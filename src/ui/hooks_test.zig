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
const invalidateSubtreeHookState = hooks.invalidateSubtreeHookState;
const ToggleState = hooks.ToggleState;
const useFocusRing = hooks.useFocusRing;
const FocusRingAnimState = hooks.FocusRingAnimState;

test "removeAllChildren cleanup reentry preserves siblings and World links" {
    const Mode = enum { self_detach, sibling_detach, reparent, recursive_clear, reorder };
    const Probe = struct {
        cx: *Cx,
        parent: *core.Node,
        destination: *core.Node,
        nodes: [3]*core.Node,
        calls: [3]u32 = .{ 0, 0, 0 },
        mode: Mode,
        fn first(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.calls[0] += 1;
            switch (p.mode) {
                .self_detach => p.cx.detachChild(p.parent, p.nodes[0]),
                .sibling_detach => p.cx.detachChild(p.parent, p.nodes[1]),
                .reparent => p.destination.appendChild(p.cx.allocator, p.nodes[0]) catch unreachable,
                .recursive_clear => p.parent.removeAllChildren(),
                .reorder => {},
            }
        }
        fn second(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.calls[1] += 1;
            if (p.mode == .reorder and p.nodes[0].parent == p.parent) {
                // B stays at index 1 and length stays 3, but unvisited C moves
                // behind the traversal cursor. Slot/length checks miss it.
                p.parent.replaceChildOrder(p.cx.allocator, &.{ p.nodes[2], p.nodes[1], p.nodes[0] }) catch unreachable;
            }
        }
        fn third(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.calls[2] += 1;
        }
    };
    for ([_]bool{ false, true }) |nested| {
        for (std.enums.values(Mode)) |mode| {
            const cx = try Cx.init(std.testing.allocator, std.testing.io);
            defer cx.deinit();
            const root = try core.box(cx, .{}, .{});
            cx.root = root;
            const parent = try core.box(cx, .{}, .{});
            const destination = try core.box(cx, .{}, .{});
            try root.appendChild(cx.allocator, parent);
            try root.appendChild(cx.allocator, destination);
            var outer: ?*core.Node = null;
            if (nested) {
                outer = try core.box(cx, .{}, .{});
                try root.appendChild(cx.allocator, outer.?);
                try outer.?.appendChild(cx.allocator, parent);
            }
            var nodes: [3]*core.Node = undefined;
            for (&nodes) |*slot| {
                slot.* = try core.box(cx, .{}, .{});
                try parent.appendChild(cx.allocator, slot.*);
                slot.*.frame_state.state_bits.flags.is_mounted = true;
            }
            var probe = Probe{ .cx = cx, .parent = parent, .destination = destination, .nodes = nodes, .mode = mode };
            onCleanup(nodes[0], Cx.simpleHandler(Probe.first, &probe));
            onCleanup(nodes[1], Cx.simpleHandler(Probe.second, &probe));
            onCleanup(nodes[2], Cx.simpleHandler(Probe.third, &probe));
            (outer orelse parent).removeAllChildren();
            try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, &probe.calls);
            if (nested) {
                try std.testing.expect(parent.parent == null);
                // Detaching a subtree cleans descendants but retains their links.
                parent.removeAllChildren();
            }
            try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
            const parent_eid = core.world.ElementId.fromRaw(parent.element_id_raw);
            try std.testing.expectEqual(@as(u32, 0), cx.world.elements.childCount(parent_eid));
            for (nodes, 0..) |node, i| {
                const expected_parent: ?*core.Node = if (mode == .reparent and i == 0) destination else null;
                try std.testing.expect(node.parent == expected_parent);
                const links = cx.world.elements.links(core.world.ElementId.fromRaw(node.element_id_raw)).?;
                if (expected_parent) |p| {
                    try std.testing.expect(links.parent.eql(core.world.ElementId.fromRaw(p.element_id_raw)));
                } else {
                    try std.testing.expect(links.parent.isNull());
                    cx.freeNode(node);
                }
            }
            if (nested) cx.freeNode(parent);
        }
    }
}

test "useHover: basic" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, node);

    const is_hovered = try useHover(scope, node);

    // initial state
    try std.testing.expect(!is_hovered.get());

    // simulate hover
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(is_hovered.get());

    // simulate leave
    node.behavior.events.on_leave.?.invoke();
    try std.testing.expect(!is_hovered.get());
}

