//! Pixel contracts for the actual Metal shaders, executed by `zig build test-metal`.
//! These test optical invariants rather than comparing a shader with its own math.
const std = @import("std");
const gpu = @import("gpu");
const blur = @import("backdrop_blur.zig");
const tab_lens_field = @import("tab_lens_field.zig");
const Uniforms = blur.GlassUniforms;
const a = std.testing.allocator;

const Fixture = struct {
    sharp: gpu.Backend.Texture,
    blurred: gpu.Backend.Texture,
    output: gpu.Backend.Texture,
    pipeline: gpu.Backend.RenderPipeline,
    sampler: gpu.Backend.Sampler,
    /// The tab lens's field table (fragment buffer 1), bound on every draw like the app's.
    field: gpu.Backend.Buffer,
    width: u32,
    height: u32,

    fn init(device: *gpu.Backend.Device, width: u32, height: u32) !Fixture {
        return initWithSource(device, width, height, @embedFile("shaders/glass.metal"));
    }

    fn initWithSource(device: *gpu.Backend.Device, width: u32, height: u32, source: []const u8) !Fixture {
        const desc: gpu.TextureDescriptor = .{
            .size = .{ .width = width, .height = height },
            .format = .bgra8_unorm,
            .memory = .host_upload,
            .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true },
        };
        var sharp = try device.createTexture(a, desc);
        errdefer sharp.destroy();
        var blurred = try device.createTexture(a, desc);
        errdefer blurred.destroy();
        var output = try device.createTexture(a, desc);
        errdefer output.destroy();
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, source);
        defer shader.deinit();
        var vertex = try shader.getFunction("glass_vertex_main");
        defer vertex.deinit();
        var fragment = try shader.getFunction("glass_fragment_main");
        defer fragment.deinit();
        var pipeline = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex,
            .fragment_function = &fragment,
            .color_attachment_formats = &.{.bgra8_unorm},
            .blend_state = null,
        });
        errdefer pipeline.deinit();
        var sampler = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
        errdefer sampler.destroy();
        const field = try tab_lens_field.create(a, device);
        return .{ .sharp = sharp, .blurred = blurred, .output = output, .pipeline = pipeline, .sampler = sampler, .field = field, .width = width, .height = height };
    }

    fn deinit(self: *Fixture) void {
        self.field.destroy();
        self.sampler.destroy();
        self.pipeline.deinit();
        self.output.destroy();
        self.blurred.destroy();
        self.sharp.destroy();
    }

    fn uniforms(self: *Fixture, scale: f32) Uniforms {
        return .{
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(self.width)), 1.0 / @as(f32, @floatFromInt(self.height)) },
            .corner_radius = 24,
            .glass_intensity = 1,
            .rect_size = .{ 128, 64 },
            .scale_factor = scale,
            .glass_tint = .{ 1, 1, 1, 0 },
            .content_uv = .{ 1.0 / 6.0, 0.25, 2.0 / 3.0, 0.5 },
        };
    }

    fn upload(self: *Fixture, valid: [4]f32, constant_gray: ?u8) !void {
        const bytes = try a.alloc(u8, self.width * self.height * 4);
        defer a.free(bytes);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const uv = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(self.width));
                const uy = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(self.height));
                const inside = uv >= valid[0] and uv < valid[2] and uy >= valid[1] and uy < valid[3];
                const v: u8 = constant_gray orelse @intFromFloat(40 + 170 * std.math.clamp((uv - valid[0]) / (valid[2] - valid[0]), 0, 1));
                const i = (y * self.width + x) * 4;
                @memcpy(bytes[i..][0..4], &[_]u8{ if (inside) v else 0, if (inside) v else 0, if (inside) v else 0, if (inside) 255 else 0 });
            }
        }
        try self.sharp.writeRegion(0, 0, 0, self.width, self.height, bytes, self.width * 4);
        // A repacked linear-ramp backdrop has a known correspondence to capture.
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const uv = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(self.width));
                const v: u8 = constant_gray orelse @intFromFloat(40 + 170 * uv);
                @memcpy(bytes[(y * self.width + x) * 4 ..][0..4], &[_]u8{ v, v, v, 255 });
            }
        }
        try self.blurred.writeRegion(0, 0, 0, self.width, self.height, bytes, self.width * 4);
    }

    fn render(self: *Fixture, queue: *gpu.Backend.Queue, u: Uniforms) ![]u8 {
        return self.renderWithScissor(queue, u, null);
    }

    fn renderWithScissor(self: *Fixture, queue: *gpu.Backend.Queue, u: Uniforms, scissor: ?[4]u32) ![]u8 {
        var encoder = try gpu.Backend.CommandEncoder.init(queue);
        errdefer encoder.deinit();
        var view = self.output.binding().createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }} });
        pass.setPipeline(&self.pipeline);
        pass.setFragmentBytes(0, std.mem.asBytes(&u));
        pass.setFragmentTextureBinding(0, self.blurred.binding());
        pass.setFragmentTextureBinding(1, self.sharp.binding());
        pass.setFragmentTextureBinding(2, self.sharp.binding());
        pass.setFragmentTextureBinding(3, self.sharp.binding());
        pass.setFragmentSampler(0, &self.sampler);
        pass.setFragmentBuffer(tab_lens_field.slot, &self.field, 0);
        if (scissor) |sc| pass.setScissorRect(sc[0], sc[1], sc[2], sc[3]);
        pass.draw(3, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        const bytes = try a.alloc(u8, self.width * self.height * 4);
        errdefer a.free(bytes);
        try self.output.readBgra8(self.width, self.height, bytes, self.width * 4);
        return bytes;
    }

    fn kawase(self: *Fixture, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue, valid: [4]f32, offset: f32) !void {
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, @embedFile("shaders/blur.metal"));
        defer shader.deinit();
        var vertex = try shader.getFunction("kawase_vertex_main");
        defer vertex.deinit();
        var fragment = try shader.getFunction("kawase_downsample");
        defer fragment.deinit();
        var pipeline = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex,
            .fragment_function = &fragment,
            .color_attachment_formats = &.{.bgra8_unorm},
            .blend_state = null,
        });
        defer pipeline.deinit();
        var encoder = try gpu.Backend.CommandEncoder.init(queue);
        errdefer encoder.deinit();
        var view = self.blurred.binding().createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        const tx = 1.0 / @as(f32, @floatFromInt(self.width));
        const ty = 1.0 / @as(f32, @floatFromInt(self.height));
        const kawase_uniforms = blur.KawaseUniforms{
            .texel_size = .{ tx, ty },
            .offset_scale = offset,
            .valid_uv = .{ valid[0] + tx * 0.5, valid[1] + ty * 0.5, valid[2] - tx * 0.5, valid[3] - ty * 0.5 },
        };
        pass.setPipeline(&pipeline);
        pass.setFragmentBytes(0, std.mem.asBytes(&kawase_uniforms));
        pass.setFragmentTextureBinding(0, self.sharp.binding());
        pass.setFragmentSampler(0, &self.sampler);
        pass.draw(3, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
    }
};

