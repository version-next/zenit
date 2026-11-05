const std = @import("std");
const Allocator = std.mem.Allocator;

const backend_mod = @import("../vtable.zig");
const capabilities_mod = @import("../capabilities.zig");
const events_mod = @import("../events.zig");
const WindowId = @import("../events.zig").WindowId;
const SystemSdk = @import("../api.zig").SystemSdk;
const SdkError = @import("../errors.zig").SdkError;
const NativeClipboardPng = extern struct { rgba: ?[*]u8 = null, width: u32 = 0, height: u32 = 0 };
extern fn zenit_wayland_decode_png([*]const u8, usize, *NativeClipboardPng) c_int;
extern fn zenit_wayland_free_png(*NativeClipboardPng) void;

const CAPS = capabilities_mod.Capabilities{
    .request_redraw = true,
    .multi_window = false,
};

/// Linux window event adapter. Wayland windows expose an ordered native input
/// ring for pointer transitions, evdev keys and owned UTF-8 commits. Fixed
/// cursors are advertised only after runtime negotiation succeeds. The minimal
/// polling branch remains available for window mocks. Clipboard capability follows
/// data-device negotiation; IME follows text-input-v3 negotiation.
pub const LinuxBackend = struct {
    pub fn initSystemSdk(allocator: Allocator, window: anytype, window_id: WindowId) !SystemSdk {
        const WindowType = @TypeOf(window);
        const WindowChild = @typeInfo(WindowType).pointer.child;
        const has_clipboard = @hasDecl(WindowChild, "clipboardAvailable") and @hasDecl(WindowChild, "clipboardSetText") and @hasDecl(WindowChild, "clipboardGetText") and @hasDecl(WindowChild, "clipboardGetTextLen");
        const has_image = has_clipboard and @hasDecl(WindowChild, "clipboardSetImagePng") and @hasDecl(WindowChild, "clipboardProbe") and @hasDecl(WindowChild, "clipboardGetImagePngLen") and @hasDecl(WindowChild, "clipboardGetImagePng");
        const has_cursor = @hasDecl(WindowChild, "cursorAvailable") and @hasDecl(WindowChild, "setCursorShapeChecked");
        const has_ime = @hasDecl(WindowChild, "imeAvailable") and @hasDecl(WindowChild, "imeSetEnabled") and @hasDecl(WindowChild, "imeDiscard") and @hasDecl(WindowChild, "imeSetCursorRect") and @hasDecl(WindowChild, "imeSetSurrounding");

        const Impl = struct {
            const Context = struct {
                window: WindowType,
                window_id: WindowId,
                ime_generation: u64 = 1,
                last_width: u32,
                last_height: u32,
                last_scale: f32,
                has_last_mouse: bool = false,
                last_mouse_x: f32,
                last_mouse_y: f32,
                last_focused: bool = false,
            };

            fn deinitImpl(ctx: *anyopaque, allocator_: Allocator) void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                allocator_.destroy(self);
            }

            fn requestRedrawImpl(ctx: *anyopaque) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                self.window.requestRedraw();
            }

            fn pumpEventsImpl(ctx: *anyopaque, queue: *events_mod.EventQueue, timeout_ms: u32) SdkError!backend_mod.PumpResult {
                const self: *Context = @ptrCast(@alignCast(ctx));

                const should_continue = if (comptime @hasDecl(@typeInfo(WindowType).pointer.child, "pollEventsWithTimeout")) self.window.pollEventsWithTimeout(timeout_ms) else self.window.pollEvents();

                const size = self.window.getSize();
                const scale = self.window.getScaleFactor();
                if (size[0] != self.last_width or size[1] != self.last_height or scale != self.last_scale) {
                    try pushEvent(queue, .{
                        .window_resized = .{
                            .window_id = self.window_id,
                            .width = size[0],
                            .height = size[1],
                            .scale_factor = scale,
                        },
                    });
                    self.last_width = size[0];
                    self.last_height = size[1];
                    self.last_scale = scale;
                }

                const pos = self.window.getMousePosition();
                const mx = pos[0];
                const my = pos[1];
                if (comptime !@hasDecl(@typeInfo(WindowType).pointer.child, "peekInputEvent")) {
                    if (!self.has_last_mouse or mx != self.last_mouse_x or my != self.last_mouse_y) {
                        try pushEvent(queue, .{
                            .mouse_move = .{
                                .window_id = self.window_id,
                                .x = mx,
                                .y = my,
                                .dx = if (self.has_last_mouse) mx - self.last_mouse_x else 0,
                                .dy = if (self.has_last_mouse) my - self.last_mouse_y else 0,
                            },
                        });
                        self.last_mouse_x = mx;
                        self.last_mouse_y = my;
                        self.has_last_mouse = true;
                    }
                }
                const focused = self.window.isFocused();
                if (focused != self.last_focused) {
                    try pushEvent(queue, .{ .window_focused = .{ .window_id = self.window_id, .focused = focused } });
                    self.last_focused = focused;
                }
                if (comptime @hasDecl(@typeInfo(WindowType).pointer.child, "peekInputEvent")) {
                    while (self.window.peekInputEvent()) |native| {
                        const mods: events_mod.Modifiers = .{ .shift = native.modifiers & 1 != 0, .ctrl = native.modifiers & 2 != 0, .alt = native.modifiers & 4 != 0, .super = native.modifiers & 8 != 0 };
                        // Push (including owned UTF-8 allocation) before consuming
                        // the native head. OOM leaves the event available to retry.
                        switch (native.kind) {
                            1 => try pushEvent(queue, .{ .mouse_button = .{ .window_id = self.window_id, .x = native.x, .y = native.y, .button = switch (native.button) {
                                0 => .left,
                                1 => .right,
                                2 => .middle,
                                else => .other,
                            }, .pressed = native.pressed != 0, .cancelled = native.cancelled != 0, .modifiers = mods } }),
                            2 => try pushEvent(queue, .{ .key = .{ .window_id = self.window_id, .keycode = @intCast(native.keycode), .pressed = native.pressed != 0, .modifiers = mods } }),
                            3 => try pushEvent(queue, .{ .text_input = .{ .window_id = self.window_id, .text = native.text[0..native.text_length] } }),
                            4 => {
                                try pushEvent(queue, .{ .mouse_move = .{ .window_id = self.window_id, .x = native.x, .y = native.y, .dx = if (self.has_last_mouse) native.x - self.last_mouse_x else 0, .dy = if (self.has_last_mouse) native.y - self.last_mouse_y else 0, .modifiers = mods } });
                                self.last_mouse_x = native.x;
                                self.last_mouse_y = native.y;
                                self.has_last_mouse = true;
                            },
                            5 => try pushEvent(queue, .{ .mouse_wheel = .{ .window_id = self.window_id, .x = native.x, .y = native.y, .dx = native.dx, .dy = native.dy, .phase = if (comptime @hasField(@TypeOf(native), "scroll_phase")) switch (native.scroll_phase) {
                                2 => .began,
                                3 => .changed,
                                4 => .ended,
                                5 => .cancelled,
                                else => .none,
                            } else .none, .modifiers = mods } }),
                            6 => if (comptime has_ime) {
                                const text = if (native.owned_text) |ptr| ptr[0..native.text_length] else "";
                                if (text.len != native.text_length or !std.unicode.utf8ValidateSlice(text)) return error.BackendFailure;
                                try pushEvent(queue, .{ .ime_preedit = .{ .window_id = self.window_id, .generation = self.ime_generation, .text = text, .cursor_utf8_offset = @intCast(@max(0, native.cursor_begin)), .selection_end_utf8 = if (native.cursor_end < 0) null else @intCast(native.cursor_end), .cursor_visible = native.cursor_begin >= 0 } });
                            } else return error.BackendFailure,
                            7 => if (comptime has_ime) {
                                const text = if (native.owned_text) |ptr| ptr[0..native.text_length] else "";
                                if (text.len != native.text_length or !std.unicode.utf8ValidateSlice(text)) return error.BackendFailure;
                                try pushEvent(queue, .{ .ime_commit = .{ .window_id = self.window_id, .generation = self.ime_generation, .text = text } });
                            } else return error.BackendFailure,
                            8 => if (comptime has_ime) {
                                try pushEvent(queue, .{ .ime_delete_surrounding = .{ .window_id = self.window_id, .generation = self.ime_generation, .before_bytes = native.delete_before, .after_bytes = native.delete_after } });
                            } else return error.BackendFailure,
                            // wl_pointer.leave on the content surface.
                            9 => try pushEvent(queue, .{ .pointer_left = .{ .window_id = self.window_id } }),
                            else => return error.BackendFailure,
                        }
                        _ = self.window.popInputEvent();
                    }
                } else {
                    while (true) {
                        // Reserve before consuming a native transition, so OOM
                        // cannot silently consume a button release/cancellation.
                        try queue.list.ensureUnusedCapacity(queue.allocator, 1);
                        const button = self.window.getMouseButtonEvent() orelse break;
                        try pushEvent(queue, .{ .mouse_button = .{
                            .window_id = self.window_id,
                            .x = button.x,
                            .y = button.y,
                            .button = switch (button.button) {
                                .left => .left,
                                .right => .right,
                                .middle => .middle,
                            },
                            .pressed = button.pressed,
                            .cancelled = if (comptime @hasField(@TypeOf(button), "cancelled")) button.cancelled else false,
                        } });
                    }
                    try queue.list.ensureUnusedCapacity(queue.allocator, 1);
                    if (self.window.getScrollDelta()) |scroll| {
                        try pushEvent(queue, .{ .mouse_wheel = .{ .window_id = self.window_id, .x = scroll.x, .y = scroll.y, .dx = scroll.dx, .dy = scroll.dy } });
                    }
                }

                if (comptime @hasDecl(@typeInfo(WindowType).pointer.child, "checkShouldClose")) {
                    if (should_continue and self.window.checkShouldClose())
                        try pushEvent(queue, .{ .window_close_requested = .{ .window_id = self.window_id } });
                }
                if (!should_continue) {
                    try pushEvent(queue, .{ .quit = {} });
                }

                return .{
                    .should_continue = should_continue,
                };
            }

            fn cursorSetShapeImpl(ctx: *anyopaque, id: WindowId, shape: u8) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id or shape > 20) return SdkError.InvalidState;
                if (shape == 19) return SdkError.NotSupported;
                if (!self.window.setCursorShapeChecked(shape)) return SdkError.BackendFailure;
            }

            fn clipboardSetImpl(ctx: *anyopaque, value: []const u8) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidState;
                _ = try clipboardResult(self.window.clipboardSetText(value));
            }
            fn clipboardLenImpl(ctx: *anyopaque) SdkError!usize {
                const self: *Context = @ptrCast(@alignCast(ctx));
                return clipboardResult(self.window.clipboardGetTextLen());
            }
            fn clipboardGetImpl(ctx: *anyopaque, buffer: []u8) SdkError![]const u8 {
                const self: *Context = @ptrCast(@alignCast(ctx));
                const length = try clipboardResult(self.window.clipboardGetText(buffer));
                if (length > buffer.len) return error.BackendFailure;
                if (!std.unicode.utf8ValidateSlice(buffer[0..length])) return error.BackendFailure;
                return buffer[0..length];
            }

            fn imeGeneration(ctx: *anyopaque) u64 {
                const self: *Context = @ptrCast(@alignCast(ctx));
                return self.ime_generation;
            }
            fn clipboardProbeImpl(ctx: *anyopaque) u32 {
                const self: *Context = @ptrCast(@alignCast(ctx));
                return self.window.clipboardProbe();
            }
            fn clipboardImageCountImpl(ctx: *anyopaque) usize {
                return if (clipboardProbeImpl(ctx) & 2 != 0) 1 else 0;
            }
            fn clipboardSetImageImpl(ctx: *anyopaque, bytes: []const u8) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                _ = try clipboardResult(self.window.clipboardSetImagePng(bytes));
            }
            fn clipboardGetImageImpl(ctx: *anyopaque, alloc: Allocator, index: usize) SdkError!?backend_mod.ClipboardImage {
                if (index != 0) return null;
                const self: *Context = @ptrCast(@alignCast(ctx));
                const length = try clipboardResult(self.window.clipboardGetImagePngLen());
                if (length == 0) return null;
                if (length > 16 * 1024 * 1024) return error.BackendFailure;
                const raw = alloc.alloc(u8, length) catch return error.OutOfMemory;
                errdefer alloc.free(raw);
                const actual = try clipboardResult(self.window.clipboardGetImagePng(raw));
                if (actual != length) return error.BackendFailure;
                var image: NativeClipboardPng = .{};
                defer zenit_wayland_free_png(&image);
                _ = try clipboardResult(zenit_wayland_decode_png(raw.ptr, raw.len, &image));
                const source = image.rgba orelse return error.BackendFailure;
                if (image.width == 0 or image.height == 0 or image.width > 4096 or image.height > 4096) return error.BackendFailure;
                const rgba = alloc.dupe(u8, source[0 .. @as(usize, image.width) * image.height * 4]) catch return error.OutOfMemory;
                errdefer alloc.free(rgba);
                const uti = alloc.dupe(u8, "public.png") catch return error.OutOfMemory;
                return .{ .width = image.width, .height = image.height, .rgba = rgba, .raw_bytes = raw, .uti = uti };
            }
            fn imeEnable(ctx: *anyopaque, id: WindowId, enabled: bool) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id) return error.InvalidState;
                _ = try clipboardResult(self.window.imeSetEnabled(enabled));
                self.ime_generation +%= 1;
            }
            fn imeDiscard(ctx: *anyopaque, id: WindowId) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id) return error.InvalidState;
                _ = try clipboardResult(self.window.imeDiscard());
                self.ime_generation +%= 1;
            }
            fn imeRect(ctx: *anyopaque, id: WindowId, x: f32, y: f32, w: f32, h: f32) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id) return error.InvalidState;
                _ = try clipboardResult(self.window.imeSetCursorRect(x, y, w, h));
            }
            fn imeSurrounding(ctx: *anyopaque, id: WindowId, text: []const u8, cursor: u32, anchor: u32, secure: bool) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id or !std.unicode.utf8ValidateSlice(text)) return error.InvalidState;
                _ = try clipboardResult(self.window.imeSetSurrounding(text, cursor, anchor, secure));
            }

            pub const VTABLE = backend_mod.BackendVTable{
                .name = if (@hasDecl(WindowChild, "peekInputEvent")) "linux-wayland" else "linux-minimal",
                .deinit = deinitImpl,
                .pump_events = pumpEventsImpl,
                .request_redraw = requestRedrawImpl,
                .clipboard = if (has_clipboard) .{ .set_text = clipboardSetImpl, .get_text = clipboardGetImpl, .get_text_len = clipboardLenImpl, .probe = if (has_image) clipboardProbeImpl else null, .image_count = if (has_image) clipboardImageCountImpl else null, .get_image = if (has_image) clipboardGetImageImpl else null, .set_image_png = if (has_image) clipboardSetImageImpl else null } else null,
                .ime = if (has_ime) .{ .set_enabled = imeEnable, .set_cursor_rect = imeRect, .discard = imeDiscard, .set_surrounding = imeSurrounding, .generation = imeGeneration } else null,
                .cursor = if (has_cursor) .{ .set_shape = cursorSetShapeImpl } else null,
            };
        };

        const size = window.getSize();
        const scale = window.getScaleFactor();
        const mouse = window.getMousePosition();

        const ctx = try allocator.create(Impl.Context);
        ctx.* = .{
            .window = window,
            .window_id = window_id,
            .last_width = size[0],
            .last_height = size[1],
            .last_scale = scale,
            .last_mouse_x = mouse[0],
            .last_mouse_y = mouse[1],
            .has_last_mouse = true,
        };

        var caps = CAPS;
        if (comptime has_clipboard) caps.clipboard = window.clipboardAvailable();
        if (comptime has_image) caps.clipboard_image = window.clipboardAvailable();
        if (comptime has_ime) caps.ime = window.imeAvailable();
        if (comptime has_cursor) caps.cursor = window.cursorAvailable();
        return SystemSdk.init(allocator, ctx, &Impl.VTABLE, caps);
    }
};

