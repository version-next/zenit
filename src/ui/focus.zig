/// Focus Manager - 焦点管理
///
/// 管理 UI 节点的焦点状态:
/// - 跟踪当前焦点节点
/// - Tab 键导航 (前进/后退)
/// - 焦点事件 (focus/blur)
/// - 可聚焦节点注册
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core.zig");
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const NodeRegistry = core.NodeRegistry;
const events_mod = @import("events.zig");
const FocusReason = events_mod.FocusReason;
const FocusEvent = events_mod.FocusEvent;
const Event = events_mod.Event;
const event_dispatcher_mod = @import("event_dispatcher.zig");
const system_sdk = @import("system_sdk");
const A11yRole = core.A11yRole;

/// Focus Scope 配置
pub const FocusScopeConfig = struct {
    /// 是否为焦点陷阱 (Tab 不能逃出)
    trap: bool = false,
    /// 进入 scope 时自动聚焦第一个 focusable 节点
    auto_focus: bool = false,
};

/// Focus scope 栈深度上限（v0.1-P6 8→64；v0.4 改 ArrayList 完全去限）。
///
/// **v0.3-P6 决策记录**：当前 64 容量远超任何实际 GUI scope 嵌套深度
/// （macOS 一般 < 5 层 modal）；ArrayList 化收益 vs callsite 改动比不划算，
/// 留 v0.4 配合 a11y 焦点 / 键盘焦点彻底分离一起做。
pub const SCOPE_STACK_CAP: usize = 64;
/// Scoped focus order 缓冲（v0.1-P6 64→512）
pub const SCOPED_BUF_CAP: usize = 512;

