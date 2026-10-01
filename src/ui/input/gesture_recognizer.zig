//! Gesture Recognizer, Phase 6 手势仲裁层
//!
//! 通用的"识别器状态机"：tap / drag / long_press / triple_click / pinch / pan
//! 都用同一套生命周期管理。
//!
//! v0.6 §2.3 接入状态: GestureArena 已实装但 **dispatcher 0 caller**,
//! event_dispatcher.mouse_{down,move,up} 暂未 feed 到这里；input/state.zig
//! 仍跑自己的 click_count / drag_anchor 实现。完整接入 (Node.on_gesture slot +
//! input 组件迁移) 留 v0.6 §2.3 dedicated session 推。
//!
//! 设计参照：
//! - UIKit UIGestureRecognizer（state machine: possible / began / changed / ended / failed / cancelled）
//! - Android GestureDetector
//! - Flutter GestureRecognizer + GestureArenaManager
//!
//! 历史债避免：
//! - **不**在 event_dispatcher 内嵌每种手势识别（现状 click/double_click 这样做，扩展难）
//! - **不**让识别器之间隐式 priority（手势仲裁是显式 requireFailure 关系）
//! - **不**给识别器持 *Node（用 ElementId 跨帧安全）
//!
//! 状态机（UIKit 风格）：
//!     possible ──┬─-> began ─-> changed* ─-> ended
//!                │                        ↓
//!                └──-> failed              cancelled
//!
//! - possible：等待识别条件满足（touchDown 时进入）
//! - began：识别条件已满足（如 long_press 持续 500ms 后）
//! - changed：处于识别中且参数更新（drag 移动中）
//! - ended：自然结束（touch up）
//! - failed：识别条件不满足（如 tap 期间手指移动超阈值）
//! - cancelled：外部取消（系统级中断）

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("../core/element_id.zig");

pub const ElementId = element_id_mod.ElementId;

pub const GestureState = enum(u8) {
    possible,
    began,
    changed,
    ended,
    failed,
    cancelled,
};

pub const GestureKind = enum(u8) {
    tap,
    double_tap,
    triple_tap,
    long_press,
    pan, // 拖拽
    pinch, // 双指缩放
    rotation,
    fling, // 抛掷（pan 结束时速度 > 阈值）
};

/// 单次手势事件回调上下文
pub const GestureEvent = struct {
    kind: GestureKind,
    state: GestureState,
    target: ElementId,
    /// 起点（possible/began 时设置）
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    /// 当前点
    current_x: f32 = 0,
    current_y: f32 = 0,
    /// 速度（pan/fling）
    velocity_x: f32 = 0,
    velocity_y: f32 = 0,
    /// 双指距离（pinch）
    pinch_scale: f32 = 1.0,
    /// 旋转弧度（rotation）
    rotation_rad: f32 = 0,
    /// click 计数（tap/double_tap/triple_tap 共用）
    click_count: u8 = 1,
};

pub const GestureCallback = *const fn (event: GestureEvent, ctx: *anyopaque) void;

/// 一个识别器配置 + 当前状态
pub const Recognizer = struct {
    kind: GestureKind,
    /// 哪个 element 上挂这个识别器
    target: ElementId,
    /// 当前状态
    state: GestureState = .possible,
    /// 用户配置参数
    config: Config = .{},
    /// 触发回调
    callback: ?GestureCallback = null,
    /// 用户上下文
    ctx: ?*anyopaque = null,

    /// 内部状态字段
    started_ns: i128 = 0,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    current_x: f32 = 0,
    current_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_t_ns: i128 = 0,
    velocity_x: f32 = 0,
    velocity_y: f32 = 0,
    click_count: u8 = 0,
    /// 上一次 tap 抬起的时刻；multi_tap_interval_ms 超时判定用（0 = 从未 tap）
    last_tap_ns: i128 = 0,
    /// 被某个 recognizer 失败后才能成功（requireFailure 关系）；NULL = 无依赖
    require_failure_of: u32 = std.math.maxInt(u32),

    pub const Config = struct {
        /// tap：移动超此距离则 failed
        tap_max_movement_px: f32 = 8.0,
        /// long_press：持续超此时间触发 began
        long_press_min_duration_ms: u32 = 500,
        /// pan：移动超此距离触发 began（区分 pan vs tap）
        pan_min_movement_px: f32 = 10.0,
        /// double_tap：两次 tap 间隔上限
        multi_tap_interval_ms: u32 = 450,
        /// fling：松手时速度超此值触发
        fling_min_velocity_px_per_s: f32 = 300,
    };
};

