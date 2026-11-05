// GENERATED FILE, do not edit: generated from doc_chip.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Documentation example (docs/YIX_REFERENCE.md §2.1): Chip styles. Changes here must sync docs.
const ui = @import("ui");

/// Capsule: neutral / accent tones, outlined when selected; hover background fades in
pub const Chip = ui.previewCva("tests/yix/doc_chip.yss", "Chip", @embedFile("doc_chip.yss"), .{ .base = .{ .direction = .row, .align_items = .center, .gap = ui.tokenRef(.space, "space100"), .padding = .{ .y = ui.tokenRef(.space, "space50"), .x = ui.tokenRef(.space, "space200") }, .corner_radius = ui.tokenRef(.radius, "full"), .background = ui.tokenRef(.color, "bg-secondary"), .transition = ui.transition("background 120ms ease-out"), ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, }, .variants = .{ .tone = .{ .neutral = .{ }, .accent = .{ .background = ui.mix(ui.tokenRef(.color, "bg-primary"), ui.tokenRef(.color, "accent"), 0.15), }, }, .selected = .{ .false = .{ }, .true = .{ .border_width = 1, .border_color = ui.tokenRef(.color, "accent"), }, }, }, .defaults = .{ .tone = .neutral, .selected = false, }, });

pub const label = ui.previewCss("tests/yix/doc_chip.yss", "label", @embedFile("doc_chip.yss"), .{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = ui.tokenRef(.font_size, "sm"), });
pub const remove = ui.previewCss("tests/yix/doc_chip.yss", "remove", @embedFile("doc_chip.yss"), .{ .padding = .{ .y = 0, .x = ui.tokenRef(.space, "space50") }, .corner_radius = ui.tokenRef(.radius, "full"), ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, });

//# yix-map doc_chip.yss
