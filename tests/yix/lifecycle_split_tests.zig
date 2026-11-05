//! Initial setup/view ownership regressions. These do not certify root replacement.
const std = @import("std");
const t = std.testing;
const ui = @import("ui");
const graph_assertions = @import("graph_assertions.zig");
const fixture = @import("_lifecycle_split.yix.zig");

fn reset() void {
    fixture.log_len = 0;
    fixture.last_ref = null;
    fixture.last_instance = null;
}

test "LP3 setup/view: generated template resources belong to the view" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const root = try fixture.Split(.{}).mount(parent, cx);
    const setup = parent.children.items[0];
    const view = setup.children.items[0];
    const signal: *ui.Signal(i32) = @ptrCast(@alignCast(setup.signals.items[0]));
    try t.expectEqual(@as(i32, 7), signal.peek());
    try t.expectEqual(@as(usize, 1), setup.signals.items.len);
    try t.expectEqual(@as(usize, 0), setup.effects.items.len);
    try t.expect(view.effects.items.len > 0);
    try t.expect(view.resources.items.len > 0);
    try t.expectEqualSlices(i32, &.{ 1, 10 }, fixture.log[0..fixture.log_len]);
    const handle = fixture.last_ref.?;
    try t.expectEqual(root, handle.get().?);
    const click = root.behavior.events.on_click.?;
    click.callback(click.context);
    try t.expectEqual(@as(i32, 8), signal.peek());
    try t.expectEqualStrings("count 8; doubled 16", root.children.items[0].getText().?.content);
    const generation = handle.generation;
    // View-only teardown leaves the declaration signal and Ref container alive.
    // No input is sent to the detached view after its event contexts are freed.
    view.dispose();
    try t.expectEqual(@as(i32, 8), signal.peek());
    try t.expectEqual(generation, handle.generation);
    try t.expect(handle.get() == null);
    try t.expectEqualSlices(i32, &.{ 1, 10, -1 }, fixture.log[0..fixture.log_len]);
    cx.freeNode(root); // Node-first final teardown disposes setup exactly once.
    try t.expectEqual(@as(usize, 0), parent.children.items.len);
    try t.expectEqualSlices(i32, &.{ 1, 10, -1, -10 }, fixture.log[0..fixture.log_len]);
}

test "LP3 setup/view: nested single-root promotion supports both teardown orders" {
    for ([_]bool{ false, true }) |scope_first| {
        reset();
        const cx = try ui.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const parent = try ui.Scope.init(t.allocator, null, cx.owner);
        const root = try fixture.Nested(.{}).mount(parent, cx);
        if (scope_first) {
            parent.dispose();
            cx.freeNode(root);
        } else {
            cx.freeNode(root);
            try t.expectEqual(@as(usize, 0), parent.children.items.len);
            parent.dispose();
        }
        try t.expectEqualSlices(i32, &.{ 1, 10, -1, -10 }, fixture.log[0..fixture.log_len]);
    }
}

test "LP3 setup/view: separate owners close and recreate independently" {
    reset();
    const a = try ui.Cx.init(t.allocator, t.io);
    const b = try ui.Cx.init(t.allocator, t.io);
    defer b.deinit();
    const sa = try ui.Scope.init(t.allocator, null, a.owner);
    const sb = try ui.Scope.init(t.allocator, null, b.owner);
    defer sb.dispose();
    const ra = try fixture.Split(.{}).mount(sa, a);
    const rb = try fixture.Split(.{}).mount(sb, b);
    defer b.freeNode(rb);
    a.freeNode(ra);
    sa.dispose();
    a.deinit();
    const click = rb.behavior.events.on_click.?;
    click.callback(click.context);
    try t.expectEqualStrings("count 8; doubled 16", rb.children.items[0].getText().?.content);
    const c = try ui.Cx.init(t.allocator, t.io);
    defer c.deinit();
    const sc = try ui.Scope.init(t.allocator, null, c.owner);
    defer sc.dispose();
    const rc = try fixture.Split(.{}).mount(sc, c);
    defer c.freeNode(rc);
    try t.expectEqualStrings("count 7; doubled 14", rc.children.items[0].getText().?.content);
}

test "LP3 setup/view: event-triggered reactive callback can destroy the instance twice" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const root = try fixture.Split(.{}).mount(parent, cx);
    const setup = parent.children.items[0];
    const count: *ui.Signal(i32) = @ptrCast(@alignCast(setup.signals.items[0]));
    const observer_scope = try parent.childScope();
    var calls: usize = 0;
    try observer_scope.createEffect(.{ .count = count, .cx = cx, .root = root, .calls = &calls }, struct {
        fn run(c: anytype) void {
            if (c.count.get() < 8) return;
            c.calls.* += 1;
            // Reentered destruction is idempotent while the callback owns a
            // deferred free. Reading count remains legal until it unwinds.
            c.cx.freeNode(c.root);
            c.cx.freeNode(c.root);
            std.debug.assert(c.count.peek() == 8);
        }
    }.run);
    const click = root.behavior.events.on_click.?;
    click.callback(click.context);
    try t.expectEqual(@as(usize, 1), calls);
    try t.expectEqual(@as(usize, 1), parent.children.items.len);
    try t.expectEqual(observer_scope, parent.children.items[0]);
    try t.expectEqualSlices(i32, &.{ 1, 10, -1, -10 }, fixture.log[0..fixture.log_len]);
}

test "LP3 setup/view: failed renderer rolls back emitted nodes and view resources" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const setup = try ui.Scope.init(t.allocator, null, cx.owner);
    defer setup.dispose();
    const count = try setup.createSignal(i32, 7);
    const render = struct {
        fn run(c: anytype, scope: *ui.Scope, context: *ui.Cx, sink: ui.view.Sink) anyerror!*ui.Node {
            const memo = try scope.createMemo(i32, c, struct {
                fn compute(s: anytype) i32 {
                    return s.get() * 2;
                }
            }.compute);
            try ui.view.emit(scope, context, sink, ui.view.text(.{}, ui.view.fmt("{d}", .{memo})));
            return error.DeliberateRenderFailure;
        }
    }.run;
    try t.expectError(error.DeliberateRenderFailure, ui.view.renderComponentView(setup, cx, count, render));
    try t.expectEqual(@as(usize, 0), setup.children.items.len);
    count.set(8); // No view observers remain to touch the failed tree.
    try t.expectEqual(@as(i32, 8), count.peek());
}