fn clipboardResult(result: c_int) SdkError!usize {
    if (result >= 0) return @intCast(result);
    return switch (result) {
        -2 => error.BufferTooSmall,
        -3 => error.Unavailable,
        -4 => error.OutOfMemory,
        -5 => error.Timeout,
        -6 => error.InvalidState,
        -7 => error.WrongThread,
        else => error.BackendFailure,
    };
}

fn pushEvent(queue: *events_mod.EventQueue, event: events_mod.Event) SdkError!void {
    queue.push(event) catch return SdkError.OutOfMemory;
}

const MockWindow = struct {
    clipboard_available: bool = false,
    clipboard_bytes: [128]u8 = @splat(0),
    clipboard_length: usize = 0,
    clipboard_status: c_int = 0,
    frame: u32 = 0,
    redraw_requests: u32 = 0,
    focused: bool = false,
    cursor_available: bool = false,
    cursor_calls: u32 = 0,
    cursor_shape: u8 = 0,
    button_pending: u8 = 0,
    scroll_pending: bool = false,
    pub fn clipboardAvailable(self: *MockWindow) bool {
        return self.clipboard_available;
    }
    pub fn clipboardSetText(self: *MockWindow, value: []const u8) c_int {
        if (self.clipboard_status < 0) return self.clipboard_status;
        if (value.len > self.clipboard_bytes.len) return -2;
        @memcpy(self.clipboard_bytes[0..value.len], value);
        self.clipboard_length = value.len;
        return 0;
    }
    pub fn clipboardGetTextLen(self: *MockWindow) c_int {
        return if (self.clipboard_status < 0) self.clipboard_status else @intCast(self.clipboard_length);
    }
    pub fn clipboardGetText(self: *MockWindow, buffer: []u8) c_int {
        if (self.clipboard_status < 0) return self.clipboard_status;
        if (self.clipboard_length > buffer.len) return -2;
        @memcpy(buffer[0..self.clipboard_length], self.clipboard_bytes[0..self.clipboard_length]);
        return @intCast(self.clipboard_length);
    }
    pub fn cursorAvailable(self: *MockWindow) bool {
        return self.cursor_available;
    }
    pub fn setCursorShapeChecked(self: *MockWindow, shape: u8) bool {
        if (!self.cursor_available) return false;
        self.cursor_calls += 1;
        self.cursor_shape = shape;
        return true;
    }
    const Button = struct { x: f32 = 10, y: f32 = 10, button: enum { left, right, middle } = .left, pressed: bool, cancelled: bool = false };
    pub fn isFocused(self: *MockWindow) bool {
        return self.focused;
    }
    pub fn getMouseButtonEvent(self: *MockWindow) ?Button {
        if (self.button_pending == 0) return null;
        self.button_pending -= 1;
        return .{ .pressed = self.button_pending == 1 };
    }
    pub fn getScrollDelta(self: *MockWindow) ?struct { x: f32, y: f32, dx: f32, dy: f32 } {
        if (!self.scroll_pending) return null;
        self.scroll_pending = false;
        return .{ .x = 10, .y = 10, .dx = 2, .dy = 3 };
    }

    pub fn pollEvents(self: *MockWindow) bool {
        self.frame += 1;
        return self.frame < 3;
    }

    pub fn getSize(self: *MockWindow) [2]u32 {
        return if (self.frame >= 2) .{ 900, 700 } else .{ 800, 600 };
    }

    pub fn getScaleFactor(_: *MockWindow) f32 {
        return 1.0;
    }

    pub fn getMousePosition(self: *MockWindow) [2]f32 {
        return switch (self.frame) {
            0 => .{ 10, 10 },
            1 => .{ 10, 10 },
            else => .{ 12, 15 },
        };
    }

    pub fn requestRedraw(self: *MockWindow) void {
        self.redraw_requests += 1;
    }
};

