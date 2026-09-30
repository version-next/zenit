//! Tabs 样式层 — TabsSlotRecipe + variant×size spec 表 + EditorTabs 具名样式函数
//!
//! 业务逻辑（TabsState/Builder/mount/事件/before_render）在 mod.zig；
//! 本文件只有样式声明。TabsVariant/TabsSize 是公共 API，留在 mod.zig，循环 import 取用。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const ConditionalStyle = core.ConditionalStyle;
const StyleOverride = core.StyleOverride;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");
const TabsVariant = mod.TabsVariant;
const TabsSize = mod.TabsSize;

// ============================================================================
// TabsSlotRecipe — 5 slots: root, tab, highlight, badge, close
//
// 样式全部收敛在这里：variant resolver 管颜色/字重/highlight 外观，
// derived 管 variant × size 组合出的全部几何（padding/radius/gap/font_size）。
// active 态不是独立 slot 而是 tab slot 的 .selected 条件——消费端
// `slots.tab.resolve(.{ .is_selected = is_active })`。
// mount/buildTab 只消费 resolve 结果，不再各自持有样式决策。
// ============================================================================

pub const TabsSlotRecipe = recipe_mod.slotRecipe(struct {
    pub const Slots = struct {
        root: ConditionalStyle = .{},
        /// tab item（active 态走 .selected 条件字段）
        tab: ConditionalStyle = .{},
        /// 跟随 active tab 的滑动指示（underline 下划线 / pill 白底滑块 / tab 浅色底）
        highlight: ConditionalStyle = .{},
        /// 数字 badge
        badge: ConditionalStyle = .{},
        /// 关闭按钮
        close: ConditionalStyle = .{},
    };

    pub const Variants = struct {
        variant: TabsVariant = .underline,
        size: TabsSize = .md,
    };

    /// 尺寸/变体无关的静态部件样式
    pub fn base(t: *const theme.ThemeTokens) Slots {
        return .{
            .badge = .{ .base = .{
                .height = .{ .px = 16 },
                .background = t.color.accent,
                .padding = Padding.symmetric(0, 6),
                .border = .{ .radius = 8 },
                .justify = .center,
                .align_items = .center,
                .text_color = t.color.button_primary_fg,
                .font_size = 10,
            } },
            .close = .{ .base = .{
                .width = .{ .px = 16 },
                .height = .{ .px = 16 },
                .border = .{ .radius = 2 },
                .justify = .center,
                .align_items = .center,
                .text_color = t.color.fg_secondary,
                .font_size = 12,
            } },
        };
    }

    pub const variants = .{
        .variant = struct {
            fn resolve(v: TabsVariant, t: *const theme.ThemeTokens) Slots {
                return switch (v) {
                    .underline => .{
                        .root = .{},
                        .tab = .{ .base = .{
                            .text_color = t.color.fg_secondary,
                            .font_weight = 500,
                        }, .selected = .{
                            .text_color = t.color.fg_primary,
                            .font_weight = 600,
                        }, .hover = .{ .text_color = t.color.fg_primary } },
                        // 2px accent bar（高度固定，宽度/水平位移每帧跟随 active tab）
                        .highlight = .{ .base = .{
                            .height = .{ .px = 2 },
                            .background = t.color.accent,
                        } },
                    },
                    .pill => .{
                        .root = .{ .base = .{
                            .background = t.color.bg_secondary,
                        } },
                        .tab = .{ .base = .{
                            .text_color = t.color.fg_secondary,
                            .font_weight = 500,
                        }, .selected = .{
                            .text_color = t.color.fg_primary,
                            .font_weight = 600,
                        } },
                        // 白色滑块 + 精确 shadow
                        .highlight = .{ .base = .{
                            .background = t.color.bg_primary,
                            .shadow = .{ .color = Color.rgba(0, 0, 0, 15), .blur = 2, .offset_x = 0, .offset_y = 1 },
                        } },
                    },
                    .tab => .{
                        .root = .{},
                        .tab = .{ .base = .{
                            .text_color = t.color.fg_secondary,
                            .font_weight = 500,
                        }, .selected = .{
                            .text_color = t.color.accent,
                            .font_weight = 600,
                        } },
                        .highlight = .{ .base = .{
                            .background = t.color.accent_subtle,
                        } },
                    },
                };
            }
        }.resolve,
    };

    /// 跨维度几何 — variant × size 组合出的 padding/radius/gap/font_size 全在这里。
    /// 只产出几何字段，禁碰 background（见 recipe.zig derived 约定）。
    pub fn derived(v: Variants, _: *const theme.ThemeTokens) Slots {
        const item_geo = StyleOverride{
            .padding = itemPadding(v.variant, v.size),
            .gap = itemGap(v.variant, v.size),
            .font_size = tabFontSize(v.size),
        };
        return .{
            .root = .{ .base = .{
                .padding = rootPadding(v.variant, v.size),
                .corner_radius = rootCornerRadius(v.variant, v.size),
                .gap = rootGap(v.variant, v.size),
            } },
            // selected 条件不改几何，一份 base 即够
            .tab = .{ .base = item_geo },
            .highlight = .{ .base = .{
                .corner_radius = highlightRadius(v.variant, v.size),
            } },
        };
    }
});

