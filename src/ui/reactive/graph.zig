//! Reactive Graph: push-pull hybrid scheduler core.
//!
//! Fixes naive depth-first push (signal.notifyImpl synchronously driving
//! effect.runWithTracking):
//!   1. Diamond dependency: A->B(memo)->C, A->C, C may see stale memo before B recomputes
//!   2. Memo eager computation: runs even if unread
//!   3. batch flush hard limit 16 + insertion-order traversal: glitches in diamonds
//!
//! Design sources:
//!   - Solid v1: dirty/check two-phase marking + lazy memo (adopted)
//!   - Reactively: version stamp + pull-up comparison (adopted)
//!   - SwiftUI AttributeGraph: pure pull; we take lazy memo only, effects stay push, and
//!     provide dumpGraph + traceUpdate to avoid its black-box problem
//!   - React fiber priority queue: too heavy, not adopted
//!
//! Data model:
//!   GraphNode {
//!     kind: signal | memo | effect
//!     version: u64                 (signal: write++; memo: recompute and value changed++)
//!     state: clean | check | dirty (Solid v1 style three-state)
//!     depth: u32                   (topological depth; dynamic deps: max(sources)+1)
//!     sources: []ReactiveNodeId    (I read from)
//!     observers: []ReactiveNodeId  (who reads me)
//!   }
//!
//! Algorithm:
//!   write(signal):
//!     signal.version += 1
//!     for obs in signal.observers: markCheck(obs)  // no recursive push effect
//!     enqueue dirty observers (effects only)
//!
//!   markCheck(node):
//!     if node.state == clean: node.state = check
//!     for obs: markCheck(obs)  // recurse only on clean->check transition (prevents dupes)
//!
//!   read(memo):
//!     updateIfNecessary(memo)
//!     return memo.value
//!
//!   updateIfNecessary(node):
//!     if node.state == clean: return
//!     if node.state == check:
//!       for src in node.sources:
//!         updateIfNecessary(src)
//!         if src.version > node.last_seen_version[src]: node.state = dirty; break
//!       if still check: node.state = clean; return
//!     if node.state == dirty: recompute(node); node.state = clean

const std = @import("std");
const testing = std.testing;
const eqlValue = @import("eq.zig").eqlValue;

// ============================================================================
// Node ID and type
// ============================================================================

pub const NodeKind = enum(u8) {
    signal,
    memo,
    effect,
};

pub const NodeState = enum(u8) {
    clean,
    check,
    dirty,
};

