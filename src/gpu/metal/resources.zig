/// Metal resource types
///
/// Define Buffer, Texture, TextureView, Sampler etc Metal implementation
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const test_support = @import("test_support.zig");

// ============================================================================
// Buffer
// ============================================================================

pub const Buffer = struct {
    raw: *mtl.MTLBuffer,
    size: u64,
    usage: gpu.BufferUsages,

    pub fn getMappedRange(self: *Buffer, offset: u64, size: u64) ![]u8 {
        if (!self.usage.map_read and !self.usage.map_write) {
            return error.BufferNotMappable;
        }

        // Boundary check: prevent out-of-bounds access
        if (size == 0) return error.BufferNotMapped;
        if (offset > self.size or size > self.size - offset) {
            return error.BufferNotMapped;
        }

        const contents = mtl.metal_buffer_contents(self.raw) orelse return error.BufferNotMapped;
        const ptr: [*]u8 = @ptrCast(@alignCast(contents));
        return ptr[offset .. offset + size];
    }

    pub fn unmap(self: *Buffer) void {
        // Metal Shared mode needs no explicit unmap
        _ = self;
    }

    /// See `Texture.setVolatile`.
    pub fn setVolatile(self: *Buffer, make_volatile: bool) bool {
        return mtl.metal_resource_set_volatile(@ptrCast(self.raw), @intFromBool(make_volatile)) != 0;
    }

    pub fn destroyCountForTesting() usize {
        if (comptime !@import("builtin").is_test) @compileError("test-only ownership counter");
        return test_support.buffer_destroy_count;
    }

    pub fn destroy(self: *Buffer) void {
        if (comptime @import("builtin").is_test) test_support.buffer_destroy_count += 1;
        mtl.release(self.raw);
    }
};

// ============================================================================
// Texture
// ============================================================================

pub const Texture = struct {
    raw: *mtl.MTLTexture,
    format: gpu.TextureFormat,
    size: gpu.Extent3D,
    mip_level_count: u32,
    dimension: gpu.TextureDimension,
    memory: gpu.TextureMemory,

    /// Upload a tightly or explicitly strided 2D region to a mip level.
    /// Device-local textures require an explicit staging/copy path instead.
    pub fn writeRegion(
        self: *Texture,
        mip_level: u32,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        bytes: []const u8,
        bytes_per_row: u32,
    ) !void {
        if (self.memory != .host_upload) return error.TextureNotHostWritable;
        if (width == 0 or height == 0 or mip_level >= self.mip_level_count) return error.InvalidTextureRegion;
        const mip_width = @max(@as(u32, 1), self.size.width >> @intCast(mip_level));
        const mip_height = @max(@as(u32, 1), self.size.height >> @intCast(mip_level));
        if (x > mip_width or width > mip_width - x or y > mip_height or height > mip_height - y) {
            return error.InvalidTextureRegion;
        }
        const required = @as(usize, bytes_per_row) * @as(usize, height);
        if (bytes_per_row < minimumUploadRowBytes(self.format, width) or bytes.len < required)
            return error.InvalidTextureData;
        mtl.metal_texture_replace_region_level(
            self.raw,
            x,
            y,
            width,
            height,
            mip_level,
            bytes.ptr,
            bytes_per_row,
        );
    }

    /// Read a BGRA8 region into caller-owned memory. The texture must have been
    /// created/configured with backend readback usage (surface drawables use
    /// `color_target_and_read`); unsupported storage modes fail at the backend.
    pub fn readBgra8(self: *const Texture, width: u32, height: u32, bytes: []u8, bytes_per_row: u32) !void {
        if (self.format != .bgra8_unorm and self.format != .bgra8_unorm_srgb) return error.UnsupportedTextureFormat;
        if (width == 0 or height == 0 or width > self.size.width or height > self.size.height) {
            return error.InvalidTextureRegion;
        }
        const required = @as(usize, bytes_per_row) * @as(usize, height);
        if (bytes_per_row < width * 4 or bytes.len < required) return error.InvalidTextureData;
        if (mtl.metal_texture_read_bgra8(self.raw, bytes.ptr, bytes_per_row, width, height) == 0) {
            return error.TextureReadFailed;
        }
    }

    /// Opaque backend handle used only by the test-mode video encoder. The
    /// renderer never interprets or owns the Objective-C texture object.
    pub fn nativeHandleForRecording(self: *const Texture) ?*anyopaque {
        return @ptrCast(self.raw);
    }

    /// Volatile storage leaves the process footprint while idle and may be
    /// discarded under memory pressure. Making it non-volatile again returns
    /// true when the contents were discarded and must be regenerated. Only
    /// toggle storage no submitted command is still using.
    pub fn setVolatile(self: *Texture, make_volatile: bool) bool {
        return mtl.metal_resource_set_volatile(@ptrCast(self.raw), @intFromBool(make_volatile)) != 0;
    }

    pub fn destroy(self: *Texture) void {
        mtl.release(self.raw);
    }

    /// Test-only: build a Texture with metadata only, no real GPU resource.
    ///
    /// `src/render` bookkeeping tests (e.g., offscreen pool retained semantics) need a Texture
    /// value but **shouldn't know the backend field layout** (hand-written `.raw = undefined`
    /// literals break when the backend switches). Each backend provides a constructor, so tests
    /// depend only on the neutral capability "make a fake texture of this size".
    ///
    /// The returned value is unusable for real GPU ops; `destroy` is also unusable.
    pub fn fakeForTesting(width: u32, height: u32, format: gpu.TextureFormat) Texture {
        return .{
            .raw = undefined,
            .format = format,
            .size = .{ .width = width, .height = height },
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
        };
    }

    pub fn binding(self: *const Texture) TextureBinding {
        return .{
            .raw = self.raw,
            .width = self.size.width,
            .height = self.size.height,
        };
    }
};

