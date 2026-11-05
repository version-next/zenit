#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include "clipboard_pasteboard.h"
#import <CoreGraphics/CoreGraphics.h>

/// Download image from URL and decode to RGBA pixel data.
/// Returns malloc'd RGBA buffer (caller must free via macos_free_image_data).
/// out_width/out_height are set on success; returns NULL on failure.
uint8_t* macos_load_image_from_url(const char* url_cstr,
                                    uint32_t* out_width,
                                    uint32_t* out_height) {
    @autoreleasepool {
        if (!url_cstr || !out_width || !out_height) return NULL;

        NSString *urlString = [NSString stringWithUTF8String:url_cstr];

        NSData *data = nil;
        if ([urlString hasPrefix:@"file://"]) {
            // local file: read directly (supports relative and absolute paths)
            NSString *path = [urlString substringFromIndex:7];
            data = [NSData dataWithContentsOfFile:path];
        } else {
            // remote URL: download via network
            NSURL *url = [NSURL URLWithString:urlString];
            if (!url) return NULL;

            NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                     cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                 timeoutInterval:15.0];
            NSURLResponse *response = nil;
            NSError *error = nil;
            data = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&error];
        }
        if (!data || data.length == 0) return NULL;

        // Decode via CGImageSource (supports JPEG, PNG, GIF, WebP, HEIC, etc.)
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) return NULL;

        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!cgImage) return NULL;

        NSUInteger width = CGImageGetWidth(cgImage);
        NSUInteger height = CGImageGetHeight(cgImage);

        // Limit to reasonable size (max 2048px on longest side)
        const NSUInteger MAX_DIM = 2048;
        if (width > MAX_DIM || height > MAX_DIM) {
            double scale = (double)MAX_DIM / (double)(width > height ? width : height);
            width = (NSUInteger)(width * scale);
            height = (NSUInteger)(height * scale);
        }

        if (width == 0 || height == 0) {
            CGImageRelease(cgImage);
            return NULL;
        }

        NSUInteger bytesPerRow = width * 4;
        uint8_t *pixels = (uint8_t *)calloc(width * height, 4);
        if (!pixels) {
            CGImageRelease(cgImage);
            return NULL;
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(
            pixels, width, height, 8, bytesPerRow,
            colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
        );
        CGColorSpaceRelease(colorSpace);

        if (!ctx) {
            free(pixels);
            CGImageRelease(cgImage);
            return NULL;
        }

        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
        CGContextRelease(ctx);
        CGImageRelease(cgImage);

        *out_width = (uint32_t)width;
        *out_height = (uint32_t)height;
        return pixels;
    }
}

void macos_free_image_data(uint8_t* data) {
    free(data);
}

/// write RGBA8 pixels to PNG file. returns 0 success, -1 param error, -2 encode fail, -3 disk fail.
int macos_write_png_from_rgba(
    const char* path_cstr,
    const uint8_t* rgba,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row
) {
    @autoreleasepool {
        if (!path_cstr || !rgba || width == 0 || height == 0 || bytes_per_row < width * 4) return -1;

        NSString *path = [NSString stringWithUTF8String:path_cstr];
        if (!path || path.length == 0) return -1;

        unsigned char *planes[5] = {0};
        planes[0] = (unsigned char *)rgba; // NSBitmapImageRep doesn't copy, caller must ensure memory valid before function return
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:planes
                          pixelsWide:(NSInteger)width
                          pixelsHigh:(NSInteger)height
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSCalibratedRGBColorSpace
                         bytesPerRow:(NSInteger)bytes_per_row
                        bitsPerPixel:32];
        if (!rep) return -2;

        // decode side (macos_decode_image_file) outputs sRGB pixels; must tag sRGB here too, else
        // decode->encode roundtrip stacks one GenericRGB<->sRGB conversion, pixel values drift
        // (image fades). retag only changes tag, not pixels.
        rep = [rep bitmapImageRepByRetaggingWithColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!rep) return -2;

        NSDictionary *props = @{};
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:props];
        if (!png || png.length == 0) return -2;

        if (![png writeToFile:path atomically:YES]) return -3;
        return 0;
    }
}

