#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwrite.h>
#include <dwrite_3.h>
#include <d2d1.h>
#include <wincodec.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include "dwrite_font_ranges.h"
#include "dwrite_alpha_correction.h"

// The bridge uses COM interfaces without linking a C++ runtime. A pure
// virtual dispatch is a programming error; provide its freestanding ABI hook.
extern "C" __attribute__((weak, noreturn)) void __cxa_pure_virtual() { abort(); }

struct ZenitDWriteRasterContext {
    DWORD thread;
    bool apartment_owned;
    IDWriteFactory *factory;
    ID2D1Factory *d2d;
    IWICImagingFactory *wic;
    IDWriteRenderingParams *params;
    IDWriteRenderingParams1 *raw;
    IWICBitmap *bitmap;
    ID2D1RenderTarget *target;
    ID2D1SolidColorBrush *brush;
    HMONITOR monitor;
    uint64_t epoch;
    bool cleartype;
    UINT width, height, target_allocations;
};
extern "C" int zenit_dwrite_cleartype_enabled();
extern "C" void zenit_dwrite_raster_context_destroy(ZenitDWriteRasterContext *ctx) {
    if (!ctx) return;
    // All context resources and the matching COM apartment belong to the UI thread.
    if (ctx->thread != GetCurrentThreadId()) abort();
    if (ctx->brush) ctx->brush->Release();
    if (ctx->target) ctx->target->Release();
    if (ctx->bitmap) ctx->bitmap->Release();
    if (ctx->raw) ctx->raw->Release();
    if (ctx->params) ctx->params->Release();
    if (ctx->wic) ctx->wic->Release();
    if (ctx->d2d) ctx->d2d->Release();
    if (ctx->factory) ctx->factory->Release();
    if (ctx->apartment_owned) CoUninitialize();
    free(ctx);
}
extern "C" ZenitDWriteRasterContext *zenit_dwrite_raster_context_create() {
    auto *ctx = static_cast<ZenitDWriteRasterContext *>(calloc(1, sizeof(ZenitDWriteRasterContext)));
    if (!ctx) return nullptr;
    ctx->thread = GetCurrentThreadId(); ctx->epoch = UINT64_MAX;
    // Do not introduce MTA before drop_bridge's OleInitialize (STA).
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ctx->apartment_owned = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) { free(ctx); return nullptr; }
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown **>(&ctx->factory));
    if (SUCCEEDED(hr)) hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &ctx->d2d);
    if (SUCCEEDED(hr)) hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&ctx->wic));
    if (FAILED(hr)) { zenit_dwrite_raster_context_destroy(ctx); return nullptr; }
    return ctx;
}
extern "C" int zenit_dwrite_raster_context_refresh(ZenitDWriteRasterContext *ctx, void *window, uint64_t epoch, float out[8]) {
    if (!ctx || ctx->thread != GetCurrentThreadId()) return -1;
    if (window) epoch = (uint64_t)(uintptr_t)GetPropW(static_cast<HWND>(window), L"Zenit.TextSettingsGeneration");
    HMONITOR monitor = window ? MonitorFromWindow(static_cast<HWND>(window), MONITOR_DEFAULTTONEAREST) : MonitorFromPoint(POINT{0,0}, MONITOR_DEFAULTTOPRIMARY);
    bool enabled = zenit_dwrite_cleartype_enabled() != 0;
    bool changed = !ctx->params || ctx->monitor != monitor || ctx->epoch != epoch || ctx->cleartype != enabled;
    if (changed) {
        IDWriteRenderingParams *params = nullptr; IDWriteRenderingParams1 *raw = nullptr; IDWriteFactory1 *factory = nullptr;
        HRESULT hr = ctx->factory->CreateMonitorRenderingParams(monitor, &params);
        if (SUCCEEDED(hr)) hr = ctx->factory->QueryInterface(__uuidof(IDWriteFactory1), (void **)&factory);
        if (SUCCEEDED(hr)) hr = factory->CreateCustomRenderingParams(1.f, 0.f, 0.f, params->GetClearTypeLevel(), params->GetPixelGeometry(), params->GetRenderingMode(), &raw);
        if (factory) factory->Release();
        if (FAILED(hr)) { if (params) params->Release(); if (raw) raw->Release(); return -1; }
        if (ctx->params) ctx->params->Release(); if (ctx->raw) ctx->raw->Release();
        ctx->params = params; ctx->raw = raw; ctx->monitor = monitor; ctx->epoch = epoch; ctx->cleartype = enabled;
    }
    IDWriteRenderingParams1 *params1 = nullptr;
    if (FAILED(ctx->params->QueryInterface(__uuidof(IDWriteRenderingParams1), (void **)&params1))) return -1;
    dwrite_gamma_ratios(ctx->params->GetGamma(), out);
    out[4] = params1->GetGrayscaleEnhancedContrast(); out[5] = ctx->params->GetEnhancedContrast(); out[6] = ctx->params->GetClearTypeLevel();
    out[7] = enabled && ctx->params->GetPixelGeometry() != DWRITE_PIXEL_GEOMETRY_FLAT && out[6] > 0;
    params1->Release(); return changed ? 1 : 0;
}
static HRESULT raster_context_target(ZenitDWriteRasterContext *ctx, UINT width, UINT height) {
    if (ctx->target && width <= ctx->width && height <= ctx->height) return S_OK;
    UINT w = 64, h = 64; while (w < width) w *= 2; while (h < height) h *= 2;
    w = w > ctx->width ? w : ctx->width; h = h > ctx->height ? h : ctx->height;
    IWICBitmap *bitmap = nullptr; ID2D1RenderTarget *target = nullptr; ID2D1SolidColorBrush *brush = nullptr;
    HRESULT hr = ctx->wic->CreateBitmap(w, h, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &bitmap);
    if (SUCCEEDED(hr)) hr = ctx->d2d->CreateWicBitmapRenderTarget(bitmap, D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED)), &target);
    if (SUCCEEDED(hr)) hr = target->CreateSolidColorBrush(D2D1::ColorF(1.f,1.f,1.f), &brush);
    if (FAILED(hr)) { if (brush) brush->Release(); if (target) target->Release(); if (bitmap) bitmap->Release(); return hr; }
    if (ctx->brush) ctx->brush->Release(); if (ctx->target) ctx->target->Release(); if (ctx->bitmap) ctx->bitmap->Release();
    ctx->bitmap = bitmap; ctx->target = target; ctx->brush = brush; ctx->width = w; ctx->height = h; ctx->target_allocations++;
    return S_OK;
}
extern "C" UINT zenit_dwrite_raster_context_target_allocations(const ZenitDWriteRasterContext *ctx) { return ctx ? ctx->target_allocations : 0; }

struct ZenitDWriteFont {
    LONG refs;
    IDWriteFactory *factory;
    IDWriteFontFace *face;
    IDWriteTextFormat *format;
    ZenitDWriteRasterContext *coverage;
    float size;
    DWRITE_FONT_METRICS metrics;
};
extern "C" void zenit_dwrite_retain_font(ZenitDWriteFont *font);

extern "C" uint32_t zenit_dwrite_font_debug_name(const ZenitDWriteFont *font, char *out, uint32_t capacity) {
    if (!font || !font->face || !out || !capacity) return 0;
    IDWriteFontFace3 *face=nullptr;
    IDWriteLocalizedStrings *names=nullptr;
    UINT32 index=0,length=0; BOOL exists=FALSE;
    wchar_t wide[256]; char family[1024];
    uint32_t result=0;
    if (FAILED(font->face->QueryInterface(__uuidof(IDWriteFontFace3),(void **)&face)) ||
        FAILED(face->GetFamilyNames(&names))) goto done;
    if (FAILED(names->FindLocaleName(L"en-us",&index,&exists))) goto done;
    if (!exists) index=0;
    if (FAILED(names->GetStringLength(index,&length)) || length>=256 ||
        FAILED(names->GetString(index,wide,256)) ||
        !WideCharToMultiByte(CP_UTF8,0,wide,-1,family,sizeof(family),nullptr,nullptr)) goto done;
    {
        int count=snprintf(out,capacity,"DirectWrite %s weight=%u simulations=%u %.1fpx",
            family,(unsigned)face->GetWeight(),(unsigned)font->face->GetSimulations(),font->size);
        if (count>0 && (uint32_t)count<capacity) result=(uint32_t)count;
    }
done:
    if (names) names->Release();
    if (face) face->Release();
    return result;
}

