// Compositor sprites on Windows (see src/ui/core/compositor_sprite.zig and
// src/zenit_app/sprite_host.zig): a GPU-rendered flipbook shown above the
// window's swap chain through DirectComposition and stepped by the system
// compositor, so a periodic animation needs no application frames.
//
// The flipbook arrives tile-compacted (src/zenit_app/sprite_tiles.zig): an
// atlas (a composition swap chain, see zenit_d12_sprite_atlas_create in the
// D3D12 / D3D11 backends) holding the cell of frame 0 at its origin and a
// dictionary of tile contents below it, plus, for every tile position whose
// content changes, the dictionary entry it shows in each frame. Each sprite is
//
//   clip visual        at the cell's window position, clipped to the cell
//                      (and to the node's rectangular clip)
//     base visual      the atlas at (0, 0): frame 0, which every tile that
//                      never changes already shows
//     tile visual      at the tile position, clipped to the tile
//       content visual the atlas, offset by step animations so that the
//                      tile's entry for the current frame lies under the clip
//
// DWM evaluates the animations at every composition. The visuals live in a
// topmost DirectComposition target of the window, above the swap chain
// whether it is presented to the HWND or through the backend's own
// (non-topmost) composition target.
//
// Every function runs on the owning UI thread. Coordinates are the window's
// client device pixels.
#include <algorithm>
#include <windows.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

extern "C" {
// Tile position inside the cell (src/zenit_app/sprite_tiles.zig Tile).
typedef struct ZenitWinSpriteTile { uint16_t x, y, w, h; } ZenitWinSpriteTile;
// Compacted flipbook layout (src/zenit_app/sprite_tiles.zig Compact).
typedef struct ZenitWinSpriteLayout {
    const ZenitWinSpriteTile *tiles;
    const uint32_t *frames;  // tile_count * frame_count dictionary entries, tile-major
    uint32_t tile_count, frame_count, columns, tiles_top, tile_px;
} ZenitWinSpriteLayout;
}

