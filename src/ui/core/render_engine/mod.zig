const std = @import("std");
const animation_checks = @import("animation_checks.zig");

const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const node_render_cache_mod = @import("../node_render_cache.zig");
const retained_memo = @import("retained_memo.zig");
const text_layout = @import("../text_layout.zig");
const property_tree_mod = @import("../property_tree.zig");
const layer_tree_mod = @import("../layer_tree.zig");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");
const retained_scene = @import("../retained_scene.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const id_hash = @import("../id_hash.zig");
const paint_order = @import("../paint_order.zig");

const render_context_mod = @import("render_context.zig");
pub const RenderContext = render_context_mod.RenderContext;

// Submodules: extracted standalone functions
const geometry = @import("geometry.zig");
const clip_mod = @import("clip.zig");
const tick_mod = @import("tick.zig");
const node_state = @import("node_state.zig");
const style_render = @import("node_style_render.zig");
const text_render = @import("text_render.zig");
const text_item_render = @import("text_item_render.zig");
const cache_finalize = @import("node_cache_finalize.zig");
const retained_meta = @import("retained_metadata.zig");
const effect_bridge_mod = @import("effect_bridge.zig");
const display_list_lowering_mod = @import("display_list_lowering.zig");
const gpu_draw_shadow = @import("gpu_draw_shadow.zig");

const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Node = node_mod.Node;
const DisplayItem = display_list_mod.DisplayItem;
const INVALID_ID = property_tree_mod.INVALID_ID;
var disable_spanned_text_retained_cache: ?bool = null;

const ChildOrderRestore = struct {
    owner: if (@import("../node_tree.zig").host_enabled) *Node else void,
    destination: []*Node,
    original: []*Node,
};

/// Stable-sort sibling paint order for the duration of a render pass. The
/// logical Node tree is restored before renderNode returns, so layout and
/// caller-owned child order remain unchanged while every paint/cache path sees
/// the same ordering. This private paint projection deliberately cannot use
/// node_tree.replaceChildOrder: it must not change logical/World order, dirty the
/// tree or publish host placements. No tree mutation or host flush is permitted
/// until restoreChildOrders; assert that storage/parent ownership survived.
fn sortSubtreeChildrenByZ(
    cx: *RenderContext,
    node: *Node,
    restores: *std.ArrayList(ChildOrderRestore),
) !void {
    const children = node.children.items;
    var needs_sort = false;
    if (children.len > 1) {
        for (children[1..], 1..) |child, index| {
            if (paint_order.siblingZ(children[index - 1]) > paint_order.siblingZ(child)) {
                needs_sort = true;
                break;
            }
        }
    }
    if (needs_sort) {
        const original = try cx.frame_allocator.dupe(*Node, children);
        try restores.append(cx.frame_allocator, .{
            .owner = if (comptime @import("../node_tree.zig").host_enabled) node else {},
            .destination = children,
            .original = original,
        });
        // Stable O(n log n) sort: equal z values retain append order. Large
        // canvas/document containers can have thousands of direct children,
        // so quadratic insertion sort is not acceptable here.
        std.sort.block(*Node, children, {}, struct {
            fn lessThan(_: void, lhs: *Node, rhs: *Node) bool {
                return paint_order.siblingZ(lhs) < paint_order.siblingZ(rhs);
            }
        }.lessThan);
    }

    for (children) |child| try sortSubtreeChildrenByZ(cx, child, restores);
}

fn restoreChildOrders(restores: *const std.ArrayList(ChildOrderRestore)) void {
    var index = restores.items.len;
    while (index > 0) {
        index -= 1;
        const restore = restores.items[index];
        if (comptime @import("../node_tree.zig").host_enabled) {
            std.debug.assert(restore.owner.children.items.ptr == restore.destination.ptr);
            std.debug.assert(restore.owner.children.items.len == restore.original.len);
            for (restore.destination) |child| std.debug.assert(child.parent == restore.owner);
        }
        @memcpy(restore.destination, restore.original);
    }
}

// Submodule import aliases: bring submodule types and functions into current
// namespace

// node_state: core data structure
const RetainedIds = node_state.RetainedIds;
const NodeRenderState = node_state.NodeRenderState;
const NodeContentRenderState = node_state.NodeContentRenderState;
const NodeExecutionState = node_state.NodeExecutionState;
const PromotedSurfaceInvalidationReason = node_state.PromotedSurfaceInvalidationReason;
const NodeExecutionPlan = node_state.NodeExecutionPlan;
const NodeContentSlices = node_state.NodeContentSlices;
const ChildRenderPass = node_state.ChildRenderPass;
const ReplayBridgeOptions = node_state.ReplayBridgeOptions;

/// Sibling paint bands (regular -> sticky -> positive_z) are identical in every
/// render mode and come from paint_order.zig, the single source of truth that
/// HitRuntime also walks, so hit paint_order matches pixels bit for bit.
/// Positive z only orders siblings; it never changes clipping.
fn childPasses(_: bool) []const ChildRenderPass {
    return &paint_order.bands;
}

// node_style_render: background / stroke / shadow / media render
const makeDisplayItemHeader = style_render.makeDisplayItemHeaderBorrowed;
const appendNodeShadowAndBackground = style_render.appendNodeShadowAndBackgroundBorrowed;
const appendNodeBorder = style_render.appendNodeBorderBorrowed;
const appendNodeOutline = style_render.appendNodeOutlineBorrowed;
const appendNodeMedia = style_render.appendNodeMediaBorrowed;

// text_item_render: DisplayList text item generation
const appendDisplayTextItem = text_item_render.appendDisplayTextItemBorrowed;

// Wavy underline (diagnostic squiggle) pure geometry tool, exposed for unit
// tests
pub const WavyParams = text_item_render.WavyParams;
pub const wavyCenterAt = text_item_render.wavyCenterAt;
pub const wavyDotStep = text_item_render.wavyDotStep;

// text_render: text rendering
const resolveNodeLogicalTextProps = text_render.resolveNodeLogicalTextProps;
const computeContentExtent = text_render.computeContentExtent;
const renderOverflowFade = text_render.renderOverflowFade;

// cache_finalize: node cache finalization
const finalizeNodeCaches = cache_finalize.finalizeNodeCachesBorrowed;

// retained_metadata: PropertyTree write + SceneRuntime update + debug tools
const shouldDebugOverlayNode = retained_meta.shouldDebugOverlayNode;
const debugOverlayPlan = retained_meta.debugOverlayPlan;
const appendRetainedMetadata = retained_meta.appendRetainedMetadata;

// effect_bridge: effect / clip bridge layer

// display_list_lowering: main path for DisplayItem local->world lowering.
// Four aliases are kept for tests.zig: getNodeDisplayItems / getNodeTextBlobs /
// getNodeDisplayPayload / appendNodeDisplayPayloadToRenderList.
// TODO: after GpuDraw B-7 paint_table main path integration, consider inlining into the
// cx.render() tail and deleting this file.
pub const getNodeDisplayItems = display_list_lowering_mod.getNodeDisplayItems;
pub const getNodeTextBlobs = display_list_lowering_mod.getNodeTextBlobs;
pub const getNodeDisplayPayload = display_list_lowering_mod.getNodeDisplayPayload;
pub const appendNodeDisplayPayloadToRenderList = display_list_lowering_mod.appendNodeDisplayPayloadToRenderList;
const appendNodeDisplayPayloadToRenderListForReplay = display_list_lowering_mod.appendNodeDisplayPayloadToRenderListForReplay;

/// Current frame dt (seconds), set by tickBeforeRender, read by on_before_render
/// hook
pub var current_frame_dt_seconds: f32 = 1.0 / 60.0;

/// Current frame absolute timestamp (ms), monotonic increasing relative to app
/// launch. Animation system computes exact progress via (now_ms - start_time_ms) /
/// duration, zero cumulative error.
pub var current_frame_time_ms: f64 = 0;
/// Record real monotonic clock (ms) when `current_frame_time_ms` set, used for
/// event phase to estimate "current time".
pub var current_frame_monotonic_ms: f64 = 0;
/// Current frame delta dt (ms): actual frame interval (max 1s, idle wake first
/// frame nominal), for delta consumers.
pub var current_frame_dt_ms: f32 = 16.667;

pub var current_reduced_motion: bool = false;
pub var current_frame_io: ?std.Io = null;

pub const FrameClock = struct {
    io: std.Io,
    reduced_motion: bool = false,
    time_ms: f64,
    dt_ms: f32,
    dt_seconds: f32,
};

/// Complete snapshot of global animation clock (includes monotonic moment for
/// event phase estimate), save/restore for nested host entry.
pub const SavedFrameClock = struct {
    io: ?std.Io,
    time_ms: f64,
    monotonic_ms: f64,
    dt_ms: f32,
    dt_seconds: f32,
};

pub fn saveFrameClock() SavedFrameClock {
    return .{
        .io = current_frame_io,
        .time_ms = current_frame_time_ms,
        .monotonic_ms = current_frame_monotonic_ms,
        .dt_ms = current_frame_dt_ms,
        .dt_seconds = current_frame_dt_seconds,
    };
}

pub fn restoreFrameClock(saved: SavedFrameClock) void {
    current_frame_io = saved.io;
    current_frame_time_ms = saved.time_ms;
    current_frame_monotonic_ms = saved.monotonic_ms;
    current_frame_dt_ms = saved.dt_ms;
    current_frame_dt_seconds = saved.dt_seconds;
}

pub fn setFrameClock(clock: FrameClock) void {
    current_frame_io = clock.io;
    current_reduced_motion = clock.reduced_motion;
    current_frame_time_ms = clock.time_ms;
    current_frame_monotonic_ms = @as(f64, @floatFromInt(@import("zenit_time").monotonicTimestamp(clock.io))) / 1_000_000.0;
    current_frame_dt_ms = clock.dt_ms;
    current_frame_dt_seconds = clock.dt_seconds;
}

test "nested frame clock restores the owning IO context and time" {
    const original = saveFrameClock();
    const original_reduced_motion = current_reduced_motion;
    defer {
        restoreFrameClock(original);
        current_reduced_motion = original_reduced_motion;
    }
    var nested = std.Io.Threaded.init(std.testing.allocator, .{});
    defer nested.deinit();
    setFrameClock(.{ .io = std.testing.io, .time_ms = 125, .dt_ms = 10, .dt_seconds = 0.01 });
    const outer = saveFrameClock();
    setFrameClock(.{ .io = nested.io(), .time_ms = 500, .dt_ms = 20, .dt_seconds = 0.02 });
    try std.testing.expect(current_frame_io.?.userdata == nested.io().userdata);
    restoreFrameClock(outer);
    try std.testing.expect(current_frame_io.?.userdata == std.testing.io.userdata);
    try std.testing.expectEqual(@as(f64, 125), current_frame_time_ms);
    try std.testing.expectEqual(outer.monotonic_ms, current_frame_monotonic_ms);
    try std.testing.expectEqual(@as(f32, 10), current_frame_dt_ms);
    try std.testing.expectEqual(@as(f32, 0.01), current_frame_dt_seconds);
    restoreFrameClock(.{ .io = null, .time_ms = 42, .monotonic_ms = 0, .dt_ms = 0, .dt_seconds = 0 });
    try std.testing.expect(current_frame_io == null);
    try std.testing.expectEqual(@as(f64, 42), estimateTimeMs());
}

fn shouldCacheOverflowSubtree(node: *Node) bool {
    if (node.tag == .scroll or node.tag == .input) return false;
    if (node.hasBeforeRenderHooks()) return false;
    if (node.frame_state.frame_local.runtime.commands != null) return false;
    if (node.frame_state.state_bits.flags.disable_render_cache) return false;
    return true;
}

fn disableSpannedTextRetainedEnabled() bool {
    if (disable_spanned_text_retained_cache) |v| return v;
    const raw = @import("zenit_environment").getNative("ZENIT_DISABLE_SPANNED_TEXT_RETAINED");
    if (raw == null) {
        disable_spanned_text_retained_cache = false;
        return false;
    }
    const value = std.mem.span(raw.?);
    const enabled = !(value.len == 0 or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"));
    disable_spanned_text_retained_cache = enabled;
    return enabled;
}

fn nodeHasSpannedText(node: *Node) bool {
    if (node.getText()) |t| {
        if (t.spans.len > 0) return true;
    }
    for (node.children.items) |child| {
        if (nodeHasSpannedText(child)) return true;
    }
    return false;
}

/// custom_draw callback context: directly write lowered DisplayItem, substitute
/// for child node recursion
pub const DrawContext = struct {
    /// Maps absolute anchors to the active surface content frame.
    content_from_world: Transform2D = Transform2D.identity(),
    lowering_buffer: *std.ArrayList(display_list_mod.DisplayItem),
    /// encoder main path consumes paint_table.DisplayItem; DrawContext exposes this
    /// buffer to snapshot.appendTo and other callers needing direct encoder-path writes.
    lowering_buffer_paint: ?*std.ArrayList(@import("../paint_table.zig").DisplayItem) = null,
    display_list: ?*display_list_mod.DisplayList = null,
    display_header: ?display_list_mod.ItemHeader = null,
    allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    render_x: f32,
    render_y: f32,
    render_w: f32,
    render_h: f32,
    local_w: f32,
    local_h: f32,
    clip: ?ComputedRect,
    /// Nearest text color up the ancestors (CSS currentColor) of the drawing node, null when none
    /// declares one: a drawing inside a control follows the control's foreground through its
    /// states (repainted when it changes, see Node.markInheritedTextDirty).
    current_color: ?types.Color = null,
};

/// Pre-render pass: tickBeforeRender common entry (forwards to tick submodule)
pub fn tickBeforeRender(node: *Node, offset_x: f32, offset_y: f32, clip_opt: ?ComputedRect, allocator: Allocator, dt_ms: f32) bool {
    return tick_mod.tickBeforeRender(node, offset_x, offset_y, clip_opt, allocator, dt_ms, current_frame_time_ms);
}

// -- Frame initialization --

fn beginRetainedFrame(cx: *RenderContext) void {
    cx.display_payload_prefix_broken = false;
    cx.scene_runtime.clear();
    cx.property_tree.clear();
    cx.layer_tree.planClear();
    cx.display_list.clear();
    cx.text_blob_store.clear();
    // Previous frame blob borrow invalidates: reclaim text switched out between
    // frames
    cx.world.content.releaseRetired();
    _ = cx.property_tree.appendTransform(.{
        .parent = 0,
        .node_id = 0,
        .local = Transform2D.identity(),
        .world = Transform2D.identity(),
        .inverse_world = Transform2D.identity(),
        .content = Transform2D.identity(),
        .flags = .{
            .is_axis_aligned = true,
            .is_integer_translation = true,
        },
        // Non-degradable: this is property_tree root transform (id 0), all subsequent
        // transform_ids indexed relative to it. Missing -> all-frame transform indices
        // misaligned.
    }) catch @panic("OOM: property_tree root transform append");
}

// -- Display list payload range update --

fn updateNodeDisplayPayloadRanges(
    cx: *RenderContext,
    node_id: u32,
    display_start: usize,
    blob_start: usize,
) void {
    if (cx.scene_runtime.nodes.getPtr(node_id)) |runtime| {
        runtime.display_item_start = @intCast(display_start);
        runtime.display_item_count = @intCast(cx.display_list.items.items.len - display_start);
        runtime.text_blob_start = @intCast(blob_start);
        runtime.text_blob_count = @intCast(cx.text_blob_store.blobs.items.len - blob_start);
    }
}

fn updateNodeSubtreeDisplayPayloadRanges(
    cx: *RenderContext,
    node_id: u32,
    display_start: usize,
    blob_start: usize,
) void {
    if (cx.scene_runtime.nodes.getPtr(node_id)) |runtime| {
        runtime.subtree_display_item_start = @intCast(display_start);
        runtime.subtree_display_item_count = @intCast(cx.display_list.items.items.len - display_start);
        runtime.subtree_text_blob_start = @intCast(blob_start);
        runtime.subtree_text_blob_count = @intCast(cx.text_blob_store.blobs.items.len - blob_start);
    }
}

/// Subtree range of a node the paint pass visited (entered at `display_start`). A node the prebuild
/// pass already put in the display list prefix (fallback path, or a prebuilt subtree whose fresh
/// copy was truncated) carries that range: when the paint pass appended nothing for it, the prefix
/// range is the subtree and is kept, otherwise the subtree is split between the prefix and the
/// tail and the range below covers only the tail (subtree_display_split).
fn finishNodeSubtreeDisplayPayloadRanges(
    cx: *RenderContext,
    node_id: u32,
    display_start: usize,
    blob_start: usize,
) void {
    const runtime = cx.scene_runtime.nodes.getPtr(node_id) orelse return;
    if (runtime.subtree_display_item_count > 0 and runtime.subtree_display_item_start < display_start) {
        if (cx.display_list.items.items.len == display_start) return;
        runtime.subtree_display_split = true;
    }
    updateNodeSubtreeDisplayPayloadRanges(cx, node_id, display_start, blob_start);
}

// -- Display list decision --

fn canUseSafeSelfEffectDisplayPayload(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    if (exec_state.retained_ids.effect_id == INVALID_ID) return false;
    if (@abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001) return false;
    if (@abs(node.style.rotate()) > 0.0001) return false;
    var current = exec_state.retained_ids.effect_id;
    var saw_safe_effect = false;
    while (current != active_parent_effect_id and current != INVALID_ID) {
        if (current >= cx.property_tree.effects.items.len) return false;
        const effect = cx.property_tree.effects.items[current];
        if (effect.node_id != node.id) return false;
        switch (effect.kind) {
            .opacity => {
                if (node.getOpacity() >= 0.999) return false;
            },
            .composited_group => {},
            .rounded_clip => {
                if (exec_state.clip_shape_kind != .rounded_rect) return false;
            },
            .backdrop_blur => {
                if (effectiveBackdropBlurRadius(node) < 0.5) return false;
            },
        }
        saw_safe_effect = true;
        current = effect.parent;
    }
    return saw_safe_effect and current == active_parent_effect_id;
}

fn canRepresentOwnContentInDisplayList(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    const allow_safe_self_effect = canUseSafeSelfEffectDisplayPayload(cx, node, exec_state, active_parent_effect_id);
    const uses_relative_effect_space = active_parent_effect_id != INVALID_ID or allow_safe_self_effect;
    // No `hasScrollAncestor` restriction: replay reads world transforms from the property tree
    // at replay time, so coordinates stay correct across scroll. The restriction would disable
    // own-content display list caching for all content inside a ScrollArea, forcing a rebuild
    // of every node each frame.
    //
    // Blur-only effect owner (no opacity layer / rounded_clip capture surface) is representable:
    // the item's effect header lets lowering begin_blur at the correct position, and content
    // stays in the world frame (same contract as .self_blur). A blur node is always promoted but
    // has no content capture surface (applyBackdropBlur composes instantly), so the promoted
    // rejection rationale (content through the surface cache path) does not apply. Rejecting it
    // pushes the nested blur subtree to the paint pass tail (fresh emit) -> storage order
    // inverted, and the glass backplate obscures tree-later sibling content.
    const blur_only_effect = effectiveBackdropBlurRadius(node) >= 0.5 and !exec_state.use_opacity_layer and !exec_state.use_rounded_clip;
    if (exec_state.use_opacity_layer and !allow_safe_self_effect) return false;
    if (exec_state.is_promoted_layer and !blur_only_effect) return false;
    if (exec_state.retained_ids.effect_id != INVALID_ID and exec_state.retained_ids.effect_id != active_parent_effect_id and !allow_safe_self_effect and !blur_only_effect) return false;
    if (node.meta.per_frame.custom_hooks.draw != null and node.children.items.len > 0) return false;
    if (!std.math.approxEqAbs(f32, exec_state.scale_x_abs, 1.0, 0.0001)) return false;
    if (!std.math.approxEqAbs(f32, exec_state.scale_y_abs, 1.0, 0.0001)) return false;
    if (@abs(node.style.rotate()) > 0.0001) return false;
    if (!uses_relative_effect_space) {
        if (!std.math.approxEqAbs(f32, exec_state.render_x, exec_state.world_rect.x, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.render_y, exec_state.world_rect.y, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.render_w, exec_state.world_rect.w, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.render_h, exec_state.world_rect.h, 0.0001)) return false;
    }
    return true;
}

fn replayNodeOwnContentFromDisplayList(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    _: u32,
) !bool {
    return appendNodeDisplayPayloadToRenderListForReplay(
        cx,
        node,
        exec_state,
        .simple,
        .own,
        exec_state.retained_ids.effect_id,
    );
}

fn tryReplayOwnContentFromPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !bool {
    if (!exec_plan.should_try_display_payload_own_replay) return false;
    if (try replayNodeOwnContentFromDisplayList(cx, node, exec_state, parent_effect_id)) {
        cx.perf.display_list_own_replay_count += 1;
        return true;
    }
    return false;
}

fn tryReplaySubtreePayloadFromPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !bool {
    if (!exec_plan.should_try_display_payload_subtree_replay) return false;
    if (cx.subtree_payload_replay_disabled) return false; // Escape hatch ZENIT_DISABLE_SUBTREE_PAYLOAD_REPLAY: cut when investigating clipping / artifacts
    if (try appendNodeDisplayPayloadToRenderListForReplay(
        cx,
        node,
        exec_state,
        exec_plan.prebuilt_display_payload_strategy,
        .subtree,
        parent_effect_id,
    )) {
        cx.perf.display_list_subtree_replay_count += 1;
        if (scene_runtime_mod.displayPayloadSubtreeStrategyUsesSelfEffectSpace(exec_plan.prebuilt_display_payload_strategy)) {
            cx.perf.display_list_self_effect_subtree_replay_count += 1;
        }
        markNodeSubtreeRenderedClean(node);
        return true;
    }
    return false;
}

/// Whether a descendant paints outside the regular band (sticky, positive z). Answered from
/// this frame's index (indexRenderCacheBoundaries) when there is one: the prepass checks ask it
/// at every level of a subtree, which made the recursive walk quadratic in depth.
fn subtreeHasOutOfBandPasses(cx: *const RenderContext, node: *Node) bool {
    if (cx.out_of_band_subtrees) |set| return set.contains(node.id);
    return subtreeHasOutOfBandPassesWalk(node);
}

fn subtreeHasOutOfBandPassesWalk(node: *Node) bool {
    for (node.children.items) |child| {
        if (childIsOutOfBand(child)) return true;
        if (subtreeHasOutOfBandPassesWalk(child)) return true;
    }
    return false;
}

fn childIsOutOfBand(child: *Node) bool {
    return child.style.position == .sticky or child.style.z_index() > 0;
}

inline fn effectiveBackdropBlurRadius(node: *Node) f32 {
    const blur = node.style.backdrop_blur();
    return if (blur >= 0.5) blur else 0;
}

fn hasScrollAncestor(node: *Node) bool {
    var current = node.parent;
    while (current) |ancestor| : (current = ancestor.parent) {
        if (ancestor.tag == .scroll) return true;
    }
    return false;
}

fn shouldUseDisplayListForSimpleSubtree(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    active_parent_effect_id: u32,
) bool {
    const allow_safe_self_effect = canUseSafeSelfEffectDisplayPayload(cx, node, exec_state, active_parent_effect_id);
    const uses_relative_effect_space = active_parent_effect_id != INVALID_ID or allow_safe_self_effect;
    if (node.children.items.len == 0) return false;
    if (node.frame_state.state_bits.flags.has_custom_draw_subtree) return false;
    if (hasUntrustedBeforeRenderHookSubtree(node)) return false;
    if (node.tag == .scroll or node.tag == .input) return false;
    // Phase G experiment: removed `hasScrollAncestor` restriction here too.
    // See comment in `canRepresentOwnContentInDisplayList`.
    if (subtreeHasOutOfBandPasses(cx, node)) return false;
    if (exec_plan.should_try_promoted_replay or exec_plan.should_try_legacy_overflow_replay) return false;
    if (exec_plan.should_write_promoted_cache or exec_plan.should_write_legacy_overflow_cache) return false;
    if (exec_state.use_opacity_layer and !allow_safe_self_effect) return false;
    if (exec_state.is_promoted_layer) return false;
    if (exec_state.retained_ids.effect_id != INVALID_ID and exec_state.retained_ids.effect_id != active_parent_effect_id and !allow_safe_self_effect) return false;
    if (!allow_safe_self_effect) {
        if (!std.math.approxEqAbs(f32, exec_state.scale_x_abs, 1.0, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.scale_y_abs, 1.0, 0.0001)) return false;
    }
    if (@abs(node.style.rotate()) > 0.0001) return false;
    if (!uses_relative_effect_space) {
        if (!std.math.approxEqAbs(f32, exec_state.render_x, exec_state.world_rect.x, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.render_y, exec_state.world_rect.y, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.render_w, exec_state.world_rect.w, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.render_h, exec_state.world_rect.h, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.content_transform.a, exec_state.world_transform.a, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.content_transform.b, exec_state.world_transform.b, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.content_transform.c, exec_state.world_transform.c, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.content_transform.d, exec_state.world_transform.d, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.content_transform.tx, exec_state.world_transform.tx, 0.0001)) return false;
        if (!std.math.approxEqAbs(f32, exec_state.content_transform.ty, exec_state.world_transform.ty, 0.0001)) return false;
    }
    return true;
}

fn subtreeCanUseDisplayListPrepass(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    const exec_plan = buildNodeExecutionPlan(cx, node, exec_state, active_parent_effect_id);
    if (!shouldUseDisplayListForSimpleSubtree(cx, node, exec_state, exec_plan, active_parent_effect_id)) return false;

    for (node.children.items) |child| {
        // A paint-skipped child (hidden / transparent) draws nothing and the prebuild loop skips it
        // too; making it visible marks the subtree (setOpacity / visibility are dirty-marking).
        if (child.isPaintSkipped()) continue;
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) return false;
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            exec_state.effective_clip,
            exec_state.subtree_force_linear_text,
        ) orelse return false;
        const child_exec_plan = buildNodeExecutionPlan(cx, child, &child_exec_state, exec_state.retained_ids.effect_id);
        if (child.children.items.len == 0) {
            if (!canRepresentOwnContentInDisplayList(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) return false;
            if (child_exec_plan.should_try_promoted_replay or child_exec_plan.should_try_legacy_overflow_replay) return false;
            if (child_exec_plan.should_write_promoted_cache or child_exec_plan.should_write_legacy_overflow_cache) return false;
            continue;
        }
        if (!subtreeCanUseDisplayListPrepass(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) return false;
    }
    return true;
}

fn subtreeCanUseDisplayListPrepassWithSelfScale(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    const has_self_scale = @abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001;
    const has_self_blur = effectiveBackdropBlurRadius(node) >= 0.5;
    if (!has_self_scale) return false;
    if (hasScrollAncestor(node)) return false;
    if (@abs(node.style.rotate()) > 0.0001) return false;
    if (node.children.items.len == 0) return false;

    const exec_plan = buildNodeExecutionPlan(cx, node, exec_state, active_parent_effect_id);
    if ((exec_plan.should_try_promoted_replay or exec_plan.should_write_promoted_cache) and !has_self_blur) return false;
    if (exec_plan.should_try_legacy_overflow_replay) return false;
    if (exec_plan.should_write_legacy_overflow_cache) return false;
    if (node.frame_state.state_bits.flags.has_custom_draw_subtree) return false;
    if (subtreeHasOutOfBandPasses(cx, node)) return false;
    if (exec_state.retained_ids.effect_id == INVALID_ID) return false;
    if (exec_state.retained_ids.effect_id == active_parent_effect_id) return false;

    for (node.children.items) |child| {
        if (child.isPaintSkipped()) continue;
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) return false;
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            exec_state.effective_clip,
            exec_state.subtree_force_linear_text,
        ) orelse return false;
        const child_exec_plan = buildNodeExecutionPlan(cx, child, &child_exec_state, exec_state.retained_ids.effect_id);
        if (child.children.items.len == 0) {
            if (!canRepresentOwnContentInDisplayList(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) return false;
            if (child_exec_plan.should_try_promoted_replay or child_exec_plan.should_try_legacy_overflow_replay) return false;
            if (child_exec_plan.should_write_promoted_cache or child_exec_plan.should_write_legacy_overflow_cache) return false;
            continue;
        }
        if (subtreeCanUseDisplayListPrepassWithSelfScale(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (!subtreeCanUseDisplayListPrepass(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) return false;
    }
    return true;
}

fn subtreeCanUseDisplayListPrepassWithSelfBlur(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    if (effectiveBackdropBlurRadius(node) < 0.5) return false;
    if (hasScrollAncestor(node)) return false;
    if (@abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001) return false;
    if (@abs(node.style.rotate()) > 0.0001) return false;
    if (node.getOpacity() < 0.999) return false;
    // Blur nodes without children (e.g. a glass header band) must also use prepass:
    // display_list storage order = z order. If rejected by prepass and left to fresh emit at the
    // paint pass tail, it sorts after **tree-later but prepass'd** sibling content, so the glass
    // backplate paints over it and obscures the text. The leaf's own content is subtree payload,
    // and .self_blur world coordinate semantics hold for a leaf equally.
    if (node.frame_state.state_bits.flags.has_custom_draw_subtree) return false;
    if (subtreeHasOutOfBandPasses(cx, node)) return false;
    if (exec_state.retained_ids.effect_id == INVALID_ID) return false;
    if (exec_state.retained_ids.effect_id == active_parent_effect_id) return false;

    const exec_plan = buildNodeExecutionPlan(cx, node, exec_state, active_parent_effect_id);
    if (exec_plan.should_try_legacy_overflow_replay) return false;
    if (exec_plan.should_write_legacy_overflow_cache) return false;

    for (node.children.items) |child| {
        if (child.isPaintSkipped()) continue;
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) return false;
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            exec_state.effective_clip,
            exec_state.subtree_force_linear_text,
        ) orelse return false;
        const child_exec_plan = buildNodeExecutionPlan(cx, child, &child_exec_state, exec_state.retained_ids.effect_id);
        if (child.children.items.len == 0) {
            // Nested blur leaf (progressive blur inner layer): blur always promoted ->
            // should_write_promoted_cache wrongly rejects; it qualifies by self_blur itself.
            if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) continue;
            if (!canRepresentOwnContentInDisplayList(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) return false;
            if (child_exec_plan.should_try_promoted_replay or child_exec_plan.should_try_legacy_overflow_replay) return false;
            if (child_exec_plan.should_write_promoted_cache or child_exec_plan.should_write_legacy_overflow_cache) return false;
            continue;
        }
        if (subtreeCanUseDisplayListPrepassWithSelfScale(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (!subtreeCanUseDisplayListPrepass(cx, child, &child_exec_state, exec_state.retained_ids.effect_id)) return false;
    }
    return true;
}

fn shouldPreferDisplayListPrepassChildren(
    _: anytype,
    node: *Node,
    exec_state: *const NodeExecutionState,
) bool {
    const has_self_scale = @abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001;
    if (!has_self_scale) return false;

    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) continue;
        if (child.children.items.len > 0) return true;
    }
    return false;
}

fn setNodeDisplayPayloadSubtreePrebuilt(
    cx: *RenderContext,
    node_id: u32,
    enabled: bool,
    strategy: scene_runtime_mod.DisplayPayloadSubtreeStrategy,
) void {
    if (cx.scene_runtime.nodes.getPtr(node_id)) |runtime| {
        runtime.display_payload_subtree_prebuilt = enabled;
        runtime.display_payload_subtree_strategy = if (enabled) strategy else .none;
        runtime.display_payload_subtree_prebuilt_epoch = if (enabled) cx.scene_runtime.frame_epoch else 0;
    }
}

fn setNodeDisplayPayloadOwnPrebuilt(
    cx: *RenderContext,
    node_id: u32,
    enabled: bool,
) void {
    if (cx.scene_runtime.nodes.getPtr(node_id)) |runtime| {
        runtime.display_payload_own_prebuilt = enabled;
        runtime.display_payload_own_prebuilt_epoch = if (enabled) cx.scene_runtime.frame_epoch else 0;
    }
}

fn markNodeSubtreeRenderedClean(node: *Node) void {
    markNodeRenderedClean(node);
    for (node.children.items) |child| {
        // A paint-skipped child was not recorded with the subtree (the prebuild skips it).
        if (child.isPaintSkipped()) {
            clearSkippedInvisibleSubtreeDirty(child);
            continue;
        }
        markNodeSubtreeRenderedClean(child);
    }
}

// -- Cross-frame subtree payload cache (avoids O(full tree) re-record on a single dirty leaf) --
//
// display_list / scene_runtime / property_tree are cleared and rebuilt each frame, and any leaf
// markRenderDirty bubbles subtree_render to the root, so the prebuild pass would re-record the
// entire simple subtree (appendNodeOwnContent * full tree).
//
// The prebuild fresh path therefore writes a cross-frame DisplayItem copy for each .simple
// subtree node (text_run materialized, blob ref broken, content/spans deep-copied). When the
// parent subtree is re-recorded, clean sibling subtrees appendSlice their cached copies
// (splice); only dirty subtrees and the root path are re-recorded. Invalidation follows the
// promoted cache:
//   - Cache header transform/effect/clip ids are the frame-internal seq of the write frame;
//     appendCachedCommands rewrites every item to this frame's ids by node_id, so shifted ids
//     are harmless. The stamp instead compares the root's owned scopes (ownerSignature): a root
//     that gained / lost its own effect or clip -> MISS.
//   - Any dirty bit on node or subtree (render/layout/composite x self/subtree) -> MISS.
//   - hooks / custom_draw / overlay / animation / disable_render_cache -> excluded.
// Coordinates: cached items are local space + transform_id header and read the current frame's
// property tree matrix on lower, so ancestor shifts/scrolls need not invalidate the cache.

/// Single-node cached item count limit: caps ancestor-descendant overlapping copy
/// memory amplification (root subtree uncached, leaf/small branches cached -> splice
/// granularity naturally lands at sibling level).
const subtree_payload_cache_max_items: usize = 256;

/// ZENIT_DISABLE_HOOK_SELF_SCOPE, refreshed at every renderNode (see hookScopeIsSelfOnly).
var hook_self_scope_disabled: bool = false;
var retained_memo_disabled_cache: ?bool = null;
/// ZENIT_DISABLE_RETAINED_MEMO=1 (read once) or a test override turns the retained subtree memo off.
pub var retained_memo_test_override: ?bool = null;
fn retained_memo_disabled() bool {
    if (retained_memo_test_override) |on| return !on;
    return retained_memo_disabled_cache orelse blk: {
        const v = @import("zenit_environment").flag("ZENIT_DISABLE_RETAINED_MEMO");
        retained_memo_disabled_cache = v;
        break :blk v;
    };
}
/// ZENIT_DEBUG_PREPASS, refreshed at every renderNode (the check sits on a per-node path).
var debug_prepass: bool = false;
/// ZENIT_TRACE_NODE=<node id> (read once per renderNode): log every subtree payload cache write
/// and splice whose commands contain that node. Debugging aid for stale-replay hunts.
pub var trace_node: u32 = 0;

/// before_render hook declared "self-only impact" (same-named NodeFlags bit).
///
/// When set, prebuild does **not** cut the paint prefix: the hook's own node is still excluded
/// from the cross-frame payload cache (hasBeforeRenderHooks in
/// nodeEligibleForSubtreePayloadCache keeps blocking), but its **siblings and descendants**
/// regain normal cache eligibility.
///
/// Two exceptions apply regardless of the declaration (callsites can't guarantee them):
///   - overlay candidate: the hook relocates the float each frame (setPopoverTranslate), so
///     prebake burns in the first-frame translate=0 position -> residue at top-left.
///   - Active manual transform/opacity animation: the hook writes ancestor-level transform
///     each frame.
///
/// Escape hatch ZENIT_DISABLE_HOOK_SELF_SCOPE=1 disables the downgrade entirely.
fn hookScopeIsSelfOnly(node: *Node, exec_state: *const NodeExecutionState, parent_effect_id: u32) bool {
    if (!node.beforeRenderHooksSelfOnly()) return false;
    // Escape hatch read once per renderNode (not a process-level one-shot cache, which would bake
    // the value so a test binary could not reach the other branch), like
    // ZENIT_DISABLE_SUBTREE_SPLICE / ZENIT_DISABLE_SUBTREE_PAYLOAD_REPLAY.
    if (hook_self_scope_disabled) return false;
    // Exception one: float relocation hook changes transform each frame, guarantee
    // void.
    if (exec_state.retained_runtime.is_overlay_candidate) return false;
    // Exception two: manual animation in progress, hook writes transform itself.
    const flags = node.frame_state.state_bits.flags;
    if (flags.manual_transform_animation_active or flags.manual_opacity_animation_active) return false;
    // Exception three: this node itself is promoted surface owner.
    if (exec_state.is_promoted_layer) return false;
    // Exception four: nodes **inside a retained/effect surface** are not allowed.
    //
    // Retained layer partial redraws (opacity_layer.zig:730-741) derive the damage rect from
    // "frame content missed cache -> re-record -> diff dirty region". If this node's content
    // switched to cross-frame splice, the retained layer couldn't see the change and
    // partial_repaints would stop growing (storybook "button hover in modal triggers partial
    // redraw" fails; ZENIT_DISABLE_SUBTREE_SPLICE restores it).
    //
    // Criterion uses parent_effect_id: passed down recursively, non-INVALID means an
    // effect/promoted surface is on the ancestor chain, exactly the scope of the damage-rect and
    // promoted cache assembly paths. Also covers nodes inside a blur island (GlassLab).
    if (parent_effect_id != INVALID_ID) return false;
    return true;
}

/// A before_render hook that prebuild must not see past: its content is left for the paint pass
/// and its whole subtree is treated as hook-owned. An undeclared hook may write its descendants
/// without marking them dirty (ScrollArea's scrollbar hook writes the thumb with
/// setBackgroundRaw every frame), so nothing below it may be recorded ahead of the hook's
/// node or reused across frames. Custom-draw hooks (Spinner/Progress) only advance their own
/// animation parameters and stay prebuildable; self-only hooks are bounded by the audit in
/// tick.zig (see hookScopeIsSelfOnly).
fn beforeRenderHookTaintsSubtree(node: *Node, exec_state: *const NodeExecutionState, parent_effect_id: u32) bool {
    if (!beforeRenderHookBreaksPrefix(node, exec_state, parent_effect_id)) return false;
    // Declared contract (audited): the hook leaves its node and subtree cache-safe.
    return !(node.beforeRenderHooksCacheTrusted() and
        !exec_state.retained_runtime.is_overlay_candidate);
}

/// The prebuild pass stops at this node (content left for the paint pass). Unchanged by the
/// descendants_cache_safe declaration: ordering stays conservative, only reuse is unlocked.
fn beforeRenderHookBreaksPrefix(node: *Node, exec_state: *const NodeExecutionState, parent_effect_id: u32) bool {
    if (!node.hasBeforeRenderHooks()) return false;
    if (!exec_state.retained_runtime.is_overlay_candidate and
        exec_state.retained_runtime.content_flags.has_custom_draw) return false;
    return !hookScopeIsSelfOnly(node, exec_state, parent_effect_id);
}

/// Promoted and legacy overflow caches bake each text_run's raster policy and each icon's snap
/// (both follow `subtree_force_linear_text`). That state is inherited and flips without marking
/// anything dirty: an ancestor starts or stops a transform animation (or its linger frames run
/// out), e.g. a tooltip / popover scaling in. A cache recorded under the other state is dropped
/// before the plan can replay or splice any part of it (descendant-scoped rebuilds reuse old
/// self and child segments too). The subtree / own payload caches stamp the same state.
fn dropCachesWithStaleTextRasterState(cx: *RenderContext, node: *Node, force_linear_text: bool) void {
    // Reference frames must leave every cache exactly as the incremental frame left it.
    if (cx.subtree_payload_reference_mode) return;
    const caches = &node.meta.per_frame.caches.commands;
    if (caches.promoted) |cache| if (cache.cached_force_linear_text != force_linear_text) {
        node_render_cache_mod.invalidatePromotedRenderCache(node);
        cx.perf.raster_state_cache_drop_count += 1;
    };
    if (caches.own) |cache| if (cache.cached_force_linear_text != force_linear_text) {
        node_render_cache_mod.invalidateRenderCache(node);
        cx.perf.raster_state_cache_drop_count += 1;
    };
}

fn markPrebuildVisited(cx: *RenderContext, node_id: u32) void {
    if (cx.scene_runtime.nodes.getPtr(node_id)) |rt| rt.prebuild_visited = true;
}

const BoundaryIndexResult = struct { boundary: bool, out_of_band: bool };

/// One walk, three frame indexes: subtrees holding or under a cache boundary (`blocked`), nodes
/// whose own content is blocked, and nodes with an out-of-band descendant (`out_of_band`, see
/// subtreeHasOutOfBandPasses).
fn indexRenderCacheBoundaries(
    allocator: Allocator,
    node: *Node,
    ancestor_has_boundary: bool,
    blocked: *id_hash.U32HashMapUnmanaged(void),
    own_blocked: ?*id_hash.U32HashMapUnmanaged(void),
    out_of_band: ?*id_hash.U32HashMapUnmanaged(void),
) !BoundaryIndexResult {
    const self_is_boundary = node.frame_state.state_bits.flags.disable_render_cache;
    var subtree_has_boundary = self_is_boundary;
    var subtree_out_of_band = false;
    for (node.children.items) |child| {
        const r = try indexRenderCacheBoundaries(
            allocator,
            child,
            ancestor_has_boundary or self_is_boundary,
            blocked,
            own_blocked,
            out_of_band,
        );
        if (r.boundary) subtree_has_boundary = true;
        if (r.out_of_band or childIsOutOfBand(child)) subtree_out_of_band = true;
    }
    if (ancestor_has_boundary or subtree_has_boundary) try blocked.put(allocator, node.id, {});
    // Own content only depends on the node itself: a boundary below it does not matter.
    if (own_blocked) |ob| if (ancestor_has_boundary or self_is_boundary) try ob.put(allocator, node.id, {});
    if (out_of_band) |set| if (subtree_out_of_band) try set.put(allocator, node.id, {});
    return .{ .boundary = subtree_has_boundary, .out_of_band = subtree_out_of_band };
}

fn nodeEligibleForSubtreePayloadCache(cx: *const RenderContext, node: *Node, runtime: *const scene_runtime_mod.SceneNodeRuntime) bool {
    // Reject cheap local conditions before consulting the frame boundary
    // index. The index is built once in O(N), avoiding a repeated ancestor +
    // subtree walk for every cache candidate in a deep tree.
    const flags = node.frame_state.state_bits.flags;
    if (flags.disable_render_cache) return false;
    if (flags.has_custom_draw_subtree) return false;
    if (flags.manual_transform_animation_active or flags.manual_opacity_animation_active) return false;
    if (!node.beforeRenderHooksCacheTrusted()) return false;
    if (flags.has_untrusted_before_render_subtree) return false;
    if (node.tag == .scroll or node.tag == .input) return false;
    if (runtime.is_overlay_candidate) return false;
    if (runtime.has_active_composite_animation or
        runtime.has_active_transform_animation or
        runtime.has_active_opacity_animation) return false;

    // `disable_render_cache` is a bidirectional subtree boundary. The index
    // contains the boundary itself, every descendant, and every ancestor that
    // would enclose it, while leaving unrelated sibling subtrees eligible.
    const blocked = cx.render_cache_boundary_blocked orelse return false;
    if (blocked.contains(node.id)) return false;
    return true;
}

fn dropSubtreePayloadCache(node: *Node) void {
    if (node.meta.per_frame.caches.commands.subtree_payload) |*cache| cache.deinit();
    node.meta.per_frame.caches.commands.subtree_payload = null;
}

fn nodeCleanForSubtreePayloadSplice(node: *Node) bool {
    const dirty = node.frame_state.state_bits.dirty;
    return !dirty.core.render and !dirty.core.subtree_render and
        !dirty.core.layout and !dirty.core.subtree_layout and
        !dirty.pipeline.composite and !dirty.pipeline.subtree_composite;
}

/// Which property-tree scopes `node_id` itself owns this frame: bit 0 owns an effect, bits 1..7
/// its kind, bit 8 owns a clip. Stable across frames as long as the node's own scopes are; frame
/// sequence ids are not (see CachedRenderSlice.cached_owner_signature).
fn ownerSignature(cx: *const RenderContext, node_id: u32, runtime: anytype) u32 {
    var sig: u32 = 0;
    if (runtime.effect_id != INVALID_ID and runtime.effect_id < cx.property_tree.effects.items.len) {
        const effect = cx.property_tree.effects.items[runtime.effect_id];
        if (effect.node_id == node_id) sig |= 1 | (@as(u32, @backingInt(effect.kind)) << 1);
    }
    if (runtime.clip_id != INVALID_ID and runtime.clip_id < cx.property_tree.clips.items.len) {
        if (cx.property_tree.clips.items[runtime.clip_id].node_id == node_id) sig |= 1 << 8;
    }
    return sig;
}

fn subtreePayloadStampValid(
    cx: *const RenderContext,
    node_id: u32,
    runtime: *const scene_runtime_mod.SceneNodeRuntime,
    cache: *const node_mod.CachedRenderSlice,
) bool {
    if (cache.cached_owner_signature != ownerSignature(cx, node_id, runtime)) return false;
    if (cache.content_version != runtime.content_version) return false;
    if (@abs(cache.world_bounds.w - runtime.world_bounds.w) > 0.01) return false;
    if (@abs(cache.world_bounds.h - runtime.world_bounds.h) > 0.01) return false;
    return true;
}

/// Clean subtree cross-frame payload splice: on hit, entire subtree avoids re-record,
/// directly append cached copy to display_list current position (matches fresh prebuild
/// landing, paint-order invariant maintained), backfill runtime ranges + prebuilt flag,
/// paint pass takes existing subtree-replay shortcut.
fn trySpliceSubtreePayloadCache(cx: *RenderContext, node: *Node, inherited_force_linear_text: bool) !bool {
    if (cx.subtree_splice_disabled) return false; // Escape hatch ZENIT_DISABLE_SUBTREE_SPLICE: cut when investigating clipping / artifacts
    if (cx.subtree_payload_reference_mode) return false;
    if (node.meta.per_frame.caches.commands.subtree_payload == null) return false;
    const cache = &node.meta.per_frame.caches.commands.subtree_payload.?;
    if (!nodeCleanForSubtreePayloadSplice(node)) return false;
    const runtime = cx.scene_runtime.getPtr(node.id) orelse return false;
    // Stamp checks are O(1). Do them before the boundary tree walk and evict
    // caches that can no longer be reused, otherwise a deep tree can rescan the
    // same stale subtrees every frame.
    // Same derivation as buildNodeExecutionState.subtree_force_linear_text; the auto term
    // (active transform animation) is excluded by eligibility.
    const force_linear_text = inherited_force_linear_text or node.frame_state.state_bits.flags.text_stabilize_subtree;
    if (!subtreePayloadStampValid(cx, node.id, runtime, cache) or cache.cached_force_linear_text != force_linear_text) {
        dropSubtreePayloadCache(node);
        return false;
    }
    if (!nodeEligibleForSubtreePayloadCache(cx, node, runtime)) {
        dropSubtreePayloadCache(node);
        return false;
    }

    if (trace_node != 0) for (cache.commands) |*c| if (c.header().node_id == trace_node) {
        std.debug.print("[trace] epoch={d} splice root={d} contains {d}\n", .{ cx.scene_runtime.frame_epoch, node.id, trace_node });
        break;
    };
    const start = cx.display_list.items.items.len;
    try appendCachedCommands(cx, cache.commands);
    // Use actual length delta after append: appendCachedCommands silently skips cache items
    // without scene_runtime records this frame (descendants culled), using cache.commands.len
    // gives false high, splice appends to list tail, false high range invades next sibling's
    // display items, rebuilding cache from this source next time absorbs neighbor items.
    const appended: u32 = @intCast(cx.display_list.items.items.len - start);
    if (cx.scene_runtime.nodes.getPtr(node.id)) |rt| {
        rt.display_item_start = @intCast(start);
        rt.display_item_count = cache.self_content_command_count;
        // Cached text materialized (content inlined, blob disconnected), blob range zeroed.
        rt.text_blob_start = 0;
        rt.text_blob_count = 0;
        rt.subtree_display_item_start = @intCast(start);
        rt.subtree_display_item_count = appended;
        rt.subtree_text_blob_start = 0;
        rt.subtree_text_blob_count = 0;
        rt.display_payload_own_prebuilt = true;
        rt.display_payload_own_prebuilt_epoch = cx.scene_runtime.frame_epoch;
        rt.display_payload_subtree_prebuilt = true;
        rt.display_payload_subtree_strategy = .simple;
        rt.display_payload_subtree_prebuilt_epoch = cx.scene_runtime.frame_epoch;
        rt.prebuild_visited = true;
    }
    cx.perf.subtree_payload_splice_count += 1;
    return true;
}

/// After fresh prebuild, write cross-frame cache: copy section just written to
/// display_list by this subtree, materialize text blob reference then deep-copy persist.
/// Called only within .simple strategy subtrees.
fn maybeWriteSubtreePayloadCache(cx: *RenderContext, node: *Node, subtree_display_start: usize, force_linear_text: bool) void {
    // Reference frames must leave the cache exactly as the incremental frame wrote it.
    if (cx.subtree_payload_reference_mode) return;
    const end = cx.display_list.items.items.len;
    if (end <= subtree_display_start) {
        dropSubtreePayloadCache(node);
        return;
    }
    const count = end - subtree_display_start;
    if (count > subtree_payload_cache_max_items) {
        dropSubtreePayloadCache(node);
        return;
    }
    const runtime = cx.scene_runtime.get(node.id) orelse {
        dropSubtreePayloadCache(node);
        return;
    };
    if (!nodeEligibleForSubtreePayloadCache(cx, node, &runtime)) {
        dropSubtreePayloadCache(node);
        return;
    }

    const buf = cx.frame_allocator.alloc(DisplayItem, count) catch return;
    @memcpy(buf, cx.display_list.items.items[subtree_display_start..end]);
    // Cross-frame self-containment (same as assembleCacheCommands): blob-backed text_run
    // materialize in-place, sever id reference to per-frame rebuilt text_blob_store
    // (blob_id cross-frame expiry trap).
    for (buf) |*item| {
        switch (item.*) {
            .text_run => |*t| {
                if (t.blob_id != INVALID_ID) {
                    t.content = display_list_mod.resolveTextRunContent(cx.text_blob_store, t.*);
                    t.blob_id = INVALID_ID;
                    t.blob_byte_start = 0;
                    t.blob_byte_end = 0;
                }
            },
            else => {},
        }
    }
    node.cacheSubtreePayloadCommands(
        cx.allocator,
        buf,
        runtime.display_item_count,
        runtime.transform_id,
        runtime.effect_id,
        runtime.clip_id,
        runtime.world_bounds,
    );
    // Stamp content_version aligned with runtime (buildCachedRenderSlice takes node cache
    // versions, splice side compares against runtime.content_version).
    if (node.meta.per_frame.caches.commands.subtree_payload) |*cache| {
        cache.content_version = runtime.content_version;
        cache.cached_force_linear_text = force_linear_text;
        cache.cached_owner_signature = ownerSignature(cx, node.id, runtime);
    }
    cx.perf.subtree_payload_cache_write_count += 1;
    if (trace_node != 0) if (node.meta.per_frame.caches.commands.subtree_payload) |c| for (c.commands) |*it| if (it.header().node_id == trace_node) {
        std.debug.print("[trace] epoch={d} cache-write root={d} contains {d}\n", .{ cx.scene_runtime.frame_epoch, node.id, trace_node });
        break;
    };
}

fn prebuildSimpleDisplayPayloadSubtree(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    allow_subtree_payload_cache: bool,
) anyerror!void {
    const subtree_display_start = cx.display_list.items.items.len;
    const subtree_blob_start = cx.text_blob_store.blobs.items.len;
    markPrebuildVisited(cx, node.id);

    // R3c: appendNodeOwnContent still writes cx.lowering_buffer (effect_bridge path) but
    // entire cx.lowering_buffer tail derived clear+rewrite this frame, no need prebuild
    // truncate protect main buffer. display_list write output retained, it is prebuilt
    // payload.
    try appendNodeOwnContent(cx, node, exec_state);
    setNodeDisplayPayloadOwnPrebuilt(cx, node.id, true);

    // Scroll container's pixel clip pair must record into prebuilt payload (encloses
    // children), else subtree replay / splice hits frame-zero clipping, see
    // prebuildScrollClipBegin.
    const scroll_clip_on = try prebuildScrollClipBegin(cx, node, exec_state);
    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) continue;
        // Downstream regression: clean sibling subtree cross-frame payload hit -> splice
        // directly, avoid re-record.
        if (allow_subtree_payload_cache and try trySpliceSubtreePayloadCache(cx, child, exec_state.subtree_force_linear_text)) continue;
        // prebuild phase doesn't pass parent_clip to children, avoid viewport culling
        // causing cached display payload missing culled child content. display payload reused
        // cross-frame, but clip area changes with scrolling.
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            null,
            exec_state.subtree_force_linear_text,
        ) orelse continue;
        try prebuildSimpleDisplayPayloadSubtree(cx, child, &child_exec_state, allow_subtree_payload_cache);
    }
    try prebuildScrollClipEnd(cx, exec_state, scroll_clip_on);

    try appendNodeOverflowFade(cx, node, exec_state);

    updateNodeSubtreeDisplayPayloadRanges(cx, node.id, subtree_display_start, subtree_blob_start);
    if (allow_subtree_payload_cache) {
        maybeWriteSubtreePayloadCache(cx, node, subtree_display_start, exec_state.subtree_force_linear_text);
    }
}

