/// Metal C API Bridge
///
/// 提供 C API 接口，让 Zig 代码能调用 Metal Objective-C API
///
/// 参考: wgpu-hal metal backend 和 metal-rs
///
/// ============================================================================
/// ⚠️ 所有权 ABI 合同（2026-07-29 确立 —— 违反会直接导致泄漏或 UAF）
/// ============================================================================
///
/// 本文件所有返回 `void*` 的函数遵循下列两条规则之一，**必须在函数注释中标明**：
///
///   [owned]    用 `__bridge_retained` 返回 +1 对象。调用方（Zig）直接接管
///              所有权，**不得再 retain**，用完 release 一次。
///              适用：create / new / copy / nextDrawable 这类"生产"函数。
///
///   [borrowed] 用 `__bridge` 返回 +0 对象。所有权仍属被查询的父对象，
///              Zig 侧**只有需要跨作用域保存时才 retain**（并自行 release）。
///              适用：单纯的属性 getter。
///
/// 历史教训：bridge 返回 +1、Zig 侧又 retain 一次、销毁只 release 一次 ——
/// 每帧净泄漏 CAMetalDrawable / MTLCommandBuffer / MTLRenderCommandEncoder。
/// drawable 池只有 2-3 个，几秒即耗尽 → nextDrawable 永久阻塞、画面冻死。
///
/// 已知例外（不要"顺手统一"，会引入新泄漏）：
///   `metal_drawable_get_texture` 定义在 **window_bridge.m:2966**，是
///   [borrowed]（`__bridge`）。Zig 侧 surface.zig 对它的 retain 是必需的。

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#import <stdint.h>

// ============================================================================
// Device Management
// ============================================================================

/// 创建系统默认 Metal 设备
void* metal_create_system_default_device(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return (__bridge_retained void*)device;
}

/// 获取所有 Metal 设备
/// @param out_count 输出系统当前设备总数
/// @param out_devices 输出设备数组（每个元素 +1 retained，归调用者），传 NULL 仅查询数量
/// @param capacity out_devices 的容量；写入数不会超过它
/// @return 实际写入 out_devices 的数量（min(capacity, 总数)）
///
/// 桥不写超过 capacity：两次调用（查数量→按数量分配→取设备）之间热插拔
/// eGPU 会让第二次的总数变大，无条件写满曾是堆越界写。
/// 本文件以 -fobjc-arc 编译：MTLCopyAllDevices 的 +1 返回由 ARC 在
/// 作用域结束时自动配平，无需手动 release。
size_t metal_copy_all_devices(size_t* out_count, void** out_devices, size_t capacity) {
    #if TARGET_OS_OSX
    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    size_t total = [devices count];
    *out_count = total;

    size_t written = 0;
    if (out_devices && devices) {
        size_t n = total < capacity ? total : capacity;
        for (size_t i = 0; i < n; i++) {
            out_devices[i] = (__bridge_retained void*)[devices objectAtIndex:i];
        }
        written = n;
    }

    return written;
    #else
    (void)capacity;
    *out_count = 0;
    return 0;
    #endif
}

/// 获取设备名称
/// @param device MTLDevice
/// @return C 字符串（不需要释放，由设备对象管理）
const char* metal_device_get_name(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    return [[dev name] UTF8String];
}

/// 创建命令队列
/// @param device MTLDevice
/// @return MTLCommandQueue (需要 release)
void* metal_device_new_command_queue(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    return (__bridge_retained void*)queue;
}

// ============================================================================
// Buffer Management
// ============================================================================

/// 创建 Buffer
/// @param device MTLDevice
/// @param length 缓冲区大小（字节）
/// @param options MTLResourceOptions
/// @return MTLBuffer (需要 release)
void* metal_device_new_buffer(void* device, size_t length, unsigned int options) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLBuffer> buffer = [dev newBufferWithLength:length
                                            options:(MTLResourceOptions)options];
    return (__bridge_retained void*)buffer;
}

/// 获取 Buffer 内容指针
/// @param buffer MTLBuffer
/// @return 内存指针（由 buffer 管理生命周期）
void* metal_buffer_contents(void* buffer) {
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    return [buf contents];
}

/// 获取 Buffer 大小
/// @param buffer MTLBuffer
/// @return 字节大小
size_t metal_buffer_get_length(void* buffer) {
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    return [buf length];
}

void metal_buffer_set_label(void* buffer, const char* label) {
    if (!buffer || !label) return;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    buf.label = [NSString stringWithUTF8String:label];
}

// ============================================================================
// Texture Management
// ============================================================================

/// 创建纹理描述符
/// @return MTLTextureDescriptor (需要 release)
unsigned int metal_texture_get_width(void* texture) {
    if (!texture) return 0;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    return (unsigned int)tex.width;
}

unsigned int metal_texture_get_height(void* texture) {
    if (!texture) return 0;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    return (unsigned int)tex.height;
}

void* metal_texture_descriptor_new(void) {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    return (__bridge_retained void*)desc;
}

/// 设置纹理描述符属性
void metal_texture_descriptor_set_pixel_format(void* desc, unsigned long format) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.pixelFormat = (MTLPixelFormat)format;
}

void metal_texture_descriptor_set_width(void* desc, size_t width) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.width = width;
}

void metal_texture_descriptor_set_height(void* desc, size_t height) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.height = height;
}

void metal_texture_descriptor_set_depth(void* desc, size_t depth) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.depth = depth;
}

void metal_texture_descriptor_set_mipmap_level_count(void* desc, size_t count) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.mipmapLevelCount = count;
}

void metal_texture_descriptor_set_sample_count(void* desc, size_t count) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.sampleCount = count;
}

void metal_texture_descriptor_set_texture_type(void* desc, unsigned long type) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.textureType = (MTLTextureType)type;
}

void metal_texture_descriptor_set_usage(void* desc, unsigned long usage) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.usage = (MTLTextureUsage)usage;
}

void metal_texture_descriptor_set_storage_mode(void* desc, unsigned long mode) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.storageMode = (MTLStorageMode)mode;
}

