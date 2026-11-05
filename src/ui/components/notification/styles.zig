//! Notification design tokens (design 16.9).
//!
//! Semantic colors in oklch same lightness same chroma, vary hue only: L~0.55 graphic tier
//! icons/dots/progress/healthbar only; text-carrying colors must use the -ink tier (L~0.47,
//! contrast >= 4.5:1).
//! Action buttons use neutral gray background per macOS native, no semantic color. Prohibit
//! alpha-diluting text for "secondary": tier by ink / ink-2 / ink-3 three-stop ink. Dark scheme not
//! in design, here computed per structure (warm dark gray glass + brightened ink/ink tiers),
//! guarantee theme switch no white-on-white.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const model = @import("model.zig");

fn hexA(rgb: u24, alpha: f32) Color {
    const a: u8 = @intFromFloat(@round(@max(0, @min(1, alpha)) * 255.0));
    return Color.hex(rgb).withAlpha(a);
}

pub const Palette = struct {
    // Semantic color - graphic tier.
    success: Color,
    @"error": Color,
    warning: Color,
    info: Color,
    violet: Color,
    quiet: Color,
    // Semantic color - text tier.
    success_ink: Color,
    error_ink: Color,
    warning_ink: Color,
    info_ink: Color,
    violet_ink: Color,
    quiet_ink: Color,
    // Neutral ink.
    ink: Color,
    ink_2: Color,
    ink_3: Color,
    // Close button shadow (glass material and shadow by GlassBox).
    shadow_rgb: u24,
    // Controls.
    track: Color,
    separator: Color,
    button_primary: Color,
    button_primary_hover: Color,
    button_primary_pressed: Color = Color.TRANSPARENT,
    button_secondary: Color,
    button_secondary_hover: Color,
    button_secondary_pressed: Color = Color.TRANSPARENT,
    reply_field: Color,
    reply_border: Color,
    close_dark: Color,
    close_dark_edge: Color,
    close_light: Color,
    close_light_edge: Color,
    close_light_glyph: Color,
    avatar_bg: Color,
    avatar_fg: Color,
    pill_fg: Color,
    pill_icon: Color,
    on_semantic: Color,
    // Copy hint (16.13).
    keycap_bg: Color,
    keycap_edge: Color,
    hint_kbd_bg: Color,

    pub fn tone(self: *const Palette, t: model.Tone) Color {
        return switch (t) {
            .success => self.success,
            .@"error" => self.@"error",
            .warning => self.warning,
            .info => self.info,
            .violet => self.violet,
            .quiet => self.quiet,
        };
    }

    pub fn toneInk(self: *const Palette, t: model.Tone) Color {
        return switch (t) {
            .success => self.success_ink,
            .@"error" => self.error_ink,
            .warning => self.warning_ink,
            .info => self.info_ink,
            .violet => self.violet_ink,
            .quiet => self.quiet_ink,
        };
    }

    /// Healthbar: semantic color 50% opacity; silent type 28% (16.2).
    pub fn lifeBar(self: *const Palette, t: model.Tone) Color {
        return self.tone(t).withAlpha(if (t == .quiet) 72 else 128);
    }

    pub fn shadow(self: *const Palette, alpha: f32) Color {
        return hexA(self.shadow_rgb, alpha);
    }
};

pub const light = Palette{
    .success = Color.hex(0x008A48),
    .@"error" = Color.hex(0xC83A35),
    .warning = Color.hex(0xBC7400),
    .info = Color.hex(0x337BD0),
    .violet = Color.hex(0x8059BB),
    .quiet = Color.hex(0x6D6864),
    .success_ink = Color.hex(0x007131),
    .error_ink = Color.hex(0xA91518),
    .warning_ink = Color.hex(0x864B00),
    .info_ink = Color.hex(0x0859AC),
    .violet_ink = Color.hex(0x6941A1),
    .quiet_ink = Color.hex(0x56524E),
    .ink = Color.hex(0x2B2724),
    .ink_2 = Color.hex(0x4A4643),
    .ink_3 = Color.hex(0x6F6B67),
    .shadow_rgb = 0x182034,
    .track = hexA(0x5A544F, 0.12),
    .separator = hexA(0x5A544F, 0.12),
    .button_primary = hexA(0x5A544F, 0.18),
    .button_primary_hover = hexA(0x5A544F, 0.26),
    .button_secondary = hexA(0x5A544F, 0.08),
    .button_secondary_hover = hexA(0x5A544F, 0.15),
    .reply_field = hexA(0xFFFFFF, 0.78),
    .reply_border = hexA(0x5A544F, 0.12),
    .close_dark = hexA(0x2B2724, 0.94),
    .close_dark_edge = hexA(0xFFFFFF, 0.35),
    .close_light = hexA(0xFFFFFF, 0.90),
    .close_light_edge = hexA(0x2B2724, 0.15),
    .close_light_glyph = Color.hex(0x6F6B67),
    .avatar_bg = Color.hex(0xF0E7DF),
    .avatar_fg = Color.hex(0x7C614C),
    .pill_fg = hexA(0xFFFFFF, 0.94),
    .pill_icon = hexA(0xFFFFFF, 0.72),
    .on_semantic = Color.hex(0xFFFFFF),
    .keycap_bg = hexA(0x5A544F, 0.08),
    .keycap_edge = hexA(0x5A544F, 0.16),
    .hint_kbd_bg = hexA(0xFFFFFF, 0.45),
};

