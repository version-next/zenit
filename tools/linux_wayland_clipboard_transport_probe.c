/* Exercise the production transfer callbacks against real kernel pipes. No
 * compositor substitute: desktop protocol interoperability has a separate gate. */
#include "../native/linux/wayland/window.c"
#include <assert.h>

static void fixture(ZenitWaylandWindow *w, struct ClipboardState *c) {
    memset(w, 0, sizeof(*w)); memset(c, 0, sizeof(*c));
    w->clipboard = c; c->receive_fd = -1;
    for (size_t i = 0; i < 8; ++i) c->sends[i].fd = -1;
}
static void nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    assert(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0);
}
static void transfer(size_t length, int over_limit) {
    ZenitWaylandWindow w; struct ClipboardState c; fixture(&w, &c);
    int fds[2]; assert(pipe(fds) == 0); nonblocking(fds[0]);
    unsigned char *source = malloc(length); assert(source);
    for (size_t i = 0; i < length; ++i) source[i] = (unsigned char)(i % 251);
    struct ClipboardSource owner = {.window = &w, .bytes = source, .length = length};
    clipboard_source_send(&owner, NULL, clipboard_mimes[0], fds[1]);
    assert(c.sends[0].fd == fds[1]);
    /* Replacing/freeing source contents cannot alter a queued transfer. */
    memset(source, 0, length); free(source); owner.bytes = NULL;
    clipboard_io(&w);
    assert(c.sends[0].offset > 0 && c.sends[0].offset < length);
    size_t stalled = c.sends[0].offset;
    int64_t start = keyboard_now();
    for (int i = 0; i < 100; ++i) clipboard_io(&w);
    assert(c.sends[0].offset == stalled);
    assert(keyboard_now() - start < 100000000LL);
    c.receive_fd = fds[0];
    int64_t deadline = keyboard_now() + 1000000000LL;
    while (c.receive_fd >= 0 && keyboard_now() < deadline) clipboard_io(&w);
    assert(c.receive_fd == -1);
    if (over_limit) {
        assert(c.receive_status == -2 && !c.cache_valid && c.length == 0);
        /* EPIPE after rejection must retire the independent sender safely. */
        clipboard_io(&w); assert(c.sends[0].fd == -1);
    } else {
        assert(c.receive_status == 0 && c.cache_valid && c.length == length);
        for (size_t i = 0; i < length; ++i) assert(c.received[i] == (unsigned char)(i % 251));
        assert(c.sends[0].fd == -1);
    }
    free(c.received);
}
static void bounded_jobs(void) {
    ZenitWaylandWindow w; struct ClipboardState c; fixture(&w, &c);
    unsigned char bytes[2] = {1, 2};
    struct ClipboardSource owner = {.window = &w, .bytes = bytes, .length = sizeof(bytes)};
    int readers[9];
    for (int i = 0; i < 9; ++i) {
        int fds[2]; assert(pipe(fds) == 0); readers[i] = fds[0];
        clipboard_source_send(&owner, NULL, clipboard_mimes[1], fds[1]);
        if (i == 8) { errno = 0; assert(fcntl(fds[1], F_GETFD) == -1 && errno == EBADF); }
    }
    struct pollfd pfds[9]; assert(clipboard_pollfds(&w, pfds) == 8);
    for (int i = 0; i < 8; ++i) {
        assert(pfds[i].events == POLLOUT);
        c.sends[i].deadline = keyboard_now() - 1;
    }
    clipboard_io(&w); assert(clipboard_pollfds(&w, pfds) == 0);
    for (int i = 0; i < 9; ++i) {
        unsigned char byte; assert(read(readers[i], &byte, 1) == 0); close(readers[i]);
    }
}
static void broken_receiver_and_signal(void) {
    int fds[2]; assert(pipe(fds) == 0); close(fds[0]);
    sigset_t before, after, block, pending;
    assert(pthread_sigmask(SIG_SETMASK, NULL, &before) == 0);
    errno = 0; assert(clipboard_write(fds[1], "x", 1) == -1 && errno == EPIPE);
    assert(pthread_sigmask(SIG_SETMASK, NULL, &after) == 0);
    assert(sigismember(&before, SIGPIPE) == sigismember(&after, SIGPIPE));
    assert(sigpending(&pending) == 0 && !sigismember(&pending, SIGPIPE));
    sigemptyset(&block); sigaddset(&block, SIGPIPE);
    assert(pthread_sigmask(SIG_BLOCK, &block, NULL) == 0);
    assert(raise(SIGPIPE) == 0);
    assert(clipboard_write(fds[1], "x", 1) == -1 && errno == EPIPE);
    assert(sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE));
    struct timespec zero = {0}; assert(sigtimedwait(&block, NULL, &zero) == SIGPIPE);
    assert(pthread_sigmask(SIG_SETMASK, &before, NULL) == 0);
    close(fds[1]);
    ZenitWaylandWindow w; struct ClipboardState c; fixture(&w, &c);
    assert(pipe(fds) == 0); close(fds[0]);
    unsigned char bytes[1] = {1};
    struct ClipboardSource owner = {.window = &w, .bytes = bytes, .length = 1};
    clipboard_source_send(&owner, NULL, clipboard_mimes[0], fds[1]);
    clipboard_io(&w); assert(c.sends[0].fd == -1);
}
static void empty_and_cancel(void) {
    ZenitWaylandWindow w; struct ClipboardState c; fixture(&w, &c);
    int fds[2]; assert(pipe(fds) == 0); nonblocking(fds[0]);
    unsigned char byte = 0;
    struct ClipboardSource owner = {.window = &w, .bytes = &byte, .length = 0};
    clipboard_source_send(&owner, NULL, clipboard_mimes[2], fds[1]);
    c.receive_fd = fds[0]; clipboard_io(&w);
    assert(c.cache_valid && c.length == 0 && c.receive_fd == -1 && c.sends[0].fd == -1);
    assert(pipe(fds) == 0); c.receive_fd = fds[0]; c.cache_valid = 1; c.length = 7;
    clipboard_cancel_receive(&c, -5);
    assert(c.receive_status == -5 && !c.cache_valid && c.length == 0 && c.receive_fd == -1);
    errno = 0; assert(fcntl(fds[0], F_GETFD) == -1 && errno == EBADF); close(fds[1]);
}
static void png_transport_and_decode(void) {
    static const unsigned char png[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,2,0,0,0,2,8,6,0,0,0,114,182,13,36,0,0,0,22,73,68,65,84,120,156,99,248,207,192,240,31,8,27,24,64,180,77,84,133,3,0,57,15,5,203,181,36,37,1,0,0,0,0,73,69,78,68,174,66,96,130};
    const unsigned char expected[] = {255,0,0,255,0,128,0,128,0,0,0,0,15,23,30,64};
    ZenitClipboardPng image;
    assert(zenit_wayland_decode_png(png, sizeof(png), &image) == 0);
    assert(image.width == 2 && image.height == 2 && !memcmp(image.rgba, expected, sizeof(expected)));
    zenit_wayland_free_png(&image);
    assert(image.rgba == NULL && image.width == 0 && image.height == 0);
    assert(zenit_wayland_decode_png(png, 12, &image) < 0 && image.rgba == NULL);
    assert(zenit_wayland_decode_png((const unsigned char *)"not png", 7, &image) < 0 && image.rgba == NULL);
    ZenitWaylandWindow w; struct ClipboardState c; fixture(&w, &c);
    unsigned char owned[sizeof(png)]; memcpy(owned, png, sizeof(png));
    struct ClipboardSource source = {.window = &w, .bytes = owned, .length = sizeof(owned), .mime_mask = 8};
    int fds[2]; assert(pipe(fds) == 0);
    clipboard_source_send(&source, NULL, clipboard_mimes[0], fds[1]);
    assert(fcntl(fds[1], F_GETFD) == -1 && errno == EBADF); close(fds[0]);
    assert(pipe(fds) == 0); nonblocking(fds[0]);
    clipboard_source_send(&source, NULL, clipboard_mimes[3], fds[1]);
    memset(owned, 0, sizeof(owned)); c.receive_fd = fds[0];
    clipboard_io(&w);
    assert(c.cache_valid && c.length == sizeof(png) && !memcmp(c.received, png, sizeof(png)));
    free(c.received);
}
int zenit_clipboard_transport_contract(void) {
    transfer(1024u * 1024u, 0);
    transfer(CLIPBOARD_LIMIT, 0);
    transfer(CLIPBOARD_LIMIT + 1u, 1);
    bounded_jobs(); broken_receiver_and_signal(); empty_and_cancel(); png_transport_and_decode();
    puts("CLIPBOARD_TRANSPORT PASS: 1MiB/16MiB exact snapshots, backpressure, 16MiB+1 rejection, eight-job bound, expiry, EPIPE, SIGPIPE preservation, empty EOF, receive cancellation, PNG MIME isolation/snapshot/alpha decode");
    return 0;
}
