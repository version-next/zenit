//! popover_test.zig — Popover / overlay 定位与生命周期单测
//!
//! 从 popover.zig 析出（2026-07-31）。测试占原文件 961 行（42%），
//! 与实现同文件除了撑大文件没有别的作用。
//!
//! ⚠ 必须在 components/mod.zig 或上游有显式 `_ = @import(...)` 才会被
//! test runner 收集 —— Zig 的 refAllDecls 只递归本文件引用过的模块。
//! 析出后已用"故意反转断言"验证过测试确实仍在跑。

const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Signal = core.Signal;
const Scope = @import("../../reactive.zig").Scope;
const animation = @import("../../animation/mod.zig");
const overlay_stack_mod = @import("../../overlay_stack.zig");
const render_engine = @import("../../core/render_engine/mod.zig");
const floating = @import("../../compute_position.zig");
const popover_mod = @import("mod.zig");
const Popover = popover_mod.Popover;
const PopoverPosition = popover_mod.PopoverPosition;
const AnchorRect = popover_mod.AnchorRect;
const PopoverPositionCtx = popover_mod.PopoverPositionCtx;
const transformOriginForPlacement = popover_mod.transformOriginForPlacement;
const popoverBeforeRender = popover_mod.popoverBeforeRender;
const HIDDEN_OPACITY: f32 = 0.001;

// ========== 测试 ==========

test "Popover: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{}).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // Hidden content is retained off-tree until the popover opens.
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    try std.testing.expect(result.content.parent == null);

    // 初始隐藏
    try std.testing.expectEqual(core.Sizing{ .px = 0 }, result.content.style.width);
    // Default placement is .bottom_start → transform_origin = (0%, 0%) → (0, 0).
    const origin = result.content.style.transform_origin().resolve(200, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0), origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), origin.y, 0.001);
}

test "Popover: every trigger mode keeps floating content in the window portal" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});
    ctx.root = root;

    const portal = try box(ctx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{});
    try root.appendChild(std.testing.allocator, portal);
    ctx.popover_portal_root = portal;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const triggers = [_]popover_mod.PopoverTrigger{ .click, .hover, .manual };
    for (triggers) |trigger| {
        const result = try Popover(.{
            .trigger = trigger,
            // Keep the closed node attached so this test can assert its stable
            // host without coupling to the visibility lifecycle.
            .detach_hidden_content = false,
        }).mount(scope, ctx);

        try std.testing.expect(!result.portaled);
        try std.testing.expect(result.wrapper.parent == null);
        try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
        try std.testing.expect(result.wrapper.children.items[0] == result.trigger);
        try std.testing.expect(result.chrome.parent == portal);
        try std.testing.expect(!result.chrome.isDescendantOf(result.wrapper));

        // The caller always owns placement of the trigger wrapper, including
        // manual mode; only the floating panel is out-of-flow.
        try root.appendChild(std.testing.allocator, result.wrapper);
    }
}

test "Popover: transform origin tracks placement" {
    const cases = [_]struct {
        placement: PopoverPosition,
        expected_x: f32,
        expected_y: f32,
    }{
        .{ .placement = .top_start, .expected_x = 0, .expected_y = 100 },
        .{ .placement = .top, .expected_x = 100, .expected_y = 100 },
        .{ .placement = .top_end, .expected_x = 200, .expected_y = 100 },
        .{ .placement = .bottom_start, .expected_x = 0, .expected_y = 0 },
        .{ .placement = .bottom, .expected_x = 100, .expected_y = 0 },
        .{ .placement = .bottom_end, .expected_x = 200, .expected_y = 0 },
        .{ .placement = .left_start, .expected_x = 200, .expected_y = 0 },
        .{ .placement = .left, .expected_x = 200, .expected_y = 50 },
        .{ .placement = .left_end, .expected_x = 200, .expected_y = 100 },
        .{ .placement = .right_start, .expected_x = 0, .expected_y = 0 },
        .{ .placement = .right, .expected_x = 0, .expected_y = 50 },
        .{ .placement = .right_end, .expected_x = 0, .expected_y = 100 },
    };

    for (cases) |case| {
        const origin = transformOriginForPlacement(case.placement).resolve(200, 100);
        try std.testing.expectApproxEqAbs(case.expected_x, origin.x, 0.001);
        try std.testing.expectApproxEqAbs(case.expected_y, origin.y, 0.001);
    }
}

test "Popover: virtual anchor returns dynamic rect" {
    // 验证 PopoverPositionCtx.anchorRect() 在三种 effective_anchor 模式下都返回正确 rect
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{}, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const trigger = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 20 } }, .{});
    trigger.setLayoutRect(.{ .x = 50, .y = 60, .w = 100, .h = 20 });
    try root.appendChild(std.testing.allocator, trigger);

    // self_trigger
    {
        const open = try scope.createSignal(bool, true);
        const popover = try box(ctx, .{}, .{});
        try root.appendChild(std.testing.allocator, popover);
        var pctx = PopoverPositionCtx{
            .popover = popover,
            .scope = scope,
            .trigger_node = trigger,
            .effective_anchor = .self_trigger,
            .is_open = open,
            .layer_handle = .{ .id = 0, .z_index = 0 },
            .pos = .bottom_start,
            .offset = .{ .static = 0 },
            .cx = ctx,
            .flip = false,
            .fallback_placements = &.{},
            .fallback_placements_ptr = null,
            .preferred_width = null,
            .preferred_max_width = null,
            .preferred_max_height = null,
            .match_trigger_width = false,
            .constrain_width_to_viewport = false,
            .viewport_padding = 0,
            .active_position = .bottom_start,
            .entry_ready = false,
            .prewarmed_ready = false,
            .is_visible = false,
            .prewarm_hidden_layout = false,
            .enter_transition = .none,
            .exit_transition = .none,
        };
        const r = pctx.anchorRect();
        try std.testing.expectEqual(@as(f32, 100), r.w);
        try std.testing.expectEqual(@as(f32, 20), r.h);
    }

    // virtual
    {
        const StateVirt = struct {
            var x: f32 = 200;
            var y: f32 = 300;
            fn cb(_: *anyopaque) AnchorRect {
                return .{ .x = x, .y = y, .w = 0, .h = 18 };
            }
        };
        const open = try scope.createSignal(bool, true);
        const popover = try box(ctx, .{}, .{});
        try root.appendChild(std.testing.allocator, popover);
        var dummy: u32 = 0;
        var pctx = PopoverPositionCtx{
            .popover = popover,
            .scope = scope,
            .trigger_node = trigger,
            .effective_anchor = .{ .virtual = .{ .ctx = @ptrCast(&dummy), .getRect = StateVirt.cb } },
            .is_open = open,
            .layer_handle = .{ .id = 0, .z_index = 0 },
            .pos = .bottom_start,
            .offset = .{ .static = 0 },
            .cx = ctx,
            .flip = false,
            .fallback_placements = &.{},
            .fallback_placements_ptr = null,
            .preferred_width = null,
            .preferred_max_width = null,
            .preferred_max_height = null,
            .match_trigger_width = false,
            .constrain_width_to_viewport = false,
            .viewport_padding = 0,
            .active_position = .bottom_start,
            .entry_ready = false,
            .prewarmed_ready = false,
            .is_visible = false,
            .prewarm_hidden_layout = false,
            .enter_transition = .none,
            .exit_transition = .none,
        };
        // 第一次读
        const r1 = pctx.anchorRect();
        try std.testing.expectEqual(@as(f32, 200), r1.x);
        try std.testing.expectEqual(@as(f32, 300), r1.y);
        try std.testing.expectEqual(@as(f32, 18), r1.h);

        // 移动锚点 → 第二次读返回新值（"reactive" 锚点的关键能力）
        StateVirt.x = 400;
        StateVirt.y = 500;
        const r2 = pctx.anchorRect();
        try std.testing.expectEqual(@as(f32, 400), r2.x);
        try std.testing.expectEqual(@as(f32, 500), r2.y);
    }
}

