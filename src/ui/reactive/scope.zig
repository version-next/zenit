const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalBase = @import("signal_base.zig").SignalBase;
const EffectBase = @import("effect_base.zig").EffectBase;
const SignalOwner = @import("owner.zig").SignalOwner;
const Signal = @import("signal.zig").Signal;
const effect_mod = @import("effect.zig");
const Memo = @import("memo.zig").Memo;
const memo_mod = @import("memo.zig");

/// Scope: 响应式资源的生命周期容器
///
/// 替代 SignalOwner 的帧级 Arena 策略，用于保留模式。
/// 每个组件 mount 时创建一个 Scope，dispose 时递归清理所有资源。
///
/// 设计要点:
/// - 不使用 Arena，用普通 allocator 逐个分配（因为需要独立销毁）
/// - SignalOwner 保留为共享的依赖追踪上下文（current_effect、is_tracking、batch_ctx）
/// - dispose() 顺序：子 Scope -> cleanups -> Effect 从 Signal subscribers 中移除 -> 释放内存
const context_mod = @import("context.zig");

pub const ALIVE_SENTINEL: u32 = 0x5C0E_A11E;
pub const DEAD_SENTINEL: u32 = 0x5C0E_DEAD;

pub const Scope = struct {
    allocator: Allocator,
    parent: ?*Scope,
    children: std.ArrayList(*Scope),
    signals: std.ArrayList(*SignalBase),
    effects: std.ArrayList(*EffectBase),
    cleanups: std.ArrayList(CleanupEntry),
    resources: std.ArrayList(ResourceEntry),
    owner: *SignalOwner,
    disposed: bool = false,
    dispose_pending: bool = false,
    /// 生存哨兵，语义同 Node.alive_sentinel：
    /// disposeNow 末尾会 allocator.destroy(self)，二次 dispose 读到的 `disposed`
    /// 可能是 0xaa 覆写值（非 0 ⇒ true），double dispose 会退化成静默 early-return。
    alive_sentinel: u32 = ALIVE_SENTINEL,
    deferred_disposal: SignalOwner.DeferredDisposal = .{},

    /// Context API: 零分配 slot 数组（每个 scope 最多 8 个 context）
    context_entries: [context_mod.max_context_slots]context_mod.ContextSlot = [_]context_mod.ContextSlot{.{}} ** context_mod.max_context_slots,
    context_count: u5 = 0,

    pub const CleanupFn = *const fn (*anyopaque) void;

    pub const CleanupEntry = struct {
        func: CleanupFn,
        ctx: *anyopaque,
    };

    /// 通用资源条目：dispose 时由 destroyFn 释放
    pub const ResourceDestroyFn = *const fn (*anyopaque, Allocator) void;
    pub const ResourceEntry = struct {
        ptr: *anyopaque,
        destroyFn: ResourceDestroyFn,
    };

    /// 创建 Scope
    pub fn init(allocator: Allocator, parent: ?*Scope, owner: *SignalOwner) !*Scope {
        const scope = try allocator.create(Scope);
        // Scope 用 caller 的 allocator（非 owner arena），父注册失败不回收
        // 就是真泄漏（实测 416B/次）
        errdefer allocator.destroy(scope);
        scope.* = .{
            .allocator = allocator,
            .parent = parent,
            .children = .{},
            .signals = .{},
            .effects = .{},
            .cleanups = .{},
            .resources = .{},
            .owner = owner,
        };

        // 注册到父 Scope
        if (parent) |p| {
            try p.children.append(allocator, scope);
        }

        return scope;
    }

    /// 递归销毁 Scope 及其所有资源
    ///
    /// 顺序：
    /// 1. 递归销毁子 Scope
    /// 2. 执行清理回调（逆序）
    /// 3. 清理 Effect（从 Signal subscribers 中移除 + 释放内存）
    /// 4. 清理 Signal（释放 subscribers 列表 + 释放内存）
    /// 5. 释放自身
    pub fn dispose(self: *Scope) void {
        if (self.disposed) return;
        if (self.owner.reactive_callback_depth > 0) {
            if (self.dispose_pending) return;
            self.queueDeferredDispose();
            return;
        }
        self.disposeNow();
    }

    fn queueDeferredDispose(self: *Scope) void {
        // A queued ancestor already owns this subtree. Otherwise preserve
        // FIFO order; disposeNow cancels descendant entries before freeing.
        var parent = self.parent;
        while (parent) |scope| : (parent = scope.parent) {
            if (scope.disposed or scope.dispose_pending) return;
        }
        self.dispose_pending = true;
        self.owner.deferDisposal(&self.deferred_disposal, @ptrCast(self), &finishDeferredDispose);
    }

    fn finishDeferredDispose(ptr: *anyopaque) void {
        const scope: *Scope = @ptrCast(@alignCast(ptr));
        scope.disposeNow();
    }

    pub fn willBeDisposedAfterReactiveCallback(self: *Scope) bool {
        var current: ?*Scope = self;
        while (current) |scope| : (current = scope.parent) {
            if (scope.disposed or scope.dispose_pending) return true;
        }
        return false;
    }

    fn disposeNow(self: *Scope) void {
        // 生存哨兵（交叉 review 的元规则：哨兵检查必须支配同一指针上
        // 的所有其它字段访问）。放在 disposeNow 而不是 dispose：这里才是两条
        // 路径（同步 / deferred）共同的销毁入口，末尾会 allocator.destroy(self)。
        // 不查的话，二次进入读到的 `disposed` 可能是 0xaa 覆写值（非 0 ⇒ true），
        // double dispose 退化成静默 early-return，与 Node 那条同型。
        if (self.alive_sentinel != ALIVE_SENTINEL) {
            @panic("Scope.disposeNow: scope 已被释放（double dispose）或内存已损坏");
        }
        if (self.disposed) return;
        self.disposed = true;
        self.dispose_pending = false;
        self.deferred_disposal.cancel();
        // Detach before callbacks: a child cleanup can dispose its former
        // parent, so no later cleanup may dereference that parent pointer.
        if (self.parent) |parent| {
            if (!parent.disposed) {
                for (parent.children.items, 0..) |child, index| {
                    if (child == self) {
                        _ = parent.children.swapRemove(index);
                        break;
                    }
                }
            }
            self.parent = null;
        }

        // 1. 递归销毁子 Scope
        for (self.children.items) |child| {
            child.disposeNow();
        }
        self.children.deinit(self.allocator);

        // 2. 执行清理回调（逆序）
        var i = self.cleanups.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.cleanups.items[i];
            entry.func(entry.ctx);
        }
        self.cleanups.deinit(self.allocator);

        // 3. 清理 Effects：注销 graph node（自动断 source/observer 边）+ 释放
        // 单轨清理路径，graph.destroyNode 处理所有 cleanup；
        // 不再遍历 effect.dependencies / signal.subscribers 列表。
        for (self.effects.items) |effect| {
            if (effect.graph_node_raw != 0xFFFFFFFF) {
                const gid: @import("graph.zig").NodeId = @bitCast(effect.graph_node_raw);
                self.owner.graph.destroyNode(gid);
                effect.graph_node_raw = 0xFFFFFFFF;
            }
            effect.destroy(self.allocator);
        }
        self.effects.deinit(self.allocator);

        // 4. 清理 Signals：同上走 graph 单轨
        for (self.signals.items) |signal| {
            if (signal.graph_node_raw != 0xFFFFFFFF) {
                const gid: @import("graph.zig").NodeId = @bitCast(signal.graph_node_raw);
                self.owner.graph.destroyNode(gid);
                signal.graph_node_raw = 0xFFFFFFFF;
            }
            signal.destroy(self.allocator);
        }
        self.signals.deinit(self.allocator);

        // 5. 释放通用资源（逆序）
        // 与 cleanup 保持一致，避免早注册的资源先释放节点/上下文，
        // 让后注册且依赖这些对象的资源在 dispose 时访问悬垂指针。
        i = self.resources.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.resources.items[i];
            entry.destroyFn(entry.ptr, self.allocator);
        }
        self.resources.deinit(self.allocator);

        // 7. 释放自身
        // 投毒：释放后再被当活 scope 使用时，dispose 入口的哨兵会当场 panic。
        self.alive_sentinel = DEAD_SENTINEL;
        self.allocator.destroy(self);
    }

    /// 创建子 Scope
    pub fn childScope(self: *Scope) !*Scope {
        return Scope.init(self.allocator, self, self.owner);
    }

    /// 在此 Scope 中创建 Signal
    pub fn createSignal(self: *Scope, comptime T: type, initial: T) !*Signal(T) {
        const signal = try Signal(T).createInScope(self, initial);
        return signal;
    }

    /// 在此 Scope 中创建 Effect
    pub fn createEffect(
        self: *Scope,
        context: anytype,
        comptime effectFn: anytype,
    ) !void {
        const Context = @TypeOf(context);
        const EffectType = effect_mod.Effect(Context, effectFn);
        _ = try EffectType.createInScope(self, context);
    }

    /// 在此 Scope 中创建 Memo
    pub fn createMemo(
        self: *Scope,
        comptime T: type,
        context: anytype,
        comptime computeFn: anytype,
    ) !*Memo(T) {
        return memo_mod.createMemoInScope(self, T, context, computeFn);
    }

    /// 注册清理回调（Scope dispose 时执行）
    pub fn onCleanup(self: *Scope, comptime T: type, ctx: *T, comptime cleanupFn: fn (*T) void) !void {
        const wrapper = struct {
            fn invoke(ptr: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                cleanupFn(typed);
            }
        };
        try self.cleanups.append(self.allocator, .{
            .func = wrapper.invoke,
            .ctx = @ptrCast(ctx),
        });
    }

    /// 注册 Signal 到此 Scope
    pub fn registerSignal(self: *Scope, signal: *SignalBase) !void {
        try self.signals.append(self.allocator, signal);
    }

    /// 注册 Effect 到此 Scope
    pub fn registerEffect(self: *Scope, effect: *EffectBase) !void {
        try self.effects.append(self.allocator, effect);
    }

    /// 注册通用资源（dispose 时由 destroyFn(ptr, allocator) 释放）
    ///
    /// ⚠️ 登记本身可失败（resources 扩容）。失败时 ptr 仍归调用方，绝大多数调用方
    /// 是「create -> 初始化 -> registerResource」三步，第三步失败就把对象漏掉了
    /// （全仓扫出 65 处）。除非你在登记前后另有 errdefer，否则用 adoptResource。
    pub fn registerResource(self: *Scope, ptr: *anyopaque, destroyFn: ResourceDestroyFn) !void {
        try self.resources.append(self.allocator, .{ .ptr = ptr, .destroyFn = destroyFn });
    }

    /// 登记资源，**登记失败就当场用同一个 destroyFn 释放它**，然后把错误抛回去。
    /// 语义：调用成功 ⇒ 资源归 scope；调用失败 ⇒ 资源已被释放，调用方不得再碰 ptr。
    /// 前提：调用时 ptr 指向的对象已经初始化到 destroyFn 能安全处理的程度
    /// （destroyFn 会读它的字段去 free），别在 `state.* = .{…}` 之前登记。
    pub fn adoptResource(self: *Scope, ptr: *anyopaque, destroyFn: ResourceDestroyFn) !void {
        self.resources.append(self.allocator, .{ .ptr = ptr, .destroyFn = destroyFn }) catch |err| {
            destroyFn(ptr, self.allocator);
            return err;
        };
    }

    /// 在当前 scope 注册一个 context 值
    pub fn setContext(self: *Scope, type_id: usize, ptr: *anyopaque) !void {
        // 查找已有 slot
        for (self.context_entries[0..self.context_count]) |*slot| {
            if (slot.type_id == type_id) {
                slot.ptr = ptr;
                return;
            }
        }
        // 分配新 slot
        if (self.context_count < context_mod.max_context_slots) {
            self.context_entries[self.context_count] = .{ .type_id = type_id, .ptr = ptr };
            self.context_count += 1;
            return;
        } else {
            return error.ContextsFull;
        }
    }

    /// 沿 parent 链向上查找 context 值
    pub fn getContext(self: *Scope, type_id: usize) ?*anyopaque {
        // 先查自身
        for (self.context_entries[0..self.context_count]) |slot| {
            if (slot.type_id == type_id) return slot.ptr;
        }
        // 递归父 scope
        if (self.parent) |p| {
            return p.getContext(type_id);
        }
        return null;
    }
};

