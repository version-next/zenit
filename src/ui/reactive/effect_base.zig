const std = @import("std");

/// EffectBase: 类型擦除的 Effect 基类
///
/// 为什么需要基类?
/// - SignalOwner 需要统一管理所有 Effect
/// - 通过虚函数表实现多态
///
/// 单轨追踪——依赖关系全部走 ReactiveGraph（src/ui/reactive/graph.zig）。
/// 旧 dependencies / addDependency / clearDependencies / removeDependencyPointer
/// 全部删除——graph.sources 是唯一依赖源。
pub const EffectBase = struct {
    /// 虚函数表
    vtable: *const VTable,

    /// 用于 effect 自身分配（Scope 路径下为 scope.allocator；Arena 路径用 fallback）
    scope_allocator: ?std.mem.Allocator = null,

    /// Effect 是否在待执行队列中 (避免重复添加)
    is_queued: bool = false,
    /// Effect 是否正在运行 (用于防止递归执行)
    is_running: bool = false,
    /// 运行中被再次触发时,标记需要重跑
    needs_rerun: bool = false,

    /// 在 ReactiveGraph 中的对应 NodeId raw（0xFFFFFFFF = 未注册）。
    /// Effect create 时注册；run 通过 graph 拓扑序调度走过来。
    graph_node_raw: u32 = 0xFFFFFFFF,

    pub const VTable = struct {
        /// 运行 Effect
        run: *const fn (*EffectBase) void,

        /// 清理 Effect
        cleanup: *const fn (*EffectBase) void,

        /// 释放具体类型内存（Scope dispose 时使用）
        /// 为 null 表示由 Arena 管理（旧路径）
        destroy: ?*const fn (*EffectBase, std.mem.Allocator) void = null,
    };

    /// 初始化 EffectBase
    pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) EffectBase {
        _ = allocator;
        return .{
            .vtable = vtable,
        };
    }

    /// 运行 Effect
    pub fn run(self: *EffectBase) void {
        self.vtable.run(self);
    }

    /// 清理 Effect
    pub fn cleanup(self: *EffectBase) void {
        self.vtable.cleanup(self);
    }

    /// 释放具体类型内存（由 Scope dispose 调用）
    pub fn destroy(self: *EffectBase, allocator: std.mem.Allocator) void {
        if (self.vtable.destroy) |destroyFn| {
            destroyFn(self, allocator);
        }
    }

    /// 运行 Effect 并重新收集依赖,带重入保护
    ///
    /// runWithTrackingFast —— 跳过 graph.clearSources/pushTracking 设置。
    /// 仅由 graph.recomputeNode → graphRecomputeCb 路径调用——graph 已经做了
    /// 这两步。省去 1k fanout 下每 effect ~30 ns 的重复 push/pop。
    pub fn runWithTrackingFast(self: *EffectBase, owner: anytype) void {
        if (self.is_running) {
            self.needs_rerun = true;
            return;
        }

        const has_deferred_disposal = comptime @hasDecl(@TypeOf(owner.*), "beginReactiveCallback");
        if (has_deferred_disposal) owner.beginReactiveCallback();
        defer if (has_deferred_disposal) owner.endReactiveCallback();

        self.is_running = true;
        defer self.is_running = false;

        var rerun_count: u32 = 0;
        const max_reruns: u32 = 128;

        while (true) {
            self.needs_rerun = false;

            const prev_effect = owner.current_effect;
            owner.current_effect = self;
            defer owner.current_effect = prev_effect;

            self.run();

            if (!self.needs_rerun) break;

            rerun_count += 1;
            if (rerun_count >= max_reruns) {
                if (std.debug.runtime_safety) {
                    std.debug.panic("Effect re-run limit exceeded ({d})", .{max_reruns});
                } else {
                    std.log.err("Effect re-run limit exceeded ({d}); skipping further runs", .{max_reruns});
                }
                break;
            }
        }
    }

    /// 单轨追踪——push/pop graph.tracking_stack + clearSources。
    /// 用于 (a) 创建时初次 run（effect.zig:50/75）和 (b) batch.flush 路径（batch.zig:93）。
    /// graph.recomputeNode → graphRecomputeCb 路径请用 runWithTrackingFast 跳过重复设置。
    pub fn runWithTracking(self: *EffectBase, owner: anytype, allocator: std.mem.Allocator) void {
        if (self.is_running) {
            self.needs_rerun = true;
            return;
        }

        const has_deferred_disposal = comptime @hasDecl(@TypeOf(owner.*), "beginReactiveCallback");
        if (has_deferred_disposal) owner.beginReactiveCallback();
        defer if (has_deferred_disposal) owner.endReactiveCallback();

        self.is_running = true;
        defer self.is_running = false;

        _ = allocator;
        var rerun_count: u32 = 0;
        const max_reruns: u32 = 128;

        while (true) {
            self.needs_rerun = false;

            // 设置当前 Effect (兼容 untrack 检测——signal.get 还需要 owner.current_effect)
            const prev_effect = owner.current_effect;
            owner.current_effect = self;
            defer owner.current_effect = prev_effect;

            // 单轨追踪：push graph node，让 signal.get → graph.trackRead 加边
            const has_graph = comptime @hasField(@TypeOf(owner.*), "graph");
            const has_node = has_graph and self.graph_node_raw != 0xFFFFFFFF;
            if (has_node) {
                const nid: @import("graph.zig").NodeId = @bitCast(self.graph_node_raw);
                if (owner.graph.getNode(nid)) |node| node.tracking_failed = false;
                owner.graph.pushTracking(nid) catch {
                    if (owner.graph.getNode(nid)) |node| {
                        node.tracking_failed = true;
                        node.state = .dirty;
                    }
                    return;
                };
                owner.graph.clearSourcesPub(nid);
            }
            defer if (has_node) owner.graph.popTracking();

            // 执行 Effect
            self.run();

            if (!self.needs_rerun) break;

            rerun_count += 1;
            if (rerun_count >= max_reruns) {
                if (std.debug.runtime_safety) {
                    std.debug.panic("Effect re-run limit exceeded ({d})", .{max_reruns});
                } else {
                    std.log.err("Effect re-run limit exceeded ({d}); skipping further runs", .{max_reruns});
                }
                break;
            }
        }
    }
};
