//! Cx node lifetime: detach / freeNode (includes delayed release during tick),
//! invalidate hover/focus/pressed etc raw references, scope bound to node.
//! constraints on release order + UAF protection documented in each function.

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_platform = @import("cx_platform.zig");
const cx_bulk_quads = @import("cx_bulk_quads.zig");
const OwnedCell = core.OwnedCell;
const Allocator = std.mem.Allocator;
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const Scope = core.Scope;
const clearNodeScopes = core.clearNodeScopes;
const core_node = @import("node.zig");
const hooks_mod = @import("../hooks.zig");
const reactive = @import("../reactive.zig");
const world = core.world;
const a11y_tree = core.a11y_tree;

/// Clear dangling Cx/EventDispatcher/FocusManager pointers into a subtree about to be destroyed.
///
/// Clears event state references to the subtree (focused/hovered/pressed etc).
/// `unregister = true` **also** removes the subtree from node_registry (true destroy);
/// `unregister = false` **only** clears state; node stays alive, pool-recycled (e.g. VL slot
/// rebind):
///   - if unregistered, next register: trackGeneration bumps generation since last_ptr==null,
///     the old interaction_index proxy handle expires, hit test returns null -> events swallowed;
///   - not unregistered: generation stable, proxy handle stays valid.
/// Bare interaction refs in Cx pointing into `subtree_root` (focused / hovered / pressed /
/// last_mouse_down + handle) are cleared with **no callback**: freeNode's immediate-release path
/// is a silent teardown (freeNodeNow uses unregisterFocusableSilent); widget state may already be
/// freed with its scope, and clearFocus would call a blur handler writing freed memory.
fn dropRawInteractionRefsInto(self: *Cx, subtree_root: *Node) void {
    const isDesc = struct {
        fn check(node: *Node, ancestor: *Node) bool {
            var current: ?*Node = node;
            while (current) |n| {
                if (n == ancestor) return true;
                current = n.parent;
            }
            return false;
        }
    }.check;

    // WARNING: a bare `*_node` pointer must not be dereferenced (isDesc walks the n.parent chain):
    // it may point to a **freed** node (detachChildRetained -> invalidateReferencesTo hit a stale
    // hovered_node and segfaulted at `current = n.parent`).
    //
    // The paired `*_handle` uses node_registry.resolve, which carries a liveness check.
    // So: **use the handle when present** (resolve failure means node dead, clear the bare
    // pointer directly); only legacy paths without a handle fall back to the bare pointer.
    const stale = struct {
        fn check(cx: *Cx, node: ?*Node, handle: ?NodeHandle) bool {
            const h = handle orelse return false;
            return cx.node_registry.resolve(h, null) == null and node != null;
        }
    }.check;

    if (stale(self, self.focused_node, self.focused_handle)) self.focused_node = null;
    if (self.focused_node) |n| {
        if (isDesc(n, subtree_root)) self.focused_node = null;
    }
    if (self.focused_handle) |h| {
        if (self.node_registry.resolve(h, null)) |n| {
            if (isDesc(n, subtree_root)) self.focused_handle = null;
        } else self.focused_handle = null;
    }

    if (stale(self, self.hovered_node, self.hovered_handle)) self.hovered_node = null;
    if (self.hovered_node) |n| {
        if (isDesc(n, subtree_root)) self.hovered_node = null;
    }
    if (self.hovered_handle) |h| {
        if (self.node_registry.resolve(h, null)) |n| {
            if (isDesc(n, subtree_root)) self.hovered_handle = null;
        } else self.hovered_handle = null;
    }

    const had_pressed = self.pressed_node != null;
    if (stale(self, self.pressed_node, self.pressed_handle)) self.pressed_node = null;
    if (self.pressed_node) |n| {
        if (isDesc(n, subtree_root)) self.pressed_node = null;
    }
    // press target follows subtree release: observers outside subtree (buttons on ancestor) see
    // press end
    if (had_pressed and self.pressed_node == null) self.notifyPressWatchers();
    if (self.pressed_handle) |h| {
        if (self.node_registry.resolve(h, null)) |n| {
            if (isDesc(n, subtree_root)) self.pressed_handle = null;
        } else self.pressed_handle = null;
    }

    if (stale(self, self.last_mouse_down_target, self.last_mouse_down_handle)) self.last_mouse_down_target = null;
    if (self.last_mouse_down_target) |n| {
        if (isDesc(n, subtree_root)) self.last_mouse_down_target = null;
    }
    if (self.last_mouse_down_handle) |h| {
        if (self.node_registry.resolve(h, null)) |n| {
            if (isDesc(n, subtree_root)) self.last_mouse_down_handle = null;
        }
    }
}