/// 创建纹理
/// @param device MTLDevice
/// @param desc MTLTextureDescriptor
/// @return MTLTexture (需要 release)
void* metal_device_new_texture(void* device, void* desc) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:d];
    return (__bridge_retained void*)texture;
}

void metal_texture_set_label(void* texture, const char* label) {
    if (!texture || !label) return;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    tex.label = [NSString stringWithUTF8String:label];
}

// ============================================================================
// Sampler Management
// ============================================================================

/// 创建采样器描述符
/// @return MTLSamplerDescriptor (需要 release)
void* metal_sampler_descriptor_new(void) {
    MTLSamplerDescriptor* desc = [MTLSamplerDescriptor new];
    return (__bridge_retained void*)desc;
}

void metal_sampler_descriptor_set_min_filter(void* desc, unsigned long filter) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.minFilter = (MTLSamplerMinMagFilter)filter;
}

void metal_sampler_descriptor_set_mag_filter(void* desc, unsigned long filter) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.magFilter = (MTLSamplerMinMagFilter)filter;
}

void metal_sampler_descriptor_set_mip_filter(void* desc, unsigned long filter) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.mipFilter = (MTLSamplerMipFilter)filter;
}

void metal_sampler_descriptor_set_address_mode_u(void* desc, unsigned long mode) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.sAddressMode = (MTLSamplerAddressMode)mode;
}

void metal_sampler_descriptor_set_address_mode_v(void* desc, unsigned long mode) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.tAddressMode = (MTLSamplerAddressMode)mode;
}

void metal_sampler_descriptor_set_address_mode_w(void* desc, unsigned long mode) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.rAddressMode = (MTLSamplerAddressMode)mode;
}

void metal_sampler_descriptor_set_compare_function(void* desc, unsigned long func) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.compareFunction = (MTLCompareFunction)func;
}

void metal_sampler_descriptor_set_lod_min_clamp(void* desc, float value) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.lodMinClamp = value;
}

void metal_sampler_descriptor_set_lod_max_clamp(void* desc, float value) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.lodMaxClamp = value;
}

void metal_sampler_descriptor_set_max_anisotropy(void* desc, unsigned long value) {
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.maxAnisotropy = value;
}

void metal_sampler_descriptor_set_label(void* desc, const char* label) {
    if (!desc || !label) return;
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    d.label = [NSString stringWithUTF8String:label];
}

/// 创建采样器
/// @param device MTLDevice
/// @param desc MTLSamplerDescriptor
/// @return MTLSamplerState (需要 release)
void* metal_device_new_sampler(void* device, void* desc) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:d];
    return (__bridge_retained void*)sampler;
}

// ============================================================================
// 便捷的纹理/采样器创建函数
// ============================================================================

/// 便捷函数：创建 2D 纹理
/// @param device MTLDevice
/// @param width 宽度
/// @param height 高度
/// @param pixelFormat 像素格式
/// @param usage 用途
/// @param storageMode 存储模式
/// @return MTLTexture (需要 release)
void* metal_device_create_texture(void* device, unsigned int width, unsigned int height, unsigned long pixelFormat, unsigned long usage, unsigned long storageMode) {
    @autoreleasepool {
        if (width == 0 || height == 0) {
            return NULL;
        }
        id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pixelFormat
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        desc.usage = (MTLTextureUsage)usage;
        desc.storageMode = (MTLStorageMode)storageMode;

        id<MTLTexture> texture = [dev newTextureWithDescriptor:desc];
        return (__bridge_retained void*)texture;
    }
}

/// 便捷函数：创建 2D 纹理（可选 mipmaps）
void* metal_device_create_texture_mipmapped(void* device, unsigned int width, unsigned int height, unsigned long pixelFormat, unsigned long usage, unsigned long storageMode, int mipmapped) {
    @autoreleasepool {
        if (width == 0 || height == 0) {
            return NULL;
        }
        id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pixelFormat
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:(mipmapped ? YES : NO)];
        desc.usage = (MTLTextureUsage)usage;
        desc.storageMode = (MTLStorageMode)storageMode;

        id<MTLTexture> texture = [dev newTextureWithDescriptor:desc];
        return (__bridge_retained void*)texture;
    }
}

/// 便捷函数：创建采样器
/// @param device MTLDevice
/// @param minFilter 最小过滤
/// @param magFilter 最大过滤
/// @param sAddressMode S 地址模式
/// @param tAddressMode T 地址模式
/// @return MTLSamplerState (需要 release)
void* metal_device_create_sampler(void* device, unsigned long minFilter, unsigned long magFilter, unsigned long sAddressMode, unsigned long tAddressMode) {
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
        MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
        desc.minFilter = (MTLSamplerMinMagFilter)minFilter;
        desc.magFilter = (MTLSamplerMinMagFilter)magFilter;
        desc.sAddressMode = (MTLSamplerAddressMode)sAddressMode;
        desc.tAddressMode = (MTLSamplerAddressMode)tAddressMode;

        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:desc];
        return (__bridge_retained void*)sampler;
    }
}

/// 便捷函数：创建采样器（含 mip filter）
void* metal_device_create_sampler_with_mip(void* device, unsigned long minFilter, unsigned long magFilter, unsigned long mipFilter, unsigned long sAddressMode, unsigned long tAddressMode) {
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
        MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
        desc.minFilter = (MTLSamplerMinMagFilter)minFilter;
        desc.magFilter = (MTLSamplerMinMagFilter)magFilter;
        desc.mipFilter = (MTLSamplerMipFilter)mipFilter;
        desc.sAddressMode = (MTLSamplerAddressMode)sAddressMode;
        desc.tAddressMode = (MTLSamplerAddressMode)tAddressMode;

        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:desc];
        return (__bridge_retained void*)sampler;
    }
}

