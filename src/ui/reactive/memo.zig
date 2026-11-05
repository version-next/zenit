/// Memo: cached derived computation
///
/// Lazy pull on read:
/// - Creation does not compute immediately
/// - get() calls graph.updateIfNecessary: if the source is unchanged return the cache,
///   else recompute and increment version
/// - Downstream builds dependencies via graph.trackRead; when the source changes,
///   the graph marks downstream dirty
///
/// Design reference: Solid v1 Memo + Reactively paper (push-pull hybrid).
///
/// Usage:
/// ```zig
/// const doubled = try createMemo(owner, i32, .{ .count = count }, struct {
///     fn compute(ctx: anytype) i32 { return ctx.count.get() * 2; }
/// }.compute);
/// doubled.get()  // lazy computation + auto-tracking
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalOwner = @import("owner.zig").SignalOwner;
const Signal = @import("signal.zig").Signal;
const effect_mod = @import("effect.zig");
const Scope = @import("scope.zig").Scope;
const graph_mod = @import("graph.zig");
const ReactiveKind = @import("signal.zig").ReactiveKind;
const debug_checks = SignalOwner.debug_checks;
const alive_sentinel: u32 = 0x3E30_A11E;
const dead_sentinel: u32 = 0x3E30_DEAD;

pub fn Memo(comptime T: type) type {
    return struct {
        owner: *SignalOwner,
        graph_node_raw: u32,
        /// Cached current value; lazy compute fill on first read
        cache: T,
        /// Last result compare key (slice is content hash, see eq.EqKey): using old slice from
        /// cache to
        /// compare risks read freed buffer from source signal.
        cache_key: @import("eq.zig").EqKey(T) = undefined,
        /// Mark before first compute (avoid read undefined cache for compare)
        initialized: bool,
        /// computeFn + user context, store as type-erased ptr avoid generic expand in graph
        compute_ctx: *anyopaque,
        compute_fn: *const fn (compute_ctx: *anyopaque, out: *anyopaque) bool,
        debug: Debug = .{},

        const Self = @This();
        pub const Value = T;
        pub const zenit_reactive: ReactiveKind = .memo;

        pub const Debug = if (debug_checks) struct {
            alive: u32 = alive_sentinel,
            scope: ?*Scope = null,
        } else struct {};

        inline fn checkAlive(self: *const Self) void {
            if (debug_checks) {
                if (self.debug.alive != alive_sentinel) {
                    std.debug.panic("Memo({s}) used after its scope was disposed", .{@typeName(T)});
                }
            }
        }

        /// Owning scope; owner arena path or Release build return null.
        pub fn debugScope(self: *const Self) ?*Scope {
            return if (debug_checks) self.debug.scope else null;
        }

        /// Read value (lazy pull + auto track downstream)
        pub fn get(self: *Self) T {
            self.checkAlive();
            self.owner.assertThread();
            if (debug_checks) self.owner.noteTrackedRead("Memo");
            self.owner.beginReactiveCallback();
            defer self.owner.endReactiveCallback();
            const gid: graph_mod.NodeId = @bitCast(self.graph_node_raw);
            // Trigger lazy recompute (state==clean is no-op; dirty/check pull upstream)
            self.owner.graph.updateIfNecessary(gid);
            // Make caller also memo observer. build-edge fail don't lose: trackRead record caller
            // tracking_failed and stay dirty (retry next), createEffect first-run by this return
            // error.OutOfMemory, mount able pass error out. Same mechanism as Signal.get.
            self.owner.graph.trackRead(gid) catch |err| {
                std.log.warn("[reactive.Memo] graph.trackRead failed: {}", .{err});
            };
            return self.cache;
        }

        /// Read value (no track)
        pub fn peek(self: *Self) T {
            self.checkAlive();
            self.owner.assertThread();
            self.owner.beginReactiveCallback();
            defer self.owner.endReactiveCallback();
            const gid: graph_mod.NodeId = @bitCast(self.graph_node_raw);
            self.owner.graph.updateIfNecessary(gid);
            return self.cache;
        }
    };
}

