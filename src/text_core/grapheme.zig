//! Grapheme cluster 边界，Unicode 17.0.0 UAX #29 extended grapheme clusters
//!
//! 为什么需要：光标移动 / 退格 / 选区若按 codepoint 走，用户会看到
//! "退格 7 次才删掉一个家庭 emoji"、"光标停在 e 和组合音符之间"、
//! "旗帜被拆成两个方块"、"肤色修饰符被单独删掉"，这些都是把
//! 「一个用户感知字符」（extended grapheme cluster）当成多个字符处理的后果。
//!
//! ## 实现的规则（UAX #29, Table 1c "Extended grapheme cluster boundary rules"）
//! - GB1  / GB2   : 文本首尾一定是边界
//! - GB3          : CR × LF（CRLF 不可拆）
//! - GB4  / GB5   : Control|CR|LF 前后一定断开
//! - GB6/7/8      : Hangul 音节序列 L/V/T/LV/LVT 组合不断
//! - GB9          : × (Extend | ZWJ)，组合记号、变体选择符、肤色修饰符
//! - GB9a         : × SpacingMark，印度语系间距组合记号
//! - GB9b         : Prepend ×
//! - GB11         : Extended_Pictographic Extend* ZWJ × Extended_Pictographic
//!                  （ZWJ emoji 序列，如 👨‍👩‍👧‍👦）
//! - GB12 / GB13  : Regional_Indicator 成对（旗帜），偶数个才断
//! - GB999        : 其余一律断开
//!
//! Grapheme_Cluster_Break, Extended_Pictographic, and Indic_Conjunct_Break
//! come from the vendored Unicode 17.0.0 data files. The full official
//! GraphemeBreakTest corpus is executed as part of `test-text-core`.
//!
//! ## API
//! 两套适配器，规则引擎共用：
//! - `nextBoundary(text, pos)` / `prevBoundary(text, pos)`，平坦 []const u8
//! - `nextBoundaryDoc(Doc, doc, pos)` / `prevBoundaryDoc(...)`，任何提供
//!   `getByteAt(usize) ?u8` + `totalLength() usize` 的文档（PieceTree 等）

const std = @import("std");
const testing = std.testing;
const unicode_data = @import("grapheme_data_generated.zig");

// ===== Grapheme_Cluster_Break 属性 =====

pub const Prop = enum(u8) {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
    /// Extend 且同时是 Extended_Pictographic 的没有；这里表示 ExtPict 基字符
    ext_pict,
};

/// codepoint -> Grapheme_Cluster_Break 属性
pub fn propOf(cp: u21) Prop {
    const gcb = gcbProp(cp);
    return if (gcb == .other and unicode_data.isExtendedPictographic(cp)) .ext_pict else gcb;
}

fn gcbProp(cp: u21) Prop {
    return switch (unicode_data.gcb(cp)) {
        inline else => |value| @field(Prop, @tagName(value)),
    };
}

const Class = struct {
    gcb: Prop,
    extended_pictographic: bool,
    incb: unicode_data.InCB,
};

fn classOf(cp: u21) Class {
    return .{
        .gcb = gcbProp(cp),
        .extended_pictographic = unicode_data.isExtendedPictographic(cp),
        .incb = unicode_data.incb(cp),
    };
}

/// GB11 需要的左侧上下文：前面是否为 `ExtPict Extend*`
/// GB12/13 需要的左侧上下文：连续 RI 的奇偶
pub const State = struct {
    /// 上一个 cluster 起点之后连续 RI 的个数（用于 GB12/13）
    ri_odd: bool = false,
    /// 左侧匹配 `ExtPict Extend*`（用于 GB11）
    ext_pict_seq: bool = false,
    /// 左侧匹配 InCB=Consonant (Extend|Linker)* 且已经包含 Linker（GB9c）。
    incb_consonant_seq: bool = false,
    incb_linker_seen: bool = false,
};

