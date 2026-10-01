/// 帧级 Timeline Profiler，记录最近 128 帧各阶段耗时
///
/// 用法:
/// ```zig
/// profiler.beginFrame();
/// profiler.markPhase(.layout);
/// // ... layout ...
/// profiler.markPhase(.before_render);
/// // ... before_render ...
/// profiler.markPhase(.render);
/// // ... render ...
/// profiler.endFrame();
/// ```
const std = @import("std");

/// 帧渲染各阶段
pub const Phase = enum(u8) {
    layout = 0,
    before_render = 1,
    render = 2,
    encode = 3,
    flush = 4,
    deferred = 5,
    idle = 6, // 帧间空闲（非渲染时间）
};

/// 单帧时间线
pub const FrameTimeline = struct {
    /// 各阶段耗时（微秒）
    phase_us: [7]u64 = [_]u64{0} ** 7,
    /// 整帧耗时（微秒）
    total_us: u64 = 0,
    /// 帧序号
    frame_number: u64 = 0,
};

/// Timeline Profiler
pub const TimelineProfiler = struct {
    /// 环形缓冲区（最近 128 帧）
    ring_buffer: [ring_size]FrameTimeline = [_]FrameTimeline{.{}} ** ring_size,
    /// 写入位置
    write_pos: u7 = 0,
    /// 已记录的帧数
    frame_count: u64 = 0,
    /// 是否启用
    enabled: bool = false,

    /// 当前帧的计时状态
    frame_start: ?std.time.Instant = null,
    current_phase: ?Phase = null,
    phase_start: ?std.time.Instant = null,
    current_frame: FrameTimeline = .{},

    const ring_size = 128;

    /// 开始新帧计时
    pub fn beginFrame(self: *TimelineProfiler) void {
        if (!self.enabled) return;
        self.frame_start = std.time.Instant.now() catch null;
        self.current_frame = .{ .frame_number = self.frame_count };
        self.current_phase = null;
        self.phase_start = null;
    }

    /// 标记进入新阶段（自动结束上一阶段的计时）
    pub fn markPhase(self: *TimelineProfiler, phase: Phase) void {
        if (!self.enabled) return;
        const now = std.time.Instant.now() catch return;

        // 结束上一阶段
        if (self.current_phase) |prev_phase| {
            if (self.phase_start) |start| {
                const elapsed_ns = now.since(start);
                self.current_frame.phase_us[@intFromEnum(prev_phase)] = elapsed_ns / 1000;
            }
        }

        // 开始新阶段
        self.current_phase = phase;
        self.phase_start = now;
    }

    /// 结束当前帧计时，写入环形缓冲区
    pub fn endFrame(self: *TimelineProfiler) void {
        if (!self.enabled) return;
        const now = std.time.Instant.now() catch return;

        // 结束最后一个阶段
        if (self.current_phase) |prev_phase| {
            if (self.phase_start) |start| {
                const elapsed_ns = now.since(start);
                self.current_frame.phase_us[@intFromEnum(prev_phase)] = elapsed_ns / 1000;
            }
        }

        // 总帧时间
        if (self.frame_start) |start| {
            self.current_frame.total_us = now.since(start) / 1000;
        }

        // 写入环形缓冲区
        self.ring_buffer[self.write_pos] = self.current_frame;
        self.write_pos +%= 1;
        self.frame_count += 1;

        // 重置
        self.frame_start = null;
        self.current_phase = null;
    }
};

test "TimelineProfiler: basic recording" {
    var profiler = TimelineProfiler{ .enabled = true };

    profiler.beginFrame();
    profiler.markPhase(.layout);
    profiler.markPhase(.render);
    profiler.endFrame();

    try std.testing.expect(profiler.frame_count == 1);
    try std.testing.expect(profiler.ring_buffer[0].frame_number == 0);
}
