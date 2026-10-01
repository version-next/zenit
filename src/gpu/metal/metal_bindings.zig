/// Metal C API 绑定
///
/// 这个文件提供对 native/metal_bridge.m 中定义的 C API 的 Zig 绑定
/// 所有 Metal API 调用都通过这些 C 桥接函数进行

// ============================================================================
// Opaque Types - Metal 对象句柄
// ============================================================================

/// MTLDevice - Metal 设备
pub const MTLDevice = opaque {};

/// MTLCommandQueue - 命令队列
pub const MTLCommandQueue = opaque {};

/// MTLCommandBuffer - 命令缓冲区
pub const MTLCommandBuffer = opaque {};

/// MTLBuffer - GPU 缓冲区
pub const MTLBuffer = opaque {};

/// MTLTexture - GPU 纹理
pub const MTLTexture = opaque {};

/// MTLTextureDescriptor - 纹理描述符
pub const MTLTextureDescriptor = opaque {};

/// MTLSamplerState - 采样器状态
pub const MTLSamplerState = opaque {};

/// MTLSamplerDescriptor - 采样器描述符
pub const MTLSamplerDescriptor = opaque {};

/// MTLLibrary - 着色器库
pub const MTLLibrary = opaque {};

/// MTLFunction - 着色器函数
pub const MTLFunction = opaque {};

/// MTLRenderPipelineState - 渲染管线状态
pub const MTLRenderPipelineState = opaque {};

/// MTLRenderPipelineDescriptor - 渲染管线描述符
pub const MTLRenderPipelineDescriptor = opaque {};

/// MTLDepthStencilState - 深度模板状态
pub const MTLDepthStencilState = opaque {};

/// MTLComputePipelineState - 计算管线状态
pub const MTLComputePipelineState = opaque {};

/// MTLRenderCommandEncoder - 渲染命令编码器
pub const MTLRenderCommandEncoder = opaque {};

/// MTLComputeCommandEncoder - 计算命令编码器
pub const MTLComputeCommandEncoder = opaque {};

/// MTLBlitCommandEncoder - Blit 命令编码器
pub const MTLBlitCommandEncoder = opaque {};

/// MTLRenderPassDescriptor - 渲染通道描述符
pub const MTLRenderPassDescriptor = opaque {};

/// CAMetalLayer - Metal 层
pub const CAMetalLayer = opaque {};

/// CAMetalDrawable - Metal 可绘制对象
pub const CAMetalDrawable = opaque {};

// ============================================================================
// Enums - Metal 枚举类型
// ============================================================================

/// MTLStorageMode - 存储模式
pub const MTLStorageMode = enum(c_uint) {
    Shared = 0,
    Managed = 1,
    Private = 2,
    Memoryless = 3,
};

/// MTLResourceOptions - 资源选项（简化版，只使用存储模式）
pub const MTLResourceOptions = c_uint;

/// 便捷函数：从存储模式创建 ResourceOptions
pub fn resourceOptionsFromStorageMode(mode: MTLStorageMode) MTLResourceOptions {
    return @as(c_uint, @intFromEnum(mode)) << 4;
}

/// MTLPixelFormat - 像素格式
pub const MTLPixelFormat = enum(c_ulong) {
    Invalid = 0,
    // 8-bit formats
    A8Unorm = 1,
    R8Unorm = 10,
    R8Snorm = 12,
    R8Uint = 13,
    R8Sint = 14,
    // 16-bit formats
    R16Unorm = 20,
    R16Snorm = 22,
    R16Uint = 23,
    R16Sint = 24,
    R16Float = 25,
    RG8Unorm = 30,
    RG8Snorm = 32,
    RG8Uint = 33,
    RG8Sint = 34,
    // 32-bit formats
    R32Uint = 53,
    R32Sint = 54,
    R32Float = 55,
    RG16Unorm = 60,
    RG16Snorm = 62,
    RG16Uint = 63,
    RG16Sint = 64,
    RG16Float = 65,
    RGBA8Unorm = 70,
    RGBA8Unorm_sRGB = 71,
    RGBA8Snorm = 72,
    RGBA8Uint = 73,
    RGBA8Sint = 74,
    BGRA8Unorm = 80,
    BGRA8Unorm_sRGB = 81,
    RGB10A2Unorm = 90,
    // 64-bit formats
    RG32Uint = 103,
    RG32Sint = 104,
    RG32Float = 105,
    RGBA16Unorm = 110,
    RGBA16Snorm = 112,
    RGBA16Uint = 113,
    RGBA16Sint = 114,
    RGBA16Float = 115,
    // 128-bit formats
    RGBA32Uint = 123,
    RGBA32Sint = 124,
    RGBA32Float = 125,
    // Depth formats
    Depth16Unorm = 250,
    Depth32Float = 252,
    Stencil8 = 253,
    Depth32Float_Stencil8 = 260,
    // BC compressed formats
    BC1_RGBA = 130,
    BC1_RGBA_sRGB = 131,
    BC2_RGBA = 132,
    BC2_RGBA_sRGB = 133,
    BC3_RGBA = 134,
    BC3_RGBA_sRGB = 135,
    BC4_RUnorm = 140,
    BC4_RSnorm = 141,
    BC5_RGUnorm = 142,
    BC5_RGSnorm = 143,
    BC6H_RGBFloat = 150,
    BC6H_RGBUfloat = 151,
    BC7_RGBAUnorm = 152,
    BC7_RGBAUnorm_sRGB = 153,
};

