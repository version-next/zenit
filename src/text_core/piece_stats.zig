//! 单遍文本统计扫描，从 `PieceTree` 析出。
//!
//! 原先是 piece_tree.zig 里 `PieceTree` 的私有嵌套函数 `scanTextStats`：输入一段
//! 字节，输出 newline_count + first/last/longest_row_chars（对齐 Zed
//! `TextSummary::from(str)`）。这些数字是 `PieceSummary` 做跨 piece 最长行合并的
//! 全部依据，错一个，编辑器的横向滚动宽度就跟着错。
//!
//! 它对 PieceTree / SumTree / allocator **零依赖**（`[]const u8` 进、四个标量出），
//! 却埋在两千多行的宿主文件里，只能跟着公共 API 间接测。接口因此切在：
//!
//!   **scan 只认字节，不认 piece / source / buffer。**
//!
//! 「统计怎么聚合成 Summary、怎么挂到 B-tree 上」仍是 piece_tree 的职责；
//! `TreePiece.fromText` 在构造 piece 时调用这里。
//!
//! 踩过的坑（搬动时原样保留；第一条按实测行为修正过，见下方测试）：
//!   - 「字符」= Unicode code point。推进量由 std.unicode.utf8ByteSequenceLength
//!     决定，它只认 0x00-0x7F(1) / 0xC0-0xDF(2) / 0xE0-0xEF(3) / 0xF0-0xF7(4)
//!     为合法 lead，其余（裸 continuation 0x80..0xBF、非法 lead 0xF8..0xFF）
//!     一律 catch 成 1。注意两点：0xC0/0xC1 是过长的 2 字节 lead，scan 不验
//!     continuation，会连带吞掉身后 1 个字节、整段只记 1 个字符；截断判断
//!     `i + cp_len <= text.len` 只看长度不看内容。无论走哪条路径 i 都必须
//!     前进，不能 panic 也不能死循环。
//!   - 行宽用 `+|=` 饱和累加：超长行不允许把 u32 溢出回 0。
//!   - first_line_chars 只在遇到第一个 '\n' 时定格；全文无 '\n' 时等于全长。
//!   - 已知怪癖（锁定现状，不修）：多字节 lead 之后紧跟 '\n' 且序列在缓冲区
//!     末尾方向被截断时，`i + cp_len <= text.len` 会把 '\n' 圈进序列长度，
//!     导致 advance 越过一个本应单独计数的换行符，该行行宽 +1、
//!     newline_count -1。只发生在「截断序列 + 紧贴 '\n'」的组合上；单靠
//!     `scan` 无法区分「序列被截断」和「序列合法但下一个字节恰好是 '\n'」，
//!     修复需要改变 advance 语义并连带修 PieceSummary 合并，超出本次
//!     「行为零变化」的边界。相关测试只断言自洽性，不硬编码怪癖算术。

const std = @import("std");

/// 一段文本的行统计（字段与 `PieceSummary` 的四个标量一一对应）。
pub const TextStats = struct {
    newline_count: usize,
    first_line_chars: u32,
    last_line_chars: u32,
    longest_row_chars: u32,
};

/// 单遍扫描：newline_count + first/last/longest_row_chars（O(n)，无分配）。
pub fn scan(text: []const u8) TextStats {
    var newline_count: usize = 0;
    var first_line_chars: u32 = 0;
    var current_line_chars: u32 = 0;
    var longest_row_chars: u32 = 0;
    var first_line_done = false;

    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '\n') {
            if (!first_line_done) {
                first_line_chars = current_line_chars;
                first_line_done = true;
            }
            if (current_line_chars > longest_row_chars) {
                longest_row_chars = current_line_chars;
            }
            current_line_chars = 0;
            newline_count += 1;
            i += 1;
        } else if (b < 0x80) {
            current_line_chars +|= 1;
            i += 1;
        } else {
            // UTF-8 多字节：算 1 个字符
            const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            const advance = if (i + cp_len <= text.len) cp_len else 1;
            current_line_chars +|= 1;
            i += advance;
        }
    }

    // 处理最后一行（没有 \n 结尾）
    if (!first_line_done) {
        first_line_chars = current_line_chars;
    }
    if (current_line_chars > longest_row_chars) {
        longest_row_chars = current_line_chars;
    }

    return .{
        .newline_count = newline_count,
        .first_line_chars = first_line_chars,
        .last_line_chars = current_line_chars,
        .longest_row_chars = longest_row_chars,
    };
}

// ── 测试 ───────────────────────────────────────────────────────────────
// 收集机制：text_core.zig 里 `pub const piece_stats = @import(...)` + 根文件的
// `test { refAllDecls }`。只有 `pub const X = @import(...)` 再导出**不会**让
// 这里的 test 被收集，必须被 refAllDecls 引用到（见 build.zig 里 font_catalog
// 的教训注释）。