test "metal legacy glass: conservative scissor matches the full cleared target byte for byte" {
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
    var f = try Fixture.init(&dq.device, 131, 127);
    defer f.deinit();
    try f.upload(.{ 0, 0, 1, 1 }, null);
    const cases = [_]struct { rect: [2]f32, uv: [4]f32, radius: f32 }{
        .{ .rect = .{ 64, 64 }, .uv = .{ 0.25, 0.25, 0.5, 0.5 }, .radius = 16 },
        .{ .rect = .{ 96, 4 }, .uv = .{ 0.125, 0.375, 0.75, 0.125 }, .radius = 2 },
        .{ .rect = .{ 4, 96 }, .uv = .{ 0.375, 0.125, 0.125, 0.75 }, .radius = 2 },
        .{ .rect = .{ 32, 48 }, .uv = .{ -0.125, 0.25, 0.5, 0.5 }, .radius = 12 },
        .{ .rect = .{ 48, 32 }, .uv = .{ 0.75, 0.125, 0.5, 0.5 }, .radius = 8 },
        .{ .rect = .{ 0.5, 0.75 }, .uv = .{ 0.375, 0.375, 0.125, 0.125 }, .radius = 8 },
    };
    for (cases) |c| {
        var u = f.uniforms(1);
        u.rect_size = c.rect;
        u.content_uv = c.uv;
        u.corner_radius = c.radius;
        const sc = blur.legacyGlassScissor(f.width, f.height, &u) orelse return error.ExpectedReducedScissor;
        const expected = try f.render(&dq.queue, u);
        defer a.free(expected);
        const actual = try f.renderWithScissor(&dq.queue, u, sc);
        defer a.free(actual);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "metal glass: blur/capture registration, Fresnel, tint and disabled optics" {
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
    var f = try Fixture.init(&dq.device, 192, 128);
    defer f.deinit();
    var u = f.uniforms(1);
    u.glass_intensity = 0;
    u.specular_params = .{ 0, 1, 1, 0 };
    u.valid_uv = .{ 0.125, 0.125, 0.875, 0.875 };
    try f.upload(u.valid_uv, null);
    const sharp = try f.render(&dq.queue, u);
    defer a.free(sharp);
    u.specular_params[3] = 1;
    u.optic_params[3] = 1;
    const blurred = try f.render(&dq.queue, u);
    defer a.free(blurred);
    for (40..88) |y| for (42..150) |x| {
        const i = (y * 192 + x) * 4;
        try std.testing.expect(@abs(@as(i32, sharp[i]) - @as(i32, blurred[i])) <= 2);
    };
    // Exercise the real Kawase shader too, including its texel-center bounds.
    try f.kawase(&dq.device, &dq.queue, u.valid_uv, 1);
    const actual_blur = try f.render(&dq.queue, u);
    defer a.free(actual_blur);
    for (40..88) |y| for (42..150) |x| {
        const i = (y * 192 + x) * 4;
        try std.testing.expect(@abs(@as(i32, sharp[i]) - @as(i32, actual_blur[i])) <= 2);
    };

    // intensity=0 means blur only, including when magnification is nonzero.
    u.surface_params[3] = 1.5;
    const disabled = try f.render(&dq.queue, u);
    defer a.free(disabled);
    try std.testing.expectEqualSlices(u8, actual_blur, disabled);
    u.glass_intensity = 1;
    u.specular_params[2] = 0;
    const no_refraction = try f.render(&dq.queue, u);
    defer a.free(no_refraction);
    u.surface_params[3] = 0;
    const no_zoom = try f.render(&dq.queue, u);
    defer a.free(no_zoom);
    try std.testing.expectEqualSlices(u8, no_refraction, no_zoom);

    // On a neutral backdrop the unlit center stays neutral and the inner rim
    // reflects only a small fraction. The old inverted view vector made F=1.
    try f.upload(.{ 0, 0, 1, 1 }, 90);
    u = f.uniforms(1);
    u.specular_params = .{ 0, 1, 0, 0 };
    const dielectric = try f.render(&dq.queue, u);
    defer a.free(dielectric);
    try std.testing.expect(@abs(@as(i32, dielectric[(64 * 192 + 96) * 4]) - 90) <= 2);
    try std.testing.expect(dielectric[(34 * 192 + 96) * 4] < 120);

    // Zero brightness and zero saturation are valid adjustments, not sentinels.
    u.glass_intensity = 0;
    u.bottom_surface_params[3] = 0;
    const black = try f.render(&dq.queue, u);
    defer a.free(black);
    try std.testing.expectEqual(@as(u8, 0), black[(64 * 192 + 96) * 4]);
    const colored = try a.alloc(u8, f.width * f.height * 4);
    defer a.free(colored);
    for (0..f.width * f.height) |i| @memcpy(colored[i * 4 ..][0..4], &[_]u8{ 40, 140, 220, 255 });
    try f.sharp.writeRegion(0, 0, 0, f.width, f.height, colored, f.width * 4);
    u.bottom_surface_params[3] = 1;
    u.bottom_surface_params[2] = 0;
    const grayscale = try f.render(&dq.queue, u);
    defer a.free(grayscale);
    const center = (64 * 192 + 96) * 4;
    try std.testing.expectEqual(grayscale[center], grayscale[center + 1]);
    try std.testing.expectEqual(grayscale[center + 1], grayscale[center + 2]);

    // A readable material veil lifts dark transmission. An opaque prominent
    // tint must retain its color even below unity optical intensity.
    try f.upload(.{ 0, 0, 1, 1 }, 40);
    u.bottom_surface_params[2] = 1;
    u.tint_mode = 1;
    u.glass_intensity = 0.5;
    u.glass_tint = .{ 1, 1, 1, 0.8 };
    const veil = try f.render(&dq.queue, u);
    defer a.free(veil);
    try std.testing.expect(veil[center] > 225);
    u.glass_tint = .{ 0, 122.0 / 255.0, 1, 1 };
    const prominent = try f.render(&dq.queue, u);
    defer a.free(prominent);
    try std.testing.expect(prominent[center] >= 253);
    try std.testing.expect(@abs(@as(i32, prominent[center + 1]) - 122) <= 3);
    try std.testing.expect(prominent[center + 2] <= 2);
    u.glass_intensity = 0;
    const only_blur = try f.render(&dq.queue, u);
    defer a.free(only_blur);
    try std.testing.expectEqual(@as(u8, 40), only_blur[center]);

    // A coated plate keeps its opaque tint outside the thin reflected edge.
    u.glass_intensity = 1;
    u.surface_params[0] = 5;
    u.specular_params[0] = 0.3;
    const coated_tint = try f.render(&dq.queue, u);
    defer a.free(coated_tint);
    for (36..92) |y| {
        const i = (y * 192 + 96) * 4;
        try std.testing.expect(coated_tint[i + 2] <= 2);
        try std.testing.expect(@abs(@as(i32, coated_tint[i + 1]) - 122) <= 3);
    }

    // Strong sidewall refraction must not bend a plate's flat interior.
    try f.upload(.{ 0, 0, 1, 1 }, null);
    u = f.uniforms(1);
    u.surface_params = .{ 5, 0.45, -1, 0 };
    u.optic_params = .{ 3, 20, 8, 0 };
    u.specular_params = .{ 0.3, 1, 1, 0 };
    const plate = try f.render(&dq.queue, u);
    defer a.free(plate);
    u.glass_intensity = 0;
    const unwarped = try f.render(&dq.queue, u);
    defer a.free(unwarped);
    for (50..78) |y| for (56..136) |x| {
        const i = (y * 192 + x) * 4;
        try std.testing.expect(@abs(@as(i32, plate[i]) - @as(i32, unwarped[i])) <= 2);
    };
}

test "metal glass: material is DPI invariant, including colored absorption" {
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
    var one = try Fixture.init(&dq.device, 192, 128);
    defer one.deinit();
    var two = try Fixture.init(&dq.device, 384, 256);
    defer two.deinit();
    try one.upload(.{ 0, 0, 1, 1 }, null);
    try two.upload(.{ 0, 0, 1, 1 }, null);
    var u = one.uniforms(1);
    u.glass_tint = .{ 0.38, 0.64, 0.90, 0.4 };
    u.optic_params = .{ 1.2, 6, 3, 0 };
    u.specular_params[3] = 0;
    const pixels1 = try one.render(&dq.queue, u);
    defer a.free(pixels1);
    var v = u;
    v.scale_factor = 2;
    v.texel_size = two.uniforms(2).texel_size;
    const pixels2 = try two.render(&dq.queue, v);
    defer a.free(pixels2);
    for (38..90) |y| for (50..142) |x| {
        for (0..3) |c| {
            var sum: f32 = 0;
            for (0..2) |dy| for (0..2) |dx| {
                sum += @floatFromInt(pixels2[((y * 2 + dy) * 384 + x * 2 + dx) * 4 + c]);
            };
            const expected: f32 = @floatFromInt(pixels1[(y * 192 + x) * 4 + c]);
            try std.testing.expectApproxEqAbs(expected, sum / 4, 4);
        }
    };
}

// Optional visual QA from the same GPU fixture, without requiring WindowServer.
// zig build test-metal -Dglass-evidence-dir=/tmp/glass
// -Dglass-reference-shader can point to a saved shader for before/after QA.
test "metal glass: optional offscreen material evidence" {
    const out = @import("zenit_environment").getBorrowed("ZENIT_GLASS_EVIDENCE_DIR") orelse return;
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
    const reference = if (@import("zenit_environment").getBorrowed("ZENIT_GLASS_REFERENCE_SHADER")) |path|
        try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20))
    else
        null;
    defer if (reference) |s| a.free(s);
    var f = try Fixture.initWithSource(&dq.device, 384, 256, reference orelse @embedFile("shaders/glass.metal"));
    defer f.deinit();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, out);
    const backdrop = try a.alloc(u8, f.width * f.height * 4);
    defer a.free(backdrop);
    for ([_]bool{ false, true }) |dark| {
        for (0..f.height) |y| for (0..f.width) |x| {
            const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(f.width));
            const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(f.height));
            const shade: f32 = (if (dark) @as(f32, 0.35) else 1.0) * (if (x % 32 < 2 or y % 32 < 2) @as(f32, 0.65) else 1.0);
            const i = (y * f.width + x) * 4;
            backdrop[i] = @intFromFloat((230 - 145 * fx) * shade);
            backdrop[i + 1] = @intFromFloat((90 + 110 * fy) * shade);
            backdrop[i + 2] = @intFromFloat((65 + 170 * fx) * shade);
            backdrop[i + 3] = 255;
        };
        try f.sharp.writeRegion(0, 0, 0, f.width, f.height, backdrop, f.width * 4);
        try f.kawase(&dq.device, &dq.queue, .{ 0, 0, 1, 1 }, 12);
        var u = f.uniforms(2);
        u.corner_radius = 32;
        u.specular_params = .{ 0.3, 4.5, 1, 0.82 };
        u.lens_params[2] = 1.2;
        u.optic_params[3] = 1;
        const pixels = try f.render(&dq.queue, u);
        defer a.free(pixels);
        // Glass output contains linear-light premultiplied RGB encoded to sRGB.
        const rgb = try a.alloc(u8, f.width * f.height * 3);
        defer a.free(rgb);
        for (0..f.width * f.height) |i| {
            const alpha = @as(f32, @floatFromInt(pixels[i * 4 + 3])) / 255;
            for (0..3) |c| {
                const channel = 2 - c;
                const fg = decodeSrgb(pixels[i * 4 + channel]);
                const bg = decodeSrgb(backdrop[i * 4 + channel]);
                const linear = std.math.clamp(fg + bg * (1 - alpha), 0, 1);
                const encoded = if (linear <= 0.0031308) linear * 12.92 else 1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
                rgb[i * 3 + c] = @intFromFloat(std.math.clamp(encoded * 255, 0, 255));
            }
        }
        const path = try std.fmt.allocPrint(a, "{s}/{s}.ppm", .{ out, if (dark) "dark" else "light" });
        defer a.free(path);
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "P6\n384 256\n255\n");
        try file.writeStreamingAll(std.testing.io, rgb);
    }
}

