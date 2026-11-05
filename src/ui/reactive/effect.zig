const std = @import("std");
const Allocator = std.mem.Allocator;

const EffectBase = @import("effect_base.zig").EffectBase;
const SignalOwner = @import("owner.zig").SignalOwner;
const Scope = @import("scope.zig").Scope;

/// Effect: automatically responds to dependency changes
///
/// Core mechanism:
/// 1. Effect runtime auto-tracks all accessed Signals
/// 2. When any dependency Signal changes, Effect reruns automatically
/// 3. Before each run, clears old dependencies and recollects them
///
/// Usage:
/// ```zig
/// try owner.createEffect(.{ .count = count }, struct {
///     fn run(ctx: anytype) void {
///         std.debug.print("Count: {d}\n", .{ctx.count.get()});
///     }
/// }.run);
/// ```
pub fn Effect(comptime Context: type, comptime effectFn: anytype) type {
    // An effect function may return an error union. Its first run happens inside
    // `create` / `createInScope` (normally while mounting): an error there is returned by the
    // creating call, with the half-made effect removed, so the mount fails instead of carrying
    // on with a partly applied result. A later run (a dependency changed) has nobody to report
    // to: the error is logged and the effect waits for its next run; such functions must leave
    // their target unchanged when they fail (all-or-nothing writes).
    const fallible = @typeInfo(@typeInfo(@TypeOf(effectFn)).@"fn".return_type.?) == .error_union;
    return struct {
        base: EffectBase,
        context: Context,
        owner: *SignalOwner,
        /// error of the first run (fallible effect functions only)
        first_error: if (fallible) ?anyerror else void = if (fallible) null else {},
        started: if (fallible) bool else void = if (fallible) false else {},

        const Self = @This();

        /// Create Effect (owner arena path, released with owner; app code use `scope.createEffect`)
        pub fn create(owner: *SignalOwner, context: Context) !*Self {
            const effect = try owner.allocator().create(Self);
            errdefer owner.allocator().destroy(effect);
            effect.* = .{
                .base = EffectBase.init(owner.allocator(), &vtable),
                .context = context,
                .owner = owner,
            };

            // Register to owner
            try owner.registerEffect(&effect.base);
            // graph register fail strip half-register: table left EffectBase with graph_node_raw
            // still 0xFFFFFFFF treated live effect by later traverse
            errdefer if (owner.effects.items.len > 0 and
                owner.effects.items[owner.effects.items.len - 1] == &effect.base)
            {
                _ = owner.effects.pop();
            };

            // Register effect node + recompute callback in graph.
            // graph markSignalWritten path queues via NodeId, drainPendingEffects runs topo-order,
            // calls this callback.
            const gid = try owner.graph.createNodeRaw(.effect, &graphRecomputeCb, &effect.base);
            errdefer owner.graph.destroyNode(gid);
            effect.base.graph_node_raw = @bitCast(gid);

            // Initial run once (establish dependencies)
            effect.runWithTracking();
            try effect.takeFirstError();

            return effect;
        }

        /// Create Effect in Scope (retain-mode path)
        pub fn createInScope(scope: *Scope, context: Context) !*Self {
            const owner = scope.owner;
            const allocator = scope.allocator;
            owner.assertThread();
            const effect = try allocator.create(Self);
            // scope.allocator is caller allocator: graph register fail must rollback all,
            // else effect struct pure leak + scope.effects left half-register
            var effect_owned_by_scope = false;
            errdefer if (!effect_owned_by_scope) allocator.destroy(effect);
            effect.* = .{
                .base = EffectBase.init(allocator, &scope_vtable),
                .context = context,
                .owner = owner,
            };
            // Scope path: dependencies list also uses scope.allocator
            effect.base.scope_allocator = allocator;

            // Register to scope
            try scope.registerEffect(&effect.base);
            var registered_with_scope = true;
            errdefer if (registered_with_scope and scope.effects.items.len > 0 and
                scope.effects.items[scope.effects.items.len - 1] == &effect.base)
            {
                _ = scope.effects.pop();
            };

            // Sync register in graph (match Arena path)
            const gid = try owner.graph.createNodeRaw(.effect, &graphRecomputeCb, &effect.base);
            errdefer owner.graph.destroyNode(gid);
            effect.base.graph_node_raw = @bitCast(gid);

            // Initial run once
            owner.beginReactiveCallback();
            effect.runWithTracking();
            const scope_was_disposed = scope.willBeDisposedAfterReactiveCallback();
            if (scope_was_disposed) {
                // Deferred scope teardown owns both removal and destruction;
                // disarm creation errdefers before that teardown frees scope.
                registered_with_scope = false;
                effect_owned_by_scope = true;
                owner.endReactiveCallback();
                return error.ScopeDisposed;
            }
            owner.endReactiveCallback();
            try effect.takeFirstError();
            if (owner.graph.getNode(gid)) |node| {
                if (node.tracking_failed) return error.OutOfMemory;
            }
            return effect;
        }

        /// After the first run: its error, if the function returned one (later runs log theirs).
        fn takeFirstError(self: *Self) !void {
            if (comptime !fallible) return;
            self.started = true;
            if (self.first_error) |err| return err;
        }

        /// vtable (Arena path)
        const vtable = EffectBase.VTable{
            .run = runImpl,
            .cleanup = cleanupImpl,
        };

        /// vtable (Scope path, supports individual release)
        const scope_vtable = EffectBase.VTable{
            .run = runImpl,
            .cleanup = cleanupImpl,
            .destroy = destroyImpl,
        };

        fn runImpl(base: *EffectBase) void {
            const self: *Self = @fieldParentPtr("base", base);
            if (comptime !fallible) return effectFn(self.context);
            if (!self.started) self.first_error = null; // a rerun of the first run starts over
            effectFn(self.context) catch |err| {
                if (!self.started) {
                    self.first_error = err;
                    return;
                }
                std.log.warn("reactive: effect update failed ({s}); its previous result stays until the effect runs again", .{@errorName(err)});
            };
        }

        /// recompute callback in graph dispatch path.
        /// use runWithTrackingFast, graph.recomputeNode already did
        /// clearSources + pushTracking + popTracking, skip duplicate setup (~30 ns/effect).
        /// return false: effect has no 'value' concept (doesn't affect version stamp).
        fn graphRecomputeCb(ctx: *anyopaque) bool {
            const base: *EffectBase = @ptrCast(@alignCast(ctx));
            const self: *Self = @fieldParentPtr("base", base);
            base.runWithTrackingFast(self.owner);
            return false;
        }

        fn cleanupImpl(base: *EffectBase) void {
            // Arena allocator auto-releases all memory
            // dependency cleanup in owner.deinit() unified
            _ = base;
        }

        fn destroyImpl(base: *EffectBase, allocator: Allocator) void {
            const self: *Self = @fieldParentPtr("base", base);
            // dependencies field deleted; graph path handles edge
            allocator.destroy(self);
        }

        /// Run Effect and recollect dependencies
        fn runWithTracking(self: *Self) void {
            self.base.runWithTracking(self.owner, self.owner.allocator());
        }
    };
}

