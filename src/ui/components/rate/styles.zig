//! Rate style layer, star color / star grid geometry (zenit-styling-revamp).
//! mount and runtime updates (tint rewrite in applyDisplayValue) share single starColor color
//! source.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;

/// Star icon / text scale relative to grid
pub const star_icon_scale: f32 = 0.75;

/// Lit / unlit coloring (warning / fg_disabled)
pub fn starColor(active: bool, t: *const theme.ThemeTokens) Color {
    return if (active) t.tokens.color.accent else t.tokens.color.border_strong;
}

/// Single star grid cell (square centered container)
pub fn starBoxStyle(size: f32) core.BoxStyle {
    return .{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .justify = .center,
        .align_items = .center,
    };
}
