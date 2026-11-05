/// ComboBox, styling layer. Named style functions and shared geometry
/// constants; logic / State / portal mounted in mod.zig.
const core = @import("../../core.zig");
const theme = core.theme;

/// RYMhT: 28px menu row with 13px body and 8px horizontal inset. Panel scroll
/// geometry (ComboBoxState.item_h) shared with row style.
pub const combo_item_height: f32 = 28;

/// RYMhT popup chrome: panel radius and md elevation.
pub fn comboPanelRadius(t: *const theme.ThemeTokens) f32 {
    return t.tokens.radius.panel;
}

pub fn comboPanelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    const radius = comboPanelRadius(t);
    return .{
        .direction = .column,
        .gap = 0,
        .padding = core.Padding.all(4),
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = radius },
        .corner_radius = radius,
        .shadow = t.tokens.shadow.md,
    };
}

pub fn comboItemStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .row,
        .width = .{ .grow = .{} },
        .height = .{ .px = combo_item_height },
        .padding = core.Padding.symmetric(0, t.tokens.space.space200),
        .justify = .space_between,
        .align_items = .center,
        .overflow_hidden = true,
        .corner_radius = t.tokens.radius.control,
    };
}

/// Empty row: same geometry as option row but initially collapsed (height 0)
pub fn comboEmptyStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    var s = comboItemStyle(t);
    s.justify = .center;
    s.display = .none; // Default collapsed; applyFilter toggles by match count
    return s;
}

pub fn comboItemTextStyle(disabled: bool, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = if (disabled) t.tokens.color.fg_disabled else t.tokens.color.fg_primary,
        .font_size = t.tokens.font_size.md,
    };
}

pub fn comboEmptyTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_tertiary,
        .font_size = t.tokens.font_size.md,
    };
}

/// Keyboard/hover highlight row bg, driven by highlight logic at runtime
pub fn comboHighlightBg(t: *const theme.ThemeTokens) core.Color {
    return t.tokens.color.bg_hover;
}

pub fn optionStyle(t: *const theme.ThemeTokens, selected: bool) core.ConditionalStyle {
    return .{
        .base = .{ .background = t.tokens.color.transparent, .text_color = t.tokens.color.fg_primary },
        .selected = .{ .background = t.tokens.color.list_selection_bg, .text_color = t.tokens.color.selection_fg },
        .hover = .{ .background = if (selected) t.tokens.color.list_selection_hover_bg else t.tokens.color.bg_hover },
        .disabled = .{ .background = t.tokens.color.transparent, .text_color = t.tokens.color.fg_disabled },
    };
}
