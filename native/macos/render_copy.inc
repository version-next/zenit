// Pixel-grid copy using only the render engine. No filtering, blending or UV
// interpolation: fragment coordinates address the source texel. Matching formats
// preserve bytes (including the sRGB read/write round trip, tested on the GPU).
// Cache belongs to the command queue (not the device), and dies with that queue.
static char zenitRenderCopyCacheKey;
@interface ZenitRenderCopyCache : NSObject
@property(nonatomic,strong) id<MTLFunction> vertex;
@property(nonatomic,strong) id<MTLFunction> fragment;
@property(nonatomic,strong) id<MTLFunction> fragment8;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id<MTLRenderPipelineState>> *pipelines;
@end
@implementation ZenitRenderCopyCache
@end

int metal_command_buffer_copy_texture_region_render(void *buffer, void *source,
    unsigned int sx, unsigned int sy, unsigned int width, unsigned int height,
    void *destination, unsigned int dx, unsigned int dy, int clear) {
    @autoreleasepool {
        id<MTLCommandBuffer> command=(__bridge id<MTLCommandBuffer>)buffer;
        id<MTLTexture> src=(__bridge id<MTLTexture>)source, dst=(__bridge id<MTLTexture>)destination;
        if (!command || !src || !dst || src==dst || !width || !height ||
            sx>src.width || width>src.width-sx || sy>src.height || height>src.height-sy ||
            dx>dst.width || width>dst.width-dx || dy>dst.height || height>dst.height-dy ||
            src.pixelFormat!=dst.pixelFormat || src.sampleCount!=1 || dst.sampleCount!=1) return 0;
        id<MTLCommandQueue> queue=command.commandQueue;
        id<MTLRenderPipelineState> pipeline;
        // Queue-local cache creation and its mutable format dictionary share
        // one lock. Retain the selected pipeline outside the critical section;
        // independent command buffers need not serialize their encoding.
        @synchronized(queue) {
        ZenitRenderCopyCache *cache=objc_getAssociatedObject(queue,&zenitRenderCopyCacheKey);
        if (!cache) {
            NSString *shader=@"#include <metal_stdlib>\nusing namespace metal;\n"
                "struct V { float4 position [[position]]; };\n"
                "vertex V copy_vertex(uint i [[vertex_id]]) {\n"
                "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return {float4(p[i],0,1)}; }\n"
                "fragment float4 copy_fragment(V v [[stage_in]], texture2d<float,access::read> src [[texture(0)]],\n"
                "constant uint4 &o [[buffer(0)]]) { return src.read(uint2(v.position.xy)-o.zw+o.xy); }\n"
                // Half values retain more precision than the 8-bit target can
                // encode. No arithmetic is applied to color, and the complete
                // byte palette (including sRGB) is checked by the GPU test.
                "fragment half4 copy_fragment8(V v [[stage_in]], texture2d<half,access::read> src [[texture(0)]],\n"
                "constant uint4 &o [[buffer(0)]]) { return src.read(uint2(v.position.xy)-o.zw+o.xy); }\n";
            NSError *error=nil;
            id<MTLLibrary> library=[queue.device newLibraryWithSource:shader options:nil error:&error];
            if (!library) { fprintf(stderr,"[render-copy] shader: %s\n",error.description.UTF8String); return 0; }
            cache=[ZenitRenderCopyCache new];
            cache.vertex=[library newFunctionWithName:@"copy_vertex"];
            cache.fragment=[library newFunctionWithName:@"copy_fragment"];
            cache.fragment8=[library newFunctionWithName:@"copy_fragment8"];
            cache.pipelines=[NSMutableDictionary new];
            if (!cache.vertex || !cache.fragment || !cache.fragment8) return 0;
            objc_setAssociatedObject(queue,&zenitRenderCopyCacheKey,cache,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSNumber *format=@(dst.pixelFormat);
        pipeline=cache.pipelines[format];
        if (!pipeline) {
            MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
            descriptor.label=@"Zenit.RenderCopy";
            BOOL byteFormat=dst.pixelFormat==MTLPixelFormatBGRA8Unorm || dst.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB ||
                dst.pixelFormat==MTLPixelFormatRGBA8Unorm || dst.pixelFormat==MTLPixelFormatRGBA8Unorm_sRGB;
            descriptor.vertexFunction=cache.vertex;
            descriptor.fragmentFunction=byteFormat ? cache.fragment8 : cache.fragment;
            descriptor.colorAttachments[0].pixelFormat=dst.pixelFormat;
            NSError *error=nil;
            pipeline=[queue.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
            if (!pipeline) { fprintf(stderr,"[render-copy] pipeline: %s\n",error.description.UTF8String); return 0; }
            cache.pipelines[format]=pipeline;
        }
        }
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=dst;
        pass.colorAttachments[0].loadAction=clear ? MTLLoadActionClear :
            (dx==0 && dy==0 && width==dst.width && height==dst.height ? MTLLoadActionDontCare : MTLLoadActionLoad);
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        zenit_pass_timer_attach(command,pass);
        id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
        if (!encoder) return 0;
        metal_command_buffer_note_engine(buffer,0);
        encoder.label=@"Zenit.RenderCopy";
        [encoder setRenderPipelineState:pipeline];
        [encoder setViewport:(MTLViewport){0,0,dst.width,dst.height,0,1}];
        [encoder setScissorRect:(MTLScissorRect){dx,dy,width,height}];
        uint32_t offsets[4]={sx,sy,dx,dy};
        [encoder setFragmentBytes:offsets length:sizeof(offsets) atIndex:0];
        [encoder setFragmentTexture:src atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        return 1;
    }
}
