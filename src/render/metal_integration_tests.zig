//! Tests that require a live Metal device.
//!
//! Keep this root separate from `render.zig`: `zig build test-headless` must be
//! runnable in a macOS session without a Metal device or WindowServer, while
//! `zig build test-metal` is a deliberate infrastructure contract.

const std = @import("std");
const gpu = @import("gpu");
const text = @import("text");
const atlas_mod = @import("glyph_atlas.zig");
const text_renderer_mod = @import("text_renderer.zig");

comptime {
    _ = @import("sdf_gpu_bench.zig");
    _ = @import("glass_material_tests.zig");
    _ = @import("packed_glyph_tests.zig");
    _ = @import("text_ink_tests.zig");
}

const GlyphAtlas = atlas_mod.GlyphAtlas;
const PageFormat = atlas_mod.PageFormat;
const packSubpixelBin = atlas_mod.packSubpixelBin;

test "metal textures carry PixelFormatView only when a foreign view format is declared" {
    const mtl = gpu.Backend.metal_bindings;
    const raw = mtl.metal_create_system_default_device() orelse return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw, .features = .{}, .limits = .{} };
    defer device.deinit();
    const pfv: c_ulong = @backingInt(mtl.MTLTextureUsage.PixelFormatView);
    const usage: gpu.TextureUsages = .{ .texture_binding = true, .render_attachment = true, .copy_src = true };
    var plain = try device.createTexture(std.testing.allocator, .{ .size = .{ .width = 8, .height = 8 }, .format = gpu.color_format, .usage = usage });
    defer plain.destroy();
    try std.testing.expectEqual(@as(c_ulong, 0), mtl.metal_texture_usage(plain.raw) & pfv);
    var host = try device.createTexture(std.testing.allocator, .{ .size = .{ .width = 8, .height = 8 }, .format = .r8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true }, .memory = .host_upload });
    defer host.destroy();
    try std.testing.expectEqual(@as(c_ulong, 0), mtl.metal_texture_usage(host.raw) & pfv);
    var viewed = try device.createTexture(std.testing.allocator, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .usage = usage, .view_formats = &.{.bgra8_unorm_srgb} });
    defer viewed.destroy();
    try std.testing.expectEqual(pfv, mtl.metal_texture_usage(viewed.raw) & pfv);
}

test "path slot rollback preserves distinct native buffer owners for retry" {
    const raw = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw, .features = .{}, .limits = .{} };
    defer device.deinit();
    var path = try @import("path_renderer.zig").PathRenderer.init(std.testing.allocator, &device);
    defer path.deinit();
    path.vertex_buffer = try device.createBuffer(std.testing.allocator, .{ .size = 256, .usage = .{ .vertex = true } });
    path.vertex_buffer_capacity = 256;
    path.parked_buffers[1] = try device.createBuffer(std.testing.allocator, .{ .size = 512, .usage = .{ .vertex = true } });
    path.parked_capacities[1] = 512;
    const previous = path.vertex_buffer.?.raw;
    const retry = path.parked_buffers[1].?.raw;
    path.restoreFrameBufferSlot(1);
    try std.testing.expectEqual(retry, path.vertex_buffer.?.raw);
    path.restoreFrameBufferSlot(0);
    try std.testing.expectEqual(previous, path.vertex_buffer.?.raw);
    try std.testing.expectEqual(retry, path.parked_buffers[1].?.raw);
    try std.testing.expectEqual(@as(usize, 256), path.vertex_buffer_capacity);
    try std.testing.expectEqual(@as(usize, 512), path.parked_capacities[1]);
    try std.testing.expect(path.parked_buffers[0] == null);
    path.restoreFrameBufferSlot(0); // Idempotent restoration cannot duplicate an owner.
    try std.testing.expect(path.parked_buffers[0] == null);
}

test "atlas first-page failure releases native sampler owners and permits clean retry" {
    const raw_device = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw_device, .features = .{}, .limits = .{} };
    defer device.deinit();
    device.fail_next_texture_for_testing = true;
    try std.testing.expectError(error.TextureCreationFailed, GlyphAtlas.init(std.testing.allocator, &device));
    try std.testing.expectEqual(@as(usize, 2), device.sampler_count);
    try std.testing.expectEqual(@as(usize, 0), device.samplers_live_for_testing);
    {
        var atlas = try GlyphAtlas.init(std.testing.allocator, &device);
        defer atlas.deinit();
        try std.testing.expectEqual(@as(u32, 1), atlas.page_count);
        try std.testing.expectEqual(@as(usize, 2), device.samplers_live_for_testing);
    }
    try std.testing.expectEqual(@as(usize, 0), device.samplers_live_for_testing);
}

test "metal atlas page size controls native allocation and rejects unsupported grids before allocation" {
    const raw_device = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw_device, .features = .{}, .limits = .{} };
    defer device.deinit();
    try std.testing.expectError(error.UnsupportedAtlasSize, GlyphAtlas.initWithPageSize(std.testing.allocator, &device, 3072));
    try std.testing.expectEqual(@as(usize, 0), device.sampler_count);
    // Default 2048 pages start each format on a small first page.
    for ([_][2]u32{ .{ 2048, GlyphAtlas.FIRST_PAGE_SIZE }, .{ 4096, 4096 } }) |sizes| {
        var atlas = try GlyphAtlas.initWithPageSize(std.testing.allocator, &device, sizes[0]);
        defer atlas.deinit();
        const page = atlas.pages[0].?;
        try std.testing.expectEqual(sizes[1], page.texture.size.width);
        try std.testing.expectEqual(sizes[1], page.texture.size.height);
        try std.testing.expectEqual(@as(u64, sizes[1]) * sizes[1], atlas.bytesUsed());
    }
}

test "a full small first page continues on default-size pages of the same format" {
    const raw_device = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw_device, .features = .{}, .limits = .{} };
    defer device.deinit();
    var atlas = try GlyphAtlas.initWithPageSize(std.testing.allocator, &device, 2048);
    defer atlas.deinit();
    var fs = try text.FontSystem.init(std.testing.allocator, std.testing.io);
    defer fs.deinit();
    // Large glyphs fill the 1024 first page within a few dozen insertions.
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 300 });
    defer font.deinit();
    var first_page_glyphs: u32 = 0;
    var spilled: ?@TypeOf(try atlas.getOrInsert(font, 0)) = null;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") |c| {
        const region = try atlas.getOrInsert(font, font.glyphIndexForCodepoint(c));
        if (region.page_index == 0) first_page_glyphs += 1 else {
            spilled = region;
            break;
        }
    }
    try std.testing.expect(first_page_glyphs > 1);
    const region = spilled orelse return error.FirstPageNeverFilled;
    try std.testing.expectEqual(@as(u32, GlyphAtlas.FIRST_PAGE_SIZE), atlas.pages[0].?.texture.size.width);
    try std.testing.expectEqual(@as(u32, 2048), atlas.pages[region.page_index].?.texture.size.width);
    // UVs are normalized per page: the spilled glyph's extent matches its texels.
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(region.width)), (region.uv_max[0] - region.uv_min[0]) * 2048, 0.001);
}