test "LP3 setup/view: retained and hidden subtree keeps setup state and hooks" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const visible = try parent.createSignal(bool, true);
    const root = try ui.view.render(parent, cx, ui.view.box(.{ .visible = visible }, .{fixture.Split(.{})}));
    const child = root.children.items[0];
    const click = child.behavior.events.on_click.?;
    click.callback(click.context);
    visible.set(false);
    try t.expectEqual(child, root.children.items[0]);
    try t.expectEqualSlices(i32, &.{ 1, 10 }, fixture.log[0..fixture.log_len]);
    cx.detachChildRetained(root, child);
    visible.set(true);
    try root.appendChild(t.allocator, child);
    const rebound_click = child.behavior.events.on_click.?;
    rebound_click.callback(rebound_click.context);
    try t.expectEqualStrings("count 9; doubled 18", child.children.items[0].getText().?.content);
    cx.freeNode(root);
    try t.expectEqualSlices(i32, &.{ 1, 10, -1, -10 }, fixture.log[0..fixture.log_len]);
}

test "LP3 setup/view: portal cleanup releases view and instance once" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    const win = try ui.box(cx, .{}, .{});
    cx.root = win;
    defer {
        cx.root = null;
        cx.popover_portal_root = null;
        cx.freeNode(win);
    }
    const root = try ui.view.render(parent, cx, ui.view.box(.{}, .{ui.view.portal(fixture.Split(.{}))}));
    const portal = try cx.ensurePopoverPortalRoot();
    try t.expectEqual(@as(usize, 1), portal.children.items.len);
    const child = portal.children.items[0];
    const click = child.behavior.events.on_click.?;
    click.callback(click.context);
    try t.expectEqualStrings("count 8; doubled 16", child.children.items[0].getText().?.content);
    parent.dispose();
    try t.expectEqual(@as(usize, 0), portal.children.items.len);
    cx.freeNode(root);
    try t.expectEqualSlices(i32, &.{ 1, 10, -1, -10 }, fixture.log[0..fixture.log_len]);
}

fn sendClick(root: *ui.Node) void {
    const h = root.behavior.events.on_click.?;
    h.callback(h.context);
}

test "LP3 setup/view: repeatable render preserves setup identity and live refs without growth" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const outer = try ui.view.render(parent, cx, ui.view.row(.{}, .{ fixture.Split(.{}), ui.view.text(.{}, "after") }));
    defer cx.freeNode(outer);
    const instance = ui.view.componentInstance(outer.children.items[0]).?;
    const count: *ui.Signal(i32) = @ptrCast(@alignCast(instance.setup.signals.items[0]));
    const handle = fixture.last_ref.?;
    const nodes = cx.world.elements.count();
    const graph = cx.owner.graph.nodeCount();
    const resources = instance.setup.resources.items.len;
    sendClick(instance.parts.root.?);
    for (0..6) |i| {
        const old_id = instance.parts.root.?.id;
        const generation = handle.generation;
        const result = try instance.rebuild();
        try t.expectEqual(instance, ui.view.componentInstance(result.root.?).?);
        try t.expect(old_id != result.root.?.id);
        try t.expectEqual(result.root.?, outer.children.items[0]);
        try t.expectEqualStrings("after", outer.children.items[1].getText().?.content);
        try t.expectEqual(count, @as(*ui.Signal(i32), @ptrCast(@alignCast(instance.setup.signals.items[0]))));
        try t.expectEqual(@as(i32, 8), count.peek());
        try t.expectEqual(handle, fixture.last_ref.?);
        try t.expectEqual(result.root.?, handle.get().?);
        try t.expectEqual(generation + 1, handle.generation);
        try t.expectEqualStrings("count 8; doubled 16", result.root.?.children.items[0].getText().?.content);
        try t.expectEqual(nodes, cx.world.elements.count());
        try t.expectEqual(graph, cx.owner.graph.nodeCount());
        try t.expectEqual(resources, instance.setup.resources.items.len);
        try t.expectEqual(@as(usize, 4 + i * 2), fixture.log_len);
        try t.expectEqual(@as(i32, -1), fixture.log[fixture.log_len - 2]);
        try t.expectEqual(@as(i32, 1), fixture.log[fixture.log_len - 1]);
    }
    sendClick(instance.parts.root.?);
    try t.expectEqual(@as(i32, 9), count.peek());
}

test "LP3 setup/view: external attrs effects events and root refs replay on the new root" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const visible = try parent.createSignal(bool, true);
    const enabled = try parent.createSignal(bool, true);
    const label = try parent.createSignal([]const u8, "first");
    const ref = try ui.view.createRef(parent, *ui.Node);
    var calls: usize = 0;
    const key = try ui.on.bindAny(parent, &calls, struct {
        fn run(n: *usize, event: ui.view.KeyPress) void {
            n.* += 1;
            event.consume();
        }
    }.run);
    const root = try ui.view.render(parent, cx, ui.view.attrs(.{
        .test_id = "external",
        .visible = visible,
        .a11y = .{ .label = label },
        .on_key_down = key,
        .style = ui.view.when(enabled, .{ .gap = 23 }),
    }, ui.view.ref(ref, fixture.Split(.{}))));
    const instance = ui.view.componentInstance(root).?;
    defer if (instance.parts.root) |r| cx.freeNode(r);
    cx.root = root;
    defer cx.root = null;
    const scopes = parent.children.items[0].children.items.len;
    const graph = cx.owner.graph.nodeCount();
    for (0..3) |_| {
        const new = (try instance.rebuild()).root.?;
        try t.expectEqual(new, cx.root.?);
        try t.expectEqual(new, ref.get().?);
        try t.expectEqualStrings("external", new.meta.ownership.meta.test_id.?);
        try t.expectEqual(@as(f32, 23), new.style.gap);
        label.set("next");
        try t.expectEqualStrings("next", new.behavior.interaction.a11y.?.label.?);
        cx.setViewport(300, 200);
        cx.layout();
        _ = cx.render();
        _ = cx.dispatcher.dispatchKeyDown(new, .{ .key = .@"return", .modifiers = .{} });
        visible.set(false);
        try t.expect(new.style.display == .none);
        visible.set(true);
        enabled.set(false);
        try t.expectEqual(@as(f32, 0), new.style.gap);
        enabled.set(true);
        try t.expectEqual(@as(f32, 23), new.style.gap);
        try t.expectEqual(graph, cx.owner.graph.nodeCount());
        try t.expectEqual(scopes, parent.children.items[0].children.items.len);
    }
    try t.expectEqual(@as(usize, 3), calls);
}