/// 判定 prev(属性=a) 与 next(属性=b) 之间是否为 grapheme cluster 边界。
/// `st` 携带跨 codepoint 的上下文，调用者需要按扫描顺序维护（见 advance）。
pub fn isBoundary(a: Prop, b: Prop, st: State) bool {
    return isBoundaryClass(
        .{ .gcb = if (a == .ext_pict) .other else a, .extended_pictographic = a == .ext_pict, .incb = .none },
        .{ .gcb = if (b == .ext_pict) .other else b, .extended_pictographic = b == .ext_pict, .incb = .none },
        st,
    );
}

fn isBoundaryClass(a: Class, b: Class, st: State) bool {
    // GB3: CR × LF
    if (a.gcb == .cr and b.gcb == .lf) return false;
    // GB4: (Control|CR|LF) ÷
    if (a.gcb == .control or a.gcb == .cr or a.gcb == .lf) return true;
    // GB5: ÷ (Control|CR|LF)
    if (b.gcb == .control or b.gcb == .cr or b.gcb == .lf) return true;
    // GB6/7/8: Hangul
    if (a.gcb == .l and (b.gcb == .l or b.gcb == .v or b.gcb == .lv or b.gcb == .lvt)) return false;
    if ((a.gcb == .lv or a.gcb == .v) and (b.gcb == .v or b.gcb == .t)) return false;
    if ((a.gcb == .lvt or a.gcb == .t) and b.gcb == .t) return false;
    // GB9: × (Extend | ZWJ)
    if (b.gcb == .extend or b.gcb == .zwj) return false;
    // GB9a: × SpacingMark
    if (b.gcb == .spacing_mark) return false;
    // GB9b: Prepend ×
    if (a.gcb == .prepend) return false;
    // GB9c: InCB=Consonant (Extend|Linker)* Linker (Extend|Linker)* × Consonant
    if (b.incb == .consonant and st.incb_consonant_seq and st.incb_linker_seen) return false;
    // GB11: ExtPict Extend* ZWJ × ExtPict
    if (a.gcb == .zwj and b.extended_pictographic and st.ext_pict_seq) return false;
    // GB12/GB13: RI RI（成对）
    if (a.gcb == .regional_indicator and b.gcb == .regional_indicator and st.ri_odd) return false;
    // GB999
    return true;
}

/// 把 state 推进到「已消费 prop 为 p 的 codepoint」之后。
/// `broke_before` = 该 codepoint 之前是否刚发生了 cluster 边界。
pub fn advance(st: State, p: Prop, broke_before: bool) State {
    return advanceClass(st, .{
        .gcb = if (p == .ext_pict) .other else p,
        .extended_pictographic = p == .ext_pict,
        .incb = .none,
    }, broke_before);
}

fn advanceClass(st: State, p: Class, broke_before: bool) State {
    var out = st;
    // RI 计数：边界处重置
    if (p.gcb == .regional_indicator) {
        out.ri_odd = if (broke_before) true else !st.ri_odd;
    } else {
        out.ri_odd = false;
    }
    // GB11 左上下文：ExtPict 开启；Extend / ZWJ 保持；其余清空
    if (p.extended_pictographic) {
        out.ext_pict_seq = true;
    } else switch (p.gcb) {
        .extend, .zwj => {},
        else => out.ext_pict_seq = false,
    }
    switch (p.incb) {
        .consonant => {
            out.incb_consonant_seq = true;
            out.incb_linker_seen = false;
        },
        .extend => if (!out.incb_consonant_seq) {
            out.incb_linker_seen = false;
        },
        .linker => if (out.incb_consonant_seq) {
            out.incb_linker_seen = true;
        } else {
            out.incb_linker_seen = false;
        },
        .none => {
            out.incb_consonant_seq = false;
            out.incb_linker_seen = false;
        },
    }
    return out;
}

// ===== 字节层适配 =====

/// 任何提供 getByteAt / totalLength 的只读文档
pub fn ByteReader(comptime Doc: type) type {
    return struct {
        pub fn byteAt(doc: *const Doc, i: usize) ?u8 {
            return doc.getByteAt(i);
        }
        pub fn len(doc: *const Doc) usize {
            return doc.totalLength();
        }
    };
}

