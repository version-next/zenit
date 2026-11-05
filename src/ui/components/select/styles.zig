const core = @import("../../core.zig");
const Color = core.Color;
const SelectSize = @import("../control_shell/mod.zig").ControlSize;
pub const Metrics = struct {
    /// Option row / checkmark size bounds from (trigger geometry not here, uses control metrics)
    icon_size: f32,
    tag_radius: f32,
    tag_height: f32,
    tag_gap: f32,
    tag_padding: core.Padding,
    tag_font: f32,
    close_size: f32,
    panel_radius: f32,
    panel_padding: f32,
    row_radius: f32,
    row_padding: core.Padding,
    row_font: f32,
    checkbox_size: f32,
    checkbox_radius: f32,
    check_size: f32,
};

pub fn metrics(size: SelectSize) Metrics {
    // RYMhT / Select and MultiSelect share 28px rows and 22px chips.
    return .{
        .icon_size = switch (size) {
            .xs => 12,
            .sm => 14,
            .md, .lg => 16,
        },
        .tag_radius = 4,
        .tag_height = switch (size) {
            .xs => 14,
            .sm => 18,
            .md => 22,
            .lg => 28,
        },
        .tag_gap = if (size == .xs or size == .sm) 3 else 6,
        .tag_padding = core.Padding.symmetric(0, switch (size) {
            .xs => 4,
            .sm => 6,
            .md, .lg => 8,
        }),
        // TODO(token): font_size.tag_xs = 10 (RYMhT 14px multi-select tag).
        .tag_font = switch (size) {
            .xs => @import("../../ui.zig").arb.px(10),
            .sm => 11,
            .md => 12,
            .lg => 13,
        },
        .close_size = if (size == .xs or size == .sm) 10 else 12,
        .panel_radius = 10,
        .panel_padding = 4,
        .row_radius = 6,
        .row_padding = core.Padding.symmetric(0, 8),
        .row_font = 13,
        .checkbox_size = 16,
        .checkbox_radius = 4,
        .check_size = 12,
    };
}

pub const Palette = struct {
    bg: Color,
    panel: Color,
    hover: Color,
    inset: Color,
    text_primary: Color,
    text_secondary: Color,
    text_tertiary: Color,
    primary: Color,
    border: Color,
    border_strong: Color,
};

pub fn palette(t: *const core.theme.ThemeTokens) Palette {
    return .{
        .bg = t.tokens.color.bg_primary,
        .panel = t.tokens.color.bg_primary,
        .hover = t.tokens.color.bg_hover,
        .inset = t.tokens.color.bg_secondary,
        .text_primary = t.tokens.color.fg_primary,
        .text_secondary = t.tokens.color.fg_secondary,
        .text_tertiary = t.tokens.color.fg_secondary,
        .primary = t.tokens.color.accent,
        .border = t.tokens.color.border_strong,
        .border_strong = t.tokens.color.border_strong,
    };
}

/// Trigger frame on its ControlShell (overlay): field metrics; multiple mode tightens the vertical
/// padding around tag chips and halves the left inset. RYMhT Select / trigger: xs shadow.
pub const TriggerFrame = struct {
    size: @import("../control_shell/mod.zig").ControlSize,
    width: f32,
    multiple: bool,
    tag_height: f32,
};

pub fn triggerFrame(f: TriggerFrame, t: *const core.ThemeTokens) core.BoxStyle {
    const cm = @import("../input/styles.zig").fieldMetrics(t, f.size);
    const pad_y = if (f.multiple) @min(cm.padding_y, (cm.derivedHeight() - f.tag_height) / 2) else cm.padding_y;
    return .{
        .width = .{ .px = f.width },
        .height = .{ .fit = .{} },
        .padding = .{ .top = pad_y, .right = cm.padding_h, .bottom = pad_y, .left = if (f.multiple) cm.padding_h / 2 else cm.padding_leading_icon },
        .corner_radius = cm.radius,
        .shadow = t.tokens.shadow.xs,
        .gap = cm.gap,
    };
}

const css = @import("../../css.zig").css;
pub const footerStyle = css(.{ .border_overlay = true, .width = .fill, .height = 28, .padding = .{ .x = .space200 }, .border_top_width = 1, .border_color = .border, .align_items = .center, .justify = .space_between });
pub const footerText = css(.{ .font_size = .xs, .color = .fg_tertiary });
pub const overflowText = css(.{ .font_size = .sm, .color = .fg_secondary });

pub const optionContentStyle = css(.{ .width = .fill, .min_width = 0, .align_items = .center, .gap = .space200 });
pub fn checkboxStyle(t: *const core.ThemeTokens) core.ConditionalStyle {
    return .{ .base = .{ .background = t.tokens.color.bg_primary, .border_color = t.tokens.color.border_strong }, .selected = .{ .background = t.tokens.color.accent, .border_color = t.tokens.color.accent }, .disabled = .{ .background = t.tokens.color.disabled_bg, .border_color = t.tokens.color.border } };
}
