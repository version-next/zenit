/// Type conversion module
///
/// Provides conversions between gpu.zig frontend types <-> Metal native types
/// Reference: wgpu-hal/src/metal/conv.rs
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");

// ============================================================================
// Texture Format Conversion
// ============================================================================

pub fn toMetalPixelFormat(format: gpu.TextureFormat) mtl.MTLPixelFormat {
    return switch (format) {
        // 8-bit formats
        .r8_unorm => .R8Unorm,
        .r8_snorm => .R8Snorm,
        .r8_uint => .R8Uint,
        .r8_sint => .R8Sint,

        // 16-bit formats
        .r16_uint => .R16Uint,
        .r16_sint => .R16Sint,
        .r16_float => .R16Float,
        .rg8_unorm => .RG8Unorm,
        .rg8_snorm => .RG8Snorm,
        .rg8_uint => .RG8Uint,
        .rg8_sint => .RG8Sint,

        // 32-bit formats
        .r32_uint => .R32Uint,
        .r32_sint => .R32Sint,
        .r32_float => .R32Float,
        .rg16_uint => .RG16Uint,
        .rg16_sint => .RG16Sint,
        .rg16_float => .RG16Float,
        .rgba8_unorm => .RGBA8Unorm,
        .rgba8_unorm_srgb => .RGBA8Unorm_sRGB,
        .rgba8_snorm => .RGBA8Snorm,
        .rgba8_uint => .RGBA8Uint,
        .rgba8_sint => .RGBA8Sint,
        .bgra8_unorm => .BGRA8Unorm,
        .bgra8_unorm_srgb => .BGRA8Unorm_sRGB,

        // 64-bit formats
        .rg32_uint => .RG32Uint,
        .rg32_sint => .RG32Sint,
        .rg32_float => .RG32Float,
        .rgba16_uint => .RGBA16Uint,
        .rgba16_sint => .RGBA16Sint,
        .rgba16_float => .RGBA16Float,

        // 128-bit formats
        .rgba32_uint => .RGBA32Uint,
        .rgba32_sint => .RGBA32Sint,
        .rgba32_float => .RGBA32Float,

        // Depth/stencil formats
        .depth16_unorm => .Depth16Unorm,
        .depth32_float => .Depth32Float,
        .stencil8 => .Stencil8,
        .depth32_float_stencil8 => .Depth32Float_Stencil8,

        // BC compressed formats
        .bc1_rgba_unorm => .BC1_RGBA,
        .bc1_rgba_unorm_srgb => .BC1_RGBA_sRGB,
        .bc2_rgba_unorm => .BC2_RGBA,
        .bc2_rgba_unorm_srgb => .BC2_RGBA_sRGB,
        .bc3_rgba_unorm => .BC3_RGBA,
        .bc3_rgba_unorm_srgb => .BC3_RGBA_sRGB,
        .bc4_r_unorm => .BC4_RUnorm,
        .bc4_r_snorm => .BC4_RSnorm,
        .bc5_rg_unorm => .BC5_RGUnorm,
        .bc5_rg_snorm => .BC5_RGSnorm,
        .bc6h_rgb_ufloat => .BC6H_RGBUfloat,
        .bc6h_rgb_float => .BC6H_RGBFloat,
        .bc7_rgba_unorm => .BC7_RGBAUnorm,
        .bc7_rgba_unorm_srgb => .BC7_RGBAUnorm_sRGB,

        // Metal unsupported formats, use nearest equivalent format.
        // depth24plus WebGPU semantics = "at least 24 bits, implementation-chosen"; Metal on
        // Apple Silicon has no D24, Depth32Float is standards-compliant (same as Dawn/wgpu),
        // not a fallback.
        .depth24_plus => .Depth32Float,
        .depth24_plus_stencil8 => .Depth32Float_Stencil8,
        // Metal natively supports RGB10A2; prior fallback to BGRA8 lost 10-bit depth (HDR/wide
        // color banding) and swapped channels RGB->BGR, undetected by caller.
        .rgb10a2_unorm => .RGB10A2Unorm,
    };
}

// ============================================================================
// Texture Type Conversion
// ============================================================================

pub fn toMetalTextureType(dimension: gpu.TextureDimension) mtl.MTLTextureType {
    return switch (dimension) {
        .@"1d" => .Type1D,
        .@"2d" => .Type2D,
        .@"3d" => .Type3D,
    };
}

// ============================================================================
// Texture Usage Conversion
// ============================================================================

/// `pixel_format_view` must be true only for textures that will be viewed or
/// reinterpreted with another pixel format (`TextureDescriptor.view_formats`).
/// MTLTextureUsagePixelFormatView prevents the driver from using lossless
/// compression on Private render targets, so it is never added implicitly.
pub fn toMetalTextureUsage(usage: gpu.TextureUsages, pixel_format_view: bool) c_ulong {
    var result: c_ulong = 0;

    if (usage.texture_binding) {
        result |= @backingInt(mtl.MTLTextureUsage.ShaderRead);
    }
    if (usage.storage_binding) {
        result |= @backingInt(mtl.MTLTextureUsage.ShaderWrite);
    }
    if (usage.render_attachment) {
        result |= @backingInt(mtl.MTLTextureUsage.RenderTarget);
    }

    if (pixel_format_view) {
        result |= @backingInt(mtl.MTLTextureUsage.PixelFormatView);
    }

    return result;
}

// ============================================================================
// Buffer Usage Conversion
// ============================================================================

