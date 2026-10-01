//! Cx 输入事件入口：鼠标 down/up/move（含 pointer capture 回同步、按下聚焦决策）、
//! click / command / action、键盘、文本输入与 IME、滚轮 / 缩放手势、拖放。
//! 事件分发本体在 event_dispatcher.zig；这里负责命中、状态记账与路由。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_render = @import("cx_render.zig");
const cx_platform = @import("cx_platform.zig");
const event_dispatcher_mod = @import("../event_dispatcher.zig");
const system_sdk_mod = @import("system_sdk");
const CursorShape = core.CursorShape;
const CursorToken = core.CursorToken;
const CustomCursorDesc = core.CustomCursorDesc;
const Event = core.Event;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;
const MouseButton = core.MouseButton;
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const a11y_macos_bridge_mod = @import("../a11y/macos_bridge.zig");
const actions_mod = @import("../actions.zig");
const cx_cursor = @import("cx_cursor.zig");
const cx_hit_target = @import("cx_hit_target.zig");
const cx_runtime_index = @import("cx_runtime_index.zig");
const debug_env = @import("debug_env.zig");
const devtoolsHitDebugEnabled = debug_env.devtoolsHitDebugEnabled;
const ensureDevtoolsHitDebugBanner = cx_hit_target.ensureDevtoolsHitDebugBanner;
const events_mod = @import("../events.zig");
const hitSceneDebugEnabled = debug_env.hitSceneDebugEnabled;
const inspector_mod = @import("inspector.zig");
const interaction_drag = @import("../interaction/drag.zig");
const logDebugNodeSummary = cx_hit_target.logDebugNodeSummary;
const resolveInteractionTarget = cx_hit_target.resolveInteractionTarget;
const shouldPreserveFocusForOverlayPointerTarget = cx_hit_target.shouldPreserveFocusForOverlayPointerTarget;

pub fn handleMouseDown(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
    self.handleMouseDownEx(x, y, .left, modifiers);
}

pub fn handleMouseDownEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
    self.mouse_x = x;
    self.mouse_y = y;
    self.cursor_state.pointer_valid = true;
    defer cx_cursor.updateCursorShape(self);
    self.needs_redraw = true;
    // 同一按键的新一次按下意味着上一次被吞按下的抬起已经丢了（同键不可能
    // 连按两次而中间没有抬起）；残留标记会把这次正常按下的抬起吞掉。
    if (self.swallowed_press_button == button) self.swallowed_press_button = null;
    if (button == .left and self.inspector.handleMouseDown(self, x, y)) {
        return;
    }
    // feed gesture_arena。只对 left button (主键) 启 gesture
    // arena，右键 / 中键各自走 dispatcher 但不参与手势识别 (UIKit 同样
    // 只把 primary touch 入 arena)。
    if (button == .left) {
        self.gesture_arena.reset();
        self.gesture_arena.onTouchDown(x, y, std.time.nanoTimestamp());
    }
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root != null) {
        const hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        });
        const target_handle = if (hit) |result| result.handle else null;
        const raw_target = if (hit) |result| self.node_registry.resolve(result.handle, &self.perf) else null;
        const target = resolveInteractionTarget(raw_target);

        if (devtoolsHitDebugEnabled()) {
            ensureDevtoolsHitDebugBanner();
            std.debug.print(
                "[devtools-hit] mouse_down win={d} button={s} xy=({d:.1},{d:.1}) modifiers=(cmd={any} shift={any} alt={any} ctrl={any})\n",
                .{ self.window_id, @tagName(button), x, y, modifiers.super, modifiers.shift, modifiers.alt, modifiers.ctrl },
            );
            if (raw_target != target) logDebugNodeSummary("raw_pointer_hit", raw_target);
            logDebugNodeSummary("pointer_hit", target);
        }

        // `.close_and_consume` 的浮层：面板外的这一下只负责关闭，按下与随后的
        // 抬起都不分发（不合成 click，不改焦点）。
        if (self.overlay_stack.consumeOutsidePress(target)) {
            self.swallowed_press_button = button;
            if (button == .left) self.gesture_arena.reset();
            return;
        }

        if (button != .left) {
            _ = self.dispatcher.dispatchMouseDownButton(x, y, target, button, modifiers);
            rebuildRuntimeIndexesIfCurrentRootDirty(self);
            return;
        }

        self.interaction_index.setMouseDownResult(hit);
        // 焦点决策在分发前按当时的树做出：handler 可能重建子树，事后再沿父链
        // 查找会读到新树（或悬垂节点）。
        const focus_decision = resolvePointerDownFocus(target);
        const preserve_overlay_focus = shouldPreserveFocusForOverlayPointerTarget(self, target);
        const focus_target_handle_pre = switch (focus_decision) {
            .focus => |ft| self.node_registry.handleFor(ft),
            .preserve, .clear => null,
        };

        // 分发前记下按下所属的浮层：handler 可能当场关闭它并失效这批引用。
        const press_owner = self.overlay_stack.findPressOwner(target);
        _ = self.dispatcher.dispatchMouseDownButton(x, y, target, .left, modifiers);
        rebuildRuntimeIndexesIfCurrentRootDirty(self);

        const focus_target = self.node_registry.resolve(focus_target_handle_pre, &self.perf);
        if (focus_target != null) {
            self.focus_manager.setFocusWithReason(focus_target, .click);
        } else if (focus_decision != .preserve and !preserve_overlay_focus) {
            self.focus_manager.clearFocus();
        }
        // Callbacks may redirect or destroy the initial target. Read the
        // settled authority, including the explicit preserve/no-op path.
        cx_platform.syncFocusedCache(self);

        self.pressed_node = self.node_registry.resolve(target_handle, &self.perf);
        self.pressed_handle = target_handle;
        self.press_overlay_owner = press_owner;
        self.last_mouse_down_target = self.pressed_node;
        self.last_mouse_down_handle = target_handle;
        self.has_new_mouse_down = true;

        if (devtoolsHitDebugEnabled()) {
            logDebugNodeSummary("focus_target", focus_target);
            logDebugNodeSummary("pressed_node", self.pressed_node);
        }
    }
}

