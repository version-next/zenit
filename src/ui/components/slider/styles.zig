//! Slider style layer, track / fill / thumb style declaration (geometry parameterized by props).
const core = @import("../../core.zig");
const Color = core.Color;
const SliderProps = @import("mod.zig").SliderProps;

pub fn trackStyle(p: SliderProps, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = p.track_height },
        .background = t.tokens.color.bg_tertiary,
        .border = .{ .radius = p.track_height / 2 },
    };
}

pub fn fillStyle(p: SliderProps, accent: Color, ratio: f32) core.BoxStyle {
    return .{
        .width = .{ .percent = ratio * 100 },
        .height = .{ .px = p.track_height },
        .background = accent,
        .border = .{ .radius = p.track_height / 2 },
    };
}

pub fn thumbBackground(disabled: bool, t: *const core.ThemeTokens) Color {
    return if (disabled) t.tokens.color.fg_disabled else t.tokens.color.bg_primary;
}

pub fn thumbStyle(p: SliderProps, disabled: bool, accent: Color, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .position = .absolute,
        .width = .{ .px = p.thumb_size },
        .height = .{ .px = p.thumb_size },
        .background = thumbBackground(disabled, t),
        .border = .{ .overlay = true, .radius = p.thumb_size / 2, .width = 1, .color = accent },
        // COMPONENTS Slider / 60: flat thumb, 1px accent outline.
        .shadow = null,
    };
}