test "small atlas keeps oversized glyphs on a lazily allocated 4096 fallback page" {
    const raw_device = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw_device, .features = .{}, .limits = .{} };
    defer device.deinit();
    var atlas = try GlyphAtlas.initWithPageSize(std.testing.allocator, &device, 2048);
    defer atlas.deinit();
    var fs = try text.FontSystem.init(std.testing.allocator, std.testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 3072 });
    defer font.deinit();
    const glyph = font.glyphIndexForCodepoint('W');
    const region = try atlas.getOrInsert(font, glyph);
    try std.testing.expect(region.width > 2046 or region.height > 2046);
    try std.testing.expect(region.width > 0 and region.height > 0);
    try std.testing.expectEqual(@as(u32, 4096), atlas.pages[region.page_index].?.texture.size.width);
    // 1 MiB small first gray page + the 16 MiB fallback page.
    try std.testing.expectEqual(@as(u64, 17 * 1024 * 1024), atlas.bytesUsed());
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(region.width)), (region.uv_max[0] - region.uv_min[0]) * 4096, 0.001);
    const cached = try atlas.getOrInsert(font, glyph);
    try std.testing.expectEqual(region.page_index, cached.page_index);
    try std.testing.expectEqual(@as(u32, 2), atlas.page_count);
}

test "metal preflight + atlas: color and grayscale pages coexist" {
    const testing = std.testing;
    const mtl = gpu.Backend.metal_bindings;

    // A missing device is an infrastructure failure for `test-metal`, not a
    // skipped unit test hidden inside the deterministic suite.
    const raw_device = mtl.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{
        .raw_device = raw_device,
        .features = .{},
        .limits = .{},
    };
    defer device.deinit();

    var atlas = try GlyphAtlas.init(testing.allocator, &device);
    defer atlas.deinit();

    try testing.expectEqual(@as(u32, 1), atlas.page_count);
    try testing.expectEqual(PageFormat.gray, atlas.getPageFormat(0).?);

    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const helvetica = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer helvetica.deinit();
    const emoji = try fs.findFont(.{ .family = "Apple Color Emoji", .size = 32 });
    defer emoji.deinit();

    const gray_region = try atlas.getOrInsert(helvetica, helvetica.glyphIndexForCodepoint('A'));
    try testing.expect(gray_region.width > 0);
    try testing.expect(!gray_region.is_color);
    try testing.expectEqual(PageFormat.gray, atlas.getPageFormat(gray_region.page_index).?);

    const emoji_glyph = emoji.glyphIndexForCodepoint(0x1F600);
    try testing.expect(emoji_glyph != 0);
    const color_region = try atlas.getOrInsert(emoji, emoji_glyph);
    try testing.expect(color_region.width > 0);
    try testing.expect(color_region.is_color);
    try testing.expectEqual(PageFormat.color, atlas.getPageFormat(color_region.page_index).?);
    try testing.expect(color_region.page_index != gray_region.page_index);

    try testing.expectEqual(@as(u32, 2), atlas.page_count);
    // Small first pages: gray R8 + color BGRA8.
    try testing.expectEqual(@as(u64, GlyphAtlas.FIRST_PAGE_SIZE) * GlyphAtlas.FIRST_PAGE_SIZE * 5, atlas.bytesUsed());

    const cache_before = atlas.getCacheSize();
    const same = try atlas.getOrInsertSubpixel(emoji, emoji_glyph, packSubpixelBin(2, 0));
    try testing.expectEqual(cache_before, atlas.getCacheSize());
    try testing.expectEqual(color_region.page_index, same.page_index);
    try testing.expect(same.is_color);
}

test "metal write-combined mapping covers only upload-only resources" {
    const testing = std.testing;
    const mtl = gpu.Backend.metal_bindings;
    const raw_device = mtl.metal_create_system_default_device() orelse return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw_device, .features = .{}, .limits = .{} };
    defer device.deinit();
    const wc: c_ulong = 1;

    // Instance/uniform streams (SlotBuffer) are write-combined; read-backs are not.
    var slots = @import("slot_buffer.zig").SlotBuffer(1).init("wc-test", 256);
    defer slots.deinit(testing.allocator);
    const ensured = try slots.ensure(testing.allocator, &device, 0, 64);
    try testing.expectEqual(wc, mtl.metal_resource_cpu_cache_mode(@ptrCast(ensured.buffer.raw)));
    var readback = try device.createBuffer(testing.allocator, .{ .size = 64, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    try testing.expectEqual(@as(c_ulong, 0), mtl.metal_resource_cpu_cache_mode(@ptrCast(readback.raw)));

    // Gray glyph pages are read by the CPU rasterizer; color pages are not.
    var atlas = try GlyphAtlas.init(testing.allocator, &device);
    defer atlas.deinit();
    var fs = try text.FontSystem.init(testing.allocator, testing.io);
    defer fs.deinit();
    const emoji = try fs.findFont(.{ .family = "Apple Color Emoji", .size = 32 });
    defer emoji.deinit();
    const color_region = try atlas.getOrInsert(emoji, emoji.glyphIndexForCodepoint(0x1F600));
    for (atlas.pages[0..atlas.page_count]) |maybe_page| {
        const page = maybe_page orelse continue;
        const expected: c_ulong = if (page.format == .gray) 0 else wc;
        try testing.expectEqual(expected, mtl.metal_resource_cpu_cache_mode(@ptrCast(page.texture.raw)));
    }
    try testing.expect(atlas.getPageFormat(color_region.page_index).? == .color);

    // Icon masks keep the default read_write host access (CPU rasterizer reads them).
    var cached = try device.createTexture(testing.allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .r8_unorm, .usage = .{ .copy_dst = true, .texture_binding = true }, .memory = .host_upload });
    defer cached.destroy();
    try testing.expectEqual(@as(c_ulong, 0), mtl.metal_resource_cpu_cache_mode(@ptrCast(cached.raw)));

    // Image uploads are write-only.
    var store: @import("image_renderer.zig").ImageTextureStore = undefined;
    store.init(testing.allocator, &device, false);
    defer store.deinit();
    _ = try store.loadTexture(2, 2, &(@as([16]u8, @splat(128))));
    try testing.expectEqual(wc, mtl.metal_resource_cpu_cache_mode(@ptrCast(store.atlas_pages.items[0].texture.raw)));
}

