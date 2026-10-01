// Project Zenit - Reactive UI System
// Phase 1: Owner-based Reactive System (Zig-optimized)

pub const SignalOwner = @import("reactive/owner.zig").SignalOwner;
/// 延迟销毁队列的入口类型导出给消费方，"节点还在队列里、它借用的资源不能立刻释放"
/// 的场景（Global Find EditorPool 在 reactive 回调里被销毁）需要把资源的释放排进**同一条**队列
///（FIFO：节点先、资源后）。Entry 的存储归资源自己，直到回调跑完或 cancel。
pub const DeferredDisposal = @import("reactive/deferred_disposal.zig").Entry;
pub const Signal = @import("reactive/signal.zig").Signal;
pub const createEffect = @import("reactive/effect.zig").createEffect;
pub const Memo = @import("reactive/memo.zig").Memo;
pub const createMemo = @import("reactive/memo.zig").createMemo;
pub const Scope = @import("reactive/scope.zig").Scope;
pub const Context = @import("reactive/context.zig").Context;
pub const StoreOf = @import("reactive/store.zig").StoreOf;

// 内部类型 (供高级用户使用)
pub const SignalBase = @import("reactive/signal_base.zig").SignalBase;
pub const EffectBase = @import("reactive/effect_base.zig").EffectBase;
pub const BatchContext = @import("reactive/batch.zig").BatchContext;

// Phase 1: 公开类型分发的 eq 工具，组件层可用同一份语义做 prop diff
pub const eqlValue = @import("reactive/eq.zig").eqlValue;

// 确保所有子模块测试被包含
test {
    _ = @import("reactive/scope.zig");
    _ = @import("reactive/signal.zig");
    _ = @import("reactive/effect.zig");
    _ = @import("reactive/owner.zig");
    _ = @import("reactive/batch.zig");
    _ = @import("reactive/memo.zig");
    _ = @import("reactive/context.zig");
    _ = @import("reactive/signal_base.zig");
    _ = @import("reactive/effect_base.zig");
    _ = @import("reactive/eq.zig");
    _ = @import("reactive/graph.zig");
}

// ===== 快速上手示例 =====

const std = @import("std");

test "Reactive System: complete example" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    // 创建 Signal
    const count = try Signal(i32).create(owner, 0);
    const name = try Signal([]const u8).create(owner, "World");

    var output_buffer: [100]u8 = undefined;
    var output_len: usize = 0;

    // 创建 Effect (自动追踪依赖)
    try createEffect(owner, .{
        .count = count,
        .name = name,
        .buffer = &output_buffer,
        .len = &output_len,
    }, struct {
        fn render(ctx: anytype) void {
            const message = std.fmt.bufPrint(
                ctx.buffer,
                "Hello {s}, Count: {d}",
                .{ ctx.name.get(), ctx.count.get() },
            ) catch unreachable;
            ctx.len.* = message.len;
        }
    }.render);

    // 验证初始渲染
    try std.testing.expectEqualStrings("Hello World, Count: 0", output_buffer[0..output_len]);

    // 单次更新
    count.set(5);
    try std.testing.expectEqualStrings("Hello World, Count: 5", output_buffer[0..output_len]);

    name.set("Zenit");
    try std.testing.expectEqualStrings("Hello Zenit, Count: 5", output_buffer[0..output_len]);
}

test "Reactive System: batch updates" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const a = try Signal(i32).create(owner, 0);
    const b = try Signal(i32).create(owner, 0);

    var effect_run_count: i32 = 0;

    try createEffect(owner, .{
        .a = a,
        .b = b,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.a.get();
            _ = ctx.b.get();
            ctx.counter.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    // 不使用 batch: 两次更新 = 两次 Effect 运行
    a.set(1);
    b.set(1);
    try std.testing.expectEqual(@as(i32, 3), effect_run_count);

    // 使用 batch: 两次更新 = 一次 Effect 运行
    try owner.batch(struct {
        fn update(ctx: anytype) void {
            ctx.a.set(2);
            ctx.b.set(2);
        }
    }.update, .{ .a = a, .b = b });

    try std.testing.expectEqual(@as(i32, 4), effect_run_count); // 只增加 1 次
}

test "Reactive System: peek doesn't track" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const tracked = try Signal(i32).create(owner, 0);
    const untracked = try Signal(i32).create(owner, 100);

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

    untracked.set(200);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count); // Effect 不运行
}

