//! command_encoder/local_sort.zig, local-sort 的几何/bounds 纯函数
//!
//! 从 command_encoder.zig 析出（2026-07-31），与 paint_fingerprint.zig 同批。
//! 同样是零 encoder 实例状态依赖的纯函数簇。
//!
//! 用途：local-sort 会在**不改变视觉结果**的前提下，把相邻的同 pipeline
//! 命令聚成一簇批量提交，减少 pipeline 切换。能否重排的判据就是这里算出的
//! bounds, **两条命令 bounds 不重叠才可换序**。
//!
//! ⚠ 合同：bounds 必须**宁大勿小**。算小了会把实际重叠的两条判为可换序，
//! 直接产生错误的绘制顺序（后画的被先画的盖住）。文本宽度用的是保守估算
//! （见 estimateTextWidthForLocalSort），不做真实 shaping，因为这里只需要
//! 一个不会低估的上界，不需要精确值。

const std = @import("std");

pub const PipelineKind = enum(u8) {
    sdf,
    image,
    icon,
    text,
    fence,
};

pub fn localSortPipelineKind(it: anytype) PipelineKind {
    return switch (it.kind) {
        .rect, .shadow, .gradient => .sdf,
        // .path: arc 走 sdf，fill_path/stroke_path 走 path renderer (作 fence 与 sdf 隔离)
        .path => if (it.arc_outer_radius > 0) .sdf else .fence,
        .image => if (it.icon_rep_ptr != null) .icon else .image,
        .text => .text,
        .control, .none => .fence,
    };
}

pub fn localSortBoundsForCommand(it: anytype) ?[4]f32 {
    return switch (it.kind) {
        .rect, .gradient => normalizedRectBounds(it.geom.x, it.geom.y, it.geom.w, it.geom.h),
        .shadow => blk: {
            if (it.shadow2_color.a > 0) {
                break :blk localSortShadowBounds(
                    it.geom.x,
                    it.geom.y,
                    it.geom.w,
                    it.geom.h,
                    @max(it.shadow_blur, it.shadow2_blur),
                    @max(@abs(it.shadow_offset_x), @abs(it.shadow2_offset_x)),
                    @max(@abs(it.shadow_offset_y), @abs(it.shadow2_offset_y)),
                );
            }
            break :blk localSortShadowBounds(
                it.geom.x,
                it.geom.y,
                it.geom.w,
                it.geom.h,
                it.shadow_blur,
                it.shadow_offset_x,
                it.shadow_offset_y,
            );
        },
        .image => localSortImageLikeBounds(it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.rotate),
        .text => localSortTextBounds(it.geom.x, it.geom.y, it.text_content, it.text_font_size),
        .path => if (it.arc_outer_radius > 0)
            localSortArcBounds(it.geom.x, it.geom.y, it.arc_outer_radius)
        else
            null,
        .control, .none => null,
    };
}

pub fn normalizedRectBounds(x: f32, y: f32, w: f32, h: f32) [4]f32 {
    const clamped_w = @max(w, 0);
    const clamped_h = @max(h, 0);
    return .{ x, y, clamped_w, clamped_h };
}

pub fn localSortImageLikeBounds(x: f32, y: f32, w: f32, h: f32, rotate: f32) [4]f32 {
    if (@abs(rotate) <= 0.0001) return normalizedRectBounds(x, y, w, h);
    const cx = x + w * 0.5;
    const cy = y + h * 0.5;
    const radius = 0.5 * std.math.sqrt(w * w + h * h);
    return .{
        cx - radius,
        cy - radius,
        radius * 2,
        radius * 2,
    };
}

pub fn localSortShadowBounds(x: f32, y: f32, w: f32, h: f32, blur: f32, offset_x: f32, offset_y: f32) [4]f32 {
    const pad = @max(blur, 0);
    const left = x + @min(offset_x, 0) - pad;
    const top = y + @min(offset_y, 0) - pad;
    const right = x + w + @max(offset_x, 0) + pad;
    const bottom = y + h + @max(offset_y, 0) + pad;
    return .{
        left,
        top,
        @max(right - left, 0),
        @max(bottom - top, 0),
    };
}

pub fn localSortArcBounds(cx: f32, cy: f32, outer_radius: f32) [4]f32 {
    const radius = @max(outer_radius, 0);
    return .{
        cx - radius,
        cy - radius,
        radius * 2,
        radius * 2,
    };
}

pub fn localSortTextBounds(x: f32, y: f32, content: []const u8, font_size: f32) [4]f32 {
    const estimated_w = estimateTextWidthForLocalSort(content, font_size);
    // y 是基线：上伸 1.5em（ascent 上界）+ 下伸 0.5em（descender 上界）。
    // 此前只算基线以上，g/p/y 的下伸部不参与重叠判定，与紧贴下方的
    // 另一管线命令被判"不相交"而重排，z 序可能颠倒。
    const ascent = @max(font_size * 1.5, font_size);
    const descent = @max(font_size * 0.5, 0);
    return .{
        x,
        y - ascent,
        estimated_w,
        ascent + descent,
    };
}

pub fn estimateTextWidthForLocalSort(content: []const u8, font_size: f32) f32 {
    var units: f32 = 0;
    var i: usize = 0;
    while (i < content.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(content[i]) catch {
            units += 0.7;
            i += 1;
            continue;
        };
        if (i + seq_len > content.len) break;
        const cp = std.unicode.utf8Decode(content[i .. i + seq_len]) catch {
            units += 0.7;
            i += seq_len;
            continue;
        };
        units += textWidthUnitsForCodepoint(cp);
        i += seq_len;
    }
    if (i < content.len) {
        units += @as(f32, @floatFromInt(content.len - i)) * 0.7;
    }
    return @max(font_size, units * font_size);
}

pub fn textWidthUnitsForCodepoint(cp: u21) f32 {
    if (cp == ' ') return 0.35;
    if (cp == '\t') return 1.6;
    if (cp <= 0x7F) {
        if ((cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return 0.62;
        return 0.5;
    }
    if (isWideCodepoint(cp)) return 1.0;
    return 0.8;
}

pub fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2329 and cp <= 0x232A) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF);
}

pub fn rectsOverlap(a: [4]f32, b: [4]f32) bool {
    if (a[2] <= 0 or a[3] <= 0 or b[2] <= 0 or b[3] <= 0) return false;
    return a[0] < b[0] + b[2] and
        a[0] + a[2] > b[0] and
        a[1] < b[1] + b[3] and
        a[1] + a[3] > b[1];
}
