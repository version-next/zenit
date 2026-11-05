//! Gallery-only native capture loss -> SDK -> App cancellation contract.
//! Seeds owned queues; never changes native focus/capture or injects desktop input.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetCapture() callconv(.winapi) ?*anyopaque;
extern fn zenit_windows_contract_move(*anyopaque, usize, isize) c_int;
extern fn zenit_windows_contract_press(*anyopaque, c_int, c_int, c_int) c_int;
extern fn zenit_windows_contract_key(*anyopaque, u16, u32, c_int) c_int;
var clicks: usize = 0;
var lost: usize = 0;
fn require(comptime stage: []const u8, ok: bool) !void {
    if (!ok) {
        std.log.err("Windows pointer contract stage={s}", .{stage});
        return error.PointerContractFailed;
    }
}
fn pump(app: *App) !void {
    _ = try app.sdk.pump(0);
    for (app.sdk.events()) |event| app.processTestContractEvent(event);
}
fn press(app: *App, x: c_int, y: c_int) !void {
    try require("press.inject", zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 0, x, y) != 0);
    try pump(app);
}
fn release(app: *App, x: c_int, y: c_int) !void {
    const point = @as(u32, @as(u16, @intCast(x))) | (@as(u32, @as(u16, @intCast(y))) << 16);
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x202, 0, @as(isize, @as(i32, @bitCast(point))));
    try pump(app);
}
fn sendPoint(app: *App, message: u32, x: c_int, y: c_int) !void {
    try sendPointFlags(app, message, x, y, 0);
}
fn sendPointFlags(app: *App, message: u32, x: c_int, y: c_int, flags: usize) !void {
    const point = @as(u32, @as(u16, @truncate(@as(u32, @bitCast(x))))) |
        (@as(u32, @as(u16, @truncate(@as(u32, @bitCast(y))))) << 16);
    const packed_point: isize = @as(i32, @bitCast(point));
    if (message == 0x200) {
        try require("move.inject", zenit_windows_contract_move(app.win.getNativeSurfaceHandle(), flags, packed_point) != 0);
        return;
    }
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), message, flags, packed_point);
}
fn batchedDrag(app: *App, node: *ui.Node, x: c_int, y: c_int) !void {
    const drag = ui.interaction.drag;
    const Record = struct {
        starts: usize = 0,
        moves: usize = 0,
        ends: usize = 0,
        cancels: usize = 0,
        delta: f32 = 0,
        fn event(e: drag.Event, raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (e.phase) {
                .start => self.starts += 1,
                .move => self.moves += 1,
                .end => {
                    self.ends += 1;
                    self.delta = e.delta.x;
                },
                .cancel => self.cancels += 1,
            }
        }
    };
    var record = Record{};
    const scope = try ui.Scope.init(app.cx.allocator, null, app.cx.owner);
    defer scope.dispose();
    _ = try drag.Binding.attach(scope, app.cx, node, .{}, Record.event, &record);
    app.cx.layout();
    clicks = 0;
    const metrics = @TypeOf(app.win).inputQueueMetrics();
    // All messages arrive before a single SDK pump. A key separates the two
    // move bursts; an up separates the last move from the drag sequence.
    try require("batched.press.inject", zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 0, x, y) != 0);
    try sendPoint(app, 0x200, x + 8, y);
    try sendPoint(app, 0x200, x + 20, y);
    try require("batched.key.inject", zenit_windows_contract_key(app.win.getNativeSurfaceHandle(), 0x87, 0, 1) != 0); // Owned F24 separator.
    try sendPoint(app, 0x200, x + 35, y);
    try sendPoint(app, 0x200, x + 40, y);
    try sendPoint(app, 0x202, x + 40, y);
    try sendPoint(app, 0x200, x + 45, y);
    _ = try app.sdk.pump(0);
    const events = app.sdk.events();
    errdefer {
        // Inspect the existing batch; another pump would change the contract.
        std.log.err("Windows pointer batch events={any}", .{events});
        std.log.err("Windows pointer batch record={any} clicks={d} capture={} drag_session={} coalesced_before={d} coalesced_after={d} scale={d}", .{
            record,                       clicks,                                                    app.cx.dispatcher.hasPointerCapture(), app.cx.drag_manager.session != null,
            metrics.mouse_move_coalesced, @TypeOf(app.win).inputQueueMetrics().mouse_move_coalesced, app.win.getScaleFactor(),
        });
    }
    try require("batched.event-count", events.len == 6);
    try require("batched.press-order", events[0] == .mouse_button and events[0].mouse_button.pressed);
    try require("batched.move-key-order", events[1] == .mouse_move and events[2] == .key and events[3] == .mouse_move);
    try require("batched.release-order", events[4] == .mouse_button and !events[4].mouse_button.pressed and events[5] == .mouse_move);
    const scale = app.win.getScaleFactor();
    try require("batched.first-delta", @abs(events[1].mouse_move.dx - 20 / scale) < 0.01);
    try require("batched.second-delta", @abs(events[3].mouse_move.dx - 20 / scale) < 0.01);
    try require("batched.post-release-delta", @abs(events[5].mouse_move.dx - 5 / scale) < 0.01);
    for (events) |event| app.processTestContractEvent(event);
    try require("batched.drag-phases", record.starts == 1 and record.moves >= 1 and record.ends == 1 and record.cancels == 0);
    try require("batched.drag-delta-and-clicks", @abs(record.delta - 40 / scale) < 0.01 and clicks == 0);
    try require("batched.capture-released", !app.cx.dispatcher.hasPointerCapture() and app.cx.drag_manager.session == null);
    try require("batched.coalescing", @TypeOf(app.win).inputQueueMetrics().mouse_move_coalesced >= metrics.mouse_move_coalesced + 2);
}
pub fn run(app: *App, node: *ui.Node) !void {
    const foreground = GetForegroundWindow();
    const capture = GetCapture();
    // Never risk releasing an attended session's OS capture.
    if (capture != null) std.log.err("Windows pointer initial OS capture={any}", .{capture});
    try require("initial.os-capture-free", capture == null);
    const old_click = node.behavior.events.on_click;
    const old_lost = node.on_capture_lost;
    defer {
        _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x215, 0, 0);
        pump(app) catch {};
        app.cx.cancelPointerInteractions(.explicit);
        node.behavior.events.on_click = old_click;
        node.on_capture_lost = old_lost;
    }
    errdefer std.log.err("Windows pointer failure foreground_before={any} foreground_after={any} capture_before={any} capture_after={any} node={any} scale={d} clicks={d} lost={d}", .{
        foreground, GetForegroundWindow(), capture, GetCapture(), node.globalRect(), app.win.getScaleFactor(), clicks, lost,
    });
    node.behavior.events.on_click = ui.Cx.simpleHandler(struct {
        fn clicked(_: *anyopaque) void {
            clicks += 1;
        }
    }.clicked, app);
    node.on_capture_lost = struct {
        fn cancelled(_: *ui.Node) void {
            lost += 1;
        }
    }.cancelled;
    const rect = node.globalRect();
    const scale = app.win.getScaleFactor();
    const x: c_int = @intFromFloat((rect.x + rect.w / 2) * scale);
    const y: c_int = @intFromFloat((rect.y + rect.h / 2) * scale);
    for ([_]u32{ 0x215, 0x8, 0x1f }) |message| { // capture changed, kill focus, cancel mode.
        clicks = 0;
        lost = 0;
        errdefer std.log.err("Windows pointer cancellation message=0x{x} clicks={d} lost={d} ui_capture={} native_left={}", .{
            message, clicks, lost, app.cx.dispatcher.hasPointerCapture(), app.win.isMouseButtonPressed(.left),
        });
        try press(app, x, y);
        app.cx.dispatcher.setPointerCapture(node);
        try require("cancel.press-captured", app.cx.dispatcher.hasPointerCapture() and app.win.isMouseButtonPressed(.left));
        _ = SendMessageW(app.win.getNativeSurfaceHandle(), message, 0, 0);
        try pump(app);
        try require("cancel.native-and-ui-released", !app.cx.dispatcher.hasPointerCapture() and !app.win.isMouseButtonPressed(.left));
        try require("cancel.callback-once", lost == 1 and clicks == 0);
        // Duplicate native cancellation must be idempotent; a late up must not click.
        _ = SendMessageW(app.win.getNativeSurfaceHandle(), message, 0, 0);
        try release(app, x, y);
        try require("cancel.duplicate-and-late-up", lost == 1 and clicks == 0);
        try press(app, x, y);
        try release(app, x, y);
        try require("cancel.next-click-recovers", clicks == 1);
    }
    // Releasing one button preserves the other native button state.
    try require("buttons.left-inject", zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 0, x, y) != 0);
    try require("buttons.right-inject", zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 1, x, y) != 0);
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x205, 0, 0);
    try require("buttons.right-release-preserves-left", app.win.isMouseButtonPressed(.left) and !app.win.isMouseButtonPressed(.right));
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x215, 0, 0);
    try pump(app);
    try require("buttons.cancel-clears-left", !app.win.isMouseButtonPressed(.left));
    // Negative client coordinates and the message's Shift/Ctrl snapshot must
    // survive scaling. Modifier changes also prevent adjacent coalescing.
    try sendPointFlags(app, 0x200, -20, -15, 12);
    try sendPointFlags(app, 0x200, -10, -5, 12);
    try sendPointFlags(app, 0x200, -10, -5, 0);
    _ = try app.sdk.pump(0);
    {
        const negative = app.sdk.events();
        errdefer std.log.err("Windows pointer negative-coordinate batch={any} scale={d}", .{ negative, scale });
        try require("negative.event-count-and-types", negative.len == 2 and negative[0] == .mouse_move and negative[1] == .mouse_move);
        try require("negative.x", @abs(negative[0].mouse_move.x - (-10 / scale)) < 0.01);
        try require("negative.y", @abs(negative[0].mouse_move.y - (-5 / scale)) < 0.01);
        try require("negative.modifiers-set", negative[0].mouse_move.modifiers.shift and negative[0].mouse_move.modifiers.ctrl);
        try require("negative.modifiers-cleared", !negative[1].mouse_move.modifiers.shift and !negative[1].mouse_move.modifiers.ctrl);
        for (negative) |event| app.processTestContractEvent(event);
    }
    try batchedDrag(app, node, x, y);
    try require("final.foreground-and-capture", GetForegroundWindow() == foreground and GetCapture() == capture);
}
