//! node_tree: tree-structure subdomain extracted from node.zig (7 methods +
//! structure callback unit). Node-typed free functions + @import("node.zig") cyclic
//! import; node.zig keeps thin delegates (original pub/private visibility).
//! appendChild/removeChild call dirty / lifecycle.fireCleanupCallbacks /
//! interaction.markCustomDrawSubtree. The structure callback unit (StructureKind /
//! StructureNotifyFn / g_structure_notify / setStructureNotifyCallback) lives here;
//! node.zig re-exports it to keep the public API (core.zig calls
//! setStructureNotifyCallback).

const std = @import("std");
const node_interaction_untrusted = @import("node_interaction.zig");
const world_mod = @import("world.zig");
const node_mod = @import("node.zig");

const Node = node_mod.Node;
const Allocator = std.mem.Allocator;

/// Diagnostic renderer seam. Production builds erase the fields and every call.
/// Subscribe before creating nodes; callbacks may copy patches but MUST NOT mutate
/// nodes or subscriptions. This is a forest protocol, independent of Cx.root:
/// detached retained nodes and rootless overlays stay alive until destroy.
pub const host_enabled = @import("builtin").is_test or @import("zenit_environment").dev_preview;
pub const HostId = u64;
pub const HostPatch = union(enum) {
    create: struct { id: HostId, world: u16, element: u32, tag: @import("types.zig").ElementTag, node: *const Node },
    /// Move an existing child, inserting before anchor (null means append).
    /// Covers first insert, reparent and reorder without changing identity.
    place: struct { id: HostId, parent: HostId, before: ?HostId },
    retained_remove: HostId,
    destroy: HostId,
    dirty: HostId,
};
pub const Host = struct {
    context: *anyopaque,
    patch: *const fn (*anyopaque, HostPatch) void,
    next: ?*Host = null,

    pub fn attach(self: *Host) void {
        if (comptime !host_enabled) return;
        if (host_notifying) @panic("renderer host callback reentry");
        var current = hosts;
        while (current) |h| : (current = h.next) {
            if (h == self) @panic("renderer host already attached");
        }
        self.next = hosts;
        hosts = self;
    }
    pub fn detach(self: *Host) void {
        if (comptime !host_enabled) return;
        if (host_notifying) @panic("renderer host callback reentry");
        var link = &hosts;
        while (link.*) |h| {
            if (h == self) {
                link.* = h.next;
                self.next = null;
                return;
            }
            link = &h.next;
        }
    }
};
var hosts: ?*Host = null;
var host_notifying = false;
var host_generation: HostId = 0;

fn publishHost(patch: HostPatch) void {
    if (comptime !host_enabled) return;
    if (host_notifying) @panic("renderer host callback reentry");
    host_notifying = true;
    defer host_notifying = false;
    var current = hosts;
    while (current) |h| : (current = h.next) h.patch(h.context, patch);
}

pub inline fn hostCreated(node: *Node) void {
    if (comptime !host_enabled) return;
    // A process-lifetime generation, independent of pointer/ElementId/u8 reuse.
    // Never wrap: a stale patch must never address a new node, even after 256 frees.
    host_generation = std.math.add(HostId, host_generation, 1) catch @panic("renderer host identity exhausted");
    node.host_id = host_generation;
    publishHost(.{ .create = .{ .id = node.host_id, .world = node.world_id, .element = node.element_id_raw, .tag = node.tag, .node = node } });
}
/// Advances on every node mutation that reaches the host channel: every dirty mark (all
/// node_dirty mark functions start with hostDirty), placement and retained removal. Event-time
/// hit refreshes compare it with its value at the last before-render tick: with no mutation since,
/// re-running the tick at the same frame time cannot change the scene (cx_render.ensureHitTestSceneFresh).
pub var g_scene_mutation_gen: u64 = 0;

/// Advances whenever a node starts retiring (Node.pending_free_cx set) or
/// freeing (Node.freeing set). A traversal that saw no advance since it began
/// knows every node on its stack still passes the check it made on entry
/// (render_engine/tick.zig isRetiring).
pub var g_retire_gen: u64 = 0;