pub fn invalidateReferencesToEx(self: *Cx, subtree_root: *Node, unregister: bool) void {
    dropRawInteractionRefsInto(self, subtree_root);
    const isDesc = struct {
        fn check(node: *Node, ancestor: *Node) bool {
            var current: ?*Node = node;
            while (current) |n| {
                if (n == ancestor) return true;
                current = n.parent;
            }
            return false;
        }
    }.check;
    // The bulk layer anchor is a bare `*Node` (see setBulkQuads lifecycle section). The host
    // contract
    // requires "resubmit before anchor destroy", but the **destroy path must backstop it**: the
    // host may
    // render one frame after detach, before the next setBulkQuads (e.g. an early-return path that
    // skips
    // resubmit leaves the anchor on a freed node). appendBulkQuads would then deref `anchor.id`
    // and read an unmapped address in Cx.render.
    //
    // Clear the anchor together with the quads: clearing only the pointer degrades the bulk layer
    // to
    // "append-tail + no-clip" (null anchor semantics), e.g. 20k quads masking chrome.
    // impl: core/bulk_quad_layer.zig dropIfInsideSubtree (parent chain walk in isDesc);
    // called here via view and written back.
    {
        var layer = cx_bulk_quads.bulkQuadLayer(self);
        _ = layer.dropIfInsideSubtree(subtree_root);
        cx_bulk_quads.storeBulkQuadLayer(self, layer);
    }
    if (self.focus_manager.current_focus) |n| {
        if (isDesc(n, subtree_root)) self.focus_manager.clearFocus();
    }
    self.focus_manager.unregisterFocusableSubtree(subtree_root);
    self.dispatcher.invalidateHandlesInSubtree(subtree_root);
    self.drag_manager.handleSubtreeInvalidation(self, subtree_root);
    if (unregister) {
        self.node_registry.unregisterSubtree(subtree_root);
    }
}

pub fn invalidateReferencesTo(self: *Cx, subtree_root: *Node) void {
    self.invalidateReferencesToEx(subtree_root, true);
}

pub fn destroyDetached(self: *Cx, node: *Node) void {
    // contract check uses @panic not assert: assert stripped in ReleaseFast,
    // but "treat already-tree node as loose free" exactly what this primitive guards, caught once
    // in Debug (downstream editor toolbar missing gating). checks like this must exist all builds.
    if (node.parent != null) @panic("destroyDetached: node 仍挂在树上；已上树的节点走 detachChild，不要走这里");
    self.invalidateReferencesTo(node);
    self.freeNode(node);
}

pub fn detachChild(self: *Cx, parent: *Node, child: *Node) void {
    self.invalidateReferencesTo(child);
    parent.removeChildIncremental(child);
}

pub fn detachChildRetained(self: *Cx, parent: *Node, child: *Node) void {
    self.invalidateReferencesTo(child);
    parent.removeChildRetained(child);
}

/// Free a node tree.
/// If the subtree root still has a Scope, first recursively dispose the scope tree, then free
/// node memory, to prevent retained-mode component resource leaks.
/// Skipped when the caller already did clearNodeScopes + dispose.
/// Also consumes the overlay's pending focus restore.
///
/// After closing Modal/Sheet/Popover, focus should return to the control that opened it
/// (`FocusConfig.restore`, default true); `previous_focus` must be read here or focus is lost.
///
/// Handle resolve failure (trigger control already destroyed) is silently skipped: legal,
/// e.g. the whole form including the trigger button is dismounted together by Show.
pub fn drainOverlayFocusRestore(self: *Cx) void {
    const h = self.overlay_stack.pending_focus_restore orelse return;
    self.overlay_stack.pending_focus_restore = null;
    const node = self.node_registry.resolve(h, null) orelse return;
    self.focus_manager.setFocus(node);
}

