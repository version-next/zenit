const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const reference = @import("windows_gpu_renderer_image_contract.zig");
const a = std.heap.page_allocator;
const Icon = extern struct { rect: [4]f32, color: [4]f32 = .{ 0.2, 0.7, 0.9, 0.65 }, clip: [4]f32, radius: f32, opacity: f32, rotate: f32, padding: f32 = 0 };
// Keep sampled coordinates away from point-filter texel boundaries. D3D
// permits 16.8 (or greater) addressing precision; the previous UV range put
// a skewed glyph sample at 2.999446 texels, selecting different valid texels
// on ARM64 and x64 WARP. These endpoints leave >=0.0166 texel margin while
// retaining subrect, skew, snap, scale and every per-pixel comparison.
// https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm#PointSampleAddressing
const Glyph = extern struct { position: [2]f32, size: [2]f32, uv: [4]f32 = .{ 0.103, 0.15, 0.933, 0.85 }, color: [4]f32 = .{ 0.2, 0.7, 0.9, 0.65 }, clip: [4]f32, skew: f32, page: f32 = 3, is_color: f32, snap: f32 };
comptime {
    if (@sizeOf(Icon) != 64 or @sizeOf(Glyph) != 80 or @offsetOf(Glyph, "snap") != 76) @compileError("Glyph/icon ABI mismatch");
}
fn uniformsFor(scale: f32, clip_case: usize) reference.Uniforms {
    var u = reference.Uniforms{ .scale = scale, .clip_kind = @intCast(@min(clip_case, 3)), .clip_rect = .{ 1 / scale, 1 / scale, 6 / scale, 6 / scale }, .clip_radii = .{ @floatCast(reference.clip_radii_px[0] / scale), @floatCast(reference.clip_radii_px[1] / scale), @floatCast(reference.clip_radii_px[2] / scale), @floatCast(reference.clip_radii_px[3] / scale) }, .fill_rule = @intFromBool(clip_case == 4) };
    const points = [_][2]f32{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 6 }, .{ 0, 6 }, .{ 2, 2 }, .{ 4, 2 }, .{ 4, 4 }, .{ 2, 4 } };
    for (points, 0..) |point, i| u.points[i] = .{ point[0] / scale, point[1] / scale };
    return u;
}
fn clipping(x: usize, y: usize, clip_case: usize) f64 {
    var cover: f64 = 1;
    if (clip_case > 0) cover *= reference.aaCoverage(x, y, 1);
    if (clip_case == 1 or clip_case == 2) cover *= reference.aaCoverage(x, y, clip_case + 1);
    if (clip_case >= 3) cover *= reference.polygonCoverage(x, y, clip_case == 4);
    return cover;
}
fn render(context: *r.Context, pipeline: *const d12.RenderPipeline, target: *const r.Texture, mask: *const r.Texture, color: *const r.Texture, sampler: *const d12.Sampler, uniform: reference.Uniforms, data: []const u8, stride: usize, clear: [4]f64) !void {
    var buffer = try context.createBuffer(a, .{ .size = stride * 2 + data.len, .usage = .{ .vertex = true, .map_write = true } });
    defer buffer.destroy();
    const mapped = try buffer.getMappedRange(0, buffer.size);
    @memset(mapped, 0); // Sentinel instances have zero size and color.
    @memcpy(mapped[stride * 2 ..], data);
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var encoder = try c.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var view = target.binding().createView();
    defer view.destroy();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = @floatCast(clear[0]), .g = @floatCast(clear[1]), .b = @floatCast(clear[2]), .a = @floatCast(clear[3]) } }} });
    pass.setPipeline(pipeline);
    pass.setVertexBuffer(1, &buffer, stride);
    pass.setFragmentBuffer(1, &buffer, stride);
    const text_uniform = extern struct {
        base: reference.Uniforms,
        gamma: [4]f32 = @splat(0),
        settings: [4]f32 = @splat(0),
    }{ .base = uniform };
    const bytes = if (stride == 80) std.mem.asBytes(&text_uniform) else std.mem.asBytes(&uniform);
    try pass.setVertexBytesChecked(0, bytes);
    try pass.setFragmentBytesChecked(0, bytes);
    pass.setFragmentTexture(0, mask);
    pass.setFragmentTexture(1, color);
    pass.setFragmentSampler(0, sampler);
    try pass.drawChecked(6, 1, 0, 1);
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    try command.waitChecked(5000);
}
fn check(actual: []const u8, expected: [4]f64, x: usize, y: usize, kind: []const u8, variant: usize) !void {
    for (expected, 0..) |value, ch| {
        const byte: i32 = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
        if (@abs(@as(i32, actual[ch]) - byte) > 2) {
            std.debug.print("{s} mismatch variant={d} x={d} y={d} ch={d} actual={d} expected={d}\n", .{ kind, variant, x, y, ch, actual[ch], byte });
            return error.IncorrectGlyphPixel;
        }
    }
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("glyph context cleanup");
    var sampler = try device.createSampler(a, .{});
    defer sampler.destroy();
    var mask = try context.createTexture(a, .{ .size = .{ .width = 4, .height = 4 }, .format = .r8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    defer mask.destroy();
    const mask_bytes = [_]u8{ 0, 64, 128, 255, 255, 128, 64, 0, 64, 255, 0, 128, 128, 0, 255, 64 };
    try mask.writeRegion(0, 0, 0, 4, 4, &mask_bytes, 4);
    var color = try context.createTexture(a, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    defer color.destroy();
    var color_bytes: [64]u8 = undefined;
    for (0..16) |i| {
        const alpha = mask_bytes[i];
        @memcpy(color_bytes[i * 4 ..][0..4], &[_]u8{ alpha / 2, alpha / 4, alpha, alpha });
    }
    try color.writeRegion(0, 0, 0, 4, 4, &color_bytes, 16);
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var output: [256]u8 = undefined;
    var icon_draws: usize = 0;
    {
        var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.icon);
        defer module.deinit();
        var vs = try module.getFunction("icon_vertex_main");
        defer vs.deinit();
        var ps = try module.getFunction("icon_fragment_main");
        defer ps.deinit();
        var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vs, .fragment_function = &ps, .color_attachment_formats = &.{.bgra8_unorm} });
        defer pipeline.deinit();
        if (try pipeline.bufferStride(0, 1) != 64) return error.IncorrectIconStride;
        for ([_]f32{ 1, 2 }) |scale| for ([_]f32{ 0, 0.35, 1 }) |opacity| for (0..2) |rotate| for (0..5) |clip_case| {
            const instance = Icon{ .rect = .{ 0, 0, 8 / scale, 8 / scale }, .radius = 1.3 / scale, .opacity = opacity, .rotate = if (rotate == 0) 0 else std.math.pi / 2.0, .clip = if (clip_case == 0) .{ 0, 0, -1, -1 } else .{ 0.5 / scale, 0.5 / scale, 7 / scale, 7 / scale } };
            try render(context, &pipeline, &target, &mask, &color, &sampler, uniformsFor(scale, clip_case), std.mem.asBytes(&instance), 64, @splat(0));
            try target.readBgra8(8, 8, &output, 32);
            for (0..8) |y| for (0..8) |x| {
                const tx = if (rotate == 0) x / 2 else y / 2;
                const ty = if (rotate == 0) y / 2 else (7 - x) / 2;
                var alpha = @as(f64, @floatFromInt(mask_bytes[ty * 4 + tx])) / 255 * reference.aaCoverage(x, y, 0) * clipping(x, y, clip_case) * opacity * instance.color[3];
                if (alpha < 0.001) alpha = 0;
                try check(output[(y * 8 + x) * 4 ..][0..4], .{ alpha * instance.color[2], alpha * instance.color[1], alpha * instance.color[0], alpha }, x, y, "icon", icon_draws);
            };
            icon_draws += 1;
        };
    }
    for (0..64) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_ICON_RGBA8_HEX={s}\nPASS: production HLSL icon, {d} draws/{d} CPU-reference pixels (byte tolerance2), R8 mask/opacity/tint, stride64, rotation, scale, corner/rect/shape/polygon clips and nonzero instance/buffer offsets\n", .{ std.fmt.bytesToHex(output, .lower), icon_draws, icon_draws * 64 });
    var text_draws: usize = 0;
    {
        var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.text);
        defer module.deinit();
        var vs = try module.getFunction("text_vertex_main");
        defer vs.deinit();
        var ps = try module.getFunction("text_fragment_main");
        defer ps.deinit();
        var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vs, .fragment_function = &ps, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{}, .dual_source_blending = true });
        defer pipeline.deinit();
        if (try pipeline.bufferStride(0, 1) != 80) return error.IncorrectTextStride;
        for ([_]f32{ 1, 2 }) |scale| for (0..2) |is_color| for (0..2) |snap| for (0..2) |skew| for (0..5) |clip_case| {
            const instance = Glyph{ .position = .{ 0.26 / scale, 0.26 / scale }, .size = .{ 7.6 / scale, 7.6 / scale }, .clip = if (clip_case == 0) .{ 0, 0, -1, -1 } else .{ 0.5 / scale, 0.5 / scale, 7 / scale, 7 / scale }, .skew = if (skew == 0) 0 else 0.8 / scale, .is_color = @floatFromInt(is_color), .snap = @floatFromInt(snap) };
            try render(context, &pipeline, &target, &mask, &color, &sampler, uniformsFor(scale, clip_case), std.mem.asBytes(&instance), 80, @splat(0));
            try target.readBgra8(8, 8, &output, 32);
            for (0..8) |y| for (0..8) |x| {
                const base: f64 = if (snap == 1) 0 else 0.26;
                const v = (@as(f64, @floatFromInt(y)) + 0.5 - base) / 7.6;
                const u = (@as(f64, @floatFromInt(x)) + 0.5 - base - (1 - v) * (if (skew == 0) @as(f64, 0) else 0.8)) / 7.6;
                var expected: [4]f64 = @splat(0);
                if (u >= 0 and u < 1 and v >= 0 and v < 1) {
                    const tx: usize = @intFromFloat(@floor((0.103 + u * 0.83) * 4));
                    const ty: usize = @intFromFloat(@floor((0.15 + v * 0.7) * 4));
                    const coverage = clipping(x, y, clip_case) * instance.color[3];
                    const alpha = @as(f64, @floatFromInt(mask_bytes[ty * 4 + tx])) / 255 * coverage;
                    if (alpha >= 0.001) {
                        if (is_color == 0) expected = .{ alpha * instance.color[2], alpha * instance.color[1], alpha * instance.color[0], alpha } else {
                            for (0..4) |ch| expected[ch] = @as(f64, @floatFromInt(color_bytes[(ty * 4 + tx) * 4 + ch])) / 255 * coverage;
                        }
                    }
                }
                try check(output[(y * 8 + x) * 4 ..][0..4], expected, x, y, "text", text_draws);
            };
            text_draws += 1;
        };
        const lcd = Glyph{ .position = .{ 0, 0 }, .size = .{ 8, 8 }, .uv = .{ 0, 0, 1, 1 }, .clip = .{ 0, 0, -1, -1 }, .skew = 0, .is_color = 2, .snap = 1 };
        const backdrop: [4]f64 = .{ 0.8, 0.6, 0.4, 1 };
        try render(context, &pipeline, &target, &color, &color, &sampler, uniformsFor(1, 0), std.mem.asBytes(&lcd), 80, backdrop);
        try target.readBgra8(8, 8, &output, 32);
        for (0..8) |y| for (0..8) |x| {
            const texel = ((y / 2) * 4 + x / 2) * 4;
            var expected: [4]f64 = .{ 0, 0, 0, 1 };
            for (0..3) |ch| {
                const alpha = @as(f64, @floatFromInt(color_bytes[texel + ch])) / 255 * lcd.color[3];
                expected[ch] = lcd.color[2 - ch] * alpha + backdrop[2 - ch] * (1 - alpha);
            }
            try check(output[(y * 8 + x) * 4 ..][0..4], expected, x, y, "LCD dual source WARP", 0);
        };
        std.debug.print("PASS: WARP production HLSL LCD independent RGB weights over opaque destination: 64 pixel readbacks\n", .{});
    }
    for (0..64) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_TEXT_RGBA8_HEX={s}\nPASS: production HLSL text, {d} draws/{d} CPU-reference pixels (byte tolerance2), R8 grayscale/BGRA color glyph, no color-glyph RGB tint, stride80, snap/continuous position, skew, atlas UV subrect, scale/clips and nonzero instance/buffer offsets\n", .{ std.fmt.bytesToHex(output, .lower), text_draws, text_draws * 64 });
}
