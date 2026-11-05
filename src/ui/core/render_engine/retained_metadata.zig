/// Retained metadata: write transform/clip/effect nodes into PropertyTree, update SceneRuntime
/// runtime state for that node.
const std = @import("std");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const render_context_mod = @import("render_context.zig");
const node_state = @import("node_state.zig");
const anim_checks = @import("animation_checks.zig");
const geometry = @import("geometry.zig");
const clip_mod = @import("clip.zig");
const display_list_mod = @import("../display_list.zig");
const retained_scene = @import("../retained_scene.zig");

const Node = node_mod.Node;
const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const RenderContext = render_context_mod.RenderContext;
const NodeRenderState = node_state.NodeRenderState;
const NodeExecutionState = node_state.NodeExecutionState;
const NodeExecutionPlan = node_state.NodeExecutionPlan;
const RetainedIds = node_state.RetainedIds;
const hasActiveCompositeAnimation = anim_checks.hasActiveCompositeAnimation;
const hasActiveTransformAnimation = anim_checks.hasActiveTransformAnimation;
const hasActiveOpacityAnimation = anim_checks.hasActiveOpacityAnimation;

// ---------------------------------------------------------------------
// Debug tools
// ---------------------------------------------------------------------

/// ZENIT_DEBUG_OVERLAY process-level cache: shouldDebugOverlayNode called by renderNodeTransform
/// per-node per-frame (via debugOverlayPlan), in sample profile posix.getenv accounts for ~1% of
/// main thread.
var debug_overlay_env_cache: ?bool = null;

fn debugOverlayEnvEnabled() bool {
    if (debug_overlay_env_cache) |v| return v;
    const v = @import("zenit_environment").flag("ZENIT_DEBUG_OVERLAY");
    debug_overlay_env_cache = v;
    return v;
}

pub fn shouldDebugOverlayNode(node: *Node) bool {
    if (!debugOverlayEnvEnabled()) return false;
    if (node.style.composited_group() or node.style.contentWarp() != null) return true;
    const name = node.meta.ownership.meta.component_name orelse return false;
    return std.mem.eql(u8, name, "Select") or
        std.mem.eql(u8, name, "Popover") or
        std.mem.eql(u8, name, "PopoverContent") or
        std.mem.eql(u8, name, "DatePicker") or
        std.mem.eql(u8, name, "DateRangePicker") or
        std.mem.eql(u8, name, "DatePickerPanel") or
        std.mem.eql(u8, name, "DateRangePickerPanel");
}

pub fn debugOverlayPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    stage: []const u8,
) void {
    if (!shouldDebugOverlayNode(node)) return;
    const bbox = node.layoutChildrenBbox() orelse ComputedRect.init(0, 0, 0, 0);
    std.debug.print(
        "[overlay-debug] frame={d} stage={s} component={s} id={d} dirty(r={any} sr={any} c={any} sc={any}) runtime(anim={any} op={any} tx={any} valid={any} promoted={d}) plan(replay={any} write={any} strategy={s} invalid={s}) style(op={d:.3} sx={d:.3} sy={d:.3}) rect=({d:.1},{d:.1},{d:.1},{d:.1}) bbox=({d:.1},{d:.1},{d:.1},{d:.1}) opacity_bounds=({d:.1},{d:.1},{d:.1},{d:.1})\n",
        .{
            cx.scene_runtime.frame_epoch,
            stage,
            node.meta.ownership.meta.component_name orelse "?",
            node.id,
            node.frame_state.state_bits.dirty.core.render,
            node.frame_state.state_bits.dirty.core.subtree_render,
            node.frame_state.state_bits.dirty.pipeline.composite,
            node.frame_state.state_bits.dirty.pipeline.subtree_composite,
            exec_state.retained_runtime.has_active_composite_animation,
            exec_state.retained_runtime.has_active_opacity_animation,
            exec_state.retained_runtime.has_active_transform_animation,
            exec_state.promoted_surface_valid,
            exec_state.promoted_layer_id,
            exec_plan.should_try_promoted_replay,
            exec_plan.should_write_promoted_cache,
            @tagName(exec_plan.rebuild_strategy),
            @tagName(exec_plan.promoted_surface_invalidation_reason),
            node.getOpacity(),
            node.style.scale_x(),
            node.style.scale_y(),
            exec_state.world_rect.x,
            exec_state.world_rect.y,
            exec_state.world_rect.w,
            exec_state.world_rect.h,
            bbox.x,
            bbox.y,
            bbox.w,
            bbox.h,
            exec_state.content_state.opacity_bounds.x,
            exec_state.content_state.opacity_bounds.y,
            exec_state.content_state.opacity_bounds.w,
            exec_state.content_state.opacity_bounds.h,
        },
    );
}

