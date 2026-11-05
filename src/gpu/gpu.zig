/// Zenit GPU - cross-platform GPU abstraction layer.
///
/// Based on wgpu API design; Zig implementation.
///
/// Backends: macOS Metal, Windows D3D11/D3D12, Linux Vulkan/OpenGL, Null reference.
/// Windows integration tracked in docs/WINDOWS_ARM64_PORT.md.
///
/// Reference: https://docs.rs/wgpu/latest/wgpu/
const builtin = @import("builtin");
const std = @import("std");

pub const rhi = @import("rhi.zig");
pub const DriverInfo = @import("driver_info.zig").DriverInfo;
pub const driver_bugs = @import("driver_bugs.zig");
pub const DriverBugs = driver_bugs.DriverBugs;
/// Native Vulkan diagnostics and explicit acceptance options.
pub const opengl_native = @import("opengl/device.zig");
pub const vulkan_native = @import("vulkan_bootstrap.zig");
pub const backend_contract = @import("backend_contract.zig");

// ============================================================================
// Backend Selection
// ============================================================================

/// Optional backend. `metal` is production; `null_backend` is device-less
/// deterministic reference, **falsify abstraction**: only second implementation
/// truly compiling confirms `Backend.*` backend-neutral, Metal semantics not
/// baked in.
pub const BackendKind = enum { metal, null_backend, d3d12, d3d11, vulkan, opengl };

/// Selected backend kind.
///
/// `-Dgpu-backend=d3d12` selects Windows renderer backend;
/// `-Dgpu-backend=null` selects reference. **Compile-time** selection: backend
/// switch introduces no runtime branch or vcall.
pub const backend_kind: BackendKind = blk: {
    const opts = @import("build_options");
    if (@hasDecl(opts, "gpu_backend")) {
        if (std.mem.eql(u8, opts.gpu_backend, "null")) break :blk .null_backend;
        if (std.mem.eql(u8, opts.gpu_backend, "metal")) break :blk .metal;
        if (std.mem.eql(u8, opts.gpu_backend, "d3d12")) {
            if (builtin.target.os.tag != .windows) @compileError("D3D12 backend requires Windows");
            break :blk .d3d12;
        }
        if (std.mem.eql(u8, opts.gpu_backend, "d3d11")) {
            if (builtin.target.os.tag != .windows) @compileError("D3D11 backend requires Windows");
            break :blk .d3d11;
        }
        if (std.mem.eql(u8, opts.gpu_backend, "vulkan")) {
            if (builtin.target.os.tag != .linux) @compileError("Vulkan backend requires Linux");
            break :blk .vulkan;
        }
        if (std.mem.eql(u8, opts.gpu_backend, "opengl")) {
            if (builtin.target.os.tag != .linux) @compileError("OpenGL backend requires Linux");
            break :blk .opengl;
        }
        @compileError("unknown -Dgpu-backend value: " ++ opts.gpu_backend);
    }
    break :blk if (builtin.target.os.tag == .macos)
        .metal
    else
        @compileError("Unsupported platform - only macOS Metal is currently implemented");
};

/// Render-target and all BGRA8 color texture format in the render pipeline (target,
/// offscreen layer, color-glyph page, each pipeline color attach, readback staging).
/// Paired with `shader_colors_encoded`. All backends use non-_sRGB: blend in sRGB-encoded
/// values, matching AppKit (docs/SRGB_BLENDING_PLAN.md). The glass/blur native model and
/// fit constants are premised on this. D3D12 HLSL and Metal use identical dials
/// (glass.hlsl generated from glass.metal).
pub const color_format: TextureFormat = .bgra8_unorm;

/// Shaders receive sRGB-encoded colors (else linear). See `color_format`.
pub const shader_colors_encoded: bool = true;

/// Both Direct3D versions share the renderer facade and HLSL, with distinct native implementations.
pub const is_direct3d = backend_kind == .d3d12 or backend_kind == .d3d11;

pub const Backend = switch (backend_kind) {
    .metal => @import("metal/backend.zig"),
    .null_backend => @import("null/backend.zig"),
    .d3d12, .d3d11 => @import("d3d12/renderer_device.zig"),
    .vulkan => @import("vulkan/renderer_device.zig"),
    .opengl => @import("opengl/renderer_device.zig"),
};

