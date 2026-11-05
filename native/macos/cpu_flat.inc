// CPU rasterizer for opaque damage patches (see src/zenit_app/cpu_patch.zig).
// Executes the encoder's own SDF / glyph / icon instances with the Metal
// shaders' coverage, AA and blend arithmetic, so a patch matches the GPU frame.
// Supported: rectangles (uniform/per-side borders, axis/diagonal two-colour
// gradients), rectangular and single rounded clips, crisp grayscale glyphs and
// snapped R8 icons. Unsupported input fails and the caller renders on the GPU.
// Ported from the cooperative-frame experiment; the drawable frame target is
// replaced by a window-positioned IOSurface patch.
#import <IOSurface/IOSurface.h>
#import <QuartzCore/CATransaction.h>
#include <math.h>

static bool cpuFlatEnabled;
static bool cpuFlatOptimized,cpuFlatStaging,cpuFlatTrace,cpuFlatInterior,cpuFlatGradientRows,cpuFlatRowAa,cpuFlatRectProfile;
static _Atomic(uint64_t) cpuFlatRectProfileEligible;
static pthread_once_t cpuFlatOnce=PTHREAD_ONCE_INIT;
static _Atomic(uint64_t) cpuFlatBorderSkippedPixels;
static _Atomic(uint64_t) cpuFlatFrames,cpuFlatGlyphs,cpuFlatBridgeSubmissions,cpuFlatAtlasReads,cpuFlatCacheHits,cpuFlatFillBytes,cpuFlatUnmaskedGlyphs,cpuFlatIntegerGlyphs,cpuFlatBackingBytes,cpuFlatCopyBytes,cpuFlatInteriorPixels,cpuFlatGradientPixels,cpuFlatGradientCoveragePixels,cpuFlatRowAaPixels;
static void initCpuFlat(void){const char *v=getenv("ZENIT_EXPERIMENT_CPU_FLAT");cpuFlatEnabled=v&&!strcmp(v,"1");v=getenv("ZENIT_CPU_PATCH_OPTIMIZED");cpuFlatOptimized=!(v&&!strcmp(v,"0"));v=getenv("ZENIT_EXPERIMENT_CPU_FLAT_STAGING");cpuFlatStaging=v&&!strcmp(v,"1");v=getenv("ZENIT_EXPERIMENT_CPU_FLAT_TRACE");cpuFlatTrace=v&&!strcmp(v,"1");v=getenv("ZENIT_EXPERIMENT_CPU_FLAT_INTERIOR");cpuFlatInterior=v&&!strcmp(v,"1");v=getenv("ZENIT_EXPERIMENT_CPU_FLAT_GRADIENT_ROWS");cpuFlatGradientRows=v&&!strcmp(v,"1");v=getenv("ZENIT_EXPERIMENT_CPU_FLAT_ROW_AA");cpuFlatRowAa=v&&!strcmp(v,"1");v=getenv("ZENIT_EXPERIMENT_CPU_FLAT_RECT_PROFILE");cpuFlatRectProfile=v&&!strcmp(v,"1");}
bool metal_cpu_flat_enabled(void){pthread_once(&cpuFlatOnce,initCpuFlat);return cpuFlatEnabled;}
bool metal_cpu_flat_optimized(void){pthread_once(&cpuFlatOnce,initCpuFlat);return cpuFlatOptimized;}
bool metal_cpu_flat_staging(void){pthread_once(&cpuFlatOnce,initCpuFlat);return cpuFlatStaging;}
bool metal_cpu_flat_row_aa_enabled(void){pthread_once(&cpuFlatOnce,initCpuFlat);return cpuFlatRowAa;}
uint64_t metal_cpu_flat_row_aa_pixels(void){return atomic_load(&cpuFlatRowAaPixels);}
bool metal_cpu_flat_gradient_rows_enabled(void){pthread_once(&cpuFlatOnce,initCpuFlat);return cpuFlatGradientRows;}
uint64_t metal_cpu_flat_gradient_pixels(void){return atomic_load(&cpuFlatGradientPixels);}
uint64_t metal_cpu_flat_gradient_coverage_pixels(void){return atomic_load(&cpuFlatGradientCoveragePixels);}
bool metal_cpu_flat_interior_enabled(void){pthread_once(&cpuFlatOnce,initCpuFlat);return cpuFlatInterior;}
uint64_t metal_cpu_flat_border_skipped_pixels(void){return atomic_load(&cpuFlatBorderSkippedPixels);}
uint64_t metal_cpu_flat_interior_pixels(void){return atomic_load(&cpuFlatInteriorPixels);}
uint64_t metal_cpu_flat_backing_bytes(void){return atomic_load(&cpuFlatBackingBytes);}
uint64_t metal_cpu_flat_copy_bytes(void){return atomic_load(&cpuFlatCopyBytes);}
uint64_t metal_cpu_flat_frames(void){return atomic_load(&cpuFlatFrames);}
uint64_t metal_cpu_flat_glyphs(void){return atomic_load(&cpuFlatGlyphs);}
uint64_t metal_cpu_flat_gpu_submissions(void){return atomic_load(&cpuFlatBridgeSubmissions);}
uint64_t metal_cpu_flat_atlas_reads(void){return atomic_load(&cpuFlatAtlasReads);}
uint64_t metal_cpu_flat_cache_hits(void){return atomic_load(&cpuFlatCacheHits);}
uint64_t metal_cpu_flat_fill_bytes(void){return atomic_load(&cpuFlatFillBytes);}
uint64_t metal_cpu_flat_unmasked_glyphs(void){return atomic_load(&cpuFlatUnmaskedGlyphs);}
uint64_t metal_cpu_flat_integer_glyphs(void){return atomic_load(&cpuFlatIntegerGlyphs);}

#define CPU_FLAT_CACHE_SLOTS 1024u
#define CPU_FLAT_CACHE_BYTES (4u*1024u*1024u)
struct CpuFlatCacheEntry {uintptr_t texture;uint64_t uv;uint8_t *bytes;size_t size;};
@interface ZenitCpuFlatCache : NSObject {
@public
    struct CpuFlatCacheEntry slots[CPU_FLAT_CACHE_SLOTS];
    size_t bytes,count;
    uint32_t generation;
    bool hasGeneration,registeredPool;
}
- (void)clear;
@end
@implementation ZenitCpuFlatCache
- (instancetype)init {self=[super init];return self;}
- (void)clear {for(unsigned i=0;i<CPU_FLAT_CACHE_SLOTS;i++){free(slots[i].bytes);slots[i]=(struct CpuFlatCacheEntry){0};}bytes=count=0;}
- (void)dealloc {[self clear];}
@end
// [owned] Cache is renderer-owned. Keys never retain atlas textures. Generation
// changes invalidate all coverage; one incoming glyph may add at most1MiB to
// the4MiB stored-byte cap before an eviction. No host/window pointer escapes.
void *metal_cpu_flat_cache_create(void){return (__bridge_retained void *)[ZenitCpuFlatCache new];}
void metal_cpu_flat_cache_destroy(void *raw){@autoreleasepool{(void)CFBridgingRelease(raw);}}
static size_t cpuFlatHash(uintptr_t texture,uint64_t uv){uint64_t h=(texture>>4)^uv;h^=h>>33;h*=0xff51afd7ed558ccdULL;h^=h>>33;return (size_t)h&(CPU_FLAT_CACHE_SLOTS-1);}
static uint8_t *cpuFlatCoverage(ZenitCpuFlatCache *cache,id<MTLTexture> atlas,const uint16_t uv[4],unsigned w,unsigned h,uint32_t generation) {
    uintptr_t identity=(uintptr_t)(__bridge void *)atlas;uint64_t key;memcpy(&key,uv,sizeof(key));
    bool optimized=metal_cpu_flat_optimized();
    if(optimized){
        if(!cache)return NULL;
        if(!cache->hasGeneration||cache->generation!=generation){[cache clear];cache->generation=generation;cache->hasGeneration=true;}
        size_t at=cpuFlatHash(identity,key);
        for(unsigned probe=0;probe<CPU_FLAT_CACHE_SLOTS;probe++,at=(at+1)&(CPU_FLAT_CACHE_SLOTS-1)){
            struct CpuFlatCacheEntry *e=&cache->slots[at];if(!e->bytes)break;
            if(e->texture==identity&&e->uv==key){atomic_fetch_add(&cpuFlatCacheHits,1);return e->bytes;}
        }
    }
    size_t size=(size_t)w*h;uint8_t *coverage=malloc(size);if(!coverage)return NULL;
    [atlas getBytes:coverage bytesPerRow:w fromRegion:MTLRegionMake2D(uv[0],uv[1],w,h) mipmapLevel:0];
    atomic_fetch_add(&cpuFlatAtlasReads,1);
    if(optimized){
        // Allocate first: an OOM on a new key must preserve existing coverage.
        if(cache->count==CPU_FLAT_CACHE_SLOTS||cache->bytes+size>CPU_FLAT_CACHE_BYTES)[cache clear];
        size_t at=cpuFlatHash(identity,key);while(cache->slots[at].bytes)at=(at+1)&(CPU_FLAT_CACHE_SLOTS-1);
        cache->slots[at]=(struct CpuFlatCacheEntry){identity,key,coverage,size};cache->count++;cache->bytes+=size;
    }
    return coverage;
}

