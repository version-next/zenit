//! Real Windows D3D12 resources. Not yet a selectable, complete gpu.Backend.
//! Upload mappings stay valid until destroy; synchronize CPU writes with GPU use.
const std = @import("std");
const gpu = @import("../gpu.zig");
pub const renderer_pipeline = @import("renderer_pipeline.zig");
pub const renderer_shaders = @import("renderer_shaders.zig");
pub const renderer_device = @import("renderer_device.zig");
pub const renderer_commands = @import("renderer_commands.zig");
pub const renderer_resources = @import("renderer_resources.zig");
pub const ShaderModule = @import("shader.zig").ShaderModule;
pub const ShaderFunction = @import("shader.zig").ShaderFunction;
const NativeDevice = opaque {};
const NativeDriverInfo = extern struct { vendor_id: u32, device_id: u32, driver_version: [4]u16, driver_version_known: u32, software: u32 };
extern fn zenit_d12_device_driver_info(*NativeDevice, *NativeDriverInfo) void;
const NativeBuffer = opaque {};
const NativeQueue = opaque {};
const NativeCommands = opaque {};
const NativeTexture = opaque {};
const NativeView = opaque {};
const NativeSampler = opaque {};
const NativePipelineLayout = opaque {};
const NativeComputePipeline = opaque {};
const NativeRenderPass = opaque {};
const NativeColorAttachment = extern struct { texture: *NativeTexture, mip: u32, layer: u32, load_op: u32, store_op: u32, clear: [4]f32, resolve: ?*NativeTexture, resolve_mip: u32, resolve_layer: u32 };
const NativeDepthAttachment = extern struct { texture: *NativeTexture, mip: u32, layer: u32, depth_load: u32, depth_store: u32, stencil_load: u32, stencil_store: u32, clear: f32, stencil_clear: u32, depth_read_only: u32, stencil_read_only: u32 };
const NativeStencilFace = extern struct { compare: u32, fail: u32, depth_fail: u32, pass: u32 };
const NativeDepthState = extern struct { format: u32 = 0, write: u32 = 0, compare: u32 = 8, read_mask: u32 = 255, write_mask: u32 = 255, front: NativeStencilFace = .{ .compare = 8, .fail = 1, .depth_fail = 1, .pass = 1 }, back: NativeStencilFace = .{ .compare = 8, .fail = 1, .depth_fail = 1, .pass = 1 }, bias: i32 = 0, slope: f32 = 0, clamp: f32 = 0 };
const NativeVertexBinding = extern struct { buffer: *NativeBuffer, offset: u64, size: u64, slot: u32 };
const NativeDraw = extern struct { buffers: [*]const NativeVertexBinding, buffer_count: u32, first_vertex: u32, vertices: u32, first_instance: u32, instances: u32, x: u32, y: u32, width: u32, height: u32, blend: [4]f32, stencil_reference: u32, groups: [*]const *NativeBindGroup, group_count: u32, index_buffer: ?*NativeBuffer, index_offset: u64, index_size: u64, index_format: u32, first_index: u32, base_vertex: i32, has_viewport: u32, viewport: [6]f32 };
extern fn zenit_d12_render_pass_begin(*NativeCommands, [*]const NativeColorAttachment, u32, ?*const NativeDepthAttachment, *?*NativeRenderPass) c_int;
extern fn zenit_d12_render_pass_regions(*NativeRenderPass, ?[*]const u32, u32) c_int;
extern fn zenit_d12_render_pass_clear_opaque(*NativeRenderPass, *const [4]f32, u32, u32, u32, u32) c_int;
extern fn zenit_d12_render_pass_draw(*NativeRenderPass, *NativeRenderPipeline, *const NativeDraw) c_int;
extern fn zenit_d12_render_pass_draw_entries(*NativeRenderPass, *NativeRenderPipeline, *const NativeDraw, [*]const NativeBindingEntry, [*]const u32, u32) c_int;
extern fn zenit_d12_render_pass_end(*NativeRenderPass) c_int;
const NativeRenderPipeline = opaque {};
const NativeVertexAttribute = extern struct { location: u32, slot: u32, format: u32, offset: u32, stride: u32, step: u32 };
const NativeColorTarget = extern struct { format: u32, write_mask: u32, blend: u32, color_src: u32, color_dst: u32, color_op: u32, alpha_src: u32, alpha_dst: u32, alpha_op: u32 };
const NativeRenderDescriptor = extern struct { attributes: [*]const NativeVertexAttribute, attribute_count: u32, targets: [*]const NativeColorTarget, target_count: u32, topology: u32, strip_index: u32, front_ccw: u32, cull: u32, fill: u32, depth_clip: u32, sample_mask: u32, samples: u32, alpha_coverage: u32, depth: NativeDepthState };
extern fn zenit_d12_render_pipeline_create(*NativeDevice, *NativePipelineLayout, *anyopaque, *anyopaque, *const NativeRenderDescriptor, *?*NativeRenderPipeline) c_int;
extern fn zenit_d12_render_buffer_stride(*NativeRenderPipeline, u32, u32, *u32) c_int;
extern fn zenit_d12_render_pipeline_retain(*NativeRenderPipeline) void;
extern fn zenit_d12_render_pipeline_layout(*NativeRenderPipeline) *NativePipelineLayout;
extern fn zenit_d12_render_pipeline_release(*NativeRenderPipeline) void;
const NativeBindGroup = opaque {};
pub const NativeBindingEntry = extern struct { binding: u32, array_index: u32, buffer: ?*NativeBuffer, offset: u64, size: u64, stride: u32, view: ?*NativeView, sampler: ?*NativeSampler };
extern fn zenit_d12_bind_group_create(*NativeDevice, *NativePipelineLayout, u32, [*]const NativeBindingEntry, u32, *?*NativeBindGroup) c_int;
extern fn zenit_d12_bind_group_release(*NativeBindGroup) void;
extern fn zenit_d12_commands_dispatch(*NativeCommands, *NativeComputePipeline, [*]const *NativeBindGroup, u32, u32, u32, u32) c_int;
pub const LayoutBinding = extern struct { group: u32, binding: u32, kind: u32, count: u32, visibility: u32, min_size: u64, view_dimension: u32, sample_type: u32, sampler_type: u32, storage_format: u32 };
extern fn zenit_d12_pipeline_layout_create(*NativeDevice, u32, [*]const LayoutBinding, u32, *?*NativePipelineLayout) c_int;
extern fn zenit_d12_pipeline_layout_bindings(*NativePipelineLayout, *u32, *u32) ?[*]const LayoutBinding;
extern fn zenit_d12_pipeline_layout_release(*NativePipelineLayout) void;
extern fn zenit_d12_pipeline_layout_owner(*NativePipelineLayout) *NativeDevice;
extern fn zenit_d12_pipeline_layout_table(*NativePipelineLayout, u32, c_int) u32;
extern fn zenit_d12_compute_pipeline_create(*NativeDevice, *NativePipelineLayout, *anyopaque, *?*NativeComputePipeline) c_int;
extern fn zenit_d12_compute_pipeline_release(*NativeComputePipeline) void;
extern fn zenit_d12_view_create(*NativeTexture, u32, u32, u32, u32, u32, *?*NativeView) c_int;
extern fn zenit_d12_storage_view_create(*NativeTexture, u32, u32, u32, u32, *?*NativeView) c_int;
extern fn zenit_d12_view_release(*NativeView) void;
extern fn zenit_d12_sampler_create(*NativeDevice, u32, u32, u32, u32, f32, f32, u32, u32, *?*NativeSampler) c_int;
extern fn zenit_d12_sampler_retain(*NativeSampler) void;
extern fn zenit_d12_sampler_release(*NativeSampler) void;
extern fn zenit_d12_sample_supported(*NativeDevice, u32, u32) c_int;
extern fn zenit_d12_texture_create(*NativeDevice, u32, u32, u32, u32, u32, u32, u32, u32, *?*NativeTexture) c_int;
extern fn zenit_d12_texture_release(*NativeTexture) void;
extern fn zenit_d12_texture_layout(*NativeTexture, *const TextureRegion, u64, *TextureCopyLayout) c_int;
extern fn zenit_d12_commands_texture_region_copy(*NativeCommands, *NativeTexture, *const TextureRegion, *NativeTexture, *const TextureRegion) c_int;
extern fn zenit_d12_commands_texture_copy(*NativeCommands, *NativeBuffer, u64, u32, *NativeTexture, *const TextureRegion, c_int) c_int;
extern fn zenit_d12_queue_create(*NativeDevice, *?*NativeQueue) c_int;
extern fn zenit_d12_queue_submit(*NativeQueue, *NativeCommands, *u64) c_int;
extern fn zenit_d12_queue_wait(*NativeQueue, u64, u32) c_int;
extern fn zenit_d12_queue_collect(*NativeQueue) c_int;
extern fn zenit_d12_queue_destroy(*NativeQueue, u32) c_int;
extern fn zenit_d12_commands_create(*NativeDevice, *?*NativeCommands) c_int;
extern fn zenit_d12_commands_copy(*NativeCommands, *NativeBuffer, u64, *NativeBuffer, u64, u64) c_int;
extern fn zenit_d12_commands_finish(*NativeCommands) c_int;
extern fn zenit_d12_commands_enable_timestamps(*NativeCommands) c_int;
extern fn zenit_d12_commands_elapsed_micros(*NativeCommands, *u64) c_int;
extern fn zenit_d12_commands_release(*NativeCommands) void;
extern fn zenit_d12_device_retain(*NativeDevice) void;
extern fn zenit_d12_texture_retain(*NativeTexture) void;
extern fn zenit_d12_device_create(c_int, *?*NativeDevice) c_int;
extern fn zenit_d12_device_atomic_workaround(*NativeDevice, c_int) c_int;
extern fn zenit_d12_device_release(*NativeDevice) void;
extern fn zenit_d12_device_vertex_viewport_index(*NativeDevice) c_int;
extern fn zenit_d12_device_is_software(*NativeDevice) c_int;
extern fn zenit_d12_buffer_create(*NativeDevice, u64, u32, *?*NativeBuffer) c_int;
extern fn zenit_d12_texture_ledger_label(*NativeTexture, [*]const u8, usize) void;
extern fn zenit_d12_buffer_ledger_label(*NativeBuffer, [*]const u8, usize) void;
extern fn zenit_d12_buffer_retain(*NativeBuffer) void;
extern fn zenit_d12_buffer_release(*NativeBuffer) void;
extern fn zenit_d12_buffer_mapping(*NativeBuffer) ?[*]u8;