namespace {

constexpr unsigned max_sprites = 64;

struct Sprite {
    unsigned node_id;
    unsigned long long key;
    IUnknown *content_object;  // identity check only (borrowed)
    IDCompositionVisual *clip;
    int origin[2];
    unsigned cell[2];
    int clip_rect[4];
    unsigned frozen;  // frame shown while frozen (tests)
    bool built_frozen; // whether the tiles were built still (tests)
    bool seen;
    // Removed from the tree once the frame that paints the node again is
    // complete (zenit_win_sprites_flush).
    bool leaving;
};

struct Host {
    HWND hwnd;
    IDCompositionDevice *device;
    IDCompositionTarget *target;  // null when joined to the surface's tree
    IDCompositionVisual *root;
    IDCompositionVisual *parent;  // the surface's root when joined
    Sprite sprites[max_sprites];
    unsigned count;
    bool dirty;
};

bool env_flag(const char *name) {
    char flag[2] = {};
    return GetEnvironmentVariableA(name, flag, sizeof(flag)) && flag[0] == '1';
}

// ZENIT_DEBUG_SPRITE_FREEZE=1 (or zenit_win_sprites_set_freeze): show the
// flipbook frame for the phase passed to each put instead of animating (pixel
// comparisons against the GPU path).
int g_freeze = -1;
bool freeze_enabled() {
    if (g_freeze < 0) g_freeze = env_flag("ZENIT_DEBUG_SPRITE_FREEZE");
    return g_freeze == 1;
}

bool g_debug = false;
bool debug_enabled() {
    static int debug = -1;
    if (debug < 0) debug = env_flag("ZENIT_DEBUG_SPRITES");
    return debug == 1 || g_debug;
}

void release_sprite(Host *host, Sprite *s) {
    if (s->clip) {
        s->clip->RemoveAllVisuals();
        host->root->RemoveVisual(s->clip);
        s->clip->Release();
    }
    *s = Sprite{};
}

Sprite *find(Host *host, unsigned node_id) {
    for (unsigned i = 0; i < host->count; ++i)
        if (host->sprites[i].node_id == node_id) return &host->sprites[i];
    return nullptr;
}

void remove_at(Host *host, unsigned index) {
    release_sprite(host, &host->sprites[index]);
    host->sprites[index] = host->sprites[host->count - 1];
    host->sprites[host->count - 1] = Sprite{};
    host->count--;
    host->dirty = true;
}

// Step animation: frame f of `frames` shows value(f) during [f * dt, (f + 1) * dt)
// of every period, from `begin` on.
template <typename Value>
HRESULT step_animation(IDCompositionDevice *device, unsigned frames, double period_s, LARGE_INTEGER begin,
                       Value value, IDCompositionAnimation **out) {
    *out = nullptr;
    IDCompositionAnimation *anim = nullptr;
    HRESULT hr = device->CreateAnimation(&anim);
    const double dt = period_s / frames;
    float last = 0;
    for (unsigned f = 0; f < frames && SUCCEEDED(hr); ++f) {
        const float v = value(f);
        if (f == 0 || v != last) hr = anim->AddCubic(f * dt, v, 0, 0, 0);
        last = v;
    }
    if (SUCCEEDED(hr)) hr = anim->AddRepeat(period_s, period_s);
    if (SUCCEEDED(hr)) hr = anim->SetAbsoluteBeginTime(begin);
    if (FAILED(hr)) {
        if (anim) anim->Release();
        return hr;
    }
    *out = anim;
    return S_OK;
}

HRESULT new_visual(IDCompositionDevice *device, IDCompositionVisual **out) {
    HRESULT hr = device->CreateVisual(out);
    if (SUCCEEDED(hr)) hr = (*out)->SetBitmapInterpolationMode(DCOMPOSITION_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR);
    if (SUCCEEDED(hr)) hr = (*out)->SetBorderMode(DCOMPOSITION_BORDER_MODE_HARD);
    if (FAILED(hr) && *out) {
        (*out)->Release();
        *out = nullptr;
    }
    return hr;
}

// Build the base and tile visuals of one sprite under its clip visual.
HRESULT build_tiles(Host *host, Sprite *s, IUnknown *content, const ZenitWinSpriteLayout *layout, double period_s,
                    double phase_s, double latency_s) {
    IDCompositionDevice *device = host->device;
    s->clip->RemoveAllVisuals();
    IDCompositionVisual *base = nullptr;
    HRESULT hr = new_visual(device, &base);
    if (SUCCEEDED(hr)) hr = base->SetContent(content);
    // (NULL, FALSE): above every existing child.
    if (SUCCEEDED(hr)) hr = s->clip->AddVisual(base, FALSE, nullptr);
    if (base) base->Release();
    if (FAILED(hr)) return hr;

    const unsigned frames = layout->frame_count;
    const double tile = layout->tile_px;
    auto entry_x = [&](uint32_t e) { return (float)(-(double)(e % layout->columns) * tile); };
    auto entry_y = [&](uint32_t e) { return (float)(-((double)layout->tiles_top + (double)(e / layout->columns) * tile)); };

    LARGE_INTEGER begin = {};
    unsigned frozen = 0;
    if (freeze_enabled()) {
        // Tests: hold the frame nearest to the current phase.
        frozen = (unsigned)llround(phase_s / period_s * frames) % frames;
    } else if (layout->tile_count) {
        // Align the step grid to the composition clock: the frame that shows
        // at the next composition is the one nearest the phase the
        // application would paint for it, and every composition samples the
        // middle of a step (no jitter between neighbours).
        DCOMPOSITION_FRAME_STATISTICS st = {};
        hr = device->GetFrameStatistics(&st);
        if (FAILED(hr)) return hr;
        if (st.timeFrequency.QuadPart <= 0) return E_FAIL;
        const double freq = (double)st.timeFrequency.QuadPart;
        const double dt = period_s / frames;
        const double now = (double)st.currentTime.QuadPart;
        double next = (double)st.nextEstimatedFrameTime.QuadPart;
        if (!(next > now)) next = now;
        const double phase_next = phase_s + (next - now) / freq - latency_s;
        double index = fmod(floor(phase_next / dt + 0.5), (double)frames);
        if (index < 0) index += frames;
        // The grid only helps steps about a composition long. A long step (a
        // caret: two frames, half a second each) would start up to half a
        // step off its phase; it starts on the phase exactly instead.
        const DXGI_RATIONAL rate = st.currentCompositionRate;
        const double interval = rate.Numerator ? (double)rate.Denominator / rate.Numerator : 1.0 / 60.0;
        if (dt > 4 * interval) {
            double into = fmod(phase_next, period_s);
            if (into < 0) into += period_s;
            begin.QuadPart = (LONGLONG)llround(next - into * freq);
        } else {
            begin.QuadPart = (LONGLONG)llround(next - (index + 0.5) * dt * freq);
        }
        if (debug_enabled())
            fprintf(stderr, "[sprite] put node=%u frames=%u tiles=%u period=%.3f phase=%.4f next_in=%.4f index=%.0f\n",
                    s->node_id, frames, layout->tile_count, period_s, phase_s, (next - now) / freq, index);
    }
    for (uint32_t i = 0; i < layout->tile_count && SUCCEEDED(hr); ++i) {
        const ZenitWinSpriteTile t = layout->tiles[i];
        const uint32_t *seq = layout->frames + (size_t)i * frames;
        IDCompositionVisual *holder = nullptr, *inner = nullptr;
        hr = new_visual(device, &holder);
        if (SUCCEEDED(hr)) hr = new_visual(device, &inner);
        if (SUCCEEDED(hr)) hr = holder->SetOffsetX((float)t.x);
        if (SUCCEEDED(hr)) hr = holder->SetOffsetY((float)t.y);
        if (SUCCEEDED(hr)) hr = holder->SetClip(D2D_RECT_F{0, 0, (float)t.w, (float)t.h});
        if (SUCCEEDED(hr)) hr = inner->SetContent(content);
        if (SUCCEEDED(hr) && freeze_enabled()) {
            hr = inner->SetOffsetX(entry_x(seq[frozen]));
            if (SUCCEEDED(hr)) hr = inner->SetOffsetY(entry_y(seq[frozen]));
        } else if (SUCCEEDED(hr)) {
            IDCompositionAnimation *ax = nullptr, *ay = nullptr;
            hr = step_animation(device, frames, period_s, begin, [&](unsigned f) { return entry_x(seq[f]); }, &ax);
            if (SUCCEEDED(hr)) hr = step_animation(device, frames, period_s, begin, [&](unsigned f) { return entry_y(seq[f]); }, &ay);
            if (SUCCEEDED(hr)) hr = inner->SetOffsetX(ax);
            if (SUCCEEDED(hr)) hr = inner->SetOffsetY(ay);
            if (ax) ax->Release();
            if (ay) ay->Release();
        }
        if (SUCCEEDED(hr)) hr = holder->AddVisual(inner, FALSE, nullptr);
        if (SUCCEEDED(hr)) hr = s->clip->AddVisual(holder, FALSE, nullptr);
        if (inner) inner->Release();
        if (holder) holder->Release();
    }
    return hr;
}

}  // namespace

