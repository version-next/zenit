#include <pthread.h>
/// Metal C API Bridge
///
/// Provides C API for Zig code to call Metal Objective-C API
///
/// Reference: wgpu-hal metal backend and metal-rs
///
/// ============================================================================
/// WARNING: Ownership ABI contract (violation causes leak or UAF)
/// ============================================================================
///
/// All void* returns must follow one rule, marked in function comment:
///
///   [owned]    Use __bridge_retained to return +1 object. Caller (Zig)
///              takes ownership; must not retain again; release once when
///              done. For 'produce' functions: create/new/copy/nextDrawable.
///
///   [borrowed] Use __bridge to return +0 object. Ownership stays with
///              queried parent; Zig retains only when saving across scopes
///              (self-releases). For simple property getters.
///
/// Mixing them up leaks per frame (e.g. CAMetalDrawable/MTLCommandBuffer/
/// MTLRenderCommandEncoder). The drawable pool has 2-3 entries, so exhaustion makes
/// nextDrawable block forever and freezes the screen.
///
/// Known exceptions (do not 'unify' carelessly, introduces new leaks):
///   `metal_drawable_get_texture` below is
///   [borrowed] (__bridge). Zig side surface.zig must retain it.

#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include <stdatomic.h>
#include <errno.h>
#import <Foundation/Foundation.h>
#import <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#import <IOSurface/IOSurface.h>
#include "pooled_present.inc"

