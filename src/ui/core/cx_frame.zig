//! Cx frame pacing: wall-time-derived frame clock (advanceFrameClock), layout entry, idle frame
//! gating (wantsFrame / hasPendingSceneWork / nextWakeDelayNs) and deferred task budget.

const std = @import("std");
const a11y_preferences = @import("../a11y/preferences.zig");
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
const cx_hover = @import("cx_hover.zig");
const cx_render = @import("cx_render.zig");
const cx_runtime_index = @import("cx_runtime_index.zig");
const debug_env = @import("debug_env.zig");
const deferred_scheduler_mod = @import("../deferred_scheduler.zig");
const layout_engine = core.layout_engine;
const renderDirtyDebugEnabled = debug_env.renderDirtyDebugEnabled;
const wantsFrameDebugEnabled = debug_env.wantsFrameDebugEnabled;

/// delta frame interval cap (seconds), see advanceFrameClock.
pub const max_frame_dt_seconds: f32 = 1.0;

pub fn advanceFrameClock(self: *Cx) void {
    const now = @import("zenit_time").Instant.now(self.io) catch return;
    // always update last_frame_instant (even idle frames record current time), so next active
    // frame's dt starts from 'now', not dumping entire idle duration into animation.
    defer self.last_frame_instant = now;

    // logic clock origin: anchored on first call (includes idle first frame, ensures epoch always
    // before any active frame).
    if (self.clock_epoch == null) self.clock_epoch = now;

    // idle frame doesn't advance logic clock: root fully clean + no overlay in/out animations + no
    // explicit redraw -> frame_time_ms frozen -> render()'s time_unchanged zero-dirty fast path
    // stays valid (else clock changes every frame, always full render, e2e query on idle gives
    // unstable frame). any active signal advances clock, drives overlay/Spring etc
    // absolute-timestamp animations.
    // A frame requested for interaction/runtime work or animation is active
    // even when paint/layout bits are clean. Otherwise its clock freezes and
    // render's cache can keep the host-requesting work alive indefinitely.
    const idle = !hasPendingSceneWork(self) and !self.needs_redraw;
    if (idle) {
        // Locked test clock with budget left but nothing animating: the granted
        // time still elapses (timers come due), in one step.
        if (self.test_frame_step_ms != null) if (self.test_clock_budget_ms) |*budget| if (budget.* > 0) {
            self.frame_time_ms += budget.*;
            budget.* = 0;
        };
        // during idle real time flows, logic clock must freeze. record this duration in pause
        // offset, else next active frame dumps entire idle into animation (overlay instant jump to
        // end).
        // A compositor sprite is an animation of this clock that keeps
        // running while the window renders nothing: the clock keeps flowing,
        // so the first frame after it hands back paints the picture the
        // compositor shows at that moment, not the one from when it took over.
        if (self.last_frame_instant) |prev| {
            if (!self.sprites.anyActive()) self.clock_paused_ns += now.since(prev);
        }
        self.frame_clock_was_idle = true;
        return;
    }
    // first frame waking from idle: since last tick is host blocking/waiting idle time, no
    // incremental animation running, can't dump as frame interval (else animation just started by
    // event skips far ahead). advance by nominal one frame.
    const resumed_from_idle = self.frame_clock_was_idle;
    self.frame_clock_was_idle = false;

    // edge-triggered consume: explicit redraw request drove this frame's clock advance, consumed
    // here. frame-active signals (anim tick / overlay tick / deferred work / events) re-set true
    // driving next frame; end of frame still false = can enter idle gating. note consume point must
    // be AFTER idle check, clearing early in frame loop freezes time this wake (time-driven overlay
    // entrance freezes at 0).
    // Every host renews declarations only when advancing/painting a fresh frame.
    // The idle cache fast path retains its last declaration and wake deadline.
    self.caret_phase_valid = false;
    self.caret_rect_count = 0;
    self.caret_shown = null;
    self.caret_rect_overflow = false;
    self.needs_redraw = false;

    if (self.test_frame_step_ms) |step| {
        // f64 throughout: a granted budget lands the clock exactly on the
        // instant it names (pixel checks compare against a flipbook sample).
        var taken: f64 = step;
        if (self.test_clock_budget_ms) |*budget| {
            taken = @min(taken, budget.*);
            budget.* -= taken;
        }
        self.frame_dt_ms = @floatCast(taken);
        self.frame_dt_seconds = @floatCast(taken / 1000);
        self.frame_time_ms += taken;
        return;
    }

    if (self.last_frame_instant) |prev| {
        const dt_ns = now.since(prev);
        const dt_s = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
        // delta dt uses real frame interval: all consumers exact on any step (spring critical
        // damping analytical, material exponential, rest by absolute time or countdown), clamping
        // to 0.1s only slows low-fps animations by 0.1/interval (software raster 2fps -> 1/5
        // speed). 1s cap only prevents anomalous stall; idle clock already frozen, doesn't
        // accumulate.
        self.frame_dt_seconds = if (resumed_from_idle) @min(dt_s, 1.0 / 60.0) else std.math.clamp(dt_s, 0.0, max_frame_dt_seconds);
        self.frame_dt_ms = self.frame_dt_seconds * 1000.0;
    } else {
        // first frame: no previous, give nominal 60fps dt.
        self.frame_dt_seconds = 1.0 / 60.0;
        self.frame_dt_ms = 1000.0 / 60.0;
    }

    // absolute clock derived from epoch, subtract cumulative idle pause. **no clamping**:
    // tween/keyframe progress by (now_ms - start_time_ms), any shortening slows animation forever.
    const since_epoch_ns = now.since(self.clock_epoch.?);
    const live_ns = since_epoch_ns -| self.clock_paused_ns;
    self.frame_time_ms = self.clock_time_offset_ms + @as(f64, @floatFromInt(live_ns)) / std.time.ns_per_ms;
}

