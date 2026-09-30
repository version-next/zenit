const std = @import("std");
const Allocator = std.mem.Allocator;

const EffectBase = @import("effect_base.zig").EffectBase;
const SignalOwner = @import("owner.zig").SignalOwner;
const Scope = @import("scope.zig").Scope;

/// Effect: 自动响应依赖变化
///
/// 核心机制:
/// 1. Effect 运行时,会自动追踪所有访问的 Signal
/// 2. 当任何依赖的 Signal 变化时,Effect 会自动重新运行
/// 3. 每次运行前会清空旧依赖,重新收集
///
/// 用法:
/// ```zig
/// try owner.createEffect(.{ .count = count }, struct {
///     fn run(ctx: anytype) void {
///         std.debug.print("Count: {d}\n", .{ctx.count.get()});
///     }
/// }.run);
/// ```
pub fn Effect(comptime Context: type, comptime effectFn: anytype) type {
    return struct {
        base: EffectBase,
        context: Context,
        owner: *SignalOwner,

        const Self = @This();

        /// 创建 Effect（Arena 路径，旧代码兼容）
        pub fn create(owner: *SignalOwner, context: Context) !*Self {
            const effect = try owner.allocator().create(Self);
            errdefer owner.allocator().destroy(effect);
            effect.* = .{
                .base = EffectBase.init(owner.allocator(), &vtable),
                .context = context,
                .owner = owner,
            };

            // 注册到 owner
            try owner.registerEffect(&effect.base);
            // graph 注册失败时把半注册态摘掉：注册表里留一个 graph_node_raw
            // 仍是 0xFFFFFFFF 的 EffectBase，会被后续遍历当成活 effect
            errdefer if (owner.effects.items.len > 0 and
                owner.effects.items[owner.effects.items.len - 1] == &effect.base)
            {
                _ = owner.effects.pop();
            };

            // 在 graph 注册 effect node + recompute callback。
            // graph 的 markSignalWritten 路径会通过 NodeId 入 pending queue，
            // drainPendingEffects 时按拓扑序跑——调到这个 callback。
            const gid = try owner.graph.createNodeRaw(.effect, &graphRecomputeCb, &effect.base);
            effect.base.graph_node_raw = @bitCast(gid);

            // 初始运行一次（建立依赖）
            effect.runWithTracking();

            return effect;
        }

        /// 在 Scope 中创建 Effect（保留模式路径）
        pub fn createInScope(scope: *Scope, context: Context) !*Self {
            const owner = scope.owner;
            const allocator = scope.allocator;
            owner.assertThread();
            const effect = try allocator.create(Self);
            // scope.allocator 是 caller allocator：graph 注册失败必须整体回退，
            // 否则 effect 结构体净泄漏 + scope.effects 里留半注册态
            var effect_owned_by_scope = false;
            errdefer if (!effect_owned_by_scope) allocator.destroy(effect);
            effect.* = .{
                .base = EffectBase.init(allocator, &scope_vtable),
                .context = context,
                .owner = owner,
            };
            // Scope 路径：dependencies 列表也用 scope.allocator
            effect.base.scope_allocator = allocator;

            // 注册到 scope
            try scope.registerEffect(&effect.base);
            var registered_with_scope = true;
            errdefer if (registered_with_scope and scope.effects.items.len > 0 and
                scope.effects.items[scope.effects.items.len - 1] == &effect.base)
            {
                _ = scope.effects.pop();
            };

            // 同步在 graph 注册（与 Arena 路径一致）
            const gid = try owner.graph.createNodeRaw(.effect, &graphRecomputeCb, &effect.base);
            errdefer owner.graph.destroyNode(gid);
            effect.base.graph_node_raw = @bitCast(gid);

            // 初始运行一次
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
            if (owner.graph.getNode(gid)) |node| {
                if (node.tracking_failed) return error.OutOfMemory;
            }
            return effect;
        }

        /// 虚函数表（Arena 路径）
        const vtable = EffectBase.VTable{
            .run = runImpl,
            .cleanup = cleanupImpl,
        };

        /// 虚函数表（Scope 路径，支持单独释放）
        const scope_vtable = EffectBase.VTable{
            .run = runImpl,
            .cleanup = cleanupImpl,
            .destroy = destroyImpl,
        };

        fn runImpl(base: *EffectBase) void {
            const self: *Self = @fieldParentPtr("base", base);
            effectFn(self.context);
        }

        /// graph 调度路径下的 recompute callback。
        /// 走 runWithTrackingFast——graph.recomputeNode 已经做了
        /// clearSources + pushTracking + popTracking，跳过重复设置（~30 ns/effect）。
        /// 返回 false：effect 没有"值"概念（不影响 version 戳）。
        fn graphRecomputeCb(ctx: *anyopaque) bool {
            const base: *EffectBase = @ptrCast(@alignCast(ctx));
            const self: *Self = @fieldParentPtr("base", base);
            base.runWithTrackingFast(self.owner);
            return false;
        }

        fn cleanupImpl(base: *EffectBase) void {
            // Arena allocator 会自动释放所有内存
            // 依赖关系的清理在 owner.deinit() 中统一处理
            _ = base;
        }

        fn destroyImpl(base: *EffectBase, allocator: Allocator) void {
            const self: *Self = @fieldParentPtr("base", base);
            // dependencies 字段已删；graph 路径处理边
            allocator.destroy(self);
        }

        /// 运行 Effect 并重新收集依赖
        fn runWithTracking(self: *Self) void {
            self.base.runWithTracking(self.owner, self.owner.allocator());
        }
    };
}

// ===== 辅助函数 =====

/// 创建 Effect 的便捷函数
///
/// owner: SignalOwner
/// context: 传递给 effectFn 的上下文
/// comptime effectFn: Effect 函数
pub fn createEffect(
    owner: *SignalOwner,
    context: anytype,
    comptime effectFn: anytype,
) !void {
    const Context = @TypeOf(context);
    const EffectType = Effect(Context, effectFn);
    _ = try EffectType.create(owner, context);
}

// ===== 测试 =====

const Signal = @import("signal.zig").Signal;

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
            _ = ctx.count.get(); // 建立依赖
            ctx.counter.* += 1;
        }
    }.run);

    // Effect 创建时应该执行一次
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
            _ = ctx.count.get(); // 自动追踪依赖
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    // 修改 count,Effect 应该自动重新执行
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
            _ = ctx.tracked.get(); // 追踪
            _ = ctx.untracked.peek(); // 不追踪
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    tracked.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count); // Effect 重新运行

    untracked.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count); // Effect 不运行
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

    // A: trigger true 时，在 untrack 内执行 batch，批量更新 source
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
                            inner.source.set(2); // batch 去重后 B 只应运行一次
                        }
                    }.update, .{ .source = args.source }) catch unreachable;
                }
            }.op, .{
                .owner = ctx.owner,
                .source = ctx.source,
            });
        }
    }.run);

    // 初始运行
    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);
    try std.testing.expectEqual(@as(i32, 1), c_runs);
    try std.testing.expectEqual(@as(i32, 0), leaf_value);

    // 触发 A：在 untrack + batch 中修改 source，B/C 需正确运行并保持订阅
    trigger.set(true);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
    try std.testing.expectEqual(@as(i32, 2), c_runs);
    try std.testing.expectEqual(@as(i32, 4), leaf_value);

    // 再次直接更新 source，验证 B/C 订阅没有丢失
    source.set(3);
    try std.testing.expectEqual(@as(i32, 3), b_runs);
    try std.testing.expectEqual(@as(i32, 3), c_runs);
    try std.testing.expectEqual(@as(i32, 6), leaf_value);
}
