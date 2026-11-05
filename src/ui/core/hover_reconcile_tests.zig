//! Stationary-pointer hover: when the scene under a pointer that does not move changes (scroll,
//! programmatic scroll, layout shift, unmount), hover follows the node now under the pointer in
//! the next rendered frame, exactly as a pointer move to the same point would, without a
//! mouse_move event. Gated on a live pointer (over the window's visible content per the platform,
//! in any activation state; no capture or press sequence) and on the hit scene having actually
//! changed.
const std = @import("std");
const ui = @import("../core.zig");
const testing = std.testing;

const row_h: f32 = 30;
const row_count = 10;

const Rig = struct {
    cx: *ui.Cx,
    clip: *ui.Node,
    content: *ui.Node,
    rows: [row_count]*ui.Node,
    log: *Log,

    const Log = struct {
        enters: [row_count]u32 = @splat(0),
        leaves: [row_count]u32 = @splat(0),
        moves: u32 = 0,
    };

    const RowCtx = struct { log: *Log, index: usize };

    fn onEvent(event: ui.Event, context: ?*anyopaque) ui.EventResult {
        const row: *RowCtx = @ptrCast(@alignCast(context.?));
        switch (event) {
            .mouse_enter => row.log.enters[row.index] += 1,
            .mouse_leave => row.log.leaves[row.index] += 1,
            .mouse_move => row.log.moves += 1,
            else => {},
        }
        return .ignored;
    }

    var row_ctx_storage: [4][row_count]RowCtx = undefined;
    var log_storage: [4]Log = undefined;

    fn init(slot: usize) !Rig {
        const cx = try ui.Cx.init(testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(200, 200);
        try cx.setTestFrameStep(16);
        cx.caret_flip_host = true;
        log_storage[slot] = .{};
        const root = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
        cx.root = root;
        // A 100px clip viewport over a 300px column: translate_y on `content` is a scroll offset.
        const clip = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .overflow_hidden = true }, .{});
        try root.appendChild(cx.allocator, clip);
        const content = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .fit = .{} } }, .{});
        try clip.appendChild(cx.allocator, content);
        var rows: [row_count]*ui.Node = undefined;
        for (0..row_count) |i| {
            const row = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = row_h } }, .{});
            row_ctx_storage[slot][i] = .{ .log = &log_storage[slot], .index = i };
            row.behavior.events.on_event = onEvent;
            row.behavior.events.event_context = &row_ctx_storage[slot][i];
            try content.appendChild(cx.allocator, row);
            rows[i] = row;
        }
        var rig = Rig{ .cx = cx, .clip = clip, .content = content, .rows = rows, .log = &log_storage[slot] };
        try rig.settle();
        return rig;
    }

    fn deinit(self: *Rig) void {
        self.cx.deinit();
    }

    /// One host frame (renderer order: clock, layout, render).
    fn frame(self: *Rig) void {
        self.cx.advanceFrameClock();
        self.cx.layout();
        _ = self.cx.render();
    }

    /// Run frames until the host would go idle.
    fn settle(self: *Rig) !void {
        var frames: usize = 0;
        while (self.cx.wantsFrame() and frames < 120) : (frames += 1) self.frame();
        try testing.expect(!self.cx.wantsFrame());
    }

    /// Programmatic scroll, the same writes ScrollArea.setScrollY performs.
    fn scrollTo(self: *Rig, y: f32) void {
        self.content.style.translate_y = -y;
        self.content.markCompositePropDirty();
    }

    fn hovered(self: *Rig) ?usize {
        const node = self.cx.hovered_node orelse return null;
        for (self.rows, 0..) |row, i| if (row == node) return i;
        return null;
    }

    fn reconcileHitTests(self: *Rig) u64 {
        return self.cx.hover_sync.reconcile_hit_tests;
    }
};

