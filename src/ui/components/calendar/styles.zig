//! Calendar 样式层 — 具名样式函数与样式常量（zenit-styling-revamp）。
//! 迁移自 mount/buildGrid 的内联样式；数值原样保留。
//! mod.zig 只消费这些函数的返回值，不做内联样式与颜色决策。
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
        // 白底面板（与 Card / Popover 同一表面），日期格靠 hover / today / selected 区分。
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = 14 },
        .padding = Padding.all(20),
        .gap = 16,
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

pub fn navButtonStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 32 },
        .height = .{ .px = 32 },
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.separator, .radius = 8 },
    };
}

/// nav 按钮 hover 动画取色源（useAnimatedBackground）
pub fn navButtonAnimColors(t: *const theme.ThemeTokens) struct { normal: Color, hover: Color } {
    return .{ .normal = t.color.bg_hover, .hover = t.color.bg_active };
}

/// nav 按钮无 icon 资产时的 "<" / ">" 文本回退
pub fn navGlyphTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_secondary, .font_size = 14, .font_weight = 600 };
}

pub fn monthLabelTextStyle(t: *const theme.ThemeTokens) core.TextProps {
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

/// 日期格状态旗标 → dayCellStyle/dayTextStyle 的视觉决策输入
pub const DayCellFlags = struct {
    selected: bool,
    today: bool,
    keyboard_focus: bool,
    current_month: bool,
};

pub fn dayCellStyle(f: DayCellFlags, cell_size: f32, t: *const theme.ThemeTokens) core.BoxStyle {
    // 面板本身是白底：非选中格一律与面板同色，邻月日期只靠 fg_tertiary 文字区分。
    const bg: Color = if (f.selected) t.color.accent else t.color.bg_primary;
    // 键盘 focus 优先级 > today border > 普通；selected 自身已有强视觉，不画 ring
    const border_width: f32 = if (f.keyboard_focus and !f.selected)
        2
    else if (f.today and !f.selected)
        1
    else
        0;
    const border_color: Color = if (f.keyboard_focus and !f.selected)
        t.color.accent
    else if (f.today and !f.selected)
        t.color.border_strong
    else
        t.color.border;
    return .{
        .width = .{ .px = cell_size },
        .height = .{ .px = cell_size },
        .justify = .center,
        .align_items = .center,
        .background = bg,
        .border = .{ .width = border_width, .color = border_color, .radius = 10 },
    };
}

pub fn dayTextStyle(f: DayCellFlags, t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = if (f.selected)
            t.color.fg_inverse
        else if (f.current_month)
            t.color.fg_primary
        else
            t.color.fg_tertiary,
        .font_size = 13,
        .font_weight = if (f.selected) 600 else 400,
    };
}

pub fn dayHoverBg(current_month: bool, t: *const theme.ThemeTokens) Color {
    return if (current_month) t.color.bg_hover else Color.lerp(t.color.bg_primary, t.color.bg_hover, 0.55);
}
