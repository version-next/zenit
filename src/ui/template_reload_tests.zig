const std = @import("std");
const t = std.testing;
const core = @import("core.zig");
const v = @import("view.zig");
const reload = @import("template_reload.zig");
const fixture = @import("zenit_environment").preview.fixture4;
const source = fixture.preview_source;
const path = "examples/template_probe/view.yix";
fn mount(cx: *core.Cx, a: std.mem.Allocator) !*v.ComponentInstance {
    cx.root_scope = try core.Scope.init(a, null, cx.owner);
    cx.root = try v.render(cx.root_scope.?, cx, fixture.Probe(.{ .start = 7 }));
    const i = v.componentInstance(cx.root.?).?;
    try t.expectEqualStrings(source, i.preview_template.?.source);
    return i;
}
fn count(i: *v.ComponentInstance) *@import("reactive.zig").Signal(u32) {
    return @ptrCast(@alignCast(i.setup.signals.items[0]));
}
fn text(node: *core.Node, expected: []const u8) bool {
    if (node.getText()) |value| if (std.mem.eql(u8, value.content, expected)) return true;
    for (node.children.items) |child| if (text(child, expected)) return true;
    return false;
}
fn prepare(a: std.mem.Allocator, bytes: []const u8) !*reload.Preparation {
    return reload.prepare(a, &.{.{ .path = path, .source = bytes }});
}
fn expectReady(p: *reload.Preparation) !void {
    if (p.result == .fallback) std.debug.print("unexpected LP4 fallback: {s}\n", .{p.result.fallback.reason});
    if (p.result == .diagnostic) std.debug.print("unexpected LP4 diagnostic: {s}\n", .{p.result.diagnostic.message});
    try t.expect(p.result == .ready);
}
fn changed(a: std.mem.Allocator) ![]u8 {
    return std.mem.replaceOwned(u8, a, source, ">Original<", ">Changed<");
}

test "LP4 supported text layout literals preserve setup across A B A" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try mount(cx, t.allocator);
    const signal = count(i);
    signal.set(23);
    const a_nodes = cx.world.elements.count();
    const a_graph = cx.owner.graph.nodeCount();
    const b = try std.mem.replaceOwned(u8, t.allocator, source, "<col>", "<row testId=\"inserted\" visible={true} style={.{ .gap = 9, .padding = 5 }}><col>");
    defer t.allocator.free(b);
    const c = try std.mem.replaceOwned(u8, t.allocator, b, "</col>", "</col><text>Changed</text></row>");
    defer t.allocator.free(c);
    for (0..6) |n| {
        const p = try prepare(t.allocator, if (n % 2 == 0) c else source);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        try t.expectEqual(@as(usize, 1), try p.apply(&.{cx}));
        try t.expectEqual(@as(u64, n + 1), reload.generation);
        try t.expectEqual(i, v.componentInstance(cx.root.?).?);
        try t.expectEqual(signal, count(i));
        try t.expectEqual(@as(u32, 23), signal.peek());
        try t.expect(text(cx.root.?, "value 23"));
        if (n % 2 == 0) {
            try t.expect(text(cx.root.?, "Changed"));
            try t.expectEqual(@as(f32, 9), cx.root.?.style.gap);
            try t.expectEqual(@as(f32, 5), cx.root.?.style.padding.left);
            try t.expectEqualStrings("inserted", cx.root.?.meta.ownership.meta.test_id.?);
        } else {
            try t.expectEqual(a_nodes, cx.world.elements.count());
            try t.expectEqual(a_graph, cx.owner.graph.nodeCount());
        }
    }
}

test "LP4 classifier rejects hole changes and non-template code" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try mount(cx, t.allocator);
    const cases = [_][2][]const u8{
        .{ "count += 1", "count += 2" },
        .{ "signal(start)", "signal(start + 1)" },
        .{ "count: u32", "count: u64" },
        .{ "onClick", "onHover" },
        .{ "value {count}", "value {start}" },
        .{ "<text testId={labelId}>Original</text>", "{if (count > 0) <text>branch</text>}" },
        .{ "<text testId={labelId}>Original</text>", "<Probe/>" },
    };
    const old = cx.root;
    for (cases) |edit| {
        const bytes = try std.mem.replaceOwned(u8, t.allocator, source, edit[0], edit[1]);
        defer t.allocator.free(bytes);
        const p = try prepare(t.allocator, bytes);
        defer p.deinit();
        try t.expect(p.result == .fallback);
        try t.expectEqual(old, cx.root);
        try t.expectEqual(@as(u64, 0), reload.generation);
    }
    // Reproducible perturbation of expression tokens: no changed dynamic hole
    // may be silently accepted, even when the stream shape stays identical.
    var rng = std.Random.DefaultPrng.init(0x4c5034);
    for (0..64) |_| {
        var buf: [64]u8 = undefined;
        const expression = try std.fmt.bufPrint(&buf, "count += {d}", .{rng.random().intRangeAtMost(u16, 2, 65535)});
        const bytes = try std.mem.replaceOwned(u8, t.allocator, source, "count += 1", expression);
        defer t.allocator.free(bytes);
        const p = try prepare(t.allocator, bytes);
        defer p.deinit();
        try t.expect(p.result == .fallback);
    }
}

test "LP4 parse errors preserve exact tree state and generation" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try mount(cx, t.allocator);
    count(i).set(41);
    const old = cx.root;
    const p = try prepare(t.allocator, "pub fn Probe() View { return <col><text>bad</col>; }");
    defer p.deinit();
    try t.expect(p.result == .diagnostic);
    try t.expect(p.result.diagnostic.line > 0);
    try t.expectEqual(old, cx.root);
    try t.expectEqual(@as(u32, 41), count(i).peek());
    try t.expectEqual(@as(u64, 0), reload.generation);
}

test "LP4 whole batch rollback keeps both owners and generation unchanged" {
    defer reload.deinit();
    const cx1 = try core.Cx.init(t.allocator, t.io);
    defer cx1.deinit();
    const cx2 = try core.Cx.init(t.allocator, t.io);
    defer cx2.deinit();
    const instance_a = try mount(cx1, t.allocator);
    const instance_b = try mount(cx2, t.allocator);
    count(instance_a).set(31);
    count(instance_b).set(47);
    const old1 = cx1.root;
    const old2 = cx2.root;
    const nodes_a = cx1.world.elements.count();
    const nodes_b = cx2.world.elements.count();
    const graph_a = cx1.owner.graph.nodeCount();
    const graph_b = cx2.owner.graph.nodeCount();
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    p.fail_after = 2;
    try t.expectError(error.TemplateInjectedFailure, p.apply(&.{ cx1, cx2 }));
    try t.expectEqual(old1, cx1.root);
    try t.expectEqual(old2, cx2.root);
    try t.expectEqual(nodes_a, cx1.world.elements.count());
    try t.expectEqual(nodes_b, cx2.world.elements.count());
    try t.expectEqual(graph_a, cx1.owner.graph.nodeCount());
    try t.expectEqual(graph_b, cx2.owner.graph.nodeCount());
    try t.expectEqual(@as(u64, 0), reload.generation);
    try t.expectEqual(@as(u32, 31), count(instance_a).peek());
    try t.expectEqual(@as(u32, 47), count(instance_b).peek());
    try t.expect(text(cx1.root.?, "Original") and text(cx2.root.?, "Original"));
    p.fail_after = null;
    try t.expectEqual(@as(usize, 2), try p.apply(&.{ cx1, cx2 }));
    try t.expect(text(cx1.root.?, "Changed") and text(cx2.root.?, "Changed"));
    try t.expectEqual(@as(u32, 31), count(instance_a).peek());
    try t.expectEqual(@as(u32, 47), count(instance_b).peek());
}

test "LP4 safe point rejection and owner closure recreation" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    errdefer cx.deinit();
    _ = try mount(cx, t.allocator);
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    cx.owner.graph.flushing = true;
    try t.expectError(error.ViewRebuildNeedsSafePoint, p.apply(&.{cx}));
    cx.owner.graph.flushing = false;
    cx.owner.beginReactiveCallback();
    try t.expectError(error.ViewRebuildNeedsSafePoint, p.apply(&.{cx}));
    cx.owner.endReactiveCallback();
    try t.expectEqual(@as(usize, 1), try p.apply(&.{cx}));
    cx.deinit();
    const next = try core.Cx.init(t.allocator, t.io);
    defer next.deinit();
    const i = try mount(next, t.allocator);
    try t.expect(text(next.root.?, "Changed"));
    try t.expectEqual(@as(u32, 7), count(i).peek());
}

test "LP4 candidate allocation failures retain old tree and setup" {
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    var reached_success = false;
    for (0..1024) |offset| {
        defer reload.deinit();
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const a = failing.allocator();
        const cx = try core.Cx.init(a, t.io);
        defer cx.deinit();
        const i = try mount(cx, a);
        count(i).set(29);
        const old_view = i.parts.root;
        const parent = try v.render(cx.root_scope.?, cx, v.row(.{}, .{v.text(.{}, "after")}));
        try parent.insertChildBefore(a, cx.root.?, parent.children.items[0]);
        cx.root = parent;
        const old = cx.root;
        const nodes = cx.world.elements.count();
        const graph = cx.owner.graph.nodeCount();
        const children = i.setup.children.items.len;
        const p = try prepare(t.allocator, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        failing.fail_index = failing.alloc_index + offset;
        if (p.apply(&.{cx})) |_| {
            reached_success = true;
            try t.expectEqual(@as(u32, 29), count(i).peek());
            count(i).set(30);
            try t.expect(text(cx.root.?, "value 30"));
            try t.expectEqual(i.parts.root.?, parent.children.items[0]);
            try t.expectEqualStrings("after", parent.children.items[1].getText().?.content);
            break;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(old, cx.root);
            try t.expectEqual(old_view, i.parts.root);
            try t.expectEqual(nodes, cx.world.elements.count());
            try t.expectEqual(graph, cx.owner.graph.nodeCount());
            try t.expectEqual(children, i.setup.children.items.len);
            try t.expectEqual(@as(u64, 0), reload.generation);
            try t.expectEqual(@as(u32, 29), count(i).peek());
            try t.expect(text(cx.root.?, "Original"));
        }
    }
    try t.expect(reached_success);
}

test "LP4 static style references select compiled factories and scalar styles are bounded" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try mount(cx, t.allocator);
    const bytes = try std.mem.replaceOwned(u8, t.allocator, source, "style={S.A}", "style={S.B}");
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    try t.expectEqual(@as(usize, 1), try p.apply(&.{cx}));
    try t.expectEqual(@as(f32, 11), i.parts.root.?.children.items[3].style.gap);
    const template = @import("template.zig");
    try t.expect(template.literalStyle(". { . gap = call ( ) }") == null);
    try t.expect(template.literalStyle(". { . gap = 1 , . gap = 2 }") == null);
    try t.expect(template.literalStyle(". { . gap = nan }") == null);
}

test "LP4 full hole multiset rejects every perturbed identity field" {
    const template = @import("template.zig");
    const captures = [_]template.Capture{.{ .id = 1, .name = "count", .type_name = "Signal(u32)" }};
    const edges = [_]template.Receiver{.{ .name = "on_click", .expected_type = "HandlerRef" }};
    const original: template.Hole = .{ .module = path, .site = 9, .path = "Probe", .captures = &captures, .type_name = "Factory", .receiver = .{ .name = "box", .expected_type = "Factory" }, .edges = &edges, .tokens = "count += 1", .token_fingerprint = 7 };
    const mapping = try template.matchHoles(t.allocator, &.{original}, &.{original});
    defer t.allocator.free(mapping);
    try t.expectEqual(@as(usize, 0), mapping[0]);
    var random = std.Random.DefaultPrng.init(0x484f4c45);
    for (0..64) |_| {
        var mutated = original;
        mutated.token_fingerprint = random.random().intRangeAtMost(u64, 8, std.math.maxInt(u64));
        try t.expectError(error.TemplateHoleChanged, template.matchHoles(t.allocator, &.{original}, &.{mutated}));
    }
    inline for (.{ "site", "path", "module", "type_name", "receiver", "captures", "edges", "tokens", "token_fingerprint", "occurrence" }) |field| {
        var mutated = original;
        if (comptime std.mem.eql(u8, field, "site")) mutated.site += 1 else if (comptime std.mem.eql(u8, field, "path")) mutated.path = "Other" else if (comptime std.mem.eql(u8, field, "module")) mutated.module = "other.yix" else if (comptime std.mem.eql(u8, field, "type_name")) mutated.type_name = "Other" else if (comptime std.mem.eql(u8, field, "receiver")) mutated.receiver.expected_type = "Other" else if (comptime std.mem.eql(u8, field, "captures")) mutated.captures = &.{.{ .id = 2, .name = "count", .type_name = "Signal(u32)" }} else if (comptime std.mem.eql(u8, field, "edges")) mutated.edges = &.{.{ .name = "on_hover", .expected_type = "HandlerRef" }} else if (comptime std.mem.eql(u8, field, "tokens")) mutated.tokens = "count += 2" else if (comptime std.mem.eql(u8, field, "token_fingerprint")) mutated.token_fingerprint += 1 else mutated.occurrence += 1;
        try t.expectError(error.TemplateHoleChanged, template.matchHoles(t.allocator, &.{original}, &.{mutated}));
    }
    var second = original;
    second.occurrence = 1;
    const duplicate = try template.matchHoles(t.allocator, &.{ original, second }, &.{ second, original });
    defer t.allocator.free(duplicate);
    try t.expectEqualSlices(usize, &.{ 1, 0 }, duplicate);
    try t.expectError(error.TemplateHoleChanged, template.matchHoles(t.allocator, &.{ original, second }, &.{original}));
    try t.expectError(error.TemplateAmbiguousHole, template.matchHoles(t.allocator, &.{ original, original }, &.{ original, original }));
}

test "LP4 candidate rejects custom formatting before user code can run" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    fixture.probe.format_calls = 0;
    cx.root = try v.render(cx.root_scope.?, cx, fixture.Fancy(.{}));
    const old = cx.root;
    const calls = fixture.probe.format_calls;
    try t.expect(calls > 0);
    const bytes = try std.mem.replaceOwned(u8, t.allocator, source, "OriginalFancy", "ChangedFancy");
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer p.deinit();
    try expectReady(p);
    try t.expectError(error.TemplateCandidateSideEffects, p.apply(&.{cx}));
    try t.expectEqual(calls, fixture.probe.format_calls);
    try t.expectEqual(old, cx.root);
    try t.expectEqual(@as(u64, 0), reload.generation);
}

