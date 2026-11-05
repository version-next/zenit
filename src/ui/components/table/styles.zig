//! Table style layer, all visual decisions here, mod.zig's mount/render only consume.
//! Direct render and virtual scroll paths share same style functions.
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
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.control },
        .padding = Padding.all(1),
    };
}

pub fn tableInnerStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .background = t.tokens.color.bg_primary,
        .overflow_hidden = true,
    };
}

pub fn tableHeaderRowStyle(header_height: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = header_height },
        .direction = .row,
        .align_items = .center,
        .background = t.tokens.color.table_header_bg,
        .border_overlay = true,
        .border_bottom_width = 1,
        .border_color = t.tokens.color.border,
    };
}

pub fn tableHeaderCellStyle(col: ColumnDef) core.BoxStyle {
    return .{
        .width = .{ .px = col.width },
        .height = .{ .grow = .{} },
        .align_self = .stretch,
        .direction = .row,
        .align_items = .center,
        .justify = colJustify(col.col_align),
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn tableHeaderTextStyle(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_tertiary,
        .font_size = t.tokens.font_size.sm,
        .font_weight = 500,
    };
}

pub fn sortIndicatorBoxStyle() core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .padding = Padding.symmetric(0, 4),
    };
}

pub fn sortIndicatorText(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_disabled,
        .font_size = 8,
    };
}

/// Row default background (striped uses bg_secondary for odd rows)
pub fn tableRowBg(striped: bool, is_even: bool, t: *const core.ThemeTokens) Color {
    return if (striped and !is_even) t.tokens.color.bg_secondary else Color.TRANSPARENT;
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

/// Hoverable row: bg_active under the pointer, eased like every control (150ms ease-out). The
/// fill replaces the row's own, and bg_hover over the page matches a striped row's bg_secondary.
pub const rowHover = @import("../../css.zig").css(.{ .background = .bg_active });
pub const rowFade = @import("../../css.zig").css(.{ .transition = @import("../../recipe.zig").transition("background 150ms ease-out") });

pub fn tableCellStyle(col: ColumnDef) core.BoxStyle {
    return .{
        .width = .{ .px = col.width },
        .height = .{ .grow = .{} },
        .align_self = .stretch,
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
