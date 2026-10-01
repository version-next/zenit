//! Accordion 样式层，AccordionItemRecipe(variant) 与 header/body 几何合同（zenit-styling-revamp）。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Border = core.Border;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const AccordionVariant = @import("mod.zig").AccordionVariant;

pub const AccordionItemRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: AccordionVariant = .default,
    };

    pub const variants = .{
        .variant = struct {
            fn resolve(v: AccordionVariant, t: *const theme.ThemeTokens) ConditionalStyle {
                return switch (v) {
                    .default => .{
                        .base = .{
                            .background = t.color.bg_secondary,
                            .corner_radius = t.radius.xl,
                        },
                    },
                    .outline => .{
                        .base = .{
                            .background = Color.TRANSPARENT,
                            .border = Border{ .width = 1, .color = t.color.fg_tertiary, .radius = t.radius.xl },
                        },
                    },
                    .ghost => .{
                        .base = .{
                            .background = Color.TRANSPARENT,
                        },
                    },
                };
            }
        }.resolve,
    };
});

// ── 具名静态样式（header / title / body / chevron 几何合同） ──
//
// body 左缩进 = chevron 尺寸 + header gap + header 左 padding（对齐标题起点），
// 三个量是同一几何合同的一部分，集中声明在这里。

pub const accordion_header_padding = Padding.symmetric(14, 20);
pub const accordion_header_gap: f32 = 12;
pub const accordion_chevron_size: f32 = 16;

pub fn accordionHeaderStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .align_items = .center,
        .padding = accordion_header_padding,
        .gap = accordion_header_gap,
        .cursor = .pointer,
    };
}

pub fn accordionTitleText(is_expanded: bool, t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_primary,
        .font_size = t.font_size.lg,
        .font_weight = if (is_expanded) 600 else 500,
        .line_height = 1.538,
    };
}

pub fn accordionBodyStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    const body_left = accordion_chevron_size + accordion_header_gap + accordion_header_padding.left;
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .padding = .{ .top = 0, .right = accordion_header_padding.right, .bottom = 16, .left = body_left },
    };
}

/// hover 时 item 容器的 border 颜色（随 variant 背景调和）
pub fn accordionHoverBorderColor(item_bg: Color, t: *const theme.ThemeTokens) Color {
    return Color.lerp(t.color.fg_tertiary, item_bg, 0.5);
}
