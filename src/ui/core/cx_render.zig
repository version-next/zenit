//! Cx frame pipeline: render() (before-render tick -> layout -> after-layout hooks ->
//! runtime indexing -> layerize -> display list), encoder paint table downgrade,
//! redraw dispatch, and scene-fresh before hit-test (ensureHitTestSceneFresh).

const std = @import("std");

/// Frame-arena capacity up to which ordinary frames keep reusing their buffer
/// (see the reset in `render`).
pub const frame_arena_retain_limit: usize = 16 * 1024 * 1024;
/// Capacity kept after a frame went beyond `frame_arena_retain_limit`.
pub const frame_arena_spike_keep: usize = 2 * 1024 * 1024;
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_frame = @import("cx_frame.zig");
const cx_bulk_quads = @import("cx_bulk_quads.zig");
const PartialInteractionRoots = cx_runtime_index.PartialInteractionRoots;
const AfterLayoutOutcome = struct { ran_layout: bool = false, interaction_dirty: bool = false };
const text_core_module = @import("text_core");
const AfterLayoutFn = core.AfterLayoutFn;
const ComputedRect = core.ComputedRect;
const LayoutContext = layout_engine.LayoutContext;
const LayoutTable = core.LayoutTable;
const Node = core.Node;
const cx_cursor = @import("cx_cursor.zig");
const cx_node_lifetime = @import("cx_node_lifetime.zig");
const cx_runtime_index = @import("cx_runtime_index.zig");
const node_tree = @import("node_tree.zig");
const debug_env = @import("debug_env.zig");
const display_list = core.display_list;
const display_list_mod = @import("display_list.zig");
const hitSceneDebugEnabled = debug_env.hitSceneDebugEnabled;
const layoutIntegrityEveryFrameEnabled = debug_env.layoutIntegrityEveryFrameEnabled;
const layout_engine = core.layout_engine;
const max_after_layout_rounds = core.max_after_layout_rounds;
const paint_table = core.paint_table;
const renderDirtyDebugEnabled = debug_env.renderDirtyDebugEnabled;
const render_engine = core.render_engine;
const text = core.text;

fn startPerfTimer(self: *const Cx) @import("zenit_time").Timer {
    // Cx.init validated this I/O clock when creating deferred_epoch. A frame
    // only needs a fresh sample; querying its resolution again adds a syscall
    // to every measured phase and used to leave an undefined timer on failure.
    var timer: @import("zenit_time").Timer = .{ .io = self.io, .started = self.deferred_epoch };
    timer.reset();
    return timer;
}

test "frame timers reuse clock validation and keep window I/O independent" {
    const Clock = struct {
        value: i96,
        resolutions: usize = 0,
        fn now(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const clock: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = clock.value };
        }
        fn resolution(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
            const clock: *@This() = @ptrCast(@alignCast(raw.?));
            clock.resolutions += 1;
            return .{ .nanoseconds = 1 };
        }
    };
    var a: Clock = .{ .value = 100 };
    var b: Clock = .{ .value = 1000 };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    vtable.clockResolution = Clock.resolution;
    // Only the two clock fields are consumed by this private helper.
    var ca: Cx = undefined;
    ca.io = .{ .userdata = &a, .vtable = &vtable };
    ca.deferred_epoch = try @import("zenit_time").Instant.now(ca.io);
    var cb: Cx = undefined;
    cb.io = .{ .userdata = &b, .vtable = &vtable };
    cb.deferred_epoch = try @import("zenit_time").Instant.now(cb.io);
    a.value = 200;
    b.value = 2000;
    var ta = startPerfTimer(&ca);
    var tb = startPerfTimer(&cb);
    a.value = 225;
    b.value = 2075;
    try std.testing.expectEqual(@as(u64, 25), ta.read());
    try std.testing.expectEqual(@as(u64, 75), tb.read());
    ta = startPerfTimer(&ca);
    a.value = 250;
    try std.testing.expectEqual(@as(u64, 25), ta.read());
    try std.testing.expectEqual(@as(usize, 1), a.resolutions);
    try std.testing.expectEqual(@as(usize, 1), b.resolutions);
}