/// 焦点管理器
pub const FocusManager = struct {
    allocator: Allocator,

    /// 当前拥有焦点的节点
    current_focus: ?*Node = null,
    current_focus_handle: ?NodeHandle = null,

    // Focus changes are synchronous, but callbacks may start a newer change.
    // Only that newest transition may continue publishing state/events.
    transition_epoch: u64 = 0,
    transition_depth: usize = 0,

    /// Tab 顺序表 (可聚焦节点列表)
    focus_order: std.ArrayList(*Node),

    /// 事件调度器引用 (用于分发 focus/blur 事件冒泡)
    dispatcher: ?*event_dispatcher_mod.EventDispatcher = null,

    /// 无障碍桥接
    a11y_bridge: AccessibilityBridge = .{},

    /// 节点注册表（用于跨帧通过 handle 解析当前焦点）
    registry: ?*NodeRegistry = null,

    /// Called after blur/focus handlers and the focus handle update have all
    /// settled. Cx uses this hook to reconcile the window-level native
    /// text-input session; widgets must not toggle that session themselves.
    ///
    /// This hook covers only focus changes that go through setFocusWithReason.
    /// The paths that change effective focus *without* dispatching events —
    /// `unregisterFocusableSubtree` + `restoreFocusAfterSubtreeRebuild` during
    /// a runtime-index rebuild, and `unregisterFocusableSilent` during node
    /// teardown — are reconciled by Cx at their own boundary instead. Any new
    /// path that writes `current_focus` directly owes the same reconcile.
    settled_context: ?*anyopaque = null,
    on_focus_settled: ?*const fn (context: *anyopaque) void = null,

    /// Focus Scope 栈 (Phase 6: 8 → 64；完整 ArrayList 化在 Phase 7 focus 重构时做)
    scope_stack: [SCOPE_STACK_CAP]?*Node = [_]?*Node{null} ** SCOPE_STACK_CAP,
    scope_stack_handles: [SCOPE_STACK_CAP]?NodeHandle = [_]?NodeHandle{null} ** SCOPE_STACK_CAP,
    scope_count: u8 = 0,

    /// 焦点记忆 (每层 scope 保存进入前的焦点 ID)
    scope_memory: [SCOPE_STACK_CAP]?u32 = [_]?u32{null} ** SCOPE_STACK_CAP,
    scope_memory_handles: [SCOPE_STACK_CAP]?NodeHandle = [_]?NodeHandle{null} ** SCOPE_STACK_CAP,

    /// Scoped focus order 缓冲区 (Phase 6: 64 → 512)
    scoped_buf: [SCOPED_BUF_CAP]*Node = undefined,

    /// 最近一次 focus 变化的原因 (用于 :focus-visible 判断)
    last_focus_reason: FocusReason = .programmatic,

    pub fn init(allocator: Allocator) FocusManager {
        return .{
            .allocator = allocator,
            .focus_order = .{},
        };
    }

    pub fn deinit(self: *FocusManager) void {
        self.focus_order.deinit(self.allocator);
    }

    pub fn setRegistry(self: *FocusManager, registry: *NodeRegistry) void {
        self.registry = registry;
    }

    fn trackedHandleFor(self: *FocusManager, node: *Node) ?NodeHandle {
        const registry = self.registry orelse return null;
        const generation = registry.trackGeneration(node) catch return registry.handleFor(node);
        return .{ .id = node.id, .generation = generation };
    }

    /// 设置焦点到指定节点
    /// 触发 blur(旧节点) 和 focus(新节点) 事件
    pub fn setFocus(self: *FocusManager, node: ?*Node) void {
        self.setFocusWithReason(node, .programmatic);
    }

    /// Identity handle taken while `node` is known to be alive. Returns null
    /// only when no identity can be established (no registry, or generation
    /// tracking failed on OOM). Registry-backed transitions fail closed when
    /// no identity can be established; registry-free callers own lifetime.
    fn identityHandleFor(self: *FocusManager, node: *Node) ?NodeHandle {
        const registry = self.registry orelse return null;
        const generation = registry.trackGeneration(node) catch return null;
        return .{ .id = node.id, .generation = generation };
    }

    /// Whether `node`'s memory survived the application callbacks run since
    /// `identity` was taken. Compares identity only (generation + pointer via
    /// `isCurrentIdentity`) and never dereferences `node`: a synchronous
    /// blur/focus handler may have freed it, and freeNode frees immediately
    /// outside tick/reactive depth (noteNodeFreed invalidates the identity).
    /// A registry-backed node with no identity must not cross callbacks.
    /// Registry-free callers retain their nodes for the whole transition.
    fn survivedCallbacks(self: *FocusManager, identity: ?NodeHandle, node: *Node) bool {
        const registry = self.registry orelse return true;
        const h = identity orelse return false;
        return registry.isCurrentIdentity(h, node);
    }

    /// Whether a live node may still become the focus owner. A node claimed
    /// for destruction (freeNode deferred inside a reactive callback / tick)
    /// is kept in memory but already unlinked from the tree; focusing it
    /// would publish a pointer that dies at the next drain.
    fn canReceiveFocus(self: *FocusManager, identity: ?NodeHandle, node: *Node) bool {
        if (!self.survivedCallbacks(identity, node)) return false;
        return !node.freeing and node.pending_free_cx == null;
    }

    /// Deliver once. An ignored event was still delivered; only an absent
    /// dispatcher/registry entry requires the mount-time direct fallback.
    fn deliverFocusEvent(self: *FocusManager, node: *Node, event: Event) void {
        if (self.dispatcher) |dispatcher| {
            const reachable = if (dispatcher.registry) |registry|
                registry.resolve(registry.handleFor(node), null) == node
            else
                true;
            if (reachable) {
                _ = dispatcher.dispatch(event, node);
                return;
            }
        }
        if (node.behavior.events.on_event) |handler| {
            _ = handler(event, node.behavior.events.event_context);
        }
    }

    fn finishFocusTransition(self: *FocusManager) void {
        self.transition_depth -= 1;
        if (self.transition_depth != 0) return;
        // Publish only the settled owner, never an outer transition's stale
        // local target. The settled hook may itself request a new transition.
        self.a11y_bridge.notifyFocusChange(self.getFocused());
        if (self.on_focus_settled) |callback| {
            if (self.settled_context) |context| callback(context);
        }
    }

    /// Synchronous, latest-request-wins focus transitions. Withdraw the old
    /// owner before blur callbacks, so a reentrant request cannot blur it twice.
    /// After each callback boundary, a superseded transition stops immediately.
    /// Identity checks independently protect targets destroyed by callbacks.
    /// Without a registry the caller must retain nodes across callbacks.
    pub fn setFocusWithReason(self: *FocusManager, node: ?*Node, reason: FocusReason) void {
        const old_node = self.getFocused();
        if (old_node == node) {
            // During blur, null is the published owner but an outer transition
            // may still intend to focus a target. An explicit clear cancels it.
            if (node == null and self.transition_depth != 0) {
                self.transition_epoch = std.math.add(u64, self.transition_epoch, 1) catch @panic("focus epoch exhausted");
                self.last_focus_reason = reason;
            }
            return;
        }

        const old_id: ?u32 = if (old_node) |old| old.id else null;
        const new_id: ?u32 = if (node) |new| new.id else null;
        const old_identity = if (old_node) |old| self.identityHandleFor(old) else null;
        const new_identity = if (node) |new| self.identityHandleFor(new) else null;
        // Never downgrade a registry-backed transition to unchecked pointers
        // if identity allocation fails. Preserve the current owner instead.
        if (node != null and self.registry != null and new_identity == null) return;

        self.transition_epoch = std.math.add(u64, self.transition_epoch, 1) catch @panic("focus epoch exhausted");
        const epoch = self.transition_epoch;
        self.transition_depth += 1;
        defer self.finishFocusTransition();

        self.current_focus = null;
        self.current_focus_handle = null;
        self.last_focus_reason = reason;
        if (old_node) |old| {
            old.markRenderDirty();
            if (old.behavior.events.on_blur) |handler| handler.invoke();
            if (self.transition_epoch != epoch) return;
            if (self.survivedCallbacks(old_identity, old)) {
                self.deliverFocusEvent(old, .{ .blur = .{
                    .related_node_id = new_id,
                    .reason = reason,
                } });
                if (self.transition_epoch != epoch) return;
            }
        }

        if (node) |new| {
            if (!self.canReceiveFocus(new_identity, new)) return;
            self.current_focus = new;
            self.current_focus_handle = new_identity;
            new.markRenderDirty();
            if (new.behavior.events.on_focus) |handler| handler.invoke();
            if (self.transition_epoch != epoch) return;
            if (self.canReceiveFocus(new_identity, new) and self.getFocused() == new) {
                self.deliverFocusEvent(new, .{ .focus = .{
                    .related_node_id = old_id,
                    .reason = reason,
                } });
            }
        }
    }

    /// 清除焦点
    pub fn clearFocus(self: *FocusManager) void {
        self.setFocusWithReason(null, .programmatic);
    }

    /// 焦点持有者的回调上下文即将销毁（组件 scope dispose，节点可能还挂在树上）：
    /// 撤掉焦点但**不调用** blur 回调 / 不派发 blur 事件——那些 handler 读的正是
    /// 正在释放的状态，且其依赖的子 scope/signal 可能已先一步释放。
    /// a11y 与原生输入会话照常同步。节点仍留在 focus_order 里。
    pub fn abandonFocus(self: *FocusManager, node: *Node) void {
        const owns = self.current_focus == node or
            (if (self.current_focus_handle) |h| h.id == node.id else false);
        if (!owns) return;
        self.current_focus = null;
        self.current_focus_handle = null;
        self.a11y_bridge.notifyFocusChange(null);
        if (self.on_focus_settled) |callback| {
            if (self.settled_context) |context| callback(context);
        }
    }

    /// 注册可聚焦节点
    pub fn registerFocusable(self: *FocusManager, node: *Node) !void {
        // 避免重复注册
        for (self.focus_order.items) |n| {
            if (n == node) return;
        }
        try self.focus_order.append(self.allocator, node);
    }

    pub fn clearFocusOrder(self: *FocusManager) void {
        self.focus_order.clearRetainingCapacity();
    }

    pub fn appendFocusableUnsorted(self: *FocusManager, node: *Node) !void {
        const is_focusable = node.behavior.interaction.focusable or node.behavior.interaction.tab_index != null;
        const excluded_from_tab = if (node.behavior.interaction.tab_index) |ti| ti < 0 else false;
        if (is_focusable and !excluded_from_tab) {
            try self.focus_order.append(self.allocator, node);
        }
    }

    pub fn finalizeFocusOrder(self: *FocusManager) void {
        if (self.focus_order.items.len <= 1) return;
        // 排序键：tab_index（正数升序在前），相同则**真实树序**。只靠稳定排序保持
        // 插入序是不够的：子树增量重建会把重灌的节点追加到末尾，插入序≠树序，
        // Tab 顺序随之错乱（子树里的可聚焦节点被挪到最后）。
        std.sort.block(*Node, self.focus_order.items, {}, struct {
            fn lessThan(_: void, a: *Node, b: *Node) bool {
                const a_idx = effectiveTabOrder(a);
                const b_idx = effectiveTabOrder(b);
                if (a_idx != b_idx) return a_idx < b_idx;
                return compareTreeOrder(a, b) == .lt;
            }
        }.lessThan);
    }

    /// 静默移除（节点释放路径用）：不触发 blur 回调 —— 释放期 handler 上下文
    /// 可能已随 scope 销毁，invoke 即 UAF。只摘链 + 清 current_focus。
    pub fn unregisterFocusableSilent(self: *FocusManager, node: *Node) void {
        // 只做指针/句柄比较，绝不能走 getFocused()：teardown 递归释放中
        // current_focus 可能指向早先已释放的兄弟节点，getFocused 的 cached
        // 回退分支会解引用它 → UAF/segfault（下游应用实测必现）。
        if (self.current_focus == node) {
            self.current_focus = null;
            self.current_focus_handle = null;
        } else if (self.current_focus_handle) |h| {
            if (h.id == node.id) {
                self.current_focus = null;
                self.current_focus_handle = null;
            }
        }
        for (self.focus_order.items, 0..) |n, i| {
            if (n == node) {
                _ = self.focus_order.orderedRemove(i);
                return;
            }
        }
    }

    /// 运行时索引**增量重建**后恢复焦点（core.rebuildDirtyRuntimeSubtrees 专用）：
    /// 重建只是 registry/focus_order 的摘除+重灌，节点身份未变（同指针同 id，
    /// 已随 rebuild 重新注册）。不触发 blur/focus 事件 —— 焦点在语义上从未
    /// 离开过该节点；走 setFocus 会派发一对假 blur/focus，让 input 类组件
    /// 关掉原生输入闸。
    pub fn restoreFocusAfterSubtreeRebuild(self: *FocusManager, node: *Node) void {
        self.current_focus = node;
        self.current_focus_handle = self.trackedHandleFor(node);
    }

    /// 移除可聚焦节点
    pub fn unregisterFocusable(self: *FocusManager, node: *Node) void {
        for (self.focus_order.items, 0..) |n, i| {
            if (n == node) {
                // Do not retain a mutable-list index across application code.
                // A blur callback may unregister again, destroy this node, or
                // intentionally re-register it for a new interaction lifetime.
                _ = self.focus_order.orderedRemove(i);
                if (self.getFocused() == node) {
                    self.setFocusWithReason(null, .programmatic);
                }
                return;
            }
        }
    }

    pub fn unregisterFocusableSubtree(self: *FocusManager, root: *Node) void {
        var write_idx: usize = 0;
        var removed_focused = false;
        const focused = self.getFocused();
        for (self.focus_order.items) |node| {
            if (node.isDescendantOf(root)) {
                if (focused == node) removed_focused = true;
                continue;
            }
            self.focus_order.items[write_idx] = node;
            write_idx += 1;
        }
        self.focus_order.items.len = write_idx;
        if (removed_focused) {
            self.current_focus = null;
            self.current_focus_handle = null;
        }
    }

    /// 焦点移到下一个可聚焦节点 (Tab)
    pub fn focusNext(self: *FocusManager) void {
        self.focusStep(.forward);
    }

    /// 焦点移到上一个可聚焦节点 (Shift+Tab)
    pub fn focusPrev(self: *FocusManager) void {
        self.focusStep(.backward);
    }

    /// Tab / Shift+Tab：从当前焦点沿 order 前进 / 后退，跳过位于 display:none 子树里的
    /// 节点（focus_order 在结构变化时收集，display 切换不重收——可见性在遍历时判定）。
    fn focusStep(self: *FocusManager, dir: enum { forward, backward }) void {
        const order = self.scopedFocusOrder();
        if (order.len == 0) return;

        var start: usize = if (dir == .forward) order.len - 1 else 0; // 无当前焦点：从首 / 尾开始
        if (self.getFocused()) |current| {
            for (order, 0..) |n, i| {
                if (n == current) {
                    start = i;
                    break;
                }
            }
        }
        var i = start;
        for (0..order.len) |_| {
            i = if (dir == .forward) (i + 1) % order.len else (if (i == 0) order.len - 1 else i - 1);
            if (order[i].isDisplayedInTree()) {
                self.setFocusWithReason(order[i], .tab);
                return;
            }
        }
    }

    /// 获取当前焦点节点
    pub fn getFocused(self: *FocusManager) ?*Node {
        if (self.registry) |registry| {
            if (registry.resolve(self.current_focus_handle, null)) |resolved| {
                self.current_focus = resolved;
                return resolved;
            }
            if (self.current_focus_handle != null) {
                if (self.current_focus) |cached| {
                    if (registry.isCurrentIdentity(self.current_focus_handle.?, cached)) {
                        return cached;
                    }
                }
                self.current_focus = null;
                self.current_focus_handle = null;
                return null;
            }
        }
        return self.current_focus;
    }

    /// 检查节点是否拥有焦点
    pub fn isFocused(self: *FocusManager, node: *Node) bool {
        return self.getFocused() == node;
    }

    /// 从节点树自动收集可聚焦节点，按 tab_index 排序
    /// 排序规则（对齐 HTML tabindex 语义）：
    /// 1. tab_index > 0 的节点排前面，按 tab_index 升序，相同则按树序
    /// 2. tab_index == 0 或 null（但 focusable=true）的节点排后面，按树序
    /// 3. tab_index == -1 的节点不加入 focus_order（仅可通过 click/setFocus 聚焦）
    pub fn collectFocusableNodes(self: *FocusManager, root: *Node) !void {
        self.clearFocusOrder();
        try self.collectRecursive(root);
        self.finalizeFocusOrder();
    }

    pub fn replaceDefaultOrderSubtree(self: *FocusManager, root: *Node) !void {
        var first_removed_index: ?usize = null;
        var write_idx: usize = 0;

        for (self.focus_order.items, 0..) |node, i| {
            if (node.isDescendantOf(root)) {
                if (first_removed_index == null) first_removed_index = i;
                continue;
            }
            self.focus_order.items[write_idx] = node;
            write_idx += 1;
        }
        self.focus_order.items.len = write_idx;

        var collected = std.ArrayList(*Node){};
        defer collected.deinit(self.allocator);
        try collectDefaultOrderRecursive(root, &collected, self.allocator);

        const focused = self.getFocused();
        if (focused) |node| {
            if (node.isDescendantOf(root) and !sliceContainsNode(collected.items, node)) {
                self.setFocusWithReason(null, .programmatic);
            }
        }

        if (collected.items.len == 0) return;

        const insert_idx = first_removed_index orelse self.findDefaultInsertIndex(root);
        try self.focus_order.ensureUnusedCapacity(self.allocator, collected.items.len);
        const old_len = self.focus_order.items.len;
        self.focus_order.items.len = old_len + collected.items.len;
        std.mem.copyBackwards(
            *Node,
            self.focus_order.items[insert_idx + collected.items.len .. self.focus_order.items.len],
            self.focus_order.items[insert_idx..old_len],
        );
        @memcpy(self.focus_order.items[insert_idx .. insert_idx + collected.items.len], collected.items);
    }

    /// 计算节点的有效排序优先级
    /// tab_index > 0 → 直接使用 (1, 2, 3...)
    /// tab_index == 0 或 null (focusable=true) → 大数 (保持树序在后面)
    fn effectiveTabOrder(node: *Node) i64 {
        if (node.behavior.interaction.tab_index) |ti| {
            if (ti > 0) return ti;
            // ti == 0 按树序排在正数之后
            return std.math.maxInt(i32);
        }
        // null (focusable=true) 等同于 0，按树序
        return std.math.maxInt(i32);
    }

    fn collectRecursive(self: *FocusManager, node: *Node) !void {
        try self.appendFocusableUnsorted(node);

        for (node.children.items) |child| {
            try self.collectRecursive(child);
        }
    }

    fn findDefaultInsertIndex(self: *FocusManager, root: *Node) usize {
        var idx: usize = 0;
        while (idx < self.focus_order.items.len) : (idx += 1) {
            const node = self.focus_order.items[idx];
            if (effectiveTabOrder(node) != std.math.maxInt(i32)) continue;
            if (compareTreeOrder(root, node) == .lt) return idx;
        }
        return self.focus_order.items.len;
    }

    // ---- Focus Scope ----

    /// 推入 Focus Scope (如 Modal 打开时)
    /// 保存当前焦点到记忆栈，auto_focus 时聚焦 scope 内第一个节点
    pub fn pushScope(self: *FocusManager, scope_node: *Node) void {
        if (self.scope_count >= self.scope_stack.len) return;

        // 保存当前焦点 ID 到记忆栈
        self.scope_memory[self.scope_count] = if (self.getFocused()) |f| f.id else null;
        self.scope_memory_handles[self.scope_count] = self.current_focus_handle;

        self.scope_stack[self.scope_count] = if (self.registry == null) scope_node else null;
        self.scope_stack_handles[self.scope_count] = self.trackedHandleFor(scope_node);
        self.scope_count += 1;

        // auto_focus: 聚焦 scope 内第一个 focusable 节点
        if (scope_node.behavior.interaction.focus_scope) |cfg| {
            if (cfg.auto_focus) {
                const order = self.scopedFocusOrder();
                if (order.len > 0) {
                    self.setFocus(order[0]);
                }
            }
        }
    }

    /// 弹出 Focus Scope，恢复之前的焦点
    pub fn popScope(self: *FocusManager) void {
        if (self.scope_count == 0) return;
        self.scope_count -= 1;
        self.scope_stack[self.scope_count] = null;
        self.scope_stack_handles[self.scope_count] = null;

        // 恢复记忆的焦点
        if (self.scope_memory_handles[self.scope_count]) |saved_handle| {
            self.scope_memory_handles[self.scope_count] = null;
            self.scope_memory[self.scope_count] = null;
            if (self.registry) |registry| {
                if (registry.resolve(saved_handle, null)) |saved_node| {
                    self.setFocus(saved_node);
                    return;
                }
            }
        } else if (self.scope_memory[self.scope_count]) |saved_id| {
            self.scope_memory[self.scope_count] = null;
            for (self.focus_order.items) |node| {
                if (node.id == saved_id) {
                    self.setFocus(node);
                    return;
                }
            }
        }
        // 保存的节点已不存在，清除焦点
        self.clearFocus();
    }

    /// 获取当前活跃的 scope 节点
    pub fn activeScope(self: *FocusManager) ?*Node {
        if (self.scope_count == 0) return null;
        if (self.registry) |registry| {
            if (registry.resolve(self.scope_stack_handles[self.scope_count - 1], null)) |resolved| {
                self.scope_stack[self.scope_count - 1] = resolved;
                return resolved;
            }
            // 有 registry 却解析失败 = scope 节点已释放；缓存的裸指针此时悬垂，
            // 不能回退去用它（Tab 会解引用已释放节点）。
            return null;
        }
        return self.scope_stack[self.scope_count - 1];
    }

    /// 获取当前 scope 内的 focus order
    /// 如果有 trap scope，只返回 scope 内的 focusable 节点
    pub fn scopedFocusOrder(self: *FocusManager) []*Node {
        const scope = self.activeScope() orelse return self.focus_order.items;

        // 检查 scope 是否为 trap
        const is_trap = if (scope.behavior.interaction.focus_scope) |cfg| cfg.trap else false;
        if (!is_trap) return self.focus_order.items;

        // 过滤出 scope 内的节点
        var count: usize = 0;
        for (self.focus_order.items) |node| {
            if (count >= self.scoped_buf.len) break;
            if (node.isDescendantOf(scope)) {
                self.scoped_buf[count] = node;
                count += 1;
            }
        }
        return self.scoped_buf[0..count];
    }
};

