const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
const Vertex = extern struct { x: f32, y: f32, alpha_scale: f32 = 1, color: [4]f32 = .{ 0.25, 0.5, 0.75, 0.5 } };
const Uniforms = extern struct {
    viewport_size: [2]f32 = .{ 8, 8 },
    scale_factor: f32 = 1,
    draw_mode: u32 = 0,
    color: [4]f32 = .{ 0.25, 0.5, 0.75, 0.5 },
    rect: [4]f32 = .{ 0, 0, 8, 8 },
    fill_rule: u32 = 0,
    point_count: u32 = 8,
    contour_count: u32 = 2,
    pad0: u32 = 0,
    ends: [8]u32 = .{ 4, 8, 0, 0, 0, 0, 0, 0 },
    points: [32][2]f32 = @splat(.{ 0, 0 }),
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_shape_kind: u32 = 0,
    pad1: u32 = 0,
    pad2: u32 = 0,
    pad6: u32 = 0,
    grad_dir: u32 = 0,
    grad_stop_count: u32 = 0,
    grad_center: [2]f32 = .{ 0.5, 0.5 },
    grad_angle: f32 = 0,
    pad3: u32 = 0,
    pad4: u32 = 0,
    pad5: u32 = 0,
    grad_colors: [16][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    grad_positions: [16]f32 = @splat(0),
};
comptime {
    if (@sizeOf(Vertex) != 28 or @offsetOf(Vertex, "color") != 12 or @sizeOf(Uniforms) != 752 or @offsetOf(Uniforms, "points") != 96 or @offsetOf(Uniforms, "clip_rect") != 352 or @offsetOf(Uniforms, "clip_radii") != 368 or
        @offsetOf(Uniforms, "grad_dir") != 400 or @offsetOf(Uniforms, "grad_center") != 408 or @offsetOf(Uniforms, "grad_colors") != 432 or @offsetOf(Uniforms, "grad_positions") != 688) @compileError("Path renderer ABI mismatch");
}
/// CPU reference of draw_mode 2 (FillGradient.tAt / colorAt, straight alpha).
fn gradientColor(u: Uniforms, x: usize, y: usize) [4]f64 {
    const lx = (@as(f64, @floatFromInt(x)) + 0.5) / u.scale_factor - u.rect[0];
    const ly = (@as(f64, @floatFromInt(y)) + 0.5) / u.scale_factor - u.rect[1];
    const dx = lx / u.rect[2] - u.grad_center[0];
    const dy = ly / u.rect[3] - u.grad_center[1];
    const t = if (u.grad_dir == 4) std.math.clamp(@sqrt(dx * dx + dy * dy) * 2, 0, 1) else blk: {
        const tau = std.math.tau;
        const ang = std.math.atan2(dy, dx) - u.grad_angle;
        break :blk (ang - tau * @floor(ang / tau)) / tau;
    };
    const n = u.grad_stop_count;
    if (t <= u.grad_positions[0]) return .{ u.grad_colors[0][0], u.grad_colors[0][1], u.grad_colors[0][2], u.grad_colors[0][3] };
    for (1..n) |i| if (t <= u.grad_positions[i]) {
        const k = (t - u.grad_positions[i - 1]) / (u.grad_positions[i] - u.grad_positions[i - 1]);
        var out: [4]f64 = undefined;
        for (0..4) |ch| out[ch] = u.grad_colors[i - 1][ch] + (u.grad_colors[i][ch] - u.grad_colors[i - 1][ch]) * k;
        return out;
    };
    const last = u.grad_colors[n - 1];
    return .{ last[0], last[1], last[2], last[3] };
}
fn smooth(distance: f64, aa: f64) f64 {
    const t = std.math.clamp((aa - distance) / (2 * aa), 0, 1);
    return t * t * (3 - 2 * t);
}
fn clipDistance(x: f64, y: f64, u: Uniforms) f64 {
    const hx = u.clip_rect[2] * u.scale_factor * 0.5;
    const hy = u.clip_rect[3] * u.scale_factor * 0.5;
    const px = x - (u.clip_rect[0] + u.clip_rect[2] * 0.5) * u.scale_factor;
    const py = y - (u.clip_rect[1] + u.clip_rect[3] * 0.5) * u.scale_factor;
    if (u.clip_shape_kind == 2) return (@sqrt(px * px / (hx * hx) + py * py / (hy * hy)) - 1) * @min(hx, hy);
    // The quadrant picks the corner radius: TL, TR, BR, BL.
    const radius = u.scale_factor * (if (px < 0) (if (py < 0) u.clip_radii[0] else u.clip_radii[3]) else (if (py < 0) u.clip_radii[1] else u.clip_radii[2]));
    const qx = @abs(px) - hx + radius;
    const qy = @abs(py) - hy + radius;
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
}
fn coverage(x: usize, y: usize, u: Uniforms) f64 {
    const px = (@as(f64, @floatFromInt(x)) + 0.5) / u.scale_factor;
    const py = (@as(f64, @floatFromInt(y)) + 0.5) / u.scale_factor;
    var result: f64 = 1;
    if (u.draw_mode == 1) {
        if (u.point_count < 3 or u.contour_count == 0) return 0;
        var parity = false;
        var winding: i32 = 0;
        var distance = std.math.inf(f64);
        var start: usize = 0;
        for (u.ends[0..u.contour_count]) |end| {
            for (start..end) |i| {
                const next = if (i + 1 < end) i + 1 else start;
                const ax: f64 = u.points[i][0];
                const ay: f64 = u.points[i][1];
                const bx: f64 = u.points[next][0];
                const by: f64 = u.points[next][1];
                if ((ay > py) != (by > py)) {
                    const intersection = ax + (py - ay) * (bx - ax) / (by - ay);
                    if (px < intersection) parity = !parity;
                }
                const cross = (bx - ax) * (py - ay) - (px - ax) * (by - ay);
                if (ay <= py and by > py and cross > 0) winding += 1;
                if (ay > py and by <= py and cross < 0) winding -= 1;
                const dx = bx - ax;
                const dy = by - ay;
                const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / @max(dx * dx + dy * dy, 0.0001), 0, 1);
                distance = @min(distance, @sqrt(std.math.pow(f64, px - ax - t * dx, 2) + std.math.pow(f64, py - ay - t * dy, 2)));
            }
            start = end;
        }
        const inside = if (u.fill_rule == 0) parity else winding != 0;
        const aa = @max(@sqrt(@as(f64, 2)) * 0.5 / u.scale_factor, 0.75 / @max(u.scale_factor, 1));
        result = smooth(if (inside) -distance else distance, aa);
    } else result = (@as(f64, @floatFromInt(x)) + 0.5) / 8;
    if (u.clip_shape_kind != 0) {
        const sx = @as(f64, @floatFromInt(x)) + 0.5;
        const sy = @as(f64, @floatFromInt(y)) + 0.5;
        const qx = @as(f64, @floatFromInt(x & ~@as(usize, 1))) + 0.5;
        const qy = @as(f64, @floatFromInt(y & ~@as(usize, 1))) + 0.5;
        const derivative = @abs(clipDistance(qx + 1, sy, u) - clipDistance(qx, sy, u)) + @abs(clipDistance(sx, qy + 1, u) - clipDistance(sx, qy, u));
        result *= smooth(clipDistance(sx, sy, u), @max(derivative * 0.5, 0.5));
    }
    return result;
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("path context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.path);
    defer module.deinit();
    var vertex = try module.getFunction("path_vertex_main");
    defer vertex.deinit();
    var fragment = try module.getFunction("path_fragment_main");
    defer fragment.deinit();
    var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer pipeline.deinit();
    if (try pipeline.bufferStride(0, 0) != 28) return error.IncorrectPathVertexStride;
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var output: [256]u8 = undefined;
    var draws: usize = 0;
    for ([_]f32{ 1, 2 }) |scale| for (0..2) |mode| for (0..2) |rule| for (0..2) |reverse| for (0..3) |clip_kind| {
        var uniforms = Uniforms{ .viewport_size = .{ 8 / scale, 8 / scale }, .scale_factor = scale, .draw_mode = @intCast(mode), .fill_rule = @intCast(rule), .clip_shape_kind = @intCast(clip_kind), .clip_rect = .{ 1 / scale, 1 / scale, 6 / scale, 6 / scale }, .clip_radii = .{ 1.5 / scale, 0, 1 / scale, 0.5 / scale } };
        const corners = [_][2]f32{ .{ 0.75, 0.75 }, .{ 7.25, 0.75 }, .{ 7.25, 7.25 }, .{ 0.75, 7.25 }, .{ 2.75, 2.75 }, .{ 5.25, 2.75 }, .{ 5.25, 5.25 }, .{ 2.75, 5.25 } };
        for (0..8) |i| {
            const index = if (reverse == 1 and i >= 4) 11 - i else i;
            uniforms.points[i] = .{ corners[index][0] / scale, corners[index][1] / scale };
        }
        const sentinel = Vertex{ .x = -100, .y = -100, .color = .{ 1, 0, 0, 1 } };
        var values: [10]Vertex = @splat(sentinel);
        const positions = [_][2]f32{ .{ 0, 0 }, .{ 8, 0 }, .{ 0, 8 }, .{ 8, 0 }, .{ 8, 8 }, .{ 0, 8 } };
        for (positions, 0..) |pos, i| values[i + 4] = .{ .x = pos[0] / scale, .y = pos[1] / scale, .alpha_scale = if (mode == 0) pos[0] / 8 else 1 };
        var buffer = try context.createBuffer(a, .{ .size = @sizeOf(@TypeOf(values)), .usage = .{ .vertex = true, .map_write = true } });
        defer buffer.destroy();
        @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.sliceAsBytes(&values));
        var encoder = try c.CommandEncoder.init(&queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        pass.setPipeline(&pipeline);
        pass.setVertexBuffer(0, &buffer, 28);
        try pass.setVertexBytesChecked(1, std.mem.asBytes(&uniforms));
        try pass.setFragmentBytesChecked(1, std.mem.asBytes(&uniforms));
        try pass.drawChecked(6, 1, 3, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        try target.readBgra8(8, 8, &output, 32);
        for (0..8) |y| for (0..8) |x| {
            const alpha = coverage(x, y, uniforms) * 0.5;
            const expected = [_]f64{ alpha * 0.75, alpha * 0.5, alpha * 0.25, alpha };
            for (expected, 0..) |value, ch| {
                const byte: i32 = @intFromFloat(@round(value * 255));
                if (@abs(@as(i32, output[(y * 8 + x) * 4 + ch]) - byte) > 2) {
                    std.debug.print("path mismatch scale={d} mode={d} rule={d} reverse={d} clip={d} x={d} y={d} ch={d} actual={d} expected={d}\n", .{ scale, mode, rule, reverse, clip_kind, x, y, ch, output[(y * 8 + x) * 4 + ch], byte });
                    return error.IncorrectPathPixel;
                }
            }
        };
        draws += 1;
    };
    // draw_mode 2: radial / conic gradients evaluated per fragment over the
    // gradient bounds (rect); the vertex colour carries opacity only.
    var gradient_draws: usize = 0;
    for ([_]f32{ 1, 2 }) |scale| for ([_]u32{ 4, 5 }) |dir| {
        var uniforms = Uniforms{ .viewport_size = .{ 8 / scale, 8 / scale }, .scale_factor = scale, .draw_mode = 2, .rect = .{ 0.5 / scale, 0.25 / scale, 7 / scale, 7.5 / scale }, .grad_dir = dir, .grad_stop_count = 3, .grad_center = .{ 0.3, 0.6 }, .grad_angle = 0.7 };
        uniforms.grad_colors[0] = .{ 1, 0, 0, 1 };
        uniforms.grad_colors[1] = .{ 0, 1, 0, 0.5 };
        uniforms.grad_colors[2] = .{ 0, 0, 1, 1 };
        uniforms.grad_positions[0] = 0;
        uniforms.grad_positions[1] = 0.4;
        uniforms.grad_positions[2] = 1;
        var values: [6]Vertex = undefined;
        const positions = [_][2]f32{ .{ 0, 0 }, .{ 8, 0 }, .{ 0, 8 }, .{ 8, 0 }, .{ 8, 8 }, .{ 0, 8 } };
        for (positions, 0..) |pos, i| values[i] = .{ .x = pos[0] / scale, .y = pos[1] / scale, .color = .{ 1, 1, 1, 0.5 } };
        var buffer = try context.createBuffer(a, .{ .size = @sizeOf(@TypeOf(values)), .usage = .{ .vertex = true, .map_write = true } });
        defer buffer.destroy();
        @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.sliceAsBytes(&values));
        var encoder = try c.CommandEncoder.init(&queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        pass.setPipeline(&pipeline);
        pass.setVertexBuffer(0, &buffer, 0);
        try pass.setVertexBytesChecked(1, std.mem.asBytes(&uniforms));
        try pass.setFragmentBytesChecked(1, std.mem.asBytes(&uniforms));
        try pass.drawChecked(6, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        try target.readBgra8(8, 8, &output, 32);
        for (0..8) |y| for (0..8) |x| {
            const g = gradientColor(uniforms, x, y);
            const alpha = g[3] * 0.5;
            const expected = [_]f64{ g[2] * alpha, g[1] * alpha, g[0] * alpha, alpha };
            for (expected, 0..) |value, ch| {
                const byte: i32 = @intFromFloat(@round(value * 255));
                if (@abs(@as(i32, output[(y * 8 + x) * 4 + ch]) - byte) > 2) {
                    std.debug.print("path gradient mismatch scale={d} dir={d} x={d} y={d} ch={d} actual={d} expected={d}\n", .{ scale, dir, x, y, ch, output[(y * 8 + x) * 4 + ch], byte });
                    return error.IncorrectPathGradientPixel;
                }
            }
        };
        gradient_draws += 1;
    };
    for (0..64) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_PATH_RGBA8_HEX={s}\nPASS: production HLSL path, {d} draws/{d} CPU-reference pixels (byte tolerance2), vertex stride28/uniform752 packed ABI, nonzero buffer/vertex offsets, fringe alpha, evenodd/nonzero rings, opposite winding, scale1/2 and per-corner rounded/ellipse clips; {d} per-fragment radial/conic gradient draws (3 stops, offset centre, start angle, opacity)\n", .{ std.fmt.bytesToHex(output, .lower), draws, draws * 64, gradient_draws });
}
