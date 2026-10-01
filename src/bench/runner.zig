//! Bench runner, Phase 0 perf 基线建立工具
//!
//! 设计目标：
//! - 简单可重复：黑箱时间测量 + warmup + 多次 sample 取中位数
//! - 输出双格式：人读 stdout 表格 + 机读 JSON（供 CI diff）
//! - 不依赖外部 crate；纯 std
//! - 每个 bench 注册一个名字 + setup + body；runner 统一执行
//!
//! 用法：在 src/bench/main.zig 注册 cases，build.zig 加 bench step：
//!     zig build bench               # 跑所有
//!     zig build bench -- name=...   # 过滤
//!     zig build bench -- json=path  # 输出 JSON

const std = @import("std");

pub const BenchOptions = struct {
    /// warmup 迭代次数（不计入测量）
    warmup_iters: u32 = 5,
    /// 测量 sample 数（取中位数 + p95）
    sample_iters: u32 = 50,
    /// 每次 sample 内部循环次数（小操作摊销噪声）。0 = 自适应。
    inner_iters: u32 = 0,
    /// 单 case 总时间软上限（ns），超时提前退出，避免一个慢 case 卡死 CI
    soft_budget_ns: u64 = 5 * std.time.ns_per_s,
};

pub const BenchResult = struct {
    name: []const u8,
    iters_per_sample: u32,
    samples: u32,
    median_ns_per_iter: f64,
    p95_ns_per_iter: f64,
    min_ns_per_iter: f64,
    mean_ns_per_iter: f64,
};

pub const BenchFn = *const fn (allocator: std.mem.Allocator, ctx: *BenchCtx) anyerror!void;

pub const BenchCase = struct {
    name: []const u8,
    setup: ?*const fn (allocator: std.mem.Allocator) anyerror!*anyopaque = null,
    teardown: ?*const fn (allocator: std.mem.Allocator, state: *anyopaque) void = null,
    body: BenchFn,
    opts: BenchOptions = .{},
};

/// 运行时上下文，body 可读 setup 输出 + 控制内层循环。
pub const BenchCtx = struct {
    state: ?*anyopaque,
    iter_index: u32,

    /// 防 LLVM 把 body 计算结果整体 dead-code-eliminate
    pub fn blackbox(self: *BenchCtx, value: anytype) void {
        _ = self;
        // 强制写入 volatile sink；LLVM 不能优化掉
        const T = @TypeOf(value);
        std.mem.doNotOptimizeAway(@as(T, value));
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    cases: []const BenchCase,
    filter: ?[]const u8,
    json_out: ?std.fs.File,
) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buffer);
    const w = &stdout_w.interface;

    try w.print("\n{s:<48} {s:>14} {s:>14} {s:>14}\n", .{ "name", "median ns/it", "p95 ns/it", "min ns/it" });
    try w.print("{s:-<48} {s:->14} {s:->14} {s:->14}\n", .{ "", "", "", "" });
    try w.flush();

    var results = std.ArrayList(BenchResult).empty;
    defer results.deinit(allocator);

    for (cases) |case| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, case.name, f) == null) continue;
        }
        const r = runCase(allocator, case) catch |err| {
            try w.print("{s:<48} ERROR: {s}\n", .{ case.name, @errorName(err) });
            try w.flush();
            continue;
        };
        try w.print("{s:<48} {d:>14.1} {d:>14.1} {d:>14.1}\n", .{
            r.name,
            r.median_ns_per_iter,
            r.p95_ns_per_iter,
            r.min_ns_per_iter,
        });
        try w.flush();
        try results.append(allocator, r);
    }

    try w.flush();

    if (json_out) |f| {
        var json_buffer: [4096]u8 = undefined;
        var json_w = f.writer(&json_buffer);
        const jw = &json_w.interface;
        // 溯源信息：baseline 只有裸数字时，门禁红了没人判断得了是代码退化
        // 还是换了机器/负载，实测 src/bench/baselines/main.json 就因为
        // 没记 commit 而烂红了一个多月。ZENIT_BENCH_COMMIT 由 CI / 刷新脚本
        // 注入；本地手跑时缺省 "unknown"，不影响比较，只影响可追溯性。
        const commit = std.process.getEnvVarOwned(allocator, "ZENIT_BENCH_COMMIT") catch null;
        defer if (commit) |c| allocator.free(c);
        const host = std.process.getEnvVarOwned(allocator, "ZENIT_BENCH_HOST") catch null;
        defer if (host) |h| allocator.free(h);
        try jw.print(
            "{{\n  \"commit\": \"{s}\",\n  \"host\": \"{s}\",\n  \"unix_time\": {d},\n  \"results\": [\n",
            .{ commit orelse "unknown", host orelse "unknown", std.time.timestamp() },
        );
        for (results.items, 0..) |r, i| {
            try jw.print(
                "    {{\"name\":\"{s}\",\"median_ns\":{d:.3},\"p95_ns\":{d:.3},\"min_ns\":{d:.3},\"mean_ns\":{d:.3},\"samples\":{d},\"iters_per_sample\":{d}}}{s}\n",
                .{ r.name, r.median_ns_per_iter, r.p95_ns_per_iter, r.min_ns_per_iter, r.mean_ns_per_iter, r.samples, r.iters_per_sample, if (i + 1 == results.items.len) "" else "," },
            );
        }
        try jw.writeAll("  ]\n}\n");
        try jw.flush();
    }
}

