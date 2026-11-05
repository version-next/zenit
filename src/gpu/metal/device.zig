/// Metal Device implementation
///
/// Creates GPU resources. All resource creation functions accept explicit Allocator parameter
/// (Data-Oriented Design).
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const conv = @import("conv.zig");
const resources = @import("resources.zig");
const test_support = @import("test_support.zig");

/// Device - Metal device (pure data structure)
pub const Device = struct {
    raw_device: *mtl.MTLDevice,
    features: gpu.Features,
    limits: gpu.Limits,

    // Optional: resource statistics
    buffer_count: usize = 0,
    texture_count: usize = 0,
    sampler_count: usize = 0,
    framebuffer_fetch_supported: ?bool = null,
    fail_next_texture_for_testing: if (test_support.enabled) bool else void = if (test_support.enabled) false else {},
    samplers_live_for_testing: if (test_support.enabled) usize else void = if (test_support.enabled) 0 else {},

    /// Programmable color-attachment reads are an Apple GPU capability.
    pub fn supportsFramebufferFetch(self: *Device) bool {
        if (comptime test_support.enabled) {
            if (@import("zenit_environment").flag("ZENIT_DEV_NO_FRAMEBUFFER_FETCH")) return false;
        }
        if (self.framebuffer_fetch_supported) |supported| return supported;
        const supported = mtl.metal_device_supports_framebuffer_fetch(self.raw_device);
        self.framebuffer_fetch_supported = supported;
        return supported;
    }

    pub fn failNextBufferForTesting(self: *Device) void {
        if (comptime !@import("builtin").is_test) @compileError("test-only fault control");
        test_support.fail_buffer_device = @ptrCast(self.raw_device);
    }

    /// Print live GPU resources grouped by label and creating call site
    /// (no-op unless ZENIT_GPU_INVENTORY is set).
    pub fn dumpInventory(self: *Device, tag: [*:0]const u8) void {
        mtl.metal_inventory_dump(self.raw_device, tag);
    }

    /// Create Buffer. Note: returned Buffer doesn't need allocator free (Metal objects manage
    /// refcount); allocator parameter reserved for future extension (e.g., auxiliary structure
    /// allocation).
    pub noinline fn createBuffer(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.BufferDescriptor,
    ) !resources.Buffer {
        if (comptime @import("builtin").is_test) {
            if (test_support.fail_buffer_device == @as(*anyopaque, @ptrCast(self.raw_device))) {
                test_support.fail_buffer_device = null;
                return error.OutOfMemory;
            }
        }
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        const options = conv.toMetalResourceOptions(desc.usage);

        const buffer = mtl.metal_device_new_buffer(
            self.raw_device,
            desc.size,
            options,
        ) orelse return error.OutOfMemory;

        // Set label (if provided)
        if (desc.label) |label| {
            const z = allocator.dupeSentinel(u8, label, 0) catch null;
            if (z) |label_z| {
                defer allocator.free(label_z);
                mtl.metal_buffer_set_label(buffer, label_z);
            }
        }

        self.buffer_count += 1;
        mtl.metal_inventory_note(buffer, @ptrFromInt(@returnAddress()));

        return resources.Buffer{
            .raw = buffer,
            .size = desc.size,
            .usage = desc.usage,
        };
    }

    /// Create Texture
    pub noinline fn createTexture(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.TextureDescriptor,
    ) !resources.Texture {
        if (comptime test_support.enabled) {
            if (self.fail_next_texture_for_testing) {
                self.fail_next_texture_for_testing = false;
                return error.OutOfMemory;
            }
        }
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

        // Create descriptor
        const mtl_desc = mtl.metal_texture_descriptor_new() orelse
            return error.OutOfMemory;
        defer mtl.release(mtl_desc);

        // Configure
        mtl.metal_texture_descriptor_set_pixel_format(
            mtl_desc,
            @backingInt(conv.toMetalPixelFormat(desc.format)),
        );
        mtl.metal_texture_descriptor_set_width(mtl_desc, desc.size.width);
        mtl.metal_texture_descriptor_set_height(mtl_desc, desc.size.height);
        mtl.metal_texture_descriptor_set_depth(mtl_desc, desc.size.depth);
        mtl.metal_texture_descriptor_set_mipmap_level_count(mtl_desc, desc.mip_level_count);
        mtl.metal_texture_descriptor_set_sample_count(mtl_desc, desc.sample_count);
        mtl.metal_texture_descriptor_set_texture_type(
            mtl_desc,
            @backingInt(conv.toMetalTextureType(desc.dimension)),
        );
        mtl.metal_texture_descriptor_set_usage(
            mtl_desc,
            conv.toMetalTextureUsage(desc.usage, conv.needsPixelFormatView(desc)),
        );
        mtl.metal_texture_descriptor_set_storage_mode(
            mtl_desc,
            @backingInt(switch (desc.memory) {
                .device_local => mtl.MTLStorageMode.Private,
                .host_upload => mtl.MTLStorageMode.Shared,
            }),
        );

        if (conv.textureWriteCombined(desc)) mtl.metal_texture_descriptor_set_cpu_cache_write_combined(mtl_desc);

        // Create texture
        const texture = mtl.metal_device_new_texture(self.raw_device, mtl_desc) orelse
            return error.OutOfMemory;

        if (desc.label) |label| {
            const z = allocator.dupeSentinel(u8, label, 0) catch null;
            if (z) |label_z| {
                defer allocator.free(label_z);
                mtl.metal_texture_set_label(texture, label_z);
            }
        }

        self.texture_count += 1;
        mtl.metal_inventory_note(texture, @ptrFromInt(@returnAddress()));
        if (@import("zenit_environment").getBorrowed("ZENIT_DEBUG_TEXCREATE") != null) {
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
        mtl.metal_sampler_descriptor_set_min_filter(mtl_desc, @backingInt(conv.toMetalMinMagFilter(desc.min_filter)));
        mtl.metal_sampler_descriptor_set_mag_filter(mtl_desc, @backingInt(conv.toMetalMinMagFilter(desc.mag_filter)));
        mtl.metal_sampler_descriptor_set_mip_filter(mtl_desc, @backingInt(conv.toMetalMipFilter(desc.mipmap_filter)));
        mtl.metal_sampler_descriptor_set_address_mode_u(mtl_desc, @backingInt(conv.toMetalAddressMode(desc.address_mode_u)));
        mtl.metal_sampler_descriptor_set_address_mode_v(mtl_desc, @backingInt(conv.toMetalAddressMode(desc.address_mode_v)));
        mtl.metal_sampler_descriptor_set_address_mode_w(mtl_desc, @backingInt(conv.toMetalAddressMode(desc.address_mode_w)));
        mtl.metal_sampler_descriptor_set_lod_min_clamp(mtl_desc, desc.lod_min_clamp);
        mtl.metal_sampler_descriptor_set_lod_max_clamp(mtl_desc, desc.lod_max_clamp);
        mtl.metal_sampler_descriptor_set_max_anisotropy(mtl_desc, desc.max_anisotropy);
        if (desc.compare) |function| {
            mtl.metal_sampler_descriptor_set_compare_function(mtl_desc, conv.toMetalCompareFunction(function));
        }
        if (desc.label) |label| {
            const label_z = try allocator.dupeSentinel(u8, label, 0);
            defer allocator.free(label_z);
            mtl.metal_sampler_descriptor_set_label(mtl_desc, label_z);
        }

        const sampler = mtl.metal_device_new_sampler(self.raw_device, mtl_desc) orelse return error.OutOfMemory;
        self.sampler_count += 1;
        if (comptime test_support.enabled) self.samplers_live_for_testing += 1;
        return .{ .raw = sampler, .testing_live_count = if (test_support.enabled) &self.samplers_live_for_testing else {} };
    }

    /// Create RenderPipeline
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

    /// Destroy device
    pub fn deinit(self: *Device) void {
        if (comptime @import("builtin").is_test) {
            if (test_support.fail_buffer_device == @as(*anyopaque, @ptrCast(self.raw_device))) test_support.fail_buffer_device = null;
        }
        mtl.release(self.raw_device);
        // Print statistics (Debug mode)
        if (std.debug.runtime_safety) {
            std.debug.print("[Device] deinit: created {} buffers, {} textures, {} samplers\n", .{
                self.buffer_count,
                self.texture_count,
                self.sampler_count,
            });
        }
    }
};

// Placeholder type (implement in later phase)
pub const ShaderModule = struct {};
pub const RenderPipeline = struct {};
pub const ComputePipeline = struct {};
pub const CommandEncoder = struct {};