test "Popover: mount with virtual anchor stores effective_anchor correctly" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const VAnchor = struct {
        fn cb(_: *anyopaque) AnchorRect {
            return .{ .x = 100, .y = 200, .w = 0, .h = 16 };
        }
    };
    var dummy: u32 = 0;
    const result = try Popover(.{
        .trigger = .manual,
        .anchor = .{ .virtual = .{ .ctx = @ptrCast(&dummy), .getRect = VAnchor.cb } },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // 拿出 position_ctx 验证 effective_anchor 是 virtual
    const pctx: *PopoverPositionCtx = @ptrCast(@alignCast(result.content.meta.per_frame.hooks.slots.anim_state.?));
    try std.testing.expect(pctx.effective_anchor == .virtual);
    const r = pctx.anchorRect();
    try std.testing.expectEqual(@as(f32, 100), r.x);
    try std.testing.expectEqual(@as(f32, 200), r.y);
}

test "Popover: toggle open/close" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(result.content.parent == null);

    // 打开
    result.is_open.set(true);
    try std.testing.expect(result.is_open.peek());
    try std.testing.expect(result.content.parent == ctx.popover_portal_root.?);

    // 关闭
    result.is_open.set(false);
    try std.testing.expect(!result.is_open.peek());
}

test "Popover: hidden content detaches from window portal after close commits" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .enter_transition = .none,
        .exit_transition = .none,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    try std.testing.expect(result.content.parent == null);

    result.is_open.set(true);
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    try std.testing.expect(result.content.parent == ctx.popover_portal_root.?);

    const position_ctx: *PopoverPositionCtx = @ptrCast(@alignCast(result.content.meta.per_frame.hooks.slots.anim_state.?));
    position_ctx.entry_ready = true;
    position_ctx.is_visible = true;

    result.is_open.set(false);
    popoverBeforeRender(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    try std.testing.expect(result.content.parent == null);
    try std.testing.expect(!position_ctx.entry_ready);
    try std.testing.expect(!position_ctx.is_visible);
}

test "Popover: reopening during the exit transition cancels the pending close" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .enter_transition = .fade_fast,
        .exit_transition = .fade_fast,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    result.is_open.set(true);
    result.is_open.set(false);
    var layer_ptr: ?*overlay_stack_mod.OverlayLayer = null;
    for (&ctx.overlay_stack.layers) |*slot| {
        if (slot.*) |*l| layer_ptr = l;
    }
    const layer = layer_ptr.?;
    const handle = layer.handle;
    try std.testing.expectEqual(overlay_stack_mod.LayerState.exiting, layer.state);

    // Reopen before the fade-out finishes (completion list re-shown on `.`).
    result.is_open.set(true);
    try std.testing.expect(layer.state != .exiting);

    // Play well past the fade: the old exit must not commit and close it.
    _ = handle;
    var t: f64 = render_engine.current_frame_time_ms;
    for (0..60) |_| {
        t += 16;
        _ = ctx.overlay_stack.tick(t, 0.016, 400, 300, std.testing.allocator);
    }
    try std.testing.expect(result.is_open.peek());
    try std.testing.expect(!layer.suspended);
}

test "Popover: external visible signal" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const vis = try scope.createSignal(bool, false);
    const result = try Popover(.{}).visible(vis).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // 外部控制
    try std.testing.expect(result.is_open == vis);
    vis.set(true);
    try std.testing.expect(vis.peek());
}

test "Popover: hover trigger" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{ .trigger = .hover }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // hover 触发
    try std.testing.expect(result.wrapper.behavior.events.on_hover != null);
    try std.testing.expect(result.wrapper.behavior.events.on_leave != null);

    result.wrapper.behavior.events.on_hover.?.invoke();
    try std.testing.expect(result.is_open.peek());

    result.wrapper.behavior.events.on_leave.?.invoke();
    try std.testing.expect(!result.is_open.peek());
}

test "Popover: before_render preserves overlay-managed opacity and scale" {
    // 曾 QUARANTINE。原注释的诊断方向是对的（"测试用 stub 绕过了
    // OverlayStack.push 所以 signal 缺失，需要更真实的 fixture"），
    // 但结论"需要教 popoverBeforeRender 去检测 manual_*_animation_active"
    // 是多余的 —— 该逻辑**已经存在**（:791-796 的 overlay_visual_in_progress
    // 就是读这两个 flag + opacity/scale 中间态）。
    //
    // 真正的问题全在 fixture 和断言上，四处：
    //   1. `.layer_handle = .{ .id = 0, .z_index = 0 }` 是**伪造句柄**，
    //      findLayer 查不到对应 layer，走不进 overlay 管理路径。
    //      → 改用真实的 ctx.overlay_stack.push() 返回值并绑定 content_node。
    //   2. 用了已删除的 `node.rect = …` 和 `node.hooks`（rect 已 SoA 化到
    //      World，hook 槽位挪到 meta.per_frame.hooks）。这测试**从写下起
    //      就编译不过**，被 `if (true) return` 挡住才没暴露。
    //      → 改用 setLayoutRect / meta.per_frame.hooks.slots。
    //   3. 手工建的节点默认带 layout dirty，会走 "pause unstable-layout"
    //      分支——那条路径**本来就该**把 opacity 压到 HIDDEN_OPACITY。
    //      → 先清 dirty，才测得到"布局已稳定"的目标场景。
    //   4. **原断言本身与设计冲突**：它要求手工写入的 0.35 在 hook 之后
    //      原样保留。但 enter 一旦 ready，before_render 会调
    //      setEnterPaused(handle,false)，OverlayStack 随即
    //      `enter_ctrl.apply(content)` 按动画进度写 opacity（progress=0 → 0）。
    //      **opacity 的所有权此刻属于 overlay controller**，popover 不该也
    //      不会去保留调用方随手设的中间值。
    //      → 改为断言真正的不变量：hook 不把 opacity 打回 HIDDEN_OPACITY
    //        （那才是"闪一下"的 bug 形态），且 enter 被正常放行。
    // 全程未改任何产品代码 —— before_render 的 overlay 感知一直是对的。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const trigger = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    const content = try box(ctx, .{ .position = .absolute, .width = .{ .px = 160 }, .height = .{ .px = 72 } }, .{});
    try root.appendChild(std.testing.allocator, trigger);
    try root.appendChild(std.testing.allocator, content);

    trigger.setLayoutRect(.{ .x = 40, .y = 24, .w = 120, .h = 32 });
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 72 });
    content.style.overflow_hidden = false;
    // 手工构造的节点默认带着 layout dirty，会让 before_render 走
    // "pause unstable-layout" 分支（那条路径本就该把 opacity 压到 HIDDEN）。
    // 本测试要验的是**布局已稳定**时的 enter 动画中间态，故先清干净
    // （与邻接的 "pauses enter until content subtree is ready" 同做法）。
    content.frame_state.state_bits.dirty.core.layout = false;
    content.frame_state.state_bits.dirty.core.subtree_layout = false;

    // 真实 overlay layer（而非伪造 handle），并置于 enter 动画进行中：
    // opacity/scale 都是 overlay 动画写下的中间值。
    const handle = try ctx.overlay_stack.push(.{
        .kind = .non_modal,
        .dismiss = .{},
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    });
    if (ctx.overlay_stack.findLayer(handle)) |layer| {
        layer.content_node = content;
    }

    content.setOpacityRaw(0.35);
    const ext = content.style.ensureExtPanic(std.testing.allocator);
    ext.scale_x = 0.92;
    ext.scale_y = 0.94;
    content.frame_state.state_bits.flags.manual_opacity_animation_active = true;
    content.frame_state.state_bits.flags.manual_transform_animation_active = true;

    const open = try scope.createSignal(bool, true);
    var position_ctx = PopoverPositionCtx{
        .popover = content,
        .scope = scope,
        .trigger_node = trigger,
        .effective_anchor = .self_trigger,
        .is_open = open,
        .layer_handle = handle,
        .pos = .bottom_start,
        .offset = .{ .static = 8 },
        .cx = ctx,
        .flip = false,
        .preferred_width = null,
        .preferred_max_width = null,
        .preferred_max_height = null,
        .match_trigger_width = false,
        .constrain_width_to_viewport = false,
        .viewport_padding = 8,
        .active_position = .bottom_start,
        .entry_ready = false,
        .prewarmed_ready = false,
        .is_visible = false,
        .prewarm_hidden_layout = true,
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    };
    content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(content);

    // 不变量 1：布局已稳定时，hook 不得把 popover 打回"隐藏待命"状态
    // （HIDDEN_OPACITY≈0.001）。那是 pause 分支的行为，出现在这里就意味着
    // 弹层会闪一下再出现。
    try std.testing.expect(content.getOpacity() != HIDDEN_OPACITY);

    // 不变量 2：enter 被放行，且所有权移交 overlay controller ——
    // opacity 由 enter_ctrl 按动画进度写入（progress=0 → 0），
    // scale 同理回到 transition 的起始 scale。
    try std.testing.expect(position_ctx.entry_ready);
    try std.testing.expect(position_ctx.is_visible);
    try std.testing.expect(!ctx.overlay_stack.findLayer(handle).?.enter_paused);

    // 不变量 3：定位已生效（弹层落到 trigger 下方，而非停在 0）。
    try std.testing.expect(content.style.translate_y > 0);
}

