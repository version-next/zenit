const std = @import("std");

const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const text_layout = @import("../text_layout.zig");
const property_tree_mod = @import("../property_tree.zig");
const layer_tree_mod = @import("../layer_tree.zig");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");
const retained_scene = @import("../retained_scene.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const paint_order = @import("../paint_order.zig");

const render_context_mod = @import("render_context.zig");
pub const RenderContext = render_context_mod.RenderContext;

// 子模块：已提取的独立功能
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
    destination: []*Node,
    original: []*Node,
};

/// Stable-sort sibling paint order for the duration of a render pass. The
/// logical Node tree is restored before renderNode returns, so layout and
/// caller-owned child order remain unchanged while every paint/cache path sees
/// the same ordering.
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
        @memcpy(restore.destination, restore.original);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 子模块导入别名：将子模块的类型和函数引入当前命名空间
// ─────────────────────────────────────────────────────────────────────────────

// node_state：核心数据结构体
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

// node_style_render：背景/边框/阴影/媒体渲染
const makeDisplayItemHeader = style_render.makeDisplayItemHeader;
const appendNodeShadowAndBackground = style_render.appendNodeShadowAndBackground;
const appendNodeBorder = style_render.appendNodeBorder;
const appendNodeOutline = style_render.appendNodeOutline;
const appendNodeMedia = style_render.appendNodeMedia;

// text_item_render：DisplayList 文本项生成
const appendDisplayTextItem = text_item_render.appendDisplayTextItem;

// 波浪线下划线（diagnostic squiggle）纯几何工具，对外暴露做单测
pub const WavyParams = text_item_render.WavyParams;
pub const wavyCenterAt = text_item_render.wavyCenterAt;
pub const wavyDotStep = text_item_render.wavyDotStep;

// text_render：文本渲染
const resolveNodeLogicalTextProps = text_render.resolveNodeLogicalTextProps;
const computeContentExtent = text_render.computeContentExtent;
const renderOverflowFade = text_render.renderOverflowFade;

// cache_finalize：节点缓存最终化
const finalizeNodeCaches = cache_finalize.finalizeNodeCaches;

// retained_metadata：PropertyTree 写入 + SceneRuntime 更新 + 调试工具
const shouldDebugOverlayNode = retained_meta.shouldDebugOverlayNode;
const debugOverlayPlan = retained_meta.debugOverlayPlan;
const appendRetainedMetadata = retained_meta.appendRetainedMetadata;

// effect_bridge：效果/裁剪桥接层

// display_list_lowering：DisplayItem local->world lowering 主路径。
// 2026-05-08 重命名 display_list_replay -> display_list_lowering 后保留 4 个 alias
// 给 tests.zig：getNodeDisplayItems / getNodeTextBlobs / getNodeDisplayPayload /
// appendNodeDisplayPayloadToRenderList。GpuDraw B-7 paint_table 主路径接入后再
// 评估能否进一步内联到 cx.render() 末尾、彻底删本文件。
pub const getNodeDisplayItems = display_list_lowering_mod.getNodeDisplayItems;
pub const getNodeTextBlobs = display_list_lowering_mod.getNodeTextBlobs;
pub const getNodeDisplayPayload = display_list_lowering_mod.getNodeDisplayPayload;
pub const appendNodeDisplayPayloadToRenderList = display_list_lowering_mod.appendNodeDisplayPayloadToRenderList;
const appendNodeDisplayPayloadToRenderListForReplay = display_list_lowering_mod.appendNodeDisplayPayloadToRenderListForReplay;

/// 当前帧的 dt（秒），由 tickBeforeRender 设置，供 on_before_render hook 读取
pub var current_frame_dt_seconds: f32 = 1.0 / 60.0;

/// 当前帧的绝对时间戳（ms），单调递增，相对于应用启动。
/// 动画系统通过 (now_ms - start_time_ms) / duration 计算精确 progress，零累积误差。
pub var current_frame_time_ms: f64 = 0;
/// 记录设置 `current_frame_time_ms` 时的真实单调时钟（ms），用于事件阶段估算“当前时刻”。
pub var current_frame_monotonic_ms: f64 = 0;
/// 当前帧的增量 dt（ms），保留给 Spring 物理模拟等需要增量的消费者。
pub var current_frame_dt_ms: f32 = 16.667;

pub const FrameClock = struct {
    time_ms: f64,
    dt_ms: f32,
    dt_seconds: f32,
};

pub fn setFrameClock(clock: FrameClock) void {
    current_frame_time_ms = clock.time_ms;
    current_frame_monotonic_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp())) / 1_000_000.0;
    current_frame_dt_ms = clock.dt_ms;
    current_frame_dt_seconds = clock.dt_seconds;
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
    const raw = std.c.getenv("ZENIT_DISABLE_SPANNED_TEXT_RETAINED");
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

/// custom_draw 回调上下文：直接写 lowered DisplayItem，替代子节点递归
pub const DrawContext = struct {
    /// Maps absolute anchors to the active surface content frame.
    content_from_world: Transform2D = Transform2D.identity(),
    lowering_buffer: *std.ArrayList(display_list_mod.DisplayItem),
    /// encoder 主路径吃 paint_table.DisplayItem；DrawContext 暴露此
    /// buffer 给 snapshot.appendTo 等需要直接写到 encoder 路径的 caller。
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
};

/// Pre-render pass: tickBeforeRender 公共入口（转发到 tick 子模块）
pub fn tickBeforeRender(node: *Node, offset_x: f32, offset_y: f32, clip_opt: ?ComputedRect, allocator: Allocator, dt_ms: f32) bool {
    return tick_mod.tickBeforeRender(node, offset_x, offset_y, clip_opt, allocator, dt_ms, current_frame_time_ms);
}

// ─────────── 帧初始化 ───────────

fn beginRetainedFrame(cx: *RenderContext) void {
    cx.display_payload_prefix_broken = false;
    cx.scene_runtime.clear();
    cx.property_tree.clear();
    cx.layer_tree.planClear();
    cx.display_list.clear();
    cx.text_blob_store.clear();
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
        // 不可降级：这是 property_tree 的根 transform（id 0），后续所有
        // transform_id 都相对它编号。缺失 -> 全帧 transform 索引整体错位。
    }) catch @panic("OOM: property_tree root transform append");
}

// ─────────── 显示列表 payload 范围更新 ───────────

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

// ─────────── 显示列表决策 ───────────

fn canUseSafeSelfEffectDisplayPayload(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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
    exec_state: NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    const allow_safe_self_effect = canUseSafeSelfEffectDisplayPayload(cx, node, exec_state, active_parent_effect_id);
    const uses_relative_effect_space = active_parent_effect_id != INVALID_ID or allow_safe_self_effect;
    // Phase G experiment: removed `hasScrollAncestor` restriction.
    // Replay path reads world transforms from property tree at replay time,
    // so coordinates stay correct across scroll. The previous restriction
    // completely disabled own-content display list caching for all editor
    // content (which lives inside a ScrollArea), forcing every frame to
    // rebuild ~100 nodes. Measured ph_rep=55ms p50 on sqlite3_test.c edit_cfile.
    // blur-only effect owner（无 opacity layer / rounded_clip 捕获面）可表示：
    // item 的 effect header 会让 lowering 在正确位置开 begin_blur，内容保持
    // world 帧（.self_blur 同合同）。blur 节点恒 promoted，但它没有内容捕获
    // 面（applyBackdropBlur 即时合成），promoted 拒绝理由（内容走 surface
    // 缓存路径）对它不成立。拒绝它会把嵌套 blur 子树整棵推回 paint pass
    // 尾部 fresh emit -> 存储序倒挂，玻璃背板糊掉树序在后的兄弟内容
    //（下游应用 header 双层毛玻璃 + 面包屑消失实拍）。
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
    exec_state: NodeExecutionState,
    _: u32,
) !bool {
    return appendNodeDisplayPayloadToRenderListForReplay(
        cx,
        node,
        &exec_state,
        .simple,
        .own,
        exec_state.retained_ids.effect_id,
    );
}

fn tryReplayOwnContentFromPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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
    if (std.posix.getenv("ZENIT_DISABLE_SUBTREE_PAYLOAD_REPLAY") != null) return false; // 逃生阀:排查裁剪/残影时切除
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

fn subtreeHasOutOfBandPasses(node: *Node) bool {
    for (node.children.items) |child| {
        if (child.style.position == .sticky) return true;
        if (child.style.z_index() > 0) return true;
        if (subtreeHasOutOfBandPasses(child)) return true;
    }
    return false;
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
    exec_state: NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    active_parent_effect_id: u32,
) bool {
    const allow_safe_self_effect = canUseSafeSelfEffectDisplayPayload(cx, node, exec_state, active_parent_effect_id);
    const uses_relative_effect_space = active_parent_effect_id != INVALID_ID or allow_safe_self_effect;
    if (node.children.items.len == 0) return false;
    if (node.frame_state.state_bits.flags.has_custom_draw_subtree) return false;
    if (hasBeforeRenderHookSubtree(node)) return false;
    if (node.tag == .scroll or node.tag == .input) return false;
    // Phase G experiment: removed `hasScrollAncestor` restriction here too.
    // See comment in `canRepresentOwnContentInDisplayList`.
    if (subtreeHasOutOfBandPasses(node)) return false;
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
    exec_state: NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    const exec_plan = buildNodeExecutionPlan(cx, node, exec_state, active_parent_effect_id);
    if (!shouldUseDisplayListForSimpleSubtree(cx, node, exec_state, exec_plan, active_parent_effect_id)) return false;

    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) return false;
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            exec_state.effective_clip,
            exec_state.subtree_force_linear_text,
        ) orelse return false;
        const child_exec_plan = buildNodeExecutionPlan(cx, child, child_exec_state, exec_state.retained_ids.effect_id);
        if (child.children.items.len == 0) {
            if (!canRepresentOwnContentInDisplayList(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) return false;
            if (child_exec_plan.should_try_promoted_replay or child_exec_plan.should_try_legacy_overflow_replay) return false;
            if (child_exec_plan.should_write_promoted_cache or child_exec_plan.should_write_legacy_overflow_cache) return false;
            continue;
        }
        if (!subtreeCanUseDisplayListPrepass(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) return false;
    }
    return true;
}

