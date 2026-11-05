const std = @import("std");
const Allocator = std.mem.Allocator;

const backend_mod = @import("../vtable.zig");
const capabilities_mod = @import("../capabilities.zig");
const events_mod = @import("../events.zig");
const WindowId = @import("../events.zig").WindowId;
const SystemSdk = @import("../api.zig").SystemSdk;
const SdkError = @import("../errors.zig").SdkError;

extern fn zenit_win_clipboard_set_text(owner: *anyopaque, text: [*]const u8, len: usize) c_int;
extern fn zenit_win_clipboard_get_text_len() c_int;
extern fn zenit_win_clipboard_get_text(buffer: [*]u8, capacity: usize) c_int;
const NativeClipboardImage = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    rgba: ?[*]u8 = null,
    raw: ?[*]u8 = null,
    raw_len: usize = 0,
};
extern fn zenit_win_clipboard_probe() u32;
extern fn zenit_win_clipboard_get_image(image: *NativeClipboardImage) c_int;
extern fn zenit_win_clipboard_free_image(image: *NativeClipboardImage) void;
extern fn zenit_win_clipboard_set_image_png(owner: *anyopaque, bytes: [*]const u8, len: usize) c_int;
extern fn zenit_win_file_dialog(owner: *anyopaque, kind: c_uint, title: [*:0]const u16, directory: [*:0]const u16, out: [*]u8, capacity: usize) c_int;

const NativeMenuNode = extern struct {
    id: u64,
    parent: u64,
    command: u64,
    label: [*]const u8,
    key: [*]const u8,
    label_len: usize,
    key_len: usize,
    modifiers: u32,
    role: u32,
    kind: u32,
    enabled: u32,
    checked: u32,
};
extern fn zenit_win_menu_clear(owner: *anyopaque) c_int;
extern fn zenit_win_menu_set(owner: *anyopaque, nodes: [*]const NativeMenuNode, count: usize) c_int;

const CAPS = capabilities_mod.Capabilities{
    .request_redraw = true,
    .multi_window = false,
    .ime = true,
    .cursor = true,
    .clipboard = true,
    .clipboard_image = true,
    .file_dialog = true,
};