// Abstraction gatekeeper: backend missing contract symbol fails compile,
// names specifically, not deferred undefined at instantiation.
comptime {
    backend_contract.verify(Backend, @tagName(backend_kind));
}

/// Diagnostic GPU pass attribution (ZENIT_GPU_PASS_TIMING=1 on Metal): the
/// tag current when a render pass begins labels that pass's GPU time in the
/// perf trace. The app renderer installs the hook; without it this is a no-op.
pub const PassTag = enum(u32) {
    other = 0,
    glass_restore,
    glass_capture,
    glass_kawase,
    glass_luminance,
    glass_quarter,
    glass_eighth,
    glass_gauss_main,
    glass_gauss_alt,
    glass_gauss_fine,
    glass_ambient_half,
    glass_ambient_gauss,
    glass_composite,
    glass_fallback,
};
pub var pass_tag_hook: ?*const fn (u32) callconv(.c) void = null;
pub fn setPassTag(tag: PassTag) void {
    if (pass_tag_hook) |hook| hook(@backingInt(tag));
}

// Core Types (main entry points like wgpu)

/// Instance - GPU interaction start point.
pub const Instance = Backend.Instance;

/// Adapter - physical graphics device handle.
pub const Adapter = Backend.Adapter;

/// Device - open device connection, create resources.
pub const Device = Backend.Device;

/// Queue - command queue, submit commands.
pub const Queue = Backend.Queue;

/// Surface - window surface, present.
pub const Surface = Backend.Surface;

// ============================================================================
// Resource Types
// ============================================================================

/// Buffer - GPU-accessible buffer.
pub const Buffer = Backend.Buffer;

/// Texture - GPU texture.
pub const Texture = Backend.Texture;

/// TextureView - texture view.
pub const TextureView = Backend.TextureView;

/// Sampler - texture sampler.
pub const Sampler = Backend.Sampler;

// ============================================================================
// Pipeline Types
// ============================================================================

/// ShaderModule - compiled shader module.
pub const ShaderModule = Backend.ShaderModule;

/// RenderPipeline - render pipeline.
pub const RenderPipeline = Backend.RenderPipeline;

/// ComputePipeline - compute pipeline.
pub const ComputePipeline = Backend.ComputePipeline;

/// BindGroup - bind group.
pub const BindGroup = Backend.BindGroup;

/// BindGroupLayout - bind group layout.
pub const BindGroupLayout = Backend.BindGroupLayout;

/// PipelineLayout - pipeline layout.
pub const PipelineLayout = Backend.PipelineLayout;

// ============================================================================
// Command Encoding
// ============================================================================

/// CommandEncoder - command encoder.
pub const CommandEncoder = Backend.CommandEncoder;

/// CommandBuffer - encoded command buffer.
pub const CommandBuffer = Backend.CommandBuffer;

/// RenderPass - render pass encoder.
pub const RenderPass = Backend.RenderPass;

/// Declare the uploaded byte span. Native storage-buffer backends use this
/// bound when creating a draw's view; other backends keep their buffer binding.
pub fn setVertexBufferRange(pass: *RenderPass, slot: u32, buffer: *const Buffer, offset: u64, size: u64) void {
    if (comptime @hasDecl(RenderPass, "setVertexBufferRange")) {
        pass.setVertexBufferRange(slot, buffer, offset, size);
    } else {
        pass.setVertexBuffer(slot, buffer, offset);
    }
}
pub fn setFragmentBufferRange(pass: *RenderPass, slot: u32, buffer: *const Buffer, offset: u64, size: u64) void {
    if (comptime @hasDecl(RenderPass, "setFragmentBufferRange")) {
        pass.setFragmentBufferRange(slot, buffer, offset, size);
    } else {
        pass.setFragmentBuffer(slot, buffer, offset);
    }
}

/// ComputePass - compute pass encoder.
pub const ComputePass = Backend.ComputePass;

// ============================================================================
// Resource Pool (Phase 0) - Generational handle + epoch retirement queue
// ============================================================================

pub const resource_pool = @import("resource_pool.zig");
pub const ResourceHandle = resource_pool.ResourceHandle;
pub const ResourcePool = resource_pool.ResourcePool;
pub const ResourceKind = resource_pool.ResourceKind;

// ============================================================================
// Common Structures
// ============================================================================

