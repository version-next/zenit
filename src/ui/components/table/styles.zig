//! Table 样式层，全部视觉决策集中在这里，mod.zig 的 mount/render 只消费。
//! 直接渲染与虚拟滚动两条路径共用同一组样式函数。
const core = @import("../../core.zig");
const Color = core.Color;
const Padding = core.Padding;
const mod = @import("mod.zig");
const ColumnAlign = mod.ColumnAlign;
const ColumnDef = mod.ColumnDef;

pub fn colJustify(a: ColumnAlign) core.JustifyContent {
    return switch (a) {
        .left => .start,
        .center => .center,
        .right => .end,
    };
}

pub fn tableBorderWrapStyle(w: f32, h: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .px = h },
        .direction = .column,
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = t.radius.sm },
        .padding = Padding.all(1),
    };
}

pub fn tableInnerStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .background = t.color.bg_primary,
        .overflow_hidden = true,
    };
}

pub fn tableHeaderRowStyle(header_height: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = header_height },
        .direction = .row,
        .align_items = .center,
        .background = t.color.bg_secondary,
        .border = .{ .width = 1, .color = t.color.separator },
    };
}

pub fn tableHeaderCellStyle(col: ColumnDef) core.BoxStyle {
    return .{
        .width = .{ .px = col.width },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .justify = colJustify(col.col_align),
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn tableHeaderTextProps(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = t.font_size.xs,
        .font_weight = 600,
    };
}

pub fn sortIndicatorBoxStyle() core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .padding = Padding.symmetric(0, 4),
    };
}

pub fn sortIndicatorText(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_disabled,
        .font_size = 8,
    };
}

/// 行常态底色（striped 时奇数行用 bg_secondary）
pub fn tableRowBg(striped: bool, is_even: bool, t: *const core.ThemeTokens) Color {
    return if (striped and !is_even) t.color.bg_secondary else Color.TRANSPARENT;
}

pub fn tableRowStyle(row_bg: Color, row_height: f32) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = row_height },
        .direction = .row,
        .align_items = .center,
        .background = row_bg,
    };
}

pub fn tableCellStyle(col: ColumnDef) core.BoxStyle {
    return .{
        .width = .{ .px = col.width },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .justify = colJustify(col.col_align),
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn tableSeparatorStyle(separator_color: Color) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 1 },
        .background = separator_color,
    };
}
