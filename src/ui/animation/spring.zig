/// Spring Animation — 解析解 (Closed-form Damped Harmonic Oscillator)
///
/// 阻尼谐振子方程: m·x'' + d·x' + k·x = 0
/// 其中 x 是相对于 target 的位移。
///
/// 解析解按阻尼比 ζ = d / (2·√(k·m)) 分三种情况:
/// - 欠阻尼 (ζ < 1): x(t) = e^(-ζω₀t) · (A·cos(ωd·t) + B·sin(ωd·t))
/// - 临界阻尼 (ζ = 1): x(t) = (A + B·t) · e^(-ω₀·t)
/// - 过阻尼 (ζ > 1): x(t) = C₁·e^(r₁·t) + C₂·e^(r₂·t)
///
/// 优势（相比欧拉积分）:
/// - 零累积误差：从绝对时间直接算出精确位置
/// - 帧率无关：跳帧后依然精确
/// - 可 seek 到任意时刻
/// - pause/resume 天然支持
const std = @import("std");
const math = std.math;
const AnimationState = @import("mod.zig").AnimationState;
const render_engine = @import("../core/render_engine/mod.zig");

/// Spring 配置
pub const SpringConfig = struct {
    /// 弹簧刚度 (推荐 100-500)
    stiffness: f32 = 170.0,
    /// 阻尼系数 (推荐 10-40)
    damping: f32 = 26.0,
    /// 质量 (推荐 1-5)
    mass: f32 = 1.0,
    /// 初始速度
    initial_velocity: f32 = 0.0,
    /// 位移静止阈值 (px)
    rest_displacement: f32 = 0.01,
    /// 速度静止阈值 (px/s)
    rest_velocity: f32 = 0.01,
    /// 完成回调
    on_complete: ?*const fn (*anyopaque) void = null,
    /// 更新回调
    on_update: ?*const fn (f32, *anyopaque) void = null,
    /// 回调上下文
    context: ?*anyopaque = null,
};

/// 预设配置
pub const SpringPreset = struct {
    /// 默认 (平衡的弹性)
    pub const default = SpringConfig{ .stiffness = 170, .damping = 26 };
    /// 柔和 (慢而平滑)
    pub const gentle = SpringConfig{ .stiffness = 120, .damping = 14 };
    /// 快速 (快速回弹)
    pub const wobbly = SpringConfig{ .stiffness = 180, .damping = 12 };
    /// 僵硬 (几乎没有弹性)
    pub const stiff = SpringConfig{ .stiffness = 210, .damping = 20 };
    /// 缓慢 (缓慢过渡)
    pub const slow = SpringConfig{ .stiffness = 280, .damping = 60 };
    /// 果冻 (高弹性)
    pub const molasses = SpringConfig{ .stiffness = 280, .damping = 120 };
};

