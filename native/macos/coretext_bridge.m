#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <math.h>

// ============================================================================
// Font Creation
// ============================================================================

/// Derive a new CTFont from an existing one at a different size.
/// Preserves all variation axes (weight, italic) from the original font.
void* coretext_derive_font(void* existing_font, float new_size) {
    CTFontRef src = (CTFontRef)existing_font;
    // CTFontCreateCopyWithAttributes with NULL descriptor preserves all axes
    CTFontRef derived = CTFontCreateCopyWithAttributes(src, new_size, NULL, NULL);
    if (!derived) {
        NSLog(@"[CoreText] coretext_derive_font: failed to derive at size %.1f", new_size);
        return NULL;
    }
    return (void*)derived;
}

char* coretext_font_copy_debug_name(void* font) {
    @autoreleasepool {
        if (!font) return NULL;

        CTFontRef ctFont = (CTFontRef)font;
        CFStringRef fullNameRef = CTFontCopyFullName(ctFont);
        CFStringRef familyRef = CTFontCopyFamilyName(ctFont);
        CFStringRef postScriptRef = CTFontCopyPostScriptName(ctFont);
        float size = (float)CTFontGetSize(ctFont);

        NSString *fullName = fullNameRef ? (__bridge_transfer NSString *)fullNameRef : @"<unknown>";
        NSString *familyName = familyRef ? (__bridge_transfer NSString *)familyRef : @"<unknown>";
        NSString *postScriptName = postScriptRef ? (__bridge_transfer NSString *)postScriptRef : @"<unknown>";
        NSString *debugName = [NSString stringWithFormat:@"%@ | family=%@ | ps=%@ | size=%.2f",
                               fullName, familyName, postScriptName, size];
        const char *utf8 = debugName.UTF8String;
        if (!utf8) return NULL;

        size_t len = strlen(utf8);
        char *out = (char *)malloc(len + 1);
        if (!out) return NULL;
        memcpy(out, utf8, len + 1);
        return out;
    }
}

void coretext_free_c_string(char* str) {
    if (str) free(str);
}

/// Create a font from a file path at a specific size
void* coretext_create_font_from_path(const char* path, float size) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSURL *url = [NSURL fileURLWithPath:nsPath];

        CGDataProviderRef provider = CGDataProviderCreateWithURL((__bridge CFURLRef)url);
        if (!provider) {
            NSLog(@"[CoreText] Failed to create data provider for: %s", path);
            return NULL;
        }

        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            NSLog(@"[CoreText] Failed to create CGFont from: %s", path);
            return NULL;
        }

        CTFontRef font = CTFontCreateWithGraphicsFont(cgFont, size, NULL, NULL);
        CGFontRelease(cgFont);

        if (!font) {
            NSLog(@"[CoreText] Failed to create CTFont from: %s", path);
            return NULL;
        }

        NSLog(@"[CoreText] Loaded font from path: %s @ %.0fpt", path, size);
        return (void*)font;
    }
}

/// Find a system font by family name, size, weight, and italic flag
void* coretext_find_font(const char* family, float size, int weight, int italic) {
    @autoreleasepool {
        // Map weight int to CTFontWeight
        // weight: 100=thin, 200=ultralight, 300=light, 400=regular,
        //         500=medium, 600=semibold, 700=bold, 800=heavy, 900=black
        CGFloat ctWeight;
        if (weight <= 100) ctWeight = -0.8;        // UIFontWeightUltraLight
        else if (weight <= 200) ctWeight = -0.6;   // UIFontWeightThin
        else if (weight <= 300) ctWeight = -0.4;   // UIFontWeightLight
        else if (weight <= 400) ctWeight = 0.0;    // UIFontWeightRegular
        else if (weight <= 500) ctWeight = 0.23;   // UIFontWeightMedium
        else if (weight <= 600) ctWeight = 0.3;    // UIFontWeightSemibold
        else if (weight <= 700) ctWeight = 0.4;    // UIFontWeightBold
        else if (weight <= 800) ctWeight = 0.56;   // UIFontWeightHeavy
        else ctWeight = 0.62;                      // UIFontWeightBlack

        NSString *familyName = [NSString stringWithUTF8String:family];

        // Build font attributes
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        attrs[(id)kCTFontFamilyNameAttribute] = familyName;
        attrs[(id)kCTFontSizeAttribute] = @(size);

        // Build traits
        NSMutableDictionary *traits = [NSMutableDictionary dictionary];
        traits[(id)kCTFontWeightTrait] = @(ctWeight);
        if (italic) {
            // 使用 symbolic trait 请求 italic 变体
            traits[(id)kCTFontSymbolicTrait] = @(kCTFontItalicTrait);
        }
        attrs[(id)kCTFontTraitsAttribute] = traits;

        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
        CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
        CFRelease(descriptor);

        if (!font) {
            NSLog(@"[CoreText] Failed to find font: %s", family);
            return NULL;
        }

        // 验证返回的字体确实包含 italic trait
        if (italic) {
            CTFontSymbolicTraits actualTraits = CTFontGetSymbolicTraits(font);
            if (!(actualTraits & kCTFontItalicTrait)) {
                // 字体族没有 italic 变体，CoreText 回退到了非 italic
                NSLog(@"[CoreText] Font %s has no italic variant, rejecting", family);
                CFRelease(font);
                return NULL;
            }
        }

        const char *style = italic ? "italic" : "regular";
        NSLog(@"[CoreText] Found system font: %s @ %.0fpt (weight=%d, style=%s)", family, size, weight, style);
        return (void*)font;
    }
}

/// Create a font from a file path with Variable Font weight/italic axis support
/// weight: CSS numeric weight (400=regular, 600=semibold, 700=bold, etc.)
/// italic: 0=normal, 1=italic (sets 'ital' axis to 1.0)
void* coretext_create_font_from_path_weighted(const char* path, float size, int weight, int italic) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSURL *url = [NSURL fileURLWithPath:nsPath];

        CGDataProviderRef provider = CGDataProviderCreateWithURL((__bridge CFURLRef)url);
        if (!provider) {
            NSLog(@"[CoreText] Failed to create data provider for: %s", path);
            return NULL;
        }

        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            NSLog(@"[CoreText] Failed to create CGFont from: %s", path);
            return NULL;
        }

        // Step 1: Create base CTFont from CGFont (no variation yet)
        CTFontRef baseFont = CTFontCreateWithGraphicsFont(cgFont, size, NULL, NULL);
        CGFontRelease(cgFont);
        if (!baseFont) {
            NSLog(@"[CoreText] Failed to create base CTFont from: %s", path);
            return NULL;
        }

        // Step 2: Apply variation axes via CTFontCreateCopyWithAttributes
        // kCTFontVariationAttribute expects dict of { NSNumber(axis_tag) : NSNumber(value) }
        NSMutableDictionary *variations = [NSMutableDictionary dictionary];
        variations[@(0x77676874)] = @((CGFloat)weight);  // 'wght'
        if (italic) {
            variations[@(0x6974616C)] = @(1.0);          // 'ital'
        }

        NSDictionary *varAttrs = @{
            (id)kCTFontVariationAttribute: variations
        };
        CTFontDescriptorRef varDesc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)varAttrs);
        CTFontRef font = CTFontCreateCopyWithAttributes(baseFont, size, NULL, varDesc);
        CFRelease(varDesc);
        CFRelease(baseFont);

        if (!font) {
            NSLog(@"[CoreText] Failed to create VF CTFont from: %s", path);
            return NULL;
        }

        const char *style = italic ? "italic" : "regular";
        NSLog(@"[CoreText] Loaded VF font: %s @ %.0fpt (weight=%d, style=%s)", path, size, weight, style);
        return (void*)font;
    }
}

