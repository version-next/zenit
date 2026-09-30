#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <stdint.h>
#import <string.h>

// Harness-only, single-surface recorder. Frames arrive directly from Zenit's
// completed Metal drawable, so the recording never observes the desktop,
// native cursor, window shadows, or macOS capture-status overlays.
typedef struct {
    int32_t ok;
    int32_t active;
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t _reserved;
    uint64_t duration_ms;
    uint64_t file_size;
    uint64_t frame_count;
    uint64_t dropped_frames;
    char path[768];
    char error[256];
} ZenitWindowRecordingState;

static void zenitCopyCString(char *dst, size_t capacity, const char *src) {
    if (!dst || capacity == 0) return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    size_t len = strnlen(src, capacity - 1);
    memcpy(dst, src, len);
    dst[len] = '\0';
}

static void zenitSetRecordingError(ZenitWindowRecordingState *out, NSString *message) {
    if (!out) return;
    zenitCopyCString(out->error, sizeof(out->error), message.UTF8String ?: "recording failed");
}

static BOOL zenitWaitForSemaphore(dispatch_semaphore_t semaphore, NSTimeInterval timeout) {
    if (!semaphore) return NO;
    if (![NSThread isMainThread]) {
        return dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0) return YES;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0;
}

@interface ZenitRenderRecorder : NSObject {
    CVMetalTextureCacheRef _textureCache;
    CVPixelBufferRef _lastPixelBuffer;
}
@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *writerInput;
@property(nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic, strong) id<MTLDevice> metalDevice;
@property(nonatomic, strong) id<MTLCommandQueue> blitQueue;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, assign) uint32_t windowID;
@property(nonatomic, assign) uint32_t width;
@property(nonatomic, assign) uint32_t height;
@property(nonatomic, assign) uint32_t fps;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) CMTime startHostTime;
@property(nonatomic, assign) int64_t lastFrameIndex;
@property(nonatomic, assign) uint64_t frameCount;
@property(nonatomic, assign) uint64_t droppedFrames;

- (BOOL)appendTexture:(id<MTLTexture>)source;
- (BOOL)finish;
- (uint64_t)elapsedMilliseconds;
@end

@implementation ZenitRenderRecorder

- (instancetype)init {
    self = [super init];
    if (self) _lastFrameIndex = -1;
    return self;
}

- (void)dealloc {
    if (_lastPixelBuffer) CVPixelBufferRelease(_lastPixelBuffer);
    if (_textureCache) CFRelease(_textureCache);
}

- (uint64_t)elapsedMilliseconds {
    if (!CMTIME_IS_NUMERIC(self.startHostTime)) return 0;
    CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    Float64 seconds = CMTimeGetSeconds(CMTimeSubtract(now, self.startHostTime));
    if (!isfinite(seconds) || seconds <= 0) return 0;
    return (uint64_t)llround(seconds * 1000.0);
}

- (BOOL)ensureMetalResourcesForTexture:(id<MTLTexture>)source {
    if (self.metalDevice == source.device && self.blitQueue && _textureCache) return YES;
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
    self.metalDevice = source.device;
    self.blitQueue = [self.metalDevice newCommandQueue];
    if (!self.blitQueue) return NO;
    CVReturn result = CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                                 NULL,
                                                 self.metalDevice,
                                                 NULL,
                                                 &_textureCache);
    return result == kCVReturnSuccess && _textureCache != NULL;
}

