// GENERATED FILE, do not edit: generated from states.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! P3a: normal element's :focus / :focus-visible / :disabled state source (tests/yix/stories.yix
//! StateBox)
const ui = @import("ui");

pub const field = ui.previewCss("tests/yix/states.yss", "field", @embedFile("states.yss"), .{ .padding = ui.tokenRef(.space, "space100"), .opacity = 1, ._focus = .{ .opacity = 0.9, }, ._focus_visible = .{ .opacity = 0.8, }, ._disabled = .{ .opacity = 0.5, }, });

/// P4: custom shadow (token color) and icon-color switch with variant
pub const Glyph = ui.previewCva("tests/yix/states.yss", "Glyph", @embedFile("states.yss"), .{ .base = .{ .width = 16, .height = 16, .icon_color = ui.tokenRef(.color, "fg-secondary"), .shadow = .{ .offset_x = 0, .offset_y = 2, .blur = 6, .spread = 0, .color = ui.tokenRef(.color, "accent") }, }, .variants = .{ .hot = .{ .false = .{ }, .true = .{ .icon_color = ui.tokenRef(.color, "accent"), }, }, }, .defaults = .{ .hot = false, }, });
pub const GlyphOnHot = ui.previewCva("tests/yix/states.yss", "GlyphOnHot", @embedFile("states.yss"), .{ .base = .{ .width = 16, .height = 16, }, .variants = .{ .hot = .{ .false = .{ }, .true = .{ .icon_color = ui.tokenRef(.color, "accent"), }, }, }, .defaults = .{ .hot = false, }, });

/// P4: text's :hover (link hover color)
pub const link = ui.previewCss("tests/yix/states.yss", "link", @embedFile("states.yss"), .{ .color = ui.tokenRef(.color, "accent"), ._hover = .{ .color = ui.tokenRef(.color, "fg-primary"), }, });

/// P4: one style writes both box and text properties, auto-split when used on <text>
pub const pill = ui.previewCss("tests/yix/states.yss", "pill", @embedFile("states.yss"), .{ .padding = .{ .y = 4, .x = 8 }, .background = ui.tokenRef(.color, "bg-secondary"), .corner_radius = 6, .color = ui.tokenRef(.color, "accent"), .font_size = ui.tokenRef(.font_size, "sm"), });

//# yix-map states.yss