// UTF-8 metadata for a retained fallback wrapper; return includes terminator.
extern "C" uint32_t zenit_dwrite_font_metadata_string(const ZenitDWriteFont *font, int locale, char *out, uint32_t capacity) {
    if (!font || !font->format || !out || !capacity || capacity>INT_MAX) return 0;
    UINT32 length=locale ? font->format->GetLocaleNameLength() : font->format->GetFontFamilyNameLength();
    if (length>65535) return 0;
    wchar_t *wide=(wchar_t *)calloc((size_t)length+1,sizeof(wchar_t));
    if (!wide) return 0;
    HRESULT hr=locale ? font->format->GetLocaleName(wide,length+1) : font->format->GetFontFamilyName(wide,length+1);
    int count=SUCCEEDED(hr) ? WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,wide,-1,out,(int)capacity,nullptr,nullptr) : 0;
    free(wide);
    return count>0 ? (uint32_t)count : 0;
}

static wchar_t *utf8_to_utf16(const char *text, int length, int *out_length) {
    if (length < 0) length = (int)strlen(text);
    int needed = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text, length, nullptr, 0);
    if (needed <= 0) return nullptr;
    wchar_t *wide = (wchar_t *)calloc((size_t)needed + 1, sizeof(wchar_t));
    if (!wide) return nullptr;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            text, length, wide, needed) != needed) {
        free(wide);
        return nullptr;
    }
    if (out_length) *out_length = needed;
    return wide;
}

extern "C" ZenitDWriteFont *zenit_dwrite_find_font(
    const char *family_utf8, const char *locale_utf8, float size, int weight, int italic) {
    if (!family_utf8 || !locale_utf8 || !(size > 0)) return nullptr;
    const char *requested = strcmp(family_utf8, "system") == 0 ? "Segoe UI" : family_utf8;
    wchar_t *family_name = utf8_to_utf16(requested, -1, nullptr);
    if (!family_name) return nullptr;
    wchar_t *locale_name = utf8_to_utf16(locale_utf8, -1, nullptr);
    if (!locale_name || !locale_name[0]) { free(locale_name); free(family_name); return nullptr; }

    ZenitDWriteFont *font = (ZenitDWriteFont *)calloc(1, sizeof(*font));
    if (!font) { free(locale_name); free(family_name); return nullptr; }
    font->refs = 1;
    font->size = size;
    IDWriteFontCollection *collection = nullptr;
    IDWriteFontFamily *family = nullptr;
    IDWriteFont *match = nullptr;
    UINT32 index = 0;
    BOOL exists = FALSE;
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
        __uuidof(IDWriteFactory), reinterpret_cast<IUnknown **>(&font->factory));
    if (FAILED(hr)) goto failed;
    hr = font->factory->GetSystemFontCollection(&collection);
    if (FAILED(hr)) goto failed;
    hr = collection->FindFamilyName(family_name, &index, &exists);
    if (FAILED(hr) || !exists) goto failed;
    hr = collection->GetFontFamily(index, &family);
    if (FAILED(hr)) goto failed;
    hr = family->GetFirstMatchingFont((DWRITE_FONT_WEIGHT)weight,
        DWRITE_FONT_STRETCH_NORMAL,
        italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
        &match);
    if (FAILED(hr)) goto failed;
    hr = match->CreateFontFace(&font->face);
    if (FAILED(hr)) goto failed;
    hr = font->factory->CreateTextFormat(family_name, nullptr,
        (DWRITE_FONT_WEIGHT)weight,
        italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL, size, locale_name, &font->format);
    if (FAILED(hr)) goto failed;
    font->face->GetMetrics(&font->metrics);
    match->Release();
    family->Release();
    collection->Release();
    free(family_name);
    free(locale_name);
    return font;

failed:
    if (match) match->Release();
    if (family) family->Release();
    if (collection) collection->Release();
    if (font->coverage) zenit_dwrite_raster_context_destroy(font->coverage);
    if (font->format) font->format->Release();
    if (font->face) font->face->Release();
    if (font->factory) font->factory->Release();
    free(font);
    free(family_name);
    free(locale_name);
    return nullptr;
}

// Keep application fonts private: never install them into the OS font collection.
extern "C" ZenitDWriteFont *zenit_dwrite_load_font(
    const char *path_utf8, const char *locale_utf8, float size) {
    if (!path_utf8 || !locale_utf8 || !(size > 0)) return nullptr;
    wchar_t *path = utf8_to_utf16(path_utf8, -1, nullptr);
    wchar_t *locale = utf8_to_utf16(locale_utf8, -1, nullptr);
    wchar_t *absolute = nullptr, *family_name = nullptr;
    ZenitDWriteFont *font = nullptr;
    IDWriteFactory3 *factory = nullptr;
    IDWriteFontFile *file = nullptr;
    IDWriteFontFaceReference *reference = nullptr;
    IDWriteFontFace3 *face = nullptr;
    IDWriteFontSetBuilder *builder = nullptr;
    IDWriteFontSet *set = nullptr;
    IDWriteFontCollection1 *collection = nullptr;
    IDWriteFontFamily *family = nullptr;
    IDWriteLocalizedStrings *names = nullptr;
    BOOL supported = FALSE;
    DWRITE_FONT_FILE_TYPE file_type;
    DWRITE_FONT_FACE_TYPE face_type;
    UINT32 count = 0, length = 0;
    DWORD needed = path ? GetFullPathNameW(path, 0, nullptr, nullptr) : 0;
    DWORD written = 0;
    if (!needed || !locale || !locale[0]) goto done;
    absolute = (wchar_t *)calloc(needed, sizeof(wchar_t));
    if (!absolute) goto done;
    written = GetFullPathNameW(path, needed, absolute, nullptr);
    if (!written || written >= needed) goto done;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory3),
        reinterpret_cast<IUnknown **>(&factory)))) goto done;
    if (FAILED(factory->CreateFontFileReference(absolute, nullptr, &file)) ||
        FAILED(file->Analyze(&supported, &file_type, &face_type, &count)) || !supported || !count ||
        FAILED(factory->CreateFontFaceReference_(file, 0, DWRITE_FONT_SIMULATIONS_NONE, &reference)) ||
        FAILED(reference->CreateFontFace(&face)) ||
        FAILED(factory->CreateFontSetBuilder(&builder)) ||
        FAILED(builder->AddFontFaceReference(reference)) ||
        FAILED(builder->CreateFontSet(&set)) ||
        FAILED(factory->CreateFontCollectionFromFontSet(set, &collection)) ||
        FAILED(static_cast<IDWriteFontCollection *>(collection)->GetFontFamily(0, &family)) ||
        FAILED(family->GetFamilyNames(&names)) ||
        FAILED(names->GetStringLength(0, &length))) goto done;
    family_name = (wchar_t *)calloc((size_t)length + 1, sizeof(wchar_t));
    if (!family_name || FAILED(names->GetString(0, family_name, length + 1))) goto done;
    font = (ZenitDWriteFont *)calloc(1, sizeof(*font));
    if (!font) goto done;
    if (FAILED(factory->CreateTextFormat(family_name, collection, face->GetWeight(),
        face->GetStyle(), face->GetStretch(), size, locale, &font->format))) {
        free(font); font = nullptr; goto done;
    }
    font->refs = 1;
    font->size = size;
    font->factory = factory; factory->AddRef();
    font->face = face; face->AddRef();
    static_cast<IDWriteFontFace *>(face)->GetMetrics(&font->metrics);
done:
    if (names) names->Release();
    if (family) family->Release();
    if (collection) collection->Release();
    if (set) set->Release();
    if (builder) builder->Release();
    if (face) face->Release();
    if (reference) reference->Release();
    if (file) file->Release();
    if (factory) factory->Release();
    free(family_name); free(absolute); free(path); free(locale);
    return font;
}

