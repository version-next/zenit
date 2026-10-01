//! Cached display item slices used by overflow-hidden subtrees and
//! display-list replay. Each `Node` owns at most one `CachedRenderSlice`;
//! the helpers here deep-copy display items (notably text content / spans)
//! so the cache can outlive the per-frame arena.
//!
//! Cache 内部 IR 是 DisplayItem。索引基准 = cx.display_list.items.items.len。
const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const display_list_mod = @import("display_list.zig");

const DisplayItem = display_list_mod.DisplayItem;
const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;

/// Per-child slice metadata so `regularChildCommands` can locate a child's
/// cached commands by id without rescanning every frame.
pub const ChildCommandSlice = struct {
    child_id: u32,
    command_count: u32,
};

/// A node-level cached slice of display items. Layout is:
///   [self_content][descendant_regular][descendant_sticky][descendant_overlay][descendant_tail]
/// The accessor methods carve the buffer into those bands.
pub const CachedRenderSlice = struct {
    commands: []DisplayItem,
    scroll_offset_x: f32,
    scroll_offset_y: f32,
    self_content_command_count: u32 = 0,
    descendant_content_command_count: u32 = 0,
    descendant_regular_command_count: u32 = 0,
    descendant_sticky_command_count: u32 = 0,
    descendant_overlay_command_count: u32 = 0,
    descendant_tail_command_count: u32 = 0,
    /// 节点自身 overflow clip 的 children 包围 token（node-local push_clip /
    /// pop_clip，见 render_engine emitScrollClipBegin）。它们不属于任何 child，
    /// 但整段替放（promoted cache hit）必须带上，否则命中缓存的帧 children
    /// 零裁剪画出去（Popover 内容溢出面板）。布局：
    ///   [self][clip_open][regular][sticky][overlay][clip_close][tail]
    /// 按 band 的访问器（descendant-scoped 逐段替放）跳过这两段，那条路径
    /// 由 paint pass fresh 发射同一对 token。
    descendant_clip_open_count: u32 = 0,
    descendant_clip_close_count: u32 = 0,
    regular_child_slices: []const ChildCommandSlice = &.{},
    content_version: u32 = 0,
    composite_version: u32 = 0,
    promoted_layer_id: u32 = std.math.maxInt(u32),
    /// 写缓存帧的 property-tree 序号（transform/effect chain 根）。缓存内每条
    /// DisplayItem 的 header id 都是**写入帧**的帧内序号；替放前必须比对根 id
    /// 未平移（全局遍历结构未变），否则 stale id 会索引到错误/越界的 property
    /// tree 节点。旧实现靠 plan ordinal layer id 的偶然 mismatch 提供这层保护，
    /// retained stable_id 化后在此显式恢复。
    cached_transform_id: u32 = std.math.maxInt(u32),
    cached_effect_id: u32 = std.math.maxInt(u32),
    /// subtree_payload 缓存（单点脏帧放大器修复）额外 stamp：写入帧的
    /// clip 链根 id。与 transform/effect 同理，帧内序号平移即 MISS。
    cached_clip_id: u32 = std.math.maxInt(u32),
    // 下游回归注：根 id 三元组只守卫缓存根自身；子树**内部**的帧内序号平移
    // （effect/clip 条件分配 + 更早节点动画期分配集合变化）不靠 stamp 拦截，
    // 而是替放时按 node_id 统一改写为本帧值，见 render_engine
    // rewriteSplicedItemHeaders。
    /// promoted 缓存里的 begin_blur token **按值烘焙**了写入帧的 glass 参数，
    /// 而 ext.glass 的写入不 bump content_version，dirty 位又会被祖先的
    /// subtree replay 提前 markNodeSubtreeRenderedClean 消费（帧内两个缓存层
    /// 抢一个 dirty 位），GlassBox interactive hover 的参数插值因此在真机上
    /// 完全冻结（RPC 截图路径反而看不出来）。stamp 写入帧的 glass 参数哈希，
    /// 参数变 -> MISS 重录。maxInt = 无 glass。
    cached_glass_hash: u64 = std.math.maxInt(u64),
    world_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    world_transform: Transform2D = .{},
    allocator: Allocator,

    pub fn selfCommands(self: *const CachedRenderSlice) []const DisplayItem {
        const count = @min(@as(usize, self.self_content_command_count), self.commands.len);
        return self.commands[0..count];
    }

    fn regularBandStart(self: *const CachedRenderSlice) usize {
        return @as(usize, self.self_content_command_count) + self.descendant_clip_open_count;
    }

    pub fn descendantRegularCommands(self: *const CachedRenderSlice) []const DisplayItem {
        const start = @min(self.regularBandStart(), self.commands.len);
        const count = @min(@as(usize, self.descendant_regular_command_count), self.commands.len - start);
        return self.commands[start .. start + count];
    }

    pub fn descendantStickyCommands(self: *const CachedRenderSlice) []const DisplayItem {
        const start = @min(self.regularBandStart() + self.descendant_regular_command_count, self.commands.len);
        const count = @min(@as(usize, self.descendant_sticky_command_count), self.commands.len - start);
        return self.commands[start .. start + count];
    }

    pub fn descendantOverlayCommands(self: *const CachedRenderSlice) []const DisplayItem {
        const start = @min(
            self.regularBandStart() + self.descendant_regular_command_count + self.descendant_sticky_command_count,
            self.commands.len,
        );
        const count = @min(@as(usize, self.descendant_overlay_command_count), self.commands.len - start);
        return self.commands[start .. start + count];
    }

    pub fn descendantTailCommands(self: *const CachedRenderSlice) []const DisplayItem {
        const start = @min(
            self.regularBandStart() + self.descendant_regular_command_count + self.descendant_sticky_command_count + self.descendant_overlay_command_count + self.descendant_clip_close_count,
            self.commands.len,
        );
        const count = @min(@as(usize, self.descendant_tail_command_count), self.commands.len - start);
        return self.commands[start .. start + count];
    }

    pub fn regularChildCommands(self: *const CachedRenderSlice, child_id: u32) ?[]const DisplayItem {
        var start = self.regularBandStart();
        for (self.regular_child_slices) |slice| {
            const count = @min(@as(usize, slice.command_count), self.commands.len - @min(start, self.commands.len));
            if (slice.child_id == child_id) {
                const bounded_start = @min(start, self.commands.len);
                return self.commands[bounded_start .. bounded_start + count];
            }
            start += count;
        }
        return null;
    }

    pub fn deinit(self: *CachedRenderSlice) void {
        freeDuplicatedDisplayItems(self.allocator, self.commands);
        if (self.regular_child_slices.len > 0) self.allocator.free(self.regular_child_slices);
    }
};

