const std = @import("std");
const ui = @import("../core.zig");
const tree = @import("node_tree.zig");
const RecordingHost = @import("recording_host.zig").RecordingHost;
const Node = ui.Node;
const a = std.testing.allocator;

test "renderer host random forest operations replay after every transition" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    var nodes: [24]*Node = undefined;
    var made: usize = 0;
    defer {
        for (nodes[0..made]) |n| if (n.parent) |p| {
            p.removeChildRetained(n);
        };
        for (nodes[0..made]) |n| cx.freeNode(n);
    }
    for (&nodes) |*slot| {
        slot.* = try cx.createNode(.box, .{});
        made += 1;
    }
    // 32 fixed seeds, 512 operations each over nested forests. Rejected cyclic
    // and foreign inputs are also exercised separately below.
    for (0..32) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        for (0..512) |_| {
            const parent = nodes[random.uintLessThan(usize, nodes.len)];
            const child = nodes[4 + random.uintLessThan(usize, 20)];
            if (parent.isDescendantOf(child)) continue;
            switch (random.uintLessThan(u8, 7)) {
                0 => try parent.appendChild(a, child),
                1 => {
                    const anchor = if (parent.children.items.len > 0) parent.children.items[0] else null;
                    try parent.insertChildBefore(a, child, anchor);
                },
                2 => if (child.parent) |p| {
                    p.removeChildRetained(child);
                },
                3 => {
                    var order: [24]*Node = undefined;
                    const len = parent.children.items.len;
                    for (parent.children.items, 0..) |n, i| order[len - i - 1] = n;
                    try parent.replaceChildOrder(a, order[0..len]);
                },
                4 => {
                    child.style.gap = random.float(f32) * 10;
                    child.markLayoutDirty();
                    child.markLayoutDirty(); // already-dirty writes must still publish
                },
                5 => {
                    (try child.style.ensureExtFallible(a)).no_cross_stretch = random.boolean();
                    child.markRenderDirty();
                },
                else => {
                    if (child.parent) |p| p.removeChildRetained(child);
                    while (child.children.items.len > 0) child.removeChildRetained(child.children.items[0]);
                    cx.freeNode(child);
                    // Reuse a World slot (including generation wrap), never a host id.
                    const index = std.mem.indexOfScalar(*Node, &nodes, child).?;
                    nodes[index] = try cx.createNode(.box, .{});
                },
            }
            var roots: [24]*Node = undefined;
            var len: usize = 0;
            for (nodes) |n| if (n.parent == null) {
                roots[len] = n;
                len += 1;
            };
            try host.expectForest(roots[0..len]);
        }
    }
}

test "renderer host final style diff coalesces ext grid and paint state" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const n = try cx.createNode(.box, .{});
    defer cx.freeNode(n);
    try host.expectForest(&.{n});
    const initial = host.patches.items.len;
    try host.flush();
    try std.testing.expectEqual(initial, host.patches.items.len);
    const ext = try n.style.ensureExtFallible(a);
    ext.grid = try a.create(ui.GridConfig);
    ext.grid.?.* = .{ .column_count = 1 };
    ext.grid.?.columns[0] = .{ .px = 12 };
    n.setBackgroundRaw(ui.Color.hex(0x112233));
    n.setOpacityRaw(0.4);
    n.markRenderDirty();
    ext.grid.?.columns[0] = .{ .px = 35 };
    ext.no_cross_stretch = true;
    n.markRenderDirty();
    try host.expectForest(&.{n});
    try std.testing.expectEqual(initial + 1, host.patches.items.len);
    n.markRenderDirty();
    try host.flush();
    try std.testing.expectEqual(initial + 1, host.patches.items.len);
}

fn oomTree(allocator: std.mem.Allocator) !void {
    // Observer storage uses a separate allocator: failure injection targets every
    // authoritative allocation. Compare the forest also after a rejected mutation.
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const p = try Node.create(allocator, 1, .box, .{});
    defer p.destroy(allocator);
    const q = try Node.create(allocator, 2, .box, .{});
    defer q.destroy(allocator);
    const c = try Node.create(allocator, 3, .box, .{});
    defer {
        if (c.parent) |parent| parent.removeChildRetained(c);
        c.destroy(allocator);
    }
    const d = try Node.create(allocator, 4, .box, .{});
    defer {
        if (d.parent) |parent| parent.removeChildRetained(d);
        d.destroy(allocator);
    }
    defer {
        var roots: [4]*Node = undefined;
        var len: usize = 0;
        for ([_]*Node{ p, q, c, d }) |n| if (n.parent == null) {
            roots[len] = n;
            len += 1;
        };
        host.expectForest(roots[0..len]) catch @panic("OOM tree patch divergence");
    }
    try p.appendChild(allocator, c);
    try p.insertChildBefore(allocator, d, c);
    try q.appendChild(allocator, c);
    try q.replaceChildOrder(allocator, &.{ d, c });
    try q.replaceChildOrder(allocator, &.{c}); // retained omission
}

