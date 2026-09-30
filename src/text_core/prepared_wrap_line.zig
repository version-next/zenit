const std = @import("std");
const grapheme = @import("grapheme.zig");
const Allocator = std.mem.Allocator;

pub const SegmentFlags = packed struct(u8) {
    breakable_after: bool = false,
    is_space: bool = false,
    is_tab: bool = false,
    _pad: u5 = 0,
};

pub const Segment = struct {
    byte_end: u32,
    columns: u32,
    flags: SegmentFlags,
};

pub const PreparedWrapLine = struct {
    segments: []Segment,
    /// u32：u16 上限 65535，超长单行（~64K 码点）会让 @intCast 在
    /// Debug/ReleaseSafe panic、ReleaseFast UB（静默截断后切片越界）
    segment_count: u32,
    content_hash: u64,

    pub fn deinit(self: *PreparedWrapLine, allocator: Allocator) void {
        if (self.segments.len > 0) allocator.free(self.segments);
    }

    pub fn breaksForColumns(
        self: *const PreparedWrapLine,
        allocator: Allocator,
        max_columns: usize,
        tab_size: usize,
    ) ![]u32 {
        if (self.segment_count == 0 or max_columns == 0) return &.{};

        var stack_breaks: [256]u32 = undefined;
        var stack_count: usize = 0;
        var heap_breaks: std.ArrayListUnmanaged(u32) = .{};
        var use_heap = false;
        defer if (use_heap) heap_breaks.deinit(allocator);

        const segs = self.segments[0..self.segment_count];
        var line_columns: usize = 0;
        var last_break_idx: ?usize = null;
        var last_break_byte: usize = 0;
        var i: usize = 0;

        while (i < segs.len) {
            const seg = segs[i];
            const seg_start: usize = if (i == 0) 0 else segs[i - 1].byte_end;
            const seg_columns = segmentColumns(seg, line_columns, tab_size);

            if (seg.flags.is_space) {
                line_columns += seg_columns;
                if (seg.flags.breakable_after) {
                    last_break_idx = i;
                    last_break_byte = seg.byte_end;
                }
                i += 1;
                continue;
            }

            const next_columns = line_columns + seg_columns;
            if (next_columns > max_columns and line_columns > 0) {
                if (last_break_idx) |break_idx| {
                    try appendBreak(allocator, &stack_breaks, &stack_count, &heap_breaks, &use_heap, @intCast(last_break_byte));
                    i = break_idx + 1;
                    line_columns = 0;
                    last_break_idx = null;
                    last_break_byte = 0;
                    while (i < segs.len and segs[i].flags.is_space) : (i += 1) {}
                    continue;
                }
                if (seg_start > 0) {
                    try appendBreak(allocator, &stack_breaks, &stack_count, &heap_breaks, &use_heap, @intCast(seg_start));
                    line_columns = 0;
                    last_break_idx = null;
                    last_break_byte = 0;
                    continue;
                }
            } else {
                line_columns = next_columns;
            }

            if (seg.flags.breakable_after) {
                last_break_idx = i;
                last_break_byte = seg.byte_end;
            }
            i += 1;
        }

        const break_count = if (use_heap) heap_breaks.items.len else stack_count;
        if (break_count == 0) return &.{};

        const breaks = try allocator.alloc(u32, break_count);
        if (use_heap) {
            @memcpy(breaks, heap_breaks.items[0..break_count]);
        } else {
            @memcpy(breaks, stack_breaks[0..break_count]);
        }
        return breaks;
    }
};