test "metal atlas: a scale change creates a new physical glyph entry" {
    const testing = std.testing;

    var inst = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    var atlas = try GlyphAtlas.init(testing.allocator, &dq.device);
    defer atlas.deinit();

    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer font.deinit();
    const glyph = font.glyphIndexForCodepoint('M');
    try testing.expect(glyph != 0);

    font.setScaleFactor(1.0);
    const one_x = try atlas.getOrInsert(font, glyph);
    const entries_after_1x = atlas.getCacheSize();
    try testing.expect(entries_after_1x >= 1);
    _ = try atlas.getOrInsert(font, glyph);
    try testing.expectEqual(entries_after_1x, atlas.getCacheSize());

    font.setScaleFactor(2.0);
    const two_x = try atlas.getOrInsert(font, glyph);
    try testing.expectEqual(entries_after_1x + 1, atlas.getCacheSize());
    try testing.expect(two_x.width > one_x.width);

    font.setScaleFactor(1.0);
    _ = try atlas.getOrInsert(font, glyph);
    try testing.expectEqual(entries_after_1x + 1, atlas.getCacheSize());

    const bin = packSubpixelBin(1, 2);
    const before_sub = atlas.getCacheSize();
    _ = try atlas.getOrInsertSubpixel(font, glyph, bin);
    const after_sub_1x = atlas.getCacheSize();
    try testing.expectEqual(before_sub + 1, after_sub_1x);
    _ = try atlas.getOrInsertSubpixel(font, glyph, bin);
    try testing.expectEqual(after_sub_1x, atlas.getCacheSize());

    font.setScaleFactor(2.0);
    _ = try atlas.getOrInsertSubpixel(font, glyph, bin);
    try testing.expectEqual(after_sub_1x + 1, atlas.getCacheSize());
}

