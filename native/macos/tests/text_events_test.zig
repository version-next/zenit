const std = @import("std");
const Window = @import("platform").Window;
extern fn zenit_test_text_window_create() ?*anyopaque;
extern fn zenit_test_text_window_destroy(ptr: *anyopaque) void;
extern fn zenit_test_text_enqueue(ptr: *anyopaque, kind: u32, bytes: [*]const u8, len: usize, cursor: u32) u64;

test "real native queue checked allocation preserves head metadata and all UTF8 bytes" {
    const t = std.testing;
    inline for (.{ Window.TextEventKind.input, Window.TextEventKind.preedit, Window.TextEventKind.commit }) |kind| {
        const ptr = zenit_test_text_window_create() orelse return error.OutOfMemory;
        defer zenit_test_text_window_destroy(ptr);
        var window: Window = .{ .window_ptr = ptr, .view_ptr = undefined, .width = 0, .height = 0 };
        const text = "漢" ** 2000 ++ "\x00tail";
        const first_seq = zenit_test_text_enqueue(ptr, @intFromEnum(kind), text.ptr, text.len, 2005);
        const second_seq = zenit_test_text_enqueue(ptr, @intFromEnum(kind), "tail".ptr, 4, 4);
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        try t.expectError(error.OutOfMemory, window.readTextEventAllocChecked(failing.allocator(), kind));
        failing.fail_index = std.math.maxInt(usize);
        const first = (try window.readTextEventAllocChecked(failing.allocator(), kind)).?;
        defer failing.allocator().free(first.text);
        try t.expectEqualStrings(text, first.text);
        try t.expectEqual(first_seq, first.sequence);
        if (kind == .preedit) try t.expectEqual(@as(u32, text.len), first.cursor_utf8_offset);
        if (kind != .input) {
            try t.expectEqual(@as(u32, 1), first.replace_start_utf8);
            try t.expectEqual(@as(u32, 7), first.replace_end_utf8);
        }
        const second = (try window.readTextEventAllocChecked(t.allocator, kind)).?;
        defer t.allocator.free(second.text);
        try t.expectEqualStrings("tail", second.text);
        try t.expectEqual(second_seq, second.sequence);
        try t.expect(first.sequence < second.sequence);
        try t.expect((try window.readTextEventAllocChecked(t.allocator, kind)) == null);
        try t.expectEqualStrings(text, first.text);
    }
}
