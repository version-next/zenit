//! Tag 样式层 — TagRecipe + 关闭按钮具名样式函数
//! 业务逻辑在 mod.zig；TagColor/TagVariant/TagSize 是公共 API，循环 import 取用。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");

const TagColor = mod.TagColor;
const TagVariant = mod.TagVariant;
const TagSize = mod.TagSize;

// ============================================================================
// TagRecipe — recipe(color × variant × size) 统一管理三个维度
//
// color 维度:   提供 background / text_color / border_color（通过 border 整体）
// variant 维度: outline 时改 background 透明 + border width = 1
// size 维度:    贡献 gap（padding/fontSize/height 通过 TagSize 方法在 mount 里设置）
//
// border.radius 在 mount 里 patch（= size.height() / 2），不在 recipe 里写死。
// ============================================================================
pub const TagRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        color: TagColor = .neutral,
        variant: TagVariant = .default,
        size: TagSize = .md,
    };

    pub const variants = .{
        .color = struct {
            fn resolve(c: TagColor, t: *const theme.ThemeTokens) ConditionalStyle {
                const bg = switch (c) {
                    .neutral => t.color.bg_tertiary,
                    .accent => Color.lerp(t.color.bg_primary, t.color.accent, 0.25),
                    .success => Color.lerp(t.color.bg_primary, t.color.success, 0.25),
                    .warning => Color.lerp(t.color.bg_primary, t.color.warning, 0.25),
                    .danger => Color.lerp(t.color.bg_primary, t.color.danger, 0.25),
                    .info => Color.lerp(t.color.bg_primary, t.color.info, 0.25),
                };
                const fg = switch (c) {
                    .neutral => t.color.fg_primary,
                    .accent => t.color.accent,
                    .success => t.color.success,
                    .warning => t.color.warning,
                    .danger => t.color.danger,
                    .info => t.color.info,
                };
                const border_c = switch (c) {
                    .neutral => t.color.border,
                    .accent => Color.lerp(t.color.bg_primary, t.color.accent, 0.5),
                    .success => Color.lerp(t.color.bg_primary, t.color.success, 0.5),
                    .warning => Color.lerp(t.color.bg_primary, t.color.warning, 0.5),
                    .danger => Color.lerp(t.color.bg_primary, t.color.danger, 0.5),
                    .info => Color.lerp(t.color.bg_primary, t.color.info, 0.5),
                };
                return .{
                    .base = .{
                        .background = bg,
                        .text_color = fg,
                        // border_color 由 variant 维度决定是否显示（width 为 0 时颜色无意义）
                        .border_color = border_c,
                    },
                };
            }
        }.resolve,
        .variant = struct {
            fn resolve(v: TagVariant, _: *const theme.ThemeTokens) ConditionalStyle {
                return switch (v) {
                    .default => .{
                        .base = .{
                            // default: 背景不透明，无 border（border_color 保留供 outline 覆盖）
                            .border_width = 0,
                        },
                    },
                    .outline => .{
                        .base = .{
                            // outline: 背景透明，显示 1px border
                            .background = Color.TRANSPARENT,
                            .border_width = 1,
                        },
                    },
                };
            }
        }.resolve,
        .size = struct {
            fn resolve(s: TagSize, _: *const theme.ThemeTokens) ConditionalStyle {
                return .{ .base = .{ .gap = 4, .font_size = s.fontSize() } };
            }
        }.resolve,
    };

    /// 跨维度几何 — height/padding 收进 recipe（只产出几何字段，禁碰 background）。
    /// pill 圆角 = height/2 在 mount 里 fold 进 Border（细粒度 border 字段在
    /// derived 之后 merge，只能在组件函数体折叠，同 control_shell.zig）。
    pub fn derived(v: Variants, _: *const theme.ThemeTokens) ConditionalStyle {
        return .{ .base = .{
            .height = .{ .px = v.size.height() },
            .padding = v.size.padding(),
        } };
    }
});

// ============================================================================
// 具名样式函数 — 关闭按钮（无 variant 维度，颜色随 Tag 前景色参数化）
// ============================================================================

pub fn tagCloseButtonStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
        .background = Color.TRANSPARENT,
        .border = .{ .radius = t.radius.full },
        .justify = .center,
        .align_items = .center,
    };
}

// iconTint 消费，故为 Style
pub fn tagCloseIconStyle() core.Style {
    return .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } };
}

pub fn tagCloseTextStyle(fg: Color) core.TextProps {
    return .{ .content = "x", .color = fg, .font_size = 10 };
}

/// 关闭按钮 hover 背景（前景色淡化 80%）
pub fn tagCloseHoverBg(fg: Color) Color {
    return Color.lerp(fg, Color.TRANSPARENT, 0.8);
}
