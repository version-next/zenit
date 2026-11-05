// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! devtools_probe styles
const ui = @import("ui");

pub const root = ui.previewCss("examples/devtools_probe/styles.yss", "root", @embedFile("styles.yss"), .{ .width = .fill, .height = .fill, .gap = ui.tokenRef(.space, "space300"), .padding = ui.tokenRef(.space, "space800"), .background = ui.tokenRef(.color, "bg-primary"), .align_items = .center, .justify = .center, });
pub const title = ui.previewCss("examples/devtools_probe/styles.yss", "title", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "xxl"), .font_weight = 600, .color = ui.tokenRef(.color, "fg-primary"), });
pub const hint = ui.previewCss("examples/devtools_probe/styles.yss", "hint", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "sm"), .color = ui.tokenRef(.color, "fg-secondary"), });

//# yix-map styles.yss