/// Color (RGBA, range 0.0-1.0).
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const WHITE = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const RED = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const GREEN = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const BLUE = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
    pub const TRANSPARENT = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

/// 3D extent.
pub const Extent3D = struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
};

// Enums (enum types like wgpu)

/// Texture format.
pub const TextureFormat = enum {
    // 8-bit formats
    r8_unorm,
    r8_snorm,
    r8_uint,
    r8_sint,

    // 16-bit formats
    r16_uint,
    r16_sint,
    r16_float,
    rg8_unorm,
    rg8_snorm,
    rg8_uint,
    rg8_sint,

    // 32-bit formats
    r32_uint,
    r32_sint,
    r32_float,
    rg16_uint,
    rg16_sint,
    rg16_float,
    rgba8_unorm,
    rgba8_unorm_srgb,
    rgba8_snorm,
    rgba8_uint,
    rgba8_sint,
    bgra8_unorm,
    bgra8_unorm_srgb,

    // Packed 32-bit formats
    rgb10a2_unorm,

    // 64-bit formats
    rg32_uint,
    rg32_sint,
    rg32_float,
    rgba16_uint,
    rgba16_sint,
    rgba16_float,

    // 128-bit formats
    rgba32_uint,
    rgba32_sint,
    rgba32_float,

    // Depth/stencil formats
    depth16_unorm,
    depth24_plus,
    depth24_plus_stencil8,
    depth32_float,
    depth32_float_stencil8,
    stencil8,

    // BC compressed formats
    bc1_rgba_unorm,
    bc1_rgba_unorm_srgb,
    bc2_rgba_unorm,
    bc2_rgba_unorm_srgb,
    bc3_rgba_unorm,
    bc3_rgba_unorm_srgb,
    bc4_r_unorm,
    bc4_r_snorm,
    bc5_rg_unorm,
    bc5_rg_snorm,
    bc6h_rgb_ufloat,
    bc6h_rgb_float,
    bc7_rgba_unorm,
    bc7_rgba_unorm_srgb,
};

/// Texture dimension.
pub const TextureDimension = enum {
    @"1d",
    @"2d",
    @"3d",
};

/// Texture memory policy. `host_upload` is for resources updated directly by
/// the CPU; render targets and other GPU-only resources should stay
/// `device_local` so the backend can choose its optimal storage mode.
pub const TextureMemory = enum {
    device_local,
    host_upload,
};

/// CPU access pattern of a `host_upload` texture. `write_only` promises the
/// CPU never reads it back (no readBgra8, getBytes or CPU rasterizer reads):
/// Metal then maps it write-combined, which makes uploads cheaper and CPU
/// reads very slow. Ignored for `device_local`.
pub const HostAccess = enum {
    read_write,
    write_only,
};

/// Texture view dimension.
pub const TextureViewDimension = enum {
    @"1d",
    @"2d",
    @"2d_array",
    cube,
    cube_array,
    @"3d",
};

/// Texture usage flags.
pub const TextureUsages = packed struct(u32) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    _padding: u27 = 0,
};

/// Buffer usage flags.
pub const BufferUsages = packed struct(u32) {
    map_read: bool = false,
    /// CPU-writable. Without `map_read` the CPU must only write the mapping:
    /// Metal maps such buffers write-combined (reads stay correct but uncached
    /// and slow). Set `map_read` for any buffer the CPU reads back.
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
    _padding: u22 = 0,
};

/// Load operation.
pub const LoadOp = enum {
    load,
    clear,
    dont_care,
};

/// Store operation.
pub const StoreOp = enum {
    store,
    discard,
};

/// Primitive topology.
pub const PrimitiveTopology = enum {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
};

/// Index format.
pub const IndexFormat = enum {
    uint16,
    uint32,
};

/// Front-face direction.
pub const FrontFace = enum {
    ccw, // Counter-clockwise.
    cw, // Clockwise.
};

/// Cull mode.
pub const CullMode = enum {
    none,
    front,
    back,
};

/// Polygon mode.
pub const PolygonMode = enum {
    fill,
    line,
    point,
};

/// Comparison function.
pub const CompareFunction = enum {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};

/// Stencil operation.
pub const StencilOperation = enum {
    keep,
    zero,
    replace,
    invert,
    increment_clamp,
    decrement_clamp,
    increment_wrap,
    decrement_wrap,
};