/// 节点是否可聚焦 (focusable 或 tab_index != null)
fn isNodeFocusable(n: *Node) bool {
    return n.behavior.interaction.focusable or n.behavior.interaction.tab_index != null;
}

const PointerDownFocusDecision = union(enum) {
    /// 焦点交给该节点（命中节点自身或最近的 focusable 祖先）。
    focus: *Node,
    /// 父链上先遇到了 `pointer_down_focus = .preserve`：焦点保持不变。
    preserve,
    /// 父链上既无 focusable 也无 preserve：清空焦点（overlay 例外另判）。
    clear,
};

/// 从命中节点沿父链向上，取最先出现的 `.preserve` 或 focusable 节点。
/// 同一节点上 `.preserve` 优先于 focusable。
fn resolvePointerDownFocus(node_opt: ?*Node) PointerDownFocusDecision {
    var current = node_opt;
    while (current) |n| {
        if (n.behavior.interaction.pointer_down_focus == .preserve) return .preserve;
        if (isNodeFocusable(n)) return .{ .focus = n };
        current = n.parent;
    }
    return .clear;
}

pub fn handleMouseUp(self: *Cx, x: f32, y: f32) void {
    self.handleMouseUpEx(x, y, .left, .{});
}

pub fn handleMouseUpEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
    self.mouse_x = x;
    self.mouse_y = y;
    self.cursor_state.pointer_valid = true;
    defer cx_cursor.updateCursorShape(self);
    self.needs_redraw = true;
    // feed gesture_arena (只 primary button)
    if (button == .left) {
        self.gesture_arena.onTouchUp(x, y, std.time.nanoTimestamp());
    }
    if (self.swallowed_press_button) |swallowed| {
        if (swallowed == button) {
            self.swallowed_press_button = null;
            if (button == .left) self.gesture_arena.reset();
            return;
        }
    }
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root != null) {
        const had_pointer_capture = button == .left and self.dispatcher.hasPointerCapture();
        const hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        });
        const target_handle = if (hit) |result| result.handle else null;
        const raw_target = if (hit) |result| self.node_registry.resolve(result.handle, &self.perf) else null;
        const target = resolveInteractionTarget(raw_target);
        self.dispatcher.dispatchMouseUpButton(x, y, target, button, modifiers);
        rebuildRuntimeIndexesIfCurrentRootDirty(self);
        if (button == .left and had_pointer_capture) {
            self.resyncPointerAfterCaptureRelease(x, y, target_handle);
        }
    }
    if (button == .left) {
        self.pressed_node = null; // 释放按下状态
        self.pressed_handle = null;
    }
}