/// 替换纹理区域内容
/// @param texture MTLTexture
/// @param x X 坐标
/// @param y Y 坐标
/// @param width 宽度
/// @param height 高度
/// @param bytes 像素数据
/// @param bytesPerRow 每行字节数
void metal_texture_replace_region(void* texture, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const void* bytes, unsigned int bytesPerRow) {
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    MTLRegion region = MTLRegionMake2D(x, y, width, height);
    [tex replaceRegion:region
           mipmapLevel:0
             withBytes:bytes
           bytesPerRow:bytesPerRow];
}

/// 替换纹理区域内容（指定 mip level）
void metal_texture_replace_region_level(void* texture, unsigned int x, unsigned int y, unsigned int width, unsigned int height, unsigned long mipLevel, const void* bytes, unsigned int bytesPerRow) {
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    MTLRegion region = MTLRegionMake2D(x, y, width, height);
    [tex replaceRegion:region
           mipmapLevel:mipLevel
             withBytes:bytes
           bytesPerRow:bytesPerRow];
}

/// 从纹理读取 BGRA8 像素（mip0）。
/// 返回 1 表示成功，0 表示失败。
int metal_texture_read_bgra8(
    void* texture,
    uint8_t* out_bytes,
    unsigned int bytes_per_row,
    unsigned int width,
    unsigned int height
) {
    @autoreleasepool {
        if (!texture || !out_bytes || bytes_per_row == 0) return 0;
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
        if (!tex) return 0;

        const unsigned int tw = (unsigned int)tex.width;
        const unsigned int th = (unsigned int)tex.height;
        if (tw == 0 || th == 0) return 0;
        if (width == 0 || height == 0) {
            width = tw;
            height = th;
        }
        if (width > tw || height > th) return 0;

        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        @try {
            [tex getBytes:out_bytes bytesPerRow:bytes_per_row fromRegion:region mipmapLevel:0];
            return 1;
        } @catch (NSException *exception) {
            (void)exception;
            return 0;
        }
    }
}

// ============================================================================
// Command Queue & Buffer
// ============================================================================

/// 创建命令缓冲区
/// @param queue MTLCommandQueue
/// @return MTLCommandBuffer (需要 release)
void* metal_command_queue_command_buffer(void* queue) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<MTLCommandBuffer> cmd_buffer = [q commandBuffer];
    return (__bridge_retained void*)cmd_buffer;
}

/// 提交命令缓冲区
/// @param buffer MTLCommandBuffer
void metal_command_buffer_commit(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    [buf commit];
}

/// 等待命令缓冲区完成
/// @param buffer MTLCommandBuffer
void metal_command_buffer_wait_until_completed(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    [buf waitUntilCompleted];
}

// ============================================================================
// Shader Library
// ============================================================================

/// 从源码创建着色器库
/// @param device MTLDevice
/// @param source MSL 源码
/// @param source_length 源码长度
/// @param error_out 错误信息输出（如果非空）
/// @return MTLLibrary (需要 release)
void* metal_device_new_library_with_source(void* device, const char* source, size_t source_length, char** error_out) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    NSString* source_str = [[NSString alloc] initWithBytes:source
                                                    length:source_length
                                                  encoding:NSUTF8StringEncoding];

    NSError* error = nil;
    id<MTLLibrary> library = [dev newLibraryWithSource:source_str
                                               options:nil
                                                 error:&error];

    if (error && error_out) {
        NSString* error_str = [error localizedDescription];
        *error_out = strdup([error_str UTF8String]);
    }

    return (__bridge_retained void*)library;
}

/// 从库中获取函数
/// @param library MTLLibrary
/// @param name 函数名
/// @return MTLFunction (需要 release)
void* metal_library_new_function(void* library, const char* name) {
    id<MTLLibrary> lib = (__bridge id<MTLLibrary>)library;
    NSString* name_str = [NSString stringWithUTF8String:name];
    id<MTLFunction> function = [lib newFunctionWithName:name_str];
    return (__bridge_retained void*)function;
}

// ============================================================================
// Reference Counting
// ============================================================================

/// 释放对象
/// @param obj 任意 Objective-C 对象
void metal_release(void* obj) {
    if (obj) {
        CFRelease(obj);
    }
}

/// 保留对象
/// @param obj 任意 Objective-C 对象
/// @return 同一个对象（引用计数 +1）
void* metal_retain(void* obj) {
    if (obj) {
        CFRetain(obj);
    }
    return obj;
}

// ============================================================================
// Autorelease Pool Management (ARC-compatible)
// ============================================================================

/// 在 ARC 模式下，我们不能直接管理 NSAutoreleasePool
/// 而是提供基于回调的 API

/// 在 autorelease pool 中执行函数
/// @param callback 回调函数
/// @param context 传递给回调的上下文
typedef void (*AutoreleaseCallback)(void* context);

void objc_autoreleasepool_run(AutoreleaseCallback callback, void* context) {
    @autoreleasepool {
        callback(context);
    }
}

// Push/Pop API 在 ARC 下需要使用不同的实现
// 使用私有 runtime 函数（不推荐但可行）
extern void* objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void* pool);

void* objc_autoreleasepool_push(void) {
    return objc_autoreleasePoolPush();
}

void objc_autoreleasepool_pop(void* pool) {
    objc_autoreleasePoolPop(pool);
}

// ============================================================================
// CAMetalLayer Management
// ============================================================================

/// 设置 layer 的设备
void metal_layer_set_device(void* layer, void* device) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    l.device = d;
}

/// 设置像素格式
void metal_layer_set_pixel_format(void* layer, unsigned long format) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.pixelFormat = (MTLPixelFormat)format;
}

/// 设置 framebuffer only
void metal_layer_set_framebuffer_only(void* layer, _Bool value) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.framebufferOnly = value;
}

/// 设置最大 drawable 数量
void metal_layer_set_maximum_drawable_count(void* layer, size_t count) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.maximumDrawableCount = count;
}

/// 设置 display sync
void metal_layer_set_display_sync_enabled(void* layer, _Bool enabled) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (@available(macOS 10.13, *)) {
        l.displaySyncEnabled = enabled;
    }
}