/// Win32 event bridge. Native window queues retain input until this pump
/// converts it to SystemSdk events and supports Unicode clipboard text.
pub const WindowsBackend = struct {
    pub fn initSystemSdk(allocator: Allocator, window: anytype, window_id: WindowId) !SystemSdk {
        const WindowType = @TypeOf(window);
        const WindowBase = switch (@typeInfo(WindowType)) {
            .pointer => |p| p.child,
            else => WindowType,
        };
        const ordered_moves = @hasDecl(WindowBase, "hasOrderedMouseMoveEvents") and WindowBase.hasOrderedMouseMoveEvents;
        const has_menu = @hasDecl(WindowBase, "peekMenuCommand") and @hasDecl(WindowBase, "consumeMenuCommand");

        const Impl = struct {
            const Context = struct {
                window: WindowType,
                allocator: Allocator,
                window_id: WindowId,
                last_width: u32,
                last_height: u32,
                last_scale: f32,
                last_focused: bool,
                has_last_mouse: bool = false,
                last_mouse_x: f32,
                last_mouse_y: f32,
                ime_buffer: [98304]u8 = undefined,
            };

            fn deinitImpl(ctx: *anyopaque, allocator_: Allocator) void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (comptime has_menu) _ = zenit_win_menu_clear(self.window.getNativeSurfaceHandle());
                allocator_.destroy(self);
            }

            fn menuSetModelImpl(ctx: *anyopaque, model: backend_mod.MenuModel) SdkError!void {
                if (comptime !has_menu) return SdkError.NotSupported;
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (model.nodes.len > 1024) return SdkError.InvalidState;
                const nodes = self.allocator.alloc(NativeMenuNode, model.nodes.len) catch return SdkError.OutOfMemory;
                defer self.allocator.free(nodes);
                for (model.nodes, nodes) |node, *native| native.* = .{
                    .id = node.id,
                    .parent = node.parent_id,
                    .command = node.command_id,
                    .label = node.label.ptr,
                    .label_len = node.label.len,
                    .key = node.key_equivalent.ptr,
                    .key_len = node.key_equivalent.len,
                    .modifiers = @as(u32, @intFromBool(node.modifiers.shift)) | (@as(u32, @intFromBool(node.modifiers.ctrl)) << 1) | (@as(u32, @intFromBool(node.modifiers.alt)) << 2) | (@as(u32, @intFromBool(node.modifiers.super)) << 3),
                    .role = @backingInt(node.role),
                    .kind = @backingInt(node.kind),
                    .enabled = @intFromBool(node.enabled),
                    .checked = @intFromBool(node.checked),
                };
                switch (zenit_win_menu_set(self.window.getNativeSurfaceHandle(), nodes.ptr, nodes.len)) {
                    1 => {},
                    -3 => return SdkError.WrongThread,
                    -4 => return SdkError.InvalidState,
                    -5 => return SdkError.NotSupported,
                    else => return SdkError.BackendFailure,
                }
            }

            fn requestRedrawImpl(ctx: *anyopaque) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                self.window.requestRedraw();
            }

            fn pumpEventsImpl(ctx: *anyopaque, queue: *events_mod.EventQueue, timeout_ms: u32) SdkError!backend_mod.PumpResult {
                _ = timeout_ms;
                const self: *Context = @ptrCast(@alignCast(ctx));

                const should_continue = self.window.pollEvents();

                const focused = self.window.isFocused();
                if (focused != self.last_focused) {
                    try pushEvent(queue, .{ .window_focused = .{
                        .window_id = self.window_id,
                        .focused = focused,
                    } });
                    self.last_focused = focused;
                }

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
                if ((!ordered_moves or (!self.has_last_mouse and self.window.peekInputKind() == 0)) and
                    (!self.has_last_mouse or mx != self.last_mouse_x or my != self.last_mouse_y))
                {
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

                var text_buffer: [4]u8 = undefined;
                while (self.window.peekInputKind() != 0) {
                    switch (self.window.peekInputKind()) {
                        1 => {
                            // Keep cancellation in the native queue if allocation fails.
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
                                .modifiers = toModifiers(button.modifiers),
                            } });
                        },
                        2 => {
                            const key = self.window.getKeyEvent() orelse break;
                            try pushEvent(queue, .{ .key = .{
                                .window_id = self.window_id,
                                .keycode = key.keycode,
                                .pressed = key.pressed,
                                .modifiers = toModifiers(key.modifiers),
                            } });
                        },
                        3 => {
                            const input = self.window.getInputText(&text_buffer) orelse break;
                            try pushEvent(queue, .{ .text_input = .{
                                .window_id = self.window_id,
                                .text = input.text,
                            } });
                        },
                        4 => switch (self.window.peekImeKind()) {
                            1 => {
                                const preedit = self.window.getImePreedit(&self.ime_buffer) orelse break;
                                try pushEvent(queue, .{ .ime_preedit = .{
                                    .window_id = self.window_id,
                                    .text = preedit.text,
                                    .cursor_utf8_offset = preedit.cursor_utf8_offset,
                                } });
                            },
                            2 => {
                                const commit = self.window.getImeCommit(&self.ime_buffer) orelse break;
                                try pushEvent(queue, .{ .ime_commit = .{
                                    .window_id = self.window_id,
                                    .text = commit.text,
                                } });
                            },
                            else => break,
                        },
                        5 => {
                            const wheel = self.window.getScrollDelta() orelse break;
                            try pushEvent(queue, .{ .mouse_wheel = .{
                                .window_id = self.window_id,
                                .x = wheel.x,
                                .y = wheel.y,
                                .dx = wheel.dx,
                                .dy = wheel.dy,
                                .modifiers = toModifiers(wheel.modifiers),
                            } });
                        },
                        6 => {
                            const drag = self.window.peekDragEvent() orelse break;
                            try pushEvent(queue, .{ .drag = .{
                                .window_id = self.window_id,
                                .x = drag.x,
                                .y = drag.y,
                                .kind = drag.kind,
                                .paths = drag.paths,
                                .payload_kind = drag.payload_kind,
                                .operation = drag.operation,
                                .payload_truncated = drag.truncated,
                                .payload_is_untrusted = drag.source_token == 0,
                                .source_token = drag.source_token,
                            } });
                            // EventQueue first owns a copy. Failed allocation
                            // leaves the native head and its serial untouched.
                            if (!self.window.consumeDragEvent(drag.sequence)) return SdkError.BackendFailure;
                        },
                        7 => {
                            if (comptime has_menu) {
                                const command = self.window.peekMenuCommand() orelse break;
                                // Reserve before consuming native state; retry on OOM.
                                try queue.list.ensureUnusedCapacity(queue.allocator, 1);
                                try pushEvent(queue, .{ .menu_command = .{ .window_id = self.window_id, .command_id = command } });
                                if (!self.window.consumeMenuCommand()) return SdkError.BackendFailure;
                            } else break;
                        },
                        8 => {
                            if (comptime ordered_moves) {
                                try queue.list.ensureUnusedCapacity(queue.allocator, 1);
                                const move = self.window.getMouseMoveEvent() orelse break;
                                if (comptime @hasField(@TypeOf(move), "left")) if (move.left) {
                                    // WM_MOUSELEAVE: position unchanged, pointer no longer over the client area.
                                    try pushEvent(queue, .{ .pointer_left = .{ .window_id = self.window_id } });
                                    continue;
                                };
                                try pushEvent(queue, .{ .mouse_move = .{
                                    .window_id = self.window_id,
                                    .x = move.x,
                                    .y = move.y,
                                    .dx = move.dx,
                                    .dy = move.dy,
                                    .modifiers = toModifiers(move.modifiers),
                                } });
                                self.has_last_mouse = true;
                                self.last_mouse_x = move.x;
                                self.last_mouse_y = move.y;
                            } else break;
                        },
                        else => break,
                    }
                }

                if (comptime @hasDecl(@typeInfo(WindowType).pointer.child, "checkShouldClose")) {
                    if (should_continue and self.window.checkShouldClose()) {
                        try pushEvent(queue, .{ .window_close_requested = .{ .window_id = self.window_id } });
                        self.window.resetShouldClose();
                    }
                }
                if (!should_continue) {
                    try pushEvent(queue, .{ .quit = {} });
                }

                return .{
                    .should_continue = should_continue,
                };
            }

            pub const VTABLE = backend_mod.BackendVTable{
                .name = "windows-minimal",
                .deinit = deinitImpl,
                .pump_events = pumpEventsImpl,
                .request_redraw = requestRedrawImpl,
                .cursor = .{ .set_shape = cursorSetShapeImpl },
                .menu = if (has_menu) .{ .set_model = menuSetModelImpl } else null,
                .dialog = .{ .run = dialogRunImpl },
                .drag_target = .{ .set_allowed_operations = dragTargetOperationsImpl },
                .drag_source = .{ .start = dragStartImpl },
                .clipboard = .{
                    .set_text = clipboardSetTextImpl,
                    .get_text = clipboardGetTextImpl,
                    .get_text_len = clipboardGetTextLenImpl,
                    .probe = clipboardProbeImpl,
                    .image_count = clipboardImageCountImpl,
                    .get_image = clipboardGetImageImpl,
                    .set_image_png = clipboardSetImageImpl,
                },
                .ime = .{
                    .set_enabled = imeSetEnabledImpl,
                    .set_cursor_rect = imeSetCursorRectImpl,
                    .discard = imeDiscardImpl,
                },
            };

            fn cursorSetShapeImpl(ctx: *anyopaque, id: WindowId, shape: u8) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id or shape > 20) return SdkError.InvalidState;
                if (shape == 19) return SdkError.NotSupported;
                if (!self.window.setCursorShapeChecked(shape)) return SdkError.InvalidState;
            }

            fn dragTargetOperationsImpl(ctx: *anyopaque, id: WindowId, operations: backend_mod.DragOperations) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id) return SdkError.InvalidState;
                if (!self.window.setDragTargetOperations(@bitCast(operations))) return SdkError.InvalidState;
            }

            fn dragStartImpl(ctx: *anyopaque, id: WindowId, request: backend_mod.DragRequest) SdkError!u64 {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (id != self.window_id) return SdkError.InvalidState;
                const result = self.window.startDrag(request);
                if (result.token != 0) return result.token;
                return switch (result.err) {
                    -2 => SdkError.OutOfMemory,
                    -3 => SdkError.BackendFailure,
                    else => SdkError.InvalidState,
                };
            }

            fn dialogRunImpl(ctx: *anyopaque, request: backend_mod.DialogRequest, buffer: []u8) SdkError!?[]const u8 {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (buffer.len == 0 or buffer.len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;
                if (std.mem.indexOfScalar(u8, request.title, 0) != null or std.mem.indexOfScalar(u8, request.default_path, 0) != null) return SdkError.InvalidState;
                const title = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, request.title) catch |err| return if (err == error.OutOfMemory) SdkError.OutOfMemory else SdkError.InvalidState;
                defer self.allocator.free(title);
                const directory = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, request.default_path) catch |err| return if (err == error.OutOfMemory) SdkError.OutOfMemory else SdkError.InvalidState;
                defer self.allocator.free(directory);
                const result = zenit_win_file_dialog(self.window.getNativeSurfaceHandle(), @backingInt(request.kind), title.ptr, directory.ptr, buffer.ptr, buffer.len);
                return switch (result) {
                    0 => null,
                    -2 => SdkError.BufferTooSmall,
                    -3 => SdkError.WrongThread,
                    -4 => SdkError.InvalidState,
                    else => if (result < 0) SdkError.BackendFailure else if (@as(usize, @intCast(result)) >= buffer.len) SdkError.BackendFailure else buffer[0..@intCast(result)],
                };
            }

            fn imeSetEnabledImpl(ctx: *anyopaque, target_id: WindowId, enabled: bool) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (target_id != self.window_id) return SdkError.InvalidState;
                self.window.setTextInputEnabled(enabled);
            }

            fn clipboardSetTextImpl(ctx: *anyopaque, value: []const u8) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (zenit_win_clipboard_set_text(self.window.getNativeSurfaceHandle(), value.ptr, value.len) == 0) return SdkError.BackendFailure;
            }

            fn clipboardProbeImpl(_: *anyopaque) u32 {
                return zenit_win_clipboard_probe();
            }

            fn clipboardImageCountImpl(_: *anyopaque) usize {
                return if (zenit_win_clipboard_probe() & 2 != 0) 1 else 0;
            }

            fn clipboardSetImageImpl(ctx: *anyopaque, bytes: []const u8) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (zenit_win_clipboard_set_image_png(self.window.getNativeSurfaceHandle(), bytes.ptr, bytes.len) == 0) return SdkError.BackendFailure;
            }

            fn clipboardGetImageImpl(_: *anyopaque, alloc: Allocator, index: usize) SdkError!?backend_mod.ClipboardImage {
                if (index != 0) return null;
                var image: NativeClipboardImage = .{};
                defer zenit_win_clipboard_free_image(&image);
                const result = zenit_win_clipboard_get_image(&image);
                if (result == 0) return null;
                if (result < 0) return SdkError.BackendFailure;
                const source = image.rgba orelse return SdkError.BackendFailure;
                if (image.width == 0 or image.height == 0 or image.width > 16384 or image.height > 16384) return SdkError.BackendFailure;
                const size = @as(usize, image.width) * image.height * 4;
                const rgba = alloc.dupe(u8, source[0..size]) catch return SdkError.OutOfMemory;
                errdefer alloc.free(rgba);
                var raw: ?[]const u8 = null;
                var uti: ?[]const u8 = null;
                errdefer if (raw) |bytes| alloc.free(bytes);
                if (image.raw) |bytes| {
                    raw = alloc.dupe(u8, bytes[0..image.raw_len]) catch return SdkError.OutOfMemory;
                    uti = alloc.dupe(u8, "public.png") catch return SdkError.OutOfMemory;
                }
                return .{ .width = image.width, .height = image.height, .rgba = rgba, .raw_bytes = raw, .uti = uti };
            }

            fn clipboardGetTextLenImpl(_: *anyopaque) SdkError!usize {
                const len = zenit_win_clipboard_get_text_len();
                if (len < 0) return SdkError.BackendFailure;
                return @intCast(len);
            }

            fn clipboardGetTextImpl(_: *anyopaque, buffer: []u8) SdkError![]const u8 {
                const len = zenit_win_clipboard_get_text(buffer.ptr, buffer.len);
                if (len == -2) return SdkError.BufferTooSmall;
                if (len < 0 or @as(usize, @intCast(len)) > buffer.len) return SdkError.BackendFailure;
                return buffer[0..@intCast(len)];
            }

            fn imeSetCursorRectImpl(ctx: *anyopaque, target_id: WindowId, x: f32, y: f32, width: f32, height: f32) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (target_id != self.window_id) return SdkError.InvalidState;
                self.window.setImeCursorRect(x, y, width, height);
            }

            fn imeDiscardImpl(ctx: *anyopaque, target_id: WindowId) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                if (target_id != self.window_id) return SdkError.InvalidState;
                self.window.discardIme();
            }

            fn toModifiers(mods: anytype) events_mod.Modifiers {
                return .{ .shift = mods.shift, .ctrl = mods.ctrl, .alt = mods.alt, .super = mods.cmd };
            }
        };

        const size = window.getSize();
        const scale = window.getScaleFactor();
        const mouse = window.getMousePosition();

        const ctx = try allocator.create(Impl.Context);
        ctx.* = .{
            .window = window,
            .allocator = allocator,
            .window_id = window_id,
            .last_width = size[0],
            .last_height = size[1],
            .last_scale = scale,
            .last_focused = window.isFocused(),
            .last_mouse_x = mouse[0],
            .last_mouse_y = mouse[1],
        };

        var caps = CAPS;
        caps.menu_bar = has_menu;
        caps.drag_drop_target = window.isDragDropReady();
        caps.drag_source = window.isDragSourceReady();
        return SystemSdk.init(allocator, ctx, &Impl.VTABLE, caps);
    }
};