test "LP4 unchanged component syntax stays stable after a sibling edit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const compiler = @import("zenit_environment").preview.yix;
    const before = (try compiler.compilePreview(a, path, source)).document;
    const bytes = try changed(a);
    const after = (try compiler.compilePreview(a, path, bytes)).document;
    try t.expectEqualDeep(before.components[1].ops, after.components[1].ops);
}

test "LP4 preparation allocation failures never publish or change setup" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try mount(cx, t.allocator);
    count(i).set(53);
    const old = cx.root;
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    var reached_success = false;
    var failures: usize = 0;
    for (0..1024) |index| {
        // Arena growth can resize in place depending on allocator placement.
        // Fix that degree of freedom; fail every subsequent backing allocation.
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        if (prepare(failing.allocator(), bytes)) |p| {
            {
                defer p.deinit();
                try expectReady(p);
            }
            try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            reached_success = true;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
        }
        try t.expectEqual(old, cx.root);
        try t.expect(i.preview_template.?.active == null and i.preview_template.?.current_ops == null);
        try t.expectEqual(@as(u32, 53), count(i).peek());
        try t.expectEqual(@as(u64, 0), reload.generation);
        if (reached_success) break;
    }
    try t.expect(reached_success and failures > 0);
    try t.expectEqual(old, cx.root);
    try t.expectEqual(@as(u32, 53), count(i).peek());
    try t.expectEqual(@as(u64, 0), reload.generation);
}

test "LP4 embedded byte dependencies cannot silently change capture types" {
    defer reload.deinit();
    const template = @import("template.zig");
    const baseline = "const bytes = @embedFile(\"embedded.yix\"); pub fn Probe() View { return <col><text>Before</text></col>; }";
    const meta: template.Metadata = .{ .module = "embedded.yix", .source = baseline, .path = "Probe", .receiver = "col", .tokens = "< col > " };
    const value = template.site(meta, .{}, v.col(.{}, .{}));
    _ = try reload.lookup(@TypeOf(value), meta);
    const p = try reload.prepare(t.allocator, &.{.{ .path = "embedded.yix", .source = "const bytes = @embedFile(\"embedded.yix\"); pub fn Probe() View { return <col><text>After</text></col>; }" }});
    defer p.deinit();
    try t.expect(p.result == .fallback);
    try t.expectEqualStrings("template_embedded_dependency", p.result.fallback.reason);
}

// A generated compound expression calls scope.derive before the text factory.
// Checking the factory's value alone is too late to prevent a user getter.
test "LP4 derived captures are rejected before expression evaluation" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    const signal = try cx.root_scope.?.createSignal(u32, 7);
    const Reader = struct {
        var calls: usize = 0;
        fn read(values: anytype) u32 {
            calls += 1;
            return values[0].get();
        }
    };
    Reader.calls = 0;
    const reactive = @import("reactive.zig");
    const derived = reactive.derive(u32, .{signal}, Reader.read);
    cx.root = try v.render(cx.root_scope.?, cx, fixture.DerivedProbe(.{ .value = reactive.toSource(derived) }));
    try t.expect(Reader.calls > 0);
    const calls = Reader.calls;
    const old = cx.root;
    const nodes = cx.world.elements.count();
    const graph = cx.owner.graph.nodeCount();
    const bytes = try std.mem.replaceOwned(u8, t.allocator, source, "DerivedOriginal", "DerivedChanged");
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer p.deinit();
    try expectReady(p);
    try t.expectError(error.TemplateCandidateSideEffects, p.apply(&.{cx}));
    try t.expectEqual(calls, Reader.calls);
    try t.expectEqual(old, cx.root);
    try t.expectEqual(nodes, cx.world.elements.count());
    try t.expectEqual(graph, cx.owner.graph.nodeCount());
    try t.expectEqual(@as(u32, 7), signal.peek());
    try t.expectEqual(@as(u64, 0), reload.generation);
    try t.expect(text(cx.root.?, "8"));
}

test "LP4 active press cannot notify external watchers during commit" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try mount(cx, t.allocator);
    const old = cx.root.?;
    const target = old.children.items[0];
    const pressed = try cx.root_scope.?.createSignal(bool, true);
    var calls: usize = 0;
    try cx.root_scope.?.createEffect(.{ .pressed = pressed, .calls = &calls }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.pressed.get();
            ctx.calls.* += 1;
        }
    }.run);
    try cx.press_watchers.append(t.allocator, .{ .node = old, .signal = pressed });
    cx.pressed_node = target;
    // Preparation assertions/OOM can unwind before the normal cleanup below.
    // These manually registered watchers must never outlive their test signal.
    defer {
        cx.press_watchers.clearRetainingCapacity();
        cx.pressed_node = null;
        cx.pressed_handle = null;
    }
    const before_calls = calls;
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    const result = p.apply(&.{cx});
    const press_kept = cx.pressed_node == target;
    // Even the deliberately broken implementation must clean up without following
    // the now-freed press watcher node, so the regression reports an assertion.
    cx.press_watchers.clearRetainingCapacity();
    cx.pressed_node = null;
    cx.pressed_handle = null;
    try t.expectEqual(before_calls, calls);
    try t.expectError(error.ViewTransactionUnsupported, result);
    try t.expect(press_kept and pressed.peek());
    try t.expectEqual(old, cx.root.?);
    try t.expectEqual(@as(u32, 7), count(i).peek());
    try t.expectEqual(@as(u64, 0), reload.generation);
}

test "LP4 descendant overlay aliases reject before old nodes are freed" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try mount(cx, t.allocator);
    const old = cx.root.?;
    const handle = try cx.overlay_stack.push(.{ .kind = .non_modal, .enter_transition = .none });
    const layer = cx.overlay_stack.findLayer(handle).?;
    layer.content_node = old.children.items[0];
    layer.barrier_node = old.children.items[1];
    defer {
        for (cx.overlay_stack.layers.items) |*slot| slot.* = null;
        cx.overlay_stack.layer_count = 0;
    }
    const content = layer.content_node;
    const barrier = layer.barrier_node;
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    const result = p.apply(&.{cx});
    const aliases_kept = layer.content_node == content and layer.barrier_node == barrier;
    for (cx.overlay_stack.layers.items) |*slot| slot.* = null;
    cx.overlay_stack.layer_count = 0;
    try t.expectError(error.ViewTransactionUnsupported, result);
    try t.expect(aliases_kept);
    try t.expectEqual(old, cx.root.?);
    try t.expectEqual(@as(u32, 7), count(i).peek());
    try t.expectEqual(@as(u64, 0), reload.generation);
}

test "LP4 portal aliases into descendants reject before publication" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try mount(cx, t.allocator);
    const old = cx.root.?;
    cx.popover_portal_root = old.children.items[0];
    defer cx.popover_portal_root = null;
    const alias = cx.popover_portal_root;
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    const result = p.apply(&.{cx});
    const alias_kept = cx.popover_portal_root == alias;
    cx.popover_portal_root = null;
    try t.expectError(error.ViewTransactionUnsupported, result);
    try t.expect(alias_kept);
    try t.expectEqual(old, cx.root.?);
    try t.expectEqual(@as(u64, 0), reload.generation);
}

test "LP4 module catalog includes unmounted box and text styles" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try mount(cx, t.allocator);
    const bytes = try std.mem.replaceOwned(u8, t.allocator, source, "style={S.A}", "style={S.Unused}");
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    var p_owned = true;
    defer if (p_owned) p.deinit();
    try expectReady(p);
    _ = try p.apply(&.{cx});
    p_owned = false;
    try t.expectEqual(@as(f32, 19), cx.root.?.children.items[3].style.gap);
    const imported = try std.mem.replaceOwned(u8, t.allocator, source, "style={S.A}", "style={Palette.Unused}");
    defer t.allocator.free(imported);
    const imported_p = try prepare(t.allocator, imported);
    var imported_owned = true;
    defer if (imported_owned) imported_p.deinit();
    try expectReady(imported_p);
    _ = try imported_p.apply(&.{cx});
    imported_owned = false;
    try t.expectEqual(@as(f32, 27), cx.root.?.children.items[3].style.gap);
    const other = try core.Cx.init(t.allocator, t.io);
    defer other.deinit();
    other.root_scope = try core.Scope.init(t.allocator, null, other.owner);
    other.root = try v.render(other.root_scope.?, other, fixture.Literals(.{}));
    const text_bytes = try std.mem.replaceOwned(u8, t.allocator, bytes, "style={S.Title}", "style={S.UnusedTitle}");
    defer t.allocator.free(text_bytes);
    const q = try prepare(t.allocator, text_bytes);
    defer if (!q.committed) q.deinit();
    try expectReady(q);
    _ = try q.apply(&.{ cx, other });
    try t.expectEqual(@as(f32, 21), other.root.?.children.items[0].getText().?.font_size);
}

test "LP4 interpolation fragments and factory literals retain typed holes" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    cx.root = try v.render(cx.root_scope.?, cx, fixture.Literals(.{}));
    const instance = v.componentInstance(cx.root.?).?;
    const signal = count(instance);
    signal.set(17);
    const fragments = try std.mem.replaceOwned(u8, t.allocator, source, "before {count} after", "start {count} start");
    defer t.allocator.free(fragments);
    const styled = try std.mem.replaceOwned(u8, t.allocator, fragments, ".gap = 2", ".gap = 8");
    defer t.allocator.free(styled);
    const renamed = try std.mem.replaceOwned(u8, t.allocator, styled, "literal.root", "literal.new");
    defer t.allocator.free(renamed);
    const bytes = try std.mem.replaceOwned(u8, t.allocator, renamed, "visible={true}", "visible={false}");
    defer t.allocator.free(bytes);
    const old = cx.root;
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    p.fail_after = 1;
    try t.expectError(error.TemplateInjectedFailure, p.apply(&.{cx}));
    try t.expectEqual(old, cx.root);
    try t.expect(text(cx.root.?, "before 17 after"));
    p.fail_after = null;
    _ = try p.apply(&.{cx});
    try t.expectEqual(signal, count(instance));
    try t.expectEqualStrings("literal.new", cx.root.?.meta.ownership.meta.test_id.?);
    try t.expectEqual(.none, cx.root.?.style.display);
    try t.expectEqual(@as(f32, 8), cx.root.?.style.gap);
    try t.expect(text(cx.root.?, "start 17 start"));
    signal.set(18);
    try t.expect(text(cx.root.?, "start 18 start"));
    for ([_][2][]const u8{ .{ "{count}", "{count:03}" }, .{ "{count}", "{start}" }, .{ "onClick={count += 1}", "onClick={count += 2}" } }) |edit| {
        const bad = try std.mem.replaceOwned(u8, t.allocator, bytes, edit[0], edit[1]);
        defer t.allocator.free(bad);
        const rejected = try prepare(t.allocator, bad);
        defer rejected.deinit();
        try t.expect(rejected.result == .fallback);
    }
}

test "LP4 template generations plateau and stale preparations cannot publish" {
    defer reload.deinit();
    var counter = core.CountingAllocator{ .parent = t.allocator };
    const a = counter.allocator();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const instance = try mount(cx, t.allocator);
    const bytes = try changed(t.allocator);
    defer t.allocator.free(bytes);
    const stale = try prepare(t.allocator, bytes);
    defer stale.deinit();
    var plateau: usize = 0;
    for (0..32) |n| {
        const p = try prepare(a, if (n % 2 == 0) bytes else source);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        _ = try p.apply(&.{cx});
        try t.expectEqual(@min(n + 1, 2), reload.retainedVersionCount());
        if (n == 3) plateau = counter.live_bytes;
        if (n > 3) try t.expectEqual(plateau, counter.live_bytes);
        try t.expect(text(cx.root.?, "value 7"));
        try t.expectEqual(@as(u32, 7), count(instance).peek());
    }
    try t.expectError(error.TemplateStalePreparation, stale.apply(&.{cx}));
    reload.deinit();
    try t.expectEqual(@as(usize, 0), counter.live_bytes);
}

test "LP4 unchanged views own literals after their template arena retires" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try mount(cx, t.allocator);
    const other = try core.Cx.init(t.allocator, t.io);
    defer other.deinit();
    other.root_scope = try core.Scope.init(t.allocator, null, other.owner);
    other.root = try v.render(other.root_scope.?, other, fixture.Literals(.{}));
    const instance = v.componentInstance(other.root.?).?;
    const renamed = try std.mem.replaceOwned(u8, t.allocator, source, "literal.root", "persistent.id");
    defer t.allocator.free(renamed);
    const baseline = try std.mem.replaceOwned(u8, t.allocator, renamed, "before {count} after", "retained {count} fragments");
    defer t.allocator.free(baseline);
    const edit = try std.mem.replaceOwned(u8, t.allocator, baseline, ">Original<", ">Changed<");
    defer t.allocator.free(edit);
    for (0..8) |n| {
        const p = try prepare(t.allocator, if (n % 2 == 0) edit else baseline);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        const previous_root = other.root;
        _ = try p.apply(&.{ cx, other });
        if (n != 0) try t.expectEqual(previous_root, other.root);
        try t.expectEqualStrings("persistent.id", other.root.?.meta.ownership.meta.test_id.?);
        count(instance).set(@intCast(n + 10));
        var buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "retained {d} fragments", .{n + 10});
        try t.expect(text(other.root.?, expected));
    }
}

test "LP4 snapshots carry untouched modules across bounded generations" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try mount(cx, t.allocator);
    const other = try core.Cx.init(t.allocator, t.io);
    defer other.deinit();
    other.root_scope = try core.Scope.init(t.allocator, null, other.owner);
    other.root = try v.render(other.root_scope.?, other, fixture.Other(.{}));
    const bytes = try std.mem.replaceOwned(u8, t.allocator, fixture.other_source, "OriginalOther", "RetainedOther");
    defer t.allocator.free(bytes);
    const renamed = try std.mem.replaceOwned(u8, t.allocator, bytes, "other.original", "other.retained");
    defer t.allocator.free(renamed);
    const p = try reload.prepare(t.allocator, &.{.{ .path = "examples/template_probe/other.yix", .source = renamed }});
    var p_owned = true;
    defer if (p_owned) p.deinit();
    try expectReady(p);
    _ = try p.apply(&.{ cx, other });
    p_owned = false;
    const stable_root = other.root;
    const edit = try changed(t.allocator);
    defer t.allocator.free(edit);
    for (0..8) |n| {
        const q = try prepare(t.allocator, if (n % 2 == 0) edit else source);
        defer if (!q.committed) q.deinit();
        try expectReady(q);
        _ = try q.apply(&.{ cx, other });
        try t.expectEqual(@as(usize, 2), reload.retainedVersionCount());
        try t.expectEqual(stable_root, other.root);
        try t.expect(text(other.root.?, "RetainedOther"));
        try t.expectEqualStrings("other.retained", other.root.?.meta.ownership.meta.test_id.?);
    }
    // A fresh mount must read the carried snapshot after the original arena
    // has been freed, even though that module did not participate in later saves.
    const fresh = try core.Cx.init(t.allocator, t.io);
    defer fresh.deinit();
    fresh.root_scope = try core.Scope.init(t.allocator, null, fresh.owner);
    fresh.root = try v.render(fresh.root_scope.?, fresh, fixture.Other(.{}));
    try t.expect(text(fresh.root.?, "RetainedOther"));
    try t.expectEqualStrings("other.retained", fresh.root.?.meta.ownership.meta.test_id.?);
}