test "Popover: none transition becomes opaque when positioned" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const trigger = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    const content = try box(ctx, .{ .position = .absolute, .width = .{ .px = 160 }, .height = .{ .px = 72 } }, .{});
    try root.appendChild(std.testing.allocator, trigger);
    try root.appendChild(std.testing.allocator, content);
    trigger.setLayoutRect(.{ .x = 40, .y = 24, .w = 120, .h = 32 });
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 72 });
    content.style.overflow_hidden = false;
    content.setOpacityRaw(0);
    content.frame_state.state_bits.dirty.core.layout = false;
    content.frame_state.state_bits.dirty.core.subtree_layout = false;

    const handle = try ctx.overlay_stack.push(.{
        .kind = .non_modal,
        .dismiss = .{},
        .enter_transition = .none,
        .exit_transition = .none,
    });
    if (ctx.overlay_stack.findLayer(handle)) |layer| layer.content_node = content;

    const open = try scope.createSignal(bool, true);
    var position_ctx = PopoverPositionCtx{
        .popover = content,
        .scope = scope,
        .trigger_node = trigger,
        .effective_anchor = .self_trigger,
        .is_open = open,
        .layer_handle = handle,
        .pos = .bottom_start,
        .offset = .{ .static = 8 },
        .cx = ctx,
        .flip = false,
        .preferred_width = null,
        .preferred_max_width = null,
        .preferred_max_height = null,
        .match_trigger_width = false,
        .constrain_width_to_viewport = false,
        .viewport_padding = 8,
        .active_position = .bottom_start,
        .entry_ready = false,
        .prewarmed_ready = false,
        .is_visible = false,
        .prewarm_hidden_layout = false,
        .enter_transition = .none,
        .exit_transition = .none,
    };
    content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(content);

    try std.testing.expect(position_ctx.entry_ready);
    try std.testing.expect(position_ctx.is_visible);
    try std.testing.expectEqual(@as(f32, 1), content.getOpacity());
    try std.testing.expect(content.style.translate_y > 0);
}

test "Popover: before_render keeps active exiting layer visible until commit" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const trigger = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    const content = try box(ctx, .{ .position = .absolute, .width = .{ .px = 160 }, .height = .{ .px = 72 } }, .{});
    try root.appendChild(std.testing.allocator, trigger);
    try root.appendChild(std.testing.allocator, content);

    trigger.setLayoutRect(.{ .x = 40, .y = 24, .w = 120, .h = 32 });
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 72 });
    content.style.overflow_hidden = false;
    content.setOpacityRaw(1);

    const handle = try ctx.overlay_stack.push(.{
        .kind = .non_modal,
        .dismiss = .{},
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    });
    if (ctx.overlay_stack.findLayer(handle)) |layer| {
        layer.content_node = content;
    }
    ctx.overlay_stack.beginExit(handle);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const open = try scope.createSignal(bool, false);
    var position_ctx = PopoverPositionCtx{
        .popover = content,
        .scope = scope,
        .trigger_node = trigger,
        .effective_anchor = .self_trigger,
        .is_open = open,
        .layer_handle = handle,
        .pos = .bottom_start,
        .offset = .{ .static = 8 },
        .cx = ctx,
        .flip = false,
        .preferred_width = null,
        .preferred_max_width = null,
        .preferred_max_height = null,
        .match_trigger_width = false,
        .constrain_width_to_viewport = false,
        .viewport_padding = 8,
        .active_position = .bottom_start,
        .entry_ready = false,
        .prewarmed_ready = false,
        .is_visible = false,
        .prewarm_hidden_layout = true,
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    };
    content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(content);

    try std.testing.expectEqual(@as(f32, 160), content.style.width.px);
    try std.testing.expectEqual(@as(f32, 72), content.style.height.px);
    try std.testing.expect(!content.style.overflow_hidden);
}

test "Popover: before_render pauses enter until content subtree is ready" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const trigger = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    const content = try box(ctx, .{ .position = .absolute, .width = .{ .px = 160 }, .height = .{ .px = 72 } }, .{});
    try root.appendChild(std.testing.allocator, trigger);
    try root.appendChild(std.testing.allocator, content);

    trigger.setLayoutRect(.{ .x = 40, .y = 24, .w = 120, .h = 32 });
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 72 });
    // 未就绪 = **布局**未稳定。此前这里只置 subtree_render，断言 pause ——
    // 那是 69ac08f（popover portal 化）之前的旧合同。现在 popoverContentReady
    // 刻意不再看 subtree_render：要求它干净会让刚打开的 overlay 死锁
    //（隐藏子树在被定位并准入前画不完第一帧，而定位又在等这一帧）。
    // 详见 popover/mod.zig:popoverContentReady 的注释。
    content.frame_state.state_bits.dirty.core.subtree_render = true;
    content.frame_state.state_bits.dirty.core.subtree_layout = true;
    content.frame_state.state_bits.dirty.core.layout = false;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const open = try scope.createSignal(bool, true);

    const handle = try ctx.overlay_stack.push(.{
        .kind = .non_modal,
        .dismiss = .{},
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    });
    ctx.overlay_stack.reactivate(handle);

    var position_ctx = PopoverPositionCtx{
        .popover = content,
        .scope = scope,
        .trigger_node = trigger,
        .effective_anchor = .self_trigger,
        .is_open = open,
        .layer_handle = handle,
        .pos = .bottom_start,
        .offset = .{ .static = 8 },
        .cx = ctx,
        .flip = false,
        .preferred_width = null,
        .preferred_max_width = null,
        .preferred_max_height = null,
        .match_trigger_width = false,
        .constrain_width_to_viewport = false,
        .viewport_padding = 8,
        .active_position = .bottom_start,
        .entry_ready = false,
        .prewarmed_ready = false,
        .is_visible = false,
        .prewarm_hidden_layout = true,
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    };
    content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(content);

    try std.testing.expect(!position_ctx.entry_ready);
    try std.testing.expect(!position_ctx.is_visible);
    try std.testing.expectApproxEqAbs(HIDDEN_OPACITY, content.getOpacity(), 0.0001);
    const layer = ctx.overlay_stack.findLayer(handle).?;
    try std.testing.expect(layer.enter_paused);
}