pub fn resyncPointerAfterCaptureRelease(self: *Cx, x: f32, y: f32, fallback_handle: ?NodeHandle) void {
    var synced_target: ?*Node = null;
    if (self.root != null) {
        cx_render.ensureHitTestSceneFresh(self);
        const synced_hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        });
        const synced_handle = if (synced_hit) |result| result.handle else fallback_handle;
        const synced_raw_target = self.node_registry.resolve(synced_handle, &self.perf);
        synced_target = resolveInteractionTarget(synced_raw_target);
    }
    self.hovered_node = self.dispatcher.syncHover(synced_target);
    self.hovered_handle = if (self.hovered_node) |n| self.node_registry.handleFor(n) else null;
    cx_cursor.updateCursorShape(self);
}

/// 索引重建的 OOM 一律 panic，不吞。
///
/// rebuildRuntimeStateRecursive 是**先清 dirty 位、再做可失败的
/// node_registry.put / focus_order.append**。所以中途 OOM 会留下
/// 「节点已标记为干净、但不在 node_registry / focus_order 里」的状态：
/// 该节点从此 hit-test 打不中、Tab 走不到，而且再没有 dirty 位能触发重试
/// 静默且永久的错乱。fullRebuildRuntimeIndexes 更糟：它先 clear()，
/// OOM 会让整棵树的索引空掉而所有节点都是干净的。
///
/// 这些调用点位于 handleMouse* / render 等 Stable 签名（见
/// docs/API_STABILITY.md）之下，无法传播 `!`，故 panic。
pub fn rebuildRuntimeIndexesIfCurrentRootDirty(self: *Cx) void {
    const root = self.root orelse return;
    if (!root.frame_state.state_bits.dirty.runtime.subtree_dirty) return;
    // 结构变更几乎总伴随布局脏（新换入的子树 rect 还是 0）。此时直接重建会按未布局的
    // 几何建出空命中代理（0 尺寸不出代理，但 plannedProxyCount 不看尺寸，partial 校验照样通过），
    // 随后 clearInteractionDirtyRecursive 把整棵子树的 hit 脏位消费掉，之后的布局不会再
    // 触发命中重建，这些节点永久点不中。先布局再重建：与事件入口 ensureHitTestSceneFresh 同一路径。
    if ((root.frame_state.state_bits.dirty.core.layout or root.frame_state.state_bits.dirty.core.subtree_layout) and
        self.tick_depth == 0 and !self.draining_deferred_frees)
    {
        cx_render.forceTickAndRebuildForHitTest(self);
        return;
    }
    cx_runtime_index.rebuildRuntimeIndexes(self) catch @panic("OOM: rebuildRuntimeIndexes (current root dirty)");
}

pub fn handleMouseMove(self: *Cx, x: f32, y: f32) void {
    self.handleMouseMoveEx(x, y, .{});
}