// Opt-in, command-buffer-local engine accounting. Native header encoders use
// this same hook, so /perf cannot miss work encoded outside the Zig wrapper.
static char zenitEngineCountsKey;
static _Atomic(int) zenitEngineTrackingEnabled = 0;
void metal_command_buffer_track_engines(void *buffer) {
    atomic_store_explicit(&zenitEngineTrackingEnabled, 1, memory_order_relaxed);
    id object = (__bridge id)buffer;
    objc_setAssociatedObject(object, &zenitEngineCountsKey,
        [NSMutableData dataWithLength:3 * sizeof(uint32_t)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
void metal_command_buffer_note_engine(void *buffer, unsigned int engine) {
    if (!atomic_load_explicit(&zenitEngineTrackingEnabled, memory_order_relaxed)) return;
    NSMutableData *data = objc_getAssociatedObject((__bridge id)buffer, &zenitEngineCountsKey);
    if (data && engine < 3) ((uint32_t *)data.mutableBytes)[engine]++;
}
void metal_command_buffer_engine_counts(void *buffer, uint32_t *counts) {
    NSData *data = objc_getAssociatedObject((__bridge id)buffer, &zenitEngineCountsKey);
    if (data) memcpy(counts, data.bytes, 3 * sizeof(uint32_t));
    else memset(counts, 0, 3 * sizeof(uint32_t));
}

// Opt-in per-pass GPU timing (ZENIT_GPU_PASS_TIMING=1): every render pass of a
// command buffer samples GPU timestamps at its vertex start and fragment end;
// on completion the durations are summed per caller-set tag and published for
// the perf trace. Diagnostic only: off, it touches nothing.
#define ZENIT_PASS_TIMER_MAX 512
#define ZENIT_PASS_TIMER_TAGS 32
static _Atomic(unsigned int) zenitPassTimerTag = 0;
static char zenitPassTimerKey;
static pthread_mutex_t zenitPassTimerLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t zenitPassTimerNs[ZENIT_PASS_TIMER_TAGS];
static uint32_t zenitPassTimerCount[ZENIT_PASS_TIMER_TAGS];
static uint64_t zenitPassTimerSeq = 0;
static MTLTimestamp zenitPassTimerCpu0 = 0, zenitPassTimerGpu0 = 0;
@interface ZenitPassTimer : NSObject
@property(nonatomic,strong) id<MTLCounterSampleBuffer> samples;
@property(nonatomic,strong) NSMutableData *tags;
@property(nonatomic) uint32_t count;
@end
@implementation ZenitPassTimer
@end
_Bool metal_pass_timer_enabled(void) {
    static _Atomic(int) cached = -1;
    int enabled = atomic_load_explicit(&cached, memory_order_acquire);
    if (enabled >= 0) return enabled != 0;
    const char *value = getenv("ZENIT_GPU_PASS_TIMING");
    enabled = value && strcmp(value, "1") == 0;
    atomic_store_explicit(&cached, enabled, memory_order_release);
    return enabled != 0;
}
void metal_pass_timer_set_tag(unsigned int tag) {
    atomic_store_explicit(&zenitPassTimerTag, tag < ZENIT_PASS_TIMER_TAGS ? tag : 0, memory_order_relaxed);
}
/// Last completed command buffer: GPU ns and pass count per tag. Returns its sequence number.
uint64_t metal_pass_timer_read(uint64_t *ns, uint32_t *counts) {
    pthread_mutex_lock(&zenitPassTimerLock);
    memcpy(ns, zenitPassTimerNs, sizeof zenitPassTimerNs);
    memcpy(counts, zenitPassTimerCount, sizeof zenitPassTimerCount);
    uint64_t seq = zenitPassTimerSeq;
    pthread_mutex_unlock(&zenitPassTimerLock);
    return seq;
}
static void zenit_pass_timer_attach(id<MTLCommandBuffer> command, MTLRenderPassDescriptor *pass) {
    // Counter sampling at stage boundaries arrived in macOS 11.
    if (@available(macOS 11.0, *)) {
        if (!metal_pass_timer_enabled() || !command || !pass) return;
        ZenitPassTimer *timer = objc_getAssociatedObject(command, &zenitPassTimerKey);
        if (!timer) {
            id<MTLDevice> device = command.device;
            if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return;
            id<MTLCounterSet> timestamps = nil;
            for (id<MTLCounterSet> set in device.counterSets)
                if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
            if (!timestamps) return;
            MTLCounterSampleBufferDescriptor *descriptor = [MTLCounterSampleBufferDescriptor new];
            descriptor.counterSet = timestamps;
            descriptor.sampleCount = 2 * ZENIT_PASS_TIMER_MAX;
            descriptor.storageMode = MTLStorageModeShared;
            NSError *error = nil;
            id<MTLCounterSampleBuffer> samples = [device newCounterSampleBufferWithDescriptor:descriptor error:&error];
            if (!samples) return;
            if (zenitPassTimerCpu0 == 0) [device sampleTimestamps:&zenitPassTimerCpu0 gpuTimestamp:&zenitPassTimerGpu0];
            timer = [ZenitPassTimer new];
            timer.samples = samples;
            timer.tags = [NSMutableData dataWithLength:ZENIT_PASS_TIMER_MAX * sizeof(uint32_t)];
            objc_setAssociatedObject(command, &zenitPassTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
                MTLTimestamp cpu1 = 0, gpu1 = 0;
                [done.device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
                const double ratio = gpu1 > zenitPassTimerGpu0 ? (double)(cpu1 - zenitPassTimerCpu0) / (double)(gpu1 - zenitPassTimerGpu0) : 1.0;
                const uint32_t n = timer.count;
                if (n == 0) return;
                NSData *data = [timer.samples resolveCounterRange:NSMakeRange(0, 2 * n)];
                if (!data) return;
                const MTLCounterResultTimestamp *ts = data.bytes;
                const uint32_t *tags = timer.tags.bytes;
                uint64_t ns[ZENIT_PASS_TIMER_TAGS] = {0};
                uint32_t counts[ZENIT_PASS_TIMER_TAGS] = {0};
                // Exclusive time: from the later of this pass's fragment start and
                // the previous pass's fragment end, to its own fragment end. Vertex
                // work of later passes runs far ahead, so vertex starts mean nothing.
                uint64_t prev_end = 0;
                for (uint32_t i = 0; i < n; i++) {
                    const uint64_t a = ts[2 * i].timestamp, b = ts[2 * i + 1].timestamp;
                    if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a) continue;
                    const uint64_t from = a > prev_end ? a : prev_end;
                    if (b > from) ns[tags[i]] += (uint64_t)((double)(b - from) * ratio);
                    if (b > prev_end) prev_end = b;
                    counts[tags[i]]++;
                }
                pthread_mutex_lock(&zenitPassTimerLock);
                memcpy(zenitPassTimerNs, ns, sizeof ns);
                memcpy(zenitPassTimerCount, counts, sizeof counts);
                zenitPassTimerSeq++;
                pthread_mutex_unlock(&zenitPassTimerLock);
            }];
        }
        if (timer.count >= ZENIT_PASS_TIMER_MAX) return;
        const uint32_t index = timer.count++;
        ((uint32_t *)timer.tags.mutableBytes)[index] = atomic_load_explicit(&zenitPassTimerTag, memory_order_relaxed);
        MTLRenderPassSampleBufferAttachmentDescriptor *attachment = pass.sampleBufferAttachments[0];
        attachment.sampleBuffer = timer.samples;
        attachment.startOfVertexSampleIndex = MTLCounterDontSample;
        attachment.endOfVertexSampleIndex = MTLCounterDontSample;
        attachment.startOfFragmentSampleIndex = 2 * index;
        attachment.endOfFragmentSampleIndex = 2 * index + 1;
    }
}

#include "render_copy.inc"

// Opt-in timing evidence only. Keep the normal submission/presentation path
// unchanged and never wait for a diagnostic callback.
_Bool metal_glass_clock_trace_enabled(void) {
    static _Atomic(int) cached = -1;
    const int enabled = atomic_load_explicit(&cached, memory_order_acquire);
    if (enabled >= 0) return enabled != 0;
    const char *value = getenv("ZENIT_GLASS_CLOCK_TRACE");
    const int initial = value && strcmp(value, "1") == 0;
    // The process environment is configured before launch. Concurrent first
    // readers can publish the same value; callbacks subsequently only load it.
    atomic_store_explicit(&cached, initial, memory_order_release);
    return initial != 0;
}

double metal_glass_clock_trace_host_time(void) { return CACurrentMediaTime(); }

/// A CPU damage patch was handed to Core Animation (it shows at the next
/// commit/vsync); pacing analysis counts it as a presented frame.
void metal_glass_clock_trace_patch(unsigned w, unsigned h) {
    if (!metal_glass_clock_trace_enabled()) return;
    fprintf(stderr, "[glass-clock] {\"kind\":\"patch\",\"host_time\":%.9f,\"w\":%u,\"h\":%u}\n", CACurrentMediaTime(), w, h);
}

void metal_glass_clock_trace_line(const char *line, size_t length) {
    if (!metal_glass_clock_trace_enabled()) return;
    // One stdio call shares stderr's lock with the asynchronous Metal records.
    fprintf(stderr, "[glass-clock] %.*s\n", (int)length, line);
}

void metal_glass_clock_trace_frame(void *buffer, void *drawable, uint64_t frame, uint64_t windowID,
                                  double sampleHostTime, double sampleFrameTimeMs,
                                  double sampleFrameDtMs) {
    if (!metal_glass_clock_trace_enabled()) return;
    // Drawable identities and presented handlers arrived in macOS 10.15.4.
    if (@available(macOS 10.15.4, *)) {
        id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)buffer;
        id<CAMetalDrawable> image = (__bridge id<CAMetalDrawable>)drawable;
        const uintptr_t identity = (uintptr_t)buffer;
        const unsigned long long drawableID = image.drawableID;
        fprintf(stderr, "[glass-clock] {\"kind\":\"submit-ready\",\"frame\":%llu,\"window\":%llu,"
                "\"command_buffer\":\"%p\",\"drawable_id\":%llu,\"host_time\":%.9f,"
                "\"sample_host_time\":%.9f,\"sample_frame_time_ms\":%.6f,\"sample_frame_dt_ms\":%.6f}\n",
                (unsigned long long)frame, (unsigned long long)windowID, buffer, drawableID, CACurrentMediaTime(),
                sampleHostTime, sampleFrameTimeMs, sampleFrameDtMs);
        // Capture scalar identities, not the objects whose handlers own these
        // blocks. The callback arguments stay alive for the duration of each call.
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            fprintf(stderr, "[glass-clock] {\"kind\":\"gpu-complete\",\"frame\":%llu,\"window\":%llu,"
                    "\"command_buffer\":\"%p\",\"drawable_id\":%llu,\"host_time\":%.9f,"
                    "\"gpu_start_time\":%.9f,\"gpu_end_time\":%.9f,\"status\":%ld}\n",
                    (unsigned long long)frame, (unsigned long long)windowID, (void *)identity, drawableID, CACurrentMediaTime(),
                    completed.GPUStartTime, completed.GPUEndTime, (long)completed.status);
        }];
        [image addPresentedHandler:^(id<MTLDrawable> presented) {
            fprintf(stderr, "[glass-clock] {\"kind\":\"presented\",\"frame\":%llu,\"window\":%llu,"
                    "\"command_buffer\":\"%p\",\"drawable_id\":%llu,\"host_time\":%.9f,"
                    "\"presented_time\":%.9f}\n",
                    (unsigned long long)frame, (unsigned long long)windowID, (void *)identity, drawableID, CACurrentMediaTime(),
                    presented.presentedTime);
        }];
    }
}

// ============================================================================
// Device Management
// ============================================================================

/// Create system default Metal device
void* metal_create_system_default_device(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return (__bridge_retained void*)device;
}

/// Get all Metal devices
/// @param out_count output system device count
/// @param out_devices output device array (each +1 retained, caller owns); pass NULL to query count
/// only
/// @param capacity capacity of out_devices; write count won't exceed it
/// @return actual write count to out_devices (min(capacity, total))
///
/// Never writes past capacity: a hot-plugged eGPU can increase the total between query
/// (count -> alloc -> get) and fill.
/// File compiled with -fobjc-arc: MTLCopyAllDevices +1 return auto-balanced by ARC at
/// scope end, no manual release needed.
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

/// Get device name
/// @param device MTLDevice
/// @return C string (caller does not free; managed by device)
const char* metal_device_get_name(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    return [[dev name] UTF8String];
}

/// Create command queue
/// @param device MTLDevice
/// @return MTLCommandQueue (needs release)
void* metal_device_new_command_queue(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    return (__bridge_retained void*)queue;
}

// ============================================================================
// Buffer Management
// ============================================================================