test "LinuxBackend preserves click transitions and consumes scroll once" {
    var window: MockWindow = .{};
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &window, 9);
    defer sdk.deinit();
    window.focused = true;
    window.button_pending = 2;
    window.scroll_pending = true;
    _ = try sdk.pump(0);
    const events = sdk.events();
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expect(events[0].window_focused.focused);
    try std.testing.expect(events[1].mouse_button.pressed);
    try std.testing.expect(!events[2].mouse_button.pressed);
    try std.testing.expectEqual(events_mod.MouseButton.left, events[2].mouse_button.button);
    try std.testing.expectEqual(@as(f32, 3), events[3].mouse_wheel.dy);
    _ = try sdk.pump(0);
    for (sdk.events()) |event| try std.testing.expect(event != .mouse_button and event != .mouse_wheel);
}

test "LinuxBackend minimal: pump events + redraw" {
    var win = MockWindow{};
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();

    try sdk.requestRedraw();
    try std.testing.expectEqual(@as(u32, 1), win.redraw_requests);

    const p1 = try sdk.pump(0);
    try std.testing.expect(p1.should_continue);
    try std.testing.expectEqual(@as(usize, 0), sdk.events().len);

    const p2 = try sdk.pump(0);
    try std.testing.expect(p2.should_continue);
    try std.testing.expectEqual(@as(usize, 2), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .window_resized);
    try std.testing.expect(sdk.events()[1] == .mouse_move);

    const p3 = try sdk.pump(0);
    try std.testing.expect(!p3.should_continue);
    try std.testing.expectEqual(@as(usize, 1), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .quit);
}