/// 弹簧动画 — 解析解
pub const Spring = struct {
    config: SpringConfig,
    from: f32,
    to: f32,
    current_value: f32,
    velocity: f32,
    state: AnimationState = .idle,
    updating: bool = false,
    control_revision: u64 = 0,
    /// Configuration/trajectory changes, distinct from pause/stop commands.
    parameter_revision: u64 = 0,

    // 解析解预计算系数
    start_time_ms: f64 = 0,
    pause_time_ms: f64 = 0,
    /// 阻尼比 ζ
    zeta: f64 = 0,
    /// 自然角频率 ω₀
    omega0: f64 = 0,
    /// 初始位移 x₀ = from - to
    x0: f64 = 0,
    /// 初始速度 v₀
    v0: f64 = 0,
    /// Upward-rounded stable time after the final displacement/velocity threshold
    /// crossing. inf means this trajectory does not settle in finite f32 time.
    settling_time_s: f32 = 0,
    /// 解析解类型
    regime: Regime = .underdamped,

    const Regime = enum { underdamped, critical, overdamped };

    /// 创建 Spring
    pub fn init(from: f32, to: f32, config: SpringConfig) Spring {
        var s = Spring{
            .config = config,
            .from = from,
            .to = to,
            .velocity = config.initial_velocity,
            .current_value = from,
        };
        s.precompute();
        s.current_value = s.from;
        s.velocity = s.config.initial_velocity;
        return s;
    }

    /// Builder 风格创建
    pub fn from_value(initial: f32) SpringBuilder {
        return SpringBuilder{
            .from = initial,
            .to = initial,
            .config = SpringPreset.default,
        };
    }

    /// 预计算解析解系数
    pub fn precompute(self: *Spring) void {
        self.control_revision +%= 1;
        self.parameter_revision +%= 1;
        self.from = finiteOr(self.from, 0);
        self.to = finiteOr(self.to, self.from);
        self.config.mass = @max(finiteOr(self.config.mass, 1), 1e-6);
        self.config.stiffness = @max(finiteOr(self.config.stiffness, 170), 1e-6);
        self.config.damping = @max(finiteOr(self.config.damping, 26), 0);
        self.config.initial_velocity = finiteOr(self.config.initial_velocity, 0);
        if (!math.isFinite(self.config.rest_displacement) or self.config.rest_displacement <= 0) self.config.rest_displacement = 0.01;
        if (!math.isFinite(self.config.rest_velocity) or self.config.rest_velocity <= 0) self.config.rest_velocity = 0.01;
        const mass: f64 = self.config.mass;
        const stiffness: f64 = self.config.stiffness;
        const damping: f64 = self.config.damping;
        self.omega0 = @sqrt(stiffness / mass);
        self.zeta = damping / (2 * @sqrt(stiffness * mass));
        self.x0 = @as(f64, self.from) - self.to;
        self.v0 = self.config.initial_velocity;

        if (self.zeta < 1) {
            self.regime = .underdamped;
        } else if (self.zeta > 1) {
            self.regime = .overdamped;
        } else {
            self.regime = .critical;
        }
        const last_exit = @max(self.lastThresholdExit(false), self.lastThresholdExit(true));
        self.settling_time_s = if (last_exit == 0) 0 else if (!math.isFinite(last_exit) or last_exit >= math.floatMax(f32)) math.inf(f32) else math.nextAfter(f32, @floatCast(last_exit), math.inf(f32));
    }

    pub fn settlingDuration(self: *const Spring) f32 {
        return self.settling_time_s;
    }

    fn magnitude(self: *const Spring, time: f64, comptime velocity: bool) f64 {
        const result = self.solveWide(time);
        return @abs(if (velocity) result.v else result.x);
    }

    /// Each non-oscillatory component has at most one stationary point. For an
    /// oscillatory component, locate the last above-threshold extremum directly
    /// from its exponentially decaying peak sequence, without stepping periods.
    fn lastThresholdExit(self: *const Spring, comptime velocity: bool) f64 {
        const threshold: f64 = if (velocity) self.config.rest_velocity else self.config.rest_displacement;
        const initial = self.magnitude(0, velocity);
        const w = self.omega0;
        const a = self.zeta * w;
        var peak: f64 = 0;
        var upper: f64 = 0;
        switch (self.regime) {
            .underdamped => {
                const b = w * @sqrt((1 - self.zeta) * (1 + self.zeta));
                const p = if (velocity) self.v0 else self.x0;
                const q = if (velocity) -(w * w * self.x0 + a * self.v0) / b else (self.v0 + a * self.x0) / b;
                const amplitude = @sqrt(p * p + q * q);
                if (a == 0) return if (amplitude < threshold) 0 else math.inf(f64);
                if (amplitude < threshold) return 0;
                const phase = math.atan2(q, p);
                const lag = math.atan2(a, b);
                const peak_amplitude = amplitude * b / w;
                const horizon = @log(peak_amplitude / threshold) / a;
                const envelope_end = @log(amplitude / threshold) / a;
                // Beyond this phase resolution, one f32 time ulp spans many
                // oscillations. The envelope gives a safe representable end.
                if (@abs(b * horizon) > 0x1p40) return envelope_end;
                const index = @floor((b * horizon - phase + lag) / math.pi);
                peak = (phase - lag + index * math.pi) / b;
                if (peak >= 0 and self.magnitude(peak, velocity) < threshold) peak -= math.pi / b;
                if (peak >= 0 and self.magnitude(peak, velocity) >= threshold) {
                    upper = peak + (math.pi / 2.0 + lag) / b;
                } else {
                    if (initial < threshold) return 0;
                    peak = 0;
                    const first_zero_phase = phase + math.pi / 2.0;
                    upper = (first_zero_phase + @ceil(-first_zero_phase / math.pi) * math.pi) / b;
                    if (upper <= 0) upper += math.pi / b;
                }
            },
            .critical => {
                const base = self.v0 + w * self.x0;
                const p = if (velocity) self.v0 else self.x0;
                const q = if (velocity) -w * base else base;
                const stationary = if (q == 0) @as(f64, -1) else (q - w * p) / (w * q);
                if (stationary > 0 and self.magnitude(stationary, velocity) >= threshold) {
                    peak = stationary;
                } else if (initial < threshold) {
                    return 0;
                } else if (stationary > 0) {
                    return self.thresholdRoot(0, stationary, threshold, velocity);
                }
                // |(p+q*t)e^-wt| <= (|p|+2|q|/(e*w))*e^(-wt/2).
                const envelope = @abs(p) + 2 * @abs(q) / (@exp(@as(f64, 1)) * w);
                upper = @max(peak, 2 * @log(envelope / threshold) / w) + 1 / w;
            },
            .overdamped => {
                const sum = self.zeta + @sqrt((self.zeta - 1) * (self.zeta + 1));
                const r1 = -w / sum;
                const r2 = -w * sum;
                const denom = r1 - r2;
                var p = (self.v0 - r2 * self.x0) / denom;
                var q = (r1 * self.x0 - self.v0) / denom;
                if (velocity) {
                    p *= r1;
                    q *= r2;
                }
                const d1 = r1 * p;
                const d2 = r2 * q;
                const stationary = if (d1 != 0 and d2 != 0 and (d1 < 0) != (d2 < 0))
                    (@log(@abs(d2)) - @log(@abs(d1))) / denom
                else
                    -1;
                if (stationary > 0 and self.magnitude(stationary, velocity) >= threshold) {
                    peak = stationary;
                } else if (initial < threshold) {
                    return 0;
                } else if (stationary > 0) {
                    return self.thresholdRoot(0, stationary, threshold, velocity);
                }
                const slow_end = if (p == 0) @as(f64, 0) else @max(0, @log(2 * @abs(p) / threshold) / -r1);
                const fast_end = if (q == 0) @as(f64, 0) else @max(0, @log(2 * @abs(q) / threshold) / -r2);
                upper = @max(peak, @max(slow_end, fast_end)) + 1 / -r2;
            },
        }
        return self.thresholdRoot(peak, upper, threshold, velocity);
    }

    fn thresholdRoot(self: *const Spring, lower: f64, upper: f64, threshold: f64, comptime velocity: bool) f64 {
        const minimum_time: f64 = 0x1p-149;
        const maximum_time: f64 = math.floatMax(f32);
        if (lower >= maximum_time) return math.inf(f64);
        var low = @max(lower, minimum_time);
        var high = @min(upper, maximum_time);
        if (self.magnitude(high, velocity) >= threshold) return math.inf(f64);
        if (self.magnitude(low, velocity) < threshold) return low;
        // Geometric bisection resolves both very fast and very slow modes even
        // when their rates differ by more than the precision of a linear search.
        for (0..96) |_| {
            const middle = @sqrt(low) * @sqrt(high);
            if (middle <= low or middle >= high) break;
            if (self.magnitude(middle, velocity) >= threshold) low = middle else high = middle;
        }
        return high;
    }

    /// 从绝对时间 t（秒）计算位移和速度
    pub fn solve(self: *const Spring, t_s: f32) struct { x: f32, v: f32 } {
        const result = self.solveWide(safeTime(t_s));
        if (!math.isFinite(result.x) or !math.isFinite(result.v)) return .{ .x = 0, .v = 0 };
        return .{ .x = bounded(result.x), .v = bounded(result.v) };
    }

    /// Absolute value sampling avoids narrowing an oversized displacement before
    /// adding the target. Published values and velocities always fit finite f32.
    pub const Sample = struct { value: f32, velocity: f32 };

    pub fn sample(self: *const Spring, t_s: f32) Sample {
        return self.sampleDirected(t_s, false);
    }

    /// Mirror one canonical physical trajectory without mutating its endpoints
    /// or configured velocity. Both position and velocity change orientation.
    pub fn sampleDirected(self: *const Spring, t_s: f32, reversed: bool) Sample {
        const time = safeTime(t_s);
        if (time == 0) return .{
            .value = finiteOr(if (reversed) self.to else self.from, 0),
            .velocity = finiteOr(if (reversed) -self.config.initial_velocity else self.config.initial_velocity, 0),
        };
        const result = self.solveWide(time);
        const value = if (reversed) result.reverse_value else result.value;
        if (!math.isFinite(value) or !math.isFinite(result.v)) return .{ .value = finiteOr(if (reversed) self.from else self.to, 0), .velocity = 0 };
        return .{ .value = bounded(value), .velocity = bounded(if (reversed) -result.v else result.v) };
    }

    fn finiteOr(value: f32, fallback: f32) f32 {
        return if (math.isFinite(value)) value else fallback;
    }

    fn bounded(value: f64) f32 {
        const limit: f64 = math.floatMax(f32);
        return @floatCast(std.math.clamp(value, -limit, limit));
    }

    fn safeTime(value: f32) f64 {
        return if (math.isFinite(value)) @max(value, 0) else 0;
    }

    fn solveWide(self: *const Spring, t_s: f64) struct { x: f64, v: f64, value: f64, reverse_value: f64 } {
        const z = self.zeta;
        const w0 = self.omega0;
        const x0 = self.x0;
        const v0 = self.v0;
        if (t_s == 0) return .{ .x = x0, .v = v0, .value = self.from, .reverse_value = self.to };

        // x = x0*f + v0*g, v = -omega²*x0*g + v0*h.
        // Compute the step response r = 1-f independently: subtracting f from
        // one loses small movement, even when the final f32 value can represent it.
        const a = z * w0;
        const at = a * t_s;
        const wt = w0 * t_s;
        var f: f64 = undefined;
        var r: f64 = undefined;
        var g: f64 = undefined;
        var h: f64 = undefined;
        if (at <= 0.25 and wt <= 0.25) {
            // Dimensionless Taylor coefficients of g(t*s)/t solve
            // G'' + 2*a*t*G' + (omega*t)²*G = 0, G(0)=0, G'(0)=1.
            // r = (omega*t)² * integral(G), avoiding first-order cancellation.
            // Both dimensionless rates are bounded here; 24 terms exceed f64
            // precision without any loop over elapsed time or missed frames.
            const q = wt * wt;
            var previous: f64 = 0;
            var coefficient: f64 = 1;
            var sum: f64 = 0;
            var integral: f64 = 0;
            for (1..25) |index| {
                const n: f64 = @floatFromInt(index);
                sum += coefficient;
                integral += coefficient / (n + 1);
                const next = -(2 * at * n * coefficient + q * previous) / (n * (n + 1));
                previous = coefficient;
                coefficient = next;
            }
            r = q * integral;
            f = 1 - r;
            g = t_s * sum;
            h = f - 2 * at * sum;
        } else switch (self.regime) {
            .underdamped => {
                const wd = w0 * @sqrt((1 - z) * (1 + z));
                const phase = wd * t_s;
                const decay = @exp(-at);
                const cosine = @cos(phase);
                g = decay * @sin(phase) / wd;
                f = decay * cosine + a * g;
                h = decay * cosine - a * g;
                const half_sine = @sin(phase / 2);
                r = -math.expm1(-at) + 2 * decay * half_sine * half_sine - a * g;
            },
            .critical => {
                const decay = @exp(-wt);
                g = t_s * decay;
                f = (1 + wt) * decay;
                h = (1 - wt) * decay;
                r = -math.expm1(-wt) - wt * decay;
            },
            .overdamped => {
                const sum = z + @sqrt((z - 1) * (z + 1));
                const r1 = -w0 / sum;
                const r2 = -w0 * sum;
                const denom = r1 - r2;
                const e1 = @exp(r1 * t_s);
                const e2 = @exp(r2 * t_s);
                // expm1 retains both the slow displacement and the fast transient;
                // do not derive the second modal coefficient by subtracting x0.
                g = e1 * -math.expm1(-denom * t_s) / denom;
                f = e1 - r1 * g;
                h = e2 + r1 * g;
                r = -math.expm1(r1 * t_s) + r1 * g;
            },
        }
        return .{
            .x = @mulAdd(f64, x0, f, v0 * g),
            .v = @mulAdd(f64, -w0 * w0 * x0, g, v0 * h),
            .value = @mulAdd(f64, self.from, f, @mulAdd(f64, self.to, r, v0 * g)),
            .reverse_value = @mulAdd(f64, self.to, f, @mulAdd(f64, self.from, r, -v0 * g)),
        };
    }

    /// 开始播放
    pub fn start(self: *Spring) void {
        self.control_revision +%= 1;
        self.precompute();
        self.state = .running;
        self.current_value = self.from;
        self.velocity = self.config.initial_velocity;
        self.start_time_ms = render_engine.current_frame_time_ms;
    }

    /// 暂停
    pub fn pause(self: *Spring) void {
        if (self.state == .running) {
            self.control_revision +%= 1;
            self.state = .paused;
            self.pause_time_ms = render_engine.current_frame_time_ms;
        }
    }

    /// 恢复
    pub fn unpause(self: *Spring) void {
        if (self.state == .paused) {
            self.control_revision +%= 1;
            self.state = .running;
            const paused_duration = render_engine.current_frame_time_ms - self.pause_time_ms;
            self.start_time_ms += paused_duration;
        }
    }

    /// 停止
    pub fn stop(self: *Spring) void {
        self.control_revision +%= 1;
        self.state = .idle;
    }

    /// 重置
    pub fn reset(self: *Spring) void {
        self.control_revision +%= 1;
        self.precompute();
        self.state = .idle;
        self.current_value = self.from;
        self.velocity = self.config.initial_velocity;
    }

    /// 更新目标值 (可以在动画进行中调用)
    /// 从当前值和当前速度重新启动，保持运动连续性
    pub fn setTarget(self: *Spring, target: f32) void {
        if (!math.isFinite(target)) return;
        self.control_revision +%= 1;
        // 保存当前运动状态作为新动画的初始条件
        const cur_val = self.current_value;
        const cur_vel = self.velocity;
        self.from = cur_val;
        self.to = target;
        self.config.initial_velocity = cur_vel;
        self.start_time_ms = render_engine.current_frame_time_ms;
        self.precompute();
        if (self.state != .running) {
            self.state = .running;
        }
    }

    /// 绝对时间戳驱动的更新 (每帧调用)
    /// Standalone callers keep self alive and stable through callbacks.
    pub fn update(self: *Spring, now_ms: f64) void {
        self.updateGuarded(now_ms, AlwaysCurrent{});
    }

    const AlwaysCurrent = struct {
        pub fn isCurrent(_: @This()) bool {
            return true;
        }
        pub fn isUnchanged(_: @This()) bool {
            return true;
        }
    };

    /// Hosts protect movable slots and their own playback commands separately:
    /// isCurrent checks storage lifetime; isUnchanged checks host authority.
    /// Once isCurrent is false, even deferred writes to self are skipped.
    pub fn updateGuarded(self: *Spring, now_ms: f64, guard: anytype) void {
        if (!guard.isCurrent()) return;
        const elapsed_ms = now_ms - self.start_time_ms;
        if (!math.isFinite(elapsed_ms) or @abs(elapsed_ms) > math.floatMax(f32)) return;
        self.updateDirected(now_ms, @floatCast(@max(0, elapsed_ms / 1000)), false, guard);
    }

    /// Host-selected phase of the canonical trajectory. Callback commands retain
    /// the same storage-lifetime and authority checks as standalone updates.
    pub fn updateDirected(self: *Spring, now_ms: f64, seconds: f32, reversed: bool, guard: anytype) void {
        if (!guard.isCurrent()) return;
        if (self.state != .running or self.updating) return;
        const elapsed_ms = now_ms - self.start_time_ms;
        if (!math.isFinite(now_ms) or now_ms < 0 or !math.isFinite(elapsed_ms) or @abs(elapsed_ms) > math.floatMax(f32)) return;
        if (!math.isFinite(seconds) or seconds < 0) return;
        self.updating = true;
        defer if (guard.isCurrent()) {
            self.updating = false;
        };
        const revision = self.control_revision;

        const result = self.solveWide(seconds);
        const value = if (reversed) result.reverse_value else result.value;
        const target = if (reversed) self.from else self.to;
        const numerical_failure = !math.isFinite(value) or !math.isFinite(result.v);
        self.current_value = if (numerical_failure) finiteOr(target, 0) else bounded(value);
        self.velocity = if (numerical_failure) 0 else bounded(if (reversed) -result.v else result.v);

        // 调用更新回调
        if (self.config.on_update) |callback| {
            if (self.config.context) |ctx| {
                if (@hasDecl(@TypeOf(guard), "beforeCallback")) guard.beforeCallback();
                callback(self.current_value, ctx);
            }
        }

        if (!guard.isCurrent()) return;
        if (!guard.isUnchanged() or self.control_revision != revision or self.state != .running) return;

        // 检查是否静止
        if (numerical_failure or seconds >= self.settling_time_s) {
            self.current_value = finiteOr(target, 0);
            self.velocity = 0;
            self.state = .completed;

            if (self.config.on_complete) |callback| {
                if (self.config.context) |ctx| {
                    if (@hasDecl(@TypeOf(guard), "beforeCallback")) guard.beforeCallback();
                    callback(ctx);
                }
            }
        }
    }

    /// 获取当前值
    pub fn getValue(self: *const Spring) f32 {
        return self.current_value;
    }

    /// 是否正在运行
    pub fn isRunning(self: *const Spring) bool {
        return self.state == .running;
    }

    /// 是否完成
    pub fn isCompleted(self: *const Spring) bool {
        return self.state == .completed;
    }
};

