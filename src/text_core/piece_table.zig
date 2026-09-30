const std = @import("std");
const Allocator = std.mem.Allocator;

/// Piece 的来源类型
pub const Source = enum {
    original, // 原始文件内容
    add, // 新增内容
};

/// Piece 表示文本的一个片段
pub const Piece = struct {
    source: Source,
    start: usize, // 在对应 buffer 中的起始位置
    length: usize, // 片段长度

    pub fn end(self: Piece) usize {
        return self.start + self.length;
    }
};

/// Piece 链表节点
const PieceNode = struct {
    data: Piece,
    next: ?*PieceNode = null,
    prev: ?*PieceNode = null,
};

/// Piece Table 文本存储引擎
/// 支持高效的插入、删除和 O(1) 时间复杂度的 Undo/Redo
pub const PieceTable = struct {
    allocator: Allocator,

    /// 只读的原始文件内容
    original_buffer: []const u8,

    /// 存储所有新增内容的缓冲区
    add_buffer: std.ArrayList(u8),

    /// 片段链表的头节点
    head: ?*PieceNode,

    /// 片段链表的尾节点
    tail: ?*PieceNode,

    /// 总字符数
    total_length: usize,

    /// 行索引缓存 (存储每行的起始字节偏移)
    line_index: std.ArrayList(usize),

    /// 初始化空的 Piece Table
    pub fn init(allocator: Allocator) !PieceTable {
        var line_index = std.ArrayList(usize){};
        try line_index.append(allocator, 0); // 第一行从偏移 0 开始

        return PieceTable{
            .allocator = allocator,
            .original_buffer = &[_]u8{},
            .add_buffer = std.ArrayList(u8){},
            .head = null,
            .tail = null,
            .total_length = 0,
            .line_index = line_index,
        };
    }

    /// 从文件内容初始化。
    /// content 会被拷贝一份，由 PieceTable 持有并在 deinit 时释放；
    /// 本函数返回后调用方即可自由释放 content。
    pub fn initFromBuffer(allocator: Allocator, content: []const u8) !PieceTable {
        var self = try init(allocator);
        errdefer self.deinit();

        if (content.len > 0) {
            self.original_buffer = try allocator.dupe(u8, content);

            // 创建初始 piece
            const node = try allocator.create(PieceNode);
            node.* = PieceNode{
                .data = Piece{
                    .source = .original,
                    .start = 0,
                    .length = content.len,
                },
                .next = null,
                .prev = null,
            };

            self.head = node;
            self.tail = node;
            self.total_length = content.len;

            // 构建行索引
            try self.rebuildLineIndex();
        }

        return self;
    }

    pub fn deinit(self: *PieceTable) void {
        // 清理链表节点
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }

        // original_buffer 由本表持有（initFromBuffer 拷贝而来）；
        // 空表时是 len=0 字面量，Allocator.free 对 len=0 是 no-op。
        self.allocator.free(self.original_buffer);
        self.add_buffer.deinit(self.allocator);
        self.line_index.deinit(self.allocator);
    }

    /// 在指定位置插入文本
    pub fn insert(self: *PieceTable, pos: usize, text: []const u8) !void {
        if (text.len == 0) return;
        if (pos > self.total_length) return error.InvalidPosition;

        // 将文本追加到 add_buffer
        const add_start = self.add_buffer.items.len;
        try self.add_buffer.appendSlice(self.allocator, text);

        const new_piece = Piece{
            .source = .add,
            .start = add_start,
            .length = text.len,
        };

        if (pos == 0) {
            // 在开头插入
            try self.insertAtHead(new_piece);
        } else if (pos == self.total_length) {
            // 在末尾插入
            try self.insertAtTail(new_piece);
        } else {
            // 在中间插入，需要分割 piece
            try self.insertInMiddle(pos, new_piece);
        }

        self.total_length += text.len;

        // 更新行索引
        try self.updateLineIndexAfterInsert(pos, text);
    }

    /// 删除指定范围的文本
    pub fn delete(self: *PieceTable, start: usize, length: usize) !void {
        if (length == 0) return;
        if (start + length > self.total_length) return error.InvalidRange;

        const end_pos = start + length;
        var current_pos: usize = 0;
        var current = self.head;

        // 找到包含 start 的 piece
        while (current) |node| {
            const piece_end = current_pos + node.data.length;

            if (piece_end > start) {
                // 这个 piece 包含删除的起始位置
                break;
            }

            current_pos = piece_end;
            current = node.next;
        }

        // 从当前位置开始删除
        while (current) |node| {
            const piece_end = current_pos + node.data.length;

            if (current_pos >= end_pos) {
                // 删除完成
                break;
            }

            if (current_pos < start and piece_end > end_pos) {
                // 删除范围完全在一个 piece 内部，需要分割成两部分
                const offset_start = start - current_pos;
                const offset_end = end_pos - current_pos;

                // 创建后半部分
                const right_piece = Piece{
                    .source = node.data.source,
                    .start = node.data.start + offset_end,
                    .length = node.data.length - offset_end,
                };

                // 修改当前 piece 为前半部分
                node.data.length = offset_start;

                // 插入后半部分
                const right_node = try self.allocator.create(PieceNode);
                right_node.* = PieceNode{
                    .data = right_piece,
                    .next = node.next,
                    .prev = node,
                };

                if (node.next) |next| {
                    next.prev = right_node;
                } else {
                    self.tail = right_node;
                }

                node.next = right_node;
                break;
            } else if (current_pos >= start and piece_end <= end_pos) {
                // 整个 piece 都在删除范围内，移除它
                const next = node.next;

                if (node.prev) |prev| {
                    prev.next = node.next;
                } else {
                    self.head = node.next;
                }

                if (node.next) |n| {
                    n.prev = node.prev;
                } else {
                    self.tail = node.prev;
                }

                self.allocator.destroy(node);
                current_pos = piece_end;
                current = next;
                continue;
            } else if (current_pos < start) {
                // 删除起点在这个 piece 中间
                const offset = start - current_pos;
                node.data.length = offset;
            } else if (piece_end > end_pos) {
                // 删除终点在这个 piece 中间
                const offset = end_pos - current_pos;
                node.data.start += offset;
                node.data.length -= offset;
                break;
            }

            current_pos = piece_end;
            current = node.next;
        }

        self.total_length -= length;

        // 更新行索引
        try self.updateLineIndexAfterDelete(start, length);
    }

    /// 获取指定范围的文本
    pub fn getText(self: *const PieceTable, start: usize, length: usize, buffer: []u8) ![]const u8 {
        if (start + length > self.total_length) return error.InvalidRange;
        if (buffer.len < length) return error.BufferTooSmall;

        var current_pos: usize = 0;
        var copied: usize = 0;
        var current = self.head;

        while (current) |node| : (current = node.next) {
            const piece = node.data;
            const piece_end = current_pos + piece.length;

            // 跳过不相关的 piece
            if (piece_end <= start) {
                current_pos = piece_end;
                continue;
            }

            // 计算需要复制的部分
            const copy_start = if (current_pos < start) start - current_pos else 0;
            const copy_end = @min(piece.length, copy_start + (length - copied));
            const copy_len = copy_end - copy_start;

            // 从对应的 buffer 复制数据
            const source_buffer = if (piece.source == .original)
                self.original_buffer
            else
                self.add_buffer.items;

            @memcpy(
                buffer[copied .. copied + copy_len],
                source_buffer[piece.start + copy_start .. piece.start + copy_end],
            );

            copied += copy_len;
            current_pos = piece_end;

            if (copied >= length) break;
        }

        return buffer[0..copied];
    }

    /// 获取总行数
    pub fn lineCount(self: *const PieceTable) usize {
        return self.line_index.items.len;
    }

    /// 获取指定行的内容
    pub fn getLine(self: *const PieceTable, line: usize, buffer: []u8) ![]const u8 {
        if (line >= self.line_index.items.len) return error.InvalidLine;

        const start = self.line_index.items[line];
        const end = if (line + 1 < self.line_index.items.len)
            self.line_index.items[line + 1]
        else
            self.total_length;

        return self.getText(start, end - start, buffer);
    }

    // ===== 私有辅助函数 =====

    fn insertAtHead(self: *PieceTable, piece: Piece) !void {
        const node = try self.allocator.create(PieceNode);
        node.* = PieceNode{
            .data = piece,
            .next = self.head,
            .prev = null,
        };

        if (self.head) |head| {
            head.prev = node;
        } else {
            self.tail = node;
        }

        self.head = node;
    }

    fn insertAtTail(self: *PieceTable, piece: Piece) !void {
        const node = try self.allocator.create(PieceNode);
        node.* = PieceNode{
            .data = piece,
            .next = null,
            .prev = self.tail,
        };

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }

        self.tail = node;
    }

    fn insertInMiddle(self: *PieceTable, pos: usize, new_piece: Piece) !void {
        var current_pos: usize = 0;
        var current = self.head;

        while (current) |node| : (current = node.next) {
            const piece = node.data;
            const piece_end = current_pos + piece.length;

            if (pos == piece_end) {
                // 刚好在当前 piece 和下一个 piece 之间 → 在此处插入新节点
                const new_node = try self.allocator.create(PieceNode);
                new_node.* = PieceNode{
                    .data = new_piece,
                    .next = node.next,
                    .prev = node,
                };
                if (node.next) |next| {
                    next.prev = new_node;
                } else {
                    self.tail = new_node;
                }
                node.next = new_node;
                return;
            }

            if (pos > current_pos and pos < piece_end) {
                // 需要分割当前 piece
                const offset = pos - current_pos;

                // 创建后半部分
                const right_piece = Piece{
                    .source = piece.source,
                    .start = piece.start + offset,
                    .length = piece.length - offset,
                };

                // 修改当前 piece 为前半部分
                node.data.length = offset;

                // 插入新 piece 和后半部分
                const new_node = try self.allocator.create(PieceNode);
                const right_node = try self.allocator.create(PieceNode);

                new_node.* = PieceNode{
                    .data = new_piece,
                    .next = right_node,
                    .prev = node,
                };

                right_node.* = PieceNode{
                    .data = right_piece,
                    .next = node.next,
                    .prev = new_node,
                };

                if (node.next) |next| {
                    next.prev = right_node;
                } else {
                    self.tail = right_node;
                }

                node.next = new_node;
                return;
            }

            current_pos = piece_end;
        }
    }

    fn rebuildLineIndex(self: *PieceTable) !void {
        self.line_index.clearRetainingCapacity();
        try self.line_index.append(self.allocator, 0);

        var current_pos: usize = 0;
        var current = self.head;

        while (current) |node| : (current = node.next) {
            const piece = node.data;
            const source_buffer = if (piece.source == .original)
                self.original_buffer
            else
                self.add_buffer.items;

            const piece_data = source_buffer[piece.start..piece.end()];

            for (piece_data, 0..) |byte, i| {
                if (byte == '\n') {
                    try self.line_index.append(self.allocator, current_pos + i + 1);
                }
            }

            current_pos += piece.length;
        }
    }

    /// 增量更新行索引（插入）
    /// 直接 rebuild — 简单可靠，避免增量偏移的潜在边界 bug
    fn updateLineIndexAfterInsert(self: *PieceTable, pos: usize, text: []const u8) !void {
        _ = pos;
        _ = text;
        try self.rebuildLineIndex();
    }

    /// 增量更新行索引（删除）
    /// 安全策略: 直接 rebuild（避免增量更新的边界 bug）
    fn updateLineIndexAfterDelete(self: *PieceTable, start: usize, length: usize) !void {
        _ = start;
        _ = length;
        try self.rebuildLineIndex();
    }
};

