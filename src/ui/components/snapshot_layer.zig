const std = @import("std");
const core = @import("../core.zig");
const animation = @import("../animation/mod.zig");
const render_engine = @import("../core/render_engine/mod.zig");
const overlay_stack = core.overlay_stack_mod;

const Allocator = std.mem.Allocator;
const Cx = core.Cx;
const Node = core.Node;
const Point = core.Point;
const Color = core.Color;
const Scope = core.Scope;
const Snapshot = core.Snapshot;
const DrawContext = render_engine.DrawContext;
const AnimationController = animation.AnimationController;
const Task = core.Task;
const WorkResult = core.WorkResult;
const box = core.box;

fn snapshotLayerDebugEnabled() bool {
    return std.posix.getenv("ZENIT_SNAPSHOT_DEBUG") != null;
}

pub const BackdropConfig = struct {
    color: Color,
    release_alpha: f32 = 1.0,
};

pub const SnapshotLayerProps = struct {
    snapshot: *Snapshot,
    anchor: Point,
    initial_opacity: f32 = 1.0,
    initial_scale: f32 = 1.0,
    backdrop: ?BackdropConfig = null,
    z_index: ?i16 = null,
};

pub const SnapshotLayerResult = struct {
    node: *Node,
    state: *SnapshotLayerState,

    pub fn animateOpacity(
        self: *SnapshotLayerResult,
        from: f32,
        to: f32,
        duration_s: f32,
        on_complete: ?*const fn (?*anyopaque) void,
        on_complete_ctx: ?*anyopaque,
    ) void {
        self.state.startOpacityAnimation(from, to, duration_s, on_complete, on_complete_ctx);
    }

    pub fn snapshot(self: *const SnapshotLayerResult) *Snapshot {
        return self.state.snapshot orelse unreachable;
    }

    pub fn opacity(self: *const SnapshotLayerResult) f32 {
        return self.state.opacity;
    }

    pub fn scale(self: *const SnapshotLayerResult) f32 {
        return self.state.scale;
    }

    pub fn dismiss(self: *SnapshotLayerResult) void {
        self.state.dismiss();
    }

    pub fn animateOpacityAndDismiss(
        self: *SnapshotLayerResult,
        from: f32,
        to: f32,
        duration_s: f32,
    ) void {
        self.state.startOpacityAnimation(from, to, duration_s, dismissOnComplete, @ptrCast(self.state));
    }
};

pub fn SnapshotLayer(props: SnapshotLayerProps) SnapshotLayerBuilder {
    return .{ .props = props };
}