/// Spring Builder
pub const SpringBuilder = struct {
    from: f32,
    to: f32,
    config: SpringConfig,

    pub fn to_value(self: SpringBuilder, value: f32) SpringBuilder {
        var new = self;
        new.to = value;
        return new;
    }

    pub fn stiffness(self: SpringBuilder, s: f32) SpringBuilder {
        var new = self;
        new.config.stiffness = s;
        return new;
    }

    pub fn damping(self: SpringBuilder, d: f32) SpringBuilder {
        var new = self;
        new.config.damping = d;
        return new;
    }

    pub fn mass(self: SpringBuilder, m: f32) SpringBuilder {
        var new = self;
        new.config.mass = m;
        return new;
    }

    pub fn preset(self: SpringBuilder, p: SpringConfig) SpringBuilder {
        var new = self;
        new.config = p;
        return new;
    }

    pub fn onComplete(self: SpringBuilder, callback: *const fn (*anyopaque) void, context: *anyopaque) SpringBuilder {
        var new = self;
        new.config.on_complete = callback;
        new.config.context = context;
        return new;
    }

    pub fn onUpdate(self: SpringBuilder, callback: *const fn (f32, *anyopaque) void, context: *anyopaque) SpringBuilder {
        var new = self;
        new.config.on_update = callback;
        new.config.context = context;
        return new;
    }

    pub fn build(self: SpringBuilder) Spring {
        return Spring.init(self.from, self.to, self.config);
    }
};

