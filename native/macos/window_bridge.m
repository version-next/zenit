#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreVideo/CVDisplayLink.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// RPC acceptance runs keep native windows renderable without taking over the desktop.
static BOOL zenitBackgroundE2E(void) {
    const char *value = getenv("ZENIT_E2E_BACKGROUND");
    return value && strcmp(value, "1") == 0;
}

static NSInteger g_requested_key_window = 0;

static void zenitActivateApplication(void) {
    if (!zenitBackgroundE2E()) [NSApp activateIgnoringOtherApps:YES];
}

static void zenitPresentWindow(NSWindow *window) {
    g_requested_key_window = window.windowNumber;
    if (!zenitBackgroundE2E()) [window makeKeyAndOrderFront:nil];
}

@class WindowWrapper;
static WindowWrapper* wrapperForWindow(NSWindow *window);
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

// 拖放桥接层排障开关：ZENIT_DEBUG_DRAG=1 时把 NSDraggingDestination
// 四个回调（kind 0/1/2/3）逐条打到 stderr。kind=3 才带 paths。
// 真机验证（从 Finder 拖文件进窗口）唯一可信判据就是这里出现 kind=3。
static BOOL drag_debug_enabled(void) {
    const char *v = getenv("ZENIT_DEBUG_DRAG");
    return v && v[0] != '\0' && v[0] != '0';
}

// ==== IME ↔ a11y 文档文本查询（NSTextInputClient 补全用） ====
//
// NSTextInputClient 的 range/point 查询都以"聚焦文本框的文档内容"为参照，
// 桥接层自己不持文本 —— 复用 a11y 桥接（zenit_a11y_focused / _value /
// _text_range_at_point）从 Zig 侧按需拉取。声明前置：实现在 a11y 节
// （zenitA11yUTF16OffsetForUTF8 等），MetalView 实现在它们之前。
static uint32_t zenitA11yWindowIdForView(NSView *view);
static NSString *zenitA11yCopyString(int (*fetch)(uint32_t, uint32_t, char *, int),
                                     uint32_t window_id, uint32_t handle);
static NSUInteger zenitA11yUTF16OffsetForUTF8(NSString *text, uint32_t utf8Offset);
static NSString *zenitA11yStringFromUTF8(const void *bytes, NSUInteger len);
static uint32_t zenitA11yUTF8OffsetForUTF16(NSString *text, NSUInteger utf16Offset);
extern uint32_t zenit_a11y_focused(uint32_t window_id);
extern int zenit_a11y_value(uint32_t window_id, uint32_t handle, char *buf, int buf_len);
extern int zenit_a11y_text_selection(uint32_t window_id, uint32_t handle, uint32_t *start, uint32_t *end, uint32_t *caret);
extern int zenit_a11y_text_range_at_point(uint32_t window_id, uint32_t handle, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8);
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

// replacementRange（UTF-16，相对文档）→ UTF-8 字节区间。
// 直接查询实时 TextInputClient，不依赖上一次 render 的 a11y 快照。
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

// Metal 视图 - 在 live resize 时保持渲染
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
// live resize 期间 AppKit 在自己的 tracking loop 里跑，应用主循环不转；只有
// setFrameSize: 触发渲染，拖动停住（按住未松）就一帧都没有 —— 所有动画冻结。
// 这个 ticker 挂在 NSRunLoopCommonModes（含 tracking mode）上持续驱动渲染回调；
// Zig 侧按 wantsFrame 门控，静止内容不重画。
@property (nonatomic, strong) NSTimer *liveResizeTicker;
@property (nonatomic, strong) NSMutableAttributedString *markedTextStorage;
@property (nonatomic, assign) BOOL discardingMarkedText;
- (void)discardMarkedTextFromInputContext;
@property (nonatomic, assign) NSRange markedTextSelectedRange;
// NSTextInputClient ranges are UTF-16 offsets in the complete client document,
// not offsets local to the marked string.
@property (nonatomic, assign) NSRange markedDocumentRange;
// 拖放事件队列：kind 0..3=destination, 4=source completion.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *dragEventQueue;
@property (nonatomic, strong) NSOperationQueue *filePromiseQueue;
@property (nonatomic, assign) BOOL zenitDragSessionActive;
@property (nonatomic, assign) uint64_t zenitDragToken;
@property (nonatomic, assign) NSDragOperation zenitDragAllowedOperations;
@property (nonatomic, assign) NSDragOperation zenitDropAllowedOperations;
// AppKit requires the vendor of virtual NSAccessibilityElement objects to
// retain them for as long as the represented UI exists.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *zenitA11yElementCache;
- (id)zenitA11yElementForHandle:(uint32_t)handle accessibilityParent:(id)parent;
- (id)zenitA11yElementForHandle:(uint32_t)handle;
@end

@implementation MetalView

- (NSTextInputContext *)inputContext {
    if (!_zenitInputContext) {
        _zenitInputContext = [[NSTextInputContext alloc] initWithClient:self];
    }
    return _zenitInputContext;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        // 创建 Metal 设备
        self.device = createBestMetalDevice();
        if (!self.device) {
            NSLog(@"[MetalView] Metal device creation failed (mainThread=%@, screen=%@)",
                  [NSThread isMainThread] ? @"YES" : @"NO",
                  [NSScreen mainScreen]);
            return nil;
        }

        // 拖放：接收文件 / 图片 / URL 拖入（Finder、浏览器）
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

        // 创建 Metal layer 并设置为 view 的 layer
        self.wantsLayer = YES;
        // 关键：live resize 时不要缩放旧内容，而是允许持续重绘
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = self.device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;

        // 性能优化（参考 wgpu-hal surface.rs）
        layer.framebufferOnly = YES;  // 纯渲染，不读取纹理（性能更好）

        // 防止 drawable 超时阻塞（关键！解决拖拽黑屏问题）
        // 参考: https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-hal/src/metal/surface.rs#L101-104
        //
        // ⚠️ 别改成 YES。2026-08-07 实测：允许超时会让重 blur 场景
        // （storybook glasslab）反复吃 ~1s 超时并跳帧，e2e 87/87 → 78/87。
        // 完整理由见 src/gpu/metal/surface.zig 的同名配置注释。
        if (@available(macOS 10.13, *)) {
            layer.allowsNextDrawableTimeout = NO;
        }

        // 控制帧缓冲队列深度（典型值 2-3）
        layer.maximumDrawableCount = 3;

        // 启用 VSync（流畅渲染）
        if (@available(macOS 10.13, *)) {
            layer.displaySyncEnabled = YES;
        }

        CGSize drawableSize = frameRect.size;
        CGFloat scale = currentScreenScale(nil);
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

    // 更新 Metal layer 尺寸
    CGSize drawableSize = self.bounds.size;
    CGFloat scale = currentScreenScale(self.window);
    drawableSize.width *= scale;
    drawableSize.height *= scale;
    self.metalLayer.drawableSize = drawableSize;

    // 直接调用渲染回调，不依赖 drawRect（layer-backed view 不触发 drawRect）
    if (self.renderCallback != NULL) {
        self.renderCallback(self.renderContext);
    }
}

- (void)viewWillStartLiveResize {
    [super viewWillStartLiveResize];
    // 关键：resize 期间启用同步 present，避免 CoreAnimation 拉伸旧帧
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

    // 恢复异步 present（延迟一帧，确保最后一帧也同步呈现）
    // 使用 weak 引用避免窗口关闭后 block 访问已释放的对象
    __weak MetalView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MetalView *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.metalLayer.presentsWithTransaction = NO;

            // setFrameSize: 的回调发生在 AppKit live-resize tracking loop 内。
            // retained UI 的外层布局与依赖其 rect 的子组件会相差一个 layout
            // pass；最后一次 resize 后若没有新输入，就没有下一帧来消费最终
            // contentView bounds，画面会一直停在倒数一个尺寸，直到 hover/click。
            // 回到主队列后 bounds 已提交，直接补交最终帧（单纯 post 空事件并
            // 不会把任一 WindowContext 标成 needs_redraw，因此不足以修复）。
            if (strongSelf.renderCallback != NULL) {
                strongSelf.renderCallback(strongSelf.renderContext);
            }
        }
    });
}