// `surface_device` / `surface_root`: the swap chain's own composition tree
// (custom-frame windows present through DirectComposition), joined above its
// content; otherwise the host makes a topmost target of its own.
extern "C" void *zenit_win_sprites_create(void *hwnd, IDCompositionDevice *surface_device, IDCompositionVisual *surface_root) {
    if (!IsWindow((HWND)hwnd)) return nullptr;
    auto host = (Host *)calloc(1, sizeof(Host));
    if (!host) return nullptr;
    host->hwnd = (HWND)hwnd;
    HRESULT hr = S_OK;
    if (surface_device && surface_root) {
        host->device = surface_device;
        host->device->AddRef();
        host->parent = surface_root;
        host->parent->AddRef();
        hr = host->device->CreateVisual(&host->root);
        // (NULL, FALSE): above the swap chain's visuals.
        if (SUCCEEDED(hr)) hr = host->parent->AddVisual(host->root, FALSE, nullptr);
    } else {
        hr = DCompositionCreateDevice(nullptr, __uuidof(IDCompositionDevice), (void **)&host->device);
        // Topmost: above the swap chain presented to the HWND.
        if (SUCCEEDED(hr)) hr = host->device->CreateTargetForHwnd(host->hwnd, TRUE, &host->target);
        if (SUCCEEDED(hr)) hr = host->device->CreateVisual(&host->root);
        if (SUCCEEDED(hr)) hr = host->target->SetRoot(host->root);
    }
    if (SUCCEEDED(hr)) hr = host->device->Commit();
    if (FAILED(hr)) {
        if (debug_enabled()) fprintf(stderr, "[sprite] DirectComposition host failed 0x%08lx\n", (unsigned long)hr);
        if (host->root) {
            if (host->parent) host->parent->RemoveVisual(host->root);
            host->root->Release();
        }
        if (host->parent) host->parent->Release();
        if (host->target) host->target->Release();
        if (host->device) host->device->Release();
        free(host);
        return nullptr;
    }
    return host;
}

