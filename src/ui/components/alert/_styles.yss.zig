// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Alert styles: variant determines accent; background and border are accent toward bg-primary
//! blend.
//! View in alert.yix; AlertVariant is public API defined in mod.zig.
const ui = @import("../../ui.zig");



/// root: full alert (with title, content top-aligned, else centered); accent: leading status icon.
pub const Alert = ui.sva(.{ .slots = .{ .root, .accent, }, .base = .{ .root = .{ .width = .fill, .height = .fit, .direction = .row, .padding = 12, .border_overlay = true, .border_width = 1, .corner_radius = ui.tokenRef(.radius, "panel"), .gap = ui.tokenRef(.space, "space200"), }, .accent = .{ .width = 16, .height = 16, }, }, .variants = .{ .kind = .{ .info = .{ .root = .{ .background = ui.tokenRef(.color, "info-alert-bg"), .border_color = ui.Color.TRANSPARENT, }, .accent = .{ .icon_color = ui.tokenRef(.color, "info"), }, }, .success = .{ .root = .{ .background = ui.tokenRef(.color, "success-alert-bg"), .border_color = ui.Color.TRANSPARENT, }, .accent = .{ .icon_color = ui.tokenRef(.color, "success"), }, }, .warning = .{ .root = .{ .background = ui.tokenRef(.color, "warning-alert-bg"), .border_color = ui.Color.TRANSPARENT, }, .accent = .{ .icon_color = ui.tokenRef(.color, "warning"), }, }, .@"error" = .{ .root = .{ .background = ui.tokenRef(.color, "danger-alert-bg"), .border_color = ui.Color.TRANSPARENT, }, .accent = .{ .icon_color = ui.tokenRef(.color, "danger"), }, }, }, .titled = .{ .false = .{ .root = .{ .align_items = .center, }, }, .true = .{ .root = .{ .align_items = .start, }, }, }, }, .defaults = .{ .kind = .info, .titled = false, }, });

pub const status_alignment = ui.previewCss("src/ui/components/alert/styles.yss", "status_alignment", @embedFile("styles.yss"), .{ .width = 20, .height = 22, .justify = .center, .align_items = .center, });
pub const content = ui.previewCss("src/ui/components/alert/styles.yss", "content", @embedFile("styles.yss"), .{ .width = .fill, .height = .fit, .direction = .column, .gap = ui.tokenRef(.space, "space100"), });
pub const title = ui.previewCss("src/ui/components/alert/styles.yss", "title", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = ui.tokenRef(.font_size, "md"), .font_weight = 600, .line_height = 1.4, });
pub const message = ui.previewCss("src/ui/components/alert/styles.yss", "message", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "md"), .font_weight = 400, .line_height = 1.5, });

/// Close button: hover floats bg-hover (150ms fade-in)
pub const close = ui.previewCss("src/ui/components/alert/styles.yss", "close", @embedFile("styles.yss"), .{ .width = 24, .height = 24, .background = ui.Color.TRANSPARENT, .corner_radius = ui.tokenRef(.radius, "md"), .justify = .center, .align_items = .center, .cursor = .pointer, ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, .transition = ui.transition("background 150ms ease-out"), });
pub const close_label = ui.previewCss("src/ui/components/alert/styles.yss", "close_label", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "lg"), });
pub const close_icon = ui.previewCss("src/ui/components/alert/styles.yss", "close_icon", @embedFile("styles.yss"), .{ .width = 14, .height = 14, .icon_color = ui.tokenRef(.color, "fg-tertiary"), });

/// COMPONENTS Alert / * contextual action: 4px inset, 24px row, 14px icon.
pub const action_inset = ui.previewCss("src/ui/components/alert/styles.yss", "action_inset", @embedFile("styles.yss"), .{ .no_cross_stretch = true, .padding = .{ .top = ui.tokenRef(.space, "space100"), .right = 0, .bottom = 0, .left = 0 }, });
pub const action_root = ui.previewCss("src/ui/components/alert/styles.yss", "action_root", @embedFile("styles.yss"), .{ .no_cross_stretch = true, .height = 24, .width = .fit, .gap = ui.tokenRef(.space, "space150"), .align_items = .center, .corner_radius = ui.tokenRef(.radius, "md"), .cursor = .pointer, ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, ._active = .{ .background = ui.tokenRef(.color, "button-pressed-bg"), }, });
pub const Action = ui.sva(.{ .slots = .{ .label, .icon, }, .base = .{ .label = .{ .font_size = ui.tokenRef(.font_size, "sm"), .font_weight = 500, .line_height = 1.2, }, .icon = .{ .width = 14, .height = 14, }, }, .variants = .{ .kind = .{ .info = .{ .label = .{ .color = ui.tokenRef(.color, "info"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "info"), }, }, .success = .{ .label = .{ .color = ui.tokenRef(.color, "success"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "success"), }, }, .warning = .{ .label = .{ .color = ui.tokenRef(.color, "warning"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "warning"), }, }, .@"error" = .{ .label = .{ .color = ui.tokenRef(.color, "danger"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "danger"), }, }, }, }, .defaults = .{ .kind = .info, }, });

//# yix-map styles.yss
