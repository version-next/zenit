/// VirtualList 动态不等高的**几何内核**。
///
/// 这里只有纯数据结构与算法：不碰 Node / Cx / 渲染，因此可以脱离窗口单测。
/// 组件侧（mod.zig）负责把「量到的真实行高」喂进来、把算出的范围画出去。
///
/// 设计对齐 TanStack Virtual（@tanstack/virtual-core）的动态测量模型，
/// 三个关键点照抄其语义（都是踩过坑才有的）：
///
/// 1. **两级缓存、两套键域**。
///    - `sizes`：按 **item key** 存实测高度。key 由调用方给（默认 = index）。
///      用 key 而不是 index，是为了让「列表头部插入一条」不作废后面所有测量 ——
///      key 跟着数据走，prepend 后旧行的实测高度依然有效。
///    - `layout`：按 **index** 存前缀和 (start, size)。它是位置性的，会被重建。
///
/// 2. **增量前缀和**。任何一次测量只把 `pending_min` 往前推；重建时保留
///    `[0, pending_min)` 不动，从 `pending_min` 往后重走一遍。不是线段树，
///    就是 O(n-min) 的前向重走 —— 因为循环体极廉价，而 min 通常在视口附近。
///
/// 3. **滚动锚定**。视口"上方"的行从估算高变成实测高时，必须同步补偿
///    scroll_y，否则用户正在看的内容会被上方的高度差顶得上下乱跳。
///    首测与复测的判据不同，见 `applyMeasurement` 的注释。
const std = @import("std");
const Allocator = std.mem.Allocator;

/// item 的稳定标识。默认取 index，调用方可提供 key_fn 让它跟着数据走。
pub const ItemKey = u64;

/// 单项的布局结果（前缀和的一格）。
pub const Measurement = struct {
    /// 该项顶端相对内容原点的 y。
    start: f32,
    /// 该项高度（实测值，或尚未测到时的估算值）。
    size: f32,

    pub fn end(self: Measurement) f32 {
        return self.start + self.size;
    }
};

/// 一次测量回填对滚动位置的影响。
pub const MeasureOutcome = struct {
    /// 高度确实变了（需要重排/重绘）。
    changed: bool = false,
    /// 需要给 scroll_y 施加的补偿量（0 = 不动）。
    scroll_adjustment: f32 = 0,
};

/// 滚动方向 —— 复测时用来抑制"向上滚动时行高抖动引发的连锁位移"。
pub const ScrollDirection = enum { forward, backward, idle };

pub const Options = struct {
    /// 总行数。
    count: usize = 0,
    /// 未测量行的估算高度（按 index 可变）。
    estimate_fn: ?*const fn (index: usize, ctx: ?*anyopaque) f32 = null,
    estimate_ctx: ?*anyopaque = null,
    /// 固定估算值（estimate_fn == null 时用）。
    estimate: f32 = 32,
    /// item → 稳定 key。null = 用 index 本身。
    key_fn: ?*const fn (index: usize, ctx: ?*anyopaque) ItemKey = null,
    key_ctx: ?*anyopaque = null,
    /// 行间距（加在每行之后，但不计入该行的 end）。
    gap: f32 = 0,
    /// 内容顶部内边距（第 0 项的 start）。
    padding_start: f32 = 0,
};

