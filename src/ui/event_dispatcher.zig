/// Event Dispatcher - Node 树事件调度
///
/// 事件传播顺序: capture -> target -> bubble
///
/// 事件处理流程:
/// 1. 命中测试: 确定目标节点
/// 2. 构建路径: root -> ... -> target
/// 3. Capture 阶段: 从 root 到 target (**不含 target**) 逐一调用
///    node.behavior.events.on_event_capture (v0.6 §2.2)。null handler 节点
///    零开销跳过；用于祖先抢先拦截 (focus trap / scroll lock / 手势仲裁)
/// 4. Target 阶段: 在目标节点上调用 on_event + click/key 等专用 handler
/// 5. Bubble 阶段: 从 target 父节点到 root 逐一调用
///
/// 任意阶段返回 .stop 都停止传播（capture stop 不再进 target/bubble，
/// 这是 W3C DOM Events 标准语义）。
const std = @import("std");
const Allocator = std.mem.Allocator;
const events = @import("events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const EventPhase = events.EventPhase;
const KeyEvent = events.KeyEvent;
const Modifiers = events.Modifiers;

// 前向引用 core 模块的 Node 类型
const core = @import("core.zig");
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const NodeRegistry = core.NodeRegistry;
const interaction_semantics = @import("core/interaction_semantics.zig");
const debug_trace = @import("core/debug_trace.zig");

fn treeHitDebugEnabled() bool {
    return false;
}

fn scrollDebugEnabled() bool {
    return false;
}

fn devtoolsHitDebugEnabled() bool {
    const raw = std.c.getenv("ZENIT_DEVTOOLS_HIT_DEBUG") orelse return false;
    const value = std.mem.span(raw);
    if (value.len == 0) return true;
    return !std.mem.eql(u8, value, "0");
}

fn logDevtoolsNodeSummary(comptime label: []const u8, node: ?*Node) void {
    if (node) |n| {
        const rect = n.globalRect();
        std.debug.print(
            "[devtools-hit] {s}=id={d} tag={s} component={s} test_id={s} rect=({d:.1},{d:.1},{d:.1},{d:.1})\n",
            .{
                label,
                n.id,
                @tagName(n.tag),
                n.meta.ownership.meta.component_name orelse "<none>",
                n.meta.ownership.meta.test_id orelse "<none>",
                rect.x,
                rect.y,
                rect.w,
                rect.h,
            },
        );
    } else {
        std.debug.print("[devtools-hit] {s}=<none>\n", .{label});
    }
}

fn isSidebarProbePoint(x: f32) bool {
    return x >= 0 and x <= 360;
}

fn logSidebarHit(comptime phase: []const u8, x: f32, y: f32, target: ?*Node) void {
    if (!treeHitDebugEnabled()) return;
    if (!isSidebarProbePoint(x)) return;
    if (target) |t| {
        std.debug.print(
            "[tree-hit] {s} ({d:.1},{d:.1}) -> id={d} tag={s} test_id={s} rect=({d:.1},{d:.1},{d:.1},{d:.1}) tx=({d:.1},{d:.1})\n",
            .{
                phase,
                x,
                y,
                t.id,
                @tagName(t.tag),
                t.meta.ownership.meta.test_id orelse "<none>",
                t.rectFromWorldOrFallback().x,
                t.rectFromWorldOrFallback().y,
                t.rectFromWorldOrFallback().w,
                t.rectFromWorldOrFallback().h,
                t.style.translate_x,
                t.style.translate_y,
            },
        );
    } else {
        std.debug.print("[tree-hit] {s} ({d:.1},{d:.1}) -> <none>\n", .{ phase, x, y });
    }
}

/// 事件调度器 - 基于 Node 树
pub const EventDispatcher = struct {
    allocator: Allocator,

    hovered_handle: ?NodeHandle = null,

    mouse_down_handle: ?NodeHandle = null,
    mouse_down_pos: [2]f32 = .{ 0, 0 },
    last_mouse_pos: [2]f32 = .{ 0, 0 },
    has_last_mouse: bool = false,

    /// 最近一次 mouseDown 的修饰键（合成 click 时使用）
    last_modifiers: events.Modifiers = .{},

    /// 多击检测
    last_click_instant: ?std.time.Instant = null,
    last_click_pos: [2]f32 = .{ 0, 0 },
    consecutive_clicks: u8 = 0,

    pointer_capture_handle: ?NodeHandle = null,
    /// Distinguishes release/reacquire even when the owner is unchanged.
    pointer_capture_epoch: u64 = 0,
    hover_epoch: u64 = 0,

    /// pointer-sequence 级 click 抑制（drag 前置合同，见 docs/DRAG_INTERACTION_DESIGN.md §8.3）。
    /// 左键 down 重置为 false；置 true 后本次序列的左键 up 不合成 click/double_click、
    /// 不更新 multi-click 计数（普通路径与 capture 路径都被 gate）。up 消费并清零。
    suppress_click: bool = false,

    /// Scroll 会话 owner（按节点 ID 锁定，避免跨帧重建后的悬垂指针）
    scroll_session_owner: ?NodeHandle = null,
    scroll_session_owner_ptr: ?*Node = null,
    /// 惯性阶段 owner（is_momentum=true 时固定派发）
    scroll_momentum_owner: ?NodeHandle = null,
    scroll_momentum_owner_ptr: ?*Node = null,
    /// 当前会话由 may_begin 打开（随后的 began 属于同一手势）
    scroll_session_from_may_begin: bool = false,

    registry: ?*const NodeRegistry = null,

    pub fn init(allocator: Allocator) EventDispatcher {
        return .{
            .allocator = allocator,
        };
    }

    pub fn setRegistry(self: *EventDispatcher, registry: *const NodeRegistry) void {
        self.registry = registry;
    }

    pub fn clearPersistentState(self: *EventDispatcher) void {
        self.hovered_handle = null;
        self.mouse_down_handle = null;
        self.pointer_capture_handle = null;
        self.suppress_click = false;
        self.scroll_session_owner = null;
        self.scroll_session_owner_ptr = null;
        self.scroll_momentum_owner = null;
        self.scroll_momentum_owner_ptr = null;
        self.scroll_session_from_may_begin = false;
    }

    /// 设置 Pointer Capture，后续鼠标事件直接发给该节点
    pub fn setPointerCapture(self: *EventDispatcher, node: *Node) void {
        const next = if (self.registry) |registry| registry.handleFor(node) else null;
        if (std.meta.eql(next, self.pointer_capture_handle)) return;
        const previous_epoch = self.pointer_capture_epoch;
        self.releasePointerCapture();
        if (self.pointer_capture_epoch != previous_epoch) return;
        self.pointer_capture_epoch = std.math.add(u64, self.pointer_capture_epoch, 1) catch @panic("capture epoch exhausted");
        self.pointer_capture_handle = if (self.resolveHandle(next) != null) next else null;
    }

    /// 释放 Pointer Capture
    pub fn releasePointerCapture(self: *EventDispatcher) void {
        const previous = self.pointer_capture_handle;
        self.pointer_capture_handle = null;
        if (self.resolveHandle(previous)) |node| {
            if (node.on_capture_lost) |callback| callback(node);
        }
    }

    /// 只释放"仍属于 handle 对应节点"的 capture：capture 是单槽，中途可能已被
    /// 其他系统接管，盲清会误伤后来者。返回是否真的释放了。
    pub fn releasePointerCaptureFor(self: *EventDispatcher, handle: NodeHandle) bool {
        const current = self.pointer_capture_handle orelse return false;
        if (current.id != handle.id or current.generation != handle.generation) return false;
        self.releasePointerCapture();
        return true;
    }

    /// 抑制当前 pointer sequence 的 click/double_click 合成（内部 API，供 drag
    /// 越阈值 / can_start 拒绝 / 强制取消时调用）。仅影响本次序列。
    pub fn cancelClickSynthesisForActivePointer(self: *EventDispatcher) void {
        self.suppress_click = true;
    }

    pub fn hasPointerCapture(self: *EventDispatcher) bool {
        return self.resolveHandle(self.pointer_capture_handle) != null;
    }

    /// 当前按下序列的 mouse_down 目标节点（无按下或节点已失效时 null）。
    ///
    /// 供"按下即拖拽"的宿主使用：on_event 回调不携带节点指针，宿主在
    /// mouse_down handler 里需要拿到被按下的节点才能 setPointerCapture,
    /// 不捕获的话，指针在别的节点上抬起时 mouse_up 不会回到拖拽发起方，
    /// 拖拽状态就地泄漏。dispatchMouseDownButton 在分发事件**之前**记录
    /// mouse_down_handle，因此 mouse_down handler 里调用总能拿到自己。
    pub fn mouseDownNode(self: *EventDispatcher) ?*Node {
        return self.resolveHandle(self.mouse_down_handle);
    }

    pub fn syncHover(self: *EventDispatcher, new_hovered: ?*Node) ?*Node {
        self.updateHoveredNode(new_hovered);
        return self.currentHovered();
    }

    pub fn deinit(self: *EventDispatcher) void {
        _ = self;
    }

    pub fn invalidateHandlesInSubtree(self: *EventDispatcher, subtree_root: *Node) void {
        if (self.hovered_handle) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) {
                self.hovered_handle = null;
            }
        }
        if (self.mouse_down_handle) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) {
                self.mouse_down_handle = null;
            }
        }
        if (self.pointer_capture_handle) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) {
                self.releasePointerCapture();
            }
        }
        if (self.scroll_session_owner) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) self.scroll_session_owner = null;
        }
        if (self.scroll_session_owner_ptr) |node| {
            if (isNodeInSubtree(subtree_root, node.id)) self.scroll_session_owner_ptr = null;
        }
        if (self.scroll_momentum_owner) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) self.scroll_momentum_owner = null;
        }
        if (self.scroll_momentum_owner_ptr) |node| {
            if (isNodeInSubtree(subtree_root, node.id)) self.scroll_momentum_owner_ptr = null;
        }
    }

    /// Dispatch captures the propagation path per invocation; nested events have
    /// independent paths. Registry-backed nodes are revalidated between callbacks.
    /// Without a registry, the caller must keep every path node and its handler
    /// contexts alive until dispatch returns (including nested dispatches).
    pub fn dispatch(self: *EventDispatcher, event: Event, target: *Node) EventResult {
        // 构建从 root 到 target 的路径
        var path_buf: [128]*Node = undefined;
        const path = buildPathInto(target, &path_buf);
        if (path.len == 0) return .ignored;
        var handled = false;

        // 提取事件指针坐标（用于 trace）
        const ptr_xy = eventPointerXY(event);
        const event_kind = eventToKindTag(event);
        const target_id = target.id;

        // 优先走 handle 解析，避免 handler 中途销毁节点导致 path 指针悬垂。
        if (self.registry) |registry| {
            var path_handle_buf: [128]NodeHandle = undefined;
            for (path, 0..) |node, i| {
                path_handle_buf[i] = registry.handleFor(node);
            }
            const path_handles = path_handle_buf[0..path.len];
            const target_handle = path_handles[path_handles.len - 1];

            // Phase 1: Capture (root -> target, 不含 target)
            if (path_handles.len > 1) {
                for (path_handles[0 .. path_handles.len - 1]) |node_handle| {
                    const node = registry.resolve(node_handle, null) orelse continue;
                    const result = invokeHandler(registry, node, event, .capture);
                    if (result != .ignored) {
                        debug_trace.maybeRecordEvent(event_kind, .capture, target_id, node_handle.id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                    }
                    if (result == .stop) return .stop;
                    if (result == .handled) handled = true;
                }
            }

            // Phase 2: Target
            if (registry.resolve(target_handle, null)) |resolved_target| {
                const target_result = invokeHandler(registry, resolved_target, event, .target);
                if (target_result != .ignored) {
                    debug_trace.maybeRecordEvent(event_kind, .target, target_id, target_id, eventResultToTag(target_result), ptr_xy[0], ptr_xy[1]);
                }
                if (target_result == .stop) return .stop;
                if (target_result == .handled) handled = true;
            } else {
                return if (handled) .handled else .ignored;
            }

            // Phase 3: Bubble (target 的父节点 -> root)
            if (path_handles.len > 1) {
                var i = path_handles.len - 1;
                while (i > 0) {
                    i -= 1;
                    const node_handle = path_handles[i];
                    const node = registry.resolve(node_handle, null) orelse continue;
                    const result = invokeHandler(registry, node, event, .bubble);
                    if (result != .ignored) {
                        debug_trace.maybeRecordEvent(event_kind, .bubble, target_id, node_handle.id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                    }
                    if (result == .stop) return .stop;
                    if (result == .handled) handled = true;
                }
            }

            return if (handled) .handled else .ignored;
        }

        // Phase 1: Capture (root -> target, 不含 target)
        if (path.len > 1) {
            for (path[0 .. path.len - 1]) |node| {
                const node_id = node.id;
                const result = invokeHandler(null, node, event, .capture);
                if (result != .ignored) {
                    debug_trace.maybeRecordEvent(event_kind, .capture, target_id, node_id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                }
                if (result == .stop) return .stop;
                if (result == .handled) handled = true;
            }
        }

        // Phase 2: Target
        const target_result = invokeHandler(null, target, event, .target);
        if (target_result != .ignored) {
            debug_trace.maybeRecordEvent(event_kind, .target, target_id, target_id, eventResultToTag(target_result), ptr_xy[0], ptr_xy[1]);
        }
        if (target_result == .stop) return .stop;
        if (target_result == .handled) handled = true;

        // Phase 3: Bubble (target 的父节点 -> root)
        if (path.len > 1) {
            var i = path.len - 1;
            while (i > 0) {
                i -= 1;
                const node = path[i];
                const node_id = node.id;
                const result = invokeHandler(null, node, event, .bubble);
                if (result != .ignored) {
                    debug_trace.maybeRecordEvent(event_kind, .bubble, target_id, node_id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                }
                if (result == .stop) return .stop;
                if (result == .handled) handled = true;
            }
        }

        return if (handled) .handled else .ignored;
    }

    /// 分发鼠标移动事件, 处理 hover 状态变化（modifiers 退化为 `.{}` 的兼容入口）
    pub fn dispatchMouseMove(self: *EventDispatcher, x: f32, y: f32, new_hovered: ?*Node) ?*Node {
        return self.dispatchMouseMoveEx(x, y, new_hovered, .{});
    }

    /// 分发鼠标移动事件，携带移动时刻的修饰键
    pub fn dispatchMouseMoveEx(self: *EventDispatcher, x: f32, y: f32, new_hovered: ?*Node, modifiers: events.Modifiers) ?*Node {
        const dx: f32 = if (self.has_last_mouse) x - self.last_mouse_pos[0] else 0;
        const dy: f32 = if (self.has_last_mouse) y - self.last_mouse_pos[1] else 0;
        self.last_mouse_pos = .{ x, y };
        self.has_last_mouse = true;

        // Pointer Capture: 直接发给捕获节点，跳过 hover 处理
        const capture_target = self.resolveHandle(self.pointer_capture_handle);
        if (capture_target) |capture| {
            const event = Event{ .mouse_move = .{ .x = x, .y = y, .dx = dx, .dy = dy, .modifiers = modifiers } };
            _ = self.dispatch(event, capture);
            return self.currentHovered();
        }

        self.updateHoveredNode(new_hovered);

        const target = self.resolveHandle(self.mouse_down_handle) orelse
            (if (self.registry != null) self.currentHovered() else new_hovered);
        if (target) |t| {
            const event = Event{ .mouse_move = .{ .x = x, .y = y, .dx = dx, .dy = dy, .modifiers = modifiers } };
            _ = self.dispatch(event, t);
        }
        return self.currentHovered();
    }

    /// 分发鼠标按下事件（支持按钮类型）
    pub fn dispatchMouseDownButton(self: *EventDispatcher, x: f32, y: f32, target: ?*Node, button: events.MouseButton, modifiers: events.Modifiers) ?*Node {
        const identity = if (target) |node| HandlerTarget.init(self.registry, node) else null;
        // 右键/中键不参与 click 合成与按压态跟踪，仅分发原始 down 事件。
        if (button != .left) {
            if (target) |t| {
                const event = Event{ .mouse_down = .{ .x = x, .y = y, .button = button, .modifiers = modifiers } };
                _ = self.dispatch(event, t);
            }
            return if (identity) |ref| ref.resolve() else null;
        }
        logSidebarHit("down", x, y, target);
        self.mouse_down_handle = if (target) |t|
            if (self.registry) |registry| registry.handleFor(t) else null
        else
            null;
        self.mouse_down_pos = .{ x, y };
        self.last_modifiers = modifiers;
        self.suppress_click = false;

        if (target) |t| {
            const event = Event{ .mouse_down = .{ .x = x, .y = y, .button = .left, .modifiers = modifiers } };
            _ = self.dispatch(event, t);
        }

        return if (identity) |ref| ref.resolve() else null;
    }

    /// 分发鼠标按下事件，默认左键的便利重载
    pub fn dispatchMouseDown(self: *EventDispatcher, x: f32, y: f32, target: ?*Node, modifiers: events.Modifiers) ?*Node {
        return self.dispatchMouseDownButton(x, y, target, .left, modifiers);
    }

    /// 分发鼠标释放事件（支持按钮类型），左键才会合成 click
    /// `modifiers` 是**抬手时刻**的修饰键，与 mouse_down 对称。
    /// 刻意不复用 `self.last_modifiers`（那是按下时刻的值）：两者可以不同
    /// （按下时没按 ⇧、抬手前按住，或反之），宿主在 mouse_up 判"加选还是
    /// 独占选中"时需要的是抬手时刻的真值。合成的 click 仍用 last_modifiers
    /// click 的语义锚点是按下。
    pub fn dispatchMouseUpButton(self: *EventDispatcher, x: f32, y: f32, target: ?*Node, button: events.MouseButton, modifiers: events.Modifiers) void {
        const target_handle = if (target) |t|
            if (self.registry) |registry| registry.handleFor(t) else null
        else
            null;

        // Pointer Capture: 发给捕获节点后自动释放。
        // click/double_click 仍要合成（浏览器 setPointerCapture 语义：capture
        // 元素收到合成 click），否则凡是 down 即 capture 的宿主（画布拖拽）
        // 永远收不到双击。
        const capture_target = self.resolveHandle(self.pointer_capture_handle);
        if (capture_target) |capture| {
            const capture_handle = self.pointer_capture_handle;
            const capture_epoch = self.pointer_capture_epoch;
            const event = Event{ .mouse_up = .{ .x = x, .y = y, .button = button, .modifiers = modifiers } };
            _ = self.dispatch(event, capture);
            if (button == .left) {
                if (self.pointer_capture_epoch == capture_epoch) {
                    if (capture_handle) |h| _ = self.releasePointerCaptureFor(h);
                }
                self.mouse_down_handle = null;
                if (!self.suppress_click) {
                    self.synthesizeClick(x, y, capture_handle, capture);
                }
                self.suppress_click = false;
            }
            return;
        }
        if (button != .left) {
            if (resolveDispatchTarget(self, target_handle, target)) |t| {
                const event = Event{ .mouse_up = .{ .x = x, .y = y, .button = button, .modifiers = modifiers } };
                _ = self.dispatch(event, t);
            }
            return;
        }
        logSidebarHit("up", x, y, target);

        // 分发 mouse_up
        if (resolveDispatchTarget(self, target_handle, target)) |t| {
            const event = Event{ .mouse_up = .{ .x = x, .y = y, .button = .left, .modifiers = modifiers } };
            _ = self.dispatch(event, t);
        }

        // 合成 click (down 和 up 在同一元素)
        const down_target = self.resolveHandle(self.mouse_down_handle);
        const click_match = if (self.registry != null)
            nodeHandleEqual(self.mouse_down_handle, target_handle)
        else if (down_target != null and down_target == target)
            true
        else
            false;
        if (click_match and !self.suppress_click) {
            self.synthesizeClick(x, y, target_handle, target);
        }

        self.suppress_click = false;
        self.mouse_down_handle = null;
    }

    /// click / double_click 合成（多击检测共享状态）。普通路径与 pointer
    /// capture 路径共用，handle 优先，raw 指针只在 registry 缺席时兜底。
    fn synthesizeClick(self: *EventDispatcher, x: f32, y: f32, target_handle: ?NodeHandle, target: ?*Node) void {
        {
            // mouse_up handler 已经跑过，可能释放了 target 子树（例如 folder toggle）。
            // 此时 raw 指针已悬垂，必须只信 handle。registry 缺席时只能赌 raw。
            const click_target: ?*Node = if (self.registry != null)
                self.resolveHandle(target_handle)
            else
                target;
            if (click_target) |t| {
                // 多击检测：使用共享阈值，避免双击/三击判定过紧。
                const dx = x - self.last_click_pos[0];
                const dy = y - self.last_click_pos[1];
                const dist_sq = dx * dx + dy * dy;
                var is_multi_click = false;
                const now_instant = std.time.Instant.now() catch null;
                if (now_instant) |now| {
                    if (self.last_click_instant) |last| {
                        const time_delta_ns = now.since(last);
                        is_multi_click = time_delta_ns < events.multi_click_interval_ns and dist_sq < events.multi_click_slop_sq;
                    }
                    self.last_click_instant = now;
                }
                if (is_multi_click) {
                    self.consecutive_clicks +|= 1;
                } else {
                    self.consecutive_clicks = 1;
                }
                self.last_click_pos = .{ x, y };

                const click_event = Event{ .click = .{ .x = x, .y = y, .click_count = self.consecutive_clicks, .modifiers = self.last_modifiers } };
                _ = self.dispatch(click_event, t);
                if (self.consecutive_clicks == 2) {
                    // click handler 可能释放了 target 所在子树（例如 folder toggle 重建 file tree）。
                    // 此时 raw 指针已悬垂，必须只信 handle：registry 存在且 resolve 失败则直接放弃 double_click。
                    const dc_target: ?*Node = if (self.registry != null)
                        self.resolveHandle(target_handle)
                    else
                        target;
                    if (dc_target) |double_click_target| {
                        const double_click_event = Event{ .double_click = .{
                            .x = x,
                            .y = y,
                            .click_count = self.consecutive_clicks,
                            .modifiers = self.last_modifiers,
                        } };
                        _ = self.dispatch(double_click_event, double_click_target);
                    }
                }
            }
        }
    }

    /// 分发鼠标释放事件，默认左键、无修饰键的便利重载
    pub fn dispatchMouseUp(self: *EventDispatcher, x: f32, y: f32, target: ?*Node) void {
        self.dispatchMouseUpButton(x, y, target, .left, .{});
    }

    /// 分发键盘事件到焦点节点
    pub fn dispatchKeyDown(self: *EventDispatcher, target: *Node, key_event: KeyEvent) EventResult {
        const event = Event{ .key_down = key_event };
        return self.dispatch(event, target);
    }

    pub fn dispatchKeyUp(self: *EventDispatcher, target: *Node, key_event: KeyEvent) EventResult {
        const event = Event{ .key_up = key_event };
        return self.dispatch(event, target);
    }

    /// 分发文本输入到焦点节点
    pub fn dispatchTextInput(self: *EventDispatcher, target: *Node, text: []const u8) EventResult {
        const event = Event{ .text_input = .{ .text = text } };
        return self.dispatch(event, target);
    }

    /// 分发 IME 预编辑到焦点节点
    pub fn dispatchImePreedit(self: *EventDispatcher, target: *Node, text: []const u8, cursor_utf8_offset: u32) EventResult {
        return self.dispatchImePreeditReplace(target, text, cursor_utf8_offset, events.ime_no_replacement, events.ime_no_replacement);
    }

    /// 分发带 replacementRange 的 IME 预编辑（再変換）；哨兵时与 dispatchImePreedit 等价
    pub fn dispatchImePreeditReplace(self: *EventDispatcher, target: *Node, text: []const u8, cursor_utf8_offset: u32, replace_start_utf8: u32, replace_end_utf8: u32) EventResult {
        const event = Event{ .ime_preedit = .{
            .text = text,
            .cursor_utf8_offset = cursor_utf8_offset,
            .replace_start_utf8 = replace_start_utf8,
            .replace_end_utf8 = replace_end_utf8,
        } };
        return self.dispatch(event, target);
    }

    /// 分发 IME 提交到焦点节点
    pub fn dispatchImeCommit(self: *EventDispatcher, target: *Node, text: []const u8) EventResult {
        return self.dispatchImeCommitReplace(target, text, events.ime_no_replacement, events.ime_no_replacement);
    }

    /// 分发带 replacementRange 的 IME 提交；哨兵时与 dispatchImeCommit 等价
    pub fn dispatchImeCommitReplace(self: *EventDispatcher, target: *Node, text: []const u8, replace_start_utf8: u32, replace_end_utf8: u32) EventResult {
        const event = Event{ .ime_commit = .{
            .text = text,
            .replace_start_utf8 = replace_start_utf8,
            .replace_end_utf8 = replace_end_utf8,
        } };
        return self.dispatch(event, target);
    }

    /// 每个滚动事件在命中测试**之前**调用：新手势开始意味着上一个手势已经结束，
    /// 它的 ended 若丢失，先补发 cancelled（否则旧 owner 及其祖先链会一直以为手指
    /// 还在板上）。放在命中测试之前，合成事件的处理器对节点树的任何改动都能被
    /// 随后的命中看到。may_begin 之后的 began 属于同一手势。
    pub fn beginScrollEvent(self: *EventDispatcher, scroll: events.ScrollEvent) void {
        if (scroll.isMomentum() or scroll.phase == .none) return;
        switch (scroll.phase) {
            .may_begin => self.cancelScrollGesture(),
            .began => if (!self.scroll_session_from_may_begin) self.cancelScrollGesture(),
            else => {},
        }
        self.scroll_session_from_may_begin = scroll.phase == .may_begin;
    }

    /// 分发滚轮事件（调用前先 beginScrollEvent，再做命中测试）。
    ///
    /// 触控板手势在 may_begin/began 时按命中锁定 owner，changed 期间不换手
    /// （内容在静止指针下移动，命中会变，不代表用户开始了新手势），ended/cancelled
    /// 后释放；ended 把 owner 交给随后的惯性事件。鼠标滚轮（.none）没有手势，
    /// 直接按命中派发，不读写会话状态。
    pub fn dispatchScroll(self: *EventDispatcher, scroll: events.ScrollEvent, hit_target: ?*Node) EventResult {
        const hit = nearestCompatibleScrollOwner(hit_target, scroll.dx, scroll.dy) orelse hit_target;
        if (scrollDebugEnabled() and !scroll.isMomentum() and !scroll.phaseEnded() and (scroll.dy != 0 or scroll.dx != 0)) {
            logScrollHitWithoutScrollArea(hit, scroll.x, scroll.y);
        }
        if (scroll.isMomentum()) return self.dispatchMomentumScroll(scroll, hit);
        if (scroll.phase == .none) {
            // 滚轮打断正在进行的惯性
            self.scroll_momentum_owner = null;
            self.scroll_momentum_owner_ptr = null;
            const target = hit orelse return .ignored;
            return self.dispatch(.{ .scroll = scroll }, target);
        }

        switch (scroll.phase) {
            .none => unreachable,
            .may_begin, .began => self.setScrollSessionOwner(hit),
            .changed => {
                const current = self.scrollSessionOwner(hit);
                if (current == null) {
                    self.setScrollSessionOwner(hit);
                } else if (hit != null and !scrollOwnerAcceptsGesture(current.?, scroll.dx, scroll.dy)) {
                    self.setScrollSessionOwner(hit);
                }
            },
            .ended, .cancelled => if (self.scrollSessionOwner(hit) == null) self.setScrollSessionOwner(hit),
        }

        // 任何新的手指/滚轮输入都打断上一轮惯性；ended 把 owner 交给本手势的惯性。
        switch (scroll.phase) {
            .ended => {
                self.scroll_momentum_owner = self.scroll_session_owner;
                self.scroll_momentum_owner_ptr = self.scroll_session_owner_ptr;
            },
            else => {
                self.scroll_momentum_owner = null;
                self.scroll_momentum_owner_ptr = null;
            },
        }

        const owner = self.scrollSessionOwner(hit);
        if (devtoolsHitDebugEnabled()) {
            std.debug.print("[devtools-hit] dispatch_scroll phase={s} session_owner={any}\n", .{ @tagName(scroll.phase), self.scroll_session_owner });
            logDevtoolsNodeSummary("resolved_scroll_owner", owner);
        }
        if (scroll.phaseEnded()) {
            self.scroll_session_owner = null;
            self.scroll_session_owner_ptr = null;
        }
        const target = owner orelse return .ignored;
        return self.dispatch(.{ .scroll = scroll }, target);
    }

    /// registry 模式只存 handle（指针会悬垂）；无 registry 的单测模式只存指针。
    fn setScrollSessionOwner(self: *EventDispatcher, node: ?*Node) void {
        if (self.registry) |registry| {
            self.scroll_session_owner = if (node) |n| registry.handleFor(n) else null;
            self.scroll_session_owner_ptr = null;
        } else {
            self.scroll_session_owner = null;
            self.scroll_session_owner_ptr = node;
        }
    }

    /// 当前会话 owner；已销毁（或指针模式下与命中不在同一棵树）时返回 null。
    fn scrollSessionOwner(self: *EventDispatcher, hit: ?*Node) ?*Node {
        if (self.registry != null) return self.resolveHandle(self.scroll_session_owner);
        const ptr = self.scroll_session_owner_ptr orelse return null;
        if (hit) |h| if (!nodesShareRoot(ptr, h)) return null;
        return ptr;
    }

    /// 惯性事件固定发给发起它的手势的 owner。owner 已被新手势清除（或节点已销毁）
    /// 说明这段惯性已被打断，直接丢弃，不回退到命中目标。
    fn dispatchMomentumScroll(self: *EventDispatcher, scroll: events.ScrollEvent, hit: ?*Node) EventResult {
        const owner = if (self.registry != null)
            self.resolveHandle(self.scroll_momentum_owner)
        else if (self.scroll_momentum_owner_ptr) |ptr|
            if (hit) |h| (if (nodesShareRoot(ptr, h)) ptr else null) else ptr
        else
            null;
        const target = owner orelse {
            self.scroll_momentum_owner = null;
            self.scroll_momentum_owner_ptr = null;
            return .ignored;
        };
        if (scroll.momentum == .ended) {
            self.scroll_momentum_owner = null;
            self.scroll_momentum_owner_ptr = null;
        }
        return self.dispatch(.{ .scroll = scroll }, target);
    }

    /// 系统中断（窗口失焦等）时结束进行中的滚动：给手势 owner 补发 cancelled，
    /// 给惯性 owner 补发惯性 ended，与真实设备的结束信号走同一条路径。
    pub fn cancelScrollGesture(self: *EventDispatcher) void {
        // 先把两个 owner 一次性取出并清空，再派发：处理器若重入滚动派发，
        // 看到的是干净状态，且它建立的新会话不会被这里随后覆盖。
        const session_owner = self.scrollSessionOwner(null);
        const momentum_owner = if (self.registry != null)
            self.resolveHandle(self.scroll_momentum_owner)
        else
            self.scroll_momentum_owner_ptr;
        self.scroll_session_owner = null;
        self.scroll_session_owner_ptr = null;
        self.scroll_momentum_owner = null;
        self.scroll_momentum_owner_ptr = null;
        self.scroll_session_from_may_begin = false;
        if (session_owner) |owner| {
            _ = self.dispatch(.{ .scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = 0, .phase = .cancelled } }, owner);
        }
        if (momentum_owner) |owner| {
            _ = self.dispatch(.{ .scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = 0, .momentum = .ended } }, owner);
        }
    }

    fn resolveHandle(self: *EventDispatcher, handle: ?NodeHandle) ?*Node {
        const registry = self.registry orelse return null;
        return registry.resolve(handle, null);
    }

    fn currentHovered(self: *EventDispatcher) ?*Node {
        return self.resolveHandle(self.hovered_handle);
    }

    fn updateHoveredNode(self: *EventDispatcher, new_hovered: ?*Node) void {
        const old_hovered = self.currentHovered();
        if (new_hovered == old_hovered) return;

        var old_path_buf: [128]*Node = undefined;
        var new_path_buf: [128]*Node = undefined;

        const old_path = if (old_hovered) |old|
            buildPathInto(old, old_path_buf[0..])
        else
            old_path_buf[0..0];

        const new_path = if (new_hovered) |new|
            buildPathInto(new, new_path_buf[0..])
        else
            new_path_buf[0..0];

        // 找公共前缀
        var common: usize = 0;
        while (common < old_path.len and common < new_path.len and old_path[common] == new_path[common]) {
            common += 1;
        }

        if (self.registry) |registry| {
            // Callbacks can detach/free either path or reenter hover dispatch.
            // Snapshot identities before calling any user code, and resolve
            // again even between on_event and the convenience hover handler.
            var old_handles: [128]NodeHandle = undefined;
            var new_handles: [128]NodeHandle = undefined;
            for (old_path, 0..) |node, index| old_handles[index] = registry.handleFor(node);
            for (new_path, 0..) |node, index| new_handles[index] = registry.handleFor(node);
            self.hover_epoch +%= 1;
            const epoch = self.hover_epoch;
            self.hovered_handle = if (new_path.len > 0) new_handles[new_path.len - 1] else null;
            var leaving_index = old_path.len;
            while (leaving_index > common) {
                leaving_index -= 1;
                const handle = old_handles[leaving_index];
                if (self.resolveHandle(handle)) |node| {
                    if (node.behavior.events.on_event) |handler| _ = handler(.mouse_leave, node.behavior.events.event_context);
                }
                if (self.hover_epoch != epoch) return;
                if (self.resolveHandle(handle)) |node| {
                    if (node.behavior.events.on_leave) |handler| handler.invoke();
                }
                if (self.hover_epoch != epoch) return;
            }
            for (new_handles[common..new_path.len]) |handle| {
                if (self.resolveHandle(handle)) |node| {
                    if (node.behavior.events.on_event) |handler| _ = handler(.mouse_enter, node.behavior.events.event_context);
                }
                if (self.hover_epoch != epoch) return;
                if (self.resolveHandle(handle)) |node| {
                    if (node.behavior.events.on_hover) |handler| handler.invoke();
                }
                if (self.hover_epoch != epoch) return;
            }
            if (self.currentHovered() == null) self.hovered_handle = null;
            return;
        }

        // 触发离开（从叶到根）
        var i = old_path.len;
        while (i > common) {
            i -= 1;
            const leaving = old_path[i];
            if (leaving.behavior.events.on_event) |handler| {
                _ = handler(.mouse_leave, leaving.behavior.events.event_context);
            }
            if (leaving.behavior.events.on_leave) |h| {
                h.invoke();
            }
        }

        // 触发进入（从根到叶）
        for (new_path[common..]) |node| {
            if (node.behavior.events.on_event) |handler| {
                _ = handler(.mouse_enter, node.behavior.events.event_context);
            }
            if (node.behavior.events.on_hover) |h| {
                h.invoke();
            }
        }

        self.hovered_handle = if (new_hovered) |node|
            if (self.registry) |registry| registry.handleFor(node) else null
        else
            null;
    }

    /// 构建从 root 到 target 的路径，写入外部 buffer
    fn buildPathInto(target: *Node, buf: []*Node) []*Node {
        return buildPathInternal(target, buf);
    }

    fn buildPathInternal(target: *Node, buf: []*Node) []*Node {
        var count: usize = 0;
        var node: ?*Node = target;

        // 先计算深度
        while (node != null) : (node = node.?.parent) {
            count += 1;
            if (count >= buf.len) {
                std.log.warn("[EventDispatcher] node tree depth ({d}) exceeds path buffer ({d}), event propagation truncated", .{ count, buf.len });
                break;
            }
        }

        if (count == 0) return buf[0..0];
        if (count > buf.len) count = buf.len;

        // 从 target 向上填充, 然后反转得到 root->target 顺序
        var i: usize = 0;
        node = target;
        while (node != null and i < count) : (node = node.?.parent) {
            buf[i] = node.?;
            i += 1;
        }

        std.mem.reverse(*Node, buf[0..i]);
        return buf[0..i];
    }
};

fn nodeHandleEqual(a: ?NodeHandle, b: ?NodeHandle) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.id == b.?.id and a.?.generation == b.?.generation;
}

