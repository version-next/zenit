/// Transition
///
/// CSS 风格的过渡动画，自动检测值变化并创建动画
///
/// 特性:
/// - 自动过渡: 设置新值时自动开始动画
/// - 可配置属性: 持续时间、缓动、延迟
/// - 可中断: 新值到来时平滑过渡到新目标
const std = @import("std");
const Easing = @import("easing.zig").Easing;
const AnimationState = @import("mod.zig").AnimationState;

/// Transition 配置
pub const TransitionConfig = struct {
    /// 持续时间 (ms)
    duration_ms: f32 = 200,
    /// 延迟 (ms)
    delay_ms: f32 = 0,
    /// 缓动函数
    easing: Easing = .ease_out_quad,
    /// 更新回调
    on_update: ?*const fn (f32, *anyopaque) void = null,
    /// 完成回调
    on_complete: ?*const fn (*anyopaque) void = null,
    /// 回调上下文
    context: ?*anyopaque = null,
};

/// CSS 风格过渡
pub const Transition = struct {
    config: TransitionConfig,
    current_value: f32,
    target_value: f32,
    start_value: f32,
    start_time_ms: f64 = 0,
    state: AnimationState = .completed, // 初始为完成状态

    /// 创建 Transition
    pub fn init(initial_value: f32, config: TransitionConfig) Transition {
        return Transition{
            .config = config,
            .current_value = initial_value,
            .target_value = initial_value,
            .start_value = initial_value,
        };
    }

    /// Builder 风格创建
    pub fn create(initial_value: f32) TransitionBuilder {
        return TransitionBuilder{
            .initial = initial_value,
            .config = .{},
        };
    }

    /// 设置新的目标值 (自动开始过渡)
    pub fn setTo(self: *Transition, value: f32, now_ms: f64) void {
        // 使用相对+绝对混合阈值，避免大值范围下误判为"无变化"
        const delta = @abs(value - self.target_value);
        const scale = @max(@abs(self.target_value), 1.0);
        if (delta / scale < 1e-5) {
            return; // 值没有显著变化
        }

        self.target_value = value;
        self.start_value = self.current_value;
        self.start_time_ms = now_ms;
        self.state = .running;
    }

    /// 立即设置值 (跳过动画)
    pub fn setImmediate(self: *Transition, value: f32) void {
        self.current_value = value;
        self.target_value = value;
        self.start_value = value;
        self.state = .completed;
    }

    /// 更新过渡 (每帧调用，传入绝对时间戳 ms)
    pub fn update(self: *Transition, now_ms: f64) void {
        if (self.state != .running) return;

        const elapsed = @as(f32, @floatCast(now_ms - self.start_time_ms));

        // 检查延迟
        if (elapsed < self.config.delay_ms) {
            return;
        }

        const active_time = elapsed - self.config.delay_ms;
        // duration_ms <= 0 时直接完成，避免除零
        const progress = if (self.config.duration_ms <= 0)
            @as(f32, 1.0)
        else
            std.math.clamp(active_time / self.config.duration_ms, 0.0, 1.0);

        // 应用缓动
        const eased = self.config.easing.apply(progress);

        // 插值
        self.current_value = self.start_value + (self.target_value - self.start_value) * eased;

        // 调用更新回调
        if (self.config.on_update) |callback| {
            if (self.config.context) |ctx| {
                callback(self.current_value, ctx);
            }
        }

        // 检查完成
        if (progress >= 1.0) {
            self.current_value = self.target_value;
            self.state = .completed;

            if (self.config.on_complete) |callback| {
                if (self.config.context) |ctx| {
                    callback(ctx);
                }
            }
        }
    }

    /// 获取当前值
    pub fn getValue(self: *const Transition) f32 {
        return self.current_value;
    }

    /// 获取目标值
    pub fn getTarget(self: *const Transition) f32 {
        return self.target_value;
    }

    /// 是否正在过渡
    pub fn isTransitioning(self: *const Transition) bool {
        return self.state == .running;
    }
};

