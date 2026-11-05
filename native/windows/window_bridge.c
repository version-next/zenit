#include "../window_chrome.h"
#define WIN32_LEAN_AND_MEAN
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define COBJMACROS
#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <imm.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdio.h>
#include <wchar.h>
#include <math.h>
#include <dwmapi.h>
#include "drop_bridge.h"
#include "drag_source.h"
#include "accessibility_bridge.h"
#include "window_geometry.h"

/* Only lock acquisition is retried; never repeat clipboard mutations or pump
   messages here. A busy reader/sync agent must not make ordinary copy/paste
   fail immediately, and a persistent lock must not stall the UI indefinitely. */
#ifdef ZENIT_WINDOW_CONTRACT
static int contract_background_windows = -1;
int zenit_windows_contract_background(int enabled) {
    int previous = contract_background_windows;
    contract_background_windows = enabled;
    return previous;
}
static unsigned clipboard_busy_attempts;
unsigned zenit_win_contract_clipboard_busy_attempts(void) { return clipboard_busy_attempts; }
#endif
static int clipboard_open(HWND owner) {
    ULONGLONG deadline = GetTickCount64() + 100;
    for (;;) {
        if (OpenClipboard(owner)) return 1;
        DWORD error = GetLastError();
#ifdef ZENIT_WINDOW_CONTRACT
        if (error == ERROR_ACCESS_DENIED) ++clipboard_busy_attempts;
#endif
        if (error != ERROR_ACCESS_DENIED || GetTickCount64() >= deadline) {
            SetLastError(error);
            return 0;
        }
        Sleep(5);
    }
}

/* Window title after creation (taskbar, Alt+Tab, UIA name). Returns 0 on
 * invalid UTF-8 or a dead window. */
int zenit_win_set_title(void *owner, const char *title) {
    if (!owner || !IsWindow((HWND)owner) || !title) return 0;
    int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, title, -1, NULL, 0);
    if (chars <= 0) return 0;
    wchar_t *wide = (wchar_t *)malloc((size_t)chars * sizeof(wchar_t));
    if (!wide) return 0;
    int ok = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, title, -1, wide, chars) == chars &&
        SetWindowTextW((HWND)owner, wide);
    free(wide);
    return ok;
}

/* UTF-8 text clipboard used by the SystemSdk's standard edit commands. */
int zenit_win_clipboard_set_text(void *owner, const char *text, size_t len) {
    if (!owner || !IsWindow((HWND)owner) || !text || len > INT_MAX) return 0;
    int chars = len ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text, (int)len, NULL, 0) : 0;
    if (len && chars <= 0) return 0;
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, ((size_t)chars + 1) * sizeof(wchar_t));
    if (!memory) return 0;
    wchar_t *wide = (wchar_t *)GlobalLock(memory);
    if (!wide) { GlobalFree(memory); return 0; }
    if (chars && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            text, (int)len, wide, chars) != chars) {
        GlobalUnlock(memory); GlobalFree(memory); return 0;
    }
    wide[chars] = 0;
    GlobalUnlock(memory);
    if (!clipboard_open((HWND)owner)) { GlobalFree(memory); return 0; }
    int ok = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory) != NULL;
    if (!ok) GlobalFree(memory);
    CloseClipboard();
    return ok;
}

/* -1 means API failure, -2 means the supplied buffer is too small. */
static int clipboard_text_read(char *buffer, size_t capacity) {
    if (!clipboard_open(NULL)) return -1;
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) { CloseClipboard(); return 0; }
    HGLOBAL memory = GetClipboardData(CF_UNICODETEXT);
    if (!memory) { CloseClipboard(); return -1; }
    const wchar_t *wide = (const wchar_t *)GlobalLock(memory);
    if (!wide) { CloseClipboard(); return -1; }
    size_t max_chars = GlobalSize(memory) / sizeof(wchar_t);
    size_t chars = 0;
    while (chars < max_chars && wide[chars]) ++chars;
    int result = -1;
    if (chars < max_chars && chars <= INT_MAX) {
        int required = chars ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            wide, (int)chars, NULL, 0, NULL, NULL) : 0;
        if (required > 0 || chars == 0) {
            if (!buffer) result = required;
            else if ((size_t)required > capacity) result = -2;
            else result = chars ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                wide, (int)chars, buffer, required, NULL, NULL) : 0;
        }
    }
    GlobalUnlock(memory);
    CloseClipboard();
    return result;
}

int zenit_win_clipboard_get_text_len(void) { return clipboard_text_read(NULL, 0); }
int zenit_win_clipboard_get_text(char *buffer, size_t capacity) {
    return clipboard_text_read(buffer, capacity);
}

#include "clipboard_image.c"

#ifdef ZENIT_WINDOW_CONTRACT
typedef struct ClipboardLockContract {
    HANDLE ready, release, thread;
    DWORD duration;
    HWND hwnd;
    int acquired, closed;
} ClipboardLockContract;
static DWORD WINAPI clipboard_lock_contract_worker(void *opaque) {
    ClipboardLockContract *lock = opaque;
    lock->hwnd = CreateWindowExW(0, L"STATIC", L"Zenit clipboard contract", 0,
        0, 0, 0, 0, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (lock->hwnd) lock->acquired = OpenClipboard(lock->hwnd) != 0;
    SetEvent(lock->ready);
    if (lock->acquired) {
        WaitForSingleObject(lock->release, lock->duration ? lock->duration : INFINITE);
        lock->closed = CloseClipboard() != 0;
    }
    if (lock->hwnd) DestroyWindow(lock->hwnd);
    return 0;
}
int zenit_win_contract_clipboard_unlock(void *opaque) {
    ClipboardLockContract *lock = opaque;
    if (!lock) return 0;
    SetEvent(lock->release);
    if (WaitForSingleObject(lock->thread, 5000) != WAIT_OBJECT_0) ExitProcess(2);
    int ok = lock->acquired && lock->closed;
    CloseHandle(lock->thread); CloseHandle(lock->ready); CloseHandle(lock->release);
    free(lock);
    return ok;
}
void *zenit_win_contract_clipboard_lock(uint32_t duration) {
    ClipboardLockContract *lock = calloc(1, sizeof(*lock));
    if (!lock) return NULL;
    lock->duration = duration;
    lock->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    lock->release = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (lock->ready && lock->release) lock->thread = CreateThread(NULL, 0, clipboard_lock_contract_worker, lock, 0, NULL);
    if (!lock->thread) {
        if (lock->ready) CloseHandle(lock->ready);
        if (lock->release) CloseHandle(lock->release);
        free(lock); return NULL;
    }
    if (WaitForSingleObject(lock->ready, 5000) != WAIT_OBJECT_0 || !lock->acquired ||
        GetOpenClipboardWindow() != lock->hwnd) {
        zenit_win_contract_clipboard_unlock(lock); return NULL;
    }
    return lock;
}
#endif

typedef struct ZenitMenuNode {
    uint64_t id,parent,command;
    const char *label,*key;
    size_t label_len,key_len;
    uint32_t modifiers,role,kind,enabled,checked;
} ZenitMenuNode;
typedef struct ZenitMenuEntry { ZenitMenuNode node; HMENU menu; WORD native_id; int enabled; } ZenitMenuEntry;

typedef struct ZenitWindow {
    HWND hwnd;
    uint32_t requested_width, requested_height;
    HMENU menu;
    HACCEL accelerators;
    ZenitMenuEntry *menu_entries;
    size_t menu_count;
    uint32_t next_menu_id;
    struct { uint64_t command,serial; } menu_commands[128];
    unsigned menu_read,menu_write;
    void *drop_target;
    void *drag_source;
    void *accessibility;
    ZenitDragPacket source_result;
    float titlebar_drag_height, titlebar_drag_right_inset;
    int custom_frame;
    int chrome_hide_controls, chrome_fullscreen;
    unsigned chrome_hover, chrome_pressed;
    uint32_t chrome_min_width, chrome_min_height;
    uint32_t chrome_state_generation;
    LONG_PTR chrome_saved_style;
    RECT chrome_saved_rect;
    int (*chrome_hit)(void *, float, float);
    void *chrome_context;
    float custom_titlebar_height;
    int (*titlebar_hit_callback)(void *, float, float);
    void *titlebar_hit_context;
    uint32_t id;
    int close_requested;
    int alive;
    int redraw_requested;
    uint64_t text_settings_generation;
    /* Runtime windows stay DWM-cloaked from creation until their first GPU
       frame is presented, and again from teardown until destruction, so the
       desktop never shows a window without application content. */
    int reveal_on_present;
    int presented;
    int cloaked;
    int concealed; /* teardown began: stays cloaked until destruction */
    int live_resize;
    int dpi_changing;
    int owner_changing;
    HMONITOR refresh_monitor;
    float refresh_hz;
#ifdef ZENIT_WINDOW_CONTRACT
    float contract_refresh_hz;
#endif
    int mouse_x, mouse_y;
    unsigned cursor_shape;
    HCURSOR cursor;
    unsigned button_mask;
    uint64_t next_input_serial;
    struct { uint16_t code; uint32_t modifiers; int down; uint64_t serial; } keys[128];
    unsigned key_read, key_write;
    struct { int code, down, x, y; uint32_t modifiers; uint64_t serial; } buttons[128];
    unsigned button_read, button_write;
    /* left: WM_MOUSELEAVE marker (pointer left the client area), never coalesced. */
    struct { int x, y, dx, dy; uint32_t modifiers; uint64_t serial; int left; } moves[128];
    unsigned move_read, move_write;
    int leave_tracked; /* TrackMouseEvent(TME_LEAVE) armed for the client area */
    struct { float x, y, dx, dy; uint32_t modifiers; uint64_t serial; } wheels[128];
    unsigned wheel_read, wheel_write;
    struct { char bytes[4]; int length; uint64_t serial; } text[128];
    unsigned text_read, text_write;
    uint16_t high_surrogate;
    struct { char *bytes; uint32_t length, cursor; int kind; uint64_t serial; } ime[128];
    unsigned ime_read, ime_write;
    int ime_active;
    int ime_enabled;
    int keyboard_isolated;
    HIMC detached_ime_context;
    void (*render_callback)(void *);
    void *render_context;
    /* Owned-window focus loss: 0 none, 1 focus went to this process, 2 elsewhere. */
    int focus_loss;
} ZenitWindow;

#define ZENIT_RESIZE_TIMER ((UINT_PTR)0x5a4e0001)
#define ZENIT_REVEAL_TIMER ((UINT_PTR)0x5a4e0002)
/* Uncloak anyway when no frame is presented in time (a failed renderer must
   not leave an invisible running application). */
#define ZENIT_REVEAL_TIMEOUT_MS 3000
#define ZENIT_CREATE_HIDDEN 1
#define ZENIT_CREATE_REVEAL_ON_PRESENT 2

void zenit_windows_show(ZenitWindow *win);

static void set_cloak(ZenitWindow *win, int cloak) {
    BOOL value = cloak ? TRUE : FALSE;
    if (win && win->hwnd && SUCCEEDED(DwmSetWindowAttribute(win->hwnd, DWMWA_CLOAK, &value, sizeof(value))))
        win->cloaked = cloak;
}

static int removed_caption(ZenitWindow *win, UINT dpi) {
    if (!win->custom_frame || win->chrome_fullscreen) return 0;
    int removed = GetSystemMetricsForDpi(SM_CYCAPTION, dpi);
    if (!IsZoomed(win->hwnd)) removed += GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi)+GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    return removed;
}

static int client_window_extent(uint32_t width, uint32_t height, UINT dpi,
    DWORD style, DWORD ex_style, BOOL menu, int removed_caption, int *outer_width, int *outer_height);

static int window_client_extent(ZenitWindow *win, uint32_t width, uint32_t height,
    UINT dpi, int *outer_width, int *outer_height);

static const wchar_t class_name[] = L"ZenitWindow";
static ATOM window_class;
static uint32_t next_id = 1;
static uint32_t live_windows;
static int app_quit_requested;
static uint64_t mouse_move_coalesced;

static float window_scale(ZenitWindow *win) {
    return win && win->hwnd ? (float)GetDpiForWindow(win->hwnd) / 96.0f : 1.0f;
}

/* Keep normal frames inside the destination work area, including non-client
   borders. Maximized and fullscreen windows retain their native frame policy. */
static void constrain_frame_to_work(RECT *frame, RECT work) {
    LONG width = frame->right-frame->left, height = frame->bottom-frame->top;
    LONG work_width = work.right-work.left;
    LONG work_height = work.bottom-work.top;
    if (width > work_width) width = work_width;
    if (height > work_height) height = work_height;
    if (frame->left > work.right-width) frame->left = work.right-width;
    if (frame->top > work.bottom-height) frame->top = work.bottom-height;
    if (frame->left < work.left) frame->left = work.left;
    if (frame->top < work.top) frame->top = work.top;
    frame->right = frame->left+width;
    frame->bottom = frame->top+height;
}
static int constrain_window_frame(RECT *frame, HMONITOR monitor) {
    MONITORINFO info = { .cbSize = sizeof(info) };
    if (!monitor || !GetMonitorInfoW(monitor, &info)) return 0;
    constrain_frame_to_work(frame, info.rcWork);
    return 1;
}

static unsigned queue_next(unsigned index) { return (index + 1) % 128; }
static uint64_t next_drag_serial(void *context) { return ++((ZenitWindow *)context)->next_input_serial; }
static uint32_t modifiers(void);

static void push_key(ZenitWindow *win, uint16_t code, uint32_t mods, int down) {
    unsigned next = queue_next(win->key_write);
    if (next == win->key_read) win->key_read = queue_next(win->key_read);
    win->keys[win->key_write].code = code;
    win->keys[win->key_write].modifiers = mods;
    win->keys[win->key_write].down = down;
    win->keys[win->key_write].serial = ++win->next_input_serial;
    win->key_write = next;
    if (getenv("ZENIT_WINDOWS_INPUT_TRACE"))
        fprintf(stderr, "[windows-key] hwnd=%p vk=0x%02x mods=0x%x down=%d serial=%llu\n", (void *)win->hwnd, code, mods, down, (unsigned long long)win->next_input_serial);
}

static void push_button(ZenitWindow *win, int code, int down, int x, int y) {
    unsigned next = queue_next(win->button_write);
    if (next == win->button_read) win->button_read = queue_next(win->button_read);
    win->buttons[win->button_write].code = code;
    win->buttons[win->button_write].down = down;
    win->buttons[win->button_write].x = x;
    win->buttons[win->button_write].y = y;
    win->buttons[win->button_write].modifiers = modifiers();
    win->buttons[win->button_write].serial = ++win->next_input_serial;
    win->button_write = next;
}

/* Only adjacent moves may coalesce: buttons/keys/text/drop are boundaries. */
static void push_move(ZenitWindow *win, int x, int y, WPARAM flags) {
    uint32_t mods = (modifiers() & ~3u) | ((flags & MK_SHIFT) ? 1u : 0u) | ((flags & MK_CONTROL) ? 2u : 0u);
    int dx = x - win->mouse_x, dy = y - win->mouse_y;
    win->mouse_x = x;
    win->mouse_y = y;
    unsigned previous = (win->move_write + 127) % 128;
    if (win->move_read != win->move_write && !win->moves[previous].left &&
        win->moves[previous].serial == win->next_input_serial && win->moves[previous].modifiers == mods) {
        win->moves[previous].x = x;
        win->moves[previous].y = y;
        win->moves[previous].dx += dx;
        win->moves[previous].dy += dy;
        win->moves[previous].modifiers = mods;
        win->moves[previous].serial = ++win->next_input_serial;
        ++mouse_move_coalesced;
        return;
    }
    unsigned next = queue_next(win->move_write);
    if (next == win->move_read) win->move_read = queue_next(win->move_read);
    win->moves[win->move_write].x = x;
    win->moves[win->move_write].y = y;
    win->moves[win->move_write].dx = dx;
    win->moves[win->move_write].dy = dy;
    win->moves[win->move_write].modifiers = mods;
    win->moves[win->move_write].serial = ++win->next_input_serial;
    win->moves[win->move_write].left = 0;
    win->move_write = next;
}

/* WM_MOUSELEAVE: ordered after the moves before it; the next move re-arms tracking. */
static void push_leave(ZenitWindow *win) {
    unsigned next = queue_next(win->move_write);
    if (next == win->move_read) win->move_read = queue_next(win->move_read);
    win->moves[win->move_write].x = win->mouse_x;
    win->moves[win->move_write].y = win->mouse_y;
    win->moves[win->move_write].dx = 0;
    win->moves[win->move_write].dy = 0;
    win->moves[win->move_write].modifiers = modifiers();
    win->moves[win->move_write].serial = ++win->next_input_serial;
    win->moves[win->move_write].left = 1;
    win->move_write = next;
}

