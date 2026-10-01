/// 节点缓存最终化：将当前帧渲染命令写入 promoted cache 或 legacy overflow cache
///
/// 设计要点 (R3g 后)：cache band 不再切 cx.display_list。改成从每个 child 的
/// runtime.subtree_display_item_* 范围 + node 自己的 runtime.display_item_* +
/// content_slices.tail_* 拼接。这样 child 走 subtree-replay / own-replay 短路
/// (写 lowering_buffer 不写 display_list 末尾) 也能被正确捕获，runtime range 永远
/// 指向 prebuilt 位置，里面就是 child 的真实 contributing items。
const std = @import("std");
const node_mod = @import("../node.zig");
const display_list_mod = @import("../display_list.zig");
const render_context_mod = @import("render_context.zig");
const node_state = @import("node_state.zig");

const types = @import("../types.zig");
const INVALID_ID = @import("../property_tree.zig").INVALID_ID;
const render_engine = @import("mod.zig");

const Node = node_mod.Node;
const DisplayItem = display_list_mod.DisplayItem;
const RenderContext = render_context_mod.RenderContext;
const NodeContentSlices = node_state.NodeContentSlices;
const NodeExecutionState = node_state.NodeExecutionState;
const NodeExecutionPlan = node_state.NodeExecutionPlan;
const ChildCommandSlice = node_mod.ChildCommandSlice;
const ComputedRect = types.ComputedRect;

var overlay_debug_cache: ?bool = null;

fn overlayDebugEnabled() bool {
    return overlay_debug_cache orelse blk: {
        const enabled = std.posix.getenv("ZENIT_DEBUG_OVERLAY") != null;
        overlay_debug_cache = enabled;
        break :blk enabled;
    };
}

