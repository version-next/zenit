//! Cx 帧节奏：墙钟派生的帧时钟（advanceFrameClock）、layout 入口、
//! idle 停帧门控（wantsFrame / hasPendingSceneWork / nextWakeDelayNs）
//! 与 deferred 任务预算。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const PartialInteractionRoots = cx_runtime_index.PartialInteractionRoots;
const DrainDeferredResult = core.DrainDeferredResult;
const LayoutContext = layout_engine.LayoutContext;
const Node = core.Node;
const Task = core.Task;
const TaskPriority = core.TaskPriority;
const WorkKey = core.WorkKey;
const cx_cursor = @import("cx_cursor.zig");
const cx_render = @import("cx_render.zig");
const cx_runtime_index = @import("cx_runtime_index.zig");
const debug_env = @import("debug_env.zig");
const deferred_scheduler_mod = @import("../deferred_scheduler.zig");
const layout_engine = core.layout_engine;
const renderDirtyDebugEnabled = debug_env.renderDirtyDebugEnabled;
const wantsFrameDebugEnabled = debug_env.wantsFrameDebugEnabled;

pub fn advanceFrameClock(self: *Cx) void {
    const now = std.time.Instant.now() catch return;
    // 始终更新 last_frame_instant（即便 idle 帧也要记当前时刻），让下一个
    // 活跃帧的 dt 从"现在"算起，而不是把整段 idle 时长一次性灌进动画。
    defer self.last_frame_instant = now;

    // 逻辑时钟原点：首次调用时锚定（含 idle 首帧，保证 epoch 一定早于任何 active 帧）。
    if (self.clock_epoch == null) self.clock_epoch = now;

    // Idle 帧不推进逻辑时钟：根全 clean + 无浮层入/出场动画 + 无显式重绘请求
    // -> frame_time_ms 冻结 -> render() 的 time_unchanged 零脏帧快速路径保持成立
    // （否则每帧时钟都变，永远走全量 render，且 e2e query 在空闲态读到的帧不稳定）。
    // 任一活跃信号都会让时钟前进，驱动 overlay/Spring 等绝对时间戳动画。
    const idle = if (self.root) |r|
        cx_render.isTreeFullyClean(r) and
            !self.overlay_stack.hasActiveAnimations() and
            !self.needs_redraw
    else
        true;
    if (idle) {
        // idle 期间真实时间照走，但逻辑时钟必须冻结。把这段时长记进暂停偏移，
        // 否则下一个 active 帧会把整段 idle 一次性灌进动画（浮层瞬间跳到终态）。
        if (self.last_frame_instant) |prev| self.clock_paused_ns += now.since(prev);
        return;
    }

    // 边沿消费：显式重绘请求驱动了本帧的时钟推进，到此即被消费。
    // 帧内活跃信号（动画 tick / overlay tick / deferred work / 事件）
    // 会重新置 true 驱动下一帧；帧末仍为 false = 可进入 idle 停帧。
    // 注意消费点必须在 idle 判定**之后**，在帧循环里提前清会把
    // 本次唤醒的时钟冻住（时间驱动的 overlay 入场动画会永远停在 0）。
    self.needs_redraw = false;

    if (self.last_frame_instant) |prev| {
        const dt_ns = now.since(prev);
        const dt_s = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
        // 增量 dt 仍钳到 [~0, 0.1s]：Spring 等物理积分器需要有界步长才稳定，
        // 一个超大 dt 会让弹簧数值发散。这个 clamp 只服务增量消费者,
        // 绝对时钟另算（见下），否则慢帧会被永久削短。
        self.frame_dt_seconds = std.math.clamp(dt_s, 0.0, 0.1);
        self.frame_dt_ms = self.frame_dt_seconds * 1000.0;
    } else {
        // 首帧：无前一拍，给一个标称 60fps dt。
        self.frame_dt_seconds = 1.0 / 60.0;
        self.frame_dt_ms = 1000.0 / 60.0;
    }

    // 绝对时钟从 epoch 派生，扣除累计 idle 暂停。**不经 clamp**：tween/keyframe
    // 按 (now_ms - start_time_ms) 算进度，任何削短都会让动画慢放且永不追回。
    const since_epoch_ns = now.since(self.clock_epoch.?);
    const live_ns = since_epoch_ns -| self.clock_paused_ns;
    self.frame_time_ms = @as(f64, @floatFromInt(live_ns)) / std.time.ns_per_ms;
}