/// Release a font
void coretext_release_font(void* font) {
    if (font) {
        CFRelease((CTFontRef)font);
    }
}

/// Retain a font (increment reference count)
void coretext_retain_font(void* font) {
    if (font) {
        CFRetain((CTFontRef)font);
    }
}

// ============================================================================
// Font Metrics
// ============================================================================

float coretext_font_get_ascent(void* font) {
    return (float)CTFontGetAscent((CTFontRef)font);
}

float coretext_font_get_descent(void* font) {
    return (float)CTFontGetDescent((CTFontRef)font);
}

float coretext_font_get_leading(void* font) {
    return (float)CTFontGetLeading((CTFontRef)font);
}

unsigned int coretext_font_get_units_per_em(void* font) {
    return (unsigned int)CTFontGetUnitsPerEm((CTFontRef)font);
}

float coretext_font_get_size(void* font) {
    return (float)CTFontGetSize((CTFontRef)font);
}

/// 字体的**稳定身份** hash：PostScript 名 + size + symbolic traits 的 FNV-1a。
///
/// 动机：CoreText 每次 shape 返回的 run 级 fallback CTFontRef **不是稳定
/// 指针**——同一个 "PingFangSC-Regular 14pt" 在两次 shape 里是两个实例。
/// 以指针为缓存键会导致 wrapper Font 每帧重建（实测滚动 CJK 文档时
/// 240 帧创建 36 万个 wrapper），进而让 glyph atlas 以不同 font_ptr 重复
/// 收录同一字形，直至 32 页耗尽、后续字形被静默丢弃（用户可见：中文
/// 逐字消失、位置留白、ASCII 不受影响）。
unsigned long long coretext_font_identity_hash(void* font) {
    CTFontRef f = (CTFontRef)font;
    unsigned long long h = 1469598103934665603ULL;
    CFStringRef name = CTFontCopyPostScriptName(f);
    if (name) {
        char buf[256];
        if (CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            for (const char* q = buf; *q; q++) { h ^= (unsigned char)*q; h *= 1099511628211ULL; }
        }
        CFRelease(name);
    }
    float size = (float)CTFontGetSize(f);
    unsigned int sbits; memcpy(&sbits, &size, sizeof(sbits));
    h ^= sbits; h *= 1099511628211ULL;
    unsigned int traits = (unsigned int)CTFontGetSymbolicTraits(f);
    h ^= traits; h *= 1099511628211ULL;
    return h;
}

/// Helper: create a CTFont from weight (CSS numeric weight: 400=regular, 700=bold, etc.)
static CTFontRef createFontWithWeight(float font_size, int weight) {
    CGFloat ctWeight;
    if (weight <= 100) ctWeight = -0.8;
    else if (weight <= 200) ctWeight = -0.6;
    else if (weight <= 300) ctWeight = -0.4;
    else if (weight <= 400) ctWeight = 0.0;
    else if (weight <= 500) ctWeight = 0.23;
    else if (weight <= 600) ctWeight = 0.3;
    else if (weight <= 700) ctWeight = 0.4;
    else if (weight <= 800) ctWeight = 0.56;
    else ctWeight = 0.62;

    CTFontRef sysFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, font_size, NULL);
    if (!sysFont) return NULL;

    NSDictionary *traits = @{ (id)kCTFontWeightTrait: @(ctWeight) };
    NSDictionary *attrs = @{
        (id)kCTFontFamilyNameAttribute: @"PingFang SC",
        (id)kCTFontTraitsAttribute: traits
    };
    CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
    CTFontRef font = CTFontCreateCopyWithAttributes(sysFont, font_size, NULL, desc);
    CFRelease(desc);
    CFRelease(sysFont);
    return font;
}

static int cssWeightFromCTFont(CTFontRef font) {
    if (!font) return 400;

    CFDictionaryRef traits = CTFontCopyTraits(font);
    if (!traits) return 400;

    CGFloat ctWeight = 0.0;
    CFNumberRef weightNumber = CFDictionaryGetValue(traits, kCTFontWeightTrait);
    if (weightNumber) {
        CFNumberGetValue(weightNumber, kCFNumberCGFloatType, &ctWeight);
    }
    CFRelease(traits);

    if (ctWeight <= -0.7) return 100;
    if (ctWeight <= -0.5) return 200;
    if (ctWeight <= -0.2) return 300;
    if (ctWeight <= 0.1) return 400;
    if (ctWeight <= 0.26) return 500;
    if (ctWeight <= 0.35) return 600;
    if (ctWeight <= 0.48) return 700;
    if (ctWeight <= 0.59) return 800;
    return 900;
}

static int shouldPreferSymbolFallbackForCodepoint(uint32_t codepoint) {
    return codepoint >= 0x2460 && codepoint <= 0x24FF;
}

/// SMP emoji 平面（U+1F000–U+1FAFF：enclosed ideographs 🈶、旗帜、表情、
/// 交通、补充符号等）默认 emoji 呈现。必须给这些码点**显式**指定
/// Apple Color Emoji：CoreText 的 cascade 是 run 上下文相关的——
/// 同一个 🈶 孤立塑形（渲染端 per-codepoint 分段）解析到 Apple Color
/// Emoji（advance ~1.33em），跟在 CJK run 后整串塑形（度量/caret 端
/// CTLine）却被 PingFang 接走（advance 1em）——分段与整串两条路径的
/// advance 不一致 = 光标/选区/宽度回写全部错位。统一强制 emoji 字体后
/// 两条路径 run 划分一致。VS15 (U+FE0E) 显式要求文本呈现时跳过。
///
/// ⚠ 强制必须按 **ZWJ 序列**整体覆盖，不能逐码点：ZWJ (U+200D) 是 BMP
/// 字符，若只给 SMP 成员标 emoji 字体，序列被切成多个 attribute run，
/// CTLine 不跨 run 结扎——👨‍👩‍👧 会碎成三个独立人形（实测 21→63px）。
static int shouldForceEmojiFallbackForCodepoint(uint32_t codepoint) {
    return codepoint >= 0x1F000 && codepoint <= 0x1FAFF;
}

static CTFontRef createEmojiFallbackFont(CTFontRef baseFont) {
    const float fontSize = baseFont ? (float)CTFontGetSize(baseFont) : 14.0f;
    return CTFontCreateWithName(CFSTR("AppleColorEmoji"), fontSize, NULL);
}

static CTFontRef createPreferredSymbolFallbackFontForBaseFont(CTFontRef baseFont) {
    const float fontSize = baseFont ? (float)CTFontGetSize(baseFont) : 14.0f;
    const int fontWeight = cssWeightFromCTFont(baseFont);
    return createFontWithWeight(fontSize, fontWeight);
}