pub const dark = Palette{
    .success = Color.hex(0x1F9D5C),
    .@"error" = Color.hex(0xD24B45),
    .warning = Color.hex(0xC98614),
    .info = Color.hex(0x4A8CDB),
    .violet = Color.hex(0x9170C8),
    .quiet = Color.hex(0x8A847F),
    .success_ink = Color.hex(0x6CD39A),
    .error_ink = Color.hex(0xF28A84),
    .warning_ink = Color.hex(0xE8B25C),
    .info_ink = Color.hex(0x8DB9F0),
    .violet_ink = Color.hex(0xC2A6EE),
    .quiet_ink = Color.hex(0xB9B3AE),
    .ink = Color.hex(0xF3EFEB),
    .ink_2 = Color.hex(0xD3CDC7),
    .ink_3 = Color.hex(0xA8A29C),
    .shadow_rgb = 0x000000,
    .track = hexA(0xFFFFFF, 0.14),
    .separator = hexA(0xFFFFFF, 0.10),
    .button_primary = hexA(0xFFFFFF, 0.18),
    .button_primary_hover = hexA(0xFFFFFF, 0.26),
    .button_secondary = hexA(0xFFFFFF, 0.09),
    .button_secondary_hover = hexA(0xFFFFFF, 0.16),
    .reply_field = hexA(0x000000, 0.28),
    .reply_border = hexA(0xFFFFFF, 0.12),
    .close_dark = hexA(0xF3EFEB, 0.94),
    .close_dark_edge = hexA(0x000000, 0.35),
    .close_light = hexA(0x3A3633, 0.92),
    .close_light_edge = hexA(0xFFFFFF, 0.14),
    .close_light_glyph = Color.hex(0xC9C3BD),
    .avatar_bg = Color.hex(0x4A3E34),
    .avatar_fg = Color.hex(0xE9D6C4),
    .pill_fg = hexA(0x2B2724, 0.94),
    .pill_icon = hexA(0x2B2724, 0.72),
    .on_semantic = Color.hex(0xFFFFFF),
    .keycap_bg = hexA(0xFFFFFF, 0.09),
    .keycap_edge = hexA(0xFFFFFF, 0.16),
    .hint_kbd_bg = hexA(0x000000, 0.22),
};

pub fn palette(t: *const theme.ThemeTokens) Palette {
    var p = if (t.scheme == .dark) dark else light;
    const c = t.tokens.color;
    p.success = c.success;
    p.@"error" = c.danger;
    p.warning = c.warning;
    p.info = c.info;
    p.success_ink = c.success;
    p.error_ink = c.danger;
    p.warning_ink = c.warning;
    p.info_ink = c.info;
    p.ink = c.fg_primary;
    p.ink_2 = c.fg_secondary;
    p.ink_3 = c.fg_tertiary;
    p.track = c.progress_track;
    p.separator = c.border;
    p.button_primary = c.button_primary_bg;
    p.button_primary_hover = c.accent_hover;
    p.button_primary_pressed = c.accent_pressed;
    p.on_semantic = c.button_primary_fg;
    p.button_secondary = c.bg_primary;
    p.button_secondary_hover = c.bg_hover;
    p.button_secondary_pressed = c.button_pressed_bg;
    return p;
}

