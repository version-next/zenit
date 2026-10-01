//! Progress 样式层，状态取色 / 轨道色 / 百分比文本样式（zenit-styling-revamp）。
//! 不确定模式 draw 回调内随 status_color 逐帧派生的渐变 lerp 属于绘制逻辑，留在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;
const ProgressStatus = @import("mod.zig").ProgressStatus;

/// 状态 -> fill 颜色（提高贴白底对比度的 lerp 收口在此）
pub fn statusColor(s: ProgressStatus, t: *const theme.ThemeTokens) Color {
    const base = switch (s) {
        .normal => t.color.accent,
        .success => t.color.success,
        .@"error" => t.color.danger,
    };
    // Storybook 和实际界面里都需要更明确的 fill 对比度，避免贴近白底时丢失。
    return Color.lerp(base, t.color.fg_primary, 0.12);
}

pub fn statusStyle(s: ProgressStatus, t: *const theme.ThemeTokens) ConditionalStyle {
    return .{
        .base = .{
            .background = statusColor(s, t),
            .corner_radius = 999,
        },
    };
}

/// 轨道底色
pub fn trackColor(t: *const theme.ThemeTokens) Color {
    return Color.lerp(t.color.bg_tertiary, t.color.fg_primary, 0.06);
}

/// 百分比文本样式
pub fn percentTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .color = t.color.fg_secondary, .font_size = t.font_size.sm };
}
