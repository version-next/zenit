// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Controls story styles: pencil "zenit UI native.pen" artboard LKxqO (01 · Controls / states).
//! Root gap 32; sections gap 16, padding-top 24, 1px top rule; matrix label 72 / cell 108.
const ui = @import("ui");

pub const root = ui.previewCss("examples/storybook/controls/styles.yss", "root", @embedFile("styles.yss"), .{ .width = 960, .direction = .column, .gap = ui.tokenRef(.space, "space800"), });
pub const header = ui.previewCss("examples/storybook/controls/styles.yss", "header", @embedFile("styles.yss"), .{ .width = .fill, .direction = .column, .gap = ui.tokenRef(.space, "space200"), });
pub const eyebrow = ui.previewCss("examples/storybook/controls/styles.yss", "eyebrow", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "xs"), .font_weight = 600, .color = ui.tokenRef(.color, "accent"), });
pub const title = ui.previewCss("examples/storybook/controls/styles.yss", "title", @embedFile("styles.yss"), .{ .font_size = 28, .font_weight = 600, .line_height = 1.25, .color = ui.tokenRef(.color, "fg-primary"), });
pub const lede = ui.previewCss("examples/storybook/controls/styles.yss", "lede", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "md"), .line_height = 1.5, .color = ui.tokenRef(.color, "fg-secondary"), });

pub const section = ui.previewCss("examples/storybook/controls/styles.yss", "section", @embedFile("styles.yss"), .{ .width = .fill, .direction = .column, .gap = ui.tokenRef(.space, "space400"), .padding = .{ .top = ui.tokenRef(.space, "space600"), .right = 0, .bottom = 0, .left = 0 }, .border_overlay = true, .border_top_width = 1, .border_color = ui.tokenRef(.color, "border"), });
pub const section_title = ui.previewCss("examples/storybook/controls/styles.yss", "section_title", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "xl"), .font_weight = 600, .line_height = 1.25, .color = ui.tokenRef(.color, "fg-primary"), });
pub const section_desc = ui.previewCss("examples/storybook/controls/styles.yss", "section_desc", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "sm"), .line_height = 1.4, .color = ui.tokenRef(.color, "fg-secondary"), });

pub const row = ui.previewCss("examples/storybook/controls/styles.yss", "row", @embedFile("styles.yss"), .{ .width = .fill, .direction = .row, .align_items = .center, .gap = ui.tokenRef(.space, "space400"), });
pub const selection_row = ui.previewCss("examples/storybook/controls/styles.yss", "selection_row", @embedFile("styles.yss"), .{ .width = .fill, .direction = .row, .align_items = .center, .gap = ui.tokenRef(.space, "space800"), });
pub const focus_row = ui.previewCss("examples/storybook/controls/styles.yss", "focus_row", @embedFile("styles.yss"), .{ .width = .fill, .direction = .row, .align_items = .center, .gap = ui.tokenRef(.space, "space600"), });

pub const variant_name = ui.previewCss("examples/storybook/controls/styles.yss", "variant_name", @embedFile("styles.yss"), .{ .width = 72, .font_size = ui.tokenRef(.font_size, "sm"), .line_height = 1.4, .color = ui.tokenRef(.color, "fg-secondary"), });
pub const column_spacer = ui.previewCss("examples/storybook/controls/styles.yss", "column_spacer", @embedFile("styles.yss"), .{ .width = 72, .height = 1, });
pub const column_head = ui.previewCss("examples/storybook/controls/styles.yss", "column_head", @embedFile("styles.yss"), .{ .width = 108, .font_size = ui.tokenRef(.font_size, "xs"), .font_weight = 500, .color = ui.tokenRef(.color, "fg-tertiary"), });

/// Matrix specimen: fixed cell width, label centered (cells pass a fit-width content slot).
pub const cell = ui.previewCss("examples/storybook/controls/styles.yss", "cell", @embedFile("styles.yss"), .{ .width = 108, .justify = .center, });
/// A field specimen is as wide as an input, its text starts at the left.
pub const field_cell = ui.previewCss("examples/storybook/controls/styles.yss", "field_cell", @embedFile("styles.yss"), .{ .width = 200, });

/// Specimen label: the shell's text tier (SizeRecipe content: md, 1.2); color and weight come
/// from the shell's tone (inherited).
pub const label = ui.previewCss("examples/storybook/controls/styles.yss", "label", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "md"), .line_height = 1.2, });
pub const placeholder = ui.previewCss("examples/storybook/controls/styles.yss", "placeholder", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "md"), .line_height = 1.2, .color = ui.tokenRef(.color, "fg-secondary"), });

/// Icon-slot glyphs (SizeRecipe icon: md), tinted like the tone's text.
pub const glyph = ui.previewCss("examples/storybook/controls/styles.yss", "glyph", @embedFile("styles.yss"), .{ .width = ui.tokenRef(.size, "md"), .height = ui.tokenRef(.size, "md"), .icon_color = ui.tokenRef(.color, "fg-primary"), });
pub const glyph_on_primary = ui.previewCss("examples/storybook/controls/styles.yss", "glyph_on_primary", @embedFile("styles.yss"), .{ .width = ui.tokenRef(.size, "md"), .height = ui.tokenRef(.size, "md"), .icon_color = ui.tokenRef(.color, "button-primary-fg"), });
pub const glyph_muted = ui.previewCss("examples/storybook/controls/styles.yss", "glyph_muted", @embedFile("styles.yss"), .{ .width = ui.tokenRef(.size, "md"), .height = ui.tokenRef(.size, "md"), .icon_color = ui.tokenRef(.color, "fg-tertiary"), });

/// useFocusRing's ring (focus-ring color, focus width, focus offset) on a box hugging the
/// control's shape: several specimens at once, which real focus cannot show.
pub const focus_ring = ui.paramStyle(struct { pub const declared = &[_][]const u8{ "corner_radius", "no_cross_stretch", "outline", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { _ = args; return ui.boxFrom(.{ .corner_radius = ui.tokenRef(.radius, "control"), .no_cross_stretch = true, .outline = ui.Outline{ .color = t.tokens.color.focus_ring, .width = t.tokens.border_width.focus, .offset = t.tokens.size.focus_offset }, }, t); } }).of(.{});

//# yix-map styles.yss