/* Cancellation uses the ordered button ring but never synthesizes a click. */
static void cancel_pointer(ZenitWindow *win) {
    if (!win->button_mask) return;
    win->button_mask = 0;
    push_button(win, -1, 0, win->mouse_x, win->mouse_y);
}

static void push_wheel(ZenitWindow *win, HWND hwnd, LPARAM lparam, float dx, float dy) {
    POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(hwnd, &point);
    unsigned next = queue_next(win->wheel_write);
    if (next == win->wheel_read) win->wheel_read = queue_next(win->wheel_read);
    win->wheels[win->wheel_write].x = (float)point.x;
    win->wheels[win->wheel_write].y = (float)point.y;
    win->wheels[win->wheel_write].dx = dx;
    win->wheels[win->wheel_write].dy = dy;
    win->wheels[win->wheel_write].modifiers = modifiers();
    win->wheels[win->wheel_write].serial = ++win->next_input_serial;
    win->wheel_write = next;
}

static void push_text(ZenitWindow *win, const wchar_t *wide, int length) {
    unsigned next = queue_next(win->text_write);
    if (next == win->text_read) win->text_read = queue_next(win->text_read);
    int bytes = WideCharToMultiByte(CP_UTF8, 0, wide, length,
        win->text[win->text_write].bytes, 4, NULL, NULL);
    if (bytes <= 0) return;
    win->text[win->text_write].length = bytes;
    win->text[win->text_write].serial = ++win->next_input_serial;
    win->text_write = next;
}

static void push_ime(ZenitWindow *win, int kind, const wchar_t *wide, int length, int cursor_utf16) {
    if (length < 0 || length > 32768) return;
    int bytes = length ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        wide, length, NULL, 0, NULL, NULL) : 0;
    if (length && bytes <= 0) return;
    char *copy = (char *)malloc((size_t)bytes + 1);
    if (!copy) return;
    if (bytes && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            wide, length, copy, bytes, NULL, NULL) != bytes) {
        free(copy); return;
    }
    copy[bytes] = 0;
    if (cursor_utf16 < 0) cursor_utf16 = length;
    if (cursor_utf16 > length) cursor_utf16 = length;
    if (cursor_utf16 > 0 && cursor_utf16 < length &&
        wide[cursor_utf16 - 1] >= 0xD800 && wide[cursor_utf16 - 1] <= 0xDBFF &&
        wide[cursor_utf16] >= 0xDC00 && wide[cursor_utf16] <= 0xDFFF)
        --cursor_utf16;
    int cursor = cursor_utf16 ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        wide, cursor_utf16, NULL, 0, NULL, NULL) : 0;
    if (cursor < 0) cursor = 0;
    unsigned next = queue_next(win->ime_write);
    if (next == win->ime_read) {
        free(win->ime[win->ime_read].bytes);
        win->ime_read = queue_next(win->ime_read);
    }
    win->ime[win->ime_write].bytes = copy;
    win->ime[win->ime_write].length = (uint32_t)bytes;
    win->ime[win->ime_write].cursor = (uint32_t)cursor;
    win->ime[win->ime_write].kind = kind;
    win->ime[win->ime_write].serial = ++win->next_input_serial;
    win->ime_write = next;
    if (getenv("ZENIT_WINDOWS_INPUT_TRACE"))
        fprintf(stderr, "[windows-ime] kind=%d serial=%llu cursor=%d text=%s\n", kind, (unsigned long long)win->next_input_serial, cursor, copy);
}

static void read_ime_string(ZenitWindow *win, HIMC context, DWORD flag, int kind) {
    LONG bytes = ImmGetCompositionStringW(context, flag, NULL, 0);
    if (bytes < 0 || bytes > 65536 || bytes % sizeof(wchar_t)) return;
    wchar_t *wide = (wchar_t *)calloc((size_t)bytes + sizeof(wchar_t), 1);
    if (!wide) return;
    if (bytes && ImmGetCompositionStringW(context, flag, wide, (DWORD)bytes) != bytes) {
        free(wide); return;
    }
    int length = (int)(bytes / sizeof(wchar_t));
    int cursor = kind == 1 ? (int)ImmGetCompositionStringW(context, GCS_CURSORPOS, NULL, 0) : length;
    push_ime(win, kind, wide, length, cursor);
    free(wide);
}

static uint32_t modifiers(void) {
    uint32_t result = 0;
    if (GetKeyState(VK_SHIFT) & 0x8000) result |= 1;
    if (GetKeyState(VK_CONTROL) & 0x8000) result |= 2;
    if (GetKeyState(VK_MENU) & 0x8000) result |= 4;
    if (GetKeyState(VK_LWIN) & 0x8000 || GetKeyState(VK_RWIN) & 0x8000) result |= 8;
    return result;
}


static void clear_menu(ZenitWindow *win) {
    if(win->menu) {SetMenu(win->hwnd,NULL);DestroyMenu(win->menu);win->menu=NULL;}
    if(win->accelerators)DestroyAcceleratorTable(win->accelerators);
    win->accelerators=NULL;free(win->menu_entries);win->menu_entries=NULL;win->menu_count=0;
    win->menu_read=win->menu_write=0;
}
static ZenitWindow *window_owner(HWND hwnd) {
    wchar_t name[64];DWORD pid=0;
    if(!IsWindow(hwnd)||!GetClassNameW(hwnd,name,64)||wcscmp(name,class_name))return NULL;
    DWORD thread=GetWindowThreadProcessId(hwnd,&pid);if(pid!=GetCurrentProcessId()||thread!=GetCurrentThreadId())return NULL;
    ZenitWindow *win=(ZenitWindow *)GetWindowLongPtrW(hwnd,GWLP_USERDATA);
    return win&&win->alive&&win->hwnd==hwnd?win:NULL;
}
/* File-open intents: process FIFO, shared by every Window, as on macOS.
   WM_COPYDATA payload v1: dwData=0x5a4e4f50 (ZNOP), cbData includes one NUL,
   lpData is one absolute UTF-8 path. Sender storage is never retained. */
#define ZENIT_OPEN_PATH_TAG ((ULONG_PTR)0x5a4e4f50)
#define ZENIT_OPEN_PATH_MAX 131072u
#define ZENIT_OPEN_QUEUE_MAX 256u
#define ZENIT_OPEN_BYTES_MAX (4u * 1024u * 1024u)
typedef struct ZenitOpenPath {
    struct ZenitOpenPath *next;
    size_t size;
    char text[];
} ZenitOpenPath;
static SRWLOCK open_path_lock = SRWLOCK_INIT;
static ZenitOpenPath *open_path_head, *open_path_tail;
static size_t open_path_count, open_path_bytes;
static INIT_ONCE open_path_once = INIT_ONCE_STATIC_INIT;
static int open_path_startup_ok;

static void open_path_free(ZenitOpenPath *head) {
    while (head) { ZenitOpenPath *next = head->next; free(head); head = next; }
}
static int open_path_commit(ZenitOpenPath *head, ZenitOpenPath *tail, size_t count, size_t bytes) {
    AcquireSRWLockExclusive(&open_path_lock);
    int ok = count <= ZENIT_OPEN_QUEUE_MAX - open_path_count && bytes <= ZENIT_OPEN_BYTES_MAX - open_path_bytes;
    if (ok && head) {
        if (open_path_tail) open_path_tail->next = head; else open_path_head = head;
        open_path_tail = tail; open_path_count += count; open_path_bytes += bytes;
    }
    ReleaseSRWLockExclusive(&open_path_lock);
    if (!ok) open_path_free(head);
    return ok;
}
static int open_path_absolute(const wchar_t *path) {
    size_t len = wcslen(path);
    return (len >= 3 && ((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) &&
        path[1] == L':' && (path[2] == L'\\' || path[2] == L'/')) ||
        (len >= 5 && path[0] == L'\\' && path[1] == L'\\');
}
static ZenitOpenPath *open_path_build(const wchar_t *path, int allow_relative) {
    if (!path || !path[0] || wcslen(path) > 32767 || (!allow_relative && !open_path_absolute(path))) return NULL;
    DWORD capacity = GetFullPathNameW(path, 0, NULL, NULL);
    if (!capacity || capacity > 32768) return NULL;
    wchar_t *full = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    if (!full) return NULL;
    DWORD length = GetFullPathNameW(path, capacity, full, NULL);
    int bytes = length && length < capacity ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, full, -1, NULL, 0, NULL, NULL) : 0;
    ZenitOpenPath *entry = bytes > 1 && bytes <= ZENIT_OPEN_PATH_MAX ? (ZenitOpenPath *)calloc(1, sizeof(*entry) + (size_t)bytes) : NULL;
    if (entry) {
        entry->size = (size_t)bytes;
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, full, -1, entry->text, bytes, NULL, NULL) != bytes) {
            free(entry); entry = NULL;
        }
    }
    free(full); return entry;
}
static ZenitOpenPath *open_path_utf8(const char *path, size_t size, int allow_relative) {
    if (!path || size < 2 || size > ZENIT_OPEN_PATH_MAX || path[size-1] || memchr(path, 0, size-1)) return NULL;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, (int)size, NULL, 0);
    if (!count || count > 32768) return NULL;
    wchar_t *wide = (wchar_t *)calloc((size_t)count, sizeof(wchar_t));
    if (!wide) return NULL;
    ZenitOpenPath *entry = NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, (int)size, wide, count) == count)
        entry = open_path_build(wide, allow_relative);
    free(wide); return entry;
}
static int open_path_commandline(const wchar_t *commandline) {
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(commandline, &argc);
    if (!argv) return 0;
    ZenitOpenPath *head = NULL, *tail = NULL;
    size_t count = 0, bytes = 0;
    int ok = 1;
    for (int i = 1; i < argc; ++i) {
        const wchar_t *path = NULL;
        if (!wcscmp(argv[i], L"--zenit-open-file")) {
            if (++i == argc) { ok = 0; break; }
            path = argv[i];
        } else if (!wcsncmp(argv[i], L"--zenit-open-file=", 18)) path = argv[i] + 18;
        if (!path) continue; /* Normal app argv remains owned by the app. */
        ZenitOpenPath *entry = open_path_build(path, 1);
        if (!entry) { ok = 0; break; }
        if (++count > ZENIT_OPEN_QUEUE_MAX || (bytes += entry->size) > ZENIT_OPEN_BYTES_MAX) {
            free(entry); ok = 0; break;
        }
        if (tail) tail->next = entry; else head = entry;
        tail = entry;
    }
    LocalFree(argv);
    if (!ok) { open_path_free(head); return 0; }
    return open_path_commit(head, tail, count, bytes);
}
static BOOL CALLBACK open_path_startup(PINIT_ONCE once, PVOID param, PVOID *context) {
    (void)once; (void)param; (void)context;
    open_path_startup_ok = open_path_commandline(GetCommandLineW());
    return TRUE; /* Failed startup input remains a stable error, not a partial retry. */
}
int zenit_windows_init_application(void) {
    return InitOnceExecuteOnce(&open_path_once, open_path_startup, NULL, NULL) && open_path_startup_ok;
}
int zenit_win_pending_open_file(char *buffer, size_t capacity) {
    AcquireSRWLockExclusive(&open_path_lock);
    ZenitOpenPath *entry = open_path_head;
    int result = 0;
    if (entry) {
        if (!buffer || capacity < entry->size) result = -(int)entry->size;
        else {
            memcpy(buffer, entry->text, entry->size);
            result = (int)entry->size - 1;
            open_path_head = entry->next;
            if (!open_path_head) open_path_tail = NULL;
            --open_path_count; open_path_bytes -= entry->size;
            free(entry);
        }
    }
    ReleaseSRWLockExclusive(&open_path_lock);
    return result;
}
static LRESULT open_path_receive(ZenitWindow *win, const COPYDATASTRUCT *data) {
    if (!win || !win->alive || win->close_requested || !data || data->dwData != ZENIT_OPEN_PATH_TAG) return FALSE;
    ZenitOpenPath *entry = open_path_utf8((const char *)data->lpData, data->cbData, 0);
    return entry ? open_path_commit(entry, entry, 1, entry->size) : FALSE;
}
int zenit_win_send_open_file(void *target, const char *path, size_t size, uint32_t timeout) {
    HWND hwnd = (HWND)target;
    wchar_t name[64];
    if (!hwnd || !IsWindow(hwnd) || !GetClassNameW(hwnd, name, 64) || wcscmp(name, class_name) || !timeout || timeout > 30000) return 0;
    ZenitOpenPath *entry = open_path_utf8(path, size, 1);
    if (!entry) return 0;
    COPYDATASTRUCT data = { ZENIT_OPEN_PATH_TAG, (DWORD)entry->size, entry->text };
    DWORD_PTR accepted = 0;
    LRESULT sent = SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, (LPARAM)&data,
        SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT, timeout, &accepted);
    free(entry);
    return sent && accepted == TRUE;
}
#ifdef ZENIT_WINDOW_CONTRACT
int zenit_win_open_path_contract_commandline(const wchar_t *commandline) { return open_path_commandline(commandline); }
extern int32_t zenit_uia_contract_selection_operation(void *, uint32_t, uint32_t, int);
int32_t zenit_windows_contract_selection_operation(ZenitWindow *win, uint32_t id, uint32_t position, int remove) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_selection_operation(win->accessibility, id, position, remove) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_scroll(void *, uint32_t, uint32_t, uint32_t, int);
int32_t zenit_windows_contract_scroll(ZenitWindow *win, uint32_t id, uint32_t start, uint32_t end, int align_top) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_scroll(win->accessibility, id, start, end, align_top) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_single_unit_select(void *, uint32_t, uint32_t, int);
int32_t zenit_windows_contract_single_unit_select(ZenitWindow *win, uint32_t id, uint32_t position, int page) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_single_unit_select(win->accessibility, id, position, page) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_line_select(void *, uint32_t, uint32_t);
int32_t zenit_windows_contract_line_select(ZenitWindow *win, uint32_t id, uint32_t position) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_line_select(win->accessibility, id, position) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_logical_select(void *, uint32_t, uint32_t, int);
int32_t zenit_windows_contract_logical_select(ZenitWindow *win, uint32_t id, uint32_t position, int paragraph) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_logical_select(win->accessibility, id, position, paragraph) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_move_select(void *, uint32_t, uint32_t, uint32_t, int);
int32_t zenit_windows_contract_move_select(ZenitWindow *win, uint32_t id, uint32_t start, uint32_t end, int count) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_move_select(win->accessibility, id, start, end, count) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_character_select(void *, uint32_t, uint32_t);
int32_t zenit_windows_contract_character_select(ZenitWindow *win, uint32_t id, uint32_t position) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_character_select(win->accessibility, id, position) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_range_select(void *, uint32_t, uint32_t, uint32_t);
int32_t zenit_windows_contract_range_select(ZenitWindow *win, uint32_t id, uint32_t start, uint32_t end) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_range_select(win->accessibility, id, start, end) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_text_selection(void *, uint32_t, uint32_t, uint32_t);
int32_t zenit_windows_contract_text_selection(ZenitWindow *win, uint32_t id, uint32_t start, uint32_t end) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_text_selection(win->accessibility, id, start, end) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_point(void *, uint32_t, double, double, uint32_t *);
int32_t zenit_windows_contract_point(ZenitWindow *win, uint32_t id, double x, double y, uint32_t *out) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_point(win->accessibility,id,x,y,out) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_visible_ranges(void *, uint32_t, uint32_t *);
int32_t zenit_windows_contract_visible_ranges(ZenitWindow *win, uint32_t id, uint32_t *out) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_visible_ranges(win->accessibility,id,out) : (int32_t)0x80040201;
}
extern int32_t zenit_uia_contract_document_selection(void *, uint32_t, uint32_t *);
int32_t zenit_windows_contract_document_selection(ZenitWindow *win, uint32_t id, uint32_t *out) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_document_selection(win->accessibility, id, out) : (int32_t)0x80040201;
}
extern int zenit_uia_contract_editable(void *, uint32_t, uint32_t *);
extern int zenit_uia_contract_geometry(void *, uint32_t, uint32_t, uint32_t *, float *);
extern int32_t zenit_uia_contract_bounds(void *, uint32_t, uint32_t, uint32_t, double *, uint32_t *);
int32_t zenit_windows_contract_bounds(ZenitWindow *win, uint32_t id, uint32_t start, uint32_t end, double *out, uint32_t *count) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_bounds(win->accessibility,id,start,end,out,count) : (int32_t)0x80040201;
}
extern int zenit_uia_contract_caret(void *, uint32_t, uint32_t, uint32_t *, float *);
int zenit_windows_contract_caret(ZenitWindow *win, uint32_t id, uint32_t index, uint32_t *out, float *line) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_caret(win->accessibility, id, index, out, line) : 0;
}
int zenit_windows_contract_geometry(ZenitWindow *win, uint32_t id, uint32_t index, uint32_t *out, float *rect) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_geometry(win->accessibility, id, index, out, rect) : 0;
}
int zenit_windows_contract_editable(ZenitWindow *win, uint32_t id, uint32_t *out) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_editable(win->accessibility, id, out) : 0;
}
extern int32_t zenit_uia_contract_focus(void *, uint32_t);
int32_t zenit_windows_contract_focus(ZenitWindow *win, uint32_t id) {
    return win && window_owner(win->hwnd) == win ? zenit_uia_contract_focus(win->accessibility, id) : (int32_t)0x80040201;
}
int zenit_windows_contract_focus_redraw(ZenitWindow *win, int gained) {
    if (!win || window_owner(win->hwnd) != win || !win->render_callback) return 0;
    // Exercise WndProc without activating a window or changing system focus.
    ValidateRect(win->hwnd, NULL);
    SendMessageW(win->hwnd, gained ? WM_SETFOCUS : WM_KILLFOCUS, 0, 0);
    return GetUpdateRect(win->hwnd, NULL, FALSE) != 0;
}
int zenit_win_open_path_contract_close(void *target) { return (int)SendMessageW((HWND)target, WM_CLOSE, 0, 0); }
int zenit_win_open_path_contract_raw(void *target, uintptr_t tag, const char *data, uint32_t size) {
    COPYDATASTRUCT payload = { (ULONG_PTR)tag, size, (void *)data };
    return (int)SendMessageW((HWND)target, WM_COPYDATA, 0, (LPARAM)&payload);
}
#endif

