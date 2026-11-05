//! Clip geometry algebra: pure functions decoupled from encoder state.
//!
//! This cluster answers: **are two clip shapes equivalent / what is the intersection of two
//! rectangles / how do external duck-typed polygons normalize to the encoder's fixed-length
//! ClipPolygon**. All take and return values only: no self, no allocation, no side effects. Stack
//! **push/pop** stays in the encoder (clip_depth / logical_clip_stack / effective_rect_clip_stack);
//! **comparison and normalization** of stack elements live here.
//!
//! Equivalence always uses approxEqAbs(1e-4): clip coords go through world->local projection and
//! DPI scaling, so bitwise comparison would treat the same clip as different and rebuild the clip
//! mask every frame.
//!
//! command_encoder.zig re-exports the same names (including pub intersectClipRects).

const std = @import("std");

/// These types still owned by command_encoder.zig (its public API surface), received here per
/// struct contract; passing comptime type params makes signature more complex than migration
/// itself, so use anytype + explicit return type keeps call sites zero-change.
pub fn clipPolygonEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a.point_count != b.point_count or a.contour_count != b.contour_count or a.fill_rule != b.fill_rule) return false;
    const max_contours = a.contour_end_points.len;
    const max_points = a.points.len;
    const contour_count = @min(@as(usize, a.contour_count), max_contours);
    for (0..contour_count) |i| {
        if (a.contour_end_points[i] != b.contour_end_points[i]) return false;
    }
    const count = @min(@as(usize, a.point_count), max_points);
    for (0..count) |i| {
        if (!std.math.approxEqAbs(f32, a.points[i][0], b.points[i][0], 0.0001) or
            !std.math.approxEqAbs(f32, a.points[i][1], b.points[i][1], 0.0001))
        {
            return false;
        }
    }
    return true;
}

/// Rounded clip state equivalence. null == null treated as equivalent (both mean 'no rounded
/// clip').
pub fn roundedClipEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const lhs = a.?;
    const rhs = b.?;
    return std.math.approxEqAbs(f32, lhs.x, rhs.x, 0.0001) and
        std.math.approxEqAbs(f32, lhs.y, rhs.y, 0.0001) and
        std.math.approxEqAbs(f32, lhs.w, rhs.w, 0.0001) and
        std.math.approxEqAbs(f32, lhs.h, rhs.h, 0.0001) and
        radiiEqual(lhs.radii, rhs.radii) and
        lhs.shape_kind == rhs.shape_kind and
        clipPolygonEqual(lhs.polygon, rhs.polygon) and
        (if (comptime @hasField(@TypeOf(lhs), "partner")) partnerEqual(lhs.partner, rhs.partner) else true);
}

fn partnerEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const lhs = a.?;
    const rhs = b.?;
    return std.math.approxEqAbs(f32, lhs.x, rhs.x, 0.0001) and
        std.math.approxEqAbs(f32, lhs.y, rhs.y, 0.0001) and
        std.math.approxEqAbs(f32, lhs.w, rhs.w, 0.0001) and
        std.math.approxEqAbs(f32, lhs.h, rhs.h, 0.0001) and
        radiiEqual(lhs.radii, rhs.radii) and
        lhs.shape_kind == rhs.shape_kind;
}

fn radiiEqual(a: [4]f32, b: [4]f32) bool {
    for (a, b) |l, r| if (!std.math.approxEqAbs(f32, l, r, 0.0001)) return false;
    return true;
}

/// Intersect two [x, y, w, h] rects. No overlap returns zero-area rect (keep top-left so caller's
/// scissor stays legal input not negative width/height).
pub fn intersectClipRects(a: [4]f32, b: [4]f32) [4]f32 {
    const x1 = @max(a[0], b[0]);
    const y1 = @max(a[1], b[1]);
    const x2 = @min(a[0] + a[2], b[0] + b[2]);
    const y2 = @min(a[1] + a[3], b[1] + b[3]);
    if (x2 <= x1 or y2 <= y1) return .{ x1, y1, 0, 0 };
    return .{ x1, y1, x2 - x1, y2 - y1 };
}