static NSAttributedString* createAttributedStringWithPreferredSymbolFallback(NSString *text, CTFontRef baseFont) {
    NSDictionary *attrs = @{
        (id)kCTFontAttributeName: (__bridge id)baseFont
    };
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text
                                                                             attributes:attrs];

    CTFontRef fallbackFont = NULL;
    CTFontRef emojiFont = NULL;
    const NSUInteger utf16Len = text.length;
    for (NSUInteger i = 0; i < utf16Len; i++) {
        unichar ch = [text characterAtIndex:i];
        uint32_t codepoint = ch;
        NSUInteger charLen = 1;
        if (CFStringIsSurrogateHighCharacter(ch) && i + 1 < utf16Len) {
            unichar low = [text characterAtIndex:(i + 1)];
            if (CFStringIsSurrogateLowCharacter(low)) {
                codepoint = CFStringGetLongCharacterForSurrogatePair(ch, low);
                charLen = 2;
            }
        }

        if (shouldPreferSymbolFallbackForCodepoint(codepoint)) {
            if (!fallbackFont) {
                fallbackFont = createPreferredSymbolFallbackFontForBaseFont(baseFont);
            }
            if (fallbackFont) {
                [attr addAttribute:(id)kCTFontAttributeName
                             value:(__bridge id)fallbackFont
                             range:NSMakeRange(i, charLen)];
            }
        }

        i += charLen - 1;
    }

    // 第二遍：emoji 强制，按 ZWJ 连接的整个序列（cluster）为单位。
    // cluster = 若干成员码点（各可带 VS16/VS15），成员之间由 ZWJ 连接。
    // 任一成员落在强制范围且未被 VS15 显式转文本呈现 → 整个 cluster
    // （含 ZWJ、VS16 与 BMP 成员如 ❤）统一覆盖同一 emojiFont 实例，
    // 保证度量/渲染/caret 三路 run 划分一致且序列不被拆散。
    NSUInteger ci = 0;
    while (ci < utf16Len) {
        const NSUInteger clusterStart = ci;
        BOOL forced = NO;
        while (ci < utf16Len) {
            unichar ch = [text characterAtIndex:ci];
            uint32_t codepoint = ch;
            NSUInteger charLen = 1;
            if (CFStringIsSurrogateHighCharacter(ch) && ci + 1 < utf16Len) {
                unichar low = [text characterAtIndex:(ci + 1)];
                if (CFStringIsSurrogateLowCharacter(low)) {
                    codepoint = CFStringGetLongCharacterForSurrogatePair(ch, low);
                    charLen = 2;
                }
            }
            BOOL memberForced = shouldForceEmojiFallbackForCodepoint(codepoint) ? YES : NO;
            ci += charLen;
            if (ci < utf16Len) {
                unichar vs = [text characterAtIndex:ci];
                if (vs == 0xFE0E) { // VS15：该成员显式文本呈现
                    memberForced = NO;
                    ci += 1;
                } else if (vs == 0xFE0F) { // VS16：显式 emoji 呈现
                    ci += 1;
                }
            }
            if (memberForced) forced = YES;
            // 仅 ZWJ 延续 cluster；其余任何字符都结束当前 cluster
            if (ci < utf16Len && [text characterAtIndex:ci] == 0x200D) {
                ci += 1;
                continue;
            }
            break;
        }
        if (forced) {
            if (!emojiFont) emojiFont = createEmojiFallbackFont(baseFont);
            if (emojiFont) {
                [attr addAttribute:(id)kCTFontAttributeName
                             value:(__bridge id)emojiFont
                             range:NSMakeRange(clusterStart, ci - clusterStart)];
            }
        }
    }

    if (fallbackFont) CFRelease(fallbackFont);
    if (emojiFont) CFRelease(emojiFont);
    return attr;
}

/// Measure UTF-8 text width using an existing CTFontRef (no font creation/release)
float coretext_measure_text_width_with_font(void* font_ptr, const char* text, int len) {
    @autoreleasepool {
        if (!font_ptr || !text || len <= 0) return 0.0f;

        NSString *nsText = [[NSString alloc] initWithBytes:text
                                                    length:(NSUInteger)len
                                                  encoding:NSUTF8StringEncoding];
        if (!nsText || nsText.length == 0) return 0.0f;

        CTFontRef font = (CTFontRef)font_ptr;
        NSAttributedString *attr = createAttributedStringWithPreferredSymbolFallback(nsText, font);
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);

        CFRelease(line);
        return (float)width;
    }
}

/// Measure UTF-8 text width with macOS text shaping (logical pixels)
float coretext_measure_text_width_utf8(const char* text, int len, float font_size) {
    if (!text || len <= 0) return 0.0f;

    NSString *nsText = [[NSString alloc] initWithBytes:text
                                                length:(NSUInteger)len
                                              encoding:NSUTF8StringEncoding];
    if (!nsText || nsText.length == 0) return 0.0f;

    CTFontRef font = CTFontCreateWithName(CFSTR("PingFang SC"), font_size, NULL);
    if (!font) {
        font = CTFontCreateWithName(CFSTR("Helvetica Neue"), font_size, NULL);
    }
    if (!font) return 0.0f;

    NSDictionary *attrs = @{
        (id)kCTFontAttributeName: (__bridge id)font
    };
    NSAttributedString *attr = [[NSAttributedString alloc] initWithString:nsText attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);

    CFRelease(line);
    CFRelease(font);
    return (float)width;
}

/// Measure UTF-8 text width with font weight support (logical pixels)
float coretext_measure_text_width_weighted(const char* text, int len, float font_size, int font_weight) {
    @autoreleasepool {
        if (!text || len <= 0) return 0.0f;
        // weight == 400 直接走原有逻辑（性能优化）
        if (font_weight <= 400) return coretext_measure_text_width_utf8(text, len, font_size);

        NSString *nsText = [[NSString alloc] initWithBytes:text
                                                    length:(NSUInteger)len
                                                  encoding:NSUTF8StringEncoding];
        if (!nsText || nsText.length == 0) return 0.0f;

        CTFontRef font = createFontWithWeight(font_size, font_weight);
        if (!font) return coretext_measure_text_width_utf8(text, len, font_size);

        NSDictionary *attrs = @{
            (id)kCTFontAttributeName: (__bridge id)font
        };
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:nsText attributes:attrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);

        CFRelease(line);
        CFRelease(font);
        return (float)width;
    }
}

/// Get glyph index for a character
unsigned int coretext_font_get_glyph_index(void* font, unsigned int codepoint) {
    @autoreleasepool {
        UniChar chars[2];
        CGGlyph glyphs[2];
        int count;

        // Handle surrogate pairs for codepoints > 0xFFFF
        if (codepoint > 0xFFFF) {
            codepoint -= 0x10000;
            chars[0] = (UniChar)(0xD800 + (codepoint >> 10));
            chars[1] = (UniChar)(0xDC00 + (codepoint & 0x3FF));
            count = 2;
        } else {
            chars[0] = (UniChar)codepoint;
            count = 1;
        }

        if (CTFontGetGlyphsForCharacters((CTFontRef)font, chars, glyphs, count)) {
            return (unsigned int)glyphs[0];
        }
        return 0;
    }
}

// ============================================================================
// Glyph Rasterization
// ============================================================================