/* Shared system cursors are borrowed; never DestroyCursor them. */
static HCURSOR cursor_for_shape(unsigned shape) {
    LPCWSTR name;
    switch (shape) {
        case 0: case 1: name = IDC_ARROW; break;
        case 2: name = IDC_HAND; break;
        case 3: name = IDC_IBEAM; break;
        case 4: name = IDC_CROSS; break;
        case 5: case 7: case 8: name = IDC_SIZEALL; break;
        case 6: name = IDC_NO; break;
        case 9: case 13: name = IDC_SIZEWE; break;
        case 10: case 14: name = IDC_SIZENS; break;
        case 11: name = IDC_SIZENWSE; break;
        case 12: name = IDC_SIZENESW; break;
        case 15: name = IDC_WAIT; break;
        case 16: name = IDC_APPSTARTING; break;
        case 17: name = IDC_HELP; break;
        default: return NULL;
    }
    return LoadCursorW(NULL, name);
}
static int client_cursor(ZenitWindow *win, HWND recipient, int hit, HCURSOR *cursor) {
    if (recipient != win->hwnd || hit != HTCLIENT || win->cursor_shape == 20) return 0;
    *cursor = win->cursor ? win->cursor :
        (win->cursor_shape == 18 ? NULL : cursor_for_shape(win->cursor_shape));
    return 1;
}
static int cursor_owned_here(ZenitWindow *win) {
    if (!win->hwnd || !IsWindowVisible(win->hwnd)) return 0;
    if (GetCapture() == win->hwnd) return 1;
    POINT point; RECT client;
    if (!GetCursorPos(&point) || WindowFromPoint(point) != win->hwnd ||
        !ScreenToClient(win->hwnd, &point) || !GetClientRect(win->hwnd, &client)) return 0;
    return PtInRect(&client, point);
}
int zenit_win_cursor_shape(void *owner, unsigned shape) {
    ZenitWindow *win = window_owner((HWND)owner);
    if (!win || shape > 20 || shape == 19) return 0;
    HCURSOR cursor = shape == 18 || shape == 20 ? NULL : cursor_for_shape(shape);
    if (!cursor && shape != 18 && shape != 20) return 0;
    win->cursor_shape = shape;
    win->cursor = cursor;
    if (shape != 20 && (GetForegroundWindow() == win->hwnd || GetCapture() == win->hwnd) && cursor_owned_here(win)) SetCursor(cursor);
    return 1;
}
int zenit_win_titlebar_region(void *owner, float height, float right_inset) {
    ZenitWindow *win = window_owner((HWND)owner);
    if (!win || !isfinite(height) || !isfinite(right_inset) || height < 0 || right_inset < 0) return 0;
    win->titlebar_drag_height = height;
    win->titlebar_drag_right_inset = right_inset;
    return 1;
}
static HRESULT custom_frame_margins(ZenitWindow *win) {
    UINT dpi=GetDpiForWindow(win->hwnd); if (!dpi) dpi=96;
    double top=ceil((double)win->custom_titlebar_height*dpi/96.0);
    if (top>INT_MAX) return E_INVALIDARG;
    MARGINS margins={0,0,win->custom_frame&&!win->chrome_hide_controls?(int)top:0,0};
    return DwmExtendFrameIntoClientArea(win->hwnd,&margins);
}
/* "Zenit.DwmCaption": DWM paints its caption buttons over this client (custom
   frame with automatic controls, not fullscreen). The GPU surface reads only
   this property to carve out and blacken that region; application-painted
   controls (chrome_hide_controls) never get a DWM cut-out. */
static void sync_dwm_caption_prop(ZenitWindow *win) {
    if (win->custom_frame && !win->chrome_hide_controls && !win->chrome_fullscreen) SetPropW(win->hwnd,L"Zenit.DwmCaption",(HANDLE)1);
    else RemovePropW(win->hwnd,L"Zenit.DwmCaption");
}
int zenit_win_custom_frame(void *owner, int enabled, float height, float right_inset) {
    ZenitWindow *win=window_owner((HWND)owner);
    if (!win || !isfinite(height) || !isfinite(right_inset) || height<=0 || right_inset<0) return 0;
    UINT dpi=GetDpiForWindow(win->hwnd); if (!dpi) dpi=96;
    if ((double)height*dpi/96.0>INT_MAX) return 0;
    int old_frame=win->custom_frame;
    float old_custom_height=win->custom_titlebar_height;
    float old_height=win->titlebar_drag_height,old_inset=win->titlebar_drag_right_inset;
    if (enabled && !SetPropW(win->hwnd,L"Zenit.CustomFrame",(HANDLE)1)) return 0;
    win->custom_frame=enabled!=0;
    win->custom_titlebar_height=enabled?height:0;
    win->titlebar_drag_height=enabled?height:0;
    win->titlebar_drag_right_inset=enabled?right_inset:0;
    sync_dwm_caption_prop(win);
    if (FAILED(custom_frame_margins(win)) || !SetWindowPos(win->hwnd,NULL,0,0,0,0,
        SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED)) {
        if (!old_frame) RemovePropW(win->hwnd,L"Zenit.CustomFrame");
        win->custom_frame=old_frame; win->custom_titlebar_height=old_custom_height; win->titlebar_drag_height=old_height; win->titlebar_drag_right_inset=old_inset;
        sync_dwm_caption_prop(win);
        custom_frame_margins(win);
        SetWindowPos(win->hwnd,NULL,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED);
        return 0;
    }
    if (!enabled) RemovePropW(win->hwnd,L"Zenit.CustomFrame");
    return 1;
}
float zenit_win_titlebar_height(void *owner) {
    ZenitWindow *win=window_owner((HWND)owner);
    return win && win->custom_frame ? win->custom_titlebar_height : 0;
}
/* Physical client pixels reserved for the DWM-owned caption buttons. */
int zenit_win_caption_button_rect(HWND hwnd, RECT *out) {
    ZenitWindow *win=window_owner(hwnd);
    if (!win || !win->custom_frame || win->chrome_hide_controls || win->chrome_fullscreen || IsIconic(hwnd)) return 0;
    RECT buttons,outer; POINT origin={0,0};
    if (!out || FAILED(DwmGetWindowAttribute(hwnd,DWMWA_CAPTION_BUTTON_BOUNDS,&buttons,sizeof(buttons))) ||
        !GetWindowRect(hwnd,&outer) || !ClientToScreen(hwnd,&origin)) return -1;
    OffsetRect(&buttons,outer.left-origin.x,outer.top-origin.y);
    if (buttons.right<=buttons.left || buttons.bottom<=buttons.top) return -1;
    *out=buttons;
    return 1;
}
int zenit_win_titlebar_hit_callback(void *owner, int (*callback)(void *,float,float), void *context) {
    ZenitWindow *win = window_owner((HWND)owner); if (!win) return 0;
    win->titlebar_hit_callback = callback; win->titlebar_hit_context = callback ? context : NULL;
    return 1;
}
int zenit_win_window_drag(void *owner) {
    ZenitWindow *win = window_owner((HWND)owner); POINT point;
    // Enter the system move loop only for an active, physical left-button gesture.
    if (!win || GetForegroundWindow() != win->hwnd || !(GetAsyncKeyState(VK_LBUTTON) & 0x8000) || !GetCursorPos(&point)) return 0;
    ReleaseCapture();
    return PostMessageW(win->hwnd, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(point.x, point.y)) != 0;
}