test "scan: 空字符串全零" {
    const s = scan("");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.longest_row_chars);
}

test "scan: 单字符无换行" {
    const s = scan("x");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 1), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 1), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 1), s.longest_row_chars);
}

test "scan: 单个换行符是唯一的空行" {
    const s = scan("\n");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.longest_row_chars);
}

test "scan: 仅换行符" {
    const s = scan("\n\n\n");
    try std.testing.expectEqual(@as(usize, 3), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.longest_row_chars);
}

test "scan: 无结尾换行时 last_line 是末行" {
    const s = scan("abc\ndef");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 结尾换行后 last_line 归零" {
    const s = scan("abc\n");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 首字符即换行时 first_line 为零" {
    const s = scan("\nabc");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 最长行在中间" {
    const s = scan("ab\nabcdefgh\n cd\n");
    try std.testing.expectEqual(@as(usize, 3), s.newline_count);
    try std.testing.expectEqual(@as(u32, 2), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 8), s.longest_row_chars);
}

test "scan: 多字节 UTF-8 按码点计数" {
    const s = scan("h\u{00E9}llo\nw\u{00F6}rld\n");
    // h é l l o = 5 码点（é 是 2 字节）；w ö r l d 同理
    try std.testing.expectEqual(@as(usize, 2), s.newline_count);
    try std.testing.expectEqual(@as(u32, 5), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 5), s.longest_row_chars);
}

test "scan: 3/4 字节码点各算一个字符" {
    const s = scan("你\n\u{1F600}z");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 1), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.longest_row_chars);
}

test "scan: 缓冲区末尾截断的多字节序列按单字节推进" {
    // "abc你" 砍掉最后一个字节：0xE4 后只剩 0xBD 且后面再无字节，
    // i+3>len ⇒ 走 advance=1 的防御分支（不能越界也不能死循环）
    const s = scan("abc\u{4F60}"[0..5]);
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 5), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 5), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 5), s.longest_row_chars);
}

test "scan: 非法 lead / 裸 continuation 不死循环（逐字节推演真实口径）" {
    // 字节序列长度 ≠ 字符数。推进量由 std.unicode.utf8ByteSequenceLength 决定：
    // 它只认 0x00-0x7F(1) / 0xC0-0xDF(2) / 0xE0-0xEF(3) / 0xF0-0xF7(4)，其余判非法。
    //
    // "\xff\xfe\xc0\x80\x8f" 逐字节推演：
    //   i=0 0xff  非法 lead              -> advance 1，记 1 字符
    //   i=1 0xfe  非法 lead              -> advance 1，记 1 字符
    //   i=2 0xc0  合法 2 字节 lead        -> 连 0x80 一起吞，advance 2，记 1 字符
    //   i=4 0x8f  裸 continuation（<0xC0，不是 lead）-> 非法，advance 1，记 1 字符
    // 合计 5 字节 -> **4** 个"字符"。
    //
    // 这是 scan 的真实口径，不是 bug：它不验证 continuation 的合法性，非法输入
    // 本就没有唯一正确答案。这条测试只要求「不 panic、不死循环、i 单调前进」，
    // 并把当前口径钉住以便将来改动时看见差异。
    const s = scan("\xff\xfe\xc0\x80\x8f");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 4), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 4), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 4), s.longest_row_chars);
}

test "scan: ≥0xF8 的非法 lead 才走「1 字节 = 1 字符」防御分支" {
    // 与上一条互补：0xF8..0xFF 是 utf8ByteSequenceLength 唯一判非法的区间，
    // 每个都退回 advance=1，逐字节各算一字符。
    const s = scan("\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 8), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 8), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 8), s.longest_row_chars);
}

test "scan: 孤立的 4 字节 lead 字节在末尾只前进 1" {
    const s = scan("ab\xf0");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: CR 计入行宽（CRLF 文件的行宽比视觉多 1，现状口径）" {
    const s = scan("ab\r\ncd\r\n");
    try std.testing.expectEqual(@as(usize, 2), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 超长单行不溢出 u32" {
    const alloc = std.testing.allocator;
    const n: usize = 200_000;
    const text = try alloc.alloc(u8, n);
    defer alloc.free(text);
    @memset(text, 'q');
    const s = scan(text);
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, @intCast(n)), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, @intCast(n)), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, @intCast(n)), s.longest_row_chars);
}