test "LP4 style catalogs reject incompatible receivers without executing factories" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try mount(cx, t.allocator);
    const other = try core.Cx.init(t.allocator, t.io);
    defer other.deinit();
    other.root_scope = try core.Scope.init(t.allocator, null, other.owner);
    other.root = try v.render(other.root_scope.?, other, fixture.Literals(.{}));
    const before = cx.root;
    const before_text = other.root;
    for ([_][2][]const u8{ .{ "style={S.A}", "style={S.TextOnly}" }, .{ "style={S.Title}", "style={S.HoverBox}" } }) |edit| {
        const bytes = try std.mem.replaceOwned(u8, t.allocator, source, edit[0], edit[1]);
        defer t.allocator.free(bytes);
        const p = try prepare(t.allocator, bytes);
        defer p.deinit();
        try t.expect(p.result == .fallback);
        try t.expectEqual(before, cx.root);
        try t.expectEqual(before_text, other.root);
        try t.expectEqual(@as(u64, 0), reload.generation);
    }
}

test "LP4 literal words do not create dynamic captures" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const instance = try mount(cx, t.allocator);
    const bytes = try std.mem.replaceOwned(u8, t.allocator, source, ">Original<", ">count<");
    defer t.allocator.free(bytes);
    const p = try prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    _ = try p.apply(&.{cx});
    try t.expect(text(cx.root.?, "count"));
    try t.expectEqual(@as(u32, 7), count(instance).peek());
}

test "LP4 long interpolation retains the visible buffer on update OOM" {
    inline for (.{ 247, 400 }) |length| {
        defer reload.deinit();
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const a = failing.allocator();
        const cx = try core.Cx.init(a, t.io);
        defer cx.deinit();
        cx.root_scope = try core.Scope.init(a, null, cx.owner);
        cx.root = try v.render(cx.root_scope.?, cx, fixture.Literals(.{}));
        const instance = v.componentInstance(cx.root.?).?;
        const prefix: [length]u8 = @splat('p');
        const replacement = prefix ++ "{count} tail";
        const bytes = try std.mem.replaceOwned(u8, t.allocator, source, "before {count} after", replacement);
        defer t.allocator.free(bytes);
        const p = try prepare(t.allocator, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        _ = try p.apply(&.{cx});
        try t.expect(text(cx.root.?, prefix ++ "4 tail"));
        failing.fail_index = failing.alloc_index;
        count(instance).set(std.math.maxInt(u32));
        try t.expect(text(cx.root.?, prefix ++ "4 tail"));
        failing.fail_index = std.math.maxInt(usize);
        count(instance).set(6);
        try t.expect(text(cx.root.?, prefix ++ "6 tail"));
    }
}

const r3 = fixture.remount;
const r3_source = fixture.remount_source;
const r3_path = "examples/template_probe/remount.yix";
fn r3Prepare(a: std.mem.Allocator, bytes: []const u8) !*reload.Preparation {
    return reload.prepare(a, &.{.{ .path = r3_path, .source = bytes }});
}
fn r3Mount(cx: *core.Cx, a: std.mem.Allocator) !*v.ComponentInstance {
    r3.mounts = 0;
    r3.unmounts = 0;
    r3.fail_mount = false;
    r3.mounted_hook = null;
    r3.unmounted_hook = null;
    cx.root_scope = try core.Scope.init(a, null, cx.owner);
    cx.root = try v.render(cx.root_scope.?, cx, r3.Parent(.{}));
    return v.componentInstance(cx.root.?).?;
}
fn findId(n: *core.Node, id: []const u8) ?*core.Node {
    if (n.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, id, value)) return n;
    for (n.children.items) |child| if (findId(child, id)) |found| return found;
    return null;
}
fn r3ChildSignal(i: *v.ComponentInstance) *@import("reactive.zig").Signal(u32) {
    const child = v.componentInstance(r3.parent_ref.?.get().?).?;
    _ = i;
    return @ptrCast(@alignCast(child.setup.signals.items[0]));
}
fn r3Signal(comptime T: type, i: *v.ComponentInstance, index: usize) *@import("reactive.zig").Signal(T) {
    return @ptrCast(@alignCast(i.setup.signals.items[index]));
}

test "LP4 descendants and For Show Match remount while parent setup survives" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try r3Mount(cx, t.allocator);
    const parent_signal = count(i);
    parent_signal.set(31);
    r3ChildSignal(i).set(40);
    const row_instance = v.componentInstance(findId(cx.root.?, "r3.row").?.parent.?).?;
    const row_signal: *@import("reactive.zig").Signal(u32) = @ptrCast(@alignCast(row_instance.setup.signals.items[0]));
    row_signal.set(41);
    const parent_ref = r3.parent_ref.?;
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, "RemountOriginal", "RemountChanged");
    defer t.allocator.free(bytes);
    const initial_nodes = cx.world.elements.count();
    const initial_graph = cx.owner.graph.nodeCount();
    for (0..6) |round| {
        const p = try r3Prepare(t.allocator, if (round % 2 == 0) bytes else r3_source);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        const before = r3.mounts;
        try t.expectEqual(@as(usize, 1), try p.apply(&.{cx}));
        try t.expectEqual(@as(usize, 5), r3.mounts - before);
        try t.expectEqual(i, v.componentInstance(cx.root.?).?);
        try t.expectEqual(parent_signal, count(i));
        try t.expectEqual(@as(u32, 31), parent_signal.peek());
        try t.expectEqual(parent_ref, r3.parent_ref.?);
        try t.expectEqual(@as(u32, 3), r3ChildSignal(i).peek());
        try t.expectEqualStrings("child 3", findId(cx.root.?, "r3.row").?.getText().?.content);
        try t.expectEqual(initial_nodes, cx.world.elements.count());
        try t.expectEqual(initial_graph, cx.owner.graph.nodeCount());
        r3ChildSignal(i).set(40);
    }
    // For insertion/removal and both branch transitions still work after reload.
    r3Signal([]const u32, i, 1).set(&.{ 2, 3, 4 });
    r3Signal(bool, i, 2).set(false);
    r3Signal(r3.Mode, i, 3).set(.b);
    try t.expect(text(cx.root.?, "hidden"));
    try t.expect(text(cx.root.?, "mode b"));
    const p = try r3Prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    const before = r3.mounts;
    _ = try p.apply(&.{cx});
    try t.expectEqual(@as(usize, 4), r3.mounts - before);
    try t.expect(text(cx.root.?, "hidden"));
    try t.expect(text(cx.root.?, "mode b"));
    r3Signal([]const u32, i, 1).set(&.{1});
    r3Signal(bool, i, 2).set(true);
    r3Signal(r3.Mode, i, 3).set(.a);
    try t.expect(findId(cx.root.?, "r3.show") != null);
    try t.expect(findId(cx.root.?, "r3.match") != null);
}

test "LP4 descendant candidate OOM has no lifecycle or ref residue" {
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, "RemountOriginal", "RemountChanged");
    defer t.allocator.free(bytes);
    var reached = false;
    for (0..1500) |offset| {
        defer reload.deinit();
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const a = failing.allocator();
        const cx = try core.Cx.init(a, t.io);
        defer cx.deinit();
        const i = try r3Mount(cx, a);
        R3External.owner = cx;
        R3External.fail_stage = null;
        R3External.written = 0;
        r3.mounted_hook = R3External.acquire;
        defer r3.mounted_hook = null;
        count(i).set(29);
        r3ChildSignal(i).set(43);
        const old = cx.root;
        const ref = r3.parent_ref.?.get();
        const ref_generation = r3.parent_ref.?.generation;
        const nodes = cx.world.elements.count();
        const graph = cx.owner.graph.nodeCount();
        const scopes = i.setup.children.items.len;
        const mounts = r3.mounts;
        const unmounts = r3.unmounts;
        const p = try r3Prepare(a, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        failing.fail_index = failing.alloc_index + offset;
        if (p.apply(&.{cx})) |_| {
            reached = true;
            try t.expectEqual(@as(u32, 29), count(i).peek());
            try t.expectEqual(@as(u32, 3), r3ChildSignal(i).peek());
            break;
        } else |err| {
            // Commit allocation failures use the irreversible L3 contract.
            if (reload.needs_remount) {
                try t.expect(p.committed);
                try t.expectEqual(.needs_remount, i.state);
                continue;
            }
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(old, cx.root);
            try t.expectEqual(.ready, i.state);
            try t.expectEqual(nodes, cx.world.elements.count());
            try t.expectEqual(graph, cx.owner.graph.nodeCount());
            try t.expectEqual(scopes, i.setup.children.items.len);
            try t.expectEqual(ref, r3.parent_ref.?.get());
            try t.expectEqual(ref_generation, r3.parent_ref.?.generation);
            try t.expectEqual(mounts, r3.mounts);
            try t.expectEqual(unmounts, r3.unmounts);
            try t.expectEqual(@as(usize, 0), R3External.live);
            try t.expectEqual(@as(u32, 0), R3External.written);
            try t.expectEqual(@as(u32, 43), r3ChildSignal(i).peek());
            try t.expectEqual(@as(u32, 29), count(i).peek());
        }
    }
    try t.expect(reached);
}

fn rejectUnknownChild(mode: usize) !void {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    cx.root = switch (mode) {
        0 => try v.render(cx.root_scope.?, cx, r3.UnsafeParent(.{})),
        1 => try v.render(cx.root_scope.?, cx, r3.PointerParent(.{})),
        2 => try v.render(cx.root_scope.?, cx, r3.BlockParent(.{})),
        else => try v.render(cx.root_scope.?, cx, r3.WrappedParent(.{})),
    };
    const before = r3.unsafe_calls;
    const old = cx.root;
    const marker = if (mode == 0) "UnsafeOriginal" else if (mode == 1) "PointerOriginal" else if (mode == 2) "BlockOriginal" else "WrappedOriginal";
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, marker, "UnsafeChanged");
    defer t.allocator.free(bytes);
    const p = try r3Prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    try t.expectError(error.TemplateCandidateSideEffects, p.apply(&.{cx}));
    try t.expectEqual(before, r3.unsafe_calls);
    try t.expectEqual(old, cx.root);
    try t.expect(!reload.needs_remount);
}

test "LP4 unknown child setup is rejected before external code executes" {
    for (0..3) |mode| try rejectUnknownChild(mode);
}

test "LP4 generated proofs check builder and mount function identity" {
    try rejectUnknownChild(3);
    // A caller can also construct Component with generated Props but a different
    // mount function. Validate the function, before creating its setup scope.
    const Fake = struct {
        fn mount(_: r3.ChildProps, _: *core.Scope, _: *core.Cx) anyerror!*core.Node {
            r3.unsafe_calls += 1;
            return error.UnknownMountExecuted;
        }
    };
    const tx_mod = @import("preview_mount.zig");
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try core.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    var tx = tx_mod.Transaction.init(t.allocator);
    defer tx.deinit();
    tx_mod.current = &tx;
    defer tx_mod.current = null;
    const before = r3.unsafe_calls;
    try t.expectError(error.TemplateCandidateSideEffects, v.component(Fake.mount, @as(r3.ChildProps, .{})).mount(scope, cx));
    try t.expectEqual(before, r3.unsafe_calls);
}

test "LP4 every descendant commit action failure requests L3 without rollback" {
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, "RemountOriginal", "RemountChanged");
    defer t.allocator.free(bytes);
    var completed = false;
    for (0..30) |index| {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const i = try r3Mount(cx, t.allocator);
        count(i).set(29);
        const p = try r3Prepare(t.allocator, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        p.fail_commit_at = index;
        if (p.apply(&.{cx})) |_| {
            completed = true;
            break;
        } else |err| {
            try t.expectEqual(error.TemplateCommitInjectedFailure, err);
            try t.expect(p.committed);
            try t.expectEqual(.needs_remount, i.state);
            try t.expect(reload.needs_remount);
            try t.expectEqualStrings("TemplateCommitInjectedFailure", reload.remount_reason.?);
            try t.expect(text(cx.root.?, "RemountChanged"));
            try t.expectEqual(@as(u32, 29), count(i).peek());
        }
    }
    try t.expect(completed);
    // Real fallible onMount, rather than only the commit-loop injector.
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const i = try r3Mount(cx, t.allocator);
    r3.fail_mount = true;
    defer r3.fail_mount = false;
    const p = try r3Prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try t.expectError(error.ProbeMountFailed, p.apply(&.{cx}));
    try t.expectEqual(.needs_remount, i.state);
    try t.expect(reload.needs_remount);
}

var r3_reentry: ?*reload.Preparation = null;
var r3_close_scope: ?*core.Scope = null;
var r3_close_cx: ?*core.Cx = null;
fn r3Reenter() anyerror!void {
    _ = r3_reentry.?.apply(&.{}) catch {};
}
fn r3CloseOwner() anyerror!void {
    r3_close_cx.?.root_scope = null;
    r3_close_scope.?.dispose();
}
fn r3DestroyChild() anyerror!void {
    const cx = r3_close_cx.?;
    cx.freeNode(findId(cx.root.?, "r3.child").?.parent.?);
}
fn r3ClosePreviousOwner() anyerror!void {
    if (r3.mounts > 10) try r3CloseOwner();
}
fn r3DisposeChildSetup() anyerror!void {
    const cx = r3_close_cx.?;
    v.componentInstance(findId(cx.root.?, "r3.child").?.parent.?).?.setup.dispose();
}