static wchar_t *menu_string(const char *text,size_t len) {
    if(!text||len>4096||memchr(text,0,len))return NULL;
    int n=len?MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,(int)len,NULL,0):0;
    if(len&&!n)return NULL;
    // Escape '&': labels are literal model text, not implicit mnemonics.
    wchar_t *raw=(wchar_t *)calloc((size_t)n+1,sizeof(wchar_t));
    wchar_t *out=(wchar_t *)calloc((size_t)n*2+1,sizeof(wchar_t));
    if(!raw||!out){free(raw);free(out);return NULL;}
    if(n&&MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,(int)len,raw,n)!=n){free(raw);free(out);return NULL;}
    size_t j=0;for(int i=0;i<n;++i){out[j++]=raw[i];if(raw[i]=='&')out[j++]=L'&';}
    free(raw);return out;
}
// Return -4 invalid model, -3 wrong thread, -5 nonportable role/key, 0 API failure.
int zenit_win_menu_set(void *owner,const ZenitMenuNode *nodes,size_t count) {
    HWND hwnd=(HWND)owner;
    if(IsWindow(hwnd)&&GetWindowThreadProcessId(hwnd,NULL)!=GetCurrentThreadId())return -3;
    ZenitWindow *win=window_owner(hwnd);
    if(!win)return -4;
    if(GetWindowThreadProcessId(hwnd,NULL)!=GetCurrentThreadId())return -3;
    if(!nodes||!count||count>1024)return -4;
    HMENU root=CreateMenu();if(!root)return 0;
    ZenitMenuEntry *entries=(ZenitMenuEntry *)calloc(count,sizeof(*entries));
    ACCEL *accels=(ACCEL *)calloc(count,sizeof(*accels));HACCEL table=NULL;
    int result=-4,naccels=0;uint32_t next=win->next_menu_id?win->next_menu_id:1;
    if(!entries||!accels){result=0;goto fail;}
    for(size_t i=0;i<count;++i) {
        const ZenitMenuNode *n=&nodes[i];HMENU parent=root;int enabled=n->enabled!=0;
        if(!n->id||n->kind>2||n->role>16||n->modifiers&~15u)goto fail;
        for(size_t j=0;j<i;++j)if(entries[j].node.id==n->id)goto fail;
        if(!n->parent){if(n->kind!=0)goto fail;}
        else {size_t j;for(j=0;j<i;++j)if(entries[j].node.id==n->parent&&entries[j].node.kind==0)break;
            if(j==i)goto fail;parent=entries[j].menu;enabled=enabled&&entries[j].enabled;}
        entries[i].node=*n;entries[i].node.label=entries[i].node.key=NULL;entries[i].node.label_len=entries[i].node.key_len=0;entries[i].enabled=enabled;
        MENUITEMINFOW info={0};info.cbSize=sizeof(info);info.fMask=MIIM_FTYPE|MIIM_STATE;
        info.fState=(enabled?MFS_ENABLED:MFS_DISABLED)|(n->checked?MFS_CHECKED:0);
        if(n->kind==2){info.fType=MFT_SEPARATOR;}
        else {
            wchar_t *label=menu_string(n->label,n->label_len);if(!label)goto fail;
            info.fType=MFT_STRING;info.fMask|=MIIM_STRING;info.dwTypeData=label;
            if(n->kind==0){entries[i].menu=CreatePopupMenu();info.fMask|=MIIM_SUBMENU;info.hSubMenu=entries[i].menu;
                if(!info.hSubMenu){free(label);result=0;goto fail;}}
            else {
                // App-specific roles must provide a command; macOS-only roles
                // are rejected atomically instead of installing inert items.
                if((n->role==0&&!n->command)||((n->role>=1&&n->role<=6)&&!n->command)) {
                    free(label);result=-5;goto fail;
                }
                WORD id=0;
                for(size_t j=0;j<win->menu_count;++j) {
                    const ZenitMenuEntry *old=&win->menu_entries[j];
                    if(old->node.id==n->id&&old->node.command==n->command&&old->node.role==n->role&&old->node.kind==1){id=old->native_id;break;}
                }
                if(!id){if(next>65535){free(label);goto fail;}id=(WORD)next++;}
                entries[i].native_id=id;info.fMask|=MIIM_ID;info.wID=id;
                if(n->key_len) {
                    if(n->key_len!=1||(unsigned char)n->key[0]>=128){free(label);result=-5;goto fail;}
                    SHORT vk=VkKeyScanW((wchar_t)(unsigned char)n->key[0]);
                    if(vk==-1){free(label);result=-5;goto fail;}
                    ACCEL a={FVIRTKEY,(WORD)(vk&255),id};
                    if(n->modifiers&1||(vk>>8)&1)a.fVirt|=FSHIFT;
                    if(n->modifiers&(2|8)||(vk>>8)&2)a.fVirt|=FCONTROL;
                    if(n->modifiers&4||(vk>>8)&4)a.fVirt|=FALT;
                    for(int j=0;j<naccels;++j)if(accels[j].key==a.key&&accels[j].fVirt==a.fVirt){free(label);goto fail;}
                    accels[naccels++]=a;
                    wchar_t suffix[64]=L"\t";
                    if(a.fVirt&FCONTROL)wcscat(suffix,L"Ctrl+");
                    if(a.fVirt&FALT)wcscat(suffix,L"Alt+");
                    if(a.fVirt&FSHIFT)wcscat(suffix,L"Shift+");
                    wchar_t key=(wchar_t)(unsigned char)n->key[0];if(key>=L'a'&&key<=L'z')key-=L'a'-L'A';
                    size_t tail=wcslen(suffix);suffix[tail]=key;suffix[tail+1]=0;
                    size_t head=wcslen(label);wchar_t *expanded=(wchar_t *)realloc(label,(head+tail+2)*sizeof(wchar_t));
                    if(!expanded){free(label);result=0;goto fail;}
                    label=expanded;memcpy(label+head,suffix,(tail+2)*sizeof(wchar_t));info.dwTypeData=label;
                }
            }
            if(!InsertMenuItemW(parent,(UINT)GetMenuItemCount(parent),TRUE,&info)) {
                if(n->kind==0){DestroyMenu(entries[i].menu);entries[i].menu=NULL;}
                free(label);result=0;goto fail;
            }
            free(label);continue;
        }
        if(!InsertMenuItemW(parent,(UINT)GetMenuItemCount(parent),TRUE,&info)){result=0;goto fail;}
    }
    if(naccels){table=CreateAcceleratorTableW(accels,naccels);if(!table){result=0;goto fail;}}
    if(!SetMenu(hwnd,root)){result=0;goto fail;}
    HMENU old=win->menu;HACCEL old_table=win->accelerators;ZenitMenuEntry *old_entries=win->menu_entries;
    win->menu=root;win->accelerators=table;win->menu_entries=entries;win->menu_count=count;win->next_menu_id=next;
    win->menu_read=win->menu_write=0;
    if(old)DestroyMenu(old);if(old_table)DestroyAcceleratorTable(old_table);free(old_entries);free(accels);
    DrawMenuBar(hwnd);InvalidateRect(hwnd,NULL,FALSE);return 1;
fail:
    if(table)DestroyAcceleratorTable(table);DestroyMenu(root);free(entries);free(accels);return result;
}
int zenit_win_menu_clear(void *owner) {
    ZenitWindow *win=window_owner((HWND)owner);
    if(!win||GetWindowThreadProcessId(win->hwnd,NULL)!=GetCurrentThreadId())return 0;
    clear_menu(win);DrawMenuBar(win->hwnd);return 1;
}
static BOOL CALLBACK bring_owned_window(HWND hwnd,LPARAM unused) {
    (void)unused;
    if(window_owner(hwnd))SetWindowPos(hwnd,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
    return TRUE;
}
static void dispatch_menu(ZenitWindow *win,WORD id) {
    for(size_t i=0;i<win->menu_count;++i) {
        const ZenitMenuEntry *e=&win->menu_entries[i];
        if(e->node.kind!=1||e->native_id!=id||!e->enabled)continue;
        if(e->node.command) {
            unsigned next=queue_next(win->menu_write);if(next==win->menu_read)return;
            win->menu_commands[win->menu_write].command=e->node.command;
            win->menu_commands[win->menu_write].serial=++win->next_input_serial;win->menu_write=next;return;
        }
        switch(e->node.role) {
            case 7:app_quit_requested=1;PostMessageW(win->hwnd,WM_NULL,0,0);break;
            case 8:case 9:case 10:case 11:case 12:case 13: {
                WORD key=e->node.role==8||e->node.role==9?'Z':e->node.role==10?'X':e->node.role==11?'C':e->node.role==12?'V':'A';
                uint32_t mods=2|(e->node.role==9?1:0);push_key(win,key,mods,1);push_key(win,key,mods,0);break;
            }
            case 14:ShowWindow(win->hwnd,SW_MINIMIZE);break;
            case 15:ShowWindow(win->hwnd,IsZoomed(win->hwnd)?SW_RESTORE:SW_MAXIMIZE);break;
            case 16:EnumThreadWindows(GetCurrentThreadId(),bring_owned_window,0);SetForegroundWindow(win->hwnd);break;
        }
        return;
    }
}
int zenit_windows_menu_peek(ZenitWindow *win,uint64_t *command) {
    if(!win||win->menu_read==win->menu_write)return 0;
    *command=win->menu_commands[win->menu_read].command;return 1;
}
int zenit_windows_menu_consume(ZenitWindow *win) {
    if(!win||win->menu_read==win->menu_write)return 0;win->menu_read=queue_next(win->menu_read);return 1;
}
static int keyboard_message(UINT message) {
    return (message >= WM_KEYFIRST && message <= WM_KEYLAST) ||
        (message >= WM_IME_STARTCOMPOSITION && message <= WM_IME_COMPOSITION) ||
        (message >= WM_IME_SETCONTEXT && message <= WM_IME_KEYUP);
}
void zenit_windows_set_keyboard_isolated(ZenitWindow *win, int isolated) {
    if (win) win->keyboard_isolated = isolated != 0;
}

// Shared by the message pump and deterministic tests with thread-local key state.
int zenit_win_menu_translate(void *owner,void *message) {
    ZenitWindow *win=window_owner((HWND)owner);MSG *msg=(MSG *)message;
    if(!win||!msg||msg->hwnd!=win->hwnd||GetWindowThreadProcessId(win->hwnd,NULL)!=GetCurrentThreadId())return 0;
    if (win->keyboard_isolated && keyboard_message(msg->message)) return 1;
    return win->accelerators?TranslateAcceleratorW(win->hwnd,win->accelerators,msg):0;
}
static void dispatch_native_message(MSG *msg) {
    ZenitWindow *win=window_owner(msg->hwnd);
    if(win&&zenit_win_menu_translate(win->hwnd,msg))return;
    TranslateMessage(msg);DispatchMessageW(msg);
}
static int show_without_activation(void);

static LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    ZenitWindow *win = (ZenitWindow *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        CREATESTRUCTW *create = (CREATESTRUCTW *)lparam;
        win = (ZenitWindow *)create->lpCreateParams;
        win->hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)win);
        return TRUE;
    }
    if (!win) return DefWindowProcW(hwnd, message, wparam, lparam);
    if (win->keyboard_isolated && keyboard_message(message)) return 0;
    if (win->chrome_fullscreen && message==WM_NCHITTEST) return HTCLIENT;
    if (win->custom_frame && !win->chrome_hide_controls && (message==WM_NCHITTEST || message==WM_NCMOUSELEAVE)) {
        LRESULT result=0;
        if (DwmDefWindowProc(hwnd,message,wparam,lparam,&result)) return result;
    }
    switch (message) {
        case WM_MOUSEACTIVATE:
            /* Background input is injected into Cx; OS mouse messages must not
               activate the window before runtime pointer isolation runs. */
            if (show_without_activation()) return MA_NOACTIVATEANDEAT;
            break;
        case WM_GETMINMAXINFO:
            if(win->chrome_min_width||win->chrome_min_height) {
                MINMAXINFO *limits=(MINMAXINFO *)lparam;
                UINT dpi=GetDpiForWindow(hwnd);if(!dpi)dpi=96;
                int width=INT_MAX,height=INT_MAX;
                window_client_extent(win, win->chrome_min_width?win->chrome_min_width:1,
                    win->chrome_min_height?win->chrome_min_height:1, dpi, &width, &height);
                MONITORINFO info={.cbSize=sizeof(info)};
                if(GetMonitorInfoW(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST),&info)) {
                    /* A minimum larger than the monitor must not undo the fit. */
                    if(width>info.rcWork.right-info.rcWork.left)width=info.rcWork.right-info.rcWork.left;
                    if(height>info.rcWork.bottom-info.rcWork.top)height=info.rcWork.bottom-info.rcWork.top;
                }
                if(win->chrome_min_width)limits->ptMinTrackSize.x=width;
                if(win->chrome_min_height)limits->ptMinTrackSize.y=height;
                return 0;
            }
            break;
        case WM_NCMOUSEMOVE:
            if(win->chrome_hide_controls&&win->custom_frame) {
                win->chrome_hover=wparam==HTMINBUTTON?1:wparam==HTMAXBUTTON?2:wparam==HTCLOSE?3:0;
                /* A press released outside the window never reports WM_NCLBUTTONUP;
                   drop it once the button is up so a later release cannot act on it. */
                if(!(GetKeyState(VK_LBUTTON)&0x8000)) win->chrome_pressed=0;
                TRACKMOUSEEVENT track={sizeof(track),TME_LEAVE|TME_NONCLIENT,hwnd,0};TrackMouseEvent(&track);
                win->redraw_requested=1;
            }
            break;
        case WM_NCMOUSELEAVE:
            win->chrome_hover=0;win->chrome_pressed=0;win->redraw_requested=1;
            break;
        case WM_NCLBUTTONDOWN:
            if (show_without_activation()) return 0;
            if(win->chrome_hide_controls&&win->custom_frame) {
                win->chrome_pressed=wparam==HTMINBUTTON?1:wparam==HTMAXBUTTON?2:wparam==HTCLOSE?3:0;
                win->redraw_requested=1;
                if(win->render_callback)win->render_callback(win->render_context);
                /* Application-drawn caption buttons report HTMIN/HTMAX/HTCLOSE so
                   Windows 11 offers Snap Layouts. DefWindowProc's button tracking
                   uses the native caption, which this frame removed, and never
                   issues the command: press here, act on the matching release. */
                if(win->chrome_pressed) return 0;
                LRESULT result=DefWindowProcW(hwnd,message,wparam,lparam);
                win->chrome_pressed=0;win->redraw_requested=1;
                return result;
            }
            break;
        case WM_NCLBUTTONUP: {
            const int released=wparam==HTMINBUTTON?1:wparam==HTMAXBUTTON?2:wparam==HTCLOSE?3:0;
            const int pressed=win->chrome_pressed;
            win->chrome_pressed=0;win->redraw_requested=1;
            if(win->chrome_hide_controls&&win->custom_frame&&pressed) {
                if(pressed==released) {
                    const WPARAM command=pressed==1?SC_MINIMIZE:pressed==3?SC_CLOSE:IsZoomed(hwnd)?SC_RESTORE:SC_MAXIMIZE;
                    PostMessageW(hwnd,WM_SYSCOMMAND,command,lparam);
                }
                return 0;
            }
            break;
        }
        case WM_NCCALCSIZE:
            if (win->custom_frame && wparam && !win->chrome_fullscreen) {
                DefWindowProcW(hwnd,message,wparam,lparam);
                NCCALCSIZE_PARAMS *params=(NCCALCSIZE_PARAMS *)lparam;
                UINT dpi=GetDpiForWindow(hwnd); if (!dpi) dpi=96;
                params->rgrc[0].top-=removed_caption(win, dpi);
                return 0;
            }
            break;
        case WM_DWMCOMPOSITIONCHANGED:
            if (win->custom_frame) custom_frame_margins(win);
            break;
        case WM_ENTERSIZEMOVE:
            win->live_resize = 1;
            SetTimer(hwnd, ZENIT_RESIZE_TIMER, 16, NULL);
            return 0;
        case WM_EXITSIZEMOVE:
            KillTimer(hwnd, ZENIT_RESIZE_TIMER);
            win->live_resize = 0;
            InvalidateRect(hwnd, NULL, FALSE);
            return 0;
        case WM_TIMER:
            if (wparam == ZENIT_REVEAL_TIMER) {
                if (win->owner_changing) return 0;
                KillTimer(hwnd, ZENIT_REVEAL_TIMER);
                if (win->cloaked && !win->presented && !win->concealed && win->alive) {
                    // Degraded path: the renderer never presented a UI frame.
                    fprintf(stderr, "[zenit-window] no frame presented within %d ms; revealing window %u\n",
                        ZENIT_REVEAL_TIMEOUT_MS, (unsigned)win->id);
                    set_cloak(win, 0);
                }
                return 0;
            }
            if (wparam == ZENIT_RESIZE_TIMER && win->live_resize) {
                if (win->render_callback) win->render_callback(win->render_context);
                return 0;
            }
            break;
        case WM_SETCURSOR: {
            HCURSOR cursor;
            // Preserve native frame/resize cursors and child-view ownership.
            if (client_cursor(win, (HWND)wparam, LOWORD(lparam), &cursor)) {
                if (cursor_owned_here(win)) SetCursor(cursor);
                return TRUE;
            }
            if ((HWND)wparam == hwnd && LOWORD(lparam) == HTCLIENT && win->cursor_shape == 20) return FALSE;
            break;
        }
        case WM_COPYDATA:
            return open_path_receive(win, (const COPYDATASTRUCT *)lparam);
        case WM_COMMAND:
            if(!lparam&&(HIWORD(wparam)==0||HIWORD(wparam)==1)){dispatch_menu(win,LOWORD(wparam));return 0;}
            break;
        case WM_NCHITTEST: {
            LRESULT standard = DefWindowProcW(hwnd, message, wparam, lparam);
            if (win->custom_frame) {
                /* Win11 can stop reporting DWM caption hits after maximizing
                   a custom client frame. Preserve the native control roles in
                   the same reserved rectangle used by the painter. */
                RECT buttons; POINT point={GET_X_LPARAM(lparam),GET_Y_LPARAM(lparam)};
                if (zenit_win_caption_button_rect(hwnd,&buttons)>0 && ScreenToClient(hwnd,&point) && PtInRect(&buttons,point)) {
                    int column=(int)(((int64_t)point.x-buttons.left)*3/(buttons.right-buttons.left));
                    return column==0?HTMINBUTTON:column==1?HTMAXBUTTON:HTCLOSE;
                }
            }
            if (win->custom_frame && !IsZoomed(hwnd)) {
                POINT screen={GET_X_LPARAM(lparam),GET_Y_LPARAM(lparam)}; RECT outer;
                UINT dpi=GetDpiForWindow(hwnd); if (!dpi) dpi=96;
                int edge=GetSystemMetricsForDpi(SM_CYSIZEFRAME,dpi)+GetSystemMetricsForDpi(SM_CXPADDEDBORDER,dpi);
                if (GetWindowRect(hwnd,&outer) && screen.x>=outer.left && screen.x<outer.right && screen.y>=outer.top && screen.y<outer.top+edge) {
                    if (screen.x<outer.left+edge) return HTTOPLEFT;
                    if (screen.x>=outer.right-edge) return HTTOPRIGHT;
                    return HTTOP;
                }
            }
            if (win->chrome_hit) {
                if (standard != HTCLIENT) return standard;
                POINT p={GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
                if (!ScreenToClient(hwnd,&p)) return HTCLIENT;
                float scale=(float)GetDpiForWindow(hwnd)/96.0f;
                int region=win->chrome_hit(win->chrome_context,p.x/scale,p.y/scale);
                if (win->chrome_fullscreen) return HTCLIENT;
                if (region==2) return HTCAPTION;
                if (region==11) return HTMINBUTTON;
                if (region==12) return HTMAXBUTTON;
                if (region==13) return HTCLOSE;
                static const int edges[]={HTTOP,HTBOTTOM,HTLEFT,HTTOPLEFT,HTBOTTOMLEFT,HTRIGHT,HTTOPRIGHT,HTBOTTOMRIGHT};
                if (region>=3 && region<=10 && !IsZoomed(hwnd)) return edges[region-3];
                return HTCLIENT;
            }
            if (standard != HTCLIENT || win->titlebar_drag_height <= 0) return standard;
            POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)}; RECT client;
            if (!ScreenToClient(hwnd, &point) || !GetClientRect(hwnd, &client)) return standard;
            float scale = (float)GetDpiForWindow(hwnd) / 96.0f;
            float x = point.x / scale, y = point.y / scale;
            float width = (client.right-client.left) / scale;
            if (x < 0 || y < 0 || y >= win->titlebar_drag_height || point.y >= client.bottom || x >= width-win->titlebar_drag_right_inset) return standard;
            if (win->titlebar_hit_callback && win->titlebar_hit_callback(win->titlebar_hit_context, x, y)) return standard;
            return HTCAPTION;
        }
        case WM_GETOBJECT:
            return zenit_uia_get_object(win->accessibility, wparam, lparam);
        case ZENIT_UIA_WAKE_MESSAGE:
            // Wake the App loop; mutations are drained outside WndProc/paint.
            return 0;
        case WM_MOVE:
            // Refresh screen-space accessibility bounds even with an idle UI.
            if (win->render_callback) InvalidateRect(hwnd, NULL, FALSE);
            break;
        case WM_SETTINGCHANGE:
            win->text_settings_generation++;
            SetPropW(hwnd, L"Zenit.TextSettingsGeneration", (HANDLE)(uintptr_t)win->text_settings_generation);
            win->redraw_requested = 1;
            InvalidateRect(hwnd, NULL, FALSE);
            break;
        case WM_DISPLAYCHANGE:
            win->text_settings_generation++;
            SetPropW(hwnd, L"Zenit.TextSettingsGeneration", (HANDLE)(uintptr_t)win->text_settings_generation);
            win->refresh_monitor = NULL;
            if (win->render_callback) InvalidateRect(hwnd, NULL, FALSE);
            break;
        case WM_CLOSE:
            zenit_drag_source_cancel(win->drag_source);
            win->close_requested = 1;
            return 0;
        case WM_ACTIVATE:
            if (win->custom_frame) custom_frame_margins(win);
            if(LOWORD(wparam)==WA_INACTIVE){
                zenit_drag_source_cancel(win->drag_source);
                /* lParam is the window being activated; NULL or a window of
                   another thread/process means the user switched away. */
                HWND next = (HWND)lparam;
                DWORD pid = 0;
                if (next) GetWindowThreadProcessId(next, &pid);
                win->focus_loss = (next && pid == GetCurrentProcessId()) ? 1 : 2;
            }
            break;
        case WM_DESTROY:
            KillTimer(hwnd, ZENIT_RESIZE_TIMER);
            win->live_resize = 0;
            win->chrome_hit = NULL; win->chrome_context = NULL;
            win->titlebar_hit_callback = NULL;
            win->titlebar_hit_context = NULL;
            clear_menu(win);
            zenit_uia_destroy(win->accessibility);
            win->accessibility = NULL;
            zenit_drag_source_cancel(win->drag_source);
            zenit_drag_source_release(win->drag_source);
            win->drag_source = NULL;
            memset(&win->source_result,0,sizeof(win->source_result));
            zenit_drop_destroy(win->drop_target);
            win->drop_target = NULL;
            if (win->detached_ime_context) {
                ImmAssociateContext(hwnd, win->detached_ime_context);
                win->detached_ime_context = NULL;
            }
            if (win->alive && live_windows > 0) --live_windows;
            win->alive = 0;
            win->hwnd = NULL;
            return 0;
        case WM_SETFOCUS:
            if (win->render_callback) InvalidateRect(hwnd, NULL, FALSE);
            return DefWindowProcW(hwnd, message, wparam, lparam);
        case WM_KILLFOCUS:
        case WM_CAPTURECHANGED:
        case WM_CANCELMODE:
            if (message == WM_KILLFOCUS && win->render_callback) InvalidateRect(hwnd, NULL, FALSE);
            win->chrome_pressed=0;win->chrome_hover=0;win->redraw_requested=1;
            cancel_pointer(win);
            if (message == WM_KILLFOCUS && win->ime_active) {
                push_ime(win, 1, L"", 0, 0);
                win->ime_active = 0;
            }
            return DefWindowProcW(hwnd, message, wparam, lparam);
        case WM_MOUSEMOVE:
            /* Client-area leave notification (moving onto the app-drawn caption, another
               window or off the window), so the runtime stops trusting the last position. */
            if (!win->leave_tracked) {
                TRACKMOUSEEVENT track={sizeof(track),TME_LEAVE,hwnd,0};
                if (TrackMouseEvent(&track)) win->leave_tracked=1;
            }
            push_move(win, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam), wparam);
            return 0;
        case WM_MOUSELEAVE:
            win->leave_tracked=0;
            push_leave(win);
            return 0;
        case WM_SIZE:
            // Present the new extent before DWM composes it. Otherwise resize,
            // maximize and restore show the previous frame until the next
            // timer tick or WM_PAINT. The App defers a nested frame.
            if (wparam != SIZE_MINIMIZED && LOWORD(lparam) && HIWORD(lparam) && win->render_callback && !win->dpi_changing && !win->owner_changing)
                win->render_callback(win->render_context);
            break;
        case WM_DPICHANGED: {
            RECT next = *(RECT *)lparam;
            HMONITOR monitor = MonitorFromRect(&next, MONITOR_DEFAULTTONEAREST);
            if (win->chrome_fullscreen) {
                MONITORINFO info = { .cbSize = sizeof(info) };
                if (GetMonitorInfoW(monitor, &info)) next = info.rcMonitor;
            } else if (!IsZoomed(hwnd)) constrain_window_frame(&next, monitor);
            RECT *suggested = &next;
            win->dpi_changing = 1;
            SetWindowPos(hwnd, NULL, suggested->left, suggested->top,
                suggested->right - suggested->left, suggested->bottom - suggested->top,
                SWP_NOZORDER | SWP_NOACTIVATE);
            if (win->custom_frame) custom_frame_margins(win);
            win->dpi_changing = 0;
            win->redraw_requested = 1;
            if (win->render_callback && !win->owner_changing) win->render_callback(win->render_context);
            return 0;
        }
        case WM_LBUTTONDOWN: case WM_LBUTTONUP:
        case WM_RBUTTONDOWN: case WM_RBUTTONUP:
        case WM_MBUTTONDOWN: case WM_MBUTTONUP: {
            int down = message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN || message == WM_MBUTTONDOWN;
            int code = message == WM_LBUTTONDOWN || message == WM_LBUTTONUP ? 0 :
                message == WM_RBUTTONDOWN || message == WM_RBUTTONUP ? 1 : 2;
            win->mouse_x = GET_X_LPARAM(lparam);
            win->mouse_y = GET_Y_LPARAM(lparam);
            if (down) win->button_mask |= 1u << code;
            else win->button_mask &= ~(1u << code);
            if (down && !show_without_activation()) { SetCapture(hwnd); SetFocus(hwnd); }
            else if (!win->button_mask && GetCapture() == hwnd) ReleaseCapture();
            push_button(win, code, down, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
            return 0;
        }
        case WM_MOUSEWHEEL:
            push_wheel(win, hwnd, lparam, 0,
                (float)GET_WHEEL_DELTA_WPARAM(wparam) * 40.0f / WHEEL_DELTA);
            return 0;
        case WM_MOUSEHWHEEL:
            // Win32 positive means scroll right; Zenit deltas describe content
            // motion, so a rightward viewport scroll must carry negative dx.
            push_wheel(win, hwnd, lparam,
                -(float)GET_WHEEL_DELTA_WPARAM(wparam) * 40.0f / WHEEL_DELTA, 0);
            return 0;
        case WM_KEYDOWN: case WM_SYSKEYDOWN:
        case WM_KEYUP: case WM_SYSKEYUP:
            if(wparam==VK_ESCAPE&&(message==WM_KEYDOWN||message==WM_SYSKEYDOWN))zenit_drag_source_cancel(win->drag_source);
            {
                uint16_t code = (uint16_t)wparam;
                uint32_t mods = modifiers();
                /* An active IME (e.g. Microsoft Pinyin) reports keys it
                   processes as VK_PROCESSKEY. With Ctrl or Alt held the key
                   is a shortcut, not text: report the key that was pressed
                   (ImmGetVirtualKey), or every Ctrl+letter shortcut is lost
                   while the IME is on. */
                if (code == VK_PROCESSKEY && (mods & (2 | 4))) {
                    UINT real = ImmGetVirtualKey(hwnd);
                    if (real && real != VK_PROCESSKEY) code = (uint16_t)real;
                    else if (lparam) {
                        UINT mapped = MapVirtualKeyW((UINT)((lparam >> 16) & 0xFF), MAPVK_VSC_TO_VK);
                        if (mapped) code = (uint16_t)mapped;
                    }
                }
                push_key(win, code, mods, message == WM_KEYDOWN || message == WM_SYSKEYDOWN);
            }
            break;
        case WM_IME_STARTCOMPOSITION:
            win->ime_active = 1;
            return 0;
        case WM_IME_COMPOSITION: {
            HIMC context = ImmGetContext(hwnd);
            if (!context) return DefWindowProcW(hwnd, message, wparam, lparam);
            if (lparam & GCS_RESULTSTR)
                read_ime_string(win, context, GCS_RESULTSTR, 2);
            if (lparam & GCS_COMPSTR)
                read_ime_string(win, context, GCS_COMPSTR, 1);
            else if (lparam & GCS_RESULTSTR)
                push_ime(win, 1, L"", 0, 0);
            ImmReleaseContext(hwnd, context);
            return 0;
        }
        case WM_IME_ENDCOMPOSITION:
            if (win->ime_active) push_ime(win, 1, L"", 0, 0);
            win->ime_active = 0;
            return 0;
        case WM_CHAR: {
            uint16_t unit = (uint16_t)wparam;
            if (unit >= 0xD800 && unit <= 0xDBFF) {
                win->high_surrogate = unit;
                return 0;
            }
            if (unit >= 0xDC00 && unit <= 0xDFFF) {
                if (win->high_surrogate) {
                    wchar_t pair[2] = {(wchar_t)win->high_surrogate, (wchar_t)unit};
                    push_text(win, pair, 2);
                }
                win->high_surrogate = 0;
                return 0;
            }
            win->high_surrogate = 0;
            /* Control characters are keys, not text: Ctrl+letter arrives as
               a C0 code (Ctrl+F = 0x06) and Backspace/Enter/Tab/Escape as
               theirs, all of which the key events already carry. As text they
               would land in the document as invisible characters. */
            if (unit < 0x20 || unit == 0x7F) return 0;
            wchar_t wide = (wchar_t)unit;
            push_text(win, &wide, 1);
            return 0;
        }
        case WM_ERASEBKGND:
            // GPU callbacks clear and repaint the entire client. Letting GDI
            // erase first exposes a white frame during resize/reveal/redraw.
            // The standalone GDI probe keeps Windows' default erasure.
            if (win->render_callback) return 1;
            return DefWindowProcW(hwnd, message, wparam, lparam);
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(hwnd, &ps);
            if (win->owner_changing) {
                EndPaint(hwnd,&ps);
                win->redraw_requested=1;
                return 0;
            }
            if (win->render_callback) {
                // The DWM-owned button region must have zero alpha in the
                // underlying redirection bitmap as well as the GPU visual.
                // GDI BLACKNESS supplies transparent black to extended glass.
                RECT buttons;
                if (win->custom_frame && zenit_win_caption_button_rect(hwnd,&buttons)>0)
                    PatBlt(dc,buttons.left,buttons.top,buttons.right-buttons.left,
                        buttons.bottom-buttons.top,BLACKNESS);
                win->render_callback(win->render_context);
            } else {
#ifdef ZENIT_GDI_PROBE
                RECT rect;
                GetClientRect(hwnd, &rect);
                FillRect(dc, &rect, (HBRUSH)(COLOR_WINDOW + 1));
                RECT swatch = {32, 88, 192, 152};
                HBRUSH color = CreateSolidBrush(RGB(42, 118, 221));
                FillRect(dc, &swatch, color);
                DeleteObject(color);
                static const wchar_t label[] = L"Zenit Win32 ARM64 window probe";
                TextOutW(dc, 32, 32, label, (int)(sizeof(label) / sizeof(label[0]) - 1));
#endif
                /* Without a renderer an application window has no content to
                   show: it is cloaked before its first frame and after
                   teardown begins, so validating the update region is all. */
            }
            EndPaint(hwnd, &ps);
            win->redraw_requested = 0;
            return 0;
        }
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static int ensure_window_class(void) {
    if (window_class) return 1;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSEXW cls = {0};
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = window_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = class_name;
    cls.hCursor = LoadCursorW(NULL, IDC_ARROW);
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    window_class = RegisterClassExW(&cls);
    return window_class != 0;
}