/// 设置 drawable timeout
void metal_layer_set_allows_next_drawable_timeout(void* layer, _Bool allows) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (@available(macOS 10.13, *)) {
        l.allowsNextDrawableTimeout = allows;
    }
}

/// 设置不透明度
void metal_layer_set_opaque(void* layer, _Bool opaque) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.opaque = opaque;
}

/// 设置 HDR 内容
void metal_layer_set_wants_edr(void* layer, _Bool wants) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (@available(macOS 10.15, *)) {
        l.wantsExtendedDynamicRangeContent = wants;
    }
}

/// 设置 drawable 尺寸
void metal_layer_set_drawable_size(void* layer, unsigned int width, unsigned int height) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.drawableSize = CGSizeMake(width, height);
}

/// 获取 nextDrawable —— [owned] 返回 +1，调用方接管，勿再 retain
void* metal_layer_next_drawable(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    id<CAMetalDrawable> drawable = [l nextDrawable];
    return (__bridge_retained void*)drawable;
}

// metal_drawable_get_texture 已在 macos_window_bridge.m 中定义

/// Drawable present
void metal_drawable_present(void* drawable) {
    id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
    [d present];
}

/// 检查 presents with transaction
_Bool metal_layer_presents_with_transaction(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    return l.presentsWithTransaction;
}

/// 获取 layer bounds
typedef struct {
    double width;
    double height;
} MetalLayerBounds;

MetalLayerBounds metal_layer_get_bounds(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    CGRect bounds = l.bounds;
    return (MetalLayerBounds){
        .width = bounds.size.width,
        .height = bounds.size.height,
    };
}

/// 获取 contents scale
double metal_layer_get_contents_scale(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    return l.contentsScale;
}

// ============================================================================
// Command Buffer Presentation
// ============================================================================

/// Command buffer present drawable
void metal_command_buffer_present_drawable(void* buffer, void* drawable) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
    [buf presentDrawable:d];
}

/// Wait until scheduled
void metal_command_buffer_wait_until_scheduled(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    [buf waitUntilScheduled];
}

/// 从 queue 创建 command buffer —— [owned] 返回 +1，调用方接管，勿再 retain
void* metal_queue_command_buffer(void* queue) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<MTLCommandBuffer> cmd_buffer = [q commandBuffer];
    return (__bridge_retained void*)cmd_buffer;
}

// ============================================================================
// Render Pass Descriptor
// ============================================================================

/// 创建渲染通道描述符
/// @return MTLRenderPassDescriptor (autorelease，需在 autorelease pool 中使用)
void* metal_render_pass_descriptor_new(void) {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    return (__bridge_retained void*)desc;  // 显式 retain
}

/// 获取颜色附件描述符
/// @param desc MTLRenderPassDescriptor
/// @param index 附件索引
/// @return MTLRenderPassColorAttachmentDescriptor (autorelease)
void* metal_render_pass_get_color_attachment(void* desc, unsigned long index) {
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    return (__bridge void*)[d.colorAttachments objectAtIndexedSubscript:index];
}

/// 获取深度附件描述符
/// @param desc MTLRenderPassDescriptor
/// @return MTLRenderPassDepthAttachmentDescriptor (autorelease)
void* metal_render_pass_get_depth_attachment(void* desc) {
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    return (__bridge void*)d.depthAttachment;
}

/// 获取模板附件描述符
/// @param desc MTLRenderPassDescriptor
/// @return MTLRenderPassStencilAttachmentDescriptor (autorelease)
void* metal_render_pass_get_stencil_attachment(void* desc) {
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    return (__bridge void*)d.stencilAttachment;
}

// ============================================================================
// Render Pass Color Attachment Configuration
// ============================================================================

/// 设置颜色附件的纹理
void metal_color_attachment_set_texture(void* attachment, void* texture) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.texture = tex;
}

/// 设置加载操作
void metal_color_attachment_set_load_action(void* attachment, unsigned long action) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    at.loadAction = (MTLLoadAction)action;
}

/// 设置存储操作
void metal_color_attachment_set_store_action(void* attachment, unsigned long action) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    at.storeAction = (MTLStoreAction)action;
}

/// 设置清除颜色
void metal_color_attachment_set_clear_color(void* attachment, double r, double g, double b, double a) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    at.clearColor = MTLClearColorMake(r, g, b, a);
}

/// 设置 resolve 纹理（用于 MSAA）
void metal_color_attachment_set_resolve_texture(void* attachment, void* texture) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.resolveTexture = tex;
}

// ============================================================================
// Render Pass Depth/Stencil Attachment Configuration
// ============================================================================

/// 设置深度附件的纹理
void metal_depth_attachment_set_texture(void* attachment, void* texture) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.texture = tex;
}

/// 设置深度附件的加载操作
void metal_depth_attachment_set_load_action(void* attachment, unsigned long action) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    at.loadAction = (MTLLoadAction)action;
}

/// 设置深度附件的存储操作
void metal_depth_attachment_set_store_action(void* attachment, unsigned long action) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    at.storeAction = (MTLStoreAction)action;
}

/// 设置清除深度值
void metal_depth_attachment_set_clear_depth(void* attachment, double depth) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    at.clearDepth = depth;
}

/// 设置模板附件的纹理
void metal_stencil_attachment_set_texture(void* attachment, void* texture) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.texture = tex;
}

/// 设置模板附件的加载操作
void metal_stencil_attachment_set_load_action(void* attachment, unsigned long action) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    at.loadAction = (MTLLoadAction)action;
}

/// 设置模板附件的存储操作
void metal_stencil_attachment_set_store_action(void* attachment, unsigned long action) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    at.storeAction = (MTLStoreAction)action;
}

/// 设置清除模板值
void metal_stencil_attachment_set_clear_stencil(void* attachment, unsigned int stencil) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    at.clearStencil = stencil;
}

// ============================================================================
// Render Command Encoder
// ============================================================================