pub const NodeId = packed struct(u32) {
    index: u24,
    generation: u8,

    pub const NULL: NodeId = .{ .index = 0xFFFFFF, .generation = 0xFF };
    /// Probe reader (used by `scope.derive` to check if has dependencies): no edge created,
    /// only probe_reads counter. Not NULL, not alive node.
    pub const PROBE: NodeId = .{ .index = 0xFFFFFE, .generation = 0xFF };

    pub fn isNull(self: NodeId) bool {
        return self.index == 0xFFFFFF;
    }

    pub fn eq(a: NodeId, b: NodeId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

// ============================================================================
// GraphNode
// ============================================================================

pub const RecomputeFn = *const fn (ctx: *anyopaque) bool; // returns true if value changed

pub const GraphNode = struct {
    /// Test provenance: an observer that replaces a release theme replay.
    /// Dependency checks must still reject any business signal capture.
    test_preview_style_infrastructure: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},
    kind: NodeKind,
    state: NodeState,
    /// Value version; incremented on signal write or memo recompute with value change
    version: u64,
    /// Topological depth. signal=0; memo/effect=max(sources.depth)+1
    depth: u32,
    /// Nodes I depend on (sources I've read)
    sources: std.ArrayListUnmanaged(NodeId),
    /// Who observes me (notified on write)
    observers: std.ArrayListUnmanaged(NodeId),
    /// Version snapshot of each source at last recompute; updateIfNecessary compares against this
    seen_versions: std.ArrayListUnmanaged(u64),
    /// Each source's run epoch when last hit by trackRead during recompute; after recompute,
    /// sources with epoch < current_run are pruned (dynamic dependency cleanup).
    /// Parallel to sources / seen_versions.
    source_runs: std.ArrayListUnmanaged(u32),
    /// Current recompute's run epoch, incremented; trackRead writes to corresponding source_runs
    /// slot.
    current_run: u32 = 0,
    /// For memo/effect: recompute entry; signal is null
    recompute: ?RecomputeFn = null,
    /// Recompute closure context (memo/effect state)
    recompute_ctx: ?*anyopaque = null,
    /// Whether the node is still alive (false = released; generation is managed by SlotMap, this
    /// flag only marks logical death)
    alive: bool = true,
    /// effect re-entrance guard
    is_running: bool = false,
    /// Failed dependency capture must never publish this run as clean.
    tracking_failed: bool = false,
};

// ============================================================================
// ReactiveGraph: global scheduler
// ============================================================================

/// Dependency tracking push failures (OOM/stack full). Each means one recompute skipped,
/// node keeps stale value; steady-state must stay 0.
pub var reactive_tracking_failures: u64 = 0;
/// Reactive dependency chains deeper than this are rejected before they can
/// exhaust the process stack. Real UI graphs are normally shallow; the bound
/// primarily protects applications that compile untrusted nested data into a
/// memo/effect chain.
pub const max_reactive_recursion_depth: usize = 128;
pub var reactive_depth_limit_hits: u64 = 0;
/// Test silent switch (Zig test runner treats std.log.err as test failure,
/// but 'error reported' is the behavior to assert).
pub var suppress_reactive_error_log: bool = false;

pub const ReactiveGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(GraphNode),
    /// Tracking reads when stack top is `NodeId.PROBE` (wrap counter, compare before/after
    /// equality)
    probe_reads: u32 = 0,
    free_list: std.ArrayListUnmanaged(u24),
    generations: std.ArrayListUnmanaged(u8),

    /// Node currently being recomputed (tracking stack top)
    tracking_stack: std.ArrayListUnmanaged(NodeId),
    /// Tracking enabled (disabled by untrack)
    tracking_enabled: bool,

    /// Pending effects queue; sorted by depth and drained at endBatch. Capacity >= node slots
    /// (see `reserveNotification`).
    pending_effects: std.ArrayListUnmanaged(NodeId),
    /// A committed write could not finish propagation. Recover unqueued effects
    /// by scanning nodes; memo reads recover through conservative `.check` states.
    rescan_effects: bool = false,
    /// Temp buffer during drain (swap with pending_effects to avoid alloc)
    drain_buffer: std.ArrayListUnmanaged(NodeId),
    /// Reused DFS worklist for observer propagation. Capacity is reserved
    /// before any node state changes, so worklist OOM cannot half-dirty a graph.
    propagation_stack: std.ArrayListUnmanaged(NodeId),
    /// batch nesting depth (stack-style); write doesn't drain immediately when > 0
    batch_depth: u32,
    /// draining during flush to prevent re-entrance
    flushing: bool,
    /// `updateIfNecessary` may recurse both through source checks and through
    /// user recompute callbacks. Keep the depth on the graph so both paths
    /// share one budget instead of resetting at callback boundaries.
    update_depth: usize,

    pub fn init(allocator: std.mem.Allocator) ReactiveGraph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .free_list = .empty,
            .generations = .empty,
            .tracking_stack = .empty,
            .tracking_enabled = true,
            .pending_effects = .empty,
            .drain_buffer = .empty,
            .propagation_stack = .empty,
            .batch_depth = 0,
            .flushing = false,
            .update_depth = 0,
        };
    }

    pub fn deinit(self: *ReactiveGraph) void {
        for (self.nodes.items) |*n| {
            if (!n.alive) continue; // destroyNode already reclaimed these ArrayLists
            n.sources.deinit(self.allocator);
            n.observers.deinit(self.allocator);
            n.seen_versions.deinit(self.allocator);
            n.source_runs.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.tracking_stack.deinit(self.allocator);
        self.pending_effects.deinit(self.allocator);
        self.drain_buffer.deinit(self.allocator);
        self.propagation_stack.deinit(self.allocator);
        self.* = undefined;
    }

    // --------
    // Node lifecycle
    // --------

    pub fn createSignal(self: *ReactiveGraph) !NodeId {
        return try self.createNode(.{
            .kind = .signal,
            .state = .clean,
            .version = 1,
            .depth = 0,
            .sources = .empty,
            .observers = .empty,
            .seen_versions = .empty,
            .source_runs = .empty,
        });
    }

    pub fn createMemo(
        self: *ReactiveGraph,
        recompute: RecomputeFn,
        ctx: *anyopaque,
    ) !NodeId {
        return try self.createNode(.{
            .kind = .memo,
            .state = .dirty, // computed on first read
            .version = 0,
            .depth = 0,
            .sources = .empty,
            .observers = .empty,
            .seen_versions = .empty,
            .source_runs = .empty,
            .recompute = recompute,
            .recompute_ctx = ctx,
        });
    }

    pub fn createEffect(
        self: *ReactiveGraph,
        recompute: RecomputeFn,
        ctx: *anyopaque,
    ) !NodeId {
        const id = try self.createNode(.{
            .kind = .effect,
            .state = .dirty,
            .version = 0,
            .depth = 0,
            .sources = .empty,
            .observers = .empty,
            .seen_versions = .empty,
            .source_runs = .empty,
            .recompute = recompute,
            .recompute_ctx = ctx,
        });
        // effect runs once immediately on creation (establish dependencies)
        self.runEffect(id);
        return id;
    }

    /// Lazy-run: the facade first establishes the EffectBase <-> graph node backref, then triggers
    /// the first run itself. Otherwise the first graph.recomputeNode calls the callback before
    /// EffectBase.graph_node_raw is set, losing a frame of dependency tracking.
    ///
    /// CRITICAL: effect is created with state=clean (not dirty). The facade immediately runs
    /// EffectBase.runWithTracking to collect dependencies; signal propagate then correctly
    /// transitions clean->dirty and enqueues. If state started dirty, propagate would skip it
    /// ('if obs.state==dirty continue').
    pub fn createNodeRaw(
        self: *ReactiveGraph,
        kind: NodeKind,
        recompute: RecomputeFn,
        ctx: *anyopaque,
    ) !NodeId {
        return try self.createNode(.{
            .kind = kind,
            // signal/effect start clean; memo stays .dirty (lazy, computed on first read)
            .state = if (kind == .memo) .dirty else .clean,
            .version = if (kind == .signal) 1 else 0,
            .depth = 0,
            .sources = .empty,
            .observers = .empty,
            .seen_versions = .empty,
            .source_runs = .empty,
            .recompute = recompute,
            .recompute_ctx = ctx,
        });
    }

    fn createNode(self: *ReactiveGraph, node: GraphNode) !NodeId {
        // Generation retirement (ABA prevention, aligns with element_id.SlotMap): slots with
        // generation=0xFF permanently retire, never reused. alive bit insufficient to prevent
        // false matches after reuse; 255th reuse wrap causes stale NodeId re-isAlive,
        // dangling graph_node_raw -> unrelated node.
        while (self.free_list.pop()) |idx| {
            const next_gen = self.generations.items[idx] +% 1;
            if (next_gen == 0xFF) {
                self.generations.items[idx] = 0xFF;
                continue;
            }
            self.nodes.items[idx] = node;
            self.generations.items[idx] = next_gen;
            return .{ .index = idx, .generation = next_gen };
        }
        const idx = self.nodes.items.len;
        if (idx >= 0xFFFFFF) return error.GraphFull;
        // Prepare all parallel storage before publishing a live slot. Reserve
        // reclamation too: destroying a node must not allocate or lose its slot.
        try self.nodes.ensureTotalCapacity(self.allocator, idx + 1);
        try self.generations.ensureTotalCapacity(self.allocator, idx + 1);
        try self.free_list.ensureTotalCapacity(self.allocator, idx + 1);
        try self.reserveNotification(idx + 1);
        self.nodes.appendAssumeCapacity(node);
        self.generations.appendAssumeCapacity(0);
        return .{ .index = @intCast(idx), .generation = 0 };
    }

    /// Notification capacity invariant: the propagation worklist and both effect queues hold
    /// at least one entry per node slot. A walk visits each node at most once and a queue holds
    /// each effect at most once (it is enqueued only while clean), so a signal write
    /// (`markSignalWritten`) never allocates to notify its observers: `Signal.set` cannot
    /// report an error, and an allocation failure there used to leave a committed value whose
    /// observers only caught up on some later write. The growth is reserved where it can fail
    /// visibly, when a node is created (signals, memos and effects are created while mounting).
    fn reserveNotification(self: *ReactiveGraph, slots: usize) !void {
        try self.propagation_stack.ensureTotalCapacity(self.allocator, slots);
        try self.pending_effects.ensureTotalCapacity(self.allocator, slots);
        // During a drain `drain_buffer` holds the batch being run (read by index, so growing it
        // here is safe); it is the queue that receives the next batch after the swap.
        try self.drain_buffer.ensureTotalCapacity(self.allocator, slots);
    }

    pub fn destroyNode(self: *ReactiveGraph, id: NodeId) void {
        if (!self.isAlive(id)) return;
        const n = &self.nodes.items[id.index];
        // Remove self from all sources' observers
        for (n.sources.items) |src_id| {
            if (self.isAlive(src_id)) {
                const src = &self.nodes.items[src_id.index];
                removeFromList(&src.observers, id);
            }
        }
        // Remove self from all observers' sources (observers remain but lose this source)
        for (n.observers.items) |obs_id| {
            if (self.isAlive(obs_id)) {
                const obs = &self.nodes.items[obs_id.index];
                if (indexOf(obs.sources, id)) |idx| {
                    _ = obs.sources.swapRemove(idx);
                    if (idx < obs.seen_versions.items.len) {
                        _ = obs.seen_versions.swapRemove(idx);
                    }
                    if (idx < obs.source_runs.items.len) {
                        _ = obs.source_runs.swapRemove(idx);
                    }
                }
            }
        }
        n.sources.deinit(self.allocator);
        n.observers.deinit(self.allocator);
        n.seen_versions.deinit(self.allocator);
        n.source_runs.deinit(self.allocator);
        n.alive = false;
        self.free_list.appendAssumeCapacity(id.index);
    }

    pub fn isAlive(self: *const ReactiveGraph, id: NodeId) bool {
        if (id.isNull()) return false;
        if (id.index >= self.nodes.items.len) return false;
        if (self.generations.items[id.index] != id.generation) return false;
        return self.nodes.items[id.index].alive;
    }

    pub fn getNode(self: *ReactiveGraph, id: NodeId) ?*GraphNode {
        if (!self.isAlive(id)) return null;
        return &self.nodes.items[id.index];
    }

    pub fn getNodeConst(self: *const ReactiveGraph, id: NodeId) ?*const GraphNode {
        if (!self.isAlive(id)) return null;
        return &self.nodes.items[id.index];
    }

    // --------
    // Dependency tracking
    // --------

    /// Called on signal/memo read to establish caller -> callee edge.
    /// Called by facade in get/peek paths.
    pub fn trackRead(self: *ReactiveGraph, source_id: NodeId) !void {
        if (!self.tracking_enabled) return;
        if (self.tracking_stack.items.len == 0) return;
        const reader_id = self.tracking_stack.items[self.tracking_stack.items.len - 1];
        if (reader_id.eq(NodeId.PROBE)) {
            self.probe_reads +%= 1;
            return;
        }
        if (reader_id.eq(source_id)) return; // self-loop impossible but safe to check
        self.addEdge(reader_id, source_id) catch |err| {
            if (self.getNode(reader_id)) |reader| {
                reader.tracking_failed = true;
                reader.state = .dirty;
            }
            reactive_tracking_failures +|= 1;
            return err;
        };
    }

    fn addEdge(self: *ReactiveGraph, reader: NodeId, source: NodeId) !void {
        const r = self.getNode(reader) orelse return;
        const s = self.getNode(source) orelse return;
        // Dedup: already have source? Mark current_run (v0.5-P2 epoch-based tracking)
        for (r.sources.items, 0..) |existing, i| {
            if (existing.eq(source)) {
                if (i < r.source_runs.items.len) {
                    r.source_runs.items[i] = r.current_run;
                }
                return;
            }
        }
        // Reserve all four tables then write atomically: OOM mid-write leaves partial edge
        // (source added but seen_versions/source_runs missing -> version misalign, memo
        // won't recompute; or forward edge without reverse observer -> never awakened).
        try r.sources.ensureUnusedCapacity(self.allocator, 1);
        try r.seen_versions.ensureUnusedCapacity(self.allocator, 1);
        try r.source_runs.ensureUnusedCapacity(self.allocator, 1);
        try s.observers.ensureUnusedCapacity(self.allocator, 1);
        r.sources.appendAssumeCapacity(source);
        r.seen_versions.appendAssumeCapacity(s.version);
        r.source_runs.appendAssumeCapacity(r.current_run);
        s.observers.appendAssumeCapacity(reader);

        // Topological depth update
        if (s.depth + 1 > r.depth) r.depth = s.depth + 1;
    }

    /// Public version, facade (EffectBase.runWithTracking) calls before effectFn run,
    /// pairs with dynamic dependency tracking.
    pub fn clearSourcesPub(self: *ReactiveGraph, id: NodeId) void {
        self.clearSources(id);
    }

    /// Clear all source edges for node (call before recompute, pairs with dynamic dependency)
    fn clearSources(self: *ReactiveGraph, id: NodeId) void {
        const n = self.getNode(id) orelse return;
        for (n.sources.items) |src_id| {
            const s = self.getNode(src_id) orelse continue;
            removeFromList(&s.observers, id);
        }
        n.sources.clearRetainingCapacity();
        n.seen_versions.clearRetainingCapacity();
        n.source_runs.clearRetainingCapacity();
    }

    /// Check if current reader (effect/memo) has read `source_id` this round.
    /// For debug-mode 'effect writes signal it reads' warning.
    pub fn currentReaderReads(self: *const ReactiveGraph, source_id: NodeId) bool {
        if (self.tracking_stack.items.len == 0) return false;
        const reader_id = self.tracking_stack.items[self.tracking_stack.items.len - 1];
        const r = self.getNodeConst(reader_id) orelse return false;
        for (r.sources.items, 0..) |existing, i| {
            if (!existing.eq(source_id)) continue;
            return i >= r.source_runs.items.len or r.source_runs.items[i] == r.current_run;
        }
        return false;
    }

    pub fn pushTracking(self: *ReactiveGraph, id: NodeId) !void {
        try self.tracking_stack.append(self.allocator, id);
    }

    pub fn popTracking(self: *ReactiveGraph) void {
        _ = self.tracking_stack.pop();
    }

    pub fn untrack(self: *ReactiveGraph, comptime fnRef: anytype, args: anytype) @TypeOf(@call(.auto, fnRef, args)) {
        const prev = self.tracking_enabled;
        self.tracking_enabled = false;
        defer self.tracking_enabled = prev;
        return @call(.auto, fnRef, args);
    }

    // --------
    // Write path
    // --------

    /// Mark signal written (caller wrote new value and confirmed inequality).
    pub fn markSignalWritten(self: *ReactiveGraph, id: NodeId) !void {
        const n = self.getNode(id) orelse return;
        std.debug.assert(n.kind == .signal);
        n.version +%= 1;
        // Mark direct observers dirty, indirect observers check
        var first_error: ?anyerror = null;
        self.propagate(id) catch |err| {
            // The caller already committed the signal value and version. A
            // clean observer is therefore not retryable by an equal-value set.
            // Mark derived nodes for version checks without allocating; unrelated
            // dependencies retain their values and do not rerun their effects.
            for (self.nodes.items) |*node| {
                if (node.alive and node.kind != .signal and node.state == .clean)
                    node.state = .check;
            }
            self.rescan_effects = true;
            first_error = err;
        };
        // drain immediately if outside batch
        if (self.batch_depth == 0) {
            self.drainPendingEffects() catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| return err;
    }

    fn propagate(self: *ReactiveGraph, source_id: NodeId) !void {
        // Each node transitions out of `.clean` at most once in this walk, so
        // `nodes.len` is a strict upper bound. Reserve before touching state:
        // an OOM is recovered conservatively by markSignalWritten because the
        // source value and version have already committed.
        try self.propagation_stack.ensureTotalCapacity(self.allocator, self.nodes.items.len);
        self.propagation_stack.clearRetainingCapacity();

        const src = self.getNode(source_id) orelse return;
        // Don't copy observer list, traverse directly. Observers cannot change during propagate:
        // 1. we only modify obs.state and enqueue pending effects, never add/remove observers;
        // 2. real effect runs happen in drainPendingEffects, after propagate has finished.
        // Avoids O(N) copy, significant for 1k fanout.
        const observers_len = src.observers.items.len;
        var first_error: ?anyerror = null;
        var i: usize = 0;
        while (i < observers_len) : (i += 1) {
            const obs_id = src.observers.items[i];
            const obs = self.getNode(obs_id) orelse continue;
            if (obs.state == .dirty) continue;
            // **Enqueue before state change**: reversed order on OOM leaves effect in 'dirty
            // but not pending', skipped forever. Enqueue-first keeps unchanged, retryable on next
            // write. Observers deduplicated by addEdge, no double-enqueue.
            if (obs.kind == .effect) {
                self.pending_effects.append(self.allocator, obs_id) catch |err| {
                    if (first_error == null) first_error = err;
                    continue;
                };
            }
            obs.state = .dirty;
            self.propagation_stack.appendAssumeCapacity(obs_id);
        }

        // A hostile/degenerated graph may contain tens of thousands of nodes.
        // Walk it on the pre-reserved heap stack instead of consuming one
        // native stack frame per edge.
        while (self.propagation_stack.pop()) |current_id| {
            const current = self.getNode(current_id) orelse continue;
            const downstream_len = current.observers.items.len;
            var downstream_index: usize = 0;
            while (downstream_index < downstream_len) : (downstream_index += 1) {
                const obs_id = current.observers.items[downstream_index];
                const obs = self.getNode(obs_id) orelse continue;
                if (obs.state != .clean) continue;
                if (obs.kind == .effect) {
                    self.pending_effects.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                        if (first_error == null) first_error = err;
                        continue;
                    };
                    self.pending_effects.appendAssumeCapacity(obs_id);
                }
                obs.state = .check;
                self.propagation_stack.appendAssumeCapacity(obs_id);
            }
        }
        if (first_error) |err| return err;
    }

    // --------
    // Read path + pull recomputation
    // --------

    /// Before reading memo: pull to clean state, ensuring latest value.
    pub fn updateIfNecessary(self: *ReactiveGraph, id: NodeId) void {
        if (self.update_depth >= max_reactive_recursion_depth) {
            reactive_depth_limit_hits +|= 1;
            return;
        }
        self.update_depth += 1;
        defer self.update_depth -= 1;

        const n = self.getNode(id) orelse return;
        if (n.state == .clean) return;

        if (n.state == .check) {
            // WARNING: n cannot outlive updateIfNecessary recursion. Recursive calls invoke user
            // callbacks, which may create reactive nodes -> createNode's nodes.append reallocates,
            // invalidating all cached *GraphNode pointers (same issue with recomputeNode's defer).
            // Thus fetch nodes by index every iteration and do not hold sources slice.
            var i: usize = 0;
            while (true) {
                const cur = self.getNode(id) orelse return;
                if (i >= cur.sources.items.len) break;
                const sources_len_before = cur.sources.items.len;
                const src_id = cur.sources.items[i];

                self.updateIfNecessary(src_id);

                const after = self.getNode(id) orelse return;
                // Nested user recompute may destroy a sibling source. destroyNode
                // swap-removes that edge, potentially moving an unchecked source
                // into an index lower than `i`. Restart the small source scan on
                // any structural change so no swapped-in dependency is skipped.
                if (after.sources.items.len != sources_len_before or
                    i >= after.sources.items.len or
                    !NodeId.eq(after.sources.items[i], src_id))
                {
                    i = 0;
                    continue;
                }
                const s = self.getNode(src_id) orelse {
                    i += 1;
                    continue;
                };
                const seen = if (i < after.seen_versions.items.len) after.seen_versions.items[i] else 0;
                if (s.version != seen) {
                    after.state = .dirty;
                    break;
                }
                i += 1;
            }
            const cur = self.getNode(id) orelse return;
            if (cur.state == .check) {
                cur.state = .clean;
                return;
            }
        }

        const cur = self.getNode(id) orelse return;
        if (cur.state == .dirty) {
            self.recomputeNode(id);
        }
    }

    fn recomputeNode(self: *ReactiveGraph, id: NodeId) void {
        const n = self.getNode(id) orelse return;
        if (n.is_running) return; // Re-entrance guard
        if (self.tracking_stack.items.len >= max_reactive_recursion_depth) {
            reactive_depth_limit_hits +|= 1;
            return;
        }
        const recompute = n.recompute orelse return;
        const ctx = n.recompute_ctx orelse return;

        n.is_running = true;
        defer if (self.getNode(id)) |nn| {
            nn.is_running = false;
        };

        // Epoch-based dependency tracking instead of clearSources(O(observers)): bump
        // current_run, mark source_runs slots, prune unmatched sources at end. Static paths
        // (1k fanout): trackRead hits dedup cache with zero alloc/remove.
        n.tracking_failed = false;
        n.current_run +%= 1;
        const this_run = n.current_run;

        // pushTracking failure (OOM / stack full) means **this recompute does not run at all**,
        // node stays stale with no signal—hardest silent failure to debug (review report §3).
        // Log and count at least.
        self.pushTracking(id) catch |err| {
            reactive_tracking_failures += 1;
            // A failed effect run is not in any queue any more: schedule the drain's rescan so it
            // is retried (memos stay dirty and recompute on their next read).
            if (n.kind == .effect) self.rescan_effects = true;
            if (!suppress_reactive_error_log) {
                std.log.scoped(.zenit_reactive).err(
                    "pushTracking failed ({s}) for node {d}: recompute skipped, value stays stale",
                    .{ @errorName(err), id.index },
                );
            }
            return;
        };
        defer self.popTracking();

        const value_changed = recompute(ctx);

        const after = self.getNode(id) orelse return;
        if (after.tracking_failed) {
            after.state = .dirty;
            // Dirty but unqueued, a later write would skip it (observers already dirty are not
            // re-queued): retry it from the drain's rescan instead.
            if (after.kind == .effect) self.rescan_effects = true;
            return;
        }

        // Prune stale sources (current_run behind); reverse swapRemove to avoid index chaos.
        var i: usize = after.sources.items.len;
        while (i > 0) {
            i -= 1;
            const seen = if (i < after.source_runs.items.len) after.source_runs.items[i] else 0;
            if (seen != this_run) {
                const stale_src = after.sources.items[i];
                if (self.getNode(stale_src)) |s| removeFromList(&s.observers, id);
                _ = after.sources.swapRemove(i);
                if (i < after.seen_versions.items.len) _ = after.seen_versions.swapRemove(i);
                if (i < after.source_runs.items.len) _ = after.source_runs.swapRemove(i);
            }
        }

        // Sync seen_versions to current source versions.
        after.seen_versions.clearRetainingCapacity();
        for (after.sources.items) |src_id| {
            const s = self.getNode(src_id) orelse continue;
            // Cannot downgrade: seen_versions must align item-by-item with sources. Short by one
            // item -> subsequent version comparisons misalign / skip memos -> stale memo stays
            // silent.
            after.seen_versions.append(self.allocator, s.version) catch @panic("OOM: ReactiveGraph seen_versions resync");
        }

        if (after.kind == .memo and value_changed) {
            after.version +%= 1;
        }
        after.state = .clean;
    }

    fn runEffect(self: *ReactiveGraph, id: NodeId) void {
        self.recomputeNode(id);
    }

    // ------------------------------------------------------------------------
    // Batch / flush
    // ------------------------------------------------------------------------

    pub fn beginBatch(self: *ReactiveGraph) void {
        self.batch_depth += 1;
    }

    pub fn endBatch(self: *ReactiveGraph) !void {
        std.debug.assert(self.batch_depth > 0);
        self.batch_depth -= 1;
        if (self.batch_depth == 0) {
            try self.drainPendingEffects();
        }
    }

    /// Drain sorted by topological depth; shallower deps update before deeper ones. Each
    /// effect runs at most once per loop (state check deduplicates; after run, state -> clean).
    fn drainPendingEffects(self: *ReactiveGraph) !void {
        if (self.flushing) return;
        self.flushing = true;
        defer self.flushing = false;

        if (self.rescan_effects) try self.drainUnqueuedEffects();

        // Prevent iteration runaway: dynamic deps may introduce new dirty effects after
        // effect runs. Legal; we run by tier until queue stabilizes.
        var rounds: u32 = 0;
        const MAX_ROUNDS: u32 = 1024;

        // Double-buffer swap replaces alloc + memcpy + clear. pending_effects and drain_buffer
        // swap; after drain, pending_effects clears. Saves ~8KB alloc/free/memcpy per loop at 1k
        // fanout.
        while (self.pending_effects.items.len > 0) : (rounds += 1) {
            if (rounds >= MAX_ROUNDS) return error.ReactivePropagationDidNotConverge;

            // Sort only if >1 effect; zig std sort optimizes to O(N) for same-depth data
            // (introsort + insertion sort), no pre-check needed.
            if (self.pending_effects.items.len > 1) {
                std.mem.sort(NodeId, self.pending_effects.items, self, sortByDepth);
            }

            // Slice pending_effects into drain_buffer; pending_effects resets. New effects
            // entering during drain go to fresh pending_effects (next loop).
            std.mem.swap(std.ArrayListUnmanaged(NodeId), &self.pending_effects, &self.drain_buffer);

            // Drain: state == .clean effects skip (checked inside updateIfNecessary). Read by
            // index: an effect may create graph nodes, whose capacity reservation can move this
            // buffer (its length does not change during the drain).
            var drained: usize = 0;
            while (drained < self.drain_buffer.items.len) : (drained += 1) {
                const id = self.drain_buffer.items[drained];
                const n = self.getNode(id) orelse continue;
                if (n.state == .clean) continue;
                if (n.kind != .effect) continue;
                self.updateIfNecessary(id);
            }
            self.drain_buffer.clearRetainingCapacity();
            if (self.rescan_effects) try self.drainUnqueuedEffects();
        }
    }

    /// Rare OOM recovery path. Select effects in depth/index order without a
    /// worklist. Re-fetch nodes after every callback, which may resize the graph.
    /// Each effect is attempted once per scan; persistent OOM remains retryable
    /// at the next flush rather than spinning on the same failed recompute.
    fn drainUnqueuedEffects(self: *ReactiveGraph) !void {
        self.rescan_effects = false;
        self.pending_effects.clearRetainingCapacity();
        var cursor: ?struct { depth: u32, index: usize } = null;
        while (true) {
            var best: ?NodeId = null;
            var best_depth: u32 = std.math.maxInt(u32);
            for (self.nodes.items, 0..) |node, index| {
                if (!node.alive or node.kind != .effect or node.state == .clean or node.is_running) continue;
                if (cursor) |prev| {
                    if (node.depth < prev.depth or (node.depth == prev.depth and index <= prev.index)) continue;
                }
                if (best == null or node.depth < best_depth) {
                    best = .{ .index = @intCast(index), .generation = self.generations.items[index] };
                    best_depth = node.depth;
                }
            }
            const id = best orelse break;
            cursor = .{ .depth = best_depth, .index = id.index };
            self.updateIfNecessary(id);
        }
        // Includes effects dirtied by callbacks below the scan cursor, as well
        // as recomputations that still could not capture dependencies.
        for (self.nodes.items) |node| {
            if (node.alive and node.kind == .effect and node.state != .clean and !node.is_running) {
                self.rescan_effects = true;
                return error.OutOfMemory;
            }
        }
    }

    fn sortByDepth(self: *ReactiveGraph, a: NodeId, b: NodeId) bool {
        const an = if (a.index < self.nodes.items.len) self.nodes.items[a.index].depth else 0;
        const bn = if (b.index < self.nodes.items.len) self.nodes.items[b.index].depth else 0;
        return an < bn;
    }

    // ------------------------------------------------------------------------
    // Devtools
    // ------------------------------------------------------------------------

    pub fn dumpGraph(self: *ReactiveGraph, w: anytype) !void {
        try w.print("== ReactiveGraph: {d} nodes, batch_depth={d} ==\n", .{ self.nodes.items.len, self.batch_depth });
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive) continue;
            try w.print("  [{d:>4}] kind={s:<6} state={s:<5} ver={d:<4} depth={d:<3} sources={d} observers={d}\n", .{
                i,
                @tagName(n.kind),
                @tagName(n.state),
                n.version,
                n.depth,
                n.sources.items.len,
                n.observers.items.len,
            });
        }
    }

    /// Count live nodes by kind (baseline measurement / debugging).
    pub fn countByKind(self: *const ReactiveGraph) std.EnumArray(NodeKind, usize) {
        var out = std.EnumArray(NodeKind, usize).initFill(0);
        for (self.nodes.items) |n| {
            if (n.alive) out.getPtr(n.kind).* += 1;
        }
        return out;
    }

    pub fn nodeCount(self: *const ReactiveGraph) usize {
        var c: usize = 0;
        for (self.nodes.items) |n| {
            if (n.alive) c += 1;
        }
        return c;
    }
};