pub const Measurements = struct {
    allocator: Allocator,
    opts: Options,

    /// key → 实测高度。**只有实测**会进这里；估算值永远不写入，
    /// 否则无法区分"量过的 32px"和"猜的 32px"，首测/复测判据就废了。
    sizes: std.AutoHashMapUnmanaged(ItemKey, f32) = .{},

    /// index → 前缀和。长度恒等于 opts.count（rebuild 时对齐）。
    layout: []Measurement = &.{},

    /// 自上次重建以来最早的脏 index。null = 干净。
    pending_min: ?usize = null,

    /// 已施加但尚未被滚动状态"消化"的补偿量。判首测/复测方位时必须把它算进
    /// 去 —— 否则同一帧内连续两次测量会各自基于旧位置做判断。
    pending_adjustment: f32 = 0,

    pub fn init(allocator: Allocator, opts: Options) Measurements {
        return .{ .allocator = allocator, .opts = opts };
    }

    pub fn deinit(self: *Measurements) void {
        self.sizes.deinit(self.allocator);
        if (self.layout.len > 0) self.allocator.free(self.layout);
        self.layout = &.{};
    }

    pub fn keyOf(self: *const Measurements, index: usize) ItemKey {
        if (self.opts.key_fn) |f| return f(index, self.opts.key_ctx);
        return @intCast(index);
    }

    /// 第 index 项应当用的高度：实测优先，否则估算。
    pub fn sizeOf(self: *const Measurements, index: usize) f32 {
        if (self.sizes.get(self.keyOf(index))) |measured| return measured;
        return self.estimateOf(index);
    }

    pub fn estimateOf(self: *const Measurements, index: usize) f32 {
        const raw = if (self.opts.estimate_fn) |f|
            f(index, self.opts.estimate_ctx)
        else
            self.opts.estimate;
        // 高度必须为正且有限：0 / NaN 会让二分与前向扫描退化成死循环。
        return if (std.math.isFinite(raw) and raw > 0) raw else 32;
    }

    pub fn hasMeasurement(self: *const Measurements, index: usize) bool {
        return self.sizes.contains(self.keyOf(index));
    }

    /// 行数变化。**不清 sizes** —— 它是 key 域的，行数变了旧 key 的高度依然有效
    /// （这正是 prepend 便宜的原因）。但前缀和是位置性的，必须整体重建。
    pub fn setCount(self: *Measurements, count: usize) void {
        if (self.opts.count == count) return;
        self.opts.count = count;
        self.pending_min = 0;
    }

    /// 丢弃全部实测值，退回纯估算（数据源整体换掉时用）。
    pub fn resetMeasurements(self: *Measurements) void {
        self.sizes.clearRetainingCapacity();
        self.pending_min = 0;
    }

    /// 作废整张前缀和，但**保留实测值**。
    ///
    /// 用于 `estimate_fn` 的返回值本身变了的场合 —— 典型是 VirtualList 的
    /// `item_height_fn` 模式：行高由调用方的回调给定，回调什么时候改返回值
    /// 账本无从得知。没有这个入口的话，`sizeOf` 读到的是实时回调值、而
    /// `offsetOf` / `totalHeight` 读的是陈旧缓存，同一份几何会自相矛盾
    /// （实测：回调 10→100 后 itemHeight=100 但 totalHeight 仍是旧的 1000）。
    ///
    /// 与 `resetMeasurements` 的区别：那个丢实测值、退回估算；这个只丢派生的
    /// 前缀和，实测值不动。
    pub fn markAllDirty(self: *Measurements) void {
        self.pending_min = 0;
    }

    /// 作废单行的实测值，使其回到估算态并在下次布局时重新测量。
    pub fn invalidate(self: *Measurements, index: usize) void {
        if (self.sizes.remove(self.keyOf(index))) {
            self.markDirty(index);
        }
    }

    fn markDirty(self: *Measurements, index: usize) void {
        if (self.pending_min) |m| {
            if (index < m) self.pending_min = index;
        } else {
            self.pending_min = index;
        }
    }

    /// 把布局量到的真实高度回填。返回是否变化 + 需要的滚动补偿。
    ///
    /// 滚动锚定判据（照搬 TanStack，两条规则按"是否首测"分流）：
    ///
    /// - **首测**：只要该项**顶端**在视口线之上 (`start < anchor`) 就补偿。
    ///   理由：这一整块此前都是估算的，估算→实测的差值必须两个方向都修正。
    ///
    /// - **复测**：只有该项**整体**在视口线之上 (`end <= anchor`) 才补偿，
    ///   且向上滚动时不补偿。理由：一个跨着视口线的行（顶在线上、底在线下，
    ///   例如流式增长的聊天气泡）是在**锚点下方**变高的，补偿反而会把视口
    ///   往下拽 —— 每次增长拽一次，表现为"内容一直往下溜"。
    pub fn applyMeasurement(
        self: *Measurements,
        index: usize,
        measured: f32,
        anchor_scroll_y: f32,
        direction: ScrollDirection,
    ) MeasureOutcome {
        if (index >= self.opts.count) return .{};
        if (!std.math.isFinite(measured) or measured <= 0) return .{};

        const key = self.keyOf(index);
        const prev = self.sizes.get(key);
        const is_first_measure = prev == null;
        // 与旧值比较：首测时和"当前生效值"（即估算值）比。
        const old_size = prev orelse self.estimateOf(index);
        const delta = measured - old_size;
        if (@abs(delta) < 0.01) {
            // 值没变，但首测仍需记账 —— 否则每帧都会被当成"首次测量"，
            // 复测判据永远走不到。
            if (is_first_measure) {
                self.sizes.put(self.allocator, key, measured) catch return .{};
            }
            return .{};
        }

        // 该项当前的 start：必须在写入新值**之前**读，否则拿到的是新几何。
        const item_start = self.offsetOf(index);
        const anchor = anchor_scroll_y + self.pending_adjustment;

        const should_adjust = if (is_first_measure)
            item_start < anchor
        else
            (item_start + old_size <= anchor) and direction != .backward;

        self.sizes.put(self.allocator, key, measured) catch return .{};
        self.markDirty(index);

        if (should_adjust) {
            self.pending_adjustment += delta;
            return .{ .changed = true, .scroll_adjustment = delta };
        }
        return .{ .changed = true, .scroll_adjustment = 0 };
    }

    /// 补偿已被滚动状态消化，清账。
    pub fn consumeAdjustment(self: *Measurements) void {
        self.pending_adjustment = 0;
    }

    /// 增量重建前缀和：保留 [0, min)，从 min 往后重走。
    pub fn ensureBuilt(self: *Measurements) void {
        const count = self.opts.count;
        if (self.layout.len != count) {
            const grown = self.allocator.realloc(self.layout, count) catch {
                // 分配失败：保持旧表不动并强制下帧重试。几何会暂时偏差，
                // 但不会 UB —— 所有读取点都对 layout.len 做了边界检查。
                self.pending_min = 0;
                return;
            };
            const old_len = self.layout.len;
            self.layout = grown;
            // 表长变了，新增的尾巴是**未初始化内存**，必须重走。
            // 起点取「旧长度」与「已有脏点」的较小者：
            // 旧长度之后是新内存（必须写），脏点之后是失效数据（必须重算）。
            // 注意不能写成 `pending_min orelse count` —— pending_min 为 null
            // （表本来是干净的）时那会得到 count，循环一格都不走，新尾巴就
            // 保持未初始化，读出来是随机浮点数。
            const from = @min(old_len, count);
            self.pending_min = if (self.pending_min) |m| @min(m, from) else from;
        }
        const min = self.pending_min orelse return;
        if (count == 0) {
            self.pending_min = null;
            return;
        }

        const start_at = @min(min, count);
        var running: f32 = if (start_at == 0)
            self.opts.padding_start
        else
            self.layout[start_at - 1].end() + self.opts.gap;

        var i = start_at;
        while (i < count) : (i += 1) {
            const size = self.sizeOf(i);
            self.layout[i] = .{ .start = running, .size = size };
            running += size + self.opts.gap;
        }
        self.pending_min = null;
    }

    /// 第 index 项顶端的 y。index == count 时返回内容总高（不含尾 gap）。
    pub fn offsetOf(self: *Measurements, index: usize) f32 {
        self.ensureBuilt();
        if (self.opts.count == 0 or self.layout.len == 0) return self.opts.padding_start;
        if (index >= self.layout.len) return self.layout[self.layout.len - 1].end();
        return self.layout[index].start;
    }

    pub fn sizeAt(self: *Measurements, index: usize) f32 {
        self.ensureBuilt();
        if (index >= self.layout.len) return self.estimateOf(index);
        return self.layout[index].size;
    }

    pub fn totalHeight(self: *Measurements) f32 {
        self.ensureBuilt();
        if (self.layout.len == 0) return self.opts.padding_start;
        return self.layout[self.layout.len - 1].end();
    }

    /// 二分：**start <= value 的最大 index**。要求 start 单调不减（前缀和天然满足）。
    fn findNearest(self: *const Measurements, value: f32) usize {
        var low: usize = 0;
        var high: usize = self.layout.len - 1;
        while (low <= high) {
            const middle = low + (high - low) / 2;
            const current = self.layout[middle].start;
            if (current < value) {
                low = middle + 1;
            } else if (current > value) {
                if (middle == 0) break;
                high = middle - 1;
            } else {
                return middle;
            }
        }
        return if (low > 0) low - 1 else 0;
    }

    /// 可见范围 [start, end)（半开区间）。overscan 由调用方另行外扩。
    pub fn range(self: *Measurements, scroll_y: f32, viewport_h: f32) struct { start: usize, end: usize } {
        self.ensureBuilt();
        const count = self.opts.count;
        if (count == 0 or self.layout.len == 0) return .{ .start = 0, .end = 0 };
        // 视口尚未测量：别把整张表都当可见，也别只画第 0 项就认定"已初始化"。
        if (!(viewport_h > 0)) return .{ .start = 0, .end = @min(count, 1) };

        const clamped_y = if (std.math.isFinite(scroll_y) and scroll_y > 0) scroll_y else 0;
        const first = self.findNearest(clamped_y);

        // 收尾用前向线性扫描（不是第二次二分）：可见行数很少，且与
        // TanStack 语义一致 —— end 严格小于视口下沿才继续推进。
        const limit = clamped_y + viewport_h;
        var last = first;
        while (last < count - 1 and self.layout[last].end() < limit) {
            last += 1;
        }
        return .{ .start = first, .end = last + 1 };
    }
};