// ===== 测试 =====

test "Scope: init/dispose" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    scope.dispose();
}

test "Scope: reactive callbacks defer disposal until their facade returns" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    // Initial effect execution may dispose its own scope. Creation reports the
    // disposal instead of returning a dangling Effect pointer.
    const initial_scope = try Scope.init(allocator, null, owner);
    try std.testing.expectError(error.ScopeDisposed, initial_scope.createEffect(.{ .scope = initial_scope }, struct {
        fn run(ctx: anytype) void {
            ctx.scope.dispose();
        }
    }.run));

    // The same operation during a later signal-driven run must let the effect
    // and graph unwind before freeing the effect, signal, and scope.
    const effect_scope = try Scope.init(allocator, null, owner);
    const signal = try effect_scope.createSignal(u32, 0);
    var dispose_on_run = false;
    var runs: usize = 0;
    try effect_scope.createEffect(.{
        .scope = effect_scope,
        .signal = signal,
        .dispose_on_run = &dispose_on_run,
        .runs = &runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.signal.get();
            ctx.runs.* += 1;
            if (ctx.dispose_on_run.*) ctx.scope.dispose();
        }
    }.run);
    dispose_on_run = true;
    signal.set(1);
    try std.testing.expectEqual(@as(usize, 2), runs);

    // Memo.get still needs to copy the computed cache after graph recompute;
    // disposal therefore waits until the complete get() facade exits.
    const memo_scope = try Scope.init(allocator, null, owner);
    const memo = try memo_scope.createMemo(u32, .{ .scope = memo_scope }, struct {
        fn compute(ctx: anytype) u32 {
            ctx.scope.dispose();
            return 42;
        }
    }.compute);
    try std.testing.expectEqual(@as(u32, 42), memo.get());
}

