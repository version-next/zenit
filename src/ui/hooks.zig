/// UI Hooks - 可复用的交互状态钩子
///
/// 消除组件中重复的 Signal + simpleHandler + Effect 模板代码。
/// 每个 hook 封装一种常见的交互模式。
///
/// 用法:
/// ```zig
/// const hooks = @import("hooks.zig");
/// const is_hovered = try hooks.useHover(scope, node);
/// ```
const std = @import("std");
const core = @import("core.zig");
const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const Signal = core.Signal;
const Scope = core.Scope;
const createEffect = core.createEffect;
const animation = @import("animation/mod.zig");
const AnimatedColor = animation.AnimatedColor;
const events = @import("events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const focus_mod = @import("focus.zig");
const FocusManager = focus_mod.FocusManager;
const HandlerRef = core.HandlerRef;

/// 为节点绑定 hover Signal（Scope 管理生命周期）
pub fn useHover(scope: *Scope, node: *Node) !*Signal(bool) {
    const is_hovered = try scope.createSignal(bool, false);
    node.addDebugSignal(@ptrCast(is_hovered), "hover", .bool);

    node.behavior.events.on_hover = Cx.simpleHandler(
        struct {
            fn handler(context: *anyopaque) void {
                const sig: *Signal(bool) = @ptrCast(@alignCast(context));
                sig.set(true);
            }
        }.handler,
        @ptrCast(is_hovered),
    );
    node.behavior.events.on_leave = Cx.simpleHandler(
        struct {
            fn handler(context: *anyopaque) void {
                const sig: *Signal(bool) = @ptrCast(@alignCast(context));
                sig.set(false);
            }
        }.handler,
        @ptrCast(is_hovered),
    );

    return is_hovered;
}

/// Hover 高亮样式目标字段
pub const HighlightStyleField = enum {
    border_color,
    background,
    opacity,
    translate_y,
    scale,
};

/// Hover 高亮动画状态 (跨帧持久化)
pub const HoverHighlightState = struct {
    color_anim: AnimatedColor,
    /// 标量动画（用于 opacity/translate_y/scale）
    scalar_anim: ?animation.AnimatedValue = null,
    target_node: ?*Node = null,
    style_field: HighlightStyleField,
    /// allocator (用于 ensureExt 等需要分配内存的操作，scale 等字段必须设置)
    allocator: ?std.mem.Allocator = null,
    /// 冻结：为 true 时 before_render 钩子不再写入样式，把该节点的样式让给外部控制者。
    /// 用于 RadioGroup 选中项，选中态 border 必须钉死 accent，不能被 hover 插值覆盖。
    frozen: bool = false,
};

/// 设置某节点上 useHoverHighlight 注册的冻结状态。返回 false 表示该节点没有 hover 高亮状态。
pub fn setHoverHighlightFrozen(node: *Node, frozen: bool) bool {
    if (node.meta.per_frame.hooks.slots.hover_highlight_state) |ptr| {
        const state: *HoverHighlightState = @ptrCast(@alignCast(ptr));
        state.frozen = frozen;
        return true;
    }
    return false;
}

/// Hover 高亮 target_node 渲染前钩子
fn hoverHighlightBeforeRender(node: *Node) void {
    if (node.meta.per_frame.hooks.slots.hover_highlight_state) |ctx_ptr| {
        const state: *HoverHighlightState = @ptrCast(@alignCast(ctx_ptr));

        // 冻结时让出样式控制权（外部控制者负责该帧的样式），不写入也不请求重绘。
        if (state.frozen) return;

        const render_engine = @import("core/render_engine/mod.zig");
        const dt = render_engine.current_frame_dt_ms / 1000.0;
        const now_ms = render_engine.current_frame_time_ms;

        switch (state.style_field) {
            .border_color, .background => {
                const result = state.color_anim.tickWithTime(now_ms);
                switch (state.style_field) {
                    .border_color => {
                        // setBorderColor 内部会处理 markRenderDirty
                        node.setBorderColor(result.color);
                        if (result.animating) node.markRenderDirty();
                    },
                    .background => {
                        // 只有颜色实际变化时才 setStyle（避免每帧无条件 markRenderDirty）
                        if (!Color.eql(node.getBackground(), result.color)) {
                            node.setBackgroundRaw(result.color);
                            node.markRenderDirty();
                        } else if (result.animating) {
                            node.markRenderDirty();
                        }
                    },
                    else => unreachable,
                }
            },
            .opacity, .translate_y, .scale => {
                if (state.scalar_anim) |*anim| {
                    anim.update(now_ms, dt);
                    const v = anim.get();
                    // composite 类属性统一走权威失效组合，而非 markRenderDirty 慢路径
                    // 与 transition tick / node_animator 一致（setOpacity 内部已收口）；
                    // markCompositeDirty 内部已置 redraw.requested，动画期无需额外标脏。
                    switch (state.style_field) {
                        .opacity => node.setOpacity(v),
                        .translate_y => {
                            node.style.translate_y = v;
                            node.markCompositePropDirty();
                        },
                        .scale => {
                            if (state.allocator) |alloc| {
                                node.style.ensureExtPanic(alloc).scale_x = v;
                                node.style.ensureExtPanic(alloc).scale_y = v;
                                node.markCompositePropDirty();
                            }
                        },
                        else => unreachable,
                    }
                }
            },
        }
    }
}

/// Hover 高亮动画配置
pub const HoverHighlightConfig = struct {
    /// 过渡持续时间 (秒)
    duration: f32 = 0.12,
    /// 缓动函数
    easing: animation.Easing = .ease_out_quad,
};

/// 设置 onMount 回调 (首次布局后触发一次)
pub fn onMount(node: *Node, handler: core.HandlerRef) void {
    node.meta.ownership.hooks.on_mount = handler;
}

/// 设置 onCleanup 回调 (节点从树中移除时触发)
pub fn onCleanup(node: *Node, handler: core.HandlerRef) void {
    node.meta.ownership.hooks.on_cleanup = handler;
}

/// 在 clearNodeScopes / dispose 之前使 hook 状态与节点脱钩，
/// 避免资源析构时再去访问已经脱离生命周期管理的 Node 指针。
pub fn invalidateSubtreeHookState(node: *Node) void {
    if (node.meta.per_frame.hooks.slots.animated_bg_state) |ptr| {
        const state: *AnimBgState = @ptrCast(@alignCast(ptr));
        state.node = null;
        node.meta.per_frame.hooks.slots.animated_bg_state = null;
    }
    if (node.meta.per_frame.hooks.slots.hover_highlight_state) |ptr| {
        const state: *HoverHighlightState = @ptrCast(@alignCast(ptr));
        state.target_node = null;
        node.meta.per_frame.hooks.slots.hover_highlight_state = null;
    }
    if (node.meta.per_frame.hooks.slots.focus_ring_anim) |ptr| {
        if (node.meta.per_frame.hooks.slots.focus_ring_owned) {
            const state: *FocusRingAnimState = @ptrCast(@alignCast(ptr));
            state.node = null;
        }
        node.meta.per_frame.hooks.slots.focus_ring_anim = null;
    }
    node.meta.per_frame.hooks.slots.focus_ring_owned = false;
    // 组件自定义 anim_state（Spinner / Skeleton shimmer 等无限动画）。
    //
    // 此前这里**只**清 animated_bg / hover_highlight / focus_ring 三个槽，漏了
    // anim_state，且从不摘除 before_render hook 本身。后果不是崩溃（各 hook
    // 首行都是 `slots.anim_state orelse return`），而是**卸载后的子树仍每帧
    // 被 tick**：`freeNode` 在 tick_depth>0 时延迟释放，排队期间 hook 照跑，
    // Spinner 每帧 markRenderDirty() -> wantsFrame 恒真 -> **idle 永不停帧**。
    //
    // 实测：storybook 切到纯静态页（Divider）后静置 10s 仍跑满 60fps，标脏源
    // 全是已被 Show 销毁的 story.button 子树里的 Button.loading spinner。
    //
    // 摘 hook 是关键，只清状态不摘 hook，hook 仍会被调用；无限动画组件
    // 不像有限 transition 那样会自行收敛，必须显式断开。
    node.meta.per_frame.hooks.slots.anim_state = null;
    node.meta.per_frame.hooks.before_render.main = null;
    node.meta.per_frame.hooks.before_render.count = 0;
    node.meta.per_frame.hooks.on_theme = null;

    for (node.children.items) |child| {
        invalidateSubtreeHookState(child);
    }
}

// ==================== useAnimatedBackground ====================

/// 动画背景状态 (跨帧持久化)
pub const AnimBgState = struct {
    bg_anim: AnimatedColor,
    cx: ?*Cx = null,
    node: ?*Node = null,
    hover_signal: ?*Signal(bool) = null,
    // 运行时可修改的目标色（外部可通过 setColors 更新）
    normal_bg: Color = Color.TRANSPARENT,
    recipe_normal_bg: Color = Color.TRANSPARENT,
    normal_override: ?Color = null,
    hover_bg: Color = Color.TRANSPARENT,
    recipe_hover_bg: Color = Color.TRANSPARENT,
    hover_override: ?Color = null,
    pressed_bg: ?Color = null,
    recipe_pressed_bg: ?Color = null,
    pressed_override: ?Color = null,
    /// 首帧直接落到目标色：挂载前设好的选中色不该从透明渐变出来。
    settled: bool = false,

    /// 运行时更新 normal/hover 目标色，从当前颜色平滑过渡
    pub fn setColors(self: *AnimBgState, normal: Color, hover: Color) void {
        self.recipe_normal_bg = normal;
        self.normal_bg = self.normal_override orelse normal;
        self.recipe_hover_bg = hover;
        self.hover_bg = self.hover_override orelse hover;
    }

    /// Override only the resting color without fighting the animation hook.
    /// Passing null restores the recipe-provided resting color.
    pub fn setNormalOverride(self: *AnimBgState, color: ?Color) void {
        self.normal_override = color;
        self.normal_bg = color orelse self.recipe_normal_bg;
        if (self.node) |node| node.markRenderDirty();
    }

    /// Override the hover/pressed colors the same way. An "active"（选中态）
    /// button that overrides its resting color to a solid accent must also
    /// override hover，否则 hover 一瞬间弹回 recipe 的 ghost 浅底，
    /// 浅色图标直接隐形。Pass null to restore the recipe colors.
    pub fn setInteractionOverride(self: *AnimBgState, hover: ?Color, pressed: ?Color) void {
        self.hover_override = hover;
        self.hover_bg = hover orelse self.recipe_hover_bg;
        self.pressed_override = pressed;
        self.pressed_bg = pressed orelse self.recipe_pressed_bg;
        if (self.node) |node| node.markRenderDirty();
    }
};

/// 动画背景渲染前钩子
fn animBgBeforeRender(node: *Node) void {
    if (node.meta.per_frame.hooks.slots.animated_bg_state) |ctx_ptr| {
        const state: *AnimBgState = @ptrCast(@alignCast(ctx_ptr));
        const now_ms = @import("core/render_engine/mod.zig").current_frame_time_ms;
        var hovered = if (state.hover_signal) |sig| sig.get() else false;

        if (state.cx) |cx| {
            const actually_hovered = if (cx.hovered_node) |h| h.isDescendantOf(node) else false;
            if (hovered and !actually_hovered) {
                if (state.hover_signal) |sig| sig.set(false);
                hovered = false;
            } else if (!hovered and actually_hovered) {
                hovered = true;
            }

            const pressed = if (cx.pressed_node) |p| p.isDescendantOf(node) else false;
            const target = if (pressed and hovered and state.pressed_bg != null)
                state.pressed_bg.?
            else if (hovered)
                state.hover_bg
            else
                state.normal_bg;
            if (state.settled) {
                state.bg_anim.setTarget(target, now_ms);
            } else {
                state.bg_anim.setImmediate(target);
                state.settled = true;
            }
        }

        const result = state.bg_anim.tickWithTime(now_ms);
        // 只有颜色实际变化时才 setStyle（避免每帧无条件 markRenderDirty）
        if (!Color.eql(node.getBackground(), result.color)) {
            node.setBackgroundRaw(result.color);
            node.markRenderDirty();
        } else if (result.animating) {
            // 颜色没变但动画仍在进行，保持重绘请求
            node.markRenderDirty();
        }
    }
}

/// useAnimatedBackground 配置
pub const AnimatedBgConfig = struct {
    normal: Color,
    hover: Color,
    pressed: ?Color = null,
    duration: f32 = 0.15,
    easing: animation.Easing = .ease_out_quad,
};

/// 为节点添加动画背景色过渡（Scope 管理生命周期）
pub fn useAnimatedBackground(scope: *Scope, cx: *Cx, node: *Node, config: AnimatedBgConfig) !*Signal(bool) {
    // 在 scope 上分配动画状态（scope dispose 时自动释放）
    const anim_state = try scope.allocator.create(AnimBgState);
    anim_state.* = .{
        .bg_anim = AnimatedColor.initWithConfig(config.normal, .{
            .duration_ms = config.duration * 1000.0,
            .easing = config.easing,
        }),
        .cx = cx,
        .node = node,
        .normal_bg = config.normal,
        .recipe_normal_bg = config.normal,
        .hover_bg = config.hover,
        .recipe_hover_bg = config.hover,
        .pressed_bg = config.pressed,
        .recipe_pressed_bg = config.pressed,
    };
    {
        errdefer scope.allocator.destroy(anim_state);
        try scope.registerResource(@ptrCast(anim_state), struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const s: *AnimBgState = @ptrCast(@alignCast(ptr));
                if (s.node) |n| {
                    if (n.meta.per_frame.hooks.slots.animated_bg_state == ptr) n.meta.per_frame.hooks.slots.animated_bg_state = null;
                    n.removeBeforeRender(animBgBeforeRender);
                }
                s.node = null;
                allocator.destroy(s);
            }
        }.destroy);
    }
    // （date_picker OOM sweep 抓到的 UAF）：state 一登记进 scope，destroy 就会解引用 s.node；
    // 而节点被释放时靠 invalidateSubtreeHookState 顺着 node->slot 回链把 s.node 置 null。原来回链
    // 在函数末尾才挂，中间 addDebugState / useHover / onCleanup 任一步 OOM 返回后：state 已登记、
    // 回链没挂 -> 节点释放时清不到 -> 之后 scope dispose 解引用已释放节点。回链必须紧跟登记。
    node.meta.per_frame.hooks.slots.animated_bg_state = anim_state;
    node.addDebugState(@ptrCast(anim_state));

    const is_hovered = try useHover(scope, node);
    anim_state.hover_signal = is_hovered;

    // hover_signal 是**借用**：它归 scope 所有，而 Scope.dispose 的相位顺序是
    //   2) cleanups -> 3) effects -> 4) signals -> 5) resources
    // 也就是说信号在第 4 步就被 destroy，而本 hook 的注销挂在第 5 步的
    // resource cleanup 上。中间这一格里 animBgBeforeRender 若被触发
    // （hit-test 会在同一帧里跑 tickBeforeRender，线上崩溃栈正是
    // handleMouseMove -> ensureHitTestSceneFresh -> tickBeforeRender -> 本 hook），
    // `state.hover_signal.get()` 读的就是已释放内存。
    //
    // 用 onCleanup 在**第 2 相位**把借用解开：信号还活着时先置 null，
    // 之后 hook 即使跑到也只会走 `else false` 分支。
    // 这是 Scope 相位模型里唯一能赶在 signal 销毁之前的钩子。
    try scope.onCleanup(AnimBgState, anim_state, struct {
        fn dropSignal(s: *AnimBgState) void {
            s.hover_signal = null;
        }
    }.dropSignal);

    // 注册为扩展回调（不覆盖主 on_before_render，不再需要保护逻辑）
    node.addBeforeRender(animBgBeforeRender);

    // Effect 驱动颜色变化（从 anim_state 读取颜色，支持运行时 setColors 更新）
    if (config.pressed != null) {
        try scope.createEffect(.{
            .anim_state = anim_state,
            .is_hovered = is_hovered,
            .cx = cx,
            .node = node,
        }, struct {
            fn update(c: anytype) void {
                const hovered = c.is_hovered.get();
                const pressed = c.cx.pressed_node == c.node;
                const s = c.anim_state;

                const target = if (pressed and hovered and s.pressed_bg != null)
                    s.pressed_bg.?
                else if (hovered)
                    s.hover_bg
                else
                    s.normal_bg;

                s.bg_anim.setTarget(target, @import("core/render_engine/mod.zig").current_frame_time_ms);
                c.node.markRenderDirty();
            }
        }.update);
    } else {
        try scope.createEffect(.{
            .anim_state = anim_state,
            .is_hovered = is_hovered,
            .node = node,
        }, struct {
            fn update(c: anytype) void {
                const hovered = c.is_hovered.get();
                const s = c.anim_state;
                s.bg_anim.setTarget(if (hovered) s.hover_bg else s.normal_bg, @import("core/render_engine/mod.zig").current_frame_time_ms);
                c.node.markRenderDirty();
            }
        }.update);
    }

    return is_hovered;
}

