/// 效果/裁剪桥接层：将 PropertyTree 中的 effect/clip 节点翻译为 DisplayItem 字面 token
///
/// 负责（R3f 后唯一活路径，Display 端）：
/// - Layer Bridge: begin/end_opacity_layer / begin/end_blur_layer / begin/end_rounded_clip
///   DisplayItem token emit
/// - Clip Bridge: push_clip / pop_clip DisplayItem token emit
/// - Effect Chain: 沿 effect_id 链展开成线性 token 序列 (appendDisplayEffectBridge*)
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

/// Effect/clip token 的 header — 这些 token 不绑定到具体 paint node，header 占位用
/// INVALID transform_id (encoder 不用 transform 二次变换 effect/clip — 字段已 lower)。
const CONTROL_HEADER: ItemHeader = .{ .transform_id = INVALID_ID, .node_id = std.math.maxInt(u32) };

// ─────────────────────────────────────────────────────────────────────────────
// 底层：Layer Bridge（begin/end）
// ─────────────────────────────────────────────────────────────────────────────

/// GPU retained 的身份键。
///
/// **只有真正被提升为独立 surface 的 layer 才有资格**：`stable_id` 本身对每个
/// plan layer 都会赋值（含没被提升的），拿它当 retained 身份会让一批只是"路过"
/// 的层去认领专属纹理 —— 它们的内容依赖外层上下文，跨帧复用不成立。
/// 不合格时返回 INVALID_SURFACE_ID，encoder 走每帧重画的安全老路。
fn retainedSurfaceId(layer: layer_tree_mod.CompositedLayer) u32 {
    if (!layer.promotion_reason.any()) return display_list_mod.INVALID_SURFACE_ID;
    if (layer.stable_id == INVALID_ID) return display_list_mod.INVALID_SURFACE_ID;
    return layer.stable_id;
}

