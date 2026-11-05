//! Sole entry point for components consuming `Source(T)` (docs/SIGNAL_API_DESIGN.md 4.7).
//!
//! - static value: applied once immediately, no effect, no allocation (zero-cost static).
//! - dynamic value: creates an effect, applies when the source changes; apply runs
//!   untracked, so internal reads don't become this binding's dependencies.
//! - equality suppression: skip apply if the new value equals the last applied one
//!   (`Derived` lacks memo's equality suppression). Slice types record a content hash,
//!   not the slice: owning text realloc frees the old buffer.
//! - borrow check (Debug): on creation, check the source's leaf signals belong to the
//!   component scope's ancestor chain.
const std = @import("std");
const core = @import("core.zig");
const reactive = @import("reactive.zig");
const Scope = reactive.Scope;
const Node = core.Node;
const eq = @import("reactive/eq.zig");
const hooks = @import("hooks.zig");
const eqlValue = eq.eqlValue;

/// bind `src` to `apply(ctx, value)`. `src` accepts `Source(T)` / `*Signal(T)` / `*Memo(T)` /
/// derived values. `ctx` saved by value, must remain valid during scope lifetime.
///
/// `apply` may return an error union (fallible, all-or-nothing writes such as
/// `setStyleInlineFallible`): the initial application is part of `bind` and its error is
/// returned (the mount fails); a failed later update is logged, leaves the target unchanged and
/// is retried by the next change of `src`, even to an equal value.
pub fn bind(scope: *Scope, src: anytype, ctx: anytype, comptime apply: anytype) !void {
    const S = @TypeOf(reactive.toSource(src));
    const T = S.Value;
    const Ctx = @TypeOf(ctx);
    const s = reactive.toSource(src);
    const fallible = comptime @typeInfo(@typeInfo(@TypeOf(apply)).@"fn".return_type.?) == .error_union;
    if (s == .value) {
        if (fallible) try apply(ctx, s.value) else apply(ctx, s.value);
        return;
    }
    reactive.checkBorrow(scope, s);

    const Last = eq.EqKey(T);

    const State = struct {
        src: S,
        ctx: Ctx,
        last: Last = undefined,
        has_last: bool = false,

        const Self = @This();

        fn run(st: *Self) if (fallible) anyerror!void else void {
            const v = st.src.get();
            const k = eq.eqKey(T, v);
            if (st.has_last and eqlValue(Last, st.last, k)) return;
            // recorded before applying: a rerun the apply itself triggers sees it as applied
            const prev: struct { Last, bool } = .{ st.last, st.has_last };
            st.last = k;
            st.has_last = true;
            const result = ownerOf(st.src).untrack(struct {
                fn call(args: struct { Ctx, T }) @typeInfo(@TypeOf(apply)).@"fn".return_type.? {
                    return apply(args[0], args[1]);
                }
            }.call, .{ st.ctx, v });
            // a failed value does not count as applied: the next change applies it even if equal
            if (fallible) result catch |err| {
                st.last, st.has_last = prev;
                return err;
            };
        }

        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            allocator.destroy(@as(*Self, @ptrCast(@alignCast(ptr))));
        }
    };
    const st = try scope.allocator.create(State);
    st.* = .{ .src = s, .ctx = ctx };
    try scope.adoptResource(st, State.destroy);
    try scope.createEffect(st, State.run);
}

/// text content binding: node holds content copy (`setTextContent`).
pub fn bindText(cx: *core.Cx, scope: *Scope, src: anytype, node: *Node) !void {
    try bindTextLabel(cx, scope, src, node, null);
}

/// same as `bindText`, also point `label_node`'s a11y label to `node`'s held text copy. a11y label
/// is borrow slice: direct pointer to source value dangles after source update, pointer to node
/// copy re-assigned after each replacement. `label_node` must already have a11y attribute.
pub fn bindTextLabel(cx: *core.Cx, scope: *Scope, src: anytype, node: *Node, label_node: ?*Node) !void {
    try bindTextA11y(cx, scope, src, node, label_node, .label);
}

/// a11y field synced by text binding
pub const A11yTextField = enum { label, description, value_text, live_text };

/// same as `bindText`, also point specified a11y text field of `a11y_node` to `node`'s held text
/// copy (e.g., live region's live_text: AT announces new text when content changes).
pub fn bindTextA11y(cx: *core.Cx, scope: *Scope, src: anytype, node: *Node, a11y_node: ?*Node, comptime field: A11yTextField) !void {
    const Ctx = struct { node: *Node, a11y_node: ?*Node, allocator: std.mem.Allocator };
    const c = Ctx{ .node = node, .a11y_node = a11y_node, .allocator = cx.allocator };
    try bind(scope, src, c, struct {
        fn apply(ctx: Ctx, text: []const u8) void {
            defer sync(ctx);
            // content unchanged (including initial value already sync-written in mount) no longer
            // allocates
            if (ctx.node.getText()) |cur| {
                if (std.mem.eql(u8, cur.content, text)) return;
            }
            ctx.node.setTextContent(ctx.allocator, text) catch |err| {
                std.log.err("[ui.bindText] setTextContent failed: {}", .{err});
            };
        }
        fn sync(ctx: Ctx) void {
            const ln = ctx.a11y_node orelse return;
            if (ln.behavior.interaction.a11y) |*attrs| {
                @field(attrs, @tagName(field)) = if (ctx.node.getText()) |t| t.content else null;
            }
        }
    }.apply);
}

