/// Effect/clip bridge: translate effect/clip nodes in PropertyTree to DisplayItem literal tokens.
///
/// Responsible for (Display side):
/// - Layer Bridge: begin/end_opacity_layer / blur_layer / rounded_clip tokens
/// - Clip Bridge: push_clip / pop_clip tokens
/// - Effect Chain: expand along the effect_id chain into a linear token sequence
///   (appendDisplayEffectBridge*)
const std = @import("std");
const display_list_mod = @import("../display_list.zig");
const layer_tree_mod = @import("../layer_tree.zig");
const property_tree_mod = @import("../property_tree.zig");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const node_state = @import("node_state.zig");
const render_context_mod = @import("render_context.zig");
const display_list_lowering = @import("display_list_lowering.zig");

const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Node = node_mod.Node;
const RenderContext = render_context_mod.RenderContext;
const NodeExecutionState = node_state.NodeExecutionState;
const EffectBridgeEntry = node_state.EffectBridgeEntry;
const INVALID_ID = property_tree_mod.INVALID_ID;
const ItemHeader = display_list_mod.ItemHeader;

/// Effect/clip token header: these tokens not bound to concrete paint node, header placeholder.
/// INVALID transform_id (encoder does not secondary-transform effect/clip; field lowered).
const CONTROL_HEADER: ItemHeader = .{ .transform_id = INVALID_ID, .node_id = std.math.maxInt(u32) };

/// GPU retained identity key.
///
/// Only layers truly promoted to independent surface qualify: stable_id assigned to each plan layer
/// (including unpromoted); using it as retained identity lets pass-through layers claim dedicated
/// texture, but their content depends on outer context, cross-frame reuse fails. Unqualified
/// returns INVALID_SURFACE_ID; encoder falls back to safe full-repaint each frame.
fn retainedSurfaceId(layer: *const layer_tree_mod.CompositedLayer) u32 {
    if (!layer.promotion_reason.any()) return display_list_mod.INVALID_SURFACE_ID;
    if (layer.stable_id == INVALID_ID) return display_list_mod.INVALID_SURFACE_ID;
    return layer.stable_id;
}