fn resolveDispatchTarget(self: *EventDispatcher, handle: ?NodeHandle, raw: ?*Node) ?*Node {
    // 优先走 handle（防悬垂指针：node 可能已被 free）；
    // registry 里不存在时 fallback 到 raw 指针，避免 hit-test 产生的原始节点指针
    // 被丢弃导致 click/hover 无响应。
    // v1 的思路是严格模式（handle 失效就丢），但会导致任何未 register 的节点事件丢失，代价过高
    return self.resolveHandle(handle) orelse raw;
}

fn scrollOwnerDirection(node: *Node) ?core.ScrollDirectionHint {
    const name = node.meta.ownership.meta.component_name orelse return null;
    if (std.mem.eql(u8, name, "md.table.viewport")) return .horizontal;
    if (!(std.mem.eql(u8, name, "ScrollArea") or
        std.mem.eql(u8, name, "VirtualList") or
        std.mem.eql(u8, name, "Grid.ScrollArea") or
        std.mem.eql(u8, name, "md.table.viewport") or
        std.mem.eql(u8, name, "LineVirtualList"))) return null;
    return node.behavior.events.scroll_direction_hint;
}

/// 诊断：命中节点的祖先里没有 ScrollArea / VirtualList（滚动会被丢掉）。
fn logScrollHitWithoutScrollArea(hit: ?*Node, x: f32, y: f32) void {
    const ht = hit orelse {
        std.debug.print("[scroll-dbg] hitTest=null at ({d:.0},{d:.0})\n", .{ x, y });
        return;
    };
    var p: ?*Node = ht;
    while (p) |n| : (p = n.parent) {
        if (n.meta.ownership.meta.component_name) |name| {
            if (std.mem.eql(u8, name, "VirtualList") or std.mem.eql(u8, name, "ScrollArea")) return;
        }
    }
    std.debug.print("[scroll-dbg] hit id={d} test_id={s} tag={s} at ({d:.0},{d:.0}): no ScrollArea ancestor\n", .{
        ht.id,
        ht.meta.ownership.meta.test_id orelse "(none)",
        @tagName(ht.tag),
        x,
        y,
    });
}

