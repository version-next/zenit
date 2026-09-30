/// Timeline — GSAP 风格时间线编排
///
/// 时间线容器，支持灵活的相对定位 (Position 参数)，
/// 统一播放控制 (play/pause/seek/reverse/timeScale)，
/// 嵌套时间线和标签定位。
///
/// 用法:
/// ```zig
/// var tl = Timeline.init(allocator);
/// defer tl.deinit();
///
/// // 编排动画
/// try tl.add(&fade_in, Position.start);           // 0s 开始
/// try tl.add(&slide_up, Position.with);            // 同时开始 ("<")
/// try tl.add(&scale_bounce, .{ .after_prev = 0.1 }); // 上一个结束后 0.1s (">+0.1")
///
/// // 标签定位
/// try tl.addLabel("phase2");
/// try tl.add(&color_change, .{ .at_label = .{ .name = "phase2", .offset = 0 } });
///
/// tl.play();
/// // 每帧:
/// if (tl.tick(dt)) requestRedraw();
/// ```
const std = @import("std");
const Scope = @import("../reactive/scope.zig").Scope;
const Allocator = std.mem.Allocator;
const ctrl_mod = @import("controller.zig");
const AnimationController = ctrl_mod.AnimationController;
const PlayState = ctrl_mod.PlayState;
const CallbackFn = ctrl_mod.CallbackFn;
const render_engine = @import("../core/render_engine/mod.zig");

/// 时间线定位参数 — GSAP 风格的相对定位
pub const Position = union(enum) {
    /// 绝对时间（秒）
    absolute: f32,
    /// 上一个条目结束后偏移 (">" 语义)
    after_prev: f32,
    /// 与上一个条目同时开始偏移 ("<" 语义)
    with_prev: f32,
    /// 标签定位 + 偏移
    at_label: struct { name: []const u8, offset: f32 = 0 },
    /// 从当前末尾偏移（默认行为）
    append: f32,

    // 常用常量
    /// 时间线起点 (0s)
    pub const start = Position{ .absolute = 0 };
    /// 上一个结束后立即开始 (">")
    pub const after = Position{ .after_prev = 0 };
    /// 与上一个同时开始 ("<")
    pub const with = Position{ .with_prev = 0 };
};

/// Stable back-link from a hook lifetime to one Timeline entry. The Timeline
/// and borrowed controller must keep stable addresses while registered.
pub const ControllerRegistration = struct {
    timeline: *Timeline,
    controller: *AnimationController,
    lifetime: *ctrl_mod.ScopeLifetime,
    previous: ?*ControllerRegistration = null,
    next: ?*ControllerRegistration = null,

    fn attach(self: *ControllerRegistration) void {
        self.lifetime.retain();
        self.next = self.lifetime.timeline_registrations;
        if (self.next) |next| next.previous = self;
        self.lifetime.timeline_registrations = self;
    }

    fn destroy(self: *ControllerRegistration) void {
        if (self.previous) |prev| prev.next = self.next else self.lifetime.timeline_registrations = self.next;
        if (self.next) |next| next.previous = self.previous;
        self.lifetime.release();
        self.timeline.allocator.destroy(self);
    }
};

// Timing identity includes cycle shape, not merely total duration: changing
// 4x1s to 2x2s must rebuild the current phase even though both last four seconds.
const ChildTiming = struct {
    kind: std.meta.Tag(AnimationController.Driver) = .tween,
    period: f32 = 0,
    delay: f32 = 0,
    loops: u32 = 1,
    yoyo: bool = false,
    spring_revision: u64 = 0,

    fn capture(ctrl: *const AnimationController) ChildTiming {
        var result = ChildTiming{ .kind = std.meta.activeTag(ctrl.driver), .loops = ctrl.loops, .yoyo = ctrl.yoyo };
        switch (ctrl.driver) {
            .tween => |tw| {
                result.period = tw.duration;
                result.delay = tw.delay;
            },
            .keyframes => |kf| result.period = kf.duration_ms,
            .spring => |sp| {
                result.period = sp.settlingDuration();
                result.spring_revision = sp.parameter_revision;
            },
        }
        return result;
    }
};

// Public parent configuration can be assigned directly, without a playback
// method bumping control_revision. Snapshot values (float bits include NaN)
// make callback/cleanup edits invalidate the old frame without persistent state.
const PlaybackConfig = struct {
    loops: u32,
    yoyo: bool,
    time_scale_bits: u32,
    direction_bits: u32,

    fn capture(timeline: *const Timeline) PlaybackConfig {
        return .{
            .loops = timeline.loops,
            .yoyo = timeline.yoyo,
            .time_scale_bits = @bitCast(timeline.time_scale),
            .direction_bits = @bitCast(timeline.direction),
        };
    }

    fn matches(self: PlaybackConfig, timeline: *const Timeline) bool {
        return std.meta.eql(self, capture(timeline));
    }
};

/// 时间线上的一个条目
pub const TimelineEntry = struct {
    /// 动画控制器
    controller: *AnimationController,
    registration: ?*ControllerRegistration = null,
    /// 在 timeline 中的起始时间（秒）
    start_time: f32,
    /// Complete configured lifetime, including a live replacement's held prefix.
    /// Unbounded entries use inf. Positions are resolved once at insertion.
    duration: f32,
    timing: ChildTiming = .{},
    /// A live Spring replacement starts at this local timeline time. Seeking
    /// before it holds the replacement's initial value; discarded history is not replayed.
    trajectory_offset: f32 = 0,
    initial_direction: f32 = 1,
    /// 是否已启动
    started: bool = false,
    last_clock_ms: f64 = 0,
    last_timeline_time: f32 = 0,
};

/// 标签
const Label = struct {
    name: []const u8,
    time: f32,
};

