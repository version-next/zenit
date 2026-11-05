//! Theme switch contract (cross-component): a component mounted under one theme and then
//! switched with `Cx.setTheme` must paint exactly like the same component mounted fresh under
//! the new theme. Mount-time token captures (a palette or token pointer stored in component
//! state, a color baked into a literal style) fail here.
const std = @import("std");
const testing = std.testing;
const core = @import("../core.zig");
const theme = core.theme;
const Cx = core.Cx;
const Scope = core.Scope;
const Node = core.Node;
const Color = core.Color;

const select = @import("select/mod.zig");
const tabs = @import("tabs/mod.zig");

const Paint = struct {
    background: Color,
    border: Color,
    text: ?Color,
    tint: ?Color,
};

fn paintOf(n: *const Node) Paint {
    return .{
        .background = n.getBackground(),
        .border = n.style.border.color,
        .text = if (n.getText()) |t| t.color else null,
        .tint = if (n.tintMode()) |m| m.color else null,
    };
}

/// Paint plus where the node is (component name chain), for the failure message only.
const Entry = struct {
    paint: Paint,
    where: [4]?[]const u8,
};

fn collect(list: *std.ArrayList(Entry), n: *const Node) !void {
    var where: [4]?[]const u8 = @splat(null);
    var cur: ?*const Node = n;
    var i: usize = 0;
    while (cur) |c| : (cur = c.parent) {
        if (i == where.len) break;
        const name = c.meta.ownership.meta.component_name orelse continue;
        where[i] = name;
        i += 1;
    }
    try list.append(testing.allocator, .{ .paint = paintOf(n), .where = where });
    for (n.children.items) |c| try collect(list, c);
}

/// Paint of the component tree plus everything it portaled (popover panels).
fn snapshot(cx: *Cx, root: *const Node) !std.ArrayList(Entry) {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(testing.allocator);
    try collect(&list, root);
    if (cx.popover_portal_root) |portal| try collect(&list, portal);
    return list;
}

fn settle(cx: *Cx) void {
    const render_engine = @import("../core/render_engine/mod.zig");
    for (0..40) |_| {
        render_engine.current_frame_time_ms += 16.0;
        render_engine.current_frame_dt_ms = 16.0;
        cx.frame_time_ms = render_engine.current_frame_time_ms;
        cx.layout();
        _ = cx.render();
    }
}

const MountFn = fn (scope: *Scope, cx: *Cx) anyerror!*Node;

fn render(tokens: *const theme.ThemeTokens, switch_to: ?*const theme.ThemeTokens, comptime mount: MountFn) !std.ArrayList(Entry) {
    const cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);
    cx.setTheme(tokens);
    const root = try core.box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    try root.appendChild(testing.allocator, try mount(scope, cx));
    settle(cx);
    if (switch_to) |t| {
        cx.setTheme(t);
        // Declared color transitions (ControlShell eases background 150ms) run to their end.
        settle(cx);
    }
    return snapshot(cx, root);
}

fn expectThemeSwitchMatchesFreshMount(comptime name: []const u8, comptime mount: MountFn) !void {
    const pairs = [_][2]*const theme.ThemeTokens{
        .{ &theme.dark, &theme.light },
        .{ &theme.light, &theme.dark },
        .{ &theme.light, &theme.high_contrast },
    };
    for (pairs) |pair| {
        var switched = try render(pair[0], pair[1], mount);
        defer switched.deinit(testing.allocator);
        var fresh = try render(pair[1], null, mount);
        defer fresh.deinit(testing.allocator);
        testing.expectEqual(fresh.items.len, switched.items.len) catch |err| {
            std.debug.print("{s}: node count differs after theme switch\n", .{name});
            return err;
        };
        for (fresh.items, switched.items, 0..) |want, got, i| {
            if (std.meta.eql(want.paint, got.paint)) continue;
            std.debug.print("{s}: node {d} (in {any}) keeps the old theme: want {any} got {any}\n", .{ name, i, want.where, want.paint, got.paint });
            return error.ThemeSwitchStale;
        }
    }
}

const opts = [_]select.SelectOption{
    .{ .value = "a", .label = "Alpha" },
    .{ .value = "b", .label = "Beta" },
    .{ .value = "c", .label = "Gamma", .disabled = true },
};

test "theme switch: Select (single, closed and open)" {
    try expectThemeSwitchMatchesFreshMount("Select single", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!*Node {
            return (try select.Select(.{ .options = &opts, .value = "b" }).mount(scope, cx)).wrapper;
        }
    }.m);
    try expectThemeSwitchMatchesFreshMount("Select single open", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!*Node {
            return (try select.Select(.{ .options = &opts, .value = "b", .open = true }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "theme switch: Select (multiple with tags, open)" {
    try expectThemeSwitchMatchesFreshMount("Select multiple open", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!*Node {
            const values: []const []const u8 = &.{ "b", "a" };
            return (try select.Select(.{ .options = &opts, .mode = .multiple, .values = values, .open = true }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "theme switch: Tabs (underline and pill)" {
    const items = [_]tabs.TabItem{
        .{ .id = "one", .label = "One" },
        .{ .id = "two", .label = "Two", .closable = true },
        .{ .id = "three", .label = "Three", .disabled = true },
    };
    _ = items;
    try expectThemeSwitchMatchesFreshMount("Tabs underline", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!*Node {
            const its = [_]tabs.TabItem{ .{ .id = "one", .label = "One" }, .{ .id = "two", .label = "Two", .closable = true }, .{ .id = "three", .label = "Three", .disabled = true } };
            return tabs.Tabs(.{ .items = &its, .active = "two" }).mount(scope, cx);
        }
    }.m);
    try expectThemeSwitchMatchesFreshMount("Tabs pill", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!*Node {
            const its = [_]tabs.TabItem{ .{ .id = "one", .label = "One" }, .{ .id = "two", .label = "Two" } };
            return tabs.Tabs(.{ .items = &its, .active = "one", .variant = .pill }).mount(scope, cx);
        }
    }.m);
}