test "useHoverHighlight: border_color with animation" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const container = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const inner = try box(ctx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
        .border = .{ .width = 1, .color = t.tokens.color.checkbox_border },
    }, .{});
    try root.appendChild(std.testing.allocator, container);
    try container.appendChild(std.testing.allocator, inner);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const render_engine = @import("core/render_engine/mod.zig");
    var now_ms: f64 = 0;

    _ = try useHoverHighlight(scope, container, inner, .border_color, t.tokens.color.checkbox_border, t.tokens.color.accent, .{});

    // initial: normal color
    try std.testing.expect(Color.eql(inner.style.border.color, t.tokens.color.checkbox_border));

    // hover -> animation triggered, after enough ticks should converge to accent color. note:
    // setTarget uses render_engine.current_frame_time_ms as animation start (hooks.zig:609), so
    // must **set frame clock to current value first then invoke**, else start at 0 but ticks from
    // 16ms, progress misaligned.
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
    try std.testing.expect(Color.eql(inner.style.border.color, t.tokens.color.accent));

    // leave -> after enough frames restore normal color (align frame clock first too)
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
    try std.testing.expect(Color.eql(inner.style.border.color, t.tokens.color.checkbox_border));
}

test "onMount: triggered after layout" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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

    // doesn't trigger before layout
    try std.testing.expect(!mounted);
    try std.testing.expect(!child.frame_state.state_bits.flags.is_mounted);

    // triggers after layout
    ctx.layout();
    try std.testing.expect(mounted);
    try std.testing.expect(child.frame_state.state_bits.flags.is_mounted);

    // re-layout doesn't trigger again
    mounted = false;
    root.markLayoutDirty();
    ctx.layout();
    try std.testing.expect(!mounted); // not duplicate
}

test "onCleanup: triggered on removeChild" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const child = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, child);

    // counter not bool: double-trigger's second write true has no effect, history missed on_cleanup
    // second invoke on detachChild -> freeNode chain (refcount underflow bug)
    var clean_count: u32 = 0;
    onCleanup(child, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(c));
            ptr.* += 1;
        }
    }.handler, &clean_count));

    // layout first to mount
    ctx.layout();
    try std.testing.expect(child.frame_state.state_bits.flags.is_mounted);
    try std.testing.expectEqual(@as(u32, 0), clean_count);

    // remove triggers cleanup
    ctx.detachChild(root, child);
    try std.testing.expectEqual(@as(u32, 1), clean_count);
    try std.testing.expect(!child.frame_state.state_bits.flags.is_mounted);

    // manually free removed node (not in tree, ctx.deinit won't free). freeNode must not trigger
    // on_cleanup again, one-time consume.
    ctx.freeNode(child);
    try std.testing.expectEqual(@as(u32, 1), clean_count);
}

test "onCleanup: recursive for nested children" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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

    // removing parent_node should also trigger child cleanup
    ctx.detachChild(root, parent_node);
    try std.testing.expectEqual(@as(u32, 1), parent_clean_count);
    try std.testing.expectEqual(@as(u32, 1), child_clean_count);

    // manually free removed node; subtree nodes' on_cleanup must not trigger twice
    ctx.freeNode(parent_node);
    try std.testing.expectEqual(@as(u32, 1), parent_clean_count);
    try std.testing.expectEqual(@as(u32, 1), child_clean_count);
}

test "invalidateSubtreeHookState detaches hook back-pointers before scope dispose" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});

    const ring_state: *FocusRingAnimState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.focus_ring_anim.?));
    try std.testing.expect(ring_state.node == node);

    invalidateSubtreeHookState(node);

    try std.testing.expect(ring_state.node == null);

    scope.dispose();
    try std.testing.expect(node.meta.per_frame.hooks.slots.focus_ring_anim == null);
}

