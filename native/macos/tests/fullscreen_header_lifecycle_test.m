// Hidden AppKit windows only. No ordering, native input or fullscreen Spaces.
#define ZENIT_TEST_RENDER_COPY_FIXTURE
#define ZENIT_MENU_ACTIONS_NO_MAIN
// This test checks real texture copies with its own fixture below.
#define ZENIT_TEST_RENDER_COPY_FIXTURE
#import "menu_actions_test.m"
#import <objc/runtime.h>

// All native Space requests stop at NSWindow's implementation boundary. The
// real Zenit action override and host run; only AppKit's desktop transition is
// replaced with delegate delivery. AppKit styleMask is never spoofed because
// even a getter projection can make AppKit resize/order native helper windows.
static IMP originalToggle;
static char simulatedFullscreenKey;
static unsigned enteredRequests;
static void fixtureNativeToggle(NSWindow *window,SEL selector,id sender) {
    WindowWrapper *w=wrapperForWindow(window);
    if([objc_getAssociatedObject(window,&simulatedFullscreenKey) boolValue]) {
        [w windowWillExitFullScreen:[NSNotification notificationWithName:NSWindowWillExitFullScreenNotification object:window]];
        objc_setAssociatedObject(window,&simulatedFullscreenKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [w windowDidExitFullScreen:[NSNotification notificationWithName:NSWindowDidExitFullScreenNotification object:window]];
    } else {
        enteredRequests++;
        assert(!w.fullscreenHeader.pendingFullscreen);
        if(w.fullscreenHeader.policy) {
            assert(w.fullscreenHeader.active && w.window.toolbar==w.fullscreenHeader.installedToolbar);
            if(!w.fullscreenHeader.windowedPaintReady) assert(w.fullscreenHeader.header.layer.opacity==0);
        }
        [w customWindowsToEnterFullScreenForWindow:window];
        [w window:window willUseFullScreenPresentationOptions:NSApplicationPresentationFullScreen];
        [w windowWillEnterFullScreen:[NSNotification notificationWithName:NSWindowWillEnterFullScreenNotification object:window]];
        objc_setAssociatedObject(window,&simulatedFullscreenKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [w windowDidEnterFullScreen:[NSNotification notificationWithName:NSWindowDidEnterFullScreenNotification object:window]];
    }
}
static void installFixtureDispatch(void) {
    originalToggle=method_setImplementation(class_getInstanceMethod(NSWindow.class,@selector(toggleFullScreen:)),(IMP)fixtureNativeToggle);

}
static void restoreFixtureDispatch(void) {
    method_setImplementation(class_getInstanceMethod(NSWindow.class,@selector(toggleFullScreen:)),originalToggle);

}
static void drainUntil(BOOL(^done)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!done() && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(done());
}
// CPU fixtures for the retained snapshot completion path. No GPU submission or
// real drawable is acquired; every copy outside this fixture fails hard.
static BOOL allowTextureCopies;
static unsigned textureCopies,readbacks;
int metal_command_buffer_copy_texture_region_render(void *buffer,void *source,unsigned x,unsigned y,unsigned width,unsigned height,void *destination,unsigned dx,unsigned dy,int flip) {
    assert(allowTextureCopies);textureCopies++;return 1;
}
@interface HeaderFixtureTexture : NSObject
@property NSUInteger width,height;
@property MTLPixelFormat pixelFormat;
@property(nonatomic,strong) id device;
@end
@implementation HeaderFixtureTexture
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    readbacks++;memset(bytes,255,row*region.size.height);
}
@end
@interface HeaderFixtureDevice : NSObject
@end
@implementation HeaderFixtureDevice
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
    HeaderFixtureTexture *texture=[HeaderFixtureTexture new];texture.width=descriptor.width;
    texture.height=descriptor.height;texture.pixelFormat=descriptor.pixelFormat;texture.device=self;return texture;
}
@end
@interface HeaderFixtureBuffer : NSObject
@property(nonatomic,strong) NSMutableArray *handlers;
@property MTLCommandBufferStatus status;
@end
@implementation HeaderFixtureBuffer
- (instancetype)init { self=[super init];if(self) {self.handlers=[NSMutableArray new];self.status=MTLCommandBufferStatusCompleted;}return self; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { [self.handlers addObject:[handler copy]]; }
- (void)complete { for(MTLCommandBufferHandler handler in self.handlers) handler((id)self);[self.handlers removeAllObjects]; }
@end
static HeaderFixtureTexture *fixtureSource(WindowWrapper *w) {
    HeaderFixtureTexture *texture=[HeaderFixtureTexture new];texture.width=w.metalView.metalLayer.drawableSize.width;
    texture.height=w.metalView.metalLayer.drawableSize.height;texture.pixelFormat=MTLPixelFormatBGRA8Unorm;
    texture.device=[HeaderFixtureDevice new];return texture;
}
static void snapshotCaptureWhileHidden(WindowWrapper *w) {
    ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
    host.pendingFullscreen=YES;w.chromeFullscreenTransition=YES;[host prepare];
    assert(!zenitHeaderVisible(host.header));
    allowTextureCopies=YES;unsigned initial=textureCopies,initialReadbacks=readbacks;
    for(int frame=0;frame<2;frame++) {
        HeaderFixtureTexture *source=fixtureSource(w);HeaderFixtureBuffer *buffer=[HeaderFixtureBuffer new];
        [host encodeTexture:(id)source commandBuffer:(id)buffer revision:42];
        assert(host.windowedCapturePending);
        [host encodeTexture:(id)source commandBuffer:(id)buffer revision:42]; // Coalesce in-flight copies.
        assert(textureCopies==initial+frame+1);
        [buffer complete];host.pendingFullscreen=NO; // Hold ready windowed state for cache assertions.
        drainUntil(^BOOL { return !host.windowedCapturePending && (frame==0 ? host.body!=nil : host.windowedPaintReady); });
        if(frame==0) {assert(!host.windowedPaintReady);host.pendingFullscreen=YES;}
    }
    assert(host.windowedPaintReady && textureCopies==initial+2 && readbacks==initialReadbacks+2);
    host.pendingFullscreen=YES;HeaderFixtureTexture *source=fixtureSource(w);
    HeaderFixtureBuffer *unchanged=[HeaderFixtureBuffer new];
    for(int frame=0;frame<8;frame++) [host encodeTexture:(id)source commandBuffer:(id)unchanged revision:42];
    assert(textureCopies==initial+2 && readbacks==initialReadbacks+2 && !unchanged.handlers.count);
    HeaderFixtureBuffer *changed=[HeaderFixtureBuffer new];
    [host encodeTexture:(id)source commandBuffer:(id)changed revision:43];
    assert(textureCopies==initial+3);[changed complete];host.pendingFullscreen=NO;
    drainUntil(^BOOL { return host.windowedCaptureRevision==43 && !host.windowedCapturePending; });
    assert(readbacks==initialReadbacks+3);
    // A newer header revision arriving during readback rejects the stale image
    // and requests a replacement frame instead of idling until timeout.
    (void)macos_fullscreen_header_take_frame_request((__bridge void *)w);
    assert(!host.frameRequested);
    id previousImage=host.retainedPaint.contents;
    HeaderFixtureBuffer *stale=[HeaderFixtureBuffer new];host.pendingFullscreen=YES;
    [host encodeTexture:(id)source commandBuffer:(id)stale revision:44];
    [host encodeTexture:(id)source commandBuffer:(id)stale revision:45];
    assert(textureCopies==initial+4);[stale complete];host.pendingFullscreen=NO;
    drainUntil(^BOOL { return !host.windowedCapturePending; });
    assert(!host.windowedPaintReady && host.retainedPaint.contents==previousImage && host.frameRequested);
    assert(macos_fullscreen_header_take_frame_request((__bridge void *)w));
    HeaderFixtureBuffer *retry=[HeaderFixtureBuffer new];host.pendingFullscreen=YES;
    [host encodeTexture:(id)source commandBuffer:(id)retry revision:45];[retry complete];host.pendingFullscreen=NO;
    drainUntil(^BOOL { return host.windowedPaintReady && host.windowedCaptureRevision==45; });
    HeaderFixtureBuffer *failed=[HeaderFixtureBuffer new];failed.status=MTLCommandBufferStatusError;host.pendingFullscreen=YES;
    [host encodeTexture:(id)source commandBuffer:(id)failed revision:46];[failed complete];host.pendingFullscreen=NO;
    drainUntil(^BOOL { return !host.windowedCapturePending; });
    assert(!host.windowedPaintReady && host.frameRequested);
    HeaderFixtureBuffer *recovered=[HeaderFixtureBuffer new];host.pendingFullscreen=YES;
    [host encodeTexture:(id)source commandBuffer:(id)recovered revision:46];[recovered complete];host.pendingFullscreen=NO;
    drainUntil(^BOOL { return host.windowedPaintReady && host.windowedCaptureRevision==46; });
    assert(textureCopies==initial+7 && readbacks==initialReadbacks+6);
    // Native colors/inset bypass the UI paint versions. Each invalidates one
    // snapshot; a change during readback must reject, then retry the stale strip.
    source=fixtureSource(w);
    for(int field=0;field<2;field++) {
        host.pendingFullscreen=YES;
        if(field==0) host.background=NSColor.redColor;
        else ((ZenitHeaderView *)host.header).controlsInset+=1;
        unsigned copies=textureCopies;
        HeaderFixtureBuffer *nativeChange=[HeaderFixtureBuffer new];
        [host encodeTexture:(id)source commandBuffer:(id)nativeChange revision:46];
        assert(textureCopies==copies+1 && !host.windowedPaintReady);
        if(field==0) host.background=NSColor.blueColor;
        else ((ZenitHeaderView *)host.header).controlsInset+=1;
        [nativeChange complete];host.pendingFullscreen=NO;
        drainUntil(^BOOL { return !host.windowedCapturePending; });
        assert(!host.windowedPaintReady);
        host.pendingFullscreen=YES;HeaderFixtureBuffer *retry=[HeaderFixtureBuffer new];
        [host encodeTexture:(id)source commandBuffer:(id)retry revision:46];
        [retry complete];host.pendingFullscreen=NO;
        drainUntil(^BOOL { return host.windowedPaintReady; });
        assert(textureCopies==copies+2);
        host.pendingFullscreen=YES;
        [host encodeTexture:(id)source commandBuffer:(id)retry revision:46];
        assert(textureCopies==copies+2); // Equality remains free.
    }
    fprintf(stderr,"PASS native background/inset capture keys and stale in-flight rejection\n");
    allowTextureCopies=NO;[host stop];w.chromeFullscreenTransition=NO;
}

// Actual native action/NSMenu dispatch with a hidden eligible window. The two
// capability getters are stubbed only for this fixture: a prohibited, unordered
// app has no genuine fullscreen eligibility. Space dispatch is already trapped.
static NSWindow *eligibleWindow;
static IMP originalEligible,originalGreenFullscreen;
static BOOL fixtureEligible(id window,SEL selector) {
    return window==eligibleWindow ? YES : ((BOOL(*)(id,SEL))originalEligible)(window,selector);
}
static BOOL fixtureGreenFullscreen(id window,SEL selector) {
    return window==eligibleWindow ? YES : ((BOOL(*)(id,SEL))originalGreenFullscreen)(window,selector);
}
static void nativeActionDispatch(WindowWrapper *w) {
    unsigned before=enteredRequests;NSButton *green=[w.window standardWindowButton:NSWindowZoomButton];
    assert(green.target==w.window);
    Method eligibility=class_getInstanceMethod(NSWindow.class,NSSelectorFromString(@"_canEnterFullScreenOrTileMode"));
    Method primary=class_getInstanceMethod(NSWindow.class,NSSelectorFromString(@"_zoomButtonIsFullScreenButton"));
    assert(eligibility && primary);eligibleWindow=w.window;
    BOOL genuinelyEligible=((BOOL(*)(id,SEL))method_getImplementation(eligibility))(w.window,NSSelectorFromString(@"_canEnterFullScreenOrTileMode"));
    fprintf(stderr,"BACKGROUND fullscreen capability: visible=%d activationPolicy=%ld nativeEligible=%d (no real Space requested)\n",w.window.visible,(long)NSApp.activationPolicy,genuinelyEligible);
    assert(!genuinelyEligible); // Prohibited/unordered windows cannot test real fullscreen close ordering.
    originalEligible=method_setImplementation(eligibility,(IMP)fixtureEligible);
    originalGreenFullscreen=method_setImplementation(primary,(IMP)fixtureGreenFullscreen);
    assert([NSApp sendAction:green.action to:green.target from:green]);
    assert(w.fullscreenHeader.pendingFullscreen && enteredRequests==before);
    method_setImplementation(eligibility,originalEligible);method_setImplementation(primary,originalGreenFullscreen);eligibleWindow=nil;
    assert(macos_chrome_action((__bridge void *)w,3,0));
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"Window"];menu.autoenablesItems=NO;
    NSMenuItem *item=[menu addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    item.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;item.target=w.window;
    NSEvent *event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:item.keyEquivalentModifierMask timestamp:0 windowNumber:w.window.windowNumber context:nil characters:@"f" charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
    assert([menu performKeyEquivalent:event]);assert(w.fullscreenHeader.pendingFullscreen);
    assert(macos_chrome_action((__bridge void *)w,3,0));
    [menu performActionForItemAtIndex:0];assert(w.fullscreenHeader.pendingFullscreen);
    assert(macos_chrome_action((__bridge void *)w,3,0));
    assert(enteredRequests==before && !w.window.visible && !NSApp.keyWindow);
    fprintf(stderr,"PASS native action dispatch: green target/action, Control-Command-F NSMenu keyEquivalent, Enter Full Screen NSMenu action -> ZenitWindow pending queue\n");
    fprintf(stderr,"Window restoration defaults: restorable=%d identifier=%s restorationClass=%s\n",w.window.restorable,w.window.identifier.UTF8String?:"nil",w.window.restorationClass ? class_getName(w.window.restorationClass) : "nil");
}

static NSWindow *minimizedWindow;
static BOOL fixtureMinimized;
static unsigned deminiaturizeRequests;
static IMP originalMiniaturized,originalDeminiaturize;
static BOOL fixtureIsMiniaturized(id window,SEL selector) {
    return window==minimizedWindow ? fixtureMinimized : ((BOOL(*)(id,SEL))originalMiniaturized)(window,selector);
}
static void fixtureDeminiaturize(id window,SEL selector,id sender) {
    if(window==minimizedWindow) {fixtureMinimized=NO;deminiaturizeRequests++;}
    else ((void(*)(id,SEL,id))originalDeminiaturize)(window,selector,sender);
}
static void minimizedEntryRequest(WindowWrapper *w) {
    minimizedWindow=w.window;fixtureMinimized=YES;deminiaturizeRequests=0;
    Method mini=class_getInstanceMethod(NSWindow.class,@selector(isMiniaturized));
    Method demini=class_getInstanceMethod(NSWindow.class,@selector(deminiaturize:));
    originalMiniaturized=method_setImplementation(mini,(IMP)fixtureIsMiniaturized);
    originalDeminiaturize=method_setImplementation(demini,(IMP)fixtureDeminiaturize);
    assert(macos_chrome_action((__bridge void *)w,3,1));
    unsigned before=enteredRequests;
    assert(!fixtureMinimized && deminiaturizeRequests==1 && w.waitingForDeminiaturize);
    assert(!w.fullscreenHeader.header && !w.fullscreenHeader.pendingFullscreen && !w.window.toolbar && !w.nativeFullscreenEntering);
    // isMiniaturized can turn false before the completion notification. Still
    // wait, including duplicate toggles and programmatic requests.
    [w.window toggleFullScreen:nil];assert(macos_chrome_action((__bridge void *)w,3,1));
    assert(deminiaturizeRequests==1 && w.waitingForDeminiaturize && enteredRequests==before);
    NSNotification *restored=[NSNotification notificationWithName:NSWindowDidDeminiaturizeNotification object:w.window];
    [w windowDidDeminiaturize:restored];
    assert(!w.waitingForDeminiaturize && w.fullscreenHeader.pendingFullscreen);
    [w windowDidDeminiaturize:restored];assert(enteredRequests==before);
    drainUntil(^BOOL { return enteredRequests==before+1; });
    assert(w.fullscreenHeader.active && !w.nativeFullscreenEntering && !w.chromeFullscreenTransition);
    fixtureNativeToggle(w.window,@selector(toggleFullScreen:),nil);
    drainUntil(^BOOL { return !w.fullscreenHeader.header; });
    before++;
    // Cancellation while restoration is pending must consume a late notification.
    fixtureMinimized=YES;assert(macos_chrome_action((__bridge void *)w,3,1));
    assert(w.waitingForDeminiaturize);assert(macos_chrome_action((__bridge void *)w,3,0));
    [w windowDidDeminiaturize:restored];
    assert(!w.waitingForDeminiaturize && !w.fullscreenHeader.header && enteredRequests==before);
    // A missing restoration completion also has a bounded epoch.
    fixtureMinimized=YES;[w.window toggleFullScreen:nil];
    NSUInteger epoch=w.fullscreenEntryEpoch;
    [w reconcileFullscreenEntryEpoch:epoch atTime:w.fullscreenEntryDeadline];
    assert(!w.waitingForDeminiaturize && !w.chromeFullscreenTransition && !w.nativeFullscreenEntering);
    [w windowDidDeminiaturize:restored];assert(enteredRequests==before);
    // AppKit completion normally observes NO. Guard the contrary state rather
    // than starting another deminiaturize cycle.
    fixtureMinimized=YES;[w.window toggleFullScreen:nil];fixtureMinimized=YES;
    unsigned requests=deminiaturizeRequests;
    [w windowDidDeminiaturize:restored];
    assert(!w.waitingForDeminiaturize && deminiaturizeRequests==requests && !w.fullscreenHeader.header);
    fixtureMinimized=YES;[w.window toggleFullScreen:nil];
    [w windowDidMiniaturize:[NSNotification notificationWithName:NSWindowDidMiniaturizeNotification object:w.window]];
    [w windowDidDeminiaturize:restored];assert(!w.waitingForDeminiaturize && !w.fullscreenHeader.header);
    fixtureMinimized=YES;[w.window toggleFullScreen:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidResignActiveNotification object:NSApp];
    [w windowDidDeminiaturize:restored];assert(!w.waitingForDeminiaturize && !w.fullscreenHeader.header && enteredRequests==before);
    fprintf(stderr,"PASS restoration cancellation: reminiaturize, application inactivity, contrary miniature getter; no loop\n");
    method_setImplementation(mini,originalMiniaturized);method_setImplementation(demini,originalDeminiaturize);minimizedWindow=nil;
    fprintf(stderr,"PASS delayed restoration: no native toggle/toolbar before didDeminiaturize; duplicate, cancellation and missing-notification expiry\n");
    assert(!w.window.visible && !NSApp.keyWindow);
}

// Exercise AppKit's actual metadata constructor, never its transition start.
// On macOS 26.4 it invokes the public presentation-options hook before reading
// the toolbar for the menu-bar companion controller. The read-only interception
// checks the toolbar at that capture point without changing Spaces or input.
@interface NSObject (HeaderFixtureNativeInit)
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)dispose;
@end
static NSWindow *captureWindow;
static IMP originalToolbarGetter;
static BOOL observedNativeToolbarCapture;
static NSInteger queryScenario;
static IMP originalActiveSpace,originalAttachedSheet,originalQueryMiniaturized;
static NSWindow *querySheet;
static BOOL fixtureOnActiveSpace(id window,SEL selector) {
    return window==captureWindow && queryScenario==1 ? NO : ((BOOL(*)(id,SEL))originalActiveSpace)(window,selector);
}
static BOOL fixtureQueryMiniaturized(id window,SEL selector) {
    return window==captureWindow && queryScenario==2 ? YES : ((BOOL(*)(id,SEL))originalQueryMiniaturized)(window,selector);
}
static NSWindow *fixtureAttachedSheet(id window,SEL selector) {
    return window==captureWindow && queryScenario==3 ? querySheet : ((id(*)(id,SEL))originalAttachedSheet)(window,selector);
}
static NSToolbar *observeCapturedToolbar(NSWindow *window,SEL selector) {
    NSToolbar *toolbar=((id(*)(id,SEL))originalToolbarGetter)(window,selector);
    if(window==captureWindow) {
        NSArray<NSString *> *stack=NSThread.callStackSymbols;
        if(stack.count>1 && [stack[1] containsString:@"[_NSFullScreenContentController initWithWindow:]"]) {
            WindowWrapper *owner=wrapperForWindow(window);
            assert(toolbar && toolbar==owner.fullscreenHeader.installedToolbar);
            assert(owner.fullscreenHeader.active && owner.nativeFullscreenEntering);
            observedNativeToolbarCapture=YES;
            fprintf(stderr,"AppKit toolbar capture: installed before will-enter notification\n%s\n",[[stack subarrayWithRange:NSMakeRange(0,MIN(stack.count,5))] componentsJoinedByString:@"\n"].UTF8String);
        }
    }
    return toolbar;
}
static void actualAppKitCaptureHook(void) {
    void *raw=macos_create_window(640,400,"Hidden native configuration capture");
    WindowWrapper *owner=(__bridge WindowWrapper *)raw;
    assert(macos_chrome_configure(raw,1,1,38));assert(macos_fullscreen_header_configure(raw,2,38));
    assert(!owner.window.toolbar && !owner.fullscreenHeader.header);
    __block unsigned willEnterNotifications=0;
    id token=[NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillEnterFullScreenNotification object:owner.window queue:nil usingBlock:^(NSNotification *n) {willEnterNotifications++;}];
    Class nativeClass=NSClassFromString(@"_NSFullScreenContentController");
    SEL initSelector=NSSelectorFromString(@"initWithWindow:");
    assert(nativeClass && [nativeClass instancesRespondToSelector:initSelector]);
    captureWindow=owner.window;
    Method method=class_getInstanceMethod(NSWindow.class,@selector(toolbar));
    originalToolbarGetter=method_setImplementation(method,(IMP)observeCapturedToolbar);
    Method active=class_getInstanceMethod(NSWindow.class,@selector(isOnActiveSpace));
    Method mini=class_getInstanceMethod(NSWindow.class,@selector(isMiniaturized));
    Method sheet=class_getInstanceMethod(NSWindow.class,@selector(attachedSheet));
    originalActiveSpace=method_setImplementation(active,(IMP)fixtureOnActiveSpace);
    originalQueryMiniaturized=method_setImplementation(mini,(IMP)fixtureQueryMiniaturized);
    originalAttachedSheet=method_setImplementation(sheet,(IMP)fixtureAttachedSheet);
    querySheet=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,100,100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    querySheet.releasedWhenClosed=NO;
    NSArray *scenarios=@[@"actual hidden/occluded",@"controlled other-Space getter",@"controlled minimized getter",@"controlled sheet getter"];
    for(queryScenario=0;queryScenario<scenarios.count;queryScenario++) {
        observedNativeToolbarCapture=NO;
        id controller=[[nativeClass alloc] initWithWindow:owner.window];
        assert(controller && observedNativeToolbarCapture && willEnterNotifications==0);
        assert(!owner.window.visible && !NSApp.keyWindow);
        [controller dispose];controller=nil; // Actual AppKit query, then abandon without starting.
        NSUInteger epoch=owner.fullscreenEntryEpoch;
        CFTimeInterval deadline=owner.fullscreenEntryDeadline;
        assert(deadline>0 && owner.nativeFullscreenEntering && owner.chromeFullscreenTransition);
        [owner reconcileFullscreenEntryEpoch:epoch atTime:deadline-.01];
        assert(owner.nativeFullscreenEntering);
        if(queryScenario==0) {
            // Exercise the actual dispatch_after watchdog with rendering idle,
            // rather than only the injected-clock branch used by other cases.
            NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:11];
            while(owner.nativeFullscreenEntering && limit.timeIntervalSinceNow>0)
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        } else [owner reconcileFullscreenEntryEpoch:epoch atTime:deadline];
        assert(!owner.nativeFullscreenEntering && !owner.chromeFullscreenTransition && !owner.fullscreenHeader.header);
        assert(!owner.window.toolbar && macos_chrome_action(raw,3,0)); // Exit no longer rejected.
        fprintf(stderr,"PASS query without entry: %s; actual constructor -> query -> toolbar capture; no willEnter; epoch reclaimed\n",[scenarios[queryScenario] UTF8String]);
    }
    method_setImplementation(active,originalActiveSpace);method_setImplementation(mini,originalQueryMiniaturized);
    method_setImplementation(sheet,originalAttachedSheet);querySheet=nil;
    method_setImplementation(method,originalToolbarGetter);captureWindow=nil;
    [NSNotificationCenter.defaultCenter removeObserver:token];
    // A refusal notification invalidates the old timer; a new request cannot be
    // reset by that timer. Also cover willEnter followed by a silent abandonment.
    [owner window:owner.window willUseFullScreenPresentationOptions:0];
    NSUInteger staleEpoch=owner.fullscreenEntryEpoch;
    [owner windowDidFailToEnterFullScreen:owner.window];
    assert(!owner.chromeFullscreenTransition && !owner.fullscreenHeader.header);
    owner.waitingForDeminiaturize=YES; // Native entry supersedes an old restore intent.
    [owner windowWillEnterFullScreen:[NSNotification notificationWithName:NSWindowWillEnterFullScreenNotification object:owner.window]];
    assert(!owner.waitingForDeminiaturize);
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidResignActiveNotification object:NSApp];
    NSUInteger currentEpoch=owner.fullscreenEntryEpoch;
    [owner reconcileFullscreenEntryEpoch:staleEpoch atTime:owner.fullscreenEntryDeadline+1];
    assert(owner.nativeFullscreenEntering && owner.fullscreenEntryEpoch==currentEpoch);
    NSView *duringAnimation=owner.fullscreenHeader.header;
    assert(owner.fullscreenEntryStarted && owner.fullscreenEntryDeadline==0);
    [owner reconcileFullscreenEntryEpoch:currentEpoch atTime:DBL_MAX];
    [owner window:owner.window willUseFullScreenPresentationOptions:0];
    assert(owner.nativeFullscreenEntering && owner.chromeFullscreenTransition && owner.fullscreenEntryStarted);
    assert(owner.fullscreenEntryDeadline==0 && owner.fullscreenEntryEpoch==currentEpoch && owner.fullscreenHeader.header==duringAnimation);
    [owner windowDidFailToEnterFullScreen:owner.window];
    assert(!owner.nativeFullscreenEntering && !owner.chromeFullscreenTransition && !owner.fullscreenHeader.header);
    [owner window:owner.window willUseFullScreenPresentationOptions:0];
    staleEpoch=owner.fullscreenEntryEpoch;CFTimeInterval exitDeadline=owner.fullscreenEntryDeadline;
    [owner windowWillExitFullScreen:[NSNotification notificationWithName:NSWindowWillExitFullScreenNotification object:owner.window]];
    [owner reconcileFullscreenEntryEpoch:staleEpoch atTime:exitDeadline];
    assert(owner.chromeFullscreenTransition && !owner.nativeFullscreenEntering && owner.fullscreenHeader.exiting);
    [owner windowDidFailToEnterFullScreen:owner.window];
    fprintf(stderr,"PASS controlled AppKit refusal, stale epoch, exit superseding entry and unbounded slow willEnter\n");
    [owner window:owner.window willUseFullScreenPresentationOptions:0];
    NSUInteger blockedEpoch=owner.fullscreenEntryEpoch;
    CFTimeInterval oldDeadline=owner.fullscreenEntryDeadline;
    [NSThread sleepForTimeInterval:MAX(0,oldDeadline-CACurrentMediaTime())+.02];
    [owner window:owner.window willUseFullScreenPresentationOptions:0];
    NSUInteger renewed=owner.fullscreenEntryEpoch;CFTimeInterval renewedDeadline=owner.fullscreenEntryDeadline;
    assert(renewed!=blockedEpoch && renewedDeadline>oldDeadline);
    [owner window:owner.window willUseFullScreenPresentationOptions:0];
    assert(owner.fullscreenEntryEpoch==renewed && owner.fullscreenEntryDeadline==renewedDeadline);
    __block BOOL drained=NO;dispatch_async(dispatch_get_main_queue(),^{drained=YES;});
    drainUntil(^BOOL { return drained; }); // Actual old watchdog was queued during main-thread blocking.
    [owner reconcileFullscreenEntryEpoch:blockedEpoch atTime:CACurrentMediaTime()];
    assert(owner.nativeFullscreenEntering && owner.fullscreenEntryEpoch==renewed && owner.fullscreenHeader.header);
    [owner windowDidFailToEnterFullScreen:owner.window];
    fprintf(stderr,"PASS actual main-thread deadline overrun: renewed epoch survives queued old watchdog; hooks never shorten deadline\n");
    macos_destroy_window(raw);
}