pub fn appendLayerBridgeBeginFromPlanState(cx: *RenderContext, effect_state: layer_tree_mod.LayerTree.EffectPlanState) !bool {
    if (!effect_state.hasCompleteSurfaceBridge()) return false;
    const layer = effect_state.layer orelse return false;
    const bounds = effect_state.begin_bounds orelse return false;

    // surface transform 情形：用 Plan 预计算的 source/draw bounds 替代 world bounds
    const src = if (layer.has_surface_transform) layer.surface_source_bounds else bounds;
    const draw = if (layer.has_surface_transform) layer.surface_draw_bounds else bounds;
    if (std.posix.getenv("ZENIT_DEBUG_LAYER") != null and layer.root_node_id == 440) {
        std.debug.print("[layer_begin] node=440 kind={s} effect_id={d} src=({d:.1},{d:.1},{d:.1},{d:.1}) draw=({d:.1},{d:.1},{d:.1},{d:.1}) cr={d:.1}\n", .{
            @tagName(layer.effect_kind),                                                                                      layer.effect_id, src.x, src.y, src.w, src.h, draw.x, draw.y, draw.w, draw.h,
            @max(@max(layer.corner_radius[0], layer.corner_radius[1]), @max(layer.corner_radius[2], layer.corner_radius[3])),
        });
    }
    // rounded-clip 折叠（Stage 3）：opacity/composited_group effect 携带的
    // corner_radius 由 composite blit 施加（同 begin_blur_layer 的单 radius 现状）。
    const fold_radius = @max(
        @max(layer.corner_radius[0], layer.corner_radius[1]),
        @max(layer.corner_radius[2], layer.corner_radius[3]),
    );
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
                    .corner_radius = fold_radius,
                    .rotate = layer.surface_rotate,
                    .use_draw_transform = layer.has_surface_transform,
                    .draw_transform = layer.surface_draw_transform,
                    .draw_x = draw.x,
                    .draw_y = draw.y,
                    .draw_w = draw.w,
                    .draw_h = draw.h,
                    .blend_mode = layer.blend_mode,
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
                    .corner_radius = fold_radius,
                    .rotate = layer.surface_rotate,
                    .use_draw_transform = layer.has_surface_transform,
                    .draw_transform = layer.surface_draw_transform,
                    .draw_x = draw.x,
                    .draw_y = draw.y,
                    .draw_w = draw.w,
                    .draw_h = draw.h,
                    .blend_mode = layer.blend_mode,
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
                .corner_radius = @max(@max(layer.corner_radius[0], layer.corner_radius[1]), @max(layer.corner_radius[2], layer.corner_radius[3])),
                .glass = layer.glass,
                .rotate = layer.surface_rotate,
                .use_draw_transform = layer.has_surface_transform,
                .draw_transform = layer.surface_draw_transform,
                .draw_x = draw.x,
                .draw_y = draw.y,
                .draw_w = draw.w,
                .draw_h = draw.h,
            },
        }),
        .rounded_clip => {
            const radius = @max(
                @max(layer.corner_radius[0], layer.corner_radius[1]),
                @max(layer.corner_radius[2], layer.corner_radius[3]),
            );
            try display_list_lowering.appendLoweredBoth(cx, .{
                .begin_rounded_clip = .{
                    .header = CONTROL_HEADER,
                    .x = src.x,
                    .y = src.y,
                    .w = src.w,
                    .h = src.h,
                    .radius = radius,
                    .rotate = layer.surface_rotate,
                    .use_draw_transform = layer.has_surface_transform,
                    .draw_transform = layer.surface_draw_transform,
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
    fallback_radius: f32,
    fallback_shape_kind: display_list_mod.ClipShapeKind,
    fallback_polygon: display_list_mod.ClipPolygon,
    use_fallback: bool,
    /// true = push_clip 落在该 effect 的 surface **内部**（begin layer 之后），
    /// 需投影到 surface content 帧；false = 落在父上下文（blur 的 clip 在
    /// begin_blur_layer 之前），投影到父 surface 的内容坐标。
    inside_surface: bool,
) !bool {
    if (effect_state.apply_clip_bounds) |clip_bounds_raw| {
        // apply_clip 的 AABB 是 world 坐标，但 surface 内 content 在
        // owner-unscaled-local 帧（layer_tree CA-pure：owner_world⁻¹ 投影；
        // effect 无 transform 时 owner_world=identity，local 即 world）。
        // 必须用属性树的 owner_world⁻¹ 把 clip（draw_transform 已是父 surface 坐标）
        // 投到 content 帧，否则带 rotate 的 surface 里世界坐标 scissor 会把内容
        // 整个裁空（例：settle 后 rotate=90° 的 accordion chevron 消失）。
        // 旋转下取 AABB 是过覆盖近似，越出部分由 composite 时父级同一 clip 兜住。
        const clip_bounds = blk: {
            if (effect_state.layer) |layer| {
                if (inside_surface and layer.has_surface_transform and layer.transform_id < cx.property_tree.transforms.items.len) {
                    break :blk cx.property_tree.transforms.items[layer.transform_id].inverse_world.transformRect(clip_bounds_raw);
                }
                if (!inside_surface) break :blk layer.surface_parent_inverse.transformRect(clip_bounds_raw);
            }
            break :blk clip_bounds_raw;
        };
        try display_list_lowering.appendLoweredBoth(cx, .{
            .push_clip = .{
                .header = CONTROL_HEADER,
                .x = clip_bounds.x,
                .y = clip_bounds.y,
                .w = clip_bounds.w,
                .h = clip_bounds.h,
                .radius = effect_state.apply_clip_radius,
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
            .radius = fallback_radius,
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
        // 防御：缓存 splice 的 item header 可能携带**过期**的 effect_id（写缓存帧的
        // property tree 索引，本帧 effect 列表收缩后越界）。正常路径由
        // canReusePromotedCommands 的 effect_id 比对拦截 stale 替放；此处兜底
        // 防 panic——越界即终止链（该 item 按无 effect 处理）。
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

// ─────────────────────────────────────────────────────────────────────────────
// 高层：Display Effect Bridge（DisplayList 回放时用）
// ─────────────────────────────────────────────────────────────────────────────

pub const DisplayEffectBridgeScope = struct {
    entry: EffectBridgeEntry,
    clip_active: bool,
    /// Begin 是否真的发射了 layer token。End 必须按这个位配对，而不是
    /// 重新推导条件：Begin 有 `draw_opacity == null` 等只在自己一侧成立的
    /// 早退（bridge 完整但仍无操作），重推导会让 End 对没 begin 过的层发
    /// end token——靠编码器空栈守卫兜底没崩，但 token 流已不配平。
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
    // 统一走 CompositorPlan：Plan 已在 buildFromPropertyTree 预计算所有参数，
    // 包括 surface transform 情形的 source/draw bounds 和 draw_transform。
    if (clip_before_layer and entry.state.hasPlanClipBridge()) {
        scope.clip_active = try appendRectClipBridgeBeginFromPlanState(
            cx,
            entry.state,
            entry.effect.local_bounds,
            0,
            .rect,
            display_list_mod.ClipPolygon.empty(),
            false,
            false, // begin layer 之前 → 父上下文，world 坐标
        );
    }
    if (try appendLayerBridgeBeginFromPlanState(cx, entry.state)) {
        scope.layer_emitted = true;
        if (!clip_before_layer and entry.state.hasPlanClipBridge()) {
            scope.clip_active = try appendRectClipBridgeBeginFromPlanState(
                cx,
                entry.state,
                entry.effect.local_bounds,
                0,
                .rect,
                display_list_mod.ClipPolygon.empty(),
                false,
                true, // begin layer 之后 → surface content 帧
            );
        }
        return scope;
    }
    // Plan 未覆盖此 effect（requires_offscreen=false 或分配失败），退化为无操作。
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
        // backdrop_blur 的嵌套顺序刻意"颠倒"：begin 是 push_clip →
        // begin_blur_layer，end 却先 pop_clip 再 end_blur_layer。这只因为
        // end_blur_layer 在编码器里是 no-op（blur 合成全部发生在 begin，
        // 且发生在 clip 作用域内）才是安全的——若哪天给 end_blur_layer
        // 加真实工作，必须改成按 clip_before_layer 分支还原真嵌套。
        if (scope.clip_active) {
            try appendRectClipBridgeEnd(cx, true);
        }
        if (!scope.layer_emitted) continue; // Begin 无操作 ⇒ End 同样无操作
        if (try appendLayerBridgeEndFromPlanState(cx, scope.entry.state)) {
            continue;
        }
        // bridge 在 begin/end 之间失效（防御性兜底，理论不可达）：
        // 用裸 token 闭合，宁可多发也不留未闭合层
        switch (scope.entry.effect.kind) {
            .opacity, .composited_group => try display_list_lowering.appendLoweredBoth(cx, .{ .end_opacity_layer = .{ .header = CONTROL_HEADER } }),
            .backdrop_blur => try display_list_lowering.appendLoweredBoth(cx, .{ .end_blur_layer = .{ .header = CONTROL_HEADER } }),
            .rounded_clip => try display_list_lowering.appendLoweredBoth(cx, .{ .end_rounded_clip = .{ .header = CONTROL_HEADER } }),
        }
    }
}

/// 收集 clip 链（innermost-first），供调用方做跨组公共前缀比较。
/// 与 `collectEffectBridgeChain` 对偶 —— effect 侧早已按前缀保留 scope，
/// clip 侧此前每组整链 close+reopen（见 display_list_lowering 的循环注释）。
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

/// only_scroll=true 时仅发射来自 scroll 容器的 clip(effect 内部场景——
/// 玻璃岛内虚拟列表的行溢出必须裁,而 Input 等小 clip 的 effect-内投影
/// 尚有坐标问题,先维持旧行为不发)。
pub fn appendDisplayClipBridgeBeginFiltered(cx: *RenderContext, clip_id: u32, active_parent_effect_id: u32, only_scroll: bool) !usize {
    return appendDisplayClipBridgeBeginSuffix(cx, clip_id, active_parent_effect_id, only_scroll, 0);
}

/// `skip_outer` = 已经由上一组打开、本组要**继续沿用**的最外层 clip 个数。
///
/// 为什么需要它：lowering 主循环按 `(effect_id, clip_id)` 分组，而虚拟列表
/// 里每一行都有自己的 clip_id。旧实现每组把**整条祖先链**重发一遍，于是
/// 岛的圆角 clip（所有行共享的最外层）被逐行 push/pop —— 实测 git diff
/// 滚动一次就有 15 万次 `null → rounded(1106) → null` 往返。每次往返
/// `syncClipStateAfterMutation` 都要 `flushAllPending`（清空全部 pipeline
/// 并吃掉一个 SDF uniform 槽），256 槽在一帧内耗尽，encode 涨到 10-17ms。
///
/// effect 侧 2026-08-02 已经修过同一个形状的 bug（见 lowering 循环里的
/// scope 前缀注释）；clip 侧当时没跟上。这里补齐：公共前缀跨组保持打开，
/// 只发射差异部分。
pub fn appendDisplayClipBridgeBeginSuffix(
    cx: *RenderContext,
    clip_id: u32,
    active_parent_effect_id: u32,
    only_scroll: bool,
    skip_outer: usize,
) !usize {
    if (clip_id == INVALID_ID or clip_id >= cx.property_tree.clips.items.len) return 0;
    // CA-pure（P6 后）：surface 内容以 **owner-local（unscaled）** 帧 lower，encoder 的
    // offscreenOffset = -(surface_source_bounds.origin)（src 亦为 owner-local 帧）。因此
    // surface 内的 push_clip 同样必须转到 owner-local：active_parent_inverse.transformRect
    // (world_aabb) + encoder 偏移 = 正确 texture 位置。早先"surface 内直接传 world_aabb"
    // 是早先的世界坐标模型假设——CA-pure 下会把 clip 推错位置 → 面板圆角/边界裁剪
    // 失效（menu item hover 背景溢出 wrapper 边缘）。
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
    // chain 是 innermost-first；outermost 在 chain[count-1]。跳过已由上一组
    // 打开的 `skip_outer` 个最外层，从第一个真正需要新开的那层开始发。
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
        // polygon 点集是 clip-rect-origin-relative（clip.zig buildClipPolygonFromPathGeometry
        // 减掉了 rect 原点），随 rect 投影自然平移；但 rect 被 clip_scale 缩放时点集
        // 必须同步缩放，否则形状与 rect 比例失配（与上面 radius * clip_scale 同理）。
        var polygon = clip.polygon;
        if (@abs(clip_scale - 1.0) > 0.0001) {
            for (polygon.points[0..polygon.point_count]) |*p| {
                p[0] *= clip_scale;
                p[1] *= clip_scale;
            }
        }
        try display_list_lowering.appendLoweredBoth(cx, .{
            .push_clip = .{
                .header = CONTROL_HEADER,
                .x = clip_rect.x,
                .y = clip_rect.y,
                .w = clip_rect.w,
                .h = clip_rect.h,
                .radius = clip.radius * clip_scale,
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