// ===== helper functions =====

/// Convenience create Effect
///
/// owner: SignalOwner
/// context: context passed to effectFn
/// comptime effectFn: Effect function
pub fn createEffect(
    owner: *SignalOwner,
    context: anytype,
    comptime effectFn: anytype,
) !void {
    const Context = @TypeOf(context);
    const EffectType = Effect(Context, effectFn);
    _ = try EffectType.create(owner, context);
}

// ===== test =====

const Signal = @import("signal.zig").Signal;

test "Effect: fallible function — first-run error fails creation without leftovers, later errors keep the previous result" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(std.testing.allocator, null, owner);
    defer scope.dispose();
    const count = try scope.createSignal(i32, 0);
    const Ctx = struct {
        count: *Signal(i32),
        fail_at: i32,
        applied: *i32,
        fn run(c: @This()) error{OutOfMemory}!void {
            const v = c.count.get();
            if (v == c.fail_at) return error.OutOfMemory;
            c.applied.* = v;
        }
    };
    var applied: i32 = -1;
    const effects = owner.graph.countByKind().get(.effect);
    try std.testing.expectError(error.OutOfMemory, scope.createEffect(Ctx{ .count = count, .fail_at = 0, .applied = &applied }, Ctx.run));
    try std.testing.expectEqual(effects, owner.graph.countByKind().get(.effect));
    try std.testing.expectEqual(@as(usize, 0), scope.effects.items.len);
    count.set(1); // the failed effect is gone: nothing runs
    try std.testing.expectEqual(@as(i32, -1), applied);

    try scope.createEffect(Ctx{ .count = count, .fail_at = 2, .applied = &applied }, Ctx.run);
    try std.testing.expectEqual(@as(i32, 1), applied);
    count.set(2); // later failure: logged, previous result stays, the effect stays subscribed
    try std.testing.expectEqual(@as(i32, 1), applied);
    count.set(3);
    try std.testing.expectEqual(@as(i32, 3), applied);

    // owner (arena) path reports the first-run error the same way
    try std.testing.expectError(error.OutOfMemory, createEffect(owner, Ctx{ .count = count, .fail_at = 3, .applied = &applied }, Ctx.run));
}