static id cornerRadius(NSWindow *window) {
    SEL selector=NSSelectorFromString(@"_cornerRadius");
    id target=[window respondsToSelector:selector] ? window : window.contentView.superview;
    NSMethodSignature *signature=[target methodSignatureForSelector:selector];
    if(!signature || strcmp(signature.methodReturnType,@encode(CGFloat)) || signature.numberOfArguments!=2) return NSNull.null;
    NSInvocation *invocation=[NSInvocation invocationWithMethodSignature:signature];
    invocation.target=target;invocation.selector=selector;[invocation invoke];
    CGFloat radius=0;[invocation getReturnValue:&radius];return @(radius);
}
static void snapshot(WindowWrapper *w,NSString *stage) {
    [w.window.contentView.superview layoutSubtreeIfNeeded];
    NSDictionary *data=@{@"stage":stage,@"radius":cornerRadius(w.window),@"toolbar":w.window.toolbar.identifier?:@"nil",@"style":@(w.window.toolbarStyle),@"accessories":@(w.window.titlebarAccessoryViewControllers.count),@"layout_height":@(w.window.contentLayoutRect.size.height),@"visible":@(w.window.visible)};
    puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:data options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
    assert(!w.window.visible);
}
// No renderer/display-link/poll is run during these idle-layout assertions.
static void assertWindowedInset(WindowWrapper *w) {
    assert(!w.fullscreenHeader.header && !w.displayLinkRunning);
    for(NSWindowButton kind=NSWindowCloseButton;kind<=NSWindowZoomButton;kind++) {
        NSButton *button=[w.window standardWindowButton:kind];
        NSRect rect=[w.metalView convertRect:button.bounds fromView:button];
        assert(fabs(w.metalView.bounds.size.height-NSMidY(rect)-w.trafficLightsInsetY)<.01);
        assert(fabs(button.frame.origin.x-(w.trafficLightsInsetX+kind*20))<.01);
    }
    assert(!w.applyingTrafficLightsInset);
}
static void overwriteButtonsWhileIdle(WindowWrapper *w) {
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(NSWindowButton kind=NSWindowCloseButton;kind<=NSWindowZoomButton;kind++) {
        NSButton *button=[w.window standardWindowButton:kind];
        // AppKit's actual _updateButtonPositions uses setFrameOrigin:.
        [button setFrameOrigin:NSMakePoint(9+kind*23,9)];
        assertWindowedInset(w); // Before setter caller/CA transaction returns.
        button.frame=NSOffsetRect(button.frame,2,3);
        assertWindowedInset(w); // Also cover the full-frame setter.
    }
    [CATransaction commit];
}
static void assertAccessoryOwnsButtons(WindowWrapper *w) {
    assert(w.fullscreenHeader.header);
    NSButton *button=[w.window standardWindowButton:NSWindowCloseButton];
    button.frame=NSOffsetRect(button.frame,2,3);NSRect nativeFrame=button.frame;
    [w applyTrafficLightsInset];assert(NSEqualRects(nativeFrame,button.frame));
    assert(!w.applyingTrafficLightsInset);
}
static void countRender(void *context) { (*(unsigned *)context)++; }
static void lifecycleIdempotence(WindowWrapper *w) {
    ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
    [host stop];[w finishFullscreenEntry];
    [host commitBodyLayout];assert(!host.body && !host.header);
    [host start];NSUInteger epoch=host.presentationEpoch;
    [host start];assert(host.presentationEpoch==epoch);
    [host commitBodyLayout];NSView *body=host.body,*header=host.header;
    NSRect frame=w.metalView.frame;CGSize drawable=w.metalView.metalLayer.drawableSize;
    [host commitBodyLayout];assert(host.body==body && host.header==header && NSEqualRects(w.metalView.frame,frame));
    assert(CGSizeEqualToSize(drawable,w.metalView.metalLayer.drawableSize));
    [host stop];[host stop];[host commitBodyLayout];assert(!host.header && !host.body);
    // No host configured: nil receivers are harmless; did-enter before policy
    // configure can later recover from the actual fullscreen state snapshot.
    void *raw=macos_create_window(640,400,"Hidden unconfigured lifecycle");
    WindowWrapper *other=(__bridge WindowWrapper *)raw;
    [other.fullscreenHeader start];[other.fullscreenHeader commitBodyLayout];
    [other windowDidEnterFullScreen:[NSNotification notificationWithName:NSWindowDidEnterFullScreenNotification object:other.window]];assert(!other.fullscreenHeader);
    assert(macos_fullscreen_header_configure(raw,2,38));
    zenitConfigureHeaderForFullscreenState(other,YES);
    assert(other.fullscreenHeader.active && other.fullscreenHeader.bodyReserveCommitted);
    macos_destroy_window(raw);
    // Host was reclaimed, then did-enter arrives without will: rebuild and
    // request first paint, even though no old frame request remains.
    assert(!host.frameRequested);
    [w windowDidEnterFullScreen:[NSNotification notificationWithName:NSWindowDidEnterFullScreenNotification object:w.window]];
    assert(host.header && host.active && host.bodyReserveCommitted);
    assert(macos_fullscreen_header_take_frame_request((__bridge void *)w)==1);
    assert(macos_fullscreen_header_take_frame_request((__bridge void *)w)==0);
    // Cancelling a restore intent while preserving an active host requests one
    // frame, without changing the native host or the body's committed geometry.
    NSView *preserved=host.header;NSRect stableFrame=w.metalView.frame;
    w.waitingForDeminiaturize=YES;
    [w cancelFullscreenRestoration:[NSNotification notificationWithName:NSApplicationDidResignActiveNotification object:NSApp]];
    assert(!w.waitingForDeminiaturize && host.active && host.header==preserved && NSEqualRects(w.metalView.frame,stableFrame));
    assert(macos_fullscreen_header_take_frame_request((__bridge void *)w)==1);
    assert(macos_fullscreen_header_take_frame_request((__bridge void *)w)==0);
    body=host.body;header=host.header;epoch=host.presentationEpoch;
    [w windowDidEnterFullScreen:[NSNotification notificationWithName:NSWindowDidEnterFullScreenNotification object:w.window]];
    assert(host.header==header && host.body==body && host.presentationEpoch==epoch);
    [host stop];[w finishFullscreenEntry];
    unsigned paints=0;RenderCallback saved=w.metalView.renderCallback;void *ctx=w.metalView.renderContext;
    w.metalView.renderCallback=countRender;w.metalView.renderContext=&paints;
    frame=w.metalView.frame;drawable=w.metalView.metalLayer.drawableSize;
    [w.metalView renderFinalResize];[w.metalView renderFinalResize];
    assert(NSEqualRects(w.metalView.frame,frame) && CGSizeEqualToSize(drawable,w.metalView.metalLayer.drawableSize));
    assert(paints==2); // An explicit final paint each call, no geometry/allocation change.
    w.metalView.renderCallback=saved;w.metalView.renderContext=ctx;
    // The exit callback must not clear a subsequent request even when the host
    // has not yet been configured (nil host has a constant presentation epoch).
    raw=macos_create_window(640,400,"Hidden async exit epoch");other=(__bridge WindowWrapper *)raw;
    [other windowDidExitFullScreen:[NSNotification notificationWithName:NSWindowDidExitFullScreenNotification object:other.window]];[other beginFullscreenEntry:YES];
    NSUInteger newEpoch=other.fullscreenEntryEpoch;
    __block BOOL done=NO;dispatch_async(dispatch_get_main_queue(),^{done=YES;});
    drainUntil(^BOOL { return done; });
    assert(other.fullscreenEntryEpoch==newEpoch && other.nativeFullscreenEntering && other.chromeFullscreenTransition);
    macos_destroy_window(raw);
    fprintf(stderr,"PASS idempotent host start/commit/finish, late didEnter recovery, unchanged final-resize geometry (two deliberate paints), async exit epoch isolation\n");
}