const SliceReader = struct {
    pub fn byteAt(doc: *const []const u8, i: usize) ?u8 {
        if (i >= doc.len) return null;
        return doc.*[i];
    }
    pub fn len(doc: *const []const u8) usize {
        return doc.len;
    }
};

fn utf8SeqLen(b: u8) usize {
    return if (b < 0x80) 1 else if (b < 0xC0) 1 // 孤立 continuation：当成单字节容错
    else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
}

/// 通用引擎：泛型在 (Doc, R) 上，R 提供 byteAt/len。
fn Engine(comptime Doc: type, comptime R: type) type {
    return struct {
        /// 解码 offset 处的 codepoint，返回 {cp, 字节长度}。非法字节按 U+FFFD 单字节处理。
        fn decodeAt(doc: *const Doc, offset: usize) struct { cp: u21, size: usize } {
            const total = R.len(doc);
            const b0 = R.byteAt(doc, offset) orelse return .{ .cp = 0xFFFD, .size = 1 };
            const n = utf8SeqLen(b0);
            if (n == 1 or offset + n > total) {
                return .{ .cp = if (b0 < 0x80) b0 else 0xFFFD, .size = 1 };
            }
            var buf: [4]u8 = undefined;
            buf[0] = b0;
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const b = R.byteAt(doc, offset + i) orelse return .{ .cp = 0xFFFD, .size = 1 };
                if ((b & 0xC0) != 0x80) return .{ .cp = 0xFFFD, .size = 1 };
                buf[i] = b;
            }
            const cp = std.unicode.utf8Decode(buf[0..n]) catch return .{ .cp = 0xFFFD, .size = 1 };
            return .{ .cp = cp, .size = n };
        }

        /// 前一个 codepoint 起点（纯 UTF-8 回溯）
        fn prevCpStart(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            var i = offset - 1;
            var steps: usize = 0;
            while (i > 0 and steps < 3) : (steps += 1) {
                const b = R.byteAt(doc, i) orelse return offset - 1;
                if ((b & 0xC0) != 0x80) return i;
                i -= 1;
            }
            const b = R.byteAt(doc, i) orelse return offset - 1;
            if ((b & 0xC0) == 0x80) return offset - 1; // 越界的 continuation 串：容错
            return i;
        }

        /// 从文本开头扫到 offset，得到 offset 处的 State + 前一个 codepoint 属性。
        /// 为避免 O(n)，只回溯到最近一个"安全起点"（见下）。
        fn contextAt(doc: *const Doc, offset: usize) struct { prev: ?Class, st: State } {
            if (offset == 0) return .{ .prev = null, .st = .{} };
            // 安全起点：回溯到不参与 RI、GB9c、GB11 或 Prepend 序列的字符。
            // 不能设置固定窗口：UAX #29 允许这些序列任意长，截断会改变 RI 奇偶性。
            var start = offset;
            while (start > 0) {
                const s = prevCpStart(doc, start);
                const d = decodeAt(doc, s);
                const p = classOf(d.cp);
                start = s;
                // other/control/cr/lf/spacing_mark 之前一定是边界，可安全作为扫描起点
                if ((p.gcb == .other and p.incb == .none and !p.extended_pictographic) or
                    p.gcb == .control or p.gcb == .cr or p.gcb == .lf) break;
            }
            var st = State{};
            var prev_prop: ?Class = null;
            var i = start;
            while (i < offset) {
                const d = decodeAt(doc, i);
                const p = classOf(d.cp);
                const broke = if (prev_prop) |pp| isBoundaryClass(pp, p, st) else true;
                st = advanceClass(st, p, broke);
                prev_prop = p;
                i += d.size;
            }
            return .{ .prev = prev_prop, .st = st };
        }

        pub fn next(doc: *const Doc, offset: usize) usize {
            const total = R.len(doc);
            if (offset >= total) return total;
            var ctx = contextAt(doc, offset);
            var i = offset;
            // 消费第一个 codepoint
            {
                const d = decodeAt(doc, i);
                const p = classOf(d.cp);
                const broke = if (ctx.prev) |pp| isBoundaryClass(pp, p, ctx.st) else true;
                ctx.st = advanceClass(ctx.st, p, broke);
                ctx.prev = p;
                i += d.size;
            }
            while (i < total) {
                const d = decodeAt(doc, i);
                const p = classOf(d.cp);
                if (isBoundaryClass(ctx.prev.?, p, ctx.st)) break;
                ctx.st = advanceClass(ctx.st, p, false);
                ctx.prev = p;
                i += d.size;
            }
            return @min(i, total);
        }

        pub fn prev(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            // 从 offset 往回逐 codepoint 退，取第一个真正的 cluster 边界。
            var cand = prevCpStart(doc, offset);
            while (true) {
                if (cand == 0) return 0;
                if (isBoundaryAt(doc, cand)) return cand;
                cand = prevCpStart(doc, cand);
            }
        }

        /// offset 是否落在 cluster 边界上
        pub fn isBoundaryAt(doc: *const Doc, offset: usize) bool {
            if (offset == 0 or offset >= R.len(doc)) return true;
            const ctx = contextAt(doc, offset);
            const prev_p = ctx.prev orelse return true;
            const d = decodeAt(doc, offset);
            return isBoundaryClass(prev_p, classOf(d.cp), ctx.st);
        }
    };
}

