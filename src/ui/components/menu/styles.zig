/// Menu — 样式层
///
/// recipe 与具名样式函数；业务逻辑/State/事件处理在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");

// ============================================================================
// MenuItemRecipe — recipe(danger) + disabled 条件态
//
// base 管几何 + 静态外观 + normal 文字色 + hover 高亮背景（键盘/鼠标虚拟高亮
// 取 hover 态色，由 MenuState.highlightIndex 运行时驱动）+ disabled 条件态。
// danger 是真变体（每项的种类），走 variant resolver；disabled 是条件，
// 走 resolve(.{ .is_disabled })——其短路语义天然保证 disabled 压过 danger
// （替代此前 3 条 compounds 互斥梯子）。
// ============================================================================
pub const MenuItemRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        danger: bool = false,
    };

    pub fn base(t: *const theme.ThemeTokens) ConditionalStyle {
        return .{
            .base = .{
                .width = .{ .grow = .{} },
                .height = .{ .px = 32 },
                .direction = .row,
                .align_items = .center,
                .justify = .space_between,
                .padding = Padding.symmetric(0, 10),
                .background = Color.TRANSPARENT,
                .font_size = 13,
                .text_color = t.color.fg_primary,
            },
            .hover = .{ .background = t.color.list_hover_bg },
            .disabled = .{ .text_color = t.color.fg_disabled },
        };
    }

    pub const variants = .{
        .danger = struct {
            fn resolve(danger: bool, t: *const theme.ThemeTokens) ConditionalStyle {
                if (!danger) return .{};
                return .{ .base = .{ .text_color = t.color.danger } };
            }
        }.resolve,
    };
});

// ── 静态具名样式函数 ──

pub fn menuListStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .padding = Padding.symmetric(4, 0),
    };
}

pub fn menuSeparatorStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 1 },
        .background = t.color.separator,
        .padding = Padding.symmetric(4, 0),
    };
}

pub fn menuShortcutStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_disabled,
        .font_size = 11,
    };
}
