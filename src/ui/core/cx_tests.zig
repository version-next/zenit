//! Cx integration unit tests: frame clock / node release and scope / World
//! SoA mirror / theme toggle / textFmt / input commands / text shaping
//! measure etc. Factored out from core.zig; explicitly imported by core.zig
//! end test block, avoids orphan tests.

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const Allocator = std.mem.Allocator;
const Color = core.Color;
const FontSystem = core.FontSystem;
const Node = core.Node;
const Scope = core.Scope;
const Signal = core.Signal;
const World = core.World;
const actions_mod = @import("../actions.zig");
const bindScopeToNode = core.bindScopeToNode;
const boxStyled = core.boxStyled;
const builders = @import("builders.zig");
const clearNodeScopes = core.clearNodeScopes;
const core_node = @import("node.zig");
const core_types = @import("types.zig");
const cx_render = @import("cx_render.zig");
const events_mod = @import("../events.zig");
const hooks_mod = @import("../hooks.zig");
const image = core.image;
const layout_engine = core.layout_engine;
const text = core.text;
const textFmt = core.textFmt;
const textStyled = core.textStyled;
const text_core_module = @import("text_core");
const text_layout = core.text_layout;
const text_module = @import("text");
const theme = core.theme;
const transition = core.transition;
const world = core.world;

test "loose interaction memo survives alternating windows and invalidates on mutation" {
    const t = std.testing;
    const a = try Cx.init(t.allocator, t.io);
    defer a.deinit();
    const b = try Cx.init(t.allocator, t.io);
    defer b.deinit();
    a.root = try core.box(a, .{}, .{});
    b.root = try core.box(b, .{}, .{});
    a.layout();
    _ = a.render();
    b.layout();
    _ = b.render();
    const index = @import("cx_runtime_index.zig");
    // Warm both after the last global generation change.
    try t.expect(!index.subtreeHasLooseInteractionDirty(a, a.root.?));
    try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
    const a_scans = a.loose_interaction_memo.scans;
    const b_scans = b.loose_interaction_memo.scans;
    for (0..20) |_| {
        try t.expect(!index.subtreeHasLooseInteractionDirty(a, a.root.?));
        try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
    }
    try t.expectEqual(a_scans, a.loose_interaction_memo.scans);
    try t.expectEqual(b_scans, b.loose_interaction_memo.scans);
    a.root.?.frame_state.state_bits.dirty.hit.geometry = true;
    @import("node_dirty.zig").bumpLooseInteractionGen();
    try t.expect(index.subtreeHasLooseInteractionDirty(a, a.root.?));
    try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
    try t.expectEqual(a_scans + 1, a.loose_interaction_memo.scans);
    try t.expectEqual(b_scans + 1, b.loose_interaction_memo.scans);
    a.layout();
    _ = a.render();
    try t.expect(!index.subtreeHasLooseInteractionDirty(a, a.root.?));
    try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
}

test "pending scene loose interaction survives a frozen render clock and is consumed" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.setViewport(320, 120);
    const root = try core.box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 120 } }, .{});
    const child = try core.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    try root.appendChild(t.allocator, child);
    cx.root = root;
    cx.layout();
    _ = cx.render();
    cx.needs_redraw = false;
    cx.caret_flip_host = true; // Ordinary blink no longer masks pending work.
    const frozen = cx.frame_time_ms;
    // These flags intentionally do not bubble to the root render/layout bits.
    child.frame_state.state_bits.dirty.hit.geometry = true;
    @import("node_dirty.zig").bumpLooseInteractionGen();
    try t.expect(!root.frame_state.state_bits.dirty.core.subtree_render);
    try t.expect(!root.frame_state.state_bits.dirty.pipeline.subtree_interaction);
    try t.expect(cx.hasPendingSceneWork());
    cx.layout();
    _ = cx.render();
    try t.expectEqual(frozen, cx.frame_time_ms);
    try t.expect(!child.frame_state.state_bits.dirty.hit.geometry);
    try t.expect(!cx.hasPendingSceneWork());
    try t.expect(!cx.wantsFrame());
}

test "pending scene interaction and animation advance the active frame clock" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.root = try core.box(cx, .{}, .{});
    cx.layout();
    _ = cx.render();
    try cx.setTestFrameStep(16);
    cx.needs_redraw = false;
    cx.root.?.frame_state.state_bits.dirty.hit.semantics = true;
    @import("node_dirty.zig").bumpLooseInteractionGen();
    const before = cx.frame_time_ms;
    cx.advanceFrameClock();
    try t.expectEqual(before + 16, cx.frame_time_ms);
    cx.layout();
    _ = cx.render();
    cx.last_tick_animations_active = true;
    cx.needs_redraw = false;
    const before_animation = cx.frame_time_ms;
    cx.advanceFrameClock();
    try t.expectEqual(before_animation + 16, cx.frame_time_ms);
    cx.layout();
    _ = cx.render();
    try t.expect(!cx.last_tick_animations_active);
}

/// Drive the same wants/clock/layout/render cycle used by the native host.
/// No forced frame budget and no manual dirty clearing: consumption must be
/// performed by the pipeline itself, including its last animation frame.
fn expectSceneConverges(cx: *Cx) !usize {
    const t = std.testing;
    var frames: usize = 0;
    while (cx.wantsFrame() and frames < 120) : (frames += 1) {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try t.expect(frames > 0 and frames < 120);
    try t.expect(!cx.wantsFrame());
    try t.expect(!cx.hasPendingSceneWork());
    const clock = cx.frame_time_ms;
    for (0..60) |_| {
        try t.expect(!cx.wantsFrame());
        // Even an incidental host query must keep the settled tree idle.
        cx.advanceFrameClock();
        try t.expect(!cx.wantsFrame());
        try t.expect(!cx.hasPendingSceneWork());
        try t.expectEqual(clock, cx.frame_time_ms);
    }
    return frames;
}

fn createConvergenceScene() !*Cx {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    errdefer cx.deinit();
    cx.setViewport(220, 120);
    cx.root = try core.box(cx, .{ .width = .{ .px = 220 }, .height = .{ .px = 120 } }, .{});
    const child = try core.box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 32 } }, .{});
    try cx.root.?.appendChild(cx.allocator, child);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    _ = try expectSceneConverges(cx);
    return cx;
}

test "host frame convergence consumes each loose interaction bit and stays idle" {
    const cx = try createConvergenceScene();
    defer cx.deinit();
    const child = cx.root.?.children.items[0];
    for (0..3) |bit| {
        switch (bit) {
            0 => child.frame_state.state_bits.dirty.hit.geometry = true,
            1 => child.frame_state.state_bits.dirty.hit.semantics = true,
            else => child.frame_state.state_bits.dirty.pipeline.interaction = true,
        }
        @import("node_dirty.zig").bumpLooseInteractionGen();
        try std.testing.expect(!cx.root.?.frame_state.state_bits.dirty.core.subtree_render);
        _ = try expectSceneConverges(cx);
        const d = child.frame_state.state_bits.dirty;
        try std.testing.expect(!d.hit.geometry and !d.hit.semantics and !d.pipeline.interaction);
    }
}

test "host frame convergence consumes the final real animation frame and stays idle" {
    const cx = try createConvergenceScene();
    defer cx.deinit();
    const child = cx.root.?.children.items[0];
    try child.applyTransition(cx.allocator, &comptime @import("../recipe.zig").transition("opacity 96ms linear"));
    child.setOpacity(0.25);
    try std.testing.expect(child.frame_state.frame_local.runtime.transitions.?.any_active);
    const frames = try expectSceneConverges(cx);
    try std.testing.expect(frames > 1);
    try std.testing.expect(!child.frame_state.frame_local.runtime.transitions.?.any_active);
    try std.testing.expect(!cx.last_tick_animations_active);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), child.getOpacity(), 0.001);
}