@interface ZenitCpuFlatFrame : NSObject
@property(nonatomic,strong) id<CAMetalDrawable> drawable;
@property(nonatomic,strong) CAMetalLayer *configuredLayer;
@property(nonatomic,assign) bool previousFramebufferOnly,previousPresentsWithTransaction,changedLayerSettings;
- (void)restoreLayerSettings;
@property(nonatomic,strong) ZenitCpuFlatCache *cache;
@property(nonatomic,assign) uint8_t *surfaceBytes;
@property(nonatomic,assign) size_t surfaceRow;
@property(nonatomic,assign) bool dirty;
@property(nonatomic,assign) IOSurfaceRef surface;
@property(nonatomic,assign) uint8_t *bytes;
@property(nonatomic,assign) size_t width,height,row;
@property(nonatomic,assign) uint64_t acquireNs;
@property(nonatomic,assign) uint32_t clearPixel;
@property(nonatomic,assign) bool needsInitialize;
@property(nonatomic,assign) bool locked,transaction,hasShape,hasDamage;
// Patch target: bytes cover only [patchX, patchX+patchW) x [patchY, patchY+patchH)
// of the window; `bytes` is the virtual window-origin base for that buffer and
// every write is clamped to the patch rectangle in cpuFlatClip.
@property(nonatomic,assign) bool isPatch;
@property(nonatomic,assign) uint32_t patchX,patchY,patchW,patchH;
@property(nonatomic,assign) uint8_t *patchBytes;
@property(nonatomic,assign) uint32_t damageX,damageY,damageW,damageH;
@property(nonatomic,assign) float shapeX,shapeY,shapeW,shapeH;
@property(nonatomic,assign) float shapeTL,shapeTR,shapeBR,shapeBL;
@end
@implementation ZenitCpuFlatFrame
- (void)restoreLayerSettings {
    if(_changedLayerSettings){
        _configuredLayer.framebufferOnly=_previousFramebufferOnly;
        _configuredLayer.presentsWithTransaction=_previousPresentsWithTransaction;
        _changedLayerSettings=false;
    }
    _configuredLayer=nil;
}
- (void)dealloc {
    if(_locked)IOSurfaceUnlock(_surface,0,NULL);
    if(_isPatch&&_surface)CFRelease(_surface);
    if(_transaction&&!_isPatch){[CATransaction commit];[CATransaction flush];}
    [self restoreLayerSettings];
    _cache=nil;_bytes=NULL;
}
@end
#ifndef ZENIT_CPU_FLAT_NEW_FRAME
#define ZENIT_CPU_FLAT_NEW_FRAME() [ZenitCpuFlatFrame new]
#endif
static void cpuFlatInitialize(ZenitCpuFlatFrame *f) {
    if(!f.needsInitialize)return;
    uint32_t color=f.clearPixel;
    if(f.isPatch){
        for(size_t y=0;y<f.patchH;y++)memset_pattern4(f.patchBytes+y*f.row,&color,(size_t)f.patchW*4);
        atomic_fetch_add(&cpuFlatFillBytes,(uint64_t)f.patchW*f.patchH*4);f.needsInitialize=false;f.dirty=true;
        return;
    }
    if(metal_cpu_flat_optimized())memset_pattern4(f.bytes,&color,f.row*f.height);
    else for(size_t y=0;y<f.height;y++)memset_pattern4(f.bytes+y*f.row,&color,f.width*4);
    atomic_fetch_add(&cpuFlatFillBytes,f.width*f.height*4);f.needsInitialize=false;f.dirty=true;
}

// [owned] +1 patch frame owning an IOSurface of w x h device pixels placed at
// (x, y) in a window of window_w x window_h. Pixels start as `clear` (opaque).
void *metal_cpu_flat_begin_patch(void *rawLayer,const float *clear,void *rawCache,unsigned x,unsigned y,unsigned w,unsigned h,unsigned window_w,unsigned window_h) {
    @autoreleasepool {
        CAMetalLayer *layer=(__bridge CAMetalLayer *)rawLayer;
        if(!layer||!clear||clear[3]!=1||!w||!h||x>window_w||y>window_h||w>window_w-x||h>window_h-y)return NULL;
        for(unsigned i=0;i<4;i++)if(!isfinite(clear[i])||clear[i]<0||clear[i]>1)return NULL;
        if(metal_cpu_flat_optimized()&&!rawCache)return NULL;
        size_t rowBytes=IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,(size_t)w*4);
        NSDictionary *properties=@{
            (__bridge NSString *)kIOSurfaceWidth:@(w),
            (__bridge NSString *)kIOSurfaceHeight:@(h),
            (__bridge NSString *)kIOSurfaceBytesPerElement:@4,
            (__bridge NSString *)kIOSurfaceBytesPerRow:@(rowBytes),
            (__bridge NSString *)kIOSurfaceAllocSize:@(IOSurfaceAlignProperty(kIOSurfaceAllocSize,rowBytes*h)),
            (__bridge NSString *)kIOSurfacePixelFormat:@((uint32_t)'BGRA')
        };
        IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if(!surface)return NULL;
        CGColorSpaceRef space=layer.colorspace;
        CGColorSpaceRef fallback=space?NULL:CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        id colorSpec=CFBridgingRelease(CGColorSpaceCopyPropertyList(space?:fallback));
        if(fallback)CGColorSpaceRelease(fallback);
        if(colorSpec)IOSurfaceSetValue(surface,kIOSurfaceColorSpace,(__bridge CFTypeRef)colorSpec);
        ZenitCpuFlatFrame *f=ZENIT_CPU_FLAT_NEW_FRAME();
        if(!f){CFRelease(surface);return NULL;}
        f.isPatch=true;f.surface=surface;f.transaction=true;
        f.cache=(__bridge ZenitCpuFlatCache *)rawCache;
        if(IOSurfaceLock(surface,0,NULL)!=KERN_SUCCESS)return NULL;
        f.locked=true;
        f.patchBytes=IOSurfaceGetBaseAddress(surface);f.row=IOSurfaceGetBytesPerRow(surface);
        if(!f.patchBytes||(uintptr_t)f.patchBytes%4||f.row<(size_t)w*4||f.row%4)return NULL;
        f.width=window_w;f.height=window_h;
        f.patchX=x;f.patchY=y;f.patchW=w;f.patchH=h;
        // Window-origin view of the patch; only patch pixels are ever addressed.
        f.bytes=(uint8_t *)((uintptr_t)f.patchBytes-(uintptr_t)y*f.row-(uintptr_t)x*4);
        f.clearPixel=(uint32_t)lrintf(clear[2]*255)|((uint32_t)lrintf(clear[1]*255)<<8)|((uint32_t)lrintf(clear[0]*255)<<16)|0xff000000u;
        f.needsInitialize=true;cpuFlatInitialize(f);
        return (__bridge_retained void *)f;
    }
}
// [owned] +1 frame drawing into a borrowed IOSurface sub-rectangle: the cell
// at (sx, sy) of `rawSurface` stands for window pixels (x, y, w, h). The caller
// keeps the surface alive until metal_cpu_flat_end_patch.
void *metal_cpu_flat_begin_patch_into(void *rawSurface,unsigned sx,unsigned sy,const float *clear,void *rawCache,unsigned x,unsigned y,unsigned w,unsigned h,unsigned window_w,unsigned window_h) {
    @autoreleasepool {
        IOSurfaceRef surface=(IOSurfaceRef)rawSurface;
        if(!surface||!clear||clear[3]!=1||!w||!h||x>window_w||y>window_h||w>window_w-x||h>window_h-y)return NULL;
        if(IOSurfaceGetPixelFormat(surface)!=0x42475241u||sx+w>IOSurfaceGetWidth(surface)||sy+h>IOSurfaceGetHeight(surface))return NULL;
        for(unsigned i=0;i<4;i++)if(!isfinite(clear[i])||clear[i]<0||clear[i]>1)return NULL;
        if(metal_cpu_flat_optimized()&&!rawCache)return NULL;
        ZenitCpuFlatFrame *f=ZENIT_CPU_FLAT_NEW_FRAME();
        if(!f)return NULL;
        CFRetain(surface);
        f.isPatch=true;f.surface=surface;f.transaction=true;
        f.cache=(__bridge ZenitCpuFlatCache *)rawCache;
        if(IOSurfaceLock(surface,0,NULL)!=KERN_SUCCESS)return NULL;
        f.locked=true;f.row=IOSurfaceGetBytesPerRow(surface);
        uint8_t *base=IOSurfaceGetBaseAddress(surface);
        if(!base||(uintptr_t)base%4||f.row%4)return NULL;
        f.patchBytes=base+(size_t)sy*f.row+(size_t)sx*4;
        f.width=window_w;f.height=window_h;
        f.patchX=x;f.patchY=y;f.patchW=w;f.patchH=h;
        f.bytes=(uint8_t *)((uintptr_t)f.patchBytes-(uintptr_t)y*f.row-(uintptr_t)x*4);
        f.clearPixel=(uint32_t)lrintf(clear[2]*255)|((uint32_t)lrintf(clear[1]*255)<<8)|((uint32_t)lrintf(clear[0]*255)<<16)|0xff000000u;
        f.needsInitialize=true;cpuFlatInitialize(f);
        return (__bridge_retained void *)f;
    }
}

