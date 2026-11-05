/// Modal Component
///
/// Modal dialog component, based on the OverlayStack framework
///
/// Features:
/// - Signal(bool) controls show/hide
/// - OverlayStack auto-manages z-index, mask, focus trap, Escape/outside-click close
/// - Supports title and close button
/// - fade in/out animation
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const theme = core.theme;
const Signal = core.Signal;
const svg_assets = @import("../../svg_assets.zig");
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const overlay_stack = @import("../../overlay_stack.zig");
const render_engine = @import("../../core/render_engine/mod.zig");

/// Modal props (Signal-first, docs/SIGNAL_API_DESIGN.md)
pub const ModalProps = struct {
    /// Open/close state. `*Signal(bool)` controlled (interaction writes directly) (typical usage);
    /// `bool` self-held by component (via `ModalResult.open` access signal to drive);
    /// `ui.split(read, cx.on(...))` lets parent intercept close (X/Esc/mask-click only propose,
    /// parent refuse keeps open).
    open: Model(bool) = .{ .local = false },
    /// Title; empty string and static doesn't build titlebar (no close button either).
    title: Source([]const u8) = .{ .value = "" },
    /// Width
    width: f32 = 480,
    /// Max height
    max_height: f32 = 600,
    /// Mask color (null = use theme overlay)
    overlay_color: ?Color = null,
    /// Dialog background
    background: ?Color = null,
    /// Click mask to close
    close_on_overlay: bool = true,
    /// Close button SVG asset (optional, null fallback text X)
    close_icon_asset: ?svg_assets.Asset = null,
    /// Opening and closing motion. Set to .none for a fixed presentation.
    enter_transition: overlay_stack.Transition = .scale_fade,
    exit_transition: overlay_stack.Transition = .scale_fade,
    /// Play the enter transition when `open` is already true as the modal mounts. Default false:
    /// one mounted open (a page restored with its dialog up) is the open result, not an opening, so
    /// it appears at once. Set true when the caller mounts it in response to the opening itself.
    animate_initial_open: bool = false,
    /// User-initiated toggle (X/Esc/mask-click) fires after settling, param is settled toggle
    /// state.
    on_open_change: ?Handler(bool) = null,
};

// ── Style layer in styles.yss ──
const styles = @import("_styles.yss.zig");
const views = @import("_modal.yix.zig");

/// Create Modal: `W.Modal(.{ .title = "Settings", .open = settings_open })`
pub fn Modal(props: anytype) ModalBuilder {
    return .{ .props = reactive.props.coerce(ModalProps, props) };
}

/// ModalBuilder.mount result. `open` is parsed toggle signal (local/bound non-null when present).
pub const ModalResult = struct {
    overlay: *Node,
    dialog: *Node,
    body: *Node,
    portaled: bool,
    open: ?*Signal(bool),

    /// `ui.view` intake: when portal overlay already hung at window root, nothing in parent.
    pub fn viewParts(self: ModalResult) core.ViewParts {
        return .{ .root = if (self.portaled) null else self.overlay, .slot = self.body };
    }
};

/// Modal runtime state (scope owns)
const ModalRuntime = struct {
    open: reactive.Bound(bool),
    on_open_change: ?Handler(bool),

    /// X/Esc/mask-click: only propose close, data-source settle then open effect drives exit
    fn requestClose(context: *anyopaque) void {
        const self: *ModalRuntime = @ptrCast(@alignCast(context));
        self.open.propose(false, self.on_open_change);
    }
};