test "host frame convergence consumes hover geometry changes and stays idle" {
    const cx = try createConvergenceScene();
    defer cx.deinit();
    const child = cx.root.?.children.items[0];
    child.behavior.events.on_hover = Cx.simpleHandler(struct {
        fn onHover(context: *anyopaque) void {
            const node: *Node = @ptrCast(@alignCast(context));
            node.setWidth(120);
        }
    }.onHover, child);
    child.markHitSemanticsDirty();
    _ = try expectSceneConverges(cx);
    cx.handleMouseMove(20, 16);
    try std.testing.expect(cx.hovered_node == child);
    _ = try expectSceneConverges(cx);
    try std.testing.expectApproxEqAbs(@as(f32, 120), child.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expect(cx.hovered_node == child);
    try std.testing.expect(cx.hitTest(100, 16) == child);
}

/// Backdate last_frame_instant by delta_ns, fake a "previous frame happened
/// delta_ns ago" slow frame.
fn backdateLastFrame(cx: *Cx, delta_ns: u64) !void {
    var t = try @import("zenit_time").Instant.now(std.testing.io);
    t.timestamp -= delta_ns;
    cx.last_frame_instant = t;
}

test "frame clock stays wall-clock accurate when frames exceed the dt clamp" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    cx.root = root;
    defer {
        cx.freeNode(root);
        cx.root = null;
    }

    // Simulate 4fps heavy load: 250ms per frame, far exceeds 0.1s increment
    // clamp.
    const slow_frame_ns: u64 = 250 * std.time.ns_per_ms;
    const frames: u64 = 20;

    // Backdate epoch by full span, make now-epoch cover all 20 frames' real
    // time.
    var epoch = try @import("zenit_time").Instant.now(std.testing.io);
    epoch.timestamp -= @intCast(frames * slow_frame_ns);
    cx.clock_epoch = epoch;

    var i: u64 = 0;
    while (i < frames) : (i += 1) {
        cx.needs_redraw = true; // Ensure active path rather than idle early-exit.
        try backdateLastFrame(cx, slow_frame_ns);
        cx.advanceFrameClock();
    }

    // Regression: logic clock must keep pace with real elapsed time. Before
    // fix this was 2000ms (40% speed), shortfall 3000ms never recovered.
    const real_elapsed_ms: f64 = @floatFromInt(frames * slow_frame_ns / std.time.ns_per_ms);
    try testing.expect(cx.frame_time_ms > real_elapsed_ms * 0.95);

    // Increment dt must also be real frame interval: clamp to 0.1s makes
    // increment animation 40% slow at 4fps.
    try testing.expectApproxEqAbs(@as(f32, 0.25), cx.frame_dt_seconds, 0.01);

    // Wake from idle: blocking wait since last tick isn't animation time,
    // first frame advances one nominal frame.
    cx.frame_clock_was_idle = true;
    cx.needs_redraw = true;
    try backdateLastFrame(cx, 300 * std.time.ns_per_ms);
    cx.advanceFrameClock();
    try testing.expect(cx.frame_dt_seconds <= 1.0 / 60.0 + 1e-6);
    // Subsequent active frames restore real frame interval.
    cx.needs_redraw = true;
    try backdateLastFrame(cx, slow_frame_ns);
    cx.advanceFrameClock();
    try testing.expectApproxEqAbs(@as(f32, 0.25), cx.frame_dt_seconds, 0.01);
}

test "frame clock treats a host-skipped idle gap as idle, not as one long frame" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    cx.root = root;
    defer {
        cx.freeNode(root);
        cx.root = null;
    }

    cx.needs_redraw = true;
    try backdateLastFrame(cx, 16 * std.time.ns_per_ms);
    cx.advanceFrameClock();

    // After-frame tree clean (dirty defaults true, zeroed per-bit).
    const dirty = &root.frame_state.state_bits.dirty;
    dirty.core.layout = false;
    dirty.core.subtree_layout = false;
    dirty.core.render = false;
    dirty.core.subtree_render = false;
    dirty.pipeline.composite = false;
    dirty.pipeline.subtree_composite = false;
    dirty.pipeline.order = false;
    dirty.pipeline.subtree_order = false;
    dirty.pipeline.interaction = false;
    dirty.pipeline.subtree_interaction = false;
    dirty.runtime.dirty = false;
    dirty.runtime.subtree_dirty = false;
    cx.a11y_prefs_version = @import("../a11y/preferences.zig").version();

    // True host (Mac/Windows runtime) when wantsFrame() false skips whole
    // frame, blocks waiting, doesn't call advanceFrameClock; idle branch never
    // runs.
    try testing.expect(!cx.wantsFrame());
    try backdateLastFrame(cx, 700 * std.time.ns_per_ms);

    // Event wake: this frame just-started animation from event can't eat 700ms
    // blocking wait.
    cx.needs_redraw = true;
    cx.advanceFrameClock();
    try testing.expect(cx.frame_dt_seconds <= 1.0 / 60.0 + 1e-6);
}

test "frame clock freezes across idle frames and resumes without a time jump" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    cx.root = root;
    defer {
        cx.freeNode(root);
        cx.root = null;
    }

    // Run one active frame first to establish baseline.
    cx.needs_redraw = true;
    try backdateLastFrame(cx, 16 * std.time.ns_per_ms);
    cx.advanceFrameClock();
    const before_idle = cx.frame_time_ms;

    // Long idle: tree all clean + no overlay animation + no needs_redraw. Note
    // dirty defaults true (node.zig:545), `= {}` sets tree dirty not clean, must
    // zero per-bit, else this case walks active path, silently loses idle freeze
    // coverage.
    const dirty = &root.frame_state.state_bits.dirty;
    dirty.core.layout = false;
    dirty.core.subtree_layout = false;
    dirty.core.render = false;
    dirty.core.subtree_render = false;
    dirty.pipeline.composite = false;
    dirty.pipeline.subtree_composite = false;
    dirty.pipeline.order = false;
    dirty.pipeline.subtree_order = false;
    dirty.pipeline.interaction = false;
    dirty.pipeline.subtree_interaction = false;
    dirty.runtime.dirty = false;
    dirty.runtime.subtree_dirty = false;
    dirty.hit.geometry = false;
    dirty.hit.semantics = false;
    @import("node_dirty.zig").bumpLooseInteractionGen();
    try testing.expect(cx_render.isTreeFullyClean(cx, root));

    // Fake "this frame 1s since last" by backdate, meanwhile backdate epoch
    // same amount, simulate real idle walltime passed. If idle branch doesn't
    // cumulate clock_paused_ns, resume frame_time_ms adds whole idle at once ->
    // next resume assert fails.
    const idle_span_ns: u64 = 1 * std.time.ns_per_s;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        cx.needs_redraw = false;
        try backdateLastFrame(cx, idle_span_ns);
        cx.clock_epoch.?.timestamp -= idle_span_ns;
        cx.advanceFrameClock();
        // Logic clock must freeze during idle (zero-dirty fast-path depends on
        // time_unchanged).
        try testing.expectEqual(before_idle, cx.frame_time_ms);
    }

    // Resume active: this 5s idle can't pour into animation once (else overlay
    // jumps to end state).
    cx.needs_redraw = true;
    try backdateLastFrame(cx, 16 * std.time.ns_per_ms);
    cx.advanceFrameClock();
    const resumed_delta = cx.frame_time_ms - before_idle;
    try testing.expect(resumed_delta >= 0);
    try testing.expect(resumed_delta < 100);
}

test "frame clock keeps flowing while a compositor sprite animates an idle window" {
    // The compositor animates the sprite on the wall clock meanwhile; the first
    // frame after the hand-back must paint the picture it shows by then.
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const noop = struct {
        fn draw(_: @import("compositor_sprite.zig").DrawContext, _: ?*anyopaque, _: f64) anyerror!void {}
        fn repaint(_: ?*anyopaque) void {}
    };
    try cx.sprites.register(testing.allocator, 1, 1000, null, noop.draw, noop.repaint);
    cx.sprites.sources.items[0].active = true;

    cx.needs_redraw = true;
    try backdateLastFrame(cx, 16 * std.time.ns_per_ms);
    cx.advanceFrameClock();
    const before_idle = cx.frame_time_ms;
    // No root: nothing pending, so these are idle frames.
    const idle_span_ns: u64 = 1 * std.time.ns_per_s;
    for (0..5) |_| {
        cx.needs_redraw = false;
        try backdateLastFrame(cx, idle_span_ns);
        cx.clock_epoch.?.timestamp -= idle_span_ns;
        cx.advanceFrameClock();
        try testing.expectEqual(before_idle, cx.frame_time_ms);
    }
    cx.needs_redraw = true;
    try backdateLastFrame(cx, 16 * std.time.ns_per_ms);
    cx.advanceFrameClock();
    try testing.expect(cx.frame_time_ms - before_idle >= 5000);
}

test "freeNode disposes attached node scope" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    try bindScopeToNode(scope, node);

    const Marker = struct {
        disposed: *bool,
    };
    var disposed = false;
    var marker = Marker{ .disposed = &disposed };
    try scope.registerResource(@ptrCast(&marker), struct {
        fn destroy(ptr: *anyopaque, _: Allocator) void {
            const typed: *Marker = @ptrCast(@alignCast(ptr));
            typed.disposed.* = true;
        }
    }.destroy);

    cx.freeNode(node);
    try testing.expect(disposed);
}

