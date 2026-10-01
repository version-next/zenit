/// Sheet / Drawer 组件
///
/// 从屏幕边缘滑入的面板（抽屉），基于 OverlayStack 框架
///
/// 特性:
/// - Signal(bool) 控制显示/隐藏
/// - 四方向滑入: left / right / top / bottom
/// - translate_x/translate_y 隐式过渡动画
/// - OverlayStack 自动管理 z-index、遮罩、焦点陷阱、Escape/outside-click
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Signal = core.Signal;
const Scope = @import("../../reactive.zig").Scope;
const overlay_stack = @import("../../overlay_stack.zig");
const render_engine = @import("../../core/render_engine/mod.zig");

// ── 样式层在 styles.zig ──
const styles = @import("styles.zig");

/// 面板滑入方向
pub const SheetSide = enum {
    left,
    right,
    top,
    bottom,
};

/// Sheet 属性
pub const SheetProps = struct {
    side: SheetSide = .right,
    width: f32 = 320,
    height: f32 = 320,
    overlay_color: ?Color = null,
    background: ?Color = null,
    close_on_overlay: bool = true,
    close_on_escape: bool = true,
    visible: ?*Signal(bool) = null,
    animation_ms: f32 = 250,
};

/// Sheet mount 返回句柄
pub const SheetResult = struct {
    overlay: *Node,
    panel: *Node,
    content: *Node,
    /// 见 Modal.mount：true = overlay 已挂到 portal root，caller 不要再 append。
    portaled: bool = false,
};

fn transitionForSide(side: SheetSide) overlay_stack.Transition {
    return switch (side) {
        .left => .slide_left,
        .right => .slide_right,
        .top => .slide_top,
        .bottom => .slide_bottom,
    };
}

/// 创建 Sheet
pub fn Sheet(props: SheetProps) SheetBuilder {
    return SheetBuilder{ .props = props };
}