fn finishDeferredNodeFree(ptr: *anyopaque) void {
    const node: *Node = @ptrCast(@alignCast(ptr));
    const cx: *Cx = @ptrCast(@alignCast(node.pending_free_cx.?));
    node.pending_free_cx = null;
    // Decide before the call: when freeNode frees immediately, `node` is gone.
    const deferred_again = cx.owner.reactive_callback_depth > 0 or cx.tick_depth > 0;
    cx.freeNode(node);
    // The owner queue drains when the reactive depth returns to zero, which can
    // happen inside a tick (and the tick queue can drain inside a reactive
    // callback). freeNode then defers the node again, into the other queue.
    // Entries queued behind it may borrow it (deferDisposalLikeFreeNode is FIFO:
    // node first), so they move with it instead of running ahead of it.
    if (deferred_again) migrateDrainingQueueTail(cx);
}

/// Move what is left of the queue currently being drained behind the node that
/// was just deferred again, preserving order. Postponing a disposal is always
/// safe; running one before an earlier entry is not.
fn migrateDrainingQueueTail(cx: *Cx) void {
    const DeferredQueue = @import("../reactive/deferred_disposal.zig").Queue;
    const target: *DeferredQueue = if (cx.owner.reactive_callback_depth > 0) &cx.owner.deferred_disposals else &cx.deferred_free_nodes;
    const source: *DeferredQueue = if (cx.owner.draining_disposals and target != &cx.owner.deferred_disposals)
        &cx.owner.deferred_disposals
    else if (cx.draining_deferred_frees and target != &cx.deferred_free_nodes)
        &cx.deferred_free_nodes
    else
        return;
    while (source.popFirst()) |entry| target.append(entry, entry.ptr, entry.dispose_fn);
}

pub fn freeNode(self: *Cx, node: *Node) void {
    // sentinel must check before freeing / pending_free_cx (reason: freeNodeNow):
    // freed node memory in Debug is 0xaa, `freeing` reads true, outside double-
    // free silently returns, freeNodeNow sentinel never reached.
    if (node.alive_sentinel != core_node.ALIVE_SENTINEL) {
        @panic("freeNode: 节点已被释放（double free）或内存已损坏");
    }
    if (node.freeing or node.pending_free_cx != null) return;
    @import("node_dirty.zig").bumpLooseInteractionGen();
    if (self.owner.reactive_callback_depth > 0 or self.tick_depth > 0) {
        // Claim before invalidating input references: cancellation hooks
        // can request destruction again. Retained unlink keeps callback
        // contexts alive until the traversal/reactive stack unwinds.
        node.pending_free_cx = @ptrCast(self);
        @import("node_tree.zig").g_retire_gen +%= 1;
        if (node.parent) |parent| parent.removeChildRetained(node);
        self.invalidateReferencesTo(node);
        if (self.owner.reactive_callback_depth > 0) {
            self.owner.deferDisposal(&node.deferred_disposal, @ptrCast(node), &finishDeferredNodeFree);
        } else {
            self.deferred_free_nodes.append(&node.deferred_disposal, @ptrCast(node), &finishDeferredNodeFree);
        }
        return;
    }
    // Immediate external callers must detach first. Internal recursive teardown uses freeNodeNow
    // directly and owns the entire child list.
    // Silently clear Cx references into this subtree (pressed / hovered / focused /
    // last_mouse_down) before free.
    // Otherwise, after a click callback releases the pressed row and before mouseUp cleanup, any
    // before_render hook (animBg reads cx.pressed_node) derefs a freed node.
    // Only clear pointers; don't call invalidateReferencesTo: its clearFocus calls the blur handler
    // (see dropRawInteractionRefsInto).
    dropRawInteractionRefsInto(self, node);
    freeNodeNow(self, node);
}

pub fn deferDisposalLikeFreeNode(
    self: *Cx,
    entry: *@import("../reactive/deferred_disposal.zig").Entry,
    ptr: *anyopaque,
    dispose_fn: *const fn (*anyopaque) void,
) void {
    if (self.owner.reactive_callback_depth > 0) {
        self.owner.deferDisposal(entry, ptr, dispose_fn);
        return;
    }
    if (self.tick_depth > 0) {
        self.deferred_free_nodes.append(entry, ptr, dispose_fn);
        return;
    }
    // fork from freeNode intentionally (secondary audit): depth zero'd but **queue actively
    // draining**,
    // this moment dispose callback sync dismantles consumer (scope cleanup -> pool.deinit), queue
    // tail may still queue
    // nodes borrowing resource. execute now = UAF; append to draining queue tail,
    // `while (popFirst())` pops in same drain, necessarily after remaining.
    if (self.draining_deferred_frees) {
        self.deferred_free_nodes.append(entry, ptr, dispose_fn);
        return;
    }
    if (self.owner.draining_disposals) {
        self.owner.deferred_disposals.append(entry, ptr, dispose_fn);
        return;
    }
    dispose_fn(ptr);
}

