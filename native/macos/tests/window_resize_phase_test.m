// Real MetalView lifecycle, no OS mouse drag: deliberately overlap an old
// queued resize-end with a new resize-start before returning to the main loop.
#ifndef ZENIT_WINDOW_BRIDGE_SOURCE
#define ZENIT_WINDOW_BRIDGE_SOURCE "../window_bridge.m"
#endif
#import ZENIT_WINDOW_BRIDGE_SOURCE
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
static unsigned frames;
static void render(void *ctx) { frames++; }
static void drain(void) {
    __block BOOL done=NO;dispatch_async(dispatch_get_main_queue(),^{done=YES;});
    for(int i=0;i<100 && !done;i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.001,YES);
    assert(done);
}
int main(void) { @autoreleasepool {
    setenv("ZENIT_E2E_BACKGROUND","1",1);macos_init_app();
    void *raw=macos_create_window(640,440,"Zenit resize-phase acceptance");assert(raw);
    WindowWrapper *wrapper=(__bridge WindowWrapper *)raw;
    MetalView *view=wrapper.metalView;view.renderCallback=render;
    // An undrawn resize step must keep the previous frame at the top-left at
    // its own size (no kCAGravityResize stretch) over the content background.
    fprintf(stderr,"TRACE placement=%ld gravity=%s flipped=%d geometryFlipped=%d\n",(long)view.layerContentsPlacement,
        view.metalLayer.contentsGravity.UTF8String,view.isFlipped,view.metalLayer.geometryFlipped);
    assert(view.layerContentsPlacement==NSViewLayerContentsPlacementTopLeft);
    assert([view.metalLayer.contentsGravity isEqualToString:kCAGravityTopLeft]);
    assert(!view.isFlipped && !view.metalLayer.geometryFlipped); // TopLeft = max-Y = visual top
    macos_set_surface_background((__bridge void *)view,0.25f,0.5f,0.75f,1.0f);
    const CGFloat *bg=CGColorGetComponents(view.metalLayer.backgroundColor);
    assert(CGColorGetNumberOfComponents(view.metalLayer.backgroundColor)==4);
    assert(bg[0]==0.25 && bg[1]==0.5 && bg[2]==0.75 && bg[3]==1.0);
    [view viewWillStartLiveResize];
    [view viewDidEndLiveResize]; // completion remains queued
    [view viewWillStartLiveResize];
    drain();
    fprintf(stderr,"TRACE second resize transaction=%d inLiveResize=%d frames=%u\n",view.metalLayer.presentsWithTransaction,view.inLiveResize,frames);
    assert(view.metalLayer.presentsWithTransaction && frames==0);
    [view viewDidEndLiveResize];drain();
    assert(!view.metalLayer.presentsWithTransaction && frames==1);
    // AppKit re-derives gravity on geometry changes; placement must survive.
    macos_set_window_size(raw,700,500);
    assert([view.metalLayer.contentsGravity isEqualToString:kCAGravityTopLeft]);
    const NSSize sizes[]={{800,600},{1200,780},{760,480},{980,600}};
    for(int i=0;i<4;i++) {
        macos_set_window_size(raw,(int)sizes[i].width,(int)sizes[i].height);
        [view renderFinalResize];
        int w=0,h=0,pw=0,ph=0;macos_get_window_size(raw,&w,&h);
        macos_get_drawable_size((__bridge void *)view,&pw,&ph);
        CGFloat scale=macos_get_scale_factor(raw);
        fprintf(stderr,"TRACE resize logical=%dx%d pixels=%dx%d layer=%.1fx%.1f scale=%.1f\n",w,h,pw,ph,view.metalLayer.drawableSize.width,view.metalLayer.drawableSize.height,scale);
        assert(w==(int)sizes[i].width && h==(int)sizes[i].height);
        assert(pw==(int)(w*scale) && ph==(int)(h*scale));
        assert(view.metalLayer.drawableSize.width==pw && view.metalLayer.drawableSize.height==ph);
    }
    // Queued completion after teardown must not call the released client.
    [view viewDidEndLiveResize];macos_destroy_window(raw);unsigned before=frames;drain();assert(frames==before);
    fprintf(stderr,"PASS resize generation, final frame, four native geometries, top-left placement and closed callback\n");
    return 0;
} }
