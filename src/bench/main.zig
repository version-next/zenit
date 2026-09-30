//! Bench main entry — 注册所有 bench cases 并运行
//!
//! 运行：
//!   zig build bench
//!   zig build bench -- 关键字              # 过滤
//!   zig build bench -- json=path/to.json   # 输出 JSON
//!
//! Phase 0 基线录入：
//! - reactive_1k_signal_fanout：1k 个 effect 订阅同一 signal，set 一次的开销
//! - resource_pool_cycle：alloc / release / endFrame 循环
//! - slotmap_alloc_free：ElementId SlotMap alloc + free 循环

const std = @import("std");
const runner = @import("runner.zig");

// reactive symbols 走 facade re-export (core.zig 已 pub 出来)，
// 不再保留独立 reactive bench module — 解决 facade 拉 Cx 时 core.zig 同时
// 属 reactive + zenit 两个 module 的冲突。
const zenit = @import("zenit");
const Signal = zenit.ui_core.Signal;
const SignalOwner = zenit.ui_core.SignalOwner;
const createEffect = zenit.ui_core.createEffect;
const ElementId = zenit.ElementId;
const SlotMap = zenit.SlotMap;
const ElementTable = zenit.ElementTable;
const IntrinsicCache = zenit.IntrinsicCache;
const LayoutInput = zenit.LayoutInput;
const AvailableSpaceXY = zenit.AvailableSpaceXY;
const hashLayoutInput = zenit.hashLayoutInput;
const LayoutTable = zenit.LayoutTable;
const paint_table = zenit.paint_table_mod;
const PaintTable = zenit.PaintTable;
const DisplayItem = zenit.DisplayItem;
const Bounds = zenit.Bounds;

// v0.2-P4 layer bench 只测算法层面的 enum/packed struct
const PromotionHint = zenit.PromotionHintForBench;

// v0.2-P5 GpuDraw + DisplayItem encoder
const GpuDraw = zenit.GpuDraw;
const encodeOne = zenit.encodeOne;
const encodeStream = zenit.encodeStream;

// v0.2-P6 i18n + shaping cache
const i18n = @import("i18n");
const ShapingCache = zenit.ShapingCache;
const ShapingKey = zenit.ShapingKey;
const GlyphPosition = zenit.GlyphPosition;
const Cluster = zenit.Cluster;
const FontMetrics = zenit.FontMetrics;

// v0.2-P7 a11y + gesture
const AccessibilityTree = zenit.AccessibilityTree;
const A11yDirtyFlag = zenit.A11yDirtyFlag;
const GestureArena = zenit.GestureArena;

// v0.2-P8 ControlledProp + Select headless
const ControlledProp = zenit.ControlledProp;
const select_headless = zenit.select_headless_mod;

const resource_pool = @import("resource_pool");
const ResourcePool = resource_pool.ResourcePool;

// ============================================================================
// Bench: reactive 1k signal fanout
// ============================================================================

const FanoutState = struct {
    owner: *SignalOwner,
    signal: *Signal(i32),
    counter: *i64,
    target: i32 = 0,
};

fn fanoutSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();

    const sig = try Signal(i32).create(owner, 0);
    const counter = try allocator.create(i64);
    counter.* = 0;

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try createEffect(owner, .{
            .sig = sig,
            .counter = counter,
        }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.sig.get();
                ctx.counter.* +%= 1;
            }
        }.run);
    }

    const state = try allocator.create(FanoutState);
    state.* = .{
        .owner = owner,
        .signal = sig,
        .counter = counter,
    };
    return @ptrCast(state);
}

fn fanoutTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *FanoutState = @ptrCast(@alignCast(ptr));
    state.owner.deinit();
    allocator.destroy(state.counter);
    allocator.destroy(state);
}

fn fanoutBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *FanoutState = @ptrCast(@alignCast(ctx.state.?));
    state.target +%= 1;
    state.signal.set(state.target);
    ctx.blackbox(state.counter.*);
}

// ============================================================================
// Bench: resource_pool alloc / release / endFrame cycle
// ============================================================================

const PoolState = struct {
    pool: ResourcePool,
};

fn poolSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const pool = try ResourcePool.init(allocator, 3);
    const state = try allocator.create(PoolState);
    state.* = .{ .pool = pool };
    return @ptrCast(state);
}

fn poolTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *PoolState = @ptrCast(@alignCast(ptr));
    state.pool.deinit();
    allocator.destroy(state);
}

fn poolBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *PoolState = @ptrCast(@alignCast(ctx.state.?));
    const h = try state.pool.alloc(.texture, null, null);
    state.pool.release(h);
    if ((ctx.iter_index & 0x3F) == 0) {
        state.pool.endFrame();
    }
    ctx.blackbox(h);
}

// ============================================================================
// Bench: SlotMap alloc + free
// ============================================================================

const SlotState = struct {
    map: SlotMap(u32),
};

fn slotSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(SlotState);
    state.* = .{ .map = SlotMap(u32).init(allocator) };
    return @ptrCast(state);
}

fn slotTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *SlotState = @ptrCast(@alignCast(ptr));
    state.map.deinit();
    allocator.destroy(state);
}

fn slotBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *SlotState = @ptrCast(@alignCast(ctx.state.?));
    const id = try state.map.alloc(@intCast(ctx.iter_index));
    state.map.free(id);
    ctx.blackbox(id);
}

// ============================================================================
// diamond glitch set —— A→B(memo), A→C(memo), [B,C]→D(effect)
// 写 A 时 D 必须只跑一次（拓扑序保证）+ B/C 都已根据新 A 重算的值。
// ============================================================================

const Memo = zenit.ui_core.Memo;
const createMemo = zenit.ui_core.createMemo;

const DiamondState = struct {
    owner: *SignalOwner,
    a: *Signal(i32),
    b: *Memo(i32),
    c: *Memo(i32),
    run_count: *u64,
    target: i32 = 0,
};

fn diamondSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const a = try Signal(i32).create(owner, 0);
    const b = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(c: anytype) i32 {
            return c.a.get() * 10;
        }
    }.compute);
    const c = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(cx: anytype) i32 {
            return cx.a.get() + 100;
        }
    }.compute);
    const counter = try allocator.create(u64);
    counter.* = 0;
    try createEffect(owner, .{
        .b = b,
        .c = c,
        .counter = counter,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.b.get();
            _ = ctx.c.get();
            ctx.counter.* +%= 1;
        }
    }.run);

    const state = try allocator.create(DiamondState);
    state.* = .{
        .owner = owner,
        .a = a,
        .b = b,
        .c = c,
        .run_count = counter,
    };
    return @ptrCast(state);
}

fn diamondTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *DiamondState = @ptrCast(@alignCast(ptr));
    state.owner.deinit();
    allocator.destroy(state.run_count);
    allocator.destroy(state);
}

fn diamondBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *DiamondState = @ptrCast(@alignCast(ctx.state.?));
    state.target +%= 1;
    state.a.set(state.target);
    ctx.blackbox(state.run_count.*);
}

// ============================================================================
// lazy memo unused —— 创建 memo 但没下游读，set source 不应触发计算
// ============================================================================

const LazyState = struct {
    owner: *SignalOwner,
    a: *Signal(i32),
    target: i32 = 0,
};

fn lazyMemoSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const a = try Signal(i32).create(owner, 0);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        _ = try createMemo(owner, i32, .{ .a = a }, struct {
            fn compute(c: anytype) i32 {
                // 故意昂贵：100 个 memo 都依赖 a；如果 lazy 正确，set a 时它们都不算
                var s: i32 = 0;
                var k: i32 = 0;
                while (k < 100) : (k += 1) s +%= c.a.get();
                return s;
            }
        }.compute);
    }

    const state = try allocator.create(LazyState);
    state.* = .{ .owner = owner, .a = a };
    return @ptrCast(state);
}

fn lazyMemoTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *LazyState = @ptrCast(@alignCast(ptr));
    state.owner.deinit();
    allocator.destroy(state);
}

fn lazyMemoBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *LazyState = @ptrCast(@alignCast(ctx.state.?));
    state.target +%= 1;
    state.a.set(state.target);
    ctx.blackbox(state.target);
}

// ============================================================================
// topological chain 10 —— A → M1 → M2 → ... → M10 → effect
// 写 A 时 effect 应只触发一次，所有 memo 拓扑序更新。
// ============================================================================

const ChainState = struct {
    owner: *SignalOwner,
    a: *Signal(i32),
    final_count: *u64,
    target: i32 = 0,
};

fn chainSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const a = try Signal(i32).create(owner, 0);
    var prev_memo = try createMemo(owner, i32, .{ .src = a }, struct {
        fn compute(c: anytype) i32 {
            return c.src.get() + 1;
        }
    }.compute);
    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        prev_memo = try createMemo(owner, i32, .{ .src = prev_memo }, struct {
            fn compute(c: anytype) i32 {
                return c.src.get() + 1;
            }
        }.compute);
    }
    const counter = try allocator.create(u64);
    counter.* = 0;
    try createEffect(owner, .{ .last = prev_memo, .counter = counter }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.last.get();
            ctx.counter.* +%= 1;
        }
    }.run);

    const state = try allocator.create(ChainState);
    state.* = .{ .owner = owner, .a = a, .final_count = counter };
    return @ptrCast(state);
}

fn chainTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *ChainState = @ptrCast(@alignCast(ptr));
    state.owner.deinit();
    allocator.destroy(state.final_count);
    allocator.destroy(state);
}

fn chainBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ChainState = @ptrCast(@alignCast(ctx.state.?));
    state.target +%= 1;
    state.a.set(state.target);
    ctx.blackbox(state.final_count.*);
}

// ============================================================================
// 10k node tree build + traverse —— element_table SoA 性能
// 模拟 layout pass 的"建树 + 全量遍历"工作量；一旦 layout 切到 ElementTable
// 这就是 zero-dirty 帧的 baseline 工作。
// ============================================================================

const TreeState = struct {
    table: ElementTable,
    root: ElementId,
    target_id: ElementId,
};

fn treeSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    var t = ElementTable.init(allocator);
    errdefer t.deinit();

    // 建 10k node 平衡树（depth 100, 100 child each）
    const root = try t.create(.{ .tag = .container, .key = 0 });
    var target: ElementId = root;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const branch = try t.create(.{ .tag = .container, .key = i });
        t.appendChild(root, branch);
        var j: u32 = 0;
        while (j < 99) : (j += 1) {
            const leaf = try t.create(.{ .tag = .text, .key = i * 100 + j });
            t.appendChild(branch, leaf);
            if (i == 50 and j == 50) target = leaf;
        }
    }

    const state = try allocator.create(TreeState);
    state.* = .{ .table = t, .root = root, .target_id = target };
    return @ptrCast(state);
}

fn treeTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *TreeState = @ptrCast(@alignCast(ptr));
    state.table.deinit();
    allocator.destroy(state);
}

fn tree10kTraverseBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *TreeState = @ptrCast(@alignCast(ctx.state.?));
    // 全树 DFS：ElementTable.children iterator
    var stack: [128]ElementId = undefined;
    stack[0] = state.root;
    var sp: usize = 1;
    var visited: u32 = 0;
    while (sp > 0) {
        sp -= 1;
        const cur = stack[sp];
        visited += 1;
        var iter = state.table.children(cur);
        while (iter.next()) |child| {
            if (sp >= stack.len) break;
            stack[sp] = child;
            sp += 1;
        }
    }
    ctx.blackbox(visited);
}

// ============================================================================
// IntrinsicCache hit rate
// 1k 不同 LayoutInput key，先 put 一遍，然后 100 次随机命中读
// ============================================================================