fn decodeSrgb(c: u8) f32 {
    const v = @as(f32, @floatFromInt(c)) / 255;
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

test "metal Gaussian: gamma DC, analytic Fourier transfer and continuous sigma" {
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
    var f = try Fixture.init(&dq.device, 256, 64);
    defer f.deinit();
    var shader = try gpu.Backend.ShaderModule.initFromSource(&dq.device, @embedFile("shaders/blur.metal"));
    defer shader.deinit();
    var vertex = try shader.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var fragment = try shader.getFunction("gaussian_blur");
    defer fragment.deinit();
    var pipeline = try gpu.Backend.createRenderPipeline(&dq.device, .{
        .vertex_function = &vertex,
        .fragment_function = &fragment,
        .color_attachment_formats = &.{.bgra8_unorm},
        .blend_state = null,
    });
    defer pipeline.deinit();
    const input = try a.alloc(u8, f.width * f.height * 4);
    defer a.free(input);
    var previous: ?[]u8 = null;
    defer if (previous) |pixels| a.free(pixels);
    for ([_]f32{ 2, 5.99, 6.01, 12, 2 }) |sigma| {
        const checker = sigma == 2 and previous != null;
        for (0..f.height) |y| for (0..f.width) |x| {
            const phase = 2 * std.math.pi * @as(f32, @floatFromInt(x)) / 64;
            const value: u8 = if (checker) (if (x % 2 == 0) 0 else 255) else @intFromFloat(@round(128 + 100 * @sin(phase)));
            @memcpy(input[(y * f.width + x) * 4 ..][0..4], &[_]u8{ value, value, value, 255 });
        };
        try f.sharp.writeRegion(0, 0, 0, f.width, f.height, input, f.width * 4);
        const valid = blur.validUv(0, 0, f.width, f.height, f.width, f.height);
        const u = blur.gaussianUniforms(sigma, f.width, f.height, false, valid);
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        errdefer encoder.deinit();
        var view = f.blurred.binding().createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        pass.setPipeline(&pipeline);
        pass.setFragmentBytes(0, std.mem.asBytes(&u));
        pass.setFragmentTextureBinding(0, f.sharp.binding());
        pass.setFragmentSampler(0, &f.sampler);
        pass.draw(3, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        const pixels = try a.alloc(u8, input.len);
        defer a.free(pixels);
        try f.blurred.readBgra8(f.width, f.height, pixels, f.width * 4);
        var dc: f32 = 0;
        var sine: f32 = 0;
        var cosine: f32 = 0;
        for (64..192) |x| {
            const value: f32 = @floatFromInt(pixels[(32 * f.width + x) * 4]);
            const phase = 2 * std.math.pi * @as(f32, @floatFromInt(x)) / 64;
            dc += value / 128;
            sine += value * @sin(phase) / 64;
            cosine += value * @cos(phase) / 64;
        }
        try std.testing.expectApproxEqAbs(if (checker) @as(f32, 127.5) else 128, dc, 1.0);
        if (!checker) {
            // Analytic Fourier transform of a Gaussian, independent of the
            // CPU's sampled/truncated kernel and the shader's implementation.
            const expected = 100 * @exp(-0.5 * std.math.pow(f32, 2 * std.math.pi * sigma / 64, 2));
            try std.testing.expectApproxEqAbs(expected, @sqrt(sine * sine + cosine * cosine), 1.0);
        }
        if (sigma == 6.01) if (previous) |before| {
            for (64..192) |x| {
                const i = (32 * f.width + x) * 4;
                try std.testing.expect(@abs(@as(i32, pixels[i]) - @as(i32, before[i])) <= 1);
            }
        };
        if (previous) |before| a.free(before);
        previous = try a.dupe(u8, pixels);
    }
}

test "metal Gaussian downsample: exact gamma box, DC, coverage and capture registration" {
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
    var f = try Fixture.init(&dq.device, 64, 48);
    defer f.deinit();
    const width = f.width / 2;
    const height = f.height / 2;
    var output = try dq.device.createTexture(a, .{
        .size = .{ .width = width, .height = height },
        .format = .bgra8_unorm,
        .memory = .host_upload,
        .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true },
    });
    defer output.destroy();
    var shader = try gpu.Backend.ShaderModule.initFromSource(&dq.device, @embedFile("shaders/blur.metal"));
    defer shader.deinit();
    var vertex = try shader.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var fragment = try shader.getFunction("gaussian_downsample");
    defer fragment.deinit();
    var pipeline = try gpu.Backend.createRenderPipeline(&dq.device, .{
        .vertex_function = &vertex,
        .fragment_function = &fragment,
        .color_attachment_formats = &.{.bgra8_unorm},
        .blend_state = null,
    });
    defer pipeline.deinit();
    const input = try a.alloc(u8, f.width * f.height * 4);
    defer a.free(input);
    const pixels = try a.alloc(u8, width * height * 4);
    defer a.free(pixels);
    const Pattern = enum { checker, constant, registered, coverage };
    for ([_]Pattern{ .checker, .constant, .registered, .coverage }) |pattern| {
        for (0..f.height) |y| for (0..f.width) |x| {
            const rgba: [4]u8 = switch (pattern) {
                .checker => blk: {
                    const c: u8 = if ((x + y) % 2 == 0) 0 else 255;
                    break :blk .{ c, c, c, 255 };
                },
                .constant => .{ 73, 111, 161, 255 },
                // An off-center valid capture must keep its original pixel
                // positions, extending its edge into the transparent padding.
                .registered => if (x >= 8 and x < 56 and y >= 6 and y < 42)
                    .{ @intCast(x * 3), @intCast(y * 4), @intCast(((x + y) % 32) * 5), 255 }
                else
                    .{ 0, 0, 0, 0 },
                // One opaque white texel per 2x2 cell: 25% coverage of white,
                // stored as premultiplied sRGB-encoded RGB (non-sRGB attachment).
                .coverage => if (x % 2 == 0 and y % 2 == 0) .{ 255, 255, 255, 255 } else .{ 0, 0, 0, 0 },
            };
            @memcpy(input[(y * f.width + x) * 4 ..][0..4], &rgba);
        };
        try f.sharp.writeRegion(0, 0, 0, f.width, f.height, input, f.width * 4);
        const valid = if (pattern == .registered)
            blur.validUv(8, 6, 48, 36, f.width, f.height)
        else
            blur.validUv(0, 0, f.width, f.height, f.width, f.height);
        const uniforms = blur.KawaseUniforms{
            .texel_size = .{ 1.0 / @as(f32, @floatFromInt(f.width)), 1.0 / @as(f32, @floatFromInt(f.height)) },
            .offset_scale = 0,
            .valid_uv = valid,
        };
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        errdefer encoder.deinit();
        var view = output.binding().createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 1, .g = 0, .b = 1, .a = 0 },
        }} });
        pass.setPipeline(&pipeline);
        pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
        pass.setFragmentTextureBinding(0, f.sharp.binding());
        pass.setFragmentSampler(0, &f.sampler);
        pass.setViewport(0, 0, @floatFromInt(width), @floatFromInt(height), 0, 1);
        pass.draw(3, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        try output.readBgra8(width, height, pixels, width * 4);
        for (0..height) |y| for (0..width) |x| {
            const i = (y * width + x) * 4;
            for (0..3) |c| {
                const expected: f32 = switch (pattern) {
                    // Linear-light averaging would produce approximately 188.
                    .checker => 127.5,
                    .constant => @floatFromInt(input[c]),
                    // Encoded-space premultiply: white 25% coverage = 64 (unmultiply back to 255).
                    // Linear premultiply then encode is 137 from old contract.
                    .coverage => 64,
                    .registered => blk: {
                        var sum: f32 = 0;
                        for (0..2) |dy| for (0..2) |dx| {
                            const sx = std.math.clamp(x * 2 + dx, 8, 55);
                            const sy = std.math.clamp(y * 2 + dy, 6, 41);
                            sum += @floatFromInt(input[(sy * f.width + sx) * 4 + c]);
                        };
                        break :blk sum / 4;
                    },
                };
                try std.testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(pixels[i + c])), 1.0);
            }
            try std.testing.expectEqual(@as(u8, if (pattern == .coverage) 64 else 255), pixels[i + 3]);
        };
    }
}

