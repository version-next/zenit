/// AnimatedColor - 基于 Transition 的四通道颜色动画 (Premultiplied Alpha 插值)
///
/// 替代 core.AnimatedColor 的简单 lerp，使用 Transition 实现更可控的缓动。
///
/// 特性:
/// - 内部以 premultiplied alpha 空间存储/插值，消除透明色过渡时的暗色闪烁
/// - 外部 API 接收/返回 straight alpha Color，零迁移成本
/// - CSS 风格缓动函数支持
/// - 可配置持续时间
/// - 与 core.AnimatedColor 相同的 tick 签名
const std = @import("std");
const Transition = @import("transition.zig").Transition;
const TransitionConfig = @import("transition.zig").TransitionConfig;
const Easing = @import("easing.zig").Easing;
const Color = @import("../core.zig").Color;

/// AnimatedColor 配置
pub const AnimatedColorConfig = struct {
    /// 过渡持续时间 (ms)
    duration_ms: f32 = 150,
    /// 缓动函数
    easing: Easing = .ease_out_quad,
};

/// 基于 Transition 的颜色动画 (premultiplied alpha 内部表示)
pub const AnimatedColor = struct {
    /// 内部存储 premultiplied 值: pr = r * (a/255), pg = g * (a/255), pb = b * (a/255)
    pr: Transition,
    pg: Transition,
    pb: Transition,
    a: Transition,
    target: Color,

    /// tick 返回类型
    pub const TickResult = struct { color: Color, animating: bool };

    /// 默认帧间隔 (秒)，假定 60 FPS
    const default_dt: f32 = 1.0 / 60.0;

    // ---- premultiplied 转换 helpers ----

    fn toPremul(color: Color) struct { pr: f32, pg: f32, pb: f32, a: f32 } {
        const af: f32 = @floatFromInt(color.a);
        const factor = af / 255.0;
        return .{
            .pr = @as(f32, @floatFromInt(color.r)) * factor,
            .pg = @as(f32, @floatFromInt(color.g)) * factor,
            .pb = @as(f32, @floatFromInt(color.b)) * factor,
            .a = af,
        };
    }

    fn fromPremul(pr: f32, pg: f32, pb: f32, af: f32) Color {
        const a_clamped = std.math.clamp(af, 0, 255);
        if (a_clamped < 0.5) {
            // 完全透明，RGB 无意义，返回全零
            return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        }
        const inv = 255.0 / a_clamped;
        return .{
            .r = @intFromFloat(@round(std.math.clamp(pr * inv, 0, 255))),
            .g = @intFromFloat(@round(std.math.clamp(pg * inv, 0, 255))),
            .b = @intFromFloat(@round(std.math.clamp(pb * inv, 0, 255))),
            .a = @intFromFloat(@round(a_clamped)),
        };
    }

    // ---- 公开 API ----

    /// 创建 AnimatedColor (默认配置)
    pub fn init(color: Color) AnimatedColor {
        return initWithConfig(color, .{});
    }

    /// 创建 AnimatedColor (自定义配置)
    pub fn initWithConfig(color: Color, config: AnimatedColorConfig) AnimatedColor {
        const tc = TransitionConfig{
            .duration_ms = config.duration_ms,
            .easing = config.easing,
        };
        const pm = toPremul(color);
        return .{
            .pr = Transition.init(pm.pr, tc),
            .pg = Transition.init(pm.pg, tc),
            .pb = Transition.init(pm.pb, tc),
            .a = Transition.init(pm.a, tc),
            .target = color,
        };
    }

    /// 设置目标颜色 (自动开始过渡，premultiplied 空间插值)
    pub fn setTarget(self: *AnimatedColor, color: Color, now_ms: f64) void {
        if (Color.eql(self.target, color)) return;
        self.target = color;
        const pm = toPremul(color);
        self.pr.setTo(pm.pr, now_ms);
        self.pg.setTo(pm.pg, now_ms);
        self.pb.setTo(pm.pb, now_ms);
        self.a.setTo(pm.a, now_ms);
    }

    /// 立即跳到目标颜色 (跳过动画)
    pub fn setImmediate(self: *AnimatedColor, color: Color) void {
        self.target = color;
        const pm = toPremul(color);
        self.pr.setImmediate(pm.pr);
        self.pg.setImmediate(pm.pg);
        self.pb.setImmediate(pm.pb);
        self.a.setImmediate(pm.a);
    }

    /// 每帧调用，读取全局帧时间戳。
    /// 与 core.AnimatedColor.tick() 签名完全一致。
    pub fn tick(self: *AnimatedColor) TickResult {
        const render_engine = @import("../core/render_engine/mod.zig");
        return self.tickWithTime(render_engine.current_frame_time_ms);
    }

    /// 帧率无关的 tick，接受绝对时间戳 (ms)
    pub fn tickWithTime(self: *AnimatedColor, now_ms: f64) TickResult {
        self.pr.update(now_ms);
        self.pg.update(now_ms);
        self.pb.update(now_ms);
        self.a.update(now_ms);

        const animating = self.pr.isTransitioning() or
            self.pg.isTransitioning() or
            self.pb.isTransitioning() or
            self.a.isTransitioning();

        return .{
            .color = self.currentColor(),
            .animating = animating,
        };
    }

    /// 获取当前颜色 (不推进动画)
    pub fn getColor(self: *const AnimatedColor) Color {
        return self.currentColor();
    }

    /// 从 premultiplied 内部值反算 straight alpha Color
    fn currentColor(self: *const AnimatedColor) Color {
        return fromPremul(
            self.pr.getValue(),
            self.pg.getValue(),
            self.pb.getValue(),
            self.a.getValue(),
        );
    }

    /// 是否正在过渡
    pub fn isAnimating(self: *const AnimatedColor) bool {
        return self.pr.isTransitioning() or
            self.pg.isTransitioning() or
            self.pb.isTransitioning() or
            self.a.isTransitioning();
    }
};

