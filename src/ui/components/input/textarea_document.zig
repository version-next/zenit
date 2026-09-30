/// TextareaDocument — 轻量文档类型
///
/// 满足 DocCursor(Doc) + WrapMap(Doc) 的 comptime duck typing 接口。
/// 使用连续 u8 数组 + line_starts 索引，适合 Textarea 的中等规模文本。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core_mod = @import("text_core");
pub const LineCol = core_mod.cursor.LineCol;

pub const TextareaDocument = struct {
    allocator: Allocator,
    text: std.ArrayListUnmanaged(u8) = .{},
    /// 每行的起始字节偏移（line_starts[0] == 0 恒成立）
    line_starts: std.ArrayListUnmanaged(usize) = .{},

    pub fn init(allocator: Allocator) TextareaDocument {
        return initFallible(allocator) catch @panic("OOM: TextareaDocument.init 无法建立 line_starts[0]=0 不变式");
    }

    /// Fallible builders must establish the first-line invariant before
    /// publishing the document, and propagate allocation failure to callers.
    pub fn initFallible(allocator: Allocator) !TextareaDocument {
        var doc = TextareaDocument{ .allocator = allocator };
        try doc.line_starts.append(allocator, 0);
        return doc;
    }

    pub fn deinit(self: *TextareaDocument) void {
        self.text.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
    }

    /// Prepare text and every line start without changing the live document.
    /// The caller can still allocate its undo snapshot before publishing.
    pub const PreparedReplace = struct {
        owner: *TextareaDocument,
        candidate: TextareaDocument,
        active: bool = true,

        pub fn deinit(self: *PreparedReplace) void {
            if (self.active) self.candidate.deinit();
            self.active = false;
        }

        pub fn commit(self: *PreparedReplace) void {
            std.debug.assert(self.active);
            std.mem.swap(TextareaDocument, self.owner, &self.candidate);
            self.deinit();
        }
    };

    pub fn prepareReplace(self: *TextareaDocument, start: usize, end: usize, input: []const u8) !PreparedReplace {
        if (start > end or end > self.text.items.len) return error.InvalidRange;
        var candidate: TextareaDocument = .{ .allocator = self.allocator };
        errdefer candidate.deinit();
        const total = try std.math.add(usize, self.text.items.len - (end - start), input.len);
        try candidate.text.ensureTotalCapacity(self.allocator, total);
        candidate.text.appendSliceAssumeCapacity(self.text.items[0..start]);
        candidate.text.appendSliceAssumeCapacity(input);
        candidate.text.appendSliceAssumeCapacity(self.text.items[end..]);
        try candidate.line_starts.append(self.allocator, 0);
        for (candidate.text.items, 0..) |byte, i| {
            if (byte == '\n') try candidate.line_starts.append(self.allocator, i + 1);
        }
        return .{ .owner = self, .candidate = candidate };
    }

    // ===== DocCursor 接口 (8 个) =====

    pub fn totalLength(self: *const TextareaDocument) usize {
        return self.text.items.len;
    }

    pub fn lineCount(self: *const TextareaDocument) usize {
        return self.line_starts.items.len;
    }

    pub fn offsetToLineCol(self: *const TextareaDocument, offset: usize) LineCol {
        const off = @min(offset, self.text.items.len);
        const starts = self.line_starts.items;
        // 二分查找：找到最大的 line 使得 line_starts[line] <= off
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= off) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line = if (lo > 0) lo - 1 else 0;
        return .{ .line = line, .col = off - starts[line] };
    }

    pub fn lineColToOffset(self: *const TextareaDocument, line: usize, col: usize) usize {
        const starts = self.line_starts.items;
        if (line >= starts.len) return self.text.items.len;
        const line_start = starts[line];
        const line_end = self.getLineEnd(line);
        return line_start + @min(col, line_end - line_start);
    }

    pub fn getLineStart(self: *const TextareaDocument, line: usize) usize {
        if (line >= self.line_starts.items.len) return self.text.items.len;
        return self.line_starts.items[line];
    }

    pub fn getLineEnd(self: *const TextareaDocument, line: usize) usize {
        const starts = self.line_starts.items;
        if (line >= starts.len) return self.text.items.len;
        if (line + 1 < starts.len) {
            // 行尾 = 下一行起始 - 1 (跳过 \n)
            return starts[line + 1] - 1;
        }
        return self.text.items.len;
    }

    pub fn getByteAt(self: *const TextareaDocument, offset: usize) ?u8 {
        if (offset >= self.text.items.len) return null;
        return self.text.items[offset];
    }

    pub fn deleteRange(self: *TextareaDocument, start: usize, len: usize) !void {
        if (len == 0) return;
        const actual_start = @min(start, self.text.items.len);
        const actual_end = actual_start + @min(len, self.text.items.len - actual_start);
        const actual_len = actual_end - actual_start;
        if (actual_len == 0) return;

        // 删除文本
        const items = self.text.items;
        if (actual_end < items.len) {
            std.mem.copyForwards(u8, items[actual_start .. items.len - actual_len], items[actual_end..items.len]);
        }
        self.text.shrinkRetainingCapacity(items.len - actual_len);

        // Deletion cannot add lines, so the existing index capacity suffices.
        self.line_starts.clearRetainingCapacity();
        self.line_starts.appendAssumeCapacity(0);
        for (self.text.items, 0..) |byte, i| {
            if (byte == '\n') self.line_starts.appendAssumeCapacity(i + 1);
        }
    }

    // ===== WrapMap 额外接口 (3 个) =====

    pub fn getLineLength(self: *const TextareaDocument, line: usize) usize {
        return self.getLineEnd(line) - self.getLineStart(line);
    }

    pub fn getTextBuf(self: *const TextareaDocument, start: usize, len: usize, buf: []u8) ![]const u8 {
        const actual_start = @min(start, self.text.items.len);
        const actual_end = actual_start + @min(len, self.text.items.len - actual_start);
        const actual_len = actual_end - actual_start;
        if (actual_len == 0) return buf[0..0];
        const copy_len = @min(actual_len, buf.len);
        @memcpy(buf[0..copy_len], self.text.items[actual_start .. actual_start + copy_len]);
        return buf[0..copy_len];
    }

    pub fn getTextAlloc(self: *const TextareaDocument, alloc: Allocator, start: usize, len: usize) ![]const u8 {
        const actual_start = @min(start, self.text.items.len);
        const actual_end = actual_start + @min(len, self.text.items.len - actual_start);
        const actual_len = actual_end - actual_start;
        if (actual_len == 0) {
            const empty = try alloc.alloc(u8, 0);
            return empty;
        }
        const result = try alloc.alloc(u8, actual_len);
        @memcpy(result, self.text.items[actual_start..actual_end]);
        return result;
    }

    // ===== 自身方法 =====

    /// Compatibility wrapper: a failed replacement preserves the old document.
    pub fn setText(self: *TextareaDocument, content: []const u8) void {
        self.setTextChecked(content) catch return;
    }

    pub fn setTextChecked(self: *TextareaDocument, content: []const u8) !void {
        var prepared = try self.prepareReplace(0, self.totalLength(), content);
        defer prepared.deinit();
        prepared.commit();
    }

    /// Prepare both text and indexes; content may borrow the current document.
    pub fn insertAt(self: *TextareaDocument, offset: usize, content: []const u8) !void {
        if (content.len == 0) return;
        const pos = @min(offset, self.text.items.len);
        var prepared = try self.prepareReplace(pos, pos, content);
        defer prepared.deinit();
        prepared.commit();
    }

    /// 获取全部文本
    pub fn getText(self: *const TextareaDocument) []const u8 {
        return self.text.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TextareaDocument: init and basic ops" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.totalLength());
    try std.testing.expectEqual(@as(usize, 1), doc.lineCount());
}