pub const Device = struct {
    raw: *NativeDevice,
    pub fn init(force_software: bool) !Device {
        var raw: ?*NativeDevice = null;
        if (zenit_d12_device_create(@intFromBool(force_software), &raw) != 0) return error.DeviceCreationFailed;
        return .{ .raw = raw.? };
    }
    pub fn retained(self: *const Device) Device {
        zenit_d12_device_retain(self.raw);
        return self.*;
    }
    pub fn driverInfo(self: *const Device) gpu.DriverInfo {
        var info: NativeDriverInfo = undefined;
        zenit_d12_device_driver_info(self.raw, &info);
        return .{ .vendor_id = info.vendor_id, .device_id = info.device_id, .driver_version = if (info.driver_version_known != 0) info.driver_version else null, .software = info.software != 0 };
    }
    pub fn driverBugs(self: *const Device) gpu.DriverBugs {
        return .{ .non_uniform_uav_buffer_array_atomics = gpu.backend_kind == .d3d12 and zenit_d12_device_atomic_workaround(self.raw, 0) == 2 };
    }
    pub fn getFeatures(self: *const Device) gpu.Features {
        _ = self;
        return .{ .non_uniform_uav_buffer_array_atomics = gpu.backend_kind == .d3d12 };
    }
    fn prepareShader(self: *const Device, function: *const ShaderFunction) !ShaderFunction {
        if (gpu.backend_kind == .d3d12 and try function.requiresNonUniformUavBufferArrayAtomics()) {
            switch (zenit_d12_device_atomic_workaround(self.raw, 1)) {
                1 => {},
                2 => return function.withAtomicSwitch(),
                else => return error.UavAtomicSelfTestFailed,
            }
        }
        return function.retained();
    }
    pub fn supportsVertexViewportIndex(self: *const Device) bool {
        return zenit_d12_device_vertex_viewport_index(self.raw) != 0;
    }
    pub fn isSoftware(self: *const Device) bool {
        return zenit_d12_device_is_software(self.raw) != 0;
    }
    pub fn destroy(self: *Device) void {
        zenit_d12_device_release(self.raw);
        self.* = undefined;
    }
    pub fn createQueue(self: *Device) !Queue {
        var raw: ?*NativeQueue = null;
        try nativeStatus(zenit_d12_queue_create(self.raw, &raw), error.QueueCreationFailed);
        return .{ .raw = raw.? };
    }
    pub fn createCommandEncoder(self: *Device) !CommandEncoder {
        var raw: ?*NativeCommands = null;
        try nativeStatus(zenit_d12_commands_create(self.raw, &raw), error.EncoderCreationFailed);
        return .{ .raw = raw.? };
    }
    pub fn createBindGroupLayout(self: *Device, allocator: std.mem.Allocator, desc: gpu.BindGroupLayoutDescriptor) !BindGroupLayout {
        _ = self;
        if (desc.entries.len > 1024) return error.InvalidBindGroupLayout;
        for (desc.entries, 0..) |entry, index| {
            const visibility: u32 = @bitCast(entry.visibility);
            if (visibility == 0 or visibility & ~@as(u32, 7) != 0 or (entry.count orelse 1) == 0) return error.InvalidBindGroupLayout;
            if (entry.ty == .texture and entry.ty.texture.multisampled) return error.UnsupportedMultisampledBinding;
            if (entry.ty == .buffer and entry.ty.buffer.has_dynamic_offset) return error.UnsupportedDynamicOffsets;
            if (entry.ty == .storage_texture and entry.ty.storage_texture.access != .write_only) return error.UnsupportedStorageTextureAccess;
            for (desc.entries[0..index]) |previous| if (previous.binding == entry.binding) return error.DuplicateBinding;
        }
        return .{ .allocator = allocator, .entries = try allocator.dupe(gpu.BindGroupLayoutEntry, desc.entries) };
    }
    pub fn createPipelineLayout(self: *Device, allocator: std.mem.Allocator, desc: PipelineLayoutDescriptor) !PipelineLayout {
        if (desc.bind_group_layouts.len > 4) return error.InvalidPipelineLayout;
        var total: usize = 0;
        for (desc.bind_group_layouts) |group| total = std.math.add(usize, total, group.entries.len) catch return error.InvalidPipelineLayout;
        if (total > 1024) return error.InvalidPipelineLayout;
        const bindings = try allocator.alloc(LayoutBinding, total);
        defer allocator.free(bindings);
        var index: usize = 0;
        for (desc.bind_group_layouts, 0..) |group, group_index| for (group.entries) |entry| {
            bindings[index] = .{ .group = @intCast(group_index), .binding = entry.binding, .kind = switch (entry.ty) {
                .buffer => |buffer| switch (buffer.ty) {
                    .uniform => 0,
                    .read_only_storage => 2,
                    .storage => 3,
                },
                .texture => 1,
                .sampler => 4,
                .storage_texture => 5,
            }, .count = entry.count orelse 1, .visibility = @bitCast(entry.visibility), .min_size = if (entry.ty == .buffer) entry.ty.buffer.min_binding_size orelse 0 else 0, .view_dimension = if (entry.ty == .texture) viewDimension(entry.ty.texture.view_dimension) else if (entry.ty == .storage_texture) viewDimension(entry.ty.storage_texture.view_dimension) else 0, .sample_type = if (entry.ty == .texture) switch (entry.ty.texture.sample_type) {
                .float => 1,
                .unfilterable_float => 2,
                .depth => 3,
                .sint => 4,
                .uint => 5,
            } else 0, .sampler_type = if (entry.ty == .sampler) switch (entry.ty.sampler.ty) {
                .filtering => 1,
                .non_filtering => 2,
                .comparison => 3,
            } else 0, .storage_format = if (entry.ty == .storage_texture) try dxgiFormat(entry.ty.storage_texture.format) else 0 };
            index += 1;
        };
        var raw: ?*NativePipelineLayout = null;
        try nativeStatus(zenit_d12_pipeline_layout_create(self.raw, @intCast(desc.bind_group_layouts.len), bindings.ptr, @intCast(bindings.len), &raw), error.InvalidPipelineLayout);
        return .{ .raw = raw.? };
    }
    /// Owned CBV/SRV/UAV buffer, texture SRV and sampler binding tables.
    pub fn createBindGroup(self: *Device, allocator: std.mem.Allocator, desc: BindGroupDescriptor) !BindGroup {
        if (desc.entries.len > 1000000) return error.InvalidBindGroup;
        const native = try allocator.alloc(NativeBindingEntry, desc.entries.len);
        defer allocator.free(native);
        for (desc.entries, native) |entry, *out| out.* = try nativeBindingEntry(entry);
        var raw: ?*NativeBindGroup = null;
        try nativeStatus(zenit_d12_bind_group_create(self.raw, desc.layout.raw, desc.group, native.ptr, @intCast(native.len), &raw), error.InvalidBindGroup);
        return .{ .raw = raw.? };
    }
    pub fn createComputePipeline(self: *Device, desc: ComputePipelineDescriptor) !ComputePipeline {
        if (desc.compute_function.stage != .compute) return error.InvalidShaderStage;
        var function = try self.prepareShader(desc.compute_function);
        defer function.deinit();
        const lowered = function.raw != desc.compute_function.raw;
        var raw: ?*NativeComputePipeline = null;
        try nativeStatus(zenit_d12_compute_pipeline_create(self.raw, desc.layout.raw, function.raw, &raw), error.ShaderLayoutMismatch);
        return .{ .raw = raw.?, .atomic_switch_workaround = lowered };
    }
    pub fn createRenderPipeline(self: *Device, desc: RenderPipelineDescriptor) !RenderPipeline {
        if (desc.vertex_function.stage != .vertex or desc.fragment_function.stage != .fragment) return error.InvalidShaderStage;
        var vertex = try self.prepareShader(desc.vertex_function);
        defer vertex.deinit();
        var fragment = try self.prepareShader(desc.fragment_function);
        defer fragment.deinit();

        if (desc.multisample.count == 0 or desc.multisample.count > 32 or !std.math.isPowerOfTwo(desc.multisample.count) or desc.multisample.mask > std.math.maxInt(u32)) return error.UnsupportedMultisampling;
        if (desc.primitive.polygon_mode == .point) return error.UnsupportedPointPolygonMode;
        if (desc.vertex_buffers.len > 32 or (desc.targets.len == 0 and desc.depth_stencil == null) or desc.targets.len > 8) return error.InvalidRenderPipeline;
        var attributes: [32]NativeVertexAttribute = undefined;
        var count: usize = 0;
        for (desc.vertex_buffers, 0..) |buffer, slot| {
            if (buffer.array_stride == 0 or buffer.array_stride > 2048 or buffer.array_stride % 4 != 0) return error.InvalidRenderPipeline;
            for (buffer.attributes) |attr| {
                if (count == attributes.len or attr.offset > std.math.maxInt(u32)) return error.InvalidRenderPipeline;
                attributes[count] = .{ .location = attr.shader_location, .slot = @intCast(slot), .format = vertexFormat(attr.format), .offset = @intCast(attr.offset), .stride = @intCast(buffer.array_stride), .step = @intFromBool(buffer.step_mode == .instance) };
                count += 1;
            }
        }
        var targets: [8]NativeColorTarget = undefined;
        for (desc.targets, targets[0..desc.targets.len]) |target, *out| {
            const blend = target.blend orelse gpu.BlendState.REPLACE;
            out.* = .{ .format = try dxgiFormat(target.format), .write_mask = @bitCast(target.write_mask), .blend = @intFromBool(target.blend != null), .color_src = blendFactor(blend.color.src_factor, false), .color_dst = blendFactor(blend.color.dst_factor, false), .color_op = @as(u32, @backingInt(blend.color.operation)) + 1, .alpha_src = blendFactor(blend.alpha.src_factor, true), .alpha_dst = blendFactor(blend.alpha.dst_factor, true), .alpha_op = @as(u32, @backingInt(blend.alpha.operation)) + 1 };
        }
        if (desc.dual_source_blending) {
            if (desc.targets.len != 1 or desc.targets[0].blend == null) return error.InvalidRenderPipeline;
            targets[0].color_src = 2; // ONE
            targets[0].color_dst = 17; // INV_SRC1_COLOR
            targets[0].alpha_src = 2;
            targets[0].alpha_dst = 19; // INV_SRC1_ALPHA
        }
        const native: NativeRenderDescriptor = .{ .attributes = &attributes, .attribute_count = @intCast(count), .targets = &targets, .target_count = @intCast(desc.targets.len), .topology = @as(u32, @backingInt(desc.primitive.topology)) + 1, .strip_index = if (desc.primitive.strip_index_format) |format| @as(u32, @backingInt(format)) + 1 else 0, .front_ccw = @intFromBool(desc.primitive.front_face == .ccw), .cull = @as(u32, @backingInt(desc.primitive.cull_mode)) + 1, .fill = if (desc.primitive.polygon_mode == .line) 2 else 3, .depth_clip = @intFromBool(!desc.primitive.unclipped_depth), .sample_mask = @intCast(desc.multisample.mask), .samples = desc.multisample.count, .alpha_coverage = @intFromBool(desc.multisample.alpha_to_coverage_enabled), .depth = if (desc.depth_stencil) |d| .{ .format = try dxgiDepthFormat(d.format), .write = @intFromBool(d.depth_write_enabled), .compare = comparisonFunction(d.depth_compare), .read_mask = d.stencil_read_mask & 255, .write_mask = d.stencil_write_mask & 255, .front = stencilFace(d.stencil_front), .back = stencilFace(d.stencil_back), .bias = d.depth_bias, .slope = d.depth_bias_slope_scale, .clamp = d.depth_bias_clamp } else .{} };
        var raw: ?*NativeRenderPipeline = null;
        try nativeStatus(zenit_d12_render_pipeline_create(self.raw, desc.layout.raw, vertex.raw, fragment.raw, &native, &raw), error.InvalidRenderPipeline);
        var slots: u32 = 0;
        for (attributes[0..count]) |attribute| slots |= @as(u32, 1) << @intCast(attribute.slot);
        return .{ .raw = raw.?, .vertex_slots = slots, .atomic_switch_workaround = vertex.raw != desc.vertex_function.raw or fragment.raw != desc.fragment_function.raw };
    }
    pub fn createShaderModule(self: *Device, allocator: std.mem.Allocator, desc: gpu.ShaderModuleDescriptor) !ShaderModule {
        _ = self; // D3DCompile produces portable bytecode; no device reference needed.
        const source = switch (desc.source) {
            .hlsl => |source| source,
            else => return error.UnsupportedShaderSource,
        };
        var diagnostic: ?[]u8 = null;
        defer if (diagnostic) |message| allocator.free(message);
        return ShaderModule.compileWithDiagnostics(allocator, source, &diagnostic) catch |err| {
            if (diagnostic) |message| std.log.err("HLSL compilation: {s}", .{message});
            return err;
        };
    }
    pub fn createSampler(self: *Device, allocator: std.mem.Allocator, desc: gpu.SamplerDescriptor) !Sampler {
        _ = allocator;
        if (desc.max_anisotropy == 0 or desc.max_anisotropy > 16 or
            (desc.max_anisotropy > 1 and (desc.min_filter != .linear or desc.mag_filter != .linear or desc.mipmap_filter != .linear))) return error.InvalidSamplerDescriptor;
        const filter: u32 = if (desc.max_anisotropy > 1) 0x55 else @as(u32, if (desc.min_filter == .linear) 0x10 else 0) |
            @as(u32, if (desc.mag_filter == .linear) 4 else 0) |
            @as(u32, if (desc.mipmap_filter == .linear) 1 else 0);
        var raw: ?*NativeSampler = null;
        try nativeStatus(zenit_d12_sampler_create(self.raw, filter | @as(u32, if (desc.compare != null) 0x80 else 0), addressMode(desc.address_mode_u), addressMode(desc.address_mode_v), addressMode(desc.address_mode_w), desc.lod_min_clamp, desc.lod_max_clamp, desc.max_anisotropy, if (desc.compare) |compare| comparisonFunction(compare) else 8, &raw), error.InvalidSamplerDescriptor);
        return .{ .raw = raw.? };
    }
    /// Native quality-level support for the exact format/count pair.
    pub fn supportsSampleCount(self: *const Device, format: gpu.TextureFormat, count: u32) !bool {
        return zenit_d12_sample_supported(self.raw, try dxgiFormat(format), count) != 0;
    }
    pub fn createTexture(self: *Device, allocator: std.mem.Allocator, desc: gpu.TextureDescriptor) !Texture {
        _ = allocator;
        if (desc.memory != .device_local) return error.UnsupportedTextureMemory;
        if (desc.sample_count == 0 or desc.sample_count > 32 or !std.math.isPowerOfTwo(desc.sample_count)) return error.UnsupportedSampleCount;
        for (desc.view_formats) |format| if (format != desc.format) return error.UnsupportedViewFormat;
        const format = try dxgiFormat(desc.format);
        var raw: ?*NativeTexture = null;
        try nativeStatus(zenit_d12_texture_create(self.raw, switch (desc.dimension) {
            .@"1d" => 1,
            .@"2d" => 2,
            .@"3d" => 3,
        }, desc.size.width, desc.size.height, desc.size.depth, desc.mip_level_count, format, @bitCast(desc.usage), desc.sample_count, &raw), error.InvalidTextureDescriptor);
        // ZENIT_GPU_LEDGER names resources by label (no-op when off).
        if (desc.label) |label| zenit_d12_texture_ledger_label(raw.?, label.ptr, label.len);
        return .{ .raw = raw.?, .size = desc.size, .format = desc.format, .mip_level_count = desc.mip_level_count, .dimension = desc.dimension, .memory = desc.memory, .sample_count = desc.sample_count };
    }
    pub fn createBuffer(self: *Device, allocator: std.mem.Allocator, desc: gpu.BufferDescriptor) !Buffer {
        _ = allocator;
        // Device-local mapped-at-creation needs a staging/copy path, still pending.
        if (desc.mapped_at_creation and !desc.usage.map_write) return error.UnsupportedMappedAtCreation;
        var raw: ?*NativeBuffer = null;
        switch (zenit_d12_buffer_create(self.raw, desc.size, @bitCast(desc.usage), &raw)) {
            0 => {},
            1 => return error.InvalidBufferDescriptor,
            else => return error.BufferCreationFailed,
        }
        if (desc.label) |label| zenit_d12_buffer_ledger_label(raw.?, label.ptr, label.len);
        return .{ .raw = raw.?, .size = desc.size, .usage = desc.usage };
    }
};
pub const Buffer = struct {
    raw: *NativeBuffer,
    size: u64,
    usage: gpu.BufferUsages,
    pub fn retained(self: *const Buffer) Buffer {
        zenit_d12_buffer_retain(self.raw);
        return self.*;
    }
    pub fn getMappedRange(self: *Buffer, offset: u64, size: u64) ![]u8 {
        if (!self.usage.map_read and !self.usage.map_write) return error.BufferNotMappable;
        if (size == 0 or offset > self.size or size > self.size - offset) return error.BufferNotMapped;
        const ptr = zenit_d12_buffer_mapping(self.raw) orelse return error.BufferNotMapped;
        return ptr[@intCast(offset)..@intCast(offset + size)];
    }
    pub fn unmap(self: *Buffer) void {
        // Persistent mapping matches the shared renderers' existing contract.
        _ = self;
    }
    pub fn destroy(self: *Buffer) void {
        zenit_d12_buffer_release(self.raw);
        self.* = undefined;
    }
};

