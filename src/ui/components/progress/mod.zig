/// Progress Component
///
/// Progress bar component supporting determinate / indeterminate modes. View in progress.yix,
/// styles and drawing in styles.yss.
///
/// Features:
/// - Percentage progress (value / status can come from signals)
/// - Status color: normal/success/error
/// - Indeterminate mode (shiny bar sweeps with frame clock, custom-drawn canvas)
/// - Optional percentage text
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const ConditionalStyle = core.ConditionalStyle;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const styles = @import("_styles.yss.zig");

/// Progress bar status.
pub const ProgressStatus = enum {
    normal,
    success,
    @"error",

    pub fn color(self: ProgressStatus, t: *const theme.ThemeTokens) Color {
        return styles.statusColor(self, t);
    }
};

/// Create Progress: `W.Progress(.{ .value = upload_ratio, .show_text = true })`
pub const Progress = @import("_progress.yix.zig").Progress;
pub const ProgressProps = @import("_progress.yix.zig").ProgressProps;

// ========== Tests ==========

test "Progress: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{ .value = 75 }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, progress);

    // Container has 1 child: track.
    try std.testing.expectEqual(@as(usize, 1), progress.children.items.len);

    // Track has 1 child: fill.
    const track = progress.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), track.children.items.len);
}

test "Progress: indeterminate custom draw emits display list gradient" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(300, 60);

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 60 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{ .indeterminate = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    ctx.layout();
    _ = ctx.render();

    var saw_gradient = false;
    for (ctx.display_list.items.items) |item| {
        switch (item) {
            .multi_gradient_rect => |grad| {
                if (grad.direction == .horizontal and grad.w > 0 and grad.h > 0) {
                    saw_gradient = true;
                    break;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_gradient);
}

test "Progress: indeterminate custom draw replays own content from display list" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(300, 60);

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 60 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{ .indeterminate = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    ctx.layout();
    ctx.perf.display_list_own_replay_count = 0;
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    try std.testing.expect(ctx.perf.display_list_own_replay_count >= 1);

    var saw_gradient = false;
    for (commands) |cmd| {
        if (cmd.isGradient() and cmd.mg_stop_count > 0) {
            // multi_gradient_rect in paint_table distinguished by mg_stop_count > 0; direction
            // field not separately stored (paint_table simplification), geom.w/h > 0 suffices to
            // validate.
            if (cmd.geom.w > 0 and cmd.geom.h > 0) {
                saw_gradient = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_gradient);
}

test "Progress: with text" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{ .value = 50, .show_text = true }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, progress);

    // Container has 2 children: track + text.
    try std.testing.expectEqual(@as(usize, 2), progress.children.items.len);
}

test "Progress: status colors" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const normal = try Progress(.{ .value = 80, .status = .normal }).mount(scope, ctx);
    const success_p = try Progress(.{ .value = 100, .status = .success }).mount(scope, ctx);
    const err = try Progress(.{ .value = 30, .status = .@"error" }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, normal);
    try root.appendChild(std.testing.allocator, success_p);
    try root.appendChild(std.testing.allocator, err);

    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
}

test "Progress: clamp value" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // Over 100 should clamp.
    const progress = try Progress(.{ .value = 150 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    const track = progress.children.items[0];
    const fill = track.children.items[0];
    try std.testing.expectEqual(core.Sizing{ .percent = 100 }, fill.style.width);
}

test "Progress: indeterminate" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{ .indeterminate = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    const track = progress.children.items[0];
    // Indeterminate mode: 1 custom-drawn child, redrawn each frame; reports busy not value.
    try std.testing.expectEqual(@as(usize, 1), track.children.items.len);
    const draw_node = track.children.items[0];
    try std.testing.expect(draw_node.hasBeforeRenderHooks());
    try std.testing.expect(draw_node.meta.per_frame.custom_hooks.draw != null);
    const a11y = progress.behavior.interaction.a11y.?;
    try std.testing.expect(a11y.busy);
    try std.testing.expect(a11y.value_range == null);
}

test "Progress: 光泽条只由绝对时间决定，入场展开、离场收窄" {
    const cycle: f64 = styles.cycle_seconds * 1000.0;
    const start = styles.barAt(0);
    try std.testing.expect(start.right - start.left < 0.05);
    const mid = styles.barAt(cycle * 0.5);
    try std.testing.expect(mid.right - mid.left > 0.2);
    const again = styles.barAt(cycle * 3.5); // Same phase across cycles.
    try std.testing.expectApproxEqAbs(mid.left, again.left, 0.0001);
    try std.testing.expectApproxEqAbs(mid.right, again.right, 0.0001);
}

test "Progress: render emits visible fill and percent text" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(320, 80);

    const root = try box(ctx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 80 },
        .background = ctx.tokens.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{
        .value = 70,
        .status = .success,
        .show_text = true,
        .width = 240,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_track = false;
    var saw_fill = false;
    var saw_text = false;
    // COMPONENTS.json Progress / 65%: flat semantic track surface.
    const expected_track = ctx.tokens.tokens.color.progress_track;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            if (Color.eql(cmd.color.toColor(), expected_track) and cmd.geom.w >= 160 and cmd.geom.h >= 4) {
                saw_track = true;
            }
        } else if (cmd.isGradient() and cmd.mg_stop_count > 0) {
            if (cmd.geom.w >= 100 and cmd.geom.h >= 4) {
                saw_fill = true;
            }
        } else if (cmd.isText()) {
            if (std.mem.eql(u8, cmd.text_content, "70%")) saw_text = true;
        }
    }

    try std.testing.expect(saw_track);
    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_text);
}

