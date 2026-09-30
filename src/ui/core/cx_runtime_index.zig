//! Cx 运行时索引重建：interaction index / node registry / focus order 的
//! 全量与增量（partial root）重建，以及重建后的焦点对账。从 core.zig 拆出，
//! Cx 上保留同名 thin delegate。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const NodeHandle = core.NodeHandle;
const Node = core.Node;

fn rebuildInteractionIndex(self: *Cx) !void {
    self.perf.interaction_full_rebuild_count += 1;
    try self.interaction_index.rebuild(self.root, &self.node_registry);
    if (self.root) |root| clearInteractionDirtyRecursive(self, root);
}

pub fn collectPartialInteractionRoots(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if ((!node.frame_state.state_bits.dirty.core.subtree_layout and !node.frame_state.state_bits.dirty.pipeline.subtree_interaction) or roots.overflow) return;
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.pipeline.interaction) {
        const candidate = partialInteractionRootForLayoutNode(node) orelse return;
        roots.add(self, candidate);
        return;
    }
    const roots_before = roots.len;
    for (node.children.items) |child| {
        collectPartialInteractionRoots(self, child, roots);
        if (roots.overflow) return;
    }
    // 孤立脏标记修复：subtree_interaction_dirty 冒泡上来后，源头的 interaction_dirty
    // 被 partial rebuild 的 clearInteractionDirtyRecursive 清除，但祖先的
    // subtree_interaction_dirty 没有被清。清除孤立标记防止每帧 full rebuild。
    if (roots.len == roots_before and node.frame_state.state_bits.dirty.pipeline.subtree_interaction and !node.frame_state.state_bits.dirty.core.subtree_layout) {
        node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    }
}

fn collectPartialInteractionRootsFallback(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if (roots.overflow) return;
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.pipeline.interaction) {
        const candidate = partialInteractionRootForLayoutNode(node) orelse return;
        roots.add(self, candidate);
        return;
    }
    for (node.children.items) |child| {
        collectPartialInteractionRootsFallback(self, child, roots);
        if (roots.overflow) return;
    }
}

pub fn collectPartialInteractionRootsWithFallback(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if (node.frame_state.state_bits.dirty.core.subtree_layout or node.frame_state.state_bits.dirty.pipeline.subtree_interaction) {
        collectPartialInteractionRoots(self, node, roots);
        if (roots.len > 0 or roots.overflow) return;
    }
    if (subtreeHasLooseInteractionDirty(node)) {
        collectPartialInteractionRootsFallback(self, node, roots);
    }
}

pub fn rebuildInteractionIndexWithPartialRoots(self: *Cx, roots: PartialInteractionRoots) !void {
    if (self.node_registry.entries.count() == 0) {
        const root = self.root orelse return;
        try fullRebuildRuntimeIndexes(self, root);
        return;
    }

    if (roots.overflow or roots.len == 0) {
        try rebuildInteractionIndex(self);
        return;
    }

    for (roots.items[0..roots.len]) |handle| {
        const node = self.node_registry.resolve(handle, null) orelse {
            try rebuildInteractionIndex(self);
            return;
        };
        if (!(try self.interaction_index.rebuildSubtree(node, &self.node_registry))) {
            try rebuildInteractionIndex(self);
            return;
        }
        self.perf.interaction_partial_rebuild_count += 1;
        clearInteractionDirtyRecursive(self, node);
    }
    // partial rebuild 完成后，清理祖先链上残留的 subtree_interaction_dirty。
    // clearInteractionDirtyRecursive 只清了 partial root 子树，祖先的 subtree 标记
    // 仍为 true，会导致下一帧再次触发无效的 full rebuild。
    if (self.root) |root| {
        clearStaleSubtreeInteractionDirty(self, root);
    }
    // partial rebuild 完成后重建空间 grid
}