const CacheState = struct {
    cache: IntrinsicCache,
    keys: [1024]u64,
};

fn cacheSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(CacheState);
    state.cache = .{};

    // 用 hashLayoutInput 生成 1024 个不同 hash
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        const inp = LayoutInput{
            .available_space = AvailableSpaceXY.definite(@as(f32, @floatFromInt(100 + i)), 200),
        };
        const h = hashLayoutInput(inp);
        state.keys[i] = h;
        state.cache.put(h, .{ .size = .{ .width = @floatFromInt(i), .height = 50 } });
    }

    return @ptrCast(state);
}

fn cacheTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *CacheState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn cacheLookupBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *CacheState = @ptrCast(@alignCast(ctx.state.?));
    // 4-entry direct mapped cache：大量 key 自相覆盖；只有 last 4 命中。
    // 但接口仍 O(1)，bench 验证调用本身开销。
    const key = state.keys[ctx.iter_index % 1024];
    const got = state.cache.get(key);
    ctx.blackbox(got);
}

// ============================================================================
// ElementTable 子树 unlink 中间节点
// ============================================================================

fn unlinkBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *TreeState = @ptrCast(@alignCast(ctx.state.?));
    // 取 target 节点并 unlink + appendChild 回去
    const tgt = state.target_id;
    if (state.table.isValid(tgt)) {
        state.table.unlink(tgt);
        // 重新挂回 root（避免 tree 退化）
        state.table.appendChild(state.root, tgt);
    }
    ctx.blackbox(tgt);
}

// ============================================================================
// single_signal_color_change_paint
// 端到端测：signal.set → effect run → 写 dirty hashmap entry。
// 这是"单 signal 改色 → paint dirty 落地"路径的真实成本。
// plan 矩阵 #2 目标 < 100µs。
// ============================================================================

const SingleSignalState = struct {
    owner: *SignalOwner,
    color_signal: *Signal(u32),
    dirty_set: std.AutoHashMapUnmanaged(u32, u8),
    target_id: u32,
    target_color: u32,
};

fn singleSignalColorSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const sig = try Signal(u32).create(owner, 0xFF0000FF);

    const state = try allocator.create(SingleSignalState);
    state.* = .{
        .owner = owner,
        .color_signal = sig,
        .dirty_set = .{},
        .target_id = 42,
        .target_color = 0xFF0000FF,
    };

    // 创建 effect：模拟 reactive effect 收到 color 变化后通知 paint dirty
    // 这是真实场景里 button.style.background = signal.get() 的 reactive 桥
    try createEffect(owner, .{
        .signal = sig,
        .dirty_set = &state.dirty_set,
        .allocator = allocator,
        .target_id = state.target_id,
        .target_color = &state.target_color,
    }, struct {
        fn run(ctx: anytype) void {
            const new_color = ctx.signal.get();
            // 模拟"颜色变化 → 标 paint dirty"
            ctx.target_color.* = new_color;
            // 诊断路径：bench 里模拟 dirty 标记的假负载，不是真渲染管线。
            // 分配失败只让这一轮少标一个 id，测的是 signal 传播开销本身。
            ctx.dirty_set.put(ctx.allocator, ctx.target_id, 1) catch {};
        }
    }.run);

    return @ptrCast(state);
}

fn singleSignalColorTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *SingleSignalState = @ptrCast(@alignCast(ptr));
    state.dirty_set.deinit(allocator);
    state.owner.deinit();
    allocator.destroy(state);
}

fn singleSignalColorBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *SingleSignalState = @ptrCast(@alignCast(ctx.state.?));
    // 模拟用户改色：signal.set 触发 reactive 链路全程跑一遍
    const new_color: u32 = @intCast(0xFF000000 | (ctx.iter_index & 0xFFFFFF));
    state.color_signal.set(new_color);
    ctx.blackbox(state.target_color);
    ctx.blackbox(state.dirty_set.count());
}

// ============================================================================
// signal_color_change_realistic
// 更真实场景：1 个 color signal 驱动 10 个 Button 的 background；
// 改色触发 10 个 effect 同时跑，每个 effect 模拟"读 signal + 改 style + 标 dirty"
// 这接近真实 dashboard 里"theme 切换"的 reactive 工作量。
// ============================================================================

const RealisticState = struct {
    owner: *SignalOwner,
    theme_signal: *Signal(u32),
    button_colors: [10]u32,
    dirty_set: std.AutoHashMapUnmanaged(u32, u8),
    allocator: std.mem.Allocator,
};

fn realisticSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const theme = try Signal(u32).create(owner, 0xFF0000FF);

    const state = try allocator.create(RealisticState);
    state.* = .{
        .owner = owner,
        .theme_signal = theme,
        .button_colors = [_]u32{0} ** 10,
        .dirty_set = .{},
        .allocator = allocator,
    };

    // 10 个 button 各创建 effect 订阅 theme 变化
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const Slot = struct {
            theme_sig: *Signal(u32),
            color_slot: *u32,
            slot_id: u32,
            dirty: *std.AutoHashMapUnmanaged(u32, u8),
            alloc: std.mem.Allocator,
        };
        const slot_ctx = Slot{
            .theme_sig = theme,
            .color_slot = &state.button_colors[i],
            .slot_id = i,
            .dirty = &state.dirty_set,
            .alloc = allocator,
        };
        try createEffect(owner, slot_ctx, struct {
            fn run(ctx: anytype) void {
                const new_color = ctx.theme_sig.get();
                // 模拟"读 signal → 算出 style → 写 Node 字段 → 标 dirty"完整链路
                ctx.color_slot.* = new_color;
                // 诊断路径：同上，bench 假负载。
                ctx.dirty.put(ctx.alloc, ctx.slot_id, 1) catch {};
            }
        }.run);
    }

    return @ptrCast(state);
}

fn realisticTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *RealisticState = @ptrCast(@alignCast(ptr));
    state.dirty_set.deinit(allocator);
    state.owner.deinit();
    allocator.destroy(state);
}

fn realisticBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *RealisticState = @ptrCast(@alignCast(ctx.state.?));
    const new_color: u32 = @intCast(0xFF000000 | (ctx.iter_index & 0xFFFFFF));
    state.theme_signal.set(new_color);
    ctx.blackbox(state.button_colors[0]);
    ctx.blackbox(state.dirty_set.count());
}

// ============================================================================
// ElementTable 1k create + appendChild 链
// 模拟 v0.5 取代 *Node god-object 后的真"创建节点"路径
// ============================================================================

fn elementCreateAppendBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    var table = ElementTable.init(allocator);
    defer table.deinit();
    const root = try table.create(.{ .tag = .container, .key = 0 });
    var i: u32 = 1;
    while (i < 100) : (i += 1) {
        const child = try table.create(.{ .tag = .text, .key = i });
        table.appendChild(root, child);
    }
    _ = ctx;
}

// ============================================================================
// World 4 表 ensureSlot 同步路径
// 模拟 builders 在 createElement 时对 layout/paint table ensureSlot 的成本
// ============================================================================

const FourTablesState = struct {
    elements: ElementTable,
    layout: LayoutTable,
    paint: PaintTable,
};

fn fourTablesSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(FourTablesState);
    state.* = .{
        .elements = ElementTable.init(allocator),
        .layout = LayoutTable.init(allocator),
        .paint = PaintTable.init(allocator),
    };
    return @ptrCast(state);
}

fn fourTablesTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *FourTablesState = @ptrCast(@alignCast(ptr));
    state.elements.deinit();
    state.layout.deinit();
    state.paint.deinit();
    allocator.destroy(state);
}

fn fourTablesEnsureBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *FourTablesState = @ptrCast(@alignCast(ctx.state.?));
    // 一次 element create + 同步 layout/paint table 写入
    const id = try state.elements.create(.{ .tag = .container, .key = ctx.iter_index });
    try state.layout.ensureSlot(id);
    try state.paint.ensureSlot(id);
    ctx.blackbox(id);
}

// ============================================================================
// ElementId hot path 验证 (世界扫 1k IDs)
// ============================================================================

fn elementIdHotPathBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const id: ElementId = .{ .index = @intCast(i), .generation = 0 };
        sum +%= id.raw();
    }
    ctx.blackbox(sum);
    _ = ctx.iter_index;
}

// ============================================================================
// Bounds.unionWith hot path（layerize 累计 bounds）
// ============================================================================

const BoundsBenchState = struct {
    bounds: [256]Bounds,
};

fn boundsSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(BoundsBenchState);
    for (&state.bounds, 0..) |*b, i| {
        b.* = .{
            .min_x = @floatFromInt(i),
            .min_y = @floatFromInt(i * 2),
            .max_x = @floatFromInt(i + 100),
            .max_y = @floatFromInt(i * 2 + 50),
        };
    }
    return @ptrCast(state);
}

fn boundsTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *BoundsBenchState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn boundsUnionBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *BoundsBenchState = @ptrCast(@alignCast(ctx.state.?));
    var acc: Bounds = .{};
    for (state.bounds) |b| {
        acc = acc.unionWith(b);
    }
    ctx.blackbox(acc);
}

// ============================================================================
// PaintChunk content_hash batch invalidation
// 模拟一帧内 1k chunks 全部 content_hash mismatch 触发重录
// ============================================================================

const PaintBatchState = struct {
    table: PaintTable,
};

fn paintBatchSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(PaintBatchState);
    state.* = .{ .table = PaintTable.init(allocator) };
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const eid: ElementId = .{ .index = @intCast(i), .generation = 0 };
        try state.table.ensureSlot(eid);
        // 初始 hash
        _ = try state.table.beginRecord(eid, 1);
        state.table.endRecord(eid, .NONE);
    }
    return @ptrCast(state);
}

fn paintBatchTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *PaintBatchState = @ptrCast(@alignCast(ptr));
    state.table.deinit();
    allocator.destroy(state);
}

fn paintBatchInvalidateBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *PaintBatchState = @ptrCast(@alignCast(ctx.state.?));
    // 全部 chunk 用新 hash 触发 cache miss
    var miss_count: u32 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const eid: ElementId = .{ .index = @intCast(i), .generation = 0 };
        const new_hash: u64 = @as(u64, ctx.iter_index) * 1000 + @as(u64, i);
        if (try state.table.beginRecord(eid, new_hash)) {
            miss_count += 1;
            state.table.endRecord(eid, .NONE);
        }
    }
    ctx.blackbox(miss_count);
}

// ============================================================================
// PropertyStateRef pack/unpack（renderer 每 chunk 读 16B 引用）
// ============================================================================

fn propertyStateRefBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const ref = zenit.PropertyStateRef{
        .transform_id = @truncate(ctx.iter_index),
        .clip_id = @truncate(ctx.iter_index >> 8),
        .effect_id = @truncate(ctx.iter_index >> 16),
        .scroll_id = @truncate(ctx.iter_index >> 24),
    };
    const raw: u128 = @bitCast(ref);
    const back: zenit.PropertyStateRef = @bitCast(raw);
    ctx.blackbox(back);
}

// ============================================================================
// IntrinsicCache miss-path（模拟 layout pass 第一次测每节点）
// ============================================================================

const IntrinsicCacheState = struct {
    cache: IntrinsicCache,
    keys: [256]u64,
};

fn intrinsicCacheMissSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(IntrinsicCacheState);
    state.cache = .{};
    for (&state.keys, 0..) |*k, i| {
        const inp = LayoutInput{
            .available_space = AvailableSpaceXY.definite(@as(f32, @floatFromInt(i)), 100),
        };
        k.* = hashLayoutInput(inp);
    }
    return @ptrCast(state);
}

