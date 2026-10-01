//! DevTools 的格式化工具，从 devtools.zig 析出。
//!
//! 八个纯函数：把布局值（Sizing / Padding / Margin / f32）和可能非法的字节
//! 串格式化成面板上显示的短文本。只依赖 std 与 core 的值类型，不碰面板状态、
//! 选中项、节点树，夹在 4600 行的 devtools.zig 里纯属历史堆积。
//!
//! 析出后这些格式化规则可以直接单测：此前要验证「宽度为 fit 时显示什么」
//! 「截断时会不会切断多字节字符」只能打开 DevTools 面板用眼睛看。
//!
//! UTF-8 判定统一走 `text_core.utf8`（2026-09-22）：此前这里有一份 100 行
//! 手写的 UTF-8 状态机（utf8SeqLen / isValidUtf8Seq / isValidUtf8）。穷举
//! 比对过，1~3 字节全量、4 字节抽样，与 std 零差异，也就是说那 100 行只是
//! 把 std 重写了一遍，overlong / surrogate / >U+10FFFF 边界全靠手写维护。
//! 现已删除，语义不变。

const std = @import("std");
const core = @import("../core.zig");
const utf8 = @import("text_core").utf8;
const Sizing = core.Sizing;
const Padding = core.Padding;

// ========== 格式化工具 ==========

pub fn truncate(alloc: std.mem.Allocator, src: []const u8, max_len: usize) []const u8 {
    if (max_len == 0) return src[0..0];

    const needs_truncate = src.len > max_len;
    if (!needs_truncate and isValidUtf8(src)) return src;

    const payload_cap: usize = if (needs_truncate and max_len >= 3) max_len - 3 else max_len;
    const out = alloc.alloc(u8, max_len) catch return if (needs_truncate)
        src[0..@min(src.len, max_len)]
    else
        "<invalid utf8>";

    var in_i: usize = 0;
    var out_i: usize = 0;
    while (in_i < src.len and out_i < payload_cap) {
        const seq_len = utf8.seqLen(src[in_i]);
        if (seq_len == 0 or in_i + seq_len > src.len) {
            out[out_i] = '?';
            out_i += 1;
            in_i += 1;
            continue;
        }

        if (!utf8.isValid(src[in_i .. in_i + seq_len])) {
            out[out_i] = '?';
            out_i += 1;
            in_i += 1;
            continue;
        }

        if (out_i + seq_len > payload_cap) break;
        @memcpy(out[out_i .. out_i + seq_len], src[in_i .. in_i + seq_len]);
        out_i += seq_len;
        in_i += seq_len;
    }

    const was_trimmed = in_i < src.len;
    if (needs_truncate and max_len >= 3) {
        out[out_i] = '.';
        out[out_i + 1] = '.';
        out[out_i + 2] = '.';
        return out[0 .. out_i + 3];
    }
    if (was_trimmed and out_i == 0 and max_len > 0) {
        out[0] = '?';
        return out[0..1];
    }
    return out[0..out_i];
}

/// 整串是否是合法 UTF-8。转发给 text_core.utf8，保留本名以免调用点改动。
pub fn isValidUtf8(src: []const u8) bool {
    return utf8.isValid(src);
}

pub fn formatSizing(buf: *[20]u8, sizing: Sizing) []const u8 {
    return switch (sizing) {
        .px => |v| std.fmt.bufPrint(buf, "{d:.0}px", .{v}) catch "px",
        .grow => |mm| if (mm.min == 0 and mm.max == std.math.inf(f32))
            "grow"
        else
            std.fmt.bufPrint(buf, "grow({d:.0}..{d:.0})", .{ mm.min, mm.max }) catch "grow",
        .fit => |mm| if (mm.min == 0 and mm.max == std.math.inf(f32))
            "fit"
        else
            std.fmt.bufPrint(buf, "fit({d:.0}..{d:.0})", .{ mm.min, mm.max }) catch "fit",
        .percent => |p| std.fmt.bufPrint(buf, "{d:.0}%", .{p}) catch "%",
    };
}

pub fn fmtFloat(buf: *[12]u8, val: f32) []const u8 {
    if (std.math.isNan(val)) return "nan";
    if (std.math.isPositiveInf(val)) return "inf";
    if (std.math.isNegativeInf(val)) return "-inf";
    if (val == 0) return "0";
    const magnitude = @abs(val);
    if (magnitude >= 1_000_000_000 or magnitude < 0.1) {
        return std.fmt.bufPrint(buf, "{e:.3}", .{val}) catch "?";
    }
    if (val == @round(val)) {
        return std.fmt.bufPrint(buf, "{d:.0}", .{val}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d:.1}", .{val}) catch "0";
}

pub fn fmtPadding(buf: *[48]u8, p: Padding) []const u8 {
    if (p.top == 0 and p.right == 0 and p.bottom == 0 and p.left == 0) return "0";
    if (p.top == p.bottom and p.left == p.right and p.top == p.left) {
        return std.fmt.bufPrint(buf, "{d:.0}", .{p.top}) catch "0";
    }
    if (p.top == p.bottom and p.left == p.right) {
        return std.fmt.bufPrint(buf, "{d:.0} {d:.0}", .{ p.top, p.left }) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d:.0} {d:.0} {d:.0} {d:.0}", .{
        p.top, p.right, p.bottom, p.left,
    }) catch "0";
}

