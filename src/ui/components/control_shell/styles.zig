//! ControlShell 样式层 — ControlShellRecipe
//!
//! 业务逻辑（controlShell()/ControlShellConfig/slot 组装）在 mod.zig；
//! 本文件只有样式声明。variant/size 枚举是公共 API，留在 mod.zig，此处循环 import 取用。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Sizing = core.Sizing;
const Padding = core.Padding;
const Border = core.Border;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");
const ControlVariant = mod.ControlVariant;
const ControlSize = mod.ControlSize;

// ============================================================================
// ControlShellRecipe — 真正的 recipe()，把 variant × size 等五个维度统一管理
//
// resolve 算法: base < variant < derived < 外部 override
// variant 维度负责: background / border / text_color / font_weight / 交互态
// derived 负责跨维度几何: padding / radius / gap（height/width 恒为 fit，高度由内容撑出）
//   （= f(size, pill, icon_only, leading_icon)，单维度 resolver 表达不了）
// ============================================================================
pub const ControlShellRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        variant: ControlVariant = .secondary,
        size: ControlSize = .md,
        /// pill 模式影响圆角，作为第三个维度
        pill: bool = false,
        /// icon_only 影响 padding，作为第四个维度
        icon_only: bool = false,
        /// leading_icon 影响 padding，作为第五个维度
        leading_icon: bool = false,
    };

    pub const variants = .{
        .variant = struct {
            fn resolve(v: ControlVariant, t: *const theme.ThemeTokens) ConditionalStyle {
                // border.radius 统一来自 derived 的 corner_radius（Border 结构里的 radius
                // 由 controlShell() fold 进去），这里写 0 即可。
                // 本 resolver 只负责 variant 语义（color / weight / border width & color / 交互态）
                return switch (v) {
                    .primary => .{
                        // 读主题的 button_primary_* token（自定义主题换品牌色即生效）。
                        // 此前 background 取 fg_primary、文字写死白色：light 下两者恰好同色，
                        // dark 下却是米色底白字（对比度约 1.5）。hover / active 从背景推导，
                        // light 预设下与原先的 0x0F0F0F / 0x2A2A2A 基本一致。
                        .base = .{
                            .background = t.color.button_primary_bg,
                            .text_color = t.color.button_primary_fg,
                            .font_weight = 600,
                            .border = Border{ .width = 0, .color = Color.TRANSPARENT, .radius = 0 },
                        },
                        .hover = .{ .background = Color.lerp(t.color.button_primary_bg, Color.BLACK, 0.35) },
                        .active = .{ .background = Color.lerp(t.color.button_primary_bg, Color.WHITE, 0.1) },
                        .disabled = .{
                            .background = t.color.bg_secondary,
                            .text_color = t.color.fg_tertiary,
                        },
                    },
                    .secondary => .{
                        .base = .{
                            .background = t.color.bg_primary,
                            .text_color = t.color.fg_primary,
                            .font_weight = 500,
                            .border = Border{ .width = 1, .color = t.color.border, .radius = 0 },
                        },
                        .hover = .{
                            .background = t.color.bg_hover,
                            .border_color = t.color.border_strong,
                        },
                        .active = .{ .background = t.color.bg_active },
                        .disabled = .{ .opacity = 0.5 },
                    },
                    .ghost => .{
                        .base = .{
                            .text_color = t.color.fg_secondary,
                            .font_weight = 500,
                        },
                        .hover = .{ .background = t.color.bg_hover },
                        .active = .{ .background = t.color.bg_active },
                        .disabled = .{ .opacity = 0.5 },
                    },
                    .danger => .{
                        .base = .{
                            .background = t.color.danger,
                            .text_color = t.color.status_fg,
                            .font_weight = 600,
                        },
                        .hover = .{ .background = t.color.danger_hover },
                        .active = .{ .background = Color.lerp(t.color.danger_hover, Color.BLACK, 0.1) },
                        .disabled = .{ .opacity = 0.5 },
                    },
                    .link => .{
                        .base = .{
                            .text_color = t.color.accent,
                            .font_weight = 500,
                        },
                        .disabled = .{ .opacity = 0.5 },
                    },
                    .field => .{
                        .base = .{
                            .background = t.color.input_bg,
                            .text_color = t.color.fg_primary,
                            .font_weight = 400,
                            .border = Border{ .width = 1, .color = t.color.border_strong, .radius = 0 },
                        },
                        .hover = .{ .border_color = t.color.border_focus },
                        .disabled = .{
                            .background = t.color.bg_secondary,
                            .text_color = t.color.fg_secondary,
                            .border_color = t.color.separator,
                        },
                    },
                };
            }
        }.resolve,
    };

    /// 跨维度几何 — 只产出几何字段，禁碰 background（会污染 bgColors 三态取色）。
    /// size/pill/icon_only/leading_icon 四个维度没有独立 resolver，全部在这里组合。
    ///
    /// **不产出 height/width 像素值**：外框高度 = padding_y × 2 + 行盒（行高），由布局
    /// fit 得出（行盒最小高度在 controlShell() 里按 metrics.lineHeightPx() 设到 slot 上）。
    /// icon_only：四边 padding = padding_y + (行高 − icon_size) / 2，图标槽最小为 icon_size
    /// 见方 → 外框 = icon_size + 2·pad = 行高 + 2·padding_y，天然正方形且与文本控件等高。
    pub fn derived(v: Variants, t: *const theme.ThemeTokens) ConditionalStyle {
        const m = t.control.get(v.size);
        const pad: Padding = if (v.icon_only)
            Padding.all(m.padding_y + (m.lineHeightPx() - m.icon_size) / 2)
        else if (v.leading_icon)
            Padding{
                .top = m.padding_y,
                .right = m.padding_h,
                .bottom = m.padding_y,
                .left = m.padding_leading_icon,
            }
        else
            Padding.symmetric(m.padding_y, m.padding_h);
        return .{
            .base = .{
                .padding = pad,
                .corner_radius = if (v.pill) 999 else m.radius,
                .height = Sizing{ .fit = .{} },
                .width = Sizing{ .fit = .{} },
                .gap = m.gap,
            },
        };
    }
});