pub fn handleMouseMoveEx(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
    // R4a: 只在鼠标实际移动时标脏，hover 命中随指针位置变化，需要一帧
    // 重新 dispatch；位置不变的 move 事件不该唤醒新帧（idle 停帧门控依赖这一点）
    const hit_tests_before = self.perf.hit_test_count;
    cx_render.ensureHitTestSceneFresh(self);
    if (x != self.mouse_x or y != self.mouse_y) {
        self.needs_redraw = true;
    }
    self.mouse_x = x;
    self.mouse_y = y;
    // feed gesture_arena
    self.cursor_state.pointer_valid = true;
    self.gesture_arena.onTouchMove(x, y, std.time.nanoTimestamp());
    if (self.root != null) {
        const has_capture = self.dispatcher.hasPointerCapture();
        const hit = if (has_capture)
            null
        else
            self.hitTestQuery(.{
                .kind = .pointer,
                .world_x = x,
                .world_y = y,
            });
        self.interaction_index.setHoveredResult(hit);
        var raw_hovered = if (hit) |result| self.node_registry.resolve(result.handle, &self.perf) else null;
        // Hover 滞回：partial interaction rebuild 在子树重建的间隙对新节点
        // 的收录有缺口（多处 app 侧撞过的同一堵墙），移动中的查询会在
        // 有效坐标上间歇 MISS。MISS 时若上一个 hovered 节点仍存活且几何
        // 上仍包含指针，保持 hover，否则光标会在 pointer↔default 之间
        // 抖（实弹：file tab 关闭按钮附近 hover 状态机最活跃，逐事件标脏
        // 场景，光标持续闪烁）。真离开时旧节点 rect 不再包含指针，照常清。
        if (raw_hovered == null and !has_capture) {
            if (self.hovered_handle) |h| {
                if (self.node_registry.resolve(h, &self.perf)) |prev| {
                    const r = prev.rectFromWorldOrFallback();
                    if (r.w > 0 and r.h > 0 and r.contains(x, y)) raw_hovered = prev;
                }
            }
        }
        if (hitSceneDebugEnabled()) {
            if (hit) |h| {
                const proxy = self.interaction_index.proxies.items[h.proxy_id];
                std.debug.print("[hit-move] ({d:.0},{d:.0}) -> id={d} comp={s} aabb=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{
                    x,                                y,
                    if (raw_hovered) |n| n.id else 0, if (raw_hovered) |n| (n.meta.ownership.meta.component_name orelse "-") else "-",
                    proxy.true_aabb.x,                proxy.true_aabb.y,
                    proxy.true_aabb.w,                proxy.true_aabb.h,
                });
            } else if (raw_hovered) |kept| {
                std.debug.print("[hit-move] ({d:.0},{d:.0}) -> MISS (hover 滞回保持 id={d})\n", .{ x, y, kept.id });
            } else {
                std.debug.print("[hit-move] ({d:.0},{d:.0}) -> MISS\n", .{ x, y });
            }
        }
        const hovered = resolveInteractionTarget(raw_hovered);
        self.perf.mouse_move_hit_test_count += 1;
        self.hovered_node = self.dispatcher.dispatchMouseMoveEx(x, y, hovered, modifiers);
        self.hovered_handle = if (self.hovered_node) |n| self.node_registry.handleFor(n) else null;
    }
    std.debug.assert(self.perf.hit_test_count - hit_tests_before <= 1);
    // 更新系统光标
    cx_cursor.updateCursorShape(self);
    self.inspector.handleMouseMove(self, x, y);
}

pub fn cancelPointerInteractions(self: *Cx, reason: interaction_drag.CancelReason) void {
    self.drag_manager.cancel(self, reason);
    // 被 consume 吞掉的按下随交互一起作废：它的抬起不会再来（或来了也不该再吞），
    // 标记留着会吞掉下一次正常点击的抬起。
    self.swallowed_press_button = null;
    self.dispatcher.cancelClickSynthesisForActivePointer();
    self.dispatcher.releasePointerCapture();
    self.cursor_state.leases.clearRetainingCapacity();
    self.cursor_override = null;
    // gesture：中断把 began/changed 转 cancelled（此前无人写 .cancelled，
    // 系统级中断后识别器卡死在中途态）
    self.gesture_arena.onTouchCancel(std.time.nanoTimestamp());
    // 进行中的触控板滚动同理：结束信号可能永远不会来，主动补发
    self.dispatcher.cancelScrollGesture();
    cx_cursor.updateCursorShape(self);
}

pub fn acquireCursor(self: *Cx, owner: *Node, shape: CursorShape) !CursorToken {
    return cx_cursor.acquireCursor(self, owner, shape);
}

pub fn updateCursor(self: *Cx, token: CursorToken, shape: CursorShape) void {
    return cx_cursor.updateCursor(self, token, shape);
}

pub fn releaseCursor(self: *Cx, token: CursorToken) void {
    return cx_cursor.releaseCursor(self, token);
}

