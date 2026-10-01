/// Modal Component
///
/// 模态对话框组件，基于 OverlayStack 框架
///
/// 特性:
/// - Signal(bool) 控制显示/隐藏
/// - OverlayStack 自动管理 z-index、遮罩、焦点陷阱、Escape/outside-click 关闭
/// - 支持标题和关闭按钮
/// - fade 入场/退场动画
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const theme = core.theme;
const Signal = core.Signal;
const svg_assets = @import("../../svg_assets.zig");
const Scope = @import("../../reactive.zig").Scope;
const overlay_stack = @import("../../overlay_stack.zig");
const render_engine = @import("../../core/render_engine/mod.zig");

/// Modal 属性
pub const ModalProps = struct {
    /// 标题
    title: ?[]const u8 = null,
    /// 宽度
    width: f32 = 480,
    /// 最大高度
    max_height: f32 = 600,
    /// 遮罩颜色 (null = 使用主题 overlay)
    overlay_color: ?Color = null,
    /// 对话框背景
    background: ?Color = null,
    /// 点击遮罩关闭
    close_on_overlay: bool = true,
    /// 显示控制 Signal（外部传入）
    visible: ?*Signal(bool) = null,
    /// 关闭按钮 SVG 资产（可选，null 则回退文本 ✕）
    close_icon_asset: ?svg_assets.Asset = null,
};

// ── 样式层在 styles.zig ──
const styles = @import("styles.zig");
const close_icon_size = styles.close_icon_size;
const dialogStyle = styles.dialogStyle;
const dialogAmbientShadow = styles.dialogAmbientShadow;
const headerStyle = styles.headerStyle;
const titleBoxStyle = styles.titleBoxStyle;
const titleTextStyle = styles.titleTextStyle;
const closeBtnStyle = styles.closeBtnStyle;
const closeGlyphBoxStyle = styles.closeGlyphBoxStyle;
const closeGlyphTextStyle = styles.closeGlyphTextStyle;
const bodyStyle = styles.bodyStyle;

/// 创建 Modal
pub fn Modal(props: ModalProps) ModalBuilder {
    return ModalBuilder{ .props = props };
}

/// ModalBuilder.mount 的返回结果
pub const ModalResult = struct { overlay: *Node, dialog: *Node, body: *Node, portaled: bool };

