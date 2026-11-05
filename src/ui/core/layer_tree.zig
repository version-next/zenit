//! LayerTree: retained composite layers.
//!
//! Plan layers keyed by (root_node_id, effect_kind) persist cross-frame (plan_by_node):
//! planAppendLayer hit updates the descriptor in place and preserves surface_valid,
//! planClear clears ops/ordinal indices, exit is driven by plan_epoch sweep.
//! **Cross-frame identity = CompositedLayer.stable_id** (LayerId packed raw, generation
//! provides ABA protection); layer_id is frame-local only (ops/planMark* use it).
//! Content cache carrier is the Node-side command cache (caches.commands.promoted);
//! surface_valid is derived by canReusePromotedSurface (stable_id+content_version+transform).
//!
//! Design reference:
//! - Chromium cc::LayerImpl + PaintArtifactCompositor::LayerizeGroup
//! - Flutter Layer / EngineLayer
//! - WebKit GraphicsLayer
//! Pitfalls avoided:
//! - don't let Layer carry geometry + content + semantics (cc::Layer 18-bool lesson)
//!   -> Layer holds (gpu_texture_handle, transform_id, clip_id, effect_id, scroll_id, chunks)
//! - don't linear-scan for layer by id (O(N*M))
//!   -> AutoHashMap by layer_id; iterate with ArrayList
//! - don't create one layer per chunk (memory explosion)
//!   -> thresholds: min_area / max_layer_count; merge if below
//! Layer promotion: see shouldPromoteLayer: backdrop_blur / composited_group /
//! text+transform animation / will_change / overlay candidate / rounded_clip animation.
//! Note: non-overlay normal transform animation is not promoted; scroll is unimplemented.
//! Not yet: filter, mask, blend-mode, 3D transform.

const std = @import("std");
const id_hash = @import("id_hash.zig");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const paint_table_mod = @import("paint_table.zig");
const property_tree_mod = @import("property_tree.zig");
const types = @import("types.zig");
const scene_runtime_mod = @import("scene_runtime.zig");
const display_list_mod = @import("display_list.zig");

pub const ElementId = element_id_mod.ElementId;
pub const PaintChunk = paint_table_mod.PaintChunk;
pub const PropertyStateRef = paint_table_mod.PropertyStateRef;
pub const Bounds = paint_table_mod.Bounds;
pub const ComputedRect = types.ComputedRect;
pub const EffectKind = property_tree_mod.EffectKind;
pub const INVALID_ID = property_tree_mod.INVALID_ID;

/// Layer promotion reason, for debug/devtools display.
pub const PromotionReason = enum(u8) {
    root,
    transform_animating,
    opacity_animating,
    scroll,
    will_change,
    filter, // Phase 6+
    mask,
    blend_mode,
    transform_3d,
};

