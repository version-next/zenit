//! Create production UI shader pipelines on the actual Vulkan driver.
const std = @import("std");
const vk = @import("vulkan_device").vulkan_native;
const shaders = @import("vulkan_ui_shaders");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts: vk.Device.Options = .{ .require_validation = true };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--allow-software")) opts.allow_software = true else return error.InvalidArgument;
    }
    var diag: vk.Diagnostic = .{};
    var device = try vk.Device.init(opts, &diag);
    defer _ = device.deinit() catch {};
    var pipelines: usize = 0;
    for (shaders.entries) |fragment| {
        if (fragment.stage != .fragment) continue;
        var name: [128]u8 = undefined;
        const vertex_name = try std.fmt.bufPrint(&name, "{s}_vertex_main", .{if (std.mem.eql(u8, fragment.program, "blur")) "kawase" else if (std.mem.eql(u8, fragment.program, "composite")) "blend" else if (std.mem.eql(u8, fragment.program, "sdf_primitives")) "sdf" else fragment.program});
        try createPair(&device, findEntry(vertex_name), fragment, &diag);
        pipelines += 1;
    }
    // Additional SDF vertex paths used by the renderer. Region viewports are a
    // Windows-only optimization, not part of the Vulkan renderer contract.
    for ([_][]const u8{ "sdf_tiled_rect_vertex_main", "sdf_shadow_ring_vertex_main", "sdf_dual_shadow_vertex_main" }) |name| {
        const fragment = findEntry(if (std.mem.eql(u8, name, "sdf_shadow_ring_vertex_main")) "sdf_shadow_ring_fragment_main" else if (std.mem.eql(u8, name, "sdf_dual_shadow_vertex_main")) "sdf_dual_shadow_fragment_main" else "sdf_rect_fragment_main");
        try createPair(&device, findEntry(name), fragment, &diag);
        pipelines += 1;
    }
    try verifyShaderAdapter(&device);
    try verifyConfiguredDraw(&device, &diag);
    try verifyReusableDraw(&device, &diag);
    try verifyImageDraw(&device, &diag);
    const software = device.info.isSoftware();
    const errors = try device.deinit();
    if (errors != 0) return error.VulkanValidationErrors;
    std.debug.print("VULKAN_UI_PIPELINES PASS: mode={s} pipelines={d} compiled_entries={d} image_draw=exact validation_enabled=true validation_errors=0\n", .{ if (software) "software-functional" else "gpu", pipelines, shaders.entries.len });
}

