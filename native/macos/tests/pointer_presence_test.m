// Hover presence in the macOS bridge (window_bridge.m "Pointer presence"): the ordered motion
// stream reports a pointer that stops being over the window's visible content (pointer_left
// marker) and re-delivers the resting position when it is over it again, independent of window
// activation. The window-server query is replaced, so the deterministic part never depends on
// the user's cursor; nothing moves the cursor or posts global events.
//
// `--live` additionally checks the real window server with the cursor at rest: a window of this
// process is ordered over the pointer and away again (the native measurements are in
// tools/macos_hover_probe.swift). It exits 3 if the cursor moved meanwhile (invalid run).
#import "../window_bridge.m"
#include "empty_a11y.inc"
#include "no_render_copy.inc"
#include <assert.h>

uint64_t zenit_text_input_length(uint32_t wid) { return 0; }
int zenit_text_input_copy(uint32_t wid, uint64_t start, char *buf, int len) { return 0; }
int zenit_text_input_selection(uint32_t wid, uint32_t *start, uint32_t *end, uint32_t *caret) { return 0; }
int zenit_text_input_frame(uint32_t wid, uint32_t start, uint32_t end, float *x, float *y, float *width, float *height) { return 0; }
int zenit_text_input_range_at_point(uint32_t wid, float x, float y, uint32_t *start, uint32_t *end) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t wid, uint64_t offset) { return offset; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t wid, uint64_t offset) { return offset; }


static BOOL fakeOver;
static int fakeQueries;
static BOOL fakePointerOver(WindowWrapper *w, NSPoint screen) { (void)w; (void)screen; fakeQueries++; return fakeOver; }

