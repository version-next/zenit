/// Animation Module — Zenit UI 动画系统
///
/// 架构分层:
///
/// ┌─────────────────────────────────────────────────┐
/// │  Presets (fadeIn/slideUp/scaleIn/shake/...)      │ 预设动画
/// ├─────────────────────────────────────────────────┤
/// │  Hooks (useAnimation/useTimeline/...)            │ Scope 声明式
/// ├─────────────────────────────────────────────────┤
/// │  animateNode (节点命令式动画)                     │ 节点属性动画
/// ├─────────────────────────────────────────────────┤
/// │  Timeline + Position (GSAP 风格编排)             │ 时间线
/// ├─────────────────────────────────────────────────┤
/// │  AnimationController (统一播放控制)               │ 控制器
/// ├─────────────────────────────────────────────────┤
/// │  AnimationManager (全局管理)                     │ 全局
/// ├─────────────────────────────────────────────────┤
/// │  Tween / Spring / Transition / Keyframes         │ 底层驱动
/// ├─────────────────────────────────────────────────┤
/// │  Easing (31 预设 + CubicBezier)                  │ 缓动函数
/// └─────────────────────────────────────────────────┘
///
/// 设计原则:
/// 1. 帧驱动: 每帧调用 tick(delta_time)
/// 2. 声明式 + 命令式: TransitionSlots 自动过渡 + animateNode 主动控制
/// 3. 可组合: Timeline 编排 + Position 相对定位
const std = @import("std");

// ── 底层驱动 ──

pub const tween = @import("tween.zig");
pub const Tween = tween.Tween;
pub const TweenConfig = tween.TweenConfig;

pub const spring = @import("spring.zig");
pub const Spring = spring.Spring;
pub const SpringConfig = spring.SpringConfig;
pub const SpringPreset = spring.SpringPreset;

pub const easing = @import("easing.zig");
pub const Easing = easing.Easing;
pub const CubicBezierParams = easing.CubicBezierParams;

pub const transition = @import("transition.zig");
pub const Transition = transition.Transition;
pub const TransitionConfig = transition.TransitionConfig;

pub const animated_value = @import("animated_value.zig");
pub const AnimatedValue = animated_value.AnimatedValue;

pub const animated_color = @import("animated_color.zig");
pub const AnimatedColor = animated_color.AnimatedColor;
pub const AnimatedColorConfig = animated_color.AnimatedColorConfig;

pub const keyframes = @import("keyframes.zig");
pub const Keyframe = keyframes.Keyframe;
pub const KeyframeAnimation = keyframes.KeyframeAnimation;

// ── 控制器 ──

pub const controller = @import("controller.zig");
pub const AnimationController = controller.AnimationController;
pub const PlayState = controller.PlayState;

// ── 时间线 ──

pub const timeline_mod = @import("timeline.zig");
pub const Timeline = timeline_mod.Timeline;
pub const Position = timeline_mod.Position;
pub const TimelineEntry = timeline_mod.TimelineEntry;

// ── 节点动画 ──

pub const node_animator = @import("node_animator.zig");
pub const NodeAnimations = node_animator.NodeAnimations;
pub const AnimatableProp = node_animator.AnimatableProp;
pub const AnimateConfig = node_animator.AnimateConfig;
pub const animateNode = node_animator.animateNode;

// ── 全局管理 ──

pub const manager = @import("manager.zig");
pub const AnimationManager = manager.AnimationManager;

// ── Hooks ──

pub const anim_hooks = @import("anim_hooks.zig");
pub const useAnimation = anim_hooks.useAnimation;
pub const useSpringAnimation = anim_hooks.useSpringAnimation;
pub const useTimeline = anim_hooks.useTimeline;

// ── 预设 ──

pub const presets = @import("presets.zig");

// ── 兼容类型 ──

/// 动画状态
pub const AnimationState = enum {
    idle,
    running,
    paused,
    completed,
};

test {
    std.testing.refAllDecls(@This());
}
