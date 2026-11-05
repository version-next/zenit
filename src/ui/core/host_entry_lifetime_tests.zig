//! Host entry (handleX / fireDueTimers) nodes freed synchronously during lifetime regression.
//! Background: host entry drains owner batch at exitHost, effect's freeNode uses owner reactive
//! deferred queue (freed post-effect), no tick_depth gate. Single window drain after
//! cx_input.handleX returns; cross-window nesting (A handler drives B entry) puts B drain in A
//! dispatch stack—if B's effect frees A's node, equivalent to A's handler directly freeNode.
//! Covers: cross-window effect-freed, single-window handler-direct-freed.
const std = @import("std");
const ui = @import("../core.zig");
const Scope = @import("../reactive.zig").Scope;
const Signal = @import("../reactive.zig").Signal;
const testing = std.testing;

const Cx = ui.Cx;
const Node = ui.Node;
const box = ui.box;

/// Allocator wrapper poisons (0xaa) on free. `Allocator.destroy` doesn't overwrite, freed Node
/// still reads valid parent/id, dereferencing returns 0xaa… -> crash immediately.
const Poison = struct {
    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(_: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        return testing.allocator.rawAlloc(len, a, ra);
    }
    fn resize(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        return testing.allocator.rawResize(m, a, n, ra);
    }
    fn remap(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        return testing.allocator.rawRemap(m, a, n, ra);
    }
    fn free(_: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        @memset(m, 0xaa);
        if (quarantine_on) {
            // Isolate: don't return, test-end verify still 0xaa (catch 'use-after-free').
            quarantine.append(testing.allocator, .{ .mem = m, .alignment = a }) catch @panic("OOM: quarantine");
            return;
        }
        testing.allocator.rawFree(m, a, ra);
    }

    const Held = struct { mem: []u8, alignment: std.mem.Alignment };
    var quarantine: std.ArrayListUnmanaged(Held) = .empty;
    var quarantine_on = false;

    /// Start isolation: freed memory post-poison held, `endQuarantine` verifies untouched then
    /// batch-return.
    fn beginQuarantine() void {
        quarantine_on = true;
    }

    /// Return count of 'use-after-free' modified blocks, return all quarantined memory.
    fn endQuarantine() usize {
        quarantine_on = false;
        var dirty: usize = 0;
        for (quarantine.items) |h| {
            for (h.mem) |byte| {
                if (byte != 0xaa) {
                    dirty += 1;
                    break;
                }
            }
            testing.allocator.rawFree(h.mem, h.alignment, @returnAddress());
        }
        quarantine.clearAndFree(testing.allocator);
        return dirty;
    }
};