pub fn refreshCursor(self: *Cx) void {
    return cx_cursor.refreshCursor(self);
}

pub fn replayCursor(self: *Cx) void {
    return cx_cursor.replayCursor(self);
}

pub fn setCursorOverride(self: *Cx, shape: ?CursorShape) void {
    return cx_cursor.setCursorOverride(self, shape);
}

pub fn setCustomCursor(self: *Cx, desc: CustomCursorDesc) void {
    return cx_cursor.setCustomCursor(self, desc);
}

pub fn activeCustomCursorKey(self: *const Cx) ?u64 {
    return cx_cursor.activeCustomCursorKey(self);
}

pub fn updateAutomationCursor(self: *Cx, x: f32, y: f32, pressed: ?bool) void {
    return cx_cursor.updateAutomationCursor(self, x, y, pressed);
}

pub fn handleClick(self: *Cx, x: f32, y: f32) void {
    self.handleMouseDown(x, y, .{});
    self.handleMouseUp(x, y);
}

pub fn bindCommandAction(self: *Cx, command_id: u64, action: actions_mod.Action) void {
    self.action_dispatcher.bindCommand(command_id, action);
}

pub fn handleCommand(self: *Cx, command_id: u64) void {
    const action = self.action_dispatcher.matchCommand(command_id) orelse return;
    const target = self.focus_manager.getFocused() orelse self.root orelse return;
    const delivery = self.action_dispatcher.dispatchActionWithDelivery(action, target);
    // 焦点链上没人接：菜单命令是 app 级的，不能因为"当前没聚焦到绑定
    // 上下文里"就静默丢弃（实锤：cx.root 是 App 的内部 wrapper，用户
    // mount root 绑的 context 在向上遍历里永远走不到，真菜单点击
    // verify_menu.sh 逮到）。降级为全树找第一个匹配 context 的节点。
    if (delivery.result == .ignored and !delivery.delivered) {
        if (self.root) |root| {
            if (findActionContextNode(root, action.context)) |node| {
                if (node.behavior.events.on_action) |action_handler| {
                    _ = action_handler(action, node.behavior.events.action_context);
                }
            }
        }
    }
    self.needs_redraw = true;
}

fn findActionContextNode(node: *Node, context: []const u8) ?*Node {
    if (node.behavior.interaction.key_context) |ctx| {
        if (std.mem.eql(u8, ctx, context) and node.behavior.events.on_action != null) return node;
    }
    for (node.children.items) |child| {
        if (findActionContextNode(child, context)) |found| return found;
    }
    return null;
}

pub fn handleKeyDown(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
    self.needs_redraw = true;
    if (inspector_mod.isToggleShortcut(key, modifiers)) {
        self.inspector.enabled = !self.inspector.enabled;
        if (!self.inspector.enabled) {
            self.inspector.pick_mode = false;
            self.inspector.clearSelection();
        }
        return;
    }
    // Drag session 优先消费 Escape（必须在 overlay stack 之前，否则一次
    // Escape 会同时取消 drag 并 dismiss 顶层浮层）。pending 静默清理、
    // active 发 cancel，两者都吞掉本次 Escape。
    if (key == .escape and self.drag_manager.handleEscape(self)) return;
    // OverlayStack: Escape 只关闭最顶层浮层
    if (key == .escape and self.overlay_stack.handleEscape()) return;

    if (key == .tab) {
        // 先分发给 focused 节点（编辑器等组件需要拦截 tab 做缩进）
        if (self.focus_manager.getFocused()) |focused| {
            const result = self.dispatcher.dispatchKeyDown(focused, .{
                .key = key,
                .modifiers = modifiers,
            });
            if (events_mod.preventsDefault(result)) return;
        }
        // 节点未处理，执行默认的焦点切换
        if (modifiers.shift) {
            self.focus_manager.focusPrev();
        } else {
            self.focus_manager.focusNext();
        }
        return;
    }

    if (self.focus_manager.getFocused()) |focused| {
        self.focused_node = focused;
        self.focused_handle = self.node_registry.handleFor(focused);
        const keyboard_target = self.focused_handle;
        // 先查询 Action 绑定
        if (self.action_dispatcher.matchKey(key, modifiers)) |action| {
            const result = self.action_dispatcher.dispatchAction(action, focused);
            if (events_mod.preventsDefault(result)) return;
            if (resolveKeyboardTarget(self, keyboard_target) == null) return;
        }

        // Space/Enter: 先 dispatch key_down，如果节点未处理则合成 click
        if (key == .space or key == .@"return") {
            const key_result = self.dispatcher.dispatchKeyDown(focused, .{
                .key = key,
                .modifiers = modifiers,
            });
            if (!events_mod.preventsDefault(key_result)) {
                // A key handler may destroy/rebind its node or redirect
                // focus. Default activation belongs only to the original
                // still-live, still-focused owner of this key sequence.
                const live_target = resolveKeyboardTarget(self, keyboard_target) orelse return;
                _ = self.dispatcher.dispatch(Event{ .click = .{
                    .x = 0,
                    .y = 0,
                    .modifiers = modifiers,
                } }, live_target);
            }
            return;
        }

        _ = self.dispatcher.dispatchKeyDown(focused, .{
            .key = key,
            .modifiers = modifiers,
        });
    } else if (self.root) |root| {
        // 没 focused 时 fallback 到 root，让 app/island 级别的快捷键也能工作
        _ = self.dispatcher.dispatchKeyDown(root, .{
            .key = key,
            .modifiers = modifiers,
        });
    }
}

