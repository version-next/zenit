const std = @import("std");

/// macOS 原生窗口 - 直接使用 Cocoa API
///
/// 完全绕过 GLFW，直接调用 macOS 原生 API
/// 解决了窗口拖拽时渲染停止的问题
pub const MacOSWindow = struct {
    window_ptr: *anyopaque,
    view_ptr: *anyopaque,
    width: u32,
    height: u32,

    // Objective-C C API 函数声明
    extern fn macos_init_app() void;
    extern fn macos_init_app_with_delegate() void;
    extern fn macos_show_blocking_alert(title: [*:0]const u8, message: [*:0]const u8) void;
    extern fn macos_is_dark_mode() c_int;
    extern fn macos_create_window(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
    extern fn macos_create_window_borderless(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
    extern fn macos_make_key_window(window_ptr: *anyopaque) void;

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
    extern fn macos_get_mouse_move_event(window_ptr: *anyopaque, x: *f32, y: *f32, dx: *f32, dy: *f32, modifiers: *u32, sequence: *u64) c_int;
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
    extern fn macos_get_scroll_event(window_ptr: *anyopaque, x: *f32, y: *f32, dx: *f32, dy: *f32, is_momentum: *c_int, phase_ended: *c_int, is_trackpad: *c_int, modifiers: *u32, sequence: *u64) c_int;
    extern fn macos_get_magnify_event(window_ptr: *anyopaque, x: *f32, y: *f32, magnification: *f32, phase: *u8, sequence: *u64) c_int;
    extern fn macos_peek_drag_event(window_ptr: *anyopaque, x: *f32, y: *f32, kind: *u8, bytes: *?[*]const u8, length: *usize, token: *?*const anyopaque, payload_kind: *u8, source_token: *u64, operation: *u8) c_int;
    extern fn macos_consume_drag_event(window_ptr: *anyopaque, token: *const anyopaque) c_int;
    extern fn macos_get_drag_event(window_ptr: *anyopaque, x: *f32, y: *f32, kind: *u8, paths_buf: [*]u8, paths_buf_len: c_int, payload_kind: *u8, source_token: *u64, operation: *u8, paths_truncated: *u8) c_int;
    extern fn macos_set_render_callback(window_ptr: *anyopaque, callback: ?*const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void;
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
    extern fn macos_set_titlebar_hit_callback(window_ptr: *anyopaque, cb: ?*const fn (?*anyopaque, f32, f32) callconv(.c) c_int, ctx: ?*anyopaque) void;
    extern fn macos_set_titlebar_drag_right_inset(window_ptr: *anyopaque, inset: f32) void;
    extern fn macos_destroy_window(window_ptr: *anyopaque) void;
    extern fn macos_begin_window_close(window_ptr: *anyopaque) c_int;
    extern fn macos_window_close_completed(window_ptr: *anyopaque) c_int;
    extern fn macos_get_pending_open_file(buffer: ?[*]u8, buffer_size: c_int) c_int;
    // 菜单动作 API
    extern fn macos_get_menu_action() c_int;
    extern fn macos_get_menu_action_event(window_id: *u64, action: *c_int) c_int;

    // 多窗口架构 API
    extern fn macos_pump_app_events() void;
    extern fn macos_pump_app_events_timeout(timeout_ms: c_uint) void;
    extern fn macos_should_quit() c_int;
    extern fn macos_consume_app_became_active() c_int;
    extern fn macos_check_window_should_close(window_ptr: *anyopaque) c_int;
    extern fn macos_reset_window_should_close(window_ptr: *anyopaque) void;
    extern fn macos_update_window_mouse(window_ptr: *anyopaque) void;
    extern fn macos_is_window_focused(window_ptr: *anyopaque) c_int;

    // CVDisplayLink (C6) — vsync 驱动帧调度
    extern fn macos_start_display_link(window_ptr: *anyopaque) void;
    extern fn macos_stop_display_link(window_ptr: *anyopaque) void;
    extern fn macos_get_display_refresh_rate(window_ptr: *anyopaque) f32;
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
        path: [768]u8 = [_]u8{0} ** 768,
        error_message: [256]u8 = [_]u8{0} ** 256,

        pub fn pathText(self: *const WindowRecordingState) []const u8 {
            return self.path[0..(std.mem.indexOfScalar(u8, &self.path, 0) orelse self.path.len)];
        }

        pub fn errorText(self: *const WindowRecordingState) []const u8 {
            return self.error_message[0..(std.mem.indexOfScalar(u8, &self.error_message, 0) orelse self.error_message.len)];
        }
    };

    var app_initialized = false;

    /// 初始化 Cocoa 应用并设置 NSApplicationDelegate + 菜单栏。
    /// 在创建窗口前调用。适用于 App Bundle 模式。
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

    /// 启动 CVDisplayLink：每个 vsync 在 CV 线程 post 空事件唤醒主线程 pump。
    /// 幂等——已在跑时是 no-op。
    pub fn startDisplayLink(self: *MacOSWindow) void {
        macos_start_display_link(self.window_ptr);
    }

    /// 停止 CVDisplayLink（idle 时省电）。幂等。link 对象保留，下次 start 复用。
    pub fn stopDisplayLink(self: *MacOSWindow) void {
        macos_stop_display_link(self.window_ptr);
    }

    /// 窗口所在显示器的标称刷新率（Hz）。link 未创建时返回 60。
    pub fn getDisplayRefreshRate(self: *MacOSWindow) f32 {
        return macos_get_display_refresh_rate(self.window_ptr);
    }

    /// Thread-safe event-pump wakeup. The native display-link callback uses the
    /// same primitive from its worker thread.
    pub fn postEmptyEvent() void {
        macos_post_empty_event();
    }

    pub fn pollEvents(self: *MacOSWindow) bool {
        const should_continue = macos_poll_events(self.window_ptr);

        // 更新窗口尺寸
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

    /// 设置窗口尺寸（content size，与 getSize 同一坐标系）。窗口中心保持不动。
    pub fn setSize(self: *MacOSWindow, width: u32, height: u32) void {
        macos_set_window_size(self.window_ptr, @intCast(width), @intCast(height));
        self.width = width;
        self.height = height;
    }

    /// 获取 DPI 缩放因子 (Retina: 2.0, 普通: 1.0)
    pub fn getScaleFactor(self: *MacOSWindow) f32 {
        return @floatCast(macos_get_scale_factor(self.window_ptr));
    }

    /// 本窗口的系统 id（macOS = NSWindow.windowNumber）。多窗口下用它给
    /// Cx.window_id 赋值，让 a11y / 系统 API 路由到本窗口而非"第一个窗口"。
    /// 窗口无效时返 0。
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

    /// 不透明的原生绘制表面句柄，交给 GPU 后端解释（Metal 后端拿到的是
    /// `CAMetalLayer*`）。刻意不叫 `getMetalLayer`：平台窗口层不该把某个
    /// GPU 后端的名字写进接口，否则将来第二个后端会出现
    /// "Windows 窗口也在调 getMetalLayer" 这种语义矛盾。
    pub fn getNativeSurfaceHandle(self: *MacOSWindow) *anyopaque {
        return macos_get_metal_layer(self.view_ptr).?;
    }

    /// 同上，返回不透明的原生设备句柄（Metal 后端为 `MTLDevice*`）。
    pub fn getNativeDeviceHandle(self: *MacOSWindow) *anyopaque {
        return macos_get_metal_device(self.view_ptr).?;
    }

    /// 设置 live resize 渲染回调
    pub fn setRenderCallback(
        self: *MacOSWindow,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        ctx: ?*anyopaque,
    ) void {
        macos_set_render_callback(self.window_ptr, callback, ctx);
    }

    /// 请求重绘
    pub fn requestRedraw(self: *MacOSWindow) void {
        macos_request_redraw(self.window_ptr);
    }

    /// 是否处于 live resize
    pub fn isInLiveResize(self: *MacOSWindow) bool {
        return macos_is_live_resize(self.window_ptr) != 0;
    }

    /// 鼠标按钮枚举。
    /// .other 兜底：桥当前用 buttonNumber == 2 过滤 otherMouse 事件，但该
    /// 不变式只靠 ObjC 侧两处 switch 的自律维持——任何一处将来放宽（back/
    /// forward 侧键是很自然的需求），未校验的 @enumFromInt 就是 Debug panic /
    /// ReleaseFast UB。events.zig 早已定义 .other、runtime 映射为 null。
    pub const MouseButton = enum(c_int) {
        left = 0,
        right = 1,
        middle = 2,
        other = 3,
    };

    /// 获取鼠标位置（逻辑像素，相对于窗口内容，Y 轴向下）
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
    };

    pub fn getMouseMoveEvent(self: *MacOSWindow) ?MouseMoveEvent {
        var sequence: u64 = 0;
        var x: f32 = 0;
        var y: f32 = 0;
        var dx: f32 = 0;
        var dy: f32 = 0;
        var modifiers: u32 = 0;
        if (macos_get_mouse_move_event(self.window_ptr, &x, &y, &dx, &dy, &modifiers, &sequence) == 0) return null;
        return .{
            .sequence = sequence,
            .x = x,
            .y = y,
            .dx = dx,
            .dy = dy,
            .modifiers = Modifiers.fromRaw(modifiers),
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

    /// 当前硬件修饰键状态（进程级）。轮询式 mouse_move 取不到事件级
    /// flags，用它补移动时刻的真实修饰键。
    pub fn currentModifiers() Modifiers {
        return Modifiers.fromRaw(macos_current_modifier_flags());
    }

    /// 检查鼠标按钮是否按下
    pub fn isMouseButtonPressed(self: *MacOSWindow, button: MouseButton) bool {
        return macos_is_mouse_button_pressed(self.window_ptr, @intFromEnum(button)) != 0;
    }

    /// 键盘事件
    pub const KeyEvent = struct {
        sequence: u64,
        keycode: u16,
        modifiers: Modifiers,
        pressed: bool,
        character: ?u8,
    };

    /// 修饰键
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

    /// macOS 键码常量
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

    /// 获取按键事件（如果有）
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

    /// 获取输入的文本事件（UTF-8）
    pub fn getInputText(self: *MacOSWindow, buffer: []u8) ?TextInputEvent {
        if (buffer.len == 0) return null;
        var sequence: u64 = 0;
        const len = macos_get_input_text(self.window_ptr, buffer.ptr, @intCast(buffer.len), &sequence);
        if (len > 0) {
            return .{ .sequence = sequence, .text = buffer[0..@intCast(len)] };
        }
        return null;
    }

    /// IME replacementRange 哨兵：本次事件不修订已提交文本（现行为）。
    pub const ime_no_replacement: u32 = 0xFFFF_FFFF;

    pub const ImePreeditEvent = struct {
        sequence: u64,
        text: []const u8,
        cursor_utf8_offset: u32,
        /// replacementRange 换算成的 UTF-8 字节区间（相对文档）；
        /// ime_no_replacement 哨兵 = 无 replacement。
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
        const status = macos_peek_text_event(self.window_ptr, @intFromEnum(kind), &bytes, &length, &event.cursor_utf8_offset, &event.replace_start_utf8, &event.replace_end_utf8, &event.sequence);
        if (status == 0) return null;
        if (status != 1 or event.sequence == 0 or (length > 0 and bytes == null)) return error.BackendFailure;
        const owned = try allocator.dupe(u8, if (length == 0) "" else bytes.?[0..length]);
        errdefer allocator.free(owned);
        if (macos_consume_text_event(self.window_ptr, @intFromEnum(kind), event.sequence) != 1) return error.BackendFailure;
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

    /// 设置 IME 候选窗口锚点矩形（逻辑像素，左上原点）
    pub fn setImeCursorRect(self: *MacOSWindow, x: f32, y: f32, width: f32, height: f32) void {
        macos_set_ime_cursor_rect(self.window_ptr, x, y, width, height);
    }

    /// 仅控制文本解释/IME；原始 keyDown/keyUp 始终由窗口事件队列派发。
    pub fn setTextInputEnabled(self: *MacOSWindow, enabled: bool) void {
        macos_set_text_input_enabled(self.window_ptr, @intFromBool(enabled));
    }

    /// 放弃当前 IME 合成（关候选窗 + 清 marked text）；widget blur 时调用
    pub fn discardIme(self: *MacOSWindow) void {
        macos_ime_discard(self.window_ptr);
    }

    /// 设置鼠标光标形状
    pub fn setCursorShape(self: *MacOSWindow, shape: u8) void {
        macos_set_cursor_shape(self.window_ptr, @intCast(shape));
    }

    /// Activate this window and establish its Metal view as the first
    /// responder. This is the public programmatic counterpart of a user click.
    pub fn activate(self: *MacOSWindow) void {
        macos_make_key_window(self.window_ptr);
    }

    pub const ScrollEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        /// true = 松手后惯性滚动（momentum），false = 手指触摸中
        is_momentum: bool,
        /// true = 触摸板手指抬起 (NSEventPhaseEnded)
        phase_ended: bool,
        /// true = 触摸板事件（有 phase 信息），false = 鼠标滚轮
        is_trackpad: bool,
        /// 事件发生时的修饰键状态（Cmd+滚轮缩放等场景需要）
        modifiers: Modifiers = .{},
    };

    /// 获取滚轮事件（如果有）
    pub fn getScrollDelta(self: *MacOSWindow) ?ScrollEvent {
        var x: f32 = -1;
        var y: f32 = -1;
        var dx: f32 = 0;
        var dy: f32 = 0;
        var is_momentum: c_int = 0;
        var phase_ended: c_int = 0;
        var is_trackpad: c_int = 0;
        var modifiers: u32 = 0;
        var sequence: u64 = 0;
        if (macos_get_scroll_event(self.window_ptr, &x, &y, &dx, &dy, &is_momentum, &phase_ended, &is_trackpad, &modifiers, &sequence) != 0) {
            return .{
                .sequence = sequence,
                .x = x,
                .y = y,
                .dx = dx,
                .dy = dy,
                .is_momentum = is_momentum != 0,
                .phase_ended = phase_ended != 0,
                .is_trackpad = is_trackpad != 0,
                .modifiers = Modifiers.fromRaw(modifiers),
            };
        }
        return null;
    }

    /// 触控板捏合手势事件
    pub const MagnifyEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        /// 相对增量：new_scale = old_scale * (1 + magnification)
        magnification: f32,
        /// 0=began 1=changed 2=ended 3=cancelled
        phase: u8,
    };

    /// 获取捏合事件（如果有）
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

    /// 拖放事件
    pub const DragEvent = struct {
        x: f32,
        y: f32,
        /// 0=entered 1=updated 2=exited 3=dropped 4=source completion
        kind: u8,
        /// dropped 时有效：写入 buffer 的换行分隔路径 / URL 列表
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

    /// 获取拖放事件（如果有）。paths 写入调用方提供的 buffer。
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

    /// 鼠标按键事件（队列式，每次消费一个，不会 miss 同帧 press+release）
    pub const MouseButtonEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        button: MouseButton,
        pressed: bool,
        /// 原始 NSEventModifierFlags 位掩码（见 macos_modifiers）。
        modifiers: u32 = 0,
    };

    /// 获取鼠标按键事件（如果有）
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
                .button = std.meta.intToEnum(MouseButton, button) catch .other,
                .pressed = pressed != 0,
                .modifiers = mods,
            };
        }
        return null;
    }

    /// 查询窗口是否应该关闭
    pub fn shouldClose(self: *MacOSWindow) bool {
        return macos_should_close(self.window_ptr) != 0;
    }

    /// 更新鼠标位置（给不调 pollEvents 的窗口用）
    pub fn updateMousePosition(self: *MacOSWindow) void {
        macos_update_mouse_position(self.window_ptr);
    }

    /// 设置非活跃窗口是否接受鼠标移动（inspector pick 模式跨窗口 hover）
    pub fn setAcceptsMouseWhileInactive(self: *MacOSWindow, accepts: bool) void {
        macos_set_accepts_mouse_while_inactive(self.window_ptr, if (accepts) 1 else 0);
    }

    /// 检查窗口是否需要渲染（可见且未被完全遮挡）
    pub fn shouldRender(self: *MacOSWindow) bool {
        return macos_should_render_window(self.window_ptr) != 0;
    }

    /// 获取系统标题栏高度（traffic lights 区域高度，通常 28-38px）
    pub fn getTitlebarHeight(self: *MacOSWindow) f32 {
        return macos_get_titlebar_height(self.window_ptr);
    }

    /// 开始窗口拖拽（在自绘 TitleBar 的 mouseDown 中调用）
    pub fn performWindowDrag(self: *MacOSWindow) void {
        macos_perform_window_drag(self.window_ptr);
    }

    /// 设置 traffic lights（红黄绿按钮）在自绘标题栏中的位置
    /// inset_x: 第一个按钮左边距, inset_y: 按钮中心距窗口顶部的距离
    pub fn setTrafficLightsInset(self: *MacOSWindow, inset_x: f32, inset_y: f32) void {
        macos_set_traffic_lights_inset(self.window_ptr, inset_x, inset_y);
    }

    /// 设置自定义 TitleBar 拖拽区域高度（逻辑像素，从窗口顶部算起）
    /// 设为 > 0 后，mouseDown 落在此区域内会自动触发窗口拖拽
    /// 命中驱动拖拽区：拖拽带内 mouseDown 先经回调判定该点是否落在交互控件上
    /// （非 0 = 是，事件正常下发不拖窗口）。传 null 清除，退回纯矩形模型。
    pub fn setTitlebarHitCallback(self: *MacOSWindow, cb: ?*const fn (?*anyopaque, f32, f32) callconv(.c) c_int, ctx: ?*anyopaque) void {
        macos_set_titlebar_hit_callback(self.window_ptr, cb, ctx);
    }

    pub fn setTitlebarDragHeight(self: *MacOSWindow, height: f32) void {
        macos_set_titlebar_drag_height(self.window_ptr, height);
    }

    /// 设置 TitleBar 右侧排除拖拽区域宽度（逻辑像素）。
    /// 用于让 titlebar 右侧的 action buttons 正常接收 click，
    /// 而不是被窗口拖拽吞掉。
    pub fn setTitlebarDragRightInset(self: *MacOSWindow, inset: f32) void {
        macos_set_titlebar_drag_right_inset(self.window_ptr, inset);
    }

    /// 获取 macOS openFile 事件的 pending 路径（Finder 双击 / open -a）
    /// 返回的 slice 指向 caller 提供的 buffer；null = 队列为空。
    /// buffer 放不下完整路径时返回 error.BufferTooSmall 且**不出队**（路径留在
    /// 队首，换更大的 buffer 重试即可）；所需大小见 `pendingOpenFileRequiredSize`。
    /// 此前会先出队再按 buffer 截断路径 —— 文件被静默丢弃或打开错误路径。
    pub fn getPendingOpenFile(self: *MacOSWindow, buf: []u8) error{BufferTooSmall}!?[]const u8 {
        _ = self; // polling 不需要 window 参数，但保持 API 一致
        const size: c_int = @intCast(@min(buf.len, std.math.maxInt(c_int)));
        const len = macos_get_pending_open_file(buf.ptr, size);
        if (len < 0) return error.BufferTooSmall;
        if (len == 0) return null;
        return buf[0..@intCast(len)];
    }

    /// 队首 pending 路径所需的 buffer 字节数（含 NUL）；队列为空返回 null。
    pub fn pendingOpenFileRequiredSize(self: *MacOSWindow) ?usize {
        _ = self;
        const rc = macos_get_pending_open_file(null, 0);
        if (rc >= 0) return null;
        return @intCast(-@as(i64, rc));
    }

    // ========== 多窗口架构 API ==========

    /// 纯事件泵：拉取所有 NSApp 事件，分发到各 WindowWrapper
    /// 不绑定任何特定窗口（静态方法）
    pub fn pumpAppEvents() void {
        macos_pump_app_events();
    }

    pub fn pumpAppEventsTimeout(timeout_ms: u32) void {
        macos_pump_app_events_timeout(timeout_ms);
    }

    /// 检查全局退出标志（Cmd+Q 或 terminate:）
    pub fn appShouldQuit() bool {
        return macos_should_quit() != 0;
    }

    /// 消费"app 变为前台"标志：返回 true 且内部重置（每次激活只返回一次 true）
    pub fn consumeAppBecameActive() bool {
        return macos_consume_app_became_active() != 0;
    }

    /// 查询当前系统是否为暗色模式
    pub fn isDarkMode() bool {
        return macos_is_dark_mode() != 0;
    }

    /// 检查此窗口是否请求关闭（Cmd+W 或 windowShouldClose:）
    pub fn checkShouldClose(self: *MacOSWindow) bool {
        return macos_check_window_should_close(self.window_ptr) != 0;
    }

    /// 重置窗口关闭请求标志
    pub fn resetShouldClose(self: *MacOSWindow) void {
        macos_reset_window_should_close(self.window_ptr);
    }

    /// 更新此窗口的鼠标位置（多窗口模式下每窗口独立调用）
    pub fn updateWindowMouse(self: *MacOSWindow) void {
        macos_update_window_mouse(self.window_ptr);
    }

    pub fn isFocused(self: *MacOSWindow) bool {
        return macos_is_window_focused(self.window_ptr) != 0;
    }

    /// 菜单动作枚举（与 ObjC 侧 MenuActionType 一一对应）
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
        return .{ .native_window_id = window_id, .action = std.meta.intToEnum(MenuAction, action) catch return null };
    }

    /// 消费下一个菜单动作（全局，不绑定窗口）
    pub fn getMenuAction() ?MenuAction {
        const raw = macos_get_menu_action();
        if (raw == 0) return null;
        return std.meta.intToEnum(MenuAction, raw) catch null;
    }
};
