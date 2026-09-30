/// AnimationManager — 全局动画管理器
///
/// 管理全局活跃的 Timeline，提供全局 pause/timeScale 控制。
///
/// 现状：**尚未接入 Cx**——不存在 `cx.animation_manager` 字段，框架渲染
/// 循环不会自动 tick，仓内也没有生产代码注册 Timeline。使用者需要自行
/// 持有 manager 实例并每帧调用 tick(dt)。
///
/// 注册关系是借用：不拥有 Timeline，但 Timeline.deinit 会自动解除所有
/// manager 连接。manager.deinit 同样先解除连接。两者注册期间须地址稳定，
/// 释放 Timeline 前必须调用 deinit，不能直接释放裸指针。
///
/// 用法:
/// ```zig
/// var mgr = AnimationManager.init(allocator);
/// defer mgr.deinit();
///
/// try mgr.register(&my_timeline);
/// // 每帧: 使用者自行驱动
/// _ = mgr.tick(dt);
///
/// // 全局控制
/// mgr.pauseAll();
/// mgr.setGlobalTimeScale(0.5); // 慢动作
/// mgr.resumeAll();
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const Timeline = @import("timeline.zig").Timeline;
const render_engine = @import("../core/render_engine/mod.zig");

/// Stable registration shared by the manager and Timeline lifetime lists.
/// The current tick temporarily retains its record across callback removal.
pub const Registration = struct {
    manager: *AnimationManager,
    timeline: *Timeline,
    previous: ?*Registration = null,
    next: ?*Registration = null,
    timeline_previous: ?*Registration = null,
    timeline_next: ?*Registration = null,
    linked: bool = true,
    in_tick: bool = false,
};

pub const AnimationManager = struct {
    allocator: Allocator,
    first: ?*Registration = null,
    last: ?*Registration = null,
    registration_count: usize = 0,
    tick_cursor: ?*Registration = null,
    ticking: bool = false,
    disposed: bool = false,
    global_time_scale: f32 = 1.0,
    global_paused: bool = false,

    pub fn init(allocator: Allocator) AnimationManager {
        return .{ .allocator = allocator };
    }

    /// May clear registrations during a callback; self must remain alive until
    /// the outer tick returns. Explicit reinitialization is only safe after it.
    pub fn deinit(self: *AnimationManager) void {
        if (self.disposed) return;
        self.disposed = true;
        while (self.first) |entry| self.unlink(entry);
    }

    /// One Timeline has one manager clock. Another manager must first release
    /// its registration; conflicts return TimelineAlreadyManaged. Registration
    /// is atomic on allocation failure; same-manager duplicates allocate nothing.
    pub fn register(self: *AnimationManager, tl: *Timeline) !void {
        if (self.disposed) return error.ManagerDisposed;
        if (tl.disposed) return error.TimelineDisposed;
        if (tl.lifetime_scope) |scope| {
            if (scope.willBeDisposedAfterReactiveCallback()) return error.TimelineDisposed;
        }
        if (tl.manager_registrations) |entry| {
            if (entry.manager == self) return;
            return error.TimelineAlreadyManaged;
        }
        const entry = try self.allocator.create(Registration);
        entry.* = .{
            .manager = self,
            .timeline = tl,
            .previous = self.last,
            .timeline_next = tl.manager_registrations,
        };
        if (self.last) |last| last.next = entry else self.first = entry;
        self.last = entry;
        if (tl.manager_registrations) |head| head.timeline_previous = entry;
        tl.manager_registrations = entry;
        tl.control_revision +%= 1;
        self.registration_count += 1;
    }

    pub fn unregister(self: *AnimationManager, tl: *Timeline) void {
        // Search our own list: an unknown pointer need not be dereferenced.
        var current = self.first;
        while (current) |entry| : (current = entry.next) {
            if (entry.timeline == tl) {
                self.unlink(entry);
                return;
            }
        }
    }

    fn unlink(self: *AnimationManager, entry: *Registration) void {
        if (!entry.linked) return;
        if (self.tick_cursor == entry) self.tick_cursor = entry.previous;
        if (entry.previous) |previous| previous.next = entry.next else self.first = entry.next;
        if (entry.next) |next| next.previous = entry.previous else self.last = entry.previous;
        if (entry.timeline_previous) |previous| previous.timeline_next = entry.timeline_next else entry.timeline.manager_registrations = entry.timeline_next;
        if (entry.timeline_next) |next| next.timeline_previous = entry.timeline_previous;
        entry.linked = false;
        entry.timeline.control_revision +%= 1;
        self.registration_count -= 1;
        if (!entry.in_tick) self.allocator.destroy(entry);
    }

    /// Visits registrations present at entry, in reverse registration order.
    /// Callback additions/re-registrations wait until the next tick. Unlinking
    /// adjusts the cursor before freeing records, including from Timeline.deinit.
    pub fn tick(self: *AnimationManager, dt: f32) bool {
        if (self.disposed or self.global_paused) return false;
        if (self.ticking) return self.hasActive();
        if (!std.math.isFinite(dt) or dt < 0 or !std.math.isFinite(self.global_time_scale) or self.global_time_scale < 0) return self.hasActive();
        const scaled = @as(f64, dt) * self.global_time_scale;
        if (scaled > std.math.floatMax(f32)) return self.hasActive();
        self.ticking = true;
        defer {
            self.ticking = false;
            self.tick_cursor = null;
        }
        const effective_dt: f32 = @floatCast(scaled);
        self.tick_cursor = self.last;
        while (self.tick_cursor) |entry| {
            self.tick_cursor = entry.previous;
            entry.in_tick = true;
            _ = entry.timeline.tickManaged(effective_dt, entry);
            // Timeline.deinit may have unlinked this retained record and freed
            // the Timeline. Only linked records still permit Timeline access.
            if (entry.linked and entry.timeline.isCompleted()) self.unlink(entry);
            entry.in_tick = false;
            if (!entry.linked) self.allocator.destroy(entry);
            if (self.disposed or self.global_paused) return false;
        }
        return self.hasActive();
    }

    fn hasActive(self: *const AnimationManager) bool {
        var current = self.first;
        while (current) |entry| : (current = entry.next) {
            if (entry.timeline.lifetime_scope) |scope| {
                if (scope.willBeDisposedAfterReactiveCallback()) continue;
            }
            if (entry.timeline.isActive()) return true;
        }
        return false;
    }

    pub fn pauseAll(self: *AnimationManager) void {
        self.global_paused = true;
    }

    pub fn resumeAll(self: *AnimationManager) void {
        self.global_paused = false;
    }

    /// Ignore negative/non-finite scales; reverse is a Timeline operation.
    pub fn setGlobalTimeScale(self: *AnimationManager, scale: f32) void {
        if (!std.math.isFinite(scale) or scale < 0) return;
        self.global_time_scale = scale;
    }

    /// Registered timeline count, including individually paused/idle entries.
    pub fn activeCount(self: *const AnimationManager) usize {
        return self.registration_count;
    }
};

