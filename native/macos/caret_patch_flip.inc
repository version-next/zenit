// GPU-populated opaque scene patches. Every function runs on the owning UI thread.
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
extern int metal_command_buffer_copy_texture_region_render(void *, void *, unsigned int, unsigned int, unsigned int, unsigned int, void *, unsigned int, unsigned int, int);
static char zenitCaretPatchesKey;
static char zenitCaretTextureKey;
static char zenitCaretPixelRectKey;

// App owns one host reference from successful admission through replacement
// completion/close, even if the window installs a different body surface.
void *macos_caret_patch_host_retain(void *layer_ptr) {
    return (__bridge_retained void *)(__bridge CALayer *)layer_ptr;
}
void macos_caret_patch_host_release(void *layer_ptr) {
    (void)CFBridgingRelease(layer_ptr);
}

void macos_caret_patch_clear(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *patch in objc_getAssociatedObject(host, &zenitCaretPatchesKey)) {
        patch.contents = nil;
        objc_setAssociatedObject(patch, &zenitCaretTextureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [patch removeFromSuperlayer];
    }
    objc_setAssociatedObject(host, &zenitCaretPatchesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction commit];
}

int macos_caret_patch_encode(void *layer_ptr, void *texture_ptr, void *command_ptr,
                            const float (*rects)[4], size_t count, float scale) {
    @autoreleasepool {
        CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
        id<MTLTexture> source = (__bridge id<MTLTexture>)texture_ptr;
        id<MTLCommandBuffer> command = (__bridge id<MTLCommandBuffer>)command_ptr;
        macos_caret_patch_clear(layer_ptr);
        if (!count || count > 64 || scale <= 0 || source.pixelFormat != MTLPixelFormatBGRA8Unorm) return 0;
        NSMutableArray<CALayer *> *patches = [NSMutableArray array];
        // Preserve overlay ordering. Negative child depth is an unsupported host,
        // rather than risking a patch behind the body or above an existing overlay.
        for (CALayer *child in host.sublayers) if (child.zPosition < 0) return 0;
        CGColorSpaceRef space = host.colorspace;
        CGColorSpaceRef fallback = space ? NULL : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        id colorSpec = CFBridgingRelease(CGColorSpaceCopyPropertyList(space ?: fallback));
        if (fallback) CGColorSpaceRelease(fallback);
        if (!colorSpec) return 0;
        BOOL ok = YES;
        size_t totalPixels = 0;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        for (size_t i = 0; i < count; i++) {
            // Fragment derivatives run in 2x2 pixel quads. Keep the crop on
            // the original attachment's quad lattice, including rounded carets.
            long x = MAX(0, (long)floor(rects[i][0] * scale) - 2) & ~1L;
            long y = MAX(0, (long)floor(rects[i][1] * scale) - 2) & ~1L;
            long right = MIN((long)source.width, ((long)ceil((rects[i][0] + rects[i][2]) * scale) + 3) & ~1L);
            long bottom = MIN((long)source.height, ((long)ceil((rects[i][1] + rects[i][3]) * scale) + 3) & ~1L);
            if (right <= x || bottom <= y) continue;
            size_t w = right - x, h = bottom - y;
            totalPixels += w * h;
            if (totalPixels > 1024 * 1024) { ok = NO; break; }
            size_t rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4);
            NSDictionary *properties = @{
                (__bridge NSString *)kIOSurfaceWidth: @(w),
                (__bridge NSString *)kIOSurfaceHeight: @(h),
                (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
                (__bridge NSString *)kIOSurfaceBytesPerRow: @(rowBytes),
                (__bridge NSString *)kIOSurfaceAllocSize: @(IOSurfaceAlignProperty(kIOSurfaceAllocSize, rowBytes * h)),
                (__bridge NSString *)kIOSurfacePixelFormat: @((uint32_t)'BGRA')
            };
            IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
            if (!surface) { ok = NO; break; }
            // IOSurface color metadata is consumed by CA; memcpy readback cannot validate it.
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, (__bridge CFTypeRef)colorSpec);
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat width:w height:h mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            id<MTLTexture> patchTexture = [host.device newTextureWithDescriptor:desc iosurface:surface plane:0];
            if (!patchTexture) { CFRelease(surface); ok = NO; break; }
            if (!metal_command_buffer_copy_texture_region_render(command_ptr, texture_ptr,
                    (unsigned)x, (unsigned)y, (unsigned)w, (unsigned)h,
                    (__bridge void *)patchTexture, 0, 0, 0)) {
                CFRelease(surface); ok = NO; break;
            }
            CALayer *patch = [CALayer layer];
            patch.name = @"zenit.caret.patch";
            patch.contentsScale = scale;
            patch.contentsGravity = kCAGravityResize;
            patch.magnificationFilter = kCAFilterNearest;
            patch.minificationFilter = kCAFilterNearest;
            patch.opaque = YES;
            patch.hidden = YES;
            patch.frame = CGRectMake(x / scale, (host.geometryFlipped ? y : (long)source.height - bottom) / scale, w / scale, h / scale);
            patch.contentsFormat = kCAContentsFormatRGBA8Uint;
            patch.zPosition = 0;
            patch.contents = (__bridge id)surface;
            objc_setAssociatedObject(patch, &zenitCaretTextureKey, patchTexture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(patch, &zenitCaretPixelRectKey, [NSValue valueWithRect:NSMakeRect(x,y,w,h)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CFRelease(surface);
            [host insertSublayer:patch atIndex:0];
            [patches addObject:patch];
        }
        objc_setAssociatedObject(host, &zenitCaretPatchesKey, patches, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction commit];
        if (!ok || !patches.count) { macos_caret_patch_clear(layer_ptr); return 0; }
        return 1;
    }
}

// Borrow the small background-initialized render target; the owning patch keeps
// it alive until handoff/close. Geometry is in the body's actual pixel grid.
void *macos_caret_patch_target(void *layer_ptr, unsigned index, unsigned (*rect)[4]) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    NSArray<CALayer *> *patches = objc_getAssociatedObject(host, &zenitCaretPatchesKey);
    if (index >= patches.count) return NULL;
    CALayer *patch = patches[index];
    id<MTLTexture> texture = objc_getAssociatedObject(patch, &zenitCaretTextureKey);
    if (!texture) return NULL;
    NSRect pixels = [objc_getAssociatedObject(patch, &zenitCaretPixelRectKey) rectValue];
    (*rect)[0] = (unsigned)pixels.origin.x;
    (*rect)[1] = (unsigned)pixels.origin.y;
    (*rect)[2] = (unsigned)texture.width;
    (*rect)[3] = (unsigned)texture.height;
    return (__bridge void *)texture;
}

void macos_caret_patch_show(void *layer_ptr, int visible) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *patch in objc_getAssociatedObject(host, &zenitCaretPatchesKey))
        patch.hidden = !visible;
    [CATransaction commit];
}

