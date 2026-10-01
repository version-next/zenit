//! Null Backend，无设备的确定性参考实现。
//!
//! ## 它存在的理由
//!
//! `gpu.Backend` 曾经是 `@import("metal/backend.zig")` 这一个编译期 alias。
//! 只有一个实现时，没人能回答这个问题：`gpu.Backend.*` 的签名到底是
//! backend-neutral 的，还是无意中把 Metal 语义焊死在了里面？
//!
//! 本后端就是那个答案。它**与 Metal 后端共用同一份渲染器代码**,
//! `src/render`、`src/ui`、`src/zenit_app` 一行不改，只把 `-Dgpu-backend=null`
//! 打开。能编译通过，抽象才算被证伪过一次；编译不过的地方，就是抽象漏了。
//!
//! 写这个实现的过程本身已经抓出三个真实泄漏（见
//! `docs/internal/RHI_SECOND_BACKEND_ASSESSMENT.md`），其中
//! `Surface.init(*CAMetalLayer)` 是硬阻塞，已改成 `*anyopaque`。
//!
//! ## 它验证什么、不验证什么
//!
//! **验证**：符号完整性、签名兼容性、资源生命周期（分配/释放配对）、
//! pass 嵌套与类型（render/blit 不可交错）、stale pass 拒绝。
//!
//! **不验证**：像素。这里不做光栅化。像素正确性永远是 Metal 集成测试与
//! 真窗口 E2E 的责任（同 `RENDERER_RHI_PLAN.md` §6 对 Null/Reference 的定位）。
const std = @import("std");
const gpu = @import("../gpu.zig");

/// 进程级分配器。Null 后端的资源是真实内存（这样 `getMappedRange` 返回的
/// 切片可以被真的写入，渲染器的 flush 路径才能跑到底），但不涉及 GPU。
const alloc = std.heap.page_allocator;

/// 每像素字节数。`gpu.TextureFormat` 本身不带这个查询（Metal 后端靠
/// `conv.zig` 转成 MTLPixelFormat 后由 Metal 负责），Null 后端要自己算
/// 分配大小，故在此补一张最小映射表，只覆盖渲染器实际用到的格式。
fn bytesPerPixel(format: gpu.TextureFormat) u32 {
    return switch (format) {
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint => 1,
        .r16_uint, .r16_sint, .r16_float, .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint => 2,
        .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_snorm, .rgba8_uint, .rgba8_sint, .bgra8_unorm, .bgra8_unorm_srgb, .r32_float, .r32_uint, .r32_sint, .rg16_uint, .rg16_sint, .rg16_float => 4,
        .rg32_float, .rg32_uint, .rg32_sint, .rgba16_uint, .rgba16_sint, .rgba16_float => 8,
        .rgba32_float, .rgba32_uint, .rgba32_sint => 16,
        else => 4,
    };
}

// ============================================================================
// 诊断计数器，让"抽象被跑过"这件事可观测
// ============================================================================

/// 跨后端一致的实例统计。测试用它断言资源被成对释放（泄漏检测）。
pub var stats: Stats = .{};

pub const Stats = struct {
    buffers_created: u64 = 0,
    buffers_destroyed: u64 = 0,
    textures_created: u64 = 0,
    textures_destroyed: u64 = 0,
    samplers_created: u64 = 0,
    render_passes: u64 = 0,
    blit_passes: u64 = 0,
    draws: u64 = 0,
    submits: u64 = 0,

    pub fn reset() void {
        stats = .{};
    }

    /// 资源是否收支平衡。用于断言渲染器没漏资源。
    pub fn balanced() bool {
        return stats.buffers_created == stats.buffers_destroyed and
            stats.textures_created == stats.textures_destroyed;
    }
};

// ============================================================================
// 资源
// ============================================================================

pub const Buffer = struct {
    bytes: []u8,
    size: u64,

    pub fn getMappedRange(self: *Buffer, offset: u64, size: u64) ![]u8 {
        // 与 Metal 后端同样的边界语义：越界是错误而不是 UB。这条断言在
        // Null 后端下是**确定性可测**的，Metal 下则依赖真实设备。
        if (offset + size > self.size) return error.OutOfBounds;
        return self.bytes[@intCast(offset)..@intCast(offset + size)];
    }

    pub fn destroy(self: *Buffer) void {
        alloc.free(self.bytes);
        self.bytes = &.{};
        stats.buffers_destroyed += 1;
    }

    pub fn deinit(self: *Buffer) void {
        self.destroy();
    }
};

