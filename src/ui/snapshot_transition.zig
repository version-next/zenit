const std = @import("std");
const core = @import("core.zig");
const animation = @import("animation/mod.zig");
const snapshot_layer = @import("components/snapshot_layer.zig");

const Cx = core.Cx;
const Node = core.Node;
const Scope = core.Scope;
const Snapshot = core.Snapshot;
pub const Transition = struct {
    pub fn dissolve(
        scope: *Scope,
        cx: *Cx,
        outgoing: *Node,
        duration_s: f32,
    ) !void {
        // captureDisplayed 优先用 promoted_cached_commands / cached_commands —
        // 对于复杂 editor 这种子树大量 promoted 的场景，才能抓到完整视觉；
        // 裸 Snapshot.capture 会错过 promoted 子树内容，导致 snapshot 只剩外壳白底。
        // captureDisplayed 走 cache 路径时 commands 空间是 parent-relative，bounds.y 已含
        // node.rect.y 偏移；若再按 (world_origin + bounds - local_offset) 合成 capture_origin，
        // 会把 rect.y 加两次。直接用 outgoing.globalRect 作为 anchor 才是屏幕真实位置。
        const snapshot = (try Snapshot.captureDisplayed(cx, outgoing)) orelse return;
        const gr = outgoing.globalRect();
        var layer = try snapshot_layer.SnapshotLayer(.{
            .snapshot = snapshot,
            .anchor = .{ .x = gr.x, .y = gr.y },
        }).mount(scope, cx);
        layer.animateOpacityAndDismiss(1.0, 0.0, duration_s);
    }

    pub fn crossfade(
        scope: *Scope,
        cx: *Cx,
        outgoing: *Node,
        incoming: *Node,
        duration_s: f32,
    ) !void {
        try dissolve(scope, cx, outgoing, duration_s);
        reveal(scope, cx, incoming, duration_s);
    }

    pub fn reveal(
        _: *Scope,
        cx: *Cx,
        incoming: *Node,
        duration_s: f32,
    ) void {
        incoming.setOpacity(0.0);
        animation.animateNode(incoming, cx.allocator, .{
            .prop = .opacity,
            .from = 0.0,
            .to = 1.0,
            .duration = duration_s,
            .easing = .linear,
        });
    }
};

pub const SnapshotTransition = Transition;

test "Transition.dissolve keeps content visible after source unmount" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try core.box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const outgoing = try core.box(cx, .{
        .width = .{ .px = 36 },
        .height = .{ .px = 22 },
        .background = core.Color.rgb(220, 70, 60),
    }, .{});
    outgoing.style.translate_x = 18;
    outgoing.style.translate_y = 14;
    try root.appendChild(cx.allocator, outgoing);

    _ = cx.render();
    cx.frame_time_ms = 0;
    try Transition.dissolve(scope, cx, outgoing, 0.2);
    cx.detachChild(root, outgoing);
    cx.freeNode(outgoing);

    cx.frame_time_ms = 16;
    _ = cx.render();
    const during = cx.lowerForEncoderPaintTable();
    var found_during = false;
    for (during) |cmd| {
        if (cmd.isFillRect()) {
            if (@abs(cmd.geom.x - 18) < 0.01 and @abs(cmd.geom.y - 14) < 0.01 and @abs(cmd.geom.w - 36) < 0.01 and @abs(cmd.geom.h - 22) < 0.01) {
                found_during = true;
                break;
            }
        }
    }
    try std.testing.expect(found_during);

    cx.frame_time_ms = 266;
    _ = cx.render();
    _ = cx.drainDeferredWork(cx.deferredBudgetUs());
    cx.frame_time_ms = 282;
    _ = cx.render();
    const after = cx.lowerForEncoderPaintTable();
    var found_after = false;
    for (after) |cmd| {
        if (cmd.isFillRect()) {
            if (@abs(cmd.geom.x - 18) < 0.01 and @abs(cmd.geom.y - 14) < 0.01 and @abs(cmd.geom.w - 36) < 0.01 and @abs(cmd.geom.h - 22) < 0.01) {
                found_after = true;
                break;
            }
        }
    }

    try std.testing.expect(!found_after);
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "Transition.crossfade reveals incoming while outgoing dissolves" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try core.box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const outgoing = try core.box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
        .background = core.Color.rgb(220, 70, 60),
    }, .{});
    outgoing.style.translate_x = 24;
    outgoing.style.translate_y = 18;
    try root.appendChild(cx.allocator, outgoing);

    const incoming = try core.box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
        .background = core.Color.rgb(60, 140, 230),
    }, .{});
    incoming.style.translate_x = 24;
    incoming.style.translate_y = 18;
    try root.appendChild(cx.allocator, incoming);

    _ = cx.render();
    cx.frame_time_ms = 0;
    try Transition.crossfade(scope, cx, outgoing, incoming, 0.2);
    cx.detachChild(root, outgoing);
    cx.freeNode(outgoing);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), incoming.getOpacity(), 0.001);

    cx.frame_time_ms = 16;
    _ = cx.render();
    cx.frame_time_ms = 266;
    _ = cx.render();
    _ = cx.drainDeferredWork(cx.deferredBudgetUs());
    cx.frame_time_ms = 282;
    _ = cx.render();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), incoming.getOpacity(), 0.01);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}