test "Effect: basic execution" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    var effect_run_count: i32 = 0;

    try createEffect(owner, .{
        .count = count,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get(); // establish dependency
            ctx.counter.* += 1;
        }
    }.run);

    // Effect created should run once
    try std.testing.expectEqual(@as(i32, 1), effect_run_count);
}

test "Effect: auto dependency tracking" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    var effect_run_count: i32 = 0;

    try createEffect(owner, .{
        .count = count,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get(); // auto-track dependencies
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    // modify count, Effect should auto-rerun
    count.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count);

    count.set(2);
    try std.testing.expectEqual(@as(i32, 3), effect_run_count);
}

test "Effect: multiple signals" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const a = try Signal(i32).create(owner, 1);
    const b = try Signal(i32).create(owner, 2);

    var sum: i32 = 0;

    try createEffect(owner, .{
        .a = a,
        .b = b,
        .result = &sum,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.result.* = ctx.a.get() + ctx.b.get();
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 3), sum);

    a.set(10);
    try std.testing.expectEqual(@as(i32, 12), sum);

    b.set(20);
    try std.testing.expectEqual(@as(i32, 30), sum);
}

test "Effect: no tracking with peek" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const tracked = try Signal(i32).create(owner, 0);
    const untracked = try Signal(i32).create(owner, 0);

    var effect_run_count: i32 = 0;

    try createEffect(owner, .{
        .tracked = tracked,
        .untracked = untracked,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.tracked.get(); // track
            _ = ctx.untracked.peek(); // don't track
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    tracked.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count); // Effect reruns

    untracked.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count); // Effect not run
}

test "Effect: dynamic dependency switching" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const use_a = try Signal(bool).create(owner, true);
    const a = try Signal(i32).create(owner, 1);
    const b = try Signal(i32).create(owner, 10);

    var last: i32 = 0;
    var runs: i32 = 0;

    try createEffect(owner, .{
        .use_a = use_a,
        .a = a,
        .b = b,
        .last = &last,
        .runs = &runs,
    }, struct {
        fn run(ctx: anytype) void {
            if (ctx.use_a.get()) {
                ctx.last.* = ctx.a.get();
            } else {
                ctx.last.* = ctx.b.get();
            }
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), last);
    try std.testing.expectEqual(@as(i32, 1), runs);

    a.set(2);
    try std.testing.expectEqual(@as(i32, 2), last);
    try std.testing.expectEqual(@as(i32, 2), runs);

    use_a.set(false);
    try std.testing.expectEqual(@as(i32, 10), last);
    try std.testing.expectEqual(@as(i32, 3), runs);

    a.set(3);
    try std.testing.expectEqual(@as(i32, 10), last);
    try std.testing.expectEqual(@as(i32, 3), runs);

    b.set(11);
    try std.testing.expectEqual(@as(i32, 11), last);
    try std.testing.expectEqual(@as(i32, 4), runs);
}

