//! node_render_cache, v0.12 §N2 god-object split: 从 node.zig 抽出
//! 渲染缓存子域（6 方法 + TextHashSnapshot 类型）。
//!
//! 范式同 §N1 node_dirty.zig：Node-typed free function +
//! @import("node.zig") 循环 import；node.zig 保留 thin delegate（原
//! pub/private 可见性），内部 caller 零改。
//!
//! buildCachedRenderSlice 原是 static fn（无 self）-> 本模块模块级
//! free function。TextHashSnapshot 类型搬入，node.zig re-export
//! （外部 text_item_render.zig 等用 node.Node.TextHashSnapshot）。
//!
//! source of truth = self.meta.per_frame.caches.commands.{own,promoted}
//! / .text_hash；本模块只做 build/invalidate/hash 逻辑。

const std = @import("std");
const node_mod = @import("node.zig");
const types = @import("types.zig");
const render_cache = @import("render_cache.zig");
const display_list_mod = @import("display_list.zig");

const Node = node_mod.Node;
const Allocator = std.mem.Allocator;
const DisplayItem = display_list_mod.DisplayItem;
const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const TextProps = types.TextProps;
const ChildCommandSlice = render_cache.ChildCommandSlice;
const CachedRenderSlice = render_cache.CachedRenderSlice;
const duplicateDisplayItems = render_cache.duplicateDisplayItems;
const freeDuplicatedDisplayItems = render_cache.freeDuplicatedDisplayItems;

pub const TextHashSnapshot = struct {
    content_hash: u64,
    spans_hash: u64,
};

fn buildCachedRenderSlice(
    allocator: Allocator,
    commands: []const DisplayItem,
    scroll_ox: f32,
    scroll_oy: f32,
    self_content_command_count: u32,
    descendant_content_command_count: u32,
    descendant_regular_command_count: u32,
    descendant_sticky_command_count: u32,
    descendant_overlay_command_count: u32,
    descendant_tail_command_count: u32,
    regular_child_slices: []const ChildCommandSlice,
    content_version: u32,
    composite_version: u32,
    promoted_layer_id: u32,
    world_bounds: ComputedRect,
    world_transform: Transform2D,
) ?CachedRenderSlice {
    if (commands.len == 0) return null;
    const duped = duplicateDisplayItems(allocator, commands) catch return null;
    const duped_regular_child_slices = if (regular_child_slices.len > 0)
        allocator.dupe(ChildCommandSlice, regular_child_slices) catch {
            freeDuplicatedDisplayItems(allocator, duped);
            return null;
        }
    else
        &.{};
    return .{
        .commands = duped,
        .scroll_offset_x = scroll_ox,
        .scroll_offset_y = scroll_oy,
        .self_content_command_count = self_content_command_count,
        .descendant_content_command_count = descendant_content_command_count,
        .descendant_regular_command_count = descendant_regular_command_count,
        .descendant_sticky_command_count = descendant_sticky_command_count,
        .descendant_overlay_command_count = descendant_overlay_command_count,
        .descendant_tail_command_count = descendant_tail_command_count,
        .regular_child_slices = duped_regular_child_slices,
        .content_version = content_version,
        .composite_version = composite_version,
        .promoted_layer_id = promoted_layer_id,
        .world_bounds = world_bounds,
        .world_transform = world_transform,
        .allocator = allocator,
    };
}

