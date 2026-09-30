/// Popover — 样式层
///
/// 浮层面板的外观声明；overlay 生命周期/portal/定位逻辑在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Border = core.Border;
const Shadow = core.Shadow;

/// 面板圆角 — border.radius 与 hit/clip shape 共用同一标量
pub fn popoverRadius(t: *const theme.ThemeTokens) f32 {
    return t.radius.md;
}

pub fn popoverContentBackground(t: *const theme.ThemeTokens) Color {
    return t.color.bg_secondary;
}

pub fn popoverContentBorder(t: *const theme.ThemeTokens) Border {
    return .{
        .width = 1,
        .color = t.color.border,
        .radius = popoverRadius(t),
    };
}

/// 主投影层 — token shadow.md
pub fn popoverKeyShadow(t: *const theme.ThemeTokens) Shadow {
    return t.shadow.md;
}

/// 环境光阴影层：大范围软阴影模拟 elevation（MD3 风格双层阴影）
pub const popover_ambient_shadow: Shadow = .{
    .color = Color.rgba(0, 0, 0, 18),
    .blur = 40,
    .offset_x = 0,
    .offset_y = 16,
};