// ========== 测试 ==========

const testing = std.testing;

fn fixedEstimate(_: usize, _: ?*anyopaque) f32 {
    return 20;
}

test "measurements: estimate-only prefix sums" {
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();

    try testing.expectEqual(@as(f32, 50), m.totalHeight());
    try testing.expectEqual(@as(f32, 0), m.offsetOf(0));
    try testing.expectEqual(@as(f32, 30), m.offsetOf(3));
    try testing.expectEqual(@as(f32, 50), m.offsetOf(5)); // == total
}

test "measurements: measured sizes override estimates" {
    var m = Measurements.init(testing.allocator, .{ .count = 4, .estimate = 10 });
    defer m.deinit();

    _ = m.applyMeasurement(1, 40, 0, .idle);
    try testing.expectEqual(@as(f32, 10), m.sizeAt(0));
    try testing.expectEqual(@as(f32, 40), m.sizeAt(1));
    // 1 变高 30 → 后面所有 start 都后移 30。
    try testing.expectEqual(@as(f32, 50), m.offsetOf(2));
    try testing.expectEqual(@as(f32, 70), m.totalHeight());
}

test "measurements: incremental rebuild keeps clean prefix" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    try testing.expectEqual(@as(?usize, null), m.pending_min);

    // 只动第 50 项 → pending_min 必须正好是 50，不是 0。
    _ = m.applyMeasurement(50, 30, 0, .idle);
    try testing.expectEqual(@as(?usize, 50), m.pending_min);
    m.ensureBuilt();
    try testing.expectEqual(@as(f32, 500), m.offsetOf(50)); // 前缀未受影响
    try testing.expectEqual(@as(f32, 530), m.offsetOf(51)); // 之后整体后移

    // 更早的脏项应把 min 往前拉，而不是覆盖成更晚的值。
    _ = m.applyMeasurement(70, 25, 0, .idle);
    _ = m.applyMeasurement(10, 15, 0, .idle);
    try testing.expectEqual(@as(?usize, 10), m.pending_min);
}

