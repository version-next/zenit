/// node cache finalization: write current-frame render commands to promoted cache or legacy
/// overflow cache.
///
/// design after R3g: cache band no longer cuts cx.display_list. instead splice each child's
/// runtime.subtree_display_item_* range + node's own runtime.display_item_* +
/// content_slices.tail_*. child using subtree-replay / own-replay shortcut (write lowering_buffer
/// not display_list tail) captured correctly, runtime range always points prebuilt location,
/// contains child's real contributing items.
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
        const enabled = @import("zenit_environment").flag("ZENIT_DEBUG_OVERLAY");
        overlay_debug_cache = enabled;
        break :blk enabled;
    };
}

fn shouldDebugOverlayNode(node: *Node) bool {
    if (!overlayDebugEnabled()) return false;
    if (node.style.composited_group() or node.style.contentWarp() != null) return true;
    const name = node.meta.ownership.meta.component_name orelse return false;
    return std.mem.eql(u8, name, "Select") or
        std.mem.eql(u8, name, "Popover") or
        std.mem.eql(u8, name, "PopoverContent") or
        std.mem.eql(u8, name, "DatePicker") or
        std.mem.eql(u8, name, "DateRangePicker") or
        std.mem.eql(u8, name, "DatePickerPanel") or
        std.mem.eql(u8, name, "DateRangePickerPanel");
}

/// slice own (self) items from node's runtime.display_item_* range.
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

/// slice child's contributing display items from child's runtime range. prefer subtree range; if
/// subtree count=0 but own count>0, fall back to own range, covers leaf node own prebuild shortcut,
/// zero growth during subtree paint.
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

fn anyChildSubtreeSplit(cx: *RenderContext, content_slices: NodeContentSlices) bool {
    for ([_][]const u32{ content_slices.regular_children.items, content_slices.sticky_children.items, content_slices.overlay_children.items }) |ids| {
        for (ids) |cid| {
            const runtime = cx.scene_runtime.getPtr(cid) orelse continue;
            if (runtime.subtree_display_split) return true;
        }
    }
    return false;
}

/// splice cache command buffer:
/// [self_items][regular_children_subtree...][sticky_children_subtree...][overlay_children_subtree...][tail].
/// return buffer + segment counts + per-child slices. buffer allocated via cx.frame_allocator
/// (per-frame arena, spliced then duped in cachePromotedRenderCommands).
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
    exec_state: *const NodeExecutionState,
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

    // node's own overflow clip wrapping children (same token pair as paint pass emits).
    if (clip_band != 0) {
        buf[idx] = render_engine.scrollClipPushTokenBorrowed(exec_state);
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
        buf[idx] = .{ .pop_clip = .{ .header = render_engine.scrollClipTokenHeaderBorrowed(exec_state) } };
        idx += 1;
    }

    if (tail_count > 0) {
        const tail = cx.display_list.items.items[content_slices.tail_start_idx..content_slices.tail_end_idx];
        @memcpy(buf[idx .. idx + tail.len], tail);
        idx += tail.len;
    }

    // cross-frame self-containment: blob-backed text_run blob_id points to **per-frame rebuilt**
    // text_blob_store, next frame replay id mismatches -> resolveTextRunContent returns empty ->
    // settle frame text vanishes. materialize on cache write: content points current frame blob
    // bytes (cachePromotedRenderCommands -> duplicateDisplayItems deep-copies content.len>0 bytes),
    // blob_id set INVALID cuts cross-frame reference. cache henceforth independent of frame-local
    // sequence ids.
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

