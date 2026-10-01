//! Cx 节点生命周期：detach / freeNode（含 tick 期间延迟释放）、
//! 失效 hover/focus/pressed 等原始引用、scope 与节点绑定。
//! 释放顺序与 UAF 防护的约束见各函数注释。

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

/// 集中式悬垂指针清理，当一棵子树即将被销毁时调用
///
/// 清除 Cx/EventDispatcher/FocusManager 中所有可能指向该子树的指针。
/// 替代散落在 control_flow.zig 中的 6 行重复检查代码。
/// 清事件 state 对 subtree 的引用（focused/hovered/pressed 等）。
/// `unregister = true` 时**同时**把 subtree 从 node_registry 中移除（节点真的销毁走这条）。
/// `unregister = false` 时**只**清 state，节点还活着，pool 化复用（例如 VL slot pool 被 rebind）：
///   - 若 unregister 了，下次 register 时 trackGeneration 会因 last_ptr==null 而 bump generation，
///     导致之前 interaction_index 里 proxy 的 handle 瞬间过期，hit test 返回 null -> 事件被吞。
///   - 不 unregister 则 generation 稳定，proxy handle 保持有效。
/// 清掉 Cx 里指进 `subtree_root` 子树的裸交互引用（focused / hovered / pressed /
/// last_mouse_down 及其 handle）。**不触发任何回调**：freeNode 的立即释放路径是静默拆除
/// （freeNodeNow 用 unregisterFocusableSilent），那时 widget 的 state 可能已随 scope 释放，
/// 走 clearFocus 会调 blur handler 写已释放内存。
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

    // ⚠ 裸 `*_node` 指针不能直接解引用（isDesc 会走 n.parent 链）：
    // 它可能指向**已释放**的节点，实测 storybook 里 Popover 挂起时
    // detachChildRetained -> invalidateReferencesTo 会踩到陈旧的
    // hovered_node，segfault 于 core.zig:1572 `current = n.parent`。
    //
    // 配套的 `*_handle` 走 node_registry.resolve，天然带存活校验。
    // 所以：**handle 在时以 handle 为准**（resolve 失败即说明节点已死，
    // 直接清掉裸指针）；只有在没有 handle 的旧路径才回退到裸指针。
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

    if (stale(self, self.pressed_node, self.pressed_handle)) self.pressed_node = null;
    if (self.pressed_node) |n| {
        if (isDesc(n, subtree_root)) self.pressed_node = null;
    }
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
    // 批量层锚点是裸 `*Node`（见 setBulkQuads 的生命周期一节）。宿主契约
    // 要求"锚点销毁前重新提交"，但**销毁路径本身必须兜底**：宿主可能在
    // 摘树之后、下一次 setBulkQuads 之前就渲染一帧（下游应用的 goHome ->
    // teardownChromeScreen 摘掉画布子树，而 applySnapshot 在 homepage 屏
    // 直接早退不再提交 ⇒ 锚点永远停留在已释放的 canvas_host）。此时
    // appendBulkQuads 会解引用 `anchor.id`，在 Cx.render 里读到未映射地址。
    //
    // 锚点连同 quads 一起清掉：只清指针会让批量层退化成"追加末尾 + 不裁剪"
    // （null anchor 的语义），那正是两万 quad 糊住 chrome 的破坏性回归。
    // 实现在 core/bulk_quad_layer.zig 的 dropIfInsideSubtree（含 isDesc 的
    // parent 链遍历）；这里经视图调用并写回。
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
    // 契约检查用 @panic 而不是 assert：assert 在 ReleaseFast 下会被去掉，
    // 而「把已上树节点当游离释放」正是本原语要拦的误用，它在 Debug 下
    // 当场抓到过一次（下游编辑器 toolbar 漏门控）。这类检查必须在所有构建下存在。
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

/// 释放节点树。
/// 若子树根节点仍挂着 Scope，则先递归 dispose 对应的 scope 树，
/// 再释放节点内存，避免保留模式组件的资源泄漏。
/// 已经由调用方 clearNodeScopes + dispose 过的子树会直接跳过这一步。
/// 消费 overlay 的待恢复焦点。
///
/// 关闭 Modal/Sheet/Popover 后，焦点应回到当初打开它的那个控件
/// （`FocusConfig.restore`，默认 true）。此前 `previous_focus` 被写入
/// 但**全仓无人读取**，焦点直接丢失。
///
/// handle 解析失败（触发控件本身已销毁）时静默跳过：这是合法情况，
/// 比如整个表单连同触发按钮一起被 Show 卸载。
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
    cx.freeNode(node);
}