pub const ModalBuilder = struct {
    props: ModalProps,

    /// Retained mode: mount
    /// portaled=true overlay already auto-hung to cx.popover_portal_root (covers whole window),
    /// caller don't appendChild(overlay) again; false (no portal, like unit tests) caller still
    /// needs append.
    pub fn mount(self: ModalBuilder, scope: *Scope, cx: *Cx) !ModalResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Parse Model first then allocate rt: rt given to scope before can't have fail calls
        // between
        // (else leak)
        const open = try reactive.resolveModel(bool, my_scope, p.open);
        const rt = try my_scope.allocator.create(ModalRuntime);
        rt.* = .{ .open = open, .on_open_change = p.on_open_change };
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*ModalRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);
        const has_title = !(p.title.isStatic() and p.title.peek().len == 0);

        // Create modal layer via OverlayStack
        const ol = try overlay_stack.overlay(my_scope, cx, .{
            .kind = .modal,
            .barrier = .{ .color = p.overlay_color orelse t.tokens.color.overlay },
            .dismiss = .{
                .outside_click = if (p.close_on_overlay) .close else .none,
                .escape = true,
            },
            .enter_transition = p.enter_transition,
            .exit_transition = p.exit_transition,
            .focus = .{ .trap = true, .auto_focus = true, .restore = true },
            .on_dismiss_request = core.Cx.simpleHandler(ModalRuntime.requestClose, rt),
        });

        // barrier node as overlay (container holding dialog)
        const barrier = ol.barrier.?;
        // overlay() sets focus_scope on ol.content, but this component doesn't use ol.content;
        // the node that actually does pushScope is barrier, so unless configured on barrier,
        // trap/auto_focus are all no-ops.
        barrier.setFocusScope(.{ .trap = true, .auto_focus = true });
        barrier.meta.ownership.meta.component_name = "Modal";
        try core.bindScopeToNode(my_scope, barrier);
        scope_bound = true;
        errdefer {
            if (barrier.parent) |parent| cx.detachChild(parent, barrier);
            cx.freeNode(barrier);
        }

        // Dialog panel (view in modal.yix; titlebar present/absent static structure at mount-time)
        const panel = try views.ModalPanel(.{
            .title = p.title.peek(),
            .has_title = has_title,
            .width = p.width,
            .max_height = p.max_height,
            .background = p.background,
            .close_icon_asset = p.close_icon_asset,
            .on_close = core.Cx.simpleHandler(ModalRuntime.requestClose, rt),
        }).viewMount(my_scope, cx);
        const dialog = panel.root.?;
        barrier.appendChild(allocator, dialog) catch |err| {
            cx.freeNode(dialog);
            return err;
        };
        const body = panel.slot.?;
        // Post-title change and dialog a11y name: name points to titlebar text node self-copy
        // (titlebar first child of panel, title first child of titlebar)
        if (has_title) {
            const title_node = dialog.children.items[0].children.items[0];
            if (dialog.behavior.interaction.a11y) |*a| a.label = title_node.getText().?.content;
            try bind_mod.bindTextLabel(cx, my_scope, p.title, title_node, dialog);
        }

        // Bind OverlayStack layer's real content_node to dialog,
        // let tick() in-out animation (fade) apply on dialog.
        cx.overlay_stack.bindContentNode(allocator, ol.handle, dialog);
        if (rt.open.read.peek() and !p.animate_initial_open) cx.overlay_stack.skipInitialEnter(ol.handle);

        // open controls show/hide (via Effect drive OverlayStack)
        {
            const open_src = rt.open.read;
            const fm = &cx.focus_manager;
            const scope_pushed = try my_scope.createSignal(bool, false);
            // Open unload direct (Show cut away/parent scope dispose) won't run visible effect pop
            // branch
            // -> focus scope stack leaks entry pointing to freed barrier.
            const scope_guard = try my_scope.allocator.create(FocusScopeGuard);
            scope_guard.* = .{ .fm = fm, .pushed = scope_pushed, .barrier = barrier, .barrier_id = barrier.id };
            try my_scope.adoptResource(@ptrCast(scope_guard), FocusScopeGuard.destroy);
            try my_scope.onCleanup(FocusScopeGuard, scope_guard, FocusScopeGuard.cleanup);

            // Initial hide: barrier shrink 0 + layer suspend (direct set suspended, don't run
            // commitExit).
            // Must also whole-tree remove from hit-test: overflow_hidden only clips visual not hit,
            // dialog content overflowing 0x0 barrier leaves unvisible hot-zone at window top-left,
            // eats hover/click of controls below.
            if (!open_src.peek()) {
                barrier.style.width = .{ .px = 0 };
                barrier.style.height = .{ .px = 0 };
                barrier.style.overflow_hidden = true;
                barrier.setHitTestVisible(false);
                if (cx.overlay_stack.findLayer(ol.handle)) |layer| {
                    layer.suspended = true;
                }
            }

            reactive.checkBorrow(my_scope, open_src);
            try my_scope.createEffect(.{
                .barrier = barrier,
                .visible = open_src,
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

        return .{ .overlay = barrier, .dialog = dialog, .body = body, .portaled = ol.portaled, .open = rt.open.asSignal() };
    }
};

/// Unload pop this component's still-pushed focus scope. Only pop if stack-top truly self
/// (popScope only top; nested wrong-pop eats upper float layer scope).
/// Only compare id/pointer, don't dereference barrier (cleanup may be mid-release).
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

// ========== Tests ==========

test "Modal: basic structure" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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

    // overlay(barrier) contains dialog
    try std.testing.expectEqual(@as(usize, 1), result.overlay.children.items.len);
    // dialog contains header + body
    try std.testing.expectEqual(@as(usize, 2), result.dialog.children.items.len);
    // absolutely positioned
    try std.testing.expectEqual(core.Position.absolute, result.overlay.style.position);
}

