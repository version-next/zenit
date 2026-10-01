//! 帧性能采样历史，从 `Cx` 析出的独立值类型。
//!
//! 背景：`Cx` 里原本铺着四组一模一样的环形缓冲（frame total / frame interval /
//! drawable acquire / CPU-only frame），每组三个字段（`_us` / `_write` / `_len`）
//! 共 14 个字段，外加 17 个方法，push / percentile / avg / max 的逻辑各抄了一遍。
//! 这些方法不碰 `Cx` 的任何其它状态，是纯数据结构，却占着 `Cx` 的字段与方法面。
//!
//! 析出之后：`Sampler` 是一个可独立单测的环形缓冲，`FramePerf` 把四条链路聚在
//! 一起。`Cx` 只留一个 `frame_perf: FramePerf` 字段。

const std = @import("std");

/// 每条链路保留的采样数。120 帧 ≈ 2 秒 @60Hz。
pub const history_size: usize = 120;

/// 固定容量环形缓冲 + 分位数/均值/极值统计。
///
/// 写满后覆盖最旧样本；`len` 在填满前单调增长，之后恒为 `history_size`。
pub const Sampler = struct {
    samples: [history_size]u64 = [_]u64{0} ** history_size,
    /// 下一个写入位置，**始终已对 samples.len 取模**。
    ///
    /// ⚠ 这里曾经是 u8 并靠 `+%= 1` 回绕（2026-09-22 交叉审查发现是 bug）：
    /// u8 在 256 处回绕，而 samples.len = 120，**120 不整除 256**。于是
    /// push 超过 256 次后 `write % 120` 不再等于真实写入位置，latest() 与
    /// atFromOldest() 会读到错位的槽，60fps 下约 4.3 秒即触发，DevTools
    /// 的帧间隔读数会静默串到旧样本上。
    ///
    /// 改成在 push 时显式对 len 取模，回绕点与容量对齐，宽度也不再是隐含前提。
    write: usize = 0,
    len: u8 = 0,

    pub fn push(self: *Sampler, value: u64) void {
        self.samples[self.write] = value;
        self.write = (self.write + 1) % self.samples.len;
        if (@as(usize, self.len) < self.samples.len) self.len += 1;
    }

    pub fn reset(self: *Sampler) void {
        self.write = 0;
        self.len = 0;
        @memset(&self.samples, 0);
    }

    pub fn count(self: *const Sampler) usize {
        return @min(@as(usize, self.len), self.samples.len);
    }

    pub fn isEmpty(self: *const Sampler) bool {
        return self.count() == 0;
    }

    /// 第 `percentile` 百分位（0-100，超过 100 按 100 处理）。空时返回 null。
    pub fn percentile(self: *const Sampler, pct: u8) ?u64 {
        const len = self.count();
        if (len == 0) return null;
        var sorted: [history_size]u64 = undefined;
        @memcpy(sorted[0..len], self.samples[0..len]);
        std.mem.sort(u64, sorted[0..len], {}, std.sort.asc(u64));
        const bounded = @min(pct, 100);
        return sorted[@min(len - 1, (len - 1) * @as(usize, bounded) / 100)];
    }

    pub fn average(self: *const Sampler) ?u64 {
        const len = self.count();
        if (len == 0) return null;
        var sum: u64 = 0;
        for (self.samples[0..len]) |s| sum += s;
        return sum / @as(u64, @intCast(len));
    }

    pub fn maximum(self: *const Sampler) ?u64 {
        const len = self.count();
        if (len == 0) return null;
        var result: u64 = 0;
        for (self.samples[0..len]) |s| result = @max(result, s);
        return result;
    }

    /// 最近一次写入的样本。
    pub fn latest(self: *const Sampler) ?u64 {
        if (self.count() == 0) return null;
        const cap = self.samples.len;
        return self.samples[(self.write + cap - 1) % cap];
    }

    /// 按「从最旧到最新」的顺序取第 `idx` 个样本，越界返回 null。
    /// DevTools 的帧间隔柱状图靠它按时间轴顺序读。
    pub fn atFromOldest(self: *const Sampler, idx: usize) ?u64 {
        const len = self.count();
        if (idx >= len) return null;
        const cap = self.samples.len;
        const oldest = (self.write + cap - len) % cap;
        return self.samples[(oldest + idx) % cap];
    }
};

/// 一帧渲染的四条耗时链路。
pub const FramePerf = struct {
    /// 最近一帧 frame_start->frame_end 的墙钟总耗时（us）。
    frame_total_us: u64 = 0,
    /// 最近一帧真实呈现节奏间隔（us，按显示器刷新率下限钳制）。
    frame_interval_us: u64 = 0,

    /// 完整帧总耗时历史。含 vsync 等待、drawable 获取与帧末空转。
    total: Sampler = .{},
    /// 真实呈现节奏历史。
    interval: Sampler = .{},
    /// drawable acquire 耗时历史。
    acquire: Sampler = .{},
    /// **只含 CPU 段**的耗时历史。
    ///
    /// 与 `total` 的区别是这条链路的关键：后者存的是墙钟总耗时，里面含 vsync
    /// 等待、drawable 获取，以及"这一帧画完之后什么都没发生"的那段空转。用它
    /// 算 P95 时，一个 CPU 只花 8ms 却被显示节奏或（e2e 里）RPC 往返拖到 26ms
    /// 的帧，会报成 26ms 的"CPU P95"，看起来像卡顿，实则 CPU 空闲。
    /// 判断"渲染工作有没有超预算"必须用这一条。
    cpu: Sampler = .{},

    pub fn pushFrameTotalUs(self: *FramePerf, value: u64) void {
        self.frame_total_us = value;
        self.total.push(value);
    }

    pub fn pushFrameIntervalUs(self: *FramePerf, value: u64) void {
        self.frame_interval_us = value;
        self.interval.push(value);
    }

    pub fn reset(self: *FramePerf) void {
        self.frame_total_us = 0;
        self.frame_interval_us = 0;
        self.total.reset();
        self.interval.reset();
        self.acquire.reset();
        self.cpu.reset();
    }
};

