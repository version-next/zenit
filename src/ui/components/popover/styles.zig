/// Popover, style layer
///
/// Floating panel appearance declaration; overlay lifecycle / portal / positioning logic in
/// mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Border = core.Border;
const Shadow = core.Shadow;

/// Panel corner radius, border.radius and hit/clip shape share same scalar
pub fn popoverRadius(t: *const theme.ThemeTokens) f32 {
    return t.tokens.radius.panel;
}

pub fn popoverContentBackground(t: *const theme.ThemeTokens) Color {
    return t.tokens.color.bg_primary;
}

pub fn popoverContentBorder(t: *const theme.ThemeTokens) Border {
    return .{
        .width = 1,
        .overlay = true,
        .color = t.tokens.color.border,
        .radius = popoverRadius(t),
    };
}

/// Main shadow layer, token shadow.md
pub fn popoverKeyShadow(t: *const theme.ThemeTokens) Shadow {
    return t.tokens.shadow.md;
}
