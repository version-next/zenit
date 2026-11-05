/// Phase L0: Scene Runtime, node-level retained metadata
///
/// Each frame write SceneNodeRuntime for visible nodes in renderNodeTransform; current phase
/// records only, no consumption, establishes foundation for later Phase unified
/// render/hit/devtools.
const std = @import("std");
const types = @import("types.zig");
const property_tree = @import("property_tree.zig");
const id_hash = @import("id_hash.zig");

const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
pub const INVALID_ID = property_tree.INVALID_ID;

pub const ContentFlags = packed struct(u8) {
    has_text: bool = false,
    has_image: bool = false,
    has_icon: bool = false,
    has_background: bool = false,
    has_border: bool = false,
    has_shadow: bool = false,
    has_custom_draw: bool = false,
    _padding: u1 = 0,
};

pub const DisplayPayloadSubtreeStrategy = enum(u8) {
    none = 0,
    simple = 1,
    self_safe_effect = 2,
    self_scale = 3,
    self_blur = 4,
};

pub fn displayPayloadSubtreeStrategyUsesSelfEffectSpace(strategy: DisplayPayloadSubtreeStrategy) bool {
    return switch (strategy) {
        .none, .simple => false,
        // self_blur differs from self_scale/self_safe_effect: backdrop_blur GPU consumer
        // (applyBackdropBlur) doesn't push offscreen layer to provide "parent -> child" world
        // translation. Converting children commands to button-local coordinates would draw at
        // (button_local) not (button_world+local). Thus self_blur must retain absolute world
        // coordinates.
        .self_blur => false,
        .self_safe_effect, .self_scale => true,
    };
}

pub const SceneNodeRuntime = struct {
    node_id: u32,
    /// node.rect (local rect relative to parent)
    local_rect: ComputedRect,
    /// World-space AABB (= world_transform.transformRect(0, 0, w, h))
    world_bounds: ComputedRect,
    /// Content-space transform without scale/rotation, for surface transform offscreen source
    /// bounds
    content_transform: Transform2D = .{},
    /// Transient part of the node's translate (StyleExt.motion_offset, parent-local units): excluded
    /// from the rest origin a surface anchors its pixel grid to.
    content_motion: [2]f32 = .{ 0, 0 },
    /// Content-space rect (content_transform.transformRect(local_rect))
    content_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    /// PropertyTree.transforms index
    transform_id: u32,
    /// PropertyTree.clips index (INVALID_ID = no clip)
    clip_id: u32 = INVALID_ID,
    /// Whether current render clip is only bounds fallback, not precise shape clip.
    clip_bounds_fallback: bool = false,
    /// PropertyTree.effects index (INVALID_ID = no effect)
    effect_id: u32 = INVALID_ID,
    /// DFS paint order
    paint_order: u64 = 0,
    /// Index of this node in RenderContext.retained_nodes this frame (its Node pointer).
    retained_index: u32 = std.math.maxInt(u32),
    display_item_start: u32 = 0,
    display_item_count: u32 = 0,
    display_payload_own_prebuilt: bool = false,
    display_payload_own_prebuilt_epoch: u64 = 0,
    subtree_display_item_start: u32 = 0,
    subtree_display_item_count: u32 = 0,
    display_payload_subtree_prebuilt: bool = false,
    display_payload_subtree_strategy: DisplayPayloadSubtreeStrategy = .none,
    display_payload_subtree_prebuilt_epoch: u64 = 0,
    /// The subtree's items are not one range this frame: part of it sits in the prebuild prefix,
    /// part was appended by the paint pass. Its subtree range covers only the appended part, so no
    /// ancestor may assemble a cross-frame cache from it.
    subtree_display_split: bool = false,
    /// The prebuild pass (or a paint-cursor resume) already processed this node this frame:
    /// any content it prebuilt is in the display list, so the paint pass must not prebuild it
    /// again. Records are rebuilt every frame, so this needs no epoch.
    prebuild_visited: bool = false,
    text_blob_start: u32 = 0,
    text_blob_count: u32 = 0,
    subtree_text_blob_start: u32 = 0,
    subtree_text_blob_count: u32 = 0,
    content_version: u32 = 0,
    composite_version: u32 = 0,
    promoted_layer_id: u32 = INVALID_ID,
    content_flags: ContentFlags = .{},
    is_overlay_candidate: bool = false,
    /// Phase L5: whether this node has active composite-only animation (can skip content rebuild)
    has_active_composite_animation: bool = false,
    has_active_transform_animation: bool = false,
    has_active_opacity_animation: bool = false,
    will_change_transform: bool = false,
    will_change_opacity: bool = false,
    has_promoted_descendant_subtree: bool = false,
    has_promoted_surface_cache: bool = false,
    promoted_surface_layer_id: u32 = INVALID_ID,
    promoted_surface_content_version: u32 = 0,
    promoted_surface_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    promoted_surface_transform: Transform2D = .{},
    /// Frame-flags for the promoted surface cache. Layout mirrors
    /// `layer_tree.LayerFrameFlags` (kept inline here to avoid a cyclic
    /// import, `layer_tree` already imports `scene_runtime`).
    promoted_surface_flags: PromotedSurfaceFrameFlags = .{},
};