const OrderedMockWindow = struct {
    const NativeEvent = struct {
        kind: u32 = 0,
        keycode: u32 = 0,
        modifiers: u32 = 0,
        button: u32 = 0,
        pressed: u32 = 0,
        cancelled: u32 = 0,
        text_length: u32 = 0,
        x: f32 = 0,
        y: f32 = 0,
        dx: f32 = 0,
        dy: f32 = 0,
        text: [64]u8 = @splat(0),
        owned_text: ?[*]u8 = null,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,
        delete_before: u32 = 0,
        delete_after: u32 = 0,
        scroll_phase: u32 = 0,
    };
    ime_available: bool = false,
    ime_result: c_int = 0,
    inputs: [4]NativeEvent = @splat(.{}),
    count: usize = 0,
    head: usize = 0,
    pub fn imeAvailable(self: *OrderedMockWindow) bool {
        return self.ime_available;
    }
    pub fn imeSetEnabled(self: *OrderedMockWindow, _: bool) c_int {
        return self.ime_result;
    }
    pub fn imeDiscard(self: *OrderedMockWindow) c_int {
        return self.ime_result;
    }
    pub fn imeSetCursorRect(self: *OrderedMockWindow, _: f32, _: f32, _: f32, _: f32) c_int {
        return self.ime_result;
    }
    pub fn imeSetSurrounding(self: *OrderedMockWindow, _: []const u8, _: u32, _: u32, _: bool) c_int {
        return self.ime_result;
    }
    pub fn pollEvents(_: *OrderedMockWindow) bool {
        return true;
    }
    pub fn getSize(_: *OrderedMockWindow) [2]u32 {
        return .{ 800, 600 };
    }
    pub fn getScaleFactor(_: *OrderedMockWindow) f32 {
        return 1;
    }
    pub fn getMousePosition(_: *OrderedMockWindow) [2]f32 {
        return .{ 0, 0 };
    }
    pub fn isFocused(_: *OrderedMockWindow) bool {
        return false;
    }
    pub fn requestRedraw(_: *OrderedMockWindow) void {}
    pub fn peekInputEvent(self: *OrderedMockWindow) ?NativeEvent {
        return if (self.head < self.count) self.inputs[self.head] else null;
    }
    pub fn popInputEvent(self: *OrderedMockWindow) ?NativeEvent {
        const event = self.peekInputEvent() orelse return null;
        @memset(&self.inputs[self.head].text, 'x');
        if (event.owned_text) |ptr| @memset(ptr[0..event.text_length], 'x');
        self.head += 1;
        return event;
    }
};