test "metal float Gaussian: encoded transfer survives float intermediates" {
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
    var fixture = try Fixture.init(&dq.device, 256, 64);
    defer fixture.deinit();
    const desc = gpu.TextureDescriptor{ .size = .{ .width = 256, .height = 64 }, .format = .rgba16_float, .memory = .host_upload, .usage = .{ .texture_binding = true, .render_attachment = true } };
    var encoded = try dq.device.createTexture(a, desc);
    defer encoded.destroy();
    var filtered = try dq.device.createTexture(a, desc);
    defer filtered.destroy();
    var module = try gpu.Backend.ShaderModule.initFromSource(&dq.device, @embedFile("shaders/blur.metal"));
    defer module.deinit();
    var vertex = try module.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var pipelines: [3]gpu.Backend.RenderPipeline = undefined;
    var count: usize = 0;
    defer for (pipelines[0..count]) |*pipeline| pipeline.deinit();
    for ([_][]const u8{ "gaussian_encode", "gaussian_filter_gamma", "gaussian_decode" }, 0..) |name, i| {
        var fragment = try module.getFunction(name);
        defer fragment.deinit();
        pipelines[i] = try gpu.Backend.createRenderPipeline(&dq.device, .{
            .vertex_function = &vertex,
            .fragment_function = &fragment,
            .color_attachment_formats = if (i == 2) &.{.bgra8_unorm} else &.{.rgba16_float},
            .blend_state = null,
        });
        count += 1;
    }
    const input = try a.alloc(u8, 256 * 64 * 4);
    defer a.free(input);
    for (0..64) |y| for (0..256) |x| {
        const phase = 2 * std.math.pi * @as(f32, @floatFromInt(x)) / 64;
        const v: u8 = @intFromFloat(@round(128 + 100 * @sin(phase)));
        @memcpy(input[(y * 256 + x) * 4 ..][0..4], &[_]u8{ v, v, v, 255 });
    };
    try fixture.sharp.writeRegion(0, 0, 0, 256, 64, input, 256 * 4);
    for ([_]f32{ 0.75, 6.01, 12 }) |sigma| {
        var command_encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        errdefer command_encoder.deinit();
        const valid = blur.validUv(0, 0, 256, 64, 256, 64);
        const encode_uniforms = blur.KawaseUniforms{ .texel_size = .{ 1.0 / 256.0, 1.0 / 64.0 }, .offset_scale = 0, .valid_uv = valid };
        const filter_uniforms = blur.gaussianUniforms(sigma, 256, 64, false, valid);
        const sources = [_]gpu.Backend.TextureBinding{ fixture.sharp.binding(), encoded.binding(), filtered.binding() };
        const targets = [_]gpu.Backend.TextureBinding{ encoded.binding(), filtered.binding(), fixture.output.binding() };
        for (0..3) |i| {
            var view = targets[i].createView();
            defer view.destroy();
            var pass = try command_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
            pass.setPipeline(&pipelines[i]);
            if (i == 0) pass.setFragmentBytes(0, std.mem.asBytes(&encode_uniforms));
            if (i == 1) pass.setFragmentBytes(0, std.mem.asBytes(&filter_uniforms));
            pass.setFragmentTextureBinding(0, sources[i]);
            pass.setFragmentSampler(0, &fixture.sampler);
            pass.draw(3, 1, 0, 0);
            pass.end();
        }
        var command = try command_encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        const pixels = try a.alloc(u8, input.len);
        defer a.free(pixels);
        try fixture.output.readBgra8(256, 64, pixels, 256 * 4);
        var dc: f32 = 0;
        var cosine: f32 = 0;
        var sine: f32 = 0;
        for (64..192) |x| {
            const v: f32 = @floatFromInt(pixels[(32 * 256 + x) * 4]);
            const phase = 2 * std.math.pi * @as(f32, @floatFromInt(x)) / 64;
            dc += v / 128;
            cosine += v * @cos(phase) / 64;
            sine += v * @sin(phase) / 64;
        }
        const expected = 100 * @exp(-0.5 * std.math.pow(f32, 2 * std.math.pi * sigma / 64, 2));
        try std.testing.expectApproxEqAbs(@as(f32, 128), dc, 0.6);
        try std.testing.expectApproxEqAbs(expected, @sqrt(sine * sine + cosine * cosine), 0.6);
    }
}

