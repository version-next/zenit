/// Clip path handling: Bezier subdivision, SVG path -> polygon conversion, clip spec parsing.
const std = @import("std");

const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const display_list_mod = @import("../display_list.zig");
const interaction_semantics = @import("../interaction_semantics.zig");

const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const Point = types.Point;
const PathGeometry = types.PathGeometry;
const Node = node_mod.Node;

pub const RenderClipSpec = struct {
    enabled: bool,
    shape_kind: display_list_mod.ClipShapeKind,
    local_rect: ComputedRect,
    /// Rounded-clip corner radii TL, TR, BR, BL (scaled; zero unless shape_kind == .rounded_rect).
    radii: [4]f32,
    /// Polygon clip (shape_kind == .polygon), in the frame allocator; null otherwise. By
    /// reference: the render states that carry it are copied per node and per pass, and the
    /// polygon is most of their size.
    polygon: ?*const display_list_mod.ClipPolygon,
    bounds_fallback: bool,
};

fn appendPolygonPoint(points: *[display_list_mod.max_clip_polygon_points]Point, point_count: *usize, point: Point) bool {
    if (point_count.* > 0) {
        const prev = points[point_count.* - 1];
        if (std.math.approxEqAbs(f32, prev.x, point.x, 0.0001) and std.math.approxEqAbs(f32, prev.y, point.y, 0.0001)) {
            return true;
        }
    }
    if (point_count.* >= display_list_mod.max_clip_polygon_points) return false;
    points[point_count.*] = point;
    point_count.* += 1;
    return true;
}

fn distancePointToLine(point: Point, line_start: Point, line_end: Point) f32 {
    const dx = line_end.x - line_start.x;
    const dy = line_end.y - line_start.y;
    const len_sq = dx * dx + dy * dy;
    if (len_sq <= 0.000001) {
        return std.math.hypot(point.x - line_start.x, point.y - line_start.y);
    }
    const t = std.math.clamp(((point.x - line_start.x) * dx + (point.y - line_start.y) * dy) / len_sq, 0.0, 1.0);
    const proj_x = line_start.x + dx * t;
    const proj_y = line_start.y + dy * t;
    return std.math.hypot(point.x - proj_x, point.y - proj_y);
}

fn estimateQuadSubdivisionCount(start: Point, ctrl: Point, end: Point) usize {
    const deviation = distancePointToLine(ctrl, start, end);
    const estimated = @as(usize, @intFromFloat(@ceil(deviation / 6.0)));
    return std.math.clamp(estimated + 1, 2, 8);
}

fn estimateCubicSubdivisionCount(start: Point, ctrl1: Point, ctrl2: Point, end: Point) usize {
    const deviation = @max(
        distancePointToLine(ctrl1, start, end),
        distancePointToLine(ctrl2, start, end),
    );
    const estimated = @as(usize, @intFromFloat(@ceil(deviation / 6.0)));
    return std.math.clamp(estimated + 2, 3, 12);
}

fn evalQuadBezier(start: Point, ctrl: Point, end: Point, t: f32) Point {
    const omt = 1.0 - t;
    return .{
        .x = omt * omt * start.x + 2.0 * omt * t * ctrl.x + t * t * end.x,
        .y = omt * omt * start.y + 2.0 * omt * t * ctrl.y + t * t * end.y,
    };
}

fn evalCubicBezier(start: Point, ctrl1: Point, ctrl2: Point, end: Point, t: f32) Point {
    const omt = 1.0 - t;
    const omt2 = omt * omt;
    const t2 = t * t;
    return .{
        .x = omt2 * omt * start.x +
            3.0 * omt2 * t * ctrl1.x +
            3.0 * omt * t2 * ctrl2.x +
            t2 * t * end.x,
        .y = omt2 * omt * start.y +
            3.0 * omt2 * t * ctrl1.y +
            3.0 * omt * t2 * ctrl2.y +
            t2 * t * end.y,
    };
}

fn appendQuadCurvePoints(
    points: *[display_list_mod.max_clip_polygon_points]Point,
    point_count: *usize,
    start: Point,
    ctrl: Point,
    end: Point,
) bool {
    const remaining_budget = display_list_mod.max_clip_polygon_points - point_count.*;
    if (remaining_budget == 0) return false;
    const steps = @max(@as(usize, 1), @min(estimateQuadSubdivisionCount(start, ctrl, end), remaining_budget));
    for (1..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        if (!appendPolygonPoint(points, point_count, evalQuadBezier(start, ctrl, end, t))) return false;
    }
    return true;
}