fn intrinsicCacheMissTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *IntrinsicCacheState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn intrinsicCacheMissBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *IntrinsicCacheState = @ptrCast(@alignCast(ctx.state.?));
    // 256 个不同 key 反复 put（4-entry cache 必然多数 miss）
    const k = state.keys[ctx.iter_index % state.keys.len];
    state.cache.put(k, .{ .size = .{ .width = 100, .height = 50 } });
}

// ============================================================================
// LayoutTable epoch++ scan (1k node check pass invalid)
// ============================================================================

fn layoutEpochScanBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *LayoutTableState = @ptrCast(@alignCast(ctx.state.?));
    var max_epoch: u64 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const e = state.table.epoch(.{ .index = @intCast(i), .generation = 0 });
        if (e > max_epoch) max_epoch = e;
    }
    ctx.blackbox(max_epoch);
}

// ============================================================================
// AvailableSpace fit-content path - 模拟 Constraint passing
// ============================================================================

fn availableSpaceTransformBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const inp = LayoutInput{
        .available_space = AvailableSpaceXY.definite(
            @as(f32, @floatFromInt((ctx.iter_index & 0xFF) + 100)),
            200,
        ),
    };
    // 模拟 Constraint passing：subtract padding + clamp + hash 决定 cache key
    const w_after = inp.available_space.width.subtractDefinite(20).clampMax(800);
    const h_after = inp.available_space.height.subtractDefinite(10).clampMax(600);
    const inp2 = LayoutInput{
        .available_space = .{ .width = w_after, .height = h_after },
        .parent_size = .{ .width = 800, .height = 600 },
    };
    const h = hashLayoutInput(inp2);
    ctx.blackbox(h);
}

// ============================================================================
// a11y_tree drainDirty
// ============================================================================

const A11yDrainState = struct {
    tree: AccessibilityTree,
    drain_count: u32,
};

fn a11yDrainSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(A11yDrainState);
    state.* = .{ .tree = AccessibilityTree.init(allocator), .drain_count = 0 };
    // 预填 100 个 a11y nodes
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try state.tree.upsert(.{
            .element = .{ .index = @intCast(i), .generation = 0 },
            .role = .button,
            .state = .{ .focusable = true },
            .label_hash = i,
        });
    }
    return @ptrCast(state);
}

fn a11yDrainTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *A11yDrainState = @ptrCast(@alignCast(ptr));
    state.tree.deinit();
    allocator.destroy(state);
}

fn a11yDrainCb(ctx: *anyopaque, id: zenit.ElementId, flag: zenit.A11yDirtyFlag) void {
    const c: *A11yDrainState = @ptrCast(@alignCast(ctx));
    c.drain_count +%= 1;
    _ = id;
    _ = flag;
}

fn a11yDrainBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *A11yDrainState = @ptrCast(@alignCast(ctx.state.?));
    state.drain_count = 0;
    state.tree.drainDirty(state, a11yDrainCb);
    // 重新标 dirty 100 个让下轮 bench 有事可 drain
    // 诊断路径：bench fixture 的重置步骤，失败只影响下一轮的样本量，
    // 不参与任何产品代码路径。
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        state.tree.markDirty(.{ .index = @intCast(i), .generation = 0 }, .{ .state_changed = true }) catch {};
    }
    ctx.blackbox(state.drain_count);
}

// ============================================================================
// select_headless typeahead 匹配
// ============================================================================

fn typeaheadSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(SelectBenchState);
    state.* = .{
        .state = select_headless.SelectState(i32).init(.{}),
        .options = undefined,
    };
    // 10 选项不同首字母
    const labels = [_][]const u8{ "Apple", "Banana", "Cherry", "Date", "Elderberry", "Fig", "Grape", "Honeydew", "Kiwi", "Lemon" };
    for (&state.options, 0..) |*opt, i| {
        opt.* = .{ .value = @intCast(i), .label = labels[i] };
    }
    return @ptrCast(state);
}

fn typeaheadBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *SelectBenchState = @ptrCast(@alignCast(ctx.state.?));
    state.state.typeahead_len = 0; // reset
    const ch: u8 = @intCast(@as(u8, 'a') + @as(u8, @intCast(ctx.iter_index % 10)));
    select_headless.step(i32, &state.state, &state.options, .type_char, ch);
    ctx.blackbox(state.state.highlight_index);
}

// ============================================================================
// a11y tree.children lookup（O(N) scan）
// ============================================================================

const A11yChildrenState = struct {
    tree: AccessibilityTree,
    out: std.ArrayListUnmanaged(zenit.ElementId) = .{},
};

fn a11yChildrenSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(A11yChildrenState);
    state.* = .{ .tree = AccessibilityTree.init(allocator) };
    errdefer allocator.destroy(state);
    errdefer state.tree.deinit();
    // Capacity is fixture setup, not part of the operation being measured.
    // Reallocating and freeing 50 IDs per iteration made this benchmark vary
    // by 2.8x on unchanged code and mostly measured the GPA, not tree.children.
    try state.out.ensureTotalCapacity(allocator, 50);
    const parent: zenit.ElementId = .{ .index = 0, .generation = 0 };
    try state.tree.upsert(.{ .element = parent, .role = .group });
    var i: u32 = 1;
    while (i <= 50) : (i += 1) {
        try state.tree.upsert(.{
            .element = .{ .index = @intCast(i), .generation = 0 },
            .parent = parent,
            .role = .listitem,
            .sibling_index = i - 1,
        });
    }
    return @ptrCast(state);
}

fn a11yChildrenTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *A11yChildrenState = @ptrCast(@alignCast(ptr));
    state.out.deinit(allocator);
    state.tree.deinit();
    allocator.destroy(state);
}

fn a11yChildrenBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const state: *A11yChildrenState = @ptrCast(@alignCast(ctx.state.?));
    state.out.clearRetainingCapacity();
    const parent: zenit.ElementId = .{ .index = 0, .generation = 0 };
    try state.tree.children(parent, &state.out, allocator);
    ctx.blackbox(state.out.items.len);
}

// ============================================================================
// encode_dashboard_typical (50 rect + 30 text + 10 image 混合)
// ============================================================================

const DashboardEncodeState = struct {
    items: [90]DisplayItem,
    out: [90]GpuDraw,
};

fn dashboardSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(DashboardEncodeState);
    var i: usize = 0;
    // 50 rect
    while (i < 50) : (i += 1) {
        state.items[i] = .{ .kind = .rect };
    }
    // 30 text（同 font）
    while (i < 80) : (i += 1) {
        state.items[i] = .{ .kind = .text, .resource_handle = 1 };
    }
    // 10 image
    while (i < 90) : (i += 1) {
        state.items[i] = .{ .kind = .image, .resource_handle = 100 };
    }
    return @ptrCast(state);
}

fn dashboardTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *DashboardEncodeState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn dashboardEncodeBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *DashboardEncodeState = @ptrCast(@alignCast(ctx.state.?));
    const written = encodeStream(&state.items, 0, &state.out);
    ctx.blackbox(written);
}

// ============================================================================
// shaping_cache_warm_hit_rate（100 次 lookup，全命中）
// ============================================================================

const ShapingWarmState = struct {
    cache: ShapingCache,
    keys: [128]ShapingKey,
};

fn shapingWarmSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(ShapingWarmState);
    state.* = .{ .cache = ShapingCache.init(allocator, 256), .keys = undefined };
    state.cache.beginFrame();

    const empty_g: []const GlyphPosition = &.{};
    const empty_c: []const Cluster = &.{};
    const m = FontMetrics{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 };

    for (&state.keys, 0..) |*k, i| {
        k.* = .{
            .text_hash = @intCast(i + 1),
            .text_len = 10,
            .font_id = 0,
            .max_width = 100,
            .font_size = 14,
        };
        try state.cache.insert(k.*, empty_g, empty_c, m, .ltr, 100);
    }
    return @ptrCast(state);
}

fn shapingWarmTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *ShapingWarmState = @ptrCast(@alignCast(ptr));
    state.cache.deinit();
    allocator.destroy(state);
}

fn shapingWarmBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ShapingWarmState = @ptrCast(@alignCast(ctx.state.?));
    const k = state.keys[ctx.iter_index % state.keys.len];
    const got = state.cache.lookup(k);
    ctx.blackbox(got);
}

// ============================================================================
// GlyphRun.xToCluster 复杂 cluster（10 codepoints, 不均匀 advance）
// ============================================================================

const GlyphRun = zenit.GlyphRun;

const XToClusterState = struct {
    glyphs: [10]GlyphPosition,
    clusters: [10]Cluster,
    run: GlyphRun,
};

fn xToClusterSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(XToClusterState);
    for (&state.glyphs, 0..) |*g, i| {
        g.* = .{
            .glyph_id = @intCast(i + 1),
            .x_advance = @floatFromInt(8 + (i % 4) * 3), // 8/11/14/17 px 不均
        };
    }
    for (&state.clusters, 0..) |*c, i| {
        c.* = .{
            .byte_offset = @intCast(i * 2),
            .glyph_start = @intCast(i),
            .glyph_end = @intCast(i + 1),
        };
    }
    state.run = .{
        .glyphs = &state.glyphs,
        .clusters = &state.clusters,
        .metrics = .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
        .total_advance = 100,
    };
    return @ptrCast(state);
}

fn xToClusterTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *XToClusterState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn xToClusterBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *XToClusterState = @ptrCast(@alignCast(ctx.state.?));
    const x: f32 = @floatFromInt(ctx.iter_index % 100);
    const cluster = state.run.xToCluster(x);
    ctx.blackbox(cluster);
}

// ============================================================================
// PropertyScrollNode array update simulation
// 模拟 1000 scroll containers 每帧更新 offset
// ============================================================================

const ScrollArrayState = struct {
    nodes: [1000]zenit.PropertyScrollNode,
};

fn scrollArraySetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(ScrollArrayState);
    for (&state.nodes, 0..) |*n, i| {
        n.* = .{ .node_id = @intCast(i), .viewport_w = 800, .viewport_h = 600 };
    }
    return @ptrCast(state);
}

fn scrollArrayTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *ScrollArrayState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn scrollOffsetUpdateBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ScrollArrayState = @ptrCast(@alignCast(ctx.state.?));
    // 1000 个 scroll node 全部 update offset（模拟每帧滚动事件）
    for (&state.nodes) |*n| {
        n.scroll_offset_y = @floatFromInt(ctx.iter_index & 0xFFFF);
        n.is_scrolling = true;
    }
    ctx.blackbox(state.nodes[0].scroll_offset_y);
}

// ============================================================================
// layerize hint collection (1000 scroll containers)
// ============================================================================

const HintCollectState = struct {
    inputs: [1000]zenit.PromotionHintForBench,
};

fn hintCollectSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(HintCollectState);
    for (&state.inputs, 0..) |*h, i| {
        h.* = .{
            .is_scroll_container = (i & 1) == 0,
            .transform_animating = (i & 2) == 0,
        };
    }
    return @ptrCast(state);
}

fn hintCollectTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *HintCollectState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn hintCollectBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *HintCollectState = @ptrCast(@alignCast(ctx.state.?));
    var promote_count: u32 = 0;
    for (state.inputs) |h| {
        if (h.shouldPromote()) promote_count += 1;
    }
    ctx.blackbox(promote_count);
}

// ============================================================================
// scroll node lookup by ElementId
// ============================================================================

fn scrollLookupBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ScrollArrayState = @ptrCast(@alignCast(ctx.state.?));
    const idx = ctx.iter_index % 1000;
    const offset = state.nodes[idx].scroll_offset_y;
    ctx.blackbox(offset);
}

