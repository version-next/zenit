/// ComboBox — 样式层
///
/// 具名样式函数与共享几何常量；业务逻辑/State/portal 挂载在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;

/// Pvnqs / Select option: 14px 文本 + 8px 上下内边距。
/// 面板滚动几何（ComboBoxState.item_h）与行样式共用。
pub const combo_item_height: f32 = 36;

/// Pvnqs / Select panel chrome。
pub fn comboPanelRadius(t: *const theme.ThemeTokens) f32 {
    return t.radius.xl;
}

pub fn comboPanelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    const radius = comboPanelRadius(t);
    return .{
        .direction = .column,
        .gap = 2,
        .padding = core.Padding.all(4),
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = radius },
        .corner_radius = radius,
        .shadow = .{
            .color = core.Color.rgba(0, 0, 0, 18),
            .blur = 12,
            .offset_x = 0,
            .offset_y = 4,
        },
    };
}

pub fn comboItemStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .row,
        .width = .{ .grow = .{} },
        .height = .{ .px = combo_item_height },
        .padding = core.Padding.symmetric(8, 12),
        .justify = .space_between,
        .align_items = .center,
        .overflow_hidden = true,
        .corner_radius = t.radius.lg,
    };
}

/// 空态行 — 与 option 行同款几何但初始收起（height 0）
pub fn comboEmptyStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    var s = comboItemStyle(t);
    s.justify = .center;
    s.display = .none; // 默认收起；applyFilter 按匹配数切换
    return s;
}

pub fn comboItemTextStyle(disabled: bool, t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = if (disabled) t.color.fg_disabled else t.color.fg_primary,
        .font_size = 14,
    };
}

pub fn comboEmptyTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "No results found",
        .color = t.color.fg_tertiary,
        .font_size = 14,
    };
}

/// 键盘/hover 高亮行背景 — 运行时由 highlight 逻辑驱动
pub fn comboHighlightBg(t: *const theme.ThemeTokens) core.Color {
    return t.color.list_hover_bg;
}
