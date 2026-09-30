/// DisplayList lowering：将 DisplayItem 序列从 local space lower 到 world space。
///
/// 历史：本文件之前叫 display_list_replay.zig（旧 IR 时代的命名）。
/// v0.5 §5 Stage B 把旧 IR 删了之后，这里只剩 lowering 工作 ——
/// encoder 直接消费 lowered DisplayItem，没有 "replay" 语义了，所以改名。
///
/// 输入和输出都是 DisplayItem (apply transform + scale 字段)。负责：
/// - appendDisplayItemsToRenderListInternal：核心 lowering 循环（17 paint variant +
///   8 effect/clip control passthrough）
/// - 公开 API：appendAllDisplayItemsToRenderList / appendNodeDisplayPayloadToRenderList
/// - 内部辅助：getNodeDisplayItems / getNodeTextBlobs / getNodeDisplayPayload
const std = @import("std");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const property_tree_mod = @import("../property_tree.zig");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const render_context_mod = @import("render_context.zig");
const node_state = @import("node_state.zig");
const style_render = @import("node_style_render.zig");
const effect_bridge = @import("effect_bridge.zig");
const text_trace = @import("trace").text_flicker;
const bracket_debug = @import("bracket_debug.zig");
const paint_table_mod = @import("../paint_table.zig");
const gpu_draw_shadow = @import("gpu_draw_shadow.zig");

const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Node = node_mod.Node;
const RenderContext = render_context_mod.RenderContext;
const NodeExecutionState = node_state.NodeExecutionState;
const INVALID_ID = property_tree_mod.INVALID_ID;
const scaleLocalRadii = style_render.scaleLocalRadii;
const DisplayEffectBridgeScope = effect_bridge.DisplayEffectBridgeScope;
const ItemHeader = display_list_mod.ItemHeader;

pub const CONTROL_HEADER: ItemHeader = .{ .transform_id = INVALID_ID, .node_id = std.math.maxInt(u32) };

/// 改名 + 只写 paint_table.DisplayItem。
/// v0.5 §5 epic 时 union DisplayItem 是 source of truth，paint_table 是 mirror；
/// 现在反过来 — paint_table 是 source，union 路径已废弃。
///
/// Control variants manage scopes. Literal controls are already lowered;
/// a node_local push_clip also carries geometry that must follow its paint transform.
fn isControlItem(item: display_list_mod.DisplayItem) bool {
    // 单一判据：与 core.zig 的 bulk quad 归属扫描共用 DisplayItem.isControl，
    // 两边各写一份名单迟早对不上。
    return item.isControl();
}

/// inline payload (polygon / glass / icon_rep / path geometry) spill 到 frame_arena 取稳定
/// 地址；不能用 main_paint 内部地址，因为后续 append 可能 realloc。
pub fn appendLoweredBoth(cx: *RenderContext, item: display_list_mod.DisplayItem) !void {
    if (cx.capture_lowered) |sink| {
        var frozen = item;
        frozen.headerPtr().* = .{ .already_lowered = true, .transform_id = INVALID_ID, .node_id = INVALID_ID };
        try sink.append(cx.allocator, frozen);
    }
    var paint_item = gpu_draw_shadow.lowerDisplayItem(item);
    switch (item) {
        .push_clip => |it| {
            if (it.shape_kind == .polygon) {
                const dup = try cx.frame_allocator.create(display_list_mod.ClipPolygon);
                dup.* = it.polygon;
                paint_item.clip_polygon_ptr = dup;
            }
        },
        .begin_blur_layer => |it| {
            const dup = try cx.frame_allocator.create(@TypeOf(it.glass));
            dup.* = it.glass;
            paint_item.glass_ptr = dup;
        },
        .icon_rep => |it| {
            const dup = try cx.frame_allocator.create(@TypeOf(it.rep));
            dup.* = it.rep;
            paint_item.icon_rep_ptr = dup;
        },
        .fill_path => |it| {
            const dup = try cx.frame_allocator.create(types.PathGeometry);
            dup.* = it.geometry.*;
            dup.commands = try cx.frame_allocator.dupe(types.PathCommand, it.geometry.commands);
            dup.owned = false;
            paint_item.path_geometry_ptr = dup;
        },
        .stroke_path => |it| {
            const dup = try cx.frame_allocator.create(types.PathGeometry);
            dup.* = it.geometry.*;
            dup.commands = try cx.frame_allocator.dupe(types.PathCommand, it.geometry.commands);
            dup.owned = false;
            paint_item.path_geometry_ptr = dup;
        },
        else => {},
    }
    try cx.lowering_buffer_paint.append(cx.allocator, paint_item);
}
/// Lower a node clip through exactly the same content/replay transform as its paint.
/// The encoder subsequently applies the surface source-origin offset to both.
pub fn lowerNodeClip(item: display_list_mod.DisplayItem, transform: Transform2D) display_list_mod.DisplayItem {
    var clip = item.push_clip;
    const rect = transform.transformRect(ComputedRect.init(clip.x, clip.y, clip.w, clip.h));
    const scale = transform.extractApproxScale();
    clip.x = rect.x;
    clip.y = rect.y;
    clip.w = rect.w;
    clip.h = rect.h;
    clip.radius *= scale;
    for (clip.polygon.points[0..clip.polygon.point_count]) |*point| {
        point[0] *= scale;
        point[1] *= scale;
    }
    clip.node_local = false;
    return .{ .push_clip = clip };
}