test "freeDetachedNodeAfterScopeDispose clears stale child scope pointers" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const parent_scope = try Scope.init(testing.allocator, null, cx.owner);
    var parent_scope_disposed = false;
    defer if (!parent_scope_disposed) parent_scope.dispose();

    const orphan_root = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    const child = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    try orphan_root.appendChild(testing.allocator, child);

    const child_scope = try parent_scope.childScope();
    try bindScopeToNode(child_scope, child);

    var child_scope_disposed = false;
    try child_scope.registerResource(@ptrCast(&child_scope_disposed), struct {
        fn destroy(ptr: *anyopaque, _: Allocator) void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    }.destroy);

    var root_cleaned = false;
    orphan_root.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
        fn cleanup(ptr: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    }.cleanup, @ptrCast(&root_cleaned));

    var child_cleaned = false;
    child.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
        fn cleanup(ptr: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    }.cleanup, @ptrCast(&child_cleaned));

    const CleanupCtx = struct {
        cx: *Cx,
        node: *Node,
    };
    var cleanup_ctx = CleanupCtx{ .cx = cx, .node = orphan_root };
    try parent_scope.registerResource(@ptrCast(&cleanup_ctx), struct {
        fn destroy(ptr: *anyopaque, _: Allocator) void {
            const ctx: *CleanupCtx = @ptrCast(@alignCast(ptr));
            ctx.cx.freeDetachedNodeAfterScopeDispose(ctx.node);
        }
    }.destroy);

    parent_scope.dispose();
    parent_scope_disposed = true;

    try testing.expect(child_scope_disposed);
    try testing.expect(root_cleaned);
    try testing.expect(child_cleaned);
}

test "clearNodeScopes invalidates scope binding before node free" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const parent_scope = try Scope.init(testing.allocator, null, cx.owner);
    var parent_scope_disposed = false;
    defer if (!parent_scope_disposed) parent_scope.dispose();

    const node = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    const child_scope = try parent_scope.childScope();
    try bindScopeToNode(child_scope, node);

    clearNodeScopes(node);
    cx.freeNode(node);

    parent_scope.dispose();
    parent_scope_disposed = true;
}

test "freeNode releases zero-length owned text content" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    node.setText(.{
        .content = try testing.allocator.dupe(u8, ""),
        .owned = true,
    });

    cx.freeNode(node);
}

test "text builder mirrors content into World.content" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.text(cx, "hello", .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.content.getText(eid).?;
    try testing.expectEqualSlices(u8, "hello", mirrored.content);

    // In-place field still source of truth (stage 1 dual-write period).
    try testing.expectEqualSlices(u8, "hello", node.getText().?.content);
}

test "image builder mirrors texture_id into World.content" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.image(cx, 42, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    defer cx.freeNode(node);
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.content.get(eid).?;
    try testing.expectEqual(@as(u32, 42), mirrored.image.?.texture_id);
    try testing.expectEqual(@as(u32, 42), node.getImage().?.texture_id);
}

test "setImage replaces and clears a retained image across frames without manual dirtying" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.setWindowMetrics(200, 100, 1);
    const node = try image(cx, 41, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    cx.root = try core.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{node});
    for (0..2) |_| _ = cx.render();
    for ([_]?u32{ 42, null, 43 }) |texture| {
        node.setImage(if (texture) |id| .{ .texture_id = id } else null);
        for (0..2) |_| {
            _ = cx.render();
            var seen: ?u32 = null;
            for (cx.lowerForEncoderPaintTable()) |item| {
                if (item.kind == .image) {
                    try t.expect(seen == null);
                    seen = @intCast(item.resource_handle);
                }
            }
            try t.expectEqual(texture, seen);
        }
        const version = node.meta.per_frame.caches.versions.content;
        node.setImage(node.getImage());
        try t.expectEqual(version, node.meta.per_frame.caches.versions.content);
        try t.expect(!node.frame_state.state_bits.dirty.core.layout);
    }
}

test "setBackground mirrors into World.paint_state" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    const red = Color.rgba(255, 0, 0, 255);
    node.setBackground(red);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectEqual(@as(u8, 255), mirrored.background.r);
    try testing.expectEqual(@as(u8, 0), mirrored.background.g);
    try testing.expectEqual(@as(u8, 255), node.getBackground().r);
}

test "setOpacity mirrors into World.paint_state" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);

    node.setOpacity(0.5);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), mirrored.opacity, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), node.getOpacity(), 0.001);
}

test "setBackgroundRaw mirrors World but skips dirty/transition" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    // Configure node background transition: setBackground walks interpolation
    // branch, setBackgroundRaw must **bypass** it, write directly.
    try node.enableImplicitAnimation(cx.allocator, &.{.background}, .{ .duration_ms = 200 });

    const blue = Color.rgba(0, 0, 255, 255);
    node.setBackgroundRaw(blue);

    // 1. In-place field write directly (non-interpolation starting point).
    try testing.expectEqual(@as(u8, 255), node.getBackground().b);
    // 2. Mirror to World.paint_state.
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectEqual(@as(u8, 255), mirrored.background.b);
    // 3. Transition slot not activated (Raw bypasses interpolation).
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.find(.background)) |slot| {
            try testing.expect(!slot.active);
        }
    }
}

test "setOpacityRaw mirrors World, no transition activation" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);

    try node.enableImplicitAnimation(cx.allocator, &.{.opacity}, .{ .duration_ms = 200 });

    node.setOpacityRaw(0.3);

    try testing.expectApproxEqAbs(@as(f32, 0.3), node.getOpacity(), 0.001);
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectApproxEqAbs(@as(f32, 0.3), mirrored.opacity, 0.001);
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.find(.opacity)) |slot| {
            try testing.expect(!slot.active);
        }
    }
}

test "setLayoutOutput/getLayoutOutput 走 World (无 in-place 字段)" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    var lo: core_node.NodeLayoutOutput = .{};
    lo.artifacts.children_bbox = .{ .x = 1, .y = 2, .w = 30, .h = 40 };
    lo.vector.stroke.width = 2.5;
    node.setLayoutOutput(lo);

    // getLayoutOutput walks World read callback (World is source of truth).
    try testing.expectEqual(@as(f32, 30), node.getLayoutOutput().artifacts.children_bbox.?.w);
    try testing.expectEqual(@as(f32, 2.5), node.getLayoutOutput().vector.stroke.width);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const stored = cx.world.layout_output.get(eid).?;
    try testing.expectEqual(@as(f32, 30), stored.artifacts.children_bbox.?.w);
}

test "layoutOutputPtr 原地改子字段直写 World" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);

    // owner/layout_engine path uses layoutOutputPtr get stable World slot
    // address, mutate in-place.
    const lo = node.layoutOutputPtr().?;
    lo.artifacts.children_bbox = .{ .x = 0, .y = 0, .w = 77, .h = 0 };

    // No in-place fields; getLayoutOutput reads World should see changes.
    try testing.expectEqual(@as(f32, 77), node.getLayoutOutput().artifacts.children_bbox.?.w);
}

test "LayoutOutputTable node free reclaims text and late access cannot resurrect a generation" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try builders.box(cx, .{}, .{});
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const cached_layout = @import("text_layout.zig").TextLayout{ .line_count = 3 };
    try node.storeTextLayout(&cached_layout);
    const borrow = cx.world.layout_output.borrowText(eid).?;
    try std.testing.expectEqual(@as(usize, 1), cx.world.layout_output.memoryStats().text_layout_live_slots);
    cx.freeNode(node);
    try std.testing.expect(borrow.resolve(&cx.world.layout_output) == null);
    try std.testing.expectEqual(@as(usize, 0), cx.world.layout_output.memoryStats().text_layout_live_slots);
    const pca = @import("paint_content_accessor.zig");
    try std.testing.expect(pca.layoutOutputPtr(&cx.world, eid.raw(), 0) == null);
    pca.writeLayoutOutput(&cx.world, eid.raw(), 0, .{});
    try std.testing.expect(cx.world.layout_output.get(eid) == null);
}

test "LayoutOutputTable standalone node destroy reclaims its payload and output" {
    const pca = @import("paint_content_accessor.zig");
    const before = pca.standaloneEntryCount();
    const node = try core_node.Node.create(std.testing.allocator, 123456, .box, .{});
    const cached_layout = @import("text_layout.zig").TextLayout{ .line_count = 3 };
    try node.storeTextLayout(&cached_layout);
    try std.testing.expect(pca.standaloneEntryCount() == before + 1);
    node.destroy(std.testing.allocator);
    try std.testing.expectEqual(before, pca.standaloneEntryCount());
}

test "主题运行时切换 (dark / light / high_contrast)" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    // Initially dark.
    try testing.expectEqualStrings("dark", cx.tokens.name);

    cx.setTheme(&theme.light);
    try testing.expectEqualStrings("light", cx.tokens.name);
    try testing.expect(cx.needs_redraw);

    cx.setTheme(&theme.high_contrast);
    try testing.expectEqualStrings("high_contrast", cx.tokens.name);
    // high_contrast near-black background (neutral.950).
    try testing.expectEqual(@as(u8, 0x0A), cx.tokens.tokens.color.bg_base.r);
    try testing.expectEqual(@as(u8, 0x0A), cx.tokens.tokens.color.bg_base.g);
    try testing.expectEqual(@as(u8, 0x0A), cx.tokens.tokens.color.bg_base.b);
    // Pure white foreground.
    try testing.expectEqual(@as(u8, 255), cx.tokens.tokens.color.fg_primary.r);
}