fn resolveKeyboardTarget(self: *Cx, identity: ?NodeHandle) ?*Node {
    const target = self.node_registry.resolve(identity, null) orelse return null;
    return if (self.focus_manager.getFocused() == target) target else null;
}

pub fn handleKeyUp(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
    self.needs_redraw = true;
    if (self.focus_manager.getFocused()) |focused| {
        self.focused_node = focused;
        self.focused_handle = self.node_registry.handleFor(focused);
        _ = self.dispatcher.dispatchKeyUp(focused, .{
            .key = key,
            .modifiers = modifiers,
        });
    }
}

/// Return the focused node only when it publishes the live text-input
/// contract and has an event sink. Element tags are visual/semantic hints;
/// they are no longer used as a platform-input capability switch.
fn focusedTextInput(self: *Cx) ?*Node {
    const focused = self.focus_manager.getFocused() orelse return null;
    if (focused.behavior.interaction.text_input_client == null or
        focused.behavior.events.on_event == null) return null;
    return focused;
}

pub fn handleTextInput(self: *Cx, t: []const u8) void {
    const focused = focusedTextInput(self) orelse return;
    const deferred = focused.behavior.interaction.deferred_text_input_redraw;
    if (!deferred) self.needs_redraw = true;
    const result = self.dispatcher.dispatchTextInput(focused, t);
    if (deferred and result != .stop) self.needs_redraw = true;
}

pub fn handleImePreedit(self: *Cx, preedit_text: []const u8, cursor_utf8_offset: u32) void {
    self.handleImePreeditReplace(preedit_text, cursor_utf8_offset, events_mod.ime_no_replacement, events_mod.ime_no_replacement);
}

pub fn handleImePreeditReplace(self: *Cx, preedit_text: []const u8, cursor_utf8_offset: u32, replace_start_utf8: u32, replace_end_utf8: u32) void {
    const focused = focusedTextInput(self) orelse return;
    self.needs_redraw = true;
    const owner = self.node_registry.handleFor(focused);
    const client_context = focused.behavior.interaction.text_input_client.?.context;
    _ = self.dispatcher.dispatchImePreeditReplace(focused, preedit_text, cursor_utf8_offset, replace_start_utf8, replace_end_utf8);
    const current = focusedTextInput(self) orelse return;
    if (!std.meta.eql(owner, self.node_registry.handleFor(current)) or
        current.behavior.interaction.text_input_client.?.context != client_context) return;
    a11y_macos_bridge_mod.publishAppliedPreedit(cx_platform.a11yWindowKey(self));
}

pub fn handleImeCommit(self: *Cx, commit_text: []const u8) void {
    self.handleImeCommitReplace(commit_text, events_mod.ime_no_replacement, events_mod.ime_no_replacement);
}