/// 判断字体是否含彩色字形表。
///
/// 为什么按**字体**判定而不是按 codepoint 的 Extended_Pictographic 判定：
/// 真正决定光栅化结果是否有颜色的是最终选中的那个字体 —— 同一个
/// pictographic 码点在 text-presentation（VS15）或在只有黑白字形的字体里
/// 落下来仍然是单通道覆盖率；反过来某些非 pictographic 码点（旗帜 tag
/// 序列、部分符号）在 Apple Color Emoji 里是彩色的。CoreText fallback
/// 已经把"用哪个字体画"解析好了，直接查那个字体的表是无歧义的信号。
///
/// sbix = Apple 位图（Apple Color Emoji）、COLR = 分层矢量（Windows/Noto）、
/// CBDT = Google 位图。三者覆盖了实际会遇到的全部彩色字形格式。
int coretext_font_has_color_glyphs(void* font_ptr) {
    @autoreleasepool {
        if (!font_ptr) return 0;
        CTFontRef font = (CTFontRef)font_ptr;

        // CTFontGetSymbolicTraits 的 kCTFontTraitColorGlyphs 是最直接的信号，
        // 但它对某些第三方彩色字体不置位，所以再查表兜底。
        if (CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs) {
            return 1;
        }

        const uint32_t tags[3] = {
            kCTFontTableSbix,
            kCTFontTableCOLR,
            'CBDT',
        };
        for (int i = 0; i < 3; i++) {
            CFDataRef table = CTFontCopyTable(font, (CTFontTableTag)tags[i],
                                              kCTFontTableOptionNoOptions);
            if (table) {
                CFRelease(table);
                return 1;
            }
        }
        return 0;
    }
}

// Forward declaration for subpixel variant
int coretext_rasterize_glyph_subpixel(
    void* font_ptr, unsigned int glyph_index, float scale_factor,
    float subpixel_offset_x, float subpixel_offset_y,
    unsigned char** out_pixels, unsigned int* out_width, unsigned int* out_height,
    int* out_bearing_x, int* out_bearing_y, int* out_advance, int* out_is_color);

/// Rasterize a glyph to a grayscale bitmap
/// Returns 0 on success, -1 on failure
/// out_pixels is allocated by this function, caller must free with coretext_free_bitmap
int coretext_rasterize_glyph(
    void* font_ptr,
    unsigned int glyph_index,
    float scale_factor,
    unsigned char** out_pixels,
    unsigned int* out_width,
    unsigned int* out_height,
    int* out_bearing_x,
    int* out_bearing_y,
    int* out_advance,
    int* out_is_color
) {
    // 默认子像素偏移 = 0
    return coretext_rasterize_glyph_subpixel(font_ptr, glyph_index, scale_factor,
        0.0f, 0.0f, out_pixels, out_width, out_height, out_bearing_x, out_bearing_y,
        out_advance, out_is_color);
}

/// Rasterize glyph with subpixel offset (R6: 子像素变体)
/// subpixel_offset_x/y: 物理像素内的亚像素偏移 [0.0, 1.0)
int coretext_rasterize_glyph_subpixel(
    void* font_ptr,
    unsigned int glyph_index,
    float scale_factor,
    float subpixel_offset_x,
    float subpixel_offset_y,
    unsigned char** out_pixels,
    unsigned int* out_width,
    unsigned int* out_height,
    int* out_bearing_x,
    int* out_bearing_y,
    int* out_advance,
    int* out_is_color
) {
    @autoreleasepool {
        CTFontRef font = (CTFontRef)font_ptr;
        CGGlyph glyph = (CGGlyph)glyph_index;
        if (out_is_color) *out_is_color = 0;
        float scale = (scale_factor > 0) ? scale_factor : 1.0f;

        // Get glyph bounding rect (logical pixels)
        CGRect bbox = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, &glyph, NULL, 1);

        // Get advance (logical pixels — unchanged)
        CGSize advanceSize;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &glyph, &advanceSize, 1);

        *out_advance = (int)ceil(advanceSize.width);

        // Invalid bbox (NaN from Variable Font .notdef glyph)
        if (isnan(bbox.size.width) || isnan(bbox.size.height) ||
            isnan(bbox.origin.x) || isnan(bbox.origin.y)) {
            *out_pixels = NULL;
            *out_width = 0;
            *out_height = 0;
            *out_bearing_x = 0;
            *out_bearing_y = 0;
            return 0;
        }

        // Empty glyph (e.g., space) — use <= 0 threshold to avoid filtering narrow glyphs like 'i', 'l'
        if (bbox.size.width <= 0 || bbox.size.height <= 0) {
            *out_pixels = NULL;
            *out_width = 0;
            *out_height = 0;
            *out_bearing_x = 0;
            *out_bearing_y = 0;
            return 0;
        }

        // Calculate bitmap dimensions in physical pixels with padding
        // R6: 加上子像素偏移，影响 origin 的 floor/ceil 计算
        const float origin_x_px = (float)bbox.origin.x * scale + subpixel_offset_x;
        const float origin_y_px = (float)bbox.origin.y * scale + subpixel_offset_y;
        const float origin_x_px_floor = floor(origin_x_px);
        const float origin_y_px_floor = floor(origin_y_px);

        // 子像素偏移可能让字形比原来宽/高 1 个像素
        unsigned int width = (unsigned int)ceil(bbox.size.width * scale + subpixel_offset_x) + 2;
        unsigned int height = (unsigned int)ceil(bbox.size.height * scale + subpixel_offset_y) + 2;

        *out_width = width;
        *out_height = height;
        // Bearings are in physical pixels (match bitmap + 1px padding)
        *out_bearing_x = (int)origin_x_px_floor - 1;
        // bearing_y = height - baseline_y; baseline_y = 1 - origin_y_px_floor
        *out_bearing_y = (int)height - 1 + (int)origin_y_px_floor;

        // 彩色字形（emoji）走 BGRA premultiplied 上下文：DeviceGray + AlphaNone
        // 只能存覆盖率，颜色信息在光栅化那一刻就丢了，后面任何 shader 都救不回来。
        const int is_color = coretext_font_has_color_glyphs(font_ptr);
        if (out_is_color) *out_is_color = is_color;

        const unsigned int bytes_per_pixel = is_color ? 4u : 1u;
        const unsigned int bytes_per_row = width * bytes_per_pixel;

        // Allocate pixel buffer (physical pixels)
        unsigned char* pixels = (unsigned char*)calloc(width * height, bytes_per_pixel);
        if (!pixels) {
            return -1;
        }

        // Create bitmap context at physical pixel size
        CGColorSpaceRef colorSpace = is_color ? CGColorSpaceCreateDeviceRGB()
                                              : CGColorSpaceCreateDeviceGray();
        // BGRA8Unorm 纹理在小端下对应 kCGImageAlphaPremultipliedFirst |
        // kCGBitmapByteOrder32Little（内存序 B,G,R,A）。
        const CGBitmapInfo bitmap_info = is_color
            ? (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little)
            : (CGBitmapInfo)kCGImageAlphaNone;
        CGContextRef ctx = CGBitmapContextCreate(
            pixels,
            width,
            height,
            8,              // bits per component
            bytes_per_row,
            colorSpace,
            bitmap_info
        );
        CGColorSpaceRelease(colorSpace);

        if (!ctx) {
            free(pixels);
            return -1;
        }

        // Scale context so CoreText renders at physical resolution
        CGContextScaleCTM(ctx, scale, scale);

        // Set up context for rendering
        // 彩色字形自带颜色（sbix/COLR），不需要也不能被 fill color 覆盖。
        if (!is_color) {
            CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        }
        CGContextSetAllowsAntialiasing(ctx, true);
        CGContextSetShouldAntialias(ctx, true);
        // 保持字形边缘平滑，避免小字号/CJK 观感发虚发毛。
        CGContextSetAllowsFontSmoothing(ctx, true);
        CGContextSetShouldSmoothFonts(ctx, true);
        CGContextSetAllowsFontSubpixelPositioning(ctx, true);
        CGContextSetShouldSubpixelPositionFonts(ctx, true);
        // 关闭量化，配合 atlas 子像素变体获得更稳定的细节。
        CGContextSetAllowsFontSubpixelQuantization(ctx, false);
        CGContextSetShouldSubpixelQuantizeFonts(ctx, false);

        // Position glyph (in logical coordinates — CTM handles scaling)
        // R6: 子像素偏移通过精确的位置传递给 CoreText
        CGPoint position = CGPointMake(
            (-origin_x_px_floor + 1.0f) / scale,
            (-origin_y_px_floor + 1.0f) / scale
        );

        // Draw glyph
        CTFontDrawGlyphs(font, &glyph, &position, 1, ctx);

        CGContextRelease(ctx);

        *out_pixels = pixels;
        return 0;
    }
}

