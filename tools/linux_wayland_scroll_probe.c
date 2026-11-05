/* Native scroll contracts; actual desktop delivery is verified separately. */
#include "../native/linux/wayland/window.c"
#include <assert.h>
static void fixture(ZenitWaylandWindow *w) {
    memset(w, 0, sizeof(*w)); w->pointer_focused = 1; w->ordered_input = 1;
    w->seat_version = 8; w->input.x = 42; w->input.y = 37;
    w->surface = (struct wl_surface *)(uintptr_t)1;
}
static void expect_scroll(ZenitWaylandWindow *w, float dx, float dy, uint32_t phase) {
    ZenitWaylandInputEvent e;
    assert(zenit_wayland_peek_input_event(w, &e));
    assert(e.kind == 5 && e.x == 42 && e.y == 37);
    assert(e.dx == dx && e.dy == dy && e.scroll_phase == phase);
    assert(zenit_wayland_pop_input(w, &e));
}
static int fd;
static int get_fd(struct wl_display *d) { (void)d; return fd; }
static int success(struct wl_display *d) { (void)d; return 0; }
static void cancel(struct wl_display *d) { (void)d; }
static struct wl_proxy *capture_bind(struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *type, uint32_t version, uint32_t flags, union wl_argument *args) {
    (void)proxy; (void)flags; assert(opcode == WL_REGISTRY_BIND && args[2].u == version);
    if (type == &wl_compositor_interface) assert(version == 4);
    else { assert(type == &wl_seat_interface); assert(version == 8); }
    return (struct wl_proxy *)(uintptr_t)2;
}
static int add_listener(struct wl_proxy *proxy, void (**listener)(void), void *data) { (void)proxy; (void)listener; (void)data; return 0; }
int zenit_scroll_protocol_contract(void) {
    ZenitWaylandWindow versions; fixture(&versions);
    versions.api.marshal = capture_bind; versions.api.add_listener = add_listener;
    registry_global(&versions, NULL, 1, "wl_compositor", 6);
    registry_global(&versions, NULL, 2, "wl_seat", 11);
    assert(versions.compositor_version == 4 && versions.seat_version == 8);
    ZenitWaylandWindow w; fixture(&w);
    /* Reordered paired representations must not double fractional distance. */
    pointer_axis_value120(&w, NULL, 0, 30);
    pointer_axis(&w, NULL, 0, 0, 640);
    pointer_axis_source(&w, NULL, WL_POINTER_AXIS_SOURCE_WHEEL);
    assert(w.event_count == 0); pointer_frame(&w, NULL);
    expect_scroll(&w, 0, -10, 0); assert(!w.event_count);
    pointer_axis_source(&w, NULL, WL_POINTER_AXIS_SOURCE_WHEEL);
    pointer_axis(&w, NULL, 0, 0, -2560); pointer_axis_value120(&w, NULL, 0, -120);
    pointer_frame(&w, NULL); expect_scroll(&w, 0, 40, 0);
    w.seat_version = 5;
    pointer_axis_discrete(&w, NULL, 1, 2); pointer_axis(&w, NULL, 0, 1, 5120);
    pointer_axis_source(&w, NULL, WL_POINTER_AXIS_SOURCE_WHEEL_TILT);
    pointer_frame(&w, NULL); expect_scroll(&w, -80, 0, 0);
    /* Finger samples preserve pixel fractions and pair both axes. */
    pointer_axis(&w, NULL, 0, 0, 320); pointer_axis(&w, NULL, 0, 1, -128);
    pointer_axis_source(&w, NULL, WL_POINTER_AXIS_SOURCE_FINGER);
    pointer_frame(&w, NULL); expect_scroll(&w, .5f, -1.25f, 2);
    pointer_axis_stop(&w, NULL, 0, 1); pointer_frame(&w, NULL); assert(!w.event_count);
    pointer_axis(&w, NULL, 0, 0, 64); pointer_axis_source(&w, NULL, WL_POINTER_AXIS_SOURCE_FINGER);
    pointer_frame(&w, NULL); expect_scroll(&w, 0, -.25f, 3);
    pointer_axis_stop(&w, NULL, 0, 0); pointer_frame(&w, NULL); expect_scroll(&w, 0, 0, 4);
    pointer_frame(&w, NULL); assert(!w.event_count);
    pointer_axis(&w, NULL, 0, 0, 256); pointer_axis_source(&w, NULL, WL_POINTER_AXIS_SOURCE_FINGER);
    pointer_frame(&w, NULL); expect_scroll(&w, 0, -1, 2);
    pointer_leave(&w, NULL, 0, (struct wl_surface *)(uintptr_t)2); assert(w.pointer_focused);
    pointer_leave(&w, NULL, 0, w.surface); expect_scroll(&w, 0, 0, 5);
    pointer_axis(&w, NULL, 0, 0, 2560); pointer_frame(&w, NULL); assert(!w.event_count);
    fixture(&w); w.seat_version = 1;
    pointer_axis(&w, NULL, 0, 0, 64); expect_scroll(&w, 0, -.25f, 0);
    w.ordered_input = 0; pointer_axis(&w, NULL, 0, 1, -128);
    ZenitWaylandScrollEvent legacy; assert(zenit_wayland_pop_scroll(&w, &legacy)); assert(legacy.dx == .5f);
    fixture(&w); pointer_axis(&w, NULL, 0, 0, 256); pointer_frame(&w, NULL);
    /* An already queued sample must bypass the 200ms idle sleep. */
    struct ClipboardState clip = {0}; clip.receive_fd = -1;
    for (int i = 0; i < 8; ++i) clip.sends[i].fd = -1;
    w.clipboard = &clip; w.display = (struct wl_display *)(uintptr_t)1;
    w.api.get_fd = get_fd; w.api.prepare_read = success; w.api.flush = success;
    w.api.dispatch_pending = success; w.api.cancel_read = cancel;
    int pipes[2]; assert(pipe(pipes) == 0); fd = pipes[0];
    int64_t start = keyboard_now(); assert(zenit_wayland_poll(&w, 200) == 1);
    assert(keyboard_now() - start < 50000000); close(pipes[0]); close(pipes[1]);
    expect_scroll(&w, 0, -1, 0);
    puts("WAYLAND_SCROLL_CONTRACT PASS direction units fractional frames phases focus pending-input");
    return 0;
}