- (BOOL)preservesContentDuringLiveResize {
    // 禁止系统缩放旧内容，避免“先变形后恢复”
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

// NSView 的默认实现对非 opaque 视图返回 YES，于是 movableByWindowBackground
// 会把落在"背景"上的 mouseDown 转成窗口拖拽。但 zenit 的控件全部由 Metal 绘制
// 在这一个视图里，没有任何 NSView 子视图 —— AppKit 无从知道指针底下是不是
// 输入框，只能把整面板当背景，导致输入框内的按下-拖动变成拖窗口，文本选不中。
//
// 窗口拖拽改由 titlebarDragHeight + titlebarHitCallback 那条链负责：它会回调
// Zig 侧做真实 hit-test，点在控件上正常下发事件，只有空白才拖窗。
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
    if (!wrapper || ![[wrapper valueForKey:@"textInputEnabled"] boolValue]) {
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
        // 带 replacement 的直接 insertText（无 marked text 的再変換提交）也走
        // commit 通道 —— text_input 事件没有 replacement 语义。
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
    if (!wrapper || ![[wrapper valueForKey:@"textInputEnabled"] boolValue]) {
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
    // 按键命令由 Zig 侧 key event 处理；这里吞掉系统默认命令，避免 NSBeep。
    if (input_debug_enabled()) {
        NSLog(@"[bridge-input] doCommandBySelector %@", NSStringFromSelector(selector));
    }
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // 系统词典查询 (Ctrl-Cmd-D) / 日文再変換都靠这里读文档文本。
    // 文档内容从聚焦节点的实时 TextInputClient 拉取；NSRange 是 UTF-16
    // 单位，桥接层按 Unicode scalar 边界钳制并映射到 UTF-8 模型。
    return zenitImeCopyAttributedRange(self, range, actualRange);
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    // point 是屏幕坐标（左下原点）。屏幕 → 窗口 → 视图 → zenit 内容坐标
    // （左上原点，与 accessibilityHitTest 同一换算），再走实时文本客户端
    // 命中拿 UTF-8 offset，换算回 UTF-16 返回。
    if (!self.window) return NSNotFound;
    const uint32_t wid = zenitA11yWindowIdForView(self);
    NSPoint window_point = [self.window convertPointFromScreen:point];
    NSPoint local = [self convertPoint:window_point fromView:nil];
    uint32_t start_utf8 = 0;
    uint32_t end_utf8 = 0;
    if (!zenit_text_input_range_at_point(wid,
                                         (float)local.x,
                                         (float)(self.bounds.size.height - local.y),
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
        NSRect windowRect = [contentView convertRect:contentRect toView:nil];
        return [self.window convertRectToScreen:windowRect];
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
        // Zig/UI 侧坐标是左上原点；Cocoa contentView 是左下原点
        NSRect content_rect = NSMakeRect(
            caret_x,
            content_bounds.size.height - caret_y - caret_h,
            caret_w,
            caret_h
        );
        NSRect window_rect = [window.contentView convertRect:content_rect toView:nil];
        NSRect screen_rect = [window convertRectToScreen:window_rect];
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

// ==== 拖放（NSDraggingDestination）====

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
    // 左下原点 → 左上原点
    float x = (float)loc.x;
    float y = (float)(self.bounds.size.height - loc.y);
    NSString *paths = @"";
    uint8_t payloadKind = 0;
    if (withPaths) {
        NSMutableArray<NSString *> *entries = [NSMutableArray array];
        NSPasteboard *pb = [sender draggingPasteboard];
        NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ [NSURL class] ] options:nil];
        for (NSURL *url in urls) {
            // file promise 等来源 url.path 可能为 nil，addObject:nil 会抛
            // NSInvalidArgumentException 取消整个拖拽会话（下游回归）
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

// ========================================================================
// v0.6 §2.1: NSAccessibility 真接管
// ------------------------------------------------------------------------
// zig 端 src/ui/a11y/macos_bridge.zig exports the retained-tree pull ABI;
// 本节用 ObjC 实装 NSAccessibilityElement 子类 ZenitA11yElement，每个对应
// zig 侧 a11y_tree.A11yNode (持 element_handle u32 = ElementId.raw())。
//
// MetalView 实现 accessibilityChildren 协议返回顶级 ZenitA11yElement 数组；
// 子层级递归走 ZenitA11yElement.accessibilityChildren。VoiceOver 因此能
// navigate 整个 zenit widget 树。
//
// 生命周期: ObjC autorelease 池管理；每次 VoiceOver 拉 children 重新生成
// 代理对象。代理只持 u32 handle 不持 zig 内存，过时调用 zenit_a11y_role
// 等会拿不到节点（返 0）—— 这正是 generational handle 的设计目的。

// zig 端 export 声明
// 每个 export 的首参是 window_id —— zig 端按它路由到该窗口自己的 a11y 树。
// window_id 与 zig 侧 Cx.window_id / macos_window_id() 同源 = NSWindow.windowNumber。
// 传 0 (ZENIT_A11Y_ANY_WINDOW) 退化成"第一个已注册窗口"。
#define ZENIT_A11Y_ANY_WINDOW ((uint32_t)0)
extern int zenit_a11y_root_count(uint32_t window_id);
extern uint32_t zenit_a11y_root_at(uint32_t window_id, int idx);
extern int zenit_a11y_exists(uint32_t window_id, uint32_t handle);
extern int zenit_a11y_children_count(uint32_t window_id, uint32_t parent_raw);
extern uint32_t zenit_a11y_children_at(uint32_t window_id, uint32_t parent_raw, int idx);
extern int zenit_a11y_role(uint32_t window_id, uint32_t handle);
extern uint32_t zenit_a11y_state(uint32_t window_id, uint32_t handle);
extern int zenit_a11y_label(uint32_t window_id, uint32_t handle, char *buf, int buf_len);
extern int zenit_a11y_description(uint32_t window_id, uint32_t handle, char *buf, int buf_len);
extern int zenit_a11y_value(uint32_t window_id, uint32_t handle, char *buf, int buf_len);
extern int zenit_a11y_numeric_value(uint32_t window_id, uint32_t handle, float *now, float *min, float *max);
extern int zenit_a11y_frame(uint32_t window_id, uint32_t handle, float *x, float *y, float *width, float *height);
extern uint8_t zenit_a11y_actions(uint32_t window_id, uint32_t handle);
extern int zenit_a11y_perform_action(uint32_t window_id, uint32_t handle, uint8_t action);
extern int zenit_a11y_text_selection(uint32_t window_id, uint32_t handle, uint32_t *start, uint32_t *end, uint32_t *caret);
extern uint8_t zenit_a11y_text_capabilities(uint32_t window_id, uint32_t handle);
extern int zenit_a11y_set_text_selection(uint32_t window_id, uint32_t handle, uint32_t start_utf8, uint32_t end_utf8);
extern int zenit_a11y_set_focus(uint32_t window_id, uint32_t handle, int focused);
extern int zenit_a11y_set_text_value(uint32_t window_id, uint32_t handle, const char *bytes, int len);
extern int zenit_a11y_text_visible_range(uint32_t window_id, uint32_t handle, uint32_t *start, uint32_t *end);
extern int zenit_a11y_text_frame(uint32_t window_id, uint32_t handle, uint32_t start_utf8, uint32_t end_utf8, float *x, float *y, float *width, float *height);
extern int zenit_a11y_text_range_at_point(uint32_t window_id, uint32_t handle, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8);
extern int zenit_a11y_set_numeric_value(uint32_t window_id, uint32_t handle, float value);
extern uint8_t zenit_a11y_numeric_capabilities(uint32_t window_id, uint32_t handle);
extern uint32_t zenit_a11y_parent(uint32_t window_id, uint32_t handle);
extern uint32_t zenit_a11y_focused(uint32_t window_id);
extern uint32_t zenit_a11y_active_descendant(uint32_t window_id, uint32_t handle);
extern uint32_t zenit_a11y_hit_test(uint32_t window_id, float x, float y);
extern uint8_t zenit_a11y_orientation(uint32_t window_id, uint32_t handle);
extern uint8_t zenit_a11y_sort_direction(uint32_t window_id, uint32_t handle);
extern uint16_t zenit_a11y_level(uint32_t window_id, uint32_t handle);
extern int zenit_a11y_row_index_range(uint32_t window_id, uint32_t handle, uint32_t *index, uint32_t *span);
extern int zenit_a11y_column_index_range(uint32_t window_id, uint32_t handle, uint32_t *index, uint32_t *span);
extern int zenit_a11y_placeholder(uint32_t window_id, uint32_t handle, char *buf, int buf_len);
extern int zenit_a11y_identifier(uint32_t window_id, uint32_t handle, char *buf, int buf_len);

enum {
    ZenitA11yActionPress = 0,
    ZenitA11yActionToggle = 1,
    ZenitA11yActionIncrement = 2,
    ZenitA11yActionDecrement = 3,
};

enum {
    ZenitA11yActionBitPress = 1 << 0,
    ZenitA11yActionBitToggle = 1 << 1,
    ZenitA11yActionBitIncrement = 1 << 2,
    ZenitA11yActionBitDecrement = 1 << 3,
};

// zig 端"永不命中"的哨兵（macos_bridge.INVALID/NO_RETAINED 同族 maxInt(u32)，
// 但 a11y 表的键域是 windowNumber，任何真实窗口都不会是 maxInt）。
#define ZENIT_A11Y_DEAD_WINDOW ((uint32_t)0xFFFFFFFFu)
#define ZENIT_A11Y_INVALID_HANDLE ((uint32_t)0xFFFFFFFFu)

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

// NSView → 所属窗口的 a11y 路由键。
//
// window == nil 时返回 DEAD 哨兵而**不是** ANY_WINDOW 通配（2026-07-30 审查
// 修正）：窗口关闭后 VoiceOver 可能仍持有该窗口的 ZenitA11yElement 代理
// （它 retain 了 parentView），通配会让这些残留代理去读**另一个仍存活窗口**
// 的树 —— handle raw 值在别人的树里还会假匹配（ElementId 不含 world 标识），
// VoiceOver 读到完全无关的 role/label。正确语义是"元素已失效"→ 全部查空。
static uint32_t zenitA11yWindowIdForView(NSView *view) {
    NSWindow *win = view.window;
    if (!win) return ZENIT_A11Y_DEAD_WINDOW;
    return (uint32_t)((NSInteger)[win windowNumber]);
}

// a11y_tree.Role enum 值（与 src/ui/a11y/tree.zig pub const Role 顺序对齐；
// 改 zig 端 enum 顺序需同步这里。）
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
        case ZenitA11yTreeRoleDialog: return NSAccessibilitySheetRole;
        case ZenitA11yTreeRoleAlertdialog: return NSAccessibilitySheetRole;
        case ZenitA11yTreeRoleAlert: return NSAccessibilityStaticTextRole;
        case ZenitA11yTreeRoleStatus: return NSAccessibilityStaticTextRole;
        case ZenitA11yTreeRoleLog: return NSAccessibilityListRole;
        case ZenitA11yTreeRoleTabs: return NSAccessibilityTabGroupRole;
        case ZenitA11yTreeRoleTab: return NSAccessibilityRadioButtonRole; // tab 在 AX 用 radio
        case ZenitA11yTreeRoleTabpanel: return NSAccessibilityGroupRole;
        case ZenitA11yTreeRoleTooltip: return NSAccessibilityHelpTagRole;
        case ZenitA11yTreeRoleHeading: return NSAccessibilityStaticTextRole;
        case ZenitA11yTreeRoleParagraph: return NSAccessibilityStaticTextRole;
        case ZenitA11yTreeRoleImage: return NSAccessibilityImageRole;
        case ZenitA11yTreeRoleList: return NSAccessibilityListRole;
        case ZenitA11yTreeRoleSeparator: return NSAccessibilitySplitterRole;
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

// initWithBytes 会吃掉开头的 UTF-8 BOM（U+FEFF），而 Zig 侧的 a11y 偏移按
// 原始 UTF-8 字节计 —— 少了 U+FEFF 所有 UTF-8↔UTF-16 换算整体错 3 字节。
static NSString *zenitA11yStringFromUTF8(const void *bytes, NSUInteger len) {
    NSString *s = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    const unsigned char *b = (const unsigned char *)bytes;
    if (s && len >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF &&
        (s.length == 0 || [s characterAtIndex:0] != 0xFEFF)) {
        s = [@"\uFEFF" stringByAppendingString:s];
    }
    return s;
}

static NSString *zenitA11yCopyString(int (*fetch)(uint32_t, uint32_t, char *, int),
                                     uint32_t window_id, uint32_t handle) {
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

static BOOL zenitA11yHandleIsWithin(uint32_t window_id, uint32_t handle, uint32_t ancestor) {
    uint32_t cursor = handle;
    // A valid retained tree is acyclic. The bound keeps malformed application
    // data from hanging an AppKit accessibility callback.
    for (NSUInteger depth = 0; depth < 4096 && cursor != ZENIT_A11Y_INVALID_HANDLE; depth++) {
        if (cursor == ancestor) return YES;
        cursor = zenit_a11y_parent(window_id, cursor);
    }
    return NO;
}

@interface ZenitA11yElement : NSAccessibilityElement
@property (nonatomic, assign) uint32_t handle;
@property (nonatomic, weak) NSView *parentView;
@property (nonatomic, weak) id accessibilityParentObject;
+ (instancetype)elementForHandle:(uint32_t)handle
                      parentView:(NSView *)parentView
             accessibilityParent:(id)accessibilityParent;
@end

@implementation ZenitA11yElement

+ (instancetype)elementForHandle:(uint32_t)handle
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
    return zenit_a11y_exists(wid, self.handle) &&
        (zenit_a11y_state(wid, self.handle) & ZenitA11yStateHidden) == 0;
}

// 代理只持 handle + parentView，window_id 每次从 parentView 现取 —— 窗口关闭或
// view 换窗口时不会留下过时的 id。
- (uint32_t)zenitWindowId {
    return zenitA11yWindowIdForView(self.parentView);
}

- (NSAccessibilityRole)accessibilityRole {
    return zenitA11yMapRoleToNS(zenit_a11y_role([self zenitWindowId], self.handle));
}

- (NSAccessibilitySubrole)accessibilitySubrole {
    int role = zenit_a11y_role([self zenitWindowId], self.handle);
    if ((zenit_a11y_state([self zenitWindowId], self.handle) & ZenitA11yStateSecure) != 0)
        return NSAccessibilitySecureTextFieldSubrole;
    if (role == ZenitA11yTreeRoleSearchbox) return NSAccessibilitySearchFieldSubrole;
    if (role == ZenitA11yTreeRoleTreeitem) return NSAccessibilityOutlineRowSubrole;
    if (role == ZenitA11yTreeRoleRow) return NSAccessibilityTableRowSubrole;
    if (role == ZenitA11yTreeRoleDialog || role == ZenitA11yTreeRoleAlertdialog)
        return NSAccessibilityDialogSubrole;
    return nil;
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
    return NSAccessibilityRoleDescription([self accessibilityRole], [self accessibilitySubrole]);
}

- (id)accessibilityValue {
    uint32_t wid = [self zenitWindowId];
    int role = zenit_a11y_role(wid, self.handle);
    if (role == ZenitA11yTreeRoleCheckbox || role == ZenitA11yTreeRoleRadio ||
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
        if (bytes.length <= INT_MAX)
            (void)zenit_a11y_set_text_value(wid, self.handle, bytes.bytes, (int)bytes.length);
        return;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        (void)zenit_a11y_set_numeric_value(wid, self.handle, [(NSNumber *)value floatValue]);
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
    (void)zenit_a11y_set_focus([self zenitWindowId], self.handle, focused ? 1 : 0);
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
        uint32_t h = zenit_a11y_children_at(wid, self.handle, i);
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
    return [self accessibilityChildren];
}

- (NSArray *)accessibilitySelectedChildren {
    uint32_t wid = [self zenitWindowId];
    uint32_t active = zenit_a11y_active_descendant(wid, self.handle);
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
    uint32_t active = zenit_a11y_active_descendant(wid, self.handle);
    if (active != ZENIT_A11Y_INVALID_HANDLE)
        return [(MetalView *)self.parentView zenitA11yElementForHandle:active];
    uint32_t focused = zenit_a11y_focused(wid);
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

- (NSArray *)accessibilityRows {
    uint32_t wid = [self zenitWindowId];
    NSMutableArray *rows = [NSMutableArray array];
    for (ZenitA11yElement *child in [self accessibilityChildren]) {
        int role = zenit_a11y_role(wid, child.handle);
        if (role == ZenitA11yTreeRoleTreeitem) {
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
    NSMutableArray *rows = [NSMutableArray array];
    for (ZenitA11yElement *row in [self accessibilityRows])
        if ([row isAccessibilitySelected]) [rows addObject:row];
    return rows;
}

- (NSArray *)accessibilityColumns {
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

- (NSArray *)accessibilityVisibleRows { return [self accessibilityRows]; }
- (NSArray *)accessibilityVisibleColumns { return [self accessibilityColumns]; }
- (NSInteger)accessibilityRowCount { return (NSInteger)[[self accessibilityRows] count]; }
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
    for (ZenitA11yElement *row in [self accessibilityRows]) {
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
    NSRect window_rect = [v convertRect:local toView:nil];
    return [v.window convertRectToScreen:window_rect];
}

- (NSPoint)accessibilityActivationPoint {
    NSRect frame = [self accessibilityFrame];
    return NSMakePoint(NSMidX(frame), NSMidY(frame));
}

- (id)accessibilityHitTest:(NSPoint)point {
    return [(MetalView *)self.parentView accessibilityHitTest:point];
}

- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
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

- (BOOL)accessibilityPerformPress {
    uint32_t wid = [self zenitWindowId];
    uint8_t actions = zenit_a11y_actions(wid, self.handle);
    uint8_t action = (actions & ZenitA11yActionBitToggle) ? ZenitA11yActionToggle : ZenitA11yActionPress;
    return zenit_a11y_perform_action(wid, self.handle, action) != 0;
}

- (BOOL)accessibilityPerformIncrement {
    return zenit_a11y_perform_action([self zenitWindowId], self.handle, ZenitA11yActionIncrement) != 0;
}

- (BOOL)accessibilityPerformDecrement {
    return zenit_a11y_perform_action([self zenitWindowId], self.handle, ZenitA11yActionDecrement) != 0;
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
    (void)zenit_a11y_set_text_selection(wid, self.handle, start, end);
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
@end

@implementation MetalView (ZenitA11y)

- (id)zenitA11yElementForHandle:(uint32_t)handle accessibilityParent:(id)parent {
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

- (id)zenitA11yElementForHandle:(uint32_t)handle {
    if (handle == ZENIT_A11Y_INVALID_HANDLE) return nil;
    uint32_t wid = zenitA11yWindowIdForView(self);
    if (!zenit_a11y_exists(wid, handle)) return nil;
    uint32_t parentHandle = zenit_a11y_parent(wid, handle);
    id parent = self;
    if (parentHandle != ZENIT_A11Y_INVALID_HANDLE) {
        // Prefer an already retained parent; recursive creation is bounded by
        // the valid retained tree and gives focus notifications the right AX
        // ancestry even before VoiceOver has pulled children.
        parent = [self zenitA11yElementForHandle:parentHandle] ?: self;
    }
    return [self zenitA11yElementForHandle:handle accessibilityParent:parent];
}

- (NSArray *)zenitAccessibilityRootChildren {
    uint32_t wid = zenitA11yWindowIdForView(self);
    // Retain live virtual elements, but never let handles from an earlier tree
    // accumulate or alias a later generational handle.
    for (NSNumber *key in [self.zenitA11yElementCache.allKeys copy]) {
        if (!zenit_a11y_exists(wid, key.unsignedIntValue)) {
            [self.zenitA11yElementCache removeObjectForKey:key];
        }
    }
    int n = zenit_a11y_root_count(wid);
    if (n <= 0) {
        // 没注册 a11y_tree (test mode 或 cx 未挂)，落 super 行为
        return [super accessibilityChildren];
    }
    NSMutableArray *kids = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        uint32_t h = zenit_a11y_root_at(wid, i);
        if (h == ZENIT_A11Y_INVALID_HANDLE) continue;
        [kids addObject:[self zenitA11yElementForHandle:h accessibilityParent:self]];
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
    uint32_t focused = zenit_a11y_focused(zenitA11yWindowIdForView(self));
    return focused == ZENIT_A11Y_INVALID_HANDLE ? nil : [self zenitA11yElementForHandle:focused];
}

- (id)accessibilityHitTest:(NSPoint)point {
    if (!self.window) return self;
    NSPoint windowPoint = [self.window convertPointFromScreen:point];
    NSPoint local = [self convertPoint:windowPoint fromView:nil];
    uint32_t handle = zenit_a11y_hit_test(
        zenitA11yWindowIdForView(self),
        (float)local.x,
        (float)(self.bounds.size.height - local.y)
    );
    return handle == ZENIT_A11Y_INVALID_HANDLE ? self : [self zenitA11yElementForHandle:handle];
}

- (BOOL)isAccessibilityElement {
    // Virtual Zenit children are not NSView descendants, so keep the hosting
    // view in the AX hierarchy as their explicit group parent.
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityGroupRole;
}

- (NSString *)accessibilityLabel {
    return @"Zenit content";
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
    // 原始 NSEventModifierFlags。⇧ 加选、⌘ 深选、ctrl 框选这类交互全靠它，
    // 少了这个字段，修饰键在真机上永远读到 false（合成事件路径反而正常，
    // 因为它绕过本桥——这正是"自动化测试全绿、真机全废"的成因）。
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

// 与 system_sdk.events.ScrollPhase 对齐：0 none, 1 may_begin, 2 began,
// 3 changed, 4 ended, 5 cancelled。惯性事件的 phase 是 None（由 momentumPhase 标记）。
static uint8_t zenitScrollPhaseCode(NSEvent *event) {
    switch (event.phase) {
        case NSEventPhaseNone: return 0;
        case NSEventPhaseMayBegin: return 1;
        case NSEventPhaseBegan: return 2;
        case NSEventPhaseChanged:
        case NSEventPhaseStationary: return 3;
        case NSEventPhaseEnded: return 4;
        case NSEventPhaseCancelled: return 5;
        // NSEventPhase 是位掩码：组合位或新值仍表示手势进行中，不能当成鼠标滚轮
        default: return 3;
    }
}

// 与 system_sdk.events.MomentumPhase 对齐：0 none, 1 began, 2 changed, 3 ended。
static uint8_t zenitMomentumPhaseCode(NSEvent *event) {
    switch (event.momentumPhase) {
        case NSEventPhaseNone: return 0;
        case NSEventPhaseBegan: return 1;
        case NSEventPhaseEnded:
        case NSEventPhaseCancelled: return 3;
        // Changed / Stationary / 未知组合：惯性仍在进行
        default: return 2;
    }
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

// 窗口包装器 (同时作为 NSWindowDelegate 处理关闭事件)
@interface WindowWrapper : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) MetalView *metalView;
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
// 鼠标状态
@property (nonatomic) NSPoint mouseLocation;
@property (nonatomic) BOOL leftButtonPressed;
@property (nonatomic) BOOL rightButtonPressed;
@property (nonatomic) BOOL middleButtonPressed;
// 键盘状态
@property (nonatomic, strong) NSMutableArray<NSValue *> *keyEventQueue;
@property (nonatomic, strong) NSString *inputText;
@property (nonatomic, strong) NSMutableArray<ZenitTextEventPacket *> *inputTextQueue;
// IME 状态
@property (nonatomic, strong) NSString *imePreeditText;
@property (nonatomic) uint32_t imePreeditCursorUtf16;
@property (nonatomic, strong) NSMutableArray<ZenitTextEventPacket *> *imePreeditQueue;
// preedit/commit 的 replacementRange（UTF-8 字节区间，相对文档）。
// ZENIT_IME_NO_REPLACEMENT 哨兵 = 本次无 replacement。
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
// Source bound at the last AppKit responder activation. InputMethodKit can
// otherwise expose a new source ID while continuing to emit literal ASCII.
@property (nonatomic, copy) NSString *lastKeyboardInputSource;
@property (nonatomic) unsigned long long pollSeq;
@property (nonatomic) unsigned long long lastInsertPollSeq;
@property (nonatomic) unsigned long long keyDispatchSeq;
@property (nonatomic) unsigned long long lastInsertKeyDispatchSeq;
@property (nonatomic, strong) NSString *lastInsertText;
@property (nonatomic) BOOL lastInsertHadMarked;
// 原生 mouse moved/dragged 队列；压力下只合并相邻 move。
@property (nonatomic, strong) NSMutableArray<NSValue *> *mouseMoveQueue;
// 鼠标按键事件队列（避免轮询 miss 同帧按下+松开）
@property (nonatomic, strong) NSMutableArray<NSValue *> *mouseButtonQueue;
// 滚轮状态
@property (nonatomic, strong) NSMutableArray<NSValue *> *scrollEventQueue;
@property (nonatomic, strong) NSMutableArray<NSValue *> *magnifyEventQueue;
// Inspector pick 模式：非 key window 时也接受鼠标移动（用于跨窗口 hover）
@property (nonatomic) BOOL acceptsMouseMovedWhileInactive;
// 自定义 TitleBar 拖拽区域高度（逻辑像素，从窗口顶部算起）
// 设为 > 0 时，mouseDown 落在此区域内会触发 performWindowDragWithEvent
@property (nonatomic) float titlebarDragHeight;
// TitleBar 右侧排除拖拽的宽度（逻辑像素）。用于让 titlebar 右侧的 action buttons
// 正常接收 click，而不是被 performWindowDragWithEvent 吃掉。
@property (nonatomic) float titlebarDragRightInset;
// 命中驱动拖拽区：mouseDown 落入拖拽带时先问 Zig 侧该点是否有交互控件；
// 返回非 0 = 有控件，事件正常下发不触发窗口拖拽。NULL = 退回矩形模型。
@property (nonatomic, assign) int (*titlebarHitCallback)(void* ctx, float x, float y);
@property (nonatomic, assign) void* titlebarHitContext;
// 失焦回调：窗口从 key 变为非 key 时触发（附带新 key window 是否属于本进程）。
// 浮窗（find/palette）用它实现"点回宿主窗口就关掉自己，点到别的 app 则保留"。
@property (nonatomic, assign) void (*resignKeyCallback)(void* ctx, int new_key_is_owner);
@property (nonatomic, assign) void* resignKeyContext;
// 归属窗口（addChildWindow 的 parent）。仅用于 resignKey 时判断新 key window
// 是不是自己的宿主 —— 子窗口关系本身由 AppKit 维护。
@property (nonatomic, weak) NSWindow* ownerWindow;
// CVDisplayLink for vsync-driven frame scheduling (C6)
@property (nonatomic) CVDisplayLinkRef displayLink;
@property (nonatomic) BOOL displayLinkRunning;
// 自定义 traffic lights 位置：AppKit 在 resize/全屏切换时会重排 titlebar
// 按钮，需要记住 inset 并在 windowDidResize 等时机重新应用
@property (nonatomic) BOOL hasTrafficLightsInset;
@property (nonatomic) float trafficLightsInsetX;
@property (nonatomic) float trafficLightsInsetY;
- (void)applyTrafficLightsInset;
@end

@implementation WindowWrapper

- (BOOL)windowShouldClose:(NSWindow *)sender {
    NSLog(@"[windowShouldClose] window=%@ title=%@", sender, sender.title);
    if (self.closeCommitted) {
        return YES;
    }
    self.shouldClose = YES;
    return NO;  // 先让 Zig 处理 dirty tabs；确认后会再次走 performClose:
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    NSLog(@"[windowWillClose] window=%@ title=%@", self.window, self.window.title);
    self.nativeCloseObserved = YES;
    self.shouldClose = NO;
    if (self.nativeCloseRetentionElapsed) {
        self.nativeCloseCompleted = YES;
    }
    // Wake the Zig event pump. Resource destruction is intentionally deferred
    // until the native close retention boundary has also elapsed.
    macos_post_empty_event();
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    // 拖到另一块显示器（60Hz↔120Hz）时把 display link 重绑到新屏，刷新率跟随
    if (self.displayLink) {
        CGDirectDisplayID did = (CGDirectDisplayID)[self.window.screen
            .deviceDescription[@"NSScreenNumber"] unsignedIntValue];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkSetCurrentCGDisplay(self.displayLink, did);
#pragma clang diagnostic pop
    }
}

- (void)applyTrafficLightsInset {
    if (!self.hasTrafficLightsInset) return;
    NSWindow *window = self.window;
    NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
    NSButton *miniButton = [window standardWindowButton:NSWindowMiniaturizeButton];
    NSButton *zoomButton = [window standardWindowButton:NSWindowZoomButton];
    if (!closeButton || !miniButton || !zoomButton) return;

    // 全屏下 titlebar 自动隐藏，交给系统摆放
    if (window.styleMask & NSWindowStyleMaskFullScreen) return;

    NSView *titlebarView = closeButton.superview;
    if (!titlebarView) return;

    CGFloat button_size = closeButton.frame.size.height;
    CGFloat inset_x = self.trafficLightsInsetX;

    // NSTitlebarContainerView 会**裁剪**子树：按钮画得出去（layer 不受
    // 裁剪约束），但 hit-test 出不去。系统默认容器只有 ~32px 高，往下摆
    // inset_y=36 的按钮时 origin.y 会算成负数，14px 的按钮只剩顶部 3px
    // 落在容器内——用户看到完整的红绿灯，却只有最上面一条能点中/hover
    // （实测：按钮画在 window-y 795..809，hit 只在 806..808 成立）。
    // 所以先把容器撑到"能装下按钮"，再在容器内摆位；不能只挪按钮。
    NSView *containerView = titlebarView.superview;
    CGFloat needed_h = self.trafficLightsInsetY + button_size / 2.0;
    if (containerView && [containerView isKindOfClass:NSClassFromString(@"NSTitlebarContainerView")]) {
        NSRect cf = containerView.frame;
        if (needed_h > cf.size.height) {
            // 容器在 NSThemeFrame 里是**顶对齐**的（origin.y 越大越靠上），
            // 长高要同时下移 origin，否则整条会顶出窗口外。
            CGFloat delta = needed_h - cf.size.height;
            cf.origin.y -= delta;
            cf.size.height = needed_h;
            containerView.frame = cf;
            // titlebarView 自身也要跟着填满容器，否则按钮仍会掉出它的 bounds
            NSRect tf = titlebarView.frame;
            tf.origin.y = 0;
            tf.size.height = needed_h;
            titlebarView.frame = tf;
        }
    }

    // 此时 titlebarView 的高度已 >= needed_h，button_y 保证非负
    CGFloat button_y = titlebarView.frame.size.height - self.trafficLightsInsetY - button_size / 2.0;
    if (button_y < 0) button_y = 0;

    NSButton *buttons[3] = { closeButton, miniButton, zoomButton };
    for (int i = 0; i < 3; i++) {
        NSRect f = buttons[i].frame;
        f.origin.x = inset_x + i * 20;
        f.origin.y = button_y;
        buttons[i].frame = f;
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    [self applyTrafficLightsInset];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    [self applyTrafficLightsInset];
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
    // 谁抢走了 key？这决定浮窗该不该关：
    //   - 新 key window 是自己的 owner（或本进程其它窗口）→ 用户回到了应用本体，
    //     浮窗关掉，符合 IDE 里"点回编辑器就收起搜索框"的直觉。
    //   - 新 key window 为 nil 或属于别的 app → 用户只是切走了，浮窗保留，
    //     切回来时内容还在。
    // 关键：必须延后一拍再判断。resignKey 发出时新窗口往往还没成为 key，
    // 此刻读 [NSApp keyWindow] 会拿到 nil，把"点宿主窗口"误判成"切到别的 app"。
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
            // 本进程的任意窗口都算"回到应用本体"；owner 命中时更明确。
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

static id zenitAccessibilityTarget(WindowWrapper *wrapper) {
    if (!wrapper) return nil;
    return wrapper.metalView ?: wrapper.window.contentView ?: wrapper.window;
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

// 全局窗口注册表：NSWindow -> WindowWrapper (支持多窗口事件路由)
static NSMapTable *g_window_registry = nil;
// 全局窗口列表（快速遍历，用于 Cmd+` 窗口切换）
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
    return [g_window_registry objectForKey:window];
}

// C API 导出

// 创建窗口
// 内部共享：根据 styleMask 创建并完成 wrapper 注册
static void* macos_create_window_internal(int width, int height, const char* title, NSWindowStyleMask styleMask, BOOL borderless) {
    @autoreleasepool {
        NSRect frame = NSMakeRect(0, 0, width, height);

        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
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
            // 不用 movableByWindowBackground：它的作用域是整个窗口背景，会连
            // 输入框一起吃掉（见 MetalView.mouseDownCanMoveWindow 的说明）。
            // 拖拽区由上层用 setTitlebarDragHeight 显式声明。
            window.movableByWindowBackground = NO;
            window.hasShadow = YES;
            // 浮岛风格：圆角 + 关闭按 Esc 由上层处理
            window.backgroundColor = [NSColor whiteColor];
            window.opaque = NO;
            // 不设 NSFloatingWindowLevel：那是**全局**层级，会连别的 app 的窗口
            // 一起压住 —— 用户切到浏览器，浮窗还赖在最上面。正确的"永远压在宿主
            // 窗口之上"应由 addChildWindow 表达（见 macos_add_child_window），
            // 那是 app 内的相对关系，切走时会跟着宿主一起沉下去。
            //
            // 宿主没挂子窗口关系时保持普通层级即可；真需要 Spotlight 那种全局浮动
            // 的场景应显式要求，而不是让 borderless 这个外观标志顺带决定。
            window.level = NSNormalWindowLevel;
        } else {
            // 透明标题栏 — 内容延伸到标题栏区域，由 App 自绘 TitleBar
            window.titlebarAppearsTransparent = YES;
            window.titleVisibility = NSWindowTitleHidden;
        }

        [window setTitle:[NSString stringWithUTF8String:title]];
        [window center];

        // 创建 Metal 视图
        MetalView *metalView = [[MetalView alloc] initWithFrame:frame];
        if (!metalView) {
            NSLog(@"[macos_create_window] Failed to create MetalView");
            return NULL;
        }
        metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        [window setContentView:metalView];

        // 包装窗口和视图
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

// 公共入口：标准窗口（带标题栏 + traffic light）
void* macos_create_window(int width, int height, const char* title) {
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskResizable |
                                  NSWindowStyleMaskMiniaturizable |
                                  NSWindowStyleMaskFullSizeContentView;
    return macos_create_window_internal(width, height, title, styleMask, NO);
}

// 显式提升窗口为 key window（borderless 浮窗 focus 易丢）
// 最近一次被要求成为 key 的窗口号。应用不在前台时 AppKit 拒绝换 key/main window，
// 多窗口 e2e（以及快捷键路由）需要一个不依赖前台状态的"逻辑焦点窗口"。

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

// 把 child 挂成 parent 的子窗口：z 序永远跟随、随 parent 一起前置/最小化，
// parent 关闭时 AppKit 自动带走 child。这是 IDE 里"搜索框永远压在项目窗口之上、
// 且和项目窗口一起活动"的原生做法 —— 比 NSFloatingWindowLevel 正确得多，后者是
// **全局**层级，会连别的 app 的窗口一起压住。
void macos_add_child_window(void* parent_ptr, void* child_ptr) {
    @autoreleasepool {
        WindowWrapper *parent = (__bridge WindowWrapper*)parent_ptr;
        WindowWrapper *child = (__bridge WindowWrapper*)child_ptr;
        if (!parent || !child || !parent.window || !child.window) return;
        // 子窗口一旦挂上就不该再自带全局浮动层级，否则仍会压住别的 app。
        child.window.level = NSNormalWindowLevel;
        [parent.window addChildWindow:child.window ordered:NSWindowAbove];
        child.ownerWindow = parent.window;
    }
}

// 把 child 居中到 parent 的**窗口**上，而不是屏幕。
//
// 建窗时统一走 `[window center]`（居中到屏幕），对主窗口是对的，但对
// Command Palette / Quick Open / Find 这类依附于某个编辑器窗口的浮层是错的：
// 编辑器窗口一旦不在屏幕正中（用户挪过、或多显示器、或半屏），浮层就会飞到
// 离它很远的地方，甚至落在另一块屏幕上。用户的心智是「这个面板属于这个窗口」，
// 所以它必须出现在那个窗口的中间。
//
// == 为什么这里只做取值与落盘，不做算术 ==
// 居中公式（含纵向偏上、屏幕夹取）全部放在 Zig 侧的纯函数里算，
// 见下游编辑器的窗口居中实现。ObjC 这层碰不到单元测试，
// 把判断逻辑留在这儿等于永远只能靠肉眼验。这里只负责两件 ObjC 才能做的事：
// 读出宿主/浮层/屏幕可见区域的几何，以及把算好的原点写回窗口。
//
// 几何通过 out 参数回传（NSRect 不适合跨 C ABI 直接传）。
// 返回 0 表示拿不到窗口，调用方应放弃定位而不是拿零值去算。
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

        // visibleFrame 已排除菜单栏与 Dock。取宿主所在那块屏幕：
        // 多显示器下浮层必须留在宿主那一块，不能跳到主屏。
        NSScreen *screen = parent.window.screen ?: [NSScreen mainScreen];
        NSRect vis = screen ? screen.visibleFrame : host;
        *vis_x = vis.origin.x; *vis_y = vis.origin.y;
        *vis_w = vis.size.width; *vis_h = vis.size.height;
        return 1;
    }
}

// 把窗口左下角（AppKit 坐标系）设到指定点。
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

// 注册失焦回调（NULL 清除）。回调参数 new_key_is_owner：
// 1 = 焦点回到了本应用（通常是宿主窗口），0 = 焦点去了别的 app 或没有 key window。
void macos_set_resign_key_callback(void* window_ptr, void (*cb)(void* ctx, int is_owner), void* ctx) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper) return;
        wrapper.resignKeyCallback = cb;
        wrapper.resignKeyContext = ctx;
    }
}

// 公共入口：无标题栏浮层窗口（看起来无标题栏 / 无 traffic light，但保留 NSWindow 自带 resize）
// 实现：仍用 Titled/Resizable/FullSizeContentView，仅隐藏 traffic light 三按钮 + titlebar 视觉。
void* macos_create_window_borderless(int width, int height, const char* title) {
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskResizable |
                                  NSWindowStyleMaskFullSizeContentView;
    void *result = macos_create_window_internal(width, height, title, styleMask, YES);
    if (result) {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)result;
        NSWindow *w = wrapper.window;
        // 隐藏 traffic light 三按钮
        [[w standardWindowButton:NSWindowCloseButton] setHidden:YES];
        [[w standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
        [[w standardWindowButton:NSWindowZoomButton] setHidden:YES];
        // Titled + FullSizeContentView 会在内容顶部留一条**不可见但仍可拖**的
        // 系统标题栏（NSThemeFrame，实测约 32px）。宿主若把可交互控件直接摆在
        // 窗口最顶部，控件就会被它盖住：框内按下-拖动变成拖窗口，文本选不中。
        //
        // 这里只关掉"整窗背景可拖"。那条隐形标题栏不归 MetalView 管，关不掉，
        // 也**不应该**在这里关 —— setMovable:NO 会连带废掉
        // performWindowDragWithEvent 之外的一切拖拽，让没有自绘标题条的宿主
        // 窗口彻底移动不了。正确的做法是宿主在顶部留出自己的标题条（见
        // 下游编辑器的标题栏拖拽区组件），把控件推到那条
        // 隐形标题栏之下。
        w.movableByWindowBackground = NO;
    }
    return result;
}

// 获取 Metal 视图
void* macos_get_metal_view(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return (__bridge void*)wrapper.metalView;
    }
}

// 设置 live resize 渲染回调
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

// 请求重绘
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

// ========================================================================
// v0.6 §2.4: a11y_router.flushToBridge push-side C ABI
// ------------------------------------------------------------------------
// zig 端 src/ui/a11y/macos_bridge.zig extern 调进来；window_id 路由到
// g_window_list 中的对应 wrapper (当前 single-window 实现走第一个；
// window_id = NSWindow.windowNumber，与 zig 侧 Cx.window_id 同源)。
//
// Retained-tree notifications target the exact virtual element. The legacy
// SystemSdk snapshot calls remain a public compatibility API, but Cx suppresses
// their automatic focus path to avoid duplicate host-view announcements.

static WindowWrapper *zenitWrapperForWindowId(uint32_t window_id) {
    if (!g_window_list) return nil;
    // window_id == NSWindow.windowNumber（zig 侧 Cx.window_id 同源）。
    // 0 = 通配（未接线的调用方），退化成第一个有效 wrapper。
    for (NSWindow *win in g_window_list) {
        WindowWrapper *w = wrapperForWindow(win);
        if (!w) continue;
        if (window_id == ZENIT_A11Y_ANY_WINDOW) return w;
        if ((uint32_t)((NSInteger)[win windowNumber]) == window_id) return w;
    }
    return nil;
}

static id zenitA11yTargetForHandle(WindowWrapper *wrapper, uint32_t handle) {
    if (!wrapper || !wrapper.metalView) return nil;
    if (handle == ZENIT_A11Y_INVALID_HANDLE) return wrapper.metalView;
    return [wrapper.metalView zenitA11yElementForHandle:handle] ?: wrapper.metalView;
}

int zenit_a11y_push_property_changed(uint32_t window_id, uint32_t element_raw, uint16_t flags) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper) return 0;
        id target = zenitA11yTargetForHandle(wrapper, element_raw);
        if (!target) return 0;
        if ((flags & ZenitA11yDirtyLabel) != 0)
            NSAccessibilityPostNotification(target, NSAccessibilityTitleChangedNotification);
        if ((flags & (ZenitA11yDirtyValue | ZenitA11yDirtyState)) != 0)
            NSAccessibilityPostNotification(target, NSAccessibilityValueChangedNotification);
        if ((flags & ZenitA11yDirtySelection) != 0)
            NSAccessibilityPostNotification(target, NSAccessibilitySelectedTextChangedNotification);
        if ((flags & ZenitA11yDirtyGeometry) != 0) {
            NSAccessibilityPostNotification(target, NSAccessibilityMovedNotification);
            NSAccessibilityPostNotification(target, NSAccessibilityResizedNotification);
        }
        if ((flags & ZenitA11yDirtyRole) != 0)
            NSAccessibilityPostNotification([target accessibilityParent] ?: wrapper.metalView,
                                            NSAccessibilityLayoutChangedNotification);
        return 1;
    }
}

int zenit_a11y_push_focus_changed(uint32_t window_id, uint32_t element_raw) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper) return 0;
        id target = zenitA11yTargetForHandle(wrapper, element_raw);
        if (!target) return 0;
        NSAccessibilityPostNotification(target, NSAccessibilityFocusedUIElementChangedNotification);
        return 1;
    }
}

int zenit_a11y_push_children_changed(uint32_t window_id, uint32_t element_raw) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper) return 0;
        id target = zenitA11yTargetForHandle(wrapper, element_raw);
        if (!target) return 0;
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

// aria-activedescendant 投影：容器持焦但视觉焦点落在 active 子元素。
// NSAccessibility has no one-to-one active-descendant property. Expose the
// relation through selectedChildren/focusedUIElement and notify both exact
// virtual elements so VoiceOver re-pulls those attributes.
int zenit_a11y_push_active_descendant(uint32_t window_id, uint32_t container_raw, uint32_t active_raw) {
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

int zenit_a11y_push_window_cleared(uint32_t window_id) {
    @autoreleasepool {
        WindowWrapper *wrapper = zenitWrapperForWindowId(window_id);
        if (!wrapper || !wrapper.metalView) return 0;
        NSArray *stale = [wrapper.metalView.zenitA11yElementCache.allValues copy];
        for (id element in stale)
            NSAccessibilityPostNotification(element, NSAccessibilityUIElementDestroyedNotification);
        [wrapper.metalView.zenitA11yElementCache removeAllObjects];
        NSAccessibilityPostNotification(wrapper.metalView, NSAccessibilityLayoutChangedNotification);
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

// 放弃当前 IME 合成：关闭候选窗、清 marked text 与 preedit 状态，但不改变
// enabled 状态。文本客户端 A→B 直接切换需要 discard A 后继续为 B 接收输入；
// 只有 macos_set_text_input_enabled(false) 拥有关闭原生闸的权限。
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

// 查询是否处于 live resize
int macos_is_live_resize(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return wrapper.window.inLiveResize ? 1 : 0;
    }
}

// 获取 Metal Layer
void* macos_get_metal_layer(void* view_ptr) {
    @autoreleasepool {
        MetalView *view = (__bridge MetalView*)view_ptr;
        return (__bridge void*)view.metalLayer;
    }
}

// 获取 Metal Device
void* macos_get_metal_device(void* view_ptr) {
    @autoreleasepool {
        MetalView *view = (__bridge MetalView*)view_ptr;
        return (__bridge void*)view.device;
    }
}

// ========== 全局退出标志（多窗口架构用） ==========
static BOOL zenitHasPendingMenuCommands(void);
void macos_menu_discard_window_commands(uint64_t window_id);

static BOOL g_app_should_quit = NO;
// App 从后台切换到前台时置 YES，由 Zig 侧消费后重置，触发所有窗口重绘
static BOOL g_app_became_active = NO;

// ========== 全局菜单动作队列 ==========
// 菜单动作枚举（与 Zig 侧 MenuAction 一一对应）
typedef enum {
    MenuActionNone = 0,
    MenuActionNewFile = 1,         // New Text File (Cmd+N) — 已有快捷键，菜单仅冗余
    MenuActionNewFileDialog = 2,   // New File... (Ctrl+Alt+Cmd+N)
    MenuActionNewWindow = 3,       // New Window (Shift+Cmd+N)
    MenuActionOpenFile = 4,        // Open... (Cmd+O)
    MenuActionOpenFolder = 5,      // Open Folder...
    MenuActionOpenRecent = 6,      // Open Recent (placeholder)
    MenuActionSave = 7,            // Save (Cmd+S)
    MenuActionSaveAs = 8,          // Save As... (Shift+Cmd+S)
    MenuActionCloseTab = 9,        // Close Tab (Cmd+W) — 已有快捷键
    MenuActionCloseWindow = 10,    // Close Window (Shift+Cmd+W)
    MenuActionInstallCli = 11,     // Install Command Line Tool（应用菜单）
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
    if (!window_id || !action || !g_menu_actions.count) return 0;
    NSDictionary *packet = g_menu_actions.firstObject;
    *window_id = [packet[@"windowId"] unsignedLongLongValue];
    *action = [packet[@"action"] intValue];
    [g_menu_actions removeObjectAtIndex:0];
    return 1;
}

static MenuActionType popMenuAction(void) {
    uint64_t window_id; int action;
    return macos_get_menu_action_event(&window_id, &action) ? (MenuActionType)action : MenuActionNone;
}

// 将事件中的鼠标/键盘/滚轮状态路由到正确的 WindowWrapper
static WindowWrapper* targetWrapperForEvent(NSEvent *event, WindowWrapper *fallback) {
    NSWindow *eventWindow = event.window;
    if (!eventWindow && event.windowNumber > 0) {
        eventWindow = [NSApp windowWithWindowNumber:event.windowNumber];
    }
    if (eventWindow) {
        WindowWrapper *target = wrapperForWindow(eventWindow);
        if (target) return target;
    }

    // 鼠标类事件在某些场景下 event.window 可能为空（例如窗口切换瞬间）；
    // 此时按当前鼠标屏幕坐标命中最上层可见窗口，避免误路由到旧 key window。
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
    NSPoint loc = [event locationInWindow];

    MouseMovePacket packet;
    packet.sequence = nextInputEventSequence();
    packet.x = (float)loc.x;
    packet.y = (float)(contentFrame.size.height - loc.y);
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

// 将鼠标按键事件推入目标窗口的事件队列（避免轮询 miss 同帧按下+松开）
static void enqueueMouseButton(WindowWrapper *target, int button, BOOL pressed, NSEvent *event) {
    NSPoint locInWindow = [event locationInWindow];
    NSRect contentFrame = [target.window.contentView frame];
    MouseButtonPacket packet;
    packet.sequence = nextInputEventSequence();
    packet.x = (float)locInWindow.x;
    packet.y = (float)(contentFrame.size.height - locInWindow.y);
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
    if (![wrapper.window isKeyWindow]) return NO;
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

/// 修饰键单独按下/松开时 macOS 派发的是 NSEventTypeFlagsChanged，**不是**
/// keyDown/keyUp。按下与松开是同一个事件类型，靠"该键对应的 flag 位是否
/// 仍然置位"区分。
///
/// 少了这条分支，"按住 ⌘ 时高亮穿透到 group 成员"这类**只依赖修饰键本身**
/// 的交互永远收不到事件（⌘+G 这类组合键不受影响，它们走 keyDown）。
static BOOL flagsChangedPressed(NSEvent *event) {
    unsigned short kc = event.keyCode;
    NSEventModifierFlags flags = event.modifierFlags;
    switch (kc) {
        case 54: case 55: return (flags & NSEventModifierFlagCommand) != 0;   // ⌘ 右/左
        case 56: case 60: return (flags & NSEventModifierFlagShift) != 0;     // ⇧ 左/右
        case 59: case 62: return (flags & NSEventModifierFlagControl) != 0;   // ctrl 左/右
        case 58: case 61: return (flags & NSEventModifierFlagOption) != 0;    // ⌥ 左/右
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

    // ⚠ flagsChanged 事件上访问 `characters` 会抛 NSInternalInconsistencyException。
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

// 轮询事件
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

        // 处理所有待处理的事件
        while (true) {
            // live resize 时切换到 NSEventTrackingRunLoopMode，避免事件丢失
            NSString *mode = (wrapper.window && wrapper.window.inLiveResize) ? NSEventTrackingRunLoopMode : NSDefaultRunLoopMode;
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate distantPast]
                                                   inMode:mode
                                                  dequeue:YES];
            if (!event) break;

            // 确定事件属于哪个窗口
            WindowWrapper *target = targetWrapperForEvent(event, wrapper);

            // 处理键盘事件
            // FlagsChanged 走独立分支：它没有 characters，也不该参与
            // menu keyEquivalent / firstResponder 那套 keyDown 专属逻辑。
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

                // Cmd+Q: 退出应用（主窗口 shouldClose）
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    [key isEqualToString:@"q"]) {
                    wrapper.shouldClose = YES;
                }

                // Shift+Cmd+W: 关闭当前聚焦窗口。
                // 裸 Cmd+W 不拦截，让 key event 传到 Zig 侧由 islandKeyHandler 处理（关当前 tab）。
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    (event.modifierFlags & NSEventModifierFlagShift) != 0 &&
                    [key.lowercaseString isEqualToString:@"w"]) {
                    target.shouldClose = YES;
                    continue;
                }

                // Cmd+`: 同 App 窗口切换
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

                // 菜单快捷键：我们从不调 sendEvent（避免系统警告音），而
                // keyEquivalent 派发恰恰住在 sendEvent 里 —— 不补这一步，
                // 自定义菜单快捷键（如 Cmd+P）永远不触发（verify_menu.sh 逮到）。
                // 菜单消费掉的按键不再进 zig 键队列（与 AppKit 语义一致）。
                const bool has_cmd_or_ctrl = (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
                if (event.type == NSEventTypeKeyDown && has_cmd_or_ctrl) {
                    BOOL menu_ate = [NSApp.mainMenu performKeyEquivalent:event];
                    if (getenv("ZENIT_DEBUG_MENU")) {
                        NSLog(@"[menu-debug] keyEquivalent keyCode=%d chars='%@' ate=%d", event.keyCode, event.charactersIgnoringModifiers, menu_ate);
                    }
                    if (menu_ate) continue;
                }

                // 记录按键事件到目标窗口（队列式，避免高输入速率覆盖）
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

                // 不调用 sendEvent，避免系统警告音
                // 我们自己处理了按键事件
                continue;
            }

            // 跟踪鼠标按钮状态 (路由到目标窗口) + 推入事件队列
            switch (event.type) {
                case NSEventTypeLeftMouseDown: {
                    // 自定义 TitleBar 拖拽：如果点击位置在拖拽区域内，
                    // 直接触发窗口拖拽而不把事件传给 Zig 侧
                    if (target.titlebarDragHeight > 0) {
                        NSRect contentFrame = [target.window.contentView frame];
                        NSPoint loc = [event locationInWindow];
                        float y_from_top = (float)(contentFrame.size.height - loc.y);
                        if (y_from_top < target.titlebarDragHeight && y_from_top >= 0) {
                            float x = (float)loc.x;
                            float w = (float)contentFrame.size.width;
                            // 排除 traffic lights 区域（左侧 78px）、
                            // 窗口边缘 resize 热区（各边 5px，避免拦截系统 resize），
                            // 以及右侧 action buttons 区域（titlebarDragRightInset）。
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
                    // 拖拽时系统只发 Dragged，不发 MouseMoved；两者进入同一
                    // native motion queue，保留相对 key/button/scroll 的顺序。
                    enqueueMouseMove(target, event);
                    break;
                case NSEventTypeScrollWheel:
                    {
                        NSPoint scrollInWindow = [event locationInWindow];
                        NSRect contentFrame = [target.window.contentView frame];
                        ScrollEventPacket packet;
                        packet.sequence = nextInputEventSequence();
                        packet.x = (float)scrollInWindow.x;
                        packet.y = (float)(contentFrame.size.height - scrollInWindow.y);
                        packet.dx = (float)event.scrollingDeltaX;
                        packet.dy = (float)event.scrollingDeltaY;
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
                        NSPoint magInWindow = [event locationInWindow];
                        NSRect magContentFrame = [target.window.contentView frame];
                        MagnifyEventPacket mpacket;
                        mpacket.sequence = nextInputEventSequence();
                        mpacket.x = (float)magInWindow.x;
                        mpacket.y = (float)(magContentFrame.size.height - magInWindow.y);
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

        // [NSApp run] 每处理完一个事件都会 updateWindows —— 它是 AppKit 激活
        // key window 首响应者的 NSTextInputContext、并把 per-context 输入法
        // 绑定挂上的正门。自建事件泵漏掉这一步的后果：开了「为每个 App 使用
        // 不同输入法」(TextInputGlobalPropertyPerContextInput=1) 的机器上，
        // 切到中文输入法后本窗口的 input context 仍旧用旧源，按键以 ASCII
        // 直落（setMarkedText 一次都不来）——「CJK 完全打不进」且时好时坏。
        // 直接 [ic activate] 是私有生命周期，会在 InputMethodKit 里同步卡住，
        // 不能用；updateWindows 是受支持的等价物。
        [NSApp updateWindows];

        // 仅给当前可交互窗口更新鼠标位置，避免后台/被遮挡窗口继续吃 hover
        // 特例: acceptsMouseMovedWhileInactive 时（inspector pick 模式），
        // 即使不是 key window 也更新鼠标位置（用于跨窗口 hover 高亮）
        // 注意: 拖拽时 mouseLocation 已在 switch 里用事件坐标更新，此处直接使用，
        //       不再调用 mouseLocationOutsideOfEventStream（拖拽期间该 API 可能返回旧值）。
        BOOL canAccept = windowCanAcceptPointerInput(wrapper);
        BOOL inactiveHover = !canAccept && wrapper.acceptsMouseMovedWhileInactive
                             && wrapper.window && [NSApp isActive];
        BOOL isDragging = wrapper.leftButtonPressed || wrapper.rightButtonPressed || wrapper.middleButtonPressed;
        if (canAccept || inactiveHover) {
            if (!isDragging) {
                // 非拖拽时用系统 API 查询实时位置（支持无事件时的 hover 更新）
                NSPoint mouseInWindow = [wrapper.window mouseLocationOutsideOfEventStream];
                NSRect contentFrame = [wrapper.window.contentView frame];
                wrapper.mouseLocation = NSMakePoint(mouseInWindow.x,
                                                    contentFrame.size.height - mouseInWindow.y);
            }
            // 拖拽时 mouseLocation 已由 LeftMouseDragged 事件更新，保持不变
            if (inactiveHover) {
                // 非 key window 时不跟踪按钮状态（避免误触）
                wrapper.leftButtonPressed = NO;
                wrapper.rightButtonPressed = NO;
                wrapper.middleButtonPressed = NO;
            }
        } else {
            // 拖拽时（按钮仍按下）保留位置和按钮状态，不清零
            // 拖拽期间 isKeyWindow 可能为 NO，但我们仍需要处理拖拽事件
            if (!isDragging) {
                wrapper.mouseLocation = NSMakePoint(-1, -1);
                wrapper.leftButtonPressed = NO;
                wrapper.rightButtonPressed = NO;
                wrapper.middleButtonPressed = NO;
            }
        }

        // 检查窗口是否已被销毁
        if (!wrapper.window) {
            wrapper.shouldClose = YES;
        }

        return wrapper.shouldClose ? 0 : 1;
    }
#endif
}

// 获取窗口尺寸
void macos_get_window_size(void* window_ptr, int* width, int* height) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) { *width = 0; *height = 0; return; }
        NSRect frame = [wrapper.window.contentView frame];
        *width = (int)frame.size.width;
        *height = (int)frame.size.height;
    }
}

// 设置窗口尺寸（content size，与 macos_get_window_size / 建窗时的
// initWithContentRect: 同一坐标系）。保持窗口中心不动，避免改尺寸时
// 窗口在屏幕上"跳"到别处。
void macos_set_window_size(void* window_ptr, int width, int height) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return;
        if (width <= 0 || height <= 0) return;
        NSWindow *w = wrapper.window;
        NSRect old_frame = w.frame;
        [w setContentSize:NSMakeSize((CGFloat)width, (CGFloat)height)];
        // setContentSize: 锚定左上角；重新居中到原中心点。
        NSRect new_frame = w.frame;
        new_frame.origin.x = old_frame.origin.x + (old_frame.size.width - new_frame.size.width) / 2.0;
        new_frame.origin.y = old_frame.origin.y + (old_frame.size.height - new_frame.size.height) / 2.0;
        [w setFrame:new_frame display:YES];
    }
}

// 获取 DPI 缩放因子 (Retina: 2.0, 普通: 1.0)
double macos_get_scale_factor(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        CGFloat forced = zenitRenderScaleOverride();
        if (forced > 0) return (double)forced;
        if (!wrapper.window) return 2.0;  // 默认 Retina
        CGFloat scale = wrapper.window.backingScaleFactor;
        return (double)scale;
    }
}

// 获取 drawable 尺寸 (考虑 retina 缩放)
void macos_get_drawable_size(void* view_ptr, int* width, int* height) {
    @autoreleasepool {
        MetalView *view = (__bridge MetalView*)view_ptr;
        // 直接用 view bounds * scale，避免 live resize 期间 drawableSize 不更新
        CGSize size = view.bounds.size;
        CGFloat scale = zenitRenderScaleOverride();
        if (scale <= 0) scale = view.window ? view.window.backingScaleFactor : [[NSScreen mainScreen] backingScaleFactor];
        *width = (int)(size.width * scale);
        *height = (int)(size.height * scale);
    }
}

// 获取鼠标位置（逻辑像素，相对于窗口内容，Y 轴向下）
void macos_get_mouse_position(void* window_ptr, float* x, float* y) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        *x = (float)wrapper.mouseLocation.x;
        *y = (float)wrapper.mouseLocation.y;
    }
}

// 获取原生 mouse moved/dragged 事件（队列式，每次消费一个）。
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

// 设置鼠标光标形状
// shape 值与 Zig CursorShape 枚举一致:
// 0=inherit(noop), 1=default, 2=pointer, 3=text, 4=crosshair,
// 5=move, 6=not_allowed, 7=grab, 8=grabbing,
// 9=ew_resize, 10=ns_resize, 11=nwse_resize, 12=nesw_resize,
// 13=col_resize, 14=row_resize, 15=wait, 16=progress,
// 17=help, 18=none
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
            case 5:  // move — macOS 无直接对应，用 openHand
            case 7:  cursor = [NSCursor openHandCursor]; break;
            case 6:  cursor = [NSCursor operationNotAllowedCursor]; break;
            case 8:  cursor = [NSCursor closedHandCursor]; break;
            case 9:  cursor = [NSCursor resizeLeftRightCursor]; break;
            case 10: cursor = [NSCursor resizeUpDownCursor]; break;
            case 11: // nwse_resize — macOS 无直接 API，用 arrow
            case 12: // nesw_resize
                     cursor = [NSCursor arrowCursor]; break;
            case 13: cursor = [NSCursor resizeLeftRightCursor]; break;  // col_resize
            case 14: cursor = [NSCursor resizeUpDownCursor]; break;     // row_resize
            case 15: // wait — 使用系统忙碌光标 (私有 API 不可用，fallback arrow)
            case 16: // progress
                     cursor = [NSCursor arrowCursor]; break;
            case 17: cursor = [NSCursor arrowCursor]; break; // help (macOS 无 help cursor)
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

// 自定义位图光标：预乘 RGBA8 → NSCursor(image + hotSpot)。
// key 为调用方的内容寻址键：同一位图同键，进程级缓存 NSCursor 对象，
// 高频 set 只做字典查找不重解码。rgba 调用期借用（CGImage 创建时即拷贝）。
// hot_x/hot_y 为左上原点像素坐标；NSCursor hotSpot 同为左上原点（Apple 文档：
// y 自图像顶边起算），故只需 /scale 换成 points，**不能翻转 y**。曾经写成
// `size_h - hot_y/scale`，让热点沿图像中线镜像：笔尖(y=21.8)的热点跑到顶部、
// 节点箭头尖(y=4.7)的热点跑到底部，两支光标都指不准；剪刀(y=12=中线)恰好
// 是翻转不动点，所以唯独它看起来正常——这正是定位该 bug 的反证。
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

// 检查鼠标按钮状态
// button: 0=left, 1=right, 2=middle
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

// 获取按键事件
// 返回: 1 如果有按键事件，0 如果没有
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

// 获取滚轮事件
// 返回: 1 如果有滚轮事件，0 如果没有
// phase: zenitScrollPhaseCode; momentum: zenitMomentumPhaseCode
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

// 获取触控板捏合（magnify）事件
// magnification 是相对增量：new_scale = old_scale * (1 + magnification)
// phase: 0=began 1=changed 2=ended 3=cancelled
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

// 获取拖放事件（队列式，每次消费一个）
// A peek lends immutable bytes until the matching queue head is consumed.
// The token is opaque identity, compared only while the queue owns the packet.
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

// 获取鼠标按键事件（队列式，每次消费一个）
// 返回: 1 如果有事件，0 如果没有
// button: 0=left, 1=right, 2=middle
// pressed: 1=按下, 0=释放
/// `modifiers` 可为 NULL（旧调用方）；非 NULL 时写回原始 NSEventModifierFlags。
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

// 查询窗口是否应该关闭（不消费事件）
int macos_should_close(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return wrapper.shouldClose ? 1 : 0;
    }
}

// 更新窗口鼠标位置（给非 key window 用）
void macos_update_mouse_position(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return;
        NSPoint mouseInWindow = [wrapper.window mouseLocationOutsideOfEventStream];
        NSRect contentFrame = [wrapper.window.contentView frame];
        wrapper.mouseLocation = NSMakePoint(mouseInWindow.x,
                                            contentFrame.size.height - mouseInWindow.y);
    }
}

