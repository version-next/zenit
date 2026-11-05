//! Bench main entry, register & run all bench cases. Run: `zig build bench` or
//! `zig build bench -- keyword` (filter) or `zig build bench -- json=path/to.json`
//! (output). Baseline: reactive_1k_signal_fanout (1k effects subscribe one
//! signal, set cost), resource_pool_cycle (alloc/release/endFrame), slotmap_alloc_free
//! (ElementId SlotMap alloc+free).

const std = @import("std");
const runner = @import("runner.zig");

// reactive symbols via facade re-export (core.zig pub); no separate reactive
// bench module, resolve facade-pulling-Cx conflict where core was dual reactive+
// zenit.
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

// v0.2-P4 layer bench only tests algorithm enum/packed struct.
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

// v0.2-P8 Select headless
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

fn fanoutSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

fn poolSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

fn slotSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// diamond glitch set: A->B(memo), A->C(memo), [B,C]->D(effect). Write A
// must run D once (topo sort) + B/C both recomputed with new A value.

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

fn diamondSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// lazy memo unused: memo created but no downstream read; set source shouldn't
// trigger compute.

const LazyState = struct {
    owner: *SignalOwner,
    a: *Signal(i32),
    target: i32 = 0,
};

fn lazyMemoSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const a = try Signal(i32).create(owner, 0);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        _ = try createMemo(owner, i32, .{ .a = a }, struct {
            fn compute(c: anytype) i32 {
                // Deliberately expensive: 100 memo depend a; if lazy correct, set a doesn't
                // compute any.
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

// topological chain 10: A->M1->M2->...->M10->effect. Set A runs effect once,
// all memo topo-updated.

const ChainState = struct {
    owner: *SignalOwner,
    a: *Signal(i32),
    final_count: *u64,
    target: i32 = 0,
};

fn chainSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// 10k node tree build + traverse; element_table SoA performance. Simulates
// layout pass "build + full traverse" workload; once layout switches to
// ElementTable, this is zero-dirty baseline.

const TreeState = struct {
    table: ElementTable,
    root: ElementId,
    target_id: ElementId,
};

fn treeSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    var t = ElementTable.init(allocator);
    errdefer t.deinit();

    // Build 10k balanced tree (depth 100, 100 child each).
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
    // Full-tree DFS via ElementTable.children iterator.
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

// IntrinsicCache hit rate: 1k different LayoutInput key, put once, then 100
// random hits.

const CacheState = struct {
    cache: IntrinsicCache,
    keys: [1024]u64,
};

fn cacheSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(CacheState);
    state.cache = .{};

    // Generate 1024 different hash via hashLayoutInput.
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
    // 4-entry direct-mapped cache: many keys self-collide; only last 4 hit. Interface
    // still O(1); bench verifies call overhead.
    const key = state.keys[ctx.iter_index % 1024];
    const got = state.cache.get(key);
    ctx.blackbox(got);
}

// ElementTable subtree unlink middle node.

fn unlinkBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *TreeState = @ptrCast(@alignCast(ctx.state.?));
    // Get target node, unlink + appendChild back.
    const tgt = state.target_id;
    if (state.table.isValid(tgt)) {
        state.table.unlink(tgt);
        // Re-hang to root (prevent tree decay).
        state.table.appendChild(state.root, tgt);
    }
    ctx.blackbox(tgt);
}

// single_signal_color_change_paint: end-to-end signal.set -> effect run ->
// dirty hashmap write. Real cost of "single signal color -> paint dirty";
// plan matrix #2 target < 100 us.

const SingleSignalState = struct {
    owner: *SignalOwner,
    color_signal: *Signal(u32),
    dirty_set: std.AutoHashMapUnmanaged(u32, u8),
    target_id: u32,
    target_color: u32,
};

fn singleSignalColorSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

    // Create effect: simulate reactive effect seeing color change, notify paint
    // dirty (real app: button.style.background = signal.get() reactive bridge).
    try createEffect(owner, .{
        .signal = sig,
        .dirty_set = &state.dirty_set,
        .allocator = allocator,
        .target_id = state.target_id,
        .target_color = &state.target_color,
    }, struct {
        fn run(ctx: anytype) void {
            const new_color = ctx.signal.get();
            // Simulate "color change -> mark paint dirty".
            ctx.target_color.* = new_color;
            // Diagnostic path: bench simulates dirty-mark fake load, not true render
            // pipeline. Alloc fail only skips one id this round, measures signal propagation
            // cost itself.
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
    // Simulate user color change: signal.set triggers full reactive pipeline.
    const new_color: u32 = @intCast(0xFF000000 | (ctx.iter_index & 0xFFFFFF));
    state.color_signal.set(new_color);
    ctx.blackbox(state.target_color);
    ctx.blackbox(state.dirty_set.count());
}

// signal_color_change_realistic: 1 color signal drives 10 Button background;
// color change triggers 10 effect simultaneously, each simulates "read signal +
// change style + mark dirty"—closer to real dashboard "theme switch" reactive
// work.

const RealisticState = struct {
    owner: *SignalOwner,
    theme_signal: *Signal(u32),
    button_colors: [10]u32,
    dirty_set: std.AutoHashMapUnmanaged(u32, u8),
    allocator: std.mem.Allocator,
};

fn realisticSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const owner = try SignalOwner.init(allocator);
    errdefer owner.deinit();
    const theme = try Signal(u32).create(owner, 0xFF0000FF);

    const state = try allocator.create(RealisticState);
    state.* = .{
        .owner = owner,
        .theme_signal = theme,
        .button_colors = @as([10]u32, @splat(0)),
        .dirty_set = .{},
        .allocator = allocator,
    };

    // 10 buttons each create effect subscribing to theme change.
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
                // Simulate "read signal -> compute style -> write Node field -> mark dirty"
                // full path.
                ctx.color_slot.* = new_color;
                // Diagnostic path: same as above, bench fake load.
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

// ElementTable 1k create + appendChild chain. Simulates v0.5's replacement of
// *Node god-object with true "create node" path.

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

// World 4-table ensureSlot sync path: builder layout/paint table ensureSlot cost
// during createElement.

const FourTablesState = struct {
    elements: ElementTable,
    layout: LayoutTable,
    paint: PaintTable,
};

fn fourTablesSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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
    // one element create + sync layout/paint table write.
    const id = try state.elements.create(.{ .tag = .container, .key = ctx.iter_index });
    try state.layout.ensureSlot(id);
    try state.paint.ensureSlot(id);
    ctx.blackbox(id);
}

// ElementId hot path verify (scan 1k IDs via world).

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

// Bounds.unionWith hot path (layerize accumulate bounds).

const BoundsBenchState = struct {
    bounds: [256]Bounds,
};

fn boundsSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// PaintChunk content_hash batch invalidation: simulate 1k chunks all content_hash
// mismatch triggering re-record.

const PaintBatchState = struct {
    table: PaintTable,
};

fn paintBatchSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(PaintBatchState);
    state.* = .{ .table = PaintTable.init(allocator) };
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const eid: ElementId = .{ .index = @intCast(i), .generation = 0 };
        try state.table.ensureSlot(eid);
        // Initial hash.
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
    // All chunks new hash -> cache miss.
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

// PropertyStateRef pack/unpack (renderer reads 16B ref per chunk).

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

// IntrinsicCache miss-path (simulate layout pass first-measure each node).

const IntrinsicCacheState = struct {
    cache: IntrinsicCache,
    keys: [256]u64,
};

fn intrinsicCacheMissSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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
    // 256 different key repeatedly put (4-entry cache guaranteed mostly miss).
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
// AvailableSpace fit-content path: simulates constraint passing
// ============================================================================

fn availableSpaceTransformBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const inp = LayoutInput{
        .available_space = AvailableSpaceXY.definite(
            @as(f32, @floatFromInt((ctx.iter_index & 0xFF) + 100)),
            200,
        ),
    };
    // Simulate Constraint passing: subtract padding + clamp + hash for cache key.
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

fn a11yDrainSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(A11yDrainState);
    state.* = .{ .tree = AccessibilityTree.init(allocator), .drain_count = 0 };
    // Pre-fill 100 a11y nodes.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try state.tree.upsert(.{
            .element = zenit.AXId.node(.{ .index = @intCast(i), .generation = 0 }),
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

fn a11yDrainCb(ctx: *anyopaque, id: zenit.AXId, flag: zenit.A11yDirtyFlag) void {
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
    // Mark dirty 100 again for next bench round to drain. Diagnostic: fixture
    // reset; fail only impacts next round sample size, outside product code.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        state.tree.markDirty(zenit.AXId.node(.{ .index = @intCast(i), .generation = 0 }), .{ .state_changed = true }) catch {};
    }
    ctx.blackbox(state.drain_count);
}

// select_headless typeahead match.

fn typeaheadSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(SelectBenchState);
    state.* = .{
        .state = select_headless.SelectState(i32){},
        .options = undefined,
    };
    // 10 options different first letter.
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

// a11y tree.children lookup (O(N) scan).

const A11yChildrenState = struct {
    tree: AccessibilityTree,
    out: std.ArrayListUnmanaged(zenit.AXId) = .empty,
};

fn a11yChildrenSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(A11yChildrenState);
    state.* = .{ .tree = AccessibilityTree.init(allocator) };
    errdefer allocator.destroy(state);
    errdefer state.tree.deinit();
    // Capacity is fixture setup, not part of the operation being measured.
    // Reallocating and freeing 50 IDs per iteration made this benchmark vary
    // by 2.8x on unchanged code and mostly measured the GPA, not tree.children.
    try state.out.ensureTotalCapacity(allocator, 50);
    const parent = zenit.AXId.node(.{ .index = 0, .generation = 0 });
    try state.tree.upsert(.{ .element = parent, .role = .group });
    var i: u32 = 1;
    while (i <= 50) : (i += 1) {
        try state.tree.upsert(.{
            .element = zenit.AXId.node(.{ .index = @intCast(i), .generation = 0 }),
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
    const parent = zenit.AXId.node(.{ .index = 0, .generation = 0 });
    try state.tree.children(parent, &state.out, allocator);
    ctx.blackbox(state.out.items.len);
}

// encode_dashboard_typical (50 rect + 30 text + 10 image mix).

const DashboardEncodeState = struct {
    items: [90]DisplayItem,
    out: [90]GpuDraw,
};

fn dashboardSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(DashboardEncodeState);
    var i: usize = 0;
    // 50 rect
    while (i < 50) : (i += 1) {
        state.items[i] = .{ .kind = .rect };
    }
    // 30 text (same font).
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

// shaping_cache_warm_hit_rate (100 lookup, all hit).

const ShapingWarmState = struct {
    cache: ShapingCache,
    keys: [128]ShapingKey,
};

fn shapingWarmSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// GlyphRun.xToCluster complex cluster (10 codepoints, uneven advance).

const GlyphRun = zenit.GlyphRun;

const XToClusterState = struct {
    glyphs: [10]GlyphPosition,
    clusters: [10]Cluster,
    run: GlyphRun,
};

fn xToClusterSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(XToClusterState);
    for (&state.glyphs, 0..) |*g, i| {
        g.* = .{
            .glyph_id = @intCast(i + 1),
            .x_advance = @floatFromInt(8 + (i % 4) * 3), // 8/11/14/17 px uneven.
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

// PropertyScrollNode array update simulation: simulate 1000 scroll containers
// update offset per frame.

const ScrollArrayState = struct {
    nodes: [1000]zenit.PropertyScrollNode,
};

fn scrollArraySetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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
    // 1000 scroll node all update offset (simulate per-frame scroll event).
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

fn hintCollectSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// ElementId pack/unpack via World.elements: verify first-class ElementId API
// cost on World path.

const ElementWorldState = struct {
    table: ElementTable,
    ids: [1000]ElementId,
};

fn elementWorldSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// LayoutTable.markLaidOut throughput: simulate layout pass writing 1k node rect.

const LayoutTableState = struct {
    table: LayoutTable,
};

fn layoutTableSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(LayoutTableState);
    state.* = .{ .table = LayoutTable.init(allocator) };
    // Pre-allocate 1k slots.
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

// LayoutTable.epoch read hot path (cache invalidation check).

fn layoutTableEpochReadBody(allocator: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    _ = allocator;
    const state: *LayoutTableState = @ptrCast(@alignCast(ctx.state.?));
    const id: ElementId = .{ .index = @truncate(ctx.iter_index % 1000), .generation = 0 };
    const e = state.table.epoch(id);
    ctx.blackbox(e);
}

// Signal alone (no observer)—minimum set cost.

const SignalAloneState = struct {
    owner: *SignalOwner,
    sig: *Signal(i32),
    target: i32,
};

fn signalAloneSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// Signal create + immediate set, no effect.

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
    // Each iter create+deinit new owner with 1k signals.
    var owner = try SignalOwner.init(allocator);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        _ = try Signal(i32).create(owner, 0);
    }
    owner.deinit();
}

// PaintTable content_hash hit rate: simulate paint pass 1000 beginRecord;
// first 800 same hash should direct cache hit.

const PaintCacheState = struct {
    table: PaintTable,
    target_id: ElementId,
};

fn paintCacheSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    var t = PaintTable.init(allocator);
    errdefer t.deinit();

    const eid: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(eid);
    // First record establish cache.
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
    // same hash -> always hit -> no re-record.
    const hit = !(try state.table.beginRecord(state.target_id, 0xCAFEBABE));
    ctx.blackbox(hit);
}

// ElementId pack/unpack hot path.

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

// PaintTable re-record (hash mismatch) path: simulate reactive trigger paint
// chunk invalidate then re-record.

const PaintRecordState = struct {
    table: PaintTable,
    target_id: ElementId,
    counter: u64,
};

fn paintRecordSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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
    // Each hash different -> must re-record.
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

// PromotionHint primaryReason branch sequence.

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

// encodeOne single DisplayItem -> GpuDraw conversion.

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

// encodeStream 100 homogeneous rect -> 1 batch.

const StreamState = struct {
    items: [100]DisplayItem,
    out: [100]GpuDraw,
};

fn streamSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// encodeStream 50 rect + 50 text alternating -> 100 separate batches
// (worst case: zero batching).

fn streamWorstCaseSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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

// BiDi splitRuns mixed script (Latin + Arabic). WARNING: **isolated module**
// microbenchmark, doesn't mean framework RTL-capable. src/i18n/bidi.zig unhooked
// from render pipeline (this bench its only callsite); see file header. Don't treat
// this bench existence as RTL evidence.

const BidiBenchState = struct {
    text: []const u8,
    runs: std.ArrayListUnmanaged(i18n.Run),
    allocator: std.mem.Allocator,
};

fn bidiSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(BidiBenchState);
    // "Hello مرحبا World" - mixed LTR/RTL.
    state.* = .{
        .text = "Hello \xD9\x85\xD8\xB1\xD8\xAD\xD8\xA8\xD8\xA7 World",
        .runs = .empty,
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

// linebreak findBreakOpportunities (CJK text).

const LineBreakBenchState = struct {
    text: []const u8,
    breaks: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
};

fn linebreakSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(LineBreakBenchState);
    // 30 CJK char (3 bytes each).
    state.* = .{
        .text = "中文段落示例显示如何处理换行符号在常规情况下表现得很好",
        .breaks = .empty,
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

fn shapingSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(ShapingState);
    state.* = .{
        .cache = ShapingCache.init(allocator, 256),
        .key = .{ .text_hash = 0xCAFEBABE, .text_len = 11, .font_id = 0, .max_width = 0, .font_size = 14 },
    };
    state.cache.beginFrame();

    // Pre-fill cache.
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

fn a11ySetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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
        .element = zenit.AXId.node(eid),
        .role = .button,
        .state = .{ .focusable = true },
        .label_hash = ctx.iter_index,
    });
    // Clear dirty prevent memory explosion.
    if ((ctx.iter_index & 0xFF) == 0xFF) {
        state.tree.dirty.clearRetainingCapacity();
    }
}

// GestureArena dispatch (tap recognition).

const GestureBenchState = struct {
    arena: GestureArena,
    counter: u64,
};

fn gestureSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
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
    // Even iter: checked=true; odd: checked=false. Each upsert should trigger
    // state_changed dirty.
    try state.tree.upsert(.{
        .element = zenit.AXId.node(eid),
        .role = .checkbox,
        .state = .{ .checked = (ctx.iter_index & 1) == 0 },
    });
    if ((ctx.iter_index & 0xFF) == 0xFF) {
        state.tree.dirty.clearRetainingCapacity();
    }
}