/// Window B: button, click writes signal; B's effect on true signal frees 'some A window node'.
const WindowB = struct {
    cx: *Cx,
    scope: *Scope,
    trigger: *Signal(bool),
    victim_cx: ?*Cx = null,
    victim: ?*Node = null,
    freed: bool = false,

    fn init(self: *WindowB) !void {
        self.cx = try Cx.init(Poison.allocator(), std.testing.io);
        errdefer self.cx.deinit();
        self.cx.setViewport(100, 100);
        const root = try box(self.cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
        self.cx.root = root;
        root.behavior.events.on_click = Cx.handlerFrom(WindowB, self, onClick);
        self.scope = try Scope.init(Poison.allocator(), null, self.cx.owner);
        self.trigger = try self.scope.createSignal(bool, false);
        try self.scope.createEffect(self, run);
        self.cx.layout();
    }

    fn deinit(self: *WindowB) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn onClick(self: *WindowB) void {
        self.trigger.set(true);
    }

    fn run(self: *WindowB) void {
        if (!self.trigger.get() or self.freed) return;
        const cx = self.victim_cx orelse return;
        const victim = self.victim orelse return;
        self.freed = true;
        if (victim.parent) |p| cx.detachChild(p, victim);
        cx.freeNode(victim);
    }

    /// Use B's real host entry (enterHost/exitHost), effect drains at B exitHost.
    fn poke(self: *WindowB) void {
        self.cx.handleClick(50, 50);
    }
};

// -- Cross-window: A's click handler drives B entry, B's effect frees A's target and parent --
// Bubble chain must skip freed ancestors, continue to living root, no UAF.
test "cross-window: B's effect frees A's click target subtree during A's dispatch" {
    var b: WindowB = undefined;
    try b.init();
    defer b.deinit();

    const A = struct {
        b: *WindowB,
        target_clicks: u32 = 0,
        container_clicks: u32 = 0,
        root_clicks: u32 = 0,
        fn onTarget(self: *@This()) void {
            self.target_clicks += 1;
            self.b.poke();
        }
        fn onContainer(self: *@This()) void {
            self.container_clicks += 1;
        }
        fn onRoot(self: *@This()) void {
            self.root_clicks += 1;
        }
    };
    var a_state: A = .{ .b = &b };

    var cx_a = try Cx.init(Poison.allocator(), std.testing.io);
    defer cx_a.deinit();
    cx_a.setViewport(200, 100);
    const root = try box(cx_a, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    root.behavior.events.on_click = Cx.handlerFrom(A, &a_state, A.onRoot);
    cx_a.root = root;
    const container = try box(cx_a, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    container.behavior.events.on_click = Cx.handlerFrom(A, &a_state, A.onContainer);
    try root.appendChild(cx_a.allocator, container);
    const target = try box(cx_a, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    target.behavior.events.on_click = Cx.handlerFrom(A, &a_state, A.onTarget);
    try container.appendChild(cx_a.allocator, target);
    cx_a.layout();
    _ = cx_a.render();

    b.victim_cx = cx_a;
    b.victim = container;

    cx_a.handleClick(10, 10);
    try testing.expect(b.freed);
    try testing.expectEqual(@as(u32, 1), a_state.target_clicks);
    try testing.expectEqual(@as(u32, 0), a_state.container_clicks);
    try testing.expectEqual(@as(u32, 1), a_state.root_clicks);
    try testing.expect(cx_a.pressed_node == null);
    try testing.expect(cx_a.hovered_node == null);
    cx_a.layout();
    _ = cx_a.render();
    cx_a.handleClick(150, 50);
    try testing.expectEqual(@as(u32, 2), a_state.root_clicks);
}

// -- Cross-window: A's mouse_down handler drives B entry, B's effect frees A's target --
// Post-dispatch cx_input still does focus decision and pressed accounting, use only handle.
test "cross-window: B's effect frees A's mouse-down target before A's focus/pressed bookkeeping" {
    var b: WindowB = undefined;
    try b.init();
    defer b.deinit();

    const A = struct {
        var bb: *WindowB = undefined;
        fn onEvent(ev: ui.Event, _: ?*anyopaque) ui.EventResult {
            if (ev == .mouse_down) bb.poke();
            return .ignored;
        }
    };
    A.bb = &b;

    var cx_a = try Cx.init(Poison.allocator(), std.testing.io);
    defer cx_a.deinit();
    cx_a.setViewport(200, 100);
    const root = try box(cx_a, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx_a.root = root;
    const target = try box(cx_a, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    target.behavior.events.on_event = A.onEvent;
    target.behavior.interaction.focusable = true;
    try root.appendChild(cx_a.allocator, target);
    cx_a.layout();
    _ = cx_a.render();

    b.victim_cx = cx_a;
    b.victim = target;

    cx_a.handleMouseDown(10, 10, .{});
    try testing.expect(b.freed);
    try testing.expect(cx_a.pressed_node == null);
    try testing.expect(cx_a.focus_manager.getFocused() == null);
    cx_a.handleMouseUp(10, 10);
    cx_a.layout();
    _ = cx_a.render();
}

// -- Cross-window: A's Enter key_down handler drives B entry, B's effect frees A's focused node --
// key_down unhandled, handleKeyDown still synthesizes click on original focused, must only
// synthesize for living+still-focused.
test "cross-window: B's effect frees A's focused node inside A's Enter key_down handler" {
    var b: WindowB = undefined;
    try b.init();
    defer b.deinit();

    const A = struct {
        var bb: *WindowB = undefined;
        var clicks: u32 = 0;
        fn onEvent(ev: ui.Event, _: ?*anyopaque) ui.EventResult {
            switch (ev) {
                .key_down => bb.poke(),
                .click => clicks += 1,
                else => {},
            }
            return .ignored;
        }
    };
    A.bb = &b;
    A.clicks = 0;

    var cx_a = try Cx.init(Poison.allocator(), std.testing.io);
    defer cx_a.deinit();
    cx_a.setViewport(200, 100);
    const root = try box(cx_a, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx_a.root = root;
    const target = try box(cx_a, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    target.behavior.events.on_event = A.onEvent;
    target.behavior.interaction.focusable = true;
    try root.appendChild(cx_a.allocator, target);
    cx_a.layout();
    _ = cx_a.render();
    cx_a.focus_manager.setFocus(target);
    try testing.expect(cx_a.focus_manager.getFocused() == target);

    b.victim_cx = cx_a;
    b.victim = target;

    cx_a.handleKeyDown(.@"return", .{});
    try testing.expect(b.freed);
    try testing.expectEqual(@as(u32, 0), A.clicks);
    try testing.expect(cx_a.focus_manager.getFocused() == null);
    cx_a.handleKeyUp(.@"return", .{});
    cx_a.layout();
    _ = cx_a.render();
}

// -- Drag: entered handler freed target itself (single window, handler direct-free) --
// handleDragPayload re-emits entered then dispatches updated and records drag_hover_handle; both
// can't use pre-emit bare ptr.
const DropZones = struct {
    cx: *Cx,
    root: *Node,
    left: *Node,
    right: *Node,
    left_enters: u32 = 0,
    left_leaves: u32 = 0,
    left_updates: u32 = 0,
    /// Left received entered, synchronized re-enter one handleDrag (same Cx) here.
    reenter_on_left_enter: ?[2]f32 = null,
    /// Left received exited, synchronized re-enter one handleDrag (same Cx) here.
    reenter_on_left_leave: ?[2]f32 = null,
    right_drops: u32 = 0,
    right_leaves: u32 = 0,
    /// Right received entered, synchronized re-enter one handleDrag (same Cx) here.
    reenter_on_right_enter: ?[2]f32 = null,
    right_enters: u32 = 0,
    right_updates: u32 = 0,
    free_on_left_enter: ?*Node = null,
    free_on_left_leave: ?*Node = null,
    free_on_left_enter_via: ?*WindowB = null,

    fn build(self: *DropZones) !void {
        self.cx = try Cx.init(Poison.allocator(), std.testing.io);
        errdefer self.cx.deinit();
        self.cx.setViewport(300, 100);
        self.root = try ui.hstack(self.cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
        self.cx.root = self.root;
        self.left = try box(self.cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
        self.left.behavior.events.on_drag_enter = Cx.handlerFrom(DropZones, self, onLeftEnter);
        self.left.behavior.events.on_drag_leave = Cx.handlerFrom(DropZones, self, onLeftLeave);
        self.left.behavior.events.on_event = onLeftEvent;
        self.left.behavior.events.event_context = self;
        try self.root.appendChild(self.cx.allocator, self.left);
        self.right = try box(self.cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
        self.right.behavior.events.on_drag_enter = Cx.handlerFrom(DropZones, self, onRightEnter);
        self.right.behavior.events.on_drag_leave = Cx.handlerFrom(DropZones, self, onRightLeave);
        self.right.behavior.events.on_event = onRightEvent;
        self.right.behavior.events.event_context = self;
        try self.root.appendChild(self.cx.allocator, self.right);
        self.cx.layout();
        _ = self.cx.render();
    }

    fn freeNow(self: *DropZones, victim: *Node) void {
        if (victim.parent) |p| self.cx.detachChild(p, victim);
        self.cx.freeNode(victim);
    }

    fn onLeftEnter(self: *DropZones) void {
        self.left_enters += 1;
        if (self.reenter_on_left_enter) |pos| {
            self.reenter_on_left_enter = null;
            self.cx.handleDrag(pos[0], pos[1], drag_updated, "");
        }
        if (self.free_on_left_enter) |v| {
            self.free_on_left_enter = null;
            self.freeNow(v);
        }
        if (self.free_on_left_enter_via) |wb| {
            self.free_on_left_enter_via = null;
            wb.poke();
        }
    }

    fn onLeftLeave(self: *DropZones) void {
        self.left_leaves += 1;
        if (self.reenter_on_left_leave) |pos| {
            self.reenter_on_left_leave = null;
            self.cx.handleDrag(pos[0], pos[1], drag_updated, "");
        }
        if (self.free_on_left_leave) |v| {
            self.free_on_left_leave = null;
            self.freeNow(v);
        }
    }

    fn onRightEnter(self: *DropZones) void {
        self.right_enters += 1;
        if (self.reenter_on_right_enter) |pos| {
            self.reenter_on_right_enter = null;
            self.cx.handleDrag(pos[0], pos[1], drag_updated, "");
        }
    }

    fn onRightLeave(self: *DropZones) void {
        self.right_leaves += 1;
    }

    fn onLeftEvent(ev: ui.Event, ctx: ?*anyopaque) ui.EventResult {
        const self: *DropZones = @ptrCast(@alignCast(ctx.?));
        if (ev == .drag and ev.drag.kind == .updated) self.left_updates += 1;
        return .ignored;
    }

    fn onRightEvent(ev: ui.Event, ctx: ?*anyopaque) ui.EventResult {
        const self: *DropZones = @ptrCast(@alignCast(ctx.?));
        if (ev == .drag and ev.drag.kind == .updated) self.right_updates += 1;
        if (ev == .drag and ev.drag.kind == .dropped) self.right_drops += 1;
        return .ignored;
    }
};

const drag_entered: u8 = 0;
const drag_updated: u8 = 1;
const drag_exited: u8 = 2;

test "drag: entered handler freeing its own drop target does not dispatch updated to the freed node" {
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();
    z.free_on_left_enter = z.left;

    // First position is updated: re-emit entered (handler frees target), dispatch updated.
    z.cx.handleDrag(50, 50, drag_updated, "");
    try testing.expectEqual(@as(u32, 1), z.left_enters);
    try testing.expectEqual(@as(u32, 0), z.left_updates);
    try testing.expect(z.cx.drag_hover_handle == null);
    z.cx.handleDrag(0, 0, drag_exited, "");
}

test "drag: leave handler of the old target freeing the new target skips its entered/updated" {
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();

    z.cx.handleDrag(50, 50, drag_entered, "");
    try testing.expectEqual(@as(u32, 1), z.left_enters);

    // Move to right: first give left exited (handler frees right), right's entered/updated must
    // skip.
    z.free_on_left_leave = z.right;
    z.cx.handleDrag(150, 50, drag_updated, "");
    try testing.expectEqual(@as(u32, 0), z.right_enters);
    try testing.expectEqual(@as(u32, 0), z.right_updates);
    try testing.expect(z.cx.drag_hover_handle == null);
    z.cx.handleDrag(0, 0, drag_exited, "");
}

test "cross-window: B's effect frees A's drop target from inside A's drag-enter handler" {
    var b: WindowB = undefined;
    try b.init();
    defer b.deinit();
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();
    b.victim_cx = z.cx;
    b.victim = z.left;
    z.free_on_left_enter_via = &b;

    z.cx.handleDrag(50, 50, drag_updated, "");
    try testing.expect(b.freed);
    try testing.expectEqual(@as(u32, 1), z.left_enters);
    try testing.expectEqual(@as(u32, 0), z.left_updates);
    try testing.expect(z.cx.drag_hover_handle == null);
}

// -- Timers: callback triggered earlier in batch clearTimer'd another due-now timer --
// clearTimer contract: 'never callback afterward': component unmount + cleanup clearTimer and free
// context typical, due-now timer if fires would be context UAF.
test "timers: clearing a timer that is due in the same firing round suppresses it" {
    var cx = try Cx.init(Poison.allocator(), std.testing.io);
    defer cx.deinit();

    const Rec = struct {
        cx: *Cx,
        other: u64 = 0,
        first_fired: u32 = 0,
        second_fired: u32 = 0,
        fn first(ctx: ?*anyopaque) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            r.first_fired += 1;
            r.cx.clearTimer(r.other);
        }
        fn second(ctx: ?*anyopaque) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            r.second_fired += 1;
        }
    };
    var rec: Rec = .{ .cx = cx };
    // Both 0-delay: same batch by order; first clears second.
    _ = try cx.setTimer(0, Rec.first, &rec);
    rec.other = try cx.setTimer(0, Rec.second, &rec);
    cx.fireDueTimers();
    try testing.expectEqual(@as(u32, 1), rec.first_fired);
    try testing.expectEqual(@as(u32, 0), rec.second_fired);
    // Cleared timer never fires again.
    cx.fireDueTimers();
    try testing.expectEqual(@as(u32, 0), rec.second_fired);
}

// Same contract UAF: first callback like component cleanup clearTimer and frees second timer's
// context. Pre-fix, second callback still ran with freed (poisoned) context.
test "timers: a callback that clears and frees another due timer's context does not trigger it" {
    var cx = try Cx.init(Poison.allocator(), std.testing.io);
    defer cx.deinit();

    const Victim = struct {
        const magic: u64 = 0x7117_7117_7117_7117;
        tag: u64 = magic,
        fn cb(ctx: ?*anyopaque) void {
            const v: *@This() = @ptrCast(@alignCast(ctx.?));
            if (v.tag != magic) @panic("定时器回调拿到了已释放的 context");
        }
    };
    const Killer = struct {
        cx: *Cx,
        victim_timer: u64 = 0,
        victim: ?*Victim = null,
        fn cb(ctx: ?*anyopaque) void {
            const k: *@This() = @ptrCast(@alignCast(ctx.?));
            k.cx.clearTimer(k.victim_timer);
            Poison.allocator().destroy(k.victim.?);
            k.victim = null;
        }
    };
    var killer: Killer = .{ .cx = cx };
    const victim = try Poison.allocator().create(Victim);
    victim.* = .{};
    killer.victim = victim;
    _ = try cx.setTimer(0, Killer.cb, &killer);
    killer.victim_timer = try cx.setTimer(0, Victim.cb, victim);
    cx.fireDueTimers();
    try testing.expect(killer.victim == null);
}

// -- Drag: prior target freed by a before_render hook during the event's hit refresh --
// handleDragPayload ensureHitTestSceneFresh, then hitTestQuery (internal refresh). A hook frees the
// prior target and the deferred free drains; a prior target *Node taken before the refresh points
// to freed memory. Must resolve after all refreshes. (Refreshes between frames re-run hooks only
// after a scene mutation, so a hook keeping the tree dirty no longer runs twice in one event; the
// hook frees on its first run, inside the refresh.)
test "drag: previous target freed by a hook during the hit-test refresh gets no exited dispatch" {
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();

    const Hook = struct {
        var cx: ?*Cx = null;
        var victim: ?*Node = null;
        var armed_calls: u32 = 0;
        var armed = false;
        fn tick(node: *Node) void {
            if (!armed) return;
            armed_calls += 1;
            node.markRenderDirty();
            if (armed_calls == 1) {
                armed = false;
                const v = victim.?;
                if (v.parent) |p| cx.?.detachChild(p, v);
                cx.?.freeNode(v);
            }
        }
    };
    Hook.cx = z.cx;
    Hook.victim = z.left;
    Hook.armed_calls = 0;
    Hook.armed = false;
    defer {
        Hook.cx = null;
        Hook.victim = null;
        Hook.armed = false;
    }
    z.root.meta.per_frame.hooks.before_render.main = Hook.tick;

    z.cx.handleDrag(50, 50, drag_entered, "");
    try testing.expectEqual(@as(u32, 1), z.left_enters);

    Hook.armed = true;
    z.root.markRenderDirty();
    z.cx.handleDrag(150, 50, drag_updated, "");
    // Hook freed the prior target inside this event's hit refresh (pre-fix crashed here); the
    // event's further refreshes coalesced into that one tick.
    try testing.expect(!Hook.armed);
    try testing.expectEqual(@as(u32, 1), Hook.armed_calls);
    z.cx.handleDrag(0, 0, drag_exited, "");
}

// -- cancelScrollGesture: cancelled owner's handler freed inertia owner --
// Both owners non-null impossible in real input (event_dispatcher exhaustive test locks), white-box
// construct: contract requires re-resolve before second dispatch, not bare ptr from pre-dispatch.
test "scroll: cancelScrollGesture does not dispatch momentum-ended to an owner freed by the cancelled handler" {
    var cx = try Cx.init(Poison.allocator(), std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 100);
    const root = try ui.hstack(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;

    const Rec = struct {
        var cx_ref: *Cx = undefined;
        var victim: ?*Node = null;
        var momentum_ended: u32 = 0;
        fn session(ev: ui.Event, _: ?*anyopaque) ui.EventResult {
            if (ev == .scroll and ev.scroll.phase == .cancelled) {
                if (victim) |v| {
                    victim = null;
                    if (v.parent) |p| cx_ref.detachChild(p, v);
                    cx_ref.freeNode(v);
                }
            }
            return .stop;
        }
        fn momentum(ev: ui.Event, _: ?*anyopaque) ui.EventResult {
            if (ev == .scroll and ev.scroll.momentum == .ended) momentum_ended += 1;
            return .stop;
        }
    };
    const session_node = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    session_node.behavior.events.on_event = Rec.session;
    try root.appendChild(cx.allocator, session_node);
    const momentum_node = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    momentum_node.behavior.events.on_event = Rec.momentum;
    try root.appendChild(cx.allocator, momentum_node);
    cx.layout();
    _ = cx.render();

    Rec.cx_ref = cx;
    Rec.victim = momentum_node;
    Rec.momentum_ended = 0;
    cx.dispatcher.scroll_session_owner = cx.node_registry.handleFor(session_node);
    cx.dispatcher.scroll_momentum_owner = cx.node_registry.handleFor(momentum_node);

    cx.dispatcher.cancelScrollGesture();
    try testing.expect(Rec.victim == null);
    try testing.expectEqual(@as(u32, 0), Rec.momentum_ended);
}

// -- drag.Manager termination: user cleanup code unmounted drag source component --
// Binding owns scope; scope.dispose destroys Binding, then destroys prior-registered callback
// context (reverse cleanup). Termination cleanup runs user code (on_capture_lost, hover resync
// triggers mouse_enter/leave, termination callback itself) afterwards, can't dereference Binding,
// termination callback delivered exactly once before context destroy (design doc §11.3).
const drag_mod = @import("../interaction/drag.zig");

const DragCtx = struct {
    const magic: u64 = 0xd7a9_d7a9_d7a9_d7a9;
    tag: u64 = magic,
    starts: u32 = 0,
    ends: u32 = 0,
    cancels: u32 = 0,
    last_reason: ?drag_mod.CancelReason = null,
    /// External counter: context freed but test still reads result.
    out: *DragOut,
    dispose_on_cancel: ?*Scope = null,

    fn cb(ev: drag_mod.Event, raw: *anyopaque) void {
        const self: *DragCtx = @ptrCast(@alignCast(raw));
        if (self.tag != magic) @panic("drag 回调拿到了已释放的 context");
        switch (ev.phase) {
            .start => self.out.starts += 1,
            .move => {},
            .end => self.out.ends += 1,
            .cancel => {
                self.out.cancels += 1;
                self.out.last_reason = ev.cancel_reason;
                if (self.dispose_on_cancel) |s| {
                    self.dispose_on_cancel = null;
                    DragUnmount.scope_disposed = true;
                    s.dispose();
                }
            },
        }
    }

    fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*DragCtx, @ptrCast(@alignCast(ptr))));
    }
};

const DragOut = struct {
    starts: u32 = 0,
    ends: u32 = 0,
    cancels: u32 = 0,
    last_reason: ?drag_mod.CancelReason = null,
};

const DragUnmount = struct {
    cx: *Cx,
    root: *Node,
    source: *Node,
    other: *Node,
    scope: *Scope,
    ctx: *DragCtx,
    out: DragOut = .{},

    var dispose_target: ?*Scope = null;
    /// Scope.dispose frees scope itself, can't read scope.disposed after.
    var scope_disposed = false;

    fn init(self: *DragUnmount) !void {
        DragUnmount.scope_disposed = false;
        DragUnmount.dispose_target = null;
        DragUnmount.dispose_on_enter = false;
        self.out = .{};
        self.cx = try Cx.init(Poison.allocator(), std.testing.io);
        errdefer self.cx.deinit();
        self.cx.setViewport(300, 100);
        self.root = try ui.hstack(self.cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
        self.cx.root = self.root;
        self.source = try box(self.cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
        try self.root.appendChild(self.cx.allocator, self.source);
        self.other = try box(self.cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
        self.other.behavior.events.on_event = onOtherEvent;
        try self.root.appendChild(self.cx.allocator, self.other);
        self.scope = try Scope.init(Poison.allocator(), null, self.cx.owner);
        // Context registered first, Binding second: reverse cleanup, Binding destroyed before
        // context.
        self.ctx = try Poison.allocator().create(DragCtx);
        self.ctx.* = .{ .out = &self.out };
        try self.scope.registerResource(self.ctx, DragCtx.destroy);
        _ = try drag_mod.Binding.attach(self.scope, self.cx, self.source, .{ .activation_distance = 4, .active_cursor = null }, DragCtx.cb, self.ctx);
        self.cx.layout();
        _ = self.cx.render();
    }

    fn deinit(self: *DragUnmount) void {
        if (!DragUnmount.scope_disposed) self.scope.dispose();
        DragUnmount.dispose_target = null;
        DragUnmount.scope_disposed = false;
        self.cx.deinit();
    }

    fn disposeNow() void {
        if (dispose_target) |s| {
            dispose_target = null;
            scope_disposed = true;
            s.dispose();
        }
    }

    /// Other received mouse_leave during hover resync, unmounted drag source.
    var dispose_on_enter = false;

    fn onOtherEvent(ev: ui.Event, _: ?*anyopaque) ui.EventResult {
        if (ev == .mouse_leave and dispose_on_enter) {
            dispose_on_enter = false;
            disposeNow();
        }
        return .ignored;
    }

    fn onCaptureLostDispose(_: *Node) void {
        disposeNow();
    }

    /// Press on source, drag to other (capture: hover not updated).
    fn startDragOverOther(self: *DragUnmount) !void {
        self.cx.handleMouseMove(10, 10);
        self.cx.handleMouseDown(10, 10, .{});
        self.cx.handleMouseMove(150, 10);
        try testing.expectEqual(@as(u32, 1), self.out.starts);
        try testing.expect(self.cx.dispatcher.hasPointerCapture());
    }
};

test "drag: hover handler unmounting the drag source during cancel's hover resync" {
    var d: DragUnmount = undefined;
    try d.init();
    defer d.deinit();
    try d.startDragOverOther();
    // Drag past threshold, that move already recorded other hover; continue move out of other,
    // hover not updated, cancel resync discovers pointer left other, re-emit mouse_leave.
    d.cx.handleMouseMove(250, 10);
    try testing.expect(d.cx.hovered_node == d.other);

    DragUnmount.dispose_target = d.scope;
    DragUnmount.dispose_on_enter = true;
    d.cx.cancelPointerInteractions(.window_blur);
    try testing.expect(DragUnmount.scope_disposed);
    try testing.expectEqual(@as(u32, 1), d.out.cancels);
    try testing.expectEqual(@as(?drag_mod.CancelReason, .window_blur), d.out.last_reason);
    try testing.expect(d.cx.drag_manager.session == null);
}

test "drag: cancel callback unmounting the drag source does not touch the freed binding" {
    var d: DragUnmount = undefined;
    try d.init();
    defer d.deinit();
    try d.startDragOverOther();

    d.ctx.dispose_on_cancel = d.scope;
    // Freed Binding if written later (machine.reset etc.), poison catch fails, isolation catches.
    Poison.beginQuarantine();
    d.cx.cancelPointerInteractions(.window_blur);
    const written_after_free = Poison.endQuarantine();
    try testing.expect(DragUnmount.scope_disposed);
    try testing.expectEqual(@as(u32, 1), d.out.cancels);
    try testing.expectEqual(@as(usize, 0), written_after_free);
}

test "drag: on_capture_lost unmounting the drag source during end still delivers end exactly once" {
    var d: DragUnmount = undefined;
    try d.init();
    defer d.deinit();
    try d.startDragOverOther();

    d.source.on_capture_lost = DragUnmount.onCaptureLostDispose;
    DragUnmount.dispose_target = d.scope;
    d.cx.handleMouseUp(160, 10);
    try testing.expect(DragUnmount.scope_disposed);
    try testing.expectEqual(@as(u32, 1), d.out.ends);
    try testing.expectEqual(@as(u32, 0), d.out.cancels);
}

// -- Drag: same Cx re-entry, outer must not overwrite inner's newer hover --
// Semantic: handleDragPayload re-entry, inner is newer pointer state. Outer commits its hover
// pre-callback, inner uses it to re-emit boundaries; once newer drag starts, outer dispatch void,
// can't write drag_hover_handle. Prevents stale hover overwriting.
test "drag: re-entrant drag event supersedes the outer one's hover bookkeeping" {
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();

    // Outer: first position hits left; left's entered handler re-enter once updated to right.
    z.reenter_on_left_enter = .{ 150, 50 };
    z.cx.handleDrag(50, 50, drag_updated, "");
    try testing.expectEqual(@as(u32, 1), z.left_enters);
    try testing.expectEqual(@as(u32, 1), z.left_leaves);
    try testing.expectEqual(@as(u32, 1), z.right_enters);
    try testing.expectEqual(@as(u32, 1), z.right_updates);
    // Outer superseded: don't dispatch its stale updated to left.
    try testing.expectEqual(@as(u32, 0), z.left_updates);
    // Hover is inner (latest) result.
    try testing.expect(z.cx.node_registry.resolve(z.cx.drag_hover_handle, null) == z.right);

    // Continue move within right: don't re-emit exited/entered.
    z.cx.handleDrag(160, 50, drag_updated, "");
    try testing.expectEqual(@as(u32, 1), z.right_enters);
    try testing.expectEqual(@as(u32, 1), z.left_leaves);
    try testing.expectEqual(@as(u32, 2), z.right_updates);
    z.cx.handleDrag(0, 0, drag_exited, "");
}

// -- Timers: callback nested fireDueTimers --
// 'This batch' = timers due when entering outermost fireDueTimers. Callback-set (including 0-delay)
// not this batch; nesting must not fire past-this-batch timers or repeat any this-batch timer.
test "timers: nested fireDueTimers fires nothing outside the outermost round and nothing twice" {
    var cx = try Cx.init(Poison.allocator(), std.testing.io);
    defer cx.deinit();

    const Rec = struct {
        var cx_ref: *Cx = undefined;
        var a: u32 = 0;
        var b: u32 = 0;
        var late: u32 = 0;
        var b_during_a: u32 = 0;
        var late_during_round: u32 = 0;
        fn onA(_: ?*anyopaque) void {
            a += 1;
            _ = cx_ref.setTimer(0, onLate, null) catch @panic("OOM");
            cx_ref.fireDueTimers();
            b_during_a = b;
            late_during_round = late;
        }
        fn onB(_: ?*anyopaque) void {
            b += 1;
            // B also nests: A already fired, late due but not this-batch.
            cx_ref.fireDueTimers();
            late_during_round += late;
        }
        fn onLate(_: ?*anyopaque) void {
            late += 1;
        }
    };
    Rec.cx_ref = cx;
    Rec.a = 0;
    Rec.b = 0;
    Rec.late = 0;
    Rec.b_during_a = 0;
    Rec.late_during_round = 0;
    _ = try cx.setTimer(0, Rec.onA, null);
    _ = try cx.setTimer(0, Rec.onB, null);

    cx.fireDueTimers();
    try testing.expectEqual(@as(u32, 1), Rec.a);
    try testing.expectEqual(@as(u32, 1), Rec.b);
    try testing.expectEqual(@as(u32, 0), Rec.late_during_round);
    try testing.expectEqual(@as(u32, 0), Rec.late);
    // Next batch triggers callback-set-new timers.
    cx.fireDueTimers();
    try testing.expectEqual(@as(u32, 1), Rec.late);
    try testing.expectEqual(@as(u32, 1), Rec.a);
    try testing.expectEqual(@as(u32, 1), Rec.b);
}

// -- Drag activation: setPointerCapture releasing old capture's on_capture_lost unmounts drag
// source --
// Activation sequence after setPointerCapture can't assume session still exists (destroyed with
// Binding post-release).
test "drag: previous capture owner's on_capture_lost unmounting the source during activation" {
    var d: DragUnmount = undefined;
    try d.init();
    defer d.deinit();
    // activation_distance = 0: mouse_down instant activate. Re-attach inconvenient, swap scope on
    // other instead.
    const scope2 = try Scope.init(Poison.allocator(), null, d.cx.owner);
    var disposed2 = false;
    defer if (!disposed2) scope2.dispose();
    const ctx2 = try Poison.allocator().create(DragCtx);
    ctx2.* = .{ .out = &d.out };
    try scope2.registerResource(ctx2, DragCtx.destroy);
    d.other.behavior.events.on_event = null;
    _ = try drag_mod.Binding.attach(scope2, d.cx, d.other, .{ .activation_distance = 0, .active_cursor = null }, DragCtx.cb, ctx2);
    d.cx.layout();
    _ = d.cx.render();

    // Source held capture first; its on_capture_lost unmounts other's drag component.
    const Lost = struct {
        var target: ?*Scope = null;
        var flag: *bool = undefined;
        fn onLost(_: *Node) void {
            if (target) |s| {
                target = null;
                flag.* = true;
                s.dispose();
            }
        }
    };
    Lost.target = scope2;
    Lost.flag = &disposed2;
    d.source.on_capture_lost = Lost.onLost;
    d.cx.setPointerCapture(d.source);

    d.cx.handleMouseDown(150, 10, .{});
    try testing.expect(disposed2);
    try testing.expect(d.cx.drag_manager.session == null);
    // Activation abort doesn't leave capture to node with no session.
    try testing.expect(!d.cx.dispatcher.hasPointerCapture());
    // Capture released, hover resync: pointer under new node.
    try testing.expect(d.cx.hovered_node == d.other);
    // Start never reached consumer: from user view drag never started, don't deliver cancel (§11.1
    // pending row).
    try testing.expectEqual(@as(u32, 0), d.out.starts);
    try testing.expectEqual(@as(u32, 0), d.out.cancels);
    d.cx.handleMouseUp(150, 10);
}

// Dropped carries payload, session terminal: despite re-emit boundary event re-entry replacement,
// deliver to still-living target anyway (yield boundary re-emit and hover write only), payload loss
// else.
test "drag: a superseded dropped event is still delivered to its live target" {
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();

    z.cx.handleDrag(50, 50, drag_entered, "");
    try testing.expectEqual(@as(u32, 1), z.left_enters);

    // Outer: drop on right; give left exited, handler re-enter one updated (same right).
    z.reenter_on_left_leave = .{ 160, 50 };
    z.cx.handleDrag(150, 50, 3, "/tmp/a.png");
    try testing.expectEqual(@as(u32, 1), z.left_leaves);
    // Inner already re-emitted right entered; outer replaced, don't re-emit duplicate, dropped
    // delivers anyway.
    try testing.expectEqual(@as(u32, 1), z.right_enters);
    try testing.expectEqual(@as(u32, 1), z.right_updates);
    try testing.expectEqual(@as(u32, 1), z.right_drops);
}

// Replaced dropped at entered handler re-entry (same target): target doesn't receive second
// entered.
test "drag: re-entry inside a dropped event's entered does not enter the target twice" {
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();

    z.cx.handleDrag(50, 50, drag_entered, "");
    z.reenter_on_right_enter = .{ 160, 50 };
    z.cx.handleDrag(150, 50, 3, "/tmp/a.png");
    try testing.expectEqual(@as(u32, 1), z.left_leaves);
    try testing.expectEqual(@as(u32, 1), z.right_enters);
    try testing.expectEqual(@as(u32, 1), z.right_updates);
    try testing.expectEqual(@as(u32, 1), z.right_drops);
    try testing.expectEqual(@as(u32, 0), z.right_leaves);
}

// Exited handler re-entry elsewhere: new target (not yet entered) doesn't receive exited.
test "drag: re-entry while leaving the old target never exits a target that was not entered" {
    var z: DropZones = .{ .cx = undefined, .root = undefined, .left = undefined, .right = undefined };
    try z.build();
    defer z.cx.deinit();

    z.cx.handleDrag(50, 50, drag_entered, "");
    z.reenter_on_left_leave = .{ 250, 50 };
    z.cx.handleDrag(150, 50, drag_updated, "");
    try testing.expectEqual(@as(u32, 1), z.left_leaves);
    try testing.expectEqual(@as(u32, 0), z.right_enters);
    try testing.expectEqual(@as(u32, 0), z.right_leaves);
    try testing.expectEqual(@as(u32, 0), z.right_updates);
    try testing.expect(z.cx.node_registry.resolve(z.cx.drag_hover_handle, null) == null);
}