fn indexOf(list: std.ArrayListUnmanaged(NodeId), needle: NodeId) ?usize {
    for (list.items, 0..) |n, i| {
        if (n.eq(needle)) return i;
    }
    return null;
}

fn removeFromList(list: *std.ArrayListUnmanaged(NodeId), target: NodeId) void {
    if (indexOf(list.*, target)) |i| {
        _ = list.swapRemove(i);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "ReactiveGraph: basic signal create + write" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const s = try g.createSignal();
    const node = g.getNode(s).?;
    try testing.expectEqual(NodeKind.signal, node.kind);
    try testing.expectEqual(NodeState.clean, node.state);

    try g.markSignalWritten(s);
    const n2 = g.getNode(s).?;
    try testing.expectEqual(@as(u64, 2), n2.version);
}

test "NodeId is exactly 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(NodeId));
}

// ----- Diamond glitch test -----
//
//      A (signal)
//     / \
//    B   C
//   memo memo
//    \ /
//     D (effect)
//
// After writing A, D's recompute must read B and C both updated to
// latest values per new A.
const DiamondCtx = struct {
    g: *ReactiveGraph,
    a_id: NodeId,
    b_id: NodeId = .{ .index = 0, .generation = 0 },
    c_id: NodeId = .{ .index = 0, .generation = 0 },
    a_value: i32 = 0,
    b_value: i32 = 0,
    c_value: i32 = 0,
    d_observed: struct { b: i32, c: i32 } = .{ .b = 0, .c = 0 },
    d_run_count: u32 = 0,
};