fn nativeStatus(status: c_int, invalid_error: anyerror) !void {
    switch (status) {
        0 => {},
        1 => return invalid_error,
        3 => return error.GpuTimeout,
        4 => return error.DeviceLost,
        else => return error.NativeGpuFailure,
    }
}
/// Move-only, confined to the render thread. GPU submissions are asynchronous.
pub const Queue = struct {
    raw: *NativeQueue,
    last_serial: u64 = 0,
    pub fn submit(self: *Queue, commands: []const CommandBuffer) !u64 {
        for (commands) |command| {
            var serial: u64 = 0;
            const status = zenit_d12_queue_submit(self.raw, command.raw, &serial);
            // Signal failure may follow real execution. Preserve its serial for
            // waitIdle/deinit recovery and keep native pending references alive.
            if (serial != 0) self.last_serial = serial;
            try nativeStatus(status, error.InvalidSubmission);
        }
        return self.last_serial;
    }
    pub fn wait(self: *Queue, serial: u64, timeout_ms: u32) !void {
        try nativeStatus(zenit_d12_queue_wait(self.raw, serial, timeout_ms), error.InvalidWait);
    }
    pub fn waitIdle(self: *Queue, timeout_ms: u32) !void {
        try self.wait(self.last_serial, timeout_ms);
    }
    pub fn collect(self: *Queue) !void {
        try nativeStatus(zenit_d12_queue_collect(self.raw), error.InvalidQueue);
    }
    /// A timeout/error preserves this Queue for a later retry; never drop it.
    pub fn deinit(self: *Queue, timeout_ms: u32) !void {
        try nativeStatus(zenit_d12_queue_destroy(self.raw, timeout_ms), error.InvalidQueue);
        self.* = undefined;
    }
};
pub const CommandEncoder = struct {
    raw: ?*NativeCommands,
    pub fn enableTimestamps(self: *CommandEncoder) !void {
        try nativeStatus(zenit_d12_commands_enable_timestamps(self.raw orelse return error.EncoderAlreadyFinished), error.InvalidEncoderState);
    }
    pub fn beginRenderPass(self: *CommandEncoder, desc: RenderPassDescriptor) !RenderPass {
        const raw = self.raw orelse return error.EncoderAlreadyFinished;
        if ((desc.color_attachments.len == 0 and desc.depth_stencil_attachment == null) or desc.color_attachments.len > 8) return error.InvalidRenderPass;
        var attachments: [8]NativeColorAttachment = undefined;
        for (desc.color_attachments, attachments[0..desc.color_attachments.len]) |attachment, *out| {
            out.* = .{ .texture = attachment.texture.raw, .mip = attachment.mip, .layer = attachment.layer, .load_op = @backingInt(attachment.load_op), .store_op = @backingInt(attachment.store_op), .clear = attachment.clear_value, .resolve = if (attachment.resolve_target) |r| r.texture.raw else null, .resolve_mip = if (attachment.resolve_target) |r| r.mip else 0, .resolve_layer = if (attachment.resolve_target) |r| r.layer else 0 };
        }
        var depth: NativeDepthAttachment = undefined;
        if (desc.depth_stencil_attachment) |d| depth = .{ .texture = d.texture.raw, .mip = d.mip, .layer = d.layer, .depth_load = @backingInt(d.depth_load_op), .depth_store = @backingInt(d.depth_store_op), .stencil_load = @backingInt(d.stencil_load_op), .stencil_store = @backingInt(d.stencil_store_op), .clear = d.depth_clear_value, .stencil_clear = d.stencil_clear_value, .depth_read_only = @intFromBool(d.depth_read_only), .stencil_read_only = @intFromBool(d.stencil_read_only) };
        var pass: ?*NativeRenderPass = null;
        try nativeStatus(zenit_d12_render_pass_begin(raw, &attachments, @intCast(desc.color_attachments.len), if (desc.depth_stencil_attachment != null) &depth else null, &pass), error.InvalidRenderPass);
        return .{ .raw = pass.? };
    }
    /// Records a complete compute dispatch with immutable binding tables.
    /// Resources and pipeline can be destroyed by the caller after recording.
    pub fn dispatch(self: *CommandEncoder, pipeline: *const ComputePipeline, groups: []const BindGroup, x: u32, y: u32, z: u32) !void {
        const raw = self.raw orelse return error.EncoderAlreadyFinished;
        if (groups.len > 4) return error.InvalidDispatch;
        var native: [4]*NativeBindGroup = undefined;
        for (groups, 0..) |group, i| native[i] = group.raw;
        try nativeStatus(zenit_d12_commands_dispatch(raw, pipeline.raw, &native, @intCast(groups.len), x, y, z), error.InvalidDispatch);
    }
    pub fn copyBufferToBuffer(self: *CommandEncoder, source: *Buffer, source_offset: u64, destination: *Buffer, destination_offset: u64, size: u64) !void {
        const raw = self.raw orelse return error.EncoderAlreadyFinished;
        try nativeStatus(zenit_d12_commands_copy(raw, source.raw, source_offset, destination.raw, destination_offset, size), error.InvalidBufferCopy);
    }
    pub fn copyBufferToTexture(self: *CommandEncoder, source: *Buffer, offset: u64, row_pitch: u32, destination: *Texture, region: TextureRegion) !void {
        const raw = self.raw orelse return error.EncoderAlreadyFinished;
        try nativeStatus(zenit_d12_commands_texture_copy(raw, source.raw, offset, row_pitch, destination.raw, &region, 1), error.InvalidTextureCopy);
    }
    pub fn copyTextureToBuffer(self: *CommandEncoder, source: *Texture, region: TextureRegion, destination: *Buffer, offset: u64, row_pitch: u32) !void {
        const raw = self.raw orelse return error.EncoderAlreadyFinished;
        try nativeStatus(zenit_d12_commands_texture_copy(raw, destination.raw, offset, row_pitch, source.raw, &region, 0), error.InvalidTextureCopy);
    }
    /// Exact-format single-sample color copy. Regions must have equal extents.
    /// Same texture is valid only across different subresources.
    pub fn copyTextureToTexture(self: *CommandEncoder, source: *const Texture, source_region: TextureRegion, destination: *const Texture, destination_region: TextureRegion) !void {
        const raw = self.raw orelse return error.CommandEncoderFinished;
        try nativeStatus(zenit_d12_commands_texture_region_copy(raw, source.raw, &source_region, destination.raw, &destination_region), error.InvalidTextureCopy);
    }
    pub fn finish(self: *CommandEncoder) !CommandBuffer {
        const raw = self.raw orelse return error.EncoderAlreadyFinished;
        try nativeStatus(zenit_d12_commands_finish(raw), error.InvalidEncoderState);
        self.raw = null;
        return .{ .raw = raw };
    }
    pub fn deinit(self: *CommandEncoder) void {
        if (self.raw) |raw| zenit_d12_commands_release(raw);
        self.raw = null;
    }
};
pub const GpuTimingResult = union(enum) { pending, disjoint, failed, elapsed: u64 };
pub const CommandBuffer = struct {
    raw: *NativeCommands,
    /// Completion-only mapped read; never waits or submits additional work.
    pub fn gpuTimingResult(self: *const CommandBuffer) GpuTimingResult {
        var micros: u64 = 0;
        return switch (zenit_d12_commands_elapsed_micros(self.raw, &micros)) {
            0 => .{ .elapsed = micros },
            3 => .pending,
            5 => .disjoint,
            else => .failed,
        };
    }
    pub fn gpuElapsedMicros(self: *const CommandBuffer) ?u64 {
        var micros: u64 = 0;
        if (zenit_d12_commands_elapsed_micros(self.raw, &micros) != 0) return null;
        return micros;
    }
    pub fn deinit(self: *CommandBuffer) void {
        zenit_d12_commands_release(self.raw);
        self.* = undefined;
    }
};