/// Duck-typed external polygon -> encoder fixed-length ClipPolygon.
///
/// `Out` is command_encoder.ClipPolygon; `coerceFillRule` converts source fill_rule enum to encoder
/// side same-sequence enum. Source types missing fields degrade to empty polygon, points/outlines
/// exceeding fixed-length capacity clamped to limit (encoder clip polygon is fixed array).
pub fn coerceClipPolygon(
    comptime Out: type,
    polygon: anytype,
    comptime coerceFillRule: anytype,
) Out {
    var out = Out.empty();
    if (!@hasField(@TypeOf(polygon), "point_count") or !@hasField(@TypeOf(polygon), "points")) {
        return out;
    }
    const max_points = out.points.len;
    const max_contours = out.contour_end_points.len;
    const count = @min(@as(usize, polygon.point_count), max_points);
    out.point_count = @intCast(count);
    if (@hasField(@TypeOf(polygon), "fill_rule")) {
        out.fill_rule = coerceFillRule(polygon.fill_rule);
    }
    if (@hasField(@TypeOf(polygon), "contour_count") and @hasField(@TypeOf(polygon), "contour_end_points")) {
        const contour_count = @min(@as(usize, polygon.contour_count), max_contours);
        out.contour_count = @intCast(contour_count);
        for (0..contour_count) |i| {
            out.contour_end_points[i] = @min(polygon.contour_end_points[i], out.point_count);
        }
    } else if (count > 0) {
        out.contour_count = 1;
        out.contour_end_points[0] = out.point_count;
    }
    for (0..count) |i| {
        out.points[i] = polygon.points[i];
    }
    return out;
}

// ── Nested shape clips ─────────────────────────────────────────────────────────────────────────
//
// Every pipeline evaluates exactly one shape clip (the uniform clip mask). A render target can
// therefore hold one shape clip at a time; a second shape clip pushed while one is active is
// placed so the target still sees the exact intersection:
//
// - `.replace`: the new shape lies inside the active one, so it alone is the intersection;
// - `.keep_outer`: the active shape lies inside the new one; the new clip only narrows the
//   rect clip and the active shape stays in force;
// - `.merged`: both are rounded rects over the same rect; the intersection is that rect with the
//   larger radius at each corner;
// - `.isolate`: the shapes genuinely cross. The content goes into its own offscreen layer where
//   the new shape is the only shape clip, and the layer composites under the active one.
//
// The containment tests are exact for rounded rects (ellipse / polygon shapes are bounded by
// their bounding box, which only ever errs toward `.isolate`).

pub const NestedShapePlacement = union(enum) {
    replace,
    keep_outer,
    merged: [4]f32,
    isolate,
};

/// Tolerance (logical px) for treating a shape as inside another: far below one device pixel.
const containment_eps: f32 = 0.01;

/// Axis-aligned rect with per-corner radii (TL, TR, BR, BL), already fitted to the rect.
pub const RoundedBox = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radii: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Corner k of a box: outward signs (TL = -x -y, TR = +x -y, BR = +x +y, BL = -x +y).
const corner_signs = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };

fn cornerPoint(b: RoundedBox, k: usize) [2]f32 {
    return .{
        if (corner_signs[k][0] < 0) b.x else b.x + b.w,
        if (corner_signs[k][1] < 0) b.y else b.y + b.h,
    };
}

/// Centre of corner k's arc (radius r): the corner point moved r inward on both axes.
fn arcCenter(b: RoundedBox, k: usize, r: f32) [2]f32 {
    const p = cornerPoint(b, k);
    return .{ p[0] - corner_signs[k][0] * r, p[1] - corner_signs[k][1] * r };
}