/// 多识别器仲裁器：管理一组 recognizer 在同一个 touch 序列上的协调。
/// 简化版：所有 recognizer 都收到事件；每个独立维护 state；
/// requireFailure 关系：A.require_failure_of = B 表示 A 只在 B failed 后才能 began。
pub const GestureArena = struct {
    allocator: std.mem.Allocator,
    recognizers: std.ArrayListUnmanaged(Recognizer),

    pub fn init(allocator: std.mem.Allocator) GestureArena {
        return .{ .allocator = allocator, .recognizers = .{} };
    }

    pub fn deinit(self: *GestureArena) void {
        self.recognizers.deinit(self.allocator);
        self.* = undefined;
    }

    /// 添加一个识别器，返回索引（用于 requireFailure 引用）
    pub fn addRecognizer(self: *GestureArena, r: Recognizer) !u32 {
        const idx: u32 = @intCast(self.recognizers.items.len);
        try self.recognizers.append(self.allocator, r);
        return idx;
    }

    /// 设置 a 必须等 b 失败后才能成功
    pub fn requireFailure(self: *GestureArena, a: u32, b: u32) void {
        if (a >= self.recognizers.items.len) return;
        self.recognizers.items[a].require_failure_of = b;
    }

    /// 重置所有 recognizer 到 possible（新 touch 序列开始）。
    /// click_count / last_tap_ns 刻意保留：double/triple_tap 的计数必须跨
    /// touch 序列存活（宿主每次 mouse-down 都会 reset），过期由 onTouchUp
    /// 按 multi_tap_interval_ms 判定，此前 reset 清零计数使多击从不可达。
    pub fn reset(self: *GestureArena) void {
        for (self.recognizers.items) |*r| {
            r.state = .possible;
            r.velocity_x = 0;
            r.velocity_y = 0;
            // 归零到"未 touchDown"哨兵：否则 tick 会拿上个序列的陈旧时戳
            // 判定 long_press（down 之前的 tick 也在跑）
            r.started_ns = 0;
        }
    }

    /// 接收 touchDown 事件
    pub fn onTouchDown(self: *GestureArena, x: f32, y: f32, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state != .possible) continue;
            r.started_ns = now_ns;
            r.origin_x = x;
            r.origin_y = y;
            r.current_x = x;
            r.current_y = y;
            r.last_x = x;
            r.last_y = y;
            r.last_t_ns = now_ns;
        }
    }

    /// 接收 touchMove 事件
    pub fn onTouchMove(self: *GestureArena, x: f32, y: f32, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state == .ended or r.state == .failed or r.state == .cancelled) continue;

            const dx = x - r.origin_x;
            const dy = y - r.origin_y;
            const dist_sq = dx * dx + dy * dy;

            // 速度估算（last point -> current）
            const dt_s = @as(f32, @floatFromInt(now_ns - r.last_t_ns)) / @as(f32, std.time.ns_per_s);
            if (dt_s > 0) {
                r.velocity_x = (x - r.last_x) / dt_s;
                r.velocity_y = (y - r.last_y) / dt_s;
            }
            r.last_x = x;
            r.last_y = y;
            r.last_t_ns = now_ns;
            r.current_x = x;
            r.current_y = y;

            switch (r.kind) {
                .tap, .double_tap, .triple_tap => {
                    // 移动超阈值 -> 失败
                    const max_d = r.config.tap_max_movement_px;
                    if (dist_sq > max_d * max_d) {
                        r.state = .failed;
                        emit(r, .failed);
                    }
                },
                .pan => {
                    if (r.state == .possible) {
                        const min_d = r.config.pan_min_movement_px;
                        if (dist_sq > min_d * min_d) {
                            // 检查 requireFailure
                            if (r.require_failure_of != std.math.maxInt(u32)) {
                                const dep_idx = r.require_failure_of;
                                if (dep_idx < self.recognizers.items.len) {
                                    if (self.recognizers.items[dep_idx].state != .failed) continue;
                                }
                            }
                            r.state = .began;
                            emit(r, .began);
                        }
                    } else if (r.state == .began or r.state == .changed) {
                        r.state = .changed;
                        emit(r, .changed);
                    }
                },
                .long_press => {
                    // 移动超阈值 -> 失败
                    const max_d = r.config.tap_max_movement_px;
                    if (dist_sq > max_d * max_d) {
                        r.state = .failed;
                        emit(r, .failed);
                    } else if (r.state == .began or r.state == .changed) {
                        r.state = .changed;
                        emit(r, .changed);
                    }
                },
                else => {},
            }
        }
    }

    /// 接收 touchUp 事件
    pub fn onTouchUp(self: *GestureArena, x: f32, y: f32, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state == .ended or r.state == .failed or r.state == .cancelled) continue;
            r.current_x = x;
            r.current_y = y;

            switch (r.kind) {
                .tap, .double_tap, .triple_tap => {
                    if (r.state == .possible) {
                        // 超过多击间隔的历史计数作废（本次算新的第一击）。
                        // 此前 now_ns 被 `_ = now_ns` 丢弃，两击相隔 10 秒
                        // 也算 double_tap。
                        const interval_ns: i128 = @as(i128, r.config.multi_tap_interval_ms) * std.time.ns_per_ms;
                        if (r.last_tap_ns != 0 and now_ns - r.last_tap_ns > interval_ns) {
                            r.click_count = 0;
                        }
                        r.click_count += 1;
                        r.last_tap_ns = now_ns;
                        const expected: u8 = switch (r.kind) {
                            .tap => 1,
                            .double_tap => 2,
                            .triple_tap => 3,
                            else => unreachable,
                        };
                        if (r.click_count >= expected) {
                            r.state = .ended;
                            emit(r, .ended);
                            r.click_count = 0;
                        }
                        // 否则等下一次 tap
                    }
                },
                .pan => {
                    if (r.state == .began or r.state == .changed) {
                        r.state = .ended;
                        emit(r, .ended);
                    } else {
                        r.state = .failed;
                    }
                },
                .long_press => {
                    if (r.state == .began or r.state == .changed) {
                        r.state = .ended;
                        emit(r, .ended);
                    } else {
                        r.state = .failed;
                    }
                },
                else => {},
            }
        }
    }

    /// 系统级中断（窗口失焦 / 会话取消）：进行中的手势一律转 cancelled。
    /// 此前 .cancelled 只被读从未被写，中断后识别器卡在 began/changed。
    pub fn onTouchCancel(self: *GestureArena, now_ns: i128) void {
        _ = now_ns;
        for (self.recognizers.items) |*r| {
            switch (r.state) {
                .possible, .began, .changed => {
                    // possible 尚未识别成功，静默转 cancelled 不发事件；
                    // began/changed 已对外宣布开始，必须补一个 cancelled 收尾
                    const announced = r.state != .possible;
                    r.state = .cancelled;
                    if (announced) emit(r, .cancelled);
                },
                .ended, .failed, .cancelled => {},
            }
            r.started_ns = 0;
        }
    }

    /// tick 用于检查时间相关识别（long_press）。caller 每帧调用一次。
    pub fn tick(self: *GestureArena, now_ns: i128) void {
        for (self.recognizers.items) |*r| {
            if (r.state != .possible) continue;
            if (r.kind == .long_press) {
                // started_ns == 0 是"本序列尚未 touchDown"的哨兵（默认值/reset 值）,
                // caller 用 epoch 时戳每帧 tick，此时 elapsed 会是 ~5.7e13 ms，
                // 远超 u32；负 elapsed 则来自时钟回拨/乱序。两者都不构成"按住"。
                if (r.started_ns == 0) continue;
                const elapsed_ns = now_ns - r.started_ns;
                if (elapsed_ns < 0) continue;
                const elapsed_ms: u32 = @intCast(@min(
                    @divTrunc(elapsed_ns, std.time.ns_per_ms),
                    std.math.maxInt(u32),
                ));
                if (elapsed_ms >= r.config.long_press_min_duration_ms) {
                    if (r.require_failure_of != std.math.maxInt(u32)) {
                        const dep_idx = r.require_failure_of;
                        if (dep_idx < self.recognizers.items.len) {
                            if (self.recognizers.items[dep_idx].state != .failed) continue;
                        }
                    }
                    r.state = .began;
                    emit(r, .began);
                }
            }
        }
    }
};

