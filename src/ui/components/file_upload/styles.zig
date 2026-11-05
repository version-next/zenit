//! FileUpload style layer, wrapper / drop zone / file row / remove button styles and drop hover
//! coloring (zenit-styling-revamp).
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

// ========== Named style functions (style layer) ==========
// Migrated from mountFileUpload / addFile / setDropHover inline styles and color decisions;
// numeric values preserved as-is (zenit-styling-revamp).

pub fn wrapperStyle(w: f32, t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = t.tokens.space.space200,
        .padding = Padding.all(t.tokens.space.space300),
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.panel },
    };
}

pub fn dropZoneStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    const colors = dropZoneColors(false, t);
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = t.tokens.size.row },
        .direction = .row,
        .justify = .space_between,
        .align_items = .center,
        .gap = 6,
        .background = colors.bg,
        .border = .{ .overlay = true, .width = 0, .color = colors.border, .radius = t.tokens.radius.control },
    };
}

/// drop hover highlight two-state coloring (consumed by setDropHover)
pub fn dropZoneColors(hover_active: bool, t: *const theme.ThemeTokens) struct { bg: Color, border: Color } {
    return if (hover_active)
        .{ .bg = t.tokens.color.bg_hover, .border = t.tokens.color.accent }
    else
        .{ .bg = t.tokens.color.transparent, .border = t.tokens.color.border };
}

pub fn hintTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.md };
}

pub fn listStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
    };
}

pub fn fileRowStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = Padding.symmetric(0, 8),
        .background = t.tokens.color.surface_inset,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.control },
    };
}

pub fn fileNameTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.md };
}

pub fn removeBtnStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .justify = .center,
        .align_items = .center,
    };
}

const css = @import("../../css.zig").css;
pub const fileIconStyle = css(.{ .width = 16, .height = 16 });
pub const removeIconStyle = css(.{ .width = 12, .height = 12 });
