/// Property Trees, retained data structure for Transform / Clip / Effect / Scroll.
/// Design reference: Chromium RenderingNG's 4 property trees (transform / clip / effect / scroll):
/// https://developer.chrome.com/docs/chromium/renderingng-data-structures
///
/// Trees are retained across frames (node changes tracked via epoch, not cleared each frame).
/// The `clear()` API remains for compatibility; new code uses the `beginFrameRetained()` path.
const std = @import("std");
const types = @import("types.zig");
const display_list_mod = @import("display_list.zig");

const Allocator = std.mem.Allocator;
const Transform2D = types.Transform2D;
const ComputedRect = types.ComputedRect;

/// Invalid ID sentinel (indicates no parent / no association).
pub const INVALID_ID: u32 = std.math.maxInt(u32);

// =========== Transform Tree ===========

pub const TransformFlags = packed struct(u8) {
    is_axis_aligned: bool = true,
    is_integer_translation: bool = false,
    has_animation: bool = false,
    has_translation: bool = false,
    has_scale: bool = false,
    has_rotation: bool = false,
    _padding: u2 = 0,
};

pub const TransformNode = struct {
    /// Parent index in transforms array (root node parent = 0 self-reference).
    parent: u32,
    /// Corresponds to UI Node.id.
    node_id: u32,
    /// This node's local transform.
    local: Transform2D,
    /// Accumulated world transform (parent.world × local).
    world: Transform2D,
    /// Inverse of world transform (for hit-test / coordinate back-projection).
    inverse_world: Transform2D,
    /// 'Content space' transform for lowering when display_list ItemHeader.transform_id points to
    /// this transform.
    /// - Top-level node: content == world (equivalent to paint pass)
    /// - Child inside a surface (opacity layer / scale layer etc):
    ///   content == inverse_layer_world * world, i.e. stacked in the surface-local coord system
    ///   with the child's own transform. Lowered DisplayItem is byte-equal to
    ///   paint pass subtree replay (inverse_replay_base * world).
    /// - Default == world (no distinction needed without a surface).
    content: Transform2D,
    flags: TransformFlags = .{},
};

// =========== Clip Tree ===========

pub const ClipNode = struct {
    /// This clip from tag==.scroll container (ScrollArea/VirtualList). Inside effect
    /// (glass/opacity layer) only emit this type clip; full emit wrongly clips small clips
    /// like Input (placeholder text disappears, measured).
    from_scroll: bool = false,
    /// Parent clip node index (INVALID_ID = no parent clip).
    parent: u32,
    /// Associated transform node index.
    transform_id: u32,
    /// Corresponds to UI Node.id.
    node_id: u32,
    /// Clipping rectangle in this node's local space.
    local_rect: ComputedRect,
    /// World-space AABB.
    world_aabb: ComputedRect,
    /// Actual clip shape consumed by render runtime.
    shape_kind: display_list_mod.ClipShapeKind = .rect,
    /// Rounded-clip corner radii TL, TR, BR, BL (.rounded_rect only).
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    polygon: display_list_mod.ClipPolygon = .{},
    /// true means currently using bounds as conservative degeneration, not precise shape clip.
    bounds_fallback: bool = false,
    /// CSS overflow semantics: a clip only clips the owner's (`node_id`) **descendants**; the
    /// owner's
    /// own shadow/background/border are not constrained by its clip (drawn on the border-box or
    /// beyond;
    /// clipping a shadow to the rect by own overflow exposes square gray blocks at rounded
    /// corners).
    /// External clip (external_clip_rects: host declares 'this node clipped by this rect') clips
    /// the
    /// owner itself, false here. Lowering skips this layer when item.node_id == node_id.
    owner_content_exempt: bool = false,
    /// Owner has self-content drawn outside children clip (shadow / outline / visible stroke),
    /// this clip can only be implemented as a node-local push_clip that wraps just the children
    /// (render_engine emitScrollClipBegin). Effect owner's compositor apply_clip thus doesn't use
    /// this layer but parent clip (apply_clip immediately pushes after begin_layer, clips owner
    /// itself).
    owner_wraps_children: bool = false,
};

// =========== Effect Tree ===========

pub const EffectKind = enum(u8) {
    opacity,
    composited_group,
    backdrop_blur,
    rounded_clip,
};