/// Transition Builder
pub const TransitionBuilder = struct {
    initial: f32,
    config: TransitionConfig,

    pub fn duration_ms(self: TransitionBuilder, ms: f32) TransitionBuilder {
        var new = self;
        new.config.duration_ms = ms;
        return new;
    }

    pub fn delay_ms(self: TransitionBuilder, ms: f32) TransitionBuilder {
        var new = self;
        new.config.delay_ms = ms;
        return new;
    }

    pub fn easing(self: TransitionBuilder, e: Easing) TransitionBuilder {
        var new = self;
        new.config.easing = e;
        return new;
    }

    pub fn onUpdate(self: TransitionBuilder, callback: *const fn (f32, *anyopaque) void, context: *anyopaque) TransitionBuilder {
        var new = self;
        new.config.on_update = callback;
        new.config.context = context;
        return new;
    }

    pub fn onComplete(self: TransitionBuilder, callback: *const fn (*anyopaque) void, context: *anyopaque) TransitionBuilder {
        var new = self;
        new.config.on_complete = callback;
        new.config.context = context;
        return new;
    }

    pub fn build(self: TransitionBuilder) Transition {
        return Transition.init(self.initial, self.config);
    }
};

// ========== 测试 ==========

test "Transition: no change" {
    var trans = Transition.create(50.0)
        .duration_ms(300)
        .build();

    // 初始状态不应该正在过渡
    try std.testing.expect(!trans.isTransitioning());
    try std.testing.expectEqual(@as(f32, 50.0), trans.getValue());
}

test "Transition: basic" {
    var trans = Transition.create(0.0)
        .duration_ms(1000)
        .easing(.linear)
        .build();

    const t0: f64 = 1000.0; // 起始时间戳
    trans.setTo(100.0, t0);
    try std.testing.expect(trans.isTransitioning());

    // 半程 (t0 + 500ms)
    trans.update(t0 + 500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), trans.getValue(), 0.1);

    // 完成 (t0 + 1000ms)
    trans.update(t0 + 1000.0);
    try std.testing.expect(!trans.isTransitioning());
    try std.testing.expectEqual(@as(f32, 100.0), trans.getValue());
}

test "Transition: interruption" {
    var trans = Transition.create(0.0)
        .duration_ms(1000)
        .easing(.linear)
        .build();

    const t0: f64 = 1000.0;
    trans.setTo(100.0, t0);
    trans.update(t0 + 500.0); // 到达 50

    // 中途改变目标 (t1 = t0 + 500)
    const t1: f64 = t0 + 500.0;
    trans.setTo(0.0, t1);

    // 应该从当前位置 (约50) 开始过渡到 0
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), trans.getValue(), 0.1);

    // 完成 (t1 + 1000ms)
    trans.update(t1 + 1000.0);
    try std.testing.expectEqual(@as(f32, 0.0), trans.getValue());
}

test "Transition: immediate" {
    var trans = Transition.create(0.0)
        .duration_ms(1000)
        .build();

    trans.setImmediate(100.0);

    try std.testing.expect(!trans.isTransitioning());
    try std.testing.expectEqual(@as(f32, 100.0), trans.getValue());
}

test "Transition: callback" {
    const TestState = struct {
        update_count: u32 = 0,
        completed: bool = false,
    };
    var state = TestState{};

    var trans = Transition.create(0.0)
        .duration_ms(500)
        .onUpdate(struct {
            fn handler(_: f32, ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.update_count += 1;
            }
        }.handler, &state)
        .onComplete(struct {
            fn handler(ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.completed = true;
            }
        }.handler, &state)
        .build();

    const t0: f64 = 1000.0;
    trans.setTo(10.0, t0);

    // 多次更新 (每 100ms)
    trans.update(t0 + 100.0);
    trans.update(t0 + 200.0);
    trans.update(t0 + 300.0);
    trans.update(t0 + 400.0);
    trans.update(t0 + 500.0);

    try std.testing.expect(state.update_count >= 4);
    try std.testing.expect(state.completed);
}