test "LP3 setup/view: slots parts and typed result refs follow rebuilt insertion points" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const text = try parent.createSignal([]const u8, "slot 1");
    const ref = try ui.view.createRef(parent, ui.view.ViewParts);
    const outer = try ui.view.render(parent, cx, ui.view.box(.{}, .{
        ui.view.with(fixture.Holder(.{}), .{ui.view.text(.{}, text)}).slots(.{ .header = ui.view.text(.{}, "header") }).parts(.{ .slot = "body" }).ref(ref),
    }));
    defer cx.freeNode(outer);
    const instance = ui.view.componentInstance(outer.children.items[0]).?;
    const graph = cx.owner.graph.nodeCount();
    const nodes = cx.world.elements.count();
    const scopes = parent.children.items[0].children.items.len;
    for (0..4) |_| {
        const parts = try instance.rebuild();
        try t.expectEqual(parts.root.?, ref.get().?.root.?);
        try t.expectEqual(parts.slot.?, ref.get().?.slot.?);
        try t.expectEqualStrings("body", parts.slot.?.meta.ownership.meta.test_id.?);
        try t.expectEqualStrings("slot 1", parts.slot.?.children.items[0].getText().?.content);
        text.set("slot 2");
        try t.expectEqualStrings("slot 2", parts.slot.?.children.items[0].getText().?.content);
        text.set("slot 1");
        try t.expectEqualStrings("header", parts.named[0].?.at.parent.children.items[0].getText().?.content);
        try t.expectEqual(graph, cx.owner.graph.nodeCount());
        try t.expectEqual(nodes, cx.world.elements.count());
        try t.expectEqual(scopes, parent.children.items[0].children.items.len);
    }
}

test "LP3 setup/view: promoted root rebuilds through its outer instance" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const live = try ui.view.createRef(parent, *ui.Node);
    const root = try ui.view.render(parent, cx, ui.view.attrs(.{ .test_id = "promoted", .style = ui.css(.{ .gap = 17 }) }, ui.view.ref(live, fixture.Nested(.{}))));
    const outer = ui.view.componentInstance(root).?;
    defer if (outer.parts.root) |r| cx.freeNode(r);
    const inner = fixture.last_instance.?;
    try t.expect(inner != outer);
    const signal: *ui.Signal(i32) = @ptrCast(@alignCast(inner.setup.signals.items[0]));
    signal.set(23);
    for (0..4) |_| {
        const refreshed = try inner.rebuild();
        try t.expectEqual(refreshed.root, outer.parts.root);
        try t.expectEqual(refreshed.root, live.get());
        try t.expectEqual(@as(f32, 17), refreshed.root.?.style.gap);
        try t.expectEqualStrings("promoted", refreshed.root.?.meta.ownership.meta.test_id.?);
        try t.expectEqual(outer, ui.view.componentInstance(refreshed.root.?).?);
        try t.expectEqual(signal, @as(*ui.Signal(i32), @ptrCast(@alignCast(inner.setup.signals.items[0]))));
        try t.expectEqual(@as(i32, 23), signal.peek());
        try t.expectEqualStrings("count 23; doubled 46", refreshed.root.?.children.items[0].getText().?.content);
    }
    const parts = try outer.rebuild();
    try t.expectEqual(outer, ui.view.componentInstance(parts.root.?).?);
    sendClick(parts.root.?);
    try t.expectEqualStrings("count 8; doubled 16", parts.root.?.children.items[0].getText().?.content);
}

const Probe = struct {
    mode: enum { normal, mount_destroy, attach_destroy, attach_dispose, detach_destroy, detach_reenter, fail } = .normal,
    setup: ?*ui.Scope = null,
    instance: ?*ui.view.ComponentInstance = null,
    value: ?*ui.Signal(i32) = null,
    root: ?*ui.Node = null,
    mounts: usize = 0,
    attaches: usize = 0,
    detaches: usize = 0,
    reentry: ?anyerror = null,

    fn component(self: *Probe, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        self.setup = scope;
        self.value = try scope.createSignal(i32, 17);
        const node = try ui.view.renderComponentView(scope, cx, self, render);
        self.mounts += 1;
        self.instance = ui.view.componentInstance(node);
        if (self.mode == .mount_destroy) {
            cx.freeNode(node);
            cx.freeNode(node);
            std.debug.assert(self.value.?.peek() == 17);
        }
        return node;
    }

    fn render(self: *Probe, scope: *ui.Scope, cx: *ui.Cx, sink: ui.view.Sink) anyerror!*ui.Node {
        try scope.onCleanup(Probe, self, detach);
        try ui.view.emit(scope, cx, sink, ui.view.box(.{ .on_click = try ui.on.bind(scope, self, reenter) }, .{
            ui.view.text(.{}, ui.view.fmt("value {d}", .{self.value.?})),
        }));
        const node = sink.root.?.*.?;
        self.root = node;
        self.attaches += 1;
        if (self.mode == .attach_destroy) {
            cx.freeNode(node);
            cx.freeNode(node);
        } else if (self.mode == .attach_dispose) self.setup.?.dispose();
        if (self.mode == .fail) return error.DeliberateRenderFailure;
        return node;
    }

    fn reenter(self: *Probe) void {
        _ = self.instance.?.rebuild() catch |err| {
            self.reentry = err;
            return;
        };
    }

    fn detach(self: *Probe) void {
        self.detaches += 1;
        if (self.mode == .detach_destroy) {
            self.setup.?.dispose();
            std.debug.assert(self.value.?.peek() == 17);
        } else if (self.mode == .detach_reenter) reenter(self);
    }
};

test "LP3 setup/view: initialization callbacks can destroy or dispose without returning a dead root" {
    for ([_]Probe{ .{ .mode = .mount_destroy }, .{ .mode = .attach_destroy }, .{ .mode = .attach_dispose } }) |initial| {
        var probe = initial;
        const cx = try ui.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const parent = try ui.Scope.init(t.allocator, null, cx.owner);
        defer parent.dispose();
        try t.expectError(error.ViewMountCancelled, ui.view.component(Probe.component, &probe).mount(parent, cx));
        try t.expectEqual(@as(usize, 0), cx.world.elements.count());
        try graph_assertions.expectOnlySignals(cx, parent, null);
        try t.expectEqual(@as(usize, 0), parent.children.items.len);
        try t.expectEqual(@as(usize, 1), probe.detaches);
    }
}

