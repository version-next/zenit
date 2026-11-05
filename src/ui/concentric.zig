//! ConcentricRectangle / containerShape -- SwiftUI concentric corner radius (macOS 26).
//!
//! Native measurement (scripts/glass_native_model/native_concentric.swift, container radius 30):
//! each corner radius = max(R - max(dx, dy), minimum), where dx/dy is that corner's distance to the
//! container edge; padding 12 -> 18, 24 -> 6, 36 -> 0; asymmetric padding (6,18) and (18,6) both
//! give 12; `.concentric(minimum: 10)` clamps small values to 10; glass (glassEffect in:) follows
//! the same rule. Falls back to minimum when no container is found.
//!
//! Coordinate contract: computed in layout space (globalRect = layout rect + translation + sticky,
//! no scale/rotation); container radius uses its style-local value, same units. Rendering scale
//! (popup animation etc) applies uniformly to node and glass radius, so they stay concentric when
//! scaled together; recompute is skipped if only one is scaled or rotated (unsupported). The four
//! radii land in corner_radius `.each`, so hit and clip follow each corner (`.auto` shapes);
//! border.radius keeps the largest for code that reads a single radius.
const std = @import("std");
const core = @import("core.zig");
const Node = core.Node;
const Cx = core.Cx;
const Color = core.Color;
const reactive = @import("reactive.zig");
const Scope = reactive.Scope;

/// Mark node as container shape (SwiftUI `.containerShape(RoundedRectangle(cornerRadius:))`).
pub fn containerShape(node: *Node, allocator: std.mem.Allocator, radius: f32) !void {
    const ext = try node.style.ensureExtFallible(allocator);
    ext.container_shape_radius = radius;
}

/// Nearest container shape ancestor (excludes self).
pub fn findContainer(node: *const Node) ?*Node {
    var cur = node.parent;
    while (cur) |n| : (cur = n.parent) {
        if (n.style.ext) |ext| {
            if (ext.container_shape_radius > 0) return n;
        }
    }
    return null;
}

/// Pure function: given node and container rect (same coordinate system) and container radius,
/// return TL/TR/BR/BL concentric radii.
pub fn radiiFor(rect: [4]f32, container: [4]f32, radius: f32, minimum: f32) [4]f32 {
    const l = rect[0] - container[0];
    const t = rect[1] - container[1];
    const r = (container[0] + container[2]) - (rect[0] + rect[2]);
    const b = (container[1] + container[3]) - (rect[1] + rect[3]);
    const half = @min(rect[2], rect[3]) / 2;
    const corner = struct {
        fn f(R: f32, dx: f32, dy: f32, m: f32, h: f32) f32 {
            return std.math.clamp(@max(R - @max(dx, dy), m), 0, h);
        }
    }.f;
    return .{
        corner(radius, l, t, minimum, half),
        corner(radius, r, t, minimum, half),
        corner(radius, r, b, minimum, half),
        corner(radius, l, b, minimum, half),
    };
}

/// Node's concentric radius this frame (global coordinates). No container -> minimum.
pub fn concentricRadii(node: *const Node, minimum: f32) [4]f32 {
    const g = node.globalRect();
    const half = @min(g.w, g.h) / 2;
    const m = std.math.clamp(minimum, 0, half);
    const c = findContainer(node) orelse return .{ m, m, m, m };
    const cg = c.globalRect();
    return radiiFor(.{ g.x, g.y, g.w, g.h }, .{ cg.x, cg.y, cg.w, cg.h }, c.style.ext.?.container_shape_radius, minimum);
}

pub const ConcentricRectangleProps = struct {
    /// `.concentric(minimum:)`: clamp concentric radius to at least this value
    minimum: f32 = 0,
    fill: Color = Color.rgba(0, 0, 0, 0),
};

const State = struct { minimum: f32, allocator: std.mem.Allocator, last: [4]f32 = .{ -1, -1, -1, -1 } };

/// Filled concentric rectangle (size from caller's layout): recompute four corners per container
/// each frame, write node only on change.
pub fn ConcentricRectangle(scope: *Scope, cx: *Cx, style: core.BoxStyle, props: ConcentricRectangleProps) !*Node {
    const node = try core.box(cx, style, .{});
    errdefer cx.freeNode(node);
    node.setBackgroundRaw(props.fill);
    const st = try scope.allocator.create(State);
    st.* = .{ .minimum = props.minimum, .allocator = cx.allocator };
    try scope.adoptResource(@ptrCast(st), struct {
        fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            alloc.destroy(@as(*State, @ptrCast(@alignCast(ptr))));
        }
    }.cleanup);
    node.meta.per_frame.hooks.slots.anim_state = @ptrCast(st);
    node.meta.per_frame.hooks.before_render.main = concentricBeforeRender;
    return node;
}

fn concentricBeforeRender(node: *Node) void {
    const st: *State = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    const radii = concentricRadii(node, st.minimum);
    if (std.mem.eql(f32, &radii, &st.last)) return;
    st.last = radii;
    const ext = node.style.ensureExtFallible(st.allocator) catch return;
    ext.corner_radius = .{ .each = radii };
    node.style.border.radius = @max(@max(radii[0], radii[1]), @max(radii[2], radii[3]));
    node.markRenderDirty();
}

test "radiiFor: matches the native ConcentricRectangle captures (container radius 30)" {
    const c = [4]f32{ 0, 0, 120, 120 };
    // Symmetric padding
    try std.testing.expectEqual([4]f32{ 18, 18, 18, 18 }, radiiFor(.{ 12, 12, 96, 96 }, c, 30, 0));
    try std.testing.expectEqual([4]f32{ 6, 6, 6, 6 }, radiiFor(.{ 24, 24, 72, 72 }, c, 30, 0));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, radiiFor(.{ 36, 36, 48, 48 }, c, 30, 0));
    // minimum 10
    try std.testing.expectEqual([4]f32{ 10, 10, 10, 10 }, radiiFor(.{ 36, 36, 48, 48 }, c, 30, 10));
    // Asymmetric: (lead 6, top 18) on 60x60 -> top-left 12, others far from edge -> 0
    try std.testing.expectEqual([4]f32{ 12, 0, 0, 0 }, radiiFor(.{ 6, 18, 60, 60 }, c, 30, 0));
    try std.testing.expectEqual([4]f32{ 12, 0, 0, 0 }, radiiFor(.{ 18, 6, 60, 60 }, c, 30, 0));
}