fn prebuildDisplayPayloadSubtrees(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    inherited_force_linear_text: bool,
    parent_effect_id: u32,
) !void {
    // Paint-order prefix invariant: if some earlier node left content for paint pass, all
    // painting later must likewise leave for paint pass fresh emit; prebuild here would put
    // "paint-later" items before "paint-earlier" fresh items (fresh only appends to tail).
    // scene_runtime cleared per-frame, default is not-prebuilt, return immediately.
    if (cx.display_payload_prefix_broken) return;
    markPrebuildVisited(cx, node.id);
    const crosses_cache_boundary = if (cx.render_cache_boundary_blocked) |blocked|
        blocked.contains(node.id)
    else
        true;
    // A boundary flag is intentionally outside the payload stamp. Evict before
    // the clean-runtime shortcut so a newly enabled descendant boundary cannot
    // inherit last frame's "already prebuilt" state and bypass this pass.
    if (crosses_cache_boundary) dropSubtreePayloadCache(node);
    // Fast skip: node and subtree both clean with valid prebuild payload -> no rebuild
    // needed
    if (!crosses_cache_boundary and
        !node.frame_state.state_bits.dirty.core.render and
        !node.frame_state.state_bits.dirty.core.subtree_render)
    {
        if (cx.scene_runtime.getPtr(node.id)) |runtime| {
            if (runtime.display_payload_subtree_prebuilt) return;
        }
    }
    // Downstream regression: clean subtree cross-frame payload hit -> entire subtree
    // avoids re-record (includes both own/subtree prebuild passes, subtree_prebuilt=true
    // shortcuts both own and paint passes).
    if (try trySpliceSubtreePayloadCache(cx, node, inherited_force_linear_text)) return;
    setNodeDisplayPayloadSubtreePrebuilt(cx, node.id, false, .none);
    const exec_state = buildNodeExecutionState(
        cx,
        node,
        parent_transform,
        parent_clip,
        inherited_force_linear_text,
    ) orelse return;

    // Overlay candidates (z_index>0) with before_render hooks (Popover/Menu/Dropdown content) are
    // relocated by the hook every frame (setPopoverTranslate). Cross-frame prebuild payload bakes
    // the **first prebuild** transform (a just-opened float has translate=0 -> content at (0,0)),
    // later replayed at the old position -> content lingers at screen top-left. These nodes are
    // excluded from the cross-frame payload cache and forced through the paint pass each frame,
    // with the real world transform, aligned with hook positioning.
    //
    // NOTE: composited_group surface owners (Modal/Sheet) are **not** excluded: their subtree
    // payload must prebuild normally, else promoted-surface cache assembly
    // (node_cache_finalize.assembleCacheCommands) gets no regular_children and the settle frame
    // keeps only the dialog itself (white box), losing title/x/body.
    if (beforeRenderHookBreaksPrefix(node, &exec_state, parent_effect_id)) {
        // Content left for the paint pass -> prefix stops here (invariant: see prefix_broken
        // declaration). Not limited to overlay candidates: any before_render hook (drag spring
        // writes
        // translate, scrollbar fade, etc.) changes this subtree's transform/content per frame, and
        // prebuild descent bakes the **state before the hook runs this frame**. If the paint side
        // then fresh-emits the same subtree you get a "half-prebuilt half-fresh" double emit (e.g.
        // glass+specularity composed twice and washed out on the settle frame, once on scroll
        // frames).
        // Exception: custom-draw nodes (Spinner/Progress): the hook only advances animation params
        // and
        // own content replays via display payload, re-projected by this frame's transform, which is
        // safe (anchored by unit test display_list_own_replay_count); keep the original prebuild
        // path.
        cx.display_payload_prefix_broken = true;
        return; // Keep subtree_prebuilt=false -> paint pass fresh emit
    }

    if (subtreeCanUseDisplayListPrepassWithSelfScale(cx, node, &exec_state, parent_effect_id)) {
        try prebuildSimpleDisplayPayloadSubtree(cx, node, &exec_state, false);
        setNodeDisplayPayloadSubtreePrebuilt(cx, node.id, true, .self_scale);
        cx.perf.display_list_subtree_prebuild_count += 1;
        return;
    }
    if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, node, &exec_state, parent_effect_id)) {
        try prebuildSimpleDisplayPayloadSubtree(cx, node, &exec_state, false);
        setNodeDisplayPayloadSubtreePrebuilt(cx, node.id, true, .self_blur);
        cx.perf.display_list_subtree_prebuild_count += 1;
        return;
    }
    if (subtreeCanUseDisplayListPrepass(cx, node, &exec_state, parent_effect_id)) {
        if (!shouldPreferDisplayListPrepassChildren(cx, node, &exec_state)) {
            const strategy: scene_runtime_mod.DisplayPayloadSubtreeStrategy =
                if (canUseSafeSelfEffectDisplayPayload(cx, node, &exec_state, parent_effect_id))
                    .self_safe_effect
                else
                    .simple;
            // Cross-frame payload cache conservative version covers only .simple strategy (no
            // self-effect spatial transform, splice semantics identical to fresh emit).
            try prebuildSimpleDisplayPayloadSubtree(cx, node, &exec_state, strategy == .simple);
            setNodeDisplayPayloadSubtreePrebuilt(
                cx,
                node.id,
                true,
                strategy,
            );
            cx.perf.display_list_subtree_prebuild_count += 1;
            return;
        }
    }

    // Stage B S5.2 ordering fix: emit own content before recurse children, let
    // display_list order match paint pass walk (own -> children). Else
    // prebuildOwnDisplayPayloads pass defers root own to after all children subtree write,
    // causes PERMUTATION visual chaos (parent covers children).
    //
    // What this node leaves in the prefix (own content, children, clip pair) is its subtree
    // range: the paint pass visits the node without appending these items again, and an
    // ancestor assembling a cross-frame cache takes the node's items from this range
    // (finishNodeSubtreeDisplayPayloadRanges).
    const subtree_display_start = cx.display_list.items.items.len;
    const subtree_blob_start = cx.text_blob_store.blobs.items.len;
    defer updateNodeSubtreeDisplayPayloadRanges(cx, node.id, subtree_display_start, subtree_blob_start);
    setNodeDisplayPayloadOwnPrebuilt(cx, node.id, false);
    const own_prebuilt = try prebuildOwnDisplayPayloadForNode(cx, node, &exec_state, parent_effect_id);
    if (debug_prepass) {
        std.debug.print("[prepass] node={d} fallback own_prebuilt={} has_own={} children={d}\n", .{ node.id, own_prebuilt, nodeHasOwnPaintContent(node, &exec_state), node.children.items.len });
    }

    // Paint-order invariant: display_list raw order == paint order (own -> children). If own
    // content exists but **can't** prebuild early (typically is_promoted_layer surface owner,
    // canRepresentOwnContentInDisplayList=false), children can't prebuild either; otherwise
    // children land first, own is appended to the tail by the paint pass, and derive after the
    // parent background covers the whole subtree (blank Modal panel on the settle frame). The
    // whole subtree is left for the paint pass to fresh-emit in correct order; renderNodeTransform
    // backfills subtree ranges, and promoted cache assembly still gets children items.
    if (!own_prebuilt and nodeHasOwnPaintContent(node, &exec_state)) {
        // own (typical: rotate/scale transform, promoted surface owner) only by paint pass
        // fresh emit -> prefix stops here
        cx.display_payload_prefix_broken = true;
        return; // subtree_prebuilt=false → paint pass fresh emit
    }

    // A legacy overflow cache hit appends its descendants during the paint
    // pass. Leave them out of the prebuild prefix, otherwise the same child
    // commands are emitted once here and once by the cache replay. Later
    // siblings must also wait so paint order remains a contiguous prefix.
    if (node.meta.per_frame.caches.commands.own != null and
        buildNodeExecutionPlan(cx, node, &exec_state, parent_effect_id).should_try_legacy_overflow_replay)
    {
        cx.display_payload_prefix_broken = true;
        return;
    }

    // Scroll container children's clip pair also must record into fallback path
    // display_list section (paint pass may still take replay shortcut for locally prebuilt
    // descendants), see prebuildScrollClipBegin.
    const scroll_clip_on = try prebuildScrollClipBegin(cx, node, &exec_state);
    for (childPasses(exec_state.use_opacity_layer)) |pass| {
        for (node.children.items) |child| {
            if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
            try prebuildDisplayPayloadSubtrees(
                cx,
                child,
                exec_state.content_transform,
                exec_state.effective_clip,
                exec_state.subtree_force_linear_text,
                exec_state.retained_ids.effect_id,
            );
        }
    }
    try prebuildScrollClipEnd(cx, &exec_state, scroll_clip_on);

    // Align with the simple subtree path: the fall-through also emits overflow_fade to
    // display_list; cx.lowering_buffer derive covers it entirely, so no truncate or paint pass
    // write is needed. Prefix invariant: if any child subtree in the loop left content for the
    // paint pass, the fade (paint order after children) must also be left for the paint pass
    // (appendNodeOverflowFade supplies it), else it gets covered by fresh children.
    if (!cx.display_payload_prefix_broken) {
        try appendNodeOverflowFade(cx, node, &exec_state);
    }
}

