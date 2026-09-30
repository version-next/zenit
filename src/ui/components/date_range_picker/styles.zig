//! DateRangePicker 样式层（zenit-styling-revamp）：
//! trigger/panel/月面板/日期格样式函数 + 交互态取色纯函数 +
//! day cell 状态取色矩阵（DayCellVisual / computeDayCellVisual）。
//! 依赖 mod.zig 的 State 与日期比较逻辑（循环 import，Zig 惰性分析允许）。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;
const mod = @import("mod.zig");
const DateRangePickerState = mod.DateRangePickerState;
const SimpleDate = @import("../calendar/mod.zig").SimpleDate;

// ========== 具名样式函数（样式层） ==========
// 迁移自 mount/mountMonthSection/buildMonthGrid/updateDisplayLabel/syncTriggerVisual
// 的内联样式与颜色决策；数值原样保留（zenit-styling-revamp）。
// day cell 的状态取色矩阵本就在 computeDayCellVisual（纯函数样式层），不动。

pub const nav_icon_size: f32 = 16;
pub const panel_radius: f32 = 14;
pub const day_cell_size: f32 = 32;
pub const day_font_size: f32 = 13;

pub fn triggerBorderColor(open: bool, has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.color.border_focus else if (has_value) t.color.border_strong else t.color.border;
}

pub fn leadingIconTint(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.color.fg_secondary else t.color.fg_tertiary;
}

pub fn chevronTint(open: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.color.accent else t.color.fg_tertiary;
}

pub fn valueTextColor(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.color.fg_primary else t.color.fg_tertiary;
}

pub fn dashColor(has_any_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_any_value) t.color.fg_secondary else t.color.fg_tertiary;
}



pub fn rangeTextStyle(t: *const theme.ThemeTokens, cm: theme.ControlMetrics) core.TextProps {
    return .{ .content = "", .color = t.color.fg_tertiary, .font_size = cm.font_size, .line_height = cm.line_height };
}

pub fn panelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = panel_radius },
        .shadow = Shadow{ .color = Color.rgba(0, 0, 0, 18), .blur = 24, .offset_x = 0, .offset_y = 8 },
    };
}

pub fn panelDividerStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 1 },
        .height = .{ .grow = .{} },
        .background = t.color.border,
    };
}

pub fn monthSectionStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 300 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 16,
        .padding = Padding.all(20),
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

pub fn monthTitleTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_primary, .font_size = 14, .font_weight = 600 };
}

pub fn weekdayCellStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 34 },
        .height = .{ .px = 28 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn weekdayTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_tertiary, .font_size = 11, .font_weight = 600 };
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

/// day cell 的 box 样式 = computeDayCellVisual 的几何/取色落到 BoxStyle
pub fn dayCellBoxStyle(visual: DayCellVisual) core.BoxStyle {
    return .{
        .width = .{ .px = day_cell_size },
        .height = .{ .px = day_cell_size },
        .justify = .center,
        .align_items = .center,
        .background = visual.bg_color,
        .border = .{ .width = visual.border_width, .color = visual.border_color, .radius = visual.corner_radius.resolve() },
    };
}

pub fn iconBtnStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 32 },
        .height = .{ .px = 32 },
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .background = t.color.bg_hover,
        .border = .{ .width = 0, .color = t.color.border, .radius = 8 },
    };
}

/// 月份导航按钮 hover 动画取色源（useAnimatedBackground）
pub fn iconBtnAnimColors(t: *const theme.ThemeTokens) struct { normal: Color, hover: Color } {
    return .{ .normal = t.color.bg_hover, .hover = t.color.bg_active };
}

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
    const is_today = if (state.today_date) |d| d.eql(date) else false;
    const in_range = mod.isDateInRange(date, state.start_date, resolved_end);

    return .{
        .bg_color = if (is_start or is_end)
            t.color.accent
        else if (in_range)
            t.color.accent_subtle
        else
            Color.TRANSPARENT,
        .text_color = if (is_start or is_end)
            t.color.fg_inverse
        else if (in_range)
            t.color.accent
        else if (in_current_month)
            t.color.fg_primary
        else
            t.color.fg_tertiary,
        .border_width = if (is_today and !(is_start or is_end)) 1 else 0,
        .border_color = t.color.accent,
        .corner_radius = if (is_start and is_end)
            core.CornerRadius.uniform(10)
        else if (is_start)
            core.CornerRadius{ .each = .{ 10, 0, 0, 10 } }
        else if (is_end)
            core.CornerRadius{ .each = .{ 0, 10, 10, 0 } }
        else if (in_range)
            core.CornerRadius.uniform(0)
        else
            core.CornerRadius.uniform(10),
        .font_weight = if (is_start or is_end or is_today) 600 else 400,
        .hover_enabled = !(is_start or is_end or in_range),
    };
}
