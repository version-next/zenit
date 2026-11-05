//! node_dirty: dirty-propagation subdomain extracted from node.zig (15 methods: 12 pub + 3
//! private).
//!
//! Unlike paint_content_accessor.zig (pca), a SoA accessor whose free functions take element_id_raw
//! + POD and are Node-agnostic, dirty propagation walks the self.parent chain /
//! frame_state.state_bits
//! / meta and needs `*Node`. So this module uses **Node-typed free functions** and
//! @import("node.zig") for the type (cyclic import with node.zig; valid under Zig lazy evaluation).
//!
//! node.zig keeps thin delegates for all 15 methods (original visibility), each forwarding in one
//! line, so the many self.markX() callers across domains need no changes.
//!
//! The dirty-notify callback unit (DirtyKind / DirtyNotifyFn / g_dirty_notify /
//! setDirtyNotifyCallback) lives here too (markRenderDirty pushes dirty to World.dirty_set via
//! g_dirty_notify); node.zig re-exports it to keep the public API intact.

const std = @import("std");
const world_mod = @import("world.zig");
const node_mod = @import("node.zig");
const redraw = @import("redraw.zig");
const debug_trace = @import("debug_trace.zig");
const types = @import("types.zig");

const Node = node_mod.Node;

// ----------------------------------------------------------------------
// dirty-notify callback unit
// Synchronously pushes dirty to World.dirty_set via callback.
// Does not import core.zig (avoids a cycle); core.zig sets the callback at Cx.init.
// ----------------------------------------------------------------------

pub const DirtyKind = enum(u8) { layout, style, structure, interaction };
pub const DirtyNotifyFn = *const fn (element_id_raw: u32, kind: DirtyKind) void;
var g_dirty_notify: ?DirtyNotifyFn = null;

/// Push one dirty mark to the node's owning World's dirty_set.
///
/// P0-3 phase 3: prefer direct `node.world_ref`; fall back to old process-level callback when
/// world_ref == null (cx-less mock). Semantics match core.zig:onNodeDirty line-for-line.
fn markWorldDirty(node: anytype, kind: DirtyKind) void {
    if (node.element_id_raw == 0xFFFFFFFF) return;
    const flags: world_mod.DirtyFlags = switch (kind) {
        .layout => .{ .input = .{ .geometry_changed = true } },
        .style => .{ .input = .{ .style_changed = true } },
        .structure => .{ .input = .{ .structure_changed = true } },
        .interaction => .{ .input = .{ .interaction_changed = true } },
    };
    if (node.world_ref) |w| {
        // OOM fault tolerance: drop one dirty, frame still uses old path rebuild.
        w.markDirty(world_mod.ElementId.fromRaw(node.element_id_raw), flags) catch {};
        return;
    }
    if (g_dirty_notify) |notify| notify(node.element_id_raw, kind);
}

pub fn setDirtyNotifyCallback(notify: ?DirtyNotifyFn) void {
    g_dirty_notify = notify;
}

// ----------------------------------------------------------------------
// dirty propagation methods (Node-typed free functions)
// ----------------------------------------------------------------------

/// Flip generation counter for the loose interaction bits (pipeline.interaction / hit.geometry /
/// hit.semantics). These bits don't bubble, so they could only be found by a full-tree recursive
/// scan (subtreeHasLooseInteractionDirty, once the largest single item in frame-structure
/// sampling). Every set/clear site bumps this generation; scans memoize by (root, generation) and
/// any flip auto-invalidates, so semantics are exactly equivalent to a fresh scan each time. Any
/// new write site for these bits must bump it too (core.zig memo comments share this contract).
pub var g_loose_interaction_gen: u64 = 1;

pub inline fn bumpLooseInteractionGen() void {
    g_loose_interaction_gen +%= 1;
}

var layout_dirty_debug: ?bool = null;
var layout_dirty_reports: u32 = 0;
/// ZENIT_DEBUG_LAYOUT_DIRTY=1: print who marks a clean node layout-dirty (first 400 marks, with a
/// stack trace). Finds layout work on frames that should only move content (scroll).
fn layoutDirtyDebugEnabled() bool {
    return layout_dirty_debug orelse blk: {
        const v = @import("zenit_environment").flag("ZENIT_DEBUG_LAYOUT_DIRTY");
        layout_dirty_debug = v;
        break :blk v;
    };
}

fn reportLayoutDirty(self: *Node) void {
    if (layout_dirty_reports >= 400) return;
    layout_dirty_reports += 1;
    std.debug.print("[layout-dirty] node={d} component={s} test_id={s}\n", .{
        self.id,
        self.meta.ownership.meta.component_name orelse "(nil)",
        self.meta.ownership.meta.test_id orelse "(nil)",
    });
    std.debug.dumpCurrentStackTrace(.{});
}