/// 创建渲染命令编码器
/// @param buffer MTLCommandBuffer
/// @param desc MTLRenderPassDescriptor
/// @return MTLRenderCommandEncoder —— [owned] 返回 +1，调用方接管，勿再 retain
void* metal_command_buffer_create_render_encoder(void* buffer, void* desc) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    id<MTLRenderCommandEncoder> encoder = [buf renderCommandEncoderWithDescriptor:d];
    return (__bridge_retained void*)encoder;
}

/// 结束渲染编码器
void metal_render_encoder_end_encoding(void* encoder) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc endEncoding];
}

/// 设置渲染管线状态
void metal_render_encoder_set_render_pipeline_state(void* encoder, void* pipeline) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLRenderPipelineState> ps = (__bridge id<MTLRenderPipelineState>)pipeline;
    [enc setRenderPipelineState:ps];
}

/// 设置视口
void metal_render_encoder_set_viewport(void* encoder, double x, double y, double width, double height, double znear, double zfar) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    MTLViewport viewport = {x, y, width, height, znear, zfar};
    [enc setViewport:viewport];
}

/// 设置裁剪矩形
void metal_render_encoder_set_scissor_rect(void* encoder, unsigned long x, unsigned long y, unsigned long width, unsigned long height) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    MTLScissorRect scissor = {x, y, width, height};
    [enc setScissorRect:scissor];
}

/// 设置剔除模式
void metal_render_encoder_set_cull_mode(void* encoder, unsigned long mode) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setCullMode:(MTLCullMode)mode];
}

/// 设置正面朝向
void metal_render_encoder_set_front_facing_winding(void* encoder, unsigned long winding) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setFrontFacingWinding:(MTLWinding)winding];
}

/// 设置三角形填充模式
void metal_render_encoder_set_triangle_fill_mode(void* encoder, unsigned long fillMode) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setTriangleFillMode:(MTLTriangleFillMode)fillMode];
}

/// 设置深度模板状态
void metal_render_encoder_set_depth_stencil_state(void* encoder, void* state) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLDepthStencilState> ds = (__bridge id<MTLDepthStencilState>)state;
    [enc setDepthStencilState:ds];
}

/// 设置深度偏移
void metal_render_encoder_set_depth_bias(void* encoder, float constant, float slope, float clamp) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setDepthBias:constant slopeScale:slope clamp:clamp];
}

// ============================================================================
// Render Encoder - Resource Binding
// ============================================================================

/// 设置顶点缓冲区
void metal_render_encoder_set_vertex_buffer(void* encoder, void* buffer, unsigned long offset, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [enc setVertexBuffer:buf offset:offset atIndex:index];
}

/// 设置片段缓冲区
void metal_render_encoder_set_fragment_buffer(void* encoder, void* buffer, unsigned long offset, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [enc setFragmentBuffer:buf offset:offset atIndex:index];
}

/// 设置顶点纹理
void metal_render_encoder_set_vertex_texture(void* encoder, void* texture, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [enc setVertexTexture:tex atIndex:index];
}

/// 设置片段纹理
void metal_render_encoder_set_fragment_texture(void* encoder, void* texture, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [enc setFragmentTexture:tex atIndex:index];
}

/// 设置顶点采样器
void metal_render_encoder_set_vertex_sampler(void* encoder, void* sampler, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLSamplerState> samp = (__bridge id<MTLSamplerState>)sampler;
    [enc setVertexSamplerState:samp atIndex:index];
}

/// 设置片段采样器
void metal_render_encoder_set_fragment_sampler(void* encoder, void* sampler, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLSamplerState> samp = (__bridge id<MTLSamplerState>)sampler;
    [enc setFragmentSamplerState:samp atIndex:index];
}

/// 设置顶点字节数据（小数据量）
void metal_render_encoder_set_vertex_bytes(void* encoder, const void* bytes, unsigned long length, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setVertexBytes:bytes length:length atIndex:index];
}

/// 设置片段字节数据（小数据量）
void metal_render_encoder_set_fragment_bytes(void* encoder, const void* bytes, unsigned long length, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setFragmentBytes:bytes length:length atIndex:index];
}

// ============================================================================
// Render Encoder - Draw Calls
// ============================================================================

/// 绘制图元
void metal_render_encoder_draw_primitives(void* encoder, unsigned long primitiveType, unsigned long vertexStart, unsigned long vertexCount) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc drawPrimitives:(MTLPrimitiveType)primitiveType
            vertexStart:vertexStart
            vertexCount:vertexCount];
}

/// 绘制图元（带实例）
void metal_render_encoder_draw_primitives_instanced(void* encoder, unsigned long primitiveType, unsigned long vertexStart, unsigned long vertexCount, unsigned long instanceCount) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc drawPrimitives:(MTLPrimitiveType)primitiveType
            vertexStart:vertexStart
            vertexCount:vertexCount
          instanceCount:instanceCount];
}

/// 绘制图元（带实例和基础实例）
void metal_render_encoder_draw_primitives_instanced_base_instance(void* encoder, unsigned long primitiveType, unsigned long vertexStart, unsigned long vertexCount, unsigned long instanceCount, unsigned long baseInstance) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc drawPrimitives:(MTLPrimitiveType)primitiveType
            vertexStart:vertexStart
            vertexCount:vertexCount
          instanceCount:instanceCount
           baseInstance:baseInstance];
}

/// 绘制索引图元
void metal_render_encoder_draw_indexed_primitives(void* encoder, unsigned long primitiveType, unsigned long indexCount, unsigned long indexType, void* indexBuffer, unsigned long indexBufferOffset) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)indexBuffer;
    [enc drawIndexedPrimitives:(MTLPrimitiveType)primitiveType
                    indexCount:indexCount
                     indexType:(MTLIndexType)indexType
                   indexBuffer:buf
             indexBufferOffset:indexBufferOffset];
}

/// 绘制索引图元（带实例）
void metal_render_encoder_draw_indexed_primitives_instanced(void* encoder, unsigned long primitiveType, unsigned long indexCount, unsigned long indexType, void* indexBuffer, unsigned long indexBufferOffset, unsigned long instanceCount) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)indexBuffer;
    [enc drawIndexedPrimitives:(MTLPrimitiveType)primitiveType
                    indexCount:indexCount
                     indexType:(MTLIndexType)indexType
                   indexBuffer:buf
             indexBufferOffset:indexBufferOffset
                 instanceCount:instanceCount];
}