extern "C" void zenit_win_sprites_destroy(void *raw) {
    auto host = (Host *)raw;
    if (!host) return;
    while (host->count) remove_at(host, host->count - 1);
    if (host->target) host->target->SetRoot(nullptr);
    if (host->parent) host->parent->RemoveVisual(host->root);
    host->device->Commit();
    host->root->Release();
    if (host->parent) host->parent->Release();
    if (host->target) host->target->Release();
    host->device->Release();
    free(host);
}

extern "C" void zenit_win_sprites_set_debug(int on) { g_debug = on != 0; }
extern "C" void zenit_win_sprites_set_freeze(int on) { g_freeze = on != 0; }
extern "C" int zenit_win_sprites_frozen(void) { return freeze_enabled() ? 1 : 0; }

extern "C" void zenit_win_sprites_begin(void *raw) {
    auto host = (Host *)raw;
    for (unsigned i = 0; i < host->count; ++i) host->sprites[i].seen = false;
}

// Show (or update) one sprite. `content` is the compacted atlas; `layout`
// describes it. `phase_s` is the animation phase now; `latency_s` how much
// later the application's own frames reach the screen (the sprite lags by as
// much, so both show the same picture at the same moment).
extern "C" int zenit_win_sprite_put(void *raw, unsigned node_id, unsigned long long key, IUnknown *content,
                                    const int origin_px[2], const unsigned cell_px[2], const int *clip_px,
                                    const ZenitWinSpriteLayout *layout, double period_s, double phase_s,
                                    double latency_s) {
    auto host = (Host *)raw;
    if (!host || !content || !layout || !layout->frame_count || !layout->columns || !layout->tile_px ||
        !(period_s > 0))
        return 1;
    Sprite *s = find(host, node_id);
    HRESULT hr = S_OK;
    if (!s) {
        if (host->count >= max_sprites) return 2;
        s = &host->sprites[host->count];
        *s = Sprite{};
        s->node_id = node_id;
        hr = new_visual(host->device, &s->clip);
        if (SUCCEEDED(hr)) hr = host->root->AddVisual(s->clip, FALSE, nullptr);
        if (FAILED(hr)) {
            if (s->clip) s->clip->Release();
            *s = Sprite{};
            return 2;
        }
        host->count++;
        host->dirty = true;
    }
    s->seen = true;
    s->leaving = false;
    // The clip visual sits at the cell origin; its clip is the cell
    // intersected with the node's rectangular clip, in cell coordinates.
    int clip[4] = {0, 0, (int)cell_px[0], (int)cell_px[1]};
    if (clip_px) {
        const int l = clip_px[0] - origin_px[0], t = clip_px[1] - origin_px[1];
        const int r = l + clip_px[2], b = t + clip_px[3];
        clip[0] = l > 0 ? l : 0;
        clip[1] = t > 0 ? t : 0;
        clip[2] = r < (int)cell_px[0] ? r : (int)cell_px[0];
        clip[3] = b < (int)cell_px[1] ? b : (int)cell_px[1];
        if (clip[2] < clip[0]) clip[2] = clip[0];
        if (clip[3] < clip[1]) clip[3] = clip[1];
    }
    const bool fresh = !s->content_object;
    if (fresh || s->origin[0] != origin_px[0] || s->origin[1] != origin_px[1]) {
        hr = s->clip->SetOffsetX((float)origin_px[0]);
        if (SUCCEEDED(hr)) hr = s->clip->SetOffsetY((float)origin_px[1]);
        s->origin[0] = origin_px[0];
        s->origin[1] = origin_px[1];
        host->dirty = true;
    }
    if (SUCCEEDED(hr) && (fresh || memcmp(s->clip_rect, clip, sizeof(clip)) != 0)) {
        hr = s->clip->SetClip(D2D_RECT_F{(float)clip[0], (float)clip[1], (float)clip[2], (float)clip[3]});
        memcpy(s->clip_rect, clip, sizeof(clip));
        host->dirty = true;
    }
    // Frozen (tests): the frame follows every put's phase.
    const unsigned frozen = freeze_enabled() ? (unsigned)llround(phase_s / period_s * layout->frame_count) % layout->frame_count : 0;
    if (SUCCEEDED(hr) && (fresh || s->key != key || s->content_object != content || s->cell[0] != cell_px[0] ||
                          s->cell[1] != cell_px[1] || s->built_frozen != freeze_enabled() ||
                          (freeze_enabled() && frozen != s->frozen))) {
        s->frozen = frozen;
        s->built_frozen = freeze_enabled();
        hr = build_tiles(host, s, content, layout, period_s, phase_s, latency_s);
        s->key = key;
        s->content_object = content;
        s->cell[0] = cell_px[0];
        s->cell[1] = cell_px[1];
        host->dirty = true;
    }
    if (FAILED(hr)) {
        if (debug_enabled()) fprintf(stderr, "[sprite] put node=%u failed 0x%08lx\n", node_id, (unsigned long)hr);
        // Leave nothing half-configured on screen.
        for (unsigned i = 0; i < host->count; ++i)
            if (&host->sprites[i] == s) {
                remove_at(host, i);
                break;
            }
        host->device->Commit();
        host->dirty = false;
        return 2;
    }
    return 0;
}