pub const EffectNode = struct {
    /// Parent effect node index (INVALID_ID = no parent effect).
    parent: u32,
    /// Associated transform node index.
    transform_id: u32,
    /// Corresponds to UI Node.id.
    node_id: u32,
    kind: EffectKind,
    opacity: f32 = 1.0,
    /// When non-normal, composition uses W3C blend (only opacity/composited_group kind consumes).
    blend_mode: types.BlendMode = .normal,
    /// Lens warp of the composited surface (opacity / composited_group kinds).
    warp: types.ContentWarp = .{},
    /// Liquid glass effect parameters (GPU-ready format).
    glass: types.ResolvedGlassParams = .{},
    corner_radius: [4]f32 = .{ 0, 0, 0, 0 },
    requires_offscreen: bool = false,
    /// Local region affected by effect.
    local_bounds: ComputedRect,
};

// =========== Scroll Tree (Phase 2 new; align with Chromium RenderingNG) ===========

/// Scroll node for composite layer translation, not content repaint. Each
/// overflow:scroll/auto container has one ScrollNode; during animation/drag, only update
/// `scroll_offset`, downstream layer transform applies this offset, paint chunk unchanged.
pub const ScrollNode = struct {
    /// Parent scroll node index (INVALID_ID = root).
    parent: u32,
    /// Associated transform node index.
    transform_id: u32,
    /// Corresponds to UI Node.id.
    node_id: u32,
    /// Current scroll offset (positive = content moves left/up, equiv viewport moves right/down).
    scroll_offset: types.Point = .{ .x = 0, .y = 0 },
    /// Content size (total scrollable area).
    content_size: types.Size = types.Size.ZERO,
    /// Viewport size (visible area).
    viewport_size: types.Size = types.Size.ZERO,
    /// Whether in scroll animation this frame (for layer promotion decision).
    is_scrolling: bool = false,
};

// =========== PropertyTree Container ===========

/// Node change epoch; in retained-across-frames mode, caller can read this to decide if layer
/// needs rebuild.
pub const NodeEpoch = u64;