pub const TextureBinding = struct {
    /// 不透明标识。Metal 后端这里是 `*MTLTexture`；Null 后端用一个单调 id，
    /// 语义上只需要"可比较", `eql` 是渲染器唯一依赖的性质。
    id: u64,
    width: u32,
    height: u32,

    pub fn eql(self: TextureBinding, other: TextureBinding) bool {
        return self.id == other.id;
    }

    pub fn createView(self: TextureBinding) TextureView {
        return .{ .id = self.id };
    }

    /// 见 Metal 后端同名函数：后端中立的测试构造器。
    pub fn testBinding(token: u64, width: u32, height: u32) TextureBinding {
        return .{ .id = token, .width = width, .height = height };
    }
};

pub const TextureView = struct {
    id: u64,

    pub fn destroy(self: *TextureView) void {
        self.id = 0;
    }
};

var next_texture_id: u64 = 1;

pub const Texture = struct {
    id: u64,
    bytes: []u8,
    format: gpu.TextureFormat,
    size: gpu.Extent3D,
    mip_level_count: u32,
    dimension: gpu.TextureDimension,
    memory: gpu.TextureMemory,

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
        _ = mip_level;
        // 与 Metal 后端一致：device-local 纹理不可直接写。保留这条错误，
        // 渲染器里依赖它的分支才能在 Null 后端下被覆盖到。
        if (self.memory != .host_upload) return error.TextureNotHostWritable;
        if (width == 0 or height == 0) return;
        if (x + width > self.size.width or y + height > self.size.height)
            return error.InvalidTextureRegion;
        const bpp = bytesPerPixel(self.format);
        const dst_stride = self.size.width * bpp;
        var row: u32 = 0;
        while (row < height) : (row += 1) {
            const src_off = row * bytes_per_row;
            const dst_off = (y + row) * dst_stride + x * bpp;
            const len = width * bpp;
            if (src_off + len > bytes.len) return error.InvalidTextureRegion;
            @memcpy(self.bytes[dst_off .. dst_off + len], bytes[src_off .. src_off + len]);
        }
    }

    pub fn readBgra8(self: *const Texture, width: u32, height: u32, bytes: []u8, bytes_per_row: u32) !void {
        const bpp = bytesPerPixel(self.format);
        const stride = self.size.width * bpp;
        var row: u32 = 0;
        while (row < @min(height, self.size.height)) : (row += 1) {
            const dst_off = row * bytes_per_row;
            const src_off = row * stride;
            const len = @min(@min(stride, bytes_per_row), width * bpp);
            if (dst_off + len > bytes.len) return;
            @memcpy(bytes[dst_off .. dst_off + len], self.bytes[src_off .. src_off + len]);
        }
    }

    pub fn nativeHandleForRecording(self: *const Texture) ?*anyopaque {
        _ = self;
        return null;
    }

    /// 仅供测试：构造只有元数据的假纹理（与 Metal 后端同名同义）。
    /// `bytes` 为空切片，故 `destroy` 不会误 free。
    pub fn fakeForTesting(width: u32, height: u32, format: gpu.TextureFormat) Texture {
        const id = next_texture_id;
        next_texture_id += 1;
        return .{
            .id = id,
            .bytes = &.{},
            .format = format,
            .size = .{ .width = width, .height = height },
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
        };
    }

    pub fn binding(self: *const Texture) TextureBinding {
        return .{ .id = self.id, .width = self.size.width, .height = self.size.height };
    }

    pub fn destroy(self: *Texture) void {
        if (self.bytes.len > 0) {
            alloc.free(self.bytes);
            self.bytes = &.{};
            stats.textures_destroyed += 1;
        }
    }

    pub fn deinit(self: *Texture) void {
        self.destroy();
    }
};

pub const Sampler = struct {
    id: u64,

    pub fn destroy(self: *Sampler) void {
        self.id = 0;
    }

    pub fn deinit(self: *Sampler) void {
        self.destroy();
    }
};

// ============================================================================
// Device / Queue / Instance / Adapter
// ============================================================================

