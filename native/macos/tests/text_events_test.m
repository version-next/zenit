// Real bridge queue reads, with no global input or system input-source changes.
#import "../window_bridge.m"
// Standalone empty accessibility fixture; no untracked helper dependency.
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
#include <assert.h>
uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w, uint64_t s, char *b, int n) { return 0; }
int zenit_text_input_selection(uint32_t w, uint32_t *s, uint32_t *e, uint32_t *c) { return 0; }
int zenit_text_input_frame(uint32_t w, uint32_t s, uint32_t e, float *x, float *y, float *a, float *b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w, float x, float y, uint32_t *s, uint32_t *e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w, uint64_t n) { return n; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w, uint64_t n) { return n; }

void *zenit_test_text_window_create(void) {
    WindowWrapper *w = [WindowWrapper new];
    w.inputTextQueue = [NSMutableArray array];
    w.imePreeditQueue = [NSMutableArray array];
    w.imeCommitQueue = [NSMutableArray array];
    return (__bridge_retained void *)w;
}
void zenit_test_text_window_destroy(void *ptr) { CFBridgingRelease(ptr); }
unsigned long long zenit_test_text_enqueue(void *ptr, uint32_t kind, const uint8_t *bytes, size_t length, uint32_t cursor) {
    WindowWrapper *w = (__bridge WindowWrapper *)ptr;
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    assert(text);
    if (kind == 0) zenitEnqueueInputText(w, text);
    if (kind == 1) zenitEnqueueImePreedit(w, text, cursor, 1, 7);
    if (kind == 2) zenitEnqueueImeCommit(w, text, 1, 7);
    return zenitTextQueue(w, kind).lastObject.sequence;
}

