//! node_lifecycle: lifecycle + geometry/rect subdomains split out of node.zig.
//!
//! Node-typed free functions + @import("node.zig") circular import; node.zig keeps thin
//! delegates (original pub/private visibility).
//!
//! Highest-risk unit, these must move together:
//!   - rect callback unit (g_rect_query/g_rect_write + registrar)
//!   - standalone fallback rect storage (g_standalone_rects + Get/Set, keyed by node ptr,
//!     used by cx-less mock element_id==0xFFFFFFFF)
//! node.zig re-exports keep public API (external core.zig calls setRect*Callback).
//!
//! Lifecycle: create (via g_node_create_hook, hook unit migrates) / destroy (tree recursive
//! -> destroyForNode recursively calls self) / release{Path,Stroke,CustomClip,All}Geometry /
//! fireMountIfNeeded / fireCleanupCallbacks / clearNodeScopes (the last three are
//! file-scope free fns, not Node methods; node.zig re-exports).

const std = @import("std");
const node_mod = @import("node.zig");
const types = @import("types.zig");
const world_mod = @import("world.zig");

const Node = node_mod.Node;
const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const ElementTag = types.ElementTag;
const Style = types.Style;

// rect callback unit (moved from node.zig).
// Provides read/write rect from World.LayoutTable for functions without cx.

// Cross-Cx crosstalk detection.
// Node<->World routing still uses process-level global callbacks, and ElementId lacks World
// identity (both Worlds allocate from index 0), so querying World B with a Window A node
// falsely matches and returns wrong data, with no crash or signal.
// Node.world_id adds owner identity; validated here at each World access entry to expose
// crosstalk immediately rather than silently rendering incorrectly.
// Cx.init still rejects concurrent Cx, so this never fires in normal use; it is a safety
// net for removing the global callbacks. A missed path panics in debug builds instead of
// producing corrupted output.

/// Registered by core.zig: check whether node belongs to current active World.
pub const WorldOwnershipCheckFn = *const fn (node: *const Node) bool;
var g_world_ownership_check: ?WorldOwnershipCheckFn = null;

pub fn setWorldOwnershipCheck(check: ?WorldOwnershipCheckFn) void {
    g_world_ownership_check = check;
}

/// Check owner before accessing World table. Cross-Cx debug/safe build panic, release
/// silent allow (no new crash surface in production).
///
/// **Only applies to nodes still walking global callback** (world_ref == null). world_ref
/// nodes connect directly to their owner World and cannot crosstalk; "which World is active
/// now" is irrelevant, and asserting would break legitimate multi-Cx scenarios (node A owns
/// cx_a while g_active_world points at later-init'd cx_b). The assertion's scope shrinks
/// as nodes migrate.
inline fn assertOwnedByActiveWorld(node: *const Node, comptime site: []const u8) void {
    if (!std.debug.runtime_safety) return;
    if (node.world_ref != null) return; // Already directly connected to owner, no crosstalk possible
    const check = g_world_ownership_check orelse return;
    if (!check(node)) {
        std.debug.panic(
            "[zenit] cross-Cx node access at {s}: node.id={d} world_id={d} " ++
                "does not belong to the active World. " ++
                "Node↔World routing still goes through process-wide globals " ++
                "(ElementId carries no World identity, so a foreign id can falsely match)",
            .{ site, node.id, node.world_id },
        );
    }
}

pub const RectQueryFn = *const fn (element_id_raw: u32) ?ComputedRect;
var g_rect_query: ?RectQueryFn = null;

pub fn setRectQueryCallback(query: ?RectQueryFn) void {
    g_rect_query = query;
}

pub const RectWriteFn = *const fn (element_id_raw: u32, r: ComputedRect) void;
var g_rect_write: ?RectWriteFn = null;

pub fn setRectWriteCallback(write: ?RectWriteFn) void {
    g_rect_write = write;
}

// Node.create auto-registers to World's callback.
pub const NodeCreateHookFn = *const fn (node: *Node) void;
var g_node_create_hook: ?NodeCreateHookFn = null;