test "metal gamma area downsample: odd source dimensions preserve integrated color and coverage" {
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
    var fixture = try Fixture.init(&dq.device, 5, 7);
    defer fixture.deinit();
    var reduced = try dq.device.createTexture(a, .{
        .size = .{ .width = 2, .height = 3 },
        .format = .rgba16_float,
        .memory = .host_upload,
        .usage = .{ .texture_binding = true, .render_attachment = true },
    });
    defer reduced.destroy();
    var output = try dq.device.createTexture(a, .{
        .size = .{ .width = 2, .height = 3 },
        .format = .bgra8_unorm,
        .memory = .host_upload,
        .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true },
    });
    defer output.destroy();
    var module = try gpu.Backend.ShaderModule.initFromSource(&dq.device, @embedFile("shaders/blur.metal"));
    defer module.deinit();
    var vertex = try module.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var pipelines: [2]gpu.Backend.RenderPipeline = undefined;
    var count: usize = 0;
    defer for (pipelines[0..count]) |*pipeline| pipeline.deinit();
    for ([_][]const u8{ "gaussian_downsample_gamma", "gaussian_decode" }, 0..) |name, i| {
        var fragment = try module.getFunction(name);
        defer fragment.deinit();
        pipelines[i] = try gpu.Backend.createRenderPipeline(&dq.device, .{
            .vertex_function = &vertex,
            .fragment_function = &fragment,
            .color_attachment_formats = if (i == 0) &.{.rgba16_float} else &.{.bgra8_unorm},
            .blend_state = null,
        });
        count += 1;
    }
    var bytes: [5 * 7 * 4]u8 = undefined;
    for (0..7) |y| for (0..5) |x| {
        const v: u8 = if ((x + y) % 2 == 0) 0 else 255;
        @memcpy(bytes[(y * 5 + x) * 4 ..][0..4], &[_]u8{ v, v, v, 255 });
    };
    try fixture.sharp.writeRegion(0, 0, 0, 5, 7, &bytes, 5 * 4);
    const uniforms = blur.GaussianAreaUniforms{ .source_size = .{ 5, 7 }, .output_size = .{ 2, 3 } };
    var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
    errdefer encoder.deinit();
    const sources = [_]gpu.Backend.TextureBinding{ fixture.sharp.binding(), reduced.binding() };
    const targets = [_]gpu.Backend.TextureBinding{ reduced.binding(), output.binding() };
    for (0..2) |i| {
        var view = targets[i].createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        pass.setPipeline(&pipelines[i]);
        if (i == 0) pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
        pass.setFragmentTextureBinding(0, sources[i]);
        pass.setFragmentSampler(0, &fixture.sampler);
        pass.setViewport(0, 0, 2, 3, 0, 1);
        pass.draw(3, 1, 0, 0);
        pass.end();
    }
    var command = try encoder.finish();
    defer command.deinit();
    command.submit();
    command.waitUntilCompleted();
    var pixels: [2 * 3 * 4]u8 = undefined;
    try output.readBgra8(2, 3, &pixels, 2 * 4);
    // Each output cell covers exactly 5/2 by 7/3 source pixels. Integrate
    // piecewise-constant checker values analytically, including final edges.
    for (0..3) |y| for (0..2) |x| {
        const x0 = @as(f32, @floatFromInt(x)) * 2.5;
        const y0 = @as(f32, @floatFromInt(y)) * (7.0 / 3.0);
        var expected: f32 = 0;
        for (0..7) |sy| for (0..5) |sx| {
            const fx: f32 = @floatFromInt(sx);
            const fy: f32 = @floatFromInt(sy);
            const area = @max(0, @min(x0 + 2.5, fx + 1) - @max(x0, fx)) * @max(0, @min(y0 + 7.0 / 3.0, fy + 1) - @max(y0, fy));
            expected += area * @as(f32, @floatFromInt(bytes[(sy * 5 + sx) * 4])) / (2.5 * 7.0 / 3.0);
        };
        for (0..3) |c| try std.testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(pixels[(y * 2 + x) * 4 + c])), 1.0);
        try std.testing.expectEqual(@as(u8, 255), pixels[(y * 2 + x) * 4 + 3]);
    };
}