// ============================================================================
// ElementId pack/unpack via World.elements
// 验证 first-class ElementId API 在 World 路径上的开销
// ============================================================================

const ElementWorldState = struct {
    table: ElementTable,
    ids: [1000]ElementId,
};

fn elementWorldSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(ElementWorldState);
    state.* = .{ .table = ElementTable.init(allocator), .ids = undefined };
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        state.ids[i] = try state.table.create(.{ .tag = .container, .key = i });
    }
    return @ptrCast(state);
}

fn elementWorldTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *ElementWorldState = @ptrCast(@alignCast(ptr));
    state.table.deinit();
    allocator.destroy(state);
}

fn elementIsValidBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ElementWorldState = @ptrCast(@alignCast(ctx.state.?));
    const id = state.ids[ctx.iter_index % 1000];
    const valid = state.table.isValid(id);
    ctx.blackbox(valid);
}

fn elementTagReadBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ElementWorldState = @ptrCast(@alignCast(ctx.state.?));
    const id = state.ids[ctx.iter_index % 1000];
    const tag = state.table.tag(id);
    ctx.blackbox(tag);
}

fn elementLinksReadBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ElementWorldState = @ptrCast(@alignCast(ctx.state.?));
    const id = state.ids[ctx.iter_index % 1000];
    const links = state.table.links(id);
    ctx.blackbox(links);
}

// ============================================================================
// LayoutTable.markLaidOut throughput
// 模拟 layout pass 写 1k 节点 rect 的开销
// ============================================================================

const LayoutTableState = struct {
    table: LayoutTable,
};

fn layoutTableSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(LayoutTableState);
    state.* = .{ .table = LayoutTable.init(allocator) };
    // 预分配 1k 个 slot
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try state.table.ensureSlot(.{ .index = @intCast(i), .generation = 0 });
    }
    return @ptrCast(state);
}

fn layoutTableTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *LayoutTableState = @ptrCast(@alignCast(ptr));
    state.table.deinit();
    allocator.destroy(state);
}

fn layoutTableMarkLaidOutBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *LayoutTableState = @ptrCast(@alignCast(ctx.state.?));
    const id: ElementId = .{ .index = @truncate(ctx.iter_index % 1000), .generation = 0 };
    state.table.markLaidOut(id, .{ .width = 100, .height = 50 }, .{
        .x = 10,
        .y = 20,
        .width = 100,
        .height = 50,
    });
}

// ============================================================================
// LayoutTable.rect read hot path
// ============================================================================

fn layoutTableRectReadBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *LayoutTableState = @ptrCast(@alignCast(ctx.state.?));
    const id: ElementId = .{ .index = @truncate(ctx.iter_index % 1000), .generation = 0 };
    const r = state.table.rect(id);
    ctx.blackbox(r);
}

// ============================================================================
// LayoutTable.epoch read hot path（cache invalidation 检查）
// ============================================================================

fn layoutTableEpochReadBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *LayoutTableState = @ptrCast(@alignCast(ctx.state.?));
    const id: ElementId = .{ .index = @truncate(ctx.iter_index % 1000), .generation = 0 };
    const e = state.table.epoch(id);
    ctx.blackbox(e);
}

// ============================================================================
// Signal alone (无 observer) - 测 set 的最低开销
// ============================================================================

const SignalAloneState = struct {
    owner: *SignalOwner,
    sig: *Signal(i32),
    target: i32,
};

fn signalAloneSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const sig = try Signal(i32).create(owner, 0);
    const state = try allocator.create(SignalAloneState);
    state.* = .{ .owner = owner, .sig = sig, .target = 0 };
    return @ptrCast(state);
}

fn signalAloneTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *SignalAloneState = @ptrCast(@alignCast(ptr));
    state.owner.deinit();
    allocator.destroy(state);
}

fn signalAloneBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *SignalAloneState = @ptrCast(@alignCast(ctx.state.?));
    state.target +%= 1;
    state.sig.set(state.target);
    ctx.blackbox(state.target);
}

// ============================================================================
// Signal create + immediate set + 不创建 effect
// ============================================================================

fn signalCreateBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = ctx;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();
    const sig = try Signal(i32).create(owner, 0);
    sig.set(42);
}

// ============================================================================
// owner.deinit 1k signals
// ============================================================================

fn ownerDeinitBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = ctx;
    // 每次 iter create + deinit 一个新 owner with 1k signals
    var owner = try SignalOwner.init(allocator);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        _ = try Signal(i32).create(owner, 0);
    }
    owner.deinit();
}

// ============================================================================
// PaintTable content_hash 命中率
// 模拟 paint pass：1000 次 beginRecord，前 800 次同 hash 应直接 cache hit。
// ============================================================================

const PaintCacheState = struct {
    table: PaintTable,
    target_id: ElementId,
};

fn paintCacheSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    var t = PaintTable.init(allocator);
    errdefer t.deinit();

    const eid: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(eid);
    // 初次录制建立 cache
    _ = try t.beginRecord(eid, 0xCAFEBABE);
    try t.pushItem(eid, .{
        .kind = .rect,
        .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 },
    });
    t.endRecord(eid, .NONE);

    const state = try allocator.create(PaintCacheState);
    state.* = .{ .table = t, .target_id = eid };
    return @ptrCast(state);
}

fn paintCacheTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *PaintCacheState = @ptrCast(@alignCast(ptr));
    state.table.deinit();
    allocator.destroy(state);
}

fn paintCacheBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *PaintCacheState = @ptrCast(@alignCast(ctx.state.?));
    // 同 hash → 永远命中 → 不重新录制
    const hit = !(try state.table.beginRecord(state.target_id, 0xCAFEBABE));
    ctx.blackbox(hit);
}

// ============================================================================
// ElementId 打包/解包 hot path
// ============================================================================

fn elementIdRoundtripBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const id: ElementId = .{
        .index = @truncate(ctx.iter_index),
        .generation = @truncate(ctx.iter_index >> 24),
    };
    const raw = id.raw();
    const back = ElementId.fromRaw(raw);
    ctx.blackbox(back);
}

// ============================================================================
// PaintTable 重新录制 (hash mismatch) 路径
// 模拟 reactive 触发 paint chunk 失效后的重录开销
// ============================================================================

const PaintRecordState = struct {
    table: PaintTable,
    target_id: ElementId,
    counter: u64,
};

fn paintRecordSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    var t = PaintTable.init(allocator);
    errdefer t.deinit();

    const eid: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(eid);

    const state = try allocator.create(PaintRecordState);
    state.* = .{ .table = t, .target_id = eid, .counter = 0 };
    return @ptrCast(state);
}

fn paintRecordTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *PaintRecordState = @ptrCast(@alignCast(ptr));
    state.table.deinit();
    allocator.destroy(state);
}

fn paintRecordBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *PaintRecordState = @ptrCast(@alignCast(ctx.state.?));
    state.counter +%= 1;
    // 每次 hash 不同 → 必须重新录制
    const new_hash = state.counter;
    _ = try state.table.beginRecord(state.target_id, new_hash);
    try state.table.pushItem(state.target_id, .{
        .kind = .rect,
        .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 },
    });
    try state.table.pushItem(state.target_id, .{
        .kind = .text,
        .local_bounds = .{ .min_x = 5, .min_y = 5, .max_x = 95, .max_y = 45 },
    });
    state.table.endRecord(state.target_id, .NONE);
}

// ============================================================================
// PromotionHint shouldPromote fast path
// ============================================================================

fn promotionHintShouldBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const h: PromotionHint = if ((ctx.iter_index & 0x7) == 0)
        .{ .is_scroll_container = true }
    else
        .{};
    const should = h.shouldPromote();
    ctx.blackbox(should);
}

// ============================================================================
// PromotionHint primaryReason 分支序列
// ============================================================================

fn promotionHintReasonBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const i = ctx.iter_index & 0xF;
    const h: PromotionHint = .{
        .transform_animating = (i == 0),
        .opacity_animating = (i == 1),
        .is_scroll_container = (i == 2),
        .will_change = (i == 3),
        .has_filter = (i == 4),
        .has_3d_transform = (i == 5),
    };
    const reason = h.primaryReason();
    ctx.blackbox(reason);
}

// ============================================================================
// PromotionHint pack/unpack u8 ↔ struct
// ============================================================================

fn promotionHintPackBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const h: PromotionHint = .{
        .transform_animating = ((ctx.iter_index & 1) == 0),
        .is_scroll_container = ((ctx.iter_index & 2) == 0),
    };
    const raw: u8 = @bitCast(h);
    const back: PromotionHint = @bitCast(raw);
    ctx.blackbox(back);
}

// ============================================================================
// encodeOne 单 DisplayItem → GpuDraw 转换
// ============================================================================

fn encodeOneBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const kind: paint_table.DisplayItemKind = switch (ctx.iter_index & 0x3) {
        0 => .rect,
        1 => .text,
        2 => .image,
        else => .path,
    };
    const item: DisplayItem = .{
        .kind = kind,
        .resource_handle = ctx.iter_index,
    };
    const draw = encodeOne(item, 5);
    ctx.blackbox(draw);
}

// ============================================================================
// encodeStream 100 同质 rect → 1 batch
// ============================================================================

const StreamState = struct {
    items: [100]DisplayItem,
    out: [100]GpuDraw,
};

fn streamSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(StreamState);
    for (&state.items) |*item| {
        item.* = .{ .kind = .rect };
    }
    return @ptrCast(state);
}

fn streamTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *StreamState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn streamHomogeneousBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *StreamState = @ptrCast(@alignCast(ctx.state.?));
    const written = encodeStream(&state.items, 0, &state.out);
    ctx.blackbox(written);
}

// ============================================================================
// encodeStream 50 rect + 50 text 交替 → 100 separate batches
// (worst case：完全无 batching)
// ============================================================================

fn streamWorstCaseSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(StreamState);
    for (&state.items, 0..) |*item, i| {
        item.* = .{
            .kind = if ((i & 1) == 0) .rect else .text,
            .resource_handle = i,
        };
    }
    return @ptrCast(state);
}

fn streamWorstCaseBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *StreamState = @ptrCast(@alignCast(ctx.state.?));
    const written = encodeStream(&state.items, 0, &state.out);
    ctx.blackbox(written);
}

// ============================================================================
// BiDi splitRuns 混合脚本（拉丁 + 阿拉伯）
//
// ⚠ 这是**孤立模块**的 microbenchmark，不代表框架支持 RTL。
// src/i18n/bidi.zig 未接入渲染管线（本 benchmark 是它唯一的调用点），
// 详见该文件头部说明。别把这条 benchmark 的存在当成 RTL 可用的证据。
// ============================================================================

const BidiBenchState = struct {
    text: []const u8,
    runs: std.ArrayListUnmanaged(i18n.Run),
    allocator: std.mem.Allocator,
};

fn bidiSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(BidiBenchState);
    // "Hello مرحبا World" - 混合 LTR/RTL
    state.* = .{
        .text = "Hello \xD9\x85\xD8\xB1\xD8\xAD\xD8\xA8\xD8\xA7 World",
        .runs = .{},
        .allocator = allocator,
    };
    return @ptrCast(state);
}

fn bidiTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *BidiBenchState = @ptrCast(@alignCast(ptr));
    state.runs.deinit(state.allocator);
    allocator.destroy(state);
}

fn bidiBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *BidiBenchState = @ptrCast(@alignCast(ctx.state.?));
    state.runs.clearRetainingCapacity();
    try i18n.splitRuns(state.text, .ltr, &state.runs, state.allocator);
    ctx.blackbox(state.runs.items.len);
}