test "invalidateSubtreeHookState unhooks focus-ring handlers so blur after scope dispose is safe" {
    // reproduce Notification in-place convert: invalidate hook, dispose scope first, then unlink
    // while focus still on node (clearFocus -> on_blur). pre-fix on_blur reads/writes FocusRingCtx
    // / signal freed with scope.
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    const Prev = struct {
        var blurs: u32 = 0;
        fn onBlur(_: *anyopaque) void {
            blurs += 1;
        }
    };
    Prev.blurs = 0;
    var dummy: u8 = 0;
    node.behavior.events.on_blur = Cx.simpleHandler(Prev.onBlur, &dummy);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    try useFocusRing(scope, ctx, node, .{});
    ctx.focus_manager.setFocus(node);

    invalidateSubtreeHookState(node);
    // focus ring handler removed, restore original handler
    try std.testing.expect(node.behavior.events.on_focus == null);
    try std.testing.expect(node.behavior.events.on_blur.?.callback == &Prev.onBlur);
    scope.dispose();
    ctx.detachChildRetained(root, node); // clearFocus -> on_blur: only call original handler
    try std.testing.expectEqual(@as(u32, 1), Prev.blurs);
    ctx.freeNode(node);
}

test "focus hook in a scope disposed before the node unhooks itself; hooks above it keep chaining" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    const Base = struct {
        focus: usize = 0,
        blur: usize = 0,
        fn onFocus(c: *anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(c))).focus += 1;
        }
        fn onBlur(c: *anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(c))).blur += 1;
        }
    };
    var base: Base = .{};
    node.behavior.events.on_focus = Cx.simpleHandler(Base.onFocus, @ptrCast(&base));
    node.behavior.events.on_blur = Cx.simpleHandler(Base.onBlur, @ptrCast(&base));

    // outer outlives inner; inner's hooks sit between the base handlers and outer's hook.
    const outer = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer outer.dispose();
    const inner = try Scope.init(std.testing.allocator, outer, ctx.owner);
    try useFocusRing(inner, ctx, node, .{});
    _ = try hooks.useFocusState(inner, ctx, node);
    const outer_state = try hooks.useFocusState(outer, ctx, node);

    inner.dispose();
    // Freed contexts are no longer reachable: focus / blur run outer's hook, then the base.
    ctx.setFocus(node);
    try std.testing.expect(outer_state.focused.peek());
    try std.testing.expectEqual(@as(usize, 1), base.focus);
    ctx.clearFocus();
    try std.testing.expect(!outer_state.focused.peek());
    try std.testing.expectEqual(@as(usize, 1), base.blur);
    try std.testing.expect(node.behavior.events.on_focus.?.context != @as(*anyopaque, @ptrCast(&base)));

    // Teardown in the order a bound component uses: the node's hooks come off, then the scope.
    invalidateSubtreeHookState(node);
    try std.testing.expect(node.behavior.events.on_focus.?.context == @as(*anyopaque, @ptrCast(&base)));
    try std.testing.expect(node.behavior.events.on_blur.?.context == @as(*anyopaque, @ptrCast(&base)));
}

test "focus ring in a child scope of the node's bound scope: disposing the bound scope is safe" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    // A component scope bound to its root, with the ring hook installed by an element scope
    // beneath it (the shape a Yix component with focusRing mounts). Children dispose first.
    const component = try Scope.init(std.testing.allocator, null, ctx.owner);
    try core.bindScopeToNode(component, node);
    const element = try Scope.init(std.testing.allocator, component, ctx.owner);
    try useFocusRing(element, ctx, node, .{});
    try std.testing.expect(node.behavior.events.on_focus != null);

    component.dispose();
    try std.testing.expect(node.behavior.events.on_focus == null);
    try std.testing.expect(node.behavior.events.on_blur == null);
    ctx.setFocus(node);
    ctx.clearFocus();
}

test "freeNode detaches hook back-pointers for nodes owned by external scope" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const parent = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } }, .{});
    try root.appendChild(std.testing.allocator, parent);

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    try parent.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    try useFocusRing(scope, ctx, node, .{});

    const anim_state: *FocusRingAnimState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.focus_ring_anim.?));
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});

    // initial: no outline
    try std.testing.expect(node.style.outline() == null);

    // Tab focus -> after enough frames outline appears (opacity -> 1.0)
    ctx.focus_manager.setFocusWithReason(node, .tab);
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() != null);
    // outline color alpha should be close to focus_ring original alpha
    // LKxqO / Foundations: 2px focus ring with 2px offset.
    try std.testing.expectEqual(@as(f32, 2), node.style.outline().?.width);
    try std.testing.expectEqual(@as(f32, 2), node.style.outline().?.offset);
    // color should be close to focus_ring (alpha may be identical due to opacity=1.0)
    try std.testing.expect(Color.eql(node.style.outline().?.color, t.tokens.color.focus_ring));

    // blur -> after enough frames outline disappears (opacity -> 0.0)
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});

    // mouse click focus -> outline still not shown after tick
    ctx.focus_manager.setFocusWithReason(node, .click);
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() == null);
}

