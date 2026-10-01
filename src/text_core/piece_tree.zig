/// PieceTree，基于 SumTree 的高性能文本存储引擎
///
/// 替代 PieceTable 的链表结构，使用 SumTree(TreePiece, PieceSummary) 实现：
/// - 插入/删除: O(log P)（P = piece 数量）
/// - 行索引维护: 嵌入在 Summary 中，O(1) 获取行数，O(log P) 行号⟷偏移转换
/// - 不再需要 rebuildLineIndex()
///
/// 与 PieceTable 的公共 API 功能对等，用于无缝替换。
const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const sum_tree = @import("sum_tree.zig");
const SumTree = sum_tree.SumTree;
const piece_stats = @import("piece_stats.zig");

/// Piece 来源
pub const Source = enum { original, add };

/// PieceSummary，每个子树的聚合摘要
///
/// 对齐 Zed TextSummary：嵌入 first/last/longest_row_chars，
/// O(log N) 维护文档最长行，无需全文件扫描。
pub const PieceSummary = struct {
    bytes: usize = 0,
    lines: usize = 0, // 换行符数量
    /// 第一行的字符数（用于相邻 piece 拼接时计算跨 piece 行宽）
    first_line_chars: u32 = 0,
    /// 最后一行的字符数（同上，last_line + next.first_line 可能形成最长行）
    last_line_chars: u32 = 0,
    /// 此子树内最长行的字符数
    longest_row_chars: u32 = 0,

    pub const ZERO: PieceSummary = .{};

    /// 合并两个 summary（对齐 Zed TextSummary::AddAssign）。
    /// 关键：拼接处 self.last_line + other.first_line 可能形成新的最长行。
    pub fn add(self: PieceSummary, other: PieceSummary) PieceSummary {
        // 拼接处的行宽 = self 最后一行 + other 第一行
        const joined_chars: u32 = self.last_line_chars +| other.first_line_chars;
        var longest = self.longest_row_chars;
        if (joined_chars > longest) longest = joined_chars;
        if (other.longest_row_chars > longest) longest = other.longest_row_chars;

        return .{
            .bytes = self.bytes + other.bytes,
            .lines = self.lines + other.lines,
            // first_line_chars: 如果 self 没有换行，first_line 延伸到 other.first_line
            .first_line_chars = if (self.lines == 0)
                self.first_line_chars +| other.first_line_chars
            else
                self.first_line_chars,
            // last_line_chars: 如果 other 没有换行，last_line 从 self.last_line 延伸
            .last_line_chars = if (other.lines == 0)
                self.last_line_chars +| other.last_line_chars
            else
                other.last_line_chars,
            .longest_row_chars = longest,
        };
    }
};

/// TreePiece, SumTree 的叶节点 item
pub const TreePiece = struct {
    source: Source,
    start: usize,
    length: usize,
    newline_count: usize,
    first_line_chars: u32 = 0,
    last_line_chars: u32 = 0,
    longest_row_chars: u32 = 0,

    pub fn summary(self: TreePiece) PieceSummary {
        return .{
            .bytes = self.length,
            .lines = self.newline_count,
            .first_line_chars = self.first_line_chars,
            .last_line_chars = self.last_line_chars,
            .longest_row_chars = self.longest_row_chars,
        };
    }

    /// 从文本内容构造 TreePiece（一次遍历计算所有统计信息）
    pub fn fromText(source: Source, start: usize, text: []const u8) TreePiece {
        const stats = PieceTree.scanTextStats(text);
        return .{
            .source = source,
            .start = start,
            .length = text.len,
            .newline_count = stats.newline_count,
            .first_line_chars = stats.first_line_chars,
            .last_line_chars = stats.last_line_chars,
            .longest_row_chars = stats.longest_row_chars,
        };
    }
};

/// Dimension: 按字节偏移查找
pub const ByteDim = struct {
    pub fn fromSummary(s: PieceSummary) usize {
        return s.bytes;
    }
};

/// Dimension: 按行号查找
pub const LineDim = struct {
    pub fn fromSummary(s: PieceSummary) usize {
        return s.lines;
    }
};

const Tree = SumTree(TreePiece, PieceSummary);
const ADD_BUFFER_PAGE_SIZE: usize = 64 * 1024;

const AddBufferPage = struct {
    allocator: Allocator,
    start: usize,
    data: []const u8,
    ref_count: Atomic(usize),

    fn create(allocator: Allocator, start: usize, data: []const u8) !*AddBufferPage {
        const copy = try allocator.dupe(u8, data);
        errdefer allocator.free(copy);
        const self = try allocator.create(AddBufferPage);
        self.* = .{
            .allocator = allocator,
            .start = start,
            .data = copy,
            .ref_count = Atomic(usize).init(1),
        };
        return self;
    }

    fn retain(self: *AddBufferPage) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn release(self: *AddBufferPage) void {
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }
};

fn hasValidPieceBounds(piece: TreePiece, source_buf: []const u8) bool {
    if (piece.start > source_buf.len) return false;
    return piece.length <= source_buf.len - piece.start;
}

/// 零拷贝 chunk 迭代器，逐 piece 返回 []const u8 直接切片
///
/// 用法：
///   var it = piece_tree.chunksInRange(start, len);
///   while (it.next()) |chunk| { ... }  // chunk 是零拷贝引用
pub fn ChunkIterator(comptime Container: type) type {
    return struct {
        const Self = @This();
        container: *const Container,
        index: usize, // 当前 piece 在 SumTree 中的 item index
        offset_in_piece: usize, // 当前 piece 内的起始偏移
        remaining: usize, // 剩余要迭代的字节数

        /// 返回当前 chunk 的零拷贝切片，推进到下一个 piece
        pub fn next(self: *Self) ?[]const u8 {
            if (self.remaining == 0) return null;
            const piece = self.container.tree.get(self.index) orelse return null;
            const piece_buf = self.container.getPieceBuffer(piece) orelse return null;
            const available = piece_buf.len - self.offset_in_piece;
            if (available == 0) return null;
            const chunk_len = @min(available, self.remaining);
            const slice_start = self.offset_in_piece;
            const result = piece_buf[slice_start .. slice_start + chunk_len];
            self.remaining -= chunk_len;
            self.offset_in_piece = 0;
            self.index += 1;
            return result;
        }

        /// 重定位到新的字节偏移（用于 tree-sitter 非顺序回调）
        pub fn seekTo(self: *Self, byte_offset: usize, total_len: usize) void {
            const clamped = @min(byte_offset, total_len);
            const seek_result = self.container.tree.seek(ByteDim, clamped);
            self.index = seek_result.index;
            self.offset_in_piece = seek_result.offset_in_item;
            self.remaining = total_len - clamped;
        }
    };
}

/// PieceTreeSnapshot，后台线程安全的只读文档视图
///
/// 通过 COW snapshot 共享 SumTree 节点（引用计数）和 append pages。
/// 用于后台 tree-sitter 解析等场景。
pub const PieceTreeSnapshot = struct {
    tree: Tree,
    original_buffer: []const u8, // 只读共享（不可变）
    original_page: ?*AddBufferPage = null,
    add_pages: []const *AddBufferPage,
    allocator: Allocator,

    /// 零拷贝：返回 offset 处所在 piece 内的直接 slice（不拷贝）。
    /// 返回从 offset 到该 piece 末尾的连续内存区域。
    pub const ChunkResult = struct {
        ptr: [*]const u8,
        len: usize,
    };

    pub fn deinit(self: *PieceTreeSnapshot) void {
        if (self.original_page) |page| page.release();
        for (self.add_pages) |page| page.release();
        if (self.add_pages.len > 0) self.allocator.free(@constCast(self.add_pages));
        self.tree.deinit();
    }

    pub fn totalLength(self: *const PieceTreeSnapshot) usize {
        return self.tree.summary().bytes;
    }

    pub fn lineCount(self: *const PieceTreeSnapshot) usize {
        return self.tree.summary().lines + 1;
    }

    pub fn getText(self: *const PieceTreeSnapshot, start: usize, length: usize, buffer: []u8) ![]const u8 {
        const total = self.totalLength();
        if (start > total or length > total - start) return error.InvalidRange;
        if (buffer.len < length) return error.BufferTooSmall;
        if (length == 0) return buffer[0..0];

        var pieces = self.tree.iterator();
        var offset_in_piece = pieces.seekTo(ByteDim, start) orelse return error.CorruptPieceTree;
        var copied: usize = 0;
        var remaining = length;

        while (remaining > 0) {
            const piece = pieces.next() orelse return error.CorruptPieceTree;
            const piece_buf = self.getPieceBuffer(piece) orelse return error.CorruptPieceTree;
            if (offset_in_piece > piece_buf.len) return error.CorruptPieceTree;
            const available = piece_buf.len - offset_in_piece;
            // Public mutators never retain empty pieces; zero progress is corruption.
            if (available == 0) return error.CorruptPieceTree;
            const to_copy = @min(available, remaining);
            @memcpy(
                buffer[copied .. copied + to_copy],
                piece_buf[offset_in_piece .. offset_in_piece + to_copy],
            );
            copied += to_copy;
            remaining -= to_copy;
            offset_in_piece = 0;
        }
        if (remaining != 0) return error.CorruptPieceTree;
        return buffer[0..copied];
    }

    pub fn getChunkAt(self: *const PieceTreeSnapshot, offset: usize) ?ChunkResult {
        const total = self.totalLength();
        if (offset >= total) return null;

        const seek_result = self.tree.seek(ByteDim, offset);
        const piece = seek_result.item orelse return null;
        const piece_buf = self.getPieceBuffer(piece) orelse return null;
        const offset_in_piece = seek_result.offset_in_item;
        if (offset_in_piece >= piece_buf.len) return null;
        return .{
            .ptr = piece_buf[offset_in_piece..].ptr,
            .len = piece_buf.len - offset_in_piece,
        };
    }

    pub fn offsetToLine(self: *const PieceTreeSnapshot, offset: usize) usize {
        const root = self.tree.root orelse return 0;
        const total = self.totalLength();
        const clamped = @min(offset, total);
        return self.offsetToLineInNode(root, clamped);
    }

    fn offsetToLineInNode(self: *const PieceTreeSnapshot, node: *const Tree.Node, remaining_bytes: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (0..internal.len) |i| {
                    const child_bytes = internal.summaries[i].bytes;
                    if (child_bytes > remaining) {
                        return lines + self.offsetToLineInNode(internal.children[i], remaining);
                    }
                    lines += internal.summaries[i].lines;
                    remaining -= child_bytes;
                }
                return lines;
            },
            .leaf => |*leaf| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.length > remaining) {
                        const buf = self.getPieceBuffer(piece) orelse return lines;
                        for (buf[0..remaining]) |byte| {
                            if (byte == '\n') lines += 1;
                        }
                        return lines;
                    }
                    lines += piece.newline_count;
                    remaining -= piece.length;
                }
                return lines;
            },
        }
    }

    pub fn lineToOffset(self: *const PieceTreeSnapshot, target_line: usize) usize {
        if (target_line == 0) return 0;
        const root = self.tree.root orelse return 0;
        return self.lineToOffsetInNode(root, target_line);
    }

    fn lineToOffsetInNode(self: *const PieceTreeSnapshot, node: *const Tree.Node, remaining_lines: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (0..internal.len) |i| {
                    const child_lines = internal.summaries[i].lines;
                    if (child_lines >= remaining) {
                        return byte_offset + self.lineToOffsetInNode(internal.children[i], remaining);
                    }
                    remaining -= child_lines;
                    byte_offset += internal.summaries[i].bytes;
                }
                return byte_offset;
            },
            .leaf => |*leaf| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.newline_count >= remaining) {
                        const buf = self.getPieceBuffer(piece) orelse return byte_offset;
                        var count: usize = 0;
                        for (buf, 0..) |byte, j| {
                            if (byte == '\n') {
                                count += 1;
                                if (count == remaining) return byte_offset + j + 1;
                            }
                        }
                        return byte_offset + piece.length;
                    }
                    remaining -= piece.newline_count;
                    byte_offset += piece.length;
                }
                return byte_offset;
            },
        }
    }

    /// 零拷贝 chunk 迭代器：逐 piece 返回直接引用，无 memcpy
    pub fn chunksInRange(self: *const PieceTreeSnapshot, start: usize, len: usize) ChunkIterator(PieceTreeSnapshot) {
        const total = self.totalLength();
        const clamped_start = @min(start, total);
        const clamped_len = @min(len, total - clamped_start);
        if (clamped_len == 0) return .{ .container = self, .index = 0, .offset_in_piece = 0, .remaining = 0 };
        const seek_result = self.tree.seek(ByteDim, clamped_start);
        return .{
            .container = self,
            .index = seek_result.index,
            .offset_in_piece = seek_result.offset_in_item,
            .remaining = clamped_len,
        };
    }

    fn getPieceBuffer(self: *const PieceTreeSnapshot, piece: TreePiece) ?[]const u8 {
        return switch (piece.source) {
            .original => blk: {
                if (!hasValidPieceBounds(piece, self.original_buffer)) return null;
                break :blk self.original_buffer[piece.start .. piece.start + piece.length];
            },
            .add => self.getAddPageSlice(piece.start, piece.length),
        };
    }

    fn getAddPageSlice(self: *const PieceTreeSnapshot, start: usize, len: usize) ?[]const u8 {
        for (self.add_pages) |page| {
            if (start < page.start or start >= page.start + page.data.len) continue;
            const local_start = start - page.start;
            if (len > page.data.len - local_start) return null;
            return page.data[local_start .. local_start + len];
        }
        return null;
    }
};