fn computeB(ctx: *anyopaque) bool {
    const c: *DiamondCtx = @ptrCast(@alignCast(ctx));
    c.g.trackRead(c.a_id) catch {};
    const new_b = c.a_value * 10;
    const changed = c.b_value != new_b;
    c.b_value = new_b;
    return changed;
}

fn computeC(ctx: *anyopaque) bool {
    const c: *DiamondCtx = @ptrCast(@alignCast(ctx));
    c.g.trackRead(c.a_id) catch {};
    const new_c = c.a_value + 100;
    const changed = c.c_value != new_c;
    c.c_value = new_c;
    return changed;
}

fn observeD(ctx: *anyopaque) bool {
    const c: *DiamondCtx = @ptrCast(@alignCast(ctx));
    // Simulate Memo facade's get: updateIfNecessary, then trackRead, then read cache.
    c.g.updateIfNecessary(c.b_id);
    c.g.updateIfNecessary(c.c_id);
    c.g.trackRead(c.b_id) catch {};
    c.g.trackRead(c.c_id) catch {};
    c.d_observed = .{ .b = c.b_value, .c = c.c_value };
    c.d_run_count += 1;
    return false;
}

test "Diamond glitch freedom: D sees consistent B/C after A change" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    var ctx = DiamondCtx{
        .g = &g,
        .a_id = try g.createSignal(),
    };
    ctx.b_id = try g.createMemo(&computeB, &ctx);
    ctx.c_id = try g.createMemo(&computeC, &ctx);

    // First run: let D run once to establish dependency.
    _ = try g.createEffect(&observeD, &ctx);
    try testing.expectEqual(@as(u32, 1), ctx.d_run_count);
    try testing.expectEqual(@as(i32, 0), ctx.d_observed.b);
    try testing.expectEqual(@as(i32, 100), ctx.d_observed.c);

    // Write A: D should run once (not twice), seeing b=50, c=105.
    ctx.a_value = 5;
    try g.markSignalWritten(ctx.a_id);

    try testing.expectEqual(@as(u32, 2), ctx.d_run_count);
    try testing.expectEqual(@as(i32, 50), ctx.d_observed.b);
    try testing.expectEqual(@as(i32, 105), ctx.d_observed.c);
}

