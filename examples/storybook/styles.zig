//! Storybook application chrome.
//!
//! Keep the showcase shell visually independent from the individual stories:
//! stories own component demos, while this file owns navigation, hierarchy,
//! preview framing, and workspace chrome.
const ui = @import("ui");

pub fn root(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .row,
        .background = t.color.bg_base,
    };
}

pub fn sidebar(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .px = ui.arb.px(232) },
        .height = .{ .grow = .{} },
        .direction = .column,
        .background = t.color.bg_secondary,
        .border_right_width = t.border_width.thin,
        .border_right_color = t.color.border,
    };
}

pub fn brand(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .direction = .row,
        .align_items = .center,
        .gap = t.space._3,
        .padding = .{ .top = ui.arb.px(34), .right = t.space._4, .bottom = t.space._3, .left = t.space._4 },
    };
}

pub fn logoMark(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .px = ui.arb.px(32) },
        .height = .{ .px = ui.arb.px(32) },
        .align_items = .center,
        .justify = .center,
        .background = t.color.accent,
        .corner_radius = t.radius.xl,
        .shadow = t.shadow.sm,
    };
}

pub fn logoLetter(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.xl,
        .font_weight = 700,
        .color = t.color.fg_inverse,
    };
}

pub fn brandCopy(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .direction = .column, .gap = t.space._0_5 };
}

pub fn brandName(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.lg,
        .font_weight = 700,
        .color = t.color.fg_primary,
    };
}

pub fn brandLabel(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.xxs,
        .font_weight = 600,
        .color = t.color.fg_tertiary,
    };
}

pub fn searchWrap(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .padding = .{ .top = t.space._1, .right = t.space._3, .bottom = t.space._3, .left = t.space._3 },
    };
}

pub fn searchField(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = ui.arb.px(32) },
        .direction = .row,
        .align_items = .center,
        .gap = t.space._2,
        .padding = .{ .top = 0, .right = t.space._2, .bottom = 0, .left = t.space._3 },
        .background = t.color.bg_primary,
        .border = .{ .width = t.border_width.thin, .color = t.color.border, .radius = t.radius.lg },
    };
}

pub fn searchText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.sm, .color = t.color.fg_tertiary };
}

pub fn navEmptyHint(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.sm, .color = t.color.fg_tertiary };
}

pub fn libraryMeta(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .padding = .{ .top = 0, .right = t.space._4, .bottom = t.space._2, .left = t.space._4 },
    };
}

pub fn libraryLabel(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xxs, .font_weight = 700, .color = t.color.fg_secondary };
}

pub fn libraryCount(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xxs, .font_weight = 500, .color = t.color.fg_tertiary };
}

pub fn navSection(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .padding = .{ .top = t.space._4, .right = t.space._2, .bottom = t.space._1, .left = t.space._2 },
    };
}

pub fn navSectionText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.xxs,
        .font_weight = 700,
        .color = t.color.fg_tertiary,
    };
}

pub fn navRow(comptime selected: bool) fn (*const ui.ThemeTokens) ui.BoxStyle {
    return struct {
        fn style(t: *const ui.ThemeTokens) ui.BoxStyle {
            return .{
                .width = .{ .grow = .{} },
                .height = .{ .px = ui.arb.px(30) },
                .direction = .row,
                .align_items = .center,
                .gap = t.space._2,
                .padding = .{ .top = 0, .right = t.space._2, .bottom = 0, .left = t.space._2 },
                .background = if (selected) t.color.accent_subtle else ui.Color.TRANSPARENT,
                .corner_radius = t.radius.lg,
                .cursor = .pointer,
            };
        }
    }.style;
}

pub fn navIndicator(comptime selected: bool) fn (*const ui.ThemeTokens) ui.BoxStyle {
    return struct {
        fn style(t: *const ui.ThemeTokens) ui.BoxStyle {
            return .{
                .width = .{ .px = ui.arb.px(3) },
                .height = .{ .px = ui.arb.px(14) },
                .background = if (selected) t.color.accent else ui.Color.TRANSPARENT,
                .corner_radius = t.radius.full,
            };
        }
    }.style;
}

pub fn navLabel(comptime selected: bool) fn (*const ui.ThemeTokens) ui.TextStyle {
    return struct {
        fn style(t: *const ui.ThemeTokens) ui.TextStyle {
            return .{
                .font_size = t.font_size.md,
                .font_weight = if (selected) 600 else 400,
                .color = if (selected) t.color.fg_primary else t.color.fg_secondary,
            };
        }
    }.style;
}

