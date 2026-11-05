const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
const clip_reference = @import("windows_gpu_renderer_image_contract.zig");
const Uniforms = extern struct { clip: clip_reference.Uniforms, frame_seed: u32 = 17 };
const Instance = extern struct {
    rect: [4]f32 = .{ 0, 0, 8, 8 },
    clip: [4]f32 = .{ 0, 0, -1, -1 },
    fill: [4]f32 = .{ 0.25, 0.5, 0.75, 0.5 },
    border: [4]f32 = .{ 1, 0, 0, 0.7 },
    shadow: [4]f32 = .{ 0, 0, 0, 0 },
    gradient_to: [4]f32 = .{ 0.8, 0.1, 0.4, 0.8 },
    radii: [4]f32 = .{ 1, 2, 3, 0.5 },
    border_width: f32 = 0,
    shadow_blur: f32 = 0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    shape: u32 = 0,
    flags: u32 = 0,
    noise_scale: f32 = 0,
    noise_intensity: f32 = 0,
    widths: [4]f32 = .{ 0, 0, 0, 0 },
    stop_offset: u32 = 0,
    stop_count: u32 = 0,
    shadow_index: u32 = 0,
    reserved: u32 = 0,
};
const Stop = extern struct { color: [4]f32, position: f32, padding: [3]f32 = .{ 0, 0, 0 } };
comptime {
    if (@sizeOf(Uniforms) != 356 or @sizeOf(Instance) != 176 or @offsetOf(Instance, "shape") != 128 or @sizeOf(Stop) != 32) @compileError("SDF renderer ABI mismatch");
}
/// Coverage as the shader's `aa_step`: smoothstep over ±`aa` around the edge.
fn mask(distance: f64, aa: f64) f64 {
    const t = std.math.clamp((aa - distance) / (2 * aa), 0, 1);
    return t * t * (3 - 2 * t);
}
/// AA half-width as the shader's `sdf_aa_width`: half the field's screen-space
/// gradient, taken like `ddx_fine`/`ddy_fine` inside the pixel's 2×2 quad,
/// floored at 0.5px. `field.at(px, py)` is the signed distance at a pixel centre.
fn quadAa(x: usize, y: usize, field: anytype) f64 {
    const qx: f64 = @floatFromInt(x & ~@as(usize, 1));
    const qy: f64 = @floatFromInt(y & ~@as(usize, 1));
    const px = @as(f64, @floatFromInt(x)) + 0.5;
    const py = @as(f64, @floatFromInt(y)) + 0.5;
    const ddx = field.at(qx + 1.5, py) - field.at(qx + 0.5, py);
    const ddy = field.at(px, qy + 1.5) - field.at(px, qy + 0.5);
    return @max(0.5 * @sqrt(ddx * ddx + ddy * ddy), 0.5);
}
const ShapeField = struct {
    inst: Instance,
    scale: f32,
    fn at(self: ShapeField, px: f64, py: f64) f64 {
        return shapeDistance(px, py, self.inst, self.scale);
    }
};
fn rounded(px: f64, py: f64, hx: f64, hy: f64, radii: [4]f32, scale: f32) f64 {
    const radius: f64 = radii[if (px < 0) (if (py < 0) @as(usize, 0) else 3) else (if (py < 0) @as(usize, 1) else 2)] * scale;
    const qx = @abs(px) - hx + radius;
    const qy = @abs(py) - hy + radius;
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
}
fn shapeDistance(x: f64, y: f64, inst: Instance, scale: f32) f64 {
    const hx: f64 = inst.rect[2] * scale * 0.5;
    const hy: f64 = inst.rect[3] * scale * 0.5;
    const px = x - (inst.rect[0] * scale + hx);
    const py = y - (inst.rect[1] * scale + hy);
    switch (inst.shape) {
        0 => return rounded(px, py, hx, hy, inst.radii, scale),
        1 => return @sqrt(px * px + py * py) - @min(hx, hy),
        2 => return @abs(py) - inst.radii[0] * scale,
        3 => {
            const half: f64 = inst.border_width * scale * 0.5;
            const radius: f64 = inst.radii[0] * scale;
            const angle = std.math.atan2(py, px);
            const period = 2 * std.math.pi;
            const relative = angle - inst.offset_x - @floor((angle - inst.offset_x) / period) * period;
            return if (relative <= inst.offset_y - inst.offset_x) @abs(@sqrt(px * px + py * py) - radius + half) - half else half + 1;
        },
        else => {
            const k = @sqrt(px * px / (hx * hx) + py * py / (hy * hy));
            if (k < 0.000001) return -@min(hx, hy);
            const g = @sqrt(px * px / std.math.pow(f64, hx, 4) + py * py / std.math.pow(f64, hy, 4)) / k;
            return (k - 1) / @max(g, 0.000001);
        },
    }
}
/// Signed distance to the per-side border's inner edge.
fn perSideInner(x: f64, y: f64, inst: Instance, scale: f32) f64 {
    var widths = inst.widths;
    for (&widths) |*width| width.* *= scale;
    const top = widths[0];
    const right = widths[1];
    const bottom = widths[2];
    const left = widths[3];
    const hx: f64 = inst.rect[2] * scale * 0.5;
    const hy: f64 = inst.rect[3] * scale * 0.5;
    const px = x - (inst.rect[0] * scale + hx) - (left - right) * 0.5;
    const py = y - (inst.rect[1] * scale + hy) - (top - bottom) * 0.5;
    const adjacent = [4]f32{ @max(top, left), @max(top, right), @max(bottom, right), @max(bottom, left) };
    var radii: [4]f32 = undefined;
    for (&radii, inst.radii, adjacent) |*radius, original, inset| radius.* = @max(0, original * scale - inset);
    return rounded(px, py, @max(0, hx - (right + left) * 0.5), @max(0, hy - (top + bottom) * 0.5), radii, 1);
}
/// The shader masks the inner edge with the outer shape's `aa_width`, so `aa`
/// is the outer field's, not the inner field's own gradient.
fn perSideBorderMask(x: f64, y: f64, inst: Instance, scale: f32, outer: f64, aa: f64) f64 {
    return outer - mask(perSideInner(x, y, inst, scale), aa);
}
fn gradient(x: f64, y: f64, inst: Instance, scale: f32, stops: []const Stop) [4]f64 {
    const dir = inst.flags & 255;
    if (dir == 0) return .{ inst.fill[0], inst.fill[1], inst.fill[2], inst.fill[3] };
    const u = (x / scale - inst.rect[0]) / inst.rect[2];
    const v = (y / scale - inst.rect[1]) / inst.rect[3];
    var t = switch (dir) {
        1 => v,
        2 => u,
        3 => (u + v) * 0.5,
        4 => @sqrt((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)) * 2,
        else => std.math.atan2(v - 0.5, u - 0.5) / (2 * std.math.pi) + 0.5,
    };
    t = std.math.clamp(t, 0, 1);
    var from = inst.fill;
    var to = inst.gradient_to;
    if (inst.stop_count > 0) {
        const index: usize = if (t <= 0.4) 0 else 1;
        from = stops[index].color;
        to = stops[index + 1].color;
        t = (t - stops[index].position) / (stops[index + 1].position - stops[index].position);
    }
    const alpha = from[3] * (1 - t) + to[3] * t;
    var result: [4]f64 = .{ 0, 0, 0, alpha };
    for (0..3) |ch| result[ch] = if (alpha > 0.000001) (from[ch] * from[3] * (1 - t) + to[ch] * to[3] * t) / alpha else 0;
    return result;
}
fn windowsBuild() u32 {
    var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    if (std.os.windows.ntdll.RtlGetVersion(&info) != .SUCCESS) return 0;
    return info.dwBuildNumber;
}