// ===== async download + file decode (background thread) =====

/// decode memory data to RGBA (internal shared logic)
static uint8_t* decode_image_data_to_rgba(NSData *data,
                                           uint32_t* out_width,
                                           uint32_t* out_height) {
    if (!data || data.length == 0) return NULL;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;

    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!cgImage) return NULL;

    NSUInteger width = CGImageGetWidth(cgImage);
    NSUInteger height = CGImageGetHeight(cgImage);

    const NSUInteger MAX_DIM = 2048;
    if (width > MAX_DIM || height > MAX_DIM) {
        double scale = (double)MAX_DIM / (double)(width > height ? width : height);
        width = (NSUInteger)(width * scale);
        height = (NSUInteger)(height * scale);
    }

    if (width == 0 || height == 0) {
        CGImageRelease(cgImage);
        return NULL;
    }

    NSUInteger bytesPerRow = width * 4;
    uint8_t *pixels = (uint8_t *)calloc(width * height, 4);
    if (!pixels) {
        CGImageRelease(cgImage);
        return NULL;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(
        pixels, width, height, 8, bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);

    if (!ctx) {
        free(pixels);
        CGImageRelease(cgImage);
        return NULL;
    }

    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(ctx);
    CGImageRelease(cgImage);

    *out_width = (uint32_t)width;
    *out_height = (uint32_t)height;
    return pixels;
}

/// download image to disk file via NSURLSession (background thread, blocks current thread). returns
/// 0 success, -1 network error, -2 file write error
int macos_download_image_to_file(const char* url_cstr, const char* dest_path) {
    @autoreleasepool {
        if (!url_cstr || !dest_path) return -1;

        NSString *urlString = [NSString stringWithUTF8String:url_cstr];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) return -1;

        NSString *destString = [NSString stringWithUTF8String:dest_path];

        // use dispatch_semaphore to make async NSURLSession wait synchronously on background thread
        __block NSData *downloadedData = nil;
        __block NSError *downloadError = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 60.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                 cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                             timeoutInterval:30.0];

        NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                downloadError = error;
            } else {
                // check HTTP status code
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                    if (statusCode >= 400) {
                        downloadError = [NSError errorWithDomain:@"HTTP" code:statusCode userInfo:nil];
                    } else {
                        downloadedData = data;
                    }
                } else {
                    downloadedData = data;
                }
            }
            dispatch_semaphore_signal(sem);
        }];
        [task resume];

        // wait for completion (blocking on background thread acceptable)
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        [session finishTasksAndInvalidate];

        if (downloadError || !downloadedData || downloadedData.length == 0) {
            return -1;
        }

        // write to temp file first, then atomic rename
        NSString *tmpPath = [destString stringByAppendingString:@".tmp"];
        if (![downloadedData writeToFile:tmpPath atomically:NO]) {
            return -2;
        }

        NSError *moveError = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        // delete target if already exists
        [fm removeItemAtPath:destString error:nil];
        if (![fm moveItemAtPath:tmpPath toPath:destString error:&moveError]) {
            [fm removeItemAtPath:tmpPath error:nil];
            return -2;
        }

        return 0;
    }
}

/// decode file to RGBA (background thread). returns malloc'd RGBA buffer, caller frees via
/// macos_free_image_data
uint8_t* macos_decode_image_file(const char* file_path,
                                  uint32_t* out_width,
                                  uint32_t* out_height) {
    @autoreleasepool {
        if (!file_path || !out_width || !out_height) return NULL;

        NSString *path = [NSString stringWithUTF8String:file_path];
        NSData *data = [NSData dataWithContentsOfFile:path];
        return decode_image_data_to_rgba(data, out_width, out_height);
    }
}

