const std = @import("std");

/// Move-only event/candidate bytes. Short input stays inline; long input retains
/// its original allocation and allocator, even when filtering shortens len.
pub const ImeText = struct {
    inline_buffer: [256]u8 = undefined,
    owned: ?[]u8 = null,
    allocator: ?std.mem.Allocator = null,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) !ImeText {
        var result: ImeText = .{ .len = input.len };
        if (input.len <= result.inline_buffer.len) {
            @memcpy(result.inline_buffer[0..input.len], input);
        } else {
            result.owned = try allocator.dupe(u8, input);
            result.allocator = allocator;
        }
        return result;
    }

    pub fn text(self: *const ImeText) []const u8 {
        return if (self.owned) |bytes| bytes[0..self.len] else self.inline_buffer[0..self.len];
    }

    pub fn mutableText(self: *ImeText) []u8 {
        return if (self.owned) |bytes| bytes[0..self.len] else self.inline_buffer[0..self.len];
    }

    pub fn deinit(self: *ImeText) void {
        if (self.owned) |bytes| self.allocator.?.free(bytes);
        self.* = .{};
    }
};

test "IME text owns exact bytes across inline boundary filtering moves and allocation failure" {
    const t = std.testing;
    for ([_]usize{ 0, 1, 255, 256, 257, 6000 }) |len| {
        const input = try t.allocator.alloc(u8, len);
        defer t.allocator.free(input);
        @memset(input, 'x');
        if (len > 1) input[len - 1] = 0;
        var value = try ImeText.init(t.allocator, input);
        try t.expectEqualSlices(u8, input, value.text());
        var moved = value;
        value = .{};
        defer moved.deinit();
        if (len > 0) moved.len -= 1;
        try t.expectEqualSlices(u8, input[0..moved.len], moved.text());
    }
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, ImeText.init(failing.allocator(), "x" ** 257));
}