pub const Device = struct {
    features: gpu.Features = .{},
    limits: gpu.Limits = .{},
    buffer_count: usize = 0,
    texture_count: usize = 0,
    sampler_count: usize = 0,

    pub fn createBuffer(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.BufferDescriptor,
    ) !Buffer {
        _ = allocator;
        if (desc.size == 0) return error.InvalidDescriptor;
        const bytes = try alloc.alloc(u8, @intCast(desc.size));
        @memset(bytes, 0);
        self.buffer_count += 1;
        stats.buffers_created += 1;
        return .{ .bytes = bytes, .size = desc.size };
    }

    pub fn createTexture(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.TextureDescriptor,
    ) !Texture {
        _ = allocator;
        if (desc.size.width == 0 or desc.size.height == 0) return error.InvalidDescriptor;
        if (desc.size.width > self.limits.max_texture_dimension_2d or
            desc.size.height > self.limits.max_texture_dimension_2d)
            return error.InvalidDescriptor;
        const bpp = bytesPerPixel(desc.format);
        const bytes = try alloc.alloc(u8, @as(usize, desc.size.width) * desc.size.height * bpp);
        @memset(bytes, 0);
        const id = next_texture_id;
        next_texture_id += 1;
        self.texture_count += 1;
        stats.textures_created += 1;
        return .{
            .id = id,
            .bytes = bytes,
            .format = desc.format,
            .size = desc.size,
            .mip_level_count = desc.mip_level_count,
            .dimension = desc.dimension,
            .memory = desc.memory,
        };
    }

    pub fn createSampler(
        self: *Device,
        allocator: std.mem.Allocator,
        desc: gpu.SamplerDescriptor,
    ) !Sampler {
        _ = allocator;
        _ = desc;
        self.sampler_count += 1;
        stats.samplers_created += 1;
        return .{ .id = 1 };
    }

    pub fn deinit(self: *Device) void {
        self.* = .{};
    }
};

pub const Queue = struct {
    pub fn deinit(self: *Queue) void {
        _ = self;
    }
};

pub const Adapter = struct {
    pub fn requestDevice(
        self: *Adapter,
        allocator: std.mem.Allocator,
        desc: anytype,
    ) !struct { device: Device, queue: Queue } {
        _ = self;
        _ = allocator;
        _ = desc;
        return .{ .device = .{}, .queue = .{} };
    }

    pub fn deinit(self: *Adapter) void {
        _ = self;
    }
};

pub const Instance = struct {
    adapters_storage: [1]Adapter = .{.{}},

    pub fn init(allocator: std.mem.Allocator, desc: anytype) !Instance {
        _ = allocator;
        _ = desc;
        return .{};
    }

    pub fn enumerateAdapters(self: *Instance) ![]Adapter {
        return self.adapters_storage[0..];
    }

    pub fn deinit(self: *Instance) void {
        _ = self;
    }
};

// ============================================================================
// Pipeline
// ============================================================================

pub const ShaderFunction = struct {
    /// 函数名的稳定副本。Metal 后端这里是 `*MTLFunction`；Null 后端保留名字，
    /// 让 pipeline 创建能做出有意义的区分（也顺带证明按"名字"而非"对象地址"
    /// 标识 shader 是可行的，见 pipeline.zig 里 PSO 缓存翻车的教训）。
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,

    pub fn deinit(self: *ShaderFunction) void {
        self.name_len = 0;
    }
};

pub const ShaderModule = struct {
    /// 源码长度。Null 后端不编译 MSL，它只需要证明"模块->函数"的生命周期
    /// 契约成立。真正的第二个**图形**后端才需要另一套 shader 源，那是比
    /// 本任务大得多的工程（见 RHI_SECOND_BACKEND_ASSESSMENT.md §四）。
    source_len: usize,

    pub fn initFromSource(device: *Device, source: []const u8) !ShaderModule {
        _ = device;
        if (source.len == 0) return error.ShaderCompilationFailed;
        return .{ .source_len = source.len };
    }

    pub fn getFunction(self: *ShaderModule, name: []const u8) !ShaderFunction {
        _ = self;
        if (name.len == 0 or name.len > 64) return error.FunctionNotFound;
        var f = ShaderFunction{};
        @memcpy(f.name[0..name.len], name);
        f.name_len = name.len;
        return f;
    }

    pub fn deinit(self: *ShaderModule) void {
        self.source_len = 0;
    }
};

pub const RenderPipeline = struct {
    id: u64,

    pub fn deinit(self: *RenderPipeline) void {
        self.id = 0;
    }
};

/// 与 Metal 后端逐字段对齐的描述符族。刻意各后端自带一份而非放进 gpu.zig：
/// 它们含 `?*const ShaderFunction` 这种**后端自有类型**的引用，无法中立化。
pub const BlendFactor = enum(c_ulong) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    src_alpha = 4,
    one_minus_src_alpha = 5,
    dst_color = 6,
    one_minus_dst_color = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    src_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
};

