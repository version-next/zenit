const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const system_sdk = @import("../system_sdk.zig");
const platform = @import("platform");
const Window = platform.Window;

const events = system_sdk.events;
const backend = system_sdk.vtable;
const capabilities_mod = system_sdk.capabilities;
const accessibility_mod = system_sdk.accessibility;
const SdkError = system_sdk.SdkError;

// Internal C bridge tags remain stable when public enum declarations evolve.
fn hapticBridgeTag(pattern: backend.HapticFeedbackPattern) c_int {
    return switch (pattern) {
        .alignment => 0,
        .generic => 1,
        .level_change => 2,
    };
}

test "haptic bridge tags preserve alignment and distinguish semantic patterns" {
    try std.testing.expectEqual(@as(c_int, 0), hapticBridgeTag(.alignment));
    try std.testing.expectEqual(@as(c_int, 1), hapticBridgeTag(.generic));
    try std.testing.expectEqual(@as(c_int, 2), hapticBridgeTag(.level_change));
}

fn utf8PrefixLength(text: []const u8, max_len: usize) usize {
    const limit = @min(text.len, max_len);
    var offset: usize = 0;
    while (offset < limit) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return offset;
        const end = offset + sequence_len;
        if (end > limit) return offset;
        _ = std.unicode.utf8Decode(text[offset..end]) catch return offset;
        offset = end;
    }
    return offset;
}

test "utf8PrefixLength never splits a scalar" {
    try std.testing.expectEqual(@as(usize, 1), utf8PrefixLength("a€b", 2));
    try std.testing.expectEqual(@as(usize, 4), utf8PrefixLength("a€b", 4));
    try std.testing.expectEqual(@as(usize, 5), utf8PrefixLength("a€b", 8));
}