/// Dimensions (design 16.2 / 16.9).
pub const Metrics = struct {
    pub const radius: f32 = 18;
    pub const row_padding = core.Padding{ .top = 12, .right = 12, .bottom = 12, .left = 12 };
    pub const row_gap: f32 = 8;
    pub const content_gap: f32 = 4;
    pub const title_gap: f32 = 8;
    pub const lead_size: f32 = 24;
    pub const chip_radius: f32 = 10;
    pub const glyph_size: f32 = 16;
    pub const ring_size: f32 = 28;
    pub const ring_stroke: f32 = 2.8;
    pub const spinner_size: f32 = 17;
    pub const spinner_stroke: f32 = 3.2;
    pub const quiet_dot: f32 = 9;
    pub const title_size: f32 = 13;
    pub const title_weight: u16 = 600;
    /// Design measured line frames: title 19 / timestamp 17 / progress metadata 15.
    pub const title_line_height: f32 = 1.4;
    pub const timestamp_line_height: f32 = 17.0 / 11.5;
    pub const meta_line_height: f32 = 15.0 / 10.5;
    pub const body_size: f32 = 12;
    pub const body_line_height: f32 = 1.4;
    pub const body_max_lines: u16 = 3;
    pub const timestamp_size: f32 = 11.5;
    pub const meta_size: f32 = 10.5;
    pub const ring_secs_size: f32 = 11;
    pub const avatar_initial_size: f32 = 13;
    pub const footer_padding = core.Padding{ .top = 12, .right = 16, .bottom = 12, .left = 16 };
    pub const footer_gap: f32 = 8;
    pub const separator: f32 = 1;
    pub const button_height: f32 = 28;
    pub const button_radius: f32 = 6;
    pub const button_font: f32 = 12;
    pub const reply_height: f32 = 30;
    pub const reply_padding = core.Padding{ .top = 0, .right = 4, .bottom = 0, .left = 11 };
    pub const send_height: f32 = 22;
    pub const send_radius: f32 = 7;
    pub const send_font: f32 = 11.5;
    pub const progress_track: f32 = 4;
    pub const progress_padding = core.Padding{ .top = 5, .right = 0, .bottom = 1, .left = 0 };
    pub const life_bar: f32 = 1.5;
    pub const close_size: f32 = 20;
    pub const close_glyph: f32 = 14;
    pub const close_inset: f32 = 5;
    pub const pill_height: f32 = 24;
    pub const pill_gap: f32 = 12;
    /// Badge and "clear all" round button spacing.
    pub const clear_gap: f32 = 6;
    pub const pill_font: f32 = 10.8;
    pub const pill_icon: f32 = 11;
};

/// Copy hint dimensions (design 16.13): unmeasured values match card.
pub const HintMetrics = struct {
    pub const height: f32 = 36;
    pub const radius: f32 = 18;
    pub const max_width: f32 = 480;
    pub const pad_plain: f32 = 16;
    /// With badge (chip / ring) left narrows.
    pub const pad_marked: f32 = 16;
    /// With button right narrows to 5, button and pill concentric.
    pub const pad_action: f32 = 5;
    pub const gap: f32 = 8;
    pub const keycap_gap: f32 = 6;
    pub const font: f32 = 13;
    pub const weight: u16 = 400;
    pub const chip: f32 = 16;
    pub const glyph: f32 = 16;
    pub const spinner: f32 = 16;
    /// Ring innerRadius 0.76 -> stroke width = 8 x 0.24.
    pub const spinner_stroke: f32 = 1.92;
    pub const spinner_sweep_deg: f32 = 110;
    pub const keycap_height: f32 = 20;
    pub const keycap_radius: f32 = 5;
    pub const keycap_font: f32 = 11;
    pub const action_height: f32 = 26;
    pub const action_radius: f32 = 13;
    pub const action_padding = core.Padding{ .top = 0, .right = 6, .bottom = 0, .left = 11 };
    pub const action_font: f32 = 12.5;
    pub const action_kbd_height: f32 = 16;
    pub const action_kbd_radius: f32 = 4;
    pub const action_kbd_font: f32 = 10.5;
    /// Extra whitespace before button (gap 8 + 4 + gap 8).
    pub const action_lead: f32 = 4;
    /// Solo: bottom edge to content bottom; stacked with cards both bottom-center from stack top.
    pub const bottom_inset: f32 = 16;
    pub const stack_gap: f32 = 12;
};