pub fn render(self: *Cx) []const display_list_mod.DisplayItem {
    // system a11y pref change (reduce motion / lower transparency): whole tree invalidate must
    // ahead of zero-dirty fast-path.
    self.syncA11yPreferences();
    // timer callbacks run first: nodes they mark dirty must catch this frame (not skip zero-dirty
    // path).
    self.fireDueTimers();
    // overlay exit done restore focus to control opened it.
    // WARNING: **ahead of zero-dirty fast-path**: after close overlay often exactly zero-dirty,
    // place after it'd early-return skip, focus never restore.
    cx_node_lifetime.drainOverlayFocusRestore(self);
    // Hover under a stationary pointer follows the committed scene (the geometry on screen):
    // scroll, layout or mount changes since hover was last resolved re-hit the pointer once.
    // Ahead of the zero-dirty fast path (a scene committed at event time still re-resolves) and
    // of the before-render tick (callbacks act like a move delivered just before this frame).
    self.reconcileStationaryHover();

    // zero-dirty fast-path: root fully-clean + prior frame cache valid return cache.
    // perf #1 matrix: 10k-node zero-dirty < 0.5ms key skip.
    // Safety: no pending scene work (including non-bubbling interaction bits
    // and active animations), and no inspector/virtual pointer paint.
    if (self.root != null) {
        const time_unchanged = self.frame_time_ms == self.last_render_frame_time_ms;
        if (self.last_render_valid and
            time_unchanged and
            // The bulk rect layer is resubmitted every frame by the host and zenit does no
            // cross-frame diff,
            // so it cannot detect content changes -> conservative redraw by default (see
            // setBulkQuads).
            // A host that can prove "same batch as last frame" via setBulkQuadsVersioned lets a
            // static
            // picture return to zero-dirty; for a 20k-quad canvas this is 21.6ms vs ~0 per frame.
            (self.bulk_quads.items.len == 0 or self.bulk_quads_unchanged) and
            // Match the host's frame gate. Loose hit/interaction bits do not
            // bubble into paint/layout flags, but still need before-render
            // index refresh. Returning the cache leaves that work pending.
            !self.hasPendingSceneWork() and
            // The automated virtual pointer is **drawn in the real render target**
            // (screenshots/recordings
            // show it) but has no Node tree, so moving it leaves the whole tree clean. Without
            // this, a pure
            // mouse_move (no node change) takes the zero-dirty early return and overlay code never
            // runs,
            // so the harness virtual mouse never draws. Visible = counted as dirty; invisible =
            // zero cost.
            !self.virtual_cursor.visible and
            !self.inspector.enabled and
            !self.inspector.debug_paint.anyActive())
        {
            self.perf.resetFrame();
            return self.display_list.items.items;
        }
    }
    // Reset the frame arena, freeing all prior-frame temporaries. Ordinary
    // frames keep their capacity and reuse it without touching malloc; after a
    // one-off spike beyond `frame_arena_retain_limit` (an application parsing a
    // whole document with the frame allocator on open) only
    // `frame_arena_spike_keep` is kept instead of pinning the spike for the
    // window's lifetime. The arena may only shrink here, at the start of a
    // render: the previous display list can still point into it.
    _ = self.frame_arena.reset(if (self.frame_arena.queryCapacity() > frame_arena_retain_limit)
        .{ .retain_with_limit = frame_arena_spike_keep }
    else
        .retain_capacity);
    self.perf.resetFrame();
    const render_cpu_start = @import("zenit_time").threadCpuTimestamp(self.io);
    defer self.perf.render_cpu_us = @intCast(@max(@import("zenit_time").threadCpuTimestamp(self.io) - render_cpu_start, 0) / 1000);
    // gesture_arena tick, long_press time-related recognizer advance by this.
    // must call before render pass; else long_press began emit then dispatch
    // render (one-frame extra delay, user feel lag).
    if (self.gesture_arena.recognizers.items.len != 0) {
        self.gesture_arena.tick(@import("zenit_time").nanoTimestamp(self.io));
    }
    // advance ShapingCache epoch; prior-frame unreached entry driven out at config threshold
    // frames. GlyphRun pipeline inherit old measure path so text measure
    // single cache layer.
    self.text.beginFrame();
    self.lowering.main_paint.clearRetainingCapacity();
    if (self.root) |r| {
        // OverlayStack: unified outside-click dismissal on press release (before the flag clears)
        // mouseDown + render between virtual list / condition render may freed hit node.
        // bare pointer kept for sync-event compat only; cross-frame consume must re-parse
        // handle with generation, avoid OverlayStack.isDescendantOf dangling parent chain.
        const outside_click_target = self.node_registry.resolve(self.last_mouse_down_handle, &self.perf);
        self.last_mouse_down_target = outside_click_target;
        if (outside_click_target == null) self.last_mouse_down_handle = null;
        // Each release against the press it ended: a later press in the same batch has
        // overwritten the press fields.
        for (self.press_releases[0..self.press_release_count]) |rel| {
            const press_target = self.node_registry.resolve(rel.press_handle, &self.perf);
            self.overlay_stack.handleOutsideRelease(true, press_target, rel.press_owner, rel.press_mark);
        }
        if (self.press_release_count == 0) self.overlay_stack.handleOutsideRelease(false, outside_click_target, self.press_overlay_owner, self.outside_press_mark);
        self.press_release_count = 0;

        const tick_mod = @import("render_engine/tick.zig");
        tick_mod.g_tick_node_count = 0;
        tick_mod.g_tick_quiet_skip_count = 0;
        tick_mod.g_tick_hook_count = 0;
        tick_mod.g_slow_hook_us = 0;
        tick_mod.g_slow_hook_name_len = 0;
        tick_mod.g_debug_frame = self.frame_count;
        tick_mod.g_debug_dirty_hooks = 0;
        var bt = startPerfTimer(self);
        const br_cpu_start = @import("zenit_time").threadCpuTimestamp(self.io);
        const trace_instr = @import("zenit_environment").flag("ZENIT_PERF_TRACE");
        const instrNow = struct {
            fn f(on: bool) u64 {
                return if (on) @import("zenit_time").threadInstructions() else 0;
            }
        }.f;
        var ri = instrNow(trace_instr);
        const instrLap = struct {
            fn f(on: bool, mark: *u64) u64 {
                if (!on) return 0;
                const now = @import("zenit_time").threadInstructions();
                defer mark.* = now;
                return (now -| mark.*) / 1000;
            }
        }.f;
        ensureBeforeRenderTicked(self);
        // After the tick (which must not see it as a frame request): nodes the
        // compositor animates are painted at this frame's time.
        self.sprites.refreshActive();
        self.perf.ri_before_render_k = instrLap(trace_instr, &ri);
        self.perf.before_render_us = bt.read() / 1000;
        self.perf.before_render_cpu_us = @intCast(@max(@import("zenit_time").threadCpuTimestamp(self.io) - br_cpu_start, 0) / 1000);
        self.perf.tick_nodes = tick_mod.g_tick_node_count;
        self.perf.tick_quiet_skips = tick_mod.g_tick_quiet_skip_count;
        self.perf.tick_hooks = tick_mod.g_tick_hook_count;
        self.perf.slow_hook_us = tick_mod.g_slow_hook_us;
        const sn_len = tick_mod.g_slow_hook_name_len;
        const sn_max = @min(sn_len, self.perf.slow_hook_name.len);
        @memcpy(self.perf.slow_hook_name[0..sn_max], tick_mod.g_slow_hook_name[0..sn_max]);
        self.perf.slow_hook_name_len = sn_max;
        // DEBUG: print render_dirty nodes every 300 frames
        if (renderDirtyDebugEnabled() and self.frame_count % 300 == 1) {
            cx_frame.debugPrintRenderDirtyNodes(self, r);
        }
        // on_before_render consumed has_new_mouse_down, clear
        self.has_new_mouse_down = false;
        self.has_new_press_release = false;
        self.press_release_count = 0;

        // OverlayStack: update anchor geometry first, after layout done advance animation time.
        self.overlay_stack.updateAnchors(self.viewport.width, self.viewport.height);

        // Pass 1.5: incremental layout
        // Cx.init already validated this clock. Reuse bt's I/O binding and
        // sample a new epoch without querying clock resolution a second time.
        var inner_timer = bt;
        inner_timer.reset();
        if (r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        self.perf.inner_layout_us = inner_timer.lap() / 1000;
        self.perf.ri_layout_k = instrLap(trace_instr, &ri);

        const animations_active = self.overlay_stack.tickAnimations(self.frame_time_ms, self.frame_dt_seconds, self.allocator);
        if (animations_active) {
            self.needs_redraw = true;
        }

        // Pass 2: render command generation
        var render_ctx = render_engine.RenderContext{
            .lowering_buffer = &self.lowering._dead_main,
            .lowering_buffer_paint = &self.lowering.main_paint,
            .display_list = &self.display_list,
            .text_blob_store = &self.text_blob_store,
            .scene_runtime = &self.scene_runtime,
            .property_tree = &self.property_tree,
            .layer_tree = &self.layer_tree,
            .world = &self.world,
            .allocator = self.allocator,
            .frame_allocator = self.frame_arena.allocator(),
            .viewport = self.viewport,
            .perf = &self.perf,
            .external_clip_rects = &self.external_clip_rects,
            // transport GlyphRun pipeline resource to render engine
            .shaping_cache = &self.text.shaping_cache,
            .font_system = self.text.font_system,
            .measure_font_context = self.text.font_resolve_ctx,
            .measure_font_fn = self.text.font_props_measure_fn,
            .visual_line_context = self,
            .visual_line_fn = &renderVisualLine,
        };
        const render_node_start = inner_timer.read();
        // main_paint is cleared and fully re-lowered from the display list below.
        render_ctx.paint_pass_lowering = false;
        render_engine.renderNode(&render_ctx, r) catch |err| {
            std.debug.print("[ui] renderNode error: {}\n", .{err});
        };
        self.perf.render_node_us = (inner_timer.read() - render_node_start) / 1000;
        self.perf.ri_render_node_k = instrLap(trace_instr, &ri);
        if (verifyIncrementalEnabled()) verifyIncrementalAgainstFull(self, &render_ctx, r);

        // bulk rect layer: absolute viewport coords => use identity transform (id 0).
        // hierarchy/clip by host anchor (see setBulkQuads): insert to anchor subtree end
        // bring its clip_id.
        cx_bulk_quads.appendBulkQuads(self) catch |err| {
            std.debug.print("[ui] bulk quad append error: {}\n", .{err});
        };

        // Stage B R3f: derive + inspector overlay still run at cx.render() end (compat
        // test expect cx.lowering.main readable immediately after cx.render()). lowerForEncoder
        // for encoder call, **idempotent**, filled return directly, no repeat derive.
        self.lowering._dead_main.clearRetainingCapacity();
        self.lowering.main_paint.clearRetainingCapacity();
        const lowering_mod = @import("render_engine/display_list_lowering.zig");
        // correctness path: main_paint just clearRetainingCapacity, here whole-frame
        // display item re-lower in. OOM leave **truncated** paint list
        // (begin/end layer mismatched, second-half tree no-draw), render() return is it
        // screen silently broken not clean fail.
        if (@import("zenit_environment").flag("ZENIT_DEBUG_DLIST")) {
            std.debug.print("[dlist] ── frame {d} items={d} ──\n", .{ self.scene_runtime.frame_epoch, self.display_list.items.items.len });
            for (self.display_list.items.items, 0..) |it, di| {
                const h = it.header();
                switch (it) {
                    .text_run => |t| std.debug.print("[dlist] {d}: text node={d} eff={d} clip={d} \"{s}\"\n", .{ di, h.node_id, h.effect_id, h.clip_id, t.content[0..@min(t.content.len, 12)] }),
                    .fill_rect => |fr| std.debug.print("[dlist] {d}: rect node={d} eff={d} clip={d} ({d:.0},{d:.0},{d:.0}x{d:.0}) r={d:.3} a={d}\n", .{ di, h.node_id, h.effect_id, h.clip_id, fr.x, fr.y, fr.w, fr.h, fr.radius[0], fr.color.a }),
                    // stroke-width / corner-radius "content property scale" regression validate
                    // observation point
                    // (downstream app: stroke + corner == world * scale).
                    .stroke_rect => |sr| std.debug.print("[dlist] {d}: stroke node={d} eff={d} clip={d} ({d:.1},{d:.1},{d:.1}x{d:.1}) w={d:.3} r={d:.3}\n", .{ di, h.node_id, h.effect_id, h.clip_id, sr.x, sr.y, sr.w, sr.h, sr.width, sr.radius[0] }),
                    .border_side => |bs| std.debug.print("[dlist] {d}: border node={d} eff={d} clip={d} ({d:.1},{d:.1},{d:.1}x{d:.1}) w={d:.3} r={d:.3}\n", .{ di, h.node_id, h.effect_id, h.clip_id, bs.x, bs.y, bs.w, bs.h, bs.width, bs.radius[0] }),
                    else => std.debug.print("[dlist] {d}: {s} node={d} eff={d} clip={d}\n", .{ di, @tagName(it), h.node_id, h.effect_id, h.clip_id }),
                }
            }
        }
        // Timed as `phase_prebuild_us`: lowering walks the whole display
        // list every frame and was the largest untimed region inside
        // render(), so a slow frame here looked like unattributed
        // `render_us`.
        const lower_start = inner_timer.read();
        _ = instrLap(trace_instr, &ri);
        render_ctx.paint_pass_lowering = true;
        self.sprites.beginLowering();
        if (self.sprites.hasSources()) render_ctx.sprite_probe = &self.sprites;
        lowering_mod.appendAllDisplayItemsToRenderList(&render_ctx) catch @panic("OOM: lower display list into main render list");
        render_ctx.sprite_probe = null;
        if (self.sprites.hasSources()) {
            if (self.sprites.afterLowering(self.allocator, .{
                .scene_runtime = &self.scene_runtime,
                .property_tree = &self.property_tree,
                .display_list = self.display_list.items.items,
                .scale = self.window_scale,
                .frame_time_ms = self.frame_time_ms,
                // The frame clock skips idle gaps; settling is real elapsed
                // time unless a harness steps the clock.
                .settle_clock_ms = if (self.test_frame_step_ms != null)
                    self.frame_time_ms
                else
                    @as(f64, @floatFromInt(@import("zenit_time").monotonicTimestamp(self.io))) / std.time.ns_per_ms,
                .reduced_motion = render_engine.current_reduced_motion,
                .flipbook_hz = self.sprites.flipbook_hz,
                .max_atlas_bytes = self.sprites.max_atlas_bytes,
                .replay_in_place = self.sprites.replay_in_place,
            })) self.needs_redraw = true;
        }
        self.perf.phase_prebuild_us = (inner_timer.read() - lower_start) / 1000;
        self.perf.ri_lowering_k = instrLap(trace_instr, &ri);
        if (@import("zenit_environment").flag("ZENIT_DEBUG_SURFDUMP")) {
            var in_surf: bool = false;
            var counts: [64]u32 = @splat(0);
            for (self.lowering.main_paint.items) |it| {
                const k = @backingInt(it.kind);
                if (it.kind == .control and it.control_kind == .begin_opacity_layer) {
                    in_surf = true;
                    std.debug.print("[surfdump] f={d} BEGIN op={d:.2}\n", .{ self.scene_runtime.frame_epoch, it.opacity });
                } else if (in_surf and it.kind == .control and it.control_kind == .end_opacity_layer) {
                    in_surf = false;
                    std.debug.print("[surfdump] f={d} END counts:", .{self.scene_runtime.frame_epoch});
                    for (counts, 0..) |c, ki| {
                        if (c > 0) std.debug.print(" {s}={d}", .{ @tagName(@as(@TypeOf(it.kind), @fromBackingInt(@intCast(ki)))), c });
                    }
                    std.debug.print("\n", .{});
                    counts = @splat(0);
                } else if (in_surf) {
                    if (k < counts.len) counts[k] += 1;
                    std.debug.print("[surfitem] {s} x={d:.1} y={d:.1} w={d:.1} h={d:.1} a={d:.2}\n", .{
                        @tagName(it.kind),                           it.geom.x, it.geom.y, it.geom.w, it.geom.h,
                        @as(f32, @floatFromInt(it.color.a)) / 255.0,
                    });
                }
            }
        }
        // v0.5-P3 Stage 4-1+: render end do one more layout sync, capture before_render hook (like
        // ScrollArea scrollbar directly
        // rewrite node.rect loose path). This is patch-style fix, real solution is give
        // scrollbar/modal etc direct cx.syncNodeRect(node) call.
        // Timed together as `phase_sync_us`: these four shadow-sync passes each walk node tree at
        // every frame end. They were untimed, cost
        // showed only as gap between render_node_us and render_us.
        const sync_start = inner_timer.read();
        self.syncLayoutToTable(r);
        // World.paint / World.interaction mirror this frame on demand
        // (see cx_world_sync.ensureWorldTablesSynced).
        self.world_tables_stale = true;
        // Project Node tree a11y metadata to AccessibilityTree. Next step (sec 2.1 ObjC bridge):
        // cx.render() end calls a11y_router.flushToBridge to post dirty queue to macOS
        // NSAccessibility.
        self.syncOrDeferA11yProjection(r);
        self.perf.phase_sync_us = (inner_timer.read() - sync_start) / 1000;
        self.perf.ri_sync_k = instrLap(trace_instr, &ri);
        // Debug build validates whole-tree invariants. Downsampled to every 64 frames to avoid
        // ~5ms debug tax per frame; regressions like shadow-sync are continuous and hit within
        // 64 frames. ZENIT_LAYOUT_INTEGRITY=1 restores per-frame validation (for sync timing
        // issues).
        const integrity_start = inner_timer.read();
        if (std.debug.runtime_safety) {
            const every_frame = layoutIntegrityEveryFrameEnabled();
            if (every_frame or self.frame_count % 64 == 1) {
                if (!self.assertLayoutSyncIntegrity(r)) {
                    std.debug.panic("LayoutTable shadow-sync integrity check failed\n", .{});
                }
            }
        }
        // `phase_retained_us` reports the debug-only integrity walk. It is
        // a full-tree traversal that exists only under runtime_safety, so
        // it inflates render() in debug builds and vanishes in release,
        // worth seeing separately rather than blaming the paint pass.
        self.perf.phase_retained_us = (inner_timer.read() - integrity_start) / 1000;
    }
    // Self-check paint invariants of scene content (before inspector/automation cursor overlays;
    // see core/paint_invariants.zig)
    if (self.paint_invariant_check) {
        const r = core.paint_invariants.duplicateFills(self.frame_arena.allocator(), self.display_list.items.items) catch |err| blk: {
            std.log.warn("paint invariant check skipped this frame: {s}", .{@errorName(err)});
            break :blk core.paint_invariants.Result{};
        };
        if (r.duplicates != 0) {
            self.paint_duplicate_fills += r.duplicates;
            self.paint_duplicate_node = r.first_node;
            std.log.warn("paint invariant: node {d} emitted an identical fill_rect / stroke_rect twice in frame {d} (cache replay double emission?)", .{ r.first_node, self.frame_count });
        }
    }
    self.inspector.renderOverlay(self);
    // Final layer: automation cursor must enter real render target to appear in
    // screenshots/recording.
    // Drawn after inspector, not in Node/hit-test tree.
    if (self.virtual_cursor.renderOverlay(self, self.frame_time_ms)) {
        self.needs_redraw = true;
    }

    // Zero-dirty fast path returns self.display_list.items.items. display_list is source of truth,
    // frame-stable (cleared only at paint pass start), no snapshot needed.
    self.last_render_valid = true;
    self.last_render_frame_time_ms = self.frame_time_ms;
    return self.display_list.items.items;
}

pub fn lowerForEncoderPaintTable(self: *Cx) []const paint_table.DisplayItem {
    return self.sprites.paintItems(self.allocator, self.lowering.main_paint.items);
}

/// Check if entire tree is clean. markDirty bubbles to root, so all of root's
/// layout/render/composite/subtree_* being clean implies whole tree clean. O(1) check.
pub fn isTreeFullyClean(self: *const Cx, root: *Node) bool {
    return !root.frame_state.state_bits.dirty.core.layout and
        !root.frame_state.state_bits.dirty.core.subtree_layout and
        !root.frame_state.state_bits.dirty.core.render and
        !root.frame_state.state_bits.dirty.core.subtree_render and
        !root.frame_state.state_bits.dirty.pipeline.composite and
        !root.frame_state.state_bits.dirty.pipeline.subtree_composite and
        !root.frame_state.state_bits.dirty.runtime.dirty and
        !root.frame_state.state_bits.dirty.runtime.subtree_dirty and
        !root.frame_state.state_bits.dirty.pipeline.order and
        !root.frame_state.state_bits.dirty.pipeline.subtree_order and
        !root.frame_state.state_bits.dirty.pipeline.interaction and
        !root.frame_state.state_bits.dirty.pipeline.subtree_interaction and
        !cx_runtime_index.subtreeHasLooseInteractionDirty(self, root);
}

pub fn scheduleRedrawAfterNs(self: *Cx, delay_ns: u64) void {
    const now = @import("zenit_time").Instant.now(self.io) catch return;
    if (self.next_redraw_scheduled_at) |scheduled_at| {
        if (self.next_redraw_delay_ns) |current_delay| {
            const elapsed = now.since(scheduled_at);
            const remaining = current_delay -| elapsed;
            if (delay_ns >= remaining) return;
        }
    }
    self.next_redraw_scheduled_at = now;
    self.next_redraw_delay_ns = delay_ns;
}

pub fn processScheduledRedraw(self: *Cx) bool {
    const scheduled_at = self.next_redraw_scheduled_at orelse return false;
    const delay_ns = self.next_redraw_delay_ns orelse return false;
    const now = @import("zenit_time").Instant.now(self.io) catch return false;
    if (now.since(scheduled_at) < delay_ns) return false;
    self.next_redraw_scheduled_at = null;
    self.next_redraw_delay_ns = null;
    self.needs_redraw = true;
    return true;
}

/// Force-update interaction index before event handling. Not gated by before_render_frame
/// cache (runs even when idle frame does not increment frame_count).
///
/// The zero-dt before-render tick is only re-run when the scene was mutated since the last tick
/// (frame or event-time) or the frame clock moved: hooks, transitions and animations evaluated
/// again at the same time over an unmutated scene produce the same scene, so repeated refreshes
/// between two frames (several hit queries per event, pending render-only work, running
/// animations) coalesce into at most one tick per mutation. Pending hit-index work (layout,
/// interaction, structure) is still committed before the query either way.
pub fn ensureHitTestSceneFresh(self: *Cx) void {
    if (self.tick_depth > 0 or self.draining_deferred_frees) return;
    _ = self.processScheduledRedraw();
    if (!self.hasPendingSceneWork()) return;
    self.input_perf.in_hit_refresh_dirty += 1;
    const run_tick = sceneMutatedSinceTick(self);
    if (!run_tick and !hitIndexWorkPending(self)) return;
    forceTickAndRebuildForHitTestEx(self, run_tick);
}

/// A mutation reached the scene (node_tree.g_scene_mutation_gen) or the frame clock advanced
/// since the last before-render tick.
pub fn sceneMutatedSinceTick(self: *const Cx) bool {
    return node_tree.g_scene_mutation_gen != self.hit_scene_tick_gen or
        self.frame_time_ms != self.hit_scene_tick_time_ms;
}

fn noteSceneTicked(self: *Cx) void {
    self.hit_scene_tick_gen = node_tree.g_scene_mutation_gen;
    self.hit_scene_tick_time_ms = self.frame_time_ms;
}

/// Work a hit query needs committed first: layout, structure/order and interaction dirtiness.
fn hitIndexWorkPending(self: *Cx) bool {
    const r = self.root orelse return false;
    const d = r.frame_state.state_bits.dirty;
    return d.core.layout or d.core.subtree_layout or d.runtime.subtree_dirty or
        d.pipeline.subtree_order or d.pipeline.subtree_interaction or
        cx_runtime_index.subtreeHasLooseInteractionDirty(self, r);
}

pub fn forceTickAndRebuildForHitTest(self: *Cx) void {
    forceTickAndRebuildForHitTestEx(self, true);
}

fn forceTickAndRebuildForHitTestEx(self: *Cx, run_tick: bool) void {
    defer cx_cursor.updateCursorShape(self);
    const r = self.root orelse return;
    const tick_mod = @import("render_engine/tick.zig");
    const saved_tick_nodes = tick_mod.g_tick_node_count;
    const build_nodes_before = self.interaction_index.stat_build_nodes;
    var refresh_timer = startPerfTimer(self);
    self.input_perf.in_hit_refresh_forced += 1;
    if (cx_runtime_index.hitTraceEnabled()) std.debug.print("[hit-scene] refresh run_tick={}\n", .{run_tick});
    defer {
        self.input_perf.in_hit_refresh_us += refresh_timer.read() / 1000;
        self.input_perf.in_hit_refresh_tick_nodes += tick_mod.g_tick_node_count -% saved_tick_nodes;
        tick_mod.g_tick_node_count = saved_tick_nodes;
        self.input_perf.in_hit_build_nodes_event += self.interaction_index.stat_build_nodes -% build_nodes_before;
    }
    const root_handle = self.node_registry.handleFor(r);
    const viewport_clip = ComputedRect.init(0, 0, self.viewport.width, self.viewport.height);
    const had_initial_layout_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
    const had_initial_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, r);
    var partial_interaction_roots = PartialInteractionRoots{};
    if ((had_initial_layout_dirty or had_initial_interaction_dirty)) {
        cx_runtime_index.collectPartialInteractionRootsWithFallback(self, r, &partial_interaction_roots);
    }
    var stage_timer = startPerfTimer(self);
    if (had_initial_layout_dirty) {
        self.input_perf.in_hit_refresh_layouts += 1;
        layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
        self.syncLayoutToTable(r);
    }
    self.input_perf.in_hit_refresh_layout_us += stage_timer.lap() / 1000;
    // Recorded after the refresh: mutations the tick itself and the commit below make are part of
    // the scene it produced.
    defer if (run_tick) noteSceneTicked(self);
    // Hit-test freshness must not consume animation time. This path can run multiple times
    // within one visual frame during mouse down/up/move, and advancing dt causes
    // popovers/selects/pickers
    // to skip opening frames. Absolute timestamp must sync with current logic frame, else
    // animations
    // advance but render stalls, causing hit test to use old frame time and lag visible position.
    if (run_tick) {
        render_engine.setFrameClock(.{
            .io = self.io,
            .time_ms = self.frame_time_ms,
            .dt_ms = 0,
            .dt_seconds = 0,
        });
        // Same as render path: freeNode deferred during traversal (see freeNode comment).
        self.tick_depth += 1;
        self.owner.beginBatch();
        self.last_tick_animations_active = render_engine.tickBeforeRender(r, 0, 0, viewport_clip, self.allocator, 0);
        // Batch before tick_depth returns to zero; freeNode in effects still deferred.
        self.owner.endBatch();
        self.tick_depth -= 1;
    }
    self.input_perf.in_hit_refresh_tick_us += stage_timer.lap() / 1000;
    // Handles make the collection itself memory-safe. Resetting after a
    // structural mutation also prevents pre-hook ancestry decisions from
    // being merged with the post-hook tree; the fresh collection below is
    // authoritative for the new topology.
    cx_node_lifetime.drainDeferredFrees(self);
    partial_interaction_roots.prune(self);
    const current_root = self.root orelse return;
    if (current_root != r or self.node_registry.resolve(root_handle, null) != current_root) {
        self.interaction_index.fallback_reason = "root_changed_refresh";
        cx_runtime_index.fullRebuildRuntimeIndexes(self, current_root) catch @panic("OOM: root changed during hit-test tick");
        return;
    }
    self.overlay_stack.updateAnchors(self.viewport.width, self.viewport.height);
    const had_post_tick_layout_dirty = current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout;
    const had_post_tick_interaction_dirty = current_root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, current_root);
    if ((had_post_tick_layout_dirty or had_post_tick_interaction_dirty)) {
        cx_runtime_index.collectPartialInteractionRootsWithFallback(self, current_root, &partial_interaction_roots);
    }
    _ = stage_timer.lap();
    if (had_post_tick_layout_dirty) {
        self.input_perf.in_hit_refresh_layouts += 1;
        layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
        self.syncLayoutToTable(current_root);
    }
    self.input_perf.in_hit_refresh_layout_us += stage_timer.lap() / 1000;
    defer self.input_perf.in_hit_refresh_index_us += stage_timer.lap() / 1000;
    const has_layout_dirty = had_initial_layout_dirty or had_post_tick_layout_dirty;
    const has_interaction_dirty = had_initial_interaction_dirty or had_post_tick_interaction_dirty;
    // OOM not swallowed (see rebuildRuntimeIndexesIfCurrentRootDirty).
    if (current_root.frame_state.state_bits.dirty.runtime.subtree_dirty) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=runtime\n", .{});
        cx_runtime_index.rebuildRuntimeIndexesWithRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildRuntimeIndexes (hit-test scene refresh)");
    } else if (current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=order\n", .{});
        cx_runtime_index.rebuildOrderIndexesWithRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildOrderIndexes (hit-test scene refresh)");
    } else if (has_layout_dirty or has_interaction_dirty) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=partial roots={d} overflow={}\n", .{ partial_interaction_roots.len, partial_interaction_roots.overflow });
        cx_runtime_index.rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildInteractionIndex (hit-test scene refresh)");
    }
}