test "measurements: rebuild only touches the dirty suffix" {
    // 增量性本身要可观测，否则「每次全量重走」也能让其它断言全绿
    // （数值相同），增量路径就成了没人验的死代码。
    //
    // 手法：先让表建好，然后在**不标脏**的前提下偷偷改 estimate。
    // 干净前缀必须保留旧值（不重算），只有脏点之后才会看到新 estimate。
    var m = Measurements.init(testing.allocator, .{ .count = 10, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    try testing.expectEqual(@as(f32, 100), m.totalHeight());

    // 改 estimate 但只把 index 5 标脏。
    m.opts.estimate = 20;
    m.markDirty(5);
    m.ensureBuilt();

    // [0,5) 是干净前缀：保留按 10 算出的旧值。
    try testing.expectEqual(@as(f32, 10), m.layout[0].size);
    try testing.expectEqual(@as(f32, 40), m.layout[4].start);
    // [5,10) 被重走：用新 estimate 20。
    try testing.expectEqual(@as(f32, 20), m.layout[5].size);
    try testing.expectEqual(@as(f32, 50), m.layout[5].start);
    // 总高 = 5*10 + 5*20 = 150。全量重走会得到 200，从而抓住"退化成全量"。
    try testing.expectEqual(@as(f32, 150), m.totalHeight());
}

test "measurements: binary search finds row covering scroll offset" {
    var m = Measurements.init(testing.allocator, .{ .count = 10, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // 项 i 占 [10i, 10i+10)。
    try testing.expectEqual(@as(usize, 0), m.findNearest(0));
    try testing.expectEqual(@as(usize, 0), m.findNearest(9.9));
    // 恰好落在项顶端 → 起始项是**该项**，不是前一项（右端开区间）。
    try testing.expectEqual(@as(usize, 3), m.findNearest(30));
    try testing.expectEqual(@as(usize, 3), m.findNearest(35));
    try testing.expectEqual(@as(usize, 9), m.findNearest(9999));
}

test "measurements: range covers viewport with variable heights" {
    var m = Measurements.init(testing.allocator, .{ .count = 6, .estimate = 10 });
    defer m.deinit();
    // 高度 10/50/10/10/10/10 → start 0/10/60/70/80/90
    _ = m.applyMeasurement(1, 50, 0, .idle);

    const r = m.range(0, 60);
    try testing.expectEqual(@as(usize, 0), r.start);
    // 视口 [0,60)：项 0 [0,10)、项 1 [10,60) 都可见；项 2 从 60 开始，不算。
    try testing.expectEqual(@as(usize, 2), r.end);

    const r2 = m.range(60, 30);
    try testing.expectEqual(@as(usize, 2), r2.start);
    try testing.expect(r2.end >= 4);
}

test "measurements: zero viewport does not claim everything visible" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    const r = m.range(0, 0);
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 1), r.end);
}

test "measurements: first measure above fold adjusts scroll" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // 视口在 y=500。项 10 (start=100) 完全在上方，首测变高 +20 → 补偿 +20。
    const out = m.applyMeasurement(10, 30, 500, .idle);
    try testing.expect(out.changed);
    try testing.expectEqual(@as(f32, 20), out.scroll_adjustment);
    try testing.expectEqual(@as(f32, 20), m.pending_adjustment);
}