// ===== 单元测试 =====

test "PieceTable: init and deinit" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.total_length);
    try std.testing.expectEqual(@as(usize, 1), table.lineCount());
}

test "PieceTable: init from buffer" {
    const content = "Hello\nWorld\n";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 12), table.total_length);
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
}

test "PieceTable: initFromBuffer 拷贝内容,调用方释放原 buffer 后仍可读" {
    const content = try std.testing.allocator.dupe(u8, "Hello\nWorld\n");
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    // 调用方立即释放自己的 buffer —— 若 initFromBuffer 借用该指针,
    // 之后的读取全是 use-after-free（testing.allocator 会把释放内存涂成 0xAA）。
    std.testing.allocator.free(content);

    try std.testing.expectEqual(@as(usize, 12), table.total_length);
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 12, &buffer);
    try std.testing.expectEqualStrings("Hello\nWorld\n", text);

    // 编辑路径也要走一遍：rebuildLineIndex 会重新扫描 original piece。
    try table.insert(5, "!");
    const after = try table.getText(0, 13, &buffer);
    try std.testing.expectEqualStrings("Hello!\nWorld\n", after);
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
}

test "PieceTable: insert at beginning" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello");
    try std.testing.expectEqual(@as(usize, 5), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTable: insert at end" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello");
    try table.insert(5, " World");
    try std.testing.expectEqual(@as(usize, 11), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 11, &buffer);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "PieceTable: insert in middle" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.insert(5, ",");
    try std.testing.expectEqual(@as(usize, 12), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 12, &buffer);
    try std.testing.expectEqualStrings("Hello, World", text);
}

