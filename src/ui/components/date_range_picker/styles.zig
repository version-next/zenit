//! DateRangePicker styling layer (zenit-styling-revamp): trigger/panel/month panel/
//! date cell style functions + interaction color pure functions + day cell state color
//! matrix (DayCellVisual / computeDayCellVisual). Depends on mod.zig's State and date
//! comparison logic (circular import, Zig lazy analysis allows).
const control_shell = @import("../control_shell/mod.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;
const mod = @import("mod.zig");
const DateRangePickerState = mod.DateRangePickerState;
const SimpleDate = @import("../calendar/mod.zig").SimpleDate;

// ========== Named style functions (styling layer) ==========
// Inline styles and color decisions from mount/mountMonthSection/buildMonthGrid/
// updateDisplayLabel/syncTriggerVisual (zenit-styling-revamp).
// Day cell state color matrix lives in computeDayCellVisual (pure function, styling layer).

pub const nav_icon_size: f32 = 16;
pub const panel_radius: f32 = 8;
pub const day_cell_size: f32 = 36;
pub const day_font_size: f32 = 13;

pub fn dashColor(has_any_value: bool, disabled: bool, t: *const theme.ThemeTokens) Color {
    if (disabled) return t.tokens.color.fg_disabled;
    return if (has_any_value) t.tokens.color.fg_secondary else t.tokens.color.fg_tertiary;
}

pub fn rangeTextStyle(t: *const theme.ThemeTokens, cm: control_shell.ControlMetrics) core.TextStyle {
    return .{ .color = t.tokens.color.fg_tertiary, .font_size = cm.font_size, .line_height = cm.line_height };
}

pub fn panelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = panel_radius },
        .shadow = t.tokens.shadow.md,
    };
}

pub fn monthSectionStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 276 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
        .padding = Padding.all(12),
    };
}

pub fn monthHeaderStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 32 },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
    };
}

pub fn monthTitleTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.md, .font_weight = 600 };
}

pub fn weekdayCellStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 36 },
        .height = .{ .px = 28 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn weekdayTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_tertiary, .font_size = t.tokens.font_size.xs, .font_weight = 600 };
}

pub fn monthGridStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
    };
}

pub fn weekRowStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .px = day_cell_size },
        .direction = .row,
        .gap = 0,
    };
}

pub fn dayPlaceholderStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = day_cell_size },
        .height = .{ .px = day_cell_size },
    };
}

/// day cell box style = computeDayCellVisual's geometry/color mapping to BoxStyle
pub fn dayCellBoxStyle(visual: DayCellVisual) core.BoxStyle {
    return .{
        .width = .{ .px = day_cell_size },
        .height = .{ .px = day_cell_size },
        .justify = .center,
        .align_items = .center,
        .background = visual.bg_color,
        .border = .{ .overlay = true, .width = visual.border_width, .color = visual.border_color, .radius = visual.corner_radius.resolve() },
    };
}

/// Month nav button: transparent at rest, bg_hover under the pointer (eased like every control).
pub const navButton = @import("../../css.zig").css(.{
    .width = 32,
    .height = 32,
    .direction = .row,
    .justify = .center,
    .align_items = .center,
    .background = .transparent,
    .corner_radius = .control,
    .cursor = .pointer,
    .transition = @import("../../recipe.zig").transition("background 150ms ease-out"),
    ._hover = .{ .background = .bg_hover },
});

pub const DayCellVisual = struct {
    bg_color: Color,
    text_color: Color,
    border_width: f32,
    border_color: Color,
    corner_radius: core.CornerRadius,
    font_weight: u16,
    hover_enabled: bool,
};

pub fn computeDayCellVisual(state: *const DateRangePickerState, date: SimpleDate, in_current_month: bool) DayCellVisual {
    const t = state.cx.tokens;
    const resolved_end = mod.effectiveRangeEnd(state.start_date, state.end_date, state.preview_end_date);
    const is_start = if (state.start_date) |d| d.eql(date) else false;
    const is_end = if (resolved_end) |d| d.eql(date) else false;
    const preview = is_end and state.end_date == null and state.preview_end_date != null;
    const is_today = if (state.today_date) |d| d.eql(date) else false;
    const in_range = mod.isDateInRange(date, state.start_date, resolved_end);

    return .{
        .bg_color = if (is_start or (is_end and !preview))
            t.tokens.color.accent
        else if (in_range)
            t.tokens.color.selection_bg
        else
            Color.TRANSPARENT,
        .text_color = if (is_start or (is_end and !preview))
            t.tokens.color.fg_inverse
        else if (in_range)
            t.tokens.color.selection_fg
        else if (in_current_month)
            t.tokens.color.fg_primary
        else
            t.tokens.color.fg_tertiary,
        .border_width = if (preview or (is_today and !(is_start or is_end or in_range))) 1 else 0,
        .border_color = if (preview) t.tokens.color.accent else t.tokens.color.border_strong,
        .corner_radius = if (preview or (is_start and mod.dayOfWeek(date.year, date.month, date.day) == 6) or (is_end and mod.dayOfWeek(date.year, date.month, date.day) == 0))
            core.CornerRadius.uniform(t.tokens.radius.md)
        else if (is_start and is_end)
            core.CornerRadius.uniform(t.tokens.radius.md)
        else if (is_start)
            core.CornerRadius{ .each = .{ t.tokens.radius.md, 0, 0, t.tokens.radius.md } }
        else if (is_end)
            core.CornerRadius{ .each = .{ 0, t.tokens.radius.md, t.tokens.radius.md, 0 } }
        else if (in_range)
            core.CornerRadius.uniform(0)
        else
            core.CornerRadius.uniform(t.tokens.radius.md),
        .font_weight = if (is_start or (is_end and !preview) or is_today) 600 else 400,
        .hover_enabled = !(is_start or is_end or in_range),
    };
}

// RxE0k / Q9ZBB: 552px month strip and 52px confirmation footer.
pub fn monthsStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .direction = .row };
}
pub fn footerStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .border_overlay = true, .width = .{ .grow = .{} }, .height = .{ .px = 52 }, .direction = .row, .align_items = .center, .gap = 8, .padding = Padding.symmetric(12, 16), .border_top_width = 1, .border_color = t.tokens.color.border };
}
pub fn footerTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .font_size = t.tokens.font_size.md, .color = t.tokens.color.fg_primary };
}
pub fn footerButtonStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .height = .{ .px = 28 }, .padding = Padding.symmetric(0, 12) };
}

pub fn footerSummaryStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .width = .{ .grow = .{ .min = 0 } }, .overflow_hidden = true };
}

pub fn triggerForeground(has_value: bool, disabled: bool, t: *const theme.ThemeTokens) Color {
    return if (disabled) t.tokens.color.fg_disabled else if (has_value) t.tokens.color.fg_primary else t.tokens.color.fg_tertiary;
}