extern fn macos_perform_haptic_feedback(pattern: c_int) c_int;
extern fn macos_clipboard_set_text(text: [*]const u8, len: c_int) c_int;
extern fn macos_clipboard_get_text(buffer: [*]u8, buffer_size: c_int) c_int;
extern fn macos_clipboard_get_text_len() c_int;
extern fn macos_clipboard_set_rich_text(text: [*]const u8, text_len: c_int, html: ?[*]const u8, html_len: c_int) c_int;
extern fn macos_clipboard_get_html(buffer: [*]u8, buffer_size: c_int) c_int;
extern fn macos_clipboard_get_html_len() c_int;
extern fn macos_clipboard_probe() u32;
extern fn macos_clipboard_image_count() u32;
extern fn macos_clipboard_read_image(index: u32, out_width: *u32, out_height: *u32) ?[*]u8;
extern fn macos_clipboard_set_image_png(bytes: [*]const u8, len: usize) c_int;
extern fn macos_clipboard_read_image_bytes(index: u32, out_len: *usize, uti_buf: ?[*]u8, uti_buf_len: usize) ?[*]u8;
extern fn macos_free_image_data(data: [*]u8) void;
extern fn macos_pick_folder(path_buffer: [*]u8, buffer_size: c_int) c_int;
extern fn macos_open_file_panel(path_buffer: [*]u8, buffer_size: c_int) c_int;
extern fn macos_save_panel(suggested_name: ?[*:0]const u8, default_directory: ?[*:0]const u8, path_buffer: [*]u8, buffer_size: c_int) c_int;
extern fn macos_accessibility_announce(window_ptr: *anyopaque, text: [*]const u8, len: c_int) c_int;
extern fn macos_accessibility_notify_focus(
    window_ptr: *anyopaque,
    role: c_int,
    label: [*]const u8,
    label_len: c_int,
    description: [*]const u8,
    description_len: c_int,
    value_text: [*]const u8,
    value_text_len: c_int,
    checked: c_int,
    expanded: c_int,
    disabled: c_int,
) c_int;
extern fn macos_accessibility_notify_property_change(
    window_ptr: *anyopaque,
    role: c_int,
    label: [*]const u8,
    label_len: c_int,
    description: [*]const u8,
    description_len: c_int,
    value_text: [*]const u8,
    value_text_len: c_int,
    checked: c_int,
    expanded: c_int,
    disabled: c_int,
) c_int;
extern fn macos_menu_begin() c_int;
extern fn macos_menu_add_menu(id: u64, parent_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn macos_menu_add_item(
    id: u64,
    parent_id: u64,
    label: [*]const u8,
    label_len: usize,
    key: [*]const u8,
    key_len: usize,
    modifiers: u8,
    role: u8,
    command_id: u64,
    enabled: c_int,
    checked: c_int,
) c_int;
extern fn macos_menu_add_separator(parent_id: u64) c_int;
extern fn macos_menu_commit() c_int;
extern fn macos_menu_discard_window_commands(window_id: u64) void;
extern fn macos_menu_poll_command(out_window_id: *u64, out_command_id: *u64) c_int;
extern fn macos_begin_drag(
    window_ptr: *anyopaque,
    token: u64,
    payload_kind: u8,
    payload: [*]const u8,
    payload_len: usize,
    allowed_operations: u8,
    preview_png: ?[*]const u8,
    preview_png_len: usize,
    preview_width: f32,
    preview_height: f32,
    hotspot_x: f32,
    hotspot_y: f32,
) c_int;
extern fn macos_set_drag_target_operations(window_ptr: *anyopaque, operations: u8) c_int;
extern fn macos_set_custom_cursor(
    window_ptr: *anyopaque,
    rgba: [*]const u8,
    len: usize,
    width: u32,
    height: u32,
    scale: f32,
    hot_x: f32,
    hot_y: f32,
    key: u64,
) void;

const GlobalEventSource = struct {
    fn appShouldQuit(_: *@This()) bool {
        return Window.appShouldQuit();
    }
    fn consumeAppBecameActive(_: *@This()) bool {
        return Window.consumeAppBecameActive();
    }
    fn isDarkMode(_: *@This()) bool {
        return Window.isDarkMode();
    }
    fn pollMenu(_: *@This(), window_id: *u64, command_id: *u64) bool {
        return macos_menu_poll_command(window_id, command_id) != 0;
    }
};

/// Native AppKit input is stored in separate queues for ABI simplicity. Keep
/// the original dispatch sequence beside each event so draining those queues
/// does not group input by type during a slow frame.
const OrderedNativeEvent = struct {
    sequence: u64,
    event: events.Event,
    owned_text: ?[]const u8 = null,

    fn deinit(self: *OrderedNativeEvent, allocator: Allocator) void {
        if (self.owned_text) |text| allocator.free(text);
        self.owned_text = null;
    }
};

/// Reserve the destination before the native reader can consume its head.
/// The returned text allocation belongs to the pending batch, not the window.
fn collectTextEvents(allocator: Allocator, window: anytype, window_id: events.WindowId, ordered: *std.ArrayList(OrderedNativeEvent)) !usize {
    var count: usize = 0;
    inline for (.{ Window.TextEventKind.preedit, Window.TextEventKind.commit, Window.TextEventKind.input }) |kind| {
        while (true) {
            try ordered.ensureUnusedCapacity(allocator, 1);
            const packet = try window.readTextEventAllocChecked(allocator, kind) orelse break;
            const event: events.Event = switch (kind) {
                .preedit => .{ .ime_preedit = .{ .window_id = window_id, .text = packet.text, .cursor_utf8_offset = packet.cursor_utf8_offset, .replace_start_utf8 = packet.replace_start_utf8, .replace_end_utf8 = packet.replace_end_utf8 } },
                .commit => .{ .ime_commit = .{ .window_id = window_id, .text = packet.text, .replace_start_utf8 = packet.replace_start_utf8, .replace_end_utf8 = packet.replace_end_utf8 } },
                .input => .{ .text_input = .{ .window_id = window_id, .text = packet.text } },
            };
            ordered.appendAssumeCapacity(.{ .sequence = packet.sequence, .event = event, .owned_text = packet.text });
            count += 1;
        }
    }
    return count;
}

/// Prepare a complete owned delivery before changing the SDK queue. On failure
/// the backend's pending batch can be retried without dropping or duplicating
/// its successfully dequeued native events.
fn appendOrderedBatchChecked(queue: *events.EventQueue, ordered: []const OrderedNativeEvent) !void {
    var prepared = events.EventQueue.init(queue.allocator);
    defer prepared.deinit();
    for (ordered) |item| try prepared.push(item.event);
    try queue.list.ensureUnusedCapacity(queue.allocator, prepared.list.items.len);
    try queue.owned_payloads.ensureUnusedCapacity(queue.allocator, prepared.owned_payloads.items.len);
    queue.list.appendSliceAssumeCapacity(prepared.list.items);
    queue.owned_payloads.appendSliceAssumeCapacity(prepared.owned_payloads.items);
    prepared.owned_payloads.clearRetainingCapacity();
}

/// EventQueue owns a full copy before native consumption. A failed push
/// leaves the native head untouched; an invalid consume rolls back only this
/// event, preserving earlier successful deliveries in the current pump.
fn collectDragEvents(queue: *events.EventQueue, window: anytype, window_id: events.WindowId) !void {
    while (try window.peekDragEventChecked()) |pending| {
        const drag = pending.event;
        const old_len = queue.list.items.len;
        const old_payload_len = queue.owned_payloads.items.len;
        try queue.push(.{ .drag = .{
            .window_id = window_id,
            .x = drag.x,
            .y = drag.y,
            .kind = drag.kind,
            .paths = drag.paths,
            .payload_kind = drag.payload_kind,
            .source_token = drag.source_token,
            .operation = drag.operation,
            .payload_truncated = drag.paths_truncated,
            .payload_is_untrusted = drag.kind != 4,
        } });
        window.consumeDragEventChecked(pending.token) catch |err| {
            for (queue.owned_payloads.items[old_payload_len..]) |payload| queue.allocator.free(payload);
            queue.owned_payloads.items.len = old_payload_len;
            queue.list.items.len = old_len;
            return err;
        };
    }
}

fn sortOrderedNativeEvents(items: []OrderedNativeEvent) void {
    std.mem.sort(OrderedNativeEvent, items, {}, struct {
        fn lessThan(_: void, lhs: OrderedNativeEvent, rhs: OrderedNativeEvent) bool {
            return lhs.sequence < rhs.sequence;
        }
    }.lessThan);
}

fn nativeSequenceRegressed(previous: u64, current: u64) bool {
    return previous != 0 and current <= previous;
}

test "native input queues merge by original cross-type sequence" {
    var items = [_]OrderedNativeEvent{
        .{ .sequence = 40, .event = .{ .key = .{ .window_id = 1, .keycode = 0, .pressed = true } } },
        .{ .sequence = 10, .event = .{ .mouse_button = .{ .window_id = 1, .x = 1, .y = 2, .button = .left, .pressed = true } } },
        .{ .sequence = 30, .event = .{ .magnify = .{ .window_id = 1, .x = 1, .y = 2, .magnification = 0.1, .phase = 1 } } },
        .{ .sequence = 20, .event = .{ .mouse_wheel = .{ .window_id = 1, .x = 1, .y = 2, .dx = 0, .dy = 3 } } },
    };

    sortOrderedNativeEvents(&items);

    const EventTag = std.meta.Tag(events.Event);
    try std.testing.expectEqual(@as(u64, 10), items[0].sequence);
    try std.testing.expectEqual(EventTag.mouse_button, std.meta.activeTag(items[0].event));
    try std.testing.expectEqual(@as(u64, 20), items[1].sequence);
    try std.testing.expectEqual(EventTag.mouse_wheel, std.meta.activeTag(items[1].event));
    try std.testing.expectEqual(@as(u64, 30), items[2].sequence);
    try std.testing.expectEqual(EventTag.magnify, std.meta.activeTag(items[2].event));
    try std.testing.expectEqual(@as(u64, 40), items[3].sequence);
    try std.testing.expectEqual(EventTag.key, std.meta.activeTag(items[3].event));
}

test "text and IME packets join the same native sequence" {
    const input = Window.TextInputEvent{ .sequence = 30, .text = "a" };
    const preedit = Window.ImePreeditEvent{ .sequence = 20, .text = "あ", .cursor_utf8_offset = 3 };
    const commit = Window.ImeCommitEvent{ .sequence = 40, .text = "亜" };
    var items = [_]OrderedNativeEvent{
        .{ .sequence = commit.sequence, .event = .{ .ime_commit = .{ .window_id = 1, .text = commit.text } } },
        .{ .sequence = input.sequence, .event = .{ .text_input = .{ .window_id = 1, .text = input.text } } },
        .{ .sequence = 10, .event = .{ .key = .{ .window_id = 1, .keycode = 0, .pressed = true } } },
        .{ .sequence = preedit.sequence, .event = .{ .ime_preedit = .{ .window_id = 1, .text = preedit.text, .cursor_utf8_offset = preedit.cursor_utf8_offset } } },
    };

    sortOrderedNativeEvents(&items);

    const EventTag = std.meta.Tag(events.Event);
    try std.testing.expectEqual(EventTag.key, std.meta.activeTag(items[0].event));
    try std.testing.expectEqual(EventTag.ime_preedit, std.meta.activeTag(items[1].event));
    try std.testing.expectEqual(EventTag.text_input, std.meta.activeTag(items[2].event));
    try std.testing.expectEqual(EventTag.ime_commit, std.meta.activeTag(items[3].event));
}

test "native mouse motion keeps its position between discrete events" {
    const move = Window.MouseMoveEvent{
        .sequence = 20,
        .x = 12,
        .y = 34,
        .dx = 2,
        .dy = -1,
        .modifiers = .{},
    };
    var items = [_]OrderedNativeEvent{
        .{ .sequence = 30, .event = .{ .mouse_button = .{ .window_id = 1, .x = 12, .y = 34, .button = .left, .pressed = true } } },
        .{ .sequence = move.sequence, .event = .{ .mouse_move = .{ .window_id = 1, .x = move.x, .y = move.y, .dx = move.dx, .dy = move.dy } } },
        .{ .sequence = 10, .event = .{ .key = .{ .window_id = 1, .keycode = 0, .pressed = true } } },
    };

    sortOrderedNativeEvents(&items);

    const EventTag = std.meta.Tag(events.Event);
    try std.testing.expectEqual(EventTag.key, std.meta.activeTag(items[0].event));
    try std.testing.expectEqual(EventTag.mouse_move, std.meta.activeTag(items[1].event));
    try std.testing.expectEqual(@as(f32, 2), items[1].event.mouse_move.dx);
    try std.testing.expectEqual(EventTag.mouse_button, std.meta.activeTag(items[2].event));
}

test "application input order is independent of window slot order" {
    var items = [_]OrderedNativeEvent{
        .{ .sequence = 20, .event = .{ .key = .{ .window_id = 1, .keycode = 1, .pressed = true } } },
        .{ .sequence = 10, .event = .{ .key = .{ .window_id = 2, .keycode = 2, .pressed = true } } },
        .{ .sequence = 30, .event = .{ .mouse_button = .{ .window_id = 2, .x = 0, .y = 0, .button = .left, .pressed = true } } },
    };

    sortOrderedNativeEvents(&items);

    try std.testing.expectEqual(@as(events.WindowId, 2), items[0].event.targetWindowId().?);
    try std.testing.expectEqual(@as(events.WindowId, 1), items[1].event.targetWindowId().?);
    try std.testing.expectEqual(@as(events.WindowId, 2), items[2].event.targetWindowId().?);
    try std.testing.expect(!nativeSequenceRegressed(0, 1));
    try std.testing.expect(!nativeSequenceRegressed(1, 2));
    try std.testing.expect(nativeSequenceRegressed(2, 2));
    try std.testing.expect(nativeSequenceRegressed(3, 2));
}

/// Per-window 状态追踪
const WindowEntry = struct {
    window: Window,
    window_id: events.WindowId,
    native_window_id: u64 = 0,
    last_focused: bool = false,

    last_width: u32 = 0,
    last_height: u32 = 0,
    last_scale: f32 = 1.0,

    has_last_mouse: bool = false,
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,

    left_down: bool = false,
    right_down: bool = false,
    middle_down: bool = false,

    collected_text_count: usize = 0,
    fn initFromWindow(window: *Window, window_id: events.WindowId) WindowEntry {
        const size = window.getSize();
        const pos = window.getMousePosition();
        return .{
            .window = window.*,
            .window_id = window_id,
            .native_window_id = window.getWindowId(),
            .last_focused = window.isFocused(),
            .last_width = size[0],
            .last_height = size[1],
            .last_scale = window.getScaleFactor(),
            .has_last_mouse = true,
            .last_mouse_x = pos[0],
            .last_mouse_y = pos[1],
        };
    }

    /// Collect every native event carrying an application-wide sequence.
    /// Dispatch is deferred until all windows have contributed.
    fn collectSequencedEvents(
        self: *WindowEntry,
        allocator: Allocator,
        ordered_native_events: *std.ArrayList(OrderedNativeEvent),
        debug_input: bool,
        pump_seq: u64,
    ) SdkError!void {
        const wid = self.window_id;
        self.collected_text_count = 0;

        // 尺寸变化
        const size = self.window.getSize();
        const scale = self.window.getScaleFactor();
        if (size[0] != self.last_width or size[1] != self.last_height or scale != self.last_scale) {
            try ordered_native_events.append(allocator, .{ .sequence = 0, .event = .{
                .window_resized = .{
                    .window_id = wid,
                    .width = size[0],
                    .height = size[1],
                    .scale_factor = scale,
                },
            } });
            self.last_width = size[0];
            self.last_height = size[1];
            self.last_scale = scale;
        }

        // Native mouse moved/dragged packets preserve every motion relative
        // to key/button/text events. The bridge may coalesce only adjacent
        // moves after its explicit pressure threshold.
        while (true) {
            try ordered_native_events.ensureUnusedCapacity(allocator, 1);
            const move = self.window.getMouseMoveEvent() orelse break;
            ordered_native_events.appendAssumeCapacity(.{
                .sequence = move.sequence,
                .event = .{ .mouse_move = .{
                    .window_id = wid,
                    .x = move.x,
                    .y = move.y,
                    .dx = move.dx,
                    .dy = move.dy,
                    .modifiers = MacOSBackend.toModifiers(move.modifiers),
                } },
            });
            self.last_mouse_x = move.x;
            self.last_mouse_y = move.y;
            self.has_last_mouse = true;
            if (debug_input) {
                std.debug.print(
                    "[sdk-input] frame={d} native_seq={d} wid={d} mouse_move x={d:.1} y={d:.1} dx={d:.1} dy={d:.1}\n",
                    .{ pump_seq, move.sequence, wid, move.x, move.y, move.dx, move.dy },
                );
            }
        }

        // 鼠标按键队列
        while (true) {
            try ordered_native_events.ensureUnusedCapacity(allocator, 1);
            const btn_evt = self.window.getMouseButtonEvent() orelse break;
            const btn = switch (btn_evt.button) {
                .left => events.MouseButton.left,
                .right => events.MouseButton.right,
                .middle => events.MouseButton.middle,
                .other => events.MouseButton.other,
            };
            ordered_native_events.appendAssumeCapacity(.{
                .sequence = btn_evt.sequence,
                .event = .{
                    .mouse_button = .{
                        .window_id = wid,
                        .x = btn_evt.x,
                        .y = btn_evt.y,
                        .button = btn,
                        .pressed = btn_evt.pressed,
                        // 修饰键必须随指针事件一起送：⇧ 加选 / ⌘ 深选 / ctrl 框选
                        // 都发生在 mouse_down 那一刻，事后从键盘状态推断不可靠。
                        .modifiers = blk: {
                            const m = platform.Modifiers.fromRaw(btn_evt.modifiers);
                            break :blk .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.cmd };
                        },
                    },
                },
            });
            switch (btn_evt.button) {
                .left => self.left_down = btn_evt.pressed,
                .right => self.right_down = btn_evt.pressed,
                .middle => self.middle_down = btn_evt.pressed,
                // 侧键等其他按钮不参与按下态跟踪（事件本身照常派发）
                .other => {},
            }
            if (debug_input) {
                std.debug.print(
                    "[sdk-input] frame={d} native_seq={d} wid={d} mouse_button btn={} pressed={} x={d:.1} y={d:.1}\n",
                    .{
                        pump_seq,
                        btn_evt.sequence,
                        wid,
                        btn_evt.button,
                        btn_evt.pressed,
                        btn_evt.x,
                        btn_evt.y,
                    },
                );
            }
        }

        // 滚轮队列: 每帧 drain，避免触控板/滚轮事件在原生队列中积压
        while (true) {
            try ordered_native_events.ensureUnusedCapacity(allocator, 1);
            const scroll = self.window.getScrollDelta() orelse break;
            ordered_native_events.appendAssumeCapacity(.{
                .sequence = scroll.sequence,
                .event = .{ .mouse_wheel = .{
                    .window_id = wid,
                    .x = scroll.x,
                    .y = scroll.y,
                    .dx = scroll.dx,
                    .dy = scroll.dy,
                    .phase = @enumFromInt(scroll.phase),
                    .momentum = @enumFromInt(scroll.momentum),
                    .modifiers = MacOSBackend.toModifiers(scroll.modifiers),
                } },
            });
            if (debug_input) {
                std.debug.print(
                    "[sdk-input] frame={d} native_seq={d} wid={d} wheel dx={d:.2} dy={d:.2} x={d:.1} y={d:.1}\n",
                    .{ pump_seq, scroll.sequence, wid, scroll.dx, scroll.dy, scroll.x, scroll.y },
                );
            }
        }

        // 捏合手势队列: 每帧 drain
        while (true) {
            try ordered_native_events.ensureUnusedCapacity(allocator, 1);
            const mag = self.window.getMagnifyEvent() orelse break;
            ordered_native_events.appendAssumeCapacity(.{
                .sequence = mag.sequence,
                .event = .{ .magnify = .{
                    .window_id = wid,
                    .x = mag.x,
                    .y = mag.y,
                    .magnification = mag.magnification,
                    .phase = mag.phase,
                } },
            });
        }

        // 按键队列: 每帧 drain，避免按键按下/抬起落后一帧甚至多帧
        while (true) {
            try ordered_native_events.ensureUnusedCapacity(allocator, 1);
            const ke = self.window.getKeyEvent() orelse break;
            ordered_native_events.appendAssumeCapacity(.{
                .sequence = ke.sequence,
                .event = .{ .key = .{
                    .window_id = wid,
                    .keycode = ke.keycode,
                    .pressed = ke.pressed,
                    .modifiers = MacOSBackend.toModifiers(ke.modifiers),
                } },
            });
            if (debug_input) {
                std.debug.print(
                    "[sdk-input] frame={d} native_seq={d} key code={d} pressed={} mods[s:{} c:{} a:{} sup:{}]\n",
                    .{
                        pump_seq,
                        ke.sequence,
                        ke.keycode,
                        ke.pressed,
                        ke.modifiers.shift,
                        ke.modifiers.ctrl,
                        ke.modifiers.alt,
                        ke.modifiers.cmd,
                    },
                );
            }
        }

        self.collected_text_count = try collectTextEvents(allocator, &self.window, wid, ordered_native_events);
    }

    /// Events without a native application sequence are emitted only after
    /// the backend has merged and dispatched every window's sequenced input.
    fn collectPostSequenceEvents(self: *WindowEntry, queue: *events.EventQueue) SdkError!void {
        const wid = self.window_id;

        try collectDragEvents(queue, &self.window, wid);

        // Native motion is queued; this sample is only a fallback for
        // programmatic/out-of-stream position changes at the pump boundary.
        const mouse_pos = self.window.getMousePosition();
        const mx = mouse_pos[0];
        const my = mouse_pos[1];
        if (!self.has_last_mouse or mx != self.last_mouse_x or my != self.last_mouse_y) {
            try queue.push(.{
                .mouse_move = .{
                    .window_id = wid,
                    .x = mx,
                    .y = my,
                    .dx = if (self.has_last_mouse) mx - self.last_mouse_x else 0,
                    .dy = if (self.has_last_mouse) my - self.last_mouse_y else 0,
                    // Sampled movement has no event-level flags; use the
                    // current hardware modifiers at this pump boundary.
                    .modifiers = blk: {
                        const m = platform.Window.currentModifiers();
                        break :blk .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.cmd };
                    },
                },
            });
            self.last_mouse_x = mx;
            self.last_mouse_y = my;
            self.has_last_mouse = true;
        }
    }

    /// 同步鼠标状态（liveResize 后调用）
    fn syncInputState(self: *WindowEntry) void {
        while (self.window.getMouseButtonEvent()) |btn_evt| {
            switch (btn_evt.button) {
                .left => self.left_down = btn_evt.pressed,
                .right => self.right_down = btn_evt.pressed,
                .middle => self.middle_down = btn_evt.pressed,
                // 侧键等其他按钮不参与按下态跟踪（事件本身照常派发）
                .other => {},
            }
        }
        const pos = self.window.getMousePosition();
        self.last_mouse_x = pos[0];
        self.last_mouse_y = pos[1];
    }
};

