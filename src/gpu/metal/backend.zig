/// Metal Backend - Metal 后端入口
///
/// 这个文件导出所有 Metal 后端类型，供 gpu.zig 使用

// Metal 绑定和转换
pub const metal_bindings = @import("metal_bindings.zig");
pub const conv = @import("conv.zig");

// 核心类型
pub const Instance = @import("instance.zig").Instance;
pub const Adapter = @import("adapter.zig").Adapter;
pub const Device = @import("device.zig").Device;
pub const Queue = @import("queue.zig").Queue;

// 资源类型
const resources = @import("resources.zig");
pub const Buffer = resources.Buffer;
pub const Texture = resources.Texture;
pub const TextureBinding = resources.TextureBinding;
pub const TextureView = resources.TextureView;
pub const Sampler = resources.Sampler;

/// Backend image encoding utility used by diagnostics/E2E capture. Renderer
/// code passes ordinary bytes and never observes an Objective-C handle.
pub fn writePngRgba(path: [:0]const u8, rgba: []const u8, width: u32, height: u32, bytes_per_row: u32) bool {
    const required = @as(usize, bytes_per_row) * @as(usize, height);
    if (width == 0 or height == 0 or bytes_per_row < width * 4 or rgba.len < required) return false;
    return metal_bindings.macos_write_png_from_rgba(path.ptr, rgba.ptr, width, height, bytes_per_row) == 0;
}

/// Explicit backend escape hatch for borrowing an externally owned Metal
/// texture. Renderer-owned images should use `Texture.binding()` instead.
pub fn importTextureBinding(texture: *metal_bindings.MTLTexture) TextureBinding {
    return .{
        .raw = texture,
        .width = metal_bindings.metal_texture_get_width(texture),
        .height = metal_bindings.metal_texture_get_height(texture),
    };
}

// Surface
const surface_mod = @import("surface.zig");
pub const Surface = surface_mod.Surface;
pub const SurfaceTexture = surface_mod.SurfaceTexture;
pub const SurfaceConfiguration = surface_mod.SurfaceConfiguration;

// 命令编码
const command_encoder_mod = @import("command_encoder.zig");
pub const CommandEncoder = command_encoder_mod.CommandEncoder;
pub const CommandBuffer = command_encoder_mod.CommandBuffer;
pub const RenderPass = command_encoder_mod.RenderPass;
pub const ComputePass = command_encoder_mod.ComputePass;
pub const BlitPass = command_encoder_mod.BlitPass;

// Pipeline
const pipeline_mod = @import("pipeline.zig");
pub const ShaderModule = pipeline_mod.ShaderModule;
pub const ShaderFunction = pipeline_mod.ShaderFunction;
pub const RenderPipeline = pipeline_mod.RenderPipeline;
pub const RenderPipelineDescriptor = pipeline_mod.RenderPipelineDescriptor;
pub const VertexBufferLayoutDescriptor = pipeline_mod.VertexBufferLayoutDescriptor;
pub const VertexAttributeDescriptor = pipeline_mod.VertexAttributeDescriptor;
pub const BlendState = pipeline_mod.BlendState;
pub const createRenderPipeline = pipeline_mod.createRenderPipeline;

// ComputePipeline（占位）
pub const ComputePipeline = command_encoder_mod.ComputePipeline;

// BindGroup 系统
const bind_group_mod = @import("bind_group.zig");
pub const BindGroupLayout = bind_group_mod.BindGroupLayout;
pub const BindGroup = bind_group_mod.BindGroup;
pub const PipelineLayout = bind_group_mod.PipelineLayout;

// ============================================================================
// 帧同步原语 — 平台无关的 CPU/GPU 同步接口
// Metal: dispatch_semaphore_t
// Vulkan (future): VkFence + VkSemaphore
// ============================================================================

pub const FrameSync = struct {
    semaphore: ?metal_bindings.dispatch_semaphore_t,

    /// 创建帧同步原语（允许 max_frames_in_flight 帧并发）
    pub fn init(max_frames_in_flight: u32) FrameSync {
        return .{
            .semaphore = metal_bindings.dispatch_semaphore_create(@intCast(max_frames_in_flight)),
        };
    }

    /// 等待 — CPU 阻塞直到有可用的 buffer slot
    pub fn waitForNextFrame(self: *FrameSync) void {
        if (self.semaphore) |sem| {
            _ = metal_bindings.dispatch_semaphore_wait(sem, metal_bindings.DISPATCH_TIME_FOREVER);
        }
    }

    /// 注册 GPU 完成回调 — 在 command buffer 完成后 signal
    pub fn signalOnCompletion(self: *FrameSync, cmd_buffer: *const CommandBuffer) void {
        if (self.semaphore) |sem| {
            metal_bindings.metal_command_buffer_add_completed_handler(cmd_buffer.raw, sem, &signalCallback);
        }
    }

    /// 手动归还一个 slot（错误路径用，防止 semaphore 泄漏导致下帧永久阻塞）
    pub fn signal(self: *FrameSync) void {
        if (self.semaphore) |sem| {
            _ = metal_bindings.dispatch_semaphore_signal(sem);
        }
    }

    /// 释放信号量。调用前必须先 drain（对未平衡的 semaphore release 会
    /// 触发 GCD 断言崩溃——dispatch_semaphore 要求释放时 value >= 初始值）。
    pub fn deinit(self: *FrameSync) void {
        if (self.semaphore) |sem| {
            metal_bindings.dispatch_release(sem);
            self.semaphore = null;
        }
    }

    /// 等待所有 in-flight 帧完成（销毁前调用）
    pub fn drain(self: *FrameSync, max_frames: u32) void {
        if (self.semaphore) |sem| {
            for (0..max_frames) |_| {
                _ = metal_bindings.dispatch_semaphore_wait(sem, metal_bindings.DISPATCH_TIME_FOREVER);
            }
            for (0..max_frames) |_| {
                _ = metal_bindings.dispatch_semaphore_signal(sem);
            }
        }
    }

    fn signalCallback(context: ?*anyopaque) callconv(.c) void {
        if (context) |sem| {
            _ = metal_bindings.dispatch_semaphore_signal(sem);
        }
    }
};