fn runCase(allocator: std.mem.Allocator, case: BenchCase) !BenchResult {
    const state: ?*anyopaque = if (case.setup) |s| try s(allocator) else null;
    defer if (case.teardown) |t| {
        if (state) |st| t(allocator, st);
    };

    var inner = case.opts.inner_iters;
    if (inner == 0) {
        inner = try calibrateInner(allocator, case, state);
    }

    // Warmup
    var ctx = BenchCtx{ .state = state, .iter_index = 0 };
    var i: u32 = 0;
    while (i < case.opts.warmup_iters) : (i += 1) {
        ctx.iter_index = i;
        var j: u32 = 0;
        while (j < inner) : (j += 1) {
            try case.body(allocator, &ctx);
        }
    }

    // Sample
    const samples = try allocator.alloc(f64, case.opts.sample_iters);
    defer allocator.free(samples);
    const t_start = std.time.nanoTimestamp();
    var s_i: u32 = 0;
    while (s_i < case.opts.sample_iters) : (s_i += 1) {
        const t0 = std.time.nanoTimestamp();
        var k: u32 = 0;
        while (k < inner) : (k += 1) {
            ctx.iter_index = s_i * inner + k;
            try case.body(allocator, &ctx);
        }
        const t1 = std.time.nanoTimestamp();
        const elapsed: f64 = @floatFromInt(t1 - t0);
        samples[s_i] = elapsed / @as(f64, @floatFromInt(inner));

        // 软预算超限提前退出
        if (@as(u64, @intCast(t1 - t_start)) > case.opts.soft_budget_ns) {
            break;
        }
    }
    const used = s_i;
    const slice = samples[0..used];

    std.mem.sort(f64, slice, {}, std.sort.asc(f64));
    const median = slice[used / 2];
    const p95 = slice[@min(used - 1, (used * 95) / 100)];
    const min_v = slice[0];

    var sum: f64 = 0;
    for (slice) |v| sum += v;
    const mean_v = sum / @as(f64, @floatFromInt(used));

    return .{
        .name = case.name,
        .iters_per_sample = inner,
        .samples = used,
        .median_ns_per_iter = median,
        .p95_ns_per_iter = p95,
        .min_ns_per_iter = min_v,
        .mean_ns_per_iter = mean_v,
    };
}

/// 自适应内部迭代数：让单 sample 至少 ~50µs，避免计时器抖动主导
fn calibrateInner(allocator: std.mem.Allocator, case: BenchCase, state: ?*anyopaque) !u32 {
    var inner: u32 = 1;
    while (inner < 1_000_000) : (inner *= 2) {
        var ctx = BenchCtx{ .state = state, .iter_index = 0 };
        const t0 = std.time.nanoTimestamp();
        var j: u32 = 0;
        while (j < inner) : (j += 1) {
            try case.body(allocator, &ctx);
        }
        const t1 = std.time.nanoTimestamp();
        const elapsed: u64 = @intCast(t1 - t0);
        if (elapsed >= 50_000) return inner;
    }
    return 1_000_000;
}
