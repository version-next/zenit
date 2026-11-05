// Executes the real bridge against message-recording AppKit boundary objects.
// No NSApplication, NSWindow, Metal device, foreground changes or global input.
#import "../window_bridge.m"
#include "empty_a11y.inc"
#include "no_render_copy.inc"
#include <assert.h>
uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w,uint64_t s,char*b,int n) { return 0; }
int zenit_text_input_selection(uint32_t w,uint32_t*s,uint32_t*e,uint32_t*c) { return 0; }
int zenit_text_input_frame(uint32_t w,uint32_t s,uint32_t e,float*x,float*y,float*a,float*b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w,float x,float y,uint32_t*s,uint32_t*e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w,uint64_t o) { return o; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w,uint64_t o) { return o; }

@interface FocusWindowProbe : NSObject
@property NSInteger windowNumber;
@property NSUInteger orders;
@end
@implementation FocusWindowProbe
- (void)makeKeyAndOrderFront:(id)sender { self.orders++; }
@end
@interface FocusAppProbe : NSObject
@property BOOL active;
@property NSUInteger activations;
@property(strong) NSWindow *keyWindow;
@end
@implementation FocusAppProbe
- (BOOL)isActive { return self.active; }
- (void)activateIgnoringOtherApps:(BOOL)force { self.activations++; }
@end

static int calls, loss;
static void onLoss(void *ctx, int same) { calls++; loss=same; }
static void drain(void) {
    __block BOOL done=NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done=YES; });
    for (int i=0; i<100 && !done; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.001,YES);
    assert(done);
}
int main(int argc, char **argv) { @autoreleasepool {
    unsetenv("ZENIT_E2E_BACKGROUND");
    FocusAppProbe *app=[FocusAppProbe new]; NSApp=(NSApplication *)app;
    FocusWindowProbe *target=[FocusWindowProbe new]; target.windowNumber=101;
    FocusWindowProbe *owner=[FocusWindowProbe new]; owner.windowNumber=102;
    WindowWrapper *w=[WindowWrapper new]; w.window=(NSWindow *)target;
    w.ownerWindow=(NSWindow *)owner; w.resignKeyCallback=onLoss; w.resignKeyContext=&calls;
    const char *which=argc>1?argv[1]:"retry";
    if (!strcmp(which,"retry")) {
        // A delayed make-key/retry after the user left the app is not activation consent.
        app.active=NO; macos_make_key_window((__bridge void *)w);
        assert(app.activations==0 && target.orders==0);
        app.active=YES; macos_make_key_window((__bridge void *)w);
        assert(app.activations==0 && target.orders==1);
    } else if (!strcmp(which,"resign")) {
        // AppKit may retain its old keyWindow while deactivating. Matching the owner
        // alone must not dismiss the panel and begin a close/focus-handoff chain.
        app.active=NO; app.keyWindow=(NSWindow *)owner;
        [w windowDidResignKey:nil]; drain();
        assert(calls==1 && loss==0);
        app.active=YES; [w windowDidResignKey:nil]; drain();
        assert(calls==2 && loss==1);
        [w windowDidResignKey:nil]; [w windowDidBecomeKey:nil]; drain();
        assert(calls==2); // superseded delayed callback must not dismiss the panel
    } else if (!strcmp(which,"destroy")) {
        g_requested_key_window=101; unregisterWindowWrapper((NSWindow *)target);
        assert(g_requested_key_window==0);
    } else if (!strcmp(which,"handoff")) {
        app.active=NO; macos_restore_key_window((__bridge void *)w);
        assert(app.activations==0 && target.orders==0);
        app.active=YES; app.keyWindow=(NSWindow *)owner;
        macos_restore_key_window((__bridge void *)w);
        assert(target.orders==0);
        app.keyWindow=nil; macos_restore_key_window((__bridge void *)w);
        assert(target.orders==1 && app.activations==0);
        w.nativeCloseStarted=YES; macos_restore_key_window((__bridge void *)w);
        assert(target.orders==1);
    } else return 2;
    fprintf(stderr,"PASS window focus policy %s\n",which);
    NSApp=nil;
    return 0;
} }