const SliceEngine = Engine([]const u8, SliceReader);

/// 下一个 grapheme cluster 边界（[]const u8）
pub fn nextBoundary(text: []const u8, pos: usize) usize {
    return SliceEngine.next(&text, pos);
}

/// Stateful grapheme-boundary scanner for callers that walk a slice from left
/// to right.  Unlike repeated `nextBoundary` calls, this retains the UAX #29
/// context across clusters, so arbitrarily long RI / InCB / GB11 sequences are
/// processed in linear time.  A repeated or backwards position is supported;
/// the latter rebuilds context with the regular random-access path.
pub const BoundaryCursor = struct {
    text: []const u8,
    start: usize = 0,
    end: usize = 0,
    next_prev: ?Class = null,
    next_state: State = .{},
    initialized: bool = false,

    pub fn init(text: []const u8) BoundaryCursor {
        return .{ .text = text };
    }

    pub fn next(self: *BoundaryCursor, pos: usize) usize {
        const bounded_pos = @min(pos, self.text.len);
        if (self.initialized and bounded_pos == self.start) return self.end;
        if (bounded_pos >= self.text.len) {
            self.start = self.text.len;
            self.end = self.text.len;
            self.initialized = true;
            return self.text.len;
        }

        var previous: ?Class = undefined;
        var state: State = undefined;
        if (self.initialized and bounded_pos == self.end) {
            previous = self.next_prev;
            state = self.next_state;
        } else {
            const context = SliceEngine.contextAt(&self.text, bounded_pos);
            previous = context.prev;
            state = context.st;
        }
        var i = bounded_pos;

        const first = SliceEngine.decodeAt(&self.text, i);
        const first_class = classOf(first.cp);
        const broke = if (previous) |previous_class|
            isBoundaryClass(previous_class, first_class, state)
        else
            true;
        state = advanceClass(state, first_class, broke);
        previous = first_class;
        i += first.size;

        while (i < self.text.len) {
            const decoded = SliceEngine.decodeAt(&self.text, i);
            const next_class = classOf(decoded.cp);
            if (isBoundaryClass(previous.?, next_class, state)) break;
            state = advanceClass(state, next_class, false);
            previous = next_class;
            i += decoded.size;
        }

        self.start = bounded_pos;
        self.end = @min(i, self.text.len);
        self.next_prev = previous;
        self.next_state = state;
        self.initialized = true;
        return self.end;
    }
};

/// 上一个 grapheme cluster 边界（[]const u8）
pub fn prevBoundary(text: []const u8, pos: usize) usize {
    return SliceEngine.prev(&text, pos);
}

/// 下一个 grapheme cluster 边界（文档适配）
pub fn nextBoundaryDoc(comptime Doc: type, doc: *const Doc, pos: usize) usize {
    return Engine(Doc, ByteReader(Doc)).next(doc, pos);
}

