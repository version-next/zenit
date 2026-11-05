// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Chip styles (COMPONENTS Chip / *): the look stacks on ControlShell's root as the chip
//! element's style; ControlShell supplies structure, slots and interaction states.
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const shell = @import("../control_shell/mod.zig");

pub const ChipSize = enum { xs, sm, md };
/// Appearance (structure). Selected / disabled are states.
pub const ChipVariant = enum { default, outline };

/// look = variant × selected × disabled; hover / press only while interactive (not readonly, not
/// disabled).
pub const Chip = ui.sva(.{ .slots = .{ .root, .label, .glyph, }, .base = .{ .root = .{ .justify = .center, }, }, .variants = .{ .look = .{ .default = .{ .root = .{ .background = ui.tokenRef(.color, "bg-primary"), .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border"), .shadow = ui.tokenRef(.shadow, "xs"), }, .label = .{ .color = ui.tokenRef(.color, "fg-primary"), }, .glyph = .{ .icon_color = ui.tokenRef(.color, "fg-primary"), }, }, .active = .{ .root = .{ .background = ui.tokenRef(.color, "selection-bg"), .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "accent-border"), .shadow = .{ .offset_x = 0, .offset_y = 0, .blur = 0, .spread = 0, .color = ui.Color.TRANSPARENT }, }, .label = .{ .color = ui.tokenRef(.color, "selection-fg"), }, .glyph = .{ .icon_color = ui.tokenRef(.color, "selection-fg"), }, }, .outline = .{ .root = .{ .background = ui.tokenRef(.color, "bg-secondary"), .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border-strong"), .shadow = ui.tokenRef(.shadow, "xs"), }, .label = .{ .color = ui.tokenRef(.color, "fg-primary"), }, .glyph = .{ .icon_color = ui.tokenRef(.color, "fg-primary"), }, }, .disabled = .{ .root = .{ .background = ui.tokenRef(.color, "bg-secondary"), .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border"), .shadow = .{ .offset_x = 0, .offset_y = 0, .blur = 0, .spread = 0, .color = ui.Color.TRANSPARENT }, }, .label = .{ .color = ui.tokenRef(.color, "fg-secondary"), }, .glyph = .{ .icon_color = ui.tokenRef(.color, "fg-secondary"), }, }, }, .interactive = .{ .false = .{ }, .true = .{ }, }, }, .defaults = .{ .look = .default, .interactive = false, }, .compound = .{ .{ .when = .{ .interactive = true, .look = .default, }, .style = .{ .root = .{ ._hover = .{ .background = ui.tokenRef(.color, "bg-active"), }, ._active = .{ .background = ui.tokenRef(.color, "button-pressed-bg"), }, }, } }, .{ .when = .{ .interactive = true, .look = .active, }, .style = .{ .root = .{ ._hover = .{ .background = ui.tokenRef(.color, "bg-active"), }, ._active = .{ .background = ui.tokenRef(.color, "button-pressed-bg"), }, }, } }, .{ .when = .{ .interactive = true, .look = .outline, }, .style = .{ .root = .{ ._hover = .{ .background = ui.tokenRef(.color, "bg-active"), }, ._active = .{ .background = ui.tokenRef(.color, "button-pressed-bg"), }, }, } }, }, });
pub const ChipLook = Chip.Dim(.look);

pub fn lookOf(variant: ChipVariant, selected: bool, disabled: bool) ChipLook {
    if (disabled) return .disabled;
    if (selected) return .active;
    return switch (variant) {
        .default => .default,
        .outline => .outline,
    };
}

/// ControlShell tone under the chip look (frame defaults the look overrides).
pub fn shellVariant(look: ChipLook) shell.ControlVariant {
    return switch (look) {
        .default, .disabled => .secondary,
        .active => .primary,
        .outline => .ghost,
    };
}

pub fn controlSize(size: ChipSize) shell.ControlSize {
    return switch (size) {
        .xs => .xs,
        .sm => .sm,
        .md => .md,
    };
}

/// COMPONENTS Chip / *: default sm is a 28px raised control; compact / large tiers retained.
pub const geometry = ui.paramStyle(struct { size: ChipSize, pub const declared = &[_][]const u8{ "height", "padding", "corner_radius", "gap", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .height = switch (args.size) { .xs => @as(f32, 20), .sm => t.tokens.size.row, .md => t.tokens.size.control_md }, .padding = core.Padding.symmetric(0, t.tokens.space.space200 + t.tokens.space.space50), .corner_radius = ui.tokenRef(.radius, "control"), .gap = ui.tokenRef(.space, "space150"), }, t); } });

pub const label = ui.previewCss("src/ui/components/chip/styles.yss", "label", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "md"), .line_height = 1.4, .font_weight = 500, });

/// Leading icon: the control's icon size.
pub const glyph_size = ui.paramStyle(struct { size: ChipSize, pub const declared = &[_][]const u8{ "width", "height", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = shell.metrics(t, controlSize(args.size)).icon_size, .height = shell.metrics(t, controlSize(args.size)).icon_size, }, t); } });

/// Close button: a notch under the icon size.
pub const close = ui.paramStyle(struct { size: ChipSize, pub const declared = &[_][]const u8{ "width", "height", "justify", "align_items", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = shell.metrics(t, controlSize(args.size)).icon_size - 2, .height = shell.metrics(t, controlSize(args.size)).icon_size - 2, .justify = .center, .align_items = .center, }, t); } });

//# yix-map styles.yss