test "setTheme 触发 before_render hook + theme_version 自增" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const Probe = struct {
        var fire_count: u32 = 0;
        fn hook(_: *Node) void {
            fire_count += 1;
        }
    };
    Probe.fire_count = 0;

    const root = try builders.box(cx, .{}, .{});
    cx.root = root;
    root.meta.per_frame.hooks.before_render.main = &Probe.hook;

    const child = try builders.box(cx, .{}, .{});
    try root.appendChild(testing.allocator, child);
    child.meta.per_frame.hooks.before_render.main = &Probe.hook;

    const initial_version = cx.theme_version;
    cx.setTheme(&theme.light);

    try testing.expect(cx.theme_version == initial_version +% 1);
    try testing.expectEqual(@as(u32, 2), Probe.fire_count);
    try testing.expect(cx.needs_redraw);

    cx.setTheme(&theme.light);
    try testing.expectEqual(@as(u32, 2), Probe.fire_count);
}

test "theme Signal 化: themeSignal 惰性创建 + setTheme 驱动 set" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const sig = try cx.themeSignal();
    // Repeated calls return same Signal.
    try testing.expectEqual(sig, try cx.themeSignal());
    try testing.expectEqualStrings("dark", sig.get().name);

    cx.setTheme(&theme.light);
    try testing.expectEqualStrings("light", sig.get().name);
}

// Window replacement on one Cx (zeditor Global Find / palette): the old window's Input asked
// for the theme first, the new window's style effects hold the same Signal, then the old
// window is freed. When the Signal belonged to the first caller's root scope it died with the
// old window and the new window's next style run read freed memory. The Cx owns it now.
test "themeSignal 归 Cx 所有：最先请求它的 Scope 释放后，其他持有者读到的仍是活的 Signal" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const old_window = try Scope.init(testing.allocator, null, cx.owner);
    const new_window = try Scope.init(testing.allocator, null, cx.owner);
    defer new_window.dispose();

    // The old window is the current window root when its component asks first.
    cx.root_scope = old_window;
    _ = try cx.themeSignal();
    const Reader = struct {
        sig: *Signal(*const theme.ThemeTokens),
        seen: []const u8 = "",
        fn run(self: *@This()) void {
            self.seen = self.sig.get().name;
        }
    };
    var reader: Reader = .{ .sig = try cx.themeSignal() };
    try new_window.createEffect(&reader, Reader.run);
    try testing.expectEqualStrings("dark", reader.seen);

    cx.root_scope = null;
    old_window.dispose();
    // Same live Signal for everyone after the first caller is gone.
    try testing.expectEqual(reader.sig, try cx.themeSignal());
    cx.setTheme(&theme.light);
    try testing.expectEqualStrings("light", reader.seen);
    try testing.expectEqualStrings("light", reader.sig.get().name);
}

// A dispose callback that asks for the theme gets the live Cx Signal, never one being freed.
test "dispose 期间回调里再取 themeSignal 不得拿到野指针" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const Probe = struct {
        cx: *Cx,
        name: []const u8 = "",

        fn destroy(ptr: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const sig = self.cx.themeSignal() catch return;
            self.name = sig.get().name;
        }
    };
    var probe = Probe{ .cx = cx };

    {
        const panel_scope = try Scope.init(testing.allocator, null, cx.owner);
        _ = try cx.themeSignal();
        try panel_scope.registerResource(@ptrCast(&probe), Probe.destroy);
        panel_scope.dispose();
    }

    try testing.expectEqualStrings("dark", probe.name);
}

test "Cx 服务 Signal（theme / a11y 偏好）在任何 OOM 点都不半建、不泄漏" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const cx = try Cx.init(a, std.testing.io);
            defer cx.deinit();
            const sig = try cx.themeSignal();
            try testing.expect(cx.theme_signal == sig);
            const prefs = try cx.a11yPreferencesSignal();
            try testing.expect(cx.a11y_prefs_signal == prefs);
            try testing.expectEqual(sig, try cx.themeSignal());
        }
    }.run, .{});
}

test "boxStyled/textStyled: setTheme 重放具名样式函数（含 paint_state 背景路径）" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const S = struct {
        fn card(t: *const theme.ThemeTokens) core_types.BoxStyle {
            return .{
                .background = t.tokens.color.bg_primary,
                .padding = core_types.Padding.all(t.tokens.space.space400),
                .text_color = t.tokens.color.fg_primary,
            };
        }
        fn label(t: *const theme.ThemeTokens) builders.TextStyle {
            return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.md };
        }
    };

    const root = try builders.boxStyled(cx, S.card, .{});
    cx.root = root;
    const label_node = try builders.textStyled(cx, S.label, "hello");
    try root.appendChild(testing.allocator, label_node);

    // DevTools precise origin: named style field points original style fn;
    // undeclared field doesn't claim source. TextStyle three trackable fields
    // same hang on label fn.
    const card_addr = @intFromPtr(&S.card);
    try testing.expectEqual(card_addr, root.styleOrigin(.background).?.address);
    try testing.expectEqual(world.StyleOriginKind.styled, root.styleOrigin(.padding).?.kind);
    try testing.expect(root.styleOrigin(.gap) == null);
    try testing.expectEqual(@intFromPtr(&S.label), label_node.styleOrigin(.text_color).?.address);

    root.setStyle(null, .translate_x, @as(f32, 7));
    const translate_origin = root.styleOrigin(.translate_x).?;
    try testing.expectEqual(world.StyleOriginKind.set_style, translate_origin.kind);
    try testing.expect(translate_origin.address != 0);

    // Apply dark value on mount (background walks paint_state, not in Style).
    try testing.expectEqual(theme.dark.tokens.color.bg_primary, root.getBackground());
    try testing.expectEqual(theme.dark.tokens.color.fg_primary, label_node.getText().?.color);
    // on_theme not before_render hook: doesn't poison promoted cache
    // eligibility.
    try testing.expect(!root.hasBeforeRenderHooks());
    try testing.expect(!label_node.hasBeforeRenderHooks());

    cx.setTheme(&theme.light);

    // Background must follow (history pit: applyTo alone background doesn't
    // update).
    try testing.expectEqual(theme.light.tokens.color.bg_primary, root.getBackground());
    try testing.expectEqual(theme.light.tokens.color.fg_primary, label_node.getText().?.color);
    try testing.expectEqual(theme.light.tokens.color.fg_primary, root.style.ext.?.text_color.?);
    // Layout dirty marked (style fn might output layout fields).
    try testing.expect(root.frame_state.state_bits.dirty.core.layout);

    // Regular box unaffected: no on_theme, no hook.
    const plain = try builders.box(cx, .{ .background = theme.dark.tokens.color.bg_secondary }, .{});
    try root.appendChild(testing.allocator, plain);
    try testing.expect(plain.meta.per_frame.hooks.on_theme == null);
}

test "invalidateSubtreeHookState 摘除 on_theme hook" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const S = struct {
        fn card(t: *const theme.ThemeTokens) core_types.BoxStyle {
            return .{ .background = t.tokens.color.bg_primary };
        }
    };

    const node = try builders.boxStyled(cx, S.card, .{});
    cx.root = node;
    try testing.expect(node.meta.per_frame.hooks.on_theme != null);

    hooks_mod.invalidateSubtreeHookState(node);
    try testing.expect(node.meta.per_frame.hooks.on_theme == null);
}

test "textFmt updates content when a source signal changes" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const count = try scope.createSignal(u32, 1);
    const label = try textFmt(cx, scope, "count = {d}", .{count}, .{});
    cx.root = label;

    try std.testing.expectEqualStrings("count = 1", label.getText().?.content);
    count.set(42);
    try std.testing.expectEqualStrings("count = 42", label.getText().?.content);
}

test "textFmt long content falls back to heap without truncation" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const n = try scope.createSignal(u64, 7);
    const label = try textFmt(cx, scope, (@as([("x").len * (70)]u8, @bitCast(@as([70][("x").len]u8, @splat(("x").*)))) ++ "") ++ "{d}", .{n}, .{});
    cx.root = label;

    try std.testing.expect(label.getText().?.content.len == 71);
    n.set(1234);
    try std.testing.expect(label.getText().?.content.len == 74);
}

test "Cx.handleDrag: source-completion kind(4) 与未知 kind 不 panic" {
    // Regression lock: kind=4 is beginDrag completion receipt (system_sdk
    // layer docs), before direct @enumFromInt into DragEvent.Kind(0..3), any drag
    // session release "invalid enum value" panic. Real device script verify_interop_probe.sh
    // caught.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    cx.handleDrag(10, 10, 4, "");
    cx.handleDrag(10, 10, 255, "");
    try std.testing.expect(cx.needs_redraw);
}