test "metal native fine grid: four pixel gamma box and bilinear reconstruction preserve alias phase" {
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
    var fixture = try Fixture.init(&dq.device, 32, 16);
    defer fixture.deinit();
    var half = try dq.device.createTexture(a, .{ .size = .{ .width = 16, .height = 8 }, .format = .rgba16_float, .usage = .{ .texture_binding = true, .render_attachment = true } });
    defer half.destroy();
    var quarter = try dq.device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .rgba16_float, .usage = .{ .texture_binding = true, .render_attachment = true } });
    defer quarter.destroy();
    var module = try gpu.Backend.ShaderModule.initFromSource(&dq.device, @embedFile("shaders/blur.metal"));
    defer module.deinit();
    var vertex = try module.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var pipelines: [2]gpu.Backend.RenderPipeline = undefined;
    var count: usize = 0;
    defer for (pipelines[0..count]) |*pipeline| pipeline.deinit();
    for ([_][]const u8{ "gaussian_downsample_gamma", "gaussian_decode" }, 0..) |name, i| {
        var fragment = try module.getFunction(name);
        defer fragment.deinit();
        pipelines[i] = try gpu.Backend.createRenderPipeline(&dq.device, .{
            .vertex_function = &vertex,
            .fragment_function = &fragment,
            .color_attachment_formats = if (i == 0) &.{.rgba16_float} else &.{.bgra8_unorm},
            .blend_state = null,
        });
        count += 1;
    }
    const phases = [_][8]u8{ .{ 128, 199, 228, 199, 128, 57, 28, 57 }, .{ 228, 199, 128, 57, 28, 57, 128, 199 } };
    // Independent piecewise-linear reconstruction of the two alternating
    // four-pixel means: phase0 ±60.5, phase1 ±25 around DC128.
    const offsets = [_]f32{ 0.25, 0.75, 0.75, 0.25, -0.25, -0.75, -0.75, -0.25 };
    for (phases, 0..) |phase, phase_index| {
        var input: [32 * 16 * 4]u8 = undefined;
        for (0..16) |y| for (0..32) |x| {
            const v = phase[x % 8];
            @memcpy(input[(y * 32 + x) * 4 ..][0..4], &[_]u8{ v, v, v, 255 });
        };
        try fixture.sharp.writeRegion(0, 0, 0, 32, 16, &input, 32 * 4);
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        errdefer encoder.deinit();
        const sources = [_]gpu.Backend.TextureBinding{ fixture.sharp.binding(), half.binding(), quarter.binding() };
        const targets = [_]gpu.Backend.TextureBinding{ half.binding(), quarter.binding(), fixture.output.binding() };
        const uniforms = [_]blur.GaussianAreaUniforms{
            .{ .source_size = .{ 32, 16 }, .output_size = .{ 16, 8 } },
            .{ .source_size = .{ 16, 8 }, .output_size = .{ 8, 4 }, .input_gamma = 1 },
        };
        for (0..3) |i| {
            var view = targets[i].createView();
            defer view.destroy();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
            pass.setPipeline(&pipelines[if (i == 2) @as(usize, 1) else 0]);
            if (i < 2) pass.setFragmentBytes(0, std.mem.asBytes(&uniforms[i]));
            pass.setFragmentTextureBinding(0, sources[i]);
            pass.setFragmentSampler(0, &fixture.sampler);
            pass.setViewport(0, 0, @floatFromInt(targets[i].width), @floatFromInt(targets[i].height), 0, 1);
            pass.draw(3, 1, 0, 0);
            pass.end();
        }
        var command = try encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        var pixels: [32 * 16 * 4]u8 = undefined;
        try fixture.output.readBgra8(32, 16, &pixels, 32 * 4);
        for (0..8) |i| {
            const expected = 128 + offsets[i] * @as(f32, if (phase_index == 0) 60.5 else 25);
            try std.testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(pixels[(8 * 32 + 8 + i) * 4])), 1.0);
        }
    }
}

extern fn metal_texture_read_bgra8(texture: *anyopaque, out: [*]u8, bytes_per_row: c_uint, width: c_uint, height: c_uint) c_int;

fn readRaw(texture: *const gpu.Backend.Texture, width: u32, height: u32, out: []u8) !void {
    if (metal_texture_read_bgra8(@ptrCast(texture.raw), out.ptr, width * 8, width, height) == 0) return error.TextureReadFailed;
}

