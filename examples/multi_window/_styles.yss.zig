// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! multi_window styles
const ui = @import("ui");

pub const root = ui.previewCss("examples/multi_window/styles.yss", "root", @embedFile("styles.yss"), .{ .width = .fill, .height = .fill, .gap = ui.tokenRef(.space, "space400"), .padding = ui.tokenRef(.space, "space1000"), .background = ui.tokenRef(.color, "bg-primary"), .align_items = .center, .justify = .center, });
pub const heading = ui.previewCss("examples/multi_window/styles.yss", "heading", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "xxxl"), .font_weight = 600, .color = ui.tokenRef(.color, "fg-primary"), });
pub const caption = ui.previewCss("examples/multi_window/styles.yss", "caption", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "lg"), .color = ui.tokenRef(.color, "fg-secondary"), });

//# yix-map styles.yss
