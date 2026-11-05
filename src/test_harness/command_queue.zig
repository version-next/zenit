/// command_queue: SPSC ring buffer for test commands.
///
/// HTTP thread writes commands -> main thread consumes and executes.
/// (Minimal zenit subset: supports IME / click / type / key / query / screenshot / focused)
const std = @import("std");

pub const QUEUE_SIZE = 16;
pub const RESULT_BUF_SIZE = 256 * 1024; // 256KB JSON result

/// phased: false = phase-less wheel events (a mouse wheel); true = trackpad gestures, one per
/// span (began, changed..., then ended with zero delta after the span's last event).
pub const ScrollStream = struct { x: f32, y: f32, step: f32, span: u32, count: u32, interval_ms: f32, phased: bool = false };

pub const TestCommand = union(enum) {
    health: void,
    /// /click also uses MousePayload, internally synthesizing down+up; without modifiers, cases
    /// like "shift-click second object" degrade silently to exclusive select (the most common
    /// operation).
    click: MousePayload,
    click_test_id: TestIdPayload,
    /// Modifiers travel with pointer events: shift-adds, cmd-deepens, ctrl-inverts selection. These
    /// interactions are only testable with modifier-carrying pointer events. Default all false =>
    /// old tests unaffected.
    mouse_down: MousePayload,
    mouse_move: MousePayload,
    mouse_up: MousePayload,
    /// The platform's `pointer_left` (macOS content exit or covering window, Windows
    /// WM_MOUSELEAVE, Wayland wl_pointer.leave), through the same Cx entry the runtimes use.
    pointer_leave: void,
    /// The platform's window activation appearance (`window_focused.appears_active`), as the
    /// runtimes apply it; test-mode apps otherwise always report active.
    window_active: bool,
    key_down: KeyPayload,
    key_up: KeyPayload,
    text_input: TextPayload,
    ime_preedit: ImePayload,
    ime_commit: TextPayload,
    query_tree: void,
    query_selector: TextPayload,
    get_focused: void,
    screen_pos: TestIdPayload,
    /// Per-frame tracking: begin recording screen rectangles of this test_id node after each frame
    /// render (for animation assertions; samples unaffected by RPC latency).
    track_start: TestIdPayload,
    /// End per-frame tracking, return all samples.
    track_stop: void,
    screenshot: ScreenshotPayload,
    windows: void,
    visual_quality: VisualQualityCommand,
    recording_start: RecordingStartPayload,
    recording_status: void,
    recording_stop: void,
    /// Query input/textarea internal state (buffer / cursor / preedit / phase).
    input_state: TestIdPayload,
    /// Custom host routes (`/app/...`). Harness does not interpret semantics; passes path+body
    /// as-is to the host's registered handler, which writes back JSON. Lets downstream apps expose
    /// diagnostics/fixtures without embedding app logic in zenit.
    app_route: AppRoutePayload,
    /// Query previous frame's FrameStats (retained hits/misses/partial_repaints, etc).
    frame_stats: void,
    /// Clear cross-frame timing sample ring. Performance gates call this after entering heavy
    /// scenes, so P95 only counts that scene's frames (otherwise mixes in previous story's
    /// samples).
    reset_timing: void,
    frames_start: struct { target: TestIdPayload, escape_on_enter: bool = false, click_target: ?TestIdPayload = null, capture_path: ?TestIdPayload = null, capture_after_ms: f64 = 0 },
    frames_read: void,
    frames_capture_read: void,
    finish_frame_capture: void,
    animation_clock: f32, // 0 restores realtime; 1..100 ms per active frame.
    /// Perf probe: continuous full-repaint frames on/off.
    force_frames: bool,
    /// Fixed step whose time advances only by clock_advance grants (frozen at 0).
    animation_clock_locked: f32,
    /// Grant ms of animation time to a locked clock.
    clock_advance: f64,
    /// Incremental per-Cx Console snapshot. after_seq=0 starts at the oldest
    /// retained event; limit is clamped by the executor.
    console_query: ConsoleQueryPayload,
    console_clear: void,
    /// Scroll wheel event (with modifiers). phase / momentum per ui.events.ScrollPhase /
    /// MomentumPhase ordinal; default 0 = none (mouse wheel).
    scroll: struct { x: f32, y: f32, dx: f32, dy: f32, phase: u8 = 0, momentum: u8 = 0, shift: bool = false, ctrl: bool = false, alt: bool = false, super: bool = false },
    /// Wheel events injected by the app at a fixed rate (no RPC per event):
    /// `step` per event, reversing every `span` events, `count` in total.
    scroll_stream: ScrollStream,
    /// Trackpad pinch event. phase: 0=began 1=changed 2=ended 3=cancelled.
    magnify: struct { x: f32, y: f32, magnification: f32, phase: u8 },
    /// Drag event. kind: 0=entered 1=updated 2=exited 3=dropped; paths newline-separated.
    drag: DragPayload,
    /// Resize window logical size (points). Regression anchor: resize triggers surface
    /// reconfiguration; in test-mode reconfiguration must preserve CPU readback ability, else
    /// subsequent /screenshot artifacts.
    resize_window: struct { width: u32, height: u32 },
    window: WindowCommand,
    quit_app: void,
    /// Compositor sprites: query, or enable/disable for this window's Cx.
    sprites: SpritesCommand,
    /// CPU damage patches (src/zenit_app/cpu_patch.zig): query/enable/disable.
    cpu_patches: SpritesCommand,
    /// WindowServer image of the key window (native layers included) as PNG.
    composited_screenshot: RecordingStartPayload,
};