test "ReactiveGraph: memo lazy — not computed until read" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const a_id = try g.createSignal();
    const Ctx = struct {
        g: *ReactiveGraph,
        a_id: NodeId,
        compute_count: u32 = 0,
    };
    var ctx = Ctx{ .g = &g, .a_id = a_id };

    const computeM = struct {
        fn cb(opaque_ctx: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(opaque_ctx));
            c.g.trackRead(c.a_id) catch {};
            c.compute_count += 1;
            return false;
        }
    }.cb;

    const m_id = try g.createMemo(&computeM, &ctx);
    // Memo should not compute immediately after creation.
    try testing.expectEqual(@as(u32, 0), ctx.compute_count);

    // First updateIfNecessary triggers computation.
    g.updateIfNecessary(m_id);
    try testing.expectEqual(@as(u32, 1), ctx.compute_count);

    // Second update skips (state=clean).
    g.updateIfNecessary(m_id);
    try testing.expectEqual(@as(u32, 1), ctx.compute_count);

    // After write a, update recomputes.
    try g.markSignalWritten(a_id);
    g.updateIfNecessary(m_id);
    try testing.expectEqual(@as(u32, 2), ctx.compute_count);
}

test "ReactiveGraph: batch coalesces multiple writes" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const Ctx = struct {
        g: *ReactiveGraph,
        a_id: NodeId,
        b_id: NodeId,
        run_count: u32 = 0,
    };
    var ctx: Ctx = undefined;
    ctx.g = &g;
    ctx.a_id = try g.createSignal();
    ctx.b_id = try g.createSignal();
    ctx.run_count = 0;

    const eff = struct {
        fn cb(opaque_ctx: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(opaque_ctx));
            c.g.trackRead(c.a_id) catch {};
            c.g.trackRead(c.b_id) catch {};
            c.run_count += 1;
            return false;
        }
    }.cb;

    _ = try g.createEffect(&eff, &ctx);
    try testing.expectEqual(@as(u32, 1), ctx.run_count);

    // No batch: two sets -> two effects.
    try g.markSignalWritten(ctx.a_id);
    try g.markSignalWritten(ctx.b_id);
    try testing.expectEqual(@as(u32, 3), ctx.run_count);

    // Batch: two sets -> one effect.
    g.beginBatch();
    try g.markSignalWritten(ctx.a_id);
    try g.markSignalWritten(ctx.b_id);
    try g.endBatch();
    try testing.expectEqual(@as(u32, 4), ctx.run_count);
}