/// Create Buffer
/// @param device MTLDevice
/// @param length buffer size (bytes)
/// @param options MTLResourceOptions
/// @return MTLBuffer (needs release)
// ============================================================================
// GPU resource inventory (ZENIT_GPU_INVENTORY=1)
// ============================================================================
// Every buffer/texture created through the Device is remembered weakly with
// the Zig call site that created it; released objects leave the table on
// their own. `metal_inventory_dump` groups live resources by label and call
// site with their driver-reported allocatedSize, so memory questions are
// answered from the live set instead of guesses.

#import <dlfcn.h>
static NSMapTable *g_inventory; // weak resource -> NSValue(call site)

int metal_inventory_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) enabled = getenv("ZENIT_GPU_INVENTORY") != NULL;
    return enabled;
}

void metal_inventory_note(void* resource, void* site) {
    if (!resource || !metal_inventory_enabled()) return;
    if (!g_inventory) g_inventory = [NSMapTable weakToStrongObjectsMapTable];
    [g_inventory setObject:[NSValue valueWithPointer:site] forKey:(__bridge id)resource];
}

void metal_inventory_dump(void* device, const char* tag) {
    if (!metal_inventory_enabled() || !g_inventory) return;
    @autoreleasepool {
        NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*> *groups = [NSMutableDictionary dictionary];
        uint64_t total = 0, volatile_bytes = 0;
        for (id resource in g_inventory) {
            id<MTLResource> r = resource;
            NSUInteger bytes = r.allocatedSize;
            MTLPurgeableState state = [r setPurgeableState:MTLPurgeableStateKeepCurrent];
            BOOL is_volatile = state == MTLPurgeableStateVolatile || state == MTLPurgeableStateEmpty;
            if (is_volatile) volatile_bytes += bytes; else total += bytes;
            const void *site = [[g_inventory objectForKey:resource] pointerValue];
            Dl_info info; NSString *where = @"?";
            if (site && dladdr(site, &info) && info.dli_sname) where = [NSString stringWithUTF8String:info.dli_sname];
            NSString *shape = [resource conformsToProtocol:@protocol(MTLTexture)]
                ? [NSString stringWithFormat:@"tex %lux%lu", (unsigned long)((id<MTLTexture>)r).width, (unsigned long)((id<MTLTexture>)r).height]
                : @"buf";
            NSString *key = [NSString stringWithFormat:@"%@%@ | %@ | %@", is_volatile ? @"(volatile) " : @"", r.label ?: @"-", shape, where];
            NSMutableArray<NSNumber*> *g = groups[key];
            if (!g) { g = [NSMutableArray arrayWithObjects:@0, @0, nil]; groups[key] = g; }
            g[0] = @(g[0].unsignedLongLongValue + 1); g[1] = @(g[1].unsignedLongLongValue + bytes);
        }
        uint64_t device_total = ((__bridge id<MTLDevice>)device).currentAllocatedSize;
        fprintf(stderr, "[gpu-inventory] %s: tracked nonvolatile %.2f MiB, volatile %.2f MiB, device currentAllocatedSize %.2f MiB\n",
                tag, total / 1048576.0, volatile_bytes / 1048576.0, device_total / 1048576.0);
        NSArray *keys = [groups keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            return [b[1] compare:a[1]];
        }];
        for (NSString *key in keys) {
            NSArray<NSNumber*> *g = groups[key];
            fprintf(stderr, "[gpu-inventory]   %8.2f MiB  x%-3llu %s\n", [g[1] unsignedLongLongValue] / 1048576.0, [g[0] unsignedLongLongValue], key.UTF8String);
        }
    }
}

/// Mark a buffer/texture volatile (1) or non-volatile (0). Volatile storage
/// leaves the process footprint and may be discarded under memory pressure.
/// Returns 1 when making it non-volatile found the contents discarded.
int metal_resource_set_volatile(void* resource, int make_volatile) {
    id<MTLResource> r = (__bridge id<MTLResource>)resource;
    MTLPurgeableState previous = [r setPurgeableState:make_volatile ? MTLPurgeableStateVolatile : MTLPurgeableStateNonVolatile];
    return !make_volatile && previous == MTLPurgeableStateEmpty;
}

void* metal_device_new_buffer(void* device, size_t length, unsigned int options) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLBuffer> buffer = [dev newBufferWithLength:length
                                            options:(MTLResourceOptions)options];
    return (__bridge_retained void*)buffer;
}

/// Get Buffer content pointer
/// @param buffer MTLBuffer
/// @return memory pointer (lifetime managed by buffer)
void* metal_buffer_contents(void* buffer) {
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    return [buf contents];
}

/// Get Buffer size
/// @param buffer MTLBuffer
/// @return byte size
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

/// Create texture descriptor
/// @return MTLTextureDescriptor (needs release)
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

/// Set texture descriptor properties
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

void metal_texture_descriptor_set_cpu_cache_write_combined(void* desc) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.cpuCacheMode = MTLCPUCacheModeWriteCombined;
}

unsigned long metal_resource_cpu_cache_mode(void* resource) {
    return (unsigned long)((__bridge id<MTLResource>)resource).cpuCacheMode;
}

void metal_texture_descriptor_set_storage_mode(void* desc, unsigned long mode) {
    MTLTextureDescriptor* d = (__bridge MTLTextureDescriptor*)desc;
    d.storageMode = (MTLStorageMode)mode;
}

/// Create texture
/// @param device MTLDevice
/// @param desc MTLTextureDescriptor
/// @return MTLTexture (needs release)
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

/// Create sampler descriptor
/// @return MTLSamplerDescriptor (needs release)
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

/// Create sampler
/// @param device MTLDevice
/// @param desc MTLSamplerDescriptor
/// @return MTLSamplerState (needs release)
void* metal_device_new_sampler(void* device, void* desc) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLSamplerDescriptor* d = (__bridge MTLSamplerDescriptor*)desc;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:d];
    return (__bridge_retained void*)sampler;
}

// ============================================================================
// Convenience texture/sampler creation functions
// ============================================================================

/// Convenience function: create 2D texture
/// @param device MTLDevice
/// @param width
/// @param height
/// @param pixelFormat pixel format
/// @param usage
/// @param storageMode storage mode
/// @return MTLTexture (needs release)
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

/// Convenience function: create 2D texture (optional mipmaps)
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

/// Convenience function: create sampler
/// @param device MTLDevice
/// @param minFilter min filter
/// @param magFilter mag filter
/// @param sAddressMode S address mode
/// @param tAddressMode T address mode
/// @return MTLSamplerState (needs release)
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

/// Convenience function: create sampler (with mip filter)
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

/// Replace texture region content
/// @param texture MTLTexture
/// @param x X coordinate
/// @param y Y coordinate
/// @param width
/// @param height
/// @param bytes pixel data
/// @param bytesPerRow bytes per row
void metal_texture_replace_region(void* texture, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const void* bytes, unsigned int bytesPerRow) {
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    MTLRegion region = MTLRegionMake2D(x, y, width, height);
    [tex replaceRegion:region
           mipmapLevel:0
             withBytes:bytes
           bytesPerRow:bytesPerRow];
}

/// Replace texture region content (specified mip level)
void metal_texture_replace_region_level(void* texture, unsigned int x, unsigned int y, unsigned int width, unsigned int height, unsigned long mipLevel, const void* bytes, unsigned int bytesPerRow) {
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    MTLRegion region = MTLRegionMake2D(x, y, width, height);
    [tex replaceRegion:region
           mipmapLevel:mipLevel
             withBytes:bytes
           bytesPerRow:bytesPerRow];
}

