//! World: unified root container for retained cross-frame state, indexed by ElementId.
//!
//! Consolidates what Cx owned separately (lowering_buffer, display_list, scene_runtime,
//! property_tree, compositor_plan): 4 tables + property tree + reactive graph + dirty set.
//!
//! World is the new source of truth, but Cx still keeps old Node paths (4 examples unmounted).
//! Planned migration:
//!   - paint pass rewrites PaintTable
//!   - layout pass rewrites LayoutTable
//!   - old Node fields become World views (getter/setter delegates)
//!
//! Design rules:
//! - no member holds a 'parent World pointer'; pass *World to operations to avoid retain cycles
//! - dirty set is the 'global dirty queue'; subsystems only push to it, no recursive push

const std = @import("std");
const id_hash = @import("id_hash.zig");
const builtin = @import("builtin");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const element_table_mod = @import("element_table.zig");
const layout_table_mod = @import("layout_table.zig");
const paint_table_mod = @import("paint_table.zig");
const interaction_table_mod = @import("interaction_table.zig");
const dirty_flags_mod = @import("dirty_flags.zig");
const content_table_mod = @import("content_table.zig");
const paint_state_table_mod = @import("paint_state_table.zig");
const layout_output_table_mod = @import("layout_output_table.zig");

// Note: World does not own ReactiveGraph. Reactive is state-side data; World is render-side data.
// They communicate via dirty_set: reactive effects call world.markDirty(id, flags); render pipeline
// consumes dirty_set after begin_frame. Decoupling avoids entanglement with reactive lifecycle at
// world.deinit,
// simplifies unit testing.

pub const ElementId = element_id_mod.ElementId;
pub const Element = element_table_mod.Element;
pub const ElementTable = element_table_mod.ElementTable;
pub const ElementTag = element_table_mod.ElementTag;
pub const LayoutTable = layout_table_mod.LayoutTable;
pub const PaintTable = paint_table_mod.PaintTable;
pub const InteractionTable = interaction_table_mod.InteractionTable;
pub const InteractionData = interaction_table_mod.InteractionData;
pub const DirtyFlags = dirty_flags_mod.DirtyFlags;
pub const ContentTable = content_table_mod.ContentTable;
pub const ContentData = content_table_mod.ContentData;
pub const PaintStateTable = paint_state_table_mod.PaintStateTable;
pub const PaintStateData = paint_state_table_mod.PaintStateData;
pub const LayoutOutputTable = layout_output_table_mod.LayoutOutputTable;

/// DevTools style source. Address points to:
/// - styled: named style function entry;
/// - inline_builder / set_style: return address near callsite.
///
/// Stores code address only, no DWARF parsing in hot path; symbolization by source_link
/// only when user clicks DevTools jump button. After stripping debug info in Release, parsing
/// gracefully degrades to empty.
pub const StyleOriginKind = enum(u8) {
    inline_builder,
    styled,
    set_style,
};

pub const StyleOrigin = struct {
    address: usize,
    kind: StyleOriginKind,
};