test "measurements: first measure below fold does not adjust scroll" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // 项 80 (start=800) 在视口 (y=100) 下方 → 变高不该动滚动位置。
    const out = m.applyMeasurement(80, 50, 100, .idle);
    try testing.expect(out.changed);
    try testing.expectEqual(@as(f32, 0), out.scroll_adjustment);
}

test "measurements: re-measure of fold-straddling item does not drag viewport" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // 先首测项 10 → 100..160（跨过视口线 150）。
    _ = m.applyMeasurement(10, 60, 0, .idle);
    m.consumeAdjustment();
    m.ensureBuilt();
    try testing.expectEqual(@as(f32, 100), m.offsetOf(10));

    // 复测：它跨着视口线 150（100 <= 150 < 160）——在锚点**下方**变高，
    // 补偿会把视口往下拽，所以必须不补偿。
    const out = m.applyMeasurement(10, 80, 150, .forward);
    try testing.expect(out.changed);
    try testing.expectEqual(@as(f32, 0), out.scroll_adjustment);
}

test "measurements: re-measure entirely above fold adjusts, but not when scrolling backward" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();

    _ = m.applyMeasurement(10, 20, 0, .idle);
    m.consumeAdjustment();
    m.ensureBuilt();
    // 项 10 = [100,120)，完全在视口线 500 之上。
    const fwd = m.applyMeasurement(10, 40, 500, .forward);
    try testing.expectEqual(@as(f32, 20), fwd.scroll_adjustment);

    m.consumeAdjustment();
    // 同样的几何，但向上滚：抑制补偿，避免"往上滚时行抖动"的连锁位移。
    const back = m.applyMeasurement(10, 60, 500, .backward);
    try testing.expect(back.changed);
    try testing.expectEqual(@as(f32, 0), back.scroll_adjustment);
}

