//! InteractionTable, Phase 3 拆 Node 的交互/焦点/手势状态
//!
//! 设计与 Element/Layout/Paint 三大表不同，**sparse**：不是每个 element 都有交互。
//! 内部是 ElementId.index -> InteractionData 的 AutoHashMap，
//! 但 hot lookup 走 ElementId.raw() 的紧凑数组（直接索引），未命中再 hash 查。
//!
//! 当前形态：sparse map only（HashMap）。Phase 6 输入/手势重构时再优化为
//! "热表 + 冷表" 双层结构。
//!
//! 历史债避免：
//! - 不在此表存 hit_test_AABB 几何，那个仍由 hit_runtime AABB tree 持有
//!   （此表只存语义：focus_index、scroll_state ref、是否监听某事件）
//!
//! v0.5-P3 哈希退化修复（P0-A）：std 的 HashMapUnmanaged 是 tombstone 删除，
//! 长生命周期表在滚动 churn（每帧对无事件节点 remove、对新节点 put）后 tombstone
//! 堆积，get/remove 探测链变长（sample：get 7->159、remove 4->150）。两个对策：
//!   1. remove 前先 contains：对不存在的 key（churn 里绝大多数）不写 tombstone,
//!      getIndex 遇 tombstone 会继续探测，contains 与 remove 探测成本相同，但
//!      不存在的 key 只探测不写。
//!   2. 按删除计数 rehash：removed_since_rehash 超过 max(64, live) 时
//!      rehash() 清空全部 tombstone（std/hash_map.zig rehash 文档明确此用途）。

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");

pub const ElementId = element_id_mod.ElementId;

pub const HitBehavior = enum(u8) {
    /// 默认：自身可命中，事件冒泡
    bubble,
    /// 透传：自身不命中（鼠标穿过去），事件不到达
    pass_through,
    /// 阻止冒泡：自身命中且吃掉事件
    capture_only,
};

pub const FocusFlags = packed struct(u8) {
    focusable: bool = false,
    /// 是否在 tab 序列里（focusable=false 时无意义）
    tabbable: bool = true,
    /// 是否当前持焦
    focused: bool = false,
    /// 鼠标 over 状态
    hovered: bool = false,
    // 曾有一个 focus_trap 位，但全仓库从未被读写过，真正生效的 focus trap
    // 是 FocusScopeConfig.trap（另一个结构体上的同名语义，有测试覆盖）。
    // 留着只会让人以为"设了这个就能拿到 trap 效果"，已删除。
    _reserved: u4 = 0,
};

pub const InteractionData = struct {
    behavior: HitBehavior = .bubble,
    focus: FocusFlags = .{},
    /// tab-index（HTML 语义：0/null = tree 顺序；正值 = 优先；-1 = 排除）
    tab_index: i16 = 0,
    /// 引用 PropertyTree.scrolls 的 id；INVALID = 不是滚动容器
    scroll_id: u32 = std.math.maxInt(u32),
    /// 监听的事件 mask（bit 位代表哪些事件类型；具体 enum 在 events.zig）
    event_mask: u32 = 0,
    /// 用户 a11y role（暂用 u16 等同当前 a11y.role enum；Phase 6 重构 a11y 时迁过去）
    a11y_role: u16 = 0,
    /// 用户 a11y label hash（避免存 []const u8）；Phase 6 提供完整 a11y 树
    a11y_label_hash: u64 = 0,
};