static int client_window_extent(uint32_t width, uint32_t height, UINT dpi,
        DWORD style, DWORD ex_style, BOOL menu, int removed_caption, int *outer_width, int *outer_height) {
    if (!width || !height) return 0;
    if (!dpi) dpi = 96;
    // Round up using the DPI ratio exactly. Truncation loses a logical pixel
    // on e.g. an 801px client at 175% scaling (1401 instead of 1402 pixels).
    uint64_t pixels_w = ((uint64_t)width * dpi + 95) / 96;
    uint64_t pixels_h = ((uint64_t)height * dpi + 95) / 96;
    if (pixels_w > INT_MAX || pixels_h > INT_MAX) return 0;
    // Center the input rectangle to leave room for non-client insets without
    // overflowing a LONG coordinate near its positive limit.
    LONG half_w = (LONG)(pixels_w / 2), half_h = (LONG)(pixels_h / 2);
    RECT bounds = {-half_w, -half_h, (LONG)(pixels_w-half_w), (LONG)(pixels_h-half_h)};
    if (!AdjustWindowRectExForDpi(&bounds, style, menu, ex_style, dpi)) return 0;
    int64_t w = (int64_t)bounds.right - bounds.left;
    int64_t h = (int64_t)bounds.bottom - bounds.top - removed_caption;
    if (w <= 0 || h <= 0 || w > INT_MAX || h > INT_MAX) return 0;
    *outer_width = (int)w;
    *outer_height = (int)h;
    return 1;
}

static void calculated_client(void *context, int width, int height, int *client_width, int *client_height) {
    ZenitWindow *win=context;
    NCCALCSIZE_PARAMS params = {0};
    params.rgrc[0] = (RECT){0,0,width,height};
    WINDOWPOS pos = {.hwnd=win->hwnd,.cx=width,.cy=height};
    params.lppos = &pos;
    SendMessageW(win->hwnd, WM_NCCALCSIZE, TRUE, (LPARAM)&params);
    *client_width=params.rgrc[0].right-params.rgrc[0].left;
    *client_height=params.rgrc[0].bottom-params.rgrc[0].top;
}

static int window_client_extent(ZenitWindow *win, uint32_t width, uint32_t height,
        UINT dpi, int *outer_width, int *outer_height) {
    if (!dpi) dpi=96;
    DWORD style = (DWORD)GetWindowLongPtrW(win->hwnd, GWL_STYLE);
    DWORD ex_style = (DWORD)GetWindowLongPtrW(win->hwnd, GWL_EXSTYLE);
    int w, h;
    if (!client_window_extent(width,height,dpi,style,ex_style,GetMenu(win->hwnd)!=NULL,
            removed_caption(win,dpi),&w,&h)) return 0;
    int64_t wanted_w=((uint64_t)width*dpi+95)/96;
    int64_t wanted_h=((uint64_t)height*dpi+95)/96;
    MONITORINFO info = {.cbSize=sizeof(info)};
    int cap_w=INT_MAX, cap_h=INT_MAX;
    if (!win->chrome_fullscreen && !IsZoomed(win->hwnd)) {
        if (!GetMonitorInfoW(MonitorFromWindow(win->hwnd,MONITOR_DEFAULTTONEAREST),&info)) return 0;
        cap_w=info.rcWork.right-info.rcWork.left; cap_h=info.rcWork.bottom-info.rcWork.top;
    }
    return zenit_resolve_client_extent(wanted_w,wanted_h,cap_w,cap_h,w,h,
        win,calculated_client,outer_width,outer_height);
}

static int initial_geometry(ZenitWindow *win, uint32_t width, uint32_t height, RECT *frame) {
    int w,h;
    if (!window_client_extent(win,width,height,GetDpiForWindow(win->hwnd),&w,&h)) return 0;
    frame->right=frame->left+w; frame->bottom=frame->top+h;
    return constrain_window_frame(frame,MonitorFromWindow(win->hwnd,MONITOR_DEFAULTTONEAREST));
}

#ifdef ZENIT_WINDOW_CONTRACT
/* The contract sizes a real HWND through the same path as create/set_size. */
int zenit_windows_contract_initial_geometry(ZenitWindow *win, uint32_t width, uint32_t height) {
    RECT frame;
    if (!win || !GetWindowRect(win->hwnd,&frame) || !initial_geometry(win,width,height,&frame)) return 0;
    return SetWindowPos(win->hwnd,NULL,frame.left,frame.top,frame.right-frame.left,
        frame.bottom-frame.top,SWP_NOZORDER|SWP_NOACTIVATE);
}
#endif

/* Background e2e runs (and window contracts) never take the foreground. */
static int show_without_activation(void) {
    char background[2] = {0};
    int no_activate = GetEnvironmentVariableA("ZENIT_E2E_BACKGROUND", background, sizeof(background)) == 1 && background[0] == '1';
#ifdef ZENIT_WINDOW_CONTRACT
    if (contract_background_windows >= 0) no_activate = contract_background_windows;
#endif
    return no_activate;
}

/* flags: ZENIT_CREATE_HIDDEN — the runtime configures the window first (an
   owner, a position) and shows it with zenit_windows_show.
   ZENIT_CREATE_REVEAL_ON_PRESENT — the window is shown cloaked and appears
   only once zenit_windows_note_presented reports its first GPU frame. Showing an active window and then making
   it owned re-shows it, which hands activation to the owner and reports a
   focus loss to the new window (an owned panel closing itself at once). */
ZenitWindow *zenit_windows_create_ex(uint32_t width, uint32_t height, const char *title, int flags) {
    int hidden = (flags & ZENIT_CREATE_HIDDEN) != 0;
    if (!ensure_window_class()) return NULL;
    if (!width || !height) return NULL;
    ZenitWindow *win = (ZenitWindow *)calloc(1, sizeof(*win));
    if (!win) return NULL;
    win->requested_width = width;
    win->requested_height = height;
    win->id = next_id++;
    win->ime_enabled = 1;
    win->reveal_on_present = (flags & ZENIT_CREATE_REVEAL_ON_PRESENT) != 0;
    int title_chars = MultiByteToWideChar(CP_UTF8, 0, title, -1, NULL, 0);
    wchar_t *wide = title_chars > 0 ? (wchar_t *)calloc((size_t)title_chars, sizeof(wchar_t)) : NULL;
    if (!wide) { free(win); return NULL; }
    MultiByteToWideChar(CP_UTF8, 0, title, -1, wide, title_chars);
    DWORD ex_style = 0;
    HWND hwnd = CreateWindowExW(ex_style, class_name, wide, WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
        CW_USEDEFAULT, NULL, NULL, GetModuleHandleW(NULL), win);
    free(wide);
    if (!hwnd) { free(win); return NULL; }
    /* Let Win32 select the launch monitor before querying its per-window DPI.
       The HWND remains hidden until its final client extent is established. */
    RECT frame;
    if (!GetWindowRect(hwnd, &frame) || !initial_geometry(win,width,height,&frame)) {
        DestroyWindow(hwnd); free(win); return NULL;
    }
    if (!SetWindowPos(hwnd, NULL, frame.left, frame.top, frame.right-frame.left,
            frame.bottom-frame.top, SWP_NOZORDER | SWP_NOACTIVATE)) {
        DestroyWindow(hwnd); free(win); return NULL;
    }
    if(!live_windows)app_quit_requested=0;
    win->alive = 1;
    win->accessibility = zenit_uia_create(hwnd);
    win->drop_target = zenit_drop_create(hwnd, next_drag_serial, win);
    ++live_windows;
    if (!hidden) zenit_windows_show(win);
    return win;
}