// ============================================================================
// linebreak findBreakOpportunities (CJK 文本)
// ============================================================================

const LineBreakBenchState = struct {
    text: []const u8,
    breaks: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
};

fn linebreakSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(LineBreakBenchState);
    // 30 个 CJK 字符（每个 3 字节）
    state.* = .{
        .text = "中文段落示例显示如何处理换行符号在常规情况下表现得很好",
        .breaks = .{},
        .allocator = allocator,
    };
    return @ptrCast(state);
}

fn linebreakTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *LineBreakBenchState = @ptrCast(@alignCast(ptr));
    state.breaks.deinit(state.allocator);
    allocator.destroy(state);
}

fn linebreakBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *LineBreakBenchState = @ptrCast(@alignCast(ctx.state.?));
    state.breaks.clearRetainingCapacity();
    try i18n.findBreakOpportunities(state.text, &state.breaks, state.allocator);
    ctx.blackbox(state.breaks.items.len);
}

// ============================================================================
// ShapingCache lookup hit (hot path)
// ============================================================================

const ShapingState = struct {
    cache: ShapingCache,
    key: ShapingKey,
};

fn shapingSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(ShapingState);
    state.* = .{
        .cache = ShapingCache.init(allocator, 256),
        .key = .{ .text_hash = 0xCAFEBABE, .text_len = 11, .font_id = 0, .max_width = 0, .font_size = 14 },
    };
    state.cache.beginFrame();

    // 预填充 cache
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 8 },
        .{ .glyph_id = 2, .x_advance = 7 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 },
    };
    try state.cache.insert(state.key, &glyphs, &clusters, .{
        .ascent = 12,
        .descent = 4,
        .line_gap = 2,
        .font_size = 14,
    }, .ltr, 15);

    return @ptrCast(state);
}

fn shapingTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *ShapingState = @ptrCast(@alignCast(ptr));
    state.cache.deinit();
    allocator.destroy(state);
}

fn shapingBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ShapingState = @ptrCast(@alignCast(ctx.state.?));
    const got = state.cache.lookup(state.key);
    ctx.blackbox(got);
}

// ============================================================================
// a11y_tree upsert 100 nodes
// ============================================================================

const A11yState_bench = struct {
    tree: AccessibilityTree,
};

fn a11ySetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(A11yState_bench);
    state.* = .{ .tree = AccessibilityTree.init(allocator) };
    return @ptrCast(state);
}

fn a11yTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *A11yState_bench = @ptrCast(@alignCast(ptr));
    state.tree.deinit();
    allocator.destroy(state);
}

fn a11yUpsertBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *A11yState_bench = @ptrCast(@alignCast(ctx.state.?));
    const eid: ElementId = .{ .index = @truncate(ctx.iter_index & 0x7F), .generation = 0 };
    try state.tree.upsert(.{
        .element = eid,
        .role = .button,
        .state = .{ .focusable = true },
        .label_hash = ctx.iter_index,
    });
    // 清 dirty 防止内存爆涨
    if ((ctx.iter_index & 0xFF) == 0xFF) {
        state.tree.dirty.clearRetainingCapacity();
    }
}

// ============================================================================
// GestureArena dispatch（tap recognition）
// ============================================================================

const GestureBenchState = struct {
    arena: GestureArena,
    counter: u64,
};

fn gestureSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(GestureBenchState);
    state.* = .{ .arena = GestureArena.init(allocator), .counter = 0 };
    _ = try state.arena.addRecognizer(.{
        .kind = .tap,
        .target = .{ .index = 1, .generation = 0 },
    });
    return @ptrCast(state);
}

fn gestureTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *GestureBenchState = @ptrCast(@alignCast(ptr));
    state.arena.deinit();
    allocator.destroy(state);
}

fn gestureBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *GestureBenchState = @ptrCast(@alignCast(ctx.state.?));
    state.counter +%= 1;
    state.arena.reset();
    state.arena.onTouchDown(50, 50, @intCast(state.counter * 1000));
    state.arena.onTouchUp(51, 51, @intCast(state.counter * 1000 + 1_000_000));
    ctx.blackbox(state.arena.recognizers.items[0].state);
}

// ============================================================================
// a11y dirty mark + state diff detection
// ============================================================================

fn a11yDiffBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *A11yState_bench = @ptrCast(@alignCast(ctx.state.?));
    const eid: ElementId = .{ .index = 0, .generation = 0 };
    // 偶数 iter：checked=true；奇数：checked=false。每次 upsert 应触发 state_changed dirty
    try state.tree.upsert(.{
        .element = eid,
        .role = .checkbox,
        .state = .{ .checked = (ctx.iter_index & 1) == 0 },
    });
    if ((ctx.iter_index & 0xFF) == 0xFF) {
        state.tree.dirty.clearRetainingCapacity();
    }
}

// ============================================================================
// ControlledProp read (uncontrolled mode)
// ============================================================================

fn controlledReadBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const Prop = ControlledProp(i32);
    const p: Prop = .{ .uncontrolled = .{ .default = 42 } };
    const internal: i32 = @intCast(ctx.iter_index & 0xFFFF);
    const got = p.read(internal);
    ctx.blackbox(got);
}

// ============================================================================
// ControlledProp write (uncontrolled mode 写 internal)
// ============================================================================

const ControlledWriteState = struct {
    internal: i32,
};

fn controlledWriteSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(ControlledWriteState);
    state.* = .{ .internal = 0 };
    return @ptrCast(state);
}

fn controlledWriteTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *ControlledWriteState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn controlledWriteBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *ControlledWriteState = @ptrCast(@alignCast(ctx.state.?));
    const Prop = ControlledProp(i32);
    const p: Prop = .{ .uncontrolled = .{ .default = 0 } };
    p.write(&state.internal, @intCast(ctx.iter_index & 0xFFFF));
    ctx.blackbox(state.internal);
}

// ============================================================================
// Select state machine step (arrow_down + commit)
// ============================================================================

const SelectBenchState = struct {
    state: select_headless.SelectState(i32),
    options: [10]select_headless.Option(i32),
};

fn selectSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const state = try allocator.create(SelectBenchState);
    state.* = .{
        .state = select_headless.SelectState(i32).init(.{}),
        .options = undefined,
    };
    for (&state.options, 0..) |*opt, i| {
        opt.* = .{ .value = @intCast(i), .label = "Option" };
    }
    return @ptrCast(state);
}

fn selectTeardown(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const state: *SelectBenchState = @ptrCast(@alignCast(ptr));
    allocator.destroy(state);
}

fn selectStepBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *SelectBenchState = @ptrCast(@alignCast(ctx.state.?));
    select_headless.step(i32, &state.state, &state.options, .arrow_down, 0);
    ctx.blackbox(state.state.highlight_index);
}

