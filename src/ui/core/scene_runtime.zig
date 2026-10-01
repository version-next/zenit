/// Phase L0: Scene Runtime，节点级保留式元数据
///
/// 每帧在 renderNodeTransform 中为可见节点写入 SceneNodeRuntime，
/// 当前阶段仅记录不消费，为后续 Phase 统一 render/hit/devtools 奠定基础。
const std = @import("std");
const types = @import("types.zig");
const property_tree = @import("property_tree.zig");

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
        // self_blur 与 self_scale/self_safe_effect 不同：backdrop_blur 的 GPU consumer
        // (applyBackdropBlur) 不 push offscreen layer 来提供"父节点 -> 子节点"的 world translation。
        // 若把 children 命令转成 button-local 坐标，主 pass 上就会画到 (button_local) 而非 (button_world+local)。
        // 因此 self_blur 必须保留 absolute world 坐标。
        .self_blur => false,
        .self_safe_effect, .self_scale => true,
    };
}

pub const SceneNodeRuntime = struct {
    node_id: u32,
    /// node.rect（相对父节点的局部矩形）
    local_rect: ComputedRect,
    /// 世界空间 AABB (= world_transform.transformRect(0, 0, w, h))
    world_bounds: ComputedRect,
    /// 不含缩放/旋转的内容空间变换，用于 surface transform 的离屏 source bounds
    content_transform: Transform2D = .{},
    /// 内容空间矩形（content_transform.transformRect(local_rect)）
    content_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    /// PropertyTree.transforms 索引
    transform_id: u32,
    /// PropertyTree.clips 索引（INVALID_ID = 无裁剪）
    clip_id: u32 = INVALID_ID,
    /// 当前 render clip 是否只是 bounds fallback，而非精确 shape clip。
    clip_bounds_fallback: bool = false,
    /// PropertyTree.effects 索引（INVALID_ID = 无效果）
    effect_id: u32 = INVALID_ID,
    /// DFS 绘制顺序
    paint_order: u64 = 0,
    display_item_start: u32 = 0,
    display_item_count: u32 = 0,
    display_payload_own_prebuilt: bool = false,
    display_payload_own_prebuilt_epoch: u64 = 0,
    subtree_display_item_start: u32 = 0,
    subtree_display_item_count: u32 = 0,
    display_payload_subtree_prebuilt: bool = false,
    display_payload_subtree_strategy: DisplayPayloadSubtreeStrategy = .none,
    display_payload_subtree_prebuilt_epoch: u64 = 0,
    text_blob_start: u32 = 0,
    text_blob_count: u32 = 0,
    subtree_text_blob_start: u32 = 0,
    subtree_text_blob_count: u32 = 0,
    content_version: u32 = 0,
    composite_version: u32 = 0,
    promoted_layer_id: u32 = INVALID_ID,
    content_flags: ContentFlags = .{},
    is_overlay_candidate: bool = false,
    /// Phase L5: 该节点是否有活跃的 composite-only 动画（可跳过内容重建）
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

pub const SceneRuntime = struct {
    allocator: Allocator,
    nodes: std.AutoHashMap(u32, SceneNodeRuntime),
    /// 每帧递增，用于验证时序
    frame_epoch: u64 = 0,

    pub fn init(allocator: Allocator) SceneRuntime {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u32, SceneNodeRuntime).init(allocator),
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
};
