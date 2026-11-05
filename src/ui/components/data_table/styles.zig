//! DataTable style layer, all visual decisions here, mod.zig's mount only consumes.
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
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.control },
        .padding = Padding.all(1),
    };
}

pub fn dataTableHeaderStyle(header_height: f32, t: *const core.ThemeTokens) core.BoxStyle {
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

pub fn dataTableHeaderCellStyle(w: f32) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .grow = .{} },
        .align_self = .stretch,
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 12),
    };
}

pub fn dataTableHeaderTextStyle(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_tertiary,
        .font_size = t.tokens.font_size.sm,
        .font_weight = 500,
    };
}

pub fn resizeHandleStyle() core.BoxStyle {
    return .{
        .width = .{ .px = 6 },
        .height = .{ .grow = .{} },
        .align_self = .stretch,
        .cursor = .ew_resize,
    };
}

/// Row background triple (selected / even / odd), striped determines if odd uses bg_secondary
pub const RowColors = struct { selection: core.Color, even: core.Color, odd: core.Color };

pub fn dataTableRowColors(striped: bool, t: *const core.ThemeTokens) RowColors {
    return .{
        .selection = t.tokens.color.selection_bg,
        .even = t.tokens.color.bg_primary,
        .odd = if (striped) t.tokens.color.bg_secondary else t.tokens.color.bg_primary,
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
        .align_self = .stretch,
        .direction = .row,
        .align_items = .center,
        .padding = Padding.symmetric(0, 12),
        .overflow_hidden = true,
    };
}

pub fn dataTableCellTextStyle(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_primary,
        .font_size = t.tokens.font_size.md,
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

pub fn dataTablePageLabelText(t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_secondary,
        .font_size = t.tokens.font_size.md,
    };
}

pub fn dataTableRowTextColor(selected: bool, t: *const core.ThemeTokens) core.Color {
    return if (selected) t.tokens.color.selection_fg else t.tokens.color.fg_primary;
}

pub fn rowVisual(normal: core.Color, selected: bool, hovered: bool, t: *const core.ThemeTokens) core.BoxStyle {
    const recipe = core.ConditionalStyle{ .base = .{ .background = normal }, .selected = .{ .background = t.tokens.color.selection_bg }, .hover = .{ .background = if (selected) t.tokens.color.list_selection_hover_bg else t.tokens.color.bg_active } };
    return recipe.resolve(.{ .is_selected = selected, .is_hovered = hovered });
}