/// Mirrors `layer_tree.LayerFrameFlags` shape; inlined here to avoid the
/// scene_runtime <-> layer_tree import cycle.
pub const PromotedSurfaceFrameFlags = packed struct(u8) {
    surface_valid: bool = false,
    reused_this_frame: bool = false,
    rebuilt_this_frame: bool = false,
    invalidated_by_descendant_this_frame: bool = false,
    invalidated_by_self_this_frame: bool = false,
    descendant_scoped_rebuild_candidate_this_frame: bool = false,
    _reserved: u2 = 0,
};

/// Scene records keyed by node id: a small id -> slot index map over a dense record array. Records
/// are a few hundred bytes and rebuilt every frame in DFS order; a hash map holding them by value
/// scattered every put across its value array, while appends here are sequential. Mirrors the
/// subset of the std.HashMap API the engine uses.
pub const NodeTable = struct {
    allocator: Allocator,
    index: id_hash.U32HashMapUnmanaged(u32) = .{},
    values: std.ArrayListUnmanaged(SceneNodeRuntime) = .empty,

    pub const Entry = struct { key_ptr: *const u32, value_ptr: *SceneNodeRuntime };
    pub const Iterator = struct {
        inner: id_hash.U32HashMapUnmanaged(u32).Iterator,
        values: []SceneNodeRuntime,
        pub fn next(self: *Iterator) ?Entry {
            const e = self.inner.next() orelse return null;
            return .{ .key_ptr = e.key_ptr, .value_ptr = &self.values[e.value_ptr.*] };
        }
    };

    pub fn deinit(self: *NodeTable) void {
        self.index.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *NodeTable) void {
        self.index.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
    }

    pub fn count(self: *const NodeTable) u32 {
        return self.index.count();
    }

    pub fn contains(self: *const NodeTable, id: u32) bool {
        return self.index.contains(id);
    }

    pub fn getPtr(self: *const NodeTable, id: u32) ?*SceneNodeRuntime {
        const i = self.index.get(id) orelse return null;
        return &self.values.items[i];
    }

    pub fn get(self: *const NodeTable, id: u32) ?SceneNodeRuntime {
        const p = self.getPtr(id) orelse return null;
        return p.*;
    }

    pub fn ensureUnusedCapacity(self: *NodeTable, additional: u32) !void {
        try self.index.ensureUnusedCapacity(self.allocator, additional);
        try self.values.ensureUnusedCapacity(self.allocator, additional);
    }

    pub fn put(self: *NodeTable, id: u32, value: SceneNodeRuntime) !void {
        try self.ensureUnusedCapacity(1);
        self.putAssumeCapacity(id, value);
    }

    pub fn putAssumeCapacity(self: *NodeTable, id: u32, value: SceneNodeRuntime) void {
        const gop = self.index.getOrPutAssumeCapacity(id);
        if (gop.found_existing) {
            self.values.items[gop.value_ptr.*] = value;
        } else {
            gop.value_ptr.* = @intCast(self.values.items.len);
            self.values.appendAssumeCapacity(value);
        }
    }

    pub fn iterator(self: *const NodeTable) Iterator {
        return .{ .inner = self.index.iterator(), .values = self.values.items };
    }
};

pub const SceneRuntime = struct {
    allocator: Allocator,
    nodes: NodeTable,
    /// Per-frame increment for timing validation
    frame_epoch: u64 = 0,

    pub fn init(allocator: Allocator) SceneRuntime {
        return .{
            .allocator = allocator,
            .nodes = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *SceneRuntime) void {
        self.nodes.deinit();
    }

    pub fn clear(self: *SceneRuntime) void {
        self.nodes.clearRetainingCapacity();
        self.frame_epoch += 1;
    }

    pub fn put(self: *SceneRuntime, runtime: SceneNodeRuntime) !void {
        try self.nodes.put(runtime.node_id, runtime);
    }

    pub fn get(self: *const SceneRuntime, node_id: u32) ?SceneNodeRuntime {
        return self.nodes.get(node_id);
    }

    /// Borrowed record, valid until the next `put`/`clear`. `SceneNodeRuntime` is a
    /// few hundred bytes; per-node passes that only read a handful of fields
    /// should not copy it out (Debug builds copy it through memcpy every time).
    pub fn getPtr(self: *const SceneRuntime, node_id: u32) ?*const SceneNodeRuntime {
        return self.nodes.getPtr(node_id);
    }
};