fn scrollOwnerAcceptsGesture(node: *Node, dx: f32, dy: f32) bool {
    const dir = scrollOwnerDirection(node) orelse return true;
    const abs_dx = @abs(dx);
    const abs_dy = @abs(dy);
    const epsilon: f32 = 0.5;
    if (abs_dx <= epsilon and abs_dy <= epsilon) return true;
    if (abs_dy > abs_dx + epsilon) return dir != .horizontal;
    if (abs_dx > abs_dy + epsilon) return dir != .vertical;
    return true;
}

pub fn nearestCompatibleScrollOwner(node: ?*Node, dx: f32, dy: f32) ?*Node {
    var cur = node;
    while (cur) |n| {
        if ((interaction_semantics.nodeHitRoles(n).scroll or scrollOwnerDirection(n) != null) and scrollOwnerAcceptsGesture(n, dx, dy)) return n;
        cur = n.parent;
    }
    return null;
}

fn nodesShareRoot(a: *Node, b: *Node) bool {
    return rootOf(a) == rootOf(b);
}

fn rootOf(node: *Node) *Node {
    var cur = node;
    while (cur.parent) |parent| {
        cur = parent;
    }
    return cur;
}

fn isNodeInSubtree(root: *Node, node_id: u32) bool {
    if (root.id == node_id) return true;
    for (root.children.items) |child| {
        if (isNodeInSubtree(child, node_id)) return true;
    }
    return false;
}