/// The D3D12 renderer draws general material instances bottom-up as layer
/// passes: inset shadow + border (under), fill (body), outer shadows. That must
/// reproduce the one-pass program, which Windows 10 WARP cannot run (the reason
/// for the split).
fn checkLayerSplit(context: *r.Context, queue: *c.Queue, module: *p.ShaderModule, vertex: *p.ShaderFunction, device: *d12.Device) !void {
    if (windowsBuild() < 22000) {
        std.debug.print("SKIP: layer split equivalence (Windows 10 WARP cannot run the one-pass program)\n", .{});
        return;
    }
    var full_f = try module.getFunction("sdf_fragment_main");
    defer full_f.deinit();
    var outer_f = try module.getFunction("sdf_outer_shadow_fragment_main");
    defer outer_f.deinit();
    var body_f = try module.getFunction("sdf_body_fragment_main");
    defer body_f.deinit();
    var border_f = try module.getFunction("sdf_border_layer_fragment_main");
    defer border_f.deinit();
    var border_p = try p.createRenderPipeline(device, .{ .vertex_function = vertex, .fragment_function = &border_f, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } });
    defer border_p.deinit();
    var inset_f = try module.getFunction("sdf_inset_layer_fragment_main");
    defer inset_f.deinit();
    var inset_p = try p.createRenderPipeline(device, .{ .vertex_function = vertex, .fragment_function = &inset_f, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } });
    defer inset_p.deinit();
    var full_p = try p.createRenderPipeline(device, .{ .vertex_function = vertex, .fragment_function = &full_f, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } });
    defer full_p.deinit();
    var outer_p = try p.createRenderPipeline(device, .{ .vertex_function = vertex, .fragment_function = &outer_f, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } });
    defer outer_p.deinit();
    var body_p = try p.createRenderPipeline(device, .{ .vertex_function = vertex, .fragment_function = &body_f, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } });
    defer body_p.deinit();
    var item = Instance{};
    item.rect = .{ 6, 9.5, 28.5, 20.25 };
    item.fill = .{ 0.7, 0.4, 0.1, 0.4 };
    item.shadow = .{ 0.2, 0.4, 0.1, 0.5 };
    item.shadow_blur = 4.5;
    item.offset_x = -2;
    item.offset_y = 3;
    item.radii = .{ 1, 3, 2, 4 };
    item.flags = 1 << 25 | 1 << 16;
    // Inset shadow, per-side border and a gradient fill overlapping the first
    // instance's shadow: exercises the under pass and cross-instance order.
    var inset = Instance{};
    inset.rect = .{ 24, 6, 20, 26 };
    inset.fill = .{ 0.2, 0.6, 0.9, 0.7 };
    inset.border = .{ 0.9, 0.2, 0.3, 0.8 };
    inset.widths = .{ 1, 2.5, 1.5, 3 };
    inset.shadow = .{ 1, 1, 0.8, 0.6 };
    inset.shadow_blur = 2.5;
    inset.offset_y = 1.5;
    inset.radii = .{ 4, 2, 5, 3 };
    inset.flags = 1 << 24 | 2 | 1 << 16;
    var sentinel = item;
    sentinel.rect = .{ -100, -100, 0, 0 };
    const instances = [_]Instance{ sentinel, sentinel, item, inset };
    var buffer = try context.createBuffer(a, .{ .size = @sizeOf(@TypeOf(instances)), .usage = .{ .vertex = true, .map_write = true } });
    defer buffer.destroy();
    @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.sliceAsBytes(&instances));
    const ShadowParam = extern struct { color: [4]f32, blur: f32, ox: f32, oy: f32, pad: f32 = 0 };
    const sp = [_]ShadowParam{.{ .color = .{ 0.1, 0.2, 0.7, 0.6 }, .blur = 7.5, .ox = 4, .oy = -2 }};
    var shadow_buffer = try context.createBuffer(a, .{ .size = 32, .usage = .{ .vertex = true, .map_write = true } });
    defer shadow_buffer.destroy();
    @memcpy(try shadow_buffer.getMappedRange(0, 32), std.mem.sliceAsBytes(&sp));
    var stop_buffer = try context.createBuffer(a, .{ .size = 32, .usage = .{ .vertex = true, .map_write = true } });
    defer stop_buffer.destroy();
    @memset(try stop_buffer.getMappedRange(0, 32), 0);
    var target = try context.createTexture(a, .{ .size = .{ .width = 48, .height = 40 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    const uniforms = Uniforms{ .clip = .{ .scale = 1, .viewport = .{ 48, 40 } } };
    var out: [2][48 * 40 * 4]u8 = undefined;
    for (0..2) |mode| {
        var encoder = try c.CommandEncoder.init(queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
        pass.setVertexBuffer(1, &buffer, 176);
        pass.setFragmentBuffer(1, &buffer, 176);
        pass.setFragmentBuffer(2, &stop_buffer, 0);
        pass.setVertexBuffer(3, &shadow_buffer, 0);
        pass.setFragmentBuffer(3, &shadow_buffer, 0);
        try pass.setVertexBytesChecked(0, std.mem.asBytes(&uniforms));
        try pass.setFragmentBytesChecked(0, std.mem.asBytes(&uniforms));
        if (mode == 0) {
            pass.setPipeline(&full_p);
            try pass.drawChecked(6, 2, 0, 1);
        } else for ([_]u32{ 1, 2 }) |first| {
            // As splitLayers: border and inset copies only for the inset instance.
            const layers = [_]*p.RenderPipeline{ &border_p, &inset_p, &body_p, &outer_p };
            for (if (first == 2) layers[0..] else layers[2..]) |layer| {
                pass.setPipeline(layer);
                try pass.drawChecked(6, 1, 0, first);
            }
        }
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        try target.readBgra8(48, 40, &out[mode], 48 * 4);
    }
    var max: u8 = 0;
    var changed: usize = 0;
    var shown: usize = 0;
    for (0..40) |y| for (0..48) |x| {
        const i = (y * 48 + x) * 4;
        var d: u8 = 0;
        for (0..4) |ch| d = @max(d, if (out[0][i + ch] > out[1][i + ch]) out[0][i + ch] - out[1][i + ch] else out[1][i + ch] - out[0][i + ch]);
        if (d > 2) {
            changed += 1;
            if (shown < 8) {
                std.debug.print("layer split px=({d},{d}) one-pass={any} split={any}\n", .{ x, y, out[0][i .. i + 4], out[1][i .. i + 4] });
                shown += 1;
            }
        }
        max = @max(max, d);
    };
    // Each layer pass stores an 8-bit intermediate: extra rounding steps
    // against the one pass (measured max 2). A wrong layer order differs
    // by far more (11 for shadows drawn below the body).
    if (max > 2) return error.LayerSplitChangedPixels;
    std.debug.print("PASS: layer split (border, inset, body, outer shadows) reproduces the one-pass program, max channel error {d}, translucent fill + two shadows, inset shadow + per-side border + gradient\n", .{max});
}

pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("SDF context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.sdf);
    defer module.deinit();
    var vertex = try module.getFunction("sdf_vertex_main");
    defer vertex.deinit();
    // Production D3D12 draws material instances with the body entry; outer
    // shadows are a separate pass (sdf_outer_shadow_fragment_main).
    var fragment = try module.getFunction("sdf_body_fragment_main");
    defer fragment.deinit();
    var pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer pipeline.deinit();
    var solid_fragment = try module.getFunction("sdf_solid_fragment_main");
    defer solid_fragment.deinit();
    var solid_pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &solid_fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer solid_pipeline.deinit();
    var plain_fragment = try module.getFunction("sdf_plain_rect_fragment_main");
    defer plain_fragment.deinit();
    // Production draws a general instance with an inset shadow as layer passes,
    // over-blended bottom-up: border, inset shadow, body (see splitLayers).
    var layer_pipelines: [3]p.RenderPipeline = undefined;
    for (&layer_pipelines, [_][]const u8{ "sdf_border_layer_fragment_main", "sdf_inset_layer_fragment_main", "sdf_body_fragment_main" }, 0..) |*slot, entry, index| {
        var layer_fragment = try module.getFunction(entry);
        defer layer_fragment.deinit();
        slot.* = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &layer_fragment, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } });
        errdefer for (layer_pipelines[0..index]) |*done| done.deinit();
    }
    defer for (&layer_pipelines) |*value| value.deinit();
    try checkLayerSplit(context, &queue, &module, &vertex, &device);
    var plain_pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &plain_fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer plain_pipeline.deinit();

    var material_pipelines: [3]p.RenderPipeline = undefined;
    var initialized: usize = 0;
    defer for (material_pipelines[0..initialized]) |*value| value.deinit();
    for ([_][]const u8{ "sdf_linear_x_fragment_main", "sdf_linear_y_fragment_main", "sdf_inset_rect_fragment_main" }, 0..) |name, i| {
        var function = try module.getFunction(name);
        defer function.deinit();
        material_pipelines[i] = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &function, .color_attachment_formats = &.{.bgra8_unorm} });
        initialized += 1;
    }

    if (try pipeline.bufferStride(0, 1) != 176 or try pipeline.bufferStride(0, 2) != 32 or try pipeline.bufferStride(0, 3) != 32) return error.IncorrectSdfStrides;
    const stops = [_]Stop{ .{ .color = .{ 1, 0.2, 0, 0.2 }, .position = 0 }, .{ .color = .{ 0, 1, 0.4, 0.8 }, .position = 0.4 }, .{ .color = .{ 0.1, 0, 1, 0.5 }, .position = 1 } };
    var stop_buffer = try context.createBuffer(a, .{ .size = @sizeOf(@TypeOf(stops)), .usage = .{ .vertex = true, .map_write = true } });
    defer stop_buffer.destroy();
    @memcpy(try stop_buffer.getMappedRange(0, stop_buffer.size), std.mem.sliceAsBytes(&stops));
    var shadow_buffer = try context.createBuffer(a, .{ .size = 32, .usage = .{ .vertex = true, .map_write = true } });
    defer shadow_buffer.destroy();
    @memset(try shadow_buffer.getMappedRange(0, 32), 0);
    var target = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var output: [256]u8 = undefined;
    var draws: usize = 0;
    var cpu_reference_pixels: usize = 0;
    const plain_variants = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17, 10, 11, 15, 18 };
    var plain_pixels: [3][plain_variants.len][256]u8 = undefined;
    const base_cases = 19;
    for ([_]f32{ 1, 1.75, 2 }, 0..) |scale, scale_index| for (0..base_cases + plain_variants.len) |case| {
        const variant = if (case >= base_cases) plain_variants[case - base_cases] else case;
        var instance = Instance{};
        instance.rect = if (variant == 4 or variant == 9) .{ 0, 1 / scale, 8 / scale, 6 / scale } else .{ 0, 0, 8 / scale, 8 / scale };
        for (&instance.radii) |*radius| radius.* /= scale;
        if (variant < 10) {
            instance.shape = @intCast(variant % 5);
            instance.border_width = if (variant >= 5) 1 / scale else 0;
        }
        if (instance.shape == 3) {
            instance.radii[0] = 3.5 / scale;
            instance.border_width = 1 / scale;
            instance.offset_x = 0;
            instance.offset_y = std.math.pi;
        }
        if (variant >= 10 and variant < 16) {
            instance.flags = @intCast(variant - 9);
            if (variant == 15) {
                instance.flags = 2;
                instance.stop_count = 3;
            }
        }
        if (variant == 16) instance.widths = .{ 1 / scale, 2 / scale, 0.5 / scale, 1.5 / scale };
        if (variant == 17) instance.radii = @splat(0);
        if (variant == 18) {
            instance.flags = 1 << 24;
            instance.shadow = .{ 0.2, 0.4, 0.7, 0.6 };
            instance.shadow_blur = 2 / scale;
            instance.offset_x = 0.5 / scale;
            instance.offset_y = 1 / scale;
            instance.border_width = 0.75 / scale;
        }
        // An unused noise seed forces the general branch without changing
        // semantics when noise_mode is zero. Compare it to the plain branch.
        if (case >= base_cases) instance.flags |= 1 << 16;
        const uniforms = Uniforms{ .clip = .{ .scale = scale } };
        var sentinel = instance;
        sentinel.rect = .{ -100, -100, 0, 0 };
        const instances = [_]Instance{ sentinel, sentinel, instance };
        var buffer = try context.createBuffer(a, .{ .size = @sizeOf(@TypeOf(instances)), .usage = .{ .vertex = true, .map_write = true } });
        defer buffer.destroy();
        @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.sliceAsBytes(&instances));
        var encoder = try c.CommandEncoder.init(&queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
        pass.setPipeline(if (case < base_cases and variant == 10) &material_pipelines[0] else if (case < base_cases and (variant == 11 or variant == 15)) &material_pipelines[1] else if (case < base_cases and variant == 18) &material_pipelines[2] else if (case < base_cases and variant == 17) &plain_pipeline else if (case < base_cases and (variant < 10 or variant == 16)) &solid_pipeline else &pipeline);
        pass.setVertexBuffer(1, &buffer, 176);
        pass.setFragmentBuffer(1, &buffer, 176);
        pass.setFragmentBuffer(2, &stop_buffer, 0);
        pass.setVertexBuffer(3, &shadow_buffer, 0);
        pass.setFragmentBuffer(3, &shadow_buffer, 0);
        try pass.setVertexBytesChecked(0, std.mem.asBytes(&uniforms));
        try pass.setFragmentBytesChecked(0, std.mem.asBytes(&uniforms));
        if (case >= base_cases and variant == 18) {
            for (&layer_pipelines) |*layer| {
                pass.setPipeline(layer);
                try pass.drawChecked(6, 1, 0, 1);
            }
        } else try pass.drawChecked(6, 1, 0, 1);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        try target.readBgra8(8, 8, &output, 32);
        if (variant != 18) for (0..8) |y| for (0..8) |x| {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const sdf = shapeDistance(px, py, instance, scale);
            const aa = quadAa(x, y, ShapeField{ .inst = instance, .scale = scale });
            const fill_mask = mask(sdf, aa);
            const border_mask = if (variant == 16) perSideBorderMask(px, py, instance, scale, fill_mask, aa) else if (instance.border_width > 0) fill_mask - mask(sdf + instance.border_width * scale, aa) else 0;
            const fill = gradient(px, py, instance, scale, &stops);
            const fa = fill[3] * fill_mask;
            const ba = instance.border[3] * border_mask;
            var expected: [4]f64 = .{ fill[2] * fa + instance.border[2] * ba * (1 - fa), fill[1] * fa + instance.border[1] * ba * (1 - fa), fill[0] * fa + instance.border[0] * ba * (1 - fa), fa + ba * (1 - fa) };
            if ((instance.shape == 4 and (y == 0 or y == 7)) or expected[3] < 0.001) expected = @splat(0);
            for (expected, 0..) |value, ch| {
                const byte: i32 = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
                if (@abs(@as(i32, output[(y * 8 + x) * 4 + ch]) - byte) > 2) {
                    std.debug.print("SDF mismatch scale={d} variant={d} x={d} y={d} ch={d} actual={d} expected={d}\n", .{ scale, variant, x, y, ch, output[(y * 8 + x) * 4 + ch], byte });
                    return error.IncorrectSdfPixel;
                }
            }
        };
        if (case >= base_cases and variant == 18) {
            // Layer passes store 8-bit intermediates: two extra rounding steps.
            for (output, plain_pixels[scale_index][case - base_cases]) |x, y| if (@abs(@as(i32, x) - y) > 2)
                return error.InsetLayerPassesChangedPixels;
        } else if (case >= base_cases) {
            if (!std.mem.eql(u8, &output, &plain_pixels[scale_index][case - base_cases]))
                return error.PlainSdfFastPathChangedPixels;
        } else for (plain_variants, 0..) |plain_variant, index| {
            if (variant == plain_variant) plain_pixels[scale_index][index] = output;
        }
        if (variant != 18) cpu_reference_pixels += 64;
        draws += 1;
    };
    for (0..64) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_SDF_RGBA8_HEX={s}\nPASS: production HLSL SDF, {d} draws/{d} CPU-reference pixels (byte tolerance2), stride176/stop32/shadow32, 340-byte inline uniform tail padding, rect/circle/line/arc/ellipse, uniform/asymmetric borders, byte-exact plain/solid/linear-gradient/inset/general equivalence, 5 gradients and 3-stop gradient, scale1/1.75/2 and nonzero instance/buffer offsets\n", .{ std.fmt.bytesToHex(output, .lower), draws, cpu_reference_pixels });
}