pub fn sidebarFooter(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .direction = .row,
        .align_items = .center,
        .gap = t.space._2,
        .padding = .{ .top = t.space._3, .right = t.space._4, .bottom = t.space._3, .left = t.space._4 },
        .border_top_width = t.border_width.thin,
        .border_top_color = t.color.border,
    };
}

pub fn onlineDot(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .px = ui.arb.px(7) },
        .height = .{ .px = ui.arb.px(7) },
        .background = t.color.success,
        .corner_radius = t.radius.full,
    };
}

pub fn sidebarFooterText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xs, .font_weight = 500, .color = t.color.fg_secondary };
}

pub fn sidebarVersion(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xs, .color = t.color.fg_tertiary };
}

pub fn workspace(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .background = t.color.bg_base,
    };
}

pub fn toolbar(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = ui.arb.px(56) },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .padding = .{ .top = 0, .right = t.space._6, .bottom = 0, .left = t.space._6 },
        .background = t.color.bg_primary,
        .border_bottom_width = t.border_width.thin,
        .border_bottom_color = t.color.border,
    };
}

pub fn breadcrumb(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .direction = .row, .align_items = .center, .gap = t.space._2 };
}

pub fn breadcrumbRoot(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.sm, .font_weight = 500, .color = t.color.fg_tertiary };
}

pub fn breadcrumbSection(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.sm, .font_weight = 600, .color = t.color.fg_secondary };
}

pub fn breadcrumbCurrent(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.sm, .font_weight = 650, .color = t.color.fg_primary };
}

pub fn toolbarActions(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .direction = .row, .align_items = .center, .gap = t.space._2 };
}

pub fn toolbarPill(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .direction = .row,
        .align_items = .center,
        .gap = t.space._1_5,
        .padding = ui.Padding.symmetric(t.space._1, t.space._2),
        .background = t.color.bg_secondary,
        .border = .{ .width = t.border_width.thin, .color = t.color.border, .radius = t.radius.full },
    };
}

pub fn toolbarPillText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xs, .font_weight = 600, .color = t.color.fg_secondary };
}

pub fn panel(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .direction = .column,
        .gap = t.space._6,
    };
}

pub fn panelHeader(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .grow = .{} }, .direction = .column, .gap = t.space._2 };
}

pub fn sectionEyebrow(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.xs,
        .font_weight = 700,
        .color = t.color.fg_tertiary,
    };
}

pub fn titleRow(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .gap = t.space._4,
    };
}

pub fn panelTitle(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.xxxl,
        .font_weight = 700,
        .color = t.color.fg_primary,
    };
}

pub fn description(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.lg,
        .color = t.color.fg_secondary,
        .line_height = 1.5,
    };
}

pub fn stablePill(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .direction = .row,
        .align_items = .center,
        .gap = t.space._1_5,
        .padding = ui.Padding.symmetric(t.space._1, t.space._2),
        .background = t.color.success_subtle,
        .corner_radius = t.radius.full,
    };
}

pub fn stableText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xs, .font_weight = 650, .color = t.color.success };
}

pub fn previewCard(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .direction = .column,
        .background = t.color.bg_primary,
        .border = .{ .width = t.border_width.thin, .color = t.color.border, .radius = t.radius.xl },
        .corner_radius = t.radius.xl,
        .shadow = t.shadow.sm,
        .overflow_hidden = true,
    };
}

pub fn previewToolbar(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = ui.arb.px(44) },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .padding = .{ .top = 0, .right = t.space._4, .bottom = 0, .left = t.space._4 },
        .background = t.color.bg_secondary,
        .border_bottom_width = t.border_width.thin,
        .border_bottom_color = t.color.border,
    };
}

pub fn previewStatus(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .direction = .row, .align_items = .center, .gap = t.space._2 };
}

pub fn previewLabel(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.sm, .font_weight = 650, .color = t.color.fg_primary };
}

pub fn themePill(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .padding = ui.Padding.symmetric(t.space._1, t.space._2),
        .background = t.color.bg_tertiary,
        .corner_radius = t.radius.full,
    };
}

pub fn themePillText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xxs, .font_weight = 700, .color = t.color.fg_secondary };
}

pub fn previewBody(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .direction = .column,
        .padding = ui.Padding.all(t.space._6),
        .background = t.color.bg_primary,
    };
}