test "scan: 逐 token 构造的期望统计（构造即预言）" {
    // 用「字符数已知」的 token 拼缓冲：期望值在构造时累加，scan 必须只凭字节
    // 恢复出同样的统计。这是多字节 / 非法字节解码路径的独立 oracle，若把
    // 「é 算 2 个字符」这类 bug 写进 scan，这里会立刻红。
    // 注意 token 集刻意不含「多字节 lead + 紧贴 '\n'」的组合：那会触发模块头
    // 记录的已知怪癖（advance 吞 '\n'），oracle 无法表达。怪癖由下方的显式
    // 现状锁定测试覆盖。
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);

    var exp_lines: usize = 0;
    var exp_first: ?u32 = null;
    var exp_cur: u32 = 0;
    var exp_longest: u32 = 0;

    const Token = struct { text: []const u8, chars: u32, newlines: usize };
    const tokens = [_]Token{
        .{ .text = "a", .chars = 1, .newlines = 0 },
        .{ .text = "\u{4F60}", .chars = 1, .newlines = 0 },
        .{ .text = "\n", .chars = 0, .newlines = 1 },
        .{ .text = "\u{1F600}", .chars = 1, .newlines = 0 },
        .{ .text = "\xff", .chars = 1, .newlines = 0 },
        .{ .text = "bcd", .chars = 3, .newlines = 0 },
        .{ .text = "\n", .chars = 0, .newlines = 1 },
        .{ .text = "\xc0\xaf", .chars = 1, .newlines = 0 }, // 「/」的过长编码。0xC0 是**合法**的 2 字节 lead，
        // 所以 scan 把 \xaf 一起吞掉记 1 字符，它不验证 continuation 合法性。
        .{ .text = "\n", .chars = 0, .newlines = 1 },
        .{ .text = "\u{00E9}", .chars = 1, .newlines = 0 }, // é（2 字节）
    };

    var seed: u64 = 4242;
    const lcg = struct {
        fn next(s: *u64) u64 {
            s.* = s.* *% 6364136223846793005 +% 1442695040888963407;
            return s.* >> 33;
        }
    };

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const pick: u64 = lcg.next(&seed) % @as(u64, tokens.len);
        const tok = tokens[@as(usize, @intCast(pick))];
        try buf.appendSlice(alloc, tok.text);
        if (tok.newlines > 0) {
            if (exp_first == null) exp_first = exp_cur;
            if (exp_cur > exp_longest) exp_longest = exp_cur;
            exp_cur = 0;
            exp_lines += 1;
        } else {
            exp_cur +|= tok.chars;
        }
    }
    if (exp_first == null) exp_first = exp_cur;
    if (exp_cur > exp_longest) exp_longest = exp_cur;

    const got = scan(buf.items);
    try std.testing.expectEqual(exp_lines, got.newline_count);
    try std.testing.expectEqual(exp_first.?, got.first_line_chars);
    try std.testing.expectEqual(exp_cur, got.last_line_chars);
    try std.testing.expectEqual(exp_longest, got.longest_row_chars);
}

// 下面两条随代码从 piece_tree.zig 迁来（原 "PieceTree: scanTextStats *"），
// 再加一条对模块头记录的已知怪癖的现状锁定：advance 会吞掉紧贴在截断序列
// 后面的 '\n'。若将来修了这个怪癖，本条必须改期望值（并同步改 PieceSummary）。

test "scan: 现状锁定 —— 截断的多字节序列会吞掉紧随的换行符（已知怪癖）" {
    // "你"(E4 BD A0) + 截断尾(E4 BD) + '\n'  共 6 字节，逐字节推演：
    //   i=0 0xE4 声明 3 字节，i+3<=6 成立 -> advance 3，记 1 字符（完整的"你"）
    //   i=3 0xE4 声明 3 字节，i+3<=6 **也成立** -> advance 3，记 1 字符
    //       但这 3 字节是 BD 0A，把身后的 '\n' 一起吞了
    //   i=6 结束
    // 所以：2 个"字符"、**0 个换行**。那个 '\n' 没有被计数。
    //
    // 这是现状锁定测试，不是在断言"应该这样"：scan 只保证不 panic / 不死循环 /
    // i 单调前进，对截断的多字节序列没有定义良好的答案。钉住它是为了将来若
    // 改动推进逻辑（比如改成校验 continuation），这里会红，提醒你换行计数的
    // 口径变了，而换行计数是 PieceSummary 跨 piece 合并的依据。
    const s = scan("\u{4F60}\u{4F60}"[0..5] ++ "\n");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 2), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.longest_row_chars);
}

test "scan: 多行文本的基本统计" {
    const stats = scan("hello\nworld foo bar\nhi\n");
    try std.testing.expectEqual(@as(usize, 3), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 5), stats.first_line_chars); // "hello"
    try std.testing.expectEqual(@as(u32, 0), stats.last_line_chars); // "" after final \n
    try std.testing.expectEqual(@as(u32, 13), stats.longest_row_chars); // "world foo bar"
}

test "scan: 无换行文本" {
    const stats = scan("abcdef");
    try std.testing.expectEqual(@as(usize, 0), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 6), stats.first_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.last_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.longest_row_chars);
}