fn pushEvent(queue: *events_mod.EventQueue, event: events_mod.Event) SdkError!void {
    queue.push(event) catch return SdkError.OutOfMemory;
}

const MockWindow = struct {
    pub const hasOrderedMouseMoveEvents = true;
    fn isDragSourceReady(self: *MockWindow) bool {
        return self.source_ready;
    }
    fn startDrag(self: *MockWindow, _: backend_mod.DragRequest) struct { token: u64, err: c_int } {
        self.source_starts += 1;
        return .{ .token = if (self.source_error == 0) 987654321 else 0, .err = self.source_error };
    }
    const Drag = struct { x: f32, y: f32, kind: u8, payload_kind: u8, paths: []const u8, truncated: bool, operation: u8, sequence: u64, source_token: u64 = 0 };
    fn isDragDropReady(self: *MockWindow) bool {
        return self.drag_ready;
    }
    fn setDragTargetOperations(self: *MockWindow, operations: u8) bool {
        if (!self.drag_ready or operations & 0xf8 != 0) return false;
        self.drag_operations = operations;
        return true;
    }
    fn peekDragEvent(self: *MockWindow) ?Drag {
        if (!self.drag_pending) return null;
        return .{ .x = 15.5, .y = 23, .kind = if (self.source_token != 0) 4 else 3, .payload_kind = 2, .paths = self.drag_payload, .truncated = false, .operation = if (self.source_token != 0) 0 else 1, .sequence = 700, .source_token = self.source_token };
    }
    fn consumeDragEvent(self: *MockWindow, serial: u64) bool {
        if (!self.drag_pending or serial != 700) return false;
        self.drag_pending = false;
        self.drag_consumed += 1;
        @memset(self.drag_payload, 'x'); // Native storage expires immediately.
        return true;
    }
    fn getNativeSurfaceHandle(_: *MockWindow) *anyopaque {
        return @ptrFromInt(1);
    }
    drag_ready: bool = false,
    source_ready: bool = false,
    source_error: c_int = -1,
    source_starts: u32 = 0,
    source_token: u64 = 0,
    drag_pending: bool = false,
    drag_consumed: u32 = 0,
    drag_payload: []u8 = &.{},
    drag_operations: u8 = 1,
    frame: u32 = 0,
    redraw_requests: u32 = 0,
    button_sent: bool = false,
    move_pending: bool = false,
    leave_pending: bool = false,
    move_after_button: bool = false,
    cancel_pending: bool = false,
    key_sent: bool = false,
    wheel_sent: bool = false,
    text_sent: bool = false,
    preedit_sent: bool = false,
    commit_sent: bool = false,
    ime_enabled: bool = false,
    ime_discarded: bool = false,
    ime_cursor_x: f32 = 0,
    text_before_key: bool = false,
    wheel_before_key: bool = false,
    cursor_shape: u8 = 1,
    cursor_accept: bool = true,

    fn pollEvents(self: *MockWindow) bool {
        self.frame += 1;
        if (self.frame == 2 and !self.button_sent) self.move_pending = true;
        return self.frame < 3;
    }

    fn getSize(self: *MockWindow) [2]u32 {
        return if (self.frame >= 2) .{ 1024, 768 } else .{ 800, 600 };
    }

    fn getScaleFactor(_: *MockWindow) f32 {
        return 1.25;
    }

    fn isFocused(self: *MockWindow) bool {
        return self.frame < 2;
    }

    fn getMousePosition(self: *MockWindow) [2]f32 {
        return switch (self.frame) {
            0 => .{ 5, 5 },
            1 => .{ 5, 5 },
            else => .{ 7, 9 },
        };
    }

    fn setCursorShapeChecked(self: *MockWindow, shape: u8) bool {
        if (!self.cursor_accept) return false;
        self.cursor_shape = shape;
        return true;
    }
    fn requestRedraw(self: *MockWindow) void {
        self.redraw_requests += 1;
    }

    fn peekInputKind(self: *MockWindow) c_int {
        if (self.drag_pending) return 6;
        if (self.frame != 2) return 0;
        if (self.leave_pending) return 8;
        if (self.move_pending and (!self.move_after_button or self.button_sent)) return 8;
        if (!self.button_sent or self.cancel_pending) return 1;
        if (self.wheel_before_key and !self.wheel_sent) return 5;
        if (self.text_before_key and !self.text_sent) return 3;
        if (!self.key_sent) return 2;
        if (!self.text_sent) return 3;
        if (!self.commit_sent) return 4;
        if (!self.wheel_sent) return 5;
        return 0;
    }

    const Mods = struct { shift: bool = false, ctrl: bool = false, alt: bool = false, cmd: bool = false };
    fn getMouseMoveEvent(self: *MockWindow) ?struct { x: f32, y: f32, dx: f32, dy: f32, modifiers: Mods, left: bool = false } {
        if (self.leave_pending) {
            self.leave_pending = false;
            return .{ .x = 5, .y = 5, .dx = 0, .dy = 0, .modifiers = .{}, .left = true };
        }
        if (!self.move_pending) return null;
        self.move_pending = false;
        return .{ .x = 7, .y = 9, .dx = 2, .dy = 4, .modifiers = .{ .shift = true } };
    }
    fn getMouseButtonEvent(self: *MockWindow) ?struct { x: f32, y: f32, button: enum { left, right, middle }, pressed: bool, cancelled: bool = false, modifiers: Mods } {
        if (self.frame != 2) return null;
        if (self.button_sent and self.cancel_pending) {
            self.cancel_pending = false;
            return .{ .x = 7, .y = 9, .button = .left, .pressed = false, .cancelled = true, .modifiers = .{} };
        }
        if (self.button_sent) return null;
        self.button_sent = true;
        return .{ .x = 7, .y = 9, .button = .left, .pressed = true, .modifiers = .{ .shift = true } };
    }
    fn getKeyEvent(self: *MockWindow) ?struct { keycode: u16, pressed: bool, modifiers: Mods } {
        if (self.frame != 2 or self.key_sent) return null;
        self.key_sent = true;
        return .{ .keycode = 0x41, .pressed = true, .modifiers = .{ .ctrl = true } };
    }
    fn getScrollDelta(self: *MockWindow) ?struct { x: f32, y: f32, dx: f32, dy: f32, modifiers: Mods } {
        if (self.frame != 2 or self.wheel_sent) return null;
        self.wheel_sent = true;
        return .{ .x = 7, .y = 9, .dx = 0, .dy = 40, .modifiers = .{} };
    }
    fn getInputText(self: *MockWindow, buffer: []u8) ?struct { text: []const u8 } {
        if (self.frame != 2 or self.text_sent) return null;
        self.text_sent = true;
        buffer[0] = 'A';
        return .{ .text = buffer[0..1] };
    }
    fn peekImeKind(self: *MockWindow) c_int {
        if (self.frame != 2) return 0;
        if (!self.preedit_sent) return 1;
        if (!self.commit_sent) return 2;
        return 0;
    }
    fn getImePreedit(self: *MockWindow, buffer: []u8) ?struct { text: []const u8, cursor_utf8_offset: u32 } {
        if (self.peekImeKind() != 1) return null;
        self.preedit_sent = true;
        @memcpy(buffer[0..3], "あ");
        return .{ .text = buffer[0..3], .cursor_utf8_offset = 3 };
    }
    fn getImeCommit(self: *MockWindow, buffer: []u8) ?struct { text: []const u8 } {
        if (self.peekImeKind() != 2) return null;
        self.commit_sent = true;
        @memcpy(buffer[0..3], "亜");
        return .{ .text = buffer[0..3] };
    }
    fn setTextInputEnabled(self: *MockWindow, enabled: bool) void {
        self.ime_enabled = enabled;
    }
    fn setImeCursorRect(self: *MockWindow, x: f32, _: f32, _: f32, _: f32) void {
        self.ime_cursor_x = x;
    }
    fn discardIme(self: *MockWindow) void {
        self.ime_discarded = true;
    }
};