/// Free bitmap allocated by coretext_rasterize_glyph
void coretext_free_bitmap(unsigned char* pixels) {
    if (pixels) {
        free(pixels);
    }
}

// ============================================================================
// Text Shaping
// ============================================================================

/// Shaped glyph result (C struct)
typedef struct {
    unsigned int glyph_index;
    unsigned int cluster;
    float x_advance;
    float y_advance;
    float x_offset;
    float y_offset;
    unsigned int is_synthetic_italic; // 1 if this glyph needs synthetic italic skew at render time
    unsigned int is_fallback_font;    // 1 if this glyph uses a fallback font (e.g. CJK)
    void* fallback_font_ref;          // retained CTFontRef of the actual fallback font (NULL if not fallback)
} CoreTextShapedGlyph;

typedef struct {
    unsigned int byte_offset;
    float primary_x;
    float secondary_x;
    unsigned int has_secondary;
} CoreTextCaretStop;

typedef struct {
    float width;
    float ascent;
    float descent;
    float leading;
    unsigned int base_rtl;
} CoreTextLineMetrics;

// Foundation 的 UTF-8 解码（initWithBytes / CFStringCreateWithBytes）会静默
// 吃掉**开头**的 BOM（EF BB BF → U+FEFF）。调用方给的是 UTF-8 字节偏移，一旦
// NSString 少了这个 U+FEFF，UTF-8↔UTF-16 映射整体错位 3 字节：cluster 偏移
// 全错、caret stops 在字节 3 处查不到映射而整体失败。补回被吃掉的 U+FEFF。
static NSString *zenitCTStringFromUTF8(const char *bytes, NSUInteger len) {
    NSString *s = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    if (!s) return nil;
    if (len >= 3 && (unsigned char)bytes[0] == 0xEF && (unsigned char)bytes[1] == 0xBB &&
        (unsigned char)bytes[2] == 0xBF && (s.length == 0 || [s characterAtIndex:0] != 0xFEFF)) {
        s = [@"\uFEFF" stringByAppendingString:s];
    }
    return s;
}

/// Extract CTLine caret offsets for UTF-8 grapheme boundaries supplied by the
/// framework. CoreText remains the authority for bidi visual placement and
/// ligature geometry; Unicode grapheme segmentation remains framework-owned.
int coretext_line_caret_stops(
    void* font_ptr,
    const char* text,
    unsigned int text_len,
    const unsigned int* boundaries,
    unsigned int boundary_count,
    CoreTextCaretStop* out_stops,
    CoreTextLineMetrics* out_metrics
) {
    @autoreleasepool {
        if (!font_ptr || !text || !boundaries || !out_stops || !out_metrics || boundary_count == 0) {
            return -1;
        }

        NSString *nsText = zenitCTStringFromUTF8(text, text_len);
        if (!nsText) return -1;
        NSAttributedString *attr = createAttributedStringWithPreferredSymbolFallback(nsText, (CTFontRef)font_ptr);
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        if (!line) return -1;

        CGFloat ascent = 0;
        CGFloat descent = 0;
        CGFloat leading = 0;
        const double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        out_metrics->width = (float)width;
        out_metrics->ascent = (float)ascent;
        out_metrics->descent = (float)descent;
        out_metrics->leading = (float)leading;
        out_metrics->base_rtl = 0;
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        if (CFArrayGetCount(runs) > 0) {
            CTRunRef first_run = (CTRunRef)CFArrayGetValueAtIndex(runs, 0);
            out_metrics->base_rtl = (CTRunGetStatus(first_run) & kCTRunStatusRightToLeft) ? 1u : 0u;
        }

        // Only scalar/grapheme boundaries are queried, so recording the UTF-8 byte
        // position at each UTF-16 scalar start plus the final sentinel is enough.
        unsigned int *utf8_to_utf16 = (unsigned int *)malloc((text_len + 1) * sizeof(unsigned int));
        if (!utf8_to_utf16) {
            CFRelease(line);
            return -1;
        }
        for (unsigned int i = 0; i <= text_len; i++) utf8_to_utf16[i] = UINT_MAX;
        const NSUInteger utf16_len = nsText.length;
        unsigned int utf8_pos = 0;
        for (NSUInteger i = 0; i < utf16_len && utf8_pos <= text_len; i++) {
            utf8_to_utf16[utf8_pos] = (unsigned int)i;
            unichar ch = [nsText characterAtIndex:i];
            if (ch < 0x80) utf8_pos += 1;
            else if (ch < 0x800) utf8_pos += 2;
            else if (CFStringIsSurrogateHighCharacter(ch) && i + 1 < utf16_len &&
                     CFStringIsSurrogateLowCharacter([nsText characterAtIndex:i + 1])) {
                utf8_pos += 4;
                i += 1;
            } else utf8_pos += 3;
        }
        utf8_to_utf16[text_len] = (unsigned int)utf16_len;

        for (unsigned int i = 0; i < boundary_count; i++) {
            const unsigned int byte = boundaries[i];
            if (byte > text_len || utf8_to_utf16[byte] == UINT_MAX) {
                free(utf8_to_utf16);
                CFRelease(line);
                return -1;
            }
            CGFloat secondary = 0;
            const CGFloat primary = CTLineGetOffsetForStringIndex(line, utf8_to_utf16[byte], &secondary);
            out_stops[i].byte_offset = byte;
            out_stops[i].primary_x = (float)primary;
            out_stops[i].secondary_x = (float)secondary;
            out_stops[i].has_secondary = fabs(primary - secondary) > 0.01 ? 1u : 0u;
        }

        free(utf8_to_utf16);
        CFRelease(line);
        return 0;
    }
}