/// One color subresource; layer selects an array slice, z selects a 3D slice.
pub const TextureRegion = extern struct {
    mip: u32 = 0,
    layer: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
    width: u32,
    height: u32,
    depth: u32 = 1,
};
/// required_bytes includes the buffer offset and meaningful last row, excluding
/// trailing padding. Padding between rows/slices must not be interpreted as pixels.
pub const TextureCopyLayout = extern struct {
    offset: u64,
    row_bytes: u64,
    required_bytes: u64,
    row_pitch: u32,
    width: u32,
    height: u32,
    depth: u32,
};
pub const Texture = struct {
    raw: *NativeTexture,
    size: gpu.Extent3D,
    format: gpu.TextureFormat,
    mip_level_count: u32,
    dimension: gpu.TextureDimension,
    memory: gpu.TextureMemory,
    sample_count: u32,
    pub fn retained(self: *const Texture) Texture {
        zenit_d12_texture_retain(self.raw);
        return self.*;
    }
    pub fn createView(self: *Texture, desc: gpu.TextureViewDescriptor) !TextureView {
        if (desc.format) |format| if (format != self.format) return error.UnsupportedViewFormat;
        if (desc.base_mip_level >= self.mip_level_count) return error.InvalidTextureView;
        const dimension = desc.dimension orelse switch (self.dimension) {
            .@"1d" => gpu.TextureViewDimension.@"1d",
            .@"2d" => if (self.size.depth > 1) gpu.TextureViewDimension.@"2d_array" else gpu.TextureViewDimension.@"2d",
            .@"3d" => gpu.TextureViewDimension.@"3d",
        };
        const available_layers = if (self.dimension == .@"3d") 1 else self.size.depth;
        if (desc.base_array_layer >= available_layers) return error.InvalidTextureView;
        var raw: ?*NativeView = null;
        try nativeStatus(zenit_d12_view_create(self.raw, switch (dimension) {
            .@"1d" => 1,
            .@"2d" => 2,
            .@"2d_array" => 3,
            .cube => 4,
            .cube_array => 5,
            .@"3d" => 6,
        }, desc.base_mip_level, desc.mip_level_count orelse self.mip_level_count - desc.base_mip_level, desc.base_array_layer, desc.array_layer_count orelse (if (dimension == .cube) 6 else available_layers - desc.base_array_layer), &raw), error.InvalidTextureView);
        return .{ .raw = raw.? };
    }
    /// A single mip, writable storage view. Cube storage views are unsupported.
    pub fn createStorageView(self: *Texture, desc: gpu.TextureViewDescriptor) !TextureView {
        if (desc.format) |format| if (format != self.format) return error.UnsupportedViewFormat;
        if (desc.base_mip_level >= self.mip_level_count or (desc.mip_level_count orelse 1) != 1) return error.InvalidTextureView;
        const dimension = desc.dimension orelse switch (self.dimension) {
            .@"1d" => gpu.TextureViewDimension.@"1d",
            .@"2d" => if (self.size.depth > 1) gpu.TextureViewDimension.@"2d_array" else gpu.TextureViewDimension.@"2d",
            .@"3d" => gpu.TextureViewDimension.@"3d",
        };
        const layers = if (self.dimension == .@"3d") 1 else self.size.depth;
        if (desc.base_array_layer >= layers) return error.InvalidTextureView;
        var raw: ?*NativeView = null;
        try nativeStatus(zenit_d12_storage_view_create(self.raw, viewDimension(dimension), desc.base_mip_level, desc.base_array_layer, desc.array_layer_count orelse (layers - desc.base_array_layer), &raw), error.InvalidTextureView);
        return .{ .raw = raw.? };
    }
    pub fn fullRegion(self: *const Texture, mip: u32, layer: u32) !TextureRegion {
        if (mip >= self.mip_level_count or mip >= 32 or
            (if (self.dimension == .@"3d") layer != 0 else layer >= self.size.depth)) return error.InvalidTextureRegion;
        const shift: u5 = @intCast(mip);
        return .{ .mip = mip, .layer = layer, .width = @max(1, self.size.width >> shift), .height = @max(1, self.size.height >> shift), .depth = if (self.dimension == .@"3d") @max(1, self.size.depth >> shift) else 1 };
    }
    pub fn copyLayout(self: *const Texture, region: TextureRegion, offset: u64) !TextureCopyLayout {
        var result: TextureCopyLayout = undefined;
        try nativeStatus(zenit_d12_texture_layout(self.raw, &region, offset, &result), error.InvalidTextureRegion);
        return result;
    }
    pub fn destroy(self: *Texture) void {
        zenit_d12_texture_release(self.raw);
        self.* = undefined;
    }
};
fn dxgiDepthFormat(format: gpu.TextureFormat) !u32 {
    return switch (format) {
        .depth16_unorm => 55,
        .depth24_plus, .depth32_float => 40,
        .depth24_plus_stencil8 => 45,
        .depth32_float_stencil8 => 20,
        else => error.UnsupportedDepthStencil,
    };
}
fn stencilOperation(op: gpu.StencilOperation) u32 {
    return switch (op) {
        .keep => 1,
        .zero => 2,
        .replace => 3,
        .increment_clamp => 4,
        .decrement_clamp => 5,
        .invert => 6,
        .increment_wrap => 7,
        .decrement_wrap => 8,
    };
}
fn stencilFace(face: gpu.StencilFaceState) NativeStencilFace {
    return .{ .compare = comparisonFunction(face.compare), .fail = stencilOperation(face.fail_op), .depth_fail = stencilOperation(face.depth_fail_op), .pass = stencilOperation(face.pass_op) };
}
fn dxgiFormat(format: gpu.TextureFormat) !u32 {
    return switch (format) {
        .r8_unorm => 61,
        .r8_snorm => 63,
        .r8_uint => 62,
        .r8_sint => 64,
        .r16_uint => 57,
        .r16_sint => 59,
        .r16_float => 54,
        .rg8_unorm => 49,
        .rg8_snorm => 51,
        .rg8_uint => 50,
        .rg8_sint => 52,
        .r32_uint => 42,
        .r32_sint => 43,
        .r32_float => 41,
        .rg16_uint => 36,
        .rg16_sint => 38,
        .rg16_float => 34,
        .rgba8_unorm => 28,
        .rgba8_unorm_srgb => 29,
        .rgba8_snorm => 31,
        .rgba8_uint => 30,
        .rgba8_sint => 32,
        .bgra8_unorm => 87,
        .bgra8_unorm_srgb => 91,
        .rgb10a2_unorm => 24,
        .rg32_uint => 17,
        .rg32_sint => 18,
        .rg32_float => 16,
        .rgba16_uint => 12,
        .rgba16_sint => 14,
        .rgba16_float => 10,
        .rgba32_uint => 3,
        .rgba32_sint => 4,
        .rgba32_float => 2,
        .depth16_unorm, .depth24_plus, .depth24_plus_stencil8, .depth32_float, .depth32_float_stencil8 => try dxgiDepthFormat(format),
        else => error.UnsupportedTextureFormat,
    };
}