pub inline fn hostDestroyed(node: *const Node) void {
    g_scene_mutation_gen +%= 1;
    if (comptime !host_enabled) return;
    publishHost(.{ .destroy = node.host_id });
}
pub inline fn hostDirty(node: *const Node) void {
    g_scene_mutation_gen +%= 1;
    if (comptime !host_enabled) return;
    if (node.freeing) return;
    publishHost(.{ .dirty = node.host_id });
}
fn hostPlaced(parent: *const Node, child: *const Node, before: ?*const Node) void {
    g_scene_mutation_gen +%= 1;
    if (comptime !host_enabled) return;
    publishHost(.{ .place = .{ .id = child.host_id, .parent = parent.host_id, .before = if (before) |b| b.host_id else null } });
}
fn hostRetained(child: *const Node) void {
    g_scene_mutation_gen +%= 1;
    if (comptime !host_enabled) return;
    publishHost(.{ .retained_remove = child.host_id });
}

// ---------------------------------------------------------------------------
// Structure callback unit (moved wholesale from node.zig)
// appendChild/removeChild syncs parent-child links to World.elements.
// ---------------------------------------------------------------------------

pub const StructureKind = enum(u8) { append, unlink };
pub const StructureNotifyFn = *const fn (parent_raw: u32, child_raw: u32, kind: StructureKind) void;
var g_structure_notify: ?StructureNotifyFn = null;

// UI tree operations are serialized, as are the existing structure/dirty hooks.
// A callback can reorder a list without changing its length or the current slot;
// an epoch detects those changes without allocating a snapshot or growing Node.
var g_structure_revision: u64 = 0;
pub fn structureRevision() u64 {
    return g_structure_revision;
}

/// Sync one parent-child chain change to the node's owner World's elements table.
///
/// Prefers the direct `world_ref`; null (cx-less mock) falls back to the global
/// callback. Includes reparent pre-unlink (when child has a parent, it must be
/// unlinked first or the sibling chain corrupts).
fn syncWorldStructure(parent: anytype, child: anytype, kind: StructureKind) void {
    if (parent.element_id_raw == 0xFFFFFFFF or child.element_id_raw == 0xFFFFFFFF) return;
    // Use parent's owner; after append child belongs to parent's World.
    if (parent.world_ref) |w| {
        const parent_eid = world_mod.ElementId.fromRaw(parent.element_id_raw);
        const child_eid = world_mod.ElementId.fromRaw(child.element_id_raw);
        if (!w.elements.isValid(parent_eid) or !w.elements.isValid(child_eid)) return;
        switch (kind) {
            .append => {
                // Reparent scenario: when child has parent, unlink first or chain corrupts.
                const existing = w.elements.links(child_eid) orelse return;
                if (!existing.parent.isNull()) w.elements.unlink(child_eid);
                w.elements.appendChild(parent_eid, child_eid);
            },
            .unlink => w.elements.unlink(child_eid),
        }
        return;
    }
    if (g_structure_notify) |notify| {
        notify(parent.element_id_raw, child.element_id_raw, kind);
    }
}

pub fn setStructureNotifyCallback(notify: ?StructureNotifyFn) void {
    g_structure_notify = notify;
}

// ---------------------------------------------------------------------------
// Tree structure methods
// ---------------------------------------------------------------------------

/// Walk parent chain upward; self is descendent of ancestor (including self)
/// return true.
pub fn isDescendantOf(self: *Node, ancestor: *Node) bool {
    var current: ?*Node = self;
    while (current) |n| {
        if (n == ancestor) return true;
        current = n.parent;
    }
    return false;
}

fn validateChild(parent: *Node, child: *Node) !void {
    if (parent.isDescendantOf(child)) return error.CyclicNodeTree;
    if (parent.world_ref != null and child.world_ref != null and parent.world_ref != child.world_ref)
        return error.CrossWorldNode;
    if (child.parent) |old_parent| {
        if (std.mem.indexOfScalar(*Node, old_parent.children.items, child) == null)
            return error.InvalidChildParent;
    }
}

pub fn appendChild(self: *Node, allocator: Allocator, child: *Node) !void {
    try validateChild(self, child);
    if (child.parent == self) {
        if (self.children.items[self.children.items.len - 1] == child) return;
    } else {
        // No parent links, dirty flags or World links change before allocation.
        try self.children.ensureUnusedCapacity(allocator, 1);
    }
    if (child.parent) |old_parent| old_parent.removeChildRetained(child);
    self.children.appendAssumeCapacity(child);
    g_structure_revision +%= 1;
    child.parent = self;
    // Child has custom_draw -> bubble mark.
    if (child.frame_state.state_bits.flags.has_custom_draw_subtree) {
        self.markCustomDrawSubtree();
    }
    // Child text / before_render flags merge to parent chain (same maintenance as
    // has_custom_draw_subtree).
    if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
    if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
    if (child.frame_state.state_bits.flags.has_untrusted_before_render_subtree) node_interaction_untrusted.markSubtreeUntrustedBeforeRenderHook(self);
    child.frame_state.state_bits.dirty.runtime.dirty = true;
    child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
    child.frame_state.state_bits.dirty.runtime.full_rebuild = false;
    child.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
    self.bubbleChildRuntimeIndexDirty(false);
    self.markLayoutDirty();
    // P0-3 phase 3: sync parent-child chain directly to owner World; no more
    // process-level callback.
    syncWorldStructure(self, child, .append);
    hostPlaced(self, child, null);
}