test "LP3 setup/view: callback rebuild is refused and detach reentry cannot start another render" {
    var probe: Probe = .{};
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const root = try ui.view.component(Probe.component, &probe).mount(parent, cx);
    const instance = probe.instance.?;
    defer if (instance.parts.root) |r| cx.freeNode(r);
    // Exercise the host's callback lifetime boundary; raw HandlerRef calls do
    // not by themselves constitute event dispatch or a native-input test.
    cx.owner.beginReactiveCallback();
    sendClick(root);
    cx.owner.endReactiveCallback();
    try t.expectEqual(error.ViewRebuildNeedsSafePoint, probe.reentry.?);
    try t.expectEqual(root, instance.parts.root.?);
    // Isolate graph flush from computation/callback depth: this is a separate
    // scheduler unsafe window, including post-effect flush bookkeeping.
    cx.owner.graph.flushing = true;
    const flushing_result = instance.rebuild();
    cx.owner.graph.flushing = false;
    try t.expectError(error.ViewRebuildNeedsSafePoint, flushing_result);
    try t.expectEqual(root, instance.parts.root.?);
    try t.expectEqual(@as(usize, 0), probe.detaches);
    probe.mode = .detach_reenter;
    _ = try instance.rebuild();
    try t.expectEqual(error.ViewRebuildUnavailable, probe.reentry.?);
    try t.expectEqual(@as(usize, 1), probe.mounts);
    try t.expectEqual(@as(usize, 2), probe.attaches);
    try t.expectEqual(@as(usize, 1), probe.detaches);
    probe.mode = .normal;
}

test "LP3 setup/view: detach destruction cancels rebuilding before using released setup" {
    var probe: Probe = .{};
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    _ = try ui.view.component(Probe.component, &probe).mount(parent, cx);
    probe.mode = .detach_destroy;
    try t.expectError(error.ViewMountCancelled, probe.instance.?.rebuild());
    // The instance was destroyed at the guarded return boundary; do not read it.
    try t.expectEqual(@as(usize, 0), parent.children.items.len);
    try t.expectEqual(@as(usize, 0), cx.world.elements.count());
    try graph_assertions.expectOnlySignals(cx, parent, null);
    try t.expectEqual(@as(usize, 1), probe.attaches);
}

test "LP3 setup/view: failed rebuild clears the host root and requires explicit remount" {
    var probe: Probe = .{};
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const ref = try ui.view.createRef(parent, *ui.Node);
    const root = try ui.view.render(parent, cx, ui.view.ref(ref, ui.view.component(Probe.component, &probe)));
    const instance = probe.instance.?;
    cx.root = root;
    defer cx.root = null;
    probe.value.?.set(29);
    probe.mode = .fail;
    try t.expectError(error.DeliberateRenderFailure, instance.rebuild());
    try t.expectEqual(.needs_remount, instance.state);
    try t.expect(instance.parts.root == null and instance.binding.node == null and instance.view_scope == null);
    try t.expect(cx.root == null and ref.get() == null);
    try t.expectEqual(@as(i32, 29), probe.value.?.peek());
    try t.expectEqual(@as(usize, 0), cx.world.elements.count());
    try graph_assertions.expectOnlySignals(cx, parent, instance.setup);
    try t.expectError(error.ViewRebuildUnavailable, instance.rebuild());
}

test "LP3 setup/view: one shot node slot fails preflight without consuming the old view" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const slot = try ui.view.render(parent, cx, ui.view.text(.{}, "one shot"));
    const root = try ui.view.render(parent, cx, ui.view.with(fixture.Holder(.{}), .{slot}).slots(.{ .header = ui.view.text(.{}, "header") }));
    defer cx.freeNode(root);
    const instance = ui.view.componentInstance(root).?;
    try t.expectError(error.ViewNonReplayableAttachment, instance.rebuild());
    try t.expectEqual(.ready, instance.state);
    try t.expectEqual(root, instance.parts.root.?);
    try t.expectEqualStrings("one shot", instance.parts.slot.?.children.items[0].getText().?.content);
}

test "LP3 setup/view: rebuilt parent retires nested external scopes before their records" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const root = try fixture.Decorated(.{}).mount(parent, cx);
    const instance = ui.view.componentInstance(root).?;
    defer if (instance.parts.root) |r| cx.freeNode(r);
    const graph = cx.owner.graph.nodeCount();
    const nodes = cx.world.elements.count();
    for (0..3) |_| {
        const result = try instance.rebuild();
        try t.expectEqualStrings("nested attrs", result.root.?.children.items[0].meta.ownership.meta.test_id.?);
        try t.expectEqual(nodes, cx.world.elements.count());
        try t.expectEqual(graph, cx.owner.graph.nodeCount());
    }
}

test "LP3 setup/view: every rebuild allocation failure leaves no partial view or live ref" {
    var failures: usize = 0;
    for (0..300) |index| {
        reset();
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const cx = try ui.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        cx.allocator = failing.allocator();
        defer cx.allocator = t.allocator;
        const parent = try ui.Scope.init(failing.allocator(), null, cx.owner);
        defer parent.dispose();
        const ref = try ui.view.createRef(parent, *ui.Node);
        const enabled = try parent.createSignal(bool, true);
        const root = try ui.view.render(parent, cx, ui.view.attrs(.{ .style = ui.view.when(enabled, .{ .gap = 13 }) }, ui.view.ref(ref, fixture.Split(.{}))));
        const instance = ui.view.componentInstance(root).?;
        defer if (instance.parts.root) |r| cx.freeNode(r);
        const count: *ui.Signal(i32) = @ptrCast(@alignCast(instance.setup.signals.items[0]));
        count.set(41);
        failing.fail_index = failing.alloc_index + index;
        const result = instance.rebuild();
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (result) |parts| {
            try t.expect(!induced);
            try t.expectEqual(parts.root.?, ref.get().?);
            try t.expectEqual(@as(i32, 41), count.peek());
            try t.expect(failures > 20);
            return;
        } else |err| {
            failures += 1;
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(.needs_remount, instance.state);
            try t.expect(instance.parts.root == null and ref.get() == null and instance.view_scope == null);
            try t.expectEqual(@as(usize, 0), cx.world.elements.count());
            try t.expectEqual(@as(i32, 41), count.peek());
            count.set(42); // No failed-tree observer remains.
        }
    }
    return error.RebuildAllocationSweepDidNotFinish;
}

