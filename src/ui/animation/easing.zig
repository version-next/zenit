/// Easing Functions
///
/// 缓动函数集合，用于控制动画的时间曲线
///
/// 基于标准 CSS easing 和 Robert Penner's easing equations
/// 支持 31 种预设 + 自定义三次贝塞尔曲线 (CSS cubic-bezier 兼容)
const std = @import("std");
const math = std.math;

/// 三次贝塞尔参数 (CSS cubic-bezier(x1, y1, x2, y2) 兼容)
pub const CubicBezierParams = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    // CSS 标准预设
    /// CSS ease: cubic-bezier(0.25, 0.1, 0.25, 1.0)
    pub const ease = CubicBezierParams{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1.0 };
    /// CSS ease-in: cubic-bezier(0.42, 0, 1, 1)
    pub const ease_in = CubicBezierParams{ .x1 = 0.42, .y1 = 0, .x2 = 1, .y2 = 1 };
    /// CSS ease-out: cubic-bezier(0, 0, 0.58, 1)
    pub const ease_out = CubicBezierParams{ .x1 = 0, .y1 = 0, .x2 = 0.58, .y2 = 1 };
    /// CSS ease-in-out: cubic-bezier(0.42, 0, 0.58, 1)
    pub const ease_in_out = CubicBezierParams{ .x1 = 0.42, .y1 = 0, .x2 = 0.58, .y2 = 1 };
    /// Motion.dev 默认
    pub const motion_default = CubicBezierParams{ .x1 = 0.22, .y1 = 1.0, .x2 = 0.36, .y2 = 1.0 };
};

/// 缓动函数类型 (tagged union: 31 个预设 + 自定义贝塞尔)
pub const Easing = union(enum) {
    // 线性
    linear,

    // 二次
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,

    // 三次
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,

    // 四次
    ease_in_quart,
    ease_out_quart,
    ease_in_out_quart,

    // 五次
    ease_in_quint,
    ease_out_quint,
    ease_in_out_quint,

    // 正弦
    ease_in_sine,
    ease_out_sine,
    ease_in_out_sine,

    // 指数
    ease_in_expo,
    ease_out_expo,
    ease_in_out_expo,

    // 圆形
    ease_in_circ,
    ease_out_circ,
    ease_in_out_circ,

    // 弹性
    ease_in_elastic,
    ease_out_elastic,
    ease_in_out_elastic,

    // 回弹
    ease_in_back,
    ease_out_back,
    ease_in_out_back,

    // 弹跳
    ease_in_bounce,
    ease_out_bounce,
    ease_in_out_bounce,

    // 自定义三次贝塞尔
    cubic_bezier: CubicBezierParams,

    /// 便捷构造: 创建自定义三次贝塞尔缓动
    pub fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32) Easing {
        return .{ .cubic_bezier = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 } };
    }

    /// 计算缓动值
    /// t: 0.0 ~ 1.0 的归一化时间
    /// 返回: 缓动后的值 (通常也在 0.0 ~ 1.0 范围，但某些缓动会超出)
    pub fn apply(self: Easing, raw_t: f32) f32 {
        const t = std.math.clamp(raw_t, 0.0, 1.0);
        return switch (self) {
            .linear => t,

            // Quad
            .ease_in_quad => t * t,
            .ease_out_quad => 1 - (1 - t) * (1 - t),
            .ease_in_out_quad => if (t < 0.5) 2 * t * t else 1 - std.math.pow(f32, -2 * t + 2, 2) / 2,

            // Cubic
            .ease_in_cubic => t * t * t,
            .ease_out_cubic => 1 - std.math.pow(f32, 1 - t, 3),
            .ease_in_out_cubic => if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 3) / 2,

            // Quart
            .ease_in_quart => t * t * t * t,
            .ease_out_quart => 1 - std.math.pow(f32, 1 - t, 4),
            .ease_in_out_quart => if (t < 0.5) 8 * t * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 4) / 2,

            // Quint
            .ease_in_quint => t * t * t * t * t,
            .ease_out_quint => 1 - std.math.pow(f32, 1 - t, 5),
            .ease_in_out_quint => if (t < 0.5) 16 * t * t * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 5) / 2,

            // Sine
            .ease_in_sine => 1 - @cos((t * math.pi) / 2),
            .ease_out_sine => @sin((t * math.pi) / 2),
            .ease_in_out_sine => -(@cos(math.pi * t) - 1) / 2,

            // Expo
            .ease_in_expo => if (t == 0) 0 else std.math.pow(f32, 2, 10 * t - 10),
            .ease_out_expo => if (t == 1) 1 else 1 - std.math.pow(f32, 2, -10 * t),
            .ease_in_out_expo => if (t == 0) 0 else if (t == 1) 1 else if (t < 0.5) std.math.pow(f32, 2, 20 * t - 10) / 2 else (2 - std.math.pow(f32, 2, -20 * t + 10)) / 2,

            // Circ
            .ease_in_circ => 1 - @sqrt(1 - std.math.pow(f32, t, 2)),
            .ease_out_circ => @sqrt(1 - std.math.pow(f32, t - 1, 2)),
            .ease_in_out_circ => if (t < 0.5) (1 - @sqrt(1 - std.math.pow(f32, 2 * t, 2))) / 2 else (@sqrt(1 - std.math.pow(f32, -2 * t + 2, 2)) + 1) / 2,

            // Elastic
            .ease_in_elastic => elasticIn(t),
            .ease_out_elastic => elasticOut(t),
            .ease_in_out_elastic => elasticInOut(t),

            // Back
            .ease_in_back => backIn(t),
            .ease_out_back => backOut(t),
            .ease_in_out_back => backInOut(t),

            // Bounce
            .ease_in_bounce => 1 - bounceOut(1 - t),
            .ease_out_bounce => bounceOut(t),
            .ease_in_out_bounce => if (t < 0.5) (1 - bounceOut(1 - 2 * t)) / 2 else (1 + bounceOut(2 * t - 1)) / 2,

            // CubicBezier
            .cubic_bezier => |params| solveCubicBezier(params, t),
        };
    }
};