pub fn setNodeCreateHook(hook: ?NodeCreateHookFn) void {
    g_node_create_hook = hook;
}

// Standalone fallback rect storage (for element_id_raw == 0xFFFFFFFF nodes,
// test mock direct Node.create without cx). Hashmap keyed by node ptr.
// Note: production nodes (valid element_id, callback registered) also land here:
// onRectQuery uses `epoch == 0` to mean "registered but not laid out this frame" and
// returns null. See rectFromWorldOrFallback and the prelayout_zero_rect_reads counter.

var g_standalone_rects: std.AutoHashMap(usize, ComputedRect) = undefined;
var g_standalone_rects_init: bool = false;

fn standaloneRectGet(node_ptr: usize) ComputedRect {
    if (!g_standalone_rects_init) return ComputedRect.init(0, 0, 0, 0);
    return g_standalone_rects.get(node_ptr) orelse ComputedRect.init(0, 0, 0, 0);
}

fn standaloneRectSet(node_ptr: usize, r: ComputedRect) void {
    if (!g_standalone_rects_init) {
        g_standalone_rects = std.AutoHashMap(usize, ComputedRect).init(std.heap.page_allocator);
        g_standalone_rects_init = true;
    }
    // Cannot degrade: sole authoritative store for fallback node rects, lose write ->
    // standaloneRectGet returns 0x0, layout silent 0-size.
    g_standalone_rects.put(node_ptr, r) catch @panic("OOM: standalone rect store");
}

// geometry / rect methods

/// Read rect from global World, fallback standalone fallback storage on miss.
pub fn rectFromWorldOrFallback(self: *const Node) ComputedRect {
    assertOwnedByActiveWorld(self, "rectFromWorldOrFallback");
    // P0-3 Phase 3: directly use owner World, no process-level g_rect_query. Semantics
    // identical to old core.zig:onRectQuery (including epoch==0 "seeded but not markLaidOut"
    // check), only World source changes from global to node's owner.
    if (self.world_ref) |w| {
        if (self.element_id_raw != 0xFFFFFFFF) {
            const eid = world_mod.ElementId.fromRaw(self.element_id_raw);
            // createElement auto-seeds layout slot (default 0); epoch==0 means 'not yet
            // marked laid out'. rectIfLaidOut merges that check with rect read in one
            // MultiArrayList access (100k+ times per frame; in Debug, dual reads were once
            // the largest sampled hotspot).
            if (w.layout.rectIfLaidOut(eid)) |r| {
                return ComputedRect.init(r.x, r.y, r.width, r.height);
            }
        }
    } else if (g_rect_query) |query| {
        legacy_rect_query_hits += 1;
        // Fallback: old path when world_ref unset (theoretically only cx-less mocks remain).
        if (query(self.element_id_raw)) |r| return r;
    }
    // Two **semantically different** cases reach here:
    //
    // (a) True standalone: element_id == INVALID cx-less mock; reads fallback storage.
    // (b) **Registered but no layout yet**: onRectQuery uses `epoch == 0` to mean
    // 'registered but not marked laid out' and returns null (correct). Such nodes usually
    // have no fallback entry, so they silently get ComputedRect(0,0,0,0) -- a **silent
    // zero-rect path** matching symptoms in docs/BUGS.md like 'layout correct, paint empty'.
    //
    // (b) does hit the production path, ~3 times per mount, concentrated in pre-layout overlay
    // positioning queries. It is a **benign transient** (layout completion yields the true
    // value): no panic, but a debug counter records it so 'zero-rect' is not silently
    // treated as normal.
    if (std.debug.runtime_safety and self.element_id_raw != 0xFFFFFFFF and g_rect_query != null) {
        prelayout_zero_rect_reads += 1;
    }
    return standaloneRectGet(@intFromPtr(self));
}

/// Count of 'registered but not yet laid out' fallback to zero-rect (debug build
/// only). Should stop growing at steady state; persistent growth indicates a path
/// reads rect before layout -- the source of 'layout correct, paint empty' bugs.
pub var prelayout_zero_rect_reads: u64 = 0;