test "useFocusRing: focused input scrolled out of ScrollArea does not steal clicks" {
    // spec $9.2 item 14 (appendix A probe 3 component version). useFocusRing on focus-visible
    // raises control to z_index=1 (over siblings). old impl z>0 cleared ancestor clip chain, got
    // global stacking_z: control scrolled outside ScrollArea viewport, pixels clipped, yet stole
    // header outside-viewport clicks.
    const box = core.box;
    const scroll_area = @import("components/scroll_area/mod.zig");
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(300, 300);

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const header = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    header.setFocusable(true);
    try root.appendChild(std.testing.allocator, header);

    const area = try scroll_area.ScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }).mount(scope, ctx);
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

    // Tab focus -> focus-visible -> z_index raised to 1.
    ctx.focus_manager.setFocusWithReason(field, .tab);
    try std.testing.expectEqual(@as(i16, 1), field.style.z_index());
    ctx.frame_time_ms += 16;
    ctx.layout();
    _ = ctx.render();

    // not scrolled: field in viewport (world y = 100+150 = 250..290), hittable.
    try std.testing.expectEqual(field, ctx.hitTest(20, 260).?);

    // scroll 200: field world y = 50..90, entire above viewport (y >= 100), in header area.
    scroll_area.setScrollY(area.state, area.content, 200);
    ctx.frame_time_ms += 16;
    ctx.layout();
    _ = ctx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 50), field.globalRect().y, 0.5);
    try std.testing.expectEqual(@as(i16, 1), field.style.z_index());

    // header area outside viewport must hit header, not clipped-invisible field.
    try std.testing.expectEqual(header, ctx.hitTest(20, 60).?);
}

test "useFocusRing: custom config with tab" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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

    ctx.focus_manager.setFocusWithReason(node, .tab);
    // tick enough frames for animation convergence
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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

test "hover subscriptions detach independently and survive callback disposal" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const a = try scope.childScope();
    const b = try scope.childScope();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    _ = try useHover(a, node);
    const second = try useHover(b, node);
    a.dispose(); // oldest listener first; newer listener stays wired
    try std.testing.expectEqual(@as(u8, 1), node.meta.ownership.debug_slots.signal_count);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(second)), node.meta.ownership.debug_slots.signals[0].?.ptr);
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(second.peek());
    b.dispose();
    try std.testing.expectEqual(@as(u8, 0), node.meta.ownership.debug_slots.signal_count);
    try std.testing.expect(node.behavior.events.on_hover == null);
    const c = try scope.childScope();
    _ = try useHover(c, node);
    const Callback = struct {
        scope: ?*Scope,
        node: *core.Node,
        calls: usize = 0,
        fn remove(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.scope) |child| {
                self.scope = null;
                child.dispose();
                // Cleanup is deferred. A reentrant event must skip pending scopes.
                self.node.behavior.events.on_hover.?.invoke();
            }
        }
    };
    const callback = try scope.createState(Callback, .{ .scope = c, .node = node });
    hooks.setHoverHandler(node, true, Cx.simpleHandler(Callback.remove, callback));
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), callback.calls);
    try std.testing.expect(node.meta.per_frame.hooks.slots.hover_listeners == null);
    try std.testing.expectEqual(@as(u8, 0), node.meta.ownership.debug_slots.signal_count);
    node.behavior.events.on_hover = null;
}

