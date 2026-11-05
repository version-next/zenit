//! Numeric contract from pencil m97vV / Y4SCQf, values are logical pixels.
const ui = @import("ui");
pub const root = ui.css(.{ .width = ui.Sizing.fill(), .height = ui.Sizing.fill(), .direction = .column, .background = ui.arb.hex(0xf7f7f9) });
pub const header = ui.css(.{ .width = ui.Sizing.fill(), .height = ui.arb.px(38), .align_items = .center, .background = ui.arb.hex(0xecedf1), .padding = .{ .left = 6 }, .gap = 0 });
pub const leading = ui.css(.{ .gap = 8, .height = ui.arb.px(38), .align_items = .center });
pub const project_group = ui.css(.{ .gap = 16, .align_items = .center });
pub const project = ui.css(.{ .gap = 8, .height = ui.arb.px(28), .align_items = .center });
pub const badge = ui.css(.{ .width = ui.arb.px(18), .height = ui.arb.px(18), .align_items = .center, .justify = .center, .border = .{ .radius = 6 }, .background = ui.arb.hex(0x5aabe4) });
pub const badge_text = ui.css(.{ .font_size = ui.arb.px(11), .font_weight = 600, .color = ui.Color.WHITE });
pub const project_text = ui.css(.{ .font_size = ui.arb.px(12), .font_weight = 600, .color = ui.arb.hex(0x1d1d1f), .wrap = .none });
pub const muted_text = ui.css(.{ .font_size = ui.arb.px(12), .color = ui.arb.hex(0x86868b) });
pub const branch = ui.css(.{ .gap = 4, .height = ui.arb.px(28), .align_items = .center });
pub const trailing = ui.css(.{ .height = ui.arb.px(38), .align_items = .center, .gap = 14 });
pub const actions = ui.css(.{ .align_items = .center, .gap = 0 });
pub const drag = ui.css(.{ .width = ui.Sizing.fill(), .min_width = ui.arb.px(160), .height = ui.Sizing.fill(), .align_self = .stretch });
pub const content = ui.css(.{ .width = ui.Sizing.fill(), .padding = ui.Padding.all(20), .gap = 16 });
pub const title = ui.css(.{ .font_size = ui.arb.px(22), .font_weight = 600, .color = ui.arb.hex(0x1d1d1f) });
pub const section = ui.css(.{ .font_size = ui.arb.px(15), .font_weight = 600, .color = ui.arb.hex(0x1d1d1f) });
pub const row_label = ui.css(.{ .font_size = ui.arb.px(13), .font_weight = 600, .color = ui.arb.hex(0x1d1d1f) });
pub const note = ui.css(.{ .font_size = ui.arb.px(12), .color = ui.arb.hex(0x6e6e73) });
pub const gallery = ui.css(.{ .width = ui.Sizing.fill(), .padding = ui.Padding.all(10), .gap = 16, .border = .{ .radius = 10 }, .background = ui.Color.WHITE });
pub const gallery_row = ui.css(.{ .width = ui.Sizing.fill(), .gap = 8 });
pub const label_row = ui.css(.{ .gap = 12, .align_items = .center });
pub const desktop = ui.css(.{ .width = ui.Sizing.fill(), .direction = .column, .padding = .{ .top = 8 }, .background = ui.arb.hex(0xdcdfe6), .border = .{ .radius = 6 }, .overflow_hidden = true });
pub const controls_row = ui.css(.{ .gap = 8, .align_items = .center });
pub const native_title = ui.css(.{ .width = ui.Sizing.fill(), .height = ui.arb.px(30), .align_items = .center, .justify = .space_between, .padding = .{ .left = 12, .right = 12 }, .background = ui.arb.hex(0xc9cdd6) });
pub const editor = ui.css(.{ .width = ui.Sizing.fill(), .padding = ui.Padding.all(16), .gap = 12, .background = ui.Color.WHITE });
pub const menu_bar = ui.css(.{ .height = ui.arb.px(38), .align_items = .center, .gap = 2 });
pub const icon_button: ui.BoxStyle = .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = ui.Padding.all(0), .border = .{ .radius = 6 }, .background = ui.Color.TRANSPARENT };
pub const icon_tint = ui.arb.hex(0x86868b);

pub fn projectSized(width: f32, _: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = 28 }, .align_items = .center, .gap = 8, .overflow_hidden = true };
}

pub fn headerSpacer(height: f32, _: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = ui.Sizing.fill(), .height = .{ .px = height } };
}