pub const SheetBuilder = struct {
    props: SheetProps,

    pub fn side(self: SheetBuilder, s: SheetSide) SheetBuilder {
        var new = self;
        new.props.side = s;
        return new;
    }

    pub fn width(self: SheetBuilder, w: f32) SheetBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn height(self: SheetBuilder, h: f32) SheetBuilder {
        var new = self;
        new.props.height = h;
        return new;
    }

    pub fn visible(self: SheetBuilder, sig: *Signal(bool)) SheetBuilder {
        var new = self;
        new.props.visible = sig;
        return new;
    }

    pub fn closeOnOverlay(self: SheetBuilder, c: bool) SheetBuilder {
        var new = self;
        new.props.close_on_overlay = c;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: SheetBuilder, scope: *Scope, cx: *Cx) !SheetResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // 通过 OverlayStack 创建 modal 层
        const panel_transition = transitionForSide(p.side);
        const ol = try overlay_stack.overlay(my_scope, cx, .{
            .kind = .modal,
            .barrier = .{ .color = styles.sheetBarrierColor(p.overlay_color, t) },
            .dismiss = .{
                .outside_click = if (p.close_on_overlay) .close else .none,
                .escape = p.close_on_escape,
            },
            .enter_transition = panel_transition,
            .exit_transition = panel_transition,
            .focus = .{ .trap = true, .auto_focus = true, .restore = true },
            .on_dismiss = p.visible,
            .a11y = .{ .role = .dialog, .modal = true },
        });

        const barrier = ol.barrier.?;
        // overlay() 把 focus_scope 配在 ol.content 上，但本组件不用 ol.content，
        // 真正 pushScope 的是 barrier，不在 barrier 上配，trap/auto_focus 全是空操作。
        barrier.setFocusScope(.{ .trap = true, .auto_focus = true });
        barrier.meta.ownership.meta.component_name = "Sheet";
        try core.bindScopeToNode(my_scope, barrier);

        // 根据方向设置 overlay 内部排列，使面板靠边
        switch (p.side) {
            .left => {
                barrier.style.direction = .row;
                barrier.style.justify = .start;
                barrier.style.align_items = .stretch;
            },
            .right => {
                barrier.style.direction = .row;
                barrier.style.justify = .end;
                barrier.style.align_items = .stretch;
            },
            .top => {
                barrier.style.direction = .column;
                barrier.style.justify = .start;
                barrier.style.align_items = .stretch;
            },
            .bottom => {
                barrier.style.direction = .column;
                barrier.style.justify = .end;
                barrier.style.align_items = .stretch;
            },
        }

        // panel
        const panel_w: core.Sizing = switch (p.side) {
            .left, .right => .{ .px = p.width },
            .top, .bottom => .{ .grow = .{} },
        };
        const panel_h: core.Sizing = switch (p.side) {
            .left, .right => .{ .grow = .{} },
            .top, .bottom => .{ .px = p.height },
        };

        // sweep：panel 建好即挂进 barrier（barrier 归 overlay 层所有），之后再做可失败的 ensureExt
        const panel = try core.adoptChild(cx, allocator, barrier, try box(cx, .{
            .width = panel_w,
            .height = panel_h,
            .background = styles.sheetPanelBackground(p.background, t),
            .direction = .column,
        }, .{}));
        const panel_ext = try panel.style.ensureExtFallible(allocator);
        panel_ext.setShadows(styles.sheetKeyShadow(t), styles.sheet_ambient_shadow);

        // 位置过渡完全交给 OverlayStack 的 slide_* transition。
        // 这里不要再手工写 translate 初值，否则会和 enter/exit 动画叠加，
        // 让 panel 在查询/抓图时出现“双重偏移”的不稳定状态。

        // 将 OverlayStack 层的真实 content_node 绑定到 panel，
        // 让层级与动画目标保持一致。
        cx.overlay_stack.bindContentNode(allocator, ol.handle, panel);

        // content
        const content = try core.adoptChild(cx, allocator, panel, try box(cx, styles.sheetContentStyle(t), .{}));

        // visible Effect
        if (p.visible) |vis| {
            const fm = &cx.focus_manager;
            const scope_pushed = try my_scope.createSignal(bool, false);
            // 打开状态下直接卸载（Show 切走 / 父 scope dispose）不会再跑 visible
            // effect 的 pop 分支 -> focus scope 栈残留指向已释放 barrier 的条目。
            const scope_guard = try my_scope.allocator.create(FocusScopeGuard);
            scope_guard.* = .{ .fm = fm, .pushed = scope_pushed, .barrier = barrier, .barrier_id = barrier.id };
            try my_scope.adoptResource(@ptrCast(scope_guard), FocusScopeGuard.destroy);
            try my_scope.onCleanup(FocusScopeGuard, scope_guard, FocusScopeGuard.cleanup);

            // 初始隐藏：barrier 缩成 0 + 层挂起
            if (!vis.peek()) {
                barrier.style.width = .{ .px = 0 };
                barrier.style.height = .{ .px = 0 };
                barrier.style.overflow_hidden = true;
                if (cx.overlay_stack.findLayer(ol.handle)) |layer| {
                    layer.suspended = true;
                }
            }

            try my_scope.createEffect(.{
                .barrier = barrier,
                .panel = panel,
                .visible = vis,
                .fm = fm,
                .scope_pushed = scope_pushed,
                .cx = cx,
                .layer_handle = ol.handle,
            }, struct {
                fn update(c: anytype) void {
                    if (c.visible.get()) {
                        if (c.cx.overlay_stack.findLayer(c.layer_handle)) |layer| {
                            if (layer.suspended) {
                                c.cx.overlay_stack.reactivate(c.layer_handle);
                            } else if (layer.state == .exiting) {
                                c.cx.overlay_stack.cancelExit(c.layer_handle, .entering);
                            }
                        }
                        c.barrier.style.width = .{ .grow = .{} };
                        c.barrier.style.height = .{ .grow = .{} };
                        c.barrier.style.overflow_hidden = false;
                        c.barrier.markSizingDirty();
                        if (!c.scope_pushed.peek()) {
                            c.fm.pushScope(c.barrier);
                            c.scope_pushed.set(true);
                        }
                    } else {
                        if (c.cx.overlay_stack.findLayer(c.layer_handle)) |layer| {
                            if (!layer.suspended and layer.state != .exiting) {
                                c.cx.overlay_stack.beginExit(c.layer_handle);
                            }
                        }
                        if (c.scope_pushed.peek()) {
                            c.fm.popScope();
                            c.scope_pushed.set(false);
                        }
                    }
                    c.barrier.markSizingDirty();
                    c.barrier.markRenderDirty();
                    c.cx.needs_redraw = true;
                }
            }.update);
        }

        return .{ .overlay = barrier, .panel = panel, .content = content, .portaled = ol.portaled };
    }
};

