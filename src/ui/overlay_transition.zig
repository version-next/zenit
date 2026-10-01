//! 浮层 enter/exit 过渡的时钟与曲线表，从 `overlay_stack.zig` 析出。
//!
//! 原本 `TransitionController`（含 duration/easing/maxStep/hiddenScale 四张
//! 表）与 `Transition` 枚举一起长在 overlay_stack.zig 里，和层栈管理混排。
//! 这组东西只被这三样东西触碰：
//!   - `Transition` 枚举（LayerConfig 的 enter/exit_transition 字段）
//!   - `TransitionController` 的 progress 状态（OverlayLayer 上的
//!     enter_ctrl / exit_ctrl 两个实例字段）
//!   - `apply()` 往节点上写 opacity/translate/scale（节点树侧唯一的接触面）
//! 互相自洽、不依赖层栈的任何字段，判据 (a) 成立。
//!
//! **接口切在「层间关系」与「单层动画时钟」之间**：tier/嵌套继承/互斥组/
//! outside-click/焦点归还仍属 overlay_stack.zig（它们需要整栈视野）；
//! 本模块只回答「这一层此刻该是什么 progress、画成什么样式」。
//!
//! **不搬的东西**：
//!   - `holdEnterUntilGeometryStable`，它读写 OverlayLayer 的
//!     enter_last_content_rect / enter_stable_frame_count / enter_paused，
//!     是层状态机的一部分，拆出去反而要把 layer 字段掏空。
//!   - `setManualTransitionFlags`，直接写 Node.frame_state 的 manual
//!     动画标志，语义上属于「节点脏位协议」，不是过渡时钟。
//!
//! 依赖注入而非硬 import：缓动曲线表（Easing）与节点类型都从各自的小
//! 模块直接引入，**不 import core.zig**, core.zig 反向 import 本模块的
//! 使用方（overlay_stack.zig），硬 import 会成环。时钟方面只消费
//! `render_engine.current_frame_dt_ms` 一个只读全局（首帧 dt），因此
//! 本模块可以在纯 Zig 单测里跑完整个时序，不拉起节点树 / 渲染引擎。
//!
//! 保留的坑（都来自原始实现的实测教训，勿改）：
//!   1. 首帧 pending_first_tick 用 `current_frame_dt_ms` 而不是
//!      `now - start_time_ms`：initWithTime 的 now 通常是 push 那一帧的
//!      时间戳，动画真正开始渲染在下一帧，直接做差会把两帧间隔算进去，
//!      丢掉入场第一帧。
//!   2. enter_delay 走 wall-clock（不受 maxStepMs 截断）：掉帧时
//!      maxStepMs 会把 delta 压小，若延迟也被截断，200ms 的 tooltip
//!      delay 会被拖成秒级。
//!   3. exit 时长 ≈ enter × 0.7：关闭是用户已做出的决定。
//!   4. enter 中途退场必须 `seedFromProgress` 从当前 progress 起播，
//!      否则 progress 跳到 1.0 全量闪现一帧。

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("core/node.zig");
const Node = node_mod.Node;
const easing_mod = @import("animation/easing.zig");
const Easing = easing_mod.Easing;
// 只为 `current_frame_dt_ms` 这一个只读帧时钟全局（见 update 的
// pending_first_tick 分支）。行为零变化的要求下这一步不能改成参数注入
// 生产调用点 `ctrl.update(now_ms)` 遍布 overlay_stack / 组件层。
const render_engine = @import("core/render_engine/mod.zig");

/// 过渡动画预设（LayerConfig.enter_transition / exit_transition 的类型）。
pub const Transition = enum {
    none,
    fade,
    /// 更短 duration 的 fade，适合 autocomplete / inline hint 这类需要"即刻"感的 popup
    fade_fast,
    scale_fade,
    /// 锚定下拉面板（通知中心这类 dropdown）：160ms ease-out 入场 / 120ms 退场，
    /// opacity + scale 0.98（原点在锚点一侧）。6px 的贴锚点滑入由 Popover 的
    /// 定位器叠加（它独占 translate），见 popover `dropdownSlideOffset`。
    dropdown,
    slide_bottom,
    slide_right,
    slide_left,
    slide_top,
};