pub fn freeNode(self: *Cx, node: *Node) void {
    // 哨兵必须在 freeing / pending_free_cx 之前检查（理由同 freeNodeNow）：
    // 已释放的节点内存在 Debug 下是 0xaa，`freeing` 读出 true，外部二次
    // freeNode 会在这里静默 return，freeNodeNow 里的哨兵根本到不了。
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
        if (node.parent) |parent| parent.removeChildRetained(node);
        self.invalidateReferencesTo(node);
        if (self.owner.reactive_callback_depth > 0) {
            self.owner.deferDisposal(&node.deferred_disposal, @ptrCast(node), &finishDeferredNodeFree);
        } else {
            self.deferred_free_nodes.append(&node.deferred_disposal, @ptrCast(node), &finishDeferredNodeFree);
        }
        return;
    }
    // Immediate external callers must detach first. Internal recursive
    // teardown uses freeNodeNow directly and owns the entire child list.
    // 释放前静默清掉 Cx 里指进这棵子树的裸引用（pressed / hovered / focused /
    // last_mouse_down）。否则在"点击回调里释放被按下的行"之后、mouseUp 收尾清
    // pressed_node 之前，任何 before_render hook（animBg 读 cx.pressed_node）都会解引用已释放节点。
    // 只清指针不走 invalidateReferencesTo：后者会 clearFocus -> 调 blur handler（见 dropRawInteractionRefsInto）。
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
    // 与 freeNode 刻意分叉的一处（二审）：深度已归零、但某条队列**正在 drain**,
    // 这是 dispose 回调里同步拆除消费方（scope cleanup -> pool.deinit）的时刻，队列后段可能还排着
    // 借用这份资源的节点。此时当场执行就是 UAF；追加到正在 drain 的那条队列末尾，
    // `while (popFirst())` 会在同一次 drain 里把它弹到，且必然排在残余节点之后。
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
    // 哨兵先于 freeing 检查：释放后的内存在 Debug 下被写成 0xaa，
    // `freeing` 会读出 true 从而静默 early-return，那样 double free
    // 就变成了无声的 no-op。这里让它当场 panic。
    if (node.alive_sentinel != core_node.ALIVE_SENTINEL) {
        @panic("freeNode: 节点已被释放（double free）或内存已损坏");
    }
    if (node.freeing) return;
    node.freeing = true;
    node.deferred_disposal.cancel();
    node.pending_free_cx = null;
    // 焦点注册表持裸 *Node：释放前必须摘除，否则后续任何
    // unregisterFocusableSubtree 的 isDescendantOf 沿 parent 链走到已释放
    // 内存 -> segfault（2026-07-30 实测：Modal body 放 Button，story 切换
    // 经 scope/freeNode 路径释放子树绕过了 detachChild 的 subtree 摘除）。
    self.focus_manager.unregisterFocusableSilent(node);
    // Silent teardown intentionally skips widget blur handlers, but it
    // must still close the native session before its client is destroyed.
    // Compare identity only: the event context may already be disposed.
    if (self.text_input_session.active_node) |active| {
        if (active.id == node.id) cx_platform.deactivateTextInputSession(self);
    }
    // Hook 资源可能注册在外部 Scope 上，而不是当前子树根节点的 scope 字段。
    // 节点释放前统一断开这些回指，避免稍后外部 Scope.dispose() 访问已释放的 Node。
    hooks_mod.invalidateSubtreeHookState(node);

    if (node.meta.ownership.scope.scope) |scope| {
        clearNodeScopes(node);
        if (!scope.disposed) scope.dispose();
    }
    for (node.children.items) |child| {
        freeNodeNow(self, child);
    }
    self.node_registry.noteNodeFreed(node.id);
    // 触发 cleanup 回调 (释放用户分配的事件上下文等)。
    // **先摘再调**：on_cleanup 有三个触发点（这里、node_lifecycle.destroy、
    // fireCleanupCallbacks），谁都可能先到。不摘的话同一个 hook 会被调两次，
    // 而回调普遍是"释放一次性资源"语义（ScrollArea 的 cell release 实测因此
    // refcount 下溢）。取出即置空 ⇒ 天然只此一次。
    if (node.meta.ownership.hooks.on_cleanup) |cleanup_handler| {
        node.meta.ownership.hooks.on_cleanup = null;
        cleanup_handler.invoke();
    }
    // 必须在 elements.destroy 前 read owned text 释放
    // 否则 element_id 被清后 getText 走 standalone path 拿不到原 entry，
    // owned content 永远悬空泄漏。
    // 释放 owned 的 text content 和 spans
    if (node.getText()) |t| {
        if (t.spans_owned) {
            self.allocator.free(t.spans);
        }
        if (t.owned) {
            self.allocator.free(t.content);
        }
    }
    // path 堆内存经 World.layout_output slot 释放，
    // 必须在下方 elements.destroy 之前（element_id 还有效）。
    node.releaseAllGeometry(self.allocator);
    // 释放动态分配的 test_id
    if (node.frame_state.state_bits.flags.test_id_owned) {
        if (node.meta.ownership.meta.test_id) |tid| {
            self.allocator.free(tid);
        }
    }
    // 释放 Grid 配置指针
    if (node.style.ext) |ext| {
        if (ext.grid) |gc| {
            self.allocator.destroy(gc);
        }
        self.allocator.destroy(ext);
    }
    // 释放 Transition 槽
    if (node.frame_state.frame_local.runtime.transitions) |ts| {
        self.allocator.destroy(ts);
    }
    // 释放命令式节点动画
    if (node.frame_state.frame_local.runtime.commands) |na| {
        na.deinit();
        self.allocator.destroy(na);
    }
    // 同步销毁 World.elements 上的 entry。
    // ElementTable.destroy 内部会自动 unlink 父子链；generation++ 防 ABA。
    // 必须在 getText/owned content 释放之后做，因为 element_id 被
    // 清后 getText 走 standalone path 拿不到原 World entry。
    // **必须走 world.destroyElement 而非裸 elements.destroy**：后者只回收
    // element slot（generation++ 进 free_list），但不清 content/paint/interaction
    // 镜像表。ContentTable.getText 仅按 index 读、不校验 generation，于是 slot 被
    // 下一个节点复用时会读到上一个 owner 的残留 text（典型：切走的 Menu 弹层项
    // "Cut/Copy/Delete" 漏进新挂载的 DatePicker trigger -> content 串台/空白）。
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        if (self.world.elements.isValid(eid)) {
            self.world.destroyElement(eid);
        }
        node.element_id_raw = 0xFFFFFFFF;
    }
    node.meta.ownership.scope.scope = null;
    node.invalidateRenderCache();
    node.invalidatePromotedRenderCache();
    node.invalidateSubtreePayloadCache();
    node.children.deinit(self.allocator);
    // 投毒（同 node_lifecycle.destroy）：Allocator.destroy 不覆写内存，不投毒的话
    // 释放后的节点仍读出 ALIVE + freeing=true，二次 freeNode 会静默 no-op。
    node.alive_sentinel = core_node.DEAD_SENTINEL;
    self.allocator.destroy(node);
}