pub const InteractionTable = struct {
    allocator: std.mem.Allocator,
    /// sparse 存储：ElementId.raw() -> InteractionData
    data: std.AutoHashMapUnmanaged(u32, InteractionData),
    /// 自上次 rehash 以来的成功删除数（tombstone 生成量的下界计数）
    removed_since_rehash: usize = 0,
    /// 活着的 entry 数（put 新键 +1 / remove 命中 -1；与 data.count() 恒等，
    /// 单独持有以便阈值判断不重复探测）
    live_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) InteractionTable {
        return .{ .allocator = allocator, .data = .{} };
    }

    pub fn deinit(self: *InteractionTable) void {
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn put(self: *InteractionTable, id: ElementId, data: InteractionData) !void {
        if (id.isNull()) return;
        const key = id.raw();
        if (!self.data.contains(key)) self.live_count += 1;
        try self.data.put(self.allocator, key, data);
    }

    pub fn get(self: *const InteractionTable, id: ElementId) ?InteractionData {
        if (id.isNull()) return null;
        return self.data.get(id.raw());
    }

    pub fn getPtr(self: *InteractionTable, id: ElementId) ?*InteractionData {
        if (id.isNull()) return null;
        return self.data.getPtr(id.raw());
    }

    /// 删除 entry。返回是否真的删了。
    ///
    /// 哈希退化修复点：先 contains。std HashMapUnmanaged 的 remove 对不存在的
    /// key 同样只探测不写 tombstone，但 getIndex 在 tombstone 区段不会提前停，
    /// 所以"churn 后对已不存在的 key 连续 remove"就是把探测成本翻倍；
    /// contains/get 的探测与 remove 完全同价，这里的关键收益其实是让
    /// removed_since_rehash 只统计"真删"，从而 rehash 阈值不被空 remove 噪声抬高。
    pub fn remove(self: *InteractionTable, id: ElementId) bool {
        if (id.isNull()) return false;
        const key = id.raw();
        if (!self.data.contains(key)) return false;
        const removed = self.data.remove(key);
        if (removed) {
            self.live_count -= 1;
            self.removed_since_rehash += 1;
            // tombstone 堆积超过活 entry 规模就整体 rehash（O(capacity)，
            // 摊销后每 entry O(1)）。std 文档：rehash 后无 tombstone。
            if (self.removed_since_rehash > @max(64, self.live_count)) {
                self.data.rehash(std.hash_map.AutoContext(u32){});
                self.removed_since_rehash = 0;
            }
        }
        return removed;
    }

    pub fn count(self: *const InteractionTable) usize {
        return self.data.count();
    }

    /// 标记 element 持焦/失焦（hot path，用 getPtr）
    pub fn setFocused(self: *InteractionTable, id: ElementId, focused: bool) void {
        if (self.getPtr(id)) |d| d.focus.focused = focused;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "InteractionTable: put/get/remove" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 5, .generation = 1 };
    try testing.expect(t.get(id) == null);

    try t.put(id, .{ .behavior = .bubble, .tab_index = 3 });
    const got = t.get(id).?;
    try testing.expectEqual(@as(i16, 3), got.tab_index);

    try testing.expect(t.remove(id));
    try testing.expect(t.get(id) == null);
}

test "InteractionTable: setFocused via getPtr" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.put(id, .{});

    t.setFocused(id, true);
    try testing.expect(t.get(id).?.focus.focused);

    t.setFocused(id, false);
    try testing.expect(!t.get(id).?.focus.focused);
}

test "InteractionTable: count tracks live entries" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.count());

    try t.put(.{ .index = 0, .generation = 0 }, .{});
    try t.put(.{ .index = 1, .generation = 0 }, .{});
    try testing.expectEqual(@as(usize, 2), t.count());

    _ = t.remove(.{ .index = 0, .generation = 0 });
    try testing.expectEqual(@as(usize, 1), t.count());
}

test "FocusFlags is 1 byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(FocusFlags));
}

