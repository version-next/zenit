//! Wire-format oracle: actual renderer vs the unchanged 80-byte Metal shader.
const std = @import("std");
const gpu = @import("gpu");
const text = @import("text");
const mod = @import("text_renderer.zig");
const a = std.testing.allocator;
const LegacyGlyph = extern struct {
    position: [2]f32, // Glyph bottom-left position.
    size: [2]f32, // Glyph size.
    uv_rect: [4]f32, // UV rect (u_min, v_min, u_max, v_max).
    color: [4]f32, // Color RGBA.
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 }, // x, y, w, h (logical pixels); negative size = disabled.
    skew_x: f32 = 0, // Synthetic italic x offset (logical pixels).
    page_index: f32 = 0, // Atlas page number (CPU bucketing, shader doesn't read).
    /// >0.5 = this glyph in BGRA color page; shader picks sample path per it (color direct output
    /// sample,
    /// not multiply text color).
    is_color: f32 = 0,
    /// >0.5 = vertex shader snap position to physical pixel (round). direct_animated text must set
    /// 0: each glyph
    /// fractional part differs, per-glyph round causes adjacent glyphs cross rounding threshold
    /// different frames,
    /// produce letter spacing / baseline jitter. per-instance not per-draw: nearest/linear lists
    /// mix multi-strategy
    /// (static composite italic, static scale text also linear list).
    shader_snap: f32 = 1,
};

fn upload(device: *gpu.Backend.Device, items: anytype) !?gpu.Backend.Buffer {
    if (items.len == 0) return null;
    const old = try a.alloc(LegacyGlyph, items.len);
    defer a.free(old);
    for (items, old) |g, *out| out.* = .{ .position = g.position, .size = g.size, .uv_rect = g.uv_rect.normalized(), .color = g.color, .rect_clip = g.rect_clip, .skew_x = g.skew_x, .page_index = @floatFromInt(g.metadata.pageIndex()), .is_color = @floatFromInt(g.metadata.colorMode()), .shader_snap = if (g.metadata.snaps()) 1 else 0 };
    var b = try device.createBuffer(a, .{ .size = old.len * @sizeOf(LegacyGlyph), .usage = .{ .vertex = true, .map_write = true } });
    @memcpy(try b.getMappedRange(0, b.size), std.mem.sliceAsBytes(old));
    return b;
}
fn drawOld(tr: *mod.TextRenderer, pass: *gpu.Backend.RenderPass, items: anytype, b: *gpu.Backend.Buffer, linear: bool) !void {
    pass.setVertexBuffer(0, &tr.uniform_buffers[tr.current_buffer], 0);
    pass.setFragmentBuffer(0, &tr.uniform_buffers[tr.current_buffer], 0);
    const smp = if (linear) tr.atlas.getSamplerLinear() else tr.atlas.getSamplerNearest();
    pass.setFragmentSampler(0, smp orelse return error.MissingSampler);
    var first: usize = 0;
    while (first < items.len) {
        const page = items[first].metadata.pageIndex();
        var end = first + 1;
        while (end < items.len and items[end].metadata.pageIndex() == page) : (end += 1) {}
        const t = tr.atlas.getPageTexture(page) orelse return error.MissingAtlasPage;
        const fallback = tr.atlas.getPageTexture(0) orelse t;
        const color = (tr.atlas.getPageFormat(page) orelse .gray) == .color;
        pass.setFragmentTextureBinding(0, if (color) fallback else t);
        pass.setFragmentTextureBinding(1, if (color) t else fallback);
        const off: u32 = @intCast(first * @sizeOf(LegacyGlyph));
        pass.setVertexBuffer(1, b, off);
        pass.setFragmentBuffer(1, b, off);
        pass.draw(6, @intCast(end - first), 0, 0);
        first = end;
    }
}