// 检查窗口是否需要 GPU present（可见且未被完全遮挡）
int macos_should_render_window(void* window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return 0;
        if (zenitBackgroundE2E()) return 1; // RPC screenshots still need GPU frames while occluded.
        if (!wrapper.window.isVisible) return 0;
        if ((wrapper.window.occlusionState & NSWindowOcclusionStateVisible) == 0) return 0;
        return 1;
    }
}

// 设置非活跃窗口是否接受鼠标移动（inspector pick 模式跨窗口 hover）
void macos_set_accepts_mouse_while_inactive(void* window_ptr, int accepts) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.acceptsMouseMovedWhileInactive = (accepts != 0);
    }
}

// 销毁窗口
// 获取系统标题栏高度（traffic lights 所在区域高度）
/// 系统里有没有能打开这个文件的应用(Launch Services 判据)。
///
/// 宿主用它区分两种失败:「没装编辑器」(该提示用户去安装)与「装了但起不来」
/// (磁盘/权限/沙箱)。**不能靠 `open(1)` 的返回值判断** —— `open` 只负责把
/// 请求投递给 Launch Services,即使没有任何 handler 它通常也返回成功,
/// 于是"双击没反应"会变成静默失败。
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
        // contentLayoutRect 是排除标题栏后的内容区域
        // 窗口总高度 - contentLayoutRect 高度 = 标题栏高度
        CGFloat content_height = window.contentLayoutRect.size.height;
        CGFloat frame_height = [window.contentView frame].size.height;
        return (float)(frame_height - content_height);
    }
}

