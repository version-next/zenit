/// 动画 Hooks — Scope 绑定的声明式动画创建
///
/// 所有 hook 创建的资源跟随 Scope 生命周期自动释放。
///
/// 用法:
/// ```zig
/// const anim = @import("animation/anim_hooks.zig");
///
/// // Scope 绑定的 tween 动画
/// const ctrl = try anim.useAnimation(scope, .{
///     .from = 0, .to = 100, .duration = 0.5,
/// });
/// // ctrl.value 每帧自动更新
///
/// // Scope 绑定的 spring 动画
/// const spring_ctrl = try anim.useSpringAnimation(scope, .{
///     .from = 0, .to = 100, .stiffness = 200, .damping = 20,
/// });
///
/// // Scope 绑定的 timeline
/// const tl = try anim.useTimeline(scope);
/// try tl.add(&ctrl1, .start);
/// tl.play();
/// ```
const std = @import("std");
const ctrl_mod = @import("controller.zig");
const AnimationController = ctrl_mod.AnimationController;
const timeline_mod = @import("timeline.zig");
const Timeline = timeline_mod.Timeline;
const Easing = @import("easing.zig").Easing;

/// 获取 Scope 类型（延迟解析避免循环依赖）
const Scope = @import("../reactive/scope.zig").Scope;

/// Tween 动画配置
pub const UseAnimationConfig = struct {
    from: f32 = 0,
    to: f32 = 1,
    duration: f32 = 0.3,
    easing: Easing = .ease_out_quad,
    delay: f32 = 0,
    loops: u32 = 1,
    yoyo: bool = false,
    auto_play: bool = true,
};

/// 创建 Scope 绑定的 Tween 动画控制器
pub fn useAnimation(scope: *Scope, config: UseAnimationConfig) !*AnimationController {
    const ctrl = try scope.allocator.create(AnimationController);
    errdefer scope.allocator.destroy(ctrl);
    ctrl.* = AnimationController.initTween(.{
        .from = config.from,
        .to = config.to,
        .duration = config.duration,
        .easing = config.easing,
        .delay = config.delay,
    });
    ctrl.loops = config.loops;
    ctrl.yoyo = config.yoyo;

    ctrl.lifetime_scope = scope;
    ctrl.scope_lifetime = try ctrl_mod.ScopeLifetime.create(scope);
    errdefer ctrl.releaseLifetime();
    try scope.registerResource(@ptrCast(ctrl), destroyController);

    if (config.auto_play) ctrl.play();
    return ctrl;
}

/// Spring 动画配置
pub const UseSpringConfig = struct {
    from: f32 = 0,
    to: f32 = 1,
    stiffness: f32 = 170,
    damping: f32 = 26,
    mass: f32 = 1,
    auto_play: bool = true,
};

/// 创建 Scope 绑定的 Spring 动画控制器
pub fn useSpringAnimation(scope: *Scope, config: UseSpringConfig) !*AnimationController {
    const ctrl = try scope.allocator.create(AnimationController);
    errdefer scope.allocator.destroy(ctrl);
    ctrl.* = AnimationController.initSpring(.{
        .from = config.from,
        .to = config.to,
        .stiffness = config.stiffness,
        .damping = config.damping,
        .mass = config.mass,
    });

    ctrl.lifetime_scope = scope;
    ctrl.scope_lifetime = try ctrl_mod.ScopeLifetime.create(scope);
    errdefer ctrl.releaseLifetime();
    try scope.registerResource(@ptrCast(ctrl), destroyController);

    if (config.auto_play) ctrl.play();
    return ctrl;
}

/// 创建 Scope 绑定的 Timeline
///
/// Scope cleanup calls Timeline.deinit, which automatically unregisters it
/// from every AnimationManager before releasing the allocation. Registered
/// managers and timelines must stay at stable addresses until detached.
pub fn useTimeline(scope: *Scope) !*Timeline {
    const tl = try scope.allocator.create(Timeline);
    errdefer scope.allocator.destroy(tl);
    tl.* = Timeline.init(scope.allocator);
    tl.lifetime_scope = scope;

    try scope.registerResource(@ptrCast(tl), destroyTimeline);

    return tl;
}

// ── 清理函数 ──

fn destroyController(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const ctrl: *AnimationController = @ptrCast(@alignCast(ptr));
    if (ctrl.scope_lifetime) |lifetime| lifetime.retire();
    ctrl.releaseLifetime();
    allocator.destroy(ctrl);
}

fn destroyTimeline(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const tl: *Timeline = @ptrCast(@alignCast(ptr));
    tl.deinit();
    allocator.destroy(tl);
}