pub const MAX_WINDOWS = 8;

pub const MacOSBackend = struct {
    allocator: Allocator,

    /// 多窗口数组
    windows: [MAX_WINDOWS]?WindowEntry = [_]?WindowEntry{null} ** MAX_WINDOWS,
    window_count: u8 = 0,
    ordered_native_events: std.ArrayList(OrderedNativeEvent) = .{},
    native_collection_pending: bool = false,
    post_collection_pending: bool = false,
    global_collection_pending: bool = false,
    pending_app_activation: bool = false,
    native_batch_complete: bool = false,
    last_dispatched_native_sequence: u64 = 0,
    input_sequence_regressions: u64 = 0,
    last_mouse_move_coalesced: u64 = 0,
    last_ime_preedit_coalesced: u64 = 0,
    staged_text_high_water: usize = 0,

    debug_input: bool = false,
    pump_seq: u64 = 0,
    next_drag_token: u64 = 1,

    /// 上一帧的系统主题状态（用于检测变化）
    last_is_dark: ?bool = null,

    pub fn create(
        allocator: Allocator,
        window: *Window,
        window_id: events.WindowId,
    ) !*MacOSBackend {
        const debug_input = readDebugFlag(allocator);
        const backend_ctx = try allocator.create(MacOSBackend);
        backend_ctx.* = .{
            .allocator = allocator,
            .debug_input = debug_input,
        };
        // 注册第一个窗口
        backend_ctx.windows[0] = WindowEntry.initFromWindow(window, window_id);
        backend_ctx.window_count = 1;

        return backend_ctx;
    }

    pub fn initSystemSdk(
        allocator: Allocator,
        window: *Window,
        window_id: events.WindowId,
    ) !system_sdk.SystemSdk {
        if (builtin.target.os.tag != .macos) {
            return SdkError.NotSupported;
        }

        const backend_ctx = try create(allocator, window, window_id);
        try capabilities_mod.validateAdvertised(CAPS, vtable);
        return system_sdk.SystemSdk.init(allocator, backend_ctx, &vtable, CAPS);
    }

    pub const CAPS = capabilities_mod.Capabilities{
        .clipboard = true,
        .clipboard_image = true,
        .file_dialog = true,
        .request_redraw = true,
        .raw_window_handle = true,
        .multi_window = true,
        .ime = true,
        .cursor = true,
        .accessibility = true,
        .drag_drop_target = true,
        .drag_source = true,
        .menu_bar = true,
        .haptic_feedback = true,
    };

    pub const vtable = backend.BackendVTable{
        .name = "macos-native",
        .deinit = deinitImpl,
        .pump_events = pumpEventsImpl,
        .request_redraw = requestRedrawImpl,
        .perform_haptic_feedback = performHapticFeedbackImpl,
        .sync_input_state = syncInputStateImpl,
        .clipboard = .{
            .set_text = clipboardSetTextImpl,
            .get_text = clipboardGetTextImpl,
            .get_text_len = clipboardGetTextLenImpl,
            .probe = clipboardProbeImpl,
            .image_count = clipboardImageCountImpl,
            .get_image = clipboardGetImageImpl,
            .set_image_png = clipboardSetImagePngImpl,
            .set_rich_text = clipboardSetRichTextImpl,
            .get_html_len = clipboardGetHtmlLenImpl,
            .get_html = clipboardGetHtmlImpl,
        },
        .dialog = .{
            .run = dialogRunImpl,
        },
        .ime = .{
            .set_enabled = imeSetEnabledImpl,
            .set_cursor_rect = imeSetCursorRectImpl,
            .discard = imeDiscardImpl,
        },
        .cursor = .{
            .set_shape = cursorSetShapeImpl,
            .set_custom = cursorSetCustomImpl,
        },
        .accessibility = .{
            .announce_text = accessibilityAnnounceImpl,
            .notify_focus = accessibilityNotifyFocusImpl,
            .notify_property_change = accessibilityNotifyPropertyChangeImpl,
        },
        .menu = .{ .set_model = menuSetModelImpl },
        .drag_source = .{ .start = dragStartImpl },
        .drag_target = .{ .set_allowed_operations = dragTargetSetOperationsImpl },
        .raw_window_handle = rawWindowHandleImpl,
        .register_window = registerWindowImpl,
        .unregister_window = unregisterWindowImpl,
    };

    fn deinitImpl(ctx: *anyopaque, allocator: Allocator) void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        for (self.ordered_native_events.items) |*event| event.deinit(allocator);
        self.ordered_native_events.deinit(allocator);
        allocator.destroy(self);
    }

    fn pumpEventsImpl(
        ctx: *anyopaque,
        queue: *events.EventQueue,
        timeout_ms: u32,
    ) SdkError!backend.PumpResult {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        self.pump_seq +%= 1;
        if (self.post_collection_pending) {
            _ = try self.resumePostCollection(queue);
            return .{ .should_continue = true, .requested_redraw = true };
        }
        if (self.native_collection_pending or self.native_batch_complete) {
            if (try self.resumeNativeBatch(queue)) _ = try self.resumePostCollection(queue);
            return .{ .should_continue = true, .requested_redraw = true };
        }

        // A failed global phase must finish before interpreting later input.
        if (!self.global_collection_pending) {
            // 1. 驱动 NSApp 事件泵（支持阻塞等待，空闲时不 busy-loop）
            Window.pumpAppEventsTimeout(timeout_ms);
            const input_metrics = Window.inputQueueMetrics();
            if (self.debug_input and
                (input_metrics.mouse_move_coalesced != self.last_mouse_move_coalesced or
                    input_metrics.ime_preedit_coalesced != self.last_ime_preedit_coalesced))
            {
                std.debug.print(
                    "[sdk-input] frame={d} queue_pressure mouse_move_coalesced={d} ime_preedit_coalesced={d}\n",
                    .{
                        self.pump_seq,
                        input_metrics.mouse_move_coalesced,
                        input_metrics.ime_preedit_coalesced,
                    },
                );
            }
            self.last_mouse_move_coalesced = input_metrics.mouse_move_coalesced;
            self.last_ime_preedit_coalesced = input_metrics.ime_preedit_coalesced;
        }

        var source: GlobalEventSource = .{};
        const global = try self.resumeGlobalCollection(queue, &source) orelse
            return .{ .should_continue = true, .requested_redraw = true };
        if (!global.should_continue) return global;

        if (!try self.resumeNativeBatch(queue)) return .{ .should_continue = true, .requested_redraw = true };

        if (!try self.resumePostCollection(queue)) return .{ .should_continue = true, .requested_redraw = true };

        return .{
            .should_continue = true,
            .requested_redraw = global.requested_redraw,
        };
    }

    fn resumeGlobalCollection(self: *MacOSBackend, queue: *events.EventQueue, source: anytype) SdkError!?backend.PumpResult {
        self.global_collection_pending = true;
        return self.collectGlobalEvents(queue, source) catch |err| {
            if (err != error.OutOfMemory) return err;
            // Preserve successful earlier deliveries and retry before AppKit.
            std.Thread.sleep(16 * std.time.ns_per_ms);
            return null;
        };
    }

    fn collectGlobalEvents(self: *MacOSBackend, queue: *events.EventQueue, source: anytype) SdkError!backend.PumpResult {
        if (source.appShouldQuit()) {
            try queue.push(.{ .quit = {} });
            self.global_collection_pending = false;
            return .{ .should_continue = false, .requested_redraw = false };
        }
        self.pending_app_activation = source.consumeAppBecameActive() or self.pending_app_activation;
        while (true) {
            // Menu events own no payload. Reserving here leaves no fallible
            // operation between native dequeue and SDK publication.
            try queue.list.ensureUnusedCapacity(queue.allocator, 1);
            var window_id: u64 = 0;
            var command_id: u64 = 0;
            if (!source.pollMenu(&window_id, &command_id)) break;
            // A window-scoped command must not fall back to a different window.
            const logical_id = if (window_id == 0) 0 else self.logicalWindowIdForNative(window_id) orelse continue;
            queue.list.appendAssumeCapacity(.{ .menu_command = .{ .window_id = logical_id, .command_id = command_id } });
        }
        const is_dark = source.isDarkMode();
        if (self.last_is_dark == null or self.last_is_dark.? != is_dark) {
            try queue.push(.{ .system_theme_changed = .{ .is_dark = is_dark } });
            self.last_is_dark = is_dark;
        }
        const redraw = self.pending_app_activation;
        self.pending_app_activation = false;
        self.global_collection_pending = false;
        return .{ .should_continue = true, .requested_redraw = redraw };
    }

    fn logicalWindowIdForNative(self: *MacOSBackend, native_id: u64) ?events.WindowId {
        if (native_id == 0) return null;
        for (self.windows) |entry| {
            const window = entry orelse continue;
            if (window.native_window_id == native_id) return window.window_id;
        }
        return null;
    }

    fn resumePostCollection(self: *MacOSBackend, queue: *events.EventQueue) SdkError!bool {
        return self.resumePostCollectionWithCollector(queue, MacOSBackend.collectPostEvents);
    }

    fn resumePostCollectionWithCollector(self: *MacOSBackend, queue: *events.EventQueue, collect: anytype) SdkError!bool {
        self.post_collection_pending = true;
        collect(self, queue) catch |err| {
            if (err != error.OutOfMemory) return err;
            // Already published events must reach the application. Retry
            // the unread head before pumping later input on the next call.
            std.Thread.sleep(16 * std.time.ns_per_ms);
            return false;
        };
        self.post_collection_pending = false;
        return true;
    }

    fn collectPostEvents(self: *MacOSBackend, queue: *events.EventQueue) SdkError!void {
        for (&self.windows) |*maybe_entry| {
            const entry = &(maybe_entry.* orelse continue);
            try entry.collectPostSequenceEvents(queue);
        }
    }

    fn resumeNativeBatch(self: *MacOSBackend, queue: *events.EventQueue) SdkError!bool {
        return self.resumeNativeBatchWithCollector(queue, MacOSBackend.collectNativeBatch);
    }

    fn resumeNativeBatchWithCollector(self: *MacOSBackend, queue: *events.EventQueue, collect: anytype) SdkError!bool {
        if (!self.native_batch_complete) collect(self) catch |err| {
            if (err != error.OutOfMemory) return err;
            // Do not pump AppKit here: another key must not query a client
            // which has not yet received the pending native text. Bound retry
            // frequency without a spin loop when memory pressure persists.
            std.Thread.sleep(16 * std.time.ns_per_ms);
            return false;
        };
        self.dispatchNativeBatch(queue) catch |err| {
            if (err != error.OutOfMemory) return err;
            std.Thread.sleep(16 * std.time.ns_per_ms);
            return false;
        };
        return true;
    }

    fn collectNativeBatch(self: *MacOSBackend) SdkError!void {
        self.native_collection_pending = true;
        for (&self.windows) |*maybe_entry| {
            const entry = &(maybe_entry.* orelse continue);

            // 更新此窗口的鼠标位置
            entry.window.updateWindowMouse();

            const focused = entry.window.isFocused();
            if (focused != entry.last_focused) {
                try self.ordered_native_events.append(self.allocator, .{ .sequence = 0, .event = .{
                    .window_focused = .{
                        .window_id = entry.window_id,
                        .focused = focused,
                    },
                } });
                entry.last_focused = focused;
            }

            // 检查窗口关闭请求
            if (entry.window.checkShouldClose()) {
                try self.ordered_native_events.append(self.allocator, .{ .sequence = 0, .event = .{
                    .window_close_requested = .{
                        .window_id = entry.window_id,
                    },
                } });
                entry.window.resetShouldClose();
            }

            try entry.collectSequencedEvents(
                self.allocator,
                &self.ordered_native_events,
                self.debug_input,
                self.pump_seq,
            );
            if (entry.collected_text_count > self.staged_text_high_water) {
                self.staged_text_high_water = entry.collected_text_count;
                if (self.debug_input) {
                    std.debug.print(
                        "[sdk-input] frame={d} wid={d} text_events_high_water={d}\n",
                        .{
                            self.pump_seq,
                            entry.window_id,
                            self.staged_text_high_water,
                        },
                    );
                }
            }
        }

        sortOrderedNativeEvents(self.ordered_native_events.items);
        self.native_collection_pending = false;
        self.native_batch_complete = true;
    }

    fn dispatchNativeBatch(self: *MacOSBackend, queue: *events.EventQueue) SdkError!void {
        try appendOrderedBatchChecked(queue, self.ordered_native_events.items);
        for (self.ordered_native_events.items) |*ordered| {
            if (ordered.sequence != 0) {
                if (nativeSequenceRegressed(self.last_dispatched_native_sequence, ordered.sequence)) self.input_sequence_regressions +|= 1;
                self.last_dispatched_native_sequence = ordered.sequence;
            }
            ordered.deinit(self.allocator);
        }
        self.ordered_native_events.clearRetainingCapacity();
        self.native_batch_complete = false;
    }

    fn performHapticFeedbackImpl(_: *anyopaque, pattern: backend.HapticFeedbackPattern) SdkError!void {
        // Bridge tag is stable and independent of AppKit enum representation.
        const result = macos_perform_haptic_feedback(hapticBridgeTag(pattern));
        switch (result) {
            1 => {},
            -1 => return SdkError.WrongThread,
            else => return SdkError.NotSupported,
        }
    }

    fn requestRedrawImpl(ctx: *anyopaque) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        // 请求所有窗口重绘
        for (&self.windows) |*maybe_entry| {
            const entry = &(maybe_entry.* orelse continue);
            entry.window.requestRedraw();
        }
    }

    fn menuSetModelImpl(_: *anyopaque, model: backend.MenuModel) SdkError!void {
        if (macos_menu_begin() == 0) return SdkError.BackendFailure;
        for (model.nodes) |node| {
            const ok = switch (node.kind) {
                .menu => macos_menu_add_menu(node.id, node.parent_id, node.label.ptr, node.label.len),
                .separator => macos_menu_add_separator(node.parent_id),
                .item => macos_menu_add_item(
                    node.id,
                    node.parent_id,
                    node.label.ptr,
                    node.label.len,
                    node.key_equivalent.ptr,
                    node.key_equivalent.len,
                    modifiersBits(node.modifiers),
                    @intFromEnum(node.role),
                    node.command_id,
                    @intFromBool(node.enabled),
                    @intFromBool(node.checked),
                ),
            };
            if (ok == 0) return SdkError.InvalidState;
        }
        if (macos_menu_commit() == 0) return SdkError.BackendFailure;
    }

    fn dragStartImpl(ctx: *anyopaque, window_id: events.WindowId, request: backend.DragRequest) SdkError!u64 {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        const token = self.next_drag_token;
        self.next_drag_token +%= 1;
        if (self.next_drag_token == 0) self.next_drag_token = 1;
        const preview_ptr: ?[*]const u8 = if (request.preview_png.len == 0) null else request.preview_png.ptr;
        const ok = macos_begin_drag(
            entry.window.window_ptr,
            token,
            @intFromEnum(request.payload_kind),
            request.payload.ptr,
            request.payload.len,
            @bitCast(request.allowed_operations),
            preview_ptr,
            request.preview_png.len,
            request.preview_width,
            request.preview_height,
            request.hotspot_x,
            request.hotspot_y,
        );
        if (ok == 0) return SdkError.InvalidState;
        return token;
    }

    fn dragTargetSetOperationsImpl(ctx: *anyopaque, window_id: events.WindowId, operations: backend.DragOperations) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        if (macos_set_drag_target_operations(entry.window.window_ptr, @bitCast(operations)) == 0)
            return SdkError.BackendFailure;
    }

    fn modifiersBits(modifiers: events.Modifiers) u8 {
        return @as(u8, @intFromBool(modifiers.shift)) |
            (@as(u8, @intFromBool(modifiers.ctrl)) << 1) |
            (@as(u8, @intFromBool(modifiers.alt)) << 2) |
            (@as(u8, @intFromBool(modifiers.super)) << 3);
    }

    fn syncInputStateImpl(ctx: *anyopaque) void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        for (&self.windows) |*maybe_entry| {
            const entry = &(maybe_entry.* orelse continue);
            entry.syncInputState();
        }
    }

    fn registerWindowImpl(ctx: *anyopaque, window: *Window, window_id: events.WindowId) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        if (window_id == 0 or self.findWindowEntry(window_id) != null) return SdkError.InvalidState;
        for (&self.windows) |*maybe_entry| {
            if (maybe_entry.*) |entry| {
                if (entry.window.window_ptr == window.window_ptr) return SdkError.InvalidState;
            }
        }
        // 查找空槽
        for (&self.windows) |*maybe_entry| {
            if (maybe_entry.* == null) {
                maybe_entry.* = WindowEntry.initFromWindow(window, window_id);
                self.window_count += 1;
                return;
            }
        }
        return SdkError.BackendFailure; // 窗口数已满
    }

    fn unregisterWindowImpl(ctx: *anyopaque, window_id: events.WindowId) void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        self.unregisterWindowWithMenuDiscard(window_id, macos_menu_discard_window_commands);
    }

    fn unregisterWindowWithMenuDiscard(self: *MacOSBackend, window_id: events.WindowId, discard: anytype) void {
        for (&self.windows) |*maybe_entry| {
            if (maybe_entry.*) |*entry| {
                if (entry.window_id == window_id) {
                    var kept: usize = 0;
                    for (self.ordered_native_events.items) |*pending| {
                        const id = pending.event.targetWindowId();
                        if (id == window_id) {
                            pending.deinit(self.allocator);
                        } else {
                            self.ordered_native_events.items[kept] = pending.*;
                            kept += 1;
                        }
                    }
                    self.ordered_native_events.items.len = kept;
                    discard(entry.native_window_id);
                    maybe_entry.* = null;
                    self.window_count -|= 1;
                    return;
                }
            }
        }
    }

    fn rawWindowHandleImpl(ctx: *anyopaque, window_id: events.WindowId) SdkError!*anyopaque {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        return entry.window.window_ptr;
    }

    fn imeSetEnabledImpl(ctx: *anyopaque, window_id: events.WindowId, enabled: bool) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        entry.window.setTextInputEnabled(enabled);
    }

    fn imeSetCursorRectImpl(ctx: *anyopaque, window_id: events.WindowId, x: f32, y: f32, width: f32, height: f32) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        entry.window.setImeCursorRect(x, y, width, height);
    }

    fn imeDiscardImpl(ctx: *anyopaque, window_id: events.WindowId) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        entry.window.discardIme();
    }

    fn cursorSetShapeImpl(ctx: *anyopaque, window_id: events.WindowId, shape: u8) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        entry.window.setCursorShape(shape);
    }

    fn cursorSetCustomImpl(
        ctx: *anyopaque,
        window_id: events.WindowId,
        rgba: [*]const u8,
        len: usize,
        width: u32,
        height: u32,
        scale: f32,
        hot_x: f32,
        hot_y: f32,
        key: u64,
    ) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        if (len < @as(usize, width) * height * 4) return SdkError.BackendFailure;
        macos_set_custom_cursor(entry.window.window_ptr, rgba, len, width, height, scale, hot_x, hot_y, key);
    }

    fn accessibilityAnnounceImpl(ctx: *anyopaque, window_id: events.WindowId, text: []const u8) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        try ensureCStringLen(text.len);
        if (macos_accessibility_announce(entry.window.window_ptr, text.ptr, @intCast(text.len)) == 0) {
            return SdkError.BackendFailure;
        }
    }

    fn accessibilityNotifyFocusImpl(ctx: *anyopaque, window_id: events.WindowId, snapshot: accessibility_mod.NodeSnapshot) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        try postAccessibilitySnapshot(entry.window.window_ptr, snapshot, .focus);
    }

    fn accessibilityNotifyPropertyChangeImpl(ctx: *anyopaque, window_id: events.WindowId, snapshot: accessibility_mod.NodeSnapshot) SdkError!void {
        const self: *MacOSBackend = @ptrCast(@alignCast(ctx));
        const entry = self.findWindowEntry(window_id) orelse return SdkError.InvalidState;
        try postAccessibilitySnapshot(entry.window.window_ptr, snapshot, .property_change);
    }

    fn clipboardSetTextImpl(ctx: *anyopaque, text: []const u8) SdkError!void {
        _ = ctx;
        if (text.len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;
        // 写失败必须上抛：此前这里丢弃返回值，复制静默失效时调用方仍收到成功。
        return clipboardWriteResult(macos_clipboard_set_text(text.ptr, @intCast(text.len)));
    }

    fn clipboardGetTextImpl(ctx: *anyopaque, buffer: []u8) SdkError![]const u8 {
        _ = ctx;
        if (buffer.len == 0) return SdkError.BufferTooSmall;
        if (buffer.len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;

        const len = macos_clipboard_get_text(buffer.ptr, @intCast(buffer.len));
        return clipboardReadSlice(buffer, len);
    }

    /// 同步弹出原生对话框（runModal 嵌套 run loop，期间帧循环阻塞，与既有
    /// pick_folder/save_panel 行为一致）。返回 null = 用户取消。
    fn dialogRunImpl(ctx: *anyopaque, request: backend.DialogRequest, path_buffer: []u8) SdkError!?[]const u8 {
        _ = ctx;
        if (path_buffer.len == 0) return SdkError.BufferTooSmall;
        if (path_buffer.len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;

        const len: c_int = switch (request.kind) {
            .open_file => macos_open_file_panel(path_buffer.ptr, @intCast(path_buffer.len)),
            .pick_folder => macos_pick_folder(path_buffer.ptr, @intCast(path_buffer.len)),
            .save_file => blk: {
                // C 侧要 NUL 结尾字符串；default_path 过长按无默认目录处理
                var dir_buf: [1024]u8 = undefined;
                var dir_z: ?[*:0]const u8 = null;
                if (request.default_path.len > 0 and request.default_path.len < dir_buf.len) {
                    @memcpy(dir_buf[0..request.default_path.len], request.default_path);
                    dir_buf[request.default_path.len] = 0;
                    dir_z = @ptrCast(&dir_buf);
                }
                var name_buf: [512]u8 = undefined;
                var name_z: ?[*:0]const u8 = null;
                if (request.title.len > 0 and request.title.len < name_buf.len) {
                    @memcpy(name_buf[0..request.title.len], request.title);
                    name_buf[request.title.len] = 0;
                    name_z = @ptrCast(&name_buf);
                }
                break :blk macos_save_panel(name_z, dir_z, path_buffer.ptr, @intCast(path_buffer.len));
            },
        };
        if (len < 0) return SdkError.BackendFailure;
        if (len == 0) return null; // 用户取消
        return path_buffer[0..@intCast(len)];
    }

    fn clipboardGetTextLenImpl(ctx: *anyopaque) SdkError!usize {
        _ = ctx;
        const len = macos_clipboard_get_text_len();
        return clipboardReportedLen(len);
    }

    fn clipboardSetRichTextImpl(ctx: *anyopaque, rich: backend.ClipboardRichText) SdkError!void {
        _ = ctx;
        if (rich.text.len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;
        var html_ptr: ?[*]const u8 = null;
        var html_len: c_int = 0;
        if (rich.html) |h| {
            if (h.len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;
            html_ptr = h.ptr;
            html_len = @intCast(h.len);
        }
        // 与 set_text 同一返回合同；此前返回 void，非法 UTF-8 时先清空剪贴板
        // 再静默放弃，调用方却收到成功。
        return clipboardWriteResult(macos_clipboard_set_rich_text(rich.text.ptr, @intCast(rich.text.len), html_ptr, html_len));
    }

    fn clipboardGetHtmlLenImpl(ctx: *anyopaque) SdkError!usize {
        _ = ctx;
        const len = macos_clipboard_get_html_len();
        return clipboardReportedLen(len);
    }

    fn clipboardGetHtmlImpl(ctx: *anyopaque, buffer: []u8) SdkError![]const u8 {
        _ = ctx;
        if (buffer.len == 0) return SdkError.BufferTooSmall;
        if (buffer.len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;
        const len = macos_clipboard_get_html(buffer.ptr, @intCast(buffer.len));
        return clipboardReadSlice(buffer, len);
    }

    fn clipboardSetImagePngImpl(ctx: *anyopaque, png_bytes: []const u8) SdkError!void {
        _ = ctx;
        if (png_bytes.len == 0) return SdkError.BackendFailure;
        if (macos_clipboard_set_image_png(png_bytes.ptr, png_bytes.len) == 0) return SdkError.BackendFailure;
    }

    fn clipboardProbeImpl(ctx: *anyopaque) u32 {
        _ = ctx;
        return macos_clipboard_probe();
    }

    fn clipboardImageCountImpl(ctx: *anyopaque) usize {
        _ = ctx;
        return macos_clipboard_image_count();
    }

    fn clipboardGetImageImpl(ctx: *anyopaque, alloc: Allocator, index: usize) SdkError!?backend.ClipboardImage {
        _ = ctx;
        if (index > std.math.maxInt(u32)) return null;
        const idx: u32 = @intCast(index);

        var width: u32 = 0;
        var height: u32 = 0;
        const rgba_raw = macos_clipboard_read_image(idx, &width, &height) orelse return null;
        defer macos_free_image_data(rgba_raw);
        const rgba_len: usize = @as(usize, width) * @as(usize, height) * 4;
        if (rgba_len == 0) return null;
        const rgba = alloc.dupe(u8, rgba_raw[0..rgba_len]) catch return SdkError.OutOfMemory;
        errdefer alloc.free(rgba);

        // 原始编码字节（可选：TIFF 派生等场景可能拿不到时仍返回解码结果）
        var raw_bytes: ?[]const u8 = null;
        var uti: ?[]const u8 = null;
        var raw_len: usize = 0;
        var uti_buf: [128]u8 = undefined;
        if (macos_clipboard_read_image_bytes(idx, &raw_len, &uti_buf, uti_buf.len)) |raw_ptr| {
            defer macos_free_image_data(raw_ptr);
            if (raw_len > 0) {
                raw_bytes = alloc.dupe(u8, raw_ptr[0..raw_len]) catch return SdkError.OutOfMemory;
                const uti_len = std.mem.indexOfScalar(u8, &uti_buf, 0) orelse 0;
                if (uti_len > 0) {
                    uti = alloc.dupe(u8, uti_buf[0..uti_len]) catch null;
                }
            }
        }

        return .{
            .width = width,
            .height = height,
            .rgba = rgba,
            .raw_bytes = raw_bytes,
            .uti = uti,
        };
    }

    fn toModifiers(mods: platform.Modifiers) events.Modifiers {
        return .{
            .shift = mods.shift,
            .ctrl = mods.ctrl,
            .alt = mods.alt,
            .super = mods.cmd,
        };
    }

    fn readDebugFlag(allocator: Allocator) bool {
        const value = std.process.getEnvVarOwned(allocator, "ZENIT_INPUT_DEBUG") catch return false;
        defer allocator.free(value);
        if (value.len == 0) return false;
        if (std.mem.eql(u8, value, "0")) return false;
        if (std.ascii.eqlIgnoreCase(value, "false")) return false;
        return true;
    }

    fn findWindowEntry(self: *MacOSBackend, window_id: events.WindowId) ?*WindowEntry {
        for (&self.windows) |*maybe_entry| {
            if (maybe_entry.*) |entry| {
                if (entry.window_id == window_id) return &(maybe_entry.*.?);
            }
        }
        return null;
    }

    const A11yNotificationKind = enum {
        focus,
        property_change,
    };

    fn postAccessibilitySnapshot(window_ptr: *anyopaque, snapshot: accessibility_mod.NodeSnapshot, kind: A11yNotificationKind) SdkError!void {
        try ensureCStringLen(snapshot.label.len);
        try ensureCStringLen(snapshot.description.len);
        try ensureCStringLen(snapshot.value_text.len);

        const result = switch (kind) {
            .focus => macos_accessibility_notify_focus(
                window_ptr,
                @intCast(@intFromEnum(snapshot.role)),
                snapshot.label.ptr,
                @intCast(snapshot.label.len),
                snapshot.description.ptr,
                @intCast(snapshot.description.len),
                snapshot.value_text.ptr,
                @intCast(snapshot.value_text.len),
                triState(snapshot.checked),
                triState(snapshot.expanded),
                if (snapshot.disabled) 1 else 0,
            ),
            .property_change => macos_accessibility_notify_property_change(
                window_ptr,
                @intCast(@intFromEnum(snapshot.role)),
                snapshot.label.ptr,
                @intCast(snapshot.label.len),
                snapshot.description.ptr,
                @intCast(snapshot.description.len),
                snapshot.value_text.ptr,
                @intCast(snapshot.value_text.len),
                triState(snapshot.checked),
                triState(snapshot.expanded),
                if (snapshot.disabled) 1 else 0,
            ),
        };
        if (result == 0) return SdkError.BackendFailure;
    }

    fn triState(value: ?bool) c_int {
        return if (value) |v| if (v) 1 else 0 else -1;
    }

    fn ensureCStringLen(len: usize) SdkError!void {
        if (len > std.math.maxInt(c_int)) return SdkError.BufferTooSmall;
    }
};

fn clipboardReadSlice(buffer: []u8, len: c_int) SdkError![]const u8 {
    if (len == -2) return error.BufferTooSmall;
    if (len < 0 or @as(usize, @intCast(len)) > buffer.len) return error.BackendFailure;
    return buffer[0..@intCast(len)];
}

/// 剪贴板写入桥的返回合同：1 = 成功，-1 = 载荷不是合法 UTF-8，其余 =
/// NSPasteboard 拒绝写入。
fn clipboardWriteResult(rc: c_int) SdkError!void {
    return switch (rc) {
        1 => {},
        -1 => SdkError.InvalidState,
        else => SdkError.BackendFailure,
    };
}

fn clipboardReportedLen(len: c_int) SdkError!usize {
    if (len == -2) return error.BufferTooSmall;
    if (len < 0) return error.BackendFailure;
    return @intCast(len);
}

test "clipboard bridge results distinguish empty capacity failure and invalid lengths" {
    const t = std.testing;
    var buffer: [4]u8 = .{ 'a', 0, 'b', 0 };
    try t.expectEqualStrings("a\x00b", try clipboardReadSlice(&buffer, 3));
    try t.expectEqualStrings("", try clipboardReadSlice(&buffer, 0));
    try t.expectError(error.BufferTooSmall, clipboardReadSlice(&buffer, -2));
    try t.expectError(error.BackendFailure, clipboardReadSlice(&buffer, -1));
    try t.expectError(error.BackendFailure, clipboardReadSlice(&buffer, 5));
    try t.expectEqual(@as(usize, 0), try clipboardReportedLen(0));
    try t.expectEqual(@as(usize, 3), try clipboardReportedLen(3));
    try t.expectError(error.BufferTooSmall, clipboardReportedLen(-2));
    try t.expectError(error.BackendFailure, clipboardReportedLen(-1));
    try clipboardWriteResult(1);
    try t.expectError(error.InvalidState, clipboardWriteResult(-1));
    try t.expectError(error.BackendFailure, clipboardWriteResult(0));
}

test "complete native text collection retains dequeued payloads and retries the unread head" {
    const t = std.testing;
    const Reader = struct {
        read: [3]bool = .{ false, false, false },
        const text = "漢" ** 2000 ++ "\x00tail";
        fn readTextEventAllocChecked(self: *@This(), allocator: Allocator, kind: Window.TextEventKind) !?Window.ImePreeditEvent {
            const index = @intFromEnum(kind);
            if (self.read[index]) return null;
            const owned = try allocator.dupe(u8, text);
            self.read[index] = true;
            return .{ .text = owned, .sequence = switch (kind) {
                .preedit => 10,
                .commit => 20,
                .input => 30,
            }, .cursor_utf8_offset = text.len, .replace_start_utf8 = 1, .replace_end_utf8 = 7 };
        }
    };
    var completed = false;
    for (0..24) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        var reader: Reader = .{};
        var pending: std.ArrayList(OrderedNativeEvent) = .{};
        defer {
            for (pending.items) |*item| item.deinit(failing.allocator());
            pending.deinit(failing.allocator());
        }
        const result = collectTextEvents(failing.allocator(), &reader, 7, &pending);
        if (result) |_| {
            completed = true;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            var consumed: usize = 0;
            for (reader.read) |read| consumed += @intFromBool(read);
            try t.expectEqual(consumed, pending.items.len);
            for (pending.items) |item| try t.expectEqualStrings(Reader.text, item.owned_text.?);
            failing.fail_index = std.math.maxInt(usize);
            _ = try collectTextEvents(failing.allocator(), &reader, 7, &pending);
        }
        sortOrderedNativeEvents(pending.items);
        try t.expectEqual(@as(usize, 3), pending.items.len);
        try t.expectEqualStrings(Reader.text, pending.items[0].event.ime_preedit.text);
        try t.expectEqualStrings(Reader.text, pending.items[1].event.ime_commit.text);
        // Identical later plain text is a distinct event, not a duplicate
        // inferred from unrelated queue heads.
        try t.expectEqualStrings(Reader.text, pending.items[2].event.text_input.text);
        try t.expectEqual(@as(u32, 1), pending.items[1].event.ime_commit.replace_start_utf8);
        try t.expectEqual(@as(u32, 7), pending.items[1].event.ime_commit.replace_end_utf8);
        if (completed) break;
    }
    try t.expect(completed);
}

test "native batch publication is atomic and retry transfers independent complete payloads" {
    const t = std.testing;
    var completed = false;
    for (0..40) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var queue = events.EventQueue.init(failing.allocator());
        defer queue.deinit();
        try queue.push(.{ .frame_requested = {} });
        var backend_state: MacOSBackend = .{ .allocator = t.allocator, .native_batch_complete = true, .last_dispatched_native_sequence = 1 };
        defer {
            for (backend_state.ordered_native_events.items) |*item| item.deinit(t.allocator);
            backend_state.ordered_native_events.deinit(t.allocator);
        }
        for (0..3) |i| {
            const owned = try t.allocator.dupe(u8, "a" ** 6000 ++ "漢");
            try backend_state.ordered_native_events.append(t.allocator, .{ .sequence = 2 + i, .event = .{ .text_input = .{ .window_id = 7, .text = owned } }, .owned_text = owned });
        }
        failing.fail_index = failing.alloc_index + failure;
        failing.resize_fail_index = failing.resize_index;
        const result = backend_state.dispatchNativeBatch(&queue);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (result) |_| {
            completed = true;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(@as(usize, 1), queue.items().len);
            try t.expectEqual(@as(u64, 1), backend_state.last_dispatched_native_sequence);
            try t.expectEqual(@as(usize, 3), backend_state.ordered_native_events.items.len);
            try t.expect(backend_state.native_batch_complete);
            try backend_state.dispatchNativeBatch(&queue);
        }
        try t.expectEqual(@as(usize, 4), queue.items().len);
        try t.expectEqual(@as(u64, 4), backend_state.last_dispatched_native_sequence);
        try t.expectEqual(@as(usize, 0), backend_state.ordered_native_events.items.len);
        try t.expect(!backend_state.native_batch_complete);
        for (queue.items()[1..]) |item| try t.expectEqualStrings("a" ** 6000 ++ "漢", item.text_input.text);
        try backend_state.dispatchNativeBatch(&queue);
        try t.expectEqual(@as(usize, 4), queue.items().len);
        if (completed) break;
    }
    try t.expect(completed);
}

test "native collection has no 128 packet cutoff and unregister releases pending text" {
    const t = std.testing;
    const Reader = struct {
        count: usize = 0,
        fn readTextEventAllocChecked(self: *@This(), allocator: Allocator, kind: Window.TextEventKind) !?Window.ImePreeditEvent {
            if (kind != .input or self.count == 200) return null;
            const text = try allocator.dupe(u8, "complete" ** 100);
            self.count += 1;
            return .{ .sequence = self.count, .text = text, .cursor_utf8_offset = 0 };
        }
    };
    var state: MacOSBackend = .{ .allocator = t.allocator };
    defer {
        for (state.ordered_native_events.items) |*item| item.deinit(t.allocator);
        state.ordered_native_events.deinit(t.allocator);
    }
    var reader: Reader = .{};
    try t.expectEqual(@as(usize, 200), try collectTextEvents(t.allocator, &reader, 7, &state.ordered_native_events));
    state.windows[0] = .{ .window = undefined, .window_id = 7 };
    state.window_count = 1;
    try state.ordered_native_events.append(t.allocator, .{ .sequence = 201, .event = .{ .key = .{ .window_id = 8, .keycode = 0, .pressed = true } } });
    state.unregisterWindowWithMenuDiscard(7, struct {
        fn discard(_: u64) void {}
    }.discard);
    try t.expectEqual(@as(usize, 1), state.ordered_native_events.items.len);
    try t.expectEqual(@as(u64, 201), state.ordered_native_events.items[0].sequence);
}

test "native pump memory pressure keeps a deliverable batch without failing the application loop" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var queue = events.EventQueue.init(failing.allocator());
    defer queue.deinit();
    var state: MacOSBackend = .{ .allocator = t.allocator, .native_batch_complete = true };
    defer {
        for (state.ordered_native_events.items) |*item| item.deinit(t.allocator);
        state.ordered_native_events.deinit(t.allocator);
    }
    const text = try t.allocator.dupe(u8, "preserved" ** 1000);
    try state.ordered_native_events.append(t.allocator, .{ .sequence = 1, .event = .{ .text_input = .{ .window_id = 1, .text = text } }, .owned_text = text });
    const never_collect = struct {
        fn collect(_: *MacOSBackend) SdkError!void {
            return error.BackendFailure;
        }
    }.collect;
    try t.expect(!try state.resumeNativeBatchWithCollector(&queue, never_collect));
    try t.expectEqual(@as(usize, 0), queue.items().len);
    try t.expectEqual(@as(usize, 1), state.ordered_native_events.items.len);
    try t.expectEqual(@as(u64, 0), state.last_dispatched_native_sequence);
    failing.fail_index = std.math.maxInt(usize);
    try t.expect(try state.resumeNativeBatchWithCollector(&queue, never_collect));
    try t.expectEqualStrings("preserved" ** 1000, queue.items()[0].text_input.text);
    try t.expectEqual(@as(u64, 1), state.last_dispatched_native_sequence);
}

test "drag collection retries every failed allocation without losing full paths or completion" {
    const t = std.testing;
    const Reader = struct {
        count: usize = 0,
        reject: bool = false,
        fn peekDragEventChecked(self: *@This()) !?Window.PendingDragEvent {
            if (self.count == 3) return null;
            return .{ .token = @ptrFromInt(self.count + 1), .event = .{
                .x = 12,
                .y = 34,
                .kind = if (self.count < 2) 3 else 4,
                .paths = if (self.count < 2) "/tmp/漢.png\n" ** 1000 else "",
                .payload_kind = 1,
                .source_token = 123456789,
                .operation = 2,
                .paths_truncated = false,
            } };
        }
        fn consumeDragEventChecked(self: *@This(), token: *const anyopaque) !void {
            if (self.reject or @intFromPtr(token) != self.count + 1) return error.BackendFailure;
            self.count += 1;
        }
    };
    var completed = false;
    var saw_partial_failure = false;
    for (0..24) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        var queue = events.EventQueue.init(failing.allocator());
        defer queue.deinit();
        var reader: Reader = .{};
        if (collectDragEvents(&queue, &reader, 7)) |_| {
            completed = true;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(reader.count, queue.items().len);
            saw_partial_failure = saw_partial_failure or reader.count > 0;
            failing.fail_index = std.math.maxInt(usize);
            try collectDragEvents(&queue, &reader, 7);
        }
        try t.expectEqual(@as(usize, 3), queue.items().len);
        try t.expectEqualStrings("/tmp/漢.png\n" ** 1000, queue.items()[0].drag.paths);
        try t.expect(queue.items()[0].drag.payload_is_untrusted);
        try t.expect(!queue.items()[2].drag.payload_is_untrusted);
        try t.expectEqual(@as(u64, 123456789), queue.items()[2].drag.source_token);
        try t.expectEqual(@as(u8, 2), queue.items()[2].drag.operation);
        if (completed) break;
    }
    try t.expect(completed);
    try t.expect(saw_partial_failure);
    var queue = events.EventQueue.init(t.allocator);
    defer queue.deinit();
    try queue.push(.{ .frame_requested = {} });
    var reader: Reader = .{ .reject = true };
    try t.expectError(error.BackendFailure, collectDragEvents(&queue, &reader, 7));
    try t.expectEqual(@as(usize, 1), queue.items().len);
    try t.expectEqual(@as(usize, 0), queue.owned_payloads.items.len);
    reader.reject = false;
    try collectDragEvents(&queue, &reader, 7);
    try t.expectEqual(@as(usize, 4), queue.items().len);
}

test "post input allocation failure retains retry phase without failing published input" {
    const t = std.testing;
    const collector = struct {
        fn collect(_: *MacOSBackend, queue: *events.EventQueue) SdkError!void {
            try queue.push(.{ .drag = .{ .window_id = 1, .x = 0, .y = 0, .kind = 3, .paths = "pending" } });
        }
    }.collect;
    var state: MacOSBackend = .{ .allocator = t.allocator };
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var queue = events.EventQueue.init(failing.allocator());
    defer queue.deinit();
    try queue.push(.{ .frame_requested = {} });
    failing.fail_index = failing.alloc_index;
    try t.expect(!try state.resumePostCollectionWithCollector(&queue, collector));
    try t.expect(state.post_collection_pending);
    try t.expectEqual(@as(usize, 1), queue.items().len);
    failing.fail_index = std.math.maxInt(usize);
    try t.expect(try state.resumePostCollectionWithCollector(&queue, collector));
    try t.expect(!state.post_collection_pending);
    try t.expectEqualStrings("pending", queue.items()[1].drag.paths);
}

test "global phase retries partial menu delivery and preserves activation and theme" {
    const t = std.testing;
    const Source = struct {
        count: usize = 0,
        active: bool = true,
        fn appShouldQuit(_: *@This()) bool {
            return false;
        }
        fn consumeAppBecameActive(self: *@This()) bool {
            const result = self.active;
            self.active = false;
            return result;
        }
        fn isDarkMode(_: *@This()) bool {
            return true;
        }
        fn pollMenu(self: *@This(), window: *u64, command: *u64) bool {
            if (self.count == 40) return false;
            self.count += 1;
            window.* = if (self.count == 5) 88 else if (self.count == 6) 0 else 7;
            command.* = self.count;
            return true;
        }
    };
    var completed = false;
    var saw_partial = false;
    for (0..32) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure, .resize_fail_index = 0 });
        var queue = events.EventQueue.init(failing.allocator());
        defer queue.deinit();
        var source: Source = .{};
        var state: MacOSBackend = .{ .allocator = t.allocator, .last_is_dark = false };
        state.windows[0] = .{ .window = undefined, .window_id = 70, .native_window_id = 7 };
        state.window_count = 1;
        var delivered: std.ArrayList(u64) = .{};
        defer delivered.deinit(t.allocator);
        const first = try state.resumeGlobalCollection(&queue, &source);
        if (first == null) {
            try t.expect(state.global_collection_pending);
            try t.expect(state.pending_app_activation);
            try t.expectEqual(false, state.last_is_dark.?);
            saw_partial = saw_partial or source.count > 0;
            for (queue.items()) |event| try delivered.append(t.allocator, event.menu_command.command_id);
            queue.clear(); // The application delivers the first pump before retry.
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            const retry = (try state.resumeGlobalCollection(&queue, &source)).?;
            try t.expect(retry.should_continue and retry.requested_redraw);
        } else {
            completed = true;
            try t.expect(first.?.requested_redraw);
        }
        var theme_count: usize = 0;
        for (queue.items()) |event| switch (event) {
            .menu_command => |menu| {
                try t.expectEqual(@as(u64, if (menu.command_id == 6) 0 else 70), menu.window_id);
                try delivered.append(t.allocator, menu.command_id);
            },
            .system_theme_changed => |theme| {
                try t.expect(theme.is_dark);
                theme_count += 1;
            },
            else => return error.UnexpectedEvent,
        };
        try t.expectEqual(@as(usize, 39), delivered.items.len);
        var next: u64 = 1;
        for (delivered.items) |command| {
            if (next == 5) next += 1;
            try t.expectEqual(next, command);
            next += 1;
        }
        try t.expectEqual(@as(usize, 1), theme_count);
        try t.expect(!state.global_collection_pending and !state.pending_app_activation);
        try t.expectEqual(true, state.last_is_dark.?);
        queue.clear();
        const empty = (try state.resumeGlobalCollection(&queue, &source)).?;
        try t.expect(!empty.requested_redraw and queue.items().len == 0);
        if (completed) break;
    }
    try t.expect(completed and saw_partial);
}