pub fn toMetalResourceOptions(usage: gpu.BufferUsages) mtl.MTLResourceOptions {
    // Determine storage mode
    const storage_mode: mtl.MTLStorageMode = if (usage.map_read or usage.map_write)
        .Shared // CPU visible
    else
        .Private; // GPU only (fastest)

    var options = mtl.resourceOptionsFromStorageMode(storage_mode);
    // Upload-only streams (instances, uniforms, vertices): write-combined
    // avoids CPU cache pollution and snooping. Read-back buffers keep caching.
    if (usage.map_write and !usage.map_read) options |= mtl.MTLResourceCPUCacheModeWriteCombined;
    return options;
}

/// Write-combined CPU mapping applies only to host textures declared write-only.
pub fn textureWriteCombined(desc: gpu.TextureDescriptor) bool {
    return desc.memory == .host_upload and desc.host_access == .write_only;
}

test "only CPU write-only resources are write-combined" {
    const testing = @import("std").testing;
    const wc = mtl.MTLResourceCPUCacheModeWriteCombined;
    try testing.expectEqual(wc, toMetalResourceOptions(.{ .vertex = true, .map_write = true }) & wc);
    try testing.expectEqual(@as(mtl.MTLResourceOptions, 0), toMetalResourceOptions(.{ .map_read = true, .copy_dst = true }) & wc);
    try testing.expectEqual(@as(mtl.MTLResourceOptions, 0), toMetalResourceOptions(.{ .map_read = true, .map_write = true }) & wc);
    try testing.expectEqual(@as(mtl.MTLResourceOptions, 0), toMetalResourceOptions(.{ .vertex = true }) & wc);
    const size: gpu.Extent3D = .{ .width = 4, .height = 4 };
    const usage: gpu.TextureUsages = .{ .texture_binding = true, .copy_dst = true };
    try testing.expect(textureWriteCombined(.{ .size = size, .format = .r8_unorm, .usage = usage, .memory = .host_upload, .host_access = .write_only }));
    try testing.expect(!textureWriteCombined(.{ .size = size, .format = .r8_unorm, .usage = usage, .memory = .host_upload }));
    try testing.expect(!textureWriteCombined(.{ .size = size, .format = .r8_unorm, .usage = usage, .host_access = .write_only }));
}

// ============================================================================
// Sampler conversion
// ============================================================================

pub fn toMetalMinMagFilter(filter: gpu.FilterMode) mtl.MTLSamplerMinMagFilter {
    return switch (filter) {
        .nearest => .Nearest,
        .linear => .Linear,
    };
}

pub fn toMetalMipFilter(filter: gpu.MipmapFilterMode) mtl.MTLSamplerMipFilter {
    return switch (filter) {
        .nearest => .Nearest,
        .linear => .Linear,
    };
}

pub fn toMetalAddressMode(mode: gpu.AddressMode) mtl.MTLSamplerAddressMode {
    return switch (mode) {
        .clamp_to_edge => .ClampToEdge,
        .repeat => .Repeat,
        .mirror_repeat => .MirrorRepeat,
        .clamp_to_border => .ClampToBorderColor,
    };
}

pub fn toMetalCompareFunction(function: gpu.CompareFunction) c_ulong {
    return switch (function) {
        .never => 0,
        .less => 1,
        .equal => 2,
        .less_equal => 3,
        .greater => 4,
        .not_equal => 5,
        .greater_equal => 6,
        .always => 7,
    };
}

/// True when a texture created with `desc` may be viewed in a pixel format
/// other than its own. Views in the texture's own format need no flag.
pub fn needsPixelFormatView(desc: gpu.TextureDescriptor) bool {
    for (desc.view_formats) |format| {
        if (format != desc.format) return true;
    }
    return false;
}

test "texture usage adds PixelFormatView only for declared foreign view formats" {
    const testing = @import("std").testing;
    const pfv: c_ulong = @backingInt(mtl.MTLTextureUsage.PixelFormatView);
    const usage: gpu.TextureUsages = .{ .texture_binding = true, .render_attachment = true, .storage_binding = true };
    const base: gpu.TextureDescriptor = .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .usage = usage };
    try testing.expect(!needsPixelFormatView(base));
    try testing.expectEqual(@as(c_ulong, 0), toMetalTextureUsage(usage, needsPixelFormatView(base)) & pfv);
    var same = base;
    same.view_formats = &.{.bgra8_unorm};
    try testing.expect(!needsPixelFormatView(same));
    var foreign = base;
    foreign.view_formats = &.{ .bgra8_unorm, .bgra8_unorm_srgb };
    try testing.expect(needsPixelFormatView(foreign));
    try testing.expectEqual(pfv, toMetalTextureUsage(usage, needsPixelFormatView(foreign)) & pfv);
}

test "sampler descriptor enums map without leaking Metal values to callers" {
    const testing = @import("std").testing;
    try testing.expectEqual(mtl.MTLSamplerMinMagFilter.Linear, toMetalMinMagFilter(.linear));
    try testing.expectEqual(mtl.MTLSamplerMipFilter.Nearest, toMetalMipFilter(.nearest));
    try testing.expectEqual(mtl.MTLSamplerAddressMode.ClampToBorderColor, toMetalAddressMode(.clamp_to_border));
    try testing.expectEqual(@as(c_ulong, 6), toMetalCompareFunction(.greater_equal));
}

// ============================================================================
// Size Conversion
// ============================================================================