/// Whether rounded box `inner` lies inside rounded box `outer` (both convex).
///
/// Outside outer's rounded corners the boxes are rects, so the test reduces to rect containment
/// plus, for each rounded outer corner, "no point of inner lies in that corner's cut-out" (beyond
/// the arc, inside the corner square). Distance from the arc centre is convex, so its maximum over
/// inner ∩ corner quadrant sits on an extreme point of inner (a square corner, an arc end, or the
/// arc point farthest from the centre) or on the quadrant boundary, which rect containment already
/// keeps within the arc's reach.
pub fn roundedBoxContains(outer: RoundedBox, inner: RoundedBox) bool {
    const e = containment_eps;
    if (inner.x < outer.x - e or inner.y < outer.y - e or
        inner.x + inner.w > outer.x + outer.w + e or inner.y + inner.h > outer.y + outer.h + e) return false;
    for (0..4) |k| {
        const ro = outer.radii[k];
        if (ro <= e) continue;
        const co = arcCenter(outer, k, ro);
        const s = corner_signs[k];
        for (0..4) |j| {
            const rn = inner.radii[j];
            var candidates: [3][2]f32 = undefined;
            var n: usize = 0;
            if (rn <= e) {
                candidates[0] = cornerPoint(inner, j);
                n = 1;
            } else {
                const cn = arcCenter(inner, j, rn);
                const t = corner_signs[j];
                candidates[0] = .{ cn[0] + t[0] * rn, cn[1] };
                candidates[1] = .{ cn[0], cn[1] + t[1] * rn };
                n = 2;
                // The arc point farthest from co lies along co -> cn, if that direction is within
                // the arc's quarter (pointing out of inner's corner j on both axes).
                const d = [2]f32{ cn[0] - co[0], cn[1] - co[1] };
                const len = @sqrt(d[0] * d[0] + d[1] * d[1]);
                if (len > 1e-6 and d[0] * t[0] >= 0 and d[1] * t[1] >= 0) {
                    candidates[2] = .{ cn[0] + d[0] / len * rn, cn[1] + d[1] / len * rn };
                    n = 3;
                }
            }
            for (candidates[0..n]) |p| {
                const in_quadrant = (p[0] - co[0]) * s[0] > e and (p[1] - co[1]) * s[1] > e;
                if (!in_quadrant) continue;
                const dx = p[0] - co[0];
                const dy = p[1] - co[1];
                if (@sqrt(dx * dx + dy * dy) > ro + e) return false;
            }
        }
    }
    return true;
}

/// The rounded box a clip state is exactly (`.rect` / `.rounded_rect`), or null.
fn exactBox(clip: anytype) ?RoundedBox {
    return switch (clip.shape_kind) {
        .rect => .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h },
        .rounded_rect => .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h, .radii = clip.radii },
        else => null,
    };
}

/// A rect containing the clip shape: the shape itself for rects / rounded rects, the clip rect
/// for an ellipse, the points' bounding box for a polygon (points are relative to the clip
/// origin).
fn boundingBox(clip: anytype) RoundedBox {
    if (exactBox(clip)) |b| return b;
    if (clip.shape_kind == .polygon) {
        const count = @min(@as(usize, clip.polygon.point_count), clip.polygon.points.len);
        if (count > 0) {
            var lo = clip.polygon.points[0];
            var hi = lo;
            for (clip.polygon.points[1..count]) |p| {
                lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
                hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
            }
            return .{ .x = clip.x + lo[0], .y = clip.y + lo[1], .w = hi[0] - lo[0], .h = hi[1] - lo[1] };
        }
    }
    return .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h };
}

fn isSquare(b: RoundedBox) bool {
    for (b.radii) |r| if (r > containment_eps) return false;
    return true;
}

fn sameRect(a: RoundedBox, b: RoundedBox) bool {
    return std.math.approxEqAbs(f32, a.x, b.x, 0.0001) and std.math.approxEqAbs(f32, a.y, b.y, 0.0001) and
        std.math.approxEqAbs(f32, a.w, b.w, 0.0001) and std.math.approxEqAbs(f32, a.h, b.h, 0.0001);
}