pub fn appendLayerBridgeBeginFromPlanState(cx: *RenderContext, effect_state: layer_tree_mod.LayerTree.EffectPlanState) !bool {
    if (!effect_state.hasCompleteSurfaceBridge()) return false;
    const layer = effect_state.layer orelse return false;
    const bounds = effect_state.begin_bounds orelse return false;

    // Surface transform case: use Plan's precomputed source/draw bounds instead of world bounds.
    const src = if (layer.has_surface_transform) layer.surface_source_bounds else bounds;
    const draw = if (layer.has_surface_transform) layer.surface_draw_bounds else bounds;
    if (@import("zenit_environment").flag("ZENIT_DEBUG_LAYER") and layer.root_node_id == 440) {
        std.debug.print("[layer_begin] node=440 kind={s} effect_id={d} src=({d:.1},{d:.1},{d:.1},{d:.1}) draw=({d:.1},{d:.1},{d:.1},{d:.1}) cr={d:.1}\n", .{
            @tagName(layer.effect_kind),                                                                                      layer.effect_id, src.x, src.y, src.w, src.h, draw.x, draw.y, draw.w, draw.h,
            @max(@max(layer.corner_radius[0], layer.corner_radius[1]), @max(layer.corner_radius[2], layer.corner_radius[3])),
        });
    }
    // Rounded-clip fold (Stage 3): the opacity/composited_group effect's corner radii (TL, TR, BR,
    // BL) are applied per corner by the composite blit.
    const fold_radii = layer.corner_radius;
    switch (layer.effect_kind) {
        .opacity => {
            const opacity = effect_state.draw_opacity orelse return false;
            try display_list_lowering.appendLoweredBoth(cx, .{
                .begin_opacity_layer = .{
                    .header = CONTROL_HEADER,
                    .x = src.x,
                    .y = src.y,
                    .w = src.w,
                    .h = src.h,
                    .opacity = opacity,
                    .corner_radii = fold_radii,
                    .rotate = layer.surface_rotate,
                    .use_draw_transform = layer.has_surface_transform,
                    .draw_transform = layer.surface_draw_transform,
                    .surface_rest_origin = layer.surface_rest_origin,
                    .draw_x = draw.x,
                    .draw_y = draw.y,
                    .draw_w = draw.w,
                    .draw_h = draw.h,
                    .blend_mode = layer.blend_mode,
                    .warp = .{ layer.warp.cap, layer.warp.edge, layer.warp.fade_start, layer.warp.fade_width },
                    .surface_stable_id = retainedSurfaceId(layer),
                    .surface_content_version = layer.content_version,
                },
            });
        },
        .composited_group => {
            const opacity = effect_state.draw_opacity orelse return false;
            try display_list_lowering.appendLoweredBoth(cx, .{
                .begin_opacity_layer = .{
                    .header = CONTROL_HEADER,
                    .x = src.x,
                    .y = src.y,
                    .w = src.w,
                    .h = src.h,
                    .opacity = opacity,
                    .corner_radii = fold_radii,
                    .rotate = layer.surface_rotate,
                    .use_draw_transform = layer.has_surface_transform,
                    .draw_transform = layer.surface_draw_transform,
                    .surface_rest_origin = layer.surface_rest_origin,
                    .draw_x = draw.x,
                    .draw_y = draw.y,
                    .draw_w = draw.w,
                    .draw_h = draw.h,
                    .blend_mode = layer.blend_mode,
                    .warp = .{ layer.warp.cap, layer.warp.edge, layer.warp.fade_start, layer.warp.fade_width },
                    .surface_stable_id = retainedSurfaceId(layer),
                    .surface_content_version = layer.content_version,
                },
            });
        },
        .backdrop_blur => try display_list_lowering.appendLoweredBoth(cx, .{
            .begin_blur_layer = .{
                .header = CONTROL_HEADER,
                .owner_node = layer.root_node_id,
                .x = src.x,
                .y = src.y,
                .w = src.w,
                .h = src.h,
                .corner_radii = layer.corner_radius,
                .glass = &layer.glass,
                .rotate = layer.surface_rotate,
                .use_draw_transform = layer.has_surface_transform,
                .draw_transform = layer.surface_draw_transform,
                .surface_rest_origin = layer.surface_rest_origin,
                .draw_x = draw.x,
                .draw_y = draw.y,
                .draw_w = draw.w,
                .draw_h = draw.h,
            },
        }),
        .rounded_clip => {
            try display_list_lowering.appendLoweredBoth(cx, .{
                .begin_rounded_clip = .{
                    .header = CONTROL_HEADER,
                    .x = src.x,
                    .y = src.y,
                    .w = src.w,
                    .h = src.h,
                    .radii = layer.corner_radius,
                    .rotate = layer.surface_rotate,
                    .use_draw_transform = layer.has_surface_transform,
                    .draw_transform = layer.surface_draw_transform,
                    .surface_rest_origin = layer.surface_rest_origin,
                    .draw_x = draw.x,
                    .draw_y = draw.y,
                    .draw_w = draw.w,
                    .draw_h = draw.h,
                },
            });
        },
    }
    return true;
}

pub fn appendLayerBridgeEndFromPlanState(cx: *RenderContext, effect_state: layer_tree_mod.LayerTree.EffectPlanState) !bool {
    if (!effect_state.hasCompleteSurfaceBridge()) return false;
    const layer = effect_state.layer orelse return false;

    switch (layer.effect_kind) {
        .opacity, .composited_group => try display_list_lowering.appendLoweredBoth(cx, .{ .end_opacity_layer = .{ .header = CONTROL_HEADER } }),
        .backdrop_blur => try display_list_lowering.appendLoweredBoth(cx, .{ .end_blur_layer = .{ .header = CONTROL_HEADER } }),
        .rounded_clip => try display_list_lowering.appendLoweredBoth(cx, .{ .end_rounded_clip = .{ .header = CONTROL_HEADER } }),
    }
    return true;
}

