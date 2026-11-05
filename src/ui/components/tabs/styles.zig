//! Tabs style layer, TabsSlotRecipe + variant x size spec table.
//!
//! Business logic (TabsRuntime/Builder/mount/event/before_render) in mod.zig; this file has only
//! style declarations. TabsVariant/TabsSize are public API, left in mod.zig, accessed via cycle
//! import.
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

// Tabs slot recipe: 5 slots: root, tab, highlight, badge, close.
//
// All styles converge here: variant resolver manages color/font-weight/highlight appearance,
// derived manages geometry from variant x size combinations (padding/radius/gap/font_size). Active
// state is not a separate slot but .selected condition on tab slot; consumers call
// `slots.tab.resolve(.{ .is_selected = is_active })`. mount/buildTab only consume resolve results,
// no longer each holding style decisions.

pub const TabsSlotRecipe = recipe_mod.slotRecipe(struct {
    pub const Slots = struct {
        root: ConditionalStyle = .{},
        /// Tab item (active state uses .selected condition field).
        tab: ConditionalStyle = .{},
        /// Slide indicator following active tab (underline / pill white-background slider / tab
        /// light background).
        highlight: ConditionalStyle = .{},
        /// Numeric badge.
        badge: ConditionalStyle = .{},
        /// Close button.
        close: ConditionalStyle = .{},
    };

    pub const Variants = struct {
        variant: TabsVariant = .underline,
        size: TabsSize = .md,
    };

    /// Size/variant-agnostic static component styles.
    pub fn base(t: *const theme.ThemeTokens) Slots {
        return .{
            .tab = .{ .hover = .{ .background = inkOverlay(t, .hover) }, .active = .{ .background = inkOverlay(t, .pressed) }, .disabled = .{ .text_color = t.tokens.color.fg_disabled } },
            .badge = .{ .base = .{
                .height = .{ .px = 16 },
                .background = t.tokens.color.accent,
                .padding = Padding.symmetric(0, 6),
                .border = .{ .radius = 8 },
                .justify = .center,
                .align_items = .center,
                .text_color = t.tokens.color.button_primary_fg,
                .font_size = 10,
            } },
            .close = .{ .base = .{
                .width = .{ .px = 16 },
                .height = .{ .px = 16 },
                .border = .{ .radius = 2 },
                .justify = .center,
                .align_items = .center,
                .text_color = t.tokens.color.fg_secondary,
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
                            .text_color = t.tokens.color.fg_secondary,
                            .font_weight = 400,
                        }, .selected = .{
                            .text_color = t.tokens.color.fg_primary,
                            .font_weight = 500,
                        }, .hover = .{ .text_color = t.tokens.color.fg_primary } },
                        // 2px primary-ink bar (height fixed, width/horizontal offset track active tab
                        // each frame).
                        .highlight = .{ .base = .{
                            .height = .{ .px = 2 },
                            .background = t.tokens.color.fg_primary,
                        } },
                    },
                    .pill => .{
                        .root = .{ .base = .{
                            .background = t.tokens.color.bg_active,
                        } },
                        .tab = .{ .base = .{
                            .text_color = t.tokens.color.fg_secondary,
                            .font_weight = 400,
                        }, .selected = .{
                            .text_color = t.tokens.color.fg_primary,
                            .font_weight = 500,
                        } },
                        // White slider + precise shadow.
                        .highlight = .{ .base = .{
                            .background = t.tokens.color.bg_primary,
                            .shadow = .{ .color = t.tokens.shadow.sm.color, .blur = 3, .offset_y = 1 },
                        } },
                    },
                    .tab => .{
                        .root = .{ .base = .{ .border_overlay = true, .background = t.tokens.color.bg_secondary, .border_bottom_width = 1, .border_color = t.tokens.color.border } },
                        .tab = .{ .base = .{
                            .text_color = t.tokens.color.fg_secondary,
                            .font_weight = 400,
                        }, .selected = .{
                            .text_color = t.tokens.color.fg_primary,
                            .font_weight = 500,
                        } },
                        .highlight = .{ .base = .{
                            .border_overlay = true,
                            .background = t.tokens.color.bg_primary,
                            .border_top_width = 1,
                            .border_left_width = 1,
                            .border_right_width = 1,
                            .border_color = t.tokens.color.border,
                            .corner_radii = .{ .each = .{ 6, 6, 0, 0 } },
                        } },
                    },
                };
            }
        }.resolve,
    };

    /// Cross-dimension geometry: all padding/radius/gap/font_size from variant x size combinations
    /// here. Produce only geometry fields, never touch background (see recipe.zig derived
    /// contract).
    pub fn derived(v: Variants, t: *const theme.ThemeTokens) Slots {
        const item_geo = StyleOverride{
            .height = .{ .px = itemHeight(v.variant, v.size) },
            .padding = itemPadding(v.variant, v.size),
            .gap = itemGap(v.variant, v.size),
            .font_size = tabFontSize(v.size),
        };
        return .{
            .root = .{ .base = .{
                .padding = rootPadding(v.variant, v.size),
                .corner_radius = if (v.variant == .pill) t.tokens.radius.xl else 0,
                .gap = rootGap(v.variant, v.size),
            } },
            // Selected condition doesn't change geometry, one base suffices. The hover /
            // pressed fill takes the selected slider's shape (pill: control radius; tab:
            // its rounded top corners); the underline bar runs along a square bottom edge.
            .tab = .{ .base = item_geo.merge(switch (v.variant) {
                .underline => StyleOverride{},
                .pill => StyleOverride{ .corner_radius = t.tokens.radius.control },
                .tab => StyleOverride{ .corner_radii = .{ .each = .{ 6, 6, 0, 0 } } },
            }) },
            .highlight = .{ .base = .{
                .corner_radius = if (v.variant == .tab) null else if (v.variant == .pill) t.tokens.radius.control else 0,
            } },
        };
    }
});