/// PieceTree，基于 B-tree 的文本存储
pub const PieceTree = struct {
    /// Bound the local scan performed by lineToOffset/offsetToLine inside a
    /// single piece. Large initial files used to be represented by one piece,
    /// making every line lookup near EOF scan the whole file despite the
    /// SumTree carrying line summaries.
    const initial_piece_bytes: usize = 2 * 1024;

    tree: Tree,
    original_buffer: []const u8,
    original_page: ?*AddBufferPage,
    add_buffer: std.ArrayList(u8),
    add_pages: std.ArrayList(*AddBufferPage),
    add_pages_total_len: usize,
    allocator: Allocator,
    /// 保护主线程 mutation 与后台 `snapshot()` 互斥。
    /// 只锁"结构体字段的修改"与"snapshot 的读出"；scan/遍历 snapshot 本身完全无锁。
    /// 粒度：snapshot 内 O(log P) tree 节点 refcount + O(P_pages) add_page refcount，
    /// 几十微秒级持锁时间，不影响主线程编辑延迟。
    snapshot_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator) PieceTree {
        return .{
            .tree = Tree.init(allocator),
            .original_buffer = &[_]u8{},
            .original_page = null,
            .add_buffer = std.ArrayList(u8){},
            .add_pages = std.ArrayList(*AddBufferPage){},
            .add_pages_total_len = 0,
            .allocator = allocator,
        };
    }

    pub fn initFromBuffer(allocator: Allocator, content: []const u8) !PieceTree {
        var self = init(allocator);
        errdefer self.deinit();
        if (content.len > 0) {
            // original buffer 通过共享页持有，便于 snapshot 跨线程延长其生命周期。
            const page = try AddBufferPage.create(allocator, 0, content);
            self.original_page = page;
            self.original_buffer = page.data;
            var tree_tx = self.tree.beginTransaction();
            defer tree_tx.deinit();
            var start: usize = 0;
            while (start < self.original_buffer.len) {
                const end = @min(start + initial_piece_bytes, self.original_buffer.len);
                try self.tree.push(TreePiece.fromText(.original, start, self.original_buffer[start..end]));
                start = end;
            }
            tree_tx.commit();
        }
        return self;
    }

    pub fn deinit(self: *PieceTree) void {
        self.tree.deinit();
        if (self.original_page) |page| page.release();
        self.add_buffer.deinit(self.allocator);
        for (self.add_pages.items) |page| page.release();
        self.add_pages.deinit(self.allocator);
    }

    /// 创建只读快照（后台线程安全）
    /// SumTree COW O(1) + add page 元数据拷贝
    ///
    /// 后台线程可调用（见 word_index.zig 的 bgLoop）。
    /// 通过 `snapshot_mutex` 与主线程 mutation 互斥，避免读到 half-mutated 的
    /// add_pages 指针/tree root（会导致 bg 线程 SIGSEGV）。
    pub fn snapshot(self: *PieceTree, alloc: Allocator) !PieceTreeSnapshot {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();

        const pages = try alloc.alloc(*AddBufferPage, self.add_pages.items.len);
        for (self.add_pages.items, 0..) |page, i| {
            page.retain();
            pages[i] = page;
        }
        if (self.original_page) |page| page.retain();
        return .{
            .tree = self.tree.snapshot(),
            .original_buffer = self.original_buffer,
            .original_page = self.original_page,
            .add_pages = pages,
            .allocator = alloc,
        };
    }

    /// A mutation batch holds the snapshot lock until commit or rollback. Reads
    /// on this thread remain valid; do not call snapshot/insert/delete on the
    /// tree while the transaction is active. Use the transaction edit methods.
    /// The COW root and append-only buffer lengths make rollback allocation-free.
    pub const Transaction = struct {
        owner: *PieceTree,
        tree_transaction: Tree.Transaction,
        add_len: usize,
        page_count: usize,
        active: bool = true,

        pub fn insert(self: *Transaction, pos: usize, text: []const u8) !void {
            std.debug.assert(self.active);
            try self.owner.insertUnlocked(pos, text);
        }

        pub fn delete(self: *Transaction, start: usize, length: usize) !void {
            std.debug.assert(self.active);
            try self.owner.deleteUnlocked(start, length);
        }

        pub fn commit(self: *Transaction) void {
            std.debug.assert(self.active);
            self.tree_transaction.commit();
            self.active = false;
            self.owner.snapshot_mutex.unlock();
        }

        /// Always defer deinit; an uncommitted batch is rolled back in full.
        pub fn deinit(self: *Transaction) void {
            if (!self.active) return;
            self.tree_transaction.deinit();
            self.owner.add_buffer.shrinkRetainingCapacity(self.add_len);
            while (self.owner.add_pages.items.len > self.page_count) {
                self.owner.add_pages.pop().?.release();
            }
            self.owner.add_pages_total_len = self.add_len;
            self.active = false;
            self.owner.snapshot_mutex.unlock();
        }
    };

    pub fn beginTransaction(self: *PieceTree) Transaction {
        self.snapshot_mutex.lock();
        return .{
            .owner = self,
            .tree_transaction = self.tree.beginTransaction(),
            .add_len = self.add_buffer.items.len,
            .page_count = self.add_pages.items.len,
        };
    }

    // ===== 编辑操作 =====

    /// 在 pos 位置插入文本，O(log P)
    pub fn insert(self: *PieceTree, pos: usize, text: []const u8) !void {
        var tx = self.beginTransaction();
        defer tx.deinit();
        try tx.insert(pos, text);
        tx.commit();
    }

    fn insertUnlocked(self: *PieceTree, pos: usize, text: []const u8) !void {
        const total = self.totalLength();
        if (pos > total) return error.InvalidPosition;
        if (text.len == 0) return;

        // getChunkAt may lend a slice of add_buffer to the caller. Growing that
        // buffer invalidates the source, including inside ArrayList.appendSlice.
        const source_ptr = @intFromPtr(text.ptr);
        const add_ptr = @intFromPtr(self.add_buffer.items.ptr);
        if (self.add_buffer.items.len > 0 and source_ptr >= add_ptr and
            source_ptr - add_ptr < self.add_buffer.items.len)
        {
            const copy = try self.allocator.dupe(u8, text);
            defer self.allocator.free(copy);
            return self.insertUnlocked(pos, copy);
        }

        // 追加到 add_buffer
        const add_start = self.add_buffer.items.len;
        try self.add_buffer.appendSlice(self.allocator, text);
        self.appendAddPages(add_start, text) catch |err| {
            self.add_buffer.shrinkRetainingCapacity(add_start);
            return err;
        };

        if (self.tree.count() == 0) {
            try self.pushInsertedPieces(add_start, text);
            return;
        }

        // 用 ByteDim seek 找到目标 piece
        const seek_result = self.tree.seek(ByteDim, pos);

        if (seek_result.item == null or seek_result.preceding == pos) {
            // 在 piece 边界上，直接 insert
            try self.insertPiecesAt(seek_result.index, add_start, text);
            return;
        }

        // 在 piece 中间，需要 split
        const piece_idx = seek_result.index;
        const piece = seek_result.item.?;
        const offset_in_piece = seek_result.offset_in_item;

        // 前缀 piece
        const prefix_buf = self.getBuffer(piece.source);
        const prefix = TreePiece.fromText(piece.source, piece.start, prefix_buf[piece.start .. piece.start + offset_in_piece]);

        // 后缀 piece
        const suffix_start = piece.start + offset_in_piece;
        const suffix_len = piece.length - offset_in_piece;
        const suffix = TreePiece.fromText(piece.source, suffix_start, self.getBuffer(piece.source)[suffix_start .. suffix_start + suffix_len]);

        // 替换原 piece 为 prefix
        try self.tree.replace(piece_idx, prefix);
        try self.insertPiecesAt(piece_idx + 1, add_start, text);
        try self.tree.insert(piece_idx + 1 + insertedPieceCount(text.len), suffix);
    }

    /// 删除 [start, start+length) 范围，O(log P)
    pub fn delete(self: *PieceTree, start: usize, length: usize) !void {
        var tx = self.beginTransaction();
        defer tx.deinit();
        try tx.delete(start, length);
        tx.commit();
    }

    fn deleteUnlocked(self: *PieceTree, start: usize, length: usize) !void {
        const total = self.totalLength();
        if (start > total or length > total - start) return error.InvalidRange;
        if (length == 0) return;

        const end_pos = start + length;

        // 找到 start 所在的 piece
        const start_seek = self.tree.seek(ByteDim, start);
        if (start_seek.item == null) return;

        // 找到 end 所在的 piece
        // 注意: end_pos 可能恰好在 piece 边界上
        var end_seek: Tree.SeekResult(ByteDim) = undefined;
        if (end_pos >= total) {
            end_seek = .{
                .index = self.tree.count(),
                .item = null,
                .offset_in_item = 0,
                .preceding = total,
            };
        } else {
            end_seek = self.tree.seek(ByteDim, end_pos);
        }

        // 情况 1: 删除范围完全在一个 piece 内部
        if (start_seek.index == end_seek.index and end_seek.item != null) {
            const piece = start_seek.item.?;
            const start_in_piece = start_seek.offset_in_item;
            const end_in_piece = end_seek.offset_in_item;

            if (start_in_piece == 0 and end_in_piece == piece.length) {
                // 整个 piece 被删除
                try self.tree.remove(start_seek.index);
            } else if (start_in_piece == 0) {
                // 删除 piece 前缀
                const buf = self.getBuffer(piece.source);
                const new_start = piece.start + end_in_piece;
                const new_len = piece.length - end_in_piece;
                try self.tree.replace(start_seek.index, TreePiece.fromText(piece.source, new_start, buf[new_start .. new_start + new_len]));
            } else if (end_in_piece == piece.length) {
                // 删除 piece 后缀
                const buf = self.getBuffer(piece.source);
                try self.tree.replace(start_seek.index, TreePiece.fromText(piece.source, piece.start, buf[piece.start .. piece.start + start_in_piece]));
            } else {
                // 从 piece 中间删除，分裂为两个
                const buf = self.getBuffer(piece.source);
                const prefix = TreePiece.fromText(piece.source, piece.start, buf[piece.start .. piece.start + start_in_piece]);
                const suffix_start = piece.start + end_in_piece;
                const suffix_len = piece.length - end_in_piece;
                const suffix = TreePiece.fromText(piece.source, suffix_start, buf[suffix_start .. suffix_start + suffix_len]);
                try self.tree.replace(start_seek.index, prefix);
                try self.tree.insert(start_seek.index + 1, suffix);
            }
            return;
        }

        // 情况 2: 删除跨越多个 piece
        // 步骤: 先收集要处理的索引范围，然后从后向前修改

        // 处理 end piece（如果部分删除）
        var end_idx = end_seek.index;
        if (end_seek.item != null and end_seek.offset_in_item > 0) {
            // end piece 前半部分被删除
            const end_piece = end_seek.item.?;
            const off = end_seek.offset_in_item;
            const buf = self.getBuffer(end_piece.source);
            const new_start = end_piece.start + off;
            const new_len = end_piece.length - off;
            try self.tree.replace(end_seek.index, TreePiece.fromText(end_piece.source, new_start, buf[new_start .. new_start + new_len]));
            end_idx = end_seek.index;
        }

        // 删除中间的完整 piece（从后向前删除以保持索引稳定）
        {
            const first_full_remove = if (start_seek.offset_in_item > 0)
                start_seek.index + 1
            else
                start_seek.index;

            if (end_idx > first_full_remove) {
                var i = end_idx;
                while (i > first_full_remove) {
                    i -= 1;
                    try self.tree.remove(i);
                }
            }
        }

        // 处理 start piece（如果部分删除）
        if (start_seek.offset_in_item > 0) {
            const piece = start_seek.item.?;
            const buf = self.getBuffer(piece.source);
            try self.tree.replace(start_seek.index, TreePiece.fromText(piece.source, piece.start, buf[piece.start .. piece.start + start_seek.offset_in_item]));
        }
    }

    // ===== 查询 API =====

    /// 总字节数 O(1)
    pub fn totalLength(self: *const PieceTree) usize {
        return self.tree.summary().bytes;
    }

    /// 总行数 O(1): newlines + 1
    pub fn lineCount(self: *const PieceTree) usize {
        return self.tree.summary().lines + 1;
    }

    /// 最长行的字符数 O(1)：从 SumTree 根节点 summary 直接读取。
    /// 对齐 Zed DisplaySnapshot::longest_row()，不需要扫描全文件。
    pub fn longestRowChars(self: *const PieceTree) u32 {
        return self.tree.summary().longest_row_chars;
    }

    /// 获取 [start, start+length) 范围的文本
    /// 按字节维度定位起始 piece，随后顺序遍历；不对每个碎片重新查树。
    pub fn getText(self: *const PieceTree, start: usize, length: usize, buffer: []u8) ![]const u8 {
        const total = self.totalLength();
        if (start > total or length > total - start) return error.InvalidRange;
        if (buffer.len < length) return error.BufferTooSmall;
        if (length == 0) return buffer[0..0];

        // O(log P) 定位起始 piece
        var pieces = self.tree.iterator();
        var offset_in_piece = pieces.seekTo(ByteDim, start) orelse return error.CorruptPieceTree;
        var copied: usize = 0;
        var remaining = length;

        // 从定位到的 piece 开始逐个复制
        while (remaining > 0) {
            const piece = pieces.next() orelse return error.CorruptPieceTree;
            const source_buf = self.getBuffer(piece.source);
            if (!hasValidPieceBounds(piece, source_buf)) return error.CorruptPieceTree;
            if (offset_in_piece > piece.length) return error.CorruptPieceTree;
            const available = piece.length - offset_in_piece;
            // Public mutators never retain empty pieces; zero progress is corruption.
            if (available == 0) return error.CorruptPieceTree;
            const to_copy = @min(available, remaining);

            @memcpy(
                buffer[copied .. copied + to_copy],
                source_buf[piece.start + offset_in_piece .. piece.start + offset_in_piece + to_copy],
            );

            copied += to_copy;
            remaining -= to_copy;
            offset_in_piece = 0; // 后续 piece 从头开始
        }

        if (remaining != 0) return error.CorruptPieceTree;
        return buffer[0..copied];
    }

    /// 零拷贝：返回 offset 处所在 piece 内的直接 slice（不拷贝）。
    /// 返回从 offset 到该 piece 末尾的连续内存区域。
    /// tree-sitter read callback 用此避免每次 4KB memcpy。
    pub const ChunkResult = struct {
        ptr: [*]const u8,
        len: usize,
    };

    pub fn getChunkAt(self: *const PieceTree, offset: usize) ?ChunkResult {
        const total = self.totalLength();
        if (offset >= total) return null;

        const seek_result = self.tree.seek(ByteDim, offset);
        const piece = seek_result.item orelse return null;
        const source_buf = self.getBuffer(piece.source);
        if (!hasValidPieceBounds(piece, source_buf)) return null;
        const offset_in_piece = seek_result.offset_in_item;
        if (offset_in_piece >= piece.length) return null;
        const available = piece.length - offset_in_piece;
        const start = piece.start + offset_in_piece;
        return .{
            .ptr = source_buf[start..].ptr,
            .len = available,
        };
    }

    /// 获取指定行的内容
    pub fn getLine(self: *const PieceTree, line: usize, buffer: []u8) ![]const u8 {
        const lc = self.lineCount();
        if (line >= lc) return error.InvalidLine;

        const start = self.lineToOffset(line);
        const end = if (line + 1 < lc)
            self.lineToOffset(line + 1)
        else
            self.totalLength();

        return self.getText(start, end - start, buffer);
    }

    /// 字节偏移 -> 行号，真正 O(log P)：B-tree 下降同时追踪 line_count
    pub fn offsetToLine(self: *const PieceTree, offset: usize) usize {
        const root = self.tree.root orelse return 0;
        const total = self.totalLength();
        const clamped = @min(offset, total);
        return self.offsetToLineInNode(root, clamped);
    }

    fn offsetToLineInNode(self: *const PieceTree, node: *const Tree.Node, remaining_bytes: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (0..internal.len) |i| {
                    const child_bytes = internal.summaries[i].bytes;
                    if (child_bytes > remaining) {
                        return lines + self.offsetToLineInNode(internal.children[i], remaining);
                    }
                    lines += internal.summaries[i].lines;
                    remaining -= child_bytes;
                }
                return lines;
            },
            .leaf => |*leaf| {
                var remaining = remaining_bytes;
                var lines: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.length > remaining) {
                        // 在此 piece 内部分扫描
                        const buf = self.getBuffer(piece.source);
                        for (buf[piece.start .. piece.start + remaining]) |byte| {
                            if (byte == '\n') lines += 1;
                        }
                        return lines;
                    }
                    lines += piece.newline_count;
                    remaining -= piece.length;
                }
                return lines;
            },
        }
    }

    /// 行号 -> 行起始字节偏移，真正 O(log P)：B-tree 下降同时追踪 byte_offset 和 line_count
    pub fn lineToOffset(self: *const PieceTree, target_line: usize) usize {
        if (target_line == 0) return 0;
        const root = self.tree.root orelse return 0;
        return self.lineToOffsetInNode(root, target_line);
    }

    fn lineToOffsetInNode(self: *const PieceTree, node: *const Tree.Node, remaining_lines: usize) usize {
        switch (node.data) {
            .internal => |*internal| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (0..internal.len) |i| {
                    const child_lines = internal.summaries[i].lines;
                    if (child_lines >= remaining) {
                        return byte_offset + self.lineToOffsetInNode(internal.children[i], remaining);
                    }
                    remaining -= child_lines;
                    byte_offset += internal.summaries[i].bytes;
                }
                return byte_offset;
            },
            .leaf => |*leaf| {
                var remaining = remaining_lines;
                var byte_offset: usize = 0;
                for (leaf.items[0..leaf.len]) |piece| {
                    if (piece.newline_count >= remaining) {
                        // 在此 piece 内找第 remaining 个 \n
                        const buf = self.getBuffer(piece.source);
                        var count: usize = 0;
                        for (buf[piece.start .. piece.start + piece.length], 0..) |byte, j| {
                            if (byte == '\n') {
                                count += 1;
                                if (count == remaining) return byte_offset + j + 1;
                            }
                        }
                        return byte_offset + piece.length;
                    }
                    remaining -= piece.newline_count;
                    byte_offset += piece.length;
                }
                return byte_offset;
            },
        }
    }

    // ===== Anchor API（稳定位置标记） =====

    /// 创建一个 anchor 指向文档 offset 处。
    /// 编辑后 anchor 会自动跟随内容移动（参考 Zed `text::Anchor`）。
    ///
    /// 实现：基于 PieceTree 的 `(source, buffer_offset)` 对。
    /// original_buffer 和 add_buffer 都是 append-only，所以 buffer_offset 是该字节的永久坐标。
    ///
    /// 特殊情况：
    ///   - offset == 0 -> 返回 `Anchor.START`（跨任何编辑都指向文档起点）
    ///   - offset == totalLength() -> 返回 `Anchor.END`（跨任何编辑都指向文档末尾）
    ///
    /// 如果你需要"锚定当前字符"（而不是永远指向端点），用 `anchorAtStrict`。
    ///
    /// 复杂度：O(log P)
    pub fn anchorAt(self: *const PieceTree, offset: usize, bias: AnchorBias) Anchor {
        const total = self.totalLength();
        if (offset == 0) return Anchor.START;
        if (offset >= total) return Anchor.END;
        return self.anchorAtStrict(offset, bias);
    }

    /// 类似 `anchorAt`，但不走 START/END 特殊常量，即使在 offset 0 或 totalLength 上
    /// 也返回 normal anchor（基于当前 piece 的 buffer_offset）。
    ///
    /// 用途：Find/Selection 等场景需要 anchor 在编辑后跟随对应字符位置移动，
    /// 不是"永远锁在文档起/终点"。
    pub fn anchorAtStrict(self: *const PieceTree, offset: usize, bias: AnchorBias) Anchor {
        const total = self.totalLength();
        const clamped = @min(offset, total);

        const seek = self.tree.seek(ByteDim, clamped);
        if (seek.item) |piece| {
            return .{
                .source = pieceSourceToAnchorSource(piece.source),
                .buffer_offset = piece.start + seek.offset_in_item,
                .bias = bias,
                .kind = .normal,
            };
        }

        // 文档末尾（offset == total，且 total > 0）-> 退到最后一个 piece 的末尾
        if (clamped > 0 and self.tree.count() > 0) {
            const last = self.tree.get(self.tree.count() - 1) orelse return Anchor.END;
            return .{
                .source = pieceSourceToAnchorSource(last.source),
                .buffer_offset = last.start + last.length,
                .bias = bias,
                .kind = .normal,
            };
        }

        // 空文档 -> fallback to START
        return Anchor.START;
    }

    /// 解析 anchor -> 当前文档 offset。
    ///
    /// 算法（对齐 Zed bias 语义）：
    ///
    /// 1. 扫所有 piece 找包含 `(source, buffer_offset)` 的 piece
    /// 2. 命中时（即 target_offset 落在 piece 的 [start, start+length] 内）：
    ///    - 若在 piece 内部（start < target < end）：直接返回 `doc_offset + (target - piece.start)`
    ///    - 若在 piece 边界上（target == piece.start 或 target == piece.end）：
    ///      bias 决定返回当前 piece 的边界还是下/上一 piece 的边界
    ///      .left 倾向 preceding piece 的末尾；.right 倾向 following piece 的起点
    /// 3. 未命中（anchor 的 buffer 区间被删除）：
    ///    - .left -> 回退到 preceding 边界（删除区间的左端 doc offset）
    ///    - .right -> 回退到 succeeding 边界（删除区间的右端 doc offset）
    ///
    /// 复杂度：O(P)（v1 线性扫；v2 可加 source+offset -> piece_index 缓存）
    pub fn resolveAnchor(self: *const PieceTree, anchor: Anchor) usize {
        switch (anchor.kind) {
            .start_of_document => return 0,
            .end_of_document => return self.totalLength(),
            .normal => {},
        }

        const target_source = anchorSourceToPieceSource(anchor.source);
        const target_offset = anchor.buffer_offset;

        var doc_offset: usize = 0;
        var best_before: usize = 0;
        var best_after: ?usize = null;
        // 记录所有命中的 piece，bias 决定选哪个。
        // 典型场景：insert 发生后，original buffer 被 split，前后两个 piece 都"触碰"
        // 原 target_offset（前 piece 的 end == target；后 piece 的 start == target）。
        var inner_hit: ?usize = null; // piece 内部命中（非边界）
        var trailing_edge_hit: ?usize = null; // target == piece_end（.left 倾向）
        var leading_edge_hit: ?usize = null; // target == piece_start（.right 倾向）

        const count = self.tree.count();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const piece = self.tree.get(i) orelse break;
            const piece_end = piece.start + piece.length;

            if (piece.source == target_source) {
                // Case 1: 严格内部命中
                if (target_offset > piece.start and target_offset < piece_end) {
                    inner_hit = doc_offset + (target_offset - piece.start);
                }
                // Case 2: target 正好在 piece 末尾（trailing edge）
                else if (target_offset == piece_end and target_offset > piece.start) {
                    trailing_edge_hit = doc_offset + piece.length;
                }
                // Case 3: target 正好在 piece 起点（leading edge）
                else if (target_offset == piece.start and target_offset < piece_end) {
                    if (leading_edge_hit == null) leading_edge_hit = doc_offset;
                }
                // Case 4: 空 piece 且 target 正好在边界上（极罕见，忽略）

                // 未命中时记录回退候选
                if (target_offset > piece_end) {
                    best_before = doc_offset + piece.length;
                } else if (target_offset < piece.start and best_after == null) {
                    best_after = doc_offset;
                }
            }

            doc_offset += piece.length;
        }

        // 优先级：inner hit 最确定
        if (inner_hit) |h| return h;

        // 边界命中：bias 决定方向
        switch (anchor.bias) {
            .left => {
                if (trailing_edge_hit) |h| return h;
                if (leading_edge_hit) |h| return h;
            },
            .right => {
                if (leading_edge_hit) |h| return h;
                if (trailing_edge_hit) |h| return h;
            },
        }

        // 完全未命中：回退
        return switch (anchor.bias) {
            .left => best_before,
            .right => best_after orelse doc_offset,
        };
    }

    // Anchor 相关类型（从 core/anchor.zig 重新导出，方便调用方）
    pub const Anchor = @import("anchor.zig").Anchor;
    pub const AnchorBias = @import("anchor.zig").Bias;
    pub const AnchorRange = @import("anchor.zig").AnchorRange;

    inline fn pieceSourceToAnchorSource(s: Source) @import("anchor.zig").Source {
        return switch (s) {
            .original => .original,
            .add => .add,
        };
    }

    inline fn anchorSourceToPieceSource(s: @import("anchor.zig").Source) Source {
        return switch (s) {
            .original => .original,
            .add => .add,
        };
    }

    // ===== 内部辅助 =====

    /// 零拷贝 chunk 迭代器：逐 piece 返回直接引用，无 memcpy
    pub fn chunksInRange(self: *const PieceTree, start: usize, len: usize) ChunkIterator(PieceTree) {
        const total = self.totalLength();
        const clamped_start = @min(start, total);
        const clamped_len = @min(len, total - clamped_start);
        if (clamped_len == 0) return .{ .container = self, .index = 0, .offset_in_piece = 0, .remaining = 0 };
        const seek_result = self.tree.seek(ByteDim, clamped_start);
        return .{
            .container = self,
            .index = seek_result.index,
            .offset_in_piece = seek_result.offset_in_item,
            .remaining = clamped_len,
        };
    }

    fn getBuffer(self: *const PieceTree, source: Source) []const u8 {
        return switch (source) {
            .original => self.original_buffer,
            .add => self.add_buffer.items,
        };
    }

    fn getPieceBuffer(self: *const PieceTree, piece: TreePiece) ?[]const u8 {
        const source_buf = self.getBuffer(piece.source);
        if (!hasValidPieceBounds(piece, source_buf)) return null;
        return source_buf[piece.start .. piece.start + piece.length];
    }

    fn appendAddPages(self: *PieceTree, add_start: usize, text: []const u8) !void {
        if (self.add_pages_total_len != add_start) return error.InvalidAddBufferState;
        const old_page_count = self.add_pages.items.len;
        const old_total_len = self.add_pages_total_len;
        errdefer {
            while (self.add_pages.items.len > old_page_count) {
                const page = self.add_pages.pop().?;
                page.release();
            }
            self.add_pages_total_len = old_total_len;
        }
        var offset: usize = 0;
        while (offset < text.len) {
            const chunk_len = @min(ADD_BUFFER_PAGE_SIZE, text.len - offset);
            const page = try AddBufferPage.create(self.allocator, self.add_pages_total_len, text[offset .. offset + chunk_len]);
            self.add_pages.append(self.allocator, page) catch |err| {
                page.release();
                return err;
            };
            self.add_pages_total_len += chunk_len;
            offset += chunk_len;
        }
    }

    fn pushInsertedPieces(self: *PieceTree, add_start: usize, text: []const u8) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            const chunk_len = @min(ADD_BUFFER_PAGE_SIZE, text.len - offset);
            try self.tree.push(TreePiece.fromText(.add, add_start + offset, text[offset .. offset + chunk_len]));
            offset += chunk_len;
        }
    }

    fn insertPiecesAt(self: *PieceTree, index: usize, add_start: usize, text: []const u8) !void {
        var offset: usize = 0;
        var insert_idx = index;
        while (offset < text.len) {
            const chunk_len = @min(ADD_BUFFER_PAGE_SIZE, text.len - offset);
            try self.tree.insert(insert_idx, TreePiece.fromText(.add, add_start + offset, text[offset .. offset + chunk_len]));
            insert_idx += 1;
            offset += chunk_len;
        }
    }

    fn insertedPieceCount(text_len: usize) usize {
        if (text_len == 0) return 0;
        return (text_len + ADD_BUFFER_PAGE_SIZE - 1) / ADD_BUFFER_PAGE_SIZE;
    }

    /// 扫描文本统计信息（对齐 Zed TextSummary::from(str)）。
    /// 一次遍历计算 newline_count + first/last/longest_row_chars。
    ///
    /// 实现已析出到 piece_stats.zig（见该文件的模块头：为什么搬、接口切在哪、
    /// 非法 UTF-8 / 末尾截断序列 / 行宽饱和这几个坑）。这里只留委托，保持
    /// `PieceTree.scanTextStats` 这个旧调用点（TreePiece.fromText 及测试）不变。
    const TextStats = piece_stats.TextStats;

    fn scanTextStats(text: []const u8) TextStats {
        return piece_stats.scan(text);
    }
};