test "LP3 setup/view: portal ownership follows rebuilt roots and both final teardown orders" {
    for ([_]bool{ false, true }) |node_first| {
        reset();
        const cx = try ui.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const parent = try ui.Scope.init(t.allocator, null, cx.owner);
        const win = try ui.view.render(parent, cx, ui.view.box(.{}, .{}));
        cx.root = win;
        defer {
            cx.root = null;
            cx.popover_portal_root = null;
            cx.freeNode(win);
        }
        try ui.view.mount(parent, cx, win, .{ui.view.portal(fixture.Split(.{}))});
        const portal = try cx.ensurePopoverPortalRoot();
        const instance = ui.view.componentInstance(portal.children.items[0]).?;
        sendClick(instance.parts.root.?);
        const graph = cx.owner.graph.nodeCount();
        const nodes = cx.world.elements.count();
        for (0..3) |_| {
            const next = (try instance.rebuild()).root.?;
            try t.expectEqual(next, portal.children.items[0]);
            try t.expectEqualStrings("count 8; doubled 16", next.children.items[0].getText().?.content);
            try t.expectEqual(graph, cx.owner.graph.nodeCount());
            try t.expectEqual(nodes, cx.world.elements.count());
        }
        if (node_first) {
            const last = instance.parts.root.?;
            cx.detachChild(portal, last);
            cx.freeNode(last);
        }
        parent.dispose();
        try t.expectEqual(@as(usize, 0), portal.children.items.len);
        try graph_assertions.expectOnlySignals(cx, null, null);
    }
}

test "LP3 setup/view: retained detached rebuild preserves state and replays themed external style" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const style = struct {
        fn panel(tkn: *const ui.theme.Values) ui.BoxStyle {
            return .{ .background = tkn.tokens.color.bg_secondary };
        }
    }.panel;
    const outer = try ui.view.render(parent, cx, ui.view.box(.{}, .{ui.view.attrs(.{ .style = style }, fixture.Split(.{}))}));
    cx.root = outer;
    defer {
        cx.root = null;
        cx.freeNode(outer);
    }
    const root = outer.children.items[0];
    const instance = ui.view.componentInstance(root).?;
    sendClick(root);
    cx.detachChildRetained(outer, root);
    cx.setTheme(&ui.theme.modes.dark);
    const new = (try instance.rebuild()).root.?;
    errdefer if (new.parent == null) cx.freeNode(new);
    try t.expect(new.parent == null);
    try t.expectEqualStrings("count 8; doubled 16", new.children.items[0].getText().?.content);
    try t.expectEqual(ui.theme.modes.dark.tokens.color.bg_secondary, new.getBackground());
    try outer.appendChild(t.allocator, new);
    cx.setTheme(&ui.theme.modes.light);
    try t.expectEqual(ui.theme.modes.light.tokens.color.bg_secondary, new.getBackground());
    sendClick(new);
    try t.expectEqualStrings("count 9; doubled 18", new.children.items[0].getText().?.content);
}

test "LP3 setup/view: active and suspended overlay roots are refused before any teardown" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const root = try fixture.Split(.{}).mount(parent, cx);
    defer cx.freeNode(root);
    const instance = ui.view.componentInstance(root).?;
    const layer = try cx.overlay_stack.push(.{ .kind = .modal });
    defer cx.overlay_stack.removePermanently(layer);
    // Use the real layer's content binding and suspension flag. No native input
    // or compositor evidence is inferred from this software-owner regression.
    cx.overlay_stack.bindContentNode(t.allocator, layer, root);
    for ([_]bool{ false, true }) |suspended| {
        for (cx.overlay_stack.layers.items) |*maybe| if (maybe.*) |*entry| {
            if (entry.handle.id == layer.id) entry.suspended = suspended;
        };
        try t.expectError(error.ViewOverlayRootNeedsOwnerRebuild, instance.rebuild());
        try t.expectEqual(root, instance.parts.root.?);
        try t.expectEqual(.ready, instance.state);
        try t.expectEqualSlices(i32, &.{ 1, 10 }, fixture.log[0..fixture.log_len]);
    }
}

test "LP3 setup/view: external setup decorators replay and initial destruction cancels render" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const Decorator = struct {
        fn stamp(calls: *usize, node: *ui.Node) void {
            calls.* += 1;
            node.meta.ownership.meta.test_id = "replayed setup";
        }
        fn destroy(_: void, node: *ui.Node, _: *ui.Scope, context: *ui.Cx) void {
            context.freeNode(node);
        }
    };
    var calls: usize = 0;
    const root = try ui.view.render(parent, cx, ui.view.setup(fixture.Split(.{}), &calls, Decorator.stamp));
    const instance = ui.view.componentInstance(root).?;
    _ = try instance.rebuild();
    try t.expectEqual(@as(usize, 2), calls);
    try t.expectEqualStrings("replayed setup", instance.parts.root.?.meta.ownership.meta.test_id.?);
    cx.freeNode(instance.parts.root.?);
    reset();
    try t.expectError(error.ViewMountCancelled, ui.view.render(parent, cx, ui.view.setup(fixture.Split(.{}), {}, Decorator.destroy)));
    try t.expectEqual(@as(usize, 0), cx.world.elements.count());
    try graph_assertions.expectOnlySignals(cx, parent, null);
}

test "LP3 setup/view: captures nested inside caller slots are one shot and never replayed" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    var captured: ?*ui.Node = null;
    const root = try ui.view.render(parent, cx, ui.view.with(fixture.Holder(.{}), .{ui.view.capture(&captured, ui.view.text(.{}, "captured once"))}).slots(.{ .header = ui.view.text(.{}, "header") }));
    defer cx.freeNode(root);
    const instance = ui.view.componentInstance(root).?;
    try t.expectEqual(captured.?, instance.parts.slot.?.children.items[0]);
    try t.expectError(error.ViewNonReplayableAttachment, instance.rebuild());
    try t.expectEqual(root, instance.parts.root.?);
    try t.expectEqualStrings("captured once", captured.?.getText().?.content);
}

test "LP3 setup/view: slot children allocation failures retire scopes before stray nodes" {
    var failures: usize = 0;
    for (0..300) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const cx = try ui.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        cx.allocator = failing.allocator();
        defer cx.allocator = t.allocator;
        const parent = try ui.Scope.init(failing.allocator(), null, cx.owner);
        defer parent.dispose();
        const root = try ui.view.render(parent, cx, ui.view.with(fixture.Holder(.{}), .{fixture.SlotChild(.{})}).slots(.{ .header = ui.view.text(.{}, "header") }));
        const instance = ui.view.componentInstance(root).?;
        defer if (instance.parts.root) |r| cx.freeNode(r);
        failing.fail_index = failing.alloc_index + index;
        const result = instance.rebuild();
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (result) |vp| {
            try t.expect(!induced);
            try t.expect(vp.slot.?.children.items[0].behavior.events.on_event != null);
            try t.expect(failures > 20);
            return;
        } else |err| {
            failures += 1;
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(.needs_remount, instance.state);
            try t.expect(instance.parts.root == null and instance.view_scope == null);
            try t.expectEqual(@as(usize, 0), cx.world.elements.count());
            try graph_assertions.expectOnlySignals(cx, parent, instance.setup);
        }
    }
    return error.SlotAllocationSweepDidNotFinish;
}

