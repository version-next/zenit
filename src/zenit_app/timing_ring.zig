//! timing_ring，跨帧计时采样环（GPU 性能门禁的抗噪统计量来源）
//!
//! 刻意独立成文件且**不 import 任何 zenit 模块**：renderer.zig 会拉进
//! Metal/ObjC 桥，没法在普通 test target 里编译；而百分位数学是纯逻辑，
//! 必须能被 `zig build test` 真正覆盖到，否则就是"看似有门禁、实际从没跑过"。

const std = @import("std");

/// 一帧的计时样本（renderer.FrameStats 的计时子集）。
pub const Sample = struct {
    gpu_execute_us: u64 = 0,
    cpu_frame_us: u64 = 0,
    total_frame_us: u64 = 0,
};

/// 为什么不能直接断言单帧计时：单帧受 drawable 获取、调度抖动、首帧 PSO 编译
/// 影响，方差极大，任何单帧阈值不是永远绿就是随机红。门禁要的是「最近 N 帧的
/// P95」这种抗噪统计量。
///
/// 采样只收**真正渲染过的帧**（frame() 走完整路径才 push），idle 跳帧不进环,
/// 否则大量近零样本会把 P95 拉低成毫无意义的假绿。
pub const TimingRing = struct {
    pub const CAPACITY = 120;

    gpu_execute_us: [CAPACITY]u64 = @splat(0),
    cpu_frame_us: [CAPACITY]u64 = @splat(0),
    total_frame_us: [CAPACITY]u64 = @splat(0),
    /// 环形写游标
    head: usize = 0,
    /// 有效样本数（上限 CAPACITY）
    len: usize = 0,

    pub fn push(self: *TimingRing, s: Sample) void {
        self.gpu_execute_us[self.head] = s.gpu_execute_us;
        self.cpu_frame_us[self.head] = s.cpu_frame_us;
        self.total_frame_us[self.head] = s.total_frame_us;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) self.len += 1;
    }

    pub fn reset(self: *TimingRing) void {
        self.head = 0;
        self.len = 0;
    }

    /// 第 p 百分位（p ∈ [0,100]），nearest-rank：排序后取 ceil(p/100*n) 名
    /// （1-based）。无样本返回 0。
    fn percentileOf(samples: []const u64, len: usize, p: u32) u64 {
        if (len == 0) return 0;
        var buf: [CAPACITY]u64 = undefined;
        @memcpy(buf[0..len], samples[0..len]);
        std.mem.sort(u64, buf[0..len], {}, std.sort.asc(u64));
        const rank = (@as(usize, p) * len + 99) / 100;
        const idx = if (rank == 0) 0 else rank - 1;
        return buf[@min(idx, len - 1)];
    }

    pub fn gpuPercentile(self: *const TimingRing, p: u32) u64 {
        return percentileOf(&self.gpu_execute_us, self.len, p);
    }
    pub fn cpuPercentile(self: *const TimingRing, p: u32) u64 {
        return percentileOf(&self.cpu_frame_us, self.len, p);
    }
    pub fn totalPercentile(self: *const TimingRing, p: u32) u64 {
        return percentileOf(&self.total_frame_us, self.len, p);
    }
};

/// 帧间隔样本超过此值视为 idle-resume gap（停帧后恢复的第一帧），丢弃不采样。
/// 它不是卡帧，idle 停帧是框架的省电行为，把它画成红柱/拉低 FPS 都是误报。
pub const IDLE_RESUME_GAP_US: u64 = 500_000;

/// DevTools FPS 用的帧间隔样本口径（纯函数，供单测覆盖）：
/// - 间隔 > IDLE_RESUME_GAP_US ⇒ null（idle 恢复帧，不进历史）；
/// - 否则钳到 >= 显示器刷新周期：事件突发可能让两帧间隔远小于一个
///   vsync 周期，不钳会显示出超过刷新率的假 FPS。
pub fn frameIntervalSampleUs(raw_interval_us: u64, display_period_us: u64) ?u64 {
    if (raw_interval_us > IDLE_RESUME_GAP_US) return null;
    return @max(raw_interval_us, display_period_us);
}

// ── tests ──

const testing = std.testing;

test "TimingRing: 空环所有百分位为 0" {
    const ring = TimingRing{};
    try testing.expectEqual(@as(u64, 0), ring.gpuPercentile(95));
    try testing.expectEqual(@as(u64, 0), ring.cpuPercentile(50));
    try testing.expectEqual(@as(u64, 0), ring.totalPercentile(100));
}