// PT-BRACKET 文本调试子系统已拆到 bracket_debug.zig（v0.5 §5 GpuDraw epic B-3
// 子项）；本文件聚焦 lowering 核心。

// ─────────────────────────────────────────────────────────────────────────────
// 公开类型
// ─────────────────────────────────────────────────────────────────────────────

// 节点 display payload 的只读取址（类型 + 三个 accessor）已析出到
// node_display_payload.zig：那边零副作用、只读 scene_runtime 下标；
// 本文件保留 lowering 主路径（写 buffer）。以下 re-export 保证
// 公共 API 与既有调用点不变。
const node_display_payload = @import("node_display_payload.zig");

pub const DisplayPayloadScope = node_display_payload.DisplayPayloadScope;
pub const TextBlobPayloadScope = node_display_payload.TextBlobPayloadScope;
pub const NodeDisplayPayloadView = node_display_payload.NodeDisplayPayloadView;

// ─────────────────────────────────────────────────────────────────────────────
// 核心回放循环
// ─────────────────────────────────────────────────────────────────────────────

/// item 实际要落入的 clip：CSS overflow 语义下，节点自己的 overflow clip 只裁
/// 它的后代，不裁它自己的 shadow / background / border（`owner_content_exempt`）。
/// header.clip_id 按「每条 item 的 id == 其 node 在 scene_runtime 里的值」的
/// 不变式（appendCachedCommands 按 node_id 改写）恒为节点**自己的** clip，
/// 所以 owner 的自身内容在这里退回父 clip；后代 node_id 不同，照常进本层。
/// 修前：overflow_hidden + 阴影的节点阴影被裁成 border-box 矩形（静态卡片阴影
/// 整圈消失；圆角外露出矩形阴影灰块）。
pub fn paintClipIdForItem(cx: *RenderContext, header: display_list_mod.ItemHeader) u32 {
    const clips = cx.property_tree.clips.items;
    if (header.clip_id == INVALID_ID or header.clip_id >= clips.len) return header.clip_id;
    const clip = clips[header.clip_id];
    if (clip.owner_content_exempt and clip.node_id == header.node_id) return clip.parent;
    return header.clip_id;
}