pub fn appendRectClipBridgeBeginFromPlanState(
    cx: *RenderContext,
    effect_state: layer_tree_mod.LayerTree.EffectPlanState,
    fallback_bounds: ComputedRect,
    fallback_radii: [4]f32,
    fallback_shape_kind: display_list_mod.ClipShapeKind,
    fallback_polygon: ?*const display_list_mod.ClipPolygon,
    use_fallback: bool,
    /// true = push_clip falls **inside** effect's surface (after begin layer), needs projection to
    /// surface content frame; false = falls in parent context (blur's clip before
    /// begin_blur_layer), project to parent surface content coordinates.
    inside_surface: bool,
) !bool {
    if (effect_state.apply_clip_bounds) |clip_bounds_raw| {
        // apply_clip AABB is world coordinates, but surface content lower in owner-unscaled-local
        // frame (layer_tree CA-pure: owner_world^-1 projection; effect without transform:
        // owner_world=identity, local is world). Must use property tree's owner_world^-1 to project
        // clip (draw_transform already parent surface coordinates) to content frame; else rotated
        // surface gets world scissor pushing content fully offscreen (e.g., settle+90-degree
        // rotated accordion chevron vanishes). AABB under rotation is covering approximation;
        // overflow clipped by parent-level same clip during composite.
        // World -> target frame; apply_clip radii are world-oriented (layer_tree), so re-orient them
        // with the same map.
        const projection: Transform2D = blk: {
            if (effect_state.layer) |layer| {
                if (inside_surface and layer.has_surface_transform and layer.transform_id < cx.property_tree.transforms.items.len) {
                    break :blk cx.property_tree.transforms.items[layer.transform_id].inverse_world;
                }
                if (!inside_surface) break :blk layer.surface_parent_inverse;
            }
            break :blk Transform2D.identity();
        };
        const clip_bounds = projection.transformRect(clip_bounds_raw);
        try display_list_lowering.appendLoweredBoth(cx, .{
            .push_clip = .{
                .header = CONTROL_HEADER,
                .x = clip_bounds.x,
                .y = clip_bounds.y,
                .w = clip_bounds.w,
                .h = clip_bounds.h,
                .radii = projection.orientCornerRadii(effect_state.apply_clip_radii),
                .shape_kind = effect_state.apply_clip_shape_kind,
                .polygon = effect_state.apply_clip_polygon,
            },
        });
        return true;
    }
    if (!use_fallback) return false;
    try display_list_lowering.appendLoweredBoth(cx, .{
        .push_clip = .{
            .header = CONTROL_HEADER,
            .x = fallback_bounds.x,
            .y = fallback_bounds.y,
            .w = fallback_bounds.w,
            .h = fallback_bounds.h,
            .radii = fallback_radii,
            .shape_kind = fallback_shape_kind,
            .polygon = fallback_polygon,
        },
    });
    return true;
}

pub fn appendRectClipBridgeEnd(cx: *RenderContext, clip_active: bool) !void {
    if (!clip_active) return;
    try display_list_lowering.appendLoweredBoth(cx, .{ .pop_clip = .{ .header = CONTROL_HEADER } });
}

pub fn collectEffectBridgeChain(
    cx: *RenderContext,
    parent_effect_id: u32,
    effect_id: u32,
    entries: *[8]EffectBridgeEntry,
) usize {
    if (effect_id == parent_effect_id or effect_id == INVALID_ID) return 0;

    var count: usize = 0;
    var current = effect_id;
    while (current != parent_effect_id and current != INVALID_ID and count < entries.len) {
        // Defense: cached splice item header may carry stale effect_id (property tree index from
        // cache write frame; effect list shrinks this frame, overwrites). Normal path blocks stale
        // via canReusePromotedCommands effect_id check; here bottleneck prevents panic, boundary
        // terminates chain (item treated as effect-free).
        if (current >= cx.property_tree.effects.items.len) break;
        entries[count] = .{
            .effect_id = current,
            .effect = cx.property_tree.effects.items[current],
            .state = cx.layer_tree.planQueryEffect(current),
        };
        count += 1;
        current = cx.property_tree.effects.items[current].parent;
    }
    return count;
}

