// Exercise the actual bridge against a private pasteboard. Swizzling is local
// to this test process; the user's general pasteboard is never read or changed.
#import "../window_bridge.m"
// Standalone empty accessibility client; no dependency on other local tests.
uint32_t zenit_a11y_focused(uint32_t window_id) { return UINT32_MAX; }
int zenit_a11y_value(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_text_selection(uint32_t window_id, uint32_t handle, uint32_t *start, uint32_t *end, uint32_t *caret) { return 0; }
int zenit_a11y_text_range_at_point(uint32_t window_id, uint32_t handle, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8) { return 0; }
int zenit_a11y_root_count(uint32_t window_id) { return 0; }
uint32_t zenit_a11y_root_at(uint32_t window_id, int idx) { return UINT32_MAX; }
int zenit_a11y_exists(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_children_count(uint32_t window_id, uint32_t parent_raw) { return 0; }
uint32_t zenit_a11y_children_at(uint32_t window_id, uint32_t parent_raw, int idx) { return 0; }
int zenit_a11y_role(uint32_t window_id, uint32_t handle) { return 0; }
uint32_t zenit_a11y_state(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_label(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_description(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_numeric_value(uint32_t window_id, uint32_t handle, float *now, float *min, float *max) { return 0; }
int zenit_a11y_frame(uint32_t window_id, uint32_t handle, float *x, float *y, float *width, float *height) { return 0; }
uint8_t zenit_a11y_actions(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_perform_action(uint32_t window_id, uint32_t handle, uint8_t action) { return 0; }
uint8_t zenit_a11y_text_capabilities(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_set_text_selection(uint32_t window_id, uint32_t handle, uint32_t start_utf8, uint32_t end_utf8) { return 0; }
int zenit_a11y_set_focus(uint32_t window_id, uint32_t handle, int focused) { return 0; }
int zenit_a11y_set_text_value(uint32_t window_id, uint32_t handle, const char *bytes, int len) { return 0; }
int zenit_a11y_text_visible_range(uint32_t window_id, uint32_t handle, uint32_t *start, uint32_t *end) { return 0; }
int zenit_a11y_text_frame(uint32_t window_id, uint32_t handle, uint32_t start_utf8, uint32_t end_utf8, float *x, float *y, float *width, float *height) { return 0; }
int zenit_a11y_set_numeric_value(uint32_t window_id, uint32_t handle, float value) { return 0; }
uint8_t zenit_a11y_numeric_capabilities(uint32_t window_id, uint32_t handle) { return 0; }
uint32_t zenit_a11y_parent(uint32_t window_id, uint32_t handle) { return UINT32_MAX; }
uint32_t zenit_a11y_active_descendant(uint32_t window_id, uint32_t handle) { return UINT32_MAX; }
uint32_t zenit_a11y_hit_test(uint32_t window_id, float x, float y) { return UINT32_MAX; }
uint8_t zenit_a11y_orientation(uint32_t window_id, uint32_t handle) { return 0; }
uint8_t zenit_a11y_sort_direction(uint32_t window_id, uint32_t handle) { return 0; }
uint16_t zenit_a11y_level(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_row_index_range(uint32_t window_id, uint32_t handle, uint32_t *index, uint32_t *span) { return 0; }
int zenit_a11y_column_index_range(uint32_t window_id, uint32_t handle, uint32_t *index, uint32_t *span) { return 0; }
int zenit_a11y_placeholder(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_identifier(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }

#import <objc/runtime.h>
#include <stdio.h>

uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w, uint64_t s, char *b, int n) { return 0; }
int zenit_text_input_selection(uint32_t w, uint32_t *s, uint32_t *e, uint32_t *c) { return 0; }
int zenit_text_input_frame(uint32_t w, uint32_t s, uint32_t e, float *x, float *y, float *a, float *b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w, float x, float y, uint32_t *s, uint32_t *e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w, uint64_t n) { return n; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w, uint64_t n) { return n; }

static NSPasteboard *privateClipboard;
static id testPasteboard(id receiver, SEL selector) { return privateClipboard; }
static int checks = 0, failures = 0;
#define CHECK(condition) do { checks++; if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); failures++; \
} } while (0)

static void verifyRead(BOOL html, NSString *type) {
    int (*readLen)(void) = html ? macos_clipboard_get_html_len : macos_clipboard_get_text_len;
    int (*readBytes)(char *, int) = html ? macos_clipboard_get_html : macos_clipboard_get_text;
    [privateClipboard clearContents];
    char buffer[64];
    memset(buffer, 'Z', sizeof(buffer));
    CHECK(readLen() == 0);
    CHECK(readBytes(buffer, sizeof(buffer)) == 0);
    CHECK(buffer[0] == 'Z');
    [privateClipboard setString:@"a" forType:type];
    CHECK(readLen() == 1);
    // Another clipboard owner changes the content between query and read.
    [privateClipboard clearContents];
    [privateClipboard setString:@"中文🙂" forType:type];
    CHECK(readBytes(buffer, 2) == -2);
    CHECK(buffer[0] == 'Z' && buffer[1] == 'Z');
    NSData *data = [@"中文🙂" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(readLen() == (int)data.length);
    CHECK(readBytes(buffer, (int)data.length) == -2);
    CHECK(buffer[0] == 'Z');
    CHECK(readBytes(buffer, (int)data.length + 1) == (int)data.length);
    CHECK(memcmp(buffer, data.bytes, data.length) == 0);
    CHECK(buffer[data.length] == 0);
    CHECK(readBytes(NULL, 20) == -2);
    CHECK(readBytes(buffer, 0) == -2);
    // NSString may contain embedded NULs; byte lengths must not use strlen.
    const char embedded[] = { 'a', 0, 'b' };
    NSString *withNul = [[NSString alloc] initWithBytes:embedded length:3 encoding:NSUTF8StringEncoding];
    [privateClipboard clearContents];
    [privateClipboard setString:withNul forType:type];
    CHECK(readLen() == 3);
    CHECK(readBytes(buffer, sizeof(buffer)) == 3);
    CHECK(memcmp(buffer, embedded, 3) == 0);
}

// Rich writes validate both payloads before touching the pasteboard and
// report the same 1 / 0 / -1 contract as plain-text writes.
static void verifyRichWrite(void) {
    const char bad[] = { 'a', (char)0xFF };
    [privateClipboard clearContents];
    [privateClipboard setString:@"KEEP" forType:NSPasteboardTypeString];
    CHECK(macos_clipboard_set_rich_text(bad, 2, NULL, 0) == -1);
    CHECK([[privateClipboard stringForType:NSPasteboardTypeString] isEqualToString:@"KEEP"]);
    CHECK(macos_clipboard_set_rich_text("hi", 2, bad, 2) == -1);
    CHECK([[privateClipboard stringForType:NSPasteboardTypeString] isEqualToString:@"KEEP"]);
    CHECK(macos_clipboard_set_rich_text("hi", 2, "<b>hi</b>", 9) == 1);
    CHECK([[privateClipboard stringForType:NSPasteboardTypeString] isEqualToString:@"hi"]);
    CHECK([[privateClipboard stringForType:NSPasteboardTypeHTML] isEqualToString:@"<b>hi</b>"]);
    CHECK(macos_clipboard_set_rich_text("plain", 5, NULL, 0) == 1);
    CHECK([[privateClipboard stringForType:NSPasteboardTypeString] isEqualToString:@"plain"]);
    CHECK([privateClipboard stringForType:NSPasteboardTypeHTML] == nil);
}

int main(void) {
    @autoreleasepool {
        privateClipboard = [NSPasteboard pasteboardWithUniqueName];
        if (!privateClipboard) return 2;
        Method method = class_getClassMethod([NSPasteboard class], @selector(generalPasteboard));
        IMP original = method_setImplementation(method, (IMP)testPasteboard);
        CHECK([NSPasteboard generalPasteboard] == privateClipboard);
        verifyRead(NO, NSPasteboardTypeString);
        verifyRead(YES, NSPasteboardTypeHTML);
        verifyRichWrite();
        method_setImplementation(method, original);
        [privateClipboard releaseGlobally];
        privateClipboard = nil;
        printf("Native clipboard: %d checks, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
}
