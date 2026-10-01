/// DocCursor，通用文档光标
///
/// 基于字节偏移的光标系统，支持选区和行列映射。
///
/// 泛型参数 Doc: 任何提供以下 API 的文档类型:
///   totalLength() -> usize
///   offsetToLineCol(offset) -> LineCol
///   lineColToOffset(line, col) -> usize
///   lineCount() -> usize
///   getLineStart(line) -> usize
///   getLineEnd(line) -> usize
///   getByteAt(offset) -> ?u8
///   deleteRange(start, len) -> !void   (唯一的 mut 操作)
/// 行列坐标
pub const LineCol = struct {
    line: usize,
    col: usize,
};

const grapheme = @import("grapheme.zig");

/// DocCursor，通用文档光标
/// Doc: 任何提供 totalLength/offsetToLineCol/lineColToOffset/lineCount/getLineStart/getLineEnd/getByteAt/deleteRange 的类型
pub fn DocCursor(comptime Doc: type) type {
    return struct {
        const Self = @This();

        /// 字节偏移
        offset: usize = 0,
        /// 选区锚点 (非 null 时有选区)
        anchor: ?usize = null,
        /// 上下移动时保持的目标列
        preferred_col: ?usize = null,

        pub fn selection(self: *const Self) ?struct { start: usize, end: usize } {
            const a = self.anchor orelse return null;
            if (a == self.offset) return null;
            return .{
                .start = @min(a, self.offset),
                .end = @max(a, self.offset),
            };
        }

        pub fn hasSelection(self: *const Self) bool {
            if (self.anchor) |a| return a != self.offset;
            return false;
        }

        pub fn moveTo(self: *Self, offset: usize) void {
            self.offset = offset;
            self.anchor = null;
            self.preferred_col = null;
        }

        pub fn selectTo(self: *Self, offset: usize) void {
            if (self.anchor == null) {
                self.anchor = self.offset;
            }
            self.offset = offset;
        }

        pub fn clearSelection(self: *Self) void {
            self.anchor = null;
        }

        pub fn selectAll(self: *Self, doc: *const Doc) void {
            self.anchor = 0;
            self.offset = doc.totalLength();
        }

        pub fn deleteSelection(self: *Self, doc: *Doc) !?usize {
            const sel = self.selection() orelse return null;
            try doc.deleteRange(sel.start, sel.end - sel.start);
            self.offset = sel.start;
            self.anchor = null;
            return sel.start;
        }

        // ===== 导航 =====

        pub fn moveLeft(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.start);
                return;
            }
            if (self.offset == 0) return;
            const new_off = prevCharBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveRight(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.end);
                return;
            }
            if (self.offset >= doc.totalLength()) return;
            const new_off = nextCharBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveUp(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            if (lc.line == 0) {
                if (shift) self.selectTo(0) else self.moveTo(0);
                return;
            }
            const target_col = self.preferred_col orelse lc.col;
            const new_off = floorCharBoundary(doc, doc.lineColToOffset(lc.line - 1, target_col));
            if (shift) self.selectTo(new_off) else {
                self.offset = new_off;
                self.anchor = null;
            }
            self.preferred_col = target_col;
        }

        pub fn moveDown(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            if (lc.line + 1 >= doc.lineCount()) {
                const end = doc.totalLength();
                if (shift) self.selectTo(end) else self.moveTo(end);
                return;
            }
            const target_col = self.preferred_col orelse lc.col;
            const new_off = floorCharBoundary(doc, doc.lineColToOffset(lc.line + 1, target_col));
            if (shift) self.selectTo(new_off) else {
                self.offset = new_off;
                self.anchor = null;
            }
            self.preferred_col = target_col;
        }

        pub fn moveToLineStart(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            const target = doc.getLineStart(lc.line);
            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        pub fn moveToLineEnd(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            const target = doc.getLineEnd(lc.line);
            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        // ===== 按词导航 =====

        pub fn moveWordLeft(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.start);
                return;
            }
            const new_off = prevWordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveWordRight(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.end);
                return;
            }
            const new_off = nextWordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        /// 返回 offset 所在词的 {start, end} 范围（双击选词用）
        /// CJK 字符每个字单独成词；ASCII 词字符连续成词
        pub fn wordBoundsAt(doc: *const Doc, offset: usize) struct { start: usize, end: usize } {
            const total = doc.totalLength();
            if (total == 0) return .{ .start = 0, .end = 0 };

            // `offset` is normally a cursor/grapheme boundary, but pointer
            // hit-testing and callers at EOF can hand us any byte offset. Probe
            // through the byte under the pointer and walk back to the containing
            // grapheme start. In particular, `total - 1` is a UTF-8 continuation
            // byte when the document ends in CJK/emoji.
            const probe_end = if (offset < total) offset + 1 else total;
            const cur_off = prevCharBoundary(doc, probe_end);
            const b = doc.getByteAt(cur_off) orelse return .{ .start = offset, .end = offset };

            // 表意/emoji（3/4 字节 lead）：每个 grapheme 独立成词。
            // 用 grapheme 边界而非手算 char_len：ZWJ 家庭 emoji / 旗帜是多 codepoint 簇。
            if (b >= 0xE0) {
                return .{ .start = cur_off, .end = nextCharBoundary(doc, cur_off) };
            }

            if (b < 0x80 and isWordSeparator(b)) {
                // 在分隔符上：选中连续的分隔符
                var start = cur_off;
                while (start > 0) {
                    const pb = doc.getByteAt(start - 1) orelse break;
                    if (!isWordSeparator(pb)) break;
                    start -= 1;
                }
                var end = cur_off;
                while (end < total) {
                    const nb = doc.getByteAt(end) orelse break;
                    if (!isWordSeparator(nb)) break;
                    end += 1;
                }
                return .{ .start = start, .end = end };
            }

            // 词字符（ASCII 词字符 + 2 字节脚本如希腊/西里尔/拉丁扩展）：
            // 向两侧扩展，遇 ASCII 分隔符或表意字符（>= 0xE0 lead）停止。
            // 历史 bug：这里曾用 `pb >= 0x80` 一刀切，2 字节字符上双击选出空范围。
            var start = cur_off;
            while (start > 0) {
                const pb = doc.getByteAt(start - 1) orelse break;
                if (pb < 0x80) {
                    if (isWordSeparator(pb)) break;
                    start -= 1;
                } else {
                    const q = prevCharBoundary(doc, start);
                    const lead = doc.getByteAt(q) orelse break;
                    if (lead >= 0xE0) break;
                    start = q;
                }
            }
            var end = cur_off;
            while (end < total) {
                const nb = doc.getByteAt(end) orelse break;
                if (nb < 0x80 and isWordSeparator(nb)) break;
                if (nb >= 0xE0) break;
                end += 1;
            }
            return .{ .start = start, .end = end };
        }

        /// 向前找词边界（跳分隔符再跳词字符）
        /// CJK 字符每个字都是独立边界
        pub fn prevWordBoundary(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            var p = offset;
            // 跳过左边的空白/分隔符
            while (p > 0) {
                const b = doc.getByteAt(p - 1) orelse break;
                if (!isWordSeparator(b)) break;
                p -= 1;
            }
            if (p == 0) return 0;
            // 前一个字符若是表意/emoji（>= 0xE0 lead）：单簇成词，退一个 grapheme
            {
                const q = prevCharBoundary(doc, p);
                const lead = doc.getByteAt(q) orelse return q;
                if (lead >= 0xE0) return q;
            }
            // 词字符（ASCII 词字符 + 2 字节脚本如希腊/西里尔/拉丁扩展）：连续回退，
            // 遇 ASCII 分隔符或表意字符停止。
            // 历史 bug：2 字节字符只退一个字符而非整词（与 nextWordBoundary 不对称）。
            while (p > 0) {
                const b = doc.getByteAt(p - 1) orelse break;
                if (b < 0x80) {
                    if (isWordSeparator(b)) break;
                    p -= 1;
                } else {
                    const q = prevCharBoundary(doc, p);
                    const lead = doc.getByteAt(q) orelse break;
                    if (lead >= 0xE0) break;
                    p = q;
                }
            }
            return p;
        }

        /// 向后找词边界（跳词字符再跳分隔符）
        /// CJK 字符每个字都是独立边界
        pub fn nextWordBoundary(doc: *const Doc, offset: usize) usize {
            const total = doc.totalLength();
            if (offset >= total) return total;
            var p = offset;
            const first = doc.getByteAt(p) orelse return p;
            if (first >= 0xE0) {
                // 表意/emoji：跳过一个完整 grapheme（ZWJ 家庭 emoji / 旗帜是
                // 多 codepoint 簇，手算 char_len 会落在簇中间），再跳分隔符
                p = nextCharBoundary(doc, p);
            } else if (first >= 0x80 or !isWordSeparator(first)) {
                // 词字符（ASCII 词字符 + 2 字节脚本如希腊/西里尔/拉丁扩展）：
                // 连续跳过，遇 ASCII 分隔符或表意字符停止。
                // 历史 bug：这里曾用 `b >= 0x80` 一刀切 break，2 字节字符上
                // 光标原地不动（Alt+Right 失灵）。continuation byte（0x80-0xBF）
                // 在本扫描域内只可能属于 2 字节字符，表意 lead 已先停住。
                while (p < total) {
                    const b = doc.getByteAt(p) orelse break;
                    if (b < 0x80 and isWordSeparator(b)) break;
                    if (b >= 0xE0) break;
                    p += 1;
                }
            }
            // 跳过右边的空白/分隔符
            while (p < total) {
                const b = doc.getByteAt(p) orelse break;
                if (!isWordSeparator(b)) break;
                p += 1;
            }
            return @min(p, total);
        }

        pub fn isWordSeparator(c: u8) bool {
            return switch (c) {
                ' ', '\t', '\n', '\r', '.', ',', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`', '/', '\\', '|', '@', '#', '$', '%', '^', '&', '*', '-', '+', '=', '~' => true,
                else => false,
            };
        }

        /// 判断 ASCII 字节是否是"词内部的字符"（字母、数字、下划线）。
        /// 和 isWordSeparator 互补（对 ASCII 来说）。
        pub fn isWordChar(c: u8) bool {
            return (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or
                c == '_';
        }

        // ===== Subword 导航 =====
        //
        // Subword 把一个 word 内部按 camelCase / snake_case / letter↔digit 进一步切分。
        // 例："getUserName_v2" -> ["get", "User", "Name", "_", "v", "2"]
        //
        // 边界判定规则（相邻两字节 p, c）：
        //   1. 原 word 边界仍然是 subword 边界（isWordSeparator 切分）
        //   2. lower->Upper / Upper->lower（`aB` -> `a|B`；`AB`+`a` -> `AB|a` 需要向前看）
        //   3. letter ↔ digit（`v2` -> `v|2`）
        //   4. 字符 ↔ `_` 或 `-`
        //
        // multi-byte 字符按"每个字符是独立 subword 边界"对待（类似 CJK 词模型）。

        fn byteClass(c: u8) enum { lower, upper, digit, underscore, dash, other } {
            if (c >= 'a' and c <= 'z') return .lower;
            if (c >= 'A' and c <= 'Z') return .upper;
            if (c >= '0' and c <= '9') return .digit;
            if (c == '_') return .underscore;
            if (c == '-') return .dash;
            return .other;
        }

        /// 判断从 p -> c 之间是否存在 subword 边界（同 word 内部）。
        /// 要求 p 和 c 都是 ASCII 词字符（调用前需过滤分隔符）。
        fn isSubwordBoundaryAscii(p: u8, c: u8) bool {
            const pc = byteClass(p);
            const cc = byteClass(c);
            if (pc == cc) return false;
            // lower -> Upper（camelCase 首字母）
            if (pc == .lower and cc == .upper) return true;
            // letter ↔ digit
            const p_is_letter = pc == .lower or pc == .upper;
            const c_is_letter = cc == .lower or cc == .upper;
            if (p_is_letter and cc == .digit) return true;
            if (pc == .digit and c_is_letter) return true;
            // 任意字符 ↔ _ / -
            if (pc == .underscore or pc == .dash or cc == .underscore or cc == .dash) return true;
            return false;
        }

        /// 向前找 subword 边界。返回 <= offset 的最近边界。
        pub fn prevSubwordBoundary(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            var p = offset;

            // 跳过左边的空白/分隔符（和 prevWordBoundary 一致）
            while (p > 0) {
                const b = doc.getByteAt(p - 1) orelse break;
                if (!isWordSeparator(b)) break;
                p -= 1;
            }
            if (p == 0) return 0;

            // 若前一个字节是 multi-byte（≥0x80），退一个完整 UTF-8 字符即算一个 subword
            const prev_b = doc.getByteAt(p - 1) orelse return p;
            if (prev_b >= 0x80) {
                return prevCharBoundary(doc, p);
            }

            // ASCII 路径：往左扫到 subword 边界或原 word 边界
            // 第一步：至少退一个字节
            p -= 1;
            while (p > 0) {
                const cur = doc.getByteAt(p) orelse break;
                const prev = doc.getByteAt(p - 1) orelse break;
                if (isWordSeparator(prev) or prev >= 0x80) break;
                if (isSubwordBoundaryAscii(prev, cur)) break;
                p -= 1;
            }
            return p;
        }

        /// 向后找 subword 边界。返回 >= offset 的最近边界。
        pub fn nextSubwordBoundary(doc: *const Doc, offset: usize) usize {
            const total = doc.totalLength();
            if (offset >= total) return total;
            var p = offset;

            const first = doc.getByteAt(p) orelse return p;

            // multi-byte 字符：跳过一个完整字符就算一个 subword。
            // 历史 bug：只判 >= 0xE0，2 字节字符落进 ASCII 路径 p += 1
            // 直接停在字符中间。
            if (first >= 0x80) {
                p = nextCharBoundary(doc, p);
                // 跳过右侧分隔符以和 word 版本保持一致
                while (p < total) {
                    const b = doc.getByteAt(p) orelse break;
                    if (!isWordSeparator(b)) break;
                    p += 1;
                }
                return p;
            }

            // ASCII 分隔符：先跳过所有分隔符（和 nextWordBoundary 一致的前置处理）
            if (isWordSeparator(first)) {
                while (p < total) {
                    const b = doc.getByteAt(p) orelse break;
                    if (!isWordSeparator(b)) break;
                    p += 1;
                }
                return p;
            }

            // 词内部：扫到下一个 subword 边界
            p += 1;
            while (p < total) {
                const cur = doc.getByteAt(p) orelse break;
                const prev = doc.getByteAt(p - 1) orelse break;
                if (isWordSeparator(cur) or cur >= 0x80) break;
                if (isSubwordBoundaryAscii(prev, cur)) break;
                p += 1;
            }
            while (p < total) {
                const b = doc.getByteAt(p) orelse break;
                if (!isWordSeparator(b)) break;
                p += 1;
            }
            return p;
        }

        pub fn moveSubwordLeft(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.start);
                return;
            }
            const new_off = prevSubwordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveSubwordRight(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.end);
                return;
            }
            const new_off = nextSubwordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        // ===== 段落导航 =====
        //
        // 段落 = 被空行分隔的文本块。空行 = 完全空或只含空白字符的行。
        //
        // moveToPrevParagraph：跳到当前段落的开头；若已在段首，跳到上一段的开头。
        // moveToNextParagraph：跳到当前段落之后的空行（或文档末尾）。

        fn isBlankLine(doc: *const Doc, line: usize) bool {
            const start = doc.getLineStart(line);
            const end = doc.getLineEnd(line);
            var p = start;
            while (p < end) : (p += 1) {
                const b = doc.getByteAt(p) orelse return true;
                if (b != ' ' and b != '\t') return false;
            }
            return true;
        }

        pub fn moveToPrevParagraph(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            var line = lc.line;

            // 若当前不在行首或非空白，先尝试从当前行继续往上
            // 规则：往上找第一个空行（跳过当前所在的连续非空行）
            // 再继续跳过其上方的连续空行（段落之间的间隙）
            // 最终光标停在"非空段首行"的第 0 列

            // 第一步：如果当前行不是空行，先跳过当前段落（往上到空行或文档头）
            if (!isBlankLine(doc, line)) {
                while (line > 0 and !isBlankLine(doc, line - 1)) : (line -= 1) {}
                // line 停在段首
            } else {
                // 当前是空行 -> 跳过连续空行
                while (line > 0 and isBlankLine(doc, line - 1)) : (line -= 1) {}
                // 再跳过上一段
                while (line > 0 and !isBlankLine(doc, line - 1)) : (line -= 1) {}
            }

            const target = doc.getLineStart(line);
            // 若未移动（已经在段首且光标就在行首）-> 尝试再往上一段
            if (target == self.offset and line > 0) {
                var l2 = line - 1;
                while (l2 > 0 and isBlankLine(doc, l2)) : (l2 -= 1) {}
                while (l2 > 0 and !isBlankLine(doc, l2 - 1)) : (l2 -= 1) {}
                const t2 = doc.getLineStart(l2);
                if (shift) self.selectTo(t2) else self.moveTo(t2);
                return;
            }

            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        pub fn moveToNextParagraph(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            const total_lines = doc.lineCount();
            var line = lc.line;

            // 当前是非空行：跳过当前段到第一个空行
            if (!isBlankLine(doc, line)) {
                while (line + 1 < total_lines and !isBlankLine(doc, line + 1)) : (line += 1) {}
                // 落在段末；目标 = 段末的下一行（空行）开头
                line += 1;
            } else {
                // 当前是空行：跳过连续空行再跳过下一段
                while (line + 1 < total_lines and isBlankLine(doc, line + 1)) : (line += 1) {}
                while (line + 1 < total_lines and !isBlankLine(doc, line + 1)) : (line += 1) {}
                line += 1;
            }

            const target = if (line >= total_lines) doc.totalLength() else doc.getLineStart(line);
            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        // ===== UTF-8 字符边界 =====

        /// Keep an existing grapheme boundary, or floor an interior byte offset
        /// to the containing cluster's start. Retains byte-column navigation.
        pub fn floorCharBoundary(doc: *const Doc, offset: usize) usize {
            if (offset >= doc.totalLength()) return doc.totalLength();
            // prevBoundary is exclusive. Probing one byte later includes offset
            // itself, and its decoder first backs up to a codepoint start.
            return prevCharBoundary(doc, offset + 1);
        }

        /// 向前找前一个 grapheme cluster 的起始位置（UAX #29 extended grapheme cluster）
        ///
        /// 不能按 codepoint 退：家庭 emoji / 组合记号 / 旗帜 / 肤色修饰符都由多个
        /// codepoint 组成，按 codepoint 退会把它们拆成残缺序列。
        pub fn prevCharBoundary(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            return grapheme.prevBoundaryDoc(Doc, doc, offset);
        }

        /// 向后找下一个 grapheme cluster 的起始位置
        pub fn nextCharBoundary(doc: *const Doc, offset: usize) usize {
            const total = doc.totalLength();
            if (offset >= total) return total;
            return grapheme.nextBoundaryDoc(Doc, doc, offset);
        }
    };
}

// ===== 多行 Doc 路径的 grapheme 边界回归测试 =====

const std_t = @import("std");

/// 只实现 prev/nextCharBoundary 需要的两个方法的最小 Doc
const StubDoc = struct {
    bytes: []const u8,
    pub fn totalLength(self: *const StubDoc) usize {
        return self.bytes.len;
    }
    pub fn getByteAt(self: *const StubDoc, offset: usize) ?u8 {
        if (offset >= self.bytes.len) return null;
        return self.bytes[offset];
    }
};

test "DocCursor 边界按 grapheme cluster 而非 codepoint" {
    const C = DocCursor(StubDoc);
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const doc = StubDoc{ .bytes = "a" ++ family ++ "\u{1F1E8}\u{1F1F3}" };

    try std_t.testing.expectEqual(@as(usize, 1), C.nextCharBoundary(&doc, 0));
    try std_t.testing.expectEqual(@as(usize, 1 + family.len), C.nextCharBoundary(&doc, 1));
    try std_t.testing.expectEqual(@as(usize, doc.bytes.len), C.nextCharBoundary(&doc, 1 + family.len));

    // 旗帜整对回退
    try std_t.testing.expectEqual(@as(usize, 1 + family.len), C.prevCharBoundary(&doc, doc.bytes.len));
    // 家庭 emoji 整个回退
    try std_t.testing.expectEqual(@as(usize, 1), C.prevCharBoundary(&doc, 1 + family.len));
}

test "DocCursor 组合记号与肤色修饰符不被拆开" {
    const C = DocCursor(StubDoc);
    const doc = StubDoc{ .bytes = "e\u{0301}\u{1F44D}\u{1F3FB}" };
    try std_t.testing.expectEqual(@as(usize, 3), C.nextCharBoundary(&doc, 0));
    try std_t.testing.expectEqual(@as(usize, 3), C.prevCharBoundary(&doc, doc.bytes.len));
    try std_t.testing.expectEqual(@as(usize, 0), C.prevCharBoundary(&doc, 3));
}

// ===== 2 字节脚本（希腊/西里尔/拉丁扩展）词导航回归 =====
//
// 历史 bug：nextWordBoundary/wordBoundsAt 只把 >= 0xE0（3/4 字节）当 multi-byte，
// 2 字节 lead（0xC2-0xDF）落进 ASCII 词路径后又被 `b >= 0x80` 立即 break,
// 光标原地不动（Alt+Right 失灵）、双击选词返回空范围。

test "DocCursor 词导航：希腊/西里尔词按整词跳，不原地卡住" {
    const C = DocCursor(StubDoc);
    const greek = "λόγος"; // 每字符 2 字节
    const cyr = "слово";
    const doc = StubDoc{ .bytes = greek ++ " " ++ cyr ++ " test" };

    // Alt+Right：整词 + 尾随分隔符
    try std_t.testing.expectEqual(@as(usize, greek.len + 1), C.nextWordBoundary(&doc, 0));
    try std_t.testing.expectEqual(
        @as(usize, greek.len + 1 + cyr.len + 1),
        C.nextWordBoundary(&doc, greek.len + 1),
    );

    // Alt+Left：从词尾回到词首
    try std_t.testing.expectEqual(@as(usize, 0), C.prevWordBoundary(&doc, greek.len));
    // 从 "test" 词首回退：越过空格回到西里尔词首
    try std_t.testing.expectEqual(
        @as(usize, greek.len + 1),
        C.prevWordBoundary(&doc, greek.len + 1 + cyr.len + 1),
    );

    // 双击选词：整词非空范围
    const bounds = C.wordBoundsAt(&doc, 2);
    try std_t.testing.expectEqual(@as(usize, 0), bounds.start);
    try std_t.testing.expectEqual(@as(usize, greek.len), bounds.end);
}

test "DocCursor 词导航：ASCII 与 2 字节字符混排聚成一个词，CJK 仍单字成词" {
    const C = DocCursor(StubDoc);
    // "naïve 中文x"：naïve 是 ASCII+2 字节混词；中/文 各自成词；x 独立
    const doc = StubDoc{ .bytes = "naïve 中文x" };
    const naive_len = "naïve".len; // 6

    try std_t.testing.expectEqual(@as(usize, naive_len + 1), C.nextWordBoundary(&doc, 0));
    // CJK：单字一跳
    try std_t.testing.expectEqual(@as(usize, naive_len + 1 + 3), C.nextWordBoundary(&doc, naive_len + 1));
    try std_t.testing.expectEqual(@as(usize, 0), C.prevWordBoundary(&doc, naive_len));

    const bounds = C.wordBoundsAt(&doc, 1);
    try std_t.testing.expectEqual(@as(usize, 0), bounds.start);
    try std_t.testing.expectEqual(@as(usize, naive_len), bounds.end);
}

test "DocCursor subword 导航：2 字节字符不落在字符中间" {
    const C = DocCursor(StubDoc);
    const doc = StubDoc{ .bytes = "λω x" };
    // 旧实现：p += 1 落在 λ 的 continuation byte 上
    const n1 = C.nextSubwordBoundary(&doc, 0);
    try std_t.testing.expect(n1 == 2 or n1 == 4 or n1 == 5); // 任一合法字符边界
    try std_t.testing.expect(n1 != 1 and n1 != 3); // 不得是字符中间
    try std_t.testing.expect(n1 > 0); // 不得原地踏步
}

test "DocCursor 词导航：ZWJ 家庭 emoji 整簇一跳" {
    const C = DocCursor(StubDoc);
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const doc = StubDoc{ .bytes = family ++ "ab" };
    // 旧实现手算 char_len=4 只跳一个 codepoint，落在 ZWJ 序列中间
    try std_t.testing.expectEqual(@as(usize, family.len), C.nextWordBoundary(&doc, 0));
}

test "DocCursor 双击文末 CJK/emoji 始终返回完整 UTF-8 边界" {
    const C = DocCursor(StubDoc);
    const cjk = "你";
    const thumbs = "\u{1F44D}";
    const doc = StubDoc{ .bytes = "a" ++ cjk ++ thumbs };

    // CJK continuation byte 上的命中也归一化到字符开头。
    const cjk_bounds = C.wordBoundsAt(&doc, 2);
    try std_t.testing.expectEqual(@as(usize, 1), cjk_bounds.start);
    try std_t.testing.expectEqual(@as(usize, 1 + cjk.len), cjk_bounds.end);

    // EOF 位于四字节 emoji 之后；旧实现从 total - 1（续字节）开始选择。
    const eof_bounds = C.wordBoundsAt(&doc, doc.bytes.len);
    try std_t.testing.expectEqual(@as(usize, 1 + cjk.len), eof_bounds.start);
    try std_t.testing.expectEqual(@as(usize, doc.bytes.len), eof_bounds.end);

    // emoji 内部任意续字节同样不得成为选区边界。
    const emoji_bounds = C.wordBoundsAt(&doc, 1 + cjk.len + 2);
    try std_t.testing.expectEqual(eof_bounds.start, emoji_bounds.start);
    try std_t.testing.expectEqual(eof_bounds.end, emoji_bounds.end);
}

test "cursor floors every interior grapheme byte and preserves exact boundaries" {
    const chunks = [_][]const u8{ "a", "😀", "e\u{301}", "👨‍👩‍👧‍👦", "🇯🇵", "👍🏽", "\r\n", "z" };
    const bytes = "a😀e\u{301}👨‍👩‍👧‍👦🇯🇵👍🏽\r\nz";
    const doc = StubDoc{ .bytes = bytes };
    const C = DocCursor(StubDoc);
    var start: usize = 0;
    for (chunks) |chunk| {
        for (0..chunk.len) |inside| {
            try std_t.testing.expectEqual(start, C.floorCharBoundary(&doc, start + inside));
        }
        start += chunk.len;
    }
    try std_t.testing.expectEqual(bytes.len, C.floorCharBoundary(&doc, bytes.len));
    try std_t.testing.expectEqual(bytes.len, C.floorCharBoundary(&doc, std_t.math.maxInt(usize)));
}
