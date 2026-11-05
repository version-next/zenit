const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
const Uniforms = extern struct {
    texel: [2]f32 = .{ 0.125, 0.125 },
    radius: f32 = 1.3,
    intensity: f32 = 0,
    rect_size: [2]f32 = .{ 8, 8 },
    scale: f32 = 1,
    padding: f32 = 0,
    tint: [4]f32 = .{ 0, 0, 0, 0 },
    specular: [4]f32 = .{ 0.35, 6, 1, 1 },
    optics: [4]f32 = .{ 1, 4, 1.8, 0 },
    top: [4]f32 = .{ 2, 0.18, -1.04719755, 0 },
    // zw = backdrop saturation / brightness; {1, 1} = unadjusted (production default).
    bottom: [4]f32 = .{ 0, 0.12, 1, 1 },
    lens: [4]f32 = .{ 0.58, 2.2, 1, 1 },
    content_uv: [4]f32 = .{ 0, 0, 1, 1 },
    edge: [4]f32 = .{ 0, 0, 0, 2 },
    edge_positions: [4]f32 = .{ 0, 1, 1, 1 },
    edge_strength: [4]f32 = .{ 0, 1, 1, 1 },
    valid_uv: [4]f32 = .{ 0.5 / 8.0, 0.5 / 8.0, 5.5 / 8.0, 4.5 / 8.0 },
};
const GlassUniforms = @import("render").GlassUniforms;
const tab_lens_field = @import("render").tab_lens_field;
comptime {
    // The legacy-surface parameters below are the leading fields of the
    // production uniform block; everything after them keeps its default.
    if (@offsetOf(GlassUniforms, "glass_tint") != 32 or @offsetOf(GlassUniforms, "valid_uv") != 192 or
        @offsetOf(GlassUniforms, "native_params") != 208) @compileError("Glass uniform ABI mismatch");
}
fn toGlass(u: Uniforms) GlassUniforms {
    return .{
        .texel_size = u.texel,
        .corner_radius = u.radius,
        .glass_intensity = u.intensity,
        .rect_size = u.rect_size,
        .scale_factor = u.scale,
        .tint_mode = u.padding,
        .glass_tint = u.tint,
        .specular_params = u.specular,
        .optic_params = u.optics,
        .surface_params = u.top,
        .bottom_surface_params = u.bottom,
        .lens_params = u.lens,
        .content_uv = u.content_uv,
        .edge_params = u.edge,
        .edge_stop_pos = u.edge_positions,
        .edge_stop_str = u.edge_strength,
        .valid_uv = u.valid_uv,
    };
}
fn texture(context: *r.Context, color: [4]u8, padded: bool) !r.Texture {
    var result = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    errdefer result.destroy();
    var bytes: [256]u8 = @splat(0);
    for (0..8) |y| for (0..8) |x| if (!padded or (x < 6 and y < 5)) @memcpy(bytes[(y * 8 + x) * 4 ..][0..4], &color);
    try result.writeRegion(0, 0, 0, 8, 8, &bytes, 32);
    return result;
}
fn render(context: *r.Context, pipeline: *const d12.RenderPipeline, target: *const r.Texture, blur: *const r.Texture, sharp: *const r.Texture, sampler: *const d12.Sampler, field: *const d12.Buffer, uniform: Uniforms, output: *[256]u8) !void {
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var encoder = try c.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var view = target.binding().createView();
    defer view.destroy();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
    pass.setPipeline(pipeline);
    const glass = toGlass(uniform);
    try pass.setFragmentBytesChecked(0, std.mem.asBytes(&glass));
    pass.setFragmentTexture(0, blur);
    pass.setFragmentTexture(1, sharp);
    // Native-model inputs (soft/coarse/alternate banks) are unused by the
    // legacy surface path but every reflected texture must be bound.
    pass.setFragmentTexture(2, sharp);
    pass.setFragmentTexture(3, blur);
    pass.setFragmentTexture(4, blur);
    pass.setFragmentSampler(0, sampler);
    // The tab lens's field table (fragment buffer 1), as backdrop_blur binds it.
    pass.setFragmentBuffer(tab_lens_field.slot, field, 0);
    try pass.drawChecked(3, 1, 0, 0);
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    try command.waitChecked(5000);
    try target.readBgra8(8, 8, output, 32);
}
fn srgbToLinear(v: f64) f64 {
    return if (v > 0.04045) std.math.pow(f64, (v + 0.055) / 1.055, 2.4) else v / 12.92;
}
fn linearToSrgb(v: f64) f64 {
    return if (v > 0.0031308) 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055 else v * 12.92;
}
fn checkMask(bytes: []const u8) !void {
    for (0..8) |y| for (0..8) |x| {
        const alpha = maskCoverage(x, y);
        const expected: i32 = if (alpha < 0.001) 0 else @intFromFloat(@round(alpha * 255));
        if (@abs(@as(i32, bytes[(y * 8 + x) * 4 + 3]) - expected) > 2) return error.IncorrectGlassMask;
    };
}
fn sdf(x: f64, y: f64) f64 {
    const qx = @abs(x - 4) - 4 + 1.3;
    const qy = @abs(y - 4) - 4 + 1.3;
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - 1.3;
}
fn maskCoverage(x: usize, y: usize) f64 {
    const px = @as(f64, @floatFromInt(x)) + 0.5;
    const py = @as(f64, @floatFromInt(y)) + 0.5;
    const qx = @as(f64, @floatFromInt(x & ~@as(usize, 1))) + 0.5;
    const qy = @as(f64, @floatFromInt(y & ~@as(usize, 1))) + 0.5;
    const derivative = @abs(sdf(qx + 1, py) - sdf(qx, py)) + @abs(sdf(px, qy + 1) - sdf(px, qy));
    const aa = @max(derivative * 0.5, 0.5);
    const t = std.math.clamp((aa - sdf(px, py)) / (2 * aa), 0, 1);
    return t * t * (3 - 2 * t);
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("glass context cleanup");
    var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.glass);
    defer module.deinit();
    var vs = try module.getFunction("glass_vertex_main");
    defer vs.deinit();
    var ps = try module.getFunction("glass_fragment_main");
    defer ps.deinit();
    var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vs, .fragment_function = &ps, .color_attachment_formats = &.{.bgra8_unorm} });
    defer pipeline.deinit();
    var sampler = try device.createSampler(a, .{});
    defer sampler.destroy();
    var field = try context.createBuffer(a, .{ .size = tab_lens_field.bytes.len, .usage = .{ .vertex = true, .map_write = true } });
    defer field.destroy();
    @memcpy(try field.getMappedRange(0, tab_lens_field.bytes.len), tab_lens_field.bytes);
    var blur_padded = try texture(context, .{ 32, 64, 96, 128 }, true);
    defer blur_padded.destroy();
    var blur_full = try texture(context, .{ 32, 64, 96, 128 }, false);
    defer blur_full.destroy();
    var sharp = try texture(context, .{ 96, 32, 16, 128 }, true);
    defer sharp.destroy();
    var sharp_full = try texture(context, .{ 96, 32, 16, 128 }, false);
    defer sharp_full.destroy();
    var transparent = try texture(context, .{ 0, 0, 0, 0 }, false);
    defer transparent.destroy();
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var output: [256]u8 = undefined;
    var cpu_draws: usize = 0;
    for ([_]f32{ 1, 2 }) |scale| for ([_]f32{ 0, 0.5, 1 }) |blur_level| for (0..5) |direction| for ([_]f32{ 0, 0.4, 1 }) |strength| for (0..2) |sharp_present| {
        var uniform = Uniforms{ .rect_size = .{ 8 / scale, 8 / scale }, .scale = scale, .radius = 1.3 / scale, .edge = .{ @floatFromInt(direction), 0, strength, 2 } };
        uniform.specular[3] = blur_level;
        try render(context, &pipeline, &target, &blur_padded, if (sharp_present == 0) &transparent else &sharp, &sampler, &field, uniform, &output);
        for (0..8) |y| for (0..8) |x| {
            const u = (@as(f64, @floatFromInt(x)) + 0.5) / 8;
            const v = (@as(f64, @floatFromInt(y)) + 0.5) / 8;
            const t = switch (direction) {
                1 => v,
                2 => 1 - v,
                3 => u,
                else => 1 - u,
            };
            const profile = t * t * (3 - 2 * t);
            const active = direction > 0 and strength > 0.001;
            const local = if (active) blur_level * (1 - strength) + profile * strength else blur_level;
            const gap_scale = if (active) 1 - strength + profile * strength else 1;
            const effective = std.math.clamp(local + @as(f64, uniform.optics[2]) * 0.045 * gap_scale, 0, 1);
            const mask = maskCoverage(x, y);
            const blur_color = [_]f64{ 0.25, 0.5, 0.75 };
            const sharp_color = [_]f64{ 0.75, 0.25, 0.125 };
            for (0..4) |ch| {
                const sharp_mix = if (sharp_present == 0) @as(f64, 0) else 128.0 / 255.0;
                // glass.metal's legacy surface path mixes blur and sharp in
                // linear light, then re-encodes (targets hold sRGB values).
                const weight = sharp_mix * (1 - effective);
                const base = if (ch == 3) @as(f64, 1) else linearToSrgb(srgbToLinear(blur_color[ch]) * (1 - weight) + srgbToLinear(sharp_color[ch]) * weight);
                const expected: i32 = if (mask < 0.001) 0 else @intFromFloat(@round(base * mask * 255));
                if (@abs(@as(i32, output[(y * 8 + x) * 4 + ch]) - expected) > 2) {
                    std.debug.print("glass mismatch scale={d} blur={d} dir={d} strength={d} sharp={d} x={d} y={d} ch={d} actual={d} expected={d}\n", .{ scale, blur_level, direction, strength, sharp_present, x, y, ch, output[(y * 8 + x) * 4 + ch], expected });
                    return error.IncorrectGlassPixel;
                }
            }
        };
        cpu_draws += 1;
    };
    var padded: [256]u8 = undefined;
    var optical_pairs: usize = 0;
    var changed = false;
    for ([_]f32{ 1, 2 }) |scale| for (0..5) |top| for (0..5) |bottom| {
        var uniform = Uniforms{ .rect_size = .{ 8 / scale, 8 / scale }, .scale = scale, .radius = 1.3 / scale, .intensity = 1.4 };
        uniform.top[0] = @floatFromInt(top);
        uniform.bottom[0] = @floatFromInt(bottom);
        try render(context, &pipeline, &target, &blur_padded, &sharp, &sampler, &field, uniform, &padded);
        try render(context, &pipeline, &target, &blur_full, &sharp_full, &sampler, &field, uniform, &output);
        try checkMask(&output);
        for (0..64) |i| {
            const pixel = output[i * 4 ..][0..4];
            const sum = @as(u32, pixel[0]) + pixel[1] + pixel[2];
            if (pixel[3] > 32 and sum * 5 < pixel[3]) return error.GlassOpticsProducedBlack;
            for (pixel[0..3]) |channel| if (@as(u32, channel) > @as(u32, pixel[3]) + 2) return error.GlassPremultipliedInvariant;
        }
        for (output, padded) |left, right| if (@abs(@as(i32, left) - @as(i32, right)) > 1) return error.GlassPaddingContamination;
        if (top == 2 and bottom == 0 and scale == 1) {
            var neutral = uniform;
            neutral.intensity = 0;
            var baseline: [256]u8 = undefined;
            try render(context, &pipeline, &target, &blur_full, &sharp_full, &sampler, &field, neutral, &baseline);
            changed = !std.mem.eql(u8, &baseline, &output);
        }
        optical_pairs += 1;
    };
    if (!changed) return error.GlassOpticsHadNoEffect;
    for (0..64) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_GLASS_RGBA8_HEX={s}\nPASS: production HLSL Glass, {d} neutral draws/{d} CPU-reference pixels (byte tolerance2), intensity-zero gate, sharp fallback/coverage normalization, 4 gradient axes/strength/blur mix, scale1/2; {d} optical padded/full pairs (byte tolerance1), all 25 top/bottom surface combinations, exact mask reference and optical-effect guard\n", .{ std.fmt.bytesToHex(output, .lower), cpu_draws, cpu_draws * 64, optical_pairs });
}