pub const SnapshotLayerBuilder = struct {
    props: SnapshotLayerProps,

    pub fn mount(self: SnapshotLayerBuilder, scope: *Scope, cx: *Cx) !SnapshotLayerResult {
        const root = cx.root orelse return error.RootUnavailable;
        const my_scope = try scope.childScope();
        const overlay_handle = try cx.overlay_stack.push(.{
            .kind = .non_modal,
            .dismiss = .{
                .outside_click = .none,
                .escape = false,
                .focus_out = false,
            },
            .enter_transition = .none,
            .exit_transition = .none,
            .focus = .{
                .trap = false,
                .auto_focus = false,
                .restore = false,
            },
            .barrier = .none,
            .content_hit_test_visible = false,
            .z_index = self.props.z_index,
        });
        errdefer cx.overlay_stack.removePermanently(overlay_handle);

        const layer = try box(cx, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        // 所有权交接：registerResource 成功之前，layer / state 由这里的 errdefer 回收；
        // 成功之后二者（连同 overlay 层、snapshot）归 my_scope 的 cleanup，若仍保留
        // `errdefer destroy(state)`，后续失败会先释放 state、scope dispose 再跑 cleanup
        // 释放一次（double free / UAF）。
        var owned_here = true;
        errdefer if (owned_here) cx.freeNode(layer);
        layer.meta.ownership.meta.component_name = "SnapshotLayer";
        layer.setHitTestVisible(false);
        // bindFloatingContent 末尾 ensureExtPanic：提前可失败地分配，OOM 走 error 而不是 panic
        _ = try layer.style.ensureExtFallible(cx.allocator);

        const state = try cx.allocator.create(SnapshotLayerState);
        errdefer if (owned_here) cx.allocator.destroy(state);
        state.* = .{
            .allocator = cx.allocator,
            .cx = cx,
            .node = layer,
            .node_id = layer.id,
            .overlay_handle = overlay_handle,
            .snapshot = self.props.snapshot,
            .anchor = self.props.anchor,
            .opacity = std.math.clamp(self.props.initial_opacity, 0.0, 1.0),
            .scale = @max(self.props.initial_scale, 0.001),
            .backdrop = self.props.backdrop,
        };

        layer.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
        layer.meta.per_frame.hooks.before_render.main = snapshotLayerBeforeRender;
        layer.setCustomDraw(snapshotLayerDraw, @ptrCast(state));

        try my_scope.registerResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, allocator: Allocator) void {
                const state_ptr: *SnapshotLayerState = @ptrCast(@alignCast(ptr));
                state_ptr.cx.overlay_stack.removePermanently(state_ptr.overlay_handle);
                if (!state_ptr.dismissed) {
                    if (state_ptr.node.parent) |parent| {
                        state_ptr.cx.detachChild(parent, state_ptr.node);
                    }
                    state_ptr.cx.freeDetachedNodeAfterScopeDispose(state_ptr.node);
                }
                if (state_ptr.snapshot) |snapshot| {
                    snapshot.deinit();
                    state_ptr.snapshot = null;
                }
                allocator.destroy(state_ptr);
            }
        }.cleanup);
        owned_here = false;
        errdefer {
            // mount 失败时 snapshot 仍归调用方（与 registerResource 之前的失败一致）
            state.snapshot = null;
            my_scope.dispose();
        }
        try core.bindScopeToNode(my_scope, layer);

        try root.appendChild(cx.allocator, layer);
        cx.overlay_stack.bindFloatingContent(cx.allocator, overlay_handle, layer);

        return .{
            .node = layer,
            .state = state,
        };
    }
};

const SnapshotLayerState = struct {
    allocator: Allocator,
    cx: *Cx,
    node: *Node,
    node_id: u32,
    overlay_handle: overlay_stack.LayerHandle,
    snapshot: ?*Snapshot,
    anchor: Point,
    opacity: f32,
    scale: f32,
    backdrop: ?BackdropConfig = null,
    controller: ?AnimationController = null,
    from_opacity: f32 = 1.0,
    to_opacity: f32 = 1.0,
    from_scale: f32 = 1.0,
    to_scale: f32 = 1.0,
    dismissed: bool = false,
    auto_dismiss_requested: bool = false,
    dismiss_scheduled: bool = false,
    on_complete: ?*const fn (?*anyopaque) void = null,
    on_complete_ctx: ?*anyopaque = null,

    fn startOpacityAnimation(
        self: *SnapshotLayerState,
        from: f32,
        to: f32,
        duration_s: f32,
        on_complete: ?*const fn (?*anyopaque) void,
        on_complete_ctx: ?*anyopaque,
    ) void {
        if (self.dismissed) return;

        self.from_opacity = std.math.clamp(from, 0.0, 1.0);
        self.to_opacity = std.math.clamp(to, 0.0, 1.0);
        self.from_scale = 1.0;
        self.to_scale = 1.0;
        self.opacity = self.from_opacity;
        self.scale = 1.0;
        self.on_complete = on_complete;
        self.on_complete_ctx = on_complete_ctx;
        self.node.markRenderDirty();
        self.node.markCompositeDirty();
        self.cx.needs_redraw = true;

        if (duration_s <= 0.0001 or @abs(to - from) <= 0.001) {
            self.opacity = std.math.clamp(to, 0.0, 1.0);
            self.scale = 1.0;
            self.controller = null;
            self.node.markRenderDirty();
            self.node.markCompositeDirty();
            self.cx.needs_redraw = true;
            self.invokeOnComplete();
            return;
        }

        // controller 插值 0..1 表示 progress；实际 opacity 在 beforeRender 里
        // 由 (from_opacity, to_opacity) 线性映射：opacity = from + (to - from) * progress
        var controller = AnimationController.initTween(.{
            .from = 0.0,
            .to = 1.0,
            .duration = duration_s,
            .easing = .linear,
        });
        controller.on_complete = opacityAnimationComplete;
        controller.on_complete_ctx = @ptrCast(self);
        controller.playPendingFirstTick();
        self.controller = controller;
        self.node.markRenderDirty();
        self.node.markCompositeDirty();
        self.cx.needs_redraw = true;
    }

    fn dismiss(self: *SnapshotLayerState) void {
        if (self.dismissed) return;
        self.dismissed = true;
        self.cx.overlay_stack.removePermanently(self.overlay_handle);

        if (self.node.parent) |parent| {
            self.cx.detachChild(parent, self.node);
        }
        self.cx.freeNode(self.node);
    }

    fn requestDeferredDismiss(self: *SnapshotLayerState) void {
        if (self.dismissed) return;
        self.auto_dismiss_requested = true;
        if (self.controller == null) {
            scheduleDeferredDismiss(self);
        }
        self.cx.needs_redraw = true;
    }

    fn invokeOnComplete(self: *SnapshotLayerState) void {
        const callback = self.on_complete;
        const callback_ctx = self.on_complete_ctx;
        self.on_complete = null;
        self.on_complete_ctx = null;
        if (callback) |cb| {
            cb(callback_ctx);
        }
    }
};

