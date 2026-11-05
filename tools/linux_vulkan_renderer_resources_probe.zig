//! Renderer-owned resource lifetime and descriptor tests on the real driver.
const std = @import("std");
const gpu = @import("vulkan_device");
const is_gl = gpu.backend_kind == .opengl;
const backend_name = if (is_gl) "opengl" else "vulkan";
const marker = if (is_gl) "OPENGL" else "VULKAN";
const source_token = if (is_gl) "zenit-opengl:image" else "zenit-vulkan:image";
const vk = if (is_gl) struct {
    const native = gpu.opengl_native;
    pub const Device = native.Device;
    pub const Diagnostic = native.Diagnostic;
    pub const shaders = native.shaders;
    pub const renderer_resources = native.renderer_resources;
    pub const renderer_device = gpu.Backend;
    pub const renderer_pipeline = native.renderer_pipeline;
} else gpu.vulkan_native;
const r = vk.renderer_resources;
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    if (comptime r.gpu.backend_kind != .vulkan and !is_gl) @compileError("probe requires a Linux GPU backend");
    var window: if (is_gl) @import("linux_wayland").Window else void = if (is_gl)
        try @import("linux_wayland").Window.init("Zenit GL resource contracts", 64, 48)
    else {};
    defer if (is_gl) window.deinit();
    const args = try init.minimal.args.toSlice(a);
    var options: vk.Device.Options = .{ .require_validation = true };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--allow-software")) options.allow_software = true else return error.InvalidArgument;
    }
    if (is_gl) {
        const surface = try window.nativeSurface();
        options.wayland_display = surface.display;
        options.wayland_surface = surface.surface;
    }
    var diag: vk.Diagnostic = .{};
    var instance = try vk.renderer_device.Instance.initWithOptions(a, .{}, options);
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer adapters[0].deinit();
    if (adapters[0].requestDevice(a, .{ .required_features = .{ .timestamp_query = true } })) |_| return error.UnsupportedFeatureAccepted else |err| {
        if (err != error.UnsupportedFeatures) return err;
    }
    var excessive = std.mem.zeroes(r.gpu.Limits);
    excessive.max_texture_dimension_2d = std.math.maxInt(u32);
    if (adapters[0].requestDevice(a, .{ .required_limits = excessive })) |_| return error.UnsupportedLimitsAccepted else |err| {
        if (err != error.UnsupportedLimits) return err;
    }
    var requested = try adapters[0].requestDevice(a, .{});
    defer requested.queue.deinit();
    var device = requested.device;
    defer device.deinit();
    const context = try device.liveContext();
    if (adapters[0].native_device.handle != null) return error.ContextDidNotMoveDevice;
    if (adapters[0].requestDevice(a, .{})) |_| return error.DuplicateDeviceRequestAccepted else |err| {
        if (err != error.DeviceAlreadyRequested) return err;
    }
    {
        var buffer = try context.createBuffer(a, .{ .size = 513, .usage = .{ .vertex = true, .map_write = true } });
        defer buffer.destroy();
        var retained = buffer.retained();
        defer retained.destroy();
        const mapped = try buffer.getMappedRange(17, 97);
        for (mapped, 0..) |*byte, i| byte.* = @intCast((i * 7 + 3) % 256);
        buffer.destroy();
        const inner = try retained.native();
        var actual: [97]u8 = undefined;
        try inner.read(17, &actual, &diag);
        for (actual, 0..) |byte, i| if (byte != (i * 7 + 3) % 256) return error.RendererBufferMismatch;
        if (retained.getMappedRange(500, 14)) |_| return error.BufferBoundsAccepted else |err| {
            if (err != error.OutOfBounds) return err;
        }
        if (context.deinit()) |_| return error.LiveContextDestroyed else |err| {
            if (err != error.ResourcesAlive) return err;
        }
    }
    {
        var texture = try context.createTexture(a, .{ .size = .{ .width = 7, .height = 5 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true, .copy_src = true } });
        defer texture.destroy();
        var pixels: [7 * 5 * 4]u8 = @splat(17);
        try texture.readBgra8(7, 5, &pixels, 28);
        for (pixels) |byte| if (byte != 0) return error.HostTextureNotInitialized;
        @memset(&pixels, 123);
        try texture.writeRegion(0, 0, 0, 7, 5, &pixels, 28);
        const binding = texture.binding();
        var view = binding.createView();
        defer view.destroy();
        texture.destroy();
        var retained = try view.binding().retainedTexture();
        defer retained.destroy();
        if (!retained.binding().eql(binding)) return error.TextureIdentityMismatch;
        @memset(&pixels, 0);
        try retained.readBgra8(7, 5, &pixels, 28);
        for (pixels) |byte| if (byte != 123) return error.RendererTextureMismatch;
    }
    {
        var texture = try context.createTexture(a, .{ .size = .{ .width = 3, .height = 2 }, .format = .rgba16_float, .memory = .host_upload, .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true } });
        defer texture.destroy();
        const texels: [6][4]f16 = @splat(.{ 2, -0.5, 0.125, 1 });
        try texture.writeRegion(0, 0, 0, 3, 2, std.mem.asBytes(&texels), 24);
        var actual: [24]f16 = undefined;
        var diagnostic: vk.Diagnostic = .{};
        const native = try texture.native();
        try native.readRegion(0, 0, 3, 2, std.mem.asBytes(&actual), 24, &diagnostic);
        if (!std.mem.eql(u8, std.mem.asBytes(&texels), std.mem.asBytes(&actual))) return error.HalfFloatTextureMismatch;
    }
    if (context.createTexture(a, .{ .size = .{ .width = 1, .height = 1, .depth = 2 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true } })) |_| return error.TextureLayerAccepted else |err| {
        if (err != error.UnsupportedTextureDescriptor) return err;
    }
    var mixed_sampler = try context.createSampler(a, .{ .address_mode_u = .mirror_repeat, .address_mode_v = .clamp_to_border, .address_mode_w = .repeat, .mag_filter = .linear, .min_filter = .nearest, .mipmap_filter = .linear, .lod_min_clamp = 0.25, .lod_max_clamp = 8 });
    mixed_sampler.destroy();
    if (context.createSampler(a, .{ .compare = .less })) |_| return error.UnsupportedSamplerAccepted else |err| {
        if (err != error.UnsupportedSamplerDescriptor) return err;
    }
    {
        var module = try vk.shaders.ShaderModule.initFromSource(&context.device, source_token);
        defer module.deinit();
        var vertex = try module.getFunction("image_vertex_main");
        defer vertex.deinit();
        var fragment = try module.getFunction("image_fragment_main");
        defer fragment.deinit();
        var pipeline = try vk.renderer_pipeline.createRenderPipeline(context, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm}, .blend_state = .{ .destination_rgb = .one_minus_src_alpha, .destination_alpha = .one_minus_src_alpha } });
        defer pipeline.deinit();
        var retained = pipeline.retained();
        defer retained.deinit();
        pipeline.deinit();
        const owner = retained.owner orelse return error.PipelineNotRetained;
        if (owner.bindings.len != 4) return error.PipelineBindingsMismatch;
        var uniforms_checked = false;
        var storage_checked = false;
        for (owner.bindings) |binding| {
            if (binding.group == 0 and binding.binding == 0) {
                if (binding.kind != 0 or binding.min_size != 352 or binding.stages != 3) return error.UniformReflectionMismatch;
                uniforms_checked = true;
            }
            if (binding.group == 0 and binding.binding == 1) {
                if (binding.kind != 2 or binding.stride != 128 or binding.stages != 1) return error.StorageReflectionMismatch;
                storage_checked = true;
            }
        }
        if (!uniforms_checked or !storage_checked) return error.MissingPipelineReflection;
        if (context.deinit()) |_| return error.LivePipelineContextDestroyed else |err| {
            if (err != error.ResourcesAlive) return err;
        }
        var other = context.*;
        if (vk.renderer_pipeline.createRenderPipeline(&other, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} })) |_| return error.ForeignShaderDeviceAccepted else |err| {
            if (err != error.InvalidDescriptor) return err;
        }
        if (vk.renderer_pipeline.createRenderPipeline(context, .{ .vertex_function = &fragment, .fragment_function = &vertex, .color_attachment_formats = &.{.bgra8_unorm} })) |_| return error.InvalidPipelineStageAccepted else |err| {
            if (err != error.InvalidShaderStage) return err;
        }
        if (vk.renderer_pipeline.createRenderPipeline(context, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm}, .sample_count = 4 })) |_| return error.UnsupportedSamplesAccepted else |err| {
            if (err != error.UnsupportedRenderPipeline) return err;
        }
    }
    if (comptime is_gl) {
        var left: [128]u8 = undefined;
        var right: [128]u8 = undefined;
        for (0..97) |len| for (0..8) |offset| {
            const lhs = left[offset..][0..len];
            const rhs = right[7 - offset ..][0..len];
            for (lhs, rhs, 0..) |*x, *y, i| {
                x.* = @intCast(i);
                y.* = @intCast(i);
            }
            if (!gpu.opengl_native.snapshotBytesEqual(lhs, rhs)) return error.SnapshotComparisonMismatch;
            if (len > 0) for ([_]usize{ 0, len / 2, len - 1 }) |i| {
                rhs[i] ^= 1;
                if (gpu.opengl_native.snapshotBytesEqual(lhs, rhs)) return error.SnapshotMutationMissed;
                rhs[i] ^= 1;
            };
        };
        std.debug.print("OPENGL_SNAPSHOT_COMPARISON PASS: unaligned_offsets=8 lengths=97 changed_first_middle_last=true\n", .{});
    }
    try verifyCommands(&device, a);
    try verifyImageRenderer(&device, a);
    const software = context.device.info.isSoftware();
    try device.deinitChecked();
    try device.deinitChecked();
    if (device.createBuffer(a, .{ .size = 16, .usage = .{ .vertex = true } })) |_| return error.DestroyedDeviceAccepted else |err| {
        if (err != error.DeviceDestroyed) return err;
    }
    std.debug.print(marker ++ "_RENDERER_RESOURCES PASS: mode={s} buffer_mapping=true texture_view_retention=true host_texture_zeroed=true descriptor_rejection=true context_ownership=true pipeline_retention=true adapter_negotiation=true uniform_range=352 storage_stride=128 validation_errors=0\n", .{if (software) "software-functional" else "gpu"});
}