test "LinuxBackend preserves native click key text release order and owns text" {
    var win: OrderedMockWindow = .{ .count = 4 };
    win.inputs[0] = .{ .kind = 1, .pressed = 1, .x = 12, .y = 13 };
    win.inputs[1] = .{ .kind = 2, .keycode = 30, .pressed = 1, .modifiers = 1 };
    win.inputs[2] = .{ .kind = 3, .text_length = 2 };
    @memcpy(win.inputs[2].text[0..2], "é");
    win.inputs[3] = .{ .kind = 2, .keycode = 30, .pressed = 0 };
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    const events = sdk.events();
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expect(events[0].mouse_button.pressed);
    try std.testing.expect(events[1].key.pressed and events[1].key.modifiers.shift);
    try std.testing.expectEqual(@as(u16, 30), events[1].key.keycode);
    try std.testing.expectEqualStrings("é", events[2].text_input.text);
    try std.testing.expect(!events[3].key.pressed);
    try std.testing.expectEqual(@as(usize, 4), win.head);
    _ = try sdk.pump(0);
    try std.testing.expectEqual(@as(usize, 0), sdk.events().len);
}

test "LinuxBackend maps wl_pointer.leave to pointer_left after the button cancellation" {
    var win: OrderedMockWindow = .{ .count = 3 };
    win.inputs[0] = .{ .kind = 4, .x = 40, .y = 50 };
    win.inputs[1] = .{ .kind = 1, .button = 0, .pressed = 0, .cancelled = 1, .x = 40, .y = 50 };
    win.inputs[2] = .{ .kind = 9, .x = 40, .y = 50 };
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    const events = sdk.events();
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expect(events[0] == .mouse_move);
    try std.testing.expect(events[1].mouse_button.cancelled);
    try std.testing.expect(events[2] == .pointer_left);
    try std.testing.expectEqual(@as(WindowId, 9), events[2].targetWindowId().?);
    try std.testing.expectEqual(@as(usize, 3), win.head);
}