/// Whether node itself has visible paint content (excludes subtree). Used for
/// paint-order invariant check: when own has content but can't prebuild early, children
/// can't land display_list first.
fn nodeHasOwnPaintContent(node: *Node, exec_state: *const NodeExecutionState) bool {
    const flags = exec_state.retained_runtime.content_flags;
    return flags.has_background or flags.has_border or flags.has_shadow or
        flags.has_image or flags.has_icon or flags.has_custom_draw or node.getText() != null;
}

/// Single node own prebuild, emit own content to display_list. Called by
/// prebuildDisplayPayloadSubtrees before recursing children on non-simple path, let
/// display_list order match paint pass walk (own -> children). Return whether successfully
/// prebuilt own.
fn prebuildOwnDisplayPayloadForNode(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    parent_effect_id: u32,
) !bool {
    if (!canRepresentOwnContentInDisplayList(cx, node, exec_state, parent_effect_id)) return false;
    const display_start = cx.display_list.items.items.len;
    const blob_start = cx.text_blob_store.blobs.items.len;
    try appendNodeOwnContent(cx, node, exec_state);
    setNodeDisplayPayloadOwnPrebuilt(cx, node.id, true);
    if (cx.display_list.items.items.len > display_start or cx.text_blob_store.blobs.items.len > blob_start) {
        cx.perf.display_list_own_prebuild_count += 1;
    }
    return true;
}

fn prebuildOwnDisplayPayloads(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    inherited_force_linear_text: bool,
    parent_effect_id: u32,
) !void {
    // Prefix invariant (same as prebuildDisplayPayloadSubtrees entry): own pass runs after
    // subtree pass, appends to tail, prefix once broken own recorded here sorts before
    // post-break fresh content, same mispaint. Pre-break nodes either entire subtree prebuilt
    // (skip at function start) or own already landed in subtree pass (epoch check skip),
    // global bail misses no legitimate work.
    if (cx.display_payload_prefix_broken) return;
    const runtime = cx.scene_runtime.getPtr(node.id) orelse return;
    if (runtime.display_payload_subtree_prebuilt) return;

    const exec_state = buildNodeExecutionState(
        cx,
        node,
        parent_transform,
        parent_clip,
        inherited_force_linear_text,
    ) orelse return;

    // Stage B S5.2: if prebuildDisplayPayloadSubtrees already handled this node own
    // before recursing children (display_payload_own_prebuilt=true this frame), skip, avoid
    // duplicate emit. display_list ordering maintained by subtree pass (own written before
    // children).
    if (runtime.display_payload_own_prebuilt and
        runtime.display_payload_own_prebuilt_epoch == cx.scene_runtime.frame_epoch)
    {
        // Already prebuilt by subtree pass, only recurse children
    } else {
        setNodeDisplayPayloadOwnPrebuilt(cx, node.id, false);
        const own_prebuilt = try prebuildOwnDisplayPayloadForNode(cx, node, &exec_state, parent_effect_id);
        // Paint-order invariant (same as prebuildDisplayPayloadSubtrees): own has visible
        // content but can't prebuild early -> children can't land display_list first, entire
        // subtree left for paint pass fresh emit (else parent background covers children after
        // derive).
        if (!own_prebuilt and nodeHasOwnPaintContent(node, &exec_state)) return;
    }

    for (childPasses(exec_state.use_opacity_layer)) |pass| {
        for (node.children.items) |child| {
            if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
            try prebuildOwnDisplayPayloads(
                cx,
                child,
                exec_state.content_transform,
                exec_state.effective_clip,
                exec_state.subtree_force_linear_text,
                exec_state.retained_ids.effect_id,
            );
        }
    }
}

// -- Display payload prebuild --

fn prebuildDisplayPayloads(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    inherited_force_linear_text: bool,
    parent_effect_id: u32,
) !void {
    try prebuildDisplayPayloadSubtrees(
        cx,
        node,
        parent_transform,
        parent_clip,
        inherited_force_linear_text,
        parent_effect_id,
    );
    try prebuildOwnDisplayPayloads(
        cx,
        node,
        parent_transform,
        parent_clip,
        inherited_force_linear_text,
        parent_effect_id,
    );
}

/// Tests: force the paint-cursor resume on/off regardless of ZENIT_DISABLE_PAINT_RESUME.
pub var paint_resume_test_override: ?bool = null;

/// Paint-cursor prebuild resume.
///
/// The prebuild pass stops at the first node whose content must stay with the paint pass
/// (`display_payload_prefix_broken`); before this, every node painted after it lost the
/// cross-frame subtree payload cache (neither splice nor write), so one ScrollArea early in
/// paint order re-recorded the whole window each frame.
///
/// Once the prefix is broken, the paint pass appends every remaining item to the display list
/// tail in paint order, so the tail *is* the paint position of the node being visited. A simple
/// subtree that the prebuild pass never reached can therefore be prebuilt right there, with the
/// exact routine and inputs the prebuild pass would have used (same parent transform / clip /
/// effect scope; descendants unclipped), and is then consumed by the ordinary subtree replay
/// shortcut. That restores both splice of clean cached subtrees and cache writes for the rest.
///
/// Guards:
/// - `prebuild_visited`: the prebuild pass (or an earlier resume) already handled this node, so
///   any prebuilt content of it is already in the list (no double emission).
/// - `paint_resume_suppress_depth`: inside an undeclared hook's subtree (hook-owned, may be
///   written without dirty marking), or inside a subtree prebuilt this frame whose fresh paint
///   output is truncated afterwards.
/// - Only the `.simple` strategy is resumed (the only cacheable one); self_scale / self_blur /
///   self_safe_effect subtrees and fallback (partially prebuildable) nodes keep the plain paint
///   path, and their children are offered the resume in turn.
const ResumeOutcome = enum { none, spliced, prebuilt };