/// Read BGRA8 pixels from texture (mip0).
/// Returns 1 on success, 0 on failure.
unsigned long metal_texture_pixel_format(void* texture) {
    return (unsigned long)((__bridge id<MTLTexture>)texture).pixelFormat;
}

unsigned long metal_texture_usage(void* texture) {
    return (unsigned long)((__bridge id<MTLTexture>)texture).usage;
}

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

/// Create command buffer
/// @param queue MTLCommandQueue
/// @return MTLCommandBuffer (needs release)
void* metal_command_queue_command_buffer(void* queue) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<MTLCommandBuffer> cmd_buffer = [q commandBuffer];
    return (__bridge_retained void*)cmd_buffer;
}

/// Submit command buffer
/// @param buffer MTLCommandBuffer
static char *memoryMetalFrameLogPath;
static void initializeMemoryMetalFrameLogPath(void) {
    const char *value=getenv("ZENIT_MEMORY_METAL_FRAME_LOG");
    if(value) memoryMetalFrameLogPath=strdup(value); // Owned process-lifetime diagnostic option.
}
static const char *zenitMemoryMetalFrameLogPath(void) {
    static pthread_once_t once=PTHREAD_ONCE_INIT;
    pthread_once(&once,initializeMemoryMetalFrameLogPath);
    return memoryMetalFrameLogPath;
}

static void zenitMemoryMetalFrameLogWarning(int error) {
    static atomic_flag warned = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set_explicit(&warned, memory_order_relaxed))
        fprintf(stderr, "[Metal frame log] diagnostic write failed: %s\n", strerror(error));
}

void metal_command_buffer_commit(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    if (metal_glass_clock_trace_enabled()) {
        fprintf(stderr, "[glass-clock] {\"kind\":\"commit\",\"command_buffer\":\"%p\",\"host_time\":%.9f}\n",
                buffer, CACurrentMediaTime());
    }
    const char *path=zenitMemoryMetalFrameLogPath();
    if(path) {
        @autoreleasepool {
            uint32_t counts[3]; metal_command_buffer_engine_counts(buffer, counts);
            uint64_t allocated=buf.commandQueue.device.currentAllocatedSize;
            uint32_t render=counts[0], blit=counts[1], compute=counts[2];
            [buf addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                FILE *log=fopen(path,"a");
                if (!log) { zenitMemoryMetalFrameLogWarning(errno); return; }
                int written=fprintf(log,"{\"deviceAllocated\":%llu,\"render\":%u,\"blit\":%u,\"compute\":%u,\"gpu_us\":%.3f}\n",
                    (unsigned long long)allocated,render,blit,compute,
                    (completed.GPUEndTime-completed.GPUStartTime)*1e6);
                int writeError = written < 0 ? errno : 0;
                // Always close, including when fprintf failed. fclose consumes
                // the stream even when its final flush reports an error.
                int closed = fclose(log);
                if (written < 0 || closed != 0)
                    zenitMemoryMetalFrameLogWarning(writeError ? writeError : errno);
            }];
        }
    }
    [buf commit];
}

/// Wait for command buffer completion
/// @param buffer MTLCommandBuffer
void metal_command_buffer_wait_until_completed(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    [buf waitUntilCompleted];
}

// ============================================================================
// Shader Library
// ============================================================================

/// Create shader library from source
/// @param device MTLDevice
/// @param source MSL source code
/// @param source_length source length
/// @param error_out error message output (if non-null)
/// @return MTLLibrary (needs release)
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

/// Get function from library
/// @param library MTLLibrary
/// @param name function name
/// @return MTLFunction (needs release)
void* metal_library_new_function(void* library, const char* name) {
    id<MTLLibrary> lib = (__bridge id<MTLLibrary>)library;
    NSString* name_str = [NSString stringWithUTF8String:name];
    id<MTLFunction> function = [lib newFunctionWithName:name_str];
    return (__bridge_retained void*)function;
}

// ============================================================================
// Reference Counting
// ============================================================================

/// Release object
/// @param obj any Objective-C object
void metal_release(void* obj) {
    // Releasing a Metal owner can itself autorelease internal drawable/cache
    // objects. This ABI is also called during teardown outside a render frame.
    @autoreleasepool { if (obj) CFRelease(obj); }
}

/// Retain object
/// @param obj any Objective-C object
/// @return same object (reference count +1)
void* metal_retain(void* obj) {
    if (obj) {
        CFRetain(obj);
    }
    return obj;
}

// ============================================================================
// Autorelease Pool Management (ARC-compatible)
// ============================================================================

/// Under ARC, NSAutoreleasePool cannot be directly managed;
/// provide callback-based API instead.

/// Execute function in autorelease pool
/// @param callback callback function
/// @param context context passed to callback
typedef void (*AutoreleaseCallback)(void* context);

void objc_autoreleasepool_run(AutoreleaseCallback callback, void* context) {
    @autoreleasepool {
        callback(context);
    }
}

// Push/Pop API requires different implementation under ARC;
// use private runtime functions (not recommended but viable).
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

/// Release the layer's idle drawable pool. CAMetalLayer keeps every drawable
/// it ever allocated (up to maximumDrawableCount) for its lifetime; a size
/// change drops the pool while the presented contents stay on screen. Setting
/// a different size and restoring it in the same turn keeps one drawable (the
/// on-screen one) and frees the rest; the next nextDrawable reallocates.
void metal_layer_purge_drawables(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    CGSize size = l.drawableSize;
    if (getenv("ZENIT_DEBUG_DRAWABLES")) fprintf(stderr, "[drawable] t=%.3f layer=%p purge\n", CACurrentMediaTime(), layer);
    if (size.width <= 1 || size.height <= 1) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.drawableSize = CGSizeMake(1, 1);
    l.drawableSize = size;
    [CATransaction commit];
    [CATransaction flush];
}

void metal_layer_set_device(void* layer, void* device) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    l.device = d;
}

void metal_layer_set_pixel_format(void* layer, unsigned long format) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.pixelFormat = (MTLPixelFormat)format;
}

void metal_layer_set_framebuffer_only(void* layer, _Bool value) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.framebufferOnly = value;
}

void metal_layer_set_maximum_drawable_count(void* layer, size_t count) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.maximumDrawableCount = count;
}

void metal_layer_set_display_sync_enabled(void* layer, _Bool enabled) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (@available(macOS 10.13, *)) {
        l.displaySyncEnabled = enabled;
    }
}

void metal_layer_set_allows_next_drawable_timeout(void* layer, _Bool allows) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (@available(macOS 10.13, *)) {
        l.allowsNextDrawableTimeout = allows;
    }
}

void metal_layer_set_opaque(void* layer, _Bool opaque) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.opaque = opaque;
}

void metal_layer_set_wants_edr(void* layer, _Bool wants) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (@available(macOS 10.15, *)) {
        l.wantsExtendedDynamicRangeContent = wants;
    }
}

void metal_layer_set_drawable_size(void* layer, unsigned int width, unsigned int height) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    CGSize size=CGSizeMake(width,height);
    if (!CGSizeEqualToSize(l.drawableSize,size)) l.drawableSize=size;
}