/// 上一个 grapheme cluster 边界（文档适配）
pub fn prevBoundaryDoc(comptime Doc: type, doc: *const Doc, pos: usize) usize {
    return Engine(Doc, ByteReader(Doc)).prev(doc, pos);
}

/// 统计 text 中 grapheme cluster 个数（测试/度量用）
pub fn count(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    var cursor = BoundaryCursor.init(text);
    while (i < text.len) {
        i = cursor.next(i);
        n += 1;
    }
    return n;
}

// ===== 测试 =====

const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"; // 👨‍👩‍👧‍👦
const flag_cn = "\u{1F1E8}\u{1F1F3}"; // 🇨🇳
const thumbs_tone = "\u{1F44D}\u{1F3FB}"; // 👍🏻
const e_acute = "e\u{0301}";

test "Unicode 17.0.0 GraphemeBreakTest conformance" {
    const corpus = @embedFile("testdata/GraphemeBreakTest-17.0.0.txt");
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var line_number: usize = 0;
    var case_count: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const body = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        if (body.len == 0) continue;

        var text_buf: [4096]u8 = undefined;
        var text_len: usize = 0;
        var expected_buf: [512]usize = undefined;
        var expected_len: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, body, " \t");
        const initial = tokens.next() orelse continue;
        try testing.expectEqualStrings("÷", initial);
        expected_buf[expected_len] = 0;
        expected_len += 1;
        while (tokens.next()) |cp_token| {
            const cp_value = try std.fmt.parseInt(u21, cp_token, 16);
            var encoded: [4]u8 = undefined;
            const encoded_len = try std.unicode.utf8Encode(cp_value, &encoded);
            @memcpy(text_buf[text_len..][0..encoded_len], encoded[0..encoded_len]);
            text_len += encoded_len;
            const marker = tokens.next() orelse return error.MalformedGraphemeBreakTest;
            if (std.mem.eql(u8, marker, "÷")) {
                expected_buf[expected_len] = text_len;
                expected_len += 1;
            } else try testing.expectEqualStrings("×", marker);
        }

        var actual_buf: [512]usize = undefined;
        var actual_len: usize = 1;
        actual_buf[0] = 0;
        var cursor = BoundaryCursor.init(text_buf[0..text_len]);
        while (actual_buf[actual_len - 1] < text_len) {
            const previous = actual_buf[actual_len - 1];
            actual_buf[actual_len] = nextBoundary(text_buf[0..text_len], previous);
            try testing.expectEqual(actual_buf[actual_len], cursor.next(previous));
            actual_len += 1;
        }
        testing.expectEqualSlices(usize, expected_buf[0..expected_len], actual_buf[0..actual_len]) catch |err| {
            std.debug.print("Unicode grapheme conformance mismatch at GraphemeBreakTest.txt:{d}\n", .{line_number});
            return err;
        };
        case_count += 1;
    }
    try testing.expectEqual(@as(usize, 766), case_count);
}

test "BoundaryCursor matches random-access boundaries" {
    const samples = [_][]const u8{
        "plain ASCII text",
        e_acute ++ family ++ flag_cn ++ flag_cn ++ thumbs_tone ++ "क्षខ្ម",
        "\x80\x80A\xF0\x28\x8C\x28",
    };
    for (samples) |sample| {
        var cursor = BoundaryCursor.init(sample);
        var pos: usize = 0;
        while (pos < sample.len) {
            const expected = nextBoundary(sample, pos);
            try testing.expectEqual(expected, cursor.next(pos));
            // Retrying a cluster after a wrapping decision must be stable.
            try testing.expectEqual(expected, cursor.next(pos));
            pos = expected;
        }
    }
}

test "BoundaryCursor handles long regional-indicator runs" {
    const allocator = testing.allocator;
    const regional_indicator = "\u{1F1E6}";
    const pair_count = 4096;
    const text = try allocator.alloc(u8, regional_indicator.len * pair_count * 2);
    defer allocator.free(text);
    for (0..pair_count * 2) |i| {
        @memcpy(text[i * regional_indicator.len ..][0..regional_indicator.len], regional_indicator);
    }
    try testing.expectEqual(pair_count, count(text));
}