pub fn addAfterLayoutHook(self: *Cx, ctx: *anyopaque, run: AfterLayoutFn) !void {
    for (self.after_layout_hooks.items) |h| {
        if (h.ctx == ctx) return;
    }
    try self.after_layout_hooks.append(self.allocator, .{ .ctx = ctx, .run = run });
}

pub fn removeAfterLayoutHook(self: *Cx, ctx: *anyopaque) void {
    var i: usize = 0;
    while (i < self.after_layout_hooks.items.len) {
        if (self.after_layout_hooks.items[i].ctx == ctx) {
            _ = self.after_layout_hooks.orderedRemove(i);
            if (self.after_layout_cursor) |*next| {
                if (i < next.*) next.* -= 1;
            }
        } else i += 1;
    }
}

/// Callback -> (if dirty) layout, loop until no callback requests or iteration limit hit.
fn runAfterLayoutHooks(self: *Cx, partial: *PartialInteractionRoots) AfterLayoutOutcome {
    var out = AfterLayoutOutcome{};
    if (self.after_layout_hooks.items.len == 0) return out;
    var round: u8 = 0;
    while (round < max_after_layout_rounds) : (round += 1) {
        const last_round = round + 1 == max_after_layout_rounds;
        var again = false;
        // Same gate as before_render: freeNode in callbacks deferred until end of round.
        self.tick_depth += 1;
        self.owner.beginBatch();
        const saved_cursor = self.after_layout_cursor;
        self.after_layout_cursor = 0;
        while (self.after_layout_cursor.? < self.after_layout_hooks.items.len) {
            const h = self.after_layout_hooks.items[self.after_layout_cursor.?];
            self.after_layout_cursor.? += 1;
            if (h.run(h.ctx, round, last_round) == .needs_layout) again = true;
        }
        self.after_layout_cursor = saved_cursor;
        self.owner.endBatch();
        self.tick_depth -= 1;
        cx_node_lifetime.drainDeferredFrees(self);
        partial.prune(self);
        const root = self.root orelse return out;
        const layout_dirty = root.frame_state.state_bits.dirty.core.layout or root.frame_state.state_bits.dirty.core.subtree_layout;
        const interaction_dirty = root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, root);
        if (interaction_dirty) out.interaction_dirty = true;
        if (layout_dirty) {
            cx_runtime_index.collectPartialInteractionRootsWithFallback(self, root, partial);
            layout_engine.layoutNode(root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(root);
            out.ran_layout = true;
        }
        if (!again) break;
    }
    return out;
}