/// Count of rect queries still using **old global callbacks** (nodes with null
/// world_ref). After migration, only cx-less test mocks should remain; production
/// path should always be 0.
pub var legacy_rect_query_hits: u64 = 0;

/// Count of node creations still using `Node.create` (relies on g_node_create_hook
/// + g_active_world globals). Production paths should migrate to `Cx.createNode`
/// / `createIn`; at steady state, only cx-less tests hit this.
pub var legacy_node_create_hits: u64 = 0;

/// Unified write entry for component layer 'changing own child rects'.
/// Writes to World.LayoutTable and maintains standalone fallback storage.
pub fn setLayoutRect(self: *Node, r: ComputedRect) void {
    assertOwnedByActiveWorld(self, "setLayoutRect");
    // P0-3 phase 3: write directly to owner World (semantic equivalent of original
    // core.zig:onRectWrite).
    if (self.world_ref) |w| {
        if (self.element_id_raw != 0xFFFFFFFF) {
            const eid = world_mod.ElementId.fromRaw(self.element_id_raw);
            if (w.layout.ensureSlot(eid)) |_| {
                w.layout.markLaidOut(
                    eid,
                    .{ .width = r.w, .height = r.h },
                    .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h },
                );
            } else |_| {}
        }
    } else if (g_rect_write) |write| {
        write(self.element_id_raw, r);
    }
    // standalone fallback: only useful when element_id == 0xFFFFFFFF, but since
    // setLayoutRect doesn't know if World successfully marked laid out, write both as
    // insurance (production nodes: element_id != 0xFFFFFFFF, read path prefers World,
    // never hits).
    if (self.element_id_raw == 0xFFFFFFFF) {
        standaloneRectSet(@intFromPtr(self), r);
    }
}

pub fn setLayoutW(self: *Node, w: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.w = w;
    setLayoutRect(self, r);
}

pub fn setLayoutH(self: *Node, h: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.h = h;
    setLayoutRect(self, r);
}

pub fn setLayoutX(self: *Node, x: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.x = x;
    setLayoutRect(self, r);
}

pub fn setLayoutY(self: *Node, y: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.y = y;
    setLayoutRect(self, r);
}

/// Compute node's global absolute coordinate (traverse ancestor chain accumulating
/// rect + translate + sticky).
pub fn globalRect(self: *const Node) ComputedRect {
    var x: f32 = 0;
    var y: f32 = 0;
    var cur: ?*const Node = self;
    while (cur) |n| : (cur = n.parent) {
        const nr = rectFromWorldOrFallback(n);
        x += nr.x + n.style.translate_x + n.frame_state.frame_local.runtime.sticky.x;
        y += nr.y + n.style.translate_y + n.frame_state.frame_local.runtime.sticky.y;
    }
    const sr = rectFromWorldOrFallback(self);
    return .{ .x = x, .y = y, .w = sr.w, .h = sr.h };
}

// Lifecycle: create / destroy / release*Geometry

pub fn create(allocator: Allocator, id: u32, tag: ElementTag, style: Style) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .id = id,
        .tag = tag,
        .style = style,
        .children = .empty,
    };
    // If the current active cx registered the hook, auto linkNodeToWorld (setLayoutRect truly
    // writes the World table, so the fallback field never becomes source-of-truth).
    //
    // This is the **last of 19 global callbacks still used by production**.
    // Chicken-and-egg: the node lacks world_ref at call time, so it can't self-bootstrap.
    // `createIn()` (below) is the explicit-World version for multi-window scenarios;
    // this one is kept for the existing API and many cx-less tests.
    if (g_node_create_hook) |hook| {
        legacy_node_create_hits += 1;
        hook(node);
    }
    @import("node_tree.zig").hostCreated(node);
    return node;
}

/// Node tag -> World tag (consistent with core.zig:nodeTagToWorldTag).
fn worldTagForElementTag(t: ElementTag) world_mod.ElementTag {
    return switch (t) {
        .box, .scroll, .list, .spacer, .anchor => .container,
        .text => .text,
        .image => .image,
        .input, .button => .input,
        .custom => .component,
    };
}