// ============================================================================
// Registration + main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var filter: ?[]const u8 = null;
    var json_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "json=")) {
            json_path = arg[5..];
        } else if (std.mem.startsWith(u8, arg, "name=")) {
            filter = arg[5..];
        } else if (filter == null) {
            filter = arg;
        }
    }

    const cases = [_]runner.BenchCase{
        .{
            .name = "reactive_1k_signal_fanout",
            .setup = fanoutSetup,
            .teardown = fanoutTeardown,
            .body = fanoutBody,
        },
        // v0.2-P1 新增（每 phase ≥ 3 条 bench gate 强制）
        .{
            .name = "reactive_diamond_no_glitch_set",
            .setup = diamondSetup,
            .teardown = diamondTeardown,
            .body = diamondBody,
        },
        .{
            .name = "reactive_lazy_memo_unused",
            .setup = lazyMemoSetup,
            .teardown = lazyMemoTeardown,
            .body = lazyMemoBody,
        },
        .{
            .name = "reactive_topological_chain_10",
            .setup = chainSetup,
            .teardown = chainTeardown,
            .body = chainBody,
        },
        .{
            .name = "resource_pool_alloc_release_cycle",
            .setup = poolSetup,
            .teardown = poolTeardown,
            .body = poolBody,
        },
        .{
            .name = "slotmap_alloc_free_cycle",
            .setup = slotSetup,
            .teardown = slotTeardown,
            .body = slotBody,
        },
        // v0.2-P2 新增（每 phase ≥ 3 条 bench gate 强制）
        .{
            .name = "element_table_10k_dfs_traverse",
            .setup = treeSetup,
            .teardown = treeTeardown,
            .body = tree10kTraverseBody,
        },
        .{
            .name = "intrinsic_cache_get",
            .setup = cacheSetup,
            .teardown = cacheTeardown,
            .body = cacheLookupBody,
        },
        .{
            .name = "element_table_unlink_relink",
            .setup = treeSetup,
            .teardown = treeTeardown,
            .body = unlinkBody,
        },
        // v0.2-P3 新增（每 phase ≥ 3 条 bench gate 强制）
        .{
            .name = "paint_chunk_content_hash_hit",
            .setup = paintCacheSetup,
            .teardown = paintCacheTeardown,
            .body = paintCacheBody,
        },
        .{
            .name = "element_id_packed_roundtrip",
            .setup = null,
            .teardown = null,
            .body = elementIdRoundtripBody,
        },
        .{
            .name = "paint_chunk_record_2_items",
            .setup = paintRecordSetup,
            .teardown = paintRecordTeardown,
            .body = paintRecordBody,
        },
        // v0.2-P4 新增（layer_tree 真集成 bench 等 v0.3 主路径切换；
        // 当前测算法层面 PromotionHint 的 fast path）
        .{
            .name = "promotion_hint_should_promote",
            .setup = null,
            .teardown = null,
            .body = promotionHintShouldBody,
        },
        .{
            .name = "promotion_hint_primary_reason",
            .setup = null,
            .teardown = null,
            .body = promotionHintReasonBody,
        },
        .{
            .name = "promotion_hint_pack_unpack",
            .setup = null,
            .teardown = null,
            .body = promotionHintPackBody,
        },
        // v0.2-P5 新增
        .{
            .name = "encode_one_display_item",
            .setup = null,
            .teardown = null,
            .body = encodeOneBody,
        },
        .{
            .name = "encode_stream_100_rect_homogeneous",
            .setup = streamSetup,
            .teardown = streamTeardown,
            .body = streamHomogeneousBody,
        },
        .{
            .name = "encode_stream_100_alternating_worst_case",
            .setup = streamWorstCaseSetup,
            .teardown = streamTeardown,
            .body = streamWorstCaseBody,
        },
        // v0.2-P6 新增
        .{
            .name = "bidi_split_runs_mixed_lr_rtl",
            .setup = bidiSetup,
            .teardown = bidiTeardown,
            .body = bidiBody,
        },
        .{
            .name = "linebreak_find_breaks_cjk_30",
            .setup = linebreakSetup,
            .teardown = linebreakTeardown,
            .body = linebreakBody,
        },
        .{
            .name = "shaping_cache_lookup_hit",
            .setup = shapingSetup,
            .teardown = shapingTeardown,
            .body = shapingBody,
        },
        // v0.2-P7 新增
        .{
            .name = "a11y_tree_upsert",
            .setup = a11ySetup,
            .teardown = a11yTeardown,
            .body = a11yUpsertBody,
        },
        .{
            .name = "gesture_arena_tap_dispatch",
            .setup = gestureSetup,
            .teardown = gestureTeardown,
            .body = gestureBody,
        },
        .{
            .name = "a11y_state_diff_detect",
            .setup = a11ySetup,
            .teardown = a11yTeardown,
            .body = a11yDiffBody,
        },
        // v0.2-P8 新增
        .{
            .name = "controlled_prop_read",
            .setup = null,
            .teardown = null,
            .body = controlledReadBody,
        },
        .{
            .name = "controlled_prop_write",
            .setup = controlledWriteSetup,
            .teardown = controlledWriteTeardown,
            .body = controlledWriteBody,
        },
        .{
            .name = "select_state_machine_arrow_down",
            .setup = selectSetup,
            .teardown = selectTeardown,
            .body = selectStepBody,
        },
        // v0.3-P1 新增
        .{
            .name = "reactive_signal_alone_no_effect",
            .setup = signalAloneSetup,
            .teardown = signalAloneTeardown,
            .body = signalAloneBody,
        },
        .{
            .name = "reactive_signal_create_set_destroy",
            .setup = null,
            .teardown = null,
            .body = signalCreateBody,
        },
        .{
            .name = "reactive_owner_deinit_1k_signals",
            .setup = null,
            .teardown = null,
            .body = ownerDeinitBody,
        },
        // v0.3-P2 新增
        .{
            .name = "layout_table_mark_laid_out",
            .setup = layoutTableSetup,
            .teardown = layoutTableTeardown,
            .body = layoutTableMarkLaidOutBody,
        },
        .{
            .name = "layout_table_rect_read",
            .setup = layoutTableSetup,
            .teardown = layoutTableTeardown,
            .body = layoutTableRectReadBody,
        },
        .{
            .name = "layout_table_epoch_read",
            .setup = layoutTableSetup,
            .teardown = layoutTableTeardown,
            .body = layoutTableEpochReadBody,
        },
        // v0.3-P3 新增（ElementId first-class 路径）
        .{
            .name = "element_id_is_valid_check",
            .setup = elementWorldSetup,
            .teardown = elementWorldTeardown,
            .body = elementIsValidBody,
        },
        .{
            .name = "element_tag_read_via_id",
            .setup = elementWorldSetup,
            .teardown = elementWorldTeardown,
            .body = elementTagReadBody,
        },
        .{
            .name = "element_links_read_via_id",
            .setup = elementWorldSetup,
            .teardown = elementWorldTeardown,
            .body = elementLinksReadBody,
        },
        // v0.3-P4 新增
        .{
            .name = "scroll_offset_update_1k_nodes",
            .setup = scrollArraySetup,
            .teardown = scrollArrayTeardown,
            .body = scrollOffsetUpdateBody,
        },
        .{
            .name = "promotion_hint_collect_1k",
            .setup = hintCollectSetup,
            .teardown = hintCollectTeardown,
            .body = hintCollectBody,
        },
        .{
            .name = "scroll_node_lookup_by_index",
            .setup = scrollArraySetup,
            .teardown = scrollArrayTeardown,
            .body = scrollLookupBody,
        },
        // v0.3-P5 新增
        .{
            .name = "encode_dashboard_typical",
            .setup = dashboardSetup,
            .teardown = dashboardTeardown,
            .body = dashboardEncodeBody,
        },
        .{
            .name = "shaping_cache_warm_hit",
            .setup = shapingWarmSetup,
            .teardown = shapingWarmTeardown,
            .body = shapingWarmBody,
        },
        .{
            .name = "glyphrun_xtocluster_complex",
            .setup = xToClusterSetup,
            .teardown = xToClusterTeardown,
            .body = xToClusterBody,
        },
        // v0.3-P6 新增
        .{
            .name = "a11y_tree_drain_dirty",
            .setup = a11yDrainSetup,
            .teardown = a11yDrainTeardown,
            .body = a11yDrainBody,
        },
        .{
            .name = "select_headless_typeahead_match",
            .setup = typeaheadSetup,
            .teardown = selectTeardown,
            .body = typeaheadBody,
        },
        .{
            .name = "a11y_tree_children_50",
            .setup = a11yChildrenSetup,
            .teardown = a11yChildrenTeardown,
            .body = a11yChildrenBody,
        },
        // v0.4-P1 新增
        .{
            .name = "intrinsic_cache_miss_put",
            .setup = intrinsicCacheMissSetup,
            .teardown = intrinsicCacheMissTeardown,
            .body = intrinsicCacheMissBody,
        },
        .{
            .name = "layout_table_epoch_scan_1k",
            .setup = layoutTableSetup,
            .teardown = layoutTableTeardown,
            .body = layoutEpochScanBody,
        },
        .{
            .name = "available_space_constraint_pass",
            .setup = null,
            .teardown = null,
            .body = availableSpaceTransformBody,
        },
        // v0.4-P2 新增（v0.5 真删除 render IR 前的算法层 baseline）
        .{
            .name = "bounds_union_256_chunks",
            .setup = boundsSetup,
            .teardown = boundsTeardown,
            .body = boundsUnionBody,
        },
        .{
            .name = "paint_chunk_invalidate_1k",
            .setup = paintBatchSetup,
            .teardown = paintBatchTeardown,
            .body = paintBatchInvalidateBody,
        },
        .{
            .name = "property_state_ref_pack_unpack",
            .setup = null,
            .teardown = null,
            .body = propertyStateRefBody,
        },
        // v0.4-P3 新增（v0.5 拆 Node 字段前的 4 表路径 baseline）
        .{
            .name = "element_create_append_100",
            .setup = null,
            .teardown = null,
            .body = elementCreateAppendBody,
        },
        .{
            .name = "four_tables_ensure_slot",
            .setup = fourTablesSetup,
            .teardown = fourTablesTeardown,
            .body = fourTablesEnsureBody,
        },
        .{
            .name = "element_id_hot_path_1k",
            .setup = null,
            .teardown = null,
            .body = elementIdHotPathBody,
        },
        // 真测 plan 矩阵 #2 "单 signal 改色 → paint" 端到端
        .{
            .name = "single_signal_color_change_paint",
            .setup = singleSignalColorSetup,
            .teardown = singleSignalColorTeardown,
            .body = singleSignalColorBody,
        },
        .{
            .name = "signal_color_change_10_buttons_realistic",
            .setup = realisticSetup,
            .teardown = realisticTeardown,
            .body = realisticBody,
        },
        // v0.5-P3 frame-level scenario benches (§5 退出标准 #1/#3/#4/#5/#8)。
        // 起步：#1 10k 节点零脏帧，目标 < 0.5ms。
        .{
            .name = "frame_10k_nodes_zero_dirty_relayout",
            .setup = frameZeroDirty10kSetup,
            .teardown = frameZeroDirty10kTeardown,
            .body = frameZeroDirty10kBody,
        },
        .{
            .name = "frame_dashboard_drawcall_count",
            .setup = frameDashboardSetup,
            .teardown = frameDashboardTeardown,
            .body = frameDashboardBody,
        },
        .{
            .name = "frame_diamond_set_no_double_paint",
            .setup = frameDiamondSetup,
            .teardown = frameDiamondTeardown,
            .body = frameDiamondBody,
        },
        .{
            .name = "frame_scrollarea_1k_items_scroll",
            .setup = frameScrollSetup,
            .teardown = frameScrollTeardown,
            .body = frameScrollBody,
        },
        .{
            .name = "frame_transform_promoted_no_paint",
            .setup = frameTransformSetup,
            .teardown = frameTransformTeardown,
            .body = frameTransformBody,
        },
        .{
            .name = "frame_select_1k_keyboard_pagedown",
            .setup = frameSelect1kSetup,
            .teardown = frameSelect1kTeardown,
            .body = frameSelect1kBody,
        },
    };

    var json_file: ?std.fs.File = null;
    defer if (json_file) |f| f.close();
    if (json_path) |p| {
        json_file = try std.fs.cwd().createFile(p, .{ .truncate = true });
    }

    try runner.run(allocator, &cases, filter, json_file);
}

// ============================================================================
// v0.5-P3 Frame-level scenario benches —— v0.5 §5 退出标准 #1/#3/#4/#5/#8
//
// 与上方 micro bench 不同：这一组吃完整 Cx (init/setViewport/layout/render)
// 路径，目标是在帧级 wall-clock 上 gate 退出标准的真数字。详见
// docs/V05_ALIGNMENT_PLAN.md §5。
//
// 起步 case：#1 frame_10k_nodes_zero_dirty_relayout —— 10k 节点零脏帧。
// 命中 cx.render() 的 fast-path（time_unchanged + isTreeFullyClean），
// 模拟生产 idle frame 的实际开销。
// ============================================================================

const Cx = zenit.Cx;
const Node = zenit.Node;
const Color = zenit.Color;
const Style = zenit.Style;
const Padding = zenit.Padding;

const FrameZeroDirtyState = struct {
    cx: *Cx,
};

fn frameZeroDirty10kSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const cx = try Cx.init(allocator);
    errdefer cx.deinit();
    cx.setViewport(1280, 800);

    // 直接命令式 build：root 一个 vstack，下挂 100 个 row，每 row 100 个 leaf
    // text-less 占位 box → 共 100*100 + 100 + 1 = 10101 ≈ 10k 节点。
    // 不用 ui.box() 的 tuple API（10k 不能字面量化），而是 Node.create +
    // cx.linkNodeToWorld + parent.appendChild —— 与 box() 内部完全等价。
    const ui_core = zenit.ui_core;
    const root = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 1280 },
            .height = .{ .px = 800 },
            .direction = .column,
        },
    );
    cx.linkNodeToWorld(root);

    const rows: u32 = 100;
    const cols: u32 = 100;
    var ri: u32 = 0;
    while (ri < rows) : (ri += 1) {
        const row = try ui_core.Node.create(
            allocator,
            cx.nextId(),
            .box,
            Style{ .direction = .row },
        );
        cx.linkNodeToWorld(row);
        try root.appendChild(allocator, row);

        var ci: u32 = 0;
        while (ci < cols) : (ci += 1) {
            const leaf = try ui_core.Node.create(
                allocator,
                cx.nextId(),
                .box,
                Style{
                    .width = .{ .px = 12 },
                    .height = .{ .px = 8 },
                },
            );
            cx.linkNodeToWorld(leaf);
            leaf.setBackgroundRaw(Color.rgba(40, 60, 90, 255));
            try row.appendChild(allocator, leaf);
        }
    }

    cx.root = root;
    // 先跑一次完整 layout + render，把 dirty bits 全清掉、display_list 缓存
    // 填好。后续 body 调用都走 fast-path。
    cx.layout();
    _ = cx.render();

    // sanity: 节点真的建起来了 + display_list 真有内容
    std.debug.assert(root.children.items.len == rows);
    std.debug.assert(root.children.items[0].children.items.len == cols);
    std.debug.assert(cx.display_list.count() > 0);

    const state = try allocator.create(FrameZeroDirtyState);
    state.* = .{ .cx = cx };
    return @ptrCast(state);
}

fn frameZeroDirty10kTeardown(allocator: std.mem.Allocator, state_ptr: *anyopaque) void {
    const state: *FrameZeroDirtyState = @ptrCast(@alignCast(state_ptr));
    state.cx.deinit();
    allocator.destroy(state);
}

fn frameZeroDirty10kBody(_: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const state: *FrameZeroDirtyState = @ptrCast(@alignCast(ctx.state.?));
    // 不改 frame_time_ms → time_unchanged → render() 走 fast-path return cache。
    // layout() 早返（had_dirty == false）；render() 早返（fully clean + cache valid）。
    state.cx.layout();
    const items = state.cx.render();
    ctx.blackbox(items.len);
}

// ----------------------------------------------------------------------------
// #5 frame_dashboard_drawcall_count — typical dashboard 画面，draw call < 600
//
// dashboard fixture：header bar + sidebar (12 nav items) + main 4×4 card grid
// (16 cards × 3 text + 1 background = 4 nodes/card)。每节点产 1 fill_rect (背
// 景色) + text 节点产 1 text_run，总 display_item 期望 ~150-250。门槛 600 给
// 真实工程量留 2-3× margin（v0.5 §5 退出标准 #5）。
// ----------------------------------------------------------------------------