test "hover: stationary pointer follows programmatically scrolled content in the next frame" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 15);
    try testing.expectEqual(@as(?usize, 0), rig.hovered());
    const moves_before = rig.log.moves;

    rig.scrollTo(60);
    rig.frame();
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
    try testing.expectEqual(@as(u32, 1), rig.log.leaves[0]);
    try testing.expectEqual(@as(u32, 1), rig.log.enters[2]);
    try testing.expectEqual(@as(u32, 0), rig.log.enters[1]);
    // Re-resolution is not a pointer move: no mouse_move reaches the content.
    try testing.expectEqual(moves_before, rig.log.moves);
    try rig.settle();
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
    try testing.expectEqual(@as(u32, 1), rig.log.enters[2]);
}

test "hover: every frame of an animated scroll re-resolves once" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 15);
    // A momentum/spring scroll moves content a little every frame.
    var y: f32 = 0;
    var expected_hits: u64 = rig.reconcileHitTests();
    while (y < 150) {
        y += 10;
        rig.scrollTo(y);
        rig.frame();
        expected_hits += 1;
        try testing.expectEqual(expected_hits, rig.reconcileHitTests());
        const want: usize = @intFromFloat(@floor((15 + y) / row_h));
        try testing.expectEqual(@as(?usize, want), rig.hovered());
    }
    // Each row entered and left at most once on the way: no stale or duplicate transitions.
    for (0..5) |i| {
        try testing.expectEqual(@as(u32, 1), rig.log.enters[i]);
        try testing.expectEqual(@as(u32, 1), rig.log.leaves[i]);
    }
    try testing.expectEqual(@as(u32, 1), rig.log.enters[5]);
}

test "hover: layout shift and unmount under a stationary pointer re-resolve hover" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 45);
    try testing.expectEqual(@as(?usize, 1), rig.hovered());

    // Content above grows: every row moves down by one row height.
    const spacer = try ui.box(rig.cx, .{ .width = .{ .px = 200 }, .height = .{ .px = row_h } }, .{});
    try rig.content.insertChildBefore(rig.cx.allocator, spacer, rig.rows[0]);
    rig.frame();
    try testing.expectEqual(@as(?usize, 0), rig.hovered());
    try testing.expectEqual(@as(u32, 1), rig.log.leaves[1]);
    try testing.expectEqual(@as(u32, 1), rig.log.enters[0]);

    // The hovered row is unmounted: the row that reflows under the pointer becomes hovered.
    rig.cx.detachChild(rig.content, rig.rows[0]);
    rig.cx.freeNode(rig.rows[0]);
    rig.frame();
    try testing.expectEqual(@as(?usize, 1), rig.hovered());
    try testing.expectEqual(@as(u32, 2), rig.log.enters[1]);
    try rig.settle();
}

test "hover: no hit test while the scene is unchanged" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    const hits_before_move = rig.reconcileHitTests();
    // A pointer move resolves hover against the committed scene; the frame after it must not
    // re-resolve the same point again.
    rig.cx.handleMouseMove(50, 15);
    try rig.settle();
    try testing.expectEqual(hits_before_move, rig.reconcileHitTests());
    const hits = rig.reconcileHitTests();
    // Paint-only change: frames run, hit scene untouched, no re-resolution.
    rig.rows[5].setBackground(ui.Color.rgb(10, 20, 30));
    try testing.expect(rig.cx.wantsFrame());
    try rig.settle();
    for (0..10) |_| rig.frame();
    try testing.expectEqual(hits, rig.reconcileHitTests());
    try testing.expectEqual(@as(?usize, 0), rig.hovered());
}

