//! 窗口内连续 pointer drag 的 headless 交互原语。
//!
//! 设计合同见 docs/DRAG_INTERACTION_DESIGN.md。要点：
//! - 不产生 Node、不修改业务数据、不决定视觉样式；
//! - 严格生命周期 `pending -> start -> move* -> end | cancel`，terminal 恰好一次；
//! - `Machine` 是纯状态机（阈值/轴投影/delta/exactly-once），不依赖 Node/Cx/allocator；
//! - `Binding` 是 Scope 管理的 raw-event adapter，占用 source 的共享 event slot；
//! - `Manager` 每 Cx 一个：单会话仲裁、capture/click 抑制/cursor、取消触发器。
//!
//! v1 只覆盖桌面 primary mouse；touch/pen、GestureArena 替换见设计文档 D4。

const std = @import("std");
const core = @import("../core.zig");
const events = @import("../events.zig");

const Cx = core.Cx;
const Node = core.Node;
const Scope = core.Scope;

pub const Axis = enum(u8) {
    both,
    horizontal,
    vertical,
};

pub const Phase = enum(u8) {
    start,
    move,
    end,
    cancel,
};

pub const CancelReason = enum(u8) {
    explicit,
    escape,
    window_blur,
    pointer_cancel,
    source_detached,
    disabled,
    scope_disposed,
    native_handoff,
};

pub const Point = struct { x: f32, y: f32 };

/// generation-safe 句柄（ui.NodeHandle）。
pub const SourceHandle = core.NodeHandle;
pub const PointerId = u32;
pub const mouse_pointer_id: PointerId = 0;

pub const PendingDownEvent = struct {
    source: SourceHandle,
    pointer_id: PointerId,
    position_window: Point,
    button: events.MouseButton,
    modifiers: events.Modifiers,
};

pub const Event = struct {
    phase: Phase,
    source: SourceHandle,
    pointer_id: PointerId,

    /// 未约束的 window logical-point 坐标。
    origin_window: Point,
    position_window: Point,

    /// position - origin，未做 axis 投影。
    raw_delta: Point,

    /// axis 投影后的累计位移。消费者应优先用它从初始模型值计算结果。
    delta: Point,

    /// 相对上一次已派发 drag event 的 axis 投影位移。
    step_delta: Point,

    /// 从 pointer down 起算的单调时间。
    elapsed_ns: u64,
    button: events.MouseButton,
    start_modifiers: events.Modifiers,
    modifiers: events.Modifiers,

    /// 仅 phase == .cancel 时非 null。
    cancel_reason: ?CancelReason = null,
};

pub const StartRequest = struct {
    source: SourceHandle,
    pointer_id: PointerId,
    button: events.MouseButton,
    origin_window: Point,
    position_window: Point,
    raw_delta: Point,
    start_modifiers: events.Modifiers,
    modifiers: events.Modifiers,
};

pub const PendingDownCallback = *const fn (PendingDownEvent, *anyopaque) void;
pub const StartPredicate = *const fn (StartRequest, *anyopaque) bool;
pub const Callback = *const fn (Event, *anyopaque) void;

pub const Config = struct {
    axis: Axis = .both,
    activation_distance: f32 = 4.0,
    /// v1 只接受 .left；保留字段是为了让未来扩展无需改变 Config 形状。
    button: events.MouseButton = .left,
    enabled: bool = true,

    /// null 表示不覆盖系统光标；只在 active 期间生效。
    active_cursor: ?core.CursorShape = .grabbing,

    /// 成功 claim down 后同步调用一次，用于 focus、按下跳值等即时行为。
    /// 它不是 drag phase，pending 结束时没有配对 callback。
    on_pending_down: ?PendingDownCallback = null,

    /// 越过阈值时同步调用一次。false 表示本次序列拒绝启动。
    can_start: ?StartPredicate = null,
};

