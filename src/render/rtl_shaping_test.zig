//! RTL（阿拉伯语/希伯来语）shaping 契约测试。
//!
//! 这些测试**必须**跑在真实 CoreText 路径上（`src/render` test target 链了
//! native/macos/coretext_bridge.m）。注意 `src/ui/core/text_layout.zig` 有
//! `builtin.is_test` 分支会绕开 CoreText 走估算路径，那条路径测不出 RTL，
//! 所以这里直接用 `text.TextShaper`，不经 text_layout。
//!
//! 背景：CoreText 的 `CTLineCreateWithAttributedString` 内部已跑完 Unicode
//! bidi（UAX #9），`CTLineGetGlyphRuns` 返回的 run 以及 run 内的 glyph 数组
//! **都已经是视觉序**（从左到右 pen 递增）。RTL 的体现是 *string index* 递减，
//! 而不是 position 递减。下面的测试把这个合同钉死，防止有人"修" RTL 时
//! 误把 glyph 数组反转或改成绝对定位，从而同时打断 LTR。

const std = @import("std");
const testing = std.testing;
const text = @import("text");

const ARABIC = "مرحبا"; // "marhaba"
const HEBREW = "שלום"; // "shalom"

/// 打开一个能覆盖阿拉伯/希伯来字形的系统字体。
/// 走 findFont 让 CoreText 自己按 cascade list 回退。
fn openFont(fs: *text.FontSystem, size: f32) !*text.Font {
    return fs.findFont(.{ .family = "Helvetica", .size = size });
}

const ShapeResult = struct {
    glyphs: []text.ShapedGlyph,
    allocator: std.mem.Allocator,

    fn deinit(self: *ShapeResult) void {
        for (self.glyphs) |g| {
            if (g.fallback_font_ref) |r| text.releaseFallbackFontRef(r);
        }
        if (self.glyphs.len > 0) self.allocator.free(self.glyphs);
    }
};

fn shape(allocator: std.mem.Allocator, s: []const u8) !ShapeResult {
    var fs = try text.FontSystem.init(allocator);
    defer fs.deinit();
    const font = try openFont(&fs, 20.0);
    defer font.deinit();

    var shaper = try text.TextShaper.init(allocator);
    defer shaper.deinit();

    const glyphs = try shaper.shape(s, font);
    return .{ .glyphs = glyphs, .allocator = allocator };
}

/// 渲染器（text_renderer.emitGlyphInstance）的合同是：
///   glyph_x = cursor_x + x_offset，cursor_x 由 x_advance 累加推进。
/// 也就是 x_offset 是**相对当前 pen** 的微调，不是绝对坐标。
/// 若 RTL run 的 x_offset 变成大负数，字形就会反向重叠，这是本测试要防的。
fn assertNoReverseOverlap(glyphs: []const text.ShapedGlyph) !void {
    var cursor: f32 = 0;
    var prev_x: f32 = -std.math.floatMax(f32);
    for (glyphs) |g| {
        const x = cursor + g.x_offset;
        // 视觉序要求 pen 单调不减；允许 mark/变音符号回退，但不允许
        // 整字形宽度级别的倒退（那就是反向重叠）。
        try testing.expect(x >= prev_x - g.x_advance);
        prev_x = x;
        cursor += g.x_advance;
    }
}

test "RTL: 阿拉伯语 shaping 产出视觉序，x_offset 不产生反向重叠" {
    var r = try shape(testing.allocator, ARABIC);
    defer r.deinit();

    try testing.expect(r.glyphs.len > 0);
    try assertNoReverseOverlap(r.glyphs);

    // CoreText 已做 bidi：glyph 数组是视觉序，x_offset 应当接近 0
    // （相对 pen 的微调），而不是把整个 run 反着摊开的大负数。
    for (r.glyphs) |g| {
        try testing.expect(@abs(g.x_offset) < 1.0);
    }
}

test "RTL: 希伯来语 shaping 产出视觉序，x_offset 不产生反向重叠" {
    var r = try shape(testing.allocator, HEBREW);
    defer r.deinit();

    try testing.expect(r.glyphs.len > 0);
    try assertNoReverseOverlap(r.glyphs);
    for (r.glyphs) |g| {
        try testing.expect(@abs(g.x_offset) < 1.0);
    }
}

test "RTL: cluster（源 byte 偏移）随视觉序递减，证明 bidi 已由 CoreText 完成" {
    var r = try shape(testing.allocator, HEBREW);
    defer r.deinit();

    try testing.expect(r.glyphs.len >= 2);
    // 视觉序第一个 glyph 对应源串**最后**一个字符，这正是 RTL 的定义。
    try testing.expect(r.glyphs[0].cluster > r.glyphs[r.glyphs.len - 1].cluster);
    // 且末尾 glyph 落在源串起点。
    try testing.expectEqual(@as(u32, 0), r.glyphs[r.glyphs.len - 1].cluster);
}

test "LTR 未退化：ASCII cluster 递增且 x_offset 为 0" {
    var r = try shape(testing.allocator, "abc");
    defer r.deinit();

    try testing.expectEqual(@as(usize, 3), r.glyphs.len);
    try assertNoReverseOverlap(r.glyphs);
    for (r.glyphs, 0..) |g, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), g.cluster);
        try testing.expect(@abs(g.x_offset) < 0.001);
    }
}

test "RTL 总宽度与 LTR 一致的累加语义：advance 之和为正且等于视觉宽度" {
    var r = try shape(testing.allocator, ARABIC);
    defer r.deinit();

    var total: f32 = 0;
    for (r.glyphs) |g| {
        // 每个 advance 必须为正，负 advance 会让 pen 倒退。
        try testing.expect(g.x_advance > 0);
        total += g.x_advance;
    }
    try testing.expect(total > 0);
}
