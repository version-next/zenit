//! Chip 样式层，ChipRecipe + shell variant 映射
//!
//! Chip 基于 ControlShell：这里只声明 chip 自有的样式决策
//! （variant 的背景/文字/边框覆盖 + hover 目标色），几何仍由
//! ControlShellRecipe（pill 模式）产出。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");
const control_shell = @import("../control_shell/mod.zig");

/// ChipVariant -> ControlShell 基底变体
pub fn shellVariant(v: mod.ChipVariant) control_shell.ControlVariant {
    return switch (v) {
        .default => .secondary,
        .active => .primary,
        .outline => .ghost,
        .disabled => .secondary,
    };
}

/// Chip 自有样式配方：base 覆盖 shell 基底，hover 为交互态目标色。
///
/// 说明：
/// - text_color 供 label/icon/close 取色；shell 根节点不渲染文本，
///   该字段对 shell 是惰性的（保持与旧 style_override 等价的视觉输出）；
/// - hover 是否生效由组件层 readonly/disabled 决定（mount 传 null 抑制），
///   recipe 只声明目标色；
/// - disabled 变体带 `.disabled = .{ .opacity = 1.0 }`：Chip 的禁用态
///   靠换色表达，不做半透明（覆盖 shell secondary 的 opacity 0.5 默认）。
pub const ChipRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: mod.ChipVariant = .default,
    };

    pub const variants = .{
        .variant = struct {
            fn resolve(v: mod.ChipVariant, t: *const theme.ThemeTokens) ConditionalStyle {
                return switch (v) {
                    .default => .{
                        .base = .{
                            .background = t.color.bg_primary,
                            .text_color = t.color.fg_primary,
                            .border = .{ .width = 1, .color = t.color.border_strong },
                        },
                        .hover = .{ .background = t.color.bg_secondary },
                    },
                    .active => .{
                        .base = .{
                            .background = t.color.accent,
                            .text_color = t.color.button_primary_fg,
                            .border = .{ .width = 1, .color = Color.lerp(t.color.accent, t.color.fg_primary, 0.18) },
                        },
                        .hover = .{ .background = Color.lerp(t.color.accent, Color.WHITE, 0.1) },
                    },
                    .outline => .{
                        .base = .{
                            .background = t.color.bg_secondary,
                            .text_color = t.color.fg_primary,
                            .border = .{ .width = 1, .color = t.color.border_strong },
                        },
                        .hover = .{ .background = t.color.bg_tertiary },
                    },
                    .disabled => .{
                        .base = .{
                            .background = t.color.bg_secondary,
                            .text_color = t.color.fg_secondary,
                            .border = .{ .width = 1, .color = t.color.separator },
                        },
                        .disabled = .{ .opacity = 1.0 },
                    },
                };
            }
        }.resolve,
    };
});