fn cacheInitializationCampaign(comptime create: anytype, comptime materialize: anytype) !void {
    // Cx services live in the Cx-owned service scope. A failed first creation
    // must not leave an unpublished signal behind for the retry to duplicate.
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    // Materialize the service scope through a different service first.
    _ = try materialize(cx);
    const service = cx.service_scope.?;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    service.allocator = failing.allocator();
    defer service.allocator = t.allocator;
    const before = service.signals.items.len;
    const graph_before = cx.owner.graph.nodeCount();
    for (0..3) |_| {
        failing.fail_index = failing.alloc_index;
        const result = create(cx);
        failing.fail_index = std.math.maxInt(usize);
        try t.expectError(error.OutOfMemory, result);
        try t.expectEqual(before, service.signals.items.len);
        try t.expectEqual(graph_before, cx.owner.graph.nodeCount());
    }
    const first = try create(cx);
    try t.expectEqual(before + 1, service.signals.items.len);
    try t.expectEqual(first, try create(cx));
}

test "LP3 setup/view: window cache OOM retries keep root inventory unchanged" {
    try cacheInitializationCampaign(ui.Cx.themeSignal, ui.Cx.a11yPreferencesSignal);
    try cacheInitializationCampaign(ui.Cx.a11yPreferencesSignal, ui.Cx.themeSignal);
    if (comptime @FieldType(ui.Cx, "style_signal") != void)
        try cacheInitializationCampaign(ui.Cx.styleGenerationSignal, ui.Cx.themeSignal);
}

test "LP3 setup/view: deferred old node cleanup cannot return an orphan replacement" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    var parent_alive = true;
    try parent.onCleanup(bool, &parent_alive, struct {
        fn mark(flag: *bool) void {
            flag.* = false;
        }
    }.mark);
    defer if (parent_alive) parent.dispose();
    const root = try fixture.Split(.{}).mount(parent, cx);
    const instance = ui.view.componentInstance(root).?;
    cx.root = root;
    defer cx.root = null;
    root.meta.ownership.hooks.on_cleanup = ui.Cx.simpleHandler(struct {
        fn close(ptr: *anyopaque) void {
            const scope: *ui.Scope = @ptrCast(@alignCast(ptr));
            scope.dispose();
        }
    }.close, @ptrCast(parent));
    const result = instance.rebuild();
    // Keep this regression leak-free even against the broken implementation,
    // which returned a live Node after freeing all of its setup/view resources.
    if (result) |parts| {
        cx.root = null;
        if (parts.root) |orphan| cx.freeNode(orphan);
        return error.RebuildReturnedOrphan;
    } else |err| try t.expectEqual(error.ViewMountCancelled, err);
    try t.expect(!parent_alive);
    try t.expect(cx.root == null);
    try t.expectEqual(@as(usize, 0), cx.world.elements.count());
    try graph_assertions.expectOnlySignals(cx, null, null);
}

test "LP3 setup/view: lifetime ticket OOM leaves the old view intact" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const root = try fixture.Split(.{}).mount(parent, cx);
    const instance = ui.view.componentInstance(root).?;
    defer if (instance.parts.root) |r| cx.freeNode(r);
    var cleaned = false;
    while (instance.setup.cleanups.items.len < instance.setup.cleanups.capacity) {
        try instance.setup.onCleanup(bool, &cleaned, struct {
            fn mark(flag: *bool) void {
                flag.* = true;
            }
        }.mark);
    }
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    instance.setup.allocator = failing.allocator();
    const result = instance.rebuild();
    instance.setup.allocator = t.allocator;
    try t.expectError(error.OutOfMemory, result);
    try t.expectEqual(.ready, instance.state);
    try t.expectEqual(root, instance.parts.root.?);
    try t.expect(!cleaned);
    try t.expectEqualSlices(i32, &.{ 1, 10 }, fixture.log[0..fixture.log_len]);
    sendClick(root);
    const next = (try instance.rebuild()).root.?;
    try t.expectEqualStrings("count 8; doubled 16", next.children.items[0].getText().?.content);
}

test "LP3 setup/view: node cleanup reentry is refused until all queues settle" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const ra = try fixture.Split(.{}).mount(parent, cx);
    const rb = try fixture.Split(.{}).mount(parent, cx);
    const a = ui.view.componentInstance(ra).?;
    const b = ui.view.componentInstance(rb).?;
    defer if (a.parts.root) |r| cx.freeNode(r);
    defer if (b.parts.root) |r| cx.freeNode(r);
    const Cleanup = struct {
        current: *ui.view.ComponentInstance,
        other: *ui.view.ComponentInstance,
        current_error: ?anyerror = null,
        other_error: ?anyerror = null,
        fn capture(instance: *ui.view.ComponentInstance) ?anyerror {
            _ = instance.rebuild() catch |err| return err;
            return null;
        }
        fn run(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.current_error = capture(self.current);
            self.other_error = capture(self.other);
        }
    };
    var cleanup = Cleanup{ .current = a, .other = b };
    ra.meta.ownership.hooks.on_cleanup = ui.Cx.simpleHandler(Cleanup.run, &cleanup);
    const cleanups = a.setup.cleanups.items.len;
    _ = try a.rebuild();
    try t.expectEqual(error.ViewRebuildUnavailable, cleanup.current_error.?);
    try t.expectEqual(error.ViewRebuildNeedsSafePoint, cleanup.other_error.?);
    try t.expectEqual(cleanups, a.setup.cleanups.items.len);
    try t.expectEqual(rb, b.parts.root.?);
    try t.expectEqual(.ready, a.state);
    try t.expectEqual(.ready, b.state);
}