pub fn layout(self: *Cx) void {
    defer cx_cursor.updateCursorShape(self);
    self.text.syncLegacyMeasureHooks();
    if (self.root) |r| {
        const had_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
        const had_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction;
        var partial_interaction_roots = PartialInteractionRoots{};
        if ((had_dirty or had_interaction_dirty) and !r.frame_state.state_bits.dirty.runtime.subtree_dirty and !r.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.collectPartialInteractionRoots(self, r, &partial_interaction_roots);
        }
        if (had_dirty) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        if (had_dirty or had_interaction_dirty) {
            // OOM 不吞：见 rebuildRuntimeIndexesIfCurrentRootDirty 的说明。
            if (r.frame_state.state_bits.dirty.runtime.subtree_dirty) {
                cx_runtime_index.rebuildRuntimeIndexes(self) catch @panic("OOM: rebuildRuntimeIndexes (frame end)");
            } else if (r.frame_state.state_bits.dirty.pipeline.subtree_order) {
                cx_runtime_index.rebuildOrderIndexes(self) catch @panic("OOM: rebuildOrderIndexes (frame end)");
            } else {
                cx_runtime_index.rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildInteractionIndex (frame end)");
            }
        }
    }
    self.frame_count +%= 1;
    self.before_render_frame = null;
    self.before_render_time_ms = std.math.nan(f64);
    self.perf.resetFrame();
}

pub fn enqueueTask(self: *Cx, task: *Task) !u64 {
    return self.deferred_scheduler.enqueueTask(task);
}

pub fn cancelTask(self: *Cx, key: WorkKey) void {
    self.deferred_scheduler.cancelTask(key);
}

pub fn promoteTask(self: *Cx, key: WorkKey, priority: TaskPriority) void {
    self.deferred_scheduler.promoteTask(key, priority);
}

pub fn hasReadyWork(self: *Cx) bool {
    const now_ns = currentDeferredTimeNs(self);
    return self.deferred_scheduler.hasReadyWork(now_ns);
}

pub fn hasPendingWork(self: *const Cx) bool {
    return self.deferred_scheduler.hasPendingWork();
}

// ---- 计时器（Cx.setTimer / clearTimer / fireDueTimers 的实现）----

const Timer = Cx.Timer;

pub fn setTimer(self: *Cx, delay_ns: u64, callback: *const fn (?*anyopaque) void, context: ?*anyopaque) !u64 {
    const id = self.next_timer_id;
    try self.timers.append(self.allocator, .{
        .id = id,
        .due_ns = currentDeferredTimeNs(self) +| delay_ns,
        .callback = callback,
        .context = context,
    });
    self.next_timer_id +%= 1;
    if (self.next_timer_id == 0) self.next_timer_id = 1;
    return id;
}

pub fn clearTimer(self: *Cx, id: u64) void {
    for (self.timers.items, 0..) |t, i| {
        if (t.id != id) continue;
        _ = self.timers.swapRemove(i);
        return;
    }
}

fn hasDueTimer(self: *const Cx) bool {
    if (self.timers.items.len == 0) return false;
    const now = currentDeferredTimeNs(self);
    for (self.timers.items) |t| {
        if (t.due_ns <= now) return true;
    }
    return false;
}

fn nextTimerDelayNs(self: *const Cx) ?u64 {
    if (self.timers.items.len == 0) return null;
    const now = currentDeferredTimeNs(self);
    var best: u64 = std.math.maxInt(u64);
    for (self.timers.items) |t| best = @min(best, t.due_ns -| now);
    return best;
}

pub fn fireDueTimers(self: *Cx) void {
    if (self.timers.items.len == 0) return;
    const now = currentDeferredTimeNs(self);
    var fired: [16]Timer = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < self.timers.items.len and n < fired.len) {
        const t = self.timers.items[i];
        if (t.due_ns <= now) {
            fired[n] = t;
            n += 1;
            _ = self.timers.swapRemove(i);
            continue;
        }
        i += 1;
    }
    for (fired[0..n]) |t| t.callback(t.context);
    if (n > 0) self.needs_redraw = true;
}

pub fn nextWakeDelayNs(self: *const Cx) ?u64 {
    var best: ?u64 = nextTimerDelayNs(self);
    if (self.next_redraw_scheduled_at) |scheduled_at| {
        if (self.next_redraw_delay_ns) |delay_ns| {
            const now = std.time.Instant.now() catch return 0;
            const elapsed = switch (now.order(scheduled_at)) {
                .lt => 0,
                .eq, .gt => now.since(scheduled_at),
            };
            const d = delay_ns -| elapsed;
            best = if (best) |b| @min(b, d) else d;
        }
    }
    const now_ns = currentDeferredTimeNs(self);
    if (self.deferred_scheduler.nextReadyDelayNs(now_ns)) |delay_ns| {
        best = if (best) |b| @min(b, delay_ns) else delay_ns;
    }
    return best;
}

pub fn wantsFrame(self: *Cx) bool {
    _ = self.processScheduledRedraw();
    if (wantsFrameDebugEnabled()) return wantsFrameDiagnosed(self);
    return self.needs_redraw or
        hasDueTimer(self) or
        self.hasReadyWork() or
        self.hasPendingSceneWork();
}

