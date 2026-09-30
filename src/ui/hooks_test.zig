//! Unit tests for public UI hooks.
//!
//! Kept in a dedicated test module so the production hooks module remains a
//! focused implementation surface. src/ui/ui.zig imports this file explicitly.

const std = @import("std");
const core = @import("core.zig");
const hooks = @import("hooks.zig");
const Cx = core.Cx;
const Scope = core.Scope;
const Color = core.Color;
const useHover = hooks.useHover;
const useHoverHighlight = hooks.useHoverHighlight;
const onMount = hooks.onMount;
const onCleanup = hooks.onCleanup;
const useAnimatedBackground = hooks.useAnimatedBackground;
const AnimBgState = hooks.AnimBgState;
const invalidateSubtreeHookState = hooks.invalidateSubtreeHookState;
const ToggleState = hooks.ToggleState;
const useFocusRing = hooks.useFocusRing;
const FocusRingAnimState = hooks.FocusRingAnimState;

test "useHover: basic" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, node);

    const is_hovered = try useHover(scope, node);

    // 初始状态
    try std.testing.expect(!is_hovered.get());

    // 模拟 hover
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(is_hovered.get());

    // 模拟 leave
    node.behavior.events.on_leave.?.invoke();
    try std.testing.expect(!is_hovered.get());
}

test "useHoverHighlight: border_color with animation" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const container = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const inner = try box(ctx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
        .border = .{ .width = 1, .color = t.color.checkbox_border },
    }, .{});
    try root.appendChild(std.testing.allocator, container);
    try container.appendChild(std.testing.allocator, inner);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const render_engine = @import("core/render_engine/mod.zig");
    var now_ms: f64 = 0;

    _ = try useHoverHighlight(scope, container, inner, .border_color, t.color.checkbox_border, t.color.accent, .{});

    // 初始: normal 色
    try std.testing.expect(Color.eql(inner.style.border.color, t.color.checkbox_border));

    // hover → 触发动画，tick 足够帧后应收敛到 accent 色。
    // 注意：setTarget 用 render_engine.current_frame_time_ms 作为动画起点
    // （hooks.zig:609），所以必须**先把帧时钟设成当前值再 invoke**，否则
    // 动画起点停在 0 而后续 tick 从 16ms 起跳，进度计算错位。
    render_engine.current_frame_time_ms = now_ms;
    render_engine.current_frame_dt_ms = 16.0;
    container.behavior.events.on_hover.?.invoke();
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        for (inner.meta.per_frame.hooks.before_render.hooks[0..inner.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(inner);
        }
    }
    try std.testing.expect(Color.eql(inner.style.border.color, t.color.accent));

    // leave → tick 足够帧后恢复 normal 色（同样先对齐帧时钟）
    render_engine.current_frame_time_ms = now_ms;
    container.behavior.events.on_leave.?.invoke();
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        for (inner.meta.per_frame.hooks.before_render.hooks[0..inner.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(inner);
        }
    }
    try std.testing.expect(Color.eql(inner.style.border.color, t.color.checkbox_border));
}

test "onMount: triggered after layout" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const child = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, child);

    var mounted = false;
    onMount(child, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(c));
            ptr.* = true;
        }
    }.handler, &mounted));

    // 布局前不触发
    try std.testing.expect(!mounted);
    try std.testing.expect(!child.frame_state.state_bits.flags.is_mounted);

    // 布局后触发
    ctx.layout();
    try std.testing.expect(mounted);
    try std.testing.expect(child.frame_state.state_bits.flags.is_mounted);

    // 再次布局不会重复触发
    mounted = false;
    root.markLayoutDirty();
    ctx.layout();
    try std.testing.expect(!mounted); // 不重复
}