const FrameDashboardState = struct {
    cx: *Cx,
    initial_drawcall_count: usize,
};

fn buildCardNode(allocator: std.mem.Allocator, cx: *Cx, idx: u32) anyerror!*Node {
    const ui_core = zenit.ui_core;
    const card = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 200 },
            .height = .{ .px = 120 },
            .direction = .column,
            .padding = Padding.all(12),
        },
    );
    cx.linkNodeToWorld(card);
    card.setBackgroundRaw(Color.rgba(28, 32, 38, 255));

    const title = try ui_core.text(cx, "Card Title", .{
        .font_size = 14,
        .font_weight = 600,
        .color = Color.rgba(220, 224, 230, 255),
    });
    try card.appendChild(allocator, title);

    // 用一个简短数字字符串作为 value (avoid allocator-owned format)
    const value_strings = [_][]const u8{
        "42",  "108", "256", "512",  "1024", "2048", "4096", "8192",
        "16K", "32K", "64K", "128K", "256K", "512K", "1M",   "2M",
    };
    const value = try ui_core.text(cx, value_strings[idx % value_strings.len], .{
        .font_size = 24,
        .font_weight = 700,
        .color = Color.rgba(240, 240, 240, 255),
    });
    try card.appendChild(allocator, value);

    const sub = try ui_core.text(cx, "vs last week", .{
        .font_size = 12,
        .color = Color.rgba(140, 150, 160, 255),
    });
    try card.appendChild(allocator, sub);

    return card;
}

fn frameDashboardSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const cx = try Cx.init(allocator);
    errdefer cx.deinit();
    cx.setViewport(1280, 800);

    const ui_core = zenit.ui_core;

    const root = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 1280 },
            .height = .{ .px = 800 },
            .direction = .column,
        },
    );
    cx.linkNodeToWorld(root);
    root.setBackgroundRaw(Color.rgba(18, 20, 24, 255));

    // header bar (40px tall, 5 quick actions)
    const header = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 1280 },
            .height = .{ .px = 40 },
            .direction = .row,
            .padding = Padding.all(8),
            .gap = 12,
        },
    );
    cx.linkNodeToWorld(header);
    header.setBackgroundRaw(Color.rgba(22, 26, 32, 255));
    try root.appendChild(allocator, header);
    const header_labels = [_][]const u8{ "Dashboard", "Analytics", "Reports", "Settings", "Profile" };
    for (header_labels) |label| {
        const item = try ui_core.text(cx, label, .{ .font_size = 13, .color = Color.rgba(200, 205, 215, 255) });
        try header.appendChild(allocator, item);
    }

    // body row: sidebar + main
    const body = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .direction = .row,
        },
    );
    cx.linkNodeToWorld(body);
    try root.appendChild(allocator, body);

    // sidebar (12 nav items)
    const sidebar = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 200 },
            .height = .{ .px = 760 },
            .direction = .column,
            .padding = Padding.all(8),
            .gap = 4,
        },
    );
    cx.linkNodeToWorld(sidebar);
    sidebar.setBackgroundRaw(Color.rgba(22, 26, 32, 255));
    try body.appendChild(allocator, sidebar);
    const nav_labels = [_][]const u8{
        "Overview", "Traffic",  "Sources", "Pages",     "Events",   "Funnels",
        "Cohorts",  "Segments", "Goals",   "Campaigns", "Settings", "Help",
    };
    for (nav_labels) |label| {
        const nav_row = try ui_core.Node.create(
            allocator,
            cx.nextId(),
            .box,
            Style{
                .width = .{ .px = 184 },
                .height = .{ .px = 32 },
                .padding = Padding.all(8),
            },
        );
        cx.linkNodeToWorld(nav_row);
        nav_row.setBackgroundRaw(Color.rgba(28, 34, 42, 255));
        try sidebar.appendChild(allocator, nav_row);
        const nav_text = try ui_core.text(cx, label, .{
            .font_size = 13,
            .color = Color.rgba(180, 190, 200, 255),
        });
        try nav_row.appendChild(allocator, nav_text);
    }

    // main content grid 4×4 cards
    const main_pane = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 1080 },
            .height = .{ .px = 760 },
            .direction = .column,
            .padding = Padding.all(16),
            .gap = 12,
        },
    );
    cx.linkNodeToWorld(main_pane);
    try body.appendChild(allocator, main_pane);

    // 6×6 = 36 cards × 4 nodes = ~144 + sidebar/header/structural ≈ 200+
    // display_items，给 600 阈值留 ~3× headroom 但又是真实工程量。
    var row_i: u32 = 0;
    while (row_i < 6) : (row_i += 1) {
        const grid_row = try ui_core.Node.create(
            allocator,
            cx.nextId(),
            .box,
            Style{ .direction = .row, .gap = 12 },
        );
        cx.linkNodeToWorld(grid_row);
        try main_pane.appendChild(allocator, grid_row);
        var col_i: u32 = 0;
        while (col_i < 6) : (col_i += 1) {
            const idx = row_i * 6 + col_i;
            const card = try buildCardNode(allocator, cx, idx);
            try grid_row.appendChild(allocator, card);
        }
    }

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const drawcall_count = cx.lowerForEncoderPaintTable().len;
    // §5 退出标准 #5: typical dashboard < 600 draw calls。当前 fixture
    // (header + 16 nav + 36 cards × 4 nodes) ≈ 176 display_items，~3.4×
    // headroom。assert 是真 gate — 若回归到 600+ bench setup 直接 panic。
    std.debug.assert(drawcall_count > 30);
    std.debug.assert(drawcall_count < 600);

    const state = try allocator.create(FrameDashboardState);
    state.* = .{ .cx = cx, .initial_drawcall_count = drawcall_count };
    return @ptrCast(state);
}

fn frameDashboardTeardown(allocator: std.mem.Allocator, state_ptr: *anyopaque) void {
    const state: *FrameDashboardState = @ptrCast(@alignCast(state_ptr));
    state.cx.deinit();
    allocator.destroy(state);
}

fn frameDashboardBody(_: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const state: *FrameDashboardState = @ptrCast(@alignCast(ctx.state.?));
    state.cx.layout();
    _ = state.cx.render();
    const items = state.cx.lowerForEncoderPaintTable();
    ctx.blackbox(items.len);
}

// ----------------------------------------------------------------------------
// #8 frame_diamond_set_no_double_paint — diamond reactive 拓扑下，源 signal
// 翻动一次后单一节点 paint 只被重录一次 (no glitch / no double paint)。
//
// 树形 (cx 内 1 个 target_box)；reactive owner 单独 (与 cx 共享 allocator):
//   A: Signal(i32)
//   B: Memo  = A.get() * 10
//   C: Memo  = A.get() + 100
//   effect(B,C): target_box.setBackground(rgba based on B+C)
//
// 期望: A.set(N) → reactive 同步 propagate (B/C/effect 各跑一次拓扑序保证)
// → effect setBackground 让 target_box render-dirty → cx.render() 重录该
// 节点的 paint 一次 (display_list_own_prebuild_count == 1)。如果有 glitch
// 即 effect 跑 2 次或 paint pass 重录 2 次，count > 1 → setup 阶段断言失败。
//
// micro reactive_diamond_no_glitch_set 测纯 reactive；本 case 测 reactive +
// paint 复合的 frame 时长，作为 v0.5 §5 #8 的可量化 gate。
// ----------------------------------------------------------------------------

const FrameDiamondState = struct {
    cx: *Cx,
    target_box: *Node,
    owner: *SignalOwner,
    a: *Signal(i32),
    effect_run_count: *u64,
    target_value: i32 = 0,
};

fn frameDiamondSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const cx = try Cx.init(allocator);
    errdefer cx.deinit();
    cx.setViewport(800, 600);

    const ui_core = zenit.ui_core;

    const root = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 800 },
            .height = .{ .px = 600 },
            .direction = .column,
        },
    );
    cx.linkNodeToWorld(root);

    const target_box = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 200 },
            .height = .{ .px = 200 },
        },
    );
    cx.linkNodeToWorld(target_box);
    target_box.setBackgroundRaw(Color.rgba(50, 80, 110, 255));
    try root.appendChild(allocator, target_box);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    // reactive graph: A → B(memo), A → C(memo), effect(B, C) → setBackground。
    // owner 与 cx 用同 allocator，但生命周期独立（cx.deinit 后 owner 仍需 deinit）。
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const a = try Signal(i32).create(owner, 0);
    const b = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(c: anytype) i32 {
            return c.a.get() * 10;
        }
    }.compute);
    const c = try createMemo(owner, i32, .{ .a = a }, struct {
        fn compute(cx_: anytype) i32 {
            return cx_.a.get() + 100;
        }
    }.compute);
    const counter = try allocator.create(u64);
    counter.* = 0;
    try createEffect(owner, .{
        .b = b,
        .c = c,
        .target_box = target_box,
        .counter = counter,
    }, struct {
        fn run(eff_ctx: anytype) void {
            const sum = eff_ctx.b.get() + eff_ctx.c.get();
            // 用 sum 派生 RGB；强制每次 set 颜色都不同 → 真触发 markRenderDirty
            const r: u8 = @intCast(@as(u32, @bitCast(sum)) & 0xFF);
            const g: u8 = @intCast((@as(u32, @bitCast(sum)) >> 8) & 0xFF);
            const b_ch: u8 = @intCast((@as(u32, @bitCast(sum)) >> 16) & 0xFF);
            eff_ctx.target_box.setBackground(zenit.Color.rgba(r, g, b_ch, 255));
            eff_ctx.counter.* +%= 1;
        }
    }.run);

    // ===== 真正的 #8 gate：a.set 后单帧 effect 拓扑序保证 ==========
    // effect 在 createEffect 时已立即 fire 一次（建立依赖），先 reset。
    counter.* = 0;
    a.set(42);
    // reactive diamond 拓扑保证: B/C 各重算 1 次，effect 跑 1 次（不 glitch
    // 成 2 次）。这是 §5 #8 的核心 gate。
    if (counter.* != 1) {
        std.debug.panic("frame_diamond: effect expected 1 fire after a.set, got {d} (glitch!)", .{counter.*});
    }
    // 验证 reactive 真正改了 node style + render dirty 路径活
    if (!target_box.frame_state.state_bits.dirty.core.render) {
        std.debug.panic("frame_diamond: setBackground 没触发 render dirty — reactive→paint 链断了", .{});
    }
    // 跑一帧消化 dirty，让稳态 body 跑在 dirty propagation 真实路径上
    cx.layout();
    _ = cx.render();

    const state = try allocator.create(FrameDiamondState);
    state.* = .{
        .cx = cx,
        .target_box = target_box,
        .owner = owner,
        .a = a,
        .effect_run_count = counter,
    };
    return @ptrCast(state);
}

fn frameDiamondTeardown(allocator: std.mem.Allocator, state_ptr: *anyopaque) void {
    const state: *FrameDiamondState = @ptrCast(@alignCast(state_ptr));
    state.owner.deinit();
    state.cx.deinit();
    allocator.destroy(state.effect_run_count);
    allocator.destroy(state);
}

fn frameDiamondBody(_: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const state: *FrameDiamondState = @ptrCast(@alignCast(ctx.state.?));
    state.target_value +%= 1;
    state.a.set(state.target_value); // reactive: B/C/effect 各 1 次
    state.cx.layout();
    _ = state.cx.render(); // paint pass: target_box 重录 1 次
    ctx.blackbox(state.effect_run_count.*);
}