fn appendCubicCurvePoints(
    points: *[display_list_mod.max_clip_polygon_points]Point,
    point_count: *usize,
    start: Point,
    ctrl1: Point,
    ctrl2: Point,
    end: Point,
) bool {
    const remaining_budget = display_list_mod.max_clip_polygon_points - point_count.*;
    if (remaining_budget == 0) return false;
    const steps = @max(@as(usize, 1), @min(estimateCubicSubdivisionCount(start, ctrl1, ctrl2, end), remaining_budget));
    for (1..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        if (!appendPolygonPoint(points, point_count, evalCubicBezier(start, ctrl1, ctrl2, end, t))) return false;
    }
    return true;
}

pub fn buildClipPolygonFromPathGeometry(geometry: PathGeometry, clip_rect: ComputedRect) display_list_mod.ClipPolygon {
    var polygon = display_list_mod.ClipPolygon.empty();
    if (geometry.commands.len == 0) return polygon;

    var points: [display_list_mod.max_clip_polygon_points]Point = undefined;
    var contour_end_points: [display_list_mod.max_clip_polygon_contours]u8 = @as([display_list_mod.max_clip_polygon_contours]u8, @splat(0));
    var point_count: usize = 0;
    var contour_count: usize = 0;
    var contour_start_idx: usize = 0;
    var subpath_start: ?Point = null;
    var prev: ?Point = null;
    var closed = false;

    const FinalizeContour = struct {
        fn run(
            start: ?Point,
            last: ?Point,
            was_closed: bool,
            points_buf: *[display_list_mod.max_clip_polygon_points]Point,
            points_len: *usize,
            contour_starts_at: usize,
            contour_count_ptr: *usize,
            contour_ends: *[display_list_mod.max_clip_polygon_contours]u8,
        ) bool {
            if (start == null or last == null) return false;
            if (contour_starts_at >= points_len.*) return false;
            const start_pt = start.?;
            const last_pt = last.?;
            if (!was_closed and (!std.math.approxEqAbs(f32, start_pt.x, last_pt.x, 0.0001) or !std.math.approxEqAbs(f32, start_pt.y, last_pt.y, 0.0001))) {
                return false;
            }
            if (points_len.* > contour_starts_at + 1) {
                const last_idx = points_len.* - 1;
                if (std.math.approxEqAbs(f32, points_buf[last_idx].x, start_pt.x, 0.0001) and
                    std.math.approxEqAbs(f32, points_buf[last_idx].y, start_pt.y, 0.0001))
                {
                    points_len.* -= 1;
                }
            }
            if (points_len.* - contour_starts_at < 3) return false;
            if (contour_count_ptr.* >= display_list_mod.max_clip_polygon_contours) return false;
            contour_ends[contour_count_ptr.*] = @intCast(points_len.*);
            contour_count_ptr.* += 1;
            return true;
        }
    };

    for (geometry.commands) |cmd| {
        switch (cmd) {
            .move_to => |pt| {
                if (subpath_start != null) {
                    if (!FinalizeContour.run(subpath_start, prev, closed, &points, &point_count, contour_start_idx, &contour_count, &contour_end_points)) {
                        return display_list_mod.ClipPolygon.empty();
                    }
                }
                contour_start_idx = point_count;
                if (!appendPolygonPoint(&points, &point_count, pt)) return display_list_mod.ClipPolygon.empty();
                subpath_start = pt;
                prev = pt;
                closed = false;
            },
            .line_to => |pt| {
                if (subpath_start == null) return display_list_mod.ClipPolygon.empty();
                if (!appendPolygonPoint(&points, &point_count, pt)) return display_list_mod.ClipPolygon.empty();
                prev = pt;
            },
            .quad_to => |quad| {
                if (subpath_start == null or prev == null) return display_list_mod.ClipPolygon.empty();
                if (!appendQuadCurvePoints(&points, &point_count, prev.?, quad.ctrl, quad.end)) {
                    return display_list_mod.ClipPolygon.empty();
                }
                prev = quad.end;
            },
            .cubic_to => |cubic| {
                if (subpath_start == null or prev == null) return display_list_mod.ClipPolygon.empty();
                if (!appendCubicCurvePoints(&points, &point_count, prev.?, cubic.ctrl1, cubic.ctrl2, cubic.end)) {
                    return display_list_mod.ClipPolygon.empty();
                }
                prev = cubic.end;
            },
            .close => {
                if (subpath_start == null or prev == null) return display_list_mod.ClipPolygon.empty();
                closed = true;
                prev = subpath_start.?;
            },
        }
    }

    if (subpath_start == null or prev == null) {
        return polygon;
    }
    if (!FinalizeContour.run(subpath_start, prev, closed, &points, &point_count, contour_start_idx, &contour_count, &contour_end_points)) {
        return polygon;
    }
    if (point_count < 3 or contour_count == 0) return polygon;

    polygon.point_count = @intCast(point_count);
    polygon.contour_count = @intCast(contour_count);
    polygon.fill_rule = geometry.fill_rule;
    for (0..contour_count) |i| {
        polygon.contour_end_points[i] = contour_end_points[i];
    }
    for (0..point_count) |i| {
        polygon.points[i] = .{
            points[i].x - clip_rect.x,
            points[i].y - clip_rect.y,
        };
    }
    return polygon;
}