/// 绘制索引图元（完整参数）
void metal_render_encoder_draw_indexed_primitives_full(void* encoder, unsigned long primitiveType, unsigned long indexCount, unsigned long indexType, void* indexBuffer, unsigned long indexBufferOffset, unsigned long instanceCount, unsigned long baseVertex, unsigned long baseInstance) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)indexBuffer;
    [enc drawIndexedPrimitives:(MTLPrimitiveType)primitiveType
                    indexCount:indexCount
                     indexType:(MTLIndexType)indexType
                   indexBuffer:buf
             indexBufferOffset:indexBufferOffset
                 instanceCount:instanceCount
                    baseVertex:baseVertex
                  baseInstance:baseInstance];
}

// ============================================================================
// Compute Command Encoder
// ============================================================================

/// 创建计算命令编码器
/// @param buffer MTLCommandBuffer
/// @return MTLComputeCommandEncoder (需要 release)
void* metal_command_buffer_create_compute_encoder(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    id<MTLComputeCommandEncoder> encoder = [buf computeCommandEncoder];
    return (__bridge_retained void*)encoder;
}

/// 结束计算编码器
void metal_compute_encoder_end_encoding(void* encoder) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    [enc endEncoding];
}

/// 设置计算管线状态
void metal_compute_encoder_set_compute_pipeline_state(void* encoder, void* pipeline) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLComputePipelineState> ps = (__bridge id<MTLComputePipelineState>)pipeline;
    [enc setComputePipelineState:ps];
}

/// 设置缓冲区
void metal_compute_encoder_set_buffer(void* encoder, void* buffer, unsigned long offset, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [enc setBuffer:buf offset:offset atIndex:index];
}

/// 设置纹理
void metal_compute_encoder_set_texture(void* encoder, void* texture, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [enc setTexture:tex atIndex:index];
}

/// 设置采样器
void metal_compute_encoder_set_sampler(void* encoder, void* sampler, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLSamplerState> samp = (__bridge id<MTLSamplerState>)sampler;
    [enc setSamplerState:samp atIndex:index];
}

/// 设置字节数据
void metal_compute_encoder_set_bytes(void* encoder, const void* bytes, unsigned long length, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    [enc setBytes:bytes length:length atIndex:index];
}

/// 设置 threadgroup 内存长度
void metal_compute_encoder_set_threadgroup_memory_length(void* encoder, unsigned long length, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    [enc setThreadgroupMemoryLength:length atIndex:index];
}

/// 调度计算
void metal_compute_encoder_dispatch_threadgroups(void* encoder, unsigned long threadgroupsX, unsigned long threadgroupsY, unsigned long threadgroupsZ, unsigned long threadsPerGroupX, unsigned long threadsPerGroupY, unsigned long threadsPerGroupZ) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    MTLSize threadgroups = MTLSizeMake(threadgroupsX, threadgroupsY, threadgroupsZ);
    MTLSize threadsPerGroup = MTLSizeMake(threadsPerGroupX, threadsPerGroupY, threadsPerGroupZ);
    [enc dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
}

// ============================================================================
// Blit Command Encoder
// ============================================================================

/// 创建 Blit 命令编码器
/// @param buffer MTLCommandBuffer
/// @return MTLBlitCommandEncoder (需要 release)
void* metal_command_buffer_create_blit_encoder(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    id<MTLBlitCommandEncoder> encoder = [buf blitCommandEncoder];
    return (__bridge_retained void*)encoder;
}

/// 结束 Blit 编码器
void metal_blit_encoder_end_encoding(void* encoder) {
    id<MTLBlitCommandEncoder> enc = (__bridge id<MTLBlitCommandEncoder>)encoder;
    [enc endEncoding];
}

/// 复制缓冲区
void metal_blit_encoder_copy_buffer(void* encoder, void* sourceBuffer, unsigned long sourceOffset, void* destinationBuffer, unsigned long destinationOffset, unsigned long size) {
    id<MTLBlitCommandEncoder> enc = (__bridge id<MTLBlitCommandEncoder>)encoder;
    id<MTLBuffer> src = (__bridge id<MTLBuffer>)sourceBuffer;
    id<MTLBuffer> dst = (__bridge id<MTLBuffer>)destinationBuffer;
    [enc copyFromBuffer:src
           sourceOffset:sourceOffset
               toBuffer:dst
      destinationOffset:destinationOffset
                   size:size];
}

/// 复制纹理
void metal_blit_encoder_copy_texture(void* encoder, void* sourceTexture, unsigned long sourceSlice, unsigned long sourceLevel, void* destinationTexture, unsigned long destinationSlice, unsigned long destinationLevel, unsigned long width, unsigned long height, unsigned long depth) {
    id<MTLBlitCommandEncoder> enc = (__bridge id<MTLBlitCommandEncoder>)encoder;
    id<MTLTexture> src = (__bridge id<MTLTexture>)sourceTexture;
    id<MTLTexture> dst = (__bridge id<MTLTexture>)destinationTexture;

    MTLOrigin sourceOrigin = {0, 0, 0};
    MTLSize sourceSize = MTLSizeMake(width, height, depth);
    MTLOrigin destinationOrigin = {0, 0, 0};

    [enc copyFromTexture:src
             sourceSlice:sourceSlice
             sourceLevel:sourceLevel
            sourceOrigin:sourceOrigin
              sourceSize:sourceSize
               toTexture:dst
        destinationSlice:destinationSlice
        destinationLevel:destinationLevel
       destinationOrigin:destinationOrigin];
}