fn emit(r: *Recognizer, state: GestureState) void {
    if (r.callback) |cb| {
        const event = GestureEvent{
            .kind = r.kind,
            .state = state,
            .target = r.target,
            .origin_x = r.origin_x,
            .origin_y = r.origin_y,
            .current_x = r.current_x,
            .current_y = r.current_y,
            .velocity_x = r.velocity_x,
            .velocity_y = r.velocity_y,
            .click_count = r.click_count,
        };
        cb(event, r.ctx orelse undefined);
    }
}

// ============================================================================
// Tests
// ============================================================================

const TestSink = struct {
    events: std.ArrayListUnmanaged(GestureEvent) = .{},
    allocator: std.mem.Allocator,

    fn cb(event: GestureEvent, ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.events.append(self.allocator, event) catch {};
    }

    fn deinit(self: *TestSink) void {
        self.events.deinit(self.allocator);
    }
};

test "GestureArena: tap recognized on quick down/up without movement" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchUp(51, 51, 1_000_000); // 1ms 后
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(GestureKind.tap, sink.events.items[0].kind);
    try testing.expectEqual(GestureState.ended, sink.events.items[0].state);
}

test "GestureArena: tap fails when movement exceeds threshold" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .tap_max_movement_px = 8 },
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchMove(100, 100, 1_000_000); // 移动 70px ≫ 8px
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(GestureState.failed, sink.events.items[0].state);
}

