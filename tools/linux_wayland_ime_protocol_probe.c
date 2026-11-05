/* Native callback/state contracts. Marshal capture verifies request ordering;
 * this test does not stand in for a real desktop IME interoperability gate. */
#include "../native/linux/wayland/window.c"
#include <assert.h>
static uint32_t ops[128];
static size_t op_count;
static uint32_t content_hint, content_purpose;
static struct wl_proxy *capture(struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *type, uint32_t version, uint32_t flags, union wl_argument *args) {
    (void)type; (void)flags; assert(version == 1);
    if (opcode == ZWP_TEXT_INPUT_V3_SET_CONTENT_TYPE) { content_hint = args[0].u; content_purpose = args[1].u; }
    assert(op_count < 128); ops[op_count++] = opcode; return proxy;
}
static void fixture(ZenitWaylandWindow *w, struct TextInputState *c, struct ClipboardState *clip) {
    memset(w, 0, sizeof(*w)); memset(c, 0, sizeof(*c)); memset(clip, 0, sizeof(*clip));
    w->text_input = c; w->clipboard = clip; clip->thread = pthread_self();
    w->surface = (struct wl_surface *)(uintptr_t)1;
    c->proxy = (struct zwp_text_input_v3 *)(uintptr_t)2;
    w->api.marshal = capture; op_count = 0;
}
static void consume(ZenitWaylandWindow *w, uint32_t kind, const char *text) {
    ZenitWaylandInputEvent event;
    assert(zenit_wayland_peek_input_event(w, &event) && event.kind == kind);
    if (text) {
        assert(event.text_length == strlen(text));
        assert(!event.text_length || (event.owned_text && memcmp(event.owned_text, text, event.text_length) == 0));
    }
    assert(zenit_wayland_pop_input(w, &event)); assert(!event.owned_text);
}
static void batches(void) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    assert(zenit_wayland_ime_set_enabled(&w, 1) == 0 && op_count == 0);
    ime_enter(&w, c.proxy, (struct wl_surface *)(uintptr_t)3); assert(!c.entered);
    ime_enter(&w, c.proxy, w.surface); assert(c.entered && c.serial == 1);
    assert(ops[0] == ZWP_TEXT_INPUT_V3_ENABLE && ops[1] == ZWP_TEXT_INPUT_V3_SET_CONTENT_TYPE && ops[2] == ZWP_TEXT_INPUT_V3_COMMIT);
    char preedit[601]; for (int i = 0; i < 200; ++i) memcpy(preedit + i * 3, "候", 3); preedit[600] = 0;
    char original[601]; memcpy(original, preedit, sizeof(preedit));
    enqueue_input(&w, (ZenitWaylandInputEvent){.kind = 2, .keycode = 30});
    ime_preedit(&w, c.proxy, preedit, 300, 600); memset(preedit, 'x', 600);
    assert(w.event_count == 1); ime_done(&w, c.proxy, c.serial);
    assert(w.event_count == 2); consume(&w, 2, NULL);
    ZenitWaylandInputEvent event; assert(zenit_wayland_peek_input_event(&w, &event));
    assert(event.cursor_begin == 300 && event.cursor_end == 600); consume(&w, 6, original);
    /* Replacing a live composition must not publish an intermediate empty
     * state: refreshing the native caret on each UI event would oscillate. */
    size_t requests = op_count;
    for (int i = 0; i < 32; ++i) {
        ime_preedit(&w, c.proxy, "候選", 3, 6); ime_done(&w, c.proxy, c.serial);
        assert(w.event_count == 1 && c.active && op_count == requests);
        assert(zenit_wayland_peek_input_event(&w, &event) && event.cursor_begin == 3 && event.cursor_end == 6);
        consume(&w, 6, "候選");
    }
    ime_delete(&w, c.proxy, 3, 6); ime_commit(&w, c.proxy, "你好"); ime_preedit(&w, c.proxy, "次", -1, -1);
    assert(w.event_count == 0); ime_done(&w, c.proxy, c.serial);
    assert(w.event_count == 4); consume(&w, 6, "");
    assert(zenit_wayland_peek_input_event(&w, &event) && event.delete_before == 3 && event.delete_after == 6);
    consume(&w, 8, NULL); consume(&w, 7, "你好");
    assert(zenit_wayland_peek_input_event(&w, &event) && event.cursor_begin == -1 && event.cursor_end == -1); consume(&w, 6, "次");
    ime_leave(&w, c.proxy, w.surface); assert(!c.entered); consume(&w, 6, "");
    assert(!w.event_count && !c.preedit && !c.commit && !w.closed);
}
static void idle_ack_and_native_cancel(void) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    assert(zenit_wayland_ime_set_enabled(&w, 1) == 0); ime_enter(&w, c.proxy, w.surface);
    for (int i = 0; i < 32; ++i) { ime_done(&w, c.proxy, c.serial); assert(!w.event_count && !c.active && !w.closed); }
    ime_preedit(&w, c.proxy, "候選", 3, 6); ime_done(&w, c.proxy, c.serial);
    consume(&w, 6, "候選"); assert(c.active);
    /* The protocol's absent preedit cancels a live native composition once. */
    ime_done(&w, c.proxy, c.serial); consume(&w, 6, ""); assert(!c.active && !w.event_count);
    ime_done(&w, c.proxy, c.serial); assert(!w.event_count);
    /* Explicit empty preedit remains an event, even when already idle. */
    ime_preedit(&w, c.proxy, "", 0, 0); ime_done(&w, c.proxy, c.serial); consume(&w, 6, "");
}
static void serial_and_clients(void) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    assert(zenit_wayland_ime_set_enabled(&w, 1) == 0); ime_enter(&w, c.proxy, w.surface);
    assert(zenit_wayland_ime_set_surrounding(&w, "a你好b", 8, 7, 1) == 0 && c.serial == 2);
    assert(zenit_wayland_ime_set_surrounding(&w, "a你好b", 8, 2, 1) == -6);
    ime_commit(&w, c.proxy, "x"); size_t count = op_count; ime_done(&w, c.proxy, 1);
    assert(!c.updating && op_count == count); consume(&w, 7, "x"); consume(&w, 6, "");
    assert(zenit_wayland_ime_set_cursor_rect(&w, 1, 2, 3, 4) == 0 && c.dirty && op_count == count);
    ime_done(&w, c.proxy, 2); assert(!w.event_count); assert(c.updating && !c.dirty && c.serial == 3);
    assert(ops[op_count - 2] == ZWP_TEXT_INPUT_V3_SET_CURSOR_RECTANGLE && ops[op_count - 1] == ZWP_TEXT_INPUT_V3_COMMIT);
    count = op_count; assert(zenit_wayland_ime_set_cursor_rect(&w, 1, 2, 3, 4) == 0 && op_count == count);
    assert(zenit_wayland_ime_set_cursor_rect(&w, 1, 2, -1, 4) == -6);
    assert(zenit_wayland_ime_discard(&w) == 0 && c.enabled && !c.has_surrounding && !c.has_rect && !c.surrounding);
    assert(c.serial == 5 && ops[count] == ZWP_TEXT_INPUT_V3_DISABLE && ops[count + 1] == ZWP_TEXT_INPUT_V3_COMMIT && ops[count + 2] == ZWP_TEXT_INPUT_V3_ENABLE);
    assert(zenit_wayland_ime_set_enabled(&w, 0) == 0 && !c.enabled && c.serial == 6);
    count = op_count; assert(zenit_wayland_ime_set_enabled(&w, 0) == 0 && op_count == count);
    ime_preedit(&w, c.proxy, "ignored", 0, 0); ime_done(&w, c.proxy, 6); assert(!w.event_count);
}
static void session_isolation(void) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    assert(zenit_wayland_ime_set_enabled(&w, 1) == 0); ime_enter(&w, c.proxy, w.surface);
    w.event_head = 126; /* exercise compaction across the ring boundary */
    enqueue_input(&w, (ZenitWaylandInputEvent){.kind = 2, .keycode = 30});
    ime_commit(&w, c.proxy, "old client"); ime_preedit(&w, c.proxy, "old preedit", 0, 11); ime_done(&w, c.proxy, c.serial);
    enqueue_input(&w, (ZenitWaylandInputEvent){.kind = 4, .x = 27});
    uint32_t previous = c.serial;
    assert(zenit_wayland_ime_discard(&w) == 0 && w.event_count == 3);
    consume(&w, 2, NULL);
    ZenitWaylandInputEvent event; assert(zenit_wayland_peek_input_event(&w, &event) && event.x == 27);
    consume(&w, 4, NULL); consume(&w, 6, "");
    ime_commit(&w, c.proxy, "in flight old client"); ime_done(&w, c.proxy, previous);
    assert(!w.event_count && !c.commit && !c.preedit);
    ime_commit(&w, c.proxy, "new client"); ime_done(&w, c.proxy, c.serial);
    consume(&w, 7, "new client"); consume(&w, 6, "");
    c.serial = UINT32_MAX - 1;
    assert(zenit_wayland_ime_discard(&w) == 0 && c.serial == 0 && c.session_serial == 0);
    ime_commit(&w, c.proxy, "old wrap"); ime_done(&w, c.proxy, UINT32_MAX); assert(!w.event_count);
    ime_commit(&w, c.proxy, "new wrap"); ime_done(&w, c.proxy, 0);
    consume(&w, 7, "new wrap"); consume(&w, 6, "");
}
static void utf8_validation(void) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    const char *invalid[] = {"\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe4\xbd", "\x80", "\xf5\x80\x80\x80", "\xe0\x80\xaf"};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i)
        assert(zenit_wayland_ime_set_surrounding(&w, invalid[i], strlen(invalid[i]), 0, 0) == -6);
    assert(zenit_wayland_ime_set_surrounding(&w, "A你好😀", 11, 11, 1) == 0); free(c.surrounding); c.surrounding = NULL;
    char limit[4001]; memset(limit, 'x', sizeof(limit));
    assert(zenit_wayland_ime_set_surrounding(&w, limit, 4000, 4000, 0) == 0); free(c.surrounding); c.surrounding = NULL;
    assert(zenit_wayland_ime_set_surrounding(&w, limit, 4001, 0, 0) == -6);
    assert(zenit_wayland_ime_set_surrounding(&w, "a\0b", 3, 0, 0) == -6);
    c.entered = c.enabled = 1; ime_commit(&w, c.proxy, invalid[0]); assert(w.closed && !c.commit);
}
static void secure_purpose(void) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    c.enabled = c.entered = c.updating = 1;
    assert(zenit_wayland_ime_set_secure(&w, 1) == 0);
    assert(content_purpose == ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PASSWORD);
    assert(c.has_surrounding && !*c.surrounding);
    assert(zenit_wayland_ime_set_surrounding(&w, "secret", 6, 6, 0) == -6 && !*c.surrounding);
    assert(content_hint == (ZWP_TEXT_INPUT_V3_CONTENT_HINT_HIDDEN_TEXT | ZWP_TEXT_INPUT_V3_CONTENT_HINT_SENSITIVE_DATA));
    size_t count = op_count;
    assert(zenit_wayland_ime_set_secure(&w, 1) == 0 && op_count == count);
    assert(zenit_wayland_ime_set_surrounding(&w, "", 0, 0, 0) == 0); count = op_count;
    assert(zenit_wayland_ime_set_surrounding(&w, "", 0, 0, 0) == 0 && op_count == count);
    assert(zenit_wayland_ime_set_secure(&w, 0) == 0 && content_purpose == ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
    assert(zenit_wayland_ime_set_surrounding(&w, "A你好", 7, 7, 1) == 0);
    assert(!strcmp(c.surrounding, "A你好") && c.cursor == 7 && c.anchor == 1);
    assert(zenit_wayland_ime_set_secure(&w, 1) == 0);
    assert(!*c.surrounding && c.cursor == 0 && c.anchor == 0);
    free(c.surrounding);
}
static void invalid_and_overflow(void) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    c.entered = c.enabled = 1;
    ime_preedit(&w, c.proxy, "候", 1, 3); assert(w.closed && !c.preedit && !w.event_count);
    fixture(&w, &c, &clip); c.entered = c.enabled = c.active = 1;
    for (int i = 0; i < 126; ++i) assert(enqueue_input(&w, (ZenitWaylandInputEvent){.kind = 2}));
    ime_commit(&w, c.proxy, "你好"); ime_delete(&w, c.proxy, 1, 0); ime_preedit(&w, c.proxy, "next", 0, 4);
    ime_done(&w, c.proxy, 0); assert(w.closed && w.event_count == 126 && !c.preedit && !c.commit);
}
int zenit_ime_wrapper_contract(int (*set_surrounding)(void *, int)) {
    ZenitWaylandWindow w; struct TextInputState c; struct ClipboardState clip; fixture(&w, &c, &clip);
    c.enabled = c.entered = c.updating = 1;
    assert(set_surrounding(&w, 0) == 0 && !strcmp(c.surrounding, "A你好"));
    assert(set_surrounding(&w, 1) == 0 && c.secure && !*c.surrounding && c.cursor == 0 && c.anchor == 0);
    assert(content_purpose == ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PASSWORD);
    assert(set_surrounding(&w, 0) == 0 && !c.secure && !strcmp(c.surrounding, "A你好"));
    assert(c.cursor == 7 && c.anchor == 1 && content_purpose == ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
    free(c.surrounding);
    puts("IME_WRAPPER PASS: normal/password/normal purpose transition, no password bytes exposed");
    return 0;
}
int zenit_ime_protocol_contract(void) {
    batches(); idle_ack_and_native_cancel(); serial_and_clients(); session_isolation(); utf8_validation(); secure_purpose(); invalid_and_overflow();
    puts("IME_PROTOCOL PASS: owned 600-byte preedit, done batching/order, selection/hidden cursor, stale serial delivery/deferred state, strict UTF-8, wrapped FIFO/session isolation, focus, enable/disable/discard, atomic overflow");
    return 0;
}