// ===== 单元测试 =====

test "PieceTree: init and deinit" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
}

test "PieceTree: init from buffer" {
    const content = "Hello\nWorld\n";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 12), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
}

test "PieceTree: insert at beginning" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello");
    try std.testing.expectEqual(@as(usize, 5), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTree: insert at end" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello");
    try pt.insert(5, " World");
    try std.testing.expectEqual(@as(usize, 11), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 11, &buffer);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "PieceTree: snapshot shares add pages without copying contiguous add buffer" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    const large = try std.testing.allocator.alloc(u8, ADD_BUFFER_PAGE_SIZE + 32);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');

    try pt.insert(0, large);
    const first_page = pt.add_pages.items[0];
    const second_page = pt.add_pages.items[1];

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 2), snap.add_pages.len);
    try std.testing.expectEqual(@intFromPtr(first_page), @intFromPtr(snap.add_pages[0]));
    try std.testing.expectEqual(@intFromPtr(second_page), @intFromPtr(snap.add_pages[1]));
}

test "PieceTree: insert in middle" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.insert(5, ",");
    try std.testing.expectEqual(@as(usize, 12), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 12, &buffer);
    try std.testing.expectEqualStrings("Hello, World", text);
}

test "PieceTree: get line" {
    const content = "Line 1\nLine 2\nLine 3\n";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    var buffer: [100]u8 = undefined;

    const line1 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", line1);

    const line2 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", line2);
}