test "Popover: subtree_render 脏不阻止定位（死锁防回归）" {
    // 配对测试：上一个测试守"布局脏 ⇒ pause"，这个守它的**反面** ——
    // 仅 subtree_render 脏（布局已稳定）时必须照常定位并 ready。
    //
    // 若有人"修复"popoverContentReady 把 subtree_render 加回就绪条件，
    // 刚打开的 overlay 会死锁：隐藏子树在被定位准入前画不完第一帧，
    // 而定位又在等这一帧。那种改动会让本测试变红。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const trigger = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    const content = try box(ctx, .{ .position = .absolute, .width = .{ .px = 160 }, .height = .{ .px = 72 } }, .{});
    try root.appendChild(std.testing.allocator, trigger);
    try root.appendChild(std.testing.allocator, content);

    trigger.setLayoutRect(.{ .x = 40, .y = 24, .w = 120, .h = 32 });
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 72 });
    // 布局干净、只有渲染脏 —— 这正是"刚打开的隐藏子树"的真实状态
    content.frame_state.state_bits.dirty.core.subtree_render = true;
    content.frame_state.state_bits.dirty.core.subtree_layout = false;
    content.frame_state.state_bits.dirty.core.layout = false;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const open = try scope.createSignal(bool, true);

    const handle = try ctx.overlay_stack.push(.{
        .kind = .non_modal,
        .dismiss = .{},
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    });
    ctx.overlay_stack.reactivate(handle);

    var position_ctx = PopoverPositionCtx{
        .popover = content,
        .scope = scope,
        .trigger_node = trigger,
        .effective_anchor = .self_trigger,
        .is_open = open,
        .layer_handle = handle,
        .pos = .bottom_start,
        .offset = .{ .static = 8 },
        .cx = ctx,
        .flip = false,
        .preferred_width = null,
        .preferred_max_width = null,
        .preferred_max_height = null,
        .match_trigger_width = false,
        .constrain_width_to_viewport = false,
        .viewport_padding = 8,
        .active_position = .bottom_start,
        .entry_ready = false,
        .prewarmed_ready = false,
        .is_visible = false,
        .prewarm_hidden_layout = true,
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    };
    content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(content);

    try std.testing.expect(position_ctx.entry_ready);
    const layer = ctx.overlay_stack.findLayer(handle).?;
    try std.testing.expect(!layer.enter_paused);
}

test "Popover: prewarmed hidden content reopens without ready-frame pause" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const trigger = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    const content = try box(ctx, .{ .position = .absolute, .width = .{ .px = 160 }, .height = .{ .px = 72 } }, .{});
    try root.appendChild(std.testing.allocator, trigger);
    try root.appendChild(std.testing.allocator, content);

    trigger.setLayoutRect(.{ .x = 40, .y = 24, .w = 120, .h = 32 });
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 72 });
    content.setOpacityRaw(HIDDEN_OPACITY);
    const ext = content.style.ensureExtPanic(std.testing.allocator);
    ext.scale_x = 0.92;
    ext.scale_y = 0.92;
    content.frame_state.state_bits.dirty.core.subtree_render = false;
    content.frame_state.state_bits.dirty.core.subtree_layout = false;
    content.frame_state.state_bits.dirty.core.layout = false;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const open = try scope.createSignal(bool, false);

    const handle = try ctx.overlay_stack.push(.{
        .kind = .non_modal,
        .dismiss = .{},
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    });
    if (ctx.overlay_stack.findLayer(handle)) |layer| {
        layer.content_node = content;
        layer.suspended = true;
    }

    var position_ctx = PopoverPositionCtx{
        .popover = content,
        .scope = scope,
        .trigger_node = trigger,
        .effective_anchor = .self_trigger,
        .is_open = open,
        .layer_handle = handle,
        .pos = .bottom_start,
        .offset = .{ .static = 8 },
        .cx = ctx,
        .flip = false,
        .preferred_width = null,
        .preferred_max_width = null,
        .preferred_max_height = null,
        .match_trigger_width = false,
        .constrain_width_to_viewport = false,
        .viewport_padding = 8,
        .active_position = .bottom_start,
        .entry_ready = false,
        .prewarmed_ready = false,
        .is_visible = false,
        .prewarm_hidden_layout = true,
        .enter_transition = .scale_fade,
        .exit_transition = .scale_fade,
    };
    content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(content);

    open.set(true);
    ctx.overlay_stack.reactivate(handle);
    popoverBeforeRender(content);

    try std.testing.expect(position_ctx.entry_ready);
    try std.testing.expect(position_ctx.is_visible);
    try std.testing.expect(!ctx.overlay_stack.findLayer(handle).?.enter_paused);
}

test "Popover: prewarm keeps content measurable after close (reopen fast-path)" {
    // 本测试原名 "closed initial render prewarms measurable content"，长期
    // QUARANTINE，注释称"content.rect 8 帧后仍是 0 …… render-pipeline
    // expectation drift，需要 real investigation"。
    //
    // **排查结论：不是 render pipeline 的问题，是原测试断言了一个不可达的场景。**
    // 初始关闭态下，overlay layer 处于 suspended，popoverBeforeRender 在开头
    // 就 early-return（:804-812 的 `if (layer.suspended) { detach…; return; }`），
    // **根本走不到** :899-903 那段 prewarm 尺寸恢复。所以初始关闭态的
    // content.rect 恒为 0，与 settle 多少帧、prewarm 开不开都无关。
    // （实测：插桩确认该 early-return 在 prewarm=true 时同样命中。）
    //
    // prewarm_hidden_layout 真正的语义是"**开过一次之后**，关闭时保留已测量的
    // 布局，让重开无需再等 ready-frame"——即 reopen fast-path，而不是"从未打开
    // 过就先测量好"。故本测试改为验证这个真实不变量：开 → 关 → content 仍可测量。
    // 初始关闭态 rect==0 的行为由邻接的
    // "can collapse hidden content when prewarm disabled" 覆盖。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .click,
        // 两者缺一不可：detach 默认 true 会把关闭态 content 整个摘出树，
        // 脱离树的节点既不 layout 也不跑 before_render hook。
        .prewarm_hidden_layout = true,
        .detach_hidden_content = false,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const trigger_box = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);

    const content_text = try core.text(ctx, "Popover content", .{});
    try result.content.appendChild(std.testing.allocator, content_text);

    ctx.layout();
    _ = ctx.render();

    // 打开并 settle：此时 content 被真正测量。
    result.is_open.set(true);
    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
        if (result.content.rectFromWorldOrFallback().w > 0) break;
    }
    try std.testing.expect(result.content.rectFromWorldOrFallback().w > 0);

    // 关闭并 settle：prewarm 的作用是让尺寸**保留**下来（而非塌回 0），
    // 这样下次打开不必再等一个 ready frame。
    result.is_open.set(false);
    iter = 0;
    while (iter < 8) : (iter += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
    }

    try std.testing.expect(result.content.rectFromWorldOrFallback().w > 0);
    try std.testing.expect(result.content.rectFromWorldOrFallback().h > 0);
}

test "Popover: closed initial render can collapse hidden content when prewarm disabled" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .manual,
        .prewarm_hidden_layout = false,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const content_text = try core.text(ctx, "Popover content", .{});
    try result.content.appendChild(std.testing.allocator, content_text);

    ctx.layout();
    _ = ctx.render();

    try std.testing.expectEqual(@as(f32, 0), result.content.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 0), result.content.rectFromWorldOrFallback().h);
    try std.testing.expect(result.content.style.overflow_hidden);
    try std.testing.expectEqual(@as(f32, 0), result.content.getOpacity());
}