pub const AttachError = error{
    InvalidActivationDistance,
    UnsupportedButton,
    EventSlotOccupied,
    InvalidSource,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Machine — 纯状态机
// ---------------------------------------------------------------------------

/// 纯状态机：输入 down/move/up/cancel（时间为调用方计算的 elapsed_ns），
/// 输出零到两个 transition。不依赖 Node、Cx、allocator，可独立单测。
pub const Machine = struct {
    axis: Axis = .both,
    activation_distance: f32 = 4.0,

    state: State = .idle,
    origin: Point = .{ .x = 0, .y = 0 },
    /// 最近一次观察到的位置（cancel 时作为事件坐标）。
    last_pos: Point = .{ .x = 0, .y = 0 },
    last_elapsed_ns: u64 = 0,
    /// 最近一次已派发 transition 的位置与投影 delta（step_delta 基准）。
    last_dispatched_pos: Point = .{ .x = 0, .y = 0 },
    last_dispatched_delta: Point = .{ .x = 0, .y = 0 },

    pub const State = enum { idle, pending, active, rejected };

    pub const Transition = struct {
        kind: Phase,
        position: Point,
        raw_delta: Point,
        delta: Point,
        step_delta: Point,
        elapsed_ns: u64,
    };

    pub const Output = struct {
        buf: [2]Transition = undefined,
        len: u8 = 0,

        fn push(self: *Output, t: Transition) void {
            std.debug.assert(self.len < 2);
            self.buf[self.len] = t;
            self.len += 1;
        }

        pub fn slice(self: *const Output) []const Transition {
            return self.buf[0..self.len];
        }
    };

    fn project(self: *const Machine, raw: Point) Point {
        return switch (self.axis) {
            .both => raw,
            .horizontal => .{ .x = raw.x, .y = 0 },
            .vertical => .{ .x = 0, .y = raw.y },
        };
    }

    fn projectedDistance(self: *const Machine, raw: Point) f32 {
        return switch (self.axis) {
            .both => @sqrt(raw.x * raw.x + raw.y * raw.y),
            .horizontal => @abs(raw.x),
            .vertical => @abs(raw.y),
        };
    }

    fn makeTransition(self: *Machine, kind: Phase, pos: Point, elapsed_ns: u64) Transition {
        const raw = Point{ .x = pos.x - self.origin.x, .y = pos.y - self.origin.y };
        const delta = self.project(raw);
        const step = Point{
            .x = delta.x - self.last_dispatched_delta.x,
            .y = delta.y - self.last_dispatched_delta.y,
        };
        self.last_dispatched_pos = pos;
        self.last_dispatched_delta = delta;
        return .{
            .kind = kind,
            .position = pos,
            .raw_delta = raw,
            .delta = delta,
            .step_delta = step,
            .elapsed_ns = elapsed_ns,
        };
    }

    pub fn feedDown(self: *Machine, pos: Point) Output {
        std.debug.assert(self.state == .idle);
        var out = Output{};
        self.origin = pos;
        self.last_pos = pos;
        self.last_elapsed_ns = 0;
        // start 的 step_delta == delta；down 当场激活时两者都为零。
        self.last_dispatched_pos = pos;
        self.last_dispatched_delta = .{ .x = 0, .y = 0 };
        self.state = .pending;
        if (self.activation_distance == 0) {
            self.state = .active;
            out.push(self.makeTransition(.start, pos, 0));
        }
        return out;
    }

    pub fn feedMove(self: *Machine, pos: Point, elapsed_ns: u64) Output {
        var out = Output{};
        self.last_pos = pos;
        self.last_elapsed_ns = elapsed_ns;
        switch (self.state) {
            .idle, .rejected => {},
            .pending => {
                const raw = Point{ .x = pos.x - self.origin.x, .y = pos.y - self.origin.y };
                if (self.projectedDistance(raw) >= self.activation_distance) {
                    self.state = .active;
                    out.push(self.makeTransition(.start, pos, elapsed_ns));
                }
            },
            .active => {
                // 相同坐标不发冗余 move。
                if (pos.x != self.last_dispatched_pos.x or pos.y != self.last_dispatched_pos.y) {
                    out.push(self.makeTransition(.move, pos, elapsed_ns));
                }
            },
        }
        return out;
    }

    pub fn feedUp(self: *Machine, pos: Point, elapsed_ns: u64) Output {
        var out = Output{};
        self.last_pos = pos;
        self.last_elapsed_ns = elapsed_ns;
        switch (self.state) {
            .idle => {},
            .rejected => self.state = .idle,
            .pending => {
                // down 后没有 move、up 坐标却已越过阈值：依次发 start、end。
                // 消费方若在 start 上 reject，由 binding 丢弃后续 end。
                const raw = Point{ .x = pos.x - self.origin.x, .y = pos.y - self.origin.y };
                if (self.projectedDistance(raw) >= self.activation_distance) {
                    self.state = .active;
                    out.push(self.makeTransition(.start, pos, elapsed_ns));
                    out.push(self.makeTransition(.end, pos, elapsed_ns));
                }
                self.state = .idle;
            },
            .active => {
                // end 使用 mouse up 的最终坐标，即便与最后一次 move 相同也要发。
                out.push(self.makeTransition(.end, pos, elapsed_ns));
                self.state = .idle;
            },
        }
        return out;
    }

    /// 任意取消触发。active 恰好发一次 cancel（坐标 = 最近观察位置）；
    /// pending/rejected 静默回 idle。
    pub fn feedCancel(self: *Machine) Output {
        var out = Output{};
        switch (self.state) {
            .idle => {},
            .pending, .rejected => self.state = .idle,
            .active => {
                out.push(self.makeTransition(.cancel, self.last_pos, self.last_elapsed_ns));
                self.state = .idle;
            },
        }
        return out;
    }

    /// can_start 返回 false 时由 binding 调用：丢弃刚发出的 start，本次
    /// pointer sequence 不再询问 predicate、不发任何 drag callback。
    /// up 当场越阈值的情形下 machine 已回到 idle，此时保持 idle 即可。
    pub fn reject(self: *Machine) void {
        std.debug.assert(self.state != .pending);
        if (self.state == .active) self.state = .rejected;
    }

    pub fn reset(self: *Machine) void {
        self.state = .idle;
    }
};

// ---------------------------------------------------------------------------
// Manager — 每 Cx 一个的中心仲裁
// ---------------------------------------------------------------------------

pub const Manager = struct {
    session: ?Session = null,
    /// 每次 claim 递增。callback 重入后用它重新校验 session 身份，
    /// 避免"旧 session 的后续处理写到新 session 上"。
    generation: u32 = 0,

    pub const SessionPhase = enum { pending, active, rejected };

    pub const Session = struct {
        binding: *Binding,
        source: SourceHandle,
        pointer_id: PointerId,
        button: events.MouseButton,
        start_modifiers: events.Modifiers,
        phase: SessionPhase = .pending,
        captured: bool = false,
        cursor_token: ?core.CursorToken = null,
    };

    fn isCurrent(self: *const Manager, binding: *const Binding, generation: u32) bool {
        const s = self.session orelse return false;
        return s.binding == binding and self.generation == generation;
    }

    /// Escape 优先消费：有 session（pending/rejected/active 任一）就取消并吞掉。
    pub fn handleEscape(self: *Manager, cx: *Cx) bool {
        if (self.session == null) return false;
        self.cancel(cx, .escape);
        return true;
    }

    /// 统一取消入口。active 恰好发一次主 callback(.cancel)；pending/rejected
    /// 静默清理。两者都抑制本次 pointer sequence 的 click。幂等。
    pub fn cancel(self: *Manager, cx: *Cx, reason: CancelReason) void {
        const session = self.session orelse return;
        // 先提交清理（commit-before-callback）：callback 重入 cancel/dispose
        // 时 session 已经为空，走幂等 no-op。
        self.session = null;
        const binding = session.binding;

        // 被强制终止的 pointer sequence 不再是有效 click；后到的 mouse up
        // 只做幂等清理（标记在下次 left down 时重置）。
        cx.dispatcher.cancelClickSynthesisForActivePointer();

        if (session.cursor_token) |token| cx.releaseCursor(token);
        if (session.captured) {
            if (cx.dispatcher.releasePointerCaptureFor(session.source)) {
                cx.resyncPointerAfterCaptureRelease(cx.mouse_x, cx.mouse_y, null);
            }
        }

        // 主 callback 只在 session 已 active（start 已派发）时才发：machine
        // 可能已越阈值但 start 回调尚未送达消费者（can_start/on_pending_down
        // 重入取消），此时从用户视角 drag 从未开始，必须静默。
        if (session.phase == .active) {
            binding.start_modifiers_snapshot = session.start_modifiers;
            const out = binding.machine.feedCancel();
            for (out.slice()) |t| {
                std.debug.assert(t.kind == .cancel);
                binding.dispatchTransition(t, reason);
            }
        }
        binding.machine.reset();
    }

    /// Node lifecycle：source 所在子树被 detach/destroy 时取消 session。
    /// 只用稳定 id 判定，不解引用可能已失效的指针。
    pub fn handleSubtreeInvalidation(self: *Manager, cx: *Cx, subtree_root: *Node) void {
        const session = self.session orelse return;
        if (isNodeInSubtree(subtree_root, session.source.id)) {
            self.cancel(cx, .source_detached);
        }
    }
};

fn isNodeInSubtree(root: *Node, node_id: u32) bool {
    if (root.id == node_id) return true;
    for (root.children.items) |child| {
        if (isNodeInSubtree(child, node_id)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Binding — Scope 管理的 raw-event adapter
// ---------------------------------------------------------------------------

pub const Binding = struct {
    cx: *Cx,
    /// 只在 source 自己的 event handler 内解引用（handler 挂在 source 上，
    /// 事件到达即证明节点存活）；跨帧持有一律走 source_handle。
    source_node: *Node,
    /// claim 时经 registry 往返校验后写入。
    source_handle: SourceHandle = .{ .id = 0, .generation = 0 },
    config: Config,
    callback: Callback,
    context: *anyopaque,
    machine: Machine,
    enabled: bool,
    /// down 时刻的 Instant，elapsed_ns 的基准。
    down_instant: ?std.time.Instant = null,
    /// 最近一次输入携带的修饰键（move 无实时值时退化为最近已知值）。
    cur_modifiers: events.Modifiers = .{},
    /// terminal 派发需要的 down 时刻快照（session 清空后仍可用）。
    start_modifiers_snapshot: events.Modifiers = .{},

    /// 在 source 上注册 drag 行为。Binding 由 scope 管理，调用方不手动 free；
    /// 失败是事务性的，不留半注册状态。
    ///
    /// 生命周期合同（docs/DRAG_INTERACTION_DESIGN.md §11.3）：attach 在
    /// callback context 创建**之后**调用，则 scope 逆序清理保证 cancel 回调
    /// 先于 context 销毁。
    pub fn attach(
        scope: *Scope,
        cx: *Cx,
        source: *Node,
        config: Config,
        callback: Callback,
        context: *anyopaque,
    ) AttachError!*Binding {
        if (std.math.isNan(config.activation_distance) or
            std.math.isInf(config.activation_distance) or
            config.activation_distance < 0)
        {
            return AttachError.InvalidActivationDistance;
        }
        if (config.button != .left) return AttachError.UnsupportedButton;
        const ev = &source.behavior.events;
        if (ev.on_event != null or ev.on_event_capture != null or
            ev.on_scroll != null or ev.event_context != null)
        {
            return AttachError.EventSlotOccupied;
        }
        // source 若已注册进 registry，其 id 必须解析回自己；解析到别的节点
        // 说明句柄不稳定（例如 id 复用未被 registry 跟踪）。未注册的新节点
        // 允许通过，claim 时再做往返校验。
        const source_handle: SourceHandle = blk: {
            const h = cx.node_registry.handleFor(source);
            if (cx.node_registry.resolve(h, null)) |resolved| {
                if (resolved != source) return AttachError.InvalidSource;
            }
            // Establish a generation before the first event. This lets scope
            // cleanup distinguish a live, not-yet-registered source from a node
            // that was already freed, without dereferencing a stale pointer.
            const generation = cx.node_registry.trackGeneration(source) catch return AttachError.OutOfMemory;
            break :blk .{ .id = source.id, .generation = generation };
        };

        const binding = cx.allocator.create(Binding) catch return AttachError.OutOfMemory;
        errdefer cx.allocator.destroy(binding);
        binding.* = .{
            .cx = cx,
            .source_node = source,
            .source_handle = source_handle,
            .config = config,
            .callback = callback,
            .context = context,
            .machine = .{
                .axis = config.axis,
                .activation_distance = config.activation_distance,
            },
            .enabled = config.enabled,
        };
        scope.registerResource(binding, destroyResource) catch return AttachError.OutOfMemory;

        // 所有可失败操作已完成，才占用 event slot。
        ev.on_event = sourceEventHandler;
        ev.event_context = binding;
        return binding;
    }

    fn destroyResource(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const binding: *Binding = @ptrCast(@alignCast(ptr));
        const cx = binding.cx;
        // scope dispose 时若 session 属于本 binding：cancel 回调先于 context
        // 销毁（context 注册在前、逆序清理在后，构造期可证明）。
        if (cx.drag_manager.session) |s| {
            if (s.binding == binding) cx.drag_manager.cancel(cx, .scope_disposed);
        }
        // 摘除 event slot：只在 source 仍以同一身份存活时动它。节点可能已经
        // 先于 scope 销毁（或从未注册），此时跳过 —— 与既有组件的
        // scope-owned event_context 同一暴露面。
        const live_source = cx.node_registry.resolve(binding.source_handle, null) orelse
            if (cx.node_registry.isCurrentIdentity(binding.source_handle, binding.source_node)) binding.source_node else null;
        if (live_source) |node| {
            if (node == binding.source_node) {
                node.behavior.events.on_event = null;
                node.behavior.events.event_context = null;
            }
        }
        allocator.destroy(binding);
    }

    pub fn setEnabled(self: *Binding, enabled: bool) void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        if (!enabled) {
            if (self.cx.drag_manager.session) |s| {
                if (s.binding == self) self.cx.drag_manager.cancel(self.cx, .disabled);
            }
        }
    }

    pub fn cancel(self: *Binding, reason: CancelReason) void {
        if (self.cx.drag_manager.session) |s| {
            if (s.binding == self) self.cx.drag_manager.cancel(self.cx, reason);
        }
    }

    pub fn isPending(self: *const Binding) bool {
        const s = self.cx.drag_manager.session orelse return false;
        return s.binding == self and s.phase == .pending;
    }

    pub fn isDragging(self: *const Binding) bool {
        const s = self.cx.drag_manager.session orelse return false;
        return s.binding == self and s.phase == .active;
    }

    // -- 内部 --

    fn elapsedNs(self: *const Binding) u64 {
        const down = self.down_instant orelse return 0;
        const now = std.time.Instant.now() catch return 0;
        // 时钟相同或倒退时不下溢。
        if (now.order(down) == .lt) return 0;
        return now.since(down);
    }

    fn buildEvent(self: *const Binding, t: Machine.Transition, session: Manager.Session, reason: ?CancelReason) Event {
        return .{
            .phase = t.kind,
            .source = session.source,
            .pointer_id = session.pointer_id,
            .origin_window = self.machine.origin,
            .position_window = t.position,
            .raw_delta = t.raw_delta,
            .delta = t.delta,
            .step_delta = t.step_delta,
            .elapsed_ns = t.elapsed_ns,
            .button = session.button,
            .start_modifiers = session.start_modifiers,
            .modifiers = self.cur_modifiers,
            .cancel_reason = reason,
        };
    }

    /// 派发一个 transition 给消费者。调用前 session 已按 commit-before-callback
    /// 处理完毕；这里只复制事件与 callback，不在 callback 后解引用 self 之外
    /// 无法证明存活的状态。
    fn dispatchTransition(self: *Binding, t: Machine.Transition, reason: ?CancelReason) void {
        // 注意：terminal (end/cancel) 调用时 manager.session 已清空，
        // buildEvent 需要的 session 信息由调用方传入快照。
        const s = self.cx.drag_manager.session orelse blk: {
            // terminal 路径：session 已清，退化用 binding 自身缓存。
            break :blk Manager.Session{
                .binding = self,
                .source = self.source_handle,
                .pointer_id = mouse_pointer_id,
                .button = self.config.button,
                .start_modifiers = self.start_modifiers_snapshot,
            };
        };
        const event = self.buildEvent(t, s, reason);
        const cb = self.callback;
        const ctx = self.context;
        cb(event, ctx);
    }

    /// 激活序列（§8.2）：标 active → 抑制 click → capture → cursor → start 回调。
    /// 返回 false 表示激活中止（source 失效或 callback 重入清了 session）。
    fn activate(self: *Binding, t: Machine.Transition, generation: u32) bool {
        const cx = self.cx;
        const manager = &cx.drag_manager;

        // can_start：越过阈值时同步询问一次；拒绝则本序列静默作废且抑制 click。
        if (self.config.can_start) |predicate| {
            const s = manager.session.?;
            const request = StartRequest{
                .source = s.source,
                .pointer_id = s.pointer_id,
                .button = s.button,
                .origin_window = self.machine.origin,
                .position_window = t.position,
                .raw_delta = t.raw_delta,
                .start_modifiers = s.start_modifiers,
                .modifiers = self.cur_modifiers,
            };
            const ctx = self.context;
            const allowed = predicate(request, ctx);
            // predicate 可重入：重新校验 session。
            if (!manager.isCurrent(self, generation)) return false;
            if (!allowed) {
                self.machine.reject();
                manager.session.?.phase = .rejected;
                cx.dispatcher.cancelClickSynthesisForActivePointer();
                return false;
            }
        }

        // 1. manager 将 session 标为 active。
        manager.session.?.phase = .active;
        // 2. 抑制本次 pointer sequence 的 click synthesis。
        cx.dispatcher.cancelClickSynthesisForActivePointer();
        // 3. 设置 pointer capture（source 必须仍可解析，否则走 detach 清理）。
        const source = cx.node_registry.resolve(manager.session.?.source, null) orelse {
            manager.cancel(cx, .source_detached);
            return false;
        };
        cx.setPointerCapture(source);
        manager.session.?.captured = true;
        // 4. 设置可选 active cursor。
        if (self.config.active_cursor) |shape| {
            // 拿不到 cursor lease 只是「拖拽期间不换光标」，拖拽本身照常
            // 进行（cursor_token 保持 null，finishSession/cancel 都处理 null）。
            //
            // 不能 panic：acquireCursor 的 error.NoPointerCapture 是可恢复的
            // 协议状态，而且能被**合法的 app 回调**触发 —— setPointerCapture
            // 会先 release 旧 capture 并触发 on_capture_lost，若 app 在那个
            // 回调里把 capture 转给别的节点（对失去 capture 做出响应，完全
            // 合理），外层 setPointerCapture 会因 epoch 变化提前返回，这里就
            // 拿不到 capture 了。库不该因为 app 的合法用法杀掉宿主进程。
            manager.session.?.cursor_token = cx.acquireCursor(source, shape) catch |err| switch (err) {
                error.OutOfMemory => @panic("OOM: drag cursor lease"),
                error.NoPointerCapture => null,
            };
        }
        // 5. 发出 start callback。
        self.dispatchTransition(t, null);
        return manager.isCurrent(self, generation);
    }

    /// 终止清理 + end 回调。session 快照先落 binding 缓存再清 manager。
    fn finishSession(self: *Binding, t: Machine.Transition) void {
        const cx = self.cx;
        const session = cx.drag_manager.session.?;
        self.start_modifiers_snapshot = session.start_modifiers;
        cx.drag_manager.session = null;
        if (session.cursor_token) |token| cx.releaseCursor(token);
        if (session.captured) {
            // 自然 mouse up 时 dispatcher 也会自动清 capture；这里带比对释放，
            // 与之幂等共存（up 之外的路径同样安全）。hover resync 由
            // handleMouseUpEx 的 had_pointer_capture 分支负责。
            _ = cx.dispatcher.releasePointerCaptureFor(session.source);
        }
        self.machine.reset();
        self.dispatchTransition(t, null);
    }

    fn processOutput(self: *Binding, out: Machine.Output, generation: u32) void {
        const manager = &self.cx.drag_manager;
        for (out.slice()) |t| {
            if (!manager.isCurrent(self, generation)) return;
            switch (t.kind) {
                .start => {
                    // 激活失败（reject / source 失效 / callback 重入清 session）
                    // 时丢弃剩余 transition（例如 up 越阈值的 end）。
                    if (!self.activate(t, generation)) return;
                },
                .move => self.dispatchTransition(t, null),
                .end => self.finishSession(t),
                .cancel => unreachable, // cancel 只经 Manager.cancel 派发
            }
        }
    }

    fn sourceEventHandler(event: core.Event, raw_ctx: ?*anyopaque) core.EventResult {
        const binding: *Binding = @ptrCast(@alignCast(raw_ctx orelse return .ignored));
        const cx = binding.cx;
        const manager = &cx.drag_manager;

        switch (event) {
            .mouse_down => |e| {
                if (!binding.enabled) return .ignored;
                if (e.button != binding.config.button) return .ignored;
                // 每个 Cx 同时最多一个 session；新的非同序列 down 不抢占。
                if (manager.session != null) return .ignored;
                if (binding.machine.state != .idle) return .ignored;

                // 稳定句柄往返校验：拿不到就不 claim。
                const handle = cx.node_registry.handleFor(binding.source_node);
                const resolved = cx.node_registry.resolve(handle, null) orelse return .ignored;
                if (resolved != binding.source_node) return .ignored;
                binding.source_handle = handle;

                manager.generation +%= 1;
                const generation = manager.generation;
                manager.session = .{
                    .binding = binding,
                    .source = handle,
                    .pointer_id = mouse_pointer_id,
                    .button = e.button,
                    .start_modifiers = e.modifiers,
                };
                binding.start_modifiers_snapshot = e.modifiers;
                binding.cur_modifiers = e.modifiers;
                binding.down_instant = std.time.Instant.now() catch null;

                const out = binding.machine.feedDown(.{ .x = e.x, .y = e.y });

                // 顺序固定：提交 pending ownership → on_pending_down → 按
                // generation 重新校验 → (activation_distance==0) 激活序列。
                if (binding.config.on_pending_down) |pending_cb| {
                    const pending_event = PendingDownEvent{
                        .source = handle,
                        .pointer_id = mouse_pointer_id,
                        .position_window = .{ .x = e.x, .y = e.y },
                        .button = e.button,
                        .modifiers = e.modifiers,
                    };
                    const ctx = binding.context;
                    pending_cb(pending_event, ctx);
                    if (!manager.isCurrent(binding, generation)) return .stop;
                }

                binding.processOutput(out, generation);
                return .stop;
            },
            .mouse_move => |e| {
                if (!manager.isCurrent(binding, manager.generation)) return .ignored;
                if (manager.session.?.binding != binding) return .ignored;
                binding.cur_modifiers = e.modifiers;
                const out = binding.machine.feedMove(.{ .x = e.x, .y = e.y }, binding.elapsedNs());
                binding.processOutput(out, manager.generation);
                return .stop;
            },
            .mouse_up => |e| {
                const s = manager.session orelse return .ignored;
                if (s.binding != binding) return .ignored;
                if (e.button != s.button) return .ignored;
                binding.cur_modifiers = e.modifiers;
                const generation = manager.generation;
                const out = binding.machine.feedUp(.{ .x = e.x, .y = e.y }, binding.elapsedNs());
                if (out.len == 0) {
                    // pending 未越阈值（click 保持有效）或 rejected 的收尾：
                    // 静默清 session。rejected 的 click 抑制已在 reject 时置位。
                    manager.session = null;
                    binding.machine.reset();
                    return .stop;
                }
                binding.processOutput(out, generation);
                // up 越阈值但 can_start 拒绝：sequence 已随 up 结束，session
                // 不能留到下一次 down（end 正常派发时 finishSession 已清）。
                if (manager.isCurrent(binding, generation)) {
                    manager.session = null;
                    binding.machine.reset();
                }
                return .stop;
            },
            else => return .ignored,
        }
    }
};

// ---------------------------------------------------------------------------
// Machine 单测（§18.1）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectPoint(expected_x: f32, expected_y: f32, p: Point) !void {
    try testing.expectEqual(expected_x, p.x);
    try testing.expectEqual(expected_y, p.y);
}

test "Machine: down/up 未越阈值零 transition" {
    var m = Machine{ .activation_distance = 4 };
    try testing.expectEqual(@as(u8, 0), m.feedDown(.{ .x = 10, .y = 10 }).len);
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 12, .y = 11 }, 100).len);
    try testing.expectEqual(@as(u8, 0), m.feedUp(.{ .x = 12, .y = 11 }, 200).len);
    try testing.expectEqual(Machine.State.idle, m.state);
}