/// Get nextDrawable — [owned] return +1, caller takes ownership, do not retain again.
// AX frame-interior service
//
// Problem: the main thread spends most of each frame blocked in [CAMetalLayer nextDrawable]'s
// semaphore (which also throttles vsync); the run loop spins only ~0.1ms per 16.7ms. AppKit
// dispatches AX requests on the main run loop, so each AXChildren round-trip adds a fixed
// ~33ms. VoiceOver issues dozens of queries per step, so animated UI reads stutter.
//
// Solution: run the blocking nextDrawable on a serial queue; the main thread meanwhile runs only
// in `com.apple.accessibilityServerIPC` run loop mode. That mode contains **only** the AX
// service MIG source (no timers, observers, other sources), so the wait processes AX requests
// only: no input events, timers, or CATransaction re-entry mid-frame. a11y projection is already
// complete at this point (Cx.render runs before drawable fetch), so AX queries read a consistent
// snapshot; state-mutating AX actions are deferred by window_bridge.m to post-frame
// (zenit_ax_in_frame_service).
//
// Fallback: the mode exists only while an AX client is connected; if absent,
// CFRunLoopRunInMode returns Finished immediately and it degrades to plain blocking (zero
// overhead). Off-thread calls behave similarly. Rollback: ZENIT_AX_FRAME_SERVICE=0.
static _Atomic int g_zenit_ax_service_depth = 0;

int zenit_ax_in_frame_service(void) {
    return atomic_load(&g_zenit_ax_service_depth) > 0;
}

static CFStringRef zenitAXServerMode(void) {
    return CFSTR("com.apple.accessibilityServerIPC");
}

static BOOL zenitAXFrameServiceEnabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char *v = getenv("ZENIT_AX_FRAME_SERVICE");
        enabled = (v && v[0] == '0') ? 0 : 1;
    }
    return enabled == 1;
}

/// AX mode present in main run loop (created when AX client connects). Once present,
/// cache as true; check each time before (CFRunLoopCopyAllModes is just ~10 elements).
static BOOL zenitAXServerModeExists(void) {
    static BOOL seen = NO;
    if (seen) return YES;
    CFArrayRef modes = CFRunLoopCopyAllModes(CFRunLoopGetMain());
    if (!modes) return NO;
    seen = CFArrayContainsValue(modes, CFRangeMake(0, CFArrayGetCount(modes)), zenitAXServerMode());
    CFRelease(modes);
    return seen;
}

static void zenitAXWakeSourcePerform(void *info) { (void)info; }

/// Debug switch ZENIT_DEBUG_DRAWABLE_DELAY_MS=N: artificially wait N ms before
/// nextDrawable, reliably reproducing 'main thread blocked on drawable backpressure'.
/// Real backpressure depends on window visibility, refresh rate and compositor load, so it is
/// intermittent. Makes AX latency regression tests deterministic (scripts/check_a11y.sh: with
/// 30ms injected, AXChildren must still be sub-millisecond).
static void zenitDebugDrawableDelay(void) {
    // Main thread (early exit path) and drawable-fetching queue thread both arrive here;
    // lazy init with atomic.
    static _Atomic int ms = -1;
    int value = atomic_load(&ms);
    if (value < 0) {
        const char *v = getenv("ZENIT_DEBUG_DRAWABLE_DELAY_MS");
        value = v ? atoi(v) : 0;
        atomic_store(&ms, value);
    }
    if (value > 0) usleep((useconds_t)value * 1000);
}

/// ZENIT_DEBUG_DRAWABLES=1: log the IOSurface behind every acquired drawable,
/// so the layer pool's real size and turnover can be read from the log.
static void zenitDebugDrawableLog(id<CAMetalDrawable> drawable) {
    static int enabled = -1;
    if (enabled < 0) enabled = getenv("ZENIT_DEBUG_DRAWABLES") != NULL;
    if (!enabled || !drawable) return;
    fprintf(stderr, "[drawable] t=%.3f layer=%p surface=%p max=%lu\n", CACurrentMediaTime(), (__bridge void *)drawable.layer,
            (void *)drawable.texture.iosurface, (unsigned long)drawable.layer.maximumDrawableCount);
}

void* metal_layer_next_drawable(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (!zenitAXFrameServiceEnabled() || ![NSThread isMainThread] || !zenitAXServerModeExists()) {
        zenitDebugDrawableDelay();
        id<CAMetalDrawable> drawable = [l nextDrawable];
        zenitDebugDrawableLog(drawable);
        return (__bridge_retained void*)drawable;
    }

    // Only main thread arrives here (already checked above); static flag suffices.
    // Avoid dispatch_once: its inline macro triggers UBSan in Zig Debug builds
    // (see image_bridge.m comment).
    static dispatch_queue_t queue;
    static CFRunLoopSourceRef wakeSource;
    if (!queue) {
        queue = dispatch_queue_create("zenit.drawable-acquire",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        CFRunLoopSourceContext ctx = {0};
        ctx.perform = zenitAXWakeSourcePerform;
        wakeSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
        CFRunLoopAddSource(CFRunLoopGetMain(), wakeSource, zenitAXServerMode());
    }

    __block id<CAMetalDrawable> drawable = nil;
    __block _Atomic bool done = false;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    CFRunLoopRef mainLoop = CFRunLoopGetMain();
    dispatch_async(queue, ^{
        @autoreleasepool {
            zenitDebugDrawableDelay();
            drawable = [l nextDrawable];
            atomic_store(&done, true);
            dispatch_semaphore_signal(sem);
            CFRunLoopSourceSignal(wakeSource);
            CFRunLoopWakeUp(mainLoop);
        }
    });

    atomic_fetch_add(&g_zenit_ax_service_depth, 1);
    // @finally: if AX callback throws ObjC exception, depth must be restored too,
    // else all subsequent AX actions permanently deferred (cross-review noted).
    @try {
        while (!atomic_load(&done)) {
            // returnAfterSourceHandled: return after handling one AX request or woken by
            // wakeSource, re-check done at loop head. 0.1s timeout is backstop only;
            // normal path woken by wakeSource.
            SInt32 result = CFRunLoopRunInMode(zenitAXServerMode(), 0.1, true);
            if (result == kCFRunLoopRunFinished || result == kCFRunLoopRunStopped) {
                // Mode removed / stopped externally: revert to blocking wait, never busy-loop.
                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                break;
            }
        }
    } @finally {
        atomic_fetch_sub(&g_zenit_ax_service_depth, 1);
    }
    zenitDebugDrawableLog(drawable);
    return (__bridge_retained void*)drawable;
}

/// Drawable present
void metal_drawable_present(void* drawable) {
    id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
    [d present];
}

_Bool metal_layer_presents_with_transaction(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    return l.presentsWithTransaction;
}

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
    zenitScheduleDrawablePresentation(buf,d);
}

/// Wait until scheduled
void metal_command_buffer_wait_until_scheduled(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    [buf waitUntilScheduled];
}

/// Create command buffer from queue — [owned] return +1, caller takes ownership,
/// do not retain again.
void* metal_queue_command_buffer(void* queue) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<MTLCommandBuffer> cmd_buffer = [q commandBuffer];
    return (__bridge_retained void*)cmd_buffer;
}

// ============================================================================
// Render Pass Descriptor
// ============================================================================

