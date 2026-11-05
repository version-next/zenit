//! Real-window VirtualList hit probe: a list whose rows record the data index they were clicked
//! as. e2e scrolls it with a stream of wheel events and clicks right after, then checks the
//! clicked index against the row painted under the pointer (the hit index must follow row
//! recycling, fast jumps, both ends and measured variable heights without a stale frame).
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");

const W = ui.widgets;

var scope: ?*ui.Scope = null;
var panel: ?*ui.Node = null;
var list: ?*W.VirtualListState = null;
var clicked: ?usize = null;
var clicks: u32 = 0;

pub fn route(app: *zenit_app.App, path: []const u8, out: []u8) ?[]const u8 {
    const measured = std.mem.eql(u8, path, "/review/vlist-hit-mount-dynamic");
    if (measured or std.mem.eql(u8, path, "/review/vlist-hit-mount")) {
        mount(app, measured) catch |err| return std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/review/vlist-hit-state")) {
        const index: i64 = if (clicked) |c| @intCast(c) else -1;
        const scroll_y: f32 = if (list) |s| s.scroll_state.scroll_y else 0;
        return std.fmt.bufPrint(out, "{{\"ok\":true,\"clicked\":{d},\"clicks\":{d},\"scroll_y\":{d:.1}}}", .{ index, clicks, scroll_y }) catch null;
    }
    if (std.mem.eql(u8, path, "/review/vlist-hit-unmount")) {
        unmount(app);
        return "{\"ok\":true}";
    }
    return null;
}

fn rowHeight(index: usize, measured: bool) f32 {
    return if (measured) 20 + @as(f32, @floatFromInt(index % 5)) * 11 else 28;
}

fn renderRow(node: *ui.Node, index: usize, cx: *ui.Cx, measured: bool) void {
    const row = ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = rowHeight(index, measured) }, .background = if (index % 2 == 0) ui.Color.rgba(245, 245, 248, 255) else ui.Color.WHITE }, .{}) catch return;
    row.meta.ownership.meta.test_id = "review.vlist-hit.row";
    row.behavior.events.on_click = .{ .callback = onClick, .context = @ptrFromInt(index + 1) };
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "VRow {d}", .{index}) catch "VRow ?";
    const text = ui.text(cx, label, .{ .font_size = 12, .color = ui.Color.BLACK }) catch {
        node.appendChild(cx.allocator, row) catch cx.freeNode(row);
        return;
    };
    row.appendChild(cx.allocator, text) catch cx.freeNode(text);
    node.appendChild(cx.allocator, row) catch cx.freeNode(row);
}

fn renderFixed(node: *ui.Node, index: usize, cx: *ui.Cx) void {
    renderRow(node, index, cx, false);
}

fn renderMeasured(node: *ui.Node, index: usize, cx: *ui.Cx) void {
    renderRow(node, index, cx, true);
}

fn onClick(ctx: *anyopaque) void {
    clicked = @intFromPtr(ctx) - 1;
    clicks += 1;
}

fn mount(app: *zenit_app.App, measured: bool) !void {
    unmount(app);
    clicked = null;
    clicks = 0;
    const cx = app.cx;
    const s = try ui.Scope.init(app.allocator, null, cx.owner);
    errdefer s.dispose();
    const root = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 320 }, .height = .{ .px = 340 }, .background = ui.Color.WHITE, .padding = ui.Padding.all(10) }, .{});
    errdefer cx.freeNode(root);
    (try root.style.ensureExtFallible(app.allocator)).inset = .{ .left = .{ .px = 420 }, .top = .{ .px = 120 } };
    root.style.ensureExtPanic(app.allocator).z_index = 50;
    const result = if (measured)
        try W.VirtualList(.{ .item_count = 2000, .measure_items = true, .estimate_item_height = 40, .width = 300, .height = 320, .overscan = 3 }).mount(s, cx, renderMeasured)
    else
        try W.VirtualList(.{ .item_count = 1000, .item_height = 28, .width = 300, .height = 320, .overscan = 3 }).mount(s, cx, renderFixed);
    result.container.meta.ownership.meta.test_id = "review.vlist-hit.list";
    try root.appendChild(app.allocator, result.container);
    try cx.root.?.appendChild(app.allocator, root);
    scope = s;
    panel = root;
    list = result.state;
    cx.root.?.markLayoutDirty();
    cx.needs_redraw = true;
}

fn unmount(app: *zenit_app.App) void {
    const cx = app.cx;
    if (panel) |p| {
        if (p.parent) |parent| cx.detachChild(parent, p);
        cx.freeNode(p);
        cx.root.?.markLayoutDirty();
        cx.needs_redraw = true;
    }
    if (scope) |s| s.dispose();
    panel = null;
    scope = null;
    list = null;
}