// ========== 测试 ==========

/// 测试辅助：设置全局模拟时间
fn setTestTime(ms: f64) void {
    render_engine.current_frame_time_ms = ms;
    render_engine.current_frame_dt_ms = 1000.0 / 60.0;
}

test "AnimationManager: basic lifecycle" {
    const ctrl_mod = @import("controller.zig");

    setTestTime(1000.0);
    var ctrl1 = ctrl_mod.AnimationController.initTween(.{
        .from = 0,
        .to = 1,
        .duration = 0.2,
        .easing = .linear,
    });

    var tl = @import("timeline.zig").Timeline.init(std.testing.allocator);
    defer tl.deinit();
    try tl.add(&ctrl1, .start);

    var mgr = AnimationManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.register(&tl);
    try std.testing.expectEqual(@as(usize, 1), mgr.activeCount());

    tl.play();

    // tick 到完成
    const dt: f32 = 1.0 / 60.0;
    var now: f64 = 1000.0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        now += @as(f64, dt) * 1000.0;
        setTestTime(now);
        if (!mgr.tick(dt)) break;
    }

    // 完成后自动移除
    try std.testing.expectEqual(@as(usize, 0), mgr.activeCount());
}

test "AnimationManager: global pause" {
    const ctrl_mod = @import("controller.zig");

    setTestTime(1000.0);
    var ctrl1 = ctrl_mod.AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 1.0,
        .easing = .linear,
    });

    var tl = @import("timeline.zig").Timeline.init(std.testing.allocator);
    defer tl.deinit();
    try tl.add(&ctrl1, .start);

    var mgr = AnimationManager.init(std.testing.allocator);
    defer mgr.deinit();
    try mgr.register(&tl);
    tl.play();

    setTestTime(1250.0);
    render_engine.current_frame_dt_ms = 250.0;
    _ = mgr.tick(0.25);
    const value_before = ctrl1.value;

    mgr.pauseAll();
    setTestTime(1750.0);
    render_engine.current_frame_dt_ms = 500.0;
    _ = mgr.tick(0.5);
    try std.testing.expectEqual(value_before, ctrl1.value); // 暂停期间不变

    mgr.resumeAll();
    setTestTime(2000.0);
    render_engine.current_frame_dt_ms = 250.0;
    _ = mgr.tick(0.25);
    try std.testing.expect(ctrl1.value > value_before); // 恢复后继续
}