/// GSAP 风格时间线
pub const Timeline = struct {
    manager_registrations: ?*@import("manager.zig").Registration = null,
    lifetime_scope: ?*Scope = null,
    ticking: bool = false,
    /// Call-scoped liveness marker. deinit invalidates it before callbacks or
    /// Scope resource destruction can release this Timeline's allocation.
    tick_alive: ?*bool = null,
    disposed: bool = false,
    control_revision: u64 = 0,
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(TimelineEntry) = .{},
    labels: std.ArrayListUnmanaged(Label) = .{},

    /// 时间线总时长（自动计算）
    total_duration: f32 = 0,
    /// Invalid live configuration holds scheduling until repaired. refresh()
    /// returns the same error; no partial duration/phase update is committed.
    schedule_error: ?ScheduleError = null,
    /// Reversing an unbounded schedule captures the finite observed extent.
    /// Parent repeat/yoyo uses this window; manual forward/stop clears it.
    reverse_extent: ?f32 = null,
    /// 当前播放时间
    current_time: f32 = 0,
    pause_time_ms: f64 = 0,
    seek_on_play: bool = false,

    /// 播放状态
    play_state: PlayState = .idle,
    /// 播放方向
    direction: f32 = 1.0,
    /// 时间缩放
    time_scale: f32 = 1.0,
    /// 循环配置
    loops: u32 = 1,
    yoyo: bool = false,
    current_loop: u32 = 0,

    /// 回调
    on_complete: ?CallbackFn = null,
    on_complete_ctx: ?*anyopaque = null,

    pub const ScheduleError = error{ InvalidTimelineDuration, InvalidTimelinePosition, TimelineDisposed };

    pub fn init(allocator: Allocator) Timeline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Timeline) void {
        if (self.disposed) return;
        self.disposed = true;
        if (self.tick_alive) |alive| alive.* = false;
        self.tick_alive = null;
        self.ticking = false;
        while (self.manager_registrations) |entry| entry.manager.unregister(self);
        self.control_revision +%= 1;
        self.play_state = .idle;
        for (self.entries.items) |entry| {
            self.releaseController(entry.controller);
            if (entry.registration) |registration| registration.destroy();
        }
        self.entries.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.entries = .{};
        self.labels = .{};
    }

    // ============ 编排 ============

    /// Hook controllers automatically detach when their Scope is disposed.
    /// Other controllers are borrowed until remove() or deinit(). Keep both
    /// objects at stable addresses while linked; raw copies do not transfer links.
    /// A controller can appear in only one entry across all Timelines; conflicting
    /// borrows return ControllerAlreadyScheduled before changing either schedule.
    /// Appends during tick are visited starting with the next tick.
    /// 添加动画到时间线
    pub fn add(self: *Timeline, ctrl: *AnimationController, position: Position) !void {
        if (self.disposed or self.scopeIsRetiring()) return error.TimelineDisposed;
        if (ctrl.isScopeRetiring()) return error.AnimationDisposed;
        if (ctrl.node_owned) return error.ControllerOwnedByNode;
        if (ctrl.timeline_owner != null) return error.ControllerAlreadyScheduled;
        self.pruneRetiredControllers();
        try self.refresh();
        const position_offset = switch (position) {
            .absolute, .append, .after_prev, .with_prev => |value| value,
            .at_label => |label| label.offset,
        };
        if (!std.math.isFinite(position_offset)) return error.InvalidTimelinePosition;
        const start_time = self.resolvePosition(position);
        const duration = ctrl.timelineDuration();
        const unbounded = duration == std.math.inf(f32) and (ctrl.loops == 0 or (ctrl.driver == .spring and ctrl.driver.spring.settlingDuration() == std.math.inf(f32)));
        if ((!std.math.isFinite(duration) and !unbounded) or duration < 0) return error.InvalidTimelineDuration;
        if (!std.math.isFinite(start_time) or (!unbounded and !std.math.isFinite(start_time + duration))) return error.InvalidTimelinePosition;

        const registration: ?*ControllerRegistration = if (ctrl.scope_lifetime) |lifetime| blk: {
            const allocated = try self.allocator.create(ControllerRegistration);
            allocated.* = .{ .timeline = self, .controller = ctrl, .lifetime = lifetime };
            break :blk allocated;
        } else null;
        errdefer if (registration) |allocated| self.allocator.destroy(allocated);
        try self.entries.append(self.allocator, .{
            .controller = ctrl,
            .registration = registration,
            .start_time = start_time,
            .duration = duration,
            .initial_direction = ctrl.direction,
            .timing = ChildTiming.capture(ctrl),
        });

        ctrl.timeline_owner = self;
        ctrl.control_revision +%= 1;
        if (registration) |allocated| allocated.attach();
        self.total_duration = @max(self.total_duration, start_time + duration);
    }

    /// Detach every occurrence before releasing a borrowed controller.
    /// Removal from a callback ends the old traversal after that callback.
    pub fn remove(self: *Timeline, ctrl: *AnimationController) void {
        if (self.disposed) return;
        var i: usize = 0;
        var removed = false;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].controller == ctrl) {
                const entry = self.entries.orderedRemove(i);
                self.releaseController(entry.controller);
                if (entry.registration) |registration| registration.destroy();
                removed = true;
            } else i += 1;
        }
        if (removed) {
            self.control_revision +%= 1;
            self.total_duration = 0;
            for (self.entries.items) |entry| self.total_duration = @max(self.total_duration, entry.start_time + entry.duration);
        }
    }

    fn releaseController(self: *Timeline, ctrl: *AnimationController) void {
        if (ctrl.timeline_owner == self) {
            ctrl.timeline_owner = null;
            // A callback handoff supersedes the old driver's prepared frame.
            ctrl.control_revision +%= 1;
        }
    }

    /// 添加标签
    pub fn addLabel(self: *Timeline, name: []const u8) !void {
        if (self.disposed or self.scopeIsRetiring()) return error.TimelineDisposed;
        try self.refresh();
        if (!std.math.isFinite(self.total_duration)) return error.InvalidTimelinePosition;
        try self.labels.append(self.allocator, .{
            .name = name,
            .time = self.total_duration,
        });
    }

    const RefreshedEntry = struct { timing: ChildTiming, duration: f32, offset: f32, retargeted: bool };

    fn prepareEntry(self: *const Timeline, entry: *const TimelineEntry) ScheduleError!RefreshedEntry {
        const timing = ChildTiming.capture(entry.controller);
        const retargeted = timing.kind == .spring and timing.spring_revision != entry.timing.spring_revision;
        const offset = if (retargeted and entry.started) @max(0, self.current_time - entry.start_time) else entry.trajectory_offset;
        const child_duration = entry.controller.timelineDuration();
        const unbounded = child_duration == std.math.inf(f32) and (timing.loops == 0 or (timing.kind == .spring and timing.period == std.math.inf(f32)));
        if ((!std.math.isFinite(child_duration) and !unbounded) or child_duration < 0) return error.InvalidTimelineDuration;
        const duration = offset + child_duration;
        if (!std.math.isFinite(offset) or (!unbounded and !std.math.isFinite(duration))) return error.InvalidTimelineDuration;
        if (!std.math.isFinite(entry.start_time) or (!unbounded and !std.math.isFinite(entry.start_time + duration))) return error.InvalidTimelinePosition;
        return .{ .timing = timing, .duration = duration, .offset = offset, .retargeted = retargeted };
    }

    /// Synchronize live child timing without changing insertion-time positions
    /// or labels. Validate the whole schedule before committing any cache/phase.
    /// No allocation or user callbacks occur. Repair invalid fields then retry.
    pub fn refresh(self: *Timeline) ScheduleError!void {
        if (self.disposed or self.scopeIsRetiring()) return error.TimelineDisposed;
        self.pruneRetiredControllers();
        var total: f32 = 0;
        var changed = false;
        for (self.entries.items) |*entry| {
            const next = self.prepareEntry(entry) catch |err| {
                self.schedule_error = err;
                return err;
            };
            total = @max(total, entry.start_time + next.duration);
            changed = changed or !std.meta.eql(next.timing, entry.timing) or next.duration != entry.duration;
        }
        self.schedule_error = null;
        if (!changed) return;
        self.control_revision +%= 1;
        const now_ms = if (self.play_state == .paused) self.pause_time_ms else render_engine.current_frame_time_ms;
        for (self.entries.items) |*entry| {
            const next = self.prepareEntry(entry) catch unreachable;
            if (std.meta.eql(next.timing, entry.timing) and next.duration == entry.duration) continue;
            entry.timing = next.timing;
            entry.duration = next.duration;
            entry.trajectory_offset = next.offset;
            if (next.retargeted) entry.initial_direction = 1;
            if (entry.started) {
                const elapsed = @max(0, self.current_time - entry.start_time);
                if (entry.controller.isCompleted() and elapsed < next.duration and self.isActive()) entry.controller.play();
                seekEntry(entry, now_ms, elapsed);
                entry.last_clock_ms = now_ms;
                entry.last_timeline_time = self.current_time;
            }
        }
        self.total_duration = total;
        if (self.direction < 0 and total == std.math.inf(f32) and self.reverse_extent == null) self.reverse_extent = self.current_time;
    }

    fn syncSchedule(self: *Timeline) bool {
        self.refresh() catch return false;
        return true;
    }

    /// 单条子动画的排程是否已与其 controller 的原始字段脱节（O(1)）。
    /// prepareEntry 出错（非法时长）也算脱节，交给 syncSchedule 记 schedule_error。
    fn entryScheduleStale(self: *const Timeline, entry: *const TimelineEntry) bool {
        const next = self.prepareEntry(entry) catch return true;
        return !std.meta.eql(next.timing, entry.timing) or next.duration != entry.duration;
    }

    // ============ 播放控制 ============

    pub fn play(self: *Timeline) void {
        if (self.disposed or self.scopeIsRetiring()) return;
        self.pruneRetiredControllers();
        if (!self.syncSchedule()) return;
        if (self.play_state == .playing) return;
        if (self.play_state == .paused) {
            self.unpause();
            return;
        }
        self.control_revision +%= 1;
        if (self.play_state == .completed) self.current_loop = 0;
        if (!self.seek_on_play and (self.play_state == .completed or self.direction < 0)) {
            self.current_loop = 0;
            for (self.entries.items) |*entry| {
                entry.started = false;
                entry.controller.stop();
                recordSpringRevision(entry);
            }
            self.seek(if (self.direction < 0) self.playbackDuration() else 0);
        }
        self.seek_on_play = false;
        self.play_state = .playing;
        for (self.entries.items) |*entry| {
            if (entry.started) {
                entry.controller.play();
                anchorEntry(entry, render_engine.current_frame_time_ms, @max(0, self.current_time - entry.start_time));
                entry.last_clock_ms = render_engine.current_frame_time_ms;
                entry.last_timeline_time = self.current_time;
            }
        }
    }

    pub fn pause(self: *Timeline) void {
        if (self.disposed or self.scopeIsRetiring()) return;
        self.pruneRetiredControllers();
        if (self.play_state == .playing) {
            self.control_revision +%= 1;
            self.play_state = .paused;
            self.pause_time_ms = render_engine.current_frame_time_ms;
            for (self.entries.items) |*entry| {
                entry.controller.pause();
            }
        }
    }

    pub fn unpause(self: *Timeline) void {
        if (self.disposed or self.scopeIsRetiring()) return;
        self.pruneRetiredControllers();
        if (!self.syncSchedule()) return;
        if (self.play_state == .paused) {
            self.control_revision +%= 1;
            self.play_state = .playing;
            const paused_ms = render_engine.current_frame_time_ms - self.pause_time_ms;
            for (self.entries.items) |*entry| {
                // A child that completed before the parent pause stays at its
                // terminal sample; play() would restart it and delay the parent.
                if (entry.started and !entry.controller.isCompleted()) {
                    const was_idle = entry.controller.play_state == .idle;
                    entry.controller.play();
                    recordSpringRevision(entry);
                    if (was_idle) anchorEntry(entry, render_engine.current_frame_time_ms, @max(0, self.current_time - entry.start_time));
                    entry.last_clock_ms += paused_ms;
                }
            }
        }
    }

    pub fn reverse(self: *Timeline) void {
        if (self.disposed or self.scopeIsRetiring()) return;
        self.pruneRetiredControllers();
        if (!self.syncSchedule()) return;
        self.control_revision +%= 1;
        self.direction = -self.direction;
        self.reverse_extent = if (self.direction < 0 and !std.math.isFinite(self.total_duration)) self.current_time else null;
    }

    pub fn seek(self: *Timeline, time: f32) void {
        if (!std.math.isFinite(time)) return;
        if (self.disposed or self.scopeIsRetiring()) return;
        self.pruneRetiredControllers();
        if (!self.syncSchedule()) return;
        self.control_revision +%= 1;
        self.seek_on_play = self.play_state == .idle or self.play_state == .completed;
        self.current_time = std.math.clamp(time, 0, self.playbackDuration());
        const now_ms = if (self.play_state == .paused) self.pause_time_ms else render_engine.current_frame_time_ms;
        for (self.entries.items) |*entry| {
            const local_t = self.current_time - entry.start_time;
            entry.last_clock_ms = now_ms;
            entry.last_timeline_time = self.current_time;
            if (local_t < 0) {
                entry.started = false;
                entry.controller.stop();
                recordSpringRevision(entry);
            } else {
                entry.started = true;
                seekEntry(entry, now_ms, local_t);
                if (self.play_state == .playing) {
                    entry.controller.play();
                    anchorEntry(entry, now_ms, local_t);
                }
            }
        }
    }

    pub fn seekProgress(self: *Timeline, p: f32) void {
        if (!std.math.isFinite(p)) return;
        if (!self.syncSchedule()) return;
        const progress_value = std.math.clamp(p, 0, 1);
        const duration = self.playbackDuration();
        if (progress_value == 0) return self.seek(0);
        if (!std.math.isFinite(duration)) return;
        self.seek(progress_value * duration);
    }

    /// Ignore negative/non-finite scales. Use reverse() to change direction.
    pub fn setTimeScale(self: *Timeline, scale: f32) void {
        if (!std.math.isFinite(scale) or scale < 0) return;
        if (self.disposed or self.scopeIsRetiring()) return;
        self.pruneRetiredControllers();
        self.control_revision +%= 1;
        self.time_scale = scale;
    }

    pub fn stop(self: *Timeline) void {
        if (self.disposed or self.scopeIsRetiring()) return;
        self.pruneRetiredControllers();
        self.control_revision +%= 1;
        self.play_state = .idle;
        self.current_time = 0;
        self.current_loop = 0;
        self.seek_on_play = false;
        self.reverse_extent = null;
        self.direction = 1.0;
        for (self.entries.items) |*entry| {
            entry.started = false;
            entry.controller.stop();
            recordSpringRevision(entry);
        }
    }

    pub fn restart(self: *Timeline) void {
        self.stop();
        self.play();
    }

    // ============ 帧驱动 ============

    /// 推进时间线，返回 true 表示仍在播放
    /// dt (seconds) drives both the playhead and child clocks. Wall-clock gaps
    /// are rebased out, including pauses at the manager level.
    /// Keep non-hook timelines at a stable address through callbacks. deinit()
    /// may clear their contents during a callback; freeing self is not allowed.
    /// While registered, only the manager adapter advances this Timeline. A
    /// direct call reports active state without bypassing the manager's clock.
    pub fn tick(self: *Timeline, dt: f32) bool {
        if (self.manager_registrations != null) return !self.disposed and !self.scopeIsRetiring() and self.isActive();
        return self.tickImpl(dt);
    }

    /// Manager-only adapter. A retained registration identifies the authorized
    /// drive, including unregister/re-register during an outer callback.
    pub fn tickManaged(self: *Timeline, dt: f32, registration: *@import("manager.zig").Registration) bool {
        if (self.manager_registrations != registration) return false;
        return self.tickImpl(dt);
    }

    fn tickImpl(self: *Timeline, dt: f32) bool {
        if (self.disposed or self.scopeIsRetiring() or self.play_state != .playing) return false;
        if (self.ticking) return true;
        // Reject invalid clocks before changing the playhead, anchors or callbacks.
        // Compute in f64 so finite f32 inputs cannot overflow before validation.
        if (!std.math.isFinite(dt) or dt < 0 or !std.math.isFinite(self.time_scale) or self.time_scale < 0 or !std.math.isFinite(self.direction)) return true;
        const effective_dt = @as(f64, dt) * self.time_scale * self.direction;
        const next_time = @as(f64, self.current_time) + effective_dt;
        const max_seconds = @as(f64, std.math.floatMax(f32)) / 1000;
        if (!std.math.isFinite(next_time) or @abs(effective_dt) > max_seconds or @abs(next_time) > max_seconds) return true;
        const now_ms = render_engine.current_frame_time_ms;
        if (!std.math.isFinite(now_ms) or now_ms < 0) return true;
        self.pruneRetiredControllers();
        if (!self.syncSchedule()) return true;
        const owner = if (self.lifetime_scope) |scope| scope.owner else null;
        if (owner) |o| o.beginReactiveCallback();
        var alive = true;
        self.tick_alive = &alive;
        self.ticking = true;
        defer if (alive) {
            self.tick_alive = null;
            self.ticking = false;
        };
        _ = self.advanceTo(next_time, now_ms, true);
        // Keep the reentrancy gate through the outer disposal batch. Cleanup
        // can change playback or free this Timeline; only the stack marker may
        // be inspected until liveness is established after draining.
        if (owner) |o| o.endReactiveCallback();
        if (!alive) return false;
        return !self.scopeIsRetiring() and self.isActive();
    }

    /// The public tick retains both the reentrancy gate and Scope owner across
    /// the first boundary and at most one residual/final sample.
    fn advanceTo(self: *Timeline, next_time: f64, now_ms: f64, allow_loop: bool) bool {
        const revision = self.control_revision;

        self.current_time = @floatCast(next_time);
        const playback_end = self.playbackDuration();
        const bounded_window = self.reverse_extent != null;
        if (bounded_window) self.current_time = std.math.clamp(self.current_time, 0, playback_end);
        const reversing = self.direction < 0;
        // 反向播放钳在 0（seek 同款下界）：无界负值会让所有 entry 的
        // local_time < 0 恒判 any_active，完成检查永不可达（时间线永转）
        if (reversing and self.current_time < 0) self.current_time = 0;

        var any_active = false;

        const Guard = struct {
            timeline: *Timeline,
            revision: u64,
            playback: PlaybackConfig,
            pub fn isCurrent(g: @This()) bool {
                return !g.timeline.disposed and !g.timeline.scopeIsRetiring() and g.timeline.control_revision == g.revision and g.playback.matches(g.timeline);
            }
        };
        const guard = Guard{ .timeline = self, .revision = revision, .playback = PlaybackConfig.capture(self) };
        const initial_count = self.entries.items.len;
        var cleanup_dispatched = false;
        // 某个子动画的用户回调跑过之后，后面的子动画在被触碰前要先核对自己的排程
        //（回调可以直接改任意子动画的 duration/loops 等原始字段）。此前是每次回调后对整条
        // Timeline 做一次全表 refresh —— N 个真实 update 回调 = 每帧 N² 次 prepareEntry
        //（基准：2048 条 18.1ms/tick）。现在改成"惰性逐条核对"：只对**接下来要处理的**那一条
        // 做一次 prepareEntry 比对（O(1)），有变化才走完整 refresh（它会 bump control_revision、
        // 让本次遍历失效，与旧语义一致）；没变化就一路 O(N)。已处理过的更早子动画若被改了，
        // 下一帧开头的 syncSchedule 照旧接住（这一点与旧实现相同：它们本帧已经按旧排程发过样本）。
        var callback_seen = false;
        var i: usize = 0;
        while (i < initial_count) : (i += 1) {
            // Cleanup may have freed entries or changed playback. Check the
            // traversal before touching entries, then synchronize raw timing
            // edits made after the previous child's ordinary callback refresh.
            if (!guard.isCurrent() or !self.isActive()) return self.isActive();
            if (cleanup_dispatched) {
                cleanup_dispatched = false;
                if (!self.syncSchedule() or !guard.isCurrent()) return self.isActive();
            }
            const entry = &self.entries.items[i];
            if (entry.registration) |registration| {
                if (registration.lifetime.isRetiring()) {
                    self.remove(entry.controller);
                    return self.isActive();
                }
            }
            if (callback_seen and self.entryScheduleStale(entry)) {
                if (!self.syncSchedule() or !guard.isCurrent()) return self.isActive();
            }
            if (bounded_window and entry.start_time > playback_end) continue;
            const entry_duration = if (bounded_window) @min(entry.duration, @max(0, playback_end - entry.start_time)) else entry.duration;
            const local_time = self.current_time - entry.start_time;
            const ctrl = entry.controller;
            const child_scope = if (ctrl.scope_lifetime) |lifetime| lifetime.scope else ctrl.lifetime_scope;
            const child_owner = if (child_scope) |scope| scope.owner else null;
            if (child_owner) |o| o.beginReactiveCallback();
            defer if (child_owner) |o| {
                cleanup_dispatched = o.endReactiveCallbackObserved() or cleanup_dispatched;
            };
            if (local_time < 0 and (!reversing or !entry.started)) {
                if (!reversing) any_active = true;
                continue;
            }
            const elapsed = if (bounded_window) @min(@max(0, local_time), entry_duration) else @max(0, local_time);
            if (reversing and elapsed >= entry_duration and entry_duration > 0 and ctrl.play_state != .paused) {
                // Before crossing this child's end in reverse, hold its final
                // value without issuing a forward completion notification.
                seekEntry(entry, now_ms, entry_duration);
                ctrl.play_state = .completed;
                entry.started = true;
                entry.last_clock_ms = now_ms;
                entry.last_timeline_time = self.current_time;
                continue;
            }
            if (!entry.started) {
                entry.started = true;
                ctrl.play();
                anchorEntry(entry, now_ms, elapsed);
            } else if (reversing and ctrl.isCompleted()) {
                ctrl.play();
                recordSpringRevision(entry);
            } else if (!reversing and ctrl.isActive()) {
                const logical_ms = @as(f64, self.current_time - entry.last_timeline_time) * 1000;
                shiftClock(ctrl, now_ms - entry.last_clock_ms - logical_ms);
            }
            entry.last_clock_ms = now_ms;
            entry.last_timeline_time = self.current_time;
            if (!ctrl.isActive()) continue;
            if (reversing or entry.trajectory_offset > 0) {
                anchorEntry(entry, now_ms, elapsed);
            }
            var called_user = false;
            const controller_revision = ctrl.control_revision;
            var active = if (reversing) ctrl.tickTimelineSampleObserved(now_ms, self, true, &called_user) else ctrl.tickTimelineSampleObserved(now_ms, self, false, &called_user);
            // Never use entry after callbacks: append may have reallocated it.
            if (self.disposed or self.scopeIsRetiring()) return false;
            if (!guard.isCurrent() or !self.isActive()) return self.isActive();
            if (ctrl.isScopeRetiring()) {
                self.remove(ctrl);
                return self.isActive();
            }
            if (called_user) callback_seen = true;
            if (bounded_window and !reversing and elapsed >= entry_duration and active and ctrl.control_revision == controller_revision) {
                active = ctrl.completeTimelineTraversal(self);
                if (self.disposed or self.scopeIsRetiring()) return false;
                if (!guard.isCurrent() or !self.isActive()) return self.isActive();
                if (ctrl.isScopeRetiring()) {
                    self.remove(ctrl);
                    return self.isActive();
                }
            }
            if (bounded_window and !reversing and elapsed >= entry_duration) {
                if (!self.syncSchedule() or !guard.isCurrent()) return self.isActive();
            }
            if (reversing and ctrl.control_revision == controller_revision) {
                if (elapsed <= 0) {
                    ctrl.play_state = .completed;
                    const callback = ctrl.on_complete;
                    const callback_ctx = ctrl.on_complete_ctx;
                    ctrl.on_complete = null;
                    ctrl.on_complete_ctx = null;
                    if (callback) |cb| {
                        if (callback_ctx) |ctx| cb(ctx);
                    }
                    if (self.disposed or self.scopeIsRetiring()) return false;
                    if (!guard.isCurrent() or !self.isActive()) return self.isActive();
                    if (ctrl.isScopeRetiring()) {
                        self.remove(ctrl);
                        return self.isActive();
                    }
                    // Reverse completion is dispatched outside controller.tick.
                    // A timing edit must invalidate this traversal before another
                    // child publishes a value or notification from the old schedule.
                    if (callback != null and callback_ctx != null) {
                        if (!self.syncSchedule() or !guard.isCurrent()) return self.isActive();
                    }
                    active = ctrl.isActive();
                    if (!active) self.entries.items[i].started = false;
                } else if (ctrl.isCompleted()) {
                    // A spring may already be settled at this sampled time.
                    // Reverse completion belongs to the start boundary.
                    ctrl.play_state = .playing;
                    active = true;
                }
            }
            any_active = any_active or active;
        }

        // No child borrow remains here. Drain our outer owner boundary before
        // deciding the parent cycle; cleanup can extend timing or destroy self.
        if (!self.drainOwnerBoundary()) return false;

        // Final completion/deferred cleanup can also change live timing. Refresh
        // before consulting the prepared parent boundary, including reverse and
        // clipped-window completion callbacks dispatched outside controller.tick.
        self.pruneRetiredControllers();
        if (!guard.isCurrent() or !self.isActive()) return self.isActive();
        if (!self.syncSchedule() or !guard.isCurrent()) return self.isActive();

        // A callback can append work even beyond the old completion boundary.
        // Keep a frame scheduled without ticking new entries in this pass.
        if (self.entries.items.len > initial_count) any_active = true;

        // A surrounding host callback still owns pending cleanup. Its effects
        // must settle before a parent cycle or completion becomes irrevocable.
        if (self.ownerDisposalPending()) return true;
        if (!allow_loop) return self.isActive();

        // 完成边界：正向到 total_duration、反向退到 0（镜像检查）
        if (!reversing and self.current_time >= playback_end and !any_active) {
            return self.handleComplete(now_ms, @max(0, cycleMilliseconds(next_time) - cycleMilliseconds(playback_end)));
        }
        if (reversing and self.current_time <= 0 and !any_active) {
            return self.handleComplete(now_ms, @max(0, -cycleMilliseconds(next_time)));
        }

        if (!reversing and self.current_time < playback_end) {
            any_active = true;
        }
        if (reversing and self.current_time > 0) {
            any_active = true;
        }

        return any_active;
    }

    /// Temporarily release/reacquire only our own callback hold. The owner
    /// remains caller-owned; the Timeline can be destroyed during the drain.
    /// Reacquire even then so tickImpl can always balance its final release.
    fn drainOwnerBoundary(self: *Timeline) bool {
        const scope = self.lifetime_scope orelse return true;
        const owner = scope.owner;
        if (owner.deferred_disposals.head == null or owner.reactive_callback_depth != 1 or owner.draining_disposals) return true;
        const alive = self.tick_alive.?;
        _ = owner.endReactiveCallbackObserved();
        owner.beginReactiveCallback();
        return alive.*;
    }

    fn ownerDisposalPending(self: *const Timeline) bool {
        const scope = self.lifetime_scope orelse return false;
        return scope.owner.deferred_disposals.head != null;
    }

    /// 是否正在播放
    pub fn isActive(self: *const Timeline) bool {
        return self.play_state == .playing;
    }

    /// 是否已完成
    pub fn isCompleted(self: *const Timeline) bool {
        return self.play_state == .completed;
    }

    /// 当前进度 [0, 1]
    pub fn progress(self: *const Timeline) f32 {
        const duration = self.playbackDuration();
        if (duration <= 0) return 1.0;
        if (!std.math.isFinite(duration)) return 0;
        return std.math.clamp(self.current_time / duration, 0, 1);
    }

    // ============ 内部 ============

    fn handleComplete(self: *Timeline, now_ms: f64, overshoot: f64) bool {
        const playback_duration = self.playbackDuration();
        if (playback_duration <= 0) {
            self.current_loop = self.loops;
            self.current_time = 0;
            return self.finish();
        }
        self.current_loop +|= 1;
        if (self.loops > 0 and self.current_loop >= self.loops) {
            self.current_time = if (self.direction < 0) 0 else playback_duration;
            return self.finish();
        }

        if (self.supportsCycleCatchup()) {
            const duration = cycleMilliseconds(playback_duration);
            const extra = @floor(overshoot / duration);
            const remaining = self.loops -| self.current_loop;
            const finished = self.loops > 0 and extra >= @as(f64, @floatFromInt(remaining));
            const crossed = if (finished) @as(f64, @floatFromInt(remaining)) else extra;
            const flips = if (finished) crossed else crossed + 1;
            if (self.yoyo and @mod(flips, 2) >= 1) self.direction = -self.direction;
            const room = std.math.maxInt(u32) - self.current_loop;
            // The final sampled leg is not committed until its callbacks and
            // cleanup accept completion. Extensions or pause keep that leg live.
            self.current_loop = if (finished) self.loops -| 1 else if (crossed >= @as(f64, @floatFromInt(room))) std.math.maxInt(u32) else self.current_loop + @as(u32, @intFromFloat(crossed));
            const residual: f32 = @floatCast(@mod(overshoot, duration) / 1000);
            const target = if (finished)
                (if (self.direction < 0) @as(f32, 0) else playback_duration)
            else if (self.direction < 0) playback_duration - residual else residual;
            for (self.entries.items) |*entry| {
                entry.started = false;
                entry.controller.stop();
                recordSpringRevision(entry);
            }
            self.seek(target);
            const revision = self.control_revision;
            const playback = PlaybackConfig.capture(self);
            const entry_count = self.entries.items.len;
            const total_duration = self.total_duration;
            const alive = self.tick_alive.?;
            _ = self.advanceTo(target, now_ms, false);
            if (!alive.*) return false;
            if (self.disposed or self.scopeIsRetiring()) return false;
            if (self.control_revision != revision or !playback.matches(self) or !self.isActive()) return self.isActive();
            // add() intentionally does not invalidate the running traversal.
            // Work appended by the residual sample belongs to the current leg.
            if (self.entries.items.len != entry_count or self.total_duration != total_duration) {
                return true;
            }
            if (self.ownerDisposalPending()) {
                return true;
            }
            if (finished) {
                self.current_loop = self.loops;
                return self.finish();
            }
            return true;
        }

        // A schedule without a finite repeat window cannot skip whole cycles.
        if (self.yoyo) self.direction = -self.direction;
        for (self.entries.items) |*entry| {
            entry.started = false;
            entry.controller.stop();
            recordSpringRevision(entry);
        }
        self.seek(if (self.direction < 0) self.playbackDuration() else 0);
        return true;
    }

    // Match the f32 seconds -> milliseconds boundary used by child drivers.
    // Normalize before subtracting the first cycle so 0.9 - 0.3 stays two
    // complete 300ms cycles rather than a value slightly below the boundary.
    fn cycleMilliseconds(seconds: f64) f64 {
        const milliseconds = @as(f32, @floatCast(seconds)) * 1000;
        return if (std.math.isFinite(milliseconds)) @as(f64, milliseconds) else seconds * 1000;
    }

    fn playbackDuration(self: *const Timeline) f32 {
        return if (self.reverse_extent) |extent| @min(extent, self.total_duration) else self.total_duration;
    }

    fn supportsCycleCatchup(self: *const Timeline) bool {
        if (!std.math.isFinite(self.playbackDuration())) return false;
        for (self.entries.items) |entry| {
            if (entry.controller.loops == 0 and entry.duration > 0 and self.reverse_extent == null) return false;
        }
        return true;
    }

    fn finish(self: *Timeline) bool {
        self.play_state = .completed;
        if (self.on_complete) |cb| {
            if (self.on_complete_ctx) |ctx| cb(ctx);
        }
        return !self.disposed and !self.scopeIsRetiring() and self.isActive();
    }

    fn shiftClock(ctrl: *AnimationController, offset_ms: f64) void {
        switch (ctrl.driver) {
            .tween => |*driver| driver.start_time_ms += offset_ms,
            .spring => |*driver| driver.start_time_ms += offset_ms,
            .keyframes => |*driver| driver.start_time_ms += offset_ms,
        }
    }

    fn recordSpringRevision(entry: *TimelineEntry) void {
        if (entry.controller.driver == .spring) entry.timing.spring_revision = entry.controller.driver.spring.parameter_revision;
    }

    fn anchorEntry(entry: *TimelineEntry, now_ms: f64, elapsed: f32) void {
        seekEntry(entry, now_ms, elapsed);
    }

    fn seekEntry(entry: *TimelineEntry, now_ms: f64, elapsed: f32) void {
        entry.controller.seekTimelineTime(@max(0, elapsed - entry.trajectory_offset), now_ms, entry.initial_direction);
        recordSpringRevision(entry);
    }

    fn pruneRetiredControllers(self: *Timeline) void {
        if (self.disposed) return;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.registration) |registration| {
                if (registration.lifetime.isRetiring()) {
                    self.remove(entry.controller);
                    continue;
                }
            }
            i += 1;
        }
    }

    fn scopeIsRetiring(self: *const Timeline) bool {
        return if (self.lifetime_scope) |scope| scope.willBeDisposedAfterReactiveCallback() else false;
    }

    fn resolvePosition(self: *const Timeline, pos: Position) f32 {
        return switch (pos) {
            .absolute => |t| @max(0, t),
            .after_prev => |offset| self.lastEntryEnd() + offset,
            .with_prev => |offset| self.lastEntryStart() + offset,
            .at_label => |lbl| self.findLabel(lbl.name) + lbl.offset,
            .append => |offset| self.total_duration + offset,
        };
    }

    fn lastEntryEnd(self: *const Timeline) f32 {
        if (self.entries.items.len == 0) return 0;
        const last = self.entries.items[self.entries.items.len - 1];
        return last.start_time + last.duration;
    }

    fn lastEntryStart(self: *const Timeline) f32 {
        if (self.entries.items.len == 0) return 0;
        return self.entries.items[self.entries.items.len - 1].start_time;
    }

    fn findLabel(self: *const Timeline, name: []const u8) f32 {
        for (self.labels.items) |label| {
            if (std.mem.eql(u8, label.name, name)) return label.time;
        }
        return self.total_duration; // 找不到则返回末尾
    }
};