pub const SpritesCommand = enum { query, enable, disable, debug };

/// `occlude`/`reveal` force the window's occlusion state (macOS resource
/// release path) without covering the real window.
pub const WindowCommand = enum { status, maximize, restore, minimize, close, occlude, reveal };
pub const WindowSnapshot = struct { decoration_height: i32, decorated: bool, maximized: bool, active: bool, suspended: bool, width: u32, height: u32 };

pub const RecordingStartPayload = struct {
    pub const PATH_CAP = 768;

    path: [PATH_CAP]u8 = undefined,
    path_len: u16 = 0,
    fps: u16 = 60,

    pub fn getPath(self: *const RecordingStartPayload) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const ConsoleQueryPayload = struct {
    after_seq: u64 = 0,
    limit: u16 = 100,
};

pub const DragPayload = struct {
    x: f32,
    y: f32,
    kind: u8,
    paths: TextPayload = .{},

    pub fn deinit(self: *DragPayload, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
    }
};

pub const ImePayload = struct {
    text: TextPayload,
    cursor_utf8_offset: u32 = 0,

    pub fn deinit(self: *ImePayload, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
    }
};

pub const ScreenshotPayload = struct {
    path: TestIdPayload = .{},
    window_id: ?TestIdPayload = null,
    pub fn getText(self: *const ScreenshotPayload) []const u8 {
        return self.path.getText();
    }
};

pub const TestIdPayload = struct {
    buf: [256]u8 = undefined,
    len: u16 = 0,

    pub fn getText(self: *const TestIdPayload) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const TextPayload = struct {
    inline_buf: [256]u8 = undefined,
    heap_ptr: ?[*]u8 = null,
    len: u32 = 0,

    pub fn getText(self: *const TextPayload) []const u8 {
        if (self.heap_ptr) |ptr| {
            return ptr[0..self.len];
        }
        return self.inline_buf[0..@min(self.len, 256)];
    }

    pub fn deinit(self: *TextPayload, allocator: std.mem.Allocator) void {
        if (self.heap_ptr) |ptr| {
            allocator.free(ptr[0..self.len]);
            self.heap_ptr = null;
        }
    }

    pub fn initFromText(allocator: std.mem.Allocator, text: []const u8) !TextPayload {
        var payload = TextPayload{};
        payload.len = @intCast(text.len);
        if (text.len <= 256) {
            @memcpy(payload.inline_buf[0..text.len], text);
        } else {
            const heap = try allocator.alloc(u8, text.len);
            @memcpy(heap, text);
            payload.heap_ptr = heap.ptr;
        }
        return payload;
    }
};

/// Pointer event payload. Modifiers default false, matching legacy `{x, y}` behavior. Custom host
/// route payload. path/body are fixed-size inline, avoiding ownership disputes between RPC and main
/// threads (same tradeoff as TestIdPayload).
pub const AppRoutePayload = struct {
    pub const PATH_CAP = 96;
    pub const BODY_CAP = 512;

    path: [PATH_CAP]u8 = undefined,
    path_len: u8 = 0,
    body: [BODY_CAP]u8 = undefined,
    body_len: u16 = 0,

    pub fn getPath(self: *const AppRoutePayload) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn getBody(self: *const AppRoutePayload) []const u8 {
        return self.body[0..self.body_len];
    }
    pub fn init(path: []const u8, body: []const u8) ?AppRoutePayload {
        if (path.len > PATH_CAP or body.len > BODY_CAP) return null;
        var p: AppRoutePayload = .{};
        @memcpy(p.path[0..path.len], path);
        p.path_len = @intCast(path.len);
        @memcpy(p.body[0..body.len], body);
        p.body_len = @intCast(body.len);
        return p;
    }
};

pub const MousePayload = struct {
    x: f32 = 0,
    y: f32 = 0,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    /// `/click` only: consecutive clicks injected back to back inside the app,
    /// so multi-click detection does not depend on the driver's round trip.
    count: u8 = 1,

    pub fn modifiers(self: *const MousePayload) @import("ui").events.Modifiers {
        return .{ .shift = self.shift, .ctrl = self.ctrl, .alt = self.alt, .super = self.super };
    }
};

pub const KeyPayload = struct {
    key_name: [32]u8 = undefined,
    key_len: u8 = 0,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn getKeyName(self: *const KeyPayload) []const u8 {
        return self.key_name[0..self.key_len];
    }
};

pub const CommandResult = struct {
    buf: [RESULT_BUF_SIZE]u8 = undefined,
    len: usize = 0,
    success: bool = true,

    pub fn getData(self: *const CommandResult) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn setJson(self: *CommandResult, json: []const u8) void {
        // Report an explicit error when it doesn't fit: truncated JSON would be swallowed by the client
        // as a successful result.
        if (json.len > self.buf.len) {
            self.setError("result JSON exceeds RESULT_BUF_SIZE");
            return;
        }
        @memcpy(self.buf[0..json.len], json);
        self.len = json.len;
        self.success = true;
    }

    pub fn setError(self: *CommandResult, msg: []const u8) void {
        const prefix = "{\"error\":\"";
        const suffix = "\"}";
        var pos: usize = 0;
        const total = prefix.len + msg.len + suffix.len;
        if (total <= self.buf.len) {
            @memcpy(self.buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            @memcpy(self.buf[pos..][0..msg.len], msg);
            pos += msg.len;
            @memcpy(self.buf[pos..][0..suffix.len], suffix);
            pos += suffix.len;
        }
        self.len = pos;
        self.success = false;
    }
};

pub const CommandQueue = struct {
    commands: [QUEUE_SIZE]TestCommand = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    io: std.Io,
    done_event: std.Io.Event = .unset,

    result: CommandResult = .{},

    allocator: std.mem.Allocator = std.heap.page_allocator,

    /// Called by the RPC producer immediately after publishing a command.
    /// The app main loop may be asleep in a native event pump while the
    /// display link is stopped, so polling alone is not a reliable wakeup.
    wake_fn: ?*const fn () void = null,

    pub fn setWakeCallback(self: *CommandQueue, wake_fn: *const fn () void) void {
        self.wake_fn = wake_fn;
    }

    pub fn submitAndWait(self: *CommandQueue, cmd: TestCommand) *const CommandResult {
        const tail = self.tail.load(.acquire);
        self.commands[tail % QUEUE_SIZE] = cmd;
        self.tail.store(tail + 1, .release);
        if (self.wake_fn) |wake| wake();

        self.done_event.waitUncancelable(self.io);
        self.done_event.reset();

        return &self.result;
    }

    pub fn hasCommand(self: *CommandQueue) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head != tail;
    }

    pub fn dequeue(self: *CommandQueue) ?TestCommand {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        if (head == tail) return null;
        const cmd = self.commands[head % QUEUE_SIZE];
        self.head.store(head + 1, .release);
        return cmd;
    }

    pub fn signalDone(self: *CommandQueue) void {
        self.done_event.set(self.io);
    }
};

var test_wake_count = std.atomic.Value(u32).init(0);

fn countTestWake() void {
    _ = test_wake_count.fetchAdd(1, .monotonic);
}

fn consumeOneForTest(queue: *CommandQueue) void {
    while (queue.dequeue() == null) std.Thread.yield() catch {};
    queue.result.setJson("{\"ok\":true}");
    queue.signalDone();
}

test "submit publishes command and wakes event pump before waiting" {
    test_wake_count.store(0, .monotonic);
    var queue = CommandQueue{ .io = std.testing.io };
    queue.setWakeCallback(countTestWake);

    const consumer = try std.Thread.spawn(.{}, consumeOneForTest, .{&queue});
    const result = queue.submitAndWait(.{ .health = {} });
    consumer.join();

    try std.testing.expectEqual(@as(u32, 1), test_wake_count.load(.monotonic));
    try std.testing.expectEqualStrings("{\"ok\":true}", result.getData());
}

pub const VisualQualityCommand = enum { status, auto, full, frosted, basic, fail_blur };