pub fn drainDeferredFrees(self: *Cx) void {
    if (self.tick_depth > 0 or self.draining_deferred_frees) return;
    self.draining_deferred_frees = true;
    defer self.draining_deferred_frees = false;
    while (self.deferred_free_nodes.popFirst()) |entry| {
        const ptr = entry.ptr;
        const dispose_fn = entry.dispose_fn;
        dispose_fn(ptr);
    }
}

fn freeNodeNow(self: *Cx, node: *Node) void {
    // sentinel before freeing check: freed memory in Debug written 0xaa,
    // `freeing` reads true silent early-return, double free becomes silent no-op. here it panics.
    if (node.alive_sentinel != core_node.ALIVE_SENTINEL) {
        @panic("freeNode: 节点已被释放（double free）或内存已损坏");
    }
    if (node.freeing) return;
    node.freeing = true;
    @import("node_tree.zig").g_retire_gen +%= 1;
    node.deferred_disposal.cancel();
    node.pending_free_cx = null;
    // focus registry holds bare *Node: must remove before free, else any
    // unregisterFocusableSubtree isDescendantOf parent chain walks freed
    // memory -> segfault (2026-07-30 real: Modal body Button, story switch,
    // scope/freeNode path released subtree bypassing detachChild subtree removal).
    self.focus_manager.unregisterFocusableSilent(node);
    // Silent teardown intentionally skips widget blur handlers, but it
    // must still close the native session before its client is destroyed.
    // Compare identity only: the event context may already be disposed.
    if (self.text_input_session.active_node) |active| {
        if (active.id == node.id) cx_platform.deactivateTextInputSession(self);
    }
    // hook resources may register on external Scope, not subtree root's scope field.
    // uniformly disconnect these back-pointers before node free, prevent later
    // external Scope.dispose() access freed Node.
    hooks_mod.invalidateSubtreeHookState(node);

    if (node.meta.ownership.scope.scope) |scope| {
        clearNodeScopes(node);
        if (!scope.disposed) scope.dispose();
    }
    for (node.children.items) |child| {
        freeNodeNow(self, child);
    }
    // style host destroyed after node scope release: scope style layer free must unlink self from
    // host
    if (node.meta.per_frame.hooks.style_host) |h| {
        node.meta.per_frame.hooks.style_host = null;
        h.destroy(h.ptr);
    }
    if (node.meta.per_frame.hooks.theme_inline) |rec| {
        node.meta.per_frame.hooks.theme_inline = null;
        rec.destroy();
    }
    self.node_registry.noteNodeFreed(node.id);
    // Trigger the cleanup callback (free user-allocated event context etc).
    // **Unlink first, then call**: on_cleanup has three trigger points (here,
    // node_lifecycle.destroy,
    // fireCleanupCallbacks) and any may arrive first. Without unlinking, the same hook runs twice;
    // callbacks are typically "free one-time resource" (ScrollArea cell release underflows its
    // refcount). Extract then null => runs exactly once.
    if (node.meta.ownership.hooks.on_cleanup) |cleanup_handler| {
        node.meta.ownership.hooks.on_cleanup = null;
        cleanup_handler.invoke();
    }
    // must read owned text before elements.destroy
    // else element_id cleared, getText walks standalone path can't get original entry,
    // owned content hangs leaked forever.
    // free owned text content + spans
    if (node.getTextRaw()) |t| {
        if (t.spans_owned) {
            self.allocator.free(t.spans);
        }
        if (t.owned) {
            self.allocator.free(t.content);
        }
    }
    // path heap freed via World.layout_output slot,
    // must precede elements.destroy below (element_id still valid).
    node.releaseAllGeometry(self.allocator);
    // free dynamically allocated test_id
    if (node.frame_state.state_bits.flags.test_id_owned) {
        if (node.meta.ownership.meta.test_id) |tid| {
            self.allocator.free(tid);
        }
    }
    // free Grid config pointers
    if (node.style.ext) |ext| {
        if (ext.grid) |gc| {
            self.allocator.destroy(gc);
        }
        self.allocator.destroy(ext);
    }
    // free Transition slot
    if (node.frame_state.frame_local.runtime.transitions) |ts| {
        self.allocator.destroy(ts);
    }
    // free imperative node animation
    if (node.frame_state.frame_local.runtime.commands) |na| {
        na.deinit();
        self.allocator.destroy(na);
    }
    // Synchronously destroy the World.elements entry.
    // ElementTable.destroy auto-unlinks the parent/child chain; generation++ prevents ABA.
    // Must come after getText/owned content free: once element_id is cleared, getText walks
    // standalone and can't reach the original World entry.
    // **Must use world.destroyElement, not bare elements.destroy**: the latter recycles the element
    // slot (generation++ to free_list) but doesn't clear the content/paint/interaction mirrors.
    // ContentTable.getText reads by index with no generation check, so a recycled slot exposes
    // the prior owner's residual text (e.g. closed Menu items "Cut/Copy/Delete" leaking into a
    // newly mounted DatePicker trigger).
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        // nodes with declared semantic sets: set provider points to component state (usually freed
        // with subtree ancestor scope),
        // must unregister here, subsequent AX callbacks can't call it.
        if (node.behavior.interaction.a11y) |props| {
            if (props.collection != null) {
                self.accessibility_tree.retireCollection(a11y_tree.AXId.node(eid)) catch
                    @panic("OOM: a11y collection retire");
            }
        }
        if (self.world.elements.isValid(eid)) {
            self.world.destroyElement(eid);
        }
        node.element_id_raw = 0xFFFFFFFF;
    }
    node.meta.ownership.scope.scope = null;
    node.invalidateRenderCache();
    node.invalidatePromotedRenderCache();
    node.invalidateSubtreePayloadCache();
    @import("node_lifecycle.zig").releaseStandaloneState(node);
    @import("layout_engine.zig").forgetIntrinsicCache(node.world_id, node.id);
    node.children.deinit(self.allocator);
    // poison (like node_lifecycle.destroy): Allocator.destroy doesn't overwrite, no poison
    // freed node still reads ALIVE + freeing=true, double freeNode silent no-op.
    node.alive_sentinel = core_node.DEAD_SENTINEL;
    self.allocator.destroy(node);
}