- (BOOL)appendTexture:(id<MTLTexture>)source {
    if (!self.active || self.failure || !source) return NO;
    if (source.width != self.width || source.height != self.height) {
        self.failure = [NSError errorWithDomain:@"com.zenit.harness.recording"
                                           code:10
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      @"window resized during recording"}];
        return NO;
    }

    Float64 elapsed = (Float64)[self elapsedMilliseconds] / 1000.0;
    int64_t frameIndex = (int64_t)floor(elapsed * (Float64)self.fps);
    if (frameIndex <= self.lastFrameIndex) return YES;
    if (!self.writerInput.readyForMoreMediaData) {
        self.droppedFrames += 1;
        return YES;
    }
    if (![self ensureMetalResourcesForTexture:source]) {
        self.failure = [NSError errorWithDomain:@"com.zenit.harness.recording"
                                           code:11
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      @"unable to create Metal recording resources"}];
        return NO;
    }

    CVPixelBufferPoolRef pool = self.adaptor.pixelBufferPool;
    if (!pool) {
        self.failure = [NSError errorWithDomain:@"com.zenit.harness.recording"
                                           code:12
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      @"video encoder pixel-buffer pool is unavailable"}];
        return NO;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn poolResult = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                              pool,
                                                              &pixelBuffer);
    if (poolResult != kCVReturnSuccess || !pixelBuffer) {
        self.droppedFrames += 1;
        return YES;
    }

    CVMetalTextureRef cvTexture = NULL;
    CVReturn textureResult = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        _textureCache,
        pixelBuffer,
        NULL,
        source.pixelFormat,
        self.width,
        self.height,
        0,
        &cvTexture);
    if (textureResult != kCVReturnSuccess || !cvTexture) {
        CVPixelBufferRelease(pixelBuffer);
        self.failure = [NSError errorWithDomain:@"com.zenit.harness.recording"
                                           code:13
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      @"unable to bind an encoder frame as a Metal texture"}];
        return NO;
    }

    id<MTLTexture> destination = CVMetalTextureGetTexture(cvTexture);
    id<MTLCommandBuffer> commandBuffer = [self.blitQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:source
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(self.width, self.height, 1)
                toTexture:destination
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status == MTLCommandBufferStatusError) {
        self.failure = commandBuffer.error;
        CFRelease(cvTexture);
        CVPixelBufferRelease(pixelBuffer);
        return NO;
    }

    CMTime presentationTime = CMTimeMake(frameIndex, (int32_t)self.fps);
    BOOL appended = [self.adaptor appendPixelBuffer:pixelBuffer
                               withPresentationTime:presentationTime];
    if (appended) {
        if (_lastPixelBuffer) CVPixelBufferRelease(_lastPixelBuffer);
        _lastPixelBuffer = CVPixelBufferRetain(pixelBuffer);
        self.lastFrameIndex = frameIndex;
        self.frameCount += 1;
    } else {
        self.failure = self.writer.error ?: [NSError errorWithDomain:@"com.zenit.harness.recording"
                                                              code:14
                                                          userInfo:@{NSLocalizedDescriptionKey:
                                                                         @"video encoder rejected a frame"}];
    }

    CFRelease(cvTexture);
    CVPixelBufferRelease(pixelBuffer);
    return appended;
}

- (BOOL)finish {
    if (!self.active) return self.writer.status == AVAssetWriterStatusCompleted;
    self.active = NO;

    int64_t finalFrameIndex = (int64_t)ceil(
        ((Float64)[self elapsedMilliseconds] / 1000.0) * (Float64)self.fps);
    finalFrameIndex = MAX(finalFrameIndex, self.lastFrameIndex + 1);
    if (_lastPixelBuffer && self.writerInput.readyForMoreMediaData) {
        CMTime finalTime = CMTimeMake(finalFrameIndex, (int32_t)self.fps);
        if ([self.adaptor appendPixelBuffer:_lastPixelBuffer withPresentationTime:finalTime]) {
            self.frameCount += 1;
            self.lastFrameIndex = finalFrameIndex;
        }
    }

    CMTime endTime = CMTimeMake(MAX(finalFrameIndex + 1, 1), (int32_t)self.fps);
    [self.writer endSessionAtSourceTime:endTime];
    [self.writerInput markAsFinished];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [self.writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(finished);
    }];
    if (!zenitWaitForSemaphore(finished, 20.0)) {
        self.failure = [NSError errorWithDomain:@"com.zenit.harness.recording"
                                           code:15
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      @"timed out while finalizing the recording file"}];
        return NO;
    }
    if (self.writer.status != AVAssetWriterStatusCompleted) {
        self.failure = self.writer.error ?: [NSError errorWithDomain:@"com.zenit.harness.recording"
                                                              code:16
                                                          userInfo:@{NSLocalizedDescriptionKey:
                                                                         @"video encoder did not finish"}];
        return NO;
    }
    return YES;
}

@end

static ZenitRenderRecorder *gZenitRenderRecorder = nil;

static void zenitFillRecordingState(ZenitRenderRecorder *recorder,
                                    ZenitWindowRecordingState *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!recorder) return;

    out->active = recorder.active ? 1 : 0;
    out->width = recorder.width;
    out->height = recorder.height;
    out->fps = recorder.fps;
    out->duration_ms = [recorder elapsedMilliseconds];
    out->frame_count = recorder.frameCount;
    out->dropped_frames = recorder.droppedFrames;
    zenitCopyCString(out->path, sizeof(out->path), recorder.path.UTF8String);
    if (recorder.failure) zenitSetRecordingError(out, recorder.failure.localizedDescription);

    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:recorder.path error:nil];
    NSNumber *fileSize = attributes[NSFileSize];
    if (fileSize) out->file_size = fileSize.unsignedLongLongValue;
}