/// 缓存渲染命令片段（深拷贝 text 的 content/spans，避免指针悬挂）
pub fn cacheRenderCommands(self: *Node, allocator: Allocator, commands: []const DisplayItem, scroll_ox: f32, scroll_oy: f32) void {
    if (node_mod.shouldLogBracketNode(self.id)) {
        std.debug.print("[PT-BRACKET] cache node={d} kind=legacy count={d} content_v={d} composite_v={d}\n", .{
            self.id,
            commands.len,
            self.meta.per_frame.caches.versions.content,
            self.meta.per_frame.caches.versions.composite,
        });
    }
    const fresh = buildCachedRenderSlice(
        allocator,
        commands,
        scroll_ox,
        scroll_oy,
        @intCast(commands.len),
        0,
        0,
        0,
        0,
        0,
        &.{},
        self.meta.per_frame.caches.versions.content,
        self.meta.per_frame.caches.versions.composite,
        std.math.maxInt(u32),
        blk: {
            const sr = self.rectFromWorldOrFallback();
            break :blk ComputedRect.init(scroll_ox, scroll_oy, sr.w, sr.h);
        },
        Transform2D.translation(scroll_ox, scroll_oy),
    );
    invalidateRenderCache(self);
    self.meta.per_frame.caches.commands.own = fresh;
}

pub fn cachePromotedRenderCommands(
    self: *Node,
    allocator: Allocator,
    commands: []const DisplayItem,
    scroll_ox: f32,
    scroll_oy: f32,
    promoted_layer_id: u32,
    world_bounds: ComputedRect,
    world_transform: Transform2D,
    self_content_command_count: u32,
    descendant_content_command_count: u32,
    descendant_regular_command_count: u32,
    descendant_sticky_command_count: u32,
    descendant_overlay_command_count: u32,
    descendant_tail_command_count: u32,
    regular_child_slices: []const ChildCommandSlice,
) void {
    if (node_mod.shouldLogBracketNode(self.id)) {
        std.debug.print("[PT-BRACKET] cache node={d} kind=promoted count={d} self={d} desc={d} content_v={d} composite_v={d}\n", .{
            self.id,
            commands.len,
            self_content_command_count,
            descendant_content_command_count,
            self.meta.per_frame.caches.versions.content,
            self.meta.per_frame.caches.versions.composite,
        });
    }
    const fresh = buildCachedRenderSlice(
        allocator,
        commands,
        scroll_ox,
        scroll_oy,
        self_content_command_count,
        descendant_content_command_count,
        descendant_regular_command_count,
        descendant_sticky_command_count,
        descendant_overlay_command_count,
        descendant_tail_command_count,
        regular_child_slices,
        self.meta.per_frame.caches.versions.content,
        self.meta.per_frame.caches.versions.composite,
        promoted_layer_id,
        world_bounds,
        world_transform,
    );
    invalidatePromotedRenderCache(self);
    self.meta.per_frame.caches.commands.promoted = fresh;
}

/// 释放缓存的渲染命令
pub fn invalidateRenderCache(self: *Node) void {
    if (self.meta.per_frame.caches.commands.own) |*cache| {
        if (node_mod.shouldLogBracketNode(self.id)) {
            std.debug.print("[PT-BRACKET] invalidate node={d} kind=legacy cached={d}\n", .{
                self.id,
                cache.commands.len,
            });
        }
        cache.deinit();
        self.meta.per_frame.caches.commands.own = null;
    }
}

/// 下游回归：写入非 promoted 干净子树的跨帧 display payload 缓存。
/// commands 需已物化（text_run 的 blob 引用断开、content 指向帧内字节,
/// buildCachedRenderSlice -> duplicateDisplayItems 会深拷贝 content/spans）。
/// stamp = 写入帧的 transform/effect/clip 链根 id + world bounds 尺寸。
pub fn cacheSubtreePayloadCommands(
    self: *Node,
    allocator: Allocator,
    commands: []const DisplayItem,
    self_content_command_count: u32,
    transform_id: u32,
    effect_id: u32,
    clip_id: u32,
    world_bounds: ComputedRect,
) void {
    var fresh = buildCachedRenderSlice(
        allocator,
        commands,
        0,
        0,
        self_content_command_count,
        @intCast(commands.len - @min(commands.len, @as(usize, self_content_command_count))),
        0,
        0,
        0,
        0,
        &.{},
        self.meta.per_frame.caches.versions.content,
        self.meta.per_frame.caches.versions.composite,
        std.math.maxInt(u32),
        world_bounds,
        Transform2D{},
    ) orelse {
        invalidateSubtreePayloadCache(self);
        return;
    };
    fresh.cached_transform_id = transform_id;
    fresh.cached_effect_id = effect_id;
    fresh.cached_clip_id = clip_id;
    invalidateSubtreePayloadCache(self);
    self.meta.per_frame.caches.commands.subtree_payload = fresh;
}

