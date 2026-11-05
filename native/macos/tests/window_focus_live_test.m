// Real AppKit focus transitions between our own probe processes. No CGEvents.
// Run only during an arranged foreground acceptance session.
#ifndef ZENIT_WINDOW_BRIDGE_SOURCE
#define ZENIT_WINDOW_BRIDGE_SOURCE "../window_bridge.m"
#endif
#import ZENIT_WINDOW_BRIDGE_SOURCE
#include "empty_a11y.inc"
#include "no_render_copy.inc"
uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w,uint64_t s,char*b,int n) { return 0; }
int zenit_text_input_selection(uint32_t w,uint32_t*s,uint32_t*e,uint32_t*c) { return 0; }
int zenit_text_input_frame(uint32_t w,uint32_t s,uint32_t e,float*x,float*y,float*a,float*b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w,float x,float y,uint32_t*s,uint32_t*e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w,uint64_t o) { return o; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w,uint64_t o) { return o; }
#ifdef ZENIT_WINDOW_BASELINE
static void macos_restore_key_window(void *w) { macos_make_key_window(w); }
#endif
static int resignCount, lastLoss;
static void onLoss(void *ctx,int same) { resignCount++; lastLoss=same; }
static void check(BOOL condition,NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"AcceptanceFailure" reason:message userInfo:nil];
}
static void tick(void) { macos_pump_app_events_timeout(10); }
static pid_t front(void) { return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; }
static void awaitFront(pid_t pid) {
    for(int i=0;i<400 && front()!=pid;i++) tick();
    check(front()==pid,@"foreground activation did not settle");
}
int main(int argc,char **argv) { @autoreleasepool {
    unsetenv("ZENIT_E2E_BACKGROUND");
    if(argc>1 && !strcmp(argv[1],"--helper")) {
        macos_init_app();
        void *window=macos_create_window(320,180,"Zenit external-app acceptance helper");
        NSString *stop=[NSString stringWithUTF8String:argv[2]];
        for(int i=0;i<6000 && ![[NSFileManager defaultManager] fileExistsAtPath:stop];i++) tick();
        macos_destroy_window(window);return 0;
    }
    check(argc==2,@"expected evidence directory");
    NSRunningApplication *previous=NSWorkspace.sharedWorkspace.frontmostApplication;
    NSString *dir=[NSString stringWithUTF8String:argv[1]];
    NSString *stop=[dir stringByAppendingPathComponent:@"helper-stop"];
    [[NSFileManager defaultManager] removeItemAtPath:stop error:nil];
    void *owner=NULL,*panel=NULL; NSTask *helper=nil; int status=0;
    @try {
        macos_init_app();owner=macos_create_window(640,440,"Zenit focus acceptance owner");
        panel=macos_create_window_borderless(360,240,"Zenit focus acceptance panel");
        macos_add_child_window(owner,panel);macos_make_key_window(panel);
        macos_set_resign_key_callback(panel,onLoss,&resignCount);
        awaitFront(getpid());for(int i=0;i<10;i++) tick();
        WindowWrapper *ow=(__bridge WindowWrapper *)owner,*pw=(__bridge WindowWrapper *)panel;
        check(pw.window.isKeyWindow,@"panel did not acquire native key window");
        macos_make_key_window(owner);for(int i=0;i<10;i++) tick();
        check(resignCount>0 && lastLoss==1,@"same-app owner handoff not reported");
        macos_make_key_window(panel);for(int i=0;i<10;i++) tick();
        helper=[NSTask new];helper.executableURL=[NSURL fileURLWithPath:@(argv[0])];
        helper.arguments=@[@"--helper",stop];NSError *error=nil;
        check([helper launchAndReturnError:&error],error.description?:@"helper launch failed");
        awaitFront(helper.processIdentifier);for(int i=0;i<10;i++) tick();
        check(lastLoss==0,@"external app deactivation was classified as same-app");
        for(int i=0;i<30;i++) {
            macos_make_key_window(panel);tick();
            fprintf(stderr,"TRACE focus retry=%d front=%d self=%d helper=%d key=%ld active=%d\n",i,front(),getpid(),helper.processIdentifier,(long)NSApp.keyWindow.windowNumber,NSApp.isActive);
            check(front()==helper.processIdentifier,@"deferred make-key stole desktop activation");
        }
        macos_destroy_window(panel);panel=NULL;
        macos_restore_key_window(owner);for(int i=0;i<10;i++) tick();
        check(front()==helper.processIdentifier,@"close handoff stole desktop activation");
        [NSApp activateIgnoringOtherApps:YES];[ow.window makeKeyAndOrderFront:nil];awaitFront(getpid());
        panel=macos_create_window_borderless(360,240,"Zenit focus acceptance replacement");
        macos_add_child_window(owner,panel);macos_make_key_window(panel);for(int i=0;i<10;i++) tick();
        macos_destroy_window(panel);panel=NULL;macos_restore_key_window(owner);for(int i=0;i<10;i++) tick();
        check(ow.window.isKeyWindow,@"active owner did not regain native key focus");
        fprintf(stderr,"PASS live same-app handoff, external-app retry/close isolation, owner recovery\n");
    } @catch(NSException *e) {fprintf(stderr,"FAIL %s\n",e.reason.UTF8String);status=1;}
    @finally {
        if(panel) macos_destroy_window(panel);if(owner) macos_destroy_window(owner);
        [@"stop" writeToFile:stop atomically:YES encoding:NSUTF8StringEncoding error:nil];
        for(int i=0;i<200 && helper.running;i++) tick();
        if(helper.running) [helper terminate];
        if(previous) [previous activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    }
    return status;
} }
