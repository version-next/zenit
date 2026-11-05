//! Retained subtree memo: reuse last frame's property-tree / scene-runtime output for a clean
//! subtree instead of recomputing it node by node.
//!
//! buildRetainedSubtree rebuilds the property tree (transforms, clips, effects) and the scene
//! runtime records for the whole tree every frame, in DFS order, with frame-local ids. For a
//! subtree nothing in which changed, that output is a pure function of the inputs handed to its
//! root (parent transform / clip / effect ids, surface inverse, viewport): a subtree appends one
//! contiguous range to each property-tree array and one contiguous run of scene records. The memo
//! keeps a copy of exactly that output and replays it:
//!
//! - ids inside the subtree are rebased by the offset between the recorded and the current range
//!   start; references to the ids handed in by the parent are remapped to this frame's;
//! - identical inputs: the copy is the output;
//! - the parent moved by a pure translation T (scrolled content): world-space fields are moved by
//!   T. Allowed only when that is exactly what a rebuild would compute: no capture-surface owner
//!   inside (their descendants' content frame is owner-local), no culled node at record time and
//!   the moved extent stays inside the parent clip (so culling cannot change), identical parent
//!   clip and surface inverse.
//!
//! Recording happens at the frontier of clean subtrees (a memoizable subtree whose parent is not
//! memoizable), so each node is copied at most once per frame, and a replayed memo is refreshed in
//! place. Content flags are not re-read: like the display caches, the memo relies on content
//! writes marking the written node (raw setters are paired with a mark by their callers), and
//! nodes under an undeclared hook, which may write raw, are never memoized. Validity: the root's subtree dirty bits are clean (every relevant mutation bubbles), no
//! node inside is volatile (untrusted before_render hook that may move content raw, active
//! transition / animation / linger, which read state outside the dirty bits); hidden-subtree
//! cleaning, linger / animation / hook registration drop memos (dropMemoChain).
//! ZENIT_DISABLE_RETAINED_MEMO=1 turns it off; reference frames of ZENIT_VERIFY_INCREMENTAL never
//! use it and the check compares the property trees and scene records of both passes.
const std = @import("std");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const property_tree_mod = @import("../property_tree.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const render_context_mod = @import("render_context.zig");
const node_state = @import("node_state.zig");
const geometry = @import("geometry.zig");

const Allocator = std.mem.Allocator;
const Node = node_mod.Node;
const Transform2D = types.Transform2D;
const ComputedRect = types.ComputedRect;
const RenderContext = render_context_mod.RenderContext;
const TransformNode = property_tree_mod.TransformNode;
const ClipNode = property_tree_mod.ClipNode;
const EffectNode = property_tree_mod.EffectNode;
const SceneNodeRuntime = scene_runtime_mod.SceneNodeRuntime;
const INVALID_ID = property_tree_mod.INVALID_ID;

pub const Inputs = struct {
    parent_transform: Transform2D,
    parent_clip: ?ComputedRect,
    parent_transform_id: u32,
    parent_clip_id: u32,
    parent_effect_id: u32,
    surface_inverse: Transform2D,
};

pub const Memo = struct {
    allocator: Allocator,
    inputs: Inputs,
    viewport_w: f32,
    viewport_h: f32,
    base_t: u32,
    base_c: u32,
    base_e: u32,
    transforms: []TransformNode = &.{},
    clips: []ClipNode = &.{},
    effects: []EffectNode = &.{},
    records: []SceneNodeRuntime = &.{},
    nodes: []*Node = &.{},
    /// Union of the records' world bounds and the clips' world AABBs (translation validity).
    extent: ?ComputedRect = null,
    /// The root's layout rect at record time (key, see tryReplay).
    root_rect: ?ComputedRect = null,
    /// Translation replay is not exact for these subtrees (see module doc).
    has_capture_owner: bool = false,
    has_culled: bool = false,

    pub fn deinit(self: *Memo) void {
        const a = self.allocator;
        a.free(self.transforms);
        a.free(self.clips);
        a.free(self.effects);
        a.free(self.records);
        a.free(self.nodes);
        a.destroy(self);
    }
};

/// Per-subtree facts gathered while it is built (returned up the DFS).
pub const BuildSummary = struct {
    /// Clean, non-volatile and every child (visible or culled) memoizable.
    memoizable: bool = false,
    has_capture_owner: bool = false,
    has_culled: bool = false,
    /// The subtree came from its own memo this frame (already current: not re-recorded).
    replayed: bool = false,
};

pub fn memoOf(node: *const Node) ?*Memo {
    const p = node.meta.per_frame.caches.commands.retained_memo orelse return null;
    return @ptrCast(@alignCast(p));
}

pub fn dropMemo(node: *Node) void {
    if (memoOf(node)) |m| m.deinit();
    node.meta.per_frame.caches.commands.retained_memo = null;
}

/// Something that the dirty bits do not show changed at this node (an animation, a linger
/// request, a hook): no memo on it or any ancestor can be replayed.
pub fn dropMemoChain(node: *Node) void {
    var cur: ?*Node = node;
    while (cur) |n| : (cur = n.parent) {
        if (n.meta.per_frame.caches.commands.retained_memo != null) dropMemo(n);
    }
}

/// Dirty bits that bubble and cover everything buildRetainedSubtree reads from a node.
pub fn subtreeClean(node: *const Node) bool {
    const d = node.frame_state.state_bits.dirty;
    return !(d.core.render or d.core.subtree_render or d.core.layout or d.core.subtree_layout or
        d.pipeline.composite or d.pipeline.subtree_composite or
        d.pipeline.order or d.pipeline.subtree_order or
        d.runtime.dirty or d.runtime.subtree_dirty);
}

/// Node state the retained build reads that changes without a dirty mark.
pub fn nodeVolatile(node: *const Node) bool {
    const flags = node.frame_state.state_bits.flags;
    if (flags.has_untrusted_before_render_subtree) return true;
    if (flags.manual_transform_animation_active or flags.manual_opacity_animation_active) return true;
    const rt = node.frame_state.frame_local.runtime;
    if (rt.linger.composite > 0 or rt.linger.opacity > 0 or rt.linger.transform > 0) return true;
    if (rt.transitions) |slots| if (slots.any_active) return true;
    if (rt.commands) |anims| if (anims.count > 0) return true;
    return false;
}

fn eqlTransform(a: Transform2D, b: Transform2D) bool {
    return a.a == b.a and a.b == b.b and a.c == b.c and a.d == b.d and a.tx == b.tx and a.ty == b.ty;
}

fn eqlClip(a: ?ComputedRect, b: ?ComputedRect) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    const x = a.?;
    const y = b.?;
    return x.x == y.x and x.y == y.y and x.w == y.w and x.h == y.h;
}

