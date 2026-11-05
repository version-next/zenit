//! Clock values for UI scheduling and performance measurements.
//! Every sample uses the caller's I/O implementation; no process-global clock
//! implementation is hidden in the library.
const std = @import("std");

pub const Instant = struct {
    timestamp: i96,

    pub fn now(io: std.Io) std.Io.Clock.ResolutionError!Instant {
        const resolution = try std.Io.Clock.awake.resolution(io);
        if (resolution.nanoseconds == 0) return error.ClockUnavailable;
        return .{ .timestamp = std.Io.Clock.awake.now(io).nanoseconds };
    }

    pub fn order(a: Instant, b: Instant) std.math.Order {
        return std.math.order(a.timestamp, b.timestamp);
    }

    pub fn since(a: Instant, b: Instant) u64 {
        return @intCast(@max(a.timestamp - b.timestamp, 0));
    }
};

pub const Timer = struct {
    io: std.Io,
    started: Instant,

    pub fn start(io: std.Io) std.Io.Clock.ResolutionError!Timer {
        return .{ .io = io, .started = try Instant.now(io) };
    }

    pub fn read(self: *Timer) u64 {
        const now: Instant = .{ .timestamp = std.Io.Clock.awake.now(self.io).nanoseconds };
        return now.since(self.started);
    }

    pub fn reset(self: *Timer) void {
        self.started = .{ .timestamp = std.Io.Clock.awake.now(self.io).nanoseconds };
    }

    pub fn lap(self: *Timer) u64 {
        const now: Instant = .{ .timestamp = std.Io.Clock.awake.now(self.io).nanoseconds };
        const elapsed = now.since(self.started);
        self.started = now;
        return elapsed;
    }
};

pub fn nanoTimestamp(io: std.Io) i128 {
    return std.Io.Clock.real.now(io).nanoseconds;
}

pub fn monotonicTimestamp(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// Retired instructions of the calling thread (Apple silicon PMC via thread_selfcounts); 0 on
/// other systems or when the counter is unavailable. A cost that, unlike time, does not move with
/// core type, clock or machine load (performance traces only).
pub fn threadInstructions() u64 {
    if (comptime @import("builtin").os.tag != .macos) return 0;
    const S = struct {
        extern "c" fn thread_selfcounts(kind: c_int, buf: *[2]u64, nbytes: usize) c_int;
    };
    var counts: [2]u64 = .{ 0, 0 };
    if (S.thread_selfcounts(1, &counts, @sizeOf([2]u64)) != 0) return 0;
    return counts[0];
}

/// CPU time consumed by the calling thread. Unlike wall-clock stage timers it excludes time the
/// thread spends preempted, so per-stage costs stay comparable on a loaded machine.
pub fn threadCpuTimestamp(io: std.Io) i128 {
    return std.Io.Clock.cpu_thread.now(io).nanoseconds;
}

test "elapsed time is ordered and clamps a future epoch" {
    const before: Instant = .{ .timestamp = 100 };
    const after: Instant = .{ .timestamp = 250 };
    try std.testing.expectEqual(std.math.Order.lt, before.order(after));
    try std.testing.expectEqual(@as(u64, 150), after.since(before));
    try std.testing.expectEqual(@as(u64, 0), before.since(after));
}

test "timer uses the supplied monotonic clock for lap and reset" {
    const FakeClock = struct {
        value: i96 = 100,
        available: bool = true,

        fn now(raw: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            std.debug.assert(clock == .awake);
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = self.value };
        }

        fn resolution(raw: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
            std.debug.assert(clock == .awake);
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!self.available) return error.ClockUnavailable;
            return .{ .nanoseconds = 1 };
        }
    };
    var fake: FakeClock = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = FakeClock.now;
    vtable.clockResolution = FakeClock.resolution;
    const io: std.Io = .{ .userdata = &fake, .vtable = &vtable };

    var timer = try Timer.start(io);
    fake.value = 250;
    try std.testing.expectEqual(@as(u64, 150), timer.read());
    try std.testing.expectEqual(@as(u64, 150), timer.lap());
    fake.value = 275;
    try std.testing.expectEqual(@as(u64, 25), timer.read());
    timer.reset();
    fake.value = 300;
    try std.testing.expectEqual(@as(u64, 25), timer.read());
    fake.available = false;
    try std.testing.expectError(error.ClockUnavailable, Instant.now(io));
    try std.testing.expectError(error.ClockUnavailable, Timer.start(io));
}
