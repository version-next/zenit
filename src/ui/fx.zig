/// fx — zenit 动画 / 物理 / 过渡
///
/// 把动画、弹性物理、视图过渡（VTAPI-style snapshot transition）、router 这类
/// "运动 / 过渡领域" 的功能集中到一个子命名空间，与组件库（widgets）和核心
/// （ui）分开。
///
/// 用法：
/// ```zig
/// const ui = @import("ui");
///
/// const opacity = ui.fx.AnimatedValue(f32).init(.{ ... });
/// const tween = ui.fx.Tween.init(.{ ... });
/// const router = try ui.fx.Router.init(...);
/// ```
const animation_mod = @import("animation/mod.zig");
const physics_mod = @import("physics.zig");
const snapshot_transition_mod = @import("snapshot_transition.zig");
const timeline_profiler_mod = @import("timeline_profiler.zig");
const router_mod = @import("router.zig");

// 子模块直通
pub const animation = animation_mod;
pub const physics = physics_mod;
pub const snapshot_transition = snapshot_transition_mod;
pub const timeline_profiler = timeline_profiler_mod;
pub const router = router_mod;

// ── 动画原语 ──
pub const Tween = animation_mod.Tween;
pub const Spring = animation_mod.Spring;
pub const AnimatedValue = animation_mod.AnimatedValue;
pub const AnimatedColor = animation_mod.AnimatedColor;
pub const AnimatedColorConfig = animation_mod.AnimatedColorConfig;
pub const KeyframeAnimation = animation_mod.KeyframeAnimation;
pub const AnimationController = animation_mod.AnimationController;
pub const Timeline = animation_mod.Timeline;
pub const Position = animation_mod.Position;
pub const Easing = animation_mod.Easing;

// ── 物理 ──
pub const RubberBand = physics_mod.RubberBand;
pub const FadeIndicator = physics_mod.FadeIndicator;

// ── 视图过渡（snapshot-based view transitions）──
pub const Transition = snapshot_transition_mod.Transition;
pub const SnapshotTransition = snapshot_transition_mod.SnapshotTransition;

// ── 时间线分析 ──
pub const TimelineProfiler = timeline_profiler_mod.TimelineProfiler;

// ── Router ──
pub const Router = router_mod.Router;