// === Debug Trace 辅助 ===

fn eventToKindTag(event: Event) debug_trace.EventKindTag {
    return switch (event) {
        .mouse_down => .mouse_down,
        .mouse_up => .mouse_up,
        .click => .click,
        .double_click => .double_click,
        .mouse_move => .mouse_move,
        .mouse_enter => .mouse_enter,
        .mouse_leave => .mouse_leave,
        .scroll => .scroll,
        .magnify => .magnify,
        .drag => .drag,
        .key_down => .key_down,
        .key_up => .key_up,
        .text_input => .text_input,
        .ime_preedit => .ime_preedit,
        .ime_commit => .ime_commit,
        .focus => .focus,
        .blur => .blur,
    };
}

fn eventResultToTag(result: EventResult) debug_trace.EventResultTag {
    return switch (result) {
        .ignored => .ignored,
        .handled => .handled,
        .stop => .stop,
    };
}

fn eventPointerXY(event: Event) [2]f32 {
    return switch (event) {
        .mouse_down => |e| .{ e.x, e.y },
        .mouse_up => |e| .{ e.x, e.y },
        .click => |e| .{ e.x, e.y },
        .double_click => |e| .{ e.x, e.y },
        .mouse_move => |e| .{ e.x, e.y },
        .scroll => |e| .{ e.x, e.y },
        else => .{ 0, 0 },
    };
}

/// Identity survives callbacks; node pointers and callback contexts do not.
/// Raw borrowing is only supported under dispatch's registry-free lifetime contract.
const HandlerTarget = struct {
    registry: ?*const NodeRegistry,
    handle: ?NodeHandle,
    raw: *Node,

    fn init(registry: ?*const NodeRegistry, node: *Node) HandlerTarget {
        return .{ .registry = registry, .handle = if (registry) |r| r.handleFor(node) else null, .raw = node };
    }

    fn resolve(self: HandlerTarget) ?*Node {
        return if (self.registry) |r| r.resolve(self.handle, null) else self.raw;
    }
};

/// 在节点上调用事件处理器
fn invokeHandler(registry: ?*const NodeRegistry, initial_node: *Node, event: Event, phase: EventPhase) EventResult {
    const target = HandlerTarget.init(registry, initial_node);
    var node = initial_node;
    // capture 阶段真派发，root -> target 路径下行调用 on_event_capture。
    // 默认 null handler 节点零开销跳过；与 bubble 阶段独立，可单独 stop 链路。
    // 用于 focus trap、scroll lock、手势仲裁等"祖先抢先拦截"场景。
    if (phase == .capture) {
        if (node.behavior.events.on_event_capture) |handler| {
            return handler(event, node.behavior.events.event_context);
        }
        return .ignored;
    }

    if (event == .click) {
        return invokeClickHandler(target, event, phase);
    }

    // 调用通用事件处理器 (如果有)
    if (node.behavior.events.on_event) |handler| {
        const result = handler(event, node.behavior.events.event_context);
        if (result != .ignored) return result;
        node = target.resolve() orelse return .ignored;
    }

    // on_event 返回 ignored 或不存在时，对特定事件 fallthrough 到专用处理器
    switch (event) {
        .key_down => |ke| {
            if (node.behavior.events.on_key_down) |kh| {
                return kh(ke.key, ke.modifiers, node.behavior.events.key_context);
            }
        },
        .key_up => |ke| {
            if (node.behavior.events.on_key_up) |kh| {
                return kh(ke.key, ke.modifiers, node.behavior.events.key_context);
            }
        },
        .scroll => |se| {
            if (node.behavior.events.on_scroll) |sh| {
                return sh(se, node.behavior.events.event_context);
            }
        },
        .drag => |de| {
            // 拖放专用 HandlerRef 通道。updated 无专属 handler：它是高频
            // 位置流，drop target 只关心进入/离开/放下三态。
            switch (de.kind) {
                .entered => if (node.behavior.events.on_drag_enter) |h| {
                    h.invoke();
                    return .handled;
                },
                .exited => if (node.behavior.events.on_drag_leave) |h| {
                    h.invoke();
                    return .handled;
                },
                .dropped => if (node.behavior.events.on_drop) |h| {
                    h.invokeWithDrop(.{
                        .paths = de.paths,
                        .x = de.x,
                        .y = de.y,
                        .payload_kind = @intFromEnum(de.payload_kind),
                        .payload_truncated = de.payload_truncated,
                        .payload_is_untrusted = de.payload_is_untrusted,
                    });
                    return .handled;
                },
                .updated => {},
            }
        },
        else => {},
    }

    return .ignored;
}