test "Scope: nested scopes dispose correctly" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const parent_scope = try Scope.init(allocator, null, owner);
    _ = try parent_scope.childScope();
    _ = try parent_scope.childScope();

    // 销毁父 Scope 应该递归销毁子 Scope
    parent_scope.dispose();
}

test "Scope: createSignal" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const count = try scope.createSignal(i32, 42);
    try std.testing.expectEqual(@as(i32, 42), count.get());

    count.set(100);
    try std.testing.expectEqual(@as(i32, 100), count.get());
}

test "Scope: createEffect with auto-tracking" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const count = try scope.createSignal(i32, 0);
    var effect_run_count: i32 = 0;

    try scope.createEffect(.{
        .count = count,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.counter.* += 1;
        }
    }.run);

    // Effect 创建时执行一次
    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    // Signal 变化触发 Effect
    count.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count);

    count.set(2);
    try std.testing.expectEqual(@as(i32, 3), effect_run_count);
}

test "Scope: dispose stops effects" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    // 在 owner 的 Arena 上创建一个 Signal（跨 Scope 存活）
    const count = try Signal(i32).create(owner, 0);

    var effect_run_count: i32 = 0;

    {
        const scope = try Scope.init(allocator, null, owner);

        try scope.createEffect(.{
            .count = count,
            .counter = &effect_run_count,
        }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.count.get();
                ctx.counter.* += 1;
            }
        }.run);

        try std.testing.expectEqual(@as(i32, 1), effect_run_count);

        count.set(1);
        try std.testing.expectEqual(@as(i32, 2), effect_run_count);

        // 销毁 Scope -> Effect 被清理
        scope.dispose();
    }

    // Scope 销毁后，Signal 变化不再触发 Effect
    count.set(2);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count);
}