test "Effect: untrack read does not subscribe" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    var runs: i32 = 0;

    try createEffect(owner, .{
        .owner = owner,
        .count = count,
        .runs = &runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.owner.untrack(struct {
                fn read(sig: *Signal(i32)) i32 {
                    return sig.get();
                }
            }.read, ctx.count);
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), runs);

    count.set(1);
    try std.testing.expectEqual(@as(i32, 1), runs);
}

test "Effect: untrack write keeps subscriptions" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);
    var runs: i32 = 0;

    try createEffect(owner, .{
        .count = count,
        .runs = &runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), runs);

    _ = owner.untrack(struct {
        fn write(sig: *Signal(i32)) void {
            sig.set(1);
        }
    }.write, count);

    try std.testing.expectEqual(@as(i32, 2), runs);

    count.set(2);
    try std.testing.expectEqual(@as(i32, 3), runs);
}

test "Effect: batch + untrack + nested effects keep tracking" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const trigger = try Signal(bool).create(owner, false);
    const source = try Signal(i32).create(owner, 0);
    const mirror = try Signal(i32).create(owner, 0);

    var a_runs: i32 = 0;
    var b_runs: i32 = 0;
    var c_runs: i32 = 0;
    var leaf_value: i32 = -1;

    // B: source -> mirror
    try createEffect(owner, .{
        .source = source,
        .mirror = mirror,
        .runs = &b_runs,
    }, struct {
        fn run(ctx: anytype) void {
            const s = ctx.source.get();
            ctx.runs.* += 1;
            ctx.mirror.set(s * 2);
        }
    }.run);

    // C: mirror -> leaf_value
    try createEffect(owner, .{
        .mirror = mirror,
        .runs = &c_runs,
        .leaf = &leaf_value,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.runs.* += 1;
            ctx.leaf.* = ctx.mirror.get();
        }
    }.run);

    // A: trigger true time, in untrack execute batch, batch-update source
    try createEffect(owner, .{
        .owner = owner,
        .trigger = trigger,
        .source = source,
        .runs = &a_runs,
    }, struct {
        fn run(ctx: anytype) void {
            const enabled = ctx.trigger.get();
            ctx.runs.* += 1;
            if (!enabled) return;

            _ = ctx.owner.untrack(struct {
                fn op(args: anytype) void {
                    args.owner.batch(struct {
                        fn update(inner: anytype) void {
                            inner.source.set(1);
                            inner.source.set(2); // batch dedup so B only run once
                        }
                    }.update, .{ .source = args.source }) catch unreachable;
                }
            }.op, .{
                .owner = ctx.owner,
                .source = ctx.source,
            });
        }
    }.run);

    // initial run
    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);
    try std.testing.expectEqual(@as(i32, 1), c_runs);
    try std.testing.expectEqual(@as(i32, 0), leaf_value);

    // trigger A: in untrack + batch modify source, B/C must run correctly and keep subscribe
    trigger.set(true);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
    try std.testing.expectEqual(@as(i32, 2), c_runs);
    try std.testing.expectEqual(@as(i32, 4), leaf_value);

    // direct update source again, verify B/C subscribe not lost
    source.set(3);
    try std.testing.expectEqual(@as(i32, 3), b_runs);
    try std.testing.expectEqual(@as(i32, 3), c_runs);
    try std.testing.expectEqual(@as(i32, 6), leaf_value);
}