test "TextareaDocument: setText and lineCount" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("hello\nworld\nfoo");
    try std.testing.expectEqual(@as(usize, 15), doc.totalLength());
    try std.testing.expectEqual(@as(usize, 3), doc.lineCount());

    try std.testing.expectEqual(@as(usize, 0), doc.getLineStart(0));
    try std.testing.expectEqual(@as(usize, 5), doc.getLineEnd(0));
    try std.testing.expectEqual(@as(usize, 6), doc.getLineStart(1));
    try std.testing.expectEqual(@as(usize, 11), doc.getLineEnd(1));
    try std.testing.expectEqual(@as(usize, 12), doc.getLineStart(2));
    try std.testing.expectEqual(@as(usize, 15), doc.getLineEnd(2));
}

test "TextareaDocument: offsetToLineCol" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("hello\nworld");
    const lc0 = doc.offsetToLineCol(0);
    try std.testing.expectEqual(@as(usize, 0), lc0.line);
    try std.testing.expectEqual(@as(usize, 0), lc0.col);

    const lc5 = doc.offsetToLineCol(5);
    try std.testing.expectEqual(@as(usize, 0), lc5.line);
    try std.testing.expectEqual(@as(usize, 5), lc5.col);

    const lc6 = doc.offsetToLineCol(6);
    try std.testing.expectEqual(@as(usize, 1), lc6.line);
    try std.testing.expectEqual(@as(usize, 0), lc6.col);

    const lc8 = doc.offsetToLineCol(8);
    try std.testing.expectEqual(@as(usize, 1), lc8.line);
    try std.testing.expectEqual(@as(usize, 2), lc8.col);
}