test "onCleanup: triggered on removeChild" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const child = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, child);

    // 计数器而非 bool：双触发时第二次写 true 无感，历史上因此漏掉
    // detachChild → freeNode 链上的 on_cleanup 二次 invoke（refcount 下溢级 bug）
    var clean_count: u32 = 0;
    onCleanup(child, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(c));
            ptr.* += 1;
        }
    }.handler, &clean_count));

    // 先布局使其 mounted
    ctx.layout();
    try std.testing.expect(child.frame_state.state_bits.flags.is_mounted);
    try std.testing.expectEqual(@as(u32, 0), clean_count);

    // 移除触发 cleanup
    ctx.detachChild(root, child);
    try std.testing.expectEqual(@as(u32, 1), clean_count);
    try std.testing.expect(!child.frame_state.state_bits.flags.is_mounted);

    // 手动释放被移除的节点 (不在树中, ctx.deinit 不会释放)
    // freeNode 不得再次触发 on_cleanup——一次性消费
    ctx.freeNode(child);
    try std.testing.expectEqual(@as(u32, 1), clean_count);
}

test "onCleanup: recursive for nested children" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const parent_node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } }, .{});
    const child_node = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, parent_node);
    try parent_node.appendChild(std.testing.allocator, child_node);

    var parent_clean_count: u32 = 0;
    var child_clean_count: u32 = 0;
    onCleanup(parent_node, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(c));
            ptr.* += 1;
        }
    }.handler, &parent_clean_count));
    onCleanup(child_node, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(c));
            ptr.* += 1;
        }
    }.handler, &child_clean_count));

    ctx.layout();

    // 移除 parent_node 应同时触发子节点的 cleanup
    ctx.detachChild(root, parent_node);
    try std.testing.expectEqual(@as(u32, 1), parent_clean_count);
    try std.testing.expectEqual(@as(u32, 1), child_clean_count);

    // 手动释放被移除的节点；子树各节点的 on_cleanup 不得二次触发
    ctx.freeNode(parent_node);
    try std.testing.expectEqual(@as(u32, 1), parent_clean_count);
    try std.testing.expectEqual(@as(u32, 1), child_clean_count);
}

test "useAnimatedBackground: creates state and hover signal" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const is_hovered = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
    });

    // 初始状态
    try std.testing.expect(!is_hovered.get());
    try std.testing.expect(node.meta.per_frame.hooks.before_render.main != null or node.meta.per_frame.hooks.before_render.count > 0);

    // hover → 设置 Signal
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(is_hovered.get());
}

test "useAnimatedBackground: normal override survives recipe color refresh" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    ctx.root = node;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
    });

    const state: *AnimBgState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.animated_bg_state.?));
    const override = Color.hex(0x123456);
    const refreshed_recipe = Color.hex(0x654321);
    state.setNormalOverride(override);
    state.setColors(refreshed_recipe, t.color.bg_hover);
    try std.testing.expect(Color.eql(state.normal_bg, override));
    try std.testing.expect(Color.eql(state.recipe_normal_bg, refreshed_recipe));

    state.setNormalOverride(null);
    try std.testing.expect(Color.eql(state.normal_bg, refreshed_recipe));
}

test "useAnimatedBackground: uses dedicated node slot" {
    const box = core.box;
    const render_engine = @import("core/render_engine/mod.zig");
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
    });

    var dummy: u8 = 0;
    node.meta.per_frame.hooks.slots.anim_state = @ptrCast(&dummy);
    node.behavior.events.on_hover.?.invoke();

    var now_ms: f64 = 0;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }

    try std.testing.expect(node.meta.per_frame.hooks.slots.anim_state == @as(?*anyopaque, @ptrCast(&dummy)));
    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state != null);
}

test "useAnimatedBackground: scope dispose removes hook state" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
    });

    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state != null);
    try std.testing.expect(node.meta.per_frame.hooks.before_render.count > 0);

    scope.dispose();

    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state == null);
    try std.testing.expectEqual(@as(u8, 0), node.meta.per_frame.hooks.before_render.count);
}