test "ReactiveGraph: destroy removes from graph" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const a = try g.createSignal();
    try testing.expect(g.isAlive(a));
    g.destroyNode(a);
    try testing.expect(!g.isAlive(a));
}

test "ReactiveGraph: dumpGraph produces output" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    _ = try g.createSignal();
    _ = try g.createSignal();

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try g.dumpGraph(&writer);
    const out = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "ReactiveGraph") != null);
    try testing.expect(std.mem.indexOf(u8, out, "signal") != null);
}

// ----- compile-time hygiene -----
test "eqlValue is reachable from graph context" {
    try testing.expect(eqlValue(i32, 42, 42));
}

// ----- OOM self-healing -----
//
// std.testing.FailingAllocator fails permanently once fail_index is hit, so it cannot model
// 'transient OOM then recovery'. Use a one-shot allocator: armed mode fails exactly once.
const OneShotFailingAllocator = struct {
    backing: std.mem.Allocator,
    armed: bool = false,

    fn allocator(self: *OneShotFailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocImpl,
        .resize = resizeImpl,
        .remap = remapImpl,
        .free = freeImpl,
    };

    fn allocImpl(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) {
            self.armed = false;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }
    fn resizeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remapImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) {
            self.armed = false;
            return null;
        }
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn freeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "signal write notifies every observer without allocating, even when every allocation fails" {
    // Signal.set cannot report an error: a write used to allocate its propagation worklist
    // and effect queue entries, and on failure the committed value's observers only caught up
    // on some later write. Node creation now reserves that capacity (reserveNotification).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var g = ReactiveGraph.init(failing.allocator());
    defer g.deinit();

    const source = try g.createSignal();
    const Ctx = struct { graph: *ReactiveGraph, source: NodeId, runs: usize = 0 };
    const callback = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *Ctx = @ptrCast(@alignCast(raw));
            ctx.runs += 1;
            ctx.graph.trackRead(ctx.source) catch {};
            return false;
        }
    }.run;
    var first = Ctx{ .graph = &g, .source = source };
    var tail = Ctx{ .graph = &g, .source = source };
    _ = try g.createEffect(&callback, &first);
    _ = try g.createEffect(&callback, &tail);
    const memo = try g.createMemo(&struct {
        fn recompute(_: *anyopaque) bool {
            return true;
        }
    }.recompute, &first);
    try g.addEdge(memo, source);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (0..3) |round| {
        try g.markSignalWritten(source);
        try testing.expectEqual(round + 2, first.runs);
        try testing.expectEqual(round + 2, tail.runs);
        try testing.expect(g.getNode(memo).?.state != .clean);
    }
    try testing.expect(!failing.has_induced_failure);
    try testing.expect(!g.rescan_effects);
}

test "node creation fails cleanly when the notification reservation cannot grow" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var g = ReactiveGraph.init(failing.allocator());
    defer g.deinit();
    _ = try g.createSignal();
    const live_before = g.nodes.items.len;
    var created: usize = 0;
    // Fail every allocation step of the next creation in turn: it either succeeds whole or
    // leaves no published node, and later writes still never allocate.
    for (0..16) |step| {
        failing.fail_index = failing.alloc_index + step;
        failing.resize_fail_index = failing.resize_index;
        const result = g.createSignal();
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (result) |_| {
            created += 1;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
        try testing.expectEqual(live_before + created, g.nodes.items.len);
        try testing.expect(g.propagation_stack.capacity >= g.nodes.items.len);
        try testing.expect(g.pending_effects.capacity >= g.nodes.items.len);
        try testing.expect(g.drain_buffer.capacity >= g.nodes.items.len);
    }
    try testing.expect(created > 0);
}

test "an effect creating many nodes during a drain does not disturb the batch being drained" {
    // The drain reads its batch by index: creating nodes may move the buffer it is reading.
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();
    const source = try g.createSignal();
    const Ctx = struct { graph: *ReactiveGraph, source: NodeId, runs: usize = 0, spawn: bool };
    const callback = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *Ctx = @ptrCast(@alignCast(raw));
            ctx.runs += 1;
            ctx.graph.trackRead(ctx.source) catch @panic("trackRead");
            if (ctx.spawn and ctx.runs > 1) for (0..512) |_| {
                _ = ctx.graph.createSignal() catch @panic("createSignal");
            };
            return false;
        }
    }.run;
    var effects: [8]Ctx = undefined;
    for (&effects, 0..) |*e, i| {
        e.* = .{ .graph = &g, .source = source, .spawn = i == 0 };
        _ = try g.createEffect(&callback, e);
    }
    const capacity_before = g.drain_buffer.capacity;
    try g.markSignalWritten(source);
    try testing.expect(g.drain_buffer.capacity > capacity_before);
    for (effects) |e| try testing.expectEqual(@as(usize, 2), e.runs);
}

test "updateIfNecessary rescans when nested recompute removes an earlier sibling source" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const victim = try g.createSignal();
    const trigger = try g.createSignal();
    const tail = try g.createSignal();

    const KillerCtx = struct {
        graph: *ReactiveGraph,
        trigger: NodeId,
        victim: NodeId,
        destroy_victim: bool = false,
    };
    var killer_ctx = KillerCtx{ .graph = &g, .trigger = trigger, .victim = victim };
    const killer_cb = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *KillerCtx = @ptrCast(@alignCast(raw));
            ctx.graph.trackRead(ctx.trigger) catch @panic("test trackRead failed");
            if (ctx.destroy_victim) {
                ctx.destroy_victim = false;
                ctx.graph.destroyNode(ctx.victim);
            }
            // Keep the memo version stable: the reader must still inspect tail.
            return false;
        }
    }.run;
    const killer = try g.createMemo(killer_cb, &killer_ctx);
    g.updateIfNecessary(killer);

    const ReaderCtx = struct {
        graph: *ReactiveGraph,
        victim: NodeId,
        killer: NodeId,
        tail: NodeId,
        runs: usize = 0,
    };
    var reader_ctx = ReaderCtx{ .graph = &g, .victim = victim, .killer = killer, .tail = tail };
    const reader_cb = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *ReaderCtx = @ptrCast(@alignCast(raw));
            ctx.runs += 1;
            ctx.graph.trackRead(ctx.victim) catch {};
            ctx.graph.updateIfNecessary(ctx.killer);
            ctx.graph.trackRead(ctx.killer) catch @panic("test trackRead failed");
            ctx.graph.trackRead(ctx.tail) catch @panic("test trackRead failed");
            return true;
        }
    }.run;
    const reader = try g.createMemo(reader_cb, &reader_ctx);
    g.updateIfNecessary(reader);
    try testing.expectEqual(@as(usize, 1), reader_ctx.runs);

    // Tail changed, but only killer propagation marks reader .check. While the
    // reader checks killer, killer destroys victim (source index 0), which
    // swap-removes tail into that already-visited index.
    g.getNode(tail).?.version +%= 1;
    killer_ctx.destroy_victim = true;
    try g.markSignalWritten(trigger);
    g.updateIfNecessary(reader);

    try testing.expectEqual(@as(usize, 2), reader_ctx.runs);
}