test "renderer host per allocation OOM preserves patch equivalence" {
    try std.testing.checkAllAllocationFailures(a, oomTree, .{});
}

fn oomRecorder(allocator: std.mem.Allocator) !void {
    var host: RecordingHost = undefined;
    host.init(allocator);
    defer host.deinit();
    const p = try Node.create(a, 1, .box, .{});
    var alive = true;
    defer if (alive) p.destroy(a);
    const c = try Node.create(a, 2, .box, .{});
    try p.appendChild(a, c);
    host.expectForest(&.{p}) catch |err| {
        if (host.failed) return error.OutOfMemory;
        return err;
    };
    p.destroy(a);
    alive = false;
    host.expectForest(&.{}) catch |err| {
        if (host.failed) return error.OutOfMemory;
        return err;
    };
}

test "renderer host recorder allocation failures cannot accept partial replay" {
    try std.testing.checkAllAllocationFailures(a, oomRecorder, .{});
}

test "renderer host rejected cycle duplicate anchor and cross window emit no patches" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const other = try ui.Cx.init(a, std.testing.io);
    defer other.deinit();
    const p = try cx.createNode(.box, .{});
    defer cx.freeNode(p);
    const c = try cx.createNode(.box, .{});
    const q = try other.createNode(.box, .{});
    defer other.freeNode(q);
    try p.appendChild(a, c);
    try host.expectForest(&.{ p, q });
    const before = host.patches.items.len;
    try std.testing.expectError(error.CyclicNodeTree, c.appendChild(a, p));
    try std.testing.expectError(error.CrossWorldNode, q.appendChild(a, c));
    try std.testing.expectError(error.InvalidAnchor, p.insertChildBefore(a, c, q));
    try std.testing.expectError(error.DuplicateChild, p.replaceChildOrder(a, &.{ c, c }));
    try host.expectForest(&.{ p, q });
    try std.testing.expectEqual(before, host.patches.items.len);
}

const Build = struct {
    fn leaf(_: *ui.Scope, cx: *ui.Cx) anyerror!*Node {
        return cx.createNode(.box, .{});
    }
    fn row(_: *ui.Scope, cx: *ui.Cx, _: u32, _: usize) anyerror!*Node {
        return cx.createNode(.box, .{});
    }
    fn key(item: u32) u64 {
        return item;
    }
    fn branch(_: *ui.Scope, cx: *ui.Cx, value: u8) anyerror!*Node {
        return cx.createNode(.box, .{ .gap = @floatFromInt(value) });
    }
};

test "renderer host real For keyed reorder and Show Match transitions" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const parent = try cx.createNode(.box, .{});
    cx.root = parent;
    const scope = try ui.Scope.init(a, null, cx.owner);
    var scope_live = true;
    defer if (scope_live) scope.dispose();
    const items = try scope.createSignal([]const u32, &.{ 1, 2, 3 });
    const visible = try scope.createSignal(bool, false);
    const branch = try scope.createSignal(u8, 0);
    const cf = @import("../control_flow.zig");
    try cf.For(u32, scope, parent, items, cx, .{ .key_fn = Build.key, .render_fn = Build.row });
    try cf.Show(scope, parent, visible, cx, Build.leaf);
    _ = try cf.Match(u8, scope, parent, branch, cx, Build.branch);
    try host.expectForest(&.{parent});
    for (0..24) |i| {
        items.set(if (i % 2 == 0) &.{ 3, 1, 2 } else &.{ 2, 4, 3 });
        try host.expectForest(&.{parent});
        visible.set(i % 2 == 0);
        try host.expectForest(&.{parent});
        branch.set(@intCast(i % 3));
        try host.expectForest(&.{parent});
    }
    scope.dispose();
    scope_live = false;
    cx.root = null;
    cx.freeNode(parent);
    try host.expectForest(&.{});
}

test "renderer host rootless suspended overlay portal and multiple window recreation" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const b = try ui.Cx.init(a, std.testing.io);
    defer b.deinit();
    const floating = try b.createNode(.box, .{});
    defer b.freeNode(floating);
    // Real overlay lifecycle with no Cx.root; no fake parent is introduced.
    const layer = try b.overlay_stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    b.overlay_stack.bindContentNode(a, layer, floating);
    defer b.overlay_stack.removePermanently(layer);
    try host.expectForest(&.{floating});
    b.overlay_stack.commitExit(layer);
    try std.testing.expect(b.overlay_stack.findLayer(layer).?.suspended);
    try host.expectForest(&.{floating});
    b.overlay_stack.reactivate(layer);
    try host.expectForest(&.{floating});
    var last_id: tree.HostId = 0;
    for (0..8) |_| {
        const cx = try ui.Cx.init(a, std.testing.io);
        const root = try cx.createNode(.box, .{});
        cx.root = root;
        const portal = try cx.ensurePopoverPortalRoot();
        const content = try cx.createNode(.box, .{});
        try portal.appendChild(a, content);
        try std.testing.expect(content.host_id > last_id);
        last_id = content.host_id;
        try host.expectForest(&.{ root, floating });
        portal.removeChildRetained(content);
        try host.expectForest(&.{ root, content, floating });
        try portal.appendChild(a, content);
        cx.deinit();
        try host.expectForest(&.{floating});
    }
}