test "WindowsBackend minimal: pump events + redraw" {
    var win = MockWindow{};
    var sdk = try WindowsBackend.initSystemSdk(std.testing.allocator, &win, 11);
    defer sdk.deinit();

    try sdk.requestRedraw();
    try std.testing.expectEqual(@as(u32, 1), win.redraw_requests);
    try sdk.setTextInputEnabled(11, true);
    try sdk.setImeCursorRect(11, 23, 0, 1, 10);
    try sdk.discardIme(11);
    try std.testing.expect(win.ime_enabled and win.ime_discarded);
    try std.testing.expectEqual(@as(f32, 23), win.ime_cursor_x);

    const p1 = try sdk.pump(0);
    try std.testing.expect(p1.should_continue);
    try std.testing.expectEqual(@as(usize, 1), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .mouse_move);

    const p2 = try sdk.pump(0);
    try std.testing.expect(p2.should_continue);
    try std.testing.expectEqual(@as(usize, 9), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .window_focused);
    try std.testing.expect(!sdk.events()[0].window_focused.focused);
    try std.testing.expect(sdk.events()[1] == .window_resized);
    try std.testing.expect(sdk.events()[2] == .mouse_move);
    try std.testing.expect(sdk.events()[3] == .mouse_button);
    try std.testing.expect(sdk.events()[3].mouse_button.modifiers.shift);
    try std.testing.expect(sdk.events()[4] == .key);
    try std.testing.expect(sdk.events()[4].key.modifiers.ctrl);
    try std.testing.expect(sdk.events()[5] == .text_input);
    try std.testing.expectEqualStrings("A", sdk.events()[5].text_input.text);
    try std.testing.expect(sdk.events()[6] == .ime_preedit);
    try std.testing.expect(sdk.events()[7] == .ime_commit);
    try std.testing.expect(sdk.events()[8] == .mouse_wheel);
    try std.testing.expectEqual(@as(f32, 40), sdk.events()[8].mouse_wheel.dy);
    try std.testing.expectEqualStrings("あ", sdk.events()[6].ime_preedit.text);
    try std.testing.expectEqual(@as(u32, 3), sdk.events()[6].ime_preedit.cursor_utf8_offset);
    try std.testing.expectEqualStrings("亜", sdk.events()[7].ime_commit.text);

    const p3 = try sdk.pump(0);
    try std.testing.expect(!p3.should_continue);
    try std.testing.expectEqual(@as(usize, 1), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .quit);
}