pub const PropertyTree = struct {
    allocator: Allocator,
    transforms: std.ArrayList(TransformNode),
    clips: std.ArrayList(ClipNode),
    effects: std.ArrayList(EffectNode),
    /// Phase 2: scroll tree.
    scrolls: std.ArrayList(ScrollNode),

    /// Retained-across-frames mode state. `current_epoch` increments each beginFrameRetained;
    /// caller compares with consumer's recorded epoch to decide if node re-read needed.
    current_epoch: NodeEpoch = 0,
    /// Epoch of last tree structure change (add/delete nodes); layer cache uses this to judge
    /// invalidation.
    last_structural_change: NodeEpoch = 0,
    /// Whether retained-across-frames mode enabled. false (default) = old 'clear each frame'
    /// path, backward compatible. Switch to true after Phase 4 layer tree ships.
    retained_mode: bool = false,

    pub fn init(allocator: Allocator) PropertyTree {
        return .{
            .allocator = allocator,
            .transforms = .empty,
            .clips = .empty,
            .effects = .empty,
            .scrolls = .empty,
        };
    }

    pub fn deinit(self: *PropertyTree) void {
        self.transforms.deinit(self.allocator);
        self.clips.deinit(self.allocator);
        self.effects.deinit(self.allocator);
        self.scrolls.deinit(self.allocator);
    }

    /// Old path: clear each frame. After Phase 4 layer tree connects, render_engine calls
    /// beginFrameRetained(); this function exists for compatibility.
    pub fn clear(self: *PropertyTree) void {
        self.transforms.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        self.effects.clearRetainingCapacity();
        self.scrolls.clearRetainingCapacity();
        // In non-retained mode, each clear counts as 'full tree rebuild', equivalent to structure
        // change.
        if (!self.retained_mode) {
            self.current_epoch +%= 1;
            self.last_structural_change = self.current_epoch;
        }
    }

    /// Retained-across-frames mode: begin frame. Don't clear nodes, only advance epoch. Caller
    /// responsible for pushing last_structural_change via mutateXxx series APIs for truly changed
    /// nodes.
    pub fn beginFrameRetained(self: *PropertyTree) void {
        self.retained_mode = true;
        self.current_epoch +%= 1;
    }

    /// Notify PropertyTree of topology change (add/delete nodes), invalidate consumer cache.
    pub fn markStructuralChange(self: *PropertyTree) void {
        self.last_structural_change = self.current_epoch;
    }

    /// Append transform node, return its index.
    pub fn appendTransform(self: *PropertyTree, node: TransformNode) !u32 {
        const id: u32 = @intCast(self.transforms.items.len);
        try self.transforms.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// Append clip node, return its index.
    pub fn appendClip(self: *PropertyTree, node: ClipNode) !u32 {
        const id: u32 = @intCast(self.clips.items.len);
        try self.clips.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// Append effect node, return its index.
    pub fn appendEffect(self: *PropertyTree, node: EffectNode) !u32 {
        const id: u32 = @intCast(self.effects.items.len);
        try self.effects.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// Append scroll node, return its index.
    pub fn appendScroll(self: *PropertyTree, node: ScrollNode) !u32 {
        const id: u32 = @intCast(self.scrolls.items.len);
        try self.scrolls.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// Update scroll offset (animation/drag hot path). **Don't** trigger structure-change epoch,
    /// just in-place mutation; layer applies translation without re-paint.
    pub fn updateScrollOffset(self: *PropertyTree, scroll_id: u32, offset: types.Point) void {
        if (scroll_id >= self.scrolls.items.len) return;
        self.scrolls.items[scroll_id].scroll_offset = offset;
    }
};

// =========== Tests ===========

const testing = std.testing;

test "PropertyTree: 4 trees including scroll" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();

    _ = try pt.appendTransform(.{
        .parent = INVALID_ID,
        .node_id = 1,
        .local = Transform2D.identity(),
        .world = Transform2D.identity(),
        .inverse_world = Transform2D.identity(),
        .content = Transform2D.identity(),
    });
    _ = try pt.appendClip(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .local_rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .world_aabb = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    _ = try pt.appendEffect(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .kind = .opacity,
        .opacity = 0.5,
        .local_bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    const scroll_id = try pt.appendScroll(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .content_size = .{ .width = 1000, .height = 5000 },
        .viewport_size = .{ .width = 1000, .height = 800 },
    });

    try testing.expectEqual(@as(u32, 0), scroll_id);
    try testing.expectEqual(@as(usize, 1), pt.scrolls.items.len);
}

test "PropertyTree: updateScrollOffset does not change structure epoch" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();
    pt.beginFrameRetained();
    const epoch_before_create = pt.current_epoch;

    _ = try pt.appendScroll(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .content_size = .{ .width = 1000, .height = 5000 },
        .viewport_size = .{ .width = 1000, .height = 800 },
    });
    // Creating nodes is structural change.
    try testing.expect(pt.last_structural_change >= epoch_before_create);

    // Advance frame.
    pt.beginFrameRetained();
    const epoch_at_anim = pt.current_epoch;
    const struct_at_anim = pt.last_structural_change;

    // During animation, only modify offset.
    pt.updateScrollOffset(0, .{ .x = 0, .y = 100 });
    pt.updateScrollOffset(0, .{ .x = 0, .y = 200 });

    // Structure epoch unchanged, layer cache continues to hit.
    try testing.expectEqual(struct_at_anim, pt.last_structural_change);
    try testing.expectEqual(epoch_at_anim, pt.current_epoch);

    // But offset truly updated.
    try testing.expectEqual(@as(f32, 200), pt.scrolls.items[0].scroll_offset.y);
}

test "PropertyTree: clear in legacy mode bumps structural epoch" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();
    // legacy mode (default).
    const before = pt.last_structural_change;
    pt.clear();
    try testing.expect(pt.last_structural_change != before);
}

test "PropertyTree: appendTransform in retained mode marks structural change" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();
    pt.beginFrameRetained();
    const struct_before = pt.last_structural_change;

    _ = try pt.appendTransform(.{
        .parent = INVALID_ID,
        .node_id = 1,
        .local = Transform2D.identity(),
        .world = Transform2D.identity(),
        .inverse_world = Transform2D.identity(),
        .content = Transform2D.identity(),
    });

    try testing.expect(pt.last_structural_change > struct_before);
}
