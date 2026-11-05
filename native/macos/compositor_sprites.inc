// Compositor sprites (see src/ui/core/compositor_sprite.zig): a GPU-rendered
// flipbook shown above the window surface and stepped by Core Animation, so a
// periodic animation needs no in-process frames. Every function runs on the
// owning UI thread.
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static char zenitSpriteContainerKey;

// ZENIT_DEBUG_SPRITE_FREEZE=1: show the flipbook frame for the phase passed to
// each put instead of animating (pixel comparisons against the GPU path).
static BOOL zenitSpriteFreeze(void) {
    static int freeze = -1;
    if (freeze < 0) freeze = getenv("ZENIT_DEBUG_SPRITE_FREEZE") != NULL;
    return freeze == 1;
}
static char zenitSpriteSeenKey;

// IOSurface-backed BGRA atlas the compositor can show directly; returns the
// surface (+1) and its render-target texture (+1) in *texture_out.
void *macos_sprite_atlas_create(void *layer_ptr, unsigned width, unsigned height, void **texture_out) {
    @autoreleasepool {
        *texture_out = NULL;
        CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
        if (!host.device || width == 0 || height == 0) return NULL;
        size_t rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * 4);
        NSDictionary *properties = @{
            (__bridge NSString *)kIOSurfaceWidth: @(width),
            (__bridge NSString *)kIOSurfaceHeight: @(height),
            (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
            (__bridge NSString *)kIOSurfaceBytesPerRow: @(rowBytes),
            (__bridge NSString *)kIOSurfaceAllocSize: @(IOSurfaceAlignProperty(kIOSurfaceAllocSize, rowBytes * height)),
            (__bridge NSString *)kIOSurfacePixelFormat: @((uint32_t)'BGRA')
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!surface) return NULL;
        CGColorSpaceRef space = host.colorspace;
        CGColorSpaceRef fallback = space ? NULL : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        id colorSpec = CFBridgingRelease(CGColorSpaceCopyPropertyList(space ?: fallback));
        if (fallback) CGColorSpaceRelease(fallback);
        if (colorSpec) IOSurfaceSetValue(surface, kIOSurfaceColorSpace, (__bridge CFTypeRef)colorSpec);
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [host.device newTextureWithDescriptor:desc iosurface:surface plane:0];
        if (!texture) { CFRelease(surface); return NULL; }
        texture.label = @"Zenit.Sprite.Atlas";
        *texture_out = (__bridge_retained void *)texture;
        return surface;
    }
}

void macos_sprite_atlas_release(void *surface) {
    if (surface) CFRelease((IOSurfaceRef)surface);
}