fn findEntry(name: []const u8) shaders.Entry {
    for (shaders.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    @panic("missing manifest shader entry");
}

fn createPair(device: *vk.Device, vertex: shaders.Entry, fragment: shaders.Entry, diag: *vk.Diagnostic) !void {
    var pipeline = try makePair(device, vertex, fragment, diag);
    pipeline.destroy();
}

fn makePair(device: *vk.Device, vertex: shaders.Entry, fragment: shaders.Entry, diag: *vk.Diagnostic) !vk.pipeline.Pipeline {
    var bindings: [64]vk.pipeline.Binding = undefined;
    var count: usize = 0;
    for ([_]shaders.Entry{ vertex, fragment }, 0..) |entry, stage| {
        for (entry.bindings) |binding| {
            if (count == bindings.len) return error.BindingCapacityExceeded;
            bindings[count] = .{ .group = binding.group, .binding = binding.binding, .kind = binding.kind, .stages = if (stage == 0) 1 else 2 };
            count += 1;
        }
    }
    const pipeline = vk.pipeline.Pipeline.init(device, vertex.code, vertex.name, fragment.code, fragment.name, bindings[0..count], .bgra8_unorm, diag) catch |err| {
        std.debug.print("VULKAN_UI_PIPELINE FAIL: vertex={s} fragment={s} error={s} operation={s} vk_result={d}\n", .{ vertex.name, fragment.name, @errorName(err), diag.operationName(), diag.vk_result });
        return err;
    };
    std.debug.print("VULKAN_UI_PIPELINE: vertex={s} fragment={s}\n", .{ vertex.name, fragment.name });
    return pipeline;
}

const ImageUniforms = extern struct {
    viewport: [2]f32 = .{ 64, 48 },
    scale: f32 = 1,
    clip_kind: u32 = 0,
    clip_rect: [4]f32 = @splat(0),
    clip_radii: [4]f32 = @splat(0),
    clip_fill: u32 = 0,
    clip_points: u32 = 0,
    clip_contours: u32 = 0,
    clip_pad: u32 = 0,
    endpoints: [2][4]u32 = @splat(@splat(0)),
    points: [16][4]f32 = @splat(@splat(0)),
};
const ImageInstance = extern struct {
    rect: [4]f32,
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    tint: [4]f32 = .{ 1, 1, 1, 1 },
    linear: [4]f32 = .{ 1, 0, 0, 1 },
    radii: [4]f32 = @splat(0),
    translation: [2]f32 = .{ 0, 0 },
    opacity: f32 = 1,
    premultiplied: f32 = 0,
    sampling: [4]f32 = @splat(0),
    clip: [4]f32 = .{ 0, 0, -1, -1 },
};
comptime {
    if (@sizeOf(ImageUniforms) != 352 or @sizeOf(ImageInstance) != 128) @compileError("image CPU ABI mismatch");
}

fn verifyImageDraw(device: *vk.Device, diag: *vk.Diagnostic) !void {
    var pipeline = try makePair(device, findEntry("image_vertex_main"), findEntry("image_fragment_main"), diag);
    defer pipeline.destroy();
    var target = try device.createTextureResource(64, 48, .bgra8_unorm, diag);
    defer target.destroy();
    var source = try device.createTextureResource(2, 2, .bgra8_unorm, diag);
    defer source.destroy();
    const texels = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 255, 255, 255 };
    try source.writeRegion(0, 0, 2, 2, &texels, 8, diag);
    var sampler = try vk.pipeline.Sampler.init(device, false, false, diag);
    defer sampler.destroy();
    var uniforms = try device.createBufferResource(@sizeOf(ImageUniforms), 64, diag);
    defer uniforms.destroy();
    const cpu_uniforms: ImageUniforms = .{};
    try uniforms.write(0, std.mem.asBytes(&cpu_uniforms), diag);
    var instances = try device.createBufferResource(@sizeOf(ImageInstance) * 2, 128, diag);
    defer instances.destroy();
    const cpu_instances = [_]ImageInstance{ .{ .rect = .{ 1, 1, 4, 4 } }, .{ .rect = .{ 8, 6, 32, 24 } } };
    try instances.write(0, std.mem.asBytes(&cpu_instances), diag);
    const bindings = [_]vk.pipeline.DrawBinding{
        try .buffer(0, 0, false, &uniforms, 0, uniforms.size),
        try .buffer(0, 1, true, &instances, 0, instances.size),
        try .texture(1, 0, &source),
        try .sampler(2, 0, &sampler),
    };
    {
        const vertex_bindings = [_]vk.pipeline.Binding{
            .{ .group = 0, .binding = 0, .kind = 0, .stages = 1 },
            .{ .group = 0, .binding = 1, .kind = 2, .stages = 1 },
        };
        const fragment_bindings = [_]vk.pipeline.Binding{
            .{ .group = 0, .binding = 0, .kind = 0, .stages = 2 },
            .{ .group = 0, .binding = 1, .kind = 2, .stages = 2 },
        };
        var read_pipeline = try vk.pipeline.Pipeline.init(device, &probe_vertex, "main", &resource_fragment, "main", &fragment_bindings, .bgra8_unorm, diag);
        defer read_pipeline.destroy();
        try read_pipeline.draw(&target, bindings[0..2], 0, 3, 0, 1, .{ 0.25, 0.5, 0.75, 1 }, diag);
        var read_pixels: [64 * 48 * 4]u8 = undefined;
        try target.readRegion(0, 0, 64, 48, &read_pixels, 64 * 4, diag);
        if (!std.mem.eql(u8, read_pixels[(24 * 64 + 32) * 4 ..][0..4], &.{ 255, 255, 255, 255 })) return error.FragmentBufferReadMismatch;
        var index_pipeline = try vk.pipeline.Pipeline.init(device, &resource_indices, "main", &resource_values, "main", &vertex_bindings, .bgra8_unorm, diag);
        defer index_pipeline.destroy();
        // Divergent vertex SSBO indexing must agree with constant indexing.
        // This caught the Mesa 26.0.3 / LLVM 22 acceptance driver failure;
        // pipeline creation and validation alone do not detect it.
        for ([_]u32{ 0, 1 }) |first_instance| {
            try index_pipeline.draw(&target, bindings[0..2], 3, 3, first_instance, 1, .{ 0.25, 0.5, 0.75, 1 }, diag);
            var index_pixels: [64 * 48 * 4]u8 = undefined;
            try target.readRegion(0, 0, 64, 48, &index_pixels, 64 * 4, diag);
            const expected = [_]u8{ 128, if (first_instance == 0) 16 else 128, 128, 255 };
            if (!std.mem.eql(u8, index_pixels[(24 * 64 + 32) * 4 ..][0..4], &expected)) {
                std.debug.print("VULKAN_VERTEX_STORAGE FAIL: first_instance={d} actual={any} expected={any}\n", .{ first_instance, index_pixels[(24 * 64 + 32) * 4 ..][0..4], expected });
                return error.VertexStorageIndexMismatch;
            }
        }
        std.debug.print("VULKAN_SHADER_BUFFERS PASS: fragment_uniform=true fragment_storage=true vertex_dynamic_storage=true first_instance=0,1 array_length=true\n", .{});
    }
    // Split the quad into separate submissions: base vertex and base instance
    // must already be absolute in Vulkan, without Windows' extra addition.
    try pipeline.draw(&target, &bindings, 0, 3, 1, 1, .{ 0.25, 0.5, 0.75, 1 }, diag);
    try pipeline.draw(&target, &bindings, 3, 3, 1, 1, null, diag);
    var pixels: [64 * 48 * 4]u8 = undefined;
    try target.readRegion(0, 0, 64, 48, &pixels, 64 * 4, diag);
    for (0..48) |y| for (0..64) |x| {
        const expected: []const u8 = if (x >= 8 and x < 40 and y >= 6 and y < 30)
            texels[(if (y >= 18) @as(usize, 2) else 0) * 4 + (if (x >= 24) @as(usize, 1) else 0) * 4 ..][0..4]
        else
            &.{ 191, 128, 64, 255 };
        if (!std.mem.eql(u8, pixels[(y * 64 + x) * 4 ..][0..4], expected)) {
            std.debug.print("VULKAN_IMAGE FAIL: pixel=({d},{d}) actual={any} expected={any}\n", .{ x, y, pixels[(y * 64 + x) * 4 ..][0..4], expected });
            return error.ImageDrawPixelMismatch;
        }
    };
    if (pipeline.draw(&target, bindings[0..3], 0, 6, 0, 1, null, diag)) |_| return error.MissingBindingAccepted else |err| {
        if (err != error.InvalidDescriptor) return err;
    }
    var feedback = bindings;
    feedback[2] = try .texture(1, 0, &target);
    if (pipeline.draw(&target, &feedback, 0, 6, 0, 1, null, diag)) |_| return error.SampledTargetAccepted else |err| {
        if (err != error.InvalidDescriptor) return err;
    }
    std.debug.print("VULKAN_IMAGE PASS: pixels=3072 exact=true cpu_stride=128 first_vertex=true first_instance=true split_submissions=true\n", .{});
}