/// Shape text using CoreText
/// Returns number of glyphs, or -1 on error
/// out_glyphs is allocated by this function, caller must free with coretext_free_shaped_glyphs
int coretext_shape_text(
    void* font_ptr,
    const char* text,
    unsigned int text_len,
    CoreTextShapedGlyph** out_glyphs,
    unsigned int* out_count,
    int synthetic_italic
) {
    @autoreleasepool {
        CTFontRef font = (CTFontRef)font_ptr;

        // Create attributed string
        NSString *nsText = zenitCTStringFromUTF8(text, text_len);
        if (!nsText) {
            *out_glyphs = NULL;
            *out_count = 0;
            return -1;
        }

        NSAttributedString *attrStr = createAttributedStringWithPreferredSymbolFallback(nsText, font);

        // Create line and get glyph runs
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        CFIndex runCount = CFArrayGetCount(runs);

        // Count total glyphs across all runs
        unsigned int totalGlyphs = 0;
        CGFontRef baseCgFont = CTFontCopyGraphicsFont(font, NULL);
        for (CFIndex r = 0; r < runCount; r++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
            totalGlyphs += (unsigned int)CTRunGetGlyphCount(run);
        }

        if (totalGlyphs == 0) {
            CFRelease(line);
            if (baseCgFont) CFRelease(baseCgFont);
            *out_glyphs = NULL;
            *out_count = 0;
            return 0;
        }

        // Allocate output
        CoreTextShapedGlyph* glyphs = (CoreTextShapedGlyph*)malloc(totalGlyphs * sizeof(CoreTextShapedGlyph));
        if (!glyphs) {
            CFRelease(line);
            if (baseCgFont) CFRelease(baseCgFont);
            return -1;
        }

        // Build UTF-16 to UTF-8 byte offset mapping for cluster info
        // NSString uses UTF-16 internally, but we want UTF-8 byte clusters
        const char* utf8Bytes = text;
        unsigned int utf8Len = text_len;

        // Create a mapping from UTF-16 index to UTF-8 byte offset
        NSUInteger utf16Len = nsText.length;
        unsigned int* utf16ToUtf8 = (unsigned int*)calloc(utf16Len + 1, sizeof(unsigned int));
        if (utf16ToUtf8) {
            unsigned int utf8Pos = 0;
            for (NSUInteger i = 0; i < utf16Len && utf8Pos <= utf8Len; i++) {
                utf16ToUtf8[i] = utf8Pos;
                unichar ch = [nsText characterAtIndex:i];
                if (ch < 0x80) utf8Pos += 1;
                else if (ch < 0x800) utf8Pos += 2;
                else if (ch >= 0xD800 && ch <= 0xDBFF) {
                    utf8Pos += 4;
                    i++; // skip low surrogate
                    if (i < utf16Len) utf16ToUtf8[i] = utf8Pos;
                }
                else utf8Pos += 3;
            }
            // Sentinel
            if (utf16Len < utf16Len + 1) {
                utf16ToUtf8[utf16Len] = utf8Pos;
            }
        }

        // Extract glyph info from all runs
        unsigned int glyphIdx = 0;
        float pen_x = 0.0f;
        for (CFIndex r = 0; r < runCount; r++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
            CFIndex count = CTRunGetGlyphCount(run);

            // Check if this run uses a fallback font (e.g. CJK characters)
            // and if it needs synthetic italic
            CFDictionaryRef runAttrs = CTRunGetAttributes(run);
            CTFontRef runFont = (CTFontRef)CFDictionaryGetValue(runAttrs, kCTFontAttributeName);
            int isFallbackFont = 0;
            if (runFont) {
                // Don't use raw pointer inequality here:
                // CT may materialize equivalent CTFont instances per run,
                // especially after deriving fonts at fractional sizes.
                if (!CFEqual(runFont, font)) {
                    // Additional guard: equivalent CTFont instances can still be
                    // backed by the same CGFont. Treat them as non-fallback.
                    CGFontRef runCgFont = CTFontCopyGraphicsFont(runFont, NULL);
                    int sameBackingFont = (runCgFont && baseCgFont && CFEqual(runCgFont, baseCgFont)) ? 1 : 0;
                    if (runCgFont) CFRelease(runCgFont);
                    isFallbackFont = sameBackingFont ? 0 : 1;
                }
            }
            int needsSyntheticItalic = 0;
            if (synthetic_italic && isFallbackFont && runFont) {
                // 只对 fallback 字体（如 CJK 回退到 PingFang SC）检测是否需要合成斜体。
                // 主字体（如 Inter-Italic VF）已经是 italic 字形，不需要再 skew。
                CTFontSymbolicTraits runTraits = CTFontGetSymbolicTraits(runFont);
                if (!(runTraits & kCTFontItalicTrait)) {
                    needsSyntheticItalic = 1;
                }
            }

            // Get glyph IDs
            CGGlyph* runGlyphs = (CGGlyph*)malloc(count * sizeof(CGGlyph));
            CTRunGetGlyphs(run, CFRangeMake(0, count), runGlyphs);

            // Get positions
            CGPoint* positions = (CGPoint*)malloc(count * sizeof(CGPoint));
            CTRunGetPositions(run, CFRangeMake(0, count), positions);

            // Get advances
            CGSize* advances = (CGSize*)malloc(count * sizeof(CGSize));
            CTRunGetAdvances(run, CFRangeMake(0, count), advances);

            // Get string indices (for cluster mapping)
            CFIndex* indices = (CFIndex*)malloc(count * sizeof(CFIndex));
            CTRunGetStringIndices(run, CFRangeMake(0, count), indices);

            for (CFIndex i = 0; i < count && glyphIdx < totalGlyphs; i++) {
                glyphs[glyphIdx].glyph_index = (unsigned int)runGlyphs[i];

                // Map UTF-16 string index to UTF-8 byte offset
                CFIndex utf16Idx = indices[i];
                if (utf16ToUtf8 && utf16Idx >= 0 && (NSUInteger)utf16Idx < utf16Len) {
                    glyphs[glyphIdx].cluster = utf16ToUtf8[utf16Idx];
                } else {
                    glyphs[glyphIdx].cluster = (unsigned int)utf16Idx;
                }

                glyphs[glyphIdx].x_advance = (float)advances[i].width;
                glyphs[glyphIdx].y_advance = (float)advances[i].height;
                // Convert absolute CoreText positions to relative offsets from current pen
                glyphs[glyphIdx].x_offset = (float)positions[i].x - pen_x;
                glyphs[glyphIdx].y_offset = (float)positions[i].y;
                glyphs[glyphIdx].is_synthetic_italic = needsSyntheticItalic ? 1 : 0;
                glyphs[glyphIdx].is_fallback_font = isFallbackFont ? 1 : 0;
                // Retain the fallback font ref so it survives CTLine release.
                // Caller is responsible for releasing via the returned ref.
                if (isFallbackFont && runFont) {
                    CFRetain(runFont);
                    glyphs[glyphIdx].fallback_font_ref = (void*)runFont;
                } else {
                    glyphs[glyphIdx].fallback_font_ref = NULL;
                }
                glyphIdx++;
                pen_x += (float)advances[i].width;
            }

            free(runGlyphs);
            free(positions);
            free(advances);
            free(indices);
        }
        if (baseCgFont) CFRelease(baseCgFont);

        if (utf16ToUtf8) free(utf16ToUtf8);
        CFRelease(line);

        *out_glyphs = glyphs;
        *out_count = glyphIdx;
        return 0;
    }
}

/// Free shaped glyphs allocated by coretext_shape_text.
/// fallback_font_ref ownership is transferred to the caller — this function does NOT release them.
void coretext_free_shaped_glyphs(CoreTextShapedGlyph* glyphs) {
    if (glyphs) {
        free(glyphs);
    }
}

// ============================================================================
// Font Enumeration (字体选择器)
//
// 设计约束（全部有本机实测依据，见下游应用的调研记录）：
//   · 枚举 272 family / 990 face 实测 17.6ms，全量 trait 扫描 40.1ms
//     —— 宿主在后台线程扫一次即可，这里不做任何缓存。
//   · 17% 的 family 渲染不了自己的名字（阿拉伯/希伯来/天城文/CJK…），
//     所以 can_render_name + lang 必须一起给出，让 UI 能换样例串。
//   · 符号字体（Wingdings 等）**有** Latin 字形但画出来是图形，
//     字形覆盖检查识别不了它 —— 唯一可靠判据是 symbolic class == 12。
// ============================================================================