pub const LayerId = packed struct(u32) {
    index: u24,
    generation: u8,

    pub const NULL: LayerId = .{ .index = 0xFFFFFF, .generation = 0xFF };

    pub fn isNull(self: LayerId) bool {
        return self.index == 0xFFFFFF;
    }

    pub fn eql(a: LayerId, b: LayerId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Layer frame state machine (replaces CompositorPlan.LayerFlags).
/// Marked by render_engine during paint pass; devtools/hit-test read.
pub const LayerFrameFlags = packed struct(u8) {
    /// Is surface content still valid (not invalidated by dirty mark).
    surface_valid: bool = false,
    /// Did this frame hit and reuse existing promoted surface.
    reused_this_frame: bool = false,
    /// Did this frame rebuild promoted surface content.
    rebuilt_this_frame: bool = false,
    /// Is surface invalidated this frame due to descendant content change.
    invalidated_by_descendant_this_frame: bool = false,
    /// Is surface invalidated this frame due to root node change.
    invalidated_by_self_this_frame: bool = false,
    /// Hit candidate for localized rebuild (descendants invalid and subtree still has promoted).
    descendant_scoped_rebuild_candidate_this_frame: bool = false,
    _reserved: u2 = 0,
};

/// Surface invalidation reason.
pub const SurfaceInvalidationReason = enum {
    self,
    descendant,
};

/// Single composite layer.
pub const Layer = struct {
    /// Root ElementId that created/reused this layer (debug + reconcile).
    root_element: ElementId = ElementId.NULL,
    /// Parent layer.
    parent: LayerId = LayerId.NULL,
    /// Promotion reason.
    reason: PromotionReason = .root,
    /// References PropertyTree's 4 trees (determine layer's transform/clip/effect/scroll).
    property_state: PropertyStateRef = .NONE,
    /// GPU surface handle (from ResourcePool; NULL = share parent's surface).
    /// Not consumed by the production renderer; see below.
    ///
    /// This does **not** mean there is no GPU reuse. Reuse takes a separate path:
    /// SceneRuntime.promoted_surface_flags (rebuilt/reused/surface_valid) plus the offscreen
    /// texture
    /// pool. A promoted surface is reused cross-frame while content is unchanged (regression test:
    /// popover.zig 'scale_fade open animation reuses promoted surface').
    ///
    /// What is saved:
    /// - CPU: on a promoted surface cache hit, render_engine/mod.zig **directly splices the
    ///   previous
    ///   frame's commands**, no subtree retrace. Offscreen textures are reused cross-frame by size
    ///   (offscreen_texture.zig REUSE_LAG_FRAMES+LRU), no per-frame create/destroy.
    /// - GPU: by **layer identity** (`CompositedLayer.stable_id`) a layer holds a dedicated texture
    ///   and
    ///   skips content commands when unchanged, leaving one composite draw with transform/opacity.
    ///   Implemented in render/offscreen_texture.zig (retained ownership) +
    ///   render/opacity_layer.zig (tryBeginRetainedOpacityLayer).
    ///   - damage_rect clip repaint: encoder per-item fingerprint diff finds the damage region,
    ///     then load+scissor+clear partial repaint (incl. non-flat: path/clip/nested opacity fold +
    ///     scissor stack). addDamage reports flow into the damage region (captureLayerTreeDamage);
    ///     the encoder decision is written back via noteEncoderOutcome to
    ///     damage_rect/needs_repaint.
    ///
    /// WARNING: the cache key is **not** content_version (only the root node's own version;
    /// descendant changes don't bump it) but the encoder's content fingerprint of the actual
    /// commands to encode, see computeRetainedContentHashes.
    ///
    /// Fields gpu_texture_handle and damage_rect / needs_repaint are still not consumed by the
    /// production renderer: the implementation uses a separate encoder-side path (stable_id lookup
    /// in
    /// the offscreen pool) with no reverse writeback to LayerTree. Kept to preserve design intent.
    gpu_texture_handle: u64 = 0,
    /// Which PaintChunks included (by ElementId; same element's chunks).
    /// Simple ArrayList, limited count (avg < 100 chunks per actual layer).
    chunk_elements: std.ArrayListUnmanaged(ElementId),
    /// world-space envelope bounds.
    world_bounds: Bounds = .ZERO,
    /// Accumulated damage rect this frame (local space; GPU encoder repaints only this).
    damage_rect: Bounds = .ZERO,
    /// Last paint epoch; validated when layerize reuses layer.
    repaint_epoch: u64 = 0,
    /// Retained plan: last plan_epoch this layer hit planAppendLayer.
    /// Sweep destroys plan layers not matching current epoch.
    plan_seen_epoch: u64 = 0,
    /// Does frame need repaint (false = full cache hit, compose only).
    needs_repaint: bool = false,
    /// GPU encoder writeback (observation only, kept separate from the damage_rect production
    /// path: writing into damage_rect would, in production where nobody calls beginFrame, be
    /// mistaken by the next frame's captureLayerTreeDamage for a producer-side report and form a
    /// whole-layer dirty-region feedback loop). Values: 0=no retained decision this frame,
    /// 1=cache hit, 2=full-layer repaint, 3=partial repaint.
    /// rect = local space {min_x,min_y,max_x,max_y}. Written to encoder_repaint_kind /
    /// encoder_damage_rect, separate from addDamage production.
    /// Encoder's captureLayerTreeDamage consumes (consume-clear).
    encoder_repaint_kind: u8 = 0,
    /// Encoder's actual repaint region (local; kind=3 is damage, =2 is whole).
    encoder_damage_rect: Bounds = .ZERO,
    /// Alive flag, set false after destroy pending epoch cleanup.
    alive: bool = true,
    /// Replaces CompositorPlan's frame state machine.
    frame_flags: LayerFrameFlags = .{},
    /// P1.6' (2026-05-01): CompositorPlan per-frame descriptor inlined.
    /// CompositorPlan.appendLayer mirrored here; prefer tree.get(id).composited
    /// over plan.layers.items[plan_id]. null = plan didn't create (layerize did).
    composited: ?CompositedLayer = null,

    pub fn deinit(self: *Layer, allocator: std.mem.Allocator) void {
        self.chunk_elements.deinit(allocator);
    }
};

/// LayerTree configuration.
pub const LayerTreeConfig = struct {
    /// Minimum area per layer (merged to parent if below).
    min_layer_area_px2: f32 = 64.0 * 64.0,
    /// Global layer count limit (downgrades promotion if exceeded).
    max_layer_count: u32 = 256,
};

pub const LayerTree = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayListUnmanaged(Layer),
    generations: std.ArrayListUnmanaged(u8),
    free_list: std.ArrayListUnmanaged(u24),
    /// Reverse query: element -> layer (find which layer an element belongs to).
    element_to_layer: std.AutoHashMapUnmanaged(u32, LayerId),
    /// Root layer.
    root: LayerId = LayerId.NULL,
    config: LayerTreeConfig,
    /// P1.8' (2026-05-01): composite ops this frame. Moved from CompositorPlan.ops.
    /// frame_clear() clears between frames; plan API appendOp/findXxxOp access here.
    frame_ops: std.ArrayList(CompositeOp),
    /// P1.9' (2026-05-01): plan_layer_id (sequence) -> LayerId this frame.
    /// Moved from CompositorPlan.tree_layer_ids.
    frame_layer_ids: std.ArrayList(LayerId),
    /// Retained plan identity: (root_node_id, effect_kind) -> persistent LayerId.
    /// On planAppendLayer hit, **reuse** tree layer (update descriptor in place,
    /// preserve surface_valid); on miss, createLayer. Epoch sweep destroys entries
    /// not this frame. Layer identity stable cross-frame.
    plan_by_node: std.AutoHashMapUnmanaged(u64, LayerId) = .{},
    /// plan frame epoch (planBuildFromPropertyTree increments, sweeps exits).
    plan_epoch: u64 = 0,
    /// root_node_id -> first/last plan_layer_id of this frame with that root, and
    /// `frame_root_next[plan_layer_id]` links the rest in append order. The render
    /// passes query a root's plan state for every node every frame
    /// (`planQueryRootNode`); scanning all plan layers per node made that
    /// O(nodes x layers). Cleared with the plan in `planClear`.
    frame_root_chains: id_hash.U32HashMapUnmanaged(RootChain) = .{},
    frame_root_next: std.ArrayList(u32) = .empty,
    /// Plan layers appended this frame with a promotion reason. While it is zero no
    /// node has a promoted layer, so the per-node promoted-state passes would only
    /// rewrite the defaults `appendRetainedMetadata` already stored.
    frame_promoted_count: u32 = 0,

    const RootChain = struct { head: u32, tail: u32 };

    pub fn init(allocator: std.mem.Allocator, config: LayerTreeConfig) LayerTree {
        return .{
            .allocator = allocator,
            .layers = .empty,
            .generations = .empty,
            .free_list = .empty,
            .element_to_layer = .{},
            .config = config,
            .frame_ops = .empty,
            .frame_layer_ids = .empty,
        };
    }

    pub fn deinit(self: *LayerTree) void {
        for (self.layers.items) |*l| {
            if (l.alive) l.deinit(self.allocator);
        }
        self.layers.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.element_to_layer.deinit(self.allocator);
        self.frame_ops.deinit(self.allocator);
        self.frame_layer_ids.deinit(self.allocator);
        self.plan_by_node.deinit(self.allocator);
        self.frame_root_chains.deinit(self.allocator);
        self.frame_root_next.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createLayer(self: *LayerTree, root_element: ElementId, reason: PromotionReason, parent: LayerId) !LayerId {
        // Generation retirement (ABA prevention): slots reaching MAX_GEN retire
        // permanently. The alive bit cannot stop ABA after reuse: a reused slot has alive=true,
        // and once generation wraps it falsely matches a stale LayerId. Slots reaching MAX_GEN
        // (= NULL's generation) retire permanently. Both
        // create/destroy sides increment and must check.
        while (self.free_list.pop()) |idx| {
            const next_gen = self.generations.items[idx] +% 1;
            if (next_gen == element_id_mod.MAX_GEN) {
                self.generations.items[idx] = element_id_mod.MAX_GEN;
                continue;
            }
            self.layers.items[idx] = .{
                .root_element = root_element,
                .parent = parent,
                .reason = reason,
                .chunk_elements = .empty,
            };
            self.generations.items[idx] = next_gen;
            return .{ .index = idx, .generation = next_gen };
        }

        const idx = self.layers.items.len;
        if (idx >= 0xFFFFFF) return error.LayerTreeFull;

        // layers and generations must match: isAlive filters by layers.len first,
        // then reads generations[idx]. Two fallible appends used to leave generation
        // missing, next isAlive crashes. Reserve both first, then append zero-fail.
        try self.layers.ensureUnusedCapacity(self.allocator, 1);
        try self.generations.ensureUnusedCapacity(self.allocator, 1);
        self.layers.appendAssumeCapacity(.{
            .root_element = root_element,
            .parent = parent,
            .reason = reason,
            .chunk_elements = .empty,
        });
        self.generations.appendAssumeCapacity(0);

        const id: LayerId = .{ .index = @intCast(idx), .generation = 0 };
        if (parent.isNull() and self.root.isNull()) self.root = id;
        return id;
    }

    /// GPU handle release callback (u64 for ResourceHandle.raw, avoid import).
    pub const GpuReleaseFn = *const fn (ctx: *anyopaque, handle: u64) void;

    pub fn destroyLayer(self: *LayerTree, id: LayerId) void {
        self.destroyLayerWithRelease(id, null, null);
    }

    /// Destroy layer and pass GPU handle to caller via callback (ResourcePool.release).
    /// null callback: pointer discarded in LayerTree only; caller owns cleanup.
    pub fn destroyLayerWithRelease(
        self: *LayerTree,
        id: LayerId,
        release_cb: ?GpuReleaseFn,
        release_ctx: ?*anyopaque,
    ) void {
        const layer = self.getMut(id) orelse return;
        // Remove element_to_layer reverse entry.
        for (layer.chunk_elements.items) |elem_id| {
            _ = self.element_to_layer.remove(elem_id.raw());
        }
        // Release GPU resources.
        if (layer.gpu_texture_handle != 0) {
            if (release_cb) |cb| {
                cb(release_ctx orelse undefined, layer.gpu_texture_handle);
            }
            layer.gpu_texture_handle = 0;
        }
        layer.deinit(self.allocator);
        layer.alive = false;
        self.generations.items[id.index] +%= 1;
        if (self.root.eql(id)) self.root = LayerId.NULL;
        // Generation retirement: slots reaching MAX_GEN skip free_list (see createLayer).
        if (self.generations.items[id.index] == element_id_mod.MAX_GEN) return;
        // Safe fallback: free_list is slot reuse pool, OOM leaks index but generation
        // incremented, stale LayerId correctly rejected by isValid.
        self.free_list.append(self.allocator, id.index) catch {};
    }

    /// Set layer's GPU texture handle (caller allocated via ResourcePool).
    pub fn setGpuTextureHandle(self: *LayerTree, id: LayerId, handle: u64) void {
        if (self.getMut(id)) |l| l.gpu_texture_handle = handle;
    }

    pub fn gpuTextureHandle(self: *const LayerTree, id: LayerId) u64 {
        if (self.get(id)) |l| return l.gpu_texture_handle;
        return 0;
    }

    pub fn isAlive(self: *const LayerTree, id: LayerId) bool {
        if (id.isNull()) return false;
        if (id.index >= self.layers.items.len) return false;
        if (self.generations.items[id.index] != id.generation) return false;
        return self.layers.items[id.index].alive;
    }

    pub fn get(self: *const LayerTree, id: LayerId) ?*const Layer {
        if (!self.isAlive(id)) return null;
        return &self.layers.items[id.index];
    }

    pub fn getMut(self: *LayerTree, id: LayerId) ?*Layer {
        if (!self.isAlive(id)) return null;
        return &self.layers.items[id.index];
    }

    /// Assign element to layer (called by layerize pass).
    pub fn assignElement(self: *LayerTree, layer_id: LayerId, element: ElementId) !void {
        const layer = self.getMut(layer_id) orelse return;
        // Reserve reverse map capacity first: append success then put failure leaves
        // element on layer unfindable.
        try self.element_to_layer.ensureUnusedCapacity(self.allocator, 1);
        try layer.chunk_elements.append(self.allocator, element);
        self.element_to_layer.putAssumeCapacity(element.raw(), layer_id);
    }

    pub fn layerOf(self: *const LayerTree, element: ElementId) ?LayerId {
        return self.element_to_layer.get(element.raw());
    }

    /// Convert chunk dirty to layer damage rect (paint pass after layerize).
    /// Since 2026-07-30, GPU encoder consumes: on retained miss with diff damage,
    /// reported rect merged into partial repaint scissor (see
    /// command_encoder.captureLayerTreeDamage / opacity_layer.computePartialDamage).
    pub fn addDamage(self: *LayerTree, layer_id: LayerId, rect: Bounds) void {
        const layer = self.getMut(layer_id) orelse return;
        layer.damage_rect = layer.damage_rect.unionWith(rect);
        layer.needs_repaint = true;
    }

    /// GPU encoder writeback (damage merged 2026-07-30): retained layer's actual
    /// repaint decision. kind: 0=cache 1=full 2=partial. rect = local
    /// {min_x,min_y,max_x,max_y}. Write encoder_repaint_kind / encoder_damage_rect
    /// (obs), separate from addDamage, consumed by captureLayerTreeDamage (consume-clear).
    pub fn noteEncoderOutcome(self: *LayerTree, stable_id: u32, kind: u8, rect: [4]f32) void {
        for (self.layers.items) |*l| {
            if (!l.alive) continue;
            const comp = l.composited orelse continue;
            if (comp.stable_id != stable_id) continue;
            switch (kind) {
                0 => {
                    l.encoder_repaint_kind = 1;
                    l.encoder_damage_rect = .ZERO;
                },
                1 => {
                    l.encoder_repaint_kind = 2;
                    l.encoder_damage_rect = .{ .min_x = rect[0], .min_y = rect[1], .max_x = rect[2], .max_y = rect[3] };
                },
                2 => {
                    l.encoder_repaint_kind = 3;
                    l.encoder_damage_rect = .{ .min_x = rect[0], .min_y = rect[1], .max_x = rect[2], .max_y = rect[3] };
                },
                else => {},
            }
            return;
        }
    }

    /// Frame start: clear all layers' damage / needs_repaint.
    pub fn beginFrame(self: *LayerTree) void {
        for (self.layers.items) |*l| {
            if (!l.alive) continue;
            l.damage_rect = .ZERO;
            l.needs_repaint = false;
            // Clear frame_flags between frames (replaces CompositorPlan.clear): preserve
            // surface_valid (cross-frame cache state), recalculate rest each frame.
            const sv = l.frame_flags.surface_valid;
            l.frame_flags = .{};
            l.frame_flags.surface_valid = sv;
        }
    }

    /// Replaces CompositorPlan.markLayerSurfaceInvalidated.
    pub fn markLayerSurfaceInvalidated(self: *LayerTree, id: LayerId, reason: SurfaceInvalidationReason) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.surface_valid = false;
            switch (reason) {
                .self => l.frame_flags.invalidated_by_self_this_frame = true,
                .descendant => l.frame_flags.invalidated_by_descendant_this_frame = true,
            }
        }
    }

    /// Replaces CompositorPlan.markLayerSurfaceReused, with the same semantics:
    /// surface_valid=true, reused=true, clears rebuilt/invalidated_*/descendant_scoped.
    pub fn markLayerSurfaceReused(self: *LayerTree, id: LayerId) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.surface_valid = true;
            l.frame_flags.reused_this_frame = true;
            l.frame_flags.rebuilt_this_frame = false;
            l.frame_flags.invalidated_by_descendant_this_frame = false;
            l.frame_flags.invalidated_by_self_this_frame = false;
            l.frame_flags.descendant_scoped_rebuild_candidate_this_frame = false;
        }
    }

    /// Replaces CompositorPlan.markLayerSurfaceRebuilt.
    /// Semantics: surface_valid=true, rebuilt=true, clear reused/descendant_scoped.
    pub fn markLayerSurfaceRebuilt(self: *LayerTree, id: LayerId) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.surface_valid = true;
            l.frame_flags.reused_this_frame = false;
            l.frame_flags.rebuilt_this_frame = true;
            l.frame_flags.descendant_scoped_rebuild_candidate_this_frame = false;
        }
    }

    /// Replaces CompositorPlan.markLayerDescendantScopedRebuildCandidate.
    pub fn markLayerDescendantScopedRebuildCandidate(self: *LayerTree, id: LayerId) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.descendant_scoped_rebuild_candidate_this_frame = true;
        }
    }

    pub fn liveLayerCount(self: *const LayerTree) u32 {
        var c: u32 = 0;
        for (self.layers.items) |l| {
            if (l.alive) c += 1;
        }
        return c;
    }

    // Compositor plan API (P1.10' 2026-05-01: absorbed from CompositorPlan struct):
    //
    // History: original CompositorPlan struct was thin facade (held *LayerTree ref), all 13 methods
    // forwarded to LayerTree. P1.10' moved methods directly to LayerTree, deleted facade.
    // Conflicting markLayer*Surface* methods use 'plan' prefix to distinguish (plan-layer-id path
    // vs direct LayerId path).

    pub const RootLayerState = struct {
        has_plan_layer: bool = false,
        promoted_layer_id: u32 = INVALID_ID,
        /// Cross-frame stable identity (CompositedLayer.stable_id); cache and compare use it.
        promoted_layer_stable_id: u32 = INVALID_ID,
        frame_flags: LayerFrameFlags = .{},
    };

    pub const EffectPlanState = struct {
        has_plan_layer: bool = false,
        layer_id: u32 = INVALID_ID,
        /// This frame's plan layer (borrowed from the tree: valid until the next plan build).
        /// By reference: a CompositedLayer carries glass parameters (~700 bytes) and plan
        /// states are copied per node.
        layer: ?*const CompositedLayer = null,
        begin_bounds: ?ComputedRect = null,
        draw_opacity: ?f32 = null,
        has_end_surface: bool = false,
        apply_clip_bounds: ?ComputedRect = null,
        apply_clip_shape_kind: display_list_mod.ClipShapeKind = .rect,
        /// TL, TR, BR, BL (.rounded_rect only).
        apply_clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
        /// The apply_clip op's polygon (this frame's plan; null when it has none). By reference:
        /// plan states are copied per node, and a polygon is most of their size.
        apply_clip_polygon: ?*const display_list_mod.ClipPolygon = null,
        apply_clip_bounds_fallback: bool = false,

        pub fn hasCompleteSurfaceBridge(self: EffectPlanState) bool {
            return self.has_plan_layer and
                self.layer != null and
                self.begin_bounds != null and
                self.has_end_surface;
        }

        fn setApplyClip(self: *EffectPlanState, clip: *const ApplyClipOp) void {
            self.apply_clip_bounds = clip.bounds;
            self.apply_clip_shape_kind = clip.shape_kind;
            self.apply_clip_radii = clip.radii;
            self.apply_clip_polygon = &clip.polygon;
            self.apply_clip_bounds_fallback = clip.bounds_fallback;
        }

        pub fn hasPlanClipBridge(self: EffectPlanState) bool {
            return self.apply_clip_bounds != null;
        }
    };

    pub const NodePlanState = struct {
        root: RootLayerState = .{},
        effect: EffectPlanState = .{},
        promoted_layer_id: u32 = INVALID_ID,
        promoted_layer_stable_id: u32 = INVALID_ID,
        frame_flags: LayerFrameFlags = .{},
        needs_rect_clip_fallback: bool = false,
        clip_bounds_fallback: bool = false,
    };

    /// Get LayerId for this frame's plan_layer_id.
    /// Internal; externals read plan-layer data via planCompositedAt / etc.
    fn planTreeLayerOf(self: *const LayerTree, plan_layer_id: u32) LayerId {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return LayerId.NULL;
        return self.frame_layer_ids.items[plan_layer_id];
    }

    /// Get frame_flags for plan_layer_id.
    pub fn planFrameFlagsOf(self: *const LayerTree, plan_layer_id: u32) LayerFrameFlags {
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        const tree_layer = self.get(tree_id) orelse return .{};
        return tree_layer.frame_flags;
    }

    /// Get CompositedLayer descriptor for plan_layer_id.
    pub fn planCompositedAt(self: *const LayerTree, plan_layer_id: u32) ?CompositedLayer {
        const layer = self.planCompositedPtrAt(plan_layer_id) orelse return null;
        return layer.*;
    }

    /// Borrowed form of `planCompositedAt` for scans. CompositedLayer carries
    /// glass/warp parameters and is several hundred bytes; the per-node plan
    /// queries below scan every plan layer, and copying each one out was a
    /// memcpy per (node x layer) on every frame.
    fn planCompositedPtrAt(self: *const LayerTree, plan_layer_id: u32) ?*const CompositedLayer {
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        const tree_layer = self.get(tree_id) orelse return null;
        if (tree_layer.composited) |*layer| return layer;
        return null;
    }

    /// Clear frame's plan ops and ordinal indices between frames. Retained form
    /// **no longer destroys layers**, tree layers persist (plan_by_node keyed);
    /// exit sweep done by planBuildFromPropertyTree's epoch sweep.
    pub fn planClear(self: *LayerTree) void {
        self.frame_ops.clearRetainingCapacity();
        self.frame_layer_ids.clearRetainingCapacity();
        self.frame_root_chains.clearRetainingCapacity();
        self.frame_root_next.clearRetainingCapacity();
        self.frame_promoted_count = 0;
    }

    fn planLayerKey(root_node_id: u32, kind: EffectKind) u64 {
        return (@as(u64, root_node_id) << 3) | @backingInt(kind);
    }

    pub fn planAppendLayer(self: *LayerTree, layer: CompositedLayer) !u32 {
        // Reserve capacity for all fallible ops before createLayer: no try after.
        // Old: createLayer succeeds, plan_by_node.put fails leaves active layer
        // outside plan_by_node and frame_layer_ids, epoch sweep only traverses
        // plan_by_node, never reclaimed, each failure adds one.
        try self.frame_layer_ids.ensureUnusedCapacity(self.allocator, 1);
        try self.plan_by_node.ensureUnusedCapacity(self.allocator, 1);
        try self.frame_root_next.ensureUnusedCapacity(self.allocator, 1);
        try self.frame_root_chains.ensureUnusedCapacity(self.allocator, 1);

        const id: u32 = @intCast(self.frame_layer_ids.items.len);
        var l = layer;
        l.layer_id = id;

        const key = planLayerKey(l.root_node_id, l.effect_kind);
        const tree_id: LayerId = blk: {
            if (self.plan_by_node.get(key)) |existing| {
                if (self.isAlive(existing)) break :blk existing;
            }
            const created = try self.createLayer(ElementId.NULL, .root, LayerId.NULL);
            self.plan_by_node.putAssumeCapacity(key, created);
            break :blk created;
        };

        l.stable_id = @bitCast(tree_id);
        if (self.getMut(tree_id)) |tl| {
            // Retained hit: update per-frame descriptor in place (transform/opacity/bounds).
            // frame_flags preserve cross-frame surface_valid, clear other per-frame (align
            // beginFrame).
            const sv = tl.frame_flags.surface_valid;
            tl.frame_flags = .{};
            tl.frame_flags.surface_valid = sv;
            tl.composited = l;
            tl.plan_seen_epoch = self.plan_epoch;
        }
        self.frame_layer_ids.appendAssumeCapacity(tree_id);
        self.frame_root_next.appendAssumeCapacity(INVALID_ID);
        if (l.promotion_reason.any()) self.frame_promoted_count += 1;
        const chain = self.frame_root_chains.getOrPutAssumeCapacity(l.root_node_id);
        if (chain.found_existing) {
            self.frame_root_next.items[chain.value_ptr.tail] = id;
            chain.value_ptr.tail = id;
        } else {
            chain.value_ptr.* = .{ .head = id, .tail = id };
        }
        return id;
    }

    /// planBuild end: destroy retained plan layers not in this frame.
    fn planSweepStale(self: *LayerTree) void {
        // Zero-allocate: up to 64 keys per sweep, repeat until sweep doesn't fill.
        // Old: single pass. 65+ layers exiting per frame leaves keys in map, slow cleanup
        // 64 per frame after, inflated size and traverse cost.
        while (true) {
            var stale: [64]u64 = undefined;
            var stale_count: usize = 0;
            var it = self.plan_by_node.iterator();
            while (it.next()) |entry| {
                const lid = entry.value_ptr.*;
                const layer = self.get(lid) orelse {
                    if (stale_count < stale.len) {
                        stale[stale_count] = entry.key_ptr.*;
                        stale_count += 1;
                    }
                    continue;
                };
                if (layer.plan_seen_epoch != self.plan_epoch) {
                    self.destroyLayer(lid);
                    if (stale_count < stale.len) {
                        stale[stale_count] = entry.key_ptr.*;
                        stale_count += 1;
                    }
                }
            }
            for (stale[0..stale_count]) |key| {
                _ = self.plan_by_node.remove(key);
            }
            if (stale_count < stale.len) break;
        }
    }

    fn planAppendOp(self: *LayerTree, op: CompositeOp) !void {
        try self.frame_ops.append(self.allocator, op);
    }

    /// One effect's ops (optional apply_clip + begin/end/draw triplet) max 4.
    const OPS_PER_EFFECT: usize = 4;

    fn planAppendOpAssumeCapacity(self: *LayerTree, op: CompositeOp) void {
        self.frame_ops.appendAssumeCapacity(op);
    }

    pub fn planFindLayerIdByEffectId(self: *const LayerTree, effect_id: u32) ?u32 {
        for (self.frame_layer_ids.items, 0..) |_, i| {
            const layer = self.planCompositedPtrAt(@intCast(i)) orelse continue;
            if (layer.effect_id == effect_id) return @intCast(i);
        }
        return null;
    }

    pub fn planQueryRootNode(self: *const LayerTree, root_node_id: u32) RootLayerState {
        var state = RootLayerState{};
        var best_priority: u8 = 0;
        const chain = self.frame_root_chains.get(root_node_id) orelse return state;
        var next: u32 = chain.head;
        while (next != INVALID_ID) {
            const i = next;
            next = self.frame_root_next.items[i];
            const layer = self.planCompositedPtrAt(i) orelse continue;
            std.debug.assert(layer.root_node_id == root_node_id);
            state.has_plan_layer = true;
            if (!layer.promotion_reason.any()) continue;
            const priority = promotedLayerPriority(layer);
            if (state.promoted_layer_id == INVALID_ID or priority > best_priority) {
                state.promoted_layer_id = @intCast(i);
                state.promoted_layer_stable_id = layer.stable_id;
                state.frame_flags = self.planFrameFlagsOf(@intCast(i));
                best_priority = priority;
            }
        }
        return state;
    }

    pub fn planQueryEffect(self: *const LayerTree, effect_id: u32) EffectPlanState {
        var state = EffectPlanState{};
        const layer_id = self.planFindLayerIdByEffectId(effect_id) orelse {
            if (self.findApplyClipOpForEffect(effect_id)) |clip| state.setApplyClip(clip);
            return state;
        };

        state.has_plan_layer = true;
        state.layer_id = layer_id;
        state.layer = self.planCompositedPtrAt(layer_id);

        if (self.findBeginSurfaceOp(layer_id)) |begin_op| {
            switch (begin_op) {
                .begin_surface => |begin| state.begin_bounds = begin.bounds,
                else => unreachable,
            }
        }
        if (self.findDrawSurfaceOp(layer_id)) |draw_op| {
            switch (draw_op) {
                .draw_surface => |draw| state.draw_opacity = draw.opacity,
                else => unreachable,
            }
        }
        state.has_end_surface = self.hasEndSurfaceOp(layer_id);

        if (self.findApplyClipOpForEffect(effect_id)) |clip| state.setApplyClip(clip);

        return state;
    }

    pub fn planQueryNode(
        self: *const LayerTree,
        root_node_id: u32,
        effect_id: u32,
        needs_clip: bool,
        use_rounded_clip: bool,
        clip_bounds_fallback: bool,
    ) NodePlanState {
        const root = self.planQueryRootNode(root_node_id);
        const effect = if (effect_id != INVALID_ID) self.planQueryEffect(effect_id) else EffectPlanState{};
        return .{
            .root = root,
            .effect = effect,
            .promoted_layer_id = root.promoted_layer_id,
            .promoted_layer_stable_id = root.promoted_layer_stable_id,
            .frame_flags = root.frame_flags,
            .needs_rect_clip_fallback = needs_clip and !use_rounded_clip and effect_id == INVALID_ID,
            .clip_bounds_fallback = if (effect_id != INVALID_ID) effect.apply_clip_bounds_fallback else clip_bounds_fallback,
        };
    }

    /// plan-layer-id wrapper: translate to LayerId then forward to
    /// markLayerDescendantScopedRebuildCandidate.
    pub fn planMarkLayerDescendantScopedRebuildCandidate(self: *LayerTree, plan_layer_id: u32) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerDescendantScopedRebuildCandidate(tree_id);
    }

    pub fn planMarkLayerSurfaceInvalidated(
        self: *LayerTree,
        plan_layer_id: u32,
        reason: SurfaceInvalidationReason,
    ) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerSurfaceInvalidated(tree_id, reason);
    }

    pub fn planMarkLayerSurfaceReused(self: *LayerTree, plan_layer_id: u32) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerSurfaceReused(tree_id);
    }

    pub fn planMarkLayerSurfaceRebuilt(self: *LayerTree, plan_layer_id: u32) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerSurfaceRebuilt(tree_id);
    }

    // Ops are matched in place (`*op`): a CompositeOp copy carries a whole clip polygon.
    fn findBeginSurfaceOp(self: *const LayerTree, layer_id: u32) ?CompositeOp {
        for (self.frame_ops.items) |*op| {
            switch (op.*) {
                .begin_surface => |begin| if (begin.layer_id == layer_id) return op.*,
                else => {},
            }
        }
        return null;
    }

    fn hasEndSurfaceOp(self: *const LayerTree, layer_id: u32) bool {
        for (self.frame_ops.items) |*op| {
            switch (op.*) {
                .end_surface => |end| if (end.layer_id == layer_id) return true,
                else => {},
            }
        }
        return false;
    }

    fn findDrawSurfaceOp(self: *const LayerTree, layer_id: u32) ?CompositeOp {
        for (self.frame_ops.items) |*op| {
            switch (op.*) {
                .draw_surface => |draw| if (draw.layer_id == layer_id) return op.*,
                else => {},
            }
        }
        return null;
    }

    /// Points into this frame's plan (valid until the next plan build).
    fn findApplyClipOpForEffect(self: *const LayerTree, effect_id: u32) ?*const ApplyClipOp {
        for (self.frame_ops.items) |*op| {
            switch (op.*) {
                .apply_clip => |*clip| if (clip.effect_id == effect_id) return clip,
                else => {},
            }
        }
        return null;
    }

    /// Rest position of the composite quad origin in the target frame: the owner's content frame
    /// (world transform without its own scale/rotation) places the source origin; the transient
    /// motion the owner carries in its translate (parent-local units) is taken back out.
    fn surfaceRestOrigin(
        parent_inverse: types.Transform2D,
        node_runtime: ?scene_runtime_mod.SceneNodeRuntime,
        source: ComputedRect,
    ) ?[2]f32 {
        const runtime = node_runtime orelse return null;
        const ct = runtime.content_transform;
        const world = ct.applyPoint(source.x, source.y);
        // The translate sits under the parent's linear transform, which the content frame shares.
        const m = runtime.content_motion;
        const rest = parent_inverse.applyPoint(world.x - (ct.a * m[0] + ct.c * m[1]), world.y - (ct.b * m[0] + ct.d * m[1]));
        if (!std.math.isFinite(rest.x) or !std.math.isFinite(rest.y)) return null;
        return .{ rest.x, rest.y };
    }

    pub fn planBuildFromPropertyTree(
        self: *LayerTree,
        effects: []const property_tree_mod.EffectNode,
        clips: []const property_tree_mod.ClipNode,
        transforms: []const property_tree_mod.TransformNode,
        scene_runtime: ?*const scene_runtime_mod.SceneRuntime,
    ) void {
        self.plan_epoch +%= 1;
        self.planClear();
        for (effects, 0..) |effect, i| {
            if (!effect.requires_offscreen) continue;

            const world_bounds = if (effect.transform_id < transforms.len)
                transforms[effect.transform_id].world.transformRect(effect.local_bounds)
            else
                effect.local_bounds;

            const transform = if (effect.transform_id < transforms.len) transforms[effect.transform_id] else null;
            const node_runtime = if (scene_runtime) |runtime| runtime.get(effect.node_id) else null;
            const promotion_reason = buildPromotionReason(effect, transform, node_runtime);
            const promoted = shouldPromoteLayer(effect, promotion_reason, node_runtime);

            // CA-pure: surface always uses unified draw_transform composite (src=owner-local,
            // composite=parent_inverse·owner_world). No split 'axis-aligned blit at world
            // bounds' vs 'transform composite', that fork was rest/animation seam bug source.
            // Always true.
            const has_surface_transform = true;

            // -- CA-pure composite model --
            // Unified path (no has_surface_transform fork):
            //  - surface content is lowered by owner_world^-1 to the **owner-unscaled-local** frame
            //    (see mod.zig surface_inverse=self.world.invert()): owner at (0,0), no owner
            //    scale/rotate.
            //  - so texture src region = opacity_bounds projected to the same frame =
            //    owner_world^-1 * opacity_bounds.
            //  - composite writeback = parent_inverse * owner_world (position+scale+rotate).
            //    owner_world is CA's M: places owner-local content in world + animation scale.
            //    At rest (scale=1), owner_world degenerates to Translate(owner_pos) -> exact
            //    center, no drift.
            const owner_world = if (transform) |tx| tx.world else types.Transform2D.identity();
            const owner_world_inv = owner_world.invert();
            // src = bounds projected to owner-unscaled-local (same frame as content). The texture
            // covers that rect, but GPU addImageUVWithTransform draws a **texture-local quad
            // [0,w]x[0,h]**
            // (quad origin = src top-left). So the composite matrix must map quad(0,0)=src_origin
            // to world:
            //   M = parent_inverse * owner_world * Translate(src.x, src.y)
            // owner_world has position+scale+rotate (scale around transform-origin); Translate(src)
            // aligns quad origin to src top-left. At rest, top-level parent_inverse is identity;
            // nested it becomes the world-to-parent content frame.
            const surface_source_bounds = owner_world_inv.transformRect(world_bounds);
            // A child surface composites into its nearest capturing ancestor's
            // content frame. Backdrop blur samples in place and does not open one.
            var parent_inverse = types.Transform2D.identity();
            var ancestor_id = effect.parent;
            while (ancestor_id != INVALID_ID and ancestor_id < effects.len) {
                const ancestor = effects[ancestor_id];
                if (ancestor.requires_offscreen and ancestor.kind != .backdrop_blur) {
                    if (ancestor.transform_id < transforms.len) {
                        parent_inverse = transforms[ancestor.transform_id].inverse_world;
                        // Descendant traversal excludes the owner's animated scale
                        // and rotation. Same-node effects share the owner's own frame.
                        if (ancestor.node_id != effect.node_id) {
                            if (scene_runtime) |runtime| {
                                if (runtime.get(ancestor.node_id)) |owner| parent_inverse = owner.content_transform.invert();
                            }
                        }
                    }
                    break;
                }
                ancestor_id = ancestor.parent;
            }
            const surface_draw_bounds = parent_inverse.transformRect(world_bounds);
            const surface_rotate: f32 = if (transform) |tx| tx.local.decompose().rotate else 0;
            const surface_draw_transform = parent_inverse.mul(owner_world).mul(types.Transform2D.translation(
                surface_source_bounds.x,
                surface_source_bounds.y,
            ));

            var layer = CompositedLayer{
                .root_node_id = effect.node_id,
                .content_bounds_local = effect.local_bounds,
                .surface_bounds_world = world_bounds,
                .transform_id = effect.transform_id,
                .effect_id = @intCast(i),
                .effect_kind = effect.kind,
                .opacity = effect.opacity,
                .glass = effect.glass,
                .blend_mode = effect.blend_mode,
                .warp = effect.warp,
                .corner_radius = effect.corner_radius,
                .promotion_reason = if (promoted) promotion_reason else .{},
                .has_surface_transform = has_surface_transform,
                .surface_rotate = surface_rotate,
                .surface_draw_transform = surface_draw_transform,
                .surface_parent_inverse = parent_inverse,
                .surface_source_bounds = surface_source_bounds,
                .surface_draw_bounds = surface_draw_bounds,
                .surface_rest_origin = surfaceRestOrigin(parent_inverse, node_runtime, surface_source_bounds),
            };
            if (node_runtime) |runtime| {
                layer.content_version = runtime.content_version;
                layer.flags = .{
                    .is_animating = runtime.has_active_composite_animation,
                    .contains_text = runtime.content_flags.has_text,
                };
            }

            // Effect either fully plans or fully skips: reserve all ops capacity first, create
            // layer, then zero-fail append. Old: append failure was @panic; reason was
            // begin/end/draw
            // triplet indivisible, but abort worst for editor; can't reserve = skip effect (like
            // planAppendLayer failure downgrade), triplet stays intact.
            self.frame_ops.ensureUnusedCapacity(self.allocator, OPS_PER_EFFECT) catch continue;
            const layer_id = self.planAppendLayer(layer) catch continue;
            // Just-appended plan layer alive and composited written, orelse unreachable; kept to
            // avoid frame-path unreachable. Ranks before any op append, so even if taken, just
            // 'effect not drawn', no orphan apply_clip.
            const stored_layer = self.planCompositedAt(layer_id) orelse continue;
            const can_reuse_surface = canReusePromotedSurface(stored_layer, transform, node_runtime);
            const tree_id = self.planTreeLayerOf(layer_id);
            if (!tree_id.isNull()) {
                if (can_reuse_surface) {
                    if (self.getMut(tree_id)) |tl| tl.frame_flags.surface_valid = true;
                } else if (promoted) {
                    if (node_runtime) |runtime| {
                        if (runtime.has_promoted_surface_cache) {
                            self.markLayerSurfaceInvalidated(tree_id, .self);
                        }
                    }
                }
            }

            if (node_runtime) |runtime| {
                // Surface-internal lowering omits the clip chain; apply_clip is the sole carrier of
                // the effect
                // owner's clipping: runtime.clip_id = nearest (self overflow or inherited).
                // Exception: an owner overflow_clip marked owner_wraps_children (shadow/stroke
                // outside the
                // children clip) is handled by the render-tree node-local push_clip; an apply_clip
                // pushed after
                // begin_layer would clip the owner's shadow/stroke too (Popover shadow cut to rect,
                // edge
                // stroke suppressed). apply_clip reverts to the **parent** clip; the owner still
                // inherits.
                var apply_clip_id = runtime.clip_id;
                if (apply_clip_id != INVALID_ID and apply_clip_id < clips.len and
                    effect.kind != .backdrop_blur and
                    clips[apply_clip_id].owner_wraps_children and
                    clips[apply_clip_id].node_id == runtime.node_id)
                {
                    apply_clip_id = clips[apply_clip_id].parent;
                }
                if (apply_clip_id != INVALID_ID and apply_clip_id < clips.len and runtime.effect_id == i and effect.kind != .rounded_clip) {
                    const tree_id2 = self.planTreeLayerOf(layer_id);
                    if (self.getMut(tree_id2)) |tl| {
                        if (tl.composited) |*c| c.clip_id = apply_clip_id;
                    }
                    const clip = clips[apply_clip_id];
                    self.planAppendOpAssumeCapacity(.{
                        .apply_clip = .{
                            .effect_id = @intCast(i),
                            .clip_id = apply_clip_id,
                            .bounds = clip.world_aabb,
                            .shape_kind = clip.shape_kind,
                            // Clip-owner-local corners re-indexed to the world frame of `bounds`.
                            .radii = if (clip.transform_id < transforms.len) transforms[clip.transform_id].world.orientCornerRadii(clip.radii) else clip.radii,
                            .polygon = clip.polygon,
                            .bounds_fallback = clip.bounds_fallback,
                        },
                    });
                }
            }

            // begin/end/draw_surface indivisible triplet (begin no-end / draw nonexistent
            // surface corrupts downstream compositor), capacity reserved at effect start, can't
            // fail, all-or-nothing.
            self.planAppendOpAssumeCapacity(.{ .begin_surface = .{
                .layer_id = layer_id,
                .bounds = world_bounds,
            } });
            self.planAppendOpAssumeCapacity(.{ .end_surface = .{
                .layer_id = layer_id,
            } });
            self.planAppendOpAssumeCapacity(.{ .draw_surface = .{
                .layer_id = layer_id,
                .opacity = effect.opacity,
                .transform_id = effect.transform_id,
            } });
        }
        self.planSweepStale();
    }
};