// Consume the +1 frame. keep: return the finished surface (+1) in *out.
int metal_cpu_flat_end_patch(void *raw,bool keep,void **out) {
    @autoreleasepool {
        if(out)*out=NULL;
        ZenitCpuFlatFrame *f=CFBridgingRelease(raw);if(!f||!f.isPatch)return 1;
        kern_return_t rc=f.locked?IOSurfaceUnlock(f.surface,0,NULL):KERN_SUCCESS;f.locked=false;
        f.transaction=false;f.cache=nil;f.bytes=NULL;
        if(keep&&rc==KERN_SUCCESS&&out){CFRetain(f.surface);*out=(void *)f.surface;atomic_fetch_add(&cpuFlatFrames,1);}
        return rc==KERN_SUCCESS?0:2;
    }
}
// Rect and zero-radius shape clips use the same SDF/2x2-quad derivatives as
// the Metal shaders. Fractional clip bounds must not be rounded to hard edges.
static float cpuFlatDistance(const float r[4],float x,float y) {
    float dx=fabsf(x-(r[0]+r[2]*.5f))-r[2]*.5f;
    float dy=fabsf(y-(r[1]+r[3]*.5f))-r[3]*.5f;
    return fminf(fmaxf(dx,dy),0)+hypotf(fmaxf(dx,0),fmaxf(dy,0));
}
static float cpuFlatAa(const float r[4],int x,int y,bool clip) {
    if(r[2]<0||r[3]<0)return 1;
    if(r[2]==0||r[3]==0)return 0;
    float px=x+.5f,py=y+.5f;
    if(px>=r[0]+2&&px<=r[0]+r[2]-2&&py>=r[1]+2&&py<=r[1]+r[3]-2)return 1;
    float d=cpuFlatDistance(r,px,py);
    int qx=x&~1,qy=y&~1;
    float dx=cpuFlatDistance(r,qx+1.5f,py)-cpuFlatDistance(r,qx+.5f,py);
    float dy=cpuFlatDistance(r,px,qy+1.5f)-cpuFlatDistance(r,px,qy+.5f);
    float aa=fmaxf(.5f*(clip?(fabsf(dx)+fabsf(dy)):hypotf(dx,dy)),.5f);
    float t=fmaxf(0,fminf(1,(aa-d)/(2*aa)));
    return t*t*(3-2*t);
}
// Same four-quadrant body distance and L2 quad derivative as the SDF shader.
static float cpuFlatRoundedDistance(const float rect[4],const float radii[4],float x,float y){
    float px=x-(rect[0]+rect[2]*.5f),py=y-(rect[1]+rect[3]*.5f);
    float radius=px<0?(py<0?radii[0]:radii[3]):(py<0?radii[1]:radii[2]);
    float dx=fabsf(px)-rect[2]*.5f+radius,dy=fabsf(py)-rect[3]*.5f+radius;
    float qx=fmaxf(dx,0),qy=fmaxf(dy,0),squared=qx*qx+qy*qy;
    if(!isfinite(squared))return fminf(fmaxf(dx,dy),0)+hypotf(qx,qy)-radius;
    float inner=fminf(fmaxf(dx,dy),0)-radius;
    // Match the tested Metal fast-length / fused-subtraction evaluation. A
    // separately rounded hypot can turn a near-zero distance into exact zero,
    // changing AA coverage at an 8-bit blend tie (the 6/8/10 case).
    // Keep zero explicit: reciprocal sqrt at zero would introduce NaN.
    return squared>0?fmaf(squared,1.f/sqrtf(squared),inner):inner;
}
static float cpuFlatRoundedAa(const float rect[4],const float radii[4],int x,int y){
    float px=x+.5f,py=y+.5f;int qx=x&~1,qy=y&~1;
    float d=cpuFlatRoundedDistance(rect,radii,px,py);
    float dx=cpuFlatRoundedDistance(rect,radii,qx+1.5f,py)-cpuFlatRoundedDistance(rect,radii,qx+.5f,py);
    float dy=cpuFlatRoundedDistance(rect,radii,px,qy+1.5f)-cpuFlatRoundedDistance(rect,radii,px,qy+.5f);
    float aa=fmaxf(.5f*hypotf(dx,dy),.5f),t=fmaxf(0,fminf(1,(aa-d)/(2*aa)));
    return t*t*(3-2*t);
}
static void cpuFlatBoundMask(ZenitCpuFlatFrame *f,const float r[4],int bounds[4]) {
    if(r[2]<0||r[3]<0)return;
    if(r[2]==0||r[3]==0){bounds[0]=bounds[1]=bounds[2]=bounds[3]=0;return;}
    int loX=(int)fmaxf(0,fminf(f.width,floorf(r[0]-2)));
    int loY=(int)fmaxf(0,fminf(f.height,floorf(r[1]-2)));
    int hiX=(int)fmaxf(0,fminf(f.width,ceilf(r[0]+r[2]+2)));
    int hiY=(int)fmaxf(0,fminf(f.height,ceilf(r[1]+r[3]+2)));
    bounds[0]=MAX(bounds[0],loX);bounds[1]=MAX(bounds[1],loY);
    bounds[2]=MAX(bounds[0],MIN(bounds[2],hiX));bounds[3]=MAX(bounds[1],MIN(bounds[3],hiY));
}
// Physical write scissor, independent of AA geometry. A new drawable must be
// fully initialized/restored first; clipping must never hide uninitialized pixels.
// NULL disables it. Rejection preserves the previous scissor and all pixels.
int metal_cpu_flat_damage_rect(void *raw,const uint32_t *rect) {
    ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
    if(!f||!f.locked||!f.transaction||!f.bytes)return 1;
    if(!rect){f.hasDamage=false;return 0;}
    if(f.needsInitialize||rect[0]>f.width||rect[1]>f.height||rect[2]>f.width-rect[0]||rect[3]>f.height-rect[1])return 2;
    f.damageX=rect[0];f.damageY=rect[1];f.damageW=rect[2];f.damageH=rect[3];f.hasDamage=true;return 0;
}
static int cpuFlatClip(ZenitCpuFlatFrame *f,const float *clip,float scale,int bounds[4],float physical[4]) {
    bounds[0]=bounds[1]=0;bounds[2]=(int)f.width;bounds[3]=(int)f.height;
    if(f.hasDamage){bounds[0]=(int)f.damageX;bounds[1]=(int)f.damageY;bounds[2]=(int)(f.damageX+f.damageW);bounds[3]=(int)(f.damageY+f.damageH);}
    physical[0]=physical[1]=0;physical[2]=physical[3]=-1;
    if(!isfinite(scale)||scale<=0)return 1;
    if(clip){
        for(unsigned i=0;i<4;i++){physical[i]=clip[i]*scale;if(!isfinite(physical[i]))return 1;}
        if(!isfinite(physical[0]+physical[2])||!isfinite(physical[1]+physical[3]))return 1;
        cpuFlatBoundMask(f,physical,bounds);
    }
    if(f.hasShape){float shape[]={f.shapeX,f.shapeY,f.shapeW,f.shapeH};cpuFlatBoundMask(f,shape,bounds);}
    if(f.isPatch){
        int px0=(int)f.patchX,py0=(int)f.patchY,px1=(int)(f.patchX+f.patchW),py1=(int)(f.patchY+f.patchH);
        bounds[0]=MAX(bounds[0],px0);bounds[1]=MAX(bounds[1],py0);
        bounds[2]=MAX(bounds[0],MIN(bounds[2],px1));bounds[3]=MAX(bounds[1],MIN(bounds[3],py1));
    }
    return 0;
}
// Conservative physical envelope shared with rectangle/border raster limits.
// No writes/initialization; caller must validate the primitive's other features.
int metal_cpu_flat_rect_bounds(void *raw,const float *rect,const float *clip,float scale,uint32_t *out){
    ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
    if(!f||!f.locked||!f.transaction||!f.bytes||!rect||!out)return 1;
    int cb[4];float mask[4];if(cpuFlatClip(f,clip,scale,cb,mask))return 2;
    float x=rect[0]*scale,y=rect[1]*scale,w=rect[2]*scale,h=rect[3]*scale;
    if(!isfinite(x+y+w+h)||w<0||h<0)return 2;
    int x0=(int)fmaxf(cb[0],fminf(cb[2],ceilf(x-.5f))),y0=(int)fmaxf(cb[1],fminf(cb[3],ceilf(y-.5f)));
    int x1=(int)fmaxf(cb[0],fminf(cb[2],ceilf(x+w-.5f))),y1=(int)fmaxf(cb[1],fminf(cb[3],ceilf(y+h-.5f)));
    out[0]=x0;out[1]=y0;out[2]=x1-x0;out[3]=y1-y0;return 0;
}
int metal_cpu_flat_rounded_shape_clip(void *raw,const float *rect,const float *radii,float scale,bool enabled) {
    ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;if(!f||!f.locked||!f.transaction)return 1;
    if(!enabled){f.hasShape=false;return 0;}
    if(!rect||!isfinite(scale)||scale<=0)return 1;
    float p[4],r[4];for(unsigned i=0;i<4;i++){
        p[i]=rect[i]*scale;r[i]=radii?radii[i]*scale:0;
        if(!isfinite(p[i])||!isfinite(r[i])||r[i]<0)return 1;
    }
    if(p[2]<0||p[3]<0||!isfinite(p[0]+p[2])||!isfinite(p[1]+p[3]))return 1;
    f.shapeX=p[0];f.shapeY=p[1];f.shapeW=p[2];f.shapeH=p[3];
    f.shapeTL=r[0];f.shapeTR=r[1];f.shapeBR=r[2];f.shapeBL=r[3];f.hasShape=true;return 0;
}
int metal_cpu_flat_shape_clip(void *raw,const float *rect,float scale,bool enabled) {
    return metal_cpu_flat_rounded_shape_clip(raw,rect,NULL,scale,enabled);
}