fn subtreeCanUseDisplayListPrepassWithSelfScale(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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
    if (subtreeHasOutOfBandPasses(node)) return false;
    if (exec_state.retained_ids.effect_id == INVALID_ID) return false;
    if (exec_state.retained_ids.effect_id == active_parent_effect_id) return false;

    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) return false;
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            exec_state.effective_clip,
            exec_state.subtree_force_linear_text,
        ) orelse return false;
        const child_exec_plan = buildNodeExecutionPlan(cx, child, child_exec_state, exec_state.retained_ids.effect_id);
        if (child.children.items.len == 0) {
            if (!canRepresentOwnContentInDisplayList(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) return false;
            if (child_exec_plan.should_try_promoted_replay or child_exec_plan.should_try_legacy_overflow_replay) return false;
            if (child_exec_plan.should_write_promoted_cache or child_exec_plan.should_write_legacy_overflow_cache) return false;
            continue;
        }
        if (subtreeCanUseDisplayListPrepassWithSelfScale(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (!subtreeCanUseDisplayListPrepass(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) return false;
    }
    return true;
}

fn subtreeCanUseDisplayListPrepassWithSelfBlur(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    active_parent_effect_id: u32,
) bool {
    if (effectiveBackdropBlurRadius(node) < 0.5) return false;
    if (hasScrollAncestor(node)) return false;
    if (@abs(node.style.scale_x() - 1.0) > 0.0001 or @abs(node.style.scale_y() - 1.0) > 0.0001) return false;
    if (@abs(node.style.rotate()) > 0.0001) return false;
    if (node.getOpacity() < 0.999) return false;
    // 无子节点的 blur 节点（如下游应用 header 的毛玻璃通铺带）也必须走 prepass：
    // display_list 存储序 = z 序，若它被 prepass 拒绝而落到 paint pass 尾部
    // fresh emit，会排到**树序在它之后、但走了 prepass** 的兄弟内容后面,
    // 玻璃背板画在后画内容之上，把文字整片糊掉（下游应用 header 面包屑消失
    // 实拍）。leaf 的 own 内容即 subtree payload，.self_blur 的世界坐标
    // 语义对 leaf 同样成立。
    if (node.frame_state.state_bits.flags.has_custom_draw_subtree) return false;
    if (subtreeHasOutOfBandPasses(node)) return false;
    if (exec_state.retained_ids.effect_id == INVALID_ID) return false;
    if (exec_state.retained_ids.effect_id == active_parent_effect_id) return false;

    const exec_plan = buildNodeExecutionPlan(cx, node, exec_state, active_parent_effect_id);
    if (exec_plan.should_try_legacy_overflow_replay) return false;
    if (exec_plan.should_write_legacy_overflow_cache) return false;

    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) return false;
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            exec_state.effective_clip,
            exec_state.subtree_force_linear_text,
        ) orelse return false;
        const child_exec_plan = buildNodeExecutionPlan(cx, child, child_exec_state, exec_state.retained_ids.effect_id);
        if (child.children.items.len == 0) {
            // 嵌套 blur 叶子（progressive blur 内层）：blur 恒 promoted ->
            // should_write_promoted_cache 会误拒；它自身能走 self_blur 即合格。
            if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) continue;
            if (!canRepresentOwnContentInDisplayList(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) return false;
            if (child_exec_plan.should_try_promoted_replay or child_exec_plan.should_try_legacy_overflow_replay) return false;
            if (child_exec_plan.should_write_promoted_cache or child_exec_plan.should_write_legacy_overflow_cache) return false;
            continue;
        }
        if (subtreeCanUseDisplayListPrepassWithSelfScale(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) continue;
        if (!subtreeCanUseDisplayListPrepass(cx, child, child_exec_state, exec_state.retained_ids.effect_id)) return false;
    }
    return true;
}

fn shouldPreferDisplayListPrepassChildren(
    _: anytype,
    node: *Node,
    exec_state: NodeExecutionState,
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
        markNodeSubtreeRenderedClean(child);
    }
}

// ─────────── 跨帧子树 payload 缓存（单点脏帧放大器修复） ───────────
//
// 现状：display_list / scene_runtime / property_tree 每帧全清重建，任意一个
// 叶子 markRenderDirty 会把 subtree_render 冒泡到根，prebuild pass 对整棵
// simple 子树全量重录（appendNodeOwnContent × 全树），O(全树) 放大器。
//
// 修法：prebuild fresh 路径为每个 .simple 子树节点写一份跨帧 DisplayItem
// 副本（text_run 物化断开 blob 引用，content/spans 深拷贝）。下一帧重录父
// 子树时，干净的兄弟子树直接 appendSlice 缓存副本（splice），只有脏子树 +
// 根路径 fresh 重录。失效语义与 promoted cache 同源：
//   - 缓存 header 的 transform/effect/clip id 是写入帧的帧内序号；根 id 三元组
//     未平移 ⇒ 遍历前缀未变 ⇒ 子树内序号未变，可安全 splice；否则 MISS。
//   - 节点或子树任何 dirty 位（render/layout/composite × self/subtree）-> MISS。
//   - hooks / custom_draw / overlay / 动画 / disable_render_cache -> 不参与。
// 坐标正确性：缓存 item 是 local 空间 + transform_id header，lower 时读当帧
// property tree 的最新矩阵，祖先平移/滚动不需要失效缓存。

/// 单节点缓存 item 数上限：限制祖先-后代重叠拷贝的内存放大
/// （根子树不缓存、叶/小分支缓存 -> splice 粒度自然落在兄弟层级）。
const subtree_payload_cache_max_items: usize = 256;

/// before_render hook 是否已声明"只影响自身"（NodeFlags 同名位）。
///
/// 命中时 prebuild **不**打断 paint 前缀：hook 所在节点自身仍然不参与跨帧
/// payload 缓存（nodeEligibleForSubtreePayloadCache 里的 hasBeforeRenderHooks
/// 那条继续拦它），但它的**兄弟与后代**恢复正常的缓存资格。
///
/// 两条不可放行的例外，与声明位无关（调用方担保不了它们）：
///   - overlay candidate：弹层每帧由 hook 重定位（setPopoverTranslate），
///     预录会烘焙首帧 translate=0 的位置 -> 内容残留左上角。
///   - 活跃的手动 transform/opacity 动画：hook 每帧写的就是祖先级变换。
///
/// 逃生阀 ZENIT_DISABLE_HOOK_SELF_SCOPE=1 -> 整个降级失效，回到保守语义。
fn hookScopeIsSelfOnly(node: *Node, exec_state: NodeExecutionState, parent_effect_id: u32) bool {
    if (!node.frame_state.state_bits.flags.before_render_hook_affects_self_only) return false;
    // 逃生阀与同文件其它两处（ZENIT_DISABLE_SUBTREE_PAYLOAD_REPLAY/
    // ZENIT_DISABLE_SUBTREE_SPLICE）保持一致：不缓存。
    // 交叉审查提醒：进程级一次性 cache 会把值焊死，同一测试二进制内再也
    // 覆盖不到另一分支，且行为与"当前 env"矛盾，排查时极具误导性。
    // 这条判定每帧至多每节点一次，getenv 的开销不值得用那份风险去换。
    if (std.posix.getenv("ZENIT_DISABLE_HOOK_SELF_SCOPE") != null) return false;
    // 例外一：弹层重定位由 hook 每帧改 transform，担保不成立。
    if (exec_state.retained_runtime.is_overlay_candidate) return false;
    // 例外二：手动动画进行中时 hook 写的是变换本身。
    const flags = node.frame_state.state_bits.flags;
    if (flags.manual_transform_animation_active or flags.manual_opacity_animation_active) return false;
    // 例外三：本节点自己是 promoted surface owner。
    if (exec_state.is_promoted_layer) return false;
    // 例外四（storybook damage-rect 回归实测）：**位于某个 retained/effect
    // surface 之内**的节点不放行。
    //
    // 机制：retained 层的部分重绘（opacity_layer.zig:730-741）靠"本帧内容没命中
    // 缓存 -> 重录 -> diff 出脏区"来产出 damage rect。一旦本节点的内容改走跨帧
    // splice，retained 层就看不到这次变化，partial_repaints 不再增长,
    // 实测 storybook「modal 内按钮悬停触发部分重绘」从 PASS 变 FAIL
    // （107 -> 107，逃生阀关掉即恢复 121/121）。
    //
    // 判据用 parent_effect_id：它沿递归下传，非 INVALID 即表示"祖先链上有
    // effect/promoted surface"，正是 damage-rect 与 promoted cache assembly
    // 两条路径的作用域。这也同时覆盖了交叉审查担心的 GlassLab 形态
    // （blur 岛内的节点）。
    if (parent_effect_id != INVALID_ID) return false;
    return true;
}

fn indexRenderCacheBoundaries(
    allocator: Allocator,
    node: *Node,
    ancestor_has_boundary: bool,
    blocked: *std.AutoHashMapUnmanaged(u32, void),
) !bool {
    const self_is_boundary = node.frame_state.state_bits.flags.disable_render_cache;
    var subtree_has_boundary = self_is_boundary;
    for (node.children.items) |child| {
        if (try indexRenderCacheBoundaries(
            allocator,
            child,
            ancestor_has_boundary or self_is_boundary,
            blocked,
        )) subtree_has_boundary = true;
    }
    if (ancestor_has_boundary or subtree_has_boundary) try blocked.put(allocator, node.id, {});
    return subtree_has_boundary;
}