static NSArray<NSValue *> *drainMoves(WindowWrapper *w) {
    NSArray<NSValue *> *out = [w.mouseMoveQueue copy] ?: @[];
    [w.mouseMoveQueue removeAllObjects];
    return out;
}
static MouseMovePacket packetAt(NSArray<NSValue *> *packets, NSUInteger i) {
    MouseMovePacket p;
    [packets[i] getValue:&p];
    return p;
}
static NSEvent *mouse(WindowWrapper *w, NSEventType type, NSPoint inWindow) {
    return [NSEvent mouseEventWithType:type location:inWindow modifierFlags:0 timestamp:0
        windowNumber:w.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}

static void testStepRule(void) {
    const ZenitPresenceCause causes[] = {ZenitPresenceEntered, ZenitPresenceExited, ZenitPresenceMove,
                                         ZenitPresenceSample, ZenitPresenceRelease};
    int checked = 0;
    for (int c = 0; c < 5; c++) for (int was = 0; was < 2; was++) for (int now = 0; now < 2; now++)
        for (int held = 0; held < 2; held++) {
            BOOL over = was;
            const ZenitPresenceTransition t = zenitPresenceStep(&over, causes[c], now, held);
            BOOL expect;
            if (held) expect = was;                                      // sequence owns the pointer
            else if (causes[c] == ZenitPresenceSample) expect = was && now; // sample only ends presence
            else expect = now;                                           // window server's answer
            assert(over == expect);
            assert(t == (expect == was ? ZenitPresenceUnchanged :
                         expect ? ZenitPresenceBecameOver : ZenitPresenceBecameAway));
            checked++;
        }
    assert(checked == 40);
    fprintf(stderr, "PASS: presence rule over 40 cause/state/answer/button combinations\n");
}

static void testTrackingArea(WindowWrapper *w) {
    // AppKit installs view tracking areas once the window is on screen.
    for (int i = 0; i < 16 && !w.metalView.zenitPointerTrackingArea; i++) pumpAppEventsWithTimeout(10);
    NSTrackingArea *area = w.metalView.zenitPointerTrackingArea;
    assert(area && [w.metalView.trackingAreas containsObject:area]);
    const NSTrackingAreaOptions o = area.options;
    assert((o & NSTrackingActiveAlways) && (o & NSTrackingMouseEnteredAndExited) && (o & NSTrackingMouseMoved) &&
           (o & NSTrackingInVisibleRect) && !(o & NSTrackingEnabledDuringMouseDrag));
    // A reinstall (geometry change) replaces, never accumulates, the area.
    [w.metalView updateTrackingAreas];
    NSUInteger pointerAreas = 0;
    for (NSTrackingArea *a in w.metalView.trackingAreas) if (a.options & NSTrackingActiveAlways) pointerAreas++;
    assert(pointerAreas == 1);
    fprintf(stderr, "PASS: content tracking area is activeAlways enter/exit/moved in the visible rect, not during drags\n");
}

static void testStationaryTransitions(WindowWrapper *w) {
    w.pointerOverContent = NO;
    drainMoves(w);
    // Uncovered / window moved under the resting pointer: mouseEntered queues the position.
    fakeOver = YES;
    zenitPointerTrackingEvent(w.metalView, YES);
    NSArray<NSValue *> *q = drainMoves(w);
    assert(w.pointerOverContent && q.count == 1 && !packetAt(q, 0).left);
    // A repeated enter (tracking area reinstalled over the pointer) adds nothing.
    zenitPointerTrackingEvent(w.metalView, YES);
    assert(drainMoves(w).count == 0);
    // Covered by another window: exit is a leave marker carrying the last position.
    const NSPoint last = w.mouseLocation;
    fakeOver = NO;
    zenitPointerTrackingEvent(w.metalView, NO);
    q = drainMoves(w);
    assert(!w.pointerOverContent && q.count == 1 && packetAt(q, 0).left);
    assert(packetAt(q, 0).x == (float)last.x && packetAt(q, 0).y == (float)last.y);
    // The getter reports the marker to the SDK.
    zenitPointerTrackingEvent(w.metalView, YES); // no-op: still not over
    assert(drainMoves(w).count == 0 && !w.pointerOverContent);
    fakeOver = YES;
    zenitPointerTrackingEvent(w.metalView, YES);
    fakeOver = NO;
    zenitPointerTrackingEvent(w.metalView, NO);
    float x, y, dx, dy; uint32_t mods; unsigned long long s1 = 0, s2 = 0; int left = -1;
    assert(macos_get_mouse_move_event((__bridge void *)w, &x, &y, &dx, &dy, &mods, &s1, &left) == 1 && left == 0);
    assert(macos_get_mouse_move_event((__bridge void *)w, &x, &y, &dx, &dy, &mods, &s2, &left) == 1 && left == 1);
    assert(s2 > s1);
    assert(macos_get_mouse_move_event((__bridge void *)w, &x, &y, &dx, &dy, &mods, &s1, &left) == 0 && left == 0);
    // An exit while the window server still names the content (reinstalled area) changes nothing.
    fakeOver = YES;
    zenitPointerTrackingEvent(w.metalView, YES);
    drainMoves(w);
    zenitPointerTrackingEvent(w.metalView, NO);
    assert(w.pointerOverContent && drainMoves(w).count == 0);
    fprintf(stderr, "PASS: enter queues the resting position, exit queues pointer_left, both from the window server's answer\n");
}

static void testPumpBoundarySample(WindowWrapper *w) {
    fakeOver = YES;
    zenitPointerTrackingEvent(w.metalView, YES);
    drainMoves(w);
    assert(w.pointerOverContent);
    // A missed exit (area reinstalled with the pointer outside): the sample ends presence.
    fakeOver = NO;
    macos_update_window_mouse((__bridge void *)w);
    NSArray<NSValue *> *q = drainMoves(w);
    assert(!w.pointerOverContent && q.count == 1 && packetAt(q, 0).left);
    // The sample never re-enters (windowNumberAtPoint can lag a window just ordered away);
    // mouseEntered or the next real move does.
    const NSPoint before = w.mouseLocation;
    fakeOver = YES;
    const int queries = fakeQueries;
    macos_update_window_mouse((__bridge void *)w);
    assert(!w.pointerOverContent && drainMoves(w).count == 0);
    assert(NSEqualPoints(before, w.mouseLocation));
    // A sample cannot change absent presence, so it does not ask the window server.
    assert(fakeQueries == queries);
    fprintf(stderr, "PASS: pump-boundary sample ends presence and never resurrects it\n");
}

static void testMovesFollowPresence(WindowWrapper *w) {
    w.pointerOverContent = NO;
    drainMoves(w);
    const NSPoint inside = NSMakePoint(60, 60);
    // Motion over another window covering our content (or outside it): no hover position.
    fakeOver = NO;
    enqueueMouseMove(w, mouse(w, NSEventTypeMouseMoved, inside));
    assert(drainMoves(w).count == 0 && !w.pointerOverContent);
    // Motion back over our content: presence and exactly one move (the event's own).
    fakeOver = YES;
    enqueueMouseMove(w, mouse(w, NSEventTypeMouseMoved, inside));
    NSArray<NSValue *> *q = drainMoves(w);
    assert(w.pointerOverContent && q.count == 1 && !packetAt(q, 0).left);
    // Moving onto another window over the content ends presence at that move, before the exit.
    fakeOver = NO;
    enqueueMouseMove(w, mouse(w, NSEventTypeMouseMoved, NSMakePoint(61, 60)));
    q = drainMoves(w);
    assert(!w.pointerOverContent && q.count == 1 && packetAt(q, 0).left);
    // Activation is irrelevant: this window is not key here, and hover motion is delivered.
    fakeOver = YES;
    assert(!windowCanAcceptPointerInput(w));
    enqueueMouseMove(w, mouse(w, NSEventTypeMouseMoved, inside));
    assert(drainMoves(w).count == 1);
    fprintf(stderr, "PASS: hover motion only while over the visible content, in an inactive window too\n");
}

static void testButtonSequence(WindowWrapper *w) {
    fakeOver = YES;
    w.pointerOverContent = YES;
    drainMoves(w);
    [w.mouseButtonQueue removeAllObjects];
    w.leftButtonPressed = YES;
    enqueueMouseButton(w, 0, YES, mouse(w, NSEventTypeLeftMouseDown, NSMakePoint(60, 60)));
    // The drag leaves the content: dragged motion is still delivered and presence is frozen.
    fakeOver = NO;
    enqueueMouseMove(w, mouse(w, NSEventTypeLeftMouseDragged, NSMakePoint(-40, 60)));
    zenitPointerTrackingEvent(w.metalView, NO);
    macos_update_window_mouse((__bridge void *)w);
    NSArray<NSValue *> *q = drainMoves(w);
    assert(w.pointerOverContent && q.count == 1 && !packetAt(q, 0).left);
    // Released outside: the release, then pointer_left, in that order.
    w.leftButtonPressed = NO;
    enqueueMouseButton(w, 0, NO, mouse(w, NSEventTypeLeftMouseUp, NSMakePoint(-40, 60)));
    q = drainMoves(w);
    assert(!w.pointerOverContent && q.count == 1 && packetAt(q, 0).left);
    MouseButtonPacket up;
    [w.mouseButtonQueue.lastObject getValue:&up];
    assert(!up.pressed && packetAt(q, 0).sequence > up.sequence);
    // Released over the content after a drag that left it: presence returns with the position.
    w.pointerOverContent = NO;
    w.leftButtonPressed = YES;
    enqueueMouseButton(w, 0, YES, mouse(w, NSEventTypeLeftMouseDown, NSMakePoint(60, 60)));
    fakeOver = YES;
    w.leftButtonPressed = NO;
    enqueueMouseButton(w, 0, NO, mouse(w, NSEventTypeLeftMouseUp, NSMakePoint(60, 60)));
    q = drainMoves(w);
    assert(w.pointerOverContent && q.count == 1 && !packetAt(q, 0).left);
    [w.mouseButtonQueue removeAllObjects];
    fprintf(stderr, "PASS: a button sequence freezes presence; its release re-evaluates it in order\n");
}

static void testMarkerNeverCoalesces(WindowWrapper *w) {
    fakeOver = YES;
    w.pointerOverContent = YES;
    drainMoves(w);
    for (NSUInteger i = 0; i < ZENIT_MOUSE_MOVE_SOFT_LIMIT; i++)
        enqueueMouseMove(w, mouse(w, NSEventTypeMouseMoved, NSMakePoint(10 + (i % 50), 10)));
    fakeOver = NO;
    zenitPointerTrackingEvent(w.metalView, NO);
    fakeOver = YES;
    // Under pressure the next move merges into an adjacent tail; never into the marker. Moving
    // back over the content makes the move itself the re-entry, adjacent to the marker.
    enqueueMouseMove(w, mouse(w, NSEventTypeMouseMoved, NSMakePoint(70, 70)));
    NSArray<NSValue *> *q = drainMoves(w);
    NSUInteger markers = 0;
    for (NSUInteger i = 0; i < q.count; i++) markers += packetAt(q, i).left;
    assert(markers == 1);
    // The marker, then the move as its own packet.
    NSUInteger at = NSNotFound;
    for (NSUInteger i = 0; i < q.count; i++) if (packetAt(q, i).left) at = i;
    assert(at != NSNotFound && at + 1 < q.count && !packetAt(q, at + 1).left);
    fprintf(stderr, "PASS: the leave marker survives move coalescing under pressure\n");
}

static void testPumpDelivery(WindowWrapper *w) {
    // Through the real pump: a mouse-moved event for this (non-key) window.
    fakeOver = YES;
    w.pointerOverContent = NO;
    for (int i = 0; i < 8; i++) pumpAppEventsWithTimeout(0);
    drainMoves(w);
    [NSApp postEvent:mouse(w, NSEventTypeMouseMoved, NSMakePoint(80, 80)) atStart:YES];
    pumpAppEventsWithTimeout(0);
    NSArray<NSValue *> *q = drainMoves(w);
    BOOL moved = NO;
    for (NSUInteger i = 0; i < q.count; i++) if (!packetAt(q, i).left) moved = YES;
    assert(moved && w.pointerOverContent);
    fakeOver = NO;
    [NSApp postEvent:mouse(w, NSEventTypeMouseMoved, NSMakePoint(81, 80)) atStart:YES];
    pumpAppEventsWithTimeout(0);
    q = drainMoves(w);
    assert(q.count >= 1 && packetAt(q, q.count - 1).left && !w.pointerOverContent);
    fprintf(stderr, "PASS: pump delivers hover motion and the leave marker for a non-key window\n");
}

// Real window server, cursor at rest. Returns 0 pass, 3 invalid (cursor moved), 4 not under a screen.
static int testLive(void) {
    g_zenit_pointer_over_override = NULL;
    // Let the cursor rest for 1 s first; the user may be using the machine.
    NSPoint cursor = NSEvent.mouseLocation;
    for (NSDate *since = [NSDate date]; -since.timeIntervalSinceNow < 1.0;) {
        usleep(50000);
        if (!NSEqualPoints(cursor, NSEvent.mouseLocation)) { cursor = NSEvent.mouseLocation; since = [NSDate date]; }
    }
    void *ptr = macos_create_window(320, 240, "pointer presence live");
    WindowWrapper *w = (__bridge WindowWrapper *)ptr;
    NSRect frame = w.window.frame;
    [w.window setFrameOrigin:NSMakePoint(cursor.x - frame.size.width / 2, cursor.y - 100)];
    [w.window orderFrontRegardless];
    NSWindow *cover = [[NSWindow alloc] initWithContentRect:NSMakeRect(cursor.x - 60, cursor.y - 40, 120, 80)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    cover.releasedWhenClosed = NO;
    int result = 0;
    double coverAt = 0, uncoverAt = 0, leftAt = 0, backAt = 0;
    BOOL sawLeft = NO, sawBack = NO;
    for (NSDate *d = [NSDate dateWithTimeIntervalSinceNow:2]; d.timeIntervalSinceNow > 0 && !w.pointerOverContent;)
        pumpAppEventsWithTimeout(10);
    if (!w.pointerOverContent) { result = 4; goto done; }
    drainMoves(w);
    coverAt = CACurrentMediaTime();
    [cover orderFrontRegardless];
    for (NSDate *d = [NSDate dateWithTimeIntervalSinceNow:2]; d.timeIntervalSinceNow > 0 && !sawLeft;) {
        pumpAppEventsWithTimeout(5);
        for (NSValue *v in drainMoves(w)) { MouseMovePacket p; [v getValue:&p]; if (p.left) { sawLeft = YES; leftAt = CACurrentMediaTime(); } }
    }
    uncoverAt = CACurrentMediaTime();
    [cover orderOut:nil];
    for (NSDate *d = [NSDate dateWithTimeIntervalSinceNow:2]; d.timeIntervalSinceNow > 0 && !sawBack;) {
        pumpAppEventsWithTimeout(5);
        for (NSValue *v in drainMoves(w)) { MouseMovePacket p; [v getValue:&p]; if (!p.left) { sawBack = YES; backAt = CACurrentMediaTime(); } }
    }
    if (!NSEqualPoints(cursor, NSEvent.mouseLocation)) { result = 3; goto done; }
    fprintf(stderr, "live: covered -> pointer_left %s after %.1f ms; uncovered -> position again %s after %.1f ms\n",
            sawLeft ? "yes" : "NO", (leftAt - coverAt) * 1000, sawBack ? "yes" : "NO", (backAt - uncoverAt) * 1000);
    assert(sawLeft && sawBack);
    fprintf(stderr, "PASS: live window server: a window over the resting pointer ends presence, its removal restores it\n");
done:
    [cover close];
    macos_destroy_window(ptr);
    return result;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        testStepRule();
        macos_init_app();
        if (argc == 2 && strcmp(argv[1], "--live") == 0) return testLive();
        g_zenit_pointer_over_override = fakePointerOver;
        void *ptr = macos_create_window(400, 240, "pointer presence");
        assert(ptr);
        WindowWrapper *w = (__bridge WindowWrapper *)ptr;
        testTrackingArea(w);
        testStationaryTransitions(w);
        testPumpBoundarySample(w);
        testMovesFollowPresence(w);
        testButtonSequence(w);
        testMarkerNeverCoalesces(w);
        testPumpDelivery(w);
        macos_destroy_window(ptr);
        fprintf(stderr, "pointer presence: all checks passed\n");
    }
    return 0;
}