test "Scope: disposing one sibling scope keeps the other active" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    const scope_a = try Scope.init(allocator, null, owner);
    const scope_b = try Scope.init(allocator, null, owner);
    defer scope_b.dispose();

    var a_runs: i32 = 0;
    var b_runs: i32 = 0;

    try scope_a.createEffect(.{
        .count = count,
        .runs = &a_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try scope_b.createEffect(.{
        .count = count,
        .runs = &b_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);

    count.set(1);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);

    // 只销毁 scope_a，不应影响 scope_b
    scope_a.dispose();

    count.set(2);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 3), b_runs);
}

test "Scope: disposed sibling is not queued during owner batch" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);
    const scope_a = try Scope.init(allocator, null, owner);
    const scope_b = try Scope.init(allocator, null, owner);
    defer scope_b.dispose();

    var a_runs: i32 = 0;
    var b_runs: i32 = 0;

    try scope_a.createEffect(.{
        .count = count,
        .runs = &a_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try scope_b.createEffect(.{
        .count = count,
        .runs = &b_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);

    scope_a.dispose();

    // batch 内两次 set：scope_b 的 effect 只应排队并运行一次，scope_a 不应被误排队
    try owner.batch(struct {
        fn update(ctx: anytype) void {
            ctx.count.set(1);
            ctx.count.set(2);
        }
    }.update, .{ .count = count });

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
}

test "Scope: dispose after batch+untrack+nested chain stops all effects" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const trigger = try Signal(bool).create(owner, false);
    const source = try Signal(i32).create(owner, 0);
    const mirror = try Signal(i32).create(owner, 0);

    var a_runs: i32 = 0;
    var b_runs: i32 = 0;
    var c_runs: i32 = 0;
    var leaf_value: i32 = -1;

    const scope = try Scope.init(allocator, null, owner);

    // B: source -> mirror
    try scope.createEffect(.{
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

    // C: mirror -> leaf
    try scope.createEffect(.{
        .mirror = mirror,
        .runs = &c_runs,
        .leaf = &leaf_value,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.runs.* += 1;
            ctx.leaf.* = ctx.mirror.get();
        }
    }.run);

    // A: trigger true 时，在 untrack 内 batch 更新 source
    try scope.createEffect(.{
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
                            inner.source.set(2);
                        }
                    }.update, .{ .source = args.source }) catch unreachable;
                }
            }.op, .{
                .owner = ctx.owner,
                .source = ctx.source,
            });
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);
    try std.testing.expectEqual(@as(i32, 1), c_runs);
    try std.testing.expectEqual(@as(i32, 0), leaf_value);

    trigger.set(true);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
    try std.testing.expectEqual(@as(i32, 2), c_runs);
    try std.testing.expectEqual(@as(i32, 4), leaf_value);

    // dispose 后，这三个 effect 都不应再被 source/mirror/trigger 变化触发
    scope.dispose();

    source.set(3);
    mirror.set(7);
    trigger.set(false);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
    try std.testing.expectEqual(@as(i32, 2), c_runs);
    try std.testing.expectEqual(@as(i32, 4), leaf_value);
}