static NSWindow *closedMiniWindow;
static unsigned closedMiniCalls;
static IMP savedClosedMini;
static void trapClosedMini(NSWindow *window,SEL selector,id sender) {
    if(window==closedMiniWindow) closedMiniCalls++;
    else ((void(*)(id,SEL,id))savedClosedMini)(window,selector,sender);
}
static void assertMiniActionDispatch(WindowWrapper *w,unsigned expected) {
    closedMiniWindow=w.window;closedMiniCalls=0;
    Method mini=class_getInstanceMethod(NSWindow.class,@selector(miniaturize:));
    savedClosedMini=method_setImplementation(mini,(IMP)trapClosedMini);
    assert(macos_chrome_action((__bridge void *)w,1,0) && closedMiniCalls==expected);
    method_setImplementation(mini,savedClosedMini);closedMiniWindow=nil;
}
static void closeDuringEntry(void) {
    void *raw=macos_create_window(640,400,"Hidden close during entry");
    WindowWrapper *w=(__bridge WindowWrapper *)raw;
    assertMiniActionDispatch(w,1); // Unordered but open windows still dispatch.
    assert(macos_chrome_configure(raw,1,1,38));assert(macos_fullscreen_header_configure(raw,2,38));
    [w windowWillEnterFullScreen:[NSNotification notificationWithName:NSWindowWillEnterFullScreenNotification object:w.window]];
    assert(w.fullscreenEntryStarted && w.nativeFullscreenEntering && w.chromeFullscreenTransition);
    assert(w.fullscreenHeader.observedButtons.count && w.trafficLightsObservedViews.count);
    [w.fullscreenHeader commitBodyLayout];
    NSView *header=w.fullscreenHeader.header,*body=w.window.contentView,*parent=w.metalView.superview;
    NSToolbar *toolbar=w.window.toolbar;
    NSRect frame=w.metalView.frame;NSUInteger accessories=w.window.titlebarAccessoryViewControllers.count;
    NSUInteger oldEpoch=w.fullscreenEntryEpoch;
    // Real native close of an unordered window, deliberately bypassing the Zig
    // close/destroy pump. The delegate must clean up before eventual destroy.
    [w.window close];
    assert(w.nativeCloseObserved && !w.nativeFullscreenEntering && !w.chromeFullscreenTransition);
    assert(!w.fullscreenEntryStarted && !w.fullscreenEntryDeadline && !w.waitingForDeminiaturize);
    assert(w.fullscreenHeader.header==header && !w.fullscreenHeader.active && !w.fullscreenHeader.pendingFullscreen && !w.fullscreenHeader.frameRequested);
    assert(w.window.contentView==body && w.metalView.superview==parent && w.window.toolbar==toolbar);
    assert(w.window.titlebarAccessoryViewControllers.count==accessories && NSEqualRects(w.metalView.frame,frame));
    [body setNeedsLayout:YES];[body layoutSubtreeIfNeeded];
    assert(NSEqualRects(w.metalView.frame,frame)); // Own layout also freezes during native close.
    assert(!w.fullscreenHeader.observedButtons.count && !w.trafficLightsObservedViews.count);
    NSUInteger closedEpoch=w.fullscreenEntryEpoch;
    [w reconcileFullscreenEntryEpoch:oldEpoch atTime:DBL_MAX];
    [w windowWillEnterFullScreen:[NSNotification notificationWithName:NSWindowWillEnterFullScreenNotification object:w.window]];
    [w windowDidEnterFullScreen:[NSNotification notificationWithName:NSWindowDidEnterFullScreenNotification object:w.window]];
    [w windowWillExitFullScreen:[NSNotification notificationWithName:NSWindowWillExitFullScreenNotification object:w.window]];
    [w windowDidFailToEnterFullScreen:w.window];[w windowDidFailToExitFullScreen:w.window];
    [w window:w.window willUseFullScreenPresentationOptions:0];[w customWindowsToEnterFullScreenForWindow:w.window];
    // Probe removal of the application observer without invoking its selector:
    // an artificial waiting bit must survive the notification, then is reset.
    w.waitingForDeminiaturize=YES;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidResignActiveNotification object:NSApp];
    assert(w.waitingForDeminiaturize);w.waitingForDeminiaturize=NO;
    assert(!macos_chrome_action(raw,3,1) && !zenitPrepareFullscreen(w.window));
    [w.fullscreenHeader prepare];[w.fullscreenHeader start];
    float closedOffsetX,closedOffsetY;macos_fullscreen_header_layout(raw,0,&closedOffsetX,&closedOffsetY);
    assert(w.fullscreenEntryEpoch==closedEpoch && w.fullscreenHeader.header==header && !w.chromeFullscreenTransition);
    assert(w.window.contentView==body && w.metalView.superview==parent && w.window.toolbar==toolbar);
    assert(macos_chrome_action(raw,0,0) && w.shouldClose);w.shouldClose=NO;
    // Dispatch to miniaturize is tested at its NSWindow boundary: never order a
    // Dock animation or window in this background fixture.
    assertMiniActionDispatch(w,0); // Closed and invisible is a handled no-op.
    assert(!macos_chrome_action(raw,3,1));
    assert(!w.fullscreenHeader.observedButtons.count && !w.trafficLightsObservedViews.count);
    assert(!w.window.visible && !NSApp.keyWindow);
    macos_destroy_window(raw);
    assert(!w.fullscreenHeader.header && !w.fullscreenHeader.body);
    assert(body.superview==nil || body.window.contentView==body); // No reparent by discard.
    fprintf(stderr,"PASS real hidden close after will: flags/observers released with view tree frozen, late delegates cannot restart, discard never restores hierarchy, close dispatches and closed-invisible minimize is a no-op\n");
}