fn addressMode(mode: gpu.AddressMode) u32 {
    return switch (mode) {
        .clamp_to_edge => 3,
        .repeat => 1,
        .mirror_repeat => 2,
        .clamp_to_border => 4,
    };
}
pub const TextureView = struct {
    raw: *NativeView,
    pub fn destroy(self: *TextureView) void {
        zenit_d12_view_release(self.raw);
        self.* = undefined;
    }
};
pub const Sampler = struct {
    raw: *NativeSampler,
    pub fn retained(self: *const Sampler) Sampler {
        zenit_d12_sampler_retain(self.raw);
        return self.*;
    }
    pub fn destroy(self: *Sampler) void {
        zenit_d12_sampler_release(self.raw);
        self.* = undefined;
    }
};

fn comparisonFunction(compare: gpu.CompareFunction) u32 {
    return switch (compare) {
        .never => 1,
        .less => 2,
        .equal => 3,
        .less_equal => 4,
        .greater => 5,
        .not_equal => 6,
        .greater_equal => 7,
        .always => 8,
    };
}

pub const BindGroupLayout = struct {
    allocator: std.mem.Allocator,
    entries: []const gpu.BindGroupLayoutEntry,
    pub fn deinit(self: *BindGroupLayout) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};
pub const PipelineLayoutDescriptor = struct { label: ?[]const u8 = null, bind_group_layouts: []const BindGroupLayout };
pub const PipelineLayout = struct {
    raw: *NativePipelineLayout,
    /// Borrowed metadata remains valid for this layout's native lifetime.
    pub fn describe(self: *const PipelineLayout) struct { bindings: []const LayoutBinding, groups: u32 } {
        var count: u32 = 0;
        var groups: u32 = 0;
        const pointer = zenit_d12_pipeline_layout_bindings(self.raw, &count, &groups);
        return .{ .bindings = if (pointer) |p| p[0..count] else &.{}, .groups = groups };
    }
    pub fn tableIndex(self: *const PipelineLayout, group: u32, sampler: bool) ?u32 {
        const index = zenit_d12_pipeline_layout_table(self.raw, group, @intFromBool(sampler));
        return if (index == std.math.maxInt(u32)) null else index;
    }
    pub fn deinit(self: *PipelineLayout) void {
        zenit_d12_pipeline_layout_release(self.raw);
        self.* = undefined;
    }
};
pub const ComputePipelineDescriptor = struct { label: ?[]const u8 = null, layout: *const PipelineLayout, compute_function: *const ShaderFunction };
pub const ComputePipeline = struct {
    raw: *NativeComputePipeline,
    atomic_switch_workaround: bool = false,
    pub fn deinit(self: *ComputePipeline) void {
        zenit_d12_compute_pipeline_release(self.raw);
        self.* = undefined;
    }
};

