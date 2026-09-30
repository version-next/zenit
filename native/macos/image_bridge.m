#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
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
            // 本地文件：直接读取（支持相对和绝对路径）
            NSString *path = [urlString substringFromIndex:7];
            data = [NSData dataWithContentsOfFile:path];
        } else {
            // 远程 URL：通过网络下载
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

/// 将 RGBA8 像素写入 PNG 文件。
/// 返回 0 成功，-1 参数错误，-2 编码失败，-3 写盘失败。
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
        planes[0] = (unsigned char *)rgba; // NSBitmapImageRep 不会拷贝，调用方需保证内存在函数返回前有效
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

        // 解码端(macos_decode_image_file)输出的是 sRGB 像素;这里必须
        // 同样打 sRGB 标签,否则解码→编码往返会叠加一次 GenericRGB↔sRGB
        // 转换,像素值逐次漂移(整图褪色)。retag 只换标签不动像素。
        rep = [rep bitmapImageRepByRetaggingWithColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!rep) return -2;

        NSDictionary *props = @{};
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:props];
        if (!png || png.length == 0) return -2;

        if (![png writeToFile:path atomically:YES]) return -3;
        return 0;
    }
}

// ===== 异步下载 + 文件解码（后台线程调用）=====

/// 解码内存数据到 RGBA（内部共用逻辑）
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

/// 使用 NSURLSession 下载图片到磁盘文件（后台线程调用，阻塞当前线程）
/// 返回: 0 成功, -1 网络错误, -2 文件写入错误
int macos_download_image_to_file(const char* url_cstr, const char* dest_path) {
    @autoreleasepool {
        if (!url_cstr || !dest_path) return -1;

        NSString *urlString = [NSString stringWithUTF8String:url_cstr];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) return -1;

        NSString *destString = [NSString stringWithUTF8String:dest_path];

        // 使用 dispatch_semaphore 使异步 NSURLSession 在后台线程上同步等待
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
                // 检查 HTTP 状态码
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

        // 等待完成（在后台线程阻塞可以接受）
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        [session finishTasksAndInvalidate];

        if (downloadError || !downloadedData || downloadedData.length == 0) {
            return -1;
        }

        // 先写到临时文件，再 atomic rename
        NSString *tmpPath = [destString stringByAppendingString:@".tmp"];
        if (![downloadedData writeToFile:tmpPath atomically:NO]) {
            return -2;
        }

        NSError *moveError = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        // 如果目标已存在则先删除
        [fm removeItemAtPath:destString error:nil];
        if (![fm moveItemAtPath:tmpPath toPath:destString error:&moveError]) {
            [fm removeItemAtPath:tmpPath error:nil];
            return -2;
        }

        return 0;
    }
}

/// 从文件解码为 RGBA（后台线程调用）
/// 返回 malloc'd RGBA buffer，调用者需通过 macos_free_image_data 释放
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

/// 用系统默认应用（浏览器）打开 URL。返回 1=ok / 0=fail
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

// ===== 剪贴板图片读取 =====
//
// 类型优先级（探测顺序，直接决定粘贴成功率）：
//   public.png → public.jpeg → public.heic → public.tiff（macOS 截图工具常给 TIFF）
//   → public.file-url（Finder 复制文件，扩展名过滤图片）
// 优先取原始编码字节；不走 NSImage（会丢原始编码，重编码有损且膨胀）。

static NSArray<NSString *> *clipboardImageDataTypes(void) {
    return @[ @"public.png", @"public.jpeg", @"public.heic", @"public.tiff" ];
}

static BOOL pathExtensionLooksLikeImage(NSString *ext) {
    if (ext.length == 0) return NO;
    // 不用 dispatch_once：其内联宏会触发 Zig Debug 构建的 UBSan
    // invalid-builtin 检查，剪贴板含 file-url 时直接 panic（下游回归）。
    // 剪贴板 API 只在主线程调用，平凡懒初始化足够。
    static NSSet<NSString *> *exts = nil;
    if (!exts) {
        exts = [[NSSet alloc] initWithArray:@[ @"png", @"jpg", @"jpeg", @"heic", @"heif",
                                               @"webp", @"gif", @"tiff", @"tif", @"bmp" ]];
    }
    return [exts containsObject:ext.lowercaseString];
}

/// 取第 index 个含图片的剪贴板项的原始字节。outUti 返回 UTI（file-url 项返回扩展名推断的描述）。
static NSData *clipboardImageDataAtIndex(uint32_t index, NSString **outUti) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
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

/// 兜底：pasteboard 项没有原始图片字节时，试着让 NSImage 解释整个剪贴板
/// （只对 index 0 生效），转 TIFF 交给通用解码。有损/膨胀，故仅作最后手段。
static NSData *clipboardImageDataViaNSImage(void) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    if (![NSImage canInitWithPasteboard:pb]) return nil;
    NSImage *img = [[NSImage alloc] initWithPasteboard:pb];
    if (!img) return nil;
    return [img TIFFRepresentation];
}

/// 探测剪贴板可提供的类型（位掩码：1=text, 2=image, 4=file_urls）。不解码，成本极低。
uint32_t macos_clipboard_probe(void) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
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
        // NSImage 兜底：某些应用只放非标准图片类型
        if (!(kinds & 2) && [NSImage canInitWithPasteboard:pb]) kinds |= 2;
        return kinds;
    }
}

/// 剪贴板中的图片项数（支持 Finder 多选复制）
uint32_t macos_clipboard_image_count(void) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
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
        // NSImage 兜底：原始字节路径全空但剪贴板整体可作图片解释时算 1 项
        if (count == 0 && [NSImage canInitWithPasteboard:pb]) count = 1;
        return count;
    }
}

/// 读取第 index 项并解码为 RGBA8（premultiplied）。
/// 返回 malloc'd buffer，调用方用 macos_free_image_data() 释放。
uint8_t *macos_clipboard_read_image(uint32_t index, uint32_t *out_width, uint32_t *out_height) {
    @autoreleasepool {
        if (!out_width || !out_height) return NULL;
        NSData *data = clipboardImageDataAtIndex(index, NULL);
        if (!data && index == 0) data = clipboardImageDataViaNSImage();
        if (!data) return NULL;
        return decode_image_data_to_rgba(data, out_width, out_height);
    }
}

/// 写入 PNG 图片到剪贴板（清空原内容）。返回 1=ok / 0=fail。
int macos_clipboard_set_image_png(const uint8_t *bytes, size_t len) {
    @autoreleasepool {
        if (!bytes || len == 0) return 0;
        NSData *data = [NSData dataWithBytes:bytes length:len];
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        return [pb setData:data forType:NSPasteboardTypePNG] ? 1 : 0;
    }
}

/// 读取第 index 项的原始编码字节（不解码），用于原样归档。
/// 返回 malloc'd buffer，调用方用 macos_free_image_data() 释放。
/// uti_buf（可为 NULL）写入 NUL 结尾的 UTI 字符串。
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
