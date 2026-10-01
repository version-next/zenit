/// AnimationController，统一播放控制器
///
/// 包装 Tween/Spring/Keyframes 三种驱动器，提供 GSAP 风格的统一播放控制：
/// play / pause / resume / reverse / seek / restart
///
/// 用法:
/// ```zig
/// // Tween 动画
/// var ctrl = AnimationController.initTween(.{ .from = 0, .to = 100, .duration = 0.5 });
/// ctrl.play();
/// // 每帧:
/// if (ctrl.tick(now_ms)) node.markRenderDirty();
/// const v = ctrl.value; // 当前值
///
/// // Spring 动画
/// var ctrl2 = AnimationController.initSpring(.{ .from = 0, .to = 100, .stiffness = 200, .damping = 20 });
/// ctrl2.play();
///
/// // 播放控制
/// ctrl.pause();
/// ctrl.unpause();
/// ctrl.reverse();
/// ctrl.seek(0.5); // 跳到 50%
/// ```
const std = @import("std");
const values = @import("value.zig");
const Scope = @import("../reactive/scope.zig").Scope;
const Easing = @import("easing.zig").Easing;
const Spring = @import("spring.zig").Spring;
const KeyframeAnimation = @import("keyframes.zig").KeyframeAnimation;
const Keyframe = @import("keyframes.zig").Keyframe;
const render_engine = @import("../core/render_engine/mod.zig");

/// 播放状态
pub const PlayState = enum {
    idle,
    playing,
    paused,
    completed,
};

/// 回调函数类型
pub const CallbackFn = *const fn (*anyopaque) void;
pub const UpdateCallbackFn = *const fn (f32, *anyopaque) void;

/// Tween 驱动配置
pub const TweenConfig = struct {
    from: f32 = 0,
    to: f32 = 1,
    duration: f32 = 0.3,
    easing: Easing = .ease_out_quad,
    delay: f32 = 0,
};

/// Spring 驱动配置
pub const SpringAnimConfig = struct {
    from: f32 = 0,
    to: f32 = 1,
    stiffness: f32 = 170,
    damping: f32 = 26,
    mass: f32 = 1,
    initial_velocity: f32 = 0,
    rest_displacement: f32 = 0.01,
    rest_velocity: f32 = 0.01,
};

/// A retained tombstone for controller copies. It does not keep disposed Scope
/// resources alive; scope is cleared before the original hook allocation dies.
pub const ScopeLifetime = struct {
    allocator: std.mem.Allocator,
    scope: ?*Scope,
    refs: usize = 1,
    timeline_registrations: ?*@import("timeline.zig").ControllerRegistration = null,

    pub fn create(scope: *Scope) !*ScopeLifetime {
        const lifetime = try scope.allocator.create(ScopeLifetime);
        lifetime.* = .{ .allocator = scope.allocator, .scope = scope };
        return lifetime;
    }

    pub fn retain(self: *ScopeLifetime) void {
        self.refs += 1;
    }

    pub fn release(self: *ScopeLifetime) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.allocator.destroy(self);
    }

    /// Detach Timeline borrows before the hook controller allocation is freed.
    pub fn retire(self: *ScopeLifetime) void {
        self.scope = null;
        while (self.timeline_registrations) |registration| {
            registration.timeline.remove(registration.controller);
        }
    }

    pub fn isRetiring(self: *const ScopeLifetime) bool {
        return if (self.scope) |scope| scope.willBeDisposedAfterReactiveCallback() else true;
    }
};