/// Where a shape clip `inner` goes when shape clip `outer` is already active in the target (see
/// NestedShapePlacement). Both carry normalised radii (pushClip fits them to their rects).
pub fn placeNestedShapeClip(outer: anytype, inner: @TypeOf(outer)) NestedShapePlacement {
    const outer_exact = exactBox(outer);
    const inner_exact = exactBox(inner);
    // A rounded rect without a rounded corner is its rect, which the rect clip stack already
    // intersects exactly: such an outer leaves the shape slot to the inner, such an inner needs
    // no shape at all.
    if (outer_exact) |o| if (isSquare(o)) return .replace;
    if (inner_exact) |i| if (isSquare(i)) return .keep_outer;
    if (outer_exact != null and inner_exact != null and sameRect(outer_exact.?, inner_exact.?)) {
        var radii: [4]f32 = undefined;
        for (0..4) |k| radii[k] = @max(outer_exact.?.radii[k], inner_exact.?.radii[k]);
        return .{ .merged = radii };
    }
    if (outer_exact) |o| if (roundedBoxContains(o, boundingBox(inner))) return .replace;
    if (inner_exact) |i| if (roundedBoxContains(i, boundingBox(outer))) return .keep_outer;
    return .isolate;
}

/// placeNestedShapeClip limited to `visible` (the rect clip in force, target coordinates):
/// pixels outside it are clipped anyway, so a shape only has to contain the other one inside it.
pub fn placeNestedShapeClipWithin(outer: anytype, inner: @TypeOf(outer), visible: ?[4]f32) NestedShapePlacement {
    const placement = placeNestedShapeClip(outer, inner);
    if (placement != .isolate) return placement;
    const rect = visible orelse return placement;
    const inner_visible = visiblePart(boundingBox(inner), rect) orelse return .replace;
    if (exactBox(outer)) |o| if (roundedBoxContains(o, inner_visible)) return .replace;
    const outer_visible = visiblePart(boundingBox(outer), rect) orelse return .keep_outer;
    if (exactBox(inner)) |i| if (roundedBoxContains(i, outer_visible)) return .keep_outer;
    return .isolate;
}

/// `box` ∩ `rect`, or null when empty. A box the rect cuts loses its corners (a superset of the
/// shape's visible part, so containment tests stay conservative).
fn visiblePart(box: RoundedBox, rect: [4]f32) ?RoundedBox {
    const x0 = @max(box.x, rect[0]);
    const y0 = @max(box.y, rect[1]);
    const x1 = @min(box.x + box.w, rect[0] + rect[2]);
    const y1 = @min(box.y + box.h, rect[1] + rect[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    const e = containment_eps;
    const uncut = x0 <= box.x + e and y0 <= box.y + e and x1 >= box.x + box.w - e and y1 >= box.y + box.h - e;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0, .radii = if (uncut) box.radii else .{ 0, 0, 0, 0 } };
}

/// The shape clips a target holds after a new shape clip is pushed where `active` (one shape,
/// or a primary and its partner, see shape_clip_pair.zig) is in force.
pub fn ShapeClipResolution(comptime Clip: type) type {
    return union(enum) {
        /// The new shape contains an active one: the active shapes stay in force (the new clip
        /// still narrows the rect clip).
        redundant,
        /// The shapes to hold: `shapes[0]` is the primary (a polygon if any), `shapes[1]` its
        /// partner when `count == 2` (never a polygon).
        shapes: struct { count: u2, shapes: [2]Clip },
        /// Three shapes genuinely cross, or two polygons do: isolate the new one.
        isolate,
    };
}

/// Fold a new shape clip into the active ones, within the `visible` rect clip. An active shape
/// that contains the new one drops out; one with the same rect merges into it per corner (placeNestedShapeClip); the rest stay.
/// Up to two shapes evaluate in the shaders, so only a third crossing shape needs isolation.
pub fn resolveShapeClips(active: anytype, new: @TypeOf(active[0]), visible: ?[4]f32) ShapeClipResolution(@TypeOf(active[0])) {
    const Clip = @TypeOf(active[0]);
    var next = new;
    var kept: [2]Clip = undefined;
    var kept_count: usize = 0;
    for (active) |shape| {
        switch (placeNestedShapeClipWithin(shape, next, visible)) {
            .keep_outer => return .redundant,
            .replace => {},
            .merged => |radii| next.radii = radii,
            .isolate => {
                kept[kept_count] = shape;
                kept_count += 1;
            },
        }
    }
    if (kept_count == 0) return .{ .shapes = .{ .count = 1, .shapes = .{ next, next } } };
    if (kept_count > 1) return .isolate;
    const old = kept[0];
    if (next.shape_kind == .polygon and old.shape_kind == .polygon) return .isolate;
    return if (old.shape_kind == .polygon)
        .{ .shapes = .{ .count = 2, .shapes = .{ old, next } } }
    else
        .{ .shapes = .{ .count = 2, .shapes = .{ next, old } } };
}

const TestClip = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    shape_kind: enum { rect, rounded_rect, ellipse, polygon } = .rounded_rect,
    polygon: struct { point_count: u8 = 0, points: [32][2]f32 = @splat(.{ 0, 0 }) } = .{},
};