// Sprites not put since zenit_win_sprites_begin leave. With `deferred` they
// stay up until zenit_win_sprites_flush (the frame now being rendered paints
// their nodes, and must be complete first); otherwise they go now. Commits
// what the puts changed. Returns the number of sprites still shown (leaving
// ones included).
extern "C" unsigned zenit_win_sprites_end(void *raw, int deferred) {
    auto host = (Host *)raw;
    unsigned i = 0;
    while (i < host->count) {
        Sprite *s = &host->sprites[i];
        if (!s->seen && !deferred) {
            remove_at(host, i);
            continue;
        }
        if (!s->seen) s->leaving = true;
        ++i;
    }
    if (host->dirty) {
        host->device->Commit();
        host->dirty = false;
    }
    return host->count;
}

// Number of sprites waiting for zenit_win_sprites_flush.
extern "C" unsigned zenit_win_sprites_leaving(void *raw) {
    auto host = (Host *)raw;
    unsigned n = 0;
    for (unsigned i = 0; i < host->count; ++i) n += host->sprites[i].leaving;
    return n;
}

// Remove the leaving sprites. Returns the number still shown.
extern "C" unsigned zenit_win_sprites_flush(void *raw) {
    auto host = (Host *)raw;
    unsigned i = 0;
    while (i < host->count) {
        if (host->sprites[i].leaving) {
            remove_at(host, i);
            continue;
        }
        ++i;
    }
    if (host->dirty) {
        host->device->Commit();
        host->dirty = false;
    }
    return host->count;
}

extern "C" void zenit_win_sprites_clear(void *raw) {
    auto host = (Host *)raw;
    if (!host) return;
    while (host->count) remove_at(host, host->count - 1);
    host->device->Commit();
    host->dirty = false;
}

// ---------------------------------------------------------------------------
// Test harness: what DWM composes for the window (swap chain and sprites),
// read from the screen. The window must be visible and unobstructed.
extern "C" int zenit_d12_write_png_rgba(const char *path, const uint8_t *rgba, size_t length, uint32_t width,
                                        uint32_t height, uint32_t stride);

