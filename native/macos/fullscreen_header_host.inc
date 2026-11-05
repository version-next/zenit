extern int metal_command_buffer_copy_texture_region_render(void *, void *, unsigned int, unsigned int, unsigned int, unsigned int, void *, unsigned int, unsigned int, int);

static void zenitHeaderCopyWarning(void) {
    static atomic_flag warned = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set_explicit(&warned, memory_order_relaxed))
        fprintf(stderr, "[header] render copy failed; header frame skipped\n");
}
// Experimental native presentation host. Included after WindowWrapper and the
// registry. It shares the logical window, Metal device and command submission.
#import <QuartzCore/CAShapeLayer.h>
#import <QuartzCore/CATransaction.h>
static BOOL zenitHeaderVisible(NSView *view) {
    return view.window.visible && (view.window.occlusionState&NSWindowOcclusionStateVisible) && !NSIsEmptyRect(view.visibleRect);
}

@interface ZenitHeaderView : NSView
@property (nonatomic) CGFloat controlsInset;
@end
@implementation ZenitHeaderView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSView *)hitTest:(NSPoint)point {
    if([self convertPoint:point fromView:self.superview].x<self.controlsInset) return nil;
    return [super hitTest:point];
}
- (void)mouseDown:(NSEvent *)event {} // The owner pump queues each event once.
- (void)rightMouseDown:(NSEvent *)event {}
@end

// Paint behind the actual NSButtons without participating in native hit testing.
@interface ZenitControlsBackgroundView : NSView
@end
@implementation ZenitControlsBackgroundView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface ZenitHeaderBodyView : NSView
@property (nonatomic, weak) ZenitFullscreenHeaderHost *host;
@property (nonatomic, strong) CAShapeLayer *bodyMask;
@property (nonatomic) CGRect maskRect;
@property (nonatomic) BOOL hasMaskRect;
@end
@implementation ZenitHeaderBodyView
- (void)layout {
    [super layout];
    ZenitFullscreenHeaderHost *host=self.host;WindowWrapper *owner=host.owner;
    if(!host.header || !owner.window || !owner.metalView || owner.nativeCloseObserved) return;
    MetalView *view=owner.metalView;
    if(!host.bodyReserveCommitted)
        host.bodyReserve=MAX(host.height,self.bounds.size.height-NSMaxY(owner.window.contentLayoutRect));
    CGFloat reserve=(!host.active || host.policy==2) ? host.bodyReserve : 0;
    CGFloat bodyHeight=MAX(1,self.bounds.size.height-reserve);
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CGRect rect=CGRectMake(0,0,self.bounds.size.width,bodyHeight);
    if(!self.bodyMask) self.bodyMask=[CAShapeLayer layer];
    if(self.layer.mask!=self.bodyMask) self.layer.mask=self.bodyMask;
    if(!self.hasMaskRect || !CGRectEqualToRect(self.maskRect,rect)) {
        CGPathRef path=CGPathCreateWithRect(rect,NULL);
        self.bodyMask.path=path;CGPathRelease(path);
        self.maskRect=rect;self.hasMaskRect=YES;
    }
    // setFrameSize synchronously renders. Publish clipping first so that
    // callback sees a complete layout, and never redraw for an unchanged frame.
    NSRect frame=NSMakeRect(0,0,self.bounds.size.width,bodyHeight+host.height);
    if(!NSEqualRects(view.frame,frame)) view.frame=frame;
    [CATransaction commit];
}
@end

@interface ZenitFullscreenHeaderHost ()
@property (nonatomic, strong) NSTitlebarAccessoryViewController *accessory;
// Retain the host toolbar while NSWindow temporarily owns the fullscreen one.
@property (nonatomic, strong) NSToolbar *savedToolbar;
@property (nonatomic, strong) NSToolbar *installedToolbar;
// NSWindowToolbarStyle (macOS 11); kept as its raw value so 10.15 still loads.
@property (nonatomic) NSInteger savedToolbarStyle;
@property (nonatomic) BOOL savedToolbarVisible;
@property (nonatomic, strong) ZenitHeaderBodyView *body;
@property (nonatomic, strong) NSLock *drawableLock;
@property (nonatomic, strong) id<CAMetalDrawable> cachedDrawable;
@property (nonatomic) BOOL acquisitionPending;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger acquisitionSerial;

@property (nonatomic) BOOL wasVisible;
@property (nonatomic) BOOL hasPresented;
@property (nonatomic, strong) NSColor *background;
@property (nonatomic, strong) ZenitControlsBackgroundView *controlsBackground;
@property (nonatomic, strong) NSArray<NSButton *> *observedButtons;
@property (nonatomic) BOOL correctingButtonAlpha;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) CALayer *retainedPaint;
@property (nonatomic) CGFloat retainedInset;
@property (nonatomic) BOOL windowedPaintReady;
@property (nonatomic) BOOL windowedCapturePending;
@property (nonatomic) uint64_t windowedCaptureRevision;
@property (nonatomic) uint64_t latestContentRevision;
@property (nonatomic) CGSize windowedCaptureSourceSize;
@property (nonatomic) CGFloat windowedCaptureScale;
@property (nonatomic) CGFloat windowedCaptureHeight;
@property (nonatomic, strong) NSColor *windowedCaptureBackground;
@property (nonatomic, strong) CAShapeLayer *headerMask;
@property (nonatomic, strong) CAShapeLayer *nativeMask;
@property (nonatomic) CGRect headerMaskRect;
@property (nonatomic) NSRect nativeMaskBounds;
@property (nonatomic) NSRect nativeMaskGPU;
@property (nonatomic) BOOL hasUpdateInputs;
@property (nonatomic) BOOL lastHasRetainedPaint;
@property (nonatomic) NSRect lastHeaderBounds;
@property (nonatomic) CGFloat lastWidth, lastHeight, lastInset;
@property (nonatomic) BOOL lastReveal, lastLocked, lastVisible, lastActive, lastExiting, lastTransition;
@property (nonatomic) NSInteger lastPolicy;
@property (nonatomic, strong) NSColor *lastBackground;
@property (nonatomic, weak) CALayer *lastHeaderLayer, *lastControlsLayer;
@property (nonatomic, weak) NSView *lastControlsParent;
@property (nonatomic) NSRect lastControlsFrame, lastGPU, lastBodyBounds, lastContentLayout, lastHeaderFrame, lastVisibleRect;