pub fn markLayoutDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    if (self.frame_state.state_bits.dirty.core.layout) return;
    if (layoutDirtyDebugEnabled()) reportLayoutDirty(self);
    bumpLooseInteractionGen();
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.hit.geometry = true;
    self.frame_state.state_bits.dirty.core.layout = true;
    self.frame_state.state_bits.dirty.core.subtree_layout = true;
    self.frame_state.state_bits.dirty.core.render = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    self.frame_state.state_bits.dirty.pipeline.composite = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    redraw.requested = true;
    debug_trace.maybeRecordRender(self.id, .layout_triggered, "markLayoutDirty");

    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.dirty.core.subtree_layout and parent.frame_state.state_bits.dirty.core.subtree_render and parent.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
        parent.frame_state.state_bits.dirty.core.subtree_layout = true;
        parent.frame_state.state_bits.dirty.core.subtree_render = true;
        parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
        if (parent.style.layout_isolation) break;
        p = parent.parent;
    }
}

/// Mark self and parent layout dirty. Used when child sizing properties (width/height) dynamically
/// change, requiring parent container to re-run layoutChildren to recalculate child sizes.
pub fn markSizingDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    bumpLooseInteractionGen();
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.hit.geometry = true;
    self.frame_state.state_bits.dirty.core.layout = true;
    self.frame_state.state_bits.dirty.core.subtree_layout = true;
    self.frame_state.state_bits.dirty.core.render = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    self.frame_state.state_bits.dirty.pipeline.composite = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    redraw.requested = true;
    debug_trace.maybeRecordRender(self.id, .sizing_triggered, "markSizingDirty");

    if (self.parent) |parent_node| {
        parent_node.frame_state.state_bits.dirty.core.layout = true;
        parent_node.frame_state.state_bits.dirty.core.subtree_layout = true;
        parent_node.frame_state.state_bits.dirty.core.render = true;
        parent_node.frame_state.state_bits.dirty.core.subtree_render = true;
        parent_node.frame_state.state_bits.dirty.pipeline.composite = true;
        parent_node.frame_state.state_bits.dirty.pipeline.subtree_composite = true;

        // Bubble subtree_dirty from grandparent (parent already handled above; starting from parent
        // would
        // immediate break, leaving grandparent unmarked).
        if (!parent_node.style.layout_isolation) {
            var p = parent_node.parent;
            while (p) |ancestor| {
                if (ancestor.frame_state.state_bits.dirty.core.subtree_layout and ancestor.frame_state.state_bits.dirty.core.subtree_render and ancestor.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
                ancestor.frame_state.state_bits.dirty.core.subtree_layout = true;
                ancestor.frame_state.state_bits.dirty.core.subtree_render = true;
                ancestor.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
                if (ancestor.style.layout_isolation) break;
                p = ancestor.parent;
            }
        }
    }
}

/// Mark runtime indices dirty (registry/focus order/interaction entries) for structural changes.
/// Separate from normal layout dirty to avoid full-tree runtime index rebuild on mere position/size
/// changes.
pub fn markRuntimeIndexDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    if (!self.frame_state.state_bits.dirty.runtime.dirty) {
        self.frame_state.state_bits.dirty.runtime.dirty = true;
    }
    bubbleChildRuntimeIndexDirty(self, false);
}

pub fn markRuntimeIndexFullRebuild(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    markRuntimeIndexDirty(self);
    if (!self.frame_state.state_bits.dirty.runtime.full_rebuild) {
        self.frame_state.state_bits.dirty.runtime.full_rebuild = true;
    }
    bubbleChildRuntimeIndexDirty(self, true);
}

pub fn markOrderDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    if (!self.frame_state.state_bits.dirty.pipeline.order) {
        self.frame_state.state_bits.dirty.pipeline.order = true;
    }
    if (!self.frame_state.state_bits.dirty.pipeline.subtree_order) {
        self.frame_state.state_bits.dirty.pipeline.subtree_order = true;
    }

    var p = self.parent;
    while (p) |parent| {
        const had_dirty = parent.frame_state.state_bits.dirty.pipeline.subtree_order;
        parent.frame_state.state_bits.dirty.pipeline.subtree_order = true;
        if (had_dirty) break;
        p = parent.parent;
    }
}