pub const DisplayEffectBridgeScope = struct {
    entry: EffectBridgeEntry,
    clip_active: bool,
    /// Begin actually emitted layer token. End must pair per this, not re-derive condition: Begin
    /// has draw_opacity==null early exits only on its side (bridge complete but no action);
    /// re-derive makes End emit for non-begun layer, encoder's empty-stack guard prevents crash but
    /// token stream unbalanced.
    layer_emitted: bool = false,
};

pub fn appendDisplayEffectBridgeBeginEntry(
    cx: *RenderContext,
    entry: EffectBridgeEntry,
    replay_node: ?*Node,
    replay_exec_state: ?*const NodeExecutionState,
) !DisplayEffectBridgeScope {
    _ = replay_node;
    _ = replay_exec_state;
    var scope = DisplayEffectBridgeScope{
        .entry = entry,
        .clip_active = false,
    };
    const clip_before_layer = entry.effect.kind == .backdrop_blur;
    // Unified via CompositorPlan: Plan precomputes all params in buildFromPropertyTree, including
    // surface transform case source/draw bounds and draw_transform.
    if (clip_before_layer and entry.state.hasPlanClipBridge()) {
        scope.clip_active = try appendRectClipBridgeBeginFromPlanState(
            cx,
            entry.state,
            entry.effect.local_bounds,
            .{ 0, 0, 0, 0 },
            .rect,
            null,
            false,
            false, // before begin layer -> parent context, world coordinates.
        );
    }
    if (try appendLayerBridgeBeginFromPlanState(cx, entry.state)) {
        scope.layer_emitted = true;
        if (!clip_before_layer and entry.state.hasPlanClipBridge()) {
            scope.clip_active = try appendRectClipBridgeBeginFromPlanState(
                cx,
                entry.state,
                entry.effect.local_bounds,
                .{ 0, 0, 0, 0 },
                .rect,
                null,
                false,
                true, // after begin layer -> surface content frame.
            );
        }
        return scope;
    }
    // Plan did not cover this effect (requires_offscreen=false or allocation failed), degrade to
    // no-op.
    return scope;
}

pub fn appendDisplayEffectBridgeBegin(
    cx: *RenderContext,
    parent_effect_id: u32,
    effect_id: u32,
    out_scopes: *[8]DisplayEffectBridgeScope,
    replay_node: ?*Node,
    replay_exec_state: ?*const NodeExecutionState,
) !usize {
    if (effect_id == INVALID_ID or effect_id == parent_effect_id) return 0;
    var chain: [8]EffectBridgeEntry = undefined;
    const count = collectEffectBridgeChain(cx, parent_effect_id, effect_id, &chain);
    if (count == 0) return 0;

    var scope_count: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        out_scopes[scope_count] = try appendDisplayEffectBridgeBeginEntry(cx, chain[i], replay_node, replay_exec_state);
        scope_count += 1;
    }
    return scope_count;
}

