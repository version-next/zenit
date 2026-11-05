/// Shared render pacing configuration.
///
/// CPU in-flight frame slots match the renderers' triple-buffered instance
/// storage. Surfaces present at most `maximum_frame_latency` frames ahead;
/// those that support it go one shallower while GPU load allows (DrawableDepth).
pub const maximum_frame_latency: u32 = 2;
pub const frames_in_flight: u32 = maximum_frame_latency + 1;

/// Presentation depth for surfaces that can change it while running. One
/// drawable fewer saves a full-window buffer, but only frames whose GPU time
/// leaves headroom inside a refresh period can afford the shallower queue:
/// heavy frames restore `maximum_frame_latency` at once, and only a sustained
/// light stretch (or idle) returns to the shallow depth. CPU frame slots stay at
/// `frames_in_flight` either way, so admission never depends on the depth.
pub const DrawableDepth = struct {
    pub const shallow: u32 = 1;
    pub const deep: u32 = maximum_frame_latency;
    /// Over-budget frames, within a light-reset window, that select `deep`.
    pub const heavy_to_deepen: u8 = 2;
    /// Consecutive light frames that clear the heavy count.
    pub const light_to_forget: u32 = 30;
    /// Consecutive light frames that return to `shallow` (~4 s at 60 Hz).
    pub const light_to_shallow: u32 = 240;

    latency: u32 = shallow,
    /// Pinned latency (ZENIT_DRAWABLE_DEPTH=<drawables>): adaptation off.
    /// Outranks the live-resize pin.
    fixed: ?u32 = null,
    /// AppKit live resize in progress: present `deep` regardless of GPU load.
    /// Every resize frame changes drawableSize (the layer drops its pool) and
    /// both resize paths present with the CA transaction, so a shallow queue
    /// leaves nextDrawable waiting on the compositor for about a refresh.
    /// Adaptation keeps observing underneath and resumes when the pin lifts.
    live_resize: bool = false,
    /// Latency last handed to the surface; null forces the next update.
    applied: ?u32 = null,
    heavy_frames: u8 = 0,
    light_streak: u32 = 0,

    /// ZENIT_DRAWABLE_DEPTH=2|3 pins the drawable count (A/B and rollback).
    pub fn fromEnvironment() DrawableDepth {
        var buf: [64]u8 = undefined;
        const value = @import("zenit_environment").getInto("ZENIT_DRAWABLE_DEPTH", &buf) orelse return .{};
        const drawables = @import("std").fmt.parseInt(u32, value, 10) catch return .{};
        if (drawables < shallow + 1 or drawables > deep + 1) return .{};
        return .{ .latency = drawables - 1, .fixed = drawables - 1 };
    }

    /// Feed one completed frame's GPU time (0 = no sample). Returns the
    /// latency to apply when it differs from what the surface has.
    pub fn note(self: *DrawableDepth, gpu_us: u64, period_us: u64) ?u32 {
        if (self.fixed != null) return self.pending();
        if (gpu_us != 0 and period_us != 0) {
            if (gpu_us * 2 > period_us) {
                self.light_streak = 0;
                self.heavy_frames +|= 1;
                if (self.heavy_frames >= heavy_to_deepen) self.latency = deep;
            } else if (gpu_us * 3 < period_us) {
                self.light_streak +|= 1;
                if (self.light_streak >= light_to_forget) self.heavy_frames = 0;
                if (self.light_streak >= light_to_shallow) self.latency = shallow;
            } else self.light_streak = 0;
        }
        return self.pending();
    }

    /// The window stopped presenting: the next burst starts shallow.
    pub fn reset(self: *DrawableDepth) ?u32 {
        if (self.fixed != null) return self.pending();
        self.latency = shallow;
        self.heavy_frames = 0;
        self.light_streak = 0;
        return self.pending();
    }

    /// Enter or leave live resize. Returns the latency to apply on change.
    pub fn setLiveResize(self: *DrawableDepth, active: bool) ?u32 {
        self.live_resize = active;
        return self.pending();
    }

    /// Latency the surface should use now.
    pub fn effective(self: *const DrawableDepth) u32 {
        if (self.fixed) |pinned| return pinned;
        if (self.live_resize) return deep;
        return self.latency;
    }

    fn pending(self: *DrawableDepth) ?u32 {
        const want = self.effective();
        if (self.applied == want) return null;
        self.applied = want;
        return want;
    }
};