/// ZENIT_DEBUG_WANTS_FRAME=1：逐条打印 wantsFrame 的子条件，定位
/// "静止画布却每帧想渲染"时到底是哪一条持续为真。只在 env 开启时走。
fn wantsFrameDiagnosed(self: *Cx) bool {
    const needs = self.needs_redraw or hasDueTimer(self);
    const ready = self.hasReadyWork();
    const scene = self.hasPendingSceneWork();
    const want = needs or ready or scene;
    if (want) {
        var buf: [512]u8 = undefined;
        var w: usize = 0;
        const append = struct {
            fn f(b: []u8, n: *usize, comptime fmt: []const u8, args: anytype) void {
                const s = std.fmt.bufPrint(b[n.*..], fmt, args) catch return;
                n.* += s.len;
            }
        }.f;
        append(&buf, &w, "[wants-frame] needs_redraw={} ready_work={} scene={}", .{ needs, ready, scene });
        if (scene) {
            if (self.root) |root| {
                const d = &root.frame_state.state_bits.dirty;
                append(&buf, &w, " | layout={} sub_layout={} render={} sub_render={}", .{
                    d.core.layout, d.core.subtree_layout, d.core.render, d.core.subtree_render,
                });
                append(&buf, &w, " composite={} sub_composite={} rt={} sub_rt={}", .{
                    d.pipeline.composite, d.pipeline.subtree_composite, d.runtime.dirty, d.runtime.subtree_dirty,
                });
                append(&buf, &w, " order={} sub_order={} inter={} sub_inter={} loose={}", .{
                    d.pipeline.order,               d.pipeline.subtree_order,                               d.pipeline.interaction,
                    d.pipeline.subtree_interaction, cx_runtime_index.subtreeHasLooseInteractionDirty(root),
                });
            }
            append(&buf, &w, " anim={} overlay_anim={}", .{
                self.last_tick_animations_active, self.overlay_stack.hasActiveAnimations(),
            });
        }
        std.debug.print("{s}\n", .{buf[0..w]});
    }
    return want;
}

pub fn hasPendingSceneWork(self: *const Cx) bool {
    const root = self.root orelse return false;
    return root.frame_state.state_bits.dirty.core.layout or
        root.frame_state.state_bits.dirty.core.subtree_layout or
        root.frame_state.state_bits.dirty.core.render or
        root.frame_state.state_bits.dirty.core.subtree_render or
        root.frame_state.state_bits.dirty.pipeline.composite or
        root.frame_state.state_bits.dirty.pipeline.subtree_composite or
        root.frame_state.state_bits.dirty.runtime.dirty or
        root.frame_state.state_bits.dirty.runtime.subtree_dirty or
        root.frame_state.state_bits.dirty.pipeline.order or
        root.frame_state.state_bits.dirty.pipeline.subtree_order or
        root.frame_state.state_bits.dirty.pipeline.interaction or
        root.frame_state.state_bits.dirty.pipeline.subtree_interaction or
        cx_runtime_index.subtreeHasLooseInteractionDirty(root) or
        self.last_tick_animations_active or
        self.overlay_stack.hasActiveAnimations();
}

pub fn debugPrintRenderDirtyNodes(self: *const Cx, node: *Node) void {
    if (!renderDirtyDebugEnabled()) return;
    if (!node.frame_state.state_bits.dirty.core.render) {
        if (node.frame_state.state_bits.dirty.core.subtree_render) {
            for (node.children.items) |child| {
                debugPrintRenderDirtyNodes(self, child);
            }
        }
        return;
    }
    std.debug.print("[render-dirty] node_id={d} render={} subtree={} component={s} test_id={s}\n", .{
        node.id,
        node.frame_state.state_bits.dirty.core.render,
        node.frame_state.state_bits.dirty.core.subtree_render,
        node.meta.ownership.meta.component_name orelse "(nil)",
        node.meta.ownership.meta.test_id orelse "(nil)",
    });
}

fn hasActiveNodeAnimations(node: *Node) bool {
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.any_active) return true;
    }
    if (node.frame_state.frame_local.runtime.commands) |anims| {
        for (anims.entries[0..anims.count]) |*entry| {
            if (entry.controller.isActive()) return true;
        }
    }
    for (node.children.items) |child| {
        if (hasActiveNodeAnimations(child)) return true;
    }
    return false;
}

pub fn deferredBudgetUs(self: *const Cx) u32 {
    if (self.pressed_node != null or self.has_new_mouse_down) {
        return deferred_scheduler_mod.ACTIVE_FRAME_BUDGET_US;
    }
    if (self.focused_node == null and self.hovered_node == null) {
        return deferred_scheduler_mod.CATCH_UP_FRAME_BUDGET_US;
    }
    return deferred_scheduler_mod.NORMAL_FRAME_BUDGET_US;
}

pub fn drainDeferredWork(self: *Cx, budget_us: u32) DrainDeferredResult {
    const now_ns = currentDeferredTimeNs(self);
    const result = self.deferred_scheduler.drain(@ptrCast(self), budget_us, now_ns);
    if (result.wants_redraw) {
        self.needs_redraw = true;
    } else if (result.next_delay_ns) |delay_ns| {
        self.scheduleRedrawAfterNs(delay_ns);
    }
    return result;
}

fn currentDeferredTimeNs(self: *const Cx) u64 {
    const now = std.time.Instant.now() catch return 0;
    return switch (now.order(self.deferred_epoch)) {
        .lt => 0,
        .eq, .gt => now.since(self.deferred_epoch),
    };
}