test "LP4 callback reentry and owner destruction request remount safely" {
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, "RemountOriginal", "RemountChanged");
    defer t.allocator.free(bytes);
    for (0..11) |mode| {
        defer reload.deinit();
        const a = try core.Cx.init(t.allocator, t.io);
        defer a.deinit();
        const b = try core.Cx.init(t.allocator, t.io);
        defer b.deinit();
        const i = try r3Mount(a, t.allocator);
        if (mode == 10) _ = try mount(b, t.allocator) else _ = try r3Mount(b, t.allocator);
        const p = try r3Prepare(t.allocator, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        if (mode == 10 or mode == 9) {
            const target = if (mode == 10) b else a;
            r3_close_cx = target;
            r3_close_scope = target.root_scope;
            r3.mounted_hook = if (mode == 10) r3CloseOwner else r3ClosePreviousOwner;
        } else if (mode == 8) {
            r3_close_cx = a;
            r3.mounted_hook = r3DisposeChildSetup;
        } else if (mode == 7) {
            r3.mounted_hook = struct {
                fn call() anyerror!void {
                    reload.deinit();
                    reload.deinit();
                    try t.expect(reload.commit_reentered);
                    try t.expectEqual(@as(u64, 0), reload.generation);
                    try t.expect(reload.remount_reason == null);
                }
            }.call;
        } else if (mode == 6) {
            r3_close_cx = a;
            r3.mounted_hook = r3DestroyChild;
        } else if (mode % 3 == 0) {
            r3_reentry = p;
            if (mode < 3) r3.mounted_hook = r3Reenter else r3.unmounted_hook = struct {
                fn call() void {
                    r3Reenter() catch unreachable;
                }
            }.call;
        } else {
            // Scope/host closure is deferred by the owner guard. Cx itself is
            // host-owned and remains valid until dev-control returns.
            const owner = if (mode % 3 == 1) a else b;
            r3_close_scope = owner.root_scope;
            r3_close_cx = owner;
            if (mode < 3) r3.mounted_hook = r3CloseOwner else r3.unmounted_hook = struct {
                fn call() void {
                    r3CloseOwner() catch unreachable;
                }
            }.call;
        }
        defer {
            r3.mounted_hook = null;
            r3.unmounted_hook = null;
        }
        if ((mode % 3 == 0 and mode < 6) or mode == 7) {
            try t.expectError(error.TemplateReloadReentry, p.apply(&.{ a, b }));
            try t.expectEqual(.needs_remount, i.state);
        } else try t.expectError(error.ViewMountCancelled, p.apply(&.{ a, b }));
        try t.expect(reload.needs_remount);
        try t.expect(p.committed);
        if (mode == 7) {
            const entry = i.preview_template.?;
            try t.expect(!entry.registered);
            try t.expect(entry.next == null and entry.active == null and entry.current_ops == null);
            // The in-flight receiver remains alive until the caller's safe-point
            // cleanup. Normal deinit is repeatable and releases all retained data.
            try t.expect(reload.retainedVersionCount() > 0);
        }
        if (mode == 1 or mode == 4) try t.expect(a.root == null);
        if (mode == 2 or mode == 5) try t.expect(b.root == null);
        if (mode == 9) try t.expect(a.root == null);
        if (mode == 10) {
            try t.expect(b.root == null);
            try t.expectEqual(@as(u32, 7), count(i).peek());
        }
        if (mode == 6 or mode == 8) {
            try t.expect(a.root == null);
            try t.expectEqual(.needs_remount, i.state);
            try t.expectEqual(@as(u32, 7), count(i).peek());
        }
    }
}

test "LP4 mount queue preserves normal child ref parent order and cancels scopes" {
    const tx_mod = @import("preview_mount.zig");
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try core.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const Actions = struct {
        var log: [8]u8 = @splat(0);
        var len: usize = 0;
        fn record(value: u8) void {
            log[len] = value;
            len += 1;
        }
        fn mountChild(_: void) void {
            record(1);
        }
        fn writeRef(_: void, _: *core.Scope) !void {
            record(2);
        }
        fn mountParent(_: void) void {
            record(3);
        }
    };
    // Normal and candidate use identical call sites, yielding identical order.
    Actions.len = 0;
    try v.runMountAction(scope, {}, Actions.mountChild);
    try Actions.writeRef({}, scope);
    try v.runMountAction(scope, {}, Actions.mountParent);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3 }, Actions.log[0..Actions.len]);
    Actions.len = 0;
    var tx = tx_mod.Transaction.init(t.allocator);
    defer tx.deinit();
    tx_mod.current = &tx;
    defer tx_mod.current = null;
    try v.runMountAction(scope, {}, Actions.mountChild);
    _ = try tx_mod.deferAction(scope, .ref, {}, Actions.writeRef);
    try v.runMountAction(scope, {}, Actions.mountParent);
    const cancelled = try scope.childScope();
    try v.runMountAction(cancelled, {}, Actions.mountParent);
    cancelled.dispose();
    try t.expectEqual(@as(usize, 0), Actions.len);
    tx_mod.current = null;
    // Cancelled actions are skipped; a scope cancelled by a running action is a
    // different case and must fail commit (covered by owner destruction above).
    try tx.run();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3 }, Actions.log[0..Actions.len]);
}

test "LP4 timers subscriptions global writes and registrations wait for commit" {
    const tx_mod = @import("preview_mount.zig");
    const Resource = struct {
        cx: *core.Cx,
        timer: ?u64 = null,
        subscription: ?u64 = null,
        var registrations: usize = 0;
        var calls: usize = 0;
        fn timerFired(_: ?*anyopaque) void {
            calls += 1;
        }
        fn visibilityChanged(_: *anyopaque) void {}
        fn cleanup(self: *@This()) void {
            if (self.timer) |id| self.cx.clearTimer(id);
            if (self.subscription) |id| self.cx.focus_manager.unsubscribeVisibility(id);
            registrations -= 1;
        }
        fn acquire(cx: *core.Cx, scope: *core.Scope) !void {
            const self = try scope.createState(@This(), .{ .cx = cx });
            // Register cleanup before publishing any external resource.
            try scope.onCleanup(@This(), self, cleanup);
            registrations += 1;
            self.timer = try cx.setTimer(0, timerFired, null);
            self.subscription = try cx.focus_manager.subscribeVisibility(self, visibilityChanged);
        }
        fn write(signal: *@import("reactive.zig").Signal(u32), _: *core.Scope) !void {
            signal.set(99);
        }
        fn mounted(_: void) void {
            calls += 1;
        }
    };
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const root = try core.Scope.init(t.allocator, null, cx.owner);
    defer root.dispose();
    const signal = try root.createSignal(u32, 7);
    for (0..2) |commit| {
        const scope = try root.childScope();
        var tx = tx_mod.Transaction.init(t.allocator);
        defer tx.deinit();
        tx_mod.current = &tx;
        defer tx_mod.current = null;
        Resource.calls = 0;
        _ = try tx_mod.deferAction(scope, .timer, cx, Resource.acquire);
        _ = try tx_mod.deferAction(scope, .subscription, signal, Resource.write);
        _ = try tx_mod.deferAction(scope, .registration, cx, Resource.acquire);
        try v.setupEffect(scope, {}, Resource.mounted);
        try v.runMountAction(scope, {}, Resource.mounted);
        try t.expectEqual(@as(usize, 0), Resource.registrations);
        try t.expectEqual(@as(usize, 0), cx.timers.items.len);
        try t.expectEqual(@as(u32, 7), signal.peek());
        try t.expectEqual(@as(usize, 0), Resource.calls);
        tx_mod.current = null;
        if (commit == 1) {
            try tx.run();
            try t.expectEqual(@as(usize, 2), Resource.registrations);
            try t.expectEqual(@as(usize, 2), cx.timers.items.len);
            try t.expectEqual(@as(u32, 99), signal.peek());
            try t.expectEqual(@as(usize, 2), Resource.calls);
        }
        scope.dispose();
        try t.expectEqual(@as(usize, 0), Resource.registrations);
        try t.expectEqual(@as(usize, 0), cx.timers.items.len);
    }
}

test "LP4 portal candidate never attaches to the external overlay host" {
    const tx_mod = @import("preview_mount.zig");
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const root = try core.Scope.init(t.allocator, null, cx.owner);
    defer root.dispose();
    cx.root = try v.render(root, cx, v.box(.{}, .{}));
    _ = try cx.themeSignal();
    _ = try cx.styleGenerationSignal();
    for (0..2) |commit| {
        const scope = try root.childScope();
        var tx = tx_mod.Transaction.init(t.allocator);
        defer tx.deinit();
        tx_mod.current = &tx;
        defer tx_mod.current = null;
        const nodes = cx.world.elements.count();
        try v.emit(scope, cx, .{ .parent = null }, v.portal(v.text(.{}, "portal candidate")));
        try t.expect(cx.popover_portal_root == null or cx.popover_portal_root.?.children.items.len == 0);
        tx_mod.current = null;
        if (commit == 1) {
            try tx.run();
            try t.expectEqual(@as(usize, 1), cx.popover_portal_root.?.children.items.len);
        }
        scope.dispose();
        try t.expect(cx.popover_portal_root == null or cx.popover_portal_root.?.children.items.len == 0);
        try t.expectEqual(nodes + @as(usize, if (commit == 1) 1 else 0), cx.world.elements.count());
    }
}

test "LP4 every external effect failure crosses the publication boundary" {
    // A hand-authored component explicitly using the setup/view contract lets
    // this test reach every framework effect entry point in one publication.
    // Arbitrary authored Yix builders remain rejected by the separate proof gate.
    const Protocol = struct {
        const module = "tests/lp4_all_effects.yix";
        const baseline = "pub fn AllEffects() View { return <col><text>EffectsOriginal</text></col>; }";
        const Signal = @import("reactive.zig").Signal(u32);
        const Context = struct { ref: *v.Ref(*core.Node), shared: *Signal };
        var shared: *Signal = undefined;
        var registrations: usize = 0;
        const Timer = struct {
            cx: *core.Cx,
            id: ?u64 = null,
            fn cleanup(self: *@This()) void {
                if (self.id) |id| self.cx.clearTimer(id);
            }
            fn fired(_: ?*anyopaque) void {}
        };
        fn addTimer(cx: *core.Cx, scope: *core.Scope) !void {
            const timer = try scope.createState(Timer, .{ .cx = cx });
            try scope.onCleanup(Timer, timer, Timer.cleanup);
            timer.id = try cx.setTimer(0, Timer.fired, null);
        }
        fn unregister(_: *u8) void {
            registrations -= 1;
        }
        fn register(_: void, scope: *core.Scope) !void {
            const ticket = try scope.createState(u8, 0);
            try scope.onCleanup(u8, ticket, unregister);
            registrations += 1;
        }
        fn write(signal: *Signal) void {
            signal.set(99);
        }
        fn noop(_: void) void {}
        fn mount(scope: *core.Scope, cx: *core.Cx) !*core.Node {
            return v.renderComponentView(scope, cx, Context{ .ref = try v.createRef(scope, *core.Node), .shared = shared }, build);
        }
        fn build(ctx: Context, scope: *core.Scope, cx: *core.Cx, sink: v.Sink) !*core.Node {
            try v.emit(scope, cx, sink, v.ref(ctx.ref, v.templateSite(.{
                .module = module,
                .path = "AllEffects",
                .receiver = "col",
                .tokens = "col ",
                .source = baseline,
            }, .{}, v.col(.{}, .{v.templateSite(.{
                .module = module,
                .path = "AllEffects",
                .receiver = "text",
                .tokens = "text ",
                .literal_text = "EffectsOriginal",
            }, .{}, v.text(.{}, "EffectsOriginal"))}))));
            const root = sink.root.?.*.?;
            try v.emit(scope, cx, .{ .parent = null }, v.portal(v.text(.{}, "external portal")));
            _ = try @import("hooks.zig").usePressed(scope, cx, root);
            _ = try @import("hooks.zig").useFocusState(scope, cx, root);
            try v.setupEffect(scope, ctx.shared, write);
            try v.setupCleanup(scope, {}, noop);
            if (!try reload.mount_effects.deferAction(scope, .timer, cx, addTimer)) try addTimer(cx, scope);
            if (!try reload.mount_effects.deferAction(scope, .registration, {}, register)) try register({}, scope);
            try v.runMountAction(scope, {}, noop);
            return root;
        }
    };
    const bytes = try std.mem.replaceOwned(u8, t.allocator, Protocol.baseline, "EffectsOriginal", "EffectsChanged");
    defer t.allocator.free(bytes);
    // ref, portal, press, focus, effect, cleanup, timer, registration, onMount.
    for (0..10) |index| {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        var destroyed = false;
        defer if (!destroyed) cx.deinit();
        cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
        cx.root = try v.render(cx.root_scope.?, cx, v.box(.{}, .{}));
        Protocol.shared = try cx.root_scope.?.createSignal(u32, 7);
        const root = try v.component(Protocol.mount, {}).mount(cx.root_scope.?, cx);
        try cx.root.?.appendChild(cx.allocator, root);
        const instance = v.componentInstance(root).?;
        Protocol.shared.set(7);
        const p = try reload.prepare(t.allocator, &.{.{ .path = Protocol.module, .source = bytes }});
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        p.fail_commit_at = index;
        if (index < 9) {
            try t.expectError(error.TemplateCommitInjectedFailure, p.apply(&.{cx}));
            try t.expectEqual(.needs_remount, instance.state);
            try t.expect(reload.needs_remount);
            try t.expectEqualStrings("TemplateCommitInjectedFailure", reload.remount_reason.?);
            try t.expectEqual(@as(u32, if (index > 4) 99 else 7), Protocol.shared.peek());
        } else {
            try t.expectEqual(@as(usize, 1), try p.apply(&.{cx}));
            try t.expect(!reload.needs_remount);
        }
        try t.expect(p.committed);
        try t.expect(text(cx.root.?, "EffectsChanged"));
        cx.deinit();
        destroyed = true;
        try t.expectEqual(@as(usize, 0), Protocol.registrations);
    }
}

test "LP4 parent and child batch uses one descriptor snapshot" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try r3Mount(cx, t.allocator);
    const parent_edit = try std.mem.replaceOwned(u8, t.allocator, r3_source, "RemountOriginal", "RemountChanged");
    defer t.allocator.free(parent_edit);
    const both = try std.mem.replaceOwned(u8, t.allocator, parent_edit, "child {value}", "descendant {value}");
    defer t.allocator.free(both);
    const p = try r3Prepare(t.allocator, both);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    try t.expectEqual(@as(usize, 1), try p.apply(&.{cx}));
    try t.expect(text(cx.root.?, "RemountChanged"));
    try t.expectEqualStrings("descendant 3", findId(cx.root.?, "r3.child").?.getText().?.content);
    try t.expectEqualStrings("descendant 3", findId(cx.root.?, "r3.row").?.getText().?.content);
}

test "LP4 candidate cannot create Cx services outside its scope" {
    const tx_mod = @import("preview_mount.zig");
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    var tx = tx_mod.Transaction.init(t.allocator);
    defer tx.deinit();
    tx_mod.current = &tx;
    defer tx_mod.current = null;
    try t.expectError(error.TemplateCandidateSideEffects, cx.themeSignal());
    try t.expectError(error.TemplateCandidateSideEffects, cx.styleGenerationSignal());
    try t.expectError(error.TemplateCandidateSideEffects, cx.a11yPreferencesSignal());
    try t.expect(cx.service_scope == null);
    tx_mod.current = null;
    const signal = try cx.themeSignal();
    tx_mod.current = &tx;
    try t.expectEqual(signal, try cx.themeSignal());
    try t.expectError(error.TemplateCandidateSideEffects, cx.styleGenerationSignal());
}

