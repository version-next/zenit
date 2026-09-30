/// Tooltip — 样式层
///
/// 内容气泡的样式常量与取色函数；overlay 生命周期与挂载逻辑在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

/// 气泡圆角 — border.radius 与 hit/clip shape 共用同一标量
pub const tooltip_radius: f32 = 4;

pub const tooltip_content_padding: Padding = Padding.symmetric(4, 8);

/// 气泡背景 — props 覆盖优先，默认 tooltip_bg token
pub fn tooltipContentBackground(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.color.tooltip_bg;
}

/// 气泡文字 — font_size 由 props 参数化
pub fn tooltipLabelStyle(text_color_override: ?Color, font_size: f32, t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .font_size = font_size,
        .color = text_color_override orelse t.color.tooltip_fg,
    };
}
