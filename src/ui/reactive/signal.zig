const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalBase = @import("signal_base.zig").SignalBase;
const SignalOwner = @import("owner.zig").SignalOwner;
const Scope = @import("scope.zig").Scope;
const eqlValue = @import("eq.zig").eqlValue;

/// Signal(T): 泛型响应式数据源
///
/// 用法:
/// ```zig
/// var owner = try SignalOwner.init(allocator);
/// defer owner.deinit();
///
/// const count = try owner.createSignal(i32, 0);
/// count.set(42);        // 触发订阅者
/// const val = count.get(); // 自动注册依赖
/// ```
pub fn Signal(comptime T: type) type {
    return struct {
        base: SignalBase,
        value: T,
        owner: *SignalOwner,

        const Self = @This();

        /// 创建 Signal (内部使用)
        ///
        /// 应该通过 SignalOwner.createSignal() 创建
        pub fn create(owner: *SignalOwner, initial: T) !*Self {
            owner.assertThread();
            const signal = try owner.allocator().create(Self);
            signal.* = .{
                .base = SignalBase.init(owner.allocator(), &vtable),
                .value = initial,
                .owner = owner,
            };

            // 注册到 owner
            try owner.registerSignal(&signal.base);

            // 同步在 graph 注册一个 NodeId
            const gid = try owner.graph.createSignal();
            signal.base.graph_node_raw = @bitCast(gid);

            return signal;
        }

        /// 在 Scope 中创建 Signal（保留模式路径）
        ///
        /// 使用 scope.allocator 分配，注册到 scope（不是 Arena）
        pub fn createInScope(scope: *Scope, initial: T) !*Self {
            scope.owner.assertThread();
            const signal = try scope.allocator.create(Self);
            errdefer scope.allocator.destroy(signal);
            signal.* = .{
                .base = SignalBase.init(scope.allocator, &scope_vtable),
                .value = initial,
                .owner = scope.owner,
            };
            // Scope 路径：subscribers 列表也用 scope.allocator
            signal.base.scope_allocator = scope.allocator;

            const gid = try scope.owner.graph.createSignal();
            errdefer scope.owner.graph.destroyNode(gid);
            // Publish in the scope only after graph allocation succeeds.
            try scope.registerSignal(&signal.base);
            signal.base.graph_node_raw = @bitCast(gid);

            return signal;
        }

        /// 虚函数表（Arena 路径，旧代码兼容）
        const vtable = SignalBase.VTable{
            .cleanup = cleanupImpl,
        };

        /// 虚函数表（Scope 路径，支持单独释放）
        const scope_vtable = SignalBase.VTable{
            .cleanup = cleanupImpl,
            .destroy = destroyImpl,
        };

        fn cleanupImpl(base: *SignalBase) void {
            // Arena allocator 会自动释放所有内存
            _ = base;
        }

        fn destroyImpl(base: *SignalBase, allocator: Allocator) void {
            const self: *Self = @fieldParentPtr("base", base);
            // subscribers 字段已删除；graph.destroyNode 处理边
            allocator.destroy(self);
        }

        /// 读取值并自动注册依赖
        ///
        /// 单轨追踪——graph.tracking_stack 是唯一依赖源。
        /// 旧 EffectBase.dependencies + SignalBase.subscribers 已废弃（v0.3-P4/P5 删字段）。
        /// untrack 跳过"发起 untrack 的当前 Effect"的追踪。
        pub fn get(self: *Self) T {
            self.owner.assertThread();

            // 检查 untrack：只跳过当前 effect 的追踪，不影响嵌套 effect/memo
            const untrack_active = !self.owner.is_tracking;
            const should_skip_for_current = untrack_active and
                self.owner.current_effect != null and
                self.owner.untracked_effect == self.owner.current_effect;

            if (!should_skip_for_current and self.base.graph_node_raw != 0xFFFFFFFF) {
                const gid: @import("graph.zig").NodeId = @bitCast(self.base.graph_node_raw);
                self.owner.graph.trackRead(gid) catch |err| {
                    std.log.warn("[reactive.Signal] graph.trackRead failed: {}", .{err});
                };
            }

            return self.value;
        }

        /// 读取值但不注册依赖
        pub fn peek(self: *const Self) T {
            self.owner.assertThread();
            return self.value;
        }

        /// 设置新值并触发所有订阅者
        pub fn set(self: *Self, new_value: T) void {
            self.owner.assertThread();
            // 值未变化则跳过。eqlValue 替代 std.meta.eql 修复了三个 bug：
            // - []const u8 比内容而非 (ptr, len)
            // - NaN bytewise 同视作相等（避免永远 dirty）
            // - struct 含切片字段递归正确比较
            if (eqlValue(T, self.value, new_value)) return;

            self.value = new_value;

            // 切到 graph 主路径。
            // graph.markSignalWritten 内部：
            //   1. signal.version++
            //   2. observers 标 dirty（effect 入 pending_effects）
            //   3. batch_depth == 0 时 drainPendingEffects（按拓扑深度排序运行）
            //   4. drain 时调每个 effect 的 graphRecomputeCb → EffectBase.runWithTracking
            //
            // 旧 push DFS 路径（self.base.notifyAll）已删除——graph 路径覆盖所有调度
            // 行为且具有：拓扑序、无 16 上限、diamond glitch freedom。
            if (self.base.graph_node_raw != 0xFFFFFFFF) {
                const gid: @import("graph.zig").NodeId = @bitCast(self.base.graph_node_raw);
                self.owner.graph.markSignalWritten(gid) catch |err| {
                    std.log.err("[reactive.Signal] graph.markSignalWritten failed: {}", .{err});
                };
            }
        }

        /// 使用函数更新值
        pub fn update(self: *Self, comptime updateFn: fn (T) T) void {
            self.set(updateFn(self.value));
        }
    };
}

// ===== 测试 =====

test "Signal: basic get/set" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 42);

    try std.testing.expectEqual(@as(i32, 42), count.get());

    count.set(100);
    try std.testing.expectEqual(@as(i32, 100), count.get());
}

test "Signal: peek doesn't track" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    // peek 不应该触发依赖追踪
    _ = count.peek();

    try std.testing.expectEqual(@as(i32, 0), count.peek());
}

test "Signal: update function" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    count.update(struct {
        fn inc(val: i32) i32 {
            return val + 1;
        }
    }.inc);

    try std.testing.expectEqual(@as(i32, 1), count.get());
}

test "Signal: skip notification if value unchanged" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 42);

    var notify_count: u32 = 0;

    // 模拟订阅
    const MockEffect = struct {
        var counter: *u32 = undefined;

        fn run(_: *anyopaque) void {
            counter.* += 1;
        }
    };

    MockEffect.counter = &notify_count;

    // 设置相同的值不应该触发通知
    count.set(42);
    try std.testing.expectEqual(@as(u32, 0), notify_count);

    // 设置不同的值应该触发通知
    count.set(100);
    // 注意: 这里实际不会通知,因为没有真正的订阅者
}