test "Cx.handleCommand: 无焦点时全树回退找 action context（wrapper root 不再吞菜单命令）" {
    // Regression lock: cx.root is App's internal wrapper,
    // dispatchAction walks up from focus, user mount on root binds context never
    // reaches, true menu click silent loss (verify_menu.sh caught). Fix = ignored
    // when find first match node whole tree.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const wrapper = try Node.create(std.testing.allocator, cx.nextId(), .box, .{});
    const child = try Node.create(std.testing.allocator, cx.nextId(), .box, .{});
    try wrapper.appendChild(std.testing.allocator, child);
    cx.root = wrapper;
    defer {
        cx.root = null;
        wrapper.destroy(std.testing.allocator);
    }

    const S = struct {
        var fired: bool = false;
        fn onAction(action: actions_mod.Action, context: ?*anyopaque) events_mod.EventResult {
            _ = context;
            if (std.mem.eql(u8, action.name, "ping")) fired = true;
            return .handled;
        }
    };
    S.fired = false;
    child.behavior.interaction.key_context = "probe";
    child.behavior.events.on_action = S.onAction;
    cx.bindCommandAction(100, .{ .context = "probe", .name = "ping" });

    cx.handleCommand(100);
    try std.testing.expect(S.fired);
}

test "Cx.handler requires existing state" {
    const CounterState = struct {
        value: u32 = 0,

        fn increment(self: *@This()) void {
            self.value += 1;
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    try std.testing.expectError(error.StateNotFound, cx.handler(CounterState, 1, CounterState.increment));
}

test "Cx.handler binds to explicit state" {
    const CounterState = struct {
        value: u32 = 0,

        fn increment(self: *@This()) void {
            self.value += 1;
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const state = try cx.state(CounterState, 7, .{});
    const ref = try cx.handler(CounterState, 7, CounterState.increment);
    ref.callback(ref.context);

    try std.testing.expectEqual(@as(u32, 1), state.value);
    try std.testing.expect(state == cx.getState(CounterState, 7).?);
}

test "光标测量：shape 钩子装与不装必须同宽（ASCII / ASCII+emoji / CJK）" {
    // == What this test pins ==. measureTextWidthWithSpans is **not a pure function of its
    // parameters**: measureProportional first tries the GlyphRun shape hook, NaN falls back to
    // measure_ctx_fn / measure_fn. So the same text and params give two answers depending on
    // whether the hook is installed: - layout+draw: no hook -> measure_ctx_fn branch (App's
    // FontSelector) - cursor/selection/hit: computeCursorPos installs hook -> shape pipeline
    // font. If the two paths pick different Fonts, the cursor drifts systematically from glyph
    // edges (even pure ASCII; emoji just makes the gap visible).
    // Fix: rig the shape pipeline with setShapeFontResolver so it and the measure end grab the
    // same *Font. This test simulates that wiring and asserts both paths give equal width.
    // It intentionally **doesn't hardcode pixel values** (drift per OS font version); "two paths
    // must equal" is the bug shape and the invariant to maintain.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // One concrete font feeds both paths, equivalent to App.setFontSelector
    // minimal model.
    const base = try fonts.findFont(.{ .family = "Helvetica Neue", .size = 14 });
    defer base.deinit();

    const Bridge = struct {
        var the_font: ?*text_module.Font = null;
        fn measure(ctx: *anyopaque, ptr: [*]const u8, len: usize, size: f32, _: u16, _: bool) f32 {
            _ = ctx;
            const f = the_font.?;
            const scale = size / f.pixelSize();
            return f.measureWidth(ptr[0..len]) * scale;
        }
        fn resolve(ctx: *anyopaque, _: []const u8, _: f32, _: u16, _: bool, _: bool, _: u16) ?*text_module.Font {
            _ = ctx;
            return the_font;
        }
    };
    Bridge.the_font = base;
    var dummy: u8 = 0;
    cx.text.measure_ctx_fn = &Bridge.measure;
    cx.text.measure_ctx = @ptrCast(&dummy);
    text_layout.setMeasureCtxFn(&Bridge.measure, @ptrCast(&dummy));
    defer text_layout.setMeasureCtxFn(null, null);
    layout_engine.setShapeFontResolver(&Bridge.resolve, @ptrCast(&dummy));
    defer layout_engine.setShapeFontResolver(null, null);

    const tl = text_layout;
    const cases = [_][]const u8{
        "ssdf x", // Pure ASCII -- user explicitly reported English is also off, must cover.
        "ssdf x\u{1F60A}", // ASCII + emoji (original reproduce string).
        "\u{4E2D}\u{6587}\u{6D4B}\u{8BD5}", // CJK walks fallback font, another parsing branch.
        "abc\u{4E2D}d\u{1F60A}e", // Three mixed: cross three font parse paths in one line.
    };

    for (cases) |content| {
        const end: u32 = @intCast(content.len);
        // No hook (layout/draw path).
        const no_hook = tl.measureTextWidthWithSpans(content, 0, end, 14, 450, false, false, &.{});
        // Hook installed (cursor/selection path).
        var guard = cx.text.beginExternalTextMeasure();
        const with_hook = tl.measureTextWidthWithSpans(content, 0, end, 14, 450, false, false, &.{});
        guard.end();

        try std.testing.expect(no_hook > 0);
        try std.testing.expect(with_hook > 0);
        // Subpixel-level agreement. 0.01 just tolerate f32 cumulative noise;
        // real bug when delta integer-pixel (measured 1.442 / 3.783).
        try std.testing.expectApproxEqAbs(no_hook, with_hook, 0.01);
    }
}

test "光标测量：前缀宽度沿整行单调且末项等于整串" {
    // Companion anchor: previous ensures "two paths same width", this ensures
    // "prefix cumulative == full string". computeCursorPos positions cursor by
    // [0, col) prefix, so prefix sequence must monotone non-decreasing, last item
    // equals full string width, line-end cursor lands text right edge by this
    // equation.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const tl = text_layout;
    var guard = cx.text.beginExternalTextMeasure();
    defer guard.end();

    for ([_][]const u8{ "ssdf x", "ssdf x\u{1F60A}", "\u{4E2D}\u{6587}abc" }) |content| {
        const total = tl.measureTextWidthWithSpans(content, 0, @intCast(content.len), 14, 450, false, false, &.{});
        var prev: f32 = 0;
        var i: u32 = 1;
        while (i <= content.len) : (i += 1) {
            // Prefix only at UTF-8 boundaries (slicing emoji mid-cluster meaningless).
            if (i < content.len and (content[i] & 0xC0) == 0x80) continue;
            const w = tl.measureTextWidthWithSpans(content, 0, i, 14, 450, false, false, &.{});
            try std.testing.expect(w >= prev - 0.001);
            prev = w;
        }
        try std.testing.expectApproxEqAbs(total, prev, 0.01);
    }
}

test "shapeVisualLine extracts CoreText grapheme and mixed-bidi caret geometry" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{5D0}\u{5D1}\u{5D2} 12";
    var owned = try cx.text.shapeVisualLine(.{
        .text = content,
        .font_family = "system",
        .font_size = 16,
    });
    defer owned.deinit();
    try owned.value.validate(content);
    try std.testing.expect(owned.value.width > 0);
    try std.testing.expect(owned.value.ascent > 0);

    var has_visual_reverse = false;
    for (owned.value.caret_stops[0 .. owned.value.caret_stops.len - 1], owned.value.caret_stops[1..]) |left, right| {
        if (right.position.byte.value < left.position.byte.value) has_visual_reverse = true;
    }
    try std.testing.expect(has_visual_reverse);

    const emoji = "A👩‍💻B";
    var emoji_line = try cx.text.shapeVisualLine(.{
        .text = emoji,
        .font_family = "system",
        .font_size = 18,
    });
    defer emoji_line.deinit();
    try emoji_line.value.validate(emoji);
    // A + one ZWJ grapheme + B yields exactly four logical boundaries; CoreText
    // may add secondary bidi carets, but must never expose interior scalar stops.
    for (emoji_line.value.caret_stops) |stop| {
        try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(emoji, stop.position.byte.value));
    }

    const cached_a = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    const cached_b = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    try std.testing.expect(cached_a.caret_stops.ptr == cached_b.caret_stops.ptr);
}

test "shapeVisualLine paragraph base direction follows UAX 9 outside isolates" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // The first glyph run is RTL, but P2 ignores strong characters inside the
    // leading isolate and therefore finds the following Latin paragraph text.
    const ltr = "\u{2067}\u{05D0}\u{05D1}\u{2069}abc";
    var ltr_line = try cx.text.shapeVisualLine(.{ .text = ltr, .font_family = "system", .font_size = 16 });
    defer ltr_line.deinit();
    try std.testing.expectEqual(text_core_module.text_coordinates.Direction.ltr, ltr_line.value.base_direction);

    // Symmetric case: isolated Latin does not override the Hebrew paragraph.
    const rtl = "\u{2066}abc\u{2069}\u{05D0}\u{05D1}";
    var rtl_line = try cx.text.shapeVisualLine(.{ .text = rtl, .font_family = "system", .font_size = 16 });
    defer rtl_line.deinit();
    try std.testing.expectEqual(text_core_module.text_coordinates.Direction.rtl, rtl_line.value.base_direction);
}

// Contract lock: measureTextWidth must be same-origin as the GlyphRun pipeline
// (render/cursor/selection use shapeText "system"). Two measure paths coexisting with no
// cross-consistency test is the structural reason ~1.5% Latin drift survived; red here =
// the pipeline split again.
test "measureTextWidth 与 shapeText 跨管线一致（下游回归）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // Cover disparity picture back then: long Latin (max diff), short Latin,
    // digits (coincide), CJK (consistent), mixed, CJK+SMP emoji (cascade
    // disparity case).
    const corpus = [_][]const u8{
        "The quick brown fox jumps over the lazy dog wonderful",
        "df",
        "Mixed",
        "123",
        "我们都好",
        "混排 Mixed 123",
        "sf工有\u{1F236}要在",
        "Hi \u{1F44B} emoji \u{1F389}\u{1F525} 测试 \u{1F600} end",
    };
    for (corpus) |s| {
        const run = try cx.text.shapeText(.{ .text = s, .font_family = "system", .font_size = 16 });
        const measured = cx.text.measureTextWidth(s, 16, 400, false);
        try std.testing.expectApproxEqAbs(run.total_advance, measured, 0.01);
    }
}