test "Scope: cleanup callbacks" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    var cleanup_count: i32 = 0;

    const scope = try Scope.init(allocator, null, owner);

    try scope.onCleanup(i32, &cleanup_count, struct {
        fn cleanup(ptr: *i32) void {
            ptr.* += 1;
        }
    }.cleanup);

    try std.testing.expectEqual(@as(i32, 0), cleanup_count);

    scope.dispose();

    try std.testing.expectEqual(@as(i32, 1), cleanup_count);
}

test "Scope: child scope disposed with parent" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    var parent_cleanup: i32 = 0;
    var child_cleanup: i32 = 0;

    const parent_scope = try Scope.init(allocator, null, owner);
    const child_scope = try parent_scope.childScope();

    try parent_scope.onCleanup(i32, &parent_cleanup, struct {
        fn cleanup(ptr: *i32) void {
            ptr.* += 1;
        }
    }.cleanup);

    try child_scope.onCleanup(i32, &child_cleanup, struct {
        fn cleanup(ptr: *i32) void {
            ptr.* += 1;
        }
    }.cleanup);

    // 销毁父 Scope
    parent_scope.dispose();

    // 两个 cleanup 都应该执行
    try std.testing.expectEqual(@as(i32, 1), parent_cleanup);
    try std.testing.expectEqual(@as(i32, 1), child_cleanup);
}

test "Scope: resources dispose in reverse registration order" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);

    const Marker = struct {
        freed: bool = false,
        order: [2]u8 = undefined,
        len: usize = 0,
    };
    var marker = Marker{};

    try scope.registerResource(@ptrCast(&marker), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            _ = alloc;
            const m: *Marker = @ptrCast(@alignCast(ptr));
            m.order[m.len] = 'a';
            m.len += 1;
            m.freed = true;
        }
    }.destroy);

    try scope.registerResource(@ptrCast(&marker), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            _ = alloc;
            const m: *Marker = @ptrCast(@alignCast(ptr));
            std.debug.assert(!m.freed);
            m.order[m.len] = 'b';
            m.len += 1;
        }
    }.destroy);

    scope.dispose();

    try std.testing.expect(marker.freed);
    try std.testing.expectEqual(@as(usize, 2), marker.len);
    try std.testing.expectEqualStrings("ba", marker.order[0..marker.len]);
}