pub fn fmtMargin(buf: *[64]u8, m: core.Margin) []const u8 {
    if (core.Margin.eql(m, .ZERO)) return "0";
    if (!m.topIsAuto() and !m.rightIsAuto() and !m.bottomIsAuto() and !m.leftIsAuto()) {
        var pad_buf: [48]u8 = undefined;
        return fmtPadding(&pad_buf, .{ .top = m.top, .right = m.right, .bottom = m.bottom, .left = m.left });
    }
    var top_buf: [12]u8 = undefined;
    var right_buf: [12]u8 = undefined;
    var bottom_buf: [12]u8 = undefined;
    var left_buf: [12]u8 = undefined;
    const top = if (m.topIsAuto()) "auto" else std.fmt.bufPrint(&top_buf, "{d:.0}", .{m.top}) catch "0";
    const right = if (m.rightIsAuto()) "auto" else std.fmt.bufPrint(&right_buf, "{d:.0}", .{m.right}) catch "0";
    const bottom = if (m.bottomIsAuto()) "auto" else std.fmt.bufPrint(&bottom_buf, "{d:.0}", .{m.bottom}) catch "0";
    const left = if (m.leftIsAuto()) "auto" else std.fmt.bufPrint(&left_buf, "{d:.0}", .{m.left}) catch "0";
    return std.fmt.bufPrint(buf, "{s} {s} {s} {s}", .{ top, right, bottom, left }) catch "margin";
}

// ── 测试 ───────────────────────────────────────────────────────────────
//
// 这些规则此前只能靠打开 DevTools 面板用眼睛看。

test "fmtFloat: 特殊值走短路分支而不是打印成数字" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("nan", fmtFloat(&buf, std.math.nan(f32)));
    try std.testing.expectEqualStrings("inf", fmtFloat(&buf, std.math.inf(f32)));
    try std.testing.expectEqualStrings("-inf", fmtFloat(&buf, -std.math.inf(f32)));
    try std.testing.expectEqualStrings("0", fmtFloat(&buf, 0));
}

test "fmtFloat: 极大极小走科学计数法，常规值走定点" {
    var buf: [12]u8 = undefined;
    // < 0.1 与 >= 1e9 用科学计数法（面板列宽有限）
    try std.testing.expect(std.mem.indexOfScalar(u8, fmtFloat(&buf, 0.001), 'e') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fmtFloat(&buf, 2e9), 'e') != null);
    // 常规区间不该出现 e
    try std.testing.expect(std.mem.indexOfScalar(u8, fmtFloat(&buf, 42.5), 'e') == null);
}

test "formatSizing: 默认 grow/fit 不打印冗余的 min..max" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("grow", formatSizing(&buf, .{ .grow = .{} }));
    try std.testing.expectEqualStrings("fit", formatSizing(&buf, .{ .fit = .{} }));
    try std.testing.expectEqualStrings("100px", formatSizing(&buf, .{ .px = 100 }));
}

test "formatSizing: 带约束时把 min..max 打出来" {
    var buf: [20]u8 = undefined;
    const s = formatSizing(&buf, .{ .grow = .{ .min = 10, .max = 200 } });
    try std.testing.expect(std.mem.startsWith(u8, s, "grow("));
}

test "isValidUtf8: 合法与非法输入" {
    try std.testing.expect(isValidUtf8("hello"));
    try std.testing.expect(isValidUtf8("中文"));
    try std.testing.expect(isValidUtf8(""));
    // 截断的多字节序列
    try std.testing.expect(!isValidUtf8("\xE4\xB8"));
    // 孤立 continuation 字节
    try std.testing.expect(!isValidUtf8("\x80"));
}

test "truncate: 合法且不超长时零拷贝原样返回" {
    const src = "short";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = truncate(arena.allocator(), src, 32);
    try std.testing.expectEqualStrings(src, out);
    // 未分配 ⇒ 返回的就是入参切片本身
    try std.testing.expect(out.ptr == src.ptr);
}

test "truncate: max_len 为 0 时返回空而不是越界" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = truncate(arena.allocator(), "abc", 0);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "truncate: 超长时不切断多字节字符" {
    // ⚠ truncate 按 max_len 分配但返回**更短**的切片（省略号之后就截断），
    //   所以返回值不能直接 free，它不是分配的那一块的完整长度。生产调用点
    //   走的是 frame_arena（整帧一次性回收），这里用 arena 复刻同一语义。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 6 个中文字符（18 字节），截到 10 字节
    const src = "中文中文中文";
    const out = truncate(arena.allocator(), src, 10);
    // 产出必须仍是合法 UTF-8，不能切在字符中间
    try std.testing.expect(isValidUtf8(out));
    try std.testing.expect(out.len <= 10);
}