fn invokeClickHandler(target: HandlerTarget, event: Event, phase: EventPhase) EventResult {
    var node = target.resolve() orelse return .ignored;
    var handled = false;

    if (phase == .target) {
        if (node.behavior.events.on_click) |h| {
            h.invoke();
            handled = true;
            node = target.resolve() orelse return .handled;
        }
    }

    if (node.behavior.events.on_event) |handler| {
        const result = handler(event, node.behavior.events.event_context);
        if (result != .ignored) return result;
        node = target.resolve() orelse return if (handled) .handled else .ignored;
    }

    if (phase == .bubble) {
        if (node.behavior.events.on_click) |h| {
            h.invoke();
            handled = true;
        }
    }

    return if (handled) .handled else .ignored;
}

/// 命中测试: 从后向前遍历子节点 (Z-order), 找最上层匹配节点
/// overflow_hidden 节点会裁剪子节点的命中区域
/// 考虑父节点的 translate_x/translate_y 偏移（如 ScrollArea 滚动）
fn hitTestNode(node: *Node, x: f32, y: f32) ?*Node {
    return hitTestNodeRuntime(node, x, y, .pointer);
}

/// 命中测试（不要求节点有事件处理器），单元测试 helper。
fn hitTestNodeAny(node: *Node, x: f32, y: f32) ?*Node {
    return hitTestNodeRuntime(node, x, y, .inspect);
}

/// 命中查询辅助：供 dispatcher 单元测试使用，统一走 runtime 索引逻辑。
fn hitTestNodeRuntime(node: *Node, x: f32, y: f32, kind: core.HitQueryKind) ?*Node {
    if (!interaction_semantics.nodeParticipatesInHitTest(node)) return null;
    var registry = NodeRegistry.init(std.heap.page_allocator);
    defer registry.deinit();
    var runtime = core.InteractionIndex.init(std.heap.page_allocator);
    defer runtime.deinit();

    registry.rebuild(node) catch return null;
    runtime.rebuild(node, &registry) catch return null;
    const hit = runtime.hitTestQuery(.{
        .kind = kind,
        .world_x = x,
        .world_y = y,
    }, &registry, null) orelse return null;
    return registry.resolve(hit.handle, null);
}

// ========== 测试 ==========

test "EventDispatcher: init/deinit" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.hovered_handle);
    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.mouse_down_handle);
}

test "EventDispatcher: dispatch to target" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var handled = false;

    const node = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &handled;

    ctx.root = node;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, node);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(handled);
}

test "EventDispatcher: direct click dispatch invokes target on_click" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var click_count: u32 = 0;

    const node = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});
    node.behavior.events.on_click = core.Cx.simpleHandler(struct {
        fn handler(context: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(context));
            ptr.* += 1;
        }
    }.handler, &click_count);

    ctx.root = node;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, node);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(u32, 1), click_count);
}

test "EventDispatcher: bubble propagation" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var parent_received = false;

    const parent = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    parent.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    parent.behavior.events.event_context = &parent_received;

    const child = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});

    try parent.appendChild(std.testing.allocator, child);
    ctx.root = parent;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, child);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(parent_received);
}

test "EventDispatcher: stop propagation" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var bubble_count: u32 = 0;

    const parent = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});

    const middle = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 150 },
    }, .{});
    middle.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            const ptr: *u32 = @ptrCast(@alignCast(context.?));
            ptr.* += 1;
            return .handled;
        }
    }.handler;
    middle.behavior.events.event_context = &bubble_count;

    const child = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});
    child.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            _ = context;
            return .stop;
        }
    }.handler;

    try middle.appendChild(std.testing.allocator, child);
    try parent.appendChild(std.testing.allocator, middle);
    ctx.root = parent;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, child);
    try std.testing.expectEqual(EventResult.stop, result);
    // click 不会在 capture 阶段触发；child 在 target 阶段 stop 后，middle 的 bubble 也不应触发。
    try std.testing.expectEqual(@as(u32, 0), bubble_count);
}

test "EventDispatcher: bubbling skips nodes torn down during target handler" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var target_calls: u32 = 0;
    var parent_calls: u32 = 0;

    const root = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});

    const parent = try core.box(ctx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 180 },
    }, .{});
    parent.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_up => {
                    const calls: *u32 = @ptrCast(@alignCast(context.?));
                    calls.* += 1;
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    parent.behavior.events.event_context = &parent_calls;

    const child = try core.box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    const TearDownCtx = struct {
        cx: *core.Cx,
        root: *core.Node,
        parent: *core.Node,
        calls: *u32,
    };
    var teardown_ctx = TearDownCtx{
        .cx = ctx,
        .root = root,
        .parent = parent,
        .calls = &target_calls,
    };
    child.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_up => {
                    const td: *TearDownCtx = @ptrCast(@alignCast(context.?));
                    td.calls.* += 1;
                    td.cx.detachChild(td.root, td.parent);
                    td.cx.freeNode(td.parent);
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    child.behavior.events.event_context = &teardown_ctx;

    try parent.appendChild(std.testing.allocator, child);
    try root.appendChild(std.testing.allocator, parent);
    ctx.root = root;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .mouse_up = .{ .x = 12, .y = 18 } }, child);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(u32, 1), target_calls);
    try std.testing.expectEqual(@as(u32, 0), parent_calls);
}

test "EventDispatcher: mouse hover" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const HoverCtx = struct {
        hover_count: u32 = 0,
        leave_count: u32 = 0,
    };
    var hover_ctx = HoverCtx{};

    const root = try core.box(ctx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});

    const btn = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 50 },
    }, .{});
    btn.behavior.events.on_hover = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const hc: *HoverCtx = @ptrCast(@alignCast(c));
            hc.hover_count += 1;
        }
    }.handler, &hover_ctx);
    btn.behavior.events.on_leave = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const hc: *HoverCtx = @ptrCast(@alignCast(c));
            hc.leave_count += 1;
        }
    }.handler, &hover_ctx);

    try root.appendChild(std.testing.allocator, btn);
    ctx.root = root;
    ctx.layout();

    // 移入按钮区域
    _ = dispatcher.dispatchMouseMove(10, 10, hitTestNode(root, 10, 10));
    try std.testing.expectEqual(@as(u32, 1), hover_ctx.hover_count);

    // 移出
    _ = dispatcher.dispatchMouseMove(300, 300, hitTestNode(root, 300, 300));
    try std.testing.expectEqual(@as(u32, 1), hover_ctx.leave_count);
}

test "EventDispatcher: scroll momentum keeps session owner despite hover target change" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const C = struct {
        left: u32 = 0,
        right: u32 = 0,
    };
    var counter = C{};

    const root = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = .row,
    }, .{});

    const left = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 120 },
    }, .{});
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .scroll => {
                    const c: *C = @ptrCast(@alignCast(context.?));
                    c.left += 1;
                    return .stop;
                },
                else => return .ignored,
            }
        }
    }.handler;
    left.behavior.events.event_context = &counter;

    const right = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 120 },
    }, .{});
    right.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .scroll => {
                    const c: *C = @ptrCast(@alignCast(context.?));
                    c.right += 1;
                    return .stop;
                },
                else => return .ignored,
            }
        }
    }.handler;
    right.behavior.events.event_context = &counter;

    try root.appendChild(std.testing.allocator, left);
    try root.appendChild(std.testing.allocator, right);
    ctx.root = root;
    ctx.layout();
    // 手指阶段命中 left，建立 scroll session owner
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = -8, .phase = .began }, hitTestNode(root, 20, 20));
    // 手指抬起，将 session owner 转移到 momentum owner
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = 0, .phase = .ended }, hitTestNode(root, 20, 20));
    // momentum 阶段指针移到 right，仍应派发给 left
    _ = dispatcher.dispatchScroll(.{ .x = 220, .y = 20, .dx = 0, .dy = -6, .momentum = .changed }, hitTestNode(root, 220, 20));

    try std.testing.expectEqual(@as(u32, 3), counter.left);
    try std.testing.expectEqual(@as(u32, 0), counter.right);
}

fn scrollSessionFixture(ctx: *core.Cx, counts: *[2]u32) !*Node {
    const root = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = .row,
    }, .{});
    for (counts) |*slot| {
        const pane = try core.box(ctx, .{
            .width = .{ .px = 150 },
            .height = .{ .px = 120 },
        }, .{});
        pane.behavior.events.on_event = struct {
            fn handler(event: Event, context: ?*anyopaque) EventResult {
                switch (event) {
                    .scroll => {
                        const c: *u32 = @ptrCast(@alignCast(context.?));
                        c.* += 1;
                        return .stop;
                    },
                    else => return .ignored,
                }
            }
        }.handler;
        pane.behavior.events.event_context = slot;
        try root.appendChild(std.testing.allocator, pane);
    }
    ctx.root = root;
    ctx.layout();
    return root;
}

fn scrollAt(dispatcher: *EventDispatcher, root: *Node, x: f32, phase: events.ScrollPhase, is_momentum: bool) void {
    const ev: events.ScrollEvent = .{ .x = x, .y = 20, .dx = 0, .dy = -8, .phase = phase, .momentum = if (is_momentum) .changed else .none };
    dispatcher.beginScrollEvent(ev);
    _ = dispatcher.dispatchScroll(ev, hitTestNode(root, x, 20));
}

test "EventDispatcher: began starts a new session even if the previous gesture never ended" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    // 旧手势落在 left，ended 丢失
    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 20, .changed, false);
    // 新手势在 right 开始：began 重新按命中锁定
    scrollAt(&dispatcher, root, 220, .began, false);
    scrollAt(&dispatcher, root, 220, .changed, false);

    // left：began + changed + 新手势开始时补发的 cancelled
    try std.testing.expectEqual(@as(u32, 3), counts[0]);
    try std.testing.expectEqual(@as(u32, 2), counts[1]);
}

test "EventDispatcher: changed keeps the gesture owner when the hit target moves" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 220, .changed, false);
    scrollAt(&dispatcher, root, 220, .ended, false);

    try std.testing.expectEqual(@as(u32, 3), counts[0]);
    try std.testing.expectEqual(@as(u32, 0), counts[1]);
}

test "EventDispatcher: cancelled releases the owner without handing it to momentum" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 20, .cancelled, false);
    scrollAt(&dispatcher, root, 20, .none, true); // 没有手势交出惯性：丢弃
    try std.testing.expectEqual(@as(u32, 2), counts[0]);

    // 取消后下一次滚动按命中派发，而不是旧 owner
    scrollAt(&dispatcher, root, 220, .changed, false);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
}

test "EventDispatcher: a new gesture cancels the previous one whose ended was lost" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const Phases = struct { cancelled: u32 = 0, began: u32 = 0 };
    var left_phases = Phases{};
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);
    const left = root.children.items[0];
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const p: *Phases = @ptrCast(@alignCast(context.?));
            switch (event) {
                .scroll => |sc| switch (sc.phase) {
                    .cancelled => p.cancelled += 1,
                    .began => p.began += 1,
                    else => {},
                },
                else => {},
            }
            return .stop;
        }
    }.handler;
    left.behavior.events.event_context = &left_phases;

    // may_begin -> began 是同一个手势：不取消
    scrollAt(&dispatcher, root, 20, .may_begin, false);
    scrollAt(&dispatcher, root, 20, .began, false);
    try std.testing.expectEqual(@as(u32, 0), left_phases.cancelled);
    scrollAt(&dispatcher, root, 20, .changed, false);
    // ended 丢失，新手势从 right 开始：left 收到补发的 cancelled
    scrollAt(&dispatcher, root, 220, .began, false);
    try std.testing.expectEqual(@as(u32, 1), left_phases.cancelled);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
}