// ========== 测试 ==========

/// 测试辅助：设置全局模拟时间
fn setTestTime(ms: f64) void {
    render_engine.current_frame_time_ms = ms;
    render_engine.current_frame_dt_ms = 1000.0 / 60.0;
}

test "Timeline: sequence (default append)" {
    setTestTime(1000.0);
    var ctrl1 = AnimationController.initTween(.{ .from = 0, .to = 10, .duration = 0.5, .easing = .linear });
    var ctrl2 = AnimationController.initTween(.{ .from = 0, .to = 20, .duration = 0.3, .easing = .linear });

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();

    try tl.add(&ctrl1, Position.start);
    try tl.add(&ctrl2, Position.after); // 上一个结束后

    try std.testing.expectApproxEqAbs(@as(f32, 0.8), tl.total_duration, 0.001);

    tl.play();

    // 运行到完成
    const dt: f32 = 1.0 / 60.0;
    var now: f64 = 1000.0;
    var i: usize = 0;
    while (tl.isActive() and i < 100) : (i += 1) {
        now += @as(f64, dt) * 1000.0;
        setTestTime(now);
        _ = tl.tick(dt);
    }

    try std.testing.expect(tl.isCompleted());
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), ctrl1.value, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), ctrl2.value, 0.1);
}

test "Timeline: parallel (with_prev)" {
    setTestTime(1000.0);
    var ctrl1 = AnimationController.initTween(.{ .from = 0, .to = 10, .duration = 0.5, .easing = .linear });
    var ctrl2 = AnimationController.initTween(.{ .from = 0, .to = 20, .duration = 0.5, .easing = .linear });

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();

    try tl.add(&ctrl1, Position.start);
    try tl.add(&ctrl2, Position.with); // 同时开始

    // 两个同时，总时长应为 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), tl.total_duration, 0.001);

    tl.play();

    // 运行 0.25s，两个都应该在中途
    const dt: f32 = 1.0 / 60.0;
    var now: f64 = 1000.0;
    for (0..15) |_| {
        now += @as(f64, dt) * 1000.0;
        setTestTime(now);
        _ = tl.tick(dt);
    }

    try std.testing.expect(ctrl1.value > 0);
    try std.testing.expect(ctrl2.value > 0);
}