/// 统一动画控制器
pub const AnimationController = struct {
    // Hooks bind their allocation to a Scope. Tick holds that owner until all
    // callback dispatch and controller access has finished.
    lifetime_scope: ?*Scope = null,
    scope_lifetime: ?*ScopeLifetime = null,
    ticking: bool = false,
    control_revision: u64 = 0,
    spring_parameter_revision: u64 = 0,
    /// One mutable playback state has one Timeline clock. Independent retained
    /// copies clear this link; remove/deinit releases the original borrow.
    timeline_owner: ?*@import("timeline.zig").Timeline = null,
    /// Set only on storage accepted by NodeAnimations. Such slots can move or
    /// be replaced and cannot be borrowed by a Timeline.
    node_owned: bool = false,

    /// 底层驱动
    driver: Driver,
    /// 播放状态
    play_state: PlayState = .idle,
    /// 播放方向 (1.0 = 正向, -1.0 = 反向)
    direction: f32 = 1.0,
    /// 总进度 [0, 1]
    progress: f32 = 0,
    /// 当前值
    value: f32 = 0,
    /// 首次对外可见的 tick 只建立时间锚点，不消耗该帧的时间片。
    pending_first_tick: bool = false,
    /// Preserve an explicit stopped/completed seek when play later arms time.
    seek_on_play: bool = false,
    /// Local driver elapsed time of a stopped seek. Unlike normalized progress,
    /// this retains delay, cycle remainder and nonconverging Spring time.
    seek_elapsed_ms: f64 = 0,
    /// 循环次数 (0 = 无限)
    loops: u32 = 1,
    /// 来回模式
    yoyo: bool = false,
    current_loop: u32 = 0,
    /// 暂停时记录的时间戳（用于 unpause 时偏移 start_time_ms）
    pause_time_ms: f64 = 0,
    /// 回调
    on_complete: ?CallbackFn = null,
    on_complete_ctx: ?*anyopaque = null,
    on_update: ?UpdateCallbackFn = null,
    on_update_ctx: ?*anyopaque = null,

    /// 驱动类型
    pub const Driver = union(enum) {
        tween: TweenDriver,
        spring: Spring,
        keyframes: KeyframeAnimation,
    };

    const TweenVelocityPhase = struct { progress: f32, direction: f32 };

    /// Tween 驱动内部状态
    pub const TweenDriver = struct {
        from: f32,
        to: f32,
        duration: f32,
        delay: f32 = 0,
        easing: Easing,
        start_time_ms: f64 = 0,
        /// Phase of the last published sample. null means a held/terminal value.
        /// Callbacks can query it before the prepared cycle count is committed.
        velocity_phase: ?TweenVelocityPhase = null,
    };

    // ============ 构造函数 ============

    /// 创建 Tween 驱动的控制器
    pub fn initTween(config: TweenConfig) AnimationController {
        const from = values.finiteOr(config.from, 0);
        const to = values.finiteOr(config.to, from);
        return .{
            .driver = .{ .tween = .{
                .from = from,
                .to = to,
                .duration = config.duration,
                .delay = config.delay,
                .easing = config.easing,
            } },
            .value = from,
        };
    }

    /// 创建 Spring 驱动的控制器
    pub fn initSpring(config: SpringAnimConfig) AnimationController {
        const spring = Spring.init(config.from, config.to, .{
            .stiffness = config.stiffness,
            .damping = config.damping,
            .mass = config.mass,
            .initial_velocity = config.initial_velocity,
            .rest_displacement = config.rest_displacement,
            .rest_velocity = config.rest_velocity,
        });
        return .{ .driver = .{ .spring = spring }, .value = spring.current_value, .spring_parameter_revision = spring.parameter_revision };
    }

    /// 创建 Keyframes 驱动的控制器
    pub fn initKeyframes(kf: []const Keyframe, duration_ms: f32) AnimationController {
        const kf_anim = KeyframeAnimation.init(kf, duration_ms, 1);
        const initial = kf_anim.current_value;
        return .{
            .driver = .{ .keyframes = kf_anim },
            .value = initial,
        };
    }

    // ============ 播放控制 ============

    /// 开始播放
    ///
    /// Phase 7 修复：原 `if (tw.start_time_ms == 0) tw.start_time_ms = now_ms`
    /// 守卫在 boot/test 场景（current_frame_time_ms 真为 0）误激活，第二次
    /// play 永远从原点开始，看上去"不前进"。改用 play_state 显式管理：
    /// 进入 .playing 时无条件锚定 start_time_ms。
    pub fn play(self: *AnimationController) void {
        if (self.play_state == .playing) return;
        if (self.play_state == .paused) {
            self.unpause();
            return;
        }
        _ = self.adoptSpringParameters();
        self.control_revision +%= 1;
        const resume_seek = self.seek_on_play;
        if (self.play_state == .completed and !resume_seek) {
            self.direction = 1.0;
            self.resetDriver();
            self.progress = 0;
            self.current_loop = 0;
        }
        self.play_state = .playing;
        self.pending_first_tick = false;
        self.seek_on_play = false;
        const now_ms = render_engine.current_frame_time_ms;
        if (resume_seek) {
            // Rebase the sampled state as a whole. Reconstructing from progress
            // loses held delay values, loop direction and unbounded Spring time.
            switch (self.driver) {
                inline else => |*driver| driver.start_time_ms = now_ms - self.seek_elapsed_ms,
            }
            if (self.driver == .spring) {
                self.driver.spring.control_revision +%= 1;
                self.driver.spring.state = .running;
            }
            return;
        }
        self.seek_elapsed_ms = 0;
        switch (self.driver) {
            .tween => |*tw| tw.start_time_ms = now_ms,
            .spring => |*sp| {
                sp.start();
                self.spring_parameter_revision = sp.parameter_revision;
                self.publishSpringSample(0, self.direction);
            },
            .keyframes => |*kf| kf.start_time_ms = now_ms,
        }
        self.value = self.evaluateAt(0);
        self.recordTweenStart();
    }

    /// 用 (current_value, velocity) 接管动画，interruption-safe 续衔。
    /// 当 NodeAnimations.set 替换 controller 时，从老 controller 取 current/velocity
    /// 调这个；新 controller 据此从老的"当前位置"开始而非 from_value 跳变。
    ///
    /// 驱动行为:
    /// - spring: from := current_value, initial_velocity := velocity, 重 precompute
    ///   + 锚定 start_time_ms = now -> 下一 tick 真从 (current, velocity) 续衔
    /// - tween: from := current_value (起点续衔)，velocity 忽略 (tween 没有速度参数)
    /// - keyframes: 不支持任意点续衔；只更新 self.value 给应用层用
    ///
    /// 调用约定: 必须在 play() 之后调，否则 spring.start() 会重 reset。
    pub fn seed(self: *AnimationController, current_value: f32, velocity: f32) void {
        if (!std.math.isFinite(current_value)) return;
        if (self.driver == .spring and !std.math.isFinite(velocity)) return;
        self.control_revision +%= 1;
        self.seek_on_play = false;
        self.seek_elapsed_ms = 0;
        self.value = current_value;
        switch (self.driver) {
            .spring => |*sp| {
                // 修改 from + initial_velocity 让 precompute 用新值算 ODE 系数
                sp.from = current_value;
                sp.config.initial_velocity = velocity;
                sp.current_value = current_value;
                sp.velocity = velocity;
                sp.precompute();
                self.spring_parameter_revision = sp.parameter_revision;
                self.current_loop = 0;
                self.direction = 1;
                // 重锚定 start_time，让 t_s=0 即"现在"
                sp.start_time_ms = render_engine.current_frame_time_ms;
                sp.state = .running;
                self.progress = 0;
            },
            .tween => |*tw| {
                tw.from = current_value;
                self.direction = 1;
                self.current_loop = 0;
                tw.start_time_ms = render_engine.current_frame_time_ms;
                self.progress = 0;
                self.recordTweenStart();
            },
            .keyframes => {
                // keyframes 没有内连续语义；只更新 value
            },
        }
    }

    /// Velocity of the last published sample, in value/sec, for interruption.
    /// Spring retains its physical velocity. Tween estimates the easing slope
    /// before affine scaling, so large absolute offsets do not erase motion.
    /// A pause retains that sample velocity; delay and terminal samples use zero.
    pub fn currentVelocity(self: *const AnimationController) f32 {
        return switch (self.driver) {
            .spring => |sp| sp.velocity,
            .tween => |tw| blk: {
                const phase = tw.velocity_phase orelse break :blk 0;
                if (!std.math.isFinite(tw.duration) or tw.duration <= 0) break :blk 0;
                const t = std.math.clamp(phase.progress, 0, 1);
                const lo = @max(0, t - 0.001);
                const hi = @min(1, t + 0.001);
                const slope = (@as(f64, values.eased(tw.easing, hi)) - values.eased(tw.easing, lo)) / (@as(f64, hi) - lo);
                const from = values.finiteOr(tw.from, 0);
                const to = values.finiteOr(tw.to, from);
                const velocity = (@as(f64, to) - from) * slope / tw.duration * @as(f64, if (phase.direction < 0) -1 else 1);
                if (!std.math.isFinite(velocity)) break :blk 0;
                break :blk @floatCast(std.math.clamp(velocity, -@as(f64, std.math.floatMax(f32)), std.math.floatMax(f32)));
            },
            .keyframes => 0,
        };
    }

    fn recordTweenVelocity(self: *AnimationController, directed_progress: f32, direction: f32, moving: bool) void {
        if (self.driver != .tween) return;
        self.driver.tween.velocity_phase = if (moving and std.math.isFinite(directed_progress)) .{ .progress = directed_progress, .direction = direction } else null;
    }

    fn recordTweenStart(self: *AnimationController) void {
        if (self.driver == .tween) self.recordTweenVelocity(if (self.direction < 0) 1 else 0, self.direction, self.driver.tween.delay <= 0 and self.driver.tween.duration > 0);
    }

    /// 开始播放，但首个对外可见 tick 仅建立时间锚点，不消耗该帧时间片。
    pub fn playPendingFirstTick(self: *AnimationController) void {
        const resume_seek = self.seek_on_play;
        self.play();
        self.control_revision +%= 1;
        if (!resume_seek) {
            // Explicit re-arming while playing starts a fresh visible leg.
            if (self.driver == .spring) {
                self.driver.spring.start();
                self.spring_parameter_revision = self.driver.spring.parameter_revision;
                self.publishSpringSample(0, self.direction);
            }
            self.seek_elapsed_ms = 0;
            self.progress = 0;
            self.current_loop = 0;
            self.value = self.evaluateAt(0);
            self.recordTweenStart();
        }
        self.pending_first_tick = true;
    }

    /// 暂停
    pub fn pause(self: *AnimationController) void {
        self.control_revision +%= 1;
        if (self.play_state == .playing) {
            self.play_state = .paused;
            self.pause_time_ms = render_engine.current_frame_time_ms;
        }
    }

    /// 恢复播放
    pub fn unpause(self: *AnimationController) void {
        if (self.play_state == .paused) {
            self.control_revision +%= 1;
            self.play_state = .playing;
            // 偏移 start_time_ms 以补偿暂停期间的时间流逝（仅 Tween/Keyframes）
            const paused_duration = render_engine.current_frame_time_ms - self.pause_time_ms;
            switch (self.driver) {
                .tween => |*tw| tw.start_time_ms += paused_duration,
                .keyframes => |*kf| kf.start_time_ms += paused_duration,
                .spring => |*sp| {
                    sp.start_time_ms += paused_duration;
                    if (sp.state == .paused) sp.state = .running;
                },
            }
        }
    }

    /// 反转方向
    pub fn reverse(self: *AnimationController) void {
        self.control_revision +%= 1;
        self.direction = -self.direction;
    }

    /// 跳转到指定进度 [0, 1]
    pub fn seek(self: *AnimationController, target_progress: f32) void {
        if (!std.math.isFinite(target_progress)) return;
        if (self.driver == .spring and target_progress > 0 and !std.math.isFinite(self.driver.spring.settlingDuration())) return;
        self.control_revision +%= 1;
        if (self.play_state == .completed) self.current_loop = 0;
        self.progress = std.math.clamp(target_progress, 0, 1);
        self.pending_first_tick = false;
        self.seek_on_play = self.play_state == .idle or self.play_state == .completed;
        self.value = self.evaluateAt(self.progress);
        // While paused, anchor against the pause instant. unpause will shift
        // this by the full paused duration, preserving a seek made mid-pause.
        const now_ms = if (self.play_state == .paused) self.pause_time_ms else render_engine.current_frame_time_ms;
        switch (self.driver) {
            .tween => |*tw| {
                const elapsed_ms = (tw.delay + self.progress * tw.duration) * 1000.0;
                tw.start_time_ms = now_ms - @as(f64, elapsed_ms);
                self.recordTweenVelocity(if (self.direction < 0) 1 - self.progress else self.progress, self.direction, self.progress < 1 and tw.duration > 0);
            },
            .keyframes => |*kf| {
                kf.start_time_ms = now_ms - @as(f64, self.progress * kf.duration_ms);
            },
            .spring => |*sp| {
                const seconds = if (self.progress == 0) 0 else self.progress * sp.settlingDuration();
                sp.control_revision +%= 1;
                sp.start_time_ms = now_ms - milliseconds(seconds);
                sp.current_value = self.value;
                sp.velocity = if (self.progress >= 1) 0 else sp.sampleDirected(seconds, self.direction < 0).velocity;
                sp.state = if (self.progress >= 1) .completed else .running;
            },
        }
        self.captureSeekTime(now_ms);
    }

    /// Timeline adapter: sample absolute child time from the registration's
    /// initial direction, including finite/infinite child loops.
    /// This only seeks; tick retains callback authority and completion delivery.
    pub fn seekTimelineTime(self: *AnimationController, elapsed: f32, now_ms: f64, initial_direction: f32) void {
        if (!std.math.isFinite(elapsed) or !std.math.isFinite(now_ms) or !std.math.isFinite(initial_direction)) return;
        const duration, const delay = switch (self.driver) {
            .tween => |driver| .{ milliseconds(driver.duration), milliseconds(driver.delay) },
            .keyframes => |driver| .{ @as(f64, driver.duration_ms), @as(f64, 0) },
            .spring => return self.seekSpringTime(elapsed, now_ms, initial_direction),
        };
        if (!std.math.isFinite(duration) or !std.math.isFinite(delay)) return;
        const elapsed_ms = milliseconds(@max(elapsed, 0));
        const frame = self.fixedFrameFrom(elapsed_ms, 0, duration, delay, 0, initial_direction) orelse FixedFrame{
            .progress = 0,
            .sample_progress = if (initial_direction < 0) 1 else 0,
            .direction = initial_direction,
            .loop_count = 0,
            .start_ms = 0,
            .finished = false,
        };
        self.control_revision +%= 1;
        self.pending_first_tick = false;
        self.seek_on_play = self.play_state == .idle or self.play_state == .completed;
        self.progress = frame.progress;
        self.direction = frame.direction;
        self.current_loop = frame.loop_count;
        const start_ms = now_ms - elapsed_ms + frame.start_ms;
        switch (self.driver) {
            .tween => |*driver| {
                self.value = values.sample(driver.from, driver.to, driver.easing, frame.sample_progress);
                driver.start_time_ms = start_ms;
                self.recordTweenVelocity(frame.sample_progress, frame.direction, frame.moving);
            },
            .keyframes => |*driver| {
                self.value = driver.valueAtProgress(frame.sample_progress);
                driver.start_time_ms = start_ms;
            },
            .spring => unreachable,
        }
        self.captureSeekTime(now_ms);
    }

    fn seekSpringTime(self: *AnimationController, elapsed: f32, now_ms: f64, initial_direction: f32) void {
        self.control_revision +%= 1;
        self.pending_first_tick = false;
        self.seek_on_play = self.play_state == .idle or self.play_state == .completed;
        const sp = &self.driver.spring;
        sp.control_revision +%= 1;
        self.spring_parameter_revision = sp.parameter_revision;
        const elapsed_ms = milliseconds(@max(elapsed, 0));
        const duration = sp.settlingDuration();
        if (self.fixedFrameFrom(elapsed_ms, 0, milliseconds(duration), 0, 0, initial_direction)) |frame| {
            self.progress = frame.progress;
            self.direction = frame.direction;
            self.current_loop = frame.loop_count;
            self.publishSpringSample(if (frame.progress >= 1) duration else @floatCast((elapsed_ms - frame.start_ms) / 1000), frame.direction);
            sp.start_time_ms = now_ms - elapsed_ms + frame.start_ms;
            sp.state = if (frame.finished) .completed else .running;
        } else {
            self.progress = 0;
            self.direction = initial_direction;
            self.current_loop = 0;
            self.publishSpringSample(@max(elapsed, 0), initial_direction);
            sp.start_time_ms = now_ms - elapsed_ms;
            sp.state = .running;
        }
        self.captureSeekTime(now_ms);
    }

    fn captureSeekTime(self: *AnimationController, now_ms: f64) void {
        self.seek_elapsed_ms = now_ms - switch (self.driver) {
            inline else => |driver| driver.start_time_ms,
        };
    }

    fn publishSpringSample(self: *AnimationController, seconds: f32, direction: f32) void {
        const sp = &self.driver.spring;
        const sample = sp.sampleDirected(seconds, direction < 0);
        const finished = seconds >= sp.settlingDuration();
        sp.current_value = if (finished) (if (direction < 0) sp.from else sp.to) else sample.value;
        sp.velocity = if (finished) 0 else sample.velocity;
        self.value = sp.current_value;
    }

    // A direct retarget/recompute creates a new canonical trajectory. Never
    // commit the previous trajectory's prepared cycle after a callback does so.
    fn adoptSpringParameters(self: *AnimationController) bool {
        if (self.driver != .spring) return false;
        const sp = &self.driver.spring;
        if (self.spring_parameter_revision == sp.parameter_revision) return false;
        self.spring_parameter_revision = sp.parameter_revision;
        self.control_revision +%= 1;
        self.seek_on_play = false;
        self.seek_elapsed_ms = 0;
        self.current_loop = 0;
        self.direction = 1;
        self.progress = 0;
        self.value = sp.current_value;
        return true;
    }

    // A low-level driver command must not leave a playing wrapper spinning on
    // an idle/paused Spring, nor publish a stale prepared value after retarget.
    fn adoptSpringCommand(self: *AnimationController) void {
        _ = self.adoptSpringParameters();
        self.control_revision +%= 1;
        const sp = &self.driver.spring;
        self.value = sp.current_value;
        switch (sp.state) {
            .idle => self.play_state = .idle,
            .paused => {
                self.play_state = .paused;
                self.pause_time_ms = sp.pause_time_ms;
            },
            else => {},
        }
    }

    /// Complete scheduled lifetime, including repeated Spring trajectories.
    /// Positive-period infinite loops are unbounded. Invalid configs return NaN.
    pub fn timelineDuration(self: *const AnimationController) f32 {
        const duration, const delay = switch (self.driver) {
            .tween => |driver| .{ milliseconds(driver.duration), milliseconds(driver.delay) },
            .keyframes => |driver| .{ @as(f64, driver.duration_ms), @as(f64, 0) },
            .spring => |driver| .{ milliseconds(driver.settlingDuration()), @as(f64, 0) },
        };
        if (self.driver == .spring and duration == std.math.inf(f64)) return std.math.inf(f32);
        if (!std.math.isFinite(duration) or !std.math.isFinite(delay)) return std.math.nan(f32);
        const cycle = @max(@max(duration, 0) + delay, 0);
        if (cycle == 0) return 0;
        if (self.loops == 0) return std.math.inf(f32);
        return @floatCast(cycle * @as(f64, @floatFromInt(self.loops)) / 1000);
    }

    /// 设置时间缩放
    /// 停止（重置到初始状态）
    pub fn stop(self: *AnimationController) void {
        self.control_revision +%= 1;
        self.play_state = .idle;
        self.pending_first_tick = false;
        self.seek_on_play = false;
        self.seek_elapsed_ms = 0;
        self.progress = 0;
        self.current_loop = 0;
        self.direction = 1.0;
        self.resetDriver();
        self.value = self.evaluateAt(0);
    }

    /// 重新开始
    pub fn restart(self: *AnimationController) void {
        self.stop();
        self.play();
    }

    // ============ 帧驱动 ============

    /// 推进动画一帧，返回 true 表示仍在播放
    /// now_ms: 当前帧的绝对时间戳（毫秒）
    /// Non-hook callers must keep this controller alive and at a stable address
    /// through tick, including callbacks. Playback methods are callback-safe;
    /// replacing the whole struct while it is ticking is not supported. When a
    /// Timeline or node owns the driver, this entry point reports active state
    /// without advancing; only its host adapter can supply the playback clock.
    pub fn tick(self: *AnimationController, now_ms: f64) bool {
        if (self.timeline_owner != null or self.node_owned) return !self.scopeIsRetiring() and self.isActive();
        return self.tickImpl(now_ms, AlwaysCurrent{}, false, false);
    }

    const AlwaysCurrent = struct {
        pub fn isCurrent(_: @This()) bool {
            return true;
        }
    };

    /// Host adapter for movable/replaced slots. The guard must live outside
    /// this controller and may only inspect stable host state. Once it returns
    /// false, no further controller access occurs, including deferred writes.
    /// Completion state is committed, but callback fields are left to the host
    /// so it can publish the final value before dispatching the notification.
    pub fn tickDeferredCompletion(self: *AnimationController, now_ms: f64, guard: anytype) bool {
        if (!guard.isCurrent()) return false;
        if (self.timeline_owner != null) return !self.scopeIsRetiring() and self.isActive();
        return self.tickImpl(now_ms, guard, true, false);
    }

    /// A Timeline seek may land in repeated delay while moving backward.
    /// Publish that held value through the same callback/reentrancy guards.
    /// The Timeline's controller borrow is stable through this call. Its own
    /// traversal revision is not a storage-lifetime guard for this controller.
    pub fn tickTimelineSample(self: *AnimationController, now_ms: f64, timeline: *@import("timeline.zig").Timeline, comptime defer_completion: bool) bool {
        return self.tickTimelineSampleObserved(now_ms, timeline, defer_completion, null);
    }

    /// Stack-owned observation, marked before invoking user code. It tracks
    /// actual dispatch (including low Spring callbacks), not registered handlers.
    /// The observer is independent of movable controller or Timeline entry storage.
    pub fn tickTimelineSampleObserved(self: *AnimationController, now_ms: f64, timeline: *@import("timeline.zig").Timeline, comptime defer_completion: bool, called: ?*bool) bool {
        if (self.timeline_owner != timeline or self.node_owned) return false;
        const CallbackObserver = struct {
            called: ?*bool,
            pub fn isCurrent(_: @This()) bool {
                return true;
            }
            pub fn beforeCallback(g: @This()) void {
                if (g.called) |flag| flag.* = true;
            }
        };
        return self.tickImpl(now_ms, CallbackObserver{ .called = called }, defer_completion, true);
    }

    /// Finish a Timeline's explicitly bounded traversal after its final value
    /// has been published. The host keeps this borrow alive through the callback.
    pub fn completeTimelineTraversal(self: *AnimationController, timeline: *@import("timeline.zig").Timeline) bool {
        if (self.timeline_owner != timeline or self.node_owned) return false;
        return self.finish(AlwaysCurrent{}, false);
    }

    fn tickImpl(self: *AnimationController, now_ms: f64, guard: anytype, comptime defer_completion: bool, comptime publish_delay: bool) bool {
        if (!guard.isCurrent() or self.scopeIsRetiring()) return false;
        if (self.play_state != .playing) return false;
        if (self.ticking) return true;
        _ = self.adoptSpringParameters();
        const start_ms = switch (self.driver) {
            inline else => |driver| driver.start_time_ms,
        };
        const clock_delta_ms = now_ms - start_ms;
        if (!std.math.isFinite(now_ms) or now_ms < 0 or !std.math.isFinite(clock_delta_ms) or @abs(clock_delta_ms) > std.math.floatMax(f32)) return true;
        const owner = if (self.effectiveScope()) |scope| scope.owner else null;
        if (owner) |o| o.beginReactiveCallback();
        defer if (owner) |o| o.endReactiveCallback();
        self.ticking = true;
        defer if (guard.isCurrent()) {
            self.ticking = false;
        };
        const revision = self.control_revision;

        if (self.pending_first_tick) {
            self.pending_first_tick = false;
            switch (self.driver) {
                inline else => |*driver| driver.start_time_ms = now_ms - self.seek_elapsed_ms,
            }

            if (self.on_update) |cb| {
                if (self.on_update_ctx) |ctx| {
                    if (@hasDecl(@TypeOf(guard), "beforeCallback")) guard.beforeCallback();
                    cb(self.value, ctx);
                }
            }
            return guard.isCurrent() and !self.scopeIsRetiring() and self.isActive();
        }

        var fixed_frame: ?FixedFrame = null;
        var spring_revision: ?u64 = null;
        sample_driver: switch (self.driver) {
            .tween => |*tw| {
                const frame = self.fixedFrame(now_ms, tw.start_time_ms, milliseconds(tw.duration), milliseconds(tw.delay)) orelse {
                    if (std.math.isFinite(tw.duration) and std.math.isFinite(tw.delay) and now_ms - tw.start_time_ms < milliseconds(tw.delay)) tw.velocity_phase = null;
                    if (publish_delay and std.math.isFinite(tw.duration) and std.math.isFinite(tw.delay) and now_ms - tw.start_time_ms < milliseconds(tw.delay)) break :sample_driver;
                    return true;
                };
                self.value = values.sample(tw.from, tw.to, tw.easing, frame.sample_progress);
                self.progress = frame.progress;
                self.recordTweenVelocity(frame.sample_progress, frame.direction, frame.moving);
                fixed_frame = frame;
            },
            .spring => |*sp| {
                const SpringGuard = struct {
                    host: @TypeOf(guard),
                    controller: *AnimationController,
                    revision: u64,
                    pub fn isCurrent(g: @This()) bool {
                        return g.host.isCurrent() and !g.controller.scopeIsRetiring();
                    }
                    pub fn isUnchanged(g: @This()) bool {
                        return g.controller.control_revision == g.revision;
                    }
                    pub fn beforeCallback(g: @This()) void {
                        if (@hasDecl(@TypeOf(g.host), "beforeCallback")) g.host.beforeCallback();
                    }
                };
                const spring_guard = SpringGuard{ .host = guard, .controller = self, .revision = revision };
                const driver_revision = sp.control_revision;
                spring_revision = driver_revision;
                const duration = sp.settlingDuration();
                const frame = self.fixedFrame(now_ms, sp.start_time_ms, milliseconds(duration), 0);
                // Explicit Timeline seeks can publish the terminal sample before
                // tick delivers its callbacks. Paused/stopped drivers stay so.
                if (sp.state == .completed) sp.state = .running;
                if (sp.state != .running) {
                    self.adoptSpringCommand();
                    return self.isActive();
                }
                if (frame) |phase| {
                    const crossed = now_ms - sp.start_time_ms >= milliseconds(duration);
                    const single_terminal = phase.finished and self.loops -| self.current_loop <= 1;
                    if (crossed and !single_terminal and (sp.config.on_update != null or sp.config.on_complete != null)) {
                        sp.updateDirected(now_ms, duration, self.direction < 0, spring_guard);
                        if (!guard.isCurrent() or self.scopeIsRetiring()) return false;
                        if (self.control_revision == revision and sp.control_revision != driver_revision) self.adoptSpringCommand();
                        if (self.control_revision != revision or sp.control_revision != driver_revision or !self.isActive()) return self.isActive();
                        sp.state = .running;
                    }
                    const seconds: f32 = if (phase.progress >= 1) duration else @floatCast(@max(0, now_ms - phase.start_ms) / 1000);
                    sp.updateDirected(now_ms, seconds, phase.direction < 0, spring_guard);
                    fixed_frame = phase;
                } else {
                    sp.updateDirected(now_ms, @floatCast(@max(0, clock_delta_ms / 1000)), self.direction < 0, spring_guard);
                }
                if (!guard.isCurrent() or self.scopeIsRetiring()) return false;
                if (self.control_revision == revision and sp.control_revision != driver_revision) self.adoptSpringCommand();
                if (self.control_revision != revision or sp.control_revision != driver_revision or !self.isActive()) return self.isActive();
                self.value = sp.getValue();
                self.progress = if (frame) |phase| phase.progress else if (sp.isCompleted()) 1 else 0;
            },
            .keyframes => |*kf| {
                const frame = self.fixedFrame(now_ms, kf.start_time_ms, kf.duration_ms, 0) orelse return true;
                self.value = kf.valueAtProgress(frame.sample_progress);
                self.progress = frame.progress;
                fixed_frame = frame;
            },
        }

        // 触发 update 回调
        if (self.on_update) |cb| {
            if (self.on_update_ctx) |ctx| {
                if (@hasDecl(@TypeOf(guard), "beforeCallback")) guard.beforeCallback();
                cb(self.value, ctx);
            }
        }

        if (!guard.isCurrent() or self.scopeIsRetiring()) return false;
        // An update callback's playback command supersedes this frame's
        // completion decision, even if progress still happens to equal one.
        if (self.control_revision != revision or !self.isActive()) return self.isActive();
        if (spring_revision) |driver_revision| {
            if (self.driver.spring.control_revision != driver_revision) {
                self.adoptSpringCommand();
                return self.isActive();
            }
        }

        if (fixed_frame) |frame| {
            self.current_loop = frame.loop_count;
            self.direction = frame.direction;
            switch (self.driver) {
                .tween => |*driver| driver.start_time_ms = frame.start_ms,
                .keyframes => |*driver| driver.start_time_ms = frame.start_ms,
                .spring => |*driver| driver.start_time_ms = frame.start_ms,
            }
            if (frame.finished) return self.finish(guard, defer_completion);
            return true;
        }

        // An unbounded trajectory only completes through numerical fallback.
        if (self.progress >= 1.0) return self.finish(guard, defer_completion);

        return true;
    }

    /// 是否正在活跃
    pub fn isActive(self: *const AnimationController) bool {
        return self.play_state == .playing;
    }

    /// 是否已完成
    pub fn isCompleted(self: *const AnimationController) bool {
        return self.play_state == .completed;
    }

    /// 获取估算时长（秒）
    pub fn estimatedDuration(self: *const AnimationController) f32 {
        return switch (self.driver) {
            .tween => |tw| tw.duration + tw.delay,
            .keyframes => |kf| kf.duration_ms / 1000.0,
            .spring => |sp| sp.settlingDuration(),
        };
    }

    // ============ 内部 ============

    // Preserve the public f32 seconds-to-ms boundary (0.3s -> 300ms).
    // Use a wide fallback only when the f32 product cannot represent it.
    fn milliseconds(seconds: f32) f64 {
        const rounded = seconds * 1000;
        return if (std.math.isFinite(rounded)) @as(f64, rounded) else @as(f64, seconds) * 1000;
    }

    const FixedFrame = struct {
        progress: f32,
        sample_progress: f32,
        direction: f32,
        loop_count: u32,
        start_ms: f64,
        finished: bool,
        moving: bool = false,
    };

    /// Prepare one sample and its cycle bookkeeping without committing it.
    /// Callback playback commands can supersede the whole prepared transition.
    fn fixedFrame(self: *const AnimationController, now_ms: f64, start_ms: f64, duration: f64, delay: f64) ?FixedFrame {
        return self.fixedFrameFrom(now_ms, start_ms, duration, delay, self.current_loop, self.direction);
    }

    fn fixedFrameFrom(self: *const AnimationController, now_ms: f64, start_ms: f64, duration: f64, delay: f64, completed_loops: u32, initial_direction: f32) ?FixedFrame {
        if (!std.math.isFinite(duration) or !std.math.isFinite(delay)) return null;
        const elapsed = now_ms - start_ms;
        if (elapsed < delay) return null;
        const duration_ms = @max(duration, 0);
        const cycle_ms = duration_ms + delay;
        const cycles = if (cycle_ms > 0) @max(0, @floor(elapsed / cycle_ms)) else 0;
        const remaining = self.loops -| completed_loops;
        const finished = cycle_ms <= 0 or (self.loops > 0 and cycles >= @as(f64, @floatFromInt(remaining)));
        const phase_cycles = if (finished) @as(f64, @floatFromInt(remaining -| 1)) else cycles;
        const direction = if (self.yoyo and @mod(phase_cycles, 2) >= 1) -initial_direction else initial_direction;
        const residual = if (cycle_ms > 0) @mod(@max(0, elapsed), cycle_ms) else 0;
        const waiting = !finished and cycles > 0 and residual < delay;
        const progress: f32 = if (finished or duration_ms <= 0) 1 else @floatCast(std.math.clamp((residual - delay) / duration_ms, 0, 1));
        const sample_direction = if (waiting and self.yoyo) -direction else direction;
        const sample_progress = if (waiting) @as(f32, 1) else progress;
        const room = std.math.maxInt(u32) - completed_loops;
        return .{
            .progress = progress,
            .sample_progress = if (sample_direction < 0) 1 - sample_progress else sample_progress,
            .direction = direction,
            .loop_count = if (finished) self.loops else if (cycles >= @as(f64, @floatFromInt(room))) std.math.maxInt(u32) else completed_loops + @as(u32, @intFromFloat(cycles)),
            .start_ms = if (!finished and cycles > 0) now_ms - residual else start_ms,
            .finished = finished,
            .moving = !waiting and !finished and duration_ms > 0,
        };
    }

    fn finish(self: *AnimationController, guard: anytype, comptime defer_completion: bool) bool {
        self.play_state = .completed;
        if (defer_completion) return false;
        const callback = self.on_complete;
        const callback_ctx = self.on_complete_ctx;
        self.on_complete = null;
        self.on_complete_ctx = null;
        if (callback) |cb| {
            if (callback_ctx) |ctx| {
                if (@hasDecl(@TypeOf(guard), "beforeCallback")) guard.beforeCallback();
                cb(ctx);
            }
        }
        return guard.isCurrent() and !self.scopeIsRetiring() and self.isActive();
    }

    /// NodeAnimations takes a retained copy, not ownership of the hook object.
    /// The receiver must eventually call releaseLifetime. Other raw struct
    /// copies do not automatically retain this reference. The Scope allocator's
    /// backing storage must outlive retained copies, as for any shared allocation.
    pub fn cloneForNode(self: AnimationController) AnimationController {
        var copy = self;
        copy.timeline_owner = null;
        copy.node_owned = false;
        copy.ticking = false;
        if (copy.driver == .spring) copy.driver.spring.updating = false;
        if (copy.scope_lifetime) |lifetime| {
            lifetime.retain();
            copy.lifetime_scope = null;
        }
        return copy;
    }

    pub fn releaseLifetime(self: *AnimationController) void {
        if (self.scope_lifetime) |lifetime| lifetime.release();
        self.scope_lifetime = null;
    }

    pub fn isScopeRetiring(self: *const AnimationController) bool {
        return self.scopeIsRetiring();
    }

    fn effectiveScope(self: *const AnimationController) ?*Scope {
        return if (self.scope_lifetime) |lifetime| lifetime.scope else self.lifetime_scope;
    }

    fn scopeIsRetiring(self: *const AnimationController) bool {
        if (self.scope_lifetime) |lifetime| return lifetime.isRetiring();
        return if (self.lifetime_scope) |scope| scope.willBeDisposedAfterReactiveCallback() else false;
    }

    fn resetDriver(self: *AnimationController) void {
        const now_ms = render_engine.current_frame_time_ms;
        switch (self.driver) {
            .tween => |*tw| {
                tw.start_time_ms = now_ms;
                tw.velocity_phase = null;
            },
            .spring => |*sp| {
                sp.reset();
                sp.start_time_ms = now_ms;
                self.spring_parameter_revision = sp.parameter_revision;
            },
            .keyframes => |*kf| {
                kf.resetWithTime(now_ms);
            },
        }
    }

    /// 在给定进度 [0, 1] 处求值（用于 seek）
    fn evaluateAt(self: *const AnimationController, progress: f32) f32 {
        return switch (self.driver) {
            .tween => |tw| {
                const directed = if (self.direction < 0) 1.0 - progress else progress;
                return values.sample(tw.from, tw.to, tw.easing, directed);
            },
            .keyframes => |kf| kf.valueAtProgress(if (self.direction < 0) 1 - progress else progress),
            .spring => |sp| {
                if (progress >= 1.0) return if (self.direction < 0) sp.from else sp.to;
                if (progress <= 0.0) return if (self.direction < 0) sp.to else sp.from;
                const t_s = progress * sp.settlingDuration();
                return sp.sampleDirected(t_s, self.direction < 0).value;
            },
        };
    }
};