// ---------------------------------------------------------------------
// Content flags collection
// ---------------------------------------------------------------------

pub fn collectContentFlags(node: *Node) scene_runtime_mod.ContentFlags {
    const bws = node.style.border.resolvedWidths();
    return .{
        // O(1): read NodeFlags.has_text_subtree (setText sets bit + appendChild merges + bubble
        // along ancestors maintain, conservatively don't clear), replaces old subtreeHasText
        // per-node recursion (whole frame O(n*depth), deep text trees' renderNodeTransform top
        // hotspot).
        .has_text = node.frame_state.state_bits.flags.has_text_subtree,
        .has_image = node.getImage() != null,
        .has_icon = node.getIcon() != null,
        .has_background = node.getBackground().a > 0 or node.style.gradient() != null or node.style.multi_gradient() != null or node.style.noise() != null,
        .has_border = bws[0] > 0 or bws[1] > 0 or bws[2] > 0 or bws[3] > 0,
        .has_shadow = node.style.shadow() != null,
        .has_custom_draw = node.meta.per_frame.custom_hooks.draw != null,
    };
}

// ---------------------------------------------------------------------
// PropertyTree + SceneRuntime writes
// ---------------------------------------------------------------------

var debug_pass_count_cache: ?bool = null;
/// ZENIT_DEBUG_PASSCOUNT, read once (this runs per rounded-clip node per frame).
fn debugPassCountEnabled() bool {
    return debug_pass_count_cache orelse blk: {
        const v = @import("zenit_environment").flag("ZENIT_DEBUG_PASSCOUNT");
        debug_pass_count_cache = v;
        break :blk v;
    };
}

fn hasExternalClip(cx: *RenderContext, node: *Node) bool {
    const ext_map = cx.external_clip_rects orelse return false;
    return ext_map.get(node.id) != null;
}