// Shaped fallback refs contain only a face. Build a complete owned Font from
// that exact face, including private collections, only on renderer cache miss.
extern "C" ZenitDWriteFont *zenit_dwrite_wrap_fallback_font(const ZenitDWriteFont *source, const char *locale_utf8) {
    if (!source || !source->face || !source->factory || !locale_utf8) return nullptr;
    wchar_t *locale=utf8_to_utf16(locale_utf8,-1,nullptr), *family_name=nullptr;
    IDWriteFactory3 *factory=nullptr;
    IDWriteFontFace3 *face=nullptr;
    IDWriteFontFaceReference *reference=nullptr;
    IDWriteFontSetBuilder *builder=nullptr;
    IDWriteFontSet *set=nullptr;
    IDWriteFontCollection1 *collection=nullptr;
    IDWriteFontFamily *family=nullptr;
    IDWriteLocalizedStrings *names=nullptr;
    UINT32 length=0;
    ZenitDWriteFont *font=nullptr;
    if (!locale || FAILED(source->factory->QueryInterface(__uuidof(IDWriteFactory3),(void **)&factory)) ||
        FAILED(source->face->QueryInterface(__uuidof(IDWriteFontFace3),(void **)&face)) ||
        FAILED(face->GetFontFaceReference(&reference)) ||
        FAILED(factory->CreateFontSetBuilder(&builder)) ||
        FAILED(builder->AddFontFaceReference(reference)) ||
        FAILED(builder->CreateFontSet(&set)) ||
        FAILED(factory->CreateFontCollectionFromFontSet(set,&collection)) ||
        FAILED(static_cast<IDWriteFontCollection *>(collection)->GetFontFamily(0,&family)) ||
        FAILED(family->GetFamilyNames(&names)) || FAILED(names->GetStringLength(0,&length))) goto done;
    family_name=(wchar_t *)calloc((size_t)length+1,sizeof(wchar_t));
    if (!family_name || FAILED(names->GetString(0,family_name,length+1))) goto done;
    font=(ZenitDWriteFont *)calloc(1,sizeof(*font));
    if (!font) goto done;
    if (FAILED(factory->CreateTextFormat(family_name,collection,face->GetWeight(),face->GetStyle(),face->GetStretch(),source->size,locale,&font->format))) {
        free(font); font=nullptr; goto done;
    }
    font->refs=1; font->size=source->size; font->metrics=source->metrics;
    font->face=source->face; font->face->AddRef();
    font->factory=source->factory; font->factory->AddRef();
done:
    if (names) names->Release();
    if (family) family->Release();
    if (collection) collection->Release();
    if (set) set->Release();
    if (builder) builder->Release();
    if (reference) reference->Release();
    if (face) face->Release();
    if (factory) factory->Release();
    free(family_name); free(locale);
    return font;
}

extern "C" ZenitDWriteFont *zenit_dwrite_derive_font(const ZenitDWriteFont *source, float size) {
    if (!source || !source->format || !(size > 0)) return nullptr;
    UINT32 family_length = source->format->GetFontFamilyNameLength();
    UINT32 locale_length = source->format->GetLocaleNameLength();
    wchar_t *family = (wchar_t *)calloc((size_t)family_length + 1, sizeof(wchar_t));
    wchar_t *locale = (wchar_t *)calloc((size_t)locale_length + 1, sizeof(wchar_t));
    IDWriteFontCollection *collection = nullptr;
    ZenitDWriteFont *font = nullptr;
    if (!family || !locale ||
        FAILED(source->format->GetFontFamilyName(family, family_length + 1)) ||
        FAILED(source->format->GetLocaleName(locale, locale_length + 1)) ||
        FAILED(source->format->GetFontCollection(&collection))) goto done;
    font = (ZenitDWriteFont *)calloc(1, sizeof(*font));
    if (!font) goto done;
    if (FAILED(source->factory->CreateTextFormat(family, collection,
        source->format->GetFontWeight(), source->format->GetFontStyle(),
        source->format->GetFontStretch(), size, locale, &font->format))) {
        free(font); font = nullptr; goto done;
    }
    font->refs = 1;
    font->factory = source->factory; font->factory->AddRef();
    font->face = source->face; font->face->AddRef();
    font->metrics = source->metrics;
    font->size = size;
done:
    if (collection) collection->Release();
    free(family); free(locale);
    return font;
}

extern "C" IDWriteTextFormat *zenit_dwrite_create_text_format(const ZenitDWriteFont *font, float size) {
    if (!font || !font->format) return nullptr;
    if (font->size == size) { font->format->AddRef(); return font->format; }
    ZenitDWriteFont *derived = zenit_dwrite_derive_font(font, size);
    if (!derived) return nullptr;
    IDWriteTextFormat *format = derived->format;
    derived->format = nullptr;
    derived->face->Release(); derived->factory->Release(); free(derived);
    return format;
}

// The system UI font: the message font Windows itself uses for dialogs and controls
// (Segoe UI, or Microsoft YaHei UI / Yu Gothic UI / Malgun Gothic on CJK systems).
// UTF-8 into out; returns its length without the terminator, 0 on failure.
extern "C" uint32_t zenit_windows_system_ui_family(char *out, uint32_t capacity) {
    if (!out || !capacity) return 0;
    NONCLIENTMETRICSW metrics = {};
    metrics.cbSize = sizeof(metrics);
    if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0) || !metrics.lfMessageFont.lfFaceName[0]) return 0;
    int length = WideCharToMultiByte(CP_UTF8, 0, metrics.lfMessageFont.lfFaceName, -1, out, (int)capacity, nullptr, nullptr);
    return length > 1 ? (uint32_t)(length - 1) : 0;
}

// The user's UI language as a BCP-47 name (zh-CN, ja-JP, en-US): DirectWrite picks CJK
// fallback faces and glyph forms by it. Returns its length without the terminator, 0 on failure.
extern "C" uint32_t zenit_windows_user_locale(char *out, uint32_t capacity) {
    if (!out || !capacity) return 0;
    wchar_t name[LOCALE_NAME_MAX_LENGTH];
    if (!GetUserDefaultLocaleName(name, LOCALE_NAME_MAX_LENGTH)) return 0;
    int length = WideCharToMultiByte(CP_UTF8, 0, name, -1, out, (int)capacity, nullptr, nullptr);
    return length > 1 ? (uint32_t)(length - 1) : 0;
}

extern "C" uint32_t zenit_dwrite_font_family_name(const ZenitDWriteFont *font, char *out, uint32_t capacity) {
    if (!font || !font->format || !out || !capacity) return 0;
    UINT32 length = font->format->GetFontFamilyNameLength();
    wchar_t *wide = (wchar_t *)calloc((size_t)length + 1, sizeof(wchar_t));
    if (!wide) return 0;
    int count = 0;
    if (SUCCEEDED(font->format->GetFontFamilyName(wide, length + 1)))
        count = WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, capacity, nullptr, nullptr);
    free(wide);
    return count > 0 ? (uint32_t)count - 1 : 0;
}
extern "C" uint32_t zenit_dwrite_font_weight(const ZenitDWriteFont *font) {
    return font && font->format ? (uint32_t)font->format->GetFontWeight() : 0;
}
extern "C" int zenit_dwrite_font_italic(const ZenitDWriteFont *font) {
    return font && font->format && font->format->GetFontStyle() != DWRITE_FONT_STYLE_NORMAL;
}

extern "C" void zenit_dwrite_release_font(ZenitDWriteFont *font) {
    if (!font || InterlockedDecrement(&font->refs) != 0) return;
    if (font->coverage) zenit_dwrite_raster_context_destroy(font->coverage);
    if (font->format) font->format->Release();
    if (font->face) font->face->Release();
    if (font->factory) font->factory->Release();
    free(font);
}