test "propagation uses heap worklist for very deep observer chains" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const chain_len = 4096;
    const ids = try testing.allocator.alloc(NodeId, chain_len);
    defer testing.allocator.free(ids);
    for (ids) |*id| id.* = try g.createSignal();
    for (1..ids.len) |i| try g.addEdge(ids[i], ids[i - 1]);

    try g.markSignalWritten(ids[0]);
    try testing.expectEqual(NodeState.dirty, g.getNode(ids[1]).?.state);
    try testing.expectEqual(NodeState.check, g.getNode(ids[ids.len - 1]).?.state);
}

test "a write marks every observer at once even when the next allocation would fail" {
    var one_shot = OneShotFailingAllocator{ .backing = testing.allocator };
    var g = ReactiveGraph.init(one_shot.allocator());
    defer g.deinit();

    const source = try g.createSignal();
    const direct = try g.createSignal();
    const tail = try g.createSignal();
    try g.addEdge(direct, source);
    try g.addEdge(tail, direct);

    // The worklist capacity was reserved when the nodes were created: the write consumes no
    // allocation and leaves nothing for a later write to recover.
    one_shot.armed = true;
    try g.markSignalWritten(source);
    try testing.expect(one_shot.armed);
    one_shot.armed = false;
    try testing.expectEqual(NodeState.dirty, g.getNode(direct).?.state);
    try testing.expectEqual(NodeState.check, g.getNode(tail).?.state);
    try testing.expect(!g.rescan_effects);
}

test "reactive recompute chain stops at explicit recursion budget" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const chain_len = max_reactive_recursion_depth + 16;
    const Context = struct {
        graph: *ReactiveGraph,
        next: ?NodeId = null,
        runs: usize = 0,
    };
    const contexts = try testing.allocator.alloc(Context, chain_len);
    defer testing.allocator.free(contexts);
    const ids = try testing.allocator.alloc(NodeId, chain_len);
    defer testing.allocator.free(ids);
    const callback = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *Context = @ptrCast(@alignCast(raw));
            ctx.runs += 1;
            if (ctx.next) |next| {
                ctx.graph.updateIfNecessary(next);
                ctx.graph.trackRead(next) catch @panic("test trackRead failed");
            }
            return true;
        }
    }.run;

    var i = chain_len;
    while (i > 0) {
        i -= 1;
        contexts[i] = .{ .graph = &g, .next = if (i + 1 < chain_len) ids[i + 1] else null };
        ids[i] = try g.createMemo(&callback, &contexts[i]);
    }

    const hits_before = reactive_depth_limit_hits;
    g.updateIfNecessary(ids[0]);
    try testing.expect(reactive_depth_limit_hits > hits_before);
    try testing.expectEqual(@as(usize, 0), g.update_depth);
    try testing.expectEqual(@as(usize, 0), g.tracking_stack.items.len);
    try testing.expect(contexts[0].runs > 0);
    try testing.expectEqual(@as(usize, 0), contexts[chain_len - 1].runs);
}

// ----- OOM Invariants -----
//
// Invariant: seen_versions must align item-by-item with sources (short by one -> version
// comparison misaligns -> stale memo silently skips recompute). recomputeNode's trailing
// `seen_versions.append(...)` panics rather than being swallowed.
//
// NOTE: that @panic is **unreachable defensive code**; do not cite it for coverage.
// addEdge calls ensureUnusedCapacity on all four tables (sources / seen_versions /
// source_runs / observers) first, then appendAssumeCapacity, so half-edges are structurally
// impossible. The resync loop only calls clearRetainingCapacity before, so append never
// needs new allocation. Alignment does not depend on coincidence.
//
// This test asserts the observable property: edges are either complete (memo is wakeable by
// source) or completely missing with trackRead returning error, never 'half-built + caller
// thinks success'. Log trackRead failures instead of `catch {}`; lost edges are observable
// only this way.
test "allocation campaign: ReactiveGraph dependency edge is fully committed or absent" {
    var saw_induced_failure = false;
    var saw_dropped_edge = false;

    // OOM will naturally trigger pushTracking failure logs; expected behavior, not test failure.
    suppress_reactive_error_log = true;
    defer suppress_reactive_error_log = false;

    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var g = ReactiveGraph.init(failing.allocator());
        defer g.deinit();

        var signals: [8]NodeId = undefined;
        var made: usize = 0;
        while (made < signals.len) : (made += 1) {
            signals[made] = g.createSignal() catch break;
        }
        if (made == 0) continue;

        const Ctx = struct {
            g: *ReactiveGraph,
            signals: []const NodeId,
            read_count: usize,
            /// Count of trackRead failures, i.e., 'this loop has missing edges' signal.
            track_failures: usize = 0,
            /// Whether this loop's recompute callback actually ran.
            ran: bool = false,
        };
        // First loop reads 1 source; each loop adds more, forcing repeated addEdge allocations.
        var ctx = Ctx{ .g = &g, .signals = signals[0..made], .read_count = 1 };

        const computeM = struct {
            fn cb(opaque_ctx: *anyopaque) bool {
                const c: *Ctx = @ptrCast(@alignCast(opaque_ctx));
                c.ran = true;
                for (c.signals[0..c.read_count]) |sid| {
                    // Do not swallow: lost edges must be observable, or test validates thin air.
                    c.g.trackRead(sid) catch {
                        c.track_failures += 1;
                    };
                }
                return true;
            }
        }.cb;

        const m_id = g.createMemo(&computeM, &ctx) catch continue;
        g.updateIfNecessary(m_id);

        // Grow dependency set each loop, forcing repeated addEdge allocations.
        while (ctx.read_count < made) {
            ctx.read_count += 1;
            ctx.track_failures = 0;
            ctx.ran = false;
            g.markSignalWritten(signals[0]) catch break;
            g.updateIfNecessary(m_id);
            const m = g.getNode(m_id) orelse break;

            // Three parallel arrays must **always** stay equal length (structural invariant). This
            // assert is unguarded by ctx.ran: even if no recompute this loop, residual state
            // cannot misalign. (Testing: replace try with `catch {}` in addEdge's source_runs
            // append; one of these two asserts must fail. See note on ran guard below.)
            try testing.expectEqual(m.sources.items.len, m.seen_versions.items.len);
            try testing.expectEqual(m.sources.items.len, m.source_runs.items.len);

            // Guarded by ran: downstream comparisons depend on 'actually recomputed this loop'.
            // markSignalWritten itself may OOM so the memo is never marked dirty; in that case
            // sources still holds the previous loop's contents. Beware: do not hoist this
            // continue above; that would skip the loop that catches misalignment.
            if (!ctx.ran) continue;

            // Core assert: all successfully trackRead sources built edges. sources may retain
            // prior-loop edges not yet pruned, so use >=. But never fewer than 'successfully
            // trackRead count'—fewer means edges silently dropped while caller oblivious,
            // root cause of 'should-update memo stays silent'.
            try testing.expect(m.sources.items.len >= ctx.read_count - ctx.track_failures);
            if (ctx.track_failures > 0) saw_dropped_edge = true;
        }

        if (!failing.has_induced_failure) continue;
        saw_induced_failure = true;
    }

    // Verify this test actually triggered allocation failures, not false-green via continue.
    try testing.expect(saw_induced_failure);
    // And verify we saw 'edges were dropped' scenario (else core assert was never truly tested).
    try testing.expect(saw_dropped_edge);
}

