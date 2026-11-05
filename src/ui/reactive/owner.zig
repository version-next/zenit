const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalBase = @import("signal_base.zig").SignalBase;
const EffectBase = @import("effect_base.zig").EffectBase;
const BatchContext = @import("batch.zig").BatchContext;
const graph_mod = @import("graph.zig");
pub const ReactiveGraph = graph_mod.ReactiveGraph;

/// SignalOwner: lifecycle manager of the reactive system.
///
/// - Each component owns one Owner
/// - Owner manages all Signals/Effects in that component
/// - Uses an Arena allocator to reclaim all memory at once
/// - On component destruction, Owner.deinit() cleans up all dependencies
pub const SignalOwner = struct {
    pub const TestWriteTrace = struct { context: *anyopaque, write: *const fn (*anyopaque, *SignalBase) void };
    pub const TestTemplateMode = enum { configured, release_tree, comptime_template, runtime_template };
    pub const TestHook = enum { onMount, onUnmount, onViewAttach, onViewDetach };
    pub const DeferredDisposal = @import("deferred_disposal.zig").Entry;
    /// Intrusive entry for `runOutsideComputation`; lives inside the requesting resource, which
    /// must `cancel()` it before it is freed.
    pub const SettledTask = @import("deferred_disposal.zig").Entry;

    /// Arena allocator: all Signal/Effect allocated from here
    test_write_trace: if (@import("builtin").is_test) ?TestWriteTrace else void = if (@import("builtin").is_test) null else {},
    template_builder: if (@import("builtin").is_test) TestTemplateMode else void = if (@import("builtin").is_test) .configured else {},

    test_hooks: if (@import("builtin").is_test) [4]usize else void = if (@import("builtin").is_test) @splat(0) else {},
    test_hook_trace: if (@import("builtin").is_test) std.hash.Wyhash else void = if (@import("builtin").is_test) .init(0) else {},
    // Test-only A/B template driver; never an LP4 publication entry point.
    test_template_wrap: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},
    test_template_depth: if (@import("builtin").is_test) usize else void = if (@import("builtin").is_test) 0 else {},

    arena: std.heap.ArenaAllocator,

    /// Parent allocator (for Arena itself)
    parent_allocator: Allocator,

    /// Thread ID when created (for thread-affinity asserts)
    thread_id: if (@import("builtin").os.tag == .freestanding) void else std.Thread.Id,

    /// All Signal list (for cleanup)
    signals: std.ArrayList(*SignalBase),

    /// All Effect list (for cleanup and execution)
    effects: std.ArrayList(*EffectBase),

    /// Batch update context
    batch_ctx: BatchContext,

    /// Currently executing Effect (for dependency tracking)
    current_effect: ?*EffectBase = null,

    // Graph main path.
    // Each SignalOwner holds one ReactiveGraph as the scheduler.
    // Signal/Memo/Effect facades register a NodeId in the graph at creation;
    // set/get/recompute go through the graph (topological order + version stamps + lazy memo).
    // The old push DFS path (signal.notifyImpl directly calls effect.runWithTracking) is kept
    // as fallback; when use_graph_path = true, everything goes through the graph.
    graph: ReactiveGraph,
    use_graph_path: bool = true,

    /// Debug diagnostic counters (docs/SIGNAL_API_DESIGN.md §4.11). Empty struct in Release.
    debug: DebugCounters = .{},

    /// Scope disposal requested from inside an effect/memo callback must wait
    /// until the outer reactive facade has stopped touching its allocation.
    reactive_callback_depth: u32 = 0,
    /// Direct scope cleanup may call into the window host outside reactive dispatch.
    scope_disposal_depth: usize = 0,
    deferred_disposals: @import("deferred_disposal.zig").Queue = .{},
    draining_disposals: bool = false,

    /// Event-entry work that arrived while an effect / memo computation was on the stack (see
    /// `runOutsideComputation`); run once that reactive work has settled.
    settled_tasks: @import("deferred_disposal.zig").Queue = .{},
    draining_settled_tasks: bool = false,

    pub const debug_checks = @import("builtin").mode == .debug;
    const tracking_stack_reserve = 2 * graph_mod.max_reactive_recursion_depth;

    /// Spec §4.11 clause 5: these counters are decision evidence for 'are raw pointers enough'.
    pub const DebugCounters = if (debug_checks) struct {
        /// Number of writes that actually changed a signal's value (basis for deciding that a split
        /// write did not land synchronously)
        signal_writes: u64 = 0,
        /// Borrow-check warning (borrowed signal not in consumer scope's ancestor chain)
        borrow_warnings: u32 = 0,
        /// effect / memo wrote signal it read in this batch
        self_write_warnings: u32 = 0,
        /// After split.write, data source unchanged and no signal writes occurred
        split_unlanded_hints: u32 = 0,
        /// Owned text set allocation failed (value unchanged)
        text_store_failures: u32 = 0,
        /// Component mount nesting depth (`enterMount` / `exitMount`)
        mount_depth: u32 = 0,
        /// Tracking read during mount, not inside effect / memo computation (value won't update,
        /// pain point 5)
        mount_tracked_reads: u32 = 0,
        /// `Derived.peek` nesting depth: get() on source in derived function is part of snapshot,
        /// not raw read
        snapshot_depth: u32 = 0,
    } else struct {};

    /// Component mount start / end (paired, `defer owner.exitMount()`). Debug: 'raw read during
    /// mount' warning; Release: no-op.
    pub fn enterMount(self: *SignalOwner) void {
        if (debug_checks) self.debug.mount_depth += 1;
    }

    pub fn exitMount(self: *SignalOwner) void {
        if (debug_checks) self.debug.mount_depth -= 1;
    }

    /// Debug: during mount and currently no real reader (tracking stack empty or top is untrack
    /// sentinel), tracking read of signal value read but won't update on source change. Component
    /// should use ui.bind / Show / textFmt.
    pub fn noteTrackedRead(self: *SignalOwner, comptime what: []const u8) void {
        if (!debug_checks) return;
        if (self.debug.mount_depth == 0 or self.debug.snapshot_depth > 0) return;
        const stack = self.graph.tracking_stack.items;
        if (stack.len != 0 and !stack[stack.len - 1].isNull()) return;
        self.debug.mount_tracked_reads += 1;
        std.log.warn("[reactive] " ++ what ++ ".get() during mount outside an effect: the value will not update; use ui.bind / Show / textFmt (or peek() if a snapshot is intended)", .{});
    }

    /// Create a SignalOwner
    ///
    /// parent_alloc: parent allocator, used to create Arena.
    pub fn recordTestHook(self: *SignalOwner, comptime hook: TestHook) void {
        if (comptime @import("builtin").is_test) {
            self.test_hooks[@backingInt(hook)] += 1;
            self.test_hook_trace.update(@tagName(hook));
        }
    }

    pub fn init(parent_alloc: Allocator) !*SignalOwner {
        const owner = try parent_alloc.create(SignalOwner);
        owner.* = .{
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
            .parent_allocator = parent_alloc,
            .thread_id = if (@import("builtin").os.tag == .freestanding) {} else std.Thread.getCurrentId(),
            .signals = .empty,
            .effects = .empty,
            .batch_ctx = BatchContext.init(parent_alloc),
            .graph = ReactiveGraph.init(parent_alloc),
        };
        errdefer {
            owner.arena.deinit();
            owner.graph.deinit();
            owner.batch_ctx.deinit();
            parent_alloc.destroy(owner);
        }
        // Pre-allocate tracking stack: untrack pushing sentinel shouldn't fail at runtime (fallback
        // is global disable tracking, which loses deps on first-calculate memo inside untrack). 256
        // = 2x the recursion depth limit of 128, covering one extra untrack nested at every level.
        try owner.graph.tracking_stack.ensureTotalCapacity(parent_alloc, tracking_stack_reserve);
        return owner;
    }

    /// Destroy SignalOwner and clean up all resources.
    ///
    /// Single cleanup path: graph.deinit handles all reactive node source/observer
    /// edges; SignalBase.subscribers / EffectBase.dependencies lists are not traversed.
    ///
    /// Cleanup order:
    /// 1. graph.deinit closes all nodes + frees graph structure
    /// 2. Free self.signals / self.effects ArrayLists themselves
    /// 3. batch_ctx.deinit
    /// 4. Arena reclaims all Signal/Effect instance memory at once.
    pub fn deinit(self: *SignalOwner) void {
        self.assertThread();
        std.debug.assert(self.reactive_callback_depth == 0);
        _ = self.drainDeferredDisposals();
        // Owners of still-queued settled tasks are released by now; drop the requests unrun.
        while (self.settled_tasks.popFirst()) |_| {}
        // Single cleanup path: graph.deinit handles all reactive nodes.
        // EffectBase.dependencies / SignalBase.subscribers fields removed.
        // Note: SignalBase.subscribers still exists before P1.5 complete, skip here to keep single
        // path.

        // Free ArrayLists (allocated with parent_allocator)
        self.effects.deinit(self.parent_allocator);
        self.signals.deinit(self.parent_allocator);

        // 4. Clean batch context
        self.batch_ctx.deinit();

        // 5. Clean graph (v0.2-P1)
        self.graph.deinit();

        // 6. Reclaim all memory once (Arena frees all Signal/Effect)
        self.arena.deinit();

        // 7. Free owner itself
        self.parent_allocator.destroy(self);
    }

    // Note: intentionally no reset() here. A reset (whole-generation Arena reclaim + field reset)
    // once existed for the 'rebuild UI tree every frame' use; that was immediate-mode legacy and
    // zenit is retained-mode, with no callers anywhere, so it was deleted. An owner's lifetime is
    // only init/deinit.

    /// Get Arena allocator (for Signal/Effect use)
    pub fn allocator(self: *SignalOwner) Allocator {
        return self.arena.allocator();
    }

    /// Register Signal (for Signal.init internal call)
    pub fn registerSignal(self: *SignalOwner, signal: *SignalBase) !void {
        self.assertThread();
        try self.signals.append(self.parent_allocator, signal);
    }

    /// Register Effect (for createEffect internal call)
    pub fn registerEffect(self: *SignalOwner, effect: *EffectBase) !void {
        self.assertThread();
        try self.effects.append(self.parent_allocator, effect);
    }

    pub fn beginReactiveCallback(self: *SignalOwner) void {
        self.assertThread();
        self.reactive_callback_depth += 1;
    }

    pub fn endReactiveCallback(self: *SignalOwner) void {
        _ = self.endReactiveCallbackObserved();
    }

    /// Reports actual disposal dispatch at this boundary. Nested callback ends,
    /// empty/cancelled queues and reentrant drains do not report pending work as
    /// executed. Hosts can resynchronize after user cleanup without scanning on
    /// every callback or reading resources that cleanup may have destroyed.
    pub fn endReactiveCallbackObserved(self: *SignalOwner) bool {
        self.assertThread();
        std.debug.assert(self.reactive_callback_depth > 0);
        self.reactive_callback_depth -= 1;
        if (self.reactive_callback_depth != 0) return false;
        const dispatched = self.drainDeferredDisposals();
        // Effect creation runs its first pass here: tasks it queued may run once its tracking
        // frame is gone (graph-driven effects still hold theirs; they drain after the flush).
        self.drainSettledTasks();
        return dispatched;
    }

    /// Whether an effect / memo computation is on the stack. Untrack sentinels do not count:
    /// they mask tracking, not the computation below them, so the whole stack is scanned.
    pub fn inReactiveComputation(self: *const SignalOwner) bool {
        for (self.graph.tracking_stack.items) |id| {
            if (!id.isNull()) return true;
        }
        return false;
    }

    /// Run event-entry work - typically a model proposal - that a reactive computation set off
    /// synchronously (e.g. an effect revoking focus delivers a blur whose handler commits a
    /// draft). Proposals must never run inside an effect / memo, so when one is on the stack the
    /// request is queued on `entry` and runs after the reactive work settles: when the
    /// outermost effect drain of the triggering signal write or batch end has finished, or when
    /// the outermost reactive callback returns. Outside a computation it runs immediately.
    /// Requests coalesce while queued. `entry` lives in the resource `ptr` points to, which must
    /// `entry.cancel()` before it is freed; the task re-reads current state, since it may run
    /// after other effects have changed it.
    pub fn runOutsideComputation(
        self: *SignalOwner,
        entry: *SettledTask,
        ptr: *anyopaque,
        task_fn: *const fn (*anyopaque) void,
    ) void {
        self.assertThread();
        if (!self.inReactiveComputation()) {
            // A queued request for the same work is superseded by this direct run.
            entry.cancel();
            task_fn(ptr);
            return;
        }
        if (entry.queue != null) return;
        self.settled_tasks.append(entry, ptr, task_fn);
    }

    /// Settle point: run queued `runOutsideComputation` tasks once no computation is on the
    /// stack and no effect drain is in progress. Called by the reactive write paths after they
    /// drain; a no-op otherwise.
    pub fn drainSettledTasks(self: *SignalOwner) void {
        if (self.settled_tasks.head == null) return;
        if (self.draining_settled_tasks or self.graph.flushing or self.inReactiveComputation()) return;
        self.draining_settled_tasks = true;
        defer self.draining_settled_tasks = false;
        // Unlink before invoking: a task may write signals (their drain re-enters here and
        // returns), queue further tasks, or free other entries' owners (which cancel them).
        while (self.settled_tasks.popFirst()) |entry| entry.dispose_fn(entry.ptr);
    }

    /// Entry storage belongs to the resource and must stay stable until its
    /// callback runs or cancels the request. Reclamation is allocation-free.
    pub fn deferDisposal(
        self: *SignalOwner,
        entry: *DeferredDisposal,
        ptr: *anyopaque,
        dispose_fn: *const fn (*anyopaque) void,
    ) void {
        std.debug.assert(self.reactive_callback_depth > 0);
        self.deferred_disposals.append(entry, ptr, dispose_fn);
    }

    fn drainDeferredDisposals(self: *SignalOwner) bool {
        if (self.draining_disposals) return false;
        var dispatched = false;
        self.draining_disposals = true;
        defer self.draining_disposals = false;
        while (self.deferred_disposals.popFirst()) |entry| {
            // Unlink before invoking: the callback may free the entry itself,
            // cancel another request, or append more destruction work.
            const ptr = entry.ptr;
            const dispose_fn = entry.dispose_fn;
            dispatched = true;
            dispose_fn(ptr);
        }
        return dispatched;
    }

    /// Batch updates
    ///
    /// Usage:
    /// ```zig
    /// try owner.batch(struct {
    ///     fn update(ctx: anytype) void {
    ///         ctx.count.set(10);
    ///         ctx.name.set("Zenit");
    ///     }
    /// }.update, .{ .count = count, .name = name });
    /// ```
    pub fn batch(
        self: *SignalOwner,
        comptime batchFn: anytype,
        args: anytype,
    ) !void {
        self.beginBatch();
        defer self.endBatch();
        batchFn(args);
    }

    /// Non-closure batch form; must pair with `endBatch` (`defer owner.endBatch()`).
    /// Can nest; the outermost endBatch runs accumulated effects topologically once.
    ///
    /// The framework wraps this around event dispatch, timer callbacks, before_render/after_layout
    /// hooks and deferred tasks, so when a handler sets multiple signals, dependent effects run
    /// once and see the full state after all writes.
    pub fn beginBatch(self: *SignalOwner) void {
        self.assertThread();
        // BatchContext.begin only counts, won't fail.
        self.batch_ctx.begin() catch unreachable;
        // Sync push graph batch_depth; graph.markSignalWritten during batch only propagates not
        // drains, endBatch drains in topo order.
        self.graph.beginBatch();
    }

    pub fn endBatch(self: *SignalOwner) void {
        self.assertThread();
        // Order: graph exits the batch first (triggers topo-order drain); then batch_ctx.end (old
        // path is dead but its nesting count is kept).
        self.graph.endBatch() catch |err| {
            std.log.err("[reactive.SignalOwner] graph.endBatch failed: {}", .{err});
        };
        self.batch_ctx.end(self);
        self.drainSettledTasks();
    }

    /// Untrack dependencies
    ///
    /// Usage:
    /// ```zig
    /// const value = owner.untrack(signal.*, struct {
    ///     fn read(s: *Signal(i32)) i32 {
    ///         return s.peek();
    ///     }
    /// }.read);
    /// ```
    pub fn untrack(
        self: *SignalOwner,
        comptime untrackedFn: anytype,
        args: anytype,
    ) @TypeOf(untrackedFn(args)) {
        self.assertThread();
        // Push a null reader sentinel onto the graph track stack: the current reader's reads of
        // signal / memo don't register as dependencies (trackRead takes the stack top as reader,
        // a null id adds no edge). Lazily computed memos or newly run effects inside untrack
        // push their own id and track normally.
        //
        // Flag-based untracking (is_tracking / untracked_effect on owner letting Signal.get skip
        // the
        // 'current effect') is wrong: a memo computed during untrack's first read also runs under
        // that
        // current_effect, so its signal reads would be skipped and it would get no deps.
        //
        // Stack capacity is reserved at init; overflow fails immediately, because degrading to
        // unguarded global tracking would silently break memo deps.
        self.graph.pushTracking(graph_mod.NodeId.NULL) catch @panic("OOM: untrack sentinel (tracking stack beyond reserve)");
        defer self.graph.popTracking();

        return untrackedFn(args);
    }

    /// Thread-affinity assert (active only with runtime_safety enabled)
    pub fn assertThread(self: *SignalOwner) void {
        if (@import("builtin").os.tag == .freestanding) return;
        if (!std.debug.runtime_safety) return;
        const current = std.Thread.getCurrentId();
        if (self.thread_id != current) {
            std.debug.panic(
                "SignalOwner used across threads: expected={d} got={d}",
                .{ self.thread_id, current },
            );
        }
    }
};

// ===== Tests =====

test "SignalOwner: init/deinit" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    try std.testing.expect(owner.signals.items.len == 0);
    try std.testing.expect(owner.effects.items.len == 0);
}

test "SignalOwner: allocator" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    // Allocate some memory from Arena
    const slice = try owner.allocator().alloc(u8, 100);
    @memset(slice, 42);

    try std.testing.expectEqual(@as(u8, 42), slice[0]);
    try std.testing.expectEqual(@as(u8, 42), slice[99]);

    // No manual free needed, deinit reclaims once
}

test "SignalOwner: memory isolation" {
    var owner1 = try SignalOwner.init(std.testing.allocator);
    defer owner1.deinit();

    var owner2 = try SignalOwner.init(std.testing.allocator);
    defer owner2.deinit();

    // Two owners' memory is isolated
    const data1 = try owner1.allocator().create(i32);
    const data2 = try owner2.allocator().create(i32);

    data1.* = 100;
    data2.* = 200;

    try std.testing.expectEqual(@as(i32, 100), data1.*);
    try std.testing.expectEqual(@as(i32, 200), data2.*);
}
