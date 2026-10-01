/// Zenit GPU - 跨平台 GPU 抽象层
///
/// 基于 wgpu API 设计，使用 Zig 实现
///
/// 当前支持: macOS Metal
/// 未来计划: Windows (D3D12), Linux (Vulkan), WebGPU
///
/// 参考: https://docs.rs/wgpu/latest/wgpu/
const builtin = @import("builtin");
const std = @import("std");

pub const rhi = @import("rhi.zig");
pub const backend_contract = @import("backend_contract.zig");

// ============================================================================
// Backend Selection
// ============================================================================

/// 可选后端。`metal` 是生产后端；`null_backend` 是无设备的确定性参考实现，
/// 用来**证伪抽象**，只有第二个实现真的编译通过，才能确认 `Backend.*` 的
/// 签名是 backend-neutral 的，而不是把 Metal 语义焊死在了里面。
pub const BackendKind = enum { metal, null_backend };

/// 选中的后端种类。
///
/// 默认跟随平台（macOS -> Metal）。`-Dgpu-backend=null` 可切到参考实现，
/// 这是 C1「让抽象长出第二个实现」的入口。选择发生在**编译期**：切换后端
/// 不引入任何运行时分支或虚调用（见 RENDERER_RHI_PLAN.md §8 的停止条件）。
pub const backend_kind: BackendKind = blk: {
    const opts = @import("build_options");
    if (@hasDecl(opts, "gpu_backend")) {
        if (std.mem.eql(u8, opts.gpu_backend, "null")) break :blk .null_backend;
        if (std.mem.eql(u8, opts.gpu_backend, "metal")) break :blk .metal;
        @compileError("unknown -Dgpu-backend value: " ++ opts.gpu_backend);
    }
    break :blk if (builtin.target.os.tag == .macos)
        .metal
    else
        @compileError("Unsupported platform - only macOS Metal is currently implemented");
};

pub const Backend = switch (backend_kind) {
    .metal => @import("metal/backend.zig"),
    .null_backend => @import("null/backend.zig"),
};

// 抽象的守门人：后端漏实现契约里的符号时，这里当场编译失败并指名道姓，
// 而不是等到某个调用点被实例化才报一个难以定位的 undefined。
comptime {
    backend_contract.verify(Backend, @tagName(backend_kind));
}

// ============================================================================
// Core Types (类似 wgpu 的主要入口点)
// ============================================================================

/// Instance - GPU 交互的起点
pub const Instance = Backend.Instance;

/// Adapter - 物理图形设备的句柄
pub const Adapter = Backend.Adapter;

/// Device - 打开的设备连接，用于创建资源
pub const Device = Backend.Device;

/// Queue - 命令队列，用于提交命令
pub const Queue = Backend.Queue;

/// Surface - 窗口表面，用于呈现
pub const Surface = Backend.Surface;

// ============================================================================
// Resource Types
// ============================================================================

/// Buffer - GPU 可访问的缓冲区
pub const Buffer = Backend.Buffer;

/// Texture - GPU 纹理
pub const Texture = Backend.Texture;

/// TextureView - 纹理视图
pub const TextureView = Backend.TextureView;

/// Sampler - 纹理采样器
pub const Sampler = Backend.Sampler;

// ============================================================================
// Pipeline Types
// ============================================================================

/// ShaderModule - 编译的着色器模块
pub const ShaderModule = Backend.ShaderModule;

/// RenderPipeline - 渲染管线
pub const RenderPipeline = Backend.RenderPipeline;

/// ComputePipeline - 计算管线
pub const ComputePipeline = Backend.ComputePipeline;

/// BindGroup - 绑定组
pub const BindGroup = Backend.BindGroup;

/// BindGroupLayout - 绑定组布局
pub const BindGroupLayout = Backend.BindGroupLayout;

/// PipelineLayout - 管线布局
pub const PipelineLayout = Backend.PipelineLayout;

// ============================================================================
// Command Encoding
// ============================================================================

/// CommandEncoder - 命令编码器
pub const CommandEncoder = Backend.CommandEncoder;

/// CommandBuffer - 已编码的命令缓冲区
pub const CommandBuffer = Backend.CommandBuffer;