// 开始窗口拖拽（TitleBar 自定义拖拽区域调用）
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

// 设置 traffic lights (红黄绿按钮) 在自绘标题栏中的垂直居中位置
// inset_y: 按钮中心距离窗口顶部的距离（逻辑像素）
void macos_set_traffic_lights_inset(void* window_ptr, float inset_x, float inset_y) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.hasTrafficLightsInset = YES;
        wrapper.trafficLightsInsetX = inset_x;
        wrapper.trafficLightsInsetY = inset_y;
        [wrapper applyTrafficLightsInset];
    }
}

// 注册命中驱动拖拽区回调（NULL 清除，退回纯矩形模型）
void macos_set_titlebar_hit_callback(void* window_ptr, int (*cb)(void* ctx, float x, float y), void* ctx) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.titlebarHitCallback = cb;
        wrapper.titlebarHitContext = ctx;
    }
}

// 设置自定义 TitleBar 拖拽区域高度
void macos_set_titlebar_drag_height(void* window_ptr, float height) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.titlebarDragHeight = height;
    }
}

// 设置 TitleBar 右侧排除拖拽区域宽度（给 action buttons 让出点击区）
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
        // 先停并释放 display link：CVDisplayLinkStop 同步等待回调线程退出，
        // 防止销毁后回调经悬垂 wrapper 指针 post 事件
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