fn partialInteractionRootForLayoutNode(node: *Node) ?*Node {
    // 一个 in-flow 子节点的盒子尺寸变化（如 Accordion content 展开高度变化）会让
    // **父容器重跑 layoutChildren**，从而把它**后面的兄弟节点整体位移**。若 partial
    // interaction 重建只覆盖这个变化节点自己的子树，被位移的兄弟（及其后代）的命中
    // 区域仍停在旧位置 → hit-test 命中旧布局（用户报的 Accordion 展开后点下方 item
    // 命中错位/落空 bug）。所以把重建根上提到**父节点**，覆盖所有被 reflow 的兄弟。
    //
    // 仅 in-flow 节点这么做：absolute/out-of-flow 节点的尺寸变化不影响兄弟排布，
    // 上提反而无谓扩大重建范围。无父节点（根）退回自身。
    if (node.style.position != .absolute) {
        if (node.parent) |parent| return parent;
    }
    return node;
}

/// loose 三位（pipeline.interaction/hit.geometry/hit.semantics）不冒泡，
/// 只能全树扫——曾是帧结构采样最大单项（每帧最多 6 个调用点）。按
/// (root, node_dirty.g_loose_interaction_gen) 记忆：所有置位/清位点都
/// bump 代数（见 node_dirty.bumpLooseInteractionGen 注释的约定），
/// 代数不变 ⇒ 位集不变 ⇒ 结果不变，语义与逐次扫描精确等价。
pub fn subtreeHasLooseInteractionDirty(node: *Node) bool {
    const LooseMemo = struct {
        var root: ?*Node = null;
        var gen: u64 = 0;
        var result: bool = false;
    };
    const cur_gen = @import("node_dirty.zig").g_loose_interaction_gen;
    if (LooseMemo.root == node and LooseMemo.gen == cur_gen) return LooseMemo.result;
    const scanned = subtreeHasLooseInteractionDirtyScan(node);
    LooseMemo.root = node;
    LooseMemo.gen = cur_gen;
    LooseMemo.result = scanned;
    return scanned;
}

fn subtreeHasLooseInteractionDirtyScan(node: *Node) bool {
    if (node.frame_state.state_bits.dirty.pipeline.interaction or node.frame_state.state_bits.dirty.hit.geometry or node.frame_state.state_bits.dirty.hit.semantics) return true;
    for (node.children.items) |child| {
        if (subtreeHasLooseInteractionDirtyScan(child)) return true;
    }
    return false;
}

fn isDescendantNode(node: *Node, ancestor: *Node) bool {
    var current: ?*Node = node;
    while (current) |n| {
        if (n == ancestor) return true;
        current = n.parent;
    }
    return false;
}

pub fn rebuildRuntimeIndexes(self: *Cx) !void {
    const root = self.root orelse return;
    // 诊断阀：ZENIT_FULL_RUNTIME_REBUILD=1 强制每次全量重建 runtime
    // index（排查 partial 重排 paint order 与静止子树交错的问题）
    const needs_full_rebuild = self.node_registry.entries.count() == 0 or
        root.frame_state.state_bits.dirty.runtime.subtree_full_rebuild or
        std.posix.getenv("ZENIT_FULL_RUNTIME_REBUILD") != null;
    if (needs_full_rebuild) {
        try fullRebuildRuntimeIndexes(self, root);
    } else {
        var partial_interaction_roots = PartialInteractionRoots{};
        collectRuntimeDirtyRoots(self, root, &partial_interaction_roots);
        try rebuildDirtyRuntimeSubtrees(self, root);
        self.focus_manager.finalizeFocusOrder();
        reconcileFocusedAfterRuntimeRebuild(self);
        try rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots);
    }
}

pub fn rebuildRuntimeIndexesForTest(self: *Cx) !void {
    return rebuildRuntimeIndexes(self);
}