test "measurements: pending_adjustment participates in the anchor comparison" {
    var m = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    // 项 30 = [300,310)。视口线 295 时它在下方 → 不补偿。
    const a = m.applyMeasurement(30, 20, 295, .idle);
    try testing.expectEqual(@as(f32, 0), a.scroll_adjustment);

    // 但若已有 +20 未消化的补偿，实际锚点是 315 > 300 → 该补偿。
    var m2 = Measurements.init(testing.allocator, .{ .count = 100, .estimate = 10 });
    defer m2.deinit();
    m2.ensureBuilt();
    m2.pending_adjustment = 20;
    const b = m2.applyMeasurement(30, 20, 295, .idle);
    try testing.expectEqual(@as(f32, 10), b.scroll_adjustment);
}

test "measurements: item keys survive prepend" {
    // key_fn 把 index 映射成"数据 id"：模拟头部插入一条后，
    // 原有数据的 id 不变，只是 index 整体 +1。这正是 key 域缓存的意义。
    const Ctx = struct {
        /// 数据源里的 id 序列，index 就是这张表的下标。
        var ids: []const u64 = &[_]u64{ 100, 101, 102 };
        fn key(index: usize, _: ?*anyopaque) ItemKey {
            return if (index < ids.len) ids[index] else 0;
        }
    };
    Ctx.ids = &[_]u64{ 100, 101, 102 };

    var m = Measurements.init(testing.allocator, .{
        .count = 3,
        .estimate = 10,
        .key_fn = Ctx.key,
    });
    defer m.deinit();

    // 量到 id=100 那行高 55（当前在 index 0）。
    _ = m.applyMeasurement(0, 55, 0, .idle);
    try testing.expectEqual(@as(f32, 55), m.sizeAt(0));

    // 头部插入 id=99：同一条数据（id=100）现在落在 index 1。
    Ctx.ids = &[_]u64{ 99, 100, 101, 102 };
    m.setCount(4);
    m.ensureBuilt();
    // 实测值跟着 key 走，没有因为 index 平移而丢失 —— 这就是 prepend 便宜的原因。
    try testing.expectEqual(@as(f32, 55), m.sizeAt(1));
    // 新插入的行还没测过，走估算。
    try testing.expectEqual(@as(f32, 10), m.sizeAt(0));
}

