// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Divider styling. Geometry (direction, weight, dashed segment length and gap, margin,
//! color override) from component params; default color from `border-strong` token, label
//! text from `fg-secondary`, follows theme. View in divider.yix; public types like
//! DividerOrientation in mod.zig.
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");

/// Divider styles: solid / dashed dotted (fixed segments in row, container clips excess)
/// / with label (label at left/center/right).
pub const Kind = enum { solid, patterned, label_left, label_center, label_right };
/// Root node: solid is the line itself; dashed/dotted is container of clipped segments;
/// with label is "line + label + line" row. Margin: horizontal line top/bottom gaps,
/// vertical line left/right gaps; with label becomes top/bottom padding.
pub const root = ui.paramStyle(struct { kind: Kind, orientation: mod.DividerOrientation, thickness: f32, color: ?ui.Color, spacing: mod.DividerSpacing, dash_gap: f32, pub const declared = &[_][]const u8{ "width", "height", "margin", "align_self", "background", "align_items", "gap", "overflow_hidden", "direction", "padding", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out: ui.BoxStyle = .{}; if ((args.kind == .solid or args.kind == .patterned) and args.orientation == .horizontal) out = out.merge(ui.boxFrom(.{ .width = .{ .grow = .{} }, .height = args.thickness, .margin = .{ .y = args.spacing.value(), .x = 0 }, }, t)); if ((args.kind == .solid or args.kind == .patterned) and args.orientation == .vertical) out = out.merge(ui.boxFrom(.{ .width = args.thickness, .height = .{ .grow = .{} }, .align_self = .stretch, .margin = .{ .y = 0, .x = args.spacing.value() }, }, t)); if (args.kind == .solid) out = out.merge(ui.boxFrom(.{ .background = ui.orElse(args.color, ui.tokenRef(.color, "border-strong")), }, t)); if (args.kind == .patterned) out = out.merge(ui.boxFrom(.{ .align_items = .center, .gap = args.dash_gap, .overflow_hidden = true, }, t)); if (args.kind == .patterned and args.orientation == .horizontal) out = out.merge(ui.boxFrom(.{ .direction = .row, }, t)); if (args.kind == .patterned and args.orientation == .vertical) out = out.merge(ui.boxFrom(.{ .direction = .column, }, t)); if ((args.kind == .label_left or args.kind == .label_center or args.kind == .label_right)) out = out.merge(ui.boxFrom(.{ .width = .{ .grow = .{} }, .direction = .row, .align_items = .center, .gap = ui.tokenRef(.space, "space300"), .padding = .{ .y = args.spacing.value(), .x = 0 }, }, t)); return out; } });

/// Dashed / dotted segment (dotted uses circles with side=weight); doesn't flex-shrink or
/// compresses to 0.
pub const dash = ui.paramStyle(struct { orientation: mod.DividerOrientation, variant: mod.DividerVariant, thickness: f32, length: f32, color: ?ui.Color, pub const declared = &[_][]const u8{ "background", "flex_shrink", "width", "height", "corner_radius", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .background = ui.orElse(args.color, ui.tokenRef(.color, "border-strong")), .flex_shrink = 0, }, t); if (args.orientation == .horizontal) out = out.merge(ui.boxFrom(.{ .width = args.length, .height = args.thickness, }, t)); if (args.orientation == .vertical) out = out.merge(ui.boxFrom(.{ .width = args.thickness, .height = args.length, }, t)); if (args.variant == .dotted) out = out.merge(ui.boxFrom(.{ .corner_radius = args.thickness / 2, }, t)); if (args.variant == .dotted and args.orientation == .horizontal) out = out.merge(ui.boxFrom(.{ .width = args.thickness, }, t)); if (args.variant == .dotted and args.orientation == .vertical) out = out.merge(ui.boxFrom(.{ .height = args.thickness, }, t)); return out; } });

/// Line segments on label sides, split remaining width equally
pub const label_line = ui.paramStyle(struct { thickness: f32, color: ?ui.Color, pub const declared = &[_][]const u8{ "width", "height", "background", "flex", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = .{ .grow = .{} }, .height = args.thickness, .background = ui.orElse(args.color, ui.tokenRef(.color, "border-strong")), .flex = 1, }, t); } });

pub const label_text = ui.previewCss("src/ui/components/divider/styles.yss", "label_text", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), });

/// Dashed segment count: enough to cover common widths, excess clipped by container
pub const dash_count = 128;

//# yix-map styles.yss