/// Node creation with explicit owner World, no process-level globals.
///
/// Once all production paths use this, g_node_create_hook and g_active_world can retire,
/// enabling true multi-Cx coexistence.
/// Semantically equivalent to core.zig:onNodeCreate: allocate element slot + stamp owner.
pub fn createIn(
    allocator: Allocator,
    world: *world_mod.World,
    world_id: u16,
    id: u32,
    tag: ElementTag,
    style: Style,
) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .id = id,
        .tag = tag,
        .style = style,
        .children = .empty,
    };
    // Direct destroy bypasses poison cleanup in destroy()/freeNodeNow, so manually
    // poison here: otherwise freed memory with ALIVE tag returned to allocator, reuse
    // causes sentinel to misidentify as live node.
    errdefer {
        node.alive_sentinel = node_mod.DEAD_SENTINEL;
        allocator.destroy(node);
    }

    const eid = try world.createElement(.{
        .tag = worldTagForElementTag(tag),
        .key = id,
    });
    node.element_id_raw = eid.raw();
    node.world_id = world_id;
    node.world_ref = world;
    @import("node_tree.zig").hostCreated(node);
    return node;
}

/// Preserve mode: recursively destroy node and subtree.
///
/// Note: does not dispose scopes. Scope lifecycle is managed by the scope tree
/// (parent Scope.dispose() recursively disposes children). Caller should dispose
/// scope before destroy, then clearNodeScopes to clear dangling pointers.
pub fn destroy(self: *Node, allocator: Allocator) void {
    // Same form as Cx.freeNodeNow: sentinel check must come **before freeing**.
    // In Debug, freed memory written as 0xaa; `freeing` field reads as true, causing
    // double-free to silently early-return. Second free path; missing it means sentinel
    // only catches half.
    if (self.alive_sentinel != node_mod.ALIVE_SENTINEL) {
        @panic("Node.destroy: 节点已被释放（double free）或内存已损坏");
    }
    if (self.freeing) return;
    self.freeing = true;
    @import("node_tree.zig").g_retire_gen +%= 1;
    self.deferred_disposal.cancel();
    self.pending_free_cx = null;
    for (self.children.items) |child| {
        destroy(child, allocator);
    }

    // Remove before call: same hook must not be repeatedly triggered by destroy /
    // freeNodeNow / fireCleanupCallbacks (see Cx.freeNodeNow comment).
    if (self.meta.ownership.hooks.on_cleanup) |h| {
        self.meta.ownership.hooks.on_cleanup = null;
        h.invoke();
        self.frame_state.state_bits.flags.is_mounted = false;
    }

    // Caller responsible for disposing scope; just clear pointer here.
    self.meta.ownership.scope.scope = null;
    if (self.meta.per_frame.hooks.style_host) |h| {
        self.meta.per_frame.hooks.style_host = null;
        h.destroy(h.ptr);
    }
    if (self.meta.per_frame.hooks.theme_inline) |rec| {
        self.meta.per_frame.hooks.theme_inline = null;
        rec.destroy();
    }

    self.invalidateRenderCache();
    self.invalidatePromotedRenderCache();
    self.invalidateSubtreePayloadCache();

    // Free dynamically allocated test_id.
    if (self.frame_state.state_bits.flags.test_id_owned) {
        if (self.meta.ownership.meta.test_id) |tid| {
            allocator.free(tid);
        }
        self.meta.ownership.meta.test_id = null;
        self.frame_state.state_bits.flags.test_id_owned = false;
    }

    // Free StyleExt extension (contains Grid config pointer).
    if (self.style.ext) |ext| {
        if (ext.grid) |gc| {
            allocator.destroy(gc);
        }
        allocator.destroy(ext);
        self.style.ext = null;
    }

    // Free Transition slot.
    if (self.frame_state.frame_local.runtime.transitions) |ts| {
        allocator.destroy(ts);
        self.frame_state.frame_local.runtime.transitions = null;
    }

    // Free NodeAnimations slot (aligned with Cx.freeNodeNow, only previous omission).
    if (self.frame_state.frame_local.runtime.commands) |na| {
        na.deinit();
        allocator.destroy(na);
        self.frame_state.frame_local.runtime.commands = null;
    }

    // Free owned text content to prevent leak.
    if (self.getTextRaw()) |t| {
        if (t.spans_owned and t.spans.len > 0) {
            allocator.free(t.spans);
        }
        if (t.owned and t.content.len > 0) {
            allocator.free(t.content);
        }
    }

    releasePathGeometry(self, allocator);
    releaseStrokeGeometry(self, allocator);
    releaseCustomClipGeometry(self, allocator);

    if (self.world_ref) |w| {
        w.layout_output.clear(world_mod.ElementId.fromRaw(self.element_id_raw));
    }
    releaseStandaloneState(self);

    // World's DevTools style source table sparsely holds by element raw key; remove
    // on node reclaim to prevent diagnosis table only growing in long-lived windows with
    // frequent mount/unmount.
    if (self.world_ref) |w| w.clearStyleOrigins(self.element_id_raw);

    @import("layout_engine.zig").forgetIntrinsicCache(self.world_id, self.id);
    self.children.deinit(allocator);
    // Poison: if freed node used as live, sentinel check panics immediately rather
    // than relying on 0xaa to make `freeing` read true for silent early-return.
    self.alive_sentinel = node_mod.DEAD_SENTINEL;
    allocator.destroy(self);
}

