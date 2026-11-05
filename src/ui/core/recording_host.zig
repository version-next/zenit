//! Diagnostic host, not a DOM backend. A sticky allocation error invalidates the
//! entire recording; flush/check never accept a truncated stream. No observer
//! allocation can change whether a native tree operation succeeds.
const std = @import("std");
const tree = @import("node_tree.zig");
const Node = @import("node.zig").Node;
const t = @import("types.zig");
const A = std.mem.Allocator;
const Id = tree.HostId;

/// Value-owned style snapshot: pointers into mutable StyleExt/GridConfig are
/// removed. Paint-state values are part of the final style, not pointer identity.
pub const StyleState = struct {
    tag: t.ElementTag,
    style: t.Style,
    ext: t.StyleExt,
    grid: ?t.GridConfig,
    background: t.Color,
    opacity: f32,

    pub fn read(node: *const Node) StyleState {
        var result: StyleState = .{
            .tag = node.tag,
            .style = node.style,
            .ext = node.style.getExt().*,
            .grid = null,
            .background = node.getBackground(),
            .opacity = node.getOpacity(),
        };
        result.style.ext = null;
        result.ext.grid = null;
        if (node.style.grid()) |g| {
            var copy = g.*;
            // Unused tracks are undefined in normal GridConfig construction.
            @memset(copy.columns[copy.column_count..], .{ .px = 0 });
            @memset(copy.rows[copy.row_count..], .{ .px = 0 });
            result.grid = copy;
        }
        return result;
    }
};
const Meta = struct { id: Id, world: u16, element: u32, tag: t.ElementTag };
pub const Patch = union(enum) {
    create: Meta,
    place: struct { id: Id, parent: Id, before: ?Id },
    retained_remove: Id,
    destroy: Id,
    style: struct { id: Id, value: StyleState },
};
const Live = struct { node: *const Node, parent: ?Id = null, dirty: bool = true, style: ?StyleState = null };
const Mirror = struct {
    meta: Meta,
    parent: ?Id = null,
    children: std.ArrayList(Id) = .empty,
    style: ?StyleState = null,
};
pub const RecordingHost = struct {
    allocator: A,
    host: tree.Host = undefined,
    failed: bool = false,
    patches: std.ArrayList(Patch) = .empty,
    live: std.AutoHashMapUnmanaged(Id, Live) = .empty,
    mirror: std.AutoHashMapUnmanaged(Id, Mirror) = .empty,
    replayed: usize = 0,

    /// Must remain at a stable address until deinit. Attach before node creation.
    pub fn init(self: *RecordingHost, allocator: A) void {
        self.* = .{ .allocator = allocator };
        self.host = .{ .context = self, .patch = receive };
        self.host.attach();
    }
    pub fn deinit(self: *RecordingHost) void {
        self.host.detach();
        var it = self.mirror.valueIterator();
        while (it.next()) |m| m.children.deinit(self.allocator);
        self.mirror.deinit(self.allocator);
        self.live.deinit(self.allocator);
        self.patches.deinit(self.allocator);
    }
    fn receive(raw: *anyopaque, event: tree.HostPatch) void {
        const self: *RecordingHost = @ptrCast(@alignCast(raw));
        if (self.failed) return;
        self.record(event) catch {
            self.failed = true;
        };
    }
    fn record(self: *RecordingHost, event: tree.HostPatch) !void {
        const patch: Patch = switch (event) {
            .create => |c| blk: {
                try self.live.putNoClobber(self.allocator, c.id, .{ .node = c.node });
                break :blk .{ .create = .{ .id = c.id, .world = c.world, .element = c.element, .tag = c.tag } };
            },
            .destroy => |id| blk: {
                const live = self.live.get(id) orelse return error.UnknownHostNode;
                // A bypassed detach followed immediately by free would disappear
                // from a final forest comparison. Check before dropping the borrow;
                // children may already be freed here, so inspect only the parent.
                if (live.parent != (if (live.node.parent) |p| p.host_id else @as(?Id, null)))
                    return error.HostParentMismatch;
                _ = self.live.remove(id);
                break :blk .{ .destroy = id };
            },
            .place => |p| blk: {
                (self.live.getPtr(p.id) orelse return error.UnknownHostNode).parent = p.parent;
                break :blk .{ .place = .{ .id = p.id, .parent = p.parent, .before = p.before } };
            },
            .retained_remove => |id| blk: {
                (self.live.getPtr(id) orelse return error.UnknownHostNode).parent = null;
                break :blk .{ .retained_remove = id };
            },
            .dirty => |id| {
                const live = self.live.getPtr(id) orelse return error.UnknownHostNode;
                live.dirty = true;
                return;
            },
        };
        try self.patches.append(self.allocator, patch);
    }
    pub fn flush(self: *RecordingHost) !void {
        if (self.failed) return error.InvalidHostRecording;
        errdefer self.failed = true;
        var it = self.live.iterator();
        while (it.next()) |entry| {
            const live = entry.value_ptr;
            if (!live.dirty) continue;
            const value = StyleState.read(live.node);
            if (live.style == null or !std.meta.eql(live.style.?, value)) {
                try self.patches.append(self.allocator, .{ .style = .{ .id = entry.key_ptr.*, .value = value } });
                live.style = value;
            }
            live.dirty = false;
        }
        while (self.replayed < self.patches.items.len) : (self.replayed += 1) try self.replay(self.patches.items[self.replayed]);
        // Every live node participates, including retained/rootless forests.
        // This runs only at a completed operation/frame boundary, never inside
        // transient renderer paint sorting or a multi-patch tree operation.
        it = self.live.iterator();
        while (it.next()) |entry| try self.expectStructure(entry.value_ptr.node);
        if (self.live.count() != self.mirror.count()) return error.HostNodeCountMismatch;
    }
    fn unlink(self: *RecordingHost, id: Id) !void {
        const child = self.mirror.getPtr(id) orelse return error.UnknownHostNode;
        if (child.parent) |parent| {
            const p = self.mirror.getPtr(parent) orelse return error.UnknownHostParent;
            const index = std.mem.indexOfScalar(Id, p.children.items, id) orelse return error.InvalidHostParent;
            _ = p.children.orderedRemove(index);
        }
        child.parent = null;
    }
    fn replay(self: *RecordingHost, patch: Patch) !void {
        switch (patch) {
            .create => |c| try self.mirror.putNoClobber(self.allocator, c.id, .{ .meta = c }),
            .retained_remove => |id| try self.unlink(id),
            .destroy => |id| {
                try self.unlink(id);
                const m = self.mirror.getPtr(id).?;
                if (m.children.items.len != 0) return error.DestroyBeforeChildren;
                m.children.deinit(self.allocator);
                _ = self.mirror.remove(id);
            },
            .place => |p| {
                try self.unlink(p.id);
                const parent = self.mirror.getPtr(p.parent) orelse return error.UnknownHostParent;
                const child = self.mirror.getPtr(p.id).?;
                if (parent.meta.world != child.meta.world) return error.CrossHostWorld;
                const index = if (p.before) |before| std.mem.indexOfScalar(Id, parent.children.items, before) orelse return error.InvalidHostAnchor else parent.children.items.len;
                try parent.children.insert(self.allocator, index, p.id);
                child.parent = p.parent;
            },
            .style => |s| {
                const m = self.mirror.getPtr(s.id) orelse return error.UnknownHostNode;
                m.style = s.value;
                // view props may refine box -> scroll/button after creation.
                m.meta.tag = s.value.tag;
            },
        }
    }
    /// Compare against an independently supplied complete forest (include detached
    /// retained roots and rootless overlays). No Node pointers are used by replay.
    pub fn expectForest(self: *RecordingHost, roots: []const *Node) !void {
        try self.flush();
        var count: usize = 0;
        for (roots) |root| {
            if (root.parent != null) return error.ExpectedForestRoot;
            count += try self.expectNode(root);
        }
        if (count != self.mirror.count() or count != self.live.count()) return error.HostNodeCountMismatch;
    }
    fn expectStructure(self: *RecordingHost, node: *const Node) !void {
        const m = self.mirror.get(node.host_id) orelse return error.MissingHostNode;
        if (m.meta.world != node.world_id or m.meta.element != node.element_id_raw or m.meta.tag != node.tag)
            return error.HostIdentityMismatch;
        if (m.parent != (if (node.parent) |p| p.host_id else @as(?Id, null))) return error.HostParentMismatch;
        if (m.children.items.len != node.children.items.len) return error.HostChildCountMismatch;
        for (node.children.items, m.children.items) |child, id| {
            if (child.parent != node) return error.HostParentMismatch;
            if (child.host_id != id) return error.HostOrderMismatch;
        }
    }
    fn expectNode(self: *RecordingHost, node: *const Node) !usize {
        try self.expectStructure(node);
        const m = self.mirror.get(node.host_id).?;
        if (m.style == null or !std.meta.eql(m.style.?, StyleState.read(node))) return error.HostStyleMismatch;
        var count: usize = 1;
        for (node.children.items, m.children.items) |child, id| {
            if (child.host_id != id) return error.HostOrderMismatch;
            count += try self.expectNode(child);
        }
        return count;
    }
};