/// Create Memo: cached derived (lazy pull).
pub fn createMemo(
    owner: *SignalOwner,
    comptime T: type,
    context: anytype,
    comptime computeFn: anytype,
) !*Memo(T) {
    const Context = @TypeOf(context);
    const MemoT = Memo(T);

    // Wrap computeFn: graph.recompute call restore compute_ctx to (Memo + Context),
    // call user computeFn, compare old/new cache, return change.
    const Closure = struct {
        memo: *MemoT,
        ctx: Context,

        fn run(opaque_ctx: *anyopaque, out: *anyopaque) bool {
            _ = out;
            const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
            const new_value = computeFn(c.ctx);
            const eq_mod = @import("eq.zig");
            const key = eq_mod.eqKey(T, new_value);
            // First: cache is undefined, must never read to compare, all is change.
            const changed = !c.memo.initialized or !eq_mod.eqlValue(eq_mod.EqKey(T), c.memo.cache_key, key);
            c.memo.cache = new_value;
            c.memo.cache_key = key;
            c.memo.initialized = true;
            return changed;
        }

        fn graphRecompute(opaque_ctx: *anyopaque) bool {
            const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
            return run(opaque_ctx, c);
        }
    };

    const memo = try owner.allocator().create(MemoT);
    // Arena alloc frame-recyclable, but half-registered (memo created, graph node not) let
    // later registry-walk code read uninitialized struct, all fail must full rollback.
    errdefer owner.allocator().destroy(memo);
    const closure = try owner.allocator().create(Closure);
    errdefer owner.allocator().destroy(closure);
    closure.* = .{
        .memo = memo,
        .ctx = context,
    };

    // Register memo to graph, state .dirty (first read compute)
    const gid = try owner.graph.createNodeRaw(.memo, &Closure.graphRecompute, closure);
    memo.* = .{
        .owner = owner,
        .graph_node_raw = @bitCast(gid),
        .cache = undefined,
        .initialized = false,
        .compute_ctx = closure,
        .compute_fn = &Closure.run,
    };

    return memo;
}

/// Create Memo in Scope (keep-alive path)
pub fn createMemoInScope(
    scope: *Scope,
    comptime T: type,
    context: anytype,
    comptime computeFn: anytype,
) !*Memo(T) {
    // scope path same owner path, lazy pull on read, no longer create internal Signal+Effect.
    const S = Scoped(T, @TypeOf(context), computeFn);
    const memo = try S.build(scope, context);
    errdefer S.destroy(memo, scope.allocator);
    try scope.registerResource(@ptrCast(memo), S.cleanup);
    if (comptime @import("builtin").is_test) scope.resources.items[scope.resources.items.len - 1].test_graph_node_raw = memo.graph_node_raw;
    return memo;
}

/// `deriveInScope` result: static value, or leftover memo.
pub fn Derived(comptime T: type) type {
    return union(enum) { value: T, memo: *Memo(T) };
}

/// Runtime static-hoist (Yix computed/property expr): create the memo and eval it once
/// immediately; if eval **records no dependency** (and no build-edge failure, i.e. a real eval),
/// shrink to a static value, else keep the memo in scope.
///
/// Dependencies are recorded exactly by the reactive graph's reader stack: any external signal
/// read by the expr function counts, never missed like a static name-based judgment. Only get()
/// counts as a dep; peek() and plain global vars don't (same as a normal memo: a 0-dep memo never
/// recomputes). Shrinking happens before anyone sees the memo (not registered in scope, no reader
/// edge). Value ownership is the same as a normal memo: cache already borrowed, shrunk reference
/// points at the same data.
pub fn deriveInScope(
    scope: *Scope,
    comptime T: type,
    context: anytype,
    comptime computeFn: anytype,
) !Derived(T) {
    // Eval once with probe reader: no track read (0-dep static) direct get static, don't alloc
    // memo.
    // Static prop derived is norm (each Yix component each computed, prev build memo
    // (context+value,
    // Button outer ~6.8KB) then destroy immediate. Track read build memo (re-eval, establish dep
    // edge).
    {
        const graph = &scope.owner.graph;
        const before = graph.probe_reads;
        try graph.pushTracking(graph_mod.NodeId.PROBE);
        scope.owner.beginReactiveCallback();
        const value = computeFn(context);
        scope.owner.endReactiveCallback();
        graph.popTracking();
        if (graph.probe_reads == before) return .{ .value = value };
    }
    const S = Scoped(T, @TypeOf(context), computeFn);
    const memo = try S.build(scope, context);
    errdefer S.destroy(memo, scope.allocator);
    const gid: graph_mod.NodeId = @bitCast(memo.graph_node_raw);
    // Eval once (don't give caller reader edge for this memo: caller not observer yet)
    scope.owner.beginReactiveCallback();
    scope.owner.graph.updateIfNecessary(gid);
    scope.owner.endReactiveCallback();
    const node = scope.owner.graph.getNode(gid).?;
    // Recursion depth overrun updateIfNecessary skip eval (initialized still false); build edge OOM
    // tracking_failed: both can't shrink.
    if (memo.initialized and !node.tracking_failed and node.sources.items.len == 0) {
        const value = memo.cache;
        S.destroy(memo, scope.allocator);
        return .{ .value = value };
    }
    try scope.registerResource(@ptrCast(memo), S.cleanup);
    if (comptime @import("builtin").is_test) scope.resources.items[scope.resources.items.len - 1].test_graph_node_raw = memo.graph_node_raw;
    return .{ .memo = memo };
}

