//! TextShaper → GlyphRun 适配器（v0.5 §5 GlyphRun pipeline 起步）
//!
//! src/text/types.zig.ShapedGlyph 是低级 shaping 输出（每 glyph 一条），包含
//! cluster 字段 (utf-8 byte offset)。zenit IR `GlyphRun` (src/ui/core/glyph_run.zig)
//! 是高级聚合：glyph 序列 + cluster_map (byte_offset → glyph index range) +
//! FontMetrics + total_advance。
//!
//! 这个 adapter 只做格式翻译，不调任何平台 API，因此 ui_core 不需要 native
//! bridge link（除了 cx.shapeText 入口处真正调 TextShaper.shape() 时）。

const std = @import("std");
const text_module = @import("text");
const ShapedGlyph = text_module.ShapedGlyph;

const glyph_run_mod = @import("glyph_run.zig");
const GlyphRun = glyph_run_mod.GlyphRun;
const GlyphPosition = glyph_run_mod.GlyphPosition;
const Cluster = glyph_run_mod.Cluster;
const FontMetrics = glyph_run_mod.FontMetrics;
const Direction = glyph_run_mod.Direction;

/// 把 TextShaper.shape() 输出 + 字体度量翻译成 GlyphRun。
///
/// 内存：glyphs/clusters slice 在 caller 提供的 allocator 里 alloc。caller
/// 负责生命周期（典型 caller 是 ShapingCache，它把这两段 slice 存到自己的 arena
/// 里供后续读取）。
///
/// cluster 聚合：ShapedGlyph 序列里**相邻 glyph 共享 cluster byte_offset 的**
/// 视为一个 cluster (复杂脚本：1 cluster = N glyphs)。
pub fn fromShapedGlyphs(
    allocator: std.mem.Allocator,
    shaped: []const ShapedGlyph,
    metrics: FontMetrics,
    direction: Direction,
) !GlyphRun {
    if (shaped.len == 0) {
        return GlyphRun{
            .glyphs = &.{},
            .clusters = &.{},
            .metrics = metrics,
            .direction = direction,
            .total_advance = 0,
        };
    }

    // 1) glyphs slice：直接 1:1 翻译，累加 total_advance
    const glyphs = try allocator.alloc(GlyphPosition, shaped.len);
    errdefer allocator.free(glyphs);
    var total: f32 = 0;
    for (shaped, 0..) |g, i| {
        glyphs[i] = .{
            .glyph_id = g.glyph_index,
            .x_advance = g.x_advance,
            .y_advance = g.y_advance,
            .x_offset = g.x_offset,
            .y_offset = g.y_offset,
        };
        total += g.x_advance;
    }

    // 2) cluster map：按 byte_offset 分段。第一遍数 cluster 数。
    var cluster_count: usize = 1;
    var prev_cluster = shaped[0].cluster;
    for (shaped[1..]) |g| {
        if (g.cluster != prev_cluster) {
            cluster_count += 1;
            prev_cluster = g.cluster;
        }
    }

    const clusters = try allocator.alloc(Cluster, cluster_count);
    errdefer allocator.free(clusters);

    // 3) 第二遍填 cluster 范围
    var ci: usize = 0;
    var run_start: u32 = 0;
    prev_cluster = shaped[0].cluster;
    for (shaped[1..], 1..) |g, i| {
        if (g.cluster != prev_cluster) {
            clusters[ci] = .{
                .byte_offset = prev_cluster,
                .glyph_start = run_start,
                .glyph_end = @intCast(i),
            };
            ci += 1;
            run_start = @intCast(i);
            prev_cluster = g.cluster;
        }
    }
    // 收尾最后一个 cluster
    clusters[ci] = .{
        .byte_offset = prev_cluster,
        .glyph_start = run_start,
        .glyph_end = @intCast(shaped.len),
    };

    return GlyphRun{
        .glyphs = glyphs,
        .clusters = clusters,
        .metrics = metrics,
        .direction = direction,
        .total_advance = total,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "fromShapedGlyphs: empty input → empty run" {
    const run = try fromShapedGlyphs(
        testing.allocator,
        &.{},
        .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
        .ltr,
    );
    try testing.expectEqual(@as(usize, 0), run.glyphs.len);
    try testing.expectEqual(@as(usize, 0), run.clusters.len);
    try testing.expectEqual(@as(f32, 0), run.total_advance);
}

test "fromShapedGlyphs: simple ASCII (1 cluster per glyph)" {
    const shaped = [_]ShapedGlyph{
        .{ .glyph_index = 1, .cluster = 0, .x_advance = 10, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 2, .cluster = 1, .x_advance = 11, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 3, .cluster = 2, .x_advance = 12, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
    };
    const run = try fromShapedGlyphs(
        testing.allocator,
        &shaped,
        .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
        .ltr,
    );
    defer testing.allocator.free(run.glyphs);
    defer testing.allocator.free(run.clusters);

    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try testing.expectEqual(@as(usize, 3), run.clusters.len);
    try testing.expectEqual(@as(f32, 33), run.total_advance);

    // 每 cluster 一个 glyph
    try testing.expectEqual(@as(u32, 0), run.clusters[0].byte_offset);
    try testing.expectEqual(@as(u32, 0), run.clusters[0].glyph_start);
    try testing.expectEqual(@as(u32, 1), run.clusters[0].glyph_end);
    try testing.expectEqual(@as(u32, 2), run.clusters[2].byte_offset);
    try testing.expectEqual(@as(u32, 2), run.clusters[2].glyph_start);
    try testing.expectEqual(@as(u32, 3), run.clusters[2].glyph_end);
}

test "fromShapedGlyphs: complex cluster (1 cluster = 2 glyphs)" {
    // 模拟 emoji ZWJ sequence: 2 glyph 共享 cluster=0
    const shaped = [_]ShapedGlyph{
        .{ .glyph_index = 100, .cluster = 0, .x_advance = 16, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 200, .cluster = 0, .x_advance = 0, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 5, .cluster = 8, .x_advance = 10, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
    };
    const run = try fromShapedGlyphs(
        testing.allocator,
        &shaped,
        .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
        .ltr,
    );
    defer testing.allocator.free(run.glyphs);
    defer testing.allocator.free(run.clusters);

    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try testing.expectEqual(@as(usize, 2), run.clusters.len);
    try testing.expectEqual(@as(f32, 26), run.total_advance);

    // cluster 0: 2 glyphs (100 + 200)
    try testing.expectEqual(@as(u32, 0), run.clusters[0].byte_offset);
    try testing.expectEqual(@as(u32, 0), run.clusters[0].glyph_start);
    try testing.expectEqual(@as(u32, 2), run.clusters[0].glyph_end);

    // cluster 1: 1 glyph (after byte 8)
    try testing.expectEqual(@as(u32, 8), run.clusters[1].byte_offset);
    try testing.expectEqual(@as(u32, 2), run.clusters[1].glyph_start);
    try testing.expectEqual(@as(u32, 3), run.clusters[1].glyph_end);
}