const NodeStyleOrigins = struct {
    /// Common source for boxStyled/textStyled or inline builder.
    base: ?StyleOrigin = null,
    /// Which StyleFields base actually declares; bit index = @intFromEnum(StyleField).
    base_fields: u64 = 0,
    /// Per-field last-writer override from setStyle. Empty (not allocated) for vast majority of
    /// nodes.
    field_overrides: std.AutoHashMapUnmanaged(u8, StyleOrigin) = .{},

    fn deinit(self: *NodeStyleOrigins, allocator: std.mem.Allocator) void {
        self.field_overrides.deinit(allocator);
        self.* = undefined;
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    /// Optional UI-thread ownership probe for retained node command payloads.
    render_cache_allocator: ?std.mem.Allocator = null,
    elements: ElementTable,
    layout: LayoutTable,
    paint: PaintTable,
    interaction: InteractionTable,
    /// NodeContent SoA mirror (double-write phase; becomes source of truth at stage 3)
    content: ContentTable,
    /// PaintState SoA mirror (background + opacity and other paint fields)
    paint_state: PaintStateTable,
    /// NodeLayoutOutput SoA mirror (vector + artifacts; double-write phase)
    layout_output: LayoutOutputTable,
    /// dirty set: pending this frame; consumed by stage at end_frame
    dirty_set: id_hash.U32HashMapUnmanaged(DirtyFlags),
    /// Monotonic notification serial, including repeated marks of an already dirty node.
    mutation_epoch: u64 = 0,
    /// DevTools-only sparse source table. Node body does not allocate for 50+ StyleFields;
    /// only styled / setStyle-modified nodes occupy an entry.
    style_origins: id_hash.U32HashMapUnmanaged(NodeStyleOrigins),
    /// Element ids of destroyed nodes are not reused while their entries go away.
    style_origin_removals: id_hash.TombstoneBudget = .{},

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .elements = ElementTable.init(allocator),
            .layout = LayoutTable.init(allocator),
            .paint = PaintTable.init(allocator),
            .interaction = InteractionTable.init(allocator),
            .content = ContentTable.init(allocator),
            .paint_state = PaintStateTable.init(allocator),
            .layout_output = LayoutOutputTable.init(allocator),
            .dirty_set = .{},
            .style_origins = .{},
        };
    }

    pub fn deinit(self: *World) void {
        var origin_it = self.style_origins.valueIterator();
        while (origin_it.next()) |origins| origins.deinit(self.allocator);
        self.style_origins.deinit(self.allocator);
        self.dirty_set.deinit(self.allocator);
        self.layout_output.deinit();
        self.paint_state.deinit();
        self.content.deinit();
        self.interaction.deinit();
        self.paint.deinit();
        self.layout.deinit();
        self.elements.deinit();
        self.* = undefined;
    }

    /// Create an element and synchronously allocate slots in layout/paint/content/paint_state
    /// tables.
    pub fn createElement(self: *World, e: Element) !ElementId {
        const id = try self.elements.create(e);
        errdefer self.destroyElement(id);
        try self.layout.ensureSlot(id);
        try self.paint.ensureSlot(id);
        try self.content.ensureSlot(id);
        try self.paint_state.ensureSlot(id);
        try self.layout_output.ensureSlot(id);
        // Element slot may be reused from free_list (generation++). Content mirror table is indexed
        // without generation checks; ensureSlot returns existing slots without clearing, so a
        // reused
        // slot keeps the previous owner's text and the new node's getText reads stale content (e.g.
        // Menu
        // items 'Cut/Copy/Delete' leaking into a new DatePicker trigger). destroyElement clears on
        // the
        // destroy side, but bare elements.destroy / Node.destroy bypass it, so alloc also clears
        // content.
        // ensureSlot preserves same-generation output and clears/reclaims a
        // reused generation before it can expose the previous owner's cache.
        self.content.clear(id);
        return id;
    }

    /// Destroy element and clear all dirty flags (non-recursive; caller decides subtree).
    pub fn destroyElement(self: *World, id: ElementId) void {
        if (!self.elements.isValid(id)) return;
        self.clearStyleOrigins(id.raw());
        self.elements.destroy(id);
        _ = self.interaction.remove(id);
        _ = self.dirty_set.remove(id.raw());
        self.content.clear(id);
        self.paint_state.clear(id);
        self.layout_output.clear(id); // table-owned sparse text payload is reclaimed
        self.layout.clear(id);
        // Paint chunk must clear content (free display_items + zero hash/epoch/property_state),
        // else slot reuse + hash collision causes beginRecord to emit old owner's items (see
        // release note).
        self.paint.release(id);
        // layout / paint slots not immediately recycled (keep dense by index; empty slots use
        // minimal memory).
    }

    /// Record common source for declarative/inline builder and which fields it actually set.
    /// DevTools is diagnostic; dropping one source on OOM won't drag down target app.
    pub fn recordStyleBase(self: *World, element_raw: u32, fields: u64, origin: StyleOrigin) void {
        if (builtin.strip_debug_info) return;
        if (element_raw == 0xFFFFFFFF or origin.address == 0 or fields == 0) return;
        const gop = self.style_origins.getOrPut(self.allocator, element_raw) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.base = origin;
        gop.value_ptr.base_fields = fields;
    }

    /// Record per-field last-writer from setStyle.
    pub fn recordStyleField(self: *World, element_raw: u32, field_index: u8, origin: StyleOrigin) void {
        if (builtin.strip_debug_info) return;
        if (element_raw == 0xFFFFFFFF or origin.address == 0) return;
        const gop = self.style_origins.getOrPut(self.allocator, element_raw) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.field_overrides.put(self.allocator, field_index, origin) catch {};
    }

    /// Check per-field overrides; fall back to base only if base actually declared the field.
    /// field_index=null for attributes like TextStyle.line_height not yet in StyleField.
    pub fn styleOrigin(self: *const World, element_raw: u32, field_index: ?u8) ?StyleOrigin {
        const origins = self.style_origins.get(element_raw) orelse return null;
        if (field_index) |index| {
            if (origins.field_overrides.get(index)) |origin| return origin;
            if (index >= 64) return null;
            if ((origins.base_fields & (@as(u64, 1) << @intCast(index))) == 0) return null;
        }
        return origins.base;
    }

    pub fn clearStyleOrigins(self: *World, element_raw: u32) void {
        const removed = self.style_origins.fetchRemove(element_raw) orelse return;
        var origins = removed.value;
        origins.deinit(self.allocator);
        if (self.style_origin_removals.noteRemoval(self.style_origins.count(), self.style_origins.capacity()))
            self.style_origins.rehash(id_hash.U32Context{});
    }

    /// Mark element dirty. Flags merged to existing entry via union.
    pub fn markDirty(self: *World, id: ElementId, flags: DirtyFlags) !void {
        if (id.isNull()) return;
        self.mutation_epoch +%= 1;
        const gop = try self.dirty_set.getOrPut(self.allocator, id.raw());
        if (!gop.found_existing) {
            gop.value_ptr.* = flags;
        } else {
            gop.value_ptr.input = gop.value_ptr.input.unionWith(flags.input);
            gop.value_ptr.output = gop.value_ptr.output.unionWith(flags.output);
            gop.value_ptr.subtree = gop.value_ptr.subtree.unionWith(flags.subtree);
        }
    }

    pub fn dirtyCount(self: *const World) usize {
        return self.dirty_set.count();
    }

    /// Frame start: clear dirty set (consumers processed it).
    /// PropertyTree.beginFrameRetained called by Cx.property_tree main path; World no longer holds
    /// copy
    /// (v0.5-P3 stage 1 dedup, 2026-04-30).
    pub fn beginFrame(self: *World) void {
        self.dirty_set.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "World: init/deinit" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.elements.count());
    try testing.expectEqual(@as(usize, 0), w.dirtyCount());
}

