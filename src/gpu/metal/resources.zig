/// Metal 资源类型
///
/// 定义 Buffer, Texture, TextureView, Sampler 等资源的 Metal 实现
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");

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

        // 边界检查：防止越界访问
        if (size == 0) return error.BufferNotMapped;
        if (offset > self.size or size > self.size - offset) {
            return error.BufferNotMapped;
        }

        const contents = mtl.metal_buffer_contents(self.raw) orelse return error.BufferNotMapped;
        const ptr: [*]u8 = @ptrCast(@alignCast(contents));
        return ptr[offset .. offset + size];
    }

    pub fn unmap(self: *Buffer) void {
        // Metal Shared 模式不需要显式 unmap
        _ = self;
    }

    pub fn destroy(self: *Buffer) void {
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
        if (bytes_per_row == 0 or bytes.len < required) return error.InvalidTextureData;
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

    pub fn destroy(self: *Texture) void {
        mtl.release(self.raw);
    }

    /// 仅供测试：构造一个只有元数据、没有真实 GPU 资源的 Texture。
    ///
    /// 存在的理由是抽象边界：`src/render` 的簿记类测试（如 offscreen 池的
    /// retained 语义）需要一个 Texture 值，但**不应该知道后端的字段布局**。
    /// 从前它直接写 `.raw = undefined` 字面量，于是换后端就编译不过——这是
    /// C1 抓出的三个抽象泄漏之一。改由后端各自提供构造器后，测试只依赖
    /// 「能造一个指定尺寸的假纹理」这个中立能力。
    ///
    /// 返回值不可用于任何真实 GPU 操作；`destroy` 亦不可调用。
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

    pub fn createView(self: TextureBinding) TextureView {
        return .{ .raw = mtl.retain(self.raw) };
    }

    /// 后端中立的测试构造器。`token` 只需可比较（`eql` 是渲染器唯一依赖的
    /// 性质），各后端自行决定塞进哪个字段——测试因此不必知道具体后端表示。
    /// 产出的 binding 不指向真实纹理，只能用于不解引用它的纯 CPU 测试。
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

    pub fn destroy(self: *Sampler) void {
        mtl.release(self.raw);
    }
};