/// open URL in default app (browser). returns 1=ok / 0=fail
int macos_open_url(const char* url) {
    if (!url) return 0;
    @autoreleasepool {
        NSString *s = [NSString stringWithUTF8String:url];
        if (!s || s.length == 0) return 0;
        NSURL *u = [NSURL URLWithString:s];
        if (!u) return 0;
        BOOL ok = [[NSWorkspace sharedWorkspace] openURL:u];
        return ok ? 1 : 0;
    }
}

// ===== clipboard image read =====
//
// Type priority (probe order, directly decides paste success):
// public.png -> public.jpeg -> public.heic -> public.tiff (macOS screenshot tool often
// gives TIFF) -> public.file-url (Finder copy; filter by image extension).
// Prefer raw encoded bytes; avoid NSImage (loses encoding, lossy bloated re-encode).

static NSArray<NSString *> *clipboardImageDataTypes(void) {
    return @[ @"public.png", @"public.jpeg", @"public.heic", @"public.tiff" ];
}

static BOOL pathExtensionLooksLikeImage(NSString *ext) {
    if (ext.length == 0) return NO;
    // don't use dispatch_once: its inline macro triggers UBSan invalid-builtin check in Zig Debug
    // build, panics on pasteboard file-url (downstream regression). pasteboard API only called on
    // main thread, simple lazy init sufficient.
    static NSSet<NSString *> *exts = nil;
    if (!exts) {
        exts = [[NSSet alloc] initWithArray:@[ @"png", @"jpg", @"jpeg", @"heic", @"heif",
                                               @"webp", @"gif", @"tiff", @"tif", @"bmp" ]];
    }
    return [exts containsObject:ext.lowercaseString];
}

/// get raw bytes of index-th image-containing pasteboard item. outUti returns UTI (file-url item
/// returns extension-inferred description).
static NSData *clipboardImageDataAtIndex(uint32_t index, NSString **outUti) {
    NSPasteboard *pb = zenitClipboardPasteboard();
    uint32_t seen = 0;
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSData *data = nil;
        NSString *uti = nil;
        for (NSString *t in clipboardImageDataTypes()) {
            NSData *d = [item dataForType:t];
            if (d.length > 0) { data = d; uti = t; break; }
        }
        if (!data) {
            NSString *urlStr = [item stringForType:@"public.file-url"];
            if (urlStr.length > 0) {
                NSURL *url = [NSURL URLWithString:urlStr];
                if (url.isFileURL && pathExtensionLooksLikeImage(url.pathExtension)) {
                    NSData *d = [NSData dataWithContentsOfURL:url];
                    if (d.length > 0) {
                        data = d;
                        uti = [@"file." stringByAppendingString:url.pathExtension.lowercaseString];
                    }
                }
            }
        }
        if (!data) continue;
        if (seen == index) {
            if (outUti) *outUti = uti;
            return data;
        }
        seen++;
    }
    return nil;
}

/// fallback: when pasteboard item has no raw image bytes, try NSImage to interpret whole pasteboard
/// (index 0 only), convert to TIFF for generic decode. lossy/bloated, last resort only.
static NSData *clipboardImageDataViaNSImage(void) {
    NSPasteboard *pb = zenitClipboardPasteboard();
    if (![NSImage canInitWithPasteboard:pb]) return nil;
    NSImage *img = [[NSImage alloc] initWithPasteboard:pb];
    if (!img) return nil;
    return [img TIFFRepresentation];
}