test "PieceTree: delete from middle" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.delete(5, 1); // 删除空格
    try std.testing.expectEqual(@as(usize, 10), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 10, &buffer);
    try std.testing.expectEqualStrings("HelloWorld", text);
}

test "PieceTree: delete from beginning" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.delete(0, 6);
    try std.testing.expectEqual(@as(usize, 5), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("World", text);
}

test "PieceTree: delete from end" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try pt.delete(5, 6);
    try std.testing.expectEqual(@as(usize, 5), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 5, &buffer);
    try std.testing.expectEqualStrings("Hello", text);
}

test "PieceTree: delete across pieces" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello");
    try pt.insert(5, " World");
    try pt.insert(11, "!");

    try pt.delete(3, 5); // 删除 "lo Wo"
    try std.testing.expectEqual(@as(usize, 7), pt.totalLength());

    var buffer: [100]u8 = undefined;
    const text = try pt.getText(0, 7, &buffer);
    try std.testing.expectEqualStrings("Helrld!", text);
}

test "PieceTree: line index after insert newline" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Hello World");
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());

    try pt.insert(5, "\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Hello\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings(" World", line1);
}

test "PieceTree: line index after insert multiple newlines" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "ABCD");
    try pt.insert(2, "\n\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AB\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", line1);
    const line2 = try pt.getLine(2, &buffer);
    try std.testing.expectEqualStrings("CD", line2);
}

test "PieceTree: line index after delete newline" {
    const content = "Line 1\nLine 2\nLine 3";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    try pt.delete(6, 1);
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1Line 2\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", line1);
}

test "PieceTree: line index after delete across lines" {
    const content = "AAA\nBBB\nCCC\nDDD";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, content);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    try pt.delete(4, 8); // "BBB\nCCC\n"
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const line0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("AAA\n", line0);
    const line1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("DDD", line1);
}

test "PieceTree: line consistency through multiple edits" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "Line 1\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    try pt.insert(7, "Line 2\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    try pt.insert(14, "Line 3");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    var buffer: [100]u8 = undefined;
    const l0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Line 1\n", l0);
    const l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 2\n", l1);
    const l2 = try pt.getLine(2, &buffer);
    try std.testing.expectEqualStrings("Line 3", l2);

    const full_before = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", full_before);

    try pt.delete(7, 7);
    try std.testing.expectEqual(@as(usize, 13), pt.totalLength());

    const full_after = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("Line 1\nLine 3", full_after);

    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());
    const new_l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("Line 3", new_l1);
}

test "PieceTree: consecutive newline inserts" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "Press hello\n");
    defer pt.deinit();

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());

    try pt.insert(11, "\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
    const l0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("Press hello\n", l0);
    const l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("\n", l1);

    try pt.insert(12, "\n");
    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    try pt.insert(13, "\n");
    try std.testing.expectEqual(@as(usize, 5), pt.lineCount());

    const full = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("Press hello\n\n\n\n", full);
}

test "PieceTree: insert newline at line start" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "ABC");
    defer pt.deinit();

    var buffer: [256]u8 = undefined;

    try pt.insert(0, "\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());
    const l0 = try pt.getLine(0, &buffer);
    try std.testing.expectEqualStrings("\n", l0);
    const l1 = try pt.getLine(1, &buffer);
    try std.testing.expectEqualStrings("ABC", l1);

    try pt.insert(1, "\n");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    const full = try pt.getText(0, pt.totalLength(), &buffer);
    try std.testing.expectEqualStrings("\n\nABC", full);
}

test "PieceTree: offsetToLine and lineToOffset" {
    const content = "Hello\nWorld\nFoo\n";
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, content);
    defer pt.deinit();

    // line 0 = "Hello\n" (0..6)
    // line 1 = "World\n" (6..12)
    // line 2 = "Foo\n"   (12..16)
    // line 3 = ""         (16..16)
    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(5));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(6));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(11));
    try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(12));
    try std.testing.expectEqual(@as(usize, 3), pt.offsetToLine(16));

    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
    try std.testing.expectEqual(@as(usize, 6), pt.lineToOffset(1));
    try std.testing.expectEqual(@as(usize, 12), pt.lineToOffset(2));
    try std.testing.expectEqual(@as(usize, 16), pt.lineToOffset(3));
}

test "PieceTree: equivalence with PieceTable for mixed operations" {
    // 等价性测试: 对相同操作序列验证 PieceTree 和 PieceTable 结果一致
    const piece_table_mod = @import("piece_table.zig");
    const PieceTable = piece_table_mod.PieceTable;

    var pt_tree = PieceTree.init(std.testing.allocator);
    defer pt_tree.deinit();

    var pt_table = try PieceTable.init(std.testing.allocator);
    defer pt_table.deinit();

    const ops = [_]struct { kind: enum { ins, del }, pos: usize, text: []const u8, del_len: usize }{
        .{ .kind = .ins, .pos = 0, .text = "Hello World\n", .del_len = 0 },
        .{ .kind = .ins, .pos = 5, .text = ",\n", .del_len = 0 },
        .{ .kind = .ins, .pos = 14, .text = "Foo\nBar\n", .del_len = 0 },
        .{ .kind = .del, .pos = 3, .text = "", .del_len = 5 },
        .{ .kind = .ins, .pos = 3, .text = "XYZ", .del_len = 0 },
        .{ .kind = .del, .pos = 0, .text = "", .del_len = 3 },
    };

    for (ops) |op| {
        switch (op.kind) {
            .ins => {
                try pt_tree.insert(op.pos, op.text);
                try pt_table.insert(op.pos, op.text);
            },
            .del => {
                try pt_tree.delete(op.pos, op.del_len);
                try pt_table.delete(op.pos, op.del_len);
            },
        }

        // 验证总长度一致
        try std.testing.expectEqual(pt_table.total_length, pt_tree.totalLength());

        // 验证行数一致
        try std.testing.expectEqual(pt_table.lineCount(), pt_tree.lineCount());

        // 验证全文一致
        var buf1: [1024]u8 = undefined;
        var buf2: [1024]u8 = undefined;
        const text1 = try pt_tree.getText(0, pt_tree.totalLength(), &buf1);
        const text2 = try pt_table.getText(0, pt_table.total_length, &buf2);
        try std.testing.expectEqualStrings(text2, text1);
    }
}

test "PieceTree: lineToOffset/offsetToLine brute force verification" {
    const alloc = std.testing.allocator;

    // 各种文档内容
    const cases = [_][]const u8{
        "Hello\nWorld\nFoo\n",
        "abc",
        "\n\n\n",
        "a\nb\nc",
        "Line 1\nLine 2\nLine 3\n",
        "",
        "\n",
        "no newline at end",
        "aaa\nbbb\nccc\nddd\neee\nfff\n",
    };

    for (cases) |content| {
        var pt = if (content.len > 0)
            try PieceTree.initFromBuffer(alloc, content)
        else
            PieceTree.init(alloc);
        defer pt.deinit();

        const lc = pt.lineCount();

        // 暴力计算行偏移表
        var line_starts_buf: [128]usize = undefined;
        var brute_lc: usize = 1;
        line_starts_buf[0] = 0;
        for (content, 0..) |byte, i| {
            if (byte == '\n') {
                line_starts_buf[brute_lc] = i + 1;
                brute_lc += 1;
            }
        }

        // 验证 lineCount
        try std.testing.expectEqual(brute_lc, lc);

        // 验证 lineToOffset
        for (0..lc) |line| {
            const expected = line_starts_buf[line];
            const got = pt.lineToOffset(line);
            try std.testing.expectEqual(expected, got);
        }

        // 验证 offsetToLine
        for (0..content.len + 1) |offset| {
            var expected_line: usize = 0;
            for (content[0..@min(offset, content.len)]) |b| {
                if (b == '\n') expected_line += 1;
            }
            const got = pt.offsetToLine(@min(offset, pt.totalLength()));
            try std.testing.expectEqual(expected_line, got);
        }
    }

    // 编辑后验证：模拟多次插入产生多个 piece
    {
        var pt = PieceTree.init(alloc);
        defer pt.deinit();

        try pt.insert(0, "AAA\n");
        try pt.insert(4, "BBB\n");
        try pt.insert(8, "CCC");

        // 全文 = "AAA\nBBB\nCCC" (3 pieces)
        try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
        try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
        try std.testing.expectEqual(@as(usize, 4), pt.lineToOffset(1));
        try std.testing.expectEqual(@as(usize, 8), pt.lineToOffset(2));

        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(3));
        try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(4));
        try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(7));
        try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(8));
        try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(11));
    }
}