test "useAnimatedBackground: beforeRender clears stale hover state from detached interaction" {
    const box = core.box;
    const render_engine = @import("core/render_engine/mod.zig");
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const is_hovered = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
    });

    node.behavior.events.on_hover.?.invoke();
    ctx.hovered_node = null;

    var now_ms: f64 = 0;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }

    try std.testing.expect(!is_hovered.get());
    try std.testing.expect(Color.eql(node.getBackground(), t.color.accent));
}

test "useAnimatedBackground: beforeRender reacts to pressed state release without hover signal change" {
    const box = core.box;
    const render_engine = @import("core/render_engine/mod.zig");
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
        .pressed = t.color.bg_active,
    });

    node.behavior.events.on_hover.?.invoke();
    ctx.hovered_node = node;
    ctx.pressed_node = node;

    var now_ms: f64 = 0;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(Color.eql(node.getBackground(), t.color.bg_active));

    ctx.pressed_node = null;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }

    try std.testing.expect(Color.eql(node.getBackground(), t.color.accent_hover));
}

test "invalidateSubtreeHookState detaches hook back-pointers before scope dispose" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.color.accent }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
    });
    try useFocusRing(scope, ctx, node, .{});

    const anim_state: *AnimBgState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.animated_bg_state.?));
    const ring_state: *FocusRingAnimState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.focus_ring_anim.?));
    try std.testing.expect(anim_state.node == node);
    try std.testing.expect(ring_state.node == node);

    invalidateSubtreeHookState(node);

    try std.testing.expect(anim_state.node == null);
    try std.testing.expect(ring_state.node == null);

    scope.dispose();
    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state == null);
    try std.testing.expect(node.meta.per_frame.hooks.slots.focus_ring_anim == null);
}

test "freeNode detaches hook back-pointers for nodes owned by external scope" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const parent = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } }, .{});
    try root.appendChild(std.testing.allocator, parent);

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.color.accent }, .{});
    try parent.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.color.accent,
        .hover = t.color.accent_hover,
    });

    const anim_state: *AnimBgState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.animated_bg_state.?));
    try std.testing.expect(anim_state.node == node);

    ctx.detachChild(parent, node);
    ctx.freeNode(node);

    try std.testing.expect(anim_state.node == null);

    scope.dispose();
    scope_disposed = true;
}

test "useToggle: click toggles state" {
    var state = ToggleState{ .checked = false };

    try std.testing.expect(!state.checked);
    state.toggle();
    try std.testing.expect(state.checked);
    state.toggle();
    try std.testing.expect(!state.checked);
}

test "useToggle: disabled prevents toggle" {
    var state = ToggleState{ .checked = false, .disabled = true };
    state.toggle();
    try std.testing.expect(!state.checked);
}

test "useToggle: callback fires" {
    const Ctx = struct {
        last_value: bool = false,
        count: u32 = 0,
    };
    var cb_ctx = Ctx{};

    var state = ToggleState{
        .checked = false,
        .on_change = core.Cx.boolHandlerFrom(Ctx, &cb_ctx, struct {
            fn handler(c: *Ctx, new_val: bool) void {
                c.last_value = new_val;
                c.count += 1;
            }
        }.handler),
    };

    state.toggle();
    try std.testing.expect(cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 1), cb_ctx.count);

    state.toggle();
    try std.testing.expect(!cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 2), cb_ctx.count);
}

test "useFocusRing: tab focus shows outline with animation, blur fades out" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});

    // 初始: 无 outline
    try std.testing.expect(node.style.outline() == null);

    // Tab focus → tick 足够帧后 outline 出现 (opacity → 1.0)
    ctx.focus_manager.last_focus_reason = .tab;
    node.behavior.events.on_focus.?.invoke();
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() != null);
    // outline color alpha 应该接近 focus_ring 的原始 alpha
    try std.testing.expectEqual(@as(f32, 1.5), node.style.outline().?.width);
    try std.testing.expectEqual(@as(f32, 2), node.style.outline().?.offset);
    // 颜色应该接近 focus_ring (alpha 可能因为 opacity=1.0 而完全一致)
    try std.testing.expect(Color.eql(node.style.outline().?.color, t.color.focus_ring));

    // blur → tick 足够帧后 outline 消失 (opacity → 0.0)
    node.behavior.events.on_blur.?.invoke();
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() == null);
}

