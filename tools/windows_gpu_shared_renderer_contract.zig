const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
extern fn zenit_d12_test_read_texture_reuses() c_long;
pub fn run(io: std.Io) !void {
    const a = std.heap.page_allocator;
    var instance = try gpu.Backend.Instance.init(a, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer for (adapters) |*adapter| adapter.deinit();
    var dq = try adapters[0].requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    try checkSdfBatchOrder(a, &dq.device, &dq.queue);
    try checkInsetLayers(a, &dq.device, &dq.queue);
    try checkPlainRectClip(a, &dq.device, &dq.queue);
    try checkOpaqueRegions(a, &dq.device, &dq.queue);
    try profileRegionArrays(io, a, &dq.device, &dq.queue);
    try checkUniformOverflow(a, &dq.device, &dq.queue);
    try profileSolidRectClip(a, &dq.device, &dq.queue);
    try checkShadowRing(a, &dq.device, &dq.queue);
    try profileImageMaskSpecialization(a, &dq.device, &dq.queue);
    var sdf = try render.SdfRenderer.init(a, &dq.device);
    var sdf_live = true;
    defer if (sdf_live) sdf.deinit();
    const image = try a.create(render.ImageRenderer);
    defer a.destroy(image);
    try image.init(a, &dq.device);
    defer image.deinit();
    var path = try render.PathRenderer.init(a, &dq.device);
    defer path.deinit();
    var text = try render.TextRenderer.init(a, &dq.device);
    defer text.deinit();
    const icon = try a.create(render.IconRenderer);
    defer a.destroy(icon);
    try icon.init(a, &dq.device);
    defer icon.deinit();
    var target = try dq.device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
    const before = gpu.Backend.CommandBuffer.error_count.load(.monotonic);
    sdf.beginFrame(8, 4, 1, 0);
    try sdf.addRoundedRect(0, 0, 4, 4, .{ 1, 0, 0, 1 }, @splat(0));
    try sdf.flush(&pass);
    try sdf.addRoundedRect(4, 0, 4, 4, .{ 0, 1, 0, 1 }, @splat(0));
    try sdf.flush(&pass);
    // Explicitly exercise the compatibility path: shared slots are now aligned,
    // so mutating padding in their old 340-byte stride would be a vacuous test.
    var compatibility_uniform = try dq.device.createBuffer(a, .{ .size = 1024, .usage = .{ .vertex = true, .map_write = true } });
    defer compatibility_uniform.destroy();
    const copied_uniform = try compatibility_uniform.getMappedRange(340, 340);
    @memcpy(copied_uniform, try sdf.uniform_buffers[sdf.current_buffer].getMappedRange(0, 340));
    try sdf.addRoundedRect(4, 0, 4, 4, .{ 0, 0, 1, 1 }, @splat(0));
    const instance_bytes = std.mem.sliceAsBytes(sdf.instances.items);
    var compatibility_instances = try dq.device.createBuffer(a, .{ .size = instance_bytes.len, .usage = .{ .vertex = true, .map_write = true } });
    defer compatibility_instances.destroy();
    @memcpy(try compatibility_instances.getMappedRange(0, instance_bytes.len), instance_bytes);
    pass.setPipeline(&sdf.pipeline);
    pass.setVertexBuffer(0, &compatibility_uniform, 340);
    pass.setFragmentBuffer(0, &compatibility_uniform, 340);
    pass.setVertexBuffer(1, &compatibility_instances, 0);
    pass.setFragmentBuffer(1, &compatibility_instances, 0);
    try pass.drawChecked(6, 1, 0, 0); // blue must overwrite the previous green
    sdf.instances.clearRetainingCapacity();
    pass.end();
    if (gpu.Backend.CommandBuffer.error_count.load(.monotonic) != before) return error.SharedRendererEncodingFailed;
    var command = try encoder.finish();
    defer command.deinit();
    // Unaligned uniform snapshots must remain independent after CPU edits and
    // destruction of the renderer, while recorded/GPU resource owners survive.
    @memset(try compatibility_uniform.getMappedRange(340, 8), 0);
    const gate = zenit_d12_test_gate_create(dq.device.context.device.raw, dq.device.context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        dq.device.context.queue.waitIdle(5000) catch @panic("shared renderer gate cleanup");
        zenit_d12_test_gate_release(gate);
    }
    try command.submitChecked();
    if (command.waitChecked(0)) |_| return error.BlockedCommandCompleted else |err| if (err != error.GpuTimeout) return err;
    sdf.deinit();
    sdf_live = false;
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try command.waitChecked(5000);
    var pixels: [128]u8 = undefined;
    try target.readBgra8(8, 4, &pixels, 32);
    // Outer/shape edges use AA; interior colors and opaque coverage are exact.
    for (1..3) |y| for ([_]usize{ 1, 2, 5, 6 }) |x| {
        const expected: [4]u8 = if (x < 4) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
        if (!std.mem.eql(u8, pixels[(y * 8 + x) * 4 ..][0..4], &expected)) return error.IncorrectSharedSdfPixel;
    };
    // Three texture-backed Image flushes exercise aligned uniforms and SRV reuse.
    const blue = try image.loadTexture(1, 1, &.{ 0, 0, 255, 255 });
    const yellow = try image.loadTexture(1, 1, &.{ 255, 255, 0, 255 });
    var image_encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
    defer image_encoder.deinit();
    var image_pass = try image_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
    const reuse_before = zenit_d12_test_read_texture_reuses();
    image.beginFrame(8, 4, 1);
    try image.addImage(blue, 0, 0, 4, 4, 0, 1);
    try image.flush(&image_pass);
    try image.addImage(yellow, 4, 0, 4, 4, 0, 1);
    try image.flush(&image_pass);
    try image.addImage(blue, 0, 0, 4, 4, 0, 1);
    try image.flush(&image_pass); // same SRV after a different texture
    if (zenit_d12_test_read_texture_reuses() <= reuse_before) return error.ReadTextureReuseNotExercised;
    image_pass.end();
    if (gpu.Backend.CommandBuffer.error_count.load(.monotonic) != before) return error.SharedImageEncodingFailed;
    var image_command = try image_encoder.finish();
    defer image_command.deinit();
    try image_command.submitChecked();
    try image_command.waitChecked(5000);
    try target.readBgra8(8, 4, &pixels, 32);
    for (1..3) |y| for ([_]usize{ 1, 2, 5, 6 }) |x| {
        const expected: [4]u8 = if (x < 4) .{ 255, 0, 0, 255 } else .{ 0, 255, 255, 255 };
        if (!std.mem.eql(u8, pixels[(y * 8 + x) * 4 ..][0..4], &expected)) return error.IncorrectSharedImagePixel;
    };
    for (0..32) |p| std.mem.swap(u8, &pixels[p * 4], &pixels[p * 4 + 2]);
    std.debug.print("SHARED_RENDERER_RGBA8_HEX={s}\nPASS: actual shared Sdf/Image/Path/Text/Icon constructors/destruction; two SDF and three Image flushes, sixteen exact sRGB interior pixels, unaligned uniform snapshot survives CPU mutation and GPU-blocked renderer destruction\n", .{std.fmt.bytesToHex(pixels, .lower)});
}

fn checkSdfBatchOrder(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 24, .height = 12 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var pixels: [2][24 * 12 * 4]u8 = undefined;
    for ([_]u32{ 0, 1 }) |clip_kind| {
        for (0..2) |version| {
            sdf.beginFrame(24, 12, 1, 0);
            sdf.setRectClip(.{ 1.25, 1.5, 20.5, 9.25 });
            sdf.setClipMask(clip_kind, .{ 0, 0, 24, 12 }, @splat(3), 0, 0, 0, @splat(0), @splat(.{ 0, 0 }));
            for (0..9) |i| {
                const x: f32 = @floatFromInt(i);
                try sdf.addRoundedRect(x, 0, 16, 12, .{ x / 10, 0.3, 0.7, 0.4 }, @splat(2));
                const item = &sdf.instances.items[i];
                item.border_widths = .{ 1, 2, 1, 0.5 };
                item.border_color = .{ 0.8, 0.2, 0.1, 0.6 };
                // Mix plain and rounded solids. Shape masks must force the
                // general solid path even for otherwise eligible rectangles.
                if (i == 0 or i == 3 or i == 6) {
                    item.corner_radii = @splat(0);
                    item.border_widths = @splat(0);
                }
                if (i == 2 or i == 7) {
                    item.packed_flags = 1;
                    item.gradient_to_color = .{ 0.1, 0.6, 0.3, 0.8 };
                } else if (i == 4 or i == 8) {
                    item.shadow_color = .{ 0.1, 0.1, 0.1, 0.5 };
                    item.shadow_blur = 2;
                }
                // Unused seed forces the full shader without changing any material.
                if (version == 1) item.packed_flags |= 1 << 16;
            }
            // render() without flush keeps the (split) list; a second render of
            // it must not split again (that would draw each shadow twice).
            {
                var warm = try gpu.Backend.CommandEncoder.init(queue);
                defer warm.deinit();
                var warm_pass = try warm.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
                try sdf.render(&warm_pass);
                warm_pass.end();
                var warm_command = try warm.finish();
                defer warm_command.deinit();
                try warm_command.submitChecked();
                try warm_command.waitChecked(5000);
            }
            const split_len = sdf.instances.items.len;
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            const before = render.sdfDrawCallsTotal();
            try sdf.render(&pass);
            if (sdf.instances.items.len != split_len) return error.OuterShadowSplitNotIdempotent;
            sdf.instances.clearRetainingCapacity();
            // Items 4 and 8 carry outer shadows: D3D12 draws each as its body then an
            // outer-shadow pass right after it (one extra draw each; in the
            // all-general version the five-and-four body runs each end in one).
            if (render.sdfDrawCallsTotal() - before != (if (version == 0) (if (clip_kind == 0) @as(u64, 11) else 9) else 4)) return error.IncorrectSolidBatchSplit;
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            try target.readBgra8(24, 12, &pixels[version], 24 * 4);
        }
        if (!std.mem.eql(u8, &pixels[0], &pixels[1])) return error.SolidBatchOrderChangedPixels;
    }
    std.debug.print("PASS: mixed plain/solid/gradient/shadow SDF batch keeps overlap order (9/7 specialized batches vs 1 general), 576 byte-exact pixels against forced full shader, shape-mask-free/rounded/rect clips and asymmetric borders\n", .{});
}

/// A general instance with an inset shadow is drawn as layer passes (border,
/// inset shadow, body, outer shadows; see SdfRenderer.splitLayers). Compare it
/// with the inset-rect specialization, which draws inset and border in one
/// program: a wrong layer order puts the border over the inset shadow.
fn checkInsetLayers(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 32, .height = 24 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var pixels: [2][32 * 24 * 4]u8 = undefined;
    for (0..2) |version| {
        sdf.beginFrame(32, 24, 1, 0);
        try sdf.addRoundedRect(4.5, 3.25, 22, 16.5, .{ 0.2, 0.5, 0.8, 0.6 }, .{ 4, 2, 5, 3 });
        const item = &sdf.instances.items[0];
        item.border_widths = .{ 2, 3, 2.5, 3.5 };
        item.border_color = .{ 0.9, 0.1, 0.1, 0.9 };
        item.shadow_color = .{ 1, 1, 0.9, 0.9 };
        item.shadow_blur = 1.5;
        item.shadow_offset_x = 2;
        item.shadow_offset_y = 2.5;
        item.packed_flags = 1 << 24;
        // Unused noise seed: general program, so the instance is split.
        if (version == 1) item.packed_flags |= 1 << 16;
        var encoder = try gpu.Backend.CommandEncoder.init(queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
        const before = render.sdfDrawCallsTotal();
        try sdf.flush(&pass);
        // inset-rect + outer shadow, or border + inset + body + outer shadow.
        if (render.sdfDrawCallsTotal() - before != @as(u64, if (version == 0) 2 else 4)) return error.IncorrectInsetLayerDraws;
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        try target.readBgra8(32, 24, &pixels[version], 32 * 4);
    }
    var maximum: u8 = 0;
    for (pixels[0], pixels[1]) |x, y| maximum = @max(maximum, if (x > y) x - y else y - x);
    // Layer passes store 8-bit intermediates: two extra rounding steps.
    if (maximum > 2) {
        std.debug.print("inset layer passes max channel error {d}\n", .{maximum});
        return error.InsetLayerPassesChangedPixels;
    }
    std.debug.print("PASS: inset shadow layer passes (border, inset, body, outer) match the one-program inset-rect specialization, max channel error {d}, per-side border + offset inset + translucent fill\n", .{maximum});
}

fn checkPlainRectClip(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 32, .height = 24 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    const clips = [_][4]f32{
        .{ 0, 0, -1, -1 },             .{ 4.25, 3.5, 8.75, 6.25 },
        .{ 10, 8, 0, 0 },              .{ -30, -30, 2, 2 },
        .{ 50, 50, 4, 4 },             .{ -2.25, -1.5, 10.125, 8.25 },
        .{ 5.125, 4.25, 0.125, 0.25 }, .{ 0, 0, 32, 24 },
    };
    var pixels: [2][32 * 24 * 4]u8 = undefined;
    for (0..2) |masked| for (0..6) |material| for (0..5) |mode| for ([_]f32{ 1, 1.75, 2 }) |scale| for (clips) |clip| {
        for (0..2) |version| {
            sdf.beginFrame(32 / scale, 24 / scale, scale, 0);
            sdf.setRectClip(clip);
            if (masked == 1) sdf.setClipMask(1, .{ 2.25 / scale, 1.5 / scale, 27 / scale, 20 / scale }, @splat(3 / scale), 0, 0, 0, @splat(0), @splat(.{ 0, 0 }));
            try sdf.addRoundedRect(-40.25, -30.125, 100, 80, .{ 0.3, 0.6, 0.8, 0.45 }, @splat(0));
            try sdf.addRoundedRect(4.375, 2.125, 8.5, 9.75, .{ 0.8, 0.2, 0.4, 1 }, @splat(0));
            for (sdf.instances.items) |*item| {
                if (material == 1 or material >= 3) {
                    item.corner_radii = .{ 1, 2, 3, 0.5 };
                    item.border_width = 0.75;
                    item.border_color = .{ 0.9, 0.1, 0.3, 0.6 };
                }
                if (material >= 3) item.border_widths = .{ 0.5, 1.25, 2.5, 0.75 };
                if (material == 4) item.fill_color[3] = 0;
                if (material == 5) {
                    item.border_widths = .{ 14, 30, 25, 20 };
                    item.fill_color[3] = 0.0009;
                }
                if (material == 2) {
                    item.shadow_blur = 3;
                    item.shadow_offset_x = 2.75;
                    item.shadow_offset_y = -1.5;
                }
                if (version == 1) item.packed_flags |= 1 << 16;
            }
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            if (mode != 1) pass.setViewport(if (mode == 2) 1 else 0, 0, if (mode == 4) 16 else 32, if (mode == 4) 12 else 24, 0, 1);
            if (mode == 3) pass.setScissorRect(2, 1, 27, 21);
            try sdf.flush(&pass);
            // A later unclipped draw must inherit only the caller's scissor.
            sdf.setRectClip(.{ 0, 0, -1, -1 });
            try sdf.addRoundedRect(0, 10, 32, 2, .{ 0.1, 0.7, 0.3, 0.4 }, @splat(0));
            if (version == 1) sdf.instances.items[0].packed_flags |= 1 << 16;
            try sdf.flush(&pass);
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            try target.readBgra8(32, 24, &pixels[version], 32 * 4);
        }
        if (!std.mem.eql(u8, &pixels[0], &pixels[1])) {
            var changed: usize = 0;
            var max_delta: u32 = 0;
            for (pixels[0], pixels[1], 0..) |actual, expected, i| {
                if (actual == expected) continue;
                max_delta = @max(max_delta, @abs(@as(i32, actual) - expected));
                if (changed < 8) std.debug.print("CLIP_DIFF channel={d} actual={d} expected={d}\n", .{ i, actual, expected });
                changed += 1;
            }
            std.debug.print("CLIP_DIFF mask={d} material={d} mode={d} scale={d} clip={any} channels={d} max={d}\n", .{ masked, material, mode, scale, clip, changed, max_delta });
            return error.ClippedPlainRectChangedPixels;
        }
    };
    std.debug.print("PASS: clipped plain/rounded bordered rectangles match general shader byte-exactly: 1440 pairs, fractional/disabled/empty/outside/thin clips, scale1/1.75/2, viewport fallback and caller scissor restoration\n", .{});
}

extern fn zenit_d12_test_opaque_clear_count() c_long;
fn checkOpaqueRegions(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 128, .height = 96 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var pixels: [3][128 * 96 * 4]u8 = undefined;
    const before = zenit_d12_test_opaque_clear_count();
    for (0..2) |transparent| for (0..4) |masked| for ([_]f32{ 1, 1.75, 2 }) |scale| for (0..2) |bordered| for (0..2) |clipped| {
        const before_pair = zenit_d12_test_opaque_clear_count();
        const skipped_before = sdf.transparent_interior_batches;
        var draws: [3]u32 = undefined;
        for (0..3) |reference| {
            const regions = sdf.region_pipelines;
            defer sdf.region_pipelines = regions;
            if (reference == 2) sdf.region_pipelines = @splat(null);
            const draw_start = gpu.Backend.RenderPass.frame_draw_call_count;
            sdf.beginFrame(128 / scale, 96 / scale, scale, 0);
            if (clipped == 1) sdf.setRectClip(.{ 1.25 / scale, 0.75 / scale, 123.5 / scale, 92.5 / scale });
            if (masked != 0) sdf.setClipMask(if (masked == 3) 2 else 1, .{ 2 / scale, 1 / scale, 124 / scale, 94 / scale }, @splat((if (masked == 2) @as(f32, 100) else 4) / scale), 0, 0, 0, @splat(0), @splat(.{ 0, 0 }));
            try sdf.addRoundedRect(-8.25, -5.5, 180, 130, .{ 0.31, 0.67, 0.89, 1 }, @splat(0));
            try sdf.addRoundedRect(6.5, 8.25, 100, 65, .{ 0.8, 0.1, 0.3, 0.45 }, @splat(3));
            try sdf.addRoundedRect(14.25, 9.5, 110, 100, .{ 0.123, 0.456, 0.789, 1 }, @splat(0));
            if (bordered == 1) for (sdf.instances.items) |*item| {
                item.corner_radii = .{ 1, 2, 3, 0.5 };
                item.border_widths = .{ 0.5, 1.25, 2.5, 0.75 };
                item.border_color = .{ 0.4, 0.7, 0.1, 0.6 };
            };
            if (transparent == 1) for (sdf.instances.items) |*item| {
                item.fill_color[3] = 0;
            };
            if (reference == 1) for (sdf.instances.items) |*item| {
                item.packed_flags |= 1 << 16;
            };
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            if (pass.clearOpaque(.{ 1, 0, 0, 0.5 }, .{ 0, 0, 20, 20 })) return error.AcceptedTranslucentClear;
            if (pass.clearOpaque(.{ 1, 0, 0, 1 }, .{ 127, 0, 20, 20 })) return error.AcceptedOutOfBoundsClear;
            if (clipped == 1) pass.setScissorRect(2, 1, 120, 90);
            const original_items = sdf.instances.items[0..3].*;
            try sdf.render(&pass);
            if (!std.mem.eql(u8, std.mem.sliceAsBytes(&original_items), std.mem.sliceAsBytes(sdf.instances.items))) return error.OpaqueClearMutatedInstances;
            sdf.instances.clearRetainingCapacity();
            try sdf.addRoundedRect(0, 20, 128, 2, .{ 0.9, 0.6, 0.1, 0.5 }, @splat(0));
            if (reference == 1) sdf.instances.items[0].packed_flags |= 1 << 16;
            try sdf.flush(&pass);
            pass.end();
            draws[reference] = gpu.Backend.RenderPass.frame_draw_call_count - draw_start;
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            try target.readBgra8(128, 96, &pixels[reference], 128 * 4);
        }
        const used_clear = zenit_d12_test_opaque_clear_count() > before_pair;
        if (used_clear != (masked <= 1 and transparent == 0)) return error.IncorrectMaskedClearEligibility;
        if ((sdf.transparent_interior_batches > skipped_before) != (masked <= 1 and transparent == 1)) return error.IncorrectTransparentInteriorEligibility;
        if (!std.mem.eql(u8, &pixels[0], &pixels[2])) return error.RegionArrayFallbackChangedPixels;
        if (device.supportsVertexViewportIndex() and masked <= 1 and (transparent == 1 or masked == 1)) {
            if (draws[0] >= draws[2]) return error.RegionArrayDidNotReduceDraws;
        } else if (draws[0] != draws[2]) return error.UnexpectedRegionArrayDraws;
        if (!std.mem.eql(u8, &pixels[0], &pixels[1])) {
            var changed: usize = 0;
            var max_delta: u32 = 0;
            for (pixels[0], pixels[1], 0..) |actual, expected, channel| {
                if (actual == expected) continue;
                if (changed < 8) std.debug.print("CLEAR_DIFF channel={d} actual={d} expected={d}\n", .{ channel, actual, expected });
                max_delta = @max(max_delta, @abs(@as(i32, actual) - expected));
                changed += 1;
            }
            std.debug.print("CLEAR_DIFF mask={d} scale={d} bordered={d} clipped={d} channels={d} max={d}\n", .{ masked, scale, bordered, clipped, changed, max_delta });
            return error.OpaqueClearChangedPixels;
        }
    };
    const clears = zenit_d12_test_opaque_clear_count() - before;
    if (clears < 12) return error.OpaqueClearPathNotExercised;
    std.debug.print("PASS: opaque/transparent interiors 96 byte-exact triples (merged/four-draw/general), verified reduced draw counts, clears={d}, sRGB/overlap order/alpha/borders/scale/scissor/rejected invalid requests\n", .{clears});
}

fn profileSolidRectClip(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 1024, .height = 768 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var samples: [2][7]u64 = undefined;
    const baseline = try a.alloc(u8, 1024 * 768 * 4);
    defer a.free(baseline);
    const candidate = try a.alloc(u8, baseline.len);
    defer a.free(candidate);
    for (0..3) |material| {
        for (0..8) |i| for (0..2) |mode| {
            sdf.beginFrame(1024, 768, 1, 0);
            if (material == 2) sdf.setClipMask(1, .{ 400, 300, 250, 250 }, @splat(16), 0, 0, 0, @splat(0), @splat(.{ 0, 0 }));
            sdf.setRectClip(.{ 480.25, 350.5, 64.5, 64.25 });
            try sdf.addRoundedRect(0, 0, 1024, 768, .{ 0.3, 0.6, 0.8, 0.45 }, @splat(if (material == 0) @as(f32, 0) else 12));
            // A transparent shadow expands the original six-vertex quad and
            // disables tiling, isolating scissor cost in both modes.
            sdf.instances.items[0].shadow_blur = 3;
            if (material != 0) {
                sdf.instances.items[0].border_width = 1.25;
                sdf.instances.items[0].border_color = .{ 0.8, 0.2, 0.4, 0.8 };
            }
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            // The default viewport is identical, but only the explicit one enables
            // conservative clipping. All other shader/material/geometry is equal.
            if (mode == 1) pass.setViewport(0, 0, 1024, 768, 0, 1);
            try sdf.flush(&pass);
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            if (i > 0) samples[mode][i - 1] = command.gpuElapsedMicros() orelse return error.MissingProfileTimestamp;
            if (i == 7) try target.readBgra8(1024, 768, if (mode == 0) baseline else candidate, 1024 * 4);
        };
        if (!std.mem.eql(u8, baseline, candidate)) return error.ScissorProfilePixelsDiffer;
        std.debug.print("SDF_CLIP_PROFILE material={d} pixels=786432 byte_exact=true baseline_us={any} clipped_us={any}\n", .{ material, samples[0], samples[1] });
    }
}

/// Signed distance (device px) to a rounded rect {x, y, w, h} with radius r.
fn roundedRectDistance(x: f32, y: f32, rect: [4]f32, r: f32) f32 {
    const qx = @abs(x - (rect[0] + rect[2] / 2)) - rect[2] / 2 + r;
    const qy = @abs(y - (rect[1] + rect[3] / 2)) - rect[3] / 2 + r;
    return @min(@max(qx, qy), 0) + @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) - r;
}

fn checkShadowRing(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 96, .height = 80 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var pixels: [2][96 * 80 * 4]u8 = undefined;
    var pairs: usize = 0;
    var changed_bytes: usize = 0;
    var max_error: u8 = 0;
    for ([_]f32{ 1, 1.75, 2 }) |scale| for ([_]u32{ 0, 1 }) |clip_kind| for ([_]bool{ false, true }) |opaque_background| for (0..15) |variant| {
        for (0..2) |version| {
            sdf.beginFrame(96, 80, scale, 0);
            if (opaque_background) try sdf.addRoundedRect(0, 0, 96 / scale, 80 / scale, .{ 0.12, 0.24, 0.36, 1 }, @splat(0));
            sdf.setRectClip(.{ 1.25 / scale, 4.5 / scale, 91 / scale, 70 / scale });
            sdf.setClipMask(clip_kind, .{ 2.25 / scale, 3.5 / scale, 89 / scale, 71 / scale }, @splat(3 / scale), 0, 0, 0, @splat(0), @splat(.{ 0, 0 }));
            const w: f32 = if (variant == 5 or variant == 6) 4 else 60.5;
            const h: f32 = if (variant == 5) 4 else 48.25;
            const spread: f32 = if (variant == 1) 5 else if (variant == 2) -4 else 0;
            const radii: [4]f32 = if (variant == 3) .{ 0, 2 / scale, 12 / scale, 4 / scale } else @splat(5 / scale);
            try sdf.addShadowRectSpread(14.25 / scale, 12.5 / scale, w / scale, h / scale, .{ 0.6, 0.2, 0.1, if (variant == 7) 0.4 else 0 }, .{ 0.15, 0.3, 0.45, 0.6 }, (if (variant == 8) @as(f32, 0) else 9) / scale, (if (variant == 4) @as(f32, 12) else 2) / scale, (if (variant == 4) @as(f32, -8) else 3) / scale, spread / scale, radii);
            const shadow = &sdf.instances.items[sdf.instances.items.len - 1];
            if (variant == 9) {
                shadow.border_widths = .{ 1 / scale, 2 / scale, 0, 0 };
                shadow.border_color = .{ 0.8, 0.1, 0.2, 0.7 };
            }
            if (variant == 10) shadow.packed_flags |= 1 << 24; // Inset must not use the hollow mesh.
            if (variant >= 11) {
                // Separate dual-shadow instances exercise nonzero shadow2 indices
                // and alpha compositing over both transparent and opaque targets.
                for (0..2) |n| {
                    try sdf.addDualShadowRect(10.25 + @as(f32, @floatFromInt(n)) * 9, 9.5, 28.5, 20.25, .{ 0.7, 0.4, 0.1, if (variant == 11) 0 else if (variant == 12) 0.4 else 1 }, .{ 0.2, 0.4, 0.1, 0.5 }, 4.5, -2, 3, .{ .color = .{ 0.1, 0.2, 0.7, 0.6 }, .blur = 7.5, .offset_x = 4, .offset_y = -2 }, .{ 1, 3, 2, 4 });
                    if (variant == 14) {
                        const dual = &sdf.instances.items[sdf.instances.items.len - 1];
                        dual.border_width = 1;
                        dual.border_color = .{ 1, 0, 0, 0.5 };
                    }
                }
            }
            // Adjacent eligible shadows share one 24-vertex instanced batch;
            // overlap verifies instance offsets and alpha ordering as well.
            try sdf.addShadowRectSpread(35.5 / scale, 28.25 / scale, 20.5 / scale, 30.25 / scale, .{ 0, 0, 0, 0 }, .{ 0.5, 0.2, 0.1, 0.4 }, 5 / scale, -2 / scale, 1 / scale, -1 / scale, @splat(3 / scale));
            if (version == 1) for (sdf.instances.items) |*item| {
                item.packed_flags |= 1 << 16;
            };
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            try sdf.flush(&pass);
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            try target.readBgra8(96, 80, &pixels[version], 96 * 4);
        }
        if (!std.mem.eql(u8, &pixels[0], &pixels[1])) {
            var changed: usize = 0;
            var maximum: u8 = 0;
            var outliers: usize = 0;
            for (0..80) |py| for (0..96) |px| {
                // Under a rounded clip mask the general reference's two passes
                // scale the shadow's blend factor by clip coverage c
                // (cS + cB(1 - cSa) instead of cS + cB(1 - Sa)), which differs
                // only inside the mask's antialiasing band: compare outside it.
                if (clip_kind == 1 and @abs(roundedRectDistance(@as(f32, @floatFromInt(px)) + 0.5, @as(f32, @floatFromInt(py)) + 0.5, .{ 2.25, 3.5, 89, 71 }, 3)) < 1.5) continue;
                const i = (py * 96 + px) * 4;
                var pixel_max: u8 = 0;
                for (pixels[0][i .. i + 4], pixels[1][i .. i + 4]) |x, y| if (x != y) {
                    changed += 1;
                    pixel_max = @max(pixel_max, if (x > y) x - y else y - x);
                };
                if (pixel_max > 3) outliers += 1;
                maximum = @max(maximum, pixel_max);
            };
            std.debug.print("shadow ring pixel delta scale={d} clip={d} opaque={} variant={d} changed={d} max={d}\n", .{ scale, clip_kind, opaque_background, variant, changed, maximum });
            // Splitting a quad changes interpolation rounding at a few pixels
            // (±1 against the single-pass reference). The general reference now
            // stores the body as an 8-bit intermediate and blends the outer
            // shadows over it in fixed point: up to two more rounding steps on
            // body edges (≤3), and at the clipped quad seams of the production
            // dual program those compound to ≤5 at isolated pixels (measured: 2
            // of 7680). Systematic errors are wide: a wrong composite order
            // changed hundreds of pixels by up to 11.
            if (maximum > 6 or outliers > 4) return error.ShadowRingChangedPixels;
            changed_bytes += changed;
            max_error = @max(max_error, maximum);
        }
        pairs += 1;
    };
    std.debug.print("PASS: shadow ring {d} full-frame pairs, changed_bytes={d} max_channel_error={d} (≤3, ≤4 isolated seam pixels ≤6; rounded-clip AA band excluded), overlapping instanced shadows, transparent/opaque targets, scale1/1.75/2, fractional rect/rounded clips, spread+/-, offsets, asymmetric radii, degenerate holes and fill/border/inset/zero-blur fallback\n", .{ pairs, changed_bytes, max_error });
}

// Multiple immutable uniform slots must survive both later uploads and growth
// of the overflow buffer until the single final submission completes.
fn checkUniformOverflow(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 600, .height = 4 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    sdf.beginFrame(600, 4, 1, 0);
    var encoder = try gpu.Backend.CommandEncoder.init(queue);
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
    pass.setViewport(0, 0, 600, 4, 0, 1);
    for (0..300) |i| {
        sdf.setRectClip(.{ @floatFromInt(i * 2), 0, 2, 4 });
        try sdf.addRoundedRect(-1, -1, 602, 6, if (i % 2 == 0) .{ 1, 0, 0, 1 } else .{ 0, 0, 1, 1 }, @splat(0));
        try sdf.flush(&pass);
    }
    if (sdf.uniform_overflow_count == 0) return error.UniformOverflowNotExercised;
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    try command.waitChecked(5000);
    var pixels: [600 * 4 * 4]u8 = undefined;
    try target.readBgra8(600, 4, &pixels, 600 * 4);
    for (0..600) |x| {
        const offset = (2 * 600 + x) * 4;
        const expected: [4]u8 = if ((x / 2) % 2 == 0) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
        if (!std.mem.eql(u8, pixels[offset..][0..4], &expected)) return error.UniformSlotOverwritten;
    }
    std.debug.print("PASS: 300 distinct shared SDF uniform slots preserve clip/color pixels across overflow and a single delayed submission\n", .{});
}

fn profileImageMaskSpecialization(a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    const renderer = try a.create(render.ImageRenderer);
    defer a.destroy(renderer);
    try renderer.init(a, device);
    defer renderer.deinit();
    var texels: [64 * 64 * 4]u8 = undefined;
    for (0..64 * 64) |i| {
        texels[i * 4] = @intCast(i % 64 * 3);
        texels[i * 4 + 1] = @intCast(i / 64 * 3);
        texels[i * 4 + 2] = @intCast(i % 31 * 4);
        texels[i * 4 + 3] = @intCast(192 + i % 64);
    }
    const texture = try renderer.loadTexture(64, 64, &texels);
    var target = try device.createTexture(a, .{ .size = .{ .width = 1024, .height = 768 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    const baseline = try a.alloc(u8, 1024 * 768 * 4);
    defer a.free(baseline);
    const candidate = try a.alloc(u8, baseline.len);
    defer a.free(candidate);
    var samples: [2][7]u64 = undefined;
    for (0..4) |variant| {
        for (0..8) |i| for (0..2) |mode| {
            const specialized = renderer.unmasked_pipeline;
            defer renderer.unmasked_pipeline = specialized;
            if (mode == 0) renderer.unmasked_pipeline = null;
            const scale: f32 = if (variant == 3) 1.75 else 1;
            renderer.beginFrame(1024 / scale, 768 / scale, scale);
            if (variant == 3) renderer.setClipMask(1, .{ 40, 40, 420, 330 }, @splat(24), 0, 0, 0, @splat(0), @splat(.{ 0, 0 }));
            if (variant != 0) renderer.setRectClip(.{ 17.25, 13.75, 780.5, 690.25 });
            const uv: [4]f32 = if (variant == 0) .{ 0, 0, 1, 1 } else .{ 0.125, 0.25, 0.875, 0.75 };
            const tint: [4]f32 = if (variant == 0) .{ 1, 1, 1, 1 } else .{ 0.8, 0.6, 0.4, 0.75 };
            const radius: f32 = if (variant == 0) 0 else 17.5;
            const opacity: f32 = if (variant == 0) 1 else 0.45;
            const rotation: f32 = if (variant >= 2) 0.17 else 0;
            if (variant == 2) {
                try renderer.addImageUVPremultiplied(texture, 0, 0, 1024 / scale, 768 / scale, uv, tint, @splat(radius), opacity, rotation);
            } else try renderer.addImageUV(texture, 0, 0, 1024 / scale, 768 / scale, uv, tint, radius, opacity, rotation);
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0.1, .g = 0.3, .b = 0.5, .a = 0.7 } }} });
            try renderer.flush(&pass);
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            if (i > 0) samples[mode][i - 1] = command.gpuElapsedMicros() orelse return error.MissingImageProfileTimestamp;
            if (i == 7) try target.readBgra8(1024, 768, if (mode == 0) baseline else candidate, 1024 * 4);
        };
        if (!std.mem.eql(u8, baseline, candidate)) return error.ImageMaskSpecializationChangedPixels;
        std.debug.print("IMAGE_MASK_PROFILE variant={d} pixels=786432 byte_exact=true general_us={any} specialized_us={any}\n", .{ variant, samples[0], samples[1] });
    }
}