// ========== 三次贝塞尔求解 ==========
// 算法来源: WebKit/Chromium 的 UnitBezier 实现
// 给定 x 坐标 (时间进度)，求解对应的 y 坐标 (缓动值)
// 使用 Newton-Raphson 迭代 + 二分法回退

fn solveCubicBezier(params: CubicBezierParams, x: f32) f32 {
    // 边界情况
    if (x <= 0) return 0;
    if (x >= 1) return 1;

    // 贝塞尔曲线的多项式系数
    // B(t) = 3*(1-t)^2*t*P1 + 3*(1-t)*t^2*P2 + t^3
    // 展开后: B(t) = (3*P1)*t + (-6*P1 + 3*P2)*t^2 + (3*P1 - 3*P2 + 1)*t^3
    const cx = 3.0 * params.x1;
    const bx = 3.0 * (params.x2 - params.x1) - cx;
    const ax = 1.0 - cx - bx;

    const cy = 3.0 * params.y1;
    const by = 3.0 * (params.y2 - params.y1) - cy;
    const ay = 1.0 - cy - by;

    // 求解 x(t) = x 的 t 值
    var t = x; // 初始猜测

    // Newton-Raphson 迭代 (最多 8 次)
    for (0..8) |_| {
        const x_val = ((ax * t + bx) * t + cx) * t - x;
        if (@abs(x_val) < 1e-6) break;

        const dx = (3.0 * ax * t + 2.0 * bx) * t + cx;
        if (@abs(dx) < 1e-6) break;

        t -= x_val / dx;
    }

    // 如果 Newton 收敛失败，使用二分法回退
    t = std.math.clamp(t, 0.0, 1.0);
    var x_val = ((ax * t + bx) * t + cx) * t;
    if (@abs(x_val - x) > 1e-4) {
        // 二分法
        var lo: f32 = 0.0;
        var hi: f32 = 1.0;
        t = x;
        for (0..20) |_| {
            x_val = ((ax * t + bx) * t + cx) * t;
            if (@abs(x_val - x) < 1e-6) break;
            if (x_val < x) {
                lo = t;
            } else {
                hi = t;
            }
            t = (lo + hi) / 2.0;
        }
    }

    // 用 t 计算 y(t)
    return ((ay * t + by) * t + cy) * t;
}

// ========== 预设缓动辅助函数 ==========

const c1: f32 = 1.70158;
const c2: f32 = c1 * 1.525;
const c3: f32 = c1 + 1;
const c4: f32 = (2.0 * math.pi) / 3.0;
const c5: f32 = (2.0 * math.pi) / 4.5;

fn elasticIn(t: f32) f32 {
    if (t == 0) return 0;
    if (t == 1) return 1;
    return -std.math.pow(f32, 2, 10 * t - 10) * @sin((t * 10 - 10.75) * c4);
}

fn elasticOut(t: f32) f32 {
    if (t == 0) return 0;
    if (t == 1) return 1;
    return std.math.pow(f32, 2, -10 * t) * @sin((t * 10 - 0.75) * c4) + 1;
}

