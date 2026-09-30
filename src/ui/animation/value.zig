//! Finite scalar sampling shared by standalone and hosted animations.
const std = @import("std");
const Easing = @import("easing.zig").Easing;

pub fn finiteOr(value: f32, fallback: f32) f32 {
    return if (std.math.isFinite(value)) value else fallback;
}

/// Invalid easing output falls back to the normalized linear phase. Finite
/// overshoot remains intentional and is not clamped to the endpoint interval.
pub fn eased(easing: Easing, progress: f32) f32 {
    const t = std.math.clamp(finiteOr(progress, 0), 0, 1);
    return finiteOr(easing.apply(t), t);
}

/// Widen before subtraction and evaluate from the nearer endpoint. Exact
/// endpoints survive cancellation; unrepresentable overshoot saturates to f32.
pub fn interpolate(raw_from: f32, raw_to: f32, raw_t: f32) f32 {
    const from = finiteOr(raw_from, 0);
    const to = finiteOr(raw_to, from);
    const t: f64 = finiteOr(raw_t, 0);
    if (t == 0) return from;
    if (t == 1) return to;
    const delta = @as(f64, to) - from;
    const value = if (t <= 0.5) @mulAdd(f64, delta, t, from) else @mulAdd(f64, -delta, 1 - t, to);
    return @floatCast(std.math.clamp(value, -@as(f64, std.math.floatMax(f32)), std.math.floatMax(f32)));
}

pub fn sample(from: f32, to: f32, easing: Easing, progress: f32) f32 {
    return interpolate(from, to, eased(easing, progress));
}