// ========== 多窗口架构 API ==========

// 纯事件泵：拉取所有 NSApp 事件，分发到各 WindowWrapper
// 不绑定任何特定窗口，由各窗口独立调用 macos_update_window_mouse 更新鼠标
static void pumpAppEventsWithTimeout(uint32_t timeout_ms) {
    @autoreleasepool {
        g_text_input_wake_posted = NO;
        atomic_store(&g_display_link_wake_pending, false);
        // First-responder assignment is the supported input-context activation
        // boundary. Never force activate/deactivate from the event pump.
        static BOOL didForceActivate = NO;
        if (!didForceActivate) {
            didForceActivate = YES;
            zenitActivateApplication();
            // 找到第一个注册的窗口建立 responder 链。
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
            // 检查是否有任何窗口在 live resize 中
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

            // 找到 fallback wrapper（key window 或第一个窗口）
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

            // 键盘事件处理
            // FlagsChanged 走独立分支：它没有 characters，也不该参与
            // menu keyEquivalent / firstResponder 那套 keyDown 专属逻辑。
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

                // Cmd+Q: 全局退出
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    [key isEqualToString:@"q"]) {
                    g_app_should_quit = YES;
                }

                // Shift+Cmd+W: 关闭目标窗口。
                // 裸 Cmd+W 不拦截，让 key event 传到 Zig 侧处理（关当前 tab）。
                if (event.type == NSEventTypeKeyDown && isCmd &&
                    (event.modifierFlags & NSEventModifierFlagShift) != 0 &&
                    [key.lowercaseString isEqualToString:@"w"]) {
                    target.shouldClose = YES;
                    [NSApp updateWindows];
                    break;
                }

                // Cmd+`: 窗口切换
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

                // 菜单快捷键：本循环从不调 sendEvent，而 keyEquivalent 派发
                // 恰恰住在 sendEvent 里 —— 不补这一步，自定义菜单快捷键永远
                // 不触发（verify_menu.sh 逮到；macos_poll_events 的旧循环同款）。
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

                // 记录按键事件到目标窗口（队列式，避免高输入速率覆盖）
                enqueueKeyEvent(target, event);

                // IME 处理
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

            // 鼠标/滚轮事件处理（路由到目标窗口）
            switch (event.type) {
                case NSEventTypeLeftMouseDown: {
                    if (target.titlebarDragHeight > 0) {
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
                        NSPoint scrollInWindow = [event locationInWindow];
                        NSRect contentFrame = [target.window.contentView frame];
                        ScrollEventPacket packet;
                        packet.sequence = nextInputEventSequence();
                        packet.x = (float)scrollInWindow.x;
                        packet.y = (float)(contentFrame.size.height - scrollInWindow.y);
                        packet.dx = (float)event.scrollingDeltaX;
                        packet.dy = (float)event.scrollingDeltaY;
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
                        NSPoint magInWindow = [event locationInWindow];
                        NSRect magContentFrame = [target.window.contentView frame];
                        MagnifyEventPacket mpacket;
                        mpacket.sequence = nextInputEventSequence();
                        mpacket.x = (float)magInWindow.x;
                        mpacket.y = (float)(magContentFrame.size.height - magInWindow.y);
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

        // 同 macos_poll_events：补上 [NSApp run] 的 updateWindows 职责，
        // 否则 NSTextInputContext 激活/per-context 输入法绑定不生效。
        [NSApp updateWindows];

        // 非阻塞泵（timeout 0：有窗口要帧 / test_mode）下 nextEventMatchingMask
        // 用 distantPast 只摘事件，run loop **一趟都不跑**：主队列之外的 run loop
        // 源、观察者（AVFoundation 的 AVPlayerItem 准备、NSURLSession 回调、
        // 通知投递……）全部饿死 —— 应用连续渲染期间视频永远 loading（下游编辑器
        // 第152轮：e2e media_viewer T3 15s 内 item.status 恒 Unknown，独立探针里
        // 同一份代码 3 次迭代就绪）。这里补一趟零等待的 run loop pass：不睡、不等，
        // 只把已就绪的源/观察者跑掉；放在事件批次之后，保持「先事件后回调」的顺序。
        // mode 与批次内 nextEvent 一致：live resize 期间是 NSEventTrackingRunLoopMode
        //（交叉审查坐实：固定 default mode 会让 tracking-only 源在 resize 中继续饿死）。
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

// 检查全局退出标志
int macos_should_quit(void) {
    return g_app_should_quit ? 1 : 0;
}

// 消费"app 变为前台"标志：返回 1 且重置为 NO（下次激活前不会再返回 1）
int macos_consume_app_became_active(void) {
    if (g_app_became_active) {
        g_app_became_active = NO;
        return 1;
    }
    return 0;
}

// 查询当前系统是否为暗色模式
// 每次 pump 都会被 collectGlobalEvents 调到，且在主循环 pool 之外也可能被调，
// effectiveAppearance 返回 autoreleased 的 NSCompositeAppearance —— 自带 pool。
int macos_is_dark_mode(void) {
    @autoreleasepool {
        NSAppearanceName appearance = [[NSApp effectiveAppearance] bestMatchFromAppearancesWithNames:@[
            NSAppearanceNameAqua,
            NSAppearanceNameDarkAqua
        ]];
        return [appearance isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
    }
}

// 检查窗口是否请求关闭（不消费）
int macos_check_window_should_close(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        return wrapper.shouldClose ? 1 : 0;
    }
}

// 重置窗口关闭请求标志
void macos_reset_window_should_close(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        wrapper.shouldClose = NO;
    }
}

// Per-window 鼠标位置更新（从 macos_poll_events 末尾提取）
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

// 当前硬件修饰键状态（进程级，非某次事件的快照）。轮询式 mouse_move
// 没有对应 NSEvent 可取 flags，用它给移动事件补真实修饰键。
uint32_t macos_current_modifier_flags(void) {
    return (uint32_t)[NSEvent modifierFlags];
}

int macos_is_window_focused(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper*)window_ptr;
        if (!wrapper.window) return 0;
        if (zenitBackgroundE2E()) return wrapper.window.windowNumber == g_requested_key_window;
        if (wrapper.window.isKeyWindow) return 1;
        // 应用不在前台时没有 key window：以"最近被要求成为 key 的窗口"为焦点窗口，
        // 多窗口 e2e / 快捷键路由才不会在用户切去别的 app 时退化成"第一个窗口"。
        if (![NSApp isActive]) {
            NSWindow *req = macos_find_window_by_number(g_requested_key_window);
            if (req) return req == wrapper.window ? 1 : 0;
            return wrapper.window.isMainWindow ? 1 : 0;
        }
        return 0;
    }
}

// 初始化 Cocoa 应用（无菜单栏，开发模式兼容）
void macos_init_app(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:zenitBackgroundE2E() ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        zenitActivateApplication();
        NSLog(@"[macos_init_app] Cocoa application initialized");
    }
}

// ========== ZenitAppDelegate + 菜单栏 ==========

@interface ZenitAppDelegate : NSObject <NSApplicationDelegate>
@end

static ZenitAppDelegate *g_app_delegate = nil;

// 全局 pending open file 路径（Finder 双击 / open -a / 拖到 Dock 图标）
static NSMutableArray<NSString *> *g_pending_open_files = nil;

// 前置声明：定义在下方菜单 API 段（static 重复声明是合法的 tentative definition）
static NSMutableDictionary<NSNumber *, NSMenu *> *zenitMenuById;

@implementation ZenitAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // setMenuModel 可能在 finishLaunching 之前就被应用调用（zenitMenuById
    // 非空即是）。此前无条件 setupMenuBar 会把自定义主菜单静默整个覆盖 ——
    // launch 前设置的菜单凭空消失且无任何报错（verify_menu.sh 逮到）。
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
    // App 从后台切换到前台：标记需重绘，Zig 侧下一帧 pump 时消费
    g_app_became_active = YES;
    NSLog(@"[ZenitAppDelegate] applicationDidBecomeActive");
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    // Zig owns process lifetime and tears down GPU/UI resources only after each
    // NSWindow has completed its AppKit close transaction.
    return NO;
}

