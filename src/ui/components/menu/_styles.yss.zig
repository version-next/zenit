// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Menu styles: menu item recipe (danger variant + hover highlight + disabled state) and panel /
//! divider / inline layout.
//! View in menu.yix; popover, keyboard nav and selection pipeline in mod.zig.
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

/// Menu item: root (row, hover / keyboard virtual highlight use list-hover-bg), label (text), icon
/// (icon, color follows text).
/// lit is menu's current virtual highlight (pointer enter and keyboard move both write it); danger
/// is per-item kind; disabled overrides danger and highlight.
pub const MenuRow = ui.sva(.{ .slots = .{ .root, .label, .icon, }, .base = .{ .root = .{ .width = .{ .grow = .{} }, .height = 28, .direction = .row, .align_items = .center, .justify = .space_between, .padding = .{ .y = 0, .x = ui.tokenRef(.space, "space200") }, .corner_radius = ui.tokenRef(.radius, "md"), .background = ui.Color.TRANSPARENT, }, .label = .{ .font_size = ui.tokenRef(.font_size, "md"), .color = ui.tokenRef(.color, "fg-primary"), }, .icon = .{ .width = 16, .height = 16, .icon_color = ui.tokenRef(.color, "fg-primary"), }, }, .variants = .{ .danger = .{ .false = .{ }, .true = .{ .label = .{ .color = ui.tokenRef(.color, "danger"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "danger"), }, }, }, .lit = .{ .false = .{ }, .true = .{ }, }, .disabled = .{ .false = .{ .root = .{ .cursor = .pointer, }, }, .true = .{ .label = .{ .color = ui.tokenRef(.color, "fg-disabled"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "fg-disabled"), }, }, }, }, .defaults = .{ .danger = false, .lit = false, .disabled = false, }, .compound = .{ .{ .when = .{ .lit = true, .disabled = false, }, .style = .{ .root = .{ .background = ui.tokenRef(.color, "bg-hover"), }, } }, }, });

/// Item list in panel
pub const list = ui.previewCss("src/ui/components/menu/styles.yss", "list", @embedFile("styles.yss"), .{ .width = .{ .grow = .{} }, .height = .fit, .direction = .column, .padding = 4, });

/// Divider outer: vertical padding, line itself 1px
pub const separator = ui.previewCss("src/ui/components/menu/styles.yss", "separator", @embedFile("styles.yss"), .{ .width = .{ .grow = .{} }, .height = .fit, .padding = .{ .y = 4, .x = 0 }, });
pub const separator_line = ui.previewCss("src/ui/components/menu/styles.yss", "separator_line", @embedFile("styles.yss"), .{ .width = .{ .grow = .{} }, .height = 1, .background = ui.tokenRef(.color, "separator"), });
pub const item_left = ui.previewCss("src/ui/components/menu/styles.yss", "item_left", @embedFile("styles.yss"), .{ .width = .fit, .height = .fit, .direction = .row, .align_items = .center, .gap = 8, });
pub const shortcut = ui.previewCss("src/ui/components/menu/styles.yss", "shortcut", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "xs"), });

/// Body text line height from COMPONENTS.json Menu rows.
pub fn rowText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.tokens.font_size.md, .line_height = 1.4, .color = t.tokens.color.fg_primary };
}

/// Menu uses aria-activedescendant: the keyboard ring follows the virtual row,
/// while pointer highlight only paints bg-hover. Foundations: 2px ring + 2px offset.
pub const virtual_focus = ui.paramStyle(struct { visible: bool, pub const declared = &[_][]const u8{ "outline", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out: ui.BoxStyle = .{}; if (args.visible) out = out.merge(ui.boxFrom(.{ .outline = ui.Outline{ .color = t.tokens.color.focus_ring, .width = t.tokens.border_width.focus, .offset = t.tokens.size.focus_offset }, }, t)); return out; } });

//# yix-map styles.yss