test "Popover: open render emits content text at panel position after prewarm settles" {
    // History: 需要多帧 settle (popover prewarm 是多帧路径)。
    //
    // P6.3 后 Popover 走 composited_group surface（整组 scale_fade）。断言真正不变量「content text 被绘制 + 落在 panel 世界位置（trigger 下方）」，
    // 而非旧的 begin/end_opacity_layer 包裹顺序（那条 promoted-surface 路径会丢 children + 弹层飞
    // (0,0)，是组件不可用的根因，见 docs/BUGS.md）。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .click,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const trigger_box = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);

    const content_text = try core.text(ctx, "Popover content", .{});
    try result.content.appendChild(std.testing.allocator, content_text);

    ctx.layout();
    _ = ctx.render();

    result.is_open.set(true);

    var commands: []const @import("../../core.zig").paint_table.DisplayItem = &.{};
    var text_idx: ?usize = null;
    var text_geom_x: f32 = 0;
    var text_geom_y: f32 = 0;
    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
        commands = ctx.lowerForEncoderPaintTable();
        text_idx = null;
        // P6.3 后 popover content 在 composited surface 内：text geom 是 surface-local。
        // 世界坐标 = M_composite 平移分量 − src 原点 + local geom
        // （M = owner_world·Translate(src)，encoder 先减 src 再施 M，settle 时
        //  owner_world = Translate(owner_pos) ⇒ world = M_t − src + geom）。
        var surf_tx: f32 = 0;
        var surf_ty: f32 = 0;
        var surf_src_x: f32 = 0;
        var surf_src_y: f32 = 0;
        var in_surface = false;
        for (commands, 0..) |cmd, i| {
            if (cmd.kind == .control) {
                switch (cmd.control_kind) {
                    .begin_opacity_layer => {
                        in_surface = true;
                        surf_tx = cmd.draw_transform[4];
                        surf_ty = cmd.draw_transform[5];
                        surf_src_x = cmd.geom.x;
                        surf_src_y = cmd.geom.y;
                    },
                    .end_opacity_layer => in_surface = false,
                    else => {},
                }
                continue;
            }
            if (cmd.isText()) {
                const txt = cmd;
                if (std.mem.eql(u8, txt.text_content, "Popover content")) {
                    text_idx = i;
                    if (in_surface) {
                        text_geom_x = surf_tx - surf_src_x + txt.geom.x;
                        text_geom_y = surf_ty - surf_src_y + txt.geom.y;
                    } else {
                        text_geom_x = txt.geom.x;
                        text_geom_y = txt.geom.y;
                    }
                }
            }
        }
        if (text_idx != null) break;
    }

    // content text 必须被绘制（promoted-surface 路径曾整段丢 children）。
    try std.testing.expect(text_idx != null);
    // 且（换算到世界坐标后）落在 trigger 下方（bottom_start + offset）。曾经的 bug 把它甩到 (0,0)。
    const trigger_rect = result.trigger.globalRect();
    try std.testing.expect(text_geom_y > trigger_rect.y + trigger_rect.h - 1.0);
    try std.testing.expect(text_geom_x >= trigger_rect.x - 1.0);
}

test "Popover: first open render keeps content scale_fade intermediate state" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .click,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const trigger_box = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);

    const content_text = try core.text(ctx, "Popover content", .{});
    try result.content.appendChild(std.testing.allocator, content_text);

    ctx.layout();
    _ = ctx.render();

    result.is_open.set(true);
    render_engine.current_frame_time_ms = 16.0;
    render_engine.current_frame_dt_ms = 16.0;
    ctx.layout();
    _ = ctx.render();

    try std.testing.expect(result.content.getOpacity() >= 0.0);
    try std.testing.expect(result.content.getOpacity() <= 1.0);
    try std.testing.expect(result.content.style.scale_x() <= 1.0);
    try std.testing.expect(result.content.style.scale_y() <= 1.0);
}

test "Popover: first 10 open frames progress from enter state instead of flashing" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .click,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const trigger_box = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);
    try result.content.appendChild(std.testing.allocator, try core.text(ctx, "Animated popover", .{}));

    ctx.layout();
    _ = ctx.render();

    result.is_open.set(true);

    var opacities: [10]f32 = undefined;
    var scales: [10]f32 = undefined;
    var now_ms: f64 = 0;
    for (0..10) |i| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        ctx.layout();
        _ = ctx.render();
        opacities[i] = result.content.getOpacity();
        scales[i] = result.content.style.scale_x();
    }

    var first_visible_idx: ?usize = null;
    for (opacities, 0..) |opacity, i| {
        if (opacity > HIDDEN_OPACITY + 0.0001) {
            first_visible_idx = i;
            break;
        }
    }

    if (first_visible_idx) |idx| {
        try std.testing.expect(opacities[idx] < 0.3);
        try std.testing.expect(scales[idx] < 1.0);

        var last_opacity = opacities[idx];
        var last_scale = scales[idx];
        for (opacities[(idx + 1)..], scales[(idx + 1)..]) |opacity, scale| {
            try std.testing.expect(opacity + 0.0001 >= last_opacity);
            try std.testing.expect(scale + 0.0001 >= last_scale);
            last_opacity = opacity;
            last_scale = scale;
        }
    }
}

test "Popover: scale_fade open animation reuses promoted surface for stable text" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .click,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const trigger_box = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);
    try result.content.appendChild(std.testing.allocator, try core.text(ctx, "Stable popover text", .{}));

    ctx.layout();
    _ = ctx.render();

    result.is_open.set(true);

    // Popover enter 是**多帧**路径：content 要等 prewarm/定位 settle 之后才会
    // 注册进 scene_runtime（实测本 fixture 下是第 4 帧）。原测试只跑 1 帧就
    // `scene_runtime.get(...).?`，必然 unwrap null 崩溃 —— 这就是原注释里
    // "not registered until prewarm settles" 的实际表现。
    // 改为 settle 到注册为止，再断言"首个注册帧 rebuild、之后复用"。
    var settle: usize = 0;
    while (settle < 10) : (settle += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
        if (ctx.scene_runtime.get(result.content.id) != null) break;
    }

    // 首个注册帧：surface 刚建好（rebuilt，未复用）。
    const fr = ctx.scene_runtime.get(result.content.id) orelse return error.PopoverNeverRegistered;
    try std.testing.expect(fr.has_active_transform_animation);
    try std.testing.expect(result.content.meta.per_frame.caches.commands.promoted != null);
    try std.testing.expect(fr.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!fr.promoted_surface_flags.reused_this_frame);

    // 下一帧：动画仍在跑，但 surface 应被**复用**而非重建 ——
    // 这正是 scale_fade 期间文字不抖动的前提。
    ctx.frame_time_ms += 16;
    ctx.layout();
    _ = ctx.render();
    const second_runtime = ctx.scene_runtime.get(result.content.id).?;
    try std.testing.expect(second_runtime.has_active_transform_animation);
    try std.testing.expect(second_runtime.promoted_surface_flags.surface_valid);
    try std.testing.expect(second_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!second_runtime.promoted_surface_flags.rebuilt_this_frame);
}

// ========== autosize：可用高度 → max_height（floating-ui size.availableHeight）==========