fn opacityAnimationComplete(ctx: *anyopaque) void {
    const state: *SnapshotLayerState = @ptrCast(@alignCast(ctx));
    state.invokeOnComplete();
}

fn dismissOnComplete(ctx: ?*anyopaque) void {
    const state_ptr = ctx orelse return;
    const state: *SnapshotLayerState = @ptrCast(@alignCast(state_ptr));
    state.requestDeferredDismiss();
}

fn scheduleDeferredDismiss(state: *SnapshotLayerState) void {
    if (state.dismiss_scheduled or state.dismissed) return;
    state.dismiss_scheduled = true;
    state.dismissed = true;
    const wrapper = state.allocator.create(DeferredDismissTask) catch {
        state.dismissed = false;
        state.dismiss_scheduled = false;
        return;
    };
    wrapper.* = .{
        .task = .{
            .allocator = state.allocator,
            .key = .{ .int = (@as(u64, state.node_id) << 32) | 0x534c },
            .priority = .user_visible,
            .version = 1,
            .state_ptr = undefined,
            .vtable = &.{
                .runSlice = DeferredDismissTask.run,
                .deinit = DeferredDismissTask.destroy,
            },
        },
        .cx = state.cx,
        .node_id = state.node_id,
        .overlay_handle = state.overlay_handle,
    };
    _ = state.cx.enqueueTask(&wrapper.task) catch {
        wrapper.task.key.deinit(state.allocator);
        state.allocator.destroy(wrapper);
        state.dismissed = false;
        state.dismiss_scheduled = false;
        state.cx.needs_redraw = true;
        return;
    };
    state.cx.needs_redraw = true;
}

const DeferredDismissTask = struct {
    task: Task,
    cx: *Cx,
    node_id: u32,
    overlay_handle: overlay_stack.LayerHandle,

    fn run(task: *Task, _: *anyopaque, _: u32) WorkResult {
        const self: *DeferredDismissTask = @fieldParentPtr("task", task);
        self.cx.overlay_stack.removePermanently(self.overlay_handle);
        if (self.cx.node_registry.entries.get(self.node_id)) |entry| {
            const node = entry.ptr;
            if (node.parent) |parent| {
                self.cx.detachChild(parent, node);
            }
            self.cx.freeNode(node);
        }
        self.cx.needs_redraw = true;
        return .{ .step = .done, .wants_redraw = true };
    }

    fn destroy(task: *Task, allocator: Allocator) void {
        const self: *DeferredDismissTask = @fieldParentPtr("task", task);
        self.task.key.deinit(allocator);
        allocator.destroy(self);
    }
};

