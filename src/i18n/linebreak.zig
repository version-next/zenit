//! Line breaking, UAX #14 简化版
//!
//! 用 UAX #14 line-break-class 体系做断行判定（取代旧的 ASCII 标点 +
//! "isCJK 之后允许断" hack）。
//!
//! 实现范围：
//! - codepoint -> line-break class（覆盖最常见 18 类）
//! - canBreakBetween(prev, next)：极简 pair 表
//! - findBreakOpportunities(text, out)：返回所有 byte-position 处可断点
//!
//! 不实现（Phase 5 暂不需要）：
//! - emoji ZWJ sequence break 抑制
//! - 完整 LB 规则（30+ 条）
//! - 区域语言定制（Thai/Lao 词典断行需要 ICU）
//!
//! 后续可补全。当前最小目标：让 CJK / 拉丁 / 阿拉伯 文本能在合理位置断行
//! 而不是 ASCII-only 模式。

const std = @import("std");
const testing = std.testing;

/// Line break class（UAX #14）
pub const LineBreakClass = enum(u8) {
    /// Mandatory break (\n, U+2028 等)
    bk,
    /// Carriage return
    cr,
    /// Line feed
    lf,
    /// Combining mark (跟前面字符走)
    cm,
    /// Zero width joiner（emoji/script 黏合）
    zwj,
    /// Word joiner / non-breaking
    wj,
    /// Glue / no-break ' '（NBSP）
    gl,
    /// Space
    sp,
    /// Break after (但 SP 之后也可)
    ba,
    /// Break before
    bb,
    /// Break opportunity ambiguous
    al,
    /// Numeric
    nu,
    /// Symbols allowing break before / after
    sy,
    /// CJK ideograph (default break around)
    id,
    /// Hyphen
    hy,
    /// In-separable (chains, \t)
    in,
    /// Quotation
    qu,
    /// Open punctuation (
    op,
    /// Close punctuation )
    cl,
    /// Closing parenthesis
    cp,
    /// Exclamation/interrogation ! ?
    ex,
    /// Other (unclassified)
    xx,
    /// Infix separator (. , ; :), UAX #14 IS
    is,
};

pub fn classify(cp: u32) LineBreakClass {
    if (cp < 0x80) return classify_ascii(@intCast(cp));

    // Hangul (CJK-like break)
    if (cp >= 0xAC00 and cp <= 0xD7A3) return .id;
    if (cp >= 0x3041 and cp <= 0x309F) return .id; // Hiragana
    if (cp >= 0x30A0 and cp <= 0x30FF) return .id; // Katakana
    if (cp >= 0x3400 and cp <= 0x4DBF) return .id; // CJK Ext A
    if (cp >= 0x4E00 and cp <= 0x9FFF) return .id; // CJK Unified
    if (cp >= 0xF900 and cp <= 0xFAFF) return .id; // CJK Compat
    if (cp >= 0x20000 and cp <= 0x2FFFF) return .id; // CJK Ext B-F

    // Mandatory breaks
    if (cp == 0x2028) return .bk; // LINE SEPARATOR
    if (cp == 0x2029) return .bk; // PARAGRAPH SEPARATOR

    // Common joiners / no-break
    if (cp == 0x00A0) return .gl; // NBSP
    if (cp == 0x200D) return .zwj;
    if (cp == 0x2060) return .wj;

    // Zero-width
    if (cp == 0x200B) return .ba; // ZWSP -> 可断

    // Hyphens
    if (cp == 0x2010 or cp == 0x2011 or cp == 0x2012 or cp == 0x2013 or cp == 0x2014) return .hy;

    // Default：可中断的字母数字（Latin Extended、Cyrillic、Greek 等都视作 AL）
    return .al;
}

fn classify_ascii(c: u8) LineBreakClass {
    return switch (c) {
        '\n' => .lf,
        '\r' => .cr,
        '\t' => .ba, // 当前简化为 break-after；真实是 BA
        ' ' => .sp,
        '0'...'9' => .nu,
        'A'...'Z', 'a'...'z' => .al,
        '-' => .hy,
        '/' => .sy,
        '(', '[', '{' => .op,
        ')', ']', '}' => .cl,
        '"', '\'' => .qu,
        '!', '?' => .ex,
        ',', '.', ';', ':' => .is,
        else => .xx,
    };
}