test "PieceTree: getText rejects corrupt piece bounds" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    try pt.insert(0, "abc");
    try pt.tree.replace(0, .{
        .source = .add,
        .start = 99,
        .length = 1,
        .newline_count = 0,
    });

    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.CorruptPieceTree, pt.getText(0, 1, &buffer));

    var snapshot = try pt.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectError(error.CorruptPieceTree, snapshot.getText(0, 1, &buffer));
}

test "PieceTreeSnapshot remains readable during concurrent source edits" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();

    const seed = "0123456789abcdef\n";
    for (0..48) |_| {
        try pt.insert(pt.totalLength(), seed);
    }

    var snapshot = try pt.snapshot(std.testing.allocator);
    defer snapshot.deinit();

    const total = snapshot.totalLength();
    const expected = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(expected);
    _ = try snapshot.getText(0, total, expected);

    const AtomicBool = std.atomic.Value(bool);
    const ReaderContext = struct {
        snapshot: *const PieceTreeSnapshot,
        expected: []const u8,
        done: *AtomicBool,
        failed: *AtomicBool,

        fn run(ctx: *@This()) void {
            var buf: [97]u8 = undefined;
            var offset: usize = 0;

            while (!ctx.done.load(.acquire)) {
                const remaining = ctx.expected.len - offset;
                const read_len = @min(buf.len, remaining);
                const text = ctx.snapshot.getText(offset, read_len, &buf) catch {
                    ctx.failed.store(true, .release);
                    return;
                };
                if (!std.mem.eql(u8, ctx.expected[offset .. offset + read_len], text)) {
                    ctx.failed.store(true, .release);
                    return;
                }

                offset += 31;
                if (offset >= ctx.expected.len) offset = 0;
            }
        }
    };

    var done = AtomicBool.init(false);
    var failed = AtomicBool.init(false);
    var reader_ctx = ReaderContext{
        .snapshot = &snapshot,
        .expected = expected,
        .done = &done,
        .failed = &failed,
    };
    const thread = try std.Thread.spawn(.{}, ReaderContext.run, .{&reader_ctx});
    defer thread.join();

    for (0..2_000) |i| {
        const mid = pt.totalLength() / 2;
        try pt.insert(mid, "X");
        try pt.delete(mid, 1);

        if ((i & 31) == 0) {
            std.Thread.yield() catch {};
        }
    }

    done.store(true, .release);
    try std.testing.expect(!failed.load(.acquire));
}

test "ChunkIterator: basic single piece" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "hello world");
    defer pt.deinit();

    // 全范围迭代
    var it = pt.chunksInRange(0, pt.totalLength());
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, "hello world", result[0..pos]);
}

test "ChunkIterator: multiple pieces after edit" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abcdef");
    defer pt.deinit();
    try pt.insert(3, "XYZ"); // "abcXYZdef"

    var it = pt.chunksInRange(0, pt.totalLength());
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    var chunk_count: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
        chunk_count += 1;
    }
    try std.testing.expectEqualSlices(u8, "abcXYZdef", result[0..pos]);
    try std.testing.expect(chunk_count >= 2); // 至少 2 个 piece
}

test "ChunkIterator: sub-range" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "0123456789");
    defer pt.deinit();
    try pt.insert(5, "AB"); // "01234AB56789"

    // 只迭代 offset 3..9 -> "34AB56"
    var it = pt.chunksInRange(3, 6);
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, "34AB56", result[0..pos]);
}

test "ChunkIterator: empty range" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abc");
    defer pt.deinit();

    var it = pt.chunksInRange(1, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "ChunkIterator: snapshot" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "hello");
    defer pt.deinit();
    try pt.insert(5, " world");

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();

    var it = snap.chunksInRange(0, snap.totalLength());
    var result: [64]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, "hello world", result[0..pos]);
}

test "PieceTreeSnapshot: getChunkAt returns direct slice inside piece" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "hello");
    defer pt.deinit();
    try pt.insert(5, " world");

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();

    const chunk0 = snap.getChunkAt(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", chunk0.ptr[0..chunk0.len]);

    const chunk6 = snap.getChunkAt(6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("world", chunk6.ptr[0..chunk6.len]);

    try std.testing.expectEqual(@as(?PieceTreeSnapshot.ChunkResult, null), snap.getChunkAt(snap.totalLength()));
}

test "PieceTreeSnapshot retains original buffer after source deinit" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "hello world");
    var snap = try pt.snapshot(std.testing.allocator);
    pt.deinit();
    defer snap.deinit();

    var buf: [11]u8 = undefined;
    const text = try snap.getText(0, 11, &buf);
    try std.testing.expectEqualStrings("hello world", text);

    const chunk = snap.getChunkAt(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello world", chunk.ptr[0..chunk.len]);
}

test "ChunkIterator: matches getText" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "The quick brown fox jumps over the lazy dog");
    defer pt.deinit();
    // 制造多个 piece
    try pt.insert(10, "!!!"); // after "quick"
    try pt.insert(0, ">>> ");
    try pt.delete(20, 5);

    const total = pt.totalLength();
    var text_buf: [256]u8 = undefined;
    const expected = try pt.getText(0, total, &text_buf);

    var it = pt.chunksInRange(0, total);
    var result: [256]u8 = undefined;
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(result[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    try std.testing.expectEqualSlices(u8, expected, result[0..pos]);
}

test "PieceTree: longestRowChars basic" {
    // 简单多行文本
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "short\na longer line here\nhi\n");
    defer pt.deinit();
    // "a longer line here" = 18 chars
    try std.testing.expectEqual(@as(u32, 18), pt.longestRowChars());
}

test "PieceTree: longestRowChars single line" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "hello world");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 11), pt.longestRowChars());
}

test "PieceTree: longestRowChars empty" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 0), pt.longestRowChars());
}

test "PieceTree: longestRowChars after insert extends line" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abc\ndef\n");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 3), pt.longestRowChars());
    // Insert " extended" after "abc" -> "abc extended\ndef\n"
    try pt.insert(3, " extended");
    try std.testing.expectEqual(@as(u32, 12), pt.longestRowChars());
}

test "PieceTree: longestRowChars after delete shrinks" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "short\nvery long line content here\nhi\n");
    defer pt.deinit();
    // "very long line content here" = 27 chars
    try std.testing.expectEqual(@as(u32, 27), pt.longestRowChars());
    // Delete "very long line content here\n" (offset 6, length 28)
    try pt.delete(6, 28);
    // Remaining: "short\nhi\n" -> longest = 5
    try std.testing.expectEqual(@as(u32, 5), pt.longestRowChars());
}

test "PieceTree: longestRowChars cross-piece join" {
    // Two pieces that join: "abc" + "defghij\nxy" -> first line "abcdefghij" = 10 chars
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abc");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 3), pt.longestRowChars());
    try pt.insert(3, "defghij\nxy");
    // "abcdefghij\nxy" -> longest = 10
    try std.testing.expectEqual(@as(u32, 10), pt.longestRowChars());
}

test "PieceTree: scanTextStats correctness" {
    const stats = PieceTree.scanTextStats("hello\nworld foo bar\nhi\n");
    try std.testing.expectEqual(@as(usize, 3), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 5), stats.first_line_chars); // "hello"
    try std.testing.expectEqual(@as(u32, 0), stats.last_line_chars); // "" after final \n
    try std.testing.expectEqual(@as(u32, 13), stats.longest_row_chars); // "world foo bar"
}

test "PieceTree: scanTextStats no newline" {
    const stats = PieceTree.scanTextStats("abcdef");
    try std.testing.expectEqual(@as(usize, 0), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 6), stats.first_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.last_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.longest_row_chars);
}

// 析出后的回归护栏：委托必须逐字段等价（含非法 UTF-8 与截断序列）。
test "PieceTree: scanTextStats delegates to piece_stats.scan unchanged" {
    const cases = [_][]const u8{
        "",
        "\n",
        "abc",
        "hello\nworld foo bar\nhi\n",
        "héllo\nwörld\n",
        "abc\u{4F60}"[0..5], // 截断的 3 字节序列
        "\xff\xfe\xc0\x80\x8f",
        "ab\r\ncd\r\n",
    };
    for (cases) |text| {
        const via_pt = PieceTree.scanTextStats(text);
        const via_mod = piece_stats.scan(text);
        try std.testing.expectEqualDeep(via_mod, via_pt);
        // 逐字段显式比对（expectEqualDeep 对 struct 的失败信息不直观）
        try std.testing.expectEqual(via_mod.newline_count, via_pt.newline_count);
        try std.testing.expectEqual(via_mod.first_line_chars, via_pt.first_line_chars);
        try std.testing.expectEqual(via_mod.last_line_chars, via_pt.last_line_chars);
        try std.testing.expectEqual(via_mod.longest_row_chars, via_pt.longest_row_chars);
    }
}

test "PieceTree: longestRowChars multi-piece insert builds correct cross-piece join" {
    // 模拟大文件场景：多次 insert 在同一行追加，跨 piece 拼接
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "line1\nline2\nline3\n");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 5), pt.longestRowChars());

    // 在 line2 末尾追加（offset=11, 在 "line2" 之后 "\n" 之前）
    try pt.insert(11, " appended text here!!!!");
    // "line2 appended text here!!!!" = 5 + 23 = 28 chars
    try std.testing.expectEqual(@as(u32, 28), pt.longestRowChars());

    // 再追加更多
    try pt.insert(11 + 23, " and even more stuff");
    // "line2 appended text here!!!! and even more stuff" = 48 chars
    try std.testing.expectEqual(@as(u32, 48), pt.longestRowChars());
}

test "PieceTree: longestRowChars matches brute-force scan on constructed content" {
    // 构造一个有已知最长行的多行内容
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    // 生成 1000 行，其中第 500 行最长（200 字符）
    var expected_longest: u32 = 0;
    for (0..1000) |i| {
        const line_len: usize = if (i == 500) 200 else @min(i % 80 + 10, 79);
        for (0..line_len) |_| {
            try buf.append(allocator, 'x');
        }
        try buf.append(allocator, '\n');
        if (line_len > expected_longest) expected_longest = @intCast(line_len);
    }

    var pt = try PieceTree.initFromBuffer(allocator, buf.items);
    defer pt.deinit();
    try std.testing.expectEqual(expected_longest, pt.longestRowChars());

    // 现在在第 700 行插入一个更长的行
    // 找到第 700 行的偏移
    var offset: usize = 0;
    var line: usize = 0;
    for (buf.items, 0..) |byte, idx| {
        if (byte == '\n') {
            line += 1;
            if (line == 700) {
                offset = idx + 1;
                break;
            }
        }
    }
    // 在这个位置插入 300 个 'Y' + '\n'
    var insert_buf: [301]u8 = undefined;
    @memset(insert_buf[0..300], 'Y');
    insert_buf[300] = '\n';
    try pt.insert(offset, &insert_buf);
    try std.testing.expectEqual(@as(u32, 300), pt.longestRowChars());
}

test "PieceSummary: add merges longest_row_chars across join" {
    // Piece A: "abc" (no newline) -> first=3, last=3, longest=3
    const a = PieceSummary{ .bytes = 3, .lines = 0, .first_line_chars = 3, .last_line_chars = 3, .longest_row_chars = 3 };
    // Piece B: "defgh\nij" -> first=5, last=2, longest=5
    const b = PieceSummary{ .bytes = 8, .lines = 1, .first_line_chars = 5, .last_line_chars = 2, .longest_row_chars = 5 };
    const merged = a.add(b);
    // joined = 3 + 5 = 8 > both -> longest = 8
    try std.testing.expectEqual(@as(u32, 8), merged.longest_row_chars);
    // first_line_chars: a has no newlines -> extends: 3 + 5 = 8
    try std.testing.expectEqual(@as(u32, 8), merged.first_line_chars);
    // last_line_chars: b has newlines -> b.last = 2
    try std.testing.expectEqual(@as(u32, 2), merged.last_line_chars);
}

test "PieceSummary: line widths saturate instead of overflowing" {
    const a = PieceSummary{
        .first_line_chars = std.math.maxInt(u32),
        .last_line_chars = std.math.maxInt(u32),
        .longest_row_chars = std.math.maxInt(u32),
    };
    const b = PieceSummary{ .first_line_chars = 10, .last_line_chars = 10, .longest_row_chars = 10 };
    const merged = a.add(b);
    try std.testing.expectEqual(std.math.maxInt(u32), merged.first_line_chars);
    try std.testing.expectEqual(std.math.maxInt(u32), merged.last_line_chars);
    try std.testing.expectEqual(std.math.maxInt(u32), merged.longest_row_chars);
}