ZenitWindow *zenit_windows_create(uint32_t width, uint32_t height, const char *title) {
    return zenit_windows_create_ex(width, height, title, 0);
}

void zenit_windows_show(ZenitWindow *win) {
    if (!win || !win->hwnd || IsWindowVisible(win->hwnd)) return;
    // Showing cloaked keeps activation, sizing and the swap chain real while
    // DWM composes nothing until the first frame is presented.
    if (win->reveal_on_present && !win->presented) {
        set_cloak(win, 1);
        // Without the fallback timer a renderer that never presents would
        // leave an invisible running application: stay uncloaked instead.
        if (win->cloaked && !SetTimer(win->hwnd, ZENIT_REVEAL_TIMER, ZENIT_REVEAL_TIMEOUT_MS, NULL))
            set_cloak(win, 0);
    }
    const int show = show_without_activation() ? SW_SHOWNOACTIVATE : SW_SHOW;
    ShowWindow(win->hwnd, show);
    // The first ShowWindow in a process takes the launcher's STARTUPINFO show
    // state instead: a child spawned with SW_HIDE (Node/Bun windowsHide, used
    // to hide a console) would keep its first window hidden for good. Only a
    // still-hidden window is shown again; a launcher's minimize stands.
    if (!IsWindowVisible(win->hwnd)) ShowWindow(win->hwnd, show);
    UpdateWindow(win->hwnd);
}

/* The renderer presented a frame: reveal a window waiting for its first one. */
void zenit_windows_note_presented(ZenitWindow *win) {
    // Only a shown window reveals; teardown keeps a concealed window cloaked.
    if (!win || win->presented || win->concealed || win->owner_changing || !win->hwnd || !IsWindowVisible(win->hwnd)) return;
    win->presented = 1;
    if (!win->cloaked || !win->hwnd) return;
    KillTimer(win->hwnd, ZENIT_REVEAL_TIMER);
    // A presented buffer (and a DirectComposition commit) reaches the screen
    // on DWM's next composition. Uncloaking first composes the redirection
    // surface behind it for one refresh; wait for that composition once.
    DwmFlush();
    set_cloak(win, 0);
}

/* Teardown is starting: hide the window's contents before the renderer
   detaches, without moving activation as SW_HIDE would mid-close. */
void zenit_windows_conceal(ZenitWindow *win) {
    if (!win || !win->hwnd) return;
    win->concealed = 1;
    KillTimer(win->hwnd, ZENIT_REVEAL_TIMER);
    set_cloak(win, 1);
}

void zenit_windows_destroy(ZenitWindow *win) {
    if (!win) return;
    if (win->hwnd && win->detached_ime_context)
        ImmAssociateContext(win->hwnd, win->detached_ime_context);
    if (win->hwnd) DestroyWindow(win->hwnd);
    while (win->ime_read != win->ime_write) {
        free(win->ime[win->ime_read].bytes);
        win->ime_read = queue_next(win->ime_read);
    }
    free(win);
}
int zenit_windows_publish_accessibility(ZenitWindow *win, const ZenitA11yNode *nodes, size_t count) {
    return win && win->alive && zenit_uia_publish(win->accessibility, nodes, count);
}
int zenit_windows_set_accessibility_action(ZenitWindow *win, void *context, ZenitA11yActionCallback callback) {
    return win && win->alive && zenit_uia_set_action_handler(win->accessibility, context, callback);
}
int zenit_windows_drain_accessibility(ZenitWindow *win) {
    return win && win->alive ? zenit_uia_drain(win->accessibility) : 0;
}
int zenit_windows_app_should_quit(void) {return app_quit_requested;}
/* The application vetoed the quit request (e.g. unsaved work); keep running. */
void zenit_windows_cancel_app_quit(void) {app_quit_requested = 0;}

/* Owned window: stays above its owner, hides when the owner is minimised and
   has no taskbar button. Owner destruction also destroys the owned HWND, so the
   runtime closes owned windows before their owner. */
int zenit_windows_set_size(ZenitWindow *win, uint32_t width, uint32_t height);

#ifdef ZENIT_WINDOW_CONTRACT
static int contract_owner_resize_failure;
void zenit_windows_contract_owner_resize_failure(void) { contract_owner_resize_failure=1; }
static int contract_taskbar_failure;
void zenit_windows_contract_taskbar_failure(void) { contract_taskbar_failure=1; }
#endif

static int fit_owned_frame(HWND hwnd, const RECT *frame) {
#ifdef ZENIT_WINDOW_CONTRACT
    if (contract_owner_resize_failure) { contract_owner_resize_failure=0; return 0; }
#endif
    return SetWindowPos(hwnd,NULL,frame->left,frame->top,frame->right-frame->left,
        frame->bottom-frame->top,SWP_NOZORDER|SWP_NOACTIVATE);
}

static int restore_owner_frame(ZenitWindow *win, const RECT *frame) {
    if (SetWindowPos(win->hwnd,NULL,frame->left,frame->top,frame->right-frame->left,
            frame->bottom-frame->top,SWP_NOZORDER|SWP_NOACTIVATE)) return 1;
    fprintf(stderr,"[zenit-window] owner geometry rollback failed: %lu\n",GetLastError());
    zenit_windows_conceal(win);
    return 0;
}

static HRESULT remove_taskbar_tab(HWND hwnd) {
#ifdef ZENIT_WINDOW_CONTRACT
    if (contract_taskbar_failure) { contract_taskbar_failure=0; return E_FAIL; }
#endif
    ITaskbarList *taskbar=NULL;
    HRESULT hr=CoCreateInstance(&CLSID_TaskbarList,NULL,CLSCTX_INPROC_SERVER,&IID_ITaskbarList,(void **)&taskbar);
    if (SUCCEEDED(hr)) {
        hr=ITaskbarList_HrInit(taskbar);
        if (SUCCEEDED(hr)) hr=ITaskbarList_DeleteTab(taskbar,hwnd);
        ITaskbarList_Release(taskbar);
    }
    return hr;
}

int zenit_windows_set_owner(ZenitWindow *win, ZenitWindow *owner) {
    if (!win || !win->hwnd || !owner || !owner->hwnd || win == owner) return 0;
    RECT frame, fitted;
    if (!GetWindowRect(win->hwnd,&frame)) return 0;
    fitted=frame;
    if (!win->chrome_fullscreen && !IsZoomed(win->hwnd)) {
        MONITORINFO info={.cbSize=sizeof(info)};
        if (!GetMonitorInfoW(MonitorFromWindow(win->hwnd,MONITOR_DEFAULTTONEAREST),&info)) return 0;
        RECT visible=frame;
        RECT dwm;
        int known=SUCCEEDED(DwmGetWindowAttribute(win->hwnd,DWMWA_EXTENDED_FRAME_BOUNDS,&dwm,sizeof(dwm))) &&
            dwm.right>dwm.left && dwm.bottom>dwm.top && dwm.left>=frame.left && dwm.top>=frame.top &&
            dwm.right<=frame.right && dwm.bottom<=frame.bottom;
        if (known) visible=dwm;
        /* Both rectangles are screen pixels in the per-monitor-aware context.
           Without DWM bounds, constrain extent but do not guess placement. */
        ZenitGeometryRect out;
        if (!zenit_fit_owned_geometry((ZenitGeometryRect){frame.left,frame.top,frame.right,frame.bottom},
                (ZenitGeometryRect){visible.left,visible.top,visible.right,visible.bottom},
                (ZenitGeometryRect){info.rcWork.left,info.rcWork.top,info.rcWork.right,info.rcWork.bottom},known,&out)) return 0;
        fitted=(RECT){out.left,out.top,out.right,out.bottom};
    }
    int needs_fit=memcmp(&frame,&fitted,sizeof(frame))!=0;
#ifdef ZENIT_WINDOW_CONTRACT
    needs_fit |= contract_owner_resize_failure;
#endif
    /* Finish fallible geometry before assigning the owner. Suppress synchronous
       resize rendering until ownership and shell bookkeeping are complete. */
    win->owner_changing=1;
    if (needs_fit && !fit_owned_frame(win->hwnd,&fitted)) {
        restore_owner_frame(win,&frame);
        win->owner_changing=0;
        return 0;
    }
    SetLastError(0);
    LONG_PTR previous=SetWindowLongPtrW(win->hwnd,GWLP_HWNDPARENT,(LONG_PTR)owner->hwnd);
    if (!previous && GetLastError()) {
        if (needs_fit) restore_owner_frame(win,&frame);
        win->owner_changing=0;
        return 0;
    }
    /* Best effort for an already-visible window; shell availability does not
       determine ownership. Runtime-owned windows are configured before show. */
    if (IsWindowVisible(win->hwnd)) {
        HRESULT hr=remove_taskbar_tab(win->hwnd);
        if (FAILED(hr)) fprintf(stderr,"[zenit-window] taskbar tab removal failed: 0x%08lx\n",(unsigned long)hr);
    }
    win->owner_changing=0;
    if ((needs_fit || win->redraw_requested) && win->render_callback) win->render_callback(win->render_context);
    return 1;
}
void zenit_windows_clear_owner(ZenitWindow *win) {
    if (win && win->hwnd) SetWindowLongPtrW(win->hwnd, GWLP_HWNDPARENT, 0);
}
/* Outer frames and the owner's monitor work area in virtual-screen pixels
   (top-left origin, y down): host x,y,w,h, panel w,h, work x,y,w,h.
   Returns 0 when either window is gone. */
int zenit_windows_owner_geometry(ZenitWindow *win, ZenitWindow *owner, double out[10]) {
    if (!win || !win->hwnd || !owner || !owner->hwnd) return 0;
    RECT host, panel;
    if (!GetWindowRect(owner->hwnd, &host) || !GetWindowRect(win->hwnd, &panel)) return 0;
    MONITORINFO info = { .cbSize = sizeof(info) };
    HMONITOR monitor = MonitorFromWindow(owner->hwnd, MONITOR_DEFAULTTONEAREST);
    if (!monitor || !GetMonitorInfoW(monitor, &info)) return 0;
    out[0] = host.left; out[1] = host.top;
    out[2] = host.right - host.left; out[3] = host.bottom - host.top;
    out[4] = panel.right - panel.left; out[5] = panel.bottom - panel.top;
    out[6] = info.rcWork.left; out[7] = info.rcWork.top;
    out[8] = info.rcWork.right - info.rcWork.left; out[9] = info.rcWork.bottom - info.rcWork.top;
    return 1;
}
void zenit_windows_set_origin(ZenitWindow *win, double x, double y) {
    if (win && win->hwnd)
        SetWindowPos(win->hwnd, NULL, (int)x, (int)y, 0, 0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}
int zenit_windows_take_focus_loss(ZenitWindow *win) {
    if (!win) return 0;
    int value = win->focus_loss;
    win->focus_loss = 0;
    return value;
}
int zenit_windows_poll(ZenitWindow *win) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        dispatch_native_message(&msg);
    }
    return win && win->alive && !app_quit_requested;
}
/* Cross-thread wake for the UI pump (watchers, LSP readers, terminal
 * output): an auto-reset event the pump waits on next to the message queue.
 * Created lazily with a compare-exchange so any thread may wake first. */
static HANDLE volatile g_wake_event;
static HANDLE zenit_wake_event(void) {
    HANDLE existing = g_wake_event;
    if (existing) return existing;
    HANDLE created = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!created) return NULL;
    HANDLE previous = InterlockedCompareExchangePointer((PVOID volatile *)&g_wake_event, created, NULL);
    if (previous) { CloseHandle(created); return previous; }
    return created;
}
void zenit_windows_post_empty_event(void) {
    HANDLE event = zenit_wake_event();
    if (event) SetEvent(event);
}

void zenit_windows_pump_timeout(uint32_t timeout_ms) {
    HANDLE event = zenit_wake_event();
    MsgWaitForMultipleObjectsEx(event ? 1 : 0, event ? &event : NULL, timeout_ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        dispatch_native_message(&msg);
    }
}
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif
/* Like zenit_windows_pump_timeout, but the deadline is honoured to well under
 * a millisecond: a plain wait timeout rounds up to the system timer tick
 * (15.6 ms by default), so a 16 ms timeout sleeps ~31 ms. Used where the loop
 * must wake when timed input is due, as a real input message would wake it. */
void zenit_windows_pump_timeout_precise(uint32_t timeout_us) {
    static HANDLE timer;
    if (!timer) timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    LARGE_INTEGER due;
    due.QuadPart = -(LONGLONG)timeout_us * 10;
    if (!timer || !timeout_us || !SetWaitableTimerEx(timer, &due, 0, NULL, NULL, NULL, 0)) {
        zenit_windows_pump_timeout(timeout_us ? (timeout_us + 999) / 1000 : 0);
        return;
    }
    HANDLE handles[2];
    DWORD count = 0;
    HANDLE event = zenit_wake_event();
    if (event) handles[count++] = event;
    handles[count++] = timer;
    MsgWaitForMultipleObjectsEx(count, handles, (timeout_us + 999) / 1000 + 16, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    CancelWaitableTimer(timer);
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        dispatch_native_message(&msg);
    }
}
int zenit_windows_begin_close(ZenitWindow *win) {
    if (!win || !win->alive) return 1;
    DestroyWindow(win->hwnd);
    return !win->alive;
}
int zenit_windows_closed(const ZenitWindow *win) { return !win || !win->alive; }
int zenit_windows_should_close(const ZenitWindow *win) { return !win || win->close_requested; }
void zenit_windows_reset_close(ZenitWindow *win) { if (win) win->close_requested = 0; }
void zenit_windows_size(ZenitWindow *win, uint32_t *width, uint32_t *height) {
    RECT rect = {0};
    if (win && win->hwnd) GetClientRect(win->hwnd, &rect);
    UINT dpi = win && win->hwnd ? GetDpiForWindow(win->hwnd) : 96;
    if (!dpi) dpi = 96;
    // Avoid float rounding just below an integer for non-binary DPI ratios.
    *width = (uint32_t)((uint64_t)(rect.right - rect.left) * 96 / dpi);
    *height = (uint32_t)((uint64_t)(rect.bottom - rect.top) * 96 / dpi);
}
void zenit_windows_drawable_size(ZenitWindow *win, uint32_t *width, uint32_t *height) {
    RECT rect = {0};
    if (win && win->hwnd) GetClientRect(win->hwnd, &rect);
    *width = (uint32_t)(rect.right - rect.left);
    *height = (uint32_t)(rect.bottom - rect.top);
}
int zenit_windows_set_size(ZenitWindow *win, uint32_t width, uint32_t height) {
    if (!win || !win->hwnd || window_owner(win->hwnd) != win) return 0;
    int outer_width, outer_height;
    if (!window_client_extent(win, width, height, GetDpiForWindow(win->hwnd), &outer_width, &outer_height)) return 0;
    RECT requested;
    if (!GetWindowRect(win->hwnd, &requested)) return 0;
    requested.right = requested.left+outer_width;
    requested.bottom = requested.top+outer_height;
    if (!win->chrome_fullscreen && !IsZoomed(win->hwnd))
        constrain_window_frame(&requested, MonitorFromWindow(win->hwnd, MONITOR_DEFAULTTONEAREST));
    if (!SetWindowPos(win->hwnd, NULL, requested.left, requested.top, requested.right-requested.left,
        requested.bottom-requested.top, SWP_NOZORDER | SWP_NOACTIVATE)) return 0;
    win->requested_width = width;
    win->requested_height = height;
    return 1;
}
int zenit_windows_live_resize(ZenitWindow *win) {
    return win && win->hwnd && win->alive && win->live_resize;
}
float zenit_windows_scale(ZenitWindow *win) {
    return window_scale(win);
}

static float refresh_from_ratio(UINT32 numerator, UINT32 denominator) {
    if (!denominator) return 0;
    float rate = (float)((double)numerator / denominator);
    return isfinite(rate) && rate > 1 ? rate : 0;
}