fn tryResumePrebuildAtPaintCursor(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    inherited_force_linear_text: bool,
    parent_effect_id: u32,
) !ResumeOutcome {
    if (!cx.display_payload_prefix_broken) return .none;
    if (!cx.paint_resume_enabled or cx.subtree_payload_reference_mode) return .none;
    if (cx.paint_resume_suppress_depth != 0) return .none;
    {
        const rt = cx.scene_runtime.nodes.getPtr(node.id) orelse return .none;
        if (rt.prebuild_visited) return .none;
        rt.prebuild_visited = true;
    }
    const crosses_cache_boundary = if (cx.render_cache_boundary_blocked) |blocked|
        blocked.contains(node.id)
    else
        true;
    if (crosses_cache_boundary) dropSubtreePayloadCache(node);
    if (try trySpliceSubtreePayloadCache(cx, node, inherited_force_linear_text)) {
        cx.perf.subtree_payload_paint_resume_count += 1;
        return .spliced;
    }
    if (!node.beforeRenderHooksCacheTrusted()) return .none;
    // O(1) copies of the first rejects of shouldUseDisplayListForSimpleSubtree. Without them a
    // node whose subtree holds a hook / custom draw re-runs the recursive prepass check, and so
    // does each child the paint pass then visits: quadratic in depth on the common failure.
    if (node.children.items.len == 0) return .none;
    const flags = node.frame_state.state_bits.flags;
    if (flags.has_custom_draw_subtree or hasUntrustedBeforeRenderHookSubtree(node)) return .none;
    if (node.tag == .scroll or node.tag == .input) return .none;
    const exec_state = buildNodeExecutionState(
        cx,
        node,
        parent_transform,
        parent_clip,
        inherited_force_linear_text,
    ) orelse return .none;
    // Same precedence as prebuildDisplayPayloadSubtrees: a subtree the prebuild pass would
    // record with a self-effect strategy is left to the paint pass rather than recorded as
    // `.simple` with different semantics.
    if (subtreeCanUseDisplayListPrepassWithSelfScale(cx, node, &exec_state, parent_effect_id)) return .none;
    if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, node, &exec_state, parent_effect_id)) return .none;
    if (!subtreeCanUseDisplayListPrepass(cx, node, &exec_state, parent_effect_id)) return .none;
    if (shouldPreferDisplayListPrepassChildren(cx, node, &exec_state)) return .none;
    if (canUseSafeSelfEffectDisplayPayload(cx, node, &exec_state, parent_effect_id)) return .none;

    try prebuildSimpleDisplayPayloadSubtree(cx, node, &exec_state, true);
    setNodeDisplayPayloadSubtreePrebuilt(cx, node.id, true, .simple);
    cx.perf.display_list_subtree_prebuild_count += 1;
    cx.perf.subtree_payload_paint_resume_count += 1;
    return .prebuilt;
}

// -- Node render state computation --

fn computeNodeRenderState(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
) ?NodeRenderState {
    const self_tx = node.style.translate_x;
    const self_ty = node.style.translate_y;
    const world_transform = geometry.nodeWorldTransform(parent_transform, node);
    // Read rect from World.LayoutTable.
    const local_rect = cx.rectFromWorld(node);
    const world_rect = world_transform.transformRect(ComputedRect.init(0, 0, local_rect.w, local_rect.h));
    const render_x = world_rect.x;
    const render_y = world_rect.y;
    const render_w = world_rect.w;
    const render_h = world_rect.h;
    const scale_x_abs = world_transform.extractScaleX();
    const scale_y_abs = world_transform.extractScaleY();
    const scale_min = @min(scale_x_abs, scale_y_abs);
    const clip_spec = clip_mod.resolveNodeRenderClipSpec(cx, node, cx.allocator, scale_min);
    var clip_world_rect = world_transform.transformRect(clip_spec.local_rect);
    var needs_clip = clip_spec.enabled;
    // External clip rectangle (viewport-frame side table): node declares "I'm clipped by
    // this rectangle" without parent-child with clip source (host scenario: canvas frame
    // and members are sibling Nodes). Intersect with own overflow clip; fully out-of-bounds
    // <0.1 below early-exit culls entire tree.
    if (cx.external_clip_rects) |ext_map| if (ext_map.get(node.id)) |ecr| {
        const ext = ComputedRect.init(ecr[0], ecr[1], ecr[2], ecr[3]);
        // Intersection empty = zero-size clip, take <0.1 below early-exit cull entire
        // subtree.
        clip_world_rect = if (needs_clip)
            (geometry.intersectRect(clip_world_rect, ext) orelse ComputedRect.init(ext.x, ext.y, 0, 0))
        else
            ext;
        needs_clip = true;
    };

    const blur_radius = effectiveBackdropBlurRadius(node);
    const pad_left = node.style.contentInsets().left * scale_x_abs;
    const pad_right = node.style.contentInsets().right * scale_x_abs;
    const pad_top = node.style.contentInsets().top * scale_y_abs;
    const pad_bottom = node.style.contentInsets().bottom * scale_y_abs;
    const node_opacity = std.math.clamp(node.getOpacity(), 0.0, 1.0);
    const has_rotation = @abs(node.style.rotate()) > 0.0001;
    const has_scale = @abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001;
    const prepromote_composite = node.style.z_index() > 0 and
        (node.style.will_change_transform() or node.style.will_change_opacity());
    const use_opacity_layer = computeUseOpacityLayer(node, has_rotation, has_scale, prepromote_composite, needs_clip, blur_radius, node_opacity);
    const opacity_bounds = if (use_opacity_layer)
        geometry.computeOpacityLayerBounds(node, world_transform, world_rect, scale_x_abs, scale_y_abs, scale_min)
    else
        world_rect;

    // opacity <= 0.001 unconditionally culls GPU draw, including the prewarm hidden copy
    // (HIDDEN_OPACITY=0.001). keep_rendering_when_transparent only decides **whether to stay in
    // tick/layout traversal** (see tick.zig: hidden subtree transitions advance, layout
    // measurement stays warm), **not** whether to emit paint. Wiring it into paint cull would let
    // the 0.001 prewarm copy leave faint GPU-blend residue at screen (0,0) (overlay prewarm
    // resets translate to 0). So 0.001 never draws; preheat goes only via tick/layout.
    if (node_opacity <= 0.001) return null;
    if (needs_clip and (clip_world_rect.w < 0.1 or clip_world_rect.h < 0.1)) return null;

    var effective_clip = parent_clip;
    if (needs_clip and clip_world_rect.w > 0 and clip_world_rect.h > 0) {
        const node_clip = clip_world_rect;
        effective_clip = if (effective_clip) |clip|
            geometry.intersectRect(clip, node_clip)
        else
            node_clip;
    }

    const has_translate = self_tx != 0 or self_ty != 0;
    if (render_w > 0 and render_h > 0 and !has_translate) {
        const margin: f32 = 48;
        if (effective_clip) |clip| {
            if (render_x + render_w < clip.x - margin or render_x > clip.x + clip.w + margin or
                render_y + render_h < clip.y - margin or render_y > clip.y + clip.h + margin)
            {
                return null;
            }
        } else {
            const vp_w = cx.viewport.width;
            const vp_h = cx.viewport.height;
            if (render_x + render_w < -margin or render_x > vp_w + margin or
                render_y + render_h < -margin or render_y > vp_h + margin)
            {
                return null;
            }
        }
    }

    const radii_raw = node.style.effectiveRadii();
    const radii = [4]f32{ radii_raw[0] * scale_min, radii_raw[1] * scale_min, radii_raw[2] * scale_min, radii_raw[3] * scale_min };
    const radius = @max(@max(radii[0], radii[1]), @max(radii[2], radii[3]));
    const use_rounded_clip = shouldUseRoundedClipBridge(node, clip_spec.shape_kind, clip_spec.radii, use_opacity_layer, blur_radius > 0);

    return .{
        .world_transform = world_transform,
        .world_rect = world_rect,
        .clip_world_rect = clip_world_rect,
        .effective_clip = effective_clip,
        .scale_x_abs = scale_x_abs,
        .scale_y_abs = scale_y_abs,
        .scale_min = scale_min,
        .pad_left = pad_left,
        .pad_right = pad_right,
        .pad_top = pad_top,
        .pad_bottom = pad_bottom,
        .node_opacity = node_opacity,
        .needs_clip = needs_clip,
        .blur_radius = blur_radius,
        .use_opacity_layer = use_opacity_layer,
        .opacity_bounds = opacity_bounds,
        .radii = radii,
        .radius = radius,
        .clip_shape_kind = clip_spec.shape_kind,
        .clip_radii = clip_spec.radii,
        .clip_polygon = clip_spec.polygon,
        .clip_bounds_fallback = clip_spec.bounds_fallback,
        .use_blur = blur_radius >= 0.5,
        .use_rounded_clip = use_rounded_clip,
    };
}

/// Single truth table: "does this node open offscreen opacity/composited surface".
/// Once duplicated in computeNodeRenderState / computeNodeContentRenderState, P6.3
/// converged to single point (first step of lifting judgment normalization).
fn computeUseOpacityLayer(
    node: *Node,
    has_rotation: bool,
    has_scale: bool,
    prepromote_composite: bool,
    needs_clip: bool,
    blur_radius: f32,
    node_opacity: f32,
) bool {
    return node.style.composited_group() or node.style.contentWarp() != null or
        // Non-normal blend must independently rasterize to src then W3C-blend with
        // background.
        node.style.blendMode() != .normal or
        (!geometry.canInlineLeafOpacity(node, has_rotation, has_scale, prepromote_composite, needs_clip, blur_radius) and node_opacity < 0.999) or
        has_rotation or has_scale or prepromote_composite;
}

fn computeNodeContentRenderState(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
) ?NodeContentRenderState {
    const self_tx = node.style.translate_x;
    const self_ty = node.style.translate_y;
    const has_rotation = @abs(node.style.rotate()) > 0.0001;
    const has_scale = @abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001;
    // After P6.3 content_transform semantics unique: surface unscaled render
    // (include_scale=false), scale uniformly applied by surface composite draw_transform. No
    // more inline_scale fork.
    const content_transform = retained_scene.buildNodeWorldTransform(node, parent_transform, .{
        .include_scale = false,
        .include_rotation = false,
    });
    // Read rect from World.LayoutTable.
    const local_rect = cx.rectFromWorld(node);
    const content_rect = content_transform.transformRect(ComputedRect.init(0, 0, local_rect.w, local_rect.h));
    const render_x = content_rect.x;
    const render_y = content_rect.y;
    const render_w = content_rect.w;
    const render_h = content_rect.h;
    const scale_x_abs = content_transform.extractScaleX();
    const scale_y_abs = content_transform.extractScaleY();
    const scale_min = @min(scale_x_abs, scale_y_abs);
    const clip_spec = clip_mod.resolveNodeRenderClipSpec(cx, node, cx.allocator, scale_min);
    var clip_content_rect = content_transform.transformRect(clip_spec.local_rect);
    var needs_clip = clip_spec.enabled;
    // External clip rectangle: same injection as computeNodeRenderState (see note
    // there). Rectangle is viewport-frame; host only annotates flat nodes without
    // scale/rotation, not inside effect surface, at which point content frame and world
    // frame coincide.
    if (cx.external_clip_rects) |ext_map| if (ext_map.get(node.id)) |ecr| {
        const ext = ComputedRect.init(ecr[0], ecr[1], ecr[2], ecr[3]);
        clip_content_rect = if (needs_clip)
            (geometry.intersectRect(clip_content_rect, ext) orelse ComputedRect.init(ext.x, ext.y, 0, 0))
        else
            ext;
        needs_clip = true;
    };

    const blur_radius = effectiveBackdropBlurRadius(node);
    const pad_left = node.style.contentInsets().left * scale_x_abs;
    const pad_right = node.style.contentInsets().right * scale_x_abs;
    const pad_top = node.style.contentInsets().top * scale_y_abs;
    const pad_bottom = node.style.contentInsets().bottom * scale_y_abs;
    const node_opacity = std.math.clamp(node.getOpacity(), 0.0, 1.0);
    const prepromote_composite = node.style.z_index() > 0 and
        (node.style.will_change_transform() or node.style.will_change_opacity());
    const use_opacity_layer = computeUseOpacityLayer(node, has_rotation, has_scale, prepromote_composite, needs_clip, blur_radius, node_opacity);
    const opacity_bounds = if (use_opacity_layer)
        geometry.computeOpacityLayerBounds(node, content_transform, content_rect, scale_x_abs, scale_y_abs, scale_min)
    else
        content_rect;

    // Same as computeNodeRenderState: 0.001 prewarm copy unconditionally not drawn
    // (see note above), keep_rendering_when_transparent only manages tick/layout preheat,
    // doesn't allow paint.
    if (node_opacity <= 0.001) return null;
    if (needs_clip and (clip_content_rect.w < 0.1 or clip_content_rect.h < 0.1)) return null;

    var effective_clip = parent_clip;
    if (needs_clip and clip_content_rect.w > 0 and clip_content_rect.h > 0) {
        const node_clip = clip_content_rect;
        effective_clip = if (effective_clip) |clip|
            geometry.intersectRect(clip, node_clip)
        else
            node_clip;
    }

    const has_translate = self_tx != 0 or self_ty != 0;
    if (render_w > 0 and render_h > 0 and !has_translate and !has_rotation) {
        const margin: f32 = 48;
        if (effective_clip) |clip| {
            if (render_x + render_w < clip.x - margin or render_x > clip.x + clip.w + margin or
                render_y + render_h < clip.y - margin or render_y > clip.y + clip.h + margin)
            {
                return null;
            }
        } else {
            const vp_w = cx.viewport.width;
            const vp_h = cx.viewport.height;
            if (render_x + render_w < -margin or render_x > vp_w + margin or
                render_y + render_h < -margin or render_y > vp_h + margin)
            {
                return null;
            }
        }
    }

    const radii_raw = node.style.effectiveRadii();
    const radii = [4]f32{ radii_raw[0] * scale_min, radii_raw[1] * scale_min, radii_raw[2] * scale_min, radii_raw[3] * scale_min };
    const radius = @max(@max(radii[0], radii[1]), @max(radii[2], radii[3]));
    const use_rounded_clip = shouldUseRoundedClipBridge(node, clip_spec.shape_kind, clip_spec.radii, use_opacity_layer, blur_radius > 0);

    return .{
        .content_transform = content_transform,
        .content_rect = content_rect,
        .clip_content_rect = clip_content_rect,
        .effective_clip = effective_clip,
        .scale_x_abs = scale_x_abs,
        .scale_y_abs = scale_y_abs,
        .scale_min = scale_min,
        .pad_left = pad_left,
        .pad_right = pad_right,
        .pad_top = pad_top,
        .pad_bottom = pad_bottom,
        .node_opacity = node_opacity,
        .needs_clip = needs_clip,
        .blur_radius = blur_radius,
        .use_opacity_layer = use_opacity_layer,
        .opacity_bounds = opacity_bounds,
        .radii = radii,
        .radius = radius,
        .clip_shape_kind = clip_spec.shape_kind,
        .clip_radii = clip_spec.radii,
        .clip_polygon = clip_spec.polygon,
        .clip_bounds_fallback = clip_spec.bounds_fallback,
        .use_blur = blur_radius >= 0.5,
        .use_rounded_clip = use_rounded_clip,
    };
}

fn shouldUseRoundedClipBridge(node: *Node, clip_shape_kind: display_list_mod.ClipShapeKind, radii: [4]f32, use_opacity_layer: bool, use_blur: bool) bool {
    if (clip_shape_kind != .rounded_rect) return false;
    // Any rounded corner needs the mask (attached group items round only their outer corners).
    if (@max(@max(radii[0], radii[1]), @max(radii[2], radii[3])) <= 0.5) return false;
    if (node.frame_state.state_bits.flags.manual_opacity_animation_active or node.frame_state.state_bits.flags.manual_transform_animation_active) return false;
    if (use_blur) return true;
    // rounded_clip effect (and the Stage 3 fold into the opacity layer rounded mask) is
    // **node-level**: the owner's own shadow / background / border and descendants are clipped
    // by the same mask, so the shadow keeps only the border-box part (Popover rectangle gray
    // outside the radius) and stroke/edge content shares the layer and gets covered by content.
    // When the owner has such content, switch to a children-enclosing node-local push_clip
    // (shader SDF radius, emitScrollClipBegin) that clips descendants only.
    if (clip_mod.ownerPaintsOutsideChildClip(node)) return false;
    if (use_opacity_layer) return true;
    // Conservative: z>0 creates a rounded_clip effect only during animation/will_change (keeps
    // the shouldPromoteLayer surface promote vehicle). Static z>0 rounded containers use
    // ClipNode -> push_clip fallback (shader SDF clip), saving an effect node, plan layer and
    // two display items. The will_change case is actually absorbed by prepromote_composite ->
    // use_opacity_layer; kept here defensively.
    const anim_checks = @import("animation_checks.zig");
    return node.style.z_index() > 0 and
        (anim_checks.hasActiveCompositeAnimation(node) or
            node.style.will_change_transform() or
            node.style.will_change_opacity());
}

// -- Property tree construction --

fn buildRetainedSubtree(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    parent_transform_id: u32,
    parent_clip_id: u32,
    parent_effect_id: u32,
    surface_inverse: Transform2D,
) retained_memo.BuildSummary {
    if (!node.frame_state.state_bits.dirty.core.render and !node.frame_state.state_bits.dirty.core.subtree_render and !node.frame_state.state_bits.dirty.core.layout and !node.frame_state.state_bits.dirty.core.subtree_layout) {
        if (cx.scene_runtime.nodes.contains(node.id)) return .{};
    }
    const memo_inputs: retained_memo.Inputs = .{
        .parent_transform = parent_transform,
        .parent_clip = parent_clip,
        .parent_transform_id = parent_transform_id,
        .parent_clip_id = parent_clip_id,
        .parent_effect_id = parent_effect_id,
        .surface_inverse = surface_inverse,
    };
    const memo_on = cx.retained_memo_enabled and !cx.subtree_payload_reference_mode;
    if (memo_on and cx.retained_hook_owned_depth == 0 and node.meta.per_frame.caches.commands.retained_memo != null) {
        if (retained_memo.tryReplay(cx, node, memo_inputs)) |_| {
            const memo = retained_memo.memoOf(node).?;
            // A replayed subtree is clean and complete: an enclosing memo may include it.
            return .{ .memoizable = true, .has_capture_owner = memo.has_capture_owner, .has_culled = memo.has_culled, .replayed = true };
        }
    }
    // An undeclared hook may write its descendants raw (hook-owned subtree, like the paint pass):
    // nothing below it is memoizable on its own either.
    const hook_owned_here = node.hasBeforeRenderHooks() and !node.beforeRenderHooksCacheTrusted();
    if (hook_owned_here) cx.retained_hook_owned_depth += 1;
    defer if (hook_owned_here) {
        cx.retained_hook_owned_depth -= 1;
    };
    var summary: retained_memo.BuildSummary = .{
        .memoizable = memo_on and cx.retained_hook_owned_depth == 0 and
            retained_memo.subtreeClean(node) and !retained_memo.nodeVolatile(node),
    };
    const render_state = computeNodeRenderState(cx, node, parent_transform, parent_clip) orelse
        return .{ .memoizable = summary.memoizable, .has_culled = true };
    // Retained/property-tree recursion must follow the same content-space transform
    // chain as runtime rendering. For opacity/composited groups, descendants render
    // into the group's unscaled/unrotated surface space; recursing with world_transform
    // here makes retained metadata disagree with the render path and causes promoted
    // surfaces to mix "panel frame" animation with "content relayout" jumps.
    const content_state = computeNodeContentRenderState(cx, node, parent_transform, parent_clip) orelse
        return .{ .memoizable = false };

    // Surface owner's content transform: whether to fold self.world.invert() depends on whether
    // surface composite **re-applies** the owner's world transform (must align with
    // layer_tree.has_surface_transform).
    //
    // - has_surface_transform (owner with scale / rotation / non-axis-aligned): the surface is
    //   composited back via draw_transform **with the owner transform**, so surface content must
    //   first be surface-local (owner world stripped), else scale/rotate applies twice.
    //   surface_inverse = self.world.invert() (scale text stays sharp, composite-time scaling).
    //   This is the scale_fade **animation period**.
    //
    // - pure translate / axis-aligned (typical overlay: popover/menu/tooltip with
    //   translate=(dx,dy),
    //   scale=1, no rotate; settled centered dialog): the surface is one axis-aligned blit and
    //   composite **doesn't** re-apply translate. The GPU encoder's offscreenOffset = -(surface
    //   bounds origin) already converts surface-internal world coords to surface-local (see
    //   command_encoder.offscreenOffset / opacity_layer.beginOpacityLayer; the clip bridge likewise
    //   uses world_aabb). Content must emit in **world coords**, so surface_inverse stays identity
    //   (inherit parent). Using self.world.invert() here makes content owner-relative while the
    //   encoder subtracts the surface bounds origin (with shadow margin): mismatch, and the whole
    //   panel flies to screen (0,0).
    //
    // The sole criterion for the content frame is "does this node open a **content-capture**
    // offscreen surface", not "does it open an opacity layer":
    //  - use_opacity_layer (opacity/composited_group/blend/scale/rotate) -> capture.
    //  - use_rounded_clip -> a promoted rounded_clip effect is always layer mode in the encoder
    //    (begin token has use_draw_transform; layer_tree has_surface_transform is always true),
    //    so it also captures content into an owner-local texture. Missing this branch draws
    //    "blur+rounded_clip same node" glass island content in world coords into an owner-local
    //    texture (offset out of the texture), leaving only the shell.
    //  - use_blur alone (no clip) -> applyBackdropBlur composes instantly, opens no capture
    //    scope; content must stay in the world frame (self_blur replay, same contract), so it
    //    doesn't enter this branch.
    const opens_capture_surface = render_state.use_opacity_layer or render_state.use_rounded_clip;
    if (opens_capture_surface) summary.has_capture_owner = true;
    const self_surface_inverse: Transform2D = if (opens_capture_surface)
        render_state.world_transform.invert()
    else
        surface_inverse;
    // Children's coordinate chain (content_transform) **excludes** the owner's animation
    // scale/rotate (unscaled rest frame), so children's surface_inverse must be the unscaled
    // inverse. Then children's content in the texture is **static** owner-local and scale is
    // applied uniformly by M_composite. A full inverse with scale would reverse-scale children
    // and composite's scale would cancel it ("modal background scales, content doesn't budge").
    // own (self) still uses the full inverse: own world includes scale, so the full inverse makes
    // own content pure local, the same frame as children.
    const surface_child_inverse: Transform2D = if (opens_capture_surface)
        content_state.content_transform.invert()
    else
        surface_inverse;

    const retained_ids = appendRetainedMetadata(
        cx,
        node,
        parent_transform,
        parent_transform_id,
        parent_clip_id,
        parent_effect_id,
        render_state,
        self_surface_inverse,
    );
    rememberContentState(cx, node, parent_transform, parent_clip, &content_state);
    const child_parent_transform = content_state.content_transform;
    const effective_clip = content_state.effective_clip;

    const child_surface_inverse = surface_child_inverse;

    // Memoizable children are recorded here when this node is not (the frontier of clean
    // subtrees); otherwise this node's own record covers them.
    var child_marks: std.ArrayList(ChildMemoMark) = .empty;
    for (childPasses(render_state.use_opacity_layer)) |pass| {
        for (node.children.items) |child| {
            if (!shouldRenderChildInPass(child, render_state.use_opacity_layer, pass)) continue;
            const mark: ChildMemoMark = .{
                .child = child,
                .t0 = cx.property_tree.transforms.items.len,
                .c0 = cx.property_tree.clips.items.len,
                .e0 = cx.property_tree.effects.items.len,
                .o0 = cx.retained_nodes.items.len,
                .inputs = .{
                    .parent_transform = child_parent_transform,
                    .parent_clip = effective_clip,
                    .parent_transform_id = retained_ids.transform_id,
                    .parent_clip_id = retained_ids.clip_id,
                    .parent_effect_id = retained_ids.effect_id,
                    .surface_inverse = child_surface_inverse,
                },
            };
            const child_summary = buildRetainedSubtree(
                cx,
                child,
                child_parent_transform,
                effective_clip,
                retained_ids.transform_id,
                retained_ids.clip_id,
                retained_ids.effect_id,
                child_surface_inverse,
            );
            if (!child_summary.memoizable) summary.memoizable = false;
            if (child_summary.has_capture_owner) summary.has_capture_owner = true;
            if (child_summary.has_culled) summary.has_culled = true;
            if (memo_on and child_summary.memoizable and !child_summary.replayed and cx.retained_nodes.items.len > mark.o0) {
                var m = mark;
                m.summary = child_summary;
                m.range = .{
                    .t1 = cx.property_tree.transforms.items.len,
                    .c1 = cx.property_tree.clips.items.len,
                    .e1 = cx.property_tree.effects.items.len,
                    .o1 = cx.retained_nodes.items.len,
                };
                child_marks.append(cx.frame_allocator, m) catch {};
            }
        }
    }
    if (memo_on and !summary.memoizable) {
        for (child_marks.items) |m| {
            retained_memo.record(cx, m.child, m.inputs, .{ .t0 = m.t0, .c0 = m.c0, .e0 = m.e0, .o0 = m.o0, .t1 = m.range.t1, .c1 = m.range.c1, .e1 = m.range.e1, .o1 = m.range.o1 }, m.summary);
        }
    }
    return summary;
}