/// Create render pass descriptor
/// @return MTLRenderPassDescriptor (autoreleased; use within autorelease pool)
void* metal_render_pass_descriptor_new(void) {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    return (__bridge_retained void*)desc; // Explicit retain
}

/// Get color attachment descriptor
/// @param desc MTLRenderPassDescriptor
/// @param index attachment index
/// @return MTLRenderPassColorAttachmentDescriptor (autoreleased)
void* metal_render_pass_get_color_attachment(void* desc, unsigned long index) {
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    return (__bridge void*)[d.colorAttachments objectAtIndexedSubscript:index];
}

/// Get depth attachment descriptor
/// @param desc MTLRenderPassDescriptor
/// @return MTLRenderPassDepthAttachmentDescriptor (autoreleased)
void* metal_render_pass_get_depth_attachment(void* desc) {
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    return (__bridge void*)d.depthAttachment;
}

/// Get stencil attachment descriptor
/// @param desc MTLRenderPassDescriptor
/// @return MTLRenderPassStencilAttachmentDescriptor (autoreleased)
void* metal_render_pass_get_stencil_attachment(void* desc) {
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    return (__bridge void*)d.stencilAttachment;
}

// ============================================================================
// Render Pass Color Attachment Configuration
// ============================================================================

void metal_color_attachment_set_texture(void* attachment, void* texture) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.texture = tex;
}

void metal_color_attachment_set_load_action(void* attachment, unsigned long action) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    at.loadAction = (MTLLoadAction)action;
}

void metal_color_attachment_set_store_action(void* attachment, unsigned long action) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    at.storeAction = (MTLStoreAction)action;
}

void metal_color_attachment_set_clear_color(void* attachment, double r, double g, double b, double a) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    at.clearColor = MTLClearColorMake(r, g, b, a);
}

void metal_color_attachment_set_resolve_texture(void* attachment, void* texture) {
    MTLRenderPassColorAttachmentDescriptor* at = (__bridge MTLRenderPassColorAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.resolveTexture = tex;
}

// ============================================================================
// Render Pass Depth/Stencil Attachment Configuration
// ============================================================================

void metal_depth_attachment_set_texture(void* attachment, void* texture) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.texture = tex;
}

void metal_depth_attachment_set_load_action(void* attachment, unsigned long action) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    at.loadAction = (MTLLoadAction)action;
}

void metal_depth_attachment_set_store_action(void* attachment, unsigned long action) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    at.storeAction = (MTLStoreAction)action;
}

void metal_depth_attachment_set_clear_depth(void* attachment, double depth) {
    MTLRenderPassDepthAttachmentDescriptor* at = (__bridge MTLRenderPassDepthAttachmentDescriptor*)attachment;
    at.clearDepth = depth;
}

void metal_stencil_attachment_set_texture(void* attachment, void* texture) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    at.texture = tex;
}

void metal_stencil_attachment_set_load_action(void* attachment, unsigned long action) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    at.loadAction = (MTLLoadAction)action;
}

void metal_stencil_attachment_set_store_action(void* attachment, unsigned long action) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    at.storeAction = (MTLStoreAction)action;
}

void metal_stencil_attachment_set_clear_stencil(void* attachment, unsigned int stencil) {
    MTLRenderPassStencilAttachmentDescriptor* at = (__bridge MTLRenderPassStencilAttachmentDescriptor*)attachment;
    at.clearStencil = stencil;
}

// ============================================================================
// Render Command Encoder
// ============================================================================

/// Create render command encoder
/// @param buffer MTLCommandBuffer
/// @param desc MTLRenderPassDescriptor
/// @return MTLRenderCommandEncoder, [owned] +1, caller takes ownership,
/// do not retain again.
void* metal_command_buffer_create_render_encoder(void* buffer, void* desc) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    MTLRenderPassDescriptor* d = (__bridge MTLRenderPassDescriptor*)desc;
    zenit_pass_timer_attach(buf, d);
    id<MTLRenderCommandEncoder> encoder = [buf renderCommandEncoderWithDescriptor:d];
    if (encoder) metal_command_buffer_note_engine(buffer, 0);
    return (__bridge_retained void*)encoder;
}

/// Render encoder without attachments over a width x height raster: its
/// fragment functions write textures directly. [owned] +1.
void* metal_command_buffer_create_attachmentless_render_encoder(void* buffer, unsigned int width, unsigned int height) {
    @autoreleasepool {
        id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
        MTLRenderPassDescriptor* d = [MTLRenderPassDescriptor renderPassDescriptor];
        d.renderTargetWidth = width;
        d.renderTargetHeight = height;
        d.defaultRasterSampleCount = 1;
        zenit_pass_timer_attach(buf, d);
        id<MTLRenderCommandEncoder> encoder = [buf renderCommandEncoderWithDescriptor:d];
        if (encoder) metal_command_buffer_note_engine(buffer, 0);
        return (__bridge_retained void*)encoder;
    }
}

void metal_render_encoder_end_encoding(void* encoder) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc endEncoding];
}

void metal_render_encoder_set_render_pipeline_state(void* encoder, void* pipeline) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLRenderPipelineState> ps = (__bridge id<MTLRenderPipelineState>)pipeline;
    [enc setRenderPipelineState:ps];
}

void metal_render_encoder_set_viewport(void* encoder, double x, double y, double width, double height, double znear, double zfar) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    MTLViewport viewport = {x, y, width, height, znear, zfar};
    [enc setViewport:viewport];
}

void metal_render_encoder_set_scissor_rect(void* encoder, unsigned long x, unsigned long y, unsigned long width, unsigned long height) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    MTLScissorRect scissor = {x, y, width, height};
    [enc setScissorRect:scissor];
}

void metal_render_encoder_set_cull_mode(void* encoder, unsigned long mode) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setCullMode:(MTLCullMode)mode];
}

void metal_render_encoder_set_front_facing_winding(void* encoder, unsigned long winding) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setFrontFacingWinding:(MTLWinding)winding];
}

void metal_render_encoder_set_triangle_fill_mode(void* encoder, unsigned long fillMode) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setTriangleFillMode:(MTLTriangleFillMode)fillMode];
}

void metal_render_encoder_set_depth_stencil_state(void* encoder, void* state) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLDepthStencilState> ds = (__bridge id<MTLDepthStencilState>)state;
    [enc setDepthStencilState:ds];
}

void metal_render_encoder_set_depth_bias(void* encoder, float constant, float slope, float clamp) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setDepthBias:constant slopeScale:slope clamp:clamp];
}

// ============================================================================
// Render Encoder - Resource Binding
// ============================================================================

void metal_render_encoder_set_vertex_buffer(void* encoder, void* buffer, unsigned long offset, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [enc setVertexBuffer:buf offset:offset atIndex:index];
}

void metal_render_encoder_set_fragment_buffer(void* encoder, void* buffer, unsigned long offset, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [enc setFragmentBuffer:buf offset:offset atIndex:index];
}

void metal_render_encoder_set_vertex_texture(void* encoder, void* texture, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [enc setVertexTexture:tex atIndex:index];
}

void metal_render_encoder_set_fragment_texture(void* encoder, void* texture, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [enc setFragmentTexture:tex atIndex:index];
}

