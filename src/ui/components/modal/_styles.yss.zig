// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Modal styles: dialog panel, title bar, close button, body. Panel view in modal.yix, popover /
//! focus trap / animation in mod.zig.
const ui = @import("../../ui.zig");

/// Dialog panel: design radius.dialog, 1px border and shadow.lg.
pub const dialog = ui.paramStyle(struct { width: f32, max_height: f32, background: ?ui.Color = null, pub const declared = &[_][]const u8{ "width", "height", "background", "direction", "corner_radius", "border_overlay", "border_width", "border_color", "shadow", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = args.width, .height = .{ .fit = .{ .max = args.max_height } }, .background = ui.orElse(args.background, ui.tokenRef(.color, "bg-primary")), .direction = .column, .corner_radius = ui.tokenRef(.radius, "dialog"), .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border"), .shadow = ui.tokenRef(.shadow, "lg"), }, t); } });

/// Title bar: title + close button space-between
pub const header = ui.previewCss("src/ui/components/modal/styles.yss", "header", @embedFile("styles.yss"), .{ .direction = .row, .justify = .space_between, .align_items = .center, .gap = ui.tokenRef(.space, "space300"), .padding = .{ .top = 16, .right = 12, .bottom = 0, .left = 20 }, .width = .{ .grow = .{} }, .background = ui.Color.TRANSPARENT, .border_overlay = true, .border_bottom_width = 1, .border_color = ui.tokenRef(.color, "border"), });
pub fn title(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.xl, .font_weight = 600, .line_height = 1.25, .wrap = .word_break };
}
/// Close button: 28x28
pub const close_button = ui.previewCss("src/ui/components/modal/styles.yss", "close_button", @embedFile("styles.yss"), .{ .width = 28, .height = 28, .background = ui.Color.TRANSPARENT, .justify = .center, .align_items = .center, .corner_radius = ui.tokenRef(.radius, "control"), ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, });
/// Text X fallback when no icon asset (28x28, same geometry as close button, no corner radius)
pub const close_glyph_box = ui.previewCss("src/ui/components/modal/styles.yss", "close_glyph_box", @embedFile("styles.yss"), .{ .width = 28, .height = 28, .background = ui.Color.TRANSPARENT, .justify = .center, .align_items = .center, });
pub const close_glyph = ui.previewCss("src/ui/components/modal/styles.yss", "close_glyph", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = 14, });
pub const body = ui.previewCss("src/ui/components/modal/styles.yss", "body", @embedFile("styles.yss"), .{ .direction = .column, .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .padding = .{ .top = 8, .right = 20, .bottom = 20, .left = 20 }, .gap = ui.tokenRef(.space, "space400"), });
pub const close_icon = ui.previewCss("src/ui/components/modal/styles.yss", "close_icon", @embedFile("styles.yss"), .{ .width = 18, .height = 18, .icon_color = ui.tokenRef(.color, "fg-secondary"), });


pub fn headerCorners(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .corner_radii = .{ .each = .{ t.tokens.radius.dialog, t.tokens.radius.dialog, 0, 0 } } };
}

//# yix-map styles.yss