test "hover: pointer capture and an active press hold hover until the sequence ends" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 15);
    // Press without capture: AppKit tracking areas and browsers do not re-resolve hover mid-press.
    rig.cx.handleMouseDown(50, 15, .{});
    const hits = rig.reconcileHitTests();
    rig.scrollTo(60);
    try rig.settle();
    try testing.expectEqual(@as(?usize, 0), rig.hovered());
    try testing.expectEqual(hits, rig.reconcileHitTests());
    try testing.expectEqual(@as(u32, 0), rig.log.leaves[0]);
    // Release over the moved content: the deferred re-resolution lands in the next frame.
    rig.cx.handleMouseUp(50, 15);
    try testing.expect(rig.cx.wantsFrame());
    try rig.settle();
    try testing.expectEqual(@as(?usize, 2), rig.hovered());

    // Capture (drag): hover stays on the capture owner while content moves under the pointer.
    rig.cx.setPointerCapture(rig.rows[2]);
    rig.scrollTo(120);
    try rig.settle();
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
    rig.cx.releasePointerCapture();
    try testing.expect(rig.cx.wantsFrame());
    try rig.settle();
    try testing.expectEqual(@as(?usize, 4), rig.hovered());

    // Press + capture released by the button-up: the up's resync resolves hover at once, so the
    // following frames have nothing left to re-resolve.
    rig.cx.handleMouseDown(50, 15, .{});
    rig.cx.setPointerCapture(rig.rows[4]);
    rig.scrollTo(30);
    try rig.settle();
    try testing.expectEqual(@as(?usize, 4), rig.hovered());
    rig.cx.handleMouseUp(50, 15);
    try testing.expectEqual(@as(?usize, 1), rig.hovered());
    const hits_after_up = rig.reconcileHitTests();
    try rig.settle();
    try testing.expectEqual(hits_after_up, rig.reconcileHitTests());
    try testing.expectEqual(@as(?usize, 1), rig.hovered());
}

test "hover: pointer outside the window or after a platform leave is not re-resolved" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    // Outside the content area (a drag or release can report positions outside).
    rig.cx.handleMouseMove(50, 15);
    rig.cx.handleMouseMove(-10, -10);
    try testing.expectEqual(@as(?usize, null), rig.hovered());
    var hits = rig.reconcileHitTests();
    rig.scrollTo(60);
    try rig.settle();
    try testing.expectEqual(@as(?usize, null), rig.hovered());
    try testing.expectEqual(hits, rig.reconcileHitTests());

    // Platform leave (macOS tracking-area exit, Windows WM_MOUSELEAVE, Wayland
    // wl_pointer.leave): the last position is stale.
    rig.cx.handleMouseMove(50, 15);
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
    rig.cx.handlePointerLeave();
    try testing.expectEqual(@as(?usize, null), rig.hovered());
    try testing.expectEqual(@as(u32, 1), rig.log.leaves[2]);
    try testing.expect(!rig.cx.pointerLive());
    hits = rig.reconcileHitTests();
    rig.scrollTo(0);
    try rig.settle();
    try testing.expectEqual(@as(?usize, null), rig.hovered());
    try testing.expectEqual(hits, rig.reconcileHitTests());
}

test "hover: an inactive window keeps following content scrolled under the pointer" {
    // Native: macOS activeAlways tracking areas (AppKit's hover controls), Win32 mouse messages
    // and wheel routing, and Wayland pointer focus are all independent of activation, and
    // inactive windows scroll under the pointer. Activation must not freeze hover.
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 15);
    try testing.expectEqual(@as(?usize, 0), rig.hovered());
    rig.cx.window_active = false;
    try testing.expect(rig.cx.pointerLive());
    const hits = rig.reconcileHitTests();
    // Wheel-scroll of the background window under the resting pointer.
    rig.scrollTo(60);
    rig.frame();
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
    try testing.expectEqual(hits + 1, rig.reconcileHitTests());
    try testing.expectEqual(@as(u32, 1), rig.log.leaves[0]);
    try testing.expectEqual(@as(u32, 1), rig.log.enters[2]);
    // A hover move in the inactive window is a hover move.
    rig.cx.handleMouseMove(50, 95);
    try testing.expectEqual(@as(?usize, 5), rig.hovered());
    try rig.settle();
}