/// 卸载时弹出本组件仍压着的 focus scope。只在栈顶确实是自己时弹
/// （popScope 只弹栈顶；嵌套时乱弹会把上层浮层的 scope 弹掉）。
/// 只比 id / 指针，不解引用 barrier（cleanup 时它可能已在释放途中）。
const FocusScopeGuard = struct {
    fm: *@FieldType(core.Cx, "focus_manager"),
    pushed: *Signal(bool),
    barrier: *Node,
    barrier_id: u32,

    fn cleanup(g: *FocusScopeGuard) void {
        if (!g.pushed.peek()) return;
        g.pushed.set(false);
        const fm = g.fm;
        if (fm.scope_count == 0) return;
        const top = fm.scope_count - 1;
        const is_ours = if (fm.scope_stack_handles[top]) |h|
            h.id == g.barrier_id
        else
            fm.scope_stack[top] == g.barrier;
        if (is_ours) fm.popScope();
    }

    fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const g: *FocusScopeGuard = @ptrCast(@alignCast(ptr));
        alloc.destroy(g);
    }
};

// ========== 测试 ==========

test "Sheet: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Sheet(.{
        .side = .right,
        .width = 300,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    // overlay 包含 panel
    try std.testing.expectEqual(@as(usize, 1), result.overlay.children.items.len);
    // panel 包含 content
    try std.testing.expectEqual(@as(usize, 1), result.panel.children.items.len);
    // absolute 定位
    try std.testing.expectEqual(core.Position.absolute, result.overlay.style.position);
}

test "Sheet: visible signal control" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, false);

    const result = try Sheet(.{
        .side = .left,
    }).visible(vis).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    try std.testing.expectEqual(core.Sizing{ .px = 0 }, result.overlay.style.width);

    vis.set(true);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.width);

    vis.set(false);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.width);
    var exiting_found = false;
    for (ctx.overlay_stack.layers) |slot| {
        if (slot) |layer| {
            try std.testing.expectEqual(overlay_stack.LayerState.exiting, layer.state);
            exiting_found = true;
            break;
        }
    }
    try std.testing.expect(exiting_found);

    var test_time: f64 = 0;
    var ticks: u32 = 0;
    while (ticks < 32) : (ticks += 1) {
        test_time += 16.0;
        render_engine.current_frame_time_ms = test_time;
        _ = ctx.overlay_stack.tick(test_time, 0.016, 800, 600, std.testing.allocator);
    }

    try std.testing.expectEqual(core.Sizing{ .px = 0 }, result.overlay.style.width);
}

test "Sheet: 打开状态下卸载会弹出自己的 focus scope" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, true);

    const sub = try scope.childScope();
    const result = try Sheet(.{ .side = .right }).visible(vis).mount(sub, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    const fm = &ctx.focus_manager;
    try std.testing.expectEqual(@as(u8, 1), fm.scope_count);

    sub.dispose();
    try std.testing.expectEqual(@as(u8, 0), fm.scope_count);
    try std.testing.expect(fm.activeScope() == null);
}

test "Sheet: 打开时 focus trap 生效并自动聚焦到对话框内" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    ctx.setViewport(800, 600);
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, false);

    const outside = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    outside.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, outside);

    const result = try Sheet(.{ .side = .right }).visible(vis).mount(scope, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    const inside = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    inside.behavior.interaction.focusable = true;
    try result.content.appendChild(std.testing.allocator, inside);

    ctx.layout();
    const fm = &ctx.focus_manager;
    fm.setFocus(outside);
    vis.set(true);

    try std.testing.expect(fm.getFocused() == inside);
    const order = fm.scopedFocusOrder();
    for (order) |n| try std.testing.expect(n != outside);
}

test "Sheet: exiting keeps overlay visible until commit" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, true);

    const result = try Sheet(.{
        .side = .right,
    }).visible(vis).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    vis.set(false);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.width);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.height);

    var exiting_found = false;
    for (ctx.overlay_stack.layers) |slot| {
        if (slot) |layer| {
            if (layer.state == .exiting) {
                exiting_found = true;
                break;
            }
        }
    }
    try std.testing.expect(exiting_found);
}

test "Sheet: four sides" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 有 root 时 overlay_stack.overlay() 总是把 barrier portal 化（与 Popover 同一个
    // window portal），caller 不再 inline append，按 `portaled` 契约行事。
    inline for (.{ SheetSide.left, SheetSide.right, SheetSide.top, SheetSide.bottom }) |s| {
        const result = try Sheet(.{ .side = s }).mount(scope, ctx);
        try std.testing.expect(result.portaled);
        try std.testing.expect(result.overlay.parent == ctx.popover_portal_root.?);
    }

    try std.testing.expectEqual(@as(usize, 4), ctx.popover_portal_root.?.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expect(root.children.items[0] == ctx.popover_portal_root.?);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "sheet: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("sheet", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Sheet(.{}).mount(scope, cx);
            return r.overlay;
        }
    }.m);
}