// Finder 双击 / "打开方式" / open -a / 拖到 Dock 图标
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

    // === Zenit 菜单（应用菜单）===
    {
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Zenit"];

        [appMenu addItemWithTitle:@"About Zenit"
                           action:@selector(orderFrontStandardAboutPanel:)
                    keyEquivalent:@""];

        [appMenu addItem:[NSMenuItem separatorItem]];

        // 安装命令行启动器。放在 About 之后、Hide 之前 —— 与 VSCode
        // (Shell Command: Install 'code') / Zed (Install CLI) 的位置一致，
        // 用户在应用菜单里找这类"一次性设置"是既有习惯。
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

    // === File 菜单 ===
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

        // Open Recent → (子菜单占位)
        NSMenuItem *openRecentItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent"
                                                                action:nil
                                                         keyEquivalent:@""];
        NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
        // TODO: 动态填充最近文件列表
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

    // === Edit 菜单 ===
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

    // === Window 菜单 ===
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

    // === Help 菜单 ===
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

// MetalView 菜单 action 方法 — 将 Edit 菜单操作转发为按键事件
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

// ===== File 菜单 actions =====

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

// Install Command Line Tool
// 不绑窗口：装 CLI 是进程级的一次性设置，没有 key window 时（比如只剩
// Welcome 窗口、或全部窗口最小化）也该能点。用 pushMenuActionForWindow(…, 0)
// 而不是 pushMenuAction()，后者会在没有 key window 时把 window_id 填 0 之外
// 还让 Zig 侧按"目标窗口找不到"提前 return。
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