/// AppKit live resize renders from two sources: `setFrameSize:` (the new
/// geometry, mandatory) and a refresh-rate ticker (animation while the pointer
/// holds still). The ticker fires once per refresh period, so one ticker
/// interval is one display period: a ticker fire whose period already
/// presented a resize frame must not queue a second drawable.
pub const LiveResizeTickGate = struct {
    resize_frame_this_period: bool = false,

    /// A `setFrameSize:` frame reached presentation.
    pub fn didPresentResizeFrame(self: *LiveResizeTickGate) void {
        self.resize_frame_this_period = true;
    }

    /// Ticker fire: true when this period has not presented yet. Either way a
    /// new period begins, so a skipped tick never suppresses the next one.
    pub fn tickerShouldRender(self: *LiveResizeTickGate) bool {
        const presented = self.resize_frame_this_period;
        self.resize_frame_this_period = false;
        return !presented;
    }

    /// Live resize began or ended; no period carries over.
    pub fn reset(self: *LiveResizeTickGate) void {
        self.resize_frame_this_period = false;
    }
};

/// Presentation-time geometry check (Ghostty IOSurfaceLayer.zig:96-123). A
/// drawable whose pixel size differs from the view's current bounds x backing
/// scale, or from the size the frame was laid out for, belongs to a resize
/// step that has already passed: presenting it shows misplaced content. The
/// frame is discarded and redrawn at once. A mismatch that survives
/// `max_consecutive_discards` redraws is not a stale frame but a persistent
/// disagreement between size sources; presenting then keeps frames flowing.
pub const PresentSizeGate = struct {
    pub const max_consecutive_discards: u8 = 2;
    consecutive_discards: u8 = 0,

    pub const Sizes = struct {
        drawable: [2]u32,
        /// Extent the frame was configured and laid out for.
        configured: [2]u32,
        /// View bounds x backing scale, read now.
        live: [2]u32,
    };

    pub fn shouldPresent(self: *PresentSizeGate, sizes: Sizes) bool {
        const stale = !std.mem.eql(u32, &sizes.drawable, &sizes.live) or !std.mem.eql(u32, &sizes.drawable, &sizes.configured);
        if (!stale or self.consecutive_discards >= max_consecutive_discards) {
            self.consecutive_discards = 0;
            return true;
        }
        self.consecutive_discards += 1;
        return false;
    }
};

const std = @import("std");

/// An event-pump wake is not necessarily a new display tick. Only continuous
/// animation work is coalesced; inputs and ready deadlines remain immediate.
pub const DisplayTickGate = struct {
    last_rendered_tick: ?u64 = null,

    pub const Request = struct {
        wants_frame: bool,
        forced: bool = false,
        deadline_due: bool = false,
    };

    /// A null tick keeps poll pacing/custom platforms unrestricted.
    pub fn shouldRender(self: *const DisplayTickGate, tick: ?u64, request: Request) bool {
        if (!request.wants_frame) return false;
        if (tick == null or request.forced or request.deadline_due) return true;
        return self.last_rendered_tick == null or self.last_rendered_tick != tick;
    }

    /// Call after a real submission. A skipped/failed attempt must not consume
    /// the tick, and an idle wake must not postpone the next active frame.
    pub fn didRender(self: *DisplayTickGate, tick: ?u64) void {
        self.last_rendered_tick = tick;
    }
};

test "display tick gate rejects the extra animation submission in a single tick" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    try t.expect(gate.shouldRender(17, .{ .wants_frame = true }));
    gate.didRender(17);
    // R9: an ordinary pump wake 0.618ms later queued another drawable.
    try t.expect(!gate.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(gate.shouldRender(18, .{ .wants_frame = true }));
    gate.didRender(18);
    try t.expect(!gate.shouldRender(18, .{ .wants_frame = true }));
}

