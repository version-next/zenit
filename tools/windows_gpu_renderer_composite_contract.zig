const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
// Layer-local mapping: local = inv · pixel + inv_offset (blend_composite.BlendUniforms).
// The default is the axis-aligned rect at origin (1.25, 0.25).
const Uniforms = extern struct { target_size: [2]f32 = .{ 8, 4 }, rect_size: [2]f32 = .{ 5.5, 3.5 }, src_uv_scale: [2]f32 = .{ 0.5, 0.5 }, inv_offset: [2]f32 = .{ -1.25, -0.25 }, inv: [4]f32 = .{ 1, 0, 0, 1 }, params: [4]f32, corner_radii: [4]f32 = .{ 0, 0, 0, 0 }, clip_rect: [4]f32 = .{ 0, 0, -1, -1 }, clip_shape: [4]f32 = .{ 0, 0, 0, 0 }, clip_shape_rect: [4]f32 = .{ 0, 0, 0, 0 }, clip_shape_radii: [4]f32 = .{ 0, 0, 0, 0 }, warp: [4]f32 = .{ 0, 0, 0, 0 }, src_uv_origin: [4]f32 = .{ 0, 0, 0, 0 } };
comptime {
    // zero warp = no lens warp, zero src_uv_origin = the quad's own texture origin (the pre-warp
    // contract); the layout must match render/blend_composite.zig BlendUniforms byte for byte
    if (@sizeOf(Uniforms) != 176 or @offsetOf(Uniforms, "warp") != 144 or @offsetOf(Uniforms, "src_uv_origin") != 160 or @offsetOf(Uniforms, "inv_offset") != 24 or @offsetOf(Uniforms, "inv") != 32 or @offsetOf(Uniforms, "params") != 48 or @offsetOf(Uniforms, "corner_radii") != 64 or @offsetOf(Uniforms, "clip_rect") != 80 or @offsetOf(Uniforms, "clip_shape_rect") != 112 or @offsetOf(Uniforms, "clip_shape_radii") != 128) @compileError("Blend uniform ABI mismatch");
}
/// Corner radius of the quadrant `(x, y)` (relative to the rect centre) lies in: TL, TR, BR, BL.
fn cornerRadius(x: f64, y: f64, radii: [4]f32) f64 {
    return if (x < 0) (if (y < 0) radii[0] else radii[3]) else (if (y < 0) radii[1] else radii[2]);
}
/// Clip coverage at a target pixel centre (rect x shape), as the shader's zb_clip_coverage.
fn clipCoverage(px: f64, py: f64, u: Uniforms) f64 {
    var coverage: f64 = 1;
    if (u.clip_rect[2] >= 0 and u.clip_rect[3] >= 0) {
        const hx = u.clip_rect[2] * 0.5;
        const hy = u.clip_rect[3] * 0.5;
        const qx = @abs(px - (u.clip_rect[0] + hx)) - hx;
        const qy = @abs(py - (u.clip_rect[1] + hy)) - hy;
        const d = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0);
        coverage *= std.math.clamp(0.5 - d, 0, 1);
    }
    const kind: u32 = @intFromFloat(u.clip_shape[0]);
    if (kind == 1 or kind == 2) {
        const hx = u.clip_shape_rect[2] * 0.5;
        const hy = u.clip_shape_rect[3] * 0.5;
        const x = px - (u.clip_shape_rect[0] + hx);
        const y = py - (u.clip_shape_rect[1] + hy);
        var d: f64 = 0;
        if (kind == 1) {
            const rr = @min(cornerRadius(x, y, u.clip_shape_radii), @min(hx, hy));
            const qx = @abs(x) - hx + rr;
            const qy = @abs(y) - hy + rr;
            d = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - rr;
        } else {
            const sx = @max(hx, 0.001);
            const sy = @max(hy, 0.001);
            d = (@sqrt(x * x / (sx * sx) + y * y / (sy * sy)) - 1) * @min(sx, sy);
        }
        coverage *= std.math.clamp(0.5 - d, 0, 1);
    }
    return coverage;
}
/// The rect rotated by `angle` about its centre (image-pipeline affine), inverted.
fn rotatedUniforms(angle: f32, params: [4]f32) Uniforms {
    const w: f32 = 5.5;
    const h: f32 = 3.5;
    const cx: f32 = 1.25 + w / 2;
    const cy: f32 = 0.25 + h / 2;
    const cs = @cos(angle);
    const sn = @sin(angle);
    // pixel = R · (local - centre_local) + centre  =>  local = R⁻¹ · (pixel - centre) + centre_local
    return .{ .inv = .{ cs, -sn, sn, cs }, .inv_offset = .{ -(cs * cx + sn * cy) + w / 2, -(-sn * cx + cs * cy) + h / 2 }, .params = params };
}
fn decode(byte: u8, srgb: bool, channel: usize) f64 {
    const value = @as(f64, @floatFromInt(byte)) / 255;
    return if (!srgb or channel == 3) value else if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}