// ==================== useFocusRing ====================

/// Focus Ring 配置
pub const FocusRingConfig = struct {
    /// focus ring 颜色（null = 使用 theme border_focus token）
    color: ?Color = null,
    /// focus ring 线宽
    width: f32 = 1.5,
    /// 组件与 ring 之间的间距 (类似 CSS outline-offset)
    offset: f32 = 2,
    /// 渐入渐出过渡持续时间 (秒)
    duration: f32 = 0.1,
    /// 缓动函数
    easing: animation.Easing = .ease_out_quad,
};

/// Focus ring handler 上下文 (通过 StateStore 持久化)
const FocusRingCtx = struct {
    signal: *Signal(bool),
    fm: *FocusManager,
    /// Focus ring 动画状态
    anim_state: ?*FocusRingAnimState = null,
    /// 链式 on_focus/on_blur 的旧回调
    prev_on_focus: ?HandlerRef = null,
    prev_on_blur: ?HandlerRef = null,
};

/// Focus ring 动画状态 (跨帧持久化)
pub const FocusRingAnimState = struct {
    /// outline opacity 动画 (0.0 = 隐藏, 1.0 = 完全显示)
    opacity_anim: animation.AnimatedValue,
    /// 节点引用
    node: ?*Node = null,
    /// outline 配置
    focus_color: Color,
    focus_width: f32,
    focus_offset: f32,
    /// 设置 outline 需要的 allocator
    allocator: std.mem.Allocator,
};

