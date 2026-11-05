// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! yix_counter styles (separated from counter.yix interface structure). Token names by field
//! category in examples/theme.json, typos are compile errors.
const ui = @import("ui");

pub const root = ui.previewCss("examples/yix_counter/styles.yss", "root", @embedFile("styles.yss"), .{ .width = .fill, .height = .fill, .direction = .column, .gap = ui.tokenRef(.space, "space300"), .padding = ui.tokenRef(.space, "space1000"), .background = ui.tokenRef(.color, "bg-primary"), .align_items = .center, .justify = .center, });
pub const title = ui.previewCss("examples/yix_counter/styles.yss", "title", @embedFile("styles.yss"), .{ .typography = ui.tokenRef(.typography, "counterTitle"), });
/// App's own counterValue token (18px)
pub const counter_text = ui.previewCss("examples/yix_counter/styles.yss", "counter_text", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "counterValue"), });
pub const derived_text = ui.previewCss("examples/yix_counter/styles.yss", "derived_text", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), });
pub const button_row = ui.previewCss("examples/yix_counter/styles.yss", "button_row", @embedFile("styles.yss"), .{ .gap = ui.tokenRef(.space, "space200"), });

/// Even/odd badge: business gives even, recipe manages background and hover
pub const Badge = ui.previewCva("examples/yix_counter/styles.yss", "Badge", @embedFile("styles.yss"), .{ .base = .{ .padding = .{ .y = ui.tokenRef(.space, "space100"), .x = ui.tokenRef(.space, "space300") }, .corner_radius = ui.tokenRef(.radius, "full"), .background = ui.tokenRef(.color, "bg-secondary"), .border_width = ui.tokenRef(.border_width, "thin"), .border_color = ui.tokenRef(.color, "border"), ._hover = .{ .opacity = 0.8, }, }, .variants = .{ .even = .{ .false = .{ }, .true = .{ .background = ui.tokenRef(.color, "success-subtle"), .border_color = ui.tokenRef(.color, "success"), }, }, }, .defaults = .{ .even = false, }, });
pub const badge_text = ui.previewCss("examples/yix_counter/styles.yss", "badge_text", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "sm"), .font_weight = ui.tokenRef(.font_weight, "semibold"), });

//# yix-map styles.yss