pub const BlendOperation = enum(c_ulong) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

pub const BlendState = struct {
    source_rgb: BlendFactor = .one,
    destination_rgb: BlendFactor = .zero,
    rgb_operation: BlendOperation = .add,
    source_alpha: BlendFactor = .one,
    destination_alpha: BlendFactor = .zero,
    alpha_operation: BlendOperation = .add,

    pub const ALPHA_BLENDING = BlendState{
        .source_rgb = .src_alpha,
        .destination_rgb = .one_minus_src_alpha,
        .rgb_operation = .add,
        .source_alpha = .one,
        .destination_alpha = .one_minus_src_alpha,
        .alpha_operation = .add,
    };
};

pub const VertexAttributeDescriptor = struct {
    format: gpu.VertexFormat,
    offset: u64,
    shader_location: u32,
};

pub const VertexBufferLayoutDescriptor = struct {
    stride: u64,
    step_mode: gpu.VertexStepMode = .vertex,
    attributes: []const VertexAttributeDescriptor,
};

pub const RenderPipelineDescriptor = struct {
    vertex_function: ?*const ShaderFunction = null,
    fragment_function: ?*const ShaderFunction = null,
    color_attachment_formats: []const gpu.TextureFormat = &.{},
    depth_attachment_format: ?gpu.TextureFormat = null,
    stencil_attachment_format: ?gpu.TextureFormat = null,
    sample_count: u32 = 1,
    vertex_buffers: []const VertexBufferLayoutDescriptor = &.{},
    blend_state: ?BlendState = null,
};

var next_pipeline_id: u64 = 1;

pub fn createRenderPipeline(device: *Device, desc: RenderPipelineDescriptor) !RenderPipeline {
    _ = device;
    _ = desc;
    const id = next_pipeline_id;
    next_pipeline_id += 1;
    return .{ .id = id };
}

// ============================================================================
// 命令编码，pass 状态机是本后端最有价值的部分
// ============================================================================

const PassKind = enum { none, render, blit };

/// 与 Metal 后端同构的 pass 状态机。
///
/// Metal 后端靠 `generation` 拒绝 stale pass（ObjC 对象地址会被立即复用，
/// 那正是 GlassBox blit crash 的根因）。Null 后端复刻同一套语义，于是这条
/// 不变式可以在**无设备的确定性测试**里被验证，而不必依赖真窗口 E2E。
pub const CommandEncoder = struct {
    state: PassKind = .none,
    next_generation: u64 = 1,
    active_generation: u64 = 0,
    finished: bool = false,

    pub fn init(queue: *Queue) !CommandEncoder {
        _ = queue;
        return .{};
    }

    fn activate(self: *CommandEncoder, kind: PassKind) u64 {
        std.debug.assert(self.state == .none);
        const g = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        self.active_generation = g;
        self.state = kind;
        return g;
    }

    fn close(self: *CommandEncoder, kind: PassKind, generation: u64) void {
        if (self.state != kind or self.active_generation != generation)
            @panic("stale or wrong-kind GPU pass used after its lifetime ended");
        self.state = .none;
        self.active_generation = 0;
    }

    fn isActive(self: *const CommandEncoder, kind: PassKind, generation: u64) bool {
        return self.state == kind and self.active_generation == generation;
    }

    pub fn beginRenderPass(self: *CommandEncoder, desc: gpu.RenderPassDescriptor) !RenderPass {
        if (self.state != .none) return error.InvalidEncoderState;
        _ = desc;
        const g = self.activate(.render);
        stats.render_passes += 1;
        return .{ .command_encoder = self, .generation = g };
    }

    pub fn beginBlitPass(self: *CommandEncoder) !BlitPass {
        if (self.state != .none) return error.InvalidEncoderState;
        const g = self.activate(.blit);
        stats.blit_passes += 1;
        return .{ .command_encoder = self, .generation = g };
    }

    pub fn finish(self: *CommandEncoder) !CommandBuffer {
        if (self.finished) return error.EncoderAlreadyFinished;
        if (self.state != .none) return error.InvalidEncoderState;
        self.finished = true;
        return .{};
    }

    pub fn deinit(self: *CommandEncoder) void {
        _ = self;
    }
};

