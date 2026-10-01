/// Retained 元数据：向 PropertyTree 写入 transform/clip/effect 节点，
/// 并更新 SceneRuntime 中该节点的运行时状态。
const std = @import("std");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const render_context_mod = @import("render_context.zig");
const node_state = @import("node_state.zig");
const anim_checks = @import("animation_checks.zig");
const geometry = @import("geometry.zig");
const clip_mod = @import("clip.zig");
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

// ─────────────────────────────────────────────────────────────────────────────
// 调试工具
// ─────────────────────────────────────────────────────────────────────────────

/// ZENIT_DEBUG_OVERLAY 进程级缓存：shouldDebugOverlayNode 由 renderNodeTransform
/// 每节点每帧（经 debugOverlayPlan）调用，sample 剖析里 posix.getenv 占主线程 ~1%。
var debug_overlay_env_cache: ?bool = null;

fn debugOverlayEnvEnabled() bool {
    if (debug_overlay_env_cache) |v| return v;
    const v = std.posix.getenv("ZENIT_DEBUG_OVERLAY") != null;
    debug_overlay_env_cache = v;
    return v;
}

pub fn shouldDebugOverlayNode(node: *Node) bool {
    if (!debugOverlayEnvEnabled()) return false;
    if (node.style.composited_group()) return true;
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
    const bbox = node.getLayoutOutput().artifacts.children_bbox orelse ComputedRect.init(0, 0, 0, 0);
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

// ─────────────────────────────────────────────────────────────────────────────
// 内容标志收集
// ─────────────────────────────────────────────────────────────────────────────

pub fn collectContentFlags(node: *Node) scene_runtime_mod.ContentFlags {
    const bws = node.style.border.resolvedWidths();
    return .{
        // O(1)：读 NodeFlags.has_text_subtree（setText 置位 + appendChild 并入
        // + 沿祖先冒泡维护，保守不清位），替代旧 subtreeHasText 每节点递归下钻
        // （整帧 O(n·depth)，深层文本树的 renderNodeTransform 主热点之一）。
        .has_text = node.frame_state.state_bits.flags.has_text_subtree,
        .has_image = node.getImage() != null,
        .has_icon = node.getIcon() != null,
        .has_background = node.getBackground().a > 0 or node.style.gradient() != null or node.style.multi_gradient() != null or node.style.noise() != null,
        .has_border = bws[0] > 0 or bws[1] > 0 or bws[2] > 0 or bws[3] > 0,
        .has_shadow = node.style.shadow() != null,
        .has_custom_draw = node.meta.per_frame.custom_hooks.draw != null,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// PropertyTree + SceneRuntime 写入
// ─────────────────────────────────────────────────────────────────────────────

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
    /// Stage B S5.2: 当前 surface 的 inverse_world transform，把世界坐标
    /// 投回 surface-local 坐标系。outer (无 surface) 时 = identity。surface
    /// 内 child 时 = surface_owner.world_transform.invert()。让 lower 路径
    /// 从 content (= surface_inverse * world) 直接产出 surface-local 坐标，
    /// 与 paint pass subtree replay (inverse_replay_base * world) 字节等价。
    surface_inverse: Transform2D,
) RetainedIds {
    const inverse_world = render_state.world_transform.invert();
    const local_rect = inverse_world.transformRect(render_state.clip_world_rect);
    const content_transform = retained_scene.buildNodeWorldTransform(node, parent_transform, .{
        .include_scale = false,
        .include_rotation = false,
    });
    // effect.local_bounds 必须是 **unscaled owner-local 帧的常量**（动画期不变）：
    // surface src = owner_world⁻¹·(owner_world·local_bounds) = local_bounds，texture
    // 覆盖区随之稳定，M_composite 独自承担 scale。早先用"含 scale 的 world opacity_bounds
    // × unscaled 逆"换算 -> 动画期逐帧漂移（texture 帧 = 反向缩放帧），children 的静态
    // content 在其中被反向缩放，composite 的 scale 恰好抵消 -> 内容视觉上不参与 scale 动画。
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
            .radius = render_state.clip_radius,
            .polygon = render_state.clip_polygon,
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
            .kind = if (node.style.composited_group()) .composited_group else .opacity,
            .opacity = render_state.node_opacity,
            .blend_mode = node.style.blendMode(),
            .requires_offscreen = true,
            .local_bounds = opacity_local_bounds,
        }) catch effect_id;
    }
    if (render_state.use_blur) {
        const cr4 = node.style.effectiveRadii();
        const gp = node.style.glass_params() orelse types.GlassParams{};
        // 玻璃矩形必须是节点自身 rect：local_rect 来自 clip_world_rect，
        // shadow/outline 会把它撑大 -> glass SDF/采样按大矩形算，视觉上
        // 出现比节点大一圈的"矩形玻璃切块"。
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
        // Stage 3 fold：同节点 opacity/composited_group + rounded_clip 合并为单个
        // offscreen，把圆角写进刚 append 的 opacity effect，composite blit 时同时
        // 施加 mask 与 opacity（逐像素标量乘可交换，与"先裁再淡"视觉等价）。
        // 前提：无 blur（blur 的 corner_radius 裁背景采样，语义不同）、opacity
        // bounds 与 clip rect 一致（mask 作用于整个合成 quad，bounds 不一致时
        // mask 位置/尺寸错误，shadow/overflow padding 场景在此回退）。
        // 不变量：rounded_clip 恒为链最内层，本合并不改变链序。
        const opacity_effect_appended = render_state.use_opacity_layer and effect_id != parent_effect_id and !render_state.use_blur;
        // computeOpacityLayerBounds 末尾恒定 +2px pad；允许该常量超集（composite mask
        // 是 surface 内 apply_clip 精确圆角裁剪的超集，多裁不掉任何有效像素）。
        // shadow/outline/children 溢出会扩得更多 -> mismatch -> 回退独立 rounded_clip。
        const bounds_match = std.math.approxEqAbs(f32, opacity_local_bounds.x, local_rect.x - 2, 0.5) and
            std.math.approxEqAbs(f32, opacity_local_bounds.y, local_rect.y - 2, 0.5) and
            std.math.approxEqAbs(f32, opacity_local_bounds.w, local_rect.w + 4, 0.5) and
            std.math.approxEqAbs(f32, opacity_local_bounds.h, local_rect.h + 4, 0.5);
        if (std.posix.getenv("ZENIT_DEBUG_PASSCOUNT") != null and !(opacity_effect_appended and bounds_match)) {
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

    // 从 World.LayoutTable 读 rect（shadow-sync 保证与 node.rect 一致）。
    // 这是 SoT inversion 的第一处 callsite 切换；invariant gate 保证不会读到 stale 数据。
    const world_rect = cx.rectFromWorld(node);
    cx.scene_runtime.put(.{
        .node_id = node.id,
        .local_rect = world_rect,
        .world_bounds = render_state.world_rect,
        .content_transform = content_transform,
        .content_bounds = content_transform.transformRect(world_rect),
        .transform_id = transform_id,
        .clip_id = clip_id,
        .clip_bounds_fallback = render_state.clip_bounds_fallback,
        .effect_id = effect_id,
        .paint_order = node.frame_state.frame_local.spatial.paint.order,
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
        // 不可降级：transform_id / clip_id / effect_id 已经写进 property_tree
        // 并作为本函数返回值继续被使用，唯独 scene_runtime 里没有这个节点,
        // 后续 layerize / hit-test 按 node_id 查 runtime 会静默 miss。
    }) catch @panic("OOM: scene_runtime.put (node metadata dropped)");

    return .{
        .transform_id = transform_id,
        .clip_id = clip_id,
        .effect_id = effect_id,
    };
}