/// Insert child before anchor; null anchor is equivalent to appendChild. Anchor
/// must be a direct child of self; otherwise error.InvalidAnchor (no silent append:
/// control flow uses anchor position; an anchor not in parent means the caller's
/// region bookkeeping is already broken). A child already under self is moved
/// (unlink then insert), consistent with appendChild's reparent semantics.
pub fn insertChildBefore(self: *Node, allocator: Allocator, child: *Node, before: ?*Node) !void {
    const anchor = before orelse return appendChild(self, allocator, child);
    if (anchor == child) return;
    if (anchor.parent != self) return error.InvalidAnchor;
    try validateChild(self, child);
    if (child.parent != self) {
        // No parent links, dirty flags or World links change before allocation.
        try self.children.ensureUnusedCapacity(allocator, 1);
    }
    if (child.parent) |old_parent| old_parent.removeChildRetained(child);
    // Reposition after unlink: when child was under self and before anchor, index
    // shifts down.
    const index = std.mem.indexOfScalar(*Node, self.children.items, anchor) orelse unreachable;
    self.children.insertAssumeCapacity(index, child);
    g_structure_revision +%= 1;
    child.parent = self;
    if (child.frame_state.state_bits.flags.has_custom_draw_subtree) self.markCustomDrawSubtree();
    if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
    if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
    if (child.frame_state.state_bits.flags.has_untrusted_before_render_subtree) node_interaction_untrusted.markSubtreeUntrustedBeforeRenderHook(self);
    child.frame_state.state_bits.dirty.runtime.dirty = true;
    child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
    child.frame_state.state_bits.dirty.runtime.full_rebuild = false;
    child.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
    self.bubbleChildRuntimeIndexDirty(false);
    self.markOrderDirty();
    self.markLayoutDirty();
    syncWorldInsertBefore(self, child, anchor, index);
    hostPlaced(self, child, anchor);
}

/// World sync for insertChildBefore. O(1) linked-list insert with world_ref;
/// cx-less old path's global callback only has append/unlink; relink successors one
/// by one, matches Node.children order (only mock tests hit this).
fn syncWorldInsertBefore(self: *Node, child: *Node, anchor: *Node, index: usize) void {
    if (self.element_id_raw == 0xFFFFFFFF or child.element_id_raw == 0xFFFFFFFF) return;
    if (self.world_ref) |w| fast: {
        // Anchor not in World table (old-path node) has no insertable list position;
        // fall through to bulk relink below.
        if (anchor.element_id_raw == 0xFFFFFFFF) break :fast;
        const parent_eid = world_mod.ElementId.fromRaw(self.element_id_raw);
        const child_eid = world_mod.ElementId.fromRaw(child.element_id_raw);
        const before_eid = world_mod.ElementId.fromRaw(anchor.element_id_raw);
        if (!w.elements.isValid(parent_eid) or !w.elements.isValid(child_eid)) return;
        if (!w.elements.isValid(before_eid)) break :fast;
        // Anchor's parent in World differs from Node tree (tables diverged); table-layer
        // insertBefore degrades to append, leaving silent order split; switch to bulk
        // relink using children as source to rewrite order suffix.
        const before_links = w.elements.links(before_eid) orelse break :fast;
        if (!before_links.parent.eql(parent_eid)) break :fast;
        const existing = w.elements.links(child_eid) orelse return;
        if (!existing.parent.isNull()) w.elements.unlink(child_eid);
        w.elements.insertBefore(parent_eid, child_eid, before_eid);
        return;
    }
    for (self.children.items[index..]) |sib| syncWorldStructure(self, sib, .unlink);
    for (self.children.items[index..]) |sib| syncWorldStructure(self, sib, .append);
}

