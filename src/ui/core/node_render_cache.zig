//! node_render_cache: render cache domain split out of node.zig (6 methods + TextHashSnapshot
//! type).
//!
//! Pattern: Node-typed free functions + @import("node.zig") circular import; node.zig keeps thin
//! delegates (original pub/private visibility). buildCachedRenderSlice is a module-level free fn.
//! node.zig re-exports TextHashSnapshot (e.g., text_item_render.zig uses
//! node.Node.TextHashSnapshot).
//!
//! Source of truth = self.meta.per_frame.caches.commands.{own,promoted} / .text_hash;
//! this module only handles build/invalidate/hash logic.

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

/// Cache render command slice (deep-copy text content/spans to avoid dangling pointers).
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
        if (self.world_ref) |w| w.render_cache_allocator orelse allocator else allocator,
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
        if (self.world_ref) |w| w.render_cache_allocator orelse allocator else allocator,
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

/// Release cached render commands.
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

/// Write the cross-frame display payload cache for a clean, non-promoted subtree.
/// commands must be materialized (text_run blob refs broken; content points to frame bytes;
/// buildCachedRenderSlice -> duplicateDisplayItems deep-copies content/spans).
/// stamp = frame-local transform/effect/clip chain root id + world bounds size.
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
        if (self.world_ref) |w| w.render_cache_allocator orelse allocator else allocator,
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

/// Write the cross-frame own-content cache (same materialization contract as
/// cacheSubtreePayloadCommands; every item belongs to this node).
pub fn cacheOwnPayloadCommands(
    self: *Node,
    allocator: Allocator,
    commands: []const DisplayItem,
    transform_id: u32,
    effect_id: u32,
    clip_id: u32,
    world_bounds: ComputedRect,
) ?*CachedRenderSlice {
    const cache_allocator = if (self.world_ref) |w| w.render_cache_allocator orelse allocator else allocator;
    // A node without own paint (pure layout box) is cached as "empty" so it is not
    // re-recorded either.
    var fresh = if (commands.len == 0) CachedRenderSlice{
        .commands = &.{},
        .scroll_offset_x = 0,
        .scroll_offset_y = 0,
        .content_version = self.meta.per_frame.caches.versions.content,
        .composite_version = self.meta.per_frame.caches.versions.composite,
        .world_bounds = world_bounds,
        .allocator = cache_allocator,
    } else buildCachedRenderSlice(
        cache_allocator,
        commands,
        0,
        0,
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
        world_bounds,
        Transform2D{},
    ) orelse {
        invalidateOwnPayloadCache(self);
        return null;
    };
    fresh.cached_transform_id = transform_id;
    fresh.cached_effect_id = effect_id;
    fresh.cached_clip_id = clip_id;
    invalidateOwnPayloadCache(self);
    self.meta.per_frame.caches.commands.own_payload = fresh;
    return &self.meta.per_frame.caches.commands.own_payload.?;
}

/// Dirty bits about to be cleared on a node that is not rendered this frame (hidden / zero-size /
/// paint-skipped subtree): its cross-frame command caches no longer match its state. Clean nodes
/// keep their caches.
pub fn dropCachesForUnrenderedClean(self: *Node) void {
    const d = self.frame_state.state_bits.dirty;
    if (!(d.core.render or d.core.subtree_render or d.core.layout or d.core.subtree_layout or
        d.pipeline.composite or d.pipeline.subtree_composite)) return;
    invalidateSubtreePayloadCache(self);
    invalidateOwnPayloadCache(self);
    invalidateRenderCache(self);
    invalidatePromotedRenderCache(self);
    @import("render_engine/retained_memo.zig").dropMemo(self);
}

pub fn invalidateOwnPayloadCache(self: *Node) void {
    if (self.meta.per_frame.caches.commands.own_payload) |*cache| {
        cache.deinit();
        self.meta.per_frame.caches.commands.own_payload = null;
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

/// Invalidate text hash cache; must call on every text content write.
///
/// Cache key is (content_version, content_ptr, content_len, spans_ptr, spans_len), but
/// `Node.setText` **does not bump** content_version (it only forwards to World.content and doesn't
/// touch per_frame.caches). A same-length text swap can leave the key unchanged:
///   - len same ("3 × 4" -> "3 × 5" both 6 bytes; the multiplication sign U+00D7 is 2 bytes in
///     UTF-8);
///   - ptr same (a freed owned buffer is often reused for the new dupe; in-place caller
///     buffer writes keep the address);
///   - version same (setText doesn't bump; caller may not markRenderDirty before this read).
/// A hit returns the old hash and shows **stale** text: blob fingerprint, paint chunk content_hash
/// and retained layer fingerprint all judge "content unchanged" and skip re-record. Most visible
/// with fallback fonts: text split by font ("3 x 4" = ['3 ']['x'][' ']['4']) updates only the
/// changed segment; others keep old glyphs.
///
/// Invalidate in the write path (not relying on callers to markRenderDirty): the cache input is
/// content/spans themselves, so whoever changes them must invalidate.
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