fn elasticInOut(t: f32) f32 {
    if (t == 0) return 0;
    if (t == 1) return 1;
    if (t < 0.5) {
        return -(std.math.pow(f32, 2, 20 * t - 10) * @sin((20 * t - 11.125) * c5)) / 2;
    }
    return (std.math.pow(f32, 2, -20 * t + 10) * @sin((20 * t - 11.125) * c5)) / 2 + 1;
}

fn backIn(t: f32) f32 {
    return c3 * t * t * t - c1 * t * t;
}

fn backOut(t: f32) f32 {
    return 1 + c3 * std.math.pow(f32, t - 1, 3) + c1 * std.math.pow(f32, t - 1, 2);
}

fn backInOut(t: f32) f32 {
    if (t < 0.5) {
        return (std.math.pow(f32, 2 * t, 2) * ((c2 + 1) * 2 * t - c2)) / 2;
    }
    return (std.math.pow(f32, 2 * t - 2, 2) * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2;
}

fn bounceOut(t: f32) f32 {
    const n1: f32 = 7.5625;
    const d1: f32 = 2.75;

    if (t < 1 / d1) {
        return n1 * t * t;
    } else if (t < 2 / d1) {
        const t2 = t - 1.5 / d1;
        return n1 * t2 * t2 + 0.75;
    } else if (t < 2.5 / d1) {
        const t2 = t - 2.25 / d1;
        return n1 * t2 * t2 + 0.9375;
    } else {
        const t2 = t - 2.625 / d1;
        return n1 * t2 * t2 + 0.984375;
    }
}

// ========== 测试 ==========

test "Easing: linear" {
    const e: Easing = .linear;
    try std.testing.expectEqual(@as(f32, 0.0), e.apply(0.0));
    try std.testing.expectEqual(@as(f32, 0.5), e.apply(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), e.apply(1.0));
}

test "Easing: ease_out_quad" {
    const e: Easing = .ease_out_quad;
    const result = e.apply(0.5);
    try std.testing.expect(result > 0.5); // ease out 应该比线性快
    try std.testing.expectEqual(@as(f32, 1.0), e.apply(1.0));
}

test "Easing: ease_in_quad" {
    const e: Easing = .ease_in_quad;
    const result = e.apply(0.5);
    try std.testing.expect(result < 0.5); // ease in 应该比线性慢
}

test "Easing: ease_in_out_cubic" {
    const e: Easing = .ease_in_out_cubic;
    try std.testing.expectEqual(@as(f32, 0.0), e.apply(0.0));
    try std.testing.expectEqual(@as(f32, 0.5), e.apply(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), e.apply(1.0));
}

test "Easing: bounce" {
    const e: Easing = .ease_out_bounce;
    const result = e.apply(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.001);
}

test "Easing: elastic" {
    const e: Easing = .ease_out_elastic;
    const result = e.apply(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.001);
}

test "CubicBezier: linear (0, 0, 1, 1)" {
    const linear_bezier = Easing.cubicBezier(0, 0, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), linear_bezier.apply(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), linear_bezier.apply(0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), linear_bezier.apply(1.0), 0.001);
}

test "CubicBezier: CSS ease (0.25, 0.1, 0.25, 1.0)" {
    const ease = Easing{ .cubic_bezier = CubicBezierParams.ease };
    // CSS ease 在 t=0.5 时 y > 0.5 (减速曲线)
    const mid = ease.apply(0.5);
    try std.testing.expect(mid > 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ease.apply(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease.apply(1.0), 0.001);
}

test "CubicBezier: CSS ease-in-out (0.42, 0, 0.58, 1)" {
    const ease_io = Easing{ .cubic_bezier = CubicBezierParams.ease_in_out };
    // ease-in-out 在 t=0.5 时 y ≈ 0.5 (对称)
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), ease_io.apply(0.5), 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ease_io.apply(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease_io.apply(1.0), 0.001);
}

test "CubicBezier: boundary values" {
    const bezier = Easing.cubicBezier(0.4, 0.0, 0.2, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bezier.apply(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bezier.apply(1.0), 0.001);
    // 中间值应该单调递增
    const v1 = bezier.apply(0.25);
    const v2 = bezier.apply(0.5);
    const v3 = bezier.apply(0.75);
    try std.testing.expect(v1 < v2);
    try std.testing.expect(v2 < v3);
}

test "CubicBezier: cubicBezier convenience" {
    const e = Easing.cubicBezier(0.25, 0.1, 0.25, 1.0);
    const result = e.apply(0.5);
    try std.testing.expect(result > 0.0);
    try std.testing.expect(result < 1.0);
}