// Emoji must force-font cover ZWJ sequences whole. Per-codepoint cover leaves BMP ZWJ in
// the base font run, and CTLine can't knit across runs: a ZWJ family emoji fragments from a
// single 21px glyph into three person shapes at 63px (measure/render/caret all equally
// broken, so the rest of the suite stays green).
test "ZWJ emoji 序列塑形不碎裂（#36 审查回归）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const adv = struct {
        fn of(c: *Cx, s: []const u8) !f32 {
            const run = try c.text.shapeText(.{ .text = s, .font_family = "system", .font_size = 16 });
            return run.total_advance;
        }
    }.of;

    const one_person = try adv(cx, "\u{1F468}");
    // Family sequence (👨 ZWJ 👩 ZWJ 👧) = single glyph, width ≈ single
    // member.
    try std.testing.expectApproxEqAbs(one_person, try adv(cx, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), 0.5);
    // ❤️‍🔥 (BMP member 2764+VS16 ZWJ sequence) = single glyph.
    try std.testing.expectApproxEqAbs(try adv(cx, "\u{1F525}"), try adv(cx, "\u{2764}\u{FE0F}\u{200D}\u{1F525}"), 0.5);
    // Skin tone modifier and flags (multi-codepoint clusters sans ZWJ) also
    // keep single glyph.
    try std.testing.expectApproxEqAbs(try adv(cx, "\u{1F44B}"), try adv(cx, "\u{1F44B}\u{1F3FB}"), 0.5);
    try std.testing.expectApproxEqAbs(one_person, try adv(cx, "\u{1F1FA}\u{1F1F8}"), 0.5);
}

// CoreText cascade is context-dependent: U+1F236 isolated uses Apple Color Emoji (~1.33em),
// but after a CJK run gets picked by PingFang (1em). Force emoji font so advance is
// context-independent (CJK has no cross-char kerning, so whole width = sum of parts holds;
// render per-codepoint segment vs measure whole CTLine consistency depends on this property).
test "SMP emoji advance 与 run 上下文无关（下游回归）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const adv = struct {
        fn of(c: *Cx, s: []const u8) !f32 {
            const run = try c.text.shapeText(.{ .text = s, .font_family = "system", .font_size = 16 });
            return run.total_advance;
        }
    }.of;

    const cjk = try adv(cx, "工有");
    const yo = try adv(cx, "\u{1F236}");
    try std.testing.expectApproxEqAbs(cjk + yo, try adv(cx, "工有\u{1F236}"), 0.05);
    // Isolated 🈶 must emoji render (~1.33em), not PingFang 1em.
    try std.testing.expect(yo > 16.5);
}

// Caret x and selection width for wide glyph/multi-codepoint must equal
// true shaping measure. Each caret stop x must exactly match that prefix's shaping
// width (not codepoint*constant, not a UTF-16-unit estimate); selection
// middle glyph selectionRects width must equal that glyph advance (= prefix
// diff). Failure shape: caret left, selection only left half (width halved).
test "caret x 与选区宽度 = 真实 shaping 度量（emoji/CJK/组合/ZWJ）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const cases = [_][]const u8{
        "a\u{1F60A}b", // Single-codepoint SMP emoji (surrogate pair).
        "a\u{4E2D}\u{6587}b", // CJK full-width.
        "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b", // ZWJ family.
        "ae\u{0301}b", // Combining diacritic.
        "a\u{2764}\u{FE0F}b", // BMP + VS16 variant selector.
        "a\u{1F44B}\u{1F3FB}b", // Skin tone modifier.
    };
    const font_size: f32 = 24;
    for (cases) |s| {
        const line = try cx.text.visualLine(.{ .text = s, .font_family = "system", .font_size = font_size });

        // 1) Each caret stop x == that prefix true shaping width.
        for (line.caret_stops) |stop| {
            const byte = stop.position.byte.value;
            try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(s, byte));
            const prefix = cx.text.measureTextWidth(s[0..byte], font_size, 400, false);
            try std.testing.expectApproxEqAbs(prefix, stop.x.value, 0.05);
        }

        // 2) Select middle glyph (drop first/last 'a'/'b'): selection width ==
        // that glyph advance.
        const glyph_start: usize = 1;
        const glyph_end: usize = s.len - 1;
        var storage: [8]text_core_module.text_coordinates.SelectionRect = undefined;
        const rects = try line.selectionRects(
            .{ .value = glyph_start },
            .{ .value = glyph_end },
            &storage,
        );
        try std.testing.expectEqual(@as(usize, 1), rects.len);
        const x0 = cx.text.measureTextWidth(s[0..glyph_start], font_size, 400, false);
        const x1 = cx.text.measureTextWidth(s[0..glyph_end], font_size, 400, false);
        try std.testing.expectApproxEqAbs(x0, rects[0].x, 0.05);
        try std.testing.expectApproxEqAbs(x1 - x0, rects[0].width, 0.05);
        // Wide glyph can't degrade half-width: middle glyph at least visible
        // width.
        try std.testing.expect(rects[0].width > 1.0);
    }
}

// Click-hit regression: click glyph center, cursor must land some glyph
// boundary (not inside cluster), click glyph right-half snap right boundary,
// emoji caret stops left (symmetric side).
test "点击命中在宽字形上吸附到字形边界（emoji/CJK/ZWJ）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // Each example exactly one middle glyph (click snap target unique).
    const cases = [_][]const u8{
        "a\u{1F60A}b",
        "a\u{4E2D}b",
        "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b",
        "a\u{1F44B}\u{1F3FB}b",
    };
    const font_size: f32 = 24;
    for (cases) |s| {
        const line = try cx.text.visualLine(.{ .text = s, .font_family = "system", .font_size = font_size });
        const glyph_start: usize = 1;
        const glyph_end: usize = s.len - 1;
        const x0 = cx.text.measureTextWidth(s[0..glyph_start], font_size, 400, false);
        const x1 = cx.text.measureTextWidth(s[0..glyph_end], font_size, 400, false);

        // Click 75% right -> snap glyph right boundary.
        const right = line.xToPosition(.{ .value = x0 + (x1 - x0) * 0.75 });
        try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(s, right.byte.value));
        try std.testing.expectEqual(glyph_end, right.byte.value);

        // Click 25% left -> snap glyph left boundary.
        const left = line.xToPosition(.{ .value = x0 + (x1 - x0) * 0.25 });
        try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(s, left.byte.value));
        try std.testing.expectEqual(glyph_start, left.byte.value);
    }
}

// A byte-index prefix can fall inside a 3-byte CJK char (e.g. "asfd" + emoji + half = 9B
// invalid UTF-8). CoreText NSString construction then fails, the shape layer reports
// TextShapingFailed, the FontSelector bridge silently returns 0.0f, and measureTextWidth
// ends up exactly 0.00, collapsing the bbox. Fix: entry first trims to the longest legal
// UTF-8 prefix.
test "measureTextWidth 对截断 UTF-8（半个 CJK）不塌成 0" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // Simulate app-side FontSelector bridge: return 0 for invalid UTF-8 (nil
    // NSString path). Before fix truncated string hits this leg -> exact 0.00;
    // after fix shapeText succeeds first, never reaches here.
    const Bridge = struct {
        fn zeroOnInvalid(_: *anyopaque, ptr: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            return if (std.unicode.utf8ValidateSlice(ptr[0..len])) 999 else 0;
        }
    };
    var dummy: u8 = 0;
    cx.text.measure_ctx_fn = Bridge.zeroOnInvalid;
    cx.text.measure_ctx = @ptrCast(&dummy);

    const valid = "asfd\u{1F3A9}";
    const trunc = "asfd\u{1F3A9}\xe4"; // 9B: valid + first byte of one, invalid UTF-8.
    try std.testing.expect(!std.unicode.utf8ValidateSlice(trunc));

    const w_valid = cx.text.measureTextWidth(valid, 16, 400, false);
    const w_trunc = cx.text.measureTextWidth(trunc, 16, 400, false);
    try std.testing.expect(w_valid > 0);
    // Truncated string by longest legal prefix measure = valid width (no
    // longer 0, not bridge 999).
    try std.testing.expectApproxEqAbs(w_valid, w_trunc, 0.01);

    // Prefix all invalid (first byte continuation) no prefix to trim, still
    // return 0.
    try std.testing.expectEqual(@as(f32, 0), cx.text.measureTextWidth("\x80\x80", 16, 400, false));
}

