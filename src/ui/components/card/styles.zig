//! Card 样式层，CardRecipe(variant × selected) 与具名静态样式（zenit-styling-revamp）。
//! mod.zig 只消费 resolve 结果与函数返回值。
const core = @import("../../core.zig");
const theme = core.theme;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const Padding = core.Padding;
const Border = core.Border;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const CardVariant = @import("mod.zig").CardVariant;

// ============================================================================
// CardRecipe, recipe(variant) + selected 条件
//
// variant 维度: background / border / corner_radius / shadow / hover 态
// selected 条件位: 高亮边框（2px accent，细粒度字段在 mod.zig fold 进 Border）
//   selected 是持久状态不是变体，走 ConditionalStyle 的 .selected 条件，
//      消费端 resolve(.{ .is_selected = ... })。
// radius 固定 = 6（所有 variant 共享）
// ============================================================================
pub const CardRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: CardVariant = .default,
    };

    pub fn base(t: *const theme.ThemeTokens) ConditionalStyle {
        return .{ .selected = .{
            .border_width = 2,
            .border_color = t.color.accent,
        } };
    }

    pub const variants = .{
        .variant = struct {
            fn resolve(v: CardVariant, t: *const theme.ThemeTokens) ConditionalStyle {
                const radius: f32 = 6;
                return switch (v) {
                    .default => .{ .base = .{
                        .background = t.color.bg_primary,
                        .border = Border{ .width = 1, .color = t.color.border, .radius = radius },
                        .corner_radius = radius,
                    }, .hover = .{ .background = t.color.bg_hover } },
                    .outlined => .{ .base = .{
                        .background = t.color.bg_primary,
                        .border = Border{ .width = 1, .color = t.color.border_strong, .radius = radius },
                        .corner_radius = radius,
                    }, .hover = .{ .border_color = t.color.accent } },
                    .elevated => .{ .base = .{
                        .background = t.color.bg_primary,
                        .corner_radius = radius,
                        .shadow = t.shadow.md,
                    }, .hover = .{ .background = t.color.bg_hover } },
                };
            }
        }.resolve,
    };
});

// ── 具名静态样式（header / title / subtitle / body） ──

pub fn cardHeaderStyle(_: *const theme.ThemeTokens) BoxStyle {
    return .{
        .direction = .column,
        .gap = 4,
        .padding = Padding.all(12),
    };
}

pub fn cardTitleContainerStyle(_: *const theme.ThemeTokens) BoxStyle {
    return .{ .height = .{ .px = 18 } };
}

pub fn cardTitleText(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_primary,
        .font_size = 14,
        .font_weight = 600,
    };
}

pub fn cardSubtitleContainerStyle(_: *const theme.ThemeTokens) BoxStyle {
    return .{ .height = .{ .px = 16 } };
}

pub fn cardSubtitleText(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = 12,
    };
}

pub fn cardBodyStyle(padded: bool) BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .direction = .column,
        .padding = if (padded) Padding.all(12) else null,
    };
}