/// Reorder children using existing node pointers. No create/destroy, no runtime
/// registry rebuild; only marks order/layout dirty. The World.elements sibling list
/// must be synced on reorder (appendChild/removeChild* both sync). The render path
/// reads Node.children today, but the migration target is the World list; a silent
/// split between the two tables would corrupt render order.
pub fn replaceChildOrder(self: *Node, allocator: Allocator, ordered_children: []const *Node) !void {
    if (std.mem.eql(*Node, self.children.items, ordered_children)) return;

    // Callers may pass a slice of self.children. Snapshot before any capacity
    // change or write, and reject duplicates before publishing either tree.
    const order = try allocator.dupe(*Node, ordered_children);
    defer allocator.free(order);
    var seen: std.AutoHashMapUnmanaged(*Node, void) = .{};
    defer seen.deinit(allocator);
    var membership_changed = order.len != self.children.items.len;
    for (order) |child| {
        try validateChild(self, child);
        const entry = try seen.getOrPut(allocator, child);
        if (entry.found_existing) return error.DuplicateChild;
        membership_changed = membership_changed or child.parent != self;
    }
    try self.children.ensureTotalCapacity(allocator, order.len);

    // Retain omitted nodes and their resources, matching removeChildRetained.
    // Ownership stays with the caller; this operation never runs cleanup.
    for (self.children.items) |child| {
        syncWorldStructure(self, child, .unlink);
        child.parent = null;
        hostRetained(child);
    }
    self.children.clearRetainingCapacity();
    g_structure_revision +%= 1;
    for (order) |child| {
        if (child.parent) |old_parent| old_parent.removeChildRetained(child);
        self.children.appendAssumeCapacity(child);
        child.parent = self;
        if (child.frame_state.state_bits.flags.has_custom_draw_subtree) self.markCustomDrawSubtree();
        if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
        if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
        if (child.frame_state.state_bits.flags.has_untrusted_before_render_subtree) node_interaction_untrusted.markSubtreeUntrustedBeforeRenderHook(self);
        if (membership_changed) {
            child.frame_state.state_bits.dirty.runtime.dirty = true;
            child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
        }
        syncWorldStructure(self, child, .append);
        hostPlaced(self, child, null);
    }
    if (membership_changed) self.markRuntimeIndexDirty();
    self.markOrderDirty();
    self.markLayoutDirty();
}

/// Remove child from parent, recursively fire onCleanup. Note: doesn't free child
/// memory; caller must manually `cx.freeNode(child)`. on_cleanup is one-shot
/// (fires and detaches); reattaching same node goes through removeChildRetained
/// which doesn't fire or consume cleanup.
pub fn removeChild(self: *Node, child: *Node) void {
    removeChildInternal(self, child, true);
}

pub fn removeChildIncremental(self: *Node, child: *Node) void {
    removeChildInternal(self, child, false);
}

pub fn removeChildRetained(self: *Node, child: *Node) void {
    removeChildRetainedInternal(self, child, false);
}

fn removeChildInternal(self: *Node, child: *Node, full_runtime_rebuild: bool) void {
    if (child.parent != self or std.mem.indexOfScalar(*Node, self.children.items, child) == null) return;
    node_mod.fireCleanupCallbacks(child);
    removeChildRetainedInternal(self, child, full_runtime_rebuild);
}

fn removeChildRetainedInternal(self: *Node, child: *Node, full_runtime_rebuild: bool) void {
    if (child.parent != self) return;
    const index = std.mem.indexOfScalar(*Node, self.children.items, child) orelse return;
    _ = self.children.orderedRemove(index);
    g_structure_revision +%= 1;
    if (full_runtime_rebuild) {
        self.markRuntimeIndexFullRebuild();
    }
    child.parent = null;
    self.markLayoutDirty();
    // P0-3 phase 3: same as above, direct owner World.
    syncWorldStructure(self, child, .unlink);
    hostRetained(child);
}

/// Remove all children, recursively fire onCleanup. Note: doesn't free memory;
/// caller must manually `cx.freeNode()` each child.
pub fn removeAllChildren(self: *Node) void {
    // Cleanup callbacks may synchronously detach/reparent children. Never keep
    // an iterator over the old ArrayList slice across those callbacks: removal
    // shifts entries and poisons the vacated tail in Debug builds.
    while (self.children.items.len > 0) {
        removeChildInternal(self, self.children.items[0], false);
    }
    self.markRuntimeIndexDirty();
    self.markLayoutDirty();
}
