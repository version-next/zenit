// In-process AppKit regression: no global CGEvents, input-source changes, or
// timing sleeps. The real bridge/pump runs against a deterministic input
// context; the client document is advanced only at the SDK dispatch boundary.
#import "../window_bridge.m"
#include "empty_a11y.inc"
#include "no_render_copy.inc"
#include <assert.h>

static NSMutableString *document;
static BOOL liveFrameEnabled;
static BOOL textOffsetsUnavailable;
static BOOL reverseTextOffsetsUnavailable;
static NSRect liveFrame;
static uint32_t queriedStart, queriedEnd;
uint64_t zenit_text_input_length(uint32_t wid) { return document.length; }
int zenit_text_input_copy(uint32_t wid, uint64_t start, char *buf, int len) {
    NSData *bytes = [document dataUsingEncoding:NSUTF8StringEncoding];
    if (start > bytes.length) return 0;
    NSUInteger count = MIN((NSUInteger)len, bytes.length - start);
    memcpy(buf, (const char *)bytes.bytes + start, count);
    return (int)count;
}
int zenit_text_input_selection(uint32_t wid, uint32_t *start, uint32_t *end, uint32_t *caret) {
    *start = *end = *caret = (uint32_t)document.length;
    return 1;
}
int zenit_text_input_frame(uint32_t wid, uint32_t start, uint32_t end,
                           float *x, float *y, float *width, float *height) {
    if (!liveFrameEnabled) return 0;
    queriedStart = start;
    queriedEnd = end;
    *x = liveFrame.origin.x; *y = liveFrame.origin.y;
    *width = liveFrame.size.width; *height = liveFrame.size.height;
    return 1;
}
int zenit_text_input_range_at_point(uint32_t wid, float x, float y,
                                    uint32_t *start, uint32_t *end) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t wid, uint64_t offset) { return reverseTextOffsetsUnavailable ? ZENIT_TEXT_OFFSET_INVALID : offset; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t wid, uint64_t offset) { return textOffsetsUnavailable ? ZENIT_TEXT_OFFSET_INVALID : offset; }

@interface PumpInputContext : NSTextInputContext
@property NSUInteger calls;
@property BOOL compose;
@property (strong) NSMutableArray<NSNumber *> *selections;
@end
@implementation PumpInputContext
- (BOOL)handleEvent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return NO;
    self.calls++;
    [self.selections addObject:@(self.client.selectedRange.location)];
    if (self.compose) {
        [self.client setMarkedText:event.characters selectedRange:NSMakeRange(1, 0)
                  replacementRange:NSMakeRange(NSNotFound, 0)];
    } else {
        [self.client insertText:event.characters replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    return YES;
}
@end

static NSEvent *key(WindowWrapper *w, NSString *text, unsigned short code) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:w.window.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}
static NSEvent *click(WindowWrapper *w, NSEventType type) {
    return [NSEvent mouseEventWithType:type location:NSMakePoint(120, 120)
        modifierFlags:0 timestamp:0 windowNumber:w.window.windowNumber context:nil
        eventNumber:0 clickCount:1 pressure:1];
}
static NSEvent *systemKey(unsigned short code) {
    // IMK consumes the low-level keyboard payload. keyEventWithType: alone
    // has no CGEvent and exercises AppKit's literal fallback instead.
    CGEventRef raw = CGEventCreateKeyboardEvent(NULL, code, true);
    CGEventSetFlags(raw, 0);
    NSEvent *event = [NSEvent eventWithCGEvent:raw];
    CFRelease(raw);
    return event;
}
static void enqueue(NSArray<NSEvent *> *events) {
    for (NSEvent *event in events.reverseObjectEnumerator) [NSApp postEvent:event atStart:YES];
}
static void dispatchToClient(WindowWrapper *w) {
    // This models SDK -> Cx: clicking enables the logical text client, and
    // applying text updates the selection queried by the next native key.
    if (w.mouseButtonQueue.count) macos_set_text_input_enabled((__bridge void *)w, 1);
    for (ZenitTextEventPacket *packet in w.inputTextQueue) [document appendString:packet.text];
    [w.mouseButtonQueue removeAllObjects];
    [w.mouseMoveQueue removeAllObjects];
    [w.keyEventQueue removeAllObjects];
    [w.inputTextQueue removeAllObjects];
    [w.imePreeditQueue removeAllObjects];
    [w.imeCommitQueue removeAllObjects];
    w.hasImePreedit = w.hasImeCommit = NO;
}

