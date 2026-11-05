const std = @import("std");
const corner_radii = @import("zenit_corner_radii");
const node_mod = @import("node.zig");
const types = @import("types.zig");

const Node = node_mod.Node;
const HitBehavior = types.HitBehavior;
const HitRoles = types.HitRoles;
const HitShapeSpec = types.HitShapeSpec;
const ClipShapeSpec = types.ClipShapeSpec;

pub fn nodeParticipatesInHitTest(node: *const Node) bool {
    // Align with render rules: opacity <= 0 invisible and should not hit. display:none
    // excludes subtree from hit (buildRecursive cuts entire subtree here).
    return node.style.display != .none and node.frame_state.state_bits.flags.hit_test_visible and node.getOpacity() > 0;
}

pub fn nodeCreatesHitProxy(node: *const Node) bool {
    if (!nodeParticipatesInHitTest(node)) return false;
    const roles = nodeHitRoles(node);
    return roles.any();
}

pub fn nodeHitRoles(node: *const Node) HitRoles {
    // Per-role override: only take explicit ones, rest use derived defaults.
    var roles = node.style.hit_roles().apply(defaultRoles(node));
    if (node.frame_state.state_bits.flags.inspect_pick_disabled) roles.inspect = false;
    return roles;
}

pub fn nodeHitBehavior(node: *const Node) HitBehavior {
    return node.style.hit_behavior() orelse defaultBehavior(node);
}

pub fn nodeHitShape(node: *const Node) HitShapeSpec {
    const explicit = node.style.hit_shape();
    return switch (explicit) {
        .auto => defaultHitShape(node),
        else => explicit,
    };
}

/// Overflow clip used by hit testing: StyleExt.hit_clip_shape when set, else (null or .auto)
/// the paint clip. The hit clip chain is a snapshot taken at interaction rebuild, so an override
/// that does not depend on per-frame geometry (.rect) is what keeps hits exact while the paint
/// clip's radius changes every frame.
pub fn nodeHitClipShape(node: *const Node) ClipShapeSpec {
    const explicit = node.style.getExt().hit_clip_shape orelse return nodeClipShape(node);
    return if (explicit == .auto) nodeClipShape(node) else explicit;
}

pub fn nodeClipShape(node: *const Node) ClipShapeSpec {
    const explicit = node.style.clip_shape();
    return switch (explicit) {
        .auto => defaultClipShape(node),
        else => explicit,
    };
}

fn defaultRoles(node: *const Node) HitRoles {
    // Plain nodes with on_scroll handler (canvas-like) count as scroll owner, else
    // hit-test never hits it, on_scroll is inert.
    const is_scroll_owner = node.tag == .scroll or
        node.behavior.events.on_scroll != null or
        componentNameEquals(node, "ScrollArea") or
        componentNameEquals(node, "VirtualList");
    // Likewise: nodes with drop target handler must participate in pointer hit, else
    // handleDrag's hitTestQuery never hits it, on_drop is inert.
    const is_drop_target = node.behavior.events.on_drop != null or
        node.behavior.events.on_drag_enter != null or
        node.behavior.events.on_drag_leave != null;
    // A hit_behavior declaring "intercept pointer" must implicitly include the pointer role,
    // else roleAllowsQuery filters it first and the behavior never fires.
    //
    // Must read the raw style field, not call nodeHitBehavior(): defaultBehavior calls
    // nodeHitRoles -> defaultRoles, so using the former recurses infinitely.
    const behavior_intercepts = if (node.style.hit_behavior()) |b| switch (b) {
        .@"opaque", .self_only, .self_and_children => true,
        .pass_through, .children_only => false,
    } else false;
    return .{
        .pointer = behavior_intercepts or
            node.cursor_query != null or node.style.cursor != .inherit or
            node.behavior.interaction.focusable or
            node.behavior.events.on_click != null or
            node.behavior.events.on_hover != null or
            node.behavior.events.on_event != null or
            is_drop_target or
            node.tag == .button or
            node.tag == .input,
        .scroll = is_scroll_owner,
        .inspect = node.frame_state.state_bits.flags.inspectable,
        .window_chrome = true,
    };
}

fn defaultBehavior(node: *const Node) HitBehavior {
    const roles = nodeHitRoles(node);
    if (roles.pointer or roles.scroll) return .self_and_children;
    return .pass_through;
}

fn defaultHitShape(node: *const Node) HitShapeSpec {
    if (componentNameEquals(node, "Spinner")) {
        return .ellipse;
    }
    const r = node.rectFromWorldOrFallback();
    const radii = corner_radii.normalize(node.style.effectiveRadii(), r.w, r.h);
    if (!uniformRadii(radii)) return .{ .rounded_corners = radii };
    const radius = radii[0];
    if (radius > 0.01) {
        const half_w = r.w / 2;
        const half_h = r.h / 2;
        if (@abs(r.w - r.h) < 0.01 and radius >= @min(half_w, half_h) - 0.5) {
            return .circle;
        }
        return .{ .rounded_rect = radius };
    }
    return .rect;
}

/// Same classification as `defaultHitShape` (minus the Spinner/circle special cases, which only
/// concern hit targets): non-uniform radii clip per corner (attached group items keep their square
/// inner corners), uniform radii clip with one radius.
fn defaultClipShape(node: *const Node) ClipShapeSpec {
    const radii = node.style.effectiveRadii();
    if (!uniformRadii(radii)) return .{ .rounded_corners = radii };
    if (radii[0] > 0.01) return .{ .rounded_rect = radii[0] };
    return .rect;
}

fn uniformRadii(r: [4]f32) bool {
    return @abs(r[0] - r[1]) < 0.01 and @abs(r[1] - r[2]) < 0.01 and @abs(r[2] - r[3]) < 0.01;
}

fn componentNameEquals(node: *const Node, expected: []const u8) bool {
    return if (node.meta.ownership.meta.component_name) |name|
        std.mem.eql(u8, name, expected)
    else
        false;
}