/// 过渡动画控制器
pub const TransitionController = struct {
    transition: Transition,
    /// 0.0 = hidden, 1.0 = fully visible
    progress: f32,
    /// 首次 tick 只锚定当前帧时间，避免丢掉第一帧。
    pending_first_tick: bool = false,
    direction: Direction,
    /// 动画开始的绝对时间戳（ms）
    start_time_ms: f64 = 0,
    elapsed_ms: f32 = 0,
    last_tick_time_ms: f64 = 0,
    /// 入场延迟的剩余量（ms）：>0 时 update() 先消耗它、progress 钉在 0。
    /// 延迟按 wall-clock（原始帧间隔）消耗，不受 maxStepMs 截断，
    /// 掉帧不会把 200ms 的延迟拖成秒级。
    delay_remaining_ms: f32 = 0,
    /// `.dropdown` 专用：未显示时相对静止位的位移（px，方向 = 离开锚点）。
    /// 由宿主（Popover 定位器，它知道实际落位）每帧写入；apply 按 opacity
    /// 进度把 translate 增量推进，与 opacity 同帧，不落后一帧。
    slide: [2]f32 = .{ 0, 0 },

    const Direction = enum { entering, exiting };

    /// 获取过渡的时长（ms）。
    /// 退场统一比入场短：关闭是用户已做出的决定，不该让 UI 拖住他
    ///（Radix/Material 的通用做法：exit ≈ enter × 0.7）。
    fn durationMs(transition: Transition, direction: Direction) f32 {
        return switch (transition) {
            .none => 0,
            .fade => switch (direction) {
                .entering => 150,
                .exiting => 110,
            },
            .fade_fast => switch (direction) {
                .entering => 120,
                .exiting => 90,
            },
            .scale_fade => switch (direction) {
                .entering => 200,
                .exiting => 140,
            },
            .dropdown => switch (direction) {
                .entering => 160,
                .exiting => 120,
            },
            .slide_bottom, .slide_right, .slide_left, .slide_top => switch (direction) {
                .entering => 300,
                .exiting => 220,
            },
        };
    }

    /// 获取过渡的缓动函数（作用在 progress 上）。
    /// progress 入场 0->1、退场 1->0 线性推进；对 progress 施加 ease-out 后，
    /// 入场读作 decelerate（快进慢停），退场自然读作 accelerate（慢起快出）,
    /// 正是 Material motion 对 enter/exit 的标准配对，无需单独的 exit 曲线。
    fn transitionEasing(transition: Transition) Easing {
        return switch (transition) {
            .none => .linear,
            .fade, .fade_fast => .ease_out_quad,
            .scale_fade, .dropdown => .ease_out_cubic,
            // iOS sheet 手感：初速度大、长尾减速，比 cubic 更"顺滑地刹住"。
            .slide_bottom, .slide_right, .slide_left, .slide_top => .ease_out_quint,
        };
    }

    fn maxStepMs(transition: Transition) f32 {
        return switch (transition) {
            .none => 0,
            .fade, .fade_fast => 24,
            .scale_fade, .dropdown => 24,
            .slide_bottom, .slide_right, .slide_left, .slide_top => 24,
        };
    }

    pub fn hiddenScaleForTransition(transition: Transition) f32 {
        return switch (transition) {
            // 主流浮层的 scale 幅度是 0.95~0.97 的轻微 pop（Radix data-state
            // animation、macOS NSPopover 同量级）；0.86 的旧值读作"飞入"，
            // 且大幅 scale 会放大动画期的文本重采样伪影。
            .scale_fade => 0.95,
            .dropdown => 0.98,
            else => 1.0,
        };
    }

    pub fn init(transition: Transition, direction: Direction) TransitionController {
        return .{
            .transition = transition,
            .progress = switch (direction) {
                .entering => 0.0,
                .exiting => 1.0,
            },
            .direction = direction,
            // start_time_ms 默认 0，运行时通过 initWithTime 或在使用前手动设置
        };
    }

    /// 运行时创建，记录当前帧绝对时间戳
    pub fn initWithTime(transition: Transition, direction: Direction, now_ms: f64) TransitionController {
        var ctrl = init(transition, direction);
        ctrl.start_time_ms = now_ms;
        ctrl.last_tick_time_ms = now_ms;
        ctrl.pending_first_tick = transition != .none;
        return ctrl;
    }

    /// 推进动画（绝对时间戳驱动）。返回 true = 动画完成。
    ///
    /// pending_first_tick 那一步消费的是 `render_engine.current_frame_dt_ms`
    /// （当前帧的 dt）而不是 `now - start_time_ms`，原因见模块头坑 1。
    pub fn update(self: *TransitionController, now_ms: f64) bool {
        if (self.transition == .none) return true;

        const dur = durationMs(self.transition, self.direction);

        if (dur <= 0) return true;

        var raw_delta = if (self.pending_first_tick)
            render_engine.current_frame_dt_ms
        else
            @as(f32, @floatCast(now_ms - self.last_tick_time_ms));
        self.pending_first_tick = false;
        self.last_tick_time_ms = now_ms;

        if (self.delay_remaining_ms > 0) {
            const consumed = @min(@max(raw_delta, 0.0), self.delay_remaining_ms);
            self.delay_remaining_ms -= consumed;
            raw_delta -= consumed;
            if (self.delay_remaining_ms > 0) return false;
        }

        const delta = std.math.clamp(raw_delta, 0.0, maxStepMs(self.transition));
        self.elapsed_ms = std.math.clamp(self.elapsed_ms + delta, 0.0, dur);
        const raw_progress = std.math.clamp(self.elapsed_ms / dur, 0.0, 1.0);

        switch (self.direction) {
            .entering => {
                self.progress = raw_progress;
                return self.progress >= 1.0;
            },
            .exiting => {
                self.progress = 1.0 - raw_progress;
                return self.progress <= 0.0;
            },
        }
    }

    /// 根据当前 progress 应用样式到节点
    pub fn apply(self: *const TransitionController, node: *Node, allocator: Allocator) void {
        if (self.transition == .none) return;

        const ease = transitionEasing(self.transition);
        const opacity_t = ease.apply(self.progress);

        switch (self.transition) {
            .none => {},
            .fade, .fade_fast => {
                node.setOpacityRaw(opacity_t);
            },
            .dropdown => {
                // 宿主独占 translate（Popover 每帧写静止位 + 当前偏移）：这里只推进
                // 增量 = 新偏移 − 旧偏移（旧偏移由节点当前 opacity 反推），同帧生效。
                const old_t = std.math.clamp(node.getOpacity(), 0, 1);
                node.setOpacityRaw(opacity_t);
                const start_scale = hiddenScaleForTransition(self.transition);
                const s = start_scale + (1.0 - start_scale) * opacity_t;
                const ext = node.style.ensureExtPanic(allocator);
                ext.scale_x = s;
                ext.scale_y = s;
                node.style.translate_x += self.slide[0] * ((1 - opacity_t) - (1 - old_t));
                node.style.translate_y += self.slide[1] * ((1 - opacity_t) - (1 - old_t));
            },
            .scale_fade => {
                // scale 幅度收窄到 0.95 后，front-load 不再产生"首帧极小极淡"的
                // 伪影，opacity 与 scale 可以共用同一条 ease-out 曲线，整组读作
                // 一次连贯的 pop（旧的线性 scale 会让动画后半段拖沓）。
                node.setOpacityRaw(opacity_t);
                const start_scale = hiddenScaleForTransition(self.transition);
                const s = start_scale + (1.0 - start_scale) * opacity_t;
                const ext = node.style.ensureExtPanic(allocator);
                ext.scale_x = s;
                ext.scale_y = s;
            },
            .slide_bottom => {
                node.setOpacityRaw(slideOpacity(self.progress));
                // 全局 hook 读 rect。
                const r = node.rectFromWorldOrFallback();
                const offset = (1.0 - opacity_t) * r.h;
                node.style.translate_y = offset;
            },
            .slide_right => {
                node.setOpacityRaw(slideOpacity(self.progress));
                const r = node.rectFromWorldOrFallback();
                const offset = (1.0 - opacity_t) * r.w;
                node.style.translate_x = offset;
            },
            .slide_left => {
                node.setOpacityRaw(slideOpacity(self.progress));
                const r = node.rectFromWorldOrFallback();
                const offset = -(1.0 - opacity_t) * r.w;
                node.style.translate_x = offset;
            },
            .slide_top => {
                node.setOpacityRaw(slideOpacity(self.progress));
                const r = node.rectFromWorldOrFallback();
                const offset = -(1.0 - opacity_t) * r.h;
                node.style.translate_y = offset;
            },
        }
        // Overlay enter/exit transitions here only touch compositor-managed
        // properties (opacity / translate / scale). Marking render-dirty on every
        // frame would force the subtree content to rebuild and defeat promoted
        // surface reuse, which is exactly what causes text to shimmer during the
        // scale_fade animation. Keep this to interaction + composite dirtiness.
        node.markCompositeAnimFrameDirty();
    }

    /// slide 类的内容透明度：在位移前 45% 就完成淡入/最后 45% 才开始淡出。
    /// 主流 sheet 的手感是"实体面板滑入 + backdrop 单独 fade"，内容全程
    /// 跟随位移淡入会显得糊；完全不淡入则首帧突兀，取前段快速 ramp 折中。
    fn slideOpacity(progress: f32) f32 {
        const t = std.math.clamp(progress / 0.45, 0.0, 1.0);
        return 1 - (1 - t) * (1 - t);
    }

    /// 让动画从指定 progress 起播（而非端点）。用于 enter 中途反向退场：
    /// exit 从当前 enter progress 开始，避免"progress 跳到 1.0 全量闪现"。
    pub fn seedFromProgress(self: *TransitionController, p0: f32) void {
        const dur = durationMs(self.transition, self.direction);
        if (dur <= 0) return;
        const p = std.math.clamp(p0, 0.0, 1.0);
        self.progress = p;
        self.elapsed_ms = switch (self.direction) {
            .entering => p * dur,
            .exiting => (1.0 - p) * dur,
        };
    }

    pub fn isComplete(self: *const TransitionController) bool {
        if (self.transition == .none) return true;
        return switch (self.direction) {
            .entering => self.progress >= 1.0,
            .exiting => self.progress <= 0.0,
        };
    }

    pub fn currentOpacity(self: *const TransitionController) f32 {
        if (!transitionAffectsOpacity(self.transition)) return 1.0;
        return transitionEasing(self.transition).apply(self.progress);
    }
};