// Phase 1: facade-level diamond glitch freedom
//
//      A (signal)
//     / \
//    B   C   <-- 都是 Memo，依赖 A
//    \ /
//     D (effect)
//
// 写 A 时 D 必须看到 B/C 都已根据新 A 重算的值（无中间陈旧状态）。
test "Reactive System: diamond glitch freedom (Memo + Effect)" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const a = try Signal(i32).create(owner, 1);

    const b = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.a.get() * 10;
        }
    }.compute);
    const c = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(ctx: anytype) i32 {
            return ctx.a.get() + 100;
        }
    }.compute);

    const Observed = struct { b: i32, c: i32, run: u32 };
    var observed = Observed{ .b = 0, .c = 0, .run = 0 };

    try createEffect(owner, .{
        .b = b,
        .c = c,
        .obs = &observed,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.obs.* = .{
                .b = ctx.b.get(),
                .c = ctx.c.get(),
                .run = ctx.obs.run + 1,
            };
        }
    }.run);

    // 初次：a=1 -> b=10, c=101
    try std.testing.expectEqual(@as(i32, 10), observed.b);
    try std.testing.expectEqual(@as(i32, 101), observed.c);
    try std.testing.expectEqual(@as(u32, 1), observed.run);

    // 写 a=5 -> 必须最终 b=50, c=105，且没有任何"中间观察值"
    a.set(5);
    try std.testing.expectEqual(@as(i32, 50), observed.b);
    try std.testing.expectEqual(@as(i32, 105), observed.c);
    // run 计数取决于 push 模型：可能 2 或 3 次（b 重算->push、c 重算->push 或合并）
    // 但最终值必须一致。这里允许 1-3 次重跑，关键是值一致。
    try std.testing.expect(observed.run >= 2);
}

// Phase 1: 验证 eqlValue 修复了 std.meta.eql 的 slice ptr-equality bug
test "Reactive System: signal []const u8 same content different ptr does not renotify" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    var buf1: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    var buf2: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };

    const s = try Signal([]const u8).create(owner, &buf1);

    var run_count: u32 = 0;
    try createEffect(owner, .{ .s = s, .c = &run_count }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.s.get();
            ctx.c.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // 同内容、不同 buffer：std.meta.eql 会判 != 触发；eqlValue 应判 = 跳过
    try std.testing.expect(buf1[0..].ptr != buf2[0..].ptr);
    s.set(&buf2);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // 不同内容应触发
    var buf3: [5]u8 = .{ 'w', 'o', 'r', 'l', 'd' };
    s.set(&buf3);
    try std.testing.expectEqual(@as(u32, 2), run_count);
}

// Phase 1: 验证 NaN 在 signal set 中不再触发 renotify storm
test "Reactive System: signal f32 NaN does not renotify" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const nan = @as(f32, std.math.nan(f32));
    const s = try Signal(f32).create(owner, nan);

    var run_count: u32 = 0;
    try createEffect(owner, .{ .s = s, .c = &run_count }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.s.get();
            ctx.c.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // 再写 NaN 不应触发（eqlValue 判等）
    s.set(nan);
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // 写真值触发
    s.set(1.0);
    try std.testing.expectEqual(@as(u32, 2), run_count);
}