test "roundedBoxContains: exact at the rounded corners" {
    const outer = RoundedBox{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 20, 20, 20, 20 } };
    // Same rect, square corners: the corners poke out of every arc.
    try std.testing.expect(!roundedBoxContains(outer, .{ .x = 0, .y = 0, .w = 100, .h = 40 }));
    // Same rect, larger radii everywhere: inside.
    try std.testing.expect(roundedBoxContains(outer, .{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 20, 20, 20, 20 } }));
    // A rect inset past the arcs' reach (20 - 20/sqrt2 = 5.86 on the diagonal) fits.
    try std.testing.expect(roundedBoxContains(outer, .{ .x = 6, .y = 6, .w = 88, .h = 28 }));
    try std.testing.expect(!roundedBoxContains(outer, .{ .x = 5.5, .y = 5.5, .w = 89, .h = 29 }));
    // A rect hugging one edge away from the corners fits; sliding it into a corner does not.
    try std.testing.expect(roundedBoxContains(outer, .{ .x = 20, .y = 0, .w = 60, .h = 10 }));
    try std.testing.expect(!roundedBoxContains(outer, .{ .x = 10, .y = 0, .w = 60, .h = 10 }));
    // A concentric inset rounded box (padding 4, inner radius 16) fits exactly.
    try std.testing.expect(roundedBoxContains(outer, .{ .x = 4, .y = 4, .w = 92, .h = 32, .radii = .{ 16, 16, 16, 16 } }));
    // ...with a smaller inner radius its corners cross the outer arcs (farthest arc point 5.17
    // in on the diagonal, the outer arc reaches 5.86).
    try std.testing.expect(!roundedBoxContains(outer, .{ .x = 4, .y = 4, .w = 92, .h = 32, .radii = .{ 4, 4, 4, 4 } }));
    // ...and with padding 8 the same small radius stays clear of them.
    try std.testing.expect(roundedBoxContains(outer, .{ .x = 8, .y = 8, .w = 84, .h = 24, .radii = .{ 4, 4, 4, 4 } }));
    // Not inside the rect at all.
    try std.testing.expect(!roundedBoxContains(outer, .{ .x = 50, .y = 10, .w = 60, .h = 10 }));
}