test "LinuxBackend retries native text after allocation failure without consuming head" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var win: OrderedMockWindow = .{ .count = 1 };
    win.inputs[0] = .{ .kind = 3, .text_length = 6 };
    @memcpy(win.inputs[0].text[0..6], "中文");
    var sdk = try LinuxBackend.initSystemSdk(failing.allocator(), &win, 9);
    defer sdk.deinit();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(SdkError.OutOfMemory, sdk.pump(0));
    try std.testing.expectEqual(@as(usize, 0), win.head);
    try std.testing.expectEqualStrings("中文", win.inputs[0].text[0..6]);
    failing.fail_index = std.math.maxInt(usize);
    _ = try sdk.pump(0);
    try std.testing.expectEqual(@as(usize, 1), win.head);
    try std.testing.expectEqualStrings("中文", sdk.events()[0].text_input.text);
}

test "LinuxBackend advertises negotiated fixed cursors and checks window and shape" {
    var win: MockWindow = .{ .cursor_available = true };
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();
    try std.testing.expect(sdk.capabilities.cursor);
    try std.testing.expect(!sdk.customCursorSupported());
    try sdk.setCursorShape(9, 3);
    try std.testing.expectEqual(@as(u8, 3), win.cursor_shape);
    try std.testing.expectError(SdkError.InvalidState, sdk.setCursorShape(10, 3));
    try std.testing.expectError(SdkError.InvalidState, sdk.setCursorShape(9, 255));
    try std.testing.expectError(SdkError.NotSupported, sdk.setCursorShape(9, 19));
    try std.testing.expectEqual(@as(u32, 1), win.cursor_calls);
    win.cursor_available = false;
    try std.testing.expectError(SdkError.BackendFailure, sdk.setCursorShape(9, 3));
}

