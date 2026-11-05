//! Native LP4 fixture: two independent setup scopes and renderer owners.
const std = @import("std");
const ui = @import("ui");
const app = @import("zenit_app");
const Probe = @import("_view.yix.zig").Probe;
const Remount = @import("_remount.yix.zig");
const Regions = @import("_regions.yix.zig");
const Persist = struct {
    signal: *ui.Signal(u32),
    key: []const u8,
    registered: bool = false,
    fn encode(ptr: *anyopaque, a: std.mem.Allocator) ![]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return std.fmt.allocPrint(a, "{d}", .{self.signal.peek()});
    }
    fn decode(ptr: *anyopaque, version: ?u32, value: ?[]const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (version == 1) if (value) |text| self.signal.set(try std.fmt.parseInt(u32, text, 10));
    }
    fn clear(self: *@This()) void {
        if (self.registered) app.dev_control.unpersist(self.key) catch {};
    }
};
fn persistCount(_: *ui.Scope, node: *ui.Node, key: []const u8) !void {
    if (comptime !app.dev_control.enabled) return;
    const i = ui.view.componentInstance(node).?;
    const ctx = try i.setup.createState(Persist, .{ .signal = @ptrCast(@alignCast(i.setup.signals.items[0])), .key = key });
    try i.setup.onCleanup(Persist, ctx, Persist.clear);
    try app.dev_control.persist(key, 1, ctx, Persist.encode, Persist.decode);
    ctx.registered = true;
}
const body = .{ .style = .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .padding = 16, .background = ui.Color.hex(0xffffff), .text_color = ui.Color.hex(0x202020), .font_size = 20 } };
fn mountA(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const root = try ui.view.render(scope, cx, ui.view.col(body, .{ Probe(.{ .start = 7 }), Remount.Parent(.{}), Regions.Regions(.{}), Regions.Slots(.{}), Regions.Moves(.{}), Regions.Branchless(.{}) }));
    try persistCount(scope, root.children.items[0], "lp4.count.a");
    try persistCount(scope, root.children.items[1], "lp4.r3.parent");
    // External host alias: child-only L2 root changes must stay in this portal.
    // App.mount owns cx.root and the window portal; keep that host root intact.
    try ui.view.mount(scope, cx, root, .{ui.view.portal(Regions.Row(.{ .id = "lp5.portal.value", .button = "lp5.portal.button" }))});
    return root;
}
fn mountB(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const root = try ui.view.render(scope, cx, ui.view.col(body, .{Probe(.{ .start = 19, .count_id = "lp4.count.b", .button_id = "lp4.increment.b", .label_id = "lp4.label.b", .style_id = "lp4.style.b" })}));
    try persistCount(scope, root.children.items[0], "lp4.count.b");
    return root;
}
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var application = app.MultiWindowApp.init(gpa.allocator(), .{ .pump_timeout_ms = 8 });
    defer application.deinit();
    _ = try application.createWindowWith(.{ .io = init.io, .window = .{ .width = 420, .height = 300, .title = "LP4 A", .persist_key = "lp4.a" } }, mountA);
    _ = try application.createWindowWith(.{ .io = init.io, .window = .{ .width = 420, .height = 300, .title = "LP4 B", .persist_key = "lp4.b" } }, mountB);
    try application.run();
}
