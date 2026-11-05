/// Spinner Component
///
/// Rotating loading animation (Material Design circular progress style), replicating MUI
/// CircularProgress keyframes. View in spinner.yix (custom canvas), keyframes and drawing
/// in styles.yss.
const std = @import("std");
const math = std.math;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = @import("../../reactive.zig").Scope;
const styles = @import("_styles.yss.zig");

/// Create Spinner: `W.Spinner(.{ .size = 24 })`
pub const Spinner = @import("_spinner.yix.zig").Spinner;
pub const SpinnerProps = @import("_spinner.yix.zig").SpinnerProps;

// ========== Test ==========

test "Spinner: basic mount" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    try std.testing.expectEqual(@as(f32, 20), spinner.rectFromWorldOrFallback().w);
    try std.testing.expect(spinner.hasBeforeRenderHooks());
    try std.testing.expect(spinner.meta.per_frame.custom_hooks.draw != null);
    try std.testing.expectEqual(core.A11yRole.progressbar, spinner.behavior.interaction.a11y.?.role);
    try std.testing.expectEqualStrings("Spinner", spinner.meta.ownership.meta.component_name.?);
}

test "Spinner: custom size" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{ .size = 40, .stroke_width = 4 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    try std.testing.expectEqual(@as(f32, 40), spinner.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 40), spinner.rectFromWorldOrFallback().h);
}

test "Spinner: custom draw emits display list arc" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(120, 120);

    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    _ = ctx.render();

    var saw_arc = false;
    for (ctx.display_list.items.items) |item| {
        switch (item) {
            .arc => |arc| {
                saw_arc = true;
                try std.testing.expectEqual(spinner.id, arc.header.node_id);
                try std.testing.expect(arc.outer_radius > 0);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_arc);
}

test "Spinner: custom draw replays own content from display list" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(80, 80);

    const root = try box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    ctx.perf.display_list_own_replay_count = 0;
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    try std.testing.expect(ctx.perf.display_list_own_replay_count >= 1);

    var saw_arc = false;
    for (commands) |cmd| {
        if (cmd.kind == .path and cmd.arc_outer_radius > 0 and cmd.stroke_width > 0) {
            saw_arc = true;
            break;
        }
    }
    try std.testing.expect(saw_arc);
}

test "Spinner: 圆弧只由绝对时间决定（帧率不影响速度），周期首尾衔接" {
    const a0 = styles.arcAt(0);
    try std.testing.expectApproxEqAbs(@as(f32, -math.pi / 2.0), a0.start, 0.0001);
    // Same at any given moment regardless of prior frames; full cycle returns arc to
    // start, total rotation 270 degrees
    const cycle: f64 = styles.cycle_seconds * 1000.0;
    const a1 = styles.arcAt(cycle);
    try std.testing.expectApproxEqAbs(a0.end - a0.start, a1.end - a1.start, 0.0001);
    try std.testing.expectApproxEqAbs(@mod(a0.start + 1.5 * math.pi, math.tau), @mod(a1.start, math.tau), 0.001);
    // Arc is longest at half period
    const half = styles.arcAt(cycle / 2.0);
    try std.testing.expect(half.end - half.start > a0.end - a0.start + 4.0);
}