fn profileRegionArrays(io: std.Io, a: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    if (!device.supportsVertexViewportIndex()) return;
    var sdf = try render.SdfRenderer.init(a, device);
    defer sdf.deinit();
    var target = try device.createTexture(a, .{ .size = .{ .width = 1024, .height = 768 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    const baseline = try a.alloc(u8, 1024 * 768 * 4);
    defer a.free(baseline);
    const candidate = try a.alloc(u8, baseline.len);
    defer a.free(candidate);
    var samples: [2][7]u64 = undefined;
    var cpu_samples: [2][7]u64 = undefined;
    for (0..2) |opaque_fill| {
        for (0..8) |i| for (0..2) |mode| {
            const regions = sdf.region_pipelines;
            defer sdf.region_pipelines = regions;
            if (mode == 0) sdf.region_pipelines = @splat(null);
            sdf.beginFrame(1024, 768, 1, 0);
            sdf.setClipMask(1, .{ 2.25, 1.5, 1018, 764 }, @splat(9), 0, 0, 0, @splat(0), @splat(.{ 0, 0 }));
            try sdf.addRoundedRect(0, 0, 1024, 768, .{ 0.3, 0.6, 0.8, @floatFromInt(opaque_fill) }, @splat(6));
            sdf.instances.items[0].border_width = 2;
            sdf.instances.items[0].border_color = .{ 0.8, 0.2, 0.4, 0.75 };
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0.12, .g = 0.18, .b = 0.3, .a = 1 } }} });
            pass.setScissorRect(3, 2, 1015, 760);
            var timer = try @import("zenit_time").Timer.start(io);
            try sdf.flush(&pass);
            pass.end();
            const cpu_us = timer.read() / 1000;
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            if (i > 0) {
                samples[mode][i - 1] = command.gpuElapsedMicros() orelse return error.MissingRegionProfileTimestamp;
                cpu_samples[mode][i - 1] = cpu_us;
            }
            if (i == 7) try target.readBgra8(1024, 768, if (mode == 0) baseline else candidate, 1024 * 4);
        };
        if (!std.mem.eql(u8, baseline, candidate)) return error.RegionProfilePixelsDiffer;
        std.debug.print("REGION_ARRAY_PROFILE opaque={d} pixels=786432 byte_exact=true four_gpu_us={any} merged_gpu_us={any} four_cpu_us={any} merged_cpu_us={any}\n", .{ opaque_fill, samples[0], samples[1], cpu_samples[0], cpu_samples[1] });
    }
}