test "placeNestedShapeClip: same rect merges per corner, containment keeps one shape, crossing isolates" {
    const parent = TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 20, 20, 20, 20 } };
    // The review's case: same box, child rounds only TR (10). Intersection = parent's corners.
    const merged = placeNestedShapeClip(parent, TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 0, 10, 0, 0 } });
    try std.testing.expectEqual(NestedShapePlacement{ .merged = .{ 20, 20, 20, 20 } }, merged);
    // Three nested owners each rounding a different corner fold into one shape.
    const two = placeNestedShapeClip(TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 20, 0, 0, 0 } }, TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 0, 20, 0, 0 } });
    try std.testing.expectEqual(NestedShapePlacement{ .merged = .{ 20, 20, 0, 0 } }, two);
    // Child well inside the parent's arcs: the child alone is the intersection.
    try std.testing.expectEqual(NestedShapePlacement.replace, placeNestedShapeClip(parent, TestClip{ .x = 20, .y = 8, .w = 60, .h = 24, .radii = .{ 4, 0, 4, 0 } }));
    // Parent inside the child: the parent stays in force.
    try std.testing.expectEqual(NestedShapePlacement.keep_outer, placeNestedShapeClip(TestClip{ .x = 10, .y = 10, .w = 20, .h = 20, .radii = .{ 10, 10, 10, 10 } }, TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 4, 4, 4, 4 } }));
    // Child flush with the parent's TL corner but offset: shapes cross.
    try std.testing.expectEqual(NestedShapePlacement.isolate, placeNestedShapeClip(parent, TestClip{ .x = 0, .y = 0, .w = 60, .h = 40, .radii = .{ 0, 10, 0, 0 } }));
    // An ellipse inside the parent by its bounding box replaces; one reaching a corner isolates.
    try std.testing.expectEqual(NestedShapePlacement.replace, placeNestedShapeClip(parent, TestClip{ .x = 20, .y = 6, .w = 60, .h = 28, .shape_kind = .ellipse }));
    try std.testing.expectEqual(NestedShapePlacement.isolate, placeNestedShapeClip(parent, TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .shape_kind = .ellipse }));
    // A polygon is bounded by its points, not its clip rect.
    var poly = TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .shape_kind = .polygon };
    poly.polygon.point_count = 3;
    poly.polygon.points[0] = .{ 30, 10 };
    poly.polygon.points[1] = .{ 70, 10 };
    poly.polygon.points[2] = .{ 50, 30 };
    try std.testing.expectEqual(NestedShapePlacement.replace, placeNestedShapeClip(parent, poly));
    // Zero-radius rounded rects are plain rects: the rect stack intersects them exactly.
    try std.testing.expectEqual(NestedShapePlacement.replace, placeNestedShapeClip(TestClip{ .x = 0, .y = 0, .w = 50, .h = 40 }, parent));
    try std.testing.expectEqual(NestedShapePlacement.keep_outer, placeNestedShapeClip(parent, TestClip{ .x = 0, .y = 0, .w = 50, .h = 40 }));
    // An active ellipse is never assumed to contain anything.
    try std.testing.expectEqual(NestedShapePlacement.isolate, placeNestedShapeClip(TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .shape_kind = .ellipse }, TestClip{ .x = 40, .y = 15, .w = 20, .h = 10, .radii = .{ 2, 2, 2, 2 } }));
}