test "Spinner: 颜色缺省取主题强调色，换主题跟随" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(60, 60);
    const root = try box(ctx, .{ .width = .{ .px = 60 }, .height = .{ .px = 60 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);
    ctx.setTheme(&core.theme.dark);
    ctx.layout();
    _ = ctx.render();
    var color: ?Color = null;
    for (ctx.display_list.items.items) |item| switch (item) {
        .arc => |arc| color = arc.color,
        else => {},
    };
    try std.testing.expect(Color.eql(core.theme.dark.tokens.color.accent, color.?));
}

test "Spinner: hands its loop to the compositor once stable, unoccluded and enabled" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(120, 120);
    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const spinner = try Spinner(.{ .size = 24 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);
    try std.testing.expectEqual(@as(usize, 1), ctx.sprites.sources.items.len);

    // Disabled (the default without a presenting host): always GPU painted.
    for (0..3) |_| {
        ctx.layout();
        _ = ctx.render();
    }
    try std.testing.expectEqual(@as(usize, 0), ctx.sprites.placements.items.len);

    ctx.sprites.enabled = true;
    // Taken over only once still for settle_ms, not at the first pause.
    const settle_ms = @import("../../core/compositor_sprite.zig").settle_ms;
    try ctx.setTestFrameStep(100);
    var placement: ?@TypeOf(ctx.sprites.placements.items[0]) = null;
    for (0..10) |_| {
        ctx.advanceFrameClock();
        root.markRenderDirty();
        ctx.layout();
        _ = ctx.render();
        if (ctx.sprites.placements.items.len == 1) {
            if (placement == null) try std.testing.expect(ctx.frame_time_ms >= settle_ms);
            placement = ctx.sprites.placements.items[0];
        }
    }
    const p = placement orelse return error.SpriteNotPlaced;
    try std.testing.expect(ctx.sprites.isActive(spinner.id));
    try std.testing.expect(!p.exiting);
    try std.testing.expectEqual(@as(u32, 336), p.frame_count);
    for (ctx.lowerForEncoderPaintTable()) |cmd| {
        try std.testing.expect(!(cmd.kind == .path and cmd.arc_outer_radius > 0));
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frames = try ctx.sprites.generate(ctx.allocator, arena.allocator(), p);
    // One arc per frame, painted where the node is; frame 0 and frame 84
    // (one arc cycle, 270 degrees later) differ.
    try std.testing.expectEqual(@as(usize, p.frame_count), frames.ends.len);
    try std.testing.expectEqual(@as(u32, 1), frames.ends[0]);
    try std.testing.expect(frames.items[0].arc_start_angle != frames.items[84].arc_start_angle);
    const rect = spinner.rectFromWorldOrFallback();
    for (frames.items) |f| {
        try std.testing.expectApproxEqAbs(rect.x + rect.w / 2, f.geom.x, 0.001);
        try std.testing.expectApproxEqAbs(rect.y + rect.h / 2, f.geom.y, 0.001);
    }
}

test "Spinner: an unfiltered host keeps the arc in every rendered frame, painted at the frame's time" {
    // Windows host (sprite_host.zig): opaque sprites stacked above a frame
    // that keeps painting the node, so neither hand-over needs an overlap.
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(120, 120);
    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const spinner = try Spinner(.{ .size = 24 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);
    const other = try box(ctx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(1, 2, 3, 255) }, .{});
    try root.appendChild(std.testing.allocator, other);
    ctx.sprites.enabled = true;
    ctx.sprites.filter_placed = false;
    ctx.sprites.replay_in_place = true;
    ctx.sprites.flipbook_hz = 120;
    try ctx.setTestFrameStep(100);
    for (0..10) |_| {
        ctx.advanceFrameClock();
        root.markRenderDirty();
        ctx.layout();
        _ = ctx.render();
    }
    try std.testing.expect(ctx.sprites.isActive(spinner.id));
    // Sampled at the host's rate: 5.6 s at 120 Hz.
    try std.testing.expectEqual(@as(u32, 672), ctx.sprites.placements.items[0].frame_count);
    const arcAt = struct {
        fn f(cx: *Cx) ?f32 {
            for (cx.lowerForEncoderPaintTable()) |cmd| if (cmd.kind == .path and cmd.arc_outer_radius > 0) return cmd.arc_start_angle;
            return null;
        }
    }.f;
    const before = arcAt(ctx) orelse return error.ArcFiltered;
    // A frame rendered for another reason while the sprite is active repaints
    // the arc at that frame's time (nothing else marks it: its tick stays
    // quiet so the window can idle).
    other.markRenderDirty();
    ctx.advanceFrameClock();
    ctx.layout();
    _ = ctx.render();
    try std.testing.expect(ctx.sprites.isActive(spinner.id));
    const after = arcAt(ctx) orelse return error.ArcFiltered;
    try std.testing.expect(before != after);
    // Leaving needs no overlap frame: no exit placement.
    ctx.sprites.enabled = false;
    root.markRenderDirty();
    ctx.advanceFrameClock();
    ctx.layout();
    _ = ctx.render();
    try std.testing.expect(!ctx.sprites.isActive(spinner.id));
    try std.testing.expectEqual(@as(usize, 0), ctx.sprites.placements.items.len);
    try std.testing.expect(arcAt(ctx) != null);
}

test "Spinner: unmount removes its compositor sprite source" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 60 }, .height = .{ .px = 60 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);
    try std.testing.expectEqual(@as(usize, 1), ctx.sprites.sources.items.len);
    scope.dispose();
    try std.testing.expectEqual(@as(usize, 0), ctx.sprites.sources.items.len);
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig
test "spinner: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("spinner", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Spinner(.{ .size = 24 }).mount(scope, cx);
        }
    }.m);
}

// Test collection from styles.yss; this line required; see docs/STYLING.md
test {
    _ = @import("_styles.yss.zig");
}