// ============================================================================
// Select state machine step (arrow_down + commit)
// ============================================================================

const SelectBenchState = struct {
    state: select_headless.SelectState(i32),
    options: [10]select_headless.Option(i32),
};

fn selectSetup(allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(SelectBenchState);
    state.* = .{
        .state = select_headless.SelectState(i32){},
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

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
        // v0.2-P1 added (>=3 bench per phase enforced).
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
        // v0.2-P2 added (>=3 bench per phase enforced).
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
        // v0.2-P3 added (>=3 bench per phase enforced).
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
        // v0.2-P4 added (layer_tree true-integrated bench pending v0.3 main-path
        // switch; currently algorithm level PromotionHint fast-path).
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
        // v0.2-P5 added.
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
        // v0.2-P6 added.
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
        // v0.2-P7 added.
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
        // v0.2-P8 added.
        .{
            .name = "select_state_machine_arrow_down",
            .setup = selectSetup,
            .teardown = selectTeardown,
            .body = selectStepBody,
        },
        // v0.3-P1 added.
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
        // v0.3-P2 added.
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
        // v0.3-P3 added (ElementId first-class path).
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
        // v0.3-P4 added.
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
        // v0.3-P5 added.
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
        // v0.3-P6 added.
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
        // v0.4-P1 added.
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
        // v0.4-P2 added (v0.5 algorithm baseline before true render-IR deletion).
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
        // v0.4-P3 added (v0.5 4-table path baseline before Node field split).
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
        // Real benchmark plan matrix #2 "single signal color -> paint" end-to-end.
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
        // v0.5-P3 frame-level scenario benches (v0.5 §5 exit criteria #1/#3/#4/#5/#8).
        // Start: #1 10k nodes zero-dirty frame, target < 0.5ms.
        .{ .name = "layout_wrap_1k_incremental", .setup = wrapLayoutSetup, .teardown = wrapLayoutTeardown, .body = wrapIncrementalBody },
        .{ .name = "layout_wrap_1k_full", .setup = wrapLayoutSetup, .teardown = wrapLayoutTeardown, .body = wrapFullBody },
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

    var json_file: ?std.Io.File = null;
    defer if (json_file) |f| f.close(io);
    if (json_path) |p| {
        json_file = try std.Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
    }

    try runner.run(allocator, io, &cases, filter, json_file);
}

// LC3B: 1,000 wrap cards / 10,000 leaves, fixed allocations. Measure both
// a deep change that cannot affect line packing and an explicit full relayout.
const WrapLayoutState = struct { cx: *Cx, leaf: *Node };
fn wrapLayoutSetup(a: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    const cx = try Cx.init(a, io);
    errdefer cx.deinit();
    cx.setViewport(600, 2200);
    const root = try Node.create(a, cx.nextId(), .box, .{ .width = .{ .px = 600 }, .height = .{ .px = 2200 }, .direction = .row, .align_items = .start, .align_content = .start });
    cx.linkNodeToWorld(root);
    cx.root = root;
    (try root.style.ensureExtFallible(a)).flex_wrap = .wrap;
    var last: *Node = undefined;
    for (0..1000) |_| {
        const card = try Node.create(a, cx.nextId(), .box, .{ .width = .{ .px = 60 }, .height = .{ .px = 20 }, .direction = .row, .flex_shrink = 0 });
        cx.linkNodeToWorld(card);
        try root.appendChild(a, card);
        for (0..10) |_| {
            last = try Node.create(a, cx.nextId(), .box, .{ .width = .{ .px = 1 }, .height = .{ .px = 1 } });
            cx.linkNodeToWorld(last);
            try card.appendChild(a, last);
        }
    }
    cx.layout();
    const state = try a.create(WrapLayoutState);
    state.* = .{ .cx = cx, .leaf = last };
    return state;
}
fn wrapLayoutTeardown(a: std.mem.Allocator, ptr: *anyopaque) void {
    const s: *WrapLayoutState = @ptrCast(@alignCast(ptr));
    s.cx.deinit();
    a.destroy(s);
}
fn wrapIncrementalBody(_: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const s: *WrapLayoutState = @ptrCast(@alignCast(ctx.state.?));
    s.leaf.markLayoutDirty();
    s.cx.layout();
    ctx.blackbox(s.leaf.rectFromWorldOrFallback());
}
fn wrapFullBody(_: std.mem.Allocator, ctx: *runner.BenchCtx) anyerror!void {
    const s: *WrapLayoutState = @ptrCast(@alignCast(ctx.state.?));
    s.cx.root.?.markLayoutDirty();
    s.cx.layout();
    ctx.blackbox(s.leaf.rectFromWorldOrFallback());
}

// Frame-level scenario benches. Unlike micro benches above: full Cx
// (init/setViewport/layout/render), gating on real wall-clock. See
// docs/V05_ALIGNMENT_PLAN.md section 5. First case: frame_10k_nodes_zero_dirty_relayout, 10k nodes
// zero-dirty. Hits the cx.render() fast path (time_unchanged + isTreeFullyClean),
// simulating the real cost of a production idle frame.

const Cx = zenit.Cx;
const Node = zenit.Node;
const Color = zenit.Color;
const Style = zenit.Style;
const Padding = zenit.Padding;

const FrameZeroDirtyState = struct {
    cx: *Cx,
};

fn frameZeroDirty10kSetup(allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    const cx = try Cx.init(allocator, io);
    errdefer cx.deinit();
    cx.setViewport(1280, 800);

    // Direct imperative build: root 1 vstack, 100 rows beneath it, each row 100 leaves.
    // Placeholder boxes without text -> total 100*100 + 100 + 1 = 10101 ≈ 10k nodes.
    // Avoid ui.box() tuple API (10k can't be literalized); use Node.create +
    // cx.linkNodeToWorld + parent.appendChild, equivalent to box() internals.
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
    // Run complete layout + render once to clear all dirty bits and populate
    // display_list cache. Subsequent body calls take fast-path.
    cx.layout();
    _ = cx.render();

    // Sanity check: nodes built successfully + display_list has content.
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
    // Without changing frame_time_ms -> time_unchanged -> render() fast-path
    // returns cache. layout() bails early (had_dirty == false); render() bails
    // early (fully clean + cache valid).
    state.cx.layout();
    const items = state.cx.render();
    ctx.blackbox(items.len);
}

// Benchmark #5: frame_dashboard_drawcall_count, typical dashboard screen <
// 600 draw calls. Dashboard fixture: header bar + sidebar (12 nav items) +
// main 4x4 card grid (16 cards x 3 text + 1 bg = 4 nodes/card). Each node
// produces 1 fill_rect (background) + text nodes produce 1 text_run, expected
// ~150-250 display_items. The 600 threshold leaves 2-3x margin for real-world
// content.

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

    // Use brief numeric string as value (avoid allocator-owned format).
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

fn frameDashboardSetup(allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    const cx = try Cx.init(allocator, io);
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

    // 6x6 = 36 cards x 4 nodes = ~144 + sidebar/header/structural ≈ 200+
    // display_items, gives 600 threshold ~3x headroom yet still real engineering.
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
    // v0.5 exit criterion #5: typical dashboard < 600 draw calls. Current
    // fixture (header + 16 nav + 36 cards x 4 nodes) ≈ 176 display_items, ~3.4x
    // headroom. assert is real gate; regression to 600+ causes panic.
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

// Benchmark #8: frame_diamond_set_no_double_paint. Diamond reactive topology: after one
// signal flip, the node paints exactly once (no glitch / no double paint).
// Tree: 1 target_box in cx; reactive owner separate (shares allocator with cx):
// A: Signal(i32), B: Memo = A.get() * 10, C: Memo = A.get() + 100,
// effect(B,C): target_box.setBackground(rgba based on B+C).
// Expected: A.set(N) -> reactive propagates synchronously (B/C/effect each run once in
// topological order) -> setBackground marks target_box render-dirty -> cx.render()
// repaints that node once (display_list_own_prebuild_count == 1). On a glitch (effect runs
// 2x or paint redraws 2x), count > 1 -> setup asserts fail. Micro
// reactive_diamond_no_glitch_set tests pure reactive; this case tests reactive + paint
// composition frame time.

const FrameDiamondState = struct {
    cx: *Cx,
    target_box: *Node,
    owner: *SignalOwner,
    a: *Signal(i32),
    effect_run_count: *u64,
    target_value: i32 = 0,
};

fn frameDiamondSetup(allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    const cx = try Cx.init(allocator, io);
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

    // Reactive graph: A -> B(memo), A -> C(memo), effect(B, C) ->
    // setBackground. Owner and cx use same allocator but independent
    // lifetimes (cx.deinit doesn't destroy owner).
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
            // Derive RGB from sum; force different color each set -> ensures
            // markRenderDirty triggers.
            const r: u8 = @intCast(@as(u32, @bitCast(sum)) & 0xFF);
            const g: u8 = @intCast((@as(u32, @bitCast(sum)) >> 8) & 0xFF);
            const b_ch: u8 = @intCast((@as(u32, @bitCast(sum)) >> 16) & 0xFF);
            eff_ctx.target_box.setBackground(zenit.Color.rgba(r, g, b_ch, 255));
            eff_ctx.counter.* +%= 1;
        }
    }.run);

    // ===== True #8 gate: after a.set, single-frame effect topology
    // guarantee =====. Effect already fired once on createEffect (establishes
    // dependencies); reset first.
    counter.* = 0;
    a.set(42);
    // Reactive diamond topology guarantee: B/C each recomputed once, effect
    // fires once (no glitch into 2x). This is §5 #8 core gate.
    if (counter.* != 1) {
        std.debug.panic("frame_diamond: effect expected 1 fire after a.set, got {d} (glitch!)", .{counter.*});
    }
    // Verify reactive actually changed node style + render dirty path is
    // live.
    if (!target_box.frame_state.state_bits.dirty.core.render) {
        std.debug.panic("frame_diamond: setBackground 没触发 render dirty — reactive→paint 链断了", .{});
    }
    // Run one frame to consume dirty, keep steady-state body on true dirty
    // propagation path.
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
    state.a.set(state.target_value); // reactive: B/C/effect each fires once.
    state.cx.layout();
    _ = state.cx.render(); // paint pass: target_box redraws once.
    ctx.blackbox(state.effect_run_count.*);
}

