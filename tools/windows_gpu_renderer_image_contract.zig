const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
pub const Uniforms = extern struct {
    viewport: [2]f32 = .{ 8, 8 },
    scale: f32 = 1,
    clip_kind: u32 = 0,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    fill_rule: u32 = 0,
    point_count: u32 = 8,
    contour_count: u32 = 2,
    clip_pad: u32 = 0,
    ends: [8]u32 = .{ 4, 8, 0, 0, 0, 0, 0, 0 },
    points: [32][2]f32 = @splat(.{ 0, 0 }),
};
const Instance = extern struct {
    rect: [4]f32,
    uv: [4]f32 = .{ 0.25, 0.25, 0.75, 0.75 },
    tint: [4]f32 = .{ 0.8, 0.5, 0.25, 0.7 },
    linear: [4]f32 = .{ 1, 0, 0, 1 },
    radii: [4]f32 = @splat(1.3),
    translation: [2]f32 = .{ 0, 0 },
    opacity: f32,
    premultiplied: f32,
    sampling: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32 = .{ 0, 0, -1, -1 },
};
comptime {
    if (@sizeOf(Uniforms) != 352 or @offsetOf(Uniforms, "clip_radii") != 32 or @offsetOf(Uniforms, "ends") != 64 or @offsetOf(Uniforms, "points") != 96 or @sizeOf(Instance) != 128 or @offsetOf(Instance, "radii") != 64 or @offsetOf(Instance, "clip") != 112) @compileError("Image renderer ABI mismatch");
}
fn smooth(signed_distance: f64, aa: f64) f64 {
    const t = std.math.clamp((aa - signed_distance) / (2 * aa), 0, 1);
    return t * t * (3 - 2 * t);
}
fn rectDistance(x: f64, y: f64, origin: f64, size: f64, radius: f64) f64 {
    const qx = @abs(x - origin - size * 0.5) - size * 0.5 + radius;
    const qy = @abs(y - origin - size * 0.5) - size * 0.5 + radius;
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
}
/// Per-corner rounded clip radii TL, TR, BR, BL (device px) of the shape-clip case.
pub const clip_radii_px = [4]f64{ 1.7, 0, 1.2, 0.6 };
/// Square {origin, size}: the quadrant (relative to the centre) picks the corner radius.
fn cornersDistance(x: f64, y: f64, origin: f64, size: f64, radii: [4]f64) f64 {
    const left = x < origin + size * 0.5;
    const top = y < origin + size * 0.5;
    return rectDistance(x, y, origin, size, if (left) (if (top) radii[0] else radii[3]) else (if (top) radii[1] else radii[2]));
}
fn distance(x: f64, y: f64, kind: usize) f64 {
    return switch (kind) {
        0 => rectDistance(x, y, 0, 8, 1.3),
        1 => rectDistance(x, y, 0.5, 7, 0),
        2 => cornersDistance(x, y, 1, 6, clip_radii_px),
        else => @sqrt((x - 4) * (x - 4) / 9 + (y - 4) * (y - 4) / 9) - 1,
    };
}
pub fn aaCoverage(x: usize, y: usize, kind: usize) f64 {
    const px = @as(f64, @floatFromInt(x)) + 0.5;
    const py = @as(f64, @floatFromInt(y)) + 0.5;
    const qx = @as(f64, @floatFromInt(x & ~@as(usize, 1))) + 0.5;
    const qy = @as(f64, @floatFromInt(y & ~@as(usize, 1))) + 0.5;
    const derivative = @abs(distance(qx + 1, py, kind) - distance(qx, py, kind)) + @abs(distance(px, qy + 1, kind) - distance(px, qy, kind));
    return smooth(distance(px, py, kind), if (kind == 0) derivative * 0.5 else @max(derivative * 0.5, 0.5));
}
pub fn polygonCoverage(x: usize, y: usize, nonzero: bool) f64 {
    const px = @as(f64, @floatFromInt(x)) + 0.5;
    const py = @as(f64, @floatFromInt(y)) + 0.5;
    const outer = px >= 1 and px < 7 and py >= 1 and py < 7;
    const inner = px >= 3 and px < 5 and py >= 3 and py < 5;
    const inside = outer and (nonzero or !inner);
    // Both contours are squares, so the signed box distance gives distance
    // to the nearest segment (including corner endpoints).
    const nearest = @min(@abs(rectDistance(px, py, 1, 6, 0)), @abs(rectDistance(px, py, 3, 2, 0)));
    return smooth(if (inside) -nearest else nearest, 0.75);
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("image context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.image);
    defer module.deinit();
    var vertex = try module.getFunction("image_vertex_main");
    defer vertex.deinit();
    var fragment = try module.getFunction("image_fragment_main");
    defer fragment.deinit();
    var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer pipeline.deinit();
    if (try pipeline.bufferStride(0, 1) != 128) return error.IncorrectImageStride;
    var sampler = try device.createSampler(a, .{});
    defer sampler.destroy();
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var output: [256]u8 = undefined;
    var draws: usize = 0;
    for (0..2) |premultiplied| {
        var input: [64]u8 = undefined;
        for (0..4) |y| for (0..4) |x| {
            const alpha: u8 = switch ((y % 2) * 2 + x % 2) {
                0 => 0,
                1 => 128,
                2 => 255,
                else => 64,
            };
            const rgb = [_]u8{ 100, @intCast(y * 60), @intCast(x * 60) };
            for (rgb, 0..) |byte, ch| input[(y * 4 + x) * 4 + ch] = if (premultiplied == 1) @intCast(@as(u32, byte) * alpha / 255) else byte;
            input[(y * 4 + x) * 4 + 3] = alpha;
        };
        var texture = try context.createTexture(a, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
        defer texture.destroy();
        try texture.writeRegion(0, 0, 0, 4, 4, &input, 16);
        for ([_]f32{ 1, 2 }) |scale| for ([_]f32{ 0, 0.35, 1 }) |opacity| for (0..5) |clip_case| {
            var uniforms = Uniforms{ .scale = scale, .clip_kind = @intCast(@min(clip_case, 3)), .clip_rect = .{ 1 / scale, 1 / scale, 6 / scale, 6 / scale }, .clip_radii = .{ @floatCast(clip_radii_px[0] / scale), @floatCast(clip_radii_px[1] / scale), @floatCast(clip_radii_px[2] / scale), @floatCast(clip_radii_px[3] / scale) }, .fill_rule = @intFromBool(clip_case == 4) };
            const points = [_][2]f32{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 6 }, .{ 0, 6 }, .{ 2, 2 }, .{ 4, 2 }, .{ 4, 4 }, .{ 2, 4 } };
            for (points, 0..) |point, i| uniforms.points[i] = .{ point[0] / scale, point[1] / scale };
            const transform = clip_case % 3;
            var instance = Instance{ .rect = .{ 0, 0, 8 / scale, 8 / scale }, .opacity = opacity, .premultiplied = @floatFromInt(premultiplied), .radii = @splat(1.3 / scale) };
            if (clip_case > 0) instance.clip = .{ 0.5 / scale, 0.5 / scale, 7 / scale, 7 / scale };
            if (transform == 1) {
                instance.linear = .{ 0, 1, -1, 0 };
                instance.translation = .{ 8 / scale, 0 };
            }
            if (transform == 2) {
                instance.linear = .{ -1, 0, 0, 1 };
                instance.translation = .{ 8 / scale, 0 };
            }
            var sentinel = instance;
            sentinel.rect = .{ -100, -100, 1, 1 };
            const values = [_]Instance{ sentinel, sentinel, instance };
            var buffer = try context.createBuffer(a, .{ .size = @sizeOf(@TypeOf(values)), .usage = .{ .vertex = true, .map_write = true } });
            defer buffer.destroy();
            @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.sliceAsBytes(&values));
            var encoder = try c.CommandEncoder.init(&queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            pass.setPipeline(&pipeline);
            pass.setVertexBuffer(1, &buffer, 128);
            pass.setFragmentBuffer(1, &buffer, 128);
            try pass.setVertexBytesChecked(0, std.mem.asBytes(&uniforms));
            try pass.setFragmentBytesChecked(0, std.mem.asBytes(&uniforms));
            pass.setFragmentTexture(0, &texture);
            pass.setFragmentSampler(0, &sampler);
            try pass.drawChecked(6, 1, 0, 1);
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            try command.submitChecked();
            try command.waitChecked(5000);
            try target.readBgra8(8, 8, &output, 32);
            for (0..8) |y| for (0..8) |x| {
                const sx = @as(f64, @floatFromInt(x)) + 0.5;
                const sy = @as(f64, @floatFromInt(y)) + 0.5;
                const local: [2]f64 = switch (transform) {
                    1 => .{ sy, 8 - sx },
                    2 => .{ 8 - sx, sy },
                    else => .{ sx, sy },
                };
                const tx: usize = @intFromFloat(@floor((0.25 + local[0] / 8 * 0.5) * 4));
                const ty: usize = @intFromFloat(@floor((0.25 + local[1] / 8 * 0.5) * 4));
                const texel = input[(ty * 4 + tx) * 4 ..][0..4];
                var cover = aaCoverage(x, y, 0) * opacity;
                if (clip_case > 0) cover *= aaCoverage(x, y, 1);
                if (clip_case == 1 or clip_case == 2) cover *= aaCoverage(x, y, clip_case + 1);
                if (clip_case >= 3) cover *= polygonCoverage(x, y, clip_case == 4);
                const alpha = @as(f64, @floatFromInt(texel[3])) / 255 * instance.tint[3] * cover;
                const tint_bgra = [_]f32{ instance.tint[2], instance.tint[1], instance.tint[0], instance.tint[3] };
                for (0..4) |ch| {
                    const value = if (alpha < 0.001) @as(f64, 0) else if (ch == 3) alpha else @as(f64, @floatFromInt(texel[ch])) / 255 * tint_bgra[ch] * (if (premultiplied == 1) cover else alpha);
                    const expected: i32 = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
                    if (@abs(@as(i32, output[(y * 8 + x) * 4 + ch]) - expected) > 2) {
                        std.debug.print("image mismatch premul={d} scale={d} opacity={d} clip={d} x={d} y={d} ch={d} actual={d} expected={d}\n", .{ premultiplied, scale, opacity, clip_case, x, y, ch, output[(y * 8 + x) * 4 + ch], expected });
                        return error.IncorrectImagePixel;
                    }
                }
            };
            draws += 1;
        };
    }
    const baseline = output;
    for (0..64) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_IMAGE_RGBA8_HEX={s}\nPASS: production HLSL image, {d} draws/{d} CPU-reference pixels (byte tolerance2), stride128/uniform352, vertex instance properties, nonzero instance/buffer offsets, premultiplied/straight alpha, opacity/tint, UV subrect, rotation/mirror, scale1/2, per-corner rounded/rect/ellipse/polygon clips\n", .{ std.fmt.bytesToHex(output, .lower), draws, draws * 64 });
    // Damage clear is replace, with load preserving pixels outside the scissor.
    var clear_module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.damage_clear);
    defer clear_module.deinit();
    var clear_vertex = try clear_module.getFunction("damage_clear_vertex_main");
    defer clear_vertex.deinit();
    var clear_fragment = try clear_module.getFunction("damage_clear_fragment_main");
    defer clear_fragment.deinit();
    var clear_pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &clear_vertex, .fragment_function = &clear_fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer clear_pipeline.deinit();
    var clear_encoder = try c.CommandEncoder.init(&queue);
    defer clear_encoder.deinit();
    var clear_pass = try clear_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .load, .store_op = .store }} });
    clear_pass.setPipeline(&clear_pipeline);
    clear_pass.setScissorRect(2, 1, 3, 2);
    try clear_pass.drawChecked(3, 1, 0, 0);
    clear_pass.end();
    var clear_command = try clear_encoder.finish();
    defer clear_command.deinit();
    try clear_command.submitChecked();
    try clear_command.waitChecked(5000);
    try target.readBgra8(8, 8, &output, 32);
    for (0..8) |y| for (0..8) |x| {
        const offset = (y * 8 + x) * 4;
        const expected = if (x >= 2 and x < 5 and y >= 1 and y < 3) &[_]u8{ 0, 0, 0, 0 } else baseline[offset..][0..4];
        if (!std.mem.eql(u8, output[offset..][0..4], expected)) return error.IncorrectDamageClearPixel;
    };
    for (0..64) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_DAMAGE_CLEAR_RGBA8_HEX={s}\nPASS: production HLSL damage clear, 64 exact pixels, scissored transparent replacement and outside-region load preservation\n", .{std.fmt.bytesToHex(output, .lower)});
}
