//! NumberStepper style layer.
const core = @import("../../core.zig");

pub fn stepBtnStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .align_self = .stretch,
        .justify = .center,
        .align_items = .center,
        .background = t.tokens.color.bg_secondary,
    };
}

pub fn stepBtnLabelStyle(disabled: bool, t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = if (disabled) t.tokens.color.fg_disabled else t.tokens.color.fg_primary,
        .font_size = t.tokens.font_size.sm,
        .font_weight = 600,
    };
}

pub fn stepperWrapperStyle(width: f32, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = width },
        .height = .{ .px = t.tokens.size.control_md },
        .shadow = t.tokens.shadow.xs,
        .direction = .row,
        .align_items = .center,
        .background = t.tokens.color.bg_primary,
        .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border_strong, .radius = t.tokens.radius.control },
    };
}

pub fn stepperValueStyle(disabled: bool, t: *const core.ThemeTokens) core.TextStyle {
    return .{
        .color = if (disabled) t.tokens.color.fg_disabled else t.tokens.color.fg_primary,
        .font_size = t.tokens.font_size.md,
    };
}

// TODO(token): size.stepper_arrows = 22 (RYMhT right-side stepper strip).
pub fn arrowsStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{ .border_overlay = true, .width = .{ .px = @import("../../ui.zig").arb.px(22) }, .height = .{ .grow = .{} }, .align_self = .stretch, .direction = .column, .background = t.tokens.color.bg_secondary, .border_left_width = 1, .border_color = t.tokens.color.border };
}
pub fn valueBoxStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{ .direction = .row, .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .align_self = .stretch, .justify = .start, .align_items = .center, .padding = core.Padding.symmetric(0, t.tokens.space.space200) };
}
pub fn stepButtonConditions(t: *const core.ThemeTokens) core.ConditionalStyle {
    return .{ .base = stepBtnStyle(t), .hover = .{ .background = t.tokens.color.bg_active }, .active = .{ .background = t.tokens.color.button_pressed_bg }, .disabled = .{ .background = t.tokens.color.disabled_bg } };
}

pub fn stepIconStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{ .width = .{ .px = t.tokens.font_size.sm }, .height = .{ .px = t.tokens.font_size.sm } };
}