// ========== 测试 ==========

/// 测试辅助：设置全局模拟时间
fn setTestTime(ms: f64) void {
    render_engine.current_frame_time_ms = ms;
}

test "AnimationController: tween basic" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 1.0,
        .easing = .linear,
    });

    ctrl.play();
    try std.testing.expect(ctrl.isActive());

    // 半秒后
    setTestTime(1500.0);
    _ = ctrl.tick(1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), ctrl.value, 1.0);

    // 完成
    setTestTime(2000.0);
    _ = ctrl.tick(2000.0);
    try std.testing.expect(ctrl.isCompleted());
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), ctrl.value, 1.0);
}

test "AnimationController: first tick arms start time without consuming progress" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 1.0,
        .easing = .linear,
    });

    ctrl.playPendingFirstTick();

    setTestTime(1250.0);
    _ = ctrl.tick(1250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ctrl.progress, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ctrl.value, 0.0001);

    setTestTime(1500.0);
    _ = ctrl.tick(1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), ctrl.progress, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), ctrl.value, 0.0001);
}

test "AnimationController: pause and resume" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 1.0,
        .easing = .linear,
    });

    ctrl.play();
    setTestTime(1250.0);
    _ = ctrl.tick(1250.0);
    const paused_value = ctrl.value;

    ctrl.pause();
    try std.testing.expect(!ctrl.isActive());

    // tick 不应该改变值（paused 状态 tick 返回 false）
    setTestTime(1750.0);
    _ = ctrl.tick(1750.0);
    try std.testing.expectEqual(paused_value, ctrl.value);

    ctrl.unpause();
    try std.testing.expect(ctrl.isActive());

    setTestTime(2000.0);
    _ = ctrl.tick(2000.0);
    try std.testing.expect(ctrl.value > paused_value);
}