struct ZenitDWriteFontRanges {
    LONG refs;
    uint32_t count, text_length;
    ZenitDWriteFontRange *items;
};
extern "C" void zenit_dwrite_release_font_ranges(ZenitDWriteFontRanges *ranges) {
    if (!ranges || InterlockedDecrement(&ranges->refs)) return;
    for (uint32_t i = 0; i < ranges->count; ++i)
        zenit_dwrite_release_font(static_cast<ZenitDWriteFont *>(ranges->items[i].font));
    free(ranges->items); free(ranges);
}
extern "C" void zenit_dwrite_retain_font_ranges(ZenitDWriteFontRanges *ranges) {
    if (ranges) InterlockedIncrement(&ranges->refs);
}
extern "C" ZenitDWriteFontRanges *zenit_dwrite_create_font_ranges(
    const ZenitDWriteFontRange *items, uint32_t count, uint32_t text_length) {
    if ((count && !items) || count > 65536 || text_length > 1048576) return nullptr;
    uint32_t end = 0;
    // Validate the entire borrowed array before taking any references.
    for (uint32_t i = 0; i < count; ++i) {
        auto *font = static_cast<ZenitDWriteFont *>(items[i].font);
        if (!font || !font->format || !items[i].length || !isfinite(items[i].size) || items[i].size <= 0 || items[i].italic_override < -1 || items[i].italic_override > 1 ||
            items[i].start < end || items[i].start > text_length || items[i].length > text_length - items[i].start) return nullptr;
        end = items[i].start + items[i].length;
    }
    auto *ranges = static_cast<ZenitDWriteFontRanges *>(calloc(1, sizeof(ZenitDWriteFontRanges)));
    if (!ranges) return nullptr;
    ranges->refs = 1; ranges->text_length = text_length;
    if (count) {
        ranges->items = static_cast<ZenitDWriteFontRange *>(malloc(count * sizeof(*items)));
        if (!ranges->items) { free(ranges); return nullptr; }
        memcpy(ranges->items, items, count * sizeof(*items));
        ranges->count = count;
        for (uint32_t i = 0; i < count; ++i)
            zenit_dwrite_retain_font(static_cast<ZenitDWriteFont *>(ranges->items[i].font));
    }
    return ranges;
}
// Source fonts are immutable and retained by both snapshots. Pointer equality
// therefore proves equal source formats without address-reuse ambiguity.
extern "C" int zenit_dwrite_font_ranges_equal(const ZenitDWriteFontRanges *a, const ZenitDWriteFontRanges *b) {
    if (a == b) return 1;
    if (!a || !b || a->count != b->count || a->text_length != b->text_length) return 0;
    for (uint32_t i = 0; i < a->count; ++i) {
        const auto &x = a->items[i], &y = b->items[i];
        if (x.font != y.font || x.start != y.start || x.length != y.length || x.size != y.size || x.italic_override != y.italic_override) return 0;
    }
    return 1;
}
static bool splits_surrogate(const wchar_t *text, uint32_t length, uint32_t at) {
    return at && at < length && text[at - 1] >= 0xd800 && text[at - 1] <= 0xdbff &&
        text[at] >= 0xdc00 && text[at] <= 0xdfff;
}
extern "C" int zenit_dwrite_apply_font_ranges(void *opaque_layout,
    const ZenitDWriteFontRanges *ranges, const uint16_t *utf16, uint32_t length) {
    if (!ranges) return 1;
    if (!opaque_layout || (length && !utf16) || length != ranges->text_length) return 0;
    auto *layout = static_cast<IDWriteTextLayout *>(opaque_layout);
    auto *text = reinterpret_cast<const wchar_t *>(utf16);
    // Unicode boundary errors must be discovered before modifying the layout.
    for (uint32_t i = 0; i < ranges->count; ++i)
        if (splits_surrogate(text, length, ranges->items[i].start) ||
            splits_surrogate(text, length, ranges->items[i].start + ranges->items[i].length)) return 0;
    for (uint32_t i = 0; i < ranges->count; ++i) {
        const auto &item = ranges->items[i];
        auto *font = static_cast<const ZenitDWriteFont *>(item.font);
        UINT32 family_length = font->format->GetFontFamilyNameLength();
        UINT32 locale_length = font->format->GetLocaleNameLength();
        auto *family = static_cast<wchar_t *>(calloc((size_t)family_length + 1, sizeof(wchar_t)));
        auto *locale = static_cast<wchar_t *>(calloc((size_t)locale_length + 1, sizeof(wchar_t)));
        IDWriteFontCollection *collection = nullptr;
        HRESULT hr = family && locale ? S_OK : E_OUTOFMEMORY;
        if (SUCCEEDED(hr)) hr = font->format->GetFontFamilyName(family, family_length + 1);
        if (SUCCEEDED(hr)) hr = font->format->GetLocaleName(locale, locale_length + 1);
        if (SUCCEEDED(hr)) hr = font->format->GetFontCollection(&collection);
        DWRITE_TEXT_RANGE span{item.start, item.length};
        if (SUCCEEDED(hr)) hr = layout->SetFontCollection(collection, span);
        if (SUCCEEDED(hr)) hr = layout->SetFontFamilyName(family, span);
        if (SUCCEEDED(hr)) hr = layout->SetFontWeight(font->format->GetFontWeight(), span);
        if (SUCCEEDED(hr)) hr = layout->SetFontStyle(item.italic_override < 0 ? font->format->GetFontStyle() :
            item.italic_override ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, span);
        if (SUCCEEDED(hr)) hr = layout->SetFontStretch(font->format->GetFontStretch(), span);
        if (SUCCEEDED(hr)) hr = layout->SetFontSize(item.size, span);
        if (SUCCEEDED(hr)) hr = layout->SetLocaleName(locale, span);
        if (collection) collection->Release();
        free(family); free(locale);
        if (FAILED(hr)) return 0; // Caller discards this partially configured layout.
    }
    return 1;
}

extern "C" float zenit_dwrite_measure_utf8_with_ranges(
    ZenitDWriteFont *font, const char *text, uint32_t length, const ZenitDWriteFontRanges *ranges) {
    if (!font || !text || length == 0 || length > INT32_MAX) return 0;
    int wide_length = 0;
    wchar_t *wide = utf8_to_utf16(text, (int)length, &wide_length);
    if (!wide) return 0;
    IDWriteTextLayout *layout = nullptr;
    HRESULT hr = font->factory->CreateTextLayout(wide, (UINT32)wide_length,
        font->format, 1000000.0f, 1000000.0f, &layout);
    if (SUCCEEDED(hr) && !zenit_dwrite_apply_font_ranges(layout, ranges, reinterpret_cast<const uint16_t *>(wide), wide_length)) hr = E_INVALIDARG;
    free(wide);
    if (FAILED(hr)) { if (layout) layout->Release(); return 0; }
    DWRITE_TEXT_METRICS metrics;
    hr = layout->GetMetrics(&metrics);
    layout->Release();
    return SUCCEEDED(hr) ? metrics.widthIncludingTrailingWhitespace : 0;
}
extern "C" float zenit_dwrite_measure_utf8(ZenitDWriteFont *font, const char *text, uint32_t length) {
    return zenit_dwrite_measure_utf8_with_ranges(font, text, length, nullptr);
}

extern "C" float zenit_dwrite_ascent(const ZenitDWriteFont *font) {
    return font ? font->size * font->metrics.ascent / font->metrics.designUnitsPerEm : 0;
}
extern "C" float zenit_dwrite_descent(const ZenitDWriteFont *font) {
    return font ? font->size * font->metrics.descent / font->metrics.designUnitsPerEm : 0;
}
extern "C" float zenit_dwrite_leading(const ZenitDWriteFont *font) {
    return font ? font->size * font->metrics.lineGap / font->metrics.designUnitsPerEm : 0;
}
extern "C" uint32_t zenit_dwrite_glyph_index(
    const ZenitDWriteFont *font, uint32_t codepoint) {
    if (!font) return 0;
    UINT16 glyph = 0;
    if (FAILED(font->face->GetGlyphIndices(&codepoint, 1, &glyph))) return 0;
    return glyph;
}

extern "C" int zenit_dwrite_font_has_color_glyphs(const ZenitDWriteFont *font) {
    if (!font) return 0;
    IDWriteFontFace2 *face = nullptr;
    if (FAILED(font->face->QueryInterface(__uuidof(IDWriteFontFace2), (void **)&face))) return 0;
    const bool color = face->IsColorFont() != FALSE;
    face->Release();
    return color;
}

