/// Metal C API bindings
///
/// Provides Zig bindings to C API defined in native/metal_bridge.m.
/// All Metal API calls go through these C bridge functions.

// ============================================================================
// Opaque Types - Metal object handles
// ============================================================================

/// MTLDevice - Metal device
pub const MTLDevice = opaque {};

/// MTLCommandQueue - command queue
pub const MTLCommandQueue = opaque {};

/// MTLCommandBuffer - command buffer
pub const MTLCommandBuffer = opaque {};

/// MTLBuffer - GPU buffer
pub const MTLBuffer = opaque {};

/// MTLTexture - GPU texture
pub const MTLTexture = opaque {};

/// MTLTextureDescriptor - texture descriptor
pub const MTLTextureDescriptor = opaque {};

/// MTLSamplerState - sampler state
pub const MTLSamplerState = opaque {};

/// MTLSamplerDescriptor - sampler descriptor
pub const MTLSamplerDescriptor = opaque {};

/// MTLLibrary - shader library
pub const MTLLibrary = opaque {};

/// MTLFunction - shader function
pub const MTLFunction = opaque {};

/// MTLRenderPipelineState - render pipeline state
pub const MTLRenderPipelineState = opaque {};

/// MTLRenderPipelineDescriptor - render pipeline descriptor
pub const MTLRenderPipelineDescriptor = opaque {};

/// MTLDepthStencilState - depth stencil state
pub const MTLDepthStencilState = opaque {};

/// MTLComputePipelineState - compute pipeline state
pub const MTLComputePipelineState = opaque {};

/// MTLRenderCommandEncoder - render command encoder
pub const MTLRenderCommandEncoder = opaque {};

/// MTLComputeCommandEncoder - compute command encoder
pub const MTLComputeCommandEncoder = opaque {};

/// MTLBlitCommandEncoder - blit command encoder
pub const MTLBlitCommandEncoder = opaque {};

/// MTLRenderPassDescriptor - render pass descriptor
pub const MTLRenderPassDescriptor = opaque {};

/// CAMetalLayer - Metal layer
pub const CAMetalLayer = opaque {};

/// CAMetalDrawable - Metal drawable
pub const CAMetalDrawable = opaque {};

// ============================================================================
// Enums - Metal enum types
// ============================================================================

/// MTLStorageMode - storage mode
pub const MTLStorageMode = enum(c_uint) {
    Shared = 0,
    Managed = 1,
    Private = 2,
    Memoryless = 3,
};

/// MTLResourceOptions - resource options (simplified, storage mode only)
pub const MTLResourceOptions = c_uint;
/// MTLResourceCPUCacheModeWriteCombined (MTLCPUCacheModeWriteCombined in bits 0-3).
pub const MTLResourceCPUCacheModeWriteCombined: MTLResourceOptions = 1;

/// Convenience function: create ResourceOptions from storage mode.
pub fn resourceOptionsFromStorageMode(mode: MTLStorageMode) MTLResourceOptions {
    return @as(c_uint, @backingInt(mode)) << 4;
}

/// MTLPixelFormat - pixel format
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

/// MTLTextureType - texture type
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

/// MTLTextureUsage - texture usage
pub const MTLTextureUsage = enum(c_ulong) {
    Unknown = 0x0000,
    ShaderRead = 0x0001,
    ShaderWrite = 0x0002,
    RenderTarget = 0x0004,
    /// MTLTextureUsagePixelFormatView is bit 4 (0x10). 0x08 is not a Metal
    /// usage bit and the driver silently drops it.
    PixelFormatView = 0x0010,
};

/// MTLSamplerMinMagFilter - sampler min/mag filter mode
pub const MTLSamplerMinMagFilter = enum(c_ulong) {
    Nearest = 0,
    Linear = 1,
};