test "Modal: visible signal control" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try scope.createSignal(bool, false);

    const result = try Modal(.{
        .title = "Toggle Modal",
        .open = vis,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    // initially hidden
    try std.testing.expectEqual(core.Sizing{ .px = 0 }, result.overlay.style.width);

    // shown
    vis.set(true);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.width);

    // hidden
    vis.set(false);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.width);

    var exiting_found = false;
    for (ctx.overlay_stack.layers.items) |slot| {
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try scope.createSignal(bool, true);

    const sub = try scope.childScope();
    const result = try Modal(.{ .title = "Unmount open", .open = vis }).mount(sub, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    const fm = &ctx.focus_manager;
    try std.testing.expectEqual(@as(u8, 1), fm.scope_count);

    sub.dispose();
    try std.testing.expectEqual(@as(u8, 0), fm.scope_count);
    try std.testing.expect(fm.activeScope() == null);
}

test "Modal: 打开时 focus trap 生效并自动聚焦到对话框内" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    ctx.setViewport(800, 600);
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try scope.createSignal(bool, false);

    const outside = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    outside.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, outside);

    const result = try Modal(.{ .title = "Trap", .open = vis }).mount(scope, ctx);
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try scope.createSignal(bool, true);

    const result = try Modal(.{
        .title = "Exit Modal",
        .open = vis,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    vis.set(false);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.width);
    try std.testing.expectEqual(core.Sizing{ .grow = .{} }, result.overlay.style.height);

    var exiting_found = false;
    for (ctx.overlay_stack.layers.items) |slot| {
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 600);

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try scope.createSignal(bool, false);

    const result = try Modal(.{
        .title = "Animated Modal",
        .width = 400,
        .open = vis,
    }).mount(scope, ctx);
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

fn firstOpenFrame(animate_initial_open: bool) !struct { opacity: f32, scale: f32 } {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 600);
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try Modal(.{ .title = "Mounted open", .width = 400, .open = true, .animate_initial_open = animate_initial_open }).mount(scope, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    render_engine.current_frame_time_ms += 16.0;
    render_engine.current_frame_dt_ms = 16.0;
    ctx.layout();
    _ = ctx.render();
    return .{ .opacity = result.dialog.getOpacity(), .scale = result.dialog.style.scale_x() };
}

test "Modal: mounted open shows at once; animate_initial_open plays the enter transition" {
    const instant = try firstOpenFrame(false);
    try std.testing.expectEqual(@as(f32, 1), instant.opacity);
    try std.testing.expectEqual(@as(f32, 1), instant.scale);
    const animated = try firstOpenFrame(true);
    try std.testing.expect(animated.opacity < 0.5);
    try std.testing.expect(animated.scale < 1);
}

test "Modal: mounted open skips only the first enter; a close then reopen animates" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 600);
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try scope.createSignal(bool, true);
    const result = try Modal(.{ .title = "Reopened", .width = 400, .open = vis }).mount(scope, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    const frame = struct {
        fn run(c: *Cx) void {
            render_engine.current_frame_time_ms += 16.0;
            render_engine.current_frame_dt_ms = 16.0;
            c.layout();
            _ = c.overlay_stack.tick(render_engine.current_frame_time_ms, 0.016, 800, 600, std.testing.allocator);
        }
    }.run;
    frame(ctx);
    try std.testing.expectEqual(@as(f32, 1), result.dialog.getOpacity());

    vis.set(false);
    for (0..30) |_| frame(ctx);
    try std.testing.expect(result.dialog.getOpacity() < 0.01);

    vis.set(true);
    frame(ctx);
    try std.testing.expect(result.dialog.getOpacity() < 0.5);
    try std.testing.expect(result.dialog.style.scale_x() < 1);
    for (0..30) |_| frame(ctx);
    try std.testing.expectEqual(@as(f32, 1), result.dialog.getOpacity());
    try std.testing.expectEqual(@as(f32, 1), result.dialog.style.scale_x());
}

test "Modal: long title wraps instead of overflowing dialog" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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

    // titlebox width constrained in dialog (old behavior: fit content width -> horizontal overflow
    // dialog)
    try std.testing.expect(title_rect.w <= dialog_rect.w);
    // after wrap height exceeds single line (14px*1.4 ~19.6; old behavior fixed 20px clipped second
    // line)
    try std.testing.expect(title_rect.h > 30);
}