/// RenderPass - 渲染通道编码器
pub const RenderPass = Backend.RenderPass;

/// ComputePass - 计算通道编码器
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

/// 颜色（RGBA，范围 0.0-1.0）
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

/// 3D 尺寸
pub const Extent3D = struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
};

// ============================================================================
// Enums (类似 wgpu 的枚举类型)
// ============================================================================

/// 纹理格式
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

/// 纹理维度
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

/// 纹理视图维度
pub const TextureViewDimension = enum {
    @"1d",
    @"2d",
    @"2d_array",
    cube,
    cube_array,
    @"3d",
};

/// 纹理使用标志
pub const TextureUsages = packed struct(u32) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    _padding: u27 = 0,
};

/// 缓冲区使用标志
pub const BufferUsages = packed struct(u32) {
    map_read: bool = false,
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

/// 加载操作
pub const LoadOp = enum {
    load,
    clear,
    dont_care,
};

/// 存储操作
pub const StoreOp = enum {
    store,
    discard,
};

/// 基元拓扑
pub const PrimitiveTopology = enum {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
};

/// 索引格式
pub const IndexFormat = enum {
    uint16,
    uint32,
};

/// 正面方向
pub const FrontFace = enum {
    ccw, // 逆时针
    cw, // 顺时针
};

/// 剔除模式
pub const CullMode = enum {
    none,
    front,
    back,
};

/// 多边形模式
pub const PolygonMode = enum {
    fill,
    line,
    point,
};

/// 比较函数
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

/// 模板操作
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

/// 混合因子
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

/// 混合操作
pub const BlendOperation = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

/// 顶点格式
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

/// 顶点步进模式
pub const VertexStepMode = enum {
    vertex,
    instance,
};

/// 地址模式
pub const AddressMode = enum {
    clamp_to_edge,
    repeat,
    mirror_repeat,
    clamp_to_border,
};

/// 过滤模式
pub const FilterMode = enum {
    nearest,
    linear,
};

/// Mipmap 过滤模式
pub const MipmapFilterMode = enum {
    nearest,
    linear,
};

/// 着色器阶段
pub const ShaderStages = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _padding: u29 = 0,
};

// ============================================================================
// Descriptors (类似 wgpu 的描述符结构)
// ============================================================================

/// Instance 描述符
pub const InstanceDescriptor = struct {
    /// **当前被所有后端忽略。** 后端选择是编译期决定的（`-Dgpu-backend=metal|null`，
    /// 见 build.zig），运行时描述符管不着；Metal / Null 两个后端的 `Instance.init`
    /// 都直接丢弃整个 descriptor。
    ///
    /// 保留这个字段只为对齐 wgpu 的描述符形状，设置它不会有任何效果，尤其是
    /// `Backends` 里列出的 vulkan / dx12 / dx11 / gl / browser_webgpu **都没有
    /// 对应实现**，别把它当成"打开某后端"的开关。
    backends: Backends = .all,
};

/// 后端选择位域。
///
/// 注意：这是 wgpu 形状的占位定义，**不代表 zenit 真的实现了这些后端**。
/// 目前只有 Metal 与 Null 两个真实后端，且都靠 `-Dgpu-backend=` 在编译期选定。
/// 见 `InstanceDescriptor.backends` 的说明。
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

/// Device 描述符
pub const DeviceDescriptor = struct {
    label: ?[]const u8 = null,
    required_features: Features = .{},
    required_limits: Limits = .{},
};

/// 功能标志
pub const Features = packed struct(u64) {
    depth_clip_control: bool = false,
    depth32float_stencil8: bool = false,
    timestamp_query: bool = false,
    texture_compression_bc: bool = false,
    texture_compression_etc2: bool = false,
    texture_compression_astc: bool = false,
    indirect_first_instance: bool = false,
    _padding: u57 = 0,
};

/// 限制
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

/// Buffer 描述符
pub const BufferDescriptor = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsages,
    mapped_at_creation: bool = false,
};

/// Texture 描述符
pub const TextureDescriptor = struct {
    label: ?[]const u8 = null,
    size: Extent3D,
    mip_level_count: u32 = 1,
    sample_count: u32 = 1,
    dimension: TextureDimension = .@"2d",
    format: TextureFormat,
    usage: TextureUsages,
    memory: TextureMemory = .device_local,
    view_formats: []const TextureFormat = &.{},
};

