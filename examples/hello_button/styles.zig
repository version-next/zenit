//! hello_button 样式表 —— 演示两层样式抽象（见 docs/styling.md）：
//!
//! 1. 具名样式函数：`fn (tokens) -> BoxStyle/TextStyle` 纯函数（root/title/counterLabel），
//!    经 ui.boxStyled/textStyled 挂载后换主题自动重放。
//! 2. 应用层自定义 recipe：`PanelRecipe` 证明 ui.recipe 不是框架组件专属 ——
//!    应用可以用同一套 CVA 风格 variant 系统定义自己的样式变体。
const ui = @import("ui");

pub fn root(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .gap = t.space._4,
        .padding = ui.Padding.all(t.space._10),
        .background = t.color.bg_primary,
        .align_items = .center,
        .justify = .center,
    };
}

pub fn title(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.xxxl,
        .font_weight = 600,
        .color = t.color.fg_primary,
    };
}

pub fn counterLabel(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.lg, .color = t.color.fg_secondary };
}

// ── 应用层自定义 recipe ──────────────────────────────────────────────────

pub const PanelEmphasis = enum { neutral, highlight };

/// CVA 风格：base + variant 维度，全部消费 token
const PanelRecipe = ui.recipe.recipe(struct {
    pub const Variants = struct {
        emphasis: PanelEmphasis = .neutral,
    };

    pub fn base(t: *const ui.ThemeTokens) ui.ConditionalStyle {
        return .{ .base = .{
            .padding = ui.Padding.symmetric(t.space._2, t.space._4),
            .corner_radius = t.radius.md,
        } };
    }

    pub const variants = .{
        .emphasis = struct {
            fn resolve(e: PanelEmphasis, t: *const ui.ThemeTokens) ui.ConditionalStyle {
                return switch (e) {
                    .neutral => .{ .base = .{ .background = t.color.bg_secondary } },
                    .highlight => .{ .base = .{
                        .background = t.color.bg_tertiary,
                        .border = .{ .width = 1, .color = t.color.accent, .radius = 0 },
                    } },
                };
            }
        }.resolve,
    };
});

/// 把 recipe 变体固化成主题安全的样式函数（emphasis 是 comptime 参数，
/// 返回的函数可直接交给 ui.boxStyled）
pub fn panel(comptime emphasis: PanelEmphasis) fn (*const ui.ThemeTokens) ui.BoxStyle {
    return struct {
        fn f(t: *const ui.ThemeTokens) ui.BoxStyle {
            return PanelRecipe.resolveBase(.{ .emphasis = emphasis }, t);
        }
    }.f;
}