fn appendDisplayItemsToRenderListInternal(
    cx: *RenderContext,
    start: usize,
    end: usize,
    include_structure: bool,
    active_parent_effect_id: u32,
    replay_node: ?*Node,
    replay_exec_state: ?*const NodeExecutionState,
) !void {
    const slice = cx.display_list.items.items[start..@min(end, cx.display_list.items.items.len)];
    const replay_base_inverse = if (replay_exec_state) |exec_state|
        exec_state.world_transform.invert()
    else
        Transform2D.identity();

    // ── effect scope 前缀保留（2026-08-02，下游应用残余 bug 根治）──
    // 相邻 group 若共享同一 effect 链前缀，scope **跨组保持打开**，只对
    // 差异部分做关/开。早先每组整链 close+reopen：begin_blur_layer 在
    // encoder 是"立即合成玻璃背板"，同一个 blur 岛的内容被 clip_id 切成
    // N 组时，玻璃背板被重画 N 次、每次糊掉前面组的内容 → 岛内只有最后
    // 一组可见（下游应用 sidebar 只剩底栏实拍）。同时每次 reopen 都跑一遍
    // blur capture+kawase 全链，纯浪费。
    // open_scopes/open_ids 以 **outermost-first** 存当前打开的链。
    var open_scopes: [8]DisplayEffectBridgeScope = undefined;
    var open_ids: [8]u32 = undefined;
    var open_count: usize = 0;
    // 不可降级：Begin 已写进流，End 不写就是不配对 scope。defer 无法传播
    // 错误 → panic（与旧实现同策略）。
    defer if (include_structure and open_count > 0) {
        effect_bridge.appendDisplayEffectBridgeEnd(cx, open_scopes[0..open_count]) catch @panic("OOM: display effect bridge end (unbalanced scope)");
    };

    // ── clip 前缀保留（与上面 effect scope 同构）──
    // 主循环按 (effect_id, clip_id) 分组，虚拟列表每行一个 clip_id。旧实现
    // 每组重发整条祖先链 → 所有行共享的最外层（岛的圆角 clip）被逐行
    // push/pop。实测 git diff 滚动 15 万次往返，每次都触发 flushAllPending
    // （清空全部 pipeline + 吃一个 SDF uniform 槽），256 槽一帧内耗尽后
    // 后续命令整批丢失（动作栏闪没），encode 也涨到 10-17ms。
    // 这里让公共前缀跨组保持打开，只关/开差异部分。
    var open_clip_ids: [8]u32 = undefined;
    var open_clip_count: usize = 0;
    defer if (include_structure and open_clip_count > 0) {
        effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count) catch @panic("OOM: display clip bridge end (unbalanced scope)");
    };

    var i: usize = 0;
    while (i < slice.len) {
        const header = slice[i].header();
        const group_clip_id = paintClipIdForItem(cx, header);

        var group_end = i + 1;
        while (group_end < slice.len) {
            const next_header = slice[group_end].header();
            if (next_header.effect_id != header.effect_id or paintClipIdForItem(cx, next_header) != group_clip_id) break;
            group_end += 1;
        }

        var chain_len: usize = 0;
        // clip 的坐标投影依赖当前最内层 effect；effect scope 一旦变动，
        // 已打开的 clip 前缀就不能再沿用（见下面 clip 前缀保留处的说明）。
        var effect_scope_changed = false;
        if (include_structure) {
            var chain: [8]node_state.EffectBridgeEntry = undefined;
            const count = effect_bridge.collectEffectBridgeChain(cx, active_parent_effect_id, header.effect_id, &chain);
            chain_len = count;
            // chain 是 innermost-first；求 outermost-first 的公共前缀
            var common: usize = 0;
            while (common < open_count and common < count and
                open_ids[common] == chain[count - 1 - common].effect_id) common += 1;
            // clip 前缀必须在 effect scope 的任何 Begin/End **之前**收拢：
            // encoder 对 begin..end 范围要么整段跳过（GPU retained 命中），
            // 要么在 end 恢复 begin 时的 clip 栈快照 —— pop 一旦落进新开的
            // scope 里（或留到旧 scope 关闭之后），关的就是范围外的 push，
            // 那几层 clip 永久泄漏。栈顶残留 tab 条 clip 时，该帧其后所有
            // 内容被裁进 tab 条（编辑/hover 动画帧整屏闪白的根因）。
            if ((open_count > common or open_count < count) and open_clip_count > 0) {
                try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
                open_clip_count = 0;
            }
            // 关闭不再需要的内层（innermost-first）
            if (open_count > common) {
                effect_scope_changed = true;
                try effect_bridge.appendDisplayEffectBridgeEnd(cx, open_scopes[common..open_count]);
                open_count = common;
            }
            // 打开缺失的（outermost → innermost）
            while (open_count < count) {
                effect_scope_changed = true;
                const entry = chain[count - 1 - open_count];
                open_scopes[open_count] = try effect_bridge.appendDisplayEffectBridgeBeginEntry(cx, entry, replay_node, replay_exec_state);
                open_ids[open_count] = entry.effect_id;
                open_count += 1;
            }
        }
        // ⚠ effect 链非空(毛玻璃岛内)时 clip 链**默认仍不发射**——曾尝试
        // 发射(scroll 容器 clip)修"岛内容器不裁"的架构缺口,但投影帧
        // 有未解问题:滚动条 thumb(容器 absolute 子)被裁到不可见,而行
        // 内容正常——同域两类 item 一裁一不裁,说明 clip 投影与部分 item
        // 的坐标帧不一致,修好前不能开。行溢出裁剪由渲染树侧的
        // emitScrollClipBegin/End(children 包围,mod.zig)承担——实测
        // 独立生效(首末行半行裁剪 ✓ 滚动条 ✓ 搜索框 ✓)。
        // 显式设 ZENIT_ENABLE_EFFECT_CLIP_BRIDGE=1 可开启用于继续调查。
        const innermost_effect_for_clip: u32 =
            if (open_count > 0) open_ids[open_count - 1] else active_parent_effect_id;
        const emit_in_effect = std.posix.getenv("ZENIT_ENABLE_EFFECT_CLIP_BRIDGE") != null;
        const want_clip = include_structure and (chain_len == 0 or emit_in_effect);

        // effect scope 变化时，clip 必须整条重开：clip 的坐标是相对
        // `innermost_effect_for_clip` 投影的（见 appendDisplayClipBridgeBeginSuffix
        // 里的 active_parent_inverse），换了 effect 帧就不能再沿用旧的 push。
        if (effect_scope_changed and open_clip_count > 0) {
            try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
            open_clip_count = 0;
        }

        if (want_clip) {
            var clip_chain: [8]u32 = undefined;
            const clip_len = effect_bridge.collectDisplayClipChainPublic(cx, group_clip_id, &clip_chain);
            // chain 是 innermost-first；按 outermost-first 求公共前缀。
            var common: usize = 0;
            while (common < open_clip_count and common < clip_len and
                open_clip_ids[common] == clip_chain[clip_len - 1 - common]) common += 1;
            if (open_clip_count > common) {
                try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count - common);
                open_clip_count = common;
            }
            if (clip_len > common) {
                const emitted = try effect_bridge.appendDisplayClipBridgeBeginSuffix(
                    cx,
                    group_clip_id,
                    innermost_effect_for_clip,
                    chain_len != 0,
                    common,
                );
                // only_scroll 过滤可能让实际发射数少于链长；按实际发射数记账，
                // 否则 End 的条数会和 Begin 对不上。
                var k: usize = 0;
                while (k < emitted and open_clip_count < open_clip_ids.len) : (k += 1) {
                    open_clip_ids[open_clip_count] = clip_chain[clip_len - 1 - common - k];
                    open_clip_count += 1;
                }
            }
        } else if (open_clip_count > 0) {
            try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
            open_clip_count = 0;
        }

        for (slice[i..group_end]) |item| {
            const item_header = item.header();

            // Literal controls are already lowered and may have INVALID transform IDs.
            // Node-local clips must instead reach the same transform path as paint items.
            //
            // 历史 bug（2026-07-29 修）：display_list 里由 custom_draw 直接 emit 的
            // begin/end_opacity_layer（如 Snapshot.appendTo 用来施加 anchor/scale/
            // opacity 的包裹层）带的正是 CONTROL header，于是在这里被 `continue`
            // 静默丢弃 —— 包裹层没了，snapshot 恒绘制在 local (0,0) 而非 anchor。
            // effect_bridge 那条路径没踩到是因为它走 appendLoweredBoth 直接写
            // paint 列表，绕过了本函数。
            if (item_header.already_lowered or (isControlItem(item) and !(item == .push_clip and item.push_clip.node_local))) {
                // 桥接 clip 前缀不得跨越 layer 边界 token：encoder 对
                // begin..end 范围要么整段跳过（GPU retained 命中），要么在 end
                // 恢复 begin 时的 clip 栈快照 —— 两条路径都假设范围内 clip
                // 自洽。若跨组保留的前缀在范围内被 End（pop 关到范围外的
                // push），那几层 clip 就永久泄漏：栈顶残留 tab 条 clip 时，
                // 该帧其后所有内容被裁进 tab 条（编辑/hover 动画帧整屏闪白
                // 的根因）。遇到边界先收拢，透传后按当前组重开。
                const is_layer_boundary = switch (item) {
                    .begin_opacity_layer,
                    .end_opacity_layer,
                    .begin_blur_layer,
                    .end_blur_layer,
                    .begin_rounded_clip,
                    .end_rounded_clip,
                    => true,
                    else => false,
                };
                if (is_layer_boundary and open_clip_count > 0) {
                    try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
                    open_clip_count = 0;
                }
                try appendLoweredBoth(cx, item);
                if (is_layer_boundary and want_clip) {
                    var boundary_chain: [8]u32 = undefined;
                    const boundary_len = effect_bridge.collectDisplayClipChainPublic(cx, group_clip_id, &boundary_chain);
                    if (boundary_len > 0) {
                        const emitted = try effect_bridge.appendDisplayClipBridgeBeginSuffix(
                            cx,
                            group_clip_id,
                            innermost_effect_for_clip,
                            chain_len != 0,
                            0,
                        );
                        var k: usize = 0;
                        while (k < emitted and open_clip_count < open_clip_ids.len) : (k += 1) {
                            open_clip_ids[open_clip_count] = boundary_chain[boundary_len - 1 - k];
                            open_clip_count += 1;
                        }
                    }
                }
                continue;
            }

            if (item_header.transform_id >= cx.property_tree.transforms.items.len) continue;
            // Stage B S5.2: 当 replay_exec_state != null (subtree replay)，用 inverse_replay_base
            // * world — paint pass 主路径走这里。replay_exec_state == null (derive 路径) 用
            // transform.content (含 surface_inverse * world)，与 subtree replay 的 inverse 应用等价。
            // 注：P6.3 后所有 overlay（modal + non_modal）统一走 composited_group surface。
            const world = cx.property_tree.transforms.items[item_header.transform_id].world;
            const content = cx.property_tree.transforms.items[item_header.transform_id].content;
            const item_transform = if (replay_exec_state != null)
                replay_base_inverse.mul(world)
            else
                content;
            const scale = item_transform.extractApproxScale();

            // lowering 写 DisplayItem (lower 后字段)。header 沿用 item.header (含
            // transform_id/clip_id/effect_id)，但 paint variant 的 x/y/w/h 已 lower 到
            // world coord — encoder 不再二次变换。
            const lowered_header = item_header;
            switch (item) {
                .fill_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .fill_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .radius = scaleLocalRadii(it.radius, scale),
                            // ⚠ 逐字段重建的 lowering：**新字段必须手动补**，
                            // 漏掉不会报错，只会静默丢值（椭圆退回圆角矩形）。
                            .shape = it.shape,
                        },
                    });
                },
                .stroke_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .stroke_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .width = it.width * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                            .shape = it.shape,
                        },
                    });
                },
                .border_side => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    const clip_rect = item_transform.transformRect(ComputedRect.init(it.clip_x, it.clip_y, it.clip_w, it.clip_h));
                    try appendLoweredBoth(cx, .{
                        .push_clip = .{
                            .header = CONTROL_HEADER,
                            .x = clip_rect.x,
                            .y = clip_rect.y,
                            .w = clip_rect.w,
                            .h = clip_rect.h,
                            .radius = it.clip_radius * scale,
                            .shape_kind = it.clip_shape_kind,
                            .polygon = it.clip_polygon,
                        },
                    });
                    try appendLoweredBoth(cx, .{
                        .stroke_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .width = it.width * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                    try appendLoweredBoth(cx, .{ .pop_clip = .{ .header = CONTROL_HEADER } });
                },
                .border_per_side => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .border_per_side = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .widths = .{ it.widths[0] * scale, it.widths[1] * scale, it.widths[2] * scale, it.widths[3] * scale },
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .gradient_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .gradient_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .from = it.from,
                            .to = it.to,
                            .direction = it.direction,
                            .radius = scaleLocalRadii(it.radius, scale),
                            // 同 multi_gradient_rect：逐字段重建，漏一个静默丢。
                            .radial_center_x = it.radial_center_x,
                            .radial_center_y = it.radial_center_y,
                            .conic_start_angle = it.conic_start_angle,
                            .extend_mode = it.extend_mode,
                            .shape = it.shape,
                        },
                    });
                },
                .shadow_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .shadow_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .blur = it.blur * scale,
                            .offset_x = it.offset_x * scale,
                            .offset_y = it.offset_y * scale,
                            .spread = it.spread * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .outline_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .outline_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .width = it.width * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .text_run => |it| {
                    const origin = item_transform.applyPoint(it.x, it.y);
                    const resolved_content = display_list_mod.resolveTextRunContent(cx.text_blob_store, it);
                    if (bracket_debug.bracketRenderDebugEnabled() and resolved_content.len == 1 and
                        (bracket_debug.bracketDebugNodeFilter() == null or item_header.node_id == bracket_debug.bracketDebugNodeFilter().?) and
                        bracket_debug.shouldLogBracketReplay(cx.scene_runtime.frame_epoch, item_header.node_id, it.blob_byte_start, it.blob_byte_end))
                    {
                        std.debug.print(
                            "[PT-BRACKET] frame={d} replay node={d} origin=({d:.1},{d:.1}) range=[{d},{d}) text=\"{s}\" clip={d} effect={d}\n",
                            .{
                                cx.scene_runtime.frame_epoch,
                                item_header.node_id,
                                origin.x,
                                origin.y,
                                it.blob_byte_start,
                                it.blob_byte_end,
                                resolved_content,
                                item_header.clip_id,
                                item_header.effect_id,
                            },
                        );
                    }
                    if (resolved_content.len == 0 and (it.content.len > 0 or it.blob_byte_end > it.blob_byte_start)) {
                        const blob_exists = it.blob_id != INVALID_ID and cx.text_blob_store.get(it.blob_id) != null;
                        text_trace.log(
                            cx.scene_runtime.frame_epoch,
                            "replay-empty-text node={d} blob={d} blob_exists={} raw_len={d} range=[{d}..{d}) scale={d:.2} clip={d} effect={d}",
                            .{
                                item_header.node_id,
                                it.blob_id,
                                blob_exists,
                                it.content.len,
                                it.blob_byte_start,
                                it.blob_byte_end,
                                scale,
                                item_header.clip_id,
                                item_header.effect_id,
                            },
                        );
                    }
                    try appendLoweredBoth(cx, .{
                        .text_run = .{
                            .header = lowered_header,
                            .x = origin.x,
                            .y = origin.y,
                            .content = resolved_content,
                            .blob_byte_start = it.blob_byte_start,
                            .blob_byte_end = it.blob_byte_end,
                            .color = it.color,
                            .font_size = it.font_size * scale,
                            .font_weight = it.font_weight,
                            .font_family = it.font_family,
                            .use_symbols_font = it.use_symbols_font,
                            .use_monospace_font = it.use_monospace_font,
                            .monospace_char_width = it.monospace_char_width * scale,
                            .use_italic_font = it.use_italic_font,
                            .spans = it.spans,
                            .blob_id = it.blob_id,
                            .blob_content_hash = it.blob_content_hash,
                            // blob_id 必须与它的 content_hash **成对**透传。
                            // blob_id 是帧内序号，store 每帧 clear 后重新分配；
                            // resolveTextRunContent 靠 blob_content_hash 才能识破
                            // "这个序号已经易主"。漏传 = 恒为 0 = 身份校验被
                            // `run.blob_content_hash == 0` 短路成永真，于是 re-lower
                            // 出来的 item 拿旧序号去切**本帧别的 blob** 的字节。
                            .raster_policy = it.raster_policy,
                            .fade_dx0 = it.fade_dx0 * scale,
                            .fade_dx1 = it.fade_dx1 * scale,
                        },
                    });
                },
                .image_quad => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .image_quad = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .texture_id = it.texture_id,
                            .tint = it.tint,
                            .corner_radius = it.corner_radius * scale,
                            .opacity = it.opacity,
                        },
                    });
                },
                .icon_rep => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .icon_rep = .{
                            .header = lowered_header,
                            .icon_id = it.icon_id,
                            .rep_size = it.rep_size,
                            .rep = it.rep,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .tint = it.tint,
                            .corner_clip_radius = it.corner_clip_radius * scale,
                            .opacity = it.opacity,
                        },
                    });
                },
                .arc => |it| {
                    const center = item_transform.applyPoint(it.cx, it.cy);
                    try appendLoweredBoth(cx, .{
                        .arc = .{
                            .header = lowered_header,
                            .cx = center.x,
                            .cy = center.y,
                            .outer_radius = it.outer_radius * scale,
                            .stroke_width = it.stroke_width * scale,
                            .start_angle = it.start_angle,
                            .end_angle = it.end_angle,
                            .color = it.color,
                        },
                    });
                },
                .multi_gradient_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .multi_gradient_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .direction = it.direction,
                            .radius = scaleLocalRadii(it.radius, scale),
                            .stop_colors = it.stop_colors,
                            .stop_positions = it.stop_positions,
                            .stop_count = it.stop_count,
                            // ⚠ 逐字段重建：漏一个就静默丢。下面四个原本**都漏了** ——
                            // shape 丢了让椭圆的渐变铺满包围盒；radial/conic 的中心与
                            // 起始角、extend_mode 丢了让径向/角度渐变回落到默认参数。
                            .radial_center_x = it.radial_center_x,
                            .radial_center_y = it.radial_center_y,
                            .radial_radius_x = it.radial_radius_x,
                            .radial_radius_y = it.radial_radius_y,
                            .conic_start_angle = it.conic_start_angle,
                            .extend_mode = it.extend_mode,
                            .shape = it.shape,
                        },
                    });
                },
                .noise_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .noise_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .fill = it.fill,
                            .mode = it.mode,
                            .scale = it.scale,
                            .intensity = it.intensity,
                            .seed = it.seed,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .inset_shadow_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .inset_shadow_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .fill = it.fill,
                            .shadow_color = it.shadow_color,
                            .blur = it.blur * scale,
                            .offset_x = it.offset_x * scale,
                            .offset_y = it.offset_y * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .shadow_dual_rect => |it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .shadow_dual_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .fill = it.fill,
                            .shadow1_color = it.shadow1_color,
                            .shadow1_blur = it.shadow1_blur * scale,
                            .shadow1_offset_x = it.shadow1_offset_x * scale,
                            .shadow1_offset_y = it.shadow1_offset_y * scale,
                            .shadow2_color = it.shadow2_color,
                            .shadow2_blur = it.shadow2_blur * scale,
                            .shadow2_offset_x = it.shadow2_offset_x * scale,
                            .shadow2_offset_y = it.shadow2_offset_y * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .fill_path => |it| {
                    const origin = item_transform.applyPoint(it.offset_x, it.offset_y);
                    try appendLoweredBoth(cx, .{
                        .fill_path = .{
                            .header = lowered_header,
                            .geometry = it.geometry,
                            .color = it.color,
                            .offset_x = origin.x,
                            .offset_y = origin.y,
                            .opacity = it.opacity,
                            // ⚠ 逐字段重建：渐变漏了会让多边形填充退回纯色。
                            .gradient_direction = it.gradient_direction,
                            .gradient_stop_colors = it.gradient_stop_colors,
                            .gradient_stop_positions = it.gradient_stop_positions,
                            .gradient_stop_count = it.gradient_stop_count,
                            .gradient_center_x = it.gradient_center_x,
                            .gradient_center_y = it.gradient_center_y,
                            .gradient_start_angle = it.gradient_start_angle,
                        },
                    });
                },
                .stroke_path => |it| {
                    const origin = item_transform.applyPoint(it.offset_x, it.offset_y);
                    try appendLoweredBoth(cx, .{
                        .stroke_path = .{
                            .header = lowered_header,
                            .geometry = it.geometry,
                            .color = it.color,
                            .width = it.width * scale,
                            .line_join = it.line_join,
                            .offset_x = origin.x,
                            .offset_y = origin.y,
                            .opacity = it.opacity,
                        },
                    });
                },
                // Stage B R3f: effect/clip 字面 token 1:1 passthrough (字段已 lower)
                .push_clip => try appendLoweredBoth(cx, lowerNodeClip(item, item_transform)),
                .pop_clip => |it| try appendLoweredBoth(cx, .{ .pop_clip = it }),
                .begin_opacity_layer => |it| try appendLoweredBoth(cx, .{ .begin_opacity_layer = it }),
                .end_opacity_layer => |it| try appendLoweredBoth(cx, .{ .end_opacity_layer = it }),
                .begin_blur_layer => |it| try appendLoweredBoth(cx, .{ .begin_blur_layer = it }),
                .end_blur_layer => |it| try appendLoweredBoth(cx, .{ .end_blur_layer = it }),
                .begin_rounded_clip => |it| try appendLoweredBoth(cx, .{ .begin_rounded_clip = it }),
                .end_rounded_clip => |it| try appendLoweredBoth(cx, .{ .end_rounded_clip = it }),
            }
        }
        i = group_end;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 公开 API
