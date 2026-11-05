//! Renderer entry points over the owned native device and stable ordered Context.
//! Device/Adapter are move-only; Queue borrows Device's Context, as do textures.
const std = @import("std");
const gpu = @import("../gpu.zig");
pub const native = @import("resources.zig");
const resources = @import("renderer_resources.zig");
const commands = @import("renderer_commands.zig");
const pipelines = @import("renderer_pipeline.zig");
pub const Buffer = native.Buffer;
pub const Texture = resources.Texture;
pub const TextureBinding = resources.TextureBinding;
pub const TextureView = resources.TextureView;
pub const Sampler = native.Sampler;
pub const Queue = commands.Queue;
pub const CommandEncoder = commands.CommandEncoder;
pub const CommandBuffer = commands.CommandBuffer;
pub const RenderPass = commands.RenderPass;
pub const BlitPass = commands.BlitPass;
pub const ShaderFunction = pipelines.ShaderFunction;
pub const RenderPipeline = pipelines.RenderPipeline;
pub const RenderPipelineDescriptor = pipelines.RenderPipelineDescriptor;
pub const VertexBufferLayoutDescriptor = pipelines.VertexBufferLayoutDescriptor;
pub const VertexAttributeDescriptor = pipelines.VertexAttributeDescriptor;
pub const BlendState = pipelines.BlendState;
pub const shaders = @import("renderer_shaders.zig");
pub const FrameSync = @import("frame_sync.zig").FrameSync;
pub const Surface = @import("surface.zig").Surface;
pub const SurfaceConfiguration = @import("surface.zig").SurfaceConfiguration;
pub const SurfaceTexture = @import("surface.zig").SurfaceTexture;
pub const SpriteAtlas = @import("surface.zig").SpriteAtlas;
extern fn zenit_d12_write_png_rgba([*:0]const u8, [*]const u8, usize, u32, u32, u32) c_int;
pub fn writePngRgba(path: [:0]const u8, rgba: []const u8, width: u32, height: u32, bytes_per_row: u32) bool {
    return zenit_d12_write_png_rgba(path.ptr, rgba.ptr, rgba.len, width, height, bytes_per_row) == 0;
}
pub const Instance = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator, desc: gpu.InstanceDescriptor) !Instance {
        if (if (gpu.backend_kind == .d3d11) !desc.backends.dx11 else !desc.backends.dx12) return error.BackendDisabled;
        return .{ .allocator = allocator };
    }
    /// One selected D3D12-capable hardware adapter in DXGI order, with WARP fallback.
    /// This is not enumeration of every physical adapter in the machine.
    pub fn enumerateAdapters(self: *Instance) ![]Adapter {
        var device = try native.Device.init(false);
        errdefer device.destroy();
        const adapters = try self.allocator.alloc(Adapter, 1);
        adapters[0] = .{ .native_device = device };
        return adapters;
    }
    pub fn deinit(self: *Instance) void {
        self.* = undefined;
    }
};
pub const Adapter = struct {
    native_device: native.Device,
    pub fn isSoftware(self: *const Adapter) bool {
        return self.native_device.isSoftware();
    }
    pub fn getFeatures(self: *const Adapter) gpu.Features {
        return self.native_device.getFeatures();
    }
    pub fn driverInfo(self: *const Adapter) gpu.DriverInfo {
        return self.native_device.driverInfo();
    }
    pub fn driverBugs(self: *const Adapter) gpu.DriverBugs {
        return self.native_device.driverBugs();
    }
    pub fn requestDevice(self: *Adapter, allocator: std.mem.Allocator, desc: gpu.DeviceDescriptor) !struct { device: Device, queue: Queue } {
        const features = self.getFeatures();
        if ((@as(u64, @bitCast(desc.required_features)) & ~@as(u64, @bitCast(features))) != 0) return error.UnsupportedFeatures;
        const supported = gpu.Limits{};
        if (desc.required_limits) |required| inline for (@import("zenit_reflection").fields(gpu.Limits)) |field| {
            if (@field(required, field.name) > @field(supported, field.name)) return error.UnsupportedLimits;
        };
        const context = try resources.Context.init(allocator, &self.native_device);
        return .{ .device = .{ .context = context, .features = features, .limits = supported }, .queue = Queue.init(context) };
    }
    pub fn deinit(self: *Adapter) void {
        self.native_device.destroy();
        self.* = undefined;
    }
};
pub const Device = struct {
    context: *resources.Context,
    features: gpu.Features,
    limits: gpu.Limits,
    pub fn createBuffer(self: *Device, allocator: std.mem.Allocator, desc: gpu.BufferDescriptor) !Buffer {
        return self.context.createBuffer(allocator, desc);
    }
    pub fn createTexture(self: *Device, allocator: std.mem.Allocator, desc: gpu.TextureDescriptor) !Texture {
        return self.context.createTexture(allocator, desc);
    }
    pub fn createSampler(self: *Device, allocator: std.mem.Allocator, desc: gpu.SamplerDescriptor) !Sampler {
        return self.context.device.createSampler(allocator, desc);
    }
    pub fn supportsSampleCount(self: *const Device, format: gpu.TextureFormat, count: u32) !bool {
        return self.context.device.supportsSampleCount(format, count);
    }
    pub fn supportsVertexViewportIndex(self: *const Device) bool {
        return self.context.device.supportsVertexViewportIndex();
    }
    pub fn driverInfo(self: *const Device) gpu.DriverInfo {
        return self.context.device.driverInfo();
    }
    pub fn driverBugs(self: *const Device) gpu.DriverBugs {
        return self.context.device.driverBugs();
    }
    pub fn isSoftware(self: *const Device) bool {
        return self.context.device.isSoftware();
    }
    /// Failure preserves the Device and ordered queue for a later retry.
    pub fn deinitChecked(self: *Device) !void {
        try self.context.deinit();
        self.* = undefined;
    }
    pub fn deinit(self: *Device) void {
        self.deinitChecked() catch @panic("D3D12 renderer Device still has live resources or GPU work");
    }
};
pub const ShaderModule = struct {
    inner: pipelines.ShaderModule,
    pub fn initFromSource(device: *Device, source: []const u8) !ShaderModule {
        return .{ .inner = try pipelines.ShaderModule.initFromSource(&device.context.device, source) };
    }
    pub fn getFunction(self: *const ShaderModule, name: []const u8) !ShaderFunction {
        return self.inner.getFunction(name);
    }
    pub fn deinit(self: *ShaderModule) void {
        self.inner.deinit();
    }
};
pub fn createRenderPipeline(device: *Device, desc: RenderPipelineDescriptor) !RenderPipeline {
    return pipelines.createRenderPipeline(&device.context.device, desc);
}
