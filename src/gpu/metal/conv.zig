/// 类型转换模块
///
/// 提供 gpu.zig 前端类型 <-> Metal 原生类型的转换
/// 参考: wgpu-hal/src/metal/conv.rs
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

        // Metal 不支持的格式，使用最近的等价格式。
        // depth24plus 的 WebGPU 语义就是"至少 24 位、实现自选"，Metal 在
        // Apple Silicon 上本就无 D24, Depth32Float 是规范授权的合规实现
        // （Dawn/wgpu 同此），不是降级。
        .depth24_plus => .Depth32Float,
        .depth24_plus_stencil8 => .Depth32Float_Stencil8,
        // Metal 原生支持 RGB10A2；此前占位回退到 BGRA8, 10 位掉 8 位
        // （HDR/宽色域 banding）且通道序 RGB->BGR，调用方毫无感知。
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

pub fn toMetalTextureUsage(usage: gpu.TextureUsages) c_ulong {
    var result: c_ulong = 0;

    if (usage.texture_binding) {
        result |= @intFromEnum(mtl.MTLTextureUsage.ShaderRead);
    }
    if (usage.storage_binding) {
        result |= @intFromEnum(mtl.MTLTextureUsage.ShaderWrite);
    }
    if (usage.render_attachment) {
        result |= @intFromEnum(mtl.MTLTextureUsage.RenderTarget);
    }

    // Metal 总是允许 PixelFormatView
    result |= @intFromEnum(mtl.MTLTextureUsage.PixelFormatView);

    return result;
}

// ============================================================================
// Buffer Usage Conversion
// ============================================================================

pub fn toMetalResourceOptions(usage: gpu.BufferUsages) mtl.MTLResourceOptions {
    // 判断存储模式
    const storage_mode: mtl.MTLStorageMode = if (usage.map_read or usage.map_write)
        .Shared // CPU 可见
    else
        .Private; // 仅 GPU（最快）

    return mtl.resourceOptionsFromStorageMode(storage_mode);
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
