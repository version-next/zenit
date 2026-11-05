// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Card styles: appearance = variant (default / outlined / elevated) x selected x hover-responsive;
//! all values reference tokens.
//! View in card.yix; CardVariant is public API defined in mod.zig.
const ui = @import("../../ui.zig");

/// Card root: when selected, 1px accent-border and no hover highlight; hover highlight changes
/// border color for outlined, background for others.
/// Background and border color changes via 120ms transition.
pub const Card = ui.previewCva("src/ui/components/card/styles.yss", "Card", @embedFile("styles.yss"), .{ .base = .{ .direction = .column, .background = ui.tokenRef(.color, "bg-primary"), .corner_radius = ui.tokenRef(.radius, "panel"), .transition = ui.transition("background 120ms ease-out, border-color 120ms ease-out"), }, .variants = .{ .kind = .{ .default = .{ .background = ui.tokenRef(.color, "bg-secondary"), .border_overlay = true, .border_width = 1, .border_color = ui.Color.TRANSPARENT, }, .outlined = .{ .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border"), }, .elevated = .{ .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border"), }, }, .selected = .{ .false = .{ }, .true = .{ .background = ui.tokenRef(.color, "accent-surface"), .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "accent-border"), }, }, .hoverable = .{ .false = .{ }, .true = .{ }, }, }, .defaults = .{ .kind = .default, .selected = false, .hoverable = false, }, .compound = .{ .{ .when = .{ .hoverable = true, .selected = false, .kind = .default, }, .style = .{ ._hover = .{ .background = ui.tokenRef(.color, "bg-active"), }, } }, .{ .when = .{ .hoverable = true, .selected = false, .kind = .elevated, }, .style = .{ ._hover = .{ .background = ui.tokenRef(.color, "bg-active"), }, } }, .{ .when = .{ .hoverable = true, .selected = false, .kind = .outlined, }, .style = .{ ._hover = .{ .border_color = ui.tokenRef(.color, "accent"), }, } }, }, });

/// Shrink to content when size not specified
pub const size = ui.paramStyle(struct { width: ?f32, height: ?f32, pub const declared = &[_][]const u8{ "width", "height", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = ui.orElse(args.width, .fit), .height = ui.orElse(args.height, .fit), }, t); } });

pub const header = ui.previewCss("src/ui/components/card/styles.yss", "header", @embedFile("styles.yss"), .{ .align_self = .stretch, .direction = .column, .gap = 2, .padding = .{ .top = 14, .right = 16, .bottom = 2, .left = 16 }, });
pub const title_row = ui.previewCss("src/ui/components/card/styles.yss", "title_row", @embedFile("styles.yss"), .{ .height = 18, });
pub const title = ui.previewCss("src/ui/components/card/styles.yss", "title", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = ui.tokenRef(.font_size, "md"), .font_weight = 600, });
pub const subtitle_row = ui.previewCss("src/ui/components/card/styles.yss", "subtitle_row", @embedFile("styles.yss"), .{ .height = 16, });
pub const subtitle = ui.previewCss("src/ui/components/card/styles.yss", "subtitle", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), });

/// Content area: children go here; when padded = false, flush to edges.
/// Under a header the body sits closer to it: the two read as one block, with no separator.
pub const Body = ui.previewCva("src/ui/components/card/styles.yss", "Body", @embedFile("styles.yss"), .{ .base = .{ .width = .{ .grow = .{} }, .direction = .column, }, .variants = .{ .padded = .{ .false = .{ }, .true = .{ .padding = .{ .y = 14, .x = 16 }, }, }, .headed = .{ .false = .{ }, .true = .{ }, }, }, .defaults = .{ .padded = true, .headed = false, }, .compound = .{ .{ .when = .{ .padded = true, .headed = true, }, .style = .{ .padding = .{ .top = 8, .right = 16, .bottom = 14, .left = 16 }, } }, }, });

/// Elevated cards are islands: xs contact shadow + md ambient shadow (Foundations 05).
pub fn elevation(kind: @import("mod.zig").CardVariant, t: *const ui.ThemeTokens) ui.BoxStyle {
    if (kind != .elevated) return .{};
    return .{ .shadows = ui.ShadowList.of(&.{ t.tokens.shadow.xs, t.tokens.shadow.md }) };
}

//# yix-map styles.yss