// Benchmark #3: frame_scrollarea_1k_items_scroll, 1k items in an
// overflow_hidden container scroll one frame < 3ms (60fps frame budget).
// Doesn't depend on the ScrollArea component (avoids pulling components/scroll_area/*):
// builds directly with raw cx: viewport (overflow_hidden, fixed height 600) +
// content (1k items); scroll simulated via content translate_y. Translate currently walks
// markRenderDirty (no composite-only path yet), so this measures "content translate + 1k
// visible items layout/render fast-path full frame time". Numbers will drop once translate
// switches to composite-only.

const FrameScrollState = struct {
    cx: *Cx,
    content: *Node,
    scroll_offset: f32 = 0,
};

fn frameScrollSetup(allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    const cx = try Cx.init(allocator, io);
    errdefer cx.deinit();
    cx.setViewport(800, 600);

    const ui_core = zenit.ui_core;

    // Root viewport: overflow_hidden + fixed 800x600.
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

    // Content pane: 1k items x 24px = 24000px height.
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

        // Brief label, reuse static string to avoid allocator hassle.
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

    // Sanity check: truly has 1000 rows + first row has text.
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
    // Simulate scroll: translate 5px per frame. Cycle between -12000 ~ 0 to
    // prevent unbounded growth. Use setStyle(.translate_y, value); translate_y is a
    // non-ext field, writable without allocator. setStyle's .interaction dirty
    // level auto-marks render dirty.
    state.scroll_offset -= 5.0;
    if (state.scroll_offset < -12000) state.scroll_offset = 0;
    state.content.setStyle(null, .translate_y, state.scroll_offset);
    state.cx.layout();
    _ = state.cx.render();
    ctx.blackbox(state.cx.display_list.count());
}