pub fn invalidateSubtreePayloadCache(self: *Node) void {
    if (self.meta.per_frame.caches.commands.subtree_payload) |*cache| {
        cache.deinit();
        self.meta.per_frame.caches.commands.subtree_payload = null;
    }
}

pub fn invalidatePromotedRenderCache(self: *Node) void {
    if (self.meta.per_frame.caches.commands.promoted) |*cache| {
        if (node_mod.shouldLogBracketNode(self.id)) {
            std.debug.print("[PT-BRACKET] invalidate node={d} kind=promoted cached={d}\n", .{
                self.id,
                cache.commands.len,
            });
        }
        cache.deinit();
        self.meta.per_frame.caches.commands.promoted = null;
    }
}

/// 作废 text hash 缓存，每次写 text content 都必须调。
///
/// ⚠️ 缓存键是 (content_version, content_ptr, content_len, spans_ptr, spans_len)，
/// 而 `Node.setText` **不撞** content_version（它只是转发给 World.content，
/// 不碰 per_frame.caches）。于是"等长换文本"时三个键分量可以全部不变：
///   - len 相同（"3 × 4" -> "3 × 5" 都是 6 字节）；
///   - ptr 相同（旧 owned buffer 被 free 后 allocator 常把同一块还给新的
///     dupe；就地改写调用方自己的 buffer 则必然同址）；
///   - version 相同（setText 不撞，调用方若只 markRenderDirty 也未必先于
///     本次读取发生）。
/// 命中旧 hash 的后果不是崩溃而是**画面陈旧**：blob 指纹、paint chunk 的
/// content_hash、retained 层指纹一路判"内容没变"而跳过重录。含字体回退的
/// 串最扎眼，文本被按字体切成多段（"3 × 4" = ['3 ']['×'][' ']['4']），
/// 变化落在哪段就只有那段更新，其余段留着旧字形。
///
/// 把作废点放在写路径（而不是让调用方记得 markRenderDirty）是因为：hash 的
/// 输入就是 content/spans 本身，谁改谁负责作废，不能依赖下游脏标记的时序。
pub fn invalidateTextHashCache(self: *Node) void {
    self.meta.per_frame.caches.text_hash = .{};
}

pub fn getOrComputeTextHashes(self: *Node, t: *const TextProps) TextHashSnapshot {
    const content_ptr = if (t.content.len > 0) @intFromPtr(t.content.ptr) else 0;
    const spans_ptr = if (t.spans.len > 0) @intFromPtr(t.spans.ptr) else 0;
    const cache = &self.meta.per_frame.caches.text_hash;
    if (cache.content_version != self.meta.per_frame.caches.versions.content or
        cache.content_ptr != content_ptr or
        cache.content_len != t.content.len or
        cache.spans_ptr != spans_ptr or
        cache.spans_len != t.spans.len)
    {
        cache.content_version = self.meta.per_frame.caches.versions.content;
        cache.content_ptr = content_ptr;
        cache.content_len = t.content.len;
        cache.spans_ptr = spans_ptr;
        cache.spans_len = t.spans.len;
        cache.content_hash = if (t.content.len > 0)
            std.hash.Wyhash.hash(0, t.content)
        else
            0;
        cache.spans_hash = if (t.spans.len > 0)
            std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(t.spans))
        else
            0;
    }
    return .{
        .content_hash = cache.content_hash,
        .spans_hash = cache.spans_hash,
    };
}