// Test collection from styles.yss, this line required, see docs/STYLING.md.
test {
    _ = @import("_styles.yss.zig");
}

// Per-allocation point OOM sweep, see src/ui/components/oom_sweep.zig.
test "progress: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("progress", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Progress(.{ .value = 75 }).mount(scope, cx);
        }
    }.m);
}

test "progress(indeterminate): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("progress(indeterminate)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Progress(.{ .indeterminate = true }).mount(scope, cx);
        }
    }.m);
}

// -- Signal-first behavior --

test "Progress: value and status follow their sources" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const done = try scope.createSignal(f32, 10);
    const status = reactive.map(done, struct {
        fn s(v: f32) ProgressStatus {
            return if (v >= 100) .success else .normal;
        }
    }.s);
    const progress = try Progress(.{ .value = done, .status = status, .show_text = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);
    if (reactive.SignalOwner.debug_checks) try std.testing.expectEqual(@as(u32, 0), ctx.owner.debug.mount_tracked_reads);
    const fill = progress.children.items[0].children.items[0];
    const text_node = progress.children.items[1];
    try std.testing.expectEqual(core.Sizing{ .percent = 10 }, fill.style.width);
    try std.testing.expectEqualStrings("10%", text_node.getText().?.content);

    done.set(64);
    try std.testing.expectEqual(core.Sizing{ .percent = 64 }, fill.style.width);
    try std.testing.expectEqualStrings("64%", text_node.getText().?.content);
    try std.testing.expectEqual(@as(?f32, 64), progress.behavior.interaction.a11y.?.value_now);
    const normal_mid = fill.style.ext.?.multi_gradient.?.stops[1].color;

    done.set(250); // Clamp to 100, status switches success.
    try std.testing.expectEqual(core.Sizing{ .percent = 100 }, fill.style.width);
    try std.testing.expect(!Color.eql(normal_mid, fill.style.ext.?.multi_gradient.?.stops[1].color));
    try std.testing.expect(Color.eql(ProgressStatus.success.color(ctx.tokens), fill.style.ext.?.multi_gradient.?.stops[1].color));
}

test "Progress: static props add no effects (zero-cost static)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const before = ctx.owner.graph.countByKind().get(.effect);
    const p = try Progress(.{ .value = 30, .status = .success, .show_text = true }).mount(scope, ctx);
    defer ctx.freeNode(p);
    try std.testing.expectEqual(before, ctx.owner.graph.countByKind().get(.effect));
}

test "progress(value signal): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("progress(signal)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const v = try scope.createSignal(f32, 42);
            return try Progress(.{ .value = v, .show_text = true }).mount(scope, cx);
        }
    }.m);
}