test "hover handler replacement preserves subscriptions and cleanup preserves a later writer" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const child = try scope.childScope();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    const hover = try useHover(child, node);
    const Callback = struct {
        fn run(raw: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    var calls: usize = 0;
    const callback = Cx.simpleHandler(Callback.run, &calls);
    hooks.setHoverHandler(node, true, callback);
    try std.testing.expect(hooks.hoverHandlersIntact(node));
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(hover.peek());
    try std.testing.expectEqual(@as(usize, 1), calls);
    // Deliberate contract violation: detected before native dispatch, but cleanup
    // still must not clobber the later callback in builds without assertions.
    node.behavior.events.on_hover = callback;
    try std.testing.expect(!hooks.hoverHandlersIntact(node));
    child.dispose();
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expect(node.behavior.events.on_leave == null);
}

test "useFocusRing: modality and overrides update same owner without focus events" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const node = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, node);
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const Counts = struct {
        focus: usize = 0,
        blur: usize = 0,
        fn onFocus(p: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.focus += 1;
        }
        fn onBlur(p: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.blur += 1;
        }
    };
    var counts: Counts = .{};
    node.behavior.events.on_focus = Cx.simpleHandler(Counts.onFocus, &counts);
    node.behavior.events.on_blur = Cx.simpleHandler(Counts.onBlur, &counts);
    const state = try @import("hooks.zig").useFocusState(scope, cx, node);
    try useFocusRing(scope, cx, node, .{ .width = 1, .duration = 0 });
    cx.focus_manager.setFocus(node);
    try std.testing.expect(state.focused.get());
    try std.testing.expect(!state.visible.get());
    try std.testing.expect(node.style.outline() == null);
    cx.focus_manager.noteInputModality(.keyboard);
    try std.testing.expect(state.visible.get());
    try std.testing.expectEqual(@as(f32, 1), node.style.outline().?.width);
    cx.focus_manager.setFocusWithVisibility(node, .programmatic, .hide);
    try std.testing.expect(!state.visible.get());
    try std.testing.expectEqual(@import("focus.zig").InputModality.keyboard, cx.focus_manager.input_modality);
    cx.focus_manager.setFocus(node);
    try std.testing.expect(state.visible.get());
    cx.focus_manager.noteInputModality(.pointer);
    try std.testing.expect(!state.visible.get());
    cx.focus_manager.setFocusWithVisibility(node, .programmatic, .show);
    try std.testing.expect(state.visible.get());
    cx.focus_manager.setFocus(node);
    try std.testing.expect(!state.visible.get());
    try std.testing.expectEqual(@as(usize, 1), counts.focus);
    try std.testing.expectEqual(@as(usize, 0), counts.blur);
}

test "useFocusRing: prior handler clears focus without publishing stale visibility" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const Clear = struct {
        fn run(p: *anyopaque) void {
            const c: *Cx = @ptrCast(@alignCast(p));
            c.focus_manager.clearFocus();
        }
    };
    node.behavior.events.on_focus = Cx.simpleHandler(Clear.run, cx);
    const state = try @import("hooks.zig").useFocusState(scope, cx, node);
    try useFocusRing(scope, cx, node, .{});
    cx.focus_manager.setFocusWithReason(node, .tab);
    try std.testing.expect(cx.focus_manager.getFocused() == null);
    try std.testing.expect(!state.focused.get());
    try std.testing.expect(!state.visible.get());
    try std.testing.expect(node.style.outline() == null);
}

test "useFocusRing: disposed scope unregisters handlers and visibility subscription" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    _ = try @import("hooks.zig").useFocusState(scope, cx, node);
    try useFocusRing(scope, cx, node, .{});
    cx.focus_manager.setFocusWithReason(node, .tab);
    scope.dispose();
    try std.testing.expectEqual(@as(usize, 0), cx.focus_manager.visibility_listeners.items.len);
    try std.testing.expect(node.behavior.events.on_focus == null);
    try std.testing.expect(node.behavior.events.on_blur == null);
    cx.focus_manager.noteInputModality(.pointer);
    cx.focus_manager.noteInputModality(.keyboard);
    cx.focus_manager.clearFocus();
}