test "Scope: parent dispose handles cross-scope signal dependencies" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const parent_scope = try Scope.init(allocator, null, owner);
    const producer_scope = try parent_scope.childScope();
    const consumer_scope = try parent_scope.childScope();

    const shared = try producer_scope.createSignal(i32, 1);
    var runs: i32 = 0;

    try consumer_scope.createEffect(.{
        .shared = shared,
        .runs = &runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.shared.get();
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), runs);

    // 之前这里会在 consumer_scope.dispose() 中访问 producer_scope 已释放的 Signal。
    parent_scope.dispose();
}

test "allocation campaign: Scope/Memo/Effect 构造路径 OOM 不泄漏不半注册" {
    // 逐 fail-index 扫描三条构造路径。testing.allocator 在测试尾自动查泄漏，
    // FailingAllocator 首中后永久失败，所以每轮独立建整套 owner/scope。
    // 锁的性质：构造失败时 (a) caller-allocator 内存全部归还（Scope 路径曾
    // 实测漏 416B）；(b) 注册表不留半注册态（graph_node_raw 仍 0xFFFFFFFF
    // 的 EffectBase）；(c) 已建的 graph node 被回退。
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing.allocator();

        var owner = SignalOwner.init(alloc) catch continue;
        defer owner.deinit();

        // pushTracking 在 OOM 时按治理策略 @panic（tracking 栈失步不可恢复），
        // 不属于本测试要锁的性质，预热容量让它在本测试内永不分配
        owner.graph.tracking_stack.ensureTotalCapacity(alloc, 8) catch continue;

        const scope = Scope.init(alloc, null, owner) catch continue;
        defer scope.dispose();

        // 子 scope（覆盖父注册失败分支）
        _ = scope.childScope() catch {};

        // effect（覆盖 registerEffect 后 createNodeRaw 失败分支）
        var effect_runs: u32 = 0;
        scope.createEffect(.{ .runs = &effect_runs }, struct {
            fn run(ctx: anytype) void {
                ctx.runs.* += 1;
            }
        }.run) catch {};

        // memo（覆盖两次分配 + graph 注册 + registerResource 各失败点）
        const m = scope.createMemo(i32, .{}, struct {
            fn compute(_: anytype) i32 {
                return 7;
            }
        }.compute) catch continue;
        try std.testing.expectEqual(@as(i32, 7), m.get());

        // 半注册态检查：走到这里的 effect 要么完整（graph node 有效），
        // 要么根本不在注册表里
        for (scope.effects.items) |eb| {
            try std.testing.expect(eb.graph_node_raw != 0xFFFFFFFF);
        }
    }
}

test "Scope: adoptResource 登记失败时当场跑 destroyFn，不留孤儿也不双重释放" {
    const Probe = struct {
        var destroyed: usize = 0;
        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            destroyed += 1;
            allocator.destroy(@as(*u64, @ptrCast(@alignCast(ptr))));
        }
    };
    Probe.destroyed = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const owner = try SignalOwner.init(a);
    defer owner.deinit();
    const scope = try Scope.init(a, null, owner);
    defer scope.dispose();

    // 第一次：resources 首次扩容那一步失败 -> 对象必须被 destroyFn 收掉，错误抛回。
    const first = try a.create(u64);
    first.* = 1;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, scope.adoptResource(@ptrCast(first), Probe.destroy));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 1), Probe.destroyed);
    try std.testing.expectEqual(@as(usize, 0), scope.resources.items.len);

    // 第二次：成功 -> 归 scope，dispose 时恰好释放一次。
    const second = try a.create(u64);
    second.* = 2;
    try scope.adoptResource(@ptrCast(second), Probe.destroy);
    try std.testing.expectEqual(@as(usize, 1), scope.resources.items.len);
    scope.dispose();
    try std.testing.expectEqual(@as(usize, 2), Probe.destroyed);
}