fn rebuildRuntimeStateRecursive(self: *Cx, node: *Node) !void {
    node.frame_state.state_bits.dirty.runtime.dirty = false;
    node.frame_state.state_bits.dirty.runtime.subtree_dirty = false;
    node.frame_state.state_bits.dirty.runtime.full_rebuild = false;
    node.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
    node.frame_state.state_bits.dirty.pipeline.order = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_order = false;
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    node.frame_state.state_bits.dirty.hit.geometry = false;
    node.frame_state.state_bits.dirty.hit.semantics = false;
    node.frame_state.state_bits.dirty.hit.structure = false;
    @import("node_dirty.zig").bumpLooseInteractionGen();
    const generation = try self.node_registry.trackGeneration(node);
    try self.node_registry.entries.put(node.id, .{ .ptr = node, .generation = generation });
    try self.focus_manager.appendFocusableUnsorted(node);
    for (node.children.items) |child| {
        try rebuildRuntimeStateRecursive(self, child);
    }
}

pub fn fullRebuildRuntimeIndexes(self: *Cx, root: *Node) !void {
    self.perf.focus_rebuild_count += 1;
    self.node_registry.clear();
    self.focus_manager.clearFocusOrder();
    try rebuildRuntimeStateRecursive(self, root);
    self.focus_manager.finalizeFocusOrder();
    reconcileFocusedAfterRuntimeRebuild(self);
    try rebuildInteractionIndex(self);
}

fn rebuildDirtyRuntimeSubtrees(self: *Cx, node: *Node) !void {
    if (!node.frame_state.state_bits.dirty.runtime.subtree_dirty) return;
    if (node.frame_state.state_bits.dirty.runtime.dirty) {
        // 增量重建只是把这棵子树从 registry/focus_order 摘掉再重灌 ——
        // 节点本身不销毁。unregisterFocusableSubtree 会顺手把落在子树内的
        // current_focus 清空（对"子树将被释放"的调用方是正确的），这里
        // 必须在重灌后把焦点还回去，否则任何"重绘当前焦点行"的组件
        //（如 VirtualList 行选中态刷新）都会静默丢键盘焦点。
        const focused_before = self.focus_manager.current_focus;
        const focus_was_inside = if (focused_before) |f| isDescendantNode(f, node) else false;
        self.node_registry.detachSubtree(node);
        self.focus_manager.unregisterFocusableSubtree(node);
        try rebuildRuntimeStateRecursive(self, node);
        if (focus_was_inside) {
            if (focused_before) |f| {
                // 仅当节点确实随 rebuild 重新注册（同 id 同指针）才恢复；
                // 若它在标脏与重建之间被从树上摘掉，维持清空语义。
                if (self.node_registry.entries.get(f.id)) |entry| {
                    if (entry.ptr == f) {
                        self.focus_manager.restoreFocusAfterSubtreeRebuild(f);
                    }
                }
            }
        }
        return;
    }
    for (node.children.items) |child| {
        try rebuildDirtyRuntimeSubtrees(self, child);
    }
    node.frame_state.state_bits.dirty.runtime.subtree_dirty = false;
    node.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = false;
}

fn collectRuntimeDirtyRoots(self: *Cx, node: *Node, roots: *PartialInteractionRoots) void {
    if (!node.frame_state.state_bits.dirty.runtime.subtree_dirty or roots.overflow) return;
    if (node.frame_state.state_bits.dirty.runtime.dirty) {
        // A newly registered/reparented node has no authoritative global
        // paint range. Rebuilding it alone can reuse the default [0,0]
        // range, placing a new topmost sibling underneath existing nodes.
        // Recompute at the parent boundary so sibling order is committed
        // together; changed range size still falls back to a full rebuild.
        roots.add(self, node.parent orelse node);
        return;
    }
    for (node.children.items) |child| {
        collectRuntimeDirtyRoots(self, child, roots);
        if (roots.overflow) return;
    }
}