test "useFocusRing: click focus does NOT show outline" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});

    // 鼠标点击 focus → tick 后仍不显示 outline
    ctx.focus_manager.last_focus_reason = .click;
    node.behavior.events.on_focus.?.invoke();
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() == null);
}

test "useFocusRing: focused input scrolled out of ScrollArea does not steal clicks" {
    // 方案 §9.2 第 14 条（附录 A 探针 3 的组件版）。useFocusRing 在 focus-visible 时把
    // 控件提到 z_index=1（压住同级兄弟）。旧实现里 z>0 让命中清空祖先 clip 链并拿到全局
    // stacking_z：控件滚出 ScrollArea 视口后，像素被裁掉了，却仍抢走视口外 header 的点击。
    const box = core.box;
    const scroll_area = @import("components/scroll_area/mod.zig");
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(300, 300);

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const header = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    header.setFocusable(true);
    try root.appendChild(std.testing.allocator, header);

    const area = try scroll_area.mountScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }, scope, ctx);
    try root.appendChild(std.testing.allocator, area.container);

    const lead = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 150 } }, .{});
    try area.content.appendChild(std.testing.allocator, lead);
    const field = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 } }, .{});
    field.setFocusable(true);
    try area.content.appendChild(std.testing.allocator, field);
    const tail = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 410 } }, .{});
    try area.content.appendChild(std.testing.allocator, tail);

    try useFocusRing(scope, ctx, field, .{});

    ctx.layout();
    _ = ctx.render();

    // Tab 聚焦 → focus-visible → z_index 提升到 1。
    ctx.focus_manager.last_focus_reason = .tab;
    field.behavior.events.on_focus.?.invoke();
    try std.testing.expectEqual(@as(i16, 1), field.style.z_index());
    ctx.frame_time_ms += 16;
    ctx.layout();
    _ = ctx.render();

    // 未滚动：field 在视口内（世界 y = 100+150 = 250..290），点得到。
    try std.testing.expectEqual(field, ctx.hitTest(20, 260).?);

    // 滚动 200：field 世界 y = 50..90，整个在视口（y ≥ 100）之上，落在 header 区。
    scroll_area.setScrollY(area.state, area.content, 200);
    ctx.frame_time_ms += 16;
    ctx.layout();
    _ = ctx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 50), field.globalRect().y, 0.5);
    try std.testing.expectEqual(@as(i16, 1), field.style.z_index());

    // 视口外的 header 区必须命中 header，而不是被裁掉、看不见的 field。
    try std.testing.expectEqual(header, ctx.hitTest(20, 60).?);
}

test "useFocusRing: custom config with tab" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{
        .color = Color.hex(0xff0000),
        .width = 2,
        .offset = 3,
    });

    ctx.focus_manager.last_focus_reason = .tab;
    node.behavior.events.on_focus.?.invoke();
    // tick 足够帧让动画收敛
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    const out = node.style.outline().?;
    try std.testing.expect(Color.eql(out.color, Color.hex(0xff0000)));
    try std.testing.expectEqual(@as(f32, 2), out.width);
    try std.testing.expectEqual(@as(f32, 3), out.offset);
}

test "useFocusRing: scope dispose removes hook state" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});
    try std.testing.expect(node.meta.per_frame.hooks.slots.focus_ring_anim != null);
    try std.testing.expect(node.meta.per_frame.hooks.before_render.count > 0);

    scope.dispose();

    try std.testing.expect(node.meta.per_frame.hooks.slots.focus_ring_anim == null);
    try std.testing.expectEqual(@as(u8, 0), node.meta.per_frame.hooks.before_render.count);
}