/// MTLTextureType - 纹理类型
pub const MTLTextureType = enum(c_ulong) {
    Type1D = 0,
    Type1DArray = 1,
    Type2D = 2,
    Type2DArray = 3,
    Type2DMultisample = 4,
    TypeCube = 5,
    TypeCubeArray = 6,
    Type3D = 7,
    Type2DMultisampleArray = 8,
    TypeTextureBuffer = 9,
};

/// MTLTextureUsage - 纹理用途
pub const MTLTextureUsage = enum(c_ulong) {
    Unknown = 0x0000,
    ShaderRead = 0x0001,
    ShaderWrite = 0x0002,
    RenderTarget = 0x0004,
    PixelFormatView = 0x0008,
};

/// MTLSamplerMinMagFilter - 采样器过滤模式
pub const MTLSamplerMinMagFilter = enum(c_ulong) {
    Nearest = 0,
    Linear = 1,
};

/// MTLSamplerMipFilter - 采样器 MIP 过滤模式
pub const MTLSamplerMipFilter = enum(c_ulong) {
    NotMipmapped = 0,
    Nearest = 1,
    Linear = 2,
};

/// MTLSamplerAddressMode - 采样器地址模式
pub const MTLSamplerAddressMode = enum(c_ulong) {
    ClampToEdge = 0,
    MirrorClampToEdge = 1,
    Repeat = 2,
    MirrorRepeat = 3,
    ClampToZero = 4,
    ClampToBorderColor = 5,
};

/// MTLLoadAction - 加载操作
pub const MTLLoadAction = enum(c_ulong) {
    DontCare = 0,
    Load = 1,
    Clear = 2,
};

/// MTLStoreAction - 存储操作
pub const MTLStoreAction = enum(c_ulong) {
    DontCare = 0,
    Store = 1,
    MultisampleResolve = 2,
    StoreAndMultisampleResolve = 3,
    Unknown = 4,
    CustomSampleDepthStore = 5,
};

/// MTLPrimitiveType - 基元类型
pub const MTLPrimitiveType = enum(c_ulong) {
    Point = 0,
    Line = 1,
    LineStrip = 2,
    Triangle = 3,
    TriangleStrip = 4,
};

/// MTLIndexType - 索引类型
pub const MTLIndexType = enum(c_ulong) {
    UInt16 = 0,
    UInt32 = 1,
};

/// MTLCompareFunction - 比较函数
pub const MTLCompareFunction = enum(c_ulong) {
    Never = 0,
    Less = 1,
    Equal = 2,
    LessEqual = 3,
    Greater = 4,
    NotEqual = 5,
    GreaterEqual = 6,
    Always = 7,
};

/// MTLCullMode - 剔除模式
pub const MTLCullMode = enum(c_ulong) {
    None = 0,
    Front = 1,
    Back = 2,
};

/// MTLWinding - 绕序
pub const MTLWinding = enum(c_ulong) {
    Clockwise = 0,
    CounterClockwise = 1,
};

/// MTLVertexFormat - 顶点格式
pub const MTLVertexFormat = enum(c_ulong) {
    Invalid = 0,
    UChar2 = 1,
    UChar3 = 2,
    UChar4 = 3,
    Char2 = 4,
    Char3 = 5,
    Char4 = 6,
    UChar2Normalized = 7,
    UChar3Normalized = 8,
    UChar4Normalized = 9,
    Char2Normalized = 10,
    Char3Normalized = 11,
    Char4Normalized = 12,
    UShort2 = 13,
    UShort3 = 14,
    UShort4 = 15,
    Short2 = 16,
    Short3 = 17,
    Short4 = 18,
    UShort2Normalized = 19,
    UShort3Normalized = 20,
    UShort4Normalized = 21,
    Short2Normalized = 22,
    Short3Normalized = 23,
    Short4Normalized = 24,
    Half2 = 25,
    Half3 = 26,
    Half4 = 27,
    Float = 28,
    Float2 = 29,
    Float3 = 30,
    Float4 = 31,
    Int = 32,
    Int2 = 33,
    Int3 = 34,
    Int4 = 35,
    UInt = 36,
    UInt2 = 37,
    UInt3 = 38,
    UInt4 = 39,
};

/// MTLVertexStepFunction - 顶点步进函数
pub const MTLVertexStepFunction = enum(c_ulong) {
    Constant = 0,
    PerVertex = 1,
    PerInstance = 2,
    PerPatch = 3,
    PerPatchControlPoint = 4,
};