pub fn rebuildOrderIndexes(self: *Cx) !void {
    const root = self.root orelse return;
    if (orderDirtyAffectsFocus(self, root)) {
        if (!(try rebuildDirtyFocusOrderIncremental(self, root))) {
            self.perf.focus_order_rebuild_count += 1;
            try self.focus_manager.collectFocusableNodes(root);
        }
        reconcileFocusedAfterRuntimeRebuild(self);
    }
    if (!(try rebuildDirtyInteractionSubtrees(self, root))) {
        try rebuildInteractionIndex(self);
    } else {
        // 增量 subtree rebuild 成功后也要重建空间 grid
    }
    clearOrderDirtyRecursive(self, root);
}

fn clearOrderDirtyRecursive(self: *Cx, node: *Node) void {
    node.frame_state.state_bits.dirty.pipeline.order = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_order = false;
    for (node.children.items) |child| {
        clearOrderDirtyRecursive(self, child);
    }
}

fn clearInteractionDirtyRecursive(self: *Cx, node: *Node) void {
    @import("node_dirty.zig").bumpLooseInteractionGen();
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    node.frame_state.state_bits.dirty.hit.geometry = false;
    node.frame_state.state_bits.dirty.hit.semantics = false;
    node.frame_state.state_bits.dirty.hit.structure = false;
    for (node.children.items) |child| {
        clearInteractionDirtyRecursive(self, child);
    }
}

/// 自底向上清理 subtree_interaction_dirty：如果节点的所有子节点都已清洁，
/// 则节点自身的 subtree_interaction_dirty 也应清除。
fn clearStaleSubtreeInteractionDirty(self: *Cx, node: *Node) void {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_interaction) return;
    if (node.frame_state.state_bits.dirty.pipeline.interaction) return; // 自身脏，不清
    for (node.children.items) |child| {
        clearStaleSubtreeInteractionDirty(self, child);
    }
    // 检查所有子节点是否已清洁
    for (node.children.items) |child| {
        if (child.frame_state.state_bits.dirty.pipeline.interaction or child.frame_state.state_bits.dirty.pipeline.subtree_interaction) return;
    }
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
}

fn orderDirtyAffectsFocus(self: *Cx, node: *Node) bool {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_order) return false;
    if (node.frame_state.state_bits.dirty.pipeline.order) {
        return subtreeContainsFocusableOrderParticipant(node);
    }
    for (node.children.items) |child| {
        if (orderDirtyAffectsFocus(self, child)) return true;
    }
    return false;
}

fn rebuildDirtyFocusOrderIncremental(self: *Cx, node: *Node) !bool {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_order) return true;
    if (node.frame_state.state_bits.dirty.pipeline.order) {
        if (!subtreeSupportsIncrementalFocusRepair(node)) return false;
        try self.focus_manager.replaceDefaultOrderSubtree(node);
        return true;
    }
    for (node.children.items) |child| {
        if (!(try rebuildDirtyFocusOrderIncremental(self, child))) return false;
    }
    return true;
}

fn rebuildDirtyInteractionSubtrees(self: *Cx, node: *Node) !bool {
    if (!node.frame_state.state_bits.dirty.pipeline.subtree_order) return true;
    if (node.frame_state.state_bits.dirty.pipeline.order) {
        if (!(try self.interaction_index.rebuildSubtree(node, &self.node_registry))) {
            return false;
        }
        self.perf.interaction_partial_rebuild_count += 1;
        return true;
    }
    for (node.children.items) |child| {
        if (!(try rebuildDirtyInteractionSubtrees(self, child))) return false;
    }
    return true;
}

fn subtreeContainsFocusableOrderParticipant(node: *Node) bool {
    if (node.behavior.interaction.focus_scope != null) return true;
    if (nodeParticipatesInFocusOrder(node)) return true;
    for (node.children.items) |child| {
        if (subtreeContainsFocusableOrderParticipant(child)) return true;
    }
    return false;
}

