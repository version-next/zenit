/// Sheet, style layer
///
/// Overlay / panel coloring, shadow and content area styles; overlay lifecycle and slide-in
/// animation in mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;

/// Overlay color, props override priority, default overlay token
pub fn sheetBarrierColor(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.tokens.color.overlay;
}

/// Panel background, props override priority
pub fn sheetPanelBackground(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.tokens.color.bg_primary;
}

/// Main shadow layer, token shadow.lg
pub fn sheetKeyShadow(t: *const theme.ThemeTokens) Shadow {
    return t.tokens.shadow.lg;
}

pub fn sheetContentStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .padding = Padding.all(t.tokens.space.space300),
    };
}

/// Only the edge facing the client gets a separator (Sheet / right in COMPONENTS.json).
pub fn sheetPanelEdge(t: *const theme.ThemeTokens, side: @import("mod.zig").SheetSide) core.BoxStyle {
    return .{
        .border_overlay = true,
        .border_color = t.tokens.color.border,
        .border_left_width = if (side == .right) 1 else 0,
        .border_right_width = if (side == .left) 1 else 0,
        .border_top_width = if (side == .bottom) 1 else 0,
        .border_bottom_width = if (side == .top) 1 else 0,
    };
}