test "display tick gate keeps input resize and deadline frames immediate" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    gate.didRender(17);
    try t.expect(gate.shouldRender(17, .{ .wants_frame = true, .forced = true }));
    gate.didRender(17);
    try t.expect(!gate.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(gate.shouldRender(17, .{ .wants_frame = true, .deadline_due = true }));
    gate.didRender(17);
    try t.expect(!gate.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(gate.shouldRender(18, .{ .wants_frame = true }));
}

test "display tick gate preserves first idle resume and unsubmitted attempts" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    try t.expect(!gate.shouldRender(0, .{ .wants_frame = false }));
    try t.expect(gate.shouldRender(0, .{ .wants_frame = true }));
    // No submission occurred; the retry is still eligible.
    try t.expect(gate.shouldRender(0, .{ .wants_frame = true }));
    gate.didRender(0);
    try t.expect(!gate.shouldRender(1, .{ .wants_frame = false }));
    try t.expect(gate.shouldRender(1, .{ .wants_frame = true }));
    gate.didRender(1);
    // Input restarts an idle link before its first new callback.
    try t.expect(gate.shouldRender(1, .{ .wants_frame = true, .forced = true }));
    gate.didRender(1);
    try t.expect(!gate.shouldRender(1, .{ .wants_frame = true }));
}

test "display tick gates are independent between windows and skipped ticks" {
    const t = @import("std").testing;
    var first: DisplayTickGate = .{};
    var second: DisplayTickGate = .{};
    first.didRender(17);
    try t.expect(!first.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(second.shouldRender(17, .{ .wants_frame = true }));
    second.didRender(17);
    try t.expect(first.shouldRender(20, .{ .wants_frame = true }));
    first.didRender(20);
    try t.expect(!first.shouldRender(20, .{ .wants_frame = true }));
    try t.expect(second.shouldRender(20, .{ .wants_frame = true }));
}

test "display tick gate leaves poll pacing unrestricted" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    gate.didRender(17);
    try t.expect(gate.shouldRender(null, .{ .wants_frame = true }));
    gate.didRender(null);
    try t.expect(gate.shouldRender(null, .{ .wants_frame = true }));
    try t.expect(!gate.shouldRender(null, .{ .wants_frame = false }));
}

/// Reduce independent window wake bounds without consuming timers or dirty state.
/// The native event pump still wakes immediately for input; this is only its
/// maximum blocking duration. Active/poll windows retain the legacy bound.
pub const MultiWindowIdleWait = struct {
    poll_ms: u32,
    earliest_ms: ?u32 = null,

    pub const Window = struct {
        deadline_ms: u32,
        display_link: bool = true,
        link_running: bool = false,
        closing: bool = false,
        ready_work: bool = false,
        retry_pending: bool = false,
    };

    pub fn include(self: *MultiWindowIdleWait, window: Window) void {
        const bound = if (self.poll_ms == 0)
            0
        else if (window.closing or !window.display_link)
            self.poll_ms
        else if (window.retry_pending)
            window.deadline_ms
        else if (window.link_running)
            @min(self.poll_ms, window.deadline_ms)
        else if (window.ready_work)
            0
        else
            window.deadline_ms;
        self.earliest_ms = if (self.earliest_ms) |previous| @min(previous, bound) else bound;
    }

    pub fn timeout(self: MultiWindowIdleWait, interactive_poll: bool) u32 {
        const bound = self.earliest_ms orelse self.poll_ms;
        return if (interactive_poll) @min(bound, 16) else bound;
    }
};

test "multi-window idle wait uses nearest deadline and does not depend on registration order" {
    const t = @import("std").testing;
    var first: MultiWindowIdleWait = .{ .poll_ms = 16 };
    first.include(.{ .deadline_ms = 500 });
    try t.expectEqual(@as(u32, 500), first.timeout(false));
    first.include(.{ .deadline_ms = 37 });
    var reversed: MultiWindowIdleWait = .{ .poll_ms = 16 };
    reversed.include(.{ .deadline_ms = 37 });
    reversed.include(.{ .deadline_ms = 500 });
    try t.expectEqual(@as(u32, 37), first.timeout(false));
    try t.expectEqual(first.timeout(false), reversed.timeout(false));
    try t.expectEqual(@as(u32, 16), first.timeout(true));
}

test "multi-window idle wait preserves active poll closing and empty lifecycle bounds" {
    const t = @import("std").testing;
    for ([_]MultiWindowIdleWait.Window{
        .{ .deadline_ms = 500, .link_running = true },
        .{ .deadline_ms = 500, .display_link = false },
        .{ .deadline_ms = 500, .closing = true },
    }) |window| {
        var wait: MultiWindowIdleWait = .{ .poll_ms = 16 };
        wait.include(.{ .deadline_ms = 500 });
        wait.include(window);
        try t.expectEqual(@as(u32, 16), wait.timeout(false));
    }
    const empty: MultiWindowIdleWait = .{ .poll_ms = 7 };
    try t.expectEqual(@as(u32, 7), empty.timeout(false));
    var zero: MultiWindowIdleWait = .{ .poll_ms = 0 };
    zero.include(.{ .deadline_ms = 500 });
    try t.expectEqual(@as(u32, 0), zero.timeout(false));
}