/// Called by both standalone destroy and Cx reclamation, after owned payloads.
// Both Node.destroy and Cx.freeNodeNow pass this release boundary. Layout's
// callback publication compares the epoch without dereferencing freed nodes.
pub const ReleaseWatch = struct {
    node: *const Node,
    alive: bool = true,
    previous: ?*ReleaseWatch = null,
    pub fn begin(self: *ReleaseWatch) void {
        self.previous = release_watch_head;
        release_watch_head = self;
    }
    pub fn end(self: *ReleaseWatch) void {
        std.debug.assert(release_watch_head == self);
        release_watch_head = self.previous;
    }
};
var release_watch_head: ?*ReleaseWatch = null;

var node_release_revision: u64 = 0;
pub fn releaseRevision() u64 {
    return node_release_revision;
}

pub fn releaseStandaloneState(node: *Node) void {
    @import("node_tree.zig").hostDestroyed(node);
    node_release_revision +%= 1;
    var watch = release_watch_head;
    while (watch) |w| : (watch = w.previous) {
        if (w.node == node) w.alive = false;
    }
    const ptr = @intFromPtr(node);
    @import("paint_content_accessor.zig").releaseStandaloneNode(ptr);
    if (g_standalone_rects_init) _ = g_standalone_rects.remove(ptr);
}

pub fn releasePathGeometry(self: *Node, allocator: Allocator) void {
    const lo = self.layoutOutputPtr() orelse return;
    if (lo.vector.fill.path) |geometry| {
        if (geometry.owned and geometry.commands.len > 0) {
            allocator.free(geometry.commands);
        }
        lo.vector.fill.path = null;
    }
}

pub fn releaseStrokeGeometry(self: *Node, allocator: Allocator) void {
    const lo = self.layoutOutputPtr() orelse return;
    if (lo.vector.stroke.geometry) |geometry| {
        if (geometry.owned and geometry.commands.len > 0) {
            allocator.free(geometry.commands);
        }
        lo.vector.stroke.geometry = null;
    }
}

pub fn releaseCustomClipGeometry(self: *Node, allocator: Allocator) void {
    if (self.layoutOutputPtr()) |lo| {
        if (lo.vector.fill.custom_clip) |geometry| {
            if (geometry.owned and geometry.commands.len > 0) {
                allocator.free(geometry.commands);
            }
            lo.vector.fill.custom_clip = null;
        }
    }
    self.meta.per_frame.custom_hooks.clip_meta.cache_rect = ComputedRect.init(-1, -1, -1, -1);
    self.meta.per_frame.custom_hooks.clip_meta.cache_epoch = 0;
}