pub fn appendDisplayEffectBridgeEnd(cx: *RenderContext, scopes: []const DisplayEffectBridgeScope) !void {
    var remaining = scopes.len;
    while (remaining > 0) {
        remaining -= 1;
        const scope = scopes[remaining];
        // backdrop_blur nesting order intentionally 'reversed': begin is push_clip ->
        // begin_blur_layer, end is pop_clip first then end_blur_layer. Safe only because
        // end_blur_layer is no-op in encoder (blur composite all happens in begin, within clip
        // scope); if end_blur_layer gains real work, must restore true nesting per
        // clip_before_layer branch.
        if (scope.clip_active) {
            try appendRectClipBridgeEnd(cx, true);
        }
        if (!scope.layer_emitted) continue; // Begin no-op => End same no-op.
        if (try appendLayerBridgeEndFromPlanState(cx, scope.entry.state)) {
            continue;
        }
        // Bridge failed between begin/end (defensive fallback, theoretically unreachable): emit raw
        // tokens, prefer double-emitting to leaving layer unclosed.
        switch (scope.entry.effect.kind) {
            .opacity, .composited_group => try display_list_lowering.appendLoweredBoth(cx, .{ .end_opacity_layer = .{ .header = CONTROL_HEADER } }),
            .backdrop_blur => try display_list_lowering.appendLoweredBoth(cx, .{ .end_blur_layer = .{ .header = CONTROL_HEADER } }),
            .rounded_clip => try display_list_lowering.appendLoweredBoth(cx, .{ .end_rounded_clip = .{ .header = CONTROL_HEADER } }),
        }
    }
}

/// Collect clip chain (innermost-first) for caller's cross-group common prefix comparison. Dual to
/// collectEffectBridgeChain; effect side already keeps scope per prefix, clip side previously
/// close+reopen each group (see display_list_lowering loop comment).
pub fn collectDisplayClipChainPublic(cx: *RenderContext, clip_id: u32, out: *[8]u32) usize {
    return collectDisplayClipChain(cx, clip_id, out);
}

fn collectDisplayClipChain(cx: *RenderContext, clip_id: u32, out: *[8]u32) usize {
    if (clip_id == INVALID_ID) return 0;
    var count: usize = 0;
    var current = clip_id;
    while (current != INVALID_ID and count < out.len and current < cx.property_tree.clips.items.len) {
        out[count] = current;
        count += 1;
        current = cx.property_tree.clips.items[current].parent;
    }
    return count;
}

pub fn appendDisplayClipBridgeBegin(cx: *RenderContext, clip_id: u32, active_parent_effect_id: u32) !usize {
    return appendDisplayClipBridgeBeginFiltered(cx, clip_id, active_parent_effect_id, false);
}

/// only_scroll=true emits only clips from scroll containers (effect-internal scenario: glass island
/// virtual list row overflow must clip; Input etc small clips' effect-internal projection still has
/// coordinate issues, maintain old behavior for now).
pub fn appendDisplayClipBridgeBeginFiltered(cx: *RenderContext, clip_id: u32, active_parent_effect_id: u32, only_scroll: bool) !usize {
    return appendDisplayClipBridgeBeginSuffix(cx, clip_id, active_parent_effect_id, only_scroll, 0);
}

