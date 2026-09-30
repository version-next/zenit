const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WindowId = u64;

/// IME replacementRange 哨兵：本次 preedit/commit 不修订已提交文本（现行为）。
pub const ime_no_replacement: u32 = 0xFFFF_FFFF;

/// 修饰键
pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _padding: u4 = 0,
};

pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
    other,
};

/// 统一系统事件
///
/// 注意:
/// - EventQueue 会复制并持有 text_input / ime_* 的 text
/// - 这些切片至少持续到下一次 pump 调用前有效
pub const Event = union(enum) {
    quit: void,
    frame_requested: void,
    /// Custom menu commands are captured together with the key window that
    /// owned the command context at click/keyboard-equivalent time.  A zero
    /// id is reserved for backends that do not have a native window target;
    /// application runtimes may then fall back to their active window.
    menu_command: struct {
        window_id: WindowId = 0,
        command_id: u64,
    },

    window_resized: struct {
        window_id: WindowId,
        width: u32,
        height: u32,
        scale_factor: f32,
    },
    window_focused: struct {
        window_id: WindowId,
        focused: bool,
    },
    window_close_requested: struct {
        window_id: WindowId,
    },

    mouse_move: struct {
        window_id: WindowId,
        x: f32,
        y: f32,
        dx: f32 = 0,
        dy: f32 = 0,
        modifiers: Modifiers = .{},
    },
    mouse_button: struct {
        window_id: WindowId,
        x: f32,
        y: f32,
        button: MouseButton,
        pressed: bool,
        modifiers: Modifiers = .{},
    },
    mouse_wheel: struct {
        window_id: WindowId,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        is_momentum: bool = false,
        phase_ended: bool = false,
        is_trackpad: bool = false,
        modifiers: Modifiers = .{},
    },
    magnify: struct {
        window_id: WindowId,
        x: f32,
        y: f32,
        /// 相对增量：new_scale = old_scale * (1 + magnification)
        magnification: f32,
        /// 0=began 1=changed 2=ended 3=cancelled
        phase: u8,
    },
    drag: struct {
        window_id: WindowId,
        x: f32,
        y: f32,
        /// 0=entered 1=updated 2=exited 3=dropped 4=source completed/cancelled
        kind: u8,
        /// dropped 时有效：换行分隔的文件路径 / URL 列表（backend 缓冲，仅本帧有效）
        paths: []const u8 = "",
        /// destination payload: 0=none, 1=file/URL list, 2=text, 3=internal UTF-8.
        payload_kind: u8 = 0,
        /// kind=4 时关联 `beginDrag` 返回值；destination 事件为 0。
        source_token: u64 = 0,
        /// kind=4 时实际操作位：1=copy 2=move 4=link；0=cancelled。
        operation: u8 = 0,
        /// The native payload exceeded the backend cap and was rejected whole.
        payload_truncated: bool = false,
        /// Destination drag data is controlled by another process (including
        /// file-promise filenames) and must be validated by the application.
        payload_is_untrusted: bool = true,
    },

    key: struct {
        window_id: WindowId,
        keycode: u16,
        pressed: bool,
        modifiers: Modifiers = .{},
    },
    text_input: struct {
        window_id: WindowId,
        text: []const u8,
    },
    ime_preedit: struct {
        window_id: WindowId,
        text: []const u8,
        cursor_utf8_offset: u32,
        /// IME replacementRange 换算成的 UTF-8 字节区间（相对聚焦 input 文档）。
        /// ime_no_replacement 哨兵 = 无 replacement（现行为）。
        replace_start_utf8: u32 = ime_no_replacement,
        replace_end_utf8: u32 = ime_no_replacement,
    },
    ime_commit: struct {
        window_id: WindowId,
        text: []const u8,
        replace_start_utf8: u32 = ime_no_replacement,
        replace_end_utf8: u32 = ime_no_replacement,
    },
    /// 系统主题切换事件（macOS Dark/Light mode）
    system_theme_changed: struct {
        is_dark: bool,
    },

    /// Return the native window targeted by this event. Application-wide
    /// events return null. `menu_command.window_id == 0` is also application
    /// scoped so older/custom backends retain a deterministic active-window
    /// fallback.
    pub fn targetWindowId(self: Event) ?WindowId {
        return switch (self) {
            .window_resized => |e| e.window_id,
            .window_focused => |e| e.window_id,
            .window_close_requested => |e| e.window_id,
            .mouse_move => |e| e.window_id,
            .mouse_button => |e| e.window_id,
            .mouse_wheel => |e| e.window_id,
            .magnify => |e| e.window_id,
            .drag => |e| e.window_id,
            .key => |e| e.window_id,
            .text_input => |e| e.window_id,
            .ime_preedit => |e| e.window_id,
            .ime_commit => |e| e.window_id,
            .menu_command => |e| if (e.window_id == 0) null else e.window_id,
            .quit, .frame_requested, .system_theme_changed => null,
        };
    }
};