pub fn layout(self: *Cx) void {
    defer cx_cursor.updateCursorShape(self);
    // Stage split of the renderer's layout_us (ZENIT_PERF_TRACE): layout engine + table sync vs.
    // interaction / order index rebuild. Written after perf.resetFrame below.
    var layout_engine_us: u64 = 0;
    var interaction_index_us: u64 = 0;
    var layout_ran = false;
    var index_ran = false;
    defer {
        self.perf.frame_layout_engine_us = layout_engine_us;
        self.perf.frame_interaction_index_us = interaction_index_us;
        self.perf.frame_layout_ran = @intFromBool(layout_ran);
        self.perf.frame_index_rebuild_ran = @intFromBool(index_ran);
    }
    self.text.syncLegacyMeasureHooks();
    if (self.root) |r| {
        const had_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
        const had_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction;
        layout_ran = had_dirty;
        index_ran = had_dirty or had_interaction_dirty;
        var partial_interaction_roots = PartialInteractionRoots{};
        if (had_dirty or had_interaction_dirty) {
            cx_runtime_index.collectPartialInteractionRoots(self, r, &partial_interaction_roots);
        }
        var stage_timer = @import("zenit_time").Timer.start(self.io) catch null;
        if (had_dirty) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        if (stage_timer) |*t| layout_engine_us = t.lap() / 1000;
        defer if (stage_timer) |*t| {
            interaction_index_us = t.read() / 1000;
        };
        if (had_dirty or had_interaction_dirty) {
            // OOM not swallowed: see rebuildRuntimeIndexesIfCurrentRootDirty note.
            if (r.frame_state.state_bits.dirty.runtime.subtree_dirty) {
                cx_runtime_index.rebuildRuntimeIndexesWithRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildRuntimeIndexes (frame end)");
            } else if (r.frame_state.state_bits.dirty.pipeline.subtree_order) {
                cx_runtime_index.rebuildOrderIndexesWithRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildOrderIndexes (frame end)");
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

// ---- timers (Cx.setTimer / clearTimer / fireDueTimers impl) ----

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

pub fn nextTimerDelayNs(self: *const Cx) ?u64 {
    if (self.timers.items.len == 0) return null;
    const now = currentDeferredTimeNs(self);
    var best: u64 = std.math.maxInt(u64);
    for (self.timers.items) |t| best = @min(best, t.due_ns -| now);
    return best;
}

pub fn fireDueTimers(self: *Cx) void {
    // nested call in callback: don't re-enter. re-entering treats 0-delay timer set in callback as
    // 'due on entry' and fires in callback stack; remaining timers from outer loop ok. note:
    // callback may set 0-delay timer, don't double-fire it in this round.
    if (self.firing_timers) return;
    if (self.timers.items.len == 0) return;
    self.firing_timers = true;
    defer self.firing_timers = false;
    const now = currentDeferredTimeNs(self);
    // on entry only snapshot due timer ids (this round only fires these, newly-set timers deferred
    // to next round), fetch from table before firing: earlier callback in round may clearTimer
    // timers already due (typical: callback unmounts component, cleanup clears component's timers
    // and frees context). if snapshotted and removed wholesale then called, clearTimer finds
    // nothing, cleared callback still runs with freed context. clearTimer contract is 'no callback
    // after', must hold this round.
    var due_ids: [16]u64 = undefined;
    var n: usize = 0;
    for (self.timers.items) |t| {
        if (n == due_ids.len) break;
        if (t.due_ns <= now) {
            due_ids[n] = t.id;
            n += 1;
        }
    }
    var fired: usize = 0;
    for (due_ids[0..n]) |id| {
        const t = takeTimer(self, id) orelse continue;
        fired += 1;
        t.callback(t.context);
    }
    if (fired > 0) self.needs_redraw = true;
}

fn takeTimer(self: *Cx, id: u64) ?Timer {
    for (self.timers.items, 0..) |t, i| {
        if (t.id == id) return self.timers.swapRemove(i);
    }
    return null;
}

pub fn nextWakeDelayNs(self: *const Cx) ?u64 {
    var best: ?u64 = nextTimerDelayNs(self);
    if (self.caret_phase_valid) {
        const delay = @max(0, self.caret_next_ns - @import("zenit_time").monotonicTimestamp(self.io));
        best = if (best) |b| @min(b, @as(u64, @intCast(delay))) else @intCast(delay);
    }
    if (self.next_redraw_scheduled_at) |scheduled_at| {
        if (self.next_redraw_delay_ns) |delay_ns| {
            const now = @import("zenit_time").Instant.now(self.io) catch return 0;
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
    if (!self.caret_flip_host and self.caret_phase_valid and
        @import("zenit_time").monotonicTimestamp(self.io) >= self.caret_next_ns)
        self.needs_redraw = true;
    if (self.test_force_frames) {
        if (self.root) |root| root.markSubtreeDirty();
        self.needs_redraw = true;
        return true;
    }
    const budget_left = self.test_frame_step_ms != null and (self.test_clock_budget_ms orelse 0) > 0;
    const wants = if (wantsFrameDebugEnabled()) wantsFrameDiagnosed(self) or budget_left else budget_left or self.needs_redraw or
        self.a11y_prefs_version != a11y_preferences.version() or
        hasDueTimer(self) or
        self.hasReadyWork() or
        self.hasPendingSceneWork() or
        cx_hover.pending(self);
    // host gets false, skips entire frame and blocks waiting, won't call advanceFrameClock again,
    // its idle branch unreachable at runtime. record 'entered idle' here, so next active frame's dt
    // doesn't dump blocking wait into just-event-started incremental animation.
    if (!wants) self.frame_clock_was_idle = true;
    return wants;
}

/// ZENIT_DEBUG_WANTS_FRAME=1: print wantsFrame subconditions line-by-line, locate which keeps true
/// when 'static canvas yet wants render every frame'. only when env enabled.
fn wantsFrameDiagnosed(self: *Cx) bool {
    const needs = self.needs_redraw or hasDueTimer(self);
    const ready = self.hasReadyWork();
    const scene = self.hasPendingSceneWork();
    const hover = cx_hover.pending(self);
    const want = needs or ready or scene or hover;
    if (want) {
        var buf: [512]u8 = undefined;
        var w: usize = 0;
        const append = struct {
            fn f(b: []u8, n: *usize, comptime fmt: []const u8, args: anytype) void {
                const s = std.fmt.bufPrint(b[n.*..], fmt, args) catch return;
                n.* += s.len;
            }
        }.f;
        append(&buf, &w, "[wants-frame] needs_redraw={} ready_work={} scene={} hover={}", .{ needs, ready, scene, hover });
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
                    d.pipeline.order,               d.pipeline.subtree_order,                                     d.pipeline.interaction,
                    d.pipeline.subtree_interaction, cx_runtime_index.subtreeHasLooseInteractionDirty(self, root),
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
    return !cx_render.isTreeFullyClean(self, root) or
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
    if (self.pressed_node != null or self.has_new_mouse_down or self.has_new_press_release) {
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
    const now = @import("zenit_time").Instant.now(self.io) catch return 0;
    return switch (now.order(self.deferred_epoch)) {
        .lt => 0,
        .eq, .gt => now.since(self.deferred_epoch),
    };
}