// ========== 测试 ==========

fn setTestTime(ms: f64) void {
    render_engine.current_frame_time_ms = ms;
}

test "Spring: basic animation" {
    setTestTime(1000.0);
    var spring = Spring.from_value(0.0)
        .to_value(100.0)
        .preset(SpringPreset.stiff)
        .build();

    spring.start();
    try std.testing.expect(spring.isRunning());

    // 模拟几秒（stiff 预设应该很快收敛）
    var ms: f64 = 1000.0;
    var i: usize = 0;
    while (i < 300 and spring.isRunning()) : (i += 1) {
        ms += 1000.0 / 60.0;
        spring.update(ms);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 100.0), spring.getValue(), 0.01);
    try std.testing.expect(spring.isCompleted());
}

test "Spring: overshoot" {
    setTestTime(1000.0);
    var spring = Spring.from_value(0.0)
        .to_value(100.0)
        .preset(SpringPreset.wobbly)
        .build();

    spring.start();

    var max_value: f32 = 0;
    var ms: f64 = 1000.0;
    var i: usize = 0;
    while (i < 500 and spring.isRunning()) : (i += 1) {
        ms += 1000.0 / 60.0;
        spring.update(ms);
        if (spring.getValue() > max_value) {
            max_value = spring.getValue();
        }
    }

    // wobbly 预设应该有超调
    try std.testing.expect(max_value > 100.0);
}