/// SDK 事件队列
pub const EventQueue = struct {
    allocator: Allocator,
    list: std.ArrayList(Event),
    /// Borrowed backend payloads that must remain valid until the next pump.
    ///
    /// macOS drains native drag and text/IME packets through reusable scratch
    /// buffers. Keeping those slices directly in `list` lets a later event or
    /// window unregister invalidate an earlier payload. Store a per-event copy
    /// here instead; `clear` releases it at the next pump boundary.
    owned_payloads: std.ArrayList([]u8),

    pub fn init(allocator: Allocator) EventQueue {
        return .{
            .allocator = allocator,
            .list = .{},
            .owned_payloads = .{},
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.clearOwnedPayloads();
        self.owned_payloads.deinit(self.allocator);
        self.list.deinit(self.allocator);
    }

    pub fn clear(self: *EventQueue) void {
        self.list.clearRetainingCapacity();
        self.clearOwnedPayloads();
    }

    fn clearOwnedPayloads(self: *EventQueue) void {
        for (self.owned_payloads.items) |payload| self.allocator.free(payload);
        self.owned_payloads.clearRetainingCapacity();
    }

    pub fn push(self: *EventQueue, event: Event) !void {
        var queued = event;
        switch (queued) {
            .drag => |*drag| {
                if (drag.paths.len > 0) {
                    const owned = try self.allocator.dupe(u8, drag.paths);
                    drag.paths = owned;
                    return self.appendOwnedEvent(queued, owned);
                }
            },
            .text_input => |*input| {
                if (input.text.len > 0) {
                    const owned = try self.allocator.dupe(u8, input.text);
                    input.text = owned;
                    return self.appendOwnedEvent(queued, owned);
                }
            },
            .ime_preedit => |*preedit| {
                if (preedit.text.len > 0) {
                    const owned = try self.allocator.dupe(u8, preedit.text);
                    preedit.text = owned;
                    return self.appendOwnedEvent(queued, owned);
                }
            },
            .ime_commit => |*commit| {
                if (commit.text.len > 0) {
                    const owned = try self.allocator.dupe(u8, commit.text);
                    commit.text = owned;
                    return self.appendOwnedEvent(queued, owned);
                }
            },
            else => {},
        }
        try self.list.append(self.allocator, queued);
    }

    fn appendOwnedEvent(self: *EventQueue, queued: Event, owned: []u8) !void {
        // Keep the two arrays transactional: an allocation failure must not
        // retain an unreferenced payload or leave an event pointing at freed
        // storage.
        errdefer self.allocator.free(owned);
        try self.list.append(self.allocator, queued);
        errdefer _ = self.list.pop();
        try self.owned_payloads.append(self.allocator, owned);
    }

    pub fn items(self: *const EventQueue) []const Event {
        return self.list.items;
    }
};

test "EventQueue push + clear" {
    var q = EventQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.push(.{ .quit = {} });
    try q.push(.{ .window_resized = .{
        .window_id = 1,
        .width = 1280,
        .height = 720,
        .scale_factor = 2.0,
    } });

    try std.testing.expectEqual(@as(usize, 2), q.items().len);

    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.items().len);
}

