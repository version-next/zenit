// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! text_input styles
const ui = @import("ui");

pub const root = ui.previewCss("examples/text_input/styles.yss", "root", @embedFile("styles.yss"), .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .gap = ui.tokenRef(.space, "space400"), .padding = ui.tokenRef(.space, "space800"), .background = ui.tokenRef(.color, "bg-primary"), });
pub const title = ui.previewCss("examples/text_input/styles.yss", "title", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "xxl"), .font_weight = 600, .color = ui.tokenRef(.color, "fg-primary"), });
pub const hint = ui.previewCss("examples/text_input/styles.yss", "hint", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "md"), .color = ui.tokenRef(.color, "fg-secondary"), });

//# yix-map styles.yss