// Observe the native ordering boundary with two logical client documents.
// The editor semantics of blur/undo are covered by the app's native E2E.
static void verifyQueuedTextBeforeFocusClick(WindowWrapper *w, PumpInputContext *probe) {
    NSMutableString *previousDocument = document;
    const unsigned long long previousSeq = w.keyDispatchSeq;
    w.keyDispatchSeq = 0;
    for (int channel = 0; channel < 3; channel++) {
        NSMutableString *oldDocument = [@"A" mutableCopy];
        NSMutableString *newDocument = [@"B" mutableCopy];
        document = oldDocument;
        probe.compose = NO;
        probe.calls = 0;
        [probe.selections removeAllObjects];
        macos_set_text_input_enabled((__bridge void *)w, 1);
        if (channel == 0) {
            [w.metalView insertText:@"X" replacementRange:NSMakeRange(NSNotFound, 0)];
        } else if (channel == 1) {
            [w.metalView insertText:@"X" replacementRange:NSMakeRange(1, 0)];
        } else {
            [w.metalView setMarkedText:@"X" selectedRange:NSMakeRange(1, 0)
                     replacementRange:NSMakeRange(NSNotFound, 0)];
        }
        enqueue(@[click(w, NSEventTypeLeftMouseDown), key(w, @"k", 40)]);
        pumpAppEventsWithTimeout(UINT32_MAX);
        assert(w.mouseButtonQueue.count == 0 && probe.calls == 0);
        NSArray<ZenitTextEventPacket *> *packets = channel == 0 ? w.inputTextQueue :
            (channel == 1 ? w.imeCommitQueue : w.imePreeditQueue);
        assert(packets.count == 1 && [packets.firstObject.text isEqualToString:@"X"]);
        // The pending packet must reach the OLD client before the queued click.
        [document appendString:packets.firstObject.text];
        [w.inputTextQueue removeAllObjects];
        [w.imeCommitQueue removeAllObjects];
        [w.imePreeditQueue removeAllObjects];
        w.hasImePreedit = w.hasImeCommit = NO;
        macos_ime_discard((__bridge void *)w);
        dispatchToClient(w);
        BOOL clicked = NO;
        for (int i = 0; i < 16 && !clicked; i++) {
            pumpAppEventsWithTimeout(0);
            assert(probe.calls == 0);
            clicked = w.mouseButtonQueue.count > 0;
            if (clicked) document = newDocument;
            dispatchToClient(w);
        }
        assert(clicked);
        for (int i = 0; i < 16 && probe.calls == 0; i++) {
            pumpAppEventsWithTimeout(0);
            dispatchToClient(w);
        }
        assert([oldDocument isEqualToString:@"AX"]);
        assert([newDocument isEqualToString:@"Bk"]);
        assert(probe.calls == 1 && [probe.selections isEqualToArray:@[@1]]);
        for (int i = 0; i < 4; i++) { pumpAppEventsWithTimeout(0); dispatchToClient(w); }
    }
    document = previousDocument;
    w.keyDispatchSeq = previousSeq;
    fprintf(stderr, "PASS: queued input/commit/preedit reaches old client before click and new-client key\n");
}

static void verifySystemComposition(WindowWrapper *w, BOOL japanese) {
    [document setString:@""];
    enqueue(@[systemKey(0)]);
    BOOL composing = NO;
    for (int i = 0; i < 16; i++) {
        pumpAppEventsWithTimeout(0);
        for (ZenitTextEventPacket *packet in w.imePreeditQueue)
            if (packet.text.length) composing = YES;
        dispatchToClient(w);
    }
    fprintf(stderr, "system source=%s first-key preedit=%d literal=%s\n",
            w.metalView.inputContext.selectedKeyboardInputSource.UTF8String,
            composing, document.UTF8String);
    assert(composing && document.length == 0);
    enqueue(@[systemKey(japanese ? 36 : 49)]);
    BOOL committed = NO;
    for (int i = 0; i < 16; i++) {
        pumpAppEventsWithTimeout(0);
        for (ZenitTextEventPacket *packet in w.imeCommitQueue)
            if (packet.text.length) committed = YES;
        dispatchToClient(w);
    }
    assert(committed);
}

static void verifyCandidateAnchor(WindowWrapper *w) {
    liveFrameEnabled = YES;
    // Empty terminal text model, with an insertion point away from the origin.
    [document setString:@""];
    liveFrame = NSMakeRect(180, 65, 9, 18);
    for (int moved = 0; moved < 2; moved++) {
        NSRange actual;
        NSRect result = [w.metalView firstRectForCharacterRange:NSMakeRange(NSNotFound, 0)
                                                   actualRange:&actual];
        NSRect local = NSMakeRect(liveFrame.origin.x,
            w.window.contentView.bounds.size.height - liveFrame.origin.y - liveFrame.size.height,
            liveFrame.size.width, liveFrame.size.height);
        NSRect expected = [w.window convertRectToScreen:
            [w.window.contentView convertRect:local toView:nil]];
        assert(NSEqualRects(result, expected));
        assert(actual.location == 0 && actual.length == 0);
        assert(queriedStart == 0 && queriedEnd == 0);
        liveFrame.origin.x += 45;
        liveFrame.origin.y += 36;
    }
    // A regular editor's explicit range must still be forwarded unchanged.
    [document setString:@"abcdef"];
    NSRange actual;
    [w.metalView firstRectForCharacterRange:NSMakeRange(1, 3) actualRange:&actual];
    assert(queriedStart == 1 && queriedEnd == 4);
    assert(actual.location == 1 && actual.length == 3);
    [document setString:@""];
    liveFrameEnabled = NO;
    fprintf(stderr, "PASS: IME unspecified range follows live terminal caret; explicit editor range preserved\n");
}

@interface DiscardInputContext : NSTextInputContext
@property BOOL callsUnmark;
@end
@implementation DiscardInputContext
- (void)discardMarkedText { if (self.callsUnmark) [self.client unmarkText]; }
@end