int macos_window_recording_start(uint32_t window_id,
                                 const char *path_utf8,
                                 uint32_t requested_fps,
                                 uint32_t width,
                                 uint32_t height,
                                 ZenitWindowRecordingState *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (gZenitRenderRecorder) {
        zenitFillRecordingState(gZenitRenderRecorder, out);
        zenitSetRecordingError(out, @"a window recording is already active");
        return 0;
    }
    if (window_id == 0 || !path_utf8 || width < 2 || height < 2) {
        zenitSetRecordingError(out, @"invalid recording window, path, or drawable size");
        return 0;
    }

    NSString *path = [NSString stringWithUTF8String:path_utf8];
    NSString *extension = [path.pathExtension lowercaseString];
    if (!path || !path.isAbsolutePath ||
        !([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"])) {
        zenitSetRecordingError(out, @"recording path must be an absolute .mp4 or .mov path");
        return 0;
    }
    NSString *parent = path.stringByDeletingLastPathComponent;
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:parent isDirectory:&isDirectory] ||
        !isDirectory) {
        zenitSetRecordingError(out, @"recording output directory does not exist");
        return 0;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:path error:&removeError]) {
            zenitSetRecordingError(out, removeError.localizedDescription);
            return 0;
        }
    }

    // H.264 requires even dimensions. Zenit's Retina drawable is normally
    // already aligned, but fail explicitly instead of silently scaling it.
    if ((width & 1u) != 0 || (height & 1u) != 0) {
        zenitSetRecordingError(out, @"recording drawable dimensions must be even");
        return 0;
    }
    uint32_t fps = MIN(MAX(requested_fps, 1u), 120u);
    double calculatedBitrate = (double)width * (double)height * (double)fps * 0.08;
    uint32_t bitrate = (uint32_t)MIN(MAX(calculatedBitrate, 8.0e6), 80.0e6);

    // `.mov` opts into ProRes 422 HQ (near-lossless) for captures that will be
    // re-encoded later, e.g. demo videos: H.264 here plus a second encode
    // afterwards visibly softens small UI text. `.mp4` keeps the H.264 default.
    BOOL prores = [[[path pathExtension] lowercaseString] isEqualToString:@"mov"];
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *writerError = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url
                                                     fileType:(prores ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4)
                                                        error:&writerError];
    if (!writer) {
        zenitSetRecordingError(out, writerError.localizedDescription);
        return 0;
    }

    NSDictionary *compression = @{
        AVVideoAverageBitRateKey: @(bitrate),
        AVVideoExpectedSourceFrameRateKey: @(fps),
        AVVideoMaxKeyFrameIntervalKey: @(fps * 2),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoAllowFrameReorderingKey: @NO,
    };
    NSDictionary *settings = prores ? @{
        AVVideoCodecKey: AVVideoCodecTypeAppleProRes422HQ,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
    } : @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compression,
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                    outputSettings:settings];
    input.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:input]) {
        zenitSetRecordingError(out, @"H.264 encoder rejected the drawable dimensions");
        return 0;
    }
    [writer addInput:input];

    NSDictionary *pixelAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                       sourcePixelBufferAttributes:pixelAttributes];

    if (![writer startWriting]) {
        zenitSetRecordingError(out, writer.error.localizedDescription);
        return 0;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    ZenitRenderRecorder *recorder = [[ZenitRenderRecorder alloc] init];
    recorder.writer = writer;
    recorder.writerInput = input;
    recorder.adaptor = adaptor;
    recorder.path = path;
    recorder.windowID = window_id;
    recorder.width = width;
    recorder.height = height;
    recorder.fps = fps;
    recorder.startHostTime = CMClockGetTime(CMClockGetHostTimeClock());
    recorder.active = YES;
    gZenitRenderRecorder = recorder;

    zenitFillRecordingState(recorder, out);
    out->ok = 1;
    out->active = 1;
    return 1;
}

int macos_window_recording_append(uint32_t window_id, void *texture_ptr) {
    ZenitRenderRecorder *recorder = gZenitRenderRecorder;
    if (!recorder || !recorder.active || recorder.windowID != window_id || !texture_ptr) return 0;
    id<MTLTexture> texture = (__bridge id<MTLTexture>)texture_ptr;
    return [recorder appendTexture:texture] ? 1 : 0;
}

int macos_window_recording_status(uint32_t window_id, ZenitWindowRecordingState *out) {
    if (out) memset(out, 0, sizeof(*out));
    ZenitRenderRecorder *recorder = gZenitRenderRecorder;
    if (!recorder) {
        if (out) out->ok = 1;
        return 1;
    }
    if (recorder.windowID != window_id) {
        zenitSetRecordingError(out, @"the active recording belongs to another window");
        return 0;
    }
    zenitFillRecordingState(recorder, out);
    out->ok = recorder.failure ? 0 : 1;
    return out->ok;
}

int macos_window_recording_stop(uint32_t window_id, ZenitWindowRecordingState *out) {
    if (out) memset(out, 0, sizeof(*out));
    ZenitRenderRecorder *recorder = gZenitRenderRecorder;
    if (!recorder) {
        zenitSetRecordingError(out, @"no active window recording");
        return 0;
    }
    if (recorder.windowID != window_id) {
        zenitSetRecordingError(out, @"the active recording belongs to another window");
        return 0;
    }

    BOOL finished = [recorder finish];
    zenitFillRecordingState(recorder, out);
    gZenitRenderRecorder = nil;
    if (finished && !recorder.failure && out->file_size > 0) {
        out->ok = 1;
        out->active = 0;
        return 1;
    }
    if (!recorder.failure && out->file_size == 0) {
        zenitSetRecordingError(out, @"recording produced an empty file");
    }
    return 0;
}
