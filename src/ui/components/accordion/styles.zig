//! Accordion style layer, AccordionItemRecipe(variant) and header/body geometry contract
//! (zenit-styling-revamp).
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
                            .background = t.tokens.color.bg_primary,
                            .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border },
                            .corner_radius = t.tokens.radius.panel,
                        },
                    },
                    .outline => .{
                        .base = .{
                            .background = Color.TRANSPARENT,
                            .border = Border{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.panel },
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

// ── Named static styles (header / title / body / chevron geometry contract) ──
//
// body left indent = chevron size + header gap + header left padding (aligns title start),
// three quantities are part of same geometry contract, declared centrally here.

pub const accordion_header_padding = Padding.symmetric(0, 12);
pub const accordion_header_gap: f32 = 6;
pub const accordion_chevron_size: f32 = 16;

pub fn accordionHeaderStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 36 },
        .background = Color.TRANSPARENT,
        .direction = .row,
        .align_items = .center,
        .padding = accordion_header_padding,
        .gap = accordion_header_gap,
        .cursor = .pointer,
    };
}

pub fn accordionTitleText(_: bool, t: *const theme.ThemeTokens) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_primary,
        .font_size = t.tokens.font_size.md,
        .font_weight = 500,
        .line_height = 1.4,
    };
}

pub fn accordionBodyStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    const body_left = accordion_chevron_size + accordion_header_gap + accordion_header_padding.left;
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .padding = .{ .top = 0, .right = 12, .bottom = 14, .left = body_left },
    };
}

pub fn accordionHeaderHover(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .background = t.tokens.color.bg_hover };
}