test "GestureArena: pan recognized after sufficient movement" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .pan,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .pan_min_movement_px = 10 },
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchMove(70, 70, 1_000_000); // 移动 ~28px > 10px
    try testing.expect(sink.events.items.len >= 1);
    try testing.expectEqual(GestureKind.pan, sink.events.items[0].kind);
    try testing.expectEqual(GestureState.began, sink.events.items[0].state);

    arena.onTouchMove(100, 100, 2_000_000);
    // 又一次 changed
    try testing.expect(sink.events.items.len >= 2);

    arena.onTouchUp(120, 120, 3_000_000);
    // ended
    const last = sink.events.items[sink.events.items.len - 1];
    try testing.expectEqual(GestureState.ended, last.state);
}

test "GestureArena: long_press triggers via tick" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .long_press,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .long_press_min_duration_ms = 500 },
    });

    // down 时间戳用非零值：started_ns == 0 是"尚未 touchDown"的哨兵
    arena.onTouchDown(50, 50, 1 * std.time.ns_per_ms);
    // 600ms 后 tick
    arena.tick(601 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(GestureKind.long_press, sink.events.items[0].kind);
    try testing.expectEqual(GestureState.began, sink.events.items[0].state);
}

test "GestureArena: tick before any touch must not panic on epoch timestamps" {
    // 回归：core.zig 每帧用 std.time.nanoTimestamp()（epoch，~1.8e18 ns）tick。
    // long_press 注册后、首次 touchDown 之前 started_ns 是默认 0，
    // elapsed_ms ≈ 5.7e13 远超 u32，旧实现 @intCast 首帧即 panic。
    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .long_press,
        .target = .{ .index = 1, .generation = 0 },
    });

    arena.tick(std.time.nanoTimestamp());
    // 没按过就不该触发
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);
}