test "AnimationController: seek" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 1.0,
        .easing = .linear,
    });

    ctrl.seek(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), ctrl.value, 1.0);

    ctrl.seek(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ctrl.value, 1.0);

    ctrl.seek(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), ctrl.value, 1.0);
}

test "AnimationController: yoyo" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 0.5,
        .easing = .linear,
    });
    ctrl.loops = 2;
    ctrl.yoyo = true;

    ctrl.play();

    // 第一次正向
    setTestTime(1500.0);
    _ = ctrl.tick(1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), ctrl.value, 1.0);

    // 第二次反向 (yoyo), resetDriver 会重置 start_time_ms 到 current_frame_time_ms
    setTestTime(2000.0);
    _ = ctrl.tick(2000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ctrl.value, 1.0);

    try std.testing.expect(ctrl.isCompleted());
}

test "AnimationController: yoyo 完成后裸 play() 重放必须从 from 正向开始" {
    // 回归：yoyo 结束时 direction 停在 -1，play() 的 was_completed 块只复位
    // progress/current_loop 不复位 direction，重放从 to 倒播到 from。
    // （restart() 因 stop() 复位 direction 而幸免，裸 play() 中招）
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 0.5,
        .easing = .linear,
    });
    ctrl.loops = 2;
    ctrl.yoyo = true;

    ctrl.play();
    setTestTime(1500.0);
    _ = ctrl.tick(1500.0);
    setTestTime(2000.0);
    _ = ctrl.tick(2000.0);
    try std.testing.expect(ctrl.isCompleted());

    // 裸 play() 重放：中点应在 from->to 的正向路径上（≈50），倒播则 ≈50 也一样……
    // 所以采样 1/5 处：正向 ≈20，倒播 ≈80
    setTestTime(3000.0);
    ctrl.play();
    setTestTime(3100.0);
    _ = ctrl.tick(3100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), ctrl.value, 2.0);
}

