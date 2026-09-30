//! Alert 样式层 — AlertRecipe(variant) 与具名静态样式（zenit-styling-revamp）。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Border = core.Border;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const AlertVariant = @import("mod.zig").AlertVariant;

// ============================================================================
// AlertRecipe — recipe(variant) 统一 Alert 颜色
//
// variant 维度: background / border(width+color+radius) / text_color(accent)
// accent = t.color.{info,success,warning,danger}
// bg     = lerp(accent, bg_primary, 0.85)
// border_color = lerp(accent, bg_primary, 0.6), width=1, radius=8
// ============================================================================
pub const AlertRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: AlertVariant = .info,
    };

    pub const variants = .{
        .variant = struct {
            fn resolve(v: AlertVariant, t: *const theme.ThemeTokens) ConditionalStyle {
                const accent = switch (v) {
                    .info => t.color.info,
                    .success => t.color.success,
                    .warning => t.color.warning,
                    .@"error" => t.color.danger,
                };
                return .{ .base = .{
                    .background = Color.lerp(accent, t.color.bg_primary, 0.78),
                    .border = Border{ .width = 1, .color = Color.lerp(accent, t.color.bg_primary, 0.35), .radius = 8 },
                    .text_color = accent,
                } };
            }
        }.resolve,
    };
});

// ── 具名静态样式（容器 / 强调条 / 内容区 / 关闭按钮） ──

pub fn alertContainerStyle(has_title: bool) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .align_items = if (has_title) .start else .center,
        .padding = Padding.all(12),
    };
}

pub fn alertAccentBarStyle(accent: Color) core.BoxStyle {
    return .{
        .width = .{ .px = 3 },
        .height = .{ .px = 24 },
        .background = accent,
        .border = .{ .radius = 2 },
    };
}

pub fn alertContentStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 4,
        .padding = Padding.symmetric(0, 10),
    };
}

pub fn alertTitleText(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_primary,
        .font_size = t.font_size.md,
        .font_weight = 600,
    };
}

pub fn alertMessageText(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = t.font_size.sm,
    };
}

pub fn alertCloseButtonStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .background = Color.TRANSPARENT,
        .border = .{ .radius = t.radius.sm },
        .justify = .center,
        .align_items = .center,
        .cursor = .pointer,
    };
}

pub const alert_close_icon_size: f32 = 12;

pub fn alertCloseLabelText(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "x",
        .color = t.color.fg_secondary,
        .font_size = 12,
    };
}