test "WindowsBackend preserves a text event queued before a key" {
    var win = MockWindow{ .text_before_key = true };
    var sdk = try WindowsBackend.initSystemSdk(std.testing.allocator, &win, 12);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    _ = try sdk.pump(0);
    try std.testing.expect(sdk.events()[3] == .mouse_button);
    try std.testing.expect(sdk.events()[4] == .text_input);
    try std.testing.expectEqualStrings("A", sdk.events()[4].text_input.text);
    try std.testing.expect(sdk.events()[5] == .key);
}

test "WindowsBackend preserves a wheel event queued before a key" {
    var win = MockWindow{ .wheel_before_key = true };
    var sdk = try WindowsBackend.initSystemSdk(std.testing.allocator, &win, 13);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    _ = try sdk.pump(0);
    try std.testing.expect(sdk.events()[3] == .mouse_button);
    try std.testing.expect(sdk.events()[4] == .mouse_wheel);
    try std.testing.expectEqual(@as(f32, 40), sdk.events()[4].mouse_wheel.dy);
    try std.testing.expect(sdk.events()[5] == .key);
}

test "WindowsBackend retries a native drop after allocation failure and owns its payload" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var text = "中文\x00🧪".*;
    var win = MockWindow{ .drag_ready = true, .drag_payload = &text };
    var sdk = try WindowsBackend.initSystemSdk(allocator.allocator(), &win, 14);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    _ = try sdk.pump(0);
    win.drag_pending = true;
    allocator.fail_index = allocator.alloc_index;
    try std.testing.expectError(SdkError.OutOfMemory, sdk.pump(0));
    try std.testing.expect(win.drag_pending);
    try std.testing.expectEqual(@as(u32, 0), win.drag_consumed);
    try std.testing.expectEqualStrings("中文\x00🧪", &text);
    allocator.fail_index = std.math.maxInt(usize);
    _ = try sdk.pump(0);
    try std.testing.expect(!win.drag_pending);
    try std.testing.expectEqual(@as(u32, 1), win.drag_consumed);
    const drag = sdk.events()[0].drag;
    try std.testing.expectEqualStrings("中文\x00🧪", drag.paths);
    try std.testing.expectEqual(@as(f32, 15.5), drag.x);
    try std.testing.expectEqual(@as(u8, 3), drag.kind);
    try std.testing.expectEqual(@as(u8, 2), drag.payload_kind);
    try std.testing.expectEqual(@as(u8, 1), drag.operation);
    try std.testing.expect(drag.payload_is_untrusted and !drag.payload_truncated);
    try std.testing.expect(text[0] == 'x');
}