test "EventDispatcher: cancelScrollGesture still ends momentum when the cancel handler re-enters" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    const Probe = struct {
        dispatcher: *EventDispatcher,
        root: *Node,
        momentum_ended_on_left: u32 = 0,
    };
    var probe = Probe{ .dispatcher = &dispatcher, .root = root };
    const left = root.children.items[0];
    const right = root.children.items[1];
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const p: *Probe = @ptrCast(@alignCast(context.?));
            if (event == .scroll and event.scroll.momentum == .ended) p.momentum_ended_on_left += 1;
            return .stop;
        }
    }.handler;
    left.behavior.events.event_context = &probe;
    right.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const p: *Probe = @ptrCast(@alignCast(context.?));
            // 收到补发的 cancelled 时重入一次滚动派发
            if (event == .scroll and event.scroll.phase == .cancelled) {
                _ = p.dispatcher.dispatchScroll(.{ .x = 220, .y = 20, .dx = 0, .dy = -3, .phase = .changed }, hitTestNode(p.root, 220, 20));
            }
            return .stop;
        }
    }.handler;
    right.behavior.events.event_context = &probe;

    // left 的手势正常结束，惯性归 left
    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 20, .ended, false);
    // right 上的新手势 ended 丢失
    scrollAt(&dispatcher, root, 220, .began, false);
    // began 已经结束了 left 的惯性；重新给 left 一段惯性所有权来构造两者并存
    dispatcher.scroll_momentum_owner = ctx.node_registry.handleFor(left);
    probe.momentum_ended_on_left = 0;

    dispatcher.cancelScrollGesture();
    try std.testing.expectEqual(@as(u32, 1), probe.momentum_ended_on_left);
}

test "EventDispatcher: mouse wheel follows the hit target on every event" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .none, false);
    scrollAt(&dispatcher, root, 220, .none, false);

    try std.testing.expectEqual(@as(u32, 1), counts[0]);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
}

test "EventDispatcher: mouse wheel leaves no session for a later trackpad stream" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .none, false);
    // 没有 began 的触控板流（旧 harness 的形状）：按自己的命中锁定，不粘到滚轮目标
    scrollAt(&dispatcher, root, 220, .changed, false);
    scrollAt(&dispatcher, root, 220, .ended, false);

    try std.testing.expectEqual(@as(u32, 1), counts[0]);
    try std.testing.expectEqual(@as(u32, 2), counts[1]);
}

test "EventDispatcher: momentum owner missing should not fall back to current hover target" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const C = struct {
        right: u32 = 0,
    };
    var counter = C{};

    const root1 = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = .row,
    }, .{});
    const left1 = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 120 },
    }, .{});
    left1.behavior.events.on_event = struct {
        fn handler(event: Event, _: ?*anyopaque) EventResult {
            return switch (event) {
                .scroll => .stop,
                else => .ignored,
            };
        }
    }.handler;
    try root1.appendChild(std.testing.allocator, left1);
    ctx.root = root1;
    ctx.layout();

    // 建立 momentum owner = left1
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = -8, .phase = .changed }, hitTestNode(root1, 20, 20));
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = -6, .momentum = .changed }, hitTestNode(root1, 20, 20));

    // 新树里没有 left1，只有 right2；momentum 不应回退命中 right2
    const root2 = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
    }, .{});
    const right2 = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
    }, .{});
    right2.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            return switch (event) {
                .scroll => blk: {
                    const c: *C = @ptrCast(@alignCast(context.?));
                    c.right += 1;
                    break :blk .stop;
                },
                else => .ignored,
            };
        }
    }.handler;
    right2.behavior.events.event_context = &counter;
    try root2.appendChild(std.testing.allocator, right2);

    const r = dispatcher.dispatchScroll(.{ .x = 200, .y = 20, .dx = 0, .dy = -5, .momentum = .changed }, hitTestNode(root2, 200, 20));
    try std.testing.expectEqual(EventResult.ignored, r);
    try std.testing.expectEqual(@as(u32, 0), counter.right);

    // 手动释放 root2 节点树（不在 ctx.root 中，不会被 ctx.deinit 自动释放）
    ctx.freeNode(root2);
}

test "hitTest: overflow_hidden container passthrough" {
    // 模拟 ScrollArea 结构: container(overflow_hidden) > content > button
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    // 根节点
    const root = try core.box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
    }, .{});
    ctx.root = root;

    // ScrollArea container: overflow_hidden + on_event
    const container = try core.box(ctx, .{
        .width = .{ .px = 600 },
        .height = .{ .px = 400 },
        .overflow_hidden = true,
    }, .{});
    container.behavior.events.on_event = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .ignored;
        }
    }.handler;
    try root.appendChild(std.testing.allocator, container);

    // content: fit height, grow width
    const content = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    }, .{});
    try container.appendChild(std.testing.allocator, content);

    // button inside content
    const btn = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 32 },
    }, .{});
    btn.tag = .button;
    try content.appendChild(std.testing.allocator, btn);

    // Layout
    ctx.layout();

    // 验证 layout 正确
    std.debug.print("\n[TEST] container rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ container.rectFromWorldOrFallback().x, container.rectFromWorldOrFallback().y, container.rectFromWorldOrFallback().w, container.rectFromWorldOrFallback().h });
    std.debug.print("[TEST] content rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ content.rectFromWorldOrFallback().x, content.rectFromWorldOrFallback().y, content.rectFromWorldOrFallback().w, content.rectFromWorldOrFallback().h });
    std.debug.print("[TEST] btn rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ btn.rectFromWorldOrFallback().x, btn.rectFromWorldOrFallback().y, btn.rectFromWorldOrFallback().w, btn.rectFromWorldOrFallback().h });

    // hitTest 在 button 区域应该命中 button，而不是 container
    const hit = hitTestNode(root, 50, 16);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(btn, hit.?);
}

test "hitTest: ScrollArea with padding and nested sections" {
    // 模拟 storybook 结构:
    // root(1400x900)
    //   main_area
    //     header(h=56)
    //     scroll_container(overflow_hidden, on_event, padding=32)
    //       content(fit height, grow width, direction=column)
    //         section(card)
    //           row(direction=row)
    //             radio_container(tag=button, on_event)
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 1400 }, .height = .{ .px = 900 } }, .{});
    ctx.root = root;

    // main area
    const main_area = try core.box(ctx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 900 },
        .direction = .column,
    }, .{});
    try root.appendChild(std.testing.allocator, main_area);

    // header
    const header = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 56 },
    }, .{});
    try main_area.appendChild(std.testing.allocator, header);

    // scroll container (like ScrollArea)
    const scroll = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 844 },
        .overflow_hidden = true,
        .padding = core.Padding.all(32),
        .direction = .column,
    }, .{});
    scroll.behavior.events.on_event = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .ignored;
        }
    }.handler;
    try main_area.appendChild(std.testing.allocator, scroll);

    // content
    const content = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    }, .{});
    try scroll.appendChild(std.testing.allocator, content);

    // section
    const section = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 8,
    }, .{});
    try content.appendChild(std.testing.allocator, section);

    // row
    const row = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 16,
    }, .{});
    try section.appendChild(std.testing.allocator, row);

    // radio container (tag=button, on_event)
    const radio = try core.box(ctx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 8,
    }, .{});
    radio.tag = .button;
    radio.behavior.events.on_event = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .handled;
        }
    }.handler;
    try row.appendChild(std.testing.allocator, radio);

    // radio circle
    const circle = try core.box(ctx, .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
    }, .{});
    try radio.appendChild(std.testing.allocator, circle);

    ctx.layout();

    std.debug.print("\n[TEST2] main_area rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ main_area.rectFromWorldOrFallback().x, main_area.rectFromWorldOrFallback().y, main_area.rectFromWorldOrFallback().w, main_area.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] header rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ header.rectFromWorldOrFallback().x, header.rectFromWorldOrFallback().y, header.rectFromWorldOrFallback().w, header.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] scroll rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ scroll.rectFromWorldOrFallback().x, scroll.rectFromWorldOrFallback().y, scroll.rectFromWorldOrFallback().w, scroll.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] content rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ content.rectFromWorldOrFallback().x, content.rectFromWorldOrFallback().y, content.rectFromWorldOrFallback().w, content.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] section rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ section.rectFromWorldOrFallback().x, section.rectFromWorldOrFallback().y, section.rectFromWorldOrFallback().w, section.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] row rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ row.rectFromWorldOrFallback().x, row.rectFromWorldOrFallback().y, row.rectFromWorldOrFallback().w, row.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] radio rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ radio.rectFromWorldOrFallback().x, radio.rectFromWorldOrFallback().y, radio.rectFromWorldOrFallback().w, radio.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] circle rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ circle.rectFromWorldOrFallback().x, circle.rectFromWorldOrFallback().y, circle.rectFromWorldOrFallback().w, circle.rectFromWorldOrFallback().h });

    // hitTest 在 radio 区域，应命中 radio (tag=button)
    const radio_global = radio.globalRect();
    const radio_center_x = radio_global.x + radio_global.w / 2;
    const radio_center_y = radio_global.y + radio_global.h / 2;
    std.debug.print("[TEST2] hitTest at ({d:.0},{d:.0})\n", .{ radio_center_x, radio_center_y });

    const hit = hitTestNode(root, radio_center_x, radio_center_y);
    try std.testing.expect(hit != null);
    std.debug.print("[TEST2] hit: id={d} tag={s}\n", .{ hit.?.id, @tagName(hit.?.tag) });
    try std.testing.expectEqual(radio, hit.?);
}

test "hitTest: opacity zero nodes do not participate" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    ctx.root = root;

    const visible = try core.box(ctx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 40 },
    }, .{});
    visible.tag = .button;
    try root.appendChild(std.testing.allocator, visible);

    const hidden = try core.box(ctx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 40 },
    }, .{});
    hidden.tag = .button;
    hidden.setOpacityRaw(0);
    try root.appendChild(std.testing.allocator, hidden);

    ctx.layout();

    const hit = hitTestNode(root, 20, 20);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(visible, hit.?);
}

test "hitTestAny: positive z does not escape overflow_hidden ancestor clip" {
    // 方案 §9.2 第 13 条（反转旧的 "overlay escapes overflow_hidden ancestor clip"）：
    // z_index 只影响同级顺序，z>0 节点照样受祖先 overflow_hidden 裁剪（命中与像素一致）。
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    ctx.root = root;

    const clipper = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(std.testing.allocator, clipper);

    const overlay = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
    }, .{});
    overlay.style.ensureExtPanic(std.testing.allocator).z_index = 10;
    try clipper.appendChild(std.testing.allocator, overlay);

    ctx.layout();
    {
        // 横跨 clipper 右下边界：(20..60) 与 clipper (0..40) 只有左上 20×20 重叠。
        const r = overlay.rectFromWorldOrFallback();
        overlay.setLayoutRect(.{ .x = 20, .y = 20, .w = r.w, .h = r.h });
    }

    // clipper 之外、overlay 之内 -> 不命中 overlay（旧实现命中它）。
    const outside = hitTestNodeAny(root, 50, 50);
    try std.testing.expect(outside != overlay);
    try std.testing.expect(outside == null or outside.? == root);
    // clipper 之内的重叠区 -> 命中 overlay。
    const inside = hitTestNodeAny(root, 30, 30);
    try std.testing.expect(inside != null);
    try std.testing.expectEqual(overlay, inside.?);
}