/// 复制纹理区域（支持自定义 source/destination origin）
void metal_blit_encoder_copy_texture_region(
    void* encoder,
    void* sourceTexture,
    unsigned long src_x,
    unsigned long src_y,
    unsigned long width,
    unsigned long height,
    void* destinationTexture,
    unsigned long dst_x,
    unsigned long dst_y
) {
    id<MTLBlitCommandEncoder> enc = (__bridge id<MTLBlitCommandEncoder>)encoder;
    id<MTLTexture> src = (__bridge id<MTLTexture>)sourceTexture;
    id<MTLTexture> dst = (__bridge id<MTLTexture>)destinationTexture;

    MTLOrigin sourceOrigin = {src_x, src_y, 0};
    MTLSize sourceSize = MTLSizeMake(width, height, 1);
    MTLOrigin destinationOrigin = {dst_x, dst_y, 0};

    [enc copyFromTexture:src
             sourceSlice:0
             sourceLevel:0
            sourceOrigin:sourceOrigin
              sourceSize:sourceSize
               toTexture:dst
        destinationSlice:0
        destinationLevel:0
       destinationOrigin:destinationOrigin];
}

// ============================================================================
// Shader Library Management
// ============================================================================

/// 从源码创建 Metal Library
/// @param device MTLDevice
/// @param source Metal Shading Language 源码
/// @param error_out 错误信息输出（如果非 NULL 且发生错误）
/// @return MTLLibrary (需要 release)，失败时返回 NULL
void* metal_device_new_library_from_source(void* device, const char* source, char** error_out) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    NSString* sourceStr = [NSString stringWithUTF8String:source];
    NSError* error = nil;

    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> library = [dev newLibraryWithSource:sourceStr
                                               options:options
                                                 error:&error];

    if (error && error_out) {
        *error_out = strdup([[error localizedDescription] UTF8String]);
    }

    return (__bridge_retained void*)library;
}

// metal_library_new_function 已在上方定义

// ============================================================================
// Render Pipeline Management
// ============================================================================

/// 创建渲染管线描述符
/// @return MTLRenderPipelineDescriptor (需要 release)
void* metal_render_pipeline_descriptor_new(void) {
    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    return (__bridge_retained void*)desc;
}

/// 设置顶点函数
void metal_render_pipeline_descriptor_set_vertex_function(void* desc, void* function) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.vertexFunction = (__bridge id<MTLFunction>)function;
}

/// 设置片段函数
void metal_render_pipeline_descriptor_set_fragment_function(void* desc, void* function) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.fragmentFunction = (__bridge id<MTLFunction>)function;
}

/// 设置颜色附件像素格式
void metal_render_pipeline_descriptor_set_color_attachment_format(void* desc, unsigned long index, unsigned long format) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].pixelFormat = (MTLPixelFormat)format;
}

/// 设置深度附件像素格式
void metal_render_pipeline_descriptor_set_depth_attachment_format(void* desc, unsigned long format) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.depthAttachmentPixelFormat = (MTLPixelFormat)format;
}

/// 设置模板附件像素格式
void metal_render_pipeline_descriptor_set_stencil_attachment_format(void* desc, unsigned long format) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)format;
}

/// 设置采样数量
void metal_render_pipeline_descriptor_set_sample_count(void* desc, unsigned long count) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.rasterSampleCount = count;
}

/// 设置顶点描述符
void metal_render_pipeline_descriptor_set_vertex_descriptor(void* desc, void* vertex_desc) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.vertexDescriptor = (__bridge MTLVertexDescriptor*)vertex_desc;
}

/// 创建渲染管线状态
/// @param device MTLDevice
/// @param desc MTLRenderPipelineDescriptor
/// @param error_out 错误信息输出
/// @return MTLRenderPipelineState (需要 release)
void* metal_device_new_render_pipeline_state(void* device, void* desc, char** error_out) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    NSError* error = nil;

    id<MTLRenderPipelineState> state = [dev newRenderPipelineStateWithDescriptor:d error:&error];

    if (error && error_out) {
        *error_out = strdup([[error localizedDescription] UTF8String]);
    }

    return (__bridge_retained void*)state;
}

// ============================================================================
// Vertex Descriptor Management
// ============================================================================

/// 创建顶点描述符
/// @return MTLVertexDescriptor (需要 release)
void* metal_vertex_descriptor_new(void) {
    MTLVertexDescriptor* desc = [[MTLVertexDescriptor alloc] init];
    return (__bridge_retained void*)desc;
}

/// 设置顶点属性格式
void metal_vertex_descriptor_set_attribute_format(void* desc, unsigned long index, unsigned long format) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.attributes[index].format = (MTLVertexFormat)format;
}

/// 设置顶点属性偏移
void metal_vertex_descriptor_set_attribute_offset(void* desc, unsigned long index, unsigned long offset) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.attributes[index].offset = offset;
}

/// 设置顶点属性缓冲区索引
void metal_vertex_descriptor_set_attribute_buffer_index(void* desc, unsigned long index, unsigned long buffer_index) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.attributes[index].bufferIndex = buffer_index;
}

/// 设置顶点布局步长
void metal_vertex_descriptor_set_layout_stride(void* desc, unsigned long index, unsigned long stride) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.layouts[index].stride = stride;
}

/// 设置顶点布局步进函数
void metal_vertex_descriptor_set_layout_step_function(void* desc, unsigned long index, unsigned long step_function) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.layouts[index].stepFunction = (MTLVertexStepFunction)step_function;
}

/// 设置顶点布局步进速率
void metal_vertex_descriptor_set_layout_step_rate(void* desc, unsigned long index, unsigned long step_rate) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.layouts[index].stepRate = step_rate;
}

// ============================================================================
// Depth Stencil State Management
// ============================================================================

/// 创建深度模板描述符
/// @return MTLDepthStencilDescriptor (需要 release)
void* metal_depth_stencil_descriptor_new(void) {
    MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
    return (__bridge_retained void*)desc;
}

/// 设置深度比较函数
void metal_depth_stencil_descriptor_set_depth_compare_function(void* desc, unsigned long compare_function) {
    MTLDepthStencilDescriptor* d = (__bridge MTLDepthStencilDescriptor*)desc;
    d.depthCompareFunction = (MTLCompareFunction)compare_function;
}