test "LP4 window hook subscriptions are deferred and dispose cleanly" {
    const queue = @import("preview_mount.zig");
    const hooks = @import("hooks.zig");
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const root = try core.Scope.init(t.allocator, null, cx.owner);
    defer root.dispose();
    cx.root = try v.render(root, cx, v.box(.{}, .{}));
    const node = cx.root.?;
    // Include ordinary dev mount in the oracle. Multiple hover listeners must
    // chain when attached, even though all three were prepared before publish.
    for (0..3) |mode| {
        const scope = try root.childScope();
        var tx = queue.Transaction.init(t.allocator);
        defer tx.deinit();
        queue.current = if (mode == 2) null else &tx;
        defer queue.current = null;
        _ = try hooks.usePressed(scope, cx, node);
        _ = try hooks.useFocusState(scope, cx, node);
        const hover1 = try hooks.useHover(scope, node);
        const hover2 = try hooks.useHover(scope, node);
        try hooks.useFocusRing(scope, cx, node, .{});
        const highlight = try hooks.useHoverHighlight(scope, node, node, .background, .rgb(0, 0, 0), .rgb(255, 255, 255), .{});
        if (mode != 2) {
            try t.expectEqual(@as(usize, 0), cx.press_watchers.items.len);
            try t.expectEqual(@as(usize, 0), cx.focus_manager.visibility_listeners.items.len);
            try t.expectEqual(@as(usize, 0), hooks.testing.hoverListenerCount(node));
            try t.expectEqual(@as(u8, 0), node.meta.per_frame.hooks.before_render.count);
        }
        queue.current = null;
        if (mode != 0) {
            if (mode == 1) try tx.run();
            try t.expect(node.meta.per_frame.hooks.slots.preview_hover_pending == null);
            try t.expectEqual(@as(usize, 1), cx.press_watchers.items.len);
            try t.expectEqual(@as(usize, 2), cx.focus_manager.visibility_listeners.items.len);
            try t.expectEqual(@as(usize, 3), hooks.testing.hoverListenerCount(node));
            try t.expectEqual(@as(u8, 2), node.meta.per_frame.hooks.before_render.count);
            try t.expect(cx.focus_manager.visibility_listeners.items[0].id < cx.focus_manager.visibility_listeners.items[1].id);
            node.behavior.events.on_hover.?.invoke();
            try t.expect(hover1.peek() and hover2.peek() and highlight.peek());
            node.behavior.events.on_leave.?.invoke();
            try t.expect(!hover1.peek() and !hover2.peek() and !highlight.peek());
        }
        scope.dispose();
        try t.expect(node.meta.per_frame.hooks.slots.preview_hover_pending == null);
        try t.expectEqual(@as(usize, 0), cx.press_watchers.items.len);
        try t.expectEqual(@as(usize, 0), cx.focus_manager.visibility_listeners.items.len);
        try t.expectEqual(@as(usize, 0), hooks.testing.hoverListenerCount(node));
        try t.expectEqual(@as(u8, 0), node.meta.per_frame.hooks.before_render.count);
        try t.expect(node.behavior.events.on_focus == null and node.behavior.events.on_blur == null);
    }
}

test "LP4 candidate hook allocation failures leave no external registrations" {
    const hooks = @import("hooks.zig");
    const queue = @import("preview_mount.zig");
    var completed = false;
    for (0..200) |fail_index| {
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const scope = try core.Scope.init(failing.allocator(), null, cx.owner);
        const node = try core.box(cx, .{}, .{});
        var node_alive = true;
        defer if (node_alive) cx.freeNode(node);
        var tx = queue.Transaction.init(failing.allocator());
        defer tx.deinit();
        failing.fail_index = failing.alloc_index + fail_index;
        queue.current = &tx;
        const result = struct {
            fn build(s: *core.Scope, c: *core.Cx, n: *core.Node) !void {
                _ = try hooks.useHover(s, n);
                try hooks.useFocusRing(s, c, n, .{});
                _ = try hooks.useHoverHighlight(s, n, n, .background, .rgb(0, 0, 0), .rgb(255, 255, 255), .{});
            }
        }.build(scope, cx, node);
        queue.current = null;
        defer scope.dispose();
        try t.expectEqual(@as(usize, 0), cx.focus_manager.visibility_listeners.items.len);
        try t.expectEqual(@as(usize, 0), hooks.testing.hoverListenerCount(node));
        try t.expectEqual(@as(u8, 0), node.meta.per_frame.hooks.before_render.count);
        // Also exercise partial initialization with target-first teardown.
        cx.freeNode(node);
        node_alive = false;
        if (result) |_| {
            completed = true;
            break;
        } else |err| try t.expectEqual(error.OutOfMemory, err);
    }
    try t.expect(completed);
}

test "LP4 discarded root never invokes user blur or detach callbacks" {
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try core.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    var calls: usize = 0;
    const Callback = struct {
        fn run(raw: *anyopaque) void {
            const counter: *usize = @ptrCast(@alignCast(raw));
            counter.* += 1;
        }
    };
    const node = try v.render(scope, cx, v.box(.{ .focusable = true }, .{}));
    cx.root = node;
    node.behavior.events.on_blur = core.Cx.simpleHandler(Callback.run, &calls);
    cx.setFocus(node);
    // Publication has drained deferred disposal at this point. The discard
    // contract must hold at depth zero as well as while a callback is guarded.
    try t.expectEqual(@as(u32, 0), cx.owner.reactive_callback_depth);
    v.discardPreviewRootWhileGuarded(cx, node);
    try t.expectEqual(@as(usize, 0), calls);
    try t.expect(cx.root == null);
}

const R3External = struct {
    cx: *core.Cx,
    timer: ?u64 = null,
    subscription: ?u64 = null,
    var owner: *core.Cx = undefined;
    var live: usize = 0;
    var fail_stage: ?usize = null;
    var written: u32 = 0;
    fn tick(_: ?*anyopaque) void {}
    fn visible(_: *anyopaque) void {}
    fn release(self: *@This()) void {
        if (self.timer) |id| self.cx.clearTimer(id);
        if (self.subscription) |id| self.cx.focus_manager.unsubscribeVisibility(id);
        live -= 1;
    }
    fn acquire() anyerror!void {
        // Called by an actual generated child onMount after its root is attached.
        const i = v.componentInstance(findId(owner.root.?, "r3.child").?.parent.?).?;
        const self = try i.setup.createState(@This(), .{ .cx = owner });
        try i.setup.onCleanup(@This(), self, release);
        live += 1;
        self.timer = try owner.setTimer(0, tick, null);
        if (fail_stage == 0) return error.ExternalTimerFailed;
        self.subscription = try owner.focus_manager.subscribeVisibility(self, visible);
        if (fail_stage == 1) return error.ExternalSubscriptionFailed;
        written += 1;
        if (fail_stage == 2) return error.ExternalWriteFailed;
    }
};

test "LP4 real external onMount failures require remount and clean resources" {
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, "RemountOriginal", "RemountChanged");
    defer t.allocator.free(bytes);
    for (0..3) |stage| {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        var destroyed = false;
        defer if (!destroyed) cx.deinit();
        defer r3.mounted_hook = null;
        const i = try r3Mount(cx, t.allocator);
        R3External.owner = cx;
        R3External.fail_stage = stage;
        R3External.written = 0;
        r3.mounted_hook = R3External.acquire;
        const p = try r3Prepare(t.allocator, bytes);
        defer if (!p.committed) p.deinit();
        const err = if (stage == 0) error.ExternalTimerFailed else if (stage == 1) error.ExternalSubscriptionFailed else error.ExternalWriteFailed;
        try t.expectError(err, p.apply(&.{cx}));
        try t.expect(reload.needs_remount);
        try t.expectEqual(.needs_remount, i.state);
        try t.expectEqual(@as(usize, 1), R3External.live);
        try t.expectEqual(@as(u32, if (stage == 2) 1 else 0), R3External.written);
        r3.mounted_hook = null;
        cx.deinit();
        destroyed = true;
        try t.expectEqual(@as(usize, 0), R3External.live);
    }
    R3External.fail_stage = null;
}

test "LP4 LP5 child relocation preserves setup ref and attachments across A B A" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try r3Mount(cx, t.allocator);
    const child = v.componentInstance(findId(cx.root.?, "r3.child").?.parent.?).?;
    const signal: *@import("reactive.zig").Signal(u32) = @ptrCast(@alignCast(child.setup.signals.items[0]));
    signal.set(29);
    const handle = r3.parent_ref.?;
    const ref_generation = handle.generation;
    const root = child.parts.root.?;
    const moved = try std.mem.replaceOwned(u8, t.allocator, r3_source, "<text>RemountOriginal</text>\n        <Child ref={handle}/>", "<Child ref={handle}/>\n        <text>RemountOriginal</text>");
    defer t.allocator.free(moved);
    for (0..6) |iteration| {
        const p = try r3Prepare(t.allocator, if (iteration % 2 == 0) moved else r3_source);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        _ = try p.apply(&.{cx});
        try t.expectEqual(root, child.parts.root.?);
        try t.expectEqual(child, v.componentInstance(findId(cx.root.?, "r3.child").?.parent.?).?);
        try t.expectEqual(@as(u32, 29), signal.peek());
        try t.expect(text(cx.root.?, "child 29"));
        try t.expectEqual(root, handle.get().?);
        try t.expectEqual(ref_generation, handle.generation);
        try t.expect(child.setup.parent == v.componentInstance(cx.root.?).?.view_scope);
        for (child.attachments.items) |attachment| try t.expectEqual(child.setup.parent, attachment.caller);
    }
}

test "LP4 deferred ref and cleanup preserve ordinary disposal registration order" {
    const queue = @import("preview_mount.zig");
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const owner = try core.Scope.init(t.allocator, null, cx.owner);
    defer owner.dispose();
    _ = try cx.themeSignal();
    _ = try cx.styleGenerationSignal();
    const ref = try v.createRef(owner, *core.Node);
    const Trace = struct {
        var bytes: [8]u8 = @splat(0);
        var len: usize = 0;
        fn user(r: *v.Ref(*core.Node)) void {
            bytes[len] = if (r.get() == null) 1 else 9;
            len += 1;
        }
        fn internal(_: *u8) void {
            bytes[len] = 2;
            len += 1;
        }
    };
    for (0..2) |candidate| {
        const scope = try owner.childScope();
        var disposed = false;
        defer if (!disposed) scope.dispose();
        var tx = queue.Transaction.init(t.allocator);
        defer tx.deinit();
        queue.current = if (candidate == 1) &tx else null;
        defer queue.current = null;
        var root: ?*core.Node = null;
        var stray: ?*core.Node = null;
        defer if (root) |node| cx.freeNode(node);
        try v.emit(scope, cx, v.Sink.capture(&root, &stray), v.ref(ref, v.text(.{}, "ref")));
        try v.setupCleanup(scope, ref, Trace.user);
        var dummy: u8 = 0;
        try scope.onCleanup(u8, &dummy, Trace.internal);
        if (candidate == 1) try t.expect(ref.get() == null);
        queue.current = null;
        if (candidate == 1) try tx.run();
        try t.expect(ref.get() == root);
        Trace.len = 0;
        @import("hooks.zig").invalidateSubtreeHookState(root.?);
        scope.dispose();
        disposed = true;
        try t.expect(ref.get() == null);
        try t.expectEqualSlices(u8, &.{ 2, 9 }, Trace.bytes[0..Trace.len]);
    }
}

test "LP4 owner scope aliases reject before candidate construction" {
    defer reload.deinit();
    const a = try core.Cx.init(t.allocator, t.io);
    defer a.deinit();
    const b = try core.Cx.init(t.allocator, t.io);
    defer b.deinit();
    _ = try r3Mount(a, t.allocator);
    _ = try r3Mount(b, t.allocator);
    const a_scope = a.root_scope;
    const old_a = a.root;
    const old_b = b.root;
    a.root_scope = b.root_scope;
    defer a.root_scope = a_scope;
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, "RemountOriginal", "RemountChanged");
    defer t.allocator.free(bytes);
    const p = try r3Prepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try t.expectError(error.TemplateOwnerMismatch, p.apply(&.{ a, b }));
    try t.expectEqual(old_a, a.root);
    try t.expectEqual(old_b, b.root);
    try t.expect(!reload.needs_remount);
}

// Exhaust the public widget entry points as well as the generated fixture
// matrix. Hand-written builders have no candidate contract and must fail before
// their mount code can touch a Cx; generated ones continue into the full matrix.
test "LP4 every exported widget builder checks candidate admission" {
    const widgets = @import("components/mod.zig");
    const queue = @import("preview_mount.zig");
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try core.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    var tx = queue.Transaction.init(t.allocator);
    defer tx.deinit();
    queue.current = &tx;
    defer queue.current = null;
    var accepted: usize = 0;
    var rejected: usize = 0;
    inline for (@typeInfo(widgets).@"struct".decl_names) |name| {
        if (comptime name[0] >= 'A' and name[0] <= 'Z' and @typeInfo(@TypeOf(@field(widgets, name))) == .@"fn") {
            if (v.previewCheckBuilder(scope, @field(widgets, name))) |_| {
                accepted += 1;
            } else |err| {
                try t.expectEqual(error.TemplateCandidateSideEffects, err);
                rejected += 1;
            }
            try t.expectEqual(@as(usize, 0), cx.focus_manager.visibility_listeners.items.len);
            try t.expectEqual(@as(usize, 0), cx.press_watchers.items.len);
            try t.expectEqual(@as(usize, 0), cx.after_layout_hooks.items.len);
            try t.expectEqual(@as(usize, 0), tx.actions.items.len);
            try t.expect(cx.popover_portal_root == null);
        }
    }
    try t.expect(accepted > 0 and rejected > 0);
}

