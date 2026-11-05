// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Badge / StatusBadge styling: color, size, spacing, font all reference tokens.
//! View in badge.yix; BadgeStatus / BadgeSize are public API, defined in mod.zig.
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");

/// Badge: compact tonal counter (4px corners), label is text inside. status
/// determines bg and text color, size determines height / padding / font, dot
/// shrinks root to 8x8 dot.
pub const Badge = ui.sva(.{ .slots = .{ .root, .label, }, .base = .{ .root = .{ .width = .fit, .justify = .center, .align_items = .center, .corner_radius = ui.tokenRef(.radius, "md"), }, .label = .{ .font_weight = 500, .line_height = 1.2, }, }, .variants = .{ .status = .{ .info = .{ .root = .{ .background = ui.tokenRef(.color, "accent-subtle"), }, .label = .{ .color = ui.tokenRef(.color, "accent"), }, }, .success = .{ .root = .{ .background = ui.tokenRef(.color, "success-subtle"), }, .label = .{ .color = ui.tokenRef(.color, "success"), }, }, .warning = .{ .root = .{ .background = ui.tokenRef(.color, "warning-subtle"), }, .label = .{ .color = ui.tokenRef(.color, "warning"), }, }, .@"error" = .{ .root = .{ .background = ui.tokenRef(.color, "danger-subtle"), }, .label = .{ .color = ui.tokenRef(.color, "danger"), }, }, }, .size = .{ .sm = .{ .root = .{ .height = ui.tokenRef(.size, "md"), .padding = .{ .y = ui.tokenRef(.space, "space50"), .x = ui.tokenRef(.space, "space150") }, }, .label = .{ .font_size = 10, }, }, .md = .{ .root = .{ .height = ui.tokenRef(.size, "lg"), .padding = .{ .y = ui.tokenRef(.space, "space0"), .x = ui.tokenRef(.space, "space200") }, }, .label = .{ .font_size = ui.tokenRef(.font_size, "xs"), }, }, }, .dot = .{ .false = .{ }, .true = .{ }, }, }, .defaults = .{ .status = .info, .size = .md, .dot = false, }, .compound = .{ .{ .when = .{ .dot = true, }, .style = .{ .root = .{ .width = 8, .height = 8, .padding = 0, .corner_radius = ui.tokenRef(.radius, "md"), }, } }, .{ .when = .{ .dot = true, .status = .info, }, .style = .{ .root = .{ .background = ui.tokenRef(.color, "accent"), }, } }, .{ .when = .{ .dot = true, .status = .success, }, .style = .{ .root = .{ .background = ui.tokenRef(.color, "success"), }, } }, .{ .when = .{ .dot = true, .status = .warning, }, .style = .{ .root = .{ .background = ui.tokenRef(.color, "warning"), }, } }, .{ .when = .{ .dot = true, .status = .@"error", }, .style = .{ .root = .{ .background = ui.tokenRef(.color, "danger"), }, } }, }, });

/// StatusBadge: status dot + label.
pub const status_row = ui.previewCss("src/ui/components/badge/styles.yss", "status_row", @embedFile("styles.yss"), .{ .width = .fit, .height = .fit, .direction = .row, .gap = ui.tokenRef(.space, "space150"), .align_items = .center, });

/// 8x8 status dot (same size as Badge dot mode), bg color same as Badge status
pub const StatusDot = ui.previewCva("src/ui/components/badge/styles.yss", "StatusDot", @embedFile("styles.yss"), .{ .base = .{ .width = 8, .height = 8, .padding = 0, .corner_radius = 4, }, .variants = .{ .status = .{ .info = .{ .background = ui.tokenRef(.color, "accent"), }, .success = .{ .background = ui.tokenRef(.color, "success"), }, .warning = .{ .background = ui.tokenRef(.color, "warning"), }, .@"error" = .{ .background = ui.tokenRef(.color, "danger"), }, }, }, .defaults = .{ .status = .info, }, });

pub const status_label = ui.previewCss("src/ui/components/badge/styles.yss", "status_label", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = ui.tokenRef(.font_size, "sm"), });

// The root intentionally retains its text/test-id API. Its vertical inset now
// explicitly centers the line instead of relying on the old hidden paint offset.
pub const centered_label = ui.paramStyle(struct { size: mod.BadgeSize, dot: bool, pub const declared = &[_][]const u8{ "padding", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .padding = centeredLabelPadding(t, args.size, args.dot), }, t); } });
pub fn centeredLabelPadding(t: *const ui.theme.ThemeTokens, size: mod.BadgeSize, dot: bool) ui.Padding {
    if (dot) return ui.Padding.all(0);
    const height = if (size == .sm) t.tokens.size.md else t.tokens.size.lg;
    const font_size = if (size == .sm) 10 else t.tokens.font_size.xs;
    const original_y = if (size == .sm) t.tokens.space.space50 else 0;
    const x = if (size == .sm) t.tokens.space.space150 else t.tokens.space.space200;
    return ui.Padding.symmetric(@max(original_y, (height - font_size * 1.2) / 2), x);
}

//# yix-map styles.yss