const ChildMemoMark = struct {
    child: *Node,
    t0: usize,
    c0: usize,
    e0: usize,
    o0: usize,
    inputs: retained_memo.Inputs,
    summary: retained_memo.BuildSummary = .{},
    range: struct { t1: usize = 0, c1: usize = 0, e1: usize = 0, o1: usize = 0 } = .{},
};

/// The root of the frame records its own memo when it is memoizable (nothing above it would).
fn recordRootRetainedMemo(cx: *RenderContext, node: *Node, summary: retained_memo.BuildSummary) void {
    if (!summary.memoizable or !cx.retained_memo_enabled or cx.subtree_payload_reference_mode) return;
    if (summary.replayed) return; // already current
    retained_memo.record(cx, node, .{
        .parent_transform = Transform2D.identity(),
        .parent_clip = null,
        .parent_transform_id = 0,
        .parent_clip_id = INVALID_ID,
        .parent_effect_id = INVALID_ID,
        .surface_inverse = Transform2D.identity(),
    }, .{
        .t0 = 1,
        .c0 = 0,
        .e0 = 0,
        .o0 = 0,
        .t1 = cx.property_tree.transforms.items.len,
        .c1 = cx.property_tree.clips.items.len,
        .e1 = cx.property_tree.effects.items.len,
        .o1 = cx.retained_nodes.items.len,
    }, summary);
}

fn rememberContentState(cx: *RenderContext, node: *Node, parent_transform: Transform2D, parent_clip: ?ComputedRect, state: *const NodeContentRenderState) void {
    const rt = cx.scene_runtime.getPtr(node.id) orelse return;
    const idx = rt.retained_index;
    if (idx >= cx.retained_nodes.items.len) return;
    const states = &cx.content_states;
    if (states.items.len <= idx) {
        states.appendNTimes(cx.frame_allocator, .{}, idx + 1 - states.items.len) catch return;
    }
    states.items[idx] = .{ .valid = true, .parent_transform = parent_transform, .parent_clip = parent_clip, .state = state.* };
}

/// The content state buildRetainedSubtree computed for these inputs this frame (pure function of
/// node state and inputs), or a fresh one.
fn contentStateFor(cx: *RenderContext, node: *Node, retained_index: u32, parent_transform: Transform2D, parent_clip: ?ComputedRect) ?NodeContentRenderState {
    if (retained_index < cx.content_states.items.len) {
        const e = &cx.content_states.items[retained_index];
        if (e.valid and std.meta.eql(e.parent_transform, parent_transform) and std.meta.eql(e.parent_clip, parent_clip)) {
            cx.perf.content_state_reuses += 1;
            return e.state;
        }
    }
    return computeNodeContentRenderState(cx, node, parent_transform, parent_clip);
}

fn syncPromotedLayerIds(cx: *RenderContext) void {
    // Only plan-layer roots differ from the defaults every record starts with (no promoted
    // layer, all frame flags clear): visit those instead of every scene record.
    var roots = cx.layer_tree.frame_root_chains.keyIterator();
    while (roots.next()) |root_id| {
        const entry_value = cx.scene_runtime.nodes.getPtr(root_id.*) orelse continue;
        const entry = .{ .value_ptr = entry_value };
        const root_layer_state = cx.layer_tree.planQueryRootNode(root_id.*);
        entry.value_ptr.promoted_layer_id = root_layer_state.promoted_layer_id;
        entry.value_ptr.promoted_surface_flags.surface_valid = root_layer_state.frame_flags.surface_valid;
        entry.value_ptr.promoted_surface_flags.reused_this_frame = root_layer_state.frame_flags.reused_this_frame;
        entry.value_ptr.promoted_surface_flags.rebuilt_this_frame = root_layer_state.frame_flags.rebuilt_this_frame;
        entry.value_ptr.promoted_surface_flags.invalidated_by_descendant_this_frame = root_layer_state.frame_flags.invalidated_by_descendant_this_frame;
        entry.value_ptr.promoted_surface_flags.invalidated_by_self_this_frame = root_layer_state.frame_flags.invalidated_by_self_this_frame;
        entry.value_ptr.promoted_surface_flags.descendant_scoped_rebuild_candidate_this_frame = root_layer_state.frame_flags.descendant_scoped_rebuild_candidate_this_frame;
    }
}

/// has_promoted_descendant_subtree: true exactly on the ancestors of promoted layer roots
/// (records start false). Walks up from the promoted roots instead of over the whole tree.
fn syncPromotedDescendantState(cx: *RenderContext, node: *Node) bool {
    _ = node;
    var any = false;
    var roots = cx.layer_tree.frame_root_chains.keyIterator();
    while (roots.next()) |root_id| {
        const rt = cx.scene_runtime.getPtr(root_id.*) orelse continue;
        if (rt.promoted_layer_id == INVALID_ID) continue;
        if (rt.retained_index >= cx.retained_nodes.items.len) continue;
        const n = cx.retained_nodes.items[rt.retained_index];
        std.debug.assert(n.id == root_id.*);
        any = true;
        var cur = n.parent;
        while (cur) |p| : (cur = p.parent) {
            const prt = cx.scene_runtime.nodes.getPtr(p.id) orelse continue;
            if (prt.has_promoted_descendant_subtree) break;
            prt.has_promoted_descendant_subtree = true;
        }
    }
    return any;
}

fn buildNodeExecutionState(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    inherited_force_linear_text: bool,
) ?NodeExecutionState {
    const retained_runtime = cx.scene_runtime.get(node.id) orelse return null;
    const retained_ids = RetainedIds{
        .transform_id = retained_runtime.transform_id,
        .clip_id = retained_runtime.clip_id,
        .effect_id = retained_runtime.effect_id,
    };
    const content_state = contentStateFor(cx, node, retained_runtime.retained_index, parent_transform, parent_clip) orelse return null;
    const world_transform = if (retained_ids.transform_id < cx.property_tree.transforms.items.len)
        cx.property_tree.transforms.items[retained_ids.transform_id].world
    else
        Transform2D.identity();
    const world_origin = world_transform.applyPoint(0, 0);
    const world_rect = retained_runtime.world_bounds;
    const plan_state = cx.layer_tree.planQueryNode(
        node.id,
        retained_ids.effect_id,
        content_state.needs_clip,
        content_state.use_rounded_clip,
        retained_runtime.clip_bounds_fallback,
    );
    const promoted_layer_id = plan_state.promoted_layer_id;
    const is_promoted_layer = promoted_layer_id != scene_runtime_mod.INVALID_ID;
    // Text under a transform animation leaves the static raster (per-glyph device-pixel snap)
    // because the animation moves it across the pixel grid. A node that captures its content
    // into a surface is the exception for its own scale/rotate and anchored (overlay) motion:
    // the composite applies those, the texture-local frame is anchored at the rest pose
    // (opacity_layer.alignTranslationSurface), so the content stays on one grid for the whole
    // animation and keeps the exact raster it has at rest. Switching it to the animated raster
    // made every glyph jump on its own the frame the animation ended.
    // Nor does the composite linger after an animation ends: the surface is gone (scale and
    // opacity are back to 1) and the content is at rest, so the animated raster there swapped
    // every glyph's raster for the last frames and back (layout stays put; see
    // FontSelector.resolveFonts, but snap vs. linear placement still shows).
    const opens_capture_surface = content_state.use_opacity_layer or content_state.use_rounded_clip;
    const own_motion_moves_content = if (opens_capture_surface)
        animation_checks.hasUnanchoredTransformAnimation(node)
    else
        animation_checks.hasMovingTransformAnimation(node);
    const auto_stabilize_text = own_motion_moves_content and retained_runtime.content_flags.has_text;

    return .{
        .retained_runtime = retained_runtime,
        .retained_ids = retained_ids,
        .content_state = content_state,
        .plan_state = plan_state,
        .world_transform = world_transform,
        .world_origin = world_origin,
        .world_rect = world_rect,
        .clip_rect = content_state.clip_content_rect,
        .content_transform = content_state.content_transform,
        .render_x = content_state.content_rect.x,
        .render_y = content_state.content_rect.y,
        .render_w = content_state.content_rect.w,
        .render_h = content_state.content_rect.h,
        .needs_clip = content_state.needs_clip,
        .scale_x_abs = content_state.scale_x_abs,
        .scale_y_abs = content_state.scale_y_abs,
        .scale_min = content_state.scale_min,
        .pad_left = content_state.pad_left,
        .pad_right = content_state.pad_right,
        .pad_top = content_state.pad_top,
        .pad_bottom = content_state.pad_bottom,
        .node_opacity = content_state.node_opacity,
        .use_opacity_layer = content_state.use_opacity_layer,
        .effective_clip = content_state.effective_clip,
        .radii = content_state.radii,
        .radius = content_state.radius,
        .clip_shape_kind = content_state.clip_shape_kind,
        .clip_radii = content_state.clip_radii,
        .clip_polygon = content_state.clip_polygon,
        .clip_bounds_fallback = content_state.clip_bounds_fallback,
        .use_rounded_clip = content_state.use_rounded_clip,
        .promoted_layer_id = promoted_layer_id,
        .promoted_layer_stable_id = plan_state.promoted_layer_stable_id,
        .is_promoted_layer = is_promoted_layer,
        .promoted_surface_valid = if (is_promoted_layer) plan_state.frame_flags.surface_valid else false,
        .subtree_force_linear_text = inherited_force_linear_text or node.frame_state.state_bits.flags.text_stabilize_subtree or auto_stabilize_text,
    };
}

/// Some hook in the subtree may write paint state without marking it (see
/// Node.beforeRenderHooksCacheTrusted). Cache-trusted hooks behave like event handlers: every
/// change they make reaches the dirty bits, so they do not block cross-frame caching.
fn hasUntrustedBeforeRenderHookSubtree(node: *Node) bool {
    return node.frame_state.state_bits.flags.has_untrusted_before_render_subtree;
}

fn hasUntrustedBeforeRenderHookDescendants(node: *Node) bool {
    for (node.children.items) |child| {
        if (child.frame_state.state_bits.flags.has_untrusted_before_render_subtree) return true;
    }
    return false;
}

// -- Plan generation --

fn buildNodeExecutionPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    active_parent_effect_id: u32,
) NodeExecutionPlan {
    // Only hooks that may write without dirty marking make content frame-variant for caching.
    const has_self_before_render_hooks = !node.beforeRenderHooksCacheTrusted();
    const has_descendant_before_render_hooks = hasUntrustedBeforeRenderHookDescendants(node);
    const has_manual_overlay_animation = node.frame_state.state_bits.flags.manual_transform_animation_active or node.frame_state.state_bits.flags.manual_opacity_animation_active;
    // Overlay roots such as PopoverContent legitimately use a root-level before_render
    // hook to update anchored placement each frame. That hook mutates transform/geometry,
    // but it does not make the subtree content itself frame-variant. Treat descendant
    // hooks as cache-unsafe, while allowing root-only overlay hooks to keep a promoted
    // surface stable across scale/opacity animation frames.
    const overlay_root_before_render_cache_safe = exec_state.retained_runtime.is_overlay_candidate and
        has_self_before_render_hooks and
        !has_descendant_before_render_hooks;
    const has_before_render_hooks = has_descendant_before_render_hooks or
        (has_self_before_render_hooks and !overlay_root_before_render_cache_safe);
    const has_surface_transform = @abs(node.style.rotate()) > 0.0001 or
        @abs(node.style.scale_x() - 1.0) > 0.0001 or
        @abs(node.style.scale_y() - 1.0) > 0.0001;
    const use_legacy_overflow_cache = !exec_state.is_promoted_layer and
        exec_state.needs_clip and
        !node.frame_state.state_bits.flags.has_custom_draw_subtree and
        !has_before_render_hooks and
        !has_surface_transform and
        canUseLegacyOverflowCache(node, exec_state.retained_runtime);
    // Promoted content cache is only safe for content whose visual output is
    // fully modeled by dirty/version propagation. Subtrees with before_render
    // hooks (for example Input caret/scroll state) can mutate visible content
    // frame-to-frame without a stable descendant content cache boundary.
    const overlay_animation_cache_unsafe = exec_state.retained_runtime.is_overlay_candidate and
        has_manual_overlay_animation and
        !overlay_root_before_render_cache_safe;
    const promoted_cache_safe = exec_state.is_promoted_layer and
        !node.frame_state.state_bits.flags.has_custom_draw_subtree and
        !has_before_render_hooks and
        !overlay_animation_cache_unsafe;
    const can_write_promoted_cache = promoted_cache_safe;
    const _local_rect = cx.rectFromWorld(node);
    const can_write_legacy_overflow_cache = use_legacy_overflow_cache and _local_rect.w > 0.1 and _local_rect.h > 0.1;
    const promoted_surface_invalidation_reason: PromotedSurfaceInvalidationReason = if (!exec_state.is_promoted_layer or node.meta.per_frame.caches.commands.promoted == null)
        .none
    else if (node.frame_state.state_bits.dirty.core.subtree_render)
        if (node.frame_state.state_bits.dirty.core.render) .self else .descendant
    else if (exec_state.plan_state.frame_flags.invalidated_by_descendant_this_frame)
        .descendant
    else if (exec_state.plan_state.frame_flags.invalidated_by_self_this_frame)
        .self
    else
        .none;
    const has_descendant_scoped_promoted_rebuild_candidate = promoted_surface_invalidation_reason == .descendant and
        exec_state.retained_runtime.has_promoted_descendant_subtree;
    const has_prebuilt_display_payload_own = exec_state.retained_runtime.display_payload_own_prebuilt;
    const own_payload_fresh_this_frame = exec_state.retained_runtime.display_payload_own_prebuilt_epoch == cx.scene_runtime.frame_epoch;
    const subtree_payload_fresh_this_frame = exec_state.retained_runtime.display_payload_subtree_prebuilt_epoch == cx.scene_runtime.frame_epoch;
    const own_payload_replay_safe_in_current_scope = exec_state.retained_ids.effect_id == active_parent_effect_id and
        !exec_state.plan_state.needs_rect_clip_fallback;
    const disable_spanned_text_retained = disableSpannedTextRetainedEnabled() and nodeHasSpannedText(node);

    // disable_spanned_text_retained only disables **cross-frame** cache (promoted / legacy
    // overflow), not same-frame display payload prebuild+replay (subtree / own), else after
    // prebuild sets subtree_prebuilt=true replay skips causing content loss.
    return .{
        .promoted_surface_invalidation_reason = promoted_surface_invalidation_reason,
        .has_promoted_descendant_subtree = exec_state.retained_runtime.has_promoted_descendant_subtree,
        .has_descendant_scoped_promoted_rebuild_candidate = has_descendant_scoped_promoted_rebuild_candidate,
        .rebuild_strategy = if (has_descendant_scoped_promoted_rebuild_candidate) .descendant_scoped_promoted else .normal,
        .has_prebuilt_display_payload_own = has_prebuilt_display_payload_own,
        .has_prebuilt_display_payload_subtree = exec_state.retained_runtime.display_payload_subtree_prebuilt,
        .prebuilt_display_payload_strategy = exec_state.retained_runtime.display_payload_subtree_strategy,
        // subtree/own replay sinks a runtime range from the **this-frame** display_list to the
        // render
        // list; the range must be written by this-frame prebuild (epoch hard constraint). A stale
        // range points at table positions now occupied by other content (e.g. an old range masking
        // a
        // sibling glass ball's fresh entries), so sinking re-draws others' entries:
        // semi-transparent
        // glass/specularity double-stacks and whitens, and toggling settle/scroll state flickers.
        .should_try_display_payload_subtree_replay = !has_before_render_hooks and
            !has_manual_overlay_animation and
            subtree_payload_fresh_this_frame and
            exec_state.retained_runtime.display_payload_subtree_prebuilt and
            exec_state.retained_runtime.subtree_display_item_count > 0,
        .should_try_display_payload_own_replay = has_prebuilt_display_payload_own and
            !has_manual_overlay_animation and
            own_payload_fresh_this_frame and
            own_payload_replay_safe_in_current_scope and
            canRepresentOwnContentInDisplayList(cx, node, exec_state, active_parent_effect_id),
        .use_legacy_overflow_cache = use_legacy_overflow_cache,
        // Reference frames (incremental == full check) replay no cross-frame cache of any kind:
        // the incremental pass has already cleared this frame's dirty bits, so without this the
        // reference would take promoted / legacy-overflow hits the incremental pass did not.
        // The plan (strategies, cache writes) stays identical so both passes record the same way.
        .should_try_promoted_replay = !disable_spanned_text_retained and
            !cx.subtree_payload_reference_mode and
            promoted_cache_safe and
            exec_state.promoted_surface_valid and
            node.meta.per_frame.caches.commands.promoted != null,
        .should_try_legacy_overflow_replay = !disable_spanned_text_retained and !cx.subtree_payload_reference_mode and use_legacy_overflow_cache and !node.frame_state.state_bits.dirty.core.subtree_render,
        .should_write_promoted_cache = !disable_spanned_text_retained and can_write_promoted_cache,
        .should_write_legacy_overflow_cache = !disable_spanned_text_retained and can_write_legacy_overflow_cache,
        .needs_rect_clip_fallback = exec_state.plan_state.needs_rect_clip_fallback,
    };
}

// -- Cache replay --

/// Cache hit frame: z>0 direct children re-render (legacy overflow cache replacement already
/// excludes them via appendLegacyCachedCommandsWithoutEscapedOverlays). Selection is the same
/// as the old "escape" criterion (positive_z band + parent not using opacity layer), part of the
/// out-of-band cache mechanism; defer to C3 unification. Clipping no longer escapes: pass the
/// parent clip and clip_id, so re-rendered content outside the cache token pair is still
/// clipped by the clip bridge to the parent's clip chain (z_index only affects sibling order,
/// not clipping, design 5.3).
fn renderOverlayChildrenAfterCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !void {
    for (childPasses(exec_state.use_opacity_layer)) |pass| {
        for (node.children.items) |child| {
            if (child.isPaintSkipped()) {
                clearSkippedInvisibleSubtreeDirty(child);
                continue;
            }
            if (pass != .positive_z or exec_state.use_opacity_layer) continue;
            if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
            try renderChildWithParentClip(cx, child, exec_state);
        }
    }
}

/// Child node's sole render entry: always inherit parent's effective_clip and
/// retained clip_id.
fn renderChildWithParentClip(
    cx: *RenderContext,
    child: *Node,
    exec_state: *const NodeExecutionState,
) !void {
    try renderNodeTransform(
        cx,
        child,
        exec_state.content_transform,
        exec_state.effective_clip,
        exec_state.subtree_force_linear_text,
        exec_state.retained_ids.transform_id,
        exec_state.retained_ids.clip_id,
        exec_state.retained_ids.effect_id,
    );
}

fn clearSkippedInvisibleSubtreeDirty(node: *Node) void {
    // Cleaned without being rendered (invisible): drop cross-frame copies recorded before the
    // change, or they are spliced as clean once the subtree shows again (a popover reopening
    // showed a button's mid-transition color).
    node_render_cache_mod.dropCachesForUnrenderedClean(node);
    node.frame_state.state_bits.dirty.core.render = false;
    node.frame_state.state_bits.dirty.core.subtree_render = false;
    node.frame_state.state_bits.dirty.pipeline.composite = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_composite = false;
    for (node.children.items) |child| {
        clearSkippedInvisibleSubtreeDirty(child);
    }
}

fn shouldRenderChildInPass(child: *Node, use_opacity_layer: bool, pass: ChildRenderPass) bool {
    _ = use_opacity_layer;
    if (child.isPaintSkipped()) return false;

    return paint_order.paintBand(child) == pass;
}

fn renderChildPass(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    pass: ChildRenderPass,
) !void {
    for (node.children.items) |child| {
        if (child.isPaintSkipped()) {
            clearSkippedInvisibleSubtreeDirty(child);
            continue;
        }
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
        try renderChildWithParentClip(cx, child, exec_state);
    }
}

/// Current node glass parameters fingerprint (field-by-field feed, avoid struct
/// padding). promoted cache begin_blur token bakes parameters by value, must compare
/// before replacement (see CachedRenderSlice.cached_glass_hash note: dirty bit can't
/// guard this path).
pub fn nodeGlassParamsHash(node: *Node) u64 {
    const gp = node.style.glass_params() orelse return std.math.maxInt(u64);
    const resolved = gp.resolve();
    var hasher = std.hash.Wyhash.init(0);
    inline for (@import("zenit_reflection").fields(@TypeOf(resolved))) |f| {
        hasher.update(std.mem.asBytes(&@field(resolved, f.name)));
    }
    // GlassGroup: table content change (member move/material interpolation) doesn't
    // change pointer, feed table version.
    if (resolved.group) |grp| {
        hasher.update(std.mem.asBytes(&grp.version));
        hasher.update(std.mem.asBytes(&grp.count));
    }
    return hasher.final();
}