fn ensureBeforeRenderTicked(self: *Cx) void {
    defer cx_cursor.updateCursorShape(self);
    if (self.before_render_frame == self.frame_count and
        std.math.approxEqAbs(f64, self.before_render_time_ms, self.frame_time_ms, 0.0001))
    {
        return;
    }
    if (self.root) |r| {
        const root_handle = self.node_registry.handleFor(r);
        self.perf.tick_before_render_count += 1;
        std.debug.assert(self.perf.tick_before_render_count <= 1);
        if (cx_runtime_index.hitTraceEnabled()) std.debug.print("[hit-scene] frame tick {d}\n", .{self.frame_count});
        // First layout pass lets on_before_render / overlay enter tick read real rect of current
        // frame.
        // Critical for layers positioned by content size; otherwise first open shows old 0x0 /
        // stale geometry.
        const had_initial_layout_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
        const had_initial_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, r);
        var partial_interaction_roots = PartialInteractionRoots{};
        if ((had_initial_layout_dirty or had_initial_interaction_dirty)) {
            cx_runtime_index.collectPartialInteractionRootsWithFallback(self, r, &partial_interaction_roots);
        }
        // These four attribution points were deleted as write-but-zero-read, making before_render
        // a black box measured at 4.7ms constant (571 nodes) with no way to drill down. Restored.
        var br_timer = startPerfTimer(self);
        if (had_initial_layout_dirty) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        self.perf.br_initial_layout_us = br_timer.lap() / 1000;
        const viewport_clip = ComputedRect.init(0, 0, self.viewport.width, self.viewport.height);
        // Set global frame time for on_before_render hooks and animation system (single-threaded
        // safe, sole entry point).
        render_engine.setFrameClock(.{
            .io = self.io,
            .time_ms = self.frame_time_ms,
            .dt_ms = self.frame_dt_ms,
            .dt_seconds = self.frame_dt_seconds,
            .reduced_motion = self.reduced_motion or self.renderer_reduced_motion,
        });
        // tick_depth gate: freeNode always deferred during traversal (see freeNode comment).
        self.tick_depth += 1;
        // Signal writes during animation tick batched until tick end; batch collected before
        // tick_depth returns to zero, effects' freeNode still deferred.
        self.owner.beginBatch();
        const tick_active = render_engine.tickBeforeRender(r, 0, 0, viewport_clip, self.allocator, self.frame_dt_seconds * 1000.0);
        self.owner.endBatch();
        self.tick_depth -= 1;
        self.perf.br_tick_us = br_timer.lap() / 1000;
        // See forceTickAndRebuildForHitTest: discard pre-hook ancestry
        // decisions after structural mutation and recollect from handles.
        cx_node_lifetime.drainDeferredFrees(self);
        partial_interaction_roots.prune(self);
        const current_root = self.root orelse return;
        if (current_root != r or self.node_registry.resolve(root_handle, null) != current_root) {
            if (current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout) {
                layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
                self.syncLayoutToTable(current_root);
            }
            // Index rebuilt afterwards, no need for local hit root.
            var ignored_partial = PartialInteractionRoots{};
            _ = runAfterLayoutHooks(self, &ignored_partial);
            cx_runtime_index.fullRebuildRuntimeIndexes(self, self.root orelse current_root) catch @panic("OOM: root changed during before-render tick");
            self.before_render_frame = self.frame_count;
            self.before_render_time_ms = self.frame_time_ms;
            return;
        }
        self.last_tick_animations_active = tick_active;
        if (tick_active) {
            self.needs_redraw = true;
        }
        // on_before_render hooks may mark layout (translate/rect) and interaction dirty. Must
        // complete layout before rebuilding interaction index, else hitTest world position stale.
        // Note:
        // has_layout_dirty must read before layout (layout clears dirty flags). If layout runs this
        // frame,
        // interaction index must update (children's absolute positions changed).
        const had_post_tick_layout_dirty = current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout;
        const had_post_tick_interaction_dirty = current_root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, current_root);
        if ((had_post_tick_layout_dirty or had_post_tick_interaction_dirty)) {
            cx_runtime_index.collectPartialInteractionRootsWithFallback(self, current_root, &partial_interaction_roots);
        }
        if (had_post_tick_layout_dirty) {
            layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(current_root);
        }
        self.perf.br_post_layout_us = br_timer.lap() / 1000;
        const after_layout = runAfterLayoutHooks(self, &partial_interaction_roots);
        const has_layout_dirty = had_initial_layout_dirty or had_post_tick_layout_dirty or after_layout.ran_layout;
        const has_interaction_dirty = had_initial_interaction_dirty or had_post_tick_interaction_dirty or after_layout.interaction_dirty;
        // OOM not swallowed (see rebuildRuntimeIndexesIfCurrentRootDirty).
        if (current_root.frame_state.state_bits.dirty.runtime.subtree_dirty) {
            cx_runtime_index.rebuildRuntimeIndexesWithRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildRuntimeIndexes (before-render tick)");
        } else if (current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.rebuildOrderIndexesWithRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildOrderIndexes (before-render tick)");
        } else if (has_layout_dirty or has_interaction_dirty) {
            cx_runtime_index.rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildInteractionIndex (before-render tick)");
        }
        self.perf.br_index_us = br_timer.lap() / 1000;
    }
    self.before_render_frame = self.frame_count;
    self.before_render_time_ms = self.frame_time_ms;
    noteSceneTicked(self);
}