/// 共用 fixture：640x480 viewport，trigger 在 y=300（下方剩 132、上方剩 284，
/// 均已扣 padding 8 + offset 8），content 高 `content_h`。
const AutosizeFixture = struct {
    cx: *Cx,
    scope: *Scope,
    content: *Node,
    handle: overlay_stack_mod.LayerHandle,
    open: *Signal(bool),
    trigger: *Node,

    fn init(content_h: f32) !AutosizeFixture {
        const cx = try Cx.init(std.testing.allocator);
        errdefer cx.deinit();
        cx.setViewport(640, 480);
        const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
        cx.root = root;
        const scope = try Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();

        const trigger = try box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 32 } }, .{});
        const content = try box(cx, .{ .position = .absolute, .width = .{ .px = 160 }, .height = .{ .fit = .{} } }, .{});
        try root.appendChild(std.testing.allocator, trigger);
        try root.appendChild(std.testing.allocator, content);
        trigger.setLayoutRect(.{ .x = 40, .y = 300, .w = 120, .h = 32 });
        content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = content_h });
        content.style.overflow_hidden = false;
        content.frame_state.state_bits.dirty.core.layout = false;
        content.frame_state.state_bits.dirty.core.subtree_layout = false;

        const handle = try cx.overlay_stack.push(.{
            .kind = .non_modal,
            .dismiss = .{},
            .enter_transition = .none,
            .exit_transition = .none,
        });
        if (cx.overlay_stack.findLayer(handle)) |layer| layer.content_node = content;
        const open = try scope.createSignal(bool, true);
        return .{ .cx = cx, .scope = scope, .content = content, .handle = handle, .open = open, .trigger = trigger };
    }

    fn deinit(self: *AutosizeFixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn positionCtx(self: *AutosizeFixture, preferred_max_height: ?f32) PopoverPositionCtx {
        return .{
            .popover = self.content,
            .scope = self.scope,
            .trigger_node = self.trigger,
            .effective_anchor = .self_trigger,
            .is_open = self.open,
            .layer_handle = self.handle,
            .pos = .bottom_start,
            .offset = .{ .static = 8 },
            .cx = self.cx,
            .flip = true,
            .preferred_width = null,
            .preferred_max_width = null,
            .preferred_max_height = preferred_max_height,
            .match_trigger_width = false,
            .constrain_width_to_viewport = false,
            .viewport_padding = 8,
            .active_position = .bottom_start,
            .entry_ready = false,
            .prewarmed_ready = false,
            .is_visible = false,
            .prewarm_hidden_layout = false,
            .enter_transition = .none,
            .exit_transition = .none,
        };
    }
};

test "Popover autosize: 两侧都放不下且 caller 未设 max_height 时，max_height 收紧到可用高度" {
    // 复现：content 300 高，下方 132 / 上方 284 都放不下 → flip best-fit 选 top。
    // 修前 autosize 只在 caller 设了 max_height 时激活，面板保持 300 高、
    // translate 贴 viewport 顶，下缘越过 trigger 把 reference element 盖住。
    var f = try AutosizeFixture.init(300);
    defer f.deinit();
    var position_ctx = f.positionCtx(null);
    f.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(f.content);

    try std.testing.expect(floating.getSide(position_ctx.active_position) == .top);
    // 284 = trigger.y(300) - padding(8) - offset(8)
    try std.testing.expectApproxEqAbs(@as(f32, 284), f.content.style.max_height(), 0.5);
    // 下一帧 layout 才应用 max_height，本帧必须已标 sizing dirty
    try std.testing.expect(f.content.frame_state.state_bits.dirty.core.layout);
    // cap 咬住内容（300 > 284）→ chrome 必须裁切子节点，否则内容照样溢出外壳压回 trigger
    try std.testing.expect(f.content.style.overflow_hidden);
}

test "Popover autosize: caller max_height 比可用高度更小时以 caller 为准" {
    var f = try AutosizeFixture.init(300);
    defer f.deinit();
    var position_ctx = f.positionCtx(200);
    f.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(f.content);

    try std.testing.expectApproxEqAbs(@as(f32, 200), f.content.style.max_height(), 0.5);
}

test "Popover autosize: 内容放得下时 max_height 不低于内容高度（不产生裁剪）" {
    // content 100 高，下方剩 132 → 留在 bottom，cap = 132 ≥ 100。
    var f = try AutosizeFixture.init(100);
    defer f.deinit();
    var position_ctx = f.positionCtx(null);
    f.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(f.content);

    try std.testing.expect(floating.getSide(position_ctx.active_position) == .bottom);
    try std.testing.expectApproxEqAbs(@as(f32, 132), f.content.style.max_height(), 0.5);
    try std.testing.expect(f.content.style.max_height() >= 100);
    // cap 没咬住 → 不额外裁切（保持 caller 意愿 false）
    try std.testing.expect(!f.content.style.overflow_hidden);
}

test "Popover autosize: 可用高度变大的那一帧仍保持裁切（ph 还贴着旧 cap）" {
    // 复现：打开 tall popover 后滚动页面，trigger 下移 → 上方可用高度逐帧变大。
    // ph 是上一帧按旧 cap 排出的高度，若只和新 cap 比会判定"没咬住"而关掉
    // overflow_hidden，本帧内容（比旧 cap 还高）整块溢出面板；连续滚动 = 连续漏出。
    var f = try AutosizeFixture.init(300);
    defer f.deinit();
    var position_ctx = f.positionCtx(null);
    f.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(f.content);
    try std.testing.expectApproxEqAbs(@as(f32, 284), f.content.style.max_height(), 0.5);
    try std.testing.expect(f.content.style.overflow_hidden);

    // 下一帧：layout 已按 cap 把面板钳到 284；页面滚动让 trigger 下移 20 → 可用 304
    f.content.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 284 });
    f.trigger.setLayoutRect(.{ .x = 40, .y = 320, .w = 120, .h = 32 });
    popoverBeforeRender(f.content);

    try std.testing.expectApproxEqAbs(@as(f32, 304), f.content.style.max_height(), 0.5);
    try std.testing.expect(f.content.style.overflow_hidden);
}

test "Popover autosize: viewport 极挤时保底 AUTOSIZE_MIN_HEIGHT 而非折到 0" {
    var f = try AutosizeFixture.init(300);
    defer f.deinit();
    // trigger 几乎贴顶且占满高度：上方 8、下方 8
    f.trigger.setLayoutRect(.{ .x = 40, .y = 16, .w = 120, .h = 448 });
    var position_ctx = f.positionCtx(null);
    f.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(&position_ctx);

    popoverBeforeRender(f.content);

    try std.testing.expectApproxEqAbs(popover_mod.AUTOSIZE_MIN_HEIGHT, f.content.style.max_height(), 0.5);
}

test "Popover: portal content has no clip and wins hit over clipped trigger container" {
    // 方案 §9.3：C2 删除 z>0 的隐式裁剪逃逸后，"画到容器外"只剩结构性 portal 一条路。
    // trigger 放在一个 overflow_hidden 的小容器里，content 延伸到容器外：content 的
    // retained clip_id 必须为空、它的背景 fill 不在任何 scissor 内、容器外的点命中 content。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 300);

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const clip_box = try box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(std.testing.allocator, clip_box);

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .manual,
        .enter_transition = .none,
        .exit_transition = .none,
    }).mount(scope, ctx);
    try clip_box.appendChild(std.testing.allocator, result.wrapper);

    const trigger_box = try box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);

    const panel_color = Color.rgba(12, 200, 150, 255);
    const panel = try box(ctx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 120 },
        .background = panel_color,
    }, .{});
    panel.setFocusable(true);
    try result.content.appendChild(std.testing.allocator, panel);

    ctx.layout();
    _ = ctx.render();

    result.is_open.set(true);
    var iter: usize = 0;
    while (iter < 12) : (iter += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
    }

    // content 挂在 portal 下，portal 祖先链上没有裁剪。
    try std.testing.expect(result.chrome.parent == ctx.popover_portal_root.?);
    const chrome_rt = ctx.scene_runtime.get(result.chrome.id) orelse return error.ChromeNotRendered;
    try std.testing.expectEqual(core.SceneRuntimeInvalidId, chrome_rt.clip_id);

    // panel 背景 fill 不处于任何 scissor 之内（对照：它的 trigger 所在容器是 40px 高的裁剪框）。
    var depth: usize = 0;
    var found = false;
    for (ctx.lowerForEncoderPaintTable()) |it| {
        if (it.kind == .control) {
            switch (it.control_kind) {
                .push_clip => depth += 1,
                .pop_clip => depth -|= 1,
                else => {},
            }
            continue;
        }
        if (!it.isFillRect()) continue;
        if (it.color.r != panel_color.r or it.color.g != panel_color.g or it.color.b != panel_color.b) continue;
        found = true;
        try std.testing.expectEqual(@as(usize, 0), depth);
        break;
    }
    try std.testing.expect(found);

    // 容器外（y > 40）、panel 内的点命中 panel。
    const panel_rect = panel.globalRect();
    try std.testing.expect(panel_rect.y + panel_rect.h > 60);
    const hit = ctx.hitTest(panel_rect.x + 20, panel_rect.y + panel_rect.h - 10) orelse return error.NoHit;
    try std.testing.expect(hit == panel or hit.isDescendantOf(result.chrome));
}