// ============================================================================
// Tabs 独立 spec 表 — 4 档 (xs/sm/md/lg)
//
// 只被 TabsSlotRecipe.derived 消费（tabIconSize 例外：icon 尺寸不是
// StyleOverride 字段，由 buildTab 直接取）。组件逻辑不得直接调用。
// ============================================================================

/// Tab 内文字字号 (比 ControlSize.fontSize 略小)
pub fn tabFontSize(size: TabsSize) f32 {
    return switch (size) {
        .xs => 11,
        .sm => 11,
        .md => 13,
        .lg => 14,
    };
}

// ── Underline variant spec ──

pub fn underlineItemPadding(size: TabsSize) Padding {
    return switch (size) {
        .xs => Padding.symmetric(3.5, 6),
        .sm => Padding.symmetric(5.5, 8),
        .md => Padding.symmetric(8, 10),
        .lg => Padding.symmetric(11.5, 14),
    };
}

// ── Pill variant spec ──

pub fn pillOuterPadding(size: TabsSize) f32 {
    return switch (size) {
        .xs => 2,
        .sm => 2,
        .md => 3,
        .lg => 4,
    };
}

pub fn pillOuterRadius(size: TabsSize) f32 {
    return switch (size) {
        .xs => 5,
        .sm => 7,
        .md => 9,
        .lg => 12,
    };
}

pub fn pillInnerPadding(size: TabsSize) Padding {
    return switch (size) {
        .xs => Padding.symmetric(1.5, 6),
        .sm => Padding.symmetric(3.5, 6),
        .md => Padding.symmetric(5, 10),
        .lg => Padding.symmetric(7.5, 14),
    };
}

pub fn pillInnerRadius(size: TabsSize) f32 {
    return switch (size) {
        .xs => 3,
        .sm => 5,
        .md => 6,
        .lg => 8,
    };
}

// ── Tab (icon) variant spec ──

pub fn tabItemPadding(size: TabsSize) Padding {
    return switch (size) {
        .xs => Padding.symmetric(3.5, 6),
        .sm => Padding.symmetric(5.5, 8),
        .md => Padding.symmetric(8, 10),
        .lg => Padding.symmetric(11, 14),
    };
}

pub fn tabIconSize(size: TabsSize) f32 {
    return switch (size) {
        .xs => 10,
        .sm => 12,
        .md => 14,
        .lg => 18,
    };
}

pub fn tabIconTextGap(size: TabsSize) f32 {
    return switch (size) {
        .xs => 4,
        .sm => 4,
        .md => 6,
        .lg => 8,
    };
}

pub fn tabCornerRadius(size: TabsSize) f32 {
    return switch (size) {
        .xs => 4,
        .sm => 6,
        .md => 8,
        .lg => 10,
    };
}

// ── 容器级 spec ──

pub fn rootPadding(variant: TabsVariant, size: TabsSize) Padding {
    return switch (variant) {
        .underline => Padding.ZERO,
        .pill => Padding.all(pillOuterPadding(size)),
        .tab => Padding.ZERO,
    };
}

pub fn rootCornerRadius(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline => 0,
        .pill => pillOuterRadius(size),
        .tab => 0,
    };
}

pub fn rootGap(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline => 0,
        .pill => 2,
        .tab => switch (size) {
            .xs => 2,
            .sm => 2,
            .md => 4,
            .lg => 4,
        },
    };
}

/// 每个 variant 对应的 tab item padding
pub fn itemPadding(variant: TabsVariant, size: TabsSize) Padding {
    return switch (variant) {
        .underline => underlineItemPadding(size),
        .pill => pillInnerPadding(size),
        .tab => tabItemPadding(size),
    };
}

/// 每个 variant 对应的 item gap
pub fn itemGap(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline, .pill => switch (size) {
            .xs => 4,
            .sm => 4,
            .md => 6,
            .lg => 8,
        },
        .tab => tabIconTextGap(size),
    };
}

/// highlight_box 的 corner radius
pub fn highlightRadius(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline => 2,
        .pill => pillInnerRadius(size),
        .tab => tabCornerRadius(size),
    };
}

// ── EditorTabs 具名样式函数（无 variant 维度的静态样式层） ──

pub fn editorTabsContainerStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .height = .{ .px = 35 },
        .background = t.color.bg_primary,
        .direction = .row,
    };
}

pub fn editorTabStyle(is_active: bool, t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .height = .{ .px = 35 },
        .background = if (is_active) t.color.bg_secondary else t.color.bg_primary,
        .padding = Padding.symmetric(0, 10),
        .direction = .row,
        .align_items = .center,
        .gap = 6,
    };
}

pub fn editorTabLabelStyle(is_active: bool, t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = if (is_active) t.color.fg_primary else t.color.fg_secondary,
        .font_size = 12,
    };
}

pub fn editorModifiedDotStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 8 },
        .height = .{ .px = 8 },
        .background = t.color.fg_secondary,
        .border = .{ .radius = 4 },
    };
}

pub fn editorCloseStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
        .border = .{ .radius = 2 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn editorCloseLabelStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "×",
        .color = t.color.fg_secondary,
        .font_size = 11,
    };
}