const Uniforms = extern struct {
    viewport: [2]f32 = .{ 64, 48 },
    scale: f32 = 1,
    clip_kind: u32 = 0,
    clip_rect: [4]f32 = @splat(0),
    radii: [4]f32 = @splat(0),
    fill: u32 = 0,
    point_count: u32 = 0,
    contour_count: u32 = 0,
    clip_pad: u32 = 0,
    endpoints: [2][4]u32 = @splat(@splat(0)),
    points: [16][4]f32 = @splat(@splat(0)),
};
const Instance = extern struct {
    rect: [4]f32 = .{ 8, 6, 32, 24 },
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    tint: [4]f32 = @splat(1),
    linear: [4]f32 = .{ 1, 0, 0, 1 },
    radii: [4]f32 = @splat(0),
    translation: [2]f32 = @splat(0),
    opacity: f32 = 1,
    premultiplied: f32 = 0,
    sampling: [4]f32 = @splat(0),
    clip: [4]f32 = .{ 0, 0, -1, -1 },
};
comptime {
    if (@sizeOf(Uniforms) != 352 or @sizeOf(Instance) != 128) @compileError("image CPU ABI mismatch");
}
fn verifyCommands(device: *vk.renderer_device.Device, a: std.mem.Allocator) !void {
    const commands = vk.renderer_device;
    var queue = try device.createQueue();
    defer queue.deinit();
    var module = try vk.renderer_device.ShaderModule.initFromSource(device, source_token);
    defer module.deinit();
    var vertex = try module.getFunction("image_vertex_main");
    defer vertex.deinit();
    var fragment = try module.getFunction("image_fragment_main");
    defer fragment.deinit();
    var pipeline = try vk.renderer_device.createRenderPipeline(device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer pipeline.deinit();
    var uniforms = try device.createBuffer(a, .{ .size = 512, .usage = .{ .vertex = true, .map_write = true } });
    defer uniforms.destroy();
    const cpu_uniforms: Uniforms = .{};
    @memcpy(try uniforms.getMappedRange(3, @sizeOf(Uniforms)), std.mem.asBytes(&cpu_uniforms));
    var instances = try device.createBuffer(a, .{ .size = 512, .usage = .{ .vertex = true, .map_write = true } });
    defer instances.destroy();
    const instance: Instance = .{};
    const mapped_instance = try instances.getMappedRange(7, 2 * @sizeOf(Instance));
    @memcpy(mapped_instance[0..@sizeOf(Instance)], std.mem.asBytes(&instance));
    var source = try device.createTexture(a, .{ .size = .{ .width = 2, .height = 2 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    defer source.destroy();
    const texels = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 255, 255, 255 };
    try source.writeRegion(0, 0, 0, 2, 2, &texels, 8);
    var sampler = try device.createSampler(a, .{});
    defer sampler.destroy();
    var target = try device.createTexture(a, .{ .size = .{ .width = 64, .height = 48 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var encoder = try commands.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &[_]r.gpu.RenderPassColorAttachment{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 } }} });
    var stale = pass;
    pass.setPipeline(&pipeline);
    pass.setVertexBuffer(0, &uniforms, 3);
    pass.setFragmentBuffer(0, &uniforms, 3);
    pass.setVertexBuffer(1, &instances, 7);
    pass.setFragmentTexture(0, &source);
    pass.setFragmentSampler(0, &sampler);
    pass.draw(6, 1, 0, 0);
    // Reuse unchanged bindings, then mutate the same held mapping without
    // another map call. Each draw must retain its own recorded contents.
    pass.draw(6, 1, 0, 0);
    const moved_instance: Instance = .{ .rect = .{ 40, 6, 16, 24 } };
    @memcpy(mapped_instance[@sizeOf(Instance)..], std.mem.asBytes(&moved_instance));
    pass.draw(6, 1, 0, 1);
    @memcpy(mapped_instance[0..@sizeOf(Instance)], std.mem.asBytes(&moved_instance));
    pass.draw(6, 1, 0, 0);
    pass.end();
    if (stale.isActive()) return error.StalePassActive;
    // Recorded data and resource holds survive caller mutation/destruction.
    @memset(try instances.getMappedRange(0, 256), 0);
    uniforms.destroy();
    instances.destroy();
    pipeline.deinit();
    sampler.destroy();
    source.destroy();
    view.destroy();
    var command = try encoder.finish();
    defer command.deinit();
    var sync = commands.FrameSync.init(1);
    defer sync.deinit();
    try sync.waitForNextFrame();
    try sync.signalOnCompletionChecked(&command);
    if (sync.drainChecked(1)) |_| return error.UnsubmittedFrameDrained else |err| {
        if (err != error.CommandNotSubmitted) return err;
    }
    if (sync.waitForNextFrame()) |_| return error.UnsubmittedFrameSlotReused else |err| {
        if (err != error.CommandNotSubmitted) return err;
    }
    if (stale.isActive()) return error.FinishedPassActive;
    if (command.isCompleted()) return error.UnsubmittedCommandCompleted;
    if (command.gpuElapsedMicros() != null) return error.UnsubmittedGpuTimingPublished;
    try command.submitChecked();
    if (!command.isCompleted()) return error.SubmittedCommandIncomplete;
    if (comptime is_gl) {
        const elapsed = command.gpuElapsedMicros() orelse return error.GpuTimingUnavailable;
        var retained_command = command.retained();
        defer retained_command.deinit();
        if (retained_command.gpuElapsedMicros() != elapsed) return error.RetainedGpuTimingMismatch;
        std.debug.print("OPENGL_GPU_TIMING PASS: gpu_us={d} source=GL_TIMESTAMP\n", .{elapsed});
    }
    try sync.collectChecked();
    if (sync.pending != 0) return error.CompletedFrameNotCollected;
    try sync.waitForNextFrame();
    try sync.signalChecked();
    if (sync.signalChecked()) |_| return error.UnbalancedFrameSignalAccepted else |err| {
        if (err != error.UnbalancedFrameSync) return err;
    }
    try sync.drainChecked(1);
    if (command.submitChecked()) |_| return error.DuplicateSubmissionAccepted else |err| {
        if (err != error.CommandAlreadySubmitted) return err;
    }
    var pixels: [64 * 48 * 4]u8 = undefined;
    try target.readBgra8(64, 48, &pixels, 64 * 4);
    for (0..48) |y| for (0..64) |x| {
        const expected: []const u8 = if (x >= 8 and x < 40 and y >= 6 and y < 30) texels[(if (y >= 18) @as(usize, 2) else 0) * 4 + (if (x >= 24) @as(usize, 1) else 0) * 4 ..][0..4] else if (x >= 40 and x < 56 and y >= 6 and y < 30) texels[(if (y >= 18) @as(usize, 2) else 0) * 4 + (if (x >= 48) @as(usize, 1) else 0) * 4 ..][0..4] else &.{ 191, 128, 64, 255 };
        if (!std.mem.eql(u8, pixels[(y * 64 + x) * 4 ..][0..4], expected)) {
            std.log.err("command pixel mismatch x={d} y={d} actual={any} expected={any}", .{ x, y, pixels[(y * 64 + x) * 4 ..][0..4].*, expected[0..4].* });
            return error.RendererCommandPixelMismatch;
        }
    };
    if (device.deinitChecked()) |_| return error.CommandContextDestroyed else |err| {
        if (err != error.ResourcesAlive) return err;
    }
    std.debug.print(marker ++ "_RENDERER_COMMANDS PASS: pixels=3072 exact=true unaligned_uniform_offset=3 unaligned_storage_offset=7 buffer_snapshot=true held_mapping_mutation=true repeated_binding=true first_instance=true appended_range=true resource_retention=true device_facade=true frame_admission=true stale_pass_rejected=true duplicate_submit_rejected=true\n", .{});
}

fn verifyImageRenderer(device: *vk.renderer_device.Device, a: std.mem.Allocator) !void {
    const b = r.gpu.Backend;
    const renderer = try a.create(@import("image_renderer").ImageRenderer);
    defer a.destroy(renderer);
    try renderer.init(a, device);
    defer renderer.deinit();
    const texels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255 };
    const texture_id = try renderer.loadTexture(2, 2, &texels);
    renderer.beginFrame(64, 48, 1);
    try renderer.addImage(texture_id, 8, 6, 32, 24, 0, 1);
    var target = try device.createTexture(a, .{ .size = .{ .width = 64, .height = 48 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var queue = try device.createQueue();
    defer queue.deinit();
    var encoder = try b.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(r.gpu.RenderPassDescriptor{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 } }} });
    try renderer.render(&pass);
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    var pixels: [64 * 48 * 4]u8 = undefined;
    try target.readBgra8(64, 48, &pixels, 64 * 4);
    // Linear filtering blends near the 2x2 source boundaries. Interior quadrant
    // samples are exact; every outside pixel must retain the pass background.
    const samples = [_]struct { x: usize, y: usize, bgra: [4]u8 }{
        .{ .x = 10, .y = 8, .bgra = .{ 0, 0, 255, 255 } },
        .{ .x = 37, .y = 8, .bgra = .{ 0, 255, 0, 255 } },
        .{ .x = 10, .y = 27, .bgra = .{ 255, 0, 0, 255 } },
        .{ .x = 37, .y = 27, .bgra = .{ 0, 255, 255, 255 } },
    };
    for (samples) |sample| if (!std.mem.eql(u8, pixels[(sample.y * 64 + sample.x) * 4 ..][0..4], &sample.bgra)) return error.ImageRendererPixelMismatch;
    for (0..48) |y| for (0..64) |x| {
        if (x >= 8 and x < 40 and y >= 6 and y < 30) continue;
        if (!std.mem.eql(u8, pixels[(y * 64 + x) * 4 ..][0..4], &.{ 191, 128, 64, 255 })) return error.ImageRendererBackgroundMismatch;
    };
    var rgba: [64 * 48 * 4]u8 = undefined;
    for (0..64 * 48) |i| {
        rgba[i * 4 ..][0..4].* = .{ pixels[i * 4 + 2], pixels[i * 4 + 1], pixels[i * 4], pixels[i * 4 + 3] };
    }
    if (!b.writePngRgba("/tmp/zenit-" ++ backend_name ++ "-image-renderer.png", &rgba, 64, 48, 64 * 4)) return error.PngCaptureFailed;
    if (b.writePngRgba("/tmp/zenit-" ++ backend_name ++ "-invalid.png", &rgba, 64, 48, 1)) return error.InvalidPngStrideAccepted;
    std.debug.print(marker ++ "_IMAGE_RENDERER PASS: backend=" ++ backend_name ++ " production_renderer=true quadrant_samples=4 background_pixels=2304 png_capture=true\n", .{});
}