/// TextureView 描述符
pub const TextureViewDescriptor = struct {
    label: ?[]const u8 = null,
    format: ?TextureFormat = null,
    dimension: ?TextureViewDimension = null,
    base_mip_level: u32 = 0,
    mip_level_count: ?u32 = null,
    base_array_layer: u32 = 0,
    array_layer_count: ?u32 = null,
};

/// Sampler 描述符
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

/// ShaderModule 描述符
pub const ShaderModuleDescriptor = struct {
    label: ?[]const u8 = null,
    source: ShaderSource,
};

/// 着色器源码
pub const ShaderSource = union(enum) {
    wgsl: []const u8,
    spirv: []const u32,
    msl: []const u8, // Metal Shading Language
    glsl: struct {
        code: []const u8,
        stage: ShaderStages,
    },
};

/// BindGroupLayout 描述符
pub const BindGroupLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry,
};

/// BindGroupLayout 条目
pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStages,
    ty: BindingType,
    count: ?u32 = null,
};

/// 绑定类型
pub const BindingType = union(enum) {
    buffer: BufferBindingLayout,
    sampler: SamplerBindingLayout,
    texture: TextureBindingLayout,
    storage_texture: StorageTextureBindingLayout,
};

/// Buffer 绑定布局
pub const BufferBindingLayout = struct {
    ty: BufferBindingType = .uniform,
    has_dynamic_offset: bool = false,
    min_binding_size: ?u64 = null,
};

/// Buffer 绑定类型
pub const BufferBindingType = enum {
    uniform,
    storage,
    read_only_storage,
};

/// Sampler 绑定布局
pub const SamplerBindingLayout = struct {
    ty: SamplerBindingType = .filtering,
};

/// Sampler 绑定类型
pub const SamplerBindingType = enum {
    filtering,
    non_filtering,
    comparison,
};

/// Texture 绑定布局
pub const TextureBindingLayout = struct {
    sample_type: TextureSampleType = .float,
    view_dimension: TextureViewDimension = .@"2d",
    multisampled: bool = false,
};

/// 纹理采样类型
pub const TextureSampleType = enum {
    float,
    unfilterable_float,
    depth,
    sint,
    uint,
};

/// StorageTexture 绑定布局
pub const StorageTextureBindingLayout = struct {
    access: StorageTextureAccess = .write_only,
    format: TextureFormat,
    view_dimension: TextureViewDimension = .@"2d",
};

/// 存储纹理访问
pub const StorageTextureAccess = enum {
    write_only,
    read_only,
    read_write,
};

/// BindGroup 描述符
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: BindGroupLayout,
    entries: []const BindGroupEntry,
};

/// BindGroup 条目
pub const BindGroupEntry = struct {
    binding: u32,
    resource: BindingResource,
};

/// 绑定资源
pub const BindingResource = union(enum) {
    buffer: BufferBinding,
    sampler: Sampler,
    texture_view: TextureView,
};

/// Buffer 绑定
pub const BufferBinding = struct {
    buffer: Buffer,
    offset: u64 = 0,
    size: ?u64 = null,
};

/// PipelineLayout 描述符
pub const PipelineLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    bind_group_layouts: []const BindGroupLayout,
};

/// RenderPipeline 描述符
pub const RenderPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: ?PipelineLayout = null,
    vertex: VertexState,
    primitive: PrimitiveState = .{},
    depth_stencil: ?DepthStencilState = null,
    multisample: MultisampleState = .{},
    fragment: ?FragmentState = null,
};

/// 顶点状态
pub const VertexState = struct {
    module: ShaderModule,
    entry_point: []const u8 = "main",
    buffers: []const VertexBufferLayout = &.{},
};

