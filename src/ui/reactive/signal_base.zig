const std = @import("std");

/// SignalBase: 类型擦除的 Signal 基类
///
/// 为什么需要基类?
/// - SignalOwner 需要统一管理所有类型的 Signal
/// - 使用基类可以将 Signal(i32), Signal([]const u8) 等统一存储
/// - 通过虚函数表实现多态
///
/// 单轨追踪，subscribers 列表全部走 ReactiveGraph
/// （src/ui/reactive/graph.zig）。旧 subscribers / addSubscriber / removeSubscriber /
/// notifyAll / VTable.notify 全部删除，graph.observers 是唯一 observer 源；
/// signal.set 走 graph.markSignalWritten 而非 notifyAll。
pub const SignalBase = struct {
    /// 虚函数表
    vtable: *const VTable,

    /// 用于 signal 自身分配（Scope 路径下为 scope.allocator；Arena 路径用 fallback）
    scope_allocator: ?std.mem.Allocator = null,

    /// 在 ReactiveGraph 中的对应 NodeId（u32，0xFFFFFFFF = 未注册）。
    /// Signal create 时同步注册到 graph；set 路径走 graph.markSignalWritten
    /// 实现拓扑序 + 版本戳传播。
    graph_node_raw: u32 = 0xFFFFFFFF,

    pub const VTable = struct {
        /// 清理函数
        cleanup: *const fn (*SignalBase) void,

        /// 释放具体类型内存（Scope dispose 时使用）
        /// 为 null 表示由 Arena 管理（旧路径）
        destroy: ?*const fn (*SignalBase, std.mem.Allocator) void = null,
    };

    /// 初始化 SignalBase
    pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) SignalBase {
        _ = allocator;
        return .{
            .vtable = vtable,
        };
    }

    /// 清理 Signal
    pub fn cleanup(self: *SignalBase) void {
        self.vtable.cleanup(self);
    }

    /// 释放具体类型内存（由 Scope dispose 调用）
    pub fn destroy(self: *SignalBase, allocator: std.mem.Allocator) void {
        if (self.vtable.destroy) |destroyFn| {
            destroyFn(self, allocator);
        }
    }
};