// ============================================================================
// Structures
// ============================================================================

/// MTLClearColor - 清除颜色
pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

/// MTLSize - 3D 尺寸
pub const MTLSize = extern struct {
    width: c_ulong,
    height: c_ulong,
    depth: c_ulong,
};

/// MTLOrigin - 3D 原点
pub const MTLOrigin = extern struct {
    x: c_ulong,
    y: c_ulong,
    z: c_ulong,
};

/// MTLRegion - 3D 区域
pub const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

// ============================================================================
// External C Functions (待实现在 native/metal_bridge.m)
// ============================================================================

// 注意: 这些函数声明将在阶段 3 实现
// 现在先定义接口，让代码能编译通过

// Device Management
pub extern "c" fn metal_create_system_default_device() ?*MTLDevice;
/// out_count 回传系统设备总数；返回值 = 实际写入 out_devices 的条数
/// （min(capacity, 总数)，每条 +1 retained 归调用者）。桥保证不写超过 capacity。
pub extern "c" fn metal_copy_all_devices(out_count: *usize, out_devices: ?[*]?*anyopaque, capacity: usize) usize;
pub extern "c" fn metal_device_get_name(device: *MTLDevice) [*:0]const u8;
pub extern "c" fn metal_device_new_command_queue(device: *MTLDevice) ?*MTLCommandQueue;

// Buffer Management
pub extern "c" fn metal_device_new_buffer(device: *MTLDevice, length: usize, options: MTLResourceOptions) ?*MTLBuffer;
pub extern "c" fn metal_buffer_contents(buffer: *MTLBuffer) ?*anyopaque;
pub extern "c" fn metal_buffer_get_length(buffer: *MTLBuffer) usize;
pub extern "c" fn metal_buffer_set_label(buffer: *MTLBuffer, label: [*:0]const u8) void;

