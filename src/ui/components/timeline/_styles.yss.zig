// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Timeline styles: status determines dot / connector color and title color / font-weight; all
//! colors reference tokens.
//! View in timeline.yix; TimelineStatus is public API defined in mod.zig.
const ui = @import("../../ui.zig");

pub const dot_size: f32 = 10;

/// One row: indicator column (dot + connector), content column (title / description / time)
pub const Row = ui.sva(.{ .slots = .{ .dot, .line, .title, }, .base = .{ .dot = .{ .width = 10, .height = 10, .corner_radius = ui.tokenRef(.radius, "full"), }, .line = .{ .width = 1, .height = .{ .grow = .{} }, }, .title = .{ .font_size = ui.tokenRef(.font_size, "md"), }, }, .variants = .{ .status = .{ .completed = .{ .dot = .{ .background = ui.tokenRef(.color, "success"), }, .line = .{ .background = ui.tokenRef(.color, "border"), }, .title = .{ .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 400, }, }, .active = .{ .dot = .{ .background = ui.tokenRef(.color, "accent"), }, .line = .{ .background = ui.tokenRef(.color, "border"), }, .title = .{ .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 600, }, }, .pending = .{ .dot = .{ .background = ui.tokenRef(.color, "border"), }, .line = .{ .background = ui.tokenRef(.color, "border"), }, .title = .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_weight = 400, }, }, }, }, .defaults = .{ .status = .pending, }, });

pub const list = ui.previewCss("src/ui/components/timeline/styles.yss", "list", @embedFile("styles.yss"), .{ .width = .{ .grow = .{} }, .height = .fit, .direction = .column, });
pub const row = ui.previewCss("src/ui/components/timeline/styles.yss", "row", @embedFile("styles.yss"), .{ .width = .fill, .height = .{ .fit = .{ .min = 48 } }, .gap = 12, });
pub const indicator = ui.previewCss("src/ui/components/timeline/styles.yss", "indicator", @embedFile("styles.yss"), .{ .width = 24, .height = .{ .grow = .{} }, .direction = .column, .align_items = .center, });

/// Content column; last row has no bottom padding
pub const Content = ui.previewCva("src/ui/components/timeline/styles.yss", "Content", @embedFile("styles.yss"), .{ .base = .{ .width = .fill, .height = .fit, .no_cross_stretch = true, .direction = .column, .gap = 2, .padding = .{ .top = 0, .right = 0, .bottom = 16, .left = 0 }, }, .variants = .{ .last = .{ .false = .{ }, .true = .{ .padding = 0, }, }, }, .defaults = .{ .last = false, }, });

pub const description = ui.previewCss("src/ui/components/timeline/styles.yss", "description", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), });
pub const time = ui.previewCss("src/ui/components/timeline/styles.yss", "time", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-disabled"), .font_size = ui.tokenRef(.font_size, "xs"), });

//# yix-map styles.yss