test "hitTest: runtime helper matches interaction index for hidden and overlay cases" {
    const allocator = std.testing.allocator;
    var registry = core.NodeRegistry.init(allocator);
    defer registry.deinit();
    var index = core.InteractionIndex.init(allocator);
    defer index.deinit();

    var ctx = try core.Cx.init(allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 220 },
    }, .{});
    ctx.root = root;

    const regular = try core.box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    regular.tag = .button;
    try root.appendChild(allocator, regular);

    const hidden = try core.box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    hidden.tag = .button;
    hidden.setOpacityRaw(0);
    try root.appendChild(allocator, hidden);

    const clipper = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(allocator, clipper);

    const overlay = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
    }, .{});
    overlay.tag = .button;
    overlay.style.ensureExtPanic(allocator).z_index = 10;
    try clipper.appendChild(allocator, overlay);

    ctx.layout();
    {
        const rr = regular.rectFromWorldOrFallback();
        regular.setLayoutRect(.{ .x = 0, .y = 0, .w = rr.w, .h = rr.h });
        const hr = hidden.rectFromWorldOrFallback();
        hidden.setLayoutRect(.{ .x = 0, .y = 0, .w = hr.w, .h = hr.h });
        const cr = clipper.rectFromWorldOrFallback();
        clipper.setLayoutRect(.{ .x = 0, .y = 0, .w = cr.w, .h = cr.h });
        // overlay 横跨 clipper 右下边界：(20..60) 与 clipper (0..40) 只重叠 20×20。
        const or_ = overlay.rectFromWorldOrFallback();
        overlay.setLayoutRect(.{ .x = 20, .y = 20, .w = or_.w, .h = or_.h });
    }

    try registry.rebuild(root);
    try index.rebuild(root, &registry);

    // clipper 内：z=10 的 overlay 压过 regular；两条命中路径一致。
    const tree_overlay = hitTestNode(root, 30, 30);
    const index_overlay = index.hitTestQuery(.{ .kind = .pointer, .world_x = 30, .world_y = 30 }, &registry, null);
    try std.testing.expect(tree_overlay != null);
    try std.testing.expect(index_overlay != null);
    try std.testing.expectEqual(overlay.id, tree_overlay.?.id);
    try std.testing.expectEqual(tree_overlay.?.id, index_overlay.?.handle.id);

    // clipper 外、overlay 矩形内：overlay 被裁掉，命中落到下面的 regular；两条路径一致。
    const tree_clipped = hitTestNode(root, 50, 50);
    const index_clipped = index.hitTestQuery(.{ .kind = .pointer, .world_x = 50, .world_y = 50 }, &registry, null);
    try std.testing.expect(tree_clipped != null);
    try std.testing.expect(index_clipped != null);
    try std.testing.expectEqual(regular.id, tree_clipped.?.id);
    try std.testing.expectEqual(tree_clipped.?.id, index_clipped.?.handle.id);

    const tree_regular = hitTestNode(root, 10, 10);
    const index_regular = index.hitTestQuery(.{ .kind = .pointer, .world_x = 10, .world_y = 10 }, &registry, null);
    try std.testing.expect(tree_regular != null);
    try std.testing.expect(index_regular != null);
    try std.testing.expectEqual(tree_regular.?.id, index_regular.?.handle.id);
}

test "on_key_down: basic key event" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var key_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node.behavior.events.on_key_down = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.key_context = &key_received;
    try root.appendChild(std.testing.allocator, node);

    ctx.layout();

    const result = dispatcher.dispatchKeyDown(node, .{ .key = .a, .modifiers = .{} });
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(key_received);
}

test "on_key_down: bubbles to parent" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var parent_key_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const parent_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    parent_node.behavior.events.on_key_down = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    parent_node.behavior.events.key_context = &parent_key_received;
    try root.appendChild(std.testing.allocator, parent_node);

    const child = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try parent_node.appendChild(std.testing.allocator, child);

    ctx.layout();

    // Dispatch to child, child has no handler, should bubble to parent's on_key_down
    const result = dispatcher.dispatchKeyDown(child, .{ .key = .a, .modifiers = .{} });
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(parent_key_received);
}

test "on_event takes priority over on_key_down" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var on_event_called = false;
    var on_key_down_called = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &on_event_called;
    node.behavior.events.on_key_down = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.key_context = &on_key_down_called;
    try root.appendChild(std.testing.allocator, node);

    ctx.layout();

    _ = dispatcher.dispatchKeyDown(node, .{ .key = .a, .modifiers = .{} });
    // on_event handled the event, on_key_down should NOT be called
    try std.testing.expect(on_event_called);
    try std.testing.expect(!on_key_down_called);
}

test "PointerCapture: mouse_move goes to capture node" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var capture_received = false;
    var normal_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    // Normal node at (0,0,200,150)
    const normal_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    normal_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    normal_node.behavior.events.event_context = &normal_received;
    try root.appendChild(std.testing.allocator, normal_node);

    // Capture node at (200,0,200,150)
    const capture_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    capture_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    capture_node.behavior.events.event_context = &capture_received;
    try root.appendChild(std.testing.allocator, capture_node);

    ctx.setViewport(400, 300);
    ctx.layout();

    // Set pointer capture to capture_node
    dispatcher.setPointerCapture(capture_node);

    // Move mouse over normal_node area, should go to capture_node instead
    _ = dispatcher.dispatchMouseMove(50, 50, hitTestNode(root, 50, 50));
    try std.testing.expect(capture_received);
    try std.testing.expect(!normal_received);
}

test "PointerCapture: auto release on mouse_up" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var up_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const capture_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    capture_node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_up => {
                    const ptr: *bool = @ptrCast(@alignCast(context.?));
                    ptr.* = true;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    capture_node.behavior.events.event_context = &up_received;
    try root.appendChild(std.testing.allocator, capture_node);

    ctx.setViewport(400, 300);
    ctx.layout();

    dispatcher.setPointerCapture(capture_node);
    try std.testing.expect(dispatcher.pointer_capture_handle != null);

    // Mouse up, should go to capture_node and auto-release
    dispatcher.dispatchMouseUp(300, 200, hitTestNode(root, 300, 200));
    try std.testing.expect(up_received);
    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.pointer_capture_handle);
}

test "PointerCapture: double click is synthesized on the capture node" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var dbl_count: u32 = 0;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const host = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    host.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .double_click => {
                    const ptr: *u32 = @ptrCast(@alignCast(context.?));
                    ptr.* += 1;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    host.behavior.events.event_context = &dbl_count;
    try root.appendChild(std.testing.allocator, host);
    ctx.setViewport(400, 300);
    ctx.layout();

    // 画布宿主模式：每次 down 即 capture（拖拽需要），up 自动释放。
    // 双击 = 两轮 down/up，第二轮 up 必须在 capture 路径里合成 double_click。
    var round: u32 = 0;
    while (round < 2) : (round += 1) {
        const t = hitTestNode(root, 100, 100);
        _ = dispatcher.dispatchMouseDown(100, 100, t, .{});
        dispatcher.setPointerCapture(host);
        dispatcher.dispatchMouseUp(100, 100, t);
    }
    try std.testing.expectEqual(@as(u32, 1), dbl_count);
}

test "PointerCapture: uses handle-based state" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var capture_received = false;
    var normal_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const normal_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    normal_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    normal_node.behavior.events.event_context = &normal_received;
    try root.appendChild(std.testing.allocator, normal_node);

    const capture_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    capture_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    capture_node.behavior.events.event_context = &capture_received;
    try root.appendChild(std.testing.allocator, capture_node);

    ctx.setViewport(400, 300);
    ctx.layout();

    dispatcher.setPointerCapture(capture_node);
    try std.testing.expect(dispatcher.pointer_capture_handle != null);

    _ = dispatcher.dispatchMouseMove(50, 50, hitTestNode(root, 50, 50));
    try std.testing.expect(capture_received);
    try std.testing.expect(!normal_received);
}

test "EventDispatcher: mouse down stores handle" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;
    ctx.layout();

    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    try std.testing.expect(dispatcher.mouse_down_handle != null);
}

test "EventDispatcher: mouse move stores hover handle" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;
    ctx.layout();

    _ = dispatcher.dispatchMouseMove(20, 20, node);
    try std.testing.expect(dispatcher.hovered_handle != null);
}

test "EventDispatcher: double click skips freed target after click handler teardown" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    const TestCtx = struct {
        cx: *core.Cx,
        parent: *core.Node,
        node: *core.Node,
        click_count: u32 = 0,
        double_click_count: u32 = 0,
    };
    var test_ctx = TestCtx{
        .cx = ctx,
        .parent = root,
        .node = node,
    };
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const tc: *TestCtx = @ptrCast(@alignCast(context.?));
            switch (event) {
                .click => {
                    tc.click_count += 1;
                    tc.cx.detachChild(tc.parent, tc.node);
                    tc.cx.freeNode(tc.node);
                },
                .double_click => {
                    tc.double_click_count += 1;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &test_ctx;
    try root.appendChild(std.testing.allocator, node);

    ctx.setViewport(200, 100);
    ctx.layout();

    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    dispatcher.last_click_pos = .{ 20, 20 };
    dispatcher.last_click_instant = std.time.Instant.now() catch null;
    dispatcher.consecutive_clicks = 1;

    dispatcher.dispatchMouseUp(20, 20, node);

    try std.testing.expectEqual(@as(u32, 1), test_ctx.click_count);
    try std.testing.expectEqual(@as(u32, 0), test_ctx.double_click_count);
}

test "EventDispatcher: registry mode with invalid handle falls back to raw target" {
    // 当 handle 失效（generation mismatch / registry 没注册）时 fallback 到 raw 指针。
    // 这避免了任何未 register 的节点都丢 event 的问题。
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.setViewport(200, 100);
    ctx.layout();

    const invalid_handle = NodeHandle{ .id = node.id, .generation = 999999 };
    try std.testing.expect(dispatcher.resolveHandle(invalid_handle) == null);
    // fallback 到 raw -> 返回 node 指针
    try std.testing.expect(resolveDispatchTarget(&dispatcher, invalid_handle, node) == node);
}

test "PointerCapture: normal when no capture" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var normal_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_move => {
                    const ptr: *bool = @ptrCast(@alignCast(context.?));
                    ptr.* = true;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &normal_received;
    try root.appendChild(std.testing.allocator, node);

    ctx.setViewport(400, 300);
    ctx.layout();

    // No capture, normal dispatch
    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.pointer_capture_handle);
    _ = dispatcher.dispatchMouseMove(50, 50, hitTestNode(root, 50, 50));
    try std.testing.expect(normal_received);
}