test "resolveShapeClips: two crossing shapes pair, a third crossing one isolates" {
    const R = ShapeClipResolution(TestClip);
    // zeditor's editor panel (r 9.5) and its scroll viewport (r 10), 0.5 px wider on each side.
    const panel = TestClip{ .x = 269.5, .y = 38.5, .w = 704, .h = 535, .radii = .{ 9.5, 9.5, 9.5, 9.5 } };
    const viewport = TestClip{ .x = 269, .y = 82, .w = 705, .h = 492, .radii = .{ 10, 10, 10, 10 } };
    try std.testing.expectEqual(NestedShapePlacement.isolate, placeNestedShapeClip(panel, viewport));
    const panel_rect = [4]f32{ 269.5, 38.5, 704, 535 };
    const pair = resolveShapeClips(&[_]TestClip{panel}, viewport, panel_rect);
    try std.testing.expectEqual(@as(u2, 2), pair.shapes.count);
    try std.testing.expectEqual(viewport.y, pair.shapes.shapes[0].y);
    try std.testing.expectEqual(panel.y, pair.shapes.shapes[1].y);
    // A thin bar hugging the viewport's top-left arc crosses the viewport. It pokes 0.5 px out of
    // the panel's left edge, but that column is outside the rect clip: the panel drops out and
    // the bar pairs with the viewport.
    const visible = intersectClipRects(panel_rect, .{ viewport.x, viewport.y, viewport.w, viewport.h });
    const bar = TestClip{ .x = 269, .y = 82, .w = 641, .h = 2, .radii = .{ 1, 1, 1, 1 } };
    try std.testing.expect(resolveShapeClips(&[_]TestClip{ viewport, panel }, bar, null) == R.isolate);
    const swapped = resolveShapeClips(&[_]TestClip{ viewport, panel }, bar, visible);
    try std.testing.expectEqual(@as(u2, 2), swapped.shapes.count);
    try std.testing.expectEqual(bar.h, swapped.shapes.shapes[0].h);
    try std.testing.expectEqual(viewport.h, swapped.shapes.shapes[1].h);
    // Near the top-left the panel is outside the visible rect, so a shape there drops it...
    const top = TestClip{ .x = 260, .y = 30, .w = 30, .h = 70, .radii = .{ 12, 12, 12, 12 } };
    try std.testing.expectEqual(@as(u2, 2), resolveShapeClips(&[_]TestClip{ viewport, panel }, top, visible).shapes.count);
    // ...at the bottom-left both arcs are visible: a shape crossing both isolates.
    const corner = TestClip{ .x = 260, .y = 540, .w = 40, .h = 40, .radii = .{ 15, 15, 15, 15 } };
    try std.testing.expect(resolveShapeClips(&[_]TestClip{ viewport, panel }, corner, visible) == R.isolate);
    // A shape containing one active shape changes nothing.
    const big = TestClip{ .x = 0, .y = 0, .w = 2000, .h = 2000, .radii = .{ 4, 4, 4, 4 } };
    try std.testing.expect(resolveShapeClips(&[_]TestClip{ viewport, panel }, big, visible) == R.redundant);
    // Same rect as an active shape: merged per corner, the other active shape stays paired.
    const same = TestClip{ .x = 269, .y = 82, .w = 705, .h = 492, .radii = .{ 0, 20, 0, 0 } };
    const merged = resolveShapeClips(&[_]TestClip{ viewport, panel }, same, visible);
    try std.testing.expectEqual(@as(u2, 2), merged.shapes.count);
    try std.testing.expectEqual([4]f32{ 10, 20, 10, 10 }, merged.shapes.shapes[0].radii);
    // Inside both: the new shape alone.
    const inside = TestClip{ .x = 400, .y = 200, .w = 50, .h = 50, .radii = .{ 4, 4, 4, 4 } };
    try std.testing.expectEqual(@as(u2, 1), resolveShapeClips(&[_]TestClip{ viewport, panel }, inside, visible).shapes.count);
}

test "resolveShapeClips: a polygon stays primary and two polygons isolate" {
    const R = ShapeClipResolution(TestClip);
    const rounded = TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .radii = .{ 20, 20, 20, 20 } };
    var poly = TestClip{ .x = 0, .y = 0, .w = 100, .h = 40, .shape_kind = .polygon };
    poly.polygon.point_count = 3;
    poly.polygon.points[0] = .{ 0, 0 };
    poly.polygon.points[1] = .{ 100, 0 };
    poly.polygon.points[2] = .{ 50, 40 };
    const a = resolveShapeClips(&[_]TestClip{poly}, rounded, null);
    try std.testing.expectEqual(@as(u2, 2), a.shapes.count);
    try std.testing.expect(a.shapes.shapes[0].shape_kind == .polygon);
    const b = resolveShapeClips(&[_]TestClip{rounded}, poly, null);
    try std.testing.expect(b.shapes.shapes[0].shape_kind == .polygon);
    try std.testing.expect(resolveShapeClips(&[_]TestClip{poly}, poly, null) == R.isolate);
}