test "Popover: dropdown transition slides 6px toward the anchor with opacity and settles at rest" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Popover(.{
        .position = .bottom_end,
        .trigger = .click,
        .offset = .{ .static = 6 },
        .enter_transition = .dropdown,
        .exit_transition = .dropdown,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const trigger_box = try box(ctx, .{ .width = .{ .px = 26 }, .height = .{ .px = 20 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);
    try result.content.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{}));

    ctx.layout();
    _ = ctx.render();
    result.is_open.set(true);

    var now_ms: f64 = 0;
    var saw_mid = false;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        ctx.frame_time_ms = now_ms;
        ctx.layout();
        _ = ctx.render();
        const op = result.content.getOpacity();
        if (op > 0.05 and op < 0.95) {
            saw_mid = true;
            // 离开静止位的量 = (1 - opacity) × 6，方向朝上（远离下方落位，靠向锚点一侧）。
            const pctx: *PopoverPositionCtx = @ptrCast(@alignCast(result.content.meta.per_frame.hooks.slots.anim_state.?));
            const dy = result.content.style.translate_y - pctx.rest_translate_y;
            try std.testing.expect(dy < -0.1);
            try std.testing.expect(@abs(dy + (1 - op) * popover_mod.DROPDOWN_SLIDE_PX) < 0.05);
        }
    }
    try std.testing.expect(saw_mid);
    const pctx: *PopoverPositionCtx = @ptrCast(@alignCast(result.content.meta.per_frame.hooks.slots.anim_state.?));
    try std.testing.expectApproxEqAbs(@as(f32, 1), result.content.getOpacity(), 0.001);
    try std.testing.expectApproxEqAbs(pctx.rest_translate_y, result.content.style.translate_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.98), overlay_stack_mod.TransitionController.hiddenScaleForTransition(.dropdown), 0.0001);

    // 退场：定位器不再跑，滑出偏移仍跟着 opacity 推进。
    const rest_y = pctx.rest_translate_y;
    result.is_open.set(false);
    var saw_exit_mid = false;
    for (0..20) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        ctx.frame_time_ms = now_ms;
        ctx.layout();
        _ = ctx.render();
        const op = result.content.getOpacity();
        if (op > 0.05 and op < 0.95) {
            saw_exit_mid = true;
            try std.testing.expect(result.content.style.translate_y < rest_y - 0.1);
        }
    }
    try std.testing.expect(saw_exit_mid);
}

test "Popover: dropdownSlideOffset follows the resolved side" {
    const off_b = popover_mod.dropdownSlideOffset(.bottom, 0);
    try std.testing.expectEqual(@as(f32, -6), off_b[1]);
    const off_t = popover_mod.dropdownSlideOffset(.top, 0.5);
    try std.testing.expectEqual(@as(f32, 3), off_t[1]);
    try std.testing.expectEqual(@as(f32, 0), popover_mod.dropdownSlideOffset(.bottom, 1)[1]);
}

fn openPopoverForConsumeTest(ctx: *Cx, result: anytype, now_ms: *f64) void {
    result.is_open.set(true);
    for (0..20) |_| {
        now_ms.* += 16.0;
        render_engine.current_frame_time_ms = now_ms.*;
        render_engine.current_frame_dt_ms = 16.0;
        ctx.frame_time_ms = now_ms.*;
        ctx.layout();
        _ = ctx.render();
    }
}

fn consumeCase(consume: bool) !usize {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .direction = .column }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var clicks: usize = 0;
    const outside = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    outside.behavior.events.on_click = Cx.simpleHandler(struct {
        fn f(c: *anyopaque) void {
            const n: *usize = @ptrCast(@alignCast(c));
            n.* += 1;
        }
    }.f, &clicks);
    try root.appendChild(std.testing.allocator, outside);

    const result = try Popover(.{
        .position = .bottom_start,
        .trigger = .click,
        .consume_outside_click = consume,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const trigger_box = try box(ctx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{});
    try result.trigger.appendChild(std.testing.allocator, trigger_box);
    try result.content.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } }, .{}));
    ctx.layout();
    _ = ctx.render();
    var now_ms: f64 = 0;
    openPopoverForConsumeTest(ctx, result, &now_ms);
    try std.testing.expect(result.is_open.peek());

    // 第一下点在面板外的按钮上。
    ctx.handleClick(50, 20);
    for (0..20) |_| {
        now_ms += 16;
        render_engine.current_frame_time_ms = now_ms;
        ctx.frame_time_ms = now_ms;
        ctx.layout();
        _ = ctx.render();
    }
    try std.testing.expect(!result.is_open.peek());
    const first = clicks;
    // 关闭后第二下照常触发。
    ctx.handleClick(50, 20);
    try std.testing.expectEqual(first + 1, clicks);
    return first;
}

test "Popover: consume_outside_click closes without activating what was clicked" {
    try std.testing.expectEqual(@as(usize, 0), try consumeCase(true));
    // 对照：默认行为关闭的同时点击照常落到下面。
    try std.testing.expectEqual(@as(usize, 1), try consumeCase(false));
}

const LostUp = enum { cancel_pointer, new_press };

/// 被 consume 吞掉的按下若收不到抬起（窗口失焦 / 指针交互被取消 / 抬起丢失），
/// 吞抬起的标记不能活过这次按下，否则下一次正常点击的抬起被吞、click 不合成。
fn lostUpCase(mode: LostUp) !usize {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .direction = .column }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var clicks: usize = 0;
    const outside = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    outside.behavior.events.on_click = Cx.simpleHandler(struct {
        fn f(c: *anyopaque) void {
            const n: *usize = @ptrCast(@alignCast(c));
            n.* += 1;
        }
    }.f, &clicks);
    try root.appendChild(std.testing.allocator, outside);

    const result = try Popover(.{ .position = .bottom_start, .trigger = .click, .consume_outside_click = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try result.trigger.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{}));
    try result.content.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } }, .{}));
    ctx.layout();
    _ = ctx.render();
    var now_ms: f64 = 0;
    openPopoverForConsumeTest(ctx, result, &now_ms);
    try std.testing.expect(result.is_open.peek());

    // 面板外按下被吞；对应的抬起丢失。
    ctx.handleMouseDown(50, 20, .{});
    try std.testing.expect(ctx.swallowed_press_button != null);
    switch (mode) {
        // 交互取消即结束这次按下：标记当场作废，不指望后续按下兜底。
        .cancel_pointer => {
            ctx.cancelPointerInteractions(.window_blur);
            try std.testing.expect(ctx.swallowed_press_button == null);
        },
        .new_press => {},
    }
    for (0..20) |_| {
        now_ms += 16;
        render_engine.current_frame_time_ms = now_ms;
        ctx.frame_time_ms = now_ms;
        ctx.layout();
        _ = ctx.render();
    }
    try std.testing.expect(!result.is_open.peek());
    // 下一次正常点击必须照常触发。
    ctx.handleClick(50, 20);
    return clicks;
}

test "Popover: consumed press whose mouse-up is lost does not swallow the next click" {
    try std.testing.expectEqual(@as(usize, 1), try lostUpCase(.cancel_pointer));
    try std.testing.expectEqual(@as(usize, 1), try lostUpCase(.new_press));
}