test "metal bank batch matches the render passes bit for bit" {
    // backdrop_blur bank batch replaces the native bank render passes with
    // fragment-write draws in render passes without attachments, several
    // targets of different sizes per pass; their output must be the same
    // bytes, including the clear/keep outside the region.
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
    const device = &dq.device;
    var module = try gpu.Backend.ShaderModule.initFromSource(device, @embedFile("shaders/blur.metal"));
    defer module.deinit();
    var vertex = try module.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var render: [4]gpu.Backend.RenderPipeline = undefined;
    for ([_][]const u8{ "gaussian_filter_gamma", "gaussian_downsample_gamma", "gaussian_filter_gamma_bank", "gaussian_downsample_gamma_bank" }, 0..) |name, i| {
        var fragment = try module.getFunction(name);
        defer fragment.deinit();
        render[i] = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex,
            .fragment_function = &fragment,
            .color_attachment_formats = if (i >= 2) &.{} else &.{.rgba16_float},
            .blend_state = null,
        });
    }
    defer for (&render) |*p| p.deinit();
    var sampler = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
    defer sampler.destroy();

    var prng = std.Random.DefaultPrng.init(0x6a55);
    const random = prng.random();
    // Quarter/eighth/ambient grids of real windows, odd sizes, long thin ones.
    const sizes = [_][2]u32{ .{ 640, 500 }, .{ 481, 437 }, .{ 17, 15 }, .{ 35, 31 }, .{ 1100, 1000 }, .{ 962, 875 }, .{ 4096, 24 }, .{ 24, 4096 } };
    var mismatched: usize = 0;
    var compared: usize = 0;
    for (sizes, 0..) |size, size_index| {
        const w = size[0];
        const h = size[1];
        // Area sources twice the size (+1: odd cells).
        const sw = w * 2 + @as(u32, @intCast(size_index % 2));
        const sh = h * 2 + @as(u32, @intCast(size_index % 2));
        const float_desc = gpu.TextureDescriptor{ .size = .{ .width = w, .height = h }, .format = .rgba16_float, .memory = .host_upload, .usage = .{ .texture_binding = true, .render_attachment = true, .storage_binding = true } };
        var source = try device.createTexture(a, float_desc);
        defer source.destroy();
        var area_desc = float_desc;
        area_desc.size = .{ .width = sw, .height = sh };
        var area_source = try device.createTexture(a, area_desc);
        defer area_source.destroy();
        var by_render = try device.createTexture(a, float_desc);
        defer by_render.destroy();
        var by_batch = try device.createTexture(a, float_desc);
        defer by_batch.destroy();
        // A second target of another size drawn first in the same pass.
        var other_desc = float_desc;
        other_desc.size = .{ .width = 33, .height = 29 };
        var other = try device.createTexture(a, other_desc);
        defer other.destroy();
        const big = try a.alloc(u16, @as(usize, sw) * sh * 4);
        defer a.free(big);
        for (big) |*v| v.* = @bitCast(@as(f16, @floatCast(random.float(f32) * 1.2)));
        try area_source.writeRegion(0, 0, 0, sw, sh, std.mem.sliceAsBytes(big), sw * 8);
        try source.writeRegion(0, 0, 0, w, h, std.mem.sliceAsBytes(big[0 .. @as(usize, w) * h * 4]), w * 8);
        const prefill = try a.alloc(u16, @as(usize, w) * h * 4);
        defer a.free(prefill);
        for (prefill, 0..) |*v, i| v.* = @bitCast(@as(f16, @floatFromInt(i % 7)));
        for (0..10) |case| {
            const area = case >= 8;
            const sigmas = [_]f32{ 0.6, 2.0, 5.2, 12.0 };
            const sigma = sigmas[(case / 2) % 4];
            const region: ?blur.PixelRegion = switch (case % 3) {
                0 => null,
                1 => .{ .x0 = @intCast(w / 7), .y0 = @intCast(h / 5), .x1 = @intCast(w - w / 9), .y1 = @intCast(h - h / 11) },
                else => .{ .x0 = -3, .y0 = @intCast(h / 3), .x1 = @intCast(w + 5), .y1 = @intCast(h / 3 + 2) },
            };
            const load_op: gpu.LoadOp = if (area and case == 9) .load else .clear;
            const gauss = blur.gaussianUniforms(sigma, w, h, case % 2 == 1, blur.validUv(0, 0, w, h, w, h));
            const au = blur.GaussianAreaUniforms{ .source_size = .{ @floatFromInt(sw), @floatFromInt(sh) }, .output_size = .{ @floatFromInt(w), @floatFromInt(h) }, .input_gamma = if (case == 8) 1 else 0 };
            try by_render.writeRegion(0, 0, 0, w, h, std.mem.sliceAsBytes(prefill), w * 8);
            try by_batch.writeRegion(0, 0, 0, w, h, std.mem.sliceAsBytes(prefill), w * 8);
            var ce = try gpu.Backend.CommandEncoder.init(&dq.queue);
            errdefer ce.deinit();
            {
                var view = by_render.binding().createView();
                defer view.destroy();
                var pass = try ce.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = load_op, .store_op = .store }} });
                pass.setPipeline(&render[if (area) 1 else 0]);
                if (area) pass.setFragmentBytes(0, std.mem.asBytes(&au)) else pass.setFragmentBytes(0, std.mem.asBytes(&gauss));
                pass.setFragmentTextureBinding(0, if (area) area_source.binding() else source.binding());
                pass.setFragmentSampler(0, &sampler);
                pass.setViewport(0, 0, @floatFromInt(w), @floatFromInt(h), 0, 1);
                if (region) |r| if (r.scissor(w, h)) |sc| pass.setScissorRect(sc[0], sc[1], sc[2], sc[3]);
                pass.draw(3, 1, 0, 0);
                pass.end();
            }
            {
                var pass = try ce.beginAttachmentlessRenderPass(@max(w, 2048), @max(h, 2048));
                pass.setFragmentSampler(0, &sampler);
                const other_gauss = blur.gaussianUniforms(3, 33, 29, false, blur.validUv(0, 0, 33, 29, 33, 29));
                const other_region = blur.bankRegion(null, 33, 29, .clear);
                pass.setPipeline(&render[2]);
                pass.setFragmentBytes(0, std.mem.asBytes(&other_gauss));
                pass.setFragmentBytes(1, std.mem.asBytes(&other_region));
                pass.setFragmentTextureBinding(0, area_source.binding());
                pass.setFragmentTextureBinding(1, other.binding());
                pass.setViewport(0, 0, 33, 29, 0, 1);
                pass.setScissorRect(0, 0, 33, 29);
                pass.draw(3, 1, 0, 0);
                const r = blur.bankRegion(region, w, h, load_op);
                pass.setPipeline(&render[if (area) 3 else 2]);
                if (area) pass.setFragmentBytes(0, std.mem.asBytes(&au)) else pass.setFragmentBytes(0, std.mem.asBytes(&gauss));
                pass.setFragmentBytes(1, std.mem.asBytes(&r));
                pass.setFragmentTextureBinding(0, if (area) area_source.binding() else source.binding());
                pass.setFragmentTextureBinding(1, by_batch.binding());
                pass.setViewport(0, 0, @floatFromInt(w), @floatFromInt(h), 0, 1);
                pass.setScissorRect(0, 0, w, h);
                pass.draw(3, 1, 0, 0);
                pass.end();
            }
            var cb = try ce.finish();
            defer cb.deinit();
            cb.submit();
            cb.waitUntilCompleted();
            const x = try a.alloc(u8, @as(usize, w) * h * 8);
            defer a.free(x);
            const y = try a.alloc(u8, x.len);
            defer a.free(y);
            try readRaw(&by_render, w, h, x);
            try readRaw(&by_batch, w, h, y);
            var case_bad: usize = 0;
            for (x, y) |p, q| case_bad += @intFromBool(p != q);
            if (case_bad > 0) std.debug.print("bank batch mismatch {d}x{d} case={d}: {d} bytes\n", .{ w, h, case, case_bad });
            mismatched += case_bad;
            compared += x.len;
        }
    }
    try std.testing.expect(compared > 0);
    try std.testing.expectEqual(@as(usize, 0), mismatched);
}

