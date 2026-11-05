//! Scrollbar paints follow theme tokens, including their alpha, during fade.
const core = @import("../../core.zig");

pub fn thumb(t: *const core.theme.ThemeTokens, active: bool, fade: f32) core.Color {
    const color = if (active) t.tokens.color.scrollbar_thumb_hover else t.tokens.color.scrollbar_thumb;
    return color.withAlpha(@intFromFloat(@as(f32, @floatFromInt(color.a)) * fade));
}

pub fn track(t: *const core.theme.ThemeTokens) core.Color {
    return t.tokens.color.scrollbar_track;
}