/// 家族数量。宿主据此分配数组。
int coretext_family_count(void) {
    @autoreleasepool {
        NSArray *fams = (__bridge_transfer NSArray *)CTFontManagerCopyAvailableFontFamilyNames();
        return (int)fams.count;
    }
}

/// 把家族名逐条 strdup 进 out_names[0..max)，返回实际写入数。
/// 每条都要用 coretext_free_c_string 释放。
int coretext_copy_family_names(char **out_names, int max) {
    if (!out_names || max <= 0) return 0;
    @autoreleasepool {
        NSArray *fams = (__bridge_transfer NSArray *)CTFontManagerCopyAvailableFontFamilyNames();
        int n = 0;
        for (NSString *fam in fams) {
            if (n >= max) break;
            const char *utf8 = fam.UTF8String;
            if (!utf8) continue;
            size_t len = strlen(utf8);
            char *copy = (char *)malloc(len + 1);
            if (!copy) continue;
            memcpy(copy, utf8, len + 1);
            out_names[n++] = copy;
        }
        return n;
    }
}

typedef struct {
    int  is_symbolic;      // symbolic class == 12：名字不可用自身渲染（Wingdings 等）
    int  can_render_name;  // 字体是否含有自己名字所需的全部字形
    int  is_variable;      // 有 variation axes
    int  face_count;       // 该家族的 face 数
    int  classification;   // 见下方 enum
    int  has_latin;        // 有没有基本拉丁字形('A''a''g''1')
    char lang[16];         // CTFontCopySupportedLanguages()[0]，用于挑样例串
} CoreTextFamilyInfo;

// classification 取值（与 CTFontStylisticClass 对齐后收敛成 UI 需要的粒度）
enum {
    CT_CLASS_UNKNOWN    = 0,
    CT_CLASS_SERIF      = 1,
    CT_CLASS_SANS       = 2,
    CT_CLASS_SCRIPT     = 3,
    CT_CLASS_DISPLAY    = 4,
    CT_CLASS_MONOSPACE  = 5,
    CT_CLASS_SYMBOLIC   = 6,
};

static int classifyFromTraits(CTFontSymbolicTraits traits) {
    if (traits & kCTFontTraitMonoSpace) return CT_CLASS_MONOSPACE;
    // ⚠ kCTFontClass* 常量本身就是**已经就位**的掩码值（如 Symbolic = 0xC0000000），
    //   不是 shift 之后的序数 12。拿右移过的值去比这些常量永远不相等 ——
    //   第一版就是这么写的，结果 272 个家族里符号字体识别出 0 个、
    //   Helvetica Neue 的分类也退化成 unknown。这里直接比掩码后的值。
    CTFontSymbolicTraits cls = traits & kCTFontClassMaskTrait;
    switch (cls) {
        case kCTFontClassOldStyleSerifs:
        case kCTFontClassTransitionalSerifs:
        case kCTFontClassModernSerifs:
        case kCTFontClassClarendonSerifs:
        case kCTFontClassSlabSerifs:
        case kCTFontClassFreeformSerifs:
            return CT_CLASS_SERIF;
        case kCTFontClassSansSerif:
            return CT_CLASS_SANS;
        case kCTFontClassScripts:
            return CT_CLASS_SCRIPT;
        case kCTFontClassOrnamentals:
            return CT_CLASS_DISPLAY;
        case kCTFontClassSymbolic:
            return CT_CLASS_SYMBOLIC;
        default:
            return CT_CLASS_UNKNOWN;
    }
}

/// 该家族能否用自身字形拼出自己的名字。
/// ⚠ 这个检查**识别不了符号字体** —— Wingdings 对 'A'/'a' 返回 true，
///   但画出来是图形。符号判据另走 is_symbolic。
static int familyCanRenderOwnName(CTFontRef font, NSString *name) {
    NSUInteger len = name.length;
    if (len == 0) return 1;
    if (len > 256) len = 256;
    unichar chars[256];
    [name getCharacters:chars range:NSMakeRange(0, len)];
    CGGlyph glyphs[256];
    return CTFontGetGlyphsForCharacters(font, chars, glyphs, len) ? 1 : 0;
}

/// 该家族的 face 数。SF Pro 这类系统字体走 descriptor 查会返回 0。
static int familyFaceCount(NSString *family) {
    NSDictionary *attrs = @{ (id)kCTFontFamilyNameAttribute : family };
    CTFontDescriptorRef desc =
        CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
    if (!desc) return 0;
    NSSet *keys = [NSSet setWithObject:(id)kCTFontFamilyNameAttribute];
    NSArray *matches = (__bridge_transfer NSArray *)
        CTFontDescriptorCreateMatchingFontDescriptors(desc, (__bridge CFSetRef)keys);
    CFRelease(desc);
    return (int)matches.count;
}

/// 一次拿齐 picker 需要的全部元数据，避免逐字段跨语言往返。
/// 返回 0 成功，-1 失败（家族名建不出字体）。
int coretext_family_info(const char *family, CoreTextFamilyInfo *out) {
    if (!family || !out) return -1;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return -1;
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)fam, 24.0, NULL);
        if (!font) return -1;

        memset(out, 0, sizeof(*out));

        CTFontSymbolicTraits traits = CTFontGetSymbolicTraits(font);
        // 同上：比掩码后的原值，不要右移。
        out->is_symbolic =
            ((traits & kCTFontClassMaskTrait) == kCTFontClassSymbolic) ? 1 : 0;
        out->classification  = classifyFromTraits(traits);
        out->can_render_name = familyCanRenderOwnName(font, fam);
        {
            // 「选了它打英文能出字吗」—— 拉丁字母 + 数字都要有。
            // 没有的话用户输入 ASCII 会得到空白/豆腐块，UI 给 disabled 视觉。
            unichar probe[4] = { 'A', 'a', 'g', '1' };
            CGGlyph pg[4];
            out->has_latin = CTFontGetGlyphsForCharacters(font, probe, pg, 4) ? 1 : 0;
        }
        out->face_count      = familyFaceCount(fam);

        NSArray *axes = (__bridge_transfer NSArray *)CTFontCopyVariationAxes(font);
        out->is_variable = (axes.count > 0) ? 1 : 0;

        NSArray *langs = (__bridge_transfer NSArray *)CTFontCopySupportedLanguages(font);
        if (langs.count > 0) {
            const char *tag = [(NSString *)langs[0] UTF8String];
            if (tag) {
                strncpy(out->lang, tag, sizeof(out->lang) - 1);
                out->lang[sizeof(out->lang) - 1] = '\0';
            }
        }

        CFRelease(font);
        return 0;
    }
}

/// CoreText weight trait(-1.0~1.0) → CSS 数值字重(100~900)。
///
/// 这是 createFontWithWeight 那张表的**逆映射**。取最近档,不做线性插值:
/// CT 的刻度本身就是离散锚点(-0.8/-0.6/-0.4/0/0.23/0.3/0.4/0.56/0.62),
/// 插值只会产出 100~900 之外的怪值。
static int ctWeightToCss(CGFloat w) {
    static const struct { CGFloat ct; int css; } table[] = {
        { -0.80, 100 }, { -0.60, 200 }, { -0.40, 300 }, { 0.00, 400 },
        {  0.23, 500 }, {  0.30, 600 }, {  0.40, 700 }, {  0.56, 800 },
        {  0.62, 900 },
    };
    int best = 400;
    CGFloat best_d = 1e9;
    for (size_t i = 0; i < sizeof(table)/sizeof(table[0]); i++) {
        CGFloat d = fabs(w - table[i].ct);
        if (d < best_d) { best_d = d; best = table[i].css; }
    }
    return best;
}

