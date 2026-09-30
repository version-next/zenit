//! Rate 样式层 — 星标取色 / 星格几何（zenit-styling-revamp）。
//! mount 与运行时更新（applyDisplayValue 的 tint 改写）共用 starColor 单一取色源。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;

/// 星标图标/文本相对格子的缩放
pub const star_icon_scale: f32 = 0.75;

/// 亮/灭取色（warning / fg_disabled）
pub fn starColor(active: bool, t: *const theme.ThemeTokens) Color {
    return if (active) t.color.warning else t.color.fg_disabled;
}

/// 单个星标格子（正方形居中容器）
pub fn starBoxStyle(size: f32) core.BoxStyle {
    return .{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .justify = .center,
        .align_items = .center,
    };
}