/// optional text row (card title / subtitle like "show one line if present, take no space if
/// absent"): `node` holds text copy, hidden when empty; `group`'s child all hidden when it is also;
/// `a11y_node` label points to `node` copy (null when empty). sync-write initial value (return on
/// fail), dynamic source then bind.
pub fn bindOptionalTextRow(cx: *core.Cx, scope: *Scope, src: anytype, node: *Node, group: ?*Node, a11y_node: ?*Node) !void {
    const s = reactive.toSource(src);
    const Ctx = struct { node: *Node, group: ?*Node, a11y_node: ?*Node, allocator: std.mem.Allocator };
    const c = Ctx{ .node = node, .group = group, .a11y_node = a11y_node, .allocator = cx.allocator };
    const Apply = struct {
        fn write(ctx: Ctx, text: []const u8) !void {
            const cur = if (ctx.node.getText()) |t| t.content else "";
            if (!std.mem.eql(u8, cur, text)) try ctx.node.setTextContent(ctx.allocator, text);
            ctx.node.setDisplay(if (text.len > 0) .flex else .none);
            if (ctx.group) |g| {
                var any = false;
                for (g.children.items) |child| {
                    if (child.style.display != .none) any = true;
                }
                g.setDisplay(if (any) .flex else .none);
            }
            if (ctx.a11y_node) |an| {
                if (an.behavior.interaction.a11y) |*attrs| {
                    attrs.label = if (text.len > 0) ctx.node.getText().?.content else null;
                }
            }
            ctx.node.markLayoutDirty();
        }
        fn apply(ctx: Ctx, text: []const u8) void {
            write(ctx, text) catch |err| std.log.err("[ui.bindOptionalTextRow] update failed: {}", .{err});
        }
    };
    try Apply.write(c, s.peek());
    if (s != .value) try bind(scope, s, c, Apply.apply);
}

/// Rebuild all of `container`'s child nodes when the source changes (list display
/// components: Timeline, Breadcrumb ...).
/// - `keyFn(value) u64` decides whether to rebuild (usually content + address of the
///   borrowed string: nodes borrow the slice, so a new array with same content also rebuilds).
/// - `build(ctx, child_scope, container, value)` appends child nodes; interaction
///   context and hooks register on `child_scope` and are rebuilt together. build runs untracked.
/// - static source: build once at mount, no effect (array only read in this sync call,
///   can be on the stack).
/// - first build error returns directly (built subtree and child scope cleaned together);
///   a rebuild failure in an effect logs and clears, retried on the next source change.
/// - contract: scope lifetime must not exceed `container` -- typically bound to the
///   container's (or an ancestor's) component scope. freeNode disposes the bound scope
///   (effect destroyed) then frees the node; if the scope outlives the container, a
///   source change after free makes the effect access freed nodes.
pub fn rebuildOn(
    cx: *core.Cx,
    scope: *Scope,
    src: anytype,
    container: *Node,
    ctx: anytype,
    comptime keyFn: anytype,
    comptime build: anytype,
) !void {
    const S = @TypeOf(reactive.toSource(src));
    const T = S.Value;
    const Ctx = @TypeOf(ctx);
    const s = reactive.toSource(src);
    reactive.checkBorrow(scope, s);

    const State = struct {
        src: S,
        ctx: Ctx,
        cx: *core.Cx,
        scope: *Scope,
        container: *Node,
        child: ?*Scope = null,
        key: ?u64 = null,

        const Self = @This();

        fn clear(st: *Self) void {
            for (st.container.children.items) |n| hooks.invalidateSubtreeHookState(n);
            if (st.child) |c| c.dispose();
            st.child = null;
            while (st.container.children.items.len > 0) {
                const n = st.container.children.items[st.container.children.items.len - 1];
                core.clearNodeScopes(n);
                st.cx.detachChild(st.container, n);
                st.cx.freeNode(n);
            }
            st.key = null;
            st.container.markLayoutDirty();
        }

        fn rebuild(st: *Self, value: T) !void {
            const k = keyFn(value);
            if (st.key != null and st.key.? == k) return;
            st.clear();
            errdefer st.clear();
            const child = try st.scope.childScope();
            st.child = child;
            try st.scope.owner.untrack(struct {
                fn call(args: struct { *Self, *Scope, T }) !void {
                    try build(args[0].ctx, args[1], args[0].container, args[2]);
                }
            }.call, .{ st, child, value });
            st.key = k;
        }

        fn run(st: *Self) void {
            st.rebuild(st.src.get()) catch |err| std.log.err("[ui.rebuildOn] rebuild failed: {}", .{err});
        }

        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            allocator.destroy(@as(*Self, @ptrCast(@alignCast(ptr))));
        }
    };

    if (s == .value) {
        // static: built on scope itself (same lifetime as component), no rebuild facility. like
        // dynamic path doesn't track: when mounted in another effect, signal read by build can't
        // register to that effect
        try scope.owner.untrack(struct {
            fn call(args: struct { Ctx, *Scope, *Node, T }) !void {
                try build(args[0], args[1], args[2], args[3]);
            }
        }.call, .{ ctx, scope, container, s.value });
        return;
    }
    const st = try scope.allocator.create(State);
    st.* = .{ .src = s, .ctx = ctx, .cx = cx, .scope = scope, .container = container };
    try scope.adoptResource(st, State.destroy);
    try st.rebuild(s.peek());
    // steps after first build fail: clean subtree and child scope yourself, don't rely on caller to
    // free container
    errdefer st.clear();
    try scope.createEffect(st, State.run);
}