/// freeNode use: free node's path heap memory (path / stroke / custom_clip) via
/// World.layout_output slot. Must call before elements.destroy (element_id still
/// valid, layoutOutputPtr can reach slot; after slot reuse is dirty). Semantic
/// equivalent of freeNode freeing owned text first.
pub fn releaseAllGeometry(self: *Node, allocator: Allocator) void {
    releasePathGeometry(self, allocator);
    releaseStrokeGeometry(self, allocator);
    releaseCustomClipGeometry(self, allocator);
}

// mount/cleanup/scope (originally file-scope free fns, not Node methods)

/// Fire onMount for current node (once after first layout).
pub fn fireMountIfNeeded(node: *Node) void {
    if (!node.frame_state.state_bits.flags.is_mounted) {
        node.frame_state.state_bits.flags.is_mounted = true;
        if (node.meta.ownership.hooks.on_mount) |mount_handler| {
            mount_handler.invoke();
        }
    }
}

/// Recursively fire onCleanup callbacks for mounted nodes (leaf to root).
///
/// **Remove before call**: on_cleanup has three trigger points (here, Node.destroy,
/// Cx.freeNodeNow); all must 'extract-then-null' so it fires once only. Otherwise normal
/// teardown (removeChild / detachChild -> freeNode) invokes it twice on mounted nodes
/// (callbacks typically 'free one-time resource'; ScrollArea could underflow a refcount).
/// Unmounted nodes skip and **preserve field** for destroy/freeNodeNow to trigger once.
pub fn fireCleanupCallbacks(node: *Node) void {
    const tree = @import("node_tree.zig");
    var index: usize = 0;
    while (index < node.children.items.len) {
        const revision = tree.structureRevision();
        const child = node.children.items[index];
        fireCleanupCallbacks(child);
        // Re-read after every callback; removals invalidate the old ArrayList
        // slice, and reorder/removal of earlier siblings can move unvisited
        // nodes behind the cursor. Consumed hooks remain one-shot on restart.
        if (tree.structureRevision() == revision) index += 1 else index = 0;
    }
    if (node.frame_state.state_bits.flags.is_mounted) {
        node.frame_state.state_bits.flags.is_mounted = false;
        // Cleanup may be followed by a same-geometry remount, even without a
        // tree mutation. Restore the conservative publication path before user
        // code can reenter layout. Stop at an already-pending ancestor.
        var pending: ?*Node = node;
        while (pending) |current| {
            if (current.frame_state.frame_local.runtime.layout_mount_pending) break;
            current.frame_state.frame_local.runtime.layout_mount_pending = true;
            pending = current.parent;
        }
        if (node.meta.ownership.hooks.on_cleanup) |cleanup_handler| {
            node.meta.ownership.hooks.on_cleanup = null;
            cleanup_handler.invoke();
        }
    }
}

/// Recursively clear scope pointers on node subtree.
/// For scenarios freeing root_scope before node memory, avoids accessing freed Scope.
pub fn clearNodeScopes(node: *Node) void {
    if (node.meta.ownership.scope.node_slot) |slot| {
        slot.* = null;
        node.meta.ownership.scope.node_slot = null;
    }
    node.meta.ownership.scope.scope = null;
    // Mark hook/component state pointers invalid to avoid dangling references after
    // scope freed first.
    node.meta.per_frame.hooks.slots.hover_highlight_state = null;
    node.meta.per_frame.hooks.slots.anim_state = null;
    node.meta.per_frame.hooks.slots.focus_ring_anim = null;
    node.meta.per_frame.hooks.slots.focus_ring_owned = false;
    for (node.children.items) |child| {
        clearNodeScopes(child);
    }
}

/// Free standalone rect fallback storage (see paint_content_accessor.zig same-named
/// function docs: these tables are process-level + page_allocator, GPA leak check
/// blind spot). Idempotent.
pub fn deinitStandaloneRects() void {
    if (!g_standalone_rects_init) return;
    g_standalone_rects.deinit();
    g_standalone_rects_init = false;
}

/// Current standalone rect table entry count (diagnostic/acceptance use).
pub fn standaloneRectCount() usize {
    if (!g_standalone_rects_init) return 0;
    return g_standalone_rects.count();
}