test "LinuxBackend does not advertise an unavailable cursor service" {
    var win: MockWindow = .{};
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();
    try std.testing.expect(!sdk.capabilities.cursor);
    try std.testing.expectError(SdkError.NotSupported, sdk.setCursorShape(9, 3));
}

test "Linux clipboard negotiation, Unicode ownership and complete reads" {
    var window: MockWindow = .{ .clipboard_available = true };
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &window, 1);
    defer sdk.deinit();
    try std.testing.expect(sdk.capabilities.clipboard);
    var input = [_]u8{ 'a', 0xc3, 0xa9 };
    try sdk.clipboardSetText(&input);
    input[0] = 'z';
    var tiny: [1]u8 = .{'!'};
    try std.testing.expectError(error.BufferTooSmall, sdk.clipboardGetText(&tiny));
    try std.testing.expectEqual(@as(u8, '!'), tiny[0]);
    const owned = (try sdk.clipboardGetTextAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("aé", owned);
    try std.testing.expectError(error.InvalidState, sdk.clipboardSetText(&.{0xff}));
    window.clipboard_bytes[0] = 0xff;
    try std.testing.expectError(error.BackendFailure, sdk.clipboardGetTextAlloc(std.testing.allocator));
    try sdk.clipboardSetText("");
    try std.testing.expect((try sdk.clipboardGetTextAlloc(std.testing.allocator)) == null);
    window.clipboard_status = -5;
    try std.testing.expectError(error.Timeout, sdk.clipboardGetTextAlloc(std.testing.allocator));
    window.clipboard_status = -7;
    try std.testing.expectError(error.WrongThread, sdk.clipboardSetText("x"));
    window.clipboard_status = -6;
    try std.testing.expectError(error.InvalidState, sdk.clipboardSetText("x"));
}

test "Linux missing data-device does not advertise clipboard support" {
    var window: MockWindow = .{};
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &window, 1);
    defer sdk.deinit();
    try std.testing.expect(!sdk.capabilities.clipboard);
    try std.testing.expectError(error.NotSupported, sdk.clipboardSetText("x"));
}

