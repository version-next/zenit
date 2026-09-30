//! FileUpload 样式层 — wrapper/drop zone/文件行/移除按钮样式与 drop 悬停取色（zenit-styling-revamp）。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

// ========== 具名样式函数（样式层） ==========
// 迁移自 mountFileUpload/addFile/setDropHover 的内联样式与颜色决策；
// 数值原样保留（zenit-styling-revamp）。

pub fn wrapperStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 8,
    };
}

pub fn dropZoneStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    const colors = dropZoneColors(false, t);
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 72 },
        .direction = .column,
        .justify = .center,
        .align_items = .center,
        .gap = 6,
        .background = colors.bg,
        .border = .{ .width = 1, .color = colors.border, .radius = 8 },
    };
}

/// drop 悬停高亮的两态取色（setDropHover 消费）
pub fn dropZoneColors(hover_active: bool, t: *const theme.ThemeTokens) struct { bg: Color, border: Color } {
    return if (hover_active)
        .{ .bg = t.color.bg_hover, .border = t.color.accent }
    else
        .{ .bg = t.color.bg_secondary, .border = t.color.border };
}

pub fn hintTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_secondary, .font_size = 13 };
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
        .background = t.color.bg_secondary,
        .border = .{ .radius = 4 },
    };
}

pub fn fileNameTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_primary, .font_size = 13 };
}

pub fn removeBtnStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn removeGlyphTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_secondary, .font_size = 12 };
}