@end
static void zenitReleaseHeaderPixels(void *info,const void *data,size_t size) { free((void *)data); }
@implementation ZenitFullscreenHeaderHost
- (void)requestFrame {
    if(!self.header || self.frameRequested) return;
    self.frameRequested=YES;macos_post_empty_event();
}
- (void)completePreparationWithoutPaint:(BOOL)fallback {
    if(!self.pendingFullscreen || self.active || self.exiting) return;
    self.pendingFullscreen=NO;self.pendingDeadline=0;self.enterWithoutPaint=fallback;
    if(fallback) self.windowedPaintReady=NO;
    [self.owner.window toggleFullScreen:nil];
}
- (void)recoverFailedExit {
    if(!self.header) return;
    self.presentationEpoch++;self.active=YES;self.exiting=NO;
    self.pendingFullscreen=NO;self.pendingDeadline=0;self.enterWithoutPaint=NO;self.windowedCapturePending=NO;self.hasPresented=NO;
    self.hasUpdateInputs=NO; // Keep the committed body reserve across menu reveal.
    [self.drawableLock lock];self.generation++;self.acquisitionSerial++;
    self.cachedDrawable=nil;self.acquisitionPending=NO;[self.drawableLock unlock];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    // Keep the last completed native header visible. Prefetch hides it only
    // if the drawable extent actually changed during the refused exit.
    [self commitBodyLayout];[self update];
    [CATransaction commit];[self requestFrame];
}
- (void)commitBodyLayout {
    if(!self.active) return;
    [self installBody];
    [self.body setNeedsLayout:YES];[self.body layoutSubtreeIfNeeded];
    // The menu bar later changes contentLayoutRect while sliding over the
    // fullscreen surface. It must not reflow the pinned Header's body.
    self.bodyReserveCommitted=YES;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=(__bridge void *)self) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];return;
    }
    // AppKit fades the controls independently when the system menu bar retracts.
    // Correct the public property synchronously, within that same transaction;
    // a per-frame correction lets a faded frame reach the compositor first.
    NSButton *button=object;
    if(!self.active || self.exiting || self.correctingButtonAlpha || button.alphaValue==1) return;
    self.correctingButtonAlpha=YES;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    button.alphaValue=1;
    [CATransaction commit];self.correctingButtonAlpha=NO;
}
- (void)observeNativeButtons {
    WindowWrapper *w=self.owner;
    NSMutableArray<NSButton *> *buttons=[NSMutableArray new];
    for(NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)]) {
        NSButton *button=[w.window standardWindowButton:kind.integerValue];
        if(button) [buttons addObject:button];
    }
    if([self.observedButtons isEqualToArray:buttons]) return;
    [self stopObservingNativeButtons];self.observedButtons=buttons;
    for(NSButton *button in self.observedButtons) {
        [button addObserver:self forKeyPath:@"alphaValue" options:NSKeyValueObservingOptionInitial context:(__bridge void *)self];
    }
}
- (void)stopObservingNativeButtons {
    for(NSButton *button in self.observedButtons)
        [button removeObserver:self forKeyPath:@"alphaValue" context:(__bridge void *)self];
    self.observedButtons=nil;
}
// Called by the pre-capture fullscreen hook, never by windowed configure.
- (void)prepare {
    if(self.header || self.policy==0 || !self.owner.window || self.owner.nativeCloseObserved) return;
    WindowWrapper *w=self.owner;
    self.savedToolbar=w.window.toolbar;
    if(@available(macOS 11.0,*)) self.savedToolbarStyle=w.window.toolbarStyle;
    self.savedToolbarVisible=w.window.toolbar.visible;
    if(!self.drawableLock) self.drawableLock=[NSLock new];
    [self.drawableLock lock];self.generation++;self.acquisitionSerial++;self.acquisitionPending=NO;[self.drawableLock unlock];
    self.header=[[ZenitHeaderView alloc] initWithFrame:NSMakeRect(0,0,w.window.frame.size.width,self.height)];
    self.header.wantsLayer=YES;
    CAMetalLayer *layer=[CAMetalLayer layer];zenitTrackMetalLayer(layer,YES);layer.device=w.metalView.metalLayer.device;
    layer.pixelFormat=w.metalView.metalLayer.pixelFormat;layer.framebufferOnly=NO;
    CGFloat scale=zenitRenderScaleOverride();layer.contentsScale=scale>0?scale:w.window.backingScaleFactor;
    layer.allowsNextDrawableTimeout=YES;layer.maximumDrawableCount=3;
    // The original client Header remains visible until this layer has a frame.
    layer.opacity=0;
    self.header.layer=[CALayer layer];self.header.layer.opacity=0;
    self.retainedPaint=[CALayer layer];
    self.retainedPaint.contentsGravity=kCAGravityTopLeft;
    self.retainedPaint.anchorPoint=CGPointZero;
    [self.header.layer addSublayer:self.retainedPaint];
    self.header.layer.contentsScale=layer.contentsScale;
    layer.opacity=1;layer.opaque=NO;layer.frame=self.header.bounds;
    [self.header.layer addSublayer:layer];self.metalLayer=layer;
    self.accessory=[NSTitlebarAccessoryViewController new];self.accessory.view=self.header;
    self.accessory.layoutAttribute=NSLayoutAttributeTrailing;
    if(@available(macOS 11.0,*)) self.accessory.automaticallyAdjustsSize=NO;
    self.installedToolbar=[[NSToolbar alloc] initWithIdentifier:@"dev.zenit.fullscreen-header"];
    w.window.toolbar=self.installedToolbar;
    if(@available(macOS 11.0,*)) w.window.toolbarStyle=NSWindowToolbarStyleUnifiedCompact;
    w.window.toolbar.visible=YES;
    [w.window addTitlebarAccessoryViewController:self.accessory];
    self.hasPresented=NO;self.windowedPaintReady=NO;w.chromeStateGeneration++;
}
- (void)start {
    if(self.active || self.policy==0 || !self.owner.window || self.owner.nativeCloseObserved) return;
    [self prepare];
    WindowWrapper *w=self.owner;
    // The pre-capture hook installed the hosts and completed their retained
    // paint gate before entry. Keep their ownership stable during animation.
    self.presentationEpoch++;
    self.active=YES;self.exiting=NO;self.hasPresented=NO;self.pendingFullscreen=NO;self.pendingDeadline=0;self.enterWithoutPaint=NO;self.windowedCapturePending=NO;
    // Freeze the accessory before NSWindow captures its transition surface,
    // rather than switching between Metal and retained paint mid-animation.
    [CATransaction begin];[CATransaction setDisableActions:YES];
    if(!self.windowedPaintReady) self.header.layer.opacity=0;
    self.metalLayer.opacity=0;[self update];[CATransaction commit];
    [CATransaction flush];
    [self observeNativeButtons];
    if(w.window.toolbar==self.installedToolbar) w.window.toolbar.visible=self.policy==2 || self.locked;
    [w.window makeFirstResponder:w.metalView];[self.body setNeedsLayout:YES];
    [self.body layoutSubtreeIfNeeded];w.chromeStateGeneration++;
}
- (void)installBody {
    if(self.body) return;
    WindowWrapper *w=self.owner;
    self.bodyReserve=self.height;self.bodyReserveCommitted=NO;
    self.body=[[ZenitHeaderBodyView alloc] initWithFrame:w.metalView.frame];self.body.host=self;
    self.body.wantsLayer=YES;self.body.layer.masksToBounds=YES;
    [w.metalView removeFromSuperview];w.window.contentView=self.body;
    w.metalView.autoresizingMask=NSViewNotSizable;[self.body addSubview:w.metalView];
    [self.body setNeedsLayout:YES];[self.body layoutSubtreeIfNeeded];
}
- (void)beginExit {
    if(!self.active || self.exiting) return;
    self.presentationEpoch++;
    // AppKit animates the existing presentation. Keep that completed Metal
    // surface intact until its normal windowed resize can be submitted.
    self.exiting=YES;
}
- (void)finishExit {
    // AppKit has finished reparenting. Restore the original windowed chrome
    // and client header; the delegate publishes its matching final resize.
    [self stop];
}
// Closing can arrive before AppKit has released its fullscreen hierarchy.
// Invalidate work and observers, retaining every view/layer/toolbar untouched.
- (void)quiesceForClose {
    self.presentationEpoch++;
    self.active=NO;self.exiting=NO;self.pendingFullscreen=NO;self.pendingDeadline=0;
    self.enterWithoutPaint=NO;self.frameRequested=NO;self.hasPresented=NO;
    self.windowedPaintReady=NO;self.windowedCapturePending=NO;
    [self stopObservingNativeButtons];
    [self.drawableLock lock];self.generation++;self.acquisitionSerial++;
    self.cachedDrawable=nil;self.acquisitionPending=NO;[self.drawableLock unlock];
}
- (void)discardClosedPresentation {
    [self quiesceForClose];
    // NSWindow/AppKit retain the closing views until their own teardown. Do not
    // reparent content or restore toolbar even on a host's hard-destroy path.
    self.controlsBackground=nil;self.accessory=nil;self.header=nil;self.metalLayer=nil;
    self.retainedPaint=nil;self.body=nil;self.savedToolbar=nil;self.installedToolbar=nil;
    self.headerMask=nil;self.nativeMask=nil;self.windowedCaptureBackground=nil;
    self.bodyReserveCommitted=NO;self.hasUpdateInputs=NO;self.lastBackground=nil;
    self.lastControlsParent=nil;self.lastHeaderLayer=nil;self.lastControlsLayer=nil;
}
- (void)stop {
    if(self.owner.nativeCloseObserved) {[self discardClosedPresentation];return;}
    if(!self.header) return;
    self.presentationEpoch++;
    WindowWrapper *w=self.owner;self.active=NO;self.exiting=NO;
    self.pendingFullscreen=NO;self.pendingDeadline=0;self.enterWithoutPaint=NO;self.frameRequested=NO;
    self.hasPresented=NO;self.windowedPaintReady=NO;self.windowedCapturePending=NO;self.windowedCaptureBackground=nil;self.bodyReserveCommitted=NO;
    [self stopObservingNativeButtons];
    [self.controlsBackground removeFromSuperview];self.controlsBackground=nil;
    [self.drawableLock lock];self.generation++;self.acquisitionSerial++;self.cachedDrawable=nil;self.acquisitionPending=NO;[self.drawableLock unlock];
    [self.accessory removeFromParentViewController];
    if(self.body) {
        [w.metalView removeFromSuperview];w.window.contentView=w.metalView;
        w.metalView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        w.metalView.frame=NSMakeRect(0,0,self.body.bounds.size.width,self.body.bounds.size.height);
    }
    // A consumer may replace its toolbar during our preparation/transition.
    // Restore only while the window still owns the toolbar we installed.
    if(w.window.toolbar==self.installedToolbar) {
        w.window.toolbar=self.savedToolbar;
        if(@available(macOS 11.0,*)) w.window.toolbarStyle=(NSWindowToolbarStyle)self.savedToolbarStyle;
        // AppKit makes a toolbar visible when attaching it, even if hidden.
        if(self.savedToolbar) self.savedToolbar.visible=self.savedToolbarVisible;
    }
    self.accessory=nil;self.header=nil;self.metalLayer=nil;self.retainedPaint=nil;self.body=nil;self.savedToolbar=nil;self.installedToolbar=nil;
    self.headerMask=nil;self.nativeMask=nil;self.hasUpdateInputs=NO;self.lastBackground=nil;self.lastControlsParent=nil;
    self.lastHeaderLayer=nil;self.lastControlsLayer=nil;
    [w applyTrafficLightsInset];
    // Closing must not reactivate the input responder while key ownership leaves.
    if(!w.nativeCloseObserved) [w.window makeFirstResponder:w.metalView];
    w.chromeStateGeneration++;
}
- (void)update {
    atomic_fetch_add_explicit(&g_header_updates,1,memory_order_relaxed);
    if(!self.header || self.owner.nativeCloseObserved) return;
    WindowWrapper *w=self.owner;
    BOOL reveal=!self.active || self.policy==2 || self.locked;
    BOOL visible=zenitHeaderVisible(self.header);
    CGFloat inset=0;
    // Poll native geometry: AppKit can rebuild/reparent the titlebar or slide
    // its presentation without a client resize or explicit chrome event.
    NSButton *buttons[3] = {
        [w.window standardWindowButton:NSWindowCloseButton],
        [w.window standardWindowButton:NSWindowMiniaturizeButton],
        [w.window standardWindowButton:NSWindowZoomButton]
    };
    for(int i=0;i<3;i++) {
        NSButton *button=buttons[i];
        if(!button) continue;
        NSRect r=[self.header convertRect:button.bounds fromView:button];inset=MAX(inset,NSMaxX(r)+8);
    }
    if(w.chromeFullscreenTransition && self.active && self.retainedPaint.contents) inset=self.retainedInset;
    else if(inset<=0) inset=((ZenitHeaderView *)self.header).controlsInset;
    NSView *parent=buttons[0].superview;
    NSRect controlsFrame=parent.bounds;
    NSRect headerGPU=NSMakeRect(inset,0,MAX(0,self.header.bounds.size.width-inset),self.header.bounds.size.height);
    NSRect gpu=parent ? [parent convertRect:headerGPU fromView:self.header] : NSZeroRect;
    if(self.controlsBackground.superview==parent && self.controlsBackground && NSEqualRects(self.controlsBackground.frame,controlsFrame))
        gpu=[self.controlsBackground convertRect:headerGPU fromView:self.header];
    NSRect bodyBounds=self.body.bounds, contentLayout=w.window.contentLayoutRect;
    BOOL bodyChanged=!self.hasUpdateInputs || self.lastReveal!=reveal ||
        self.body.layer.mask!=self.body.bodyMask ||
        self.lastWidth!=w.window.frame.size.width || self.lastHeight!=self.height ||
        self.lastActive!=self.active || self.lastPolicy!=self.policy ||
        !NSEqualRects(self.lastBodyBounds,bodyBounds) ||
        (!self.bodyReserveCommitted && !NSEqualRects(self.lastContentLayout,contentLayout));
    BOOL buttonsChanged=self.active && (self.observedButtons.count!=3 ||
        self.observedButtons[0]!=buttons[0] || self.observedButtons[1]!=buttons[1] || self.observedButtons[2]!=buttons[2]);
    BOOL nativeBackgroundValid=!self.background || !parent ||
        (self.nativeMask && self.lastControlsLayer==self.controlsBackground.layer &&
         self.controlsBackground.superview==parent && NSEqualRects(self.controlsBackground.frame,controlsFrame) &&
         self.controlsBackground.layer.mask==self.nativeMask && NSEqualRects(self.nativeMaskBounds,self.controlsBackground.bounds));
    BOOL same=self.hasUpdateInputs && !bodyChanged && !buttonsChanged && nativeBackgroundValid &&
        self.headerMask && self.lastHeaderLayer==self.header.layer &&
        self.header.layer.mask==self.headerMask && NSEqualRects(self.lastHeaderBounds,self.header.bounds) &&
        self.lastHasRetainedPaint==(self.retainedPaint.contents!=nil) && CGPointEqualToPoint(self.retainedPaint.position,CGPointZero) &&
        (!w.chromeFullscreenTransition || self.exiting || !self.retainedPaint.contents || self.metalLayer.opacity==0) &&
        self.lastInset==inset && self.lastLocked==self.locked && self.lastVisible==visible &&
        self.lastExiting==self.exiting && self.lastTransition==w.chromeFullscreenTransition &&
        (self.lastBackground==self.background || [self.lastBackground isEqual:self.background]) && self.lastControlsParent==parent &&
        NSEqualRects(self.lastControlsFrame,controlsFrame) && NSEqualRects(self.lastGPU,gpu) &&
        NSEqualRects(self.lastHeaderFrame,self.header.frame) && NSEqualRects(self.lastVisibleRect,self.header.visibleRect) &&
        (w.window.toolbar!=self.installedToolbar || w.window.toolbar.visible==reveal);
    if(same) return;
    atomic_fetch_add_explicit(&g_header_work_updates,1,memory_order_relaxed);
    [CATransaction begin];[CATransaction setDisableActions:YES];
    if(w.window.toolbar==self.installedToolbar && w.window.toolbar.visible!=reveal) {
        w.window.toolbar.visible=reveal;
        // Keep the proven fullscreen sibling-order workaround on a reveal edge.
        if(reveal && self.active) {
            [self.accessory removeFromParentViewController];
            [w.window addTitlebarAccessoryViewController:self.accessory];
        }
        w.chromeStateGeneration++;
    }
    if(self.header.frame.size.width!=w.window.frame.size.width || (reveal && self.header.frame.size.height!=self.height))
        self.header.frame=NSMakeRect(0,0,w.window.frame.size.width,self.height);
    if(bodyChanged) {[self.body setNeedsLayout:YES];[self.body layoutSubtreeIfNeeded];}
    visible=zenitHeaderVisible(self.header);
    if(!self.hasUpdateInputs || self.lastHeaderLayer!=self.header.layer || self.lastBackground!=self.background)
        self.header.layer.backgroundColor=self.background.CGColor;
    if(self.active) [self observeNativeButtons];
    if(visible!=self.wasVisible) {self.wasVisible=visible;w.chromeStateGeneration++;}
    ((ZenitHeaderView *)self.header).controlsInset=inset;
    if(self.background && parent) {
        BOOL newBackground=!self.controlsBackground;
        if(newBackground) {
            self.controlsBackground=[ZenitControlsBackgroundView new];self.controlsBackground.wantsLayer=YES;
        }
        BOOL reparented=self.controlsBackground.superview!=parent;
        if(reparented)
            [parent addSubview:self.controlsBackground positioned:NSWindowBelow relativeTo:buttons[0]];
        if(!NSEqualRects(self.controlsBackground.frame,controlsFrame)) self.controlsBackground.frame=controlsFrame;
        gpu=[self.controlsBackground convertRect:NSMakeRect(inset,0,MAX(0,self.header.bounds.size.width-inset),self.header.bounds.size.height) fromView:self.header];
        BOOL newMask=!self.nativeMask;
        if(newMask) {self.nativeMask=[CAShapeLayer layer];self.nativeMask.fillRule=kCAFillRuleEvenOdd;}
        if(self.controlsBackground.layer.mask!=self.nativeMask) self.controlsBackground.layer.mask=self.nativeMask;
        if(newMask || !NSEqualRects(self.nativeMaskBounds,self.controlsBackground.bounds) || !NSEqualRects(self.nativeMaskGPU,gpu)) {
            CGMutablePathRef exposed=CGPathCreateMutable();
            CGPathAddRect(exposed,NULL,NSRectToCGRect(self.controlsBackground.bounds));CGPathAddRect(exposed,NULL,NSRectToCGRect(gpu));
            self.nativeMask.path=exposed;CGPathRelease(exposed);
            self.nativeMaskBounds=self.controlsBackground.bounds;self.nativeMaskGPU=gpu;
        }
        // Input caching may precede AppKit creating the controls parent. New
        // native objects need their initial paint even when the color is cached.
        if(newBackground || newMask || reparented || self.lastControlsLayer!=self.controlsBackground.layer || self.lastBackground!=self.background)
            self.controlsBackground.layer.backgroundColor=self.background.CGColor;
    }
    CGRect rect=CGRectMake(inset,0,MAX(0,self.header.bounds.size.width-inset),self.header.bounds.size.height);
    BOOL newMask=!self.headerMask;
    if(newMask) self.headerMask=[CAShapeLayer layer];
    if(self.header.layer.mask!=self.headerMask) self.header.layer.mask=self.headerMask;
    if(newMask || !CGRectEqualToRect(self.headerMaskRect,rect)) {
        CGPathRef path=CGPathCreateWithRect(rect,NULL);self.headerMask.path=path;CGPathRelease(path);self.headerMaskRect=rect;
    }
    if(!self.exiting && !CGRectEqualToRect(self.metalLayer.frame,self.header.bounds)) self.metalLayer.frame=self.header.bounds;
    self.retainedPaint.position=CGPointZero;
    if(w.chromeFullscreenTransition && !self.exiting && self.retainedPaint.contents) self.metalLayer.opacity=0;
    [CATransaction commit];
    self.lastHeaderBounds=self.header.bounds;self.lastHasRetainedPaint=self.retainedPaint.contents!=nil;
    self.hasUpdateInputs=YES;self.lastWidth=w.window.frame.size.width;self.lastHeight=self.height;self.lastInset=inset;
    self.lastReveal=reveal;self.lastLocked=self.locked;self.lastVisible=visible;self.lastActive=self.active;
    self.lastExiting=self.exiting;self.lastTransition=w.chromeFullscreenTransition;self.lastPolicy=self.policy;
    self.lastBackground=self.background;self.lastControlsParent=parent;self.lastControlsFrame=controlsFrame;
    self.lastHeaderLayer=self.header.layer;self.lastControlsLayer=self.controlsBackground.layer;
    self.lastGPU=gpu;self.lastBodyBounds=self.body.bounds;self.lastContentLayout=w.window.contentLayoutRect;
    self.lastHeaderFrame=self.header.frame;self.lastVisibleRect=self.header.visibleRect;
}
- (void)prefetch {
    if(self.exiting || !self.active || !self.header || !zenitHeaderVisible(self.header)) return;
    CAMetalLayer *layer=self.metalLayer;
    CGFloat scale=zenitRenderScaleOverride();
    layer.contentsScale=scale>0?scale:self.owner.window.backingScaleFactor;
    self.header.layer.contentsScale=layer.contentsScale;
    CGSize size=CGSizeMake(self.header.bounds.size.width*layer.contentsScale,self.header.bounds.size.height*layer.contentsScale);
    if(!CGSizeEqualToSize(layer.drawableSize,size)) {
        [self.drawableLock lock];self.generation++;self.cachedDrawable=nil;[self.drawableLock unlock];
        self.hasPresented=NO;
        [CATransaction begin];[CATransaction setDisableActions:YES];layer.opacity=0;[CATransaction commit];
        layer.drawableSize=size;
    }
    [self.drawableLock lock];
    if(self.acquisitionPending || self.cachedDrawable) {[self.drawableLock unlock];return;}
    self.acquisitionPending=YES;NSUInteger generation=self.generation,serial=++self.acquisitionSerial;
    [self.drawableLock unlock];
    // Acquisition can wait for AppKit's clipped/reparented layer. It never
    // blocks the owner event loop or the body submission.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{
        @autoreleasepool {
            id<CAMetalDrawable> drawable=[layer nextDrawable];
            if(getenv("ZENIT_DEBUG_HEADER")) fprintf(stderr,"[header] acquire %p %lux%lu\n",(__bridge void *)drawable,(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height);
            [self.drawableLock lock];
            BOOL valid=generation==self.generation && serial==self.acquisitionSerial;
            if(valid) self.cachedDrawable=drawable;
            if(serial==self.acquisitionSerial) self.acquisitionPending=NO;
            [self.drawableLock unlock];
            dispatch_async(dispatch_get_main_queue(),^{
                [self.drawableLock lock];
                BOOL current=valid && generation==self.generation && serial==self.acquisitionSerial;
                [self.drawableLock unlock];
                // Only the main-thread continuation touches the weak owner.
                // Pin it locally and reject a detached/closed native window.
                WindowWrapper *owner=self.owner;
                if(current && self.header && !self.hasPresented && owner.window && owner.metalView && !owner.nativeCloseObserved) {
                    owner.chromeStateGeneration++;[self requestFrame];
                }
            });
        }
    });
}
- (BOOL)needsWindowedCapture:(id<MTLTexture>)source revision:(uint64_t)revision {
    return !self.active && !self.windowedCapturePending &&
        (!self.windowedPaintReady || self.windowedCaptureRevision!=revision ||
         !CGSizeEqualToSize(self.windowedCaptureSourceSize,CGSizeMake(source.width,source.height)) ||
         self.windowedCaptureScale!=self.metalLayer.contentsScale || self.windowedCaptureHeight!=self.height ||
         self.retainedInset!=((ZenitHeaderView *)self.header).controlsInset ||
         !((self.windowedCaptureBackground==self.background) || [self.windowedCaptureBackground isEqual:self.background]));
}
- (void)encodeTexture:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)buffer revision:(uint64_t)revision {
    if(self.owner.nativeCloseObserved || self.exiting || !self.header || (!self.pendingFullscreen && !zenitHeaderVisible(self.header))) return;
    self.latestContentRevision=revision;
    if(!self.active && self.owner.metalView.bounds.size.width>0) {
        // Source pixels are authoritative even if scale changed during prewarm.
        CGFloat scale=source.width/self.owner.metalView.bounds.size.width;
        self.metalLayer.contentsScale=scale;self.header.layer.contentsScale=scale;
    }
    // CAMetalLayer's drawable can disappear when AppKit reparents its view to
    // the fullscreen toolbar window. Keep a completed windowed Header image
    // behind it, rather than exposing an empty native layer during handoff.
    if([self needsWindowedCapture:source revision:revision] && (!self.owner.chromeFullscreenTransition || self.pendingFullscreen) && (source.pixelFormat==MTLPixelFormatBGRA8Unorm || source.pixelFormat==MTLPixelFormatRGBA8Unorm)) {
        self.windowedPaintReady=NO; // Never admit an older content/extent snapshot.
        NSUInteger h=MIN(source.height,(NSUInteger)ceil(self.height*self.metalLayer.contentsScale));
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat width:source.width height:h mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;
        desc.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> snapshot=[source.device newTextureWithDescriptor:desc];
        if(snapshot) {
            if (!metal_command_buffer_copy_texture_region_render((__bridge void *)buffer, (__bridge void *)source,
                0,0,(unsigned int)source.width,(unsigned int)h,(__bridge void *)snapshot,0,0,0)) {
                zenitHeaderCopyWarning(); return;
            }
            NSUInteger generation=self.generation, epoch=self.presentationEpoch;
            CGFloat capturedInset=((ZenitHeaderView *)self.header).controlsInset, capturedScale=self.metalLayer.contentsScale;
            self.windowedCapturePending=YES;
            BOOL capturedBodyReady=self.body!=nil;CGFloat capturedHeight=self.height;
            NSColor *capturedBackground=self.background;
            CGSize capturedSourceSize=CGSizeMake(source.width,source.height);
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                CGImageRef image=NULL;
                if(completed.status==MTLCommandBufferStatusCompleted) {
                    size_t row=snapshot.width*4,size=row*snapshot.height;void *pixels=malloc(size);
                    if(pixels) {
                        [snapshot getBytes:pixels bytesPerRow:row fromRegion:MTLRegionMake2D(0,0,snapshot.width,snapshot.height) mipmapLevel:0];
                        CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,pixels,size,zenitReleaseHeaderPixels);
                        if(provider) {
                            CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                            CGBitmapInfo format=snapshot.pixelFormat==MTLPixelFormatBGRA8Unorm ? kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst : kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast;
                            image=CGImageCreate(snapshot.width,snapshot.height,8,32,row,color,format,provider,NULL,NO,kCGRenderingIntentDefault);
                            CGColorSpaceRelease(color);CGDataProviderRelease(provider);
                        } else free(pixels);
                    }
                }
                dispatch_async(dispatch_get_main_queue(),^{
                    WindowWrapper *owner=self.owner;
                    if(generation==self.generation && epoch==self.presentationEpoch && self.header && !self.active && !self.exiting &&
                        owner.window && owner.metalView && !owner.nativeCloseObserved) {
                        self.windowedCapturePending=NO;
                        if(image && revision==self.latestContentRevision && capturedScale==self.metalLayer.contentsScale && capturedHeight==self.height &&
                           capturedInset==((ZenitHeaderView *)self.header).controlsInset &&
                           (capturedBackground==self.background || [capturedBackground isEqual:self.background])) {
                            [CATransaction begin];[CATransaction setDisableActions:YES];
                            self.retainedPaint.contents=(__bridge id)image;
                            self.retainedPaint.contentsScale=capturedScale;
                            self.retainedPaint.bounds=CGRectMake(0,0,snapshot.width/capturedScale,snapshot.height/capturedScale);
                            self.retainedInset=capturedInset;
                            self.retainedPaint.position=CGPointZero;
                            self.header.layer.opacity=1;
                            [self installBody];
                            self.windowedCaptureRevision=revision;self.windowedCaptureSourceSize=capturedSourceSize;
                            self.windowedCaptureScale=capturedScale;self.windowedCaptureHeight=capturedHeight;
                            self.windowedCaptureBackground=capturedBackground;
                            self.windowedPaintReady=capturedBodyReady &&
                                CGSizeEqualToSize(capturedSourceSize,owner.metalView.metalLayer.drawableSize);
                            [CATransaction commit];
                        }
                        // Retry failed/stale images too. Only a completed strip
                        // matching the installed body's final viewport admits entry.
                        if(!self.windowedPaintReady) {
                            owner.chromeStateGeneration++;[self requestFrame];
                        }
                        if(self.pendingFullscreen && self.windowedPaintReady)
                            [self completePreparationWithoutPaint:NO];
                    }
                    if(image) CGImageRelease(image);
                });
            }];
        }
    }
    // Windowed preparation needs only its completed retained snapshot, not a
    // second native drawable/copy/presentation on every body frame.
    if(!self.active) return;
    [self.drawableLock lock];id<CAMetalDrawable> drawable=self.cachedDrawable;self.cachedDrawable=nil;[self.drawableLock unlock];
    if(getenv("ZENIT_DEBUG_HEADER")) fprintf(stderr,"[header] encode src=%lux%lu dst=%lux%lu visible=%g window=%ld frame=%s shown=%d level=%ld alpha=%g\n",(unsigned long)source.width,(unsigned long)source.height,(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height,self.header.visibleRect.size.height,(long)self.header.window.windowNumber,NSStringFromRect(self.header.window.frame).UTF8String,self.header.window.visible,(long)self.header.window.level,[self.owner.window standardWindowButton:NSWindowCloseButton].alphaValue);
    if(!self.owner.chromeFullscreenTransition && drawable && drawable.texture.width==source.width && drawable.texture.height<=source.height) {
        if (!metal_command_buffer_copy_texture_region_render((__bridge void *)buffer, (__bridge void *)source,
            0,0,(unsigned int)source.width,(unsigned int)drawable.texture.height,(__bridge void *)drawable.texture,0,0,0)) {
            zenitHeaderCopyWarning(); return;
        }
        zenitScheduleDrawablePresentation(buffer,drawable);self.hasPresented=YES;
        if(self.header.layer.opacity==0 || self.metalLayer.opacity==0) {
            NSUInteger generation=self.generation, epoch=self.presentationEpoch;
            CGRect capturedBounds=self.header.bounds;
            CGSize capturedDrawableSize=self.metalLayer.drawableSize;
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                if(completed.status!=MTLCommandBufferStatusCompleted) return;
                dispatch_async(dispatch_get_main_queue(),^{
                    WindowWrapper *owner=self.owner;
                    if(generation!=self.generation || epoch!=self.presentationEpoch || !self.header || self.exiting ||
                        !owner.window || !owner.metalView || owner.nativeCloseObserved || owner.chromeFullscreenTransition ||
                        !CGRectEqualToRect(capturedBounds,self.header.bounds) ||
                        !CGSizeEqualToSize(capturedDrawableSize,self.metalLayer.drawableSize)) return;
                    [CATransaction begin];[CATransaction setDisableActions:YES];
                    self.header.layer.opacity=1;self.metalLayer.opacity=1;[CATransaction commit];
                });
            }];
        }
    }
    [self prefetch];
}
@end

