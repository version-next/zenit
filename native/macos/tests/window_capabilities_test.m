// Window capability opt-outs against the real bridge: maximize/zoom refusal,
// state-restoration exclusion, and the secure restorable state declaration.
#import "../window_bridge.m"
#include "no_render_copy.inc"
// Standalone empty accessibility client; no dependency on other local tests.
uint64_t zenit_a11y_focused(uint32_t window_id) { return UINT32_MAX; }
int zenit_a11y_value(uint32_t window_id, uint64_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_text_selection(uint32_t window_id, uint64_t handle, uint32_t *start, uint32_t *end, uint32_t *caret) { return 0; }
int zenit_a11y_text_range_at_point(uint32_t window_id, uint64_t handle, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8) { return 0; }
int zenit_a11y_root_count(uint32_t window_id) { return 0; }
uint64_t zenit_a11y_root_at(uint32_t window_id, int idx) { return UINT32_MAX; }
int zenit_a11y_exists(uint32_t window_id, uint64_t handle) { return 0; }
int zenit_a11y_children_count(uint32_t window_id, uint64_t parent_raw) { return 0; }
uint64_t zenit_a11y_children_at(uint32_t window_id, uint64_t parent_raw, int idx) { return 0; }
int zenit_a11y_role(uint32_t window_id, uint64_t handle) { return 0; }
uint32_t zenit_a11y_state(uint32_t window_id, uint64_t handle) { return 0; }
int zenit_a11y_label(uint32_t window_id, uint64_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_description(uint32_t window_id, uint64_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_numeric_value(uint32_t window_id, uint64_t handle, float *now, float *min, float *max) { return 0; }
int zenit_a11y_frame(uint32_t window_id, uint64_t handle, float *x, float *y, float *width, float *height) { return 0; }
uint8_t zenit_a11y_actions(uint32_t window_id, uint64_t handle) { return 0; }
int zenit_a11y_perform_action(uint32_t window_id, uint64_t handle, uint8_t action) { return 0; }
uint8_t zenit_a11y_text_capabilities(uint32_t window_id, uint64_t handle) { return 0; }
int zenit_a11y_set_text_selection(uint32_t window_id, uint64_t handle, uint32_t start_utf8, uint32_t end_utf8) { return 0; }
int zenit_a11y_set_focus(uint32_t window_id, uint64_t handle, int focused) { return 0; }
int zenit_a11y_set_text_value(uint32_t window_id, uint64_t handle, const char *bytes, int len) { return 0; }
int zenit_a11y_text_visible_range(uint32_t window_id, uint64_t handle, uint32_t *start, uint32_t *end) { return 0; }
int zenit_a11y_text_frame(uint32_t window_id, uint64_t handle, uint32_t start_utf8, uint32_t end_utf8, float *x, float *y, float *width, float *height) { return 0; }
int zenit_a11y_set_numeric_value(uint32_t window_id, uint64_t handle, float value) { return 0; }
uint8_t zenit_a11y_numeric_capabilities(uint32_t window_id, uint64_t handle) { return 0; }
uint64_t zenit_a11y_parent(uint32_t window_id, uint64_t handle) { return UINT32_MAX; }
uint64_t zenit_a11y_active_descendant(uint32_t window_id, uint64_t handle) { return UINT32_MAX; }
uint64_t zenit_a11y_hit_test(uint32_t window_id, float x, float y) { return UINT32_MAX; }
uint8_t zenit_a11y_orientation(uint32_t window_id, uint64_t handle) { return 0; }
uint8_t zenit_a11y_sort_direction(uint32_t window_id, uint64_t handle) { return 0; }
uint16_t zenit_a11y_level(uint32_t window_id, uint64_t handle) { return 0; }
int zenit_a11y_row_index_range(uint32_t window_id, uint64_t handle, uint32_t *index, uint32_t *span) { return 0; }
int zenit_a11y_column_index_range(uint32_t window_id, uint64_t handle, uint32_t *index, uint32_t *span) { return 0; }
int zenit_a11y_placeholder(uint32_t window_id, uint64_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_identifier(uint32_t window_id, uint64_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_collection_info(uint32_t window_id, uint64_t handle, uint32_t *count, uint32_t *first_visible, uint32_t *visible_len) { return 0; }
uint64_t zenit_a11y_collection_row_at(uint32_t window_id, uint64_t handle, uint32_t index) { return UINT32_MAX; }
int zenit_a11y_commit_scroll_to_visible(uint32_t window_id, uint64_t handle) { return 0; }
int zenit_ax_in_frame_service(void) { return 0; }
uint32_t zenit_a11y_set_size(uint32_t window_id, uint64_t handle) { return 0; }
void zenit_a11y_preferences_changed(void) {}

uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w, uint64_t s, char *b, int n) { return 0; }
int zenit_text_input_selection(uint32_t w, uint32_t *s, uint32_t *e, uint32_t *c) { return 0; }
int zenit_text_input_frame(uint32_t w, uint32_t s, uint32_t e, float *x, float *y, float *a, float *b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w, float x, float y, uint32_t *s, uint32_t *e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w, uint64_t n) { return n; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w, uint64_t n) { return n; }

#include <stdio.h>

static int checks = 0, failures = 0;
#define CHECK(condition) do { checks++; if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); failures++; \
} } while (0)

// Capability bit 3 of chrome.Capabilities (packed u8): maximize.
#define CAP_MAXIMIZE 8

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        void *ptr = macos_create_window(320, 240, "caps");
        CHECK(ptr != NULL);
        WindowWrapper *w = (__bridge WindowWrapper *)ptr;
        NSWindow *win = w.window;
        CHECK(win != nil);
        id<NSWindowDelegate> del = win.delegate;

        // Defaults match an out-of-box NSWindow: zoomable and restorable.
        ZenitChromeState st;
        macos_chrome_state(ptr, &st);
        CHECK((st.capabilities & CAP_MAXIMIZE) != 0);
        CHECK([win standardWindowButton:NSWindowZoomButton].enabled);
        CHECK([del windowShouldZoom:win toFrame:win.frame]);
        CHECK(win.restorable);

        // Opting out blocks every zoom entry point and drops the capability.
        CHECK(macos_chrome_maximizable(ptr, 0) == 1);
        CHECK(![win standardWindowButton:NSWindowZoomButton].enabled);
        CHECK(![del windowShouldZoom:win toFrame:win.frame]);
        macos_chrome_state(ptr, &st);
        CHECK((st.capabilities & CAP_MAXIMIZE) == 0);

        // The re-assert in macos_chrome_configure must restore the opt-out;
        // force the precondition so deleting the re-assert actually goes red.
        [win standardWindowButton:NSWindowZoomButton].enabled = YES;
        CHECK(macos_chrome_configure(ptr, 1, 1, 32.0f) == 1);
        CHECK(![win standardWindowButton:NSWindowZoomButton].enabled);
        macos_chrome_state(ptr, &st);
        CHECK((st.capabilities & CAP_MAXIMIZE) == 0);

        CHECK(macos_chrome_maximizable(ptr, 1) == 1);
        CHECK([win standardWindowButton:NSWindowZoomButton].enabled);
        CHECK([del windowShouldZoom:win toFrame:win.frame]);
        macos_chrome_state(ptr, &st);
        CHECK((st.capabilities & CAP_MAXIMIZE) != 0);

        CHECK(macos_chrome_restorable(ptr, 0) == 1);
        CHECK(!win.restorable);
        CHECK(macos_chrome_restorable(ptr, 1) == 1);
        CHECK(win.restorable);

        // Secure restorable state declaration (macOS 12+ API; automatic when
        // linked on the macOS 14 SDK).
        ZenitAppDelegate *delegate = [ZenitAppDelegate new];
        CHECK([delegate applicationSupportsSecureRestorableState:NSApp]);

        macos_destroy_window(ptr);
        printf("Native window capabilities: %d checks, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
}