pub fn markInteractionDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    bumpLooseInteractionGen();
    self.invalidateCustomClipGeometryCache();
    if (!self.frame_state.state_bits.dirty.pipeline.interaction) {
        self.frame_state.state_bits.dirty.pipeline.interaction = true;
    }
    self.frame_state.state_bits.dirty.hit.geometry = true;
    self.frame_state.state_bits.dirty.hit.semantics = true;
    if (!self.frame_state.state_bits.dirty.pipeline.subtree_interaction) {
        self.frame_state.state_bits.dirty.pipeline.subtree_interaction = true;
    }
    redraw.requested = true;

    var p = self.parent;
    while (p) |parent| {
        const had_dirty = parent.frame_state.state_bits.dirty.pipeline.subtree_interaction;
        parent.frame_state.state_bits.dirty.pipeline.subtree_interaction = true;
        if (had_dirty) break;
        p = parent.parent;
    }
}

pub fn markHitSemanticsDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    bumpLooseInteractionGen();
    self.frame_state.state_bits.dirty.hit.semantics = true;
    markInteractionDirty(self);
}

pub fn markHitStructureDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    self.frame_state.state_bits.dirty.hit.structure = true;
    markRuntimeIndexDirty(self);
}

pub fn bubbleChildRuntimeIndexDirty(self: *Node, full_rebuild: bool) void {
    if (!self.frame_state.state_bits.dirty.runtime.subtree_dirty) {
        self.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
    }
    if (full_rebuild and !self.frame_state.state_bits.dirty.runtime.subtree_full_rebuild) {
        self.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = true;
    }

    var p = self.parent;
    while (p) |parent| {
        const had_dirty = parent.frame_state.state_bits.dirty.runtime.subtree_dirty;
        const had_full = parent.frame_state.state_bits.dirty.runtime.subtree_full_rebuild;
        parent.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
        if (full_rebuild) parent.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = true;
        if (had_dirty and (!full_rebuild or had_full)) break;
        p = parent.parent;
    }
}

/// Mark subtree dirty without marking self layout dirty. Bubble subtree_dirty upward. For scenarios
/// where only children need relayout, not self. Example: VirtualList's content_node with all
/// absolute-positioned children; after rebind, only recursively relayout dirty children without
/// re-running content_node's own layoutChildren.
pub fn markSubtreeDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    if (self.frame_state.state_bits.dirty.core.subtree_layout and self.frame_state.state_bits.dirty.core.subtree_render) return;
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.core.subtree_layout = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    redraw.requested = true;

    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.dirty.core.subtree_layout and parent.frame_state.state_bits.dirty.core.subtree_render and parent.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
        parent.frame_state.state_bits.dirty.core.subtree_layout = true;
        parent.frame_state.state_bits.dirty.core.subtree_render = true;
        parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
        if (parent.style.layout_isolation) break;
        p = parent.parent;
    }
}

pub fn markCompositeDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    const self_out_of_band = isOutOfBandRenderUnit(self);
    const self_needs_render_dirty = self.meta.per_frame.caches.commands.promoted == null and !self_out_of_band;
    var bubble_render_dirty = true;
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.pipeline.composite = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    if (self_needs_render_dirty) {
        self.frame_state.state_bits.dirty.core.render = true;
        self.frame_state.state_bits.dirty.core.subtree_render = true;
    }
    redraw.requested = true;

    // subtree_render bubbles per-hop: out-of-band hop (child is out-of-band unit for parent)
    // doesn't
    // mark parent, but **continues upward**; higher cached ancestors still hold child's old
    // commands
    // (scheme §5.4 C3). Old impl stopped bubbling entirely at first out-of-band hop, leaving
    // promoted/legacy ancestors permanently replaying old frames (V2).
    var child: *Node = self;
    var p = self.parent;
    while (p) |parent| {
        const had_composite_dirty = parent.frame_state.state_bits.dirty.pipeline.subtree_composite;
        const had_render_dirty = parent.frame_state.state_bits.dirty.core.subtree_render;
        parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
        if (bubble_render_dirty) {
            if (!isOutOfBandRenderUnit(child)) {
                parent.frame_state.state_bits.dirty.core.subtree_render = true;
            }
            // layout_isolation as render dirty boundary (consistent with markLayoutDirty).
            if (parent.style.layout_isolation) {
                bubble_render_dirty = false;
            }
        }
        if (had_composite_dirty and (!bubble_render_dirty or had_render_dirty)) break;
        child = parent;
        p = parent.parent;
    }
}

/// **Single authoritative** invalidation combo after a composite-property (opacity/translate/
/// scale/rotate) animation write: interaction (hit-test geometry) + composite (layer props/
/// recompose) + invalidateRenderCache (content version, prevents stale promoted/payload).
/// All animation drivers (transition tick, node_animator, hooks before_render) and Node setters
/// must converge here; separate per-path dirty marking misses composite or cache invalidation and
/// causes visual bugs during animation.
pub fn markCompositePropDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    markInteractionDirty(self);
    markCompositeDirty(self);
    @import("node_render_cache.zig").invalidateRenderCache(self);
}