test "useFocusRing: component config propagates one logical pixel and reacts" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const Config = @import("ui.zig").FocusRingConfig;
    const config = try scope.createSignal(Config, .{ .width = 1, .offset = 0, .duration = 0 });
    const button = try @import("components/button/mod.zig").Button(.{ .label = "Focus", .focus_ring = config }).mount(scope, cx);
    try root.appendChild(cx.allocator, button);
    cx.focus_manager.setFocusWithReason(button, .tab);
    try std.testing.expectEqual(@as(f32, 1), button.style.outline().?.width);
    try std.testing.expectEqual(@as(f32, 0), button.style.outline().?.offset);
    config.set(.{ .width = 3, .offset = 4, .duration = 0 });
    for (button.meta.per_frame.hooks.before_render.hooks[0..button.meta.per_frame.hooks.before_render.count]) |callback| {
        if (callback) |f| f(button);
    }
    try std.testing.expectEqual(@as(f32, 3), button.style.outline().?.width);
    try std.testing.expectEqual(@as(f32, 4), button.style.outline().?.offset);
}

test "useFocusRing: prior handler disposes hook scope safely" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    const Dispose = struct {
        fn run(p: *anyopaque) void {
            const s: *Scope = @ptrCast(@alignCast(p));
            s.dispose();
        }
    };
    node.behavior.events.on_focus = Cx.simpleHandler(Dispose.run, scope);
    _ = try @import("hooks.zig").useFocusState(scope, cx, node);
    try useFocusRing(scope, cx, node, .{});
    cx.focus_manager.setFocusWithReason(node, .tab);
    try std.testing.expectEqual(@as(usize, 0), cx.focus_manager.visibility_listeners.items.len);
    // The application's own handler borrowed that disposed scope too.
    node.behavior.events.on_focus = null;
    cx.focus_manager.clearFocus();
}

test "useFocusRing: external scope cleanup after Cx does not touch freed manager" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    // An independent owner lets the external scope outlive the Cx.
    const owner = try core.SignalOwner.init(std.testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(std.testing.allocator, null, owner);
    defer scope.dispose();
    _ = try @import("hooks.zig").useFocusState(scope, cx, node);
    try useFocusRing(scope, cx, node, .{});
    cx.deinit();
}

test "useFocusRing: another focus owner does not dirty or animate an idle ring" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const idle = try core.box(cx, .{}, .{});
    const target = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, idle);
    try root.appendChild(cx.allocator, target);
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    try useFocusRing(scope, cx, idle, .{});
    try useFocusRing(scope, cx, target, .{});
    idle.frame_state.state_bits.dirty = std.mem.zeroes(@TypeOf(idle.frame_state.state_bits.dirty));
    const content_version = idle.meta.per_frame.caches.versions.content;
    const anim: *@import("hooks.zig").FocusRingAnimState = @ptrCast(@alignCast(idle.meta.per_frame.hooks.slots.focus_ring_anim.?));
    cx.focus_manager.setFocusWithReason(target, .tab);
    cx.focus_manager.noteInputModality(.pointer);
    cx.focus_manager.noteInputModality(.keyboard);
    cx.focus_manager.clearFocus();
    try std.testing.expectEqual(content_version, idle.meta.per_frame.caches.versions.content);
    try std.testing.expect(!idle.frame_state.state_bits.dirty.core.render);
    try std.testing.expect(!idle.frame_state.state_bits.dirty.core.subtree_render);
    try std.testing.expect(!anim.opacity_anim.isAnimating());
    try std.testing.expectEqual(@as(f32, 0), anim.opacity_anim.getTarget());
}

test "useFocusRing: one logical pixel outline expands node geometry and effective radii" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 120);
    const root = try core.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    cx.root = root;
    const node = try core.box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } }, .{});
    (try node.style.ensureExtFallible(cx.allocator)).corner_radius = .{ .each = .{ 0, 4, 8, 12 } };
    try root.appendChild(cx.allocator, node);
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    try useFocusRing(scope, cx, node, .{ .width = 1, .offset = 2, .duration = 0 });
    cx.focus_manager.setFocusWithReason(node, .tab);
    cx.layout();
    const items = cx.render();
    var outlines: usize = 0;
    for (items) |item| switch (item) {
        .outline_rect => |outline| {
            outlines += 1;
            try std.testing.expectApproxEqAbs(@as(f32, -3), outline.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, -3), outline.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 86), outline.w, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 46), outline.h, 0.001);
            try std.testing.expectEqual(@as(f32, 1), outline.width);
            for (outline.radius, [_]f32{ 3, 7, 11, 15 }) |actual, expected|
                try std.testing.expectApproxEqAbs(expected, actual, 0.001);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), outlines);
}