fn collectDefaultOrderRecursive(node: *Node, out: *std.ArrayList(*Node), allocator: Allocator) !void {
    const is_focusable = node.behavior.interaction.focusable or node.behavior.interaction.tab_index != null;
    const excluded_from_tab = if (node.behavior.interaction.tab_index) |ti| ti < 0 else false;
    const positive_tab_index = if (node.behavior.interaction.tab_index) |ti| ti > 0 else false;
    if (is_focusable and !excluded_from_tab and !positive_tab_index) {
        try out.append(allocator, node);
    }

    for (node.children.items) |child| {
        try collectDefaultOrderRecursive(child, out, allocator);
    }
}

fn sliceContainsNode(nodes: []const *Node, target: *Node) bool {
    for (nodes) |node| {
        if (node == target) return true;
    }
    return false;
}

fn compareTreeOrder(a: *Node, b: *Node) std.math.Order {
    if (a == b) return .eq;

    var a_buf: [128]*Node = undefined;
    var b_buf: [128]*Node = undefined;
    const a_path = buildPathToRoot(a, a_buf[0..]);
    const b_path = buildPathToRoot(b, b_buf[0..]);

    var common: usize = 0;
    while (common < a_path.len and common < b_path.len and a_path[common] == b_path[common]) {
        common += 1;
    }

    // 不在同一棵树（portal 挂在别处的浮层等）：无从比较，交给稳定排序保持原序。
    // 缺这条时 common == 0 会读 a_path[-1]。
    if (common == 0) return .eq;
    if (common == a_path.len) return .lt;
    if (common == b_path.len) return .gt;

    const parent = a_path[common - 1];
    const a_child = a_path[common];
    const b_child = b_path[common];

    for (parent.children.items) |child| {
        if (child == a_child) return .lt;
        if (child == b_child) return .gt;
    }

    return .eq;
}

fn buildPathToRoot(node: *Node, buf: []*Node) []*Node {
    var count: usize = 0;
    var current: ?*Node = node;
    while (current != null and count < buf.len) : (current = current.?.parent) {
        buf[count] = current.?;
        count += 1;
    }
    // 防 silent truncation — 128 层是 UI tree 极限上限（DOM 几百层
    // 算病态），但 silent truncate 会让 compareTreeOrder 错位。debug build 显式
    // panic，prod build 仍降级返截断 path（保留 v0.5 行为，避免线上崩）。
    if (current != null) {
        if (std.debug.runtime_safety) {
            std.debug.panic("focus.zig: buildPathToRoot exceeded buf.len={d}, tree too deep", .{buf.len});
        }
    }
    std.mem.reverse(*Node, buf[0..count]);
    return buf[0..count];
}

// ============================================================================
// Accessibility bridge (was src/ui/accessibility.zig — merged here in v0.5-P6)
//
// FocusManager 已持有 a11y_bridge 字段，把 bridge 定义内联到此文件去除独立 file。
// 完整 a11y_tree 投影 + nsaccessibility_router 路径在 src/ui/a11y/；本 bridge 是
// 单点 notify 兼容层（macOS NSAccessibility / Linux AT-SPI / Windows UIA 单调用入口）。
// ============================================================================

pub const AccessibilityBridge = struct {
    enabled: bool = false,
    /// Cx's retained accessibility tree owns precise element-level focus
    /// notifications. Standalone users of this compatibility bridge keep the
    /// historical automatic snapshot behavior.
    automatic_focus_notifications: bool = true,
    sdk: ?*system_sdk.SystemSdk = null,
    window_id: system_sdk.events.WindowId = 1,

    pub fn attachSystemSdk(self: *AccessibilityBridge, sdk: ?*system_sdk.SystemSdk, window_id: system_sdk.events.WindowId) void {
        self.sdk = sdk;
        self.window_id = window_id;
        self.enabled = if (sdk) |bound_sdk| bound_sdk.getCapabilities().has(.accessibility) else false;
    }

    pub fn clearSystemSdk(self: *AccessibilityBridge) void {
        self.sdk = null;
        self.enabled = false;
    }

    pub fn setWindowId(self: *AccessibilityBridge, window_id: system_sdk.events.WindowId) void {
        self.window_id = window_id;
    }

    pub fn notifyFocusChange(self: *AccessibilityBridge, node: ?*Node) void {
        if (!self.enabled or !self.automatic_focus_notifications) return;
        const snapshot = a11ySnapshotForNode(node orelse return) orelse return;
        const sdk = self.sdk orelse return;
        sdk.notifyAccessibilityFocus(self.window_id, snapshot) catch {};
    }

    pub fn announceText(self: *AccessibilityBridge, text: []const u8) void {
        if (!self.enabled) return;
        const sdk = self.sdk orelse return;
        sdk.announceAccessibilityText(self.window_id, text) catch {};
    }

    pub fn notifyPropertyChange(self: *AccessibilityBridge, node: *Node) void {
        if (!self.enabled) return;
        const snapshot = a11ySnapshotForNode(node) orelse return;
        const sdk = self.sdk orelse return;
        sdk.notifyAccessibilityPropertyChange(self.window_id, snapshot) catch {};
    }
};

fn a11ySnapshotForNode(node: *const Node) ?system_sdk.AccessibilityNodeSnapshot {
    const a11y = node.behavior.interaction.a11y orelse return a11ySnapshotForVisibleText(node);
    var snapshot = system_sdk.AccessibilityNodeSnapshot{
        .role = mapA11yRole(a11y.role),
        .label = a11y.label orelse "",
        .description = a11y.description orelse "",
        .value_text = a11y.value_text orelse "",
        .live = a11y.live orelse "",
        .checked = a11y.checked,
        .disabled = a11y.disabled,
        .expanded = a11y.expanded,
        .selected = a11y.selected,
        .required = a11y.required,
        .invalid = a11y.invalid,
        .readonly = a11y.readonly,
        .busy = a11y.busy,
        .modal = a11y.modal,
    };
    if (snapshot.label.len == 0) {
        if (node.getText()) |text| snapshot.label = text.content;
    }
    if (!snapshot.hasSemanticContent()) return null;
    return snapshot;
}

fn a11ySnapshotForVisibleText(node: *const Node) ?system_sdk.AccessibilityNodeSnapshot {
    const text = node.getText() orelse return null;
    if (text.content.len == 0) return null;
    return .{ .label = text.content };
}

