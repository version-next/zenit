//! Poisoned atlas contents probe, registered only by the macOS test harness.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

pub fn route(app: *App, path: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.eql(u8, path, "/review/glyph-gutter-poison") and !std.mem.eql(u8, path, "/review/glyph-gutter-clear")) return null;
    return probe(app, path, out) catch |err| std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
}
fn probe(app: *App, path: []const u8, out: []u8) ![]const u8 {
    app.renderer.frame_sync.drain(3);
    const atlas = &app.renderer.text_renderer.atlas;
    var regions: usize = 0;
    if (std.mem.endsWith(u8, path, "poison")) {
        const stage = try ui.box(app.cx, .{ .position = .absolute, .width = .{ .px = 380 }, .height = .{ .px = 220 }, .background = ui.Color.WHITE }, .{});
        (try stage.style.ensureExtFallible(app.allocator)).inset = .{ .left = .{ .px = 400 }, .top = .{ .px = 350 } };
        stage.meta.ownership.meta.test_id = "review.glyph-gutter.stage";
        const transformed = try ui.box(app.cx, .{ .position = .absolute, .width = .{ .px = 230 }, .height = .{ .px = 80 }, .rotate = 0.19, .scale_x = 1.37, .scale_y = 1.37 }, .{});
        (try transformed.style.ensureExtFallible(app.allocator)).inset = .{ .left = .{ .px = 65.3 }, .top = .{ .px = 60.7 } };
        try transformed.appendChild(app.allocator, try ui.text(app.cx, "IIII WMWM", .{ .font_size = 34, .color = ui.Color.BLACK }));
        try stage.appendChild(app.allocator, transformed);
        try app.cx.root.?.appendChild(app.allocator, stage);
        app.cx.root.?.markLayoutDirty();
        const max_size = @TypeOf(atlas.*).ATLAS_SIZE;
        const poison = try app.allocator.alloc(u8, max_size * max_size);
        defer app.allocator.free(poison);
        @memset(poison, 255);
        for (atlas.pages[0..atlas.page_count]) |*slot| {
            const page = &slot.*.?;
            if (page.format != .gray) continue;
            const size = page.texture.size;
            try page.texture.writeRegion(0, 0, 0, size.width, size.height, poison, size.width);
            page.packer.current_x = 0;
            page.packer.current_y = 0;
            page.packer.current_row_height = 0;
        }
        atlas.cache.clearRetainingCapacity();
        app.renderer.text_renderer.prewarm_signature_valid = false;
    } else {
        // Oracle: write only the reserved 1px outer ring, never glyph pixels.
        // If production upload already owns that ring this does not change any
        // visible pixels; a change exposes sampling of undefined page contents.
        const max_size = @TypeOf(atlas.*).ATLAS_SIZE;
        const zeros: [max_size + 2]u8 = @splat(0);
        var it = atlas.cache.iterator();
        while (it.next()) |entry| {
            const region = entry.value_ptr;
            if (region.width == 0 or region.height == 0) continue;
            const page = &atlas.pages[region.page_index].?;
            if (page.format != .gray) continue;
            const page_width: f32 = @floatFromInt(page.texture.size.width);
            const page_height: f32 = @floatFromInt(page.texture.size.height);
            const x: u32 = @intFromFloat(@round(region.uv_min[0] * page_width));
            const y: u32 = @intFromFloat(@round(region.uv_min[1] * page_height));
            const w: u32 = @intCast(region.width);
            const h: u32 = @intCast(region.height);
            try page.texture.writeRegion(0, x - 1, y - 1, w + 2, 1, zeros[0 .. w + 2], w + 2);
            try page.texture.writeRegion(0, x - 1, y + h, w + 2, 1, zeros[0 .. w + 2], w + 2);
            try page.texture.writeRegion(0, x - 1, y, 1, h, zeros[0..h], 1);
            try page.texture.writeRegion(0, x + w, y, 1, h, zeros[0..h], 1);
            regions += 1;
        }
    }
    app.renderer.offscreen_pool.invalidateRetainedContents();
    app.cx.root.?.markRenderDirty();
    app.cx.needs_redraw = true;
    return std.fmt.bufPrint(out, "{{\"ok\":true,\"cleared_regions\":{d},\"frame_count\":{d}}}", .{ regions, app.renderer.frame_count });
}