pub const ModalBuilder = struct {
    props: ModalProps,

    pub fn title(self: ModalBuilder, t: []const u8) ModalBuilder {
        var new = self;
        new.props.title = t;
        return new;
    }

    pub fn width(self: ModalBuilder, w: f32) ModalBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn maxHeight(self: ModalBuilder, h: f32) ModalBuilder {
        var new = self;
        new.props.max_height = h;
        return new;
    }

    pub fn visible(self: ModalBuilder, sig: *Signal(bool)) ModalBuilder {
        var new = self;
        new.props.visible = sig;
        return new;
    }

    pub fn closeOnOverlay(self: ModalBuilder, c: bool) ModalBuilder {
        var new = self;
        new.props.close_on_overlay = c;
        return new;
    }

    /// 保留模式: mount
    /// portaled=true 时 overlay 已自动挂到 cx.popover_portal_root（覆盖整窗口），
    /// caller 不要再 appendChild(overlay)；false 时（无 portal，如单测）caller 仍需 append。
    pub fn mount(self: ModalBuilder, scope: *Scope, cx: *Cx) !ModalResult {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // 通过 OverlayStack 创建 modal 层
        const ol = try overlay_stack.overlay(my_scope, cx, .{
            .kind = .modal,
            .barrier = .{ .color = p.overlay_color orelse t.color.overlay },
            .dismiss = .{
                .outside_click = if (p.close_on_overlay) .close else .none,
                .escape = true,
            },
            .enter_transition = .scale_fade,
            .exit_transition = .scale_fade,
            .focus = .{ .trap = true, .auto_focus = true, .restore = true },
            .on_dismiss = p.visible,
            .a11y = .{ .role = .dialog, .label = p.title, .modal = true },
        });

        // barrier 节点作为 overlay（包含 dialog 的容器）
        const barrier = ol.barrier.?;
        // overlay() 把 focus_scope 配在 ol.content 上，但本组件不用 ol.content，
        // 真正 pushScope 的是 barrier，不在 barrier 上配，trap/auto_focus 全是空操作。
        barrier.setFocusScope(.{ .trap = true, .auto_focus = true });
        barrier.meta.ownership.meta.component_name = "Modal";
        try core.bindScopeToNode(my_scope, barrier);
        scope_bound = true;
        errdefer {
            if (barrier.parent) |parent| cx.detachChild(parent, barrier);
            cx.freeNode(barrier);
        }

        // dialog 容器
        const dialog = try box(cx, dialogStyle(p.width, p.max_height, p.background, t), .{});
        try appendModalChild(cx, barrier, dialog);
        const dialog_ext = try dialog.style.ensureExtFallible(allocator);
        dialog_ext.setShadows(t.shadow.lg, dialogAmbientShadow());

        // 将 OverlayStack 层的真实 content_node 绑定到 dialog，
        // 让 tick() 中的入场/退场动画（fade）作用在 dialog 上。
        cx.overlay_stack.bindContentNode(allocator, ol.handle, dialog);

        // header（如果有标题）
        if (p.title) |title_text| {
            const header = try box(cx, headerStyle(t), .{});
            try appendModalChild(cx, dialog, header);

            var title_node = try box(cx, titleBoxStyle(t), .{});
            try appendModalChild(cx, header, title_node);
            var title_txt = titleTextStyle(t);
            title_txt.content = title_text;
            title_node.setText(title_txt);

            if (p.visible) |vis| {
                const close_btn = try box(cx, closeBtnStyle(t), .{});
                try appendModalChild(cx, header, close_btn);
                if (p.close_icon_asset) |asset| {
                    const close_icon = try core.iconTint(cx, asset, t.color.fg_secondary, .{
                        .width = .{ .px = close_icon_size },
                        .height = .{ .px = close_icon_size },
                    });
                    try appendModalChild(cx, close_btn, close_icon);
                } else {
                    var text_btn = try box(cx, closeGlyphBoxStyle(t), .{});
                    try appendModalChild(cx, close_btn, text_btn);
                    var glyph_txt = closeGlyphTextStyle(t);
                    glyph_txt.content = "\xe2\x9c\x95";
                    text_btn.setText(glyph_txt);
                }

                close_btn.behavior.events.on_click = core.Cx.simpleHandler(
                    struct {
                        fn handler(context: *anyopaque) void {
                            const sig: *Signal(bool) = @ptrCast(@alignCast(context));
                            sig.set(false);
                        }
                    }.handler,
                    @ptrCast(vis),
                );
                close_btn.meta.ownership.meta.test_id = "modal.close";
            }
        }

        // body
        const body = try box(cx, bodyStyle(t), .{});
        try appendModalChild(cx, dialog, body);

        // visible Signal 控制显隐（通过 Effect 驱动 OverlayStack）
        if (p.visible) |vis| {
            const fm = &cx.focus_manager;
            const scope_pushed = try my_scope.createSignal(bool, false);
            // 打开状态下直接卸载（Show 切走 / 父 scope dispose）不会再跑 visible
            // effect 的 pop 分支 -> focus scope 栈残留指向已释放 barrier 的条目。
            const scope_guard = try my_scope.allocator.create(FocusScopeGuard);
            scope_guard.* = .{ .fm = fm, .pushed = scope_pushed, .barrier = barrier, .barrier_id = barrier.id };
            try my_scope.adoptResource(@ptrCast(scope_guard), FocusScopeGuard.destroy);
            try my_scope.onCleanup(FocusScopeGuard, scope_guard, FocusScopeGuard.cleanup);

            // 初始隐藏：barrier 缩成 0 + 层挂起（直接设 suspended，不走 commitExit）。
            // 还必须整棵摘出 hit-test：overflow_hidden 只裁视觉不裁命中，
            // 溢出 0×0 barrier 的 dialog 内容会在窗口左上角留下一片
            // 不可见热区，吃掉底下控件的 hover/click。
            if (!vis.peek()) {
                barrier.style.width = .{ .px = 0 };
                barrier.style.height = .{ .px = 0 };
                barrier.style.overflow_hidden = true;
                barrier.setHitTestVisible(false);
                if (cx.overlay_stack.findLayer(ol.handle)) |layer| {
                    layer.suspended = true;
                }
            }

            try my_scope.createEffect(.{
                .barrier = barrier,
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
                        c.barrier.setHitTestVisible(true);
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
                        c.barrier.setHitTestVisible(false);
                    }
                    c.barrier.markSizingDirty();
                    c.barrier.markRenderDirty();
                    c.cx.needs_redraw = true;
                }
            }.update);
        }

        return .{ .overlay = barrier, .dialog = dialog, .body = body, .portaled = ol.portaled };
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