/// skip_outer = outermost clip count already opened by previous group, this group continues to use.
/// Why needed: lowering main loop groups by (effect_id, clip_id), each virtual list row has own
/// clip_id. Old impl re-emitted entire ancestor chain per group; measured: island rounded_clip (all
/// rows shared outer layer) push/pop per row logged 150k swaps of null->rounded(1106)->null. Each
/// swap calls syncClipStateAfterMutation flushAllPending (drain pipeline, eat SDF uniform slot),
/// 256 slots exhausted per frame, encode balloons to 10-17ms. Effect side fixed same shape bug
/// 2026-08-02 (see lowering loop scope prefix comment); clip side missed the sync. Now closed: hold
/// common prefix across groups, emit only diff.
pub fn appendDisplayClipBridgeBeginSuffix(
    cx: *RenderContext,
    clip_id: u32,
    active_parent_effect_id: u32,
    only_scroll: bool,
    skip_outer: usize,
) !usize {
    if (clip_id == INVALID_ID or clip_id >= cx.property_tree.clips.items.len) return 0;
    // CA-pure (P6+): surface content lower in **owner-local (unscaled)** frame; encoder
    // offscreenOffset = -(surface_source_bounds.origin) (src also owner-local). Thus push_clip
    // inside surface also convert to owner-local: active_parent_inverse.transformRect(world_aabb) +
    // encoder offset = correct texture position. Old 'surface directly pass world_aabb' assumed
    // world-coordinate model; under CA-pure clips positioned wrong -> panel rounded_clip/boundary
    // clip fails (menu item hover background overflows wrapper edge).
    const active_parent_inverse = blk: {
        if (active_parent_effect_id == INVALID_ID or active_parent_effect_id >= cx.property_tree.effects.items.len) {
            break :blk Transform2D.identity();
        }
        const parent_transform_id = cx.property_tree.effects.items[active_parent_effect_id].transform_id;
        if (parent_transform_id >= cx.property_tree.transforms.items.len) break :blk Transform2D.identity();
        break :blk cx.property_tree.transforms.items[parent_transform_id].inverse_world;
    };
    var chain: [8]u32 = undefined;
    const count = collectDisplayClipChain(cx, clip_id, &chain);
    if (count == 0) return 0;

    var emitted: usize = 0;
    // Chain is innermost-first; outermost in chain[count-1]. Skip skip_outer outermost layers
    // already opened by previous group; start from first layer truly needing new open.
    var i = count - @min(skip_outer, count);
    while (i > 0) {
        i -= 1;
        const clip = cx.property_tree.clips.items[chain[i]];
        if (only_scroll and !clip.from_scroll) continue;
        const clip_rect = if (active_parent_effect_id != INVALID_ID)
            active_parent_inverse.transformRect(clip.world_aabb)
        else
            clip.world_aabb;
        const clip_scale = if (active_parent_effect_id != INVALID_ID and clip.transform_id < cx.property_tree.transforms.items.len)
            active_parent_inverse.mul(cx.property_tree.transforms.items[clip.transform_id].world).extractApproxScale()
        else
            1.0;
        // Clip-owner-local corners -> the frame the clip rect is emitted in (world, or the active
        // surface's content frame).
        const clip_orientation: Transform2D = if (clip.transform_id < cx.property_tree.transforms.items.len) blk: {
            const world = cx.property_tree.transforms.items[clip.transform_id].world;
            break :blk if (active_parent_effect_id != INVALID_ID) active_parent_inverse.mul(world) else world;
        } else Transform2D.identity();
        const clip_radii = clip_orientation.orientCornerRadii(clip.radii);
        // Polygon point set is clip-rect-origin-relative (clip.zig buildClipPolygonFromPathGeometry
        // subtracts rect origin), naturally translates per rect projection; but when rect is
        // clip_scale-scaled, point set must scale likewise, else shape/rect aspect mismatches (same
        // logic as above radius * clip_scale).
        var polygon: ?*const display_list_mod.ClipPolygon = null;
        if (clip.shape_kind == .polygon or clip.polygon.point_count != 0) {
            const own = try cx.frame_allocator.create(display_list_mod.ClipPolygon);
            own.* = clip.polygon;
            if (@abs(clip_scale - 1.0) > 0.0001) {
                for (own.points[0..own.point_count]) |*p| {
                    p[0] *= clip_scale;
                    p[1] *= clip_scale;
                }
            }
            polygon = own;
        }
        try display_list_lowering.appendLoweredBoth(cx, .{
            .push_clip = .{
                .header = CONTROL_HEADER,
                .x = clip_rect.x,
                .y = clip_rect.y,
                .w = clip_rect.w,
                .h = clip_rect.h,
                .radii = .{ clip_radii[0] * clip_scale, clip_radii[1] * clip_scale, clip_radii[2] * clip_scale, clip_radii[3] * clip_scale },
                .shape_kind = clip.shape_kind,
                .polygon = polygon,
            },
        });
        emitted += 1;
    }
    return emitted;
}

pub fn appendDisplayClipBridgeEnd(cx: *RenderContext, clip_count: usize) !void {
    var remaining = clip_count;
    while (remaining > 0) {
        remaining -= 1;
        try appendRectClipBridgeEnd(cx, true);
    }
}