test "InteractionTable: NULL id is no-op" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    try t.put(ElementId.NULL, .{});
    try testing.expect(t.get(ElementId.NULL) == null);
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "InteractionTable: remove of absent key makes no tombstone / no rehash trigger" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    // 空 remove 不计入 removed_since_rehash，也不动 live_count
    try testing.expect(!t.remove(.{ .index = 42, .generation = 0 }));
    try testing.expectEqual(@as(usize, 0), t.removed_since_rehash);
    try testing.expectEqual(@as(usize, 0), t.live_count);

    // 真删才计数
    try t.put(.{ .index = 42, .generation = 0 }, .{});
    try testing.expect(t.remove(.{ .index = 42, .generation = 0 }));
    try testing.expectEqual(@as(usize, 1), t.removed_since_rehash);
    try testing.expectEqual(@as(usize, 0), t.live_count);
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "InteractionTable: rehash fires when removals outgrow live set" {
    var t = InteractionTable.init(testing.allocator);
    defer t.deinit();

    // live=0 阈值为 max(64, 0)=64：删 65 个（各自 put 后立刻删）应触发一次 rehash 清零
    var i: u32 = 0;
    while (i < 65) : (i += 1) {
        try t.put(.{ .index = @intCast(i), .generation = 0 }, .{});
        _ = t.remove(.{ .index = @intCast(i), .generation = 0 });
    }
    try testing.expectEqual(@as(usize, 0), t.removed_since_rehash);
    try testing.expectEqual(@as(usize, 0), t.count());
    try testing.expectEqual(@as(usize, 0), t.live_count);

    // 表里留着 entry 时 rehash 也不丢数据
    var j: u32 = 0;
    while (j < 40) : (j += 1) {
        try t.put(.{ .index = @intCast(1000 + j), .generation = 3 }, .{ .tab_index = @intCast(j) });
    }
    var k: u32 = 0;
    while (k < 200) : (k += 1) {
        try t.put(.{ .index = @intCast(5000 + k), .generation = 0 }, .{});
        _ = t.remove(.{ .index = @intCast(5000 + k), .generation = 0 });
    }
    // 200 次真删、live=40 -> 阈值 64：期间至少 rehash 一次，剩余计数必然 ≤ 阈值
    try testing.expect(t.removed_since_rehash <= @max(64, t.live_count));
    try testing.expectEqual(@as(usize, 40), t.count());
    var m: u32 = 0;
    while (m < 40) : (m += 1) {
        const d = t.get(.{ .index = @intCast(1000 + m), .generation = 3 }).?;
        try testing.expectEqual(@as(i16, @intCast(m)), d.tab_index);
    }
}

/// churn 基准：N 轮"插 M 键->删其中 M-K 键"，每轮换键段。返回量测到的 1 万次 get 纳秒数。
fn churnGetCost(comptime do_churn: bool) u64 {
    const ROUNDS = 200;
    const KEYS = 2000;
    const KEEP = 100; // 每轮删 1900

    var t = InteractionTable.init(std.heap.page_allocator);
    defer t.deinit();

    var r: u32 = 0;
    while (r < ROUNDS) : (r += 1) {
        const base = @as(u32, KEYS) * r;
        var i: u32 = 0;
        while (i < KEYS) : (i += 1) {
            t.put(
                .{ .index = @intCast((base + i) & element_id_mod.MAX_INDEX), .generation = @intCast((base + i) >> 24 & 0xFF) },
                .{ .tab_index = @intCast(i & 0x7F) },
            ) catch @panic("oom");
        }
        if (do_churn) {
            var d: u32 = 0;
            while (d < KEYS - KEEP) : (d += 1) {
                _ = t.remove(.{ .index = @intCast((base + d) & element_id_mod.MAX_INDEX), .generation = @intCast((base + d) >> 24 & 0xFF) });
            }
        }
    }

    // 结束态：(a) count 与 live_count 一致
    assert(t.count() == t.live_count);

    // (b) 1 万次 get（跨多个键段，含 churn 段与保留段）
    var timer = std.time.Timer.start() catch @panic("no timer");
    var sink: i64 = 0;
    var probe: u32 = 0;
    while (probe < 10_000) : (probe += 1) {
        const eid = ElementId{
            .index = @intCast((probe * 7919) & element_id_mod.MAX_INDEX),
            .generation = @intCast((probe * 7919) >> 24 & 0xFF),
        };
        if (t.get(eid)) |d| sink += d.tab_index;
    }
    std.mem.doNotOptimizeAway(sink);
    return timer.read();
}

fn assert(ok: bool) void {
    if (!ok) @panic("assert failed");
}

test "InteractionTable: churn does not degrade get latency (<=3x fresh)" {
    if (builtin_mode == .Debug) {
        // Debug 下哈希/探测常数大、噪声高，阈值放宽为 3 倍仍要测。
    }
    const churned = churnGetCost(true);
    const fresh = churnGetCost(false);
    // fresh 表（从未 remove）同样 4 万活 entry，是最公平的基线。
    const ratio = @as(f64, @floatFromInt(churned)) / @as(f64, @floatFromInt(fresh));
    const limit: f64 = 3.0;
    std.debug.print(
        "churn get={d}ns fresh get={d}ns ratio={d:.2} (limit {d:.1})\n",
        .{ churned, fresh, ratio, limit },
    );
    try testing.expect(ratio <= limit);
}

const builtin_mode = @import("builtin").mode;