pub const RenderPass = struct {
    command_encoder: *CommandEncoder,
    generation: u64,

    /// 与 Metal 后端同名同类型的类型级计数器（`src/render/command_encoder.zig`
    /// 每帧把它清零）。跨后端必须存在，否则渲染器编译不过。
    pub var frame_draw_call_count: u32 = 0;

    fn assertActive(self: *const RenderPass) void {
        if (!self.command_encoder.isActive(.render, self.generation))
            @panic("stale or wrong-kind GPU pass used after its lifetime ended");
    }

    pub fn isActive(self: *const RenderPass) bool {
        return self.command_encoder.isActive(.render, self.generation);
    }

    pub fn setPipeline(self: *RenderPass, pipeline: *const RenderPipeline) void {
        self.assertActive();
        _ = pipeline;
    }

    pub fn setViewport(self: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_d: f32, max_d: f32) void {
        self.assertActive();
        _ = .{ x, y, w, h, min_d, max_d };
    }

    pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        self.assertActive();
        _ = .{ x, y, w, h };
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: *const Buffer, offset: u64) void {
        self.assertActive();
        _ = .{ slot, buffer, offset };
    }

    pub fn setFragmentBuffer(self: *RenderPass, slot: u32, buffer: *const Buffer, offset: u64) void {
        self.assertActive();
        _ = .{ slot, buffer, offset };
    }

    pub fn setFragmentTexture(self: *RenderPass, slot: u32, texture: *const Texture) void {
        self.assertActive();
        _ = .{ slot, texture };
    }

    pub fn setFragmentTextureBinding(self: *RenderPass, slot: u32, texture: TextureBinding) void {
        self.assertActive();
        _ = .{ slot, texture };
    }

    pub fn setFragmentSampler(self: *RenderPass, slot: u32, sampler: ?*const Sampler) void {
        self.assertActive();
        _ = .{ slot, sampler };
    }

    pub fn setVertexBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        _ = .{ slot, data };
    }

    pub fn setFragmentBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        _ = .{ slot, data };
    }

    pub fn draw(self: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.assertActive();
        _ = .{ first_vertex, first_instance };
        if (vertex_count == 0 or instance_count == 0) return;
        frame_draw_call_count += 1;
        stats.draws += 1;
    }

    pub fn end(self: *RenderPass) void {
        self.assertActive();
        self.command_encoder.close(.render, self.generation);
    }
};

pub const BlitPass = struct {
    command_encoder: *CommandEncoder,
    generation: u64,

    fn assertActive(self: *const BlitPass) void {
        if (!self.command_encoder.isActive(.blit, self.generation))
            @panic("stale or wrong-kind GPU pass used after its lifetime ended");
    }

    pub fn isActive(self: *const BlitPass) bool {
        return self.command_encoder.isActive(.blit, self.generation);
    }

    pub fn copyTextureRegion(
        self: *BlitPass,
        source: TextureBinding,
        source_x: u32,
        source_y: u32,
        width: u32,
        height: u32,
        destination: TextureBinding,
        destination_x: u32,
        destination_y: u32,
    ) !void {
        self.assertActive();
        // 与 Metal 后端逐字对齐的区域校验，这条契约在 Null 后端下可确定性测试。
        if (width == 0 or height == 0 or
            source_x > source.width or width > source.width - source_x or
            source_y > source.height or height > source.height - source_y or
            destination_x > destination.width or width > destination.width - destination_x or
            destination_y > destination.height or height > destination.height - destination_y)
        {
            return error.InvalidTextureRegion;
        }
    }

    pub fn end(self: *BlitPass) void {
        self.assertActive();
        self.command_encoder.close(.blit, self.generation);
    }
};

pub const CommandBuffer = struct {
    completed: bool = true,

    pub fn submit(self: *CommandBuffer) void {
        _ = self;
        stats.submits += 1;
    }

    pub fn retained(self: *const CommandBuffer) CommandBuffer {
        return .{ .completed = self.completed };
    }

    pub fn waitUntilCompleted(self: *const CommandBuffer) void {
        _ = self;
    }

    pub fn isCompleted(self: *const CommandBuffer) bool {
        return self.completed;
    }

    pub fn gpuElapsedMicros(self: *const CommandBuffer) ?u64 {
        _ = self;
        return null;
    }

    /// 与 Metal 后端同名的类型级错误计数（cmd buffer 提交失败观测点）。
    pub var error_count: std.atomic.Value(u64) = .init(0);

    pub fn presentDrawable(self: *CommandBuffer, drawable: *anyopaque) void {
        _ = .{ self, drawable };
    }

    pub fn deinit(self: *CommandBuffer) void {
        _ = self;
    }
};