// Texture/Sampler Convenience Functions
pub extern "c" fn metal_texture_descriptor_new() ?*MTLTextureDescriptor;
pub extern "c" fn metal_texture_descriptor_set_pixel_format(desc: *MTLTextureDescriptor, format: c_ulong) void;
pub extern "c" fn metal_texture_descriptor_set_width(desc: *MTLTextureDescriptor, width: usize) void;
pub extern "c" fn metal_texture_descriptor_set_height(desc: *MTLTextureDescriptor, height: usize) void;
pub extern "c" fn metal_texture_descriptor_set_depth(desc: *MTLTextureDescriptor, depth: usize) void;
pub extern "c" fn metal_texture_descriptor_set_mipmap_level_count(desc: *MTLTextureDescriptor, count: usize) void;
pub extern "c" fn metal_texture_descriptor_set_sample_count(desc: *MTLTextureDescriptor, count: usize) void;
pub extern "c" fn metal_texture_descriptor_set_texture_type(desc: *MTLTextureDescriptor, texture_type: c_ulong) void;
pub extern "c" fn metal_texture_descriptor_set_usage(desc: *MTLTextureDescriptor, usage: c_ulong) void;
pub extern "c" fn metal_texture_descriptor_set_storage_mode(desc: *MTLTextureDescriptor, mode: c_ulong) void;
pub extern "c" fn metal_device_new_texture(device: *MTLDevice, desc: *MTLTextureDescriptor) ?*MTLTexture;
pub extern "c" fn metal_sampler_descriptor_new() ?*MTLSamplerDescriptor;
pub extern "c" fn metal_sampler_descriptor_set_min_filter(desc: *MTLSamplerDescriptor, filter: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_mag_filter(desc: *MTLSamplerDescriptor, filter: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_mip_filter(desc: *MTLSamplerDescriptor, filter: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_address_mode_u(desc: *MTLSamplerDescriptor, mode: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_address_mode_v(desc: *MTLSamplerDescriptor, mode: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_address_mode_w(desc: *MTLSamplerDescriptor, mode: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_compare_function(desc: *MTLSamplerDescriptor, function: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_lod_min_clamp(desc: *MTLSamplerDescriptor, value: f32) void;
pub extern "c" fn metal_sampler_descriptor_set_lod_max_clamp(desc: *MTLSamplerDescriptor, value: f32) void;
pub extern "c" fn metal_sampler_descriptor_set_max_anisotropy(desc: *MTLSamplerDescriptor, value: c_ulong) void;
pub extern "c" fn metal_sampler_descriptor_set_label(desc: *MTLSamplerDescriptor, label: [*:0]const u8) void;
pub extern "c" fn metal_device_new_sampler(device: *MTLDevice, desc: *MTLSamplerDescriptor) ?*MTLSamplerState;
pub extern "c" fn metal_device_create_texture(device: *MTLDevice, width: c_uint, height: c_uint, pixelFormat: c_ulong, usage: c_ulong, storageMode: c_ulong) ?*MTLTexture;
pub extern "c" fn metal_device_create_texture_mipmapped(device: *MTLDevice, width: c_uint, height: c_uint, pixelFormat: c_ulong, usage: c_ulong, storageMode: c_ulong, mipmapped: c_int) ?*MTLTexture;
pub extern "c" fn metal_device_create_sampler(device: *MTLDevice, minFilter: c_ulong, magFilter: c_ulong, sAddressMode: c_ulong, tAddressMode: c_ulong) ?*MTLSamplerState;
pub extern "c" fn metal_device_create_sampler_with_mip(device: *MTLDevice, minFilter: c_ulong, magFilter: c_ulong, mipFilter: c_ulong, sAddressMode: c_ulong, tAddressMode: c_ulong) ?*MTLSamplerState;
pub extern "c" fn metal_texture_set_label(texture: *MTLTexture, label: [*:0]const u8) void;
pub extern "c" fn metal_texture_get_width(texture: *MTLTexture) c_uint;
pub extern "c" fn metal_texture_get_height(texture: *MTLTexture) c_uint;
pub extern "c" fn metal_texture_replace_region(texture: *MTLTexture, x: c_uint, y: c_uint, width: c_uint, height: c_uint, bytes: [*]const u8, bytesPerRow: c_uint) void;
pub extern "c" fn metal_texture_replace_region_level(texture: *MTLTexture, x: c_uint, y: c_uint, width: c_uint, height: c_uint, mipLevel: c_ulong, bytes: [*]const u8, bytesPerRow: c_uint) void;
pub extern "c" fn metal_texture_read_bgra8(texture: *MTLTexture, out_bytes: [*]u8, bytes_per_row: c_uint, width: c_uint, height: c_uint) c_int;

// 图像写出（image_bridge.m），把 RGBA8 像素编码成 PNG 落盘。
// 返回 0 成功，负数失败。用于 e2e 截图验证。
pub extern "c" fn macos_write_png_from_rgba(path_cstr: [*:0]const u8, rgba: [*]const u8, width: c_uint, height: c_uint, bytes_per_row: c_uint) c_int;

// Command Queue
pub extern "c" fn metal_command_queue_command_buffer(queue: *MTLCommandQueue) ?*MTLCommandBuffer;

// Command Buffer
pub extern "c" fn metal_command_buffer_commit(buffer: *MTLCommandBuffer) void;
pub extern "c" fn metal_command_buffer_wait_until_completed(buffer: *MTLCommandBuffer) void;

/// GPU 实际执行起止时刻（秒，CPU 时间基准）。**仅在 command buffer 完成后有效**，
/// 未完成时返回 0。这是真 GPU 时间，区别于 FrameStats.gpu_encode_us 那个
/// 混入 wait/acquire 的 CPU 墙钟（审查报告 §4）。
pub extern "c" fn metal_command_buffer_gpu_start_time(buffer: *MTLCommandBuffer) f64;
pub extern "c" fn metal_command_buffer_gpu_end_time(buffer: *MTLCommandBuffer) f64;

/// 非阻塞查询是否已到终态（completed / error）。
pub extern "c" fn metal_command_buffer_is_completed(buffer: *MTLCommandBuffer) bool;

// Reference Counting
pub extern "c" fn metal_release(obj: *anyopaque) void;
pub extern "c" fn metal_retain(obj: *anyopaque) *anyopaque;

// CAMetalLayer Management
pub extern "c" fn metal_layer_set_device(layer: *CAMetalLayer, device: *MTLDevice) void;
pub extern "c" fn metal_layer_set_pixel_format(layer: *CAMetalLayer, format: c_ulong) void;
pub extern "c" fn metal_layer_set_framebuffer_only(layer: *CAMetalLayer, value: c_int) void;
pub extern "c" fn metal_layer_set_maximum_drawable_count(layer: *CAMetalLayer, count: usize) void;
pub extern "c" fn metal_layer_set_display_sync_enabled(layer: *CAMetalLayer, enabled: c_int) void;
pub extern "c" fn metal_layer_set_allows_next_drawable_timeout(layer: *CAMetalLayer, allows: c_int) void;
pub extern "c" fn metal_layer_set_opaque(layer: *CAMetalLayer, is_opaque: c_int) void;
pub extern "c" fn metal_layer_set_wants_edr(layer: *CAMetalLayer, wants: c_int) void;
pub extern "c" fn metal_layer_set_drawable_size(layer: *CAMetalLayer, width: c_uint, height: c_uint) void;
pub extern "c" fn metal_layer_next_drawable(layer: *CAMetalLayer) ?*CAMetalDrawable;
pub extern "c" fn metal_drawable_get_texture(drawable: *CAMetalDrawable) *MTLTexture;
pub extern "c" fn metal_drawable_present(drawable: *CAMetalDrawable) void;
pub extern "c" fn metal_layer_presents_with_transaction(layer: *CAMetalLayer) c_int;

pub const MetalLayerBounds = extern struct {
    width: f64,
    height: f64,
};
pub extern "c" fn metal_layer_get_bounds(layer: *CAMetalLayer) MetalLayerBounds;
pub extern "c" fn metal_layer_get_contents_scale(layer: *CAMetalLayer) f64;

// Command Buffer Presentation
pub extern "c" fn metal_command_buffer_present_drawable(buffer: *MTLCommandBuffer, drawable: *CAMetalDrawable) void;
pub extern "c" fn metal_command_buffer_wait_until_scheduled(buffer: *MTLCommandBuffer) void;
pub extern "c" fn metal_queue_command_buffer(queue: *MTLCommandQueue) ?*MTLCommandBuffer;

// ============================================================================
// Helper Functions
// ============================================================================

/// 创建系统默认 Metal 设备
pub fn createSystemDefaultDevice() ?*MTLDevice {
    return metal_create_system_default_device();
}

/// 释放 Metal 对象
pub fn release(obj: anytype) void {
    metal_release(@ptrCast(obj));
}

/// 保留 Metal 对象
pub fn retain(obj: anytype) @TypeOf(obj) {
    return @ptrCast(@alignCast(metal_retain(@ptrCast(obj))));
}

// ============================================================================
// Autorelease Pool
// ============================================================================

pub extern "c" fn objc_autoreleasepool_push() ?*anyopaque;
pub extern "c" fn objc_autoreleasepool_pop(pool: *anyopaque) void;

/// Autorelease Pool RAII 包装器
pub const AutoreleasePool = struct {
    pool: *anyopaque,

    pub fn init() AutoreleasePool {
        return AutoreleasePool{
            .pool = objc_autoreleasepool_push() orelse unreachable,
        };
    }

    pub fn deinit(self: *AutoreleasePool) void {
        objc_autoreleasepool_pop(self.pool);
    }
};

/// 在 autorelease pool 中执行函数
/// 使用示例:
/// ```zig
/// const result = autoreleasepool(struct {
///     fn call(ctx: *Context) !Result {
///         // ... Metal API 调用 ...
///         return result;
///     }
/// }.call, &context);
/// ```
pub fn autoreleasepool(comptime func: anytype, context: anytype) @typeInfo(@TypeOf(func)).Fn.return_type.? {
    var pool = AutoreleasePool.init();
    defer pool.deinit();
    return func(context);
}

// ============================================================================
// Render Pass Descriptor
// ============================================================================

pub const MTLRenderPassColorAttachmentDescriptor = opaque {};
pub const MTLRenderPassDepthAttachmentDescriptor = opaque {};
pub const MTLRenderPassStencilAttachmentDescriptor = opaque {};

pub extern "c" fn metal_render_pass_descriptor_new() *MTLRenderPassDescriptor;
pub extern "c" fn metal_render_pass_get_color_attachment(desc: *MTLRenderPassDescriptor, index: c_ulong) *MTLRenderPassColorAttachmentDescriptor;
pub extern "c" fn metal_render_pass_get_depth_attachment(desc: *MTLRenderPassDescriptor) *MTLRenderPassDepthAttachmentDescriptor;
pub extern "c" fn metal_render_pass_get_stencil_attachment(desc: *MTLRenderPassDescriptor) *MTLRenderPassStencilAttachmentDescriptor;

// Color Attachment
pub extern "c" fn metal_color_attachment_set_texture(attachment: *MTLRenderPassColorAttachmentDescriptor, texture: ?*MTLTexture) void;
pub extern "c" fn metal_color_attachment_set_load_action(attachment: *MTLRenderPassColorAttachmentDescriptor, action: c_ulong) void;
pub extern "c" fn metal_color_attachment_set_store_action(attachment: *MTLRenderPassColorAttachmentDescriptor, action: c_ulong) void;
pub extern "c" fn metal_color_attachment_set_clear_color(attachment: *MTLRenderPassColorAttachmentDescriptor, r: f64, g: f64, b: f64, a: f64) void;
pub extern "c" fn metal_color_attachment_set_resolve_texture(attachment: *MTLRenderPassColorAttachmentDescriptor, texture: ?*MTLTexture) void;

// Depth Attachment
pub extern "c" fn metal_depth_attachment_set_texture(attachment: *MTLRenderPassDepthAttachmentDescriptor, texture: ?*MTLTexture) void;
pub extern "c" fn metal_depth_attachment_set_load_action(attachment: *MTLRenderPassDepthAttachmentDescriptor, action: c_ulong) void;
pub extern "c" fn metal_depth_attachment_set_store_action(attachment: *MTLRenderPassDepthAttachmentDescriptor, action: c_ulong) void;
pub extern "c" fn metal_depth_attachment_set_clear_depth(attachment: *MTLRenderPassDepthAttachmentDescriptor, depth: f64) void;

// Stencil Attachment
pub extern "c" fn metal_stencil_attachment_set_texture(attachment: *MTLRenderPassStencilAttachmentDescriptor, texture: ?*MTLTexture) void;
pub extern "c" fn metal_stencil_attachment_set_load_action(attachment: *MTLRenderPassStencilAttachmentDescriptor, action: c_ulong) void;
pub extern "c" fn metal_stencil_attachment_set_store_action(attachment: *MTLRenderPassStencilAttachmentDescriptor, action: c_ulong) void;
pub extern "c" fn metal_stencil_attachment_set_clear_stencil(attachment: *MTLRenderPassStencilAttachmentDescriptor, stencil: c_uint) void;

// ============================================================================
// Render Command Encoder
// ============================================================================

pub extern "c" fn metal_command_buffer_create_render_encoder(buffer: *MTLCommandBuffer, desc: *MTLRenderPassDescriptor) ?*MTLRenderCommandEncoder;
pub extern "c" fn metal_render_encoder_end_encoding(encoder: *MTLRenderCommandEncoder) void;
pub extern "c" fn metal_render_encoder_set_render_pipeline_state(encoder: *MTLRenderCommandEncoder, pipeline: *MTLRenderPipelineState) void;
pub extern "c" fn metal_render_encoder_set_viewport(encoder: *MTLRenderCommandEncoder, x: f64, y: f64, width: f64, height: f64, znear: f64, zfar: f64) void;
pub extern "c" fn metal_render_encoder_set_scissor_rect(encoder: *MTLRenderCommandEncoder, x: c_ulong, y: c_ulong, width: c_ulong, height: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_cull_mode(encoder: *MTLRenderCommandEncoder, mode: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_front_facing_winding(encoder: *MTLRenderCommandEncoder, winding: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_triangle_fill_mode(encoder: *MTLRenderCommandEncoder, fillMode: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_depth_stencil_state(encoder: *MTLRenderCommandEncoder, state: ?*MTLDepthStencilState) void;
pub extern "c" fn metal_render_encoder_set_depth_bias(encoder: *MTLRenderCommandEncoder, constant: f32, slope: f32, clamp: f32) void;

// Resource Binding
pub extern "c" fn metal_render_encoder_set_vertex_buffer(encoder: *MTLRenderCommandEncoder, buffer: ?*MTLBuffer, offset: c_ulong, index: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_fragment_buffer(encoder: *MTLRenderCommandEncoder, buffer: ?*MTLBuffer, offset: c_ulong, index: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_vertex_texture(encoder: *MTLRenderCommandEncoder, texture: ?*MTLTexture, index: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_fragment_texture(encoder: *MTLRenderCommandEncoder, texture: ?*MTLTexture, index: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_vertex_sampler(encoder: *MTLRenderCommandEncoder, sampler: ?*MTLSamplerState, index: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_fragment_sampler(encoder: *MTLRenderCommandEncoder, sampler: ?*MTLSamplerState, index: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_vertex_bytes(encoder: *MTLRenderCommandEncoder, bytes: *const anyopaque, length: c_ulong, index: c_ulong) void;
pub extern "c" fn metal_render_encoder_set_fragment_bytes(encoder: *MTLRenderCommandEncoder, bytes: *const anyopaque, length: c_ulong, index: c_ulong) void;

// Draw Calls
pub extern "c" fn metal_render_encoder_draw_primitives(encoder: *MTLRenderCommandEncoder, primitiveType: c_ulong, vertexStart: c_ulong, vertexCount: c_ulong) void;
pub extern "c" fn metal_render_encoder_draw_primitives_instanced(encoder: *MTLRenderCommandEncoder, primitiveType: c_ulong, vertexStart: c_ulong, vertexCount: c_ulong, instanceCount: c_ulong) void;
pub extern "c" fn metal_render_encoder_draw_primitives_instanced_base_instance(encoder: *MTLRenderCommandEncoder, primitiveType: c_ulong, vertexStart: c_ulong, vertexCount: c_ulong, instanceCount: c_ulong, baseInstance: c_ulong) void;
pub extern "c" fn metal_render_encoder_draw_indexed_primitives(encoder: *MTLRenderCommandEncoder, primitiveType: c_ulong, indexCount: c_ulong, indexType: c_ulong, indexBuffer: *MTLBuffer, indexBufferOffset: c_ulong) void;
pub extern "c" fn metal_render_encoder_draw_indexed_primitives_instanced(encoder: *MTLRenderCommandEncoder, primitiveType: c_ulong, indexCount: c_ulong, indexType: c_ulong, indexBuffer: *MTLBuffer, indexBufferOffset: c_ulong, instanceCount: c_ulong) void;
pub extern "c" fn metal_render_encoder_draw_indexed_primitives_full(encoder: *MTLRenderCommandEncoder, primitiveType: c_ulong, indexCount: c_ulong, indexType: c_ulong, indexBuffer: *MTLBuffer, indexBufferOffset: c_ulong, instanceCount: c_ulong, baseVertex: c_ulong, baseInstance: c_ulong) void;

// ============================================================================
// Compute Command Encoder
// ============================================================================

pub extern "c" fn metal_command_buffer_create_compute_encoder(buffer: *MTLCommandBuffer) ?*MTLComputeCommandEncoder;
pub extern "c" fn metal_compute_encoder_end_encoding(encoder: *MTLComputeCommandEncoder) void;
pub extern "c" fn metal_compute_encoder_set_compute_pipeline_state(encoder: *MTLComputeCommandEncoder, pipeline: *MTLComputePipelineState) void;
pub extern "c" fn metal_compute_encoder_set_buffer(encoder: *MTLComputeCommandEncoder, buffer: ?*MTLBuffer, offset: c_ulong, index: c_ulong) void;
pub extern "c" fn metal_compute_encoder_set_texture(encoder: *MTLComputeCommandEncoder, texture: ?*MTLTexture, index: c_ulong) void;
pub extern "c" fn metal_compute_encoder_set_sampler(encoder: *MTLComputeCommandEncoder, sampler: ?*MTLSamplerState, index: c_ulong) void;
pub extern "c" fn metal_compute_encoder_set_bytes(encoder: *MTLComputeCommandEncoder, bytes: *const anyopaque, length: c_ulong, index: c_ulong) void;
pub extern "c" fn metal_compute_encoder_set_threadgroup_memory_length(encoder: *MTLComputeCommandEncoder, length: c_ulong, index: c_ulong) void;
pub extern "c" fn metal_compute_encoder_dispatch_threadgroups(encoder: *MTLComputeCommandEncoder, threadgroupsX: c_ulong, threadgroupsY: c_ulong, threadgroupsZ: c_ulong, threadsPerGroupX: c_ulong, threadsPerGroupY: c_ulong, threadsPerGroupZ: c_ulong) void;

// ============================================================================
// GPU Frame Synchronization (dispatch_semaphore)
// ============================================================================

/// dispatch_semaphore_t, GCD 信号量，用于 CPU/GPU 帧同步
pub const dispatch_semaphore_t = *anyopaque;

/// 创建信号量（初始值 = value）
pub extern "c" fn dispatch_semaphore_create(value: c_long) ?dispatch_semaphore_t;

/// 等待信号量（递减，timeout = DISPATCH_TIME_FOREVER）
pub extern "c" fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: u64) c_long;

/// 发送信号量（递增）
pub extern "c" fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) c_long;

/// 释放 dispatch 对象。dispatch_semaphore_t 在 Zig 侧是裸 extern 指针，
/// 不受 ARC 管辖，create 后必须显式 release，否则每个 FrameSync 生命周期
/// 泄漏一个信号量对象（多窗口反复开关线性累积）。
pub extern "c" fn dispatch_release(object: dispatch_semaphore_t) void;

/// DISPATCH_TIME_FOREVER
pub const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);

/// Command Buffer 添加完成回调
pub extern "c" fn metal_command_buffer_add_completed_handler(
    buffer: *MTLCommandBuffer,
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) callconv(.c) void,
) void;

/// Command Buffer 错误观测：完成时 status == Error 才回调（Metal completion
/// 线程；desc 只在回调期间有效）。
pub extern "c" fn metal_command_buffer_notify_error(
    buffer: *MTLCommandBuffer,
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, c_long, [*:0]const u8) callconv(.c) void,
) void;

// ============================================================================
// Blit Command Encoder
// ============================================================================

pub extern "c" fn metal_command_buffer_create_blit_encoder(buffer: *MTLCommandBuffer) ?*MTLBlitCommandEncoder;
pub extern "c" fn metal_blit_encoder_end_encoding(encoder: *MTLBlitCommandEncoder) void;
pub extern "c" fn metal_blit_encoder_copy_buffer(encoder: *MTLBlitCommandEncoder, sourceBuffer: *MTLBuffer, sourceOffset: c_ulong, destinationBuffer: *MTLBuffer, destinationOffset: c_ulong, size: c_ulong) void;
pub extern "c" fn metal_blit_encoder_copy_texture(encoder: *MTLBlitCommandEncoder, sourceTexture: *MTLTexture, sourceSlice: c_ulong, sourceLevel: c_ulong, destinationTexture: *MTLTexture, destinationSlice: c_ulong, destinationLevel: c_ulong, width: c_ulong, height: c_ulong, depth: c_ulong) void;
pub extern "c" fn metal_blit_encoder_copy_texture_region(encoder: *MTLBlitCommandEncoder, sourceTexture: *MTLTexture, src_x: c_ulong, src_y: c_ulong, width: c_ulong, height: c_ulong, destinationTexture: *MTLTexture, dst_x: c_ulong, dst_y: c_ulong) void;

// ============================================================================
// Shader Library Management
// ============================================================================

pub extern "c" fn metal_device_new_library_from_source(device: *MTLDevice, source: [*:0]const u8, error_out: ?*?[*:0]u8) ?*MTLLibrary;
pub extern "c" fn metal_library_new_function(library: *MTLLibrary, name: [*:0]const u8) ?*MTLFunction;

// ============================================================================
// Render Pipeline Management
// ============================================================================

pub extern "c" fn metal_render_pipeline_descriptor_new() *MTLRenderPipelineDescriptor;
pub extern "c" fn metal_render_pipeline_descriptor_set_vertex_function(desc: *MTLRenderPipelineDescriptor, function: ?*MTLFunction) void;
pub extern "c" fn metal_render_pipeline_descriptor_set_fragment_function(desc: *MTLRenderPipelineDescriptor, function: ?*MTLFunction) void;
pub extern "c" fn metal_render_pipeline_descriptor_set_color_attachment_format(desc: *MTLRenderPipelineDescriptor, index: c_ulong, format: c_ulong) void;
pub extern "c" fn metal_render_pipeline_descriptor_set_depth_attachment_format(desc: *MTLRenderPipelineDescriptor, format: c_ulong) void;
pub extern "c" fn metal_render_pipeline_descriptor_set_stencil_attachment_format(desc: *MTLRenderPipelineDescriptor, format: c_ulong) void;
pub extern "c" fn metal_render_pipeline_descriptor_set_sample_count(desc: *MTLRenderPipelineDescriptor, count: c_ulong) void;
pub extern "c" fn metal_render_pipeline_descriptor_set_vertex_descriptor(desc: *MTLRenderPipelineDescriptor, vertex_desc: ?*MTLVertexDescriptor) void;
pub extern "c" fn metal_device_new_render_pipeline_state(device: *MTLDevice, desc: *MTLRenderPipelineDescriptor, error_out: ?*[*:0]u8) ?*MTLRenderPipelineState;

// ============================================================================
// Vertex Descriptor Management
// ============================================================================

pub const MTLVertexDescriptor = opaque {};

pub extern "c" fn metal_vertex_descriptor_new() *MTLVertexDescriptor;
pub extern "c" fn metal_vertex_descriptor_set_attribute_format(desc: *MTLVertexDescriptor, index: c_ulong, format: c_ulong) void;
pub extern "c" fn metal_vertex_descriptor_set_attribute_offset(desc: *MTLVertexDescriptor, index: c_ulong, offset: c_ulong) void;
pub extern "c" fn metal_vertex_descriptor_set_attribute_buffer_index(desc: *MTLVertexDescriptor, index: c_ulong, buffer_index: c_ulong) void;
pub extern "c" fn metal_vertex_descriptor_set_layout_stride(desc: *MTLVertexDescriptor, index: c_ulong, stride: c_ulong) void;
pub extern "c" fn metal_vertex_descriptor_set_layout_step_function(desc: *MTLVertexDescriptor, index: c_ulong, step_function: c_ulong) void;
pub extern "c" fn metal_vertex_descriptor_set_layout_step_rate(desc: *MTLVertexDescriptor, index: c_ulong, step_rate: c_ulong) void;

// ============================================================================
// Depth Stencil State Management
// ============================================================================

pub const MTLDepthStencilDescriptor = opaque {};

pub extern "c" fn metal_depth_stencil_descriptor_new() *MTLDepthStencilDescriptor;
pub extern "c" fn metal_depth_stencil_descriptor_set_depth_compare_function(desc: *MTLDepthStencilDescriptor, compare_function: c_ulong) void;
pub extern "c" fn metal_depth_stencil_descriptor_set_depth_write_enabled(desc: *MTLDepthStencilDescriptor, enabled: c_int) void;
pub extern "c" fn metal_device_new_depth_stencil_state(device: *MTLDevice, desc: *MTLDepthStencilDescriptor) ?*MTLDepthStencilState;

// ============================================================================
// Color Attachment Blending
// ============================================================================

pub extern "c" fn metal_render_pipeline_color_attachment_set_blending_enabled(desc: *MTLRenderPipelineDescriptor, index: c_ulong, enabled: c_int) void;
pub extern "c" fn metal_render_pipeline_color_attachment_set_source_rgb_blend_factor(desc: *MTLRenderPipelineDescriptor, index: c_ulong, factor: c_ulong) void;
pub extern "c" fn metal_render_pipeline_color_attachment_set_destination_rgb_blend_factor(desc: *MTLRenderPipelineDescriptor, index: c_ulong, factor: c_ulong) void;
pub extern "c" fn metal_render_pipeline_color_attachment_set_rgb_blend_operation(desc: *MTLRenderPipelineDescriptor, index: c_ulong, operation: c_ulong) void;
pub extern "c" fn metal_render_pipeline_color_attachment_set_source_alpha_blend_factor(desc: *MTLRenderPipelineDescriptor, index: c_ulong, factor: c_ulong) void;
pub extern "c" fn metal_render_pipeline_color_attachment_set_destination_alpha_blend_factor(desc: *MTLRenderPipelineDescriptor, index: c_ulong, factor: c_ulong) void;
pub extern "c" fn metal_render_pipeline_color_attachment_set_alpha_blend_operation(desc: *MTLRenderPipelineDescriptor, index: c_ulong, operation: c_ulong) void;
pub extern "c" fn metal_render_pipeline_color_attachment_set_write_mask(desc: *MTLRenderPipelineDescriptor, index: c_ulong, mask: c_ulong) void;
