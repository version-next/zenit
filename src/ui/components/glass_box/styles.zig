//! GlassBox 样式层，header 文本样式。
//! glass 材质本体（surface border/tint/blur 的 Resolved* 插值链）是运行时
//! 渲染逻辑，留在 mod.zig（改动它必须肉眼看截图，见 memory）。
const core = @import("../../core.zig");
const theme = core.theme;

pub fn glassTitleStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_primary,
        .font_size = 15,
        .font_weight = 650,
    };
}

pub fn glassSubtitleStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = 12,
        .font_weight = 450,
    };
}