test "metal packed glyph metadata preserves the legacy 80-byte shader pixels" {
    var instance = try gpu.Backend.Instance.init(a, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    var tr = try mod.TextRenderer.init(a, &dq.device);
    defer tr.deinit();
    const Glyph = std.meta.Elem(@TypeOf(tr.instances_nearest.items));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Glyph));
    var fs = try text.FontSystem.init(a, std.testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 16 });
    defer font.deinit();
    var shader = try gpu.Backend.ShaderModule.initFromSource(&dq.device, @embedFile("testdata/text_instance_80.metal"));
    defer shader.deinit();
    var v = try shader.getFunction("text_vertex_main");
    defer v.deinit();
    var f = try shader.getFunction("text_fragment_main");
    defer f.deinit();
    var pso = try gpu.Backend.createRenderPipeline(&dq.device, .{ .vertex_function = &v, .fragment_function = &f, .color_attachment_formats = &.{gpu.color_format}, .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .rgb_operation = .add, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha, .alpha_operation = .add } });
    defer pso.deinit();
    var target = try dq.device.createTexture(a, .{ .size = .{ .width = 256, .height = 128 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true }, .memory = .host_upload });
    defer target.destroy();
    var reference = try dq.device.createTexture(a, .{ .size = .{ .width = 256, .height = 128 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true }, .memory = .host_upload });
    defer reference.destroy();
    const expected = try a.alloc(u8, 256 * 128 * 4);
    defer a.free(expected);
    const actual = try a.alloc(u8, expected.len);
    defer a.free(actual);
    var cases: usize = 0;
    for ([_]bool{ false, true }) |high_uv| for ([_]f32{ 1, 1.25, 2 }) |scale| for ([_]bool{ false, true }) |snap| for ([_]f32{ -4, 0, 4 }) |skew| for ([_][4]f32{ .{ 0, 0, -1, -1 }, .{ -0.125, -0.25, 256, 128 }, .{ 14.3, 16.7, 25.25, 18.5 }, .{ 0, 0, 0, 0 }, .{ -50, -40, 12, 16 } }) |clip| for (0..4) |shape| {
        tr.beginFrame(256 / scale, 128 / scale, scale);
        tr.current_rect_clip = clip;
        tr.clip_shape_kind = @intCast(shape);
        tr.clip_rect = .{ 4, 4, 80, 45 };
        tr.clip_radii = .{ 6, 0, 9, 3 };
        tr.clip_point_count = 3;
        tr.clip_contour_count = 1;
        tr.clip_polygon_end_points[0] = 3;
        tr.clip_polygon_points[0] = .{ 0, 0 };
        tr.clip_polygon_points[1] = .{ 80, 0 };
        tr.clip_polygon_points[2] = .{ 40, 45 };
        try tr.drawTextWithOptions("Ag中文😀", 8.37, 24.13, font, .{ .r = 0.2, .g = 0.7, .b = 0.3, .a = 0.65 }, 16, false, null, false, snap, 0);
        if (high_uv) {
            // Exercise odd texel coordinates near the far atlas edge and exactly 1.0,
            // with a nonempty pattern so an all-zero decode cannot pass vacuously.
            var gray: [64]u8 = undefined;
            var color: [256]u8 = undefined;
            for (0..64) |i| {
                gray[i] = @intCast(32 + (i * 17) % 224);
                color[i * 4] = @intCast((i * 29) % 192);
                color[i * 4 + 1] = @intCast((i * 13) % 192);
                color[i * 4 + 2] = @intCast((i * 7) % 192);
                color[i * 4 + 3] = 192;
            }
            // Pages carry UVs normalized by their own extent; this text fits
            // every format on its first page, so all pages share one extent.
            const extent = tr.atlas.pages[0].?.texture.size.width;
            for (tr.atlas.pages[0..tr.atlas.page_count]) |*maybe_page| {
                if (maybe_page.*) |*page| {
                    try std.testing.expectEqual(extent, page.texture.size.width);
                    const rgba = page.format != .gray;
                    try page.texture.writeRegion(0, extent - 8, extent - 8, 8, 8, if (rgba) &color else &gray, if (rgba) 32 else 8);
                }
            }
            const page_size: f32 = @floatFromInt(extent);
            const uv = @FieldType(Glyph, "uv_rect").init(.{ (page_size - 8) / page_size, (page_size - 7) / page_size, (page_size - 1) / page_size, 1 });
            for (tr.instances_nearest.items) |*g| g.uv_rect = uv;
            for (tr.instances_linear.items) |*g| g.uv_rect = uv;
        }
        for (tr.instances_nearest.items) |*g| g.skew_x = skew;
        for (tr.instances_linear.items) |*g| g.skew_x = skew;
        const nearest = try a.dupe(Glyph, tr.instances_nearest.items);
        defer a.free(nearest);
        const linear = try a.dupe(Glyph, tr.instances_linear.items);
        defer a.free(linear);
        var nb = try upload(&dq.device, nearest);
        defer if (nb) |*b| b.destroy();
        var lb = try upload(&dq.device, linear);
        defer if (lb) |*b| b.destroy();
        var enc = try gpu.Backend.CommandEncoder.init(&dq.queue);
        errdefer enc.deinit();
        var view = target.binding().createView();
        defer view.destroy();
        var pass = try enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        pass.setViewport(0, 0, 256, 128, 0, 1);
        try tr.flush(&pass);
        pass.end();
        var rv = reference.binding().createView();
        defer rv.destroy();
        var rp = try enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = rv, .load_op = .clear, .store_op = .store }} });
        rp.setViewport(0, 0, 256, 128, 0, 1);
        rp.setPipeline(&pso);
        if (nb) |*b| try drawOld(&tr, &rp, nearest, b, false);
        if (lb) |*b| try drawOld(&tr, &rp, linear, b, true);
        rp.end();
        var cmd = try enc.finish();
        defer cmd.deinit();
        cmd.submit();
        cmd.waitUntilCompleted();
        try target.readBgra8(256, 128, actual, 256 * 4);
        try reference.readBgra8(256, 128, expected, 256 * 4);
        if (!std.mem.eql(u8, actual, expected)) {
            std.debug.print("packed glyph mismatch scale={d} snap={} skew={d} clip={any} shape={d} high_uv={}\n", .{ scale, snap, skew, clip, shape, high_uv });
            return error.PackedGlyphPixelMismatch;
        }
        if (shape == 0 and clip[2] < 0) {
            var visible = false;
            for (0..256 * 128) |pixel| visible = visible or expected[pixel * 4] != 0 or expected[pixel * 4 + 1] != 0 or expected[pixel * 4 + 2] != 0;
            try std.testing.expect(visible);
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 720), cases);
}