test "renderer host cleanup reentry and deferred destruction retain identity until release" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const parent = try cx.createNode(.box, .{});
    defer cx.freeNode(parent);
    const child = try cx.createNode(.box, .{});
    const sibling = try cx.createNode(.box, .{});
    defer cx.freeNode(sibling);
    try parent.appendChild(a, child);
    try parent.appendChild(a, sibling);
    const Reentry = struct {
        parent: *Node,
        sibling: *Node,
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.parent.removeChildRetained(self.sibling);
        }
    };
    var reentry = Reentry{ .parent = parent, .sibling = sibling };
    child.meta.ownership.hooks.on_cleanup = .{ .context = &reentry, .callback = Reentry.cleanup };
    child.frame_state.state_bits.flags.is_mounted = true;
    parent.removeChild(child);
    try host.expectForest(&.{ parent, child, sibling });
    const id = child.host_id;
    cx.tick_depth += 1;
    cx.freeNode(child);
    try host.expectForest(&.{ parent, child, sibling });
    cx.tick_depth -= 1;
    @import("cx_node_lifetime.zig").drainDeferredFrees(cx);
    try host.expectForest(&.{ parent, sibling });
    try std.testing.expect(!host.live.contains(id));
}

test "renderer host identities survive ElementId reuse retirement and two observers" {
    var first: RecordingHost = undefined;
    first.init(a);
    defer first.deinit();
    var second: RecordingHost = undefined;
    second.init(a);
    defer second.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    var previous: tree.HostId = 0;
    var initial_element: ?u32 = null;
    var reused_index = false;
    var retired_index = false;
    for (0..600) |_| {
        const n = try cx.createNode(.box, .{});
        if (initial_element) |raw| {
            reused_index = reused_index or (raw & 0xFFFFFF) == (n.element_id_raw & 0xFFFFFF);
            retired_index = retired_index or (raw & 0xFFFFFF) != (n.element_id_raw & 0xFFFFFF);
            if (previous != 0) try std.testing.expect(raw != n.element_id_raw);
        } else {
            initial_element = n.element_id_raw;
        }
        try std.testing.expect(n.host_id > previous);
        previous = n.host_id;
        try first.expectForest(&.{n});
        try second.expectForest(&.{n});
        n.setStyle(null, .layout_isolation, true); // dirty level .none still diffed
        n.setStyle(a, .tab_index, 3);
        try first.expectForest(&.{n});
        try second.expectForest(&.{n});
        cx.freeNode(n);
        try first.expectForest(&.{});
        try second.expectForest(&.{});
    }
    try std.testing.expect(reused_index);
    try std.testing.expect(retired_index);
}

fn oomOwnedCreate(allocator: std.mem.Allocator) !void {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    var world = ui.world.World.init(allocator);
    defer world.deinit();
    defer host.expectForest(&.{}) catch @panic("partial create published a host node");
    const n = try @import("node_lifecycle.zig").createIn(allocator, &world, 123, 1, .box, .{});
    try host.expectForest(&.{n});
    // Standalone lifecycle destruction does not own the World slot.
    world.destroyElement(ui.world.ElementId.fromRaw(n.element_id_raw));
    n.element_id_raw = 0xFFFFFFFF;
    n.destroy(allocator);
}

test "renderer host explicit World create rolls back at every allocation" {
    try std.testing.checkAllAllocationFailures(a, oomOwnedCreate, .{});
}

test "renderer host flush rejects missed reorder and latches invalidity" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const p = try Node.create(a, 1, .box, .{});
    defer p.destroy(a);
    const c = try Node.create(a, 2, .box, .{});
    const d = try Node.create(a, 3, .box, .{});
    try p.appendChild(a, c);
    try p.appendChild(a, d);
    try host.flush();
    // Model a missed patch without introducing another raw Node write.
    host.host.detach();
    try p.replaceChildOrder(a, &.{ d, c });
    host.host.attach();
    try std.testing.expectError(error.HostOrderMismatch, host.flush());
    try std.testing.expectError(error.InvalidHostRecording, host.flush());
}

test "renderer host destroy detects a missed retained removal" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const p = try Node.create(a, 1, .box, .{});
    defer p.destroy(a);
    const c = try Node.create(a, 2, .box, .{});
    try p.appendChild(a, c);
    try host.flush();
    host.host.detach();
    p.removeChildRetained(c);
    host.host.attach();
    c.destroy(a);
    try std.testing.expectError(error.InvalidHostRecording, host.flush());
}

test "renderer host flush compares ElementId metadata" {
    var host: RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const n = try Node.create(a, 1, .box, .{});
    defer n.destroy(a);
    try host.flush();
    host.mirror.getPtr(n.host_id).?.meta.element ^= 1;
    try std.testing.expectError(error.HostIdentityMismatch, host.flush());
}