/// Combo for **per-frame animation driving** of composite props: interaction + composite,
/// **does not** bump content version. Frame content is unchanged, only layer props change; bumping
/// content version would invalidate canReusePromotedSurface every frame, killing surface reuse
/// during animation (text shimmer + full rebuild). Use markCompositePropDirty for one-shot writes
/// (positioning, setters, state switches); use this for per-frame interpolation. No manual dirty
/// combos outside these two named ones.
pub fn markCompositeAnimFrameDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    markInteractionDirty(self);
    markCompositeDirty(self);
}

/// Advances whenever a hit layer moves (markHitLayerMotion*). Hit-index consumers that cache a
/// query result against the scene (stationary-pointer hover) compare
/// `HitRuntime.sceneEpoch()`, which folds this in: a layer move changes what a fixed world point
/// resolves to without any rebuild.
pub var g_hit_layer_motion_gen: u64 = 0;

/// Own-transform change (scroll offset) of a node, interaction part only: the hit-layer
/// counterpart of markInteractionDirty. A hit layer's subtree is stored in its own local space and
/// queried through its live transform (hit_runtime.HitLayer), so the move needs no rebuild; only
/// the scene epoch advances. Any other node falls back to markInteractionDirty.
pub fn markHitLayerMotion(self: *Node) void {
    if (!self.behavior.interaction.hit_layer) return markInteractionDirty(self);
    @import("node_tree.zig").hostDirty(self);
    self.invalidateCustomClipGeometryCache();
    g_hit_layer_motion_gen +%= 1;
    redraw.requested = true;
}

/// markCompositeAnimFrameDirty for an own-transform change: hit part via markHitLayerMotion.
pub fn markHitLayerMotionAnimFrameDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    markHitLayerMotion(self);
    markCompositeDirty(self);
}

/// markCompositePropDirty for an own-transform change: hit part via markHitLayerMotion.
pub fn markHitLayerMotionPropDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    markHitLayerMotion(self);
    markCompositeDirty(self);
    @import("node_render_cache.zig").invalidateRenderCache(self);
}

/// Out-of-band render unit: whether `self` is **excluded from replay and freshly redrawn** when its
/// **immediate parent's** cache replays. If so, self's render dirty need not invalidate the parent
/// (prevents overlay flicker from forcing the parent's legacy overflow snapshot to rebuild per
/// frame).
///
/// Criteria must match the render side line by line:
///   - legacy overflow replay (tryReplayLegacyOverflowCacheHit) excludes all z>0 direct children
///     (appendLegacyCachedCommandsWithoutEscapedOverlays), then renderOverlayChildrenAfterCacheHit
///     redraws them by `!use_opacity_layer`; legacy cache is used only when the parent has no
///     effect (-> no opacity layer).
///   - promoted replay (tryReplayPromotedCacheHit) replays the whole span and **doesn't** exclude
///     or
///     redraw z>0 children (a promoted node opens a surface -> use_opacity_layer). So when the
///     parent
///     holds a promoted cache, self is not out-of-band and must invalidate the parent. Read the
///     parent's **actually held** cache, not a "will it open a layer" heuristic: opacity=1 promoted
///     parents (composited_group/will_change) would be misclassified.
///   - parents with opacity < 0.999 use normal bubbling: they open an opacity layer with no legacy
///     cache, so bubbling is conservative.
///
/// This is a **one-hop** check only. Out-of-band != "skip whole ancestor chain": cached ancestors
/// above the parent (promoted spans, legacy snapshots) still hold self's old commands; the bubble
/// must skip this hop and continue up (per-hop loop in markRenderDirty / markCompositeDirty).
pub fn isOutOfBandRenderUnit(self: *const Node) bool {
    const parent = self.parent orelse return false;
    if (self.style.z_index() <= 0) return false;
    if (std.math.clamp(parent.getOpacity(), 0.0, 1.0) < 0.999) return false;
    if (parent.meta.per_frame.caches.commands.promoted != null) return false;
    return true;
}

