/// render_engine internal state struct definitions.
/// Includes: RetainedIds, NodeRenderState, NodeContentRenderState,
/// NodeExecutionState, NodeExecutionPlan, NodeContentSlices, ChildRenderPass and related enums.
const std = @import("std");
const types = @import("../types.zig");
const display_list_mod = @import("../display_list.zig");
const layer_tree_mod = @import("../layer_tree.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");

const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Point = types.Point;

// ---------------------------------------------------------------------
// Basic ID containers
// ---------------------------------------------------------------------

pub const RetainedIds = struct {
    transform_id: u32,
    clip_id: u32,
    effect_id: u32,
};

// ---------------------------------------------------------------------
// Render state (transform/scale/clip/effects, world-coordinate based)
// ---------------------------------------------------------------------

pub const NodeRenderState = struct {
    world_transform: Transform2D,
    world_rect: ComputedRect,
    clip_world_rect: ComputedRect,
    effective_clip: ?ComputedRect,
    scale_x_abs: f32,
    scale_y_abs: f32,
    scale_min: f32,
    pad_left: f32,
    pad_right: f32,
    pad_top: f32,
    pad_bottom: f32,
    node_opacity: f32,
    needs_clip: bool,
    blur_radius: f32,
    use_opacity_layer: bool,
    opacity_bounds: ComputedRect,
    radii: [4]f32,
    radius: f32,
    clip_shape_kind: display_list_mod.ClipShapeKind,
    /// Rounded overflow clip corner radii TL, TR, BR, BL (scaled; .rounded_rect only).
    clip_radii: [4]f32,
    clip_polygon: ?*const display_list_mod.ClipPolygon,
    clip_bounds_fallback: bool,
    use_blur: bool,
    use_rounded_clip: bool,
};

/// Content render state: content coords without scale/rotation; for text and child positioning.
pub const NodeContentRenderState = struct {
    content_transform: Transform2D,
    content_rect: ComputedRect,
    clip_content_rect: ComputedRect,
    effective_clip: ?ComputedRect,
    scale_x_abs: f32,
    scale_y_abs: f32,
    scale_min: f32,
    pad_left: f32,
    pad_right: f32,
    pad_top: f32,
    pad_bottom: f32,
    node_opacity: f32,
    needs_clip: bool,
    blur_radius: f32,
    use_opacity_layer: bool,
    opacity_bounds: ComputedRect,
    radii: [4]f32,
    radius: f32,
    clip_shape_kind: display_list_mod.ClipShapeKind,
    /// Rounded overflow clip corner radii TL, TR, BR, BL (scaled; .rounded_rect only).
    clip_radii: [4]f32,
    clip_polygon: ?*const display_list_mod.ClipPolygon,
    clip_bounds_fallback: bool,
    use_blur: bool,
    use_rounded_clip: bool,
};

// ---------------------------------------------------------------------
// Execution state: merges world coords, scene runtime, compositor plan
// ---------------------------------------------------------------------

pub const NodeExecutionState = struct {
    retained_runtime: scene_runtime_mod.SceneNodeRuntime,
    retained_ids: RetainedIds,
    content_state: NodeContentRenderState,
    plan_state: layer_tree_mod.LayerTree.NodePlanState,
    world_transform: Transform2D,
    world_origin: Point,
    world_rect: ComputedRect,
    clip_rect: ComputedRect,
    content_transform: Transform2D,
    render_x: f32,
    render_y: f32,
    render_w: f32,
    render_h: f32,
    needs_clip: bool,
    scale_x_abs: f32,
    scale_y_abs: f32,
    scale_min: f32,
    pad_left: f32,
    pad_right: f32,
    pad_top: f32,
    pad_bottom: f32,
    node_opacity: f32,
    use_opacity_layer: bool,
    effective_clip: ?ComputedRect,
    radii: [4]f32,
    radius: f32,
    clip_shape_kind: display_list_mod.ClipShapeKind,
    /// Rounded overflow clip corner radii TL, TR, BR, BL (scaled; .rounded_rect only).
    clip_radii: [4]f32,
    clip_polygon: ?*const display_list_mod.ClipPolygon,
    clip_bounds_fallback: bool,
    use_rounded_clip: bool,
    promoted_layer_id: u32,
    /// Cross-frame stable identity (CompositedLayer.stable_id); used for node cache writes /
    /// cross-frame compare. promoted_layer_id (frame-local index) only for this frame's planMark*
    /// API.
    promoted_layer_stable_id: u32,
    is_promoted_layer: bool,
    promoted_surface_valid: bool,
    subtree_force_linear_text: bool,
};