test "TextareaDocument: lineColToOffset" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("hello\nworld");
    try std.testing.expectEqual(@as(usize, 0), doc.lineColToOffset(0, 0));
    try std.testing.expectEqual(@as(usize, 3), doc.lineColToOffset(0, 3));
    try std.testing.expectEqual(@as(usize, 5), doc.lineColToOffset(0, 100)); // clamp
    try std.testing.expectEqual(@as(usize, 6), doc.lineColToOffset(1, 0));
    try std.testing.expectEqual(@as(usize, 9), doc.lineColToOffset(1, 3));
}

test "TextareaDocument: insertAt" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("helo");
    try doc.insertAt(3, "l");
    try std.testing.expectEqualStrings("hello", doc.getText());

    try doc.insertAt(5, "\nworld");
    try std.testing.expectEqualStrings("hello\nworld", doc.getText());
    try std.testing.expectEqual(@as(usize, 2), doc.lineCount());
}

test "TextareaDocument: deleteRange" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("hello\nworld");
    try doc.deleteRange(5, 1); // delete \n
    try std.testing.expectEqualStrings("helloworld", doc.getText());
    try std.testing.expectEqual(@as(usize, 1), doc.lineCount());

    try doc.deleteRange(0, 5); // delete "hello"
    try std.testing.expectEqualStrings("world", doc.getText());
}

test "TextareaDocument: getByteAt" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("abc");
    try std.testing.expectEqual(@as(?u8, 'a'), doc.getByteAt(0));
    try std.testing.expectEqual(@as(?u8, 'c'), doc.getByteAt(2));
    try std.testing.expectEqual(@as(?u8, null), doc.getByteAt(3));
}

test "TextareaDocument: getTextBuf and getTextAlloc" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("hello world");
    var buf: [5]u8 = undefined;
    const slice = try doc.getTextBuf(6, 5, &buf);
    try std.testing.expectEqualStrings("world", slice);

    const heap = try doc.getTextAlloc(alloc, 0, 5);
    defer alloc.free(heap);
    try std.testing.expectEqualStrings("hello", heap);
}

test "TextareaDocument: getLineLength" {
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("abc\nde\nfghij");
    try std.testing.expectEqual(@as(usize, 3), doc.getLineLength(0));
    try std.testing.expectEqual(@as(usize, 2), doc.getLineLength(1));
    try std.testing.expectEqual(@as(usize, 5), doc.getLineLength(2));
}

test "TextareaDocument: DocCursor compatibility" {
    const DocCursor = core_mod.cursor.DocCursor;
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("hello\nworld");
    var cursor = DocCursor(TextareaDocument){};

    // moveRight
    cursor.moveRight(&doc, false);
    try std.testing.expectEqual(@as(usize, 1), cursor.offset);

    // moveTo end of first line
    cursor.moveTo(5);
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);

    // moveDown
    cursor.moveDown(&doc, false);
    try std.testing.expectEqual(@as(usize, 11), cursor.offset); // "world" end (col 5 clamped)

    // moveUp
    cursor.moveUp(&doc, false);
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);
}