fn shouldDebugOverlayNode(node: *Node) bool {
    if (!overlayDebugEnabled()) return false;
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

/// 从 node 的 runtime.display_item_* 范围切 own (self) items。
fn nodeOwnItems(cx: *RenderContext, node_id: u32) []const DisplayItem {
    const runtime = cx.scene_runtime.get(node_id) orelse return &.{};
    const start = @as(usize, runtime.display_item_start);
    const count = @as(usize, runtime.display_item_count);
    if (count == 0) return &.{};
    const total = cx.display_list.items.items.len;
    if (start >= total) return &.{};
    const end = @min(start + count, total);
    return cx.display_list.items.items[start..end];
}

/// 从 child 的 runtime range 切 child 的 contributing display items。
/// 优先用 subtree range；若 subtree count=0 但 own count>0，回退到 own range,
/// 这覆盖 leaf 节点 own 走 prebuild 短路、subtree paint 期间 0 增长的情况。
fn childSubtreeItems(cx: *RenderContext, child_id: u32) []const DisplayItem {
    const runtime = cx.scene_runtime.get(child_id) orelse return &.{};
    const total = cx.display_list.items.items.len;

    var start = @as(usize, runtime.subtree_display_item_start);
    var count = @as(usize, runtime.subtree_display_item_count);
    if (count == 0) {
        start = @as(usize, runtime.display_item_start);
        count = @as(usize, runtime.display_item_count);
        if (count == 0) return &.{};
    }
    if (start >= total) return &.{};
    const end = @min(start + count, total);
    return cx.display_list.items.items[start..end];
}

/// 拼接 cache 命令缓冲：
///   [self_items][regular_children_subtree...][sticky_children_subtree...][overlay_children_subtree...][tail]
/// 返回 buffer + 各段 count + per-child slices。buffer 用 cx.frame_allocator 分配
/// (per-frame arena, 拼好交给 cachePromotedRenderCommands 内部 dupe 持有)。
const Assembly = struct {
    commands: []const DisplayItem,
    self_count: u32,
    regular_count: u32,
    sticky_count: u32,
    overlay_count: u32,
    tail_count: u32,
    clip_open_count: u32,
    clip_close_count: u32,
    regular_child_slices: []const ChildCommandSlice,
};

fn assembleCacheCommands(
    cx: *RenderContext,
    node: *Node,
    content_slices: NodeContentSlices,
    exec_state: NodeExecutionState,
) !Assembly {
    const allocator = cx.frame_allocator;

    const self_items = nodeOwnItems(cx, node.id);

    if (shouldDebugOverlayNode(node)) {
        const own_rt = cx.scene_runtime.get(node.id);
        std.debug.print("[overlay-debug]   asm node id={d} own=({d},{d}) list_len={d}\n", .{
            node.id,
            if (own_rt) |r| r.display_item_start else 0,
            if (own_rt) |r| r.display_item_count else 0,
            cx.display_list.items.items.len,
        });
        for (content_slices.regular_children.items) |cid| {
            if (cx.scene_runtime.get(cid)) |r| {
                std.debug.print("[overlay-debug]   asm child id={d} subtree=({d},{d}) own=({d},{d})\n", .{
                    cid, r.subtree_display_item_start, r.subtree_display_item_count, r.display_item_start, r.display_item_count,
                });
            } else {
                std.debug.print("[overlay-debug]   asm child id={d} NO-RUNTIME\n", .{cid});
            }
        }
    }

    var total_count: usize = self_items.len;
    for (content_slices.regular_children.items) |cid| {
        total_count += childSubtreeItems(cx, cid).len;
    }
    for (content_slices.sticky_children.items) |cid| {
        total_count += childSubtreeItems(cx, cid).len;
    }
    for (content_slices.overlay_children.items) |cid| {
        total_count += childSubtreeItems(cx, cid).len;
    }
    const tail_count = content_slices.tail_end_idx - content_slices.tail_start_idx;
    total_count += tail_count;
    const clip_band: u32 = if (content_slices.clip_wrapped) 1 else 0;
    total_count += 2 * @as(usize, clip_band);

    const buf = try allocator.alloc(DisplayItem, total_count);
    var idx: usize = 0;

    @memcpy(buf[idx .. idx + self_items.len], self_items);
    idx += self_items.len;

    // 节点自身 overflow clip 的 children 包围（与 paint pass 发射的同一对 token）。
    if (clip_band != 0) {
        buf[idx] = render_engine.scrollClipPushToken(exec_state);
        idx += 1;
    }

    var regular_child_slices = try allocator.alloc(ChildCommandSlice, content_slices.regular_children.items.len);
    var regular_count: u32 = 0;
    for (content_slices.regular_children.items, 0..) |cid, i| {
        const items = childSubtreeItems(cx, cid);
        @memcpy(buf[idx .. idx + items.len], items);
        idx += items.len;
        regular_count += @intCast(items.len);
        regular_child_slices[i] = .{ .child_id = cid, .command_count = @intCast(items.len) };
    }

    var sticky_count: u32 = 0;
    for (content_slices.sticky_children.items) |cid| {
        const items = childSubtreeItems(cx, cid);
        @memcpy(buf[idx .. idx + items.len], items);
        idx += items.len;
        sticky_count += @intCast(items.len);
    }

    var overlay_count: u32 = 0;
    for (content_slices.overlay_children.items) |cid| {
        const items = childSubtreeItems(cx, cid);
        @memcpy(buf[idx .. idx + items.len], items);
        idx += items.len;
        overlay_count += @intCast(items.len);
    }

    if (clip_band != 0) {
        buf[idx] = .{ .pop_clip = .{ .header = render_engine.scrollClipTokenHeader(exec_state) } };
        idx += 1;
    }

    if (tail_count > 0) {
        const tail = cx.display_list.items.items[content_slices.tail_start_idx..content_slices.tail_end_idx];
        @memcpy(buf[idx .. idx + tail.len], tail);
        idx += tail.len;
    }

    // 跨帧自包含化：blob-backed text_run 的 blob_id 指向**每帧重建**的 text_blob_store，
    // 下帧 replay 时 id 对不上 -> resolveTextRunContent 返回空串 -> settle 帧文字消失。
    // 写缓存时就地物化：content 指向当前帧 blob 字节（cachePromotedRenderCommands ->
    // duplicateDisplayItems 会深拷贝 content.len>0 的字节），blob_id 置 INVALID 断开
    // 跨帧引用。缓存从此不依赖任何帧内序号身份。
    for (buf) |*item| {
        switch (item.*) {
            .text_run => |*t| {
                if (t.blob_id != INVALID_ID) {
                    const resolved = display_list_mod.resolveTextRunContent(cx.text_blob_store, t.*);
                    t.content = resolved;
                    t.blob_id = INVALID_ID;
                    t.blob_byte_start = 0;
                    t.blob_byte_end = 0;
                }
            },
            else => {},
        }
    }

    return .{
        .commands = buf,
        .self_count = @intCast(self_items.len),
        .regular_count = regular_count,
        .sticky_count = sticky_count,
        .overlay_count = overlay_count,
        .tail_count = @intCast(tail_count),
        .clip_open_count = clip_band,
        .clip_close_count = clip_band,
        .regular_child_slices = regular_child_slices,
    };
}

/// descendant_scoped_promoted 策略：拼接旧 self_commands + 新 descendant_commands
/// 若无旧缓存或 old_self_commands 为空，退化为直接写 commands_slice
fn writeDescendantScopedPromotedCache(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    asm_: Assembly,
) void {
    const node_rect = ComputedRect{
        .x = exec_state.render_x,
        .y = exec_state.render_y,
        .w = exec_state.render_w,
        .h = exec_state.render_h,
    };
    const descendant_count = asm_.regular_count + asm_.sticky_count + asm_.overlay_count + asm_.tail_count + asm_.clip_open_count + asm_.clip_close_count;

    if (node.meta.per_frame.caches.commands.promoted) |old_cache| {
        // 洗白防护（下游回归 review 指出的洞）：本分支保留**旧帧的 self 命令**
        // （含按值烘焙旧 glass 参数的 begin_blur token），glass hash 必须跟随
        // 实际写入的命令（沿用旧 hash），否则 markPromotedCacheRebuilt 盖上
        // 当前参数的章后，替放守卫比"当前 vs 当前"永远相等，旧 token 畅通
        // 无阻（GlassBox hover 回落方向视觉冻结的根因）。
        const old_glass_hash = old_cache.cached_glass_hash;
        const old_self_commands = old_cache.selfCommands();
        if (old_self_commands.len > 0) {
            // 拼旧 self + 新 descendant (asm_.commands 是 self ++ descendant 拼好的；切尾)。
            const new_descendant_commands = asm_.commands[asm_.self_count..];
            // frame arena：cachePromotedRenderCommands 内部会 dupe 持久化，
            // spliced 本身只活到本次调用结束，无需 free。
            const spliced_buf = cx.frame_allocator.alloc(DisplayItem, old_self_commands.len + new_descendant_commands.len) catch {
                node.cachePromotedRenderCommands(
                    cx.allocator,
                    asm_.commands,
                    exec_state.render_x,
                    exec_state.render_y,
                    exec_state.promoted_layer_stable_id,
                    node_rect,
                    exec_state.content_transform,
                    asm_.self_count,
                    descendant_count,
                    asm_.regular_count,
                    asm_.sticky_count,
                    asm_.overlay_count,
                    asm_.tail_count,
                    asm_.regular_child_slices,
                );
                return;
            };
            @memcpy(spliced_buf[0..old_self_commands.len], old_self_commands);
            @memcpy(spliced_buf[old_self_commands.len..], new_descendant_commands);
            node.cachePromotedRenderCommands(
                cx.allocator,
                spliced_buf,
                exec_state.render_x,
                exec_state.render_y,
                exec_state.promoted_layer_stable_id,
                node_rect,
                exec_state.content_transform,
                @intCast(old_self_commands.len),
                descendant_count,
                asm_.regular_count,
                asm_.sticky_count,
                asm_.overlay_count,
                asm_.tail_count,
                asm_.regular_child_slices,
            );
            if (node.meta.per_frame.caches.commands.promoted) |*fresh| {
                fresh.cached_glass_hash = old_glass_hash;
            }
            cx.perf.descendant_scoped_promoted_cache_splice_count += 1;
            return;
        }
    }

    node.cachePromotedRenderCommands(
        cx.allocator,
        asm_.commands,
        exec_state.render_x,
        exec_state.render_y,
        exec_state.promoted_layer_stable_id,
        node_rect,
        exec_state.content_transform,
        asm_.self_count,
        descendant_count,
        asm_.regular_count,
        asm_.sticky_count,
        asm_.overlay_count,
        asm_.tail_count,
        asm_.regular_child_slices,
    );
}

/// 普通 promoted cache 写入（非 descendant_scoped_promoted 策略）
fn writePromotedCache(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    asm_: Assembly,
) void {
    const descendant_count = asm_.regular_count + asm_.sticky_count + asm_.overlay_count + asm_.tail_count + asm_.clip_open_count + asm_.clip_close_count;
    node.cachePromotedRenderCommands(
        cx.allocator,
        asm_.commands,
        exec_state.render_x,
        exec_state.render_y,
        exec_state.promoted_layer_stable_id,
        .{
            .x = exec_state.render_x,
            .y = exec_state.render_y,
            .w = exec_state.render_w,
            .h = exec_state.render_h,
        },
        exec_state.content_transform,
        asm_.self_count,
        descendant_count,
        asm_.regular_count,
        asm_.sticky_count,
        asm_.overlay_count,
        asm_.tail_count,
        asm_.regular_child_slices,
    );
}

/// 写入 promoted cache 后更新 scene_runtime + compositor_plan 状态
fn markPromotedCacheRebuilt(cx: *RenderContext, node: *Node, exec_state: NodeExecutionState) void {
    // 记录写入帧的 property-tree 根 id：替放前比对，防 stale 帧内序号索引
    // 错误/越界的 transform/effect 节点（见 CachedRenderSlice 字段注释）。
    if (node.meta.per_frame.caches.commands.promoted) |*cache| {
        cache.cached_transform_id = exec_state.retained_ids.transform_id;
        cache.cached_effect_id = exec_state.retained_ids.effect_id;
        // 下游回归：clip_id 此前漏 stamp/漏比对，纯 clip 数量平移（transform/
        // effect 不变）可蒙混过关，替放后 item 索引到别的节点的 clip rect。
        cache.cached_clip_id = exec_state.retained_ids.clip_id;
        // glass 参数按值烘焙在缓存的 begin_blur token 里；参数写入不 bump
        // content_version、dirty 位会被祖先 subtree replay 提前消费，必须
        // 独立 stamp（GlassBox interactive hover 真机冻结的根因）。
        // maxInt 哨兵 = 本次写入是 fresh 记录（splice 路径已带旧命令的旧章，
        // 覆盖它就是"洗白"，旧 token 配新章，守卫失效）。
        if (cache.cached_glass_hash == std.math.maxInt(u64)) {
            cache.cached_glass_hash = render_engine.nodeGlassParamsHash(node);
        }
    }
    cx.layer_tree.planMarkLayerSurfaceRebuilt(exec_state.promoted_layer_id);
    if (cx.scene_runtime.nodes.getPtr(node.id)) |runtime| {
        runtime.promoted_surface_flags.surface_valid = true;
        runtime.promoted_surface_flags.reused_this_frame = false;
        runtime.promoted_surface_flags.rebuilt_this_frame = true;
    }
}

pub fn finalizeNodeCaches(
    cx: *RenderContext,
    node: *Node,
    legacy_overflow_start_idx: usize,
    content_slices: NodeContentSlices,
    exec_state: NodeExecutionState,
    exec_plan: NodeExecutionPlan,
) void {
    if (exec_plan.should_write_promoted_cache) {
        const asm_ = assembleCacheCommands(cx, node, content_slices, exec_state) catch {
            // OOM: 跳过 cache 写入；下帧会重建
            return;
        };

        if (shouldDebugOverlayNode(node)) {
            std.debug.print(
                "[overlay-debug] frame={d} stage=cache-write component={s} id={d} self={d} regular={d} sticky={d} overlay={d} tail={d}\n",
                .{
                    cx.scene_runtime.frame_epoch,
                    node.meta.ownership.meta.component_name orelse "?",
                    node.id,
                    asm_.self_count,
                    asm_.regular_count,
                    asm_.sticky_count,
                    asm_.overlay_count,
                    asm_.tail_count,
                },
            );
        }

        if (exec_plan.rebuild_strategy == .descendant_scoped_promoted) {
            writeDescendantScopedPromotedCache(cx, node, exec_state, asm_);
        } else {
            writePromotedCache(cx, node, exec_state, asm_);
        }
        if (node.meta.per_frame.caches.commands.promoted) |*cache| {
            cache.descendant_clip_open_count = asm_.clip_open_count;
            cache.descendant_clip_close_count = asm_.clip_close_count;
        }
        markPromotedCacheRebuilt(cx, node, exec_state);
        return;
    }

    if (exec_plan.should_write_legacy_overflow_cache) {
        const commands_slice = cx.display_list.items.items[legacy_overflow_start_idx..];
        node.cacheRenderCommands(
            cx.allocator,
            commands_slice,
            exec_state.world_origin.x,
            exec_state.world_origin.y,
        );
    }
}
