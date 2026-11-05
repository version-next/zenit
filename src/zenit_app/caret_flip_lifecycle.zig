//! A patch survives exit requests until a replacement is presented and completed.
const std = @import("std");
const pacing = @import("render_pacing.zig");

/// Value snapshot only: it never owns native layers or renderer pointers.
/// A preparation may publish patches only for the same stable host epoch.
pub const Host = struct {
    signature: u64,
    surface: usize,
    layer: usize,
    drawable: [2]u32,
    viewport: [2]f32,
    scale: f32,
    blocked: bool,

    pub fn accepts(self: Host, current: Host) bool {
        return !self.blocked and !current.blocked and std.meta.eql(self, current);
    }
};

test "caret host rejects transitions and every surface geometry or identity change" {
    const stable: Host = .{ .signature = 7, .surface = 10, .layer = 20, .drawable = .{ 200, 100 }, .viewport = .{ 100, 50 }, .scale = 2, .blocked = false };
    try std.testing.expect(stable.accepts(stable));
    var changed = stable;
    changed.blocked = true;
    try std.testing.expect(!stable.accepts(changed));
    try std.testing.expect(!changed.accepts(changed));
    inline for (.{ "signature", "surface", "layer", "scale" }) |field| {
        changed = stable;
        @field(changed, field) += 1;
        try std.testing.expect(!stable.accepts(changed));
    }
    changed = stable;
    changed.drawable[0] += 1;
    try std.testing.expect(!stable.accepts(changed));
    changed = stable;
    changed.viewport[1] += 1;
    try std.testing.expect(!stable.accepts(changed));
    try std.testing.expect(changed.accepts(changed));
}

pub const Exit = struct {
    pending: bool = false,
    failures: u8 = 0,
    retry_at_ns: i128 = 0,
    pub const max_failures = 8;

    /// No caller (including a forced/manual frame) may bypass a failed handoff.
    pub fn retryDelay(self: Exit, now: i128) u64 {
        return @intCast(@max(0, self.retry_at_ns - now));
    }

    pub const Attempt = enum { not_presented, gpu_failed, completed };
    pub const Result = union(enum) { pending, retry: u64, abandon, complete };

    /// Surface acquisition/visibility is not evidence of a broken GPU.
    pub fn recordAttempt(self: *Exit, now: i128, attempt: Attempt) Result {
        return switch (attempt) {
            .not_presented => .pending,
            .completed => if (self.finish(true)) .complete else .pending,
            .gpu_failed => if (self.failed(now)) |delay| .{ .retry = delay } else .abandon,
        };
    }

    /// null means abandon the patch and disable admission for this renderer.
    pub fn failed(self: *Exit, now: i128) ?u64 {
        self.failures +|= 1;
        if (self.failures >= max_failures) {
            self.close();
            return null;
        }
        const shift: u6 = @intCast(@min(self.failures - 1, 5));
        const delay: u64 = @as(u64, @min(@as(u64, 16) << shift, 500)) * std.time.ns_per_ms;
        self.retry_at_ns = now + delay;
        return delay;
    }

    pub fn begin(self: *Exit) void {
        self.pending = true;
    }

    /// Returns whether the native patch can now be removed. Skipped, timed-out,
    /// encoded-but-unsubmitted and failed GPU attempts all pass false.
    pub fn finish(self: *Exit, presented_and_completed: bool) bool {
        if (!self.pending or !presented_and_completed) return false;
        self.close();
        return true;
    }

    /// Window teardown clears native patches independently of frame admission.
    pub fn close(self: *Exit) void {
        self.* = .{};
    }
};

test "caret exit preserves the patch through rejected timeout and failed attempts" {
    var exit: Exit = .{};
    var gate: pacing.DisplayTickGate = .{};
    gate.didRender(7);
    exit.begin();
    try std.testing.expect(!gate.shouldRender(7, .{ .wants_frame = true }));
    try std.testing.expect(exit.pending);
    // Retry on another tick, then acquisition timeout, encoding error, GPU error.
    try std.testing.expect(gate.shouldRender(8, .{ .wants_frame = true }));
    for (0..3) |_| {
        try std.testing.expect(!exit.finish(false));
        try std.testing.expect(exit.pending);
    }
    try std.testing.expect(exit.finish(true));
    try std.testing.expect(!exit.pending);
    try std.testing.expect(!exit.finish(true));
}

test "closing a failed handoff clears its state without consuming another window" {
    var first: Exit = .{};
    var second: Exit = .{};
    first.begin();
    second.begin();
    try std.testing.expect(!first.finish(false));
    first.close();
    first.close();
    try std.testing.expect(!first.pending);
    try std.testing.expect(second.pending);
    try std.testing.expect(second.finish(true));
}