test "metal bank batch: Kawase and copy draws match their render passes bit for bit" {
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
    const device = &dq.device;
    var module = try gpu.Backend.ShaderModule.initFromSource(device, @embedFile("shaders/blur.metal"));
    defer module.deinit();
    var vertex = try module.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var pipelines: [5]gpu.Backend.RenderPipeline = undefined;
    for ([_][]const u8{ "kawase_downsample", "kawase_upsample", "kawase_downsample_bank", "kawase_upsample_bank", "copy_bank" }, 0..) |name, i| {
        var fragment = try module.getFunction(name);
        defer fragment.deinit();
        pipelines[i] = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex,
            .fragment_function = &fragment,
            .color_attachment_formats = if (i >= 2) &.{} else &.{gpu.color_format},
            .blend_state = null,
        });
    }
    defer for (&pipelines) |*p| p.deinit();
    var sampler = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
    defer sampler.destroy();
    var prng = std.Random.DefaultPrng.init(0x1c0a);
    const random = prng.random();
    var mismatched: usize = 0;
    var compared: usize = 0;
    for ([_][2]u32{ .{ 576, 192 }, .{ 1024, 448 }, .{ 130, 70 }, .{ 2048, 320 }, .{ 64, 64 } }) |size| {
        const w = size[0];
        const h = size[1];
        const desc = gpu.TextureDescriptor{ .size = .{ .width = w, .height = h }, .format = gpu.color_format, .memory = .host_upload, .usage = .{ .texture_binding = true, .render_attachment = true, .storage_binding = true, .copy_src = true, .copy_dst = true } };
        var source = try device.createTexture(a, desc);
        defer source.destroy();
        var by_render = try device.createTexture(a, desc);
        defer by_render.destroy();
        var by_batch = try device.createTexture(a, desc);
        defer by_batch.destroy();
        const bytes = try a.alloc(u8, @as(usize, w) * h * 4);
        defer a.free(bytes);
        random.bytes(bytes);
        try source.writeRegion(0, 0, 0, w, h, bytes, w * 4);
        const prefill = try a.alloc(u8, bytes.len);
        defer a.free(prefill);
        for (prefill, 0..) |*v, i| v.* = @truncate(i * 13);
        for (0..6) |case| {
            // Kawase into a half-size target region of the same texture size
            // (the pass covers the whole target), and copies of a sub-rect.
            const kawase = case < 2;
            const tw = if (kawase) w / 2 else w;
            const th = if (kawase) h / 2 else h;
            const valid = blur.validUv(3, 5, w - 20, h - 14, w, h);
            const ku = blur.KawaseUniforms{ .texel_size = .{ 1.0 / @as(f32, @floatFromInt(w)), 1.0 / @as(f32, @floatFromInt(h)) }, .offset_scale = 1.5 + @as(f32, @floatFromInt(case)) * 0.7, .valid_uv = valid };
            const sx: u32 = 7;
            const sy: u32 = 3;
            const cw = w / 2;
            const ch = h / 3;
            const dx: u32 = if (case == 5) 0 else 11;
            const dy: u32 = if (case == 5) 0 else 2;
            const clear = case == 2 or case == 4;
            try by_render.writeRegion(0, 0, 0, w, h, prefill, w * 4);
            try by_batch.writeRegion(0, 0, 0, w, h, prefill, w * 4);
            var ce = try gpu.Backend.CommandEncoder.init(&dq.queue);
            errdefer ce.deinit();
            if (kawase) {
                var view = by_render.binding().createView();
                defer view.destroy();
                var pass = try ce.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }} });
                pass.setPipeline(&pipelines[case]);
                pass.setFragmentBytes(0, std.mem.asBytes(&ku));
                pass.setFragmentTextureBinding(0, source.binding());
                pass.setFragmentSampler(0, &sampler);
                pass.setViewport(0, 0, @floatFromInt(tw), @floatFromInt(th), 0, 1);
                pass.draw(3, 1, 0, 0);
                pass.end();
            } else {
                try gpu.copyTextureRegion(&ce, source.binding(), sx, sy, cw, ch, by_render.binding(), dx, dy, clear);
            }
            {
                var pass = try ce.beginAttachmentlessRenderPass(4096, 4096);
                pass.setFragmentSampler(0, &sampler);
                if (kawase) {
                    pass.setPipeline(&pipelines[case + 2]);
                    pass.setFragmentBytes(0, std.mem.asBytes(&ku));
                } else {
                    const copy = blur.BankCopy{ .rect = .{ dx, dy, dx + cw, dy + ch }, .offset = .{ @as(i32, @intCast(sx)) - @as(i32, @intCast(dx)), @as(i32, @intCast(sy)) - @as(i32, @intCast(dy)) }, .clear = @intFromBool(clear) };
                    pass.setPipeline(&pipelines[4]);
                    pass.setFragmentBytes(0, std.mem.asBytes(&copy));
                }
                pass.setFragmentTextureBinding(0, source.binding());
                pass.setFragmentTextureBinding(1, by_batch.binding());
                pass.setViewport(0, 0, @floatFromInt(tw), @floatFromInt(th), 0, 1);
                pass.setScissorRect(0, 0, tw, th);
                pass.draw(3, 1, 0, 0);
                pass.end();
            }
            var cb = try ce.finish();
            defer cb.deinit();
            cb.submit();
            cb.waitUntilCompleted();
            const x = try a.alloc(u8, bytes.len);
            defer a.free(x);
            const y = try a.alloc(u8, bytes.len);
            defer a.free(y);
            try by_render.readBgra8(w, h, x, w * 4);
            try by_batch.readBgra8(w, h, y, w * 4);
            // Kawase passes write their whole (tw x th) viewport; compare it.
            var case_bad: usize = 0;
            for (0..th) |row| for (0..tw * 4) |col| {
                const i = row * w * 4 + col;
                case_bad += @intFromBool(x[i] != y[i]);
            };
            if (case_bad > 0) std.debug.print("bank kawase/copy mismatch {d}x{d} case={d}: {d} bytes\n", .{ w, h, case, case_bad });
            mismatched += case_bad;
            compared += @as(usize, tw) * th * 4;
        }
    }
    try std.testing.expect(compared > 0);
    try std.testing.expectEqual(@as(usize, 0), mismatched);
}