test "LP4 queued hooks tolerate target destruction before publication" {
    const hooks = @import("hooks.zig");
    const queue = @import("preview_mount.zig");
    for (0..2) |mode| {
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const scope = try core.Scope.init(t.allocator, null, cx.owner);
        defer scope.dispose();
        const node = try core.box(cx, .{}, .{});
        var tx = queue.Transaction.init(t.allocator);
        defer tx.deinit();
        queue.current = &tx;
        defer queue.current = null;
        if (mode == 1) _ = try queue.deferAction(scope, .mount, .{ .cx = cx, .node = node }, struct {
            fn destroy(c: anytype, _: *core.Scope) anyerror!void {
                c.cx.freeNode(c.node);
            }
        }.destroy);
        _ = try hooks.useHover(scope, node);
        _ = try hooks.useFocusState(scope, cx, node);
        try hooks.useFocusRing(scope, cx, node, .{});
        _ = try hooks.useHoverHighlight(scope, node, node, .background, .rgb(0, 0, 0), .rgb(255, 255, 255), .{});
        queue.current = null;
        if (mode == 0) cx.freeNode(node);
        try tx.run();
        try t.expect(cx.root == null);
        try t.expectEqual(@as(usize, 0), cx.focus_manager.visibility_listeners.items.len);
        // Scope is intentionally independent of the target node. Cleanup must
        // also be safe after the queue skipped every invalidated registration.
    }
}

const lp5_regions_path = "examples/template_probe/regions.yix";
fn mountRegions(cx: *core.Cx, allocator: std.mem.Allocator) !*v.ComponentInstance {
    cx.root_scope = try core.Scope.init(allocator, null, cx.owner);
    cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.Regions(.{}));
    return v.componentInstance(cx.root.?).?;
}
fn regionPrepare(allocator: std.mem.Allocator, bytes: []const u8) !*reload.Preparation {
    return reload.prepare(allocator, &.{.{ .path = lp5_regions_path, .source = bytes }});
}

test "LP4 LP5 active branch and keyed row structure retain controller and row state" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    fixture.regions.mounts = 0;
    fixture.regions.unmounts = 0;
    const parent = try mountRegions(cx, t.allocator);
    const row = v.componentInstance(findId(cx.root.?, "lp5.row.value").?.parent.?).?;
    const value: *@import("reactive.zig").Signal(u32) = @ptrCast(@alignCast(row.setup.signals.items[0]));
    value.set(83);
    const item_signal = parent.setup.signals.items[0];
    const original = fixture.regions_source;
    const b1 = try std.mem.replaceOwned(u8, t.allocator, original, "<text>RowOriginal</text>", "<row><text>RowChanged</text></row>");
    defer t.allocator.free(b1);
    const b2 = try std.mem.replaceOwned(u8, t.allocator, b1, "<text testId=\"lp5.if\">IfOriginal</text>", "<col><text testId=\"lp5.if\">IfChanged</text></col>");
    defer t.allocator.free(b2);
    const b = try std.mem.replaceOwned(u8, t.allocator, b2, "<text testId=\"lp5.match\">MatchOriginal</text>", "<box><text testId=\"lp5.match\">MatchChanged</text></box>");
    defer t.allocator.free(b);
    const nodes = cx.world.elements.count();
    const graph = cx.owner.graph.nodeCount();
    for (0..6) |iteration| {
        const p = try regionPrepare(t.allocator, if (iteration % 2 == 0) b else original);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        try t.expectEqual(@as(usize, 4), try p.apply(&.{cx}));
        try t.expectEqual(parent, v.componentInstance(cx.root.?).?);
        try t.expectEqual(item_signal, parent.setup.signals.items[0]);
        try t.expectEqual(row, v.componentInstance(findId(cx.root.?, "lp5.row.value").?.parent.?).?);
        try t.expectEqual(@as(u32, 83), value.peek());
        try t.expect(text(cx.root.?, "row 83"));
        try t.expectEqual(@as(usize, 2), fixture.regions.mounts);
        try t.expectEqual(@as(usize, 0), fixture.regions.unmounts);
        try t.expect(text(cx.root.?, if (iteration % 2 == 0) "RowChanged" else "RowOriginal"));
        if (iteration % 2 == 1) {
            try t.expectEqual(nodes, cx.world.elements.count());
            try t.expectEqual(graph, cx.owner.graph.nodeCount());
        }
    }
    // Existing For reconcile must still see the migrated row root through its
    // lease, and preserve item-key identity when data order changes.
    const items: *@import("reactive.zig").Signal([]const u32) = @ptrCast(@alignCast(item_signal));
    items.set(&.{ 2, 1, 3 });
    try t.expectEqual(@as(u32, 83), value.peek());
    try t.expectEqual(@as(usize, 3), fixture.regions.mounts);
    items.set(&.{});
    try t.expectEqual(@as(usize, 3), fixture.regions.unmounts);
}

test "LP4 LP5 controller key and dormant region edits use L3 before publication" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try mountRegions(cx, t.allocator);
    const old = cx.root;
    const cases = [_][2][]const u8{
        .{ "key={item}", "key={item + 1}" },
        .{ "if (shown)", "if (!shown)" },
        .{ "<text testId=\"lp5.if.else\">IfElse</text>", "<row><text>ChangedDormant</text></row>" },
        .{ ".b => <text testId=\"lp5.match.else\">MatchElse</text>", ".b => <text testId=\"lp5.match.else\">MatchElse</text>, else => <text>extra</text>" },
    };
    for (cases) |edit| {
        const bytes = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, edit[0], edit[1]);
        defer t.allocator.free(bytes);
        const p = try regionPrepare(t.allocator, bytes);
        defer p.deinit();
        try t.expect(p.result == .fallback);
        try t.expectEqual(old, cx.root);
        try t.expectEqual(@as(u64, 0), reload.generation);
    }
}

test "LP4 LP5 default and named slot bodies update without rerunning setup" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.Slots(.{}));
    const parent = v.componentInstance(cx.root.?).?;
    const signal: *@import("reactive.zig").Signal(u32) = @ptrCast(@alignCast(parent.setup.signals.items[0]));
    signal.set(67);
    const root = cx.root;
    const a_nodes = cx.world.elements.count();
    const a_graph = cx.owner.graph.nodeCount();
    const styled = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "style={S.A}", "style={S.B}");
    defer t.allocator.free(styled);
    const b1 = try std.mem.replaceOwned(u8, t.allocator, styled, "<text>DefaultOriginal</text>", "<row><text>DefaultChanged</text></row>");
    defer t.allocator.free(b1);
    const b = try std.mem.replaceOwned(u8, t.allocator, b1, "<text>HeaderOriginal</text>", "<col><text>HeaderChanged</text></col>");
    defer t.allocator.free(b);
    for (0..6) |iteration| {
        const p = try regionPrepare(t.allocator, if (iteration % 2 == 0) b else fixture.regions_source);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        try t.expectEqual(@as(usize, 2), try p.apply(&.{cx}));
        try t.expectEqual(root, cx.root);
        try t.expectEqual(@as(u32, 67), signal.peek());
        try t.expect(text(cx.root.?, "slot setup 67"));
        try t.expectEqual(@as(f32, if (iteration % 2 == 0) 17 else 3), findId(cx.root.?, "lp5.slot.body").?.style.gap);
        try t.expect(text(cx.root.?, if (iteration % 2 == 0) "DefaultChanged" else "DefaultOriginal"));
        try t.expect(text(cx.root.?, if (iteration % 2 == 0) "HeaderChanged" else "HeaderOriginal"));
        if (iteration % 2 == 1) {
            try t.expectEqual(a_nodes, cx.world.elements.count());
            try t.expectEqual(a_graph, cx.owner.graph.nodeCount());
        }
    }
}

test "LP4 LP5 relocation and region OOM preserve all old ownership before commit" {
    for (0..3) |mode| {
        const bytes = if (mode == 0)
            try std.mem.replaceOwned(u8, t.allocator, r3_source, "<text>RemountOriginal</text>\n        <Child ref={handle}/>", "<Child ref={handle}/>\n        <text>RemountOriginal</text>")
        else if (mode == 1)
            try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "<text>RowOriginal</text>", "<row><text>RowChanged</text></row>")
        else
            try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "<text>DefaultOriginal</text>", "<row><text>DefaultChanged</text></row>");
        defer t.allocator.free(bytes);
        var reached = false;
        for (0..1800) |offset| {
            defer reload.deinit();
            var failing = t.FailingAllocator.init(t.allocator, .{});
            const a = failing.allocator();
            const cx = try core.Cx.init(a, t.io);
            defer cx.deinit();
            const parent = if (mode == 0) try r3Mount(cx, a) else if (mode == 1) try mountRegions(cx, a) else blk: {
                cx.root_scope = try core.Scope.init(a, null, cx.owner);
                cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.Slots(.{}));
                break :blk v.componentInstance(cx.root.?).?;
            };
            const old = cx.root;
            const view_scope = parent.view_scope;
            const nodes = cx.world.elements.count();
            const graph = cx.owner.graph.nodeCount();
            const children = parent.view_scope.?.children.items.len;
            const ref = if (mode == 0) r3.parent_ref.?.get() else null;
            const ref_generation = if (mode == 0) r3.parent_ref.?.generation else 0;
            const child = if (mode == 0) v.componentInstance(findId(cx.root.?, "r3.child").?.parent.?).? else null;
            const child_parent = if (child) |i| i.setup.parent else null;
            const p = if (mode == 0) try r3Prepare(a, bytes) else try regionPrepare(a, bytes);
            defer if (!p.committed) p.deinit();
            try expectReady(p);
            failing.fail_index = failing.alloc_index + offset;
            if (p.apply(&.{cx})) |_| {
                reached = true;
                break;
            } else |err| {
                if (reload.needs_remount) {
                    try t.expect(p.committed);
                    continue;
                }
                try t.expectEqual(error.OutOfMemory, err);
                try t.expectEqual(old, cx.root);
                try t.expectEqual(view_scope, parent.view_scope);
                try t.expectEqual(nodes, cx.world.elements.count());
                try t.expectEqual(graph, cx.owner.graph.nodeCount());
                try t.expectEqual(children, parent.view_scope.?.children.items.len);
                try t.expectEqual(@as(u64, 0), reload.generation);
                if (mode == 0) {
                    try t.expectEqual(ref, r3.parent_ref.?.get());
                    try t.expectEqual(ref_generation, r3.parent_ref.?.generation);
                    try t.expectEqual(child_parent, child.?.setup.parent);
                    try t.expectEqual(ref, child.?.parts.root);
                }
            }
        }
        try t.expect(reached);
    }
}

test "LP4 LP5 two children and owners match by complete hole identity" {
    defer reload.deinit();
    const cx1 = try core.Cx.init(t.allocator, t.io);
    defer cx1.deinit();
    const cx2 = try core.Cx.init(t.allocator, t.io);
    var closed = false;
    defer if (!closed) cx2.deinit();
    var children: [2][2]*v.ComponentInstance = undefined;
    var signals: [2][2]*@import("reactive.zig").Signal(u32) = undefined;
    for ([_]*core.Cx{ cx1, cx2 }, 0..) |cx, owner| {
        cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
        cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.Moves(.{}));
        for ([_][]const u8{ "lp5.left", "lp5.right" }, 0..) |id, index| {
            const child = v.componentInstance(findId(cx.root.?, id).?.parent.?).?;
            children[owner][index] = child;
            signals[owner][index] = @ptrCast(@alignCast(child.setup.signals.items[0]));
            signals[owner][index].set(@intCast(10 + owner * 20 + index));
        }
    }
    const b = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "<Row id=\"lp5.left\" button=\"lp5.left.button\"/><text>MoveDivider</text><Row id=\"lp5.right\" button=\"lp5.right.button\"/>", "<row><Row id=\"lp5.right\" button=\"lp5.right.button\"/><box><Row id=\"lp5.left\" button=\"lp5.left.button\"/></box></row><text>MoveDivider</text>");
    defer t.allocator.free(b);
    for (0..6) |iteration| {
        const p = try regionPrepare(t.allocator, if (iteration % 2 == 0) b else fixture.regions_source);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        const updated = p.apply(&.{ cx1, cx2 }) catch |err| {
            std.debug.print("LP5 identity reconciliation failed: {s}\n", .{@errorName(err)});
            try t.expect(false);
            return;
        };
        try t.expectEqual(@as(usize, 2), updated);
        for ([_]*core.Cx{ cx1, cx2 }, 0..) |cx, owner| for ([_][]const u8{ "lp5.left", "lp5.right" }, 0..) |id, index| {
            try t.expectEqual(children[owner][index], v.componentInstance(findId(cx.root.?, id).?.parent.?).?);
            try t.expectEqual(@as(u32, @intCast(10 + owner * 20 + index)), signals[owner][index].peek());
        };
    }
    cx2.deinit();
    closed = true;
    const p = try regionPrepare(t.allocator, b);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    try t.expectEqual(@as(usize, 1), try p.apply(&.{cx1}));
    try t.expectEqual(@as(u32, 10), signals[0][0].peek());
}

test "LP4 LP5 ambiguous instances keys and slot shape reject before mutation" {
    {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
        cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.Ambiguous(.{}));
        const b = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "AmbiguousOriginal", "AmbiguousChanged");
        defer t.allocator.free(b);
        const p = try regionPrepare(t.allocator, b);
        defer p.deinit();
        try t.expect(p.result == .fallback);
        try t.expectEqualStrings("TemplateAmbiguousHole", p.result.fallback.reason);
    }
    {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const parent = try mountRegions(cx, t.allocator);
        const items: *@import("reactive.zig").Signal([]const u32) = @ptrCast(@alignCast(parent.setup.signals.items[0]));
        items.set(&.{ 1, 1 });
        const b = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "RowOriginal", "RowChanged");
        defer t.allocator.free(b);
        const p = try regionPrepare(t.allocator, b);
        defer p.deinit();
        try expectReady(p);
        const old = cx.root;
        try t.expectError(error.TemplateAmbiguousKey, p.apply(&.{cx}));
        try t.expectEqual(old, cx.root);
        try t.expect(!reload.needs_remount);
    }
    {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
        cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.Slots(.{}));
        const cases = [_][2][]const u8{
            .{ "DefaultOriginal", "value {value + 1}" },
            .{ "header={<box><text>HeaderOriginal</text></box>}", "header={<box><text>HeaderOriginal</text><text>extra</text></box>} footer={<text>new slot</text>}" },
        };
        for (cases) |edit| {
            const b = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, edit[0], edit[1]);
            defer t.allocator.free(b);
            const p = try regionPrepare(t.allocator, b);
            defer p.deinit();
            try t.expect(p.result == .fallback);
        }
    }
}