fn mapA11yRole(role: A11yRole) system_sdk.AccessibilityRole {
    return switch (role) {
        .none => .none,
        .button => .button,
        .checkbox => .checkbox,
        .radio => .radio,
        .textbox => .textbox,
        .switch_role => .switch_role,
        .tab => .tab,
        .tablist => .tablist,
        .dialog => .dialog,
        .alert => .alert,
        .menu => .menu,
        .menuitem => .menuitem,
        .listbox => .listbox,
        .option => .option,
        .progressbar => .progressbar,
        .slider => .slider,
        .heading => .heading,
        .link => .link,
        .img => .img,
        .list => .list,
        .listitem => .listitem,
        .table => .table,
        .tooltip => .tooltip,
        // v0.7 §2.5
        .combobox => .combobox,
        .grid => .grid,
        .gridcell => .gridcell,
        // 2026-07-31 补齐（与 core.zig 的 mapA11yRoleToTreeRole 同批）
        .tree => .tree,
        .treeitem => .treeitem,
        .row => .row,
        .columnheader => .columnheader,
        .rowheader => .rowheader,
        .menubar => .menubar,
        .menuitemcheckbox => .menuitemcheckbox,
        .menuitemradio => .menuitemradio,
        .spinbutton => .spinbutton,
        .status => .status,
        .group => .group,
        .navigation => .navigation,
        .separator => .separator,
        .region => .region,
        .article => .article,
        .application => .application,
        .radiogroup => .radiogroup,
        .textarea => .textarea,
        .searchbox => .searchbox,
        .tabpanel => .tabpanel,
        .alertdialog => .alertdialog,
        .log => .log,
        .paragraph => .paragraph,
        .section => .section,
        .form => .form,
        .main => .main,
        .banner => .banner,
        .contentinfo => .contentinfo,
        .generic => .generic,
    };
}

// ========== 测试 ==========

test "FocusManager: init/deinit" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    try std.testing.expectEqual(@as(?*Node, null), fm.current_focus);
    try std.testing.expectEqual(@as(usize, 0), fm.focus_order.items.len);
}

test "FocusManager: stale cached focus never bypasses registry generation" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var fm = FocusManager.init(allocator);
    defer fm.deinit();

    const node = try Node.create(allocator, 91_001, .button, .{});
    defer node.destroy(allocator);
    try registry.rebuild(node);
    fm.setRegistry(&registry);
    fm.setFocus(node);
    try std.testing.expect(fm.getFocused() == node);

    registry.unregisterSubtree(node);
    try std.testing.expectEqual(@as(?*Node, null), fm.getFocused());
}

test "FocusManager: setFocus triggers blur/focus" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const FocusCtx = struct {
        focus_count: u32 = 0,
        blur_count: u32 = 0,
    };

    var ctx_a = FocusCtx{};
    var ctx_b = FocusCtx{};

    const node_a = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node_a.behavior.events.on_focus = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const fc: *FocusCtx = @ptrCast(@alignCast(c));
            fc.focus_count += 1;
        }
    }.handler, &ctx_a);
    node_a.behavior.events.on_blur = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const fc: *FocusCtx = @ptrCast(@alignCast(c));
            fc.blur_count += 1;
        }
    }.handler, &ctx_a);

    const node_b = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node_b.behavior.events.on_focus = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const fc: *FocusCtx = @ptrCast(@alignCast(c));
            fc.focus_count += 1;
        }
    }.handler, &ctx_b);
    node_b.behavior.events.on_blur = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const fc: *FocusCtx = @ptrCast(@alignCast(c));
            fc.blur_count += 1;
        }
    }.handler, &ctx_b);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    try root.appendChild(std.testing.allocator, node_a);
    try root.appendChild(std.testing.allocator, node_b);
    ctx.root = root;

    // 聚焦 A
    fm.setFocus(node_a);
    try std.testing.expectEqual(@as(u32, 1), ctx_a.focus_count);
    try std.testing.expectEqual(@as(u32, 0), ctx_a.blur_count);

    // 聚焦 B (A 失焦)
    fm.setFocus(node_b);
    try std.testing.expectEqual(@as(u32, 1), ctx_a.blur_count);
    try std.testing.expectEqual(@as(u32, 1), ctx_b.focus_count);
}

test "FocusManager: Tab navigation" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});

    const nodes = blk: {
        var result: [3]*Node = undefined;
        for (&result) |*n| {
            n.* = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
            try root.appendChild(std.testing.allocator, n.*);
            try fm.registerFocusable(n.*);
        }
        break :blk result;
    };

    ctx.root = root;

    // 初始无焦点
    try std.testing.expectEqual(@as(?*Node, null), fm.current_focus);

    // Tab -> 第一个
    fm.focusNext();
    try std.testing.expect(fm.current_focus == nodes[0]);

    // Tab -> 第二个
    fm.focusNext();
    try std.testing.expect(fm.current_focus == nodes[1]);

    // Tab -> 第三个
    fm.focusNext();
    try std.testing.expect(fm.current_focus == nodes[2]);

    // Tab -> 回到第一个 (循环)
    fm.focusNext();
    try std.testing.expect(fm.current_focus == nodes[0]);

    // Shift+Tab -> 第三个
    fm.focusPrev();
    try std.testing.expect(fm.current_focus == nodes[2]);
}

test "FocusManager: registerFocusable no duplicates" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;

    try fm.registerFocusable(node);
    try fm.registerFocusable(node);
    try fm.registerFocusable(node);

    try std.testing.expectEqual(@as(usize, 1), fm.focus_order.items.len);
}

test "FocusManager: unregisterFocusable" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;

    try fm.registerFocusable(node);
    try std.testing.expectEqual(@as(usize, 1), fm.focus_order.items.len);

    fm.setFocus(node);
    try std.testing.expect(fm.current_focus == node);

    fm.unregisterFocusable(node);
    try std.testing.expectEqual(@as(usize, 0), fm.focus_order.items.len);
    try std.testing.expectEqual(@as(?*Node, null), fm.current_focus);
}

test "FocusManager: collectFocusableNodes uses focusable field" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = core.Direction.column,
    }, .{});

    // 普通 box (不可聚焦)
    const box1 = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try root.appendChild(std.testing.allocator, box1);

    // focusable input
    const input1 = try core.Node.create(std.testing.allocator, ctx.nextId(), .input, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    input1.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, input1);

    // focusable button
    const btn1 = try core.Node.create(std.testing.allocator, ctx.nextId(), .button, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 30 },
    });
    btn1.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, btn1);

    // focusable box (via focusable field)
    const focusable_box = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    focusable_box.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, focusable_box);

    // input without focusable flag (should NOT be collected)
    const input2 = try core.Node.create(std.testing.allocator, ctx.nextId(), .input, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    try root.appendChild(std.testing.allocator, input2);

    ctx.root = root;

    try fm.collectFocusableNodes(root);
    // Only 3 focusable nodes (input1, btn1, focusable_box), not input2
    try std.testing.expectEqual(@as(usize, 3), fm.focus_order.items.len);
    try std.testing.expect(fm.focus_order.items[0] == input1);
    try std.testing.expect(fm.focus_order.items[1] == btn1);
    try std.testing.expect(fm.focus_order.items[2] == focusable_box);
}

test "Cx: click non-focusable clears focus" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    // focusable button
    const btn = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.focusable = true;
    btn.behavior.events.on_event = struct {
        fn handler(_: core.Event, _: ?*anyopaque) core.EventResult {
            return .handled;
        }
    }.handler;
    try root.appendChild(std.testing.allocator, btn);

    // non-focusable area with event handler (to be hittable)
    const area = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    area.behavior.events.on_event = struct {
        fn handler(_: core.Event, _: ?*anyopaque) core.EventResult {
            return .handled;
        }
    }.handler;
    try root.appendChild(std.testing.allocator, area);

    ctx.root = root;
    ctx.setViewport(400, 300);
    ctx.layout();

    // Click focusable button first
    ctx.handleMouseDown(50, 15, .{});
    ctx.handleMouseUp(50, 15);
    try std.testing.expect(ctx.focus_manager.current_focus == btn);

    // Click non-focusable area → clears focus
    ctx.handleMouseDown(50, 45, .{});
    ctx.handleMouseUp(50, 45);
    try std.testing.expectEqual(@as(?*Node, null), ctx.focus_manager.current_focus);
}

test "Cx: click focusable node sets focus" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    const btn = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.focusable = true;
    btn.behavior.events.on_event = struct {
        fn handler(_: core.Event, _: ?*anyopaque) core.EventResult {
            return .handled;
        }
    }.handler;
    try root.appendChild(std.testing.allocator, btn);

    ctx.root = root;
    ctx.setViewport(400, 300);
    ctx.layout();

    // Initially no focus
    try std.testing.expectEqual(@as(?*Node, null), ctx.focus_manager.current_focus);

    // Click focusable node → gets focus
    ctx.handleMouseDown(50, 15, .{});
    ctx.handleMouseUp(50, 15);
    try std.testing.expect(ctx.focus_manager.current_focus == btn);
}

test "Cx: click child of focusable finds ancestor" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    // focusable parent container
    const container = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 50 },
    }, .{});
    container.behavior.interaction.focusable = true;
    container.behavior.events.on_event = struct {
        fn handler(_: core.Event, _: ?*anyopaque) core.EventResult {
            return .handled;
        }
    }.handler;
    try root.appendChild(std.testing.allocator, container);

    // non-focusable child inside focusable container
    const child = try core.box(ctx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    child.behavior.events.on_event = struct {
        fn handler(_: core.Event, _: ?*anyopaque) core.EventResult {
            return .handled;
        }
    }.handler;
    try container.appendChild(std.testing.allocator, child);

    ctx.root = root;
    ctx.setViewport(400, 300);
    ctx.layout();

    // Click child → focus goes to focusable ancestor (container)
    ctx.handleMouseDown(40, 15, .{});
    ctx.handleMouseUp(40, 15);
    try std.testing.expect(ctx.focus_manager.current_focus == container);
}

// ── pointer_down_focus = .preserve ────────────────────────────────────
// 场景：一个 focusable 的"编辑器"持有焦点；一个 focusable=false 的按钮挂在两层
// focusable=false 的容器（toolbar → group）下。`preserve_on` 决定把 .preserve
// 设在哪一层（null = 不设，走默认转移）。