// ============================================================================
// Anchor tests
// ============================================================================

test "Anchor: START and END resolve to 0 and totalLength" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "Hello, World");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(PieceTree.Anchor.START));
    try std.testing.expectEqual(@as(usize, 12), pt.resolveAnchor(PieceTree.Anchor.END));
}

test "Anchor: anchorAt(0) returns START" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abc");
    defer pt.deinit();

    const a = pt.anchorAt(0, .right);
    const AnchorKind = @import("anchor.zig").Kind;
    try std.testing.expectEqual(AnchorKind.start_of_document, a.kind);
}

test "Anchor: anchorAt(total) returns END" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abc");
    defer pt.deinit();

    const a = pt.anchorAt(3, .left);
    const AnchorKind = @import("anchor.zig").Kind;
    try std.testing.expectEqual(AnchorKind.end_of_document, a.kind);
}

test "Anchor: normal anchor resolves to correct offset" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "Hello, World");
    defer pt.deinit();

    const a = pt.anchorAt(5, .left); // after "Hello"
    const AnchorKind = @import("anchor.zig").Kind;
    try std.testing.expectEqual(AnchorKind.normal, a.kind);
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(a));
}

test "Anchor: stability across insertions BEFORE anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "Hello, World");
    defer pt.deinit();

    // Anchor 指向 "World" 的 W
    const anchor_world = pt.anchorAt(7, .right);
    try std.testing.expectEqual(@as(usize, 7), pt.resolveAnchor(anchor_world));

    // 在开头插入 "<<" (2 字节)
    try pt.insert(0, "<<");
    // anchor 应自动跟随到新的 "World" 起点（offset 9）
    try std.testing.expectEqual(@as(usize, 9), pt.resolveAnchor(anchor_world));
}

test "Anchor: stability across insertions AFTER anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "Hello, World");
    defer pt.deinit();

    const anchor_mid = pt.anchorAt(5, .left); // 指向 "Hello" 末尾
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(anchor_mid));

    // 在末尾追加
    try pt.insert(12, "!!!");
    // anchor 位置不变
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(anchor_mid));
}

test "Anchor: stability across deletions BEFORE anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "Hello, World");
    defer pt.deinit();

    const anchor_world = pt.anchorAt(7, .right);
    try std.testing.expectEqual(@as(usize, 7), pt.resolveAnchor(anchor_world));

    // 删除 "Hello, " (7 字节)
    try pt.delete(0, 7);
    // anchor 跟随到新的 "World" 起点（offset 0）
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(anchor_world));
}

test "Anchor: stability across deletions AFTER anchor" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "Hello, World");
    defer pt.deinit();

    const anchor_mid = pt.anchorAt(5, .left);

    // 删除 "World" (5 字节，位置 7..12)
    try pt.delete(7, 5);
    // anchor 位置不变
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(anchor_mid));
}

test "Anchor: bias left vs right on insert AT anchor position" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abcdef");
    defer pt.deinit();

    // Anchor 位于 offset 3（"abc|def"）
    const a_left = pt.anchorAt(3, .left);
    const a_right = pt.anchorAt(3, .right);
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_left));
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_right));

    // 在 offset 3 插入 "XYZ" -> 文档变为 "abcXYZdef"
    try pt.insert(3, "XYZ");

    // Bias 语义（对齐 Zed）：
    //   .left  -> anchor 粘在 insert 之前的字符后 -> 位置不变（3）
    //   .right -> anchor 粘在 insert 之后的字符前 -> 随 insert 移动到右边（6）
    //
    // 实现细节：insert 把原 original piece split 成 "abc"(0..3) 和 "def"(3..6)，
    // 中间插入 add piece。target_offset=3 同时命中：
    //   - "abc" piece 的 trailing edge (piece_end=3) -> doc_offset=3
    //   - "def" piece 的 leading edge (piece_start=3) -> doc_offset=6
    // .left 选 trailing；.right 选 leading。
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_left));
    try std.testing.expectEqual(@as(usize, 6), pt.resolveAnchor(a_right));
}

test "Anchor: falls back to left boundary when inside deleted range (.left bias)" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abcdefghij");
    defer pt.deinit();

    // Anchor 指向 offset 5 (字符 'f')
    const a_left = pt.anchorAt(5, .left);
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(a_left));

    // 删除 [3, 8) -> 删掉 "defgh"
    try pt.delete(3, 5);
    // anchor 所在 buffer 字节已不在任何 piece 中
    // .left bias -> 回退到 delete range 的左边界（doc offset 3）
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_left));
}

test "Anchor: falls back to right boundary when inside deleted range (.right bias)" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abcdefghij");
    defer pt.deinit();

    const a_right = pt.anchorAt(5, .right);
    try std.testing.expectEqual(@as(usize, 5), pt.resolveAnchor(a_right));

    try pt.delete(3, 5);
    // .right bias -> 回退到 delete range 的右边界（doc offset 3，和 left 相同因为删除后右边直接接上）
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a_right));
}

test "Anchor: survives complex edit sequence" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "The quick brown fox");
    defer pt.deinit();

    // 多个 anchor 指向不同字符
    const a_quick = pt.anchorAt(4, .right); // 'q'
    const a_brown = pt.anchorAt(10, .right); // 'b'
    const a_fox = pt.anchorAt(16, .right); // 'f'

    // 多次编辑：替换 "quick" 为 "very swift"
    try pt.delete(4, 5); // "The  brown fox"
    try pt.insert(4, "very swift"); // "The very swift brown fox"

    // anchor 位置应正确反映新 doc 中对应字符
    // 原 'q' 所在的 buffer 字节已被删除 -> 回退到 delete 边界 (offset 4)
    try std.testing.expectEqual(@as(usize, 4), pt.resolveAnchor(a_quick));
    // 'b' 和 'f' 的 buffer 字节未动，跟随新 offset（长度 +5）
    try std.testing.expectEqual(@as(usize, 15), pt.resolveAnchor(a_brown));
    try std.testing.expectEqual(@as(usize, 21), pt.resolveAnchor(a_fox));
}

test "Anchor: resolveAnchorRange returns pair" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "hello world");
    defer pt.deinit();

    const r: PieceTree.AnchorRange = .{
        .start = pt.anchorAt(0, .right),
        .end = pt.anchorAt(5, .left),
    };
    // 用 piece_tree 内的 resolve，不是 document 的 resolveAnchorRange（那个在 document 层）
    const s = pt.resolveAnchor(r.start);
    const e = pt.resolveAnchor(r.end);
    try std.testing.expectEqual(@as(usize, 0), s);
    try std.testing.expectEqual(@as(usize, 5), e);
}

test "Anchor: normal anchor pointsTo predicate" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abcdef");
    defer pt.deinit();

    const a = pt.anchorAt(3, .left);
    // anchor 指向 original buffer 的 offset 3
    try std.testing.expect(a.pointsTo(.original, 3));
    try std.testing.expect(!a.pointsTo(.original, 4));
    try std.testing.expect(!a.pointsTo(.add, 3));
}

test "Anchor: insert + anchor survives in add buffer" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "AB");
    defer pt.deinit();

    // 先 insert，让后续 anchor 落到 add buffer
    try pt.insert(1, "XYZ"); // "AXYZB"

    const a_y = pt.anchorAt(2, .right); // 'Y' 在 add buffer
    try std.testing.expectEqual(@as(usize, 2), pt.resolveAnchor(a_y));

    // 再插入东西
    try pt.insert(0, "<<"); // "<<AXYZB"
    try std.testing.expectEqual(@as(usize, 4), pt.resolveAnchor(a_y));
}

fn checkTransactionalAllocationFailures(comptime deleting: bool) !void {
    const baseline = "first line\nsecond line\n" ** 5000;
    const inserted = "inserted\n" ** 16000;
    var fail_at: usize = 0;
    while (fail_at < 2000) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var pt = try PieceTree.initFromBuffer(failing.allocator(), baseline);
        defer pt.deinit();
        var snap = try pt.snapshot(std.testing.allocator);
        defer snap.deinit();
        failing.fail_index = failing.alloc_index + fail_at;
        failing.resize_fail_index = failing.resize_index;
        const result = if (deleting) pt.delete(5, baseline.len - 10) else pt.insert(5, inserted);
        if (result) |_| {
            try std.testing.expectEqual(if (deleting) @as(usize, 10) else baseline.len + inserted.len, pt.totalLength());
            return;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const buf = try std.testing.allocator.alloc(u8, baseline.len);
            defer std.testing.allocator.free(buf);
            try std.testing.expectEqual(@as(usize, baseline.len), pt.totalLength());
            try std.testing.expectEqualStrings(baseline, try pt.getText(0, baseline.len, buf));
            try std.testing.expectEqualStrings(baseline, try snap.getText(0, baseline.len, buf));
            try std.testing.expectEqual(@as(usize, 0), pt.add_buffer.items.len);
            try std.testing.expectEqual(@as(usize, 0), pt.add_pages.items.len);
            try std.testing.expectEqual(@as(usize, 0), pt.add_pages_total_len);
        }
    }
    return error.TestUnexpectedResult;
}

test "PieceTree transactions preserve text and release split nodes on every allocation failure" {
    try checkTransactionalAllocationFailures(false);
    try checkTransactionalAllocationFailures(true);
}

test "PieceTree transaction rollback keeps prior snapshots and anchors valid" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "hello world\n");
    defer pt.deinit();
    const anchor = pt.anchorAtStrict(6, .right);
    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();
    {
        var tx = pt.beginTransaction();
        defer tx.deinit();
        try tx.insert(0, "prefix");
        try tx.delete(8, 3);
        try std.testing.expectError(error.InvalidRange, tx.delete(1, std.math.maxInt(usize)));
    }
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings("hello world\n", try pt.getText(0, pt.totalLength(), &buf));
    try std.testing.expectEqualStrings("hello world\n", try snap.getText(0, snap.totalLength(), &buf));
    try std.testing.expectEqual(@as(usize, 6), pt.resolveAnchor(anchor));
    // A subsequent transaction can acquire the lock and publish a complete edit.
    try pt.insert(0, "ok ");
    try std.testing.expectEqual(@as(usize, 9), pt.resolveAnchor(anchor));
}

test "PieceTree insertion accepts a borrowed add-buffer chunk across reallocation" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();
    const content = "abcdef\n" ** 500;
    try pt.insert(0, content);
    const chunk = pt.getChunkAt(0).?;
    try pt.insert(0, chunk.ptr[0..chunk.len]);
    const buf = try std.testing.allocator.alloc(u8, pt.totalLength());
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqualStrings(content ++ content, try pt.getText(0, pt.totalLength(), buf));
}

// ============================================================================
// 边界 & 树形状补充测试
//
// 既有 66 条覆盖了常规插入/删除/行索引/anchor/事务。这组专打此前没测过的
// 分支：空文档退化、单字符、超长行、无换行大文件、非法 UTF-8、以及
// SumTree 分裂/合并路径上的树形状不变量。
// ============================================================================

/// 确定性 LCG（与 sum_tree.zig 的 fuzzy 测试同款乘数）。
const Lcg = struct {
    state: u64,

    fn init(seed: u64) Lcg {
        return .{ .state = seed };
    }

    /// 返回 [0, mod) 的 usize。mod 必须非零。
    fn below(self: *Lcg, mod: usize) usize {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        const m: u64 = @intCast(mod);
        return @as(usize, @intCast((self.state >> 33) % m));
    }
};

/// 树形状不变量校验。只断言本实现**必须**成立的性质：
///   1. 所有叶子深度相同（高度只在根部分裂/坍缩时变化，splitInternalInsert
///      造的新节点高度取自兄弟，merge 不改深度，所以深度必然均匀）；
///   2. 每个节点项数 ≤ BRANCHING_FACTOR（分裂总是 4/5，插入有容量守卫）；
///   3. Σ(piece.length) == tree.summary().bytes == totalLength()；
///   4. piece 总数 == tree.count()。
/// 刻意**不**断言「叶子填充 ≥ MIN_CHILDREN」：removeInNode 只对直接子节点
/// rebalance、不上抛，欠满是本实现允许的中间态（见 sum_tree.zig:631）。
const PieceTreeShape = struct {
    /// B-tree 参数照抄 sum_tree.zig（BRANCHING_FACTOR=8）。
    const branching_factor: usize = 8;
    /// 退化成链表时的深度上限。8 叉树下 512 piece 只需深度 2；6 是宽松护栏，
    /// 专门抓「树退化成线性」这类结构灾难。
    const max_depth: usize = 6;

    fn check(pt: *const PieceTree, alloc: std.mem.Allocator) !void {
        var depths = std.ArrayList(usize){};
        defer depths.deinit(alloc);
        var piece_count: usize = 0;
        var byte_sum: usize = 0;

        const root = pt.tree.root orelse {
            try std.testing.expectEqual(@as(usize, 0), pt.tree.count());
            try std.testing.expectEqual(@as(usize, 0), pt.tree.summary().bytes);
            return;
        };
        try collect(root, 0, &depths, &piece_count, &byte_sum, alloc);

        try std.testing.expectEqual(pt.tree.count(), piece_count);
        try std.testing.expectEqual(pt.totalLength(), byte_sum);
        try std.testing.expect(depths.items.len > 0);
        for (depths.items) |d| {
            try std.testing.expectEqual(depths.items[0], d);
            try std.testing.expect(d <= max_depth);
        }
    }

    fn collect(
        node: *const Tree.Node,
        depth: usize,
        depths: *std.ArrayList(usize),
        piece_count: *usize,
        byte_sum: *usize,
        alloc: std.mem.Allocator,
    ) !void {
        switch (node.data) {
            .leaf => |*leaf| {
                try depths.append(alloc, depth);
                try std.testing.expect(leaf.len <= branching_factor);
                piece_count.* += leaf.len;
                for (leaf.items[0..leaf.len]) |piece| byte_sum.* += piece.length;
            },
            .internal => |*internal| {
                try std.testing.expect(internal.len <= branching_factor);
                try std.testing.expect(internal.len > 0);
                for (0..internal.len) |i| {
                    try collect(internal.children[i], depth + 1, depths, piece_count, byte_sum, alloc);
                }
            },
        }
    }
};