test "shapeText 的缓存必须按 font_family 分桶（字体选择器预览的前置条件）" {
    // == bug shape == shapingKey used to always write font_id=0 and didn't put
    // family into text_hash, so the same text with a different family re-shape hits the
    // **previous family's** cache entry and returns the wrong glyphs+width. Hidden normally,
    // since all prod call-sites pass literal "system" (sole family). But a font selector
    // preview list draws the same string (e.g., "Aa") in different families, so line 2+
    // degraded to line 1's font.
    // Doesn't hardcode pixels (drift per OS font version); asserts "two very different fonts
    // can't measure the same width", which is the bug shape.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const probe = "Aa Bb";
    const helv = try cx.text.shapeText(.{
        .text = probe,
        .font_family = "Helvetica Neue",
        .font_size = 16,
    });
    // Zapfino is calligraphy, same string much wider; both can't same-width.
    const zapf = try cx.text.shapeText(.{
        .text = probe,
        .font_family = "Zapfino",
        .font_size = 16,
    });

    try std.testing.expect(helv.total_advance > 0);
    try std.testing.expect(zapf.total_advance > 0);
    try std.testing.expect(helv.total_advance != zapf.total_advance);

    // Reverse fetch again: cache-hit path also must bucket-separate (can't
    // second fetch slip back).
    const helv2 = try cx.text.shapeText(.{
        .text = probe,
        .font_family = "Helvetica Neue",
        .font_size = 16,
    });
    try std.testing.expectEqual(helv.total_advance, helv2.total_advance);
}

test "生存哨兵：新建节点是 ALIVE" {
    // A sentinel negative check can't "use-after-free read" in a test, that is UAF
    // itself and GPA reports first. Manual negative repro: comment
    // out the sentinel check at freeNodeNow entry, call freeNode twice on the same node;
    // in Debug the second call reads the 0xaa-overwritten `freeing` (true) and silently
    // early-returns, exactly what the sentinel eliminates. With the sentinel the second call
    // panics.
    const ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const n = try builders.box(ctx, .{ .width = .{ .px = 10 } }, .{});
    try std.testing.expect(n.alive_sentinel == core_node.ALIVE_SENTINEL);
    ctx.freeNode(n);
}

test "ensurePopoverPortalRoot: 构建中途 OOM 回滚回收 ElementTable slot" {
    // errdefer original portal.destroy: Node.destroy doesn't call
    // world.destroyElement, each failure leaks element slot (and mirror-table
    // row). Inject failures each alloc point.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const ctx = try Cx.init(fa.allocator(), std.testing.io);
    defer ctx.deinit();
    const root_node = try builders.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root_node;
    // Preheat: World element table / style source table etc. amortized
    // expand, first box more alloc than after. Without preheat k increments
    // while box needs decrement, handily skips "after box" failure point.
    ctx.freeNode(try builders.box(ctx, .{ .position = .absolute }, .{}));

    var saw_failure_after_box = false;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        const before = ctx.world.elements.count();
        fa.fail_index = fa.alloc_index + k;
        const result = ctx.ensurePopoverPortalRoot();
        fa.fail_index = std.math.maxInt(usize);
        if (result) |portal| {
            try std.testing.expectEqual(portal, ctx.popover_portal_root.?);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(ctx.popover_portal_root == null);
            try std.testing.expectEqual(@as(usize, 0), root_node.children.items.len);
            if (k > 0) saw_failure_after_box = true;
            try std.testing.expectEqual(before, ctx.world.elements.count());
        }
    }
    try std.testing.expect(k < 64);
    try std.testing.expect(saw_failure_after_box);
}

test "NodeRegistry: 节点释放后 generations 不再只增不减" {
    const ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root_node = try builders.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root_node;
    const baseline = ctx.node_registry.generations.count();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const n = try builders.box(ctx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
        try root_node.appendChild(std.testing.allocator, n);
        try ctx.node_registry.rebuild(ctx.root);
        const h = ctx.node_registry.handleFor(n);
        try std.testing.expectEqual(n, ctx.node_registry.resolve(h, null).?);
        ctx.detachChild(root_node, n);
        ctx.freeNode(n);
        // After-free old handle must fail parse, identity invalid.
        try std.testing.expect(ctx.node_registry.resolve(h, null) == null);
    }
    try ctx.node_registry.rebuild(ctx.root);
    try std.testing.expect(ctx.node_registry.generations.count() <= baseline + 1);
}

/// Observer: effect reads a, b two signals, tally runs, record ever see
/// half-updated a != b state. Common to next two host entry batch-test.
const PairProbe = struct {
    a: *Signal(u32),
    b: *Signal(u32),
    runs: u32 = 0,
    saw_torn: bool = false,

    fn writeBoth(ctx: ?*anyopaque) void {
        const self: *PairProbe = @ptrCast(@alignCast(ctx.?));
        const next = self.a.peek() + 1;
        self.a.set(next);
        self.b.set(next);
    }

    fn writeBothHandler(ctx: *anyopaque) void {
        writeBoth(ctx);
    }

    fn install(self: *PairProbe, scope: *Scope) !void {
        try scope.createEffect(self, struct {
            fn run(p: *PairProbe) void {
                if (p.a.get() != p.b.get()) p.saw_torn = true;
                p.runs += 1;
            }
        }.run);
    }
};

test "host-entry batch: 事件 handler 连续写多个 signal：effect 只跑一次且看不到半更新状态" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    var probe = PairProbe{
        .a = try scope.createSignal(u32, 0),
        .b = try scope.createSignal(u32, 0),
    };
    try probe.install(scope);
    try std.testing.expectEqual(@as(u32, 1), probe.runs);

    const btn = core.clickable(
        try core.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{}),
        Cx.simpleHandler(PairProbe.writeBothHandler, &probe),
    );
    cx.root = btn;
    cx.layout();
    cx.handleClick(50, 20);

    try std.testing.expectEqual(@as(u32, 1), probe.a.peek());
    try std.testing.expectEqual(@as(u32, 2), probe.runs);
    try std.testing.expect(!probe.saw_torn);
}

test "host-entry batch: 定时器回调连续写多个 signal：effect 只跑一次且看不到半更新状态" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    var probe = PairProbe{
        .a = try scope.createSignal(u32, 0),
        .b = try scope.createSignal(u32, 0),
    };
    try probe.install(scope);

    _ = try cx.setTimer(0, PairProbe.writeBoth, &probe);
    cx.fireDueTimers();

    try std.testing.expectEqual(@as(u32, 1), probe.a.peek());
    try std.testing.expectEqual(@as(u32, 2), probe.runs);
    try std.testing.expect(!probe.saw_torn);
}

test "cx.on infers the payload: fn(*S) gives HandlerRef, fn(*S, T) gives Handler(T)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const S = struct {
        clicks: u32 = 0,
        volume: f32 = 0,
        fn click(s: *@This()) void {
            s.clicks += 1;
        }
        fn setVolume(s: *@This(), v: f32) void {
            s.volume = v;
        }
    };
    const st = try cx.bindState(S, .{});
    const click = cx.on(S, st, S.click);
    const set_volume = cx.on(S, st, S.setVolume);
    comptime std.debug.assert(@TypeOf(click) == core.HandlerRef);
    comptime std.debug.assert(@TypeOf(set_volume) == core.Handler(f32));
    // Function pointers (callers often pass method as param) also can infer.
    const click_ptr: *const fn (*S) void = S.click;
    const vol_ptr: *const fn (*S, f32) void = S.setVolume;
    comptime std.debug.assert(@TypeOf(cx.on(S, st, click_ptr)) == core.HandlerRef);
    comptime std.debug.assert(@TypeOf(cx.on(S, st, vol_ptr)) == core.Handler(f32));
    click.invoke();
    set_volume.call(0.5);
    try std.testing.expectEqual(@as(u32, 1), st.clicks);
    try std.testing.expectEqual(@as(f32, 0.5), st.volume);
}

