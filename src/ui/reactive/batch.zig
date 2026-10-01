const std = @import("std");
const EffectBase = @import("effect_base.zig").EffectBase;

/// BatchContext: 批量更新上下文
///
/// 调度逻辑全部委托到 ReactiveGraph（owner.graph）。
/// 此结构保留：
///   1. nesting_level：维持嵌套 batch 计数（公共 API 不变）
///   2. is_batching：is_batching getter 兼容查询
/// queueEffect / flush / pending_effects 路径已废弃，signal.set 不再
/// 经此队列；调度走 graph.markSignalWritten + graph.endBatch 拓扑序 drain。
pub const BatchContext = struct {
    /// 待执行的 Effect 队列
    pending_effects: std.ArrayList(*EffectBase),

    /// 是否处于批量模式
    is_batching: bool = false,

    /// 嵌套层级
    nesting_level: u32 = 0,

    /// 父 allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BatchContext {
        return .{
            .pending_effects = std.ArrayList(*EffectBase){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BatchContext) void {
        self.pending_effects.deinit(self.allocator);
    }

    /// 开始批量更新
    pub fn begin(self: *BatchContext) !void {
        self.nesting_level += 1;
        if (self.nesting_level == 1) {
            self.is_batching = true;
            self.pending_effects.clearRetainingCapacity();
        }
    }

    /// 结束批量更新
    ///
    /// owner: *SignalOwner (类型擦除为 anyopaque,避免循环依赖)
    pub fn end(self: *BatchContext, owner: anytype) void {
        if (self.nesting_level == 0) return;

        self.nesting_level -= 1;

        // 只有最外层 batch 结束时才执行
        if (self.nesting_level == 0) {
            // 注意：不在此处设 is_batching=false，flush 内部管理 batching 状态
            // 这确保 flush 期间产生的新 Effect 仍然走 batch 路径（queueEffect）
            self.flush(owner);
        }
    }

    /// 添加 Effect 到待执行队列
    pub fn queueEffect(self: *BatchContext, effect: *EffectBase) !void {
        // 避免重复添加
        if (effect.is_queued) return;

        try self.pending_effects.append(self.allocator, effect);
        effect.is_queued = true;
    }

    /// 执行所有待处理的 Effect
    ///
    /// 使用"drain loop"策略：flush 期间保持 batching 开启，
    /// Effect 执行中产生的新 Signal 变化会继续 queueEffect 到列表中。
    /// 循环直到队列为空或达到安全上限。
    ///
    /// 历史债避免（吸取 Phase 0 审查的"16 次硬上限静默清空"问题）：
    /// 上限提到 1024，且达到上限时**panic（debug）/ error log（release）**
    /// 而非静默丢，业务上应当观察到，因为这是真实的循环依赖 bug。
    fn flush(self: *BatchContext, owner: anytype) void {
        const max_iterations: u32 = 1024;
        var iteration: u32 = 0;

        while (self.pending_effects.items.len > 0 and iteration < max_iterations) {
            iteration += 1;

            // 保持 batching 开启，让 flush 中产生的新 Effect 进入队列
            self.is_batching = true;

            // 快照当前队列长度，只执行本轮已有的 Effect
            const count = self.pending_effects.items.len;
            for (self.pending_effects.items[0..count]) |effect| {
                effect.is_queued = false;
                effect.runWithTracking(owner, self.allocator);
            }

            // 移除已执行的（可能有新 Effect 被追加到末尾）
            if (self.pending_effects.items.len > count) {
                std.mem.copyForwards(
                    *EffectBase,
                    self.pending_effects.items[0 .. self.pending_effects.items.len - count],
                    self.pending_effects.items[count..],
                );
                self.pending_effects.shrinkRetainingCapacity(self.pending_effects.items.len - count);
            } else {
                self.pending_effects.clearRetainingCapacity();
            }
        }

        self.is_batching = false;

        if (iteration >= max_iterations and self.pending_effects.items.len > 0) {
            // 真正的循环依赖；不静默丢，给开发者一个清晰错误。
            // debug：panic；release：高严重日志 + 清队列防死循环（非静默）。
            if (std.debug.runtime_safety) {
                std.debug.panic(
                    "[reactive.BatchContext] flush did not converge after {d} iterations, {d} effects pending — likely cyclic dependency",
                    .{ max_iterations, self.pending_effects.items.len },
                );
            } else {
                std.log.err(
                    "[reactive.BatchContext] flush did not converge after {d} iterations, {d} effects pending — likely cyclic dependency",
                    .{ max_iterations, self.pending_effects.items.len },
                );
            }
            for (self.pending_effects.items) |effect| {
                effect.is_queued = false;
            }
            self.pending_effects.clearRetainingCapacity();
        }
    }
};

// ===== 测试 =====

test "BatchContext: init/deinit" {
    var ctx = BatchContext.init(std.testing.allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.is_batching == false);
    try std.testing.expectEqual(@as(u32, 0), ctx.nesting_level);
}

test "BatchContext: nesting" {
    var ctx = BatchContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.begin();
    try std.testing.expect(ctx.is_batching == true);
    try std.testing.expectEqual(@as(u32, 1), ctx.nesting_level);

    try ctx.begin(); // 嵌套
    try std.testing.expectEqual(@as(u32, 2), ctx.nesting_level);

    // 模拟 owner (简化测试)
    var mock_owner = struct {
        current_effect: ?*EffectBase = null,
    }{};

    ctx.end(&mock_owner);
    try std.testing.expect(ctx.is_batching == true); // 还在批量模式
    try std.testing.expectEqual(@as(u32, 1), ctx.nesting_level);

    ctx.end(&mock_owner);
    try std.testing.expect(ctx.is_batching == false); // 退出批量模式
    try std.testing.expectEqual(@as(u32, 0), ctx.nesting_level);
}
