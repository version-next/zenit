/// render_engine 内部状态结构体定义
/// 包含：RetainedIds、NodeRenderState、NodeContentRenderState、
///       NodeExecutionState、NodeExecutionPlan、NodeContentSlices、
///       ChildRenderPass 及相关枚举
const std = @import("std");
const types = @import("../types.zig");
const display_list_mod = @import("../display_list.zig");
const layer_tree_mod = @import("../layer_tree.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");

const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Point = types.Point;

// ─────────────────────────────────────────────────────────────────────────────
// 基础 ID 容器
// ─────────────────────────────────────────────────────────────────────────────

pub const RetainedIds = struct {
    transform_id: u32,
    clip_id: u32,
    effect_id: u32,
};

// ─────────────────────────────────────────────────────────────────────────────
// 渲染状态（含变换/缩放/裁剪/效果，基于世界坐标）
// ─────────────────────────────────────────────────────────────────────────────

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
    clip_radii: [4]f32,
    clip_radius: f32,
    clip_polygon: display_list_mod.ClipPolygon,
    clip_bounds_fallback: bool,
    use_blur: bool,
    use_rounded_clip: bool,
};

/// 内容渲染状态：不含缩放/旋转的内容坐标，用于文本和子节点精确定位
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
    clip_radii: [4]f32,
    clip_radius: f32,
    clip_polygon: display_list_mod.ClipPolygon,
    clip_bounds_fallback: bool,
    use_blur: bool,
    use_rounded_clip: bool,
};

// ─────────────────────────────────────────────────────────────────────────────
// 执行状态：合并世界坐标、场景 runtime、compositor plan
// ─────────────────────────────────────────────────────────────────────────────

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
    clip_radii: [4]f32,
    clip_radius: f32,
    clip_polygon: display_list_mod.ClipPolygon,
    clip_bounds_fallback: bool,
    use_rounded_clip: bool,
    promoted_layer_id: u32,
    /// 跨帧稳定身份（CompositedLayer.stable_id）；写入 node 缓存/跨帧比较用它，
    /// promoted_layer_id（帧内序号）只用于本帧 planMark* API。
    promoted_layer_stable_id: u32,
    is_promoted_layer: bool,
    promoted_surface_valid: bool,
    subtree_force_linear_text: bool,
};

// ─────────────────────────────────────────────────────────────────────────────
// 枚举：invalidation / 重建策略 / 渲染 pass
// ─────────────────────────────────────────────────────────────────────────────

pub const PromotedSurfaceInvalidationReason = enum {
    none,
    self,
    descendant,
};

pub const NodeRebuildStrategy = enum {
    normal,
    descendant_scoped_promoted,
};

/// 子节点绘制带 = paint_order.PaintBand（regular / sticky / positive_z），
/// 与 hit_runtime 共用同一判定函数，见 core/paint_order.zig。
pub const ChildRenderPass = @import("../paint_order.zig").PaintBand;

// ─────────────────────────────────────────────────────────────────────────────
// 执行计划：决定缓存策略、显示列表策略、重建策略
// ─────────────────────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────────────────────
// 桥范围 / 内容切片
// ─────────────────────────────────────────────────────────────────────────────

/// Per-pass list of child node ids that contributed to the parent's paint.
/// finalizeNodeCaches 用这个 + 每个 child 的 runtime.subtree_display_item_*
/// 范围去拼 cache band，**不依赖** cx.display_list 的 idx，因为 child 走
/// subtree-replay / own-replay 短路时不写 display_list 末尾，但 runtime range
/// 仍指向 prebuilt 位置。从 runtime 拼能正确捕获两种路径。
pub const NodeContentSlices = struct {
    regular_children: std.ArrayList(u32),
    sticky_children: std.ArrayList(u32),
    overlay_children: std.ArrayList(u32),
    /// Tail items (overflow_fade) 总是 paint 期间 fresh-emit 到 display_list 末尾，
    /// 这两个 idx 直接切 display_list 拿到。
    tail_start_idx: usize,
    tail_end_idx: usize,
    /// children 是否被本节点 overflow clip 的 node-local token 对包围
    /// （emitScrollClipBegin 返回 true）。promoted cache 拼装据此把这对 token
    /// 一并写进缓存（见 CachedRenderSlice.descendant_clip_open_count）。
    clip_wrapped: bool = false,

    // 无 deinit：三个 children 列表一律分配在 frame arena 上（帧末整体回收），
    // 不允许用通用分配器释放。
};

// ─────────────────────────────────────────────────────────────────────────────
// 效果桥相关（渲染时，非显示列表版本）
// ─────────────────────────────────────────────────────────────────────────────

/// EffectBridgeEntry：渲染时效果桥链上的单条记录
pub const EffectBridgeEntry = struct {
    effect_id: u32,
    effect: @import("../property_tree.zig").EffectNode,
    state: layer_tree_mod.LayerTree.EffectPlanState,
};

/// ReplayBridgeOptions：回放缓存命令时的桥选项
pub const ReplayBridgeOptions = struct {
    use_bridge: bool,
    reuse_origin: bool,
    parent_effect_id: u32 = @import("../property_tree.zig").INVALID_ID,
    exec_plan: ?NodeExecutionPlan = null,
};