namespace {

// Client rectangle `r` (client pixels; empty = whole client) in screen pixels.
bool screen_rect(HWND hwnd, int x, int y, int w, int h, RECT *out) {
    RECT client;
    POINT origin = {0, 0};
    if (!GetClientRect(hwnd, &client) || !ClientToScreen(hwnd, &origin)) return false;
    if (w <= 0 || h <= 0) {
        x = 0;
        y = 0;
        w = client.right;
        h = client.bottom;
    }
    if (x < 0 || y < 0 || x + w > client.right || y + h > client.bottom || w <= 0 || h <= 0) return false;
    *out = RECT{origin.x + x, origin.y + y, origin.x + x + w, origin.y + y + h};
    return true;
}

// Copy screen pixels of `r` into `rgba` rows starting at `row` (stride w * 4).
bool grab(HDC screen, HDC memory, HBITMAP bitmap, const uint8_t *bits, const RECT &r, uint8_t *rgba) {
    const int w = r.right - r.left, h = r.bottom - r.top;
    HGDIOBJ old = SelectObject(memory, bitmap);
    const BOOL ok = BitBlt(memory, 0, 0, w, h, screen, r.left, r.top, SRCCOPY | CAPTUREBLT);
    GdiFlush();
    SelectObject(memory, old);
    if (!ok) return false;
    for (int i = 0; i < w * h; ++i) {
        rgba[i * 4 + 0] = bits[i * 4 + 2];
        rgba[i * 4 + 1] = bits[i * 4 + 1];
        rgba[i * 4 + 2] = bits[i * 4 + 0];
        rgba[i * 4 + 3] = 255;
    }
    return true;
}

struct Grabber {
    HDC screen = nullptr, memory = nullptr;
    HBITMAP bitmap = nullptr;
    uint8_t *bits = nullptr;
    bool init(int w, int h) {
        screen = GetDC(nullptr);
        memory = screen ? CreateCompatibleDC(screen) : nullptr;
        BITMAPINFO info = {};
        info.bmiHeader.biSize = sizeof(info.bmiHeader);
        info.bmiHeader.biWidth = w;
        info.bmiHeader.biHeight = -h;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        void *raw = nullptr;
        bitmap = memory ? CreateDIBSection(memory, &info, DIB_RGB_COLORS, &raw, nullptr, 0) : nullptr;
        bits = (uint8_t *)raw;
        return bitmap != nullptr;
    }
    ~Grabber() {
        if (bitmap) DeleteObject(bitmap);
        if (memory) DeleteDC(memory);
        if (screen) ReleaseDC(nullptr, screen);
    }
};

typedef HRESULT(WINAPI *DwmFlushFn)(void);
DwmFlushFn dwm_flush() {
    static DwmFlushFn fn = [] {
        HMODULE dwm = LoadLibraryExW(L"dwmapi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return dwm ? (DwmFlushFn)(void *)GetProcAddress(dwm, "DwmFlush") : (DwmFlushFn) nullptr;
    }();
    return fn;
}

struct Burst {
    HANDLE thread;
    RECT rect;
    unsigned count;
    char path[1024];
    int result;
};
Burst *g_burst = nullptr;

DWORD WINAPI burst_main(void *raw) {
    auto b = (Burst *)raw;
    const int w = b->rect.right - b->rect.left, h = b->rect.bottom - b->rect.top;
    Grabber g;
    const size_t frame = (size_t)w * h * 4;
    auto rgba = (uint8_t *)malloc(frame * b->count);
    b->result = 2;
    if (rgba && g.init(w, h)) {
        bool ok = true;
        DwmFlushFn flush = dwm_flush();
        for (unsigned i = 0; i < b->count && ok; ++i) {
            // One image per composition.
            if (flush) flush();
            ok = grab(g.screen, g.memory, g.bitmap, g.bits, b->rect, rgba + frame * i);
        }
        if (ok) b->result = zenit_d12_write_png_rgba(b->path, rgba, frame * b->count, (uint32_t)w, (uint32_t)h * b->count, (uint32_t)w * 4) == 0 ? 1 : 2;
    }
    free(rgba);
    return 0;
}

}  // namespace

// 1 = written.
// Diagnostics for the raise: the handle's root window, the foreground window,
// and the root's title (UTF-8, truncated).
extern "C" void zenit_win_window_info(void *hwnd, void **root, void **foreground, char *title, int title_len, int *state) {
    HWND h = (HWND)hwnd;
    HWND r = GetAncestor(h, GA_ROOT);
    *root = r;
    *foreground = GetForegroundWindow();
    // state: visible, iconic, cloaked (DWMWA_CLOAKED), window rect l,t,r,b
    DWORD cloaked = 0;
    DwmGetWindowAttribute(r ? r : h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
    RECT wr = {};
    GetWindowRect(r ? r : h, &wr);
    state[0] = IsWindowVisible(r ? r : h) ? 1 : 0;
    state[1] = IsIconic(r ? r : h) ? 1 : 0;
    state[2] = (int)cloaked;
    state[3] = wr.left; state[4] = wr.top; state[5] = wr.right; state[6] = wr.bottom;
    wchar_t wide[256] = {};
    GetWindowTextW(r ? r : h, wide, 255);
    if (title_len > 0) {
        const int n = WideCharToMultiByte(CP_UTF8, 0, wide, -1, title, title_len, nullptr, nullptr);
        if (n <= 0) title[0] = 0;
        title[title_len - 1] = 0;
    }
}

// Tests: make the window the foreground window (as when the user types in
// it), inside its monitor's work area (moved to its top-left, shrunk to fit),
// so screen captures of its client area see all of it. A background window
// cannot be raised above the foreground one without activating it.
extern "C" int zenit_win_bring_to_front(void *hwnd) {
    HWND h = (HWND)hwnd;
    RECT window;
    MONITORINFO info = {};
    info.cbSize = sizeof(info);
    if (!GetWindowRect(h, &window) || !GetMonitorInfoW(MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST), &info)) return 0;
    const RECT work = info.rcWork;
    const int w = std::min<int>(window.right - window.left, work.right - work.left);
    const int hgt = std::min<int>(window.bottom - window.top, work.bottom - work.top);
    if (!SetWindowPos(h, HWND_TOP, work.left, work.top, w, hgt, 0)) return 0;
    return SetForegroundWindow(h) ? 1 : 0;
}

extern "C" int zenit_win_capture_client_png(void *hwnd, const char *path, int x, int y, int w, int h) {
    RECT r;
    if (!path || !screen_rect((HWND)hwnd, x, y, w, h, &r)) return 0;
    if (DwmFlushFn flush = dwm_flush()) flush();
    const int rw = r.right - r.left, rh = r.bottom - r.top;
    Grabber g;
    auto rgba = (uint8_t *)malloc((size_t)rw * rh * 4);
    int result = 0;
    if (rgba && g.init(rw, rh) && grab(g.screen, g.memory, g.bitmap, g.bits, r, rgba))
        result = zenit_d12_write_png_rgba(path, rgba, (size_t)rw * rh * 4, (uint32_t)rw, (uint32_t)rh, (uint32_t)rw * 4) == 0;
    free(rgba);
    return result;
}

// Capture `count` successive compositions of a client rectangle on a worker
// thread (the UI thread keeps rendering meanwhile) into one PNG, images
// stacked top to bottom. 1 = started.
extern "C" int zenit_win_capture_burst_start(void *hwnd, const char *path, int x, int y, int w, int h, unsigned count) {
    if (g_burst || !path || !count || count > 2048 || strlen(path) >= sizeof(g_burst->path)) return 0;
    auto b = (Burst *)calloc(1, sizeof(Burst));
    if (!b) return 0;
    if (!screen_rect((HWND)hwnd, x, y, w, h, &b->rect)) {
        free(b);
        return 0;
    }
    b->count = count;
    strcpy(b->path, path);
    b->thread = CreateThread(nullptr, 0, burst_main, b, 0, nullptr);
    if (!b->thread) {
        free(b);
        return 0;
    }
    g_burst = b;
    return 1;
}

// 1 = written, 2 = failed, 0 = still running after `timeout_ms` (or none).
extern "C" int zenit_win_capture_burst_wait(unsigned timeout_ms) {
    if (!g_burst) return 0;
    if (WaitForSingleObject(g_burst->thread, timeout_ms) != WAIT_OBJECT_0) return 0;
    CloseHandle(g_burst->thread);
    const int result = g_burst->result;
    free(g_burst);
    g_burst = nullptr;
    return result;
}