/// Focus ring 渲染前钩子：tick opacity 动画并更新 outline alpha
fn focusRingBeforeRender(node: *Node) void {
    // 从 node 的 focus_ring_anim 指针获取状态
    if (node.meta.per_frame.hooks.slots.focus_ring_anim) |anim_ptr| {
        const anim_state: *FocusRingAnimState = @ptrCast(@alignCast(anim_ptr));

        const render_engine = @import("core/render_engine/mod.zig");
        anim_state.opacity_anim.update(render_engine.current_frame_time_ms, render_engine.current_frame_dt_ms / 1000.0);
        const opacity = anim_state.opacity_anim.get();
        const target_opacity = anim_state.opacity_anim.getTarget();
        const effective_opacity = if (opacity <= 0.001 and target_opacity > 0.001)
            target_opacity
        else
            opacity;

        if (effective_opacity > 0.001) {
            // outline 可见：设置 alpha 通道
            var color = anim_state.focus_color;
            color.a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * effective_opacity);
            const new_outline: ?@import("core/types.zig").Outline = .{
                .color = color,
                .width = anim_state.focus_width,
                .offset = anim_state.focus_offset,
            };
            // 只有 outline 实际变化或动画进行中时才 setStyle
            if (anim_state.opacity_anim.isAnimating() or node.style.outline() == null) {
                node.setStyle(anim_state.allocator, .outline, new_outline);
                node.markRenderDirty();
            }
        } else {
            // 完全透明：仅当 outline 非 null 时才清除（避免每帧无条件 setStyle）
            if (node.style.outline() != null) {
                node.setStyle(anim_state.allocator, .outline, null);
                node.markRenderDirty();
            }
        }
    }
}

