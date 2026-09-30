/// AnimatedValue
///
/// 可动画的值包装器，提供多种动画模式
///
/// 特性:
/// - 统一接口: 可以选择 tween 或 spring 动画
/// - 自动插值: 设置值时自动开始动画
/// - Signal 风格: 可与响应式系统集成
const std = @import("std");
const Tween = @import("tween.zig").Tween;
const TweenConfig = @import("tween.zig").TweenConfig;
const Spring = @import("spring.zig").Spring;
const SpringConfig = @import("spring.zig").SpringConfig;
const SpringPreset = @import("spring.zig").SpringPreset;
const Transition = @import("transition.zig").Transition;
const TransitionConfig = @import("transition.zig").TransitionConfig;
const Easing = @import("easing.zig").Easing;

/// 动画类型
pub const AnimationType = enum {
    tween,
    spring,
    transition,
    none, // 立即更新，无动画
};

/// AnimatedValue 配置
pub const AnimatedValueConfig = struct {
    /// 动画类型
    animation_type: AnimationType = .transition,
    /// Tween 配置
    tween_config: TweenConfig = .{},
    /// Spring 配置
    spring_config: SpringConfig = SpringPreset.default,
    /// Transition 配置
    transition_config: TransitionConfig = .{},
};

/// 可动画的值
pub const AnimatedValue = struct {
    current_value: f32,
    target_value: f32,

    /// 内部动画状态 — tagged union，只存储活跃的动画类型
    animator: Animator,

    const Animator = union(AnimationType) {
        tween: Tween,
        spring: Spring,
        transition: Transition,
        none: void,
    };

    /// 创建 AnimatedValue
    pub fn init(initial_value: f32, config: AnimatedValueConfig) AnimatedValue {
        return AnimatedValue{
            .current_value = initial_value,
            .target_value = initial_value,
            .animator = switch (config.animation_type) {
                .tween => .{ .tween = Tween.init(.{ .from = initial_value, .to = initial_value, .duration = config.tween_config.duration, .easing = config.tween_config.easing }) },
                .spring => .{ .spring = Spring.init(initial_value, initial_value, config.spring_config) },
                .transition => .{ .transition = Transition.init(initial_value, config.transition_config) },
                .none => .{ .none = {} },
            },
        };
    }

    /// Builder 风格创建
    pub fn create(initial_value: f32) AnimatedValueBuilder {
        return AnimatedValueBuilder{ .initial = initial_value };
    }

    /// 设置目标值 (触发动画)
    pub fn setTo(self: *AnimatedValue, value: f32, now_ms: f64) void {
        // 使用相对+绝对混合阈值
        const delta = @abs(value - self.target_value);
        const scale = @max(@abs(self.target_value), 1.0);
        if (delta / scale < 1e-5) {
            return;
        }

        self.target_value = value;

        switch (self.animator) {
            .tween => |*tw| {
                tw.config.from = self.current_value;
                tw.config.to = value;
                tw.start();
            },
            .spring => |*sp| {
                sp.from = self.current_value;
                sp.setTarget(value);
            },
            .transition => |*tr| {
                tr.setTo(value, now_ms);
            },
            .none => {
                self.current_value = value;
            },
        }
    }

    /// 立即设置值
    pub fn setImmediate(self: *AnimatedValue, value: f32) void {
        self.current_value = value;
        self.target_value = value;
        switch (self.animator) {
            .tween => |*tw| tw.reset(),
            .spring => |*sp| sp.reset(),
            .transition => |*tr| tr.setImmediate(value),
            .none => {},
        }
    }

    /// 更新动画 (now_ms: 绝对时间戳 ms; dt_s 已无消费者，保留签名兼容)
    pub fn update(self: *AnimatedValue, now_ms: f64, dt_s: f32) void {
        _ = dt_s;
        switch (self.animator) {
            .tween => |*tw| {
                // Tween.update 吃绝对 ms 时间戳（与 spring/transition 同轨）。
                // 曾误传 dt_s（~0.016）：elapsed = 0.016 − 绝对ms 恒为巨大负数，
                // 被 delay 判断挡住 → tween 永远冻在 from。
                tw.update(now_ms);
                self.current_value = tw.getValue();
            },
            .spring => |*sp| {
                sp.update(now_ms);
                self.current_value = sp.getValue();
            },
            .transition => |*tr| {
                tr.update(now_ms);
                self.current_value = tr.getValue();
            },
            .none => {},
        }
    }

    /// 获取当前值
    pub fn get(self: *const AnimatedValue) f32 {
        return self.current_value;
    }

    /// 获取目标值
    pub fn getTarget(self: *const AnimatedValue) f32 {
        return self.target_value;
    }

    /// 是否正在动画
    pub fn isAnimating(self: *const AnimatedValue) bool {
        return switch (self.animator) {
            .tween => |tw| tw.isRunning(),
            .spring => |sp| sp.isRunning(),
            .transition => |tr| tr.isTransitioning(),
            .none => false,
        };
    }
};