fn snapshotLayerBeforeRender(node: *Node) void {
    const state: *SnapshotLayerState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    if (state.dismissed) return;

    if (snapshotLayerDebugEnabled()) {
        std.debug.print("[snapshot.before] node_id={d} opacity={d:.3} scale={d:.3} animating={} auto_dismiss={} dismissed={}\n", .{
            state.node_id,
            state.opacity,
            state.scale,
            state.controller != null,
            state.auto_dismiss_requested,
            state.dismissed,
        });
    }

    if (state.controller) |controller_value| {
        var controller = controller_value;
        const on_complete = controller.on_complete;
        const on_complete_ctx = controller.on_complete_ctx;
        controller.on_complete = null;
        controller.on_complete_ctx = null;

        const still_active = controller.tick(render_engine.current_frame_time_ms);
        const t = std.math.clamp(controller.value, 0.0, 1.0);
        state.opacity = state.from_opacity + (state.to_opacity - state.from_opacity) * t;
        state.scale = state.from_scale + (state.to_scale - state.from_scale) * t;
        if (still_active) {
            controller.on_complete = on_complete;
            controller.on_complete_ctx = on_complete_ctx;
            state.controller = controller;
            node.markRenderDirty();
            node.markCompositeDirty();
            state.cx.needs_redraw = true;
        } else {
            state.controller = null;
            node.markRenderDirty();
            node.markCompositeDirty();
            state.cx.needs_redraw = true;
            if (on_complete) |cb| {
                if (on_complete_ctx) |ctx| {
                    cb(ctx);
                }
            }
            return;
        }
    }

    if (state.auto_dismiss_requested and state.controller == null) {
        scheduleDeferredDismiss(state);
    }
}

fn snapshotLayerDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const state: *SnapshotLayerState = @ptrCast(@alignCast(context orelse return));
    const snapshot = state.snapshot orelse return;
    if (state.opacity <= 0.001) return;

    if (snapshotLayerDebugEnabled()) {
        std.debug.print("[snapshot.draw] node_id={d} opacity={d:.3} scale={d:.3} anchor=({d:.1},{d:.1}) cmds={d} local=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{
            state.node_id,
            state.opacity,
            state.scale,
            state.anchor.x,
            state.anchor.y,
            snapshot.commands.commands.len,
            snapshot.local_bounds.x,
            snapshot.local_bounds.y,
            snapshot.local_bounds.w,
            snapshot.local_bounds.h,
        });
    }

    if (state.backdrop) |backdrop| {
        const backdrop_opacity = backdropOpacity(state.opacity, backdrop.release_alpha);
        if (backdrop_opacity > 0.001) {
            const backdrop_color = applyOpacity(backdrop.color, backdrop_opacity);
            // Stage B S4: DisplayItem 路径，与 progress/spinner 对齐。
            if (ctx.display_list) |dl| {
                if (ctx.display_header) |header| {
                    try dl.append(.{
                        .fill_rect = .{
                            .header = header,
                            .x = 0,
                            .y = 0,
                            .w = ctx.local_w,
                            .h = ctx.local_h,
                            .color = backdrop_color,
                        },
                    });
                }
            }
        }
    }

    try snapshot.appendTo(ctx, state.anchor, state.opacity, state.scale);
}

fn backdropOpacity(snapshot_opacity: f32, release_alpha: f32) f32 {
    const threshold = std.math.clamp(release_alpha, 0.001, 1.0);
    if (snapshot_opacity >= threshold) return 1.0;
    return std.math.clamp(snapshot_opacity / threshold, 0.0, 1.0);
}

fn applyOpacity(color: Color, opacity: f32) Color {
    const alpha = @as(f32, @floatFromInt(color.a)) * std.math.clamp(opacity, 0.0, 1.0);
    return color.withAlpha(@intFromFloat(@round(alpha)));
}

