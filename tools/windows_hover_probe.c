/* Native Win32 reference for hover liveness (docs/UI_FRAMEWORK_CORE.md, "Hover Under a Stationary
 * Pointer"). Runs on the Windows acceptance machine as a batch probe (tools/windows_batch.py stage
 * `hover-probe`) and drives REAL input there: SetCursorPos / SendInput move the test machine's
 * cursor and wheel. Never run it on a machine someone is using.
 *
 * Window A (this process) has a plain client area with TrackMouseEvent(TME_LEAVE) like Zenit's
 * window bridge, plus a standard Explorer-themed ListView. Window B is another process (this exe
 * with --foreign) that takes activation and covers / uncovers the cursor.
 *
 * Measures, with the cursor stationary where it matters:
 *   - WM_MOUSEMOVE / WM_MOUSEWHEEL reach A while B is the foreground window;
 *   - wheel routing setting (SPI_GETMOUSEWHEELROUTING);
 *   - the ListView's own motion and hot item while it is wheel-scrolled inactive;
 *   - WM_MOUSELEAVE when B is ordered over the resting cursor, WM_MOUSEMOVE when it moves away;
 *   - WM_MOUSELEAVE after a captured drag is released over B without further motion;
 *   - WM_MOUSELEAVE when the cursor moves off A.
 * Output: `HOVERPROBE_JSON {...}` on stdout, `PASS:`/`FAIL:`/`INFO:` lines on stderr; exit 0 only
 * if every fact the Zenit design relies on holds. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>
#include <stdio.h>
#include <string.h>

#ifndef SPI_GETMOUSEWHEELROUTING
#define SPI_GETMOUSEWHEELROUTING 0x201C
#endif

static const wchar_t *kClassA = L"ZenitHoverProbeA";
static const wchar_t *kClassB = L"ZenitHoverProbeForeign";

typedef struct {
    int moves, leaves, wheels, lv_moves, lv_leaves;
    double last_move_ms, last_leave_ms, last_wheel_ms;
} Counters;
static Counters c;
static HWND a_hwnd, list_hwnd;
static int a_tracking, lv_tracking;
static LARGE_INTEGER freq, t_origin;
static int failures;

static double now_ms(void) {
    LARGE_INTEGER t; QueryPerformanceCounter(&t);
    return (double)(t.QuadPart - t_origin.QuadPart) * 1000.0 / (double)freq.QuadPart;
}
static void reset(void) { memset(&c, 0, sizeof c); }
static void pump(int ms) {
    double end = now_ms() + ms;
    while (now_ms() < end) {
        MSG m;
        while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageW(&m); }
        Sleep(2);
    }
}
static void fact(int required, int ok, const char *what) {
    fprintf(stderr, "%s: %s\n", ok ? "PASS" : (required ? "FAIL" : "INFO"), what);
    if (required && !ok) failures++;
}

static LRESULT CALLBACK list_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR ref) {
    (void)id; (void)ref;
    if (msg == WM_MOUSEMOVE) {
        c.lv_moves++;
    } else if (msg == WM_MOUSELEAVE) {
        c.lv_leaves++;
    }
    return DefSubclassProc(h, msg, wp, lp);
}

static LRESULT CALLBACK proc_a(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_MOUSEMOVE:
        if (!a_tracking) {
            TRACKMOUSEEVENT t = {sizeof t, TME_LEAVE, h, 0};
            if (TrackMouseEvent(&t)) a_tracking = 1;
        }
        c.moves++; c.last_move_ms = now_ms();
        return 0;
    case WM_MOUSELEAVE:
        a_tracking = 0; c.leaves++; c.last_leave_ms = now_ms();
        return 0;
    case WM_MOUSEWHEEL:
        c.wheels++; c.last_wheel_ms = now_ms();
        return 0;
    case WM_LBUTTONDOWN: SetCapture(h); return 0;   /* like Zenit's bridge */
    case WM_LBUTTONUP: if (GetCapture() == h) ReleaseCapture(); return 0;
    case WM_ERASEBKGND: {
        RECT r; GetClientRect(h, &r);
        FillRect((HDC)wp, &r, (HBRUSH)(COLOR_WINDOW + 1));
        return 1;
    }
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static LRESULT CALLBACK proc_b(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    if (msg == WM_ERASEBKGND) {
        RECT r; GetClientRect(h, &r);
        HBRUSH b = CreateSolidBrush(RGB(200, 60, 60)); FillRect((HDC)wp, &r, b); DeleteObject(b);
        return 1;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static int foreign_main(HINSTANCE inst) {
    WNDCLASSW wc = {0}; wc.lpfnWndProc = proc_b; wc.hInstance = inst; wc.lpszClassName = kClassB;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    HWND b = CreateWindowExW(0, kClassB, L"Zenit hover probe: foreign app", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                             20, 20, 240, 180, NULL, NULL, inst, NULL);
    if (!b) return 2;
    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) { TranslateMessage(&m); DispatchMessageW(&m); }
    return 0;
}

static void send_alt(void) {
    INPUT in[2] = {0};
    in[0].type = INPUT_KEYBOARD; in[0].ki.wVk = VK_MENU;
    in[1].type = INPUT_KEYBOARD; in[1].ki.wVk = VK_MENU; in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
}
/* Foreground for an arbitrary top-level window of either process (test machine only). */
static int force_foreground(HWND h) {
    for (int attempt = 0; attempt < 5; attempt++) {
        if (GetForegroundWindow() == h) return 1;
        AllowSetForegroundWindow(ASFW_ANY);
        send_alt();
        DWORD fg_thread = GetWindowThreadProcessId(GetForegroundWindow(), NULL);
        DWORD me = GetCurrentThreadId();
        if (fg_thread && fg_thread != me) AttachThreadInput(me, fg_thread, TRUE);
        SetForegroundWindow(h);
        BringWindowToTop(h);
        if (fg_thread && fg_thread != me) AttachThreadInput(me, fg_thread, FALSE);
        pump(150);
    }
    return GetForegroundWindow() == h;
}
static void wheel(int delta) {
    INPUT in = {0}; in.type = INPUT_MOUSE; in.mi.dwFlags = MOUSEEVENTF_WHEEL; in.mi.mouseData = (DWORD)delta;
    SendInput(1, &in, sizeof in);
}
static void button(int down) {
    INPUT in = {0}; in.type = INPUT_MOUSE; in.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
    SendInput(1, &in, sizeof in);
}
static POINT client_to_screen(HWND h, int x, int y) { POINT p = {x, y}; ClientToScreen(h, &p); return p; }

static HWND find_foreign(DWORD pid) {
    for (int i = 0; i < 200; i++) {
        HWND h = NULL;
        while ((h = FindWindowExW(NULL, h, kClassB, NULL)) != NULL) {
            DWORD owner = 0; GetWindowThreadProcessId(h, &owner);
            if (owner == pid) return h;
        }
        Sleep(25);
    }
    return NULL;
}

/* Entry from tools/windows_hover_probe.zig (the Zig root owns process start-up). */
int zenit_windows_hover_probe_main(void) {
    HINSTANCE inst = GetModuleHandleW(NULL);
    const wchar_t *cmd = GetCommandLineW();
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (cmd && wcsstr(cmd, L"--foreign")) return foreign_main(inst);
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&t_origin);
    INITCOMMONCONTROLSEX icc = {sizeof icc, ICC_LISTVIEW_CLASSES}; InitCommonControlsEx(&icc);
    POINT saved; GetCursorPos(&saved);

    WNDCLASSW wc = {0}; wc.lpfnWndProc = proc_a; wc.hInstance = inst; wc.lpszClassName = kClassA;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    RECT outer = {0, 0, 640, 400};
    AdjustWindowRectExForDpi(&outer, WS_OVERLAPPEDWINDOW, FALSE, 0, GetDpiForSystem());
    a_hwnd = CreateWindowExW(0, kClassA, L"Zenit hover probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                             120, 120, outer.right - outer.left, outer.bottom - outer.top, NULL, NULL, inst, NULL);
    RECT client; GetClientRect(a_hwnd, &client);
    const int half = client.right / 2;
    list_hwnd = CreateWindowExW(0, WC_LISTVIEWW, L"", WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_NOCOLUMNHEADER,
                                half, 0, client.right - half, client.bottom, a_hwnd, NULL, inst, NULL);
    SetWindowTheme(list_hwnd, L"Explorer", NULL);
    ListView_SetExtendedListViewStyle(list_hwnd, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
    LVCOLUMNW col = {LVCF_WIDTH, 0, client.right - half - 30};
    ListView_InsertColumn(list_hwnd, 0, &col);
    for (int i = 0; i < 200; i++) {
        wchar_t text[32]; swprintf(text, 32, L"Row %03d", i);
        LVITEMW item = {LVIF_TEXT, i}; item.pszText = text;
        ListView_InsertItem(list_hwnd, &item);
    }
    SetWindowSubclass(list_hwnd, list_proc, 1, 0);

    wchar_t self[MAX_PATH]; GetModuleFileNameW(NULL, self, MAX_PATH);
    wchar_t line[MAX_PATH + 16]; swprintf(line, MAX_PATH + 16, L"\"%s\" --foreign", self);
    STARTUPINFOW si = {sizeof si}; PROCESS_INFORMATION pi = {0};
    if (!CreateProcessW(NULL, line, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "FAIL: foreign process did not start (%lu)\n", GetLastError());
        return 2;
    }
    HWND b = find_foreign(pi.dwProcessId);
    if (!b) { fprintf(stderr, "FAIL: foreign window missing\n"); TerminateProcess(pi.hProcess, 1); return 2; }
    RECT ar; GetWindowRect(a_hwnd, &ar);
    SetWindowPos(b, HWND_TOP, ar.right + 40, ar.top, 240, 180, SWP_NOACTIVATE);
    pump(300);

    const POINT pt = client_to_screen(a_hwnd, half / 2, client.bottom / 2);
    UINT routing = 0xFFFFFFFF; SystemParametersInfoW(SPI_GETMOUSEWHEELROUTING, 0, &routing, 0);

    /* 1. active baseline */
    int a_fg = force_foreground(a_hwnd);
    SetCursorPos(pt.x, pt.y); pump(100); reset();
    SetCursorPos(pt.x + 6, pt.y + 3); pump(250);
    int active_moves = c.moves;

    /* 2. another process takes the foreground */
    int b_fg = force_foreground(b);
    pump(200);
    /* 3. motion over the inactive window */
    reset(); SetCursorPos(pt.x, pt.y); pump(300);
    int inactive_moves = c.moves;
    /* 4. wheel over the inactive window (stationary cursor) */
    reset(); wheel(-WHEEL_DELTA); pump(300);
    int inactive_wheels = c.wheels, wheel_synth_moves = c.moves;

    /* 5. the standard ListView, inactive, wheel-scrolled under a resting cursor */
    RECT row; ListView_GetItemRect(list_hwnd, 3, &row, LVIR_BOUNDS);
    POINT lp = client_to_screen(list_hwnd, (row.left + row.right) / 2, (row.top + row.bottom) / 2);
    SetCursorPos(lp.x, lp.y); pump(300);
    int lv_hot_before = ListView_GetHotItem(list_hwnd), lv_top_before = ListView_GetTopIndex(list_hwnd);
    reset(); wheel(-WHEEL_DELTA); pump(400);
    int lv_top_after = ListView_GetTopIndex(list_hwnd), lv_hot_after = ListView_GetHotItem(list_hwnd);
    LVHITTESTINFO hit = {0}; POINT lc = lp; ScreenToClient(list_hwnd, &lc); hit.pt = lc;
    int lv_under_after = ListView_HitTest(list_hwnd, &hit);
    int lv_moves_after_wheel = c.lv_moves;

    /* 6. B ordered over the resting cursor (no activation change: B stays foreground) */
    SetCursorPos(pt.x, pt.y); pump(250); reset();
    double t0 = now_ms();
    SetWindowPos(b, HWND_TOPMOST, pt.x - 100, pt.y - 80, 200, 160, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    pump(500);
    int cover_leaves = c.leaves; double cover_leave_ms = c.leaves ? c.last_leave_ms - t0 : -1;
    int cover_moves = c.moves;
    /* 7. B moves away from the resting cursor */
    reset(); t0 = now_ms();
    SetWindowPos(b, HWND_NOTOPMOST, ar.right + 40, ar.top, 240, 180, SWP_NOACTIVATE);
    pump(500);
    int uncover_moves = c.moves; double uncover_move_ms = c.moves ? c.last_move_ms - t0 : -1;

    /* 8. captured drag released over B without further motion */
    int a_fg2 = force_foreground(a_hwnd);
    POINT pt2 = client_to_screen(a_hwnd, half / 4, client.bottom / 4);
    SetWindowPos(b, HWND_TOPMOST, pt2.x - 60, pt2.y - 40, 120, 80, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetCursorPos(pt.x, pt.y); pump(200);
    button(1); pump(150);
    int captured = GetCapture() == a_hwnd;
    SetCursorPos(pt2.x, pt2.y); pump(150);
    reset(); button(0); t0 = now_ms(); pump(600);
    int release_leaves = c.leaves; double release_leave_ms = c.leaves ? c.last_leave_ms - t0 : -1;
    SetWindowPos(b, HWND_NOTOPMOST, ar.right + 40, ar.top, 240, 180, SWP_NOACTIVATE);

    /* 9. cursor moves off A onto the desktop */
    SetCursorPos(pt.x, pt.y); pump(250); reset();
    SetCursorPos(ar.left + (ar.right - ar.left) / 2, ar.bottom + 60); pump(400);
    int out_leaves = c.leaves;

    printf("HOVERPROBE_JSON {\"wheel_routing\":%u,\"foreground\":{\"a\":%d,\"b\":%d,\"a_again\":%d},"
           "\"active_moves\":%d,\"inactive_moves\":%d,\"inactive_wheels\":%d,\"wheel_synthesized_moves\":%d,"
           "\"listview\":{\"hot_before\":%d,\"top_before\":%d,\"top_after\":%d,\"hot_after\":%d,\"under_after\":%d,\"moves_after_wheel\":%d},"
           "\"cover\":{\"leaves\":%d,\"leave_ms\":%.1f,\"moves\":%d},\"uncover\":{\"moves\":%d,\"move_ms\":%.1f},"
           "\"release_over_other\":{\"captured\":%d,\"leaves\":%d,\"leave_ms\":%.1f},\"move_out\":{\"leaves\":%d}}\n",
           routing, a_fg, b_fg, a_fg2, active_moves, inactive_moves, inactive_wheels, wheel_synth_moves,
           lv_hot_before, lv_top_before, lv_top_after, lv_hot_after, lv_under_after, lv_moves_after_wheel,
           cover_leaves, cover_leave_ms, cover_moves, uncover_moves, uncover_move_ms,
           captured, release_leaves, release_leave_ms, out_leaves);
    fflush(stdout);

    fact(1, a_fg && b_fg && a_fg2, "foreground switches between the probe and the foreign process");
    fact(1, active_moves > 0, "WM_MOUSEMOVE in the active window");
    fact(1, inactive_moves > 0, "WM_MOUSEMOVE reaches a window while another process is foreground");
    fact(routing != 0, inactive_wheels > 0, "WM_MOUSEWHEEL reaches the inactive window under the cursor (required unless wheel routing is focus-only)");
    fact(0, lv_top_after != lv_top_before, "the standard ListView scrolls while inactive");
    fact(0, lv_hot_after == lv_under_after, "the ListView's hot item follows the row under the resting cursor after an inactive scroll");
    fact(1, cover_leaves > 0, "WM_MOUSELEAVE when another process's window is ordered over the resting cursor");
    fact(1, uncover_moves > 0, "WM_MOUSEMOVE at the resting cursor when the covering window moves away");
    fact(0, captured && release_leaves > 0, "WM_MOUSELEAVE after a captured drag is released over another window without motion");
    fact(1, out_leaves > 0, "WM_MOUSELEAVE when the cursor moves off the window");

    PostMessageW(b, WM_CLOSE, 0, 0);
    WaitForSingleObject(pi.hProcess, 3000);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    SetCursorPos(saved.x, saved.y);
    DestroyWindow(a_hwnd);
    fprintf(stderr, "hover probe complete: %d required fact(s) failed\n", failures);
    return failures ? 1 : 0;
}
