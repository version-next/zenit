const std = @import("std");
const ui = @import("ui");
const graph_assertions = @import("graph_assertions.zig");
const fixture = @import("_review_reactive.yix.zig");
const testing = std.testing;

const Env = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: ?*ui.Node = null,
    fn init() !Env {
        const cx = try ui.Cx.init(testing.allocator, std.testing.io);
        errdefer cx.deinit();
        return .{ .cx = cx, .scope = try ui.Scope.init(testing.allocator, null, cx.owner) };
    }
    fn deinit(e: *Env) void {
        e.scope.dispose();
        if (e.root) |r| e.cx.freeNode(r);
        e.cx.deinit();
    }
    fn mount(e: *Env, element: anytype) !void {
        e.root = try ui.view.render(e.scope, e.cx, element);
    }
    fn text(e: *Env) []const u8 {
        return e.root.?.getText().?.content;
    }
};

test "Yix external get in function-only interpolation follows actual reads" {
    var e = try Env.init();
    defer e.deinit();
    const store = try e.scope.createSignal(i32, 10);
    fixture.store = store;
    defer fixture.store = null;
    try e.mount(fixture.ExternalOnly(.{}));
    try testing.expectEqualStrings("10", e.text());
    store.set(20);
    try testing.expectEqualStrings("20", e.text());
}

test "Yix external get with static prop follows actual reads" {
    var e = try Env.init();
    defer e.deinit();
    const store = try e.scope.createSignal(i32, 10);
    fixture.store = store;
    defer fixture.store = null;
    try e.mount(fixture.ExternalWithProp(.{ .n = 1 }));
    store.set(20);
    try testing.expectEqualStrings("21", e.text());
}

test "Yix function returning source preserves source forwarding" {
    var e = try Env.init();
    defer e.deinit();
    const store = try e.scope.createSignal(i32, 10);
    fixture.store = store;
    defer fixture.store = null;
    try e.mount(fixture.ReturnedSource(.{}));
    store.set(20);
    try testing.expectEqualStrings("20", e.text());
}

test "Yix pure calls and peek-only calls keep zero memo and effect overhead" {
    inline for (.{ fixture.Pure, fixture.PeekOnly }) |component| {
        var e = try Env.init();
        defer e.deinit();
        const store = try e.scope.createSignal(i32, 10);
        fixture.store = store;
        defer fixture.store = null;
        const before = try graph_assertions.staticCounts(e.cx);
        try e.mount(component(.{}));
        const after = try graph_assertions.staticCounts(e.cx);
        try testing.expectEqual(before.get(.memo), after.get(.memo));
        try testing.expectEqual(before.get(.effect), after.get(.effect));
        const initial = try testing.allocator.dupe(u8, e.text());
        defer testing.allocator.free(initial);
        store.set(20);
        try testing.expectEqualStrings(initial, e.text());
    }
}

test "Yix external function-only host attribute follows actual reads" {
    var e = try Env.init();
    defer e.deinit();
    const store = try e.scope.createSignal(i32, 0);
    fixture.store = store;
    defer fixture.store = null;
    try e.mount(fixture.ExternalVisible(.{}));
    try testing.expect(e.root.?.style.display == .none);
    store.set(1);
    try testing.expect(e.root.?.style.display == .flex);
}

test "Yix null and comptime struct call results retain value passing" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(fixture.NullCall(.{}));
    try testing.expectEqualStrings("nil", a.text());
    var b = try Env.init();
    defer b.deinit();
    try b.mount(fixture.ComptimeStructCall(.{}));
    try testing.expectEqualStrings("i32", b.text());
}

test "Yix static recipe call remains directly applicable as style" {
    var e = try Env.init();
    defer e.deinit();
    const before = try graph_assertions.staticCounts(e.cx);
    try e.mount(fixture.StaticRecipeCall(.{}));
    const after = try graph_assertions.staticCounts(e.cx);
    try testing.expectEqual(@as(f32, 7), e.root.?.style.gap);
    try testing.expectEqual(before.get(.memo), after.get(.memo));
    try testing.expectEqual(before.get(.effect), after.get(.effect));
}

test "Yix runtime struct with comptime metadata still tracks external reads" {
    var e = try Env.init();
    defer e.deinit();
    const store = try e.scope.createSignal(i32, 10);
    fixture.store = store;
    defer fixture.store = null;
    try e.mount(fixture.MixedRuntimeCall(.{}));
    try testing.expectEqualStrings("10", e.text());
    store.set(20);
    try testing.expectEqualStrings("20", e.text());
}
