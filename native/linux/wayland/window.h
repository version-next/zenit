#ifndef ZENIT_WAYLAND_WINDOW_H
#define ZENIT_WAYLAND_WINDOW_H
#include <stdint.h>
#include <stddef.h>
typedef struct ZenitWaylandWindow ZenitWaylandWindow;
typedef struct {
    void *display;
    void *surface;
    uint32_t logical_width;
    uint32_t logical_height;
    uint32_t pixel_width;
    uint32_t pixel_height;
    float scale;
} ZenitWaylandSurface;
typedef struct { float x, y; uint32_t buttons, focused; } ZenitWaylandInputState;
typedef struct { float x, y; uint32_t button, pressed, cancelled; } ZenitWaylandButtonEvent;
typedef struct { float x, y, dx, dy; } ZenitWaylandScrollEvent;
/* kind: 1 button, 2 key, 3 text, 4 motion, 5 scroll, 6 preedit, 7 commit, 8 delete surrounding,
 * 9 pointer left the surface. */
typedef struct {
    uint32_t kind, keycode, modifiers, button, pressed, cancelled, text_length;
    float x, y, dx, dy;
    unsigned char text[64];
    /* Borrowed until pop; non-NULL for owned IME strings. */
    unsigned char *owned_text;
    int32_t cursor_begin, cursor_end;
    uint32_t delete_before, delete_after;
    uint32_t scroll_phase; /* SDK ScrollPhase: none=0, began=2, changed=3, ended=4, cancelled=5 */
} ZenitWaylandInputEvent;
typedef struct { uint32_t desired_shape, applied_shape, apply_count, pointer_focused, compositor_theme, theme_scale; } ZenitWaylandCursorState;
int zenit_wayland_cursor_available(ZenitWaylandWindow *);
int zenit_wayland_set_cursor(ZenitWaylandWindow *, uint32_t shape);
int zenit_wayland_cursor_state(ZenitWaylandWindow *, ZenitWaylandCursorState *);
void zenit_wayland_enable_ordered_input(ZenitWaylandWindow *);
int zenit_wayland_peek_input(ZenitWaylandWindow *);
int zenit_wayland_peek_input_event(ZenitWaylandWindow *, ZenitWaylandInputEvent *);
int zenit_wayland_pop_input(ZenitWaylandWindow *, ZenitWaylandInputEvent *);
int zenit_wayland_input_state(ZenitWaylandWindow *, ZenitWaylandInputState *);
int zenit_wayland_pop_button(ZenitWaylandWindow *, ZenitWaylandButtonEvent *);
int zenit_wayland_pop_scroll(ZenitWaylandWindow *, ZenitWaylandScrollEvent *);

/* Independent of Vulkan. Owns display, native surface and xdg-shell objects. */
ZenitWaylandWindow *zenit_wayland_create(const char *title, uint32_t width, uint32_t height);
void zenit_wayland_destroy(ZenitWaylandWindow *window);
void zenit_wayland_set_title(ZenitWaylandWindow *window, const char *title);
/* Clipboard negative results: -1 failure, -2 capacity, -3 unavailable,
 * -4 allocation, -5 timeout, -6 invalid focus/serial/reentry, -7 wrong thread. */
int zenit_wayland_clipboard_available(ZenitWaylandWindow *window);
int zenit_wayland_clipboard_set_text(ZenitWaylandWindow *window, const unsigned char *text, size_t length);
int zenit_wayland_clipboard_get_text_len(ZenitWaylandWindow *window);
int zenit_wayland_clipboard_get_text(ZenitWaylandWindow *window, unsigned char *buffer, size_t capacity);
int zenit_wayland_clipboard_set_png(ZenitWaylandWindow *window, const unsigned char *bytes, size_t length);
unsigned zenit_wayland_clipboard_probe(ZenitWaylandWindow *window);
int zenit_wayland_clipboard_write_ready(ZenitWaylandWindow *window);
int zenit_wayland_clipboard_get_png_len(ZenitWaylandWindow *window);
int zenit_wayland_clipboard_get_png(ZenitWaylandWindow *window, unsigned char *buffer, size_t capacity);
typedef struct { unsigned char *rgba; uint32_t width, height; } ZenitClipboardPng;
int zenit_wayland_decode_png(const unsigned char *bytes, size_t length, ZenitClipboardPng *out);
void zenit_wayland_free_png(ZenitClipboardPng *image);
int zenit_wayland_ime_available(ZenitWaylandWindow *window);
int zenit_wayland_ime_set_enabled(ZenitWaylandWindow *window, int enabled);
int zenit_wayland_ime_set_secure(ZenitWaylandWindow *window, int secure);
int zenit_wayland_ime_discard(ZenitWaylandWindow *window);
int zenit_wayland_ime_set_cursor_rect(ZenitWaylandWindow *window, int32_t x, int32_t y, int32_t width, int32_t height);
int zenit_wayland_ime_set_surrounding(ZenitWaylandWindow *window, const char *text, size_t length, uint32_t cursor, uint32_t anchor);
int zenit_wayland_poll(ZenitWaylandWindow *window, int timeout_ms);
int zenit_wayland_metrics(ZenitWaylandWindow *window, ZenitWaylandSurface *out);
int zenit_wayland_request_frame(ZenitWaylandWindow *window);
int zenit_wayland_request_frame_clock(ZenitWaylandWindow *window);
uint64_t zenit_wayland_frame_tick(const ZenitWaylandWindow *window);
float zenit_wayland_refresh_rate(const ZenitWaylandWindow *window);
void zenit_wayland_cancel_frame(ZenitWaylandWindow *window);
int zenit_wayland_set_maximized(ZenitWaylandWindow *window, int maximized);
int zenit_wayland_set_minimized(ZenitWaylandWindow *window);
int zenit_wayland_close(ZenitWaylandWindow *window);
int zenit_wayland_decoration_height(ZenitWaylandWindow *window);
uint32_t zenit_wayland_window_state(ZenitWaylandWindow *window);
int zenit_wayland_has_decorations(ZenitWaylandWindow *window);
int zenit_wayland_set_size(ZenitWaylandWindow *window, uint32_t width, uint32_t height);
#endif
