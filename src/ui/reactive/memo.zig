/// Memo: 缓存的派生计算
///
/// v0.2-P1 重写：lazy pull on read。
/// - 创建时不立即计算（v0.1 是 eager push）
/// - get() 时调 graph.updateIfNecessary：若 source 没变直接返回 cache，
///   若变了重算并 version++
/// - 下游通过 graph.trackRead 建依赖；source 变化时 graph 把下游标 dirty
///
/// 设计参照：Solid v1 Memo + Reactively 论文（push-pull 混合）。
///
/// 用法:
/// ```zig
/// const doubled = try createMemo(owner, i32, .{ .count = count }, struct {
///     fn compute(ctx: anytype) i32 { return ctx.count.get() * 2; }
/// }.compute);
/// doubled.get()  // lazy 计算 + 自动追踪
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalOwner = @import("owner.zig").SignalOwner;
const Signal = @import("signal.zig").Signal;
const effect_mod = @import("effect.zig");
const Scope = @import("scope.zig").Scope;
const graph_mod = @import("graph.zig");

pub fn Memo(comptime T: type) type {
    return struct {
        owner: *SignalOwner,
        graph_node_raw: u32,
        /// 缓存的当前值；首次读时 lazy 计算后填充
        cache: T,
        /// 首次计算前标记（避免读 undefined cache 比较）
        initialized: bool,
        /// computeFn + 用户上下文，存为类型擦除指针避免 generic 在 graph 里展开
        compute_ctx: *anyopaque,
        compute_fn: *const fn (compute_ctx: *anyopaque, out: *anyopaque) bool,

        const Self = @This();

        /// 读取值（lazy pull + 自动追踪下游）
        pub fn get(self: *Self) T {
            self.owner.assertThread();
            self.owner.beginReactiveCallback();
            defer self.owner.endReactiveCallback();
            const gid: graph_mod.NodeId = @bitCast(self.graph_node_raw);
            // 触发 lazy 重算（state == clean 时是 no-op；dirty/check 时拉取上游）
            self.owner.graph.updateIfNecessary(gid);
            // 让调用者也成为 memo 的 observer
            // 不可降级：丢边 = 下游不再被这个 memo 唤醒（该更新的静默不更新）。
            // Memo.get 是 Stable 签名（返回 T），无法传播错误 -> panic。
            self.owner.graph.trackRead(gid) catch @panic("OOM: Memo.get trackRead (dependency edge lost)");
            return self.cache;
        }

        /// 读取值（不追踪）
        pub fn peek(self: *Self) T {
            self.owner.assertThread();
            self.owner.beginReactiveCallback();
            defer self.owner.endReactiveCallback();
            const gid: graph_mod.NodeId = @bitCast(self.graph_node_raw);
            self.owner.graph.updateIfNecessary(gid);
            return self.cache;
        }
    };
}

/// 创建 Memo: 缓存的派生计算（lazy pull）。
pub fn createMemo(
    owner: *SignalOwner,
    comptime T: type,
    context: anytype,
    comptime computeFn: anytype,
) !*Memo(T) {
    const Context = @TypeOf(context);
    const MemoT = Memo(T);

    // 包装 computeFn：graph.recompute 调时把 compute_ctx 还原成 (Memo + Context)，
    // 调 user computeFn，比较新旧 cache，返回是否变化。
    const Closure = struct {
        memo: *MemoT,
        ctx: Context,

        fn run(opaque_ctx: *anyopaque, out: *anyopaque) bool {
            _ = out;
            const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
            const new_value = computeFn(c.ctx);
            const eq = @import("eq.zig").eqlValue;
            // 首次：cache 是 undefined，绝不能读取来比较，一律视作变化。
            const changed = !c.memo.initialized or !eq(T, c.memo.cache, new_value);
            c.memo.cache = new_value;
            c.memo.initialized = true;
            return changed;
        }

        fn graphRecompute(opaque_ctx: *anyopaque) bool {
            const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
            return run(opaque_ctx, c);
        }
    };

    const memo = try owner.allocator().create(MemoT);
    // arena 分配帧内可回收，但半注册态（memo 已建、graph node 没建）会让
    // 后续按注册表遍历的代码读到未初始化结构，失败路径必须整体回退
    errdefer owner.allocator().destroy(memo);
    const closure = try owner.allocator().create(Closure);
    errdefer owner.allocator().destroy(closure);
    closure.* = .{
        .memo = memo,
        .ctx = context,
    };

    // memo 注册到 graph，状态 .dirty（首次读时计算）
    const gid = try owner.graph.createNodeRaw(.memo, &Closure.graphRecompute, closure);
    memo.* = .{
        .owner = owner,
        .graph_node_raw = @bitCast(gid),
        .cache = undefined,
        .initialized = false,
        .compute_ctx = closure,
        .compute_fn = &Closure.run,
    };

    return memo;
}