// Publish drawable and patch visibility in one CA transaction. Preserve the host policy.
static char zenitCaretPresentPolicyKey;
void macos_caret_handoff_begin(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    // Drain the preceding ordinary presentation before retaining a new body
    // drawable in the explicit caret transaction.
    [CATransaction flush];
    objc_setAssociatedObject(host, &zenitCaretPresentPolicyKey, @(host.presentsWithTransaction), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    host.presentsWithTransaction = YES;
}
void macos_caret_handoff_end(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    host.presentsWithTransaction = [objc_getAssociatedObject(host, &zenitCaretPresentPolicyKey) boolValue];
    objc_setAssociatedObject(host, &zenitCaretPresentPolicyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction commit];
    [CATransaction flush];
}

// Harness-only compositor readback: uses the actual CALayer frames/hidden flags/contents.
// No GPU command is encoded; hidden baseline is a CPU-readable retained texture.
int macos_caret_patch_composite(void *layer_ptr, unsigned char *bgra, unsigned width, unsigned height, float scale) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    NSArray<CALayer *> *patches = objc_getAssociatedObject(host, &zenitCaretPatchesKey);
    if (!patches.count || scale <= 0) return 0;
    for (CALayer *patch in patches) {
        if (patch.hidden) continue;
        IOSurfaceRef surface = (__bridge IOSurfaceRef)patch.contents;
        long x = lround(patch.frame.origin.x * scale);
        long y = lround(host.geometryFlipped ? patch.frame.origin.y * scale : height - CGRectGetMaxY(patch.frame) * scale);
        size_t w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface);
        if (x < 0 || y < 0 || x + w > width || y + h > height) return 0;
        if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return 0;
        const unsigned char *pixels = IOSurfaceGetBaseAddress(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface);
        if (!pixels) { IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL); return 0; }
        for (size_t row = 0; row < h; row++)
            memcpy(bgra + ((y + row) * width + x) * 4, pixels + row * stride, w * 4);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    return 1;
}