fn canReusePromotedCommands(node: *Node, runtime: scene_runtime_mod.SceneNodeRuntime, exec_state: *const NodeExecutionState, cache: node_mod.CachedRenderSlice) bool {
    // Parameter interpolation in progress (GlassBox interactive boost etc.) component
    // attaches disable_render_cache exit all cache, token bakes parameters by value, no
    // stamp scheme escapes washing/timing race.
    if (node.frame_state.state_bits.flags.disable_render_cache) return false;
    if (cache.cached_glass_hash != nodeGlassParamsHash(node)) return false;
    if (runtime.promoted_layer_id == scene_runtime_mod.INVALID_ID) return false;
    if (cache.promoted_layer_id != runtime.promoted_layer_id) return false;
    if (cache.content_version != runtime.content_version) return false;
    // Root id triplet comparison intercepts "cache root semantic self-change" (promoted semantics
    // depend on the root effect chain). **Internal** frame-internal seq shifts of the subtree are
    // not intercepted here: the appendCachedCommands replacement rewrites by node_id to this
    // frame's value uniformly (rewriteSplicedItemHeaders).
    if (cache.cached_transform_id != exec_state.retained_ids.transform_id) return false;
    if (cache.cached_effect_id != exec_state.retained_ids.effect_id) return false;
    if (cache.cached_clip_id != exec_state.retained_ids.clip_id) return false;
    if (!hasSameLinearTransform(cache.world_transform, exec_state.content_transform)) return false;
    if (@abs(cache.world_bounds.w - exec_state.render_w) > 0.01) return false;
    if (@abs(cache.world_bounds.h - exec_state.render_h) > 0.01) return false;
    return true;
}

fn appendCachedCommands(cx: *RenderContext, commands: []const DisplayItem) !void {
    // Coordinates: cached DisplayItems are local space; display_list_lowering reads this frame's
    // property tree matrix by header.transform_id on lower and recalculates coords. Splice filters
    // and rewrites per item:
    //   - node exists this frame, id shifted -> rewrite to this-frame value;
    //   - node **not exist** this frame (e.g. after runtime setOpacity(0), buildRetainedSubtree
    //     skips the whole branch, no scene_runtime entry) -> **discard**. Passing a stale frame seq
    //     through would index this frame's rebuilt property tree and hit **another element**'s
    //     transform. Not traversed = invisible/removed, so discarding is always safe.
    //   - control token (transform_id == INVALID, begin/end layer etc.) passes through unchanged,
    //     so content entry add/remove doesn't affect pairing.
    // By pointer: items are large unions and scene records a few hundred bytes; spliced
    // commands make up most of a cached frame's display list.
    for (commands) |*command| {
        const h = command.header();
        if (h.transform_id == INVALID_ID) {
            _ = try cx.display_list.appendPtr(command);
            continue;
        }
        const fresh = cx.scene_runtime.getPtr(h.node_id) orelse {
            cx.perf.subtree_payload_absent_node_drop_count += 1;
            continue;
        };
        // DisplayList.append freezes pointer-backed payloads (notably path
        // geometry). A replayed cache may be replaced later in this render,
        // so borrowing its geometry here leaves lowering with a dangling ptr.
        // The header is rewritten on the stored copy (one copy per item).
        const item = try cx.display_list.appendPtr(command);
        if (fresh.transform_id != h.transform_id or
            fresh.clip_id != h.clip_id or
            fresh.effect_id != h.effect_id)
        {
            // Observation count (original downstream regression invariant probe semantics
            // upgraded to "count rewritten").
            cx.perf.subtree_payload_stale_header_count += 1;
            const hp = item.headerPtr();
            hp.transform_id = fresh.transform_id;
            hp.clip_id = fresh.clip_id;
            hp.effect_id = fresh.effect_id;
        }
    }
}

// Header transform/clip/effect_id is the **write-frame**'s frame-internal seq (property_tree
// is cleared and rebuilt each frame, ids are append indexes). effect/clip are conditional
// allocations (use_opacity_layer / needs_clip / blur / rounded_clip, flip during animation;
// opacity==0 skips the whole subtree with no alloc), so any earlier allocation-set change
// shifts all following seqs. A stamp only compares the cache root, and an offset where "one
// add one subtract leaves the total unchanged" fools even a full-frame table length compare,
// never self-healing. Sole invariant: **each content item's header id always equals its
// node's value in write-frame scene_runtime** (makeDisplayItemHeader is the single stamp
// path). buildRetainedSubtree rebuilds this-frame scene_runtime for the entire tree before any
// splice, so rewriting per item to this-frame values eliminates the whole class of stale ids;
// nodes with no entry this frame are discarded (see appendCachedCommands). All four replay
// paths (subtree payload / promoted replay / descendant-scoped rebuild / legacy overflow)
// converge into appendCachedCommands, the sole rewrite point.

fn collectSubtreeNodeIds(
    node: *Node,
    ids: *std.AutoHashMap(u32, void),
) !void {
    try ids.put(node.id, {});
    for (node.children.items) |child| {
        try collectSubtreeNodeIds(child, ids);
    }
}

/// Legacy overflow caches retain the parent's clipped content, while direct
/// positive-z children are treated as out-of-band render units and rendered
/// fresh after a cache hit (renderOverlayChildrenAfterCacheHit, which keeps
/// the parent's clip/clip_id, positive z never escapes clipping). Since the
/// R3f display-list merge, those items are also present in the cached slice;
/// omit them during replay to avoid stale+fresh double drawing (visible with
/// translucent overlays).
fn appendLegacyCachedCommandsWithoutEscapedOverlays(
    cx: *RenderContext,
    node: *Node,
    commands: []const DisplayItem,
) !void {
    var escaped_ids = std.AutoHashMap(u32, void).init(cx.frame_allocator);
    for (node.children.items) |child| {
        if (child.style.z_index() <= 0) continue;
        try collectSubtreeNodeIds(child, &escaped_ids);
    }
    if (escaped_ids.count() == 0) {
        try appendCachedCommands(cx, commands);
        return;
    }

    // Append maximal retained runs so the common case does not devolve into
    // one ArrayList growth/check per display item.
    var run_start: usize = 0;
    for (commands, 0..) |command, index| {
        if (!escaped_ids.contains(command.header().node_id)) continue;
        if (run_start < index) try appendCachedCommands(cx, commands[run_start..index]);
        run_start = index + 1;
    }
    if (run_start < commands.len) try appendCachedCommands(cx, commands[run_start..]);
}

fn canUseLegacyOverflowCache(node: *Node, runtime: scene_runtime_mod.SceneNodeRuntime) bool {
    if (!shouldCacheOverflowSubtree(node)) return false;
    if (hasScrollAncestor(node)) return false;
    if (runtime.effect_id != INVALID_ID) return false;
    if (runtime.is_overlay_candidate) return false;
    if (runtime.has_active_composite_animation) return false;
    return true;
}

fn hasSameLinearTransform(a: Transform2D, b: Transform2D) bool {
    return @abs(a.a - b.a) < 0.0001 and
        @abs(a.b - b.b) < 0.0001 and
        @abs(a.c - b.c) < 0.0001 and
        @abs(a.d - b.d) < 0.0001;
}

// -- Cache replay execution --

fn replayPromotedCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    cache: node_mod.CachedRenderSlice,
    parent_effect_id: u32,
) !void {
    try replayCachedNodeHit(
        cx,
        node,
        exec_state,
        .{
            .use_bridge = true,
            .reuse_origin = false,
            .parent_effect_id = parent_effect_id,
            .exec_plan = exec_plan,
        },
        cache.commands,
    );
}

fn replayLegacyOverflowCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    cache: node_mod.CachedRenderSlice,
) !void {
    const own_prebuilt = exec_state.retained_runtime.display_payload_own_prebuilt and
        exec_state.retained_runtime.display_payload_own_prebuilt_epoch == cx.scene_runtime.frame_epoch;
    const splice_start = cx.display_list.items.items.len;
    const self_count = @min(cache.self_content_command_count, cache.commands.len);
    try appendLegacyCachedCommandsWithoutEscapedOverlays(cx, node, if (own_prebuilt) cache.commands[self_count..] else cache.commands);
    if (!own_prebuilt) {
        if (cx.scene_runtime.nodes.getPtr(node.id)) |runtime| {
            runtime.display_item_start = @intCast(splice_start);
            runtime.display_item_count = @intCast(self_count);
            // Assembly materializes cached text; there are no frame-local blobs.
            runtime.text_blob_start = 0;
            runtime.text_blob_count = 0;
        }
    }
    try renderOverlayChildrenAfterCacheHit(cx, node, exec_state);
}

fn replayCachedNodeHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    options: ReplayBridgeOptions,
    commands: []const DisplayItem,
) !void {
    if (options.use_bridge) {
        const exec_plan = options.exec_plan orelse unreachable;
        _ = exec_plan;
        try appendCachedCommands(cx, commands);
    } else if (options.reuse_origin) {
        // reuse_origin only affects scroll offset semantics, doesn't exempt header
        // frame-internal seq rewrite.
        try appendCachedCommands(cx, commands);
    } else {
        try appendCachedCommands(cx, commands);
    }

    try renderOverlayChildrenAfterCacheHit(
        cx,
        node,
        exec_state,
    );
}

fn markNodeReplayClean(node: *Node) void {
    markNodeRenderedClean(node);
}

fn markPromotedSurfaceInvalidated(
    cx: *RenderContext,
    node_id: u32,
    layer_id: u32,
    reason: layer_tree_mod.SurfaceInvalidationReason,
) void {
    cx.layer_tree.planMarkLayerSurfaceInvalidated(layer_id, reason);
    if (cx.scene_runtime.nodes.getPtr(node_id)) |runtime| {
        runtime.promoted_surface_flags.surface_valid = false;
        runtime.promoted_surface_flags.reused_this_frame = false;
        runtime.promoted_surface_flags.rebuilt_this_frame = false;
        switch (reason) {
            .self => runtime.promoted_surface_flags.invalidated_by_self_this_frame = true,
            .descendant => runtime.promoted_surface_flags.invalidated_by_descendant_this_frame = true,
        }
    }
}

fn markPromotedDescendantScopedRebuildCandidate(
    cx: *RenderContext,
    node_id: u32,
    layer_id: u32,
) void {
    cx.layer_tree.planMarkLayerDescendantScopedRebuildCandidate(layer_id);
    if (cx.scene_runtime.nodes.getPtr(node_id)) |runtime| {
        runtime.promoted_surface_flags.descendant_scoped_rebuild_candidate_this_frame = true;
    }
}

fn tryReplayPromotedCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !bool {
    if (shouldDebugOverlayNode(node)) {
        std.debug.print(
            "[overlay-debug] frame={d} stage=try-replay component={s} id={d} subtree_render_dirty={any} valid={any}\n",
            .{ cx.scene_runtime.frame_epoch, node.meta.ownership.meta.component_name orelse "?", node.id, node.frame_state.state_bits.dirty.core.subtree_render, exec_state.promoted_surface_valid },
        );
    }
    if (node.frame_state.state_bits.dirty.core.subtree_render) {
        markPromotedSurfaceInvalidated(
            cx,
            node.id,
            exec_state.promoted_layer_id,
            if (node.frame_state.state_bits.dirty.core.render) .self else .descendant,
        );
        return false;
    }
    const cache = node.meta.per_frame.caches.commands.promoted orelse return false;
    var runtime_for_cache = exec_state.retained_runtime;
    // Cross-frame compare uses stable id (frame-internal seq shifts with node add/delete
    // -> spurious miss).
    runtime_for_cache.promoted_layer_id = exec_state.promoted_layer_stable_id;
    if (!canReusePromotedCommands(node, runtime_for_cache, exec_state, cache)) {
        markPromotedSurfaceInvalidated(cx, node.id, exec_state.promoted_layer_id, .self);
        return false;
    }

    cx.perf.render_cache_hit += 1;
    cx.layer_tree.planMarkLayerSurfaceReused(exec_state.promoted_layer_id);
    if (cx.scene_runtime.nodes.getPtr(node.id)) |runtime| {
        runtime.promoted_surface_flags.surface_valid = true;
        runtime.promoted_surface_flags.reused_this_frame = true;
        runtime.promoted_surface_flags.rebuilt_this_frame = false;
        runtime.promoted_surface_flags.invalidated_by_descendant_this_frame = false;
        runtime.promoted_surface_flags.invalidated_by_self_this_frame = false;
    }
    // Splice itself yields the correct paint order [own (self segment), children]; do **not**
    // additionally mirror own content (mirror + splice draws own twice: semi-transparent shadow
    // stacks deeper, and hover animation alternating fresh(once)/replay(twice) frames makes
    // shadow depth pulsate). The own range needed by next-frame cache assembly points directly
    // at the splice's self segment.
    const splice_start = cx.display_list.items.items.len;
    try replayPromotedCacheHit(
        cx,
        node,
        exec_state,
        exec_plan,
        cache,
        parent_effect_id,
    );
    if (cx.scene_runtime.nodes.getPtr(node.id)) |runtime| {
        runtime.display_item_start = @intCast(splice_start);
        runtime.display_item_count = cache.self_content_command_count;
        // own text materialized in cache (content bytes inlined, blob disconnected), blob
        // range zeroed.
        runtime.text_blob_start = 0;
        runtime.text_blob_count = 0;
    }
    markNodeReplayClean(node);
    return true;
}

fn tryReplayLegacyOverflowCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !bool {
    const cache = node.meta.per_frame.caches.commands.own orelse return false;
    cx.perf.render_cache_hit += 1;
    // legacy overflow cache is assembled by the "own first, descendants after" contract
    // (finalizeNodeCaches / assembleCacheCommands). If own was already written sequentially in
    // the prebuild phase this frame, replay takes only the descendant segment; else replay
    // includes own. Either way own appears exactly once and ranks before descendants (replay then
    // mirroring own would let the parent background cover all descendants, e.g. an
    // overflow_hidden progress track covering its fill).
    try replayLegacyOverflowCacheHit(
        cx,
        node,
        exec_state,
        cache,
    );
    markNodeReplayClean(node);
    return true;
}

fn tryReplayNodeFromPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !bool {
    if (exec_plan.should_try_promoted_replay) {
        if (try tryReplayPromotedCacheHit(cx, node, exec_state, exec_plan, parent_effect_id)) {
            return true;
        }
        cx.perf.render_cache_miss += 1;
        return false;
    }

    if (exec_plan.promoted_surface_invalidation_reason != .none or exec_plan.should_write_promoted_cache) {
        cx.perf.render_cache_miss += 1;
    }

    if (exec_plan.should_try_legacy_overflow_replay) {
        if (try tryReplayLegacyOverflowCacheHit(cx, node, exec_state)) {
            return true;
        }
        cx.perf.render_cache_miss += 1;
    }

    return false;
}

// -- Node bridge management --

// -- Node content render --

fn appendNodeText(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !void {
    const logical_t = resolveNodeLogicalTextProps(node) orelse return;
    try appendDisplayTextItem(cx, node, exec_state, &logical_t, node.layoutTextLayout());
}

/// scroll container (tag==.scroll) children render between a real pixel clip pair.
/// WARNING: a regular container's overflow_hidden previously had **no pixel clipping**
/// (push_clip had only two emission points: effect apply_clip and border_side);
/// virtual list overscan rows / partially scrolled-out first/last rows draw outside the
/// container. Children render paths are multiple (direct / bucket-cache assembly / retained)
/// and all must be wrapped: fixing one leaves e.g. 200-line boards (bucket path) unchanged.
/// This wrapper covers all three childPasses bands (regular/sticky/positive_z): z>0 children
/// are clipped too, z_index only affects sibling order, not clipping. To paint outside the
/// container, use a portal (cx.ensurePopoverPortalRoot / OverlayStack).
fn emitScrollClipBegin(cx: *RenderContext, node: *Node, exec_state: *const NodeExecutionState) !bool {
    const on = scrollClipWanted(node, exec_state); // Escape hatch ZENIT_DISABLE_SCROLL_CLIP inside
    if (on) {
        const token = scrollClipPushTokenBorrowed(exec_state);
        // WARNING: the token must land in display_list too: paint flow is entirely
        // replaced/bypassed
        // by "rebuild from display_list" paths (frame-end full derive, subtree payload replay,
        // splice). Emitting only in the direct paint flow makes clipping vanish on any frame that
        // takes a rebuild path (intermittent: depends on which cache path the frame hits).
        // Node-local
        // clip and paint share a header, so they relocate together on cache replay.
        try cx.display_list.append(token);
        const transform = cx.property_tree.transforms.items[exec_state.retained_ids.transform_id].content;
        try display_list_lowering_mod.appendLoweredBoth(cx, try display_list_lowering_mod.lowerNodeClip(cx.frame_allocator, token, transform));
    }
    return on;
}

fn emitScrollClipEnd(cx: *RenderContext, exec_state: *const NodeExecutionState, on: bool) !void {
    if (!on) return;
    const token: DisplayItem = .{ .pop_clip = .{
        .header = scrollClipTokenHeaderBorrowed(exec_state),
    } };
    // Symmetric with push, see emitScrollClipBegin note.
    if (!elideEmptyScrollClipScope(cx, exec_state)) try cx.display_list.append(token);
    // The paint-pass lowered streams keep their pair: descendants replayed from prebuilt ranges
    // are lowered between the two tokens without appending to display_list.
    try display_list_lowering_mod.appendLoweredBoth(cx, token);
}

/// Closing a scroll clip scope that holds nothing: drop its push token from display_list instead
/// of appending the pop. An empty clip scope draws nothing, but the paint pass re-opens the scope
/// of a fallback-prebuilt overflow container whose own content and children already sit in the
/// prebuild prefix (inside the prebuild's own pair), which left a second, empty pair at the
/// display list tail; whether that happened depended on which caches the frame hit (a legacy
/// overflow cache hit keeps the container out of the prefix), so the cached and the uncached
/// paths produced different streams for the same frame. Elision makes the stream canonical.
/// Our push is the tail exactly when nothing was appended since: anything a descendant or the
/// node itself emits after the push lands behind it.
fn elideEmptyScrollClipScope(cx: *RenderContext, exec_state: *const NodeExecutionState) bool {
    const items = cx.display_list.items.items;
    if (items.len == 0) return false;
    const last = items[items.len - 1];
    if (last != .push_clip) return false;
    const header = scrollClipTokenHeaderBorrowed(exec_state);
    if (last.push_clip.header.node_id != header.node_id or !last.push_clip.node_local) return false;
    cx.display_list.items.shrinkRetainingCapacity(items.len - 1);
    cx.perf.empty_clip_scope_elided_count += 1;
    return true;
}

fn scrollClipWanted(node: *Node, exec_state: *const NodeExecutionState) bool {
    // Criterion is **the node itself declares overflow_hidden** (exec_state.needs_clip derived
    // from style.overflow_hidden, see the early exit at the start of
    // clip.resolveNodeRenderClipSpec), not the node's tag. Requiring `tag == .scroll or tag ==
    // .input` leaves any **regular box** with overflow_hidden unclipped. Input is exactly this
    // shape: input_container (tag=.input) sets overflow_hidden=false (non-symmetric radius needs
    // border_side clipping), while the inner editable_surface (regular box, overflow_hidden=true)
    // does the clipping of scrolled text; each condition alone misses one of them and long input
    // text draws out of the input box over the leading icon and neighbors. Clipping by
    // declaration matches CSS overflow:hidden semantics, independent of type. z>0 children are
    // inside this wrapper too (positive_z band also between the token pair).
    //
    // Exception: when the node **itself has an offscreen effect** (opacity / composited_group /
    // backdrop_blur / rounded_clip) don't emit. Its clipping is already borne by the compositor
    // plan (effect_bridge projects apply_clip to the owner-local frame, rounded_clip takes the
    // surface mask), and another CONTROL push_clip pair is not just duplicate: lowering toggles
    // the effect bridge by group, a control token cuts the effect group mid-way, and content
    // after the token falls outside the blur/opacity layer (tests.zig "same-frame two
    // blur+rounded_clip islands": content ranks after end_blur).
    //
    // But if an opacity / composited_group owner has self-content painted outside the children
    // clip (shadow / stroke, clip_mod.ownerPaintsOutsideChildClip), do **not** exclude: the
    // compositor's apply_clip right after begin_layer push covers the entire surface content and
    // would clip the owner's own shadow to a rectangle and press edge content against the stroke
    // (Popover). That owner's overflow clip is then borne by this token, covering children only,
    // and layer_tree's apply_clip correspondingly retreats to the parent clip
    // (ClipNode.owner_wraps_children). The token has a real header (see scrollClipTokenHeader) so
    // it doesn't cut the effect group; the promoted cache also writes this pair into the cache
    // (CachedRenderSlice.descendant_clip_open_count).
    if (!exec_state.needs_clip or !(exec_state.clip_rect.w > 0 and exec_state.clip_rect.h > 0)) return false;
    if (exec_state.use_rounded_clip or effectiveBackdropBlurRadius(node) > 0) return false;
    if (exec_state.use_opacity_layer and !clip_mod.ownerPaintsOutsideChildClip(node)) return false;
    return !@import("zenit_environment").flag("ZENIT_DISABLE_SCROLL_CLIP");
}

test "out-of-band index matches the subtree walk at every node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x00b);
    const random = prng.random();
    for (0..40) |round| {
        var nodes: [24]*Node = undefined;
        for (&nodes, 0..) |*slot, i| {
            const n = try Node.create(allocator, @intCast(round * 100 + i + 1), .box, .{});
            switch (random.uintLessThan(u8, 8)) {
                0 => n.style.position = .sticky,
                1 => (try n.style.ensureExtFallible(allocator)).z_index = 2,
                else => {},
            }
            if (i > 0) try nodes[random.uintLessThan(usize, i)].appendChild(allocator, n);
            slot.* = n;
        }
        var blocked = id_hash.U32HashMapUnmanaged(void){};
        var out_of_band = id_hash.U32HashMapUnmanaged(void){};
        _ = try indexRenderCacheBoundaries(allocator, nodes[0], false, &blocked, null, &out_of_band);
        for (nodes) |n| try std.testing.expectEqual(subtreeHasOutOfBandPassesWalk(n), out_of_band.contains(n.id));
    }
}

test "scroll clip rejects absent, empty, and NaN bounds" {
    const node = try Node.create(std.testing.allocator, 1, .box, .{});
    defer node.destroy(std.testing.allocator);
    // These cases must reject before accessing any effect fields.
    var state: NodeExecutionState = undefined;
    state.needs_clip = false;
    try std.testing.expect(!scrollClipWanted(node, &state));
    state.needs_clip = true;
    state.clip_rect = .{ .x = 0, .y = 0, .w = 0, .h = 1 };
    try std.testing.expect(!scrollClipWanted(node, &state));
    state.clip_rect.w = std.math.nan(f32);
    try std.testing.expect(!scrollClipWanted(node, &state));
    state.clip_rect.w = 1;
    state.clip_rect.h = std.math.nan(f32);
    try std.testing.expect(!scrollClipWanted(node, &state));
}

