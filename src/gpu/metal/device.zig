/// Metal Device 实现
///
/// 用于创建各种 GPU 资源
/// 所有资源创建函数都显式接受 Allocator 参数（Data-Oriented Design）
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const conv = @import("conv.zig");
const resources = @import("resources.zig");

/// Device - Metal 设备（纯数据结构）
pub const Device = struct {
    raw_device: *mtl.MTLDevice,
    features: gpu.Features,
    limits: gpu.Limits,

    // 可选：资源统计
    buffer_count: usize = 0,
    texture_count: usize = 0,
    sampler_count: usize = 0,

    /// 创建 Buffer
    /// 注意：返回的 Buffer 不需要 allocator 释放（Metal 对象自己管理引用计数）
    ///      但 allocator 参数为未来扩展保留（如需分配辅助结构）
    pub fn createBuffer(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.BufferDescriptor,
    ) !resources.Buffer {
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        const options = conv.toMetalResourceOptions(desc.usage);

        const buffer = mtl.metal_device_new_buffer(
            self.raw_device,
            desc.size,
            options,
        ) orelse return error.OutOfMemory;

        // 设置标签（如果提供）
        if (desc.label) |label| {
            const z = allocator.dupeZ(u8, label) catch null;
            if (z) |label_z| {
                defer allocator.free(label_z);
                mtl.metal_buffer_set_label(buffer, label_z);
            }
        }

        self.buffer_count += 1;

        return resources.Buffer{
            .raw = buffer,
            .size = desc.size,
            .usage = desc.usage,
        };
    }

    /// 创建 Texture
    pub fn createTexture(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.TextureDescriptor,
    ) !resources.Texture {
        if (desc.size.width == 0 or desc.size.height == 0 or desc.size.depth == 0 or
            desc.mip_level_count == 0 or desc.sample_count == 0)
        {
            return error.InvalidTextureDescriptor;
        }
        if (desc.memory == .host_upload and desc.sample_count != 1) {
            return error.InvalidTextureDescriptor;
        }
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // 创建 descriptor
        const mtl_desc = mtl.metal_texture_descriptor_new() orelse
            return error.OutOfMemory;
        defer mtl.release(mtl_desc);

        // 配置
        mtl.metal_texture_descriptor_set_pixel_format(
            mtl_desc,
            @intFromEnum(conv.toMetalPixelFormat(desc.format)),
        );
        mtl.metal_texture_descriptor_set_width(mtl_desc, desc.size.width);
        mtl.metal_texture_descriptor_set_height(mtl_desc, desc.size.height);
        mtl.metal_texture_descriptor_set_depth(mtl_desc, desc.size.depth);
        mtl.metal_texture_descriptor_set_mipmap_level_count(mtl_desc, desc.mip_level_count);
        mtl.metal_texture_descriptor_set_sample_count(mtl_desc, desc.sample_count);
        mtl.metal_texture_descriptor_set_texture_type(
            mtl_desc,
            @intFromEnum(conv.toMetalTextureType(desc.dimension)),
        );
        mtl.metal_texture_descriptor_set_usage(
            mtl_desc,
            conv.toMetalTextureUsage(desc.usage),
        );
        mtl.metal_texture_descriptor_set_storage_mode(
            mtl_desc,
            @intFromEnum(switch (desc.memory) {
                .device_local => mtl.MTLStorageMode.Private,
                .host_upload => mtl.MTLStorageMode.Shared,
            }),
        );

        // 创建纹理
        const texture = mtl.metal_device_new_texture(self.raw_device, mtl_desc) orelse
            return error.OutOfMemory;

        if (desc.label) |label| {
            const z = allocator.dupeZ(u8, label) catch null;
            if (z) |label_z| {
                defer allocator.free(label_z);
                mtl.metal_texture_set_label(texture, label_z);
            }
        }

        self.texture_count += 1;
        if (std.posix.getenv("ZENIT_DEBUG_TEXCREATE") != null) {
            std.debug.print("[texcreate] {s} {d}x{d}\n", .{ desc.label orelse "?", desc.size.width, desc.size.height });
        }

        return resources.Texture{
            .raw = texture,
            .format = desc.format,
            .size = desc.size,
            .mip_level_count = desc.mip_level_count,
            .dimension = desc.dimension,
            .memory = desc.memory,
        };
    }

    /// Create a sampler entirely from the backend-neutral descriptor.
    pub fn createSampler(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.SamplerDescriptor,
    ) !resources.Sampler {
        if (!std.math.isFinite(desc.lod_min_clamp) or
            !std.math.isFinite(desc.lod_max_clamp) or
            desc.lod_min_clamp < 0 or
            desc.lod_min_clamp > desc.lod_max_clamp or
            desc.max_anisotropy == 0 or
            desc.max_anisotropy > 16)
        {
            return error.InvalidSamplerDescriptor;
        }

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        const mtl_desc = mtl.metal_sampler_descriptor_new() orelse return error.OutOfMemory;
        defer mtl.release(mtl_desc);
        mtl.metal_sampler_descriptor_set_min_filter(mtl_desc, @intFromEnum(conv.toMetalMinMagFilter(desc.min_filter)));
        mtl.metal_sampler_descriptor_set_mag_filter(mtl_desc, @intFromEnum(conv.toMetalMinMagFilter(desc.mag_filter)));
        mtl.metal_sampler_descriptor_set_mip_filter(mtl_desc, @intFromEnum(conv.toMetalMipFilter(desc.mipmap_filter)));
        mtl.metal_sampler_descriptor_set_address_mode_u(mtl_desc, @intFromEnum(conv.toMetalAddressMode(desc.address_mode_u)));
        mtl.metal_sampler_descriptor_set_address_mode_v(mtl_desc, @intFromEnum(conv.toMetalAddressMode(desc.address_mode_v)));
        mtl.metal_sampler_descriptor_set_address_mode_w(mtl_desc, @intFromEnum(conv.toMetalAddressMode(desc.address_mode_w)));
        mtl.metal_sampler_descriptor_set_lod_min_clamp(mtl_desc, desc.lod_min_clamp);
        mtl.metal_sampler_descriptor_set_lod_max_clamp(mtl_desc, desc.lod_max_clamp);
        mtl.metal_sampler_descriptor_set_max_anisotropy(mtl_desc, desc.max_anisotropy);
        if (desc.compare) |function| {
            mtl.metal_sampler_descriptor_set_compare_function(mtl_desc, conv.toMetalCompareFunction(function));
        }
        if (desc.label) |label| {
            const label_z = try allocator.dupeZ(u8, label);
            defer allocator.free(label_z);
            mtl.metal_sampler_descriptor_set_label(mtl_desc, label_z);
        }

        const sampler = mtl.metal_device_new_sampler(self.raw_device, mtl_desc) orelse return error.OutOfMemory;
        self.sampler_count += 1;
        return .{ .raw = sampler };
    }

    /// 创建 RenderPipeline
    pub fn createRenderPipeline(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.RenderPipelineDescriptor,
    ) !RenderPipeline {
        _ = allocator;
        _ = self;
        _ = desc;
        return error.NotImplemented;
    }

    /// 销毁设备
    pub fn deinit(self: *Device) void {
        mtl.release(self.raw_device);
        // 统计信息打印（Debug 模式）
        if (std.debug.runtime_safety) {
            std.debug.print("[Device] deinit: created {} buffers, {} textures, {} samplers\n", .{
                self.buffer_count,
                self.texture_count,
                self.sampler_count,
            });
        }
    }
};

// 占位类型（在后续阶段实现）
pub const ShaderModule = struct {};
pub const RenderPipeline = struct {};
pub const ComputePipeline = struct {};
pub const CommandEncoder = struct {};