test "PieceTree: empty document degenerate paths stay consistent" {
    const alloc = std.testing.allocator;
    var pt = PieceTree.init(alloc);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.longestRowChars());
    try std.testing.expectEqual(@as(usize, 0), pt.tree.count());
    // 查询在空文档上必须安全
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
    try std.testing.expectEqual(@as(?PieceTree.ChunkResult, null), pt.getChunkAt(0));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", try pt.getText(0, 0, &buf));
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(PieceTree.Anchor.END));
    // initFromBuffer("") 与 init() 等价（0 个 piece）；空树形状检查也必须安全
    var pt2 = try PieceTree.initFromBuffer(alloc, "");
    defer pt2.deinit();
    try std.testing.expectEqual(@as(usize, 0), pt2.tree.count());
    try std.testing.expectEqual(@as(usize, 0), pt2.totalLength());
    try PieceTreeShape.check(&pt2, alloc);
    // 空文档上删除 0 长度是合法 no-op
    try pt.delete(0, 0);
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
}

test "PieceTree: single character round-trips through every read path" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "x");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 1), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 1), pt.longestRowChars());
    try std.testing.expectEqual(@as(usize, 1), pt.tree.count());

    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("x", try pt.getText(0, 1, &buf));
    try std.testing.expectEqualStrings("x", try pt.getLine(0, &buf));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(0));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(1));
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));

    const chunk = pt.getChunkAt(0).?;
    try std.testing.expectEqual(@as(usize, 1), chunk.len);
    try std.testing.expectEqual(@as(u8, 'x'), chunk.ptr[0]);
    try std.testing.expectEqual(@as(?PieceTree.ChunkResult, null), pt.getChunkAt(1));

    var it = pt.chunksInRange(0, 1);
    try std.testing.expectEqualStrings("x", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());

    var snap = try pt.snapshot(std.testing.allocator);
    defer snap.deinit();
    try std.testing.expectEqualStrings("x", try snap.getText(0, 1, &buf));

    // 逐字节打满再清空：piece 反复 split/replace/remove 的最小压力路径
    try pt.delete(0, 1);
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 0), pt.tree.count());
    try pt.insert(0, "y");
    try std.testing.expectEqualStrings("y", try pt.getText(0, 1, &buf));
}

test "PieceTree: single character inserted into empty tree" {
    var pt = PieceTree.init(std.testing.allocator);
    defer pt.deinit();
    try pt.insert(0, "Q");
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("Q", try pt.getText(0, pt.totalLength(), &buf));
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
}

test "PieceTree: deleting everything then editing again stays consistent" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "aa\nbb\ncc\n");
    defer pt.deinit();
    try pt.delete(0, pt.totalLength());
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try PieceTreeShape.check(&pt, std.testing.allocator);

    // 文档清空后（tree.count()==0）再走 insert 的「空树 push」分支
    try pt.insert(0, "fresh\ncontent\n");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("fresh\ncontent\n", try pt.getText(0, pt.totalLength(), &buf));
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
    try PieceTreeShape.check(&pt, std.testing.allocator);
}

test "PieceTree: single very long line survives piece boundaries and cross-piece joins" {
    const alloc = std.testing.allocator;
    // 行长跨过 initial_piece_bytes(2048) 与 ADD_BUFFER_PAGE_SIZE(64KiB) 两个分片阈值
    const line_len: usize = 150_000;
    const content = try alloc.alloc(u8, line_len);
    defer alloc.free(content);
    @memset(content, 'L');

    var pt = try PieceTree.initFromBuffer(alloc, content);
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, line_len), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(u32, @intCast(line_len)), pt.longestRowChars());
    try PieceTreeShape.check(&pt, alloc);

    // 在长行中间插入等长内容：split -> prefix/add/suffix 三段
    const mid = line_len / 2;
    try pt.insert(mid, content);
    try std.testing.expectEqual(@as(usize, line_len * 2), pt.totalLength());
    try std.testing.expectEqual(@as(u32, @intCast(line_len * 2)), pt.longestRowChars());
    try PieceTreeShape.check(&pt, alloc);

    // 全量读回并逐段比对
    const full = try alloc.alloc(u8, pt.totalLength());
    defer alloc.free(full);
    try std.testing.expectEqual(@as(usize, line_len * 2), (try pt.getText(0, pt.totalLength(), full)).len);
    try std.testing.expectEqualSlices(u8, content, full[0..line_len]);
    try std.testing.expectEqualSlices(u8, content, full[line_len..]);

    // 行坐标在超长单行上必须全程为 0
    var off: usize = 0;
    while (off <= pt.totalLength()) : (off += 997) {
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(@min(off, pt.totalLength())));
    }
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));

    // ChunkIterator 跨多个 piece 拼回全文
    var it = pt.chunksInRange(0, pt.totalLength());
    var assembled: usize = 0;
    while (it.next()) |chunk| assembled += chunk.len;
    try std.testing.expectEqual(pt.totalLength(), assembled);
}

test "PieceTree: long line that exceeds one add-buffer page" {
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, ADD_BUFFER_PAGE_SIZE + 1024);
    defer alloc.free(big);
    @memset(big, 'z');

    var pt = PieceTree.init(alloc); // 空树：insert 走 pushInsertedPieces 多页路径
    defer pt.deinit();
    try pt.insert(0, big);
    try std.testing.expectEqual(big.len, pt.totalLength());
    try std.testing.expectEqual(@as(u32, @intCast(big.len)), pt.longestRowChars());
    try std.testing.expectEqual(@as(usize, 2), pt.add_pages.items.len);

    const full = try alloc.alloc(u8, pt.totalLength());
    defer alloc.free(full);
    try std.testing.expectEqualSlices(u8, big, try pt.getText(0, pt.totalLength(), full));

    // 删除跨 add 页边界的内容后，剩余字节仍然正确
    try pt.delete(ADD_BUFFER_PAGE_SIZE - 4, 8);
    const rest = try alloc.alloc(u8, pt.totalLength());
    defer alloc.free(rest);
    const got = try pt.getText(0, pt.totalLength(), rest);
    try std.testing.expectEqualSlices(u8, big[0 .. ADD_BUFFER_PAGE_SIZE - 4], got[0 .. ADD_BUFFER_PAGE_SIZE - 4]);
    try std.testing.expectEqualSlices(u8, big[ADD_BUFFER_PAGE_SIZE + 4 ..], got[ADD_BUFFER_PAGE_SIZE - 4 ..]);
}

test "PieceTree: large file with no newlines keeps offset<->line trivial" {
    const alloc = std.testing.allocator;
    const size: usize = 1024 * 1024;
    const content = try alloc.alloc(u8, size);
    defer alloc.free(content);
    // 半随机可校验内容（不用 '\n'）
    var rng = Lcg.init(7);
    for (content) |*b| b.* = @intCast('a' + @as(u32, @intCast(rng.below(26))));

    var pt = try PieceTree.initFromBuffer(alloc, content);
    defer pt.deinit();
    try std.testing.expectEqual(size, pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(usize, size / PieceTree.initial_piece_bytes), pt.tree.count());
    try PieceTreeShape.check(&pt, alloc);

    // 抽样读回并校验（分段 getText 走跨 piece 路径）
    var buf: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < size) : (off += 61_234) {
        const n = @min(buf.len, size - off);
        if (n == 0) break;
        try std.testing.expectEqualSlices(u8, content[off .. off + n], try pt.getText(off, n, &buf));
    }

    // 任意 offset 都在第 0 行
    var probe: usize = 0;
    while (probe < size) : (probe += 123_457) {
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(probe));
    }

    // 1MiB 无换行文件在文件中间插入一个换行：lineCount 1->2，坐标全部正确。
    // 语义对齐既有测试 "offsetToLine and lineToOffset"：lineToOffset(k) 返回
    // 第 k 个 '\n' 之后的字节（lineToOffsetInNode 的 `byte_offset + j + 1`），
    // 所以 '\n' 插在 mid 时 line 1 从 mid+1 开始；offsetToLine 则只数严格位于
    // offset 之前的 '\n'。此前把 lineToOffset(1) 断言成 mid，差 1 是本测试
    // 写错了预期，不是实现错。
    const mid = size / 2;
    try pt.insert(mid, "\n");
    try std.testing.expectEqual(@as(usize, 2), pt.lineCount());
    try std.testing.expectEqual(@as(usize, mid + 1), pt.lineToOffset(1));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(mid));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(mid + 1));
    try std.testing.expectEqual(@as(usize, 1), pt.offsetToLine(mid + 5));
    try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(mid - 1));
    // getLine(k) 的区间是 [lineToOffset(k), lineToOffset(k+1))，**含行尾的
    // '\n'**（见 getLine 实现：end = lineToOffset(line+1)）。所以 line 0 是
    // content[0..mid] 再加那个插入的换行，长度 mid+1，不是 mid。
    const line_buf = try alloc.alloc(u8, mid + 1);
    defer alloc.free(line_buf);
    const line0 = try pt.getLine(0, line_buf);
    try std.testing.expectEqual(@as(usize, mid + 1), line0.len);
    try std.testing.expectEqualStrings(content[0..mid], line0[0..mid]);
    try std.testing.expectEqual(@as(u8, '\n'), line0[mid]);
    try PieceTreeShape.check(&pt, alloc);
}

test "PieceTree: invalid UTF-8 bytes are stored and returned verbatim" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "\xff", // 孤立非法字节
        "\xc3\x28", // 2 字节 lead 后跟 ASCII（非法 continuation）
        "\xe2\x82", // 3 字节序列被截断
        "\xf0\x9f\x98", // 4 字节序列被截断
        "ok\xff\xfe\xc0\x80ok", // 合法 + 非法混合
        "a\xc0\x80b", // NUL 的过长编码
    };

    for (cases) |content| {
        var pt = try PieceTree.initFromBuffer(alloc, content);
        defer pt.deinit();
        const buf = try alloc.alloc(u8, content.len);
        defer alloc.free(buf);
        try std.testing.expectEqualStrings(content, try pt.getText(0, content.len, buf));

        // 中间插入 + 删除后字节仍然原样
        try pt.insert(content.len / 2, "\xff");
        try pt.delete(content.len / 2, 1);
        try std.testing.expectEqualStrings(content, try pt.getText(0, content.len, buf));
    }
}

test "PieceTree: invalid UTF-8 does not corrupt byte-exact reads or summary aggregation" {
    const alloc = std.testing.allocator;
    // 3 字节汉字序列在缓冲区末尾方向被截断（E4 BD 后紧跟 '\n'）：
    // 这是 scanTextStats 的 advance 修正路径 + 已知怪癖（见 piece_stats.zig
    // 模块头的坑位说明）。本测试不硬编码怪癖算术，只锁两条无歧义不变量：
    //   1. 字节级读写完全不受多字节解码影响（存储层是纯字节）；
    //   2. Summary 聚合与对同一缓冲的单遍 scan 一致（统计自洽）。
    const tail = "\u{4F60}"[0..2]; // E4 BD（缺第 3 字节）
    var content = std.ArrayList(u8){};
    defer content.deinit(alloc);
    try content.appendSlice(alloc, "aaa\n");
    try content.appendSlice(alloc, "\u{4F60}");
    try content.appendSlice(alloc, tail);
    try content.appendSlice(alloc, "\nbbb\n");

    var pt = try PieceTree.initFromBuffer(alloc, content.items);
    defer pt.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(content.items, try pt.getText(0, pt.totalLength(), &buf));
    // line0 是纯 ASCII，其边界由真实字节扫描（lineToOffsetInNode）决定
    try std.testing.expectEqualStrings("aaa\n", try pt.getLine(0, &buf));
    // Summary 行数 == 单遍 scan 的 newline_count + 1（单 piece 下的自洽性）
    try std.testing.expectEqual(
        PieceTree.scanTextStats(content.items).newline_count + 1,
        pt.lineCount(),
    );

    // snapshot 路径读回同样字节
    var snap = try pt.snapshot(alloc);
    defer snap.deinit();
    try std.testing.expectEqualStrings(content.items, try snap.getText(0, snap.totalLength(), &buf));
}

