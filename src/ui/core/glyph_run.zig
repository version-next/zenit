//! GlyphRun + cluster map, Phase 6 cluster-aware text layout 数据结构
//!
//! 现 zenit text_layout.zig 用旧 ASCII-first measure API 返回单个 f32 advance；这丢失了：
//! - 字符 -> glyph cluster 关系（complex script: 1 cluster = N codepoints / N glyphs）
//! - 每 glyph 独立 advance + offset
//! - direction（RTL 时 glyph order != logical order）
//! - baseline 度量（ascent/descent/line_gap）混合字号正确对齐
//!
//! GlyphRun 是从 TextShaper.shape() 输出的标准化 IR：保留 cluster_map 让
//! cursor xToCluster 单调 + shaping 一致。
//!
//! 设计参照：
//! - HarfBuzz hb_buffer / hb_glyph_info_t / hb_glyph_position_t
//! - CoreText CTRun / CTRunGetGlyphCount + CTRunGetStringIndices
//! - Skia SkShaper RunIterator
//!
//! 历史债避免：
//! - **不**让 GlyphRun 持有 owned []Glyph（只引用 ShapingCache 的 slice）
//! - **不**用 codepoint index 当 cursor 位置（应当 cluster index）
//! - **不**忽略 direction：RTL run 的 glyph_x 应理解为视觉位置，cluster 顺序逻辑

const std = @import("std");
const testing = std.testing;

pub const Direction = enum(u8) { ltr, rtl };

/// 单个 glyph 的位置 + advance（HarfBuzz 风格）
pub const GlyphPosition = struct {
    /// glyph id（font-specific）
    glyph_id: u32,
    /// x advance（往右移多少进入下一字形位置）
    x_advance: f32,
    /// y advance（垂直书写时用；横排恒 0）
    y_advance: f32 = 0,
    /// x offset（字形相对 baseline 起点 x 偏移；非 advance）
    x_offset: f32 = 0,
    /// y offset
    y_offset: f32 = 0,
};

/// cluster map entry：从 codepoint index 反查 glyph index 范围
pub const Cluster = struct {
    /// 此 cluster 在原文 utf-8 byte stream 中的起始 byte
    byte_offset: u32,
    /// glyphs 数组中此 cluster 对应的起始 index
    glyph_start: u32,
    /// glyphs 数组中此 cluster 结束 index（exclusive）
    glyph_end: u32,
};

/// 字体 metrics（pixel space）
pub const FontMetrics = struct {
    /// baseline 上方高度（正值）
    ascent: f32,
    /// baseline 下方高度（正值）
    descent: f32,
    /// 行间距（baseline 到下行 baseline 的额外间距）
    line_gap: f32,
    /// 字号（用于回算 metrics）
    font_size: f32,

    /// 返回该 metrics 下 line height = ascent + descent + line_gap
    pub fn lineHeight(self: FontMetrics) f32 {
        return self.ascent + self.descent + self.line_gap;
    }
};

/// 完整 shaping 结果：一段 (font, direction, script) 一致的文本
pub const GlyphRun = struct {
    /// glyph 序列（视觉顺序：LTR 是 logical 顺序；RTL 是反转后的视觉顺序）
    glyphs: []const GlyphPosition,
    /// cluster map（按 byte_offset 升序，无论 direction）
    clusters: []const Cluster,
    /// 字体 metrics
    metrics: FontMetrics,
    /// 文本方向
    direction: Direction = .ltr,
    /// 总 x advance（所有 glyphs 累加）
    total_advance: f32 = 0,

    /// 给定原文 byte position，找对应 cluster index。
    /// 返回该 cluster 的 glyph_start。RTL 时 caller 应反向计算视觉 x。
    pub fn clusterAt(self: GlyphRun, byte: u32) ?u32 {
        // clusters 按 byte_offset 升序排，二分查找
        var lo: usize = 0;
        var hi: usize = self.clusters.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = self.clusters[mid];
            if (c.byte_offset <= byte) {
                if (mid + 1 == self.clusters.len or self.clusters[mid + 1].byte_offset > byte) {
                    return @intCast(mid);
                }
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    /// 给定视觉 x（local space，run 起点为 0），找对应 cluster index。
    /// 单调累加 advance；适合 LTR run。RTL 由 caller 反转 x 输入。
    pub fn xToCluster(self: GlyphRun, x: f32) u32 {
        if (self.clusters.len == 0) return 0;
        if (x <= 0) return 0;

        var cur_x: f32 = 0;
        for (self.clusters, 0..) |cluster, idx| {
            // 该 cluster 的 width = sum of advances of its glyphs
            var cluster_w: f32 = 0;
            var gi = cluster.glyph_start;
            while (gi < cluster.glyph_end) : (gi += 1) {
                if (gi >= self.glyphs.len) break;
                cluster_w += self.glyphs[gi].x_advance;
            }
            // 落在该 cluster 内？
            if (x < cur_x + cluster_w / 2.0) return @intCast(idx);
            cur_x += cluster_w;
        }
        return @intCast(self.clusters.len);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FontMetrics.lineHeight" {
    const m = FontMetrics{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 };
    try testing.expectEqual(@as(f32, 18), m.lineHeight());
}

test "GlyphRun.clusterAt: byte offset → cluster idx" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 12 },
        .{ .glyph_id = 3, .x_advance = 11 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 }, // 'h' at byte 0
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 }, // 'i' at byte 1
        .{ .byte_offset = 2, .glyph_start = 2, .glyph_end = 3 }, // '!' at byte 2
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
    };

    try testing.expectEqual(@as(u32, 0), run.clusterAt(0).?);
    try testing.expectEqual(@as(u32, 1), run.clusterAt(1).?);
    try testing.expectEqual(@as(u32, 2), run.clusterAt(2).?);
}

test "GlyphRun.clusterAt: byte beyond text → last cluster" {
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 5, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &.{},
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    try testing.expectEqual(@as(u32, 1), run.clusterAt(100).?);
}

test "GlyphRun.xToCluster: x=0 → cluster 0" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    try testing.expectEqual(@as(u32, 0), run.xToCluster(0));
}

test "GlyphRun.xToCluster: x at half of cluster 0 → cluster 0" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    // x=4 in cluster 0 (width 10), midpoint = 5; 4 < 5 -> still cluster 0
    try testing.expectEqual(@as(u32, 0), run.xToCluster(4));
}

test "GlyphRun.xToCluster: x past midpoint of cluster 0 → cluster 1" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    // x=8 past cluster 0 midpoint (5) -> cluster 1
    try testing.expectEqual(@as(u32, 1), run.xToCluster(8));
}

test "GlyphRun.xToCluster: complex cluster (1 codepoint, 2 glyphs)" {
    // 模拟阿拉伯组合：1 cluster 包含 2 glyphs
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 5 },
        .{ .glyph_id = 2, .x_advance = 5 },
        .{ .glyph_id = 3, .x_advance = 12 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 2 }, // 第一个 cluster：2 glyphs，width 10
        .{ .byte_offset = 2, .glyph_start = 2, .glyph_end = 3 }, // 第二个 cluster：1 glyph，width 12
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    // x=4 在 cluster 0（midpoint=5）-> 0
    try testing.expectEqual(@as(u32, 0), run.xToCluster(4));
    // x=8 过 cluster 0 midpoint -> 1
    try testing.expectEqual(@as(u32, 1), run.xToCluster(8));
}

test "GlyphRun.xToCluster: empty clusters → 0" {
    const run = GlyphRun{
        .glyphs = &.{},
        .clusters = &.{},
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    try testing.expectEqual(@as(u32, 0), run.xToCluster(50));
}
