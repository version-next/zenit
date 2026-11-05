//! Corner-radius normalisation shared by every rounded shape the renderer rasterises.
//! Hit testing uses the same function so a shape hits exactly where the renderer draws.
//!
//! A rounded rect reaches the GPU through several paths: the SDF fill, the overflow shape clip
//! (pushClip), the image pipeline (images and every offscreen-layer composite mask: opacity fold,
//! rounded-clip layer, retained layer), the blend composite and the glass material (shader shape,
//! material veil and composite fallback, GlassGroup members, the D3D11 glass geometry). None of the
//! shaders may be trusted to clamp a radius, so each path must hand them a radius set that already
//! fits its rect, or an oversized radius (a pill's 9999) turns the distance field inside out and
//! the outlines diverge. All of them call `normalize` (or `normalizeUniform` for a shape model with
//! a single radius) with the size of the rect the shape is actually evaluated over.

const std = @import("std");

/// Corner radii TL, TR, BR, BL fitted to a `w` x `h` rect: negative / NaN radii become 0, every
/// corner caps at half the shorter side (the CSS-style per-corner cap the SDF fill has always
/// used; +inf therefore means "fully round").
pub fn normalize(radii: [4]f32, w: f32, h: f32) [4]f32 {
    const half = @min(w, h) / 2;
    const max_r: f32 = if (std.math.isFinite(half) and half > 0) half else 0;
    var out: [4]f32 = undefined;
    for (radii, 0..) |r, i| out[i] = if (r > 0) @min(r, max_r) else 0; // NaN > 0 is false
    return out;
}

/// Largest corner.
pub fn max(radii: [4]f32) f32 {
    return @max(@max(radii[0], radii[1]), @max(radii[2], radii[3]));
}

/// `normalize`, then every corner takes the largest fitted corner. For shape models that carry a
/// single radius (a glass popover with its arrow, the tab lens, a GlassGroup member): a
/// non-uniform request resolves to its largest corner, deterministically and the same way on
/// every consumer of that shape.
pub fn normalizeUniform(radii: [4]f32, w: f32, h: f32) [4]f32 {
    return @splat(max(normalize(radii, w, h)));
}

/// `radii` scaled by `s` (a unit change; NaN and negative values stay invalid for `normalize`).
pub fn scale(radii: [4]f32, s: f32) [4]f32 {
    return .{ radii[0] * s, radii[1] * s, radii[2] * s, radii[3] * s };
}

test "normalizeUniform collapses to the largest fitted corner" {
    try std.testing.expectEqual([4]f32{ 20, 20, 20, 20 }, normalizeUniform(.{ -4, 20, 0, std.math.nan(f32) }, 100, 40));
    try std.testing.expectEqual([4]f32{ 20, 20, 20, 20 }, normalizeUniform(.{ 9999, 0, 0, 0 }, 100, 40));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, normalizeUniform(.{ -1, -1, -1, -1 }, 100, 40));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, normalizeUniform(.{ 8, 8, 8, 8 }, 0, 0));
}

test "normalize caps every corner at half the shorter side" {
    try std.testing.expectEqual([4]f32{ 20, 0, 10, 20 }, normalize(.{ 9999, 0, 10, 20.5 }, 100, 40));
    try std.testing.expectEqual([4]f32{ 0, 0, 3, 5 }, normalize(.{ -4, std.math.nan(f32), 3, std.math.inf(f32) }, 10, 10));
    // Degenerate rects carry no radius.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, normalize(.{ 5, 5, 5, 5 }, 0, 40));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, normalize(.{ 5, 5, 5, 5 }, -3, 40));
    // In-range radii pass through bit for bit.
    try std.testing.expectEqual([4]f32{ 6, 6, 6, 6 }, normalize(.{ 6, 6, 6, 6 }, 120, 64));
}