test "EventDispatcher: dispatchKeyUp invokes on_key_up" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var key_up_count: u32 = 0;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    node.behavior.events.on_key_up = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
            return .handled;
        }
    }.handler;
    node.behavior.events.key_context = &key_up_count;
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;

    ctx.layout();

    const result = dispatcher.dispatchKeyUp(node, .{ .key = .a, .modifiers = .{} });
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(u32, 1), key_up_count);
}

const MouseUpProbe = struct {
    up_modifiers: core.Modifiers = .{},
    click_modifiers: core.Modifiers = .{},
    up_count: u32 = 0,

    fn onEvent(event: core.Event, context: ?*anyopaque) EventResult {
        const self: *MouseUpProbe = @ptrCast(@alignCast(context.?));
        switch (event) {
            .mouse_up => |e| {
                self.up_modifiers = e.modifiers;
                self.up_count += 1;
            },
            .click => |e| self.click_modifiers = e.modifiers,
            else => {},
        }
        return .handled;
    }
};

fn mouseUpProbeCx(ctx: *core.Cx, probe: *MouseUpProbe) !void {
    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    root.behavior.events.on_event = MouseUpProbe.onEvent;
    root.behavior.events.event_context = probe;
    ctx.root = root;
    ctx.layout();
}

test "Cx: mouse_up carries release-time modifiers" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    var probe = MouseUpProbe{};
    try mouseUpProbeCx(ctx, &probe);

    // 验收 1：按住 ⇧ 按下 -> 抬手时仍按住 ⇒ mouse_up.shift == true
    ctx.handleMouseDownEx(50, 50, .left, .{ .shift = true });
    ctx.handleMouseUpEx(50, 50, .left, .{ .shift = true });
    try std.testing.expectEqual(@as(u32, 1), probe.up_count);
    try std.testing.expect(probe.up_modifiers.shift);
}

test "Cx: mouse_up reflects modifier released before lift, not press-time latch" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    var probe = MouseUpProbe{};
    try mouseUpProbeCx(ctx, &probe);

    // 验收 2：按住 ⇧ 按下 -> **抬手前松开 ⇧** ⇒ mouse_up.shift == false。
    // 这条专门区分"复用 last_modifiers"的偷懒改法，那样会错误地是 true。
    ctx.handleMouseDownEx(50, 50, .left, .{ .shift = true });
    ctx.handleMouseUpEx(50, 50, .left, .{});
    try std.testing.expect(!probe.up_modifiers.shift);

    // 合成的 click 锚点仍是按下时刻，保持既有语义不回归。
    try std.testing.expect(probe.click_modifiers.shift);
}

test "Cx: mouse_up without modifiers stays all-false" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    var probe = MouseUpProbe{};
    try mouseUpProbeCx(ctx, &probe);

    // 验收 3：不按修饰键 ⇒ 全 false（不回归）
    ctx.handleMouseDownEx(50, 50, .left, .{});
    ctx.handleMouseUpEx(50, 50, .left, .{});
    try std.testing.expect(!probe.up_modifiers.shift);
    try std.testing.expect(!probe.up_modifiers.super);
    try std.testing.expect(!probe.up_modifiers.ctrl);
    try std.testing.expect(!probe.up_modifiers.alt);

    // 验收 4：旧的 handleMouseUp(x, y) 仍可编译调用，行为等价于无修饰键。
    ctx.handleMouseDownEx(50, 50, .left, .{ .shift = true });
    ctx.handleMouseUp(50, 50);
    try std.testing.expect(!probe.up_modifiers.shift);
}

test "EventDispatcher: second click emits double_click" {
    var dispatcher = EventDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const DoubleClickState = struct {
        double_clicks: *u32,
        last_click_count: *u8,
    };

    var double_clicks: u32 = 0;
    var last_click_count: u8 = 0;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const state: *DoubleClickState = @ptrCast(@alignCast(context.?));
            switch (event) {
                .click => |e| state.last_click_count.* = e.click_count,
                .double_click => {
                    state.double_clicks.* += 1;
                },
                else => {},
            }
            return .ignored;
        }
    }.handler;
    var state = DoubleClickState{
        .double_clicks = &double_clicks,
        .last_click_count = &last_click_count,
    };
    node.behavior.events.event_context = &state;
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;

    ctx.layout();

    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    dispatcher.dispatchMouseUp(20, 20, node);
    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    dispatcher.dispatchMouseUp(20, 20, node);

    try std.testing.expectEqual(@as(u8, 2), last_click_count);
    try std.testing.expectEqual(@as(u32, 1), double_clicks);
}

test "EventDispatcher: nested dispatch preserves outer bubble path with and without registry" {
    for ([_]bool{ true, false }) |with_registry| {
        var cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const a_parent = try core.box(cx, .{}, .{});
        const b_parent = try core.box(cx, .{}, .{});
        const a = try core.box(cx, .{}, .{});
        const b = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, a_parent);
        try root.appendChild(cx.allocator, b_parent);
        try a_parent.appendChild(cx.allocator, a);
        try b_parent.appendChild(cx.allocator, b);
        const State = struct {
            cx: *core.Cx,
            other: *core.Node,
            a_count: usize = 0,
            b_count: usize = 0,
            fn capture(e: core.Event, raw: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (e == .mouse_down) {
                    _ = self.cx.dispatcher.dispatch(.{ .text_input = .{ .text = "nested" } }, self.other);
                }
                return .ignored;
            }
            fn parentA(e: core.Event, raw: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (e == .mouse_down) self.a_count += 1;
                return .ignored;
            }
            fn parentB(e: core.Event, raw: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (e == .mouse_down) self.b_count += 1;
                return .ignored;
            }
        };
        var state = State{ .cx = cx, .other = b };
        root.behavior.events.on_event_capture = State.capture;
        root.behavior.events.event_context = &state;
        a_parent.behavior.events.on_event = State.parentA;
        a_parent.behavior.events.event_context = &state;
        b_parent.behavior.events.on_event = State.parentB;
        b_parent.behavior.events.event_context = &state;
        cx.layout();
        _ = cx.render();
        if (!with_registry) cx.dispatcher.registry = null;
        _ = cx.dispatcher.dispatch(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left, .modifiers = .{} } }, a);
        try std.testing.expectEqual(@as(usize, 0), state.b_count);
        try std.testing.expectEqual(@as(usize, 1), state.a_count);
    }
}

test "EventDispatcher: destroyed click target receives no followup handler" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const node = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, node);
    const State = struct {
        cx: *core.Cx,
        node: *core.Node,
        followups: usize = 0,
        fn click(self: *@This()) void {
            self.cx.detachChild(self.node.parent.?, self.node);
            self.cx.freeNode(self.node);
        }
        fn event(e: core.Event, raw: ?*anyopaque) core.EventResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (e == .click) self.followups += 1;
            return .ignored;
        }
    };
    var state = State{ .cx = cx, .node = node };
    node.behavior.events.on_click = core.Cx.handlerFrom(State, &state, State.click);
    node.behavior.events.on_event = State.event;
    node.behavior.events.event_context = &state;
    cx.layout();
    _ = cx.render();
    _ = cx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0, .modifiers = .{} } }, node);
    try std.testing.expectEqual(@as(usize, 0), state.followups);
}

test "EventDispatcher: generic callback destruction suppresses specialized followups" {
    for ([_]Event{
        .{ .key_down = .{ .key = .a, .modifiers = .{} } },
        .{ .click = .{ .x = 0, .y = 0 } },
    }) |input_event| {
        const cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const victim = try core.box(cx, .{}, .{});
        const leaf = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, victim);
        try victim.appendChild(cx.allocator, leaf);
        const State = struct {
            cx: *core.Cx,
            victim: *Node,
            followups: usize = 0,
            fn event(_: Event, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.cx.detachChild(self.victim.parent.?, self.victim);
                self.cx.freeNode(self.victim);
                return .ignored;
            }
            fn key(_: events.KeyCode, _: Modifiers, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.followups += 1;
                return .handled;
            }
            fn click(self: *@This()) void {
                self.followups += 1;
            }
        };
        var state = State{ .cx = cx, .victim = victim };
        victim.behavior.events.on_event = State.event;
        victim.behavior.events.event_context = &state;
        victim.behavior.events.on_key_down = State.key;
        victim.behavior.events.key_context = &state;
        victim.behavior.events.on_click = core.Cx.handlerFrom(State, &state, State.click);
        cx.layout();
        // Click reaches victim during bubble (generic handler before on_click).
        _ = cx.dispatcher.dispatch(input_event, if (input_event == .click) leaf else victim);
        try std.testing.expectEqual(@as(usize, 0), state.followups);
    }
}

test "EventDispatcher: mouse down returns only a surviving target" {
    for ([_]events.MouseButton{ .left, .right, .middle }) |button| {
        const cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const node = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, node);
        const State = struct {
            cx: *core.Cx,
            node: *Node,
            fn event(_: Event, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.cx.detachChild(self.node.parent.?, self.node);
                self.cx.freeNode(self.node);
                return .handled;
            }
        };
        var state = State{ .cx = cx, .node = node };
        node.behavior.events.on_event = State.event;
        node.behavior.events.event_context = &state;
        cx.layout();
        try std.testing.expect(cx.dispatcher.dispatchMouseDownButton(0, 0, node, button, .{}) == null);
    }
}

test "dispatch: nested dispatch from handler must not clobber outer bubble path" {
    // root->A->B, root->C->D。B 的 mouse_up handler 调 cx.setFocus(D)，触发嵌套的
    // blur/focus dispatch（路径 root->C->D）。外层冒泡必须仍走 B->A->root，
    // 不能因共享路径缓冲被覆写而冒泡到 C。
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const Counter = struct { n: u32 = 0 };
    var a_calls = Counter{};
    var c_calls = Counter{};
    const countUp = struct {
        fn h(e: Event, cx_: ?*anyopaque) EventResult {
            if (e == .mouse_up) @as(*Counter, @ptrCast(@alignCast(cx_.?))).n += 1;
            return .ignored;
        }
    }.h;
    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    const a = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const b = try core.box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    const c = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const d = try core.box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    a.behavior.events.on_event = countUp;
    a.behavior.events.event_context = &a_calls;
    c.behavior.events.on_event = countUp;
    c.behavior.events.event_context = &c_calls;
    d.behavior.interaction.focusable = true;
    const BCtx = struct { cx: *core.Cx, d: *core.Node };
    var bctx = BCtx{ .cx = ctx, .d = d };
    b.behavior.events.on_event = struct {
        fn h(e: Event, p: ?*anyopaque) EventResult {
            const t: *BCtx = @ptrCast(@alignCast(p.?));
            if (e == .mouse_up) t.cx.setFocus(t.d);
            return .ignored;
        }
    }.h;
    b.behavior.events.event_context = &bctx;
    try a.appendChild(std.testing.allocator, b);
    try c.appendChild(std.testing.allocator, d);
    try root.appendChild(std.testing.allocator, a);
    try root.appendChild(std.testing.allocator, c);
    ctx.root = root;
    ctx.setViewport(200, 200);
    ctx.layout();
    _ = ctx.dispatcher.dispatch(Event{ .mouse_up = .{ .x = 10, .y = 10 } }, b);
    try std.testing.expectEqual(@as(u32, 1), a_calls.n);
    try std.testing.expectEqual(@as(u32, 0), c_calls.n);
}
