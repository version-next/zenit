//! UTF-8 合法性判定 —— 仓库唯一一份。
//!
//! 此前同样的逻辑在仓库里有三份：
//!   - `ui/devtools/format.zig`：100 行手写状态机，判"整串是否合法"
//!   - `ui/console.zig` 的 `validUtf8PrefixLen`：判"最长合法前缀长度"
//!   - `ui/core/text_shaping.zig` 的 `validUtf8Prefix`：判"最长合法前缀切片"
//!
//! 三者看着语义不同，其实是同一个扫描的三种返回形态。手写那份还额外承担了
//! overlong / surrogate / >U+10FFFF 三类边界的维护责任 —— 穷举比对过（1~3
//! 字节全量、4 字节抽样），它和 std 零差异，也就是说那 100 行只是把 std
//! 重写了一遍，却要自己背边界正确性的锅。
//!
//! 统一成一个扫描 + 三个薄包装：规则只有一份，三种返回形态按调用点取用。

const std = @import("std");

/// 最长合法 UTF-8 前缀的字节长度，扫描至多 `limit` 字节。
///
/// 这是下面三个函数共同的内核：合法前缀长度一旦算出，"整串是否合法"就是
/// "前缀长度 == 总长"，"合法前缀切片"就是按这个长度切。
pub fn validPrefixLen(bytes: []const u8, limit: usize) usize {
    const end = @min(limit, bytes.len);
    var i: usize = 0;
    while (i < end) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
        if (i + n > end) return i;
        _ = std.unicode.utf8Decode(bytes[i..][0..n]) catch return i;
        i += n;
    }
    return i;
}

/// 整串是否是合法 UTF-8。
pub fn isValid(bytes: []const u8) bool {
    return validPrefixLen(bytes, bytes.len) == bytes.len;
}

/// 最长合法 UTF-8 前缀切片。
///
/// ⚠ 调用方按**字节**切前缀时可能落在多字节序列中间（半个 CJK/emoji）。
/// 非法 UTF-8 会让 CoreText 的 NSString 构造失败 —— shape 层报
/// TextShapingFailed，FontSelector 桥则**静默返回 0.0f**，最终宽度 0.00
/// 直接把 bbox 压塌（下游应用实测：emoji 之后切在 CJK 首字节的"前缀"全部量出
/// 0.00）。先裁到最长合法前缀，与渲染端实际能显示的内容一致；合法输入零
/// 开销原样通过。
pub fn validPrefix(bytes: []const u8) []const u8 {
    return bytes[0..validPrefixLen(bytes, bytes.len)];
}

/// 单个 UTF-8 序列的字节长度；首字节非法时返回 0。
///
/// 与 `std.unicode.utf8ByteSequenceLength` 的差别只是错误表达（0 而非
/// error），给按字节推进的截断循环用。
pub fn seqLen(first_byte: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first_byte) catch 0;
}

// ── 测试 ───────────────────────────────────────────────────────────────

test "isValid: 合法输入" {
    try std.testing.expect(isValid(""));
    try std.testing.expect(isValid("hello"));
    try std.testing.expect(isValid("中文"));
    try std.testing.expect(isValid("🎉"));
}

test "isValid: 截断序列与孤立 continuation" {
    try std.testing.expect(!isValid("\xE4\xB8")); // 3 字节序列只给了 2 字节
    try std.testing.expect(!isValid("\x80")); // 孤立 continuation
    try std.testing.expect(!isValid("\xFF"));
}

test "isValid: overlong / surrogate / 超出 U+10FFFF 都要拒绝" {
    // 这三类是手写实现最容易写漏的边界，锁死它们
    try std.testing.expect(!isValid("\xC0\x80")); // overlong NUL
    try std.testing.expect(!isValid("\xE0\x80\x80")); // overlong
    try std.testing.expect(!isValid("\xED\xA0\x80")); // UTF-16 surrogate D800
    try std.testing.expect(!isValid("\xF4\x90\x80\x80")); // > U+10FFFF
    try std.testing.expect(!isValid("\xF5\x80\x80\x80")); // 首字节越界
}

test "validPrefixLen: 切在多字节中间时退回序列起点" {
    const s = "ab中"; // 'a''b' + 3 字节
    try std.testing.expectEqual(@as(usize, 2), validPrefixLen(s, 3)); // 切在"中"中间
    try std.testing.expectEqual(@as(usize, 2), validPrefixLen(s, 4));
    try std.testing.expectEqual(@as(usize, 5), validPrefixLen(s, 5)); // 完整
}

test "validPrefixLen: limit 超过串长时按串长算" {
    try std.testing.expectEqual(@as(usize, 5), validPrefixLen("hello", 999));
}

test "validPrefix: 合法输入零拷贝原样返回" {
    const src = "中文";
    const out = validPrefix(src);
    try std.testing.expectEqualStrings(src, out);
    try std.testing.expect(out.ptr == src.ptr);
}

test "validPrefix: 非法尾部被裁掉" {
    try std.testing.expectEqualStrings("ab", validPrefix("ab\xE4\xB8"));
    try std.testing.expectEqualStrings("", validPrefix("\x80\x80"));
}

test "seqLen: 首字节非法返回 0（供截断循环推进用）" {
    try std.testing.expectEqual(@as(usize, 1), seqLen('a'));
    try std.testing.expectEqual(@as(usize, 3), seqLen(0xE4));
    try std.testing.expectEqual(@as(usize, 4), seqLen(0xF0));
    try std.testing.expectEqual(@as(usize, 0), seqLen(0x80)); // 孤立 continuation
    try std.testing.expectEqual(@as(usize, 0), seqLen(0xFF));
}
