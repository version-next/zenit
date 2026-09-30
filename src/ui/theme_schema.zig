const std = @import("std");
const core = @import("core.zig");
const theme_mod = @import("theme.zig");

const Color = core.Color;
const ThemeTokens = theme_mod.ThemeTokens;

pub const WindowThemeSchema = struct {
    // Shared window surfaces
    surface_bg: Color,
    surface_border: Color,
    divider: Color,
    panel_subtle_bg: Color,
    panel_subtle_border: Color,

    // Shared text colors
    text_primary: Color,
    text_secondary: Color,
    text_caption: Color,
    text_muted: Color,
    hover_bg: Color,

    // Shared accent colors
    accent_primary: Color,
    accent_hover: Color,
    accent_fg: Color,

    // Shared list/entry colors
    list_active_bg: Color,
    list_active_text: Color,
    list_active_subtle_text: Color,
    folder_icon: Color,
    folder_icon_active: Color,
    file_icon: Color,

    // DevTools specific semantic colors
    devtools_pick_accent: Color,
    devtools_pick_active_bg: Color,
    devtools_pick_active_border: Color,
    devtools_row_selected_bg: Color,
    devtools_row_hover_bg: Color,
    devtools_component_label: Color,
    devtools_text_preview: Color,
    devtools_state_badge_bg: Color,
    devtools_state_card_bg: Color,
    devtools_event_name: Color,
    /// DevTools 次要信息色（ID/数量等），替代 fg_disabled 确保可读性
    devtools_muted: Color,
};

pub fn window(tokens: *const ThemeTokens) WindowThemeSchema {
    const c = tokens.color;
    const is_dark = tokens.scheme == .dark;

    return .{
        .surface_bg = c.bg_primary,
        .surface_border = c.border.withAlpha(if (is_dark) 180 else 120),
        .divider = c.border.withAlpha(if (is_dark) 220 else 160),
        .panel_subtle_bg = if (is_dark) c.bg_secondary else c.bg_tertiary.withAlpha(110),
        .panel_subtle_border = c.border.withAlpha(if (is_dark) 210 else 140),

        .text_primary = c.fg_primary,
        .text_secondary = c.fg_secondary,
        .text_caption = c.fg_secondary,
        .text_muted = c.fg_disabled,
        .hover_bg = c.bg_hover.withAlpha(if (is_dark) 170 else 30),

        .accent_primary = c.button_primary_bg,
        .accent_hover = c.accent_hover,
        .accent_fg = c.button_primary_fg,

        .list_active_bg = c.list_selection_bg,
        .list_active_text = c.accent,
        .list_active_subtle_text = c.fg_secondary,
        .folder_icon = c.info,
        .folder_icon_active = c.accent,
        .file_icon = c.fg_disabled,

        .devtools_pick_accent = c.info,
        .devtools_pick_active_bg = c.info.withAlpha(if (is_dark) 80 else 50),
        .devtools_pick_active_border = c.info.withAlpha(if (is_dark) 210 else 160),
        .devtools_row_selected_bg = c.selection_bg.withAlpha(if (is_dark) 110 else 70),
        .devtools_row_hover_bg = c.list_hover_bg.withAlpha(if (is_dark) 130 else 70),
        .devtools_component_label = c.warning,
        .devtools_text_preview = c.success,
        .devtools_state_badge_bg = c.info.withAlpha(if (is_dark) 80 else 60),
        .devtools_state_card_bg = c.bg_hover.withAlpha(if (is_dark) 120 else 55),
        .devtools_event_name = c.warning,
        // fg_disabled 在 light 模式太浅(0xD4D4D4)，DevTools 用专用 muted 色确保可读
        .devtools_muted = if (is_dark) Color.hex(0x6B6B6B) else Color.hex(0x999999),
    };
}