static uint64_t zenitCaretColorSignature(CGColorSpaceRef space) {
    if (!space) return 0;
    uint64_t hash = 1469598103934665603ULL;
    CFDataRef profile = CGColorSpaceCopyICCData(space);
    if (profile) {
        const UInt8 *bytes = CFDataGetBytePtr(profile);
        for (CFIndex i = 0; i < CFDataGetLength(profile); i++) hash = (hash ^ bytes[i]) * 1099511628211ULL;
        CFRelease(profile);
    }
    CFStringRef name = CGColorSpaceGetName(space);
    return hash ^ (name ? CFHash(name) : 0) ^ CGColorSpaceGetModel(space);
}

// AppKit can slide/reparent the titlebar without a client resize event. Read
// both model and presentation geometry; no patch is admitted during animation.
static BOOL zenitCaretLayerMoving(CALayer *layer) {
    for (; layer; layer = layer.superlayer) {
        CALayer *presented = layer.presentationLayer;
        BOOL moving = layer.animationKeys.count || (presented && (!CGRectEqualToRect(layer.bounds, presented.bounds) ||
            !CGPointEqualToPoint(layer.position, presented.position) ||
            !CATransform3DEqualToTransform(layer.transform, presented.transform) ||
            layer.opacity != presented.opacity || layer.hidden != presented.hidden));
        if (moving) {
            return YES;
        }
    }
    return NO;
}

int macos_caret_native_ready(void *window_ptr) {
    WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
    unsigned reason = (!wrapper.metalView.layer ? 1 : 0) | (wrapper.chromeFullscreenTransition ? 2 : 0) |
        (wrapper.fullscreenHeader.pendingFullscreen ? 4 : 0) | (wrapper.fullscreenHeader.exiting ? 8 : 0) |
        (wrapper.window.visible && !zenitWindowOnActiveSpace(wrapper) ? 16 : 0) |
        (zenitCaretLayerMoving(wrapper.metalView.layer) ? 32 : 0) |
        (zenitCaretLayerMoving(wrapper.fullscreenHeader.header.layer) ? 64 : 0);
    static unsigned logged = ~0u;
    if (getenv("ZENIT_CARET_FLIP_DEBUG") && logged != reason) {
        logged = reason; fprintf(stderr,"[caret-native] window=%ld blockers=0x%x\n",(long)wrapper.window.windowNumber,reason);
    }
    return reason == 0;
}

uint64_t macos_caret_native_signature(void *window_ptr) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
        NSWindow *window = wrapper.window;
        CAMetalLayer *layer = (CAMetalLayer *)wrapper.metalView.layer;
        NSScreen *screen = window.screen;
        NSView *header = wrapper.fullscreenHeader.header;
        NSRect headerScreen = header.window ? [header.window convertRectToScreen:[header convertRect:header.bounds toView:nil]] : NSZeroRect;
        NSRect headerVisible = header ? header.visibleRect : NSZeroRect;
        uint64_t values[] = { (uint64_t)window.occlusionState, window.keyWindow, window.visible,
            wrapper.chromeStateGeneration, (uint64_t)llround(window.backingScaleFactor * 1024),
            (uint64_t)llround(wrapper.metalView.bounds.size.width * 1024),
            (uint64_t)llround(wrapper.metalView.bounds.size.height * 1024),
            (uintptr_t)screen, zenitCaretColorSignature(screen.colorSpace.CGColorSpace),
            zenitCaretColorSignature(layer.colorspace), window.effectiveAppearance.name.hash,
            NSApp.effectiveAppearance.name.hash, wrapper.chromeFullscreenTransition,
            zenitWindowOnActiveSpace(wrapper), (uintptr_t)layer, (uintptr_t)layer.superlayer,
            (uint64_t)llround(layer.drawableSize.width), (uint64_t)llround(layer.drawableSize.height),
            (uint64_t)llround(layer.contentsScale * 1024), (uintptr_t)header, (uintptr_t)header.window,
            header.hiddenOrHasHiddenAncestor, header.layer.hidden,
            (uint64_t)llround(header.layer.opacity*1024), (uintptr_t)header.layer,
            (uintptr_t)header.layer.superlayer,
            wrapper.fullscreenHeader.presentationEpoch, wrapper.fullscreenHeader.active,
            wrapper.fullscreenHeader.exiting, wrapper.fullscreenHeader.pendingFullscreen };
        uint64_t signature = 1469598103934665603ULL;
        for (size_t i = 0; i < sizeof(values)/sizeof(values[0]); i++) signature = (signature ^ values[i]) * 1099511628211ULL;
        // Quantize subpixel AppKit geometry exactly as the other native inputs.
        CGFloat geometry[] = { window.frame.origin.x, window.frame.origin.y,
            layer.bounds.origin.x, layer.bounds.origin.y, layer.bounds.size.width, layer.bounds.size.height,
            layer.position.x, layer.position.y, headerScreen.origin.x, headerScreen.origin.y,
            headerScreen.size.width, headerScreen.size.height, headerVisible.origin.x, headerVisible.origin.y,
            headerVisible.size.width, headerVisible.size.height };
        for (size_t i = 0; i < sizeof(geometry)/sizeof(geometry[0]); i++) signature = (signature ^ (uint64_t)llround(geometry[i]*1024)) * 1099511628211ULL;
        return signature;
    }
}