/// 该过渡是否影响 opacity（决定 LayerConfig 是否需要 composited_group
/// surface、manual_opacity_animation_active 标志等）。
pub fn transitionAffectsOpacity(transition: Transition) bool {
    return switch (transition) {
        .none => false,
        .fade, .fade_fast, .scale_fade, .dropdown, .slide_bottom, .slide_right, .slide_left, .slide_top => true,
    };
}

/// 该过渡是否影响 transform（translate / scale）。
pub fn transitionAffectsTransform(transition: Transition) bool {
    return switch (transition) {
        .scale_fade, .dropdown, .slide_bottom, .slide_right, .slide_left, .slide_top => true,
        .none, .fade, .fade_fast => false,
    };
}

/// 层配置是否需要 composited_group surface（任一方向过渡影响 opacity 或
/// transform 即需要）。原来是无调用者的私有 helper，析出时保留，它是
/// 「为什么 bindContentNode 无条件开 composited_group 是安全的」这组
/// 判定表的唯一表驱动表达，tier/z 序改动会先碰这里。
pub fn layerNeedsCompositedGroup(enter: Transition, exit: Transition) bool {
    return transitionAffectsOpacity(enter) or
        transitionAffectsTransform(enter) or
        transitionAffectsOpacity(exit) or
        transitionAffectsTransform(exit);
}