/// AnimatedValue Builder
pub const AnimatedValueBuilder = struct {
    initial: f32,
    config: AnimatedValueConfig = .{},

    pub fn useSpring(self: AnimatedValueBuilder) AnimatedValueBuilder {
        var new = self;
        new.config.animation_type = .spring;
        return new;
    }

    pub fn useTransition(self: AnimatedValueBuilder) AnimatedValueBuilder {
        var new = self;
        new.config.animation_type = .transition;
        return new;
    }

    pub fn noAnimation(self: AnimatedValueBuilder) AnimatedValueBuilder {
        var new = self;
        new.config.animation_type = .none;
        return new;
    }

    pub fn duration_ms(self: AnimatedValueBuilder, ms: f32) AnimatedValueBuilder {
        var new = self;
        new.config.tween_config.duration = ms / 1000.0;
        new.config.transition_config.duration_ms = ms;
        return new;
    }

    pub fn easing(self: AnimatedValueBuilder, e: Easing) AnimatedValueBuilder {
        var new = self;
        new.config.tween_config.easing = e;
        new.config.transition_config.easing = e;
        return new;
    }

    pub fn stiffness(self: AnimatedValueBuilder, s: f32) AnimatedValueBuilder {
        var new = self;
        new.config.spring_config.stiffness = s;
        return new;
    }

    pub fn damping(self: AnimatedValueBuilder, d: f32) AnimatedValueBuilder {
        var new = self;
        new.config.spring_config.damping = d;
        return new;
    }

    pub fn build(self: AnimatedValueBuilder) AnimatedValue {
        return AnimatedValue.init(self.initial, self.config);
    }
};

// ========== 便捷函数 ==========

/// 创建一个使用 transition 的动画值
pub fn animated(initial: f32) AnimatedValue {
    return AnimatedValue.create(initial).useTransition().build();
}

/// 创建一个使用 spring 的动画值
pub fn springValue(initial: f32) AnimatedValue {
    return AnimatedValue.create(initial).useSpring().build();
}

// ========== 测试 ==========

test "AnimatedValue: transition mode" {
    var value = AnimatedValue.create(0.0)
        .useTransition()
        .duration_ms(500)
        .easing(.linear)
        .build();

    try std.testing.expectEqual(@as(f32, 0.0), value.get());

    const t0: f64 = 1000.0;
    value.setTo(100.0, t0);
    try std.testing.expect(value.isAnimating());

    value.update(t0 + 250.0, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), value.get(), 1.0);

    value.update(t0 + 500.0, 0.25);
    try std.testing.expect(!value.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), value.get());
}

test "AnimatedValue: spring mode" {
    var value = AnimatedValue.create(0.0)
        .useSpring()
        .stiffness(500)
        .damping(50)
        .build();

    const dt_s: f32 = 1.0 / 60.0;
    value.setTo(10.0, 0);
    try std.testing.expect(value.isAnimating());

    // 运行足够多的帧
    var i: usize = 0;
    var t: f64 = 0;
    while (i < 300 and value.isAnimating()) : (i += 1) {
        t += @as(f64, dt_s) * 1000.0;
        value.update(t, dt_s);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 10.0), value.get(), 0.01);
}

test "AnimatedValue: no animation" {
    var value = AnimatedValue.create(0.0)
        .noAnimation()
        .build();

    value.setTo(100.0, 0);
    try std.testing.expect(!value.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), value.get());
}

test "AnimatedValue: immediate set" {
    var value = AnimatedValue.create(0.0)
        .useTransition()
        .duration_ms(1000)
        .build();

    const t0: f64 = 1000.0;
    value.setTo(50.0, t0);
    value.update(t0 + 100.0, 0.1); // 开始动画

    // 立即设置
    value.setImmediate(100.0);
    try std.testing.expect(!value.isAnimating());
    try std.testing.expectEqual(@as(f32, 100.0), value.get());
}

test "animated convenience function" {
    var value = animated(0.0);
    value.setTo(10.0, 0);
    try std.testing.expect(value.isAnimating());
}

test "springValue convenience function" {
    var value = springValue(0.0);
    value.setTo(10.0, 0);
    try std.testing.expect(value.isAnimating());
}

test "AnimatedValue: tween mode 真的会动（now_ms 轨道回归）" {
    // 回归：update 曾把 dt_s（帧间隔秒）当绝对 ms 传给 Tween，
    // elapsed 恒为巨大负数被 delay 挡住 —— tween 永远冻在 from。
    // 该模式当前无 builder 入口（零消费者），直接 init 构造。
    var value = AnimatedValue.init(0.0, .{
        .animation_type = .tween,
        .tween_config = .{ .from = 0, .to = 100, .duration = 0.5, .easing = .linear },
    });

    // Tween.start 锚定全局帧时钟——显式设定，消除测试顺序依赖
    const t0: f64 = 1000.0;
    @import("../core/render_engine/mod.zig").current_frame_time_ms = t0;
    value.setTo(100.0, t0);
    // 250ms 后应约走到一半，绝不允许还钉在 0
    value.update(t0 + 250.0, 1.0 / 60.0);
    try std.testing.expect(value.get() > 10.0);
    // 跑满后到达 to
    value.update(t0 + 600.0, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), value.get(), 0.5);
}