/// Blend factor.
pub const BlendFactor = enum {
    zero,
    one,
    src,
    one_minus_src,
    src_alpha,
    one_minus_src_alpha,
    dst,
    one_minus_dst,
    dst_alpha,
    one_minus_dst_alpha,
    src_alpha_saturated,
    constant,
    one_minus_constant,
};

/// Blend operation.
pub const BlendOperation = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

/// Vertex format.
pub const VertexFormat = enum {
    uint8x2,
    uint8x4,
    sint8x2,
    sint8x4,
    unorm8x2,
    unorm8x4,
    snorm8x2,
    snorm8x4,
    uint16x2,
    uint16x4,
    sint16x2,
    sint16x4,
    unorm16x2,
    unorm16x4,
    snorm16x2,
    snorm16x4,
    float16x2,
    float16x4,
    float32,
    float32x2,
    float32x3,
    float32x4,
    uint32,
    uint32x2,
    uint32x3,
    uint32x4,
    sint32,
    sint32x2,
    sint32x3,
    sint32x4,
};

/// Vertex step mode.
pub const VertexStepMode = enum {
    vertex,
    instance,
};

/// Address mode.
pub const AddressMode = enum {
    clamp_to_edge,
    repeat,
    mirror_repeat,
    clamp_to_border,
};

/// Filter mode.
pub const FilterMode = enum {
    nearest,
    linear,
};

/// Mipmap filter mode.
pub const MipmapFilterMode = enum {
    nearest,
    linear,
};

/// Shader stage.
pub const ShaderStages = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _padding: u29 = 0,
};

// Descriptors (descriptor structs like wgpu)

/// Instance descriptor.
pub const InstanceDescriptor = struct {
    /// Backend selection is compile-time (`-Dgpu-backend=metal|null|d3d12|d3d11|vulkan|opengl`).
    /// Direct3D and Vulkan initialization reject a disabled selected backend; Metal and Null
    /// ignore this descriptor. These flags do not switch backends at runtime; GL and browser
    /// WebGPU entries remain descriptor placeholders.
    backends: Backends = .all,
};

/// Backend selection bitfield.
///
/// Available implementations are Metal, Null, D3D12, D3D11, Vulkan and OpenGL, selected at build time.
/// See `InstanceDescriptor.backends`.
pub const Backends = packed struct(u32) {
    vulkan: bool = false,
    metal: bool = false,
    dx12: bool = false,
    dx11: bool = false,
    gl: bool = false,
    browser_webgpu: bool = false,
    _padding: u26 = 0,

    pub const all = Backends{
        .vulkan = true,
        .metal = true,
        .dx12 = true,
        .dx11 = true,
        .gl = true,
        .browser_webgpu = true,
    };
};

/// Device descriptor.
pub const DeviceDescriptor = struct {
    label: ?[]const u8 = null,
    required_features: Features = .{},
    /// Null requests no additional minimums. Vulkan and D3D12 negotiate
    /// explicit limits; Metal retains its existing descriptor policy.
    required_limits: ?Limits = null,
};

/// Feature flags.
pub const Features = packed struct(u64) {
    depth_clip_control: bool = false,
    depth32float_stencil8: bool = false,
    timestamp_query: bool = false,
    texture_compression_bc: bool = false,
    texture_compression_etc2: bool = false,
    texture_compression_astc: bool = false,
    indirect_first_instance: bool = false,
    /// Nonuniform descriptor indexing for raw/structured UAV buffer array atomics.
    /// Includes verified backend workarounds; query before choosing this path.
    non_uniform_uav_buffer_array_atomics: bool = false,
    _padding: u56 = 0,
};