// ---------------------------------------------------------------------
// Enums: invalidation / rebuild strategy / render pass
// ---------------------------------------------------------------------

pub const PromotedSurfaceInvalidationReason = enum {
    none,
    self,
    descendant,
};

pub const NodeRebuildStrategy = enum {
    normal,
    descendant_scoped_promoted,
};

/// Child render band = paint_order.PaintBand (regular / sticky / positive_z); shared judgment
/// with hit_runtime (see core/paint_order.zig).
pub const ChildRenderPass = @import("../paint_order.zig").PaintBand;

// ---------------------------------------------------------------------
// Execution plan: decides cache / display list / rebuild strategy
// ---------------------------------------------------------------------

pub const NodeExecutionPlan = struct {
    promoted_surface_invalidation_reason: PromotedSurfaceInvalidationReason,
    has_promoted_descendant_subtree: bool,
    has_descendant_scoped_promoted_rebuild_candidate: bool,
    rebuild_strategy: NodeRebuildStrategy,
    has_prebuilt_display_payload_own: bool,
    has_prebuilt_display_payload_subtree: bool,
    prebuilt_display_payload_strategy: scene_runtime_mod.DisplayPayloadSubtreeStrategy,
    should_try_display_payload_subtree_replay: bool,
    should_try_display_payload_own_replay: bool,
    use_legacy_overflow_cache: bool,
    should_try_promoted_replay: bool,
    should_try_legacy_overflow_replay: bool,
    should_write_promoted_cache: bool,
    should_write_legacy_overflow_cache: bool,
    needs_rect_clip_fallback: bool,
};

// ---------------------------------------------------------------------
// Bridge scope / content slice
// ---------------------------------------------------------------------

/// Per-pass list of child node ids that contributed to parent's paint.
/// finalizeNodeCaches uses this + each child's runtime.subtree_display_item_* range
/// to splice cache band; **doesn't depend** on cx.display_list idx, since child
/// subtree-replay / own-replay shortcut doesn't write display_list end, but runtime range
/// still points prebuilt. Splicing from runtime correctly captures both paths.
pub const NodeContentSlices = struct {
    regular_children: std.ArrayList(u32),
    sticky_children: std.ArrayList(u32),
    overlay_children: std.ArrayList(u32),
    /// Tail items (overflow_fade) always fresh-emit to display_list end during paint;
    /// these two idx slice display_list directly.
    tail_start_idx: usize,
    tail_end_idx: usize,
    /// Whether children surrounded by this node's overflow clip node-local token pair
    /// (emitScrollClipBegin returns true). Promoted cache splicing writes this pair into cache
    /// accordingly (see CachedRenderSlice.descendant_clip_open_count).
    clip_wrapped: bool = false,

    // No deinit: three children lists all allocated on frame arena (bulk-reclaimed at frame end);
    // don't use general allocator release.
};

// ---------------------------------------------------------------------
// Effect bridge related (render time, non-display-list version)
// ---------------------------------------------------------------------

/// EffectBridgeEntry: single record on effect bridge chain at render time.
pub const EffectBridgeEntry = struct {
    effect_id: u32,
    effect: @import("../property_tree.zig").EffectNode,
    state: layer_tree_mod.LayerTree.EffectPlanState,
};

/// ReplayBridgeOptions: bridge options when replaying cached commands.
pub const ReplayBridgeOptions = struct {
    use_bridge: bool,
    reuse_origin: bool,
    parent_effect_id: u32 = @import("../property_tree.zig").INVALID_ID,
    exec_plan: ?NodeExecutionPlan = null,
};
