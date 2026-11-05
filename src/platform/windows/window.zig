const std = @import("std");
const owned_window = @import("../owned_window.zig");

/// Win32 window and message-pump adapter. Pixel rendering is still owned by
/// the GPU backend; the native bridge's GDI paint is only a diagnostic fallback.
pub const WindowsWindow = struct {
    native: *anyopaque,
    recording: ?*anyopaque = null,
    /// Borrowed ID3D11Device, attached by the renderer and cleared before teardown.
    native_device: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    mouse_sequence: u64 = 0,
    key_sequence: u64 = 0,
    text_sequence: u64 = 0,
    ime_sequence: u64 = 0,
    titlebar_drag_height: f32 = 0,
    titlebar_drag_right_inset: f32 = 0,

    extern fn zenit_win_blocking_alert(owner: ?*anyopaque, title: [*:0]const u8, message: [*:0]const u8) c_int;
    extern fn zenit_windows_init_application() c_int;
    extern fn zenit_win_pending_open_file(buffer: ?[*]u8, capacity: usize) c_int;
    extern fn zenit_win_send_open_file(target: *anyopaque, path: [*]const u8, size: usize, timeout: u32) c_int;
    extern fn zenit_windows_create(width: u32, height: u32, title: [*:0]const u8) ?*anyopaque;
    extern fn zenit_windows_create_ex(width: u32, height: u32, title: [*:0]const u8, flags: c_int) ?*anyopaque;
    extern fn zenit_windows_show(window: *anyopaque) void;
    const create_hidden: c_int = 1;
    const create_reveal_on_present: c_int = 2;
    extern fn zenit_windows_note_presented(window: *anyopaque) void;
    extern fn zenit_windows_conceal(window: *anyopaque) void;
    extern fn zenit_windows_destroy(window: *anyopaque) void;
    extern fn zenit_windows_app_should_quit() c_int;
    extern fn zenit_windows_poll(window: *anyopaque) c_int;
    extern fn zenit_windows_menu_peek(window: *anyopaque, command: *u64) c_int;
    extern fn zenit_windows_menu_consume(window: *anyopaque) c_int;

    pub fn peekMenuCommand(self: *WindowsWindow) ?u64 {
        var command: u64 = 0;
        return if (zenit_windows_menu_peek(self.native, &command) != 0) command else null;
    }
    pub fn consumeMenuCommand(self: *WindowsWindow) bool {
        return zenit_windows_menu_consume(self.native) != 0;
    }
    extern fn zenit_windows_pump_timeout(timeout_ms: u32) void;
    extern fn zenit_windows_pump_timeout_precise(timeout_us: u32) void;
    extern fn zenit_windows_post_empty_event() void;
    extern fn zenit_windows_begin_close(window: *anyopaque) c_int;
    extern fn zenit_windows_closed(window: *anyopaque) c_int;
    extern fn zenit_windows_should_close(window: *anyopaque) c_int;
    extern fn zenit_windows_reset_close(window: *anyopaque) void;
    extern fn zenit_windows_size(window: *anyopaque, width: *u32, height: *u32) void;
    extern fn zenit_windows_drawable_size(window: *anyopaque, width: *u32, height: *u32) void;
    extern fn zenit_windows_set_size(window: *anyopaque, width: u32, height: u32) c_int;
    extern fn zenit_windows_scale(window: *anyopaque) f32;
    extern fn zenit_windows_display_refresh(window: *anyopaque) f32;
    extern fn zenit_windows_id(window: *anyopaque) u32;
    extern fn zenit_windows_count() u32;
    extern fn zenit_windows_handle(window: *anyopaque) ?*anyopaque;
    extern fn zenit_windows_redraw(window: *anyopaque) void;
    extern fn zenit_windows_set_render_callback(window: *anyopaque, callback: ?*const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void;
    extern fn zenit_windows_mouse(window: *anyopaque, x: *f32, y: *f32) void;
    extern fn zenit_windows_button(window: *anyopaque, x: *f32, y: *f32, button: *c_int, down: *c_int, modifiers: *u32) c_int;
    extern fn zenit_windows_next_input_kind(window: *anyopaque) c_int;
    extern fn zenit_windows_key(window: *anyopaque, code: *u16, modifiers: *u32, down: *c_int) c_int;
    extern fn zenit_windows_text(window: *anyopaque, buffer: [*]u8, capacity: c_int) c_int;
    extern fn zenit_windows_ime_next_kind(window: *anyopaque) c_int;
    extern fn zenit_windows_ime_read(window: *anyopaque, expected_kind: c_int, buffer: [*]u8, capacity: u32, length: *u32, cursor: *u32) c_int;
    extern fn zenit_windows_ime_enable(window: *anyopaque, enabled: c_int) void;
    extern fn zenit_windows_ime_discard(window: *anyopaque) void;
    extern fn zenit_windows_ime_cursor(window: *anyopaque, x: f32, y: f32, w: f32, h: f32) void;
    extern fn zenit_windows_wheel(window: *anyopaque, x: *f32, y: *f32, dx: *f32, dy: *f32, modifiers: *u32) c_int;
    extern fn zenit_windows_focused(window: *anyopaque) c_int;
    extern fn zenit_windows_button_pressed(window: *anyopaque, button: c_int) c_int;
    extern fn zenit_windows_activate(window: *anyopaque) void;
    const NativeDragPacket = extern struct {
        x: f32,
        y: f32,
        kind: u32,
        payload_kind: u32,
        truncated: u32,
        operation: u32,
        bytes: ?[*]const u8,
        length: usize,
        serial: u64,
        source_token: u64,
    };
    comptime {
        if (@sizeOf(usize) == 8 and (@sizeOf(NativeDragPacket) != 56 or @offsetOf(NativeDragPacket, "bytes") != 24 or @offsetOf(NativeDragPacket, "serial") != 40 or @offsetOf(NativeDragPacket, "source_token") != 48))
            @compileError("Native Windows drag packet ABI mismatch");
    }
    extern fn zenit_windows_drag_ready(window: *anyopaque) c_int;
    extern fn zenit_windows_drag_operations(window: *anyopaque, operations: c_uint) c_int;
    extern fn zenit_windows_drag_peek(window: *anyopaque, packet: *NativeDragPacket) c_int;
    extern fn zenit_windows_drag_consume(window: *anyopaque, serial: u64) c_int;
    extern fn zenit_windows_drag_start(window: *anyopaque, kind: c_uint, bytes: [*]const u8, length: usize, operations: c_uint, png: [*]const u8, png_length: usize, width: f32, height: f32, hotspot_x: f32, hotspot_y: f32, err: *c_int) u64;
    extern fn zenit_windows_drag_cancel(window: *anyopaque) void;
    pub fn cancelDrag(self: *WindowsWindow) void {
        zenit_windows_drag_cancel(self.native);
    }
    pub fn startDrag(self: *WindowsWindow, request: anytype) struct { token: u64, err: c_int } {
        var err: c_int = 0;
        const token = zenit_windows_drag_start(self.native, @backingInt(request.payload_kind), request.payload.ptr, request.payload.len, @as(u8, @bitCast(request.allowed_operations)), request.preview_png.ptr, request.preview_png.len, request.preview_width, request.preview_height, request.hotspot_x, request.hotspot_y, &err);
        return .{ .token = token, .err = err };
    }
    pub const DragEvent = struct {
        x: f32,
        y: f32,
        kind: u8,
        payload_kind: u8,
        paths: []const u8,
        truncated: bool,
        operation: u8,
        sequence: u64,
        source_token: u64,
    };
    pub fn isDragDropReady(self: *WindowsWindow) bool {
        return zenit_windows_drag_ready(self.native) != 0;
    }
    pub fn isDragSourceReady(self: *WindowsWindow) bool {
        return self.isDragDropReady();
    }
    pub fn setDragTargetOperations(self: *WindowsWindow, operations: u8) bool {
        return zenit_windows_drag_operations(self.native, operations) != 0;
    }
    pub fn peekDragEvent(self: *WindowsWindow) ?DragEvent {
        var packet: NativeDragPacket = undefined;
        if (zenit_windows_drag_peek(self.native, &packet) == 0) return null;
        return .{ .x = packet.x, .y = packet.y, .kind = @intCast(packet.kind), .payload_kind = @intCast(packet.payload_kind), .paths = if (packet.bytes) |bytes| bytes[0..packet.length] else "", .truncated = packet.truncated != 0, .operation = @intCast(packet.operation), .sequence = packet.serial, .source_token = packet.source_token };
    }
    pub fn consumeDragEvent(self: *WindowsWindow, sequence: u64) bool {
        return zenit_windows_drag_consume(self.native, sequence) != 0;
    }

    pub const WindowRecordingState = extern struct {
        ok: c_int = 0,
        active: c_int = 0,
        width: u32 = 0,
        height: u32 = 0,
        fps: u32 = 0,
        _reserved: u32 = 0,
        duration_ms: u64 = 0,
        file_size: u64 = 0,
        frame_count: u64 = 0,
        dropped_frames: u64 = 0,
        path: [768]u8 = @as([768]u8, @splat(0)),
        error_message: [256]u8 = @as([256]u8, @splat(0)),

        pub fn pathText(self: *const WindowRecordingState) []const u8 {
            return self.path[0..(std.mem.indexOfScalar(u8, &self.path, 0) orelse self.path.len)];
        }

        pub fn errorText(self: *const WindowRecordingState) []const u8 {
            return self.error_message[0..(std.mem.indexOfScalar(u8, &self.error_message, 0) orelse self.error_message.len)];
        }
    };

    pub const MouseButton = enum(c_int) {
        left = 0,
        right = 1,
        middle = 2,
    };

    pub const Modifiers = packed struct {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        cmd: bool = false,
        _padding: u28 = 0,

        pub fn fromRaw(raw: u32) Modifiers {
            return @bitCast(raw);
        }
    };

    pub const KeyEvent = struct {
        keycode: u16,
        modifiers: Modifiers,
        character: ?u8,
        pressed: bool = true,
        sequence: u64 = 0,
    };

    pub const KeyCode = struct {
        pub const RETURN: u16 = 0x0D;
        pub const TAB: u16 = 0x09;
        pub const SPACE: u16 = 0x20;
        pub const DELETE: u16 = 0x08;
        pub const ESCAPE: u16 = 0x1B;
        pub const LEFT: u16 = 0x25;
        pub const RIGHT: u16 = 0x27;
        pub const DOWN: u16 = 0x28;
        pub const UP: u16 = 0x26;
        pub const FORWARD_DELETE: u16 = 0x2E;
        pub const HOME: u16 = 0x24;
        pub const END: u16 = 0x23;
        pub const PAGE_UP: u16 = 0x21;
        pub const PAGE_DOWN: u16 = 0x22;
        pub const A: u16 = 0x41;
        pub const C: u16 = 0x43;
        pub const V: u16 = 0x56;
        pub const X: u16 = 0x58;
        pub const Z: u16 = 0x5A;
    };

    pub const ScrollEvent = struct {
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        phase: u8,
        momentum: u8,
        modifiers: Modifiers = .{},
        sequence: u64 = 0,
    };

    /// IME replacementRange sentinel: maintains same API shape as macOS platform.
    pub const ime_no_replacement: u32 = 0xFFFF_FFFF;

    pub const TextInputEvent = struct {
        sequence: u64,
        text: []const u8,
    };

    pub const ImePreeditEvent = struct {
        sequence: u64,
        text: []const u8,
        cursor_utf8_offset: u32,
        replace_start_utf8: u32 = ime_no_replacement,
        replace_end_utf8: u32 = ime_no_replacement,
    };

    pub const ImeCommitEvent = struct {
        sequence: u64,
        text: []const u8,
        replace_start_utf8: u32 = ime_no_replacement,
        replace_end_utf8: u32 = ime_no_replacement,
    };

    pub const MouseButtonEvent = struct {
        x: f32,
        y: f32,
        button: MouseButton,
        pressed: bool,
        cancelled: bool = false,
        modifiers: Modifiers = .{},
        sequence: u64 = 0,
    };

    pub const MouseMoveEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        modifiers: Modifiers,
        /// WM_MOUSELEAVE marker in the ordered move stream: the pointer left the client area
        /// (x/y repeat the last position). The backend reports it as `pointer_left`.
        left: bool = false,
    };

    pub const InputQueueMetrics = struct {
        mouse_move_coalesced: u64,
        ime_preedit_coalesced: u64,
    };

    pub fn initAppWithDelegate() void {
        initAppWithDelegateChecked() catch |err| std.log.err("Windows application startup: {s}", .{@errorName(err)});
    }

    /// Queue explicit --zenit-open-file arguments once per process. Ordinary
    /// application arguments are left to the application's own parser.
    pub fn initAppWithDelegateChecked() !void {
        if (zenit_windows_init_application() == 0) return error.OpenFileStartupFailed;
    }

    /// Show a Unicode modal alert on the calling UI thread. Prefer the owned
    /// variant when choosing among multiple Zenit windows on that thread.
    pub fn showBlockingAlert(title: [:0]const u8, message: [:0]const u8) void {
        showBlockingAlertChecked(title, message) catch |err| std.log.err("Windows blocking alert: {s}", .{@errorName(err)});
    }

    pub fn showBlockingAlertChecked(title: [:0]const u8, message: [:0]const u8) !void {
        if (zenit_win_blocking_alert(null, title.ptr, message.ptr) != 1) return error.NativeAlertFailed;
    }

    pub fn showBlockingAlertOwned(self: *WindowsWindow, title: [:0]const u8, message: [:0]const u8) !void {
        if (zenit_win_blocking_alert(self.getNativeSurfaceHandle(), title.ptr, message.ptr) != 1) return error.NativeAlertFailed;
    }

    pub fn init(width: u32, height: u32, title: [:0]const u8) !WindowsWindow {
        try initAppWithDelegateChecked();
        const native = zenit_windows_create(width, height, title.ptr) orelse return error.WindowCreationFailed;
        return .{ .native = native, .width = width, .height = height };
    }

    /// A window that stays hidden until `show`: owned panels are configured
    /// (owner, position) before they appear, so they take activation once.
    pub fn initHidden(width: u32, height: u32, title: [:0]const u8) !WindowsWindow {
        try initAppWithDelegateChecked();
        const native = zenit_windows_create_ex(width, height, title.ptr, 1) orelse return error.WindowCreationFailed;
        return .{ .native = native, .width = width, .height = height };
    }

    /// Show a window created with `initHidden` (activating it, except in
    /// background e2e runs). No effect once visible.
    pub fn show(self: *WindowsWindow) void {
        zenit_windows_show(self.native);
    }

    /// An application window: shown cloaked (or hidden, for windows the
    /// runtime places before showing) and revealed by `notePresented` once its
    /// first GPU frame exists, so the desktop never shows it without content.
    pub fn initApplication(width: u32, height: u32, title: [:0]const u8, hidden: bool) !WindowsWindow {
        try initAppWithDelegateChecked();
        const flags: c_int = create_reveal_on_present | if (hidden) create_hidden else 0;
        const native = zenit_windows_create_ex(width, height, title.ptr, flags) orelse return error.WindowCreationFailed;
        return .{ .native = native, .width = width, .height = height };
    }

    /// The renderer presented a frame to this window.
    pub fn notePresented(self: *WindowsWindow) void {
        zenit_windows_note_presented(self.native);
    }

    /// Hide the contents before teardown detaches the renderer.
    pub fn conceal(self: *WindowsWindow) void {
        zenit_windows_conceal(self.native);
    }

    pub fn deinit(self: *WindowsWindow) void {
        zenit_recording_destroy(self.recording);
        self.recording = null;
        zenit_windows_destroy(self.native);
    }

    pub fn beginClose(self: *WindowsWindow) bool {
        return zenit_windows_begin_close(self.native) != 0;
    }

    pub fn closeCompleted(self: *const WindowsWindow) bool {
        return zenit_windows_closed(self.native) != 0;
    }

    pub fn pollEvents(self: *WindowsWindow) bool {
        return zenit_windows_poll(self.native) != 0;
    }

    pub fn getSize(self: *WindowsWindow) [2]u32 {
        zenit_windows_size(self.native, &self.width, &self.height);
        return .{ self.width, self.height };
    }

    pub fn setSize(self: *WindowsWindow, width: u32, height: u32) void {
        _ = self.setSizeChecked(width, height);
    }

    /// Exact logical client extent; integer getSize is retained for compatibility.
    pub fn getLogicalSize(self: *WindowsWindow) [2]f32 {
        const pixels = self.getDrawableSize();
        const scale = self.getScaleFactor();
        return .{ @as(f32, @floatFromInt(pixels[0])) / scale, @as(f32, @floatFromInt(pixels[1])) / scale };
    }

    /// Reports native API success. getSize remains authoritative if the OS
    /// constrains the requested size. Invalid parameters leave the window alone.
    pub fn setSizeChecked(self: *WindowsWindow, width: u32, height: u32) bool {
        if (zenit_windows_set_size(self.native, width, height) == 0) return false;
        _ = self.getSize();
        return true;
    }

    pub fn getScaleFactor(self: *WindowsWindow) f32 {
        return zenit_windows_scale(self.native);
    }

    /// Current monitor's refresh rate; 60Hz only if the driver cannot report it.
    pub fn getDisplayRefreshRate(self: *WindowsWindow) f32 {
        return zenit_windows_display_refresh(self.native);
    }

    /// No platform window, returns 1 to maintain 'single window' semantics, not 0 (0 is a11y
    /// wildcard).
    pub fn getWindowId(self: *const WindowsWindow) u32 {
        return zenit_windows_id(self.native);
    }

    extern fn zenit_recording_start([*:0]const u8, u32, u32, u32, *WindowRecordingState) ?*anyopaque;
    extern fn zenit_recording_status(?*anyopaque, *WindowRecordingState) void;
    extern fn zenit_recording_due(?*anyopaque) c_int;
    extern fn zenit_recording_append(?*anyopaque, *const anyopaque) c_int;
    extern fn zenit_recording_stop(?*anyopaque, *WindowRecordingState) void;
    extern fn zenit_recording_destroy(?*anyopaque) void;
    extern fn zenit_recording_fail(?*anyopaque, [*:0]const u8) void;

    pub fn failWindowRecording(self: *WindowsWindow, message: [:0]const u8) void {
        zenit_recording_fail(self.recording, message);
    }

    /// BGRA app content only. Odd dimensions are padded to even for H.264.
    pub const RecordingFrame = extern struct { bytes: [*]const u8, width: u32, height: u32, stride: u32 };

    pub fn startWindowRecording(self: *WindowsWindow, path: []const u8, fps: u32) WindowRecordingState {
        var state = self.windowRecordingStatus();
        if (state.active != 0) return state;
        state = .{};
        if (path.len == 0 or path.len >= state.path.len or std.mem.indexOfScalar(u8, path, 0) != null) {
            const message = "recording path is empty, too long or contains NUL";
            @memcpy(state.error_message[0..message.len], message);
            return state;
        }
        zenit_recording_destroy(self.recording);
        self.recording = null;
        var path_z: [768:0]u8 = @splat(0);
        @memcpy(path_z[0..path.len], path);
        const size = self.getDrawableSize();
        self.recording = zenit_recording_start(&path_z, fps, size[0], size[1], &state);
        return state;
    }

    pub fn windowRecordingStatus(self: *WindowsWindow) WindowRecordingState {
        var state: WindowRecordingState = .{};
        zenit_recording_status(self.recording, &state);
        return state;
    }

    pub fn windowRecordingFrameDue(self: *WindowsWindow) bool {
        return zenit_recording_due(self.recording) != 0;
    }

    /// texture points to a RecordingFrame, whose bytes are copied before return.
    pub fn appendWindowRecordingFrame(self: *WindowsWindow, texture: *anyopaque) bool {
        return zenit_recording_append(self.recording, texture) != 0;
    }

    pub fn stopWindowRecording(self: *WindowsWindow) WindowRecordingState {
        var state: WindowRecordingState = .{};
        zenit_recording_stop(self.recording, &state);
        return state;
    }

    pub fn liveWindowCount() u32 {
        return zenit_windows_count();
    }

    pub fn getDrawableSize(self: *WindowsWindow) [2]u32 {
        var width: u32 = 0;
        var height: u32 = 0;
        zenit_windows_drawable_size(self.native, &width, &height);
        return .{ width, height };
    }

    pub fn getNativeSurfaceHandle(self: *WindowsWindow) *anyopaque {
        return zenit_windows_handle(self.native) orelse @panic("Win32 window already destroyed");
    }

    /// Borrowed ID3D11Device owned by this window's renderer. COM callers must
    /// AddRef or retain a resource before keeping it beyond renderer teardown.
    /// A standalone platform window has no device until a renderer is attached.
    pub fn getNativeDeviceHandle(self: *WindowsWindow) *anyopaque {
        return self.native_device orelse @panic("Windows window has no attached GPU renderer");
    }

    pub fn setRenderCallback(
        self: *WindowsWindow,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        ctx: ?*anyopaque,
    ) void {
        zenit_windows_set_render_callback(self.native, callback, ctx);
    }

    pub fn requestRedraw(self: *WindowsWindow) void {
        zenit_windows_redraw(self.native);
    }

    /// Windows App currently uses the timed message pump, not display link.
    pub fn startDisplayLink(self: *WindowsWindow) void {
        _ = self;
    }
    pub fn stopDisplayLink(self: *WindowsWindow) void {
        _ = self;
    }

    extern fn zenit_windows_live_resize(*anyopaque) c_int;
    pub fn isInLiveResize(self: *WindowsWindow) bool {
        return zenit_windows_live_resize(self.native) != 0;
    }

    pub fn getMousePosition(self: *WindowsWindow) [2]f32 {
        var x: f32 = 0;
        var y: f32 = 0;
        zenit_windows_mouse(self.native, &x, &y);
        return .{ x, y };
    }

    pub const hasOrderedMouseMoveEvents = true;
    extern fn zenit_windows_move(*anyopaque, *f32, *f32, *f32, *f32, *u32, *u64, *c_int) c_int;
    extern fn zenit_windows_input_metrics(*u64) void;
    pub fn getMouseMoveEvent(self: *WindowsWindow) ?MouseMoveEvent {
        var event: MouseMoveEvent = .{ .sequence = 0, .x = 0, .y = 0, .dx = 0, .dy = 0, .modifiers = .{} };
        var raw: u32 = 0;
        var left: c_int = 0;
        if (zenit_windows_move(self.native, &event.x, &event.y, &event.dx, &event.dy, &raw, &event.sequence, &left) == 0) return null;
        event.left = left != 0;
        event.modifiers = Modifiers.fromRaw(raw);
        return event;
    }

    pub fn inputQueueMetrics() InputQueueMetrics {
        var coalesced: u64 = 0;
        zenit_windows_input_metrics(&coalesced);
        return .{ .mouse_move_coalesced = coalesced, .ime_preedit_coalesced = 0 };
    }

    pub fn isMouseButtonPressed(self: *WindowsWindow, button: MouseButton) bool {
        return zenit_windows_button_pressed(self.native, @backingInt(button)) != 0;
    }

    pub fn getKeyEvent(self: *WindowsWindow) ?KeyEvent {
        var code: u16 = 0;
        var raw: u32 = 0;
        var down: c_int = 0;
        if (zenit_windows_key(self.native, &code, &raw, &down) == 0) return null;
        self.key_sequence += 1;
        return .{ .keycode = code, .modifiers = Modifiers.fromRaw(raw), .character = null, .pressed = down != 0, .sequence = self.key_sequence };
    }

    pub fn peekInputKind(self: *WindowsWindow) c_int {
        return zenit_windows_next_input_kind(self.native);
    }

    pub fn getInputText(self: *WindowsWindow, buffer: []u8) ?TextInputEvent {
        if (buffer.len == 0) return null;
        const len = zenit_windows_text(self.native, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(c_int))));
        if (len <= 0) return null;
        self.text_sequence += 1;
        return .{ .sequence = self.text_sequence, .text = buffer[0..@intCast(len)] };
    }

    pub fn getImePreedit(self: *WindowsWindow, buffer: []u8) ?ImePreeditEvent {
        if (buffer.len == 0) return null;
        var length: u32 = 0;
        var cursor: u32 = 0;
        if (zenit_windows_ime_read(self.native, 1, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(u32))), &length, &cursor) == 0) return null;
        self.ime_sequence += 1;
        return .{ .sequence = self.ime_sequence, .text = buffer[0..length], .cursor_utf8_offset = cursor };
    }

    pub fn getImeCommit(self: *WindowsWindow, buffer: []u8) ?ImeCommitEvent {
        if (buffer.len == 0) return null;
        var length: u32 = 0;
        var cursor: u32 = 0;
        if (zenit_windows_ime_read(self.native, 2, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(u32))), &length, &cursor) == 0) return null;
        self.ime_sequence += 1;
        return .{ .sequence = self.ime_sequence, .text = buffer[0..length] };
    }

    pub fn peekImeKind(self: *WindowsWindow) c_int {
        return zenit_windows_ime_next_kind(self.native);
    }

    extern fn zenit_windows_set_keyboard_isolated(window: *anyopaque, isolated: c_int) void;
    /// Test-runtime ingress gate; defaults off for every native window.
    pub fn setKeyboardIsolated(self: *WindowsWindow, isolated: bool) void {
        zenit_windows_set_keyboard_isolated(self.native, @intFromBool(isolated));
    }

    pub fn setTextInputEnabled(self: *WindowsWindow, enabled: bool) void {
        zenit_windows_ime_enable(self.native, if (enabled) 1 else 0);
    }

    pub fn discardIme(self: *WindowsWindow) void {
        zenit_windows_ime_discard(self.native);
    }

    pub fn setImeCursorRect(self: *WindowsWindow, x: f32, y: f32, w: f32, h: f32) void {
        zenit_windows_ime_cursor(self.native, x, y, w, h);
    }

    extern fn zenit_win_cursor_shape(*anyopaque, c_uint) c_int;
    pub fn setCursorShapeChecked(self: *WindowsWindow, shape: u8) bool {
        const hwnd = zenit_windows_handle(self.native) orelse return false;
        return zenit_win_cursor_shape(hwnd, shape) != 0;
    }
    pub fn setCursorShape(self: *WindowsWindow, shape: u8) void {
        _ = self.setCursorShapeChecked(shape);
    }

    pub fn activate(self: *WindowsWindow) void {
        zenit_windows_activate(self.native);
    }

    extern fn zenit_windows_set_owner(window: *anyopaque, owner: *anyopaque) c_int;
    extern fn zenit_windows_clear_owner(window: *anyopaque) void;
    extern fn zenit_windows_owner_geometry(window: *anyopaque, owner: *anyopaque, out: *[10]f64) c_int;
    extern fn zenit_windows_logical_geometry(window: *anyopaque, screen: u64, out: *[9]f64) c_int;
    extern fn zenit_windows_restore_logical_frame(window: *anyopaque, frame: *const [4]f64) void;
    pub fn previewGeometry(self: *WindowsWindow, screen: u64) ?[9]f64 {
        var out: [9]f64 = undefined;
        if (zenit_windows_logical_geometry(self.native, screen, &out) == 0) return null;
        return out;
    }
    pub fn restorePreviewFrame(self: *WindowsWindow, frame: [4]f64) void {
        zenit_windows_restore_logical_frame(self.native, &frame);
    }
    extern fn zenit_windows_set_origin(window: *anyopaque, x: f64, y: f64) void;
    extern fn zenit_windows_take_focus_loss(window: *anyopaque) c_int;

    /// Make this an owned window of `owner`: above the owner, minimised with
    /// it, no taskbar button. Destroying the owner HWND destroys this one too.
    pub fn setOwner(self: *WindowsWindow, owner: *WindowsWindow) bool {
        return zenit_windows_set_owner(self.native, owner.native) != 0;
    }

    pub fn clearOwner(self: *WindowsWindow, owner: *WindowsWindow) void {
        _ = owner;
        zenit_windows_clear_owner(self.native);
    }

    /// Native outer frame and monitor work area, in virtual-screen pixels.
    pub fn frameWorkArea(self: *WindowsWindow) ?[10]f64 {
        var geometry: [10]f64 = undefined;
        if (zenit_windows_owner_geometry(self.native, self.native, &geometry) == 0) return null;
        return geometry;
    }

    /// Centre on `owner` (see owned_window.centerOnOwner), clamped to the
    /// owner's monitor work area. Must run after the window has its final size.
    pub fn centerOnOwner(self: *WindowsWindow, owner: *WindowsWindow) bool {
        var g: [10]f64 = undefined;
        if (zenit_windows_owner_geometry(self.native, owner.native, &g) == 0) return false;
        const origin = owned_window.centerOnOwner(
            .{ .x = g[0], .y = g[1], .w = g[2], .h = g[3] },
            g[4],
            g[5],
            .{ .x = g[6], .y = g[7], .w = g[8], .h = g[9] },
            .down,
        );
        zenit_windows_set_origin(self.native, origin.x, origin.y);
        return true;
    }

    /// WM_ACTIVATE records focus loss natively; nothing to arm.
    pub fn armFocusLossReporting(self: *WindowsWindow) void {
        _ = self;
    }

    pub fn takeFocusLoss(self: *WindowsWindow) ?owned_window.FocusLoss {
        return switch (zenit_windows_take_focus_loss(self.native)) {
            1 => .same_application,
            2 => .other_application,
            else => null,
        };
    }

    pub fn getScrollDelta(self: *WindowsWindow) ?ScrollEvent {
        var x: f32 = 0;
        var y: f32 = 0;
        var dx: f32 = 0;
        var dy: f32 = 0;
        var raw_modifiers: u32 = 0;
        if (zenit_windows_wheel(self.native, &x, &y, &dx, &dy, &raw_modifiers) == 0) return null;
        return .{ .x = x, .y = y, .dx = dx, .dy = dy, .phase = 0, .momentum = 0, .modifiers = Modifiers.fromRaw(raw_modifiers) };
    }

    pub fn getMouseButtonEvent(self: *WindowsWindow) ?MouseButtonEvent {
        var x: f32 = 0;
        var y: f32 = 0;
        var button: c_int = 0;
        var down: c_int = 0;
        var raw_modifiers: u32 = 0;
        if (zenit_windows_button(self.native, &x, &y, &button, &down, &raw_modifiers) == 0) return null;
        self.mouse_sequence += 1;
        return .{ .x = x, .y = y, .button = if (button < 0) .left else @fromBackingInt(@intCast(button)), .pressed = down != 0, .cancelled = button < 0, .modifiers = Modifiers.fromRaw(raw_modifiers), .sequence = self.mouse_sequence };
    }

    pub fn shouldClose(self: *WindowsWindow) bool {
        return zenit_windows_should_close(self.native) != 0;
    }

    pub fn updateMousePosition(self: *WindowsWindow) void {
        _ = self;
    }

    pub fn setAcceptsMouseWhileInactive(self: *WindowsWindow, accepts: bool) void {
        _ = self;
        _ = accepts;
    }

    pub fn shouldRender(self: *WindowsWindow) bool {
        _ = self;
        return true;
    }

    pub fn getTitlebarHeight(self: *WindowsWindow) f32 {
        return zenit_win_titlebar_height(self.getNativeSurfaceHandle());
    }

    extern fn zenit_win_custom_frame(owner: *anyopaque, enabled: c_int, height: f32, right_inset: f32) c_int;
    extern fn zenit_win_titlebar_height(owner: *anyopaque) f32;

    pub fn setCustomTitlebar(self: *WindowsWindow, height: f32, right_inset: f32) !void {
        if (zenit_win_custom_frame(self.getNativeSurfaceHandle(), 1, height, right_inset) == 0) return error.CustomTitlebarFailed;
        self.titlebar_drag_height = height;
        self.titlebar_drag_right_inset = right_inset;
    }

    extern fn zenit_win_window_drag(owner: *anyopaque) c_int;
    extern fn zenit_win_titlebar_region(owner: *anyopaque, height: f32, right_inset: f32) c_int;
    extern fn zenit_win_set_title(owner: *anyopaque, title: [*:0]const u8) c_int;
    extern fn zenit_win_titlebar_hit_callback(owner: *anyopaque, callback: ?*const fn (?*anyopaque, f32, f32) callconv(.c) c_int, context: ?*anyopaque) c_int;

    pub fn performWindowDrag(self: *WindowsWindow) void {
        _ = zenit_win_window_drag(self.getNativeSurfaceHandle());
    }

    pub fn setTitlebarHitCallback(self: *WindowsWindow, callback: ?*const fn (?*anyopaque, f32, f32) callconv(.c) c_int, context: ?*anyopaque) void {
        _ = zenit_win_titlebar_hit_callback(self.getNativeSurfaceHandle(), callback, context);
    }

    pub fn setTrafficLightsInset(self: *WindowsWindow, inset_x: f32, inset_y: f32) void {
        _ = self;
        _ = inset_x;
        _ = inset_y;
    }

    /// Change the window title after creation.
    pub fn setTitle(self: *WindowsWindow, title: [:0]const u8) void {
        _ = zenit_win_set_title(self.getNativeSurfaceHandle(), title.ptr);
    }

    pub fn setTitlebarDragHeight(self: *WindowsWindow, height: f32) void {
        if (zenit_win_titlebar_region(self.getNativeSurfaceHandle(), height, self.titlebar_drag_right_inset) != 0) self.titlebar_drag_height = height;
    }

    pub fn setTitlebarDragRightInset(self: *WindowsWindow, inset: f32) void {
        if (zenit_win_titlebar_region(self.getNativeSurfaceHandle(), self.titlebar_drag_height, inset) != 0) self.titlebar_drag_right_inset = inset;
    }

    /// Consume the process FIFO into caller storage. Insufficient capacity
    /// returns BufferTooSmall without changing the queue or truncating a path.
    pub fn getPendingOpenFile(self: *WindowsWindow, buf: []u8) error{BufferTooSmall}!?[]const u8 {
        _ = self;
        const rc = zenit_win_pending_open_file(buf.ptr, buf.len);
        if (rc < 0) return error.BufferTooSmall;
        if (rc == 0) return null;
        return buf[0..@intCast(rc)];
    }

    /// Required UTF-8 bytes including NUL; null means the process queue is empty.
    pub fn pendingOpenFileRequiredSize(self: *WindowsWindow) ?usize {
        _ = self;
        const rc = zenit_win_pending_open_file(null, 0);
        return if (rc < 0) @intCast(-@as(i64, rc)) else null;
    }

    /// Deliver one file/folder intent to an existing Zenit HWND using bounded
    /// WM_COPYDATA. Relative paths resolve in the sender's working directory.
    /// Success means queued, not opened. This never activates the target.
    pub fn sendOpenFile(target: *anyopaque, path: [:0]const u8, timeout_ms: u32) !void {
        if (zenit_win_send_open_file(target, path.ptr, path.len + 1, timeout_ms) == 0) return error.OpenFileDeliveryFailed;
    }

    pub fn pumpAppEvents() void {
        zenit_windows_pump_timeout(0);
    }

    pub fn pumpAppEventsTimeout(timeout_ms: u32) void {
        zenit_windows_pump_timeout(timeout_ms);
    }

    /// As pumpAppEventsTimeout, but wakes at the deadline instead of the next
    /// system timer tick after it (see zenit_windows_pump_timeout_precise).
    pub fn pumpAppEventsTimeoutPrecise(timeout_us: u32) void {
        zenit_windows_pump_timeout_precise(timeout_us);
    }

    /// Wake a pump blocked in pumpAppEventsTimeout from any thread.
    pub fn postEmptyEvent() void {
        zenit_windows_post_empty_event();
    }

    pub fn appShouldQuit() bool {
        return zenit_windows_app_should_quit() != 0;
    }

    extern fn zenit_windows_cancel_app_quit() void;
    /// Withdraw a pending user quit request after the application vetoed it.
    pub fn cancelAppQuit() void {
        zenit_windows_cancel_app_quit();
    }

    pub fn checkShouldClose(self: *WindowsWindow) bool {
        return self.shouldClose();
    }

    pub fn resetShouldClose(self: *WindowsWindow) void {
        zenit_windows_reset_close(self.native);
    }

    pub fn updateWindowMouse(self: *WindowsWindow) void {
        _ = self;
    }

    pub fn isFocused(self: *WindowsWindow) bool {
        return zenit_windows_focused(self.native) != 0;
    }

    /// Menu action enum (consistent with macOS side)
    pub const MenuAction = enum(c_int) {
        none = 0,
        new_file = 1,
        new_file_dialog = 2,
        new_window = 3,
        open_file = 4,
        open_folder = 5,
        open_recent = 6,
        save = 7,
        save_as = 8,
        close_tab = 9,
        close_window = 10,
        install_cli = 11,
    };

    pub const MenuActionEvent = struct { native_window_id: u64, action: MenuAction };
    pub fn getMenuActionEvent() ?MenuActionEvent {
        return null;
    }

    pub fn getMenuAction() ?MenuAction {
        return null;
    }
};