test "Spring: update target" {
    setTestTime(1000.0);
    var spring = Spring.from_value(0.0)
        .to_value(50.0)
        .build();

    spring.start();

    // 运行到一半
    var ms: f64 = 1000.0;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        ms += 1000.0 / 60.0;
        spring.update(ms);
    }

    // 中途改变目标
    setTestTime(ms);
    spring.setTarget(100.0);

    // 继续运行
    while (i < 300 and spring.isRunning()) : (i += 1) {
        ms += 1000.0 / 60.0;
        spring.update(ms);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 100.0), spring.getValue(), 0.01);
}

test "Spring: callback" {
    setTestTime(1000.0);
    const TestState = struct {
        last_value: f32 = 0,
        completed: bool = false,
    };
    var state = TestState{};

    var spring = Spring.from_value(0.0)
        .to_value(10.0)
        .stiffness(500)
        .damping(50)
        .onUpdate(struct {
            fn handler(value: f32, ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.last_value = value;
            }
        }.handler, &state)
        .onComplete(struct {
            fn handler(ctx: *anyopaque) void {
                const ptr: *TestState = @ptrCast(@alignCast(ctx));
                ptr.completed = true;
            }
        }.handler, &state)
        .build();

    spring.start();

    var ms: f64 = 1000.0;
    var i: usize = 0;
    while (i < 300 and spring.isRunning()) : (i += 1) {
        ms += 1000.0 / 60.0;
        spring.update(ms);
    }

    try std.testing.expect(state.completed);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), state.last_value, 0.01);
}