fn renderVisualLine(context: *anyopaque, content: []const u8, font_size: f32, font_weight: u16, italic: bool, family: u16, mono: bool, symbols: bool) ?text_core_module.VisualLine {
    const self: *Cx = @ptrCast(@alignCast(context));
    return self.text.visualLine(.{
        .text = content,
        .font_family = "system",
        .font_size = font_size,
        .font_weight = font_weight,
        .use_italic = italic,
        .font_family_id = family,
        .use_monospace = mono,
        .use_symbols = symbols,
    }) catch null;
}

var verify_incremental_cache: ?bool = null;
/// ZENIT_VERIFY_INCREMENTAL=1: render every frame twice and compare the cached path with the
/// reference full path (see render_engine/incremental_verify.zig). Debug/testing aid only.
pub fn verifyIncrementalEnabled() bool {
    return verify_incremental_cache orelse blk: {
        const v = @import("zenit_environment").flag("ZENIT_VERIFY_INCREMENTAL");
        if (v) std.debug.print("[incremental-verify] enabled: every frame is compared with the reference full path\n", .{});
        verify_incremental_cache = v;
        break :blk v;
    };
}

/// Test hook: force the check on/off regardless of the environment.
pub fn setVerifyIncrementalForTest(enabled: ?bool) void {
    verify_incremental_cache = enabled;
}