pub const Builder = struct {
    allocator: Allocator,
    segments: std.ArrayListUnmanaged(Segment) = .{},
    content_hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),
    pending_kind: enum { none, spaces } = .none,
    pending_start: usize = 0,
    pending_end: usize = 0,
    pending_columns: usize = 0,

    pub fn init(allocator: Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.segments.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn feed(self: *Builder, content: []const u8, base_offset: usize) !void {
        if (content.len == 0) return;
        self.content_hasher.update(content);

        var i: usize = 0;
        while (i < content.len) {
            const abs_i = base_offset + i;
            const byte = content[i];

            if (byte == ' ') {
                if (self.pending_kind != .spaces) {
                    try self.flushPending();
                    self.pending_kind = .spaces;
                    self.pending_start = abs_i;
                    self.pending_columns = 0;
                }
                var j = i;
                while (j < content.len and content[j] == ' ') : (j += 1) {}
                self.pending_end = base_offset + j;
                self.pending_columns += j - i;
                i = j;
                continue;
            }

            if (byte == '\t') {
                try self.flushPending();
                try self.segments.append(self.allocator, .{
                    .byte_end = @intCast(abs_i + 1),
                    .columns = 0,
                    .flags = .{ .breakable_after = true, .is_tab = true },
                });
                i += 1;
                continue;
            }

            const cp_len = utf8Len(byte);
            const next_i = @min(i + cp_len, content.len);
            const cp = std.unicode.utf8Decode(content[i..next_i]) catch 0;
            if (cp != 0 and isWideChar(cp)) {
                try self.flushPending();
                try self.segments.append(self.allocator, .{
                    .byte_end = @intCast(base_offset + next_i),
                    .columns = 2,
                    .flags = .{ .breakable_after = true },
                });
                i = next_i;
                continue;
            }

            try self.flushPending();
            try self.segments.append(self.allocator, .{
                .byte_end = @intCast(base_offset + next_i),
                .columns = 1,
                .flags = .{},
            });
            i = next_i;
        }
    }

    pub fn finish(self: *Builder) !*PreparedWrapLine {
        try self.flushPending();
        const prepared = try self.allocator.create(PreparedWrapLine);
        errdefer self.allocator.destroy(prepared);
        const seg_count: u32 = @intCast(self.segments.items.len);
        prepared.* = .{
            .segments = try self.segments.toOwnedSlice(self.allocator),
            .segment_count = seg_count,
            .content_hash = self.content_hasher.final(),
        };
        self.segments = .{};
        return prepared;
    }

    fn flushPending(self: *Builder) !void {
        switch (self.pending_kind) {
            .none => return,
            .spaces => try self.segments.append(self.allocator, .{
                .byte_end = @intCast(self.pending_end),
                .columns = @intCast(self.pending_columns),
                .flags = .{ .breakable_after = true, .is_space = true },
            }),
        }
        self.pending_kind = .none;
        self.pending_start = 0;
        self.pending_end = 0;
        self.pending_columns = 0;
    }
};

pub fn prepareLine(allocator: Allocator, content: []const u8) !*PreparedWrapLine {
    const prepared = try allocator.create(PreparedWrapLine);
    errdefer allocator.destroy(prepared);

    if (content.len == 0) {
        prepared.* = .{
            .segments = &.{},
            .segment_count = 0,
            .content_hash = 0,
        };
        return prepared;
    }

    var segments = std.ArrayListUnmanaged(Segment){};
    errdefer segments.deinit(allocator);

    var i: usize = 0;
    var grapheme_cursor = grapheme.BoundaryCursor.init(content);
    while (i < content.len) {
        const byte = content[i];
        if (byte == ' ') {
            const start = i;
            while (i < content.len and content[i] == ' ') : (i += 1) {}
            try segments.append(allocator, .{
                .byte_end = @intCast(i),
                .columns = @intCast(i - start),
                .flags = .{ .breakable_after = true, .is_space = true },
            });
            continue;
        }
        if (byte == '\t') {
            i += 1;
            try segments.append(allocator, .{
                .byte_end = @intCast(i),
                .columns = 0,
                .flags = .{ .breakable_after = true, .is_tab = true },
            });
            continue;
        }

        const wide_len = decodeWideLen(content[i..]);
        if (wide_len > 0) {
            i += wide_len;
            try segments.append(allocator, .{
                .byte_end = @intCast(i),
                .columns = 2,
                .flags = .{ .breakable_after = true },
            });
            continue;
        }

        // 按 grapheme cluster 推进：按码点会把 ZWJ emoji/组合字符拆成
        // 多个独立 segment，每个都可能成为断点（1e2bee4 的遗漏兄弟）
        i = grapheme_cursor.next(i);
        try segments.append(allocator, .{
            .byte_end = @intCast(i),
            .columns = 1,
            .flags = .{},
        });
    }

    const seg_count: u32 = @intCast(segments.items.len);
    prepared.* = .{
        .segments = try segments.toOwnedSlice(allocator),
        .segment_count = seg_count,
        .content_hash = std.hash.Wyhash.hash(0, content),
    };
    return prepared;
}

pub fn prepareLineChunked(
    allocator: Allocator,
    feedFn: *const fn (ctx: *anyopaque, offset: usize, buf: []u8) anyerror![]const u8,
    ctx: *anyopaque,
    total_len: usize,
    chunk_size: usize,
) !*PreparedWrapLine {
    var builder = Builder.init(allocator);
    errdefer builder.deinit();

    var stack_buf: [4096 + 8]u8 = undefined;
    const target_chunk = @min(chunk_size, stack_buf.len - 4);

    var offset: usize = 0;
    while (offset < total_len) {
        const remaining = total_len - offset;
        const request_len = @min(remaining, target_chunk + 4);
        const slice = try feedFn(ctx, offset, stack_buf[0..request_len]);
        if (slice.len == 0) break;
        const process_len = if (offset + slice.len < total_len)
            utf8AlignedPrefixLen(slice, @min(target_chunk, slice.len))
        else
            slice.len;
        if (process_len == 0) return error.InvalidUtf8Boundary;
        try builder.feed(slice[0..process_len], offset);
        offset += process_len;
    }

    return builder.finish();
}

