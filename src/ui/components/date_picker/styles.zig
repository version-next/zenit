//! DatePicker styling layer, trigger/panel/Today button style and interaction
//! color pure functions (zenit-styling-revamp). mount init and runtime update
//! (syncTriggerVisual/updateDisplayLabel) share same color source.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;

// ========== Named style functions (styling layer) ==========
// Migrated from mount/syncTriggerVisual/updateDisplayLabel inline styles and
// color decisions; values kept as-is (zenit-styling-revamp).

pub const panel_radius: f32 = 8;

/// trigger border color switches three states with open / has_value (mount init +
/// syncTriggerVisual shared)
pub fn triggerBorderColor(open: bool, has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.tokens.color.border_focus else if (has_value) t.tokens.color.border_strong else t.tokens.color.border;
}

pub fn displayTextColor(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.tokens.color.fg_primary else t.tokens.color.fg_tertiary;
}

pub fn leadingIconTint(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.tokens.color.fg_secondary else t.tokens.color.fg_tertiary;
}

pub fn chevronTint(open: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.tokens.color.accent else t.tokens.color.fg_tertiary;
}

pub fn panelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 276 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = panel_radius },
        .shadow = t.tokens.shadow.md,
    };
}

/// Today button: overlay on Button(.secondary) with light fill, no border, fills panel width.
/// Height / font size / radius from control metrics (no hardcoded 34 / 13 / 10).
pub fn todayBtnOverride(t: *const theme.ThemeTokens) core.StyleOverride {
    return .{
        .width = .{ .grow = .{} },
        .align_self = .stretch,
        .height = .{ .px = 36 },
        .background = t.tokens.color.transparent,
        .text_color = t.tokens.color.accent,
        .border = .{ .overlay = true, .width = 0, .color = t.tokens.color.border },
    };
}

/// DatePicker / DateRangePicker trigger look (A03ao): a ControlShell frame whose colors follow
/// the picker's own states — resting border by value, border_focus while open, danger when
/// invalid; no hover color; xs shadow. Shared by both pickers (one definition).
pub const TriggerLook = struct {
    size: @import("../control_shell/mod.zig").ControlSize,
    width: f32,
    open: bool = false,
    has_value: bool = false,
    invalid: bool = false,
    disabled: bool = false,
};

pub fn triggerFrame(l: TriggerLook, t: *const theme.ThemeTokens) core.BoxStyle {
    const cm = @import("../control_shell/mod.zig").metrics(t, l.size);
    return .{
        .width = .{ .px = l.width },
        .background = triggerBackground(l.disabled, t),
        .border = .{ .overlay = true, .width = 1, .color = triggerBorder(l.open, l.has_value, l.disabled, l.invalid, t), .radius = cm.radius },
        .corner_radius = cm.radius,
        .shadow = t.tokens.shadow.xs,
    };
}

pub fn triggerLeadingTint(l: TriggerLook, t: *const theme.ThemeTokens) Color {
    return if (l.disabled) t.tokens.color.fg_disabled else leadingIconTint(l.has_value, t);
}

pub fn triggerChevronTint(l: TriggerLook, t: *const theme.ThemeTokens) Color {
    return if (l.disabled) t.tokens.color.fg_disabled else chevronTint(l.open, t);
}

pub fn triggerBackground(disabled: bool, t: *const theme.ThemeTokens) Color {
    return if (disabled) t.tokens.color.disabled_bg else t.tokens.color.bg_primary;
}
pub fn triggerForeground(has_value: bool, disabled: bool, t: *const theme.ThemeTokens) Color {
    return if (disabled) t.tokens.color.fg_disabled else if (has_value) t.tokens.color.fg_primary else t.tokens.color.fg_tertiary;
}
pub fn triggerBorder(open: bool, has_value: bool, disabled: bool, invalid: bool, t: *const theme.ThemeTokens) Color {
    const recipe = core.ConditionalStyle{ .base = .{ .border_color = triggerBorderColor(open, has_value, t) }, .invalid = .{ .border_color = t.tokens.color.danger }, .disabled = .{ .border_color = t.tokens.color.border } };
    return recipe.resolve(.{ .is_invalid = invalid, .is_disabled = disabled }).border_color.?;
}

// QOo7I / RxE0k: time fields and explicit action footer live below the date grid.
pub fn timeEditorStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .border_overlay = true, .width = .{ .grow = .{} }, .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .padding = Padding.symmetric(12, 0), .border_top_width = 1, .border_color = t.tokens.color.border };
}
pub fn timeFieldsStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .gap = 6, .align_items = .start, .no_cross_stretch = true };
}
pub fn timeHeadingStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .font_size = t.tokens.font_size.xs, .font_weight = 600, .color = t.tokens.color.fg_tertiary };
}
pub fn timeFooterStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .border_overlay = true, .width = .{ .grow = .{} }, .height = .{ .px = 52 }, .direction = .row, .justify = .end, .align_items = .center, .gap = 12, .padding = Padding.symmetric(12, 0), .border_top_width = 1, .border_color = t.tokens.color.border };
}
pub fn timeButtonStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .height = .{ .px = 28 }, .padding = Padding.symmetric(0, 12) };
}

pub fn timeFieldStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .height = .{ .px = 28 } };
}