fn ownerOf(src: anytype) *reactive.SignalOwner {
    return switch (src) {
        .value => unreachable,
        .signal => |p| p.owner,
        .memo => |p| p.owner,
        .derived => |d| d.owner,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Probe = struct {
    calls: u32 = 0,
    last: u32 = 0,
    fn apply(p: *Probe, v: u32) void {
        p.calls += 1;
        p.last = v;
    }
};

test "bind: static source applies once without creating an effect" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    var probe = Probe{};
    const before = cx.owner.graph.countByKind();
    try bind(scope, reactive.Source(u32).of(7), &probe, Probe.apply);
    const after = cx.owner.graph.countByKind();
    try testing.expectEqual(@as(u32, 1), probe.calls);
    try testing.expectEqual(@as(u32, 7), probe.last);
    try testing.expectEqual(before.get(.effect), after.get(.effect));
}

test "bind: dynamic source re-applies on change and suppresses equal values" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const n = try scope.createSignal(u32, 3);
    const parity = reactive.map(n, struct {
        fn f(v: u32) u32 {
            return v % 2;
        }
    }.f);
    var probe = Probe{};
    try bind(scope, parity, &probe, Probe.apply);
    try testing.expectEqual(@as(u32, 1), probe.calls);
    n.set(5); // derived value still 1: equality suppression, no repeated apply
    try testing.expectEqual(@as(u32, 1), probe.calls);
    n.set(6);
    try testing.expectEqual(@as(u32, 2), probe.calls);
    try testing.expectEqual(@as(u32, 0), probe.last);
}

test "bind: fallible apply — the initial error fails bind, a later one leaves the target and the next change applies even an equal value" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Target = struct {
        applied: ?u32 = null,
        fail: bool = false,
        fn apply(t: *@This(), v: u32) error{OutOfMemory}!void {
            if (t.fail) return error.OutOfMemory;
            t.applied = v;
        }
    };
    // static source: the error comes back from bind
    var static_target = Target{ .fail = true };
    try testing.expectError(error.OutOfMemory, bind(scope, reactive.Source(u32).of(1), &static_target, Target.apply));
    // dynamic source (tens of n): initial failure fails bind and leaves no effect behind
    const n = try scope.createSignal(u32, 31);
    const tens = reactive.map(n, struct {
        fn f(v: u32) u32 {
            return v / 10;
        }
    }.f);
    const effects = cx.owner.graph.countByKind().get(.effect);
    var target = Target{ .fail = true };
    try testing.expectError(error.OutOfMemory, bind(scope, tens, &target, Target.apply));
    try testing.expectEqual(effects, cx.owner.graph.countByKind().get(.effect));
    try testing.expect(target.applied == null);
    target.fail = false;
    try bind(scope, tens, &target, Target.apply);
    try testing.expectEqual(@as(?u32, 3), target.applied);
    // a later failure keeps the previous value...
    target.fail = true;
    n.set(41);
    try testing.expectEqual(@as(?u32, 3), target.applied);
    // ...and the failed value is not taken as applied: the next change, still 4, applies it
    target.fail = false;
    n.set(42);
    try testing.expectEqual(@as(?u32, 4), target.applied);
}