test "LP3 setup/view: For leases follow rebuilt rows through reorder and removal" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const root = try ui.view.render(parent, cx, ui.view.box(.{}, .{}));
    cx.root = root;
    const data = try parent.createSignal([]const u32, &.{ 1, 2 });
    try ui.For(u32, parent, root, data, cx, .{
        .key_fn = struct {
            fn key(n: u32) u64 {
                return n;
            }
        }.key,
        .render_fn = struct {
            fn row(s: *ui.Scope, c: *ui.Cx, _: u32, _: usize) anyerror!*ui.Node {
                return fixture.Nested(.{}).mount(s, c);
            }
        }.row,
    });
    const surviving_inner = fixture.last_instance.?;
    const first = root.children.items[1];
    const outer = ui.view.componentInstance(first).?;
    const inner = outer;
    // Both row root replacement and replacement of a promoted descendant must
    // update the same host alias; the row array itself moves during reconcile.
    const replacement = (try inner.rebuild()).root.?;
    try t.expectEqual(replacement, root.children.items[1]);
    data.set(&.{ 2, 1 });
    try t.expectEqual(replacement, root.children.items[2]);
    _ = try ui.view.componentInstance(replacement).?.rebuild();
    data.set(&.{2});
    try t.expectEqual(@as(usize, 3), root.children.items.len); // anchors + surviving row
    const survivor = root.children.items[1];
    const survivor_id = survivor.id;
    _ = try surviving_inner.rebuild();
    try t.expect(root.children.items[1].id != survivor_id);
    data.set(&.{});
    try t.expectEqual(@as(usize, 2), root.children.items.len);
}

test "LP3 setup/view: native callback root bindings refuse migration before teardown" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const host = try ui.view.render(parent, cx, ui.view.box(.{}, .{}));
    cx.root = host;
    try ui.view.renderInto(parent, cx, host, struct {
        fn child(s: *ui.Scope, c: *ui.Cx) anyerror!*ui.Node {
            return fixture.Split(.{}).mount(s, c);
        }
    }.child, {}, .{}, "LP3 callback");
    const instance = fixture.last_instance.?;
    const root = instance.parts.root.?;
    try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, instance.rebuild());
    try t.expectEqual(root, host.children.items[0]);
    sendClick(root);
    try t.expectEqualStrings("count 8; doubled 16", root.children.items[0].getText().?.content);
}

test "LP3 setup/view: root lease is cleared on consumed failure and outlives setup teardown" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    var probe = Probe{};
    const root = try ui.view.component(Probe.component, &probe).mount(parent, cx);
    const lease = (try ui.view.RootLease.acquire(t.allocator, root)).?;
    defer lease.release();
    probe.mode = .fail;
    try t.expectError(error.DeliberateRenderFailure, probe.instance.?.rebuild());
    try t.expect(lease.node == null);
    probe.setup.?.dispose();
    try t.expect(lease.instance == null);
}

test "LP3 setup/view: native captured parts and imperative root snapshots reject inner refresh" {
    reset();
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    var captured: *ui.Node = undefined;
    const root = try ui.view.render(parent, cx, ui.view.capture(&captured, fixture.Nested(.{})));
    defer cx.freeNode(root);
    try t.expectEqual(root, captured);
    try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, fixture.last_instance.?.rebuild());
    try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, ui.view.componentInstance(root).?.rebuild());
    sendClick(captured);
    try t.expectEqualStrings("count 8; doubled 16", captured.children.items[0].getText().?.content);
}

test "LP3 setup/view: promoted root OOM clears all owner roots and leases" {
    for (0..250) |offset| {
        reset();
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const cx = try ui.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        cx.allocator = failing.allocator();
        defer cx.allocator = t.allocator;
        const parent = try ui.Scope.init(failing.allocator(), null, cx.owner);
        defer parent.dispose();
        const live = try ui.view.createRef(parent, *ui.Node);
        const root = try ui.view.render(parent, cx, ui.view.ref(live, fixture.Nested(.{})));
        const outer = ui.view.componentInstance(root).?;
        defer if (outer.parts.root) |node| cx.freeNode(node);
        const inner = fixture.last_instance.?;
        const lease = (try ui.view.RootLease.acquire(t.allocator, root)).?;
        defer lease.release();
        failing.fail_index = failing.alloc_index + offset;
        const result = inner.rebuild();
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (result) |parts| {
            try t.expect(!induced);
            try t.expectEqual(parts.root, outer.parts.root);
            try t.expectEqual(parts.root, live.get());
            try t.expectEqual(parts.root, lease.node);
            return;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            // Preflight allocation failure preserves the original generation;
            // consumed failure invalidates every external owner together.
            if (inner.state == .ready) {
                try t.expectEqual(root, outer.parts.root.?);
                try t.expectEqual(root, live.get().?);
                try t.expectEqual(root, lease.node.?);
            } else {
                try t.expectEqual(.needs_remount, outer.state);
                try t.expect(outer.parts.root == null and inner.parts.root == null);
                try t.expect(live.get() == null and lease.node == null);
                try t.expectEqual(@as(usize, 0), cx.world.elements.count());
            }
        }
    }
    return error.PromotionSweepDidNotFinish;
}
test "LP3 setup/view: promoted slotted native parts refuse inner migration" {
    const Host = struct {
        var scope_only = false;
        fn mount(_: struct {}, scope: *ui.Scope, c: *ui.Cx) anyerror!ui.view.ViewParts {
            return ui.view.renderComponentView(scope, c, {}, render);
        }
        fn render(_: void, scope: *ui.Scope, c: *ui.Cx, sink: ui.view.Sink) anyerror!ui.view.ViewParts {
            try ui.view.emit(scope, c, sink, fixture.Split(.{}));
            const root = sink.root.?.*.?;
            return .{
                .root = root,
                .slot = if (scope_only) null else root.children.items[0],
                .slot_scope = if (scope_only) fixture.last_instance.?.view_scope else null,
            };
        }
    };
    for ([_]bool{ false, true }) |scope_only| {
        reset();
        Host.scope_only = scope_only;
        const cx = try ui.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const parent = try ui.Scope.init(t.allocator, null, cx.owner);
        defer parent.dispose();
        const parts = try ui.view.slotted(Host.mount, .{}).viewMount(parent, cx);
        const outer = ui.view.componentInstance(parts.root.?).?;
        defer if (outer.parts.root) |root| cx.freeNode(root);
        const inner = fixture.last_instance.?;
        try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, inner.rebuild());
        try t.expectEqual(parts.root, inner.parts.root);
        sendClick(parts.root.?);
        try t.expectEqualStrings("count 8; doubled 16", parts.root.?.children.items[0].getText().?.content);
    }
}

test "LP3 setup/view: native file upload caption and group pin retained button roots" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    const upload = try ui.widgets.FileUpload(.{}).mount(parent, cx);
    defer cx.freeNode(upload.wrapper);
    try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, ui.view.componentInstance(upload.browse_button).?.rebuild());
    const caption = try ui.widgets.WindowControls(.{}).mount(parent, cx);
    defer cx.freeNode(caption);
    try t.expectEqual(@as(usize, 3), caption.children.items.len);
    for (caption.children.items) |button| {
        const instance = ui.view.componentInstance(button) orelse return error.MissingCaptionInstance;
        try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, instance.rebuild());
    }
    const group = try ui.widgets.Group(.{}).mount(parent, cx);
    defer cx.freeNode(group.container);
    const button = try ui.widgets.Button(.{ .label = "attached" }).mount(parent, cx);
    try ui.widgets.addGroupItem(group.container, t.allocator, button, .only, 8);
    try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, ui.view.componentInstance(button).?.rebuild());
}