// ── 测试 ───────────────────────────────────────────────────────────────
// ⚠ 收集方式：经由 overlay_stack.zig 末尾的 `test { _ = @import("overlay_transition.zig"); }`
// 登记（refAllDecls 不会递归收集 test 块，见 build.zig:556-570 的同类注释）。

test "TransitionController: fade enter" {
    // fade duration is 150 ms (see durationMs).
    var ctrl = TransitionController.initWithTime(.fade, .entering, 100.0);
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);

    // First update consumes `current_frame_dt_ms` (pending_first_tick path)
    // rather than (now - start), so 16ms / 150ms ≈ 0.107.
    render_engine.current_frame_dt_ms = 16.0;
    _ = ctrl.update(175.0);
    try std.testing.expect(ctrl.progress > 0.05 and ctrl.progress < 0.2);
    try std.testing.expect(!ctrl.isComplete());

    // Subsequent updates use (now - last_tick): 250 - 175 = 75ms, but
    // maxStepMs(.fade) = 24ms clamps each step to prevent jank from large
    // gaps. So elapsed = 16 + 24 = 40ms, progress ≈ 0.267.
    _ = ctrl.update(250.0);
    try std.testing.expect(ctrl.progress > 0.2 and ctrl.progress < 0.35);
    try std.testing.expect(!ctrl.isComplete());

    // Each update clamps the step to maxStepMs (24ms for fade), so reaching
    // completion requires several frame-sized ticks rather than one huge gap.
    var t: f64 = 250.0;
    var safety: u32 = 0;
    while (!ctrl.isComplete() and safety < 64) : (safety += 1) {
        t += 16.0;
        _ = ctrl.update(t);
    }
    try std.testing.expect(ctrl.isComplete());
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.progress);
}

