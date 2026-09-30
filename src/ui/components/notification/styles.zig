//! Notification 设计令牌（设计稿 16.9）。
//!
//! 语义色在 oklch 下同明度同色度、只换色相：L≈0.55 的图形档只做图标底 /
//! 圆点 / 进度条 / 生命条；承载文字必须换 -ink 档（L≈0.47，≥4.5:1）。
//! 操作按钮按 macOS 原生做法用中性灰底，不上语义色。
//! 禁止用 alpha 稀释文字表达「次要」：层级靠 ink / ink-2 / ink-3 三档墨色。
//!
//! 深色方案不在设计稿里，这里给出按同一结构推导的对应值（暖深灰玻璃 +
//! 提亮的墨色 / ink 档），保证换主题不出现白底白字。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const model = @import("model.zig");

fn hexA(rgb: u24, alpha: f32) Color {
    const a: u8 = @intFromFloat(@round(@max(0, @min(1, alpha)) * 255.0));
    return Color.hex(rgb).withAlpha(a);
}

pub const Palette = struct {
    // 语义色 · 图形档
    success: Color,
    @"error": Color,
    warning: Color,
    info: Color,
    violet: Color,
    quiet: Color,
    // 语义色 · 文字档
    success_ink: Color,
    error_ink: Color,
    warning_ink: Color,
    info_ink: Color,
    violet_ink: Color,
    quiet_ink: Color,
    // 中性墨色
    ink: Color,
    ink_2: Color,
    ink_3: Color,
    // 玻璃
    glass_rgb: u24,
    glass_edge: Color,
    glass_outline: Color,
    sheen_top: Color,
    sheen_bottom: Color,
    highlight: Color,
    inset_top: Color,
    inset_bottom: Color,
    inset_glow: Color,
    shadow_rgb: u24,
    // 控件
    track: Color,
    separator: Color,
    button_primary: Color,
    button_primary_hover: Color,
    button_secondary: Color,
    button_secondary_hover: Color,
    reply_field: Color,
    reply_border: Color,
    close_dark: Color,
    close_dark_edge: Color,
    close_light: Color,
    close_light_edge: Color,
    close_light_glyph: Color,
    avatar_bg: Color,
    avatar_fg: Color,
    pill_bg: Color,
    pill_fg: Color,
    pill_icon: Color,
    on_semantic: Color,

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

    /// 生命条：语义色 50% 透明；静默类型 28%（16.2）。
    pub fn lifeBar(self: *const Palette, t: model.Tone) Color {
        return self.tone(t).withAlpha(if (t == .quiet) 72 else 128);
    }

    pub fn glass(self: *const Palette, alpha: f32) Color {
        return hexA(self.glass_rgb, alpha);
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
    // 玻璃底：中性白（与编辑器浮条 media_glass 同一套材质），不带暖色。
    .glass_rgb = 0xFFFFFF,
    .glass_edge = hexA(0xFFFFFF, 0.87),
    .glass_outline = hexA(0x182034, 0.0),
    .sheen_top = hexA(0xFFFFFF, 0.12),
    .sheen_bottom = hexA(0xFFFFFF, 0.0),
    .highlight = hexA(0xFFFFFF, 0.25),
    .inset_top = hexA(0xFFFFFF, 0.95),
    .inset_bottom = hexA(0x182034, 0.06),
    .inset_glow = hexA(0xFFFFFF, 0.18),
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
    .pill_bg = hexA(0x20242E, 0.80),
    .pill_fg = hexA(0xFFFFFF, 0.94),
    .pill_icon = hexA(0xFFFFFF, 0.72),
    .on_semantic = Color.hex(0xFFFFFF),
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
    .glass_rgb = 0x20242E,
    .glass_edge = hexA(0xFFFFFF, 0.14),
    .glass_outline = hexA(0x000000, 0.40),
    .sheen_top = hexA(0xFFFFFF, 0.07),
    .sheen_bottom = hexA(0x000000, 0.06),
    .highlight = hexA(0xFFFFFF, 0.10),
    .inset_top = hexA(0xFFFFFF, 0.14),
    .inset_bottom = hexA(0x000000, 0.30),
    .inset_glow = hexA(0xFFFFFF, 0.05),
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
    .pill_bg = hexA(0xF3EFEB, 0.86),
    .pill_fg = hexA(0x2B2724, 0.94),
    .pill_icon = hexA(0x2B2724, 0.72),
    .on_semantic = Color.hex(0xFFFFFF),
};

pub fn palette(t: *const theme.ThemeTokens) *const Palette {
    return switch (t.scheme) {
        .light => &light,
        .dark => &dark,
    };
}

/// 尺寸（设计稿 16.2 / 16.9）。
pub const Metrics = struct {
    pub const radius: f32 = 18;
    pub const row_padding = core.Padding{ .top = 14, .right = 16, .bottom = 14, .left = 14 };
    pub const row_gap: f32 = 12;
    pub const content_gap: f32 = 3;
    pub const title_gap: f32 = 8;
    pub const lead_size: f32 = 32;
    pub const chip_radius: f32 = 10;
    pub const glyph_size: f32 = 18;
    pub const ring_size: f32 = 28;
    pub const ring_stroke: f32 = 2.8;
    pub const spinner_size: f32 = 17;
    pub const spinner_stroke: f32 = 3.2;
    pub const quiet_dot: f32 = 9;
    pub const title_size: f32 = 13;
    pub const title_weight: u16 = 600;
    /// 设计稿实测行框：标题 19 / 时间戳 17 / 进度元信息 15。
    pub const title_line_height: f32 = 19.0 / 13.0;
    pub const timestamp_line_height: f32 = 17.0 / 11.5;
    pub const meta_line_height: f32 = 15.0 / 10.5;
    pub const body_size: f32 = 12.5;
    pub const body_line_height: f32 = 1.35;
    pub const body_max_lines: u16 = 3;
    pub const timestamp_size: f32 = 11.5;
    pub const meta_size: f32 = 10.5;
    pub const ring_secs_size: f32 = 11;
    pub const avatar_initial_size: f32 = 13;
    pub const footer_padding = core.Padding{ .top = 9, .right = 12, .bottom = 11, .left = 12 };
    pub const footer_gap: f32 = 8;
    pub const separator: f32 = 0.5;
    pub const button_height: f32 = 28;
    pub const button_radius: f32 = 8;
    pub const button_font: f32 = 12.5;
    pub const reply_height: f32 = 30;
    pub const reply_padding = core.Padding{ .top = 0, .right = 4, .bottom = 0, .left = 11 };
    pub const send_height: f32 = 22;
    pub const send_radius: f32 = 7;
    pub const send_font: f32 = 11.5;
    pub const progress_track: f32 = 4;
    pub const progress_padding = core.Padding{ .top = 5, .right = 0, .bottom = 1, .left = 0 };
    pub const life_bar: f32 = 1.5;
    pub const close_size: f32 = 20;
    pub const close_glyph: f32 = 12;
    pub const close_inset: f32 = 5;
    pub const pill_height: f32 = 24;
    pub const pill_gap: f32 = 12;
    /// 角标与「全部清除」圆钮之间的间距。
    pub const clear_gap: f32 = 6;
    pub const pill_font: f32 = 10.8;
    pub const pill_icon: f32 = 11;
};