/// Limits.
pub const Limits = struct {
    max_texture_dimension_1d: u32 = 8192,
    max_texture_dimension_2d: u32 = 8192,
    max_texture_dimension_3d: u32 = 2048,
    max_texture_array_layers: u32 = 256,
    max_bind_groups: u32 = 4,
    max_bindings_per_bind_group: u32 = 640,
    max_dynamic_uniform_buffers_per_pipeline_layout: u32 = 8,
    max_dynamic_storage_buffers_per_pipeline_layout: u32 = 4,
    max_sampled_textures_per_shader_stage: u32 = 16,
    max_samplers_per_shader_stage: u32 = 16,
    max_storage_buffers_per_shader_stage: u32 = 8,
    max_storage_textures_per_shader_stage: u32 = 4,
    max_uniform_buffers_per_shader_stage: u32 = 12,
    max_uniform_buffer_binding_size: u64 = 65536,
    max_storage_buffer_binding_size: u64 = 134217728,
    max_vertex_buffers: u32 = 8,
    max_vertex_attributes: u32 = 16,
    max_vertex_buffer_array_stride: u32 = 2048,
    max_compute_workgroup_storage_size: u32 = 16384,
    max_compute_invocations_per_workgroup: u32 = 256,
    max_compute_workgroup_size_x: u32 = 256,
    max_compute_workgroup_size_y: u32 = 256,
    max_compute_workgroup_size_z: u32 = 64,
    max_compute_workgroups_per_dimension: u32 = 65535,
};

/// Buffer descriptor.
pub const BufferDescriptor = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsages,
    mapped_at_creation: bool = false,
};

/// Texture descriptor.
pub const TextureDescriptor = struct {
    label: ?[]const u8 = null,
    size: Extent3D,
    mip_level_count: u32 = 1,
    sample_count: u32 = 1,
    dimension: TextureDimension = .@"2d",
    format: TextureFormat,
    usage: TextureUsages,
    memory: TextureMemory = .device_local,
    host_access: HostAccess = .read_write,
    /// Pixel formats other than `format` this texture will be viewed or
    /// reinterpreted as (WebGPU `viewFormats`). Leave empty unless a view in a
    /// different format is really created: on Metal a foreign entry adds
    /// MTLTextureUsagePixelFormatView, which disables lossless compression of
    /// Private render targets. D3D12 rejects foreign entries.
    view_formats: []const TextureFormat = &.{},
};

/// TextureView descriptor
pub const TextureViewDescriptor = struct {
    label: ?[]const u8 = null,
    format: ?TextureFormat = null,
    dimension: ?TextureViewDimension = null,
    base_mip_level: u32 = 0,
    mip_level_count: ?u32 = null,
    base_array_layer: u32 = 0,
    array_layer_count: ?u32 = null,
};

/// Sampler descriptor
pub const SamplerDescriptor = struct {
    label: ?[]const u8 = null,
    address_mode_u: AddressMode = .clamp_to_edge,
    address_mode_v: AddressMode = .clamp_to_edge,
    address_mode_w: AddressMode = .clamp_to_edge,
    mag_filter: FilterMode = .nearest,
    min_filter: FilterMode = .nearest,
    mipmap_filter: MipmapFilterMode = .nearest,
    lod_min_clamp: f32 = 0.0,
    lod_max_clamp: f32 = 32.0,
    compare: ?CompareFunction = null,
    max_anisotropy: u16 = 1,
};

/// ShaderModule descriptor
pub const ShaderModuleDescriptor = struct {
    label: ?[]const u8 = null,
    source: ShaderSource,
};

/// Shader source code
pub const ShaderSource = union(enum) {
    wgsl: []const u8,
    spirv: []const u32,
    msl: []const u8, // Metal Shading Language
    hlsl: HlslSource,
    glsl: struct {
        code: []const u8,
        stage: ShaderStages,
    },
};

/// HLSL entry manifests make shader stages explicit instead of guessing from names.
pub const ShaderStage = enum { vertex, fragment, compute };
pub const HlslEntryPoint = struct { name: []const u8, stage: ShaderStage };
pub const HlslSource = struct { code: []const u8, entry_points: []const HlslEntryPoint };

/// BindGroupLayout descriptor
pub const BindGroupLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry,
};

/// BindGroupLayout entry
pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStages,
    ty: BindingType,
    count: ?u32 = null,
};

/// Binding type
pub const BindingType = union(enum) {
    buffer: BufferBindingLayout,
    sampler: SamplerBindingLayout,
    texture: TextureBindingLayout,
    storage_texture: StorageTextureBindingLayout,
};

/// Buffer binding layout
pub const BufferBindingLayout = struct {
    ty: BufferBindingType = .uniform,
    has_dynamic_offset: bool = false,
    min_binding_size: ?u64 = null,
};

/// Buffer binding type
pub const BufferBindingType = enum {
    uniform,
    storage,
    read_only_storage,
};