fn promotedLayerPriority(layer: *const CompositedLayer) u8 {
    return switch (layer.effect_kind) {
        .backdrop_blur => 3,
        .composited_group => 2,
        .opacity => 1,
        .rounded_clip => 1,
    };
}

fn buildPromotionReason(
    effect: property_tree_mod.EffectNode,
    transform: ?property_tree_mod.TransformNode,
    node_runtime: ?scene_runtime_mod.SceneNodeRuntime,
) CompositedPromotionReason {
    var reason = CompositedPromotionReason{};
    if (node_runtime) |runtime| {
        reason.is_overlay = runtime.is_overlay_candidate;
        reason.has_opacity_animation = runtime.has_active_opacity_animation;
        reason.has_transform_animation = runtime.has_active_transform_animation or if (transform) |tx|
            tx.flags.has_animation and (tx.flags.has_translation or tx.flags.has_scale or tx.flags.has_rotation)
        else
            false;
        reason.text_with_transform_animation = runtime.is_overlay_candidate and runtime.content_flags.has_text and reason.has_transform_animation;
        reason.has_will_change_transform = runtime.will_change_transform;
        reason.has_will_change_opacity = runtime.will_change_opacity;
    }
    reason.explicit_composited_group = effect.kind == .composited_group;
    reason.has_filter_effect = effect.kind == .backdrop_blur;
    return reason;
}

