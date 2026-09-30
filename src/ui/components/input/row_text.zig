const std = @import("std");
const core = @import("../../core.zig");

/// VirtualList retains each row after the renderer returns. Neither a shared
/// composition scratch buffer nor a mutable document is a valid text owner.
/// Allocate with the node's Cx allocator so ContentTable can release the copy.
/// Prepare before publishing; a failed copy leaves the previous row intact.
pub fn set(node: *core.Node, cx: *core.Cx, content: []const u8, color: core.Color, font_size: f32) !void {
    const old = node.getText();
    const same_content = if (old) |text| text.owned and std.mem.eql(u8, text.content, content) else false;
    if (same_content and core.Color.eql(old.?.color, color) and old.?.font_size == font_size) return;
    const bytes = if (same_content) old.?.content else try cx.allocator.dupe(u8, content);
    node.setText(.{ .content = bytes, .owned = true, .color = color, .font_size = font_size });
    if (!same_content or old.?.font_size != font_size) node.markSizingDirty();
    node.markRenderDirty();
}

/// A failed row copy must be retried even without a further editing event.
pub fn retry(cx: *core.Cx, node: *core.Node) void {
    node.markLayoutDirty();
    cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
}

test "VirtualList refresh and recycling release owned row snapshots" {
    const t = std.testing;
    const list = @import("../virtual_list/mod.zig");
    const Scope = @import("../../reactive.zig").Scope;
    const Rows = struct {
        generation: usize = 0,
        fn render(node: *core.Node, index: usize, cx: *core.Cx, context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var scratch: [80]u8 = undefined;
            const text = std.fmt.bufPrint(&scratch, "row-{d}-generation-{d}", .{ index, self.generation }) catch unreachable;
            set(node, cx, text, core.Color.BLACK, 14) catch unreachable;
        }
    };
    var cx = try core.Cx.init(t.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 96 } }, .{});
    cx.root = root;
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    var rows: Rows = .{};
    const mounted = try list.VirtualList(.{ .item_count = 40, .item_height = 24, .width = 320, .height = 96, .overscan = 0 }).mountWithContext(scope, cx, &rows, null, Rows.render);
    try root.appendChild(t.allocator, mounted.container);
    for (0..12) |generation| {
        rows.generation = generation;
        mounted.state.scroll_state.scroll_y = @floatFromInt(generation * 48);
        cx.layout();
        mounted.state.updateVisibleItems();
        list.refreshRange(mounted.state, 0, 40);
        var count: usize = 0;
        for (mounted.state.pool_bindings, mounted.state.pool_nodes) |binding, row| {
            const index = binding orelse continue;
            var expected: [80]u8 = undefined;
            try t.expectEqualStrings(try std.fmt.bufPrint(&expected, "row-{d}-generation-{d}", .{ index, generation }), row.getText().?.content);
            try t.expect(row.getText().?.owned);
            count += 1;
        }
        try t.expect(count > 0);
    }
}