test "SnapshotLayer mounts as a pure draw overlay" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const source = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
        .background = Color.rgb(220, 40, 40),
    }, .{});
    source.style.translate_x = 12;
    source.style.translate_y = 18;
    try root.appendChild(cx.allocator, source);

    _ = cx.render();
    const snapshot = (try Snapshot.capture(cx, source)) orelse return error.ExpectedSnapshot;

    const handle = try SnapshotLayer(.{
        .snapshot = snapshot,
        .anchor = .{ .x = 96, .y = 52 },
        .z_index = 10,
    }).mount(scope, cx);

    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    // Snapshot 的 anchor/scale/opacity 不是烘进 rect 几何的，而是由包裹它的
    // begin_opacity_layer 的 **draw_transform** 承载（rect 保持 snapshot 本地
    // 坐标，encoder 用该 transform 把整层搬到 anchor）。原测试直接找
    // "几何 == anchor 的 fill_rect"，那是 pre-layer 时代的期望，永远不会命中。
    // 改为断言真正的不变量：存在一个把本地 bounds 映射到 anchor 的包裹层，
    // 且层内确实有 snapshot 的 fill_rect。
    var layer_at_anchor = false;
    for (commands) |cmd| {
        if (cmd.kind != .control) continue;
        if (@abs(cmd.draw_x - 96) < 0.01 and @abs(cmd.draw_y - 52) < 0.01 and
            @abs(cmd.draw_w - 40) < 0.01 and @abs(cmd.draw_h - 24) < 0.01)
        {
            layer_at_anchor = true;
            break;
        }
    }
    try std.testing.expect(layer_at_anchor);

    // 层内 snapshot 内容（本地坐标 40x24）确实被绘制。
    var found = false;
    for (commands) |cmd| {
        if (cmd.isFillRect() and
            @abs(cmd.geom.w - 40) < 0.01 and @abs(cmd.geom.h - 24) < 0.01 and
            @abs(cmd.geom.x - 0) < 0.01 and @abs(cmd.geom.y - 0) < 0.01)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(handle.node.meta.per_frame.custom_hooks.draw != null);
    try std.testing.expect(!handle.node.frame_state.state_bits.flags.hit_test_visible);
    try std.testing.expect(cx.overlay_stack.findLayer(handle.state.overlay_handle) != null);
}

test "SnapshotLayer opacity animation fades snapshot out" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const source = try box(cx, .{
        .width = .{ .px = 32 },
        .height = .{ .px = 20 },
        .background = Color.rgb(40, 120, 220),
    }, .{});
    try root.appendChild(cx.allocator, source);

    _ = cx.render();
    const snapshot = (try Snapshot.capture(cx, source)) orelse return error.ExpectedSnapshot;

    var completed = false;
    var handle = try SnapshotLayer(.{
        .snapshot = snapshot,
        .anchor = .{ .x = 80, .y = 40 },
    }).mount(scope, cx);

    cx.frame_time_ms = 0;
    handle.animateOpacity(1.0, 0.0, 0.2, struct {
        fn done(ctx: ?*anyopaque) void {
            const flag = ctx orelse return;
            @as(*bool, @ptrCast(@alignCast(flag))).* = true;
        }
    }.done, @ptrCast(&completed));

    cx.frame_time_ms = 16;
    _ = cx.render();
    cx.frame_time_ms = 266;
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var found_snapshot_rect = false;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            const rect = cmd;
            if (@abs(rect.geom.x - 80) < 0.01 and @abs(rect.geom.y - 40) < 0.01 and @abs(rect.geom.w - 32) < 0.01 and @abs(rect.geom.h - 20) < 0.01) {
                found_snapshot_rect = true;
                break;
            }
        }
    }

    try std.testing.expect(!found_snapshot_rect);
    try std.testing.expect(completed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), handle.state.opacity, 0.001);
}

test "SnapshotLayer completion callback may dispose scope" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const source = try box(cx, .{
        .width = .{ .px = 32 },
        .height = .{ .px = 20 },
        .background = Color.rgb(200, 80, 60),
    }, .{});
    try root.appendChild(cx.allocator, source);

    _ = cx.render();
    const snapshot = (try Snapshot.capture(cx, source)) orelse return error.ExpectedSnapshot;

    var handle = try SnapshotLayer(.{
        .snapshot = snapshot,
        .anchor = .{ .x = 80, .y = 40 },
    }).mount(scope, cx);
    const overlay_handle = handle.state.overlay_handle;

    cx.frame_time_ms = 0;
    handle.animateOpacity(1.0, 0.0, 0.2, struct {
        fn done(ctx: ?*anyopaque) void {
            const ptr = ctx orelse return;
            @as(*Scope, @ptrCast(@alignCast(ptr))).dispose();
        }
    }.done, @ptrCast(scope));

    cx.frame_time_ms = 16;
    _ = cx.render();
    cx.frame_time_ms = 266;
    _ = cx.render();

    try std.testing.expect(scope.disposed);
    try std.testing.expect(cx.overlay_stack.findLayer(overlay_handle) == null);
}