// COLR/CPAL layers are rasterized in painter order into the atlas's native
// premultiplied BGRA representation. Analysis owns the geometry after the
// enumerator advances. No D2D target, GPU wait or C++ runtime is required.
struct ColorGlyphLayer {
    IDWriteGlyphRunAnalysis *analysis;
    RECT bounds;
    DWRITE_COLOR_F color;
    ColorGlyphLayer *next;
};
static int rasterize_color_glyph(ZenitDWriteFont *font, const DWRITE_GLYPH_RUN &run,
    float scale, float x, float y, uint8_t **pixels, uint32_t *width, uint32_t *height,
    int32_t *bearing_x, int32_t *bearing_y) {
    IDWriteFactory2 *factory = nullptr;
    if (FAILED(font->factory->QueryInterface(__uuidof(IDWriteFactory2), (void **)&factory))) return 1;
    IDWriteColorGlyphRunEnumerator *enumerator = nullptr;
    HRESULT hr = factory->TranslateColorGlyphRun(x, y, &run, nullptr,
        DWRITE_MEASURING_MODE_NATURAL, nullptr, 0, &enumerator);
    factory->Release();
    if (hr == DWRITE_E_NOCOLOR) return 1;
    if (FAILED(hr) || !enumerator) return -1;
    ColorGlyphLayer *head = nullptr, **tail = &head;
    RECT extent = {INT_MAX, INT_MAX, INT_MIN, INT_MIN};
    unsigned layer_count = 0;
    bool has_palette = false;
    int result = -1;
    uint8_t *output = nullptr, *mask = nullptr;
    for (;;) {
        BOOL more = FALSE;
        hr = enumerator->MoveNext(&more);
        if (FAILED(hr) || !more) break;
        const DWRITE_COLOR_GLYPH_RUN *layer = nullptr;
        hr = enumerator->GetCurrentRun(&layer);
        if (FAILED(hr) || !layer || ++layer_count > 1024) { hr = E_FAIL; break; }
        auto *entry = (ColorGlyphLayer *)calloc(1, sizeof(ColorGlyphLayer));
        if (!entry) { hr = E_OUTOFMEMORY; break; }
        *tail = entry; tail = &entry->next;
        entry->color = layer->runColor;
        hr = font->factory->CreateGlyphRunAnalysis(&layer->glyphRun, scale, nullptr,
            DWRITE_RENDERING_MODE_NATURAL, DWRITE_MEASURING_MODE_NATURAL,
            layer->baselineOriginX, layer->baselineOriginY, &entry->analysis);
        if (FAILED(hr)) break;
        hr = entry->analysis->GetAlphaTextureBounds(DWRITE_TEXTURE_CLEARTYPE_3x1, &entry->bounds);
        if (FAILED(hr)) break;
        const bool empty = entry->bounds.right <= entry->bounds.left || entry->bounds.bottom <= entry->bounds.top;
        // A foreground-brush layer cannot be baked into a reusable fixed-color
        // atlas entry without retaining its separate tint mask. Windows 10's
        // Segoe UI Emoji starts many glyphs with an inkless foreground layer
        // (glyph 1); it contributes nothing and must not discard the colors.
        if (layer->paletteIndex == 0xffff) {
            if (empty) continue;
            result = 1; hr = E_FAIL; break;
        }
        has_palette = true;
        if (empty) continue;
        if (entry->bounds.left < extent.left) extent.left = entry->bounds.left;
        if (entry->bounds.top < extent.top) extent.top = entry->bounds.top;
        if (entry->bounds.right > extent.right) extent.right = entry->bounds.right;
        if (entry->bounds.bottom > extent.bottom) extent.bottom = entry->bounds.bottom;
    }
    enumerator->Release();
    if (SUCCEEDED(hr) && has_palette && extent.right > extent.left && extent.bottom > extent.top) {
        const int64_t w = (int64_t)extent.right - extent.left, h = (int64_t)extent.bottom - extent.top;
        if (w <= 4096 && h <= 4096) {
            const size_t count = (size_t)w * (size_t)h;
            output = (uint8_t *)calloc(count, 4);
            mask = (uint8_t *)malloc(count * 3);
            if (output && mask) {
                result = 0;
                for (auto *entry = head; entry; entry = entry->next) {
                    if (entry->bounds.right <= entry->bounds.left || entry->bounds.bottom <= entry->bounds.top) continue;
                    hr = entry->analysis->CreateAlphaTexture(DWRITE_TEXTURE_CLEARTYPE_3x1,
                        &extent, mask, (UINT32)(count * 3));
                    if (FAILED(hr)) { result = -1; break; }
                    for (size_t i = 0; i < count; ++i) {
                        const float a = ((float)mask[i*3] + mask[i*3+1] + mask[i*3+2]) / (3.0f * 255.0f) * entry->color.a;
                        const float channels[4] = {entry->color.b, entry->color.g, entry->color.r, 1};
                        for (unsigned c = 0; c < 4; ++c) {
                            const float v = channels[c] * a * 255 + output[i*4+c] * (1-a);
                            output[i*4+c] = (uint8_t)fminf(255, fmaxf(0, floorf(v + 0.5f)));
                        }
                    }
                }
                if (!result) {
                    *pixels = output; output = nullptr;
                    *width = (uint32_t)w; *height = (uint32_t)h;
                    *bearing_x = extent.left; *bearing_y = -extent.top;
                }
            }
        }
    }
    free(output); free(mask);
    while (head) {
        auto *next = head->next;
        if (head->analysis) head->analysis->Release();
        free(head); head = next;
    }
    return result;
}

extern "C" int zenit_dwrite_cleartype_enabled() {
    BOOL smoothing = FALSE; UINT type = 0;
    if (!SystemParametersInfoW(SPI_GETFONTSMOOTHING, 0, &smoothing, 0) ||
        !SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE, 0, &type, 0)) return 0;
    return smoothing && type == FE_FONTSMOOTHINGCLEARTYPE;
}

// Keep raw masks color-independent; alpha correction belongs to the final blend.
extern "C" int zenit_dwrite_text_rendering_params(float out[8]) {
    if (!out) return -1;
    IDWriteFactory *factory = nullptr;
    IDWriteRenderingParams *params = nullptr;
    IDWriteRenderingParams1 *params1 = nullptr;
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown **>(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateMonitorRenderingParams(MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY), &params);
    if (SUCCEEDED(hr)) hr = params->QueryInterface(__uuidof(IDWriteRenderingParams1), (void **)&params1);
    if (SUCCEEDED(hr)) {
        dwrite_gamma_ratios(params->GetGamma(), out);
        out[4] = params1->GetGrayscaleEnhancedContrast();
        out[5] = params->GetEnhancedContrast();
        out[6] = params->GetClearTypeLevel();
        out[7] = params->GetPixelGeometry() != DWRITE_PIXEL_GEOMETRY_FLAT && params->GetClearTypeLevel() > 0;
    }
    if (params1) params1->Release();
    if (params) params->Release();
    if (factory) factory->Release();
    return SUCCEEDED(hr) ? 0 : -1;
}