test "Machine: 阈值边界 — 小于不激活、等于激活" {
    var m = Machine{ .axis = .horizontal, .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 3.99, .y = 100 }, 1).len);
    const out = m.feedMove(.{ .x = -4, .y = 0 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.start, out.buf[0].kind);
    try expectPoint(-4, 0, out.buf[0].delta);
}

test "Machine: vertical 轴投影只看 dy" {
    var m = Machine{ .axis = .vertical, .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    // dx 巨大也不激活
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 100, .y = 3 }, 1).len);
    const out = m.feedMove(.{ .x = 100, .y = 5 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try expectPoint(0, 5, out.buf[0].delta);
    try expectPoint(100, 5, out.buf[0].raw_delta);
}

test "Machine: both 用欧氏距离" {
    var m = Machine{ .axis = .both, .activation_distance = 5 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 3, .y = 3 }, 1).len); // sqrt(18) < 5
    const out = m.feedMove(.{ .x = 3, .y = 4 }, 2); // 5 == 5
    try testing.expectEqual(@as(u8, 1), out.len);
}

test "Machine: activation_distance=0 在 down 当场 start 且 delta 为零" {
    var m = Machine{ .activation_distance = 0 };
    const out = m.feedDown(.{ .x = 7, .y = 9 });
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.start, out.buf[0].kind);
    try expectPoint(0, 0, out.buf[0].delta);
    try expectPoint(0, 0, out.buf[0].step_delta);
    try testing.expectEqual(Machine.State.active, m.state);
}