fn shiftRect(r: ComputedRect, dx: f32, dy: f32) ComputedRect {
    return ComputedRect.init(r.x + dx, r.y + dy, r.w, r.h);
}

fn shiftTransform(t: Transform2D, dx: f32, dy: f32) Transform2D {
    var out = t;
    out.tx += dx;
    out.ty += dy;
    return out;
}

/// new = T * old with T a pure translation: (dx, dy), else null.
fn translationBetween(old: Transform2D, new: Transform2D) ?[2]f32 {
    if (old.a != new.a or old.b != new.b or old.c != new.c or old.d != new.d) return null;
    return .{ new.tx - old.tx, new.ty - old.ty };
}

fn rebase(id: u32, base_old: u32, len: usize, base_new: u32, parent_old: u32, parent_new: u32) u32 {
    // The handed-in parent id first: it may be INVALID_ID (no clip / effect above).
    if (id == parent_old) return parent_new;
    if (id == INVALID_ID) return INVALID_ID;
    if (id >= base_old and id < base_old + len) return id - base_old + base_new;
    // Neither inside the subtree nor the handed-in parent id: an ancestor's id; ancestors are
    // rebuilt every time this memo replays, so the reference would be stale.
    return INVALID_ID - 1;
}

/// Replay the memo of `node` for these inputs. Returns null when it cannot be used (the caller
/// then builds the subtree normally), otherwise the root's ids.
pub fn tryReplay(cx: *RenderContext, node: *Node, in: Inputs) ?node_state.RetainedIds {
    const memo = memoOf(node) orelse return null;
    if (!subtreeClean(node)) {
        dropMemo(node);
        return null;
    }
    if (memo.viewport_w != cx.viewport.width or memo.viewport_h != cx.viewport.height) return null;
    // The root's own placement is set by its parent's layout, which moves it without marking it:
    // part of the key, like the inputs.
    if (memo.transforms.len == 0 or !eqlTransform(memo.transforms[0].local, geometry.nodeLocalTransform(node))) return null;
    if (!eqlClip(memo.root_rect, cx.rectFromWorld(node))) return null;
    if (!eqlTransform(memo.inputs.surface_inverse, in.surface_inverse)) return null;
    if (!eqlClip(memo.inputs.parent_clip, in.parent_clip)) return null;
    var dx: f32 = 0;
    var dy: f32 = 0;
    if (!eqlTransform(memo.inputs.parent_transform, in.parent_transform)) {
        const d = translationBetween(memo.inputs.parent_transform, in.parent_transform) orelse return null;
        if (memo.has_capture_owner or memo.has_culled) return null;
        // content = surface_inverse * world moves by T only when the surface inverse is identity.
        if (!eqlTransform(in.surface_inverse, Transform2D.identity())) return null;
        // Every node rect and every clip of the subtree must stay inside the parent clip after
        // the move: then each inner effective clip is the inner clip itself (it moves with the
        // content) and no node can become culled against the parent clip.
        const extent = memo.extent orelse return null;
        const moved_extent = shiftRect(extent, d[0], d[1]);
        const clip = in.parent_clip orelse ComputedRect.init(0, 0, cx.viewport.width, cx.viewport.height);
        if (moved_extent.x < clip.x or moved_extent.y < clip.y or
            moved_extent.x + moved_extent.w > clip.x + clip.w or moved_extent.y + moved_extent.h > clip.y + clip.h) return null;
        dx = d[0];
        dy = d[1];
    }
    const pt = cx.property_tree;
    const base_t: u32 = @intCast(pt.transforms.items.len);
    const base_c: u32 = @intCast(pt.clips.items.len);
    const base_e: u32 = @intCast(pt.effects.items.len);
    const moved = dx != 0 or dy != 0;

    // Validate every remapped reference before appending anything (all or nothing).
    for (memo.transforms) |*t| if (rebase(t.parent, memo.base_t, memo.transforms.len, base_t, memo.inputs.parent_transform_id, in.parent_transform_id) == INVALID_ID - 1) return null;
    for (memo.clips) |*c| {
        if (rebase(c.parent, memo.base_c, memo.clips.len, base_c, memo.inputs.parent_clip_id, in.parent_clip_id) == INVALID_ID - 1) return null;
        if (rebase(c.transform_id, memo.base_t, memo.transforms.len, base_t, memo.inputs.parent_transform_id, in.parent_transform_id) == INVALID_ID - 1) return null;
    }
    for (memo.effects) |*e| {
        if (rebase(e.parent, memo.base_e, memo.effects.len, base_e, memo.inputs.parent_effect_id, in.parent_effect_id) == INVALID_ID - 1) return null;
        if (rebase(e.transform_id, memo.base_t, memo.transforms.len, base_t, memo.inputs.parent_transform_id, in.parent_transform_id) == INVALID_ID - 1) return null;
    }
    pt.transforms.ensureUnusedCapacity(pt.allocator, memo.transforms.len) catch return null;
    pt.clips.ensureUnusedCapacity(pt.allocator, memo.clips.len) catch return null;
    pt.effects.ensureUnusedCapacity(pt.allocator, memo.effects.len) catch return null;
    cx.retained_nodes.ensureUnusedCapacity(cx.frame_allocator, memo.nodes.len) catch return null;
    cx.scene_runtime.nodes.ensureUnusedCapacity(@intCast(memo.records.len)) catch return null;

    for (memo.transforms) |*slot| {
        const t = slot.*;
        var n = t;
        n.parent = rebase(t.parent, memo.base_t, memo.transforms.len, base_t, memo.inputs.parent_transform_id, in.parent_transform_id);
        if (moved) {
            n.world = shiftTransform(t.world, dx, dy);
            n.inverse_world = n.world.invert();
            n.content = shiftTransform(t.content, dx, dy);
            n.flags.is_integer_translation = n.world.isIntegerTranslation(0.0001);
        }
        pt.transforms.appendAssumeCapacity(n);
        slot.* = n;
    }
    for (memo.clips) |*slot| {
        const c = slot.*;
        var n = c;
        n.parent = rebase(c.parent, memo.base_c, memo.clips.len, base_c, memo.inputs.parent_clip_id, in.parent_clip_id);
        n.transform_id = rebase(c.transform_id, memo.base_t, memo.transforms.len, base_t, memo.inputs.parent_transform_id, in.parent_transform_id);
        if (moved) n.world_aabb = shiftRect(c.world_aabb, dx, dy);
        pt.clips.appendAssumeCapacity(n);
        slot.* = n;
    }
    for (memo.effects) |*slot| {
        const e = slot.*;
        var n = e;
        n.parent = rebase(e.parent, memo.base_e, memo.effects.len, base_e, memo.inputs.parent_effect_id, in.parent_effect_id);
        n.transform_id = rebase(e.transform_id, memo.base_t, memo.transforms.len, base_t, memo.inputs.parent_transform_id, in.parent_transform_id);
        pt.effects.appendAssumeCapacity(n);
        slot.* = n;
    }
    var root_ids: node_state.RetainedIds = undefined;
    for (memo.records, memo.nodes, 0..) |*r, n_ptr, i| {
        // Updated in place: the memo then holds exactly what this frame got.
        const rec = r;
        rec.transform_id = rebase(rec.transform_id, memo.base_t, memo.transforms.len, base_t, memo.inputs.parent_transform_id, in.parent_transform_id);
        rec.clip_id = rebase(rec.clip_id, memo.base_c, memo.clips.len, base_c, memo.inputs.parent_clip_id, in.parent_clip_id);
        rec.effect_id = rebase(rec.effect_id, memo.base_e, memo.effects.len, base_e, memo.inputs.parent_effect_id, in.parent_effect_id);
        if (moved) {
            rec.world_bounds = shiftRect(rec.world_bounds, dx, dy);
            rec.content_transform = shiftTransform(rec.content_transform, dx, dy);
            rec.content_bounds = shiftRect(rec.content_bounds, dx, dy);
        }
        // Cache-derived fields: caches are written / dropped during the frame, read them fresh
        // (same expressions as appendRetainedMetadata).
        // Global DFS paint order shifts when anything earlier is inserted.
        rec.paint_order = n_ptr.frame_state.frame_local.spatial.paint.order;
        if (n_ptr.meta.per_frame.caches.commands.promoted) |*c| {
            rec.has_promoted_surface_cache = true;
            rec.promoted_surface_layer_id = c.promoted_layer_id;
            rec.promoted_surface_content_version = c.content_version;
            rec.promoted_surface_bounds = c.world_bounds;
            rec.promoted_surface_transform = c.world_transform;
        } else {
            rec.has_promoted_surface_cache = false;
            rec.promoted_surface_layer_id = scene_runtime_mod.INVALID_ID;
            rec.promoted_surface_content_version = 0;
            rec.promoted_surface_bounds = ComputedRect.init(0, 0, 0, 0);
            rec.promoted_surface_transform = Transform2D.identity();
        }
        if (i == 0) root_ids = .{ .transform_id = rec.transform_id, .clip_id = rec.clip_id, .effect_id = rec.effect_id };
        rec.retained_index = @intCast(cx.retained_nodes.items.len);
        cx.scene_runtime.nodes.putAssumeCapacity(rec.node_id, rec.*);
        cx.retained_nodes.appendAssumeCapacity(n_ptr);
    }
    // Refresh the memo to this frame's ids / positions: the next replay remaps from here.
    memo.inputs = in;
    memo.base_t = base_t;
    memo.base_c = base_c;
    memo.base_e = base_e;
    if (moved) memo.extent = if (memo.extent) |e| shiftRect(e, dx, dy) else null;
    cx.perf.rn_memo_replays += 1;
    cx.perf.rn_memo_replay_nodes += @intCast(memo.records.len);
    return root_ids;
}