test "TransitionController: fade exit" {
    // fade exit duration is 110 ms, maxStepMs(.fade) = 24 ms.
    var ctrl = TransitionController.initWithTime(.fade, .exiting, 100.0);
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.progress);

    // First update: pending_first_tick path uses current_frame_dt_ms (16ms).
    // For .exiting: progress = 1.0 - 16/110 ≈ 0.855.
    render_engine.current_frame_dt_ms = 16.0;
    _ = ctrl.update(175.0);
    try std.testing.expect(ctrl.progress > 0.8 and ctrl.progress < 1.0);
    try std.testing.expect(!ctrl.isComplete());

    // Second update: clamp step to 24ms. elapsed = 16 + 24 = 40, progress
    // = 1.0 - 40/110 ≈ 0.636.
    _ = ctrl.update(250.0);
    try std.testing.expect(ctrl.progress > 0.6 and ctrl.progress < 0.85);
    try std.testing.expect(!ctrl.isComplete());

    // Drive to completion via clamped frame-sized ticks.
    var t: f64 = 250.0;
    var safety: u32 = 0;
    while (!ctrl.isComplete() and safety < 64) : (safety += 1) {
        t += 16.0;
        _ = ctrl.update(t);
    }
    try std.testing.expect(ctrl.isComplete());
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
}

test "TransitionController: none is instant" {
    var ctrl = TransitionController.initWithTime(.none, .entering, 100.0);
    const done = ctrl.update(101.0);
    try std.testing.expect(done);
    try std.testing.expect(ctrl.isComplete());
}

test "TransitionController: enter delay holds progress at 0 then animates" {
    var ctrl = TransitionController.initWithTime(.scale_fade, .entering, 0);
    ctrl.delay_remaining_ms = 200;

    // 延迟期内（~200ms，12 帧 × 16ms = 192ms）：progress 钉在 0，动画未完成
    var now_ms: f64 = 0;
    for (0..12) |_| {
        now_ms += 16.0;
        try std.testing.expect(!ctrl.update(now_ms));
        try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
    }

    // 继续推进：延迟耗尽后动画开始，progress 单调上升直至完成
    var last_progress: f32 = 0;
    var completed = false;
    for (0..20) |_| {
        now_ms += 16.0;
        completed = ctrl.update(now_ms);
        try std.testing.expect(ctrl.progress + 0.0001 >= last_progress);
        last_progress = ctrl.progress;
        if (completed) break;
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.progress);
}

test "TransitionController: seedFromProgress starts exit from mid-enter progress" {
    // enter 进行到一半时退场：exit 应从 0.5 起播，而非 1.0 闪现
    var exit_ctrl = TransitionController.initWithTime(.scale_fade, .exiting, 0);
    exit_ctrl.seedFromProgress(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), exit_ctrl.progress);

    // 延迟持有期（progress=0）退场：首次 update 即完成，浮层立即消失
    var exit_from_hidden = TransitionController.initWithTime(.scale_fade, .exiting, 0);
    exit_from_hidden.seedFromProgress(0.0);
    try std.testing.expectEqual(@as(f32, 0.0), exit_from_hidden.progress);
    try std.testing.expect(exit_from_hidden.update(16.0));
}