pub fn handleImeCommitReplace(self: *Cx, commit_text: []const u8, replace_start_utf8: u32, replace_end_utf8: u32) void {
    const focused = focusedTextInput(self) orelse return;
    const deferred = focused.behavior.interaction.deferred_text_input_redraw;
    if (!deferred) self.needs_redraw = true;
    const result = self.dispatcher.dispatchImeCommitReplace(focused, commit_text, replace_start_utf8, replace_end_utf8);
    if (deferred and result != .stop) self.needs_redraw = true;
}

pub fn scrollEventFromSdk(wheel: system_sdk_mod.events.MouseWheel) events_mod.ScrollEvent {
    return .{
        .x = wheel.x,
        .y = wheel.y,
        .dx = wheel.dx,
        .dy = wheel.dy,
        .phase = switch (wheel.phase) {
            .none => .none,
            .may_begin => .may_begin,
            .began => .began,
            .changed => .changed,
            .ended => .ended,
            .cancelled => .cancelled,
        },
        .momentum = switch (wheel.momentum) {
            .none => .none,
            .began => .began,
            .changed => .changed,
            .ended => .ended,
        },
        .modifiers = .{
            .shift = wheel.modifiers.shift,
            .ctrl = wheel.modifiers.ctrl,
            .alt = wheel.modifiers.alt,
            .super = wheel.modifiers.super,
        },
    };
}

pub fn handleScroll(self: *Cx, scroll: events_mod.ScrollEvent) void {
    // pinch 手势进行中抑制 trackpad 滚动派发（捏合与双指平移同源，
    // 同时派发会导致缩放时画面乱跳），同一手势期间不同时收到 pan/scroll。
    if (self.magnify_target_handle != null and scroll.isTrackpad()) return;
    self.needs_redraw = true;
    // 先结束丢失了 ended 的上一个手势，再做命中测试
    self.dispatcher.beginScrollEvent(scroll);
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root != null) {
        const scroll_hit = self.hitTestQuery(.{
            .kind = .scroll,
            .world_x = scroll.x,
            .world_y = scroll.y,
        });
        const pointer_hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = scroll.x,
            .world_y = scroll.y,
        });
        const raw_pointer_target = if (pointer_hit) |result|
            self.node_registry.resolve(result.handle, &self.perf)
        else
            null;
        const pointer_target = resolveInteractionTarget(raw_pointer_target);
        const preferred_target = event_dispatcher_mod.nearestCompatibleScrollOwner(pointer_target, scroll.dx, scroll.dy);
        const scroll_target = if (scroll_hit) |result|
            self.node_registry.resolve(result.handle, &self.perf)
        else
            null;
        const hit_target = preferred_target orelse event_dispatcher_mod.nearestCompatibleScrollOwner(scroll_target, scroll.dx, scroll.dy);

        if (devtoolsHitDebugEnabled()) {
            ensureDevtoolsHitDebugBanner();
            std.debug.print(
                "[devtools-hit] scroll win={d} xy=({d:.1},{d:.1}) delta=({d:.1},{d:.1}) momentum={s} phase={s}\n",
                .{ self.window_id, scroll.x, scroll.y, scroll.dx, scroll.dy, @tagName(scroll.momentum), @tagName(scroll.phase) },
            );
            if (raw_pointer_target != pointer_target) logDebugNodeSummary("raw_pointer_hit", raw_pointer_target);
            logDebugNodeSummary("pointer_hit", pointer_target);
            logDebugNodeSummary("preferred_scroll_owner", preferred_target);
            logDebugNodeSummary("scroll_hit", scroll_target);
            logDebugNodeSummary("dispatch_scroll_target", hit_target);
        }
        if (scroll.isMomentum()) {
            self.interaction_index.setScrollMomentumOwner(scroll_hit);
        } else {
            self.interaction_index.setScrollSessionOwner(scroll_hit);
        }
        _ = self.dispatcher.dispatchScroll(scroll, hit_target);
    }
}