// ========== 测试 ==========

/// 测试辅助：模拟帧推进 (默认 150ms duration, 60 FPS -> 每帧 ~16.67ms)
const test_dt_ms: f64 = 1000.0 / 60.0;

test "AnimatedColor: init" {
    const color = Color.hex(0xFF8040);
    var anim = AnimatedColor.init(color);
    const result = anim.tickWithTime(0);

    try std.testing.expect(Color.eql(result.color, color));
    try std.testing.expect(!result.animating);
}

test "AnimatedColor: setTarget starts transition" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFFFFFF);
    var anim = AnimatedColor.init(start);

    const t0: f64 = 1000.0;
    anim.setTarget(target, t0);

    // 第一帧: 应该开始动画
    const result = anim.tickWithTime(t0 + test_dt_ms);
    try std.testing.expect(result.animating);
    // 颜色应该已经开始移动 (不再是 0x000000)
    try std.testing.expect(result.color.r > 0 or result.color.g > 0 or result.color.b > 0);
}

test "AnimatedColor: tick converges to target" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFFFFFF);
    var anim = AnimatedColor.init(start);

    const t0: f64 = 1000.0;
    anim.setTarget(target, t0);

    // 运行足够多帧 (150ms duration / ~16.67ms = 9 帧, 多跑一些确保收敛)
    var t = t0;
    for (0..30) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }

    t += test_dt_ms;
    const result = anim.tickWithTime(t);
    try std.testing.expect(!result.animating);
    try std.testing.expect(Color.eql(result.color, target));
}

test "AnimatedColor: mid-flight target change" {
    const start = Color.hex(0x000000);
    const mid_target = Color.hex(0xFFFFFF);
    const final_target = Color.hex(0x808080);

    var anim = AnimatedColor.init(start);
    const t0: f64 = 1000.0;
    anim.setTarget(mid_target, t0);

    // 只跑几帧，还在过渡中
    var t = t0;
    for (0..3) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }
    try std.testing.expect(anim.isAnimating());

    // 中途切换目标
    anim.setTarget(final_target, t);
    try std.testing.expect(anim.isAnimating());

    // 运行直到收敛
    for (0..60) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }

    t += test_dt_ms;
    const result = anim.tickWithTime(t);
    try std.testing.expect(!result.animating);
    try std.testing.expect(Color.eql(result.color, final_target));
}

test "AnimatedColor: setTarget with same color is no-op" {
    const color = Color.hex(0xFF0000);
    var anim = AnimatedColor.init(color);

    anim.setTarget(color, 0);
    const result = anim.tickWithTime(test_dt_ms);
    try std.testing.expect(!result.animating);
}

test "AnimatedColor: setImmediate skips animation" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFFFFFF);
    var anim = AnimatedColor.init(start);

    anim.setImmediate(target);

    const result = anim.tickWithTime(test_dt_ms);
    try std.testing.expect(!result.animating);
    try std.testing.expect(Color.eql(result.color, target));
}

test "AnimatedColor: custom config" {
    const start = Color.hex(0x000000);
    const target = Color.hex(0xFF0000);
    var anim = AnimatedColor.initWithConfig(start, .{
        .duration_ms = 500,
        .easing = .linear,
    });

    const t0: f64 = 1000.0;
    anim.setTarget(target, t0);

    // 在 500ms linear 的半程 (15帧 ≈ 250ms) 应该约一半
    var t = t0;
    for (0..15) |_| {
        t += test_dt_ms;
        _ = anim.tickWithTime(t);
    }
    const mid = anim.getColor();
    // R 通道应该在 100-160 范围 (约 127)
    try std.testing.expect(mid.r > 80 and mid.r < 180);
}

test "AnimatedColor: transparent to opaque no dark flash" {
    // 核心场景: rgba(0,0,0,0) -> rgba(238,241,248,255) 不应出现暗色中间帧
    const transparent = Color.rgba(0, 0, 0, 0);
    const opaque_color = Color.rgba(238, 241, 248, 255);
    var anim = AnimatedColor.initWithConfig(transparent, .{
        .duration_ms = 150,
        .easing = .linear,
    });

    const t0: f64 = 1000.0;
    anim.setTarget(opaque_color, t0);

    // 检查每一帧，RGB 不应出现暗色
    var t = t0;
    for (0..12) |_| {
        t += test_dt_ms;
        const result = anim.tickWithTime(t);
        const c = result.color;
        if (c.a > 10) {
            // 当有可见 alpha 时，RGB 应接近目标色（不是黑色）
            try std.testing.expect(c.r > 180);
            try std.testing.expect(c.g > 180);
            try std.testing.expect(c.b > 190);
        }
    }
}

test "AnimatedColor: low-alpha hover to opaque active no dark flash" {
    // 场景: hover 中 rgba(0,0,0,15) -> active rgba(238,241,248,255)
    const hover_bg = Color.rgba(0, 0, 0, 15);
    const active_bg = Color.rgba(238, 241, 248, 255);
    var anim = AnimatedColor.initWithConfig(hover_bg, .{
        .duration_ms = 150,
        .easing = .linear,
    });

    const t0: f64 = 1000.0;
    anim.setTarget(active_bg, t0);

    var t = t0;
    for (0..12) |_| {
        t += test_dt_ms;
        const result = anim.tickWithTime(t);
        const c = result.color;
        if (c.a > 30) {
            // 不应出现暗色（r/g/b 不应远低于目标值）
            try std.testing.expect(c.r > 100);
            try std.testing.expect(c.g > 100);
        }
    }
}
