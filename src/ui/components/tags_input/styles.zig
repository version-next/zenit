const css = @import("../../css.zig").css;
pub const shell = css(.{ .padding = .space200, .background = .bg_primary, .border_overlay = true, .border_width = 1, .border_color = .border_strong, .corner_radius = .control });
pub const chip = css(.{ .align_items = .center, .height = 24, .corner_radius = .md, .padding = .{ .x = .space200, .y = 0 }, .gap = .space100, .background = .bg_secondary, .border_overlay = true, .border_width = 0, .font_size = .sm });

pub const chipText = css(.{ .font_size = .sm, .font_weight = .regular, .color = .fg_primary });
pub const closeButton = css(.{ .width = 12, .height = 12, .cursor = .pointer, .align_items = .center, .justify = .center, ._hover = .{ .background = .bg_hover } });
pub const closeIcon = css(.{ .width = 12, .height = 12 });

const core = @import("../../core.zig");
pub fn inputRow(show_add: bool, t: *const core.ThemeTokens) core.BoxStyle {
    return .{ .direction = .row, .width = .{ .grow = .{} }, .height = if (show_add) .{ .fit = .{} } else .{ .px = t.tokens.size.row }, .gap = t.tokens.space.space150, .align_items = .center };
}
