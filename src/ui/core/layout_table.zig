//! LayoutTable, Phase 3 拆 Node 的布局产物存储（SoA, dense, indexed by ElementId）
//!
//! 与 ElementTable 一一对应：每个 element 创建时，layout_table 同步分配槽。
//! 字段拆分：constraints_in / final_rect / baseline / layout_epoch / intrinsic_cache。
//! 这样 layout pass 只读 constraints/写 rect，paint pass 只读 rect，各自顺序扫
//! 单字段数组，cache-friendly。
//!
//! 历史债避免：
//! - 不在此表存"渲染缓存"或"命中代理"，那些去 PaintTable / InteractionTable
//! - 不挂 Allocator 给每个 entry, intrinsic_cache 是 inline struct（4 entry，无堆分配）

const std = @import("std");
const testing = std.testing;
const constraint = @import("layout/constraint.zig");
const element_id_mod = @import("element_id.zig");

pub const ElementId = element_id_mod.ElementId;
pub const LayoutInput = constraint.LayoutInput;
pub const LayoutOutput = constraint.LayoutOutput;
pub const Size2D = constraint.Size2D;
pub const IntrinsicCache = constraint.IntrinsicCache;

/// final_rect, element 在父空间的位置 + 测得的尺寸
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub const ZERO: Rect = .{};
};

/// LayoutTable 单条记录
pub const LayoutData = struct {
    /// 父->子约束（最近一次 layout 的输入）
    last_input: LayoutInput = .{ .available_space = .{ .width = .max_content, .height = .max_content } },
    /// 测得尺寸（perform_layout 写入）
    measured: Size2D = .{},
    /// final_rect（在父空间）
    final_rect: Rect = .{},
    /// 第一行 baseline（用于 align-items: baseline）
    first_baseline: ?f32 = null,
    /// 每次重算 layout_epoch++；下游 paint cache 据此判失效
    layout_epoch: u64 = 0,
    /// intrinsic 测量缓存（4-entry direct-mapped）
    intrinsic_cache: IntrinsicCache = .{},
};

pub const LayoutTable = struct {
    allocator: std.mem.Allocator,
    items: std.MultiArrayList(LayoutData),

    pub fn init(allocator: std.mem.Allocator) LayoutTable {
        return .{ .allocator = allocator, .items = .{} };
    }

    pub fn deinit(self: *LayoutTable) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// 确保对应 ElementId 的 slot 存在（按 index 直接定位）。
    /// 调用方负责保持与 ElementTable 同步：element create -> layout.ensure(id)
    pub fn ensureSlot(self: *LayoutTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        while (self.items.len <= idx) {
            try self.items.append(self.allocator, .{});
        }
    }

    pub fn get(self: *const LayoutTable, id: ElementId) ?LayoutData {
        if (id.isNull() or id.index >= self.items.len) return null;
        return self.items.get(id.index);
    }

    pub fn rect(self: *const LayoutTable, id: ElementId) ?Rect {
        if (id.isNull() or id.index >= self.items.len) return null;
        return self.items.items(.final_rect)[id.index];
    }

    pub fn setRect(self: *LayoutTable, id: ElementId, r: Rect) void {
        if (id.isNull() or id.index >= self.items.len) return;
        self.items.items(.final_rect)[id.index] = r;
    }

    /// Reset a dense slot before its ElementTable index is reused by another
    /// generation. Dense auxiliary tables intentionally retain capacity, but no
    /// layout output may cross element ownership.
    pub fn clear(self: *LayoutTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.items.len) return;
        self.items.set(id.index, .{});
    }

    pub fn epoch(self: *const LayoutTable, id: ElementId) u64 {
        if (id.isNull() or id.index >= self.items.len) return 0;
        return self.items.items(.layout_epoch)[id.index];
    }

    /// epoch 与 rect 的单次合并读：epoch==0（已 seed 未 markLaidOut）返回 null。
    /// 热读路径（rectFromWorldOrFallback，全帧十万次级）此前对 epoch()/rect()
    /// 各做一次 MultiArrayList 字段切片派生，Debug 下每次派生都是数个不内联
    /// 调用；这里合并为一次 slice() + 两个字段索引。
    pub fn rectIfLaidOut(self: *const LayoutTable, id: ElementId) ?Rect {
        if (id.isNull() or id.index >= self.items.len) return null;
        const s = self.items.slice();
        if (s.items(.layout_epoch)[id.index] == 0) return null;
        return s.items(.final_rect)[id.index];
    }

    /// 标记该 id 重新布局；epoch++、清 intrinsic cache（输入约束变了）
    pub fn markLaidOut(self: *LayoutTable, id: ElementId, measured: Size2D, r: Rect) void {
        if (id.isNull() or id.index >= self.items.len) return;
        self.items.items(.measured)[id.index] = measured;
        self.items.items(.final_rect)[id.index] = r;
        self.items.items(.layout_epoch)[id.index] +%= 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LayoutTable: ensureSlot grows as needed" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id_5: ElementId = .{ .index = 5, .generation = 0 };
    try t.ensureSlot(id_5);
    try testing.expectEqual(@as(usize, 6), t.items.len);
}

test "LayoutTable: setRect / rect roundtrip" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    t.setRect(id, .{ .x = 10, .y = 20, .width = 100, .height = 50 });

    const r = t.rect(id).?;
    try testing.expectEqual(@as(f32, 10), r.x);
    try testing.expectEqual(@as(f32, 100), r.width);
}

test "LayoutTable: markLaidOut bumps epoch" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    const e0 = t.epoch(id);

    t.markLaidOut(id, .{ .width = 100, .height = 50 }, .{ .x = 0, .y = 0, .width = 100, .height = 50 });
    const e1 = t.epoch(id);
    try testing.expect(e1 > e0);

    t.markLaidOut(id, .{ .width = 200, .height = 50 }, .{ .x = 0, .y = 0, .width = 200, .height = 50 });
    const e2 = t.epoch(id);
    try testing.expect(e2 > e1);
}

test "LayoutTable: invalid id returns null" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 99, .generation = 0 };
    try testing.expect(t.get(id) == null);
    try testing.expect(t.rect(id) == null);
    try testing.expectEqual(@as(u64, 0), t.epoch(id));
}

test "LayoutTable: clear resets rect and epoch" {
    var t = LayoutTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    t.markLaidOut(id, .{ .width = 100, .height = 50 }, .{ .x = 7, .y = 8, .width = 100, .height = 50 });
    t.clear(id);

    try testing.expectEqual(Rect.ZERO, t.rect(id).?);
    try testing.expectEqual(@as(u64, 0), t.epoch(id));
}