/// 枚举该家族**实际存在**的字重档位。
///
/// ⚠ 为什么必须枚举而不能挂一张固定的 100~900 列表:CoreText 对拿不到的
/// 字重**静默降级、不报错**。实测 Zapfino 只有 1 个 face,问它要 Bold 会
/// 安静地返回 Regular;Menlo 要 Light 也回 Regular。UI 若给出字体没有的档位,
/// 用户选了看不到任何变化,也没有任何失败信号 —— 和"状态变了画面没变"
/// 属同一类静默失效。
///
/// 输出按 CSS 字重升序、去重(同一档的 Italic 与 Regular 合并成一档 ——
/// 斜体是独立的轴,不该挤进字重下拉)。
/// 可变字体(实测 272 个家族里 12 个)给的是**连续轴区间**而非离散 face,
/// 这里按轴的 min/max 铺满标准档位,让 VF 也能有可选项。
///
/// 返回实际写入数;out_weights 收 CSS 数值。
int coretext_family_weights(const char *family, int *out_weights, int max) {
    if (!family || !out_weights || max <= 0) return 0;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return 0;

        int seen[16]; int n = 0;

        // 可变字体:按 Weight 轴区间铺标准档位。
        CTFontRef probe = CTFontCreateWithName((__bridge CFStringRef)fam, 16, NULL);
        if (probe) {
            NSArray *axes = (__bridge_transfer NSArray *)CTFontCopyVariationAxes(probe);
            CFRelease(probe);
            for (NSDictionary *a in axes) {
                NSNumber *aid = a[(id)kCTFontVariationAxisIdentifierKey];
                if (!aid || aid.unsignedIntValue != 0x77676874) continue; // 'wght'
                int lo = [a[(id)kCTFontVariationAxisMinimumValueKey] intValue];
                int hi = [a[(id)kCTFontVariationAxisMaximumValueKey] intValue];
                for (int w = 100; w <= 900; w += 100) {
                    if (w < lo || w > hi) continue;
                    if (n < max && n < (int)(sizeof(seen)/sizeof(seen[0]))) out_weights[n] = w, seen[n] = w, n++;
                }
                if (n > 0) return n;
            }
        }

        NSDictionary *attrs = @{ (id)kCTFontFamilyNameAttribute : fam };
        CTFontDescriptorRef desc =
            CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
        if (!desc) return 0;
        NSSet *keys = [NSSet setWithObject:(id)kCTFontFamilyNameAttribute];
        NSArray *matches = (__bridge_transfer NSArray *)
            CTFontDescriptorCreateMatchingFontDescriptors(desc, (__bridge CFSetRef)keys);
        CFRelease(desc);

        for (id m in matches) {
            NSDictionary *tr = (__bridge_transfer NSDictionary *)
                CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)m,
                                              kCTFontTraitsAttribute);
            if (!tr) continue;
            NSNumber *wn = tr[(id)kCTFontWeightTrait];
            if (!wn) continue;
            int css = ctWeightToCss([wn doubleValue]);
            int dup = 0;
            for (int i = 0; i < n; i++) if (seen[i] == css) { dup = 1; break; }
            if (dup) continue;
            if (n >= max || n >= (int)(sizeof(seen)/sizeof(seen[0]))) break;
            seen[n] = css;
            out_weights[n] = css;
            n++;
        }

        // 升序（CoreText 返回顺序是 Regular 优先，不是字重序）
        for (int i = 1; i < n; i++) {
            int v = out_weights[i], j = i - 1;
            while (j >= 0 && out_weights[j] > v) { out_weights[j+1] = out_weights[j]; j--; }
            out_weights[j+1] = v;
        }
        return n;
    }
}

/// 枚举该家族的风格名（Regular / Bold Italic / Semibold …）。
/// 返回实际写入数；每条都要 coretext_free_c_string。
int coretext_family_styles(const char *family, char **out_styles, int max) {
    if (!family || !out_styles || max <= 0) return 0;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return 0;
        NSDictionary *attrs = @{ (id)kCTFontFamilyNameAttribute : fam };
        CTFontDescriptorRef desc =
            CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
        if (!desc) return 0;
        NSSet *keys = [NSSet setWithObject:(id)kCTFontFamilyNameAttribute];
        NSArray *matches = (__bridge_transfer NSArray *)
            CTFontDescriptorCreateMatchingFontDescriptors(desc, (__bridge CFSetRef)keys);
        CFRelease(desc);

        int n = 0;
        for (id m in matches) {
            if (n >= max) break;
            NSString *style = (__bridge_transfer NSString *)
                CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)m,
                                              kCTFontStyleNameAttribute);
            if (!style) continue;
            const char *utf8 = style.UTF8String;
            if (!utf8) continue;
            size_t len = strlen(utf8);
            char *copy = (char *)malloc(len + 1);
            if (!copy) continue;
            memcpy(copy, utf8, len + 1);
            out_styles[n++] = copy;
        }
        return n;
    }
}

/// 从字体自身的 character set 里取前 `max_cp` 个可渲染码点，写进 out_utf8。
///
/// 这是样例串的**最终兜底**：`lang` 为空且非符号字体时（实测 macOS 上有
/// Noto Sans Batak / Noto Sans Tagalog 两个，它们既渲染不了自己的名字、
/// 又拿不到语言标签），只能问字体"你到底能画什么"。
/// 返回写入的码点数；0 = 连码点都取不到。
int coretext_family_sample_codepoints(const char *family, uint32_t *out_cps, int max_cp) {
    if (!family || !out_cps || max_cp <= 0) return 0;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return 0;
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)fam, 24.0, NULL);
        if (!font) return 0;
        CFCharacterSetRef cs = CTFontCopyCharacterSet(font);
        if (!cs) { CFRelease(font); return 0; }

        int n = 0;
        // 跳过 ASCII 与常见标点：这些字体真正的"性格"在它自己的脚本区段里。
        // 上界取 BMP 末尾就够——再往上是 emoji/补充平面，不适合当样例。
        for (uint32_t cp = 0x00A1; cp <= 0xFFFF && n < max_cp; cp++) {
            if (CFCharacterSetIsLongCharacterMember(cs, cp)) out_cps[n++] = cp;
        }
        CFRelease(cs);
        CFRelease(font);
        return n;
    }
}

/// 校验 family 是否**真的**存在。
///
/// ⚠ 为什么需要它：`coretext_find_font` 走 descriptor 匹配，
///   对不存在的家族名会**静默返回一个替身字体**（只有 italic 那一路做了校验）。
///   picker 把用户存盘的家族名解析回字体时，必须回读实际家族名比对，
///   否则「字体丢失」会伪装成「字体正常」。
/// 返回 1 = 名字完全匹配；0 = 不存在或被替换。
int coretext_family_exists(const char *family) {
    if (!family) return 0;
    @autoreleasepool {
        NSString *want = [NSString stringWithUTF8String:family];
        if (!want) return 0;
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)want, 12.0, NULL);
        if (!font) return 0;
        NSString *got = (__bridge_transfer NSString *)CTFontCopyFamilyName(font);
        CFRelease(font);
        return (got && [got isEqualToString:want]) ? 1 : 0;
    }
}