/// MTLSamplerMipFilter - sampler MIP filter mode
pub const MTLSamplerMipFilter = enum(c_ulong) {
    NotMipmapped = 0,
    Nearest = 1,
    Linear = 2,
};

/// MTLSamplerAddressMode - sampler address mode
pub const MTLSamplerAddressMode = enum(c_ulong) {
    ClampToEdge = 0,
    MirrorClampToEdge = 1,
    Repeat = 2,
    MirrorRepeat = 3,
    ClampToZero = 4,
    ClampToBorderColor = 5,
};

/// MTLLoadAction - load action
pub const MTLLoadAction = enum(c_ulong) {
    DontCare = 0,
    Load = 1,
    Clear = 2,
};

/// MTLStoreAction - store action
pub const MTLStoreAction = enum(c_ulong) {
    DontCare = 0,
    Store = 1,
    MultisampleResolve = 2,
    StoreAndMultisampleResolve = 3,
    Unknown = 4,
    CustomSampleDepthStore = 5,
};

/// MTLPrimitiveType - primitive type
pub const MTLPrimitiveType = enum(c_ulong) {
    Point = 0,
    Line = 1,
    LineStrip = 2,
    Triangle = 3,
    TriangleStrip = 4,
};

/// MTLIndexType - index type
pub const MTLIndexType = enum(c_ulong) {
    UInt16 = 0,
    UInt32 = 1,
};

/// MTLCompareFunction - compare function
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

/// MTLCullMode - cull mode
pub const MTLCullMode = enum(c_ulong) {
    None = 0,
    Front = 1,
    Back = 2,
};

/// MTLWinding - winding order
pub const MTLWinding = enum(c_ulong) {
    Clockwise = 0,
    CounterClockwise = 1,
};

/// MTLVertexFormat - vertex format
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

/// MTLVertexStepFunction - vertex step function
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

/// MTLClearColor - clear color
pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

/// MTLSize - 3D size
pub const MTLSize = extern struct {
    width: c_ulong,
    height: c_ulong,
    depth: c_ulong,
};

/// MTLOrigin - 3D origin
pub const MTLOrigin = extern struct {
    x: c_ulong,
    y: c_ulong,
    z: c_ulong,
};

/// MTLRegion - 3D region
pub const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

// ============================================================================
// External C Functions (to implement in native/metal_bridge.m)
// ============================================================================

// Note: implementation deferred to phase 3; defining interface now for compilation.

// Device Management
pub extern "c" fn metal_create_system_default_device() ?*MTLDevice;
/// out_count returns total system device count; return value = count actually written
/// to out_devices (min(capacity, total); each +1 retained to caller). Bridge guarantees
/// no overflow beyond capacity.
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
pub extern "c" fn metal_texture_descriptor_set_cpu_cache_write_combined(desc: *MTLTextureDescriptor) void;
/// MTLCPUCacheMode of a buffer or texture (0 = default cache, 1 = write-combined).
pub extern "c" fn metal_resource_cpu_cache_mode(resource: *anyopaque) c_ulong;
pub extern "c" fn metal_device_new_texture(device: *MTLDevice, desc: *MTLTextureDescriptor) ?*MTLTexture;
pub extern "c" fn metal_inventory_enabled() c_int;
pub extern "c" fn metal_resource_set_volatile(resource: *anyopaque, make_volatile: c_int) c_int;
pub extern "c" fn metal_inventory_note(resource: ?*anyopaque, site: ?*anyopaque) void;
pub extern "c" fn metal_inventory_dump(device: *MTLDevice, tag: [*:0]const u8) void;
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
pub extern "c" fn metal_texture_pixel_format(texture: *MTLTexture) c_ulong;
pub extern "c" fn metal_texture_usage(texture: *MTLTexture) c_ulong;
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

// Write image (image_bridge.m): encode RGBA8 pixels as PNG to disk. Return 0 on
// success, negative on failure. Used for e2e screenshot verification.
pub extern "c" fn macos_write_png_from_rgba(path_cstr: [*:0]const u8, rgba: [*]const u8, width: c_uint, height: c_uint, bytes_per_row: c_uint) c_int;

