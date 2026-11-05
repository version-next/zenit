// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Stack styles: layout entirely from props (gap, alignment, size, padding, background, wrap). View
//! in stack.yix.
const ui = @import("../../ui.zig");

/// Stack: shrinks to content when size not given; background default transparent. VStack / HStack
/// shared, direction from view (includes reverse).
pub const stack = ui.paramStyle(struct { direction: ui.Direction, gap: f32, justify: ui.JustifyContent, align_items: ui.AlignItems, width: ?f32, height: ?f32, padding: ?ui.Padding, background: ?ui.Color, wrap: bool = false, pub const declared = &[_][]const u8{ "direction", "no_cross_stretch", "gap", "justify", "align_items", "width", "height", "padding", "background", "flex_wrap", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .direction = args.direction, .no_cross_stretch = true, .gap = args.gap, .justify = args.justify, .align_items = args.align_items, .width = ui.orElse(args.width, .fit), .height = ui.orElse(args.height, .fit), .padding = ui.orElse(args.padding, 0), .background = ui.orElse(args.background, ui.Color.TRANSPARENT), }, t); if (args.wrap) out = out.merge(ui.boxFrom(.{ .flex_wrap = .wrap, }, t)); return out; } });

/// Elastic spacing: occupies remaining space; fixed to min-size when given
pub const spacer = ui.paramStyle(struct { min_size: f32, pub const declared = &[_][]const u8{ "width", "height", "flex", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .flex = 1, }, t); if (args.min_size > 0) out = out.merge(ui.boxFrom(.{ .width = args.min_size, .height = args.min_size, }, t)); return out; } });

//# yix-map styles.yss