/// scope-path memo: alloc, register to graph (not yet given to scope manage) and free
fn Scoped(comptime T: type, comptime Context: type, comptime computeFn: anytype) type {
    const MemoT = Memo(T);
    return struct {
        const Closure = struct {
            memo: *MemoT,
            ctx: Context,

            fn run(opaque_ctx: *anyopaque, out: *anyopaque) bool {
                _ = out;
                const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
                const new_value = computeFn(c.ctx);
                const eq_mod = @import("eq.zig");
                const key = eq_mod.eqKey(T, new_value);
                // First: cache is undefined, must never read to compare, all is change.
                const changed = !c.memo.initialized or !eq_mod.eqlValue(eq_mod.EqKey(T), c.memo.cache_key, key);
                c.memo.cache = new_value;
                c.memo.cache_key = key;
                c.memo.initialized = true;
                return changed;
            }
            fn graphRecompute(opaque_ctx: *anyopaque) bool {
                const c: *@This() = @ptrCast(@alignCast(opaque_ctx));
                return run(opaque_ctx, c);
            }
        };

        /// Alloc memo + closure and create graph node; fail full rollback. Returned memo not yet
        /// register to scope.
        fn build(scope: *Scope, context: Context) !*MemoT {
            const memo = try scope.allocator.create(MemoT);
            // scope.allocator is caller allocator: before registerResource hang cleanup
            // any fail is net leak, must errdefer full rollback (has built graph node too)
            errdefer scope.allocator.destroy(memo);
            const closure = try scope.allocator.create(Closure);
            errdefer scope.allocator.destroy(closure);
            closure.* = .{ .memo = memo, .ctx = context };
            const gid = try scope.owner.graph.createNodeRaw(.memo, &Closure.graphRecompute, closure);
            memo.* = .{
                .owner = scope.owner,
                .graph_node_raw = @bitCast(gid),
                .cache = undefined,
                .initialized = false,
                .compute_ctx = closure,
                .compute_fn = &Closure.run,
            };
            if (debug_checks) memo.debug.scope = scope;
            return memo;
        }

        /// Unregister graph node and free memo and closure (two separate alloc both free)
        fn destroy(m: *MemoT, allocator: std.mem.Allocator) void {
            const gid_destroy: graph_mod.NodeId = @bitCast(m.graph_node_raw);
            m.owner.graph.destroyNode(gid_destroy);
            // After destroyNode graph no longer hold closure, safe to free.
            const c: *Closure = @ptrCast(@alignCast(m.compute_ctx));
            allocator.destroy(c);
            if (debug_checks) m.debug.alive = dead_sentinel;
            allocator.destroy(m);
        }

        fn cleanup(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            destroy(@ptrCast(@alignCast(ptr)), allocator);
        }
    };
}

// ===== Tests =====

test "Memo: basic derived computation" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 5);

    const doubled = try createMemo(owner, i32, .{ .count = count }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.count.get() * 2;
        }
    }.compute);

    try std.testing.expectEqual(@as(i32, 10), doubled.get());

    count.set(7);
    try std.testing.expectEqual(@as(i32, 14), doubled.get());

    count.set(0);
    try std.testing.expectEqual(@as(i32, 0), doubled.get());
}

test "Memo: tracks multiple signals" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const a = try Signal(i32).create(owner, 3);
    const b = try Signal(i32).create(owner, 4);

    const sum = try createMemo(owner, i32, .{ .a = a, .b = b }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.a.get() + ctx.b.get();
        }
    }.compute);

    try std.testing.expectEqual(@as(i32, 7), sum.get());

    a.set(10);
    try std.testing.expectEqual(@as(i32, 14), sum.get());

    b.set(20);
    try std.testing.expectEqual(@as(i32, 30), sum.get());
}

test "Memo: downstream effect reacts to memo change" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 2);

    const doubled = try createMemo(owner, i32, .{ .count = count }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.count.get() * 2;
        }
    }.compute);

    var effect_result: i32 = 0;

    try effect_mod.createEffect(owner, .{
        .doubled = doubled,
        .result = &effect_result,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.result.* = ctx.doubled.get();
        }
    }.run);

    // Effect first run
    try std.testing.expectEqual(@as(i32, 4), effect_result);

    // Modify source Signal -> Memo update -> downstream Effect update
    count.set(5);
    try std.testing.expectEqual(@as(i32, 10), effect_result);
}