/// Match Metal's physical texel/block storage (depth24_plus maps to depth32).
/// Widen before multiplication so an invalid, oversized row cannot wrap.
fn minimumUploadRowBytes(format: gpu.TextureFormat, width: u32) usize {
    const w: usize = width;
    return switch (format) {
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint, .stencil8 => w,
        .r16_uint, .r16_sint, .r16_float, .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint, .depth16_unorm => w * 2,
        .r32_uint, .r32_sint, .r32_float, .rg16_uint, .rg16_sint, .rg16_float, .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_snorm, .rgba8_uint, .rgba8_sint, .bgra8_unorm, .bgra8_unorm_srgb, .rgb10a2_unorm, .depth24_plus, .depth32_float => w * 4,
        .rg32_uint, .rg32_sint, .rg32_float, .rgba16_uint, .rgba16_sint, .rgba16_float, .depth24_plus_stencil8, .depth32_float_stencil8 => w * 8,
        .rgba32_uint, .rgba32_sint, .rgba32_float => w * 16,
        .bc1_rgba_unorm, .bc1_rgba_unorm_srgb, .bc4_r_unorm, .bc4_r_snorm => ((w + 3) / 4) * 8,
        .bc2_rgba_unorm, .bc2_rgba_unorm_srgb, .bc3_rgba_unorm, .bc3_rgba_unorm_srgb, .bc5_rg_unorm, .bc5_rg_snorm, .bc6h_rgb_ufloat, .bc6h_rgb_float, .bc7_rgba_unorm, .bc7_rgba_unorm_srgb => ((w + 3) / 4) * 16,
    };
}

/// Non-owning texture reference suitable for command binding. It cannot destroy
/// the underlying resource, so renderer batching cannot accidentally duplicate
/// ownership while copying bindings.
pub const TextureBinding = struct {
    raw: *mtl.MTLTexture,
    width: u32,
    height: u32,

    pub fn eql(self: TextureBinding, other: TextureBinding) bool {
        return self.raw == other.raw;
    }

    pub fn samePixelFormat(self: TextureBinding, other: TextureBinding) bool {
        return mtl.metal_texture_pixel_format(self.raw) == mtl.metal_texture_pixel_format(other.raw);
    }

    pub fn createView(self: TextureBinding) TextureView {
        return .{ .raw = mtl.retain(self.raw) };
    }

    /// Backend-neutral test constructor. `token` needs only comparable (renderer's only dependency
    /// `eql`), backends choose which field; tests thus unaware of concrete representation. Produced
    /// binding doesn't reference real texture, only for CPU-only tests not dereferencing it.
    pub fn testBinding(token: u64, width: u32, height: u32) TextureBinding {
        return .{ .raw = @ptrFromInt(token), .width = width, .height = height };
    }
};

// ============================================================================
// TextureView
// ============================================================================

pub const TextureView = struct {
    raw: *mtl.MTLTexture,

    pub fn destroy(self: *TextureView) void {
        mtl.release(self.raw);
    }
};

// ============================================================================
// Sampler
// ============================================================================

pub const Sampler = struct {
    raw: *mtl.MTLSamplerState,
    testing_live_count: if (test_support.enabled) ?*usize else void = if (test_support.enabled) null else {},

    pub fn destroy(self: *Sampler) void {
        mtl.release(self.raw);
        if (comptime test_support.enabled) {
            if (self.testing_live_count) |count| {
                count.* -= 1;
                self.testing_live_count = null;
            }
        }
    }
};