/// Native form of one bind group entry (also used by entry draws).
pub fn nativeBindingEntry(entry: BindGroupEntry) !NativeBindingEntry {
    if (entry.buffer) |buffer| if (entry.offset > buffer.size) return error.InvalidBindGroup;
    if (entry.buffer == null and (entry.offset != 0 or entry.size != null or entry.stride != 0)) return error.InvalidBindGroup;
    return .{ .binding = entry.binding, .array_index = entry.array_index, .buffer = if (entry.buffer) |buffer| buffer.raw else null, .view = if (entry.texture_view) |view| view.raw else null, .sampler = if (entry.sampler) |sampler| sampler.raw else null, .offset = entry.offset, .size = if (entry.buffer) |buffer| entry.size orelse (buffer.size - entry.offset) else 0, .stride = entry.stride };
}
/// Whether bind_group_create accepts these entries for `group` (the group is
/// created and released; for error attribution, not for per-draw use).
pub fn validateBindGroupEntries(layout: *const PipelineLayout, group: u32, entries: []const NativeBindingEntry) bool {
    var raw: ?*NativeBindGroup = null;
    if (zenit_d12_bind_group_create(zenit_d12_pipeline_layout_owner(layout.raw), layout.raw, group, entries.ptr, @intCast(entries.len), &raw) != 0) return false;
    zenit_d12_bind_group_release(raw.?);
    return true;
}
/// Supply exactly one buffer, texture_view or sampler.
/// D3D12 buffer interpretation is explicit: zero stride = byte-address,
/// nonzero stride = structured buffer. Uniform buffers require zero stride.
pub const BindGroupEntry = struct {
    binding: u32,
    array_index: u32 = 0,
    buffer: ?*const Buffer = null,
    texture_view: ?*const TextureView = null,
    sampler: ?*const Sampler = null,
    offset: u64 = 0,
    size: ?u64 = null,
    stride: u32 = 0,
};
pub const BufferBinding = BindGroupEntry;
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: *const PipelineLayout,
    group: u32,
    entries: []const BindGroupEntry,
};
pub const BindGroup = struct {
    raw: *NativeBindGroup,
    pub fn deinit(self: *BindGroup) void {
        zenit_d12_bind_group_release(self.raw);
        self.* = undefined;
    }
};