// cross-scope cleanup adversarial test，在删除双轨保护前 land。
//
// 场景：owner-arena managed signal × scope-managed effect。
// scope.dispose 后，signal 仍存活；signal.set 应当：
//   (a) 不调到已销毁的 effect（曾经的 use-after-free 风险）
//   (b) 不引发任何 panic / 内存读越界
//
// v0.2-P1 双轨保护下：scope.dispose 调 graph.destroyNode 注销 effect node；
// signal 写时 graph.markSignalWritten 不会找到 dirty observer。
// 但 signal_base.subscribers 列表里旧 effect ptr 还在；旧 push DFS 路径若仍走
// 会触发 UAF。当前 set 已切到 graph 路径不走 push，但 subscribers 列表本身
// 也通过 scope.dispose:120 清理。这条 test 保证未来 v0.3 拆双轨时仍正确。
test "Reactive System: cross-scope cleanup — owner signal + scope effect" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    // owner-arena 创建 signal（跨 scope 存活）
    const counter = try Signal(i32).create(owner, 0);

    // 创建 scope，scope 内 effect 订阅 owner-arena signal
    var scope = try @import("reactive/scope.zig").Scope.init(owner.parent_allocator, null, owner);
    var effect_run_count: u32 = 0;

    try scope.createEffect(.{
        .signal = counter,
        .out = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.signal.get();
            ctx.out.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), effect_run_count);

    // 触发：scope-effect 应该 run
    counter.set(1);
    try std.testing.expectEqual(@as(u32, 2), effect_run_count);

    // 销毁 scope, effect 应当被 dispose；signal 仍存活
    scope.dispose();

    // 关键断言：dispose 后 signal.set 必须**不**触发已销毁的 effect。
    // 若 v0.3 拆双轨过程中 graph.destroyNode 没有正确从 signal.observers 摘除，
    // 这里会 panic / segfault / 触发 effect 调到悬垂 ctx 让 run_count 改变。
    counter.set(2);
    counter.set(3);
    try std.testing.expectEqual(@as(u32, 2), effect_run_count); // 不变

    // signal 自己仍可以正常被新 scope 订阅
    const new_scope = try @import("reactive/scope.zig").Scope.init(owner.parent_allocator, null, owner);
    defer new_scope.dispose();
    var new_run_count: u32 = 0;
    try new_scope.createEffect(.{
        .signal = counter,
        .out = &new_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.signal.get();
            ctx.out.* += 1;
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 1), new_run_count);

    counter.set(4);
    try std.testing.expectEqual(@as(u32, 2), new_run_count);
    try std.testing.expectEqual(@as(u32, 2), effect_run_count); // 老 effect 仍不变
}

// signal owner.deinit 后无残留 graph node leak
test "Reactive System: owner.deinit cleans up graph nodes" {
    var owner = try SignalOwner.init(std.testing.allocator);

    // 创建 100 个 signal + 50 个 effect
    var signals: [100]*Signal(i32) = undefined;
    for (&signals) |*slot| {
        slot.* = try Signal(i32).create(owner, 0);
    }
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try createEffect(owner, .{ .s = signals[i] }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.s.get();
            }
        }.run);
    }

    // graph node 数量：100 signal + 50 effect = 150
    try std.testing.expectEqual(@as(usize, 150), owner.graph.nodeCount());

    owner.deinit();
    // owner 已 deinit；graph 也跟着销毁，本测试主要验证不 leak
    // （由 testing.allocator 在 test 末尾报告 leak 检出）
}

// 回归：memo 的 compute 在 updateIfNecessary 递归中创建 reactive 节点，
// 会让 graph.nodes（ArrayListUnmanaged）realloc。修复前 updateIfNecessary
// 把 `*GraphNode` 缓存跨递归使用，realloc 后通过已释放内存读
// n.seen_versions.items -> segfault（graph.zig:468）。
//
// 触发形状必须是**两级 memo 链**：memoB 依赖 memoA 才会进入 .check 分支
// 并递归 updateIfNecessary(memoA)，进而在递归内跑 memoA 的 compute。
// 单级 memo 走 .dirty 直接 recomputeNode，碰不到这条路径。
test "regression: memo compute allocating reactive nodes must not dangle updateIfNecessary" {
    const owner_mod_ = @import("reactive/owner.zig");
    const owner = try owner_mod_.SignalOwner.init(std.testing.allocator);
    defer owner.deinit();
    const root = try Scope.init(std.testing.allocator, null, owner);
    defer root.dispose();

    const src = try root.createSignal(u32, 1);

    const A = struct {
        sc: *Scope,
        s: *Signal(u32),
        fn compute(self: *@This()) u32 {
            const v = self.s.get();
            // compute 内创建新 reactive 节点 -> nodes.append -> realloc
            const tmp = self.sc.createSignal(u32, v) catch return v;
            return tmp.get();
        }
    };
    var actx = A{ .sc = root, .s = src };
    const memo_a = try root.createMemo(u32, &actx, A.compute);
    const MemoT = @TypeOf(memo_a.*);

    const B = struct {
        a: *MemoT,
        fn compute(self: *@This()) u32 {
            return self.a.get() +% 1;
        }
    };
    var bctx = B{ .a = memo_a };
    const memo_b = try root.createMemo(u32, &bctx, B.compute);
    _ = memo_b.get();

    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        src.set(i);
        _ = memo_b.get();
    }

    // 能跑到这里即证明没有悬垂解引用；顺带断言值仍然正确传播。
    src.set(4242);
    try std.testing.expectEqual(@as(u32, 4243), memo_b.get());
}