/// Lower the display list the incremental pass produced, re-render the same frame in
/// subtree-payload reference mode (no splice, no cache write, no paint-cursor resume), lower
/// again and compare. The reference output stays as the frame's result; per-frame perf counters
/// are restored so they still describe the incremental pass. Mismatches are reported through
/// `perf.incremental_verify_mismatch_count` and a log line naming the first item and field.
fn verifyIncrementalAgainstFull(self: *Cx, render_ctx: *render_engine.RenderContext, root: *Node) void {
    const lowering_mod = @import("render_engine/display_list_lowering.zig");
    const verify = @import("render_engine/incremental_verify.zig");
    const arena = self.frame_arena.allocator();

    const lowerSnapshot = struct {
        fn run(ctx: *render_engine.RenderContext, alloc: std.mem.Allocator) ![]verify.Item {
            var main: std.ArrayList(display_list_mod.DisplayItem) = .empty;
            var paint: std.ArrayList(paint_table.DisplayItem) = .empty;
            var local = ctx.*;
            local.lowering_buffer = &main;
            local.lowering_buffer_paint = &paint;
            local.capture_lowered = null;
            local.sprite_probe = null;
            local.paint_pass_lowering = true;
            local.allocator = alloc;
            try lowering_mod.appendAllDisplayItemsToRenderList(&local);
            return verify.snapshot(alloc, paint.items);
        }
    }.run;

    const dump_dl = @import("zenit_environment").flag("ZENIT_VERIFY_DUMP_DL");
    const inc_dl = if (dump_dl) arena.dupe(display_list_mod.DisplayItem, render_ctx.display_list.items.items) catch &.{} else &.{};
    const incremental = lowerSnapshot(render_ctx, arena) catch |err| {
        std.log.warn("incremental verify skipped: {s}", .{@errorName(err)});
        return;
    };
    const retained_incremental = verify.snapshotRetained(arena, render_ctx.property_tree, render_ctx.scene_runtime) catch |err| {
        std.log.warn("incremental verify skipped: {s}", .{@errorName(err)});
        return;
    };
    const saved_perf = self.perf;
    render_ctx.subtree_payload_reference_mode = true;
    render_engine.renderNode(render_ctx, root) catch |err| {
        std.debug.print("[ui] reference renderNode error: {}\n", .{err});
    };
    render_ctx.subtree_payload_reference_mode = false;
    self.perf = saved_perf;
    const reference = lowerSnapshot(render_ctx, arena) catch |err| {
        std.log.warn("incremental verify skipped: {s}", .{@errorName(err)});
        return;
    };
    const retained_reference = verify.snapshotRetained(arena, render_ctx.property_tree, render_ctx.scene_runtime) catch |err| {
        std.log.warn("incremental verify skipped: {s}", .{@errorName(err)});
        return;
    };
    const retained_diff = verify.compareRetained(retained_incremental, retained_reference);
    if (retained_diff.mismatches > 0 and retained_diff.first_node != 0) {
        const find = struct {
            fn f(n: *Node, id: u32) ?*Node {
                if (n.id == id) return n;
                for (n.children.items) |c| if (f(c, id)) |hit| return hit;
                return null;
            }
        }.f;
        if (find(root, retained_diff.first_node)) |n| {
            var parent_comp: []const u8 = "-";
            var cur = n.parent;
            while (cur) |p| : (cur = p.parent) if (p.meta.ownership.meta.component_name) |c| {
                parent_comp = c;
                break;
            };
            std.debug.print("[incremental-verify]   node {d}: tag={s} component={s} in={s} test_id={s} draw={} icon={} image={}\n", .{ n.id, @tagName(n.tag), n.meta.ownership.meta.component_name orelse "-", parent_comp, n.meta.ownership.meta.test_id orelse "-", n.meta.per_frame.custom_hooks.draw != null, n.getIcon() != null, n.getImage() != null });
        }
    }
    if (retained_diff.mismatches > 0) {
        std.debug.print("[incremental-verify] frame {d}: retained build differs in {d} entries, first {s}[{d}].{s} (node {d})\n", .{ self.frame_count, retained_diff.mismatches, retained_diff.first_table, retained_diff.first_index, retained_diff.first_field, retained_diff.first_node });
    }
    var result = verify.compare(incremental, reference);
    result.mismatches += retained_diff.mismatches;
    if (dump_dl and result.first != null) {
        const ref_dl = render_ctx.display_list.items.items;
        for (0..@max(inc_dl.len, ref_dl.len)) |i| {
            const a: ?display_list_mod.DisplayItem = if (i < inc_dl.len) inc_dl[i] else null;
            const b: ?display_list_mod.DisplayItem = if (i < ref_dl.len) ref_dl[i] else null;
            const at: u8 = if (a) |x| (if (x == .text_run) @backingInt(x.text_run.raster_policy) else 9) else 9;
            const bt: u8 = if (b) |x| (if (x == .text_run) @backingInt(x.text_run.raster_policy) else 9) else 9;
            std.debug.print("[verify-dl] {d}: inc={s}#{d}/{d} | ref={s}#{d}/{d}\n", .{ i, if (a) |x| @tagName(x) else "-", if (a) |x| x.header().node_id else 0, at, if (b) |x| @tagName(x) else "-", if (b) |x| x.header().node_id else 0, bt });
        }
    }
    self.perf.incremental_verify_mismatch_count = @intCast(@min(result.mismatches, std.math.maxInt(u32)));
    self.incremental_verify_mismatch_total += result.mismatches;
    if (result.first != null and @import("zenit_environment").flag("ZENIT_VERIFY_DUMP")) {
        const dump_all = @import("zenit_environment").flag("ZENIT_VERIFY_DUMP_ALL");
        const lo = if (dump_all) 0 else result.first.?.index -| 4;
        const lim = @min(@max(incremental.len, reference.len), if (dump_all) std.math.maxInt(usize) else lo + 28);
        for (lo..lim) |i| {
            const a = if (i < incremental.len) incremental[i] else null;
            const b = if (i < reference.len) reference[i] else null;
            std.debug.print("[verify-dump] {d}: inc={s}/{s} ({d:.1},{d:.1},{d:.1}x{d:.1}) c={x} | ref={s}/{s} ({d:.1},{d:.1},{d:.1}x{d:.1}) c={x} p={d}/{d} s={}/{} d={x}/{x} {s}\n", .{ i, if (a) |x| @tagName(x.kind) else "-", if (a) |x| @tagName(x.control_kind) else "-", if (a) |x| x.geom.x else 0, if (a) |x| x.geom.y else 0, if (a) |x| x.geom.w else 0, if (a) |x| x.geom.h else 0, if (a) |x| @as(u32, @bitCast(x.color)) else 0, if (b) |x| @tagName(x.kind) else "-", if (b) |x| @tagName(x.control_kind) else "-", if (b) |x| x.geom.x else 0, if (b) |x| x.geom.y else 0, if (b) |x| x.geom.w else 0, if (b) |x| x.geom.h else 0, if (b) |x| @as(u32, @bitCast(x.color)) else 0, if (a) |x| x.text_raster_policy else 0, if (b) |x| x.text_raster_policy else 0, if (a) |x| x.icon_snap else false, if (b) |x| x.icon_snap else false, if (a) |x| x.paint_digest else 0, if (b) |x| x.paint_digest else 0, if (a != null and b != null) (verify.firstDifference(a.?, b.?) orelse "") else "<len>" });
        }
    }
    if (result.first) |first| {
        // debug.print, not log.warn: release builds drop warnings and this check is used there.
        std.debug.print(
            "[incremental-verify] frame {d}: {d} mismatching items (incremental={d} reference={d}), first at {d} field {s}\n",
            .{ self.frame_count, result.mismatches, result.lhs_len, result.rhs_len, first.index, first.field },
        );
    }
}