extern "C" int zenit_dwrite_rasterize_glyph_context(
    ZenitDWriteRasterContext *ctx, ZenitDWriteFont *font, uint32_t glyph_index, float scale,
    float offset_x, float offset_y, uint32_t cleartype, uint8_t **out_pixels,
    uint32_t *out_width, uint32_t *out_height,
    int32_t *out_bearing_x, int32_t *out_bearing_y,
    int32_t *out_advance, uint32_t *out_is_color) {
    if (!font || !out_pixels || !out_width || !out_height ||
        !out_bearing_x || !out_bearing_y || !out_advance || !out_is_color ||
        glyph_index > UINT16_MAX || scale <= 0) return -1;
    if (!ctx) {
        if (!font->coverage) font->coverage = zenit_dwrite_raster_context_create();
        ctx = font->coverage;
        float params[8]; if (!ctx || zenit_dwrite_raster_context_refresh(ctx, nullptr, 0, params) < 0) return -1;
    }
    if (ctx->thread != GetCurrentThreadId() || !ctx->params) return -1;
    *out_pixels = nullptr;
    *out_is_color = 0;
    *out_width = *out_height = 0;
    UINT16 glyph = (UINT16)glyph_index;
    DWRITE_GLYPH_METRICS metrics;
    if (FAILED(font->face->GetDesignGlyphMetrics(&glyph, 1, &metrics, FALSE))) return -1;
    float advance = font->size * scale * metrics.advanceWidth / font->metrics.designUnitsPerEm;
    *out_advance = (int32_t)(advance + 0.5f);
    FLOAT advance_dip = font->size * metrics.advanceWidth / font->metrics.designUnitsPerEm;
    DWRITE_GLYPH_OFFSET glyph_offset = {0, 0};
    DWRITE_GLYPH_RUN run = {};
    run.fontFace = font->face;
    run.fontEmSize = font->size;
    run.glyphCount = 1;
    run.glyphIndices = &glyph;
    run.glyphAdvances = &advance_dip;
    run.glyphOffsets = &glyph_offset;
    if (zenit_dwrite_font_has_color_glyphs(font)) {
        const int color = rasterize_color_glyph(font, run, scale, offset_x, offset_y,
            out_pixels, out_width, out_height, out_bearing_x, out_bearing_y);
        if (color <= 0) { *out_is_color = color == 0; return color; }
    }
    IDWriteFactory2 *factory = nullptr;
    IDWriteGlyphRunAnalysis *analysis = nullptr;
    HRESULT hr = font->factory->QueryInterface(__uuidof(IDWriteFactory2), (void **)&factory);
    if (FAILED(hr)) return -1;
    DWRITE_RENDERING_MODE mode;
    hr = font->face->GetRecommendedRenderingMode(font->size, scale,
        DWRITE_MEASURING_MODE_NATURAL, ctx->params, &mode);
    if (FAILED(hr)) { factory->Release(); return -1; }
    // Very large text recommends outlines; the atlas still needs an AA bitmap.
    if (mode == DWRITE_RENDERING_MODE_OUTLINE) mode = DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC;
    // Atlas offsets are physical pixels. Translation must follow DIP scaling.
    DWRITE_MATRIX transform = {scale, 0, 0, scale, offset_x, offset_y};
    hr = factory->CreateGlyphRunAnalysis(&run, &transform,
        mode, DWRITE_MEASURING_MODE_NATURAL,
        DWRITE_GRID_FIT_MODE_ENABLED, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
        0, 0, &analysis);
    factory->Release();
    if (FAILED(hr)) return -1;
    RECT bounds;
    hr = analysis->GetAlphaTextureBounds(DWRITE_TEXTURE_ALIASED_1x1, &bounds);
    analysis->Release();
    if (FAILED(hr)) return -1;
    if (bounds.right <= bounds.left || bounds.bottom <= bounds.top) return 0;
    // D2D and GlyphRunAnalysis do not use identical grayscale scan conversion.
    // Draw an uncorrected mask, as Terminal's atlas does, rather than averaging LCD.
    bounds.left -= 2; bounds.top -= 2; bounds.right += 2; bounds.bottom += 2;
    const int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
    if (width > 4094 || height > 4094) return 2;
    hr = raster_context_target(ctx, width, height);
    ID2D1RenderTarget *target = ctx->target;
    IWICBitmap *bitmap = ctx->bitmap;
    ID2D1SolidColorBrush *brush = ctx->brush;
    uint8_t *bgra = nullptr, *pixels = nullptr;
    if (SUCCEEDED(hr)) {
        target->SetDpi(96*scale, 96*scale);
        target->SetTextRenderingParams(ctx->raw);
        target->SetTextAntialiasMode(cleartype ? D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE : D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        target->BeginDraw();
        target->PushAxisAlignedClip(D2D1::RectF(0,0,width/scale,height/scale), D2D1_ANTIALIAS_MODE_ALIASED);
        target->Clear(D2D1::ColorF(0.f, 0.f, 0.f, 1.f));
        glyph_offset.advanceOffset = offset_x / scale;
        glyph_offset.ascenderOffset = -offset_y / scale;
        target->DrawGlyphRun(D2D1::Point2F(-bounds.left / scale, -bounds.top / scale), &run, brush, DWRITE_MEASURING_MODE_NATURAL);
        target->PopAxisAlignedClip();
        hr = target->EndDraw();
    }
    const size_t count = (size_t)width * height;
    if (SUCCEEDED(hr)) {
        bgra = (uint8_t *)malloc(count * 4);
        pixels = (uint8_t *)malloc(count * (cleartype ? 4 : 1));
        if (!bgra || !pixels) hr = E_OUTOFMEMORY;
    }
    if (SUCCEEDED(hr)) { WICRect region = {0,0,width,height}; hr = bitmap->CopyPixels(&region, width * 4, (UINT)(count * 4), bgra); }
    if (SUCCEEDED(hr)) {
        for (size_t i = 0; i < count; ++i) {
            if (cleartype) { pixels[i*4] = bgra[i*4+2]; pixels[i*4+1] = bgra[i*4+1]; pixels[i*4+2] = bgra[i*4]; pixels[i*4+3] = 255; }
            else pixels[i] = bgra[i*4];
        }
        *out_pixels = pixels; *out_width = width; *out_height = height;
        *out_bearing_x = bounds.left; *out_bearing_y = -bounds.top;
        *out_is_color = cleartype ? 2 : 0;
    } else free(pixels);
    free(bgra);
    if (hr == D2DERR_RECREATE_TARGET) {
        if (ctx->brush) ctx->brush->Release();
        if (ctx->target) ctx->target->Release();
        if (ctx->bitmap) ctx->bitmap->Release();
        ctx->brush = nullptr; ctx->target = nullptr; ctx->bitmap = nullptr;
        ctx->width = ctx->height = 0;
    }
    return SUCCEEDED(hr) ? 0 : -1;
}

extern "C" int zenit_dwrite_rasterize_glyph_mode(ZenitDWriteFont *font, uint32_t glyph, float scale, float x, float y, uint32_t lcd,
    uint8_t **pixels, uint32_t *width, uint32_t *height, int32_t *bx, int32_t *by, int32_t *advance, uint32_t *color) {
    return zenit_dwrite_rasterize_glyph_context(nullptr, font, glyph, scale, x, y, lcd, pixels, width, height, bx, by, advance, color);
}
extern "C" int zenit_dwrite_rasterize_glyph(
    ZenitDWriteFont *font, uint32_t glyph_index, float scale, float offset_x, float offset_y,
    uint8_t **pixels, uint32_t *width, uint32_t *height, int32_t *bx, int32_t *by, int32_t *advance, uint32_t *color) {
    return zenit_dwrite_rasterize_glyph_mode(font, glyph_index, scale, offset_x, offset_y, 0, pixels, width, height, bx, by, advance, color);
}

extern "C" void zenit_dwrite_free_bitmap(uint8_t *pixels) { free(pixels); }

extern "C" void zenit_dwrite_retain_font(ZenitDWriteFont *font) {
    if (font) InterlockedIncrement(&font->refs);
}
extern "C" float zenit_dwrite_font_size(const ZenitDWriteFont *font) {
    return font ? font->size : 0;
}
extern "C" uint64_t zenit_dwrite_font_identity(const ZenitDWriteFont *font) {
    if (!font || !font->face) return 0;
    // A layout may return a new COM face object for the same font. Cache keys
    // must identify the font files/index/simulations, not that object address.
    uint64_t hash = 14695981039346656037ull;
    auto mix = [&hash](const void *data, size_t length) {
        const auto *bytes = static_cast<const uint8_t *>(data);
        for (size_t i = 0; i < length; ++i) { hash ^= bytes[i]; hash *= 1099511628211ull; }
    };
    UINT32 index = font->face->GetIndex();
    DWRITE_FONT_SIMULATIONS simulations = font->face->GetSimulations();
    mix(&index, sizeof(index)); mix(&simulations, sizeof(simulations));
    UINT32 count = 0;
    if (FAILED(font->face->GetFiles(&count, nullptr)) || !count) return 0;
    auto **files = static_cast<IDWriteFontFile **>(calloc(count, sizeof(IDWriteFontFile *)));
    if (!files) return 0;
    if (FAILED(font->face->GetFiles(&count, files))) { free(files); return 0; }
    for (UINT32 i = 0; i < count; ++i) {
        const void *key = nullptr; UINT32 length = 0;
        IDWriteFontFileLoader *loader = nullptr;
        if (SUCCEEDED(files[i]->GetReferenceKey(&key, &length)) &&
            SUCCEEDED(files[i]->GetLoader(&loader))) {
            // File keys are scoped to their loader. System/custom loaders are
            // stable process resources, unlike per-shape font face wrappers.
            mix(&loader, sizeof(loader)); mix(&length, sizeof(length)); mix(key, length);
            loader->Release();
        }
        files[i]->Release();
    }
    free(files); return hash;
}

struct ZenitDWriteShapedGlyph {
    uint32_t glyph_index, cluster;
    float x_advance, y_advance, x_offset, y_offset;
    uint32_t flags;
    ZenitDWriteFont *fallback;
};

/* Capture the actual layout runs, including fallback faces, instead of
   looking up a glyph per Unicode codepoint. DirectWrite owns bidi analysis,
   ligatures, combining marks and script-specific joining. */
static bool same_font_face(IDWriteFontFace *a, IDWriteFontFace *b) {
    if (a == b) return true;
    ZenitDWriteFont left = {}, right = {};
    left.face = a; right.face = b;
    uint64_t identity = zenit_dwrite_font_identity(&left);
    return identity && identity == zenit_dwrite_font_identity(&right);
}

class GlyphCollector final : public IDWriteTextRenderer {
public:
    ZenitDWriteFont *base;
    const uint32_t *byte_offsets;
    uint32_t utf16_length;
    ZenitDWriteShapedGlyph *glyphs = nullptr;
    uint32_t count = 0, capacity = 0;
    LONG refs = 1;
    float first_baseline = 0;
    bool has_baseline = false;
    GlyphCollector(ZenitDWriteFont *font, const uint32_t *map, uint32_t length)
        : base(font), byte_offsets(map), utf16_length(length) {}
    ~GlyphCollector() {
        for (uint32_t i = 0; i < count; ++i) zenit_dwrite_release_font(glyphs[i].fallback);
        free(glyphs);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IDWritePixelSnapping) || iid == __uuidof(IDWriteTextRenderer)) {
            *out = static_cast<IDWriteTextRenderer *>(this);
            AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { return InterlockedDecrement(&refs); }
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void *, BOOL *disabled) override {
        if (!disabled) return E_POINTER;
        *disabled = TRUE; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void *, DWRITE_MATRIX *matrix) override {
        if (!matrix) return E_POINTER;
        *matrix = DWRITE_MATRIX{1, 0, 0, 1, 0, 0}; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void *, FLOAT *scale) override {
        if (!scale) return E_POINTER;
        *scale = 1; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void *, FLOAT x, FLOAT y,
        DWRITE_MEASURING_MODE, const DWRITE_GLYPH_RUN *run,
        const DWRITE_GLYPH_RUN_DESCRIPTION *description, IUnknown *) override {
        if (!run || !description || !description->clusterMap || run->isSideways) return E_INVALIDARG;
        if (description->textPosition > utf16_length || description->stringLength > utf16_length - description->textPosition) return E_INVALIDARG;
        if (run->glyphCount > 1000000 - count) return E_OUTOFMEMORY;
        if (count + run->glyphCount > capacity) {
            uint32_t next = (count + run->glyphCount) * 2;
            void *memory = realloc(glyphs, (size_t)next * sizeof(*glyphs));
            if (!memory) return E_OUTOFMEMORY;
            glyphs = static_cast<ZenitDWriteShapedGlyph *>(memory); capacity = next;
        }
        uint32_t *clusters = static_cast<uint32_t *>(malloc((size_t)run->glyphCount * sizeof(uint32_t)));
        if (!clusters && run->glyphCount) return E_OUTOFMEMORY;
        for (uint32_t g = 0; g < run->glyphCount; ++g) clusters[g] = UINT32_MAX;
        for (uint32_t c = 0; c < description->stringLength; ++c) {
            uint32_t g = description->clusterMap[c];
            uint32_t position = description->textPosition + c;
            if (g >= run->glyphCount || position >= utf16_length) { free(clusters); return E_INVALIDARG; }
            if (clusters[g] == UINT32_MAX) clusters[g] = byte_offsets[position];
        }
        // Additional glyphs in a multi-glyph cluster share its first byte.
        uint32_t cluster = byte_offsets[description->textPosition];
        for (uint32_t g = 0; g < run->glyphCount; ++g) {
            if (clusters[g] != UINT32_MAX) cluster = clusters[g]; else clusters[g] = cluster;
        }
        ZenitDWriteFont *fallback = nullptr;
        if (!same_font_face(run->fontFace, base->face) || run->fontEmSize != base->size) {
            fallback = static_cast<ZenitDWriteFont *>(calloc(1, sizeof(*fallback)));
            if (!fallback) { free(clusters); return E_OUTOFMEMORY; }
            fallback->refs = 1;
            fallback->size = run->fontEmSize;
            fallback->factory = base->factory; fallback->factory->AddRef();
            fallback->face = run->fontFace; fallback->face->AddRef();
            fallback->face->GetMetrics(&fallback->metrics);
        }
        if (!has_baseline) { first_baseline = y; has_baseline = true; }
        float pen = x;
        bool rtl = (run->bidiLevel & 1) != 0;
        for (uint32_t g = 0; g < run->glyphCount; ++g) {
            float advance = run->glyphAdvances[g];
            DWRITE_GLYPH_OFFSET offset = run->glyphOffsets ? run->glyphOffsets[g] : DWRITE_GLYPH_OFFSET{0, 0};
            if (rtl) pen -= advance;
            zenit_dwrite_retain_font(fallback);
            glyphs[count++] = ZenitDWriteShapedGlyph{
                run->glyphIndices[g], clusters[g], advance, 0,
                pen + (rtl ? -offset.advanceOffset : offset.advanceOffset),
                y - first_baseline - offset.ascenderOffset,
                fallback ? 1u : 0u, fallback
            };
            if (!rtl) pen += advance;
        }
        zenit_dwrite_release_font(fallback);
        free(clusters); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void *, FLOAT, FLOAT, const DWRITE_UNDERLINE *, IUnknown *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void *, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH *, IUnknown *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) override { return E_NOTIMPL; }
};