test "World: createElement allocates slots in all dense tables" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 1 });
    try testing.expect(w.elements.isValid(id));
    // layout / paint allocated
    try testing.expect(w.layout.get(id) != null);
    try testing.expect(w.paint.get(id) != null);
    // interaction is sparse, not auto-allocated
    try testing.expect(w.interaction.get(id) == null);
}

test "World: style origins use base declarations with per-field last-writer overrides" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const element_raw: u32 = 0x0100002A;
    const padding_index: u8 = 2;
    const gap_index: u8 = 7;
    w.recordStyleBase(element_raw, @as(u64, 1) << padding_index, .{
        .address = 0x1111,
        .kind = .styled,
    });

    try testing.expectEqual(@as(usize, 0x1111), w.styleOrigin(element_raw, padding_index).?.address);
    try testing.expect(w.styleOrigin(element_raw, gap_index) == null);

    w.recordStyleField(element_raw, gap_index, .{
        .address = 0x2222,
        .kind = .set_style,
    });
    const override = w.styleOrigin(element_raw, gap_index).?;
    try testing.expectEqual(@as(usize, 0x2222), override.address);
    try testing.expectEqual(StyleOriginKind.set_style, override.kind);

    w.clearStyleOrigins(element_raw);
    try testing.expect(w.styleOrigin(element_raw, padding_index) == null);
}

