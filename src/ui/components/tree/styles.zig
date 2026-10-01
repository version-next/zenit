/// Tree，样式层
///
/// 具名样式函数；业务逻辑/State/事件处理在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

pub fn treeContainerStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    };
}

pub fn treeRowStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 4),
        .background = Color.TRANSPARENT,
    };
}

/// 选中行背景，由 applySelectionStyles 运行时驱动
pub fn treeSelectionBg(t: *const theme.ThemeTokens) Color {
    return t.color.list_selection_bg;
}

pub fn treeIndicatorBoxStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
        .justify = .center,
        .align_items = .center,
    };
}

// iconTint 的 style 参数是 core.Style（非 BoxStyle），返回类型跟随
pub fn treeExpandIconStyle(_: *const theme.ThemeTokens) core.Style {
    return .{
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
    };
}

pub fn treeIndicatorTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = 8,
    };
}

pub fn treeLabelBoxStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .padding = Padding.symmetric(0, 4),
    };
}

pub fn treeLabelTextStyle(disabled: bool, t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = if (disabled) t.color.fg_disabled else t.color.fg_primary,
        .font_size = t.font_size.sm,
    };
}