test "metal command encoder rejects stale pass generations across render and blit" {
    const testing = std.testing;

    var inst = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    const texture_desc: gpu.TextureDescriptor = .{
        .size = .{ .width = 8, .height = 8 },
        .format = .bgra8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true, .copy_dst = true },
    };
    var source = try dq.device.createTexture(testing.allocator, texture_desc);
    defer source.destroy();
    var destination = try dq.device.createTexture(testing.allocator, texture_desc);
    defer destination.destroy();

    var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
    errdefer encoder.deinit();
    var source_view = source.binding().createView();
    defer source_view.destroy();

    var render_pass = try encoder.beginRenderPass(.{
        .color_attachments = &.{.{
            .view = source_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    });
    var stale_render_alias = render_pass;
    try testing.expect(render_pass.isActive());
    try testing.expect(stale_render_alias.isActive());
    try testing.expectError(error.InvalidEncoderState, encoder.finish());
    render_pass.end();
    try testing.expect(!render_pass.isActive());
    try testing.expect(!stale_render_alias.isActive());

    var blit_pass = try encoder.beginBlitPass();
    try testing.expect(blit_pass.isActive());
    // The old render alias must remain invalid even when Metal reuses an
    // Objective-C encoder address for this different pass kind.
    try testing.expect(!stale_render_alias.isActive());
    try blit_pass.copyTextureRegion(source.binding(), 0, 0, 8, 8, destination.binding(), 0, 0);
    blit_pass.end();
    try testing.expect(!blit_pass.isActive());

    var destination_view = destination.binding().createView();
    defer destination_view.destroy();
    var second_render_pass = try encoder.beginRenderPass(.{
        .color_attachments = &.{.{
            .view = destination_view,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    });
    try testing.expect(second_render_pass.isActive());
    try testing.expect(!stale_render_alias.isActive());
    second_render_pass.end();

    var command_buffer = try encoder.finish();
    command_buffer.deinit();
}

test "metal text renderer: direct_animated 坐标连续无吸附, static 双侧吸附幂等" {
    const testing = std.testing;
    const mtl = gpu.Backend.metal_bindings;

    const raw_device = mtl.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{
        .raw_device = raw_device,
        .features = .{},
        .limits = .{},
    };
    defer device.deinit();

    // init compiles text.metal from embedded source, also verifies shader side changes of
    // shader_snap field.
    var tr = try text_renderer_mod.TextRenderer.init(testing.allocator, &device);
    defer tr.deinit();
    tr.setViewport(800, 600, 2.0); // 2x DPR: half-pixel snapping observable.

    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 16 });
    defer font.deinit();

    const white = text_renderer_mod.Color.WHITE;
    const frac_x: f32 = 10.37;
    const frac_y: f32 = 20.13;

    // -- Static path: CPU snap to physical pixels + shader_snap=1 (shader round idempotent) --
    try tr.drawTextWithOptions("Hello", frac_x, frac_y, font, white, 16, false, null, false, true, 0);
    const static_nearest = tr.instances_nearest.items.len;
    const static_linear = tr.instances_linear.items.len;
    try testing.expect(static_nearest + static_linear > 0);
    for (tr.instances_nearest.items) |inst| {
        try testing.expect(inst.metadata.snaps());
        // CPU already snapped by round(x*scale)/scale -> position*scale should be integer
        const px = inst.position[0] * 2.0;
        const py = inst.position[1] * 2.0;
        try testing.expectApproxEqAbs(@round(px), px, 1e-3);
        try testing.expectApproxEqAbs(@round(py), py, 1e-3);
    }
    for (tr.instances_linear.items) |inst| {
        try testing.expect(inst.metadata.snaps());
    }

    // -- Animated path (direct_animated): continuous coords + shader_snap=0 --
    const anim_base_nearest = tr.instances_nearest.items.len;
    const anim_base_linear = tr.instances_linear.items.len;
    try tr.drawTextWithOptions("Hello", frac_x, frac_y, font, white, 16, false, null, true, false, 0);
    // force_linear -> all go in linear list
    try testing.expectEqual(anim_base_nearest, tr.instances_nearest.items.len);
    const anim_a_start = anim_base_linear;
    const anim_a_len = tr.instances_linear.items.len - anim_a_start;
    try testing.expect(anim_a_len > 0);
    for (tr.instances_linear.items[anim_a_start..]) |inst| {
        try testing.expect(!inst.metadata.snaps());
    }

    // same text translated sub-pixel 0.3px redraw: per-glyph position difference must be exactly
    // 0.3 (rounding either side discretizes 0.3 into 0 or 0.5 mix -> kerning jitter)
    const shift: f32 = 0.3;
    const b_start = tr.instances_linear.items.len;
    try tr.drawTextWithOptions("Hello", frac_x + shift, frac_y, font, white, 16, false, null, true, false, 0);
    const anim_b_len = tr.instances_linear.items.len - b_start;
    try testing.expectEqual(anim_a_len, anim_b_len);
    var gi: usize = 0;
    while (gi < anim_a_len) : (gi += 1) {
        const ia = tr.instances_linear.items[anim_a_start + gi];
        const ib = tr.instances_linear.items[b_start + gi];
        try testing.expectApproxEqAbs(ia.position[0] + shift, ib.position[0], 1e-3);
        try testing.expectApproxEqAbs(ia.position[1], ib.position[1], 1e-3);
    }
}

test "metal text renderer: instance storage grows within a frame, retires, and is reused across frames" {
    const testing = std.testing;

    var inst_gpu = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst_gpu.deinit();
    const adapters = try inst_gpu.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    var tr = try text_renderer_mod.TextRenderer.init(testing.allocator, &dq.device);
    defer tr.deinit();

    const GlyphInstance = std.meta.Elem(@TypeOf(tr.instances_nearest.items));
    const glyph = GlyphInstance{
        .position = .{ 0, 0 },
        .size = .{ 1, 1 },
        .uv_rect = @FieldType(GlyphInstance, "uv_rect").init(.{ 0, 0, 0, 0 }),
        .color = .{ 1, 1, 1, 1 },
    };
    var target = try dq.device.createTexture(testing.allocator, .{
        .size = .{ .width = 8, .height = 8 },
        .format = .bgra8_unorm,
        .usage = .{ .render_attachment = true },
    });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();

    var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);

    const pass_desc: gpu.RenderPassDescriptor = .{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    };

    // -- Frame A: the slot grows to the frame's demand; a second flush grows it
    // again and retires the first buffer (earlier draws still reference it) --
    tr.beginFrame(8, 8, 1.0);
    const slot = tr.current_buffer;
    try tr.instances_nearest.appendNTimes(testing.allocator, glyph, 5000);
    {
        var pass = try encoder.beginRenderPass(pass_desc);
        try tr.endFrame(&pass);
        try testing.expect(tr.instance_buffers.capacity(slot) >= @sizeOf(GlyphInstance) * 5000);
        try tr.instances_nearest.appendNTimes(testing.allocator, glyph, 20000);
        try tr.flush(&pass);
        pass.end();
    }
    const cap0 = tr.instance_buffers.capacity(slot);
    try testing.expect(cap0 >= @sizeOf(GlyphInstance) * 25000);
    try testing.expect(cap0 < @sizeOf(GlyphInstance) * 50000);
    try testing.expectEqual(@as(usize, 1), tr.instance_buffers.retired[slot].items.len);
    const raw0 = tr.instance_buffers.buffers[slot].?.raw;

    // -- idle BUFFER_COUNT-1 frames, wrap to same slot --
    var i: usize = 0;
    while (i < tr.instance_buffers.buffers.len - 1) : (i += 1) {
        tr.beginFrame(8, 8, 1.0);
        var pass = try encoder.beginRenderPass(pass_desc);
        try tr.endFrame(&pass);
        pass.end();
    }

    // -- Frame C (same slot): retired storage is gone, a smaller frame reuses
    // the grown buffer instead of allocating --
    tr.beginFrame(8, 8, 1.0);
    try testing.expectEqual(slot, tr.current_buffer);
    try testing.expectEqual(@as(usize, 0), tr.instance_buffers.retired[slot].items.len);
    try tr.instances_nearest.appendNTimes(testing.allocator, glyph, 12000);
    {
        var pass = try encoder.beginRenderPass(pass_desc);
        try tr.endFrame(&pass);
        pass.end();
    }
    try testing.expectEqual(raw0, tr.instance_buffers.buffers[slot].?.raw);
    try testing.expectEqual(cap0, tr.instance_buffers.capacity(slot));

    // Idle release drops every slot; the next frame regrows from the minimum.
    tr.releaseScratch();
    try testing.expectEqual(@as(usize, 0), tr.instance_buffers.capacity(slot));

    var command_buffer = try encoder.finish();
    command_buffer.deinit();
}