/// Whether owner has own content outside "children overflow clip": shadow, outline, visible stroke
/// (clip shrinks within stroke inset, stroke itself outside clip).
///
/// These nodes' overflow clip cannot use node-level mechanism; rounded_clip effect's mask and
/// compositor's apply_clip both activate before owner's own content, clipping shadows to border-box
/// (gray block outside Popover arc), compressing stroke beneath border-adjacent content. They
/// switch to node-local push_clip around children (render_engine emitScrollClipBegin). Nodes
/// without this content clip equally without visual difference, retaining original fold /
/// apply_clip fast path.
pub fn ownerPaintsOutsideChildClip(node: *const Node) bool {
    if (node.style.shadowSlice().len > 0) return true;
    if (node.style.outline()) |o| {
        if (o.width > 0 and o.color.a != 0) return true;
    }
    const border = node.style.border;
    if (border.color.a != 0) {
        const w = border.resolvedWidths();
        if (w[0] > 0 or w[1] > 0 or w[2] > 0 or w[3] > 0) return true;
    }
    return false;
}

/// Overflow clip boundary = **padding box** (border inset), matching CSS.
///
/// The border paints inside the layout rect without consuming layout space, so children can tile
/// under it. A border-box clip would let edge children (color blocks in Popover, first/last table
/// rows) cover the stroke and expose child right angles at rounded corners. Clipping inward keeps
/// the stroke intact; what shows under it is the node's own background.
///
/// Only applies to a **visible** border: a transparent/zero-width border paints nothing, so
/// shrinking would only eat content. Exception: backdrop_blur (glass) nodes, where the clip is also
/// the rounded_clip effect's surface range and the border paints inside that effect; shrinking
/// would cut off its own stroke.
fn clipBorderInsets(node: *const Node) [4]f32 {
    const border = node.style.border;
    if (border.color.a == 0) return .{ 0, 0, 0, 0 };
    if (node.style.backdrop_blur() >= 0.5) return .{ 0, 0, 0, 0 };
    return border.resolvedWidths(); // top, right, bottom, left
}

fn insetApplies(node: *const Node, rect: ComputedRect, inset: [4]f32) bool {
    _ = node;
    if (inset[0] == 0 and inset[1] == 0 and inset[2] == 0 and inset[3] == 0) return false;
    // When border fills entire box (very narrow dividers etc.) don't shrink: zero-area clip culls
    // entire subtree, even owner's stroke.
    return rect.w - inset[1] - inset[3] >= 0.1 and rect.h - inset[0] - inset[2] >= 0.1;
}

/// Shared rectangular padding-box clip, including visible-border and glass
/// exceptions. Accessibility uses the same bounds as paint for rect clips.
pub fn paddingBoxClipRect(node: *const Node, rect: ComputedRect) ComputedRect {
    const inset = clipBorderInsets(node);
    if (!insetApplies(node, rect, inset)) return rect;
    return ComputedRect.init(
        rect.x + inset[3],
        rect.y + inset[0],
        rect.w - inset[1] - inset[3],
        rect.h - inset[0] - inset[2],
    );
}

/// Padding-box (inner) corner radii for an overflow clip, TL, TR, BR, BL, multiplied by
/// `scale`. CSS inner radius = outer radius - adjacent border width; a circular corner takes the
/// wider of its two adjacent sides (TL: top/left, TR: top/right, BR: bottom/right, BL:
/// bottom/left), so a uniform border reduces every corner by the same width.
pub fn paddingBoxClipRadii(node: *const Node, rect: ComputedRect, outer: [4]f32, scale: f32) [4]f32 {
    const inset = clipBorderInsets(node); // top, right, bottom, left
    const applies = insetApplies(node, rect, inset);
    const adjacent = [4]f32{
        @max(inset[0], inset[3]),
        @max(inset[0], inset[1]),
        @max(inset[2], inset[1]),
        @max(inset[2], inset[3]),
    };
    var out: [4]f32 = undefined;
    for (outer, adjacent, 0..) |radius, side, i| {
        const inner = if (applies) @max(radius - side, 0) else radius;
        out[i] = @max(inner * scale, 0);
    }
    return out;
}