test "quit OOM retries without confirming application exit and unregister discards scoped commands" {
    const t = std.testing;
    const Source = struct {
        fn appShouldQuit(_: *@This()) bool {
            return true;
        }
        fn consumeAppBecameActive(_: *@This()) bool {
            unreachable;
        }
        fn isDarkMode(_: *@This()) bool {
            unreachable;
        }
        fn pollMenu(_: *@This(), _: *u64, _: *u64) bool {
            unreachable;
        }
    };
    var source: Source = .{};
    var state: MacOSBackend = .{ .allocator = t.allocator };
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var queue = events.EventQueue.init(failing.allocator());
    defer queue.deinit();
    try t.expect((try state.resumeGlobalCollection(&queue, &source)) == null);
    try t.expect(state.global_collection_pending and queue.items().len == 0);
    failing.fail_index = std.math.maxInt(usize);
    const result = (try state.resumeGlobalCollection(&queue, &source)).?;
    try t.expect(!result.should_continue and !state.global_collection_pending);
    try t.expectEqual(@as(usize, 1), queue.items().len);
    try t.expect(queue.items()[0] == .quit);
    const Discard = struct {
        var id: u64 = 0;
        fn discard(window_id: u64) void {
            @This().id = window_id;
        }
    };
    Discard.id = 0;
    state.windows[0] = .{ .window = undefined, .window_id = 7, .native_window_id = 700 };
    state.window_count = 1;
    state.unregisterWindowWithMenuDiscard(7, Discard.discard);
    try t.expectEqual(@as(u64, 700), Discard.id);
    try t.expectEqual(@as(usize, 0), state.window_count);
}