/// Sampler binding layout
pub const SamplerBindingLayout = struct {
    ty: SamplerBindingType = .filtering,
};

/// Sampler binding type
pub const SamplerBindingType = enum {
    filtering,
    non_filtering,
    comparison,
};

/// Texture binding layout
pub const TextureBindingLayout = struct {
    sample_type: TextureSampleType = .float,
    view_dimension: TextureViewDimension = .@"2d",
    multisampled: bool = false,
};

/// Texture sampling type
pub const TextureSampleType = enum {
    float,
    unfilterable_float,
    depth,
    sint,
    uint,
};

/// StorageTexture binding layout
pub const StorageTextureBindingLayout = struct {
    access: StorageTextureAccess = .write_only,
    format: TextureFormat,
    view_dimension: TextureViewDimension = .@"2d",
};

/// Storage texture access
pub const StorageTextureAccess = enum {
    write_only,
    read_only,
    read_write,
};

/// BindGroup descriptor
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: BindGroupLayout,
    entries: []const BindGroupEntry,
};

/// BindGroup entry
pub const BindGroupEntry = struct {
    binding: u32,
    resource: BindingResource,
};

/// Binding resource
pub const BindingResource = union(enum) {
    buffer: BufferBinding,
    sampler: Sampler,
    texture_view: TextureView,
};

/// Buffer binding
pub const BufferBinding = struct {
    buffer: Buffer,
    offset: u64 = 0,
    size: ?u64 = null,
};

/// PipelineLayout descriptor
pub const PipelineLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    bind_group_layouts: []const BindGroupLayout,
};

/// RenderPipeline descriptor
pub const RenderPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: ?PipelineLayout = null,
    vertex: VertexState,
    primitive: PrimitiveState = .{},
    depth_stencil: ?DepthStencilState = null,
    multisample: MultisampleState = .{},
    fragment: ?FragmentState = null,
};

/// Vertex state
pub const VertexState = struct {
    module: ShaderModule,
    entry_point: []const u8 = "main",
    buffers: []const VertexBufferLayout = &.{},
};

/// Vertex buffer layout
pub const VertexBufferLayout = struct {
    array_stride: u64,
    step_mode: VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

/// Vertex attribute
pub const VertexAttribute = struct {
    format: VertexFormat,
    offset: u64,
    shader_location: u32,
};

/// Primitive state
pub const PrimitiveState = struct {
    topology: PrimitiveTopology = .triangle_list,
    strip_index_format: ?IndexFormat = null,
    front_face: FrontFace = .ccw,
    cull_mode: CullMode = .none,
    unclipped_depth: bool = false,
    polygon_mode: PolygonMode = .fill,
};

/// Depth-stencil state
pub const DepthStencilState = struct {
    format: TextureFormat,
    depth_write_enabled: bool,
    depth_compare: CompareFunction,
    stencil_front: StencilFaceState = .{},
    stencil_back: StencilFaceState = .{},
    stencil_read_mask: u32 = 0xFFFFFFFF,
    stencil_write_mask: u32 = 0xFFFFFFFF,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0.0,
    depth_bias_clamp: f32 = 0.0,
};

/// Stencil face state
pub const StencilFaceState = struct {
    compare: CompareFunction = .always,
    fail_op: StencilOperation = .keep,
    depth_fail_op: StencilOperation = .keep,
    pass_op: StencilOperation = .keep,
};

/// Multisample state
pub const MultisampleState = struct {
    count: u32 = 1,
    mask: u64 = 0xFFFFFFFF,
    alpha_to_coverage_enabled: bool = false,
};

/// Fragment state
pub const FragmentState = struct {
    module: ShaderModule,
    entry_point: []const u8 = "main",
    targets: []const ColorTargetState,
};

/// Color target state
pub const ColorTargetState = struct {
    format: TextureFormat,
    blend: ?BlendState = null,
    write_mask: ColorWrites = ColorWrites.all,
};

/// Color write flags
pub const ColorWrites = packed struct(u32) {
    red: bool = false,
    green: bool = false,
    blue: bool = false,
    alpha: bool = false,
    _padding: u28 = 0,

    pub const all = ColorWrites{
        .red = true,
        .green = true,
        .blue = true,
        .alpha = true,
    };
};

/// Blend state
pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,

    pub const REPLACE = BlendState{
        .color = .{
            .src_factor = .one,
            .dst_factor = .zero,
            .operation = .add,
        },
        .alpha = .{
            .src_factor = .one,
            .dst_factor = .zero,
            .operation = .add,
        },
    };

    pub const ALPHA_BLENDING = BlendState{
        .color = .{
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
            .operation = .add,
        },
        .alpha = .{
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
            .operation = .add,
        },
    };
};

