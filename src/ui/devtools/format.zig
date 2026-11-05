//! DevTools formatting utilities.
//!
//! Eight pure functions: format layout values (Sizing/Padding/Margin/f32) and possibly-invalid
//! byte strings into short panel display text. Depend only on std/core value types, not panel
//! state/selection/tree, so they are unit-testable directly (e.g. what displays for width=fit,
//! whether truncation breaks multibyte chars).
//!
//! UTF-8 validity is delegated to `text_core.utf8` (exhaustively checked equal to std for 1-3 byte
//! sequences, sampled for 4 byte).

const std = @import("std");
const core = @import("../core.zig");
const utf8 = @import("text_core").utf8;
const Sizing = core.Sizing;
const Padding = core.Padding;

// ===== Formatting utilities =====

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

/// Whether entire string is valid UTF-8. Forwarded to text_core.utf8; keep this name to avoid call
/// site changes.
pub fn isValidUtf8(src: []const u8) bool {
    return utf8.isValid(src);
}

pub fn formatSizing(buf: *[20]u8, sizing: Sizing) []const u8 {
    return switch (sizing) {
        .px => |v| std.fmt.bufPrint(buf, "{d:.0}px", .{v}) catch "px",
        .grow => |mm| if (mm.min < 0 and mm.max == std.math.inf(f32))
            "grow"
        else
            std.fmt.bufPrint(buf, "grow({d:.0}..{d:.0})", .{ mm.min, mm.max }) catch "grow",
        .fit => |mm| if (mm.min < 0 and mm.max == std.math.inf(f32))
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

// ── Tests ─────────────────────────────────────────────────────────────
//
// These rules were previously only verifiable by opening DevTools panel visually.

test "fmtFloat: 特殊值走短路分支而不是打印成数字" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("nan", fmtFloat(&buf, std.math.nan(f32)));
    try std.testing.expectEqualStrings("inf", fmtFloat(&buf, std.math.inf(f32)));
    try std.testing.expectEqualStrings("-inf", fmtFloat(&buf, -std.math.inf(f32)));
    try std.testing.expectEqualStrings("0", fmtFloat(&buf, 0));
}

test "fmtFloat: 极大极小走科学计数法，常规值走定点" {
    var buf: [12]u8 = undefined;
    // < 0.1 and >= 1e9 use scientific notation (panel column width limited)
    try std.testing.expect(std.mem.indexOfScalar(u8, fmtFloat(&buf, 0.001), 'e') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fmtFloat(&buf, 2e9), 'e') != null);
    // Regular range shouldn't have 'e'
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
    // Truncated multibyte sequence
    try std.testing.expect(!isValidUtf8("\xE4\xB8"));
    // Orphan continuation byte
    try std.testing.expect(!isValidUtf8("\x80"));
}

test "truncate: 合法且不超长时零拷贝原样返回" {
    const src = "short";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = truncate(arena.allocator(), src, 32);
    try std.testing.expectEqualStrings(src, out);
    // No allocation -> return input slice itself
    try std.testing.expect(out.ptr == src.ptr);
}

test "truncate: max_len 为 0 时返回空而不是越界" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = truncate(arena.allocator(), "abc", 0);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "truncate: 超长时不切断多字节字符" {
    // Warning: truncate allocates to max_len but returns **shorter** slice (ellipsis then cut),
    //   so return can't be freed directly; it's not the full allocated block. Production calls
    //   use frame_arena (one-time per-frame recovery); here we replicate with arena semantics.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 6 multibyte characters (18 bytes), truncate to 10 bytes
    const src = "中文中文中文";
    const out = truncate(arena.allocator(), src, 10);
    // Output must still be valid UTF-8, can't cut in middle of character
    try std.testing.expect(isValidUtf8(out));
    try std.testing.expect(out.len <= 10);
}