test "metal command encoder deinit ends a pass abandoned by an error path" {
    // AppRenderer.frame after beginRenderPass any `try` failure, only errdefer gpu_encoder.deinit()
    // left. deinit must endEncoding + release that live pass, or encoder leaks and command buffer
    // with unended encoder freed (Metal validation: MTL_DEBUG_LAYER=1 asserts crash).
    const testing = std.testing;

    var inst = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    var target = try dq.device.createTexture(testing.allocator, .{
        .size = .{ .width = 8, .height = 8 },
        .format = .bgra8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();

    for (0..2) |kind| {
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        if (kind == 0) {
            const pass = try encoder.beginRenderPass(.{
                .color_attachments = &.{.{
                    .view = view,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                }},
            });
            try testing.expect(pass.isActive());
        } else {
            const pass = try encoder.beginBlitPass();
            try testing.expect(pass.isActive());
        }
        try testing.expect(encoder.active_pass_raw != null);
        encoder.deinit(); // pass never ended
    }
}

test "175 percent drawable edges and encoded UNORM blending are exact" {
    var instance = try gpu.Backend.Instance.init(std.testing.allocator, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer std.testing.allocator.free(adapters);
    defer for (adapters) |*adapter| adapter.deinit();
    var dq = try adapters[0].requestDevice(std.testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    try @import("drawable_extent_contract.zig").run(std.testing.allocator, &dq.device, &dq.queue);
}

extern "c" fn zenit_test_fractional_layer(*f64, *f64) ?*anyopaque;
extern "c" fn zenit_test_fractional_layer_reset(*anyopaque, f64, f64) void;
extern "c" fn zenit_test_fractional_layer_destroy(*anyopaque) void;
extern "c" fn zenit_test_write_bgra8([*:0]const u8, [*]u8, u32, u32) void;

test "fractional Cocoa bounds use acquired Metal texture extent" {
    const allocator = std.testing.allocator;
    var width: f64 = 0;
    var height: f64 = 0;
    const layer = zenit_test_fractional_layer(&width, &height) orelse return error.MetalDeviceUnavailable;
    defer zenit_test_fractional_layer_destroy(layer);
    const raw = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw, .features = .{}, .limits = .{} };
    defer device.deinit();
    var queue = gpu.Backend.Queue{ .raw = gpu.Backend.metal_bindings.metal_device_new_command_queue(raw) orelse return error.MetalQueueUnavailable };
    defer queue.deinit();
    var surface = gpu.Backend.Surface.init(layer);
    defer surface.deinit();
    try surface.configure(allocator, &device, .{ .width = 800, .height = 600, .format = .bgra8_unorm, .usage = .color_target_and_read });
    const Encoder = @import("command_encoder.zig").RenderCommandEncoder;
    var sdf = try @import("sdf_renderer.zig").SdfRenderer.init(allocator, &device);
    defer sdf.deinit();
    var text_renderer = try text_renderer_mod.TextRenderer.init(allocator, &device);
    defer text_renderer.deinit();
    var pool = @import("offscreen_texture.zig").OffscreenTexturePool{};
    defer pool.deinit();
    var persistent = @import("command_encoder.zig").PersistentGpuCache{};
    defer persistent.deinit();
    persistent.path_renderer = try @import("path_renderer.zig").PathRenderer.init(allocator, &device);
    var encoder = Encoder.init(&sdf, &text_renderer, &pool, &persistent);
    defer encoder.deinit();
    for ([_]f64{ 400.2, 400.4, 400.75, 401.1 }, 0..) |logical_width, index| {
        width = logical_width;
        zenit_test_fractional_layer_reset(layer, width, height);
        var target = try surface.acquireTexture(allocator);
        defer target.deinit();
        const bindings = gpu.Backend.metal_bindings;
        const actual_w = bindings.metal_texture_get_width(target.texture.raw);
        const actual_h = bindings.metal_texture_get_height(target.texture.raw);
        try std.testing.expectEqual(actual_w, target.texture.size.width);
        try std.testing.expectEqual(actual_h, target.texture.size.height);
        encoder.beginFrame(@floatCast(width), @floatCast(height), 2);
        encoder.setDrawableExtent(actual_w, actual_h);
        try std.testing.expectEqual([2]u32{ actual_w, actual_h }, encoder.drawable_extent);
        try std.testing.expectEqual(@as(f32, @floatFromInt(actual_w)), encoder.sdf_renderer.viewport_width);
        try std.testing.expectEqual(@as(f32, @floatFromInt(actual_h)), encoder.text_renderer.viewport_height);
        var staging = try device.createTexture(allocator, .{ .size = target.texture.size, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .copy_dst = true, .copy_src = true } });
        defer staging.destroy();
        var command_encoder = try gpu.Backend.CommandEncoder.init(&queue);
        var view = target.texture.binding().createView();
        defer view.destroy();
        var pass = try command_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 32.0 / 255.0, .g = 32.0 / 255.0, .b = 32.0 / 255.0, .a = 1 } }} });
        encoder.render_pass = &pass;
        encoder.applyOffscreenTargetViewport();
        var points = [_]f32{ -2, -2, @floatCast(width + 2), -2, @floatCast(width + 2), @floatCast(height + 2), -2, @floatCast(height + 2) };
        var path = &persistent.path_renderer.?;
        path.setRectClip(.{ 0, 0, @floatCast(width), @floatCast(height) });
        _ = try path.addFillPath(&.{@import("path_tessellator.zig").Contour{ .vertices = &points, .closed = true }}, .{ 240.0 / 255.0, 240.0 / 255.0, 240.0 / 255.0, 0.5 }, 0, 0);
        try path.flush(&pass);
        pass.end();
        encoder.render_pass = null;
        var blit = try command_encoder.beginBlitPass();
        try blit.copyTextureRegion(target.texture.binding(), 0, 0, actual_w, actual_h, staging.binding(), 0, 0);
        blit.end();
        var command = try command_encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        const bytes = try allocator.alloc(u8, @as(usize, actual_w) * actual_h * 4);
        defer allocator.free(bytes);
        try staging.readBgra8(actual_w, actual_h, bytes, actual_w * 4);
        for (0..actual_h) |y| for (0..3) |channel| try std.testing.expectEqual(@as(u8, 136), bytes[(y * actual_w + actual_w - 1) * 4 + channel]);
        for (0..actual_w) |x| for (0..3) |channel| try std.testing.expectEqual(@as(u8, 136), bytes[((actual_h - 1) * @as(usize, actual_w) + x) * 4 + channel]);
        const artifacts = [_][*:0]const u8{ "/tmp/zenit-dpi-fractional-400.2.png", "/tmp/zenit-dpi-fractional-400.4.png", "/tmp/zenit-dpi-fractional-400.75.png", "/tmp/zenit-dpi-fractional-401.1.png" };
        zenit_test_write_bgra8(artifacts[index], bytes.ptr, actual_w, actual_h);
        std.debug.print("fractional Cocoa bounds={d}x{d} configured=800x600 acquired={d}x{d} viewport={any}\n", .{ width, height, actual_w, actual_h, encoder.drawable_extent });
    }
}

extern fn metal_command_buffer_track_engines(*anyopaque) void;
extern fn metal_command_buffer_engine_counts(*anyopaque, *[3]u32) void;