// ----------------------------------------------------------------------------
// #3 frame_scrollarea_1k_items_scroll — 1k items 在 overflow_hidden 容器里
// scroll 一帧 < 3ms (60fps frame budget)。
//
// 不依赖 ScrollArea component (避免拉 components/scroll_area/* 进 facade)：
// 直接 raw cx 构 viewport (overflow_hidden, 固定高 600) + content (1k items)；
// scroll 通过 content.setTranslateY 模拟。setTranslateY 当前走 markRenderDirty
// (translate composite-only 路径未切)，所以这测的是 "content translate +
// 1k visible items 的 layout/render fast-path 整帧时长"，给 §5 #3 在 60fps
// 预算下做工程量级 gate。后续 translate 切到 composite-only 时数字会再降。
// ----------------------------------------------------------------------------

const FrameScrollState = struct {
    cx: *Cx,
    content: *Node,
    scroll_offset: f32 = 0,
};

fn frameScrollSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const cx = try Cx.init(allocator);
    errdefer cx.deinit();
    cx.setViewport(800, 600);

    const ui_core = zenit.ui_core;

    // root viewport: overflow_hidden + 固定 800×600
    const viewport = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 800 },
            .height = .{ .px = 600 },
            .direction = .column,
            .overflow_hidden = true,
        },
    );
    cx.linkNodeToWorld(viewport);
    viewport.setBackgroundRaw(Color.rgba(20, 24, 30, 255));

    // content pane: 1k items × 24px = 24000px 高
    const content = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 800 },
            .height = .{ .px = 24000 },
            .direction = .column,
        },
    );
    cx.linkNodeToWorld(content);
    try viewport.appendChild(allocator, content);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const row = try ui_core.Node.create(
            allocator,
            cx.nextId(),
            .box,
            Style{
                .width = .{ .px = 800 },
                .height = .{ .px = 24 },
                .padding = Padding.all(4),
            },
        );
        cx.linkNodeToWorld(row);
        row.setBackgroundRaw(if (i % 2 == 0) Color.rgba(28, 32, 38, 255) else Color.rgba(32, 36, 42, 255));
        try content.appendChild(allocator, row);

        // 简短 label，复用静态字符串避免 allocator 麻烦
        const labels = [_][]const u8{
            "Item A", "Item B", "Item C", "Item D", "Item E",
            "Item F", "Item G", "Item H", "Item I", "Item J",
        };
        const label_text = try ui_core.text(cx, labels[i % labels.len], .{
            .font_size = 13,
            .color = Color.rgba(200, 205, 215, 255),
        });
        try row.appendChild(allocator, label_text);
    }

    cx.root = viewport;
    cx.layout();
    _ = cx.render();

    // sanity: 真有 1000 row + 第一行有 text
    std.debug.assert(content.children.items.len == 1000);
    std.debug.assert(content.children.items[0].children.items.len == 1);

    const state = try allocator.create(FrameScrollState);
    state.* = .{ .cx = cx, .content = content };
    return @ptrCast(state);
}

fn frameScrollTeardown(allocator: std.mem.Allocator, state_ptr: *anyopaque) void {
    const state: *FrameScrollState = @ptrCast(@alignCast(state_ptr));
    state.cx.deinit();
    allocator.destroy(state);
}

fn frameScrollBody(_: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const state: *FrameScrollState = @ptrCast(@alignCast(ctx.state.?));
    // 模拟 scroll: 每帧 translate 5px。-12000 ~ 0 之间循环避免无限增长。
    // setTranslateY pub fn 已删 (v0.5 round 9 dead code cleanup)，走
    // setStyle(.translate_y, value) — translate_y 是非-ext 字段，无 allocator
    // 也能写。setStyle 的 .interaction dirty level 自动 markRenderDirty。
    state.scroll_offset -= 5.0;
    if (state.scroll_offset < -12000) state.scroll_offset = 0;
    state.content.setStyle(null, .translate_y, state.scroll_offset);
    state.cx.layout();
    _ = state.cx.render();
    ctx.blackbox(state.cx.display_list.count());
}

// ----------------------------------------------------------------------------
// #4 frame_transform_promoted_no_paint — will_change_transform 节点经 layer_tree
// promote 为 composited surface 后，setRotate 触发 composite-only 路径，
// paint 不重录 (display_list_own_prebuild_count == 0)。
//
// 核心 invariant 链 (markCompositeDirty in node.zig:1460):
//   self_needs_render_dirty = (promoted == null) and !isOutOfBandRenderUnit
// 节点 promoted=composited surface → self_needs_render_dirty=false → 不冒泡
// render dirty → render() 不重 paint 该节点 → prebuild_count == 0 当帧。
//
// 当前 setTranslateX 走 markRenderDirtyTracked (line 1148, translate
// composite-only 路径未切)，setRotate 走 markCompositeDirty (line 1176,
// 已切)，所以本 case 必用 setRotate。
// ----------------------------------------------------------------------------

const FrameTransformState = struct {
    cx: *Cx,
    target: *Node,
    rotate_value: f32 = 0,
};

fn frameTransformSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const cx = try Cx.init(allocator);
    errdefer cx.deinit();
    cx.setViewport(800, 600);

    const ui_core = zenit.ui_core;

    const root = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 800 },
            .height = .{ .px = 600 },
            .direction = .column,
        },
    );
    cx.linkNodeToWorld(root);

    // target: 200×200 will_change_transform 让 layer_tree promote 它。
    const target = try ui_core.Node.create(
        allocator,
        cx.nextId(),
        .box,
        Style{
            .width = .{ .px = 200 },
            .height = .{ .px = 200 },
        },
    );
    cx.linkNodeToWorld(target);
    target.setBackgroundRaw(Color.rgba(80, 120, 160, 255));
    // 直接走 composited_group=true 路径让 layer_tree promote (layer_tree.zig:800
    // shouldPromoteLayer：effect.kind == .composited_group → return true)。
    // 比 will_change_transform 路径稳 — 后者还要 scene_runtime 同步 ext 才生效。
    (try target.style.ensureExtFallible(allocator)).composited_group = true;
    try root.appendChild(allocator, target);

    cx.root = root;
    cx.layout();
    _ = cx.render();
    cx.layout(); // 第二帧让 layer_tree promote 真生效 (如果 promotion 是 t+1 帧)
    _ = cx.render();

    // 验证 promotion 真生效 — 这是 #4 的前置条件
    if (target.meta.per_frame.caches.commands.promoted == null) {
        std.debug.panic(
            "frame_transform: target node not promoted to composited surface — " ++
                "will_change_transform → layer_tree promotion 链断了，无法测 paint=0",
            .{},
        );
    }

    // ===== #4 真正的 gate：setRotate → composite-only path =====
    cx.perf.resetFrame();
    target.setRotate(allocator, 0.1);

    // setRotate 路径下 markCompositeDirty(target) 应该不冒泡 render dirty
    // （因 target promoted），target 自己的 dirty.core.render 也不该被设
    if (target.frame_state.state_bits.dirty.core.render) {
        std.debug.panic(
            "frame_transform: target promoted but markCompositeDirty 还冒泡了 render dirty " ++
                "(self_needs_render_dirty 逻辑断了)",
            .{},
        );
    }

    cx.layout();
    _ = cx.render();

    // §5 #4 核心 gate: paint 重录次数 = 0
    if (cx.perf.display_list_own_prebuild_count != 0) {
        std.debug.panic(
            "frame_transform: setRotate 触发 paint 重录！expected display_list_own_prebuild_count == 0, got {d}",
            .{cx.perf.display_list_own_prebuild_count},
        );
    }

    const state = try allocator.create(FrameTransformState);
    state.* = .{ .cx = cx, .target = target, .rotate_value = 0.1 };
    return @ptrCast(state);
}

fn frameTransformTeardown(allocator: std.mem.Allocator, state_ptr: *anyopaque) void {
    const state: *FrameTransformState = @ptrCast(@alignCast(state_ptr));
    state.cx.deinit();
    allocator.destroy(state);
}

fn frameTransformBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const state: *FrameTransformState = @ptrCast(@alignCast(ctx.state.?));
    state.rotate_value += 0.05;
    if (state.rotate_value > 6.28) state.rotate_value = 0; // ~2π wrap
    state.target.setRotate(allocator, state.rotate_value);
    state.cx.layout();
    _ = state.cx.render();
    ctx.blackbox(state.cx.perf.display_list_own_prebuild_count);
}

// ----------------------------------------------------------------------------
// v0.8 §2.2 — frame_select_1k_keyboard_pagedown
//
// mountSelectHeadless 接 1k options + virtualize=true，open popover，每帧
// 模拟 PageDown (state.machine 走 page_down action) 然后 layout + render。
// 目标 (v0.7 plan 退出阈值): < 5ms median per frame。
//
// 检测要点：
// - virtualize=true 路径下 popover content 只 mount ~10 个 pool node
// - state machine PageDown 改 highlight_index，VL ensureVisible 滚到目标行
// - aria-activedescendant 字段也跟随 (v0.8 §2.1 wire-up 已 land)
// ----------------------------------------------------------------------------

const FrameSelect1kState = struct {
    cx: *Cx,
    scope: *zenit.Scope,
    state: *zenit.select_headless_mount.SelectState(i32),
    options: []zenit.select_headless_mount.Option(i32),
    item_count: usize,
};

fn frameSelect1kSetup(allocator: std.mem.Allocator) anyerror!*anyopaque {
    const cx = try Cx.init(allocator);
    errdefer cx.deinit();
    cx.setViewport(800, 600);

    const root = try Node.create(allocator, cx.nextId(), .box, Style{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
    });
    cx.linkNodeToWorld(root);
    cx.root = root;

    const scope = try zenit.Scope.init(allocator, null, cx.owner);

    const Opt = zenit.select_headless_mount.Option(i32);
    const opts = try allocator.alloc(Opt, 1000);
    for (opts, 0..) |*o, i| {
        o.* = .{ .value = @intCast(i), .label = "Item" };
    }

    const mount_result = try zenit.select_headless_mount.mountSelectHeadless(i32, .{
        .options = opts,
        .virtualize = true,
        .max_dropdown_height = 240, // 视口 ~8 行 × 30px
    }, scope, cx);
    try root.appendChild(allocator, mount_result.wrapper);

    // 打开下拉，让 VL 真 render pool nodes
    mount_result.is_open.set(true);
    cx.layout();
    _ = cx.render();

    const st = try allocator.create(FrameSelect1kState);
    st.* = .{
        .cx = cx,
        .scope = scope,
        .state = mount_result.state,
        .options = opts,
        .item_count = opts.len,
    };
    return @ptrCast(st);
}

fn frameSelect1kTeardown(allocator: std.mem.Allocator, state_ptr: *anyopaque) void {
    const st: *FrameSelect1kState = @ptrCast(@alignCast(state_ptr));
    st.scope.dispose();
    st.cx.deinit();
    allocator.free(st.options);
    allocator.destroy(st);
}

fn frameSelect1kBody(_: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const st: *FrameSelect1kState = @ptrCast(@alignCast(ctx.state.?));
    // 每帧 step 一次 PageDown — wrap 防止 highlight 卡在末尾
    if (st.state.highlight_index) |hi| {
        if (hi + 10 >= st.item_count) {
            st.state.highlight_index = 0;
        }
    }
    zenit.select_headless_mod.step(i32, st.state, st.options, .page_down, 0);
    st.cx.layout();
    _ = st.cx.render();
    ctx.blackbox(st.state.highlight_index);
}