fn encode(value: f64, srgb: bool, channel: usize) u8 {
    const v = std.math.clamp(value, 0, 1);
    const nonlinear = if (!srgb or channel == 3) v else if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(nonlinear * 255));
}
fn blend(source: f64, destination: f64, mode: usize) f64 {
    return switch (mode) {
        1 => source * destination,
        2 => source + destination - source * destination,
        3 => if (destination <= 0.5) 2 * source * destination else 1 - 2 * (1 - source) * (1 - destination),
        4 => @min(source, destination),
        5 => @max(source, destination),
        6 => if (source >= 1) 1 else @min(1, destination / @max(1 - source, 0.0001)),
        7 => if (source <= 0) 0 else 1 - @min(1, (1 - destination) / @max(source, 0.0001)),
        8 => if (source <= 0.5) 2 * source * destination else 1 - 2 * (1 - source) * (1 - destination),
        9 => if (source <= 0.5) destination - (1 - 2 * source) * destination * (1 - destination) else destination + (2 * source - 1) * ((if (destination <= 0.25) ((16 * destination - 12) * destination + 4) * destination else @sqrt(destination)) - destination),
        10 => @abs(source - destination),
        11 => source + destination - 2 * source * destination,
        else => source,
    };
}
fn sourceSample(bytes: []const u8, uv: [2]f64, channel: usize, srgb: bool) f64 {
    const x = uv[0] * 4 - 0.5;
    const y = uv[1] * 4 - 0.5;
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    var result: f64 = 0;
    for (0..2) |dy| for (0..2) |dx| {
        const sx: usize = @intCast(std.math.clamp(ix + @as(i32, @intCast(dx)), 0, 3));
        const sy: usize = @intCast(std.math.clamp(iy + @as(i32, @intCast(dy)), 0, 3));
        result += decode(bytes[(sy * 4 + sx) * 4 + channel], srgb, channel) * (if (dx == 0) 1 - fx else fx) * (if (dy == 0) 1 - fy else fy);
    };
    return result;
}
fn verify(output: []const u8, src: []const u8, dst: []const u8, uniforms: Uniforms, mode: usize, srgb: bool) !void {
    for (0..4) |y| for (0..8) |x| {
        const px = @as(f64, @floatFromInt(x)) + 0.5;
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        const local: [2]f64 = .{ uniforms.inv[0] * px + uniforms.inv[2] * py + uniforms.inv_offset[0], uniforms.inv[1] * px + uniforms.inv[3] * py + uniforms.inv_offset[1] };
        const offset = (y * 8 + x) * 4;
        var expected: [4]u8 = undefined;
        if (local[0] < 0 or local[1] < 0 or local[0] >= uniforms.rect_size[0] or local[1] >= uniforms.rect_size[1]) {
            @memcpy(&expected, dst[offset..][0..4]);
        } else {
            var mask: f64 = 1;
            const radius = cornerRadius(local[0] - uniforms.rect_size[0] * 0.5, local[1] - uniforms.rect_size[1] * 0.5, uniforms.corner_radii);
            if (radius > 0.5) {
                const qx = @abs(local[0] - uniforms.rect_size[0] * 0.5) - uniforms.rect_size[0] * 0.5 + radius;
                const qy = @abs(local[1] - uniforms.rect_size[1] * 0.5) - uniforms.rect_size[1] * 0.5 + radius;
                const distance = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
                mask = std.math.clamp(0.5 - distance, 0, 1);
            }
            const uv: [2]f64 = .{ local[0] / uniforms.rect_size[0] * uniforms.src_uv_scale[0], local[1] / uniforms.rect_size[1] * uniforms.src_uv_scale[1] };
            mask *= clipCoverage(px, py, uniforms);
            const src_a = sourceSample(src, uv, 3, srgb) * mask;
            const dst_a = decode(dst[offset + 3], srgb, 3);
            const opacity = uniforms.params[0];
            const effective_a = (if (src_a < 0.0001) @as(f64, 0) else src_a) * opacity;
            const dest_alpha = if (dst_a < 0.0001) @as(f64, 0) else dst_a;
            const result_a = effective_a + dest_alpha * (1 - effective_a);
            expected[3] = encode(result_a, srgb, 3);
            for (0..3) |ch| {
                const source = if (src_a < 0.0001) @as(f64, 0) else sourceSample(src, uv, ch, srgb) * mask / src_a;
                const destination = if (dst_a < 0.0001) @as(f64, 0) else decode(dst[offset + ch], srgb, ch) / dst_a;
                const result = if (result_a < 0.0001) @as(f64, 0) else (1 - effective_a) * dest_alpha * destination + effective_a * dest_alpha * blend(source, destination, mode) + (1 - dest_alpha) * effective_a * source;
                expected[ch] = encode(result, srgb, ch);
            }
        }
        for (0..4) |ch| if (@abs(@as(i32, output[offset + ch]) - @as(i32, expected[ch])) > 2) {
            std.debug.print("composite mismatch srgb={} mode={d} opacity={d} radii={any} x={d} y={d} ch={d} actual={d} expected={d}\n", .{ srgb, mode, uniforms.params[0], uniforms.corner_radii, x, y, ch, output[offset + ch], expected[ch] });
            return error.IncorrectCompositePixel;
        };
    };
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("composite context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.composite);
    defer module.deinit();
    var vertex = try module.getFunction("blend_vertex_main");
    defer vertex.deinit();
    var fragment = try module.getFunction("blend_fragment_main");
    defer fragment.deinit();
    var sampler = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
    defer sampler.destroy();
    var src_bytes: [64]u8 = @splat(0);
    const colors = [_][4]u8{ .{ 0, 128, 128, 128 }, .{ 255, 64, 0, 255 }, .{ 0, 0, 0, 0 }, .{ 64, 0, 96, 128 } };
    for (0..2) |y| for (0..2) |x| @memcpy(src_bytes[(y * 4 + x) * 4 ..][0..4], &colors[y * 2 + x]);
    var dst_bytes: [128]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        const alpha: u8 = switch (x % 3) {
            0 => 0,
            1 => 128,
            else => 255,
        };
        @memcpy(dst_bytes[(y * 8 + x) * 4 ..][0..4], &[_]u8{ alpha / 2, @intCast(@as(u32, alpha) * @as(u32, @intCast(y + 1)) / 4), alpha / 4, alpha });
    };
    var output: [128]u8 = undefined;
    for ([_]gpu.TextureFormat{ .bgra8_unorm, .bgra8_unorm_srgb }) |format| {
        const srgb = format == .bgra8_unorm_srgb;
        var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{format} });
        defer pipeline.deinit();
        var src = try context.createTexture(a, .{ .size = .{ .width = 4, .height = 4 }, .format = format, .memory = .host_upload, .usage = .{ .texture_binding = true } });
        defer src.destroy();
        try src.writeRegion(0, 0, 0, 4, 4, &src_bytes, 16);
        var dst = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = format, .memory = .host_upload, .usage = .{ .texture_binding = true } });
        defer dst.destroy();
        try dst.writeRegion(0, 0, 0, 8, 4, &dst_bytes, 32);
        var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = format, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer target.destroy();
        var view = target.binding().createView();
        defer view.destroy();
        for (0..12) |mode| for ([_]f32{ 0, 0.35, 1 }) |opacity| for ([_][4]f32{ .{ 0, 0, 0, 0 }, .{ 1.5, 1.5, 1.5, 1.5 }, .{ 1.5, 0, 1.75, 0 } }) |radii| for ([_]f32{ 0, 0.6 }) |angle| for (0..5) |clip| {
            var encoder = try c.CommandEncoder.init(&queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
            pass.setPipeline(&pipeline);
            const params = [4]f32{ opacity, @floatFromInt(mode), 0, 0 };
            var uniforms = if (angle == 0) Uniforms{ .params = params } else rotatedUniforms(angle, params);
            uniforms.corner_radii = radii;
            // Composite-time clips in target pixels: a rect clip, or a rounded-rect / ellipse shape clip.
            if (clip == 1) uniforms.clip_rect = .{ 2, 0.5, 4.5, 2.5 };
            if (clip == 2) {
                uniforms.clip_shape = .{ 1, 0, 0, 0 };
                uniforms.clip_shape_rect = .{ 1.5, 0.25, 5, 3.5 };
                uniforms.clip_shape_radii = @splat(1.25);
            }
            if (clip == 4) {
                // Per-corner shape clip (attached group item: square inner corners).
                uniforms.clip_shape = .{ 1, 0, 0, 0 };
                uniforms.clip_shape_rect = .{ 1.5, 0.25, 5, 3.5 };
                uniforms.clip_shape_radii = .{ 1.5, 0, 1.25, 0 };
            }
            if (clip == 3) {
                uniforms.clip_shape = .{ 2, 0, 0, 0 };
                uniforms.clip_shape_rect = .{ 1, 0.5, 6, 3 };
            }
            try pass.setFragmentBytesChecked(0, std.mem.asBytes(&uniforms));
            pass.setFragmentTexture(0, &src);
            pass.setFragmentTexture(1, &dst);
            pass.setFragmentSampler(0, &sampler);
            try pass.drawChecked(3, 1, 0, 0);
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            try target.readBgra8(8, 4, &output, 32);
            try verify(&output, &src_bytes, &dst_bytes, uniforms, mode, srgb);
        };
    }
    for (0..32) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_COMPOSITE_RGBA8_HEX={s}\nPASS: production HLSL composite, 12 blend modes, 3 opacities, unrounded/uniform/per-corner rounded masks, axis-aligned/rotated 0.6 rad, unclipped/rect clip/uniform and per-corner rounded and ellipse shape clips, linear/sRGB, 2160 draws/69120 CPU-reference pixels (byte tolerance2), premultiplied partial/zero alpha, padded source UV and outside-rect passthrough\n", .{std.fmt.bytesToHex(output, .lower)});
}