fn nodeEligibleForSubtreePayloadCache(cx: *const RenderContext, node: *Node, runtime: scene_runtime_mod.SceneNodeRuntime) bool {
    // Reject cheap local conditions before consulting the frame boundary
    // index. The index is built once in O(N), avoiding a repeated ancestor +
    // subtree walk for every cache candidate in a deep tree.
    const flags = node.frame_state.state_bits.flags;
    if (flags.disable_render_cache) return false;
    if (flags.has_custom_draw_subtree) return false;
    if (flags.manual_transform_animation_active or flags.manual_opacity_animation_active) return false;
    if (node.hasBeforeRenderHooks()) return false;
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

fn subtreePayloadStampValid(
    runtime: scene_runtime_mod.SceneNodeRuntime,
    cache: node_mod.CachedRenderSlice,
) bool {
    if (cache.cached_transform_id != runtime.transform_id) return false;
    if (cache.cached_effect_id != runtime.effect_id) return false;
    if (cache.cached_clip_id != runtime.clip_id) return false;
    if (cache.content_version != runtime.content_version) return false;
    if (@abs(cache.world_bounds.w - runtime.world_bounds.w) > 0.01) return false;
    if (@abs(cache.world_bounds.h - runtime.world_bounds.h) > 0.01) return false;
    return true;
}

/// 干净子树跨帧 payload splice：命中则整支子树免重录，直接把缓存副本追加到
/// display_list 当前位置（与 fresh prebuild 落点一致，paint-order 不变式保持），
/// 并回填 runtime ranges + prebuilt 标记，paint pass 走既有 subtree-replay 短路。
fn trySpliceSubtreePayloadCache(cx: *RenderContext, node: *Node) !bool {
    if (std.posix.getenv("ZENIT_DISABLE_SUBTREE_SPLICE") != null) return false; // 逃生阀:排查裁剪/残影时切除
    const cache = node.meta.per_frame.caches.commands.subtree_payload orelse return false;
    if (!nodeCleanForSubtreePayloadSplice(node)) return false;
    const runtime = cx.scene_runtime.get(node.id) orelse return false;
    // Stamp checks are O(1). Do them before the boundary tree walk and evict
    // caches that can no longer be reused, otherwise a deep tree can rescan the
    // same stale subtrees every frame.
    if (!subtreePayloadStampValid(runtime, cache)) {
        dropSubtreePayloadCache(node);
        return false;
    }
    if (!nodeEligibleForSubtreePayloadCache(cx, node, runtime)) {
        dropSubtreePayloadCache(node);
        return false;
    }

    const start = cx.display_list.items.items.len;
    try appendCachedCommands(cx, cache.commands);
    // 记账用 append 后的实际长度差：appendCachedCommands 会静默 continue
    // 跳过本帧无 scene_runtime 记录的缓存项（后代被 cull），用 cache.commands.len
    // 会虚高，splice 追加在列表尾，虚高范围会侵入后续 sibling 的显示项，
    // 下次以此为源重建缓存时把邻居的 item 吸进来。
    const appended: u32 = @intCast(cx.display_list.items.items.len - start);
    if (cx.scene_runtime.nodes.getPtr(node.id)) |rt| {
        rt.display_item_start = @intCast(start);
        rt.display_item_count = cache.self_content_command_count;
        // 缓存内文本已物化（content 内联，blob 断开），blob range 置零。
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
    }
    cx.perf.subtree_payload_splice_count += 1;
    return true;
}

/// fresh prebuild 后写跨帧缓存：拷贝本子树刚写入 display_list 的区段，
/// 物化 text blob 引用后深拷贝持久化。仅 .simple 策略子树内调用。
fn maybeWriteSubtreePayloadCache(cx: *RenderContext, node: *Node, subtree_display_start: usize) void {
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
    if (!nodeEligibleForSubtreePayloadCache(cx, node, runtime)) {
        dropSubtreePayloadCache(node);
        return;
    }

    const buf = cx.frame_allocator.alloc(DisplayItem, count) catch return;
    @memcpy(buf, cx.display_list.items.items[subtree_display_start..end]);
    // 跨帧自包含化（同 assembleCacheCommands）：blob-backed text_run 就地物化，
    // 断开对每帧重建 text_blob_store 的 id 引用（blob_id 跨帧失效坑）。
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
    // stamp content_version 与 runtime 对齐（buildCachedRenderSlice 取的是
    // node 缓存 versions，splice 端比对的是 runtime.content_version）。
    if (node.meta.per_frame.caches.commands.subtree_payload) |*cache| {
        cache.content_version = runtime.content_version;
    }
    cx.perf.subtree_payload_cache_write_count += 1;
}

fn prebuildSimpleDisplayPayloadSubtree(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    allow_subtree_payload_cache: bool,
) anyerror!void {
    const subtree_display_start = cx.display_list.items.items.len;
    const subtree_blob_start = cx.text_blob_store.blobs.items.len;

    // R3c: appendNodeOwnContent 仍写 cx.lowering_buffer（effect_bridge 路径）但
    // 这一帧整个 cx.lowering_buffer 末尾被 derive clear+rewrite，不需要 prebuild
    // truncate 保护主 buffer。display_list 写出物保留，它就是 prebuilt payload。
    try appendNodeOwnContent(cx, node, exec_state);
    setNodeDisplayPayloadOwnPrebuilt(cx, node.id, true);

    // scroll 容器的像素裁剪对必须录进 prebuilt payload(children 包围),
    // 否则 subtree replay / splice 命中帧零裁剪,见 prebuildScrollClipBegin。
    const scroll_clip_on = try prebuildScrollClipBegin(cx, node, exec_state);
    for (node.children.items) |child| {
        if (!shouldRenderChildInPass(child, exec_state.use_opacity_layer, .regular)) continue;
        // 下游回归：干净兄弟子树跨帧 payload 命中 -> 直接 splice，免重录。
        if (allow_subtree_payload_cache and try trySpliceSubtreePayloadCache(cx, child)) continue;
        // prebuild 阶段不传 parent_clip 给子节点，避免 viewport culling 导致
        // 缓存的 display payload 缺少被 cull 子节点的内容。
        // display payload 是跨帧复用的，但 clip 区域会因滚动而变化。
        const child_exec_state = buildNodeExecutionState(
            cx,
            child,
            exec_state.content_transform,
            null,
            exec_state.subtree_force_linear_text,
        ) orelse continue;
        try prebuildSimpleDisplayPayloadSubtree(cx, child, child_exec_state, allow_subtree_payload_cache);
    }
    try prebuildScrollClipEnd(cx, exec_state, scroll_clip_on);

    try appendNodeOverflowFade(cx, node, exec_state);

    updateNodeSubtreeDisplayPayloadRanges(cx, node.id, subtree_display_start, subtree_blob_start);
    if (allow_subtree_payload_cache) {
        maybeWriteSubtreePayloadCache(cx, node, subtree_display_start);
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
    // Paint-order 前缀不变式：前面某个节点已把内容留给 paint pass，
    // 那么 paint 顺序在其后的一切都必须同样留给 paint pass fresh emit
    // 这里再 prebuild 会让"后画"的 items 排到"先画"的 fresh items
    // 之前（fresh 只能追加在表尾）。scene_runtime 每帧清零，默认即
    // not-prebuilt，直接返回即可。
    if (cx.display_payload_prefix_broken) return;
    const crosses_cache_boundary = if (cx.render_cache_boundary_blocked) |blocked|
        blocked.contains(node.id)
    else
        true;
    // A boundary flag is intentionally outside the payload stamp. Evict before
    // the clean-runtime shortcut so a newly enabled descendant boundary cannot
    // inherit last frame's "already prebuilt" state and bypass this pass.
    if (crosses_cache_boundary) dropSubtreePayloadCache(node);
    // 快速跳过：节点和子树都 clean 且已有有效 prebuild payload -> 不需要重建
    if (!crosses_cache_boundary and
        !node.frame_state.state_bits.dirty.core.render and
        !node.frame_state.state_bits.dirty.core.subtree_render)
    {
        if (cx.scene_runtime.get(node.id)) |runtime| {
            if (runtime.display_payload_subtree_prebuilt) return;
        }
    }
    // 下游回归：干净子树跨帧 payload 命中 -> 整支免重录（含 own/subtree 两个
    // prebuild pass, subtree_prebuilt=true 会让 own pass 与 paint pass 都短路）。
    if (try trySpliceSubtreePayloadCache(cx, node)) return;
    setNodeDisplayPayloadSubtreePrebuilt(cx, node.id, false, .none);
    const exec_state = buildNodeExecutionState(
        cx,
        node,
        parent_transform,
        parent_clip,
        inherited_force_linear_text,
    ) orelse return;

    // Overlay 候选（z_index>0）且自带 before_render hook 的节点（Popover/Menu/
    // Dropdown content）每帧由 hook 在 render 时重定位（setPopoverTranslate）。
    // 跨帧 prebuild 的 display payload 会按**首次 prebuild 时**的 transform 烘焙
    // （弹层刚开时 translate=0 -> 内容在 (0,0)），之后被 replay 在旧位置 -> 弹层
    // 内容残留屏幕左上角。这类节点不参与跨帧 payload 缓存，强制每帧 paint pass
    // 走真实 world transform 重新发射，与 hook 定位一致。
    //
    // 注意：composited_group surface owner（Modal/Sheet）**不**在此排除，它的子树
    // payload 必须正常 prebuild，否则 promoted-surface cache assembly
    // （node_cache_finalize.assembleCacheCommands）的 regular_children 取不到子项 ->
    // settle 帧 dialog 只剩 self（白底框）、标题/×/body 全丢。
    if (node.hasBeforeRenderHooks() and
        (exec_state.retained_runtime.is_overlay_candidate or
            !exec_state.retained_runtime.content_flags.has_custom_draw) and
        !hookScopeIsSelfOnly(node, exec_state, parent_effect_id))
    {
        // 内容留给 paint pass -> 前缀到此为止（不变式见 prefix_broken 声明）。
        // 不限 overlay candidate：任何 before_render hook（拖拽 spring 写
        // translate、滚动条 fade 等）都逐帧改变本子树的 transform/内容，
        // prebuild 下潜预录其子会烘焙**本帧 hook 运行前**的状态；paint 侧一旦
        // 又对同一子树 fresh/direct 发射，就得到"半 prebuilt 半 fresh"的
        // 双份（GlassLab 拖拽球滚动闪烁根因：settle 帧 prebuild 深入 ->
        // 玻璃+高光双合成偏白，滚动帧 prefix 早断 -> 单份，两态逐帧切换）。
        // 例外：custom-draw 节点（Spinner/Progress）的 hook 只推进动画参数，
        // own 内容经 display payload replay 按本帧 transform 重投影是安全设计
        //（有单测锚定 display_list_own_replay_count），保持原预录路径。
        cx.display_payload_prefix_broken = true;
        return; // 保持 subtree_prebuilt=false → paint pass fresh emit
    }

    if (subtreeCanUseDisplayListPrepassWithSelfScale(cx, node, exec_state, parent_effect_id)) {
        try prebuildSimpleDisplayPayloadSubtree(cx, node, exec_state, false);
        setNodeDisplayPayloadSubtreePrebuilt(cx, node.id, true, .self_scale);
        cx.perf.display_list_subtree_prebuild_count += 1;
        return;
    }
    if (subtreeCanUseDisplayListPrepassWithSelfBlur(cx, node, exec_state, parent_effect_id)) {
        try prebuildSimpleDisplayPayloadSubtree(cx, node, exec_state, false);
        setNodeDisplayPayloadSubtreePrebuilt(cx, node.id, true, .self_blur);
        cx.perf.display_list_subtree_prebuild_count += 1;
        return;
    }
    if (subtreeCanUseDisplayListPrepass(cx, node, exec_state, parent_effect_id)) {
        if (!shouldPreferDisplayListPrepassChildren(cx, node, exec_state)) {
            const strategy: scene_runtime_mod.DisplayPayloadSubtreeStrategy =
                if (canUseSafeSelfEffectDisplayPayload(cx, node, exec_state, parent_effect_id))
                    .self_safe_effect
                else
                    .simple;
            // 跨帧 payload 缓存保守版仅覆盖 .simple 策略（无 self-effect 空间
            // 变换，splice 语义与 fresh emit 完全等价）。
            try prebuildSimpleDisplayPayloadSubtree(cx, node, exec_state, strategy == .simple);
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

    // Stage B S5.2 ordering 修复：在 recurse children 前先 emit 自己 own
    // content，让 display_list 顺序与 paint pass walk (own -> children)
    // 一致。否则 prebuildOwnDisplayPayloads pass 会把 root own 推迟到所有
    // children subtree 之后写，导致 PERMUTATION 视觉错乱（parent 覆盖
    // children）。
    setNodeDisplayPayloadOwnPrebuilt(cx, node.id, false);
    const own_prebuilt = try prebuildOwnDisplayPayloadForNode(cx, node, exec_state, parent_effect_id);
    if (std.posix.getenv("ZENIT_DEBUG_PREPASS") != null) {
        std.debug.print("[prepass] node={d} fallback own_prebuilt={} has_own={} children={d}\n", .{ node.id, own_prebuilt, nodeHasOwnPaintContent(node, exec_state), node.children.items.len });
    }

    // Paint-order 不变式：display_list raw 顺序 == paint 顺序（own -> children）。
    // 若 own 内容存在但**不能**先行 prebuild（典型：is_promoted_layer surface owner，
    // canRepresentOwnContentInDisplayList=false），children 也不得 prebuild，否则
    // children 先落 list、own 由 paint pass 追加到末尾，derive 后父背景盖住整个子树
    // （settle 帧 Modal 空白面板的根因）。整棵留给 paint pass 按正确顺序 fresh emit；
    // paint pass renderNodeTransform 会回填 subtree ranges，promoted cache assembly
    // 仍取得到 children items。
    if (!own_prebuilt and nodeHasOwnPaintContent(node, exec_state)) {
        // own（典型：rotate/scale 变换、promoted surface owner）只能由
        // paint pass fresh emit -> 前缀到此为止
        cx.display_payload_prefix_broken = true;
        return; // subtree_prebuilt=false → paint pass fresh emit
    }

    // scroll 容器 children 的裁剪对同样要录进 fallback 路径的 display_list
    // 区段(paint pass 对局部 prebuilt 的子孙仍可能走 replay 短路),
    // 见 prebuildScrollClipBegin。
    const scroll_clip_on = try prebuildScrollClipBegin(cx, node, exec_state);
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
    try prebuildScrollClipEnd(cx, exec_state, scroll_clip_on);

    // Stage B S5.2: 跟 simple subtree 路径对齐，fall-through 也 emit overflow_fade
    // 到 display_list。R3c 后 cx.lowering_buffer 整体被 derive 覆盖，无需 truncate
    // paint pass 写入。
    // 前缀不变式：children 循环里若有子树把内容留给了 paint pass，fade
    //（paint 顺序在 children 之后）也必须留给 paint pass（paint 侧的
    // appendNodeOverflowFade 会补），否则 fade 会被 fresh children 盖住。
    if (!cx.display_payload_prefix_broken) {
        try appendNodeOverflowFade(cx, node, exec_state);
    }
}

/// 节点自身是否有可见 paint 内容（不含子树）。用于 paint-order 不变式判定：
/// own 有内容但不能先行 prebuild 时，children 不得先落 display_list。
fn nodeHasOwnPaintContent(node: *Node, exec_state: NodeExecutionState) bool {
    const flags = exec_state.retained_runtime.content_flags;
    return flags.has_background or flags.has_border or flags.has_shadow or
        flags.has_image or flags.has_icon or flags.has_custom_draw or node.getText() != null;
}

/// 单节点 own prebuild, emit own content 到 display_list。供
/// prebuildDisplayPayloadSubtrees 在非 simple 路径递归 children 前调用，让
/// display_list 顺序与 paint pass walk (own -> children) 一致。返回是否成功
/// prebuilt own。
fn prebuildOwnDisplayPayloadForNode(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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
    // 前缀不变式（同 prebuildDisplayPayloadSubtrees 入口）：own pass 跑在
    // subtree pass 之后、追加在表尾，前缀一旦截断，这里补录的 own 会
    // 排到断点后 fresh 内容之前，同样错序。断点前的节点要么整支 prebuilt
    //（本函数开头就跳过），要么 own 已在 subtree pass 落位（epoch 检查
    // 跳过），全局 bail 不会漏掉合法工作。
    if (cx.display_payload_prefix_broken) return;
    const runtime = cx.scene_runtime.get(node.id) orelse return;
    if (runtime.display_payload_subtree_prebuilt) return;

    const exec_state = buildNodeExecutionState(
        cx,
        node,
        parent_transform,
        parent_clip,
        inherited_force_linear_text,
    ) orelse return;

    // Stage B S5.2: 若 prebuildDisplayPayloadSubtrees 已经在递归 children
    // 前处理过该节点 own (display_payload_own_prebuilt=true 当帧)，则跳过，
    // 避免重复 emit。display_list ordering 由 subtree pass 维护 (own 先于
    // children 写入)。
    if (runtime.display_payload_own_prebuilt and
        runtime.display_payload_own_prebuilt_epoch == cx.scene_runtime.frame_epoch)
    {
        // 已被 subtree pass prebuilt，仅需 recurse children
    } else {
        setNodeDisplayPayloadOwnPrebuilt(cx, node.id, false);
        const own_prebuilt = try prebuildOwnDisplayPayloadForNode(cx, node, exec_state, parent_effect_id);
        // Paint-order 不变式（与 prebuildDisplayPayloadSubtrees 同理）：own 有可见
        // 内容但不能先行 prebuild -> children 也不得先落 display_list，整棵留给
        // paint pass fresh emit（否则父背景在 derive 后盖住 children）。
        if (!own_prebuilt and nodeHasOwnPaintContent(node, exec_state)) return;
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

// ─────────── 显示载荷预构建 ───────────

fn prebuildDisplayPayloads(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    inherited_force_linear_text: bool,
    parent_effect_id: u32,
) !void {
    var boundary_blocked = std.AutoHashMapUnmanaged(u32, void){};
    defer boundary_blocked.deinit(cx.frame_allocator);
    _ = try indexRenderCacheBoundaries(cx.frame_allocator, node, false, &boundary_blocked);
    const previous_boundary_index = cx.render_cache_boundary_blocked;
    cx.render_cache_boundary_blocked = &boundary_blocked;
    defer cx.render_cache_boundary_blocked = previous_boundary_index;

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

// ─────────── 节点渲染状态计算 ───────────

fn computeNodeRenderState(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
) ?NodeRenderState {
    const self_tx = node.style.translate_x;
    const self_ty = node.style.translate_y;
    const world_transform = geometry.nodeWorldTransform(parent_transform, node);
    // World.LayoutTable 读 rect。
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
    // 外部裁剪矩形（视口系旁表）：节点声明"我受这个矩形裁剪"而无须与裁剪
    // 来源构成父子（宿主场景：画布 frame 与其成员是平铺兄弟 Node）。
    // 与自身 overflow clip 取交；完全出界时下方的 <0.1 早退直接 cull 整树。
    if (cx.external_clip_rects) |ext_map| if (ext_map.get(node.id)) |ecr| {
        const ext = ComputedRect.init(ecr[0], ecr[1], ecr[2], ecr[3]);
        // 交集为空 = 零尺寸 clip，走下方 <0.1 早退把整棵子树 cull 掉。
        clip_world_rect = if (needs_clip)
            (geometry.intersectRect(clip_world_rect, ext) orelse ComputedRect.init(ext.x, ext.y, 0, 0))
        else
            ext;
        needs_clip = true;
    };

    const blur_radius = effectiveBackdropBlurRadius(node);
    const pad_left = node.style.padding.left * scale_x_abs;
    const pad_right = node.style.padding.right * scale_x_abs;
    const pad_top = node.style.padding.top * scale_y_abs;
    const pad_bottom = node.style.padding.bottom * scale_y_abs;
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

    // opacity ≤ 0.001 无条件 cull GPU draw，含 prewarm 隐藏副本（HIDDEN_OPACITY=0.001）。
    // keep_rendering_when_transparent 只决定**是否留在 tick/layout traversal**
    // （见 tick.zig：让隐藏子树的 transition 继续推进、layout 测量通路保持预热），
    // **不**决定是否发射 paint。早先把该 flag 接进 paint cull -> prewarm 副本以
    // 0.001 经 GPU 混色后在屏幕左上角 (0,0) 留下肉眼可见淡残影（overlay prewarm 把
    // translate reset 到 0）。这里解耦两件事：0.001 永远不画，预热仅靠 tick/layout。
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
    const use_rounded_clip = shouldUseRoundedClipBridge(node, clip_spec.shape_kind, clip_spec.radius, use_opacity_layer, blur_radius > 0);

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
        .clip_radius = clip_spec.radius,
        .clip_polygon = clip_spec.polygon,
        .clip_bounds_fallback = clip_spec.bounds_fallback,
        .use_blur = blur_radius >= 0.5,
        .use_rounded_clip = use_rounded_clip,
    };
}

/// "本节点是否开 offscreen opacity/composited surface" 的唯一真值表。
/// 曾在 computeNodeRenderState / computeNodeContentRenderState 各复制一份，
/// P6.3 收敛为单点（提升判定归一的第一步）。
fn computeUseOpacityLayer(
    node: *Node,
    has_rotation: bool,
    has_scale: bool,
    prepromote_composite: bool,
    needs_clip: bool,
    blur_radius: f32,
    node_opacity: f32,
) bool {
    return node.style.composited_group() or
        // 非 normal blend 必须独立光栅化成 src 再与背景做 W3C 混合。
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
    // P6.3 后 content_transform 语义唯一：surface 内 unscaled 渲染（include_scale=false），
    // scale 由 surface composite 的 draw_transform 统一施加。不再有 inline_scale 分叉。
    const content_transform = retained_scene.buildNodeWorldTransform(node, parent_transform, .{
        .include_scale = false,
        .include_rotation = false,
    });
    // World.LayoutTable 读 rect。
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
    // 外部裁剪矩形：与 computeNodeRenderState 同一注入（见彼处注释）。
    // 矩形是视口系；宿主只对无 scale/rotation、不在 effect surface 内的
    // 平铺节点标注，此时 content 帧与 world 帧重合。
    if (cx.external_clip_rects) |ext_map| if (ext_map.get(node.id)) |ecr| {
        const ext = ComputedRect.init(ecr[0], ecr[1], ecr[2], ecr[3]);
        clip_content_rect = if (needs_clip)
            (geometry.intersectRect(clip_content_rect, ext) orelse ComputedRect.init(ext.x, ext.y, 0, 0))
        else
            ext;
        needs_clip = true;
    };

    const blur_radius = effectiveBackdropBlurRadius(node);
    const pad_left = node.style.padding.left * scale_x_abs;
    const pad_right = node.style.padding.right * scale_x_abs;
    const pad_top = node.style.padding.top * scale_y_abs;
    const pad_bottom = node.style.padding.bottom * scale_y_abs;
    const node_opacity = std.math.clamp(node.getOpacity(), 0.0, 1.0);
    const prepromote_composite = node.style.z_index() > 0 and
        (node.style.will_change_transform() or node.style.will_change_opacity());
    const use_opacity_layer = computeUseOpacityLayer(node, has_rotation, has_scale, prepromote_composite, needs_clip, blur_radius, node_opacity);
    const opacity_bounds = if (use_opacity_layer)
        geometry.computeOpacityLayerBounds(node, content_transform, content_rect, scale_x_abs, scale_y_abs, scale_min)
    else
        content_rect;

    // 同 computeNodeRenderState：0.001 prewarm 副本无条件不画（见上方注释），
    // keep_rendering_when_transparent 仅管 tick/layout 预热，不放行 paint。
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
    const use_rounded_clip = shouldUseRoundedClipBridge(node, clip_spec.shape_kind, clip_spec.radius, use_opacity_layer, blur_radius > 0);

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
        .clip_radius = clip_spec.radius,
        .clip_polygon = clip_spec.polygon,
        .clip_bounds_fallback = clip_spec.bounds_fallback,
        .use_blur = blur_radius >= 0.5,
        .use_rounded_clip = use_rounded_clip,
    };
}

fn shouldUseRoundedClipBridge(node: *Node, clip_shape_kind: display_list_mod.ClipShapeKind, radius: f32, use_opacity_layer: bool, use_blur: bool) bool {
    if (clip_shape_kind != .rounded_rect) return false;
    if (radius <= 0.5) return false;
    if (node.frame_state.state_bits.flags.manual_opacity_animation_active or node.frame_state.state_bits.flags.manual_transform_animation_active) return false;
    if (use_blur) return true;
    // rounded_clip effect（及 Stage 3 fold 进 opacity layer 的圆角 mask）是
    // **节点级**的：owner 自己的 shadow / background / border 与后代同在该
    // effect 内，被同一张 mask 裁掉，阴影只剩 border-box 内那一截（Popover
    // 圆角外的矩形灰块），描边与贴边内容同层、被内容盖住。owner 有这类内容时
    // 改走 children 包围的 node-local push_clip（shader SDF 圆角，
    // emitScrollClipBegin），只裁后代。
    if (clip_mod.ownerPaintsOutsideChildClip(node)) return false;
    if (use_opacity_layer) return true;
    // Stage 2 保守收紧：z>0 只在动画期/will_change 时建 rounded_clip effect（保留
    // shouldPromoteLayer 的 surface promote 载体）。静态 z>0 圆角容器改走 ClipNode
    // -> push_clip fallback（Stage 1 shader SDF clip 覆盖），省 effect node/plan
    // layer/两条 display item。will_change 情形实际已被 prepromote_composite ->
    // use_opacity_layer 吸收，此处仅防御性保留。
    const anim_checks = @import("animation_checks.zig");
    return node.style.z_index() > 0 and
        (anim_checks.hasActiveCompositeAnimation(node) or
            node.style.will_change_transform() or
            node.style.will_change_opacity());
}

// ─────────── 属性树构建 ───────────

fn buildRetainedSubtree(
    cx: *RenderContext,
    node: *Node,
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    parent_transform_id: u32,
    parent_clip_id: u32,
    parent_effect_id: u32,
    surface_inverse: Transform2D,
) void {
    if (!node.frame_state.state_bits.dirty.core.render and !node.frame_state.state_bits.dirty.core.subtree_render and !node.frame_state.state_bits.dirty.core.layout and !node.frame_state.state_bits.dirty.core.subtree_layout) {
        if (cx.scene_runtime.get(node.id) != null) return;
    }
    const render_state = computeNodeRenderState(cx, node, parent_transform, parent_clip) orelse return;
    // Retained/property-tree recursion must follow the same content-space transform
    // chain as runtime rendering. For opacity/composited groups, descendants render
    // into the group's unscaled/unrotated surface space; recursing with world_transform
    // here makes retained metadata disagree with the render path and causes promoted
    // surfaces to mix "panel frame" animation with "content relayout" jumps.
    const content_state = computeNodeContentRenderState(cx, node, parent_transform, parent_clip) orelse return;

    // surface owner 的 content transform：是否把 self.world.invert() 折进去，取决于
    // surface composite **是否会重新施加** owner 的 world transform。
    //
    // - has_surface_transform（owner 带 scale / rotation / 非轴对齐）：surface 以
    //   draw_transform 把内容**带着 owner transform 合成回去**，所以 surface 内 content
    //   必须先 surface-local（剥掉 owner world），否则 scale/rotate 被施加两次。此时
    //   surface_inverse = self.world.invert()（S5.2 行为，scale 文本保持清晰、composite 时缩放）。
    //
    // - 纯平移 / 轴对齐（典型 overlay：popover/menu/tooltip 落位后 translate=(dx,dy)，
    //   scale=1，无旋转）：surface 是一次 axis-aligned blit，composite **不**重施 translate，
    //   GPU encoder 的 offscreenOffset = -(surface bounds 原点) 已把 surface 内 world 坐标转
    //   surface-local（见 command_encoder.offscreenOffset / opacity_layer.beginOpacityLayer，
    //   clip bridge 也据此用 world_aabb）。此时 content 必须以 **world 坐标** emit ->
    //   surface_inverse 必须保持 identity。早先无条件用 self.world.invert() 让 content 退化成
    //   owner-relative，但 encoder 减的是含 shadow margin 的 surface bounds 原点，二者错开 ->
    //   整个 overlay 面板飞到屏幕左上角 (0,0)、内容不可见。
    // Stage B S5.2 + 2026-06-06 修：当本节点开 surface (use_opacity_layer) 时，self/children
    // 的 content 用哪种坐标系，取决于 surface 合成方式（必须与 layer_tree.has_surface_transform
    // 一致）：
    //  - **有 surface transform**（owner 自身 scale≠1 / rotate≠0 / 非轴对齐）：composite 用
    //    draw_transform 带着 owner transform 把内容合成回去，故 surface 内 content 必须先剥掉
    //    owner world -> surface_inverse = self.world.invert()。这是 scale_fade **动画期**。
    //  - **纯平移 / 轴对齐**（settled 的居中 dialog：scale=1、rotate=0）：surface 是一次
    //    axis-aligned blit，composite **不**重施 transform，encoder 的 offscreenOffset =
    //    -(surface bounds 原点) 已把 surface 内 world 坐标转 surface-local。此时 content 必须以
    //    **world 坐标** emit -> surface_inverse 保持 identity（继承 parent）。
    //    早先无条件用 self.world.invert() -> content 退化成 owner-relative，但 encoder 减的是
    //    含 shadow margin 的 surface bounds 原点，二者错开 -> 居中 dialog 飞到 (0,0)（先闪左上角
    //    再到中间）。这正是本次要修的 bug。
    // 2026-08-02（下游回归根治）：内容帧的唯一判据是"本节点是否开**内容
    // 捕获**的 offscreen surface"，而不是"是否开 opacity layer"：
    //  - use_opacity_layer（opacity/composited_group/blend/scale/rotate）-> 捕获。
    //  - use_rounded_clip -> promoted rounded_clip effect 在 encoder 恒走 layer
    //    模式（begin token 带 use_draw_transform，见 layer_tree has_surface_transform
    //    恒 true），同样捕获内容进 owner-local 纹理。早先此分支漏掉 ->
    //    "blur+rounded_clip 同节点"的玻璃岛内容以 world 坐标画进 owner-local
    //    纹理（整体偏移出纹理）-> 岛内容全丢只剩玻璃壳。
    //  - use_blur 单独存在（无 clip）-> applyBackdropBlur 即时合成、不开捕获
    //    scope，内容必须保持 world 帧（self_blur replay 同合同），不进此分支。
    const opens_capture_surface = render_state.use_opacity_layer or render_state.use_rounded_clip;
    const self_surface_inverse: Transform2D = if (opens_capture_surface)
        render_state.world_transform.invert()
    else
        surface_inverse;
    // children 的坐标链（content_transform）**不含** owner 的动画 scale/rotate（unscaled
    // rest 帧），故 children 的 surface_inverse 必须是 unscaled 逆，这样 children 的
    // content 在 texture 内是**静态** owner-local，scale 由 M_composite 统一施加。
    // 若沿用含 scale 的完整逆（早先行为），children content 被反向缩放，composite 的
    // scale 恰好抵消 -> "modal 背景在 scale、内容纹丝不动"。own（self）仍用完整逆：
    // 自身 world 含 scale，完整逆使 own content = 纯 local，与 children 同帧。
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
    const child_parent_transform = content_state.content_transform;
    const effective_clip = content_state.effective_clip;

    const child_surface_inverse = surface_child_inverse;

    for (childPasses(render_state.use_opacity_layer)) |pass| {
        for (node.children.items) |child| {
            if (!shouldRenderChildInPass(child, render_state.use_opacity_layer, pass)) continue;

            buildRetainedSubtree(
                cx,
                child,
                child_parent_transform,
                effective_clip,
                retained_ids.transform_id,
                retained_ids.clip_id,
                retained_ids.effect_id,
                child_surface_inverse,
            );
        }
    }
}

fn syncPromotedLayerIds(cx: *RenderContext) void {
    var it = cx.scene_runtime.nodes.iterator();
    while (it.next()) |entry| {
        const root_layer_state = cx.layer_tree.planQueryRootNode(entry.key_ptr.*);
        entry.value_ptr.promoted_layer_id = root_layer_state.promoted_layer_id;
        entry.value_ptr.promoted_surface_flags.surface_valid = root_layer_state.frame_flags.surface_valid;
        entry.value_ptr.promoted_surface_flags.reused_this_frame = root_layer_state.frame_flags.reused_this_frame;
        entry.value_ptr.promoted_surface_flags.rebuilt_this_frame = root_layer_state.frame_flags.rebuilt_this_frame;
        entry.value_ptr.promoted_surface_flags.invalidated_by_descendant_this_frame = root_layer_state.frame_flags.invalidated_by_descendant_this_frame;
        entry.value_ptr.promoted_surface_flags.invalidated_by_self_this_frame = root_layer_state.frame_flags.invalidated_by_self_this_frame;
        entry.value_ptr.promoted_surface_flags.descendant_scoped_rebuild_candidate_this_frame = root_layer_state.frame_flags.descendant_scoped_rebuild_candidate_this_frame;
    }
}

fn syncPromotedDescendantState(cx: *RenderContext, node: *Node) bool {
    const self_has_promoted_layer = cx.layer_tree.planQueryRootNode(node.id).promoted_layer_id != INVALID_ID;
    var descendant_has_promoted = false;

    for (node.children.items) |child| {
        if (syncPromotedDescendantState(cx, child)) {
            descendant_has_promoted = true;
        }
    }

    if (cx.scene_runtime.nodes.getPtr(node.id)) |runtime| {
        runtime.has_promoted_descendant_subtree = descendant_has_promoted;
    }

    return self_has_promoted_layer or descendant_has_promoted;
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
    const content_state = computeNodeContentRenderState(cx, node, parent_transform, parent_clip) orelse return null;
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
    const auto_stabilize_text = retained_runtime.has_active_transform_animation and retained_runtime.content_flags.has_text;

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
        .clip_radius = content_state.clip_radius,
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

fn hasBeforeRenderHookSubtree(node: *Node) bool {
    // O(1)：NodeFlags.has_before_render_subtree 由 addBeforeRender 置位并沿
    // 祖先冒泡、appendChild 并入父链维护（保守不清位：hook 删除后保持 true，
    // 多算 true 只会让本函数更保守地拒绝缓存，方向安全）。替代旧实现每节点
    // 递归下钻（整帧 O(n·depth)）。
    return node.frame_state.state_bits.flags.has_before_render_subtree;
}

fn hasBeforeRenderHookDescendants(node: *Node) bool {
    // 只扫直接子节点（读各自 O(1) 标志），不再递归下钻。
    for (node.children.items) |child| {
        if (child.frame_state.state_bits.flags.has_before_render_subtree) return true;
    }
    return false;
}

// ─────────── 执行计划生成 ───────────

fn buildNodeExecutionPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    active_parent_effect_id: u32,
) NodeExecutionPlan {
    const has_self_before_render_hooks = node.hasBeforeRenderHooks();
    const has_descendant_before_render_hooks = hasBeforeRenderHookDescendants(node);
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

    // disable_spanned_text_retained 只禁止**跨帧**缓存（promoted / legacy overflow），
    // 不禁止同帧内的 display payload prebuild+replay（subtree / own），
    // 否则 prebuild 标记 subtree_prebuilt=true 后 replay 被跳过会导致内容丢失。
    return .{
        .promoted_surface_invalidation_reason = promoted_surface_invalidation_reason,
        .has_promoted_descendant_subtree = exec_state.retained_runtime.has_promoted_descendant_subtree,
        .has_descendant_scoped_promoted_rebuild_candidate = has_descendant_scoped_promoted_rebuild_candidate,
        .rebuild_strategy = if (has_descendant_scoped_promoted_rebuild_candidate) .descendant_scoped_promoted else .normal,
        .has_prebuilt_display_payload_own = has_prebuilt_display_payload_own,
        .has_prebuilt_display_payload_subtree = exec_state.retained_runtime.display_payload_subtree_prebuilt,
        .prebuilt_display_payload_strategy = exec_state.retained_runtime.display_payload_subtree_strategy,
        // subtree/own replay 是把 runtime 区间从**本帧** display_list 下沉到
        // render list，区间必须是本帧 prebuild 写的（epoch 硬条件）。stale
        // 区间指向的表位如今被别的内容占据（典型：GlassLab 滚动时 502 的旧区
        // 间罩住兄弟玻璃球的 fresh 条目），下沉即把别人的条目再画一遍,
        // 半透明玻璃/高光叠两次整体增白，settle/滚动两态切换即滚动闪烁根因。
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
        .should_try_promoted_replay = !disable_spanned_text_retained and
            promoted_cache_safe and
            exec_state.promoted_surface_valid and
            node.meta.per_frame.caches.commands.promoted != null,
        .should_try_legacy_overflow_replay = !disable_spanned_text_retained and use_legacy_overflow_cache and !node.frame_state.state_bits.dirty.core.subtree_render,
        .should_write_promoted_cache = !disable_spanned_text_retained and can_write_promoted_cache,
        .should_write_legacy_overflow_cache = !disable_spanned_text_retained and can_write_legacy_overflow_cache,
        .needs_rect_clip_fallback = exec_state.plan_state.needs_rect_clip_fallback,
    };
}

// ─────────── 缓存回放 ───────────

/// 缓存命中帧的 z>0 直接子节点补渲染（legacy overflow 缓存替放时它们已被
/// appendLegacyCachedCommandsWithoutEscapedOverlays 从缓存命令里剔除）。
/// 选中集合与旧的"逃逸"判据相同（positive_z 带 + 父节点不走 opacity layer），
/// 这属于带外缓存机制，留给 C3 统一；但裁剪不再逃逸：传父节点的 clip 与
/// clip_id，补渲染的内容落在缓存 token 对之外时仍由 clip-bridge 裁到父节点的
/// 裁剪链（z_index 只影响同级顺序，不影响裁剪，方案 §5.3）。
fn renderOverlayChildrenAfterCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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

/// 子节点的唯一渲染入口：永远继承父节点的 effective_clip 与 retained clip_id。
fn renderChildWithParentClip(
    cx: *RenderContext,
    child: *Node,
    exec_state: NodeExecutionState,
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
    exec_state: NodeExecutionState,
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

/// 节点当前 glass 参数的指纹（逐字段喂，避开 struct padding）。
/// promoted 缓存的 begin_blur token 按值烘焙参数，替放前必须比对（见
/// CachedRenderSlice.cached_glass_hash 注释：dirty 位守不住这条通路）。
pub fn nodeGlassParamsHash(node: *Node) u64 {
    const gp = node.style.glass_params() orelse return std.math.maxInt(u64);
    const resolved = gp.resolve();
    var hasher = std.hash.Wyhash.init(0);
    inline for (@typeInfo(@TypeOf(resolved)).@"struct".fields) |f| {
        hasher.update(std.mem.asBytes(&@field(resolved, f.name)));
    }
    return hasher.final();
}

fn canReusePromotedCommands(node: *Node, runtime: scene_runtime_mod.SceneNodeRuntime, exec_state: NodeExecutionState, cache: node_mod.CachedRenderSlice) bool {
    // 参数插值进行中（GlassBox interactive boost 等）由组件挂 disable_render_cache
    // 退出全部缓存，token 按值烘焙参数，任何 stamp 方案都躲不开洗白/时序竞态。
    if (node.frame_state.state_bits.flags.disable_render_cache) return false;
    if (cache.cached_glass_hash != nodeGlassParamsHash(node)) return false;
    if (runtime.promoted_layer_id == scene_runtime_mod.INVALID_ID) return false;
    if (cache.promoted_layer_id != runtime.promoted_layer_id) return false;
    if (cache.content_version != runtime.content_version) return false;
    // 根 id 三元组比对拦截"缓存根自身语义变化"（promoted 语义依赖根 effect 链）；
    // 子树**内部**的帧内序号平移不在此拦截，appendCachedCommands 替放时按
    // node_id 统一改写为本帧值（rewriteSplicedItemHeaders，下游回归根治）。
    if (cache.cached_transform_id != exec_state.retained_ids.transform_id) return false;
    if (cache.cached_effect_id != exec_state.retained_ids.effect_id) return false;
    if (cache.cached_clip_id != exec_state.retained_ids.clip_id) return false;
    if (!hasSameLinearTransform(cache.world_transform, exec_state.content_transform)) return false;
    if (@abs(cache.world_bounds.w - exec_state.render_w) > 0.01) return false;
    if (@abs(cache.world_bounds.h - exec_state.render_h) > 0.01) return false;
    return true;
}

fn appendCachedCommands(cx: *RenderContext, commands: []const DisplayItem) !void {
    // 坐标正确性：cache 内 DisplayItem 是 local 空间；display_list_lowering 在
    // lower 时按 header.transform_id 读当帧 property tree 矩阵重算坐标。
    // splice 逐条过滤 + 改写（原 rewriteSplicedItemHeaders，下游回归与残影根治合并）：
    //   - node 本帧存在、id 平移 -> 改写为本帧值；
    //   - node 本帧**不存在**（典型：运行时 setOpacity(0) 后 buildRetainedSubtree
    //     整支跳过，无 scene_runtime 条目）-> **丢弃**。此前 `orelse continue`
    //     把 stale 写入帧序号原样放行，去索引本帧重建的 property tree 会命中
    //     **别的元素**的 transform，下游应用 layers"键画到行左、划过即留"残影
    //     的根因。没被遍历 = 不可见/已摘除，本就不该画，丢弃恒安全。
    //   - control token（transform_id == INVALID，begin/end layer 等）原样透传，
    //     内容条目的增删不影响其配对。
    for (commands) |command| {
        const h = command.header();
        if (h.transform_id == INVALID_ID) {
            try cx.display_list.append(command);
            continue;
        }
        const fresh = cx.scene_runtime.get(h.node_id) orelse {
            cx.perf.subtree_payload_absent_node_drop_count += 1;
            continue;
        };
        var item = command;
        if (fresh.transform_id != h.transform_id or
            fresh.clip_id != h.clip_id or
            fresh.effect_id != h.effect_id)
        {
            // 观测计数（原下游回归不变式探针语义升级为"已改写条数"）。
            cx.perf.subtree_payload_stale_header_count += 1;
            const hp = item.headerPtr();
            hp.transform_id = fresh.transform_id;
            hp.clip_id = fresh.clip_id;
            hp.effect_id = fresh.effect_id;
        }
        // DisplayList.append freezes pointer-backed payloads (notably path
        // geometry). A replayed cache may be replaced later in this render,
        // so borrowing its geometry here leaves lowering with a dangling ptr.
        try cx.display_list.append(item);
    }
}

// 下游回归背景（改写逻辑现内联在 appendCachedCommands）：header 的
// transform/clip/effect_id 是**写入帧**的帧内序号（property_tree 每帧 clear
// 重建的 append 索引）。effect/clip 是条件分配（use_opacity_layer / needs_clip /
// blur / rounded_clip，动画期会翻转；opacity==0 子树整支跳过不分配），任何更早
// 节点的分配集合变化都会平移其后所有节点的序号，而 stamp 只能比对缓存根，
// "一增一减总长不变"的对冲平移甚至骗过全帧表长度比对且不自愈。
// 唯一不变式是：**每条 content item 的 header id 恒等于其 node 在写入帧
// scene_runtime 里的值**（makeDisplayItemHeader 单一 stamp 路径）。而
// buildRetainedSubtree 在任何 splice 之前已为全树重建本帧 scene_runtime，
// 故 splice 时按 node_id 逐条改写为本帧值即可整类消除 stale id；本帧无条目
// 的 node 直接丢弃（残影根治，见 appendCachedCommands）。四条回放路径
// （subtree payload / promoted replay / descendant-scoped rebuild /
// legacy overflow）全部汇入 appendCachedCommands，那里是唯一改写点。

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

// ─────────── 缓存回放执行 ───────────

fn replayPromotedCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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
    exec_state: NodeExecutionState,
    cache: node_mod.CachedRenderSlice,
) !void {
    try appendLegacyCachedCommandsWithoutEscapedOverlays(cx, node, cache.commands);
    try renderOverlayChildrenAfterCacheHit(cx, node, exec_state);
}

fn replayCachedNodeHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    options: ReplayBridgeOptions,
    commands: []const DisplayItem,
) !void {
    if (options.use_bridge) {
        const exec_plan = options.exec_plan orelse unreachable;
        _ = exec_plan;
        try appendCachedCommands(cx, commands);
    } else if (options.reuse_origin) {
        // reuse_origin 只影响 scroll 偏移语义，不豁免 header 帧内序号改写。
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
    exec_state: NodeExecutionState,
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
    // 跨帧比较用 stable id（帧内序号会因节点增删平移 -> spurious miss）。
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
    // splice 本身就是 [own(self段), children] 的正确 paint 顺序，**不再**额外镜像
    // own content（早先 mirror + splice = own 画两遍：半透明阴影叠加变深，hover
    // 动画期 fresh(一遍)/replay(两遍) 帧交替 -> 阴影深浅脉动"抖动"）。下帧 cache
    // assembly 需要的 own range 直接指向 splice 的 self 区段。
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
        // own 文本已在缓存内物化（content 字节内联，blob 断开），blob range 置零。
        runtime.text_blob_start = 0;
        runtime.text_blob_count = 0;
    }
    markNodeReplayClean(node);
    return true;
}

fn tryReplayLegacyOverflowCacheHit(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !bool {
    const cache = node.meta.per_frame.caches.commands.own orelse return false;
    cx.perf.render_cache_hit += 1;
    try replayLegacyOverflowCacheHit(
        cx,
        node,
        exec_state,
        cache,
    );
    // Stage B R3e: throwaway swap 删除 (R3b 后 appendNodeOwnContent 不写 cx.lowering_buffer)。
    // 不可降级：漏掉 own content 后仍 markNodeReplayClean，节点会被当成
    // "已正确重放"缓存下来，之后每帧都少画自身内容 = 持久静默渲染错误。
    appendNodeOwnContent(cx, node, exec_state) catch @panic("OOM: appendNodeOwnContent on legacy overflow replay");
    markNodeReplayClean(node);
    return true;
}

fn tryReplayNodeFromPlan(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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

// ─────────── 节点桥管理 ───────────

// ─────────── 节点内容渲染 ───────────

fn appendNodeText(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !void {
    const logical_t = resolveNodeLogicalTextProps(node) orelse return;
    try appendDisplayTextItem(cx, node, exec_state, &logical_t, node.getLayoutOutput().artifacts.text_layout);
}

/// scroll 容器(tag==.scroll)children 渲染前后的真像素裁剪对。
/// ⚠ 普通容器的 overflow_hidden 此前**没有像素裁剪**(push_clip 只有
/// effect apply_clip 与 border_side 两个发射点);虚拟列表 overscan 行/
/// 部分滚出的首末行原样画出容器(下游应用侧栏行压搜索框/页脚,用户多次
/// 截图实锤)。children 渲染路径有多条(直绘/分桶缓存拼装/retained),
/// 每条都要包，只修一条时 40 行小板好了、200 行大板(走分桶路径)照旧。
/// 本包围覆盖 childPasses 的全部三个带(regular/sticky/positive_z):z>0
/// 子节点同样被裁，z_index 只影响同级顺序,不影响裁剪。要画到容器外
/// 只能挂 portal(cx.ensurePopoverPortalRoot / OverlayStack)。
fn emitScrollClipBegin(cx: *RenderContext, node: *Node, exec_state: NodeExecutionState) !bool {
    const on = scrollClipWanted(node, exec_state); // 逃生阀 ZENIT_DISABLE_SCROLL_CLIP 在内
    if (on) {
        const token = scrollClipPushToken(exec_state);
        // ⚠ token 必须同时落 display_list:paint 流会被"从 display_list 重建"
        // 的路径整体替换/绕过(帧末全量 derive、subtree payload replay、splice)。
        // 只直发 paint 流的话,凡走重建路径的帧裁剪整个消失，大板 sidebar
        // 溢出行画到岛外(用户截图实锤,间歇性:取决于该帧命中哪条缓存路径)。
        // 节点局部 clip 与 paint 共用 header，缓存重放时一起重定位。
        try cx.display_list.append(token);
        const transform = cx.property_tree.transforms.items[exec_state.retained_ids.transform_id].content;
        try display_list_lowering_mod.appendLoweredBoth(cx, display_list_lowering_mod.lowerNodeClip(token, transform));
    }
    return on;
}

fn emitScrollClipEnd(cx: *RenderContext, exec_state: NodeExecutionState, on: bool) !void {
    if (!on) return;
    const token: DisplayItem = .{ .pop_clip = .{
        .header = scrollClipTokenHeader(exec_state),
    } };
    try cx.display_list.append(token); // 与 push 对称,见 emitScrollClipBegin 注释
    try display_list_lowering_mod.appendLoweredBoth(cx, token);
}

fn scrollClipWanted(node: *Node, exec_state: NodeExecutionState) bool {
    // 判据是**节点自己声明了 overflow_hidden**（exec_state.needs_clip 即由
    // style.overflow_hidden 推导，见 clip.resolveNodeRenderClipSpec 开头的早退），
    // 而不是节点的 tag。
    //
    // 曾经这里额外要求 `tag == .scroll or tag == .input`，于是任何声明了
    // overflow_hidden 的**普通 box** 都拿不到像素裁剪。Input 组件正是这个形状：
    // 它把 input_container（tag=.input）显式设成 overflow_hidden=false
    // （非对称圆角场景要走 border_side 裁剪），真正负责裁剪滚动文本的是内层
    // editable_surface，一个 overflow_hidden=true 的普通 box。两个条件
    // 各自落空：.input 那个 needs_clip=false，editable_surface 那个 tag 不对。
    // 结果超长输入的文字直接画到输入框外，盖住 leading icon 与邻近控件
    // （下游编辑器链接浮层实测：文本盒 208.4px 画在 204px 的容器里，溢出到左边框外）。
    //
    // 按声明裁剪也与 CSS 的 overflow:hidden 语义一致：谁声明谁裁剪，与
    // 元素类型无关。z>0 子节点同样在本包围内（positive_z 带也在 token 对之间），
    // z_index 不带来任何裁剪逃逸。
    //
    // 例外：节点**自己带离屏效果**（opacity / composited_group /
    // backdrop_blur / rounded_clip）时不发。它的裁剪已由 compositor plan 承担
    // （effect_bridge 把 apply_clip 投到 owner-local 帧、rounded_clip 走 surface mask），
    // 再发一对 CONTROL push_clip 不只是重复：lowering 按组开关 effect bridge，控制
    // token 会把 effect 组从中间切开，token 之后的内容落到 blur/opacity 层**外面**
    // （tests.zig「同帧两个 blur+rounded_clip 岛」实测 content 排在 end_blur 之后；
    // 这正是 43bb5f3 放宽判据后 test-ui-core 六个失败的来源）。
    //
    // opacity / composited_group owner 若有画在 children clip 之外的自身内容
    // （阴影 / 描边，clip_mod.ownerPaintsOutsideChildClip）则**不**排除：compositor
    // 的 apply_clip 在 begin_layer 后立即 push、覆盖整个 surface 内容，会把 owner
    // 自己的阴影裁成矩形、让贴边内容压住描边（Popover 实拍）。这类 owner 的
    // overflow clip 由此处只包 children 的 token 承担，layer_tree 的 apply_clip
    // 相应退回父 clip（ClipNode.owner_wraps_children）。token 带真实 header（见
    // scrollClipTokenHeader），不会把 effect 组切开；promoted cache 也把这对
    // token 写进缓存（CachedRenderSlice.descendant_clip_open_count）。
    if (exec_state.use_rounded_clip or effectiveBackdropBlurRadius(node) > 0) return false;
    if (exec_state.use_opacity_layer and !clip_mod.ownerPaintsOutsideChildClip(node)) return false;
    return exec_state.needs_clip and
        exec_state.clip_rect.w > 0 and exec_state.clip_rect.h > 0 and
        std.posix.getenv("ZENIT_DISABLE_SCROLL_CLIP") == null;
}

/// token 带**本节点的真实 header**而不是 CONTROL_HEADER。
///
/// lowering 按 (effect_id, clip_id) 分组、按组开关 effect bridge：CONTROL header 的
/// effect_id 是 INVALID，token 自成一组、effect 链为空 -> 祖先的 opacity/blur 层在
/// token 前被 end、在其后被 begin 重开。结果是一个带 overflow_hidden 的普通子节点
/// 把祖先的合成层切成两段：组 opacity 变成两次独立合成（重叠区二次混合），blur
/// 背板被采样两次。真实 header 让 token 与本节点子内容同组，effect 链不变；
/// splice 的 header 改写（appendCachedCommands）也照常覆盖它。push_clip 的
/// node_local 标志让 lowering 按该 header 变换几何；pop_clip 仍是控制项。
pub fn scrollClipTokenHeader(exec_state: NodeExecutionState) display_list_mod.ItemHeader {
    return makeDisplayItemHeader(exec_state);
}

pub fn scrollClipPushToken(exec_state: NodeExecutionState) DisplayItem {
    // Store node-local geometry so retained replay and full lowering apply the
    // same transform as the descendants. offscreenOffset only subtracts the
    // surface source bounds; it cannot convert a world-space clip to owner-local.
    const local = exec_state.content_transform.invert().transformRect(exec_state.clip_rect);
    return .{ .push_clip = .{
        .header = scrollClipTokenHeader(exec_state),
        .node_local = true,
        .x = local.x,
        .y = local.y,
        .w = local.w,
        .h = local.h,
        .radius = if (exec_state.scale_min > 0) exec_state.clip_radius / exec_state.scale_min else 0,
        .shape_kind = exec_state.clip_shape_kind,
        .polygon = exec_state.clip_polygon,
    } };
}

/// prepass(prebuild)版 scroll clip 包围:**只写 display_list**。
/// prepass 的写出物 = prebuilt payload,由 subtree replay / splice / 全量
/// derive 消费，区段里没有这对 token 的话,凡命中缓存重放的帧,溢出行
/// 就带着零裁剪画出去(paint pass 的 emitScrollClipBegin 在 replay 短路
/// 层级之下,根本不执行)。
fn prebuildScrollClipBegin(cx: *RenderContext, node: *Node, exec_state: NodeExecutionState) !bool {
    const on = scrollClipWanted(node, exec_state);
    if (on) try cx.display_list.append(scrollClipPushToken(exec_state));
    return on;
}

fn prebuildScrollClipEnd(cx: *RenderContext, exec_state: NodeExecutionState, on: bool) !void {
    if (!on) return;
    try cx.display_list.append(.{ .pop_clip = .{
        .header = scrollClipTokenHeader(exec_state),
    } });
}

fn appendNodeBodyContent(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !void {
    if (node.meta.per_frame.custom_hooks.draw) |draw| {
        // World.LayoutTable 读 rect。
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
    exec_state: NodeExecutionState,
) !void {
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
    // backdrop_blur 的 begin token 由 content item 的 effect header 驱动
    //（lowering 按组开 effect bridge）。无 bg/渐变/边框/文本的"纯玻璃"节点
    // 零 item -> 没有任何组携带它的 effect_id -> begin_blur 永不发射，玻璃
    // 静默不渲染（下游应用 header 双层 progressive blur 的内层实拍）。补一条
    // 透明占位 rect 让 effect 有载体；a=0 不产生可见像素。
    if (cx.display_list.items.items.len == display_start and
        effectiveBackdropBlurRadius(node) >= 0.5)
    {
        const local_rect = cx.rectFromWorld(node);
        try cx.display_list.append(.{ .fill_rect = .{
            .header = style_render.makeDisplayItemHeader(exec_state),
            .x = 0,
            .y = 0,
            .w = local_rect.w,
            .h = local_rect.h,
            .color = types.Color.rgba(0, 0, 0, 0),
            .radius = .{ 0, 0, 0, 0 },
        } });
    }
    updateNodeDisplayPayloadRanges(cx, node.id, display_start, blob_start);
}

fn appendNodeDescendantContent(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !NodeContentSlices {
    // frame arena + 预留满容量：slice 只活到本帧 cache 拼装结束；arena 上
    // append-grow 无法原地 realloc（中间夹子递归的分配），必须一次性预留。
    const child_cap = node.children.items.len;
    var regular_children: std.ArrayList(u32) = .{};
    var sticky_children: std.ArrayList(u32) = .{};
    var overlay_children: std.ArrayList(u32) = .{};
    try regular_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    try sticky_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    try overlay_children.ensureTotalCapacity(cx.frame_allocator, child_cap);
    var clip_wrapped = false;

    if (node.meta.per_frame.custom_hooks.draw) |draw| {
        // custom_hooks.draw 路径直接 emit 到 display_list 当前末尾；不走 children
        // pass，所以 cache 端把它当 regular_children=[]，节点 own-content range
        // 已由 appendNodeOwnContent 写入 runtime.display_item_*，custom_draw 增加
        // 的 items 进 own range 之外，cache 不归任何 child 而是 tail 后？
        //
        // 当前简化：custom_draw 节点不参与 promoted cache 的 per-pass 归类（极少
        // 同时具备 has_custom_draw + promoted layer 的场景）；让 paint 直接 emit。
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

/// 缓存 splice 后回填 child 的 subtree range，指向本帧 display_list 中刚 splice
/// 的区段。scene_runtime 每帧清空，若不回填，下次 cache assembly
/// （assembleCacheCommands 按 per-child range 切片）会取到 count=0 -> 该 child
/// 内容从缓存里静默消失。
fn setChildSpliceRange(cx: *RenderContext, child_id: u32, start: usize, len: usize) void {
    if (cx.scene_runtime.nodes.getPtr(child_id)) |runtime| {
        runtime.subtree_display_item_start = @intCast(start);
        runtime.subtree_display_item_count = @intCast(len);
    }
}

fn replayCachedDescendantPass(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    cache: node_mod.CachedRenderSlice,
    pass: ChildRenderPass,
) !bool {
    if (pass == .regular) {
        // regular band 有 per-child 计数（regular_child_slices）：逐 child splice
        // 并回填精确 range，保持 assembly 的 per-child 归属正确。
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
    // sticky/overlay band 无 per-child 计数：仅当该 pass 恰有一个 child 时整段
    // 归属之；多 child 无法精确切分，放弃 band 替放退回 fresh render（保正确）。
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
    exec_state: NodeExecutionState,
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
    exec_state: NodeExecutionState,
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
    exec_state: NodeExecutionState,
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
    const pad = node.style.padding;
    const border_widths = node.style.border.resolvedWidths();
    const bw_top = border_widths[types.Border.SIDE_TOP];
    const bw_right = border_widths[types.Border.SIDE_RIGHT];
    const bw_bottom = border_widths[types.Border.SIDE_BOTTOM];
    const bw_left = border_widths[types.Border.SIDE_LEFT];
    const inner_x = bw_left;
    const inner_y = bw_top;
    // World.LayoutTable 读 rect。
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

// ─────────── 缓存最终化 ───────────

// ─────────── 重建策略与主渲染流 ───────────

fn renderNodeRebuildCommon(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    exec_plan: NodeExecutionPlan,
    parent_effect_id: u32,
) !void {
    const legacy_overflow_start_idx = cx.display_list.items.items.len;
    // Ordering 修复（2026-05-31）：若本节点 own content 本帧已在 prebuild 阶段
    // 按序写入 display_list（own_prebuilt 且 epoch=当前帧），但 own-replay 因
    // clip fallback 等不安全（should_try_display_payload_own_replay=false），
    // 则**不能**在此 fresh re-emit，否则 own（含背景）被追加到已 prebuilt 的
    // children 之后，背景覆盖 children（overflow_hidden + 背景节点整子树被盖住
    // 的根因，如 Table）。prebuild 的 own 副本已正确排在 children 之前。
    const own_already_prebuilt_fresh = exec_state.retained_runtime.display_payload_own_prebuilt and
        exec_state.retained_runtime.display_payload_own_prebuilt_epoch == cx.scene_runtime.frame_epoch;
    if (!try tryReplayOwnContentFromPlan(cx, node, exec_state, exec_plan, parent_effect_id)) {
        if (!own_already_prebuilt_fresh) {
            try appendNodeOwnContent(cx, node, exec_state);
        }
    }
    const content_slices = try appendNodeDescendantContent(cx, node, exec_state);

    finalizeNodeCaches(
        cx,
        node,
        legacy_overflow_start_idx,
        content_slices,
        exec_state,
        exec_plan,
    );
    // content_slices 在 frame arena 上，帧末整体回收，无需 deinit。
}

fn appendDescendantScopedPromotedSelfSlice(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !bool {
    _ = exec_state;
    const cache = node.meta.per_frame.caches.commands.promoted orelse return false;
    if (node.frame_state.state_bits.flags.disable_render_cache) return false;
    // glass 参数烘焙在缓存 token 里，参数变了不许替放旧 self slice。
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
    exec_state: NodeExecutionState,
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
    // frame arena + 满容量预留，同 appendNodeDescendantContent。
    const child_cap = node.children.items.len;
    var regular_children: std.ArrayList(u32) = .{};
    var sticky_children: std.ArrayList(u32) = .{};
    var overlay_children: std.ArrayList(u32) = .{};
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
                    // 整段从 cache 替到 display_list；child id 顺序按 children 列表
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
    // content_slices 在 frame arena 上，帧末整体回收，无需 deinit。
}

fn renderNodeWithRebuildStrategy(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
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

// ─────────── 公开入口 ───────────

pub fn renderNode(cx: *RenderContext, node: *Node) anyerror!void {
    // (phase_*_us PerfCounters 字段已删，全 6 项 0 read，纯 dead telemetry)
    beginRetainedFrame(cx);
    var child_order_restores: std.ArrayList(ChildOrderRestore) = .{};
    defer restoreChildOrders(&child_order_restores);
    try sortSubtreeChildrenByZ(cx, node, &child_order_restores);
    buildRetainedSubtree(cx, node, Transform2D.identity(), null, 0, INVALID_ID, INVALID_ID, Transform2D.identity());
    cx.layer_tree.planBuildFromPropertyTree(
        cx.property_tree.effects.items,
        cx.property_tree.clips.items,
        cx.property_tree.transforms.items,
        cx.scene_runtime,
    );
    syncPromotedLayerIds(cx);
    _ = syncPromotedDescendantState(cx, node);
    try prebuildDisplayPayloads(cx, node, Transform2D.identity(), null, false, INVALID_ID);
    const r = renderNodeTransform(cx, node, Transform2D.identity(), null, false, 0, INVALID_ID, INVALID_ID);

    // Stage B-1: shadow GpuDraw encode (debug-only). 不改主路径，只验证
    // display_list -> GpuDraw lowering 在真场景下不丢信息。divergence 累计到
    // PerfCounters.stage_b_shadow_count_mismatches，devtools 可观察。
    if (@import("builtin").mode == .Debug) {
        runShadowEncode(cx);
    }

    return r;
}

/// Stage B-1/B-2: shadow encode 入口（debug-only 在 renderNode 末尾自动调；测试也直接调）。
/// 内联 cmd -> PipelineId 映射 (与 paint_table.DisplayItemKind -> PipelineId 对偶)：
///   1=rect, 2=text, 3=image, 4=path, 5=shadow, 6=gradient, 0=控制流（不计）
pub fn runShadowEncode(cx: *RenderContext) void {
    const display_items = cx.display_list.items.items;
    if (display_items.len == 0) return;

    // Stage B S6 R3a: cache 已迁 DisplayItem，paint pass cx.lowering_buffer 不再是 cache
    // 索引基准。expected_pipelines 由 display_list 自身派生而非 lowering_buffer 比对。
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

    // 按 lowered kind 累计 display_list item 数
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

    // frame_allocator: 每帧重置，无需 free
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
    // on_before_render 已在 tickBeforeRender 中统一执行
    const subtree_display_start = cx.display_list.items.items.len;
    const subtree_blob_start = cx.text_blob_store.blobs.items.len;
    const exec_state = buildNodeExecutionState(cx, node, parent_transform, parent_clip, inherited_force_linear_text) orelse return;
    const exec_plan = buildNodeExecutionPlan(cx, node, exec_state, parent_effect_id);
    debugOverlayPlan(cx, node, exec_state, exec_plan, "render");

    if (exec_plan.has_descendant_scoped_promoted_rebuild_candidate) {
        markPromotedDescendantScopedRebuildCandidate(cx, node.id, exec_state.promoted_layer_id);
    }

    if (try tryReplayNodeFromPlan(cx, node, exec_state, exec_plan, parent_effect_id)) {
        updateNodeSubtreeDisplayPayloadRanges(cx, node.id, subtree_display_start, subtree_blob_start);
        return;
    }

    if (try tryReplaySubtreePayloadFromPlan(cx, node, &exec_state, exec_plan, parent_effect_id)) {
        return;
    }

    try renderNodeWithRebuildStrategy(cx, node, exec_state, exec_plan, parent_effect_id);
    // Stage B S5.2: 如果 paint pass 入口时 display_list 已含本节点子树 prebuild
    // contribution (subtree_display_start 之后到 paint pass 入口前)，paint pass
    // fresh emit 又会在末尾追加同样内容。truncate 末尾 fresh 部分留 prebuild。
    // 判定：subtree_display_start < (prebuild 后位置). 但 prebuild 后位置 ==
    // subtree_display_start (paint pass 入口时 cx.display_list 长度)。所以无法
    // 直接判. 用 scene_runtime 的 subtree_display_item_count (prebuild 写的)
    // 替代，如 > 0，prebuild 写过本节点子树，truncate fresh 部分。
    if (cx.scene_runtime.get(node.id)) |rt| {
        if (rt.display_payload_subtree_prebuilt and rt.subtree_display_item_count > 0) {
            cx.display_list.items.shrinkRetainingCapacity(subtree_display_start);
            // ⚠️ 只能截 display_list，**不能**截 text_blob_store。
            //
            // 保留下来的是 prebuild 那份 display item，它们的 text_run 仍以
            // `blob_id` 间接引用 blob（prebuildSimpleDisplayPayloadSubtree 不做
            // 物化，只记录范围）。而 prebuild 的 blob 就落在
            // [subtree_blob_start, ...) 这段里，截掉正是截掉它们自己引用的
            // 数据。槽位随后被后续节点的文本复用，resolveTextRunContent 便按
            // 旧 offset 去切新 blob 的字节：终端画出状态栏的 "plaintext"
            // 切片 "plainte"、编辑器 tab 名，或空串。
            //
            // blob 只增不减、每帧 clear，多留几条的代价是本帧一点内存；
            // 截错则是画面直接错。
        }
    }
    updateNodeSubtreeDisplayPayloadRanges(cx, node.id, subtree_display_start, subtree_blob_start);

    markNodeRenderedClean(node);
}

// ===== 等宽快速路径辅助函数 =====

// 检查 spans 是否只做颜色覆盖（无 font_weight/italic/strikethrough）
// 纯文本编辑器的语法高亮只有 color 和 bg_color，永远返回 true

pub fn estimateTimeMs() f64 {
    const now = @as(f64, @floatFromInt(std.time.nanoTimestamp())) / 1_000_000.0;
    const delta = now - current_frame_monotonic_ms;
    return if (delta <= 0) current_frame_time_ms else current_frame_time_ms + delta;
}