test "World: style origins of destroyed elements do not accumulate tombstones" {
    if (builtin.strip_debug_info) return error.SkipZigTest;
    var w = World.init(testing.allocator);
    defer w.deinit();
    for (1..301) |raw| w.recordStyleBase(@intCast(raw), 1, .{ .address = 0x1111, .kind = .styled });
    var next: u32 = 1000;
    for (0..200) |_| {
        const first = next;
        for (0..80) |_| {
            w.recordStyleBase(next, 1, .{ .address = 0x1111, .kind = .styled });
            next += 1;
        }
        for (first..next) |raw| {
            w.clearStyleOrigins(@intCast(raw));
            try id_hash.expectFewTombstones(&w.style_origins);
        }
    }
    try testing.expectEqual(@as(u32, 300), w.style_origins.count());
}

test "World: markDirty unions flags" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });

    try w.markDirty(id, .{ .input = .{ .style_changed = true } });
    try w.markDirty(id, .{ .input = .{ .geometry_changed = true } });

    const got = w.dirty_set.get(id.raw()).?;
    try testing.expect(got.input.style_changed);
    try testing.expect(got.input.geometry_changed);
}

test "World: destroyElement removes dirty entry + interaction" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    try w.interaction.put(id, .{ .tab_index = 5 });
    try w.markDirty(id, .{ .input = .{ .style_changed = true } });

    w.destroyElement(id);
    try testing.expect(w.interaction.get(id) == null);
    try testing.expect(w.dirty_set.get(id.raw()) == null);
}

test "World: destroyElement 清 paint chunk —— slot 复用 + hash 撞车不得吐旧显示项" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    // Record one display item (hash=42)
    try testing.expect(try w.paint.beginRecord(id, 42));
    try w.paint.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 } });
    w.paint.endRecord(id, .NONE);
    try testing.expectEqual(@as(usize, 1), w.paint.get(id).?.display_items.items.len);

    w.destroyElement(id);

    // Reuse same slot (LIFO free list), new owner's content_hash happens to collide with old value:
    // beginRecord must truly re-record (return true), cannot cache-hit and emit old owner's items
    const id2 = try w.createElement(.{ .tag = .container, .key = 1 });
    try testing.expectEqual(id.index, id2.index); // Precondition: slot is truly reused
    try testing.expect(try w.paint.beginRecord(id2, 42));
    try testing.expectEqual(@as(usize, 0), w.paint.get(id2).?.display_items.items.len);
    // property_state must also zero; full table scan consumes it by idx
    try testing.expectEqual(paint_table_mod.PropertyStateRef.NONE, w.paint.get(id2).?.property_state);
}

test "World: destroyElement clears LayoutTable before slot reuse" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    w.layout.markLaidOut(id, .{ .width = 80, .height = 40 }, .{ .x = 12, .y = 34, .width = 80, .height = 40 });
    try testing.expect(w.layout.epoch(id) != 0);
    w.destroyElement(id);

    const reused = try w.createElement(.{ .tag = .container, .key = 1 });
    try testing.expectEqual(id.index, reused.index);
    try testing.expectEqual(layout_table_mod.Rect.ZERO, w.layout.rect(reused).?);
    try testing.expectEqual(@as(u64, 0), w.layout.epoch(reused));
}

test "World: beginFrame clears dirty" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    try w.markDirty(id, .{ .input = .{ .style_changed = true } });
    try testing.expectEqual(@as(usize, 1), w.dirtyCount());

    w.beginFrame();
    try testing.expectEqual(@as(usize, 0), w.dirtyCount());
}

test "World: combined element creation + tree linking" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const root = try w.createElement(.{ .tag = .container, .key = 0 });
    const c1 = try w.createElement(.{ .tag = .text, .key = 1 });
    const c2 = try w.createElement(.{ .tag = .text, .key = 2 });

    w.elements.appendChild(root, c1);
    w.elements.appendChild(root, c2);

    try testing.expectEqual(@as(u32, 2), w.elements.childCount(root));
}