static NSPoint zenitLogicalScreenPoint(WindowWrapper *w,NSPoint screen) {
    ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
    if(host.active && zenitHeaderVisible(host.header)) {
        NSPoint p=[host.header convertPoint:[host.header.window convertPointFromScreen:screen] fromView:nil];
        if(NSPointInRect(p,host.header.visibleRect)) return NSMakePoint(p.x,host.height-p.y);
    }
    NSPoint p=[w.metalView convertPoint:[w.window convertPointFromScreen:screen] fromView:nil];
    return NSMakePoint(p.x,w.metalView.bounds.size.height-p.y);
}
static NSPoint zenitLogicalEventPoint(WindowWrapper *w,NSEvent *event) {
    return zenitLogicalScreenPoint(w,event.window?[event.window convertPointToScreen:event.locationInWindow]:event.locationInWindow);
}
static NSRect zenitLogicalScreenRect(WindowWrapper *w,CGFloat x,CGFloat y,CGFloat width,CGFloat height) {
    if(!w) return NSZeroRect;
    NSView *view=w.metalView;
    if(w.fullscreenHeader.active && y>=0 && y+height<=w.fullscreenHeader.height+.5) {
        view=w.fullscreenHeader.header;
        if(!zenitHeaderVisible(view)) return NSZeroRect;
    }
    NSRect local=NSMakeRect(x,view.bounds.size.height-y-height,width,height);
    return [view.window convertRectToScreen:[view convertRect:local toView:nil]];
}
static BOOL zenitLogicalHeaderHidden(WindowWrapper *w,CGFloat y,CGFloat height) {
    return w.fullscreenHeader.active && y>=0 && y+height<=w.fullscreenHeader.height+.5 && !zenitHeaderVisible(w.fullscreenHeader.header);
}
// Shared late-configuration path: a system entry/restoration can precede the
// application's policy configuration. The caller snapshots native fullscreen.
static void zenitConfigureHeaderForFullscreenState(WindowWrapper *w,BOOL fullscreen) {
    if(!w.fullscreenHeader.policy) [w.fullscreenHeader stop];
    else if(fullscreen || w.nativeFullscreenEntering) {
        [w.fullscreenHeader start];
        if(!w.chromeFullscreenTransition) [w.fullscreenHeader commitBodyLayout];
        [w.fullscreenHeader requestFrame];
    }
}
int macos_fullscreen_header_configure(void *owner,int policy,float height) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper *)owner;
        if(!w.window || policy<0 || policy>2 || !isfinite(height) || height<=0) return 0;
        if(policy && (!(w.window.styleMask&NSWindowStyleMaskTitled) || w.chromeHideControls)) return 0;
        if(!w.fullscreenHeader) {w.fullscreenHeader=[ZenitFullscreenHeaderHost new];w.fullscreenHeader.owner=w;}
        w.fullscreenHeader.height=height;w.fullscreenHeader.policy=policy;
        zenitConfigureHeaderForFullscreenState(w,(w.window.styleMask&NSWindowStyleMaskFullScreen)!=0);
        // Windowed policy configuration must not change toolbar, accessory,
        // titlebar height or AppKit system corners. Prepare at entry instead.
        return 1;
    }
}
void macos_fullscreen_header_layout(void *owner,int locked,float *offsetX,float *offsetY) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper *)owner;ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
        // AppKit can relayout plain-titlebar buttons after initial configure.
        // Keep the requested client-header inset; prepared/fullscreen hosts
        // retain native geometry. Frame notifications are the primary correction;
        // this poll is only a fallback and skips equal frames.
        [w applyTrafficLightsInset];
        // Chrome state is read-only. Enforce custom-chrome button hiding in
        // the poll, including windows with no fullscreen Header host.
        if(w.chromeHideControls) {
            NSButton *buttons[3]={[w.window standardWindowButton:NSWindowCloseButton],
                [w.window standardWindowButton:NSWindowMiniaturizeButton],[w.window standardWindowButton:NSWindowZoomButton]};
            for(int i=0;i<3;i++) if(buttons[i] && !buttons[i].hidden) buttons[i].hidden=YES;
        }
        host.locked=!!locked;[host update];*offsetX=0;*offsetY=0;
        [host prefetch];
        if(!host.active || !host.header.window) return;
        NSPoint screen=[host.header.window convertPointToScreen:[host.header convertPoint:NSMakePoint(0,host.height) toView:nil]];
        NSPoint body=[w.metalView convertPoint:[w.window convertPointFromScreen:screen] fromView:nil];
        *offsetX=body.x;*offsetY=w.metalView.bounds.size.height-body.y;
    }
}
int macos_fullscreen_header_take_frame_request(void *owner) {
    @autoreleasepool {
        ZenitFullscreenHeaderHost *host=((__bridge WindowWrapper *)owner).fullscreenHeader;
        BOOL requested=host.frameRequested;host.frameRequested=NO;return requested;
    }
}
int macos_fullscreen_header_needs_content_revision(void *layer) {
    @autoreleasepool {
        for(WindowWrapper *w in g_window_registry.objectEnumerator)
            if((__bridge void *)w.metalView.metalLayer==layer)
                return w.fullscreenHeader.header && !w.fullscreenHeader.active;
        return 0;
    }
}
void macos_fullscreen_header_encode(void *layer,void *texture,void *buffer,uint64_t revision) {
    @autoreleasepool {
        for(WindowWrapper *w in g_window_registry.objectEnumerator)
            if((__bridge void *)w.metalView.metalLayer==layer) {
                [w.fullscreenHeader encodeTexture:(__bridge id<MTLTexture>)texture commandBuffer:(__bridge id<MTLCommandBuffer>)buffer revision:revision];return;
            }
    }
}
void macos_fullscreen_header_background(void *owner,uint8_t r,uint8_t g,uint8_t b,uint8_t a) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper *)owner;
        if(!w.fullscreenHeader) return;
        w.fullscreenHeader.background=[NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
    }
}
int macos_fullscreen_header_post_pointer(void *owner,float x,float y,int right) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper *)owner;ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
        if(!host.header || !zenitHeaderVisible(host.header)) return 0;
        NSPoint point=[host.header convertPoint:NSMakePoint(x,host.height-y) toView:nil];
        for(NSNumber *type in right?@[@(NSEventTypeRightMouseDown),@(NSEventTypeRightMouseUp)]:@[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]) {
            NSEvent *e=[NSEvent mouseEventWithType:type.integerValue location:point modifierFlags:0
                timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:host.header.window.windowNumber
                context:nil eventNumber:1 clickCount:1 pressure:1];
            [NSApp postEvent:e atStart:NO];
        }
        return 1;
    }
}
int macos_fullscreen_header_test_hover(void *owner,int edge) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper *)owner;
        if(!w.fullscreenHeader.active || !CGPreflightPostEventAccess()) return 0;
        NSRect screen=w.window.screen.frame;
        CGFloat mainHeight=NSScreen.screens.firstObject.frame.size.height;
        CGPoint point=CGPointMake(NSMidX(screen),mainHeight-NSMaxY(screen)+(edge?1:200));
        CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,point,kCGMouseButtonLeft);
        if(!event) return 0;
        CGEventPost(kCGHIDEventTap,event);CFRelease(event);return 1;
    }
}
int macos_fullscreen_header_test_ready(void *owner) {
    @autoreleasepool {
        WindowWrapper *w=(__bridge WindowWrapper *)owner;
        return w.fullscreenHeader.windowedPaintReady && w.fullscreenHeader.header.layer.opacity==1;
    }
}