const PdfPlacement = enum {
    /// 按钮在编辑器子树内（编辑器就是按钮最近的 focusable 祖先）。
    inside_editor,
    /// 按钮在编辑器之外的兄弟子树（悬浮条挂在别处，父链上没有 focusable）。
    sibling_of_editor,
    /// 按钮在另一个 focusable 面板之内（最近的 focusable 祖先不是编辑器）。
    inside_focusable_panel,
};

const PdfPreserveOn = enum { none, toolbar, button };

const PdfFixture = struct {
    ctx: *core.Cx,
    editor: *Node,
    panel: ?*Node,
    button: *Node,
    /// 按钮中心（窗口坐标）
    button_xy: [2]f32,
    /// 编辑器上一个不被其它子节点覆盖的点
    editor_xy: [2]f32,
};

fn pdfHandled(_: core.Event, _: ?*anyopaque) core.EventResult {
    return .handled;
}

fn pdfBox(ctx: *core.Cx, w: f32, h: f32) !*Node {
    const n = try core.box(ctx, .{
        .width = .{ .px = w },
        .height = .{ .px = h },
        .direction = core.Direction.column,
    }, .{});
    n.behavior.events.on_event = pdfHandled;
    return n;
}

fn buildPdfFixture(ctx: *core.Cx, placement: PdfPlacement, preserve_on: PdfPreserveOn) !PdfFixture {
    const a = std.testing.allocator;
    const root = try core.box(ctx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = core.Direction.column,
    }, .{});
    ctx.root = root;

    const editor = try pdfBox(ctx, 400, 100);
    editor.behavior.interaction.focusable = true;
    try root.appendChild(a, editor);

    const toolbar = try pdfBox(ctx, 200, 40);
    const group = try pdfBox(ctx, 150, 30);
    const button = try pdfBox(ctx, 60, 20);
    try group.appendChild(a, button);
    try toolbar.appendChild(a, group);

    var panel: ?*Node = null;
    switch (placement) {
        .inside_editor => {
            // 编辑器正文区在上（y 0..60），工具条在下（y 60..100）。
            const body = try pdfBox(ctx, 400, 60);
            try editor.appendChild(a, body);
            try editor.appendChild(a, toolbar);
        },
        .sibling_of_editor => try root.appendChild(a, toolbar),
        .inside_focusable_panel => {
            const p = try pdfBox(ctx, 400, 100);
            p.behavior.interaction.focusable = true;
            try p.appendChild(a, toolbar);
            try root.appendChild(a, p);
            panel = p;
        },
    }

    switch (preserve_on) {
        .none => {},
        .toolbar => toolbar.setPointerDownFocus(.preserve),
        .button => button.setPointerDownFocus(.preserve),
    }

    ctx.setViewport(400, 300);
    ctx.layout();

    const toolbar_y: f32 = if (placement == .inside_editor) 60 else 100;
    return .{
        .ctx = ctx,
        .editor = editor,
        .panel = panel,
        .button = button,
        .button_xy = .{ 30, toolbar_y + 10 },
        .editor_xy = .{ 300, 20 },
    };
}

fn pdfClick(ctx: *core.Cx, xy: [2]f32) void {
    ctx.handleMouseDown(xy[0], xy[1], .{});
    ctx.handleMouseUp(xy[0], xy[1]);
}

/// 先点编辑器拿到焦点，再点按钮；返回点按钮后的焦点。
fn pdfFocusAfterButtonClick(placement: PdfPlacement, preserve_on: PdfPreserveOn) !struct { focus: ?*Node, fx: PdfFixture, ctx: *core.Cx } {
    const ctx = try core.Cx.init(std.testing.allocator);
    errdefer ctx.deinit();
    const fx = try buildPdfFixture(ctx, placement, preserve_on);

    pdfClick(ctx, fx.editor_xy);
    try std.testing.expect(ctx.focus_manager.current_focus == fx.editor);

    pdfClick(ctx, fx.button_xy);
    // 命中确实落在按钮上（否则断言测的是别的节点）。
    try std.testing.expect(ctx.last_mouse_down_target == fx.button);
    return .{ .focus = ctx.focus_manager.current_focus, .fx = fx, .ctx = ctx };
}

test "Cx: pointer_down_focus defaults to transfer" {
    const ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const n = try core.box(ctx, .{}, .{});
    ctx.root = n;
    try std.testing.expectEqual(core.PointerDownFocus.transfer, n.behavior.interaction.pointer_down_focus);
}

test "Cx: pointer_down_focus button under focused editor — default and preserve both keep editor" {
    // 编辑器本身就是最近的 focusable 祖先：默认转移的目标恰好就是当前焦点。
    {
        const r = try pdfFocusAfterButtonClick(.inside_editor, .none);
        defer r.ctx.deinit();
        try std.testing.expect(r.focus == r.fx.editor);
    }
    {
        const r = try pdfFocusAfterButtonClick(.inside_editor, .toolbar);
        defer r.ctx.deinit();
        try std.testing.expect(r.focus == r.fx.editor);
        try std.testing.expect(r.ctx.focused_node == r.fx.editor);
    }
}

test "Cx: pointer_down_focus preserve keeps editor focus when toolbar is outside editor" {
    {
        // 对照：默认行为——父链上无 focusable → 清空焦点。
        const r = try pdfFocusAfterButtonClick(.sibling_of_editor, .none);
        defer r.ctx.deinit();
        try std.testing.expectEqual(@as(?*Node, null), r.focus);
    }
    {
        const r = try pdfFocusAfterButtonClick(.sibling_of_editor, .toolbar);
        defer r.ctx.deinit();
        try std.testing.expect(r.focus == r.fx.editor);
        try std.testing.expect(r.ctx.focused_node == r.fx.editor);
        try std.testing.expect(r.ctx.focused_handle != null);
    }
}

test "Cx: pointer_down_focus preserve stops walk before a focusable panel ancestor" {
    {
        // 对照：默认行为——焦点转给按钮最近的 focusable 祖先（面板）。
        const r = try pdfFocusAfterButtonClick(.inside_focusable_panel, .none);
        defer r.ctx.deinit();
        try std.testing.expect(r.fx.panel != null);
        try std.testing.expect(r.focus == r.fx.panel.?);
    }
    {
        const r = try pdfFocusAfterButtonClick(.inside_focusable_panel, .toolbar);
        defer r.ctx.deinit();
        try std.testing.expect(r.focus == r.fx.editor);
    }
}

test "Cx: pointer_down_focus preserve on a focusable button wins over its own focusability" {
    {
        const r = try pdfFocusAfterButtonClick(.sibling_of_editor, .button);
        defer r.ctx.deinit();
        try std.testing.expect(r.focus == r.fx.editor);
    }
    {
        // 按钮自身 focusable + preserve：仍不抢焦点（可 Tab 到，但点击不抢）。
        const ctx = try core.Cx.init(std.testing.allocator);
        defer ctx.deinit();
        const fx = try buildPdfFixture(ctx, .sibling_of_editor, .button);
        fx.button.behavior.interaction.focusable = true;
        pdfClick(ctx, fx.editor_xy);
        try std.testing.expect(ctx.focus_manager.current_focus == fx.editor);
        pdfClick(ctx, fx.button_xy);
        try std.testing.expect(ctx.last_mouse_down_target == fx.button);
        try std.testing.expect(ctx.focus_manager.current_focus == fx.editor);
    }
}

test "Cx: pointer_down_focus preserve does not block a focusable descendant" {
    // 工具条设 .preserve，但按钮本身 focusable（如工具条里的内嵌输入框）：
    // 从命中节点向上先遇到 focusable → 正常拿焦点。
    const ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const fx = try buildPdfFixture(ctx, .sibling_of_editor, .toolbar);
    fx.button.behavior.interaction.focusable = true;
    pdfClick(ctx, fx.editor_xy);
    try std.testing.expect(ctx.focus_manager.current_focus == fx.editor);
    pdfClick(ctx, fx.button_xy);
    try std.testing.expect(ctx.focus_manager.current_focus == fx.button);
}

test "Cx: pointer_down_focus preserve with nothing focused stays unfocused and still dispatches" {
    const ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const fx = try buildPdfFixture(ctx, .sibling_of_editor, .toolbar);
    const Counter = struct {
        var downs: u32 = 0;
        fn handler(ev: core.Event, _: ?*anyopaque) core.EventResult {
            if (ev == .mouse_down) downs += 1;
            return .handled;
        }
    };
    Counter.downs = 0;
    fx.button.behavior.events.on_event = Counter.handler;
    try std.testing.expectEqual(@as(?*Node, null), ctx.focus_manager.current_focus);
    pdfClick(ctx, fx.button_xy);
    try std.testing.expectEqual(@as(?*Node, null), ctx.focus_manager.current_focus);
    try std.testing.expectEqual(@as(u32, 1), Counter.downs);
}

test "Cx: layout auto collects focusable nodes" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = core.Direction.column,
    }, .{});

    const btn1 = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    btn1.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, btn1);

    const btn2 = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    btn2.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, btn2);

    // non-focusable
    const box1 = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try root.appendChild(std.testing.allocator, box1);

    ctx.root = root;
    ctx.setViewport(400, 300);
    ctx.layout();

    // layout should have collected 2 focusable nodes
    try std.testing.expectEqual(@as(usize, 2), ctx.focus_manager.focus_order.items.len);
    try std.testing.expect(ctx.focus_manager.focus_order.items[0] == btn1);
    try std.testing.expect(ctx.focus_manager.focus_order.items[1] == btn2);
}