const resource_indices align(4) = @embedFile("resource_indices").*;
const resource_values align(4) = @embedFile("resource_values").*;
const resource_fragment align(4) = @embedFile("resource_fragment").*;
const probe_vertex align(4) = @embedFile("probe_vertex").*;
const probe_fragment align(4) = @embedFile("probe_fragment").*;
fn verifyReusableDraw(device: *vk.Device, diag: *vk.Diagnostic) !void {
    var pipeline = try vk.pipeline.Pipeline.init(device, &probe_vertex, "main", &probe_fragment, "main", &.{}, .bgra8_unorm, diag);
    defer pipeline.destroy();
    var target = try device.createTextureResource(64, 48, .bgra8_unorm, diag);
    defer target.destroy();
    try pipeline.draw(&target, &.{}, 0, 3, 0, 1, .{ 0.25, 0.5, 0.75, 1 }, diag);
    var pixels: [64 * 48 * 4]u8 = undefined;
    try target.readRegion(0, 0, 64, 48, &pixels, 64 * 4, diag);
    if (!std.mem.eql(u8, pixels[(24 * 64 + 32) * 4 ..][0..4], &.{ 0, 255, 0, 255 })) return error.ReusableDrawFailed;
    std.debug.print("VULKAN_REUSABLE_DRAW PASS: triangle_center=green\n", .{});
}