test "AnimationController: 绝对时间模型下 Tween 正确完成" {
    // time_scale/setTimeScale 已删除：绝对时间戳模型下它是写入无人读的
    // 死代码（tick 全程从 now_ms 派生），setTimeScale(2.0) 静默无效比
    // 没有这个 API 更糟。倍速语义由 Timeline.time_scale 承担。
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 1.0,
        .easing = .linear,
    });

    ctrl.play();
    setTestTime(2000.0);
    _ = ctrl.tick(2000.0);
    try std.testing.expect(ctrl.isCompleted());
}

test "AnimationController: spring driver" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initSpring(.{
        .from = 0,
        .to = 100,
        .stiffness = 500,
        .damping = 50,
    });

    ctrl.play();
    try std.testing.expect(ctrl.isActive());

    // 运行足够帧（Spring 用绝对时间戳）
    const dt_ms: f32 = 1000.0 / 60.0;
    var now: f64 = 1000.0;
    var i: usize = 0;
    while (i < 300 and ctrl.isActive()) : (i += 1) {
        now += dt_ms;
        setTestTime(now);
        _ = ctrl.tick(now);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 100.0), ctrl.value, 0.1);
    try std.testing.expect(ctrl.isCompleted());
}

test "AnimationController: keyframes driver" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initKeyframes(&.{
        .{ .progress = 0.0, .value = 0, .easing = .linear },
        .{ .progress = 0.5, .value = 100, .easing = .linear },
        .{ .progress = 1.0, .value = 50, .easing = .linear },
    }, 1000);

    ctrl.play();

    // 25% (在 [0, 0.5] 段，局部 50%) -> value ≈ 50
    setTestTime(1250.0);
    _ = ctrl.tick(1250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), ctrl.value, 2.0);
}