test "Machine: start 只发一次，start.step_delta == delta，move 的 total/step 正确" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 10, .y = 10 });
    const start_out = m.feedMove(.{ .x = 20, .y = 10 }, 1);
    try testing.expectEqual(@as(u8, 1), start_out.len);
    try expectPoint(10, 0, start_out.buf[0].delta);
    try expectPoint(10, 0, start_out.buf[0].step_delta);

    const move_out = m.feedMove(.{ .x = 25, .y = 13 }, 2);
    try testing.expectEqual(@as(u8, 1), move_out.len);
    try testing.expectEqual(Phase.move, move_out.buf[0].kind);
    try expectPoint(15, 3, move_out.buf[0].delta);
    try expectPoint(5, 3, move_out.buf[0].step_delta);
}

test "Machine: 相同坐标不发冗余 move" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 5, .y = 5 }, 1);
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 5, .y = 5 }, 2).len);
}

test "Machine: up 坐标与最后 move 不同，end 反映最终位置" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 5, .y = 0 }, 1);
    const out = m.feedUp(.{ .x = 9, .y = 2 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.end, out.buf[0].kind);
    try expectPoint(9, 2, out.buf[0].delta);
    try expectPoint(4, 2, out.buf[0].step_delta);
}

test "Machine: up 与最后 move 相同坐标仍发 end" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 5, .y = 0 }, 1);
    const out = m.feedUp(.{ .x = 5, .y = 0 }, 2);
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.end, out.buf[0].kind);
}