test "Sampler: 空时统计量全为 null" {
    var s = Sampler{};
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), s.percentile(95));
    try std.testing.expectEqual(@as(?u64, null), s.average());
    try std.testing.expectEqual(@as(?u64, null), s.maximum());
    try std.testing.expectEqual(@as(?u64, null), s.latest());
    try std.testing.expectEqual(@as(?u64, null), s.atFromOldest(0));
}

test "Sampler: 基本统计" {
    var s = Sampler{};
    for ([_]u64{ 10, 20, 30, 40 }) |v| s.push(v);
    try std.testing.expectEqual(@as(usize, 4), s.count());
    try std.testing.expectEqual(@as(?u64, 40), s.latest());
    try std.testing.expectEqual(@as(?u64, 40), s.maximum());
    try std.testing.expectEqual(@as(?u64, 25), s.average());
    try std.testing.expectEqual(@as(?u64, 10), s.percentile(0));
    try std.testing.expectEqual(@as(?u64, 40), s.percentile(100));
}

test "Sampler: 写满后覆盖最旧，len 封顶" {
    var s = Sampler{};
    for (0..history_size + 10) |i| s.push(@intCast(i));
    try std.testing.expectEqual(history_size, s.count());
    try std.testing.expectEqual(@as(?u64, history_size + 9), s.latest());
    // 最旧的样本应是第 10 个（0..9 已被覆盖）
    try std.testing.expectEqual(@as(?u64, 10), s.atFromOldest(0));
    try std.testing.expectEqual(@as(?u64, null), s.atFromOldest(history_size));
}

test "Sampler: atFromOldest 在回绕后仍按时间序" {
    var s = Sampler{};
    for (0..history_size + 5) |i| s.push(@intCast(i * 2));
    var prev: u64 = 0;
    for (0..s.count()) |i| {
        const v = s.atFromOldest(i).?;
        if (i > 0) try std.testing.expect(v > prev);
        prev = v;
    }
}

test "Sampler: percentile 超过 100 按 100 处理" {
    var s = Sampler{};
    for ([_]u64{ 1, 2, 3 }) |v| s.push(v);
    try std.testing.expectEqual(s.percentile(100), s.percentile(200));
}

test "Sampler: reset 清空" {
    var s = Sampler{};
    for ([_]u64{ 5, 6, 7 }) |v| s.push(v);
    s.reset();
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), s.latest());
}

test "FramePerf: push 同时更新 latest 标量与历史" {
    var p = FramePerf{};
    p.pushFrameTotalUs(100);
    p.pushFrameIntervalUs(200);
    p.acquire.push(30);
    p.cpu.push(40);

    try std.testing.expectEqual(@as(u64, 100), p.frame_total_us);
    try std.testing.expectEqual(@as(u64, 200), p.frame_interval_us);
    try std.testing.expectEqual(@as(?u64, 100), p.total.latest());
    try std.testing.expectEqual(@as(?u64, 200), p.interval.latest());
    try std.testing.expectEqual(@as(?u64, 30), p.acquire.latest());
    try std.testing.expectEqual(@as(?u64, 40), p.cpu.latest());

    p.reset();
    try std.testing.expectEqual(@as(u64, 0), p.frame_total_us);
    try std.testing.expectEqual(@as(u64, 0), p.frame_interval_us);
    try std.testing.expect(p.total.isEmpty());
    try std.testing.expect(p.cpu.isEmpty());
}

test "Sampler: write 计数器回绕 256 之后仍指向正确样本" {
    // 回归测试（2026-09-22，glmx 交叉审查发现）：
    //
    // write 是 u8，在 256 处 wrapping 回绕；但 samples 长度是 120，而
    // **120 不整除 256**。于是 push 超过 256 次以后，`write % 120` 不再等于
    // 「真实写入位置」，latest()/atFromOldest() 会读到错位的槽。
    //
    // 60fps 下 257 帧 ≈ 4.3 秒，任何跑过几秒的真实应用都必然踩到。
    // DevTools 的帧间隔读数因此会静默串到旧样本上。
    var s = Sampler{};
    for (0..300) |i| s.push(@intCast(i));

    // 第 300 次 push 写的是值 299
    try std.testing.expectEqual(@as(?u64, 299), s.latest());

    // 最旧的应是 300-120 = 180
    try std.testing.expectEqual(@as(?u64, 180), s.atFromOldest(0));
    try std.testing.expectEqual(@as(?u64, 299), s.atFromOldest(119));

    // 从最旧到最新必须严格递增（回绕不得打乱时间序）
    var prev: u64 = 0;
    for (0..s.count()) |i| {
        const v = s.atFromOldest(i).?;
        if (i > 0) try std.testing.expect(v == prev + 1);
        prev = v;
    }
}
