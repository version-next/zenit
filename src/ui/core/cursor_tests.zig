const std = @import("std");
const ui = @import("../core.zig");
const testing = std.testing;

const Fixture = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    a: *ui.Node,
    b: *ui.Node,

    fn init() !Fixture {
        const cx = try ui.Cx.init(testing.allocator);
        errdefer cx.deinit();
        cx.setViewport(300, 100);
        const root = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .direction = .row }, .{});
        cx.root = root;
        const a = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .cursor = .pointer }, .{});
        try root.appendChild(cx.allocator, a);
        const b = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .cursor = .text }, .{});
        try root.appendChild(cx.allocator, b);
        cx.layout();
        return .{ .cx = cx, .root = root, .a = a, .b = b };
    }
};

fn regionQuery(_: *const ui.Node, x: f32, _: f32, _: ?*anyopaque) ?ui.CursorRegion {
    return if (x < 50) .{ .shape = .ew_resize, .id = 42 } else null;
}

test "cursor: stationary style update survives automation consuming scene dirtiness" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.cx.handleMouseMove(150, 20);
    try testing.expectEqual(ui.CursorShape.text, f.cx.current_cursor);
    f.b.setCursor(.crosshair);
    f.cx.updateAutomationCursor(20, 20, false);
    f.cx.layout();
    try testing.expectEqual(ui.CursorShape.crosshair, f.cx.current_cursor);
    try testing.expectEqual(ui.CursorShape.pointer, f.cx.virtual_cursor.shape);
    try testing.expectEqual(@as(f32, 150), f.cx.mouse_x);
    try testing.expectEqual(ui.cursor.Source.style, f.cx.cursor_state.decision.source);
}

test "cursor: query only applies on live hit ancestry, not owner lifetime" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.a.setCursorQuery(regionQuery, null);
    f.cx.handleMouseMove(20, 20);
    try testing.expectEqual(ui.CursorShape.ew_resize, f.cx.current_cursor);
    try testing.expectEqual(@as(u64, 42), f.cx.cursor_state.decision.region_id);
    f.cx.handleMouseMove(150, 20);
    try testing.expectEqual(ui.CursorShape.text, f.cx.current_cursor);
    f.cx.handleMouseMove(70, 20);
    try testing.expectEqual(ui.CursorShape.pointer, f.cx.current_cursor);
}

test "cursor: stationary geometry and occlusion replace the decision without callbacks" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.a.setCursorQuery(regionQuery, null);
    f.cx.handleMouseMove(20, 20);
    f.a.setTranslateX(200);
    f.cx.layout();
    try testing.expectEqual(ui.CursorShape.default, f.cx.current_cursor);
    f.a.setTranslateX(0);
    f.cx.layout();
    try testing.expectEqual(ui.CursorShape.ew_resize, f.cx.current_cursor);
    const overlay = try ui.box(f.cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .position = .absolute, .cursor = .not_allowed }, .{});
    overlay.style.ensureExtPanic(f.cx.allocator).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    try f.root.appendChild(f.cx.allocator, overlay);
    f.cx.layout();
    try testing.expect(overlay.globalRect().contains(20, 20));
    try testing.expectEqual(ui.CursorShape.not_allowed, f.cx.current_cursor);
    f.cx.detachChild(f.root, overlay);
    f.cx.freeNode(overlay);
    f.cx.layout();
    try testing.expectEqual(ui.CursorShape.ew_resize, f.cx.current_cursor);
}

test "cursor: same-owner leases compose, updates do not steal order, release is exact" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.cx.handleMouseMove(20, 20);
    f.cx.setPointerCapture(f.a);
    const first = try f.cx.acquireCursor(f.a, .grabbing);
    f.cx.setPointerCapture(f.a); // Reasserting capture is not a new session.
    try testing.expectEqual(ui.CursorShape.grabbing, f.cx.current_cursor);
    const second = try f.cx.acquireCursor(f.a, .ew_resize);
    f.cx.updateCursor(first, .crosshair);
    try testing.expectEqual(ui.CursorShape.ew_resize, f.cx.current_cursor);
    f.cx.setCursorOverride(.wait);
    try testing.expectEqual(ui.CursorShape.ew_resize, f.cx.current_cursor);
    f.cx.releaseCursor(second);
    try testing.expectEqual(ui.CursorShape.crosshair, f.cx.current_cursor);
    f.cx.releaseCursor(second);
    try testing.expectEqual(ui.CursorShape.crosshair, f.cx.current_cursor);
    f.cx.setCursorOverride(null);
    f.cx.releasePointerCapture();
    try testing.expectEqual(ui.CursorShape.pointer, f.cx.current_cursor);
    try testing.expectEqual(@as(usize, 0), f.cx.cursor_state.leases.items.len);
}