/// descendant_scoped_promoted strategy: splice old self_commands + new descendant_commands. if no
/// old cache or old_self_commands empty, degrade to direct write commands_slice
fn writeDescendantScopedPromotedCache(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
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
        // whitewash defense (downstream regression caught in review): this branch keeps **old
        // frame's self commands** (includes begin_blur tokens with old-frame glass params baked),
        // glass hash must follow actual written commands (reuse old hash), else
        // markPromotedCacheRebuilt stamps current params, replacement guard comparing 'current vs
        // current' always equal, old token flows unchecked (GlassBox hover fallback direction
        // visual freeze root cause).
        const old_glass_hash = old_cache.cached_glass_hash;
        const old_self_commands = old_cache.selfCommands();
        if (old_self_commands.len > 0) {
            // splice old self + new descendant (asm_.commands is self ++ descendant spliced; slice
            // tail).
            const new_descendant_commands = asm_.commands[asm_.self_count..];
            // frame arena: cachePromotedRenderCommands dupes for persistence, spliced itself lives
            // only until call end, no free needed.
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

/// normal promoted cache write (non-descendant_scoped_promoted strategy)
fn writePromotedCache(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
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

/// after writing promoted cache update scene_runtime + compositor_plan state
fn markPromotedCacheRebuilt(cx: *RenderContext, node: *Node, exec_state: *const NodeExecutionState) void {
    // record property-tree root id of written frame: compare before replay, prevent stale
    // frame-local id indexing errors/bounds of transform/effect nodes (see CachedRenderSlice field
    // comment).
    if (node.meta.per_frame.caches.commands.promoted) |*cache| {
        cache.cached_transform_id = exec_state.retained_ids.transform_id;
        cache.cached_effect_id = exec_state.retained_ids.effect_id;
        // downstream regression: clip_id previously missed stamp/compare, pure clip count shift
        // (transform/effect unchanged) could hide, replay misindexes to other node's clip rect.
        cache.cached_clip_id = exec_state.retained_ids.clip_id;
        // Raster policy / icon snap baked into the items (render_engine
        // dropCachesWithStaleTextRasterState). An old self segment spliced in was recorded under
        // the same state: a cache from the other state is dropped before this frame renders.
        cache.cached_force_linear_text = exec_state.subtree_force_linear_text;
        // glass params baked-by-value in cache's begin_blur token; param write doesn't bump
        // content_version, dirty consumed early by ancestor subtree replay, needs independent stamp
        // (GlassBox interactive hover real machine freeze root cause). maxInt sentinel = this write
        // is fresh record (splice path already has old command's old stamp, overwriting it is
        // 'whitewash', old token with new stamp, guard fails).
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
    _: usize,
    content_slices: NodeContentSlices,
    exec_state: NodeExecutionState,
    exec_plan: NodeExecutionPlan,
) void {
    finalizeNodeCachesBorrowed(cx, node, 0, content_slices, &exec_state, exec_plan);
}

pub fn finalizeNodeCachesBorrowed(
    cx: *RenderContext,
    node: *Node,
    _: usize,
    content_slices: NodeContentSlices,
    exec_state: *const NodeExecutionState,
    exec_plan: NodeExecutionPlan,
) void {
    if (exec_plan.should_write_promoted_cache) {
        const asm_ = assembleCacheCommands(cx, node, content_slices, exec_state) catch {
            // OOM: skip cache write; next frame rebuilds
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
        // A child split between the prebuild prefix and the paint-pass tail has no single range
        // to copy: a cache assembled now would replay without its prefix part. Keep none.
        if (anyChildSubtreeSplit(cx, content_slices)) {
            node.invalidateRenderCache();
            return;
        }
        // Both caches use the same self-before-descendants contract. A raw
        // paint-pass tail can omit prebuilt own content or include it depending
        // on the prepass prefix, making replay append a second background.
        const assembled = assembleCacheCommands(cx, node, content_slices, exec_state) catch return;
        node.cacheRenderCommands(
            cx.allocator,
            assembled.commands,
            exec_state.world_origin.x,
            exec_state.world_origin.y,
        );
        if (node.meta.per_frame.caches.commands.own) |*cache| {
            cache.cached_force_linear_text = exec_state.subtree_force_linear_text;
            cache.self_content_command_count = assembled.self_count;
            cache.descendant_content_command_count = @intCast(assembled.commands.len - assembled.self_count);
        }
    }
}