fn viewDimension(dimension: gpu.TextureViewDimension) u32 {
    return switch (dimension) {
        .@"1d" => 1,
        .@"2d" => 2,
        .@"2d_array" => 3,
        .cube => 4,
        .cube_array => 5,
        .@"3d" => 6,
    };
}

/// Shader locations map to HLSL TEXCOORDn input semantics. SV_VertexID and
/// SV_InstanceID do not require a vertex-buffer attribute.
pub const RenderPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: *const PipelineLayout,
    vertex_function: *const ShaderFunction,
    fragment_function: *const ShaderFunction,
    vertex_buffers: []const gpu.VertexBufferLayout = &.{},
    targets: []const gpu.ColorTargetState,
    dual_source_blending: bool = false,
    primitive: gpu.PrimitiveState = .{},
    depth_stencil: ?gpu.DepthStencilState = null,
    multisample: gpu.MultisampleState = .{},
};
pub const RenderPipeline = struct {
    raw: *NativeRenderPipeline,
    vertex_slots: u32,
    atomic_switch_workaround: bool = false,
    /// Borrowed: pipeline owns its native layout. Do not deinit this value.
    pub fn bindingLayout(self: *const RenderPipeline) PipelineLayout {
        return .{ .raw = zenit_d12_render_pipeline_layout(self.raw) };
    }
    pub fn bufferStride(self: *const RenderPipeline, group: u32, binding: u32) !u32 {
        var stride: u32 = 0;
        try nativeStatus(zenit_d12_render_buffer_stride(self.raw, group, binding, &stride), error.ShaderLayoutMismatch);
        return stride;
    }
    pub fn retained(self: *const RenderPipeline) RenderPipeline {
        zenit_d12_render_pipeline_retain(self.raw);
        return self.*;
    }
    pub fn deinit(self: *RenderPipeline) void {
        zenit_d12_render_pipeline_release(self.raw);
        self.* = undefined;
    }
};
fn blendFactor(factor: gpu.BlendFactor, alpha: bool) u32 {
    return switch (factor) {
        .zero => 1,
        .one => 2,
        .src => if (alpha) 5 else 3,
        .one_minus_src => if (alpha) 6 else 4,
        .src_alpha => 5,
        .one_minus_src_alpha => 6,
        .dst => if (alpha) 7 else 9,
        .one_minus_dst => if (alpha) 8 else 10,
        .dst_alpha => 7,
        .one_minus_dst_alpha => 8,
        .src_alpha_saturated => if (alpha) 2 else 11,
        .constant => 14,
        .one_minus_constant => 15,
    };
}
fn vertexFormat(format: gpu.VertexFormat) u32 {
    return switch (format) {
        .uint8x2 => 50,
        .uint8x4 => 30,
        .sint8x2 => 52,
        .sint8x4 => 32,
        .unorm8x2 => 49,
        .unorm8x4 => 28,
        .snorm8x2 => 51,
        .snorm8x4 => 31,
        .uint16x2 => 36,
        .uint16x4 => 12,
        .sint16x2 => 38,
        .sint16x4 => 14,
        .unorm16x2 => 35,
        .unorm16x4 => 11,
        .snorm16x2 => 37,
        .snorm16x4 => 13,
        .float16x2 => 34,
        .float16x4 => 10,
        .float32 => 41,
        .float32x2 => 16,
        .float32x3 => 6,
        .float32x4 => 2,
        .uint32 => 42,
        .uint32x2 => 17,
        .uint32x3 => 7,
        .uint32x4 => 3,
        .sint32 => 43,
        .sint32x2 => 18,
        .sint32x3 => 8,
        .sint32x4 => 4,
    };
}