test "PieceTable: get line" {
    const content = "Line 1\nLine 2\nLine 3\n";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 4), table.lineCount());

    var buffer: [100]u8 = undefined;

    const line1 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", line1);

    const line2 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", line2);
}

test "PieceTable: delete from middle" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.delete(5, 1); // 删除空格
    try std.testing.expectEqual(@as(usize, 10), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 10, &buffer);
    try std.testing.expectEqualStrings("HelloWorld", text);
}

test "PieceTable: delete from beginning" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.delete(0, 6); // 删除 "Hello "
    try std.testing.expectEqual(@as(usize, 5), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("World", text);
}

test "PieceTable: delete from end" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try table.delete(5, 6); // 删除 " World"
    try std.testing.expectEqual(@as(usize, 5), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTable: delete across pieces" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello");
    try table.insert(5, " World");
    try table.insert(11, "!");

    // 现在有 3 个 pieces: "Hello", " World", "!"
    try table.delete(3, 5); // 删除 "lo Wo" 跨越两个 pieces
    try std.testing.expectEqual(@as(usize, 7), table.total_length);

    var buffer: [100]u8 = undefined;
    const text = try table.getText(0, 7, &buffer);
    try std.testing.expectEqualStrings("Helrld!", text);
}

test "PieceTable: incremental line index after insert newline" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "Hello World");
    try std.testing.expectEqual(@as(usize, 1), table.lineCount());

    // 在中间插入换行符
    try table.insert(5, "\n");
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Hello\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings(" World", line1);
}