// ─────────────────────────────────────────────────────────────────────────────

pub const getNodeDisplayItems = node_display_payload.getNodeDisplayItems;
pub const getNodeTextBlobs = node_display_payload.getNodeTextBlobs;
pub const getNodeDisplayPayload = node_display_payload.getNodeDisplayPayload;

/// Stage B R3f: 把整个 cx.display_list lower 到 cx.lowering.main (世界坐标 +
/// 字段 lower 后的 DisplayItem 流) 供 encoder 消费。当前是 cx.render() 末尾
/// 唯一的翻译入口。
/// Freeze a displayed subtree without opening its ancestor effect scopes.
pub fn appendSnapshotDisplayItems(cx: *RenderContext, start: usize, end: usize, parent_effect_id: u32) !void {
    try appendDisplayItemsToRenderListInternal(cx, start, end, true, parent_effect_id, null, null);
}

pub fn appendAllDisplayItemsToRenderList(cx: *RenderContext) !void {
    const len = cx.display_list.items.items.len;
    if (len == 0) return;
    try appendDisplayItemsToRenderListInternal(cx, 0, len, true, INVALID_ID, null, null);
}

pub fn appendNodeDisplayPayloadToRenderList(
    cx: *RenderContext,
    node_id: u32,
    scope: DisplayPayloadScope,
) !bool {
    const payload = getNodeDisplayPayload(cx, node_id, scope) orelse return false;
    if (payload.items.len == 0) return false;

    const runtime = cx.scene_runtime.get(node_id) orelse return false;
    const start: usize = switch (scope) {
        .own => runtime.display_item_start,
        .subtree => runtime.subtree_display_item_start,
    };
    try appendDisplayItemsToRenderListInternal(cx, start, start + payload.items.len, true, INVALID_ID, null, null);
    return true;
}