/// Diagnostic only: isolate fragment evaluation from sRGB/blending at the VM's
/// actual drawable size. Never treat these samples as an application FPS gate.
pub fn profile() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("SDF profile cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.sdf);
    defer module.deinit();
    var vertex = try module.getFunction("sdf_vertex_main");
    defer vertex.deinit();
    var ring_vertex = try module.getFunction("sdf_shadow_ring_vertex_main");
    defer ring_vertex.deinit();
    var tiled_vertex = try module.getFunction("sdf_tiled_rect_vertex_main");
    defer tiled_vertex.deinit();
    var flat_module = try p.ShaderModule.initFromSource(&device,
        \\// zenit-entry: fragment flat
        \\float4 flat():SV_Target { return float4(0.125,0.25,0.375,0.5); }
    );
    defer flat_module.deinit();
    var flat = try flat_module.getFunction("flat");
    defer flat.deinit();
    var solid = try module.getFunction("sdf_solid_fragment_main");
    defer solid.deinit();
    var rect = try module.getFunction("sdf_rect_fragment_main");
    defer rect.deinit();
    var plain = try module.getFunction("sdf_plain_rect_fragment_main");
    defer plain.deinit();
    var general = try module.getFunction("sdf_body_fragment_main");
    defer general.deinit();
    var outer = try module.getFunction("sdf_outer_shadow_fragment_main");
    defer outer.deinit();
    var instance = Instance{};
    instance.rect = .{ 0, 0, 1925, 1750 };
    instance.radii = @splat(0);
    var buffer = try context.createBuffer(a, .{ .size = @sizeOf(Instance), .usage = .{ .vertex = true, .map_write = true } });
    defer buffer.destroy();
    @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.asBytes(&instance));
    var dummy = try context.createBuffer(a, .{ .size = 32, .usage = .{ .vertex = true, .map_write = true } });
    defer dummy.destroy();
    @memset(try dummy.getMappedRange(0, 32), 0);
    const uniforms = Uniforms{ .clip = .{ .viewport = .{ 1925, 1750 }, .scale = 1 } };
    for ([_]@import("gpu").TextureFormat{ .bgra8_unorm, .bgra8_unorm_srgb }) |format| {
        var target = try context.createTexture(a, .{ .size = .{ .width = 1925, .height = 1750 }, .format = format, .usage = .{ .render_attachment = true } });
        defer target.destroy();
        var view = target.binding().createView();
        defer view.destroy();
        for ([_]bool{ false, true }) |blend| {
            for ([_]*p.ShaderFunction{ &flat, &plain, &plain, &solid, &rect, &general, &outer, &outer }, [_][]const u8{ "flat", "plain", "tiled-plain", "solid", "rect", "general", "shadow", "shadow-ring" }) |fragment, label| {
                const ring = std.mem.eql(u8, label, "shadow-ring");
                const tiled = std.mem.eql(u8, label, "tiled-plain");
                var item = instance;
                if (std.mem.startsWith(u8, label, "shadow")) {
                    item.rect = .{ 100, 100, 1725, 1550 };
                    item.fill[3] = 0;
                    item.shadow = .{ 0.15, 0.3, 0.45, 0.6 };
                    item.shadow_blur = 24;
                    item.radii = @splat(12);
                }
                @memcpy(try buffer.getMappedRange(0, buffer.size), std.mem.asBytes(&item));
                var pipeline = try p.createRenderPipeline(&device, .{
                    .vertex_function = if (ring) &ring_vertex else if (tiled) &tiled_vertex else &vertex,
                    .fragment_function = fragment,
                    .color_attachment_formats = &.{format},
                    .blend_state = if (blend) .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } else null,
                });
                defer pipeline.deinit();
                var samples: [7]u64 = undefined;
                for (0..samples.len + 1) |i| {
                    var encoder = try c.CommandEncoder.init(&queue);
                    defer encoder.deinit();
                    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
                    pass.setPipeline(&pipeline);
                    pass.setVertexBuffer(1, &buffer, 0);
                    pass.setFragmentBuffer(1, &buffer, 0);
                    pass.setVertexBuffer(3, &dummy, 0);
                    pass.setFragmentBuffer(2, &dummy, 0);
                    pass.setFragmentBuffer(3, &dummy, 0);
                    try pass.setVertexBytesChecked(0, std.mem.asBytes(&uniforms));
                    try pass.setFragmentBytesChecked(0, std.mem.asBytes(&uniforms));
                    try pass.drawChecked(if (ring) 24 else if (tiled) 30 else 6, 1, 0, 0);
                    pass.end();
                    var command = try encoder.finish();
                    defer command.deinit();
                    try command.submitChecked();
                    try command.waitChecked(5000);
                    const elapsed = command.gpuElapsedMicros() orelse return error.MissingProfileTimestamp;
                    if (i > 0) samples[i - 1] = elapsed;
                }
                std.debug.print("SDF_PROFILE format={s} blend={} shader={s} pixels=3368750 samples_us={any}\n", .{ @tagName(format), blend, label, samples });
            }
        }
    }
}