test "multi-window ready work cannot spin past retry backoff or delay another ready window" {
    const t = @import("std").testing;
    var wait: MultiWindowIdleWait = .{ .poll_ms = 16 };
    wait.include(.{ .deadline_ms = 50, .ready_work = true, .retry_pending = true });
    try t.expectEqual(@as(u32, 50), wait.timeout(false));
    wait.include(.{ .deadline_ms = 500, .ready_work = true });
    try t.expectEqual(@as(u32, 0), wait.timeout(false));
    var active: MultiWindowIdleWait = .{ .poll_ms = 16 };
    active.include(.{ .deadline_ms = 2, .link_running = true, .ready_work = true });
    try t.expectEqual(@as(u32, 2), active.timeout(false));
}

test "drawable depth starts shallow and deepens only on repeated heavy frames" {
    const t = @import("std").testing;
    var depth: DrawableDepth = .{};
    // First update applies the shallow depth even without a sample.
    try t.expectEqual(@as(?u32, DrawableDepth.shallow), depth.note(0, 16_667));
    try t.expectEqual(@as(?u32, null), depth.note(3_000, 16_667));
    // One spike is not enough; a second within the window deepens at once.
    try t.expectEqual(@as(?u32, null), depth.note(9_000, 16_667));
    try t.expectEqual(@as(?u32, DrawableDepth.deep), depth.note(9_000, 16_667));
    // Medium frames keep the deep queue and interrupt the light streak.
    for (0..DrawableDepth.light_to_shallow - 1) |_| try t.expectEqual(@as(?u32, null), depth.note(2_000, 16_667));
    try t.expectEqual(@as(?u32, null), depth.note(7_000, 16_667));
    for (0..DrawableDepth.light_to_shallow - 1) |_| try t.expectEqual(@as(?u32, null), depth.note(2_000, 16_667));
    try t.expectEqual(@as(?u32, DrawableDepth.shallow), depth.note(2_000, 16_667));
}

test "drawable depth forgets isolated spikes and resets at idle" {
    const t = @import("std").testing;
    var depth: DrawableDepth = .{};
    _ = depth.note(0, 8_333);
    try t.expectEqual(@as(?u32, null), depth.note(5_000, 8_333));
    for (0..DrawableDepth.light_to_forget) |_| _ = depth.note(1_000, 8_333);
    // The earlier spike was forgotten: this one alone stays shallow.
    try t.expectEqual(@as(?u32, null), depth.note(5_000, 8_333));
    try t.expectEqual(@as(?u32, DrawableDepth.deep), depth.note(5_000, 8_333));
    try t.expectEqual(@as(?u32, DrawableDepth.shallow), depth.reset());
    try t.expectEqual(@as(?u32, null), depth.reset());
    // Missing samples never move the depth.
    try t.expectEqual(@as(?u32, null), depth.note(0, 8_333));
    try t.expectEqual(@as(?u32, null), depth.note(9_000, 0));
}

test "pinned drawable depth never adapts" {
    const t = @import("std").testing;
    var depth: DrawableDepth = .{ .latency = DrawableDepth.deep, .fixed = DrawableDepth.deep };
    try t.expectEqual(@as(?u32, DrawableDepth.deep), depth.note(1_000, 16_667));
    for (0..DrawableDepth.light_to_shallow + 1) |_| try t.expectEqual(@as(?u32, null), depth.note(1_000, 16_667));
    try t.expectEqual(@as(?u32, null), depth.reset());
}