fn shouldPromoteLayer(effect: property_tree_mod.EffectNode, reason: CompositedPromotionReason, node_runtime: ?scene_runtime_mod.SceneNodeRuntime) bool {
    if (effect.kind == .backdrop_blur) return true;
    if (effect.kind == .composited_group) return true;
    if (reason.text_with_transform_animation) return true;
    if (reason.has_will_change_transform or reason.has_will_change_opacity) return true;
    if (reason.is_overlay and (reason.has_transform_animation or reason.has_opacity_animation)) return true;
    if (effect.kind == .rounded_clip) {
        if (node_runtime) |runtime| {
            return runtime.has_active_composite_animation;
        }
    }
    return false;
}

fn hasSameLinearTransform(a: types.Transform2D, b: types.Transform2D) bool {
    return @abs(a.a - b.a) < 0.0001 and
        @abs(a.b - b.b) < 0.0001 and
        @abs(a.c - b.c) < 0.0001 and
        @abs(a.d - b.d) < 0.0001;
}

fn canReusePromotedSurface(layer: CompositedLayer, transform: ?property_tree_mod.TransformNode, node_runtime: ?scene_runtime_mod.SceneNodeRuntime) bool {
    const runtime = node_runtime orelse return false;
    const current_transform = transform orelse return false;
    if (!layer.promotion_reason.any()) return false;
    if (!runtime.has_promoted_surface_cache) return false;
    // Cross-frame identity uses stable_id (retained LayerId raw with generation),
    // per-frame sequence shifts with node add/delete/move, caused spurious cache misses.
    if (runtime.promoted_surface_layer_id != layer.stable_id) return false;
    if (runtime.promoted_surface_content_version != runtime.content_version) return false;
    if (layer.promotion_reason.has_transform_animation) {
        return true;
    }
    if (@abs(runtime.promoted_surface_bounds.w - runtime.world_bounds.w) > 0.01) return false;
    if (@abs(runtime.promoted_surface_bounds.h - runtime.world_bounds.h) > 0.01) return false;
    if (!hasSameLinearTransform(runtime.promoted_surface_transform, current_transform.world)) return false;
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "LayerId is exactly 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(LayerId));
}