/// Hover / pressed fill of a tab: the primary text colour as a translucent ink over
/// whatever the tab sits on (white page, the pill or tab track, the selected slider),
/// so one fill reads the same on every variant and keeps the surface's hue. An opaque
/// fill cannot: bg_hover (a blue-tinted grey) was a 0.75 OKLab ΔE step on the
/// #f4f4f7 track, below a visible difference, and the pressed fill was lighter than
/// hover there. Alphas give ΔE ≈ 3.6–3.9 (hover) and 6.5–7 (pressed) on both the
/// primary and secondary backgrounds of either scheme; lightening a dark surface reads
/// stronger than darkening a light one, so a light ink (dark scheme) uses less.
pub const InkState = enum { hover, pressed };

pub fn inkOverlay(t: *const theme.ThemeTokens, state: InkState) Color {
    const ink = t.tokens.color.fg_primary;
    const light_ink = @as(u32, ink.r) + ink.g + ink.b > 3 * 128;
    const alpha: u8 = switch (state) {
        .hover => if (light_ink) 10 else 14,
        .pressed => if (light_ink) 18 else 26,
    };
    return ink.withAlpha(alpha);
}

// Tabs independent spec table, 4 sizes (xs/sm/md/lg).
//
// Consumed only by TabsSlotRecipe.derived (tabIconSize exception: icon size not a StyleOverride
// field, consumed directly by buildTab). Component logic must not call directly.

/// Tab text font size (slightly smaller than ControlSize.fontSize).
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
        .md => Padding.symmetric(0, 12),
        .lg => Padding.symmetric(11.5, 14),
    };
}

// ── Pill variant spec ──

pub fn pillOuterPadding(size: TabsSize) f32 {
    return switch (size) {
        .xs => 2,
        .sm => 2,
        .md => 2,
        .lg => 4,
    };
}

pub fn pillOuterRadius(size: TabsSize) f32 {
    return switch (size) {
        .xs => 5,
        .sm => 7,
        .md => 8,
        .lg => 12,
    };
}

pub fn pillInnerPadding(size: TabsSize) Padding {
    return switch (size) {
        .xs => Padding.symmetric(1.5, 6),
        .sm => Padding.symmetric(3.5, 6),
        .md => Padding.symmetric(0, 12),
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
        .md => Padding.symmetric(0, 12),
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

// -- Container-level spec --

pub fn rootPadding(variant: TabsVariant, size: TabsSize) Padding {
    return switch (variant) {
        .underline => Padding.ZERO,
        .pill => Padding.all(pillOuterPadding(size)),
        .tab => Padding.ZERO,
    };
}

pub fn rootGap(variant: TabsVariant, size: TabsSize) f32 {
    return switch (variant) {
        .underline => 0,
        .pill => 1,
        .tab => switch (size) {
            .xs => 2,
            .sm => 2,
            .md => 0,
            .lg => 4,
        },
    };
}

/// Tab item padding per variant.
pub fn itemPadding(variant: TabsVariant, size: TabsSize) Padding {
    return switch (variant) {
        .underline => underlineItemPadding(size),
        .pill => pillInnerPadding(size),
        .tab => tabItemPadding(size),
    };
}

/// Item gap per variant.
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

// cokFx: default underline 30px, segmented/document 28px.
pub fn itemHeight(variant: TabsVariant, size: TabsSize) f32 {
    return switch (size) {
        .xs => 20,
        .sm => 24,
        .md => if (variant == .underline) 30 else 28,
        .lg => 40,
    };
}