test "cursor: capture epochs reject stale tokens including same-owner reacquisition" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.cx.setPointerCapture(f.a);
    const old = try f.cx.acquireCursor(f.a, .grabbing);
    f.cx.dispatcher.releasePointerCapture();
    f.cx.dispatcher.setPointerCapture(f.a);
    const current = try f.cx.acquireCursor(f.a, .ew_resize);
    f.cx.releaseCursor(old);
    try testing.expectEqual(ui.CursorShape.ew_resize, f.cx.current_cursor);
    try testing.expectEqual(current.id, f.cx.cursor_state.decision.token.?.id);
    try testing.expectError(error.NoPointerCapture, f.cx.acquireCursor(f.b, .text));
}

test "cursor: replacing capture immediately drops the previous owner's cursor" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.cx.handleMouseMove(150, 20);
    f.cx.setPointerCapture(f.a);
    _ = try f.cx.acquireCursor(f.a, .grabbing);
    f.cx.setPointerCapture(f.b);
    try testing.expectEqual(ui.CursorShape.text, f.cx.current_cursor);
    try testing.expectEqual(@as(usize, 0), f.cx.cursor_state.leases.items.len);
}

test "cursor: blur cancels raw capture and calls loss callback once" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    var lost: usize = 0;
    f.a.cursor_query_context = &lost;
    f.a.on_capture_lost = struct {
        fn call(node: *ui.Node) void {
            const n: *usize = @ptrCast(@alignCast(node.cursor_query_context.?));
            n.* += 1;
        }
    }.call;
    f.cx.handleMouseMove(150, 20);
    f.cx.setPointerCapture(f.a);
    _ = try f.cx.acquireCursor(f.a, .grabbing);
    f.cx.cancelPointerInteractions(.window_blur);
    f.cx.cancelPointerInteractions(.window_blur);
    try testing.expectEqual(@as(usize, 1), lost);
    try testing.expect(!f.cx.dispatcher.hasPointerCapture());
    try testing.expectEqual(ui.CursorShape.text, f.cx.current_cursor);
}

test "cursor: detach invalidates leases without a mouse leave" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.cx.handleMouseMove(20, 20);
    f.cx.setPointerCapture(f.a);
    _ = try f.cx.acquireCursor(f.a, .grabbing);
    f.cx.detachChild(f.root, f.a);
    f.cx.freeNode(f.a);
    f.cx.layout();
    try testing.expectEqual(ui.CursorShape.text, f.cx.current_cursor);
    try testing.expectEqual(@as(usize, 0), f.cx.cursor_state.leases.items.len);
}

test "cursor: tokens from another window cannot release an equal-numbered lease" {
    const a = try Fixture.init();
    defer a.cx.deinit();
    const b = try Fixture.init();
    defer b.cx.deinit();
    a.cx.setPointerCapture(a.a);
    b.cx.setPointerCapture(b.a);
    const ta = try a.cx.acquireCursor(a.a, .grabbing);
    const tb = try b.cx.acquireCursor(b.a, .ew_resize);
    try testing.expectEqual(ta.id, tb.id);
    b.cx.releaseCursor(ta);
    try testing.expectEqual(ui.CursorShape.ew_resize, b.cx.current_cursor);
}

test "cursor: native handoff is different from defer and hidden" {
    const f = try Fixture.init();
    defer f.cx.deinit();
    f.a.setCursor(.uncontrolled);
    f.cx.handleMouseMove(20, 20);
    try testing.expectEqual(ui.CursorShape.uncontrolled, f.cx.current_cursor);
    f.cx.handleMouseMove(150, 20);
    try testing.expectEqual(ui.CursorShape.text, f.cx.current_cursor);
}

test "cursor: leave callback may destroy the next hover target" {
    var f = try Fixture.init();
    defer f.cx.deinit();
    f.a.behavior.events.event_context = &f;
    f.a.behavior.events.on_event = struct {
        fn call(event: ui.Event, context: ?*anyopaque) ui.EventResult {
            if (event == .mouse_leave) {
                const fixture: *Fixture = @ptrCast(@alignCast(context.?));
                fixture.cx.detachChild(fixture.root, fixture.b);
                fixture.cx.freeNode(fixture.b);
            }
            return .ignored;
        }
    }.call;
    f.cx.handleMouseMove(20, 20);
    f.cx.handleMouseMove(150, 20);
    try testing.expectEqual(ui.CursorShape.default, f.cx.current_cursor);
    try testing.expect(f.cx.hovered_handle == null);
}