test "failed handoff backs off exponentially and abandons after eight attempts" {
    var exit: Exit = .{};
    exit.begin();
    var now: i128 = 100;
    for ([_]u64{ 16, 32, 64, 128, 256, 500, 500 }) |ms| {
        try std.testing.expectEqual(ms * std.time.ns_per_ms, exit.failed(now).?);
        exit.begin(); // repeated invalidation cannot reset the budget/deadline
        try std.testing.expectEqual(ms * std.time.ns_per_ms, exit.retryDelay(now));
        now += ms * std.time.ns_per_ms;
        try std.testing.expectEqual(@as(u64, 0), exit.retryDelay(now));
    }
    try std.testing.expect(exit.failed(now) == null);
    try std.testing.expect(!exit.pending);
    exit.begin();
    _ = exit.failed(now);
    try std.testing.expect(exit.finish(true));
    try std.testing.expectEqual(@as(u8, 0), exit.failures);
    try std.testing.expectEqual(@as(i128, 0), exit.retry_at_ns);
}

/// Poll pacing must wake for both the admission deadline and ordinary phases.
pub fn quietWakeMs(now: i128, start: i128, admission_ns: u64, caret_next: ?i128) u64 {
    const deadline = if (caret_next) |phase| @min(start + admission_ns, phase) else start + admission_ns;
    const left: u64 = @intCast(@max(0, deadline - now));
    return @max(1, (left +| (std.time.ns_per_ms - 1)) / std.time.ns_per_ms);
}

test "poll quiet wake keeps 500ms blink deadlines inside the two second admission window" {
    try std.testing.expectEqual(@as(u64, 500), quietWakeMs(0, 0, 2000000000, 500000000));
    try std.testing.expectEqual(@as(u64, 499), quietWakeMs(1000001, 0, 2000000000, 500000000));
    try std.testing.expectEqual(@as(u64, 1), quietWakeMs(500000001, 0, 2000000000, 500000000));
    try std.testing.expectEqual(@as(u64, 2000), quietWakeMs(0, 0, 2000000000, null));
}

test "twenty surface timeouts preserve the handoff budget and recovery completes" {
    var exit: Exit = .{};
    exit.begin();
    for (0..20) |i| {
        try std.testing.expectEqual(Exit.Result.pending, exit.recordAttempt(@intCast(i * 250000000), .not_presented));
        try std.testing.expect(exit.pending);
        try std.testing.expectEqual(@as(u8, 0), exit.failures);
    }
    try std.testing.expectEqual(Exit.Result.complete, exit.recordAttempt(5000000000, .completed));
    try std.testing.expect(!exit.pending);
}

/// Remove the overlay only with one ordinary replacement queued. Keep the
/// editor's declared cadence; no failed handoff deadline may delay this paint.
pub fn resumeOrdinary(cx: anytype, now: i128) void {
    cx.caret_flip_host = false;
    cx.caret_paint_override = null;
    cx.needs_redraw = true;
    cx.caret_next_ns = now + cx.caret_half_ns;
    cx.scheduleRedrawAfterNs(cx.caret_half_ns);
}

/// Retry-generated needs_redraw never counts as a new interaction. Consume each
/// input/resize generation once so an unavailable surface still backs off.
pub const Activity = struct {
    input_seen: u64 = 0,
    resize_seen: u64 = 0,

    pub fn take(self: *Activity, input: u64, resize: u64, resize_pending: bool) bool {
        const urgent = input != self.input_seen or (resize_pending and resize != self.resize_seen);
        self.input_seen = input;
        self.resize_seen = resize;
        return urgent;
    }
};

/// Fresh input or a resize cuts a running caret-exit or surface retry backoff short. Only an
/// interrupted backoff asks for a frame (the retry runs now): input that waits on no backoff
/// requests frames through what it changes, never through this. A wheel against a pinned end
/// changes nothing and must render nothing.
pub fn interruptBackoff(activity: *Activity, input: u64, resize: u64, resize_pending: bool, caret_retry_at_ns: *i128, surface_retry_at_ns: *i128) bool {
    if (!activity.take(input, resize, resize_pending)) return false;
    const backed_off = caret_retry_at_ns.* != 0 or surface_retry_at_ns.* != 0;
    caret_retry_at_ns.* = 0;
    surface_retry_at_ns.* = 0;
    return backed_off;
}

