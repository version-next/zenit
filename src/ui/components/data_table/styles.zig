//! DataTable 样式层 — 全部视觉决策集中在这里，mod.zig 的 mount 只消费。
const core = @import("../../core.zig");
const Padding = core.Padding;

pub fn dataTableRootStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 8,
    };
}

pub fn dataTableBorderWrapStyle(w: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{} },
        .direction = .column,
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = t.radius.sm },
        .padding = Padding.all(1),
    };
}

pub fn dataTableHeaderStyle(header_height: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = header_height },
        .direction = .row,
        .align_items = .center,
        .background = t.color.bg_secondary,
    };
}

pub fn dataTableHeaderCellStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn dataTableHeaderTextProps(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = 13,
        .font_weight = 600,
    };
}

pub fn resizeHandleStyle() core.BoxStyle {
    return .{
        .width = .{ .px = 6 },
        .height = .{ .grow = .{} },
        .cursor = .ew_resize,
    };
}

/// 行底色三元组（选中 / 偶行 / 奇行），striped 决定奇行是否用 bg_secondary
pub const RowColors = struct { selection: core.Color, even: core.Color, odd: core.Color };

pub fn dataTableRowColors(striped: bool, t: *const core.ThemeTokens) RowColors {
    return .{
        .selection = t.color.list_selection_bg,
        .even = t.color.bg_primary,
        .odd = if (striped) t.color.bg_secondary else t.color.bg_primary,
    };
}

pub fn dataTableRowStyle(bg: core.Color, row_height: f32) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = row_height },
        .direction = .row,
        .align_items = .center,
        .background = bg,
    };
}

pub fn dataTableCellStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 12),
        .overflow_hidden = true,
    };
}

pub fn dataTableCellTextProps(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_primary,
        .font_size = 13,
    };
}

pub fn dataTablePagerStyle() core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
    };
}

pub fn dataTablePageLabelText(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "Page 1 / 1",
        .color = t.color.fg_secondary,
        .font_size = 13,
    };
}