test "textFmt accepts derived values, memos and static values" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const last = try scope.createSignal(?bool, null);
    const word = @import("../reactive.zig").map(last, struct {
        fn f(v: ?bool) []const u8 {
            return if (v) |c| (if (c) "checked" else "unchecked") else "(none)";
        }
    }.f);
    const label = try textFmt(cx, scope, "{s} changed → {s}", .{ "box", word }, .{});
    cx.root = label;
    try std.testing.expectEqualStrings("box changed → (none)", label.getText().?.content);
    last.set(true);
    try std.testing.expectEqualStrings("box changed → checked", label.getText().?.content);
}

test "host entries bind this Cx's animation clock (multi-window: the clock is global)" {
    const render_engine = @import("render_engine/mod.zig");
    var a = try Cx.init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    var b = try Cx.init(std.testing.allocator, std.testing.io);
    defer b.deinit();
    // Window A last frame-out: global clock stop at A's time.
    a.frame_time_ms = 50_000;
    a.bindFrameClock();
    try std.testing.expectEqual(@as(f64, 50_000), render_engine.current_frame_time_ms);

    const Probe = struct {
        var seen: f64 = -1;
        fn cb(_: ?*anyopaque) void {
            seen = render_engine.current_frame_time_ms;
        }
    };
    Probe.seen = -1;
    // Window B (frame clock 1234) timer callback spawn animation must use B's
    // clock.
    b.frame_time_ms = 1234;
    _ = try b.setTimer(0, Probe.cb, null);
    b.fireDueTimers();
    try std.testing.expectEqual(@as(f64, 1234), Probe.seen);

    // Entry return restore pre-entry clock (here A's), don't leave B's clock
    // for after-code.
    try std.testing.expectEqual(@as(f64, 50_000), render_engine.current_frame_time_ms);
    b.handleKeyDown(.space, .{});
    try std.testing.expectEqual(@as(f64, 50_000), render_engine.current_frame_time_ms);
}

test "nested host entries across windows: the outer window gets its clock back" {
    const render_engine = @import("render_engine/mod.zig");
    var a = try Cx.init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    var b = try Cx.init(std.testing.allocator, std.testing.io);
    defer b.deinit();
    a.frame_time_ms = 1234;
    b.frame_time_ms = 50_000;

    // Window A timer callback sync-drive window B (e.g., forward input to
    // other window), then spawn animation in A.
    const Probe = struct {
        var other: *Cx = undefined;
        var inside_b: f64 = -1;
        var after_b: f64 = -1;
        fn cb(_: ?*anyopaque) void {
            const Inner = struct {
                fn cb(_: ?*anyopaque) void {
                    inside_b = render_engine.current_frame_time_ms;
                }
            };
            _ = other.setTimer(0, Inner.cb, null) catch return;
            other.fireDueTimers();
            after_b = render_engine.current_frame_time_ms;
        }
    };
    Probe.other = b;
    Probe.inside_b = -1;
    Probe.after_b = -1;
    _ = try a.setTimer(0, Probe.cb, null);
    a.fireDueTimers();
    try std.testing.expectEqual(@as(f64, 50_000), Probe.inside_b);
    try std.testing.expectEqual(@as(f64, 1234), Probe.after_b);
}

test "transition setters: writing the current value never starts a transition" {
    const recipe_mod = @import("../recipe.zig");
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const n = try builders.box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.hex(0x336699) }, .{});
    defer cx.freeNode(n);
    n.setOpacityRaw(1);
    try n.applyTransition(cx.allocator, &comptime recipe_mod.transition("background 150ms ease-out, border-color 150ms ease-out, opacity 150ms ease-out"));
    // Slot just built (to_* still default): write same value as current is
    // no-op.
    n.setBackground(Color.hex(0x336699));
    n.setBorderColor(n.style.border.color);
    n.setOpacity(1);
    try std.testing.expect(!n.frame_state.frame_local.runtime.transitions.?.any_active);
    // True change triggers startup.
    n.setOpacity(0);
    try std.testing.expect(n.frame_state.frame_local.runtime.transitions.?.any_active);
}

test "theme replay skips an independent root destroyed by an earlier hook" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    defer cx.freeNode(root);
    cx.root = root;
    defer cx.root = null;
    const overlay = try core.box(cx, .{}, .{});
    const handle = try cx.overlay_stack.push(.{ .kind = .non_modal, .enter_transition = .none });
    defer cx.overlay_stack.removePermanently(handle);
    cx.overlay_stack.bindContentNode(cx.allocator, handle, overlay);
    const Probe = struct {
        var context: *Cx = undefined;
        var victim: *Node = undefined;
        fn hook(_: *Node, _: *const theme.Values, _: Allocator) void {
            context.destroyDetached(victim);
        }
    };
    Probe.context = cx;
    Probe.victim = overlay;
    root.meta.per_frame.hooks.on_theme = Probe.hook;
    cx.setTheme(&theme.modes.light);
}

test "caret declaration wakes fallback hosts without consuming an ordinary redraw" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.needs_redraw = false;
    cx.a11y_prefs_version = @import("../a11y/preferences.zig").version();
    cx.setBlinkCaretPhase(true, 0, 500 * std.time.ns_per_ms);
    cx.caret_flip_host = true;
    try std.testing.expect(!cx.wantsFrame());
    try std.testing.expectEqual(@as(?u64, 0), cx.nextWakeDelayNs());
    cx.caret_flip_host = false;
    try std.testing.expect(cx.wantsFrame());
    cx.caret_paint_override = false;
    try std.testing.expect(!cx.blinkCaretVisible(true));
    cx.caret_paint_override = null;
    try std.testing.expect(cx.blinkCaretVisible(true));
}

test "caret rectangle admission rejects nonfinite empty and overflow declarations" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.addBlinkCaretRect(.{ 0, 0, 0, 10 });
    cx.addBlinkCaretRect(.{ std.math.nan(f32), 0, 2, 10 });
    try std.testing.expectEqual(@as(usize, 0), cx.caret_rect_count);
    for (0..65) |_| cx.addBlinkCaretRect(.{ 10.25, 20.5, 2, 18 });
    try std.testing.expectEqual(@as(usize, 64), cx.caret_rect_count);
    try std.testing.expect(cx.caret_rect_overflow);
}

test "Cx shutdown keeps timer cancellation storage alive through scope cleanup" {
    const Resource = struct {
        cx: *Cx,
        id: u64,
        cancelled: *bool,
        fn callback(_: ?*anyopaque) void {}
        fn cleanup(self: *@This()) void {
            self.cx.clearTimer(self.id);
            // Cleanup may also replace a scheduled task while the owner is
            // shutting down. It must use live storage and leave no exit leak.
            const replacement = self.cx.setTimer(0, callback, null) catch unreachable;
            self.cx.clearTimer(replacement);
            self.cancelled.* = true;
        }
    };
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    cx.root_scope = try Scope.init(std.testing.allocator, null, cx.owner);
    var cancelled = false;
    const resource = try cx.root_scope.?.createState(Resource, .{ .cx = cx, .id = try cx.setTimer(0, Resource.callback, null), .cancelled = &cancelled });
    try cx.root_scope.?.onCleanup(Resource, resource, Resource.cleanup);
    cx.deinit();
    try std.testing.expect(cancelled);
}

test "inactive windows suppress caret paint and wake declarations until activation" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.window_active = false;
    cx.caret_paint_override = true;
    try t.expect(!cx.blinkCaretVisible(true));
    cx.setBlinkCaretPhase(true, 100, 200);
    cx.addBlinkCaretRect(.{ 0, 0, 1, 10 });
    try t.expect(!cx.caret_phase_valid);
    try t.expectEqual(@as(usize, 0), cx.caret_rect_count);
    cx.window_active = true;
    try t.expect(cx.blinkCaretVisible(true));
    cx.setBlinkCaretPhase(true, 100, 200);
    cx.addBlinkCaretRect(.{ 0, 0, 1, 10 });
    try t.expect(cx.caret_phase_valid);
    try t.expectEqual(@as(usize, 1), cx.caret_rect_count);
}

test "a one-off frame-arena spike is released by the next render instead of pinned" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.setViewport(320, 120);
    const root = try core.box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 120 } }, .{});
    cx.root = root;
    cx.layout();
    _ = cx.render();
    // An application parses a whole document with the frame allocator once.
    const spike = 4 * cx_render.frame_arena_retain_limit;
    _ = try cx.frame_arena.allocator().alloc(u8, spike);
    try t.expect(cx.frame_arena.queryCapacity() >= spike);
    cx.needs_redraw = true;
    root.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try t.expect(cx.frame_arena.queryCapacity() <= cx_render.frame_arena_spike_keep);
    // Ordinary frames below the limit keep their capacity (no malloc churn).
    _ = try cx.frame_arena.allocator().alloc(u8, cx_render.frame_arena_retain_limit / 4);
    const steady = cx.frame_arena.queryCapacity();
    root.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try t.expectEqual(steady, cx.frame_arena.queryCapacity());
}