void metal_render_encoder_set_vertex_sampler(void* encoder, void* sampler, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLSamplerState> samp = (__bridge id<MTLSamplerState>)sampler;
    [enc setVertexSamplerState:samp atIndex:index];
}

void metal_render_encoder_set_fragment_sampler(void* encoder, void* sampler, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLSamplerState> samp = (__bridge id<MTLSamplerState>)sampler;
    [enc setFragmentSamplerState:samp atIndex:index];
}

void metal_render_encoder_set_vertex_bytes(void* encoder, const void* bytes, unsigned long length, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setVertexBytes:bytes length:length atIndex:index];
}

void metal_render_encoder_set_fragment_bytes(void* encoder, const void* bytes, unsigned long length, unsigned long index) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc setFragmentBytes:bytes length:length atIndex:index];
}

// ============================================================================
// Render Encoder - Draw Calls
// ============================================================================

void metal_render_encoder_draw_primitives(void* encoder, unsigned long primitiveType, unsigned long vertexStart, unsigned long vertexCount) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc drawPrimitives:(MTLPrimitiveType)primitiveType
            vertexStart:vertexStart
            vertexCount:vertexCount];
}

void metal_render_encoder_draw_primitives_instanced(void* encoder, unsigned long primitiveType, unsigned long vertexStart, unsigned long vertexCount, unsigned long instanceCount) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc drawPrimitives:(MTLPrimitiveType)primitiveType
            vertexStart:vertexStart
            vertexCount:vertexCount
          instanceCount:instanceCount];
}

void metal_render_encoder_draw_primitives_instanced_base_instance(void* encoder, unsigned long primitiveType, unsigned long vertexStart, unsigned long vertexCount, unsigned long instanceCount, unsigned long baseInstance) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    [enc drawPrimitives:(MTLPrimitiveType)primitiveType
            vertexStart:vertexStart
            vertexCount:vertexCount
          instanceCount:instanceCount
           baseInstance:baseInstance];
}

void metal_render_encoder_draw_indexed_primitives(void* encoder, unsigned long primitiveType, unsigned long indexCount, unsigned long indexType, void* indexBuffer, unsigned long indexBufferOffset) {
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)indexBuffer;
    [enc drawIndexedPrimitives:(MTLPrimitiveType)primitiveType
                    indexCount:indexCount
                     indexType:(MTLIndexType)indexType
                   indexBuffer:buf
             indexBufferOffset:indexBufferOffset];
}

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

/// Create compute command encoder
/// @param buffer MTLCommandBuffer
/// @return MTLComputeCommandEncoder (needs release)
void* metal_command_buffer_create_compute_encoder(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    id<MTLComputeCommandEncoder> encoder = [buf computeCommandEncoder];
    if (encoder) metal_command_buffer_note_engine(buffer, 2);
    return (__bridge_retained void*)encoder;
}

void metal_compute_encoder_end_encoding(void* encoder) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    [enc endEncoding];
}

void metal_compute_encoder_set_compute_pipeline_state(void* encoder, void* pipeline) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLComputePipelineState> ps = (__bridge id<MTLComputePipelineState>)pipeline;
    [enc setComputePipelineState:ps];
}

void metal_compute_encoder_set_buffer(void* encoder, void* buffer, unsigned long offset, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [enc setBuffer:buf offset:offset atIndex:index];
}

void metal_compute_encoder_set_texture(void* encoder, void* texture, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [enc setTexture:tex atIndex:index];
}

void metal_compute_encoder_set_sampler(void* encoder, void* sampler, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    id<MTLSamplerState> samp = (__bridge id<MTLSamplerState>)sampler;
    [enc setSamplerState:samp atIndex:index];
}

void metal_compute_encoder_set_bytes(void* encoder, const void* bytes, unsigned long length, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    [enc setBytes:bytes length:length atIndex:index];
}

void metal_compute_encoder_set_threadgroup_memory_length(void* encoder, unsigned long length, unsigned long index) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    [enc setThreadgroupMemoryLength:length atIndex:index];
}

void metal_compute_encoder_dispatch_threadgroups(void* encoder, unsigned long threadgroupsX, unsigned long threadgroupsY, unsigned long threadgroupsZ, unsigned long threadsPerGroupX, unsigned long threadsPerGroupY, unsigned long threadsPerGroupZ) {
    id<MTLComputeCommandEncoder> enc = (__bridge id<MTLComputeCommandEncoder>)encoder;
    MTLSize threadgroups = MTLSizeMake(threadgroupsX, threadgroupsY, threadgroupsZ);
    MTLSize threadsPerGroup = MTLSizeMake(threadsPerGroupX, threadsPerGroupY, threadsPerGroupZ);
    [enc dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
}

// ============================================================================
// Blit Command Encoder
// ============================================================================

/// Create Blit command encoder
/// @param buffer MTLCommandBuffer
/// @return MTLBlitCommandEncoder (needs release)
void* metal_command_buffer_create_blit_encoder(void* buffer) {
    id<MTLCommandBuffer> buf = (__bridge id<MTLCommandBuffer>)buffer;
    id<MTLBlitCommandEncoder> encoder = [buf blitCommandEncoder];
    if (encoder) metal_command_buffer_note_engine(buffer, 1);
    return (__bridge_retained void*)encoder;
}

void metal_blit_encoder_end_encoding(void* encoder) {
    id<MTLBlitCommandEncoder> enc = (__bridge id<MTLBlitCommandEncoder>)encoder;
    [enc endEncoding];
}

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

/// Create Metal Library from source
/// @param device MTLDevice
/// @param source Metal Shading Language source
/// @param error_out error message output (if non-NULL and error occurs)
/// @return MTLLibrary (needs release); NULL on failure
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

// metal_library_new_function already defined above

// ============================================================================
// Render Pipeline Management
// ============================================================================

/// Create render pipeline descriptor
/// @return MTLRenderPipelineDescriptor (needs release)
void* metal_render_pipeline_descriptor_new(void) {
    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    return (__bridge_retained void*)desc;
}

void metal_render_pipeline_descriptor_set_vertex_function(void* desc, void* function) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.vertexFunction = (__bridge id<MTLFunction>)function;
}

void metal_render_pipeline_descriptor_set_fragment_function(void* desc, void* function) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.fragmentFunction = (__bridge id<MTLFunction>)function;
}

void metal_render_pipeline_descriptor_set_color_attachment_format(void* desc, unsigned long index, unsigned long format) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].pixelFormat = (MTLPixelFormat)format;
}

void metal_render_pipeline_descriptor_set_depth_attachment_format(void* desc, unsigned long format) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.depthAttachmentPixelFormat = (MTLPixelFormat)format;
}

void metal_render_pipeline_descriptor_set_stencil_attachment_format(void* desc, unsigned long format) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)format;
}

void metal_render_pipeline_descriptor_set_sample_count(void* desc, unsigned long count) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.rasterSampleCount = count;
}

void metal_render_pipeline_descriptor_set_vertex_descriptor(void* desc, void* vertex_desc) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.vertexDescriptor = (__bridge MTLVertexDescriptor*)vertex_desc;
}

/// Create render pipeline state
/// @param device MTLDevice
/// @param desc MTLRenderPipelineDescriptor
/// @param error_out error message output
/// @return MTLRenderPipelineState (needs release)
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