/// probe pasteboard available types (bitmask: 1=text, 2=image, 4=file_urls). no decode, negligible
/// cost.
uint32_t macos_clipboard_probe(void) {
    @autoreleasepool {
        NSPasteboard *pb = zenitClipboardPasteboard();
        uint32_t kinds = 0;
        if ([pb availableTypeFromArray:@[ NSPasteboardTypeString ]]) kinds |= 1;
        for (NSPasteboardItem *item in pb.pasteboardItems) {
            for (NSString *t in clipboardImageDataTypes()) {
                if ([item availableTypeFromArray:@[ t ]]) { kinds |= 2; break; }
            }
            NSString *urlStr = [item stringForType:@"public.file-url"];
            if (urlStr.length > 0) {
                kinds |= 4;
                NSURL *url = [NSURL URLWithString:urlStr];
                if (url.isFileURL && pathExtensionLooksLikeImage(url.pathExtension)) kinds |= 2;
            }
        }
        // NSImage fallback: some apps only put non-standard image types
        if (!(kinds & 2) && [NSImage canInitWithPasteboard:pb]) kinds |= 2;
        return kinds;
    }
}

/// count of image items in pasteboard (supports Finder multi-select copy)
uint32_t macos_clipboard_image_count(void) {
    @autoreleasepool {
        NSPasteboard *pb = zenitClipboardPasteboard();
        uint32_t count = 0;
        for (NSPasteboardItem *item in pb.pasteboardItems) {
            BOOL has = NO;
            for (NSString *t in clipboardImageDataTypes()) {
                if ([item availableTypeFromArray:@[ t ]]) { has = YES; break; }
            }
            if (!has) {
                NSString *urlStr = [item stringForType:@"public.file-url"];
                if (urlStr.length > 0) {
                    NSURL *url = [NSURL URLWithString:urlStr];
                    has = url.isFileURL && pathExtensionLooksLikeImage(url.pathExtension);
                }
            }
            if (has) count++;
        }
        // NSImage fallback: count 1 if no raw byte path but pasteboard as whole can be interpreted
        // as image
        if (count == 0 && [NSImage canInitWithPasteboard:pb]) count = 1;
        return count;
    }
}

/// read index-th item and decode to RGBA8 (premultiplied). returns malloc'd buffer, caller frees
/// with macos_free_image_data().
uint8_t *macos_clipboard_read_image(uint32_t index, uint32_t *out_width, uint32_t *out_height) {
    @autoreleasepool {
        if (!out_width || !out_height) return NULL;
        NSData *data = clipboardImageDataAtIndex(index, NULL);
        if (!data && index == 0) data = clipboardImageDataViaNSImage();
        if (!data) return NULL;
        return decode_image_data_to_rgba(data, out_width, out_height);
    }
}

/// write PNG image to pasteboard (clear original). returns 1=ok / 0=fail.
int macos_clipboard_set_image_png(const uint8_t *bytes, size_t len) {
    @autoreleasepool {
        if (!bytes || len == 0) return 0;
        NSData *data = [NSData dataWithBytes:bytes length:len];
        NSPasteboard *pb = zenitClipboardPasteboard();
        [pb clearContents];
        return [pb setData:data forType:NSPasteboardTypePNG] ? 1 : 0;
    }
}

/// read index-th item's raw encoded bytes (no decode), for as-is archival. returns malloc'd buffer,
/// caller frees with macos_free_image_data(). uti_buf (may be NULL) writes NUL-terminated UTI
/// string.
uint8_t *macos_clipboard_read_image_bytes(uint32_t index, size_t *out_len,
                                          char *uti_buf, size_t uti_buf_len) {
    @autoreleasepool {
        if (!out_len) return NULL;
        *out_len = 0;
        NSString *uti = nil;
        NSData *data = clipboardImageDataAtIndex(index, &uti);
        if (!data) return NULL;
        uint8_t *bytes = malloc(data.length);
        if (!bytes) return NULL;
        memcpy(bytes, data.bytes, data.length);
        *out_len = data.length;
        if (uti_buf && uti_buf_len > 0) {
            const char *s = uti ? uti.UTF8String : "";
            strlcpy(uti_buf, s, uti_buf_len);
        }
        return bytes;
    }
}