test "Metal render copy preserves bytes, offsets and untouched pixels without blit" {
    const t = std.testing;
    var inst = try gpu.Backend.Instance.init(t.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer t.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(t.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    for ([_]gpu.TextureFormat{ .bgra8_unorm, .bgra8_unorm_srgb }) |format| {
        const desc: gpu.TextureDescriptor = .{
            .size = .{ .width = 16, .height = 16 },
            .format = format,
            .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true, .copy_dst = true },
            .memory = .host_upload,
        };
        var src = try dq.device.createTexture(t.allocator, desc);
        defer src.destroy();
        var dst = try dq.device.createTexture(t.allocator, desc);
        defer dst.destroy();
        var pixels: [16 * 16 * 4]u8 = undefined;
        for (&pixels, 0..) |*byte, i| byte.* = @truncate((i / 4) * 37 + (i % 4) * 73);
        const initial: [pixels.len]u8 = @splat(83);
        try src.writeRegion(0, 0, 0, 16, 16, &pixels, 16 * 4);
        {
            var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
            errdefer encoder.deinit();
            try gpu.copyTextureRegion(&encoder, src.binding(), 0, 0, 16, 16, dst.binding(), 0, 0, false);
            var command = try encoder.finish();
            defer command.deinit();
            command.submit();
            command.waitUntilCompleted();
            var actual: [pixels.len]u8 = undefined;
            try dst.readBgra8(16, 16, &actual, 16 * 4);
            try t.expectEqualSlices(u8, &pixels, &actual);
        }
        for ([_]bool{ false, true }) |clear| {
            try dst.writeRegion(0, 0, 0, 16, 16, &initial, 16 * 4);
            var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
            errdefer encoder.deinit();
            metal_command_buffer_track_engines(@ptrCast(encoder.raw));
            try gpu.copyTextureRegion(&encoder, src.binding(), 2, 1, 3, 3, dst.binding(), 1, 2, clear);
            try t.expectError(error.InvalidTextureRegion, gpu.copyTextureRegion(&encoder, src.binding(), 15, 0, 2, 1, dst.binding(), 0, 0, false));
            try t.expectError(error.InvalidTextureRegion, gpu.copyTextureRegion(&encoder, src.binding(), 0, 0, 1, 1, src.binding(), 0, 0, false));
            var counts: [3]u32 = undefined;
            metal_command_buffer_engine_counts(@ptrCast(encoder.raw), &counts);
            try t.expectEqual([3]u32{ 1, 0, 0 }, counts);
            var command = try encoder.finish();
            defer command.deinit();
            command.submit();
            command.waitUntilCompleted();
            var actual: [pixels.len]u8 = undefined;
            try dst.readBgra8(16, 16, &actual, 16 * 4);
            for (0..16) |y| for (0..16) |x| for (0..4) |c| {
                const expected = if (x >= 1 and x < 4 and y >= 2 and y < 5)
                    pixels[((y - 2 + 1) * 16 + x - 1 + 2) * 4 + c]
                else if (clear) @as(u8, 0) else initial[0];
                try t.expectEqual(expected, actual[(y * 16 + x) * 4 + c]);
            };
        }
    }
}

test "Metal render copy cache handles concurrent first use and formats" {
    const t = std.testing;
    var inst = try gpu.Backend.Instance.init(t.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer t.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(t.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    const Worker = struct {
        queue: *gpu.Backend.Queue,
        source: gpu.Backend.TextureBinding,
        destination: gpu.Backend.TextureBinding,
        start: *std.atomic.Value(bool),
        failure: ?anyerror = null,

        fn copy(self: *@This()) !void {
            var encoder = try gpu.Backend.CommandEncoder.init(self.queue);
            errdefer encoder.deinit();
            try gpu.copyTextureRegion(&encoder, self.source, 0, 0, 4, 4, self.destination, 0, 0, false);
            var command = try encoder.finish();
            defer command.deinit();
            command.submit();
            command.waitUntilCompleted();
        }
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.copy() catch |err| {
                self.failure = err;
            };
        }
    };
    var sources: [4]gpu.Backend.Texture = undefined;
    var destinations: [4]gpu.Backend.Texture = undefined;
    var source_count: usize = 0;
    var destination_count: usize = 0;
    defer for (sources[0..source_count]) |*texture| texture.destroy();
    defer for (destinations[0..destination_count]) |*texture| texture.destroy();
    const pixels: [4 * 4 * 4]u8 = @splat(83);
    var start = std.atomic.Value(bool).init(false);
    var workers: [4]Worker = undefined;
    for (&workers, 0..) |*worker, i| {
        const format: gpu.TextureFormat = if (i % 2 == 0) .bgra8_unorm else .bgra8_unorm_srgb;
        sources[i] = try dq.device.createTexture(t.allocator, .{
            .size = .{ .width = 4, .height = 4 },
            .format = format,
            .usage = .{ .texture_binding = true },
            .memory = .host_upload,
        });
        source_count += 1;
        destinations[i] = try dq.device.createTexture(t.allocator, .{
            .size = .{ .width = 4, .height = 4 },
            .format = format,
            .usage = .{ .render_attachment = true },
            .memory = .host_upload,
        });
        destination_count += 1;
        try sources[i].writeRegion(0, 0, 0, 4, 4, &pixels, 16);
        worker.* = .{ .queue = &dq.queue, .source = sources[i].binding(), .destination = destinations[i].binding(), .start = &start };
    }
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer {
        start.store(true, .release);
        for (threads[0..started]) |thread| thread.join();
    }
    for (&workers, 0..) |*worker, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started += 1;
    }
    start.store(true, .release);
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    for (&workers, 0..) |*worker, i| {
        if (worker.failure) |err| return err;
        var actual: [pixels.len]u8 = undefined;
        try destinations[i].readBgra8(4, 4, &actual, 16);
        try t.expectEqualSlices(u8, &pixels, &actual);
    }
}

// Filler glyphs stay outside the viewport. Three visible markers straddle
// overflow allocation and growth, so their pixels must equal a three-glyph draw.
test "metal text renderer: over 40000 glyphs preserve pixels through overflow growth" {
    const a = std.testing.allocator;
    var inst = try gpu.Backend.Instance.init(a, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer a.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    var tr = try text_renderer_mod.TextRenderer.init(a, &dq.device);
    defer tr.deinit();
    var fs = try text.FontSystem.init(a, std.testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 16 });
    defer font.deinit();
    tr.beginFrame(128, 64, 1);
    try tr.drawTextWithOptions("A", 8, 24, font, text_renderer_mod.Color.WHITE, 16, false, null, false, true, 0);
    try std.testing.expectEqual(@as(usize, 1), tr.instances_nearest.items.len);
    const seed = tr.instances_nearest.items[0];
    // Well past the slot's starting capacity, then a second flush that grows
    // it again mid-frame: draws bound before the growth keep their storage.
    const first_count: usize = 5000;
    const total_count: usize = 40001;
    const Glyph = @TypeOf(seed);
    var markers: [3]Glyph = @splat(seed);
    for (&markers, 0..) |*g, i| {
        g.position[0] += @as(f32, @floatFromInt(i)) * 32;
        g.color = .{ 0, 0, 0, 1 };
        g.color[i] = 1;
    }
    var filler = seed;
    filler.position = .{ -1000, -1000 };
    var target = try dq.device.createTexture(a, .{ .size = .{ .width = 128, .height = 64 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    const expected = try a.alloc(u8, 128 * 64 * 4);
    defer a.free(expected);
    const actual = try a.alloc(u8, expected.len);
    defer a.free(actual);
    for (0..2) |stress| {
        tr.beginFrame(128, 64, 1);
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        errdefer encoder.deinit();
        var view = target.binding().createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }} });
        if (stress == 0) {
            try tr.instances_nearest.appendSlice(a, &markers);
        } else {
            try tr.instances_nearest.appendNTimes(a, filler, first_count);
            tr.instances_nearest.items[0] = markers[0];
            tr.instances_nearest.items[first_count - 1] = markers[1];
            try tr.flush(&pass);
            const before = tr.instance_buffers.capacity(tr.current_buffer);
            try std.testing.expect(before >= @sizeOf(Glyph) * first_count);
            try tr.instances_nearest.appendNTimes(a, filler, total_count - first_count);
            tr.instances_nearest.items[total_count - first_count - 1] = markers[2];
            try tr.flush(&pass);
            try std.testing.expect(tr.instance_buffers.capacity(tr.current_buffer) > before);
            try std.testing.expectEqual(@as(usize, 1), tr.instance_buffers.retired[tr.current_buffer].items.len);
        }
        try tr.endFrame(&pass);
        pass.end();
        var cmd = try encoder.finish();
        defer cmd.deinit();
        cmd.submit();
        cmd.waitUntilCompleted();
        try target.readBgra8(128, 64, if (stress == 0) expected else actual, 128 * 4);
    }
    // Check the oracle has visible ink for each marker, not an empty frame.
    for (0..3) |marker| {
        var ink: usize = 0;
        for (0..64) |y| for (0..32) |x| {
            const pixel = (y * 128 + x + marker * 32) * 4;
            if (expected[pixel] + @as(u16, expected[pixel + 1]) + expected[pixel + 2] > 0) ink += 1;
        };
        try std.testing.expect(ink > 0);
    }
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "metal text overflow allocation failure preserves owned buffers and retries" {
    const a = std.testing.allocator;
    var inst = try gpu.Backend.Instance.init(a, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer a.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    var tr = try text_renderer_mod.TextRenderer.init(a, &dq.device);
    defer tr.deinit();
    try checkOverflowAllocationFailure(&tr, &dq.device, &dq.queue);
}

fn checkOverflowAllocationFailure(tr: anytype, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    const a = std.testing.allocator;
    const list = if (comptime @hasField(@TypeOf(tr.*), "instances_nearest")) &tr.instances_nearest else &tr.instances;
    const Glyph = std.meta.Elem(@TypeOf(list.items));
    const glyph = std.mem.zeroes(Glyph);
    var target = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true } });
    defer target.destroy();
    var source = try device.createTexture(a, .{ .size = .{ .width = 1, .height = 1 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    defer source.destroy();
    try source.writeRegion(0, 0, 0, 1, 1, &.{ 255, 255, 255, 255 }, 4);
    if (comptime @hasField(@TypeOf(tr.*), "instance_texture_ids")) {
        if (tr.textures.items.len == 0) try tr.textures.append(tr.allocator, null);
        tr.textures.items[0] = .{ .texture = source, .width = 1, .height = 1, .bytes = 4 };
    }
    defer if (comptime @hasField(@TypeOf(tr.*), "instance_texture_ids")) {
        tr.textures.items[0] = null;
    };
    for (0..2) |kind| {
        if (comptime @hasField(@TypeOf(tr.*), "grad_stops")) tr.beginFrame(8, 8, 1, 0) else tr.beginFrame(8, 8, 1);
        const slot = tr.current_buffer;
        const old = try device.createBuffer(a, .{ .size = 16, .usage = .{ .vertex = true, .map_write = true } });
        var owned = old;
        @memset(try owned.getMappedRange(0, 16), 0xab);
        // A 16-byte slot buffer cannot hold two instances (or one overflow
        // uniform), so the flush must grow it and the growth allocation fails.
        const storage = if (kind == 0) &tr.instance_buffers else &tr.uniform_overflow;
        try std.testing.expect(storage.buffers[slot] == null);
        storage.buffers[slot] = old;
        storage.capacities[slot] = 16;
        if (kind == 1) tr.uniform_write_offset = if (comptime @hasField(@TypeOf(tr.*), "instances_nearest")) 512 else 256;
        try list.*.appendNTimes(a, glyph, 2);
        if (comptime @hasField(@TypeOf(tr.*), "instance_texture_ids")) try tr.instance_texture_ids.appendNTimes(a, 0, 2);
        if (comptime @hasField(@TypeOf(tr.*), "instance_textures")) {
            for (0..2) |_| try tr.instance_textures.append(a, .{ .binding = source.binding(), .view = source.binding().createView() });
        }
        var encoder = try gpu.Backend.CommandEncoder.init(queue);
        errdefer encoder.deinit();
        var view = target.binding().createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        const destroyed = gpu.Backend.Buffer.destroyCountForTesting();
        device.failNextBufferForTesting();
        try std.testing.expectError(error.OutOfMemory, tr.flush(&pass));
        // Counting release calls catches the ownership bug without dereferencing
        // a freed native object on the failing implementation.
        try std.testing.expectEqual(destroyed, gpu.Backend.Buffer.destroyCountForTesting());
        try std.testing.expectEqual(@as(usize, 2), list.*.items.len);
        try std.testing.expectEqual(old.raw, storage.buffers[slot].?.raw);
        try std.testing.expectEqual(@as(usize, 16), storage.capacities[slot]);
        if (kind == 0) try std.testing.expectEqual(@as(usize, 0), tr.buffer_write_offset) else try std.testing.expectEqual(@as(usize, 0), tr.uniform_overflow_used);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xab)), try owned.getMappedRange(0, 16));
        try tr.flush(&pass);
        // The retry replaces the buffer; the old one is retired with the slot,
        // not destroyed while this frame's encoded draws may still read it.
        try std.testing.expectEqual(destroyed, gpu.Backend.Buffer.destroyCountForTesting());
        try std.testing.expectEqual(old.raw, storage.retired[slot].items[storage.retired[slot].items.len - 1].raw);
        try std.testing.expectEqual(@as(usize, 0), list.*.items.len);
        pass.end();
        var cmd = try encoder.finish();
        defer cmd.deinit();
        cmd.submit();
        cmd.waitUntilCompleted();
    }
}