test "WindowsBackend advertises registered targets and routes policy to its window" {
    var win = MockWindow{ .drag_ready = true };
    var sdk = try WindowsBackend.initSystemSdk(std.testing.allocator, &win, 15);
    defer sdk.deinit();
    try std.testing.expect(sdk.capabilities.drag_drop_target and !sdk.capabilities.drag_source);
    try sdk.setDragTargetOperations(15, .{ .move = true, .link = true });
    try std.testing.expectEqual(@as(u8, 6), win.drag_operations);
    try std.testing.expectError(SdkError.InvalidState, sdk.setDragTargetOperations(16, .{ .copy = true }));
    try sdk.setDragTargetOperations(15, .{});
    try std.testing.expectEqual(@as(u8, 0), win.drag_operations);
}

test "WindowsBackend maps source errors and emits trusted completion with token" {
    var win = MockWindow{ .drag_ready = true, .source_ready = true };
    var sdk = try WindowsBackend.initSystemSdk(std.testing.allocator, &win, 17);
    defer sdk.deinit();
    const request = backend_mod.DragRequest{ .payload_kind = .text, .payload = "source" };
    try std.testing.expectError(SdkError.InvalidState, sdk.beginDrag(18, request));
    try std.testing.expectEqual(@as(u32, 0), win.source_starts);
    try std.testing.expectError(SdkError.InvalidState, sdk.beginDrag(17, request));
    win.source_error = -2;
    try std.testing.expectError(SdkError.OutOfMemory, sdk.beginDrag(17, request));
    win.source_error = -3;
    try std.testing.expectError(SdkError.BackendFailure, sdk.beginDrag(17, request));
    win.source_error = 0;
    const token = try sdk.beginDrag(17, request);
    try std.testing.expectEqual(@as(u64, 987654321), token);
    _ = try sdk.pump(0);
    _ = try sdk.pump(0);
    win.drag_pending = true;
    win.source_token = token;
    _ = try sdk.pump(0);
    const event = sdk.events()[0].drag;
    try std.testing.expectEqual(token, event.source_token);
    try std.testing.expectEqual(@as(u8, 4), event.kind);
    try std.testing.expectEqual(@as(u8, 0), event.operation);
    try std.testing.expect(!event.payload_is_untrusted);
    try std.testing.expectEqual(@as(u32, 1), win.drag_consumed);
}