test "TimingRing: nearest-rank 百分位取值正确" {
    var ring = TimingRing{};
    // 1..100 微秒各一个样本
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        ring.push(.{ .gpu_execute_us = i });
    }
    try testing.expectEqual(@as(usize, 100), ring.len);
    // nearest-rank: P95 -> 第 95 名 -> 值 95；P50 -> 第 50 名 -> 50
    try testing.expectEqual(@as(u64, 95), ring.gpuPercentile(95));
    try testing.expectEqual(@as(u64, 50), ring.gpuPercentile(50));
    try testing.expectEqual(@as(u64, 100), ring.gpuPercentile(100));
    try testing.expectEqual(@as(u64, 1), ring.gpuPercentile(0));
}

test "TimingRing: nearest-rank 用 ceil 而非 floor（样本数非 100 倍数时才可区分）" {
    // n=10：P95 的 ceil(0.95*10)=10 -> 第 10 名；floor 会得到第 9 名。
    // 上一个用例 n=100 时两者恰好相同，区分不出取整方向，故补此例，
    // 否则把 ceil 改成 floor 测试仍全绿（实测过的假信号）。
    var ring = TimingRing{};
    var i: u64 = 1;
    while (i <= 10) : (i += 1) ring.push(.{ .gpu_execute_us = i * 10 });
    try testing.expectEqual(@as(u64, 100), ring.gpuPercentile(95)); // 第 10 名
    try testing.expectEqual(@as(u64, 30), ring.gpuPercentile(25)); // ceil(2.5)=3 → 第 3 名
    try testing.expectEqual(@as(u64, 10), ring.gpuPercentile(1)); // ceil(0.1)=1 → 第 1 名
}

test "TimingRing: 单个离群值不会污染 P95（抗噪的核心性质）" {
    var ring = TimingRing{};
    var i: usize = 0;
    while (i < 100) : (i += 1) ring.push(.{ .gpu_execute_us = 1000 });
    // 一个 100ms 的离群帧
    ring.push(.{ .gpu_execute_us = 100_000 });
    // P95 仍应是稳态值，而非离群值，否则门禁会被单帧抖动随机拉红
    try testing.expectEqual(@as(u64, 1000), ring.gpuPercentile(95));
    try testing.expectEqual(@as(u64, 100_000), ring.gpuPercentile(100));
}

test "TimingRing: 持续变慢会推高 P95（门禁必须能变红）" {
    var ring = TimingRing{};
    var i: usize = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .gpu_execute_us = 1000 });
    try testing.expectEqual(@as(u64, 1000), ring.gpuPercentile(95));
    // 整环被慢帧填满 -> P95 必须跟着涨（反向验证的逻辑基础）
    i = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .gpu_execute_us = 20_000 });
    try testing.expectEqual(@as(u64, 20_000), ring.gpuPercentile(95));
}

test "TimingRing: 环绕后只保留最近 CAPACITY 个样本" {
    var ring = TimingRing{};
    // 先灌满一整环慢样本，再灌满一整环快样本
    var i: usize = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .cpu_frame_us = 9999 });
    i = 0;
    while (i < TimingRing.CAPACITY) : (i += 1) ring.push(.{ .cpu_frame_us = 7 });
    try testing.expectEqual(@as(usize, TimingRing.CAPACITY), ring.len);
    // 旧的 9999 应被完全挤出
    try testing.expectEqual(@as(u64, 7), ring.cpuPercentile(100));
}

test "TimingRing: 三路计时各自独立统计" {
    var ring = TimingRing{};
    ring.push(.{ .gpu_execute_us = 10, .cpu_frame_us = 20, .total_frame_us = 30 });
    ring.push(.{ .gpu_execute_us = 11, .cpu_frame_us = 21, .total_frame_us = 31 });
    try testing.expectEqual(@as(u64, 11), ring.gpuPercentile(100));
    try testing.expectEqual(@as(u64, 21), ring.cpuPercentile(100));
    try testing.expectEqual(@as(u64, 31), ring.totalPercentile(100));
}

test "TimingRing: reset 清空样本" {
    var ring = TimingRing{};
    ring.push(.{ .gpu_execute_us = 500 });
    ring.reset();
    try testing.expectEqual(@as(usize, 0), ring.len);
    try testing.expectEqual(@as(u64, 0), ring.gpuPercentile(95));
}

test "frameIntervalSampleUs: 正常间隔原样通过" {
    try testing.expectEqual(@as(?u64, 20_000), frameIntervalSampleUs(20_000, 16_666));
}

test "frameIntervalSampleUs: 短于刷新周期被钳到周期（FPS 不超刷新率）" {
    try testing.expectEqual(@as(?u64, 16_666), frameIntervalSampleUs(2_000, 16_666));
}

test "frameIntervalSampleUs: idle-resume gap 丢弃" {
    try testing.expectEqual(@as(?u64, null), frameIntervalSampleUs(IDLE_RESUME_GAP_US + 1, 16_666));
    // 边界：恰好等于阈值仍算慢帧，保留
    try testing.expectEqual(@as(?u64, IDLE_RESUME_GAP_US), frameIntervalSampleUs(IDLE_RESUME_GAP_US, 16_666));
}
