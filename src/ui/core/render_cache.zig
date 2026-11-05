//! Cached display item slices used by overflow-hidden subtrees and display-list replay. Each `Node`
//! owns at most one `CachedRenderSlice`; the helpers here deep-copy display items (notably text
//! content / spans) so the cache can outlive the per-frame arena.
//!
//! Cache IR is DisplayItem. Index baseline = cx.display_list.items.items.len.
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
    /// Node's own overflow clip wrapper tokens (node-local push_clip / pop_clip, see render_engine
    /// emitScrollClipBegin). They don't belong to any child, but full-block replacement (promoted
    /// cache hit) must include them; otherwise frames with cached children render unclipped
    /// (Popover content overflows panel). Layout:
    ///  [self][clip_open][regular][sticky][overlay][clip_close][tail]
    /// Band accessors (descendant-scoped segment replacement) skip these two segments; that path's
    /// fresh emit generates the same pair of tokens.
    descendant_clip_open_count: u32 = 0,
    descendant_clip_close_count: u32 = 0,
    regular_child_slices: []const ChildCommandSlice = &.{},
    content_version: u32 = 0,
    composite_version: u32 = 0,
    promoted_layer_id: u32 = std.math.maxInt(u32),
    /// Write the property-tree sequence number of the cache-frame (transform/effect chain root).
    /// Every DisplayItem header id in the cache is a frame-local sequence number of the
    /// write-frame; before replacement, compare root id with no shift (global traverse structure
    /// unchanged), or stale id will index wrong/out-of-bounds property tree nodes. Old
    /// implementation relied on accidental mismatch of plan ordinal layer id for this protection;
    /// after retained stable_id conversion, restored explicitly here.
    cached_transform_id: u32 = std.math.maxInt(u32),
    cached_effect_id: u32 = std.math.maxInt(u32),
    /// subtree_payload cache (single-dirty-frame amplifier fix) extra stamp: clip chain root id of
    /// the write-frame. Same logic as transform/effect: frame-local sequence shift = MISS.
    cached_clip_id: u32 = std.math.maxInt(u32),
    // Regression note: root id triple guards only the cache root itself; frame-local sequence
    // shifts inside the subtree (effect/clip conditional allocation + earlier node animation period
    // allocation set changes) are not intercepted by stamp, but rewritten uniformly during
    // replacement by node_id to this frame's value; see render_engine rewriteSplicedItemHeaders.
    /// promoted cache begin_blur token has glass parameters of the write-frame baked in by value,
    /// but ext.glass writes do not bump content_version, and the dirty bit gets consumed early by
    /// ancestor subtree replay markNodeSubtreeRenderedClean (two cache layers contend for one dirty
    /// bit); GlassBox interactive hover parameter interpolation thus freezes entirely on real
    /// hardware (RPC screenshot path shows no issue). Stamp captures the write-frame glass
    /// parameter hash; parameter change -> MISS and re-record. maxInt = no glass.
    cached_glass_hash: u64 = std.math.maxInt(u64),
    /// subtree_payload stamp: the cache root's linear-text (stable raster) state at write time.
    /// text_run items bake their raster policy; the state is inherited from ancestors
    /// (`text_stabilize_subtree`, e.g. ScrollArea toggles it on its content during bounce)
    /// and flipping it marks no descendant dirty.
    cached_force_linear_text: bool = false,
    /// subtree_payload / own_payload stamp: which property-tree nodes the cache root **owns**
    /// (its own effect and its kind, its own clip), see render_engine ownerSignature. Replaces
    /// comparing the root's frame-local transform/effect/clip sequence ids, which shift whenever
    /// anything painted earlier allocates one more or one fewer node (a list row rebinding at the
    /// top missed every cache below it each frame). Item headers are rewritten to this frame's ids
    /// by appendCachedCommands either way; what must be detected is the root gaining or losing
    /// its own effect / clip scope.
    cached_owner_signature: u32 = std.math.maxInt(u32),
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
        .begin_blur_layer => |*blur| {
            const glass = try allocator.create(@TypeOf(blur.glass.*));
            glass.* = source.begin_blur_layer.glass.*;
            blur.glass = glass;
        },
        .push_clip => |*clip| clip.polygon = try duplicatePolygon(allocator, source.push_clip.polygon),
        .border_side => |*border| border.clip_polygon = try duplicatePolygon(allocator, source.border_side.clip_polygon),
        else => {},
    }
    return out;
}

fn duplicatePolygon(allocator: Allocator, source: anytype) !@TypeOf(source) {
    const p = source orelse return null;
    const clone = try allocator.create(@TypeOf(p.*));
    clone.* = p.*;
    return clone;
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
        .begin_blur_layer => |*blur| allocator.destroy(@constCast(blur.glass)),
        .push_clip => |*clip| if (clip.polygon) |p| allocator.destroy(@constCast(p)),
        .border_side => |*border| if (border.clip_polygon) |p| allocator.destroy(@constCast(p)),
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