// Preserve shaped ligatures and bearings; change primary-face cluster advances.
// Resolve the requested face at this formatted range, including real or
// simulated italic. Actual system fallback runs still keep natural advances.
static IDWriteFontFace *formatted_font_face(IDWriteTextLayout *layout, UINT32 position) {
    IDWriteFontCollection *collection = nullptr;
    IDWriteFontFamily *family = nullptr;
    IDWriteFont *match = nullptr;
    IDWriteFontFace *face = nullptr;
    wchar_t *name = nullptr;
    UINT32 length = 0, index = 0;
    BOOL exists = FALSE;
    DWRITE_FONT_WEIGHT weight;
    DWRITE_FONT_STYLE style;
    DWRITE_FONT_STRETCH stretch;
    if (FAILED(layout->GetFontFamilyNameLength(position, &length)) ||
        FAILED(layout->GetFontCollection(position, &collection)) || !collection) goto done;
    name = static_cast<wchar_t *>(calloc((size_t)length + 1, sizeof(wchar_t)));
    if (!name || FAILED(layout->GetFontFamilyName(position, name, length + 1)) ||
        FAILED(layout->GetFontWeight(position, &weight)) ||
        FAILED(layout->GetFontStyle(position, &style)) ||
        FAILED(layout->GetFontStretch(position, &stretch)) ||
        FAILED(collection->FindFamilyName(name, &index, &exists)) || !exists ||
        FAILED(collection->GetFontFamily(index, &family)) ||
        FAILED(family->GetFirstMatchingFont(weight, stretch, style, &match)) ||
        FAILED(match->CreateFontFace(&face))) goto done;
done:
    if (match) match->Release();
    if (family) family->Release();
    if (collection) collection->Release();
    free(name);
    return face;
}

class FixedAsciiRenderer final : public IDWriteTextRenderer {
    LONG refs = 1;
    ID2D1RenderTarget *target;
    ID2D1Brush *brush;
    IDWriteTextLayout *layout;
    float x, y, baseline, cell, pen = 0;
public:
    FixedAsciiRenderer(ID2D1RenderTarget *t, ID2D1Brush *b, IDWriteTextLayout *l,
        float px, float py, float bl, float c): target(t), brush(b), layout(l), x(px), y(py), baseline(bl), cell(c) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(IDWritePixelSnapping) && iid != __uuidof(IDWriteTextRenderer)) return E_NOINTERFACE;
        *out = static_cast<IDWriteTextRenderer *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { return InterlockedDecrement(&refs); }
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void *, BOOL *out) override { if (!out) return E_POINTER; *out = TRUE; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void *, DWRITE_MATRIX *out) override { if (!out) return E_POINTER; *out = {1, 0, 0, 1, 0, 0}; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void *, FLOAT *out) override { if (!out) return E_POINTER; *out = 1; return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void *, FLOAT, FLOAT cy, DWRITE_MEASURING_MODE,
        const DWRITE_GLYPH_RUN *run, const DWRITE_GLYPH_RUN_DESCRIPTION *desc, IUnknown *) override {
        if (!run || !desc || !desc->clusterMap || run->isSideways || (run->bidiLevel & 1) || run->glyphCount > 1048576) return E_INVALIDARG;
        if (!run->glyphCount) return S_OK;
        auto *clusters = static_cast<uint32_t *>(malloc(run->glyphCount * sizeof(uint32_t)));
        auto *advances = static_cast<float *>(malloc(run->glyphCount * sizeof(float)));
        if (!clusters || !advances) { free(clusters); free(advances); return E_OUTOFMEMORY; }
        for (uint32_t g = 0; g < run->glyphCount; ++g) clusters[g] = UINT32_MAX;
        for (uint32_t c = 0; c < desc->stringLength; ++c) {
            uint32_t g = desc->clusterMap[c];
            if (g >= run->glyphCount) { free(clusters); free(advances); return E_INVALIDARG; }
            if (clusters[g] == UINT32_MAX) clusters[g] = c;
        }
        uint32_t cluster = 0;
        for (uint32_t g = 0; g < run->glyphCount; ++g) {
            if (clusters[g] != UINT32_MAX) cluster = clusters[g]; else clusters[g] = cluster;
        }
        IDWriteFontFace *requested = formatted_font_face(layout, desc->textPosition);
        if (!requested) { free(clusters); free(advances); return E_FAIL; }
        bool fixed = same_font_face(requested, run->fontFace);
        requested->Release();
        float total = 0;
        for (uint32_t g = 0; g < run->glyphCount; ++g) {
            uint32_t next = g + 1 < run->glyphCount ? clusters[g + 1] : desc->stringLength;
            advances[g] = fixed ? cell * (next > clusters[g] ? next - clusters[g] : 1) : run->glyphAdvances[g];
            total += advances[g];
        }
        DWRITE_GLYPH_RUN adjusted = *run; adjusted.glyphAdvances = advances;
        target->DrawGlyphRun({x + pen, y + cy - baseline}, &adjusted, brush, DWRITE_MEASURING_MODE_NATURAL);
        pen += total;
        free(clusters); free(advances); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void *, FLOAT, FLOAT, const DWRITE_UNDERLINE *, IUnknown *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void *, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH *, IUnknown *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) override { return E_NOTIMPL; }
};
extern "C" int zenit_dwrite_draw_fixed_ascii(void *layout, void *target, void *brush,
    const void *font, float x, float y, float baseline, float advance) {
    if (!layout || !target || !brush || !isfinite(advance) || advance <= 0) return 0;
    FixedAsciiRenderer renderer(static_cast<ID2D1RenderTarget *>(target), static_cast<ID2D1Brush *>(brush),
        static_cast<IDWriteTextLayout *>(layout), x, y, baseline, advance);
    return SUCCEEDED(static_cast<IDWriteTextLayout *>(layout)->Draw(nullptr, &renderer, 0, 0));
}