/// Store the output buildRetainedSubtree just produced for `node` (ranges starting at the given
/// indices) as its memo.
pub const Range = struct { t0: usize, c0: usize, e0: usize, o0: usize, t1: usize, c1: usize, e1: usize, o1: usize };

pub fn record(cx: *RenderContext, node: *Node, in: Inputs, range: Range, summary: BuildSummary) void {
    const pt = cx.property_tree;
    const nodes = cx.retained_nodes.items[range.o0..range.o1];
    if (nodes.len == 0) return;
    const allocator = if (node.world_ref) |w| w.render_cache_allocator orelse cx.allocator else cx.allocator;
    var memo: *Memo = memoOf(node) orelse blk: {
        const m = allocator.create(Memo) catch return;
        m.* = .{ .allocator = allocator, .inputs = in, .viewport_w = 0, .viewport_h = 0, .base_t = 0, .base_c = 0, .base_e = 0 };
        node.meta.per_frame.caches.commands.retained_memo = @ptrCast(m);
        break :blk m;
    };
    const ok = resize(TransformNode, allocator, &memo.transforms, range.t1 - range.t0) and
        resize(ClipNode, allocator, &memo.clips, range.c1 - range.c0) and
        resize(EffectNode, allocator, &memo.effects, range.e1 - range.e0) and
        resize(SceneNodeRuntime, allocator, &memo.records, nodes.len) and
        resize(*Node, allocator, &memo.nodes, nodes.len);
    if (!ok) {
        dropMemo(node);
        return;
    }
    @memcpy(memo.transforms, pt.transforms.items[range.t0..range.t1]);
    @memcpy(memo.clips, pt.clips.items[range.c0..range.c1]);
    @memcpy(memo.effects, pt.effects.items[range.e0..range.e1]);
    @memcpy(memo.nodes, nodes);
    var extent: ?ComputedRect = null;
    for (memo.records, nodes) |*r, n| {
        r.* = cx.scene_runtime.nodes.get(n.id) orelse {
            dropMemo(node);
            return;
        };
        extent = if (extent) |e| unionRect(e, r.world_bounds) else r.world_bounds;
    }
    for (memo.clips) |*c| extent = if (extent) |e| unionRect(e, c.world_aabb) else c.world_aabb;
    memo.inputs = in;
    memo.viewport_w = cx.viewport.width;
    memo.viewport_h = cx.viewport.height;
    memo.base_t = @intCast(range.t0);
    memo.base_c = @intCast(range.c0);
    memo.base_e = @intCast(range.e0);
    memo.extent = extent;
    memo.root_rect = cx.rectFromWorld(node);
    memo.has_capture_owner = summary.has_capture_owner;
    memo.has_culled = summary.has_culled;
    cx.perf.rn_memo_records += 1;
}

fn resize(comptime T: type, allocator: Allocator, slice: *[]T, len: usize) bool {
    if (slice.len == len) return true;
    allocator.free(slice.*);
    slice.* = allocator.alloc(T, len) catch {
        slice.* = &.{};
        return false;
    };
    return true;
}

fn unionRect(a: ComputedRect, b: ComputedRect) ComputedRect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return ComputedRect.init(x0, y0, x1 - x0, y1 - y0);
}