pub fn appendRetainedMetadata(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_transform_id: u32,
    parent_clip_id: u32,
    parent_effect_id: u32,
    render_state: NodeRenderState,
    /// Stage B S5.2: current surface's inverse_world transform, project world coords back to
    /// surface-local coord system. outer (no surface) = identity. surface child =
    /// surface_owner.world_transform.invert(). let lower path from content (= surface_inverse *
    /// world) directly produce surface-local coords, byte-equivalent to paint pass subtree replay
    /// (inverse_replay_base * world).
    surface_inverse: Transform2D,
) RetainedIds {
    const inverse_world = render_state.world_transform.invert();
    const local_rect = inverse_world.transformRect(render_state.clip_world_rect);
    const content_transform = retained_scene.buildNodeWorldTransform(node, parent_transform, .{
        .include_scale = false,
        .include_rotation = false,
    });
    // effect.local_bounds must be **unscaled owner-local frame constant** (unchanged during
    // animation): surface src = owner_world^-1 * (owner_world * local_bounds) = local_bounds,
    // texture coverage stabilizes, M_composite alone bears scale. earlier used 'scaled world
    // opacity_bounds * unscaled inverse' -> drifted per-frame during animation (texture frame =
    // reverse-scaled frame), children's static content reverse-scaled within it, composite's scale
    // exactly cancels -> content visually doesn't participate in scale animation.
    const local_rect_full = cx.rectFromWorld(node);
    const opacity_local_bounds = geometry.computeOpacityLayerBounds(
        node,
        Transform2D.identity(),
        ComputedRect.init(0, 0, local_rect_full.w, local_rect_full.h),
        1.0,
        1.0,
        1.0,
    );
    const display_content_transform = surface_inverse.mul(render_state.world_transform);
    const transform_id = cx.property_tree.appendTransform(.{
        .parent = parent_transform_id,
        .node_id = node.id,
        .local = geometry.nodeLocalTransform(node),
        .world = render_state.world_transform,
        .inverse_world = inverse_world,
        .content = display_content_transform,
        .flags = .{
            .is_axis_aligned = render_state.world_transform.isAxisAligned(),
            .is_integer_translation = render_state.world_transform.isIntegerTranslation(0.0001),
            .has_animation = hasActiveCompositeAnimation(node),
            .has_translation = @abs(node.style.translate_x) > 0.0001 or @abs(node.style.translate_y) > 0.0001,
            .has_scale = @abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001,
            .has_rotation = @abs(node.style.rotate()) > 0.0001,
        },
    }) catch parent_transform_id;

    var clip_id = parent_clip_id;
    if (render_state.needs_clip and render_state.clip_world_rect.w > 0 and render_state.clip_world_rect.h > 0) {
        clip_id = cx.property_tree.appendClip(.{
            .from_scroll = node.tag == .scroll,
            .parent = parent_clip_id,
            .transform_id = transform_id,
            .node_id = node.id,
            .local_rect = local_rect,
            .world_aabb = render_state.clip_world_rect,
            .shape_kind = render_state.clip_shape_kind,
            .radii = render_state.clip_radii,
            .polygon = display_list_mod.ClipPolygon.of(render_state.clip_polygon),
            .bounds_fallback = render_state.clip_bounds_fallback,
            .owner_content_exempt = !hasExternalClip(cx, node),
            .owner_wraps_children = !render_state.use_blur and clip_mod.ownerPaintsOutsideChildClip(node),
        }) catch parent_clip_id;
    }

    var effect_id = parent_effect_id;
    if (render_state.use_opacity_layer) {
        effect_id = cx.property_tree.appendEffect(.{
            .parent = effect_id,
            .transform_id = transform_id,
            .node_id = node.id,
            .kind = if (node.style.composited_group() or node.style.contentWarp() != null) .composited_group else .opacity,
            .opacity = render_state.node_opacity,
            .blend_mode = node.style.blendMode(),
            .warp = node.style.contentWarp() orelse .{},
            // (a content_warp alone promotes: see mod.zig needsOpacityLayer)
            .requires_offscreen = true,
            .local_bounds = opacity_local_bounds,
        }) catch effect_id;
    }
    if (render_state.use_blur) {
        const cr4 = node.style.effectiveRadii();
        const gp = node.style.glass_params() orelse types.GlassParams{};
        // glass rect must be node's own rect: local_rect from clip_world_rect, shadow/outline
        // expands it -> glass SDF/sample computed from large rect, visually shows 'rectangular
        // glass section' one circle wider than node.
        const glass_local_bounds = inverse_world.transformRect(render_state.world_rect);
        effect_id = cx.property_tree.appendEffect(.{
            .parent = effect_id,
            .transform_id = transform_id,
            .node_id = node.id,
            .kind = .backdrop_blur,
            .glass = gp.resolve(),
            .corner_radius = cr4,
            .requires_offscreen = true,
            .local_bounds = glass_local_bounds,
        }) catch effect_id;
    }
    if (render_state.use_rounded_clip) {
        // Stage 3 fold: same-node opacity/composited_group + rounded_clip merge into single
        // offscreen, write rounded_clip into just-appended opacity effect, composite blit applies
        // mask and opacity simultaneously (per-pixel scalar multiply is commutative, visually
        // equivalent to 'clip then fade').
        // precondition: no blur (blur's corner_radius clips background sample, different
        // semantics), opacity bounds and clip rect match (mask acts on entire composite quad,
        // bounds mismatch causes mask position/size error, shadow/overflow padding scenarios fall
        // back here).
        // invariant: rounded_clip always innermost in chain, merge doesn't change chain order.
        const opacity_effect_appended = render_state.use_opacity_layer and effect_id != parent_effect_id and !render_state.use_blur;
        // computeOpacityLayerBounds always +2px pad at end; allow that constant superset (composite
        // mask is superset of surface-internal apply_clip precise rounded_clip, overcutting doesn't
        // discard valid pixels). shadow/outline/children overflow expands more -> mismatch -> fall
        // back to independent rounded_clip.
        const bounds_match = std.math.approxEqAbs(f32, opacity_local_bounds.x, local_rect.x - 2, 0.5) and
            std.math.approxEqAbs(f32, opacity_local_bounds.y, local_rect.y - 2, 0.5) and
            std.math.approxEqAbs(f32, opacity_local_bounds.w, local_rect.w + 4, 0.5) and
            std.math.approxEqAbs(f32, opacity_local_bounds.h, local_rect.h + 4, 0.5);
        if (debugPassCountEnabled() and !(opacity_effect_appended and bounds_match)) {
            std.debug.print("[nofold] node={d} comp={s} op_layer={} blur={} bounds_match={} ob=({d:.1},{d:.1},{d:.1},{d:.1}) lr=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{
                node.id,                        node.meta.ownership.meta.component_name orelse "?",
                render_state.use_opacity_layer, render_state.use_blur,
                bounds_match,                   opacity_local_bounds.x,
                opacity_local_bounds.y,         opacity_local_bounds.w,
                opacity_local_bounds.h,         local_rect.x,
                local_rect.y,                   local_rect.w,
                local_rect.h,
            });
        }
        if (opacity_effect_appended and bounds_match) {
            cx.property_tree.effects.items[effect_id].corner_radius = render_state.clip_radii;
        } else {
            effect_id = cx.property_tree.appendEffect(.{
                .parent = effect_id,
                .transform_id = transform_id,
                .node_id = node.id,
                .kind = .rounded_clip,
                .corner_radius = render_state.clip_radii,
                .requires_offscreen = true,
                .local_bounds = local_rect,
            }) catch effect_id;
        }
    }

    // read rect from World.LayoutTable (shadow-sync guarantees match node.rect). this is first
    // callsite of SoT inversion switch; invariant gate ensures no stale data read.
    const world_rect = cx.rectFromWorld(node);
    cx.scene_runtime.put(.{
        .node_id = node.id,
        .local_rect = world_rect,
        .world_bounds = render_state.world_rect,
        .content_transform = content_transform,
        .content_motion = if (node.style.ext) |ext| ext.motion_offset else .{ 0, 0 },
        .content_bounds = content_transform.transformRect(world_rect),
        .transform_id = transform_id,
        .clip_id = clip_id,
        .clip_bounds_fallback = render_state.clip_bounds_fallback,
        .effect_id = effect_id,
        .paint_order = node.frame_state.frame_local.spatial.paint.order,
        .retained_index = @intCast(cx.retained_nodes.items.len),
        .content_version = node.meta.per_frame.caches.versions.content,
        .composite_version = node.meta.per_frame.caches.versions.composite,
        .content_flags = collectContentFlags(node),
        .is_overlay_candidate = node.style.z_index() > 0,
        .has_active_composite_animation = hasActiveCompositeAnimation(node),
        .has_active_transform_animation = hasActiveTransformAnimation(node),
        .has_active_opacity_animation = hasActiveOpacityAnimation(node),
        .will_change_transform = node.style.will_change_transform(),
        .will_change_opacity = node.style.will_change_opacity(),
        .has_promoted_descendant_subtree = false,
        .has_promoted_surface_cache = node.meta.per_frame.caches.commands.promoted != null,
        .promoted_surface_layer_id = if (node.meta.per_frame.caches.commands.promoted) |cache| cache.promoted_layer_id else scene_runtime_mod.INVALID_ID,
        .promoted_surface_content_version = if (node.meta.per_frame.caches.commands.promoted) |cache| cache.content_version else 0,
        .promoted_surface_bounds = if (node.meta.per_frame.caches.commands.promoted) |cache| cache.world_bounds else ComputedRect.init(0, 0, 0, 0),
        .promoted_surface_transform = if (node.meta.per_frame.caches.commands.promoted) |cache| cache.world_transform else Transform2D.identity(),
        .promoted_surface_flags = .{},
        // cannot downgrade: transform_id / clip_id / effect_id already written into property_tree
        // and used as this function's return value, only scene_runtime missing this node, later
        // layerize / hit-test query runtime by node_id will silently miss.
    }) catch @panic("OOM: scene_runtime.put (node metadata dropped)");
    cx.retained_nodes.append(cx.frame_allocator, node) catch @panic("OOM: retained node order");

    return .{
        .transform_id = transform_id,
        .clip_id = clip_id,
        .effect_id = effect_id,
    };
}
