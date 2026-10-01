const std = @import("std");

/// Unsupported platform window stub.
///
/// 用于让非 macOS 目标先具备可编译的平台接口层，
/// 后续可替换为真正的平台实现。
pub const UnsupportedWindow = struct {
    width: u32 = 0,
    height: u32 = 0,

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
            _ = raw;
            return .{};
        }
    };

    pub const KeyEvent = struct {
        keycode: u16,
        modifiers: Modifiers,
        character: ?u8,
    };

    pub const KeyCode = struct {
        pub const RETURN: u16 = 36;
        pub const TAB: u16 = 48;
        pub const SPACE: u16 = 49;
        pub const DELETE: u16 = 51;
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

    pub const ScrollEvent = struct {
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        phase: u8,
        momentum: u8,
    };

    /// IME replacementRange 哨兵：与 macos 平台保持同一 API 形状。
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
    };

    pub const MouseMoveEvent = struct {
        sequence: u64,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        modifiers: Modifiers,
    };

    pub const InputQueueMetrics = struct {
        mouse_move_coalesced: u64,
        ime_preedit_coalesced: u64,
    };

    pub fn initAppWithDelegate() void {}

    pub fn showBlockingAlert(title: [:0]const u8, message: [:0]const u8) void {
        _ = title;
        _ = message;
    }

    pub fn init(width: u32, height: u32, title: [:0]const u8) !UnsupportedWindow {
        _ = width;
        _ = height;
        _ = title;
        return error.NotSupported;
    }

    pub fn deinit(self: *UnsupportedWindow) void {
        _ = self;
    }

    pub fn beginClose(self: *UnsupportedWindow) bool {
        _ = self;
        return true;
    }

    pub fn closeCompleted(self: *const UnsupportedWindow) bool {
        _ = self;
        return true;
    }

    pub fn pollEvents(self: *UnsupportedWindow) bool {
        _ = self;
        return false;
    }

    pub fn getSize(self: *UnsupportedWindow) [2]u32 {
        return .{ self.width, self.height };
    }

    pub fn setSize(self: *UnsupportedWindow, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }

    pub fn getScaleFactor(self: *UnsupportedWindow) f32 {
        _ = self;
        return 1.0;
    }

    /// 无真实显示器，返回标称 60Hz（与 Cx.display_refresh_hz 默认值一致）。
    pub fn getDisplayRefreshRate(self: *UnsupportedWindow) f32 {
        _ = self;
        return 60.0;
    }

    /// 无平台窗口，返 1，保持"单窗口"语义，不是 0（0 是 a11y 的通配键）。
    pub fn getWindowId(self: *UnsupportedWindow) u32 {
        _ = self;
        return 1;
    }

    fn unsupportedRecordingState() WindowRecordingState {
        var state: WindowRecordingState = .{};
        const message = "window recording is only supported on macOS";
        @memcpy(state.error_message[0..message.len], message);
        return state;
    }

    pub fn startWindowRecording(self: *UnsupportedWindow, path: []const u8, fps: u32) WindowRecordingState {
        _ = self;
        _ = path;
        _ = fps;
        return unsupportedRecordingState();
    }

    pub fn windowRecordingStatus(self: *UnsupportedWindow) WindowRecordingState {
        _ = self;
        return unsupportedRecordingState();
    }

    pub fn appendWindowRecordingFrame(self: *UnsupportedWindow, texture: *anyopaque) bool {
        _ = self;
        _ = texture;
        return false;
    }

    pub fn stopWindowRecording(self: *UnsupportedWindow) WindowRecordingState {
        _ = self;
        return unsupportedRecordingState();
    }

    pub fn liveWindowCount() u32 {
        return 0;
    }

    pub fn getDrawableSize(self: *UnsupportedWindow) [2]u32 {
        return .{ self.width, self.height };
    }

    pub fn getNativeSurfaceHandle(self: *UnsupportedWindow) *anyopaque {
        _ = self;
        @panic("Unsupported platform: getNativeSurfaceHandle");
    }

    pub fn getNativeDeviceHandle(self: *UnsupportedWindow) *anyopaque {
        _ = self;
        @panic("Unsupported platform: getNativeDeviceHandle");
    }

    pub fn setRenderCallback(
        self: *UnsupportedWindow,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        ctx: ?*anyopaque,
    ) void {
        _ = self;
        _ = callback;
        _ = ctx;
    }

    pub fn requestRedraw(self: *UnsupportedWindow) void {
        _ = self;
    }

    pub fn isInLiveResize(self: *UnsupportedWindow) bool {
        _ = self;
        return false;
    }

    pub fn getMousePosition(self: *UnsupportedWindow) [2]f32 {
        _ = self;
        return .{ 0, 0 };
    }

    pub fn getMouseMoveEvent(self: *UnsupportedWindow) ?MouseMoveEvent {
        _ = self;
        return null;
    }

    pub fn inputQueueMetrics() InputQueueMetrics {
        return .{ .mouse_move_coalesced = 0, .ime_preedit_coalesced = 0 };
    }

    pub fn isMouseButtonPressed(self: *UnsupportedWindow, button: MouseButton) bool {
        _ = self;
        _ = button;
        return false;
    }

    pub fn getKeyEvent(self: *UnsupportedWindow) ?KeyEvent {
        _ = self;
        return null;
    }

    pub fn getInputText(self: *UnsupportedWindow, buffer: []u8) ?TextInputEvent {
        _ = self;
        _ = buffer;
        return null;
    }

    pub fn getImePreedit(self: *UnsupportedWindow, buffer: []u8) ?ImePreeditEvent {
        _ = self;
        _ = buffer;
        return null;
    }

    pub fn getImeCommit(self: *UnsupportedWindow, buffer: []u8) ?ImeCommitEvent {
        _ = self;
        _ = buffer;
        return null;
    }

    pub fn setImeCursorRect(self: *UnsupportedWindow, x: f32, y: f32, w: f32, h: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
    }

    pub fn setCursorShape(self: *UnsupportedWindow, shape: u8) void {
        _ = self;
        _ = shape;
    }

    pub fn activate(self: *UnsupportedWindow) void {
        _ = self;
    }

    pub fn getScrollDelta(self: *UnsupportedWindow) ?ScrollEvent {
        _ = self;
        return null;
    }

    pub fn getMouseButtonEvent(self: *UnsupportedWindow) ?MouseButtonEvent {
        _ = self;
        return null;
    }

    pub fn shouldClose(self: *UnsupportedWindow) bool {
        _ = self;
        return false;
    }

    pub fn updateMousePosition(self: *UnsupportedWindow) void {
        _ = self;
    }

    pub fn setAcceptsMouseWhileInactive(self: *UnsupportedWindow, accepts: bool) void {
        _ = self;
        _ = accepts;
    }

    pub fn shouldRender(self: *UnsupportedWindow) bool {
        _ = self;
        return true;
    }

    pub fn getTitlebarHeight(self: *UnsupportedWindow) f32 {
        _ = self;
        return 0;
    }

    pub fn performWindowDrag(self: *UnsupportedWindow) void {
        _ = self;
    }

    pub fn setTrafficLightsInset(self: *UnsupportedWindow, inset_x: f32, inset_y: f32) void {
        _ = self;
        _ = inset_x;
        _ = inset_y;
    }

    pub fn setTitlebarDragHeight(self: *UnsupportedWindow, height: f32) void {
        _ = self;
        _ = height;
    }

    pub fn setTitlebarDragRightInset(self: *UnsupportedWindow, inset: f32) void {
        _ = self;
        _ = inset;
    }

    pub fn getPendingOpenFile(self: *UnsupportedWindow, buf: []u8) error{BufferTooSmall}!?[]const u8 {
        _ = self;
        _ = buf;
        return null;
    }

    pub fn pendingOpenFileRequiredSize(self: *UnsupportedWindow) ?usize {
        _ = self;
        return null;
    }

    pub fn pumpAppEvents() void {}

    pub fn appShouldQuit() bool {
        return false;
    }

    pub fn checkShouldClose(self: *UnsupportedWindow) bool {
        _ = self;
        return false;
    }

    pub fn resetShouldClose(self: *UnsupportedWindow) void {
        _ = self;
    }

    pub fn updateWindowMouse(self: *UnsupportedWindow) void {
        _ = self;
    }

    pub fn isFocused(self: *UnsupportedWindow) bool {
        _ = self;
        return false;
    }

    /// 菜单动作枚举（与 macOS 侧一致）
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

test "UnsupportedWindow defaults" {
    var win = UnsupportedWindow{ .width = 640, .height = 480 };
    try std.testing.expectEqual(@as(bool, false), win.pollEvents());
    try std.testing.expectEqual(@as([2]u32, .{ 640, 480 }), win.getSize());
    try std.testing.expectEqual(@as([2]u32, .{ 640, 480 }), win.getDrawableSize());
    try std.testing.expectEqual(@as(f32, 1.0), win.getScaleFactor());
    try std.testing.expectEqual(@as(?UnsupportedWindow.KeyEvent, null), win.getKeyEvent());
    try std.testing.expectEqualStrings("", win.getInputText(&[_]u8{}));
}