test "FocusScope: push/pop" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope1 = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    scope1.behavior.interaction.focus_scope = .{ .trap = true };
    try root.appendChild(std.testing.allocator, scope1);

    const scope2 = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    scope2.behavior.interaction.focus_scope = .{ .trap = true };
    try scope1.appendChild(std.testing.allocator, scope2);

    try std.testing.expectEqual(@as(u8, 0), fm.scope_count);
    try std.testing.expectEqual(@as(?*Node, null), fm.activeScope());

    fm.pushScope(scope1);
    try std.testing.expectEqual(@as(u8, 1), fm.scope_count);
    try std.testing.expect(fm.activeScope() == scope1);

    fm.pushScope(scope2);
    try std.testing.expectEqual(@as(u8, 2), fm.scope_count);
    try std.testing.expect(fm.activeScope() == scope2);

    fm.popScope();
    try std.testing.expectEqual(@as(u8, 1), fm.scope_count);
    try std.testing.expect(fm.activeScope() == scope1);

    fm.popScope();
    try std.testing.expectEqual(@as(u8, 0), fm.scope_count);
    try std.testing.expectEqual(@as(?*Node, null), fm.activeScope());

    // pop on empty is safe
    fm.popScope();
    try std.testing.expectEqual(@as(u8, 0), fm.scope_count);
}

test "FocusScope: scope 节点释放后 activeScope 返回 null 而非悬垂指针" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var fm = FocusManager.init(allocator);
    defer fm.deinit();

    const modal = try Node.create(allocator, 91_002, .button, .{});
    defer modal.destroy(allocator);
    modal.behavior.interaction.focus_scope = .{ .trap = true };
    try registry.rebuild(modal);
    fm.setRegistry(&registry);

    fm.pushScope(modal);
    // 解析成功会把裸指针缓存进 scope_stack
    try std.testing.expect(fm.activeScope() == modal);

    // 模拟 scope 节点被释放（freeNode → noteNodeFreed 摘表项）
    registry.unregisterSubtree(modal);
    try std.testing.expect(fm.activeScope() == null);
    // Tab 路径（scopedFocusOrder）走无 scope 分支，不解引用悬垂 scope
    try std.testing.expectEqual(fm.focus_order.items.len, fm.scopedFocusOrder().len);
}

test "FocusScope: tab stays within trap" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});

    // Outside button (should be excluded from trap navigation)
    const outside_btn = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    outside_btn.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, outside_btn);

    // Modal scope
    const modal = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    modal.behavior.interaction.focus_scope = .{ .trap = true };
    try root.appendChild(std.testing.allocator, modal);

    const btn_a = try core.box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn_a.behavior.interaction.focusable = true;
    try modal.appendChild(std.testing.allocator, btn_a);

    const btn_b = try core.box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn_b.behavior.interaction.focusable = true;
    try modal.appendChild(std.testing.allocator, btn_b);

    ctx.root = root;

    // Collect focusable nodes (3 total: outside_btn, btn_a, btn_b)
    try fm.collectFocusableNodes(root);
    try std.testing.expectEqual(@as(usize, 3), fm.focus_order.items.len);

    // Push trap scope
    fm.pushScope(modal);

    // Scoped order should only contain btn_a, btn_b
    const scoped = fm.scopedFocusOrder();
    try std.testing.expectEqual(@as(usize, 2), scoped.len);

    // Tab navigation stays within trap
    fm.setFocus(btn_a);
    fm.focusNext();
    try std.testing.expect(fm.current_focus == btn_b);

    fm.focusNext();
    try std.testing.expect(fm.current_focus == btn_a); // wraps back

    fm.focusPrev();
    try std.testing.expect(fm.current_focus == btn_b); // wraps back

    fm.popScope();
}

test "FocusScope: isDescendantOf" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const parent_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(std.testing.allocator, parent_node);
    const child = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    try parent_node.appendChild(std.testing.allocator, child);
    const grandchild = try core.box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try child.appendChild(std.testing.allocator, grandchild);

    const unrelated = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    try root.appendChild(std.testing.allocator, unrelated);

    try std.testing.expect(grandchild.isDescendantOf(root));
    try std.testing.expect(grandchild.isDescendantOf(parent_node));
    try std.testing.expect(grandchild.isDescendantOf(child));
    try std.testing.expect(grandchild.isDescendantOf(grandchild)); // node is descendant of itself
    try std.testing.expect(!grandchild.isDescendantOf(unrelated));
    try std.testing.expect(!unrelated.isDescendantOf(parent_node));
}

test "FocusEvent: blur carries related_node_id" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const node_a = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node_a.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, node_a);

    const node_b = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node_b.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, node_b);

    const TestCtx = struct {
        var last_blur_related: ?u32 = null;
        var last_focus_related: ?u32 = null;
        var last_focus_reason: FocusReason = .programmatic;
    };
    TestCtx.last_blur_related = null;
    TestCtx.last_focus_related = null;
    TestCtx.last_focus_reason = .programmatic;

    // 必须先 layout 以注册节点到 registry，dispatcher 才能分发事件
    ctx.layout();

    // Set on_event to capture FocusEvent details
    node_a.behavior.events.on_event = struct {
        fn handler(event: Event, _: ?*anyopaque) events_mod.EventResult {
            switch (event) {
                .blur => |fe| {
                    TestCtx.last_blur_related = fe.related_node_id;
                },
                else => {},
            }
            return .ignored;
        }
    }.handler;

    node_b.behavior.events.on_event = struct {
        fn handler(event: Event, _: ?*anyopaque) events_mod.EventResult {
            switch (event) {
                .focus => |fe| {
                    TestCtx.last_focus_related = fe.related_node_id;
                    TestCtx.last_focus_reason = fe.reason;
                },
                else => {},
            }
            return .ignored;
        }
    }.handler;

    // Focus A first
    ctx.focus_manager.setFocusWithReason(node_a, .click);

    // Focus B (A blurs)
    ctx.focus_manager.setFocusWithReason(node_b, .tab);

    // A's blur should carry B's id as related
    try std.testing.expectEqual(node_b.id, TestCtx.last_blur_related.?);
    // B's focus should carry A's id as related
    try std.testing.expectEqual(node_a.id, TestCtx.last_focus_related.?);
    // B's focus reason should be .tab
    try std.testing.expectEqual(FocusReason.tab, TestCtx.last_focus_reason);
}

test "FocusEvent: focus reason click/tab/programmatic" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, node);

    const TestCtx2 = struct {
        var last_reason: FocusReason = .programmatic;
    };

    node.behavior.events.on_event = struct {
        fn handler(event: Event, _: ?*anyopaque) events_mod.EventResult {
            switch (event) {
                .focus => |fe| {
                    TestCtx2.last_reason = fe.reason;
                },
                else => {},
            }
            return .ignored;
        }
    }.handler;

    ctx.layout();

    // Test click reason
    ctx.focus_manager.setFocusWithReason(node, .click);
    try std.testing.expectEqual(FocusReason.click, TestCtx2.last_reason);

    // Clear and test tab reason
    ctx.focus_manager.clearFocus();
    ctx.focus_manager.setFocusWithReason(node, .tab);
    try std.testing.expectEqual(FocusReason.tab, TestCtx2.last_reason);

    // Clear and test programmatic reason
    ctx.focus_manager.clearFocus();
    ctx.focus_manager.setFocus(node); // default is .programmatic
    try std.testing.expectEqual(FocusReason.programmatic, TestCtx2.last_reason);
}

test "FocusEvent: bubbles via dispatch" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    var parent_got_focus = false;

    const parent_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    parent_node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) events_mod.EventResult {
            switch (event) {
                .focus => {
                    const ptr: *bool = @ptrCast(@alignCast(context.?));
                    ptr.* = true;
                },
                else => {},
            }
            return .ignored;
        }
    }.handler;
    parent_node.behavior.events.event_context = &parent_got_focus;
    try root.appendChild(std.testing.allocator, parent_node);

    const child = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    child.behavior.interaction.focusable = true;
    try parent_node.appendChild(std.testing.allocator, child);

    ctx.layout();

    // Focus child — should bubble to parent's on_event
    ctx.focus_manager.setFocus(child);
    try std.testing.expect(parent_got_focus);
}

test "Focus memory: restore after popScope" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    // Outer button
    const outer_btn = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    outer_btn.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, outer_btn);

    // Modal scope
    const modal = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    modal.behavior.interaction.focus_scope = .{ .trap = true };
    try root.appendChild(std.testing.allocator, modal);

    const inner_btn = try core.box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    inner_btn.behavior.interaction.focusable = true;
    try modal.appendChild(std.testing.allocator, inner_btn);

    ctx.setViewport(800, 600);
    ctx.layout();

    // Focus outer button
    ctx.focus_manager.setFocus(outer_btn);
    try std.testing.expect(ctx.focus_manager.current_focus == outer_btn);

    // Push modal scope — saves outer_btn focus
    ctx.focus_manager.pushScope(modal);
    // Focus moves to inner_btn (or manually set)
    ctx.focus_manager.setFocus(inner_btn);
    try std.testing.expect(ctx.focus_manager.current_focus == inner_btn);

    // Pop scope — restores outer_btn focus
    ctx.focus_manager.popScope();
    try std.testing.expect(ctx.focus_manager.current_focus == outer_btn);
}

test "Focus memory: auto_focus on push" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    // Modal scope with auto_focus
    const modal = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    modal.behavior.interaction.focus_scope = .{ .trap = true, .auto_focus = true };
    try root.appendChild(std.testing.allocator, modal);

    const btn_a = try core.box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn_a.behavior.interaction.focusable = true;
    try modal.appendChild(std.testing.allocator, btn_a);

    const btn_b = try core.box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn_b.behavior.interaction.focusable = true;
    try modal.appendChild(std.testing.allocator, btn_b);

    ctx.setViewport(800, 600);
    ctx.layout();

    // Initially no focus
    try std.testing.expectEqual(@as(?*Node, null), ctx.focus_manager.current_focus);

    // Push scope with auto_focus → first focusable node in scope should be focused
    ctx.focus_manager.pushScope(modal);
    try std.testing.expect(ctx.focus_manager.current_focus == btn_a);

    ctx.focus_manager.popScope();
}

// ========== Tab Index 测试 ==========

test "tab_index=0 auto focusable via collectFocusableNodes" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    // tab_index=0 的节点应当自动可聚焦
    const btn = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.tab_index = 0;
    try root.appendChild(std.testing.allocator, btn);

    // 普通节点（不可聚焦）
    const plain = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try root.appendChild(std.testing.allocator, plain);

    ctx.root = root;

    try fm.collectFocusableNodes(root);
    // tab_index=0 被收集, plain 不被收集
    try std.testing.expectEqual(@as(usize, 1), fm.focus_order.items.len);
    try std.testing.expect(fm.focus_order.items[0] == btn);
}