test "PieceTree: offset beyond total clamps instead of panicking" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abc\ndef\n");
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, 2), pt.offsetToLine(999));
    try std.testing.expectEqual(@as(usize, 0), pt.lineToOffset(0));
    // 超界行号退化为文档末尾（现有行为：返回末 piece 累计偏移）
    try std.testing.expectEqual(pt.totalLength(), pt.lineToOffset(999));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidRange, pt.getText(9, 1, &tiny));
    try std.testing.expectError(error.InvalidPosition, pt.insert(99, "x"));
    try std.testing.expectError(error.InvalidRange, pt.delete(99, 1));
    // start == total 是合法的（末尾插入）
    try pt.insert(pt.totalLength(), "!");
    try std.testing.expectError(error.InvalidLine, pt.getLine(99, &tiny));
}

test "PieceTree: many small edits keep the tree a balanced B-tree" {
    const alloc = std.testing.allocator;
    var pt = try PieceTree.initFromBuffer(alloc, "");
    defer pt.deinit();

    // 用「可精确重放的字符串模型」做 oracle：每一步编辑后 both 全文一致 +
    // 树形状合法。LCG 保证可复现。
    var model = std.ArrayList(u8){};
    defer model.deinit(alloc);

    var rng = Lcg.init(20260730);
    const alphabet = "abcdefghij\n\n";
    const read_buf = try alloc.alloc(u8, 4096);
    defer alloc.free(read_buf);

    var step: usize = 0;
    while (step < 400) : (step += 1) {
        const op = rng.below(10);
        if (op < 6) {
            // 插入 1..12 个字符
            const n = 1 + rng.below(12);
            var tmp: [12]u8 = undefined;
            for (0..n) |i| tmp[i] = alphabet[rng.below(alphabet.len)];
            const pos = if (model.items.len == 0) 0 else rng.below(model.items.len + 1);
            try pt.insert(pos, tmp[0..n]);
            try model.insertSlice(alloc, pos, tmp[0..n]);
        } else if (op < 9 and model.items.len > 0) {
            // 删除 1..40 字节
            const pos = rng.below(model.items.len);
            const max_del = @min(40, model.items.len - pos);
            const n = 1 + rng.below(max_del);
            try pt.delete(pos, n);
            try model.replaceRange(alloc, pos, n, "");
        } else {
            // 替换：等价于 delete + insert（覆盖 deleteUnlocked 的跨 piece 分支）
            if (model.items.len == 0) continue;
            const pos = rng.below(model.items.len);
            const max_del = @min(20, model.items.len - pos);
            const n = 1 + rng.below(max_del);
            const insert_n = 1 + rng.below(12);
            var tmp: [12]u8 = undefined;
            for (0..insert_n) |i| tmp[i] = alphabet[rng.below(alphabet.len)];
            try pt.delete(pos, n);
            try model.replaceRange(alloc, pos, n, "");
            try pt.insert(pos, tmp[0..insert_n]);
            try model.insertSlice(alloc, pos, tmp[0..insert_n]);
        }

        // 每步校验：长度、全文、行数、最长行、树形状
        try std.testing.expectEqual(model.items.len, pt.totalLength());
        if (model.items.len > 0) {
            var pos: usize = 0;
            while (pos < model.items.len) {
                const n = @min(read_buf.len, model.items.len - pos);
                try std.testing.expectEqualSlices(u8, model.items[pos .. pos + n], try pt.getText(pos, n, read_buf));
                pos += n;
            }
        }
        var nl: usize = 1;
        for (model.items) |b| {
            if (b == '\n') nl += 1;
        }
        try std.testing.expectEqual(nl, pt.lineCount());

        var longest: u32 = 0;
        var cur: u32 = 0;
        for (model.items) |b| {
            if (b == '\n') {
                if (cur > longest) longest = cur;
                cur = 0;
            } else cur += 1;
        }
        if (cur > longest) longest = cur;
        // 注意：PieceTree 按 code point 计数，但本测试 alphabet 全 ASCII，两口径一致
        try std.testing.expectEqual(longest, pt.longestRowChars());

        if (step % 40 == 0) try PieceTreeShape.check(&pt, alloc);
    }
    try PieceTreeShape.check(&pt, alloc);
    // 刻意**不**断言 tree.count() 的具体量级：piece 数量取决于合并/分裂策略
    // （相邻同源 piece 会被合并），是实现细节而非契约。这个循环的价值在于
    // 「每步之后全文与 model 逐字节一致 + PieceTreeShape.check 通过」，那才是
    // B-tree 不变量。此前这里写了 `count() > 20`，实测随机序列下会被合并到
    // 20 以下而变红，断言的是实现细节，不是行为。
}

test "PieceTree: document entirely of newlines" {
    const alloc = std.testing.allocator;
    const n: usize = 5000;
    const content = try alloc.alloc(u8, n);
    defer alloc.free(content);
    @memset(content, '\n');

    var pt = try PieceTree.initFromBuffer(alloc, content);
    defer pt.deinit();
    try std.testing.expectEqual(n, pt.totalLength());
    try std.testing.expectEqual(n + 1, pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.longestRowChars());
    try PieceTreeShape.check(&pt, alloc);

    // line k 的起点必是 k（每行都是空行）
    var k: usize = 0;
    while (k <= n) : (k += 317) {
        try std.testing.expectEqual(k, pt.lineToOffset(k));
        try std.testing.expectEqual(k, pt.offsetToLine(k));
    }
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try pt.getLine(0, &buf));
    try std.testing.expectEqualStrings("", try pt.getLine(n, &buf));
}

test "PieceTree: snapshot line coordinates match the live tree" {
    const alloc = std.testing.allocator;
    var pt = try PieceTree.initFromBuffer(alloc, "l0\nl1\nl2\nl3\n");
    defer pt.deinit();
    try pt.insert(3, "INSERTED\n"); // 多 piece
    var snap = try pt.snapshot(alloc);
    defer snap.deinit();

    try std.testing.expectEqual(pt.totalLength(), snap.totalLength());
    try std.testing.expectEqual(pt.lineCount(), snap.lineCount());
    var off: usize = 0;
    while (off <= pt.totalLength()) : (off += 1) {
        try std.testing.expectEqual(pt.offsetToLine(off), snap.offsetToLine(off));
    }
    var line: usize = 0;
    while (line < pt.lineCount()) : (line += 1) {
        try std.testing.expectEqual(pt.lineToOffset(line), snap.lineToOffset(line));
    }
}

test "PieceTree: ChunkIterator seekTo repositions for non-sequential readers" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "0123456789abcdefghij");
    defer pt.deinit();
    try pt.insert(10, "---"); // 制造 3 个 piece

    const total = pt.totalLength();
    const buf = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(buf);
    // oracle：正序全量
    const oracle = try pt.getText(0, total, buf);

    // tree-sitter 式非顺序读法：读一段 -> seek 到中段 -> 读到尾 -> 再 seek 回头部
    var got = std.ArrayList(u8){};
    defer got.deinit(std.testing.allocator);

    var it = pt.chunksInRange(0, total);
    while (it.next()) |c| try got.appendSlice(std.testing.allocator, c);
    try std.testing.expectEqualStrings(oracle, got.items);

    got.clearRetainingCapacity();
    it.seekTo(6, total);
    while (it.next()) |c| try got.appendSlice(std.testing.allocator, c);
    try std.testing.expectEqualStrings(oracle[6..], got.items);

    got.clearRetainingCapacity();
    it.seekTo(0, total);
    while (it.next()) |c| try got.appendSlice(std.testing.allocator, c);
    try std.testing.expectEqualStrings(oracle, got.items);

    // seek 超出 total：钳到末尾，读出空
    it.seekTo(total * 2, total);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "PieceTree: anchors survive a delete that empties the document" {
    var pt = try PieceTree.initFromBuffer(std.testing.allocator, "abcdef");
    defer pt.deinit();
    const a = pt.anchorAtStrict(3, .right);
    try std.testing.expectEqual(@as(usize, 3), pt.resolveAnchor(a));
    try pt.delete(0, 6);
    // 文档清空：anchor 回退到 0（.right 且无 best_after 时落在 doc_offset）
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(a));
    // 清空后 anchorAtStrict 也不 panic
    const b = pt.anchorAtStrict(0, .left);
    try std.testing.expectEqual(@as(usize, 0), pt.resolveAnchor(b));
}

test "PieceTree: many-piece insert then full read matches (no newline, 300 pieces)" {
    const alloc = std.testing.allocator;
    var pt = PieceTree.init(alloc);
    defer pt.deinit();
    var expect = std.ArrayList(u8){};
    defer expect.deinit(alloc);

    // 300 次随机位置小插入，制造 300+ piece 的树（高度 2~3）
    var rng = Lcg.init(99);
    var step: usize = 0;
    while (step < 300) : (step += 1) {
        const pos = if (expect.items.len == 0) 0 else rng.below(expect.items.len + 1);
        const c: u8 = @intCast('A' + @as(u32, @intCast(rng.below(26))));
        try pt.insert(pos, &[_]u8{c});
        try expect.insert(alloc, pos, c);
    }
    try std.testing.expectEqual(expect.items.len, pt.totalLength());
    const buf = try alloc.alloc(u8, expect.items.len);
    defer alloc.free(buf);
    try std.testing.expectEqualSlices(u8, expect.items, try pt.getText(0, pt.totalLength(), buf));
    try PieceTreeShape.check(&pt, alloc);
    // 逐 offset 校验 offsetToLine（全程无换行 -> 恒 0）
    var off: usize = 0;
    while (off <= pt.totalLength()) : (off += 7) {
        try std.testing.expectEqual(@as(usize, 0), pt.offsetToLine(off));
    }
}

test "PieceTree fragmented range reads match immutable snapshot after COW edit" {
    const allocator = std.testing.allocator;
    const original = "abcd" ** 256;
    var tree = try PieceTree.initFromBuffer(allocator, original);
    defer tree.deinit();
    for (0..256) |i| try tree.insert(i * 6 + 2, "XY");
    const expected = "abXYcd" ** 256;
    var snapshot = try tree.snapshot(allocator);
    defer snapshot.deinit();
    try tree.insert(0, "prefix");
    const live_expected = "prefix" ++ expected;
    var buffer: [live_expected.len]u8 = undefined;
    var start: usize = 0;
    while (start <= expected.len) : (start += 1) {
        for ([_]usize{ 0, @min(@as(usize, 1), expected.len - start), @min(@as(usize, 31), expected.len - start), expected.len - start }) |length| {
            const snap_text = try snapshot.getText(start, length, &buffer);
            try std.testing.expectEqualSlices(u8, expected[start .. start + length], snap_text);
            const live_text = try tree.getText(start + 6, length, &buffer);
            try std.testing.expectEqualSlices(u8, expected[start .. start + length], live_text);
        }
    }
    try std.testing.expectEqualSlices(u8, live_expected, try tree.getText(0, live_expected.len, &buffer));
    try std.testing.expectError(error.InvalidRange, snapshot.getText(expected.len, 1, &buffer));
    try std.testing.expectError(error.BufferTooSmall, tree.getText(0, 2, buffer[0..1]));
}

test "PieceTree public edits never retain zero-byte pieces" {
    var tree = try PieceTree.initFromBuffer(std.testing.allocator, "");
    defer tree.deinit();
    const Op = struct { start: usize, remove: usize = 0, insert: []const u8 = "" };
    for ([_]Op{
        .{ .start = 0 },
        .{ .start = 0, .insert = "abcdef" },
        .{ .start = 0 },
        .{ .start = 6 },
        .{ .start = 3, .insert = "XYZ" },
        .{ .start = 4, .remove = 1 },
        .{ .start = 2, .remove = 4 },
        .{ .start = 0, .remove = 1 },
        .{ .start = 2, .remove = 1 },
        .{ .start = 0, .remove = 2 },
        .{ .start = 0, .insert = "again" },
        .{ .start = 0, .remove = 5 },
    }) |op| {
        try tree.delete(op.start, op.remove);
        try tree.insert(op.start, op.insert);
        var pieces = tree.tree.iterator();
        var bytes: usize = 0;
        while (pieces.next()) |piece| {
            try std.testing.expect(piece.length > 0);
            bytes += piece.length;
        }
        try std.testing.expectEqual(bytes, tree.totalLength());
        var snapshot = try tree.snapshot(std.testing.allocator);
        defer snapshot.deinit();
        var buffer: [32]u8 = undefined;
        _ = try snapshot.getText(0, bytes, &buffer);
        _ = try tree.getText(0, bytes, &buffer);
    }
}