fn verifyShaderAdapter(device: *vk.Device) !void {
    const programs = [_][]const u8{ "blur", "composite", "path", "image", "damage_clear", "icon", "text", "sdf_primitives", "glass" };
    for (programs) |program| {
        var token: [64]u8 = undefined;
        var module = try vk.shaders.ShaderModule.initFromSource(device, try std.fmt.bufPrint(&token, "zenit-vulkan:{s}", .{program}));
        defer module.deinit();
        // Source storage is caller-owned and may be overwritten immediately.
        @memset(&token, 0);
        for (shaders.entries) |entry| {
            if (!std.mem.eql(u8, program, entry.program)) continue;
            var function = try module.getFunction(entry.name);
            defer function.deinit();
            if (function.device != device or !std.mem.eql(u8, function.entry.code, entry.code) or function.entry.stage != entry.stage) return error.ShaderAdapterMismatch;
        }
        if (module.getFunction("missing_function")) |_| return error.MissingShaderFunctionAccepted else |err| {
            if (err != error.ShaderFunctionNotFound) return err;
        }
        if (!std.mem.eql(u8, program, "image")) {
            if (module.getFunction("image_fragment_main")) |_| return error.CrossProgramFunctionAccepted else |err| {
                if (err != error.ShaderFunctionNotFound) return err;
            }
        }
    }
    for ([_][]const u8{ "", "zenit-vulkan:", "zenit-vulkan:missing", "zenit-vulkan:image\n", "zenit-vulkan:image trailing", "image" }) |token| {
        if (vk.shaders.ShaderModule.initFromSource(device, token)) |_| return error.InvalidShaderTokenAccepted else |err| {
            if (err != error.InvalidShaderProgram) return err;
        }
    }
    var dead_device = device.*;
    dead_device.handle = null;
    if (vk.shaders.ShaderModule.initFromSource(&dead_device, "zenit-vulkan:image")) |_| return error.DeadShaderDeviceAccepted else |err| {
        if (err != error.InvalidDescriptor) return err;
    }
    std.debug.print("VULKAN_SHADER_ADAPTER PASS: programs=9 functions=43 borrowed_source=false missing_function_rejected=true cross_program_rejected=true\n", .{});
}

const blend_fragment align(4) = @embedFile("blend_fragment").*;
fn verifyConfiguredDraw(device: *vk.Device, diag: *vk.Diagnostic) !void {
    var target = try device.createTextureResource(64, 48, .bgra8_unorm, diag);
    defer target.destroy();
    const states = [_]vk.pipeline.State{
        .{ .blend_enabled = 0 },
        .{},
        .{ .source_rgb = 4 },
    };
    const colors = [_][4]u8{ .{ 191, 128, 64, 128 }, .{ 255, 192, 96, 255 }, .{ 191, 128, 64, 255 } };
    for (states, colors) |state, expected| {
        var pipeline = try vk.pipeline.Pipeline.initConfigured(device, &probe_vertex, "main", &blend_fragment, "main", &.{}, state, diag);
        defer pipeline.destroy();
        try pipeline.drawRegion(&target, &.{}, 0, 3, 0, 1, .{ 0.25, 0.5, 0.75, 1 }, .{ .viewport = .{ 0, 0, 64, 48, 0, 1 }, .scissor = .{ 28, 20, 8, 8 } }, diag);
        var pixel: [4]u8 = undefined;
        try target.readRegion(32, 24, 1, 1, &pixel, 4, diag);
        if (!std.mem.eql(u8, &pixel, &expected)) {
            std.debug.print("VULKAN_BLEND FAIL: actual={any} expected={any}\n", .{ pixel, expected });
            return error.BlendPixelMismatch;
        }
        try target.readRegion(24, 24, 1, 1, &pixel, 4, diag);
        if (!std.mem.eql(u8, &pixel, &.{ 191, 128, 64, 255 })) return error.ScissorPixelMismatch;
        try pipeline.drawRegion(&target, &.{}, 0, 3, 0, 1, .{ 0.25, 0.5, 0.75, 1 }, .{ .viewport = .{ 0, 0, 64, 48, 0, 1 }, .scissor = .{ 0, 0, 0, 0 } }, diag);
        try target.readRegion(32, 24, 1, 1, &pixel, 4, diag);
        if (!std.mem.eql(u8, &pixel, &.{ 191, 128, 64, 255 })) return error.EmptyScissorDrawn;
        if (pipeline.drawRegion(&target, &.{}, 0, 3, 0, 1, null, .{ .viewport = .{ 0, 0, 0, 48, 0, 1 }, .scissor = .{ 0, 0, 64, 48 } }, diag)) |_| return error.InvalidViewportAccepted else |err| {
            if (err != error.InvalidDescriptor) return err;
        }
    }
    if (vk.pipeline.Pipeline.initConfigured(device, &probe_vertex, "main", &blend_fragment, "main", &.{}, .{ .source_rgb = 15 }, diag)) |_| return error.InvalidBlendFactorAccepted else |err| {
        if (err != error.InvalidDescriptor) return err;
    }
    std.debug.print("VULKAN_PIPELINE_STATE PASS: blend_disabled=true premultiplied=true straight_alpha=true scissor=true empty_scissor=true invalid_state_rejected=true\n", .{});
}