test "tab_index=-1 excluded from Tab cycle" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    // tab_index=-1: 可聚焦但不参与 Tab 循环
    const hidden = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    hidden.behavior.interaction.tab_index = -1;
    try root.appendChild(std.testing.allocator, hidden);

    // tab_index=0: 正常参与 Tab 循环
    const visible = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    visible.behavior.interaction.tab_index = 0;
    try root.appendChild(std.testing.allocator, visible);

    ctx.root = root;

    try fm.collectFocusableNodes(root);
    // 只有 visible 在 focus_order 中
    try std.testing.expectEqual(@as(usize, 1), fm.focus_order.items.len);
    try std.testing.expect(fm.focus_order.items[0] == visible);

    // 但 tab_index=-1 的节点仍可通过 setFocus 聚焦
    fm.setFocus(hidden);
    try std.testing.expect(fm.current_focus == hidden);
}

test "tab_index positive controls Tab order" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    // 树序: c (tab_index=3), a (tab_index=1), b (tab_index=2), d (focusable, no tab_index)
    const c = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    c.behavior.interaction.tab_index = 3;
    try root.appendChild(std.testing.allocator, c);

    const a = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    a.behavior.interaction.tab_index = 1;
    try root.appendChild(std.testing.allocator, a);

    const b = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    b.behavior.interaction.tab_index = 2;
    try root.appendChild(std.testing.allocator, b);

    const d = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    d.behavior.interaction.focusable = true; // no tab_index, 排在正数之后
    try root.appendChild(std.testing.allocator, d);

    ctx.root = root;

    try fm.collectFocusableNodes(root);
    // 排序: a(1), b(2), c(3), d(树序末)
    try std.testing.expectEqual(@as(usize, 4), fm.focus_order.items.len);
    try std.testing.expect(fm.focus_order.items[0] == a);
    try std.testing.expect(fm.focus_order.items[1] == b);
    try std.testing.expect(fm.focus_order.items[2] == c);
    try std.testing.expect(fm.focus_order.items[3] == d);

    // Tab 导航按排序顺序
    fm.focusNext();
    try std.testing.expect(fm.current_focus == a);
    fm.focusNext();
    try std.testing.expect(fm.current_focus == b);
    fm.focusNext();
    try std.testing.expect(fm.current_focus == c);
    fm.focusNext();
    try std.testing.expect(fm.current_focus == d);
    fm.focusNext();
    try std.testing.expect(fm.current_focus == a); // 循环
}

test "Space/Enter triggers click on focusable node" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    var click_count: u32 = 0;

    const btn = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.focusable = true;
    btn.behavior.events.on_click = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const cnt: *u32 = @ptrCast(@alignCast(c));
            cnt.* += 1;
        }
    }.handler, &click_count);
    try root.appendChild(std.testing.allocator, btn);

    ctx.root = root;
    ctx.setViewport(400, 300);
    ctx.layout();

    // 聚焦 btn
    ctx.focus_manager.setFocus(btn);
    try std.testing.expect(ctx.focus_manager.current_focus == btn);

    // Space 触发 click
    ctx.handleKeyDown(.space, .{});
    try std.testing.expectEqual(@as(u32, 1), click_count);

    // Enter 触发 click
    ctx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(u32, 2), click_count);
}

test "Space/Enter does not override node key handler" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});

    var click_count: u32 = 0;
    var key_count: u32 = 0;

    const input_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 30 } }, .{});
    input_node.behavior.interaction.focusable = true;
    input_node.behavior.events.on_click = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const cnt: *u32 = @ptrCast(@alignCast(c));
            cnt.* += 1;
        }
    }.handler, &click_count);
    // 节点自身处理 key_down → 返回 .handled (不是 .ignored)
    input_node.behavior.events.on_event = struct {
        fn handler(event: core.Event, context: ?*anyopaque) events_mod.EventResult {
            switch (event) {
                .key_down => {
                    const cnt: *u32 = @ptrCast(@alignCast(context.?));
                    cnt.* += 1;
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    input_node.behavior.events.event_context = &key_count;
    try root.appendChild(std.testing.allocator, input_node);

    ctx.root = root;
    ctx.setViewport(400, 300);
    ctx.layout();

    ctx.focus_manager.setFocus(input_node);

    // Enter → 节点处理了 key_down，不应合成 click
    ctx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(u32, 1), key_count);
    try std.testing.expectEqual(@as(u32, 0), click_count); // click 不触发
}

// ========== Accessibility bridge tests ==========

test "A11yProps: default values" {
    const props = core.A11yProps{};
    try std.testing.expectEqual(A11yRole.none, props.role);
    try std.testing.expectEqual(@as(?[]const u8, null), props.label);
    try std.testing.expectEqual(@as(?bool, null), props.checked);
    try std.testing.expect(!props.disabled);
}

test "AccessibilityBridge: notifyFocusChange smoke" {
    var bridge = AccessibilityBridge{};
    bridge.notifyFocusChange(null);

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node.behavior.interaction.a11y = .{ .role = .button, .label = "Submit" };
    try root.appendChild(std.testing.allocator, node);

    bridge.enabled = true;
    bridge.notifyFocusChange(node);
    bridge.announceText("Button focused");
    bridge.notifyPropertyChange(node);
}

test "AccessibilityBridge: forwards snapshots to SystemSdk" {
    const MockBackend = struct {
        focus_count: u32 = 0,
        property_count: u32 = 0,
        last_focus: system_sdk.AccessibilityNodeSnapshot = .{},
        last_property: system_sdk.AccessibilityNodeSnapshot = .{},

        fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}

        fn pump(_: *anyopaque, _: *system_sdk.EventQueue, _: u32) system_sdk.SdkError!system_sdk.PumpResult {
            return .{};
        }

        fn announce(_: *anyopaque, _: system_sdk.events.WindowId, _: []const u8) system_sdk.SdkError!void {}

        fn notifyFocus(ctx_: *anyopaque, _: system_sdk.events.WindowId, snapshot: system_sdk.AccessibilityNodeSnapshot) system_sdk.SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx_));
            self.focus_count += 1;
            self.last_focus = snapshot;
        }

        fn notifyProperty(ctx_: *anyopaque, _: system_sdk.events.WindowId, snapshot: system_sdk.AccessibilityNodeSnapshot) system_sdk.SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx_));
            self.property_count += 1;
            self.last_property = snapshot;
        }
    };

    var backend = MockBackend{};
    const vtable = system_sdk.BackendVTable{
        .name = "ui-a11y-mock",
        .deinit = MockBackend.deinitFn,
        .pump_events = MockBackend.pump,
        .accessibility = .{
            .announce_text = MockBackend.announce,
            .notify_focus = MockBackend.notifyFocus,
            .notify_property_change = MockBackend.notifyProperty,
        },
    };

    var sdk = system_sdk.SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .accessibility = true });
    defer sdk.deinit();

    var bridge = AccessibilityBridge{};
    bridge.attachSystemSdk(&sdk, 3);

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 160 }, .height = .{ .px = 80 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    node.behavior.interaction.a11y = .{
        .role = .checkbox,
        .label = "Autosave",
        .checked = true,
        .disabled = true,
    };
    try root.appendChild(std.testing.allocator, node);

    bridge.notifyFocusChange(node);
    bridge.notifyPropertyChange(node);

    try std.testing.expectEqual(@as(u32, 1), backend.focus_count);
    try std.testing.expectEqual(system_sdk.AccessibilityRole.checkbox, backend.last_focus.role);
    try std.testing.expectEqualStrings("Autosave", backend.last_focus.label);
    try std.testing.expectEqual(@as(?bool, true), backend.last_focus.checked);
    try std.testing.expect(backend.last_focus.disabled);
    try std.testing.expectEqual(@as(u32, 1), backend.property_count);
    try std.testing.expectEqual(system_sdk.AccessibilityRole.checkbox, backend.last_property.role);
    try std.testing.expectEqualStrings("Autosave", backend.last_property.label);
}

test "FocusManager: focus event delivered once" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    node.setFocusable(true);
    const State = struct {
        count: usize = 0,
        fn event(e: core.Event, raw: ?*anyopaque) core.EventResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (e == .focus) self.count += 1;
            return .ignored;
        }
    };
    var state = State{};
    node.behavior.events.on_event = State.event;
    node.behavior.events.event_context = &state;
    cx.layout();
    _ = cx.render();
    cx.focus_manager.setFocus(node);
    try std.testing.expectEqual(@as(usize, 1), state.count);
}

test "FocusManager: blur redirect does not recursively blur old owner" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const a = try core.box(cx, .{}, .{});
    const b = try core.box(cx, .{}, .{});
    const c = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, a);
    try root.appendChild(cx.allocator, b);
    try root.appendChild(cx.allocator, c);
    a.setFocusable(true);
    b.setFocusable(true);
    c.setFocusable(true);
    const State = struct {
        cx: *core.Cx,
        target: *core.Node,
        count: usize = 0,
        fn blur(self: *@This()) void {
            self.count += 1;
            // Bound recursion so the regression is an assertion, not a crash.
            if (self.count < 5) self.cx.focus_manager.setFocus(self.target);
        }
    };
    var state = State{ .cx = cx, .target = c };
    a.behavior.events.on_blur = core.Cx.handlerFrom(State, &state, State.blur);
    cx.layout();
    _ = cx.render();
    cx.focus_manager.setFocus(a);
    cx.focus_manager.setFocus(b);
    a.behavior.events.on_blur = null;
    try std.testing.expectEqual(@as(usize, 1), state.count);
}

test "FocusManager: mouse focus redirect keeps Cx cache consistent" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try core.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const a = try core.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    const b = try core.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(cx.allocator, a);
    try root.appendChild(cx.allocator, b);
    a.setFocusable(true);
    b.setFocusable(true);
    const State = struct {
        cx: *core.Cx,
        target: *core.Node,
        fn focus(self: *@This()) void {
            self.cx.focus_manager.setFocus(self.target);
        }
        fn event(_: core.Event, _: ?*anyopaque) core.EventResult {
            return .handled;
        }
    };
    var state = State{ .cx = cx, .target = b };
    a.behavior.events.on_focus = core.Cx.handlerFrom(State, &state, State.focus);
    a.behavior.events.on_event = State.event;
    cx.layout();
    _ = cx.render();
    const r = a.rectFromWorldOrFallback();
    cx.handleMouseDown(r.x + 5, r.y + 5, .{});
    try std.testing.expectEqual(b, cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(b, cx.focused_node.?);
}