test "AnimationController: callback" {
    setTestTime(1000.0);
    const State = struct {
        last_value: f32 = 0,
        completed: bool = false,
    };
    var state = State{};

    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 0.5,
        .easing = .linear,
    });
    ctrl.on_update = struct {
        fn handler(v: f32, ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.last_value = v;
        }
    }.handler;
    ctrl.on_update_ctx = @ptrCast(&state);
    ctrl.on_complete = struct {
        fn handler(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.completed = true;
        }
    }.handler;
    ctrl.on_complete_ctx = @ptrCast(&state);

    ctrl.play();
    setTestTime(1250.0);
    _ = ctrl.tick(1250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), state.last_value, 1.0);

    setTestTime(1500.0);
    _ = ctrl.tick(1500.0);
    try std.testing.expect(state.completed);
}

test "AnimationController: restart" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 0.5,
        .easing = .linear,
    });

    ctrl.play();
    setTestTime(1500.0);
    _ = ctrl.tick(1500.0);
    try std.testing.expect(ctrl.isCompleted());

    ctrl.restart();
    try std.testing.expect(ctrl.isActive());
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ctrl.value, 1.0);
}

test "AnimationController: infinite loops" {
    setTestTime(1000.0);
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 10,
        .duration = 0.1,
        .easing = .linear,
    });
    ctrl.loops = 0; // 无限

    ctrl.play();
    const dt_ms: f32 = 1000.0 / 60.0;
    var now: f64 = 1000.0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        now += dt_ms;
        setTestTime(now);
        _ = ctrl.tick(now);
    }
    // 应该仍在播放
    try std.testing.expect(ctrl.isActive());
}

test "AnimationController: estimatedDuration" {
    const ctrl_tween = AnimationController.initTween(.{ .duration = 0.5, .delay = 0.1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), ctrl_tween.estimatedDuration(), 0.001);

    const ctrl_spring = AnimationController.initSpring(.{ .from = 1, .to = 0, .mass = 1, .stiffness = 1, .damping = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 6.638352), ctrl_spring.estimatedDuration(), 0.00001);
}