#ifndef ZENIT_TEXT_EVENTS_NO_MAIN
int main(void) {
    @autoreleasepool {
        WindowWrapper *w = [WindowWrapper new];
        w.inputTextQueue = [NSMutableArray array];
        w.imePreeditQueue = [NSMutableArray array];
        w.imeCommitQueue = [NSMutableArray array];
        void *ptr = (__bridge void *)w;
        NSMutableString *longText = [NSMutableString string];
        for (int i = 0; i < 2000; i++) [longText appendString:@"漢"];
        [longText appendString:@"👩‍💻"];
        NSData *expected = [longText dataUsingEncoding:NSUTF8StringEncoding];
        char small[512];
        char full[8192];
        for (int kind = 0; kind < 3; kind++) {
            if (kind == 0) zenitEnqueueInputText(w, longText);
            if (kind == 1) zenitEnqueueImePreedit(w, longText, (uint32_t)longText.length, 1, 7);
            if (kind == 2) zenitEnqueueImeCommit(w, longText, 1, 7);
            int length = 0; uint32_t cursor = 0, start = 0, end = 0;
            unsigned long long sequence = 0;
            memset(small, 0x55, sizeof(small));
            int result = kind == 0 ? macos_get_input_text(ptr, small, sizeof(small), &sequence) :
                kind == 1 ? macos_get_ime_preedit(ptr, small, sizeof(small), &length, &cursor, &start, &end, &sequence) :
                            macos_get_ime_commit(ptr, small, sizeof(small), &length, &start, &end, &sequence);
            fprintf(stderr, "kind=%d undersized result=%d copied=%d remaining=%lu\n", kind, result, length,
                    (unsigned long)(kind == 0 ? w.inputTextQueue.count : kind == 1 ? w.imePreeditQueue.count : w.imeCommitQueue.count));
            assert(result == 0); // Insufficient capacity does not consume or return a prefix.
            for (int i = 0; i < sizeof(small); i++) assert(small[i] == 0x55);
            result = kind == 0 ? macos_get_input_text(ptr, full, sizeof(full), &sequence) :
                kind == 1 ? macos_get_ime_preedit(ptr, full, sizeof(full), &length, &cursor, &start, &end, &sequence) :
                            macos_get_ime_commit(ptr, full, sizeof(full), &length, &start, &end, &sequence);
            if (kind == 0) length = result;
            assert(result > 0 && length == expected.length);
            assert(memcmp(full, expected.bytes, expected.length) == 0);
            if (kind == 1) assert(cursor == expected.length);
            if (kind != 0) assert(start == 1 && end == 7);
        }
        // Cached UTF-8 stays alive after peek's autorelease pool, includes
        // embedded NUL, and is immutable even if the producer mutates its string.
        const unichar chars[] = { 'a', 0, 0x6F22, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDCBB, 'z' };
        NSString *unicode = [[NSString alloc] initWithCharacters:chars length:9];
        NSData *unicodeBytes = [unicode dataUsingEncoding:NSUTF8StringEncoding];
        for (uint32_t kind = 0; kind < 3; kind++) {
            NSMutableString *source = [unicode mutableCopy];
            if (kind == 0) zenitEnqueueInputText(w, source);
            if (kind == 1) zenitEnqueueImePreedit(w, source, 4, 1, 7);
            if (kind == 2) zenitEnqueueImeCommit(w, source, 1, 7);
            [source setString:@"changed"];
            const uint8_t *bytes = NULL; size_t length = 0;
            uint32_t cursor, start, end; unsigned long long sequence = 0;
            @autoreleasepool {
                assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &sequence) == 1);
            }
            assert(length == unicodeBytes.length);
            assert(memcmp(bytes, unicodeBytes.bytes, length) == 0);
            if (kind == 1) assert(cursor == 5); // UTF-16 cursor inside a surrogate snaps back.
            assert(macos_consume_text_event(ptr, kind, sequence + 1) == 0);
            unsigned long long repeated = 0;
            assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &repeated) == 1);
            assert(repeated == sequence && memcmp(bytes, unicodeBytes.bytes, length) == 0);
            assert(macos_consume_text_event(ptr, kind, sequence) == 1);
            assert(macos_consume_text_event(ptr, kind, sequence) == 0);
            assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &sequence) == 0);
        }
        fprintf(stderr, "PASS: peek lifetime, NUL, immutable payload, cursor and matching consumption\n");

        // Unpaired UTF-16 surrogates cannot be encoded as UTF-8. The peek must
        // still deliver (U+FFFD substituted) instead of reporting -1, which the
        // Zig pump surfaces as BackendFailure and ends App.run with the packet
        // stuck at the queue head.
        const unichar lone[] = { 'a', 0xD800, 'b', 0xDC00 };
        NSString *loneText = [[NSString alloc] initWithCharacters:lone length:4];
        const char loneExpected[] = "a\xEF\xBF\xBD" "b\xEF\xBF\xBD";
        for (uint32_t kind = 0; kind < 3; kind++) {
            if (kind == 0) zenitEnqueueInputText(w, loneText);
            if (kind == 1) zenitEnqueueImePreedit(w, loneText, 3, 1, 7);
            if (kind == 2) zenitEnqueueImeCommit(w, loneText, 1, 7);
            const uint8_t *bytes = NULL; size_t length = 0;
            uint32_t cursor, start, end; unsigned long long sequence = 0;
            assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &sequence) == 1);
            assert(length == sizeof(loneExpected) - 1);
            assert(memcmp(bytes, loneExpected, length) == 0);
            if (kind == 1) assert(cursor == 5); // after "a" + U+FFFD + "b"
            assert(macos_consume_text_event(ptr, kind, sequence) == 1);
            assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &sequence) == 0);
        }
        fprintf(stderr, "PASS: lone surrogates are delivered as U+FFFD, never a fatal peek\n");

        // Singleton compatibility is materialized once; retry must not invent
        // another sequence or repeat an empty composition-end packet.
        w.inputTextQueue = nil; w.inputText = @"fallback";
        w.imePreeditQueue = nil; w.hasImePreedit = YES; w.imePreeditText = @"";
        w.imeCommitQueue = nil; w.hasImeCommit = YES; w.imeCommitText = @"";
        for (uint32_t kind = 0; kind < 3; kind++) {
            const uint8_t *bytes; size_t length; uint32_t cursor, start, end;
            unsigned long long sequence, repeated;
            assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &sequence) == 1);
            assert(length == (kind == 0 ? 8 : 0));
            assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &repeated) == 1);
            assert(repeated == sequence);
            assert(macos_consume_text_event(ptr, kind, sequence) == 1);
            assert(macos_peek_text_event(ptr, kind, &bytes, &length, &cursor, &start, &end, &sequence) == 0);
        }
        fprintf(stderr, "PASS: stable legacy singleton and empty end/commit events\n");

        fprintf(stderr, "PASS: native long text/preedit/commit preserve queue head on small reads\n");
    }
    return 0;
}

#endif