static CALayer *zenitSpriteContainer(CAMetalLayer *host, BOOL create) {
    CALayer *container = objc_getAssociatedObject(host, &zenitSpriteContainerKey);
    if (container || !create) return container;
    container = [CALayer layer];
    container.name = @"zenit.sprites";
    container.anchorPoint = CGPointZero;
    container.frame = host.bounds;
    container.masksToBounds = NO;
    [host addSublayer:container];
    objc_setAssociatedObject(host, &zenitSpriteContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return container;
}

static CGRect zenitSpritePixelsToLayer(CAMetalLayer *host, double x, double y, double w, double h, double scale) {
    double height_px = host.drawableSize.height;
    double top = host.geometryFlipped ? y : height_px - (y + h);
    return CGRectMake(x / scale, top / scale, w / scale, h / scale);
}

// Unit contentsRect of flipbook cell `index`. IOSurface rows run top-down; the
// contents unit space starts at the bottom unless the layer's contents are
// flipped (geometry-flipped ancestry), so the row is mirrored accordingly.
static CGRect zenitSpriteCell(CALayer *sprite, unsigned index, unsigned columns, double cw, double ch, const unsigned atlas_px[2]) {
    const double aw = atlas_px[0], ah = atlas_px[1];
    const double col = index % columns, row = index / columns;
    const double top = row * ch / ah;
    const double y = sprite.contentsAreFlipped ? top : 1.0 - top - ch / ah;
    return CGRectMake(col * cw / aw, y, cw / aw, ch / ah);
}

void macos_sprites_begin(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    CALayer *container = zenitSpriteContainer(host, NO);
    for (CALayer *clip in container.sublayers) objc_setAssociatedObject(clip, &zenitSpriteSeenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Keep the sprite of `node_id` as it is for this frame (it is leaving).
void macos_sprite_keep(void *layer_ptr, unsigned node_id) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    for (CALayer *clip in zenitSpriteContainer(host, NO).sublayers) {
        if ([clip.name isEqualToString:[NSString stringWithFormat:@"zenit.sprite.%u", node_id]])
            objc_setAssociatedObject(clip, &zenitSpriteSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Show (or update) one sprite. Geometry is in the window's device pixels.
_Bool metal_glass_clock_trace_enabled(void);

// Layer writes for one sprite update. A sprite that did not move is put again
// every frame; writing its unchanged geometry still dirtied the layers, so
// each frame committed a transaction to the render server. Only differing
// values are written, inside a transaction opened at the first write.
typedef struct {
    BOOL open;
} ZenitSpriteTxn;

static void zenitSpriteTxnBegin(ZenitSpriteTxn *txn) {
    if (txn->open) return;
    txn->open = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
}

static void zenitSpriteTxnEnd(ZenitSpriteTxn *txn) {
    if (txn->open) [CATransaction commit];
    txn->open = NO;
}

static void zenitSpriteSetFrame(ZenitSpriteTxn *txn, CALayer *layer, CGRect frame) {
    if (CGRectEqualToRect(layer.frame, frame)) return;
    zenitSpriteTxnBegin(txn);
    layer.frame = frame;
}

static void zenitSpriteSetMasks(ZenitSpriteTxn *txn, CALayer *layer, BOOL masks) {
    if (layer.masksToBounds == masks) return;
    zenitSpriteTxnBegin(txn);
    layer.masksToBounds = masks;
}

// `phase_s` is the animation phase at the current media time.
void macos_sprite_put(void *layer_ptr, unsigned node_id, unsigned long long key, void *surface,
                      const int origin_px[2], const unsigned cell_px[2], const int *clip_px,
                      unsigned columns, unsigned frames, const unsigned atlas_px[2],
                      double period_s, double phase_s, double scale, int is_opaque) {
    @autoreleasepool {
        CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
        ZenitSpriteTxn txn = {NO};
        CALayer *container = zenitSpriteContainer(host, NO);
        if (!container) {
            zenitSpriteTxnBegin(&txn);
            container = zenitSpriteContainer(host, YES);
        }
        NSString *name = [NSString stringWithFormat:@"zenit.sprite.%u", node_id];
        CALayer *clip = nil;
        for (CALayer *candidate in container.sublayers) if ([candidate.name isEqualToString:name]) clip = candidate;
        zenitSpriteSetFrame(&txn, container, host.bounds);
        if (!clip) {
            zenitSpriteTxnBegin(&txn);
            clip = [CALayer layer];
            clip.name = name;
            clip.anchorPoint = CGPointZero;
            CALayer *sprite = [CALayer layer];
            sprite.name = @"zenit.sprite.content";
            sprite.anchorPoint = CGPointZero;
            sprite.contentsGravity = kCAGravityResize;
            sprite.magnificationFilter = kCAFilterNearest;
            sprite.minificationFilter = kCAFilterNearest;
            sprite.opaque = NO;
            [clip addSublayer:sprite];
            [container addSublayer:clip];
        }
        CALayer *sprite = clip.sublayers.firstObject;
        const double ox = origin_px[0], oy = origin_px[1], cw = cell_px[0], ch = cell_px[1];
        CGRect spriteFrame = zenitSpritePixelsToLayer(host, ox, oy, cw, ch, scale);
        const CGRect clipFrame = clip_px
            ? zenitSpritePixelsToLayer(host, clip_px[0], clip_px[1], clip_px[2], clip_px[3], scale)
            : host.bounds;
        zenitSpriteSetFrame(&txn, clip, clipFrame);
        zenitSpriteSetMasks(&txn, clip, clip_px != NULL);
        spriteFrame.origin.x -= clipFrame.origin.x;
        spriteFrame.origin.y -= clipFrame.origin.y;
        zenitSpriteSetFrame(&txn, sprite, spriteFrame);
        if (sprite.contentsScale != scale) {
            zenitSpriteTxnBegin(&txn);
            sprite.contentsScale = scale;
        }
        // Opaque cells carry the background they cover: the compositor replaces
        // pixels instead of blending (exact match with the GPU frame).
        if (sprite.opaque != (is_opaque != 0)) {
            zenitSpriteTxnBegin(&txn);
            sprite.opaque = is_opaque != 0;
        }
        NSNumber *knownKey = objc_getAssociatedObject(sprite, &zenitSpriteContainerKey);
        if (!knownKey || knownKey.unsignedLongLongValue != key || sprite.contents != (__bridge id)surface) {
            zenitSpriteTxnBegin(&txn);
            sprite.contents = (__bridge id)surface;
            objc_setAssociatedObject(sprite, &zenitSpriteContainerKey, @(key), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:frames];
            NSMutableArray<NSNumber *> *times = [NSMutableArray arrayWithCapacity:frames + 1];
            for (unsigned i = 0; i < frames; i++) {
                [rects addObject:[NSValue valueWithRect:NSRectFromCGRect(zenitSpriteCell(sprite, i, columns, cw, ch, atlas_px))]];
                [times addObject:@((double)i / frames)];
            }
            [times addObject:@1.0];
            [rects addObject:rects.firstObject];
            sprite.contentsRect = rects.firstObject.rectValue;
            CAKeyframeAnimation *steps = [CAKeyframeAnimation animationWithKeyPath:@"contentsRect"];
            steps.values = rects;
            steps.keyTimes = times;
            steps.calculationMode = kCAAnimationDiscrete;
            steps.duration = period_s;
            steps.repeatCount = HUGE_VALF;
            steps.removedOnCompletion = NO;
            // Align frame 0 with phase 0 of the source's clock.
            steps.beginTime = [sprite convertTime:CACurrentMediaTime() fromLayer:nil] - phase_s;
            // Pacing traces: frame 0 shows at anchor + k * period (host time).
            if (metal_glass_clock_trace_enabled()) {
                const double now = CACurrentMediaTime();
                fprintf(stderr, "[glass-clock] {\"kind\":\"sprite\",\"node\":%u,\"host_time\":%.9f,\"anchor\":%.9f,\"period\":%.9f,\"frames\":%u}\n",
                        node_id, now, now - phase_s, period_s, frames);
            }
            [sprite removeAnimationForKey:@"zenit.flipbook"];
            [sprite addAnimation:steps forKey:@"zenit.flipbook"];
        }
        if (zenitSpriteFreeze() && frames) {
            // Tests: hold the frame nearest to the current phase, no animation.
            unsigned index = (unsigned)llround(phase_s / period_s * frames) % frames;
            const CGRect cell = zenitSpriteCell(sprite, index, columns, cw, ch, atlas_px);
            if ([sprite animationForKey:@"zenit.flipbook"] || !CGRectEqualToRect(sprite.contentsRect, cell)) {
                zenitSpriteTxnBegin(&txn);
                [sprite removeAnimationForKey:@"zenit.flipbook"];
                sprite.contentsRect = cell;
            }
        }
        objc_setAssociatedObject(clip, &zenitSpriteSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        zenitSpriteTxnEnd(&txn);
    }
}

// Remove sprites neither put nor kept since macos_sprites_begin.
// Returns the number still shown.
unsigned macos_sprites_end(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    CALayer *container = zenitSpriteContainer(host, NO);
    if (!container) return 0;
    ZenitSpriteTxn txn = {NO};
    unsigned shown = 0;
    for (CALayer *clip in [container.sublayers copy]) {
        if (objc_getAssociatedObject(clip, &zenitSpriteSeenKey)) { shown++; continue; }
        zenitSpriteTxnBegin(&txn);
        [clip removeFromSuperlayer];
    }
    zenitSpriteTxnEnd(&txn);
    return shown;
}

void macos_sprites_clear(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    CALayer *container = zenitSpriteContainer(host, NO);
    if (!container) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [container removeFromSuperlayer];
    [CATransaction commit];
    objc_setAssociatedObject(host, &zenitSpriteContainerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ---------------------------------------------------------------------------
// CPU damage patches (src/zenit_app/cpu_patch.zig): opaque IOSurfaces placed
// over the window surface, below sprites. A GPU frame presents its drawable
// and removes every patch in one transaction (begin/end_gpu_handoff).
static char zenitPatchContainerKey;
static char zenitPatchPolicyKey;

static CALayer *zenitPatchContainer(CAMetalLayer *host, BOOL create) {
    CALayer *container = objc_getAssociatedObject(host, &zenitPatchContainerKey);
    if (container || !create) return container;
    container = [CALayer layer];
    container.name = @"zenit.patches";
    container.anchorPoint = CGPointZero;
    container.frame = host.bounds;
    CALayer *sprites = zenitSpriteContainer(host, NO);
    if (sprites) [host insertSublayer:container below:sprites];
    else [host addSublayer:container];
    objc_setAssociatedObject(host, &zenitPatchContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return container;
}

// Show `surface` at a window device-pixel rectangle; patches it fully covers
// are dropped. Returns the number of patches shown.
unsigned macos_patch_put(void *layer_ptr, void *surface, unsigned x, unsigned y, unsigned w, unsigned h, double scale) {
    @autoreleasepool {
        CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        CALayer *container = zenitPatchContainer(host, YES);
        container.frame = host.bounds;
        CGRect frame = zenitSpritePixelsToLayer(host, x, y, w, h, scale);
        for (CALayer *old in [container.sublayers copy])
            if (CGRectContainsRect(frame, old.frame)) [old removeFromSuperlayer];
        CALayer *patch = [CALayer layer];
        patch.name = @"zenit.patch";
        patch.anchorPoint = CGPointZero;
        patch.frame = frame;
        patch.contentsScale = scale;
        patch.contentsGravity = kCAGravityResize;
        patch.magnificationFilter = kCAFilterNearest;
        patch.minificationFilter = kCAFilterNearest;
        patch.opaque = YES;
        patch.contents = (__bridge id)surface;
        [container addSublayer:patch];
        unsigned count = (unsigned)container.sublayers.count;
        [CATransaction commit];
        return count;
    }
}

int macos_patches_begin_gpu_handoff(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    CALayer *container = zenitPatchContainer(host, NO);
    if (!container.sublayers.count) return 0;
    objc_setAssociatedObject(host, &zenitPatchPolicyKey, @(host.presentsWithTransaction), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    host.presentsWithTransaction = YES;
    return 1;
}

// Called after the drawable was presented into the current transaction
// (remove = 1), or after a failed frame (remove = 0: keep the patches).
void macos_patches_end_gpu_handoff(void *layer_ptr, int remove) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    CALayer *container = zenitPatchContainer(host, NO);
    [CATransaction setDisableActions:YES];
    if (remove) for (CALayer *patch in [container.sublayers copy]) [patch removeFromSuperlayer];
    NSNumber *policy = objc_getAssociatedObject(host, &zenitPatchPolicyKey);
    if (policy) host.presentsWithTransaction = policy.boolValue;
    objc_setAssociatedObject(host, &zenitPatchPolicyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void macos_patches_clear(void *layer_ptr) {
    CAMetalLayer *host = (__bridge CAMetalLayer *)layer_ptr;
    CALayer *container = zenitPatchContainer(host, NO);
    if (!container) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [container removeFromSuperlayer];
    [CATransaction commit];
    objc_setAssociatedObject(host, &zenitPatchContainerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Test harness: mirror a CPU patch into the retained presented-frame copy that
// /screenshot reads (src/zenit_app/renderer.zig retain_present_copy).
int macos_patch_copy_to_texture(void *surface_ptr, void *texture_ptr, unsigned x, unsigned y, unsigned w, unsigned h) {
    IOSurfaceRef surface = (IOSurfaceRef)surface_ptr;
    id<MTLTexture> texture = (__bridge id<MTLTexture>)texture_ptr;
    if (!surface || !texture || x + w > texture.width || y + h > texture.height) return 1;
    if (IOSurfaceGetWidth(surface) < w || IOSurfaceGetHeight(surface) < h) return 1;
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return 2;
    [texture replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:0 withBytes:IOSurfaceGetBaseAddress(surface) bytesPerRow:IOSurfaceGetBytesPerRow(surface)];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return 0;
}