/// Single subresource of a 2D texture/array. Attachments stay alive until the
/// command's GPU work completes. Resolve selects one single-sample subresource.
pub const ResolveTarget = struct { texture: *const Texture, mip: u32 = 0, layer: u32 = 0 };
pub const ColorAttachment = struct {
    texture: *const Texture,
    mip: u32 = 0,
    layer: u32 = 0,
    load_op: gpu.LoadOp = .load,
    store_op: gpu.StoreOp = .store,
    clear_value: [4]f32 = .{ 0, 0, 0, 0 },
    resolve_target: ?ResolveTarget = null,
};
pub const DepthStencilAttachment = struct {
    texture: *const Texture,
    mip: u32 = 0,
    layer: u32 = 0,
    depth_load_op: gpu.LoadOp = .load,
    depth_store_op: gpu.StoreOp = .store,
    depth_clear_value: f32 = 0,
    depth_read_only: bool = false,
    stencil_load_op: gpu.LoadOp = .load,
    stencil_store_op: gpu.StoreOp = .store,
    stencil_clear_value: u32 = 0,
    stencil_read_only: bool = false,
};
pub const RenderPassDescriptor = struct { label: ?[]const u8 = null, color_attachments: []const ColorAttachment = &.{}, depth_stencil_attachment: ?DepthStencilAttachment = null };
pub const VertexBinding = struct { buffer: *const Buffer, slot: u32, offset: u64 = 0, size: ?u64 = null };
pub const Scissor = struct { x: u32 = 0, y: u32 = 0, width: u32, height: u32 };
/// Optional viewport, in attachment pixels. Null restores the full attachment.
pub const Viewport = struct { x: f32 = 0, y: f32 = 0, width: f32, height: f32, min_depth: f32 = 0, max_depth: f32 = 1 };
pub const DrawDescriptor = struct {
    pipeline: *const RenderPipeline,
    vertex_buffers: []const VertexBinding = &.{},
    bind_groups: []const BindGroup = &.{},
    vertex_count: u32,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
    scissor: ?Scissor = null,
    viewport: ?Viewport = null,
    blend_constant: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_reference: u32 = 0,
};
pub const IndexBinding = struct { buffer: *const Buffer, format: gpu.IndexFormat, offset: u64 = 0, size: ?u64 = null };
pub const IndexedDrawDescriptor = struct {
    pipeline: *const RenderPipeline,
    vertex_buffers: []const VertexBinding = &.{},
    bind_groups: []const BindGroup = &.{},
    index_buffer: IndexBinding,
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    base_vertex: i32 = 0,
    first_instance: u32 = 0,
    scissor: ?Scissor = null,
    viewport: ?Viewport = null,
    blend_constant: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_reference: u32 = 0,
};
pub const RenderPass = struct {
    raw: ?*NativeRenderPass,
    pub fn setDrawRegions(self: *RenderPass, regions: []const [4]u32) !void {
        const raw = self.raw orelse return error.RenderPassAlreadyEnded;
        if (regions.len > 4) return error.InvalidDrawRegions;
        try nativeStatus(zenit_d12_render_pass_regions(raw, if (regions.len == 0) null else @ptrCast(regions.ptr), @intCast(regions.len)), error.InvalidDrawRegions);
    }
    pub fn clearOpaque(self: *RenderPass, color: [4]f32, bounds: [4]u32) !void {
        const raw = self.raw orelse return error.RenderPassAlreadyEnded;
        try nativeStatus(zenit_d12_render_pass_clear_opaque(raw, &color, bounds[0], bounds[1], bounds[2], bounds[3]), error.InvalidClear);
    }
    /// Record a complete non-indexed draw and immutable descriptor tables.
    pub fn draw(self: *RenderPass, desc: DrawDescriptor) !void {
        return self.recordDraw(desc, null, 0, 0, null);
    }
    /// Draw with bind groups given as native entries (`group_counts[i]` per
    /// group, concatenated): the same validation and recorded draw as binding
    /// groups created from them, without per-draw bind group objects.
    pub fn drawEntries(self: *RenderPass, desc: DrawDescriptor, entries: []const NativeBindingEntry, group_counts: []const u32) !void {
        if (desc.bind_groups.len != 0 or group_counts.len > 4) return error.InvalidDraw;
        var total: usize = 0;
        for (group_counts) |count| total += count;
        if (total != entries.len) return error.InvalidDraw;
        return self.recordDraw(desc, null, 0, 0, .{ .entries = entries, .group_counts = group_counts });
    }
    /// Index contents may be GPU-written: callers must keep effective vertex
    /// indices within the bound vertex ranges. Instance and index byte bounds
    /// are validated before recording, without reading GPU-owned data.
    pub fn drawIndexed(self: *RenderPass, desc: IndexedDrawDescriptor) !void {
        return self.recordDraw(.{ .pipeline = desc.pipeline, .vertex_buffers = desc.vertex_buffers, .bind_groups = desc.bind_groups, .vertex_count = desc.index_count, .instance_count = desc.instance_count, .first_instance = desc.first_instance, .scissor = desc.scissor, .viewport = desc.viewport, .blend_constant = desc.blend_constant, .stencil_reference = desc.stencil_reference }, desc.index_buffer, desc.first_index, desc.base_vertex, null);
    }
    const EntryGroups = struct { entries: []const NativeBindingEntry, group_counts: []const u32 };
    fn recordDraw(self: *RenderPass, desc: DrawDescriptor, index: ?IndexBinding, first_index: u32, base_vertex: i32, direct: ?EntryGroups) !void {
        const raw = self.raw orelse return error.RenderPassAlreadyEnded;
        if (desc.vertex_buffers.len > 32 or desc.bind_groups.len > 4) return error.InvalidDraw;
        var groups: [4]*NativeBindGroup = undefined;
        for (desc.bind_groups, groups[0..desc.bind_groups.len]) |group, *out| out.* = group.raw;
        var bindings: [32]NativeVertexBinding = undefined;
        for (desc.vertex_buffers, bindings[0..desc.vertex_buffers.len]) |binding, *out| {
            if (binding.offset > binding.buffer.size) return error.InvalidDraw;
            out.* = .{ .buffer = binding.buffer.raw, .slot = binding.slot, .offset = binding.offset, .size = binding.size orelse (binding.buffer.size - binding.offset) };
        }
        const scissor = desc.scissor orelse Scissor{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) };
        if (index) |binding| if (binding.offset > binding.buffer.size) return error.InvalidDraw;
        const native: NativeDraw = .{ .buffers = &bindings, .buffer_count = @intCast(desc.vertex_buffers.len), .first_vertex = desc.first_vertex, .vertices = desc.vertex_count, .first_instance = desc.first_instance, .instances = desc.instance_count, .x = scissor.x, .y = scissor.y, .width = scissor.width, .height = scissor.height, .blend = desc.blend_constant, .stencil_reference = desc.stencil_reference, .groups = &groups, .group_count = @intCast(desc.bind_groups.len), .index_buffer = if (index) |b| b.buffer.raw else null, .index_offset = if (index) |b| b.offset else 0, .index_size = if (index) |b| b.size orelse (b.buffer.size - b.offset) else 0, .index_format = if (index) |b| @as(u32, @backingInt(b.format)) + 1 else 0, .first_index = first_index, .base_vertex = base_vertex, .has_viewport = @intFromBool(desc.viewport != null), .viewport = if (desc.viewport) |v| .{ v.x, v.y, v.width, v.height, v.min_depth, v.max_depth } else .{ 0, 0, 0, 0, 0, 1 } };
        if (direct) |d| {
            const status = zenit_d12_render_pass_draw_entries(raw, desc.pipeline.raw, &native, d.entries.ptr, d.group_counts.ptr, @intCast(d.group_counts.len));
            if (status == 6) return error.InvalidBindGroup;
            try nativeStatus(status, error.InvalidDraw);
        } else try nativeStatus(zenit_d12_render_pass_draw(raw, desc.pipeline.raw, &native), error.InvalidDraw);
    }
    pub fn end(self: *RenderPass) !void {
        const raw = self.raw orelse return error.RenderPassAlreadyEnded;
        try nativeStatus(zenit_d12_render_pass_end(raw), error.InvalidRenderPass);
        self.raw = null;
    }
    pub fn deinit(self: *RenderPass) void {
        if (self.raw != null) self.end() catch @panic("render pass cleanup failed");
    }
};