pub fn handleMagnify(self: *Cx, magnification: f32, x: f32, y: f32, phase: events_mod.GesturePhase) void {
    self.needs_redraw = true;
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root == null) return;
    if (phase == .began or self.magnify_target_handle == null) {
        const hit = self.hitTestQuery(.{ .kind = .pointer, .world_x = x, .world_y = y });
        self.magnify_target_handle = if (hit) |result| result.handle else null;
    }
    const target = if (self.magnify_target_handle) |h|
        self.node_registry.resolve(h, &self.perf)
    else
        null;
    if (target) |t| {
        _ = self.dispatcher.dispatch(.{ .magnify = .{
            .magnification = magnification,
            .x = x,
            .y = y,
            .phase = phase,
        } }, t);
    }
    if (phase == .ended or phase == .cancelled) {
        self.magnify_target_handle = null;
    }
}

pub fn handleDrag(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8) void {
    handleDragPayload(self, x, y, kind, paths, if (paths.len > 0) 1 else 0, false, false);
}

pub fn handlePlatformDrag(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8, payload_kind: u8, payload_truncated: bool, payload_is_untrusted: bool) void {
    handleDragPayload(self, x, y, kind, paths, payload_kind, payload_truncated, payload_is_untrusted);
}

fn handleDragPayload(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8, payload_kind_raw: u8, payload_truncated: bool, payload_is_untrusted: bool) void {
    self.needs_redraw = true;
    // kind=4 = 拖拽源完成回执（beginDrag 的 completion/cancellation，带
    // source_token/operation），不是指针位置事件，不进 hit-test 派发。
    // 未来更大的 kind 同样防御性忽略：@enumFromInt 对未知值是 checked
    // panic（实锤：verify_interop_probe.sh 里拖出松手即整个 app abort）。
    if (kind > @intFromEnum(events_mod.DragEvent.Kind.dropped)) return;
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root == null) return;

    const drag_kind: events_mod.DragEvent.Kind = @enumFromInt(kind);
    const payload_kind = std.meta.intToEnum(events_mod.DragEvent.PayloadKind, payload_kind_raw) catch .none;

    // 上一个目标：走 handle resolve，节点已释放时自动得到 null。
    const prev: ?*Node = if (self.drag_hover_handle) |h|
        self.node_registry.resolve(h, &self.perf)
    else
        null;

    // exited（离开窗口）不做命中：光标已经在窗口外，此时的坐标无意义。
    const target: ?*Node = if (drag_kind == .exited) null else blk: {
        const hit = self.hitTestQuery(.{ .kind = .pointer, .world_x = x, .world_y = y });
        break :blk if (hit) |result|
            self.node_registry.resolve(result.handle, &self.perf)
        else
            null;
    };

    // 跨节点边界：给旧目标补 exited，给新目标补 entered。
    if (prev != target) {
        if (prev) |p| {
            _ = self.dispatcher.dispatch(.{ .drag = .{
                .x = x,
                .y = y,
                .kind = .exited,
                .payload_kind = payload_kind,
                .payload_truncated = payload_truncated,
                .payload_is_untrusted = payload_is_untrusted,
            } }, p);
        }
        if (target) |t| {
            _ = self.dispatcher.dispatch(.{ .drag = .{
                .x = x,
                .y = y,
                .kind = .entered,
                .payload_kind = payload_kind,
                .payload_truncated = payload_truncated,
                .payload_is_untrusted = payload_is_untrusted,
            } }, t);
        }
    }

    self.drag_hover_handle = if (target) |t| self.node_registry.handleFor(t) else null;

    // 已经在上面补发过的 entered/exited 不重复派发。
    if (target) |t| {
        if (drag_kind == .updated or drag_kind == .dropped or
            (drag_kind == .entered and prev == target))
        {
            _ = self.dispatcher.dispatch(.{ .drag = .{
                .x = x,
                .y = y,
                .kind = drag_kind,
                .paths = paths,
                .payload_kind = payload_kind,
                .payload_truncated = payload_truncated,
                .payload_is_untrusted = payload_is_untrusted,
            } }, t);
        }
    }

    // 会话结束（放下或离开窗口）：清掉悬停态，避免下次拖拽误判为"仍在原目标"。
    if (drag_kind == .dropped or drag_kind == .exited) {
        self.drag_hover_handle = null;
    }
}