test "measurements: invalidate returns a row to estimate state" {
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();
    _ = m.applyMeasurement(2, 40, 0, .idle);
    try testing.expectEqual(@as(f32, 40), m.sizeAt(2));
    try testing.expect(m.hasMeasurement(2));

    m.invalidate(2);
    try testing.expect(!m.hasMeasurement(2));
    try testing.expectEqual(@as(f32, 10), m.sizeAt(2));
}

test "measurements: count growth keeps existing measurements" {
    var m = Measurements.init(testing.allocator, .{ .count = 3, .estimate = 10 });
    defer m.deinit();
    _ = m.applyMeasurement(1, 30, 0, .idle);
    try testing.expectEqual(@as(f32, 50), m.totalHeight()); // 10+30+10

    m.setCount(6);
    try testing.expectEqual(@as(f32, 80), m.totalHeight()); // +3*10
    try testing.expectEqual(@as(f32, 30), m.sizeAt(1)); // 实测未丢
}

test "measurements: count shrink does not read stale tail" {
    var m = Measurements.init(testing.allocator, .{ .count = 50, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    m.setCount(3);
    try testing.expectEqual(@as(f32, 30), m.totalHeight());
    try testing.expectEqual(@as(usize, 3), m.layout.len);
}

test "measurements: non-finite and non-positive measurements are rejected" {
    var m = Measurements.init(testing.allocator, .{ .count = 3, .estimate = 10 });
    defer m.deinit();
    try testing.expect(!m.applyMeasurement(0, 0, 0, .idle).changed);
    try testing.expect(!m.applyMeasurement(0, -5, 0, .idle).changed);
    try testing.expect(!m.applyMeasurement(0, std.math.nan(f32), 0, .idle).changed);
    try testing.expect(!m.applyMeasurement(0, std.math.inf(f32), 0, .idle).changed);
    try testing.expectEqual(@as(f32, 30), m.totalHeight());
}

test "measurements: gap and padding_start shift the prefix sums" {
    var m = Measurements.init(testing.allocator, .{
        .count = 3,
        .estimate = 10,
        .gap = 5,
        .padding_start = 7,
    });
    defer m.deinit();
    try testing.expectEqual(@as(f32, 7), m.offsetOf(0));
    try testing.expectEqual(@as(f32, 22), m.offsetOf(1)); // 7+10+5
    try testing.expectEqual(@as(f32, 37), m.offsetOf(2));
    // 总高不含尾部 gap。
    try testing.expectEqual(@as(f32, 47), m.totalHeight());
}

test "measurements: estimate_fn allows per-index estimates" {
    var m = Measurements.init(testing.allocator, .{ .count = 4, .estimate_fn = fixedEstimate });
    defer m.deinit();
    try testing.expectEqual(@as(f32, 80), m.totalHeight());
    try testing.expectEqual(@as(f32, 40), m.offsetOf(2));
}

test "measurements: repeated identical measurement is a no-op after the first" {
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();

    const first = m.applyMeasurement(0, 25, 0, .idle);
    try testing.expect(first.changed);
    m.ensureBuilt();

    // 同值复测：不该再标脏（否则每帧全表重建）。
    const again = m.applyMeasurement(0, 25, 0, .idle);
    try testing.expect(!again.changed);
    try testing.expectEqual(@as(?usize, null), m.pending_min);
}

test "measurements: unchanged first measurement is still recorded as measured" {
    // 首测量到的值恰好等于估算值时，delta==0 但仍必须记账；
    // 否则它永远停留在"未测量"，复测判据（整体在视口线上方）走不到。
    var m = Measurements.init(testing.allocator, .{ .count = 5, .estimate = 10 });
    defer m.deinit();
    m.ensureBuilt();
    _ = m.applyMeasurement(0, 10, 0, .idle);
    try testing.expect(m.hasMeasurement(0));
}