/// 为节点添加外围 focus ring 视觉反馈（Scope 管理生命周期）
pub fn useFocusRing(scope: *Scope, cx: *Cx, node: *Node, config: FocusRingConfig) !void {
    // The initial effect and later callbacks write outline/z-index without
    // returning errors. Prepare their shared storage before publishing hooks.
    _ = try node.style.ensureExtFallible(cx.allocator);
    const t = cx.tokens;
    const focus_color = config.color orelse t.color.focus_ring;

    const is_focused = try scope.createSignal(bool, false);
    node.addDebugSignal(@ptrCast(is_focused), "focused", .bool);

    // 在 scope 上分配动画状态
    const anim_state = try scope.allocator.create(FocusRingAnimState);
    anim_state.* = .{
        .opacity_anim = animation.AnimatedValue.create(0.0)
            .useTransition()
            .duration_ms(config.duration * 1000.0)
            .easing(config.easing)
            .build(),
        .node = node,
        .focus_color = focus_color,
        .focus_width = config.width,
        .focus_offset = config.offset,
        .allocator = scope.allocator,
    };
    {
        errdefer scope.allocator.destroy(anim_state);
        try scope.registerResource(@ptrCast(anim_state), struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const s: *FocusRingAnimState = @ptrCast(@alignCast(ptr));
                if (s.node) |n| {
                    if (n.meta.per_frame.hooks.slots.focus_ring_anim == ptr) {
                        n.meta.per_frame.hooks.slots.focus_ring_anim = null;
                        n.meta.per_frame.hooks.slots.focus_ring_owned = false;
                    }
                    n.removeBeforeRender(focusRingBeforeRender);
                }
                s.node = null;
                allocator.destroy(s);
            }
        }.destroy);
    }

    // 注册为扩展回调（不覆盖主 on_before_render）
    node.addBeforeRender(focusRingBeforeRender);
    node.meta.per_frame.hooks.slots.focus_ring_anim = anim_state;
    node.meta.per_frame.hooks.slots.focus_ring_owned = true;

    // Handler 上下文
    const ring_ctx = try scope.allocator.create(FocusRingCtx);
    ring_ctx.* = .{
        .signal = is_focused,
        .fm = &cx.focus_manager,
        .anim_state = anim_state,
        .prev_on_focus = node.behavior.events.on_focus,
        .prev_on_blur = node.behavior.events.on_blur,
    };
    {
        errdefer scope.allocator.destroy(ring_ctx);
        try scope.registerResource(@ptrCast(ring_ctx), struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const s: *FocusRingCtx = @ptrCast(@alignCast(ptr));
                allocator.destroy(s);
            }
        }.destroy);
    }

    // Focus / Blur handlers（链式调用旧回调）
    node.behavior.events.on_focus = Cx.simpleHandler(
        struct {
            fn handler(context: *anyopaque) void {
                const rc: *FocusRingCtx = @ptrCast(@alignCast(context));
                if (rc.prev_on_focus) |prev| prev.invoke();
                const focus_visible = rc.fm.last_focus_reason != .click;
                rc.signal.set(focus_visible);
                if (rc.anim_state) |state| {
                    const now_ms = @import("core/render_engine/mod.zig").current_frame_time_ms;
                    if (focus_visible) {
                        state.opacity_anim.setTo(1.0, now_ms);
                        if (state.node) |n| {
                            // 本回调是 void，无法传播；z_index 只是视觉层级，
                            // 分配失败时保持原值降级即可，但绝不能 @panic 掉整个进程。
                            if (n.style.ensureExtFallible(state.allocator)) |ext| {
                                ext.z_index = 1;
                            } else |_| {}
                            n.setStyle(state.allocator, .outline, .{
                                .color = state.focus_color,
                                .width = state.focus_width,
                                .offset = state.focus_offset,
                            });
                            n.markRenderDirty();
                        }
                    } else {
                        state.opacity_anim.setTo(0.0, now_ms);
                        if (state.node) |n| {
                            // void 回调，失败降级不 panic（同上）。
                            if (n.style.ensureExtFallible(state.allocator)) |ext| {
                                ext.z_index = 0;
                            } else |_| {}
                            n.markRenderDirty();
                        }
                    }
                }
            }
        }.handler,
        @ptrCast(ring_ctx),
    );
    node.behavior.events.on_blur = Cx.simpleHandler(
        struct {
            fn handler(context: *anyopaque) void {
                const rc: *FocusRingCtx = @ptrCast(@alignCast(context));
                if (rc.prev_on_blur) |prev| prev.invoke();
                rc.signal.set(false);
                if (rc.anim_state) |state| {
                    state.opacity_anim.setTo(0.0, @import("core/render_engine/mod.zig").current_frame_time_ms);
                    if (state.node) |n| {
                        // 本回调是 void，无法传播；z_index 只是视觉层级，
                        // 分配失败时保持原值降级即可，但绝不能 @panic 掉整个进程。
                        if (n.style.ensureExtFallible(state.allocator)) |ext| {
                            ext.z_index = 0;
                        } else |_| {}
                        n.markRenderDirty();
                    }
                }
            }
        }.handler,
        @ptrCast(ring_ctx),
    );

    // Effect: focus-visible 时设置动画目标 opacity + z_index 提升
    // z_index 提升确保 focus ring (outline) 不被同级兄弟节点遮挡（如 Group 组合）
    try scope.createEffect(.{
        .is_focused = is_focused,
        .anim_state = anim_state,
        .node = node,
        .allocator = scope.allocator,
    }, struct {
        fn update(c: anytype) void {
            const now_ms = @import("core/render_engine/mod.zig").current_frame_time_ms;
            if (c.is_focused.get()) {
                c.anim_state.opacity_anim.setTo(1.0, now_ms);
                // 本回调是 void，无法传播；z_index 只是视觉层级，
                // 分配失败时保持原值降级即可，但绝不能 @panic 掉整个进程。
                if (c.node.style.ensureExtFallible(c.allocator)) |ext| {
                    ext.z_index = 1;
                } else |_| {}
                c.node.setStyle(c.allocator, .outline, .{
                    .color = c.anim_state.focus_color,
                    .width = c.anim_state.focus_width,
                    .offset = c.anim_state.focus_offset,
                });
            } else {
                c.anim_state.opacity_anim.setTo(0.0, now_ms);
                // void 回调，失败降级不 panic（同上）。
                if (c.node.style.ensureExtFallible(c.allocator)) |ext| {
                    ext.z_index = 0;
                } else |_| {}
            }
            c.node.markRenderDirty();
        }
    }.update);
}