static int compare_glyph_positions(const void *a, const void *b) {
    const auto *left = static_cast<const ZenitDWriteShapedGlyph *>(a);
    const auto *right = static_cast<const ZenitDWriteShapedGlyph *>(b);
    return left->x_offset < right->x_offset ? -1 : left->x_offset > right->x_offset ? 1 : 0;
}
extern "C" int zenit_dwrite_shape_utf8_with_ranges(ZenitDWriteFont *font, const char *text,
    uint32_t length, int italic, ZenitDWriteShapedGlyph **out_glyphs, uint32_t *out_count,
    const ZenitDWriteFontRanges *ranges) {
    if (!font || !out_glyphs || !out_count || length > INT32_MAX) return -1;
    *out_glyphs = nullptr; *out_count = 0;
    if (!length) return ranges && ranges->text_length ? -1 : 0;
    int wide_length = 0;
    wchar_t *wide = utf8_to_utf16(text, (int)length, &wide_length);
    if (!wide) return -1;
    uint32_t *map = static_cast<uint32_t *>(calloc((size_t)wide_length + 1, sizeof(uint32_t)));
    if (!map) { free(wide); return -1; }
    uint32_t w = 0;
    for (uint32_t b = 0; b < length;) {
        uint8_t first = (uint8_t)text[b];
        uint32_t bytes = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4;
        map[w++] = b;
        if (bytes == 4) map[w++] = b;
        b += bytes;
    }
    map[w] = length;
    IDWriteTextLayout *layout = nullptr;
    HRESULT hr = font->factory->CreateTextLayout(wide, (UINT32)wide_length,
        font->format, 1000000.0f, 1000000.0f, &layout);
    if (SUCCEEDED(hr) && italic) hr = layout->SetFontStyle(DWRITE_FONT_STYLE_ITALIC, DWRITE_TEXT_RANGE{0, (UINT32)wide_length});
    if (SUCCEEDED(hr) && !zenit_dwrite_apply_font_ranges(layout, ranges, reinterpret_cast<const uint16_t *>(wide), wide_length)) hr = E_INVALIDARG;
    free(wide);
    if (FAILED(hr)) { if (layout) layout->Release(); free(map); return -1; }
    GlyphCollector collector(font, map, (uint32_t)wide_length);
    hr = layout->Draw(nullptr, &collector, 0, 0);
    layout->Release(); free(map);
    if (FAILED(hr)) return -1;
    qsort(collector.glyphs, collector.count, sizeof(*collector.glyphs), compare_glyph_positions);
    float pen = 0;
    for (uint32_t i = 0; i < collector.count; ++i) {
        float position = collector.glyphs[i].x_offset;
        collector.glyphs[i].x_offset = position - pen;
        pen += collector.glyphs[i].x_advance;
    }
    *out_glyphs = collector.glyphs; *out_count = collector.count;
    collector.glyphs = nullptr; collector.count = 0;
    return 0;
}
extern "C" int zenit_dwrite_shape_utf8(ZenitDWriteFont *font, const char *text,
    uint32_t length, int italic, ZenitDWriteShapedGlyph **out_glyphs, uint32_t *out_count) {
    return zenit_dwrite_shape_utf8_with_ranges(font, text, length, italic, out_glyphs, out_count, nullptr);
}
extern "C" void zenit_dwrite_free_shaped_glyphs(ZenitDWriteShapedGlyph *glyphs) { free(glyphs); }

struct ZenitDWriteCaretStop {
    uint32_t byte_offset;
    float primary_x, secondary_x;
    uint32_t has_secondary;
};
struct ZenitDWriteLineMetrics {
    float width, ascent, descent, leading;
    uint32_t base_rtl;
};
extern "C" int zenit_dwrite_line_caret_stops_with_ranges(ZenitDWriteFont *font,
    const char *text, uint32_t length, const uint32_t *boundaries,
    uint32_t boundary_count, ZenitDWriteCaretStop *stops, ZenitDWriteLineMetrics *metrics,
    const ZenitDWriteFontRanges *ranges) {
    if (!font || !boundaries || !boundary_count || !stops || !metrics || length > INT32_MAX) return -1;
    *metrics = ZenitDWriteLineMetrics{0, zenit_dwrite_ascent(font), zenit_dwrite_descent(font), zenit_dwrite_leading(font), 0};
    if (!length) {
        if (ranges && ranges->text_length) return -1;
        for (uint32_t i = 0; i < boundary_count; ++i) {
            if (boundaries[i]) return -1;
            stops[i] = ZenitDWriteCaretStop{0, 0, 0, 0};
        }
        return 0;
    }
    int wide_length = 0;
    wchar_t *wide = utf8_to_utf16(text, (int)length, &wide_length);
    if (!wide) return -1;
    // UTF-8 boundaries are public. DirectWrite positions index UTF-16 units.
    uint32_t *map = static_cast<uint32_t *>(malloc(((size_t)length + 1) * sizeof(uint32_t)));
    if (!map) { free(wide); return -1; }
    for (uint32_t b = 0; b <= length; ++b) map[b] = UINT32_MAX;
    uint32_t w = 0;
    for (uint32_t b = 0; b < length;) {
        uint8_t first = (uint8_t)text[b];
        uint32_t bytes = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4;
        map[b] = w; w += bytes == 4 ? 2 : 1; b += bytes;
    }
    map[length] = w;
    IDWriteTextLayout *layout = nullptr;
    HRESULT hr = font->factory->CreateTextLayout(wide, (UINT32)wide_length,
        font->format, 1000000.0f, 1000000.0f, &layout);
    if (SUCCEEDED(hr) && !zenit_dwrite_apply_font_ranges(layout, ranges, reinterpret_cast<const uint16_t *>(wide), wide_length)) hr = E_INVALIDARG;
    free(wide);
    if (FAILED(hr)) { if (layout) layout->Release(); free(map); return -1; }
    DWRITE_TEXT_METRICS text_metrics;
    hr = layout->GetMetrics(&text_metrics);
    if (SUCCEEDED(hr) && ranges) {
        // A VisualLine has one native line. Range fonts can be taller than
        // the primary font; caret/selection height must use the same layout.
        DWRITE_LINE_METRICS line = {};
        UINT32 line_count = 0;
        hr = layout->GetLineMetrics(&line, 1, &line_count);
        if (SUCCEEDED(hr) && line_count != 1) hr = E_INVALIDARG;
        if (SUCCEEDED(hr)) {
            metrics->ascent = line.baseline;
            metrics->descent = line.height - line.baseline;
            metrics->leading = 0;
        }
    }
    if (SUCCEEDED(hr)) {
        metrics->width = text_metrics.widthIncludingTrailingWhitespace;
        metrics->base_rtl = layout->GetReadingDirection() == DWRITE_READING_DIRECTION_RIGHT_TO_LEFT;
        for (uint32_t i = 0; i < boundary_count; ++i) {
            uint32_t byte = boundaries[i];
            if (byte > length || map[byte] == UINT32_MAX) { hr = E_INVALIDARG; break; }
            uint32_t position = map[byte];
            FLOAT current_x = 0, previous_x = 0, y = 0;
            DWRITE_HIT_TEST_METRICS current = {}, previous = {};
            if (position < (uint32_t)wide_length) {
                hr = layout->HitTestTextPosition(position, FALSE, &current_x, &y, &current);
                if (FAILED(hr)) break;
            }
            if (position > 0) {
                hr = layout->HitTestTextPosition(position - 1, TRUE, &previous_x, &y, &previous);
                if (FAILED(hr)) break;
            }
            // Downstream is the leading edge of the next cluster. At line
            // end use the previous cluster's trailing edge, not the paragraph
            // sentinel, which may be on the opposite side of an RTL run.
            float primary = position == (uint32_t)wide_length ? previous_x : current_x;
            float delta = current_x - previous_x;
            bool split = position > 0 && position < (uint32_t)wide_length &&
                current.bidiLevel != previous.bidiLevel && (delta > 0.01f || delta < -0.01f);
            stops[i] = ZenitDWriteCaretStop{byte, primary, split ? previous_x : primary, split ? 1u : 0u};
        }
    }
    layout->Release(); free(map);
    return SUCCEEDED(hr) ? 0 : -1;
}

extern "C" int zenit_dwrite_line_caret_stops(ZenitDWriteFont *font,
    const char *text, uint32_t length, const uint32_t *boundaries,
    uint32_t count, ZenitDWriteCaretStop *stops, ZenitDWriteLineMetrics *metrics) {
    return zenit_dwrite_line_caret_stops_with_ranges(font, text, length, boundaries, count, stops, metrics, nullptr);
}