fn nodeParticipatesInFocusOrder(node: *Node) bool {
    const is_focusable = node.behavior.interaction.focusable or node.behavior.interaction.tab_index != null;
    const excluded_from_tab = if (node.behavior.interaction.tab_index) |ti| ti < 0 else false;
    return is_focusable and !excluded_from_tab;
}

fn subtreeSupportsIncrementalFocusRepair(node: *Node) bool {
    if (node.behavior.interaction.focus_scope != null) return false;
    if (node.behavior.interaction.tab_index) |ti| {
        if (ti > 0) return false;
    }
    for (node.children.items) |child| {
        if (!subtreeSupportsIncrementalFocusRepair(child)) return false;
    }
    return true;
}

/// Runtime-index rebuilds are the **second** boundary at which the
/// effective focus can change (the first is setFocusWithReason, which
/// reconciles via on_focus_settled). A rebuild detaches the subtree from
/// registry/focus_order and re-registers it, so focus can be cleared and
/// restored — `restoreFocusAfterSubtreeRebuild` writes the fields directly
/// and deliberately fires no blur/focus events.
///
/// The window-level native IME gate is *derived* from focus, so it has to
/// be reconciled wherever focus settles, not only where focus events are
/// dispatched. Leaving it out is silent and permanent: the gate is a single
/// window-global switch, so a focused editor whose gate was closed by a
/// previous client (a popover Input, a freed node's deactivate) never gets
/// another chance to reopen it, and accepts no IME input until the user
/// clicks away and back. refreshTextInputSession is idempotent, so calling
/// it on every settle costs nothing when the state already matches.
fn reconcileFocusedAfterRuntimeRebuild(self: *Cx) void {
    if (self.focus_manager.getFocused()) |focused| {
        if (!self.node_registry.entries.contains(focused.id)) {
            // partial 重建对未覆盖子树的收录有缺口：entries 缺席 ≠ 节点已死。
            // 只有 generations 判死（noteNodeFreed 置 last_ptr=null / 指针
            // 已换代）才清焦点；活着但暂未入索引的节点保持焦点，下一次
            // full rebuild 自然收录。实弹：焦点在 sidebar 行上时，编辑器
            // syntax prewarm 完成触发的 partial 重建曾借此把焦点清成 null
            // （面板整体失焦灰），且随机器时序忽现忽隐。
            const alive = if (self.node_registry.generations.get(focused.id)) |g|
                g.last_ptr == focused
            else
                false;
            if (!alive) {
                // clearFocus 走 setFocusWithReason → on_focus_settled 已
                // 刷过原生闸，这里不必重复。
                self.focus_manager.clearFocus();
                self.focused_node = null;
                self.focused_handle = null;
                return;
            }
            // handle 保持旧值：entries 回来后 resolve 自然恢复。
            self.focused_node = focused;
            self.refreshTextInputSession();
            return;
        }
        self.focused_node = focused;
        self.focused_handle = self.node_registry.handleFor(focused);
        self.refreshTextInputSession();
        return;
    }
    self.focused_node = null;
    self.focused_handle = null;
    self.refreshTextInputSession();
}

pub const PartialInteractionRoots = struct {
    items: [64]NodeHandle = undefined,
    len: usize = 0,
    overflow: bool = false,

    fn add(self: *PartialInteractionRoots, cx: *Cx, node: *Node) void {
        if (self.overflow) return;

        const handle = cx.node_registry.handleFor(node);

        var i: usize = 0;
        while (i < self.len) {
            const existing_handle = self.items[i];
            const existing = cx.node_registry.resolve(existing_handle, null) orelse {
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
                continue;
            };
            if (existing == node) return;
            if (isDescendantNode(node, existing)) return;
            if (isDescendantNode(existing, node)) {
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
                continue;
            }
            i += 1;
        }

        if (self.len >= self.items.len) {
            self.overflow = true;
            self.len = 0;
            return;
        }
        self.items[self.len] = handle;
        self.len += 1;
    }
};