fn appendModalChild(cx: *Cx, parent: *Node, child: *Node) !void {
    parent.appendChild(cx.allocator, child) catch |err| {
        cx.freeNode(child);
        return err;
    };
}

// ========== 测试 ==========

test "Modal: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Modal(.{
        .title = "Test Modal",
        .width = 400,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    // overlay(barrier) 包含 dialog
    try std.testing.expectEqual(@as(usize, 1), result.overlay.children.items.len);
    // dialog 包含 header + body
    try std.testing.expectEqual(@as(usize, 2), result.dialog.children.items.len);
    // absolute 定位
    try std.testing.expectEqual(core.Position.absolute, result.overlay.style.position);
}

test "Modal: visible signal control" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, false);

    const result = try Modal(.{
        .title = "Toggle Modal",
    }).visible(vis).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    // 初始隐藏
    try std.testing.expectEqual(core.Sizing{ .px = 0 }, result.overlay.style.width);

    // 显示
    vis.set(true);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.width);

    // 隐藏
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
    while (ticks < 16) : (ticks += 1) {
        test_time += 16.0;
        render_engine.current_frame_time_ms = test_time;
        _ = ctx.overlay_stack.tick(test_time, 0.016, 800, 600, std.testing.allocator);
    }

    try std.testing.expectEqual(core.Sizing{ .px = 0 }, result.overlay.style.width);
}

test "Modal: 打开状态下卸载会弹出自己的 focus scope" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, true);

    const sub = try scope.childScope();
    const result = try Modal(.{ .title = "Unmount open" }).visible(vis).mount(sub, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    const fm = &ctx.focus_manager;
    try std.testing.expectEqual(@as(u8, 1), fm.scope_count);

    sub.dispose();
    try std.testing.expectEqual(@as(u8, 0), fm.scope_count);
    try std.testing.expect(fm.activeScope() == null);
}

test "Modal: 打开时 focus trap 生效并自动聚焦到对话框内" {
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

    const result = try Modal(.{ .title = "Trap" }).visible(vis).mount(scope, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    const inside = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    inside.behavior.interaction.focusable = true;
    try result.body.appendChild(std.testing.allocator, inside);

    ctx.layout();
    const fm = &ctx.focus_manager;
    fm.setFocus(outside);
    vis.set(true);

    try std.testing.expect(fm.getFocused() == inside);
    const order = fm.scopedFocusOrder();
    for (order) |n| try std.testing.expect(n != outside);
}

test "Modal: exiting keeps overlay visible until commit" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, true);

    const result = try Modal(.{
        .title = "Exit Modal",
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

test "Modal: first 10 open frames progress from enter state instead of flashing" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(800, 600);

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, false);

    const result = try Modal(.{
        .title = "Animated Modal",
        .width = 400,
    }).visible(vis).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.overlay);

    ctx.layout();
    _ = ctx.render();

    vis.set(true);

    var opacities: [10]f32 = undefined;
    var scales: [10]f32 = undefined;
    var now_ms: f64 = 0;
    for (0..10) |i| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        ctx.layout();
        _ = ctx.render();
        opacities[i] = result.dialog.getOpacity();
        scales[i] = result.dialog.style.scale_x();
    }

    var first_visible_idx: ?usize = null;
    for (opacities, 0..) |opacity, i| {
        if (opacity > 0.001) {
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

test "Modal: long title wraps instead of overflowing dialog" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(800, 600);

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Modal(.{
        .title = "Do you want to save changes to \"03-canvas-engine-research.md\" before closing this window forever?",
        .width = 320,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.overlay);

    ctx.layout();

    const header = result.dialog.children.items[0];
    const title_box = header.children.items[0];
    const title_rect = title_box.rectFromWorldOrFallback();
    const dialog_rect = result.dialog.rectFromWorldOrFallback();

    // 标题盒宽被约束在 dialog 内（旧行为：fit 内容宽 -> 水平溢出 dialog）
    try std.testing.expect(title_rect.w <= dialog_rect.w);
    // 折行后高度超过单行（14px * 1.4 ≈ 19.6；旧行为固定 20px 裁掉第二行）
    try std.testing.expect(title_rect.h > 30);
}

test "Modal: no title" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Modal(.{}).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    // 无标题: dialog 只有 body
    try std.testing.expectEqual(@as(usize, 1), result.dialog.children.items.len);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

test "Modal: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("modal", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Modal(.{ .title = "Test Modal", .width = 400 }).mount(scope, cx);
            return r.overlay;
        }
    }.m);
}