test "GB9c: Indic conjunct consonants stay in one cluster" {
    try testing.expectEqual(@as(usize, 1), count("क्ष"));
    try testing.expectEqual(@as(usize, 1), count("ខ្ម"));
}

test "GB12/13: RI parity remains exact beyond the old lookback window" {
    const regional_a = "🇦";
    var bytes: [4 * 130]u8 = undefined;
    for (0..130) |index| @memcpy(bytes[index * 4 ..][0..4], regional_a);
    try testing.expectEqual(@as(usize, 65), count(&bytes));
    try testing.expectEqual(@as(usize, 4 * 128), prevBoundary(&bytes, bytes.len));
}

test "GB11: ZWJ 家庭 emoji 是单个 cluster" {
    try testing.expectEqual(@as(usize, 25), family.len);
    try testing.expectEqual(@as(usize, 1), count(family));
    try testing.expectEqual(@as(usize, family.len), nextBoundary(family, 0));
    try testing.expectEqual(@as(usize, 0), prevBoundary(family, family.len));
}

test "GB9: 组合尖音符不与基字符分离" {
    try testing.expectEqual(@as(usize, 1), count(e_acute));
    try testing.expectEqual(@as(usize, 3), nextBoundary(e_acute, 0));
    try testing.expectEqual(@as(usize, 0), prevBoundary(e_acute, 3));
}

test "GB12/13: regional indicator 成对" {
    try testing.expectEqual(@as(usize, 1), count(flag_cn));
    try testing.expectEqual(@as(usize, 0), prevBoundary(flag_cn, flag_cn.len));
    // 两面旗 = 两个 cluster，不能贪心吃四个 RI
    const two = flag_cn ++ flag_cn;
    try testing.expectEqual(@as(usize, 2), count(two));
    try testing.expectEqual(@as(usize, 8), nextBoundary(two, 0));
    try testing.expectEqual(@as(usize, 8), prevBoundary(two, two.len));
}

test "肤色修饰符不被拆开" {
    try testing.expectEqual(@as(usize, 1), count(thumbs_tone));
    try testing.expectEqual(@as(usize, 0), prevBoundary(thumbs_tone, thumbs_tone.len));
}

test "GB3/GB4/GB5: CRLF 与 control" {
    try testing.expectEqual(@as(usize, 1), count("\r\n"));
    try testing.expectEqual(@as(usize, 2), count("\n\n"));
    try testing.expectEqual(@as(usize, 2), count("a\n"));
    // Extend 不能黏到 CR/LF 上
    try testing.expectEqual(@as(usize, 2), count("\n\u{0301}"));
}

test "GB6/7/8: Hangul 音节序列" {
    try testing.expectEqual(@as(usize, 1), count("\u{1100}\u{1161}\u{11A8}"));
}

test "ASCII 与混合文本仍按预期前后移动" {
    const s = "ab" ++ family ++ "c" ++ e_acute;
    try testing.expectEqual(@as(usize, 5), count(s));
    var i: usize = 0;
    i = nextBoundary(s, i);
    try testing.expectEqual(@as(usize, 1), i);
    i = nextBoundary(s, i);
    try testing.expectEqual(@as(usize, 2), i);
    i = nextBoundary(s, i);
    try testing.expectEqual(@as(usize, 2 + family.len), i);
    var back = s.len;
    var seen: usize = 0;
    while (back > 0) : (seen += 1) {
        back = prevBoundary(s, back);
    }
    try testing.expectEqual(@as(usize, 5), seen);
}

test "边界幂等：prev(next(x)) == x" {
    const s = "x" ++ flag_cn ++ thumbs_tone ++ e_acute ++ family;
    var i: usize = 0;
    while (i < s.len) {
        const n = nextBoundary(s, i);
        try testing.expect(n > i);
        try testing.expectEqual(i, prevBoundary(s, n));
        i = n;
    }
}
