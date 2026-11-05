// The pasteboard behind the application clipboard (text, rich text and images).
//
// ZENIT_E2E_PASTEBOARD=<name> moves the clipboard onto a private named pasteboard. E2E
// launchers give every app instance its own name, so instances running in parallel cannot read
// each other's copies and a test run never overwrites the developer's clipboard. Unset, the
// system general pasteboard is used, as in every shipped app.
//
// Each translation unit that includes this header keeps its own cached pointer; the choice is a
// pure function of the environment at first use, so all of them agree.
#pragma once
#import <AppKit/AppKit.h>
#include <stdlib.h>

static void zenitReleasePrivatePasteboard(void);
static NSPasteboard *g_zenit_private_pasteboard;

static inline NSPasteboard *zenitClipboardPasteboard(void) {
    static NSPasteboard *pasteboard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *name = getenv("ZENIT_E2E_PASTEBOARD");
        if (name && name[0]) {
            pasteboard = [NSPasteboard pasteboardWithName:[NSString stringWithUTF8String:name]];
            g_zenit_private_pasteboard = pasteboard;
            // A named pasteboard outlives the process in pboard's server until released.
            atexit(zenitReleasePrivatePasteboard);
        } else {
            pasteboard = [NSPasteboard generalPasteboard];
        }
    });
    return pasteboard;
}

static void zenitReleasePrivatePasteboard(void) {
    @autoreleasepool {
        [g_zenit_private_pasteboard releaseGlobally];
    }
}
