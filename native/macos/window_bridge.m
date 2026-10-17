#include "../window_chrome.h"
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <CoreVideo/CVDisplayLink.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <limits.h>
#include <pthread.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_statistics.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <malloc/malloc.h>
#include <string.h>
#include "pooled_present.inc"
#include "missing_pools_cursor.h"

// RPC acceptance runs keep native windows renderable without taking over the desktop.
static BOOL zenitBackgroundE2E(void) {
    const char *value = getenv("ZENIT_E2E_BACKGROUND");
    return value && strcmp(value, "1") == 0;
}

static NSInteger g_requested_key_window = 0;
static _Atomic uint64_t g_header_updates = 0, g_header_work_updates = 0;
static _Atomic uint64_t g_live_wrappers=0, g_live_windows=0, g_live_metal_views=0;
static _Atomic uint64_t g_loop_updates=0,g_loop_work=0,g_last_loop_updates=0,g_last_loop_work=0,g_max_loop_updates=0;
static _Atomic BOOL g_memory_loop_seen=NO;
static NSHashTable<CAMetalLayer *> *g_body_layers,*g_header_layers;
static BOOL zenitMemoryVMProbeEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{enabled=getenv("ZENIT_MEMORY_VM_PROBE")!=NULL;});
    return enabled;
}
static const char *zenitMemoryMissingPoolsLogPath(void) {
    static char *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value=getenv("ZENIT_MEMORY_MISSING_POOLS_LOG");
        if(value) path=strdup(value);
    });
    return path;
}
static void zenitTrackMetalLayer(CAMetalLayer *layer,BOOL header) {
    if(!zenitMemoryVMProbeEnabled()) return;
    if(header) {if(!g_header_layers) g_header_layers=[NSHashTable weakObjectsHashTable];[g_header_layers addObject:layer];}
    else {if(!g_body_layers) g_body_layers=[NSHashTable weakObjectsHashTable];[g_body_layers addObject:layer];}
}
void zenit_memory_loop_begin(void) {
    if(g_memory_loop_seen) {
        g_last_loop_updates=g_header_updates-g_loop_updates;g_last_loop_work=g_header_work_updates-g_loop_work;
        g_max_loop_updates=MAX(g_max_loop_updates,g_last_loop_updates);
    }
    g_memory_loop_seen=YES;g_loop_updates=g_header_updates;g_loop_work=g_header_work_updates;
}
// Diagnostic sampling is opt-in and never intercepts ObjC ownership operations.
// libobjc's MISSING POOLS record identifies pthread_self(), not the Mach tid.
void zenit_memory_native_stats(uint64_t *out) {
    @autoreleasepool {
        out[0]=g_header_updates;out[1]=g_header_work_updates;out[2]=(uint64_t)pthread_self();
        out[3]=0;out[4]=g_live_wrappers;out[5]=g_live_windows;out[6]=g_live_metal_views;
        out[7]=g_last_loop_updates;out[8]=g_last_loop_work;out[9]=g_max_loop_updates;
        out[15]=g_body_layers.allObjects.count;out[16]=g_header_layers.allObjects.count;
        for(int i=10;i<15;i++) out[i]=0;
        if(zenitMemoryVMProbeEnabled()) {
            struct task_vm_info vm={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
            if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&count)==KERN_SUCCESS && count>=TASK_VM_INFO_REV3_COUNT) {
                out[10]=vm.ledger_tag_graphics_footprint;out[11]=vm.ledger_tag_graphics_footprint_compressed;
            }
            mach_vm_address_t address=0;mach_vm_size_t size=0;natural_t depth=0;
            vm_region_submap_info_data_64_t region;
            while(YES) {
                count=VM_REGION_SUBMAP_INFO_COUNT_64;
                kern_return_t result=mach_vm_region_recurse(mach_task_self(),&address,&size,&depth,(vm_region_recurse_info_t)&region,&count);
                if(result!=KERN_SUCCESS) break;
                if(region.is_submap) {depth++;continue;}
                uint64_t resident=(uint64_t)region.pages_resident*vm_page_size;
                if(region.user_tag==VM_MEMORY_IOSURFACE) out[12]+=resident;
                if(region.user_tag==VM_MEMORY_IOACCELERATOR) out[13]+=resident;
                if(region.user_tag==VM_MEMORY_MALLOC_SMALL) out[14]+=resident;
                if(!size || address+size<=address) break;
                address+=size;
            }
        }
        const char *path=zenitMemoryMissingPoolsLogPath();
        if(path) {
            static _Thread_local ZenitMissingPoolsCursor cursor;
            out[3]=zenitReadMissingPools(&cursor,path,out[2]);
        }
    }
}


// Background e2e must not take over the desktop, but it must still run as a UI
// application. `Prohibited` marks the process non-UI: the kernel then drops
// the main thread - which builds, lays out and encodes every frame - from the
// user-interactive band (pri 46, what any app launched as Regular or Accessory
// gets, even hidden and inactive) to plain timeshare (pri 31). Under load that
// thread loses its core and lands on efficiency cores; md_scroll_perf measured
// every frame phase ~3x slower (render p50 3.6ms -> 11.9ms), i.e. the perf
// gates were timing a scheduling class no shipped app runs in. `Accessory`
// keeps the Dock icon, menu bar and app switcher out of the way exactly like
// `Prohibited`; the app still never activates or orders a window front
// because zenitActivateApplication/zenitPresentWindow skip both here.
static NSApplicationActivationPolicy zenitActivationPolicy(void) {
    return zenitBackgroundE2E() ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular;
}


// All malloc zones, including Tree-sitter/native framework allocations.
// This is a process total and cannot be added to per-owner Zig ledgers.
void zenit_memory_malloc_stats(uint64_t *out) {
    malloc_statistics_t stats = {0};
    malloc_zone_statistics(NULL, &stats);
    out[0] = stats.blocks_in_use; out[1] = stats.size_in_use;
    out[2] = stats.max_size_in_use; out[3] = stats.size_allocated;

}

static void zenitActivateApplication(void) {
    if (!zenitBackgroundE2E()) [NSApp activateIgnoringOtherApps:YES];
}

static void zenitPresentWindow(NSWindow *window) {
    g_requested_key_window = window.windowNumber;
    if (!zenitBackgroundE2E()) [window makeKeyAndOrderFront:nil];
}

@class WindowWrapper;
@interface ZenitFullscreenHeaderHost : NSObject
// Main-thread publication epoch, independent of drawable acquisition.
@property (nonatomic) NSUInteger presentationEpoch;
@property (nonatomic, weak) WindowWrapper *owner;
@property (nonatomic, strong) NSView *header;
@property (nonatomic) CGFloat height;
@property (nonatomic) NSInteger policy;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL exiting;
@property (nonatomic) BOOL locked;
@property (nonatomic) CGFloat bodyReserve;
@property (nonatomic) BOOL bodyReserveCommitted;
@property (nonatomic) BOOL pendingFullscreen;
@property (nonatomic) CFTimeInterval pendingDeadline;
@property (nonatomic) BOOL frameRequested;
@property (nonatomic) BOOL enterWithoutPaint;
- (void)requestFrame;
- (void)completePreparationWithoutPaint:(BOOL)fallback;
- (void)recoverFailedExit;
- (void)start;
- (void)prepare;
- (void)stop;
- (void)quiesceForClose;
- (void)discardClosedPresentation;
- (void)update;
- (void)commitBodyLayout;
- (void)finishExit;
- (void)beginExit;
- (void)encodeTexture:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)buffer revision:(uint64_t)revision;
@end
static WindowWrapper* wrapperForWindow(NSWindow *window);
static BOOL zenitPrepareFullscreen(NSWindow *window);
static BOOL zenitDeferFullscreenUntilDeminiaturized(NSWindow *window,id sender);
static void zenitPrepareFullscreenExit(NSWindow *window);
static NSRect zenitLogicalScreenRect(WindowWrapper *owner,CGFloat x,CGFloat y,CGFloat width,CGFloat height);
static NSPoint zenitLogicalScreenPoint(WindowWrapper *owner,NSPoint screen);
static BOOL zenitLogicalHeaderHidden(WindowWrapper *owner,CGFloat y,CGFloat height);
static BOOL windowCanAcceptPointerInput(WindowWrapper *wrapper);
static BOOL viewCanPresentCursor(NSView *view);
static id<MTLDevice> createBestMetalDevice(void);
static void pumpAppEventsWithTimeout(uint32_t timeout_ms);
void macos_update_window_mouse(void *window_ptr);
void macos_post_empty_event(void);
void macos_ime_discard(void* window_ptr);
static BOOL input_debug_enabled(void) {
    const char *v = getenv("ZENIT_INPUT_DEBUG");
    return v && v[0] != '\0' && v[0] != '0';
}

// Drag debug switch: ZENIT_DEBUG_DRAG=1 logs NSDraggingDestination
// four callbacks (kind 0/1/2/3) to stderr. kind=3 only carries paths.
// Real machine truth (drag file from Finder) is kind=3 appearing.
static BOOL drag_debug_enabled(void) {
    const char *v = getenv("ZENIT_DEBUG_DRAG");
    return v && v[0] != '\0' && v[0] != '0';
}

// ==== IME <-> a11y document text query (NSTextInputClient) ====
//
// NSTextInputClient range/point queries are relative to the focused text box document.
// The bridge holds no text; it pulls from Zig on demand through the a11y bridge
// (zenit_a11y_focused / _value / _text_range_at_point). Forward declared: the impls
// (zenitA11yUTF16OffsetForUTF8 etc) live in the a11y node, after MetalView.
// AX element identity matches Zig a11y.tree.AXId.raw() (64-bit {payload, kind}). Node handle is
// value-equal to ElementId zero-extended; collection items use a separate kind namespace.
typedef uint64_t ZenitAXHandle;
static uint32_t zenitA11yWindowIdForView(NSView *view);
static NSString *zenitA11yCopyString(int (*fetch)(uint32_t, ZenitAXHandle, char *, int),
                                     uint32_t window_id, ZenitAXHandle handle);
static NSUInteger zenitA11yUTF16OffsetForUTF8(NSString *text, uint32_t utf8Offset);
static NSString *zenitA11yStringFromUTF8(const void *bytes, NSUInteger len);
static uint32_t zenitA11yUTF8OffsetForUTF16(NSString *text, NSUInteger utf16Offset);
extern ZenitAXHandle zenit_a11y_focused(uint32_t window_id);
extern int zenit_a11y_value(uint32_t window_id, ZenitAXHandle handle, char *buf, int buf_len);
extern int zenit_a11y_text_selection(uint32_t window_id, ZenitAXHandle handle, uint32_t *start, uint32_t *end, uint32_t *caret);
extern int zenit_a11y_text_range_at_point(uint32_t window_id, ZenitAXHandle handle, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8);
extern uint64_t zenit_text_input_length(uint32_t window_id);
extern int zenit_text_input_copy(uint32_t window_id, uint64_t start_utf8, char *buf, int buf_len);
extern int zenit_text_input_selection(uint32_t window_id, uint32_t *start, uint32_t *end, uint32_t *caret);
extern int zenit_text_input_frame(uint32_t window_id, uint32_t start_utf8, uint32_t end_utf8, float *x, float *y, float *width, float *height);
extern int zenit_text_input_range_at_point(uint32_t window_id, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8);
extern uint64_t zenit_text_input_utf16_for_utf8(uint32_t window_id, uint64_t utf8_offset);
extern uint64_t zenit_text_input_utf8_for_utf16(uint32_t window_id, uint64_t utf16_offset);
#define ZENIT_IME_NO_REPLACEMENT ((uint32_t)0xFFFFFFFFu)
#define ZENIT_TEXT_OFFSET_INVALID ((uint64_t)UINT64_MAX)
#define ZENIT_MAX_IME_PREEDIT_QUEUE ((NSUInteger)256)
#define ZENIT_MOUSE_MOVE_SOFT_LIMIT ((NSUInteger)256)

static unsigned long long g_ime_preedit_coalesced_count = 0;
static unsigned long long g_mouse_move_coalesced_count = 0;
// Coalesce wakeups within one native pump. IMK can call the client from a
// run-loop source while nextEventMatchingMask is blocked with no NSEvent to
// return. Queuing text alone does not wake that wait.
static BOOL g_text_input_wake_posted = NO;
// CVDisplayLink wake coalescing. The link thread fires every vsync, but the
// pump consumes at most one application-defined event per iteration; when the
// app renders slower than the refresh rate the wake events used to pile up in
// the NSApp queue without bound (measured 116 queued after 3s). At most one
// display-link wake is kept in flight: set when posting, cleared when the pump
// dequeues an application-defined event and at every pump entry (so a wake
// swallowed by a nested/modal run loop can never wedge the link).
static atomic_bool g_display_link_wake_pending = false;

static unsigned long long nextInputEventSequence(void);

/// Text payloads cannot live in an NSValue C struct. Keep the payload and the
/// native dispatch sequence together so text/IME queues can join the same
/// ordered stream as key and pointer input.
@interface ZenitTextEventPacket : NSObject
@property (nonatomic) unsigned long long sequence;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSData *utf8Data;
@property (nonatomic) uint32_t cursorUtf16;
@property (nonatomic) uint32_t replaceStartUtf8;
@property (nonatomic) uint32_t replaceEndUtf8;
@end

@implementation ZenitTextEventPacket
@end

static ZenitTextEventPacket *zenitTextEventPacket(NSString *text,
                                                   uint32_t cursor_utf16,
                                                   uint32_t replace_start_utf8,
                                                   uint32_t replace_end_utf8) {
    ZenitTextEventPacket *packet = [[ZenitTextEventPacket alloc] init];
    packet.sequence = nextInputEventSequence();
    packet.text = text ?: @"";
    packet.cursorUtf16 = cursor_utf16;
    packet.replaceStartUtf8 = replace_start_utf8;
    packet.replaceEndUtf8 = replace_end_utf8;
    if (!g_text_input_wake_posted) {
        g_text_input_wake_posted = YES;
        macos_post_empty_event();
    }
    return packet;
}

static void zenitEnqueueInputText(id wrapper, NSString *text) {
    NSMutableArray<ZenitTextEventPacket *> *queue = [wrapper valueForKey:@"inputTextQueue"];
    if (queue) {
        [queue addObject:zenitTextEventPacket(text, 0,
                                              ZENIT_IME_NO_REPLACEMENT,
                                              ZENIT_IME_NO_REPLACEMENT)];
    } else {
        [wrapper setValue:text forKey:@"inputText"];
    }
}

static void zenitEnqueueImePreedit(id wrapper, NSString *text,
                                   uint32_t cursor_utf16,
                                   uint32_t replace_start_utf8,
                                   uint32_t replace_end_utf8) {
    NSString *value = text ?: @"";
    [wrapper setValue:value forKey:@"imePreeditText"];
    [wrapper setValue:@(cursor_utf16) forKey:@"imePreeditCursorUtf16"];
    [wrapper setValue:@(replace_start_utf8) forKey:@"imePreeditReplaceStartUtf8"];
    [wrapper setValue:@(replace_end_utf8) forKey:@"imePreeditReplaceEndUtf8"];
    [wrapper setValue:@(YES) forKey:@"hasImePreedit"];

    NSMutableArray<ZenitTextEventPacket *> *queue = [wrapper valueForKey:@"imePreeditQueue"];
    if (queue) {
        if (queue.count >= ZENIT_MAX_IME_PREEDIT_QUEUE) {
            // Preedit packets are successive composition snapshots. Under
            // extreme back-pressure preserve the oldest transitions and the
            // newest state by replacing only the previous tail snapshot.
            [queue removeLastObject];
            g_ime_preedit_coalesced_count += 1;
            if (input_debug_enabled()) {
                NSLog(@"[bridge-input] preedit queue pressure: coalesced tail at %lu packets",
                      (unsigned long)ZENIT_MAX_IME_PREEDIT_QUEUE);
            }
        }
        [queue addObject:zenitTextEventPacket(value, cursor_utf16,
                                              replace_start_utf8,
                                              replace_end_utf8)];
    }
}

static void zenitEnqueueImeCommit(id wrapper, NSString *text,
                                  uint32_t replace_start_utf8,
                                  uint32_t replace_end_utf8) {
    NSMutableArray<ZenitTextEventPacket *> *queue = [wrapper valueForKey:@"imeCommitQueue"];
    if (queue) {
        [queue addObject:zenitTextEventPacket(text, 0,
                                              replace_start_utf8,
                                              replace_end_utf8)];
    } else {
        [wrapper setValue:text forKey:@"imeCommitText"];
        [wrapper setValue:@(replace_start_utf8) forKey:@"imeCommitReplaceStartUtf8"];
        [wrapper setValue:@(replace_end_utf8) forKey:@"imeCommitReplaceEndUtf8"];
    }
    [wrapper setValue:@(YES) forKey:@"hasImeCommit"];
}

// replacementRange (UTF-16, relative document) -> UTF-8 byte
// range. Query live TextInputClient directly, not dependent on last
// render's a11y snapshot.
static BOOL zenitImeConvertReplacementRange(NSView *view, NSRange range,
                                            uint32_t *out_start, uint32_t *out_end) {
    *out_start = ZENIT_IME_NO_REPLACEMENT;
    *out_end = ZENIT_IME_NO_REPLACEMENT;
    if (range.location == NSNotFound) return YES;
    if (range.length > NSUIntegerMax - range.location) return NO;
    const NSUInteger end16 = range.location + range.length;
    const uint32_t wid = zenitA11yWindowIdForView(view);
    const uint64_t start = zenit_text_input_utf8_for_utf16(wid, range.location);
    const uint64_t end = zenit_text_input_utf8_for_utf16(wid, end16);
    if (start == ZENIT_TEXT_OFFSET_INVALID || end == ZENIT_TEXT_OFFSET_INVALID ||
        start >= ZENIT_IME_NO_REPLACEMENT || end >= ZENIT_IME_NO_REPLACEMENT || start > end) return NO;
    // General text queries clamp out-of-bounds and split-surrogate offsets.
    // A replacement must be exact: never turn a stale range into insertion
    // at EOF or silently replace a different Unicode scalar.
    const uint64_t recovered_start16 = zenit_text_input_utf16_for_utf8(wid, start);
    const uint64_t recovered_end16 = zenit_text_input_utf16_for_utf8(wid, end);
    if (recovered_start16 == ZENIT_TEXT_OFFSET_INVALID || recovered_end16 == ZENIT_TEXT_OFFSET_INVALID ||
        recovered_start16 != range.location || recovered_end16 != end16) return NO;
    *out_start = (uint32_t)start;
    *out_end = (uint32_t)end;
    return YES;
}

static NSRange zenitImeLiveSelectedRange(NSView *view) {
    const uint32_t wid = zenitA11yWindowIdForView(view);
    uint32_t start = 0, end = 0, caret = 0;
    if (!zenit_text_input_selection(wid, &start, &end, &caret)) return NSMakeRange(NSNotFound, 0);
    const uint64_t start16 = zenit_text_input_utf16_for_utf8(wid, start);
    const uint64_t end16 = zenit_text_input_utf16_for_utf8(wid, end);
    if (start16 == ZENIT_TEXT_OFFSET_INVALID || end16 == ZENIT_TEXT_OFFSET_INVALID ||
        start16 > NSUIntegerMax || end16 > NSUIntegerMax) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange((NSUInteger)MIN(start16, end16), (NSUInteger)(MAX(start16, end16) - MIN(start16, end16)));
}

static NSAttributedString *zenitImeCopyAttributedRange(NSView *view, NSRange range, NSRangePointer actualRange) {
    if (actualRange) *actualRange = NSMakeRange(NSNotFound, 0);
    if (range.location == NSNotFound) return nil;
    const uint32_t wid = zenitA11yWindowIdForView(view);
    const uint64_t start = zenit_text_input_utf8_for_utf16(wid, range.location);
    const uint64_t end = zenit_text_input_utf8_for_utf16(wid, NSMaxRange(range));
    if (start == ZENIT_TEXT_OFFSET_INVALID || end == ZENIT_TEXT_OFFSET_INVALID || end < start) return nil;
    const uint64_t byteLength = end - start;
    if (byteLength > INT_MAX) return nil;
    if (byteLength == 0) {
        if (actualRange) *actualRange = NSMakeRange(range.location, 0);
        return [[NSAttributedString alloc] initWithString:@""];
    }
    char *bytes = malloc((size_t)byteLength);
    if (!bytes) return nil;
    const int copied = zenit_text_input_copy(wid, start, bytes, (int)byteLength);
    if (copied != (int)byteLength) {
        free(bytes);
        return nil;
    }
    // Use the copying initializer and keep ownership explicit. The failure
    // ownership semantics of initWithBytesNoCopy:...freeWhenDone: are easy to
    // get wrong and used to leave a possible double-free edge here.
    // BOM-preserving: actualRange below is computed from raw UTF-8 offsets.
    NSString *text = zenitA11yStringFromUTF8(bytes, (NSUInteger)byteLength);
    free(bytes);
    if (!text) return nil;
    const uint64_t actualStart16 = zenit_text_input_utf16_for_utf8(wid, start);
    const uint64_t actualEnd16 = zenit_text_input_utf16_for_utf8(wid, end);
    if (actualRange && actualStart16 != ZENIT_TEXT_OFFSET_INVALID &&
        actualEnd16 != ZENIT_TEXT_OFFSET_INVALID && actualEnd16 >= actualStart16) {
        *actualRange = NSMakeRange((NSUInteger)actualStart16,
                                   (NSUInteger)(actualEnd16 - actualStart16));
    }
    return [[NSAttributedString alloc] initWithString:text];
}

static id<MTLDevice> createBestMetalDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
        return device;
    }

#if TARGET_OS_OSX
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    if (devices.count == 0) {
        NSLog(@"[MetalView] MTLCreateSystemDefaultDevice returned nil and MTLCopyAllDevices found 0 devices");
        return nil;
    }

    id<MTLDevice> preferred = nil;
    for (id<MTLDevice> candidate in devices) {
        if (!preferred) preferred = candidate;
        if ([candidate respondsToSelector:@selector(isLowPower)] && !candidate.isLowPower) {
            preferred = candidate;
            break;
        }
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:devices.count];
    for (id<MTLDevice> candidate in devices) {
        [names addObject:candidate.name ?: @"(unnamed)"];
    }
    NSLog(@"[MetalView] Falling back to MTLCopyAllDevices (%lu found): %@; selected %@",
          (unsigned long)devices.count,
          [names componentsJoinedByString:@", "],
          preferred.name);
    return preferred;
#else
    return nil;
#endif
}

// Background (off-screen) e2e only: ZENIT_RENDER_SCALE renders at a higher
// backing scale than the screen provides, e.g. 3 for 4K demo recordings of a
// 1280x800pt window. Ignored on-screen, where the layer must match the display.
static CGFloat zenitRenderScaleOverride(void) {
    if (!zenitBackgroundE2E()) return 0;
    const char *value = getenv("ZENIT_RENDER_SCALE");
    if (!value) return 0;
    double scale = atof(value);
    return (scale >= 1.0 && scale <= 4.0) ? (CGFloat)scale : 0;
}

static CGFloat currentScreenScale(NSWindow *window) {
    CGFloat forced = zenitRenderScaleOverride();
    if (forced > 0) return forced;
    NSScreen *screen = nil;
    if (window) {
        screen = window.screen;
    }
    if (!screen) {
        screen = [NSScreen mainScreen];
    }
    if (!screen) {
        NSArray<NSScreen *> *screens = [NSScreen screens];
        if (screens.count > 0) {
            screen = screens.firstObject;
        }
    }
    return screen ? screen.backingScaleFactor : 1.0;
}

static BOOL isPointerEventType(NSEventType type) {
    switch (type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseDown:
        case NSEventTypeOtherMouseUp:
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged:
        case NSEventTypeScrollWheel:
        case NSEventTypeMagnify:
            return YES;
        default:
            return NO;
    }
}

// Metal view - continue rendering during live resize
typedef void (*RenderCallback)(void* ctx);
static NSString * const ZenitInternalDragType = @"dev.zenit.internal-drag";

@interface MetalView : NSView <NSTextInputClient, NSDraggingSource>
@property (nonatomic, strong) NSCursor *zenitDesiredCursor;
@property (nonatomic, strong) NSTrackingArea *zenitCursorTrackingArea;
- (void)presentDesiredCursor;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
// A custom NSTextInputClient owns one context. Keeping it explicit lets an
// input-source transition replace a stale InputMethodKit conversion session.
@property (nonatomic, strong) NSTextInputContext *zenitInputContext;
@property (nonatomic, assign) RenderCallback renderCallback;
@property (nonatomic, assign) void* renderContext;
// During live resize AppKit runs in own tracking loop, app main
// loop doesn't; only setFrameSize: triggers render, drag pause leaves
// no frame - all animations freeze. Ticker runs on
// NSRunLoopCommonModes (includes tracking) to drive render; Zig gates
// on wantsFrame, static content doesn't redraw.
@property (nonatomic, strong) NSTimer *liveResizeTicker;
- (void)renderFinalResize;
@property (nonatomic, strong) NSMutableAttributedString *markedTextStorage;
@property (nonatomic, assign) BOOL discardingMarkedText;
- (void)discardMarkedTextFromInputContext;
@property (nonatomic, assign) NSRange markedTextSelectedRange;
// NSTextInputClient ranges are UTF-16 offsets in the complete client document,
// not offsets local to the marked string.
@property (nonatomic, assign) NSRange markedDocumentRange;
// Drag event queue: kind 0..3 = destination, 4 = source completion.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *dragEventQueue;
@property (nonatomic, strong) NSOperationQueue *filePromiseQueue;
@property (nonatomic, assign) BOOL zenitDragSessionActive;
@property (nonatomic, assign) uint64_t zenitDragToken;
@property (nonatomic, assign) NSDragOperation zenitDragAllowedOperations;
@property (nonatomic, assign) NSDragOperation zenitDropAllowedOperations;
// AppKit requires the vendor of virtual NSAccessibilityElement objects to
// retain them for as long as the represented UI exists.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *zenitA11yElementCache;
// Per-window pending LayoutChanged targets this flush
// (deduplicated by object identity). Attached to host view, cohabits
// element cache: windows don't interfere, destroy releases with it.
@property (nonatomic, strong) NSMutableArray *zenitA11yPendingLayoutTargets;
- (id)zenitA11yElementForHandle:(ZenitAXHandle)handle accessibilityParent:(id)parent;
- (id)zenitA11yElementForHandle:(ZenitAXHandle)handle;
@end

@implementation MetalView
- (void)dealloc { atomic_fetch_sub_explicit(&g_live_metal_views,1,memory_order_relaxed); }

- (NSTextInputContext *)inputContext {
    if (!_zenitInputContext) {
        _zenitInputContext = [[NSTextInputContext alloc] initWithClient:self];
    }
    return _zenitInputContext;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        atomic_fetch_add_explicit(&g_live_metal_views,1,memory_order_relaxed);
        // Create Metal device
        self.device = createBestMetalDevice();
        if (!self.device) {
            NSLog(@"[MetalView] Metal device creation failed (mainThread=%@, screen=%@)",
                  [NSThread isMainThread] ? @"YES" : @"NO",
                  [NSScreen mainScreen]);
            return nil;
        }

        // Drag: receive file/image/URL drag (Finder, browser)
        self.dragEventQueue = [NSMutableArray array];
        self.zenitDropAllowedOperations = NSDragOperationCopy;
        self.filePromiseQueue = [[NSOperationQueue alloc] init];
        self.filePromiseQueue.name = @"dev.zenit.file-promises";
        self.filePromiseQueue.maxConcurrentOperationCount = 2;
        NSMutableArray<NSPasteboardType> *dragTypes = [NSMutableArray arrayWithArray:@[
            NSPasteboardTypeFileURL,
            NSPasteboardTypeURL,
            NSPasteboardTypeString,
            ZenitInternalDragType,
        ]];
        [dragTypes addObjectsFromArray:NSFilePromiseReceiver.readableDraggedTypes];
        [self registerForDraggedTypes:dragTypes];

        // Create Metal layer and set as view's layer
        self.wantsLayer = YES;
        // Critical: during live resize don't scale old content, allow
        // continuous redraw
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

        CAMetalLayer *layer = [CAMetalLayer layer];
        zenitTrackMetalLayer(layer,NO);
        layer.device = self.device;
        // Blending on sRGB encoded values, consistent with
        // AppKit/Core Animation (docs/SRGB_BLENDING_PLAN.md): non-_sRGB
        // format + explicit sRGB colorspace (omit = sRGB values treated as
        // P3 native on P3 screen).
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        CGColorSpaceRef srgb_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        layer.colorspace = srgb_space;
        CGColorSpaceRelease(srgb_space);

        // Performance optimization (reference wgpu-hal surface.rs) initial
        // value; Surface.configure overrides by usage. App uses
        // color_target_and_read (framebufferOnly = NO): glass reads drawable
        // backdrop, framebufferOnly can't blit-source or sample.
        layer.framebufferOnly = YES;

        // Prevents drawable timeout blocking (fixes black screen while dragging). Reference:
        // https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-hal/src/metal/surface.rs#L101-104
        //
        // WARNING: do not change to YES. With timeouts allowed, heavy-blur scenes (storybook
        // glasslab)
        // repeatedly eat the ~1s timeout and skip frames. Full rationale in the same-name config
        // comment in src/gpu/metal/surface.zig.
        if (@available(macOS 10.13, *)) {
            layer.allowsNextDrawableTimeout = NO;
        }

        // Control framebuffer queue depth (typical 2-3)
        layer.maximumDrawableCount = 3;

        // Enable VSync (smooth rendering)
        if (@available(macOS 10.13, *)) {
            layer.displaySyncEnabled = YES;
        }

        CGSize drawableSize = frameRect.size;
        CGFloat scale = currentScreenScale(nil);
        layer.contentsScale=scale;
        drawableSize.width *= scale;
        drawableSize.height *= scale;
        layer.drawableSize = drawableSize;

        self.layer = layer;
        self.metalLayer = layer;
        self.renderCallback = NULL;
        self.renderContext = NULL;
        self.markedTextStorage = [[NSMutableAttributedString alloc] initWithString:@""];
        self.markedTextSelectedRange = NSMakeRange(0, 0);
        self.markedDocumentRange = NSMakeRange(NSNotFound, 0);
        self.zenitA11yElementCache = [NSMutableDictionary dictionary];

        NSLog(@"[MetalView] Initialized with device: %@, drawable: %.0fx%.0f",
              self.device.name, drawableSize.width, drawableSize.height);
    }
    return self;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];

    if (self.inLiveResize) {
        NSRect wf = self.window.frame;
        NSLog(@"[resize] window frame: origin=(%.1f, %.1f) size=(%.1f x %.1f) view=(%.1f x %.1f)",
              wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
              newSize.width, newSize.height);
    }

    // Update Metal layer size
    CGSize drawableSize = self.bounds.size;
    CGFloat scale = currentScreenScale(self.window);
    drawableSize.width *= scale;
    drawableSize.height *= scale;
    self.metalLayer.contentsScale=scale;
    if (!CGSizeEqualToSize(self.metalLayer.drawableSize,drawableSize))
        self.metalLayer.drawableSize = drawableSize;

    // Direct render callback invocation, not drawRect-dependent
    // (layer-backed view doesn't trigger drawRect)
    if (self.inLiveResize && self.renderCallback != NULL) {
        self.renderCallback(self.renderContext);
    }
}

- (void)renderFinalResize {
    [CATransaction begin];[CATransaction setDisableActions:YES];
    BOOL transactional=self.metalLayer.presentsWithTransaction;
    self.metalLayer.presentsWithTransaction=YES;
    [self setFrameSize:self.frame.size];
    if(!self.inLiveResize && self.renderCallback) self.renderCallback(self.renderContext);
    self.metalLayer.presentsWithTransaction=transactional;
    [CATransaction commit];
}

- (void)viewWillStartLiveResize {
    [super viewWillStartLiveResize];
    // Critical: enable sync present during resize, prevent
    // CoreAnimation from stretching old frame
    self.metalLayer.presentsWithTransaction = YES;

    [self.liveResizeTicker invalidate];
    NSTimeInterval interval = 1.0 / 60.0;
    NSScreen *screen = self.window.screen;
    if (@available(macOS 12.0, *)) {
        if (screen.maximumFramesPerSecond > 0) interval = 1.0 / (NSTimeInterval)screen.maximumFramesPerSecond;
    }
    __weak MetalView *weakSelf = self;
    NSTimer *ticker = [NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *timer) {
        MetalView *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.inLiveResize) {
            [timer invalidate];
            return;
        }
        if (strongSelf.renderCallback != NULL) strongSelf.renderCallback(strongSelf.renderContext);
    }];
    [[NSRunLoop currentRunLoop] addTimer:ticker forMode:NSRunLoopCommonModes];
    self.liveResizeTicker = ticker;
}

- (void)viewDidEndLiveResize {
    [super viewDidEndLiveResize];
    [self.liveResizeTicker invalidate];
    self.liveResizeTicker = nil;

    // Restore async present (one-frame delayed, ensures final frame
    // syncs). Use weak reference to avoid block accessing released object
    // after close.
    __weak MetalView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MetalView *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.metalLayer.presentsWithTransaction = NO;

            // setFrameSize: callback in AppKit live-resize tracking loop.
            // Retained UI outer layout and child components depending on rect
            // differ by one layout pass; after final resize without new input, no
            // next frame consumes final bounds, screen stays at penultimate size
            // until hover/click. Back to main queue, bounds committed, directly
            // flush final frame (post-empty-event won't mark WindowContext
            // needs_redraw, insufficient).
            [strongSelf renderFinalResize];
        }
    });
}

- (BOOL)preservesContentDuringLiveResize {
    // Don't allow system to scale old content, avoid scale-then-
    // recover visual.
    return NO;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.zenitCursorTrackingArea) [self removeTrackingArea:self.zenitCursorTrackingArea];
    self.zenitCursorTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
        options:NSTrackingCursorUpdate | NSTrackingInVisibleRect | NSTrackingActiveInActiveApp
        owner:self userInfo:nil];
    [self addTrackingArea:self.zenitCursorTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSMenuDidEndTrackingNotification object:nil];
    if (self.window) [center addObserver:self selector:@selector(zenitMenuTrackingEnded:)
        name:NSMenuDidEndTrackingNotification object:nil];
}

- (void)zenitMenuTrackingEnded:(NSNotification *)notification {
    (void)notification;
    // AppKit restores its own cursor after posting the tracking-end notification.
    // Run afterwards; recheck native ownership then, never capture eligibility
    // from before the menu or require an unrelated mouse move/focus change.
    __weak MetalView *weakSelf = self;
    [NSRunLoop.mainRunLoop performInModes:@[NSDefaultRunLoopMode]
        block:^{ [weakSelf presentDesiredCursor]; }];
}

- (void)presentDesiredCursor {
    const BOOL eligible = self.zenitDesiredCursor && viewCanPresentCursor(self);
    if (eligible) [self.zenitDesiredCursor set];
    const char *debug = getenv("ZENIT_CURSOR_DEBUG");
    if (debug && debug[0] && debug[0] != '0') {
        NSLog(@"[cursor-native] window=%ld desired=%@ status=%@", (long)self.window.windowNumber,
              self.zenitDesiredCursor, !self.zenitDesiredCursor ? @"handoff" : eligible ? @"applied" : @"deferred");
    }
}

// AppKit requests restoration after menus, native subviews and window changes.
// This is independent of the framework's logical-shape equality fast path.
- (void)cursorUpdate:(NSEvent *)event {
    (void)event;
    [self presentDesiredCursor];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

// NSView default returns YES for non-opaque, so
// movableByWindowBackground turns mouseDown on background into drag.
// But zenit controls all Metal-rendered on this view, no NSView
// subviews - AppKit doesn't know if pointer over input, treats whole
// panel as background, press-drag in input becomes window drag, text
// unselectable. Handled by titlebarDragHeight +
// titlebarHitCallback: calls Zig for real hit-test, events on control
// normal, space-only drags window.
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)becomeFirstResponder {
    // AppKit activates the NSTextInputContext when an NSTextInputClient becomes
    // first responder in the key window. Calling activate directly is outside
    // the public lifecycle contract and can synchronously stall in InputMethodKit.
    return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
    return [super resignFirstResponder];
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *text = nil;
    if ([string isKindOfClass:[NSAttributedString class]]) {
        text = [(NSAttributedString*)string string];
    } else if ([string isKindOfClass:[NSString class]]) {
        text = (NSString*)string;
    }
    if (!text || (text.length == 0 && replacementRange.location == NSNotFound)) {
        if (input_debug_enabled()) {
            NSLog(@"[bridge-input] insertText ignored empty text without replacement");
        }
        return;
    }

    id wrapper = wrapperForWindow(self.window);
    if (!wrapper || [[wrapper valueForKey:@"keyboardIsolated"] boolValue] ||
        ![[wrapper valueForKey:@"textInputEnabled"] boolValue]) {
        if (input_debug_enabled()) {
            NSLog(@"[bridge-input] insertText ignored without active text editor");
        }
        return;
    }

    // Validate before publishing dedupe state or clearing native marked text.
    uint32_t replace_start_utf8, replace_end_utf8;
    if (!zenitImeConvertReplacementRange(self, replacementRange, &replace_start_utf8, &replace_end_utf8)) return;
    const BOOL hasReplacement = replace_start_utf8 != ZENIT_IME_NO_REPLACEMENT;

    const BOOL hadMarkedText = self.markedTextStorage.length > 0;
    NSString *text_copy = [text copy];
    const unsigned long long keyDispatchSeq = [[wrapper valueForKey:@"keyDispatchSeq"] unsignedLongLongValue];
    const unsigned long long lastInsertKeyDispatchSeq = [[wrapper valueForKey:@"lastInsertKeyDispatchSeq"] unsignedLongLongValue];
    NSString *lastInsertText = [wrapper valueForKey:@"lastInsertText"];
    const BOOL lastInsertHadMarked = [[wrapper valueForKey:@"lastInsertHadMarked"] boolValue];
    const BOOL isSpaceText = [text_copy isEqualToString:@" "] || [text_copy isEqualToString:@"　"];
    if (keyDispatchSeq != 0 &&
        keyDispatchSeq == lastInsertKeyDispatchSeq &&
        lastInsertHadMarked &&
        !hadMarkedText &&
        isSpaceText) {
        if (input_debug_enabled()) {
            NSLog(@"[bridge-input] suppress post-commit space text=\"%@\" keySeq=%llu", text_copy, keyDispatchSeq);
        }
        return;
    }
    if (keyDispatchSeq != 0 &&
        keyDispatchSeq == lastInsertKeyDispatchSeq &&
        lastInsertText &&
        [lastInsertText isEqualToString:text_copy] &&
        lastInsertHadMarked == hadMarkedText) {
        if (input_debug_enabled()) {
            NSLog(@"[bridge-input] dedupe insertText text=\"%@\" keySeq=%llu", text_copy, keyDispatchSeq);
        }
        return;
    }
    [wrapper setValue:@(keyDispatchSeq) forKey:@"lastInsertKeyDispatchSeq"];
    [wrapper setValue:text_copy forKey:@"lastInsertText"];
    [wrapper setValue:@(hadMarkedText) forKey:@"lastInsertHadMarked"];

    if (input_debug_enabled()) {
        NSUInteger utf8len = [text_copy lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSLog(@"[ime-debug] insertText text=\"%@\" utf8len=%lu hadMarked=%d keySeq=%llu",
              text_copy, (unsigned long)utf8len, hadMarkedText ? 1 : 0, keyDispatchSeq);
    }

    if (input_debug_enabled()) {
        NSLog(@"[bridge-input] insertText wrapper=%p text=\"%@\" hadMarked=%d keySeq=%llu",
              wrapper, text_copy, hadMarkedText ? 1 : 0, keyDispatchSeq);
    }

    // An explicit range was resolved against the current document, including
    // any projected marked text. Clearing that projection first invalidates
    // its coordinates. Commit replaces it directly and ends the composition.
    // Keep the legacy clear-before-input order for implicit commits so their
    // post-commit duplicate guard is established after the composition end.
    if (!hasReplacement) {
        zenitEnqueueImePreedit(wrapper, @"", 0,
                               ZENIT_IME_NO_REPLACEMENT,
                               ZENIT_IME_NO_REPLACEMENT);
    }
    if (hadMarkedText || hasReplacement) {
        // A direct insertText with a replacement range (a reconversion commit
        // without marked text) also goes through the commit channel - text_input
        // events have no replacement semantics.
        zenitEnqueueImeCommit(wrapper, text_copy,
                              replace_start_utf8,
                              replace_end_utf8);
    } else {
        zenitEnqueueInputText(wrapper, text_copy);
    }
    if (input_debug_enabled()) {
        NSMutableArray<ZenitTextEventPacket *> *inputQueue = [wrapper valueForKey:@"inputTextQueue"];
        NSMutableArray<ZenitTextEventPacket *> *commitQueue = [wrapper valueForKey:@"imeCommitQueue"];
        NSString *dbgInput = inputQueue.count > 0 ? inputQueue.lastObject.text : [wrapper valueForKey:@"inputText"];
        NSString *dbgCommit = commitQueue.count > 0 ? commitQueue.lastObject.text : [wrapper valueForKey:@"imeCommitText"];
        NSLog(@"[bridge-input] after insert input=\"%@\" inputQ=%lu commit=\"%@\" commitQ=%lu",
              dbgInput ?: @"<nil>",
              (unsigned long)inputQueue.count,
              dbgCommit ?: @"<nil>",
              (unsigned long)commitQueue.count);
    }

    [self.markedTextStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    self.markedTextSelectedRange = NSMakeRange(0, 0);
    self.markedDocumentRange = NSMakeRange(NSNotFound, 0);
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    NSString *text = nil;
    if ([string isKindOfClass:[NSAttributedString class]]) {
        text = [(NSAttributedString*)string string];
    } else if ([string isKindOfClass:[NSString class]]) {
        text = (NSString*)string;
    }
    if (!text) text = @"";
    id wrapper = wrapperForWindow(self.window);
    if (!wrapper || [[wrapper valueForKey:@"keyboardIsolated"] boolValue] ||
        ![[wrapper valueForKey:@"textInputEnabled"] boolValue]) {
        if (input_debug_enabled()) {
            NSLog(@"[bridge-input] setMarkedText ignored without active text editor");
        }
        return;
    }
    if (input_debug_enabled()) {
        NSLog(@"[bridge-input] setMarkedText text=\"%@\" sel=(%lu,%lu)",
              text,
              (unsigned long)selectedRange.location,
              (unsigned long)selectedRange.length);
    }

    // Failed reconversion must leave both native and editor composition intact.
    uint32_t replace_start_utf8, replace_end_utf8;
    if (!zenitImeConvertReplacementRange(self, replacementRange, &replace_start_utf8, &replace_end_utf8)) return;

    // A candidate or explicit replacement can arrive without a new keyDown.
    // It starts a new insertion identity; an implicit empty update is only
    // cleanup and must preserve same-key post-commit duplicate/space guards.
    if (text.length > 0 || replace_start_utf8 != ZENIT_IME_NO_REPLACEMENT) {
        [wrapper setValue:@0 forKey:@"lastInsertKeyDispatchSeq"];
        [wrapper setValue:nil forKey:@"lastInsertText"];
        [wrapper setValue:@NO forKey:@"lastInsertHadMarked"];
    }

    const BOOL wasMarked = self.markedTextStorage.length > 0 &&
                           self.markedDocumentRange.location != NSNotFound;
    NSString *text_copy = [text copy];

    // Establish the marked range in document coordinates on the first preedit
    // update. Subsequent snapshots retain the same insertion origin while the
    // marked text's UTF-16 length changes.
    NSUInteger markedLocation = self.markedDocumentRange.location;
    if (replacementRange.location != NSNotFound) {
        markedLocation = replacementRange.location;
    } else if (!wasMarked) {
        const NSRange selection = zenitImeLiveSelectedRange(self);
        markedLocation = selection.location == NSNotFound ? 0 : selection.location;
    }
    [self.markedTextStorage setAttributedString:[[NSAttributedString alloc] initWithString:text_copy]];
    self.markedTextSelectedRange = selectedRange;
    self.markedDocumentRange = NSMakeRange(markedLocation, text_copy.length);

    NSUInteger caret_utf16 = selectedRange.location;
    if (selectedRange.length > 0) {
        const NSUInteger max_range = NSMaxRange(selectedRange);
        caret_utf16 = max_range;
    }
    if (caret_utf16 > text_copy.length) caret_utf16 = text_copy.length;
    zenitEnqueueImePreedit(wrapper, text_copy, (uint32_t)caret_utf16,
                           replace_start_utf8, replace_end_utf8);
}

- (void)discardMarkedTextFromInputContext {
    // AppKit may synchronously call unmarkText from discardMarkedText.
    // Explicit SDK cancellation must not turn that callback into a commit.
    const BOOL previous = self.discardingMarkedText;
    self.discardingMarkedText = YES;
    @try {
        [[self inputContext] discardMarkedText];
    } @finally {
        self.discardingMarkedText = previous;
    }
}

- (void)unmarkText {
    if (input_debug_enabled()) {
        NSLog(@"[bridge-input] unmarkText");
    }
    NSString *accepted = [self.markedTextStorage.string copy];
    [self.markedTextStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    self.markedTextSelectedRange = NSMakeRange(0, 0);
    self.markedDocumentRange = NSMakeRange(NSNotFound, 0);
    id wrapper = wrapperForWindow(self.window);
    if (!wrapper || accepted.length == 0) return;
    if (self.discardingMarkedText) {
        zenitEnqueueImePreedit(wrapper, @"", 0,
                               ZENIT_IME_NO_REPLACEMENT,
                               ZENIT_IME_NO_REPLACEMENT);
    } else {
        // NSTextInputClient unmarkText accepts the marked text as normal
        // input. The editor already owns its projection; commit replaces that
        // projection once and closes its undo group without deleting it.
        zenitEnqueueImeCommit(wrapper, accepted,
                              ZENIT_IME_NO_REPLACEMENT,
                              ZENIT_IME_NO_REPLACEMENT);
    }
}

- (BOOL)hasMarkedText {
    return self.markedTextStorage.length > 0;
}

- (NSRange)markedRange {
    if (self.markedTextStorage.length == 0) {
        return NSMakeRange(NSNotFound, 0);
    }
    return self.markedDocumentRange;
}

- (NSRange)selectedRange {
    if (self.markedTextStorage.length > 0 && self.markedDocumentRange.location != NSNotFound) {
        const NSUInteger localLocation = MIN(self.markedTextSelectedRange.location,
                                             self.markedTextStorage.length);
        const NSUInteger localEnd = MIN(NSMaxRange(self.markedTextSelectedRange),
                                        self.markedTextStorage.length);
        return NSMakeRange(self.markedDocumentRange.location + localLocation,
                           localEnd - localLocation);
    }

    return zenitImeLiveSelectedRange(self);
}

- (void)doCommandBySelector:(SEL)selector {
    // Key commands handled by Zig side key event; swallow system
    // default command here, avoid NSBeep.
    if (input_debug_enabled()) {
        NSLog(@"[bridge-input] doCommandBySelector %@", NSStringFromSelector(selector));
    }
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // System dictionary lookup (Ctrl-Cmd-D) and Japanese reconversion (saihenkan)
    // both read the document text through this method. Content from live TextInputClient of
    // focused node; NSRange UTF-16 units, bridge clamps to Unicode
    // scalar boundary and maps to UTF-8 model.
    return zenitImeCopyAttributedRange(self, range, actualRange);
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    // point is screen coordinate (lower-left origin). Screen ->
    // window -> view -> zenit content (upper-left origin, same as
    // accessibilityHitTest), then live text client hit for UTF-8 offset,
    // convert back UTF-16 to return.
    if (!self.window) return NSNotFound;
    const uint32_t wid = zenitA11yWindowIdForView(self);
    NSPoint local = zenitLogicalScreenPoint(wrapperForWindow(self.window),point);
    uint32_t start_utf8 = 0;
    uint32_t end_utf8 = 0;
    if (!zenit_text_input_range_at_point(wid,
                                         (float)local.x,
                                         (float)local.y,
                                         &start_utf8, &end_utf8)) {
        return NSNotFound;
    }
    const uint64_t offset16 = zenit_text_input_utf16_for_utf8(wid, start_utf8);
    return offset16 == ZENIT_TEXT_OFFSET_INVALID || offset16 > NSUIntegerMax
        ? NSNotFound
        : (NSUInteger)offset16;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    const uint32_t wid = zenitA11yWindowIdForView(self);
    uint64_t start64 = range.location == NSNotFound
        ? ZENIT_TEXT_OFFSET_INVALID
        : zenit_text_input_utf8_for_utf16(wid, range.location);
    uint64_t end64 = range.location == NSNotFound
        ? ZENIT_TEXT_OFFSET_INVALID
        : zenit_text_input_utf8_for_utf16(wid, NSMaxRange(range));
    // IMEs may query an unspecified range before/while composing. A terminal
    // has an empty document but a real insertion point; use that live caret
    // instead of a stale editor rectangle or the whole view's bottom edge.
    if (start64 == ZENIT_TEXT_OFFSET_INVALID || end64 == ZENIT_TEXT_OFFSET_INVALID) {
        uint32_t start = 0, end = 0, caret = 0;
        if (zenit_text_input_selection(wid, &start, &end, &caret)) {
            start64 = end64 = caret;
        }
    }
    float live_x = 0, live_y = 0, live_w = 0, live_h = 0;
    if (start64 != ZENIT_TEXT_OFFSET_INVALID && end64 != ZENIT_TEXT_OFFSET_INVALID &&
        start64 <= UINT32_MAX && end64 <= UINT32_MAX &&
        zenit_text_input_frame(wid, (uint32_t)start64, (uint32_t)end64,
                               &live_x, &live_y, &live_w, &live_h) && self.window) {
        const uint64_t actualStart16 = zenit_text_input_utf16_for_utf8(wid, start64);
        const uint64_t actualEnd16 = zenit_text_input_utf16_for_utf8(wid, end64);
        if (actualRange) {
            *actualRange = actualStart16 == ZENIT_TEXT_OFFSET_INVALID || actualEnd16 == ZENIT_TEXT_OFFSET_INVALID
                ? NSMakeRange(NSNotFound, 0)
                : NSMakeRange((NSUInteger)actualStart16, (NSUInteger)(actualEnd16 - actualStart16));
        }
        NSView *contentView = self.window.contentView;
        const CGFloat h = live_h > 0 ? live_h : 18;
        NSRect contentRect = NSMakeRect(live_x,
                                        contentView.bounds.size.height - live_y - h,
                                        live_w > 0 ? live_w : 1,
                                        h);
        return zenitLogicalScreenRect(wrapperForWindow(self.window),live_x,live_y,live_w>0?live_w:1,h);
    }
    if (actualRange) *actualRange = range;
    id wrapper = wrapperForWindow(self.window);
    if (wrapper &&
        [[wrapper valueForKey:@"hasImeCursorRect"] boolValue] &&
        [wrapper valueForKey:@"window"] &&
        [[wrapper valueForKey:@"window"] contentView]) {
        NSWindow *window = [wrapper valueForKey:@"window"];
        NSRect content_bounds = [window.contentView bounds];
        const CGFloat raw_w = [[wrapper valueForKey:@"imeCursorWidth"] floatValue];
        const CGFloat raw_h = [[wrapper valueForKey:@"imeCursorHeight"] floatValue];
        const CGFloat caret_w = raw_w > 0 ? raw_w : 1;
        const CGFloat caret_h = raw_h > 0 ? raw_h : 18;
        const CGFloat caret_x = [[wrapper valueForKey:@"imeCursorX"] floatValue];
        const CGFloat caret_y = [[wrapper valueForKey:@"imeCursorY"] floatValue];
        // Zig/UI coordinates upper-left origin; Cocoa contentView lower-
        // left origin
        NSRect content_rect = NSMakeRect(
            caret_x,
            content_bounds.size.height - caret_y - caret_h,
            caret_w,
            caret_h
        );
        NSRect window_rect = [window.contentView convertRect:content_rect toView:nil];
        NSRect screen_rect = zenitLogicalScreenRect(wrapper,caret_x,caret_y,caret_w,caret_h);
        if (input_debug_enabled()) {
            NSLog(@"[bridge-input] firstRect caret=(%.1f,%.1f %.1fx%.1f) content_h=%.1f screen=(%.1f,%.1f %.1fx%.1f)",
                  caret_x, caret_y, caret_w, caret_h,
                  content_bounds.size.height,
                  screen_rect.origin.x, screen_rect.origin.y,
                  screen_rect.size.width, screen_rect.size.height);
        }
        return screen_rect;
    }

    NSRect window_rect = [self convertRect:self.bounds toView:nil];
    return [self.window convertRectToScreen:window_rect];
}

// ==== Drag and drop (NSDraggingDestination) ====

- (void)enqueueDragEventAtX:(float)x
                          y:(float)y
                       kind:(uint8_t)kind
                      paths:(NSString *)paths
                payloadKind:(uint8_t)payloadKind {
    if (drag_debug_enabled()) {
        fprintf(stderr, "[DRAG] kind=%d x=%.1f y=%.1f paths=%s\n",
                (int)kind, x, y, paths.length > 0 ? paths.UTF8String : "(none)");
        fflush(stderr);
    }
    if (!self.dragEventQueue) self.dragEventQueue = [NSMutableArray array];
    [self.dragEventQueue addObject:@{
        @"x": @(x),
        @"y": @(y),
        @"kind": @(kind),
        @"paths": [paths copy] ?: @"",
        @"payloadKind": @(payloadKind),
    }];
}

- (void)pushDragEvent:(id<NSDraggingInfo>)sender kind:(uint8_t)kind withPaths:(BOOL)withPaths {
    NSPoint loc = [sender draggingLocation];
    // lower-left origin -> upper-left origin
    float x = (float)loc.x;
    float y = (float)(self.bounds.size.height - loc.y);
    NSString *paths = @"";
    uint8_t payloadKind = 0;
    if (withPaths) {
        NSMutableArray<NSString *> *entries = [NSMutableArray array];
        NSPasteboard *pb = [sender draggingPasteboard];
        NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ [NSURL class] ] options:nil];
        for (NSURL *url in urls) {
            // file promise source url.path may be nil, addObject:nil throws
            // NSInvalidArgumentException canceling entire drag session
            // (downstream regression)
            if (url.isFileURL) {
                // Finder may vend a file-reference URL (`/.file/id=...`).
                // filePathURL resolves it to the usable filesystem URL.
                NSURL *fileURL = url.filePathURL;
                NSString *path = fileURL.path;
                // The ABI serializes file lists with newlines. macOS permits
                // newlines in filenames, so a hostile drag source could forge
                // extra list entries unless such names fail closed.
                if (path.length > 0 && [path rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) {
                    [entries addObject:path];
                }
            } else if (url.absoluteString.length > 0) {
                [entries addObject:url.absoluteString];
            }
        }
        if (entries.count == 0) {
            NSData *internalData = [pb dataForType:ZenitInternalDragType];
            NSString *internalText = internalData ? [[NSString alloc] initWithData:internalData encoding:NSUTF8StringEncoding] : nil;
            if (internalText.length > 0) {
                [entries addObject:internalText];
                payloadKind = 3;
            } else {
                NSString *s = [pb stringForType:NSPasteboardTypeString];
                if (s.length > 0) {
                    [entries addObject:s];
                    payloadKind = 2;
                }
            }
        } else {
            payloadKind = 1;
        }
        paths = [entries componentsJoinedByString:@"\n"];
    }
    [self enqueueDragEventAtX:x y:y kind:kind paths:paths payloadKind:payloadKind];
}

- (BOOL)receiveFilePromisesFromDraggingInfo:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    NSArray<NSFilePromiseReceiver *> *receivers =
        [pb readObjectsForClasses:@[ [NSFilePromiseReceiver class] ] options:@{}];
    if (receivers.count == 0) return NO;

    NSPoint loc = [sender draggingLocation];
    const float x = (float)loc.x;
    const float y = (float)(self.bounds.size.height - loc.y);
    NSString *directoryName = [NSString stringWithFormat:@"zenit-file-promises-%@", NSUUID.UUID.UUIDString];
    NSString *directoryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:directoryName];
    NSURL *destination = [NSURL fileURLWithPath:directoryPath isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:destination
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        if (drag_debug_enabled()) {
            fprintf(stderr, "[DRAG] file promise temp directory failed: %s\n",
                    directoryError.localizedDescription.UTF8String ?: "unknown error");
        }
        return NO;
    }

    __weak MetalView *weakView = self;
    // A single pasteboard item may promise multiple legacy files, and a drag
    // may contain several receivers. Preserve the destination API's existing
    // one-drop/one-newline-separated-list semantics instead of emitting one
    // synthetic drop per asynchronously completed file.
    NSMutableArray<NSString *> *receivedPaths = [NSMutableArray array];
    for (NSFilePromiseReceiver *receiver in receivers) {
        [receiver receivePromisedFilesAtDestination:destination
                                            options:@{}
                                     operationQueue:self.filePromiseQueue
                                             reader:^(NSURL *fileURL, NSError *errorOrNil) {
            if (errorOrNil != nil || fileURL == nil) {
                if (drag_debug_enabled()) {
                    fprintf(stderr, "[DRAG] file promise receive failed: %s\n",
                            errorOrNil.localizedDescription.UTF8String ?: "unknown error");
                }
                return;
            }
            NSURL *resolvedURL = fileURL.filePathURL;
            NSString *path = resolvedURL.path;
            if (path.length == 0 || [path rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [receivedPaths addObject:path];
            });
        }];
    }
    void (^finishPromises)(void) = ^{
        // Every reader submits its result to the main queue before returning,
        // so this submission is ordered after all successful results.
        dispatch_async(dispatch_get_main_queue(), ^{
            MetalView *view = weakView;
            if (view && receivedPaths.count > 0) {
                NSString *paths = [receivedPaths componentsJoinedByString:@"\n"];
                [view enqueueDragEventAtX:x y:y kind:3 paths:paths payloadKind:1];
            } else {
                // Do not accumulate empty directories for cancelled/failed
                // promises or completed promises whose window has gone away.
                // Successful delivered drops intentionally keep their files
                // alive for the consumer after this callback returns.
                [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
            }
        });
    };
    if (@available(macOS 10.15, *)) {
        [self.filePromiseQueue addBarrierBlock:finishPromises];
    } else {
        // NSFilePromiseReceiver itself dates back to 10.12. Keep that support
        // without blocking AppKit's main thread on older systems.
        NSOperationQueue *promiseQueue = self.filePromiseQueue;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [promiseQueue waitUntilAllOperationsAreFinished];
            finishPromises();
        });
    }
    return YES;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    [self pushDragEvent:sender kind:0 withPaths:NO];
    return sender.draggingSourceOperationMask & self.zenitDropAllowedOperations;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    [self pushDragEvent:sender kind:1 withPaths:NO];
    return sender.draggingSourceOperationMask & self.zenitDropAllowedOperations;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    [self pushDragEvent:sender kind:2 withPaths:NO];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if ((sender.draggingSourceOperationMask & self.zenitDropAllowedOperations) == NSDragOperationNone) return NO;
    if ([self receiveFilePromisesFromDraggingInfo:sender]) return YES;
    [self pushDragEvent:sender kind:3 withPaths:YES];
    return YES;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
 sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    (void)context;
    return self.zenitDragAllowedOperations;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session {
    (void)session;
    return NO;
}

- (void)draggingSession:(NSDraggingSession *)session
          endedAtPoint:(NSPoint)screenPoint
             operation:(NSDragOperation)operation {
    (void)session;
    // Window teardown invalidates the source token before detaching the view.
    // AppKit may still deliver this completion to its retained source object;
    // never resurrect an event for a window/Cx that no longer exists.
    if (!self.zenitDragSessionActive || self.zenitDragToken == 0 || !self.window) {
        self.zenitDragSessionActive = NO;
        self.zenitDragToken = 0;
        self.zenitDragAllowedOperations = NSDragOperationNone;
        return;
    }
    NSPoint windowPoint = [self.window convertPointFromScreen:screenPoint];
    NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
    uint8_t operationBits = 0;
    if ((operation & NSDragOperationCopy) != 0) operationBits |= 1;
    if ((operation & NSDragOperationMove) != 0) operationBits |= 2;
    if ((operation & NSDragOperationLink) != 0) operationBits |= 4;
    if (!self.dragEventQueue) self.dragEventQueue = [NSMutableArray array];
    [self.dragEventQueue addObject:@{
        @"x": @((float)viewPoint.x),
        @"y": @((float)(self.bounds.size.height - viewPoint.y)),
        @"kind": @((uint8_t)4),
        @"paths": @"",
        @"payloadKind": @((uint8_t)0),
        @"sourceToken": @(self.zenitDragToken),
        @"operation": @(operationBits),
    }];
    self.zenitDragSessionActive = NO;
    self.zenitDragToken = 0;
    self.zenitDragAllowedOperations = NSDragOperationNone;
}

@end

// ==== NSAccessibility implementation (retained-tree pull ABI)
//
// Zig side exports from src/ui/a11y/macos_bridge.zig; ObjC implements the NSAccessibilityElement
// subclass ZenitA11yElement corresponding to zig a11y_tree.A11yNode (holds element_handle u32
// = ElementId.raw()).
//
// MetalView implements accessibilityChildren, returning the top-level ZenitA11yElement array;
// child levels recurse via the element's accessibilityChildren.
//
// Lifecycle: the ObjC autorelease pool manages proxies; each VoiceOver fetch regenerates them.
// A proxy holds a u32 handle, not zig memory; a stale call to zenit_a11y_role returns 0
// (generational handle by design).

// Zig exports (first param window_id - zig routes to that
// window's a11y tree). window_id matches Zig Cx.window_id /
// macos_window_id() = NSWindow.windowNumber. Pass 0
// (ZENIT_A11Y_ANY_WINDOW) degrades to first registered window.
#define ZENIT_A11Y_ANY_WINDOW ((uint32_t)0)
extern int zenit_a11y_root_count(uint32_t window_id);
extern ZenitAXHandle zenit_a11y_root_at(uint32_t window_id, int idx);
extern int zenit_a11y_exists(uint32_t window_id, ZenitAXHandle handle);
extern int zenit_a11y_children_count(uint32_t window_id, ZenitAXHandle parent_raw);
extern ZenitAXHandle zenit_a11y_children_at(uint32_t window_id, ZenitAXHandle parent_raw, int idx);
extern int zenit_a11y_role(uint32_t window_id, ZenitAXHandle handle);
extern uint32_t zenit_a11y_state(uint32_t window_id, ZenitAXHandle handle);
extern int zenit_a11y_label(uint32_t window_id, ZenitAXHandle handle, char *buf, int buf_len);
extern int zenit_a11y_description(uint32_t window_id, ZenitAXHandle handle, char *buf, int buf_len);
extern int zenit_a11y_value(uint32_t window_id, ZenitAXHandle handle, char *buf, int buf_len);
extern int zenit_a11y_numeric_value(uint32_t window_id, ZenitAXHandle handle, float *now, float *min, float *max);
extern int zenit_a11y_frame(uint32_t window_id, ZenitAXHandle handle, float *x, float *y, float *width, float *height);
extern uint8_t zenit_a11y_actions(uint32_t window_id, ZenitAXHandle handle);
extern int zenit_a11y_perform_action(uint32_t window_id, ZenitAXHandle handle, uint8_t action);
extern int zenit_a11y_text_selection(uint32_t window_id, ZenitAXHandle handle, uint32_t *start, uint32_t *end, uint32_t *caret);
extern uint8_t zenit_a11y_text_capabilities(uint32_t window_id, ZenitAXHandle handle);
extern int zenit_a11y_set_text_selection(uint32_t window_id, ZenitAXHandle handle, uint32_t start_utf8, uint32_t end_utf8);
extern int zenit_a11y_set_focus(uint32_t window_id, ZenitAXHandle handle, int focused);
extern int zenit_a11y_set_text_value(uint32_t window_id, ZenitAXHandle handle, const char *bytes, int len);
extern int zenit_a11y_text_visible_range(uint32_t window_id, ZenitAXHandle handle, uint32_t *start, uint32_t *end);
extern int zenit_a11y_text_frame(uint32_t window_id, ZenitAXHandle handle, uint32_t start_utf8, uint32_t end_utf8, float *x, float *y, float *width, float *height);
extern int zenit_a11y_text_range_at_point(uint32_t window_id, ZenitAXHandle handle, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8);
extern int zenit_a11y_set_numeric_value(uint32_t window_id, ZenitAXHandle handle, float value);
extern uint8_t zenit_a11y_numeric_capabilities(uint32_t window_id, ZenitAXHandle handle);
extern ZenitAXHandle zenit_a11y_parent(uint32_t window_id, ZenitAXHandle handle);
extern ZenitAXHandle zenit_a11y_focused(uint32_t window_id);
extern ZenitAXHandle zenit_a11y_active_descendant(uint32_t window_id, ZenitAXHandle handle);
extern ZenitAXHandle zenit_a11y_hit_test(uint32_t window_id, float x, float y);
extern uint8_t zenit_a11y_orientation(uint32_t window_id, ZenitAXHandle handle);
extern uint8_t zenit_a11y_sort_direction(uint32_t window_id, ZenitAXHandle handle);
extern uint16_t zenit_a11y_level(uint32_t window_id, ZenitAXHandle handle);
extern uint32_t zenit_a11y_set_size(uint32_t window_id, ZenitAXHandle handle);
extern int zenit_a11y_row_index_range(uint32_t window_id, ZenitAXHandle handle, uint32_t *index, uint32_t *span);
extern int zenit_a11y_column_index_range(uint32_t window_id, ZenitAXHandle handle, uint32_t *index, uint32_t *span);
extern int zenit_a11y_placeholder(uint32_t window_id, ZenitAXHandle handle, char *buf, int buf_len);
extern int zenit_a11y_identifier(uint32_t window_id, ZenitAXHandle handle, char *buf, int buf_len);
// Semantic collection (docs/A11Y_ARCHITECTURE.md section 12).
extern int zenit_a11y_collection_info(uint32_t window_id, ZenitAXHandle handle, uint32_t *count, uint32_t *first_visible, uint32_t *visible_len);
extern ZenitAXHandle zenit_a11y_collection_row_at(uint32_t window_id, ZenitAXHandle handle, uint32_t index);
extern int zenit_a11y_commit_scroll_to_visible(uint32_t window_id, ZenitAXHandle handle);

enum {
    ZenitA11yActionPress = 0,
    ZenitA11yActionToggle = 1,
    ZenitA11yActionIncrement = 2,
    ZenitA11yActionDecrement = 3,
    ZenitA11yActionScrollToVisible = 4,
};

enum {
    ZenitA11yActionBitPress = 1 << 0,
    ZenitA11yActionBitToggle = 1 << 1,
    ZenitA11yActionBitIncrement = 1 << 2,
    ZenitA11yActionBitDecrement = 1 << 3,
};

// Zig never-hit sentinel (macos_bridge.INVALID/NO_RETAINED same
// family maxInt(u32), but a11y table key domain is windowNumber, no
// real window is maxInt).
#define ZENIT_A11Y_DEAD_WINDOW ((uint32_t)0xFFFFFFFFu)
#define ZENIT_A11Y_INVALID_HANDLE ((ZenitAXHandle)0xFFFFFFFFu)

// AXId kind in 8 bits above payload (Zig a11y.tree.AXId uses
// comptime assert pinning this). Non-zero = semantic collection item
// element (row/cell/compound text), not Node projection.
static inline BOOL zenitA11yIsItemHandle(ZenitAXHandle handle) {
    return ((handle >> 32) & 0xFFu) != 0;
}

enum {
    ZenitA11yDirtyRole = 1 << 0,
    ZenitA11yDirtyState = 1 << 1,
    ZenitA11yDirtyLabel = 1 << 2,
    ZenitA11yDirtyValue = 1 << 3,
    ZenitA11yDirtyLive = 1 << 4,
    ZenitA11yDirtyFocus = 1 << 5,
    ZenitA11yDirtyStructure = 1 << 6,
    ZenitA11yDirtyActiveDescendant = 1 << 7,
    ZenitA11yDirtyGeometry = 1 << 8,
    ZenitA11yDirtySelection = 1 << 9,
    ZenitA11yDirtyRowCount = 1 << 10,
};

enum {
    ZenitA11yStateDisabled = 1u << 0,
    ZenitA11yStateHidden = 1u << 1,
    ZenitA11yStateExpanded = 1u << 2,
    ZenitA11yStateSelected = 1u << 3,
    ZenitA11yStateChecked = 1u << 4,
    ZenitA11yStateIndeterminate = 1u << 5,
    ZenitA11yStatePressed = 1u << 6,
    ZenitA11yStateRequired = 1u << 7,
    ZenitA11yStateInvalid = 1u << 8,
    ZenitA11yStateReadonly = 1u << 9,
    ZenitA11yStateBusy = 1u << 10,
    ZenitA11yStateModal = 1u << 11,
    ZenitA11yStateFocused = 1u << 12,
    ZenitA11yStateFocusable = 1u << 13,
    ZenitA11yStateHasPopup = 1u << 14,
    ZenitA11yStateMultiline = 1u << 15,
    ZenitA11yStateMultiselectable = 1u << 16,
    ZenitA11yStateSecure = 1u << 17,
    ZenitA11yStateExpandedPresent = 1u << 18,
};

// NSView -> owning window's a11y routing key. When window == nil return the DEAD sentinel,
// NOT ANY_WINDOW: after a window closes VoiceOver may still hold its ZenitA11yElement proxy,
// and a wildcard would read another live window's tree, where the handle raw value
// false-matches (ElementId lacks world identity) and VoiceOver sees an unrelated role/label.
// Correct behavior is element invalid -> queries empty.
static uint32_t zenitA11yWindowIdForView(NSView *view) {
    NSWindow *win = view.window;
    if (!win) return ZENIT_A11Y_DEAD_WINDOW;
    return (uint32_t)((NSInteger)[win windowNumber]);
}

// a11y_tree.Role enum values (aligned with
// src/ui/a11y/tree.zig pub const Role order; changing zig enum needs
// sync here).
typedef NS_ENUM(int, ZenitA11yTreeRole) {
    ZenitA11yTreeRoleNone = 0,
    ZenitA11yTreeRoleApplication = 1,
    ZenitA11yTreeRoleButton = 2,
    ZenitA11yTreeRoleCheckbox = 3,
    ZenitA11yTreeRoleRadio = 4,
    ZenitA11yTreeRoleRadioGroup = 5,
    ZenitA11yTreeRoleSlider = 6,
    ZenitA11yTreeRoleSpinButton = 7,
    ZenitA11yTreeRoleProgressBar = 8,
    ZenitA11yTreeRoleLink = 9,
    ZenitA11yTreeRoleTextbox = 10,
    ZenitA11yTreeRoleTextarea = 11,
    ZenitA11yTreeRoleSearchbox = 12,
    ZenitA11yTreeRoleCombobox = 13,
    ZenitA11yTreeRoleListbox = 14,
    ZenitA11yTreeRoleListitem = 15,
    ZenitA11yTreeRoleTree = 16,
    ZenitA11yTreeRoleTreeitem = 17,
    ZenitA11yTreeRoleGrid = 18,
    ZenitA11yTreeRoleRow = 19,
    ZenitA11yTreeRoleCell = 20,
    ZenitA11yTreeRoleColumnheader = 21,
    ZenitA11yTreeRoleRowheader = 22,
    ZenitA11yTreeRoleMenu = 23,
    ZenitA11yTreeRoleMenubar = 24,
    ZenitA11yTreeRoleMenuitem = 25,
    ZenitA11yTreeRoleMenuitemcheckbox = 26,
    ZenitA11yTreeRoleMenuitemradio = 27,
    ZenitA11yTreeRoleDialog = 28,
    ZenitA11yTreeRoleAlertdialog = 29,
    ZenitA11yTreeRoleAlert = 30,
    ZenitA11yTreeRoleStatus = 31,
    ZenitA11yTreeRoleLog = 32,
    ZenitA11yTreeRoleTabs = 33,
    ZenitA11yTreeRoleTab = 34,
    ZenitA11yTreeRoleTabpanel = 35,
    ZenitA11yTreeRoleTooltip = 36,
    ZenitA11yTreeRoleGroup = 37,
    ZenitA11yTreeRoleRegion = 38,
    ZenitA11yTreeRoleHeading = 39,
    ZenitA11yTreeRoleParagraph = 40,
    ZenitA11yTreeRoleImage = 41,
    ZenitA11yTreeRoleArticle = 42,
    ZenitA11yTreeRoleSection = 43,
    ZenitA11yTreeRoleNavigation = 44,
    ZenitA11yTreeRoleList = 45,
    ZenitA11yTreeRoleSeparator = 46,
    ZenitA11yTreeRoleForm = 47,
    ZenitA11yTreeRoleMain = 48,
    ZenitA11yTreeRoleBanner = 49,
    ZenitA11yTreeRoleContentinfo = 50,
    ZenitA11yTreeRoleGeneric = 51,
    ZenitA11yTreeRoleStaticText = 52,
    ZenitA11yTreeRoleSwitchControl = 53,
    ZenitA11yTreeRoleScrollArea = 54,
};

static NSAccessibilityRole zenitA11yMapRoleToNS(int role_int) {
    switch ((ZenitA11yTreeRole)role_int) {
        case ZenitA11yTreeRoleApplication: return NSAccessibilityApplicationRole;
        case ZenitA11yTreeRoleButton: return NSAccessibilityButtonRole;
        case ZenitA11yTreeRoleCheckbox: return NSAccessibilityCheckBoxRole;
        case ZenitA11yTreeRoleRadio: return NSAccessibilityRadioButtonRole;
        case ZenitA11yTreeRoleRadioGroup: return NSAccessibilityRadioGroupRole;
        case ZenitA11yTreeRoleSlider: return NSAccessibilitySliderRole;
        case ZenitA11yTreeRoleSpinButton: return NSAccessibilityIncrementorRole;
        case ZenitA11yTreeRoleProgressBar: return NSAccessibilityProgressIndicatorRole;
        case ZenitA11yTreeRoleLink: return NSAccessibilityLinkRole;
        case ZenitA11yTreeRoleTextbox: return NSAccessibilityTextFieldRole;
        case ZenitA11yTreeRoleTextarea: return NSAccessibilityTextAreaRole;
        case ZenitA11yTreeRoleSearchbox: return NSAccessibilityTextFieldRole;
        case ZenitA11yTreeRoleCombobox: return NSAccessibilityComboBoxRole;
        case ZenitA11yTreeRoleListbox: return NSAccessibilityListRole;
        case ZenitA11yTreeRoleListitem: return NSAccessibilityRowRole;
        case ZenitA11yTreeRoleTree: return NSAccessibilityOutlineRole;
        case ZenitA11yTreeRoleTreeitem: return NSAccessibilityRowRole;
        case ZenitA11yTreeRoleGrid: return NSAccessibilityTableRole;
        case ZenitA11yTreeRoleRow: return NSAccessibilityRowRole;
        case ZenitA11yTreeRoleCell: return NSAccessibilityCellRole;
        case ZenitA11yTreeRoleColumnheader: return NSAccessibilityColumnRole;
        case ZenitA11yTreeRoleRowheader: return NSAccessibilityRowRole;
        case ZenitA11yTreeRoleMenu: return NSAccessibilityMenuRole;
        case ZenitA11yTreeRoleMenubar: return NSAccessibilityMenuBarRole;
        case ZenitA11yTreeRoleMenuitem: return NSAccessibilityMenuItemRole;
        case ZenitA11yTreeRoleMenuitemcheckbox: return NSAccessibilityMenuItemRole;
        case ZenitA11yTreeRoleMenuitemradio: return NSAccessibilityMenuItemRole;
        // Dialog/alert/status/log: AXGroup + AXApplication* subrole (see
        // zenitA11ySubroleForRole). AXSheet is window-docked; alert/status
        // mapped to AXStaticText lose live region and can't hold subelements.
        case ZenitA11yTreeRoleDialog: return NSAccessibilityGroupRole;
        case ZenitA11yTreeRoleAlertdialog: return NSAccessibilityGroupRole;
        case ZenitA11yTreeRoleAlert: return NSAccessibilityGroupRole;
        case ZenitA11yTreeRoleStatus: return NSAccessibilityGroupRole;
        case ZenitA11yTreeRoleLog: return NSAccessibilityGroupRole;
        case ZenitA11yTreeRoleTabs: return NSAccessibilityTabGroupRole;
        case ZenitA11yTreeRoleTab: return NSAccessibilityRadioButtonRole; // tab uses radio in AX
        case ZenitA11yTreeRoleTabpanel: return NSAccessibilityGroupRole;
        case ZenitA11yTreeRoleSwitchControl: return NSAccessibilityCheckBoxRole;
        case ZenitA11yTreeRoleScrollArea: return NSAccessibilityScrollAreaRole;
        case ZenitA11yTreeRoleTooltip: return NSAccessibilityHelpTagRole;
        // AXHeading: macOS 26 SDK public NSAccessibilityHeadingRole, but
        // string value WebKit/Chromium use, old VoiceOver title rotor
        // recognizes it.
        case ZenitA11yTreeRoleHeading: return @"AXHeading";
        case ZenitA11yTreeRoleParagraph: return NSAccessibilityStaticTextRole;
        case ZenitA11yTreeRoleImage: return NSAccessibilityImageRole;
        case ZenitA11yTreeRoleList: return NSAccessibilityListRole;
        case ZenitA11yTreeRoleSeparator: return NSAccessibilitySplitterRole;
        case ZenitA11yTreeRoleStaticText: return NSAccessibilityStaticTextRole;
        case ZenitA11yTreeRoleGeneric:
        case ZenitA11yTreeRoleGroup:
        case ZenitA11yTreeRoleRegion:
        case ZenitA11yTreeRoleArticle:
        case ZenitA11yTreeRoleSection:
        case ZenitA11yTreeRoleNavigation:
        case ZenitA11yTreeRoleForm:
        case ZenitA11yTreeRoleMain:
        case ZenitA11yTreeRoleBanner:
        case ZenitA11yTreeRoleContentinfo:
            return NSAccessibilityGroupRole;
        default:
            return NSAccessibilityUnknownRole;
    }
}

// initWithBytes strips leading UTF-8 BOM (U+FEFF), but Zig a11y
// offsets count original UTF-8 bytes - missing U+FEFF throws all
// UTF-8<->UTF-16 conversion off by 3 bytes.
static NSString *zenitA11yStringFromUTF8(const void *bytes, NSUInteger len) {
    NSString *s = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    const unsigned char *b = (const unsigned char *)bytes;
    if (s && len >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF &&
        (s.length == 0 || [s characterAtIndex:0] != 0xFEFF)) {
        s = [@"\uFEFF" stringByAppendingString:s];
    }
    return s;
}

static NSString *zenitA11yCopyString(int (*fetch)(uint32_t, ZenitAXHandle, char *, int),
                                     uint32_t window_id, ZenitAXHandle handle) {
    int needed = fetch(window_id, handle, NULL, 0);
    if (needed <= 0) return nil;
    char stack_buf[256];
    char *buf = stack_buf;
    char *heap = NULL;
    if ((size_t)needed > sizeof(stack_buf)) {
        heap = (char *)malloc((size_t)needed + 1);
        if (!heap) return nil;
        buf = heap;
    }
    int written = fetch(window_id, handle, buf, needed);
    NSString *s = (written > 0)
        ? zenitA11yStringFromUTF8(buf, (NSUInteger)written)
        : nil;
    if (heap) free(heap);
    return s;
}

static NSUInteger zenitA11yUTF16OffsetForUTF8(NSString *text, uint32_t utf8Offset) {
    if (!text) return NSNotFound;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NSNotFound;
    NSUInteger byteOffset = MIN((NSUInteger)utf8Offset, data.length);
    // Zig publishes grapheme boundaries, but stale/native callers are still
    // handled defensively by backing up to a decodable UTF-8 prefix.
    while (true) {
        NSString *prefix = zenitA11yStringFromUTF8(data.bytes, byteOffset);
        if (prefix) return prefix.length;
        if (byteOffset == 0) return 0;
        byteOffset--;
    }
}

static uint32_t zenitA11yUTF8OffsetForUTF16(NSString *text, NSUInteger utf16Offset) {
    if (!text) return 0;
    NSUInteger safe = MIN(utf16Offset, text.length);
    // Avoid splitting a UTF-16 surrogate pair.
    if (safe > 0 && safe < text.length) {
        unichar previous = [text characterAtIndex:safe - 1];
        unichar next = [text characterAtIndex:safe];
        if (CFStringIsSurrogateHighCharacter(previous) && CFStringIsSurrogateLowCharacter(next)) safe--;
    }
    NSString *prefix = [text substringToIndex:safe];
    NSData *bytes = [prefix dataUsingEncoding:NSUTF8StringEncoding];
    return (uint32_t)MIN(bytes.length, (NSUInteger)UINT32_MAX);
}

static BOOL zenitA11yRangeFitsLength(NSRange range, NSUInteger length) {
    return range.location != NSNotFound && range.location <= length &&
        range.length <= length - range.location;
}

static NSRange zenitA11yClampedRange(NSRange range, NSUInteger length) {
    if (range.location == NSNotFound || range.location > length)
        return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(range.location, MIN(range.length, length - range.location));
}

static BOOL zenitA11yHandleIsWithin(uint32_t window_id, ZenitAXHandle handle, ZenitAXHandle ancestor) {
    ZenitAXHandle cursor = handle;
    // A valid retained tree is acyclic. The bound keeps malformed application
    // data from hanging an AppKit accessibility callback.
    for (NSUInteger depth = 0; depth < 4096 && cursor != ZENIT_A11Y_INVALID_HANDLE; depth++) {
        if (cursor == ancestor) return YES;
        cursor = zenit_a11y_parent(window_id, cursor);
    }
    return NO;
}

// Subroles: match Chromium ax_platform_node_cocoa table. Landmark
// subroles let VoiceOver landmark rotor jump to navigation/main/
// footer.
static NSAccessibilitySubrole zenitA11ySubroleForRole(int role) {
    switch (role) {
        case ZenitA11yTreeRoleSearchbox: return NSAccessibilitySearchFieldSubrole;
        case ZenitA11yTreeRoleTreeitem: return NSAccessibilityOutlineRowSubrole;
        case ZenitA11yTreeRoleRow: return NSAccessibilityTableRowSubrole;
        case ZenitA11yTreeRoleSwitchControl: return NSAccessibilitySwitchSubrole;
        case ZenitA11yTreeRoleTab: return NSAccessibilityTabButtonSubrole;
        case ZenitA11yTreeRoleTabpanel: return @"AXTabPanel";
        case ZenitA11yTreeRoleDialog: return @"AXApplicationDialog";
        case ZenitA11yTreeRoleAlertdialog: return @"AXApplicationAlertDialog";
        case ZenitA11yTreeRoleAlert: return @"AXApplicationAlert";
        case ZenitA11yTreeRoleStatus: return @"AXApplicationStatus";
        case ZenitA11yTreeRoleLog: return @"AXApplicationLog";
        case ZenitA11yTreeRoleNavigation: return @"AXLandmarkNavigation";
        case ZenitA11yTreeRoleMain: return @"AXLandmarkMain";
        case ZenitA11yTreeRoleBanner: return @"AXLandmarkBanner";
        case ZenitA11yTreeRoleContentinfo: return @"AXLandmarkContentInfo";
        case ZenitA11yTreeRoleRegion: return @"AXLandmarkRegion";
        case ZenitA11yTreeRoleForm: return @"AXLandmarkForm";
        case ZenitA11yTreeRoleArticle: return @"AXDocumentArticle";
        default: return nil;
    }
}

// AppKit NSAccessibilityRoleDescription doesn't recognize WebKit
// subroles (AXHeading, AXApplicationDialog, landmarks), returns empty
// so VoiceOver only speaks name. Provide fallback descriptions here;
// AppKit-recognized combos use system localization.
static NSString *zenitA11yFallbackRoleDescription(int role) {
    switch (role) {
        case ZenitA11yTreeRoleHeading: return @"heading";
        case ZenitA11yTreeRoleDialog: return @"dialog";
        case ZenitA11yTreeRoleAlertdialog: return @"alert dialog";
        case ZenitA11yTreeRoleAlert: return @"alert";
        case ZenitA11yTreeRoleStatus: return @"status";
        case ZenitA11yTreeRoleLog: return @"log";
        case ZenitA11yTreeRoleTabpanel: return @"tab panel";
        case ZenitA11yTreeRoleNavigation: return @"navigation";
        case ZenitA11yTreeRoleMain: return @"main";
        case ZenitA11yTreeRoleBanner: return @"banner";
        case ZenitA11yTreeRoleContentinfo: return @"content information";
        case ZenitA11yTreeRoleRegion: return @"region";
        case ZenitA11yTreeRoleForm: return @"form";
        case ZenitA11yTreeRoleArticle: return @"article";
        case ZenitA11yTreeRoleSwitchControl: return @"switch";
        default: return nil;
    }
}

// AX in-frame service (metal_bridge.m): main thread waiting drawable
// only turns AX run loop mode. Frame not ended, AX actions
// (press/focus/value/range) can't sync, queue to g_zenit_ax_deferred,
// next pump start (zenitDrainDeferredA11yMutations, before event
// dispatch) executes in order. Don't use dispatch_async(main):
// continuous render pump enters nextEventMatchingMask, gets display-
// link immediately returns, run loop doesn't turn, main queue starves.
// Read-only queries sync-answer.
extern int zenit_ax_in_frame_service(void);
static NSMutableArray *g_zenit_ax_deferred;

// Defer returns YES immediately: accepted semantics, matching AppKit
// press contract; actual execution next pump after frame end.
static BOOL zenitA11yRunMutation(BOOL (^mutation)(void)) {
    if (zenit_ax_in_frame_service()) {
        if (!g_zenit_ax_deferred) g_zenit_ax_deferred = [NSMutableArray array];
        [g_zenit_ax_deferred addObject:[mutation copy]];
        // Wake possible nextEventMatchingMask-blocked pump (idle has no
        // display-link).
        macos_post_empty_event();
        return YES;
    }
    return mutation();
}

// Non-reentrant: nested event loop (press opens file dialog etc) may
// run nested pump, later-queued action runs before batch remainder
// (cross review spotted). Leave to outer next turn; don't drain in-
// frame service (action must run outside frame).
static void zenitDrainDeferredA11yMutations(void) {
    static BOOL draining = NO;
    if (draining || zenit_ax_in_frame_service() || g_zenit_ax_deferred.count == 0) return;
    draining = YES;
    @try {
        NSArray *pending = g_zenit_ax_deferred;
        g_zenit_ax_deferred = nil;
        for (BOOL (^mutation)(void) in pending) (void)mutation();
    } @finally {
        draining = NO;
    }
}

@interface ZenitA11yElement : NSAccessibilityElement
@property (nonatomic, assign) ZenitAXHandle handle;
@property (nonatomic, weak) NSView *parentView;
@property (nonatomic, weak) id accessibilityParentObject;
+ (instancetype)elementForHandle:(ZenitAXHandle)handle
                      parentView:(NSView *)parentView
             accessibilityParent:(id)accessibilityParent;
@end

@implementation ZenitA11yElement

+ (instancetype)elementForHandle:(ZenitAXHandle)handle
                      parentView:(NSView *)parentView
             accessibilityParent:(id)accessibilityParent {
    ZenitA11yElement *el = [[ZenitA11yElement alloc] init];
    el.handle = handle;
    el.parentView = parentView;
    el.accessibilityParentObject = accessibilityParent;
    return el;
}

- (BOOL)isAccessibilityElement {
    uint32_t wid = [self zenitWindowId];
    float x=0,y=0,width=0,height=0;
    if(zenit_a11y_frame(wid,self.handle,&x,&y,&width,&height) && zenitLogicalHeaderHidden(wrapperForWindow(self.parentView.window),y,height)) return NO;
    return zenit_a11y_exists(wid, self.handle) &&
        (zenit_a11y_state(wid, self.handle) & ZenitA11yStateHidden) == 0;
}

// Proxy holds handle + parentView, window_id live-fetched each from
// parentView - stale id not left when window closes or view switches.
- (uint32_t)zenitWindowId {
    return zenitA11yWindowIdForView(self.parentView);
}

- (NSAccessibilityRole)accessibilityRole {
    return zenitA11yMapRoleToNS(zenit_a11y_role([self zenitWindowId], self.handle));
}

- (NSAccessibilitySubrole)accessibilitySubrole {
    uint32_t wid = [self zenitWindowId];
    if ((zenit_a11y_state(wid, self.handle) & ZenitA11yStateSecure) != 0)
        return NSAccessibilitySecureTextFieldSubrole;
    return zenitA11ySubroleForRole(zenit_a11y_role(wid, self.handle));
}

- (NSString *)accessibilityLabel {
    return zenitA11yCopyString(zenit_a11y_label, [self zenitWindowId], self.handle);
}

- (NSString *)accessibilityHelp {
    return zenitA11yCopyString(zenit_a11y_description, [self zenitWindowId], self.handle);
}

- (NSString *)accessibilityPlaceholderValue {
    return zenitA11yCopyString(zenit_a11y_placeholder, [self zenitWindowId], self.handle);
}

- (NSString *)accessibilityIdentifier {
    return zenitA11yCopyString(zenit_a11y_identifier, [self zenitWindowId], self.handle);
}

- (NSString *)accessibilityRoleDescription {
    NSString *system = NSAccessibilityRoleDescription([self accessibilityRole], [self accessibilitySubrole]);
    NSString *fallback = zenitA11yFallbackRoleDescription(zenit_a11y_role([self zenitWindowId], self.handle));
    // AppKit falls back unrecognized subrole to parent role
    // description (dialog becomes group), so roles with fallback use it.
    if (fallback) return fallback;
    return system;
}

- (id)accessibilityValue {
    uint32_t wid = [self zenitWindowId];
    int role = zenit_a11y_role(wid, self.handle);
    if (role == ZenitA11yTreeRoleTab) {
        // Tab value is selected (AppKit tab button matches Chromium).
        return @((zenit_a11y_state(wid, self.handle) & ZenitA11yStateSelected) != 0 ? 1 : 0);
    }
    if (role == ZenitA11yTreeRoleCheckbox || role == ZenitA11yTreeRoleSwitchControl || role == ZenitA11yTreeRoleRadio ||
        role == ZenitA11yTreeRoleMenuitemcheckbox || role == ZenitA11yTreeRoleMenuitemradio) {
        // AppKit check controls publish 0=off, 1=on, 2=mixed.
        uint32_t state = zenit_a11y_state(wid, self.handle);
        if ((state & (1u << 5)) != 0) return @2;
        return @((state & (1u << 4)) != 0 ? 1 : 0);
    }
    NSString *text = zenitA11yCopyString(zenit_a11y_value, wid, self.handle);
    if (text) return text;
    // An editable control with an empty value is still a readable text value;
    // the zero-length C probe otherwise looks identical to "not published".
    if ((zenit_a11y_text_capabilities(wid, self.handle) & 0x1) != 0) return @"";
    float now = 0;
    if (zenit_a11y_numeric_value(wid, self.handle, &now, NULL, NULL)) return @(now);
    return nil;
}

- (id)accessibilityMinValue {
    float min = 0;
    return zenit_a11y_numeric_value([self zenitWindowId], self.handle, NULL, &min, NULL) ? @(min) : nil;
}

- (id)accessibilityMaxValue {
    float max = 0;
    return zenit_a11y_numeric_value([self zenitWindowId], self.handle, NULL, NULL, &max) ? @(max) : nil;
}

- (void)setAccessibilityValue:(id)value {
    uint32_t wid = [self zenitWindowId];
    uint8_t textCaps = zenit_a11y_text_capabilities(wid, self.handle);
    if ((textCaps & 0x4) != 0 && [value isKindOfClass:[NSString class]]) {
        NSData *bytes = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
        ZenitAXHandle handle = self.handle;
        if (bytes.length <= INT_MAX)
            (void)zenitA11yRunMutation(^BOOL {
                return zenit_a11y_set_text_value(wid, handle, bytes.bytes, (int)bytes.length) != 0;
            });
        return;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        ZenitAXHandle handle = self.handle;
        float number = [(NSNumber *)value floatValue];
        (void)zenitA11yRunMutation(^BOOL { return zenit_a11y_set_numeric_value(wid, handle, number) != 0; });
    }
}

- (BOOL)isAccessibilityEnabled {
    // a11y_tree.State bit 0 = disabled
    uint32_t bits = zenit_a11y_state([self zenitWindowId], self.handle);
    return (bits & ZenitA11yStateDisabled) == 0;
}

- (BOOL)isAccessibilityFocused {
    return (zenit_a11y_state([self zenitWindowId], self.handle) & ZenitA11yStateFocused) != 0;
}

- (void)setAccessibilityFocused:(BOOL)focused {
    uint32_t wid = [self zenitWindowId];
    ZenitAXHandle handle = self.handle;
    (void)zenitA11yRunMutation(^BOOL { return zenit_a11y_set_focus(wid, handle, focused ? 1 : 0) != 0; });
}

- (BOOL)isAccessibilitySelected {
    return (zenit_a11y_state([self zenitWindowId], self.handle) & ZenitA11yStateSelected) != 0;
}

- (BOOL)isAccessibilityExpanded {
    return (zenit_a11y_state([self zenitWindowId], self.handle) & ZenitA11yStateExpanded) != 0;
}

- (BOOL)isAccessibilityRequired {
    return (zenit_a11y_state([self zenitWindowId], self.handle) & ZenitA11yStateRequired) != 0;
}

- (BOOL)isAccessibilityModal {
    return (zenit_a11y_state([self zenitWindowId], self.handle) & ZenitA11yStateModal) != 0;
}

- (NSAccessibilityOrientation)accessibilityOrientation {
    switch (zenit_a11y_orientation([self zenitWindowId], self.handle)) {
        case 1: return NSAccessibilityOrientationHorizontal;
        case 2: return NSAccessibilityOrientationVertical;
        default: return NSAccessibilityOrientationUnknown;
    }
}

- (NSAccessibilitySortDirection)accessibilitySortDirection {
    switch (zenit_a11y_sort_direction([self zenitWindowId], self.handle)) {
        case 1: return NSAccessibilitySortDirectionAscending;
        case 2: return NSAccessibilitySortDirectionDescending;
        default: return NSAccessibilitySortDirectionUnknown;
    }
}

- (NSInteger)accessibilityDisclosureLevel {
    uint16_t level = zenit_a11y_level([self zenitWindowId], self.handle);
    return level > 0 ? (NSInteger)(level - 1) : 0;
}

- (NSRange)accessibilityRowIndexRange {
    uint32_t index = 0, span = 0;
    if (!zenit_a11y_row_index_range([self zenitWindowId], self.handle, &index, &span))
        return NSMakeRange(NSNotFound, 0);
    return NSMakeRange((NSUInteger)index, (NSUInteger)span);
}

- (NSRange)accessibilityColumnIndexRange {
    uint32_t index = 0, span = 0;
    if (!zenit_a11y_column_index_range([self zenitWindowId], self.handle, &index, &span))
        return NSMakeRange(NSNotFound, 0);
    return NSMakeRange((NSUInteger)index, (NSUInteger)span);
}

- (NSArray *)accessibilityChildren {
    uint32_t wid = [self zenitWindowId];
    int n = zenit_a11y_children_count(wid, self.handle);
    if (n <= 0) return @[];
    NSMutableArray *kids = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        ZenitAXHandle h = zenit_a11y_children_at(wid, self.handle, i);
        if (h == ZENIT_A11Y_INVALID_HANDLE) continue;
        MetalView *host = (MetalView *)self.parentView;
        [kids addObject:[host zenitA11yElementForHandle:h accessibilityParent:self]];
    }
    return kids;
}

- (NSArray *)accessibilityChildrenInNavigationOrder {
    return [self accessibilityChildren];
}

- (NSArray *)accessibilityVisibleChildren {
    // Collection table: only rows intersecting viewport (full rows in
    // AXChildren/AXRows fetched by segment).
    uint32_t count = 0, first = 0, len = 0;
    if ([self zenitCollectionCount:&count first:&first visible:&len])
        return [self zenitCollectionRowsFrom:first count:len];
    return [self accessibilityChildren];
}

- (NSArray *)accessibilitySelectedChildren {
    uint32_t wid = [self zenitWindowId];
    ZenitAXHandle active = zenit_a11y_active_descendant(wid, self.handle);
    MetalView *host = (MetalView *)self.parentView;
    if (active != ZENIT_A11Y_INVALID_HANDLE)
        return @[[host zenitA11yElementForHandle:active]];
    NSMutableArray *selected = [NSMutableArray array];
    for (ZenitA11yElement *child in [self accessibilityChildren]) {
        if ([child isAccessibilitySelected]) [selected addObject:child];
    }
    return selected;
}

- (id)accessibilityFocusedUIElement {
    uint32_t wid = [self zenitWindowId];
    ZenitAXHandle active = zenit_a11y_active_descendant(wid, self.handle);
    if (active != ZENIT_A11Y_INVALID_HANDLE)
        return [(MetalView *)self.parentView zenitA11yElementForHandle:active];
    ZenitAXHandle focused = zenit_a11y_focused(wid);
    if (focused == ZENIT_A11Y_INVALID_HANDLE ||
        !zenitA11yHandleIsWithin(wid, focused, self.handle)) return nil;
    if (focused == self.handle) return self;
    return [(MetalView *)self.parentView zenitA11yElementForHandle:focused];
}

- (NSArray *)zenitChildrenWithRoles:(NSIndexSet *)roles {
    uint32_t wid = [self zenitWindowId];
    NSMutableArray *result = [NSMutableArray array];
    for (ZenitA11yElement *child in [self accessibilityChildren]) {
        int role = zenit_a11y_role(wid, child.handle);
        if ([roles containsIndex:(NSUInteger)role]) [result addObject:child];
    }
    return result;
}

// Semantic collection (docs/A11Y_ARCHITECTURE.md section 12):
// table exposes all rows (matches NSTableView: AXRows/AXChildren =
// all, offscreen have real frame). Items materialize on fetch;
// segment fetch only materializes requested segment.

- (BOOL)zenitCollectionCount:(uint32_t *)count first:(uint32_t *)first visible:(uint32_t *)len {
    return zenit_a11y_collection_info([self zenitWindowId], self.handle, count, first, len) != 0;
}

- (NSArray *)zenitCollectionRowsFrom:(uint32_t)first count:(uint32_t)n {
    uint32_t wid = [self zenitWindowId];
    MetalView *host = (MetalView *)self.parentView;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:n];
    for (uint32_t i = 0; i < n; i++) {
        ZenitAXHandle h = zenit_a11y_collection_row_at(wid, self.handle, first + i);
        if (h == ZENIT_A11Y_INVALID_HANDLE) break;
        [rows addObject:[host zenitA11yElementForHandle:h accessibilityParent:self]];
    }
    return rows;
}

static BOOL zenitA11yIsRowListAttribute(NSAccessibilityAttributeName attribute) {
    return [attribute isEqualToString:NSAccessibilityRowsAttribute] ||
        [attribute isEqualToString:NSAccessibilityChildrenAttribute] ||
        [attribute isEqualToString:NSAccessibilityChildrenInNavigationOrderAttribute];
}

- (NSUInteger)accessibilityArrayAttributeCount:(NSAccessibilityAttributeName)attribute {
    uint32_t count = 0;
    if (zenitA11yIsRowListAttribute(attribute) && [self zenitCollectionCount:&count first:NULL visible:NULL])
        return count;
    return [super accessibilityArrayAttributeCount:attribute];
}

- (NSArray *)accessibilityArrayAttributeValues:(NSAccessibilityAttributeName)attribute
                                          index:(NSUInteger)index
                                       maxCount:(NSUInteger)maxCount {
    uint32_t count = 0;
    if (zenitA11yIsRowListAttribute(attribute) && [self zenitCollectionCount:&count first:NULL visible:NULL]) {
        if (index >= count) return @[];
        NSUInteger n = MIN(maxCount, (NSUInteger)count - index);
        return [self zenitCollectionRowsFrom:(uint32_t)index count:(uint32_t)n];
    }
    return [super accessibilityArrayAttributeValues:attribute index:index maxCount:maxCount];
}

- (NSUInteger)accessibilityIndexOfChild:(id)child {
    uint32_t count = 0;
    if ([child isKindOfClass:[ZenitA11yElement class]] &&
        [self zenitCollectionCount:&count first:NULL visible:NULL]) {
        uint32_t index = 0, span = 0;
        ZenitA11yElement *element = child;
        if (zenit_a11y_parent([self zenitWindowId], element.handle) == self.handle &&
            zenit_a11y_row_index_range([self zenitWindowId], element.handle, &index, &span))
            return index;
        return NSNotFound;
    }
    return [super accessibilityIndexOfChild:child];
}

- (NSArray *)accessibilityRows {
    uint32_t count = 0;
    if ([self zenitCollectionCount:&count first:NULL visible:NULL])
        return [self zenitCollectionRowsFrom:0 count:count];
    uint32_t wid = [self zenitWindowId];
    NSMutableArray *rows = [NSMutableArray array];
    for (ZenitA11yElement *child in [self accessibilityChildren]) {
        int role = zenit_a11y_role(wid, child.handle);
        // listitem on macOS is AXRow: if not counted, list AXRowCount = 0,
        // VoiceOver speaks 0 items (VirtualList measured).
        if (role == ZenitA11yTreeRoleTreeitem || role == ZenitA11yTreeRoleListitem) {
            [rows addObject:child];
            continue;
        }
        if (role != ZenitA11yTreeRoleRow) continue;
        BOOL isHeaderRow = NO;
        for (ZenitA11yElement *cell in [child accessibilityChildren]) {
            if (zenit_a11y_role(wid, cell.handle) == ZenitA11yTreeRoleColumnheader) {
                isHeaderRow = YES;
                break;
            }
        }
        if (!isHeaderRow) [rows addObject:child];
    }
    return rows;
}

- (NSArray *)accessibilitySelectedRows {
    // Collection has no selection model: don't iterate all rows.
    if ([self zenitCollectionCount:NULL first:NULL visible:NULL]) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (ZenitA11yElement *row in [self accessibilityRows])
        if ([row isAccessibilitySelected]) [rows addObject:row];
    return rows;
}

- (NSArray *)accessibilityColumns {
    // Collection is single column, no header: don't iterate all rows.
    if ([self zenitCollectionCount:NULL first:NULL visible:NULL]) return @[];
    NSMutableArray *columns = [NSMutableArray array];
    for (ZenitA11yElement *child in [self accessibilityChildren]) {
        int role = zenit_a11y_role([self zenitWindowId], child.handle);
        if (role == ZenitA11yTreeRoleColumnheader) {
            [columns addObject:child];
        } else if (role == ZenitA11yTreeRoleRow) {
            for (ZenitA11yElement *cell in [child accessibilityChildren]) {
                if (zenit_a11y_role([self zenitWindowId], cell.handle) == ZenitA11yTreeRoleColumnheader)
                    [columns addObject:cell];
            }
        }
    }
    return columns;
}

- (NSArray *)accessibilityVisibleRows {
    uint32_t count = 0, first = 0, len = 0;
    if ([self zenitCollectionCount:&count first:&first visible:&len])
        return [self zenitCollectionRowsFrom:first count:len];
    return [self accessibilityRows];
}
- (NSArray *)accessibilityVisibleColumns { return [self accessibilityColumns]; }
- (NSInteger)accessibilityRowCount {
    // Virtualized collection declares logical total, report total (tree
    // has only visible rows).
    uint32_t declared = zenit_a11y_set_size([self zenitWindowId], self.handle);
    if (declared > 0) return (NSInteger)declared;
    return (NSInteger)[[self accessibilityRows] count];
}
- (NSInteger)accessibilityColumnCount { return (NSInteger)[[self accessibilityColumns] count]; }

- (NSInteger)accessibilityIndex {
    uint32_t index = 0, span = 0;
    uint32_t wid = [self zenitWindowId];
    if (zenit_a11y_row_index_range(wid, self.handle, &index, &span)) return (NSInteger)index;
    if (zenit_a11y_column_index_range(wid, self.handle, &index, &span)) return (NSInteger)index;
    return NSNotFound;
}

- (NSArray *)accessibilityColumnHeaderUIElements { return [self accessibilityColumns]; }

- (NSArray *)accessibilityVisibleCells {
    NSMutableArray *cells = [NSMutableArray array];
    uint32_t wid = [self zenitWindowId];
    uint32_t count = 0;
    BOOL collection = [self zenitCollectionCount:&count first:NULL visible:NULL];
    for (ZenitA11yElement *row in (collection ? [self accessibilityVisibleRows] : [self accessibilityRows])) {
        for (ZenitA11yElement *cell in [row accessibilityChildren]) {
            int role = zenit_a11y_role(wid, cell.handle);
            if (role == ZenitA11yTreeRoleCell || role == ZenitA11yTreeRoleRowheader)
                [cells addObject:cell];
        }
    }
    return cells;
}

- (id)accessibilityCellForColumn:(NSInteger)column row:(NSInteger)row {
    if (column < 0 || row < 0) return nil;
    uint32_t count = 0;
    if ([self zenitCollectionCount:&count first:NULL visible:NULL]) {
        if (column != 0 || (uint64_t)row >= count) return nil;
        ZenitA11yElement *rowElement = [[self zenitCollectionRowsFrom:(uint32_t)row count:1] firstObject];
        return [[rowElement accessibilityChildren] firstObject];
    }
    uint32_t wid = [self zenitWindowId];
    for (ZenitA11yElement *rowElement in [self accessibilityRows]) {
        uint32_t rowIndex = 0, rowSpan = 0;
        if (!zenit_a11y_row_index_range(wid, rowElement.handle, &rowIndex, &rowSpan) ||
            (uint32_t)row < rowIndex || (uint64_t)row >= (uint64_t)rowIndex + rowSpan) continue;
        for (ZenitA11yElement *cell in [rowElement accessibilityChildren]) {
            uint32_t columnIndex = 0, columnSpan = 0;
            if (zenit_a11y_column_index_range(wid, cell.handle, &columnIndex, &columnSpan) &&
                (uint32_t)column >= columnIndex &&
                (uint64_t)column < (uint64_t)columnIndex + columnSpan)
                return cell;
        }
    }
    return nil;
}

// AXScrollArea AXContents (NSScrollView reports documentView):
// scroll content is subelements.
- (NSArray *)accessibilityContents {
    return [self accessibilityChildren];
}

- (NSArray *)accessibilityTabs {
    return [self zenitChildrenWithRoles:[NSIndexSet indexSetWithIndex:ZenitA11yTreeRoleTab]];
}

- (id)accessibilityParent {
    return self.accessibilityParentObject ?: NSAccessibilityUnignoredAncestor(self.parentView);
}

- (id)accessibilityWindow { return self.parentView.window; }
- (id)accessibilityTopLevelUIElement { return self.parentView.window; }

- (NSRect)accessibilityFrame {
    NSView *v = self.parentView;
    if (!v) return NSZeroRect;
    float x = 0, y = 0, width = 0, height = 0;
    if (!zenit_a11y_frame([self zenitWindowId], self.handle, &x, &y, &width, &height)) return NSZeroRect;
    // Zenit layout is top-left/y-down; AppKit views are bottom-left/y-up.
    NSRect local = NSMakeRect(x, v.bounds.size.height - y - height, width, height);
    return zenitLogicalScreenRect(wrapperForWindow(v.window),x,y,width,height);
}

- (NSPoint)accessibilityActivationPoint {
    NSRect frame = [self accessibilityFrame];
    return NSMakePoint(NSMidX(frame), NSMidY(frame));
}

- (id)accessibilityHitTest:(NSPoint)point {
    return [(MetalView *)self.parentView accessibilityHitTest:point];
}

// Cull attributes by role. NSAccessibilityElement reports all
// implemented accessors as attributes, pre-refactor text box had
// AXRows/AXTabs/AXCellForColumnAndRow (axprobe measured), assistive
// tech asks as table/tab group. Gate by role like AccessKit.
- (BOOL)zenitAllowsStructuralSelector:(SEL)selector handled:(BOOL *)handled {
    *handled = YES;
    uint32_t wid = [self zenitWindowId];
    int role = zenit_a11y_role(wid, self.handle);
    NSAccessibilityRole nsRole = [self accessibilityRole];
    BOOL isTable = [nsRole isEqualToString:NSAccessibilityTableRole];
    BOOL isCollection = isTable || [nsRole isEqualToString:NSAccessibilityListRole] ||
        [nsRole isEqualToString:NSAccessibilityOutlineRole];
    if (selector == @selector(accessibilityRows) || selector == @selector(accessibilityVisibleRows) ||
        selector == @selector(accessibilitySelectedRows) || selector == @selector(accessibilityRowCount))
        return isCollection;
    if (selector == @selector(accessibilityColumns) || selector == @selector(accessibilityVisibleColumns) ||
        selector == @selector(accessibilityColumnCount) || selector == @selector(accessibilityColumnHeaderUIElements) ||
        selector == @selector(accessibilityVisibleCells) || selector == @selector(accessibilityCellForColumn:row:))
        return isTable;
    if (selector == @selector(accessibilityTabs))
        return [nsRole isEqualToString:NSAccessibilityTabGroupRole];
    if (selector == @selector(accessibilityContents))
        return [nsRole isEqualToString:NSAccessibilityScrollAreaRole];
    if (selector == @selector(accessibilitySelectedChildren))
        return isCollection || role == ZenitA11yTreeRoleTabs || role == ZenitA11yTreeRoleRadioGroup ||
            role == ZenitA11yTreeRoleMenu || role == ZenitA11yTreeRoleMenubar || role == ZenitA11yTreeRoleCombobox;
    if (selector == @selector(accessibilityIndex)) {
        uint32_t index = 0, span = 0;
        return [nsRole isEqualToString:NSAccessibilityRowRole] ||
            zenit_a11y_row_index_range(wid, self.handle, &index, &span) ||
            zenit_a11y_column_index_range(wid, self.handle, &index, &span);
    }
    if (selector == @selector(accessibilityRowIndexRange)) {
        uint32_t index = 0, span = 0;
        return zenit_a11y_row_index_range(wid, self.handle, &index, &span) != 0;
    }
    if (selector == @selector(accessibilityColumnIndexRange)) {
        uint32_t index = 0, span = 0;
        return zenit_a11y_column_index_range(wid, self.handle, &index, &span) != 0;
    }
    if (selector == @selector(accessibilitySortDirection))
        return role == ZenitA11yTreeRoleColumnheader || role == ZenitA11yTreeRoleRowheader;
    if (selector == @selector(accessibilityDisclosureLevel))
        return role == ZenitA11yTreeRoleTreeitem || role == ZenitA11yTreeRoleRow || role == ZenitA11yTreeRoleHeading;
    if (selector == @selector(accessibilityMinValue) || selector == @selector(accessibilityMaxValue))
        return zenit_a11y_numeric_value(wid, self.handle, NULL, NULL, NULL) != 0;
    if (selector == @selector(isAccessibilityModal))
        return role == ZenitA11yTreeRoleDialog || role == ZenitA11yTreeRoleAlertdialog;
    if (selector == @selector(accessibilityPlaceholderValue))
        return (zenit_a11y_text_capabilities(wid, self.handle) & 0x1) != 0 || role == ZenitA11yTreeRoleCombobox;
    *handled = NO;
    return NO;
}

- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    BOOL handled = NO;
    BOOL allowed = [self zenitAllowsStructuralSelector:selector handled:&handled];
    if (handled) return allowed;
    uint8_t actions = zenit_a11y_actions([self zenitWindowId], self.handle);
    if (selector == @selector(accessibilityPerformPress))
        return (actions & (ZenitA11yActionBitPress | ZenitA11yActionBitToggle)) != 0;
    if (selector == @selector(accessibilityPerformIncrement))
        return (actions & ZenitA11yActionBitIncrement) != 0;
    if (selector == @selector(accessibilityPerformDecrement))
        return (actions & ZenitA11yActionBitDecrement) != 0;
    if (selector == @selector(accessibilitySelectedTextRange) ||
        selector == @selector(accessibilitySelectedText) ||
        selector == @selector(accessibilityNumberOfCharacters) ||
        selector == @selector(accessibilityVisibleCharacterRange) ||
        selector == @selector(accessibilityStringForRange:) ||
        selector == @selector(accessibilityAttributedStringForRange:) ||
        selector == @selector(accessibilitySelectedTextRanges) ||
        selector == @selector(accessibilityRangeForIndex:) ||
        selector == @selector(accessibilityInsertionPointLineNumber) ||
        selector == @selector(accessibilityRangeForLine:) ||
        selector == @selector(accessibilityLineForIndex:)) {
        return (zenit_a11y_text_capabilities([self zenitWindowId], self.handle) & 0x1) != 0;
    }
    if (selector == @selector(setAccessibilitySelectedTextRange:)) {
        return (zenit_a11y_text_capabilities([self zenitWindowId], self.handle) & 0x2) != 0;
    }
    if (selector == @selector(setAccessibilityValue:)) {
        uint8_t caps = zenit_a11y_text_capabilities([self zenitWindowId], self.handle);
        return (caps & 0x4) != 0 ||
            (zenit_a11y_numeric_capabilities([self zenitWindowId], self.handle) & 0x2) != 0;
    }
    if (selector == @selector(accessibilityRangeForPosition:) ||
        selector == @selector(accessibilityFrameForRange:)) {
        return (zenit_a11y_text_capabilities([self zenitWindowId], self.handle) & 0x8) != 0;
    }
    if (selector == @selector(setAccessibilityFocused:)) {
        uint32_t state = zenit_a11y_state([self zenitWindowId], self.handle);
        return (state & ZenitA11yStateFocused) != 0 ||
            ((state & (ZenitA11yStateFocusable | ZenitA11yStateDisabled | ZenitA11yStateHidden)) ==
             ZenitA11yStateFocusable);
    }
    if (selector == @selector(isAccessibilityExpanded)) {
        return (zenit_a11y_state([self zenitWindowId], self.handle) & ZenitA11yStateExpandedPresent) != 0;
    }
    return [super isAccessibilitySelectorAllowed:selector];
}

// New accessor coverage gaps: invalid/busy/haspopup, macOS 26
// heading level. Use old property interface, other attributes via
// AppKit from new accessors (Chromium AXPlatformNodeCocoa mixes).
static NSString *const kZenitAXInvalid = @"AXInvalid";
static NSString *const kZenitAXElementBusy = @"AXElementBusy";
static NSString *const kZenitAXHasPopup = @"AXHasPopup";

- (NSArray *)accessibilityAttributeNames {
    NSMutableArray *names = [[super accessibilityAttributeNames] mutableCopy] ?: [NSMutableArray array];
    uint32_t wid = [self zenitWindowId];
    uint32_t state = zenit_a11y_state(wid, self.handle);
    if ((state & ZenitA11yStateInvalid) != 0) [names addObject:kZenitAXInvalid];
    if ((state & ZenitA11yStateBusy) != 0) [names addObject:kZenitAXElementBusy];
    if ((state & ZenitA11yStateHasPopup) != 0) [names addObject:kZenitAXHasPopup];
    if (@available(macOS 26.0, *)) {
        if (zenit_a11y_role(wid, self.handle) == ZenitA11yTreeRoleHeading && zenit_a11y_level(wid, self.handle) > 0)
            [names addObject:NSAccessibilityHeadingLevelAttribute];
    }
    if ([self zenitExposesScrollToVisibleAttribute]) [names addObject:@"AXScrollToVisible"];
    return names;
}

// Parameterized attribute names skip isAccessibilitySelectorAllowed:,
// separately filter table-specific items.
- (NSArray *)accessibilityParameterizedAttributeNames {
    NSArray *names = [super accessibilityParameterizedAttributeNames] ?: @[];
    if ([[self accessibilityRole] isEqualToString:NSAccessibilityTableRole]) return names;
    return [names filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        (void)bindings;
        return ![name isEqualToString:NSAccessibilityCellForColumnAndRowParameterizedAttribute];
    }]];
}

static BOOL zenitAXTraceEnabled(void) {
    static int on = -1;
    if (on < 0) on = getenv("ZENIT_DEBUG_AXTRACE") ? 1 : 0;
    return on == 1;
}

- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)attribute forParameter:(id)parameter {
    if (zenitAXTraceEnabled())
        fprintf(stderr, "[AXTRACE] %.3f h=%llu param %s\n", CACurrentMediaTime(), (unsigned long long)self.handle, attribute.UTF8String);
    return [super accessibilityAttributeValue:attribute forParameter:parameter];
}

- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)attribute {
    if (zenitAXTraceEnabled()) {
        NSString *label = [self accessibilityLabel] ?: ([[self accessibilityValue] isKindOfClass:[NSString class]] ? [self accessibilityValue] : @"");
        fprintf(stderr, "[AXTRACE] %.3f h=%llu role=%s name=%s attr %s\n", CACurrentMediaTime(), (unsigned long long)self.handle,
                [[self accessibilityRole] UTF8String], label.UTF8String, attribute.UTF8String);
    }
    uint32_t wid = [self zenitWindowId];
    if ([attribute isEqualToString:kZenitAXInvalid])
        return (zenit_a11y_state(wid, self.handle) & ZenitA11yStateInvalid) != 0 ? @"true" : @"false";
    if ([attribute isEqualToString:kZenitAXElementBusy])
        return @((zenit_a11y_state(wid, self.handle) & ZenitA11yStateBusy) != 0);
    if ([attribute isEqualToString:kZenitAXHasPopup])
        return @((zenit_a11y_state(wid, self.handle) & ZenitA11yStateHasPopup) != 0);
    if (@available(macOS 26.0, *)) {
        if ([attribute isEqualToString:NSAccessibilityHeadingLevelAttribute]) {
            uint16_t level = zenit_a11y_level(wid, self.handle);
            return level > 0 ? @(level) : nil;
        }
    }
    return [super accessibilityAttributeValue:attribute];
}

// AXScrollToVisible: VoiceOver calls when cursor to offscreen
// element. macOS 26 SDK public NSAccessibilityScrollToVisibleAction,
// string value valid old systems. New protocol no method, use old
// action interface. Any element supports (static text, disabled).
static NSString *const kZenitAXScrollToVisible = @"AXScrollToVisible";

- (NSArray *)accessibilityActionNames {
    NSArray *names = [super accessibilityActionNames] ?: @[];
    return [names arrayByAddingObject:kZenitAXScrollToVisible];
}

- (void)accessibilityPerformAction:(NSAccessibilityActionName)action {
    if ([action isEqualToString:kZenitAXScrollToVisible]) {
        [self zenitScrollToVisible];
        return;
    }
    [super accessibilityPerformAction:action];
}

// Collection items: offset committed here (AX callback) to a11y
// layer, same service window frame/visible row reads immediately
// reflect new position; component scroll state in deferred
// perform_action. Normal nodes: commit returns 0, deferred scroll.
- (void)zenitScrollToVisible {
    uint32_t wid = [self zenitWindowId];
    ZenitAXHandle handle = self.handle;
    (void)zenit_a11y_commit_scroll_to_visible(wid, handle);
    (void)zenitA11yRunMutation(^BOOL {
        return zenit_a11y_perform_action(wid, handle, ZenitA11yActionScrollToVisible) != 0;
    });
}

// NSTableView cell exposes AXScrollToVisible as settable property,
// VoiceOver each step sets it (lldb breakpoint measured, docs
// section 12.2). Collection items expose same; other properties back
// to AppKit.
- (BOOL)zenitExposesScrollToVisibleAttribute {
    return zenitA11yIsItemHandle(self.handle) &&
        zenit_a11y_role([self zenitWindowId], self.handle) == ZenitA11yTreeRoleCell;
}

- (BOOL)accessibilityIsAttributeSettable:(NSAccessibilityAttributeName)attribute {
    if ([attribute isEqualToString:kZenitAXScrollToVisible] && [self zenitExposesScrollToVisibleAttribute])
        return YES;
    return [super accessibilityIsAttributeSettable:attribute];
}

- (void)accessibilitySetValue:(id)value forAttribute:(NSAccessibilityAttributeName)attribute {
    if ([attribute isEqualToString:kZenitAXScrollToVisible] && [self zenitExposesScrollToVisibleAttribute]) {
        [self zenitScrollToVisible];
        return;
    }
    [super accessibilitySetValue:value forAttribute:attribute];
}

- (BOOL)accessibilityPerformPress {
    uint32_t wid = [self zenitWindowId];
    uint8_t actions = zenit_a11y_actions(wid, self.handle);
    uint8_t action = (actions & ZenitA11yActionBitToggle) ? ZenitA11yActionToggle : ZenitA11yActionPress;
    ZenitAXHandle handle = self.handle;
    return zenitA11yRunMutation(^BOOL { return zenit_a11y_perform_action(wid, handle, action) != 0; });
}

- (BOOL)accessibilityPerformIncrement {
    uint32_t wid = [self zenitWindowId];
    ZenitAXHandle handle = self.handle;
    return zenitA11yRunMutation(^BOOL { return zenit_a11y_perform_action(wid, handle, ZenitA11yActionIncrement) != 0; });
}

- (BOOL)accessibilityPerformDecrement {
    uint32_t wid = [self zenitWindowId];
    ZenitAXHandle handle = self.handle;
    return zenitA11yRunMutation(^BOOL { return zenit_a11y_perform_action(wid, handle, ZenitA11yActionDecrement) != 0; });
}

- (NSRange)accessibilitySelectedTextRange {
    uint32_t start = 0, end = 0, caret = 0;
    uint32_t wid = [self zenitWindowId];
    if (!zenit_a11y_text_selection(wid, self.handle, &start, &end, &caret)) return NSMakeRange(NSNotFound, 0);
    NSString *text = zenitA11yCopyString(zenit_a11y_value, wid, self.handle) ?: @"";
    NSUInteger utf16Start = zenitA11yUTF16OffsetForUTF8(text, start);
    NSUInteger utf16End = zenitA11yUTF16OffsetForUTF8(text, end);
    if (utf16Start == NSNotFound || utf16End == NSNotFound) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(MIN(utf16Start, utf16End), MAX(utf16Start, utf16End) - MIN(utf16Start, utf16End));
}

- (void)setAccessibilitySelectedTextRange:(NSRange)range {
    uint32_t wid = [self zenitWindowId];
    NSString *text = zenitA11yCopyString(zenit_a11y_value, wid, self.handle) ?: @"";
    NSRange safe = zenitA11yClampedRange(range, text.length);
    if (safe.location == NSNotFound) return;
    uint32_t start = zenitA11yUTF8OffsetForUTF16(text, safe.location);
    uint32_t end = zenitA11yUTF8OffsetForUTF16(text, NSMaxRange(safe));
    ZenitAXHandle handle = self.handle;
    (void)zenitA11yRunMutation(^BOOL { return zenit_a11y_set_text_selection(wid, handle, start, end) != 0; });
}

- (NSString *)accessibilitySelectedText {
    NSString *text = zenitA11yCopyString(zenit_a11y_value, [self zenitWindowId], self.handle) ?: @"";
    NSRange range = [self accessibilitySelectedTextRange];
    if (!zenitA11yRangeFitsLength(range, text.length)) return nil;
    return [text substringWithRange:range];
}

- (NSInteger)accessibilityNumberOfCharacters {
    uint32_t start = 0, end = 0, caret = 0;
    uint32_t wid = [self zenitWindowId];
    if (!zenit_a11y_text_selection(wid, self.handle, &start, &end, &caret)) return 0;
    return (NSInteger)(zenitA11yCopyString(zenit_a11y_value, wid, self.handle) ?: @"").length;
}

- (NSRange)accessibilityVisibleCharacterRange {
    uint32_t start = 0, end = 0;
    uint32_t wid = [self zenitWindowId];
    NSString *text = zenitA11yCopyString(zenit_a11y_value, wid, self.handle) ?: @"";
    if (!zenit_a11y_text_visible_range(wid, self.handle, &start, &end))
        return NSMakeRange(0, text.length);
    NSUInteger start16 = zenitA11yUTF16OffsetForUTF8(text, start);
    NSUInteger end16 = zenitA11yUTF16OffsetForUTF8(text, end);
    if (start16 == NSNotFound || end16 == NSNotFound) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(MIN(start16, end16), MAX(start16, end16) - MIN(start16, end16));
}

- (NSArray<NSValue *> *)accessibilitySelectedTextRanges {
    NSRange range = [self accessibilitySelectedTextRange];
    return range.location == NSNotFound ? @[] : @[[NSValue valueWithRange:range]];
}

- (NSString *)accessibilityStringForRange:(NSRange)range {
    NSString *text = zenitA11yCopyString(zenit_a11y_value, [self zenitWindowId], self.handle) ?: @"";
    if (!zenitA11yRangeFitsLength(range, text.length)) return nil;
    return [text substringWithRange:range];
}

- (NSAttributedString *)accessibilityAttributedStringForRange:(NSRange)range {
    NSString *substring = [self accessibilityStringForRange:range];
    return substring ? [[NSAttributedString alloc] initWithString:substring] : nil;
}

- (NSRange)accessibilityRangeForIndex:(NSInteger)index {
    NSString *text = zenitA11yCopyString(zenit_a11y_value, [self zenitWindowId], self.handle) ?: @"";
    if (index < 0 || (NSUInteger)index > text.length) return NSMakeRange(NSNotFound, 0);
    if ((NSUInteger)index == text.length) return NSMakeRange(text.length, 0);
    return [text rangeOfComposedCharacterSequenceAtIndex:(NSUInteger)index];
}

- (NSRange)accessibilityRangeForPosition:(NSPoint)point {
    NSView *view = self.parentView;
    if (!view || !view.window) return NSMakeRange(NSNotFound, 0);
    NSPoint windowPoint = [view.window convertPointFromScreen:point];
    NSPoint local = [view convertPoint:windowPoint fromView:nil];
    float zenitX = (float)local.x;
    float zenitY = (float)(view.bounds.size.height - local.y);
    uint32_t start = 0, end = 0;
    uint32_t wid = [self zenitWindowId];
    if (!zenit_a11y_text_range_at_point(wid, self.handle, zenitX, zenitY, &start, &end))
        return NSMakeRange(NSNotFound, 0);
    NSString *text = zenitA11yCopyString(zenit_a11y_value, wid, self.handle) ?: @"";
    NSUInteger start16 = zenitA11yUTF16OffsetForUTF8(text, start);
    NSUInteger end16 = zenitA11yUTF16OffsetForUTF8(text, end);
    if (start16 == NSNotFound || end16 == NSNotFound) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(MIN(start16, end16), MAX(start16, end16) - MIN(start16, end16));
}

- (NSRect)accessibilityFrameForRange:(NSRange)range {
    NSView *view = self.parentView;
    if (!view || !view.window || range.location == NSNotFound) return NSZeroRect;
    uint32_t wid = [self zenitWindowId];
    NSString *text = zenitA11yCopyString(zenit_a11y_value, wid, self.handle) ?: @"";
    NSRange safe = zenitA11yClampedRange(range, text.length);
    if (safe.location == NSNotFound) return NSZeroRect;
    uint32_t start = zenitA11yUTF8OffsetForUTF16(text, safe.location);
    uint32_t end = zenitA11yUTF8OffsetForUTF16(text, NSMaxRange(safe));
    float x = 0, y = 0, width = 0, height = 0;
    if (!zenit_a11y_text_frame(wid, self.handle, start, end, &x, &y, &width, &height))
        return NSZeroRect;
    NSRect local = NSMakeRect(x, view.bounds.size.height - y - height, width, height);
    return [view.window convertRectToScreen:[view convertRect:local toView:nil]];
}

- (NSInteger)accessibilityInsertionPointLineNumber {
    uint32_t start = 0, end = 0, caret = 0;
    uint32_t wid = [self zenitWindowId];
    if (!zenit_a11y_text_selection(wid, self.handle, &start, &end, &caret)) return NSNotFound;
    NSString *text = zenitA11yCopyString(zenit_a11y_value, wid, self.handle) ?: @"";
    NSUInteger caret16 = zenitA11yUTF16OffsetForUTF8(text, caret);
    if (caret16 == NSNotFound) return NSNotFound;
    __block NSInteger line = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, MIN(caret16, text.length))
                             options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(__unused NSString *substring, __unused NSRange substringRange,
                                       __unused NSRange enclosingRange, __unused BOOL *stop) { line++; }];
    return MAX(line - 1, 0);
}

- (NSRange)accessibilityRangeForLine:(NSInteger)line {
    if (line < 0) return NSMakeRange(NSNotFound, 0);
    NSString *text = zenitA11yCopyString(zenit_a11y_value, [self zenitWindowId], self.handle) ?: @"";
    __block NSInteger current = 0;
    __block NSRange result = NSMakeRange(NSNotFound, 0);
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(__unused NSString *substring, NSRange substringRange,
                                       __unused NSRange enclosingRange, BOOL *stop) {
        if (current == line) { result = substringRange; *stop = YES; }
        current++;
    }];
    if (text.length == 0 && line == 0) return NSMakeRange(0, 0);
    return result;
}

- (NSInteger)accessibilityLineForIndex:(NSInteger)index {
    NSString *text = zenitA11yCopyString(zenit_a11y_value, [self zenitWindowId], self.handle) ?: @"";
    if (index < 0 || (NSUInteger)index > text.length) return NSNotFound;
    __block NSInteger line = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, (NSUInteger)index)
                             options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(__unused NSString *substring, __unused NSRange substringRange,
                                       __unused NSRange enclosingRange, __unused BOOL *stop) { line++; }];
    return MAX(line - 1, 0);
}

@end

@interface MetalView (ZenitA11y)
- (id)zenitA11yRootParent;
@end

@implementation MetalView (ZenitA11y)

// Debug switch ZENIT_DEBUG_AXTRACE=1: each property/parameterized
// request from assistive tech to stderr. Real machine VoiceOver
// debug (2026-10-01 confirmed 'only reach first' is host grouping
// structure not data). No env var = one static check.
- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)attribute {
    if (zenitAXTraceEnabled())
        fprintf(stderr, "[AXTRACE] %.3f HOST attr %s\n", CACurrentMediaTime(), attribute.UTF8String);
    return [super accessibilityAttributeValue:attribute];
}

- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)attribute forParameter:(id)parameter {
    if (zenitAXTraceEnabled())
        fprintf(stderr, "[AXTRACE] %.3f HOST param %s %s\n", CACurrentMediaTime(), attribute.UTF8String,
                [[parameter description] UTF8String]);
    return [super accessibilityAttributeValue:attribute forParameter:parameter];
}

- (id)zenitA11yElementForHandle:(ZenitAXHandle)handle accessibilityParent:(id)parent {
    if (handle == ZENIT_A11Y_INVALID_HANDLE) return nil;
    NSNumber *key = @(handle);
    ZenitA11yElement *element = self.zenitA11yElementCache[key];
    if (!element) {
        element = [ZenitA11yElement elementForHandle:handle
                                         parentView:self
                                accessibilityParent:parent];
        self.zenitA11yElementCache[key] = element;
    } else {
        element.parentView = self;
        element.accessibilityParentObject = parent;
    }
    return element;
}

- (id)zenitA11yElementForHandle:(ZenitAXHandle)handle {
    if (handle == ZENIT_A11Y_INVALID_HANDLE) return nil;
    uint32_t wid = zenitA11yWindowIdForView(self);
    if (!zenit_a11y_exists(wid, handle)) return nil;
    ZenitAXHandle parentHandle = zenit_a11y_parent(wid, handle);
    id parent = [self zenitA11yRootParent];
    if (parentHandle != ZENIT_A11Y_INVALID_HANDLE) {
        // Prefer an already retained parent; recursive creation is bounded by
        // the valid retained tree and gives focus notifications the right AX
        // ancestry even before VoiceOver has pulled children.
        parent = [self zenitA11yElementForHandle:parentHandle] ?: [self zenitA11yRootParent];
    }
    return [self zenitA11yElementForHandle:handle accessibilityParent:parent];
}

- (NSArray *)zenitAccessibilityRootChildren {
    uint32_t wid = zenitA11yWindowIdForView(self);
    // Retain live virtual elements, but never let handles from an earlier tree
    // accumulate or alias a later generational handle.
    for (NSNumber *key in [self.zenitA11yElementCache.allKeys copy]) {
        if (!zenit_a11y_exists(wid, (ZenitAXHandle)key.unsignedLongLongValue)) {
            [self.zenitA11yElementCache removeObjectForKey:key];
        }
    }
    int n = zenit_a11y_root_count(wid);
    if (n <= 0) {
        // No registered a11y_tree (test mode or cx unhooked), fall to super.
        return [super accessibilityChildren];
    }
    NSMutableArray *kids = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        ZenitAXHandle h = zenit_a11y_root_at(wid, i);
        if (h == ZENIT_A11Y_INVALID_HANDLE) continue;
        [kids addObject:[self zenitA11yElementForHandle:h accessibilityParent:[self zenitA11yRootParent]]];
    }
    return kids;
}

- (NSArray *)accessibilityChildren {
    return [self zenitAccessibilityRootChildren];
}

- (NSArray *)accessibilityChildrenInNavigationOrder {
    return [self zenitAccessibilityRootChildren];
}

- (NSArray *)accessibilityVisibleChildren {
    return [self zenitAccessibilityRootChildren];
}

- (id)accessibilityFocusedUIElement {
    ZenitAXHandle focused = zenit_a11y_focused(zenitA11yWindowIdForView(self));
    return focused == ZENIT_A11Y_INVALID_HANDLE ? nil : [self zenitA11yElementForHandle:focused];
}

- (id)accessibilityHitTest:(NSPoint)point {
    if (!self.window) return [self zenitA11yRootParent];
    NSPoint local = zenitLogicalScreenPoint(wrapperForWindow(self.window),point);
    ZenitAXHandle handle = zenit_a11y_hit_test(
        zenitA11yWindowIdForView(self),
        (float)local.x,
        (float)local.y
    );
    return handle == ZENIT_A11Y_INVALID_HANDLE ? [self zenitA11yRootParent] : [self zenitA11yElementForHandle:handle];
}

// Host view is transparent to assistive tech (ignored): AppKit elevates accessibilityChildren
// directly to the window, like a native AppKit content view. Exposing it as an AXGroup would
// make VoiceOver at window level see only the group + traffic lights (needing VO+Shift+Down
// to enter), and add a meaningless nesting level with a hardcoded English name.
- (BOOL)isAccessibilityElement {
    return NO;
}

/// Virtual subelements parent after transparency: nearest non-
/// transparent ancestor (usually window).
- (id)zenitA11yRootParent {
    return NSAccessibilityUnignoredAncestor(self) ?: self.window;
}

@end

typedef struct {
    unsigned long long sequence;
    float x;
    float y;
    float dx;
    float dy;
    uint32_t modifiers;
} MouseMovePacket;

typedef struct {
    unsigned long long sequence;
    float x;
    float y;
    int button;  // 0=left, 1=right, 2=middle
    BOOL pressed;
    // Original NSEventModifierFlags. Shift-add-select, Cmd-deep-select,
    // Ctrl-frame-select depend; missing reads false on real machine
    // (synthetic path works bypasses bridge - why e2e all green, real
    // broken).
    uint32_t modifiers;
} MouseButtonPacket;

typedef struct {
    unsigned long long sequence;
    float x;
    float y;
    float dx;
    float dy;
    uint8_t phase;     // zenitScrollPhaseCode
    uint8_t momentum;  // zenitMomentumPhaseCode
    uint32_t modifiers;
} ScrollEventPacket;

// Align with system_sdk.events.ScrollPhase: 0 none, 1 may_begin,
// 2 began, 3 changed, 4 ended, 5 cancelled. Momentum phase none
// (marked by momentumPhase).
static uint8_t zenitScrollPhaseCode(NSEvent *event) {
    switch (event.phase) {
        case NSEventPhaseNone: return 0;
        case NSEventPhaseMayBegin: return 1;
        case NSEventPhaseBegan: return 2;
        case NSEventPhaseChanged:
        case NSEventPhaseStationary: return 3;
        case NSEventPhaseEnded: return 4;
        case NSEventPhaseCancelled: return 5;
        // NSEventPhase bitmask: OR combined bits still in-gesture, not
        // mouse wheel.
        default: return 3;
    }
}

// Align with system_sdk.events.MomentumPhase: 0 none, 1 began,
// 2 changed, 3 ended.
static uint8_t zenitMomentumPhaseCode(NSEvent *event) {
    switch (event.momentumPhase) {
        case NSEventPhaseNone: return 0;
        case NSEventPhaseBegan: return 1;
        case NSEventPhaseEnded:
        case NSEventPhaseCancelled: return 3;
        // Changed/Stationary/unknown combo: momentum still ongoing
        default: return 2;
    }
}

// Scroll deltas are logical px (scroll_area applies the offset in px). AppKit reports
// line units for non-precise wheels (~0.1 per detent, up to ~15 on fast flicks) -
// convert with 40 px/line, shared by Chromium kScrollbarPixelsPerCocoaTick,
// WebKit Scrollbar::pixelsPerLineStep, Flutter pixelsPerLine ("to match Chromium").
// Precise devices (trackpads, Magic Mouse) already report points: pass through 1:1.
// Logical points only - do not multiply by display scale (HiDPI would double speed).
static void zenitScrollDeltas(NSEvent *event, float *out_dx, float *out_dy) {
    const double scale = event.hasPreciseScrollingDeltas ? 1.0 : 40.0;
    *out_dx = (float)(event.scrollingDeltaX * scale);
    *out_dy = (float)(event.scrollingDeltaY * scale);
}

typedef struct {
    unsigned long long sequence;
    float x;
    float y;
    float magnification;
    // 0=began 1=changed 2=ended 3=cancelled
    uint8_t phase;
} MagnifyEventPacket;

typedef struct {
    unsigned long long sequence;
    uint16_t keycode;
    uint32_t modifiers;
    char character;
    BOOL pressed;
} KeyEventPacket;

// window wrapper (also NSWindowDelegate for close event)
// Borderless application windows remain keyboard/focus-capable.
@interface ZenitWindow : NSWindow
@end
@implementation ZenitWindow
- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)mask backing:(NSBackingStoreType)backing defer:(BOOL)defer {
    self=[super initWithContentRect:rect styleMask:mask backing:backing defer:defer];
    if(self) atomic_fetch_add_explicit(&g_live_windows,1,memory_order_relaxed);return self;
}
- (void)dealloc { atomic_fetch_sub_explicit(&g_live_windows,1,memory_order_relaxed); }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)toggleFullScreen:(id)sender {
    if(!(self.styleMask & NSWindowStyleMaskFullScreen) && zenitDeferFullscreenUntilDeminiaturized(self,sender)) return;
    if (!(self.styleMask & NSWindowStyleMaskFullScreen) && !zenitPrepareFullscreen(self)) return;
    if(self.styleMask & NSWindowStyleMaskFullScreen) zenitPrepareFullscreenExit(self);
    [super toggleFullScreen:sender];
}
@end

@interface WindowWrapper : NSObject <NSWindowDelegate> {
@public
    // One CVDisplayLink writer, main-thread cadence/timing snapshots.
    _Atomic(uint64_t) displayTickSequence;
    _Atomic(uint64_t) displayTickCallbackHostTime;
    _Atomic(uint64_t) displayTickTargetHostTime;
}
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) MetalView *metalView;
@property (nonatomic, strong) ZenitFullscreenHeaderHost *fullscreenHeader;
@property (nonatomic) BOOL shouldClose;
// Closing is a two-phase operation. The first user attempt is surfaced to Zig
// through shouldClose so it can resolve dirty documents. Once Zig commits, the
// same NSWindow is closed by AppKit and remains owned across the native close
// animation's retention boundary.
@property (nonatomic) BOOL closeCommitted;
@property (nonatomic) BOOL nativeCloseStarted;
@property (nonatomic) BOOL nativeCloseObserved;
@property (nonatomic) BOOL nativeCloseRetentionElapsed;
@property (nonatomic) BOOL nativeCloseCompleted;
// mouse state
@property (nonatomic) NSPoint mouseLocation;
@property (nonatomic) BOOL leftButtonPressed;
@property (nonatomic) BOOL rightButtonPressed;
@property (nonatomic) BOOL middleButtonPressed;
// keyboard state
@property (nonatomic, strong) NSMutableArray<NSValue *> *keyEventQueue;
@property (nonatomic, strong) NSString *inputText;
@property (nonatomic, strong) NSMutableArray<ZenitTextEventPacket *> *inputTextQueue;
// IME state
@property (nonatomic, strong) NSString *imePreeditText;
@property (nonatomic) uint32_t imePreeditCursorUtf16;
@property (nonatomic, strong) NSMutableArray<ZenitTextEventPacket *> *imePreeditQueue;
// preedit/commit replacementRange (UTF-8 byte range, relative
// document). ZENIT_IME_NO_REPLACEMENT sentinel = no replacement this
// time.
@property (nonatomic) uint32_t imePreeditReplaceStartUtf8;
@property (nonatomic) uint32_t imePreeditReplaceEndUtf8;
@property (nonatomic) BOOL hasImePreedit;
@property (nonatomic, strong) NSString *imeCommitText;
@property (nonatomic) uint32_t imeCommitReplaceStartUtf8;
@property (nonatomic) uint32_t imeCommitReplaceEndUtf8;
@property (nonatomic) BOOL hasImeCommit;
@property (nonatomic, strong) NSMutableArray<ZenitTextEventPacket *> *imeCommitQueue;
@property (nonatomic) float imeCursorX;
@property (nonatomic) float imeCursorY;
@property (nonatomic) float imeCursorWidth;
@property (nonatomic) float imeCursorHeight;
@property (nonatomic) BOOL hasImeCursorRect;
// Whether the focused zenit node is an editable text control. This gates only
// NSTextInputContext; raw keyDown/keyUp packets remain enabled for every UI.
@property (nonatomic) BOOL textInputEnabled;
@property (nonatomic) BOOL keyboardIsolated;
// Source bound at the last AppKit responder activation. InputMethodKit can
// otherwise expose a new source ID while continuing to emit literal ASCII.
@property (nonatomic, copy) NSString *lastKeyboardInputSource;
@property (nonatomic) unsigned long long pollSeq;
@property (nonatomic) unsigned long long lastInsertPollSeq;
@property (nonatomic) unsigned long long keyDispatchSeq;
@property (nonatomic) unsigned long long lastInsertKeyDispatchSeq;
@property (nonatomic, strong) NSString *lastInsertText;
@property (nonatomic) BOOL lastInsertHadMarked;
// native mouse moved/dragged queue; under pressure only merge
// adjacent moves.
@property (nonatomic, strong) NSMutableArray<NSValue *> *mouseMoveQueue;
// mouse button event queue (avoid polling miss same-frame press+
// release)
@property (nonatomic, strong) NSMutableArray<NSValue *> *mouseButtonQueue;
// scroll wheel state
@property (nonatomic, strong) NSMutableArray<NSValue *> *scrollEventQueue;
@property (nonatomic, strong) NSMutableArray<NSValue *> *magnifyEventQueue;
// Inspector pick mode: accept mouse move even when not key window
// (for cross-window hover)
@property (nonatomic) BOOL acceptsMouseMovedWhileInactive;
// custom titlebar drag height (logical px from window top). >0
// mouseDown in this area triggers performWindowDragWithEvent
@property (nonatomic) float titlebarDragHeight;
// titlebar right exclude width (logical px). For titlebar right
// action buttons to receive click without performWindowDragWithEvent.
@property (nonatomic) float titlebarDragRightInset;
// hit-driven drag area: mouseDown in band asks Zig if point has
// interactive control; non-zero = has, event normal not window drag.
// NULL = fall back to rect model.
@property (nonatomic, assign) int (*titlebarHitCallback)(void* ctx, float x, float y);
@property (nonatomic, assign) void* titlebarHitContext;
@property (nonatomic, assign) int (*chromeHitCallback)(void*, float, float);
@property (nonatomic, assign) void* chromeHitContext;
@property (nonatomic) BOOL chromeHideControls;
// Zoom/maximize refused; windowShouldZoom: consults this so green button,
// title-bar double-click and performZoom: stay consistent. Zero default =
// maximizable, matching an out-of-box NSWindow.
@property (nonatomic) BOOL zoomDisabled;
@property (nonatomic) BOOL chromeFullscreenTransition;
@property (nonatomic) BOOL nativeFullscreenEntering;
// Query hooks are speculative: only entries without a will/did are timed,
// independent of the header host (which may not have been configured yet).
@property (nonatomic) NSUInteger fullscreenEntryEpoch;
@property (nonatomic) CFTimeInterval fullscreenEntryDeadline;
@property (nonatomic) BOOL fullscreenEntryStarted;
@property (nonatomic) BOOL waitingForDeminiaturize;
- (void)beginFullscreenEntry:(BOOL)entering;
- (void)finishFullscreenEntry;
- (void)cancelFullscreenRestoration:(NSNotification *)notification;
- (void)reconcileFullscreenEntryEpoch:(NSUInteger)epoch atTime:(CFTimeInterval)now;
@property (nonatomic) uint32_t chromeStateGeneration;
// Resign-key callback: fires when the window goes from key to non-key, and
// reports whether the new key window belongs to this process. Floating (find/palette) closes when host
// focused, keeps when other app focused.
@property (nonatomic, assign) void (*resignKeyCallback)(void* ctx, int new_key_is_owner);
@property (nonatomic, assign) void* resignKeyContext;
// owner window (addChildWindow parent). Only for resignKey checking
// new key window is own host - child maintained by AppKit.
@property (nonatomic, weak) NSWindow* ownerWindow;
// CVDisplayLink for vsync-driven frame scheduling (C6)
@property (nonatomic) CVDisplayLinkRef displayLink;
@property (nonatomic) BOOL displayLinkRunning;
// Windowed inset follows AppKit frame notifications synchronously, including
// when the renderer is idle. Prepared fullscreen hosts own their native layout.
@property (nonatomic) BOOL hasTrafficLightsInset;
@property (nonatomic) float trafficLightsInsetX;
@property (nonatomic) float trafficLightsInsetY;
@property (nonatomic) BOOL applyingTrafficLightsInset;
@property (nonatomic, strong) NSArray<NSView *> *trafficLightsObservedViews;
@property (nonatomic, strong) NSArray<NSNumber *> *trafficLightsPreviousFrameNotifications;
- (void)applyTrafficLightsInset;
- (void)stopObservingTrafficLights;
@end
// System buttons must win over application drag regions.
static BOOL chromePointInNativeButton(WindowWrapper *w, NSPoint p) {
    for (NSWindowButton kind=NSWindowCloseButton; kind<=NSWindowZoomButton; kind++) {
        NSButton *b=[w.window standardWindowButton:kind];
        if (b && !b.hidden && NSPointInRect(p,[w.window.contentView convertRect:b.bounds fromView:b])) return YES;
    }
    return NO;
}


// Opt-in native lifecycle journal, inherited by zdoc. No project/document text.
// Global notification logging survives delegate removal during a hard destroy.
static const char *zenitFullscreenTracePath(void) {
    const char *path=getenv("ZDOC_FSH_TRACE_FILE");
    if(!path || !path[0]) path=getenv("ZENIT_FSH_TRACE_FILE");
    return path && path[0]=='/' ? path : NULL;
}
static void zenitTraceFullscreenWindow(NSWindow *window,WindowWrapper *w,const char *event) {
    const char *path=zenitFullscreenTracePath();if(!path || !window) return;
    FILE *file=fopen(path,"a");if(!file) {perror("[fullscreen-trace]");return;}
    static _Atomic uint64_t sequence=0;
    fprintf(file,"{\"seq\":%llu,\"time\":%.6f,\"pid\":%d,\"window\":%ld,\"event\":\"%s\",\"tracked\":%d,\"fullscreen\":%d,\"entering\":%d,\"transition\":%d,\"closed\":%d,\"host_active\":%d,\"content_view\":\"%p\",\"metal_parent\":\"%p\",\"header\":\"%p\",\"toolbar\":\"%p\",\"accessories\":%lu}\n",
        (unsigned long long)(atomic_fetch_add_explicit(&sequence,1,memory_order_relaxed)+1),CACurrentMediaTime(),getpid(),(long)window.windowNumber,event,w!=nil,
        !!(window.styleMask&NSWindowStyleMaskFullScreen),w.nativeFullscreenEntering,w.chromeFullscreenTransition,
        w.nativeCloseObserved,w.fullscreenHeader.active,(__bridge void *)window.contentView,
        (__bridge void *)w.metalView.superview,(__bridge void *)w.fullscreenHeader.header,
        (__bridge void *)window.toolbar,(unsigned long)window.titlebarAccessoryViewControllers.count);
    fclose(file);
}
static void zenitTraceFullscreen(WindowWrapper *w,const char *event) {
    zenitTraceFullscreenWindow(w.window,w,event);
}
static void zenitInstallFullscreenTrace(void) {
    if(!zenitFullscreenTracePath()) return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        for(NSNotificationName name in @[NSWindowWillCloseNotification,NSWindowWillEnterFullScreenNotification,
            NSWindowDidEnterFullScreenNotification,NSWindowWillExitFullScreenNotification,NSWindowDidExitFullScreenNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                NSWindow *window=note.object;if(![window isKindOfClass:ZenitWindow.class]) return;
                NSString *event=[@"notification." stringByAppendingString:note.name];
                zenitTraceFullscreenWindow(window,wrapperForWindow(window),event.UTF8String);
            }];
        }
    });
}

@implementation WindowWrapper
- (instancetype)init {
    self=[super init];if(self) {
        atomic_fetch_add_explicit(&g_live_wrappers,1,memory_order_relaxed);
        zenitInstallFullscreenTrace();
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelFullscreenRestoration:)
            name:NSApplicationDidResignActiveNotification object:nil];
    }return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self name:NSApplicationDidResignActiveNotification object:nil];[self stopObservingTrafficLights];atomic_fetch_sub_explicit(&g_live_wrappers,1,memory_order_relaxed); }

- (BOOL)windowShouldClose:(NSWindow *)sender {
    NSLog(@"[windowShouldClose] window=%@ title=%@", sender, sender.title);
    if (self.closeCommitted) {
        return YES;
    }
    self.shouldClose = YES;
    return NO; // let Zig handle dirty tabs; will retry performClose after confirm
}

- (BOOL)windowShouldZoom:(NSWindow *)sender toFrame:(NSRect)frame {
    (void)sender;(void)frame;
    // Every zoom entry point funnels through this delegate question.
    return !self.zoomDisabled;
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    NSLog(@"[windowWillClose] window=%@ title=%@", self.window, self.window.title);
    zenitTraceFullscreen(self,"windowWillClose.before");
    self.nativeCloseObserved = YES;
    // A direct NSWindow close can bypass the consumer's deferred destroy pump.
    // Release entry flags and native observers at the actual close boundary;
    // destroy repeats this idempotently when the ARC retention period ends.
    [self finishFullscreenEntry];[self.fullscreenHeader quiesceForClose];
    [self stopObservingTrafficLights];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSApplicationDidResignActiveNotification object:nil];
    zenitTraceFullscreen(self,"windowWillClose.quiesced");
    self.shouldClose = NO;
    if (self.nativeCloseRetentionElapsed) {
        self.nativeCloseCompleted = YES;
    }
    // Wake the Zig event pump. Resource destruction is intentionally deferred
    // until the native close retention boundary has also elapsed.
    macos_post_empty_event();
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    // drag to different monitor (60Hz<->120Hz) rebind display link to
    // new screen, refresh rate follows
    if (self.displayLink) {
        CGDirectDisplayID did = (CGDirectDisplayID)[self.window.screen
            .deviceDescription[@"NSScreenNumber"] unsignedIntValue];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkSetCurrentCGDisplay(self.displayLink, did);
#pragma clang diagnostic pop
    }
}

- (void)stopObservingTrafficLights {
    for(NSUInteger i=0;i<self.trafficLightsObservedViews.count;i++) {
        NSView *view=self.trafficLightsObservedViews[i];
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:view];
        view.postsFrameChangedNotifications=self.trafficLightsPreviousFrameNotifications[i].boolValue;
    }
    self.trafficLightsObservedViews=nil;self.trafficLightsPreviousFrameNotifications=nil;
}
- (void)observeTrafficLights {
    NSView *views[9];NSUInteger count=0;
    for(NSWindowButton kind=NSWindowCloseButton;kind<=NSWindowZoomButton;kind++) {
        NSView *view=[self.window standardWindowButton:kind];
        // Parent geometry can change without changing a button's local frame.
        for(int level=0;view && level<3;level++,view=view.superview) {
            BOOL found=NO;
            for(NSUInteger i=0;i<count;i++) if(views[i]==view) { found=YES;break; }
            if(!found) views[count++]=view;
        }
    }
    BOOL unchanged=self.trafficLightsObservedViews.count==count;
    for(NSUInteger i=0;unchanged && i<count;i++) unchanged=self.trafficLightsObservedViews[i]==views[i];
    if(unchanged) return; // No observer arrays/allocations on the poll fallback.
    [self stopObservingTrafficLights];
    NSMutableArray<NSView *> *observed=[NSMutableArray new];
    NSMutableArray<NSNumber *> *previous=[NSMutableArray new];
    for(NSUInteger i=0;i<count;i++) {
        NSView *view=views[i];[observed addObject:view];
        [previous addObject:@(view.postsFrameChangedNotifications)];
        view.postsFrameChangedNotifications=YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trafficLightsFrameChanged:) name:NSViewFrameDidChangeNotification object:view];
    }
    self.trafficLightsObservedViews=observed;self.trafficLightsPreviousFrameNotifications=previous;
}
- (void)trafficLightsFrameChanged:(NSNotification *)notification {
    // NSView posts synchronously from setFrameOrigin:/setFrameSize:, including
    // AppKit's _updateButtonPositions path. No dispatch, poll or render wakeup:
    // correct before returning to AppKit and before its CA transaction commits.
    [self applyTrafficLightsInset];
}
- (void)applyTrafficLightsInset {
    // The prepared fullscreen accessory owns the buttons during the handoff.
    // The legacy client-titlebar inset must not reset their positions during
    // the fullscreen resize animation (20-point vs native 23-point spacing).
    if (self.nativeCloseObserved || !self.hasTrafficLightsInset || (self.fullscreenHeader.header && !self.fullscreenHeader.pendingFullscreen) || self.applyingTrafficLightsInset) return;
    NSWindow *window = self.window;
    NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
    NSButton *miniButton = [window standardWindowButton:NSWindowMiniaturizeButton];
    NSButton *zoomButton = [window standardWindowButton:NSWindowZoomButton];
    if (!closeButton || !miniButton || !zoomButton) return;

    // fullscreen titlebar auto-hides, system arranges
    if (window.styleMask & NSWindowStyleMaskFullScreen) return;

    NSView *titlebarView = closeButton.superview;
    if (!titlebarView) return;

    self.applyingTrafficLightsInset=YES;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    @try {
        [self observeTrafficLights];
        CGFloat button_size = closeButton.frame.size.height;
        CGFloat inset_x = self.trafficLightsInsetX;

        // NSTitlebarContainerView clips subviews: buttons drawn outside
        // (layer escapes clip), hit-test doesn't. System default ~32px high,
        // placing inset_y=36 button makes origin.y negative, so the 14px button has
        // only its top 3px inside the container: the user sees the full traffic
        // lights but only the topmost strip is clickable/hoverable (measured: buttons
        // drawn at window-y 795..809, hit only works in 806..808).
        // Expand container to fit button, place inside; can't just move button.
        NSView *containerView = titlebarView.superview;
        CGFloat needed_h = self.trafficLightsInsetY + button_size / 2.0;
        if (containerView && [containerView isKindOfClass:NSClassFromString(@"NSTitlebarContainerView")]) {
            NSRect cf = containerView.frame;
            if (needed_h > cf.size.height) {
                // Container in NSThemeFrame top-aligned (higher origin.y higher),
                // growing height must shift origin down or whole thing tops outside
                // window.
                CGFloat delta = needed_h - cf.size.height;
                cf.origin.y -= delta;
                cf.size.height = needed_h;
                containerView.frame = cf;
                // titlebarView itself fills container or buttons drop out bounds
                NSRect tf = titlebarView.frame;
                tf.origin.y = 0;
                tf.size.height = needed_h;
                titlebarView.frame = tf;
            }
        }

        // titlebarView height now >= needed_h, button_y guaranteed non-
        // negative
        CGFloat button_y = titlebarView.frame.size.height - self.trafficLightsInsetY - button_size / 2.0;
        if (button_y < 0) button_y = 0;

        NSButton *buttons[3] = { closeButton, miniButton, zoomButton };
        for (int i = 0; i < 3; i++) {
            NSRect f = buttons[i].frame;
            f.origin.x = inset_x + i * 20;
            f.origin.y = button_y;
            if (!NSEqualRects(buttons[i].frame, f)) buttons[i].frame = f;
        }
    } @finally {
        [CATransaction commit];self.applyingTrafficLightsInset=NO;
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    self.chromeStateGeneration++;
    [self applyTrafficLightsInset];
}

// Only speculative queries are timed. After will-enter AppKit owns completion
// through did-enter/did-fail; a slow animation must never be dismantled by time.
// An expired query cannot lend its epoch/deadline to a new request.
- (void)beginFullscreenEntry:(BOOL)entering {
    self.nativeFullscreenEntering=self.nativeFullscreenEntering || entering;self.chromeFullscreenTransition=YES;
    CFTimeInterval now=CACurrentMediaTime();
    if(self.fullscreenEntryStarted || self.fullscreenEntryDeadline>now) return;
    // Share an unexpired deadline without shortening it. Once expired, advance
    // the epoch even if its old main-queue block has not been able to run.
    NSUInteger epoch=++self.fullscreenEntryEpoch;
    self.fullscreenEntryDeadline=now+10;
    __weak WindowWrapper *owner=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        [owner reconcileFullscreenEntryEpoch:epoch atTime:CACurrentMediaTime()];
    });
}
- (void)finishFullscreenEntry {
    self.fullscreenEntryEpoch++;self.fullscreenEntryDeadline=0;self.fullscreenEntryStarted=NO;
    self.waitingForDeminiaturize=NO;
    self.nativeFullscreenEntering=NO;self.chromeFullscreenTransition=NO;
}
- (void)reconcileFullscreenEntryEpoch:(NSUInteger)epoch atTime:(CFTimeInterval)now {
    if(epoch!=self.fullscreenEntryEpoch || self.fullscreenEntryStarted || self.fullscreenEntryDeadline==0 || now<self.fullscreenEntryDeadline) return;
    [self finishFullscreenEntry];
    if(self.window.styleMask&NSWindowStyleMaskFullScreen) {
        // A query found an already fullscreen window: keep its native hosts.
        [self.fullscreenHeader start];[self.fullscreenHeader commitBodyLayout];
        [self.fullscreenHeader requestFrame];
    } else {
        [self.fullscreenHeader finishExit];[self applyTrafficLightsInset];
        [self.metalView renderFinalResize];
    }
    self.chromeStateGeneration++;macos_post_empty_event();
}
- (void)windowDidDeminiaturize:(NSNotification *)notification {
    if(!self.waitingForDeminiaturize) return;
    // No toolbar installation or native toggle until AppKit finished restoring.
    if(self.window.miniaturized) { // Unexpected/late delivery: never loop restoration.
        [self cancelFullscreenRestoration:notification];return;
    }
    [self finishFullscreenEntry];[self.window toggleFullScreen:nil];
}

- (void)cancelFullscreenRestoration:(NSNotification *)notification {
    if(!self.waitingForDeminiaturize) return;
    [self finishFullscreenEntry];
    if(!self.fullscreenHeader.active) [self.fullscreenHeader stop];
    else {
        // post_empty_event only wakes the pump; it does not mark Cx dirty.
        // chrome_controller.syncChromeWithBackend consumes this one-shot request
        // and sets cx.needs_redraw, even without a windowChrome signal subscriber.
        [self.fullscreenHeader requestFrame];
    }
    self.chromeStateGeneration++;macos_post_empty_event();
}
- (void)windowDidMiniaturize:(NSNotification *)notification {
    [self cancelFullscreenRestoration:notification];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    zenitTraceFullscreen(self,"windowDidExitFullScreen");
    if(self.nativeCloseObserved) return;
    // AppKit still owns the transition hierarchy during delegate delivery.
    // Commit the final body layout and its matching frame together once that
    // bookkeeping has returned, instead of publishing a windowed projection
    // while the fullscreen accessory is still being reparented.
    __weak WindowWrapper *owner=self;
    ZenitFullscreenHeaderHost *host=self.fullscreenHeader;
    NSUInteger epoch=host.presentationEpoch, entryEpoch=self.fullscreenEntryEpoch;
    dispatch_async(dispatch_get_main_queue(),^{
        WindowWrapper *w=owner;
        if(!w || w.fullscreenEntryEpoch!=entryEpoch || w.fullscreenHeader!=host || host.presentationEpoch!=epoch ||
           (w.window.styleMask&NSWindowStyleMaskFullScreen)) return;
        [CATransaction begin];[CATransaction setDisableActions:YES];
        [w.window.contentView.superview layoutSubtreeIfNeeded];
        [host finishExit];
        [w finishFullscreenEntry];
        [w applyTrafficLightsInset];
        w.chromeStateGeneration++;
        [w.metalView renderFinalResize];
        [CATransaction commit];
    });
}

// Public pre-animation delegate hooks cover entries which bypass the action
// override (system Spaces/restoration). Return nil to retain AppKit animation.
- (NSArray<NSWindow *> *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window {
    if(self.nativeCloseObserved) return nil;
    [self beginFullscreenEntry:YES];
    [self.fullscreenHeader start];return nil;
}
- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)options {
    if(self.nativeCloseObserved) return options;
    [self beginFullscreenEntry:YES];
    [self.fullscreenHeader start];return options;
}
- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    zenitTraceFullscreen(self,"windowWillEnterFullScreen");
    if(self.nativeCloseObserved) return;
    [self beginFullscreenEntry:YES];
    self.fullscreenEntryStarted=YES;self.fullscreenEntryDeadline=0;self.waitingForDeminiaturize=NO;
    [self.fullscreenHeader start];
}
- (void)windowWillExitFullScreen:(NSNotification *)notification {
    zenitTraceFullscreen(self,"windowWillExitFullScreen");
    if(self.nativeCloseObserved) return;
    // An exit supersedes an incomplete entry; its old watchdog must not commit
    // body/header layout into the exit transaction.
    [self finishFullscreenEntry];self.chromeFullscreenTransition=YES;
    [self.fullscreenHeader beginExit];
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    zenitTraceFullscreen(self,"windowDidEnterFullScreen");
    if(self.nativeCloseObserved) return;
    [self finishFullscreenEntry];
    // A speculative query may have been reclaimed before a late did-enter.
    // start is idempotent and also safely does nothing before configure.
    [self.fullscreenHeader start];[self.fullscreenHeader commitBodyLayout];
    if(self.fullscreenHeader.active) {
        [CATransaction begin];[CATransaction setDisableActions:YES];
        for(NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)])
            [self.window standardWindowButton:kind.integerValue].alphaValue=1;
        [CATransaction commit];
    }
    // Covers did-enter delivered directly, including a host rebuilt after query
    // expiry: publish first paint just like reconcile's already-fullscreen path.
    [self.fullscreenHeader requestFrame];self.chromeStateGeneration++;
}
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
    zenitTraceFullscreen(self,"windowDidFailToEnterFullScreen");
    if(self.nativeCloseObserved) return;
    [self finishFullscreenEntry];[self.fullscreenHeader finishExit];
    [self applyTrafficLightsInset];self.chromeStateGeneration++;
    [self.metalView renderFinalResize];
}
- (void)windowDidFailToExitFullScreen:(NSWindow *)window {
    zenitTraceFullscreen(self,"windowDidFailToExitFullScreen");
    if(self.nativeCloseObserved) return;
    [self finishFullscreenEntry];
    [self.fullscreenHeader recoverFailedExit];self.chromeStateGeneration++;
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    // makeFirstResponder is the supported activation boundary. AppKit owns the
    // corresponding NSTextInputContext activate/deactivate calls.
    if (self.metalView && self.window.firstResponder != self.metalView) {
        [self.window makeFirstResponder:self.metalView];
    }
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (!self.resignKeyCallback) return;
    // who got key? decides float close:
    // - New key window is our owner (or any other window of this process): the
    //   user is back in the app, so close the float, matching the IDE intuition
    //   that clicking back into the editor dismisses the search box.
    // - New key window is nil or belongs to another app: the user merely switched
    //   away, so keep the float so its content is still there on return.
    // Critical: defer one beat. resignKey fires before new
    // window key, [NSApp keyWindow] nil now, 'click host' misread as
    // 'switch app'.
    __weak WindowWrapper *weakWrapper = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WindowWrapper *strongWrapper = weakWrapper;
        if (!strongWrapper) return;
        void (*cb)(void*, int) = strongWrapper.resignKeyCallback;
        void *ctx = strongWrapper.resignKeyContext;
        if (!cb || !ctx || strongWrapper.nativeCloseStarted) return;
        NSWindow *owner = strongWrapper.ownerWindow;
        NSWindow *newKey = [NSApp keyWindow];
        int is_owner = 0;
        if (newKey != nil) {
            // any process window counts back to app; owner clearer.
            is_owner = (owner != nil && newKey == owner) ? 1 : ([NSApp isActive] ? 1 : 0);
        }
        cb(ctx, is_owner);
    });
}

@end

typedef NS_ENUM(NSInteger, ZenitAccessibilityRole) {
    ZenitAccessibilityRoleNone = 0,
    ZenitAccessibilityRoleButton = 1,
    ZenitAccessibilityRoleCheckbox = 2,
    ZenitAccessibilityRoleRadio = 3,
    ZenitAccessibilityRoleTextbox = 4,
    ZenitAccessibilityRoleSwitch = 5,
    ZenitAccessibilityRoleTab = 6,
    ZenitAccessibilityRoleTabList = 7,
    ZenitAccessibilityRoleDialog = 8,
    ZenitAccessibilityRoleAlert = 9,
    ZenitAccessibilityRoleMenu = 10,
    ZenitAccessibilityRoleMenuItem = 11,
    ZenitAccessibilityRoleListBox = 12,
    ZenitAccessibilityRoleOption = 13,
    ZenitAccessibilityRoleProgressBar = 14,
    ZenitAccessibilityRoleSlider = 15,
    ZenitAccessibilityRoleHeading = 16,
    ZenitAccessibilityRoleLink = 17,
    ZenitAccessibilityRoleImage = 18,
    ZenitAccessibilityRoleList = 19,
    ZenitAccessibilityRoleListItem = 20,
};

static NSString *zenitStringFromUtf8(const char *bytes, int len) {
    if (!bytes || len <= 0) return nil;
    return [[NSString alloc] initWithBytes:bytes length:(NSUInteger)len encoding:NSUTF8StringEncoding];
}

static NSString *zenitAccessibilityRoleName(NSInteger role) {
    switch (role) {
        case ZenitAccessibilityRoleButton: return @"button";
        case ZenitAccessibilityRoleCheckbox: return @"checkbox";
        case ZenitAccessibilityRoleRadio: return @"radio button";
        case ZenitAccessibilityRoleTextbox: return @"text field";
        case ZenitAccessibilityRoleSwitch: return @"switch";
        case ZenitAccessibilityRoleTab: return @"tab";
        case ZenitAccessibilityRoleTabList: return @"tab group";
        case ZenitAccessibilityRoleDialog: return @"dialog";
        case ZenitAccessibilityRoleAlert: return @"alert";
        case ZenitAccessibilityRoleMenu: return @"menu";
        case ZenitAccessibilityRoleMenuItem: return @"menu item";
        case ZenitAccessibilityRoleListBox: return @"list box";
        case ZenitAccessibilityRoleOption: return @"option";
        case ZenitAccessibilityRoleProgressBar: return @"progress indicator";
        case ZenitAccessibilityRoleSlider: return @"slider";
        case ZenitAccessibilityRoleHeading: return @"heading";
        case ZenitAccessibilityRoleLink: return @"link";
        case ZenitAccessibilityRoleImage: return @"image";
        case ZenitAccessibilityRoleList: return @"list";
        case ZenitAccessibilityRoleListItem: return @"list item";
        default: return nil;
    }
}

static NSString *zenitAccessibilityMessage(
    NSInteger role,
    NSString *label,
    NSString *descriptionText,
    NSString *valueText,
    int checked,
    int expanded,
    BOOL disabled
) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (label.length > 0) [parts addObject:label];

    NSString *roleName = zenitAccessibilityRoleName(role);
    if (roleName.length > 0) [parts addObject:roleName];
    if (valueText.length > 0) [parts addObject:valueText];

    if (checked == 1) {
        [parts addObject:@"checked"];
    } else if (checked == 0) {
        [parts addObject:@"not checked"];
    }

    if (expanded == 1) {
        [parts addObject:@"expanded"];
    } else if (expanded == 0) {
        [parts addObject:@"collapsed"];
    }

    if (disabled) {
        [parts addObject:@"dimmed"];
    }

    if (descriptionText.length > 0) {
        [parts addObject:descriptionText];
    }

    if (parts.count == 0) return nil;
    return [parts componentsJoinedByString:@", "];
}

// host view transparent (MetalView isAccessibilityElement),
// notification can't target: transparent element notification dropped
// by AppKit. Always target nearest non-transparent ancestor (usually
// window).
static id zenitA11yHostTarget(WindowWrapper *wrapper) {
    if (!wrapper) return nil;
    NSView *host = wrapper.metalView ?: wrapper.window.contentView;
    id unignored = host ? NSAccessibilityUnignoredAncestor(host) : nil;
    return unignored ?: wrapper.window;
}

static id zenitAccessibilityTarget(WindowWrapper *wrapper) {
    return zenitA11yHostTarget(wrapper);
}

static int zenitPostAccessibilityAnnouncementWithPriority(
    WindowWrapper *wrapper,
    NSString *message,
    NSAccessibilityPriorityLevel priority
) {
    if (!wrapper || !wrapper.window || message.length == 0) return 0;
    id target = zenitAccessibilityTarget(wrapper);
    if (!target) return 0;

    NSDictionary *userInfo = @{
        NSAccessibilityAnnouncementKey: message,
        NSAccessibilityPriorityKey: @(priority),
    };
    NSAccessibilityPostNotificationWithUserInfo(
        target,
        NSAccessibilityAnnouncementRequestedNotification,
        userInfo
    );
    return 1;
}

static int zenitPostAccessibilityAnnouncement(WindowWrapper *wrapper, NSString *message) {
    return zenitPostAccessibilityAnnouncementWithPriority(wrapper, message, NSAccessibilityPriorityHigh);
}

// global window registry: NSWindow -> WindowWrapper (support multi-
// window event routing)
static NSMapTable *g_window_registry = nil;
// global window list (fast iterate, for Cmd+` switch)
static NSMutableArray<NSWindow *> *g_window_list = nil;
// AppKit events from every window share one monotonically increasing sequence.
// The Zig backend drains type-specific native queues, then merges by this value
// so a slow frame cannot reorder key/scroll/button/magnify input by queue type.
static unsigned long long g_input_event_sequence = 1;

static unsigned long long nextInputEventSequence(void) {
    unsigned long long sequence = g_input_event_sequence++;
    if (g_input_event_sequence == 0) g_input_event_sequence = 1;
    return sequence;
}

static void registerWindowWrapper(NSWindow *window, WindowWrapper *wrapper) {
    if (!g_window_registry) {
        g_window_registry = [NSMapTable weakToWeakObjectsMapTable];
    }
    [g_window_registry setObject:wrapper forKey:window];
    if (!g_window_list) {
        g_window_list = [NSMutableArray array];
    }
    [g_window_list addObject:window];
}

static void unregisterWindowWrapper(NSWindow *window) {
    if (zenitBackgroundE2E() && g_requested_key_window == window.windowNumber) {
        g_requested_key_window = 0;
    }
    if (g_window_registry) {
        [g_window_registry removeObjectForKey:window];
    }
    [g_window_list removeObject:window];
}

static WindowWrapper* wrapperForWindow(NSWindow *window) {
    if (!g_window_registry || !window) return nil;
    WindowWrapper *direct=[g_window_registry objectForKey:window];
    if(direct) return direct;
    for(WindowWrapper *owner in g_window_registry.objectEnumerator)
        if(owner.fullscreenHeader.active && owner.fullscreenHeader.header.window==window) return owner;
    return nil;
}

// Fullscreen presentation host shares stable identity, input, scale, layout, persistent native hosts and atomic resize clipping and generation-safe acquisition.
#include "fullscreen_header_host.inc"

// Prepare before AppKit captures the fullscreen toolbar configuration, including
// entry through the native green button and the system keyboard command.
static BOOL zenitDeferFullscreenUntilDeminiaturized(NSWindow *window,id sender) {
    WindowWrapper *w=wrapperForWindow(window);
    if(w.waitingForDeminiaturize) return YES; // Coalesce even if isMiniaturized already changed.
    if(!window.miniaturized) return NO;
    [w beginFullscreenEntry:NO];w.waitingForDeminiaturize=YES;
    [window deminiaturize:sender];return YES;
}

static BOOL zenitPrepareFullscreen(NSWindow *window) {
    WindowWrapper *w=wrapperForWindow(window);
    if(w.nativeCloseObserved) return NO;
    ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
    if(!host || !host.policy) return YES;
    if(host.active) return NO; // Entry already handed to AppKit.
    if(host.pendingFullscreen) return NO; // Coalesce with the accepted request.
    if(host.enterWithoutPaint || host.windowedPaintReady) {
        host.enterWithoutPaint=NO;[w beginFullscreenEntry:YES];
        [host start];return YES;
    }
    // Set pending before prepare so windowed inset ownership stays intact.
    host.pendingFullscreen=YES;host.pendingDeadline=CACurrentMediaTime()+.25;[w beginFullscreenEntry:NO];
    [host prepare];[w applyTrafficLightsInset];[host requestFrame];
    __weak WindowWrapper *weakOwner=w;
    __weak ZenitFullscreenHeaderHost *weakHost=host;NSUInteger epoch=host.presentationEpoch;
    // Bounded prewarm: a hidden/occluded/minimized window may never acquire a
    // drawable. Continue the accepted request with the accessory still unpainted
    // rather than dropping it. First fullscreen paint publishes the header.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/4),dispatch_get_main_queue(),^{
        WindowWrapper *owner=weakOwner;ZenitFullscreenHeaderHost *current=weakHost;
        if(owner && current && owner.fullscreenHeader==current && current.presentationEpoch==epoch && current.pendingFullscreen)
            [current completePreparationWithoutPaint:YES];
    });
    return NO;
}

static void zenitPrepareFullscreenExit(NSWindow *window) {
    [wrapperForWindow(window).fullscreenHeader beginExit];
}


// C API export

// window creation. internal shared: create by styleMask and
// complete wrapper registration
static void* macos_create_window_internal(int width, int height, const char* title, NSWindowStyleMask styleMask, BOOL borderless) {
    @autoreleasepool {
        NSRect frame = NSMakeRect(0, 0, width, height);

        NSWindow *window = [[ZenitWindow alloc] initWithContentRect:frame
                                                      styleMask:styleMask
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        // NSWindow defaults this to YES. Under ARC Apple explicitly requires it
        // to be NO; otherwise close releases the object independently of the
        // strong reference owned by WindowWrapper and can over-release it.
        window.releasedWhenClosed = NO;

        if (borderless) {
            window.titlebarAppearsTransparent = YES;
            window.titleVisibility = NSWindowTitleHidden;
            // don't use movableByWindowBackground: scope entire window, swallows
            // input too (see MetalView.mouseDownCanMoveWindow). Drag declared
            // explicit via setTitlebarDragHeight.
            window.movableByWindowBackground = NO;
            window.hasShadow = YES;
            // floating island style: rounded + close via Esc by app
            window.backgroundColor = [NSColor whiteColor];
            window.opaque = NO;
            // don't set NSFloatingWindowLevel: that's global level, presses
            // other app windows - user switches browser, float still on top.
            // Correct 'always above host' via addChildWindow
            // (macos_add_child_window), app-local relation, sinks with host on
            // switch. Host without child keeps normal level; need Spotlight global
            // float, ask explicit, don't let borderless appearance dictate.
            window.level = NSNormalWindowLevel;
        } else {
            // transparent titlebar - content extends to titlebar, app renders
            // TitleBar
            window.titlebarAppearsTransparent = YES;
            window.titleVisibility = NSWindowTitleHidden;
        }

        [window setTitle:[NSString stringWithUTF8String:title]];
        [window center];

        // create Metal view
        MetalView *metalView = [[MetalView alloc] initWithFrame:frame];
        if (!metalView) {
            NSLog(@"[macos_create_window] Failed to create MetalView");
            return NULL;
        }
        metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        [window setContentView:metalView];

        // wrap window and view
        WindowWrapper *wrapper = [[WindowWrapper alloc] init];
        wrapper.window = window;
        wrapper.metalView = metalView;
        wrapper.shouldClose = NO;
        wrapper.closeCommitted = NO;
        wrapper.nativeCloseStarted = NO;
        wrapper.nativeCloseObserved = NO;
        wrapper.nativeCloseRetentionElapsed = NO;
        wrapper.nativeCloseCompleted = NO;
        NSPoint initialMouse = [window mouseLocationOutsideOfEventStream];
        NSRect initialContentFrame = [window.contentView frame];
        wrapper.mouseLocation = NSMakePoint(initialMouse.x,
                                            initialContentFrame.size.height - initialMouse.y);
        wrapper.inputText = nil;
        wrapper.keyEventQueue = [NSMutableArray array];
        wrapper.mouseMoveQueue = [NSMutableArray array];
        wrapper.inputTextQueue = [NSMutableArray array];
        wrapper.imePreeditText = nil;
        wrapper.imePreeditCursorUtf16 = 0;
        wrapper.imePreeditQueue = [NSMutableArray array];
        wrapper.hasImePreedit = NO;
        wrapper.imeCommitText = nil;
        wrapper.hasImeCommit = NO;
        wrapper.imeCommitQueue = [NSMutableArray array];
        wrapper.imeCommitReplaceStartUtf8 = ZENIT_IME_NO_REPLACEMENT;
        wrapper.imeCommitReplaceEndUtf8 = ZENIT_IME_NO_REPLACEMENT;
        wrapper.imePreeditReplaceStartUtf8 = ZENIT_IME_NO_REPLACEMENT;
        wrapper.imePreeditReplaceEndUtf8 = ZENIT_IME_NO_REPLACEMENT;
        wrapper.imeCursorX = 0;
        wrapper.imeCursorY = 0;
        wrapper.imeCursorWidth = 1;
        wrapper.imeCursorHeight = 18;
        wrapper.hasImeCursorRect = NO;
        wrapper.textInputEnabled = NO;
        wrapper.pollSeq = 0;
        wrapper.lastInsertPollSeq = 0;
        wrapper.keyDispatchSeq = 0;
        wrapper.lastInsertKeyDispatchSeq = 0;
        wrapper.lastInsertText = nil;
        wrapper.lastInsertHadMarked = NO;
        wrapper.scrollEventQueue = [NSMutableArray array];
        wrapper.magnifyEventQueue = [NSMutableArray array];
        wrapper.mouseButtonQueue = [NSMutableArray array];
        // AppKit may synchronously query the text client while establishing
        // the responder/key-window chain. Publish its routing and queues first.
        registerWindowWrapper(window, wrapper);
        [window setDelegate:wrapper];
        [window makeFirstResponder:metalView];
        zenitPresentWindow(window);
        // Access for diagnostics only; AppKit activates it via first-responder
        // lifecycle above. Do not call activate/deactivate directly.
        NSTextInputContext *ic = [metalView inputContext];
        wrapper.lastKeyboardInputSource = ic.selectedKeyboardInputSource;

        NSLog(@"[macos_create_window] Window created: %dx%d inputContext=%@ inputSource=%@",
              width, height, ic, ic ? [ic selectedKeyboardInputSource] : @"(nil)");

        return (__bridge_retained void*)wrapper;
    }
}

// public entry: standard window (with titlebar + traffic light)
void* macos_create_window(int width, int height, const char* title) {
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskResizable |
                                  NSWindowStyleMaskMiniaturizable |
                                  NSWindowStyleMaskFullSizeContentView;
    return macos_create_window_internal(width, height, title, styleMask, NO);
}

// Explicitly elevate window to key window (borderless float easily
// loses focus). Last window requested to be key. AppKit rejects
// key/main change when app backgrounded; multi-window e2e (and
// shortcut routing) need logical focus independent of foreground.

static NSWindow *macos_find_window_by_number(NSInteger number) {
    if (number == 0) return nil;
    for (NSWindow *w in [NSApp windows]) {
        if ([w windowNumber] == number) return w;
    }
    return nil;
}

void macos_make_key_window(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper && wrapper.window) {
            g_requested_key_window = [wrapper.window windowNumber];
            if (![NSApp isActive]) {
                zenitActivateApplication();
            }
            zenitPresentWindow(wrapper.window);
        }
    }
}

// Child attached to parent: z follows parent, fronts/minimizes with
// it, AppKit auto-closes on parent close. IDE native 'search always
// above project, moves with it' - much more correct than
// NSFloatingWindowLevel (global, presses other app windows).
void macos_add_child_window(void* parent_ptr, void* child_ptr) {
    @autoreleasepool {
        WindowWrapper *parent = (__bridge WindowWrapper*)parent_ptr;
        WindowWrapper *child = (__bridge WindowWrapper*)child_ptr;
        if (!parent || !child || !parent.window || !child.window) return;
        // Child once attached shouldn't have global float level, else still
        // presses other apps.
        child.window.level = NSNormalWindowLevel;
        [parent.window addChildWindow:child.window ordered:NSWindowAbove];
        child.ownerWindow = parent.window;
    }
}

// Center the child on the parent's window, not the screen. [window center] is screen-centered:
// right for the main window, wrong for Command Palette/Quick Open/Find docked to an editor
// (moved, multi-monitor, half-screen: the float lands far away or on another screen).
// Users expect 'panel belongs to this window'.
//
// == Why only get/store, not arithmetic ==
//
// Centering (vertical bias, screen clip) is computed in a pure Zig function (see downstream
// editor); ObjC has no tests. ObjC only reads the visible geometry of host/float/screen and
// writes the computed origin back to the window. Geometry goes via out param (NSRect crosses
// the C ABI poorly). Return 0 = window unavailable; caller must abandon, not use zeros.
int macos_get_centering_geometry(
    void* child_ptr, void* parent_ptr,
    double* host_x, double* host_y, double* host_w, double* host_h,
    double* panel_w, double* panel_h,
    double* vis_x, double* vis_y, double* vis_w, double* vis_h
) {
    @autoreleasepool {
        WindowWrapper *child = (__bridge WindowWrapper*)child_ptr;
        WindowWrapper *parent = (__bridge WindowWrapper*)parent_ptr;
        if (!child || !parent || !child.window || !parent.window) return 0;

        NSRect host = parent.window.frame;
        NSRect panel = child.window.frame;
        *host_x = host.origin.x; *host_y = host.origin.y;
        *host_w = host.size.width; *host_h = host.size.height;
        *panel_w = panel.size.width; *panel_h = panel.size.height;

        // visibleFrame excludes menu bar and Dock. Get host's screen:
        // multi-monitor, float stays on host screen, can't jump to main.
        NSScreen *screen = parent.window.screen ?: [NSScreen mainScreen];
        NSRect vis = screen ? screen.visibleFrame : host;
        *vis_x = vis.origin.x; *vis_y = vis.origin.y;
        *vis_w = vis.size.width; *vis_h = vis.size.height;
        return 1;
    }
}

// Set window bottom-left (AppKit coords) to point.
void macos_set_window_origin(void* window_ptr, double x, double y) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper || !wrapper.window) return;
        [wrapper.window setFrameOrigin:NSMakePoint(x, y)];
    }
}

void macos_remove_child_window(void* parent_ptr, void* child_ptr) {
    @autoreleasepool {
        WindowWrapper *parent = (__bridge WindowWrapper*)parent_ptr;
        WindowWrapper *child = (__bridge WindowWrapper*)child_ptr;
        if (!parent || !child || !parent.window || !child.window) return;
        [parent.window removeChildWindow:child.window];
        child.ownerWindow = nil;
    }
}

// Register resign key callback (NULL clears). Param
// new_key_is_owner: 1 = focus back to app (usually host), 0 =
// other app or no key window.
void macos_set_resign_key_callback(void* window_ptr, void (*cb)(void* ctx, int is_owner), void* ctx) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper) return;
        wrapper.resignKeyCallback = cb;
        wrapper.resignKeyContext = ctx;
    }
}

// Public entry: borderless float (appears no titlebar/traffic lights
// but keeps NSWindow resize). Impl: still Titled/Resizable/
// FullSizeContentView, only hide lights + titlebar visual.
void* macos_create_window_borderless(int width, int height, const char* title) {
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskResizable |
                                  NSWindowStyleMaskFullSizeContentView;
    void *result = macos_create_window_internal(width, height, title, styleMask, YES);
    if (result) {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)result;
        NSWindow *w = wrapper.window;
        // Hide traffic lights three buttons
        [[w standardWindowButton:NSWindowCloseButton] setHidden:YES];
        [[w standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
        [[w standardWindowButton:NSWindowZoomButton] setHidden:YES];
        // Titled + FullSizeContentView leaves invisible-but-draggable
        // system titlebar (NSThemeFrame, ~32px) at top. Host putting control
        // at window top gets covered: press-drag = window drag, text
        // unselectable. Only turns off whole-window-draggable. Invisible
        // titlebar not under MetalView control, can't turn off, shouldn't -
        // setMovable:NO would also break every drag other than
        // performWindowDragWithEvent, leaving a host window that has no
        // self-drawn title strip completely unmovable. Correct: host reserves titlebar at
        // top (see downstream titlebar drag), pushes controls below invisible.
        w.movableByWindowBackground = NO;
    }
    return result;
}

// get Metal view
void* macos_get_metal_view(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return (__bridge void*)wrapper.metalView;
    }
}

// set live resize render callback
void macos_set_render_callback(void* window_ptr, RenderCallback callback, void* ctx) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.metalView.renderCallback = callback;
        wrapper.metalView.renderContext = ctx;
    }
}

// AppKit chooses the current input device and respects accessibility/user
// preferences. A successful request does not promise a physical pulse.
int macos_perform_haptic_feedback(int pattern) {
    const BOOL debug = getenv("ZENIT_DEBUG_HAPTICS") != NULL;
    if (debug) NSLog(@"[haptic-debug] request pattern=%d main=%d active=%d event=%ld buttons=%lu",
                     pattern, [NSThread isMainThread], NSApp.active,
                     (long)NSApp.currentEvent.type, (unsigned long)NSEvent.pressedMouseButtons);
    if (![NSThread isMainThread]) return -1;
    // Stable bridge tags are semantic, never intensity/amplitude values.
    NSHapticFeedbackPattern nativePattern;
    switch (pattern) {
        case 0: nativePattern = NSHapticFeedbackPatternAlignment; break;
        case 1: nativePattern = NSHapticFeedbackPatternGeneric; break;
        case 2: nativePattern = NSHapticFeedbackPatternLevelChange; break;
        default: return 0;
    }
    @autoreleasepool {
        id<NSHapticFeedbackPerformer> performer = [NSHapticFeedbackManager defaultPerformer];
        if (debug) NSLog(@"[haptic-debug] performer=%@", performer);
        [performer performFeedbackPattern:nativePattern
                         performanceTime:NSHapticFeedbackPerformanceTimeNow];
    }
    return 1;
}

// request redraw
void macos_request_redraw(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        [wrapper.metalView setNeedsDisplay:YES];
    }
}

int macos_accessibility_announce(void *window_ptr, const char *text, int len) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
        NSString *message = zenitStringFromUtf8(text, len);
        return zenitPostAccessibilityAnnouncement(wrapper, message);
    }
}

int macos_accessibility_notify_focus(
    void *window_ptr,
    int role,
    const char *label,
    int label_len,
    const char *description,
    int description_len,
    const char *value_text,
    int value_text_len,
    int checked,
    int expanded,
    int disabled
) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
        if (!wrapper || !wrapper.window) return 0;

        id target = zenitAccessibilityTarget(wrapper);
        if (!target) return 0;

        NSAccessibilityPostNotification(target, NSAccessibilityFocusedUIElementChangedNotification);

        NSString *message = zenitAccessibilityMessage(
            role,
            zenitStringFromUtf8(label, label_len),
            zenitStringFromUtf8(description, description_len),
            zenitStringFromUtf8(value_text, value_text_len),
            checked,
            expanded,
            disabled != 0
        );
        if (message.length > 0) {
            zenitPostAccessibilityAnnouncement(wrapper, message);
        }
        return 1;
    }
}

int macos_accessibility_notify_property_change(
    void *window_ptr,
    int role,
    const char *label,
    int label_len,
    const char *description,
    int description_len,
    const char *value_text,
    int value_text_len,
    int checked,
    int expanded,
    int disabled
) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
        if (!wrapper || !wrapper.window) return 0;

        id target = zenitAccessibilityTarget(wrapper);
        if (!target) return 0;

        NSAccessibilityPostNotification(target, NSAccessibilityValueChangedNotification);

        NSString *message = zenitAccessibilityMessage(
            role,
            zenitStringFromUtf8(label, label_len),
            zenitStringFromUtf8(description, description_len),
            zenitStringFromUtf8(value_text, value_text_len),
            checked,
            expanded,
            disabled != 0
        );
        if (message.length > 0) {
            zenitPostAccessibilityAnnouncement(wrapper, message);
        }
        return 1;
    }
}

// ==== a11y_router.flushToBridge push C ABI
//
// Zig src/ui/a11y/macos_bridge.zig externs in; window_id routes to the g_window_list wrapper
// (single-window impl takes the first; window_id = NSWindow.windowNumber, same source as zig
// Cx.window_id).
//
// Retained-tree notifications target the exact virtual element. Legacy SystemSdk snapshot calls
// remain as a compatibility API; Cx suppresses the automatic focus path to avoid duplicate
// host-view announcements.

static WindowWrapper *zenitWrapperForWindowId(uint32_t window_id) {
    if (!g_window_list) return nil;
    // window_id == NSWindow.windowNumber (zig Cx.window_id source).
    // 0 = wildcard (unwired caller), degrades to first valid wrapper.
    for (NSWindow *win in g_window_list) {
        WindowWrapper *w = wrapperForWindow(win);
        if (!w) continue;
        if (window_id == ZENIT_A11Y_ANY_WINDOW) return w;
        if ((uint32_t)((NSInteger)[win windowNumber]) == window_id) return w;
    }
    return nil;
}

// Cache-only query, no creation: assistive tech never saw element,
// can't care about attrs/geometry. Property/geometry only to cached,
// others skip, kills scroll/animation whole-tree Moved/Resized. Focus
// and structure don't here.
static id zenitA11yCachedElement(WindowWrapper *wrapper, ZenitAXHandle handle) {
    if (!wrapper || !wrapper.metalView || handle == ZENIT_A11Y_INVALID_HANDLE) return nil;
    return wrapper.metalView.zenitA11yElementCache[@(handle)];
}

// Structure change: notify nearest cached ancestor (else host view).
static id zenitA11yNearestKnownAncestor(WindowWrapper *wrapper, uint32_t window_id, ZenitAXHandle handle) {
    ZenitAXHandle cursor = handle;
    for (NSUInteger depth = 0; depth < 4096 && cursor != ZENIT_A11Y_INVALID_HANDLE; depth++) {
        id cached = zenitA11yCachedElement(wrapper, cursor);
        if (cached) return cached;
        cursor = zenit_a11y_parent(window_id, cursor);
    }
    return zenitA11yHostTarget(wrapper);
}

static id zenitA11yTargetForHandle(WindowWrapper *wrapper, ZenitAXHandle handle) {
    if (!wrapper || !wrapper.metalView) return nil;
    if (handle == ZENIT_A11Y_INVALID_HANDLE) return zenitA11yHostTarget(wrapper);
    return [wrapper.metalView zenitA11yElementForHandle:handle] ?: zenitA11yHostTarget(wrapper);
}

int zenit_a11y_push_property_changed(uint32_t window_id, ZenitAXHandle element_raw, uint16_t flags) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper) return 0;
        if ((flags & ZenitA11yDirtyRole) != 0) {
            NSAccessibilityPostNotification(
                zenitA11yNearestKnownAncestor(wrapper, window_id, zenit_a11y_parent(window_id, element_raw)),
                NSAccessibilityLayoutChangedNotification);
        }
        id target = zenitA11yCachedElement(wrapper, element_raw);
        if (!target) return 1;
        if ((flags & ZenitA11yDirtyLabel) != 0)
            NSAccessibilityPostNotification(target, NSAccessibilityTitleChangedNotification);
        if ((flags & (ZenitA11yDirtyValue | ZenitA11yDirtyState)) != 0)
            NSAccessibilityPostNotification(target, NSAccessibilityValueChangedNotification);
        if ((flags & ZenitA11yDirtySelection) != 0)
            NSAccessibilityPostNotification(target, NSAccessibilitySelectedTextChangedNotification);
        if ((flags & ZenitA11yDirtyRowCount) != 0)
            NSAccessibilityPostNotification(target, NSAccessibilityRowCountChangedNotification);
        // Geometry notification only to focused element (VoiceOver cursor
        // box follows); others' motion picked up naturally next frame fetch.
        if ((flags & ZenitA11yDirtyGeometry) != 0 &&
            (zenit_a11y_state(window_id, element_raw) & ZenitA11yStateFocused) != 0) {
            NSAccessibilityPostNotification(target, NSAccessibilityMovedNotification);
            NSAccessibilityPostNotification(target, NSAccessibilityResizedNotification);
        }
        return 1;
    }
}

int zenit_a11y_push_focus_changed(uint32_t window_id, ZenitAXHandle element_raw) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper) return 0;
        id target = zenitA11yTargetForHandle(wrapper, element_raw);
        if (!target) return 0;
        NSAccessibilityPostNotification(target, NSAccessibilityFocusedUIElementChangedNotification);
        return 1;
    }
}

// Layout notifications are deduplicated by target per flush and sent at flush_end. A single
// story switch deletes hundreds of nodes; folding parents to the nearest-known ancestor makes
// nearly all the same content root (one navigation produced 80 LayoutChanged).
// Targets are bucketed by window (MetalView.zenitA11yPendingLayoutTargets): flush_end must not
// ignore window_id, or window A's notifications appear in window B's flush.
int zenit_a11y_push_children_changed(uint32_t window_id, ZenitAXHandle element_raw) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper || !wrapper.metalView) return 0;
        id target = zenitA11yNearestKnownAncestor(wrapper, window_id, element_raw);
        if (!target) return 0;
        MetalView *view = wrapper.metalView;
        if (!view.zenitA11yPendingLayoutTargets) view.zenitA11yPendingLayoutTargets = [NSMutableArray array];
        if ([view.zenitA11yPendingLayoutTargets indexOfObjectIdenticalTo:target] == NSNotFound)
            [view.zenitA11yPendingLayoutTargets addObject:target];
        return 1;
    }
}

int zenit_a11y_push_flush_end(uint32_t window_id) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper || !wrapper.metalView) return 0;
        NSArray *targets = wrapper.metalView.zenitA11yPendingLayoutTargets;
        wrapper.metalView.zenitA11yPendingLayoutTargets = nil;
        for (id target in targets)
            NSAccessibilityPostNotification(target, NSAccessibilityLayoutChangedNotification);
        return 1;
    }
}

int zenit_a11y_push_announce(uint32_t window_id, const char *text, int len, uint8_t priority) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper) return 0;
        NSString *message = zenitStringFromUtf8(text, len);
        if (message.length == 0) return 0;
        NSAccessibilityPriorityLevel nativePriority =
            priority >= 2 ? NSAccessibilityPriorityHigh : NSAccessibilityPriorityMedium;
        return zenitPostAccessibilityAnnouncementWithPriority(wrapper, message, nativePriority);
    }
}

// aria-activedescendant projection: the container holds focus but visual focus is on the active
// child.
// NSAccessibility has no one-to-one active-descendant property. Expose the
// relation through selectedChildren/focusedUIElement and notify both exact
// virtual elements so VoiceOver re-pulls those attributes.
int zenit_a11y_push_active_descendant(uint32_t window_id, ZenitAXHandle container_raw, ZenitAXHandle active_raw) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper) return 0;
        id container = zenitA11yTargetForHandle(wrapper, container_raw);
        id active = active_raw == ZENIT_A11Y_INVALID_HANDLE
            ? nil
            : zenitA11yTargetForHandle(wrapper, active_raw);
        if (!container) return 0;
        NSAccessibilityPostNotification(container, NSAccessibilitySelectedChildrenChangedNotification);
        NSAccessibilityPostNotification(active ?: container, NSAccessibilityFocusedUIElementChangedNotification);
        return 1;
    }
}

// System a11y preferences (src/ui/a11y/preferences.zig): bit layout
// match Zig: bit0 reduce motion, bit1 reduce transparency, bit2
// increase contrast, bit3 no color difference, bit4 invert.
extern void zenit_a11y_preferences_changed(void);

uint32_t zenit_a11y_display_options(void) {
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    uint32_t bits = 0;
    if (ws.accessibilityDisplayShouldReduceMotion) bits |= 1u << 0;
    if (ws.accessibilityDisplayShouldReduceTransparency) bits |= 1u << 1;
    if (ws.accessibilityDisplayShouldIncreaseContrast) bits |= 1u << 2;
    if (ws.accessibilityDisplayShouldDifferentiateWithoutColor) bits |= 1u << 3;
    if (ws.accessibilityDisplayShouldInvertColors) bits |= 1u << 4;
    return bits;
}

// Register once: system settings change refreshes Zig prefs, wakes
// main loop (Cx.wantsFrame requests frame on version change, whole
// tree invalid at render start).
void zenit_a11y_observe_display_options(void) {
    // App.init on main thread; static flag ok. Don't use dispatch_once:
    // inline macro triggers Zig Debug UBSan (e2e startup abort, see
    // image_bridge.m same).
    static BOOL registered = NO;
    if (registered) return;
    registered = YES;
    {
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        (void)note;
                        zenit_a11y_preferences_changed();
                        macos_post_empty_event();
                    }];
    }
}

int zenit_a11y_push_element_destroyed(uint32_t window_id, ZenitAXHandle element_raw) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        id element = zenitA11yCachedElement(wrapper, element_raw);
        if (!element) return 1;
        NSAccessibilityPostNotification(element, NSAccessibilityUIElementDestroyedNotification);
        [wrapper.metalView.zenitA11yElementCache removeObjectForKey:@(element_raw)];
        // Destroyed elements can't receive this flush's layout notifications.
        [wrapper.metalView.zenitA11yPendingLayoutTargets removeObjectIdenticalTo:element];
        return 1;
    }
}

int zenit_a11y_push_window_cleared(uint32_t window_id) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper || !wrapper.metalView) return 0;
        NSArray *stale = [wrapper.metalView.zenitA11yElementCache.allValues copy];
        for (id element in stale)
            NSAccessibilityPostNotification(element, NSAccessibilityUIElementDestroyedNotification);
        [wrapper.metalView.zenitA11yElementCache removeAllObjects];
        wrapper.metalView.zenitA11yPendingLayoutTargets = nil;
        NSAccessibilityPostNotification(zenitA11yHostTarget(wrapper), NSAccessibilityLayoutChangedNotification);
        return 1;
    }
}

// Called only after Cx has applied the preedit to its live document. AppKit's
// synchronous speculative cache remains authoritative until this acknowledgement.
int zenit_text_input_preedit_applied(uint32_t window_id, uint64_t start16, uint64_t end16,
                                      uint32_t start8, uint32_t end8) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        MetalView *view = wrapper.metalView;
        if (!view || !view.hasMarkedText || start16 > end16 || end16 > NSUIntegerMax || start8 > end8 ||
            end16 - start16 != view.markedTextStorage.length) return 0;
        NSData *candidate = [view.markedTextStorage.string dataUsingEncoding:NSUTF8StringEncoding];
        if (!candidate || candidate.length != (uint64_t)end8 - start8) return 0;
        // Resolve the applied model again, not a borrowed event string which
        // the handler may have replaced. A newer queued candidate must not be
        // overwritten by an acknowledgement of a different older projection.
        char buffer[256];
        for (size_t copied = 0; copied < candidate.length;) {
            const int wanted = (int)MIN(sizeof(buffer), candidate.length - copied);
            if (zenit_text_input_copy(window_id, (uint64_t)start8 + copied, buffer, wanted) != wanted ||
                memcmp(buffer, (const uint8_t *)candidate.bytes + copied, wanted) != 0) return 0;
            copied += (size_t)wanted;
        }
        view.markedDocumentRange = NSMakeRange((NSUInteger)start16, (NSUInteger)(end16 - start16));
        return 1;
    }
}

void macos_set_ime_cursor_rect(void* window_ptr, float x, float y, float width, float height) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        const BOOL changed = !wrapper.hasImeCursorRect ||
                             wrapper.imeCursorX != x ||
                             wrapper.imeCursorY != y ||
                             wrapper.imeCursorWidth != width ||
                             wrapper.imeCursorHeight != height;
        wrapper.imeCursorX = x;
        wrapper.imeCursorY = y;
        wrapper.imeCursorWidth = width;
        wrapper.imeCursorHeight = height;
        wrapper.hasImeCursorRect = YES;
        if (changed && input_debug_enabled()) {
            NSLog(@"[bridge-input] set_ime_cursor_rect x=%.1f y=%.1f w=%.1f h=%.1f",
                  x, y, width, height);
        }
        if (changed && wrapper.metalView) {
            NSTextInputContext *inputContext = [wrapper.metalView inputContext];
            if (inputContext) {
                [inputContext invalidateCharacterCoordinates];
            }
        }
    }
}

// Set by the test-enabled runtime before it pumps this window's input.
void macos_set_keyboard_isolated(void *window_ptr, int isolated) {
    WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
    wrapper.keyboardIsolated = isolated != 0;
}

// Enable/disable AppKit text interpretation independently from raw keyboard
// delivery. The Metal view remains first responder in both states.
void macos_set_text_input_enabled(void* window_ptr, int enabled) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper) return;
        if (enabled == 0) {
            // Disabling and discarding are one state transition. Leaving
            // marked text alive behind a false gate lets the next focused
            // client inherit another editor's composition.
            macos_ime_discard(window_ptr);
            wrapper.textInputEnabled = NO;
            return;
        }
        wrapper.textInputEnabled = enabled != 0;
    }
}

// Abort current IME composition: close candidate window, clear marked
// text/preedit, don't change enabled. Text client A->B needs discard A
// then continue B; only macos_set_text_input_enabled(false) owns
// closing native gate.
void macos_ime_discard(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        MetalView *view = wrapper.metalView;
        const NSUInteger queuedPreeditCount = wrapper.imePreeditQueue.count;
        const BOOL hadPendingComposition = (view && view.markedTextStorage.length > 0) || wrapper.hasImePreedit;
        if (view) {
            if (hadPendingComposition) {
                NSTextInputContext *inputContext = [view inputContext];
                if (inputContext) {
                    [view discardMarkedTextFromInputContext];
                    [inputContext invalidateCharacterCoordinates];
                }
            }
            [view.markedTextStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
            view.markedTextSelectedRange = NSMakeRange(0, 0);
            view.markedDocumentRange = NSMakeRange(NSNotFound, 0);
        }
        // discardMarkedText may synchronously call unmarkText, which already
        // enqueues the clear. Add the explicit packet only when it did not.
        if (hadPendingComposition && wrapper.imePreeditQueue.count == queuedPreeditCount) {
            zenitEnqueueImePreedit(wrapper, @"", 0,
                                   ZENIT_IME_NO_REPLACEMENT,
                                   ZENIT_IME_NO_REPLACEMENT);
        }
        wrapper.hasImeCursorRect = NO;
    }
}

// query live resize state
int macos_is_live_resize(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return wrapper.window.inLiveResize ? 1 : 0;
    }
}

#include "caret_patch_flip.inc"

// get Metal Layer
void* macos_get_metal_layer(void* view_ptr) {
    @autoreleasepool {
        MetalView *view = (__bridge MetalView*)view_ptr;
        return (__bridge void*)view.metalLayer;
    }
}

// get Metal Device
void* macos_get_metal_device(void* view_ptr) {
    @autoreleasepool {
        MetalView *view = (__bridge MetalView*)view_ptr;
        return (__bridge void*)view.device;
    }
}

// ==== Global exit flag (multi-window architecture) ====
static BOOL zenitHasPendingMenuCommands(void);
void macos_menu_discard_window_commands(uint64_t window_id);

static BOOL g_app_should_quit = NO;
// Set to YES when the app switches from background to foreground; the Zig side
// consumes it and resets it, triggering a redraw of all windows.
static BOOL g_app_became_active = NO;

// ==== Global menu action queue; menu action enum (1-1 with Zig
// MenuAction) ====
typedef enum {
    MenuActionNone = 0,
    MenuActionNewFile = 1, // New Text File (Cmd+N) - already has shortcut, menu redundant
    MenuActionNewFileDialog = 2,   // New File... (Ctrl+Alt+Cmd+N)
    MenuActionNewWindow = 3,       // New Window (Shift+Cmd+N)
    MenuActionOpenFile = 4,        // Open... (Cmd+O)
    MenuActionOpenFolder = 5,      // Open Folder...
    MenuActionOpenRecent = 6,      // Open Recent (placeholder)
    MenuActionSave = 7,            // Save (Cmd+S)
    MenuActionSaveAs = 8,          // Save As... (Shift+Cmd+S)
    MenuActionCloseTab = 9, // Close Tab (Cmd+W) - already has shortcut
    MenuActionCloseWindow = 10,    // Close Window (Shift+Cmd+W)
    MenuActionInstallCli = 11, // Install Command Line Tool (app menu)
} MenuActionType;

static NSMutableArray<NSDictionary *> *g_menu_actions;

static void pushMenuActionForWindow(MenuActionType action, uint64_t window_id) {
    if (action == MenuActionNone) return;
    if (!g_menu_actions) g_menu_actions = [NSMutableArray array];
    BOOL wake = g_menu_actions.count == 0;
    [g_menu_actions addObject:@{@"action": @(action), @"windowId": @(window_id)}];
    if (wake) macos_post_empty_event();
}

static void pushMenuAction(MenuActionType action) {
    NSWindow *window = NSApp.keyWindow;
    pushMenuActionForWindow(action, window ? (uint64_t)(NSInteger)window.windowNumber : 0);
}

int macos_get_menu_action_event(uint64_t *window_id, int *action) {
    @autoreleasepool {
        if (!window_id || !action || !g_menu_actions.count) return 0;
        NSDictionary *packet = g_menu_actions.firstObject;
        *window_id = [packet[@"windowId"] unsignedLongLongValue];
        *action = [packet[@"action"] intValue];
        [g_menu_actions removeObjectAtIndex:0];
        return 1;
    }
}

static MenuActionType popMenuAction(void) {
    uint64_t window_id; int action;
    return macos_get_menu_action_event(&window_id, &action) ? (MenuActionType)action : MenuActionNone;
}

// Route mouse/keyboard/scroll state in event to correct
// WindowWrapper
static WindowWrapper* targetWrapperForEvent(NSEvent *event, WindowWrapper *fallback) {
    NSWindow *eventWindow = event.window;
    if (!eventWindow && event.windowNumber > 0) {
        eventWindow = [NSApp windowWithWindowNumber:event.windowNumber];
    }
    if (eventWindow) {
        WindowWrapper *target = wrapperForWindow(eventWindow);
        if (target) return target;
    }

    // Mouse events sometimes event.window empty (window switch instant);
    // hit topmost visible by screen coords, avoid wrong route to old key.
    if (isPointerEventType(event.type) && [NSApp isActive]) {
        const NSPoint p = [NSEvent mouseLocation];
        for (NSWindow *w in [NSApp orderedWindows]) {
            if (!w.isVisible) continue;
            if (NSPointInRect(p, w.frame)) {
                WindowWrapper *target = wrapperForWindow(w);
                if (target) return target;
            }
        }
    }

    return fallback;
}

// Queue native mouse motion with its exact position/flags. The soft limit is
// deliberately not a hard cap: once pressure is high we may combine only two
// adjacent move packets. A key/button/text/gesture sequence between them makes
// the sequence numbers non-adjacent, so that semantic boundary is preserved.
static void enqueueMouseMove(WindowWrapper *target, NSEvent *event) {
    if (!target || !event) return;
    const BOOL dragging = target.leftButtonPressed ||
                          target.rightButtonPressed ||
                          target.middleButtonPressed;
    const BOOL inactiveHover = target.acceptsMouseMovedWhileInactive &&
                               target.window && [NSApp isActive] &&
                               (target.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    if (!windowCanAcceptPointerInput(target) && !dragging && !inactiveHover) return;
    NSRect contentFrame = [target.window.contentView frame];
    NSPoint loc = zenitLogicalEventPoint(target,event);

    MouseMovePacket packet;
    packet.sequence = nextInputEventSequence();
    packet.x = (float)loc.x;
    packet.y = (float)loc.y;
    // Match the SDK's established top-left coordinate semantics exactly;
    // NSEvent deltaY uses AppKit's coordinate convention and is not used.
    packet.dx = packet.x - (float)target.mouseLocation.x;
    packet.dy = packet.y - (float)target.mouseLocation.y;
    packet.modifiers = (uint32_t)event.modifierFlags;

    if (!target.mouseMoveQueue) target.mouseMoveQueue = [NSMutableArray array];
    if (target.mouseMoveQueue.count >= ZENIT_MOUSE_MOVE_SOFT_LIMIT &&
        target.mouseMoveQueue.count > 0) {
        NSValue *tailValue = target.mouseMoveQueue.lastObject;
        MouseMovePacket tail;
        [tailValue getValue:&tail];
        if (tail.sequence != ULLONG_MAX && tail.sequence + 1 == packet.sequence) {
            packet.dx += tail.dx;
            packet.dy += tail.dy;
            [target.mouseMoveQueue removeLastObject];
            g_mouse_move_coalesced_count += 1;
            if (input_debug_enabled()) {
                NSLog(@"[bridge-input] mouse move pressure: coalesced adjacent seq=%llu..%llu",
                      tail.sequence, packet.sequence);
            }
        }
    }
    [target.mouseMoveQueue addObject:[NSValue valueWithBytes:&packet objCType:@encode(MouseMovePacket)]];
    target.mouseLocation = NSMakePoint(packet.x, packet.y);
}

// Push button event into target window queue (avoid polling miss
// same-frame press+release)
static void enqueueMouseButton(WindowWrapper *target, int button, BOOL pressed, NSEvent *event) {
    NSPoint locInWindow = zenitLogicalEventPoint(target,event);
    NSRect contentFrame = [target.window.contentView frame];
    MouseButtonPacket packet;
    packet.sequence = nextInputEventSequence();
    packet.x = (float)locInWindow.x;
    packet.y = (float)locInWindow.y;
    packet.button = button;
    packet.pressed = pressed;
    packet.modifiers = (uint32_t)event.modifierFlags;
    if (!target.mouseButtonQueue) {
        target.mouseButtonQueue = [NSMutableArray array];
    }
    [target.mouseButtonQueue addObject:[NSValue valueWithBytes:&packet objCType:@encode(MouseButtonPacket)]];
    if (input_debug_enabled()) {
        NSString *title = target.window.title ?: @"<untitled>";
        NSLog(@"[bridge-input] mouse_button target=\"%@\" btn=%d pressed=%d x=%.1f y=%.1f eventWindow=%@",
              title,
              button,
              pressed ? 1 : 0,
              packet.x,
              packet.y,
              event.window ? event.window.title : @"<nil>");
    }
}

static BOOL windowCanAcceptPointerInput(WindowWrapper *wrapper) {
    if (!wrapper || !wrapper.window) return NO;
    if (![NSApp isActive]) return NO;
    if (![wrapper.window isKeyWindow] && !(wrapper.fullscreenHeader.active && wrapper.fullscreenHeader.header.window.isKeyWindow)) return NO;
    if ((wrapper.window.occlusionState & NSWindowOcclusionStateVisible) == 0) return NO;
    return YES;
}

static BOOL viewCanPresentCursor(NSView *view) {
    NSWindow *window = view.window;
    if (!window || !window.isVisible || view.hidden || !NSApp.isActive) return NO;
    WindowWrapper *wrapper = wrapperForWindow(window);
    // Native dragging owns its own feedback, not the retained UI cursor.
    if (wrapper.metalView.zenitDragSessionActive) return NO;
    NSPoint screen = NSEvent.mouseLocation;
    NSPoint local = [view convertPoint:[window convertPointFromScreen:screen] fromView:nil];
    const BOOL dragging = wrapper.leftButtonPressed || wrapper.rightButtonPressed || wrapper.middleButtonPressed;
    // Match the host's input-delivery policy. Inspector pick windows explicitly
    // receive inactive hover; ordinary non-key windows do not, so their cached
    // desired cursor must not be presented at an unobserved pointer location.
    if (!windowCanAcceptPointerInput(wrapper) && !wrapper.acceptsMouseMovedWhileInactive && !dragging) return NO;
    if (!dragging) {
        if (!NSPointInRect(local, view.visibleRect)) return NO;
        NSInteger top = [NSWindow windowNumberAtPoint:screen belowWindowWithWindowNumber:0];
        if (top != window.windowNumber) return NO;
    }
    // Do not overwrite embedded native controls. Dragging outside our bounds
    // remains eligible until the pointer sequence ends.
    if (NSPointInRect(local, view.bounds)) {
        NSPoint parentPoint = [view.superview convertPoint:[window convertPointFromScreen:screen] fromView:nil];
        if ([view hitTest:parentPoint] != view) return NO;
    }
    return YES;
}

/// Modifier alone press/release macOS dispatches
/// NSEventTypeFlagsChanged, NOT keyDown/keyUp. Same event type,
/// distinguish by flag-bit still set. Without: modifier-only interactions
/// (highlight-under-Cmd) never fire (Cmd+G combos fine, they're keyDown).
static BOOL flagsChangedPressed(NSEvent *event) {
    unsigned short kc = event.keyCode;
    NSEventModifierFlags flags = event.modifierFlags;
    switch (kc) {
        case 54: case 55: return (flags & NSEventModifierFlagCommand) != 0; // Cmd right/left
        case 56: case 60: return (flags & NSEventModifierFlagShift) != 0; // Shift left/right
        case 59: case 62: return (flags & NSEventModifierFlagControl) != 0; // ctrl left/right
        case 58: case 61: return (flags & NSEventModifierFlagOption) != 0; // Option left/right
        case 57: return (flags & NSEventModifierFlagCapsLock) != 0;
        default: return NO;
    }
}

// `MetalView` must remain the window's first responder so keyboard shortcuts,
// menus, and non-text controls keep receiving raw key events. That does not
// mean every focused zenit node is an NSTextInputClient, though. Cx's single
// TextInputSession derives this flag from the focused node's live
// TextInputClient contract. Only then may AppKit feed a key into the input context.
// Otherwise IMEs can open a candidate window for buttons, sliders, or even an
// unfocused window root, positioned at firstRectForCharacterRange's fallback.
static BOOL zenitTextInputIsActive(WindowWrapper *target) {
    return target && target.metalView && target.textInputEnabled;
}

// An input-source change while the app stays active does not reliably
// reactivate an existing custom NSTextInputContext. Cross the same responder
// boundary that AppKit uses on an application deactivate/reactivate, but keep
// zenit's logical widget focus intact.
static NSTextInputContext *synchronizeTextInputSource(WindowWrapper *target,
                                                       NSString *reason) {
    if (!target || !target.metalView) return nil;
    NSTextInputContext *context = [target.metalView inputContext];
    NSString *selected = context.selectedKeyboardInputSource;
    NSString *previous = target.lastKeyboardInputSource;
    if (!previous) {
        target.lastKeyboardInputSource = selected;
        return context;
    }
    if ((!selected && !previous) || [selected isEqualToString:previous]) {
        return context;
    }

    macos_ime_discard((__bridge void *)target);
    [context invalidateCharacterCoordinates];
    const BOOL wasFirstResponder = target.window.firstResponder == target.metalView;
    if (wasFirstResponder) {
        [target.window makeFirstResponder:nil];
    }
    NSTextInputContext *replacement = [[NSTextInputContext alloc] initWithClient:target.metalView];
    replacement.selectedKeyboardInputSource = selected;
    target.metalView.zenitInputContext = replacement;
    if (wasFirstResponder) [target.window makeFirstResponder:target.metalView];
    context = [target.metalView inputContext];
    target.lastKeyboardInputSource = context.selectedKeyboardInputSource ?: selected;
    if (input_debug_enabled()) {
        NSLog(@"[ime-debug] rebound input context reason=%@ source=%@ -> %@ current=%d",
              reason,
              previous ?: @"<nil>",
              target.lastKeyboardInputSource ?: @"<nil>",
              [NSTextInputContext currentInputContext] == context);
    }
    return context;
}

static void enqueueKeyEvent(WindowWrapper *target, NSEvent *event) {
    if (!target) return;
    KeyEventPacket packet;
    packet.sequence = nextInputEventSequence();
    packet.keycode = event.keyCode;
    packet.modifiers = (uint32_t)event.modifierFlags;
    packet.pressed = (event.type == NSEventTypeKeyDown) ? YES :
                     (event.type == NSEventTypeFlagsChanged ? flagsChangedPressed(event) : NO);
    packet.character = 0;

    // WARNING: accessing characters on flagsChanged throws
    // NSInternalInconsistencyException.
    NSString *chars = (event.type == NSEventTypeKeyDown) ? event.characters : nil;
    if (event.type == NSEventTypeKeyDown && chars.length > 0) {
        unichar ch = [chars characterAtIndex:0];
        packet.character = (ch < 128) ? (char)ch : 0;
    }

    if (!target.keyEventQueue) {
        target.keyEventQueue = [NSMutableArray array];
    }
    [target.keyEventQueue addObject:[NSValue valueWithBytes:&packet objCType:@encode(KeyEventPacket)]];
}

// poll events
int macos_poll_events(void* window_ptr) {
    // Legacy single-window callers share the exact same dispatcher as the
    // multi-window runtime. Keeping two AppKit loops caused years of drift in
    // menu, flagsChanged, updateWindows and IME activation semantics.
    pumpAppEventsWithTimeout(0);
    macos_update_window_mouse(window_ptr);
    WindowWrapper *sharedWrapper = (__bridge WindowWrapper*)window_ptr;
    if (!sharedWrapper.window) sharedWrapper.shouldClose = YES;
    return sharedWrapper.shouldClose ? 0 : 1;
#if 0
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.pollSeq += 1;

        // Bringing the app forward and assigning first responder is sufficient;
        // AppKit binds the input context to the active input source.
        static BOOL didForceActivate = NO;
        if (!didForceActivate) {
            didForceActivate = YES;
            zenitActivateApplication();
            if (wrapper.metalView && wrapper.window.firstResponder != wrapper.metalView) {
                [wrapper.window makeFirstResponder:wrapper.metalView];
            }
        }

        // handle all pending events
        while (true) {
            // live resize switch to NSEventTrackingRunLoopMode, avoid lost
            // events
            NSString *mode = (wrapper.window && wrapper.window.inLiveResize) ? NSEventTrackingRunLoopMode : NSDefaultRunLoopMode;
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate distantPast]
                                                   inMode:mode
                                                  dequeue:YES];
            if (!event) break;

            // determine event belongs to which window
            WindowWrapper *target = targetWrapperForEvent(event, wrapper);

            // handle keyboard events. FlagsChanged separate: no characters,
            // skip menu keyEquivalent/firstResponder keyDown logic.
            if (event.type == NSEventTypeFlagsChanged) {
                enqueueKeyEvent(target, event);
                // Caps Lock / Shift can switch an IME between native and ASCII
                // modes. Keeping this event inside the Zig queue leaves the
                // menu-bar source looking correct while InputMethodKit remains
                // stuck in its previous mode.
                [NSApp sendEvent:event];
                continue;
            }
            if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
                if (getenv("ZENIT_DEBUG_MENU")) {
                    NSLog(@"[menu-debug] key event type=%lu keyCode=%d flags=0x%lx", (unsigned long)event.type, event.keyCode, (unsigned long)event.modifierFlags);
                }
                BOOL isCmd = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
                NSString *key = event.charactersIgnoringModifiers;

                // Cmd+Q: exit app (main window shouldClose)
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    [key isEqualToString:@"q"]) {
                    wrapper.shouldClose = YES;
                }

                // Shift+Cmd+W: close current focused window. Bare Cmd+W
                // unintercepted, let go to Zig islandKeyHandler (close current tab).
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    (event.modifierFlags & NSEventModifierFlagShift) != 0 &&
                    [key.lowercaseString isEqualToString:@"w"]) {
                    target.shouldClose = YES;
                    continue;
                }

                // Cmd+`: same-app window switch
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    event.keyCode == 50) {
                    NSWindow *keyWindow = [NSApp keyWindow];
                    for (NSWindow *w in g_window_list) {
                        if (w != keyWindow && w.isVisible) {
                            zenitPresentWindow(w);
                            break;
                        }
                    }
                    continue;
                }

                // Menu shortcuts: never call sendEvent (avoid beep), keyEquivalent
                // dispatch in sendEvent - skip, custom menu shortcuts (Cmd+P) never
                // fire (verify_menu.sh caught). Menu-consumed keys skip zig queue.
                const bool has_cmd_or_ctrl = (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
                if (event.type == NSEventTypeKeyDown && has_cmd_or_ctrl) {
                    BOOL menu_ate = [NSApp.mainMenu performKeyEquivalent:event];
                    if (getenv("ZENIT_DEBUG_MENU")) {
                        NSLog(@"[menu-debug] keyEquivalent keyCode=%d chars='%@' ate=%d", event.keyCode, event.charactersIgnoringModifiers, menu_ate);
                    }
                    if (menu_ate) continue;
                }

                // record key event to target window (queue, avoid high-input clobber)
                enqueueKeyEvent(target, event);
                if (event.type == NSEventTypeKeyDown) {
                    NSResponder *fr = [target.window firstResponder];
                    BOOL is_metalview = (fr == target.metalView);
                    if (!is_metalview) {
                        if (input_debug_enabled()) {
                            NSLog(@"[ime-debug] firstResponder MISMATCH: fr=%@ metalView=%@ — forcing makeFirstResponder", fr, target.metalView);
                        }
                        [target.window makeFirstResponder:target.metalView];
                    }
                    if (zenitTextInputIsActive(target)) {
                        NSTextInputContext *ic = synchronizeTextInputSource(target, @"keyDown");
                        target.keyDispatchSeq += 1;
                        if (input_debug_enabled()) {
                            NSLog(@"[ime-debug] dispatch inputSource=%@ currentContext=%d active=%d",
                                  ic.selectedKeyboardInputSource,
                                  [NSTextInputContext currentInputContext] == ic,
                                  [NSApp isActive]);
                        }
                        BOOL handled = [ic handleEvent:event];
                        if (input_debug_enabled()) {
                            NSLog(@"[ime-debug] handleEvent returned=%d keyCode=%d char='%@'",
                                  handled, event.keyCode, event.characters);
                        }
                    }
                }

                // don't call sendEvent, avoid beep. We handled key ourselves.
                continue;
            }

            // track mouse button state (route to target) + push queue
            switch (event.type) {
                case NSEventTypeLeftMouseDown: {
                    if (target.chromeHitCallback) {
                        NSPoint p=[target.window.contentView convertPoint:event.locationInWindow fromView:nil];
                        float y=(float)(target.window.contentView.bounds.size.height-p.y);
                        if (!chromePointInNativeButton(target,p) && target.chromeHitCallback(target.chromeHitContext,(float)p.x,y)==2 && !(target.window.styleMask & NSWindowStyleMaskFullScreen)) {
                            [target.window performWindowDragWithEvent:event];
                            break;
                        }
                    }
                    // custom TitleBar drag: if click in drag area, trigger window drag
                    // not pass to Zig
                    if (!target.chromeHitCallback && target.titlebarDragHeight > 0) {
                        NSRect contentFrame = [target.window.contentView frame];
                        NSPoint loc = [event locationInWindow];
                        float y_from_top = (float)(contentFrame.size.height - loc.y);
                        if (y_from_top < target.titlebarDragHeight && y_from_top >= 0) {
                            float x = (float)loc.x;
                            float w = (float)contentFrame.size.width;
                            // exclude traffic lights (left 78px), window edge resize zones (each
                            // 5px, avoid system resize), right action buttons
                            // (titlebarDragRightInset).
                            float resize_inset = 5.0f;
                            float right_inset = target.titlebarDragRightInset > 0 ? target.titlebarDragRightInset : resize_inset;
                            if (x > 78 && x < (w - right_inset)) {
                                int on_control = 0;
                                if (target.titlebarHitCallback) {
                                    on_control = target.titlebarHitCallback(target.titlebarHitContext, x, y_from_top);
                                }
                                if (!on_control) {
                                    [target.window performWindowDragWithEvent:event];
                                    break;
                                }
                            }
                        }
                    }
                    if (getenv("ZENIT_DEBUG_MOUSEEV")) {
                        fprintf(stderr, "[mouseev] DOWN ts=%.3f click=%ld pressure=%.2f win=%ld subtype=%ld\n",
                                event.timestamp, (long)event.clickCount, event.pressure,
                                (long)(event.window ? event.window.windowNumber : -1), (long)event.subtype);
                    }
                    target.leftButtonPressed = YES;
                    enqueueMouseButton(target, 0, YES, event);
                    break;
                }
                case NSEventTypeLeftMouseUp:
                    if (getenv("ZENIT_DEBUG_MOUSEEV")) {
                        fprintf(stderr, "[mouseev] UP ts=%.3f click=%ld pressure=%.2f win=%ld subtype=%ld\n",
                                event.timestamp, (long)event.clickCount, event.pressure,
                                (long)(event.window ? event.window.windowNumber : -1), (long)event.subtype);
                    }
                    target.leftButtonPressed = NO;
                    enqueueMouseButton(target, 0, NO, event);
                    break;
                case NSEventTypeRightMouseDown:
                    target.rightButtonPressed = YES;
                    enqueueMouseButton(target, 1, YES, event);
                    break;
                case NSEventTypeRightMouseUp:
                    target.rightButtonPressed = NO;
                    enqueueMouseButton(target, 1, NO, event);
                    break;
                case NSEventTypeOtherMouseDown:
                    if (event.buttonNumber == 2) {
                        target.middleButtonPressed = YES;
                        enqueueMouseButton(target, 2, YES, event);
                    }
                    break;
                case NSEventTypeOtherMouseUp:
                    if (event.buttonNumber == 2) {
                        target.middleButtonPressed = NO;
                        enqueueMouseButton(target, 2, NO, event);
                    }
                    break;
                case NSEventTypeMouseMoved:
                case NSEventTypeLeftMouseDragged:
                case NSEventTypeRightMouseDragged:
                case NSEventTypeOtherMouseDragged:
                    // drag sends Dragged not MouseMoved; both in native motion queue,
                    // preserve relative order with key/button/scroll.
                    enqueueMouseMove(target, event);
                    break;
                case NSEventTypeScrollWheel:
                    {
                        NSPoint scrollInWindow = zenitLogicalEventPoint(target,event);
                        NSRect contentFrame = [target.window.contentView frame];
                        ScrollEventPacket packet;
                        packet.sequence = nextInputEventSequence();
                        packet.x = (float)scrollInWindow.x;
                        packet.y = (float)scrollInWindow.y;
                        zenitScrollDeltas(event, &packet.dx, &packet.dy);
                        packet.phase = zenitScrollPhaseCode(event);
                        packet.momentum = zenitMomentumPhaseCode(event);
                        packet.modifiers = (uint32_t)event.modifierFlags;
                        if (!target.scrollEventQueue) {
                            target.scrollEventQueue = [NSMutableArray array];
                        }
                        [target.scrollEventQueue addObject:[NSValue valueWithBytes:&packet objCType:@encode(ScrollEventPacket)]];
                    }
                    break;
                case NSEventTypeMagnify:
                    {
                        NSPoint magInWindow = zenitLogicalEventPoint(target,event);
                        NSRect magContentFrame = [target.window.contentView frame];
                        MagnifyEventPacket mpacket;
                        mpacket.sequence = nextInputEventSequence();
                        mpacket.x = (float)magInWindow.x;
                        mpacket.y = (float)magInWindow.y;
                        mpacket.magnification = (float)event.magnification;
                        if (event.phase == NSEventPhaseBegan) mpacket.phase = 0;
                        else if (event.phase == NSEventPhaseEnded) mpacket.phase = 2;
                        else if (event.phase == NSEventPhaseCancelled) mpacket.phase = 3;
                        else mpacket.phase = 1;
                        if (!target.magnifyEventQueue) {
                            target.magnifyEventQueue = [NSMutableArray array];
                        }
                        [target.magnifyEventQueue addObject:[NSValue valueWithBytes:&mpacket objCType:@encode(MagnifyEventPacket)]];
                    }
                    break;
                default:
                    break;
            }

            [NSApp sendEvent:event];
            if (event.type == NSEventTypeMouseMoved || event.type == NSEventTypeLeftMouseDragged || event.type == NSEventTypeRightMouseDragged || event.type == NSEventTypeOtherMouseDragged) {
                // AppKit can reset the cursor on non-key hover or crossing the
                // host boundary while the logical shape is unchanged.
                [target.metalView presentDesiredCursor];
            }
        }

        // [NSApp run] after event calls updateWindows - AppKit activates
        // key window firstResponder's NSTextInputContext, per-context input
        // method binding. Custom pump skips: on 'different IM per App' machine,
        // switch Chinese, this window InputContext still old source, keys
        // ASCII-fall, CJK totally broken flaky. Direct [ic activate] private,
        // sync-stalls InputMethodKit, unusable; updateWindows equivalent.
        [NSApp updateWindows];

        // update mouse position only current interactive window, avoid
        // background/occluded hover. Exception: acceptsMouseMovedWhileInactive
        // (inspector pick), update non-key (cross-window hover). Note: drag
        // mouseLocation already by event, use directly, don't query
        // mouseLocationOutsideOfEventStream (may stale during drag).
        BOOL canAccept = windowCanAcceptPointerInput(wrapper);
        BOOL inactiveHover = !canAccept && wrapper.acceptsMouseMovedWhileInactive
                             && wrapper.window && [NSApp isActive];
        BOOL isDragging = wrapper.leftButtonPressed || wrapper.rightButtonPressed || wrapper.middleButtonPressed;
        if (canAccept || inactiveHover) {
            if (!isDragging) {
                // non-drag use system API query real-time (support hover without
                // events)
                NSPoint mouseInWindow = [wrapper.window mouseLocationOutsideOfEventStream];
                NSRect contentFrame = [wrapper.window.contentView frame];
                wrapper.mouseLocation = NSMakePoint(mouseInWindow.x,
                                                    contentFrame.size.height - mouseInWindow.y);
                if(wrapper.fullscreenHeader.active) wrapper.mouseLocation=zenitLogicalScreenPoint(wrapper,NSEvent.mouseLocation);
            }
            // drag mouseLocation already by LeftMouseDragged, unchanged
            if (inactiveHover) {
                // non-key window don't track button (avoid mis-trigger)
                wrapper.leftButtonPressed = NO;
                wrapper.rightButtonPressed = NO;
                wrapper.middleButtonPressed = NO;
            }
        } else {
            // drag (button down) retain position/button, don't zero. isKeyWindow
            // may be NO during drag, handle drag events anyway.
            if (!isDragging) {
                wrapper.mouseLocation = NSMakePoint(-1, -1);
                wrapper.leftButtonPressed = NO;
                wrapper.rightButtonPressed = NO;
                wrapper.middleButtonPressed = NO;
            }
        }

        // check window destroyed
        if (!wrapper.window) {
            wrapper.shouldClose = YES;
        }

        return wrapper.shouldClose ? 0 : 1;
    }
#endif
}

// get window size
void macos_get_window_size(void* window_ptr, int* width, int* height) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) { *width = 0; *height = 0; return; }
        // The logical viewport belongs to the render view in both windowed
        // and fullscreen mode. A persistent clipped body host can have a
        // different height; switching to its frame on exit changes the
        // projection independently of the drawable and shifts the whole UI.
        NSRect frame = wrapper.metalView.bounds;
        *width = (int)frame.size.width;
        *height = (int)frame.size.height;
    }
}

// set window size (content size, same coords as macos_get_window_size/
// initWithContentRect:). Keep center fixed, avoid jump.
void macos_set_window_size(void* window_ptr, int width, int height) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return;
        if (width <= 0 || height <= 0) return;
        NSWindow *w = wrapper.window;
        NSRect old_frame = w.frame;
        [w setContentSize:NSMakeSize((CGFloat)width, (CGFloat)height)];
        // setContentSize: anchors upper-left; recenter to original center.
        NSRect new_frame = w.frame;
        new_frame.origin.x = old_frame.origin.x + (old_frame.size.width - new_frame.size.width) / 2.0;
        new_frame.origin.y = old_frame.origin.y + (old_frame.size.height - new_frame.size.height) / 2.0;
        [w setFrame:new_frame display:YES];
    }
}

// get DPI scale (Retina: 2.0, normal: 1.0)
double macos_get_scale_factor(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        CGFloat forced = zenitRenderScaleOverride();
        if (forced > 0) return (double)forced;
        if (!wrapper.window) return 2.0; // default Retina
        CGFloat scale = wrapper.window.backingScaleFactor;
        return (double)scale;
    }
}

// get drawable size (considers retina scale)
void macos_get_drawable_size(void* view_ptr, int* width, int* height) {
    @autoreleasepool {
        MetalView *view = (__bridge MetalView*)view_ptr;
        // use view bounds * scale direct, avoid drawableSize stale during
        // live resize
        CGSize size = view.bounds.size;
        CGFloat scale = zenitRenderScaleOverride();
        if (scale <= 0) scale = view.window ? view.window.backingScaleFactor : [[NSScreen mainScreen] backingScaleFactor];
        *width = (int)(size.width * scale);
        *height = (int)(size.height * scale);
    }
}

// get mouse position (logical px, relative window content, Y down)
void macos_get_mouse_position(void* window_ptr, float* x, float* y) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        *x = (float)wrapper.mouseLocation.x;
        *y = (float)wrapper.mouseLocation.y;
    }
}

// get native mouse moved/dragged (queue, consume one each).
int macos_get_mouse_move_event(void* window_ptr, float* x, float* y,
                               float* dx, float* dy, uint32_t* modifiers,
                               unsigned long long* sequence) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper.mouseMoveQueue.count > 0) {
            NSValue *eventValue = wrapper.mouseMoveQueue.firstObject;
            [wrapper.mouseMoveQueue removeObjectAtIndex:0];
            MouseMovePacket packet;
            [eventValue getValue:&packet];
            *x = packet.x;
            *y = packet.y;
            *dx = packet.dx;
            *dy = packet.dy;
            *modifiers = packet.modifiers;
            if (sequence) *sequence = packet.sequence;
            return 1;
        }
        *x = 0;
        *y = 0;
        *dx = 0;
        *dy = 0;
        *modifiers = 0;
        if (sequence) *sequence = 0;
        return 0;
    }
}

void macos_get_input_queue_metrics(unsigned long long* mouse_move_coalesced,
                                   unsigned long long* ime_preedit_coalesced) {
    if (mouse_move_coalesced) *mouse_move_coalesced = g_mouse_move_coalesced_count;
    if (ime_preedit_coalesced) *ime_preedit_coalesced = g_ime_preedit_coalesced_count;
}

// Set mouse cursor shape. shape matches the Zig CursorShape enum:
// 0=inherit(noop), 1=default, 2=pointer, 3=text, 4=crosshair,
// 5=move, 6=not_allowed, 7=grab, 8=grabbing, 9=ew_resize,
// 10=ns_resize, 11=nwse_resize, 12=nesw_resize, 13=col_resize,
// 14=row_resize, 15=wait, 16=progress, 17=help, 18=none
void macos_set_cursor_shape(void *window_ptr, int shape) {
    @autoreleasepool {
        if (!window_ptr) return;
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return;
        NSCursor *cursor = nil;
        switch (shape) {
            case 1:  cursor = [NSCursor arrowCursor]; break;
            case 2:  cursor = [NSCursor pointingHandCursor]; break;
            case 3:  cursor = [NSCursor IBeamCursor]; break;
            case 4:  cursor = [NSCursor crosshairCursor]; break;
            case 5: // move - macOS no direct, use openHand
            case 7:  cursor = [NSCursor openHandCursor]; break;
            case 6:  cursor = [NSCursor operationNotAllowedCursor]; break;
            case 8:  cursor = [NSCursor closedHandCursor]; break;
            case 9:  cursor = [NSCursor resizeLeftRightCursor]; break;
            case 10: cursor = [NSCursor resizeUpDownCursor]; break;
            case 11: // nwse_resize - macOS no direct API, use arrow
            case 12: // nesw_resize
                     cursor = [NSCursor arrowCursor]; break;
            case 13: cursor = [NSCursor resizeLeftRightCursor]; break;  // col_resize
            case 14: cursor = [NSCursor resizeUpDownCursor]; break;     // row_resize
            case 15: // wait - use system busy cursor (private API unavailable, arrow)
            case 16: // progress
                     cursor = [NSCursor arrowCursor]; break;
            case 17: cursor = [NSCursor arrowCursor]; break; // help (macOS no help cursor)
            case 18: { // Transparent image; never imbalance NSCursor hide/unhide.
                NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
                cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
                break;
            }
            case 20: // uncontrolled: native content owns presentation.
                wrapper.metalView.zenitDesiredCursor = nil;
                return;
            default: cursor = [NSCursor arrowCursor]; break;
        }
        wrapper.metalView.zenitDesiredCursor = cursor;
        [wrapper.metalView presentDesiredCursor];
    }
}

// Custom bitmap cursor: premultiply RGBA8 -> NSCursor(image + hotSpot). key is the caller's
// content-addressed key (same bitmap, same key); NSCursor is cached process-wide so frequent
// sets are a dict lookup. rgba is caller-borrowed (CGImage copies). hot_x/hot_y are top-left
// pixels; NSCursor hotSpot is also top-left (y from image top), so only divide by scale to get
// points; do not flip y (size_h - hot_y/scale mirrors the hotspot about the midline and
// mispoints every cursor except those with y at the midline).
static NSMutableDictionary<NSNumber *, NSCursor *> *g_custom_cursor_cache = nil;

void macos_set_custom_cursor(void *window_ptr,
                             const uint8_t *rgba,
                             size_t len,
                             unsigned int width,
                             unsigned int height,
                             float scale,
                             float hot_x,
                             float hot_y,
                             unsigned long long key) {
    @autoreleasepool {
        if (!window_ptr || !rgba || width == 0 || height == 0) return;
        if (scale <= 0.0f) scale = 1.0f;
        if ((size_t)width * (size_t)height * 4 > len) return;
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return;

        if (!g_custom_cursor_cache) {
            g_custom_cursor_cache = [NSMutableDictionary new];
        }
        NSCursor *cursor = g_custom_cursor_cache[@(key)];
        if (!cursor) {
            CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
            if (!color_space) return;
            CGContextRef ctx = CGBitmapContextCreate(
                (void *)rgba, width, height, 8, (size_t)width * 4, color_space,
                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CFRelease(color_space);
            if (!ctx) return;
            CGImageRef cg_image = CGBitmapContextCreateImage(ctx);
            CFRelease(ctx);
            if (!cg_image) return;
            NSImage *image = [[NSImage alloc] initWithCGImage:cg_image
                                                         size:NSMakeSize(width / scale, height / scale)];
            CFRelease(cg_image);
            if (!image) return;
            const CGFloat size_w = width / scale;
            const CGFloat size_h = height / scale;
            NSPoint hot = NSMakePoint(hot_x / scale, hot_y / scale);
            hot.x = MIN(MAX(hot.x, 0.0), size_w);
            hot.y = MIN(MAX(hot.y, 0.0), size_h);
            cursor = [[NSCursor alloc] initWithImage:image hotSpot:hot];
            if (!cursor) return;
            g_custom_cursor_cache[@(key)] = cursor;
        }
        wrapper.metalView.zenitDesiredCursor = cursor;
        [wrapper.metalView presentDesiredCursor];
    }
}

// check mouse button state; button: 0=left, 1=right, 2=middle
int macos_is_mouse_button_pressed(void* window_ptr, int button) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        switch (button) {
            case 0: return wrapper.leftButtonPressed ? 1 : 0;
            case 1: return wrapper.rightButtonPressed ? 1 : 0;
            case 2: return wrapper.middleButtonPressed ? 1 : 0;
            default: return 0;
        }
    }
}

// get key event; return: 1 if have, 0 if not
int macos_get_key_event(void* window_ptr, uint16_t* keycode, uint32_t* modifiers, char* character, int* pressed, unsigned long long* sequence) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper.keyEventQueue.count > 0) {
            NSValue *event_value = wrapper.keyEventQueue.firstObject;
            [wrapper.keyEventQueue removeObjectAtIndex:0];
            KeyEventPacket packet;
            [event_value getValue:&packet];
            *keycode = packet.keycode;
            *modifiers = packet.modifiers;
            *character = packet.character;
            *pressed = packet.pressed ? 1 : 0;
            if (sequence) *sequence = packet.sequence;
            return 1;
        }
        if (sequence) *sequence = 0;
        return 0;
    }
}

// Text kinds shared with MacOSWindow: 0=input, 1=preedit, 2=commit.
// Peeking lends bytes owned by the queued packet; consuming requires the same
// sequence. Neither insufficient caller capacity nor allocation failure pops it.
static NSMutableArray<ZenitTextEventPacket *> *zenitTextQueue(WindowWrapper *w, uint32_t kind) {
    if (kind == 0) {
        if (!w.inputTextQueue) w.inputTextQueue = [NSMutableArray array];
        if (w.inputTextQueue.count == 0 && w.inputText.length > 0) {
            [w.inputTextQueue addObject:zenitTextEventPacket(w.inputText, 0, ZENIT_IME_NO_REPLACEMENT, ZENIT_IME_NO_REPLACEMENT)];
            w.inputText = nil;
        }
        return w.inputTextQueue;
    }
    if (kind == 1) {
        if (!w.imePreeditQueue) w.imePreeditQueue = [NSMutableArray array];
        if (w.imePreeditQueue.count == 0 && w.hasImePreedit) {
            [w.imePreeditQueue addObject:zenitTextEventPacket(w.imePreeditText ?: @"", w.imePreeditCursorUtf16, w.imePreeditReplaceStartUtf8, w.imePreeditReplaceEndUtf8)];
        }
        return w.imePreeditQueue;
    }
    if (kind == 2) {
        if (!w.imeCommitQueue) w.imeCommitQueue = [NSMutableArray array];
        if (w.imeCommitQueue.count == 0 && w.hasImeCommit) {
            [w.imeCommitQueue addObject:zenitTextEventPacket(w.imeCommitText ?: @"", 0, w.imeCommitReplaceStartUtf8, w.imeCommitReplaceEndUtf8)];
            w.imeCommitText = nil;
        }
        return w.imeCommitQueue;
    }
    return nil;
}

// NSString can carry unpaired UTF-16 surrogates (IME/pasteboard/drag sources
// are not guaranteed well-formed). Strict UTF-8 encoding then returns nil — and
// even allowLossyConversion yields an *empty* NSData — which used to make the
// peek report -1, surface as BackendFailure and terminate App.run while the
// packet stayed at the queue head forever. Replace each unpaired surrogate with
// U+FFFD. One UTF-16 unit is replaced by one, so UTF-16 indices recorded in the
// packet (IME cursor) stay valid against the sanitized text.
static NSString *zenitStringReplacingLoneSurrogates(NSString *text) {
    const NSUInteger n = text.length;
    unichar *units = (unichar *)malloc((n ? n : 1) * sizeof(unichar));
    if (!units) return @"";
    [text getCharacters:units range:NSMakeRange(0, n)];
    for (NSUInteger i = 0; i < n; i++) {
        const unichar ch = units[i];
        if (CFStringIsSurrogateHighCharacter(ch)) {
            if (i + 1 < n && CFStringIsSurrogateLowCharacter(units[i + 1])) { i++; continue; }
            units[i] = 0xFFFD;
        } else if (CFStringIsSurrogateLowCharacter(ch)) {
            units[i] = 0xFFFD;
        }
    }
    NSString *clean = [[NSString alloc] initWithCharacters:units length:n];
    free(units);
    return clean ?: @"";
}

static uint32_t utf8_offset_for_utf16_index(NSString *text, uint32_t utf16_index) {
    NSUInteger index = MIN((NSUInteger)utf16_index, text.length);
    if (index > 0 && index < text.length) {
        unichar before = [text characterAtIndex:index - 1];
        unichar after = [text characterAtIndex:index];
        if (before >= 0xD800 && before <= 0xDBFF && after >= 0xDC00 && after <= 0xDFFF) index--;
    }
    NSData *prefix = [[text substringToIndex:index] dataUsingEncoding:NSUTF8StringEncoding];
    return prefix.length <= UINT32_MAX ? (uint32_t)prefix.length : UINT32_MAX;
}

int macos_peek_text_event(void *window_ptr, uint32_t kind, const uint8_t **bytes, size_t *length,
                         uint32_t *cursor, uint32_t *start, uint32_t *end, unsigned long long *sequence) {
    @autoreleasepool {
        *bytes = NULL; *length = 0; *cursor = 0; *sequence = 0;
        *start = *end = ZENIT_IME_NO_REPLACEMENT;
        if (!window_ptr || kind > 2) return -1;
        WindowWrapper *w = (__bridge WindowWrapper *)window_ptr;
        ZenitTextEventPacket *packet = zenitTextQueue(w, kind).firstObject;
        if (!packet) return 0;
        if (!packet.utf8Data) packet.utf8Data = [packet.text dataUsingEncoding:NSUTF8StringEncoding];
        if (!packet.utf8Data) {
            packet.text = zenitStringReplacingLoneSurrogates(packet.text ?: @"");
            packet.utf8Data = [packet.text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        }
        *bytes = packet.utf8Data.bytes;
        *length = packet.utf8Data.length;
        *cursor = kind == 1 ? utf8_offset_for_utf16_index(packet.text, packet.cursorUtf16) : 0;
        *start = packet.replaceStartUtf8; *end = packet.replaceEndUtf8;
        *sequence = packet.sequence;
        return 1;
    }
}

int macos_consume_text_event(void *window_ptr, uint32_t kind, unsigned long long sequence) {
    @autoreleasepool {
        if (!window_ptr || kind > 2 || sequence == 0) return 0;
        WindowWrapper *w = (__bridge WindowWrapper *)window_ptr;
        NSMutableArray<ZenitTextEventPacket *> *queue = zenitTextQueue(w, kind);
        if (queue.count == 0 || queue.firstObject.sequence != sequence) return 0;
        [queue removeObjectAtIndex:0];
        if (kind == 1) w.hasImePreedit = queue.count > 0;
        if (kind == 2) {
            w.hasImeCommit = queue.count > 0;
            if (!w.hasImeCommit) {
                w.imeCommitText = nil;
                w.imeCommitReplaceStartUtf8 = w.imeCommitReplaceEndUtf8 = ZENIT_IME_NO_REPLACEMENT;
            }
        }
        return 1;
    }
}

static int zenitReadTextEvent(void *window_ptr, uint32_t kind, char *buffer, int capacity, int *out_len,
                             uint32_t *cursor, uint32_t *start, uint32_t *end, unsigned long long *sequence) {
    const uint8_t *bytes = NULL; size_t length = 0;
    *out_len = 0;
    if (macos_peek_text_event(window_ptr, kind, &bytes, &length, cursor, start, end, sequence) != 1) return 0;
    // Legacy callers reserve a byte for NUL. Never return a successful prefix.
    if (!buffer || capacity <= 0 || length >= (size_t)capacity) return 0;
    if (length > 0) memcpy(buffer, bytes, length);
    buffer[length] = 0;
    if (!macos_consume_text_event(window_ptr, kind, *sequence)) return 0;
    *out_len = (int)length;
    return 1;
}

int macos_get_input_text(void *window_ptr, char *buffer, int buffer_size, unsigned long long *sequence) {
    int length = 0; uint32_t cursor, start, end;
    unsigned long long local_sequence;
    if (!sequence) sequence = &local_sequence;
    if (!zenitReadTextEvent(window_ptr, 0, buffer, buffer_size, &length, &cursor, &start, &end, sequence)) return 0;
    return length;
}

int macos_get_ime_preedit(void *window_ptr, char *buffer, int buffer_size, int *out_len, uint32_t *cursor,
                        uint32_t *start, uint32_t *end, unsigned long long *sequence) {
    unsigned long long local_sequence;
    return zenitReadTextEvent(window_ptr, 1, buffer, buffer_size, out_len, cursor, start, end, sequence ?: &local_sequence);
}

int macos_get_ime_commit(void *window_ptr, char *buffer, int buffer_size, int *out_len,
                       uint32_t *start, uint32_t *end, unsigned long long *sequence) {
    uint32_t cursor; unsigned long long local_sequence;
    return zenitReadTextEvent(window_ptr, 2, buffer, buffer_size, out_len, &cursor, start, end, sequence ?: &local_sequence);
}

// get scroll event; return: 1 if have, 0 if not; phase:
// zenitScrollPhaseCode; momentum: zenitMomentumPhaseCode
int macos_get_scroll_event(void* window_ptr, float* x, float* y, float* dx, float* dy, uint8_t* phase, uint8_t* momentum, uint32_t* modifiers, unsigned long long* sequence) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper.scrollEventQueue.count > 0) {
            NSValue *event_value = wrapper.scrollEventQueue.firstObject;
            [wrapper.scrollEventQueue removeObjectAtIndex:0];

            ScrollEventPacket packet;
            [event_value getValue:&packet];

            *x = packet.x;
            *y = packet.y;
            *dx = packet.dx;
            *dy = packet.dy;
            *phase = packet.phase;
            *momentum = packet.momentum;
            *modifiers = packet.modifiers;
            if (sequence) *sequence = packet.sequence;
            return 1;
        }
        *x = -1;
        *y = -1;
        *dx = 0;
        *dy = 0;
        *phase = 0;
        *momentum = 0;
        *modifiers = 0;
        if (sequence) *sequence = 0;
        return 0;
    }
}

// get trackpad pinch (magnify) event. magnification is relative
// increment: new_scale = old_scale * (1 + magnification). phase: 0=began
// 1=changed 2=ended 3=cancelled
int macos_get_magnify_event(void* window_ptr, float* x, float* y, float* magnification, uint8_t* phase, unsigned long long* sequence) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper.magnifyEventQueue.count > 0) {
            NSValue *event_value = wrapper.magnifyEventQueue.firstObject;
            [wrapper.magnifyEventQueue removeObjectAtIndex:0];

            MagnifyEventPacket packet;
            [event_value getValue:&packet];
            *x = packet.x;
            *y = packet.y;
            *magnification = packet.magnification;
            *phase = packet.phase;
            if (sequence) *sequence = packet.sequence;
            return 1;
        }
        *x = 0;
        *y = 0;
        *magnification = 0;
        *phase = 0;
        if (sequence) *sequence = 0;
        return 0;
    }
}

// get drag event (queue, consume one each). A peek lends
// immutable bytes until matching queue head consumed. Token opaque
// identity, compared only while queue owns packet.
int macos_peek_drag_event(void *window_ptr, float *x, float *y, uint8_t *kind,
                         const uint8_t **bytes, size_t *length, const void **token,
                         uint8_t *payload_kind, uint64_t *source_token, uint8_t *operation) {
    @autoreleasepool {
        *x = *y = 0; *kind = *payload_kind = *operation = 0;
        *bytes = NULL; *length = 0; *token = NULL; *source_token = 0;
        if (!window_ptr) return -1;
        WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
        NSMutableArray *queue = wrapper.metalView.dragEventQueue;
        NSDictionary *event = queue.firstObject;
        if (!event) return 0;
        NSData *data = event[@"utf8Data"];
        if (!data) {
            NSString *paths = event[@"paths"] ?: @"";
            data = [paths dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) {
                data = [zenitStringReplacingLoneSurrogates(paths) dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            }
            NSMutableDictionary *cached = [event mutableCopy];
            cached[@"utf8Data"] = data;
            event = [cached copy];
            queue[0] = event;
        }
        *x = [event[@"x"] floatValue]; *y = [event[@"y"] floatValue];
        *kind = [event[@"kind"] unsignedCharValue];
        *payload_kind = [event[@"payloadKind"] unsignedCharValue];
        *source_token = [event[@"sourceToken"] unsignedLongLongValue];
        *operation = [event[@"operation"] unsignedCharValue];
        *bytes = data.bytes; *length = data.length;
        *token = (__bridge const void *)event;
        return 1;
    }
}

int macos_consume_drag_event(void *window_ptr, const void *token) {
    @autoreleasepool {
        if (!window_ptr || !token) return 0;
        WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
        NSMutableArray *queue = wrapper.metalView.dragEventQueue;
        if ((__bridge const void *)queue.firstObject != token) return 0;
        [queue removeObjectAtIndex:0];
        return 1;
    }
}

// Legacy fixed-buffer calls also retain an oversized head for a larger retry.
int macos_get_drag_event(void* window_ptr, float* x, float* y, uint8_t* kind, char* paths_buf, int paths_buf_len, uint8_t* payload_kind, uint64_t* source_token, uint8_t* operation, uint8_t* paths_truncated) {
    const uint8_t *bytes; size_t length; const void *token;
    uint8_t local_payload, local_operation; uint64_t local_source;
    if (paths_truncated) *paths_truncated = 0;
    if (!payload_kind) payload_kind = &local_payload;
    if (!operation) operation = &local_operation;
    if (!source_token) source_token = &local_source;
    int status = macos_peek_drag_event(window_ptr, x, y, kind, &bytes, &length, &token, payload_kind, source_token, operation);
    if (status != 1) return 0;
    if (!paths_buf || paths_buf_len <= 0 || length >= (size_t)paths_buf_len) {
        if (paths_truncated) *paths_truncated = 1;
        return 0;
    }
    if (length > 0) memcpy(paths_buf, bytes, length);
    paths_buf[length] = 0;
    return macos_consume_drag_event(window_ptr, token);
}

int macos_set_drag_target_operations(void* window_ptr, uint8_t operations) {
    @autoreleasepool {
        if (!window_ptr) return 0;
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        MetalView *view = wrapper.metalView;
        if (!view) return 0;
        NSDragOperation nativeOperations = NSDragOperationNone;
        if ((operations & 1) != 0) nativeOperations |= NSDragOperationCopy;
        if ((operations & 2) != 0) nativeOperations |= NSDragOperationMove;
        if ((operations & 4) != 0) nativeOperations |= NSDragOperationLink;
        view.zenitDropAllowedOperations = nativeOperations;
        return 1;
    }
}

// Begin a source drag. Payload and preview bytes are copied into AppKit-owned
// objects before this function returns. Completion/cancellation is delivered by
// macos_get_drag_event(kind=4), keyed by token.
int macos_begin_drag(
    void* window_ptr,
    uint64_t token,
    uint8_t payload_kind,
    const uint8_t* payload,
    size_t payload_len,
    uint8_t allowed_operations,
    const uint8_t* preview_png,
    size_t preview_png_len,
    float preview_width,
    float preview_height,
    float hotspot_x,
    float hotspot_y
) {
    @autoreleasepool {
        if (!window_ptr || !payload || payload_len == 0 || token == 0) return 0;
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        MetalView *view = wrapper.metalView;
        if (!view || view.zenitDragSessionActive) return 0;
        NSEvent *event = NSApp.currentEvent;
        if (!event) return 0;

        NSData *payloadData = [NSData dataWithBytes:payload length:payload_len];
        NSString *payloadString = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding];
        id<NSPasteboardWriting> writer = nil;
        if (payload_kind == 0) {
            if (!payloadString) return 0;
            NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
            [item setString:payloadString forType:NSPasteboardTypeString];
            writer = item;
        } else if (payload_kind == 1) {
            if (!payloadString) return 0;
            NSURL *url = [NSURL URLWithString:payloadString];
            if (!url.scheme) url = [NSURL fileURLWithPath:payloadString];
            if (!url) return 0;
            if (url.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
                // Existing file dragged out to Finder/other apps: write an
                // explicit NSPasteboardTypeFileURL representation (Finder
                // performs the copy/move) plus a plain-text path fallback.
                // TODO(file-promise): support "generate on drop" via
                // NSFilePromiseProvider; needs a retained delegate object per
                // drag session (lifecycle owned by the view), deferred.
                NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
                [item setString:url.absoluteString forType:NSPasteboardTypeFileURL];
                [item setString:url.path forType:NSPasteboardTypeString];
                writer = item;
            } else {
                // Non-file URL, or file path that does not exist (yet): keep
                // the legacy NSURL writer behavior.
                writer = url;
            }
        } else if (payload_kind == 2) {
            NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
            [item setData:payloadData forType:ZenitInternalDragType];
            writer = item;
        } else {
            return 0;
        }

        NSDragOperation nativeOperations = NSDragOperationNone;
        if ((allowed_operations & 1) != 0) nativeOperations |= NSDragOperationCopy;
        if ((allowed_operations & 2) != 0) nativeOperations |= NSDragOperationMove;
        if ((allowed_operations & 4) != 0) nativeOperations |= NSDragOperationLink;
        if (nativeOperations == NSDragOperationNone) return 0;

        NSDraggingItem *draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:writer];
        NSImage *preview = nil;
        if (preview_png && preview_png_len > 0) {
            NSData *previewData = [NSData dataWithBytes:preview_png length:preview_png_len];
            preview = [[NSImage alloc] initWithData:previewData];
            if (!preview) return 0;
        }
        if (!preview) preview = [NSImage imageNamed:NSImageNameMultipleDocuments];

        NSPoint viewPoint = [view convertPoint:event.locationInWindow fromView:nil];
        NSRect frame = NSMakeRect(
            viewPoint.x - hotspot_x,
            viewPoint.y - (preview_height - hotspot_y),
            preview_width,
            preview_height
        );
        [draggingItem setDraggingFrame:frame contents:preview];
        view.zenitDragToken = token;
        view.zenitDragAllowedOperations = nativeOperations;
        view.zenitDragSessionActive = YES;
        NSDraggingSession *session = [view beginDraggingSessionWithItems:@[ draggingItem ]
                                                                   event:event
                                                                  source:view];
        if (!session) {
            view.zenitDragSessionActive = NO;
            view.zenitDragToken = 0;
            view.zenitDragAllowedOperations = NSDragOperationNone;
            return 0;
        }
        session.animatesToStartingPositionsOnCancelOrFail = YES;
        return 1;
    }
}

// get mouse button event (queue, consume one each); return: 1 have, 0
// not; button: 0=left, 1=right, 2=middle; pressed: 1=down, 0=up
/// modifiers can be NULL (old caller); non-NULL write back original
/// NSEventModifierFlags.
int macos_get_mouse_button_event_ex(void* window_ptr, float* x, float* y, int* button, int* pressed, uint32_t* modifiers, unsigned long long* sequence) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper.mouseButtonQueue.count > 0) {
            NSValue *event_value = wrapper.mouseButtonQueue.firstObject;
            [wrapper.mouseButtonQueue removeObjectAtIndex:0];

            MouseButtonPacket packet;
            [event_value getValue:&packet];

            *x = packet.x;
            *y = packet.y;
            *button = packet.button;
            *pressed = packet.pressed ? 1 : 0;
            if (modifiers) *modifiers = packet.modifiers;
            if (sequence) *sequence = packet.sequence;
            return 1;
        }
        if (sequence) *sequence = 0;
        return 0;
    }
}

int macos_get_mouse_button_event(void* window_ptr, float* x, float* y, int* button, int* pressed) {
    return macos_get_mouse_button_event_ex(window_ptr, x, y, button, pressed, NULL, NULL);
}

// query window should close (don't consume event)
int macos_should_close(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return wrapper.shouldClose ? 1 : 0;
    }
}

// update window mouse position (for non-key window)
void macos_update_mouse_position(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return;
        NSPoint mouseInWindow = [wrapper.window mouseLocationOutsideOfEventStream];
        NSRect contentFrame = [wrapper.window.contentView frame];
        wrapper.mouseLocation = NSMakePoint(mouseInWindow.x,
                                            contentFrame.size.height - mouseInWindow.y);
                if(wrapper.fullscreenHeader.active) wrapper.mouseLocation=zenitLogicalScreenPoint(wrapper,NSEvent.mouseLocation);
    }
}

// check window needs GPU present (visible and not fully occluded)
int macos_should_render_window(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return 0;
        if (wrapper.fullscreenHeader.pendingFullscreen && CACurrentMediaTime()<wrapper.fullscreenHeader.pendingDeadline) return 1; // One bounded prewarm can render while occluded.
        if (zenitBackgroundE2E()) return 1; // RPC screenshots still need GPU frames while occluded.
        if (!wrapper.window.isVisible) return 0;
        if ((wrapper.window.occlusionState & NSWindowOcclusionStateVisible) == 0) return 0;
        return 1;
    }
}

// set non-active window accept mouse move (inspector pick cross-
// window hover)
void macos_set_accepts_mouse_while_inactive(void* window_ptr, int accepts) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.acceptsMouseMovedWhileInactive = (accepts != 0);
    }
}

// destroy window. get system titlebar height (traffic lights area)
/// The system has an app to open this file (Launch Services judgment).
/// Host distinguishes two failures: no editor (prompt install) vs installed but won't start
/// (disk/perms/sandbox). **Can't rely on open(1) return**: it only delivers to Launch Services
/// and typically succeeds even with no handler, turning a double-click into a silent failure.
int macos_has_handler_for_file(const char* path) {
    @autoreleasepool {
        if (!path) return 0;
        NSString *p = [NSString stringWithUTF8String:path];
        if (!p) return 0;
        NSURL *url = [NSURL fileURLWithPath:p];
        if (!url) return 0;
        NSURL *app = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url];
        return app ? 1 : 0;
    }
}

float macos_get_titlebar_height(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        NSWindow *window = wrapper.window;
        // contentLayoutRect is content area excluding titlebar; window total
        // height - contentLayoutRect height = titlebar height
        CGFloat content_height = window.contentLayoutRect.size.height;
        CGFloat frame_height = [window.contentView frame].size.height;
        return (float)(frame_height - content_height);
    }
}

// begin window drag (TitleBar custom drag area calls)
void macos_perform_window_drag(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        NSWindow *window = wrapper.window;
        NSEvent *event = window.currentEvent;
        if (event) {
            [window performWindowDragWithEvent:event];
        }
    }
}

// set traffic lights (red/yellow/green buttons) vertical center in
// custom titlebar. inset_y: button center distance from top (logical px)
void macos_set_traffic_lights_inset(void* window_ptr, float inset_x, float inset_y) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.hasTrafficLightsInset = YES;
        wrapper.trafficLightsInsetX = inset_x;
        wrapper.trafficLightsInsetY = inset_y;
        [wrapper applyTrafficLightsInset];
    }
}

// register hit-driven drag area callback (NULL clear, fall back pure
// rect)
void macos_set_titlebar_hit_callback(void* window_ptr, int (*cb)(void* ctx, float x, float y), void* ctx) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.titlebarHitCallback = cb;
        wrapper.titlebarHitContext = ctx;
    }
}

// set custom TitleBar drag area height
void macos_set_titlebar_drag_height(void* window_ptr, float height) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.titlebarDragHeight = height;
    }
}

// Window title after creation (Window menu, Mission Control, accessibility;
// hidden in the titlebar when the app draws its own header).
void macos_set_window_title(void* window_ptr, const char* title) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        NSString *text = title ? [NSString stringWithUTF8String:title] : nil;
        if (!wrapper.window || !text) return;
        [wrapper.window setTitle:text];
    }
}

// set TitleBar right exclude drag width (for action buttons click)
void macos_set_titlebar_drag_right_inset(void* window_ptr, float inset) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.titlebarDragRightInset = inset;
    }
}

// Commit a close request using AppKit's own close path. Standard windows use
// performClose: so the traffic-light behavior remains native; borderless helper
// windows have no close button, so close is the canonical equivalent.
//
// No animation is authored here. NSWindow's inferred animationBehavior and the
// user's system accessibility preferences remain authoritative. We only read
// AppKit's current duration as a lifetime barrier for deferred destruction.
int macos_begin_window_close(void* window_ptr) {
    @autoreleasepool {
        if (!window_ptr) return 0;
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper || !wrapper.window) return 0;
        if (wrapper.nativeCloseStarted) return 1;

        zenitTraceFullscreen(wrapper,"begin_window_close");
        wrapper.closeCommitted = YES;
        wrapper.nativeCloseStarted = YES;
        wrapper.nativeCloseObserved = NO;
        wrapper.nativeCloseRetentionElapsed = NO;
        wrapper.nativeCloseCompleted = NO;
        // A queued resign-key block must never call back into a WindowContext
        // after Zig has committed that context to closing.
        wrapper.resignKeyCallback = NULL;
        wrapper.resignKeyContext = NULL;

        // End input while this window still owns its responder lifecycle.
        // Delayed resource destruction runs after another window has become
        // key; messaging the old input context then can disconnect IMK's
        // newly active session and silently swallow the next window's keys.
        macos_set_text_input_enabled(window_ptr, 0);
        [wrapper.window makeFirstResponder:nil];

        NSLog(@"[macos_begin_window_close] window=%@ title=%@", wrapper.window, wrapper.window.title);

        // Read AppKit's current duration; do not create an animation or assign
        // a duration. NSWindow's inferred native animation remains completely
        // system-owned. The duration is only an ARC retention boundary because
        // AppKit exposes willClose, but no public did-finish-close callback for
        // its private NSWindow transform animation.
        NSTimeInterval retention = [NSAnimationContext currentContext].duration;
        if ([NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion) {
            retention = 0;
        }

        NSWindow *window = wrapper.window;
        if (window.styleMask & NSWindowStyleMaskClosable) {
            [window performClose:nil];
        } else {
            [window close];
        }

        __weak WindowWrapper *weakWrapper = wrapper;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(retention * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WindowWrapper *strongWrapper = weakWrapper;
            if (!strongWrapper) return;
            strongWrapper.nativeCloseRetentionElapsed = YES;
            if (strongWrapper.nativeCloseObserved) {
                strongWrapper.nativeCloseCompleted = YES;
            }
            NSLog(@"[macos_window_close_complete] window=%@ title=%@ retention=%.3fs",
                  strongWrapper.window, strongWrapper.window.title, retention);
            macos_post_empty_event();
        });
        return 1;
    }
}

int macos_window_close_completed(void* window_ptr) {
    @autoreleasepool {
        if (!window_ptr) return 0;
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return wrapper.nativeCloseCompleted ? 1 : 0;
    }
}

void macos_destroy_window(void* window_ptr) {
    @autoreleasepool {
        if (!window_ptr) return;
        WindowWrapper *wrapper = (__bridge_transfer WindowWrapper*)window_ptr;
        zenitTraceFullscreen(wrapper,"destroy.begin");
        [wrapper finishFullscreenEntry];[wrapper.fullscreenHeader discardClosedPresentation];
        zenitTraceFullscreen(wrapper,"destroy.presentation_discarded");
        [wrapper stopObservingTrafficLights];
        // stop and release display link: CVDisplayLinkStop sync-waits
        // callback thread exit, prevent destroy-after callback via dangling
        if (wrapper.displayLink) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CVDisplayLinkStop(wrapper.displayLink);
            CVDisplayLinkRelease(wrapper.displayLink);
#pragma clang diagnostic pop
            wrapper.displayLink = NULL;
            wrapper.displayLinkRunning = NO;
        }
        // Invalidate every callback/token before any native object is detached.
        // This is the hard lifetime boundary for live resize, titlebar hit
        // testing, IME, accessibility proxies, file promises, and drag source.
        [wrapper.metalView.liveResizeTicker invalidate];
        wrapper.metalView.liveResizeTicker = nil;
        wrapper.metalView.renderCallback = NULL;
        wrapper.metalView.renderContext = NULL;
        wrapper.chromeHitCallback = NULL; wrapper.chromeHitContext = NULL;
        wrapper.titlebarHitCallback = NULL;
        wrapper.titlebarHitContext = NULL;
        wrapper.resignKeyCallback = NULL;
        wrapper.resignKeyContext = NULL;
        wrapper.ownerWindow = nil;
        wrapper.metalView.zenitDragSessionActive = NO;
        wrapper.metalView.zenitDragToken = 0;
        wrapper.metalView.zenitDragAllowedOperations = NSDragOperationNone;
        [wrapper.metalView unregisterDraggedTypes];
        [wrapper.metalView.filePromiseQueue cancelAllOperations];
        if (!wrapper.nativeCloseStarted && wrapper.window.isKeyWindow) {
            macos_set_text_input_enabled(window_ptr, 0);
            [wrapper.window makeFirstResponder:nil];
        }
        [wrapper.metalView.zenitA11yElementCache removeAllObjects];
        [wrapper.keyEventQueue removeAllObjects];
        [wrapper.mouseMoveQueue removeAllObjects];
        [wrapper.inputTextQueue removeAllObjects];
        [wrapper.imePreeditQueue removeAllObjects];
        [wrapper.imeCommitQueue removeAllObjects];
        [wrapper.mouseButtonQueue removeAllObjects];
        [wrapper.scrollEventQueue removeAllObjects];
        [wrapper.magnifyEventQueue removeAllObjects];
        [wrapper.metalView.dragEventQueue removeAllObjects];
        [wrapper.window setDelegate:nil];
        macos_menu_discard_window_commands((uint64_t)(NSInteger)wrapper.window.windowNumber);
        unregisterWindowWrapper(wrapper.window);
        // Normal user closes have already completed AppKit's native close
        // transaction. orderOut is retained only as the non-animated hard-stop
        // path for initialization failures and application shutdown.
        if (!wrapper.nativeCloseCompleted) {
            [wrapper.window orderOut:nil];
        }
        wrapper.window = nil;
        wrapper.metalView = nil;
        NSLog(@"[macos_destroy_window] Window destroyed");
    }
}

// ========== multi-window architecture API ==========

// pure event pump: fetch all NSApp events, dispatch to
// WindowWrappers. not bound any window, each independently calls
// macos_update_window_mouse
static void pumpAppEventsWithTimeout(uint32_t timeout_ms) {
    @autoreleasepool {
        // previous frame AX service window deferred actions: frame ended,
        // execute before this round input events.
        zenitDrainDeferredA11yMutations();
        g_text_input_wake_posted = NO;
        atomic_store(&g_display_link_wake_pending, false);
        // First-responder assignment is the supported input-context activation
        // boundary. Never force activate/deactivate from the event pump.
        static BOOL didForceActivate = NO;
        if (!didForceActivate) {
            didForceActivate = YES;
            zenitActivateApplication();
            // find first registered window establish responder chain.
            if (g_window_list.count > 0) {
                NSWindow *firstWin = g_window_list[0];
                WindowWrapper *wrapper = wrapperForWindow(firstWin);
                if (wrapper && wrapper.metalView && wrapper.window.firstResponder != wrapper.metalView) {
                    [wrapper.window makeFirstResponder:wrapper.metalView];
                }
            }
        }

        // Deliver each semantic event to Zig before interpreting the next one.
        // Sorting the resulting packets cannot fix a key interpreted while a
        // preceding click/Tab/commit still has not updated logical focus or
        // the live TextInputClient selection. Keep hover batching bounded.
        // Text callbacks can also arrive outside this pump (e.g. discard or
        // a candidate click); drain them before waiting for another NSEvent.
        for (NSWindow *window in g_window_list) {
            WindowWrapper *wrapper = wrapperForWindow(window);
            if (wrapper.inputTextQueue.count || wrapper.imePreeditQueue.count ||
                wrapper.imeCommitQueue.count) return;
        }
        if (zenitHasPendingMenuCommands()) return;
        BOOL shouldBlockForFirstEvent = timeout_ms != 0;
        for (NSUInteger batch = 0; batch < 256; batch++) {
            // check any window in live resize
            NSString *mode = NSDefaultRunLoopMode;
            for (NSWindow *w in g_window_list) {
                if (w.inLiveResize) {
                    mode = NSEventTrackingRunLoopMode;
                    break;
                }
            }
            NSDate *untilDate = [NSDate distantPast];
            if (shouldBlockForFirstEvent) {
                untilDate = (timeout_ms == UINT32_MAX)
                    ? [NSDate distantFuture]
                    : [NSDate dateWithTimeIntervalSinceNow:((double)timeout_ms) / 1000.0];
            }
            const unsigned long long sequenceBeforeWait = g_input_event_sequence;
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:untilDate
                                                   inMode:mode
                                                  dequeue:YES];
            // nextEvent runs the run loop and may deliver an asynchronous
            // text callback before returning a keyboard event. Let Zig apply
            // that callback first; leave the event in its original order.
            if (g_input_event_sequence != sequenceBeforeWait || zenitHasPendingMenuCommands()) {
                if (event) [NSApp postEvent:event atStart:YES];
                break;
            }
            if (!event) break;
            shouldBlockForFirstEvent = NO;
            if (event.type == NSEventTypeApplicationDefined) {
                atomic_store(&g_display_link_wake_pending, false);
            }

            // find fallback wrapper (key window or first)
            WindowWrapper *fallback = nil;
            NSWindow *keyWin = [NSApp keyWindow];
            if (keyWin) fallback = wrapperForWindow(keyWin);
            if (!fallback && g_window_list.count > 0) {
                fallback = wrapperForWindow(g_window_list[0]);
            }
            WindowWrapper *target = targetWrapperForEvent(event, fallback);
            if (!target) {
                [NSApp sendEvent:event];
                [NSApp updateWindows];
                break;
            }

            // Drop physical keys before native menu, close and IME side effects.
            // The harness injects directly into Cx and never uses this path.
            if (target.keyboardIsolated && (event.type == NSEventTypeKeyDown ||
                event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged)) continue;

            // keyboard event handling. FlagsChanged separate branch: no
            // characters, skip menu keyEquivalent/firstResponder keyDown logic.
            if (event.type == NSEventTypeFlagsChanged) {
                enqueueKeyEvent(target, event);
                BOOL imeHandled = NO;
                if (zenitTextInputIsActive(target)) {
                    NSTextInputContext *ic = [target.metalView inputContext];
                    imeHandled = [ic handleEvent:event];
                    if (input_debug_enabled()) {
                        NSLog(@"[ime-debug] flagsChanged inputSource=%@ keyCode=%d handled=%d",
                              ic.selectedKeyboardInputSource,
                              event.keyCode,
                              imeHandled);
                    }
                }
                // AppKit still owns modifier-state propagation when the active
                // input context did not consume the transition. Sending both
                // unconditionally can toggle an IME's per-application mode
                // twice (Caps Lock is the observable failure).
                if (!imeHandled) [NSApp sendEvent:event];
                [NSApp updateWindows];
                break;
            }
            if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
                BOOL isCmd = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
                NSString *key = event.charactersIgnoringModifiers;

                // Cmd+Q: global exit
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    [key isEqualToString:@"q"]) {
                    g_app_should_quit = YES;
                }

                // Shift+Cmd+W: close target window. Bare Cmd+W unintercepted, go to
                // Zig (close current tab).
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    (event.modifierFlags & NSEventModifierFlagShift) != 0 &&
                    [key.lowercaseString isEqualToString:@"w"]) {
                    target.shouldClose = YES;
                    [NSApp updateWindows];
                    break;
                }

                // Cmd+`: window switch
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    event.keyCode == 50) {
                    NSWindow *kw = [NSApp keyWindow];
                    for (NSWindow *w in g_window_list) {
                        if (w != kw && w.isVisible) {
                            zenitPresentWindow(w);
                            break;
                        }
                    }
                    [NSApp updateWindows];
                    break;
                }

                // menu shortcuts: this loop never calls sendEvent, keyEquivalent
                // dispatch in sendEvent - skip it, custom menu (Cmd+P) never fire
                // (verify_menu.sh caught; macos_poll_events old loop same).
                const bool has_cmd_or_ctrl = (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
                if (event.type == NSEventTypeKeyDown && has_cmd_or_ctrl) {
                    BOOL menu_ate = [NSApp.mainMenu performKeyEquivalent:event];
                    if (getenv("ZENIT_DEBUG_MENU")) {
                        NSLog(@"[menu-debug] pump keyEquivalent keyCode=%d ate=%d", event.keyCode, menu_ate);
                    }
                    if (menu_ate) {
                        [NSApp updateWindows];
                        break;
                    }
                }

                // record key event to target window (queue, avoid high-input
                // clobber)
                enqueueKeyEvent(target, event);

                // IME handling
                if (event.type == NSEventTypeKeyDown) {
                    NSResponder *fr = [target.window firstResponder];
                    if (fr != target.metalView) {
                        [target.window makeFirstResponder:target.metalView];
                    }
                    if (zenitTextInputIsActive(target)) {
                        NSTextInputContext *ic = synchronizeTextInputSource(target, @"keyDown");
                        target.keyDispatchSeq += 1;
                        if (input_debug_enabled()) {
                            NSLog(@"[ime-debug] pump dispatch inputSource=%@ currentContext=%d active=%d",
                                  ic.selectedKeyboardInputSource,
                                  [NSTextInputContext currentInputContext] == ic,
                                  [NSApp isActive]);
                        }
                        [ic handleEvent:event];
                    }
                }
                [NSApp updateWindows];
                break;
            }

            // mouse/scroll event handling (route to target)
            switch (event.type) {
                case NSEventTypeLeftMouseDown: {
                    if (target.chromeHitCallback) {
                        NSPoint p=[target.window.contentView convertPoint:event.locationInWindow fromView:nil];
                        float y=(float)(target.window.contentView.bounds.size.height-p.y);
                        if (!chromePointInNativeButton(target,p) && target.chromeHitCallback(target.chromeHitContext,(float)p.x,y)==2 && !(target.window.styleMask & NSWindowStyleMaskFullScreen)) {
                            [target.window performWindowDragWithEvent:event];
                            break;
                        }
                    }
                    if (!target.chromeHitCallback && target.titlebarDragHeight > 0) {
                        NSRect contentFrame = [target.window.contentView frame];
                        NSPoint loc = [event locationInWindow];
                        float y_from_top = (float)(contentFrame.size.height - loc.y);
                        if (y_from_top < target.titlebarDragHeight && y_from_top >= 0) {
                            float x = (float)loc.x;
                            float w = (float)contentFrame.size.width;
                            float resize_inset = 5.0f;
                            float right_inset = target.titlebarDragRightInset > 0 ? target.titlebarDragRightInset : resize_inset;
                            if (x > 78 && x < (w - right_inset)) {
                                int on_control = 0;
                                if (target.titlebarHitCallback) {
                                    on_control = target.titlebarHitCallback(target.titlebarHitContext, x, y_from_top);
                                }
                                if (!on_control) {
                                    [target.window performWindowDragWithEvent:event];
                                    break;
                                }
                            }
                        }
                    }
                    if (getenv("ZENIT_DEBUG_MOUSEEV")) {
                        fprintf(stderr, "[mouseev] DOWN ts=%.3f click=%ld pressure=%.2f win=%ld subtype=%ld\n",
                                event.timestamp, (long)event.clickCount, event.pressure,
                                (long)(event.window ? event.window.windowNumber : -1), (long)event.subtype);
                    }
                    target.leftButtonPressed = YES;
                    enqueueMouseButton(target, 0, YES, event);
                    break;
                }
                case NSEventTypeLeftMouseUp:
                    if (getenv("ZENIT_DEBUG_MOUSEEV")) {
                        fprintf(stderr, "[mouseev] UP ts=%.3f click=%ld pressure=%.2f win=%ld subtype=%ld\n",
                                event.timestamp, (long)event.clickCount, event.pressure,
                                (long)(event.window ? event.window.windowNumber : -1), (long)event.subtype);
                    }
                    target.leftButtonPressed = NO;
                    enqueueMouseButton(target, 0, NO, event);
                    break;
                case NSEventTypeRightMouseDown:
                    target.rightButtonPressed = YES;
                    enqueueMouseButton(target, 1, YES, event);
                    break;
                case NSEventTypeRightMouseUp:
                    target.rightButtonPressed = NO;
                    enqueueMouseButton(target, 1, NO, event);
                    break;
                case NSEventTypeOtherMouseDown:
                    if (event.buttonNumber == 2) {
                        target.middleButtonPressed = YES;
                        enqueueMouseButton(target, 2, YES, event);
                    }
                    break;
                case NSEventTypeOtherMouseUp:
                    if (event.buttonNumber == 2) {
                        target.middleButtonPressed = NO;
                        enqueueMouseButton(target, 2, NO, event);
                    }
                    break;
                case NSEventTypeMouseMoved:
                case NSEventTypeLeftMouseDragged:
                case NSEventTypeRightMouseDragged:
                case NSEventTypeOtherMouseDragged:
                    enqueueMouseMove(target, event);
                    break;
                case NSEventTypeScrollWheel:
                    {
                        NSPoint scrollInWindow = zenitLogicalEventPoint(target,event);
                        NSRect contentFrame = [target.window.contentView frame];
                        ScrollEventPacket packet;
                        packet.sequence = nextInputEventSequence();
                        packet.x = (float)scrollInWindow.x;
                        packet.y = (float)scrollInWindow.y;
                        zenitScrollDeltas(event, &packet.dx, &packet.dy);
                        packet.phase = zenitScrollPhaseCode(event);
                        packet.momentum = zenitMomentumPhaseCode(event);
                        packet.modifiers = (uint32_t)event.modifierFlags;
                        if (!target.scrollEventQueue) {
                            target.scrollEventQueue = [NSMutableArray array];
                        }
                        [target.scrollEventQueue addObject:[NSValue valueWithBytes:&packet objCType:@encode(ScrollEventPacket)]];
                    }
                    break;
                case NSEventTypeMagnify:
                    {
                        NSPoint magInWindow = zenitLogicalEventPoint(target,event);
                        NSRect magContentFrame = [target.window.contentView frame];
                        MagnifyEventPacket mpacket;
                        mpacket.sequence = nextInputEventSequence();
                        mpacket.x = (float)magInWindow.x;
                        mpacket.y = (float)magInWindow.y;
                        mpacket.magnification = (float)event.magnification;
                        if (event.phase == NSEventPhaseBegan) mpacket.phase = 0;
                        else if (event.phase == NSEventPhaseEnded) mpacket.phase = 2;
                        else if (event.phase == NSEventPhaseCancelled) mpacket.phase = 3;
                        else mpacket.phase = 1;
                        if (!target.magnifyEventQueue) {
                            target.magnifyEventQueue = [NSMutableArray array];
                        }
                        [target.magnifyEventQueue addObject:[NSValue valueWithBytes:&mpacket objCType:@encode(MagnifyEventPacket)]];
                    }
                    break;
                default:
                    break;
            }

            [NSApp sendEvent:event];
            [NSApp updateWindows];
            if (event.type == NSEventTypeMouseMoved || event.type == NSEventTypeLeftMouseDragged || event.type == NSEventTypeRightMouseDragged || event.type == NSEventTypeOtherMouseDragged) {
                [target.metalView presentDesiredCursor];
            }
            if (event.type != NSEventTypeMouseMoved) break;
        }

        // same as macos_poll_events: fill updateWindows, else
        // NSTextInputContext activation/per-context IM doesn't work.
        [NSApp updateWindows];

        // Non-blocking pump (timeout 0: wants frame / test_mode).
        // nextEventMatchingMask with distantPast only fetches; the run loop never runs, so
        // non-main-queue sources and observers (AVFoundation AVPlayerItem prep, NSURLSession,
        // notifications...) starve, and continuous rendering leaves video loading forever.
        // Fill in one zero-wait run loop pass here: no sleep/wait, only ready sources/observers;
        // after the event batch, keep event-then-callback order. The mode matches the batch
        // nextEvent:
        // during live resize it is NSEventTrackingRunLoopMode (a fixed default mode would starve
        // tracking-only sources during resize).
        if (timeout_ms == 0) {
            NSString *passMode = NSDefaultRunLoopMode;
            for (NSWindow *w in g_window_list) {
                if (w.inLiveResize) {
                    passMode = NSEventTrackingRunLoopMode;
                    break;
                }
            }
            [[NSRunLoop currentRunLoop] runMode:passMode beforeDate:[NSDate distantPast]];
        }
    }
}

void macos_pump_app_events(void) {
    pumpAppEventsWithTimeout(0);
}

void macos_pump_app_events_timeout(unsigned int timeout_ms) {
    pumpAppEventsWithTimeout(timeout_ms);
}

// check global exit flag
int macos_should_quit(void) {
    return g_app_should_quit ? 1 : 0;
}

// The application vetoed the quit request (e.g. unsaved work); keep running.
void macos_cancel_app_quit(void) {
    g_app_should_quit = NO;
}

// consume 'app became foreground' flag: return 1 and reset to NO
// (won't return 1 again until next activation)
int macos_consume_app_became_active(void) {
    if (g_app_became_active) {
        g_app_became_active = NO;
        return 1;
    }
    return 0;
}

// query current system is dark mode. each pump called by
// collectGlobalEvents, may also called outside main pool,
// effectiveAppearance returns autoreleased NSCompositeAppearance - has
// own pool.
int macos_is_dark_mode(void) {
    @autoreleasepool {
        NSAppearanceName appearance = [[NSApp effectiveAppearance] bestMatchFromAppearancesWithNames:@[
            NSAppearanceNameAqua,
            NSAppearanceNameDarkAqua
        ]];
        return [appearance isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
    }
}

// check window requested close (don't consume)
int macos_check_window_should_close(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return wrapper.shouldClose ? 1 : 0;
    }
}

// reset window close request flag
void macos_reset_window_should_close(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.shouldClose = NO;
    }
}

// per-window mouse position update (extracted from
// macos_poll_events end)
void macos_update_window_mouse(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return;

        BOOL canAccept = windowCanAcceptPointerInput(wrapper);
        BOOL inactiveHover = !canAccept && wrapper.acceptsMouseMovedWhileInactive
                             && wrapper.window && [NSApp isActive];
        BOOL isDragging = wrapper.leftButtonPressed || wrapper.rightButtonPressed || wrapper.middleButtonPressed;

        if (canAccept || inactiveHover) {
            if (!isDragging) {
                NSPoint mouseInWindow = [wrapper.window mouseLocationOutsideOfEventStream];
                NSRect contentFrame = [wrapper.window.contentView frame];
                wrapper.mouseLocation = NSMakePoint(mouseInWindow.x,
                                                    contentFrame.size.height - mouseInWindow.y);
                if(wrapper.fullscreenHeader.active) wrapper.mouseLocation=zenitLogicalScreenPoint(wrapper,NSEvent.mouseLocation);
            }
            if (inactiveHover) {
                wrapper.leftButtonPressed = NO;
                wrapper.rightButtonPressed = NO;
                wrapper.middleButtonPressed = NO;
            }
        } else {
            if (!isDragging) {
                wrapper.mouseLocation = NSMakePoint(-1, -1);
                wrapper.leftButtonPressed = NO;
                wrapper.rightButtonPressed = NO;
                wrapper.middleButtonPressed = NO;
            }
        }
    }
}

// current hardware modifier state (process-level, not event
// snapshot). poll-style mouse_move no NSEvent for flags, use to
// augment modifier.
uint32_t macos_current_modifier_flags(void) {
    return (uint32_t)[NSEvent modifierFlags];
}

int macos_is_window_focused(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return 0;
        if (zenitBackgroundE2E()) return wrapper.window.windowNumber == g_requested_key_window;
        if (wrapper.window.isKeyWindow) return 1;
        // app not foreground no key window: use 'last requested key' as
        // focus, multi-window e2e/shortcut routing don't degrade to first
        // when user switches app.
        if (![NSApp isActive]) {
            NSWindow *req = macos_find_window_by_number(g_requested_key_window);
            if (req) return req == wrapper.window ? 1 : 0;
            return wrapper.window.isMainWindow ? 1 : 0;
        }
        return 0;
    }
}

// system appearance sense active: app foreground and window key
// (non-active window Liquid Glass tint desaturated). Background e2e
// app not foreground: default active not change all baselines; set
// ZENIT_E2E_REAL_ACTIVATION use actual (for non-active appearance).
int macos_window_appears_active(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return 1;
        if (zenitBackgroundE2E() && getenv("ZENIT_E2E_REAL_ACTIVATION") == NULL) return 1;
        return ([NSApp isActive] && wrapper.window.isKeyWindow) ? 1 : 0;
    }
}

// init Cocoa app (no menubar, dev compat)
void macos_init_app(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:zenitActivationPolicy()];
        [NSApp finishLaunching];
        zenitActivateApplication();
        NSLog(@"[macos_init_app] Cocoa application initialized");
    }
}

// ========== ZenitAppDelegate + menubar ==========

@interface ZenitAppDelegate : NSObject <NSApplicationDelegate>
@end

static ZenitAppDelegate *g_app_delegate = nil;

// global pending open file path (Finder double-click / open -a /
// drag to Dock)
static NSMutableArray<NSString *> *g_pending_open_files = nil;

// forward declare: defined below menu API (static redeclaration legal
// tentative)
static NSMutableDictionary<NSNumber *, NSMenu *> *zenitMenuById;

@implementation ZenitAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // setMenuModel may be called before finishLaunching (zenitMenuById
    // non-empty means so). Before unconditional setupMenuBar silently
    // overwrites custom main menu - set before launch vanishes no error
    // (verify_menu.sh caught).
    if (!zenitMenuById) {
        [self setupMenuBar];
    }
    NSLog(@"[ZenitAppDelegate] Application finished launching with menu bar");
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"[ZenitAppDelegate] Application will terminate");
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    // AppKit's standard Quit menu normally terminates immediately. Convert it
    // into the same application-wide event as Cmd-Q so Zig can unwind every
    // window, GPU resource, callback, and SDK registration in order.
    g_app_should_quit = YES;
    macos_post_empty_event();
    return NSTerminateCancel;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // App switched from background to foreground: mark for redraw; the Zig side
    // consumes it on the next frame pump.
    g_app_became_active = YES;
    NSLog(@"[ZenitAppDelegate] applicationDidBecomeActive");
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    // Zig owns process lifetime and tears down GPU/UI resources only after each
    // NSWindow has completed its AppKit close transaction.
    return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)sender {
    (void)sender;
    // Declare support for secure restorable-state coding (macOS 12+ API).
    // Automatic for apps linked on the macOS 14 SDK; explicit declaration
    // keeps older link configurations on the supported path.
    return YES;
}

// Finder double-click / open with / open -a / drag to Dock
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (filename.length == 0) return NO;
    NSLog(@"[ZenitAppDelegate] openFile: %@", filename);
    // AppKit normally invokes the delegate on the main thread, but the C ABI
    // polling function is public and may be called elsewhere. Synchronize the
    // hand-off so a future/background poll cannot race ARC assignment.
    @synchronized ([ZenitAppDelegate class]) {
        if (!g_pending_open_files) g_pending_open_files = [NSMutableArray array];
        [g_pending_open_files addObject:[filename copy]];
    }
    return YES;
}

// Preserve every file in one LaunchServices delivery, in delivery order.
- (void)application:(NSApplication *)sender openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        if (url.isFileURL) [self application:sender openFile:url.path];
    }
}

- (void)setupMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // === Zenit menu (app menu) ===
    {
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Zenit"];

        [appMenu addItemWithTitle:@"About Zenit"
                           action:@selector(orderFrontStandardAboutPanel:)
                    keyEquivalent:@""];

        [appMenu addItem:[NSMenuItem separatorItem]];

        // Install command line launcher. After About, before Hide - match
        // VSCode/Zed position, user habit finding one-time setup in app menu.
        [appMenu addItemWithTitle:@"Install Command Line Tool"
                           action:@selector(zenitInstallCli:)
                    keyEquivalent:@""];

        [appMenu addItem:[NSMenuItem separatorItem]];

        [appMenu addItemWithTitle:@"Hide Zenit"
                           action:@selector(hide:)
                    keyEquivalent:@"h"];

        NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                    action:@selector(hideOtherApplications:)
                                             keyEquivalent:@"h"];
        hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;

        [appMenu addItemWithTitle:@"Show All"
                           action:@selector(unhideAllApplications:)
                    keyEquivalent:@""];

        [appMenu addItem:[NSMenuItem separatorItem]];

        [appMenu addItemWithTitle:@"Quit Zenit"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];

        appMenuItem.submenu = appMenu;
        [mainMenu addItem:appMenuItem];
    }

    // === File menu ===
    {
        NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

        // New Text File (Cmd+N)
        [fileMenu addItemWithTitle:@"New Text File"
                            action:@selector(zenitNewFile:)
                     keyEquivalent:@"n"];

        // New File... (Ctrl+Alt+Cmd+N)
        NSMenuItem *newFileDialog = [fileMenu addItemWithTitle:@"New File…"
                                                        action:@selector(zenitNewFileDialog:)
                                                 keyEquivalent:@"n"];
        newFileDialog.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;

        // New Window (Shift+Cmd+N)
        NSMenuItem *newWindow = [fileMenu addItemWithTitle:@"New Window"
                                                     action:@selector(zenitNewWindow:)
                                              keyEquivalent:@"n"];
        newWindow.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;

        [fileMenu addItem:[NSMenuItem separatorItem]];

        // Open... (Cmd+O)
        [fileMenu addItemWithTitle:@"Open…"
                            action:@selector(zenitOpenFile:)
                     keyEquivalent:@"o"];

        // Open Folder...
        [fileMenu addItemWithTitle:@"Open Folder…"
                            action:@selector(zenitOpenFolder:)
                     keyEquivalent:@""];

        // Open Recent -> (submenu placeholder)
        NSMenuItem *openRecentItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent"
                                                                action:nil
                                                         keyEquivalent:@""];
        NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
        // TODO: dynamically populate recent files
        [recentMenu addItemWithTitle:@"(empty)"
                              action:nil
                       keyEquivalent:@""];
        openRecentItem.submenu = recentMenu;
        [fileMenu addItem:openRecentItem];

        [fileMenu addItem:[NSMenuItem separatorItem]];

        // Save (Cmd+S)
        [fileMenu addItemWithTitle:@"Save"
                            action:@selector(zenitSave:)
                     keyEquivalent:@"s"];

        // Save As... (Shift+Cmd+S)
        NSMenuItem *saveAs = [fileMenu addItemWithTitle:@"Save As…"
                                                  action:@selector(zenitSaveAs:)
                                           keyEquivalent:@"s"];
        saveAs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;

        [fileMenu addItem:[NSMenuItem separatorItem]];

        // Close Tab (Cmd+W)
        [fileMenu addItemWithTitle:@"Close Tab"
                            action:@selector(zenitCloseTab:)
                     keyEquivalent:@"w"];

        // Close Window (Shift+Cmd+W)
        NSMenuItem *closeWin = [fileMenu addItemWithTitle:@"Close Window"
                                                    action:@selector(zenitCloseWindow:)
                                             keyEquivalent:@"w"];
        closeWin.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;

        fileMenuItem.submenu = fileMenu;
        [mainMenu addItem:fileMenuItem];
    }

    // === Edit menu ===
    {
        NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

        [editMenu addItemWithTitle:@"Undo"
                            action:@selector(zenitUndo:)
                     keyEquivalent:@"z"];

        NSMenuItem *redoItem = [editMenu addItemWithTitle:@"Redo"
                                                   action:@selector(zenitRedo:)
                                            keyEquivalent:@"z"];
        redoItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;

        [editMenu addItem:[NSMenuItem separatorItem]];

        [editMenu addItemWithTitle:@"Cut"
                            action:@selector(zenitCut:)
                     keyEquivalent:@"x"];

        [editMenu addItemWithTitle:@"Copy"
                            action:@selector(zenitCopy:)
                     keyEquivalent:@"c"];

        [editMenu addItemWithTitle:@"Paste"
                            action:@selector(zenitPaste:)
                     keyEquivalent:@"v"];

        [editMenu addItemWithTitle:@"Select All"
                            action:@selector(zenitSelectAll:)
                     keyEquivalent:@"a"];

        editMenuItem.submenu = editMenu;
        [mainMenu addItem:editMenuItem];
    }

    // === Window menu ===
    {
        NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
        NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

        [windowMenu addItemWithTitle:@"Minimize"
                              action:@selector(performMiniaturize:)
                       keyEquivalent:@"m"];

        [windowMenu addItemWithTitle:@"Zoom"
                              action:@selector(performZoom:)
                       keyEquivalent:@""];

        [windowMenu addItem:[NSMenuItem separatorItem]];

        [windowMenu addItemWithTitle:@"Bring All to Front"
                              action:@selector(arrangeInFront:)
                       keyEquivalent:@""];

        windowMenuItem.submenu = windowMenu;
        [mainMenu addItem:windowMenuItem];

        [NSApp setWindowsMenu:windowMenu];
    }

    // === Help menu ===
    {
        NSMenuItem *helpMenuItem = [[NSMenuItem alloc] init];
        NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

        helpMenuItem.submenu = helpMenu;
        [mainMenu addItem:helpMenuItem];

        [NSApp setHelpMenu:helpMenu];
    }

    [NSApp setMainMenu:mainMenu];
}

@end

// MetalView menu action method - forward Edit menu to key events
@implementation MetalView (MenuActions)

- (void)_simulateKeyEventWithCode:(uint16_t)keyCode character:(char)ch modifiers:(uint32_t)mods {
    WindowWrapper *wrapper = wrapperForWindow(self.window);
    if (!wrapper) return;
    if (!wrapper.keyEventQueue) {
        wrapper.keyEventQueue = [NSMutableArray array];
    }
    KeyEventPacket packet;
    packet.sequence = nextInputEventSequence();
    packet.keycode = keyCode;
    packet.modifiers = mods;
    packet.character = ch;
    packet.pressed = YES;
    [wrapper.keyEventQueue addObject:[NSValue valueWithBytes:&packet objCType:@encode(KeyEventPacket)]];
}

// Cmd+Z → Undo (keycode 6 = 'z')
- (void)zenitUndo:(id)sender {
    [self _simulateKeyEventWithCode:6 character:'z' modifiers:NSEventModifierFlagCommand];
}

// Cmd+Shift+Z → Redo
- (void)zenitRedo:(id)sender {
    [self _simulateKeyEventWithCode:6 character:'z' modifiers:(NSEventModifierFlagCommand | NSEventModifierFlagShift)];
}

// Cmd+X → Cut (keycode 7 = 'x')
- (void)zenitCut:(id)sender {
    [self _simulateKeyEventWithCode:7 character:'x' modifiers:NSEventModifierFlagCommand];
}

// Cmd+C → Copy (keycode 8 = 'c')
- (void)zenitCopy:(id)sender {
    [self _simulateKeyEventWithCode:8 character:'c' modifiers:NSEventModifierFlagCommand];
}

// Cmd+V → Paste (keycode 9 = 'v')
- (void)zenitPaste:(id)sender {
    [self _simulateKeyEventWithCode:9 character:'v' modifiers:NSEventModifierFlagCommand];
}

// Cmd+A → Select All (keycode 0 = 'a')
- (void)zenitSelectAll:(id)sender {
    [self _simulateKeyEventWithCode:0 character:'a' modifiers:NSEventModifierFlagCommand];
}

// ===== File menu actions =====

// Cmd+N → New Text File (keycode 45 = 'n')
- (void)zenitNewFile:(id)sender {
    [self _simulateKeyEventWithCode:45 character:'n' modifiers:NSEventModifierFlagCommand];
}

// Ctrl+Alt+Cmd+N → New File...
- (void)zenitNewFileDialog:(id)sender {
    pushMenuAction(MenuActionNewFileDialog);
}

// Shift+Cmd+N → New Window
- (void)zenitNewWindow:(id)sender {
    pushMenuAction(MenuActionNewWindow);
}

// Cmd+O → Open...
- (void)zenitOpenFile:(id)sender {
    NSLog(@"[Menu] zenitOpenFile: triggered");
    pushMenuAction(MenuActionOpenFile);
}

// Open Folder...
- (void)zenitOpenFolder:(id)sender {
    pushMenuAction(MenuActionOpenFolder);
}

// Install Command Line Tool. Not bound to a window: CLI install is process-level and one-time,
// and must work even with no key window (Welcome only, or all minimized). Use
// pushMenuActionForWindow(..., 0), not pushMenuAction(): the latter fills window_id 0 and Zig
// returns early on target not found.
- (void)zenitInstallCli:(id)sender {
    pushMenuActionForWindow(MenuActionInstallCli, 0);
}

// Cmd+S → Save (keycode 1 = 's')
- (void)zenitSave:(id)sender {
    [self _simulateKeyEventWithCode:1 character:'s' modifiers:NSEventModifierFlagCommand];
}

// Shift+Cmd+S → Save As...
- (void)zenitSaveAs:(id)sender {
    pushMenuAction(MenuActionSaveAs);
}

// Cmd+W → Close Tab (keycode 13 = 'w')
- (void)zenitCloseTab:(id)sender {
    [self _simulateKeyEventWithCode:13 character:'w' modifiers:NSEventModifierFlagCommand];
}

// Shift+Cmd+W → Close Window
- (void)zenitCloseWindow:(id)sender {
    pushMenuAction(MenuActionCloseWindow);
}

@end

// get next pending menu action (0 = none)
int macos_get_menu_action(void) {
    @autoreleasepool {
        return (int)popMenuAction();
    }
}

// init Cocoa app + AppDelegate + menubar
void macos_init_app_with_delegate(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:zenitActivationPolicy()];

        // create and set delegate
        g_app_delegate = [[ZenitAppDelegate alloc] init];
        [NSApp setDelegate:g_app_delegate];

        // immediately setup menubar (don't wait
        // applicationDidFinishLaunching, we don't use [NSApp run])
        [g_app_delegate setupMenuBar];

        [NSApp finishLaunching];
        zenitActivateApplication();
        NSLog(@"[macos_init_app_with_delegate] Cocoa application initialized with delegate + menu bar");
    }
}

void macos_show_blocking_alert(const char *title, const char *message) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:zenitActivationPolicy()];
        zenitActivateApplication();

        NSString *appName = [[NSProcessInfo processInfo] processName] ?: @"";
        NSString *titleString = title ? [NSString stringWithUTF8String:title] : appName;
        NSString *messageString = message ? [NSString stringWithUTF8String:message] : @"";

        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = titleString ?: appName;
        alert.informativeText = messageString ?: @"";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ========== Clipboard API ==========

// Return: 1 = success, 0 = setString rejected, -1 = invalid UTF-8.
//
// Construct the new content first, then clear: if construction fails (invalid UTF-8) the
// original clipboard stays unchanged. Clearing first would destroy the old content
// unrecoverably, and a dropped setString BOOL would report success while changeCount rose
// but content stayed stale (silent copy failure).
int macos_clipboard_set_text(const char* text, int len) {
    @autoreleasepool {
        // construct then clear: construction fails, user's clipboard
        // unchanged, no corruption.
        NSString *str = [[NSString alloc] initWithBytes:text
                                                 length:(NSUInteger)len
                                               encoding:NSUTF8StringEncoding];
        if (!str) return -1;
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        return [pb setString:str forType:NSPasteboardTypeString] ? 1 : 0;
    }
}



// 0 = empty, -1 = conversion/backend failure, -2 = insufficient capacity.
// Reads never return a truncated prefix. NSString byte lengths include NULs.
static int zenit_clipboard_string_len(NSString *str) {
    if (!str || str.length == 0) return 0;
    if (![str UTF8String]) return -1;
    const NSUInteger len = [str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return len < INT_MAX ? (int)len : -2; // reserve one byte for the terminator
}

static int zenit_clipboard_copy_string(NSString *str, char *buffer, int buffer_size) {
    const int len = zenit_clipboard_string_len(str);
    if (len <= 0) return len;
    if (!buffer || buffer_size <= len) return -2;
    const char *utf8 = [str UTF8String];
    if (!utf8) return -1;
    memcpy(buffer, utf8, (size_t)len);
    buffer[len] = 0;
    return len;
}

int macos_clipboard_get_text(char* buffer, int buffer_size) {
    @autoreleasepool {
        NSString *str = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        return zenit_clipboard_copy_string(str, buffer, buffer_size);
    }
}

int macos_clipboard_get_text_len(void) {
    @autoreleasepool {
        NSString *str = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        return zenit_clipboard_string_len(str);
    }
}

// Rich clipboard write: plain text + optional HTML as multiple representations
// of a single pasteboard item, so paste targets pick their best type.
// RTF is intentionally not written: HTML→RTF needs NSAttributedString
// initWithHTML (WebKit-backed, spins a nested runloop on the main thread),
// which is too heavy/fragile for a synchronous clipboard call. TODO(rtf):
// revisit with a pure CoreText converter if a consumer needs RTF.
//
// Same result contract as macos_clipboard_set_text: 1 = written, 0 = the
// pasteboard refused the write, -1 = text or HTML is not valid UTF-8. Both
// payloads are validated *before* clearContents so a rejected call leaves the
// user's existing clipboard intact instead of wiping it and reporting success.
int macos_clipboard_set_rich_text(const char* text, int text_len, const char* html, int html_len) {
    @autoreleasepool {
        if (text_len < 0 || (!text && text_len > 0) || html_len < 0) return -1;
        NSString *str = [[NSString alloc] initWithBytes:text length:(NSUInteger)text_len encoding:NSUTF8StringEncoding];
        if (!str) return -1;
        NSString *htmlStr = nil;
        if (html && html_len > 0) {
            htmlStr = [[NSString alloc] initWithBytes:html length:(NSUInteger)html_len encoding:NSUTF8StringEncoding];
            if (!htmlStr) return -1;
        }
        NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
        if (![item setString:str forType:NSPasteboardTypeString]) return 0;
        if (htmlStr && ![item setString:htmlStr forType:NSPasteboardTypeHTML]) return 0;
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        return [pb writeObjects:@[ item ]] ? 1 : 0;
    }
}

// Same empty/error/full-read contract as the plain-text representation.
int macos_clipboard_get_html_len(void) {
    @autoreleasepool {
        NSString *str = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeHTML];
        return zenit_clipboard_string_len(str);
    }
}

int macos_clipboard_get_html(char* buffer, int buffer_size) {
    @autoreleasepool {
        NSString *str = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeHTML];
        return zenit_clipboard_copy_string(str, buffer, buffer_size);
    }
}

// ========== Application menu / command bridge ==========

static NSMutableDictionary<NSNumber *, NSMenu *> *zenitMenuById;
// Each command captures the key-window identity at invocation time. Looking up
// NSApp.keyWindow later in the Zig pump is racy: the user can focus or close a
// different window before the queue is drained.
static NSMutableArray<NSDictionary *> *zenitPendingMenuCommands;

@interface ZenitMenuCommandTarget : NSObject
- (void)invokeZenitMenuCommand:(id)sender;
@end

@implementation ZenitMenuCommandTarget
- (void)invokeZenitMenuCommand:(id)sender {
    NSNumber *command = [sender representedObject];
    if (!command) return;
    if (!zenitPendingMenuCommands) zenitPendingMenuCommands = [NSMutableArray array];
    // Commands are actions, not coalescible snapshots. The native pump yields
    // when any command is pending; never evict an earlier user action.
    const BOOL needsWake = zenitPendingMenuCommands.count == 0;
    NSWindow *keyWindow = NSApp.keyWindow;
    WindowWrapper *logicalOwner=wrapperForWindow(keyWindow);
    uint64_t windowId = logicalOwner ? (uint64_t)logicalOwner.window.windowNumber : (keyWindow ? (uint64_t)keyWindow.windowNumber : 0);
    [zenitPendingMenuCommands addObject:@{
        @"windowId": @(windowId),
        @"commandId": command,
    }];
    if (needsWake) macos_post_empty_event();
}
@end

static ZenitMenuCommandTarget *zenitMenuTarget;

static NSString *zenitString(const char *bytes, size_t len) {
    if (!bytes || len == 0) return @"";
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @"";
}

static SEL zenitSelectorForMenuRole(uint8_t role) {
    switch (role) {
        case 1: return @selector(orderFrontStandardAboutPanel:);
        case 2: return NSSelectorFromString(@"showSettingsWindow:");
        case 3: return nil; // Services is wired through NSApp.servicesMenu below.
        case 4: return @selector(hide:);
        case 5: return @selector(hideOtherApplications:);
        case 6: return @selector(unhideAllApplications:);
        case 7: return @selector(terminate:);
        case 8: return @selector(undo:);
        case 9: return @selector(redo:);
        case 10: return @selector(cut:);
        case 11: return @selector(copy:);
        case 12: return @selector(paste:);
        case 13: return @selector(selectAll:);
        case 14: return @selector(performMiniaturize:);
        case 15: return @selector(performZoom:);
        case 16: return @selector(arrangeInFront:);
        default: return nil;
    }
}

int macos_menu_begin(void) {
    @autoreleasepool {
        if (![NSThread isMainThread]) return 0;
        zenitMenuById = [NSMutableDictionary dictionary];
        if (!zenitPendingMenuCommands) zenitPendingMenuCommands = [NSMutableArray array];
        if (!zenitMenuTarget) zenitMenuTarget = [[ZenitMenuCommandTarget alloc] init];
        NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
        [NSApp setMainMenu:main];
        return 1;
    }
}

int macos_menu_add_menu(uint64_t menu_id, uint64_t parent_id, const char *label, size_t label_len) {
    @autoreleasepool {
        if (![NSThread isMainThread] || !NSApp.mainMenu) return 0;
        NSString *title = zenitString(label, label_len);
        NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
        zenitMenuById[@(menu_id)] = menu;
        NSMenu *parent = parent_id == 0 ? NSApp.mainMenu : zenitMenuById[@(parent_id)];
        if (!parent) return 0;
        NSMenuItem *container = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        container.submenu = menu;
        [parent addItem:container];
        return 1;
    }
}

int macos_menu_add_separator(uint64_t parent_id) {
    @autoreleasepool {
        if (![NSThread isMainThread]) return 0;
        NSMenu *parent = zenitMenuById[@(parent_id)];
        if (!parent) return 0;
        [parent addItem:[NSMenuItem separatorItem]];
        return 1;
    }
}

int macos_menu_add_item(uint64_t item_id, uint64_t parent_id,
                        const char *label, size_t label_len,
                        const char *key, size_t key_len,
                        uint8_t modifiers, uint8_t role, uint64_t command_id,
                        int enabled, int checked) {
    @autoreleasepool {
        (void)item_id;
        if (![NSThread isMainThread]) return 0;
        NSMenu *parent = zenitMenuById[@(parent_id)];
        if (!parent) return 0;

        SEL action = zenitSelectorForMenuRole(role);
        id target = nil; // standard roles travel through the responder chain
        if (role == 0 || (role == 2 && command_id != 0)) {
            action = @selector(invokeZenitMenuCommand:);
            target = zenitMenuTarget;
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:zenitString(label, label_len)
                                                      action:action
                                               keyEquivalent:zenitString(key, key_len)];
        item.target = target;
        item.enabled = enabled != 0;
        item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
        item.representedObject = @(command_id);

        NSEventModifierFlags flags = 0;
        if (modifiers & 1) flags |= NSEventModifierFlagShift;
        if (modifiers & 2) flags |= NSEventModifierFlagControl;
        if (modifiers & 4) flags |= NSEventModifierFlagOption;
        if (modifiers & 8) flags |= NSEventModifierFlagCommand;
        item.keyEquivalentModifierMask = flags;
        [parent addItem:item];
        if (role == 3) NSApp.servicesMenu = parent;
        return 1;
    }
}

int macos_menu_commit(void) {
    @autoreleasepool {
        if (![NSThread isMainThread] || !NSApp.mainMenu) return 0;
        [NSApp.mainMenu update];
        return 1;
    }
}

static BOOL zenitHasPendingMenuCommands(void) {
    return zenitPendingMenuCommands.count > 0 || g_menu_actions.count > 0;
}

void macos_menu_discard_window_commands(uint64_t window_id) {
    @autoreleasepool {
        if (![NSThread isMainThread] || window_id == 0) return;
        // No temporary index set: cleanup must not allocate a separate work list.
        for (NSUInteger i = zenitPendingMenuCommands.count; i > 0; i--) {
            if ([zenitPendingMenuCommands[i - 1][@"windowId"] unsignedLongLongValue] == window_id)
                [zenitPendingMenuCommands removeObjectAtIndex:i - 1];
        }
        for (NSUInteger i = g_menu_actions.count; i > 0; i--) {
            if ([g_menu_actions[i - 1][@"windowId"] unsignedLongLongValue] == window_id)
                [g_menu_actions removeObjectAtIndex:i - 1];
        }
    }
}

// Test hook: enqueue a custom menu command exactly as a menu click captures
// it (native window number, or 0 for "no key window").
void macos_menu_post_command_for_testing(uint64_t window_id, uint64_t command_id) {
    @autoreleasepool {
        if (![NSThread isMainThread]) return;
        if (!zenitPendingMenuCommands) zenitPendingMenuCommands = [NSMutableArray array];
        [zenitPendingMenuCommands addObject:@{ @"windowId": @(window_id), @"commandId": @(command_id) }];
        macos_post_empty_event();
    }
}

int macos_menu_poll_command(uint64_t *out_window_id, uint64_t *out_command_id) {
    @autoreleasepool {
        if (![NSThread isMainThread] || !out_window_id || !out_command_id || zenitPendingMenuCommands.count == 0) return 0;
        NSDictionary *packet = zenitPendingMenuCommands.firstObject;
        [zenitPendingMenuCommands removeObjectAtIndex:0];
        *out_window_id = [packet[@"windowId"] unsignedLongLongValue];
        *out_command_id = [packet[@"commandId"] unsignedLongLongValue];
        return 1;
    }
}

// ========== File dialog API ==========

int macos_pick_folder(char* path_buffer, int buffer_size) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        panel.title = @"Open Folder";
        panel.prompt = @"Open";

        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK) return 0; // user cancel

        NSURL *url = panel.URL;
        if (!url) return -1;
        const char *path = [url.path UTF8String];
        if (!path || !path_buffer || buffer_size <= 0) return -1;
        const size_t len = strlen(path);
        if (len >= (size_t)buffer_size) return -1;
        memcpy(path_buffer, path, len);
        path_buffer[len] = '\0';
        return (int)len;
    }
}

// pop NSOpenPanel select file (return path length, 0=cancel,
// -1=error)
int macos_open_file_panel(char* path_buffer, int buffer_size) {
    @autoreleasepool {

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.title = @"Open File";
        panel.prompt = @"Open";
        // don't set allowedContentTypes - allow all file types

        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK) return 0;

        NSURL *url = panel.URL;
        if (!url) return -1;
        const char *path = [url.path UTF8String];
        if (!path || !path_buffer || buffer_size <= 0) return -1;
        const size_t len = strlen(path);
        if (len >= (size_t)buffer_size) return -1;
        memcpy(path_buffer, path, len);
        path_buffer[len] = '\0';
        return (int)len;
    }
}

// pop NSOpenPanel select image (return path length, 0=cancel,
// -1=error)
int macos_pick_image_file_panel(char* path_buffer, int buffer_size) {
    @autoreleasepool {
        NSLog(@"[ImageReplacePanel] opening image picker isMainThread=%d", [NSThread isMainThread]);
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.title = @"Choose Image";
        panel.prompt = @"Choose";
        if (@available(macOS 11.0, *)) {
            panel.allowedContentTypes = @[UTTypeImage];
        } else {
            panel.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"heif", @"avif", @"svg"];
        }

        NSModalResponse response = [panel runModal];
        NSLog(@"[ImageReplacePanel] response=%ld", (long)response);
        if (response != NSModalResponseOK) return 0;

        NSURL *url = panel.URL;
        if (!url) return -1;
        const char *path = [url.path UTF8String];
        if (!path || !path_buffer || buffer_size <= 0) return -1;
        const size_t len = strlen(path);
        if (len >= (size_t)buffer_size) return -1;
        memcpy(path_buffer, path, len);
        path_buffer[len] = '\0';
        NSLog(@"[ImageReplacePanel] selected=%@", url.path);
        return (int)len;
    }
}

int macos_save_panel(const char* suggested_name, const char* default_directory, char* path_buffer, int buffer_size) {
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = @"Save As";
        panel.prompt = @"Save";
        panel.canCreateDirectories = YES;

        if (suggested_name) {
            panel.nameFieldStringValue = [NSString stringWithUTF8String:suggested_name];
        }
        if (default_directory) {
            NSString *dir = [NSString stringWithUTF8String:default_directory];
            NSURL *dirURL = [NSURL fileURLWithPath:dir isDirectory:YES];
            panel.directoryURL = dirURL;
        }

        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK) return 0; // user cancel

        NSURL *url = panel.URL;
        if (!url) return -1;
        const char *path = [url.path UTF8String];
        if (!path || !path_buffer || buffer_size <= 0) return -1;
        const size_t len = strlen(path);
        if (len >= (size_t)buffer_size) return -1;
        memcpy(path_buffer, path, len);
        path_buffer[len] = '\0';
        return (int)len;
    }
}

// ========== Pending Open File Polling API ==========

// Returns: >0 path length written (NUL-terminated), 0 = queue empty,
// <0 = buffer too small; -return is the required buffer size (bytes incl. the
// NUL terminator). A too-small buffer never dequeues and never truncates: the
// path stays at the head for a retry with a larger buffer. (Previously the
// path was dequeued and silently cut to fit, so the file was lost/misopened.)
int macos_get_pending_open_file(char* buffer, int buffer_size) {
    @autoreleasepool {
        if (buffer_size < 0) buffer_size = 0;
        @synchronized ([ZenitAppDelegate class]) {
            while (g_pending_open_files.count > 0) {
                NSString *pending = g_pending_open_files[0];
                const char *utf8 = [pending UTF8String];
                if (!utf8) {
                    // Not representable as UTF-8: can never be delivered.
                    [g_pending_open_files removeObjectAtIndex:0];
                    continue;
                }
                const size_t full_len = strlen(utf8);
                if (full_len >= (size_t)INT_MAX) {
                    [g_pending_open_files removeObjectAtIndex:0];
                    continue;
                }
                if (!buffer || full_len + 1 > (size_t)buffer_size) {
                    return -(int)(full_len + 1);
                }
                memcpy(buffer, utf8, full_len);
                buffer[full_len] = '\0';
                [g_pending_open_files removeObjectAtIndex:0];
                return (int)full_len;
            }
        }
        return 0;
    }
}

// Metal render helper functions

void* metal_create_command_queue(void* device_ptr) {
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)device_ptr;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        return (__bridge_retained void*)queue;
    }
}

void* metal_get_next_drawable(void* layer_ptr) {
    @autoreleasepool {
        CAMetalLayer *layer = (__bridge CAMetalLayer*)layer_ptr;
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) return NULL;
        return (__bridge_retained void*)drawable;
    }
}

void* metal_create_command_buffer(void* queue_ptr) {
    @autoreleasepool {
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)queue_ptr;
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        return (__bridge_retained void*)commandBuffer;
    }
}

void* metal_begin_render_pass(void* command_buffer_ptr, void* texture_ptr,
                               float r, float g, float b, float a) {
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)command_buffer_ptr;
        id<MTLTexture> texture = (__bridge id<MTLTexture>)texture_ptr;

        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        return (__bridge_retained void*)encoder;
    }
}

void metal_end_render_pass(void* encoder_ptr) {
    @autoreleasepool {
        id<MTLRenderCommandEncoder> encoder = (__bridge_transfer id<MTLRenderCommandEncoder>)encoder_ptr;
        [encoder endEncoding];
    }
}

void metal_present_drawable(void* command_buffer_ptr, void* drawable_ptr) {
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)command_buffer_ptr;
        id<CAMetalDrawable> drawable = (__bridge_transfer id<CAMetalDrawable>)drawable_ptr;
        zenitScheduleDrawablePresentation(commandBuffer,drawable);
    }
}

void metal_commit_command_buffer(void* command_buffer_ptr) {
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge_transfer id<MTLCommandBuffer>)command_buffer_ptr;
        [commandBuffer commit];
    }
}

/// return current key window CGWindowID (for screencapture -l). 0
/// if no window
// specific window id (= NSWindow.windowNumber). zig App uses to set
// Cx.window_id, route a11y/system API to this window not first.
uint32_t macos_window_id(void *window_ptr) {
    if (!window_ptr) return 0;
    WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
    if (!wrapper.window) return 0;
    return (uint32_t)((NSInteger)[wrapper.window windowNumber]);
}

uint32_t macos_live_window_count(void) {
    return g_window_list ? (uint32_t)g_window_list.count : 0;
}

int64_t macos_get_key_window_id(void) {
    @autoreleasepool {
        // Background RPC focus must agree with macos_is_window_focused. AppKit
        // can retain an old key window even after a logical palette activation.
        NSWindow *w = zenitBackgroundE2E() ? macos_find_window_by_number(g_requested_key_window) : [NSApp keyWindow];
        // app not foreground keyWindow nil: fall back last-requested-key,
        // then mainWindow, then first
        if (!w) w = macos_find_window_by_number(g_requested_key_window);
        if (!w) w = [NSApp mainWindow];
        if (!w) w = [[NSApp windows] firstObject];
        if (!w) return 0;
        return (int64_t)[w windowNumber];
    }
}

int64_t macos_get_window_id_by_title(const char *title) {
    NSString *target = [NSString stringWithUTF8String:title];
    for (NSWindow *w in [NSApp windows]) {
        if ([[w title] isEqualToString:target]) {
            return (int64_t)[w windowNumber];
        }
    }
    return 0;
}

/// post empty event to NSApp queue, wake runloop. for animation:
/// needs_redraw=true but no event, ensure next pump doesn't empty-wait
void macos_post_empty_event(void) {
    @autoreleasepool {
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                            location:NSZeroPoint
                                       modifierFlags:0
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:0
                                               data1:0
                                               data2:0];
        [NSApp postEvent:event atStart:NO];
    }
}

// ==================== CVDisplayLink (C6) ====================

static BOOL glassClockTraceEnabled(void) {
    static _Atomic(int) cached = -1;
    const int enabled = atomic_load_explicit(&cached, memory_order_acquire);
    if (enabled >= 0) return enabled != 0;
    const char *value = getenv("ZENIT_GLASS_CLOCK_TRACE");
    const int initial = value && strcmp(value, "1") == 0;
    atomic_store_explicit(&cached, initial, memory_order_release);
    return initial != 0;
}

// [borrowed] Reads timing scalars from the live window; no ownership change.
// The target can be stale after idle. Consumers must inspect its host time,
// not treat the last callback as a prediction for every input-driven frame.
uint64_t macos_get_presentation_clock(void *window_ptr, double *times) {
    times[0] = 0;
    times[1] = 0;
    const double frequency = CVGetHostClockFrequency();
    times[2] = (double)CVGetCurrentHostTime() / frequency;
    if (!window_ptr) return 0;
    WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
    for (unsigned int attempt = 0; attempt < 4; attempt++) {
        const uint64_t before = atomic_load_explicit(&wrapper->displayTickSequence, memory_order_seq_cst);
        if (before & 1) continue;
        const uint64_t callback = atomic_load_explicit(&wrapper->displayTickCallbackHostTime, memory_order_seq_cst);
        const uint64_t target = atomic_load_explicit(&wrapper->displayTickTargetHostTime, memory_order_seq_cst);
        if (before != atomic_load_explicit(&wrapper->displayTickSequence, memory_order_seq_cst)) continue;
        times[0] = (double)callback / frequency;
        times[1] = (double)target / frequency;
        return before / 2;
    }
    return atomic_load_explicit(&wrapper->displayTickSequence, memory_order_seq_cst) / 2;
}

uint64_t macos_glass_clock_trace_display_tick(void *window_ptr, double *times) {
    times[0] = 0;
    times[1] = 0;
    if (!glassClockTraceEnabled()) return 0;
    double snapshot[3];
    const uint64_t tick = macos_get_presentation_clock(window_ptr, snapshot);
    times[0] = snapshot[0];
    times[1] = snapshot[1];
    return tick;
}

// A callback being written (odd sequence) still reports the previous completed
// tick. This is a per-window cadence token, not a predicted animation time.
uint64_t macos_get_display_tick(void *window_ptr) {
    WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
    return atomic_load_explicit(&wrapper->displayTickSequence, memory_order_seq_cst) / 2;
}

/// CVDisplayLink vsync callback (runs dedicated high-priority
/// thread)
static CVReturn displayLinkCallback(
    CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow,
    const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn,
    CVOptionFlags *flagsOut,
    void *displayLinkContext
) {
    (void)displayLink;
    (void)inNow;
    (void)flagsIn;
    (void)flagsOut;
    WindowWrapper *wrapper = (__bridge WindowWrapper *)displayLinkContext;
    atomic_fetch_add_explicit(&wrapper->displayTickSequence, 1, memory_order_seq_cst);
    atomic_store_explicit(&wrapper->displayTickCallbackHostTime, CVGetCurrentHostTime(), memory_order_seq_cst);
    atomic_store_explicit(&wrapper->displayTickTargetHostTime,
                          (inOutputTime->flags & kCVTimeStampHostTimeValid) ? inOutputTime->hostTime : 0,
                          memory_order_seq_cst);
    atomic_fetch_add_explicit(&wrapper->displayTickSequence, 1, memory_order_seq_cst);
    // at vsync instant wake main thread render; previous unwaken still
    // not taken don't stack.
    if (!atomic_exchange(&g_display_link_wake_pending, true)) {
        macos_post_empty_event();
    }
    return kCVReturnSuccess;
}

/// start CVDisplayLink - when animations active
void macos_start_display_link(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper.displayLinkRunning) return;

        if (!wrapper.displayLink) {
            CVDisplayLinkRef link = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CVDisplayLinkCreateWithActiveCGDisplays(&link);
            CVDisplayLinkSetOutputCallback(link, &displayLinkCallback, (__bridge void*)wrapper);
            CGDirectDisplayID displayID = (CGDirectDisplayID)[wrapper.window.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            CVDisplayLinkSetCurrentCGDisplay(link, displayID);
#pragma clang diagnostic pop
            wrapper.displayLink = link;
        }

        CVDisplayLinkStart(wrapper.displayLink);
        wrapper.displayLinkRunning = YES;
    }
}

/// stop CVDisplayLink - when idle (save CPU)
void macos_stop_display_link(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.displayLinkRunning) return;
        if (wrapper.displayLink) {
            CVDisplayLinkStop(wrapper.displayLink);
        }
        wrapper.displayLinkRunning = NO;
    }
}

/// get screen refresh rate (Hz)
float macos_get_display_refresh_rate(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (wrapper.displayLink) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CVTime period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(wrapper.displayLink);
#pragma clang diagnostic pop
            if (period.flags & kCVTimeIsIndefinite) return 60.0;
            return (float)period.timeScale / (float)period.timeValue;
        }
        return 60.0;
    }
}

int macos_chrome_configure(void *owner, int mode, int automatic, float height) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper*)owner;
        if (!w.window || (mode==1 && (!isfinite(height) || height<=0))) return 0;
        if (!mode) return 1;
        w.chromeHideControls=mode==2 || !automatic;
        if (mode==2) {
            w.window.styleMask=NSWindowStyleMaskBorderless|NSWindowStyleMaskResizable;
            w.window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
        }
        w.window.titlebarAppearsTransparent=YES;
        w.window.titleVisibility=NSWindowTitleHidden;
        if (mode==1) w.window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        for (NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)]) {
            NSButton *b=[w.window standardWindowButton:kind.integerValue];
            b.hidden=mode==2 || !automatic;
            // windowShouldZoom: is the behavior gate; button state is cosmetic.
            // Re-assert as cheap insurance for paths not driven here (fullscreen
            // round trips, state restoration).
            if (kind.integerValue==NSWindowZoomButton && w.zoomDisabled) b.enabled=NO;
        }
        if (mode==1 && automatic) macos_set_traffic_lights_inset(owner,7,height/2);
        w.window.movableByWindowBackground=NO;
        w.titlebarDragHeight=0;
        return 1;
    }
}
// Explicit `.native` chrome: a real system titlebar (title, standard buttons,
// system drag), with the client below it. Windows are created with a transparent
// full-size titlebar because legacy apps paint their own; only the new chrome API
// asks for this, so the legacy default appearance is unchanged.
int macos_chrome_system_titlebar(void *owner) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper*)owner;
        if (!w.window) return 0;
        NSSize content=w.window.contentView.frame.size;
        w.window.styleMask=(w.window.styleMask & ~(NSWindowStyleMaskFullSizeContentView|NSWindowStyleMaskBorderless))|NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable;
        w.window.titlebarAppearsTransparent=NO;
        w.window.titleVisibility=NSWindowTitleVisible;
        for (NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)]) {
            NSButton *b=[w.window standardWindowButton:kind.integerValue];
            b.hidden=NO;
            // Keep the zoom opt-out symmetric with chrome_configure's insurance.
            if (kind.integerValue==NSWindowZoomButton && w.zoomDisabled) b.enabled=NO;
        }
        w.chromeHideControls=NO;
        w.hasTrafficLightsInset=NO;
        w.titlebarDragHeight=0;
        w.window.movableByWindowBackground=NO;
        // Keep the requested client size; the titlebar is added above it.
        [w.window setContentSize:content];
        return 1;
    }
}
void macos_chrome_hit(void *owner, int (*hit)(void*,float,float), void *context) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper*)owner;
        w.chromeHitCallback=hit; w.chromeHitContext=hit?context:NULL;
    }
}
void macos_chrome_state(void *owner, ZenitChromeState *out) {
    @autoreleasepool {
        memset(out,0,sizeof(*out)); WindowWrapper *w=(__bridge WindowWrapper*)owner;
        out->appearance=1;out->button_layout[3]=1;out->button_layout[4]=2;out->button_layout[5]=3;
        if (!w.window) return;
        out->state_generation=w.chromeStateGeneration;
        out->flags=(w.window.isZoomed?1:0)|((w.window.styleMask & NSWindowStyleMaskFullScreen)?2:0)|(w.window.isKeyWindow?4:0)|(w.chromeFullscreenTransition?8:0);
        out->flags |= 16;
        out->capabilities=63; /* Native resizable edges; no explicit manual resize API. */
        if (w.zoomDisabled) out->capabilities&=~8; /* drop maximize (bit 3) */
        if (w.fullscreenHeader.active) out->flags |= 128;
        if (w.fullscreenHeader.active && zenitHeaderVisible(w.fullscreenHeader.header)) out->flags |= 256;
        if (w.fullscreenHeader.active && w.fullscreenHeader.hasPresented) out->flags |= 512;
        if ((out->flags & 2) && !w.fullscreenHeader.active) return;
        for (NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)]) {
            NSButton *b=[w.window standardWindowButton:kind.integerValue];
            if (!b || b.hidden || w.chromeHideControls) continue;
            NSView *host=w.fullscreenHeader.header ?: w.window.contentView;
            NSRect r=[host convertRect:b.bounds fromView:b];
            float y=(float)(host.bounds.size.height-NSMaxY(r));
            /* The system titlebar can sit outside a native-mode client. */
            if (y<0) continue;
            out->controls[out->controls_count++]=(ZenitChromeRect){(float)r.origin.x,y,(float)r.size.width,(float)r.size.height};
        }
    }
}
int macos_chrome_minimum(void *owner,uint32_t width,uint32_t height) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper*)owner;if(!w.window)return 0;
        w.window.contentMinSize=NSMakeSize(width,height);return 1;
    }
}
int macos_chrome_maximizable(void *owner, int enabled) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper*)owner;if(!w.window)return 0;
        w.zoomDisabled=!enabled;
        [[w.window standardWindowButton:NSWindowZoomButton] setEnabled:enabled!=0];
        return 1;
    }
}
int macos_chrome_restorable(void *owner, int enabled) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper*)owner;if(!w.window)return 0;
        w.window.restorable=enabled!=0;return 1;
    }
}
int macos_chrome_action(void *owner, int action, int value) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper*)owner; if (!w.window) return 0;
        // Close/minimize retain their existing native semantics after will-close.
        if(w.nativeCloseObserved && action!=0 && action!=1) return 0;
        switch(action) {
        case 0: w.shouldClose=YES; return 1;
        case 1:
            if(w.nativeCloseObserved && !w.window.visible) return 1; // Handled no-op; never revive a closed window.
            [w.window miniaturize:nil]; return 1;
        case 2: if (w.window.isZoomed != !!value) [w.window zoom:nil]; return 1;
        case 3:
            if(w.waitingForDeminiaturize || w.fullscreenHeader.pendingFullscreen) {
                if(!value) { // An explicit windowed request cancels preparation.
                    [w.fullscreenHeader stop];[w finishFullscreenEntry];
                    [w.metalView renderFinalResize];macos_post_empty_event();
                }
                return 1; // Duplicate enter is already queued, not refused.
            }
            if(w.chromeFullscreenTransition) return value && w.nativeFullscreenEntering;
            if(!!(w.window.styleMask&NSWindowStyleMaskFullScreen)!=!!value) {
                [w.window toggleFullScreen:nil];
            }
            return 1;
        default: return 0;
        }
    }
}