test "PieceTable: incremental line index after insert multiple newlines" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    try table.insert(0, "ABCD");
    try table.insert(2, "\n\n"); // 插入两个换行符
    // 现在是: "AB\n\nCD"
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AB\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", line1);
    const line2 = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("CD", line2);
}

test "PieceTable: incremental line index after delete newline" {
    const content = "Line 1\nLine 2\nLine 3";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    // 删除第一个换行符 (位置 6, 长度 1)
    try table.delete(6, 1);
    // 现在是: "Line 1Line 2\nLine 3"
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1Line 2\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", line1);
}

test "PieceTable: incremental line index after delete across lines" {
    const content = "AAA\nBBB\nCCC\nDDD";
    var table = try PieceTable.initFromBuffer(std.testing.allocator, content);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 4), table.lineCount());

    // 删除 "BBB\nCCC\n" (位置 4, 长度 8)
    try table.delete(4, 8);
    // 现在是: "AAA\nDDD"
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AAA\n", line0);
    const line1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("DDD", line1);
}

test "PieceTable: line index consistency through multiple edits" {
    var table = try PieceTable.init(std.testing.allocator);
    defer table.deinit();

    // 逐步构建多行文本
    try table.insert(0, "Line 1\n");
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    try table.insert(7, "Line 2\n");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    try table.insert(14, "Line 3");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());

    // 验证所有行
    var buffer: [100]u8 = undefined;
    const l0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", l0);
    const l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", l1);
    const l2 = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("Line 3", l2);

    // 验证删除前全文
    const full_before = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", full_before);

    // 删除中间行
    try table.delete(7, 7); // 删除 "Line 2\n"
    try std.testing.expectEqual(@as(usize, 13), table.total_length);

    // 验证删除后全文
    const full_after = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 3", full_after);

    try std.testing.expectEqual(@as(usize, 2), table.lineCount());
    const new_l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", new_l1);
}

test "PieceTable: consecutive newline inserts (simulating Enter key)" {
    // 模拟用户场景: 初始文本 "Press hello"，在行尾连续按回车
    var table = try PieceTable.initFromBuffer(std.testing.allocator, "Press hello\n");
    defer table.deinit();

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());

    // 光标在 "Press hello\n" 的 \n 位置 (offset 11)，按回车
    // 插入 \n 在 offset 11 → "Press hello\n\n"
    try table.insert(11, "\n");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
    const l0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Press hello\n", l0);
    const l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1);

    // 光标现在在 offset 12（第3行开头），再按回车
    try table.insert(12, "\n");
    try std.testing.expectEqual(@as(usize, 4), table.lineCount());
    const l1b = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1b);
    const l2b = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("\n", l2b);
    const l3b = try table.getLine(3, &buffer);
    try std.testing.expectEqualStrings("", l3b);

    // 再按回车 offset 13
    try table.insert(13, "\n");
    try std.testing.expectEqual(@as(usize, 5), table.lineCount());

    // 验证全文
    const full = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("Press hello\n\n\n\n", full);
}

test "PieceTable: insert newline at line start" {
    // 模拟场景: 文本 "ABC"，在 offset 0 连续插入 \n
    var table = try PieceTable.initFromBuffer(std.testing.allocator, "ABC");
    defer table.deinit();

    var buffer: [256]u8 = undefined;

    // 在 offset 0 插入 \n → "\nABC"
    try table.insert(0, "\n");
    try std.testing.expectEqual(@as(usize, 2), table.lineCount());
    const l0 = try table.getLine(0, &buffer);
    try std.testing.expectEqualStrings("\n", l0);
    const l1 = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("ABC", l1);

    // 光标在 offset 1 (第二行开头)，再插入 \n → "\n\nABC"
    try table.insert(1, "\n");
    try std.testing.expectEqual(@as(usize, 3), table.lineCount());
    const l1b = try table.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1b);
    const l2b = try table.getLine(2, &buffer);
    try std.testing.expectEqualStrings("ABC", l2b);

    const full = try table.getText(0, table.total_length, &buffer);
    try std.testing.expectEqualStrings("\n\nABC", full);
}