pub fn resolveNodeRenderClipSpec(cx: *@import("render_context.zig").RenderContext, node: *Node, allocator: Allocator, scale_min: f32) RenderClipSpec {
    // Read rect from World.LayoutTable.
    const node_world_rect = cx.rectFromWorld(node);
    const node_local_rect = ComputedRect.init(0, 0, node_world_rect.w, node_world_rect.h);
    if (!node.style.overflow_hidden) {
        return .{
            .enabled = false,
            .shape_kind = .rect,
            .local_rect = node_local_rect,
            .radii = .{ 0, 0, 0, 0 },
            .polygon = null,
            .bounds_fallback = false,
        };
    }

    const clip_shape = interaction_semantics.nodeClipShape(node);
    if (clip_shape == .custom) {
        // Intentional swallow: custom_clip generated by user-injected provider, failure reasons not
        // limited to OOM. Below `.custom => lo_vec.fill.custom_clip orelse lo_vec.fill.path`
        // explicitly declares fallback path, reverting to node's own path clipping, still valid
        // clip shape, no overflow.
        node.ensureCustomClipGeometry(allocator) catch {};
    }
    const lo_vec = if (node.layoutOutput()) |lo| lo.vector else @import("../node_layout_output.zig").NodeVector{};
    const clip_geometry = switch (clip_shape) {
        .path => lo_vec.fill.path,
        .custom => lo_vec.fill.custom_clip orelse lo_vec.fill.path,
        else => null,
    };
    return switch (clip_shape) {
        .none => .{
            .enabled = false,
            .shape_kind = .rect,
            .local_rect = node_local_rect,
            .radii = .{ 0, 0, 0, 0 },
            .polygon = null,
            .bounds_fallback = false,
        },
        .rect, .ellipse, .path, .custom => blk: {
            const local_rect = switch (clip_shape) {
                .path, .custom => blk2: {
                    if (clip_geometry) |geometry| {
                        const bounds = geometry.bounds;
                        const x1 = std.math.clamp(bounds.x, 0.0, node_world_rect.w);
                        const y1 = std.math.clamp(bounds.y, 0.0, node_world_rect.h);
                        const x2 = std.math.clamp(bounds.x + bounds.w, 0.0, node_world_rect.w);
                        const y2 = std.math.clamp(bounds.y + bounds.h, 0.0, node_world_rect.h);
                        if (x2 > x1 and y2 > y1) {
                            break :blk2 ComputedRect.init(x1, y1, x2 - x1, y2 - y1);
                        }
                    }
                    break :blk2 node_local_rect;
                },
                .rect => paddingBoxClipRect(node, node_local_rect),
                else => node_local_rect,
            };
            const has_geometry = (clip_shape == .path or clip_shape == .custom) and clip_geometry != null;
            // Stored whenever it was built (null reads as the empty polygon). One that cannot be
            // stored degrades exactly like one that cannot be built (bounds fallback).
            const stored: ?*display_list_mod.ClipPolygon = if (has_geometry) (cx.frame_allocator.create(display_list_mod.ClipPolygon) catch null) else null;
            if (stored) |p| p.* = buildClipPolygonFromPathGeometry(clip_geometry.?, local_rect);
            const polygon = if (stored) |p| p.* else display_list_mod.ClipPolygon.empty();
            break :blk .{
                // Render runtime currently supports precise rect / rounded-rect / ellipse clip masks.
                // Path-backed path/custom clip semantics use the polygon primitive when geometry exists.
                // Remaining custom clip semantics still degrade conservatively.
                .enabled = true,
                .shape_kind = switch (clip_shape) {
                    .path, .custom => if (polygon.point_count != 0 and polygon.contour_count != 0) .polygon else .rect,
                    .ellipse => .ellipse,
                    else => .rect,
                },
                .local_rect = local_rect,
                .radii = .{ 0, 0, 0, 0 },
                .polygon = stored,
                .bounds_fallback = (clip_shape == .path or clip_shape == .custom) and (polygon.point_count == 0 or polygon.contour_count == 0),
            };
        },
        .rounded_rect, .rounded_corners => {
            const outer: [4]f32 = switch (clip_shape) {
                .rounded_rect => |radius| .{ radius, radius, radius, radius },
                .rounded_corners => |radii| radii,
                else => unreachable,
            };
            return .{
                .enabled = true,
                .shape_kind = .rounded_rect,
                .local_rect = paddingBoxClipRect(node, node_local_rect),
                .radii = paddingBoxClipRadii(node, node_local_rect, outer, scale_min),
                .polygon = null,
                .bounds_fallback = false,
            };
        },
        .auto => unreachable,
    };
}