/// The token carries **this node's real header**, not CONTROL_HEADER. Lowering groups by
/// (effect_id, clip_id) and toggles the effect bridge per group: a CONTROL header has effect_id
/// INVALID, so the token self-groups with an empty effect chain, ending ancestor opacity/blur
/// layers before the token and reopening them after. A normal child with overflow_hidden would
/// then cut the ancestor composite layer in two (group opacity becomes two independent
/// composites with double-blended overlap; blur backdrop sampled twice). A real header lets the
/// token group with this node's child content and leaves the effect chain unchanged; splice
/// header rewrite (appendCachedCommands) covers it normally. push_clip's node_local flag makes
/// lowering transform geometry by that header; pop_clip is still a control item.
pub fn scrollClipTokenHeader(exec_state: NodeExecutionState) display_list_mod.ItemHeader {
    return scrollClipTokenHeaderBorrowed(&exec_state);
}

pub fn scrollClipTokenHeaderBorrowed(exec_state: *const NodeExecutionState) display_list_mod.ItemHeader {
    return makeDisplayItemHeader(exec_state);
}

pub fn scrollClipPushToken(exec_state: NodeExecutionState) DisplayItem {
    return scrollClipPushTokenBorrowed(&exec_state);
}

pub fn scrollClipPushTokenBorrowed(exec_state: *const NodeExecutionState) DisplayItem {
    // Store node-local geometry so retained replay and full lowering apply the
    // same transform as the descendants. offscreenOffset only subtracts the
    // surface source bounds; it cannot convert a world-space clip to owner-local.
    const local = exec_state.content_transform.invert().transformRect(exec_state.clip_rect);
    return .{ .push_clip = .{
        .header = scrollClipTokenHeaderBorrowed(exec_state),
        .node_local = true,
        .x = local.x,
        .y = local.y,
        .w = local.w,
        .h = local.h,
        .radii = if (exec_state.scale_min > 0) style_render.scaleLocalRadii(exec_state.clip_radii, 1 / exec_state.scale_min) else .{ 0, 0, 0, 0 },
        .shape_kind = exec_state.clip_shape_kind,
        .polygon = exec_state.clip_polygon,
    } };
}

/// Prepass (prebuild) version of the scroll clip wrapper: **display_list only**. Prepass output
/// is the prebuilt payload consumed by subtree replay / splice / full derive; without this
/// token pair in the segment, any cache-replay frame draws overflow rows with zero clipping
/// (the paint pass's emitScrollClipBegin never executes under the replay shortcut).
fn prebuildScrollClipBegin(cx: *RenderContext, node: *Node, exec_state: *const NodeExecutionState) !bool {
    const on = scrollClipWanted(node, exec_state);
    if (on) try cx.display_list.append(scrollClipPushTokenBorrowed(exec_state));
    return on;
}

fn prebuildScrollClipEnd(cx: *RenderContext, exec_state: *const NodeExecutionState, on: bool) !void {
    if (!on) return;
    if (elideEmptyScrollClipScope(cx, exec_state)) return;
    try cx.display_list.append(.{ .pop_clip = .{
        .header = scrollClipTokenHeaderBorrowed(exec_state),
    } });
}

fn appendNodeBodyContent(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !void {
    if (node.meta.per_frame.custom_hooks.draw) |draw| {
        // Read rect from World.LayoutTable.
        const local_rect = cx.rectFromWorld(node);
        const draw_ctx = DrawContext{
            .lowering_buffer = cx.lowering_buffer,
            .lowering_buffer_paint = cx.lowering_buffer_paint,
            .display_list = cx.display_list,
            .display_header = makeDisplayItemHeader(exec_state),
            .content_from_world = cx.property_tree.transforms.items[exec_state.retained_ids.transform_id].content.mul(exec_state.world_transform.invert()),
            .allocator = cx.allocator,
            .frame_allocator = cx.frame_allocator,
            .render_x = exec_state.render_x,
            .render_y = exec_state.render_y,
            .render_w = exec_state.render_w,
            .render_h = exec_state.render_h,
            .local_w = local_rect.w,
            .local_h = local_rect.h,
            .clip = exec_state.effective_clip,
            .current_color = node.resolveTextColor(),
        };
        try draw.callback(draw_ctx, draw.context);
        return;
    }

    const scroll_clip_on = try emitScrollClipBegin(cx, node, exec_state);
    for (childPasses(exec_state.use_opacity_layer)) |pass| {
        try renderChildPass(cx, node, exec_state, pass);
    }
    try emitScrollClipEnd(cx, exec_state, scroll_clip_on);
}

fn appendNodeOwnContent(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !void {
    const own_cache_ok = ownPayloadCacheEligible(cx, node, exec_state);
    if (own_cache_ok) {
        if (try tryReplayOwnPayloadCache(cx, node, exec_state)) return;
    } else if (!cx.subtree_payload_reference_mode and node.meta.per_frame.caches.commands.own_payload != null) {
        // (A reference frame must leave every cache exactly as the incremental frame left it.)
        node_render_cache_mod.invalidateOwnPayloadCache(node);
    }
    cx.perf.own_content_emit_count += 1;
    const display_start = cx.display_list.items.items.len;
    const blob_start = cx.text_blob_store.blobs.items.len;
    try appendNodeShadowAndBackground(cx, node, exec_state);
    try appendNodeBorder(cx, node, exec_state);
    try appendNodeOutline(cx, node, exec_state);
    try appendNodeText(cx, node, exec_state);
    try appendNodeMedia(cx, node, exec_state);
    if (node.meta.per_frame.custom_hooks.draw != null and node.children.items.len == 0) {
        try appendNodeBodyContent(cx, node, exec_state);
    }
    // backdrop_blur's begin token is driven by the content item's effect header (lowering toggles
    // the effect bridge by group). A "pure glass" node with no bg/gradient/border/text has zero
    // items, so no group carries its effect_id, begin_blur never emits and the glass silently
    // doesn't render. Add one transparent placeholder rect as effect vehicle; a=0 produces no
    // visible pixels.
    if (cx.display_list.items.items.len == display_start and
        effectiveBackdropBlurRadius(node) >= 0.5)
    {
        const local_rect = cx.rectFromWorld(node);
        try cx.display_list.append(.{ .fill_rect = .{
            .header = style_render.makeDisplayItemHeaderBorrowed(exec_state),
            .x = 0,
            .y = 0,
            .w = local_rect.w,
            .h = local_rect.h,
            .color = types.Color.rgba(0, 0, 0, 0),
            .radius = .{ 0, 0, 0, 0 },
        } });
    }
    updateNodeDisplayPayloadRanges(cx, node.id, display_start, blob_start);
    if (own_cache_ok) maybeWriteOwnPayloadCache(cx, node, exec_state, display_start);
}

// -- Cross-frame own-content cache --
//
// The subtree payload cache only helps clean subtrees; a node on a dirty path (its subtree is
// being re-recorded because some descendant changed) and a leaf directly under such a node
// re-record their own content every frame although it did not change. The own-content cache
// keeps a materialized copy of exactly the items appendNodeOwnContent emitted for the node and
// replays it while the node itself is clean. Contract (same as the subtree payload cache):
// items are node-local with a header that appendCachedCommands rewrites to this frame's ids, so
// ancestor movement / scroll needs no invalidation.
//
// Reuse requires: node clean in render / layout / composite (descendant bits do not matter), the
// stamp (owned effect/clip scopes, content + composite version, size, linear-text state, content
// scale)
// matching, and eligibility: not hook-owned (no undeclared hook on the node or above it),
// no custom draw, no disable_render_cache on it or an ancestor, no active animation. Promoted
// owners and overlays qualify: their own items are the same node-local stream either way, placed
// where the fresh record would have gone, and their surfaces / positions come from this frame's
// property and layer trees. A cache is only written when a clean node is re-recorded (it was needed
// at least twice), so nodes that stay inside spliced subtrees cost no memory.

/// Own items are small; a node with more (custom content) is not worth duplicating.
const own_payload_cache_max_items: usize = 64;

fn nodeCleanForOwnPayloadReuse(node: *Node) bool {
    const dirty = node.frame_state.state_bits.dirty;
    return !(dirty.core.render or dirty.core.layout or dirty.pipeline.composite);
}

fn ownPayloadCacheEligible(cx: *const RenderContext, node: *Node, exec_state: *const NodeExecutionState) bool {
    if (!cx.own_payload_cache_enabled or cx.subtree_payload_reference_mode) return false;
    if (cx.hook_owned_depth != 0) return false;
    const flags = node.frame_state.state_bits.flags;
    if (flags.disable_render_cache) return false;
    if (flags.manual_transform_animation_active or flags.manual_opacity_animation_active) return false;
    if (node.meta.per_frame.custom_hooks.draw != null) return false;
    const runtime = exec_state.retained_runtime;
    // A hook may rewrite its own node without marking it; only a node whose hook declared the
    // cache-safe contract (which covers the node itself) may reuse its own content. Overlay roots
    // with a hook relocate / animate themselves every frame: never.
    if (node.hasBeforeRenderHooks() and
        (!node.beforeRenderHooksCacheTrusted() or runtime.is_overlay_candidate)) return false;
    if (runtime.has_active_composite_animation or
        runtime.has_active_transform_animation or
        runtime.has_active_opacity_animation) return false;
    const own_blocked = cx.render_cache_own_blocked orelse return false;
    if (own_blocked.contains(node.id)) return false;
    return true;
}

fn ownPayloadStampValid(cx: *const RenderContext, node_id: u32, cache: node_mod.CachedRenderSlice, exec_state: *const NodeExecutionState) bool {
    const runtime = exec_state.retained_runtime;
    if (cache.cached_owner_signature != ownerSignature(cx, node_id, runtime)) return false;
    if (cache.content_version != runtime.content_version) return false;
    if (cache.composite_version != runtime.composite_version) return false;
    if (cache.cached_force_linear_text != exec_state.subtree_force_linear_text) return false;
    if (@abs(cache.world_bounds.w - runtime.world_bounds.w) > 0.01) return false;
    if (@abs(cache.world_bounds.h - runtime.world_bounds.h) > 0.01) return false;
    if (!hasSameLinearTransform(cache.world_transform, exec_state.content_transform)) return false;
    return true;
}

fn tryReplayOwnPayloadCache(cx: *RenderContext, node: *Node, exec_state: *const NodeExecutionState) !bool {
    const cache = node.meta.per_frame.caches.commands.own_payload orelse return false;
    if (!nodeCleanForOwnPayloadReuse(node)) return false;
    if (!ownPayloadStampValid(cx, node.id, cache, exec_state)) {
        node_render_cache_mod.invalidateOwnPayloadCache(node);
        return false;
    }
    const start = cx.display_list.items.items.len;
    try appendCachedCommands(cx, cache.commands);
    if (cx.scene_runtime.nodes.getPtr(node.id)) |rt| {
        rt.display_item_start = @intCast(start);
        rt.display_item_count = @intCast(cx.display_list.items.items.len - start);
        // Cached text is materialized (content inline, no blob reference).
        rt.text_blob_start = 0;
        rt.text_blob_count = 0;
    }
    cx.perf.own_payload_cache_hit_count += 1;
    return true;
}

fn maybeWriteOwnPayloadCache(cx: *RenderContext, node: *Node, exec_state: *const NodeExecutionState, display_start: usize) void {
    if (cx.subtree_payload_reference_mode) return;
    // Only a node re-recorded while unchanged is worth a copy; a dirty one would be stale by
    // the next change anyway.
    if (!nodeCleanForOwnPayloadReuse(node)) {
        if (node.meta.per_frame.caches.commands.own_payload != null) node_render_cache_mod.invalidateOwnPayloadCache(node);
        return;
    }
    const end = cx.display_list.items.items.len;
    const count = end - display_start;
    if (count > own_payload_cache_max_items) {
        node_render_cache_mod.invalidateOwnPayloadCache(node);
        return;
    }
    const buf = cx.frame_allocator.alloc(DisplayItem, count) catch return;
    @memcpy(buf, cx.display_list.items.items[display_start..end]);
    for (buf) |*item| {
        switch (item.*) {
            .text_run => |*t| {
                if (t.blob_id != INVALID_ID) {
                    t.content = display_list_mod.resolveTextRunContent(cx.text_blob_store, t.*);
                    t.blob_id = INVALID_ID;
                    t.blob_byte_start = 0;
                    t.blob_byte_end = 0;
                }
            },
            else => {},
        }
    }
    const runtime = exec_state.retained_runtime;
    const cache = node_render_cache_mod.cacheOwnPayloadCommands(
        node,
        cx.allocator,
        buf,
        runtime.transform_id,
        runtime.effect_id,
        runtime.clip_id,
        runtime.world_bounds,
    ) orelse return;
    // Stamp versions from the runtime record the reuse side compares against.
    cache.content_version = runtime.content_version;
    cache.composite_version = runtime.composite_version;
    cache.cached_force_linear_text = exec_state.subtree_force_linear_text;
    cache.cached_owner_signature = ownerSignature(cx, node.id, runtime);
    cache.world_transform = exec_state.content_transform;
    cx.perf.own_payload_cache_write_count += 1;
}

fn appendNodeDescendantContent(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !NodeContentSlices {
    // frame arena + reserve full capacity: slice only lives until this-frame cache
    // assembly ends; append-grow on arena can't realloc in place (recursion-mid
    // allocations), must reserve one-shot.
    const child_cap = node.children.items.len;
    var regular_children: std.ArrayList(u32) = .empty;
    var sticky_children: std.ArrayList(u32) = .empty;
    var overlay_children: std.ArrayList(u32) = .empty;
    try regular_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    try sticky_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    try overlay_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    var clip_wrapped = false;

    if (node.meta.per_frame.custom_hooks.draw) |draw| {
        // custom_hooks.draw emits directly to the current tail of display_list and doesn't go
        // through
        // the children pass, so the cache side sees regular_children=[]. The node's own-content
        // range
        // is already written by appendNodeOwnContent into runtime.display_item_*; items added by
        // custom_draw fall outside the own range and belong to no child, only to the tail.
        //
        // Simplification: custom_draw nodes don't participate in promoted cache per-pass
        // classification (rarely both has_custom_draw + promoted layer); the paint pass emits
        // directly.
        const draw_local_rect = cx.rectFromWorld(node);
        const draw_ctx = DrawContext{
            .lowering_buffer = cx.lowering_buffer,
            .lowering_buffer_paint = cx.lowering_buffer_paint,
            .display_list = cx.display_list,
            .display_header = makeDisplayItemHeader(exec_state),
            .content_from_world = cx.property_tree.transforms.items[exec_state.retained_ids.transform_id].content.mul(exec_state.world_transform.invert()),
            .allocator = cx.allocator,
            .frame_allocator = cx.frame_allocator,
            .render_x = exec_state.render_x,
            .render_y = exec_state.render_y,
            .render_w = exec_state.render_w,
            .render_h = exec_state.render_h,
            .local_w = draw_local_rect.w,
            .local_h = draw_local_rect.h,
            .clip = exec_state.effective_clip,
            .current_color = node.resolveTextColor(),
        };
        if (node.children.items.len > 0) {
            try draw.callback(draw_ctx, draw.context);
        }
    } else {
        const scroll_clip_on = try emitScrollClipBegin(cx, node, exec_state);
        clip_wrapped = scroll_clip_on;
        for (childPasses(exec_state.use_opacity_layer)) |pass| {
            const target = switch (pass) {
                .regular => &regular_children,
                .sticky => &sticky_children,
                .positive_z => &overlay_children,
            };
            for (node.children.items) |child| {
                if (child.isPaintSkipped()) {
                    if (pass == .regular) clearSkippedInvisibleSubtreeDirty(child);
                    continue;
                }
                if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
                try renderChildWithParentClip(cx, child, exec_state);
                target.appendAssumeCapacity(child.id);
            }
        }
        try emitScrollClipEnd(cx, exec_state, scroll_clip_on);
    }

    const tail_start_idx = cx.display_list.items.items.len;
    try appendNodeOverflowFade(cx, node, exec_state);
    return .{
        .regular_children = regular_children,
        .sticky_children = sticky_children,
        .overlay_children = overlay_children,
        .tail_start_idx = tail_start_idx,
        .tail_end_idx = cx.display_list.items.items.len,
        .clip_wrapped = clip_wrapped,
    };
}

fn childPassHasDirtyDescendant(node: *Node, use_opacity_layer: bool, pass: ChildRenderPass) bool {
    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, use_opacity_layer, pass)) continue;
        if (child.frame_state.state_bits.dirty.core.render or child.frame_state.state_bits.dirty.core.subtree_render or child.frame_state.state_bits.dirty.pipeline.composite or child.frame_state.state_bits.dirty.pipeline.subtree_composite) {
            return true;
        }
    }
    return false;
}

fn childPassHasCleanDescendant(node: *Node, use_opacity_layer: bool, pass: ChildRenderPass) bool {
    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, use_opacity_layer, pass)) continue;
        if (!(child.frame_state.state_bits.dirty.core.render or child.frame_state.state_bits.dirty.core.subtree_render or child.frame_state.state_bits.dirty.pipeline.composite or child.frame_state.state_bits.dirty.pipeline.subtree_composite)) {
            return true;
        }
    }
    return false;
}

/// After cache splice backfill child's subtree range, point to just-spliced section
/// in this-frame display_list. scene_runtime cleared per-frame, if not backfilled, next
/// cache assembly (assembleCacheCommands slices by per-child range) gets count=0 -> that
/// child content silently disappears from cache.
fn setChildSpliceRange(cx: *RenderContext, child_id: u32, start: usize, len: usize) void {
    if (cx.scene_runtime.nodes.getPtr(child_id)) |runtime| {
        runtime.subtree_display_item_start = @intCast(start);
        runtime.subtree_display_item_count = @intCast(len);
    }
}

fn replayCachedDescendantPass(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    cache: node_mod.CachedRenderSlice,
    pass: ChildRenderPass,
) !bool {
    if (pass == .regular) {
        // regular band has per-child count (regular_child_slices): per-child splice and
        // backfill precise range, maintain assembly per-child ownership correct.
        if (cache.regular_child_slices.len == 0) return false;
        for (cache.regular_child_slices) |slice| {
            const commands = cache.regularChildCommands(slice.child_id) orelse return false;
            const start = cx.display_list.items.items.len;
            try appendCachedCommands(cx, commands);
            setChildSpliceRange(cx, slice.child_id, start, commands.len);
        }
        cx.perf.descendant_scoped_promoted_descendant_pass_replay_count += 1;
        return true;
    }

    const commands = switch (pass) {
        .regular => unreachable,
        .sticky => cache.descendantStickyCommands(),
        .positive_z => cache.descendantOverlayCommands(),
    };
    if (commands.len == 0) return false;
    // sticky/overlay band no per-child count: only when that pass has exactly one child
    // does entire section belong to it; multiple children can't precisely split, abandon
    // band replacement fall back fresh render (preserve correctness).
    var sole_child_id: u32 = INVALID_ID;
    var pass_child_count: usize = 0;
    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
        sole_child_id = child.id;
        pass_child_count += 1;
    }
    if (pass_child_count != 1) return false;
    const start = cx.display_list.items.items.len;
    try appendCachedCommands(cx, commands);
    setChildSpliceRange(cx, sole_child_id, start, commands.len);
    cx.perf.descendant_scoped_promoted_descendant_pass_replay_count += 1;
    return true;
}

fn replayCachedRegularChild(
    cx: *RenderContext,
    exec_state: *const NodeExecutionState,
    cache: node_mod.CachedRenderSlice,
    child_id: u32,
) !bool {
    _ = exec_state;
    const commands = cache.regularChildCommands(child_id) orelse return false;
    if (commands.len == 0) return false;
    const start = cx.display_list.items.items.len;
    try appendCachedCommands(cx, commands);
    setChildSpliceRange(cx, child_id, start, commands.len);
    cx.perf.descendant_scoped_promoted_regular_child_replay_count += 1;
    return true;
}

fn replayCachedDescendantTail(
    cx: *RenderContext,
    exec_state: *const NodeExecutionState,
    cache: node_mod.CachedRenderSlice,
) !bool {
    _ = exec_state;
    const commands = cache.descendantTailCommands();
    if (commands.len == 0) return false;
    try appendCachedCommands(cx, commands);
    cx.perf.descendant_scoped_promoted_tail_replay_count += 1;
    return true;
}

