/// Pure geometry utilities: rect ops, transforms, sticky offsets. Independent of any other render
/// submodule.
const std = @import("std");

const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const retained_scene = @import("../retained_scene.zig");

const ComputedRect = types.ComputedRect;
const Point = types.Point;
const Padding = types.Padding;
const StickyInsets = types.StickyInsets;
const StickyState = node_mod.StickyState;
const Color = types.Color;
const Transform2D = types.Transform2D;
const Node = node_mod.Node;

pub fn intersectRect(a: ComputedRect, b: ComputedRect) ?ComputedRect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.w, b.x + b.w);
    const y2 = @min(a.y + a.h, b.y + b.h);
    if (x2 <= x1 or y2 <= y1) return null;
    return ComputedRect.init(x1, y1, x2 - x1, y2 - y1);
}

pub fn unionRect(a: ComputedRect, b: ComputedRect) ComputedRect {
    const min_x = @min(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_x = @max(a.x + a.w, b.x + b.w);
    const max_y = @max(a.y + a.h, b.y + b.h);
    return ComputedRect.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

pub fn nodeLocalTransform(node: *Node) Transform2D {
    return retained_scene.buildNodeLocalTransform(node, .{ .include_rotation = true });
}

pub fn nodeWorldTransform(parent_transform: Transform2D, node: *Node) Transform2D {
    return retained_scene.buildNodeWorldTransform(node, parent_transform, .{ .include_rotation = true });
}

pub fn expandRect(rect: ComputedRect, left: f32, top: f32, right: f32, bottom: f32) ComputedRect {
    return ComputedRect.init(
        rect.x - left,
        rect.y - top,
        rect.w + left + right,
        rect.h + top + bottom,
    );
}

pub fn computeOpacityLayerBounds(
    node: *Node,
    world_transform: Transform2D,
    render_rect: ComputedRect,
    scale_x_abs: f32,
    scale_y_abs: f32,
    scale_min: f32,
) ComputedRect {
    var bounds = render_rect;

    if (!node.style.overflow_hidden) {
        if (node.layoutChildrenBbox()) |bbox| {
            bounds = unionRect(bounds, world_transform.transformRect(bbox));
        }
    }

    // Must traverse **all** shadow layers (max max_shadows), only shadow[0] lets later large-blur
    // shadow exceed surface texture boundary, clipped by rectangle (Modal double shadows
    // blur=80/offset_y=32 once leaked). Positive spread also expands shadow shape (negative only
    // shrinks, doesn't expand overflow).
    for (node.style.shadowSlice()) |shadow| {
        const spread = @max(@as(f32, 0), shadow.spread);
        const blur_x = (shadow.blur * 2 + spread) * scale_x_abs;
        const blur_y = (shadow.blur * 2 + spread) * scale_y_abs;
        const offset_x = shadow.offset_x * scale_x_abs;
        const offset_y = shadow.offset_y * scale_y_abs;
        bounds = expandRect(
            bounds,
            blur_x + @max(@as(f32, 0), -offset_x),
            blur_y + @max(@as(f32, 0), -offset_y),
            blur_x + @max(@as(f32, 0), offset_x),
            blur_y + @max(@as(f32, 0), offset_y),
        );
    }

    if (node.style.outline()) |out| {
        const outline_margin = (out.offset + out.width) * scale_min;
        bounds = expandRect(bounds, outline_margin, outline_margin, outline_margin, outline_margin);
    }

    return expandRect(bounds, 2, 2, 2, 2);
}

pub fn modulateColorOpacity(color: Color, opacity: f32) Color {
    const alpha = @as(f32, @floatFromInt(color.a)) * std.math.clamp(opacity, 0.0, 1.0);
    return color.withAlpha(@intFromFloat(@round(alpha)));
}

pub fn canInlineLeafOpacity(
    node: *Node,
    has_rotation: bool,
    has_scale: bool,
    prepromote_composite: bool,
    needs_clip: bool,
    blur_radius: f32,
) bool {
    if (has_rotation or has_scale or prepromote_composite) return false;
    if (needs_clip or blur_radius > 0.001) return false;
    if (node.children.items.len != 0) return false;
    if (node.meta.per_frame.custom_hooks.draw != null or node.frame_state.state_bits.flags.has_custom_draw_subtree) return false;
    if (node.getText() != null) return false;
    return true;
}

/// All inputs to solveSticky. Coordinate convention: `self_rect`/`parent_rect` are layout rects
/// (relative to their parents), `parent_origin`/`clip`/`constraint` are screen coordinates.
pub const StickyInput = struct {
    /// Sticky node's own layout rect (relative to parent).
    self_rect: ComputedRect,
    /// Sticky node's own translate: participates in natural position (screen coord accumulation
    /// same as tick/globalRect).
    self_translate: Point = .{ .x = 0, .y = 0 },
    /// Parent's screen origin = tick recursively passed offset (contains all ancestor rects +
    /// translates + sticky, including parent's own; **don't** re-add parent_rect.x/y or parent
    /// translate).
    parent_origin: Point,
    /// Parent layout rect, use only w/h; null = no parent, no clamping.
    parent_rect: ?ComputedRect,
    parent_padding: Padding = Padding.ZERO,
    insets: StickyInsets,
    /// Adhesion region: all overflow_hidden ancestor frames INTERSECT window viewport (not
    /// including sticky itself).
    clip: ComputedRect,
    /// Explicit clamp container (screen coords, padding subtracted); when non-null, replaces parent
    /// content box.
    constraint: ?ComputedRect = null,
};

pub const StickyResult = struct {
    offset: Point = .{ .x = 0, .y = 0 },
    state: StickyState = .{},
};

/// Solve sticky offset (pure function, no side effects). When natural position crosses adhesion
/// line in a direction, compensate to adhesion line, then clamp container (default parent content
/// box) trims, ensure sticky stays in container. top and bottom (left and right) simultaneous:
/// latter wins.
pub fn solveSticky(in: StickyInput) StickyResult {
    const natural_x = in.parent_origin.x + in.self_rect.x + in.self_translate.x;
    const natural_y = in.parent_origin.y + in.self_rect.y + in.self_translate.y;
    const bounds: ?ComputedRect = in.constraint orelse if (in.parent_rect) |pr| ComputedRect.init(
        in.parent_origin.x + in.parent_padding.left,
        in.parent_origin.y + in.parent_padding.top,
        pr.w - in.parent_padding.left - in.parent_padding.right,
        pr.h - in.parent_padding.top - in.parent_padding.bottom,
    ) else null;

    var x: f32 = 0;
    var y: f32 = 0;
    var x_constrained = false;
    var y_constrained = false;

    if (in.insets.left) |inset_left| {
        const desired_x = in.clip.x + inset_left;
        if (natural_x < desired_x) {
            const want = desired_x - natural_x;
            x = want;
            if (bounds) |b| x = std.math.clamp(want, 0, @max(@as(f32, 0), b.x + b.w - natural_x - in.self_rect.w));
            x_constrained = x < want;
        }
    }
    if (in.insets.top) |inset_top| {
        const desired_y = in.clip.y + inset_top;
        if (natural_y < desired_y) {
            const want = desired_y - natural_y;
            y = want;
            if (bounds) |b| y = std.math.clamp(want, 0, @max(@as(f32, 0), b.y + b.h - natural_y - in.self_rect.h));
            y_constrained = y < want;
        }
    }
    if (in.insets.right) |inset_right| {
        const desired_x = in.clip.x + in.clip.w - inset_right - in.self_rect.w;
        if (natural_x > desired_x) {
            const want = desired_x - natural_x;
            x = want;
            if (bounds) |b| x = std.math.clamp(want, @min(@as(f32, 0), b.x - natural_x), 0);
            x_constrained = x > want;
        }
    }
    if (in.insets.bottom) |inset_bottom| {
        const desired_y = in.clip.y + in.clip.h - inset_bottom - in.self_rect.h;
        if (natural_y > desired_y) {
            const want = desired_y - natural_y;
            y = want;
            if (bounds) |b| y = std.math.clamp(want, @min(@as(f32, 0), b.y - natural_y), 0);
            y_constrained = y > want;
        }
    }

    const engaged = x != 0 or y != 0;
    const constrained = x_constrained or y_constrained;
    return .{
        .offset = .{ .x = x, .y = y },
        .state = .{
            .engaged_top = y > 0,
            .engaged_bottom = y < 0,
            .engaged_left = x > 0,
            .engaged_right = x < 0,
            .pinned = engaged and !constrained,
            .constrained = constrained,
        },
    };
}

/// Tick-side sticky writeback: node constructs StickyInput -> solveSticky -> write offset and
/// state, mark dirty on change. clip: sticky's adhesion region (ancestor clip intersection); null =
/// intersection empty, no adhesion region, zero offset and state (can't retain last frame's:
/// globalRect / hit / pinned popover all read it). offset_x/y: parent's screen origin (tick
/// recursively accumulated all ancestor rects + translates + sticky).
pub fn computeStickyOffset(node: *Node, offset_x: f32, offset_y: f32, clip: ?ComputedRect) void {
    const result: StickyResult = if (clip) |c| blk: {
        // Read rect from World.LayoutTable via global hook.
        const parent = node.parent;
        break :blk solveSticky(.{
            .self_rect = node.rectFromWorldOrFallback(),
            .self_translate = .{ .x = node.style.translate_x, .y = node.style.translate_y },
            .parent_origin = .{ .x = offset_x, .y = offset_y },
            .parent_rect = if (parent) |p| p.rectFromWorldOrFallback() else null,
            .parent_padding = if (parent) |p| p.style.contentInsets() else Padding.ZERO,
            .insets = node.style.sticky_insets(),
            .clip = c,
        });
    } else .{};

    const sticky = &node.frame_state.frame_local.runtime.sticky;
    // State bit change also counts as change (plan §7.4): devtools / e2e serialization reads same
    // runtime.sticky.
    const changed = result.offset.x != sticky.x or result.offset.y != sticky.y or !result.state.eql(sticky.state);
    sticky.x = result.offset.x;
    sticky.y = result.offset.y;
    sticky.state = result.state;

    // Change -> mark render dirty + clear ancestor render cache.
    if (changed) {
        node.markInteractionDirty();
        node.frame_state.state_bits.dirty.core.render = true;
        node.frame_state.state_bits.dirty.core.subtree_render = true;
        var p = node.parent;
        while (p) |parent| {
            parent.frame_state.state_bits.dirty.core.subtree_render = true;
            parent.invalidateRenderCache();
            if (parent.style.overflow_hidden) break;
            p = parent.parent;
        }
    }
}

test "LC3C sticky clamp includes non overlay border and padding" {
    const a = std.testing.allocator;
    const parent = try Node.create(a, 1, .box, .{ .border = .{ .width = 5 }, .padding = .all(10) });
    defer parent.destroy(a);
    const child = try Node.create(a, 2, .box, .{ .position = .sticky });
    try parent.appendChild(a, child);
    const ext = try child.style.ensureExtFallible(a);
    ext.sticky_insets = .{ .top = 0 };
    parent.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.setLayoutRect(.{ .x = 15, .y = 15, .w = 20, .h = 20 });
    computeStickyOffset(child, 0, -70, ComputedRect.init(0, 0, 100, 100));
    try std.testing.expectEqual(@as(f32, 50), child.frame_state.frame_local.runtime.sticky.y);
    try std.testing.expect(child.frame_state.frame_local.runtime.sticky.state.constrained);
    parent.style.border.overlay = true;
    computeStickyOffset(child, 0, -70, ComputedRect.init(0, 0, 100, 100));
    try std.testing.expectEqual(@as(f32, 55), child.frame_state.frame_local.runtime.sticky.y);
    computeStickyOffset(child, 0, 0, ComputedRect.init(0, 0, 100, 100));
    try std.testing.expectEqual(@as(f32, 0), child.frame_state.frame_local.runtime.sticky.y);
}
