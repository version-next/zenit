/// Pre-frame tick: declarative Transition advance, imperative animation
/// tick, on_before_render hook, viewport clip traversal
const std = @import("std");
const tick_node_dirty = @import("../node_dirty.zig");

const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const geometry = @import("geometry.zig");
const a11y_preferences = @import("../../a11y/preferences.zig");
// Global frame time defined in mod.zig; tick receives now_ms;
// tickBeforeRender caller (mod.zig) passes current_frame_time_ms

const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const Node = node_mod.Node;

fn transitionPropAffectsOpacity(prop: types.TransitionProp) bool {
    return prop == .opacity;
}

fn transitionPropAffectsTransform(prop: types.TransitionProp) bool {
    return switch (prop) {
        .translate_x, .translate_y, .scale_x, .scale_y, .rotate => true,
        else => false,
    };
}

/// "Dynamic" properties: position, size, scale, rotation. Reduced
/// motion skips interpolation. Color, opacity, radius, stroke-width are
/// visual transitions, excluded.
fn transitionPropIsMotion(prop: types.TransitionProp) bool {
    return switch (prop) {
        .translate_x, .translate_y, .scale_x, .scale_y, .rotate, .width => true,
        else => false,
    };
}

/// Declarative Transition tick: advance active transitions' progress,
/// update style. Return true = active transitions (need more redraws).
pub fn tickTransitions(node: *Node, slots: *types.TransitionSlots, allocator: Allocator, now_ms: f64) bool {
    var still_active = false;
    var interaction_changed = false;
    var composite_changed = false;
    var render_changed = false;
    var requested_linger = false;

    // Collect completion callbacks (deferred to loop end to avoid node
    // destruction in callback causing UAF)
    var pending_callbacks: [12]struct { cb: *const fn (*anyopaque) void, ctx: *anyopaque } = undefined;
    var pending_count: u5 = 0;

    for (slots.slots[0..slots.count]) |*slot| {
        if (!slot.active) continue;

        // Absolute timestamp driven: progress = (now - start) / duration,
        // zero cumulative error
        const elapsed = @as(f32, @floatCast(now_ms - slot.start_time_ms));
        // Two "reduced motion" modes differ:
        // - current_reduced_motion (frame-clock level): renderer downgrade / explicit host disable,
        //   all transitions jump to end;
        // - reduce motion effect (system a11y pref): only translation jumps, colors/opacity still
        //   transition.
        const reduce = @import("mod.zig").current_reduced_motion or
            (a11y_preferences.reduceMotion() and transitionPropIsMotion(slot.prop));
        const progress = if (slot.spec.duration_ms > 0 and !reduce)
            std.math.clamp(elapsed / slot.spec.duration_ms, 0, 1)
        else
            @as(f32, 1.0);

        const is_complete = progress >= 1.0;

        if (is_complete) {
            slot.active = false;
            const affects_opacity = transitionPropAffectsOpacity(slot.prop);
            const affects_transform = transitionPropAffectsTransform(slot.prop);
            if (affects_opacity or affects_transform) {
                node.requestCompositeAnimationLinger(affects_opacity, affects_transform);
                requested_linger = true;
            }
            // Collect completion callbacks (don't trigger immediately)
            if (slot.on_complete) |cb| {
                if (slot.on_complete_ctx) |ctx| {
                    if (pending_count < 12) {
                        pending_callbacks[pending_count] = .{ .cb = cb, .ctx = ctx };
                        pending_count += 1;
                    }
                }
                slot.on_complete = null;
                slot.on_complete_ctx = null;
            }
        } else {
            still_active = true;
        }

        const t = slot.spec.easing.apply(progress);

        // At completion assign exact end value, avoid float rounding from
        // from + (to - from) * 1.0
        const lerped = if (is_complete) slot.to_value else slot.from_value + (slot.to_value - slot.from_value) * t;

        // Apply interpolation to style
        switch (slot.prop) {
            .background => {
                node.setBackgroundRaw(if (is_complete) slot.to_color else types.Color.lerp(slot.from_color, slot.to_color, t));
                render_changed = true;
            },
            .border_color => {
                node.style.border.color = if (is_complete) slot.to_color else types.Color.lerp(slot.from_color, slot.to_color, t);
                render_changed = true;
            },
            .opacity => {
                node.setOpacityRaw(lerped);
                interaction_changed = true;
                composite_changed = true;
            },
            .translate_x => {
                node.style.translate_x = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .translate_y => {
                node.style.translate_y = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .scale_x => {
                node.style.ensureExtPanic(allocator).scale_x = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .scale_y => {
                node.style.ensureExtPanic(allocator).scale_y = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .rotate => {
                node.style.ensureExtPanic(allocator).rotate = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .corner_radius => {
                node.style.ensureExtPanic(allocator).corner_radius = .{ .all = @max(0, lerped) };
                interaction_changed = true;
                render_changed = true;
            },
            .border_width => {
                node.style.border.setUniformWidth(lerped);
                interaction_changed = true;
                render_changed = true;
            },
            .width => {
                node.style.width = .{ .px = @max(0, lerped) };
                node.markLayoutDirty();
            },
            .text_color => {
                if (node.getText()) |cur| {
                    var tp = cur;
                    tp.color = if (is_complete) slot.to_color else types.Color.lerp(slot.from_color, slot.to_color, t);
                    node.setText(tp);
                }
                render_changed = true;
            },
        }
    }

    slots.any_active = still_active;
    // composite properties all use authoritative dirty marking
    // (markCompositePropDirty = interaction + composite +
    // invalidateRenderCache), consistent with node_animator/hooks/setter.
    if (composite_changed) {
        node.markCompositePropDirty();
    } else {
        if (interaction_changed) node.markInteractionDirty();
        if (render_changed) node.markRenderDirty();
    }

    // After loop trigger deferred callbacks (node traversal complete,
    // safe to destroy nodes)
    for (pending_callbacks[0..pending_count]) |entry| {
        entry.cb(entry.ctx);
    }

    return still_active or requested_linger;
}

/// DEBUG: global frame count (for log rate-limiting)
pub var g_debug_frame: u64 = 0;
/// DEBUG: current frame markRenderDirty hook count
pub var g_debug_dirty_hooks: u32 = 0;

var dirty_hook_debug_cache: ?bool = null;

fn dirtyHookDebugEnabled() bool {
    return dirty_hook_debug_cache orelse blk: {
        const enabled = @import("zenit_environment").flag("ZENIT_RENDER_DIRTY_DEBUG");
        dirty_hook_debug_cache = enabled;
        break :blk enabled;
    };
}

/// Runtime self-only audit (Debug/ReleaseSafe only).
///
/// before_render_hook_affects_self_only is caller-guaranteed, but the framework has many
/// "side-effect-free writes" (setBackgroundRaw / setOpacityRaw, 151 places) that don't mark
/// dirty or bump content_version. If the guarantee breaks, the cross-frame cache reuses a stale
/// DisplayItem; transform writes have a property_tree recalc fallback, but color/opacity baked
/// into the item do not, so corruption is silent until the next real dirty.
///
/// The audit criterion must **exactly match the threat model**, else it punishes legal usage:
/// - checking only "value changed" also flags a hook mounting a new descendant (no stale-reuse
///   issue); an editor hook doing VirtualList mount/reclaim every frame would crash every frame.
/// - checking only "value changed" also flags the recommended fix (switch to setBackground,
///   which marks dirty and is safe), which is self-contradictory.
/// So check the **(node id, drawn value, content_version) triple** on pre-existing nodes only:
/// - new nodes excluded (fresh build this frame, no stale reuse);
/// - disappeared nodes excluded (won't be reused);
/// - pre-existing value changed **and content_version changed**: legal (dirty-write);
/// - pre-existing value changed **but content_version unchanged**: **breach**, unmarked write,
///   cache reuses stale.
const SelfScopeAuditEntry = struct {
    node: *Node,
    paint_hash: u64,
    content_version: u32,
    composite_version: u32,
};

/// Audit sample limit. Exceed -> skip audit (better skip than fail
/// diagnostic).
const self_scope_audit_max: usize = 4096;

/// Fingerprint covers = "baked into DisplayItem and **no** per-frame recalc fallback".
///
/// Included: background rgba, opacity, border (width/color/radius), written as constants into
/// fill_rect/stroke_rect (display_list.zig 66-90 color/radius/shape). Cache replay uses them,
/// so a wrong value stays wrong until the next real dirty.
///
/// **Intentionally exclude transform/translate**: a cached item has local coords + transform_id;
/// lowering reads the current-frame property_tree matrix (cleared/rebuilt each frame), so
/// translate self-heals. Verified: a lying hook changing descendant translate (7->56) each frame
/// keeps drawn_x current, zero stale. Fingerprinting it only adds false positives.
fn paintHashOf(node: *Node) u64 {
    var h: u64 = 1469598103934665603;
    const bg = node.getBackground();
    inline for (.{ bg.r, bg.g, bg.b, bg.a }) |c| {
        h = (h ^ @as(u64, c)) *% 1099511628211;
    }
    h = (h ^ @as(u64, @bitCast(@as(f64, node.getOpacity())))) *% 1099511628211;
    // border three fields equally baked into item without fallback
    // (cross-review coverage gap)
    const b = node.style.border;
    h = (h ^ @as(u64, @bitCast(@as(f64, b.width)))) *% 1099511628211;
    h = (h ^ @as(u64, @bitCast(@as(f64, b.radius)))) *% 1099511628211;
    inline for (.{ b.color.r, b.color.g, b.color.b, b.color.a }) |c| {
        h = (h ^ @as(u64, c)) *% 1099511628211;
    }
    return h;
}

var self_scope_audit_every_frame_cache: ?bool = null;
/// ZENIT_SELF_SCOPE_AUDIT_EVERY_FRAME=1: restore per-frame audit
/// (default sample every 64 frames).
fn selfScopeAuditEveryFrameEnabled() bool {
    return self_scope_audit_every_frame_cache orelse blk: {
        const v = @import("zenit_environment").flag("ZENIT_SELF_SCOPE_AUDIT_EVERY_FRAME");
        self_scope_audit_every_frame_cache = v;
        break :blk v;
    };
}

fn collectSelfScopeAudit(
    node: *Node,
    exclude: ?*Node,
    buf: []SelfScopeAuditEntry,
    count: *usize,
) void {
    collectScopeAudit(node, exclude, false, buf, count);
}

/// `skip_uncached`: leave out nodes at or below a disable_render_cache boundary (no cross-frame
/// cache can hold them, so an unmarked write there cannot be replayed stale).
fn collectScopeAudit(
    node: *Node,
    exclude: ?*Node,
    skip_uncached: bool,
    buf: []SelfScopeAuditEntry,
    count: *usize,
) void {
    if (skip_uncached and node.frame_state.state_bits.flags.disable_render_cache) return;
    if (node != exclude) {
        if (count.* >= buf.len) return; // Capacity insufficient: caller gives up this audit
        buf[count.*] = .{
            .node = node,
            .paint_hash = paintHashOf(node),
            .content_version = node.meta.per_frame.caches.versions.content,
            .composite_version = node.meta.per_frame.caches.versions.composite,
        };
        count.* += 1;
    }
    for (node.children.items) |child| {
        collectScopeAudit(child, exclude, skip_uncached, buf, count);
    }
}

/// Find render root from node upward (one without parent).
fn renderRootOf(node: *Node) *Node {
    var cur = node;
    while (cur.parent) |p| cur = p;
    return cur;
}

pub fn runBeforeRenderHook(node: *Node, hook: *const fn (*Node) void) bool {
    const was_dirty = node.frame_state.state_bits.dirty.core.render;
    node.frame_state.state_bits.dirty.core.render = false;

    // Only audit in safe builds, only for nodes declaring self-only; sampled because of traversal
    // cost. WARNING: the audit walks from the render root to leaves and hashes paint per node
    // before/after each self-only hook. Real screen: 38 audits/frame, 143,564 nodes traversed vs.
    // tick's 583 (246x), br_tick 2.6ms -> 19.2ms, Debug scrolling drops frames. Consistent with
    // assertLayoutSyncIntegrity (also a tree diagnostic): sampled every 64 frames. Guarantee
    // violations are continuous (the unmarked write repeats every frame), so the sample hits.
    // ZENIT_SELF_SCOPE_AUDIT_EVERY_FRAME=1 restores per-frame auditing (debugging).
    const audit_sampled = selfScopeAuditEveryFrameEnabled() or (g_debug_frame % 64 == 1);
    const self_only = node.beforeRenderHooksSelfOnly();
    // descendants_cache_safe guarantee: audited over the node and its subtree (siblings keep the
    // conservative default), uncacheable boundary nodes excluded.
    const descendants_safe = !self_only and node.frame_state.state_bits.flags.before_render_hook_descendants_cache_safe;
    // `.self` / `.dirty_marking` scoped hooks: every write (the node's own included) must be marked.
    const scoped_trusted = node.beforeRenderHooksScopedTrusted();
    const audit = (@import("builtin").mode == .debug or @import("builtin").mode == .safe) and
        (self_only or descendants_safe or scoped_trusted) and
        audit_sampled;
    var audit_buf: [self_scope_audit_max]SelfScopeAuditEntry = undefined;
    var audit_count: usize = 0;
    var audit_overflow = false;
    if (audit) {
        if (descendants_safe)
            collectScopeAudit(node, null, true, &audit_buf, &audit_count)
        else if (scoped_trusted)
            // Scoped `.self` / `.dirty_marking` hooks are cache-trusted
            // (Node.beforeRenderHooksCacheTrusted): their own writes must go through dirty-marking
            // entries too, so the node is audited as well.
            collectSelfScopeAudit(renderRootOf(node), null, &audit_buf, &audit_count)
        else
            collectSelfScopeAudit(renderRootOf(node), node, &audit_buf, &audit_count);
        // Sample reaches limit = tree larger than buffer, incomplete sample
        // -> skip audit not misdiagnose.
        audit_overflow = audit_count >= self_scope_audit_max;
    }

    hook(node);

    if (audit and !audit_overflow) {
        for (audit_buf[0..audit_count]) |entry| {
            // Only pre-existing nodes before hook. If node enqueued by freeNode,
            // intra-frame pointer still dereferenceable (delayed destroy), read values
            // still own, doesn't affect.
            const now_hash = paintHashOf(entry.node);
            if (now_hash == entry.paint_hash) continue;
            // Value changed but content_version changed = dirty-write path =
            // cache invalidates = legal.
            if (entry.node.meta.per_frame.caches.versions.content != entry.content_version) continue;
            // Opacity goes through the composite path (markCompositePropDirty): its version bump
            // and the subtree_composite bit invalidate cached content the same way.
            if (entry.node.meta.per_frame.caches.versions.composite != entry.composite_version) continue;
            std.debug.panic(
                "before_render_hook_affects_self_only / before_render_hook_descendants_cache_safe 担保被违反：hook 所在 node_id={d} " ++
                    "component={s} test_id={s}；它改了 node_id={d} 的绘制态（背景/不透明度）" ++
                    "**且没有标脏**（content_version 未变）。未标脏的写入会让跨帧 payload 缓存" ++
                    "复用陈旧颜色（transform 有 property_tree 每帧重算兜底，颜色没有）。\n" ++
                    "修法二选一：(a) 摘掉该节点的 before_render_hook_affects_self_only；" ++
                    "(b) 改走 setBackground/setOpacity 等会标脏的入口，不要用 setBackgroundRaw/setOpacityRaw。",
                .{
                    node.id,
                    node.meta.ownership.meta.component_name orelse "(nil)",
                    node.meta.ownership.meta.test_id orelse "(nil)",
                    entry.node.id,
                },
            );
        }
    }
    if (node.frame_state.state_bits.dirty.core.render) {
        // DEBUG: hook itself called markRenderDirty
        g_debug_dirty_hooks += 1;
        if (dirtyHookDebugEnabled() and g_debug_frame % 300 == 1 and g_debug_dirty_hooks <= 8) {
            std.debug.print("[hook-dirty] frame={d} hook_set_dirty node_id={d} component={s} test_id={s}\n", .{
                g_debug_frame,
                node.id,
                node.meta.ownership.meta.component_name orelse "(nil)",
                node.meta.ownership.meta.test_id orelse "(nil)",
            });
        }
        return true;
    }
    if (was_dirty) {
        node.frame_state.state_bits.dirty.core.render = true;
        // DEBUG: was_dirty restored
        g_debug_dirty_hooks += 1;
        if (dirtyHookDebugEnabled() and g_debug_frame % 300 == 1 and g_debug_dirty_hooks <= 8) {
            std.debug.print("[hook-dirty] frame={d} was_dirty_restored node_id={d} component={s} test_id={s}\n", .{
                g_debug_frame,
                node.id,
                node.meta.ownership.meta.component_name orelse "(nil)",
                node.meta.ownership.meta.test_id orelse "(nil)",
            });
        }
    }
    return false;
}

/// Return true = on_before_render hook requested redraw (active
/// animation). now_ms: caller (mod.zig) passes current_frame_time_ms
pub var g_tick_node_count: u32 = 0;
pub var g_tick_hook_count: u32 = 0;
pub var g_slow_hook_us: u64 = 0;
pub var g_slow_hook_name: [64]u8 = @as([64]u8, @splat(0));
pub var g_slow_hook_name_len: u8 = 0;
/// devtools performance panel open sets true; closed saves two clock
/// reads per hook.
pub var g_profile_hooks: bool = false;

var hook_trace_cache: ?bool = null;
/// ZENIT_DEBUG_ANIM_REQUESTS=1: name every node whose tick asks for another
/// frame (what keeps an idle window rendering).
fn noteAnimationRequest(node: *Node, comptime source: []const u8) void {
    const S = struct {
        var enabled: ?bool = null;
    };
    if (S.enabled == null) S.enabled = @import("zenit_environment").flag("ZENIT_DEBUG_ANIM_REQUESTS");
    if (!S.enabled.?) return;
    // Anonymous nodes (hooks on plain boxes) are named by their nearest named
    // ancestor so the report says which component keeps the window rendering.
    var named: ?*Node = node.parent;
    while (named) |n| : (named = n.parent) {
        if (n.meta.ownership.meta.component_name != null or n.meta.ownership.meta.test_id != null) break;
    }
    std.debug.print("[anim-request] {s} node={d} component={s} test_id={s} under={s}/{s}\n", .{
        source,
        node.id,
        node.meta.ownership.meta.component_name orelse "(nil)",
        node.meta.ownership.meta.test_id orelse "(nil)",
        if (named) |n| n.meta.ownership.meta.component_name orelse "(nil)" else "(root)",
        if (named) |n| n.meta.ownership.meta.test_id orelse "(nil)" else "",
    });
}

/// ZENIT_HOOK_TRACE=1: force per-hook timing, log >5ms hooks. Use:
/// frame SLOW shows huge before_render but slow_hook empty (g_profile_hooks
/// defaults off, devtools perf only), use this to find culprit.
fn hookTraceEnabled() bool {
    return hook_trace_cache orelse blk: {
        const v = @import("zenit_environment").flag("ZENIT_HOOK_TRACE");
        hook_trace_cache = v;
        break :blk v;
    };
}

fn runHookTimed(node: *Node, hook: *const fn (*Node) void) bool {
    const trace = hookTraceEnabled();
    if (!g_profile_hooks and !trace) return runBeforeRenderHook(node, hook);
    const io = @import("mod.zig").current_frame_io orelse return runBeforeRenderHook(node, hook);
    var ht = @import("zenit_time").Timer.start(io) catch return runBeforeRenderHook(node, hook);
    const requested = runBeforeRenderHook(node, hook);
    const elapsed = ht.read() / 1000;
    if (elapsed > g_slow_hook_us) {
        g_slow_hook_us = elapsed;
        const name = node.meta.ownership.meta.component_name orelse node.meta.ownership.meta.test_id orelse "(unnamed)";
        const n = @min(name.len, g_slow_hook_name.len);
        @memcpy(g_slow_hook_name[0..n], name[0..n]);
        g_slow_hook_name_len = @intCast(n);
    }
    if (trace and elapsed > 1000) {
        std.debug.print("[hook-trace] {d}us node_id={d} component={s} test_id={s}\n", .{
            elapsed,
            node.id,
            node.meta.ownership.meta.component_name orelse "(nil)",
            node.meta.ownership.meta.test_id orelse "(nil)",
        });
    }
    return requested;
}

// A callback may retire an ancestor while this subtree is still on the
// traversal stack. Its allocations survive until Cx drains, but callbacks
// must stop: their Scope-owned state may already have been disposed.
//
// Walking the parent chain on every check made the tick quadratic in depth (it runs on entry,
// after every hook and after every child). A node is reached only through its ancestors, each of
// which passed this check on entry; until something starts retiring during the tick
// (node_tree.g_retire_gen advances), those results still hold and only the node's own state can
// differ.
fn isRetiring(node: *Node) bool {
    if (node.pending_free_cx != null or node.freeing) return true;
    if (@import("../node_tree.zig").g_retire_gen == retire_gen_at_tick_start) return false;
    var current: ?*Node = node;
    while (current) |ancestor| : (current = ancestor.parent) {
        if (ancestor.pending_free_cx != null or ancestor.freeing) return true;
    }
    return false;
}

// -- Quiet-subtree skip --
//
// Most of a window has no per-frame tick work: no before_render hook, no active transition /
// node animation / linger frame, no sticky node. A full tick that finds a subtree like that
// stamps it quiet (NodeRuntime.tick_quiet_epoch = g_tick_quiet_epoch); later ticks skip the
// subtree while the stamp is valid and nothing in the subtree changed. Every way to add tick
// work goes through a mutation that sets a bubbling dirty bit (hook registration happens at
// build/mount, which marks structure / layout; activating a transition or animation goes through
// a dirty-marking setter), and dirty bits stay set until the next render. The one gap is a
// mutation landing between the end of a tick and the render that cleans its bits:
// noteRenderCleanedAfterTick then bumps g_tick_quiet_epoch, invalidating every stamp.

/// Valid quiet stamps equal this; bumped to invalidate them all (never 0).
pub var g_tick_quiet_epoch: u32 = 1;
/// Subtrees skipped by the quiet-subtree rule this tick (perf).
pub var g_tick_quiet_skip_count: u32 = 0;
/// node_tree.g_scene_mutation_gen when the last tick ended.
var mutation_gen_at_tick_end: u64 = 0;
/// Escape hatch ZENIT_DISABLE_TICK_SKIP=1 (read once per process).
var tick_skip_disabled: ?bool = null;
/// Tests: force the skip on/off.
pub var tick_skip_test_override: ?bool = null;

fn tickSkipEnabled() bool {
    if (tick_skip_test_override) |v| return v;
    return !(tick_skip_disabled orelse blk: {
        const v = @import("zenit_environment").flag("ZENIT_DISABLE_TICK_SKIP");
        tick_skip_disabled = v;
        break :blk v;
    });
}

pub fn invalidateTickQuietStamps() void {
    g_tick_quiet_epoch +%= 1;
    if (g_tick_quiet_epoch == 0) g_tick_quiet_epoch = 1;
}

/// Call when a tick pass over the root ends.
pub fn noteTickEnded() void {
    mutation_gen_at_tick_end = @import("../node_tree.zig").g_scene_mutation_gen;
}

/// Call after the render pass that cleans dirty bits: a mutation since the last tick had its bits
/// cleaned without the tick seeing it, so no quiet stamp can be trusted any more.
pub fn noteRenderCleanedAfterTick() void {
    if (@import("../node_tree.zig").g_scene_mutation_gen != mutation_gen_at_tick_end) invalidateTickQuietStamps();
}

/// Anything in the subtree changed since the last tick (all of these bubble to ancestors).
fn subtreeChangedSinceTick(node: *const Node) bool {
    const d = node.frame_state.state_bits.dirty;
    return d.core.render or d.core.subtree_render or d.core.layout or d.core.subtree_layout or
        d.pipeline.composite or d.pipeline.subtree_composite or
        d.pipeline.interaction or d.pipeline.subtree_interaction or
        d.pipeline.order or d.pipeline.subtree_order or
        d.runtime.dirty or d.runtime.subtree_dirty;
}

fn tickQuietSkippable(node: *const Node) bool {
    return node.frame_state.frame_local.runtime.tick_quiet_epoch == g_tick_quiet_epoch and
        !subtreeChangedSinceTick(node) and tickSkipEnabled();
}

/// The node itself has per-frame tick work (after this frame's tick ran on it).
fn nodeHasTickWork(node: *const Node) bool {
    if (node.hasBeforeRenderHooks()) return true;
    if (node.style.position == .sticky) return true;
    const rt = node.frame_state.frame_local.runtime;
    if (rt.linger.composite > 0 or rt.linger.opacity > 0 or rt.linger.transform > 0) return true;
    if (rt.transitions) |slots| if (slots.any_active) return true;
    if (rt.commands) |anims| if (anims.count > 0) return true;
    return false;
}

/// node_tree.g_retire_gen when the running tick started (see isRetiring).
var retire_gen_at_tick_start: u64 = 0;

pub fn tickBeforeRender(node: *Node, offset_x: f32, offset_y: f32, clip_opt: ?ComputedRect, allocator: Allocator, dt_ms: f32, now_ms: f64) bool {
    // A root that is itself retiring is caught by the entry check; nothing above it is visited.
    const saved_retire_gen = retire_gen_at_tick_start;
    retire_gen_at_tick_start = @import("../node_tree.zig").g_retire_gen;
    defer retire_gen_at_tick_start = saved_retire_gen;
    var quiet = true;
    const requested = tickBeforeRenderNode(node, offset_x, offset_y, clip_opt, allocator, dt_ms, now_ms, &quiet);
    noteTickEnded();
    return requested;
}

fn tickBeforeRenderNode(node: *Node, offset_x: f32, offset_y: f32, clip_opt: ?ComputedRect, allocator: Allocator, dt_ms: f32, now_ms: f64, parent_quiet: *bool) bool {
    var subtree_quiet = true;
    defer {
        // Stamp only after every child was visited or proven quiet; any early return leaves the
        // subtree unstamped (conservative).
        if (!subtree_quiet or nodeHasTickWork(node)) {
            node.frame_state.frame_local.runtime.tick_quiet_epoch = 0;
            parent_quiet.* = false;
        } else {
            node.frame_state.frame_local.runtime.tick_quiet_epoch = g_tick_quiet_epoch;
        }
    }
    if (isRetiring(node)) {
        subtree_quiet = false;
        return false;
    }
    var redraw_requested = false;
    g_tick_node_count += 1;

    // Subtree hook flag self-heals: the component layer has 40+ places doing `before_render.main =`
    // directly without addBeforeRender. At actual hook execution we set the flag and bubble it up
    // (digest "bypass-setter write"); next frame's render hasBeforeRenderHookSubtree sees it. tick
    // runs before render over the whole tree and the flag only grows, so semantics = the old
    // recursive conservative superset. It may keep the flag for an unmounted hook, which is only
    // more conservative, the safe direction.
    if (node.hasBeforeRenderHooks()) {
        node.markSubtreeBeforeRenderHook();
        if (!node.beforeRenderHooksCacheTrusted())
            @import("../node_interaction.zig").markSubtreeUntrustedBeforeRenderHook(node);
    }

    // Read rect from global World hook.
    const local_rect = node.rectFromWorldOrFallback();

    if (node.consumeCompositeAnimationLingerFrame()) {
        redraw_requested = true;
    }

    // -1. Update out_of_viewport flag for on_before_render hook (Skeleton
    // shimmer, Spinner)
    if (clip_opt) |clip| {
        const nx = local_rect.x + node.style.translate_x + node.frame_state.frame_local.runtime.sticky.x + offset_x;
        const ny = local_rect.y + node.style.translate_y + node.frame_state.frame_local.runtime.sticky.y + offset_y;
        const margin: f32 = 48;
        node.frame_state.state_bits.flags.out_of_viewport = (local_rect.w > 0 and local_rect.h > 0) and
            (nx + local_rect.w < clip.x - margin or nx > clip.x + clip.w + margin or
                ny + local_rect.h < clip.y - margin or ny > clip.y + clip.h + margin);
    } else {
        node.frame_state.state_bits.flags.out_of_viewport = true;
    }

    // 0. Declarative Transition tick (absolute timestamp driven)
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.any_active) {
            if (tickTransitions(node, slots, allocator, now_ms)) {
                redraw_requested = true;
                noteAnimationRequest(node, "transition");
            }
            if (isRetiring(node)) {
                subtree_quiet = false;
                return true;
            }
        }
    }

    // 0.5 imperative node animation tick (absolute timestamp driven)
    if (node.frame_state.frame_local.runtime.commands) |anims| {
        if (anims.count > 0) {
            if (anims.tick(node, allocator, now_ms)) {
                redraw_requested = true;
                noteAnimationRequest(node, "animation");
            }
            if (isRetiring(node)) {
                subtree_quiet = false;
                return true;
            }
        }
        if (anims.count == 0) {
            anims.deinit();
            allocator.destroy(anims);
            node.frame_state.frame_local.runtime.commands = null;
        }
    }

    // 1. Unconditionally execute nodes with hooks (ensure ScrollArea bounce,
    // animation tick continue)
    if (node.meta.per_frame.hooks.before_render.main) |hook| {
        g_tick_hook_count += 1;
        if (runHookTimed(node, hook)) {
            redraw_requested = true;
            noteAnimationRequest(node, "hook");
        }
        if (isRetiring(node)) {
            subtree_quiet = false;
            return true;
        }
    }
    for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |hook_opt| {
        if (hook_opt) |hook| {
            g_tick_hook_count += 1;
            if (runHookTimed(node, hook)) {
                redraw_requested = true;
                noteAnimationRequest(node, "hook");
            }
            if (isRetiring(node)) {
                subtree_quiet = false;
                return true;
            }
        }
    }

    if (node.style.overflow_hidden and
        (local_rect.w <= 0.1 or local_rect.h <= 0.1) and
        !subtreeHasActiveAnimation(node))
    {
        clearHiddenSubtreeSceneDirty(node);
        subtree_quiet = false;
        return redraw_requested;
    }

    // 1.5 overflow_hidden tighten clip region
    const tbr_tx = node.style.translate_x;
    const tbr_ty = node.style.translate_y;
    var effective_clip = clip_opt;
    if (node.style.overflow_hidden) {
        const node_clip = ComputedRect.init(
            local_rect.x + tbr_tx + node.frame_state.frame_local.runtime.sticky.x + offset_x,
            local_rect.y + tbr_ty + node.frame_state.frame_local.runtime.sticky.y + offset_y,
            local_rect.w,
            local_rect.h,
        );
        effective_clip = if (effective_clip) |clip|
            geometry.intersectRect(clip, node_clip)
        else
            node_clip;
    }

    // 1.6 sticky offset calculation (needs effective_clip set, before
    // child_offset). Sticky uses ancestor clip_opt (excludes self overflow);
    // null (empty intersection) still calls computeStickyOffset to clear offset/
    // state and mark dirty, can't keep stale.
    if (node.style.position == .sticky) {
        geometry.computeStickyOffset(node, offset_x, offset_y, clip_opt);
    }

    // 2. Calculate child cumulative offset (rect + translate +
    // sticky_offset pass through). Relative coords: child_offset includes
    // parent rect position.
    const child_offset_x = offset_x + local_rect.x + tbr_tx + node.frame_state.frame_local.runtime.sticky.x;
    const child_offset_y = offset_y + local_rect.y + tbr_ty + node.frame_state.frame_local.runtime.sticky.y;

    // 3. Recurse children with viewport clip. WARNING: iteration must be safe under mutation:
    // before_render hooks and animation completion callbacks (steps 1, 0.5) can destroy nodes this
    // frame (typical: animateOpacity(..., done) whose done callback disposes the scope, and cleanup
    // runs detachChild + freeNode). detachChild -> removeChildIncremental modifies node.children
    // in place, so `for (node.children.items)` hits a freed *Node (segfault) or skips/re-visits
    // from the array left-shift. Iterate by index, re-read items each round, and validate the slot
    // is still the expected child; if a deletion occurred (length shrunk or slot changed), realign
    // without advancing. This guarantees no bounds violation and no skips.
    var child_idx: usize = 0;
    while (child_idx < node.children.items.len) {
        const child = node.children.items[child_idx];
        defer {
            // Deleting a later sibling shrinks the array without moving this
            // child. Advance by identity, not by comparing list lengths.
            if (child_idx < node.children.items.len and node.children.items[child_idx] == child) child_idx += 1;
        }
        // Read rect from global hook.
        const child_rect = child.rectFromWorldOrFallback();
        if (child.style.overflow_hidden and
            (child_rect.w <= 0.1 or child_rect.h <= 0.1) and
            !child.hasBeforeRenderHooks() and
            !subtreeHasActiveAnimation(child))
        {
            clearHiddenSubtreeDirty(child);
            if (child.frame_state.frame_local.runtime.tick_quiet_epoch != g_tick_quiet_epoch) subtree_quiet = false;
            continue;
        }

        // opacity==0 with no hooks and no active transition/animation is completely invisible, so
        // skip
        // child render recursion. Still tick active transitions deep in a hidden subtree: otherwise
        // active slots never complete, slots.any_active stays true, hasPendingSceneWork() returns
        // true
        // every frame, and the app locks at 60fps redraw (typical: hidden panel Input border_color
        // transition).
        if (child.isPaintSkipped() and !child.hasBeforeRenderHooks() and
            (child.frame_state.frame_local.runtime.transitions == null or !child.frame_state.frame_local.runtime.transitions.?.any_active) and
            (child.frame_state.frame_local.runtime.commands == null or child.frame_state.frame_local.runtime.commands.?.count == 0))
        {
            if (child.frame_state.frame_local.runtime.tick_quiet_epoch != g_tick_quiet_epoch) subtree_quiet = false;
            if (subtreeHasActiveAnimation(child)) {
                tickOffscreenAnimationsInSubtree(child, allocator, now_ms);
                if (isRetiring(node)) {
                    subtree_quiet = false;
                    return true;
                }
            }
            continue;
        }

        const child_tx = child.style.translate_x;
        const child_ty = child.style.translate_y;
        const child_x = child_rect.x + child_tx + child.frame_state.frame_local.runtime.sticky.x + child_offset_x;
        const child_y = child_rect.y + child_ty + child.frame_state.frame_local.runtime.sticky.y + child_offset_y;
        const child_w = child_rect.w;
        const child_h = child_rect.h;

        // If child sized, no hooks, not sticky, no translate offset,
        // completely outside viewport -> skip whole subtree. Sticky can't skip:
        // sticky_offset needs recalc each frame. Translate can't skip: used for
        // scroll, AABB doesn't reflect actual visible region.
        const child_has_translate = child_tx != 0 or child_ty != 0;
        if (child_w > 0 and child_h > 0 and !child.hasBeforeRenderHooks() and child.style.position != .sticky and !child_has_translate) {
            const margin: f32 = 48;
            var out_of_clip = false;
            if (effective_clip) |clip| {
                const clip_x2 = clip.x + clip.w;
                const clip_y2 = clip.y + clip.h;
                if (child_x + child_w < clip.x - margin or child_x > clip_x2 + margin or
                    child_y + child_h < clip.y - margin or child_y > clip_y2 + margin)
                {
                    out_of_clip = true;
                }
            } else {
                out_of_clip = true;
            }
            if (out_of_clip) {
                if (tickQuietSkippable(child)) {
                    g_tick_quiet_skip_count += 1;
                    continue;
                }
                subtree_quiet = false;
                // Out of viewport: still tick active transitions in subtree to prevent
                // any_active stuck at true
                tickOffscreenAnimationsInSubtree(child, allocator, now_ms);
                if (isRetiring(node)) {
                    subtree_quiet = false;
                    return true;
                }
                continue; // Skip child render recursion
            }
        }

        if (tickQuietSkippable(child)) {
            g_tick_quiet_skip_count += 1;
            continue;
        }
        if (tickBeforeRenderNode(child, child_offset_x, child_offset_y, effective_clip, allocator, dt_ms, now_ms, &subtree_quiet)) {
            redraw_requested = true;
        }
        if (isRetiring(node)) {
            subtree_quiet = false;
            return true;
        }
    }
    return redraw_requested;
}

fn clearHiddenSubtreeDirty(node: *Node) void {
    // Cleaned without being rendered: a cross-frame copy recorded before this change would be
    // spliced as clean once the subtree shows again.
    @import("../node_render_cache.zig").dropCachesForUnrenderedClean(node);
    node.frame_state.state_bits.dirty.core.layout = false;
    node.frame_state.state_bits.dirty.core.subtree_layout = false;
    node.frame_state.state_bits.dirty.core.render = false;
    node.frame_state.state_bits.dirty.core.subtree_render = false;
    node.frame_state.state_bits.dirty.pipeline.composite = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_composite = false;
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    tick_node_dirty.bumpLooseInteractionGen();

    for (node.children.items) |child| {
        clearHiddenSubtreeDirty(child);
    }
}

fn clearHiddenSubtreeSceneDirty(node: *Node) void {
    // Cleaned without being rendered: a cross-frame copy recorded before this change would be
    // spliced as clean once the subtree shows again.
    @import("../node_render_cache.zig").dropCachesForUnrenderedClean(node);
    node.frame_state.state_bits.dirty.core.render = false;
    node.frame_state.state_bits.dirty.core.subtree_render = false;
    node.frame_state.state_bits.dirty.pipeline.composite = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_composite = false;
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    tick_node_dirty.bumpLooseInteractionGen();

    for (node.children.items) |child| {
        clearHiddenSubtreeSceneDirty(child);
    }
}

/// Recursively advance active animations in out-of-viewport subtree to
/// prevent stuck-active state disabling idle-skip.
fn tickOffscreenAnimationsInSubtree(node: *Node, allocator: Allocator, now_ms: f64) void {
    if (isRetiring(node)) return;
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.any_active) {
            _ = tickTransitions(node, slots, allocator, now_ms);
            if (isRetiring(node)) return;
        }
    }
    if (node.frame_state.frame_local.runtime.commands) |anims| {
        if (nodeAnimationsActive(anims)) {
            _ = anims.tick(node, allocator, now_ms);
            if (isRetiring(node)) return;
        }
        if (anims.count == 0) {
            anims.deinit();
            allocator.destroy(anims);
            node.frame_state.frame_local.runtime.commands = null;
        }
    }
    var child_idx: usize = 0;
    while (child_idx < node.children.items.len) {
        const child = node.children.items[child_idx];
        defer {
            if (child_idx < node.children.items.len and node.children.items[child_idx] == child) child_idx += 1;
        }
        if (!subtreeHasActiveAnimation(child)) continue;
        tickOffscreenAnimationsInSubtree(child, allocator, now_ms);
        if (isRetiring(node)) return;
    }
}

fn nodeAnimationsActive(anims: *const @import("../../animation/node_animator.zig").NodeAnimations) bool {
    for (anims.entries[0..anims.count]) |entry| {
        if (entry.controller.isActive()) return true;
    }
    return false;
}

/// Quick check if subtree has active animations (avoid useless
/// recursion).
fn subtreeHasActiveAnimation(node: *Node) bool {
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.any_active) return true;
    }
    if (node.frame_state.frame_local.runtime.commands) |anims| {
        if (nodeAnimationsActive(anims)) return true;
    }
    for (node.children.items) |child| {
        if (subtreeHasActiveAnimation(child)) return true;
    }
    return false;
}