test "metal SDF icon and image overflow failures preserve owned buffers" {
    const a = std.testing.allocator;
    var inst = try gpu.Backend.Instance.init(a, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer a.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    var sdf = try @import("sdf_renderer.zig").SdfRenderer.init(a, &dq.device);
    defer sdf.deinit();
    try checkOverflowAllocationFailure(&sdf, &dq.device, &dq.queue);
    var icon: @import("icon_renderer.zig").IconRenderer = undefined;
    try icon.init(a, &dq.device);
    defer icon.deinit();
    try checkOverflowAllocationFailure(&icon, &dq.device, &dq.queue);
    var image: @import("image_renderer.zig").ImageRenderer = undefined;
    try image.init(a, &dq.device);
    defer image.deinit();
    try checkOverflowAllocationFailure(&image, &dq.device, &dq.queue);
}

test "cropped main target retains raster mapping across nested shape isolation" {
    const a = std.testing.allocator;
    const ce = @import("command_encoder.zig");
    const raw = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw, .features = .{}, .limits = .{} };
    defer device.deinit();
    var queue = gpu.Backend.Queue{ .raw = gpu.Backend.metal_bindings.metal_device_new_command_queue(raw) orelse return error.MetalQueueUnavailable };
    defer queue.deinit();
    var sdf = try @import("sdf_renderer.zig").SdfRenderer.init(a, &device);
    defer sdf.deinit();
    var tr = try text_renderer_mod.TextRenderer.init(a, &device);
    defer tr.deinit();
    var ir: @import("image_renderer.zig").ImageRenderer = undefined;
    try ir.init(a, &device);
    defer ir.deinit();
    var pool = @import("offscreen_texture.zig").OffscreenTexturePool{};
    defer pool.deinit();
    var persistent = ce.PersistentGpuCache{};
    defer persistent.deinit();
    var enc = ce.RenderCommandEncoder.init(&sdf, &tr, &pool, &persistent);
    enc.image_renderer = &ir;
    enc.io = std.testing.io;
    defer enc.deinit();
    const crop = [4]u32{ 38, 23, 8, 30 };
    var reference: [128 * 96 * 4]u8 = undefined;
    // Full scene, a standalone caret patch, then a cell at a nonzero atlas offset.
    for ([_][4]u32{ .{ 128, 96, 0, 0 }, .{ 8, 30, 0, 0 }, .{ 24, 48, 7, 9 } }, 0..) |target, index| {
        var texture = try device.createTexture(a, .{ .size = .{ .width = target[0], .height = target[1] }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .render_attachment = true, .texture_binding = true } });
        defer texture.destroy();
        var command_encoder = try gpu.Backend.CommandEncoder.init(&queue);
        errdefer command_encoder.deinit();
        var view = texture.binding().createView();
        defer view.destroy();
        var pass = try command_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 1, .g = 1, .b = 1, .a = 1 } }} });
        enc.beginFrame(128, 96, 1);
        enc.gpu_command_encoder = &command_encoder;
        enc.main_render_target = texture.binding();
        enc.render_pass = &pass;
        enc.root_target_crop = if (index == 0) null else crop;
        enc.root_target_offset = .{ target[2], target[3] };
        enc.applyOffscreenTargetViewport();
        const polygon = ce.ClipPolygon.empty();
        // Completely clipped descendants need no isolation texture. Treating
        // this as a resource fallback would incorrectly reject caret admission.
        try enc.pushClip(0, 0, 0, 0, @splat(0), .rect, polygon);
        _ = try enc.pushClipCommand(10, 5, 85, 80, @splat(12), .rounded_rect, polygon);
        try std.testing.expectEqual(ce.PushClipMode.clip, try enc.pushClipCommand(20, 0, 100, 65, @splat(16), .rounded_rect, polygon));
        try std.testing.expectEqual(@as(u32, 0), enc.isolated_clip_fallbacks);
        try enc.popClip();
        try enc.popClip();
        try enc.popClip();
        try std.testing.expectEqual(ce.PushClipMode.clip, try enc.pushClipCommand(10, 5, 85, 80, @splat(12), .rounded_rect, polygon));
        // The second crossing shape pairs with the first in the shaders; a third one finds both
        // shape slots taken and isolates, the path this test covers. Within the visible rect
        // (20..95 x 5..65) its corners cut that rect's, which pokes out of the first shape's
        // top-right and the second's bottom-left corner: no shape contains another there.
        try std.testing.expectEqual(ce.PushClipMode.clip, try enc.pushClipCommand(20, 0, 100, 65, @splat(16), .rounded_rect, polygon));
        try std.testing.expectEqual(ce.PushClipMode.isolated, try enc.pushClipCommand(15, 0, 85, 70, @splat(24), .rounded_rect, polygon));
        try std.testing.expectEqual(@as(usize, 1), enc.offscreen_depth);
        try std.testing.expectEqual(@as(?[4]u32, null), enc.render_pass.?.root_crop);
        const offset = enc.offscreenOffset();
        try sdf.addRoundedRect(40 + offset[0], 25 + offset[1], 2, 25, .{ 0.2, 0.4, 0.7, 1 }, @splat(0));
        try enc.popClip();
        try @import("opacity_layer.zig").endOpacityLayer(&enc);
        try enc.popClip();
        try enc.popClip();
        const restored = enc.render_pass.?;
        try std.testing.expect(restored.generation > pass.generation);
        try enc.flush(restored);
        restored.end();
        var command = try command_encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        const bytes = try a.alloc(u8, @as(usize, target[0]) * target[1] * 4);
        defer a.free(bytes);
        try texture.readBgra8(target[0], target[1], bytes, target[0] * 4);
        if (index == 0) {
            @memcpy(&reference, bytes);
            // A blank reference must never make crop equality pass accidentally.
            try std.testing.expect(reference[(25 * 128 + 40) * 4] < 240);
        } else {
            for (0..target[1]) |y| for (0..target[0]) |x| {
                const actual = bytes[(y * target[0] + x) * 4 ..][0..4];
                if (x >= target[2] and x < target[2] + crop[2] and y >= target[3] and y < target[3] + crop[3]) {
                    const r = ((y - target[3] + crop[1]) * 128 + x - target[2] + crop[0]) * 4;
                    try std.testing.expectEqualSlices(u8, reference[r..][0..4], actual);
                } else try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, actual);
            };
        }
    }
}