static void verifyUnmarkAndDiscard(WindowWrapper *w) {
    void *ptr = (__bridge void *)w;
    macos_set_text_input_enabled(ptr, 1);
    [w.metalView setMarkedText:@"hello" selectedRange:NSMakeRange(2, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.imePreeditQueue removeAllObjects];
    [w.metalView unmarkText];
    assert(!w.metalView.hasMarkedText);
    assert(w.imePreeditQueue.count == 0);
    assert(w.imeCommitQueue.count == 1);
    assert([w.imeCommitQueue.firstObject.text isEqualToString:@"hello"]);
    [w.metalView unmarkText];
    assert(w.imeCommitQueue.count == 1);
    [w.imeCommitQueue removeAllObjects];

    NSTextInputContext *previous = w.metalView.zenitInputContext;
    DiscardInputContext *discardContext = [[DiscardInputContext alloc] initWithClient:w.metalView];
    discardContext.callsUnmark = YES;
    w.metalView.zenitInputContext = discardContext;
    [w.metalView setMarkedText:@"cancel" selectedRange:NSMakeRange(6, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.imePreeditQueue removeAllObjects];
    macos_ime_discard(ptr);
    assert(!w.metalView.hasMarkedText && !w.metalView.discardingMarkedText);
    assert(w.imeCommitQueue.count == 0);
    assert(w.imePreeditQueue.count == 1);
    assert(w.imePreeditQueue.firstObject.text.length == 0);
    // The context may not call the client at all. The SDK must still clear
    // its pending projection once, including a queued but now unmarked one.
    discardContext.callsUnmark = NO;
    [w.imePreeditQueue removeAllObjects];
    [w.metalView setMarkedText:@"cancel" selectedRange:NSMakeRange(6, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.imePreeditQueue removeAllObjects];
    macos_ime_discard(ptr);
    assert(w.imeCommitQueue.count == 0 && w.imePreeditQueue.count == 1);
    assert(w.imePreeditQueue.firstObject.text.length == 0);
    [w.imePreeditQueue removeAllObjects];
    assert(!w.metalView.hasMarkedText && w.hasImePreedit);
    macos_ime_discard(ptr);
    assert(w.imeCommitQueue.count == 0 && w.imePreeditQueue.count == 1);
    assert(w.imePreeditQueue.firstObject.text.length == 0);
    w.metalView.zenitInputContext = previous;
    [w.imePreeditQueue removeAllObjects];
    macos_set_text_input_enabled(ptr, 0);
    fprintf(stderr, "PASS: unmark accepts once; explicit discard clears without committing\n");
}

static void verifyExplicitReplacementCommit(WindowWrapper *w) {
    void *ptr = (__bridge void *)w;
    macos_set_text_input_enabled(ptr, 1);
    // Conversion stubs in this pump test use ASCII identity coordinates;
    // the app e2e covers actual UTF16/UTF8 conversion after an emoji prefix.
    for (NSNumber *marked in @[@NO, @YES]) {
        for (NSString *value in @[@"replacement", @""]) {
            [document setString:@"abcXYZtail"];
            if (marked.boolValue) {
                [w.metalView setMarkedText:@"XYZ" selectedRange:NSMakeRange(3, 0)
                    replacementRange:NSMakeRange(3, 3)];
            }
            [w.imePreeditQueue removeAllObjects];
            [w.imeCommitQueue removeAllObjects];
            [w.inputTextQueue removeAllObjects];
            [w.metalView insertText:value replacementRange:NSMakeRange(3, 3)];
            assert(w.imePreeditQueue.count == 0);
            assert(w.inputTextQueue.count == 0 && w.imeCommitQueue.count == 1);
            ZenitTextEventPacket *packet = w.imeCommitQueue.firstObject;
            assert(packet.replaceStartUtf8 == 3 && packet.replaceEndUtf8 == 6);
            assert([packet.text isEqualToString:value]);
            assert(!w.metalView.hasMarkedText);
            [w.imeCommitQueue removeAllObjects];
        }
    }
    [w.metalView insertText:@"" replacementRange:NSMakeRange(NSNotFound, 0)];
    assert(w.imePreeditQueue.count == 0 && w.imeCommitQueue.count == 0 && w.inputTextQueue.count == 0);
    [w.metalView insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    assert(w.imePreeditQueue.count == 1 && w.inputTextQueue.count == 1);
    assert(w.imePreeditQueue.firstObject.sequence < w.inputTextQueue.firstObject.sequence);
    dispatchToClient(w);
    [document setString:@""];
    macos_set_text_input_enabled(ptr, 0);
    fprintf(stderr, "PASS: explicit replacement commits without invalidating its coordinates, including deletion\n");
}

static void verifyCompositionStartsNewInsertIdentity(WindowWrapper *w) {
    void *ptr = (__bridge void *)w;
    macos_set_text_input_enabled(ptr, 1);
    const unsigned long long previousSeq = w.keyDispatchSeq;
    w.keyDispatchSeq = 4242;
    w.lastInsertText = nil;
    [document setString:@"abc"];
    for (int round = 0; round < 4; round++) {
        if (round < 2) {
            [w.metalView setMarkedText:@"ni" selectedRange:NSMakeRange(2, 0)
                     replacementRange:NSMakeRange(NSNotFound, 0)];
        }
        // Also cover an explicit empty replacement without a nonempty mark.
        [w.metalView setMarkedText:@"" selectedRange:NSMakeRange(0, 0)
                 replacementRange:round < 2 ? NSMakeRange(NSNotFound, 0) : NSMakeRange(0, 1)];
        [w.inputTextQueue removeAllObjects];
        [w.imeCommitQueue removeAllObjects];
        [w.imePreeditQueue removeAllObjects];
        [w.metalView insertText:@"你" replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(w.inputTextQueue.count == 1);
        // Duplicate callbacks within that same composition remain suppressed.
        [w.metalView insertText:@"你" replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(w.inputTextQueue.count == 1);
    }
    // An implicit empty update after commit is cleanup, not a new candidate.
    // Keep the same-key suppression of the commit's trailing space callback.
    [w.inputTextQueue removeAllObjects];
    [w.imeCommitQueue removeAllObjects];
    [w.metalView setMarkedText:@"ni" selectedRange:NSMakeRange(2, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.metalView insertText:@"你" replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.metalView setMarkedText:@"" selectedRange:NSMakeRange(0, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.metalView insertText:@" " replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.metalView insertText:@"　" replacementRange:NSMakeRange(NSNotFound, 0)];
    assert(w.imeCommitQueue.count == 1 && w.inputTextQueue.count == 0);
    w.keyDispatchSeq = previousSeq;
    w.lastInsertText = nil;
    w.lastInsertHadMarked = NO;
    [w.inputTextQueue removeAllObjects];
    [w.imeCommitQueue removeAllObjects];
    [w.imePreeditQueue removeAllObjects];
    macos_set_text_input_enabled(ptr, 0);
    fprintf(stderr, "PASS: a new composition cannot inherit an earlier insert dedupe identity\n");
}

static void verifyRejectedReplacement(WindowWrapper *w) {
    void *ptr = (__bridge void *)w;
    macos_set_text_input_enabled(ptr, 1);
    [document setString:@"abcXYZtail"];
    [w.metalView setMarkedText:@"XYZ" selectedRange:NSMakeRange(1, 0)
        replacementRange:NSMakeRange(3, 3)];
    [w.imePreeditQueue removeAllObjects];
    [w.imeCommitQueue removeAllObjects];
    [w.inputTextQueue removeAllObjects];
    w.lastInsertText = @"previous commit";
    w.lastInsertKeyDispatchSeq = 1234;
    w.lastInsertHadMarked = YES;
    NSString *previousInsert = w.lastInsertText;
    const NSRange previousMarked = w.metalView.markedRange;
    const NSRange previousSelected = w.metalView.selectedRange;
    for (NSNumber *mode in @[@0, @1, @2]) {
        textOffsetsUnavailable = mode.integerValue == 1;
        reverseTextOffsetsUnavailable = mode.integerValue == 2;
        // Overflow rejects before lookup; missing-client conversion rejects
        // before either native marked storage or dedupe state is published.
        const NSRange range = mode.integerValue > 0 ? NSMakeRange(3, 3) : NSMakeRange(NSUIntegerMax - 1, 4);
        for (NSString *value in @[@"Q", @""]) {
            [w.metalView insertText:value replacementRange:range];
            [w.metalView setMarkedText:value selectedRange:NSMakeRange(0, 0) replacementRange:range];
            assert(w.imePreeditQueue.count == 0 && w.imeCommitQueue.count == 0 && w.inputTextQueue.count == 0);
            assert([w.metalView.markedTextStorage.string isEqualToString:@"XYZ"]);
            assert(NSEqualRanges(previousMarked, w.metalView.markedRange));
            assert(NSEqualRanges(previousSelected, w.metalView.selectedRange));
            assert(w.lastInsertText == previousInsert);
            assert(w.lastInsertKeyDispatchSeq == 1234 && w.lastInsertHadMarked);
        }
    }
    textOffsetsUnavailable = reverseTextOffsetsUnavailable = NO;
    uint32_t start = 123, end = 456;
    // NSNotFound's length is ignored for compatibility; the u32 ABI reserves
    // UINT32_MAX as absence, so that exact byte endpoint is unrepresentable.
    assert(zenitImeConvertReplacementRange(w.metalView, NSMakeRange(NSNotFound, 9), &start, &end));
    assert(start == ZENIT_IME_NO_REPLACEMENT && end == ZENIT_IME_NO_REPLACEMENT);
    assert(zenitImeConvertReplacementRange(w.metalView, NSMakeRange(UINT32_MAX - 1, 0), &start, &end));
    assert(start == UINT32_MAX - 1 && end == UINT32_MAX - 1);
    assert(!zenitImeConvertReplacementRange(w.metalView, NSMakeRange(UINT32_MAX, 0), &start, &end));
    assert(start == ZENIT_IME_NO_REPLACEMENT && end == ZENIT_IME_NO_REPLACEMENT);
    [w.metalView unmarkText];
    dispatchToClient(w);
    [document setString:@""];
    macos_set_text_input_enabled(ptr, 0);
    fprintf(stderr, "PASS: rejected replacement preserves native marked state, dedupe and event queues\n");
}

static void verifyAppliedMarkedOrigin(WindowWrapper *w) {
    macos_set_text_input_enabled((__bridge void *)w, 1);
    [document setString:@"abcXYZtail"];
    [w.metalView setMarkedText:@"XYZ" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(3, 3)];
    [w.imePreeditQueue removeAllObjects];
    assert(w.metalView.markedRange.location == 3);
    [document setString:@"zXYZtail"]; // earlier cursor replacement shifted primary
    assert(zenit_text_input_preedit_applied((uint32_t)w.window.windowNumber, 1, 4, 1, 4));
    assert(w.metalView.markedRange.location == 1 && w.metalView.selectedRange.location == 2);
    assert(w.imePreeditQueue.count == 0 && w.imeCommitQueue.count == 0);
    [w.metalView setMarkedText:@"ABC" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    const NSRange pendingRange = w.metalView.markedRange;
    assert(!zenit_text_input_preedit_applied((uint32_t)w.window.windowNumber, 2, 5, 1, 4));
    assert(NSEqualRanges(pendingRange, w.metalView.markedRange)); // different queued text
    assert(!zenit_text_input_preedit_applied((uint32_t)w.window.windowNumber, 2, 4, 1, 4)); // length mismatch
    NSMutableString *longCandidate = [NSMutableString string];
    for (int i = 0; i < 255; i++) [longCandidate appendString:@"a"];
    [longCandidate appendString:@"🙂x"];
    [w.metalView setMarkedText:longCandidate selectedRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    [document setString:@"p"];
    [document appendString:longCandidate];
    const NSUInteger byteCount = [longCandidate lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    assert(zenit_text_input_preedit_applied((uint32_t)w.window.windowNumber, 1, 1 + longCandidate.length, 1, (uint32_t)(1 + byteCount)));
    assert(w.metalView.markedRange.location == 1);
    [w.metalView unmarkText];
    assert(!zenit_text_input_preedit_applied((uint32_t)w.window.windowNumber, 1, 4, 1, 4));
    dispatchToClient(w);
    [document setString:@""];
    macos_set_text_input_enabled((__bridge void *)w, 0);
    fprintf(stderr, "PASS: applied marked origin follows model; unmatched and ended candidates remain untouched\n");
}

static void testScrollDeltaUnits(void) {
    const CGScrollEventUnit units[] = { kCGScrollEventUnitLine, kCGScrollEventUnitPixel };
    for (int i = 0; i < 2; i++) {
        CGEventRef raw = CGEventCreateScrollWheelEvent(NULL, units[i], 2, 1, -2);
        assert(raw != NULL);
        NSEvent *event = [NSEvent eventWithCGEvent:raw];
        assert(event != nil);
        assert(event.hasPreciseScrollingDeltas == (i == 1));
        float dx = 0, dy = 0;
        zenitScrollDeltas(event, &dx, &dy);
        assert(dx == (i == 0 ? -80.0f : -2.0f));
        assert(dy == (i == 0 ? 40.0f : 1.0f));
        CFRelease(raw);
    }
    fprintf(stderr, "PASS: line wheels normalize to logical points; precise deltas pass through\n");
}

// Queue real NSEvents inside this process: unlike harness Cx injection, these
// exercise both pump entry points (which share one dispatcher) without global input.
static void verifyScrollNormalization(WindowWrapper *w) {
    for (int pump = 0; pump < 2; pump++) {
        for (int precise = 0; precise < 2; precise++) {
            for (int variant = 0; variant < 4; variant++) {
                const BOOL zero = (variant & 2) != 0;
                const BOOL shifted = (variant & 1) != 0;
                CGEventRef raw = CGEventCreateScrollWheelEvent(NULL,
                    precise ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine,
                    2, zero ? 0 : -3, zero ? 0 : 2);
                assert(raw);
                CGEventSetFlags(raw, shifted ? kCGEventFlagMaskShift : 0);
                NSEvent *event = [NSEvent eventWithCGEvent:raw];
                CFRelease(raw);
                assert(event.hasPreciseScrollingDeltas == (BOOL)precise);
                const float dx = (float)(event.scrollingDeltaX * (precise ? 1 : 40));
                const float dy = (float)(event.scrollingDeltaY * (precise ? 1 : 40));
                if (!zero) {
                    assert(dx != 0 || dy != 0);
                    if (!shifted) assert(dx != 0 && dy != 0);
                }
                [w.scrollEventQueue removeAllObjects];
                enqueue(@[event]);
                for (int attempt = 0; attempt < 16 && w.scrollEventQueue.count == 0; attempt++) {
                    if (pump) pumpAppEventsWithTimeout(0);
                    else macos_poll_events((__bridge void *)w);
                }
                assert(w.scrollEventQueue.count == 1);
                ScrollEventPacket packet;
                [w.scrollEventQueue.firstObject getValue:&packet];
                assert(packet.dx == dx && packet.dy == dy);
                assert(packet.modifiers == (uint32_t)event.modifierFlags);
                assert(packet.phase == 0);
                assert(packet.momentum == 0);
                [w.scrollEventQueue removeAllObjects];
            }
        }
    }
    fprintf(stderr, "PASS: both native scroll entry points normalize line units and preserve precise deltas, axes, zero and modifiers\n");
}

// Explicit SDK phase expectations, independent of the bridge mapping helpers.
// Zero-delta lifecycle packets must survive queueing and native ABI dequeue:
// scroll ownership/bounce completion depends on them even without movement.
static void verifyScrollLifecycle(WindowWrapper *w) {
    const struct {
        CGScrollPhase phase;
        CGMomentumScrollPhase momentum;
        uint8_t expectedPhase, expectedMomentum;
        int dy;
    } cases[] = {
        { kCGScrollPhaseMayBegin, kCGMomentumScrollPhaseNone, 1, 0, 0 },
        { kCGScrollPhaseBegan, kCGMomentumScrollPhaseNone, 2, 0, 0 },
        { kCGScrollPhaseChanged, kCGMomentumScrollPhaseNone, 3, 0, -3 },
        { kCGScrollPhaseEnded, kCGMomentumScrollPhaseNone, 4, 0, 0 },
        { 0, kCGMomentumScrollPhaseBegin, 0, 1, -2 },
        { 0, kCGMomentumScrollPhaseContinue, 0, 2, -1 },
        { 0, kCGMomentumScrollPhaseEnd, 0, 3, 0 },
        { kCGScrollPhaseBegan, kCGMomentumScrollPhaseNone, 2, 0, 0 },
        { kCGScrollPhaseCancelled, kCGMomentumScrollPhaseNone, 5, 0, 0 },
    };
    for (int pump = 0; pump < 2; pump++) {
        unsigned long long previousSequence = 0;
        for (NSUInteger i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
            CGEventRef raw = CGEventCreateScrollWheelEvent(NULL,
                kCGScrollEventUnitPixel, 2, cases[i].dy, 0);
            assert(raw);
            CGEventSetIntegerValueField(raw, kCGScrollWheelEventScrollPhase, cases[i].phase);
            CGEventSetIntegerValueField(raw, kCGScrollWheelEventMomentumPhase, cases[i].momentum);
            NSEvent *event = [NSEvent eventWithCGEvent:raw];
            CFRelease(raw);
            assert(event.hasPreciseScrollingDeltas);
            enqueue(@[event]);
            for (int attempt = 0; attempt < 16 && w.scrollEventQueue.count == 0; attempt++) {
                if (pump) pumpAppEventsWithTimeout(0);
                else macos_poll_events((__bridge void *)w);
            }
            float x, y, dx, dy;
            uint8_t phase, momentum;
            uint32_t modifiers;
            unsigned long long sequence;
            assert(macos_get_scroll_event((__bridge void *)w, &x, &y, &dx, &dy,
                &phase, &momentum, &modifiers, &sequence));
            assert(dx == 0 && dy == cases[i].dy);
            assert(phase == cases[i].expectedPhase && momentum == cases[i].expectedMomentum);
            assert(sequence > previousSequence);
            previousSequence = sequence;
            assert(!macos_get_scroll_event((__bridge void *)w, &x, &y, &dx, &dy,
                &phase, &momentum, &modifiers, &sequence));
        }
    }
    fprintf(stderr, "PASS: native scroll lifecycle preserves zero-delta boundaries, momentum and dequeue order\n");
}

static NSEvent *chordKey(WindowWrapper *w, NSString *text, unsigned short code, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:flags timestamp:0 windowNumber:w.window.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}

// Pumps one queued key and returns whether the input context saw it, the
// queued key packet count and the text the context inserted.
static void pumpChord(WindowWrapper *w, PumpInputContext *probe, NSEvent *event,
                      BOOL expectInterpreted, NSString *expectedText) {
    [w.keyEventQueue removeAllObjects];
    [document setString:@""];
    const NSUInteger calls = probe.calls;
    enqueue(@[event]);
    for (int i = 0; i < 8 && w.keyEventQueue.count == 0; i++) pumpAppEventsWithTimeout(0);
    // The raw key always reaches Zig.
    assert(w.keyEventQueue.count == 1);
    KeyEventPacket packet;
    [w.keyEventQueue.firstObject getValue:&packet];
    assert(packet.keycode == event.keyCode && packet.pressed);
    assert(probe.calls == calls + (expectInterpreted ? 1 : 0));
    if (!expectInterpreted) assert(w.inputTextQueue.count == 0 && w.imeCommitQueue.count == 0);
    dispatchToClient(w);
    assert([document isEqualToString:expectedText]);
}

// Reserved chords (macos_set_reserved_key_chords): ⌥] reaches Zig as a key
// without the input method typing ‘; anything not reserved exactly (other
// modifiers, other keys, cleared table) is interpreted as before; Caps Lock
// does not defeat a reservation; an active composition keeps every key.
static void verifyReservedChords(WindowWrapper *w, PumpInputContext *probe) {
    void *ptr = (__bridge void *)w;
    dispatchToClient(w);
    macos_set_text_input_enabled(ptr, 1);
    probe.compose = NO;
    const NSEventModifierFlags opt = NSEventModifierFlagOption;
    // Unreserved: today's behaviour (the IME types the Option character).
    pumpChord(w, probe, chordKey(w, @"‘", 30, opt), YES, @"‘");
    const uint32_t chords[] = {
        30u | (ZENIT_CHORD_OPTION << 16),
        33u | (ZENIT_CHORD_OPTION << 16),
        42u | (ZENIT_CHORD_OPTION << 16),
        30u | (ZENIT_CHORD_CONTROL << 16),
    };
    macos_set_reserved_key_chords(ptr, chords, 4);
    pumpChord(w, probe, chordKey(w, @"‘", 30, opt), NO, @"");
    pumpChord(w, probe, chordKey(w, @"“", 33, opt), NO, @"");
    pumpChord(w, probe, chordKey(w, @"«", 42, opt), NO, @"");
    pumpChord(w, probe, chordKey(w, @"‘", 30, opt | NSEventModifierFlagCapsLock), NO, @"");
    // Exact modifier match: ⌥⇧] and ⌘⌥] are not reserved; nor is ⌥p.
    pumpChord(w, probe, chordKey(w, @"’", 30, opt | NSEventModifierFlagShift), YES, @"’");
    pumpChord(w, probe, chordKey(w, @"π", 35, opt), YES, @"π");
    // A composition in progress owns the key.
    [w.metalView setMarkedText:@"n" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.imePreeditQueue removeAllObjects];
    {
        const NSUInteger calls = probe.calls;
        enqueue(@[chordKey(w, @"‘", 30, opt)]);
        for (int i = 0; i < 8 && probe.calls == calls; i++) pumpAppEventsWithTimeout(0);
        assert(probe.calls == calls + 1);
        [w.metalView unmarkText];
        dispatchToClient(w);
    }
    // Replacing the table with an empty one restores interpretation.
    macos_set_reserved_key_chords(ptr, NULL, 0);
    pumpChord(w, probe, chordKey(w, @"‘", 30, opt), YES, @"‘");
    // A table over the cap is truncated, never overflows.
    uint32_t many[40];
    for (int i = 0; i < 40; i++) many[i] = (uint32_t)(100 + i) | (ZENIT_CHORD_OPTION << 16);
    many[39] = 30u | (ZENIT_CHORD_OPTION << 16);
    macos_set_reserved_key_chords(ptr, many, 40);
    assert(w.reservedKeyChords.length == 32 * sizeof(uint32_t));
    pumpChord(w, probe, chordKey(w, @"‘", 30, opt), YES, @"‘");
    macos_set_reserved_key_chords(ptr, NULL, 0);
    [document setString:@""];
    macos_set_text_input_enabled(ptr, 0);
    fprintf(stderr, "PASS: reserved chords reach Zig without IME text; exact match, caps lock, composition and clear\n");
}

static void verifyKeyboardIsolation(WindowWrapper *w, PumpInputContext *probe) {
    void *ptr = (__bridge void *)w;
    dispatchToClient(w);
    assert(!w.keyboardIsolated);
    macos_set_text_input_enabled(ptr, 1);
    macos_set_keyboard_isolated(ptr, 1);
    NSUInteger calls = probe.calls;
    NSEvent *quit = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:NSEventModifierFlagCommand timestamp:0
        windowNumber:w.window.windowNumber context:nil characters:@"q"
        charactersIgnoringModifiers:@"q" isARepeat:NO keyCode:12];
    NSEvent *close = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:NSEventModifierFlagCommand | NSEventModifierFlagShift timestamp:0
        windowNumber:w.window.windowNumber context:nil characters:@"W"
        charactersIgnoringModifiers:@"W" isARepeat:NO keyCode:13];
    enqueue(@[quit, close, key(w, @"x", 7)]);
    for (int i = 0; i < 4; ++i) pumpAppEventsWithTimeout(0);
    assert(!w.shouldClose && !g_app_should_quit);
    assert(probe.calls == calls);
    assert(w.keyEventQueue.count == 0 && w.inputTextQueue.count == 0);
    // Asynchronous candidate callbacks must not mutate native marked state.
    [w.metalView setMarkedText:@"candidate" selectedRange:NSMakeRange(1, 0)
        replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.metalView insertText:@"candidate" replacementRange:NSMakeRange(NSNotFound, 0)];
    assert(w.imePreeditQueue.count == 0 && w.imeCommitQueue.count == 0);
    assert(w.inputTextQueue.count == 0 && !w.metalView.hasMarkedText);
    // Isolation belongs to the target window, not the process or key window.
    void *otherPtr = macos_create_window(200, 100, "input isolation other window");
    assert(otherPtr);
    WindowWrapper *other = (__bridge WindowWrapper *)otherPtr;
    assert(!other.keyboardIsolated);
    PumpInputContext *otherProbe = [[PumpInputContext alloc] initWithClient:other.metalView];
    otherProbe.selections = [NSMutableArray array];
    other.metalView.zenitInputContext = otherProbe;
    other.lastKeyboardInputSource = otherProbe.selectedKeyboardInputSource;
    macos_set_text_input_enabled(otherPtr, 1);
    enqueue(@[key(other, @"b", 11)]);
    pumpAppEventsWithTimeout(0);
    assert(otherProbe.calls == 1 && other.keyEventQueue.count == 1);
    assert(probe.calls == calls && w.keyEventQueue.count == 0);
    dispatchToClient(other);
    macos_destroy_window(otherPtr);
    macos_set_keyboard_isolated(ptr, 0);
    enqueue(@[key(w, @"x", 7)]);
    pumpAppEventsWithTimeout(0);
    assert(probe.calls == calls + 1 && w.keyEventQueue.count == 1);
    dispatchToClient(w);
    fprintf(stderr, "PASS: per-window keyboard isolation blocks quit/close/IME, preserves other windows and restores normal input\n");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        testScrollDeltaUnits();
        macos_init_app();
        void *ptr = macos_create_window(400, 240, "zenit input pump regression");
        assert(ptr);
        WindowWrapper *w = (__bridge WindowWrapper *)ptr;
        document = [NSMutableString string];
        verifyCandidateAnchor(w);
        verifyScrollNormalization(w);
        verifyScrollLifecycle(w);
        if (argc == 2 && strcmp(argv[1], "--system-ime") == 0) {
            // Real keyboard delivery requires an active application. Wait on
            // that OS condition only, never on IME readiness or a fixed delay.
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
            [[NSRunningApplication currentApplication] activateWithOptions:
                NSApplicationActivateIgnoringOtherApps | NSApplicationActivateAllWindows];
            while ((!NSApp.active || !w.window.keyWindow) && deadline.timeIntervalSinceNow > 0) {
                pumpAppEventsWithTimeout(10);
                dispatchToClient(w);
            }
            if (!NSApp.active || !w.window.keyWindow) {
                fprintf(stderr, "FAIL: OS activation precondition active=%d key=%d\n",
                        NSApp.active, w.window.keyWindow);
                macos_destroy_window(ptr);
                return 2;
            }
            NSString *source = w.metalView.inputContext.selectedKeyboardInputSource;
            const BOOL chinese = [source isEqualToString:@"com.apple.inputmethod.SCIM.WBX"] ||
                [source isEqualToString:@"com.apple.inputmethod.SCIM.ITABC"];
            const BOOL japanese = [source isEqualToString:@"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"];
            if (!chinese && !japanese) {
                fprintf(stderr, "SKIP: --system-ime supports Apple Wubi/Pinyin/Japanese\n");
                macos_destroy_window(ptr);
                return 3;
            }
            // No activation warmup or sacrificial key: exercise the current
            // system input method on this window's first text key.
            macos_set_text_input_enabled(ptr, 1);
            verifySystemComposition(w, japanese);
            fprintf(stderr, "PASS: system IME first key composes and commits without warmup\n");

            void *childPtr = macos_create_window(400, 240, "input child");
            WindowWrapper *child = (__bridge WindowWrapper *)childPtr;
            macos_set_text_input_enabled(childPtr, 1);
            verifySystemComposition(child, japanese);
            macos_begin_window_close(childPtr);
            [w.window makeKeyAndOrderFront:nil];
            deadline = [NSDate dateWithTimeIntervalSinceNow:3];
            while (!macos_window_close_completed(childPtr) && deadline.timeIntervalSinceNow > 0) {
                pumpAppEventsWithTimeout(10);
                dispatchToClient(child);
                dispatchToClient(w);
            }
            assert(macos_window_close_completed(childPtr));
            macos_destroy_window(childPtr);
            verifySystemComposition(w, japanese);
            fprintf(stderr, "PASS: original window first IME key after child destruction\n");
            macos_destroy_window(ptr);
            return 0;
        }
        verifyUnmarkAndDiscard(w);
        verifyExplicitReplacementCommit(w);
        verifyCompositionStartsNewInsertIdentity(w);
        verifyRejectedReplacement(w);
        verifyAppliedMarkedOrigin(w);
        // Consume startup AppKit notifications before placing a controlled
        // burst at the front of this process's queue.
        for (int i = 0; i < 16; i++) { pumpAppEventsWithTimeout(0); dispatchToClient(w); }
        PumpInputContext *probe = [[PumpInputContext alloc] initWithClient:w.metalView];
        probe.selections = [NSMutableArray array];
        w.metalView.zenitInputContext = probe;
        w.lastKeyboardInputSource = probe.selectedKeyboardInputSource;
        verifyKeyboardIsolation(w, probe);
        verifyReservedChords(w, probe);
        verifyQueuedTextBeforeFocusClick(w, probe);

        // First click and first key queued together: the old pump consumed
        // both with textInputEnabled=NO and irretrievably lost the first key.
        for (int iteration = 0; iteration < 32; iteration++) {
            [document setString:@""];
            probe.calls = 0;
            [probe.selections removeAllObjects];
            macos_set_text_input_enabled(ptr, 0);
            dispatchToClient(w);
            enqueue(@[click(w, NSEventTypeLeftMouseDown), click(w, NSEventTypeLeftMouseUp),
                      key(w, @"a", 0), key(w, @"b", 11)]);
            for (int i = 0; i < 8; i++) { pumpAppEventsWithTimeout(0); dispatchToClient(w); }
            assert([document isEqualToString:@"ab"]);
            assert(probe.calls == 2);
            assert(([probe.selections isEqualToArray:@[@0, @1]]));
        }
        fprintf(stderr, "PASS: 32 click + first-key bursts and live selection ordering\n");

        // A preedit produced outside the pump must reach Zig even when the
        // next pump was asked to block indefinitely. It must also precede
        // the already queued key's live-client query.
        [document setString:@""];
        [probe.selections removeAllObjects];
        zenitEnqueueInputText(w, @"x");
        enqueue(@[key(w, @"y", 16)]);
        pumpAppEventsWithTimeout(UINT32_MAX);
        assert(probe.selections.count == 0);
        dispatchToClient(w);
        pumpAppEventsWithTimeout(0);
        dispatchToClient(w);
        assert([document isEqualToString:@"xy"]);
        assert([probe.selections isEqualToArray:@[@1]]);
        fprintf(stderr, "PASS: out-of-pump text is dispatched before waiting/interpreting\n");

        // An IMK callback can run *inside* nextEvent's wait without producing
        // a keyboard NSEvent. It must wake the app, not wait for another key.
        for (int i = 0; i < 8; i++) { pumpAppEventsWithTimeout(0); dispatchToClient(w); }
        __block BOOL callbackRan = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            callbackRan = YES;
            zenitEnqueueInputText(w, @"z");
        });
        NSDate *waitStart = [NSDate date];
        pumpAppEventsWithTimeout(2000);
        assert(callbackRan);
        assert(-waitStart.timeIntervalSinceNow < 1.0);
        assert(w.inputTextQueue.count == 1);
        dispatchToClient(w);
        assert([document isEqualToString:@"xyz"]);
        fprintf(stderr, "PASS: asynchronous text callback wakes an idle native pump\n");

        // The same first-key ordering must apply to composition callbacks.
        macos_set_text_input_enabled(ptr, 0);
        dispatchToClient(w);
        probe.compose = YES;
        probe.calls = 0;
        enqueue(@[click(w, NSEventTypeLeftMouseDown), key(w, @"n", 45)]);
        BOOL sawPreedit = NO;
        for (int i = 0; i < 4; i++) {
            pumpAppEventsWithTimeout(0);
            for (ZenitTextEventPacket *packet in w.imePreeditQueue)
                if ([packet.text isEqualToString:@"n"]) sawPreedit = YES;
            dispatchToClient(w);
        }
        assert(probe.calls == 1 && sawPreedit);
        fprintf(stderr, "PASS: first composition key after focus transition\n");
        macos_destroy_window(ptr);
    }
    return 0;
}
