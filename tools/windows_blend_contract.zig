const std = @import("std");
const ui = @import("ui");
const modes = [_]ui.BlendMode{ .normal, .multiply, .screen, .overlay, .darken, .lighten, .color_dodge, .color_burn, .hard_light, .soft_light, .difference, .exclusion };
const ids = [_][]const u8{ "blend.normal", "blend.multiply", "blend.screen", "blend.overlay", "blend.darken", "blend.lighten", "blend.color-dodge", "blend.color-burn", "blend.hard-light", "blend.soft-light", "blend.difference", "blend.exclusion" };
const bg = ui.Color.rgba(128, 192, 64, 255);
const fg = ui.Color.rgba(192, 64, 128, 255);
fn box(cx: *ui.Cx, parent: *ui.Node, id: []const u8, color: ui.Color, opacity: f32) !*ui.Node {
    const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .background = color, .opacity = opacity }, .{});
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn foreground(cx: *ui.Cx, parent: *ui.Node, color: ui.Color, mode: ui.BlendMode, opacity: f32) !void {
    const node = try box(cx, parent, "", color, opacity);
    (try node.style.ensureExtFallible(cx.allocator)).blend_mode = mode;
}
fn clipped(ctx: ui.DrawContext, _: ?*anyopaque) anyerror!void {
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    // Literal clip tokens are already lowered to the active content frame.
    // An outer isolated group has a translucent background; the geometric
    // clip must retain it exactly instead of applying its alpha a second time.
    try dl.append(.{ .begin_opacity_layer = .{ .header = header, .x = ctx.render_x, .y = ctx.render_y, .w = 100, .h = 100, .opacity = 0.5 } });
    try dl.append(.{ .fill_rect = .{ .header = header, .x = 0, .y = 0, .w = 100, .h = 100, .color = ui.Color.rgba(255, 255, 0, 128) } });
    try dl.append(.{ .push_clip = .{ .header = header, .x = ctx.render_x, .y = ctx.render_y, .w = 100, .h = 100, .radii = @splat(30), .shape_kind = .rounded_rect } });
    try dl.append(.{ .begin_opacity_layer = .{ .header = header, .x = ctx.render_x, .y = ctx.render_y, .w = 100, .h = 100, .opacity = 1, .blend_mode = .multiply } });
    try dl.append(.{ .fill_rect = .{ .header = header, .x = 0, .y = 0, .w = 100, .h = 100, .color = ui.Color.rgba(0, 255, 255, 255) } });
    try dl.append(.{ .end_opacity_layer = .{ .header = header } });
    try dl.append(.{ .pop_clip = .{ .header = header } });
    try dl.append(.{ .end_opacity_layer = .{ .header = header } });
}
pub fn mount(cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 340 }, .flex_shrink = 0, .direction = .column, .gap = 12 }, .{});
    for (0..2) |row_index| {
        const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
        try root.appendChild(cx.allocator, row);
        for (0..6) |column| {
            const i = row_index * 6 + column;
            const node = try box(cx, row, ids[i], bg, 1);
            try foreground(cx, node, fg, modes[i], 1);
        }
    }
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, row);
    const alpha = try box(cx, row, "blend.alpha", bg, 1);
    try foreground(cx, alpha, ui.Color.rgba(192, 64, 128, 128), .screen, 0.5);
    const nested = try box(cx, row, "blend.nested", ui.Color.rgba(255, 255, 0, 255), 0.5);
    try foreground(cx, nested, ui.Color.rgba(0, 255, 255, 255), .multiply, 1);
    const round = try box(cx, row, "blend.rounded", bg, 1);
    (try round.style.ensureExtFallible(cx.allocator)).corner_radius = .{ .all = 30 };
    round.style.overflow_hidden = true;
    try foreground(cx, round, fg, .multiply, 1);
    const rotated = try box(cx, row, "blend.rotated", bg, 1);
    const child = try box(cx, rotated, "", fg, 1);
    child.setRotate(cx.allocator, std.math.pi / 2.0);
    (try child.style.ensureExtFallible(cx.allocator)).corner_radius = .{ .all = 30 };
    child.style.overflow_hidden = true;
    (try child.style.ensureExtFallible(cx.allocator)).blend_mode = .multiply;
    const clip = try box(cx, row, "blend.clip-translucent", ui.Color.TRANSPARENT, 1);
    clip.setCustomDraw(clipped, null);
    return root;
}
