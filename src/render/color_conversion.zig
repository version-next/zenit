//! Renderer color-space conversion helpers.
//!
//! Kept outside the command encoder because these conversions are pure and are
//! shared by command encoding and the public render facade.

const std = @import("std");

/// sRGB byte (0..255) to linear float, precomputed at comptime.
///
/// Every renderer call site feeds `u8 / 255.0`, so the whole domain is 256
/// points and the table is *exact* for them — not an approximation. This
/// matters because the transfer function is a `pow`, and encoding a
/// 20k-object frame used to call it three times per instance; `pow` showed up
/// as a visible share of frame time in profiles.
const srgb_to_linear_table: [256]f32 = blk: {
    @setEvalBranchQuota(2_000_000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*slot, i| {
        slot.* = srgbToLinearExact(@as(f32, @floatFromInt(i)) / 255.0);
    }
    break :blk table;
};

/// Table-driven conversion for the common byte-valued case.
pub inline fn srgbByteToLinear(v: u8) f32 {
    return srgb_to_linear_table[v];
}

/// Packed sRGB bytes to linear RGBA floats.
pub fn toFloat4(c: anytype) [4]f32 {
    return .{
        srgbByteToLinear(c.r),
        srgbByteToLinear(c.g),
        srgbByteToLinear(c.b),
        @as(f32, @floatFromInt(c.a)) / 255.0,
    };
}

/// Packed sRGB bytes to the text renderer's linear color type.
pub fn toRenderColor(c: anytype) @import("text_renderer.zig").Color {
    const rgba = toFloat4(c);
    return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
}

/// Reference sRGB transfer function. Kept as the single source of truth so the
/// lookup table above is generated from exactly this curve.
pub fn srgbToLinearExact(v: f32) f32 {
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// sRGB to linear for arbitrary floats.
///
/// Inputs that land exactly on a `n/255` grid point (all renderer call sites)
/// are served from the comptime table; anything else falls back to the exact
/// curve, so off-grid callers keep full precision.
pub fn srgbToLinear(v: f32) f32 {
    if (v >= 0.0 and v <= 1.0) {
        const scaled = v * 255.0;
        const idx = @round(scaled);
        if (scaled == idx) return srgb_to_linear_table[@intFromFloat(idx)];
    }
    return srgbToLinearExact(v);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "srgb lookup table is bit-exact against the reference curve for all bytes" {
    // The table replaced a per-instance `pow` call. It is only a safe swap if
    // it reproduces the reference curve exactly, not approximately.
    var i: u16 = 0;
    while (i <= 255) : (i += 1) {
        const v = @as(f32, @floatFromInt(i)) / 255.0;
        try testing.expectEqual(srgbToLinearExact(v), srgbByteToLinear(@intCast(i)));
        try testing.expectEqual(srgbToLinearExact(v), srgbToLinear(v));
    }
}

test "srgbToLinear keeps exact curve for off-grid inputs" {
    for ([_]f32{ 0.01, 0.03, 0.0404, 0.2, 0.333, 0.75, 0.999 }) |v| {
        try testing.expectEqual(srgbToLinearExact(v), srgbToLinear(v));
    }
}

test "srgbToLinear endpoints and out-of-range inputs stay well defined" {
    try testing.expectEqual(@as(f32, 0.0), srgbToLinear(0.0));
    try testing.expectApproxEqAbs(@as(f32, 1.0), srgbToLinear(1.0), 1e-6);
    // Out-of-range must not index the table.
    try testing.expectEqual(srgbToLinearExact(-0.5), srgbToLinear(-0.5));
    try testing.expectEqual(srgbToLinearExact(1.5), srgbToLinear(1.5));
}

test "toFloat4 converts rgb through the table and alpha linearly" {
    const c = .{ .r = @as(u8, 255), .g = @as(u8, 0), .b = @as(u8, 128), .a = @as(u8, 64) };
    const f = toFloat4(c);
    try testing.expectEqual(srgbToLinearExact(1.0), f[0]);
    try testing.expectEqual(@as(f32, 0.0), f[1]);
    try testing.expectEqual(srgbToLinearExact(128.0 / 255.0), f[2]);
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), f[3], 1e-6);
}