test "Timeline: stagger (incremental after_prev)" {
    var ctrl1 = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 0.2, .easing = .linear });
    var ctrl2 = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 0.2, .easing = .linear });
    var ctrl3 = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 0.2, .easing = .linear });

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();

    try tl.add(&ctrl1, Position.start);
    try tl.add(&ctrl2, .{ .after_prev = -0.1 }); // 0.1s 重叠
    try tl.add(&ctrl3, .{ .after_prev = -0.1 }); // 0.1s 重叠

    // ctrl1: 0..0.2, ctrl2: 0.1..0.3, ctrl3: 0.2..0.4
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), tl.total_duration, 0.001);
}

test "Timeline: label positioning" {
    var ctrl1 = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 0.3, .easing = .linear });
    var ctrl2 = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 0.2, .easing = .linear });

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();

    try tl.add(&ctrl1, Position.start);
    try tl.addLabel("midpoint");
    try tl.add(&ctrl2, .{ .at_label = .{ .name = "midpoint", .offset = 0.1 } });

    // ctrl2 应该在 0.3(label) + 0.1(offset) = 0.4 开始
    const entry2 = tl.entries.items[1];
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), entry2.start_time, 0.001);
}

test "Timeline: seek" {
    setTestTime(1000.0);
    var ctrl1 = AnimationController.initTween(.{ .from = 0, .to = 100, .duration = 1.0, .easing = .linear });

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();

    try tl.add(&ctrl1, Position.start);

    tl.seekProgress(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), ctrl1.value, 2.0);
}