test "LP4 LP5 moved child root replay keeps ref and lease on later child edits" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = try r3Mount(cx, t.allocator);
    const child = v.componentInstance(findId(cx.root.?, "r3.child").?.parent.?).?;
    const value: *@import("reactive.zig").Signal(u32) = @ptrCast(@alignCast(child.setup.signals.items[0]));
    value.set(91);
    const ref = r3.parent_ref.?;
    const moved = try std.mem.replaceOwned(u8, t.allocator, r3_source, "<text>RemountOriginal</text>\n        <Child ref={handle}/>", "<Child ref={handle}/>\n        <text>RemountOriginal</text>");
    defer t.allocator.free(moved);
    const p1 = try r3Prepare(t.allocator, moved);
    defer if (!p1.committed) p1.deinit();
    try expectReady(p1);
    _ = try p1.apply(&.{cx});
    const first_root = child.parts.root;
    const edited = try std.mem.replaceOwned(u8, t.allocator, moved, "child {value}", "edited child {value}");
    defer t.allocator.free(edited);
    const p2 = try r3Prepare(t.allocator, edited);
    defer if (!p2.committed) p2.deinit();
    try expectReady(p2);
    _ = try p2.apply(&.{cx});
    try t.expectEqual(@as(u32, 91), value.peek());
    try t.expect(first_root != child.parts.root);
    try t.expectEqual(child.parts.root, ref.get());
    try t.expect(text(cx.root.?, "edited child 91"));
    // A third parent move must consume the lease's new root, never its retired
    // snapshot or the attachment scope retired during the child refresh.
    const back = try std.mem.replaceOwned(u8, t.allocator, r3_source, "child {value}", "edited child {value}");
    defer t.allocator.free(back);
    const p3 = try r3Prepare(t.allocator, back);
    defer if (!p3.committed) p3.deinit();
    try expectReady(p3);
    _ = try p3.apply(&.{cx});
    try t.expectEqual(child, v.componentInstance(findId(cx.root.?, "r3.child").?.parent.?).?);
    try t.expectEqual(child.parts.root, ref.get());
    try t.expectEqual(@as(u32, 91), value.peek());
}

test "LP4 LP5 selected nondefault branches retain selection and later switch correctly" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const parent = try mountRegions(cx, t.allocator);
    const shown: *@import("reactive.zig").Signal(bool) = @ptrCast(@alignCast(parent.setup.signals.items[1]));
    const mode: *@import("reactive.zig").Signal(fixture.regions.Mode) = @ptrCast(@alignCast(parent.setup.signals.items[2]));
    shown.set(false);
    mode.set(.b);
    const b1 = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "IfElse", "IfElseChanged");
    defer t.allocator.free(b1);
    const b = try std.mem.replaceOwned(u8, t.allocator, b1, "MatchElse", "MatchElseChanged");
    defer t.allocator.free(b);
    const p = try regionPrepare(t.allocator, b);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    _ = try p.apply(&.{cx});
    try t.expect(!shown.peek());
    try t.expectEqual(fixture.regions.Mode.b, mode.peek());
    try t.expect(text(cx.root.?, "IfElseChanged") and text(cx.root.?, "MatchElseChanged"));
    try t.expect(!text(cx.root.?, "IfOriginal") and !text(cx.root.?, "MatchOriginal"));
    shown.set(true);
    mode.set(.a);
    try t.expect(text(cx.root.?, "IfOriginal") and text(cx.root.?, "MatchOriginal"));
    shown.set(false);
    mode.set(.b);
    try t.expect(text(cx.root.?, "IfElseChanged") and text(cx.root.?, "MatchElseChanged"));
    const moved = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "return <col>", "return <col><text>new sibling</text>");
    defer t.allocator.free(moved);
    const unsupported = try regionPrepare(t.allocator, moved);
    defer unsupported.deinit();
    try t.expect(unsupported.result == .fallback);
    try t.expectEqualStrings("TemplateChildRelocation", unsupported.result.fallback.reason);
}

test "LP4 LP5 imperative attachment replay rejects without shared writes" {
    const Child = struct {
        fn builder(scope: *core.Scope, cx: *core.Cx) anyerror!*core.Node {
            return v.renderComponentView(scope, cx, .{}, struct {
                fn render(_: @TypeOf(.{}), vs: *core.Scope, c: *core.Cx, sink: v.Sink) anyerror!*core.Node {
                    try v.emit(vs, c, sink, v.box(.{}, .{}));
                    return sink.root.?.*.?;
                }
            }.render);
        }
    };
    const Touch = struct {
        fn apply(counter: *usize, _: *core.Node) void {
            counter.* += 1;
        }
    };
    {
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const scope = try core.Scope.init(t.allocator, null, cx.owner);
        defer scope.dispose();
        cx.root = try v.render(scope, cx, v.box(.{}, .{}));
        var writes: usize = 0;
        const node = try v.append(scope, cx, cx.root.?, v.setup(v.component(Child.builder, {}), &writes, Touch.apply));
        const instance = v.componentInstance(node).?;
        const before = writes;
        const old = instance.parts.root;
        const nodes = cx.world.elements.count();
        try t.expectError(error.ViewTransactionUnsupported, instance.prepareView());
        try t.expectEqual(old, instance.parts.root);
        try t.expectEqual(nodes, cx.world.elements.count());
        try t.expectEqual(before, writes);
    }
}

test "LP4 LP5 scope migration preserves distinct allocator provenance" {
    defer reload.deinit();
    var scope_memory = core.CountingAllocator{ .parent = t.allocator };
    var node_memory = core.CountingAllocator{ .parent = t.allocator };
    {
        const cx = try core.Cx.init(node_memory.allocator(), t.io);
        defer cx.deinit();
        cx.root_scope = try core.Scope.init(scope_memory.allocator(), null, cx.owner);
        cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.AllocatorMoves(.{}));
        const b = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "<Row id=\"alloc.left\"/><text>alloc divider</text><Row id=\"alloc.right\"/>", "<Row id=\"alloc.right\"/><text>alloc divider</text><Row id=\"alloc.left\"/>");
        defer t.allocator.free(b);
        for (0..6) |iteration| {
            const p = try regionPrepare(t.allocator, if (iteration % 2 == 0) b else fixture.regions_source);
            defer if (!p.committed) p.deinit();
            try expectReady(p);
            _ = try p.apply(&.{cx});
        }
    }
    try t.expectEqual(@as(usize, 0), scope_memory.live_bytes);
    try t.expectEqual(@as(usize, 0), node_memory.live_bytes);
}

test "LP4 LP5 relocation callback reentry and retained child destruction require remount" {
    const bytes = try std.mem.replaceOwned(u8, t.allocator, r3_source, "<text>RemountOriginal</text>\n        <Child ref={handle}/>", "<Child ref={handle}/>\n        <text>RemountOriginal</text>");
    defer t.allocator.free(bytes);
    for (0..2) |mode| {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const parent = try r3Mount(cx, t.allocator);
        count(parent).set(73);
        const p = try r3Prepare(t.allocator, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        r3_reentry = p;
        r3_close_cx = cx;
        if (mode == 0) {
            r3.unmounted_hook = struct {
                fn call() void {
                    r3Reenter() catch unreachable;
                }
            }.call;
        } else r3.mounted_hook = r3DisposeChildSetup;
        defer {
            r3.mounted_hook = null;
            r3.unmounted_hook = null;
        }
        try t.expectError(if (mode == 0) error.TemplateReloadReentry else error.ViewMountCancelled, p.apply(&.{cx}));
        try t.expect(reload.needs_remount and p.committed);
        try t.expectEqual(@as(u32, 73), count(parent).peek());
        if (mode == 1) try t.expect(cx.root == null);
    }
}

test "LP4 LP5 stored nested controller rejects derived getters before evaluation" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    const signal = try cx.root_scope.?.createSignal(bool, true);
    const Reader = struct {
        var calls: usize = 0;
        fn read(values: anytype) bool {
            calls += 1;
            return values[0].get();
        }
    };
    Reader.calls = 0;
    const reactive = @import("reactive.zig");
    cx.root = try v.render(cx.root_scope.?, cx, fixture.regions.NestedDerived(.{ .bad = reactive.toSource(reactive.derive(bool, .{signal}, Reader.read)) }));
    const before = Reader.calls;
    const old = cx.root;
    const b = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "NestedOriginal", "NestedChanged");
    defer t.allocator.free(b);
    const p = try regionPrepare(t.allocator, b);
    defer p.deinit();
    try t.expect(p.result == .fallback);
    try t.expectEqualStrings("TemplateNestedController", p.result.fallback.reason);
    // The direct lifecycle API independently guards stored controller values;
    // even a caller bypassing classification must not execute the getter.
    var instances: std.ArrayList(*v.ComponentInstance) = .empty;
    defer instances.deinit(t.allocator);
    try v.collectTemplateInstances(cx.root_scope.?, t.allocator, &instances);
    var exercised = false;
    for (instances.items) |instance| {
        const entry = instance.preview_template orelse continue;
        if (!std.mem.eql(u8, entry.component, "NestedDerived/keyword_if:1/branch:0")) continue;
        if (instance.prepareView()) |candidate| {
            var prepared = candidate;
            prepared.cancel();
            try t.expect(false);
        } else |err| try t.expectEqual(error.TemplateCandidateSideEffects, err);
        exercised = true;
    }
    try t.expect(exercised);
    try t.expectEqual(before, Reader.calls);
    try t.expectEqual(old, cx.root);
    try t.expect(!reload.needs_remount);
}

test "LP4 LP5 retained captures cannot borrow a retiring view ref" {
    const Harness = struct {
        var original_ref: ?*v.Ref(*core.Node) = null;
        fn render(ctx: anytype, scope: *core.Scope, cx: *core.Cx, sink: v.Sink) anyerror!*core.Node {
            const handle = try v.createRef(scope, *core.Node);
            if (!ctx.move.peek()) original_ref = handle;
            const value = v.templateSite(.{ .path = "capture", .receiver = "col", .tokens = "col" }, .{}, v.col(.{}, .{
                v.templateSite(.{ .path = "capture", .receiver = "Row", .tokens = "Row ref" }, .{}, v.ref(handle, fixture.regions.Row(.{}))),
            }));
            const T = @TypeOf(value);
            var ops = v.template.Schema(T).instructions;
            if (ctx.move.peek()) ops[1].relocate = true;
            try v.template.build(.runtime_template, T, &ops, &value, scope, cx, sink);
            return sink.root.?.*.?;
        }
    };
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    const setup_scope = try cx.root_scope.?.childScope();
    const move = try setup_scope.createSignal(bool, false);
    cx.root = try v.renderComponentView(setup_scope, cx, .{ .move = move }, Harness.render);
    const parent = v.componentInstance(cx.root.?).?;
    const old = cx.root;
    const old_ref = Harness.original_ref.?;
    const old_value = old_ref.get();
    const nodes = cx.world.elements.count();
    move.set(true);
    if (parent.prepareView()) |candidate| {
        var prepared = candidate;
        prepared.cancel();
        try t.expect(false);
    } else |err| try t.expectEqual(error.TemplateRetainedCaptureLifetime, err);
    try t.expectEqual(old, cx.root);
    try t.expectEqual(old_value, old_ref.get());
    try t.expectEqual(nodes, cx.world.elements.count());
    try t.expectEqual(.ready, parent.state);
}

test "LP4 LP5 retained captures reject borrowed view storage recursively" {
    const Harness = struct {
        var original_freed = false;
        const Storage = struct {
            bytes: []u8,
            original: bool,
            fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                if (self.original) original_freed = true;
                allocator.free(self.bytes);
                allocator.destroy(self);
            }
        };
        fn render(ctx: anytype, scope: *core.Scope, cx: *core.Cx, sink: v.Sink) anyerror!*core.Node {
            const storage = try scope.allocator.create(Storage);
            storage.* = .{ .bytes = scope.allocator.dupe(u8, "borrowed") catch |err| {
                scope.allocator.destroy(storage);
                return err;
            }, .original = !ctx.move.peek() };
            try scope.adoptResource(storage, Storage.destroy);
            const value = v.templateSite(.{ .path = "borrow", .receiver = "col", .tokens = "col" }, .{}, v.col(.{}, .{
                v.templateSite(.{ .module = "borrowed-fixture", .path = "borrow", .receiver = "Row", .tokens = "Row id borrowed", .attributes = &.{.{ .name = "id", .tokens = "\"borrowed\"", .kind = .property, .literal = .{ .text = "borrowed" } }} }, .{}, fixture.regions.Row(.{ .id = storage.bytes })),
            }));
            const T = @TypeOf(value);
            var ops = v.template.Schema(T).instructions;
            if (ctx.move.peek()) ops[1].relocate = true;
            try v.template.build(.runtime_template, T, &ops, &value, scope, cx, sink);
            return sink.root.?.*.?;
        }
    };
    Harness.original_freed = false;
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root_scope = try core.Scope.init(t.allocator, null, cx.owner);
    const setup_scope = try cx.root_scope.?.childScope();
    const move = try setup_scope.createSignal(bool, false);
    cx.root = try v.renderComponentView(setup_scope, cx, .{ .move = move }, Harness.render);
    const parent = v.componentInstance(cx.root.?).?;
    const old = cx.root;
    const nodes = cx.world.elements.count();
    move.set(true);
    if (parent.prepareView()) |candidate| {
        var prepared = candidate;
        prepared.cancel();
        try t.expect(false);
    } else |err| try t.expectEqual(error.TemplateRetainedCaptureLifetime, err);
    try t.expect(!Harness.original_freed);
    try t.expectEqual(old, cx.root);
    try t.expectEqual(nodes, cx.world.elements.count());
    try t.expect(findId(old.?, "borrowed") != null);
    const bytes = try t.allocator.dupe(u8, "borrowed");
    defer t.allocator.free(bytes);
    try t.expect(!v.template.retainedValueSafe(@as([]const u8, bytes), setup_scope));
    try t.expect(!v.template.retainedValueSafe(@as(?[]const u8, bytes), setup_scope));
    try t.expect(!v.template.retainedValueSafe([_][]const u8{bytes}, setup_scope));
    try t.expect(!v.template.retainedValueSafe(@as(*const [8]u8, @ptrCast(bytes.ptr)), setup_scope));
    const sentinel = try t.allocator.allocSentinel(u8, 0, 0);
    defer t.allocator.free(sentinel);
    try t.expect(!v.template.retainedValueSafe(sentinel, setup_scope));
    try t.expect(v.template.retainedValueSafe([_]u8{ 1, 2 }, setup_scope));
}

fn mountExternalPortal(cx: *core.Cx, a: std.mem.Allocator) !*v.ComponentInstance {
    cx.root_scope = try core.Scope.init(a, null, cx.owner);
    cx.root = try v.render(cx.root_scope.?, cx, v.box(.{}, .{}));
    try v.mount(cx.root_scope.?, cx, cx.root.?, .{
        v.portal(v.text(.{}, "before portal")),
        v.portal(fixture.regions.Row(.{ .id = "external.portal.value", .button = "external.portal.button" })),
        v.portal(v.text(.{}, "after portal")),
    });
    return v.componentInstance(cx.popover_portal_root.?.children.items[1]).?;
}

fn portalEdit(a: std.mem.Allocator) ![]u8 {
    return std.mem.replaceOwned(u8, a, fixture.regions_source, "row {value}", "portal {value}");
}