test "WindowsBackend keeps pointer cancellation ordered and retries it on OOM" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var win = MockWindow{ .cancel_pending = true };
    var sdk = try WindowsBackend.initSystemSdk(allocator.allocator(), &win, 15);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    _ = try sdk.pump(0);
    try std.testing.expect(!sdk.events()[3].mouse_button.cancelled);
    try std.testing.expect(sdk.events()[4].mouse_button.cancelled);
    try std.testing.expect(sdk.events()[5] == .key);
    sdk.event_queue.list.clearAndFree(sdk.event_queue.allocator);
    win.frame = 1;
    win.cancel_pending = true;
    allocator.fail_index = allocator.alloc_index;
    try std.testing.expectError(SdkError.OutOfMemory, sdk.pump(0));
    try std.testing.expect(win.cancel_pending);
    allocator.fail_index = std.math.maxInt(usize);
    win.frame = 1;
    _ = try sdk.pump(0);
    try std.testing.expect(!win.cancel_pending);
    try std.testing.expectEqual(@as(usize, 1), sdk.events().len);
    try std.testing.expect(sdk.events()[0].mouse_button.cancelled);
    try std.testing.expectEqual(@as(WindowId, 15), sdk.events()[0].targetWindowId().?);
}

test "WindowsBackend does not sample the final mouse position before queued down and retries moves on OOM" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var win = MockWindow{ .move_after_button = true };
    var sdk = try WindowsBackend.initSystemSdk(allocator.allocator(), &win, 16);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    _ = try sdk.pump(0);
    try std.testing.expect(sdk.events()[2] == .mouse_button);
    try std.testing.expect(sdk.events()[3] == .mouse_move);
    try std.testing.expectEqual(@as(f32, 2), sdk.events()[3].mouse_move.dx);
    try std.testing.expectEqual(@as(f32, 4), sdk.events()[3].mouse_move.dy);
    try std.testing.expect(sdk.events()[3].mouse_move.modifiers.shift);
    try std.testing.expect(sdk.events()[4] == .key);
    sdk.event_queue.list.clearAndFree(sdk.event_queue.allocator);
    win.frame = 1;
    win.move_pending = true;
    allocator.fail_index = allocator.alloc_index;
    try std.testing.expectError(SdkError.OutOfMemory, sdk.pump(0));
    try std.testing.expect(win.move_pending);
    allocator.fail_index = std.math.maxInt(usize);
    win.frame = 1;
    _ = try sdk.pump(0);
    try std.testing.expect(!win.move_pending);
    try std.testing.expectEqual(@as(usize, 1), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .mouse_move);
}