test "Machine: 无 move 但 up 跨阈值，顺序为 start/end" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    const out = m.feedUp(.{ .x = 10, .y = 0 }, 1);
    try testing.expectEqual(@as(u8, 2), out.len);
    try testing.expectEqual(Phase.start, out.buf[0].kind);
    try testing.expectEqual(Phase.end, out.buf[1].kind);
    try expectPoint(10, 0, out.buf[0].delta);
    try expectPoint(0, 0, out.buf[1].step_delta);
    try testing.expectEqual(Machine.State.idle, m.state);
}

test "Machine: active cancel 恰好一次，坐标用最近观察位置" {
    var m = Machine{ .activation_distance = 0 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 8, .y = 6 }, 5);
    const out = m.feedCancel();
    try testing.expectEqual(@as(u8, 1), out.len);
    try testing.expectEqual(Phase.cancel, out.buf[0].kind);
    try expectPoint(8, 6, out.buf[0].position);
    try testing.expectEqual(@as(u64, 5), out.buf[0].elapsed_ns);
    // 幂等：再 cancel 无输出
    try testing.expectEqual(@as(u8, 0), m.feedCancel().len);
}

test "Machine: pending/rejected cancel 静默" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(u8, 0), m.feedCancel().len);
    try testing.expectEqual(Machine.State.idle, m.state);

    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 10, .y = 0 }, 1); // start
    m.reject();
    try testing.expectEqual(@as(u8, 0), m.feedCancel().len);
    try testing.expectEqual(Machine.State.idle, m.state);
}

test "Machine: rejected 后 move/up 均无输出" {
    var m = Machine{ .activation_distance = 4 };
    _ = m.feedDown(.{ .x = 0, .y = 0 });
    _ = m.feedMove(.{ .x = 10, .y = 0 }, 1);
    m.reject();
    try testing.expectEqual(@as(u8, 0), m.feedMove(.{ .x = 50, .y = 50 }, 2).len);
    try testing.expectEqual(@as(u8, 0), m.feedUp(.{ .x = 50, .y = 50 }, 3).len);
    try testing.expectEqual(Machine.State.idle, m.state);
}