pub fn registerScrollCtxCell(self: *Cx, cell: OwnedCell) !void {
    try self.scroll_ctx_cells.append(self.allocator, cell);
}

pub fn freeDetachedNodeAfterScopeDispose(self: *Cx, node: *Node) void {
    hooks_mod.invalidateSubtreeHookState(node);
    clearNodeScopes(node);
    self.freeNode(node);
}

pub fn bindScopeToNode(scope: *Scope, node: *Node) !void {
    const ScopeBinding = struct {
        node: ?*Node,
    };
    const binding = try scope.allocator.create(ScopeBinding);
    binding.* = .{ .node = node };
    errdefer scope.allocator.destroy(binding);

    try scope.registerResource(@ptrCast(binding), struct {
        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            const typed: *ScopeBinding = @ptrCast(@alignCast(ptr));
            if (typed.node) |bound_node| {
                hooks_mod.invalidateSubtreeHookState(bound_node);
                clearNodeScopes(bound_node);
            }
            allocator.destroy(typed);
        }
    }.destroy);
    // A component can promote a child node to an outer scope. Retire the
    // old back-reference only after registration succeeds, otherwise that
    // scope would later dereference the node freed by its new owner.
    if (node.meta.ownership.scope.node_slot) |old_slot| old_slot.* = null;
    node.meta.ownership.scope.scope = scope;
    node.meta.ownership.scope.node_slot = &binding.node;
}