/// hover 高亮动画（Scope 管理生命周期）
pub fn useHoverHighlight(
    scope: *Scope,
    node: *Node,
    target_node: *Node,
    comptime StyleField: HighlightStyleField,
    normal: Color,
    hover: Color,
    config: HoverHighlightConfig,
) !*Signal(bool) {
    const is_hovered = try useHover(scope, node);

    // 在 scope 上分配动画状态
    const hl_state = try scope.allocator.create(HoverHighlightState);
    hl_state.* = .{
        .color_anim = AnimatedColor.initWithConfig(normal, .{
            .duration_ms = config.duration * 1000.0,
            .easing = config.easing,
        }),
        .target_node = target_node,
        .style_field = StyleField,
    };
    try scope.adoptResource(@ptrCast(hl_state), struct {
        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const s: *HoverHighlightState = @ptrCast(@alignCast(ptr));
            if (s.target_node) |n| {
                if (n.meta.per_frame.hooks.slots.hover_highlight_state == ptr) n.meta.per_frame.hooks.slots.hover_highlight_state = null;
                n.removeBeforeRender(hoverHighlightBeforeRender);
            }
            allocator.destroy(s);
        }
    }.destroy);

    // 注册为扩展回调
    target_node.addBeforeRender(hoverHighlightBeforeRender);
    target_node.meta.per_frame.hooks.slots.hover_highlight_state = hl_state;

    // Effect: hover 变化时设置动画目标颜色
    try scope.createEffect(.{
        .hl_state = hl_state,
        .is_hovered = is_hovered,
        .normal = normal,
        .hover = hover,
        .target = target_node,
    }, struct {
        fn update(c: anytype) void {
            c.hl_state.color_anim.setTarget(if (c.is_hovered.get()) c.hover else c.normal, @import("core/render_engine/mod.zig").current_frame_time_ms);
            c.target.markRenderDirty();
        }
    }.update);

    return is_hovered;
}

// ==================== ToggleState ====================

/// Toggle 状态
pub const ToggleState = struct {
    checked: bool = false,
    disabled: bool = false,
    /// 2026-07-31 并轨：统一 `?core.HandlerRef`（context 已含在内）。
    /// 用 invokeWithBool 触发，注册方若用的是无参 handler，会退化为
    /// 无参调用而不是丢事件。
    on_change: ?core.HandlerRef = null,

    pub fn toggle(self: *ToggleState) void {
        if (self.disabled) return;
        self.checked = !self.checked;
        if (self.on_change) |h| h.invokeWithBool(self.checked);
    }
};

/// Toggle 事件处理逻辑 (类型安全版，可被 wrapper 调用)
pub fn toggleEventHandlerFn(event: Event, state: *ToggleState) EventResult {
    if (state.disabled) return .ignored;

    switch (event) {
        .click => {
            state.toggle();
            return .handled;
        },
        .key_down => |e| {
            if (e.key == .space) {
                state.toggle();
                return .handled;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}
