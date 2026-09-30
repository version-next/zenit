/// Physics Primitives - 可复用的物理原语
///
/// 从 ScrollArea 提取的物理模块，任何组件可以复用。
///
/// 模块:
/// - RubberBand: Apple UIScrollView 级橡皮筋阻尼
/// - FadeIndicator: 自动淡入淡出指示器 (如滚动条)
const std = @import("std");

/// Apple UIScrollView 级橡皮筋阻尼
///
/// 有理函数: f(x) = x*d*c / (d + c*x)
/// - 小位移近乎线性 (手感灵敏)
/// - 大位移渐近于 d (平滑衰减)
///
/// 用法:
/// ```zig
/// const rb = RubberBand{};
/// const visual = rb.clamp(raw_overscroll, viewport_size);
/// ```
pub const RubberBand = struct {
    /// 阻尼系数 (Apple 标准 = 0.55)
    coefficient: f32 = 0.55,

    /// 将原始输入距离映射为视觉距离 (阻尼后)
    pub fn clamp(self: RubberBand, input: f32, dimension: f32) f32 {
        const c = self.coefficient;
        const d = @max(dimension, 1.0);
        const abs_x = @abs(input);
        const clamped = (abs_x * d * c) / (d + c * abs_x);
        return if (input < 0) -clamped else clamped;
    }

    /// clamp 的精确反函数: 从视觉值恢复原始距离
    pub fn unclamp(self: RubberBand, visual: f32, dimension: f32) f32 {
        const c = self.coefficient;
        const d = @max(dimension, 1.0);
        const abs_v = @abs(visual);
        if (abs_v == 0) return 0;
        // 有理函数渐近线为 d，限制在 d*0.999 以内避免除零
        const max_visual = d * 0.999;
        const safe = @min(abs_v, max_visual);
        const denom = c * d - c * safe;
        // 分母过小时返回相对于 dimension 的合理大值
        const saturated = d * 100;
        if (denom < 1e-6) return if (visual < 0) -saturated else saturated;
        const raw = safe * d / denom;
        return if (visual < 0) -raw else raw;
    }

    /// iOS 风格增量更新: 反函数恢复 raw → 加 delta → 重新映射
    pub fn applyDelta(self: RubberBand, current_bonus: f32, raw_delta: f32, dimension: f32) f32 {
        const raw = self.unclamp(current_bonus, dimension) + raw_delta;
        return self.clamp(raw, dimension);
    }
};

/// 自动淡入淡出指示器
///
/// 活跃时显示，空闲一段时间后自动淡出。hover 时保持显示。
///
/// 用法:
/// ```zig
/// var indicator = FadeIndicator{};
/// indicator.onActivity();   // 滚动时调用
/// indicator.tick();         // 每帧调用
/// const alpha = indicator.opacity;
/// ```
pub const FadeIndicator = struct {
    /// 当前不透明度 [0, 1]
    opacity: f32 = 0,
    /// 空闲帧数计数
    idle_frames: u32 = 0,
    /// 是否被 hover (hover 时不淡出)
    hovered: bool = false,
    /// 淡出前的延迟帧数 (默认 90 帧 ≈ 1.5s @60fps)
    fade_delay: u32 = 90,
    /// 每帧淡出速度 (默认 1/36 ≈ 0.6s 完全淡出)
    fade_speed: f32 = 1.0 / 36.0,
    /// 激活时的初始不透明度
    active_opacity: f32 = 0.7,

    /// 标记活跃 (有滚动/交互时调用)
    pub fn onActivity(self: *FadeIndicator) void {
        self.idle_frames = 0;
        if (self.opacity < self.active_opacity) {
            self.opacity = self.active_opacity;
        }
    }

    /// 每帧 tick: 处理淡出逻辑
    pub fn tick(self: *FadeIndicator) void {
        // hover 时保持 100% 不透明
        if (self.hovered) {
            self.opacity = 1.0;
            self.idle_frames = 0;
            return;
        }

        if (self.opacity <= 0) return;

        self.idle_frames +|= 1; // 饱和加法防溢出
        if (self.idle_frames > self.fade_delay) {
            self.opacity -= self.fade_speed;
            if (self.opacity < 0) self.opacity = 0;
        }
    }

    /// 是否可见
    pub fn isVisible(self: *const FadeIndicator) bool {
        return self.opacity > 0;
    }
};

// ========== 测试 ==========

test "RubberBand: clamp/unclamp round-trip" {
    const rb = RubberBand{};
    const dim: f32 = 200;
    const inputs = [_]f32{ 5, 20, 50, 100, -10, -80 };
    for (inputs) |input| {
        const clamped = rb.clamp(input, dim);
        const recovered = rb.unclamp(clamped, dim);
        try std.testing.expectApproxEqAbs(input, recovered, 0.1);
    }
}

test "RubberBand: asymptotic behavior" {
    const rb = RubberBand{};
    const dim: f32 = 200;

    // 小输入: 有衰减但接近输入
    const small = rb.clamp(10, dim);
    try std.testing.expect(small > 0);
    try std.testing.expect(small <= 10.0);

    // 大输入: 渐近于 dim
    const large = rb.clamp(10000, dim);
    try std.testing.expect(large > 0);
    try std.testing.expect(large <= dim);

    // 单调递增
    try std.testing.expect(large > small);

    // 负输入对称
    const neg = rb.clamp(-50, dim);
    try std.testing.expect(neg < 0);
}

test "RubberBand: applyDelta cumulative" {
    const rb = RubberBand{};
    const dim: f32 = 200;

    // 连续越界: 阻力累积
    const first = rb.applyDelta(0, -5, dim);
    try std.testing.expect(first < 0);

    const second = rb.applyDelta(first, -5, dim);
    const second_increment = @abs(second - first);
    const first_increment = @abs(first);
    try std.testing.expect(second_increment < first_increment);
}

test "RubberBand: custom coefficient" {
    const rb = RubberBand{ .coefficient = 0.3 };
    const rb_standard = RubberBand{};
    const dim: f32 = 200;

    // 更低系数 = 更强衰减
    const custom = rb.clamp(50, dim);
    const standard = rb_standard.clamp(50, dim);
    try std.testing.expect(custom < standard);
}

test "FadeIndicator: activity triggers visibility" {
    var fi = FadeIndicator{};
    try std.testing.expect(!fi.isVisible());

    fi.onActivity();
    try std.testing.expect(fi.isVisible());
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);
}

test "FadeIndicator: fade after delay" {
    var fi = FadeIndicator{};
    fi.onActivity();

    // 延迟期内: 不淡出
    for (0..90) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);

    // 延迟后: 开始淡出
    fi.tick();
    try std.testing.expect(fi.opacity < 0.7);

    // 跑足够帧: 完全淡出
    for (0..40) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 0), fi.opacity);
    try std.testing.expect(!fi.isVisible());
}

test "FadeIndicator: hover suppresses fade" {
    var fi = FadeIndicator{};
    fi.onActivity();

    fi.hovered = true;
    fi.tick();
    try std.testing.expectEqual(@as(f32, 1.0), fi.opacity);

    // 即使超过 delay 也不淡出
    for (0..200) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 1.0), fi.opacity);
}

test "FadeIndicator: activity resets fade" {
    var fi = FadeIndicator{};
    fi.onActivity();

    // 等到开始淡出
    for (0..95) |_| fi.tick();
    try std.testing.expect(fi.opacity < 0.7);

    // 重新活跃
    fi.onActivity();
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);

    // 延迟重新开始计时
    for (0..90) |_| fi.tick();
    try std.testing.expectEqual(@as(f32, 0.7), fi.opacity);
}