test "Modal: no title" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Modal(.{}).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.overlay);

    // no title: dialog only body
    try std.testing.expectEqual(@as(usize, 1), result.dialog.children.items.len);
}

test "Modal: dialog exposes role=dialog and a label that follows a dynamic title" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const title = try scope.createText("Delete file?", .{});
    const result = try Modal(.{ .title = title, .open = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.overlay);
    const a11y = &result.dialog.behavior.interaction.a11y;
    try std.testing.expectEqual(core.A11yRole.dialog, a11y.*.?.role);
    try std.testing.expectEqualStrings("Delete file?", a11y.*.?.label.?);
    title.set("Delete 3 files?");
    // label must point to node currently-held text, not replaced old buffer
    const title_node = result.dialog.children.items[0].children.items[0];
    try std.testing.expectEqual(title_node.getText().?.content.ptr, a11y.*.?.label.?.ptr);
    try std.testing.expectEqualStrings("Delete 3 files?", a11y.*.?.label.?);
}

// styles.yss test collection, this line required, see docs/STYLING.md
test {
    _ = @import("_styles.yss.zig");
}

test "Modal: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("modal", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Modal(.{ .title = "Test Modal", .width = 400 }).mount(scope, cx);
            return r.overlay;
        }
    }.m);
}

test "Modal: split open — ✕ and Esc are proposals the parent can reject" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const open = try scope.createSignal(bool, true);
    const Gate = struct {
        open: *Signal(bool),
        allow: bool = false,
        asked: u32 = 0,
        fn propose(self: *@This(), v: bool) void {
            self.asked += 1;
            if (self.allow) self.open.set(v);
        }
    };
    var gate = Gate{ .open = open };
    const result = try Modal(.{ .title = "Unsaved changes", .open = reactive.split(open, ctx.on(Gate, &gate, Gate.propose)) }).mount(scope, ctx);
    if (!result.portaled) try root.appendChild(std.testing.allocator, result.overlay);
    try std.testing.expect(result.open == null); // split: toggle owned by parent

    const close_btn = result.dialog.children.items[0].children.items[1];
    close_btn.behavior.events.on_click.?.invoke(); // X: rejected
    ctx.handleKeyDown(.escape, .{}); // Esc: rejected
    try std.testing.expectEqual(@as(u32, 2), gate.asked);
    try std.testing.expect(open.peek());
    try std.testing.expect(result.overlay.style.width != .px); // still open
    try std.testing.expect(!ctx.overlay_stack.anyExiting()); // layer also no self-exit

    gate.allow = true;
    ctx.handleKeyDown(.escape, .{});
    try std.testing.expect(!open.peek());
    try std.testing.expect(ctx.overlay_stack.anyExiting()); // settle then open effect drive exit
}

test "Modal: composition Escape reaches Input and Textarea before overlay dismissal" {
    const input_mod = @import("../input/mod.zig");
    inline for (.{ false, true }) |multiline| {
        const ctx = try Cx.init(std.testing.allocator, std.testing.io);
        defer ctx.deinit();
        ctx.root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
        ctx.setViewport(800, 600);
        const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
        defer scope.dispose();
        const visible = try scope.createSignal(bool, false);
        const modal = try Modal(.{ .open = visible, .enter_transition = .none, .exit_transition = .none }).mount(scope, ctx);
        if (!modal.portaled) try ctx.root.?.appendChild(std.testing.allocator, modal.overlay);
        const field = if (multiline) blk: {
            const mounted = try input_mod.Textarea(.{ .value = "draft" }).mountResult(scope, ctx);
            try modal.body.appendChild(std.testing.allocator, mounted.wrapper);
            break :blk mounted.input;
        } else blk: {
            const mounted = try input_mod.Input(.{ .value = "draft" }).mountResult(scope, ctx);
            try modal.body.appendChild(std.testing.allocator, mounted.node);
            break :blk mounted.input_container;
        };
        visible.set(true);
        ctx.layout();
        ctx.setFocus(field);
        try std.testing.expect(ctx.isFocused(field));
        ctx.handleImePreedit("候", 3);
        const client = field.behavior.interaction.text_input_client.?;
        try std.testing.expect(client.is_composing.?(client.context));
        ctx.handleKeyDown(.escape, .{});
        try std.testing.expect(visible.peek());
        try std.testing.expect(!client.is_composing.?(client.context));
        try std.testing.expect(ctx.isFocused(field));
        ctx.handleKeyDown(.escape, .{});
        try std.testing.expect(!visible.peek());
    }
}