test "LayerTree: createLayer / get / destroyLayer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const id = try t.createLayer(root_elem, .root, LayerId.NULL);
    try testing.expect(t.isAlive(id));
    try testing.expect(t.root.eql(id));

    const layer = t.get(id).?;
    try testing.expectEqual(PromotionReason.root, layer.reason);

    t.destroyLayer(id);
    try testing.expect(!t.isAlive(id));
}

test "LayerTree: assignElement + layerOf reverse lookup" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .root, LayerId.NULL);

    const e1: ElementId = .{ .index = 1, .generation = 0 };
    const e2: ElementId = .{ .index = 2, .generation = 0 };
    try t.assignElement(layer, e1);
    try t.assignElement(layer, e2);

    try testing.expect(t.layerOf(e1).?.eql(layer));
    try testing.expect(t.layerOf(e2).?.eql(layer));
    try testing.expect(t.layerOf(.{ .index = 99, .generation = 0 }) == null);
}

test "LayerTree: addDamage marks needs_repaint and unions rect" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    try testing.expect(!t.get(layer).?.needs_repaint);

    t.addDamage(layer, .{ .min_x = 0, .min_y = 0, .max_x = 50, .max_y = 50 });
    try testing.expect(t.get(layer).?.needs_repaint);

    t.addDamage(layer, .{ .min_x = 30, .min_y = 30, .max_x = 100, .max_y = 100 });
    const dmg = t.get(layer).?.damage_rect;
    try testing.expectEqual(@as(f32, 0), dmg.min_x);
    try testing.expectEqual(@as(f32, 100), dmg.max_x);
}