test "TextareaDocument: WrapMap compatibility" {
    const WrapMap = core_mod.wrap_map.WrapMap;
    const alloc = std.testing.allocator;
    var doc = TextareaDocument.init(alloc);
    defer doc.deinit();

    doc.setText("short\nthis is a longer line that might wrap");

    var wm = WrapMap(TextareaDocument).init(alloc);
    defer wm.deinit();
    wm.char_width = 8.0;
    wm.setWrapWidth(100, &doc);
    wm.setEnabled(true, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    // 至少有 2 个 display line（第二行会被 wrap）
    try std.testing.expect(wm.total_display_lines >= 2);

    // bufferToDisplay 应该正常工作
    const dp = wm.bufferToDisplay(0, 3);
    try std.testing.expectEqual(@as(u32, 0), dp.display_line);
    try std.testing.expectEqual(@as(usize, 3), dp.display_col);
}

test "TextareaDocument allocation failure keeps replacement text and line index" {
    const t = std.testing;
    for ([_]bool{ false, true }) |insertion| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var doc = TextareaDocument.init(failing.allocator());
        defer doc.deinit();
        doc.setText("keep\ntail");
        const before_text = doc.text.items.ptr;
        const before_lines = doc.line_starts.items.ptr;
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        if (insertion) {
            // Fits the existing text allocation, but exceeds line index capacity.
            _ = doc.insertAt(0, "\n" ** 12) catch {};
        } else doc.setText("new\n" ** 300);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try t.expect(failing.has_induced_failure);
        try t.expectEqualStrings("keep\ntail", doc.getText());
        try t.expectEqualSlices(usize, &.{ 0, 5 }, doc.line_starts.items);
        try t.expectEqual(before_text, doc.text.items.ptr);
        try t.expectEqual(before_lines, doc.line_starts.items.ptr);
    }
}

test "TextareaDocument replacement and aliased insertion fail atomically at every allocation" {
    const t = std.testing;
    for ([_]bool{ false, true }) |insertion| {
        var succeeded = false;
        for (0..100) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            const initial = "a\n" ** 100;
            try doc.setTextChecked(initial);
            const old_text = doc.text.items.ptr;
            const old_lines = doc.line_starts.items.ptr;
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            const result = if (insertion) doc.insertAt(1, doc.getText()) else doc.setTextChecked("b\n" ** 300);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                succeeded = true;
            } else |_| {
                try t.expect(failing.has_induced_failure);
                try t.expectEqualStrings(initial, doc.getText());
                try t.expectEqual(old_text, doc.text.items.ptr);
                try t.expectEqual(old_lines, doc.line_starts.items.ptr);
                try t.expectEqual(@as(usize, 101), doc.lineCount());
                for (doc.line_starts.items, 0..) |offset, line| try t.expectEqual(line * 2, offset);
                if (insertion) try doc.insertAt(1, doc.getText()) else try doc.setTextChecked("b\n" ** 300);
            }
            const expected = if (insertion) "a" ++ initial ++ initial[1..] else "b\n" ** 300;
            try t.expectEqualStrings(expected, doc.getText());
            var line: usize = 1;
            for (expected, 0..) |byte, i| {
                if (byte == '\n') {
                    try t.expectEqual(i + 1, doc.getLineStart(line));
                    line += 1;
                }
            }
            try t.expectEqual(line, doc.lineCount());
            if (succeeded) break;
        }
        try t.expect(succeeded);
    }
}

test "TextareaDocument deletion allocates nothing and public ranges saturate" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var doc = TextareaDocument.init(failing.allocator());
    defer doc.deinit();
    try doc.setTextChecked("ab\ncd\nef");
    const max = std.math.maxInt(usize);
    var buffer: [20]u8 = undefined;
    try t.expectEqualStrings("d\nef", try doc.getTextBuf(4, max, &buffer));
    const suffix = try doc.getTextAlloc(t.allocator, 4, max);
    defer t.allocator.free(suffix);
    try t.expectEqualStrings("d\nef", suffix);
    try t.expectEqualStrings("", try doc.getTextBuf(max, max, &buffer));
    try t.expectEqual(@as(usize, 5), doc.lineColToOffset(1, max));
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    failing.resize_fail_index = failing.resize_index;
    try doc.deleteRange(2, 3);
    try t.expectEqualStrings("ab\nef", doc.getText());
    try t.expectEqualSlices(usize, &.{ 0, 3 }, doc.line_starts.items);
    try doc.deleteRange(max, max);
    try doc.deleteRange(3, max);
    try t.expectEqualStrings("ab\n", doc.getText());
    try t.expectEqualSlices(usize, &.{ 0, 3 }, doc.line_starts.items);
    try doc.deleteRange(0, max);
    try t.expectEqualStrings("", doc.getText());
    try t.expectEqualSlices(usize, &.{0}, doc.line_starts.items);
    try t.expectEqual(allocations, failing.alloc_index);
}