/// 设置深度写入启用
void metal_depth_stencil_descriptor_set_depth_write_enabled(void* desc, int enabled) {
    MTLDepthStencilDescriptor* d = (__bridge MTLDepthStencilDescriptor*)desc;
    d.depthWriteEnabled = enabled ? YES : NO;
}

/// 创建深度模板状态
/// @param device MTLDevice
/// @param desc MTLDepthStencilDescriptor
/// @return MTLDepthStencilState (需要 release)
void* metal_device_new_depth_stencil_state(void* device, void* desc) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLDepthStencilDescriptor* d = (__bridge MTLDepthStencilDescriptor*)desc;
    id<MTLDepthStencilState> state = [dev newDepthStencilStateWithDescriptor:d];
    return (__bridge_retained void*)state;
}

// ============================================================================
// Color Attachment Blending
// ============================================================================

/// 设置颜色附件混合启用
void metal_render_pipeline_color_attachment_set_blending_enabled(void* desc, unsigned long index, int enabled) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].blendingEnabled = enabled ? YES : NO;
}

/// 设置源 RGB 混合因子
void metal_render_pipeline_color_attachment_set_source_rgb_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].sourceRGBBlendFactor = (MTLBlendFactor)factor;
}

/// 设置目标 RGB 混合因子
void metal_render_pipeline_color_attachment_set_destination_rgb_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].destinationRGBBlendFactor = (MTLBlendFactor)factor;
}

/// 设置 RGB 混合操作
void metal_render_pipeline_color_attachment_set_rgb_blend_operation(void* desc, unsigned long index, unsigned long operation) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].rgbBlendOperation = (MTLBlendOperation)operation;
}

/// 设置源 Alpha 混合因子
void metal_render_pipeline_color_attachment_set_source_alpha_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].sourceAlphaBlendFactor = (MTLBlendFactor)factor;
}

/// 设置目标 Alpha 混合因子
void metal_render_pipeline_color_attachment_set_destination_alpha_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].destinationAlphaBlendFactor = (MTLBlendFactor)factor;
}

/// 设置 Alpha 混合操作
void metal_render_pipeline_color_attachment_set_alpha_blend_operation(void* desc, unsigned long index, unsigned long operation) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].alphaBlendOperation = (MTLBlendOperation)operation;
}

/// 设置颜色写入掩码
void metal_render_pipeline_color_attachment_set_write_mask(void* desc, unsigned long index, unsigned long mask) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].writeMask = (MTLColorWriteMask)mask;
}

// ============================================================================
// GPU Frame Synchronization
// ============================================================================

/// 添加 command buffer 完成回调（用于 triple buffering 信号量同步）
/// callback 签名: void (*)(void* context)
typedef void (*MetalCompletedCallback)(void* context);

void metal_command_buffer_add_completed_handler(void* buffer, void* context, MetalCompletedCallback callback) {
    id<MTLCommandBuffer> cmdBuffer = (__bridge id<MTLCommandBuffer>)buffer;
    // `context` is the FrameSync dispatch semaphore. Giving it a strong,
    // correctly typed local makes the completion block retain it under ARC;
    // FrameSync teardown can no longer leave the asynchronous callback with a
    // dangling raw pointer if a caller misses the normal drain-before-deinit
    // sequence.
    dispatch_semaphore_t semaphore = (__bridge dispatch_semaphore_t)context;
    [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        callback((__bridge void*)semaphore);
    }];
}

// ============================================================================
// Command buffer 错误观测
// ============================================================================

/// command buffer 完成时若 status == Error，回调错误码与描述。
/// 此前全仓库没有任何 MTLCommandBufferStatus 检查：GPU fault / hang /
/// 设备移除全部静默，画面冻结而无诊断。
/// callback 在 Metal 的 completion 线程上执行；desc 只在回调期间有效。
typedef void (*MetalErrorCallback)(void* context, long code, const char* desc);

void metal_command_buffer_notify_error(void* buffer, void* context, MetalErrorCallback callback) {
    id<MTLCommandBuffer> cmdBuffer = (__bridge id<MTLCommandBuffer>)buffer;
    [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        if (cb.status != MTLCommandBufferStatusError) return;
        NSError* err = cb.error;
        const char* desc = err ? err.localizedDescription.UTF8String : NULL;
        callback(context, err ? (long)err.code : -1, desc ? desc : "unknown");
    }];
}

// ============================================================================
// GPU 执行时间（真 GPU 时间，非 CPU 墙钟）
// ============================================================================

/// 读取 command buffer 的 GPU 执行起止时刻（秒，CPU 时间基准）。
/// **必须在 command buffer 完成之后调用**（completed handler 里或
/// waitUntilCompleted 之后），否则返回 0。
///
/// 这是 FrameStats.gpu_encode_us 无法替代的信息：后者是 CPU 侧编码+提交的
/// 墙钟，混入了 wait / drawable acquire；GPUStartTime/GPUEndTime 才是 GPU
/// 实际执行这批命令的时间（审查报告 §4 指出的缺口）。
/// 可用性：macOS 10.15+ / iOS 10.3+。
double metal_command_buffer_gpu_start_time(void* buffer) {
    if (!buffer) return 0.0;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)buffer;
    return (double)cmd.GPUStartTime;
}

double metal_command_buffer_gpu_end_time(void* buffer) {
    if (!buffer) return 0.0;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)buffer;
    return (double)cmd.GPUEndTime;
}

/// 非阻塞查询 command buffer 是否已完成（completed 或 error 均算终态）。
/// 用于把"必须等 GPU 才能读回的数据"改成机会式读取：没完成就跳过本次，
/// 而不是把主线程钉在 waitUntilCompleted 上。
bool metal_command_buffer_is_completed(void* buffer) {
    if (!buffer) return false;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)buffer;
    MTLCommandBufferStatus status = cmd.status;
    return status == MTLCommandBufferStatusCompleted ||
           status == MTLCommandBufferStatusError;
}