test "LayerTree: beginFrame clears damage" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .root, LayerId.NULL);
    t.addDamage(layer, .{ .min_x = 0, .min_y = 0, .max_x = 50, .max_y = 50 });

    t.beginFrame();
    try testing.expect(!t.get(layer).?.needs_repaint);
    try testing.expectEqual(@as(f32, 0), t.get(layer).?.damage_rect.max_x);
}

test "LayerTree: destroyLayer cleans up element_to_layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .root, LayerId.NULL);
    const e1: ElementId = .{ .index = 1, .generation = 0 };
    try t.assignElement(layer, e1);

    t.destroyLayer(layer);
    try testing.expect(t.layerOf(e1) == null);
}

test "LayerTree: liveLayerCount" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();
    try testing.expectEqual(@as(u32, 0), t.liveLayerCount());

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const a = try t.createLayer(root_elem, .root, LayerId.NULL);
    _ = try t.createLayer(root_elem, .scroll, a);
    _ = try t.createLayer(root_elem, .transform_animating, a);
    try testing.expectEqual(@as(u32, 3), t.liveLayerCount());

    t.destroyLayer(a);
    try testing.expectEqual(@as(u32, 2), t.liveLayerCount());
}

test "LayerTree: setGpuTextureHandle / destroy with release callback" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    t.setGpuTextureHandle(layer, 0xDEADBEEF);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), t.gpuTextureHandle(layer));

    const Captured = struct {
        last_handle: u64 = 0,
        var release_count: u32 = 0;

        fn cb(ctx: *anyopaque, handle: u64) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.last_handle = handle;
            release_count += 1;
        }
    };
    var captured = Captured{};
    Captured.release_count = 0;

    t.destroyLayerWithRelease(layer, &Captured.cb, &captured);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), captured.last_handle);
    try testing.expectEqual(@as(u32, 1), Captured.release_count);
    try testing.expect(!t.isAlive(layer));
}

test "LayerTree: destroyLayer (no callback) just drops GPU handle" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    t.setGpuTextureHandle(layer, 0xCAFE);

    t.destroyLayer(layer);
    try testing.expect(!t.isAlive(layer));
    // No release callback; GPU handles managed by caller (when accepting ResourcePool, pool.release
    // handles epoch retirement queue).
}