static void detachedHeaderCallbacks(void) {
    ZenitHeaderBodyView *orphan=[ZenitHeaderBodyView new];
    [orphan layout];assert(!orphan.bodyMask); // No host, including after weak zeroing.
    for(int reason=0;reason<3;reason++) {
        void *raw=macos_create_window(640,400,"Hidden detached snapshot");
        WindowWrapper *w=(__bridge WindowWrapper *)raw;
        assert(macos_fullscreen_header_configure(raw,2,38));
        ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
        [host prepare];host.pendingFullscreen=YES;
        HeaderFixtureBuffer *buffer=[HeaderFixtureBuffer new];
        allowTextureCopies=YES;
        [host encodeTexture:(id)fixtureSource(w) commandBuffer:(id)buffer revision:1];
        allowTextureCopies=NO;assert(buffer.handlers.count==1);
        NSUInteger generation=host.generation;uint32_t chromeGeneration=w.chromeStateGeneration;
        if(reason==0) host.owner=nil;
        else if(reason==1) w.nativeCloseObserved=YES; // Test owner guard independently of generation.
        else [host quiesceForClose]; // Late completion must also respect invalidation.
        [buffer complete];
        __block BOOL drained=NO;dispatch_async(dispatch_get_main_queue(),^{drained=YES;});
        drainUntil(^BOOL {return drained;});
        assert(!host.windowedPaintReady && !host.retainedPaint.contents && !host.frameRequested && !host.body);
        assert(w.chromeStateGeneration==chromeGeneration);
        assert(reason==2 ? host.generation!=generation : host.generation==generation);
        host.owner=w;w.nativeCloseObserved=NO;
        macos_destroy_window(raw);
    }
    fprintf(stderr,"PASS nil-host layout and snapshot completion reject nil/closed owner or stale generation without publication/frame request\n");
}