pub fn appendNodeDisplayPayloadToRenderListForReplay(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    strategy: scene_runtime_mod.DisplayPayloadSubtreeStrategy,
    scope: DisplayPayloadScope,
    active_parent_effect_id: u32,
) !bool {
    const payload = getNodeDisplayPayload(cx, node.id, scope) orelse return false;
    if (payload.items.len == 0) return false;
    const runtime = cx.scene_runtime.get(node.id) orelse return false;

    if (text_trace.enabled()) {
        var text_item_count: usize = 0;
        var blob_backed_text_item_count: usize = 0;
        var min_blob_id: u32 = std.math.maxInt(u32);
        var max_blob_id: u32 = 0;
        for (payload.items) |item| {
            switch (item) {
                .text_run => |run| {
                    text_item_count += 1;
                    if (run.blob_id != INVALID_ID and run.blob_byte_end > run.blob_byte_start) {
                        blob_backed_text_item_count += 1;
                        min_blob_id = @min(min_blob_id, run.blob_id);
                        max_blob_id = @max(max_blob_id, run.blob_id);
                    }
                },
                else => {},
            }
        }
        if (text_item_count > 0 and blob_backed_text_item_count > 0 and payload.blobs.len < blob_backed_text_item_count) {
            const runtime_blob_start: u32 = switch (scope) {
                .own => runtime.text_blob_start,
                .subtree => runtime.subtree_text_blob_start,
            };
            const runtime_blob_count: u32 = switch (scope) {
                .own => runtime.text_blob_count,
                .subtree => runtime.subtree_text_blob_count,
            };
            text_trace.log(
                cx.scene_runtime.frame_epoch,
                "payload-replay-shared-blob-ref node={d} scope={s} strategy={s} items={d} text_items={d} blob_text_items={d} runtime_blob_range=[{d}..{d}) payload_blobs={d} run_blob_range=[{d}..{d}]",
                .{
                    node.id,
                    @tagName(scope),
                    @tagName(strategy),
                    payload.items.len,
                    text_item_count,
                    blob_backed_text_item_count,
                    runtime_blob_start,
                    runtime_blob_start + runtime_blob_count,
                    payload.blobs.len,
                    if (min_blob_id == std.math.maxInt(u32)) 0 else min_blob_id,
                    max_blob_id,
                },
            );
        }
    }
    const start: usize = switch (scope) {
        .own => runtime.display_item_start,
        .subtree => runtime.subtree_display_item_start,
    };
    const uses_self_effect_space = scene_runtime_mod.displayPayloadSubtreeStrategyUsesSelfEffectSpace(strategy);
    try appendDisplayItemsToRenderListInternal(
        cx,
        start,
        start + payload.items.len,
        true,
        active_parent_effect_id,
        if (uses_self_effect_space) node else null,
        if (uses_self_effect_space) exec_state else null,
    );
    return true;
}