/// 顶点缓冲区布局
pub const VertexBufferLayout = struct {
    array_stride: u64,
    step_mode: VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

/// 顶点属性
pub const VertexAttribute = struct {
    format: VertexFormat,
    offset: u64,
    shader_location: u32,
};

/// 基元状态
pub const PrimitiveState = struct {
    topology: PrimitiveTopology = .triangle_list,
    strip_index_format: ?IndexFormat = null,
    front_face: FrontFace = .ccw,
    cull_mode: CullMode = .none,
    unclipped_depth: bool = false,
    polygon_mode: PolygonMode = .fill,
};

/// 深度模板状态
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

/// 模板面状态
pub const StencilFaceState = struct {
    compare: CompareFunction = .always,
    fail_op: StencilOperation = .keep,
    depth_fail_op: StencilOperation = .keep,
    pass_op: StencilOperation = .keep,
};

/// 多重采样状态
pub const MultisampleState = struct {
    count: u32 = 1,
    mask: u64 = 0xFFFFFFFF,
    alpha_to_coverage_enabled: bool = false,
};

/// 片段状态
pub const FragmentState = struct {
    module: ShaderModule,
    entry_point: []const u8 = "main",
    targets: []const ColorTargetState,
};

/// 颜色目标状态
pub const ColorTargetState = struct {
    format: TextureFormat,
    blend: ?BlendState = null,
    write_mask: ColorWrites = ColorWrites.all,
};

/// 颜色写入标志
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

/// 混合状态
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

/// 混合分量
pub const BlendComponent = struct {
    src_factor: BlendFactor,
    dst_factor: BlendFactor,
    operation: BlendOperation,
};

/// ComputePipeline 描述符
pub const ComputePipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: ?PipelineLayout = null,
    module: ShaderModule,
    entry_point: []const u8 = "main",
};

/// RenderPass 颜色附件
pub const RenderPassColorAttachment = struct {
    view: TextureView,
    resolve_target: ?TextureView = null,
    load_op: LoadOp,
    store_op: StoreOp,
    clear_value: Color = Color.BLACK,
};

/// RenderPass 深度模板附件
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

/// RenderPass 描述符
pub const RenderPassDescriptor = struct {
    label: ?[]const u8 = null,
    color_attachments: []const RenderPassColorAttachment,
    depth_stencil_attachment: ?RenderPassDepthStencilAttachment = null,
};

/// ComputePass 描述符
pub const ComputePassDescriptor = struct {
    label: ?[]const u8 = null,
};

test {
    // ⚠ Zig 不会递归收集被 import 文件里的 test 块，`pub const x =
    // @import(...)` 这种顶层再导出**不会**让它的 test 被收集（见 build.zig
    // 里 text.zig->font_catalog 那次「3ms 就跑完了」的记录）。要跑就必须在
    // 这里显式引用一次。
    //
    // 2026-09-22 实测：加 resource_pool / bind_group / conv 之前 test-gpu 是
    // 10 个，之后 22 个，前面 12 个（含 ABA、epoch 退休等关键不变量）
    // 一直没跑过。
    _ = rhi;
    _ = backend_contract;
    _ = resource_pool;
    // metal/* 的测试只在 Metal 后端下有意义（bind_group 依赖
    // Backend.BindGroupLayout，Null 后端没有该类型）。
    if (backend_kind == .metal) {
        _ = @import("metal/bind_group.zig");
        _ = @import("metal/conv.zig");
    }
}

test "both backends satisfy the renderer contract" {
    // C1 的核心断言：契约不是只对**当前选中**的后端成立，而是对**两个**
    // 后端都成立。只校验选中的那个是循环论证，那正是"抽象从未被证伪"
    // 的老状态（见 docs/internal/RHI_SECOND_BACKEND_ASSESSMENT.md）。
    //
    // verify 是 comptime 的：这两行任一不满足都会让本文件编译失败，
    // 所以测试体本身无需运行时断言。
    backend_contract.verify(@import("metal/backend.zig"), "metal");
    backend_contract.verify(@import("null/backend.zig"), "null");
}

test "backend selection is compile-time and matches the built backend" {
    // 后端选择必须是 comptime 常量：切后端不引入运行时分支或虚调用
    // （RENDERER_RHI_PLAN.md §8 的停止条件之一）。
    comptime std.debug.assert(@TypeOf(backend_kind) == BackendKind);
    switch (backend_kind) {
        .metal => try std.testing.expect(Backend == @import("metal/backend.zig")),
        .null_backend => try std.testing.expect(Backend == @import("null/backend.zig")),
    }
}