test "Event targetWindowId distinguishes window and application events" {
    const pointer: Event = .{ .mouse_move = .{
        .window_id = 19,
        .x = 1,
        .y = 2,
    } };
    try std.testing.expectEqual(@as(?WindowId, 19), pointer.targetWindowId());

    const targeted_menu: Event = .{ .menu_command = .{
        .window_id = 23,
        .command_id = 7,
    } };
    try std.testing.expectEqual(@as(?WindowId, 23), targeted_menu.targetWindowId());

    const legacy_menu: Event = .{ .menu_command = .{ .command_id = 7 } };
    try std.testing.expectEqual(@as(?WindowId, null), legacy_menu.targetWindowId());
    try std.testing.expectEqual(@as(?WindowId, null), (Event{ .quit = {} }).targetWindowId());
}

test "EventQueue owns each drag payload until clear" {
    var q = EventQueue.init(std.testing.allocator);
    defer q.deinit();

    var scratch = [_]u8{ 'f', 'i', 'l', 'e', '1' };
    try q.push(.{ .drag = .{
        .window_id = 1,
        .x = 0,
        .y = 0,
        .kind = 3,
        .paths = scratch[0..],
        .payload_truncated = true,
        .payload_is_untrusted = true,
    } });
    scratch = .{ 'f', 'i', 'l', 'e', '2' };
    try q.push(.{ .drag = .{
        .window_id = 1,
        .x = 0,
        .y = 0,
        .kind = 3,
        .paths = scratch[0..],
    } });
    scratch[0] = 0;

    try std.testing.expectEqualStrings("file1", q.items()[0].drag.paths);
    try std.testing.expectEqualStrings("file2", q.items()[1].drag.paths);
    try std.testing.expect(q.items()[0].drag.payload_truncated);
    try std.testing.expect(q.items()[0].drag.payload_is_untrusted);
    try std.testing.expectEqual(@as(usize, 2), q.owned_payloads.items.len);
    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.owned_payloads.items.len);
}

test "EventQueue owns text and IME payloads until clear" {
    var q = EventQueue.init(std.testing.allocator);
    defer q.deinit();

    var scratch = [_]u8{ 'a', 'b', 'c' };
    try q.push(.{ .text_input = .{ .window_id = 1, .text = scratch[0..] } });
    scratch = .{ 'd', 'e', 'f' };
    try q.push(.{ .ime_preedit = .{
        .window_id = 1,
        .text = scratch[0..],
        .cursor_utf8_offset = 3,
    } });
    scratch = .{ 'g', 'h', 'i' };
    try q.push(.{ .ime_commit = .{ .window_id = 1, .text = scratch[0..] } });
    scratch = .{ 0, 0, 0 };

    try std.testing.expectEqualStrings("abc", q.items()[0].text_input.text);
    try std.testing.expectEqualStrings("def", q.items()[1].ime_preedit.text);
    try std.testing.expectEqualStrings("ghi", q.items()[2].ime_commit.text);
    try std.testing.expectEqual(@as(usize, 3), q.owned_payloads.items.len);
    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.owned_payloads.items.len);
}

test "EventQueue drag push is transactional on allocation failure" {
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var q = EventQueue.init(failing.allocator());
        defer q.deinit();

        q.push(.{ .drag = .{
            .window_id = 1,
            .x = 0,
            .y = 0,
            .kind = 3,
            .paths = "/tmp/promised-file",
        } }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), q.items().len);
            try std.testing.expectEqual(@as(usize, 0), q.owned_payloads.items.len);
            continue;
        };

        try std.testing.expectEqual(@as(usize, 1), q.items().len);
        try std.testing.expectEqual(@as(usize, 1), q.owned_payloads.items.len);
    }
}