test "live resize pins the deep drawable queue and hands back to adaptation" {
    const t = @import("std").testing;
    var depth: DrawableDepth = .{};
    try t.expectEqual(@as(?u32, DrawableDepth.shallow), depth.note(0, 16_667));
    // Resize starts shallow: the pin deepens before the first resize frame.
    try t.expectEqual(@as(?u32, DrawableDepth.deep), depth.setLiveResize(true));
    try t.expectEqual(DrawableDepth.deep, depth.effective());
    // Light resize frames and an idle reset cannot drop the pin.
    for (0..DrawableDepth.light_to_shallow + 1) |_| try t.expectEqual(@as(?u32, null), depth.note(1_000, 16_667));
    try t.expectEqual(@as(?u32, null), depth.reset());
    try t.expectEqual(@as(?u32, null), depth.setLiveResize(true));
    // Resize end returns the adaptive (here shallow) latency.
    try t.expectEqual(@as(?u32, DrawableDepth.shallow), depth.setLiveResize(false));
    try t.expectEqual(@as(?u32, null), depth.note(1_000, 16_667));
}

test "live resize leaves an adaptively deep queue deep after the drag" {
    const t = @import("std").testing;
    var depth: DrawableDepth = .{};
    _ = depth.note(0, 16_667);
    _ = depth.note(9_000, 16_667);
    try t.expectEqual(@as(?u32, DrawableDepth.deep), depth.note(9_000, 16_667));
    try t.expectEqual(@as(?u32, null), depth.setLiveResize(true));
    try t.expectEqual(@as(?u32, null), depth.setLiveResize(false));
    try t.expectEqual(DrawableDepth.deep, depth.effective());
    // Idle after the drag still returns to shallow (and the caller purges).
    try t.expectEqual(@as(?u32, DrawableDepth.shallow), depth.reset());
}

test "explicit ZENIT_DRAWABLE_DEPTH outranks the live resize pin" {
    const t = @import("std").testing;
    var depth: DrawableDepth = .{ .latency = DrawableDepth.shallow, .fixed = DrawableDepth.shallow };
    try t.expectEqual(@as(?u32, DrawableDepth.shallow), depth.note(0, 16_667));
    try t.expectEqual(@as(?u32, null), depth.setLiveResize(true));
    try t.expectEqual(DrawableDepth.shallow, depth.effective());
    try t.expectEqual(@as(?u32, null), depth.setLiveResize(false));
}

test "live resize ticker skips only a period that already presented a resize frame" {
    const t = @import("std").testing;
    var gate: LiveResizeTickGate = .{};
    // Pointer held still: every tick renders.
    try t.expect(gate.tickerShouldRender());
    try t.expect(gate.tickerShouldRender());
    // setFrameSize: presented in this period: the tick yields.
    gate.didPresentResizeFrame();
    try t.expect(!gate.tickerShouldRender());
    // The skip opened a new period; the next tick renders again.
    try t.expect(gate.tickerShouldRender());
    // Several resize frames in one period still cost one skipped tick.
    gate.didPresentResizeFrame();
    gate.didPresentResizeFrame();
    try t.expect(!gate.tickerShouldRender());
    try t.expect(gate.tickerShouldRender());
    // A new live resize does not inherit the previous drag's period.
    gate.didPresentResizeFrame();
    gate.reset();
    try t.expect(gate.tickerShouldRender());
}

test "present size gate discards stale drawables and cannot starve presentation" {
    const t = @import("std").testing;
    var gate: PresentSizeGate = .{};
    const fresh: PresentSizeGate.Sizes = .{ .drawable = .{ 1600, 1200 }, .configured = .{ 1600, 1200 }, .live = .{ 1600, 1200 } };
    try t.expect(gate.shouldPresent(fresh));
    // Bounds moved on after layout/acquire.
    try t.expect(!gate.shouldPresent(.{ .drawable = .{ 1600, 1200 }, .configured = .{ 1600, 1200 }, .live = .{ 1640, 1200 } }));
    // A native drawableSize write raced the configured layout size.
    try t.expect(!gate.shouldPresent(.{ .drawable = .{ 1640, 1200 }, .configured = .{ 1600, 1200 }, .live = .{ 1640, 1200 } }));
    // Persistent disagreement presents rather than discarding forever.
    try t.expect(gate.shouldPresent(.{ .drawable = .{ 1640, 1200 }, .configured = .{ 1600, 1200 }, .live = .{ 1640, 1200 } }));
    // A matching frame clears the streak; the next stale one is discarded again.
    try t.expect(gate.shouldPresent(fresh));
    try t.expect(!gate.shouldPresent(.{ .drawable = .{ 1600, 1200 }, .configured = .{ 1600, 1200 }, .live = .{ 1600, 1180 } }));
    try t.expect(gate.shouldPresent(fresh));
    try t.expectEqual(@as(u8, 0), gate.consecutive_discards);
}