static bool cpuFlatContainsInterior(const float r[4],float x,float y,float w,float h) {
    if(r[2]<0||r[3]<0)return true;
    return r[2]>0&&r[3]>0&&x>=r[0]+2&&y>=r[1]+2&&x+w<=r[0]+r[2]-2&&y+h<=r[1]+r[3]-2;
}
static float cpuFlatMaskAlpha(const float shape[4],const float radii[4],const float clip[4],int x,int y) {
    float a=cpuFlatAa(clip,x,y,true);
    if(shape[2]<0||shape[3]<0)return a;
    if(shape[2]==0||shape[3]==0)return 0;
    if(radii[0]==0&&radii[1]==0&&radii[2]==0&&radii[3]==0)return a*cpuFlatAa(shape,x,y,true);
    // A rectangle inset by the largest corner radius is inside every corner.
    // Two extra pixels cover the derivative quad neighbour and rounding margin.
    // Bound geometry like the existing row-AA shortcut; large coordinates and
    // oversized radii keep the exact distance path. This changes no storage.
    if(cpuFlatOptimized){
        float inset=fmaxf(fmaxf(radii[0],radii[1]),fmaxf(radii[2],radii[3]))+2;
        float px=x+.5f,py=y+.5f;
        if(fabsf(shape[0])<=1e6f&&fabsf(shape[1])<=1e6f&&shape[2]<=1e6f&&shape[3]<=1e6f&&
           px>=shape[0]+inset&&py>=shape[1]+inset&&
           px<=shape[0]+shape[2]-inset&&py<=shape[1]+shape[3]-inset)return a;
    }
    // Shape clipping uses fwidth (L1), unlike body coverage's L2 derivative.
    float px=x+.5f,py=y+.5f;int qx=x&~1,qy=y&~1;
    float d=cpuFlatRoundedDistance(shape,radii,px,py);
    float dx=cpuFlatRoundedDistance(shape,radii,qx+1.5f,py)-cpuFlatRoundedDistance(shape,radii,qx+.5f,py);
    float dy=cpuFlatRoundedDistance(shape,radii,px,qy+1.5f)-cpuFlatRoundedDistance(shape,radii,px,qy+.5f);
    float aa=fmaxf(.5f*(fabsf(dx)+fabsf(dy)),.5f),t=fmaxf(0,fminf(1,(aa-d)/(2*aa)));
    // Match rect_clip_alpha * shape_clip_alpha: finish smoothstep before
    // multiplying the independent rectangular mask (float grouping matters).
    return a*(t*t*(3-2*t));
}
// Copy scalars once per draw; no ObjC messages inside the pixel loop.
static bool cpuFlatShapeSnapshot(ZenitCpuFlatFrame *f,float shape[4],float radii[4]) {
    shape[0]=shape[1]=0;shape[2]=shape[3]=-1;memset(radii,0,4*sizeof(float));
    if(f.hasShape){shape[0]=f.shapeX;shape[1]=f.shapeY;shape[2]=f.shapeW;shape[3]=f.shapeH;
        radii[0]=f.shapeTL;radii[1]=f.shapeTR;radii[2]=f.shapeBR;radii[3]=f.shapeBL;}
    return radii[0]!=0||radii[1]!=0||radii[2]!=0||radii[3]!=0;
}
static const uint8_t cpuFlatBayer[256] = {
      0,128, 32,160,  8,136, 40,168,  2,130, 34,162, 10,138, 42,170,
    192, 64,224, 96,200, 72,232,104,194, 66,226, 98,202, 74,234,106,
     48,176, 16,144, 56,184, 24,152, 50,178, 18,146, 58,186, 26,154,
    240,112,208, 80,248,120,216, 88,242,114,210, 82,250,122,218, 90,
     12,140, 44,172,  4,132, 36,164, 14,142, 46,174,  6,134, 38,166,
    204, 76,236,108,196, 68,228,100,206, 78,238,110,198, 70,230,102,
     60,188, 28,156, 52,180, 20,148, 62,190, 30,158, 54,182, 22,150,
    252,124,220, 92,244,116,212, 84,254,126,222, 94,246,118,214, 86,
      3,131, 35,163, 11,139, 43,171,  1,129, 33,161,  9,137, 41,169,
    195, 67,227, 99,203, 75,235,107,193, 65,225, 97,201, 73,233,105,
     51,179, 19,147, 59,187, 27,155, 49,177, 17,145, 57,185, 25,153,
    243,115,211, 83,251,123,219, 91,241,113,209, 81,249,121,217, 89,
     15,143, 47,175,  7,135, 39,167, 13,141, 45,173,  5,133, 37,165,
    207, 79,239,111,199, 71,231,103,205, 77,237,109,197, 69,229,101,
     63,191, 31,159, 55,183, 23,151, 61,189, 29,157, 53,181, 21,149,
    255,127,223, 95,247,119,215, 87,253,125,221, 93,245,117,213, 85,
};
#include "cpu_flat_gradient_row.inc"
// Intersect half-open integer spans with cpuFlatAa's exact full-coverage
// pixel-center comparisons. A negative mask extent is disabled; zero is empty.
// Clamp in float before converting, including far-offscreen finite geometry.
static void cpuFlatIntersectInterior(const float r[4],int b[4]) {
    if(b[0]>=b[2]||b[1]>=b[3]||r[2]<0||r[3]<0)return;
    if(r[2]==0||r[3]==0){b[2]=b[0];b[3]=b[1];return;}
    int x0=(int)fmaxf(b[0],fminf(b[2],ceilf((r[0]+2)-.5f)));
    int y0=(int)fmaxf(b[1],fminf(b[3],ceilf((r[1]+2)-.5f)));
    int x1=(int)fmaxf(b[0],fminf(b[2],floorf((r[0]+r[2]-2)-.5f)+1));
    int y1=(int)fmaxf(b[1],fminf(b[3],floorf((r[1]+r[3]-2)-.5f)+1));
    b[0]=x0;b[1]=y0;b[2]=MAX(x0,x1);b[3]=MAX(y0,y1);
}
// The rectangle inset by the maximum corner radius is inside every rounded
// corner. Keep the existing two-pixel derivative/rounding margin as well.
// Only bounded geometry uses this shortcut; oversized radii yield no span.
static void cpuFlatIntersectRoundedInterior(const float r[4],const float radii[4],int b[4]) {
    if(r[2]<0||r[3]<0)return;
    float radius=fmaxf(fmaxf(radii[0],radii[1]),fmaxf(radii[2],radii[3]));
    for(unsigned k=0;k<4;k++)if(!isfinite(r[k])||fabsf(r[k])>1e6f||!isfinite(radii[k])||radii[k]<0){b[2]=b[0];b[3]=b[1];return;}
    if(radius>=r[2]*.5f||radius>=r[3]*.5f){b[2]=b[0];b[3]=b[1];return;}
    float inner[]={r[0]+radius,r[1]+radius,r[2]-2*radius,r[3]-2*radius};
    cpuFlatIntersectInterior(inner,b);
}
// A conservative x span where rectangular SDF and its quad derivatives
// depend only on y. The two-pixel inset includes the adjacent quad lane and
// float rounding margin (geometry is bounded to1e6). No rounded bodies here.
static void cpuFlatRowAaSpan(const float r[4],int y,int span[2]) {
    if(r[2]<0||r[3]<0)return;
    if(r[2]==0||r[3]==0){span[1]=span[0];return;}
    for(unsigned k=0;k<4;k++)if(fabsf(r[k])>1e6f){span[1]=span[0];return;}
    float cy=r[1]+r[3]*.5f,hy=r[3]*.5f;int qy=y&~1;
    float minDy=fminf(fabsf(qy+.5f-cy)-hy,fabsf(qy+1.5f-cy)-hy);
    float inset=fmaxf(0,-minDy)+2;
    int lo=(int)fmaxf(span[0],fminf(span[1],ceilf(r[0]+inset-.5f)));
    int hi=(int)fmaxf(span[0],fminf(span[1],floorf(r[0]+r[2]-inset-.5f)+1));
    span[0]=lo;span[1]=MAX(lo,hi);
}
// Same encoded-space premultiplied two-color interpolation and ordered dither
// as sdf_primitives.metal. Only axis/diagonal linear PAD gradients are admitted.
int metal_cpu_flat_rect_rounded(void *raw,const float *rect,const float *radii,const float *color,const float *to,unsigned direction,const float *clip,float scale) {
    ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
    if(!f||!f.locked||!f.transaction||!f.bytes||!rect||!color||direction>3||(direction&&!to))return 1;
    for(unsigned i=0;i<4;i++)if(!isfinite(color[i])||color[i]<0||color[i]>1||
        (direction&&(!isfinite(to[i])||to[i]<0||to[i]>1)))return 1;
    float physicalRadii[4]={0};bool rounded=false;
    for(unsigned i=0;i<4;i++)if(radii){physicalRadii[i]=radii[i]*scale;if(!isfinite(physicalRadii[i])||physicalRadii[i]<0)return 2;rounded|=physicalRadii[i]!=0;}
    int cb[4];float mask[4];if(cpuFlatClip(f,clip,scale,cb,mask))return 2;
    float x=rect[0]*scale,y=rect[1]*scale,w=rect[2]*scale,h=rect[3]*scale;
    if(!isfinite(x+y+w+h)||w<0||h<0)return 2;
    int x0=(int)fmaxf(cb[0],fminf(cb[2],ceilf(x-.5f))),y0=(int)fmaxf(cb[1],fminf(cb[3],ceilf(y-.5f)));
    int x1=(int)fmaxf(cb[0],fminf(cb[2],ceilf(x+w-.5f))),y1=(int)fmaxf(cb[1],fminf(cb[3],ceilf(y+h-.5f)));
    bool opaque=!rounded&&!direction&&color[3]==1&&mask[2]<0&&!f.hasShape&&
        x==roundf(x*.5f)*2&&y==roundf(y*.5f)*2&&w==roundf(w*.5f)*2&&h==roundf(h*.5f)*2;
    const double profileStart=cpuFlatRectProfile?CACurrentMediaTime():0;
    uint64_t profileInterior=0,profileGradient=0,profileRowAa=0;
    if(f.needsInitialize){
        if(opaque&&x0==0&&y0==0&&x1==(int)f.width&&y1==(int)f.height)f.needsInitialize=false;
        else cpuFlatInitialize(f);
    }
    f.dirty=true;
    uint8_t *base=f.bytes;size_t pitch=f.row;float shape[4],shapeRadii[4];bool shapeRounded=cpuFlatShapeSnapshot(f,shape,shapeRadii);
    if(opaque){
        uint32_t pixel=(uint32_t)lrintf(color[2]*255)|((uint32_t)lrintf(color[1]*255)<<8)|((uint32_t)lrintf(color[0]*255)<<16)|0xff000000u;
        if(metal_cpu_flat_optimized()&&x0==0&&x1==(int)f.width)
            memset_pattern4(f.bytes+(size_t)y0*f.row,&pixel,(size_t)(y1-y0)*f.row);
        else for(int yy=y0;yy<y1;yy++)memset_pattern4(f.bytes+(size_t)yy*f.row+(size_t)x0*4,&pixel,(size_t)(x1-x0)*4);
    }else{
        int interior[]={x0,y0,x0,y0};uint32_t pixel=0;
        bool solid=cpuFlatInterior&&metal_cpu_flat_optimized()&&!direction&&color[3]==1;
        unsigned source[3]={0};
        if(solid)for(unsigned k=0;k<3;k++){
            source[k]=(unsigned)lrint((double)color[k]*255.0);
            if(fabsf(color[k]*255.f-source[k])>.0001f)solid=false;
        }
        if(solid){
            float body[]={x,y,w,h};interior[2]=x1;interior[3]=y1;
            if(rounded)cpuFlatIntersectRoundedInterior(body,physicalRadii,interior);
            else cpuFlatIntersectInterior(body,interior);
            cpuFlatIntersectInterior(mask,interior);
            if(shapeRounded)cpuFlatIntersectRoundedInterior(shape,shapeRadii,interior);
            else cpuFlatIntersectInterior(shape,interior);
            pixel=source[2]|(source[1]<<8)|(source[0]<<16)|0xff000000u;
        }
        bool gradientRows=!shapeRounded&&cpuFlatGradientRows&&metal_cpu_flat_optimized()&&direction==1&&!rounded&&x1-x0>=64;
        int coverage[]={x0,y0,x0,y0};
        if(gradientRows){
            float body[]={x,y,w,h};coverage[2]=x1;coverage[3]=y1;
            cpuFlatIntersectInterior(body,coverage);cpuFlatIntersectInterior(mask,coverage);cpuFlatIntersectInterior(shape,coverage);
        }
        uint64_t rowAaPixels=0;
        for(int yy=y0;yy<y1;yy++){
        float rowRgb[16][3],rowAlpha=0;
        if(gradientRows)cpuFlatVerticalRow(color,to,y,h,yy,rowRgb,&rowAlpha);
        bool coveredRow=gradientRows&&yy>=coverage[1]&&yy<coverage[3];
        int aaSpan[]={x0,x0};float rowCoverage=0;
        if(cpuFlatRowAa&&gradientRows&&!coveredRow){
            float body[]={x,y,w,h};aaSpan[1]=x1;
            cpuFlatRowAaSpan(body,yy,aaSpan);cpuFlatRowAaSpan(mask,yy,aaSpan);cpuFlatRowAaSpan(shape,yy,aaSpan);
            if(aaSpan[0]<aaSpan[1])rowCoverage=cpuFlatAa(body,aaSpan[0],yy,false)*cpuFlatMaskAlpha(shape,shapeRadii,mask,aaSpan[0],yy);
        }
        rowAaPixels+=(uint64_t)(aaSpan[1]-aaSpan[0]);
        for(int xx=x0;xx<x1;xx++){
        // Boundary pixels keep the original global-coordinate AA/blend loop.
        if(xx==interior[0]&&yy>=interior[1]&&yy<interior[3]&&xx<interior[2]){
            memset_pattern4(base+(size_t)yy*pitch+(size_t)xx*4,&pixel,(size_t)(interior[2]-xx)*4);
            xx=interior[2]-1;continue;
        }
        float alpha=color[3],rgb[3]={color[0],color[1],color[2]};
        if(gradientRows){alpha=rowAlpha;memcpy(rgb,rowRgb[(unsigned)xx&15],sizeof(rgb));}
        else if(direction){
            float u=(xx+.5f-x)/fmaxf(w,.001f),v=(yy+.5f-y)/fmaxf(h,.001f);
            float t=direction==1?v:direction==2?u:(u+v)*.5f;t=fmaxf(0,fminf(1,t));
            alpha=color[3]*(1-t)+to[3]*t;
            float dither=((float)cpuFlatBayer[((unsigned)yy&15)*16+((unsigned)xx&15)]-127.5f)/65025.f;
            for(unsigned k=0;k<3;k++){
                float premul=color[k]*color[3]*(1-t)+to[k]*to[3]*t;
                rgb[k]=fmaxf(0,fminf(1,(alpha>1e-6f?premul/alpha:0)+dither));
            }
        }
        float body[]={x,y,w,h};if(!coveredRow||xx<coverage[0]||xx>=coverage[2])alpha*=xx>=aaSpan[0]&&xx<aaSpan[1]?rowCoverage:(rounded?cpuFlatRoundedAa(body,physicalRadii,xx,yy):cpuFlatAa(body,xx,yy,false))*cpuFlatMaskAlpha(shape,shapeRadii,mask,xx,yy);
        if(alpha<.001f)continue;
        uint8_t *dst=base+(size_t)yy*pitch+(size_t)xx*4;
        for(unsigned k=0;k<3;k++)dst[k]=(uint8_t)lrint((double)(rgb[2-k]*alpha)*255.0+(double)dst[k]*(1.0-(double)alpha));
        dst[3]=255;
    }
        }
        if(cpuFlatRectProfile){
        profileRowAa=rowAaPixels;
        profileInterior=(uint64_t)fmax(0,interior[2]-interior[0])*(uint64_t)fmax(0,interior[3]-interior[1]);
        profileGradient=gradientRows?(uint64_t)fmax(0,coverage[2]-coverage[0])*(uint64_t)fmax(0,coverage[3]-coverage[1]):0;
        }
        atomic_fetch_add(&cpuFlatRowAaPixels,rowAaPixels);
        if(gradientRows){
            atomic_fetch_add(&cpuFlatGradientPixels,(uint64_t)(x1-x0)*(y1-y0));
            atomic_fetch_add(&cpuFlatGradientCoveragePixels,(uint64_t)(coverage[2]-coverage[0])*(coverage[3]-coverage[1]));
        }
        if(interior[0]<interior[2]&&interior[1]<interior[3])
            atomic_fetch_add(&cpuFlatInteriorPixels,(uint64_t)(interior[2]-interior[0])*(interior[3]-interior[1]));
    }
    atomic_fetch_add(&cpuFlatFillBytes,(uint64_t)(x1-x0)*(y1-y0)*4);
    // Diagnostic only: bounded successful large-rectangle observations. Area is
    // the clipped loop envelope, not bytes allocated or unique pixels written.
    // Timing includes initialization/raster work, excludes this log operation.
    if(cpuFlatRectProfile&&(uint64_t)(x1-x0)*(y1-y0)>=65536){
        const double wallUs=(CACurrentMediaTime()-profileStart)*1e6;
        const uint64_t ordinal=atomic_fetch_add(&cpuFlatRectProfileEligible,1);
        if(ordinal<128)fprintf(stderr,"[cpu-flat-rect-profile] {\"version\":1,\"ordinal\":%llu,\"presented_frames\":%llu,\"wall_us\":%.3f,\"rect\":[%g,%g,%g,%g],\"bounds\":[%d,%d,%d,%d],\"color\":[%g,%g,%g,%g],\"direction\":%u,\"rounded\":%s,\"shape_rounded\":%s,\"opaque_bulk\":%s,\"clip\":[%g,%g,%g,%g],\"shape\":[%g,%g,%g,%g],\"interior_pixels\":%llu,\"gradient_covered_pixels\":%llu,\"row_aa_pixels\":%llu}\n",
            (unsigned long long)ordinal,(unsigned long long)atomic_load(&cpuFlatFrames),wallUs,x,y,w,h,x0,y0,x1,y1,color[0],color[1],color[2],color[3],direction,rounded?"true":"false",shapeRounded?"true":"false",opaque?"true":"false",mask[0],mask[1],mask[2],mask[3],shape[0],shape[1],shape[2],shape[3],(unsigned long long)profileInterior,(unsigned long long)profileGradient,(unsigned long long)profileRowAa);
        else if(ordinal==128)fprintf(stderr,"[cpu-flat-rect-profile] {\"version\":1,\"exhausted\":true,\"limit\":128}\n");
    }
    return 0;
}
// sdf_rounded_rect_4 at a local (center-relative) physical position, with the
// same fast-length evaluation as cpuFlatRoundedDistance.
static float cpuFlatSdf4(float px,float py,float hx,float hy,const float radii[4]){
    float radius=px<0?(py<0?radii[0]:radii[3]):(py<0?radii[1]:radii[2]);
    float dx=fabsf(px)-hx+radius,dy=fabsf(py)-hy+radius;
    float qx=fmaxf(dx,0),qy=fmaxf(dy,0),squared=qx*qx+qy*qy;
    if(!isfinite(squared))return fminf(fmaxf(dx,dy),0)+hypotf(qx,qy)-radius;
    float inner=fminf(fmaxf(dx,dy),0)-radius;
    return squared>0?fmaf(squared,1.f/sqrtf(squared),inner):inner;
}
// Outer box shadow (single, rect shape, optional CSS spread) under an optional
// fill, as sdf_fragment_impl<kShadow>: one premultiplied result per pixel
// (shadow composited first, fill second, then the clip mask) blended once.
int metal_cpu_flat_shadow(void *raw,const float *rect,const float *radii,const float *fill,const float *shadow,float blur,float offsetX,float offsetY,float spread,const float *clip,float scale) {
    ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
    if(!f||!f.locked||!f.transaction||!f.bytes||!rect||!fill||!shadow)return 1;
    for(unsigned i=0;i<4;i++)if(!isfinite(fill[i])||fill[i]<0||fill[i]>1||!isfinite(shadow[i])||shadow[i]<0||shadow[i]>1)return 1;
    if(!isfinite(blur)||blur<=0||!isfinite(offsetX)||!isfinite(offsetY)||!isfinite(spread))return 2;
    float r[4]={0};bool rounded=false;
    for(unsigned i=0;i<4;i++)if(radii){r[i]=radii[i]*scale;if(!isfinite(r[i])||r[i]<0)return 2;rounded|=r[i]!=0;}
    int cb[4];float mask[4];if(cpuFlatClip(f,clip,scale,cb,mask))return 2;
    float x=rect[0]*scale,y=rect[1]*scale,w=rect[2]*scale,h=rect[3]*scale;
    if(!isfinite(x+y+w+h)||w<0||h<0)return 2;
    // Vertex quad: the body expanded by 2*blur + |offset| (+ positive spread), logical.
    float expand=blur*2+fabsf(offsetX)+fabsf(offsetY)+fmaxf(spread,0);
    float qx=(rect[0]-expand)*scale,qy=(rect[1]-expand)*scale,qw=(rect[2]+expand*2)*scale,qh=(rect[3]+expand*2)*scale;
    int x0=(int)fmaxf(cb[0],fminf(cb[2],ceilf(qx-.5f))),y0=(int)fmaxf(cb[1],fminf(cb[3],ceilf(qy-.5f)));
    int x1=(int)fmaxf(cb[0],fminf(cb[2],ceilf(qx+qw-.5f))),y1=(int)fmaxf(cb[1],fminf(cb[3],ceilf(qy+qh-.5f)));
    if(f.needsInitialize)cpuFlatInitialize(f);
    f.dirty=true;
    float shape[4],shapeRadii[4];cpuFlatShapeSnapshot(f,shape,shapeRadii);
    const float cx=x+w*.5f,cy=y+h*.5f,hx=w*.5f,hy=h*.5f;
    const float sb=blur*scale,sox=offsetX*scale,soy=offsetY*scale,ss=spread*scale;
    const float shx=fmaxf(hx+ss,0),shy=fmaxf(hy+ss,0);
    float sr[4];for(unsigned i=0;i<4;i++)sr[i]=fmaxf(r[i]+ss,0);
    float body[]={x,y,w,h};
    for(int yy=y0;yy<y1;yy++)for(int xx=x0;xx<x1;xx++){
        float px=xx+.5f,py=yy+.5f;
        float fillAlpha=rounded?cpuFlatRoundedAa(body,r,xx,yy):cpuFlatAa(body,xx,yy,false);
        float ssdf=cpuFlatSdf4((px-cx)-sox,(py-cy)-soy,shx,shy,sr);
        float t=fmaxf(0,fminf(1,(ssdf-sb)/(-sb-sb)));
        float shadowAlpha=t*t*(3-2*t)*(1-fillAlpha);
        float res[4]={0,0,0,0};
        if(shadowAlpha>0){
            float a=shadow[3]*shadowAlpha;
            res[0]=shadow[0]*a;res[1]=shadow[1]*a;res[2]=shadow[2]*a;res[3]=a;
        }
        if(fillAlpha>0){
            float a=fill[3]*fillAlpha,k=1-res[3];
            res[0]+=fill[0]*a*k;res[1]+=fill[1]*a*k;res[2]+=fill[2]*a*k;res[3]+=a*k;
        }
        float m=cpuFlatMaskAlpha(shape,shapeRadii,mask,xx,yy);
        for(unsigned k=0;k<4;k++)res[k]*=m;
        if(res[3]<.001f)continue;
        uint8_t *dst=f.bytes+(size_t)yy*f.row+(size_t)xx*4;
        for(unsigned k=0;k<3;k++)dst[k]=(uint8_t)lrint((double)res[2-k]*255.0+(double)dst[k]*(1.0-(double)res[3]));
        dst[3]=255;
    }
    return 0;
}
// Multi-stop linear PAD gradient fill (eval_gradient_stops: premultiplied
// interpolation between the bracketing stops, unpremultiplied, then the same
// ordered dither as the two-color path). Stops follow the GradientStop ABI.
struct CpuFlatStop {float color[4],position,pad[3];};
_Static_assert(sizeof(struct CpuFlatStop)==32,"GradientStop ABI");
int metal_cpu_flat_rect_stops(void *raw,const float *rect,const float *radii,const void *rawStops,unsigned count,unsigned direction,const float *clip,float scale) {
    ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
    const struct CpuFlatStop *stops=rawStops;
    if(!f||!f.locked||!f.transaction||!f.bytes||!rect||!stops||count<2||count>16||direction<1||direction>3)return 1;
    for(unsigned i=0;i<count;i++){
        for(unsigned k=0;k<4;k++)if(!isfinite(stops[i].color[k])||stops[i].color[k]<0||stops[i].color[k]>1)return 1;
        if(!isfinite(stops[i].position)||(i&&stops[i].position<stops[i-1].position))return 1;
    }
    float r[4]={0};bool rounded=false;
    for(unsigned i=0;i<4;i++)if(radii){r[i]=radii[i]*scale;if(!isfinite(r[i])||r[i]<0)return 2;rounded|=r[i]!=0;}
    int cb[4];float mask[4];if(cpuFlatClip(f,clip,scale,cb,mask))return 2;
    float x=rect[0]*scale,y=rect[1]*scale,w=rect[2]*scale,h=rect[3]*scale;
    if(!isfinite(x+y+w+h)||w<0||h<0)return 2;
    int x0=(int)fmaxf(cb[0],fminf(cb[2],ceilf(x-.5f))),y0=(int)fmaxf(cb[1],fminf(cb[3],ceilf(y-.5f)));
    int x1=(int)fmaxf(cb[0],fminf(cb[2],ceilf(x+w-.5f))),y1=(int)fmaxf(cb[1],fminf(cb[3],ceilf(y+h-.5f)));
    if(f.needsInitialize)cpuFlatInitialize(f);
    f.dirty=true;
    float shape[4],shapeRadii[4];cpuFlatShapeSnapshot(f,shape,shapeRadii);
    const float minPos=stops[0].position,maxPos=stops[count-1].position;
    float body[]={x,y,w,h};
    for(int yy=y0;yy<y1;yy++)for(int xx=x0;xx<x1;xx++){
        float u=(xx+.5f-x)/fmaxf(w,.001f),v=(yy+.5f-y)/fmaxf(h,.001f);
        float t=direction==1?v:direction==2?u:(u+v)*.5f;t=fmaxf(0,fminf(1,t));
        float tc=fmaxf(minPos,fminf(maxPos,t));
        float c[4];memcpy(c,stops[count-1].color,sizeof(c));
        for(unsigned i=0;i+1<count;i++){
            const struct CpuFlatStop *s0=&stops[i],*s1=&stops[i+1];
            if(tc>=s0->position&&tc<=s1->position){
                float span=s1->position-s0->position,lt=span>1e-6f?(tc-s0->position)/span:0;
                float a=s0->color[3]*(1-lt)+s1->color[3]*lt;
                for(unsigned k=0;k<3;k++){
                    float premul=s0->color[k]*s0->color[3]*(1-lt)+s1->color[k]*s1->color[3]*lt;
                    c[k]=a>1e-6f?premul/a:0;
                }
                c[3]=a>1e-6f?a:0;
                break;
            }
        }
        float dither=((float)cpuFlatBayer[((unsigned)yy&15)*16+((unsigned)xx&15)]-127.5f)/65025.f;
        float rgb[3];for(unsigned k=0;k<3;k++)rgb[k]=fmaxf(0,fminf(1,c[k]+dither));
        float alpha=c[3]*((rounded?cpuFlatRoundedAa(body,r,xx,yy):cpuFlatAa(body,xx,yy,false))*cpuFlatMaskAlpha(shape,shapeRadii,mask,xx,yy));
        if(alpha<.001f)continue;
        uint8_t *dst=f.bytes+(size_t)yy*f.row+(size_t)xx*4;
        for(unsigned k=0;k<3;k++)dst[k]=(uint8_t)lrint((double)(rgb[2-k]*alpha)*255.0+(double)dst[k]*(1.0-(double)alpha));
        dst[3]=255;
    }
    return 0;
}
// Byte copy of a GPU-written texture (BGRA8, shared storage) whose texel
// (0,0) is window pixel (x,y): glass underlays (src/zenit_app/cpu_patch.zig).
// Clipped to the patch and damage scissor; no blending, no clip masks.
// The window rect (x,y,w,h) is copied; texel (0,0) is window pixel (tx,ty).
int metal_cpu_flat_blit(void *raw,void *rawTexture,unsigned tx,unsigned ty,unsigned x,unsigned y,unsigned w,unsigned h) {
    @autoreleasepool {
        ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
        id<MTLTexture> texture=(__bridge id<MTLTexture>)rawTexture;
        if(!f||!f.locked||!f.transaction||!f.bytes||!texture)return 1;
        if(texture.pixelFormat!=MTLPixelFormatBGRA8Unorm||texture.storageMode==MTLStorageModePrivate||x<tx||y<ty||x-tx+w>texture.width||y-ty+h>texture.height)return 1;
        int b[4]={0,0,(int)f.width,(int)f.height};
        if(f.hasDamage){b[0]=(int)f.damageX;b[1]=(int)f.damageY;b[2]=(int)(f.damageX+f.damageW);b[3]=(int)(f.damageY+f.damageH);}
        if(f.isPatch){b[0]=MAX(b[0],(int)f.patchX);b[1]=MAX(b[1],(int)f.patchY);b[2]=MIN(b[2],(int)(f.patchX+f.patchW));b[3]=MIN(b[3],(int)(f.patchY+f.patchH));}
        int x0=MAX(b[0],(int)x),y0=MAX(b[1],(int)y),x1=MIN(b[2],(int)(x+w)),y1=MIN(b[3],(int)(y+h));
        if(x0>=x1||y0>=y1)return 0;
        if(f.needsInitialize)cpuFlatInitialize(f);
        f.dirty=true;
        [texture getBytes:f.bytes+(size_t)y0*f.row+(size_t)x0*4 bytesPerRow:f.row
               fromRegion:MTLRegionMake2D((NSUInteger)(x0-(int)tx),(NSUInteger)(y0-(int)ty),(NSUInteger)(x1-x0),(NSUInteger)(y1-y0)) mipmapLevel:0];
        for(int yy=y0;yy<y1;yy++){uint8_t *row=f.bytes+(size_t)yy*f.row;for(int xx=x0;xx<x1;xx++)row[(size_t)xx*4+3]=255;}
        return 0;
    }
}
int metal_cpu_flat_rect_fill(void *raw,const float *rect,const float *color,const float *to,unsigned direction,const float *clip,float scale) {
    return metal_cpu_flat_rect_rounded(raw,rect,NULL,color,to,direction,clip,scale);
}
int metal_cpu_flat_rect(void *raw,const float *rect,const float *color,float scale) {
    return metal_cpu_flat_rect_fill(raw,rect,color,NULL,0,NULL,scale);
}
// Exact Metal64-byte glyph wire ABI. Geometry/rasterization comes from the
// ordinary TextRenderer; this path does not re-shape text in a second API.
struct CpuFlatGlyph {
    float position[2],size[2];uint16_t uv[4];float color[4],clip[4];float skew;uint32_t metadata;
};
_Static_assert(sizeof(struct CpuFlatGlyph)==64,"CPU glyph ABI");
// Shared geometry contract for drawing and conservative write coverage. Bounds
// exclude clear/initialization: callers must restore an opaque initialized frame
// first. Rounded-mask holes and zero-alpha texels may shrink actual writes.
struct CpuFlatGlyphGeometry {int clip[4];float mask[4],x,y;unsigned w,h;uint16_t uv[4];};
static int cpuFlatGlyphGeometry(ZenitCpuFlatFrame *f,const struct CpuFlatGlyph *g,id<MTLTexture> atlas,float scale,struct CpuFlatGlyphGeometry *out){
        if(!f||!f.locked||!f.transaction||!f.bytes||!g||!atlas||atlas.pixelFormat!=MTLPixelFormatR8Unorm||atlas.storageMode!=MTLStorageModeShared||g->skew||((g->metadata>>8)&3))return 1;
        for(unsigned i=0;i<4;i++)if(!isfinite(g->color[i])||g->color[i]<0||g->color[i]>1)return 1;
        int cb[4];float mask[4];if(cpuFlatClip(f,g->clip,scale,cb,mask))return 2;
        float x=g->position[0]*scale,y=g->position[1]*scale;
        if(g->metadata&(1u<<10)){x=roundf(x);y=roundf(y);}
        // The wire UV is a fixed 4096 grid; smaller pages use multiples of
        // 4096 / page_size (see text_renderer.zig MetalGlyphUV).
        if(!atlas.width||4096%atlas.width||atlas.width!=atlas.height)return 1;
        unsigned grid=4096/(unsigned)atlas.width;uint16_t uv[4];
        for(unsigned k=0;k<4;k++){if(g->uv[k]%grid)return 3;uv[k]=(uint16_t)(g->uv[k]/grid);}
        unsigned w=uv[2]-uv[0],h=uv[3]-uv[1];
        if(!w||!h||w>1024||h>1024||!isfinite(x+y)||fabsf(x)>1e7f||fabsf(y)>1e7f||x!=roundf(x)||y!=roundf(y)||
            !isfinite(g->size[0])||!isfinite(g->size[1])||fabsf(g->size[0]*scale-w)>.0001f||fabsf(g->size[1]*scale-h)>.0001f||
            uv[2]>atlas.width||uv[3]>atlas.height){
            if(cpuFlatTrace)fprintf(stderr,"[cpu-flat-glyph] scale=%g pos=%g,%g size=%g,%g uv=%u,%u,%u,%u flags=%u\n",scale,x,y,g->size[0],g->size[1],g->uv[0],g->uv[1],g->uv[2],g->uv[3],g->metadata);
            return 3;
        }
        memcpy(out->clip,cb,sizeof(cb));memcpy(out->mask,mask,sizeof(mask));
        out->x=x;out->y=y;out->w=w;out->h=h;memcpy(out->uv,uv,sizeof(uv));return 0;
}
// Output is [x,y,width,height] in physical pixels, untouched on failure.
// No pixel writes, coverage allocation, GPU calls or initialization occur here.
int metal_cpu_flat_glyph_bounds(void *raw,const void *instance,void *rawAtlas,float scale,int *bounds){
    if(!bounds)return 1;
    struct CpuFlatGlyphGeometry p;
    int result=cpuFlatGlyphGeometry((__bridge ZenitCpuFlatFrame *)raw,instance,(__bridge id<MTLTexture>)rawAtlas,scale,&p);
    if(result)return result;
    int x=MAX(p.clip[0],(int)p.x),y=MAX(p.clip[1],(int)p.y);
    int right=MIN(p.clip[2],(int)p.x+(int)p.w),bottom=MIN(p.clip[3],(int)p.y+(int)p.h);
    if(right<=x||bottom<=y){memset(bounds,0,4*sizeof(int));return 0;}
    bounds[0]=x;bounds[1]=y;bounds[2]=right-x;bounds[3]=bottom-y;return 0;
}
int metal_cpu_flat_glyph(void *raw,const void *instance,void *rawAtlas,float scale,uint32_t generation) {
    @autoreleasepool {
        ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
        const struct CpuFlatGlyph *g=instance;id<MTLTexture> atlas=(__bridge id<MTLTexture>)rawAtlas;
        struct CpuFlatGlyphGeometry p;int result=cpuFlatGlyphGeometry(f,g,atlas,scale,&p);if(result)return result;
        int *cb=p.clip;float *mask=p.mask,x=p.x,y=p.y;unsigned w=p.w,h=p.h;
        uint8_t *coverage=cpuFlatCoverage(f.cache,atlas,p.uv,w,h,generation);if(!coverage)return 4;
        cpuFlatInitialize(f);
        int x0=(int)x,y0=(int)y;
        f.dirty=true;
    uint8_t *base=f.bytes;size_t pitch=f.row;float shape[4],shapeRadii[4];bool shapeRounded=cpuFlatShapeSnapshot(f,shape,shapeRadii);
        bool unmasked=!shapeRounded&&cpuFlatContainsInterior(mask,x,y,w,h)&&cpuFlatContainsInterior(shape,x,y,w,h);
        if(unmasked)atomic_fetch_add(&cpuFlatUnmaskedGlyphs,1);
        // With full opacity, byte-valued text color and no fractional mask,
        // nearest R8 coverage gives round((src*c + dst*(255-c))/255).
        // The odd divisor has no ties; float rounding error is far below the
        // half-step margin. The GPU reference sweeps all256^3 channel triples.
        unsigned source[3];bool integer=unmasked&&g->color[3]==1;
        for(unsigned k=0;k<3;k++){source[k]=(unsigned)lrintf(g->color[k]*255.f);if(fabsf(g->color[k]*255.f-source[k])>.0001f)integer=false;}
        uint32_t sourceRB=(source[0]<<16)|source[2],sourcePixel=0xff000000u|sourceRB|(source[1]<<8);
        if(integer)atomic_fetch_add(&cpuFlatIntegerGlyphs,1);
        static _Atomic(bool) tracedGlyph;
        if(cpuFlatTrace&&!atomic_exchange(&tracedGlyph,true))fprintf(stderr,"[cpu-flat-mask] pos=%g,%g size=%u,%u clip=%g,%g,%g,%g shape=%g,%g,%g,%g unmasked=%d\n",x,y,w,h,mask[0],mask[1],mask[2],mask[3],shape[0],shape[1],shape[2],shape[3],unmasked);
        for(unsigned yy=0;yy<h;yy++){
            int dy=y0+(int)yy;if(dy<cb[1]||dy>=cb[3])continue;
            for(unsigned xx=0;xx<w;xx++){
                int dx=x0+(int)xx;if(dx<cb[0]||dx>=cb[2])continue;
                uint8_t covered=coverage[(size_t)yy*w+xx];if(!covered)continue;
                if(integer){
                    uint32_t *pixel=(uint32_t *)(base+(size_t)dy*pitch+(size_t)dx*4);
                    if(covered==255){*pixel=sourcePixel;continue;}
                    unsigned inv=255-covered;uint32_t dst=*pixel;
                    uint32_t rb=sourceRB*covered+(dst&0x00ff00ffu)*inv+0x00800080u;
                    rb=((rb+((rb>>8)&0x00ff00ffu))>>8)&0x00ff00ffu;
                    unsigned green=source[1]*covered+((dst>>8)&255)*inv+128;
                    green=(green+(green>>8))>>8;
                    *pixel=0xff000000u|rb|(green<<8);continue;
                }
                float alpha=covered/255.f*g->color[3];if(alpha<.001f)continue;
                if(!unmasked)alpha*=cpuFlatMaskAlpha(shape,shapeRadii,mask,dx,dy);
                if(alpha<.001f)continue;
                uint8_t *dst=base+(size_t)dy*pitch+(size_t)dx*4;
                // Match the tested Metal blend order: shader-rounded premul,
                // then one destination-factor multiply/add in normalized space.
                // Explicit fmaf prevents contraction of the source multiply
                // instead, which changes BGRA8 results near half-step ties.
                for(unsigned k=0;k<3;k++){
                    float premul=g->color[2-k]*alpha;
                    float blended=fmaf(dst[k]/255.f,1.f-alpha,premul);
                    dst[k]=(uint8_t)lrint((double)blended*255.0);
                }
                dst[3]=255;
            }
        }
        if(!metal_cpu_flat_optimized())free(coverage);
        atomic_fetch_add(&cpuFlatGlyphs,1);return 0;
    }
}