/// Blend component
pub const BlendComponent = struct {
    src_factor: BlendFactor,
    dst_factor: BlendFactor,
    operation: BlendOperation,
};

/// ComputePipeline descriptor
pub const ComputePipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: ?PipelineLayout = null,
    module: ShaderModule,
    entry_point: []const u8 = "main",
};

/// RenderPass color attachment
pub const RenderPassColorAttachment = struct {
    view: TextureView,
    resolve_target: ?TextureView = null,
    load_op: LoadOp,
    store_op: StoreOp,
    clear_value: Color = Color.BLACK,
};

/// RenderPass depth-stencil attachment
pub const RenderPassDepthStencilAttachment = struct {
    view: TextureView,
    depth_load_op: LoadOp = .load,
    depth_store_op: StoreOp = .store,
    depth_clear_value: f32 = 0.0,
    depth_read_only: bool = false,
    stencil_load_op: LoadOp = .load,
    stencil_store_op: StoreOp = .store,
    stencil_clear_value: u32 = 0,
    stencil_read_only: bool = false,
};

/// RenderPass descriptor
pub const RenderPassDescriptor = struct {
    label: ?[]const u8 = null,
    color_attachments: []const RenderPassColorAttachment,
    depth_stencil_attachment: ?RenderPassDepthStencilAttachment = null,
};

/// ComputePass descriptor
pub const ComputePassDescriptor = struct {
    label: ?[]const u8 = null,
};

test {
    // WARNING: Zig doesn't recursively collect test blocks from imported files;
    // `pub const x = @import(...)` re-exports at top level **don't** collect their tests
    // (see build.zig text.zig->font_catalog '3ms ran to completion' note). Must
    // explicitly reference here to run.
    //
    // Without explicit references, resource_pool / bind_group / conv tests (including key
    // invariants like ABA, epoch retirement) never ran.
    _ = driver_bugs; // Required portable driver-rule regressions (not just type re-exports).
    _ = rhi;
    _ = backend_contract;
    _ = resource_pool;
    // Direct3D range validation is CPU-only and belongs in the portable gate.
    _ = @import("d3d12/renderer_commands.zig");
    // metal/* tests meaningful only under Metal backend (bind_group depends on
    // Backend.BindGroupLayout, Null backend lacks it).
    if (backend_kind == .metal) {
        _ = @import("metal/bind_group.zig");
        _ = @import("metal/conv.zig");
        _ = @import("metal/surface.zig");
    }
}

test "both backends satisfy the renderer contract" {
    // Core assertion: the contract holds for **both** backends, not just the **currently
    // selected** one. Verifying only the selected backend is circular.
    //
    // verify is comptime: either line failing makes this file fail to compile, so the test
    // body itself needs no runtime assertions.
    backend_contract.verify(@import("metal/backend.zig"), "metal");
    backend_contract.verify(@import("null/backend.zig"), "null");
}

test "backend selection is compile-time and matches the built backend" {
    // Backend selection must be comptime constant: switching backends introduces no
    // runtime branches or virtual calls.
    comptime std.debug.assert(@TypeOf(backend_kind) == BackendKind);
    switch (backend_kind) {
        .metal => try std.testing.expect(Backend == @import("metal/backend.zig")),
        .null_backend => try std.testing.expect(Backend == @import("null/backend.zig")),
        .d3d12, .d3d11 => try std.testing.expect(Backend == @import("d3d12/renderer_device.zig")),
        .vulkan => try std.testing.expect(Backend == @import("vulkan/renderer_device.zig")),
        .opengl => try std.testing.expect(Backend == @import("opengl/renderer_device.zig")),
    }
}

/// Exact pixel copy, render-only on Metal. Other backends keep blit semantics.
pub const copyTextureRegion = @import("texture_copy.zig").copyTextureRegion;
pub const copyTextureRegionAudited = @import("texture_copy.zig").copyTextureRegionAudited;

test {
    _ = @import("texture_copy.zig");
}