// Command Queue
pub extern "c" fn metal_command_queue_command_buffer(queue: *MTLCommandQueue) ?*MTLCommandBuffer;

// Command Buffer
pub extern "c" fn metal_command_buffer_commit(buffer: *MTLCommandBuffer) void;
pub extern "c" fn metal_command_buffer_wait_until_completed(buffer: *MTLCommandBuffer) void;

/// GPU actual execution start/end times (seconds, CPU time base). Valid only after
/// command buffer completes; returns 0 if incomplete. True GPU time, differs from
/// FrameStats.gpu_encode_us which mixes wait/acquire (see review report section 4).
pub extern "c" fn metal_command_buffer_gpu_start_time(buffer: *MTLCommandBuffer) f64;
pub extern "c" fn metal_command_buffer_gpu_end_time(buffer: *MTLCommandBuffer) f64;

/// Non-blocking query: has command buffer reached terminal state (completed/error)?
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
pub extern "c" fn metal_layer_purge_drawables(layer: *CAMetalLayer) void;
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

/// Create system default Metal device
pub fn createSystemDefaultDevice() ?*MTLDevice {
    return metal_create_system_default_device();
}

/// Release Metal object
pub fn release(obj: anytype) void {
    metal_release(@ptrCast(obj));
}

/// Retain Metal object
pub fn retain(obj: anytype) @TypeOf(obj) {
    return @ptrCast(@alignCast(metal_retain(@ptrCast(obj))));
}

// ============================================================================
// Autorelease Pool
// ============================================================================

pub extern "c" fn objc_autoreleasepool_push() ?*anyopaque;
pub extern "c" fn objc_autoreleasepool_pop(pool: *anyopaque) void;

/// Autorelease pool RAII wrapper
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

/// Execute function in autorelease pool
/// Usage example:
/// ```zig
/// const result = autoreleasepool(struct {
///     fn call(ctx: *Context) !Result {
///         // ... Metal API calls ...
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

pub extern "c" fn metal_command_buffer_create_attachmentless_render_encoder(buffer: *MTLCommandBuffer, width: c_uint, height: c_uint) ?*MTLRenderCommandEncoder;
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

/// dispatch_semaphore_t, GCD semaphore for CPU/GPU frame sync
pub const dispatch_semaphore_t = *anyopaque;

/// Create semaphore (initial value = value)
pub extern "c" fn dispatch_semaphore_create(value: c_long) ?dispatch_semaphore_t;

/// Wait semaphore (decrement, timeout = DISPATCH_TIME_FOREVER)
pub extern "c" fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: u64) c_long;

/// Signal semaphore (increment)
pub extern "c" fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) c_long;

/// Release dispatch object. dispatch_semaphore_t in Zig is bare extern pointer,
/// not ARC-managed; after create must explicitly release, else each FrameSync lifetime
/// leaks one semaphore (multi-window repeat open/close accumulates linearly).
pub extern "c" fn dispatch_release(object: dispatch_semaphore_t) void;

/// DISPATCH_TIME_FOREVER
pub const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);

/// Add completion callback to command buffer
pub extern "c" fn metal_command_buffer_add_completed_handler(
    buffer: *MTLCommandBuffer,
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) callconv(.c) void,
) void;

/// Command buffer error observation: calls only when status == Error at completion
/// (Metal completion thread; desc valid only during callback).
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

pub extern "c" fn metal_command_buffer_copy_texture_region_render(buffer: *MTLCommandBuffer, source: *MTLTexture, sx: u32, sy: u32, width: u32, height: u32, destination: *MTLTexture, dx: u32, dy: u32, clear: c_int) c_int;

pub extern "c" fn metal_device_supports_framebuffer_fetch(device: *MTLDevice) bool;