test "bindText: node text follows an owned text signal across buffer growth" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const label = try core.text(cx, "", .{});
    defer cx.freeNode(label);
    const name = try scope.createText("hi", .{});
    try bindText(cx, scope, name, label);
    try testing.expectEqualStrings("hi", label.getText().?.content);
    name.set("a much longer value that reallocates the text buffer");
    try testing.expectEqualStrings("a much longer value that reallocates the text buffer", label.getText().?.content);
    name.set("hi");
    try testing.expectEqualStrings("hi", label.getText().?.content);
}

test "bindTextLabel: a11y label follows the node's own copy across updates" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const label = try core.text(cx, "", .{});
    defer cx.freeNode(label);
    const host = try core.box(cx, .{}, .{});
    defer cx.freeNode(host);
    host.behavior.interaction.a11y = .{ .role = .dialog };
    const name = try scope.createText("first", .{});
    try bindTextLabel(cx, scope, name, label, host);
    try testing.expectEqualStrings("first", host.behavior.interaction.a11y.?.label.?);
    name.set("a much longer value that reallocates the text buffer");
    try testing.expectEqual(label.getText().?.content.ptr, host.behavior.interaction.a11y.?.label.?.ptr);
    try testing.expectEqualStrings("a much longer value that reallocates the text buffer", host.behavior.interaction.a11y.?.label.?);
}

const RebuildProbe = struct {
    cx: *core.Cx,
    builds: u32 = 0,
    fn key(items: []const u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(items));
    }
    fn build(p: *RebuildProbe, _: *Scope, container: *Node, items: []const u32) !void {
        p.builds += 1;
        for (items) |_| _ = try core.adoptChild(p.cx, p.cx.allocator, container, try core.box(p.cx, .{}, .{}));
    }
};

test "rebuildOn: static builds once without an effect; dynamic rebuilds only when the key changes" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    var probe = RebuildProbe{ .cx = cx };
    const host = try core.box(cx, .{}, .{});
    defer cx.freeNode(host);
    const before = cx.owner.graph.countByKind().get(.effect);
    const two = [_]u32{ 1, 2 };
    try rebuildOn(cx, scope, reactive.Source([]const u32).of(&two), host, &probe, RebuildProbe.key, RebuildProbe.build);
    try testing.expectEqual(before, cx.owner.graph.countByKind().get(.effect));
    try testing.expectEqual(@as(usize, 2), host.children.items.len);

    const dyn_host = try core.box(cx, .{}, .{});
    defer cx.freeNode(dyn_host);
    const three = [_]u32{ 1, 2, 3 };
    const same = [_]u32{ 1, 2, 3 };
    const items = try scope.createSignal([]const u32, &two);
    probe.builds = 0;
    try rebuildOn(cx, scope, items, dyn_host, &probe, RebuildProbe.key, RebuildProbe.build);
    items.set(&three);
    try testing.expectEqual(@as(usize, 3), dyn_host.children.items.len);
    items.set(&same); // same key (content): no rebuild
    try testing.expectEqual(@as(u32, 2), probe.builds);
}

test "rebuildOn: a static build inside another effect does not subscribe that effect" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const host = try core.box(cx, .{}, .{});
    defer cx.freeNode(host);

    const Outer = struct {
        cx: *core.Cx,
        scope: *Scope,
        host: *Node,
        dep: *reactive.Signal(u32),
        runs: u32 = 0,
        fn run(self: *@This()) void {
            self.runs += 1;
            if (self.runs > 1) return;
            const one = [_]u32{1};
            rebuildOn(self.cx, self.scope, reactive.Source([]const u32).of(&one), self.host, self, key, build) catch unreachable;
        }
        fn key(_: []const u32) u64 {
            return 0;
        }
        fn build(self: *@This(), _: *Scope, _: *Node, _: []const u32) !void {
            _ = self.dep.get();
        }
    };
    var outer = Outer{ .cx = cx, .scope = scope, .host = host, .dep = try scope.createSignal(u32, 0) };
    try scope.createEffect(&outer, Outer.run);
    outer.dep.set(1);
    try testing.expectEqual(@as(u32, 1), outer.runs);
}

test "OOM sweep: bind / bindText fail cleanly at every allocation" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var cx = try core.Cx.init(testing.allocator, std.testing.io);
        defer cx.deinit();
        const scope = Scope.init(failing.allocator(), null, cx.owner) catch continue;
        const label = try core.text(cx, "", .{});
        defer cx.freeNode(label);
        var probe = Probe{};
        const ok = blk: {
            const n = scope.createSignal(u32, 1) catch break :blk false;
            bind(scope, n, &probe, Probe.apply) catch break :blk false;
            const t = scope.createText("x", .{}) catch break :blk false;
            bindText(cx, scope, t, label) catch break :blk false;
            n.set(2);
            try testing.expectEqual(@as(u32, 2), probe.last);
            break :blk true;
        };
        scope.dispose();
        if (ok and !failing.has_induced_failure) break;
    }
    try testing.expect(fail_index > 4);
}