// ============================================================================
// Surface
// ============================================================================

pub const SurfaceUsage = enum { color_target_only, color_target_and_read };
pub const PresentMode = enum { fifo, immediate, mailbox };
pub const AlphaMode = enum { fully_opaque, premultiplied, postmultiplied };

pub const SurfaceConfiguration = struct {
    format: gpu.TextureFormat,
    width: u32,
    height: u32,
    usage: SurfaceUsage = .color_target_only,
    present_mode: PresentMode = .fifo,
    alpha_mode: AlphaMode = .fully_opaque,
    maximum_frame_latency: u32 = 2,
};

pub const SurfaceTexture = struct {
    texture: Texture,
    present_with_transaction: bool = false,

    pub fn preparePresent(self: *SurfaceTexture, command_buffer: *CommandBuffer) void {
        _ = .{ self, command_buffer };
    }

    pub fn presentAfterSubmit(self: *SurfaceTexture, command_buffer: *CommandBuffer) void {
        _ = .{ self, command_buffer };
    }

    pub fn deinit(self: *SurfaceTexture) void {
        self.texture.destroy();
    }
};

pub const Surface = struct {
    format: ?gpu.TextureFormat = null,
    extent: gpu.Extent3D = .{ .width = 0, .height = 0, .depth = 1 },

    /// 平台句柄被忽略，这正是 `*anyopaque` 签名的意义：Null 后端不需要
    /// 知道 CAMetalLayer 是什么。
    pub fn init(layer: *anyopaque) Surface {
        _ = layer;
        return .{};
    }

    pub fn configure(
        self: *Surface,
        allocator: std.mem.Allocator,
        device: *Device,
        config: SurfaceConfiguration,
    ) !void {
        _ = .{ allocator, device };
        self.format = config.format;
        self.extent = .{ .width = config.width, .height = config.height, .depth = 1 };
    }

    pub fn acquireTexture(self: *Surface, allocator: std.mem.Allocator) !SurfaceTexture {
        _ = allocator;
        const format = self.format orelse return error.SurfaceNotConfigured;
        const bpp = bytesPerPixel(format);
        const bytes = try alloc.alloc(u8, @as(usize, self.extent.width) * self.extent.height * bpp);
        @memset(bytes, 0);
        const id = next_texture_id;
        next_texture_id += 1;
        stats.textures_created += 1;
        return .{ .texture = .{
            .id = id,
            .bytes = bytes,
            .format = format,
            .size = self.extent,
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
        } };
    }

    pub fn deinit(self: *Surface) void {
        self.format = null;
    }
};

// ============================================================================
// FrameSync
// ============================================================================

/// Metal 后端用 `dispatch_semaphore_t`（Darwin 专属）。接口本身没泄漏类型，
/// 所以这里用可移植的 `std.Thread.Semaphore` 即可，这也顺带证明了
/// FrameSync 的抽象是干净的。
pub const FrameSync = struct {
    sem: std.Thread.Semaphore,

    pub fn init(max_frames_in_flight: u32) FrameSync {
        return .{ .sem = .{ .permits = max_frames_in_flight } };
    }

    pub fn waitForNextFrame(self: *FrameSync) void {
        self.sem.wait();
    }

    pub fn signalOnCompletion(self: *FrameSync, command_buffer: *const CommandBuffer) void {
        _ = command_buffer;
        self.sem.post();
    }

    pub fn signal(self: *FrameSync) void {
        self.sem.post();
    }

    /// 与 Metal 后端对齐：drain 后释放同步原语（std 信号量无系统资源，no-op 语义）
    pub fn deinit(self: *FrameSync) void {
        _ = self;
    }

    pub fn drain(self: *FrameSync, max_frames: u32) void {
        var i: u32 = 0;
        while (i < max_frames) : (i += 1) self.sem.wait();
        i = 0;
        while (i < max_frames) : (i += 1) self.sem.post();
    }
};

// ============================================================================
// 杂项
// ============================================================================

/// 与 GPU 无关的诊断工具（截图落盘）。Null 后端不写文件。
pub fn writePngRgba(path: [:0]const u8, rgba: []const u8, width: u32, height: u32, bytes_per_row: u32) bool {
    _ = .{ path, rgba, width, height, bytes_per_row };
    return false;
}