/// Create vertex descriptor
/// @return MTLVertexDescriptor (needs release)
void* metal_vertex_descriptor_new(void) {
    MTLVertexDescriptor* desc = [[MTLVertexDescriptor alloc] init];
    return (__bridge_retained void*)desc;
}

void metal_vertex_descriptor_set_attribute_format(void* desc, unsigned long index, unsigned long format) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.attributes[index].format = (MTLVertexFormat)format;
}

void metal_vertex_descriptor_set_attribute_offset(void* desc, unsigned long index, unsigned long offset) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.attributes[index].offset = offset;
}

void metal_vertex_descriptor_set_attribute_buffer_index(void* desc, unsigned long index, unsigned long buffer_index) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.attributes[index].bufferIndex = buffer_index;
}

void metal_vertex_descriptor_set_layout_stride(void* desc, unsigned long index, unsigned long stride) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.layouts[index].stride = stride;
}

void metal_vertex_descriptor_set_layout_step_function(void* desc, unsigned long index, unsigned long step_function) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.layouts[index].stepFunction = (MTLVertexStepFunction)step_function;
}

void metal_vertex_descriptor_set_layout_step_rate(void* desc, unsigned long index, unsigned long step_rate) {
    MTLVertexDescriptor* d = (__bridge MTLVertexDescriptor*)desc;
    d.layouts[index].stepRate = step_rate;
}

// ============================================================================
// Depth Stencil State Management
// ============================================================================

/// Create depth-stencil descriptor
/// @return MTLDepthStencilDescriptor (needs release)
void* metal_depth_stencil_descriptor_new(void) {
    MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
    return (__bridge_retained void*)desc;
}

void metal_depth_stencil_descriptor_set_depth_compare_function(void* desc, unsigned long compare_function) {
    MTLDepthStencilDescriptor* d = (__bridge MTLDepthStencilDescriptor*)desc;
    d.depthCompareFunction = (MTLCompareFunction)compare_function;
}

void metal_depth_stencil_descriptor_set_depth_write_enabled(void* desc, int enabled) {
    MTLDepthStencilDescriptor* d = (__bridge MTLDepthStencilDescriptor*)desc;
    d.depthWriteEnabled = enabled ? YES : NO;
}

/// Create depth-stencil state
/// @param device MTLDevice
/// @param desc MTLDepthStencilDescriptor
/// @return MTLDepthStencilState (needs release)
void* metal_device_new_depth_stencil_state(void* device, void* desc) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLDepthStencilDescriptor* d = (__bridge MTLDepthStencilDescriptor*)desc;
    id<MTLDepthStencilState> state = [dev newDepthStencilStateWithDescriptor:d];
    return (__bridge_retained void*)state;
}

// ============================================================================
// Color Attachment Blending
// ============================================================================

void metal_render_pipeline_color_attachment_set_blending_enabled(void* desc, unsigned long index, int enabled) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].blendingEnabled = enabled ? YES : NO;
}

void metal_render_pipeline_color_attachment_set_source_rgb_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].sourceRGBBlendFactor = (MTLBlendFactor)factor;
}

void metal_render_pipeline_color_attachment_set_destination_rgb_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].destinationRGBBlendFactor = (MTLBlendFactor)factor;
}

void metal_render_pipeline_color_attachment_set_rgb_blend_operation(void* desc, unsigned long index, unsigned long operation) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].rgbBlendOperation = (MTLBlendOperation)operation;
}

void metal_render_pipeline_color_attachment_set_source_alpha_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].sourceAlphaBlendFactor = (MTLBlendFactor)factor;
}

void metal_render_pipeline_color_attachment_set_destination_alpha_blend_factor(void* desc, unsigned long index, unsigned long factor) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].destinationAlphaBlendFactor = (MTLBlendFactor)factor;
}

void metal_render_pipeline_color_attachment_set_alpha_blend_operation(void* desc, unsigned long index, unsigned long operation) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].alphaBlendOperation = (MTLBlendOperation)operation;
}

void metal_render_pipeline_color_attachment_set_write_mask(void* desc, unsigned long index, unsigned long mask) {
    MTLRenderPipelineDescriptor* d = (__bridge MTLRenderPipelineDescriptor*)desc;
    d.colorAttachments[index].writeMask = (MTLColorWriteMask)mask;
}

// ============================================================================
// GPU Frame Synchronization
// ============================================================================

/// Add command buffer completion callback (for triple-buffering semaphore sync).
/// Callback signature: void (*)(void* context)
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
// Command buffer error observation
// ============================================================================

/// When command buffer completes with status == Error, invoke callback with error
/// code and description. Previously entire codebase lacked any MTLCommandBufferStatus
/// checks: GPU faults, hangs, device removal all silent, UI freezes with no diagnostics.
/// Callback executes on Metal's completion thread; desc valid only during callback.
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
// GPU execution time (real GPU time, not CPU wall clock)
// ============================================================================

/// Read command buffer's GPU execution start/end time (seconds, CPU time base).
/// **Must be called after command buffer completes** (in completed handler or
/// after waitUntilCompleted); otherwise returns 0.
///
/// This provides what FrameStats.gpu_encode_us cannot: the latter is CPU-side encode+submit wall
/// clock mixed with wait / drawable acquire, whereas GPUStartTime/GPUEndTime give the time the GPU
/// actually spent executing the batch.
/// Availability: macOS 10.15+ / iOS 10.3+.
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

/// Non-blocking query: is command buffer complete (either completed or error counts
/// as terminal). Use to replace 'must wait on GPU for read-back data' with opportunistic
/// reads: skip this frame if not done yet, rather than pin main thread to
/// waitUntilCompleted.
bool metal_command_buffer_is_completed(void* buffer) {
    if (!buffer) return false;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)buffer;
    MTLCommandBufferStatus status = cmd.status;
    return status == MTLCommandBufferStatusCompleted ||
           status == MTLCommandBufferStatusError;
}

// Test-mode GPU ownership probe. No production path calls these helpers.
// The watchdog bounds a failed test's queue stall; probes must verify value is
// still zero before releasing it themselves, otherwise the probe is invalid.
void* metal_test_gate_new(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLSharedEvent> event = [dev newSharedEvent];
    if (!event) return NULL;
    event.signaledValue = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (event.signaledValue == 0) event.signaledValue = 1;
    });
    return (__bridge_retained void*)event;
}
void metal_test_gate_wait(void* buffer, void* event) {
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)buffer;
    [cmd encodeWaitForEvent:(__bridge id<MTLSharedEvent>)event value:1];
}
uint64_t metal_test_gate_value(void* event) {
    return ((__bridge id<MTLSharedEvent>)event).signaledValue;
}
void metal_test_gate_release(void* event) {
    ((__bridge id<MTLSharedEvent>)event).signaledValue = 1;
}

// Borrowed from the drawable; the surface retains its texture separately.
void* metal_drawable_get_texture(void* drawable_ptr) {
    @autoreleasepool {
        id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)drawable_ptr;
        return (__bridge void*)drawable.texture;
    }
}

_Bool metal_device_supports_framebuffer_fetch(void *device) {
    return [(__bridge id<MTLDevice>)device supportsFamily:MTLGPUFamilyApple1];
}

// CPU damage patches (src/render/cpu_flat.zig).
#include "cpu_flat.inc"
