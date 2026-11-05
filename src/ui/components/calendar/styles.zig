//! Calendar styling layer, named style functions and constants (zenit-styling-revamp).
//! Migrated from mount/buildGrid inline styles; values kept as-is. mod.zig only
//! consumes function returns, makes no inline style or color decisions.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

pub const nav_icon_size: f32 = 16;

pub fn containerStyle(panel_width: f32, t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = panel_width },
        .height = .{ .fit = .{} },
        .direction = .column,
        // White-background panel (same surface as Card / Popover), date cells distinguished by
        // hover / today / selected.
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.panel },
        .padding = Padding.all(12),
        .gap = 8,
    };
}

pub fn headerStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
    };
}

pub fn monthLabelTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.md, .font_weight = 600 };
}

pub fn weekdayCellStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 36 },
        .height = .{ .px = 28 },
        .justify = .center,
        // Preserve the original text block's inline start position; only
        // vertical centering used to come from the hidden paint offset.
        .align_items = .start,
    };
}

pub fn weekdayTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_tertiary, .font_size = t.tokens.font_size.xs, .font_weight = 600 };
}

pub fn gridStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
    };
}

pub fn weekRowStyle(cell_size: f32) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = cell_size },
        .direction = .row,
        .justify = .space_between,
    };
}

/// date cell state flags -> visual decision input for dayCellStyle/dayTextStyle
pub const DayCellFlags = struct {
    selected: bool,
    today: bool,
    keyboard_focus: bool,
    current_month: bool,
};

pub fn dayCellStyle(f: DayCellFlags, cell_size: f32, t: *const theme.ThemeTokens) core.BoxStyle {
    // Panel is white: non-selected cells match panel, adjacent-month dates distinguished
    // by fg_tertiary text only.
    const bg: Color = if (f.selected) t.tokens.color.accent else t.tokens.color.bg_primary;
    // RxE0k: today is accent text with no frame; keyboard focus is an independent 2px ring with
    // 2px offset, including selected dates.
    const border_width: f32 = 0;
    const border_color = t.tokens.color.border_strong;
    return .{
        .width = .{ .px = cell_size },
        .height = .{ .px = cell_size },
        .justify = .center,
        .align_items = .center,
        .background = bg,
        .outline = if (f.keyboard_focus) .{ .color = t.tokens.color.focus_ring, .width = t.tokens.border_width.focus, .offset = 2 } else null,
        .border = .{ .overlay = true, .width = border_width, .color = border_color, .radius = t.tokens.radius.control },
    };
}

pub fn dayTextStyle(f: DayCellFlags, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = if (f.selected)
            t.tokens.color.fg_inverse
        else if (f.today)
            t.tokens.color.accent
        else if (f.current_month)
            t.tokens.color.fg_primary
        else
            t.tokens.color.fg_disabled,
        .font_size = t.tokens.font_size.md,
        .font_weight = if (f.selected or f.today) 600 else 400,
    };
}

pub fn dayHoverBg(current_month: bool, t: *const theme.ThemeTokens) Color {
    return if (current_month) t.tokens.color.bg_hover else Color.lerp(t.tokens.color.bg_primary, t.tokens.color.bg_hover, 0.55);
}
