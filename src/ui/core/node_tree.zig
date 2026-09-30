//! node_tree — v0.12 §N5 god-object split（最后一刀，最高耦合 4/5）：
//! 从 node.zig 抽出树结构子域（7 方法 + structure callback 单元）。
//!
//! 范式同 §N1-§N4：Node-typed free function + @import("node.zig") 循环
//! import；node.zig 保留 thin delegate（原 pub/private 可见性）。
//!
//! 留最后切因耦合最高：appendChild/removeChild 调 dirty(§N1)/
//! lifecycle.fireCleanupCallbacks(§N4)/interaction.markCustomDrawSubtree
//! (§N3)——前 4 刀已稳定这些接口，此时切阻力最小。
//!
//! structure callback 单元（StructureKind/StructureNotifyFn/
//! g_structure_notify/setStructureNotifyCallback）整体搬，node.zig
//! re-export 保持公开 API（外部 core.zig 调 setStructureNotifyCallback）。

const std = @import("std");
const world_mod = @import("world.zig");
const node_mod = @import("node.zig");

const Node = node_mod.Node;
const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────
// structure callback 单元（自 node.zig 整体搬入）
// appendChild/removeChild 同步父子链到 World.elements。
// ─────────────────────────────────────────────────────────────────────

pub const StructureKind = enum(u8) { append, unlink };
pub const StructureNotifyFn = *const fn (parent_raw: u32, child_raw: u32, kind: StructureKind) void;
var g_structure_notify: ?StructureNotifyFn = null;

/// 把一次父子链变更同步给节点所属 World 的 elements 表。
///
/// P0-3 阶段 3：优先直连 `world_ref`；null（cx-less mock）时退回旧全局回调。
/// 语义与原 core.zig:onNodeStructure 逐行一致 —— 含 append 前的 reparent
/// unlink（child 已有 parent 时必须先摘链，否则父子链表会串）。
fn syncWorldStructure(parent: anytype, child: anytype, kind: StructureKind) void {
    if (parent.element_id_raw == 0xFFFFFFFF or child.element_id_raw == 0xFFFFFFFF) return;
    // 用 parent 的 owner —— append 后 child 归属 parent 所在 World。
    if (parent.world_ref) |w| {
        const parent_eid = world_mod.ElementId.fromRaw(parent.element_id_raw);
        const child_eid = world_mod.ElementId.fromRaw(child.element_id_raw);
        if (!w.elements.isValid(parent_eid) or !w.elements.isValid(child_eid)) return;
        switch (kind) {
            .append => {
                // reparent 场景：child 已有 parent 时先 unlink，否则链表串台。
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

// ─────────────────────────────────────────────────────────────────────
// 树结构方法
// ─────────────────────────────────────────────────────────────────────

/// 沿 parent 链向上查找；self 是 ancestor 后代（含 self）返回 true。
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
    child.parent = self;
    // 子节点有 custom_draw → 冒泡标记
    if (child.frame_state.state_bits.flags.has_custom_draw_subtree) {
        self.markCustomDrawSubtree();
    }
    // 子树 text / before_render 标志并入父链（同 has_custom_draw_subtree 维护方式）
    if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
    if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
    child.frame_state.state_bits.dirty.runtime.dirty = true;
    child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
    child.frame_state.state_bits.dirty.runtime.full_rebuild = false;
    child.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
    self.bubbleChildRuntimeIndexDirty(false);
    self.markLayoutDirty();
    // P0-3 阶段 3：直连 owner World 同步父子链，不再经过进程级回调。
    syncWorldStructure(self, child, .append);
}

/// 使用现有子节点指针重排 children 顺序。
/// 不创建/销毁节点，不触发 runtime registry rebuild，只标记 order/layout dirty。
/// World.elements 的兄弟链表必须同步重排（appendChild/removeChild* 都同步，
/// 这里曾漏掉）：渲染主路径今天走 Node.children 暂无消费者，但 P3 迁移的
/// 既定方向是读 World 链表——沉默的表间分叉在那天会变成绘制顺序错乱。
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
    }
    self.children.clearRetainingCapacity();
    for (order) |child| {
        if (child.parent) |old_parent| old_parent.removeChildRetained(child);
        self.children.appendAssumeCapacity(child);
        child.parent = self;
        if (child.frame_state.state_bits.flags.has_custom_draw_subtree) self.markCustomDrawSubtree();
        if (child.frame_state.state_bits.flags.has_text_subtree) self.markSubtreeText();
        if (child.frame_state.state_bits.flags.has_before_render_subtree) self.markSubtreeBeforeRenderHook();
        if (membership_changed) {
            child.frame_state.state_bits.dirty.runtime.dirty = true;
            child.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
        }
        syncWorldStructure(self, child, .append);
    }
    if (membership_changed) self.markRuntimeIndexDirty();
    self.markOrderDirty();
    self.markLayoutDirty();
}

/// 从父节点移除子节点，递归触发 onCleanup。
/// 注意: 不释放 child 内存。调用者需手动 `cx.freeNode(child)` 释放。
/// on_cleanup 是一次性消费（触发即摘除）——detach 后重挂同一节点请走
/// removeChildRetained，它不触发也不消费 cleanup。
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
    if (full_runtime_rebuild) {
        self.markRuntimeIndexFullRebuild();
    }
    child.parent = null;
    self.markLayoutDirty();
    // P0-3 阶段 3：同上，直连 owner World。
    syncWorldStructure(self, child, .unlink);
}

/// 移除所有子节点，递归触发 onCleanup。
/// 注意: 不释放子节点内存。调用者需对每个子节点手动 `cx.freeNode()` 释放。
pub fn removeAllChildren(self: *Node) void {
    for (self.children.items) |child| {
        node_mod.fireCleanupCallbacks(child);
        // Keep the World.elements sibling chain in lockstep with Node.children,
        // exactly like removeChild/removeChildRetained.
        syncWorldStructure(self, child, .unlink);
        child.parent = null;
    }
    self.children.clearRetainingCapacity();
    self.markRuntimeIndexDirty();
    self.markLayoutDirty();
}