test "LayerTree: ABA — destroyed id rejected after slot reuse" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const a = try t.createLayer(root_elem, .root, LayerId.NULL);
    t.destroyLayer(a);

    const b = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    try testing.expectEqual(a.index, b.index); // Reuse slot.
    try testing.expect(a.generation != b.generation);
    try testing.expect(!t.isAlive(a));
    try testing.expect(t.isAlive(b));
}

test "P1.10': planAppendLayer creates layer in tree and returns plan_id" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const live_before = tree.liveLayerCount();
    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    try testing.expectEqual(@as(u32, 0), plan_id);
    try testing.expectEqual(live_before + 1, tree.liveLayerCount());

    const tree_id = tree.planTreeLayerOf(plan_id);
    try testing.expect(!tree_id.isNull());
    try testing.expect(tree.isAlive(tree_id));
}

test "planQueryRootNode: per-root chain keeps the scan's priority and first-wins order" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();
    const base: CompositedLayer = .{
        .root_node_id = 0,
        .content_bounds_local = ComputedRect.init(0, 0, 10, 10),
        .surface_bounds_world = ComputedRect.init(0, 0, 10, 10),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .opacity,
    };
    const promoted: CompositedPromotionReason = .{ .has_opacity_animation = true };
    var l = base;
    // root 7: unpromoted, then opacity (prio 1), then blur (prio 3), then another blur.
    l.root_node_id = 7;
    _ = try tree.planAppendLayer(l);
    l.effect_kind = .opacity;
    l.promotion_reason = promoted;
    l.effect_id = 1;
    const opacity_7 = try tree.planAppendLayer(l);
    // An unrelated root interleaved between root 7's layers.
    var other = base;
    other.root_node_id = 9;
    other.effect_id = 2;
    other.effect_kind = .composited_group;
    other.promotion_reason = promoted;
    const group_9 = try tree.planAppendLayer(other);
    l.effect_kind = .backdrop_blur;
    l.effect_id = 3;
    const blur_7 = try tree.planAppendLayer(l);
    l.effect_id = 4;
    _ = try tree.planAppendLayer(l);
    try testing.expectEqual(@as(u32, 4), tree.frame_promoted_count);

    const s7 = tree.planQueryRootNode(7);
    try testing.expect(s7.has_plan_layer);
    // Highest priority wins; the first of equal priority stays.
    try testing.expectEqual(blur_7, s7.promoted_layer_id);
    try testing.expect(blur_7 != opacity_7);
    try testing.expectEqual(group_9, tree.planQueryRootNode(9).promoted_layer_id);
    const none = tree.planQueryRootNode(8);
    try testing.expect(!none.has_plan_layer);
    try testing.expectEqual(INVALID_ID, none.promoted_layer_id);

    tree.planClear();
    try testing.expectEqual(@as(u32, 0), tree.frame_promoted_count);
    try testing.expect(!tree.planQueryRootNode(7).has_plan_layer);
}

test "retained plan: planClear 保留 layer，跨帧身份稳定，epoch sweep 清退场" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    tree.plan_epoch += 1;
    _ = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    _ = try tree.planAppendLayer(.{
        .root_node_id = 2,
        .content_bounds_local = ComputedRect.init(0, 0, 50, 50),
        .surface_bounds_world = ComputedRect.init(0, 0, 50, 50),
        .transform_id = 0,
        .effect_id = 1,
        .effect_kind = .opacity,
    });
    try testing.expectEqual(@as(u32, 2), tree.liveLayerCount());
    const stable_a = tree.planCompositedAt(0).?.stable_id;

    // Retained: planClear clears ops/ordinal only, layer survives cross-frame.
    tree.planClear();
    try testing.expectEqual(@as(u32, 2), tree.liveLayerCount());
    try testing.expectEqual(@as(usize, 0), tree.frame_layer_ids.items.len);

    // Same node next frame -> reuse layer (stable_id unchanged), ordinal may differ.
    tree.plan_epoch += 1;
    _ = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    try testing.expectEqual(stable_a, tree.planCompositedAt(0).?.stable_id);
    // node 2 absent this frame -> destroyed by sweep.
    tree.planSweepStale();
    try testing.expectEqual(@as(u32, 1), tree.liveLayerCount());
}

test "P1.10': planMarkLayerSurfaceInvalidated forwards to tree by plan id" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    tree.planMarkLayerSurfaceInvalidated(plan_id, .self);

    const tree_id = tree.planTreeLayerOf(plan_id);
    const tree_layer = tree.get(tree_id).?;
    try testing.expect(!tree_layer.frame_flags.surface_valid);
    try testing.expect(tree_layer.frame_flags.invalidated_by_self_this_frame);
    try testing.expect(!tree_layer.frame_flags.invalidated_by_descendant_this_frame);

    tree.planMarkLayerSurfaceInvalidated(plan_id, .descendant);
    const tree_layer2 = tree.get(tree_id).?;
    try testing.expect(tree_layer2.frame_flags.invalidated_by_descendant_this_frame);
}

test "P1.10': planMarkLayerSurfaceReused matches semantics" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    tree.planMarkLayerSurfaceInvalidated(plan_id, .self);
    tree.planMarkLayerSurfaceReused(plan_id);

    const tree_id = tree.planTreeLayerOf(plan_id);
    const tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.frame_flags.surface_valid);
    try testing.expect(tree_layer.frame_flags.reused_this_frame);
    try testing.expect(!tree_layer.frame_flags.invalidated_by_self_this_frame);
    try testing.expect(!tree_layer.frame_flags.rebuilt_this_frame);

    const ff = tree.planFrameFlagsOf(plan_id);
    try testing.expectEqual(tree_layer.frame_flags.surface_valid, ff.surface_valid);
    try testing.expectEqual(tree_layer.frame_flags.reused_this_frame, ff.reused_this_frame);
    try testing.expectEqual(tree_layer.frame_flags.rebuilt_this_frame, ff.rebuilt_this_frame);
}

test "P1.10': planMarkLayerSurfaceRebuilt + planMarkLayerDescendantScoped" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });

    tree.planMarkLayerSurfaceRebuilt(plan_id);
    const tree_id = tree.planTreeLayerOf(plan_id);
    var tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.frame_flags.surface_valid);
    try testing.expect(tree_layer.frame_flags.rebuilt_this_frame);
    try testing.expect(!tree_layer.frame_flags.reused_this_frame);

    tree.planMarkLayerDescendantScopedRebuildCandidate(plan_id);
    tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.frame_flags.descendant_scoped_rebuild_candidate_this_frame);
}

test "P1.10': planAppendLayer mirrors CompositedLayer to tree.composited" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 42,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 50),
        .surface_bounds_world = ComputedRect.init(10, 20, 100, 50),
        .transform_id = 7,
        .effect_id = 3,
        .effect_kind = .opacity,
        .opacity = 0.5,
    });

    const tree_id = tree.planTreeLayerOf(plan_id);
    const tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.composited != null);
    const c = tree_layer.composited.?;
    try testing.expectEqual(@as(u32, 42), c.root_node_id);
    try testing.expectEqual(@as(u32, 7), c.transform_id);
    try testing.expectEqual(@as(u32, 3), c.effect_id);
    try testing.expectEqual(EffectKind.opacity, c.effect_kind);
    try testing.expectEqual(@as(f32, 0.5), c.opacity);
    try testing.expectApproxEqAbs(@as(f32, 100), c.surface_bounds_world.w, 0.001);
}

// =============================================================================
// Compositor types (CompositedLayer / CompositeOp etc), historically lived in
// compositor_plan.zig; merged into layer_tree.zig with the API that operates on
// them now living on the LayerTree struct itself (P1.10' 2026-05-01).
// =============================================================================

/// Phase L5: Layer promotion reason (CompositorPlan internal, distinct from LayerTree
/// PromotionReason).
pub const CompositedPromotionReason = packed struct(u16) {
    has_transform_animation: bool = false,
    has_opacity_animation: bool = false,
    has_filter_effect: bool = false,
    text_with_transform_animation: bool = false,
    is_overlay: bool = false,
    has_will_change_transform: bool = false,
    has_will_change_opacity: bool = false,
    explicit_composited_group: bool = false,
    is_scroll_container: bool = false,
    _pad: u7 = 0,

    pub fn any(self: CompositedPromotionReason) bool {
        return self.has_transform_animation or
            self.has_opacity_animation or
            self.has_filter_effect or
            self.text_with_transform_animation or
            self.is_overlay or
            self.has_will_change_transform or
            self.has_will_change_opacity or
            self.explicit_composited_group or
            self.is_scroll_container;
    }
};