test "Timeline: pause and unpause" {
    setTestTime(1000.0);
    var ctrl1 = AnimationController.initTween(.{ .from = 0, .to = 100, .duration = 1.0, .easing = .linear });

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();

    try tl.add(&ctrl1, Position.start);

    tl.play();
    setTestTime(1250.0);
    render_engine.current_frame_dt_ms = 250.0;
    _ = tl.tick(0.25);
    const paused_value = ctrl1.value;

    tl.pause();
    setTestTime(1750.0);
    render_engine.current_frame_dt_ms = 500.0;
    _ = tl.tick(0.5);
    try std.testing.expectEqual(paused_value, ctrl1.value);

    tl.unpause();
    setTestTime(2000.0);
    render_engine.current_frame_dt_ms = 250.0;
    _ = tl.tick(0.25);
    try std.testing.expect(ctrl1.value > paused_value);
}

test "Timeline: reverse 播到 0 必须完成，current_time 不越界为负" {
    // 回归：reverse 后 current_time 无下界递减，local_time < 0 恒把
    // any_active 钉 true，完成检查（>= total_duration and !any_active）
    // 永不可达 —— 时间线永转、重绘被钉死。
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{ .from = 0, .to = 10, .duration = 0.5, .easing = .linear });

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();
    try tl.add(&ctrl, Position.start);
    tl.play();

    // 正向推进到中途
    const dt: f32 = 1.0 / 60.0;
    var now: f64 = 1000.0;
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        now += @as(f64, dt) * 1000.0;
        setTestTime(now);
        _ = tl.tick(dt);
    }
    try std.testing.expect(tl.current_time > 0);

    // 反向：有限步数内必须停下来（旧实现永转）
    tl.reverse();
    var still_active = true;
    i = 0;
    while (still_active and i < 300) : (i += 1) {
        now += @as(f64, dt) * 1000.0;
        setTestTime(now);
        still_active = tl.tick(dt);
    }
    try std.testing.expect(!still_active);
    try std.testing.expect(tl.current_time >= 0);
}