test "Linux IME owns long preedit, selection and commit; focus switch invalidates copied events" {
    var bytes: [600]u8 = undefined;
    for (0..200) |i| @memcpy(bytes[i * 3 ..][0..3], "候");
    var commit = [_]u8{ 0xe4, 0xbd, 0xa0 };
    var win: OrderedMockWindow = .{ .ime_available = true, .count = 4 };
    win.inputs[0] = .{ .kind = 6, .owned_text = &bytes, .text_length = bytes.len, .cursor_begin = 300, .cursor_end = 600 };
    win.inputs[1] = .{ .kind = 8, .delete_before = 3, .delete_after = 6 };
    win.inputs[2] = .{ .kind = 7, .owned_text = &commit, .text_length = 3 };
    win.inputs[3] = .{ .kind = 6, .cursor_begin = -1, .cursor_end = -1 };
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();
    try std.testing.expect(sdk.capabilities.ime);
    _ = try sdk.pump(0);
    const events = sdk.events();
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqualStrings("候", events[0].ime_preedit.text[0..3]);
    try std.testing.expectEqualStrings("你", events[2].ime_commit.text);
    try std.testing.expectEqual(@as(u32, 300), events[0].ime_preedit.cursor_utf8_offset);
    try std.testing.expectEqual(@as(?u32, 600), events[0].ime_preedit.selection_end_utf8);
    try std.testing.expect(!events[3].ime_preedit.cursor_visible);
    try std.testing.expectEqual(@as(u32, 6), events[1].ime_delete_surrounding.after_bytes);
    try std.testing.expect(sdk.imeEventCurrent(events[0]));
    win.ime_result = -7;
    try std.testing.expectError(error.WrongThread, sdk.discardIme(9));
    try std.testing.expect(sdk.imeEventCurrent(events[0]));
    win.ime_result = 0;
    try sdk.discardIme(9);
    try std.testing.expect(!sdk.imeEventCurrent(events[0]));
    try std.testing.expect(!sdk.imeEventCurrent(events[1]));
    try std.testing.expect(!sdk.imeEventCurrent(events[2]));
    try std.testing.expectError(error.InvalidState, sdk.setTextInputEnabled(8, true));
    try std.testing.expectError(error.InvalidState, sdk.setImeSurrounding(9, "\xff", 0, 0, false));
}

test "Linux IME allocation failure preserves native preedit for retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var candidate = [_]u8{ 0xe4, 0xbd, 0xa0 };
    var win: OrderedMockWindow = .{ .ime_available = true, .count = 1 };
    win.inputs[0] = .{ .kind = 6, .owned_text = &candidate, .text_length = 3, .cursor_begin = 3, .cursor_end = 3 };
    var sdk = try LinuxBackend.initSystemSdk(failing.allocator(), &win, 9);
    defer sdk.deinit();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, sdk.pump(0));
    try std.testing.expectEqual(@as(usize, 0), win.head);
    try std.testing.expectEqualStrings("你", &candidate);
    failing.fail_index = std.math.maxInt(usize);
    _ = try sdk.pump(0);
    try std.testing.expectEqual(@as(usize, 1), win.head);
    try std.testing.expectEqualStrings("你", sdk.events()[0].ime_preedit.text);
}

test "LinuxBackend preserves fractional scroll and gesture termination order" {
    var win: OrderedMockWindow = .{ .count = 4 };
    for ([_]u32{ 2, 3, 4, 5 }, 0..) |phase, i| {
        win.inputs[i] = .{ .kind = 5, .x = 90, .y = 300, .dx = 0.5, .dy = if (i < 2) -1.25 else 0, .scroll_phase = phase };
    }
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    const expected = [_]events_mod.ScrollPhase{ .began, .changed, .ended, .cancelled };
    try std.testing.expectEqual(@as(usize, 4), sdk.events().len);
    for (sdk.events(), expected, 0..) |event, phase, i| {
        const wheel = event.mouse_wheel;
        try std.testing.expectEqual(phase, wheel.phase);
        try std.testing.expectEqual(@as(f32, 0.5), wheel.dx);
        try std.testing.expectEqual(@as(f32, if (i < 2) -1.25 else 0), wheel.dy);
        try std.testing.expectEqual(@as(f32, 90), wheel.x);
        try std.testing.expectEqual(@as(f32, 300), wheel.y);
    }
    _ = try sdk.pump(0);
    try std.testing.expectEqual(@as(usize, 0), sdk.events().len);
}
