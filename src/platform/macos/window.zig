const std = @import("std");
const owned_window = @import("../owned_window.zig");

/// macOS native window using Cocoa API. Bypasses GLFW entirely to solve rendering stall during
/// window drag.
pub const MacOSWindow = struct {
    window_ptr: *anyopaque,
    view_ptr: *anyopaque,
    width: u32,
    height: u32,
    /// Focus loss recorded by the native resign-key callback, consumed by the
    /// runtime between events (see `armFocusLossReporting`).
    pending_focus_loss: ?owned_window.FocusLoss = null,

    // Objective-C C API function declarations
    extern fn macos_init_app() void;
    extern fn macos_init_app_with_delegate() void;
    extern fn macos_show_blocking_alert(title: [*:0]const u8, message: [*:0]const u8) void;
    extern fn macos_is_dark_mode() c_int;
    extern fn macos_create_window(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
    extern fn macos_create_window_borderless(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
    extern fn macos_activate_window(window_ptr: *anyopaque) void;
    extern fn macos_restore_key_window(window_ptr: *anyopaque) void;

    extern fn macos_get_metal_view(window_ptr: *anyopaque) ?*anyopaque;
    extern fn macos_get_metal_layer(view_ptr: *anyopaque) ?*anyopaque;
    extern fn macos_get_metal_device(view_ptr: *anyopaque) ?*anyopaque;
    extern fn macos_poll_events(window_ptr: *anyopaque) c_int;
    extern fn macos_get_window_size(window_ptr: *anyopaque, width: *c_int, height: *c_int) void;
    extern fn macos_set_window_size(window_ptr: *anyopaque, width: c_int, height: c_int) void;
    extern fn macos_get_scale_factor(window_ptr: *anyopaque) f64;
    extern fn macos_window_id(window_ptr: *anyopaque) u32;
    extern fn macos_live_window_count() u32;
    extern fn macos_get_drawable_size(view_ptr: *anyopaque, width: *c_int, height: *c_int) void;
    extern fn macos_get_mouse_position(window_ptr: *anyopaque, x: *f32, y: *f32) void;
    extern fn macos_get_mouse_move_event(window_ptr: *anyopaque, x: *f32, y: *f32, dx: *f32, dy: *f32, modifiers: *u32, sequence: *u64, left: *c_int) c_int;
    extern fn macos_get_input_queue_metrics(mouse_move_coalesced: *u64, ime_preedit_coalesced: *u64) void;
    extern fn macos_current_modifier_flags() u32;
    extern fn macos_is_mouse_button_pressed(window_ptr: *anyopaque, button: c_int) c_int;
    extern fn macos_get_key_event(window_ptr: *anyopaque, keycode: *u16, modifiers: *u32, character: *u8, pressed: *c_int, sequence: *u64) c_int;
    extern fn macos_peek_text_event(window_ptr: *anyopaque, kind: u32, bytes: *?[*]const u8, length: *usize, cursor: *u32, start: *u32, end: *u32, sequence: *u64) c_int;
    extern fn macos_consume_text_event(window_ptr: *anyopaque, kind: u32, sequence: u64) c_int;
    extern fn macos_get_input_text(window_ptr: *anyopaque, buffer: [*]u8, buffer_size: c_int, sequence: *u64) c_int;
    extern fn macos_get_ime_preedit(window_ptr: *anyopaque, buffer: [*]u8, buffer_size: c_int, out_len: *c_int, cursor_utf8_offset: *u32, replace_start_utf8: *u32, replace_end_utf8: *u32, sequence: *u64) c_int;
    extern fn macos_get_ime_commit(window_ptr: *anyopaque, buffer: [*]u8, buffer_size: c_int, out_len: *c_int, replace_start_utf8: *u32, replace_end_utf8: *u32, sequence: *u64) c_int;
    extern fn macos_set_text_input_enabled(window_ptr: *anyopaque, enabled: c_int) void;
    extern fn macos_set_ime_cursor_rect(window_ptr: *anyopaque, x: f32, y: f32, width: f32, height: f32) void;
    extern fn macos_ime_discard(window_ptr: *anyopaque) void;
    extern fn macos_set_cursor_shape(window_ptr: *anyopaque, shape: c_int) void;
    extern fn macos_get_scroll_event(window_ptr: *anyopaque, x: *f32, y: *f32, dx: *f32, dy: *f32, phase: *u8, momentum: *u8, modifiers: *u32, sequence: *u64) c_int;
    extern fn macos_get_magnify_event(window_ptr: *anyopaque, x: *f32, y: *f32, magnification: *f32, phase: *u8, sequence: *u64) c_int;
    extern fn macos_peek_drag_event(window_ptr: *anyopaque, x: *f32, y: *f32, kind: *u8, bytes: *?[*]const u8, length: *usize, token: *?*const anyopaque, payload_kind: *u8, source_token: *u64, operation: *u8) c_int;
    extern fn macos_consume_drag_event(window_ptr: *anyopaque, token: *const anyopaque) c_int;
    extern fn macos_get_drag_event(window_ptr: *anyopaque, x: *f32, y: *f32, kind: *u8, paths_buf: [*]u8, paths_buf_len: c_int, payload_kind: *u8, source_token: *u64, operation: *u8, paths_truncated: *u8) c_int;
    extern fn macos_set_render_callback(window_ptr: *anyopaque, callback: ?*const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void;
    extern fn macos_set_surface_background(view_ptr: *anyopaque, r: f32, g: f32, b: f32, a: f32) void;
    extern fn macos_set_live_resize_tick_callback(window_ptr: *anyopaque, callback: ?*const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void;
    extern fn macos_request_redraw(window_ptr: *anyopaque) void;
    extern fn macos_is_live_resize(window_ptr: *anyopaque) c_int;
    extern fn macos_get_mouse_button_event_ex(window_ptr: ?*anyopaque, x: *f32, y: *f32, button: *c_int, pressed: *c_int, modifiers: *u32, sequence: *u64) c_int;
    extern fn macos_get_mouse_button_event(window_ptr: *anyopaque, x: *f32, y: *f32, button: *c_int, pressed: *c_int) c_int;
    extern fn macos_should_close(window_ptr: *anyopaque) c_int;
    extern fn macos_update_mouse_position(window_ptr: *anyopaque) void;
    extern fn macos_set_accepts_mouse_while_inactive(window_ptr: *anyopaque, accepts: c_int) void;
    extern fn macos_should_render_window(window_ptr: *anyopaque) c_int;
    extern fn macos_get_titlebar_height(window_ptr: *anyopaque) f32;
    extern fn macos_perform_window_drag(window_ptr: *anyopaque) void;
    extern fn macos_set_traffic_lights_inset(window_ptr: *anyopaque, inset_x: f32, inset_y: f32) void;
    extern fn macos_set_titlebar_drag_height(window_ptr: *anyopaque, height: f32) void;
    extern fn macos_set_window_title(window_ptr: *anyopaque, title: [*:0]const u8) void;
    extern fn macos_set_titlebar_hit_callback(window_ptr: *anyopaque, cb: ?*const fn (?*anyopaque, f32, f32) callconv(.c) c_int, ctx: ?*anyopaque) void;
    extern fn macos_set_titlebar_drag_right_inset(window_ptr: *anyopaque, inset: f32) void;
    extern fn macos_destroy_window(window_ptr: *anyopaque) void;
    extern fn macos_begin_window_close(window_ptr: *anyopaque) c_int;
    extern fn macos_window_close_completed(window_ptr: *anyopaque) c_int;
    extern fn macos_get_pending_open_file(buffer: ?[*]u8, buffer_size: c_int) c_int;
    // Menu action API
    extern fn macos_get_menu_action() c_int;
    extern fn macos_get_menu_action_event(window_id: *u64, action: *c_int) c_int;

    // Multi-window architecture API
    extern fn macos_pump_app_events() void;
    extern fn macos_pump_app_events_timeout(timeout_ms: c_uint) void;
    extern fn macos_should_quit() c_int;
    extern fn macos_consume_app_became_active() c_int;
    extern fn macos_consume_app_reopen() c_int;
    extern fn macos_set_app_reopen_handled(handled: c_int) void;
    extern fn macos_check_window_should_close(window_ptr: *anyopaque) c_int;
    extern fn macos_reset_window_should_close(window_ptr: *anyopaque) void;
    extern fn macos_update_window_mouse(window_ptr: *anyopaque) void;
    extern fn macos_is_window_focused(window_ptr: *anyopaque) c_int;
    extern fn macos_window_appears_active(window_ptr: *anyopaque) c_int;

    // CVDisplayLink (C6): vsync-driven frame scheduling
    extern fn macos_start_display_link(window_ptr: *anyopaque) void;
    extern fn macos_stop_display_link(window_ptr: *anyopaque) void;
    extern fn macos_get_display_refresh_rate(window_ptr: *anyopaque) f32;
    extern fn macos_get_display_tick(window_ptr: *anyopaque) u64;
    extern fn macos_get_presentation_clock(window_ptr: *anyopaque, times: *[3]f64) u64;
    extern fn macos_post_empty_event() void;
    extern fn macos_window_recording_start(window_id: u32, path: [*:0]const u8, fps: u32, width: u32, height: u32, out: *WindowRecordingState) c_int;
    extern fn macos_window_recording_append(window_id: u32, texture: *anyopaque) c_int;
    extern fn macos_window_recording_status(window_id: u32, out: *WindowRecordingState) c_int;
    extern fn macos_window_recording_stop(window_id: u32, out: *WindowRecordingState) c_int;

    /// Fixed-layout mirror of the native AVFoundation recording bridge. Keeping all
    /// strings inline makes the callback result safe after Objective-C returns.
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

    var app_initialized = false;

    /// Initialize Cocoa app and set NSApplicationDelegate + menu bar. Call before creating windows.
    /// For App Bundle mode.
    pub fn initAppWithDelegate() void {
        if (!app_initialized) {
            macos_init_app_with_delegate();
            app_initialized = true;
        }
    }

    pub fn showBlockingAlert(title: [:0]const u8, message: [:0]const u8) void {
        macos_show_blocking_alert(title.ptr, message.ptr);
    }

    pub fn init(width: u32, height: u32, title: [:0]const u8) !MacOSWindow {
        return initInternal(width, height, title, false);
    }

    fn initInternal(width: u32, height: u32, title: [:0]const u8, borderless: bool) !MacOSWindow {
        if (!app_initialized) {
            macos_init_app();
            app_initialized = true;
        }

        const window_ptr = (if (borderless)
            macos_create_window_borderless(@intCast(width), @intCast(height), title.ptr)
        else
            macos_create_window(@intCast(width), @intCast(height), title.ptr)) orelse return error.WindowCreationFailed;

        const view_ptr = macos_get_metal_view(window_ptr) orelse {
            macos_destroy_window(window_ptr);
            return error.NoMetalView;
        };

        std.log.info("[MacOSWindow] Native window created: {d}x{d} borderless={any}", .{ width, height, borderless });

        return MacOSWindow{
            .window_ptr = window_ptr,
            .view_ptr = view_ptr,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *MacOSWindow) void {
        macos_destroy_window(self.window_ptr);
        std.log.info("[MacOSWindow] Window destroyed", .{});
    }

    /// Commit a previously-approved close through AppKit's native window path.
    /// Returns false only when the native window is already unavailable.
    pub fn beginClose(self: *MacOSWindow) bool {
        return macos_begin_window_close(self.window_ptr) != 0;
    }

    /// True after AppKit has closed the NSWindow and its native-animation
    /// retention boundary has elapsed, making resource release safe.
    pub fn closeCompleted(self: *const MacOSWindow) bool {
        return macos_window_close_completed(self.window_ptr) != 0;
    }

    /// Start CVDisplayLink: posts empty event to main thread on each vsync from CV thread.
    /// Idempotent, no-op if already running.
    pub fn startDisplayLink(self: *MacOSWindow) void {
        macos_start_display_link(self.window_ptr);
    }

    /// Stop CVDisplayLink (save power on idle). Idempotent. Link object retained for reuse on next
    /// start.
    pub fn stopDisplayLink(self: *MacOSWindow) void {
        macos_stop_display_link(self.window_ptr);
    }

    /// Nominal refresh rate (Hz) of display containing this window. Returns 60 if link not created.
    pub fn getDisplayRefreshRate(self: *MacOSWindow) f32 {
        return macos_get_display_refresh_rate(self.window_ptr);
    }

    /// Monotonic, per-window CVDisplayLink callback token. Zero means no
    /// callback yet; starting/stopping the link never rewinds the token.
    pub fn getDisplayTick(self: *const MacOSWindow) u64 {
        return macos_get_display_tick(self.window_ptr);
    }

    pub const DisplayTiming = struct {
        tick: u64,
        callback_time_seconds: f64,
        target_time_seconds: f64,
        current_time_seconds: f64,
    };

    pub fn getDisplayTiming(self: *const MacOSWindow) DisplayTiming {
        var times: [3]f64 = .{ 0, 0, 0 };
        const tick = macos_get_presentation_clock(self.window_ptr, &times);
        return .{ .tick = tick, .callback_time_seconds = times[0], .target_time_seconds = times[1], .current_time_seconds = times[2] };
    }

    /// Thread-safe event-pump wakeup. The native display-link callback uses the
    /// same primitive from its worker thread.
    pub fn postEmptyEvent() void {
        macos_post_empty_event();
    }

    pub fn pollEvents(self: *MacOSWindow) bool {
        const should_continue = macos_poll_events(self.window_ptr);

        // Update window size
        var w: c_int = 0;
        var h: c_int = 0;
        macos_get_window_size(self.window_ptr, &w, &h);
        self.width = @intCast(w);
        self.height = @intCast(h);

        return should_continue != 0;
    }

    pub fn getSize(self: *MacOSWindow) [2]u32 {
        var w: c_int = 0;
        var h: c_int = 0;
        macos_get_window_size(self.window_ptr, &w, &h);
        self.width = @intCast(w);
        self.height = @intCast(h);
        return .{ self.width, self.height };
    }

    /// Set window size (content size, same coordinate system as getSize). Window center unchanged.
    pub fn setSize(self: *MacOSWindow, width: u32, height: u32) void {
        macos_set_window_size(self.window_ptr, @intCast(width), @intCast(height));
        self.width = width;
        self.height = height;
    }

    /// Get DPI scale factor (Retina: 2.0, normal: 1.0)
    pub fn getScaleFactor(self: *MacOSWindow) f32 {
        return @floatCast(macos_get_scale_factor(self.window_ptr));
    }

    /// System ID of this window (macOS = NSWindow.windowNumber). In multi-window, use to set
    /// Cx.window_id
    /// so a11y / system APIs route to this window not first window. Returns 0 if window invalid.
    pub fn getWindowId(self: *MacOSWindow) u32 {
        return macos_window_id(self.window_ptr);
    }

    /// Starts a native-resolution, app-window-only H.264/MP4 recording.
    /// The operating-system pointer is intentionally not exposed to the
    /// recorder; the same CGWindowID used for event routing selects the source.
    pub fn startWindowRecording(self: *MacOSWindow, path: []const u8, fps: u32) WindowRecordingState {
        var state: WindowRecordingState = .{};
        if (path.len == 0 or path.len >= 1024) {
            const message = "recording path is empty or too long";
            @memcpy(state.error_message[0..message.len], message);
            return state;
        }
        var path_z: [1024:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const drawable = self.getDrawableSize();
        _ = macos_window_recording_start(self.getWindowId(), &path_z, fps, drawable[0], drawable[1], &state);
        return state;
    }

    pub fn appendWindowRecordingFrame(self: *MacOSWindow, texture: *anyopaque) bool {
        return macos_window_recording_append(self.getWindowId(), texture) != 0;
    }

    pub fn windowRecordingStatus(self: *MacOSWindow) WindowRecordingState {
        var state: WindowRecordingState = .{};
        _ = macos_window_recording_status(self.getWindowId(), &state);
        return state;
    }

    pub fn stopWindowRecording(self: *MacOSWindow) WindowRecordingState {
        var state: WindowRecordingState = .{};
        _ = macos_window_recording_stop(self.getWindowId(), &state);
        return state;
    }

    /// Diagnostic count from the native window registry.
    pub fn liveWindowCount() u32 {
        return macos_live_window_count();
    }

    pub fn getDrawableSize(self: *MacOSWindow) [2]u32 {
        var w: c_int = 0;
        var h: c_int = 0;
        macos_get_drawable_size(self.view_ptr, &w, &h);
        return .{ @intCast(w), @intCast(h) };
    }

    /// Opaque native draw surface handle for GPU backend to interpret (Metal backend receives
    /// CAMetalLayer*).
    /// Not named getMetalLayer intentionally: platform window layer should not hardcode a GPU
    /// backend name,
    /// else second backend gets "Windows window calls getMetalLayer" semantic contradiction.
    pub fn getNativeSurfaceHandle(self: *MacOSWindow) *anyopaque {
        return macos_get_metal_layer(self.view_ptr).?;
    }

    /// Like above, return opaque native device handle (Metal backend: MTLDevice*).
    pub fn getNativeDeviceHandle(self: *MacOSWindow) *anyopaque {
        return macos_get_metal_device(self.view_ptr).?;
    }

    /// Set live-resize render callback
    pub fn setRenderCallback(
        self: *MacOSWindow,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        ctx: ?*anyopaque,
    ) void {
        macos_set_render_callback(self.window_ptr, callback, ctx);
    }

    /// Color shown where no presented frame covers the surface (the strip a
    /// growing live resize exposes before the new-size frame lands).
    pub fn setSurfaceBackground(self: *MacOSWindow, r: f32, g: f32, b: f32, a: f32) void {
        macos_set_surface_background(self.view_ptr, r, g, b, a);
    }

    /// Live-resize refresh ticker callback. Distinct from the setFrameSize
    /// render callback so the host can keep both to one frame per period.
    /// Null falls back to the render callback.
    pub fn setLiveResizeTickCallback(
        self: *MacOSWindow,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        ctx: ?*anyopaque,
    ) void {
        macos_set_live_resize_tick_callback(self.window_ptr, callback, ctx);
    }

    /// Request redraw
    pub fn requestRedraw(self: *MacOSWindow) void {
        macos_request_redraw(self.window_ptr);
    }

    /// Is window in live resize
    pub fn isInLiveResize(self: *MacOSWindow) bool {
        return macos_is_live_resize(self.window_ptr) != 0;
    }

    /// Mouse button enum. .other catchall: bridge filters otherMouse with buttonNumber == 2, but
    /// invariant
    /// relies on self-discipline in two ObjC switch statements; if either relaxes (back/forward
    /// side keys
    /// natural request) unchecked @enumFromInt is Debug panic / ReleaseFast UB. events.zig already
    /// defines
    /// .other, runtime maps to null.
    pub const MouseButton = enum(c_int) {
        left = 0,
        right = 1,
        middle = 2,
        other = 3,
    };

    /// Get mouse position (logical pixels, relative to window content, Y down)
    pub fn getMousePosition(self: *MacOSWindow) [2]f32 {
        var x: f32 = 0;
        var y: f32 = 0;
        macos_get_mouse_position(self.window_ptr, &x, &y);
        return .{ x, y };
    }

    pub const MouseMoveEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        modifiers: Modifiers,
        /// Presence marker in the ordered motion stream: the pointer is no longer over this
        /// window's visible content (left it, or another window now covers it). x/y repeat the
        /// last position. The SDK reports it as `pointer_left`.
        left: bool = false,
    };

    pub fn getMouseMoveEvent(self: *MacOSWindow) ?MouseMoveEvent {
        var sequence: u64 = 0;
        var x: f32 = 0;
        var y: f32 = 0;
        var dx: f32 = 0;
        var dy: f32 = 0;
        var modifiers: u32 = 0;
        var left: c_int = 0;
        if (macos_get_mouse_move_event(self.window_ptr, &x, &y, &dx, &dy, &modifiers, &sequence, &left) == 0) return null;
        return .{
            .sequence = sequence,
            .x = x,
            .y = y,
            .dx = dx,
            .dy = dy,
            .modifiers = Modifiers.fromRaw(modifiers),
            .left = left != 0,
        };
    }

    pub const InputQueueMetrics = struct {
        mouse_move_coalesced: u64,
        ime_preedit_coalesced: u64,
    };

    pub fn inputQueueMetrics() InputQueueMetrics {
        var mouse_move_coalesced: u64 = 0;
        var ime_preedit_coalesced: u64 = 0;
        macos_get_input_queue_metrics(&mouse_move_coalesced, &ime_preedit_coalesced);
        return .{
            .mouse_move_coalesced = mouse_move_coalesced,
            .ime_preedit_coalesced = ime_preedit_coalesced,
        };
    }

    /// Current hardware modifier state (process-level). Polling-style mouse_move cannot get
    /// event-level
    /// flags; use this to supplement move-time true modifiers.
    pub fn currentModifiers() Modifiers {
        return Modifiers.fromRaw(macos_current_modifier_flags());
    }

    /// Check if mouse button pressed
    pub fn isMouseButtonPressed(self: *MacOSWindow, button: MouseButton) bool {
        return macos_is_mouse_button_pressed(self.window_ptr, @backingInt(button)) != 0;
    }

    /// Keyboard events
    pub const KeyEvent = struct {
        sequence: u64,
        keycode: u16,
        modifiers: Modifiers,
        pressed: bool,
        character: ?u8,
    };

    /// Modifier keys
    pub const Modifiers = packed struct {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        cmd: bool = false,
        _padding: u28 = 0,

        pub fn fromRaw(raw: u32) Modifiers {
            return .{
                .shift = (raw & 0x20000) != 0, // NSEventModifierFlagShift
                .ctrl = (raw & 0x40000) != 0, // NSEventModifierFlagControl
                .alt = (raw & 0x80000) != 0, // NSEventModifierFlagOption
                .cmd = (raw & 0x100000) != 0, // NSEventModifierFlagCommand
            };
        }
    };

    /// macOS key code constants
    pub const KeyCode = struct {
        pub const RETURN: u16 = 36;
        pub const TAB: u16 = 48;
        pub const SPACE: u16 = 49;
        pub const DELETE: u16 = 51; // Backspace
        pub const ESCAPE: u16 = 53;
        pub const LEFT: u16 = 123;
        pub const RIGHT: u16 = 124;
        pub const DOWN: u16 = 125;
        pub const UP: u16 = 126;
        pub const FORWARD_DELETE: u16 = 117;
        pub const HOME: u16 = 115;
        pub const END: u16 = 119;
        pub const PAGE_UP: u16 = 116;
        pub const PAGE_DOWN: u16 = 121;
        pub const A: u16 = 0;
        pub const C: u16 = 8;
        pub const V: u16 = 9;
        pub const X: u16 = 7;
        pub const Z: u16 = 6;
    };

    /// Get key event if any
    pub fn getKeyEvent(self: *MacOSWindow) ?KeyEvent {
        var keycode: u16 = 0;
        var modifiers: u32 = 0;
        var character: u8 = 0;
        var pressed: c_int = 0;
        var sequence: u64 = 0;

        if (macos_get_key_event(self.window_ptr, &keycode, &modifiers, &character, &pressed, &sequence) != 0) {
            return .{
                .sequence = sequence,
                .keycode = keycode,
                .modifiers = Modifiers.fromRaw(modifiers),
                .pressed = pressed != 0,
                .character = if (character != 0) character else null,
            };
        }
        return null;
    }

    pub const TextInputEvent = struct {
        sequence: u64,
        text: []const u8,
    };

    /// Get text input event (UTF-8)
    pub fn getInputText(self: *MacOSWindow, buffer: []u8) ?TextInputEvent {
        if (buffer.len == 0) return null;
        var sequence: u64 = 0;
        const len = macos_get_input_text(self.window_ptr, buffer.ptr, @intCast(buffer.len), &sequence);
        if (len > 0) {
            return .{ .sequence = sequence, .text = buffer[0..@intCast(len)] };
        }
        return null;
    }

    /// IME replacementRange sentinel: this event does not revise already-committed text (current
    /// behavior).
    pub const ime_no_replacement: u32 = 0xFFFF_FFFF;

    pub const ImePreeditEvent = struct {
        sequence: u64,
        text: []const u8,
        cursor_utf8_offset: u32,
        /// replacementRange converted to UTF-8 byte range (relative to document);
        /// ime_no_replacement sentinel = no replacement.
        replace_start_utf8: u32 = ime_no_replacement,
        replace_end_utf8: u32 = ime_no_replacement,
    };

    pub const ImeCommitEvent = struct {
        sequence: u64,
        text: []const u8,
        replace_start_utf8: u32 = ime_no_replacement,
        replace_end_utf8: u32 = ime_no_replacement,
    };

    pub const TextEventKind = enum(u32) { input, preedit, commit };

    /// Caller owns the returned text allocation. The native queue head is
    /// consumed only after copying succeeds; a retry observes the same event.
    pub fn readTextEventAllocChecked(self: *MacOSWindow, allocator: std.mem.Allocator, kind: TextEventKind) !?ImePreeditEvent {
        var bytes: ?[*]const u8 = null;
        var length: usize = 0;
        var event: ImePreeditEvent = .{ .sequence = 0, .text = "", .cursor_utf8_offset = 0 };
        const status = macos_peek_text_event(self.window_ptr, @backingInt(kind), &bytes, &length, &event.cursor_utf8_offset, &event.replace_start_utf8, &event.replace_end_utf8, &event.sequence);
        if (status == 0) return null;
        if (status != 1 or event.sequence == 0 or (length > 0 and bytes == null)) return error.BackendFailure;
        const owned = try allocator.dupe(u8, if (length == 0) "" else bytes.?[0..length]);
        errdefer allocator.free(owned);
        if (macos_consume_text_event(self.window_ptr, @backingInt(kind), event.sequence) != 1) return error.BackendFailure;
        event.text = owned;
        return event;
    }

    pub fn getImePreedit(self: *MacOSWindow, buffer: []u8) ?ImePreeditEvent {
        if (buffer.len == 0) return null;
        var out_len: c_int = 0;
        var cursor_utf8_offset: u32 = 0;
        var replace_start_utf8: u32 = ime_no_replacement;
        var replace_end_utf8: u32 = ime_no_replacement;
        var sequence: u64 = 0;
        if (macos_get_ime_preedit(self.window_ptr, buffer.ptr, @intCast(buffer.len), &out_len, &cursor_utf8_offset, &replace_start_utf8, &replace_end_utf8, &sequence) != 0) {
            const len: usize = @intCast(if (out_len < 0) 0 else out_len);
            return .{
                .sequence = sequence,
                .text = buffer[0..len],
                .cursor_utf8_offset = cursor_utf8_offset,
                .replace_start_utf8 = replace_start_utf8,
                .replace_end_utf8 = replace_end_utf8,
            };
        }
        return null;
    }

    pub fn getImeCommit(self: *MacOSWindow, buffer: []u8) ?ImeCommitEvent {
        if (buffer.len == 0) return null;
        var out_len: c_int = 0;
        var replace_start_utf8: u32 = ime_no_replacement;
        var replace_end_utf8: u32 = ime_no_replacement;
        var sequence: u64 = 0;
        if (macos_get_ime_commit(self.window_ptr, buffer.ptr, @intCast(buffer.len), &out_len, &replace_start_utf8, &replace_end_utf8, &sequence) != 0) {
            const len: usize = @intCast(if (out_len < 0) 0 else out_len);
            return .{
                .sequence = sequence,
                .text = buffer[0..len],
                .replace_start_utf8 = replace_start_utf8,
                .replace_end_utf8 = replace_end_utf8,
            };
        }
        return null;
    }

    /// Set IME candidate window anchor rect (logical pixels, top-left origin)
    pub fn setImeCursorRect(self: *MacOSWindow, x: f32, y: f32, width: f32, height: f32) void {
        macos_set_ime_cursor_rect(self.window_ptr, x, y, width, height);
    }

    /// Controls text interpretation / IME only; raw keyDown/keyUp always dispatched from window
    /// event queue.
    extern fn macos_set_keyboard_isolated(window: *anyopaque, isolated: c_int) void;
    /// Test-runtime ingress gate; defaults off for every native window.
    pub fn setKeyboardIsolated(self: *MacOSWindow, isolated: bool) void {
        macos_set_keyboard_isolated(self.window_ptr, @intFromBool(isolated));
    }

    pub fn setTextInputEnabled(self: *MacOSWindow, enabled: bool) void {
        macos_set_text_input_enabled(self.window_ptr, @intFromBool(enabled));
    }

    extern fn macos_set_reserved_key_chords(window_ptr: *anyopaque, chords: [*]const u32, count: u32) void;

    /// Modifier bits of a packed reserved chord (`ZENIT_CHORD_*` in window_bridge.m).
    pub const ReservedChordMask = struct {
        pub const shift: u32 = 1;
        pub const control: u32 = 2;
        pub const option: u32 = 4;
        pub const command: u32 = 8;
    };

    /// Packed entry: macOS virtual keycode | (modifier mask << 16).
    pub fn packReservedChord(keycode: u16, shift: bool, control: bool, option: bool, command: bool) u32 {
        var m: u32 = 0;
        if (shift) m |= ReservedChordMask.shift;
        if (control) m |= ReservedChordMask.control;
        if (option) m |= ReservedChordMask.option;
        if (command) m |= ReservedChordMask.command;
        return @as(u32, keycode) | (m << 16);
    }

    /// Replace the window's reserved chords (at most 32; empty clears). A
    /// reserved keyDown is delivered as a key event but not interpreted by
    /// the input method (no text from it). See window_bridge.m.
    pub fn setReservedKeyChords(self: *MacOSWindow, packed_chords: []const u32) void {
        const n: u32 = @intCast(@min(packed_chords.len, 32));
        macos_set_reserved_key_chords(self.window_ptr, packed_chords.ptr, n);
    }

    /// Discard current IME composition (close candidate window + clear marked text); call on widget
    /// blur
    pub fn discardIme(self: *MacOSWindow) void {
        macos_ime_discard(self.window_ptr);
    }

    /// Set mouse cursor shape
    pub fn setCursorShape(self: *MacOSWindow, shape: u8) void {
        macos_set_cursor_shape(self.window_ptr, @intCast(shape));
    }

    /// Activate this window and establish its Metal view as the first
    /// responder. This is the public programmatic counterpart of a user click.
    pub fn activate(self: *MacOSWindow) void {
        macos_activate_window(self.window_ptr);
    }

    /// Close completion may restore an unclaimed key window, never desktop activation.
    pub fn restoreFocus(self: *MacOSWindow) void {
        macos_restore_key_window(self.window_ptr);
    }

    extern fn macos_add_child_window(parent_ptr: *anyopaque, child_ptr: *anyopaque) void;
    extern fn macos_remove_child_window(parent_ptr: *anyopaque, child_ptr: *anyopaque) void;
    extern fn macos_get_centering_geometry(child_ptr: *anyopaque, parent_ptr: *anyopaque, host_x: *f64, host_y: *f64, host_w: *f64, host_h: *f64, panel_w: *f64, panel_h: *f64, vis_x: *f64, vis_y: *f64, vis_w: *f64, vis_h: *f64) c_int;
    extern fn macos_window_geometry(window_ptr: *anyopaque, screen: u64, out: *[9]f64) c_int;
    extern fn macos_restore_window_frame(window_ptr: *anyopaque, frame: *const [4]f64) void;
    /// Logical outer frame, visible screen frame, stable display number.
    pub fn previewGeometry(self: *MacOSWindow, screen: u64) ?[9]f64 {
        var out: [9]f64 = undefined;
        if (macos_window_geometry(self.window_ptr, screen, &out) == 0) return null;
        return out;
    }
    pub fn restorePreviewFrame(self: *MacOSWindow, frame: [4]f64) void {
        macos_restore_window_frame(self.window_ptr, &frame);
    }
    extern fn macos_set_window_origin(window_ptr: *anyopaque, x: f64, y: f64) void;
    extern fn macos_set_resign_key_callback(window_ptr: *anyopaque, cb: ?*const fn (?*anyopaque, c_int) callconv(.c) void, ctx: ?*anyopaque) void;

    /// Attach this window to `owner`: it stays above the owner, comes forward
    /// with it, and never floats over other applications.
    pub fn setOwner(self: *MacOSWindow, owner: *MacOSWindow) bool {
        macos_add_child_window(owner.window_ptr, self.window_ptr);
        return true;
    }

    pub fn clearOwner(self: *MacOSWindow, owner: *MacOSWindow) void {
        macos_remove_child_window(owner.window_ptr, self.window_ptr);
    }

    /// Centre on `owner` (see owned_window.centerOnOwner). Must run after the
    /// window has its final size. Leaves the window where it is when the
    /// geometry is unavailable.
    pub fn centerOnOwner(self: *MacOSWindow, owner: *MacOSWindow) bool {
        var host: owned_window.Rect = undefined;
        var visible: owned_window.Rect = undefined;
        var panel_w: f64 = 0;
        var panel_h: f64 = 0;
        if (macos_get_centering_geometry(self.window_ptr, owner.window_ptr, &host.x, &host.y, &host.w, &host.h, &panel_w, &panel_h, &visible.x, &visible.y, &visible.w, &visible.h) == 0) return false;
        const origin = owned_window.centerOnOwner(host, panel_w, panel_h, visible, .up);
        macos_set_window_origin(self.window_ptr, origin.x, origin.y);
        return true;
    }

    /// Record resign-key notifications into `pending_focus_loss`. `self` must
    /// be at its final address. The native side clears the callback when the
    /// window starts closing.
    pub fn armFocusLossReporting(self: *MacOSWindow) void {
        macos_set_resign_key_callback(self.window_ptr, focusLossCallback, self);
    }

    pub fn takeFocusLoss(self: *MacOSWindow) ?owned_window.FocusLoss {
        defer self.pending_focus_loss = null;
        return self.pending_focus_loss;
    }

    fn focusLossCallback(ctx: ?*anyopaque, new_key_is_app: c_int) callconv(.c) void {
        const self: *MacOSWindow = @ptrCast(@alignCast(ctx orelse return));
        self.pending_focus_loss = if (new_key_is_app != 0) .same_application else .other_application;
    }

    pub const ScrollEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        /// Scroll delta in logical points (normalized at the event bridge).
        dx: f32,
        /// Scroll delta in logical points (normalized at the event bridge).
        dy: f32,
        /// NSEvent.phase encoding: 0=none, 1=may_begin, 2=began, 3=changed, 4=ended, 5=cancelled
        phase: u8,
        /// NSEvent.momentumPhase encoding: 0=none, 1=began, 2=changed, 3=ended (cancelled folds into ended)
        momentum: u8,
        /// Modifier state at event time (needed for Cmd+scroll zoom etc.)
        modifiers: Modifiers = .{},
    };

    /// Get scroll event if any
    pub fn getScrollDelta(self: *MacOSWindow) ?ScrollEvent {
        var x: f32 = -1;
        var y: f32 = -1;
        var dx: f32 = 0;
        var dy: f32 = 0;
        var phase: u8 = 0;
        var momentum: u8 = 0;
        var modifiers: u32 = 0;
        var sequence: u64 = 0;
        if (macos_get_scroll_event(self.window_ptr, &x, &y, &dx, &dy, &phase, &momentum, &modifiers, &sequence) != 0) {
            return .{
                .sequence = sequence,
                .x = x,
                .y = y,
                .dx = dx,
                .dy = dy,
                .phase = phase,
                .momentum = momentum,
                .modifiers = Modifiers.fromRaw(modifiers),
            };
        }
        return null;
    }

    /// Trackpad pinch-gesture event
    pub const MagnifyEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        /// Relative delta: new_scale = old_scale * (1 + magnification)
        magnification: f32,
        /// 0=began 1=changed 2=ended 3=cancelled
        phase: u8,
    };

    /// Get pinch event if any
    pub fn getMagnifyEvent(self: *MacOSWindow) ?MagnifyEvent {
        var x: f32 = 0;
        var y: f32 = 0;
        var magnification: f32 = 0;
        var phase: u8 = 0;
        var sequence: u64 = 0;
        if (macos_get_magnify_event(self.window_ptr, &x, &y, &magnification, &phase, &sequence) != 0) {
            return .{ .sequence = sequence, .x = x, .y = y, .magnification = magnification, .phase = phase };
        }
        return null;
    }

    /// Drag and drop events
    pub const DragEvent = struct {
        x: f32,
        y: f32,
        /// 0=entered 1=updated 2=exited 3=dropped 4=source completion
        kind: u8,
        /// Valid on dropped: writes newline-separated paths / URL list to buffer
        paths: []const u8,
        payload_kind: u8,
        source_token: u64,
        operation: u8,
        /// Legacy truncation flag; complete checked peeks always return false.
        paths_truncated: bool,
    };

    pub const PendingDragEvent = struct {
        event: DragEvent,
        token: *const anyopaque,
    };

    /// Borrowed until consumption or native queue mutation. Copy into its
    /// destination before consuming, without pumping AppKit between calls.
    pub fn peekDragEventChecked(self: *MacOSWindow) !?PendingDragEvent {
        var event: DragEvent = .{ .x = 0, .y = 0, .kind = 0, .paths = "", .payload_kind = 0, .source_token = 0, .operation = 0, .paths_truncated = false };
        var bytes: ?[*]const u8 = null;
        var length: usize = 0;
        var token: ?*const anyopaque = null;
        const status = macos_peek_drag_event(self.window_ptr, &event.x, &event.y, &event.kind, &bytes, &length, &token, &event.payload_kind, &event.source_token, &event.operation);
        if (status == 0) return null;
        if (status != 1 or token == null or (length > 0 and bytes == null)) return error.BackendFailure;
        event.paths = if (length == 0) "" else bytes.?[0..length];
        return .{ .event = event, .token = token.? };
    }

    pub fn consumeDragEventChecked(self: *MacOSWindow, token: *const anyopaque) !void {
        if (macos_consume_drag_event(self.window_ptr, token) != 1) return error.BackendFailure;
    }

    /// Get drag and drop event if any. paths writes to caller-provided buffer.
    pub fn getDragEvent(self: *MacOSWindow, paths_buf: []u8) ?DragEvent {
        if (paths_buf.len == 0 or paths_buf.len > std.math.maxInt(c_int)) return null;
        var x: f32 = 0;
        var y: f32 = 0;
        var kind: u8 = 0;
        var source_token: u64 = 0;
        var operation: u8 = 0;
        var payload_kind: u8 = 0;
        var paths_truncated: u8 = 0;
        if (macos_get_drag_event(self.window_ptr, &x, &y, &kind, paths_buf.ptr, @intCast(paths_buf.len), &payload_kind, &source_token, &operation, &paths_truncated) != 0) {
            const len = std.mem.indexOfScalar(u8, paths_buf, 0) orelse paths_buf.len;
            return .{ .x = x, .y = y, .kind = kind, .paths = paths_buf[0..len], .payload_kind = payload_kind, .source_token = source_token, .operation = operation, .paths_truncated = paths_truncated != 0 };
        }
        return null;
    }

    /// Mouse button event queue (queue-style, consume one per call, will not miss press+release
    /// same frame)
    pub const MouseButtonEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        button: MouseButton,
        pressed: bool,
        /// Raw NSEventModifierFlags bitmask (see macos_modifiers).
        modifiers: u32 = 0,
    };

    /// Get mouse button event if any
    pub fn getMouseButtonEvent(self: *MacOSWindow) ?MouseButtonEvent {
        var x: f32 = 0;
        var y: f32 = 0;
        var button: c_int = 0;
        var pressed: c_int = 0;
        var mods: u32 = 0;
        var sequence: u64 = 0;
        if (macos_get_mouse_button_event_ex(self.window_ptr, &x, &y, &button, &pressed, &mods, &sequence) != 0) {
            return .{
                .sequence = sequence,
                .x = x,
                .y = y,
                .button = std.enums.fromInt(MouseButton, button) orelse .other,
                .pressed = pressed != 0,
                .modifiers = mods,
            };
        }
        return null;
    }

    /// Check if window should close
    pub fn shouldClose(self: *MacOSWindow) bool {
        return macos_should_close(self.window_ptr) != 0;
    }

    /// Update mouse position (for windows not polling events)
    pub fn updateMousePosition(self: *MacOSWindow) void {
        macos_update_mouse_position(self.window_ptr);
    }

    /// Set whether inactive window accepts mouse move (inspector pick mode crosses windows)
    pub fn setAcceptsMouseWhileInactive(self: *MacOSWindow, accepts: bool) void {
        macos_set_accepts_mouse_while_inactive(self.window_ptr, if (accepts) 1 else 0);
    }

    /// Check if window needs rendering (visible and not fully occluded)
    pub fn shouldRender(self: *MacOSWindow) bool {
        return macos_should_render_window(self.window_ptr) != 0;
    }

    /// Get system titlebar height (traffic-light area height, typically 28-38px)
    pub fn getTitlebarHeight(self: *MacOSWindow) f32 {
        return macos_get_titlebar_height(self.window_ptr);
    }

    /// Begin window drag (call in custom TitleBar mouseDown)
    pub fn performWindowDrag(self: *MacOSWindow) void {
        macos_perform_window_drag(self.window_ptr);
    }

    /// Set traffic-light button positions in custom titlebar. inset_x: left margin of first button,
    /// inset_y: distance from window top to button center
    pub fn setTrafficLightsInset(self: *MacOSWindow, inset_x: f32, inset_y: f32) void {
        macos_set_traffic_lights_inset(self.window_ptr, inset_x, inset_y);
    }

    /// Set custom titlebar drag area height (logical pixels from window top). When > 0, mouseDown
    /// in area
    /// auto-triggers window drag. Hit-driven drag: mouseDown in drag band first asks callback if
    /// point hits
    /// interactive control (nonzero = yes, event routes normally no window drag). Pass null to
    /// clear,
    /// fall back to pure-rect model.
    pub fn setTitlebarHitCallback(self: *MacOSWindow, cb: ?*const fn (?*anyopaque, f32, f32) callconv(.c) c_int, ctx: ?*anyopaque) void {
        macos_set_titlebar_hit_callback(self.window_ptr, cb, ctx);
    }

    /// Change the window title after creation.
    pub fn setTitle(self: *MacOSWindow, title: [:0]const u8) void {
        macos_set_window_title(self.window_ptr, title.ptr);
    }

    pub fn setTitlebarDragHeight(self: *MacOSWindow, height: f32) void {
        macos_set_titlebar_drag_height(self.window_ptr, height);
    }

    /// Set titlebar right exclusion width (logical pixels). Lets titlebar right action buttons
    /// receive click
    /// without window drag intercepting.
    pub fn setTitlebarDragRightInset(self: *MacOSWindow, inset: f32) void {
        macos_set_titlebar_drag_right_inset(self.window_ptr, inset);
    }

    /// Get macOS openFile event pending path (Finder double-click / open -a). Returned slice points
    /// to caller's buffer;
    /// null = queue empty. If buffer too small, returns error.BufferTooSmall and does not dequeue
    /// (retry with larger buffer);
    /// see pendingOpenFileRequiredSize for needed size. Previously dequeued then truncated,
    /// silently losing files.
    pub fn getPendingOpenFile(self: *MacOSWindow, buf: []u8) error{BufferTooSmall}!?[]const u8 {
        _ = self; // polling does not need window param but keeping API consistent
        const size: c_int = @intCast(@min(buf.len, std.math.maxInt(c_int)));
        const len = macos_get_pending_open_file(buf.ptr, size);
        if (len < 0) return error.BufferTooSmall;
        if (len == 0) return null;
        return buf[0..@intCast(len)];
    }

    /// Buffer byte count needed for queue-head pending path (including NUL); null if queue empty.
    pub fn pendingOpenFileRequiredSize(self: *MacOSWindow) ?usize {
        _ = self;
        const rc = macos_get_pending_open_file(null, 0);
        if (rc >= 0) return null;
        return @intCast(-@as(i64, rc));
    }

    // ========== Multi-window architecture API ==========

    /// Pure event pump: pull all NSApp events, dispatch to each WindowWrapper.
    /// Not bound to any specific window (static method).
    pub fn pumpAppEvents() void {
        macos_pump_app_events();
    }

    pub fn pumpAppEventsTimeout(timeout_ms: u32) void {
        macos_pump_app_events_timeout(timeout_ms);
    }

    /// Check global exit flag (Cmd+Q or terminate:)
    pub fn appShouldQuit() bool {
        return macos_should_quit() != 0;
    }

    extern fn macos_cancel_app_quit() void;
    /// Withdraw a pending user quit request after the application vetoed it.
    pub fn cancelAppQuit() void {
        macos_cancel_app_quit();
    }

    /// Consume "app became foreground" flag: returns true and resets internally (one true per
    /// activation)
    pub fn consumeAppBecameActive() bool {
        return macos_consume_app_became_active() != 0;
    }

    /// Consume "app reopened while no window was visible" (Dock click, launching the running
    /// app again). Only raised while some window registered `setAppReopenHandled(true)`.
    pub fn consumeAppReopen() bool {
        return macos_consume_app_reopen() != 0;
    }

    /// Register (true) or withdraw (false) one window's application reopen handler. While any is
    /// registered, a reopen with no visible window is left to the application instead of
    /// AppKit's default (restore minimized windows).
    pub fn setAppReopenHandled(handled: bool) void {
        macos_set_app_reopen_handled(@intFromBool(handled));
    }

    /// Query whether system is in dark mode
    pub fn isDarkMode() bool {
        return macos_is_dark_mode() != 0;
    }

    /// Check if this window requested close (Cmd+W or windowShouldClose:)
    pub fn checkShouldClose(self: *MacOSWindow) bool {
        return macos_check_window_should_close(self.window_ptr) != 0;
    }

    /// Reset window close-request flag
    pub fn resetShouldClose(self: *MacOSWindow) void {
        macos_reset_window_should_close(self.window_ptr);
    }

    /// Update this window's mouse position (multi-window mode calls once per window)
    pub fn updateWindowMouse(self: *MacOSWindow) void {
        macos_update_window_mouse(self.window_ptr);
    }

    pub fn isFocused(self: *MacOSWindow) bool {
        return macos_is_window_focused(self.window_ptr) != 0;
    }

    /// System appearance sense of active (app foreground and key window); background e2e defaults
    /// to active.
    pub fn appearsActive(self: *MacOSWindow) bool {
        return macos_window_appears_active(self.window_ptr) != 0;
    }

    /// Menu action enum (one-to-one with ObjC MenuActionType)
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

    pub const MenuActionEvent = struct {
        /// Native NSWindow identity, not the application's logical WindowId.
        native_window_id: u64,
        action: MenuAction,
    };

    pub fn getMenuActionEvent() ?MenuActionEvent {
        var window_id: u64 = 0;
        var action: c_int = 0;
        if (macos_get_menu_action_event(&window_id, &action) == 0) return null;
        return .{ .native_window_id = window_id, .action = std.enums.fromInt(MenuAction, action) orelse return null };
    }

    /// Consume next menu action (global, not window-bound)
    pub fn getMenuAction() ?MenuAction {
        const raw = macos_get_menu_action();
        if (raw == 0) return null;
        return std.enums.fromInt(MenuAction, raw);
    }
};