test "enter delay 按 wall-clock 消耗，掉帧的大步不被 maxStepMs 截短" {
    // 坑 2 的钉子：delay 剩 84ms 时来了一帧 100ms，必须整帧吃掉 84ms 并
    // 当场溢出进入动画。若 delay 也被 maxStepMs(24) 截断，这一帧只会
    // 消耗 24ms，progress 仍钉在 0, tooltip delay 在掉帧时被拉长。
    var ctrl = TransitionController.initWithTime(.fade, .entering, 0);
    ctrl.delay_remaining_ms = 100;
    render_engine.current_frame_dt_ms = 16.0;
    _ = ctrl.update(16.0); // pending_first_tick 走 dt：消耗 16，剩 84
    try std.testing.expect(ctrl.delay_remaining_ms > 0);
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);

    _ = ctrl.update(116.0); // 100ms 的一帧：delay 按 wall-clock 清零并溢出
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.delay_remaining_ms);
    try std.testing.expect(ctrl.progress > 0.0); // 溢出的 16ms 已进入动画
}

test "exit duration 比 enter 短（exit ≈ enter × 0.7）" {
    render_engine.current_frame_dt_ms = 16.0;
    var enter = TransitionController.initWithTime(.fade, .entering, 0);
    var exit_ = TransitionController.initWithTime(.fade, .exiting, 0);
    // 走完整时长后比较 elapsed_ms（clamp 到 dur）：exit 必须短于 enter。
    var t: f64 = 0;
    while (!enter.isComplete()) : (t += 16.0) {
        _ = enter.update(t);
    }
    var t2: f64 = 0;
    while (!exit_.isComplete()) : (t2 += 16.0) {
        _ = exit_.update(t2);
    }
    try std.testing.expect(exit_.elapsed_ms < enter.elapsed_ms);
}

test "maxStepMs 钳制：一次 1000ms 的大步只推进一帧的量" {
    render_engine.current_frame_dt_ms = 16.0;
    var a = TransitionController.initWithTime(.fade, .entering, 0);
    _ = a.update(16.0); // first tick: 16ms
    var b = TransitionController.initWithTime(.fade, .entering, 0);
    _ = b.update(16.0); // first tick: 16ms
    _ = b.update(1016.0); // 一个 1000ms 的大步 → 只加 24ms
    try std.testing.expect(b.elapsed_ms == a.elapsed_ms + 24);
    try std.testing.expect(!b.isComplete());
}

test "hiddenScaleForTransition 只有 scale_fade 收缩" {
    try std.testing.expectEqual(@as(f32, 0.95), TransitionController.hiddenScaleForTransition(.scale_fade));
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.fade));
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.slide_bottom));
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.none));
}

test "transitionAffectsOpacity / Transform / layerNeedsCompositedGroup 的表" {
    try std.testing.expect(!transitionAffectsOpacity(.none));
    try std.testing.expect(transitionAffectsOpacity(.fade));
    try std.testing.expect(transitionAffectsOpacity(.fade_fast));
    try std.testing.expect(transitionAffectsOpacity(.scale_fade));
    try std.testing.expect(transitionAffectsOpacity(.slide_top));
    try std.testing.expect(!transitionAffectsTransform(.fade));
    try std.testing.expect(transitionAffectsTransform(.scale_fade));
    try std.testing.expect(transitionAffectsTransform(.slide_left));
    try std.testing.expect(!transitionAffectsTransform(.none));

    // 任一方向有动画 -> 需要 composited_group；双向 .none -> 不需要
    try std.testing.expect(!layerNeedsCompositedGroup(.none, .none));
    try std.testing.expect(layerNeedsCompositedGroup(.fade, .none));
    try std.testing.expect(layerNeedsCompositedGroup(.none, .fade_fast));
    try std.testing.expect(layerNeedsCompositedGroup(.scale_fade, .scale_fade));
}

test "currentOpacity 在 .none 时恒 1.0" {
    var ctrl = TransitionController.initWithTime(.none, .entering, 0);
    ctrl.progress = 0.0;
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.currentOpacity());
}

test "enter 中途反向：exit seed 后继续单调走向 0" {
    render_engine.current_frame_dt_ms = 16.0;
    var exit_ctrl = TransitionController.initWithTime(.fade, .exiting, 0);
    exit_ctrl.seedFromProgress(0.7);
    var last: f32 = exit_ctrl.progress;
    var done = false;
    var t: f64 = 0;
    for (0..32) |_| {
        t += 16.0;
        done = exit_ctrl.update(t);
        try std.testing.expect(exit_ctrl.progress <= last + 0.0001);
        last = exit_ctrl.progress;
        if (done) break;
    }
    try std.testing.expect(done);
    try std.testing.expectEqual(@as(f32, 0.0), exit_ctrl.progress);
}