test "GestureArena: tick tolerates clock going backwards and reset clears started_ns" {
    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .long_press,
        .target = .{ .index = 1, .generation = 0 },
        .config = .{ .long_press_min_duration_ms = 500 },
    });

    arena.onTouchDown(50, 50, 1_000 * std.time.ns_per_ms);
    // 时钟回拨（乱序时戳）：负 elapsed 不得 panic、不得触发
    arena.tick(900 * std.time.ns_per_ms);
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);

    // reset 后 started_ns 归零：新序列开始前的 tick 不得用陈旧时戳触发
    arena.reset();
    arena.tick(1_000_000 * std.time.ns_per_ms);
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);
}

test "GestureArena: requireFailure relation - tap blocks pan from triggering immediately" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    const tap_idx = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .tap_max_movement_px = 8 },
    });
    const pan_idx = try arena.addRecognizer(.{
        .kind = .pan,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .pan_min_movement_px = 10 },
    });
    arena.requireFailure(pan_idx, tap_idx);

    arena.onTouchDown(50, 50, 0);
    arena.onTouchMove(60, 60, 1_000_000); // 移动 ~14px：tap fail，pan 可以触发

    // tap 应失败
    var saw_tap_fail = false;
    var saw_pan_began = false;
    for (sink.events.items) |e| {
        if (e.kind == .tap and e.state == .failed) saw_tap_fail = true;
        if (e.kind == .pan and e.state == .began) saw_pan_began = true;
    }
    try testing.expect(saw_tap_fail);
    try testing.expect(saw_pan_began);
}

test "GestureArena: reset returns all recognizers to possible" {
    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
    });

    arena.onTouchDown(50, 50, 0);
    arena.onTouchUp(51, 51, 1_000_000);
    try testing.expectEqual(GestureState.ended, arena.recognizers.items[0].state);

    arena.reset();
    try testing.expectEqual(GestureState.possible, arena.recognizers.items[0].state);
}

test "GestureArena: double_tap 超过 multi_tap_interval_ms 不得触发" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .double_tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .multi_tap_interval_ms = 450 },
    });

    // 第一击
    arena.onTouchDown(50, 50, 1_000 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 1_050 * std.time.ns_per_ms);
    // 第二击在 10 秒后，远超 450ms 间隔，必须视为新的第一击
    arena.reset();
    arena.onTouchDown(50, 50, 11_000 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 11_050 * std.time.ns_per_ms);

    for (sink.events.items) |e| {
        try testing.expect(!(e.kind == .double_tap and e.state == .ended));
    }
}

test "GestureArena: double_tap 间隔内两击触发" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .double_tap,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .multi_tap_interval_ms = 450 },
    });

    arena.onTouchDown(50, 50, 1_000 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 1_050 * std.time.ns_per_ms);
    // 新序列（宿主每次 down 都 reset），但在间隔内，计数必须跨 reset 存活
    arena.reset();
    arena.onTouchDown(50, 50, 1_200 * std.time.ns_per_ms);
    arena.onTouchUp(50, 50, 1_250 * std.time.ns_per_ms);

    var fired = false;
    for (sink.events.items) |e| {
        if (e.kind == .double_tap and e.state == .ended) fired = true;
    }
    try testing.expect(fired);
}

test "GestureArena: onTouchCancel 把进行中的手势转 cancelled" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var arena = GestureArena.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.addRecognizer(.{
        .kind = .pan,
        .target = .{ .index = 1, .generation = 0 },
        .callback = &TestSink.cb,
        .ctx = &sink,
        .config = .{ .pan_min_movement_px = 10 },
    });

    arena.onTouchDown(50, 50, 1_000_000);
    arena.onTouchMove(80, 80, 2_000_000); // 移动 ~42px → pan began
    arena.onTouchCancel(3_000_000);

    try testing.expectEqual(GestureState.cancelled, arena.recognizers.items[0].state);
    var saw_cancel = false;
    for (sink.events.items) |e| {
        if (e.kind == .pan and e.state == .cancelled) saw_cancel = true;
    }
    try testing.expect(saw_cancel);

    // cancel 后 tick/move 不得复活
    arena.onTouchMove(90, 90, 4_000_000);
    try testing.expectEqual(GestureState.cancelled, arena.recognizers.items[0].state);
}