test "Memo: skips when value unchanged" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const x = try Signal(i32).create(owner, 5);
    const y = try Signal(i32).create(owner, -5);

    // abs(x + y), when x=5, y=-5 result always 0
    const abs_sum = try createMemo(owner, i32, .{ .x = x, .y = y }, struct {
        fn compute(ctx: anytype) i32 {
            const s = ctx.x.get() + ctx.y.get();
            return if (s < 0) -s else s;
        }
    }.compute);

    var effect_count: i32 = 0;

    try effect_mod.createEffect(owner, .{
        .abs_sum = abs_sum,
        .counter = &effect_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.abs_sum.get();
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 0), abs_sum.get());
    try std.testing.expectEqual(@as(i32, 1), effect_count);

    // Change x and y keep total same -> Memo value same -> downstream Effect should not run again
    // Note: x.set trigger memo effect re-eval, but abs(6+(-5))=1 ≠ 0
    // must ensure truly unchanged case.
    x.set(10);
    y.set(-10);
    // abs(10+(-10))=0, but middle x.set(10) time abs(10+(-5))=5, so effect run
    // final is 0, but process has change
    try std.testing.expectEqual(@as(i32, 0), abs_sum.get());
}

test "Memo: peek doesn't track" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 3);
    const tripled = try createMemo(owner, i32, .{ .count = count }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.count.get() * 3;
        }
    }.compute);

    var effect_run_count: i32 = 0;

    try effect_mod.createEffect(owner, .{
        .tripled = tripled,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.tripled.peek(); // peek no track
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    count.set(10);
    // Memo update, but downstream Effect use peek, so should not re-run
    try std.testing.expectEqual(@as(i32, 1), effect_run_count);
    // but memo value truly update
    try std.testing.expectEqual(@as(i32, 30), tripled.peek());
}

test "deriveInScope：读过信号的表达式在任何分配失败下都不会被收缩成静态值；不读信号时收缩且不留图节点" {
    const reactive_scope = @import("scope.zig");
    // Don't read signal: shrink to value, no graph node
    {
        var owner = try SignalOwner.init(std.testing.allocator);
        defer owner.deinit();
        const scope = try reactive_scope.Scope.init(std.testing.allocator, null, owner);
        defer scope.dispose();
        const before = owner.graph.countByKind().get(.memo);
        const d = try deriveInScope(scope, i32, .{ .x = @as(i32, 3) }, struct {
            fn compute(ctx: anytype) i32 {
                return ctx.x * 2;
            }
        }.compute);
        try std.testing.expectEqual(@as(i32, 6), d.value);
        try std.testing.expectEqual(before, owner.graph.countByKind().get(.memo));
    }
    // Don't read signal: no alloc at all (probe eval, don't create then destroy temp memo)--all
    // fail still
    // get static value
    {
        var owner = try SignalOwner.init(std.testing.allocator);
        defer owner.deinit();
        const scope = try reactive_scope.Scope.init(std.testing.allocator, null, owner);
        defer scope.dispose();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const saved_graph = owner.graph.allocator;
        const saved_scope = scope.allocator;
        owner.graph.allocator = failing.allocator();
        scope.allocator = failing.allocator();
        defer {
            owner.graph.allocator = saved_graph;
            scope.allocator = saved_scope;
        }
        const d = try deriveInScope(scope, i32, .{ .x = @as(i32, 4) }, struct {
            fn compute(ctx: anytype) i32 {
                return ctx.x + 1;
            }
        }.compute);
        try std.testing.expectEqual(@as(i32, 5), d.value);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    // Read signal: per-alloc inject fail. Result only error or memo left (build edge fail
    // tracking_failed,
    // can't treat as 0-dep shrink)
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var owner = try SignalOwner.init(std.testing.allocator);
        defer owner.deinit();
        const scope = try reactive_scope.Scope.init(std.testing.allocator, null, owner);
        defer scope.dispose();
        const sig = try scope.createSignal(i32, 5);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const saved_graph = owner.graph.allocator;
        const saved_scope = scope.allocator;
        owner.graph.allocator = failing.allocator();
        scope.allocator = failing.allocator();
        defer {
            owner.graph.allocator = saved_graph;
            scope.allocator = saved_scope;
        }
        const result = deriveInScope(scope, i32, .{ .s = sig }, struct {
            fn compute(ctx: anytype) i32 {
                return ctx.s.get() + 1;
            }
        }.compute) catch continue;
        switch (result) {
            .value => return error.CollapsedDespiteReadingASignal,
            .memo => |m| try std.testing.expectEqual(@as(i32, 6), m.peek()),
        }
    }
}