fn appendNodeOverflowFade(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !void {
    if (!exec_state.needs_clip) return;
    const fade = node.style.overflow_fade() orelse return;
    const header = makeDisplayItemHeader(exec_state);
    try renderOverflowFade(
        cx,
        node,
        exec_state.render_x,
        exec_state.render_y,
        exec_state.render_w,
        exec_state.render_h,
        fade,
    );

    const extent = computeContentExtent(node);
    const edges = fade.edges;
    const size = fade.size;
    const solid = fade.color orelse node.getBackground();
    var transparent = solid;
    transparent.a = 0;
    const pad = node.style.contentInsets();
    const border_widths = node.style.border.resolvedWidths();
    const bw_top = border_widths[types.Border.SIDE_TOP];
    const bw_right = border_widths[types.Border.SIDE_RIGHT];
    const bw_bottom = border_widths[types.Border.SIDE_BOTTOM];
    const bw_left = border_widths[types.Border.SIDE_LEFT];
    const inner_x = bw_left;
    const inner_y = bw_top;
    // Read rect from World.LayoutTable.
    const local_rect = cx.rectFromWorld(node);
    const inner_w = @max(@as(f32, 0), local_rect.w - bw_left - bw_right);
    const inner_h = @max(@as(f32, 0), local_rect.h - bw_top - bw_bottom);

    if (edges.top and extent.min_y < pad.top) {
        try cx.display_list.append(.{
            .gradient_rect = .{
                .header = header,
                .x = inner_x,
                .y = inner_y,
                .w = inner_w,
                .h = size,
                .from = solid,
                .to = transparent,
                .direction = .vertical,
                .radius = .{ 0, 0, 0, 0 },
            },
        });
    }

    if (edges.bottom and extent.max_y > local_rect.h - pad.bottom) {
        try cx.display_list.append(.{
            .gradient_rect = .{
                .header = header,
                .x = inner_x,
                .y = inner_y + inner_h - size,
                .w = inner_w,
                .h = size,
                .from = transparent,
                .to = solid,
                .direction = .vertical,
                .radius = .{ 0, 0, 0, 0 },
            },
        });
    }

    if (edges.left and extent.min_x < pad.left) {
        try cx.display_list.append(.{
            .gradient_rect = .{
                .header = header,
                .x = inner_x,
                .y = inner_y,
                .w = size,
                .h = inner_h,
                .from = solid,
                .to = transparent,
                .direction = .horizontal,
                .radius = .{ 0, 0, 0, 0 },
            },
        });
    }

    if (edges.right and extent.max_x > local_rect.w - pad.right) {
        try cx.display_list.append(.{
            .gradient_rect = .{
                .header = header,
                .x = inner_x + inner_w - size,
                .y = inner_y,
                .w = size,
                .h = inner_h,
                .from = transparent,
                .to = solid,
                .direction = .horizontal,
                .radius = .{ 0, 0, 0, 0 },
            },
        });
    }
}

// -- Cache finalization --

// -- Rebuild strategy and main render flow --

fn renderNodeRebuildCommon(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !void {
    // Ordering: if this node's own content was already written sequentially in the prebuild phase
    // this frame (own_prebuilt and epoch=current frame) but own-replay is unsafe, e.g. clip
    // fallback (should_try_display_payload_own_replay=false), then **don't** fresh re-emit here:
    // own (including background) would be appended after the already-prebuilt children and the
    // background would cover them (e.g. overflow_hidden + background nodes like Table). The
    // prebuild own copy already ranks before children.
    const own_already_prebuilt_fresh = exec_state.retained_runtime.display_payload_own_prebuilt and
        exec_state.retained_runtime.display_payload_own_prebuilt_epoch == cx.scene_runtime.frame_epoch;
    if (!try tryReplayOwnContentFromPlan(cx, node, exec_state, exec_plan, parent_effect_id)) {
        if (!own_already_prebuilt_fresh) {
            try appendNodeOwnContent(cx, node, exec_state);
        }
    }
    // legacy overflow cache no longer sliced by paint tail section, instead assembled
    // by finalizeNodeCaches by content_slices (own first, descendants after), cache content
    // independent of where own written this frame; this starting point kept only for
    // signature.
    const legacy_overflow_start_idx = cx.display_list.items.items.len;
    const content_slices = try appendNodeDescendantContent(cx, node, exec_state);

    finalizeNodeCaches(
        cx,
        node,
        legacy_overflow_start_idx,
        content_slices,
        exec_state,
        exec_plan,
    );
    // content_slices on frame arena, entire reclaim frame-end, no deinit needed.
}

fn appendDescendantScopedPromotedSelfSlice(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
) !bool {
    _ = exec_state;
    const cache = node.meta.per_frame.caches.commands.promoted orelse return false;
    if (node.frame_state.state_bits.flags.disable_render_cache) return false;
    // glass parameters baked in cache token, changed params forbid replacing old self
    // slice.
    if (cache.cached_glass_hash != nodeGlassParamsHash(node)) return false;
    const self_commands = cache.selfCommands();
    if (self_commands.len == 0) return false;

    try appendCachedCommands(cx, self_commands);
    cx.perf.descendant_scoped_promoted_self_replay_count += 1;
    return true;
}

fn renderNodeDescendantScopedPromotedRebuild(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !void {
    const legacy_overflow_start_idx = cx.display_list.items.items.len;
    if (!try appendDescendantScopedPromotedSelfSlice(cx, node, exec_state)) {
        if (!try tryReplayOwnContentFromPlan(cx, node, exec_state, exec_plan, parent_effect_id)) {
            try appendNodeOwnContent(cx, node, exec_state);
        }
    }
    const existing_cache = node.meta.per_frame.caches.commands.promoted;
    // frame arena + full capacity reserve, same as appendNodeDescendantContent.
    const child_cap = node.children.items.len;
    var regular_children: std.ArrayList(u32) = .empty;
    var sticky_children: std.ArrayList(u32) = .empty;
    var overlay_children: std.ArrayList(u32) = .empty;
    try regular_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    try sticky_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    try overlay_children.ensureTotalCapacity(cx.frame_allocator, child_cap);

    const scroll_clip_on = try emitScrollClipBegin(cx, node, exec_state);
    for (childPasses(exec_state.use_opacity_layer)) |pass| {
        const pass_has_dirty = childPassHasDirtyDescendant(node, exec_state.use_opacity_layer, pass);
        const pass_has_clean = childPassHasCleanDescendant(node, exec_state.use_opacity_layer, pass);
        const target = switch (pass) {
            .regular => &regular_children,
            .sticky => &sticky_children,
            .positive_z => &overlay_children,
        };

        if (pass == .regular and pass_has_dirty and pass_has_clean) {
            if (existing_cache) |cache| {
                for (node.children.items) |child| {
                    if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
                    const child_dirty = child.frame_state.state_bits.dirty.core.render or child.frame_state.state_bits.dirty.core.subtree_render or child.frame_state.state_bits.dirty.pipeline.composite or child.frame_state.state_bits.dirty.pipeline.subtree_composite;
                    if (!child_dirty and try replayCachedRegularChild(cx, exec_state, cache, child.id)) {
                        target.appendAssumeCapacity(child.id);
                        continue;
                    }
                    try renderChildWithParentClip(cx, child, exec_state);
                    target.appendAssumeCapacity(child.id);
                }
                continue;
            }
        }

        if (existing_cache) |cache| {
            if (!pass_has_dirty) {
                if (try replayCachedDescendantPass(cx, node, exec_state, cache, pass)) {
                    // entire segment replaces from cache to display_list; child id order by
                    // children
                    // list
                    for (node.children.items) |child| {
                        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
                        target.appendAssumeCapacity(child.id);
                    }
                }
                continue;
            }
        }

        for (node.children.items) |child| {
            if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, pass)) continue;
            try renderChildWithParentClip(cx, child, exec_state);
            target.appendAssumeCapacity(child.id);
        }
    }
    try emitScrollClipEnd(cx, exec_state, scroll_clip_on);

    var replayed_tail = false;
    const tail_start_idx = cx.display_list.items.items.len;
    if (existing_cache) |cache| {
        replayed_tail = try replayCachedDescendantTail(cx, exec_state, cache);
    }
    if (!replayed_tail) {
        try appendNodeOverflowFade(cx, node, exec_state);
    }
    const tail_end_idx = cx.display_list.items.items.len;
    const content_slices = NodeContentSlices{
        .regular_children = regular_children,
        .sticky_children = sticky_children,
        .overlay_children = overlay_children,
        .tail_start_idx = tail_start_idx,
        .tail_end_idx = tail_end_idx,
        .clip_wrapped = scroll_clip_on,
    };

    finalizeNodeCaches(
        cx,
        node,
        legacy_overflow_start_idx,
        content_slices,
        exec_state,
        exec_plan,
    );
    // content_slices on frame arena, entire reclaim frame-end, no deinit needed.
}

fn renderNodeWithRebuildStrategy(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !void {
    switch (exec_plan.rebuild_strategy) {
        .normal => try renderNodeRebuildCommon(cx, node, exec_state, exec_plan, parent_effect_id),
        .descendant_scoped_promoted => {
            cx.perf.descendant_scoped_promoted_rebuild_count += 1;
            try renderNodeDescendantScopedPromotedRebuild(cx, node, exec_state, exec_plan, parent_effect_id);
        },
    }
}

fn markNodeRenderedClean(node: *Node) void {
    node.frame_state.state_bits.dirty.core.render = false;
    node.frame_state.state_bits.dirty.core.subtree_render = false;
    node.frame_state.state_bits.dirty.pipeline.composite = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_composite = false;
}

// -- Public entry points --

/// Stage timestamps for the rn_* perf fields: calling-thread CPU time (preemption excluded).
fn stageNowNs() u64 {
    const io = current_frame_io orelse return 0;
    return @intCast(@max(@import("zenit_time").threadCpuTimestamp(io), 0));
}

pub fn renderNode(cx: *RenderContext, node: *Node) anyerror!void {
    var stage_t = stageNowNs();
    const stage_lap = struct {
        fn lap(t: *u64) u64 {
            const now = stageNowNs();
            const d = (now -| t.*) / 1000;
            t.* = now;
            return d;
        }
    }.lap;
    const trace_instr = @import("zenit_environment").flag("ZENIT_PERF_TRACE");
    var stage_i: u64 = if (trace_instr) @import("zenit_time").threadInstructions() else 0;
    const instr_lap = struct {
        fn lap(on: bool, i: *u64) u64 {
            if (!on) return 0;
            const now = @import("zenit_time").threadInstructions();
            const d = (now -| i.*) / 1000;
            i.* = now;
            return d;
        }
    }.lap;
    beginRetainedFrame(cx);
    var child_order_restores: std.ArrayList(ChildOrderRestore) = .empty;
    defer restoreChildOrders(&child_order_restores);
    try sortSubtreeChildrenByZ(cx, node, &child_order_restores);
    cx.retained_nodes.clearRetainingCapacity();
    cx.content_states.clearRetainingCapacity();
    cx.retained_hook_owned_depth = 0;
    cx.retained_memo_enabled = !retained_memo_disabled();
    const root_summary = buildRetainedSubtree(cx, node, Transform2D.identity(), null, 0, INVALID_ID, INVALID_ID, Transform2D.identity());
    recordRootRetainedMemo(cx, node, root_summary);
    cx.perf.rn_retained_nodes = @intCast(cx.scene_runtime.nodes.count());
    cx.perf.rn_retained_us = stage_lap(&stage_t);
    cx.perf.rni_retained_k = instr_lap(trace_instr, &stage_i);
    cx.layer_tree.planBuildFromPropertyTree(
        cx.property_tree.effects.items,
        cx.property_tree.clips.items,
        cx.property_tree.transforms.items,
        cx.scene_runtime,
    );
    // Both passes visit every node to copy plan-layer promotion into its runtime
    // record. With no promoted plan layer they would write back exactly the defaults
    // `appendRetainedMetadata` stored this frame (records are rebuilt every frame).
    if (cx.layer_tree.frame_promoted_count != 0) {
        syncPromotedLayerIds(cx);
        _ = syncPromotedDescendantState(cx, node);
    }
    cx.perf.rn_layer_plan_us = stage_lap(&stage_t);
    cx.perf.rni_layer_plan_k = instr_lap(trace_instr, &stage_i);
    // The cache-boundary index serves both the prebuild pass and the paint-cursor resumes in
    // the paint pass (tryResumePrebuildAtPaintCursor), so it lives for the whole frame.
    var boundary_blocked = id_hash.U32HashMapUnmanaged(void){};
    defer boundary_blocked.deinit(cx.frame_allocator);
    var own_blocked = id_hash.U32HashMapUnmanaged(void){};
    defer own_blocked.deinit(cx.frame_allocator);
    var out_of_band = id_hash.U32HashMapUnmanaged(void){};
    defer out_of_band.deinit(cx.frame_allocator);
    _ = try indexRenderCacheBoundaries(cx.frame_allocator, node, false, &boundary_blocked, &own_blocked, &out_of_band);
    const previous_boundary_index = cx.render_cache_boundary_blocked;
    const previous_own_index = cx.render_cache_own_blocked;
    const previous_out_of_band = cx.out_of_band_subtrees;
    cx.render_cache_boundary_blocked = &boundary_blocked;
    cx.render_cache_own_blocked = &own_blocked;
    cx.out_of_band_subtrees = &out_of_band;
    defer {
        cx.render_cache_boundary_blocked = previous_boundary_index;
        cx.render_cache_own_blocked = previous_own_index;
        cx.out_of_band_subtrees = previous_out_of_band;
    }
    cx.paint_resume_suppress_depth = 0;
    cx.hook_owned_depth = 0;
    cx.paint_resume_enabled = paint_resume_test_override orelse !@import("zenit_environment").flag("ZENIT_DISABLE_PAINT_RESUME");
    cx.own_payload_cache_enabled = !@import("zenit_environment").flag("ZENIT_DISABLE_OWN_PAYLOAD_CACHE");
    cx.subtree_splice_disabled = @import("zenit_environment").flag("ZENIT_DISABLE_SUBTREE_SPLICE");
    cx.subtree_payload_replay_disabled = @import("zenit_environment").flag("ZENIT_DISABLE_SUBTREE_PAYLOAD_REPLAY");
    hook_self_scope_disabled = @import("zenit_environment").flag("ZENIT_DISABLE_HOOK_SELF_SCOPE");
    debug_prepass = @import("zenit_environment").flag("ZENIT_DEBUG_PREPASS");
    trace_node = if (!@import("zenit_environment").flag("ZENIT_TRACE_NODE")) 0 else blk: {
        var b: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&b);
        const v = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_TRACE_NODE") catch break :blk 0;
        break :blk std.fmt.parseInt(u32, v, 10) catch 0;
    };

    cx.perf.rn_boundary_index_us = stage_lap(&stage_t);
    cx.perf.rni_boundary_k = instr_lap(trace_instr, &stage_i);
    try prebuildDisplayPayloads(cx, node, Transform2D.identity(), null, false, INVALID_ID);
    cx.perf.rn_prebuild_us = stage_lap(&stage_t);
    cx.perf.rni_prebuild_k = instr_lap(trace_instr, &stage_i);
    const r = renderNodeTransform(cx, node, Transform2D.identity(), null, false, 0, INVALID_ID, INVALID_ID);
    cx.perf.rn_paint_us = stage_lap(&stage_t);
    cx.perf.rni_paint_k = instr_lap(trace_instr, &stage_i);
    // The paint pass cleaned this frame's dirty bits: mutations since the tick are invisible to
    // the next tick's quiet-subtree skip.
    if (!cx.subtree_payload_reference_mode) tick_mod.noteRenderCleanedAfterTick();

    // Stage B-1: shadow GpuDraw encode (debug-only). Doesn't alter main path, only
    // verify display_list -> GpuDraw lowering doesn't lose info in real scenarios.
    // divergence accumulates to PerfCounters.stage_b_shadow_count_mismatches, devtools
    // observable.
    if (@import("builtin").mode == .debug) {
        runShadowEncode(cx);
    }

    return r;
}

/// Shadow encode entry (debug-only, auto-called at renderNode tail; tests also call it
/// directly). Inline cmd -> PipelineId map (dual of paint_table.DisplayItemKind -> PipelineId):
///   1=rect, 2=text, 3=image, 4=path, 5=shadow, 6=gradient, 0=control flow (not counted)
pub fn runShadowEncode(cx: *RenderContext) void {
    const display_items = cx.display_list.items.items;
    if (display_items.len == 0) return;

    // Stage B S6 R3a: cache migrated to DisplayItem; paint pass cx.lowering_buffer no longer
    // cache index baseline. expected_pipelines derived from display_list itself not lowering_buffer
    // compare.
    const expected_pipelines = cx.frame_allocator.alloc(u16, cx.display_list.items.items.len) catch return;
    var drawable_commands: usize = 0;
    for (display_items) |it| {
        const lowered = gpu_draw_shadow.lowerDisplayItem(it);
        const pl: u16 = switch (lowered.kind) {
            .rect => 1,
            .text => 2,
            .image => 3,
            .path => 4,
            .shadow => 5,
            .gradient => 6,
            .none, .control => 0,
        };
        if (pl != 0) {
            expected_pipelines[drawable_commands] = pl;
            drawable_commands += 1;
            switch (pl) {
                1 => cx.perf.stage_b_shadow_drawable_kind_rect +%= 1,
                2 => cx.perf.stage_b_shadow_drawable_kind_text +%= 1,
                3 => cx.perf.stage_b_shadow_drawable_kind_image +%= 1,
                4 => cx.perf.stage_b_shadow_drawable_kind_path +%= 1,
                5 => cx.perf.stage_b_shadow_drawable_kind_shadow +%= 1,
                6 => cx.perf.stage_b_shadow_drawable_kind_gradient +%= 1,
                else => {},
            }
        }
    }

    // Count display_list items by lowered kind.
    for (display_items) |it| {
        const lowered = gpu_draw_shadow.lowerDisplayItem(it);
        switch (lowered.kind) {
            .rect => cx.perf.stage_b_shadow_kind_rect +%= 1,
            .text => cx.perf.stage_b_shadow_kind_text +%= 1,
            .image => cx.perf.stage_b_shadow_kind_image +%= 1,
            .path => cx.perf.stage_b_shadow_kind_path +%= 1,
            .shadow => cx.perf.stage_b_shadow_kind_shadow +%= 1,
            .gradient => cx.perf.stage_b_shadow_kind_gradient +%= 1,
            .none, .control => {},
        }
    }

    // frame_allocator: reset per-frame, no need to free.
    const draws = cx.frame_allocator.alloc(gpu_draw_shadow.GpuDraw, display_items.len) catch return;
    const result = gpu_draw_shadow.encodeShadow(
        display_items,
        drawable_commands,
        draws,
        expected_pipelines[0..drawable_commands],
    );
    cx.perf.stage_b_shadow_display_items +%= @truncate(result.display_item_count);
    cx.perf.stage_b_shadow_drawable_commands +%= @truncate(result.drawable_command_count);
    cx.perf.stage_b_shadow_gpu_draws +%= @truncate(result.gpu_draw_count);
    if (!result.counts_match) {
        cx.perf.stage_b_shadow_count_mismatches +%= 1;
    }
    if (!result.pipelines_match) {
        cx.perf.stage_b_shadow_pipeline_mismatches +%= 1;
    }
    if (result.max_batch_run > cx.perf.stage_b_shadow_max_batch_run) {
        cx.perf.stage_b_shadow_max_batch_run = result.max_batch_run;
    }
    cx.perf.stage_b_shadow_field_value_mismatches +%= result.field_value_mismatches;
}

fn renderNodeTransform(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    inherited_force_linear_text: bool,
    _: u32,
    _: u32,
    parent_effect_id: u32,
) anyerror!void {
    // on_before_render already unified in tickBeforeRender.
    // Runs before the ranges below are sampled and before the runtime record is copied into
    // exec_state: a resumed subtree is complete in the list and replays like a prefix one.
    cx.perf.rn_paint_nodes += 1;
    const resumed = try tryResumePrebuildAtPaintCursor(cx, node, parent_transform, parent_clip, inherited_force_linear_text, parent_effect_id);
    // A subtree spliced from its cross-frame cache is complete in the display list and clean
    // throughout (the splice requires it): when this pass does not lower (Cx.render lowers the
    // whole list afterwards) the ordinary subtree replay below would only rebuild its execution
    // state and plan, then walk the subtree clearing bits that are already clear.
    if (resumed == .spliced and !cx.paint_pass_lowering) {
        cx.perf.display_list_subtree_replay_count += 1;
        cx.perf.rn_paint_subtree_replays += 1;
        cx.perf.rn_paint_splice_fast += 1;
        return;
    }
    const subtree_display_start = cx.display_list.items.items.len;
    const subtree_blob_start = cx.text_blob_store.blobs.items.len;
    const exec_state = buildNodeExecutionState(cx, node, parent_transform, parent_clip, inherited_force_linear_text) orelse {
        cx.perf.rn_paint_culled += 1;
        return;
    };
    dropCachesWithStaleTextRasterState(cx, node, exec_state.subtree_force_linear_text);
    const exec_plan = buildNodeExecutionPlan(cx, node, &exec_state, parent_effect_id);
    debugOverlayPlan(cx, node, exec_state, exec_plan, "render");

    // Descendants may not resume a prebuild when this subtree is hook-owned, or when it was
    // already prebuilt this frame and is being re-rendered (that fresh output is truncated).
    const hook_owned = beforeRenderHookTaintsSubtree(node, &exec_state, parent_effect_id);
    const suppress_resume = hook_owned or
        (exec_state.retained_runtime.display_payload_subtree_prebuilt and
            exec_state.retained_runtime.display_payload_subtree_prebuilt_epoch == cx.scene_runtime.frame_epoch);
    if (suppress_resume) cx.paint_resume_suppress_depth += 1;
    if (hook_owned) cx.hook_owned_depth += 1;
    defer {
        if (suppress_resume) cx.paint_resume_suppress_depth -= 1;
        if (hook_owned) cx.hook_owned_depth -= 1;
    }

    if (exec_plan.has_descendant_scoped_promoted_rebuild_candidate) {
        markPromotedDescendantScopedRebuildCandidate(cx, node.id, exec_state.promoted_layer_id);
    }

    if (try tryReplayNodeFromPlan(cx, node, &exec_state, exec_plan, parent_effect_id)) {
        cx.perf.rn_paint_cache_replays += 1;
        finishNodeSubtreeDisplayPayloadRanges(cx, node.id, subtree_display_start, subtree_blob_start);
        return;
    }

    if (try tryReplaySubtreePayloadFromPlan(cx, node, &exec_state, exec_plan, parent_effect_id)) {
        cx.perf.rn_paint_subtree_replays += 1;
        return;
    }
    cx.perf.rn_paint_rebuilds += 1;

    // The paint pass re-records this subtree. Its cross-frame payload cache is only written by
    // the prebuild routines (prebuild pass / paint-cursor resume); unless one of them recorded
    // it this frame, the cache is older than what is drawn now and must not be spliced on a
    // later clean frame (a subtree changed while the resume refused it, e.g. a descendant
    // carrying a hover hook for the duration of a transition, kept a cache from mid-transition).
    if (!cx.subtree_payload_reference_mode and node.meta.per_frame.caches.commands.subtree_payload != null and
        !(exec_state.retained_runtime.display_payload_subtree_prebuilt and
            exec_state.retained_runtime.display_payload_subtree_prebuilt_epoch == cx.scene_runtime.frame_epoch))
    {
        dropSubtreePayloadCache(node);
        cx.perf.subtree_payload_rerecord_drop_count += 1;
    }
    try renderNodeWithRebuildStrategy(cx, node, &exec_state, exec_plan, parent_effect_id);
    // If the paint pass entry already contains this node's subtree prebuild contribution (after
    // subtree_display_start, before paint pass entry), paint pass fresh emit would append the same
    // content at the end; truncate the fresh portion and keep prebuild.
    // Comparing positions can't detect this: the position after prebuild == subtree_display_start
    // (cx.display_list length at paint pass entry). Use scene_runtime's subtree_display_item_count
    // (written by prebuild) instead: if > 0, prebuild wrote this node's subtree, so truncate the
    // fresh portion.
    if (cx.scene_runtime.getPtr(node.id)) |rt| {
        if (rt.display_payload_subtree_prebuilt and rt.subtree_display_item_count > 0) {
            cx.display_list.items.shrinkRetainingCapacity(subtree_display_start);
            // WARNING: only display_list can be truncated, never text_blob_store.
            //
            // The kept prebuild display items' text_run still reference blobs indirectly by blob_id
            // (prebuildSimpleDisplayPayloadSubtree doesn't materialize, it only records a range),
            // and
            // prebuild's blobs fall in [subtree_blob_start, ...); truncating would truncate exactly
            // the
            // data they reference. The slot is then reused by later nodes' text, and
            // resolveTextRunContent
            // slices the new blob's bytes by the old offset (e.g. status bar "plaintext" becomes
            // "plainte", tab name garbled or empty).
            //
            // Blobs only grow and are cleared per frame; keeping extras costs some memory this
            // frame,
            // while truncating wrongly renders wrong.
        }
    }
    finishNodeSubtreeDisplayPayloadRanges(cx, node.id, subtree_display_start, subtree_blob_start);

    markNodeRenderedClean(node);
}

// ===== Monospace fast-path helper functions =====

// Check if spans only override color (no font_weight/italic/strikethrough).
// Pure-text editor syntax highlight only has color and bg_color, always returns true.

pub fn estimateTimeMs() f64 {
    const io = current_frame_io orelse return current_frame_time_ms;
    const now = @as(f64, @floatFromInt(@import("zenit_time").monotonicTimestamp(io))) / 1_000_000.0;
    const delta = now - current_frame_monotonic_ms;
    return if (delta <= 0) current_frame_time_ms else current_frame_time_ms + delta;
}