test "Spring: analytical solution accuracy" {
    // 验证解析解在不同帧率下结果一致（这是解析解相比欧拉积分的核心优势）
    setTestTime(0);
    var spring_60fps = Spring.from_value(0.0)
        .to_value(100.0)
        .preset(SpringPreset.default)
        .build();
    spring_60fps.start();

    setTestTime(0);
    var spring_30fps = Spring.from_value(0.0)
        .to_value(100.0)
        .preset(SpringPreset.default)
        .build();
    spring_30fps.start();

    // 60fps 跑 60 帧 = 1 秒
    var ms: f64 = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        ms += 1000.0 / 60.0;
        spring_60fps.update(ms);
    }

    // 30fps 跑 30 帧 = 1 秒
    ms = 0;
    i = 0;
    while (i < 30) : (i += 1) {
        ms += 1000.0 / 30.0;
        spring_30fps.update(ms);
    }

    // 解析解下两者在 t=1s 时结果应该完全一致
    try std.testing.expectApproxEqAbs(spring_60fps.getValue(), spring_30fps.getValue(), 0.001);
}

test "Spring: 非法 stiffness/damping 不产生 NaN（钳制防线）" {
    // 回归：负 stiffness → @sqrt(负) → omega0/zeta 全 NaN，NaN 比较全 false
    // 骗过 regime 选择与 w0 早退，最终把 NaN 写进节点 style。
    setTestTime(0);
    var s = Spring.init(0.0, 100.0, .{ .stiffness = -50.0, .damping = -5.0 });
    s.start();
    setTestTime(100);
    s.update(100);
    try std.testing.expect(!std.math.isNan(s.getValue()));
    try std.testing.expect(!std.math.isNan(s.omega0));
    try std.testing.expect(!std.math.isNan(s.zeta));
    // 负阻尼也不许能量爆炸：值必须有限
    setTestTime(5000);
    s.update(5000);
    try std.testing.expect(std.math.isFinite(s.getValue()));
}
