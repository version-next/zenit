//! Resource assertions shared by release and preview fixtures. Preview-only
//! style watchers are identified by their actual dependencies, never a fixed
//! allowance for extra effects.
const std = @import("std");
const ui = @import("ui");
const t = std.testing;

fn serviceSignal(cx: *ui.Cx, raw: u32) bool {
    if (cx.theme_signal) |s| if (s.base.graph_node_raw == raw) return true;
    if (cx.a11y_prefs_signal) |s| if (s.base.graph_node_raw == raw) return true;
    if (comptime @TypeOf(cx.style_signal) != void)
        if (cx.style_signal) |s| if (s.base.graph_node_raw == raw) return true;
    return false;
}

/// No allowance: every service signal must be a published Cx service, owned
/// exactly once by the independent service scope, with no business resources.
fn services(cx: *ui.Cx) !usize {
    var expected: usize = @intFromBool(cx.theme_signal != null);
    expected += @intFromBool(cx.a11y_prefs_signal != null);
    if (comptime @TypeOf(cx.style_signal) != void) expected += @intFromBool(cx.style_signal != null);
    if (cx.service_scope) |scope| {
        try t.expect(scope.parent == null and scope.owner == cx.owner);
        try t.expectEqual(expected, scope.signals.items.len);
        try t.expectEqual(@as(usize, 0), scope.children.items.len);
        try t.expectEqual(@as(usize, 0), scope.effects.items.len);
        try t.expectEqual(@as(usize, 0), scope.resources.items.len);
        for (scope.signals.items, 0..) |s, i| {
            try t.expect(serviceSignal(cx, s.graph_node_raw));
            for (scope.signals.items[0..i]) |other| try t.expect(s != other);
        }
    } else try t.expectEqual(@as(usize, 0), expected);
    return expected;
}

pub fn staticCounts(cx: *ui.Cx) !@TypeOf(cx.owner.graph.countByKind()) {
    var counts = cx.owner.graph.countByKind();
    counts.getPtr(.signal).* -= try services(cx);
    if (comptime @TypeOf(cx.style_signal) != void) {
        if (cx.style_signal) |generation| {
            for (cx.owner.graph.nodes.items) |node| {
                if (!node.alive or node.kind != .effect) continue;
                var watches_preview = false;
                for (node.sources.items) |source| {
                    if (@as(u32, @bitCast(source)) == generation.base.graph_node_raw) watches_preview = true;
                }
                if (!watches_preview) continue;
                // Static style watchers may only read theme and generation.
                // A mistakenly captured business signal must still fail.
                for (node.sources.items) |source| {
                    const raw: u32 = @bitCast(source);
                    const theme = if (cx.theme_signal) |signal| raw == signal.base.graph_node_raw else false;
                    if (!(raw == generation.base.graph_node_raw or theme)) return error.UnexpectedStyleDependency;
                }
                counts.getPtr(.effect).* -= 1;
            }
        }
    }
    return counts;
}

pub fn expectOnlySignals(cx: *ui.Cx, scope: ?*ui.Scope, extra: ?*ui.Scope) !void {
    const expected = (try services(cx)) + (if (scope) |s| s.signals.items.len else @as(usize, 0)) + (if (extra) |s| s.signals.items.len else @as(usize, 0));
    try t.expectEqual(expected, cx.owner.graph.nodeCount());
    for (cx.owner.graph.nodes.items, 0..) |node, index| {
        if (!node.alive) continue;
        try t.expectEqual(.signal, node.kind);
        try t.expectEqual(@as(usize, 0), node.sources.items.len);
        try t.expectEqual(@as(usize, 0), node.observers.items.len);
        var owned = serviceSignal(cx, @as(u32, @intCast(index)) | (@as(u32, cx.owner.graph.generations.items[index]) << 24));
        if (scope) |s| for (s.signals.items) |signal| {
            if (@as(u24, @truncate(signal.graph_node_raw)) == index) owned = true;
        };
        if (extra) |s| for (s.signals.items) |signal| {
            if (@as(u24, @truncate(signal.graph_node_raw)) == index) owned = true;
        };
        try t.expect(owned);
    }
}