// Read-only observability for test-mode consumers; it does not repaint or submit.
unsigned macos_caret_patch_count(void *layer_ptr) {
    return (unsigned)[objc_getAssociatedObject((__bridge id)layer_ptr, &zenitCaretPatchesKey) count];
}

// Opt-in diagnostic identity only: no object is retained beyond this call.
void macos_caret_drawable_info(void *layer_ptr, void *drawable_ptr, uint64_t *out) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)drawable_ptr;
    id<MTLTexture> texture = drawable.texture;
    IOSurfaceRef surface = texture.iosurface;
    out[0] = surface ? IOSurfaceGetID(surface) : 0;
    out[1] = (uintptr_t)(__bridge void *)texture;
    out[2] = 0;
    if (@available(macOS 10.15.4, *)) out[2] = drawable.drawableID;
    out[3] = host.maximumDrawableCount;
}

// Only the owning test window is changed; no system appearance preference is written.
void macos_caret_test_environment(void *window_ptr, int kind) {
    WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
    if (kind == 1 || kind == 2) wrapper.window.appearance = [NSAppearance appearanceNamed:kind == 1 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    if (kind == 3 || kind == 4) {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kind == 3 ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB);
        ((CAMetalLayer *)wrapper.metalView.layer).colorspace = space;
        CGColorSpaceRelease(space);
    }
    // Test-mode caller only: simulate an in-flight transition without entering
    // a Space or activating the app, then exercise the actual admission path.
    if (kind == 5 || kind == 6) wrapper.chromeFullscreenTransition = kind == 5;
}

int macos_caret_window_number(void *window_ptr) {
    return (int)((__bridge WindowWrapper *)window_ptr).window.windowNumber;
}
int macos_caret_window_visible(void *window_ptr) {
    return ((__bridge WindowWrapper *)window_ptr).window.visible;
}

// A real WindowServer image, not the IOSurface memcpy compositor. Never requests
// screen-recording permission or activates a window. 0 means PM must run attended.
int macos_caret_capture_window(void *window_ptr, const char *path) {
    @autoreleasepool {
        WindowWrapper *wrapper = (__bridge WindowWrapper *)window_ptr;
        if (!wrapper.window.visible || !CGPreflightScreenCaptureAccess()) return 0;
        typedef CGImageRef (*CaptureFn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
        // Obsoleted in the macOS 15 SDK; try the system symbol without building an
        // unavailable direct call. PM's screencapture path remains the fallback.
        CaptureFn capture = (CaptureFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        if (!capture) return 0;
        [CATransaction flush];
        CGImageRef image = capture(CGRectNull, kCGWindowListOptionIncludingWindow,
            (CGWindowID)wrapper.window.windowNumber, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
        if (!image) return 0;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        CGImageDestinationRef output = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
        BOOL ok = NO;
        if (output) {
            CGImageDestinationAddImage(output, image, NULL);
            ok = CGImageDestinationFinalize(output);
            CFRelease(output);
        }
        CGImageRelease(image);
        return ok ? 1 : -1;
    }
}

int macos_caret_patch_command_succeeded(void *command_ptr) {
    id<MTLCommandBuffer> command = (__bridge id<MTLCommandBuffer>)command_ptr;
    return command.status == MTLCommandBufferStatusCompleted;
}