pub fn registerScrollCtxCell(self: *Cx, cell: OwnedCell) !void {
    // Do not free from a node/scope callback: that callback may still be on the
    // stack. At a subsequent registration, no completed callback uses the cell.
    var i: usize = 0;
    while (i < self.scroll_ctx_cells.items.len) {
        const entry = self.scroll_ctx_cells.items[i];
        if (entry.can_destroy) |ready| {
            if (ready(entry.ptr)) {
                _ = self.scroll_ctx_cells.swapRemove(i);
                entry.destroyFn(entry.ptr, self.allocator);
                continue;
            }
        }
        i += 1;
    }
    try self.scroll_ctx_cells.append(self.allocator, cell);
}

pub fn freeDetachedNodeAfterScopeDispose(self: *Cx, node: *Node) void {
    hooks_mod.invalidateSubtreeHookState(node);
    clearNodeScopes(node);
    self.freeNode(node);
}

/// A scope-owned, reusable root binding. Detaching does not dispose the scope.
/// A promoted single root retires the prior binding's reverse reference.
pub const NodeScopeBinding = struct {
    scope: *Scope,
    node: ?*Node = null,

    pub fn create(scope: *Scope) !*NodeScopeBinding {
        const binding = try scope.allocator.create(NodeScopeBinding);
        binding.* = .{ .scope = scope };
        try scope.adoptResource(binding, destroy);
        return binding;
    }

    pub fn detach(self: *NodeScopeBinding) void {
        if (self.node) |node| {
            std.debug.assert(node.meta.ownership.scope.node_slot == &self.node);
            node.meta.ownership.scope.scope = null;
            node.meta.ownership.scope.node_slot = null;
            self.node = null;
        }
    }

    pub fn attach(self: *NodeScopeBinding, node: *Node) void {
        self.detach();
        if (node.meta.ownership.scope.node_slot) |old_slot| old_slot.* = null;
        self.node = node;
        node.meta.ownership.scope.scope = self.scope;
        node.meta.ownership.scope.node_slot = &self.node;
    }

    fn destroy(ptr: *anyopaque, allocator: Allocator) void {
        const self: *NodeScopeBinding = @ptrCast(@alignCast(ptr));
        if (self.node) |node| {
            hooks_mod.invalidateSubtreeHookState(node);
            clearNodeScopes(node);
        }
        allocator.destroy(self);
    }
};

pub fn bindScopeToNode(scope: *Scope, node: *Node) !void {
    const binding = try NodeScopeBinding.create(scope);
    binding.attach(node);
}