test "WindowsBackend reports WM_MOUSELEAVE as pointer_left in input order, not as a move" {
    var win = MockWindow{ .leave_pending = true };
    var sdk = try WindowsBackend.initSystemSdk(std.testing.allocator, &win, 17);
    defer sdk.deinit();
    _ = try sdk.pump(0);
    _ = try sdk.pump(0);
    var left_at: ?usize = null;
    var button_at: ?usize = null;
    for (sdk.events(), 0..) |event, i| switch (event) {
        .pointer_left => |e| {
            try std.testing.expectEqual(@as(WindowId, 17), e.window_id);
            try std.testing.expect(left_at == null);
            left_at = i;
        },
        .mouse_button => if (button_at == null) {
            button_at = i;
        },
        else => {},
    };
    try std.testing.expect(left_at != null and button_at != null and left_at.? < button_at.?);
    try std.testing.expect(!win.leave_pending);
}

test "WindowsBackend cursor routes by window, rejects unsupported shapes and propagates native rejection" {
    var win = MockWindow{};
    var sdk = try WindowsBackend.initSystemSdk(std.testing.allocator, &win, 17);
    defer sdk.deinit();
    try std.testing.expect(sdk.capabilities.cursor and !sdk.customCursorSupported());
    try sdk.setCursorShape(17, 3);
    try std.testing.expectEqual(@as(u8, 3), win.cursor_shape);
    try std.testing.expectError(SdkError.InvalidState, sdk.setCursorShape(18, 2));
    try std.testing.expectError(SdkError.InvalidState, sdk.setCursorShape(17, 255));
    try std.testing.expectError(SdkError.NotSupported, sdk.setCursorShape(17, 19));
    try std.testing.expectEqual(@as(u8, 3), win.cursor_shape);
    win.cursor_accept = false;
    try std.testing.expectError(SdkError.InvalidState, sdk.setCursorShape(17, 2));
    try std.testing.expectEqual(@as(u8, 3), win.cursor_shape);
    win.cursor_accept = true;
    try sdk.setCursorShape(17, 18);
    try sdk.setCursorShape(17, 20);
    try std.testing.expectEqual(@as(u8, 20), win.cursor_shape);
}