fn duplicateDisplayItem(allocator: Allocator, source: DisplayItem) !DisplayItem {
    var out = source;
    switch (out) {
        .text_run => |*text| {
            const source_text = source.text_run;
            text.content = "";
            text.spans = null;
            errdefer {
                if (text.content.len > 0) allocator.free(text.content);
                if (text.spans) |spans| if (spans.len > 0) allocator.free(spans);
            }
            if (source_text.content.len > 0) {
                text.content = try allocator.dupe(u8, source_text.content);
            }
            if (source_text.spans) |spans| {
                if (spans.len > 0) text.spans = try allocator.dupe(types.TextSpan, spans);
            }
        },
        .fill_path => |*path| path.geometry = try duplicatePathGeometry(allocator, source.fill_path.geometry),
        .stroke_path => |*path| path.geometry = try duplicatePathGeometry(allocator, source.stroke_path.geometry),
        else => {},
    }
    return out;
}

fn duplicatePathGeometry(allocator: Allocator, source: *const types.PathGeometry) !*const types.PathGeometry {
    const clone = try allocator.create(types.PathGeometry);
    errdefer allocator.destroy(clone);
    clone.* = source.*;
    clone.commands = &.{};
    if (source.commands.len > 0) clone.commands = try allocator.dupe(types.PathCommand, source.commands);
    clone.owned = true;
    return clone;
}

fn freeDuplicatedDisplayItem(allocator: Allocator, item: *DisplayItem) void {
    switch (item.*) {
        .text_run => |*text| {
            if (text.content.len > 0) allocator.free(text.content);
            if (text.spans) |spans| if (spans.len > 0) allocator.free(spans);
        },
        .fill_path => |*path| freeDuplicatedPathGeometry(allocator, path.geometry),
        .stroke_path => |*path| freeDuplicatedPathGeometry(allocator, path.geometry),
        else => {},
    }
}

fn freeDuplicatedPathGeometry(allocator: Allocator, geometry: *const types.PathGeometry) void {
    if (geometry.commands.len > 0) allocator.free(geometry.commands);
    allocator.destroy(@constCast(geometry));
}

/// Deep-copy a slice of display items. Pointer-backed text and path payloads
/// are duplicated so the cache survives the per-frame arena reset. On error
/// mid-copy, all already-duplicated allocations are freed before returning.
pub fn duplicateDisplayItems(allocator: Allocator, items: []const DisplayItem) ![]DisplayItem {
    const duped = try allocator.alloc(DisplayItem, items.len);
    var initialized: usize = 0;
    errdefer {
        for (duped[0..initialized]) |*item| freeDuplicatedDisplayItem(allocator, item);
        allocator.free(duped);
    }

    for (items) |item| {
        duped[initialized] = try duplicateDisplayItem(allocator, item);
        initialized += 1;
    }

    return duped;
}

/// Free a slice produced by `duplicateDisplayItems`, including any
/// heap-allocated pointer payloads.
pub fn freeDuplicatedDisplayItems(allocator: Allocator, items: []DisplayItem) void {
    for (items) |*item| freeDuplicatedDisplayItem(allocator, item);
    allocator.free(items);
}