test "LP3 setup/view: For remounts a failed refreshed row before keyed reuse" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    cx.root = try ui.view.render(parent, cx, ui.view.box(.{}, .{}));
    var probe = Probe{};
    const Row = struct {
        var context: ?*Probe = null;
        fn key(n: u32) u64 {
            return n;
        }
        fn render(scope: *ui.Scope, c: *ui.Cx, _: u32, _: usize) anyerror!*ui.Node {
            return ui.view.component(Probe.component, context.?).mount(scope, c);
        }
    };
    Row.context = &probe;
    defer Row.context = null;
    const data = try parent.createSignal([]const u32, &.{1});
    try ui.For(u32, parent, cx.root.?, data, cx, .{ .key_fn = Row.key, .render_fn = Row.render });
    probe.mode = .fail;
    try t.expectError(error.DeliberateRenderFailure, probe.instance.?.rebuild());
    try t.expectEqual(@as(usize, 2), cx.root.?.children.items.len);
    probe.mode = .normal;
    data.set(&.{ 1, 2 });
    try t.expectEqual(@as(usize, 4), cx.root.?.children.items.len);
    data.set(&.{});
    try t.expectEqual(@as(usize, 2), cx.root.?.children.items.len);
}

test "LP3 setup/view: For cannot reuse a root freed by deferred rebuild cancellation" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    cx.root = try ui.view.render(parent, cx, ui.view.box(.{}, .{}));
    var probe = Probe{};
    const Row = struct {
        var context: ?*Probe = null;
        fn key(n: u32) u64 {
            return n;
        }
        fn render(scope: *ui.Scope, c: *ui.Cx, _: u32, _: usize) anyerror!*ui.Node {
            return ui.view.component(Probe.component, context.?).mount(scope, c);
        }
    };
    Row.context = &probe;
    defer Row.context = null;
    const data = try parent.createSignal([]const u32, &.{1});
    try ui.For(u32, parent, cx.root.?, data, cx, .{ .key_fn = Row.key, .render_fn = Row.render });
    const old = probe.root.?;
    old.meta.ownership.hooks.on_cleanup = ui.Cx.simpleHandler(struct {
        fn close(raw: *anyopaque) void {
            const setup: *ui.Scope = @ptrCast(@alignCast(raw));
            setup.dispose();
        }
    }.close, @ptrCast(probe.setup.?));
    try t.expectError(error.ViewMountCancelled, probe.instance.?.rebuild());
    data.set(&.{ 1, 2 });
    try t.expectEqual(@as(usize, 4), cx.root.?.children.items.len);
    data.set(&.{});
    try t.expectEqual(@as(usize, 2), cx.root.?.children.items.len);
}

test "LP3 setup/view: For reclaims scope-first retained roots before remounting" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    cx.root = try ui.view.render(parent, cx, ui.view.box(.{}, .{}));
    var probe = Probe{};
    const Row = struct {
        var context: ?*Probe = null;
        fn key(n: u32) u64 {
            return n;
        }
        fn render(scope: *ui.Scope, c: *ui.Cx, _: u32, _: usize) anyerror!*ui.Node {
            return ui.view.component(Probe.component, context.?).mount(scope, c);
        }
    };
    Row.context = &probe;
    defer Row.context = null;
    const data = try parent.createSignal([]const u32, &.{1});
    try ui.For(u32, parent, cx.root.?, data, cx, .{ .key_fn = Row.key, .render_fn = Row.render });
    const old_id = probe.root.?.id;
    const lease = probe.instance.?.leases.?;
    probe.setup.?.dispose();
    try t.expect(lease.resolve() == null);
    try t.expect(lease.retainedNode() != null);
    data.set(&.{ 1, 2 });
    try t.expectEqual(@as(usize, 4), cx.root.?.children.items.len);
    try t.expect(cx.root.?.children.items[1].id != old_id);
    data.set(&.{});
    try t.expectEqual(@as(usize, 2), cx.root.?.children.items.len);
}

test "LP3 setup/view: legacy untracked For roots mount but refuse migration" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try ui.Scope.init(t.allocator, null, cx.owner);
    defer parent.dispose();
    cx.root = try ui.view.render(parent, cx, ui.view.box(.{}, .{}));
    const Row = struct {
        var instance: ?*ui.view.ComponentInstance = null;
        fn key(n: u32) u64 {
            return n;
        }
        fn render(scope: *ui.Scope, c: *ui.Cx, _: u32, _: usize) anyerror!*ui.Node {
            return ui.view.component(component, {}).mount(scope, c);
        }
        fn component(scope: *ui.Scope, c: *ui.Cx) anyerror!*ui.Node {
            const root = try ui.view.renderComponentView(scope, c, {}, build);
            instance = ui.view.componentInstance(root);
            return root;
        }
        fn build(_: void, _: *ui.Scope, c: *ui.Cx, sink: ui.view.Sink) anyerror!*ui.Node {
            // Legacy host with no World registration. Match Node.create's
            // storage initialization without its process-wide creation hook.
            const node = try c.allocator.create(ui.Node);
            node.* = .{ .id = c.nextId(), .tag = .box, .style = .{}, .children = .empty };
            try sink.insert(c, node);
            return node;
        }
    };
    const data = try parent.createSignal([]const u32, &.{1});
    try ui.For(u32, parent, cx.root.?, data, cx, .{ .key_fn = Row.key, .render_fn = Row.render });
    try t.expectEqual(std.math.maxInt(u32), Row.instance.?.parts.root.?.element_id_raw);
    try t.expectError(error.ViewHostRootAliasNeedsOwnerRebuild, Row.instance.?.rebuild());
    try t.expectEqual(@as(usize, 3), cx.root.?.children.items.len);
    data.set(&.{});
    try t.expectEqual(@as(usize, 2), cx.root.?.children.items.len);
}

test "LP3 setup/view: service accounting rejects captured business signals" {
    if (comptime @FieldType(ui.Cx, "style_signal") == void) return;
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const business = try scope.createSignal(i32, 1);
    const generation = try cx.styleGenerationSignal();
    try scope.createEffect(.{ .generation = generation, .business = business }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.generation.get();
            _ = ctx.business.get();
        }
    }.run);
    try t.expectError(error.UnexpectedStyleDependency, graph_assertions.staticCounts(cx));
}