// 获取下一个待处理的菜单动作（0 = 无）
int macos_get_menu_action(void) {
    return (int)popMenuAction();
}

// 初始化 Cocoa 应用 + AppDelegate + 菜单栏
void macos_init_app_with_delegate(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:zenitBackgroundE2E() ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular];

        // 创建并设置 delegate
        g_app_delegate = [[ZenitAppDelegate alloc] init];
        [NSApp setDelegate:g_app_delegate];

        // 立即设置菜单栏（不等 applicationDidFinishLaunching，因为我们不走 [NSApp run]）
        [g_app_delegate setupMenuBar];

        [NSApp finishLaunching];
        zenitActivateApplication();
        NSLog(@"[macos_init_app_with_delegate] Cocoa application initialized with delegate + menu bar");
    }
}

void macos_show_blocking_alert(const char *title, const char *message) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:zenitBackgroundE2E() ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular];
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

// ========== 剪贴板 API ==========

// 返回码：1 = 写入成功；0 = setString 拒绝；-1 = 文本不是合法 UTF-8。
//
// 曾经这个函数返回 void，且顺序是「先 clearContents 再构造 NSString」：
//   - str 为 nil（非法 UTF-8）时，用户的旧剪贴板**已经被清空**，新内容却没进去
//     —— 先毁旧状态再做可失败操作，失败即不可恢复；
//   - setString: 的 BOOL 被整个丢弃，调用方一路收到"成功"。
// 两条合起来的症状是"复制静默失效"：changeCount 涨了（clearContents 生效），
// 内容却还是上一次的。
int macos_clipboard_set_text(const char* text, int len) {
    @autoreleasepool {
        // 先构造再清空：构造失败就原样保留用户的剪贴板，不做任何破坏。
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
    uint64_t windowId = keyWindow ? (uint64_t)(NSInteger)keyWindow.windowNumber : 0;
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
    if (![NSThread isMainThread]) return 0;
    zenitMenuById = [NSMutableDictionary dictionary];
    if (!zenitPendingMenuCommands) zenitPendingMenuCommands = [NSMutableArray array];
    if (!zenitMenuTarget) zenitMenuTarget = [[ZenitMenuCommandTarget alloc] init];
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
    [NSApp setMainMenu:main];
    return 1;
}

int macos_menu_add_menu(uint64_t menu_id, uint64_t parent_id, const char *label, size_t label_len) {
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

int macos_menu_add_separator(uint64_t parent_id) {
    if (![NSThread isMainThread]) return 0;
    NSMenu *parent = zenitMenuById[@(parent_id)];
    if (!parent) return 0;
    [parent addItem:[NSMenuItem separatorItem]];
    return 1;
}

int macos_menu_add_item(uint64_t item_id, uint64_t parent_id,
                        const char *label, size_t label_len,
                        const char *key, size_t key_len,
                        uint8_t modifiers, uint8_t role, uint64_t command_id,
                        int enabled, int checked) {
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

int macos_menu_commit(void) {
    if (![NSThread isMainThread] || !NSApp.mainMenu) return 0;
    [NSApp.mainMenu update];
    return 1;
}

static BOOL zenitHasPendingMenuCommands(void) {
    return zenitPendingMenuCommands.count > 0 || g_menu_actions.count > 0;
}

void macos_menu_discard_window_commands(uint64_t window_id) {
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

int macos_menu_poll_command(uint64_t *out_window_id, uint64_t *out_command_id) {
    if (![NSThread isMainThread] || !out_window_id || !out_command_id || zenitPendingMenuCommands.count == 0) return 0;
    NSDictionary *packet = zenitPendingMenuCommands.firstObject;
    [zenitPendingMenuCommands removeObjectAtIndex:0];
    *out_window_id = [packet[@"windowId"] unsignedLongLongValue];
    *out_command_id = [packet[@"commandId"] unsignedLongLongValue];
    return 1;
}

// ========== 文件对话框 API ==========

int macos_pick_folder(char* path_buffer, int buffer_size) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        panel.title = @"Open Folder";
        panel.prompt = @"Open";

        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK) return 0;  // 用户取消

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

// 弹出 NSOpenPanel 选择文件（返回路径长度，0=取消，-1=错误）
int macos_open_file_panel(char* path_buffer, int buffer_size) {
    @autoreleasepool {

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.title = @"Open File";
        panel.prompt = @"Open";
        // 不设置 allowedContentTypes — 允许所有文件类型

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

// 弹出 NSOpenPanel 选择图片文件（返回路径长度，0=取消，-1=错误）
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
        if (response != NSModalResponseOK) return 0;  // 用户取消

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

// Metal 渲染辅助函数

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

void* metal_drawable_get_texture(void* drawable_ptr) {
    @autoreleasepool {
        id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)drawable_ptr;
        return (__bridge void*)drawable.texture;
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
        [commandBuffer presentDrawable:drawable];
    }
}

void metal_commit_command_buffer(void* command_buffer_ptr) {
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge_transfer id<MTLCommandBuffer>)command_buffer_ptr;
        [commandBuffer commit];
    }
}

/// 返回当前 key window 的 CGWindowID（供 screencapture -l 使用）
/// 无窗口时返回 0
// 某个具体窗口的 id（= NSWindow.windowNumber）。zig 侧 App 用它设 Cx.window_id，
// 让 a11y / 系统 API 路由到本窗口而不是"第一个窗口"。
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
        // 应用不在前台时 keyWindow 为 nil：先退到最近被要求成为 key 的窗口，再退到 mainWindow，再退到第一个窗口
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

/// 向 NSApp 事件队列 post 一个空事件，唤醒 runloop
/// 用于动画帧：当 needs_redraw=true 但没有外部事件时，保证下一帧 pumpAppEvents 不会空等
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

/// CVDisplayLink vsync 回调（运行在专用高优先级线程）
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
    (void)inOutputTime;
    (void)flagsIn;
    (void)flagsOut;
    (void)displayLinkContext;
    // 在 vsync 时刻唤醒主线程渲染；上一个唤醒还没被 pump 取走就不再叠加。
    if (!atomic_exchange(&g_display_link_wake_pending, true)) {
        macos_post_empty_event();
    }
    return kCVReturnSuccess;
}

/// 启动 CVDisplayLink — 动画活跃时调用
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

/// 停止 CVDisplayLink — 无动画时调用（节省 CPU）
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

/// 获取屏幕刷新率（Hz）
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