test "SnapshotLayer dismiss detaches node from root" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const source = try box(cx, .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .background = Color.rgb(120, 40, 180),
    }, .{});
    try root.appendChild(cx.allocator, source);

    _ = cx.render();
    const snapshot = (try Snapshot.capture(cx, source)) orelse return error.ExpectedSnapshot;

    var handle = try SnapshotLayer(.{
        .snapshot = snapshot,
        .anchor = .{ .x = 48, .y = 36 },
    }).mount(scope, cx);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expect(cx.overlay_stack.findLayer(handle.state.overlay_handle) != null);

    handle.dismiss();

    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expect(cx.overlay_stack.findLayer(handle.state.overlay_handle) == null);
}

test "SnapshotLayer scope dispose releases overlay layer and node" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const source = try box(cx, .{
        .width = .{ .px = 28 },
        .height = .{ .px = 18 },
        .background = Color.rgb(40, 160, 120),
    }, .{});
    try root.appendChild(cx.allocator, source);

    _ = cx.render();
    const snapshot = (try Snapshot.capture(cx, source)) orelse return error.ExpectedSnapshot;

    const handle = try SnapshotLayer(.{
        .snapshot = snapshot,
        .anchor = .{ .x = 64, .y = 48 },
    }).mount(scope, cx);
    const overlay_handle = handle.state.overlay_handle;

    try std.testing.expect(cx.overlay_stack.findLayer(overlay_handle) != null);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);

    scope.dispose();

    try std.testing.expect(cx.overlay_stack.findLayer(overlay_handle) == null);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "SnapshotLayer: mount 在任意分配点失败时不泄漏也不 double free（sweep）" {
    // oom_sweep.sweepMount 不适用：snapshot 必须先 render + capture，而 render 在 OOM
    // 下按设计 panic。这里只对 mount 本身的分配点逐个注入失败。
    const t = std.testing;
    const Run = struct {
        /// 返回 mount 自身用掉的分配次数；fail_at = null 表示不注入。
        fn once(fail_at: ?usize, induced: *usize) !usize {
            var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
            defer if (gpa.deinit() == .leak) @panic("SnapshotLayer mount OOM path leaked");
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const cx = try Cx.init(failing.allocator());
            defer cx.deinit();
            cx.setViewport(240, 160);
            const scope = try Scope.init(failing.allocator(), null, cx.owner);
            defer scope.dispose();
            cx.root = try box(cx, .{ .width = .{ .px = 240 }, .height = .{ .px = 160 } }, .{});
            const src = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 24 }, .background = Color.rgb(220, 40, 40) }, .{});
            try cx.root.?.appendChild(cx.allocator, src);
            _ = cx.render();
            const snapshot = (try Snapshot.capture(cx, src)) orelse return error.ExpectedSnapshot;

            const before = failing.alloc_index;
            if (fail_at) |k| failing.fail_index = before + k;
            const result = SnapshotLayer(.{ .snapshot = snapshot, .anchor = .{ .x = 10, .y = 10 } }).mount(scope, cx);
            failing.fail_index = std.math.maxInt(usize);
            const used = failing.alloc_index - before;
            if (result) |_| {} else |_| {
                induced.* += 1;
                snapshot.deinit(); // 失败时 snapshot 归调用方
            }
            return used;
        }
    };
    var induced: usize = 0;
    const total = try Run.once(null, &induced);
    try t.expect(total > 0);
    for (0..total) |k| _ = try Run.once(k, &induced);
    // 个别分配点失败被框架内部降级吞掉（不致 mount 失败），与 oom_sweep 同样按比例卡覆盖
    try t.expect(induced >= total / 2);
}
