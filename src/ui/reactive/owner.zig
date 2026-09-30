const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalBase = @import("signal_base.zig").SignalBase;
const EffectBase = @import("effect_base.zig").EffectBase;
const BatchContext = @import("batch.zig").BatchContext;
const graph_mod = @import("graph.zig");
pub const ReactiveGraph = graph_mod.ReactiveGraph;

/// SignalOwner: 响应式系统的生命周期管理器
///
/// 核心职责:
/// - 管理组件内所有 Signal/Effect 的生命周期
/// - 使用 Arena allocator 一次性回收所有内存
/// - 组件销毁时自动清理所有依赖关系
///
/// 设计理念:
/// - 每个组件拥有一个 Owner
/// - Owner 管理该组件内所有 Signal/Effect
/// - 组件销毁时,Owner.deinit() 自动清理一切
pub const SignalOwner = struct {
    pub const DeferredDisposal = @import("deferred_disposal.zig").Entry;

    /// Arena allocator: 所有 Signal/Effect 都从这里分配
    arena: std.heap.ArenaAllocator,

    /// 父 allocator (用于 Arena 自身)
    parent_allocator: Allocator,

    /// 创建时的线程 ID (用于线程亲和性断言)
    thread_id: std.Thread.Id,

    /// 所有 Signal 列表 (用于清理)
    signals: std.ArrayList(*SignalBase),

    /// 所有 Effect 列表 (用于清理和执行)
    effects: std.ArrayList(*EffectBase),

    /// 批量更新上下文
    batch_ctx: BatchContext,

    /// 是否启用依赖追踪
    is_tracking: bool = true,

    /// 当前正在执行的 Effect (用于依赖追踪)
    current_effect: ?*EffectBase = null,

    /// 调用 untrack 时需要临时禁用追踪的 Effect。
    /// 仅对该 Effect 生效，避免影响 untrack 内触发的其他 Effect。
    untracked_effect: ?*EffectBase = null,

    // graph 主路径切换。
    // 每个 SignalOwner 持有一个 ReactiveGraph 作为新主路径调度器。
    // Signal/Memo/Effect facade 在 create 时同时在 graph 里注册 NodeId；
    // set/get/recompute 走 graph（拓扑序 + 版本戳 + lazy memo）。
    // 旧 push DFS 路径（signal.notifyImpl 直接 effect.runWithTracking）保留作
    // fallback；当 use_graph_path = true 时全部走 graph。
    graph: ReactiveGraph,
    use_graph_path: bool = true,

    /// Scope disposal requested from inside an effect/memo callback must wait
    /// until the outer reactive facade has stopped touching its allocation.
    reactive_callback_depth: u32 = 0,
    deferred_disposals: @import("deferred_disposal.zig").Queue = .{},
    draining_disposals: bool = false,

    /// 创建 SignalOwner
    ///
    /// parent_alloc: 父 allocator,用于创建 Arena
    pub fn init(parent_alloc: Allocator) !*SignalOwner {
        const owner = try parent_alloc.create(SignalOwner);
        owner.* = .{
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
            .parent_allocator = parent_alloc,
            .thread_id = std.Thread.getCurrentId(),
            .signals = .{},
            .effects = .{},
            .batch_ctx = BatchContext.init(parent_alloc),
            .graph = ReactiveGraph.init(parent_alloc),
        };
        return owner;
    }

    /// 销毁 SignalOwner 并清理所有资源
    ///
    /// 单轨清理路径——graph.deinit 处理所有 reactive node 的 source /
    /// observer 边；不再遍历 SignalBase.subscribers / EffectBase.dependencies
    /// 列表（这两个字段在 v0.3-P4/P5 删除）。
    ///
    /// 执行顺序:
    /// 1. graph.deinit 关闭所有 node + 释放图结构
    /// 2. 释放 self.signals / self.effects ArrayLists 自身
    /// 3. batch_ctx.deinit
    /// 4. 一次性回收 Arena 释放所有 Signal/Effect 实例内存
    pub fn deinit(self: *SignalOwner) void {
        self.assertThread();
        std.debug.assert(self.reactive_callback_depth == 0);
        _ = self.drainDeferredDisposals();
        // 单轨清理——graph.deinit 处理所有 reactive node。
        // EffectBase.dependencies / SignalBase.subscribers 字段已删除。
        // 注意 SignalBase.subscribers 仍存在于 P1.5 完成前，此处不调用以保持单轨。

        // 释放 ArrayLists (用 parent_allocator 分配)
        self.effects.deinit(self.parent_allocator);
        self.signals.deinit(self.parent_allocator);

        // 4. 清理批量上下文
        self.batch_ctx.deinit();

        // 5. 清理 graph（v0.2-P1）
        self.graph.deinit();

        // 6. 一次性回收所有内存 (Arena 会释放所有 Signal/Effect)
        self.arena.deinit();

        // 7. 释放 owner 自身
        self.parent_allocator.destroy(self);
    }

    // 注意：这里刻意没有 reset()。曾存在一个"每帧重建 UI 树"用途的
    // reset（Arena 整代回收 + 各字段复位）——那是 immediate-mode 的遗留，
    // zenit 是保留模式框架，全仓从无调用方，2026-08-16 决策删除。
    // owner 的生命周期只有 init/deinit 两点。

    /// 获取 Arena allocator (供 Signal/Effect 使用)
    pub fn allocator(self: *SignalOwner) Allocator {
        return self.arena.allocator();
    }

    /// 注册 Signal (供 Signal.init 内部调用)
    pub fn registerSignal(self: *SignalOwner, signal: *SignalBase) !void {
        self.assertThread();
        try self.signals.append(self.parent_allocator, signal);
    }

    /// 注册 Effect (供 createEffect 内部调用)
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
        return if (self.reactive_callback_depth == 0) self.drainDeferredDisposals() else false;
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

    /// 批量更新
    ///
    /// 用法:
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
        self.assertThread();
        try self.batch_ctx.begin();
        // 同步推 graph batch_depth；graph.markSignalWritten 在 batch_depth>0
        // 时只 propagate 不 drain，等 endBatch 时拓扑序 drain。
        self.graph.beginBatch();
        defer {
            // 顺序：先 graph 退批，触发拓扑序 drain；再 batch_ctx.end（旧路径已无效但保留 nesting 计数）。
            self.graph.endBatch() catch |err| {
                std.log.err("[reactive.SignalOwner] graph.endBatch failed: {}", .{err});
            };
            self.batch_ctx.end(self);
        }

        batchFn(args);
    }

    /// 取消依赖追踪
    ///
    /// 用法:
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
        const prev_tracking = self.is_tracking;
        const prev_untracked_effect = self.untracked_effect;
        self.is_tracking = false;
        self.untracked_effect = self.current_effect;
        defer {
            self.untracked_effect = prev_untracked_effect;
            self.is_tracking = prev_tracking;
        }

        return untrackedFn(args);
    }

    /// 线程亲和性断言 (仅在开启 runtime_safety 时生效)
    pub fn assertThread(self: *SignalOwner) void {
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

// ===== 测试 =====

test "SignalOwner: init/deinit" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    try std.testing.expect(owner.signals.items.len == 0);
    try std.testing.expect(owner.effects.items.len == 0);
}

test "SignalOwner: allocator" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    // 从 Arena 分配一些内存
    const slice = try owner.allocator().alloc(u8, 100);
    @memset(slice, 42);

    try std.testing.expectEqual(@as(u8, 42), slice[0]);
    try std.testing.expectEqual(@as(u8, 42), slice[99]);

    // 不需要手动释放,deinit 会一次性回收
}

test "SignalOwner: memory isolation" {
    var owner1 = try SignalOwner.init(std.testing.allocator);
    defer owner1.deinit();

    var owner2 = try SignalOwner.init(std.testing.allocator);
    defer owner2.deinit();

    // 两个 owner 的内存是隔离的
    const data1 = try owner1.allocator().create(i32);
    const data2 = try owner2.allocator().create(i32);

    data1.* = 100;
    data2.* = 200;

    try std.testing.expectEqual(@as(i32, 100), data1.*);
    try std.testing.expectEqual(@as(i32, 200), data2.*);
}