// Exact texel-to-pixel R8 icon compositing experiment. No persistent mask copy:
// source textures are CPU-uploaded, immutable while this synchronous call runs.
// Rotation, fractional sampling and icon-local corner masks need separate parity.
struct CpuFlatIcon {float rect[4],tint[4],clip[4],radius,opacity,rotate,padding;};
_Static_assert(sizeof(struct CpuFlatIcon)==64,"IconInstance ABI");
int metal_cpu_flat_icon(void *raw,const void *instance,void *rawTexture,float scale) {
    @autoreleasepool {
        ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
        const struct CpuFlatIcon *icon=instance;id<MTLTexture> texture=(__bridge id<MTLTexture>)rawTexture;
        if(!f||!f.locked||!f.transaction||!f.bytes||!icon||!texture||texture.pixelFormat!=MTLPixelFormatR8Unorm||texture.storageMode!=MTLStorageModeShared)return 1;
        if(icon->rotate!=0||icon->radius!=0||!isfinite(icon->opacity)||icon->opacity<0||icon->opacity>1)return 2;
        for(unsigned i=0;i<4;i++)if(!isfinite(icon->tint[i])||icon->tint[i]<0||icon->tint[i]>1)return 2;
        int bounds[4];float clip[4];if(cpuFlatClip(f,icon->clip,scale,bounds,clip))return 2;
        float x=icon->rect[0]*scale,y=icon->rect[1]*scale,w=icon->rect[2]*scale,h=icon->rect[3]*scale;
        if(!isfinite(x+y+w+h)||fabsf(x)>1e7f||fabsf(y)>1e7f||x!=roundf(x)||y!=roundf(y)||
           !texture.width||!texture.height||texture.width>1024||texture.height>1024||
           w!=texture.width||h!=texture.height)return 3;
        size_t width=texture.width,height=texture.height;
        uint8_t *mask=malloc(width*height);if(!mask)return 4;
        [texture getBytes:mask bytesPerRow:width fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
        cpuFlatInitialize(f);f.dirty=true;
        float shape[4],radii[4];cpuFlatShapeSnapshot(f,shape,radii);
        uint8_t *base=f.bytes;size_t pitch=f.row;
        for(unsigned yy=0;yy<height;yy++)for(unsigned xx=0;xx<width;xx++){
            int dx=(int)x+(int)xx,dy=(int)y+(int)yy;
            if(dx<bounds[0]||dx>=bounds[2]||dy<bounds[1]||dy>=bounds[3])continue;
            float alpha=mask[yy*width+xx]/255.f;
            alpha*=cpuFlatMaskAlpha(shape,radii,clip,dx,dy);
            alpha=icon->tint[3]*(alpha*icon->opacity);
            if(alpha<.001f)continue;
            uint8_t *pixel=base+(size_t)dy*pitch+(size_t)dx*4;
            for(unsigned k=0;k<3;k++){float blended=icon->tint[2-k]*alpha+(pixel[k]/255.f)*(1.f-alpha);pixel[k]=(uint8_t)lrint((double)blended*255.0);}
            pixel[3]=255;
        }
        free(mask);return 0;
    }
}

static float cpuFlatCoverageAtDistance(float d,float aa){float t=fmaxf(0,fminf(1,(aa-d)/(2*aa)));return t*t*(3-2*t);}
// Matches the shader's uniform/per-side border distances and front-to-back
// premultiplied accumulation. No intermediate surface or border mask allocation.
int metal_cpu_flat_border_rect(void *raw,const float *rect,const float *radii,const float *fill,const float *border,float width,const float *widths,const float *clip,float scale){
    ZenitCpuFlatFrame *f=(__bridge ZenitCpuFlatFrame *)raw;
    if(!f||!f.locked||!f.transaction||!f.bytes||!rect||!radii||!fill||!border||!widths)return 1;
    int bounds[4];float mask[4];if(cpuFlatClip(f,clip,scale,bounds,mask))return 2;
    float body[4],corners[4],bw[4];bool perSide=false;
    for(unsigned k=0;k<4;k++){
        body[k]=rect[k]*scale;corners[k]=radii[k]*scale;bw[k]=widths[k]*scale;
        if(!isfinite(body[k])||!isfinite(corners[k])||corners[k]<0||!isfinite(bw[k])||bw[k]<0||
           !isfinite(fill[k])||fill[k]<0||fill[k]>1||!isfinite(border[k])||border[k]<0||border[k]>1)return 2;
        perSide|=bw[k]>0;
    }
    width*=scale;
    if(!isfinite(width)||width<0||body[2]<0||body[3]<0||!isfinite(body[0]+body[2])||!isfinite(body[1]+body[3]))return 2;
    float inner[4],innerRadii[4];
    inner[2]=fmaxf(0,body[2]-(bw[1]+bw[3]));inner[3]=fmaxf(0,body[3]-(bw[0]+bw[2]));
    inner[0]=body[0]+body[2]*.5f+(bw[3]-bw[1])*.5f-inner[2]*.5f;
    inner[1]=body[1]+body[3]*.5f+(bw[0]-bw[2])*.5f-inner[3]*.5f;
    innerRadii[0]=fmaxf(0,corners[0]-fmaxf(bw[0],bw[3]));innerRadii[1]=fmaxf(0,corners[1]-fmaxf(bw[0],bw[1]));
    innerRadii[2]=fmaxf(0,corners[2]-fmaxf(bw[2],bw[1]));innerRadii[3]=fmaxf(0,corners[3]-fmaxf(bw[2],bw[3]));
    for(unsigned k=0;k<4;k++)if(!isfinite(inner[k]))return 2;
    int x0=(int)fmaxf(bounds[0],fminf(bounds[2],ceilf(body[0]-.5f))),y0=(int)fmaxf(bounds[1],fminf(bounds[3],ceilf(body[1]-.5f)));
    int x1=(int)fmaxf(bounds[0],fminf(bounds[2],ceilf(body[0]+body[2]-.5f))),y1=(int)fmaxf(bounds[1],fminf(bounds[3],ceilf(body[1]+body[3]-.5f)));
    // With transparent fill, a deep interior contributes exactly zero: both
    // outer and inner coverage are one. Leave a conservative corner/width band
    // plus two physical pixels for the shader's quad-derived AA footprint.
    // Oversized corners/borders simply produce an empty skip rectangle.
    int skip[4]={x0,y0,x0,y0};uint64_t skipped=0;
    if(cpuFlatInterior&&metal_cpu_flat_optimized()&&fill[3]==0){
        float corner=fmaxf(fmaxf(corners[0],corners[1]),fmaxf(corners[2],corners[3]));
        float stroke=perSide?fmaxf(fmaxf(bw[0],bw[1]),fmaxf(bw[2],bw[3])):width;
        float inset=corner+stroke+2;
        if(isfinite(inset)&&body[2]>2*inset&&body[3]>2*inset){
            skip[0]=(int)fmaxf(x0,fminf(x1,ceilf(body[0]+inset-.5f)));
            skip[1]=(int)fmaxf(y0,fminf(y1,ceilf(body[1]+inset-.5f)));
            skip[2]=(int)fmaxf(x0,fminf(x1,ceilf(body[0]+body[2]-inset-.5f)));
            skip[3]=(int)fmaxf(y0,fminf(y1,ceilf(body[1]+body[3]-inset-.5f)));
        }
    }
    cpuFlatInitialize(f);f.dirty=true;float shape[4],shapeRadii[4];cpuFlatShapeSnapshot(f,shape,shapeRadii);uint8_t *base=f.bytes;size_t pitch=f.row;
    for(int y=y0;y<y1;y++)for(int x=x0;x<x1;x++){
        if(x==skip[0]&&y>=skip[1]&&y<skip[3]&&skip[2]>x){
            skipped+=(uint64_t)(skip[2]-x);x=skip[2]-1;continue;
        }
        float px=x+.5f,py=y+.5f;int qx=x&~1,qy=y&~1;
        float d=cpuFlatRoundedDistance(body,corners,px,py);
        float dx=cpuFlatRoundedDistance(body,corners,qx+1.5f,py)-cpuFlatRoundedDistance(body,corners,qx+.5f,py);
        float dy=cpuFlatRoundedDistance(body,corners,px,qy+1.5f)-cpuFlatRoundedDistance(body,corners,px,qy+.5f);
        float aa=fmaxf(.5f*hypotf(dx,dy),.5f),outer=cpuFlatCoverageAtDistance(d,aa);
        float inside=perSide?cpuFlatRoundedDistance(inner,innerRadii,px,py):d+width;
        float borderMask=(perSide||width>0)?outer-cpuFlatCoverageAtDistance(inside,aa):0;
        float fa=fill[3]*outer,ba=borderMask>0?border[3]*borderMask:0;
        float clipped=cpuFlatMaskAlpha(shape,shapeRadii,mask,x,y);
        float alpha=(fa+ba*(1-fa))*clipped;if(alpha<.001f)continue;
        uint8_t *pixel=base+(size_t)y*pitch+(size_t)x*4;
        for(unsigned k=0;k<3;k++){
            float premul=(fill[2-k]*fa+border[2-k]*ba*(1-fa))*clipped;
            float blended=premul+(pixel[k]/255.f)*(1.f-alpha);
            pixel[k]=(uint8_t)lrint((double)blended*255.0);
        }
        pixel[3]=255;
    }
    if(skipped)atomic_fetch_add(&cpuFlatBorderSkippedPixels,skipped);
    return 0;
}