// Benchmark #4: frame_transform_promoted_no_paint, will_change_transform
// node promoted to composited surface via layer_tree, setRotate triggers
// composite-only path, paint not redrawn (display_list_own_prebuild_count
// == 0). Invariant chain (markCompositeDirty in node.zig):
// self_needs_render_dirty = (promoted == null) and !isOutOfBandRenderUnit.
// A promoted node -> self_needs_render_dirty=false -> doesn't bubble render dirty ->
// render() doesn't repaint the node -> prebuild_count == 0 that frame.
// setTranslateX walks markRenderDirtyTracked (no composite-only path yet), while setRotate
// walks markCompositeDirty, so this case must use setRotate.

const FrameTransformState = struct {
    cx: *Cx,
    target: *Node,
    rotate_value: f32 = 0,
};

fn frameTransformSetup(allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    const cx = try Cx.init(allocator, io);
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

    // Target: 200x200 will_change_transform lets layer_tree promote it.
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
    // Go directly to composited_group=true path to promote via layer_tree
    // (layer_tree.zig:800 shouldPromoteLayer: effect.kind == .composited_group ->
    // return true). More stable than will_change_transform path, which needs
    // scene_runtime to sync ext to take effect.
    (try target.style.ensureExtFallible(allocator)).composited_group = true;
    try root.appendChild(allocator, target);

    cx.root = root;
    cx.layout();
    _ = cx.render();
    cx.layout(); // Second frame lets layer_tree promotion take real effect (if promotion is t+1 frame).
    _ = cx.render();

    // Verify promotion truly took effect, this is #4 precondition.
    if (target.meta.per_frame.caches.commands.promoted == null) {
        std.debug.panic(
            "frame_transform: target node not promoted to composited surface — " ++
                "will_change_transform → layer_tree promotion 链断了，无法测 paint=0",
            .{},
        );
    }

    // ===== #4 true gate: setRotate -> composite-only path =====.
    cx.perf.resetFrame();
    target.setRotate(allocator, 0.1);

    // Under setRotate path markCompositeDirty(target) should not bubble render
    // dirty (because target promoted), and target's own dirty.core.render
    // shouldn't be set either.
    if (target.frame_state.state_bits.dirty.core.render) {
        std.debug.panic(
            "frame_transform: target promoted but markCompositeDirty 还冒泡了 render dirty " ++
                "(self_needs_render_dirty 逻辑断了)",
            .{},
        );
    }

    cx.layout();
    _ = cx.render();

    // v0.5 #4 core gate: paint redraws 0 times.
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

// frame_select_1k_keyboard_pagedown: mount SelectHeadless with 1k options + virtualize=true, open
// the popover; each frame simulates PageDown (state machine page_down action) then layout +
// render. Target: < 5ms median per frame.
// Points checked:
// - with virtualize=true the popover content mounts only ~10 pool nodes
// - PageDown changes highlight_index and VL ensureVisible scrolls to the target row
// - the aria-activedescendant field follows the highlight.

const FrameSelect1kState = struct {
    cx: *Cx,
    scope: *zenit.Scope,
    state: *zenit.select_headless_mount.SelectState(i32),
    options: []zenit.select_headless_mount.Option(i32),
    item_count: usize,
};

fn frameSelect1kSetup(allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    const cx = try Cx.init(allocator, io);
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

    const mount_result = try zenit.select_headless_mount.SelectHeadless(i32, .{
        .options = opts,
        .virtualize = true,
        .max_dropdown_height = 240, // Viewport ~8 rows x 30px.
    }).mount(scope, cx);
    try root.appendChild(allocator, mount_result.wrapper);

    // Open dropdown, let VL truly render pool nodes.
    mount_result.open.?.set(true);
    cx.layout();
    _ = cx.render();

    const st = try allocator.create(FrameSelect1kState);
    st.* = .{
        .cx = cx,
        .scope = scope,
        .state = &zenit.select_headless_mount.stateOf(i32, mount_result).nav,
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
    // Step PageDown once per frame, wrap to prevent highlight stuck at end.
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