test "Timeline: 回调改后面子动画的时长，后者在本帧被触碰前就按新排程（惰性核对）" {
    setTestTime(1000.0);
    const Edit = struct {
        var target: ?*AnimationController = null;
        var calls: usize = 0;
        fn update(_: f32, _: *anyopaque) void {
            calls += 1;
            if (target) |b| b.driver.tween.duration = 1.0;
        }
    };
    var a = AnimationController.initTween(.{ .from = 0, .to = 10, .duration = 0.5, .easing = .linear });
    var b = AnimationController.initTween(.{ .from = 0, .to = 20, .duration = 0.3, .easing = .linear });
    Edit.target = &b;
    Edit.calls = 0;
    var dummy: u8 = 0;
    a.on_update = Edit.update;
    a.on_update_ctx = @ptrCast(&dummy);

    var tl = Timeline.init(std.testing.allocator);
    defer tl.deinit();
    try tl.add(&a, Position.start);
    try tl.add(&b, Position.start); // 与 a 并行，排在 a 之后遍历
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), tl.total_duration, 0.001);
    tl.play();

    // 第一帧：a 的 update 回调把 b 的 duration 从 0.3 改成 1.0。
    // 旧实现：回调后全表 refresh；新实现：遍历到 b 之前只核对 b 这一条。两者都必须让 b 的排程在本帧就是 1.0，
    // 且时长变化使本次遍历失效（control_revision 变）——修前的"回调之后不同步"会让 b 先按 0.3 的排程走一帧。
    const revision_before = tl.control_revision;
    setTestTime(1000.0 + 16.0);
    _ = tl.tick(0.016);
    try std.testing.expect(Edit.calls >= 1);
    // 排程变化使本次遍历失效：b 在本帧**没有**被触碰（entry 的 duration/anchor 记账还是 0.3s 的旧排程，
    // 而 controller 采样读的是改后的原始字段——两者脱节的那一帧不能发样本）。
    // 负向实测：关掉惰性核对后 b 本帧被采样到 20 × 0.016 / 1.0 = 0.32；有同步（无论全表还是惰性）仍是 0。
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), b.value, 0.001);
    try std.testing.expect(!tl.entries.items[1].started);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tl.entries.items[1].duration, 0.001);
    try std.testing.expect(tl.control_revision != revision_before);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tl.total_duration, 0.001);

    // 之后正常跑完：b 走满 1.0s 才完成（不是 0.3s）
    var now: f64 = 1016.0;
    var i: usize = 0;
    while (tl.isActive() and i < 120) : (i += 1) {
        now += 16.0;
        setTestTime(now);
        _ = tl.tick(0.016);
    }
    try std.testing.expect(tl.isCompleted());
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), b.value, 0.5);
    try std.testing.expect(i >= 55);
}