static void idleWindowEvents(WindowWrapper *w) {
    unsigned frames=0;RenderCallback saved=w.metalView.renderCallback;void *savedContext=w.metalView.renderContext;
    w.metalView.renderCallback=countRender;w.metalView.renderContext=&frames;
    assertWindowedInset(w);overwriteButtonsWhileIdle(w);
    // Deliver key delegate notifications only: never order/activate a window
    // or change the user's real key window in this unattended fixture.
    [w windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:w.window]];
    overwriteButtonsWhileIdle(w);
    [w windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:w.window]];
    overwriteButtonsWhileIdle(w);
    for(NSAppearanceName name in @[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]) {
        w.window.appearance=[NSAppearance appearanceNamed:name];
        [w.window.contentView.superview layoutSubtreeIfNeeded];
        overwriteButtonsWhileIdle(w);
    }
    NSSize original=w.metalView.bounds.size;
    [w.window setContentSize:NSMakeSize(original.width+20,original.height+20)];
    assertWindowedInset(w); // Real _tileTitlebarAndRedisplay, no poll.
    [w.window setContentSize:original];assertWindowedInset(w);
    assert(!w.window.visible && !NSApp.keyWindow && frames==0);
    w.metalView.renderCallback=saved;w.metalView.renderContext=savedContext;
}
int main(int argc,char **argv) { @autoreleasepool {
    NSArray<NSView *> *observed;NSArray<NSNumber *> *previous;
    __weak WindowWrapper *weakOwner;
    @autoreleasepool {
    setenv("ZENIT_E2E_BACKGROUND","1",1);
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    installFixtureDispatch();
    actualAppKitCaptureHook();closeDuringEntry();detachedHeaderCallbacks();
    void *raw=macos_create_window(980,600,"Hidden header lifecycle");
    WindowWrapper *w=(__bridge WindowWrapper *)raw;
    assert(macos_chrome_configure(raw,1,1,38));
    snapshot(w,@"hidden-policy");
    id originalRadius=cornerRadius(w.window);
    NSToolbar *original=w.window.toolbar;NSWindowToolbarStyle originalStyle=w.window.toolbarStyle;
    NSUInteger accessories=w.window.titlebarAccessoryViewControllers.count;
    assert(macos_fullscreen_header_configure(raw,2,38));
    snapshot(w,@"pinned-configured");
    NSButton *close=[w.window standardWindowButton:NSWindowCloseButton];
    idleWindowEvents(w);
    NSRect normalized=close.frame;
    float offsetX,offsetY;macos_fullscreen_header_layout(raw,0,&offsetX,&offsetY);
    assert(normalized.origin.x==7 && offsetX==0 && offsetY==0);
    assert(NSEqualRects(normalized,close.frame));
    if(argc>1 && !strcmp(argv[1],"--measure")) {
        assert(macos_fullscreen_header_configure(raw,0,38));snapshot(w,@"pinned-disabled");
        macos_destroy_window(raw);restoreFixtureDispatch();return 0;
    }
    assert(w.window.toolbar==original && w.window.toolbarStyle==originalStyle);
    assert([cornerRadius(w.window) isEqual:originalRadius]);
    assert(w.window.titlebarAccessoryViewControllers.count==accessories && !w.fullscreenHeader.header);
    // Exercise the actual pre-capture hook. An unpainted header returns NO,
    // delaying the real Space request until the two-frame retained-paint gate.
    assert(!zenitPrepareFullscreen(w.window));
    assert(w.fullscreenHeader.pendingFullscreen && !w.fullscreenHeader.active);
    assert([w.window.toolbar.identifier isEqual:@"dev.zenit.fullscreen-header"]);
    assert(w.window.titlebarAccessoryViewControllers.count==accessories+1);
    snapshot(w,@"prepared-before-capture");
    // Prepared accessory ownership: windowed observer must not countermand it.
    assertAccessoryOwnsButtons(w);
    [w.fullscreenHeader finishExit];w.chromeFullscreenTransition=NO;
    idleWindowEvents(w);
    assert(w.window.toolbar==original && w.window.toolbarStyle==originalStyle);
    assert([cornerRadius(w.window) isEqual:originalRadius]);
    assert(w.window.titlebarAccessoryViewControllers.count==accessories && !w.fullscreenHeader.pendingFullscreen);
    snapshot(w,@"cancelled-preparation");
    lifecycleIdempotence(w);nativeActionDispatch(w);minimizedEntryRequest(w);
    unsigned beforeRequests=enteredRequests;
    assert(macos_chrome_action(raw,3,1));
    assert(w.fullscreenHeader.pendingFullscreen && w.chromeFullscreenTransition);
    NSUInteger pendingEpoch=w.fullscreenHeader.presentationEpoch;
    // Reconfiguration during prewarm must not prematurely start the host.
    assert(!w.nativeFullscreenEntering && macos_fullscreen_header_configure(raw,2,38));
    assert(w.fullscreenHeader.pendingFullscreen && !w.fullscreenHeader.active);
    CFTimeInterval prewarmDeadline=w.fullscreenHeader.pendingDeadline;
    assert(prewarmDeadline>CACurrentMediaTime());
    unsetenv("ZENIT_E2E_BACKGROUND");
    assert(macos_should_render_window(raw)==1);
    w.fullscreenHeader.pendingDeadline=CACurrentMediaTime()-1;
    assert(macos_should_render_window(raw)==0); // No unbounded occlusion bypass.
    // The RPC visual suite can render the hidden window without ordering it front.
    setenv("ZENIT_E2E_BACKGROUND","1",1);
    assert(!w.window.visible && macos_should_render_window(raw)==1);
    w.fullscreenHeader.pendingDeadline=prewarmDeadline;
    assert(macos_fullscreen_header_take_frame_request(raw)==1);
    assert(macos_fullscreen_header_take_frame_request(raw)==0);
    assert(macos_chrome_action(raw,3,1));[w.window toggleFullScreen:nil];
    assert(w.fullscreenHeader.pendingFullscreen && w.fullscreenHeader.presentationEpoch==pendingEpoch);
    assert(enteredRequests==beforeRequests);
    NSButton *pendingClose=[w.window standardWindowButton:NSWindowCloseButton];
    pendingClose.frame=NSOffsetRect(pendingClose.frame,2,3);
    assert(pendingClose.frame.origin.x==w.trafficLightsInsetX); // Pending still keeps windowed inset.
    w.fullscreenHeader.windowedCapturePending=YES; // Also abandon a never-completed warmup slot at handoff.
    // No renderer runs. A hidden/occluded window still hands exactly one
    // accepted entry to the native boundary when bounded prewarm expires.
    drainUntil(^BOOL { return enteredRequests==beforeRequests+1; });
    assert(!w.fullscreenHeader.pendingFullscreen && !w.fullscreenHeader.windowedCapturePending);
    assert(w.fullscreenHeader.active && !w.chromeFullscreenTransition);
    assert([objc_getAssociatedObject(w.window,&simulatedFullscreenKey) boolValue]);
    assert(w.fullscreenHeader.frameRequested && !w.fullscreenHeader.hasPresented);
    snapshot(w,@"preparation-timeout-entered-unpainted");
    fixtureNativeToggle(w.window,@selector(toggleFullScreen:),nil);
    drainUntil(^BOOL { return !w.fullscreenHeader.header; });
    assert(w.window.toolbar==original && w.window.toolbarStyle==originalStyle);
    snapshotCaptureWhileHidden(w);
    // Explicit set-windowed cancels one queued request; stale timeout must not enter.
    assert(macos_chrome_action(raw,3,1));assert(macos_chrome_action(raw,3,0));
    assert(!w.fullscreenHeader.header && !w.fullscreenHeader.pendingFullscreen && !w.chromeFullscreenTransition);
    NSDate *cancelDeadline=[NSDate dateWithTimeIntervalSinceNow:.3];
    while(cancelDeadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(enteredRequests==beforeRequests+1);
    // A path which bypasses toggle can configure the host after will-enter.
    [w windowWillEnterFullScreen:[NSNotification notificationWithName:NSWindowWillEnterFullScreenNotification object:w.window]];
    // Existing host is configured here; also test a genuinely missing host below.
    [w.fullscreenHeader stop];w.chromeFullscreenTransition=NO;w.nativeFullscreenEntering=NO;
    // A host-supplied toolbar must survive replacement, restoration and repeat
    // cycles, including when the caller drops its own strong reference.
    NSToolbar *custom=[[NSToolbar alloc] initWithIdentifier:@"host-owned-toolbar"];
    w.window.toolbar=custom;w.window.toolbarStyle=NSWindowToolbarStyleExpanded;
    w.window.toolbar.visible=NO;id customRadius=cornerRadius(w.window);
    __weak NSToolbar *weakToolbar=custom;custom=nil;
    void *raw2=macos_create_window(760,480,"Other hidden window");
    WindowWrapper *other=(__bridge WindowWrapper *)raw2;
    assert(!other.fullscreenHeader);
    [other customWindowsToEnterFullScreenForWindow:other.window];
    assert(other.nativeFullscreenEntering);
    assert(macos_fullscreen_header_configure(raw2,2,38));
    assert(other.fullscreenHeader.active && other.fullscreenHeader.frameRequested);
    [other.fullscreenHeader stop];other.nativeFullscreenEntering=NO;other.chromeFullscreenTransition=NO;
    assert(macos_fullscreen_header_configure(raw2,2,38));
    zenitConfigureHeaderForFullscreenState(other,YES); // A restored native-state snapshot.
    assert(other.fullscreenHeader.active && other.fullscreenHeader.bodyReserveCommitted && other.fullscreenHeader.frameRequested);
    [other.fullscreenHeader stop];
    for(int cycle=0;cycle<2;cycle++) {
        assert(macos_fullscreen_header_configure(raw,2,38));
        assert(w.window.toolbar==weakToolbar && w.window.toolbarStyle==NSWindowToolbarStyleExpanded);
        [w.fullscreenHeader prepare];
        assert(weakToolbar && weakToolbar==w.fullscreenHeader.savedToolbar);
        assert(!other.window.toolbar && !other.fullscreenHeader.header);
        [w.fullscreenHeader start];assertAccessoryOwnsButtons(w);
        [w.fullscreenHeader commitBodyLayout];CGFloat frozenReserve=w.fullscreenHeader.bodyReserve;
        [w.fullscreenHeader beginExit];assertAccessoryOwnsButtons(w);
        [w windowDidFailToExitFullScreen:w.window];
        assert(w.fullscreenHeader.active && !w.fullscreenHeader.exiting && w.fullscreenHeader.savedToolbar==weakToolbar);
        assert(!w.fullscreenHeader.pendingFullscreen && !w.chromeFullscreenTransition);
        assert(w.fullscreenHeader.bodyReserveCommitted && w.fullscreenHeader.bodyReserve==frozenReserve);
        assert(!w.fullscreenHeader.hasPresented && w.fullscreenHeader.frameRequested);
        [w.fullscreenHeader beginExit];[w.fullscreenHeader finishExit];
        assert(w.window.toolbar==weakToolbar && !weakToolbar.visible);
        assert(w.window.toolbarStyle==NSWindowToolbarStyleExpanded);
        assert([cornerRadius(w.window) isEqual:customRadius]);
        assert(w.window.titlebarAccessoryViewControllers.count==accessories);
        assert(!w.fullscreenHeader.savedToolbar && !w.fullscreenHeader.header && !w.fullscreenHeader.body);
        assertWindowedInset(w);overwriteButtonsWhileIdle(w);
        snapshot(w,@"host-toolbar-restored");
    }
    // A consumer toolbar installed after prepare wins, including its style
    // and visibility. Neither update nor stop may undo that consumer change.
    NSToolbar *preservedCustom=weakToolbar;
    [w.fullscreenHeader prepare];NSToolbar *replacement=[[NSToolbar alloc] initWithIdentifier:@"replacement-toolbar"];
    w.window.toolbar=replacement;w.window.toolbarStyle=NSWindowToolbarStyleExpanded;replacement.visible=NO;
    [w.fullscreenHeader update];assert(!replacement.visible);
    [w.fullscreenHeader stop];assert(w.window.toolbar==replacement && w.window.toolbarStyle==NSWindowToolbarStyleExpanded && !replacement.visible);
    w.window.toolbar=preservedCustom;w.window.toolbarStyle=NSWindowToolbarStyleExpanded;weakToolbar.visible=NO;
    // The normal did-exit delegate keeps its deferred atomic final-paint
    // transaction. Once restored, a later AppKit write is fixed without poll.
    [w.fullscreenHeader prepare];[w.fullscreenHeader start];
    float closedOffsetX,closedOffsetY;macos_fullscreen_header_layout(raw,0,&closedOffsetX,&closedOffsetY);[w.fullscreenHeader beginExit];
    [w windowDidExitFullScreen:[NSNotification notificationWithName:NSWindowDidExitFullScreenNotification object:w.window]];
    NSDate *exitDeadline=[NSDate dateWithTimeIntervalSinceNow:1];
    while(w.fullscreenHeader.header && exitDeadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(!w.fullscreenHeader.header && !w.chromeFullscreenTransition);
    overwriteButtonsWhileIdle(w);
    // Delegate failure cleanup uses the same restoration path.
    [w.fullscreenHeader prepare];[w windowDidFailToEnterFullScreen:w.window];
    assert(w.window.toolbar==weakToolbar && w.window.toolbarStyle==NSWindowToolbarStyleExpanded);
    assert(!w.fullscreenHeader.header && !w.chromeFullscreenTransition);
    assert(!w.window.visible && !other.window.visible && !NSApp.keyWindow);
    // Observer teardown restores notification settings and cannot receive a
    // dangling callback if a caller retains one of the native button views.
    observed=w.trafficLightsObservedViews;
    previous=w.trafficLightsPreviousFrameNotifications;
    weakOwner=w;
    macos_destroy_window(raw2);macos_destroy_window(raw);w=nil;other=nil;
    restoreFixtureDispatch();
    } // Drain callback/lookup autoreleases before checking owner lifetime.
    assert(!weakOwner);
    for(NSUInteger i=0;i<observed.count;i++) {
        assert(observed[i].postsFrameChangedNotifications==previous[i].boolValue);
        observed[i].frame=NSOffsetRect(observed[i].frame,1,1);
    }
    fprintf(stderr,"PASS: deferred header install, pre-capture gate, nil/custom toolbar restoration, repeat cycles, failure, per-window ownership and synchronous idle insets, queued entry/fallback, late configure and cached snapshots\n");
} return 0; }