test "input interrupts a running backoff, and asks for no frame when none runs" {
    var activity: Activity = .{};
    var caret: i128 = 0;
    var surface: i128 = 0;
    // No backoff: fresh input is consumed but requests nothing.
    try std.testing.expect(!interruptBackoff(&activity, 1, 0, false, &caret, &surface));
    // A caret-exit retry waiting: the next input cuts it short and asks for the retry frame.
    caret = 500;
    try std.testing.expect(interruptBackoff(&activity, 2, 0, false, &caret, &surface));
    try std.testing.expectEqual(@as(i128, 0), caret);
    // Each input generation interrupts once.
    surface = 900;
    try std.testing.expect(!interruptBackoff(&activity, 2, 0, false, &caret, &surface));
    try std.testing.expectEqual(@as(i128, 900), surface);
    try std.testing.expect(interruptBackoff(&activity, 3, 0, false, &caret, &surface));
    try std.testing.expectEqual(@as(i128, 0), surface);
}

test "input and resize interrupt backoff once while passive retries do not" {
    var activity: Activity = .{};
    var exit: Exit = .{};
    exit.begin();
    _ = exit.failed(100);
    for (0..20) |_| try std.testing.expect(!activity.take(0, 0, false));
    try std.testing.expect(activity.take(1, 0, false));
    try std.testing.expect(!activity.take(1, 0, false));
    try std.testing.expect(activity.take(1, 1, true));
    try std.testing.expect(!activity.take(1, 1, true));
    try std.testing.expect(activity.take(1, 2, true));
    try std.testing.expectEqual(@as(u8, 1), exit.failures); // interruption never resets GPU failure budget
}

/// Expensive preparation failures back off independently of ordinary blinking.
pub const Admission = struct {
    failures: u8 = 0,
    next_ns: i128 = 0,
    input_seen: u64 = 0,
    content_seen: u64 = 0,

    pub fn observe(self: *Admission, input: u64, content: u64) void {
        if (input != self.input_seen or content != self.content_seen) {
            self.failures = 0;
            self.next_ns = 0;
        }
        self.input_seen = input;
        self.content_seen = content;
    }

    /// Paint/preparation invalidations are already consumed by this frame.
    pub fn painted(self: *Admission, content: u64) void {
        self.content_seen = content;
    }

    pub fn failed(self: *Admission, now: i128, base_ns: u64) void {
        self.failures +|= 1;
        const shift: u6 = @intCast(@min(self.failures - 1, 5));
        const base: u64 = @min(base_ns, 30 * std.time.ns_per_s);
        const scaled: u64 = base << shift;
        const delay = @min(scaled, 30 * std.time.ns_per_s);
        self.next_ns = now + delay;
    }

    pub fn wakeMs(self: Admission, now: i128, quiet_start: i128, idle_ns: u64, caret_next: ?i128) u64 {
        return quietWakeMs(now, @max(quiet_start, self.next_ns - idle_ns), idle_ns, caret_next);
    }

    pub fn ready(self: Admission, now: i128) bool {
        return now >= self.next_ns;
    }
};

test "persistent admission failure cools down to thirty seconds and input or content resets it" {
    var admission: Admission = .{};
    admission.observe(1, 1);
    var now: i128 = 0;
    for ([_]u64{ 2, 4, 8, 16, 30, 30, 30 }) |seconds| {
        admission.failed(now, 2 * std.time.ns_per_s);
        admission.painted(100); // the hidden/visible/fallback frames cannot reset cooldown
        admission.observe(1, 100);
        try std.testing.expectEqual(now + seconds * std.time.ns_per_s, admission.next_ns);
        try std.testing.expect(!admission.ready(now + seconds * std.time.ns_per_s - 1));
        now += seconds * std.time.ns_per_s;
        try std.testing.expect(admission.ready(now));
    }
    admission.observe(2, 100); // genuine input
    try std.testing.expectEqual(@as(u8, 0), admission.failures);
    try std.testing.expect(admission.ready(now));
    admission.failed(now, 2 * std.time.ns_per_s);
    admission.observe(2, 101); // external content mutation, even without input
    try std.testing.expectEqual(@as(u8, 0), admission.failures);
    try std.testing.expect(admission.ready(now));
}

test "admission cooldown sleeps until the next ordinary phase instead of an expired entry deadline" {
    const admission: Admission = .{ .failures = 5, .next_ns = 30 * std.time.ns_per_s };
    try std.testing.expectEqual(@as(u64, 500), admission.wakeMs(20 * std.time.ns_per_s, 0, 2 * std.time.ns_per_s, 20500 * std.time.ns_per_ms));
}