/// subtree_render bubble when an out-of-band unit is itself render-dirty: judged per hop. An
/// out-of-band hop doesn't mark the parent but continues up; a normal hop marks and stops at an
/// already-dirty ancestor (it already bubbled by the same rule; the per-hop judgment depends only
/// on
/// the (child, parent) pair, not the path taken); layout_isolation is a boundary. Cost is
/// O(ancestor
/// depth), same order as the subtree_composite bubble; idle frames skip this.
fn bubbleSubtreeRenderAcrossOutOfBandHops(self: *Node) void {
    var child: *Node = self;
    var p = self.parent;
    while (p) |parent| {
        if (!isOutOfBandRenderUnit(child)) {
            if (parent.frame_state.state_bits.dirty.core.subtree_render) break;
            parent.frame_state.state_bits.dirty.core.subtree_render = true;
        }
        if (parent.style.layout_isolation) break;
        child = parent;
        p = parent.parent;
    }
}

pub fn markRenderDirty(self: *Node) void {
    @import("node_tree.zig").hostDirty(self);
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.frame_state.state_bits.dirty.core.render = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    redraw.requested = true;

    // P0-3 phase 3: push dirty directly to owner World, no longer through process-level
    // g_dirty_notify.
    markWorldDirty(self, .style);

    // Out-of-band render unit (isOutOfBandRenderUnit): parent's cache replay excludes it and
    // freshly
    // redraws, so don't mark parent's subtree_render (prevent overlay flicker from parent snapshot
    // rebuild); higher cached ancestors hold its old commands, subtree_render must hop-skip and
    // continue bubbling (scheme §5.4 C3).
    if (isOutOfBandRenderUnit(self)) {
        var p = self.parent;
        while (p) |parent| {
            if (parent.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
            parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
            if (parent.style.layout_isolation) break;
            p = parent.parent;
        }
        bubbleSubtreeRenderAcrossOutOfBandHops(self);
        return;
    }

    // Normal node: bubble subtree_render_dirty upward, stop at ancestor with layout_isolation=true
    // (consistent with markLayoutDirty/markSizingDirty): isolation node as dirty boundary lets
    // render_engine's fast-skip work outside isolation.
    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.dirty.core.subtree_render) break;
        parent.frame_state.state_bits.dirty.core.subtree_render = true;
        if (parent.style.layout_isolation) break;
        p = parent.parent;
    }
}

/// Which inheritable text properties of a node changed (see markInheritedTextDirty).
pub const InheritedTextChange = struct {
    /// text_color: read at paint (text, currentColor icons / images, custom draws).
    color: bool = false,
    /// text_font_size / text_font_weight: read by layout **and** paint (Node.resolveTextProps).
    metrics: bool = false,

    pub fn any(self: InheritedTextChange) bool {
        return self.color or self.metrics;
    }

    /// The inheritable text fields a box style carries.
    pub fn of(s: types.BoxStyle) InheritedTextChange {
        return .{ .color = s.text_color != null, .metrics = s.font_size != null or s.font_weight != null };
    }
};

/// The node's inheritable text properties (text_color / text_font_size / text_font_weight) changed.
/// Every text that resolves them (the node itself included, its own StyleExt value applies to it)
/// and every descendant reading them is otherwise clean, so a parent repaint would replay cached
/// commands and layout would reuse cached measurements with the old values:
/// - size / weight: text re-measures (markSizingDirty: new content version drops its intrinsic
///   cache entry, the ancestors re-lay out) — unless the text declares both itself;
/// - color: text, currentColor icons / images and custom draws (DrawContext.current_color)
///   repaint.
pub fn markInheritedTextDirty(self: *Node, change: InheritedTextChange) void {
    @import("node_tree.zig").hostDirty(self);
    if (!change.any()) return;
    markInheritedTextReader(self, change);
    markInheritedTextDescendants(self, change);
}

fn markInheritedTextDescendants(self: *Node, change: InheritedTextChange) void {
    for (self.children.items) |child| {
        markInheritedTextReader(child, change);
        markInheritedTextDescendants(child, change);
    }
}

fn markInheritedTextReader(node: *Node, change: InheritedTextChange) void {
    if (change.metrics) if (node.getText()) |t| if (!(t.font_size_set and t.font_weight_set)) {
        markSizingDirty(node);
        return;
    };
    if (change.color and readsInheritedColor(node)) markRenderDirty(node);
}

fn readsInheritedColor(node: *const Node) bool {
    if (node.meta.per_frame.custom_hooks.draw != null) return true;
    if (node.getText() != null) return true;
    if (node.getIcon()) |ic| return ic.tint_current_color;
    if (node.getImage()) |im| return im.tint_current_color;
    return false;
}

/// markRenderDirty + track render reason (DevTools trace).
pub fn markRenderDirtyTracked(self: *Node, reason: debug_trace.RenderReason, comptime source: []const u8) void {
    @import("node_tree.zig").hostDirty(self);
    markRenderDirty(self);
    debug_trace.maybeRecordRender(self.id, reason, source);
}