test "hover: covered by another window, then uncovered under a resting pointer" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 15);
    try testing.expectEqual(@as(?usize, 0), rig.hovered());
    // Another window is ordered over the resting pointer: the platform reports a leave while the
    // position is unchanged and still inside the content.
    rig.cx.handlePointerLeave();
    try testing.expectEqual(@as(?usize, null), rig.hovered());
    try testing.expectEqual(@as(u32, 1), rig.log.leaves[0]);
    // Content scrolled while covered: nothing under the other window may hover.
    const hits = rig.reconcileHitTests();
    rig.scrollTo(30);
    try rig.settle();
    try testing.expectEqual(@as(?usize, null), rig.hovered());
    try testing.expectEqual(hits, rig.reconcileHitTests());
    // The window moves away: the platform re-delivers the unchanged position as a move, which
    // hovers what is under it now and resumes re-resolution.
    rig.cx.handleMouseMove(50, 15);
    try testing.expectEqual(@as(?usize, 1), rig.hovered());
    try testing.expectEqual(@as(u32, 1), rig.log.enters[1]);
    rig.scrollTo(60);
    rig.frame();
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
    try rig.settle();
}

test "hover: windows reconcile independently" {
    var a = try Rig.init(0);
    defer a.deinit();
    var b = try Rig.init(1);
    defer b.deinit();
    a.cx.handleMouseMove(50, 15);
    b.cx.handleMouseMove(50, 15);
    const b_hits = b.reconcileHitTests();
    a.scrollTo(60);
    a.frame();
    b.frame();
    try testing.expectEqual(@as(?usize, 2), a.hovered());
    try testing.expectEqual(@as(?usize, 0), b.hovered());
    try testing.expectEqual(b_hits, b.reconcileHitTests());
    try testing.expectEqual(@as(u32, 0), b.log.leaves[0]);
}

test "hover: a leave callback that moves content again converges" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    const Bump = struct {
        var target: ?*Rig = null;
        fn onLeave(_: *anyopaque) void {
            const r = target orelse return;
            target = null;
            r.scrollTo(90);
        }
    };
    rig.cx.handleMouseMove(50, 15);
    Bump.target = &rig;
    rig.rows[0].behavior.events.on_leave = ui.Cx.simpleHandler(Bump.onLeave, @ptrCast(&rig));
    rig.scrollTo(30);
    try rig.settle();
    // Left row 0 at offset 30 (onto row 1), the callback scrolled to 90: row 3 ends up hovered.
    try testing.expectEqual(@as(?usize, 3), rig.hovered());
    try testing.expectEqual(@as(u32, 1), rig.log.enters[3]);
}

test "hover: a platform drag session over the window suspends re-resolution until it ends" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 15);
    // OS drag enters (kind 0) and moves (kind 1): no pointer motion is delivered meanwhile.
    rig.cx.handleDrag(50, 15, 0, "");
    rig.cx.handleDrag(50, 15, 1, "");
    const hits = rig.reconcileHitTests();
    rig.scrollTo(60);
    try rig.settle();
    try testing.expectEqual(hits, rig.reconcileHitTests());
    try testing.expectEqual(@as(?usize, 0), rig.hovered());
    // The session leaves the window (kind 2): the next pointer event re-establishes the position.
    rig.cx.handleDrag(50, 15, 2, "");
    rig.cx.handleMouseMove(50, 15);
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
}

test "hover: a full hit-scene rebuild also re-resolves hover" {
    var rig = try Rig.init(0);
    defer rig.deinit();
    rig.cx.handleMouseMove(50, 15);
    // A structural change that forces the full (not partial) index rebuild path. (The partial
    // path bumps the epoch separately; disabling the bump in HitRuntime.clear fails only this.)
    rig.scrollTo(60);
    rig.content.markRuntimeIndexFullRebuild();
    rig.frame();
    try testing.expectEqual(@as(?usize, 2), rig.hovered());
}