test "FocusManager: mouse focus callback destroys its target" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try core.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const a = try core.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(cx.allocator, a);
    a.setFocusable(true);
    const State = struct {
        cx: *core.Cx,
        target: *core.Node,
        fn focus(self: *@This()) void {
            self.cx.detachChild(self.target.parent.?, self.target);
            self.cx.freeNode(self.target);
        }
        fn event(_: core.Event, _: ?*anyopaque) core.EventResult {
            return .handled;
        }
    };
    var state = State{ .cx = cx, .target = a };
    a.behavior.events.on_focus = core.Cx.handlerFrom(State, &state, State.focus);
    a.behavior.events.on_event = State.event;
    cx.layout();
    _ = cx.render();
    const r = a.rectFromWorldOrFallback();
    cx.handleMouseDown(r.x + 5, r.y + 5, .{});
    try std.testing.expect(cx.focus_manager.getFocused() == null);
    try std.testing.expect(cx.focused_node == null);
    try std.testing.expect(cx.focused_handle == null);
}

test "FocusManager: reentrant blur requests settle once and newest request wins" {
    const Request = enum { clear, restore_old, redirect, redirect_then_destroy };
    for ([_]Request{ .clear, .restore_old, .redirect, .redirect_then_destroy }) |request| {
        const cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const a = try core.box(cx, .{}, .{});
        const b = try core.box(cx, .{}, .{});
        const c = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, a);
        try root.appendChild(cx.allocator, b);
        try root.appendChild(cx.allocator, c);
        const State = struct {
            cx: *core.Cx,
            old: *Node,
            target: *Node,
            request: Request,
            blur_calls: usize = 0,
            settled_calls: usize = 0,
            settled_owner: ?*Node = null,
            fn blur(self: *@This()) void {
                self.blur_calls += 1;
                // Guard makes regressions assert instead of exhausting stack.
                if (self.blur_calls > 1) return;
                switch (self.request) {
                    .clear => self.cx.clearFocus(),
                    .restore_old => self.cx.setFocus(self.old),
                    .redirect, .redirect_then_destroy => {
                        self.cx.setFocus(self.target);
                        if (self.request == .redirect_then_destroy) {
                            self.cx.detachChild(self.target.parent.?, self.target);
                            self.cx.freeNode(self.target);
                        }
                    },
                }
            }
            fn settled(ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.settled_calls += 1;
                self.settled_owner = self.cx.focus_manager.getFocused();
            }
        };
        var state = State{ .cx = cx, .old = a, .target = c, .request = request };
        cx.layout();
        _ = cx.render();
        cx.setFocus(a);
        a.behavior.events.on_blur = core.Cx.handlerFrom(State, &state, State.blur);
        cx.focus_manager.settled_context = &state;
        cx.focus_manager.on_focus_settled = State.settled;
        cx.setFocus(b);
        a.behavior.events.on_blur = null;
        // Restore before state leaves scope / Cx teardown.
        cx.focus_manager.settled_context = null;
        cx.focus_manager.on_focus_settled = null;
        const expected: ?*Node = switch (request) {
            .clear, .redirect_then_destroy => null,
            .restore_old => a,
            .redirect => c,
        };
        try std.testing.expectEqual(@as(usize, 1), state.blur_calls);
        try std.testing.expectEqual(@as(usize, 1), state.settled_calls);
        try std.testing.expectEqual(expected, state.settled_owner);
        try std.testing.expectEqual(expected, cx.focus_manager.getFocused());
    }
}

test "FocusManager: unregistered mount target receives one focus event" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    const State = struct {
        count: usize = 0,
        fn event(e: Event, ptr: ?*anyopaque) core.EventResult {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (e == .focus) self.count += 1;
            return .ignored;
        }
    };
    var state = State{};
    node.behavior.events.on_event = State.event;
    node.behavior.events.event_context = &state;
    cx.setFocus(node);
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqual(node, cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(node, cx.focused_node.?);
}

test "FocusManager: keyboard default activation requires its original live focus owner" {
    const Mutation = enum { destroy, redirect };
    for ([_]Mutation{ .destroy, .redirect }) |mutation| {
        const cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const a = try core.box(cx, .{}, .{});
        const b = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, a);
        try root.appendChild(cx.allocator, b);
        a.setFocusable(true);
        b.setFocusable(true);
        const State = struct {
            cx: *core.Cx,
            source: *Node,
            other: *Node,
            mutation: Mutation,
            clicks: usize = 0,
            fn event(e: Event, ptr: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(ptr.?));
                if (e == .key_down) {
                    switch (self.mutation) {
                        .destroy => {
                            self.cx.detachChild(self.source.parent.?, self.source);
                            self.cx.freeNode(self.source);
                        },
                        .redirect => self.cx.setFocus(self.other),
                    }
                }
                if (e == .click) self.clicks += 1;
                return .ignored;
            }
        };
        var state = State{ .cx = cx, .source = a, .other = b, .mutation = mutation };
        a.behavior.events.on_event = State.event;
        a.behavior.events.event_context = &state;
        cx.layout();
        _ = cx.render();
        cx.setFocus(a);
        cx.handleKeyDown(.@"return", .{});
        try std.testing.expectEqual(@as(usize, 0), state.clicks);
        try std.testing.expectEqual(if (mutation == .redirect) b else null, cx.focus_manager.getFocused());
    }
}

test "FocusManager: action callbacks cannot forward keys to a stale focus owner" {
    const Mutation = enum { destroy, redirect };
    for ([_]Mutation{ .destroy, .redirect }) |mutation| {
        const cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const a = try core.box(cx, .{}, .{});
        const b = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, a);
        try root.appendChild(cx.allocator, b);
        a.setFocusable(true);
        b.setFocusable(true);
        a.behavior.interaction.key_context = "review-keyboard";
        const State = struct {
            cx: *core.Cx,
            source: *Node,
            other: *Node,
            mutation: Mutation,
            key_calls: usize = 0,
            fn action(_: @import("actions.zig").Action, ptr: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(ptr.?));
                switch (self.mutation) {
                    .destroy => {
                        self.cx.detachChild(self.source.parent.?, self.source);
                        self.cx.freeNode(self.source);
                    },
                    .redirect => self.cx.setFocus(self.other),
                }
                return .ignored;
            }
            fn event(e: Event, ptr: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(ptr.?));
                if (e == .key_down) self.key_calls += 1;
                return .ignored;
            }
        };
        var state = State{ .cx = cx, .source = a, .other = b, .mutation = mutation };
        a.behavior.events.on_action = State.action;
        a.behavior.events.action_context = &state;
        a.behavior.events.on_event = State.event;
        a.behavior.events.event_context = &state;
        cx.action_dispatcher.bind(.s, .{ .super = true }, .{ .context = "review-keyboard", .name = "save" });
        cx.layout();
        _ = cx.render();
        cx.setFocus(a);
        cx.handleKeyDown(.s, .{ .super = true });
        try std.testing.expectEqual(@as(usize, 0), state.key_calls);
        try std.testing.expectEqual(if (mutation == .redirect) b else null, cx.focus_manager.getFocused());
    }
}

test "FocusManager: unregister focus does not remove callback-shifted neighbor" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const a = try core.box(cx, .{}, .{});
    const b = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, a);
    try root.appendChild(cx.allocator, b);
    const S = struct {
        cx: *core.Cx,
        node: *core.Node,
        fn blur(self: *@This()) void {
            self.cx.focus_manager.unregisterFocusable(self.node);
        }
    };
    var state = S{ .cx = cx, .node = a };
    try cx.focus_manager.registerFocusable(a);
    try cx.focus_manager.registerFocusable(b);
    cx.setFocus(a);
    a.behavior.events.on_blur = core.Cx.handlerFrom(S, &state, S.blur);
    cx.focus_manager.unregisterFocusable(a);
    a.behavior.events.on_blur = null;
    try std.testing.expectEqual(@as(usize, 1), cx.focus_manager.focus_order.items.len);
    try std.testing.expectEqual(b, cx.focus_manager.focus_order.items[0]);
}

test "FocusManager: identity allocation failure preserves the current owner" {
    const alloc = std.testing.allocator;
    const a = try Node.create(alloc, 98001, .box, .{});
    defer a.destroy(alloc);
    const b = try Node.create(alloc, 98002, .box, .{});
    defer b.destroy(alloc);
    var fm = FocusManager.init(alloc);
    defer fm.deinit();
    fm.setFocus(a);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var registry = NodeRegistry.init(failing.allocator());
    defer registry.deinit();
    fm.setRegistry(&registry);
    const State = struct {
        blurs: usize = 0,
        fn blur(self: *@This()) void {
            self.blurs += 1;
        }
    };
    var state = State{};
    a.behavior.events.on_blur = core.Cx.handlerFrom(State, &state, State.blur);
    fm.setFocus(b);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(a, fm.getFocused().?);
    try std.testing.expectEqual(@as(usize, 0), state.blurs);
}

test "FocusManager: settled hook may synchronously redirect again" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const a = try core.box(cx, .{}, .{});
    const b = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, a);
    try root.appendChild(cx.allocator, b);
    const State = struct {
        cx: *core.Cx,
        target: *Node,
        original: *const fn (*anyopaque) void,
        original_context: *anyopaque,
        calls: usize = 0,
        fn settled(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) self.cx.setFocus(self.target);
            self.original(self.original_context);
        }
    };
    var state = State{
        .cx = cx,
        .target = b,
        .original = cx.focus_manager.on_focus_settled.?,
        .original_context = cx.focus_manager.settled_context.?,
    };
    cx.focus_manager.on_focus_settled = State.settled;
    cx.focus_manager.settled_context = &state;
    defer {
        cx.focus_manager.on_focus_settled = state.original;
        cx.focus_manager.settled_context = state.original_context;
    }
    cx.layout();
    _ = cx.render();
    cx.setFocus(a);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectEqual(b, cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(b, cx.focused_node.?);
    try std.testing.expectEqual(cx.node_registry.handleFor(b), cx.focused_handle.?);
}