test "LP4 LP5 external Portal leases follow new roots across owners and A B A" {
    defer reload.deinit();
    const a = try core.Cx.init(t.allocator, t.io);
    defer a.deinit();
    const b = try core.Cx.init(t.allocator, t.io);
    var closed = false;
    defer if (!closed) b.deinit();
    const owners = [_]*core.Cx{ a, b };
    var children: [2]*v.ComponentInstance = undefined;
    var signals: [2]*@import("reactive.zig").Signal(u32) = undefined;
    var leases: [2]*v.RootLease = undefined;
    for (owners, 0..) |cx, index| {
        children[index] = try mountExternalPortal(cx, t.allocator);
        signals[index] = @ptrCast(@alignCast(children[index].setup.signals.items[0]));
        signals[index].set(@intCast(70 + index));
        try t.expect(children[index].leases != null);
        leases[index] = children[index].leases.?;
    }
    const bytes = try portalEdit(t.allocator);
    defer t.allocator.free(bytes);
    for (0..6) |round| {
        const p = try regionPrepare(t.allocator, if (round % 2 == 0) bytes else fixture.regions_source);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        const old = [_]*core.Node{ children[0].parts.root.?, children[1].parts.root.? };
        try t.expectEqual(@as(usize, 2), try p.apply(&owners));
        for (owners, 0..) |cx, index| {
            const portal = cx.popover_portal_root.?;
            try t.expectEqual(@as(usize, 3), portal.children.items.len);
            try t.expect(text(portal.children.items[0], "before portal"));
            try t.expect(text(portal.children.items[2], "after portal"));
            const root = portal.children.items[1];
            try t.expect(root != old[index]);
            try t.expectEqual(children[index], v.componentInstance(root));
            try t.expectEqual(root, leases[index].resolve());
            try t.expectEqual(root, leases[index].retainedNode());
            try t.expectEqual(signals[index], @as(*@import("reactive.zig").Signal(u32), @ptrCast(@alignCast(children[index].setup.signals.items[0]))));
            try t.expectEqual(@as(u32, @intCast(70 + index)), signals[index].peek());
            try t.expect(text(root, if (round % 2 == 0) (if (index == 0) "portal 70" else "portal 71") else (if (index == 0) "row 70" else "row 71")));
        }
    }
    // One owner closes. Its host lease cannot affect the survivor or a recreated owner.
    b.deinit();
    closed = true;
    const c = try core.Cx.init(t.allocator, t.io);
    defer c.deinit();
    const recreated = try mountExternalPortal(c, t.allocator);
    const p = try regionPrepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    try t.expectEqual(@as(usize, 2), try p.apply(&.{ a, c }));
    try t.expectEqual(children[0].parts.root, leases[0].resolve());
    try t.expect(text(recreated.parts.root.?, "portal 5"));
}

test "LP4 LP5 external Portal candidate OOM and cancellation preserve live leases" {
    const bytes = try portalEdit(t.allocator);
    defer t.allocator.free(bytes);
    var reached = false;
    for (0..1000) |offset| {
        defer reload.deinit();
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const a = failing.allocator();
        const cx = try core.Cx.init(a, t.io);
        defer cx.deinit();
        const child = try mountExternalPortal(cx, a);
        try t.expect(child.leases != null);
        const lease = child.leases.?;
        const old = child.parts.root.?;
        const nodes = cx.world.elements.count();
        const graph = cx.owner.graph.nodeCount();
        const portal = cx.popover_portal_root.?;
        // Direct cancellation must not mutate the host alias either.
        var candidate = try child.prepareView();
        try t.expectEqual(old, lease.resolve());
        candidate.cancel();
        try t.expectEqual(old, lease.resolve());
        try t.expectEqual(nodes, cx.world.elements.count());
        const p = try regionPrepare(a, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        failing.fail_index = failing.alloc_index + offset;
        if (p.apply(&.{cx})) |_| {
            try t.expect(child.parts.root != old);
            try t.expectEqual(child.parts.root, lease.resolve());
            reached = true;
            break;
        } else |err| {
            if (reload.needs_remount) {
                try t.expect(p.committed);
                continue;
            }
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(old, lease.resolve());
            try t.expectEqual(old, child.parts.root);
            try t.expectEqual(old, portal.children.items[1]);
            try t.expectEqual(@as(usize, 3), portal.children.items.len);
            try t.expectEqual(nodes, cx.world.elements.count());
            try t.expectEqual(graph, cx.owner.graph.nodeCount());
            try t.expectEqual(@as(u64, 0), reload.generation);
        }
    }
    try t.expect(reached);
}

test "LP4 LP5 external Portal active input and callback reentry reject safely" {
    const bytes = try portalEdit(t.allocator);
    defer t.allocator.free(bytes);
    for (0..2) |mode| {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const child = try mountExternalPortal(cx, t.allocator);
        const old = child.parts.root.?;
        try t.expect(child.leases != null);
        const lease = child.leases.?;
        const p = try regionPrepare(t.allocator, bytes);
        defer if (!p.committed) p.deinit();
        try expectReady(p);
        if (mode == 0) {
            cx.focused_node = old;
            try t.expectError(error.ViewTransactionUnsupported, p.apply(&.{cx}));
            cx.focused_node = null;
        } else {
            cx.owner.beginReactiveCallback();
            try t.expectError(error.ViewRebuildNeedsSafePoint, p.apply(&.{cx}));
            cx.owner.endReactiveCallback();
        }
        try t.expectEqual(old, lease.resolve());
        try t.expectEqual(@as(u64, 0), reload.generation);
        try t.expect(!p.committed);
    }
}

// A branch dispatcher and a receiver factory are compiled Zig functions, not
// template data. These edits must reach the real classifier and remain L3 until
// a typed dispatch/factory catalog exists; accepting syntax is not compilation.
const unsupported_lp5_edits = [_][2][]const u8{
    .{ ".a => <text>CaseA</text>, else => <text>CaseDefault</text>", ".a => <text>CaseA</text>, .b => <text>CaseAddedB</text>, else => <text>CaseDefault</text>" },
    .{ ".a => <text>CaseA</text>, else => <text>CaseDefault</text>", "else => <text>CaseDefault</text>" },
    .{ "{if (shown) <text>SingleBranch</text>}", "{if (shown) <text>SingleBranch</text> else <text>AddedElse</text>}" },
    .{ " else <text testId=\"lp5.if.else\">IfElse</text>", "" },
    .{ "{if (shown) <box><text testId=\"lp5.if\">IfOriginal</text></box> else <text testId=\"lp5.if.else\">IfElse</text>}", "{if (shown) <box><text testId=\"lp5.if\">IfOriginal</text></box> else if (shown) <text>new branch</text> else <text testId=\"lp5.if.else\">IfElse</text>}" },
    .{ ", .b => <text testId=\"lp5.match.else\">MatchElse</text>", "" },
    .{ ".b => <text testId=\"lp5.match.else\">MatchElse</text>", ".b => <text testId=\"lp5.match.else\">MatchElse</text>, else => <text>new case</text>" },
    .{ "<text>MoveDivider</text>", "<text>MoveDivider</text><Row id=\"new.receiver\"/>" },
    .{ "<text>MoveDivider</text>", "<text>MoveDivider</text><SlotFrame header={<text>new header</text>}><text>new receiver</text></SlotFrame>" },
};

fn mountFallbackFixture(cx: *core.Cx, a: std.mem.Allocator) !*v.ComponentInstance {
    const regions = try mountRegions(cx, a);
    _ = try v.append(cx.root_scope.?, cx, cx.root.?, fixture.regions.Moves(.{}));
    _ = try v.append(cx.root_scope.?, cx, cx.root.?, fixture.regions.Branchless(.{}));
    _ = try v.append(cx.root_scope.?, cx, cx.root.?, fixture.regions.Cases(.{}));
    return regions;
}

test "LP4 LP5 branch set and new receiver L3 preserve both owners across repeated attempts" {
    defer reload.deinit();
    const a = try core.Cx.init(t.allocator, t.io);
    defer a.deinit();
    const b = try core.Cx.init(t.allocator, t.io);
    defer b.deinit();
    const pa = try mountFallbackFixture(a, t.allocator);
    const pb = try mountFallbackFixture(b, t.allocator);
    const old_a = a.root;
    const old_b = b.root;
    // Select the branches being deleted, not only the default initial ones.
    const shown: *@import("reactive.zig").Signal(bool) = @ptrCast(@alignCast(pa.setup.signals.items[1]));
    const mode: *@import("reactive.zig").Signal(fixture.regions.Mode) = @ptrCast(@alignCast(pb.setup.signals.items[2]));
    shown.set(false);
    mode.set(.b);
    const nodes_a = a.world.elements.count();
    const nodes_b = b.world.elements.count();
    const graph_a = a.owner.graph.nodeCount();
    const graph_b = b.owner.graph.nodeCount();
    for (unsupported_lp5_edits) |edit| {
        const bytes = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, edit[0], edit[1]);
        defer t.allocator.free(bytes);
        try t.expect(!std.mem.eql(u8, bytes, fixture.regions_source));
        for (0..3) |_| {
            const p = try regionPrepare(t.allocator, bytes);
            defer p.deinit();
            try t.expect(p.result == .fallback);
            try t.expect(!p.committed);
            try t.expectEqual(@as(u64, 0), reload.generation);
            try t.expectEqual(old_a, a.root);
            try t.expectEqual(old_b, b.root);
            // Restoring A is accepted without rebuilding any instance.
            const back = try regionPrepare(t.allocator, fixture.regions_source);
            defer if (!back.committed) back.deinit();
            try expectReady(back);
            // No apply here: successful no-op publication would consume a generation.
        }
    }
    try t.expect(!shown.peek());
    try t.expectEqual(fixture.regions.Mode.b, mode.peek());
    try t.expectEqual(nodes_a, a.world.elements.count());
    try t.expectEqual(nodes_b, b.world.elements.count());
    try t.expectEqual(graph_a, a.owner.graph.nodeCount());
    try t.expectEqual(graph_b, b.owner.graph.nodeCount());
    // A supported edit still publishes after all failures, preserving selected branches.
    const bytes = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, "IfElse", "IfElseRecovered");
    defer t.allocator.free(bytes);
    const p = try regionPrepare(t.allocator, bytes);
    defer if (!p.committed) p.deinit();
    try expectReady(p);
    _ = try p.apply(&.{ a, b });
    try t.expect(text(a.root.?, "IfElseRecovered"));
    try t.expectEqual(pa, v.componentInstance(a.root.?).?);
}

test "LP4 LP5 branch set and new receiver classifier OOM never execute factories" {
    for (unsupported_lp5_edits) |edit| {
        const bytes = try std.mem.replaceOwned(u8, t.allocator, fixture.regions_source, edit[0], edit[1]);
        defer t.allocator.free(bytes);
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        _ = try mountFallbackFixture(cx, t.allocator);
        const old = cx.root;
        const nodes = cx.world.elements.count();
        const graph = cx.owner.graph.nodeCount();
        const mounts = fixture.regions.mounts;
        const unmounts = fixture.regions.unmounts;
        var reached = false;
        for (0..12000) |offset| {
            var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = offset });
            const p = regionPrepare(failing.allocator(), bytes) catch |err| {
                try t.expectEqual(error.OutOfMemory, err);
                try t.expectEqual(old, cx.root);
                try t.expectEqual(@as(u64, 0), reload.generation);
                continue;
            };
            defer p.deinit();
            try t.expect(p.result == .fallback);
            reached = true;
            break;
        }
        try t.expect(reached);
        // The parser/classifier can also be called reentrantly; it must reject
        // these unsupported edits without setup, lifecycle or shared writes.
        cx.owner.beginReactiveCallback();
        const p = try regionPrepare(t.allocator, bytes);
        try t.expect(p.result == .fallback);
        p.deinit();
        cx.owner.endReactiveCallback();
        try t.expectEqual(old, cx.root);
        try t.expectEqual(nodes, cx.world.elements.count());
        try t.expectEqual(graph, cx.owner.graph.nodeCount());
        try t.expectEqual(mounts, fixture.regions.mounts);
        try t.expectEqual(unmounts, fixture.regions.unmounts);
    }
}

test "LP4 LP5 external Portal queued callbacks retain lease ownership on child destruction" {
    const Callback = struct {
        child: *v.ComponentInstance,
        destroy: bool,
        seen: *bool,
        fn run(self: @This(), _: *core.Scope) !void {
            self.seen.* = true;
            // This is a real queued callback, after root publication. A nested
            // preparation cannot run while the outer owner callback is active.
            try t.expectError(error.ViewRebuildNeedsSafePoint, self.child.prepareView());
            if (self.destroy) self.child.setup.dispose();
        }
    };
    for (0..2) |mode| {
        defer reload.deinit();
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const child = try mountExternalPortal(cx, t.allocator);
        try t.expect(child.leases != null);
        const lease = child.leases.?;
        var candidate = try child.prepareView();
        defer candidate.cancel();
        var seen = false;
        reload.mount_effects.current = candidate.transaction;
        defer reload.mount_effects.current = null;
        try t.expect(try reload.mount_effects.deferAction(candidate.scope, .mount, Callback{ .child = child, .destroy = mode == 1, .seen = &seen }, Callback.run));
        reload.mount_effects.current = null;
        cx.owner.beginReactiveCallback();
        if (mode == 0) {
            try candidate.commit();
            try t.expectEqual(child.parts.root, lease.resolve());
        } else {
            try t.expectError(error.ViewMountCancelled, candidate.commit());
            try t.expectEqual(.needs_remount, child.state);
        }
        cx.owner.endReactiveCallback();
        try t.expect(seen);
        if (mode == 1) {
            try t.expect(lease.resolve() == null);
            // The independent host lease retains cleanup ownership even though
            // component setup is already gone. Portal teardown frees this node.
            try t.expect(lease.retainedNode() != null);
        }
    }
}

test "LP4 LP5 external Portal initial mount OOM releases partial host leases" {
    var reached = false;
    for (0..1200) |offset| {
        defer reload.deinit();
        var memory = core.CountingAllocator{ .parent = t.allocator };
        var failing = t.FailingAllocator.init(memory.allocator(), .{});
        {
            const cx = try core.Cx.init(failing.allocator(), t.io);
            defer cx.deinit();
            failing.fail_index = failing.alloc_index + offset;
            if (mountExternalPortal(cx, failing.allocator())) |child| {
                try t.expect(child.leases != null);
                try t.expectEqual(child.parts.root, child.leases.?.resolve());
                reached = true;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
            }
        }
        try t.expectEqual(@as(usize, 0), memory.live_bytes);
        if (reached) break;
    }
    try t.expect(reached);
}