static float display_refresh(const wchar_t *device) {
    // CCD retains fractional rates while DEVMODE reports integer Hertz.
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        UINT32 path_count = 0, mode_count = 0;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != ERROR_SUCCESS || !path_count || !mode_count) break;
        DISPLAYCONFIG_PATH_INFO *paths = calloc(path_count, sizeof(*paths));
        DISPLAYCONFIG_MODE_INFO *modes = calloc(mode_count, sizeof(*modes));
        if (!paths || !modes) { free(paths); free(modes); break; }
        LONG status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths, &mode_count, modes, NULL);
        float rate = 0;
        if (status == ERROR_SUCCESS) {
            for (UINT32 i = 0; i < path_count; ++i) {
                DISPLAYCONFIG_SOURCE_DEVICE_NAME source = {0};
                source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                source.header.size = sizeof(source);
                source.header.adapterId = paths[i].sourceInfo.adapterId;
                source.header.id = paths[i].sourceInfo.id;
                if (DisplayConfigGetDeviceInfo(&source.header) == ERROR_SUCCESS && wcscmp(source.viewGdiDeviceName, device) == 0) {
                    rate = refresh_from_ratio(paths[i].targetInfo.refreshRate.Numerator, paths[i].targetInfo.refreshRate.Denominator);
                    if (rate > 0) break;
                }
            }
        }
        free(paths);
        free(modes);
        if (rate > 0) return rate;
        if (status != ERROR_INSUFFICIENT_BUFFER) break;
    }
    // Remote/legacy drivers may not expose CCD paths. Values 0/1 mean default.
    DEVMODEW mode = {0};
    mode.dmSize = sizeof(mode);
    if (EnumDisplaySettingsW(device, ENUM_CURRENT_SETTINGS, &mode) && mode.dmDisplayFrequency > 1)
        return (float)mode.dmDisplayFrequency;
    return 60;
}

float zenit_windows_display_refresh(ZenitWindow *win) {
    if (!win || !win->alive || !win->hwnd) return 60;
    HMONITOR monitor = MonitorFromWindow(win->hwnd, MONITOR_DEFAULTTONEAREST);
    if (monitor && monitor == win->refresh_monitor) return win->refresh_hz;
    MONITORINFOEXW info = {0};
    info.cbSize = sizeof(info);
    float rate = 60;
    if (monitor && GetMonitorInfoW(monitor, (MONITORINFO *)&info)) {
#ifdef ZENIT_WINDOW_CONTRACT
        rate = win->contract_refresh_hz > 0 ? win->contract_refresh_hz : display_refresh(info.szDevice);
#else
        rate = display_refresh(info.szDevice);
#endif
    }
    win->refresh_monitor = monitor;
    win->refresh_hz = rate;
    return rate;
}

#ifdef ZENIT_WINDOW_CONTRACT
// Test-only display source: does not modify the desktop's display mode.
void zenit_win_contract_refresh_source(ZenitWindow *win, UINT32 numerator, UINT32 denominator) {
    if (win) win->contract_refresh_hz = refresh_from_ratio(numerator, denominator);
}
#endif
uint32_t zenit_windows_id(const ZenitWindow *win) { return win ? win->id : 0; }
uint32_t zenit_windows_count(void) { return live_windows; }
void *zenit_windows_handle(ZenitWindow *win) { return win ? (void *)win->hwnd : NULL; }
void zenit_windows_redraw(ZenitWindow *win) {
    if (!win || !win->hwnd) return;
    win->redraw_requested = 1;
    InvalidateRect(win->hwnd, NULL, FALSE);
}
void zenit_windows_set_render_callback(ZenitWindow *win, void (*callback)(void *), void *ctx) {
    if (!win) return;
    int attaching = callback && !win->render_callback;
    win->render_callback = callback;
    win->render_context = ctx;
    // Ask for the first GPU paint as soon as presentation owns this window.
    // Avoid erasing its background or activating another window.
    if (attaching && win->hwnd) InvalidateRect(win->hwnd, NULL, FALSE);
}
void zenit_windows_mouse(ZenitWindow *win, float *x, float *y) {
    float scale = window_scale(win);
    *x = win ? (float)win->mouse_x / scale : 0;
    *y = win ? (float)win->mouse_y / scale : 0;
}
int zenit_windows_move(ZenitWindow *win, float *x, float *y, float *dx, float *dy, uint32_t *mods, uint64_t *serial, int *left) {
    if (!win || win->move_read == win->move_write) return 0;
    *left = win->moves[win->move_read].left;
    float scale = window_scale(win);
    unsigned index = win->move_read;
    *x = (float)win->moves[index].x / scale;
    *y = (float)win->moves[index].y / scale;
    *dx = (float)win->moves[index].dx / scale;
    *dy = (float)win->moves[index].dy / scale;
    *mods = win->moves[index].modifiers;
    *serial = win->moves[index].serial;
    win->move_read = queue_next(index);
    return 1;
}
void zenit_windows_input_metrics(uint64_t *coalesced) { *coalesced = mouse_move_coalesced; }
int zenit_windows_button(ZenitWindow *win, float *x, float *y, int *button, int *down, uint32_t *mods) {
    if (!win || win->button_read == win->button_write) return 0;
    float scale = window_scale(win);
    *x = (float)win->buttons[win->button_read].x / scale;
    *y = (float)win->buttons[win->button_read].y / scale;
    *button = win->buttons[win->button_read].code;
    *down = win->buttons[win->button_read].down;
    *mods = win->buttons[win->button_read].modifiers;
    win->button_read = queue_next(win->button_read);
    return 1;
}
/* The SDK consumes heterogeneous input in Win32 message order. */
static void poll_source_result(ZenitWindow *win) {
    if(!win || win->source_result.serial)return;
    unsigned operation=0;uint64_t token=0;
    if(zenit_drag_source_result(win->drag_source,&operation,&token)) {
        win->source_result.kind=4;win->source_result.operation=operation;
        win->source_result.source_token=token;win->source_result.serial=++win->next_input_serial;
    }
}
int zenit_windows_next_input_kind(ZenitWindow *win) {
    if (!win) return 0;
    poll_source_result(win);
    uint64_t first = UINT64_MAX;
    int kind = 0;
    if (win->button_read != win->button_write && win->buttons[win->button_read].serial < first) {
        first = win->buttons[win->button_read].serial; kind = 1;
    }
    if (win->key_read != win->key_write && win->keys[win->key_read].serial < first) {
        first = win->keys[win->key_read].serial; kind = 2;
    }
    if (win->text_read != win->text_write && win->text[win->text_read].serial < first) {
        first = win->text[win->text_read].serial; kind = 3;
    }
    if (win->ime_read != win->ime_write && win->ime[win->ime_read].serial < first) {
        first = win->ime[win->ime_read].serial; kind = 4;
    }
    if (win->wheel_read != win->wheel_write && win->wheels[win->wheel_read].serial < first) {
        first = win->wheels[win->wheel_read].serial; kind = 5;
    }
    ZenitDragPacket drag;
    if (zenit_drop_peek(win->drop_target, &drag) && drag.serial < first) {first=drag.serial;kind = 6;}
    if (win->source_result.serial && win->source_result.serial < first) {first=win->source_result.serial;kind = 6;}
    if(win->menu_read!=win->menu_write&&win->menu_commands[win->menu_read].serial<first) {first=win->menu_commands[win->menu_read].serial;kind=7;}
    if(win->move_read!=win->move_write&&win->moves[win->move_read].serial<first)kind=8;
    return kind;
}
int zenit_windows_drag_ready(ZenitWindow *win) { return win && win->drop_target != NULL; }
int zenit_windows_drag_operations(ZenitWindow *win, unsigned operations) { return win && zenit_drop_set_operations(win->drop_target,operations); }
int zenit_windows_drag_peek(ZenitWindow *win, ZenitDragPacket *packet) {
    if(!win||!packet)return 0;poll_source_result(win);
    ZenitDragPacket incoming={0};int has_incoming=zenit_drop_peek(win->drop_target,&incoming);
    if(win->source_result.serial&&(!has_incoming||win->source_result.serial<incoming.serial)){*packet=win->source_result;return 1;}
    if(has_incoming){*packet=incoming;return 1;}return 0;
}
int zenit_windows_drag_consume(ZenitWindow *win, uint64_t serial) {
    if(!win)return 0;
    if(serial&&serial==win->source_result.serial){
        zenit_drag_source_release(win->drag_source);win->drag_source=NULL;
        memset(&win->source_result,0,sizeof(win->source_result));return 1;
    }
    return zenit_drop_consume(win->drop_target,serial);
}
uint64_t zenit_windows_drag_start(ZenitWindow *win,unsigned kind,const char *bytes,size_t length,unsigned operations,
    const unsigned char *png,size_t png_length,float width,float height,float hotspot_x,float hotspot_y,int *error) {
    if(error)*error=-1;
    if(!win||!win->alive||!win->drop_target||win->drag_source)return 0;
    uint64_t token=0;
    win->drag_source=zenit_drag_source_start(win->hwnd,kind,bytes,length,operations,png,png_length,width,height,hotspot_x,hotspot_y,&token,error);
    return token;
}
void zenit_windows_drag_cancel(ZenitWindow *win) {if(win)zenit_drag_source_cancel(win->drag_source);}
int zenit_windows_key(ZenitWindow *win, uint16_t *code, uint32_t *mods, int *down) {
    if (!win || win->key_read == win->key_write) return 0;
    *code = win->keys[win->key_read].code;
    *mods = win->keys[win->key_read].modifiers;
    *down = win->keys[win->key_read].down;
    win->key_read = queue_next(win->key_read);
    return 1;
}
int zenit_windows_text(ZenitWindow *win, char *buffer, int capacity) {
    if (!win || win->text_read == win->text_write) return 0;
    int len = win->text[win->text_read].length;
    if (capacity < len) return 0;
    memcpy(buffer, win->text[win->text_read].bytes, (size_t)len);
    win->text_read = queue_next(win->text_read);
    return len;
}
int zenit_windows_ime_read(ZenitWindow *win, int expected_kind, char *buffer,
    uint32_t capacity, uint32_t *length, uint32_t *cursor) {
    if (!win || win->ime_read == win->ime_write ||
        win->ime[win->ime_read].kind != expected_kind) return 0;
    uint32_t size = win->ime[win->ime_read].length;
    if (capacity < size || (size && !buffer)) return 0;
    if (size) memcpy(buffer, win->ime[win->ime_read].bytes, size);
    *length = size;
    *cursor = win->ime[win->ime_read].cursor;
    free(win->ime[win->ime_read].bytes);
    win->ime_read = queue_next(win->ime_read);
    return 1;
}
int zenit_windows_ime_next_kind(ZenitWindow *win) {
    return !win || win->ime_read == win->ime_write ? 0 : win->ime[win->ime_read].kind;
}
void zenit_windows_ime_enable(ZenitWindow *win, int enabled) {
    if (!win || !win->hwnd || !!enabled == win->ime_enabled) return;
    if (enabled) {
        ImmAssociateContext(win->hwnd, win->detached_ime_context);
        win->detached_ime_context = NULL;
    } else {
        win->detached_ime_context = ImmAssociateContext(win->hwnd, NULL);
        if (win->ime_active) push_ime(win, 1, L"", 0, 0);
        win->ime_active = 0;
    }
    win->ime_enabled = !!enabled;
}
void zenit_windows_ime_discard(ZenitWindow *win) {
    if (!win || !win->hwnd) return;
    HIMC context = ImmGetContext(win->hwnd);
    if (context) {
        ImmNotifyIME(context, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
        ImmReleaseContext(win->hwnd, context);
    }
    if (win->ime_active) push_ime(win, 1, L"", 0, 0);
    win->ime_active = 0;
}
void zenit_windows_ime_cursor(ZenitWindow *win, float x, float y, float w, float h) {
    if (!win || !win->hwnd) return;
    HIMC context = ImmGetContext(win->hwnd);
    if (!context) return;
    float scale = window_scale(win);
    COMPOSITIONFORM composition = {0};
    composition.dwStyle = CFS_POINT;
    composition.ptCurrentPos.x = (LONG)(x * scale);
    composition.ptCurrentPos.y = (LONG)((y + h) * scale);
    ImmSetCompositionWindow(context, &composition);
    CANDIDATEFORM candidate = {0};
    candidate.dwIndex = 0;
    candidate.dwStyle = CFS_EXCLUDE;
    candidate.ptCurrentPos = composition.ptCurrentPos;
    candidate.rcArea.left = (LONG)(x * scale);
    candidate.rcArea.top = (LONG)(y * scale);
    candidate.rcArea.right = (LONG)((x + w) * scale);
    candidate.rcArea.bottom = (LONG)((y + h) * scale);
    ImmSetCandidateWindow(context, &candidate);
    ImmReleaseContext(win->hwnd, context);
}
int zenit_windows_wheel(ZenitWindow *win, float *x, float *y,
    float *dx, float *dy, uint32_t *mods) {
    if (!win || win->wheel_read == win->wheel_write) return 0;
    float scale = window_scale(win);
    *x = win->wheels[win->wheel_read].x / scale;
    *y = win->wheels[win->wheel_read].y / scale;
    *dx = win->wheels[win->wheel_read].dx;
    *dy = win->wheels[win->wheel_read].dy;
    *mods = win->wheels[win->wheel_read].modifiers;
    win->wheel_read = queue_next(win->wheel_read);
    return 1;
}
int zenit_windows_focused(ZenitWindow *win) { return win && win->hwnd && GetForegroundWindow() == win->hwnd; }
int zenit_windows_button_pressed(ZenitWindow *win, int button) {
    return win && button >= 0 && button < 3 && (win->button_mask & (1u << button)) != 0;
}
void zenit_windows_activate(ZenitWindow *win) { if (win && win->hwnd) SetForegroundWindow(win->hwnd); }

#ifdef ZENIT_WINDOW_CONTRACT
int zenit_windows_contract_keyboard_isolated(HWND hwnd) {
    ZenitWindow *win = window_owner(hwnd);
    return win && win->keyboard_isolated;
}
/* Owned key seeding bypasses OS translation without executing shortcuts/IME. */
int zenit_windows_contract_key(HWND hwnd, uint16_t key, uint32_t mods, int pressed) {
    ZenitWindow *win = window_owner(hwnd);
    if (!win || GetWindowThreadProcessId(hwnd, NULL) != GetCurrentThreadId()) return 0;
    push_key(win, key, mods, pressed);
    return 1;
}
/* Gallery-only queue injection: no SetCapture/SetFocus or desktop input. */
int zenit_windows_contract_move(HWND hwnd, uintptr_t flags, intptr_t point) {
    ZenitWindow *win = window_owner(hwnd);
    if (!win || GetWindowThreadProcessId(hwnd, NULL) != GetCurrentThreadId()) return 0;
    /* Use the same queue/coalescer as WM_MOUSEMOVE without arming OS hover
       tracking for an injected position unrelated to the real desktop cursor. */
    push_move(win, GET_X_LPARAM(point), GET_Y_LPARAM(point), (WPARAM)flags);
    return 1;
}
int zenit_windows_contract_press(HWND hwnd, int button, int x, int y) {
    ZenitWindow *win = window_owner(hwnd);
    if (!win || button < 0 || button >= 3) return 0;
    win->mouse_x = x;
    win->mouse_y = y;
    win->button_mask |= 1u << button;
    push_button(win, button, 1, x, y);
    return 1;
}
#endif

#ifdef ZENIT_WINDOW_CONTRACT
int zenit_windows_contract_cursor(void *owner, unsigned *shape, void **cursor) {
    ZenitWindow *win = window_owner((HWND)owner);
    if (!win) return 0;
    *shape = win->cursor_shape;
    *cursor = win->cursor;
    return 1;
}
#endif

#ifdef ZENIT_WINDOW_CONTRACT
int zenit_windows_contract_cursor_route(void *owner, void *recipient, int hit, void **cursor) {
    ZenitWindow *win = window_owner((HWND)owner);
    return win ? client_cursor(win, (HWND)recipient, hit, (HCURSOR *)cursor) : 0;
}
#endif

/* Unicode blocking alerts. */
static wchar_t *alert_string(const char *text) {
    if (!text) return NULL;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (count <= 0) return NULL;
    wchar_t *wide = (wchar_t *)calloc((size_t)count, sizeof(wchar_t));
    if (!wide) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count) != count) {
        free(wide); return NULL;
    }
    return wide;
}

static BOOL CALLBACK alert_choose_owner(HWND hwnd, LPARAM context) {
    ZenitWindow *win = window_owner(hwnd);
    if (win && !win->close_requested) { *(HWND *)context = hwnd; return FALSE; }
    return TRUE;
}