test "Popover: an item that closes a nested popover from its click handler keeps the parent open" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .direction = .column }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try Popover(.{ .position = .bottom_start, .trigger = .click, .consume_outside_click = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.wrapper);
    try outer.trigger.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{}));
    try outer.content.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{}));

    // 内层菜单：manual + 自己的 visible，点菜单项时在 click 回调里关掉它。
    const inner_visible = try core.Signal(bool).createInScope(scope, false);
    const inner = try Popover(.{ .position = .bottom_start, .trigger = .manual, .visible = inner_visible, .consume_outside_click = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, inner.wrapper);
    const item = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 30 } }, .{});
    item.behavior.events.on_click = Cx.simpleHandler(struct {
        fn f(c: *anyopaque) void {
            const sig: *Signal(bool) = @ptrCast(@alignCast(c));
            sig.set(false);
        }
    }.f, @ptrCast(inner_visible));
    try inner.content.appendChild(std.testing.allocator, item);

    ctx.layout();
    _ = ctx.render();
    var now_ms: f64 = 0;
    openPopoverForConsumeTest(ctx, outer, &now_ms);
    inner_visible.set(true);
    for (0..20) |_| {
        now_ms += 16;
        render_engine.current_frame_time_ms = now_ms;
        ctx.frame_time_ms = now_ms;
        ctx.layout();
        _ = ctx.render();
    }
    try std.testing.expect(outer.is_open.peek());
    try std.testing.expect(inner_visible.peek());

    const r = item.globalRect();
    const ir = item.rectFromWorldOrFallback();
    ctx.handleClick(r.x + ir.w / 2, r.y + ir.h / 2);
    for (0..20) |_| {
        now_ms += 16;
        render_engine.current_frame_time_ms = now_ms;
        ctx.frame_time_ms = now_ms;
        ctx.layout();
        _ = ctx.render();
    }
    try std.testing.expect(!inner_visible.peek());
    try std.testing.expect(outer.is_open.peek());
}

const HookTextCtx = struct {
    node: *Node,
    reveal: ?*Node = null,
    armed: bool = false,
    fn hook(n: *Node) void {
        const self: *HookTextCtx = @ptrCast(@alignCast(n.meta.per_frame.hooks.slots.anim_state orelse return));
        if (!self.armed) return;
        self.armed = false;
        self.node.setTextContent(std.testing.allocator, "0 silenced · nothing pops up; summarized once when it ends, and this sentence keeps going so it needs several lines") catch unreachable;
        self.node.markSizingDirty();
        if (self.reveal) |w| {
            w.style.height = .{ .fit = .{} };
            w.markSizingDirty();
            w.setOpacity(1);
        }
    }
};

test "Popover: wrapped text updated from a before_render hook re-wraps and repaints in full" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .direction = .column }, .{});
    ctx.root = root;
    const portal = try box(ctx, .{ .position = .absolute, .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    try root.appendChild(std.testing.allocator, portal);
    ctx.popover_portal_root = portal;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const pop = try Popover(.{ .position = .bottom_start, .trigger = .click, .width = 360, .size_policy = .fit_content }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, pop.wrapper);
    try pop.trigger.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{}));
    pop.chrome.style.direction = .column;
    try pop.content.appendChild(std.testing.allocator, try box(ctx, .{ .width = .fill(), .height = .{ .px = 40 } }, .{}));
    // 先折叠（高 0 + 裁切 + 透明），钩子里与改文本同帧展开——面板横幅的真实时序。
    const collapsed = try box(ctx, .{ .width = .fill(), .direction = .column, .padding = .{ .top = 0, .right = 10, .bottom = 10, .left = 10 } }, .{});
    try pop.content.appendChild(std.testing.allocator, collapsed);
    collapsed.style.height = .{ .px = 0 };
    collapsed.style.overflow_hidden = true;
    collapsed.setOpacityRaw(0);
    const row = try box(ctx, .{ .width = .fill(), .direction = .row, .gap = 10 }, .{});
    try collapsed.appendChild(std.testing.allocator, row);
    const col = try box(ctx, .{ .width = .fill(), .direction = .column, .gap = 1 }, .{});
    try row.appendChild(std.testing.allocator, col);
    const t = try core.text(ctx, "", .{ .font_size = 11.5, .wrap = .word });
    try col.appendChild(std.testing.allocator, t);
    t.style.width = .fill();

    // 钩子挂在主树上的一个节点：模拟宿主在 before_render 里刷新面板文本。
    var hctx: HookTextCtx = .{ .node = t, .reveal = collapsed };
    const driver = try box(ctx, .{ .width = .{ .px = 1 }, .height = .{ .px = 1 } }, .{});
    try root.appendChild(std.testing.allocator, driver);
    driver.meta.per_frame.hooks.slots.anim_state = @ptrCast(&hctx);
    driver.meta.per_frame.hooks.before_render.main = HookTextCtx.hook;

    ctx.layout();
    _ = ctx.render();
    var now_ms: f64 = 0;
    openPopoverForConsumeTest(ctx, pop, &now_ms);
    const one_line_h = t.rectFromWorldOrFallback().h;

    hctx.armed = true;
    driver.markRenderDirty();
    var painted: usize = 0;
    // 真实应用只调 render()（layout 在 render 内部）；额外的 ctx.layout() 会掩盖问题。
    for (0..3) |_| {
        now_ms += 16;
        render_engine.current_frame_time_ms = now_ms;
        ctx.frame_time_ms = now_ms;
        const items = ctx.render();
        painted = 0;
        for (items) |it| {
            if (it == .text_run) painted += it.text_run.content.len;
        }
    }
    try std.testing.expect(t.rectFromWorldOrFallback().h > one_line_h * 2);
    const expected = "0 silenced · nothing pops up; summarized once when it ends, and this sentence keeps going so it needs several lines".len;
    try std.testing.expect(painted + 8 >= expected);
}

fn setRows(ctx: *Cx, content: *Node, n: usize) !void {
    while (content.children.items.len > 0) {
        const c = content.children.items[content.children.items.len - 1];
        ctx.detachChildRetained(content, c);
        ctx.freeNode(c);
    }
    for (0..n) |_| try content.appendChild(std.testing.allocator, try box(ctx, .{ .width = .fill(), .height = .{ .px = 60 } }, .{}));
    content.markLayoutDirty();
}

fn stepFrames(ctx: *Cx, now_ms: *f64, n: usize) void {
    for (0..n) |_| {
        now_ms.* += 16;
        render_engine.current_frame_time_ms = now_ms.*;
        render_engine.current_frame_dt_ms = 16;
        ctx.frame_time_ms = now_ms.*;
        _ = ctx.render();
    }
}

test "Popover fit_content: a shrinkable scroll list grows back when its rows grow again" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .direction = .column }, .{});
    ctx.root = root;
    const portal = try box(ctx, .{ .position = .absolute, .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    try root.appendChild(std.testing.allocator, portal);
    ctx.popover_portal_root = portal;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const pop = try Popover(.{ .position = .bottom_start, .trigger = .click, .width = 300, .size_policy = .fit_content }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, pop.wrapper);
    try pop.trigger.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{}));
    pop.chrome.style.direction = .column;
    const header = try box(ctx, .{ .width = .fill(), .height = .{ .px = 50 } }, .{});
    header.style.flex_shrink = 0;
    try pop.content.appendChild(std.testing.allocator, header);
    const sa = try @import("../scroll_area/mod.zig").mountScrollArea(.{ .direction = .vertical }, scope, ctx);
    try pop.content.appendChild(std.testing.allocator, sa.container);
    sa.container.style.height = .{ .fit = .{ .max = 300 } };
    sa.container.style.flex_shrink = 1;
    sa.content.style.width = .fill();

    try setRows(ctx, sa.content, 6);
    ctx.layout();
    _ = ctx.render();
    var now_ms: f64 = 0;
    openPopoverForConsumeTest(ctx, pop, &now_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 300), sa.container.rectFromWorldOrFallback().h, 1);

    try setRows(ctx, sa.content, 2);
    stepFrames(ctx, &now_ms, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 120), sa.container.rectFromWorldOrFallback().h, 1);

    try setRows(ctx, sa.content, 4);
    stepFrames(ctx, &now_ms, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 240), sa.container.rectFromWorldOrFallback().h, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 290), pop.chrome.rectFromWorldOrFallback().h, 1);
}