fn appendBreak(
    allocator: Allocator,
    stack_breaks: *[256]u32,
    stack_count: *usize,
    heap_breaks: *std.ArrayListUnmanaged(u32),
    use_heap: *bool,
    break_at: u32,
) !void {
    if (use_heap.*) {
        if (heap_breaks.items.len > 0 and heap_breaks.items[heap_breaks.items.len - 1] == break_at) return;
        try heap_breaks.append(allocator, break_at);
        return;
    }
    if (stack_count.* > 0 and stack_breaks[stack_count.* - 1] == break_at) return;
    if (stack_count.* < stack_breaks.len) {
        stack_breaks[stack_count.*] = break_at;
        stack_count.* += 1;
        return;
    }
    try heap_breaks.ensureTotalCapacity(allocator, stack_breaks.len * 2);
    for (stack_breaks[0..stack_count.*]) |bp| heap_breaks.appendAssumeCapacity(bp);
    use_heap.* = true;
    if (heap_breaks.items.len == 0 or heap_breaks.items[heap_breaks.items.len - 1] != break_at) {
        heap_breaks.appendAssumeCapacity(break_at);
    }
}

fn segmentColumns(seg: Segment, current_columns: usize, tab_size: usize) usize {
    if (seg.flags.is_tab) {
        const size = if (tab_size == 0) 4 else tab_size;
        return size - (current_columns % size);
    }
    return seg.columns;
}

fn utf8Len(byte: u8) usize {
    return if (byte < 0x80) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
}

fn decodeWideLen(text: []const u8) usize {
    if (text.len == 0) return 0;
    const first = text[0];
    if (first < 0x80) return 0;
    const cp_len = std.unicode.utf8ByteSequenceLength(first) catch return 0;
    if (cp_len == 0 or cp_len > text.len) return 0;
    const cp = std.unicode.utf8Decode(text[0..cp_len]) catch return 0;
    return if (isWideChar(cp)) cp_len else 0;
}

fn utf8AlignedPrefixLen(text: []const u8, preferred: usize) usize {
    if (text.len == 0 or preferred == 0) return 0;
    var idx: usize = 0;
    var last_boundary: usize = 0;
    const limit = @min(preferred, text.len);
    while (idx < limit) {
        const cp_len = utf8Len(text[idx]);
        if (idx + cp_len > limit) break;
        last_boundary = idx + cp_len;
        idx += cp_len;
    }
    return if (last_boundary > 0) last_boundary else limit;
}

fn isWideChar(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6);
}

test "prepared wrap line computes breaks for words and tabs" {
    var prepared = try prepareLine(std.testing.allocator, "alpha beta\tgamma");
    defer {
        prepared.deinit(std.testing.allocator);
        std.testing.allocator.destroy(prepared);
    }

    const breaks = try prepared.breaksForColumns(std.testing.allocator, 8, 4);
    defer if (breaks.len > 0) std.testing.allocator.free(breaks);

    try std.testing.expectEqual(@as(usize, 2), breaks.len);
    try std.testing.expectEqual(@as(u32, 6), breaks[0]);
    try std.testing.expectEqual(@as(u32, 11), breaks[1]);
}

test "prepared wrap line builder preserves chunked word runs" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.feed("alpha be", 0);
    try builder.feed("ta gamma", 8);
    var prepared = try builder.finish();
    defer {
        prepared.deinit(std.testing.allocator);
        std.testing.allocator.destroy(prepared);
    }

    try std.testing.expectEqual(@as(u32, 16), prepared.segment_count);
    const breaks = try prepared.breaksForColumns(std.testing.allocator, 6, 4);
    defer if (breaks.len > 0) std.testing.allocator.free(breaks);
    try std.testing.expectEqual(@as(usize, 2), breaks.len);
    try std.testing.expectEqual(@as(u32, 6), breaks[0]);
}

test "prepared wrap line supports space runs beyond u16" {
    const spaces = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(spaces);
    @memset(spaces, ' ');

    var prepared = try prepareLine(std.testing.allocator, spaces);
    defer {
        prepared.deinit(std.testing.allocator);
        std.testing.allocator.destroy(prepared);
    }
    try std.testing.expectEqual(@as(u32, 70_000), prepared.segments[0].columns);
}