/// CompositedLayer flags (old CompositorPlan private LayerFlags).
/// Frame state (surface_valid / reused / rebuilt / invalidated_by_self /
/// invalidated_by_descendant / descendant_scoped_candidate) lives in LayerTree.frame_flags;
/// read it via plan.frameFlagsOf(plan_id). Here: plan-stable metadata only
/// (is_animating / contains_text).
const CompositedLayerFlags = packed struct(u8) {
    is_animating: bool = false,
    contains_text: bool = false,
    _reserved: u6 = 0,
};

/// Subtree requiring offscreen composite.
pub const CompositedLayer = struct {
    layer_id: u32 = 0,
    /// Cross-frame stable identity (retained LayerId packed raw with generation ABA
    /// protection). layer_id is per-frame sequence (frame-local ops only); **all
    /// cross-frame comparison uses stable_id**.
    stable_id: u32 = INVALID_ID,
    root_node_id: u32,
    content_bounds_local: ComputedRect,
    surface_bounds_world: ComputedRect,
    transform_id: u32,
    clip_id: u32 = INVALID_ID,
    effect_id: u32,
    effect_kind: EffectKind,
    opacity: f32 = 1.0,
    blend_mode: types.BlendMode = .normal,
    warp: types.ContentWarp = .{},
    glass: types.ResolvedGlassParams = .{},
    corner_radius: [4]f32 = .{ 0, 0, 0, 0 },
    content_version: u32 = 0,
    flags: CompositedLayerFlags = .{},
    promotion_reason: CompositedPromotionReason = .{},
    has_surface_transform: bool = false,
    surface_rotate: f32 = 0,
    surface_draw_transform: types.Transform2D = types.Transform2D.identity(),
    surface_parent_inverse: types.Transform2D = types.Transform2D.identity(),
    surface_source_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    surface_draw_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    /// Where the composite quad origin (surface_draw_transform's translation) lands in the target
    /// frame at rest: owner scale/rotation 1/0 and transient motion (an overlay slide) removed.
    /// The encoder anchors the texture's pixel grid to this point, so the texture holds the same
    /// pixels for the whole animation and composes onto the direct-draw grid once it settles.
    /// null: unknown (grid follows the current matrix).
    surface_rest_origin: ?[2]f32 = null,
};

/// Composite op.
const CompositeOp = union(enum) {
    begin_surface: struct {
        layer_id: u32,
        bounds: ComputedRect,
    },
    end_surface: struct {
        layer_id: u32,
    },
    draw_surface: struct {
        layer_id: u32,
        opacity: f32,
        transform_id: u32,
    },
    apply_clip: ApplyClipOp,
};

pub const ApplyClipOp = struct {
    effect_id: u32,
    clip_id: u32,
    bounds: ComputedRect,
    shape_kind: display_list_mod.ClipShapeKind = .rect,
    /// TL, TR, BR, BL (.rounded_rect only).
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    polygon: display_list_mod.ClipPolygon = .{},
    bounds_fallback: bool = false,
};

test "LayerTree: 世代回卷前 slot 永久退役（悬垂 LayerId 不复活）" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const first = try t.createLayer(root_elem, .root, LayerId.NULL);
    t.destroyLayer(first);

    // Single slot create/destroy cycles: generation +2 per cycle. Old implementation,
    // after rollover, stale LayerId would re-isAlive (alive can't stop reuse).
    var cycles: u32 = 0;
    while (cycles < 200) : (cycles += 1) {
        const id = try t.createLayer(root_elem, .root, LayerId.NULL);
        if (id.index != first.index) {
            t.destroyLayer(id);
            break;
        }
        try testing.expect(!t.isAlive(first));
        t.destroyLayer(id);
    }
    try testing.expect(cycles < 200);
    try testing.expect(!t.isAlive(first));
}

// (2026-09-14): LayerTree slot table allocation/rollback contract.

/// Two parallel tables must match; live layers findable in plan_by_node or
/// frame_layer_ids (else epoch sweep never reclaims).
fn expectLayerTreeInvariants(t: *const LayerTree) !void {
    try testing.expectEqual(t.layers.items.len, t.generations.items.len);
    // plan-path layers: live count == active entries in plan_by_node.
    var planned_alive: u32 = 0;
    var it = t.plan_by_node.iterator();
    while (it.next()) |entry| {
        if (t.isAlive(entry.value_ptr.*)) planned_alive += 1;
    }
    try testing.expectEqual(planned_alive, t.liveLayerCount());
}

test "LayerTree: createLayer 在任意分配点失败都不留下 layers/generations 错位的半个 layer" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var t = LayerTree.init(a, .{});
        defer t.deinit();
        const root_elem: ElementId = .{ .index = 0, .generation = 0 };
        var created: u32 = 0;
        var i: usize = 0;
        while (i < 40) : (i += 1) {
            const r = t.createLayer(root_elem, .root, LayerId.NULL);
            try testing.expectEqual(t.layers.items.len, t.generations.items.len);
            if (r) |_| {
                created += 1;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                break;
            }
        }
        try testing.expectEqual(created, t.liveLayerCount());
        // After failure, tables usable: isAlive never out-of-bounds.
        const probe: LayerId = .{ .index = @intCast(t.layers.items.len), .generation = 0 };
        try testing.expect(!t.isAlive(probe));
        if (!failing.has_induced_failure) break;
    }
}

test "LayerTree: planAppendLayer 在任意分配点失败都不留下 sweep 永远收不到的孤儿 layer" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var t = LayerTree.init(a, .{});
        defer t.deinit();
        t.plan_epoch += 1;
        var node: u32 = 1;
        while (node <= 20) : (node += 1) {
            const r = t.planAppendLayer(.{
                .root_node_id = node,
                .content_bounds_local = ComputedRect.init(0, 0, 10, 10),
                .surface_bounds_world = ComputedRect.init(0, 0, 10, 10),
                .transform_id = 0,
                .effect_id = node,
                .effect_kind = .opacity,
            });
            try expectLayerTreeInvariants(&t);
            if (r) |_| {} else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                break;
            }
        }
        // Next frame none appear: sweep must clean all live (orphans stay).
        t.plan_epoch += 1;
        t.planClear();
        t.planSweepStale();
        try testing.expectEqual(@as(u32, 0), t.liveLayerCount());
        try testing.expectEqual(@as(usize, 0), t.plan_by_node.count());
        if (!failing.has_induced_failure) break;
    }
}

test "LayerTree: 一帧退场超过 64 个 layer 时 plan_by_node 一次清干净" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();
    t.plan_epoch += 1;
    var node: u32 = 1;
    while (node <= 150) : (node += 1) {
        _ = try t.planAppendLayer(.{
            .root_node_id = node,
            .content_bounds_local = ComputedRect.init(0, 0, 10, 10),
            .surface_bounds_world = ComputedRect.init(0, 0, 10, 10),
            .transform_id = 0,
            .effect_id = node,
            .effect_kind = .opacity,
        });
    }
    try testing.expectEqual(@as(u32, 150), t.liveLayerCount());
    t.plan_epoch += 1;
    t.planClear();
    t.planSweepStale();
    try testing.expectEqual(@as(u32, 0), t.liveLayerCount());
    // Old: single pass left 86 destroyed keys.
    try testing.expectEqual(@as(usize, 0), t.plan_by_node.count());
}

test "LayerTree: planBuildFromPropertyTree 在任意分配点失败都不 abort、不留半截 op 三元组" {
    const effects = [_]property_tree_mod.EffectNode{
        .{ .parent = INVALID_ID, .transform_id = 0, .node_id = 1, .kind = .opacity, .requires_offscreen = true, .local_bounds = ComputedRect.init(0, 0, 10, 10) },
        .{ .parent = INVALID_ID, .transform_id = 0, .node_id = 2, .kind = .composited_group, .requires_offscreen = true, .local_bounds = ComputedRect.init(0, 0, 20, 20) },
        .{ .parent = INVALID_ID, .transform_id = 0, .node_id = 3, .kind = .opacity, .requires_offscreen = true, .local_bounds = ComputedRect.init(0, 0, 30, 30) },
    };
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var t = LayerTree.init(a, .{});
        defer t.deinit();
        // Before fix: @panic on injection hitting op append, test abort.
        t.planBuildFromPropertyTree(&effects, &.{}, &.{}, null);
        try expectLayerTreeInvariants(&t);
        // Every planned layer must have complete begin/end/draw; ops-ref layers in plan.
        var begins: usize = 0;
        var ends: usize = 0;
        var draws: usize = 0;
        for (t.frame_ops.items) |op| switch (op) {
            .begin_surface => |b| {
                begins += 1;
                try testing.expect(b.layer_id < t.frame_layer_ids.items.len);
            },
            .end_surface => ends += 1,
            .draw_surface => draws += 1,
            else => {},
        };
        try testing.expectEqual(t.frame_layer_ids.items.len, begins);
        try testing.expectEqual(begins, ends);
        try testing.expectEqual(begins, draws);
        if (!failing.has_induced_failure) {
            // No injection to any point = full success: all three effects in.
            try testing.expectEqual(@as(usize, 3), t.frame_layer_ids.items.len);
            break;
        }
    }
}