test "createNode: 世代回卷前 slot 永久退役（悬垂 NodeId 不复活）" {
    // Real test: old impl returned stale id as isAlive at exactly 256th reuse (ABA).
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const first = try g.createSignal();
    g.destroyNode(first);

    var cycles: u32 = 0;
    while (cycles < 300) : (cycles += 1) {
        const id = try g.createSignal();
        if (id.index != first.index) {
            g.destroyNode(id);
            break;
        }
        try testing.expect(!g.isAlive(first));
        g.destroyNode(id);
    }
    try testing.expect(cycles < 300);
    try testing.expect(!g.isAlive(first));
}

test "a batched write reaches nested memo effects at batch end without allocating or rerunning unrelated effects" {
    var failing = OneShotFailingAllocator{ .backing = testing.allocator };
    var graph = ReactiveGraph.init(failing.allocator());
    defer graph.deinit();
    const source = try graph.createSignal();
    const unrelated = try graph.createSignal();
    const Ctx = struct {
        graph: *ReactiveGraph,
        source: NodeId,
        memo: NodeId = NodeId.NULL,
        value: u32 = 0,
        cache: u32 = 0,
        observed: u32 = 0,
        runs: usize = 0,
    };
    var ctx = Ctx{ .graph = &graph, .source = source };
    const memo_cb = struct {
        fn run(raw: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(raw));
            c.graph.trackRead(c.source) catch unreachable;
            const changed = c.cache != c.value;
            c.cache = c.value;
            return changed;
        }
    }.run;
    ctx.memo = try graph.createMemo(memo_cb, &ctx);
    const effect_cb = struct {
        fn run(raw: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(raw));
            c.runs += 1;
            if (!c.memo.isNull()) {
                c.graph.updateIfNecessary(c.memo);
                c.graph.trackRead(c.memo) catch unreachable;
                c.observed = c.cache;
            } else c.graph.trackRead(c.source) catch unreachable;
            return false;
        }
    }.run;
    _ = try graph.createEffect(effect_cb, &ctx);
    var other = Ctx{ .graph = &graph, .source = unrelated };
    _ = try graph.createEffect(effect_cb, &other);
    graph.beginBatch();
    ctx.value = 42;
    failing.armed = true;
    try graph.markSignalWritten(source);
    try testing.expect(failing.armed);
    failing.armed = false;
    try testing.expectEqual(@as(usize, 1), ctx.runs);
    try graph.endBatch();
    try testing.expectEqual(@as(u32, 42), ctx.observed);
    try testing.expectEqual(@as(usize, 2), ctx.runs);
    try testing.expectEqual(@as(usize, 1), other.runs);
    try testing.expect(!graph.rescan_effects);
}

test "failed effect recompute remains scheduled until memory recovers without another write" {
    var graph = ReactiveGraph.init(testing.allocator);
    defer graph.deinit();
    const source = try graph.createSignal();
    const Ctx = struct { graph: *ReactiveGraph, source: NodeId, value: u32 = 0, observed: u32 = 0 };
    var ctx = Ctx{ .graph = &graph, .source = source };
    _ = try graph.createEffect(struct {
        fn run(raw: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(raw));
            c.graph.trackRead(c.source) catch unreachable;
            c.observed = c.value;
            return false;
        }
    }.run, &ctx);
    graph.tracking_stack.deinit(graph.allocator);
    graph.tracking_stack = .empty;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    graph.allocator = failing.allocator();
    suppress_reactive_error_log = true;
    defer suppress_reactive_error_log = false;
    graph.beginBatch();
    ctx.value = 42;
    // The write itself never allocates (its capacity was reserved at creation); the effect's
    // own recompute fails at the batch end and stays scheduled.
    try graph.markSignalWritten(source);
    try testing.expectError(error.OutOfMemory, graph.endBatch());
    try testing.expect(graph.rescan_effects);
    try testing.expectEqual(@as(u32, 0), ctx.observed);
    graph.allocator = testing.allocator;
    graph.beginBatch();
    try graph.endBatch();
    try testing.expectEqual(@as(u32, 42), ctx.observed);
    try testing.expect(!graph.rescan_effects);
}

test "an effect whose run fails is retried by the next drain instead of going deaf" {
    // The failed effect stays dirty and leaves the queue; propagation skips dirty observers, so
    // without a rescan no later write would ever reach it.
    var graph = ReactiveGraph.init(testing.allocator);
    defer graph.deinit();
    const source = try graph.createSignal();
    const unrelated = try graph.createSignal();
    const Ctx = struct { graph: *ReactiveGraph, source: NodeId, value: u32 = 0, observed: u32 = 0 };
    const callback = struct {
        fn run(raw: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(raw));
            c.graph.trackRead(c.source) catch unreachable;
            c.observed = c.value;
            return false;
        }
    }.run;
    var ctx = Ctx{ .graph = &graph, .source = source };
    _ = try graph.createEffect(callback, &ctx);
    var other = Ctx{ .graph = &graph, .source = unrelated };
    _ = try graph.createEffect(callback, &other);

    // Make the effect's next run fail: its tracking stack has to grow and nothing can be had.
    graph.tracking_stack.deinit(graph.allocator);
    graph.tracking_stack = .empty;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    graph.allocator = failing.allocator();
    suppress_reactive_error_log = true;
    defer suppress_reactive_error_log = false;
    ctx.value = 42;
    try testing.expectError(error.OutOfMemory, graph.markSignalWritten(source));
    try testing.expectEqual(@as(u32, 0), ctx.observed);
    try testing.expect(graph.rescan_effects);

    // Memory is back; a write to an unrelated signal drains and the failed effect catches up
    // without its own source being written again.
    graph.allocator = testing.allocator;
    other.value = 7;
    try graph.markSignalWritten(unrelated);
    try testing.expectEqual(@as(u32, 7), other.observed);
    try testing.expectEqual(@as(u32, 42), ctx.observed);
    try testing.expect(!graph.rescan_effects);
}

test "a memo read sees a write made while the next allocation would fail" {
    var failing = OneShotFailingAllocator{ .backing = std.testing.allocator };
    var graph = ReactiveGraph.init(failing.allocator());
    defer graph.deinit();
    const signal = try graph.createSignal();
    const Context = struct { graph: *ReactiveGraph, signal: NodeId, source: u32 = 0, memo: u32 = 0 };
    var context = Context{ .graph = &graph, .signal = signal };
    const cb = struct {
        fn run(raw: *anyopaque) bool {
            const c: *Context = @ptrCast(@alignCast(raw));
            c.graph.trackRead(c.signal) catch unreachable;
            c.memo = c.source;
            return true;
        }
    }.run;
    const memo = try graph.createMemo(cb, &context);
    graph.updateIfNecessary(memo);
    context.source = 42;
    failing.armed = true;
    try graph.markSignalWritten(signal);
    try std.testing.expect(failing.armed);
    failing.armed = false;
    graph.updateIfNecessary(memo);
    try std.testing.expectEqual(@as(u32, 42), context.memo);
}