int zenit_win_blocking_alert(void *owner, const char *title, const char *message) {
    HWND hwnd = (HWND)owner;
    if (hwnd) {
        ZenitWindow *win = window_owner(hwnd);
        if (!win || win->close_requested) return 0;
    } else {
        HWND active = GetActiveWindow();
        ZenitWindow *win = window_owner(active);
        if (win && !win->close_requested) hwnd = active;
        else EnumThreadWindows(GetCurrentThreadId(), alert_choose_owner, (LPARAM)&hwnd);
    }
    wchar_t *caption = alert_string(title), *body = alert_string(message);
    if (!caption || !body) { free(caption); free(body); return 0; }
    int result = MessageBoxW(hwnd, body, caption, MB_OK | MB_ICONERROR | MB_APPLMODAL);
    free(caption); free(body);
    return result;
}

#ifdef ZENIT_WINDOW_CONTRACT
#define ZENIT_ALERT_TIMER ((UINT_PTR)0x5a4e0031)
static struct {
    HHOOK hook;
    HWND owner, dialog, foreground;
    wchar_t *title, *message;
    int seen, valid, ink;
} alert_contract;

static BOOL CALLBACK alert_find_body(HWND child, LPARAM context) {
    wchar_t name[32];
    if (!GetClassNameW(child, name, 32) || wcscmp(name, L"Static")) return TRUE;
    int length = GetWindowTextLengthW(child);
    if (length <= 0 || length > 4096) return TRUE;
    wchar_t *text = (wchar_t *)calloc((size_t)length + 1, sizeof(wchar_t));
    if (!text) return TRUE;
    GetWindowTextW(child, text, length + 1);
    int matches = !wcscmp(text, alert_contract.message);
    free(text);
    if (!matches) return TRUE;
    *(HWND *)context = child;
    return FALSE;
}

static int alert_body_ink(HWND dialog, HWND body) {
    RECT bounds, text;
    if (!GetWindowRect(dialog, &bounds) || !GetWindowRect(body, &text)) return -1;
    int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
    if (width <= 0 || height <= 0 || width > 2048 || height > 2048) return -1;
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    HDC dc = GetDC(dialog), memory = dc ? CreateCompatibleDC(dc) : NULL;
    void *pixels = NULL;
    HBITMAP bitmap = memory ? CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, NULL, 0) : NULL;
    HGDIOBJ previous = bitmap ? SelectObject(memory, bitmap) : NULL;
    int ink = -1;
    if (bitmap && previous && PrintWindow(dialog, memory, 0)) {
        GdiFlush();
        int left = text.left - bounds.left, top = text.top - bounds.top;
        int right = text.right - bounds.left, bottom = text.bottom - bounds.top;
        if (left >= 0 && top >= 0 && right <= width && bottom <= height && right > left && bottom > top) {
            ink = 0;
            const unsigned char *rgba = (const unsigned char *)pixels;
            for (int y = top; y < bottom; ++y) for (int x = left; x < right; ++x) {
                size_t offset = ((size_t)y * width + x) * 4;
                if (rgba[offset] < 150 && rgba[offset+1] < 150 && rgba[offset+2] < 150) ++ink;
            }
        }
    }
    if (previous) SelectObject(memory, previous);
    if (bitmap) DeleteObject(bitmap);
    if (memory) DeleteDC(memory);
    if (dc) ReleaseDC(dialog, dc);
    return ink;
}

static void CALLBACK alert_contract_timer(HWND hwnd, UINT message, UINT_PTR timer, DWORD time) {
    (void)message; (void)time;
    KillTimer(hwnd, timer);
    wchar_t title[512] = {0}; HWND body = NULL;
    GetWindowTextW(hwnd, title, 512);
    EnumChildWindows(hwnd, alert_find_body, (LPARAM)&body);
    HWND button = GetDlgItem(hwnd, IDOK);
    if (!button) button = GetDlgItem(hwnd, IDCANCEL);
    alert_contract.valid = !wcscmp(title, alert_contract.title) && body && button &&
        GetWindow(hwnd, GW_OWNER) == alert_contract.owner &&
        (!alert_contract.owner || !IsWindowEnabled(alert_contract.owner));
    alert_contract.ink = body ? alert_body_ink(hwnd, body) : -1;

    if (button) PostMessageW(hwnd, WM_COMMAND, GetDlgCtrlID(button), (LPARAM)button);
    else EndDialog(hwnd, IDOK);
}

static LRESULT CALLBACK alert_contract_hook(int code, WPARAM wp, LPARAM lp) {
    if (code == HCBT_ACTIVATE) {
        HWND hwnd = (HWND)wp;
        wchar_t name[32];
        if (!alert_contract.dialog && GetClassNameW(hwnd, name, 32) && !wcscmp(name, L"#32770")) {
            alert_contract.dialog = hwnd; alert_contract.seen = 1;
            if (!SetTimer(hwnd, ZENIT_ALERT_TIMER, 150, alert_contract_timer))
                PostMessageW(hwnd, WM_CLOSE, 0, 0);
        }
    }
    return CallNextHookEx(alert_contract.hook, code, wp, lp);
}

/* Run native modal contracts on an inactive desktop, on a fresh thread.
   Never SwitchDesktop: the user's desktop and foreground remain untouched.
   The joining thread closes this handle after the UI thread has exited. */
static HDESK alert_original_desktop;
void *zenit_win_alert_contract_desktop(void) {
    alert_original_desktop = GetThreadDesktop(GetCurrentThreadId());
    // This thread tests dialog controls, not IME. Avoid a lingering default IME window.
    ImmDisableIME(GetCurrentThreadId());
    wchar_t name[96];
    swprintf(name, 96, L"ZenitAlert-%lu-%lu-%llu", GetCurrentProcessId(),
        GetCurrentThreadId(), (unsigned long long)GetTickCount64());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0,
        DESKTOP_CREATEWINDOW | DESKTOP_READOBJECTS | DESKTOP_WRITEOBJECTS |
        DESKTOP_ENUMERATE | DESKTOP_HOOKCONTROL, NULL);
    if (!desktop) return NULL;
    if (!SetThreadDesktop(desktop)) { CloseDesktop(desktop); return NULL; }
    return desktop;
}
int zenit_win_alert_contract_leave_desktop(void) {
    int ok = SetThreadDesktop(alert_original_desktop);
    if (!ok) fprintf(stderr, "[windows-alert-contract] SetThreadDesktop restore error=%lu\n", GetLastError());
    return ok;
}
int zenit_win_alert_contract_close_desktop(void *desktop) {
    int ok = desktop && CloseDesktop((HDESK)desktop);
    if (!ok) fprintf(stderr, "[windows-alert-contract] CloseDesktop error=%lu\n", GetLastError());
    return ok;
}

int zenit_win_alert_contract_begin(void *owner, const char *title, const char *message) {
    if (alert_contract.hook) return 0;
    memset(&alert_contract, 0, sizeof(alert_contract));
    alert_contract.owner = (HWND)owner;
    alert_contract.foreground = GetForegroundWindow();
    alert_contract.title = alert_string(title); alert_contract.message = alert_string(message);
    if (!alert_contract.title || !alert_contract.message) goto failed;
    alert_contract.hook = SetWindowsHookExW(WH_CBT, alert_contract_hook, NULL, GetCurrentThreadId());
    if (alert_contract.hook) return 1;
failed:
    free(alert_contract.title); free(alert_contract.message);
    memset(&alert_contract, 0, sizeof(alert_contract));
    return 0;
}

int zenit_win_alert_contract_end(void) {
    if (!alert_contract.hook) return 0;
    int ok = alert_contract.seen && alert_contract.valid && alert_contract.ink > 20 &&
        !IsWindow(alert_contract.dialog) &&
        (!alert_contract.owner || IsWindowEnabled(alert_contract.owner));
    fprintf(stderr, "[windows-alert-contract] seen=%d valid=%d body_ink=%d closed=%d foreground=%d before=%p after=%p\n",
        alert_contract.seen, alert_contract.valid, alert_contract.ink, !IsWindow(alert_contract.dialog),
        GetForegroundWindow() == alert_contract.foreground, alert_contract.foreground, GetForegroundWindow());
    UnhookWindowsHookEx(alert_contract.hook);
    free(alert_contract.title); free(alert_contract.message);
    memset(&alert_contract, 0, sizeof(alert_contract));
    return ok;
}
#endif

int zenit_win_chrome_configure(void *owner, int mode, int automatic, float height) {
    ZenitWindow *w=window_owner((HWND)owner); if (!w) return 0;
    if (!mode) return 1;
    HIGHCONTRASTW contrast={sizeof(contrast),0,NULL};
    if(SystemParametersInfoW(SPI_GETHIGHCONTRAST,sizeof(contrast),&contrast,0)&&(contrast.dwFlags&HCF_HIGHCONTRASTON))return 2;
    int previous_hide=w->chrome_hide_controls;w->chrome_hide_controls=mode==2 || !automatic;
    if (!zenit_win_custom_frame(owner,1,mode==2?1:height,0)){w->chrome_hide_controls=previous_hide;sync_dwm_caption_prop(w);return 0;}
    int corner=2;DwmSetWindowAttribute(w->hwnd,33,&corner,sizeof(corner));
    if (w->chrome_hide_controls) {
        LONG_PTR style=GetWindowLongPtrW(w->hwnd,GWL_STYLE);
        SetLastError(0);
        /* Preserve native commands and HTMAXBUTTON/Snap; DWM's caption paint
           has no glass caption margin; the application paints its client slots. */
        if (!SetWindowLongPtrW(w->hwnd,GWL_STYLE,mode==2?style & ~(WS_SYSMENU|WS_MINIMIZEBOX|WS_MAXIMIZEBOX):style) && GetLastError()) return 0;
        if (!SetWindowPos(w->hwnd,NULL,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED)) return 0;
    }
    return 1;
}
void zenit_win_chrome_hit(void *owner, int (*hit)(void *,float,float), void *context) {
    ZenitWindow *w=window_owner((HWND)owner);
    if (w) { w->chrome_hit=hit; w->chrome_context=hit?context:NULL; }
}
int zenit_win_chrome_minimum(void *owner,uint32_t width,uint32_t height) {
    ZenitWindow *w=window_owner((HWND)owner);if(!w)return 0;
    w->chrome_min_width=width;w->chrome_min_height=height;return 1;
}
void zenit_win_chrome_state(void *owner, ZenitChromeState *out) {
    memset(out,0,sizeof(*out));
    ZenitWindow *w=window_owner((HWND)owner); if (!w) return;
    out->state_generation=w->chrome_state_generation;
    out->flags=(IsZoomed(w->hwnd)?1:0)|(w->chrome_fullscreen?2:0)|(GetForegroundWindow()==w->hwnd?4:0);
    out->flags |= 16;
    out->appearance=2;out->button_layout[3]=1;out->button_layout[4]=2;out->button_layout[5]=3;
    out->caption_hover=w->chrome_hover;out->caption_pressed=w->chrome_pressed;
    HIGHCONTRASTW contrast={sizeof(contrast),0,NULL};if(SystemParametersInfoW(SPI_GETHIGHCONTRAST,sizeof(contrast),&contrast,0)&&(contrast.dwFlags&HCF_HIGHCONTRASTON))out->flags|=64;
    out->capabilities=127;
    if (w->custom_frame && !w->chrome_hide_controls && !w->chrome_fullscreen) {
        RECT r; int got=zenit_win_caption_button_rect(w->hwnd,&r);
        if (got<0) out->controls_count=-1;
        else if (got>0) {
            float scale=(float)GetDpiForWindow(w->hwnd)/96.0f;
            out->controls_count=1;
            out->controls[0]=(ZenitChromeRect){r.left/scale,r.top/scale,(r.right-r.left)/scale,(r.bottom-r.top)/scale};
        }
    }
}
int zenit_win_chrome_action(void *owner, int action, int value) {
    ZenitWindow *w=window_owner((HWND)owner); if (!w) return 0;
    w->chrome_state_generation++;
    switch(action) {
    case 0: w->close_requested=1; return 1;
    case 1: ShowWindow(w->hwnd,SW_MINIMIZE); return 1;
    case 2: if (w->chrome_fullscreen) return 0; ShowWindow(w->hwnd,value?SW_MAXIMIZE:SW_RESTORE); return 1;
    case 3: {
        if (!!value==w->chrome_fullscreen) return 1;
        RECT previous; if (!GetWindowRect(w->hwnd,&previous)) return 0;
        LONG_PTR style=GetWindowLongPtrW(w->hwnd,GWL_STYLE);
        RECT next=w->chrome_saved_rect;
        LONG_PTR next_style=w->chrome_saved_style;
        if (value) {
            MONITORINFO info={.cbSize=sizeof(info)};
            if (!GetMonitorInfoW(MonitorFromWindow(w->hwnd,MONITOR_DEFAULTTONEAREST),&info)) return 0;
            next=info.rcMonitor;
            next_style=style & ~(WS_CAPTION|WS_THICKFRAME);
        }
        if (!value && !(next_style & WS_MAXIMIZE)) constrain_window_frame(&next, MonitorFromRect(&next, MONITOR_DEFAULTTONEAREST));
        SetLastError(0);
        if (!SetWindowLongPtrW(w->hwnd,GWL_STYLE,next_style) && GetLastError()) return 0;
        int previous_fullscreen=w->chrome_fullscreen;
        w->chrome_fullscreen=!!value; /* NCCALCSIZE must see the pending frame policy. */
        sync_dwm_caption_prop(w);
        if (!SetWindowPos(w->hwnd,value?HWND_TOP:NULL,next.left,next.top,next.right-next.left,next.bottom-next.top,SWP_FRAMECHANGED|(value?0:SWP_NOZORDER))) {
            w->chrome_fullscreen=previous_fullscreen;
            sync_dwm_caption_prop(w);
            SetWindowLongPtrW(w->hwnd,GWL_STYLE,style);
            SetWindowPos(w->hwnd,NULL,previous.left,previous.top,previous.right-previous.left,previous.bottom-previous.top,SWP_NOZORDER|SWP_FRAMECHANGED);
            return 0;
        }
        if (value) { w->chrome_saved_style=style; w->chrome_saved_rect=previous; }
        return 1;
    }
    default: return 0;
    }
}

// Persist points, never the HWND or an HMONITOR address. Device name hash is
// stable across process generations; disconnected monitors fall back to nearest.
static uint32_t zenit_monitor_key(const WCHAR *s) {
    uint32_t h = 2166136261u;
    for (; *s; ++s) h = (h ^ (uint32_t)*s) * 16777619u;
    return h;
}
typedef struct { uint64_t key; HMONITOR found; } ZenitMonitorLookup;
static BOOL CALLBACK zenit_find_monitor(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM param) {
    (void)dc; (void)rect;
    ZenitMonitorLookup *lookup = (ZenitMonitorLookup *)param;
    MONITORINFOEXW info = {0}; info.cbSize = sizeof(info);
    if (GetMonitorInfoW(monitor, (MONITORINFO *)&info) && zenit_monitor_key(info.szDevice) == lookup->key) {
        lookup->found = monitor; return FALSE;
    }
    return TRUE;
}
int zenit_windows_logical_geometry(ZenitWindow *win, uint64_t screen, double out[9]) {
    if (!win || !win->hwnd) return 0;
    RECT f; if (!GetWindowRect(win->hwnd, &f)) return 0;
    ZenitMonitorLookup lookup = { screen, NULL };
    if (screen) EnumDisplayMonitors(NULL, NULL, zenit_find_monitor, (LPARAM)&lookup);
    HMONITOR monitor = lookup.found ? lookup.found : MonitorFromWindow(win->hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFOEXW info = {0}; info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, (MONITORINFO *)&info)) return 0;
    double scale = GetDpiForWindow(win->hwnd) / 96.0;
    if (scale <= 0) scale = 1;
    out[0] = f.left / scale; out[1] = f.top / scale;
    out[2] = (f.right-f.left) / scale; out[3] = (f.bottom-f.top) / scale;
    out[4] = info.rcWork.left / scale; out[5] = info.rcWork.top / scale;
    out[6] = (info.rcWork.right-info.rcWork.left) / scale;
    out[7] = (info.rcWork.bottom-info.rcWork.top) / scale;
    out[8] = zenit_monitor_key(info.szDevice); return 1;
}
void zenit_windows_restore_logical_frame(ZenitWindow *win, const double f[4]) {
    if (!win || !win->hwnd) return;
    double scale = GetDpiForWindow(win->hwnd) / 96.0;
    if (scale <= 0) scale = 1;
    SetWindowPos(win->hwnd, NULL, (int)(f[0]*scale), (int)(f[1]*scale),
        (int)(f[2]*scale), (int)(f[3]*scale), SWP_NOZORDER | SWP_NOACTIVATE);
}