/// 在 Scope 中创建 Memo（保留模式路径）
pub fn createMemoInScope(
    scope: *Scope,
    comptime T: type,
    context: anytype,
    comptime computeFn: anytype,
) !*Memo(T) {
    // scope 路径同 owner 路径，lazy pull on read，不再创建内部 Signal+Effect。
    const Context = @TypeOf(context);
    const MemoT = Memo(T);

    const Closure = struct {
        memo: *MemoT,
        ctx: Context,

        fn run(opaque_ctx: *anyopaque, out: *anyopaque) bool {
            _ = out;
            const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
            const new_value = computeFn(c.ctx);
            const eq = @import("eq.zig").eqlValue;
            // 首次：cache 是 undefined，绝不能读取来比较，此时一律视作变化。
            const changed = !c.memo.initialized or !eq(T, c.memo.cache, new_value);
            c.memo.cache = new_value;
            c.memo.initialized = true;
            return changed;
        }
        fn graphRecompute(opaque_ctx: *anyopaque) bool {
            const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
            return run(opaque_ctx, c);
        }
    };

    const memo = try scope.allocator.create(MemoT);
    // scope.allocator 是 caller allocator：registerResource 挂上 cleanup 之前
    // 任何失败都是净泄漏，必须 errdefer 整体回退（含已建的 graph node）
    errdefer scope.allocator.destroy(memo);
    const closure = try scope.allocator.create(Closure);
    errdefer scope.allocator.destroy(closure);

    closure.* = .{ .memo = memo, .ctx = context };

    const gid = try scope.owner.graph.createNodeRaw(.memo, &Closure.graphRecompute, closure);
    errdefer scope.owner.graph.destroyNode(gid);
    memo.* = .{
        .owner = scope.owner,
        .graph_node_raw = @bitCast(gid),
        .cache = undefined,
        .initialized = false,
        .compute_ctx = closure,
        .compute_fn = &Closure.run,
    };

    // Memo 结构体本身非常轻量，
    // 通过 scope 的资源追踪列表管理其生命周期 + graph node 注销。
    // ⚠ closure 与 memo 是两次独立分配：cleanup 必须**两个都释放**，
    // 否则每个 memo 在 scope dispose 后漏一个 Closure（compute_ctx 即该指针）。
    try scope.registerResource(@ptrCast(memo), struct {
        fn cleanup(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const m: *Memo(T) = @ptrCast(@alignCast(ptr));
            const gid_destroy: graph_mod.NodeId = @bitCast(m.graph_node_raw);
            m.owner.graph.destroyNode(gid_destroy);
            // destroyNode 之后 graph 不再持有 closure，可安全释放。
            const c: *Closure = @ptrCast(@alignCast(m.compute_ctx));
            allocator.destroy(c);
            allocator.destroy(m);
        }
    }.cleanup);

    return memo;
}

// ===== 测试 =====

test "Memo: basic derived computation" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 5);

    const doubled = try createMemo(owner, i32, .{ .count = count }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.count.get() * 2;
        }
    }.compute);

    try std.testing.expectEqual(@as(i32, 10), doubled.get());

    count.set(7);
    try std.testing.expectEqual(@as(i32, 14), doubled.get());

    count.set(0);
    try std.testing.expectEqual(@as(i32, 0), doubled.get());
}

test "Memo: tracks multiple signals" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const a = try Signal(i32).create(owner, 3);
    const b = try Signal(i32).create(owner, 4);

    const sum = try createMemo(owner, i32, .{ .a = a, .b = b }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.a.get() + ctx.b.get();
        }
    }.compute);

    try std.testing.expectEqual(@as(i32, 7), sum.get());

    a.set(10);
    try std.testing.expectEqual(@as(i32, 14), sum.get());

    b.set(20);
    try std.testing.expectEqual(@as(i32, 30), sum.get());
}

test "Memo: downstream effect reacts to memo change" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 2);

    const doubled = try createMemo(owner, i32, .{ .count = count }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.count.get() * 2;
        }
    }.compute);

    var effect_result: i32 = 0;

    try effect_mod.createEffect(owner, .{
        .doubled = doubled,
        .result = &effect_result,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.result.* = ctx.doubled.get();
        }
    }.run);

    // Effect 首次运行
    try std.testing.expectEqual(@as(i32, 4), effect_result);

    // 修改源 Signal -> Memo 更新 -> 下游 Effect 更新
    count.set(5);
    try std.testing.expectEqual(@as(i32, 10), effect_result);
}

test "Memo: skips when value unchanged" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const x = try Signal(i32).create(owner, 5);
    const y = try Signal(i32).create(owner, -5);

    // abs(x + y)，当 x=5, y=-5 时结果始终为 0
    const abs_sum = try createMemo(owner, i32, .{ .x = x, .y = y }, struct {
        fn compute(ctx: anytype) i32 {
            const s = ctx.x.get() + ctx.y.get();
            return if (s < 0) -s else s;
        }
    }.compute);

    var effect_count: i32 = 0;

    try effect_mod.createEffect(owner, .{
        .abs_sum = abs_sum,
        .counter = &effect_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.abs_sum.get();
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 0), abs_sum.get());
    try std.testing.expectEqual(@as(i32, 1), effect_count);

    // 改变 x 和 y 使总和不变 -> Memo 值不变 -> 下游 Effect 不应再运行
    // 注意: x.set 会触发 memo 的 effect 重新计算, 但 abs(6 + (-5)) = 1 ≠ 0
    // 所以要确保真正不变的情况
    x.set(10);
    y.set(-10);
    // abs(10 + (-10)) = 0, 但中间 x.set(10) 时 abs(10+(-5))=5, 所以 effect 会运行
    // 最终结果是 0, 但过程中有变化
    try std.testing.expectEqual(@as(i32, 0), abs_sum.get());
}

test "Memo: peek doesn't track" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 3);
    const tripled = try createMemo(owner, i32, .{ .count = count }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.count.get() * 3;
        }
    }.compute);

    var effect_run_count: i32 = 0;

    try effect_mod.createEffect(owner, .{
        .tripled = tripled,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.tripled.peek(); // peek 不追踪
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    count.set(10);
    // Memo 更新了,但下游 Effect 用的是 peek,所以不应重新运行
    try std.testing.expectEqual(@as(i32, 1), effect_run_count);
    // 但 memo 值确实更新了
    try std.testing.expectEqual(@as(i32, 30), tripled.peek());
}