/// 判断是否为 CJK 字符（中日韩统一表意文字范围，可在任意位置断行）。
/// 单一事实来源：ui/core/text_layout.isCJK 与 text_core/wrap_map 的
/// precise wrap 断点都走这里，保证编辑态 WrapMap 与渲染端折行一致。
pub fn isCJK(codepoint: u21) bool {
    return (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or // CJK 基本
        (codepoint >= 0x3400 and codepoint <= 0x4DBF) or // CJK 扩展 A
        (codepoint >= 0x20000 and codepoint <= 0x2A6DF) or // CJK 扩展 B
        (codepoint >= 0x2A700 and codepoint <= 0x2B73F) or // CJK 扩展 C
        (codepoint >= 0x2B740 and codepoint <= 0x2B81F) or // CJK 扩展 D
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or // CJK 兼容
        (codepoint >= 0x3000 and codepoint <= 0x303F) or // CJK 符号标点
        (codepoint >= 0xFF00 and codepoint <= 0xFFEF); // 全角字符
}

/// 极简 pair table：判定 prev - next 之间是否允许断行。
/// 返回 true 表示可在 prev 之后断（即 next 开始处是断点）。
///
/// 规则（UAX #14 子集，按重要性排序）：
/// 1. \n / \r / BK 后必断（其实是 mandatory）
/// 2. SP 之后 + 非 CL/CP/IS 等 -> 可断
/// 3. WJ / GL / ZWJ / NBSP 周围不断
/// 4. AL/NU 之间不断（同质连续不断）
/// 5. ID（CJK）每个字符前后都可断（除非紧跟标点）
/// 6. HY 之后可断
/// 7. 默认：拉丁文 AL 与 ID 之间可断
pub fn canBreakBetween(prev: LineBreakClass, next: LineBreakClass) bool {
    // No-break around joiners
    if (prev == .wj or next == .wj) return false;
    if (prev == .gl or next == .gl) return false;
    if (prev == .zwj) return false;

    // Mandatory after BK / LF / CR
    if (prev == .bk or prev == .lf) return true;
    if (prev == .cr and next != .lf) return true;
    if (prev == .cr and next == .lf) return false;

    // SP-NEXT：通常可断（SP 之后任何非 close-punctuation）
    if (prev == .sp) {
        if (next == .cl or next == .cp or next == .ex or next == .is) return false;
        return true;
    }

    // 不在 break-before 之前断（break-before 类是行首类，不应在它前断）
    if (next == .cm) return false;

    // ID（CJK）允许其前后断（除 close 标点紧跟）
    if (prev == .id) {
        return switch (next) {
            .cl, .cp, .ex, .is, .sy, .hy => false,
            else => true,
        };
    }
    if (next == .id) {
        // ID 前可断除非 prev 是 open 标点
        return switch (prev) {
            .op, .qu => false,
            else => true,
        };
    }

    // HY 之后可断
    if (prev == .hy) return true;

    // BA（break-after）之后可断
    if (prev == .ba) return true;

    // BB（break-before）之前可断
    if (next == .bb) return true;

    // Numeric 间不断
    if (prev == .nu and next == .nu) return false;
    if (prev == .al and next == .al) return false;
    if (prev == .nu and next == .al) return false;
    if (prev == .al and next == .nu) return false;

    // Default: 不断
    return false;
}

/// 在 text 中找出所有 break opportunity（byte position，相对 text 起点）。
/// 返回所有"可在此 byte 位置之后开始新行"的 position。
pub fn findBreakOpportunities(
    text: []const u8,
    out: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
) !void {
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iter = view.iterator();

    var prev_class: ?LineBreakClass = null;
    var byte_pos: u32 = 0;

    while (iter.nextCodepoint()) |cp| {
        const cls = classify(cp);
        const seq_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;

        if (prev_class) |pc| {
            if (canBreakBetween(pc, cls)) {
                try out.append(allocator, byte_pos);
            }
        }

        byte_pos += seq_len;
        prev_class = cls;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "classify: ASCII space + letter" {
    try testing.expectEqual(LineBreakClass.sp, classify(' '));
    try testing.expectEqual(LineBreakClass.al, classify('a'));
    try testing.expectEqual(LineBreakClass.nu, classify('5'));
}

test "classify: CJK is ID" {
    try testing.expectEqual(LineBreakClass.id, classify(0x4E2D)); // 中
    try testing.expectEqual(LineBreakClass.id, classify(0x6587)); // 文
    try testing.expectEqual(LineBreakClass.id, classify(0x3042)); // あ Hiragana
}

test "classify: hyphen" {
    try testing.expectEqual(LineBreakClass.hy, classify('-'));
    try testing.expectEqual(LineBreakClass.hy, classify(0x2010));
}

test "classify: NBSP is GL (no-break)" {
    try testing.expectEqual(LineBreakClass.gl, classify(0x00A0));
}

test "canBreakBetween: SP + AL = break" {
    try testing.expect(canBreakBetween(.sp, .al));
}

test "canBreakBetween: AL + AL = no break" {
    try testing.expect(!canBreakBetween(.al, .al));
}

test "canBreakBetween: NBSP doesn't allow break" {
    try testing.expect(!canBreakBetween(.gl, .al));
    try testing.expect(!canBreakBetween(.al, .gl));
}

test "canBreakBetween: ID surrounded by AL allows break" {
    try testing.expect(canBreakBetween(.id, .al));
    try testing.expect(canBreakBetween(.al, .id));
    try testing.expect(canBreakBetween(.id, .id));
}

test "canBreakBetween: ID + close punctuation = no break" {
    try testing.expect(!canBreakBetween(.id, .cl));
    try testing.expect(!canBreakBetween(.id, .ex));
}

test "canBreakBetween: HY allows break after" {
    try testing.expect(canBreakBetween(.hy, .al));
}

test "findBreakOpportunities: simple ASCII spaces" {
    var out: std.ArrayListUnmanaged(u32) = .{};
    defer out.deinit(testing.allocator);

    try findBreakOpportunities("hello world foo", &out, testing.allocator);
    // 期望在 "hello " 后（byte 6）和 "world " 后（byte 12）有 break
    try testing.expect(out.items.len >= 2);
    try testing.expectEqual(@as(u32, 6), out.items[0]);
    try testing.expectEqual(@as(u32, 12), out.items[1]);
}

test "findBreakOpportunities: CJK every char is breakable" {
    var out: std.ArrayListUnmanaged(u32) = .{};
    defer out.deinit(testing.allocator);

    // "中文" = 6 bytes (UTF-8 各 3 字节)
    try findBreakOpportunities("\xE4\xB8\xAD\xE6\x96\x87", &out, testing.allocator);
    // 中 ↔ 文 之间应有 break
    try testing.expect(out.items.len >= 1);
    try testing.expectEqual(@as(u32, 3), out.items[0]);
}

test "findBreakOpportunities: NBSP suppresses break" {
    var out: std.ArrayListUnmanaged(u32) = .{};
    defer out.deinit(testing.allocator);

    // "a" + NBSP + "b"，NBSP 是 0xC2 0xA0
    try findBreakOpportunities("a\xC2\xA0b", &out, testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
