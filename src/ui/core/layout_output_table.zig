//! LayoutOutputTable, v0.10 §L NodeLayoutOutput SoA, dense by ElementId
//!
//! 与 ElementTable 一一对应：每个 element 创建时同步 ensureSlot。
//! Stage 1 (本提交): 双写期。Node.visuals.layout_output 仍是 source of truth；
//! 此表是**非 owning 镜像**, shallow copy NodeLayoutOutput（含 ?PathGeometry
//! 指针的别名拷贝）。in-place 字段仍负责 path 的 clone/freePathGeometry
//! 生命周期；本表 clear **不 free**（否则与 in-place double-free）。
//!
//! Stage 3 删 in-place 字段后，本表成 source of truth，届时 clear 路径才
//! 接管 freePathGeometry（见 V10_ALIGNMENT_PLAN.md §L Stage 3 + 风险节）。
//!
//! NodeLayoutOutput.artifacts.text_layout 是定长 TextLayout struct（无堆/
//! 无自指 slice），普通值拷贝即可，无 §a ContentTable 的 fixupAfterMove 问题。

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const nlo = @import("node_layout_output.zig");

pub const ElementId = element_id_mod.ElementId;
pub const NodeLayoutOutput = nlo.NodeLayoutOutput;

pub const LayoutOutputTable = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(NodeLayoutOutput),

    pub fn init(allocator: std.mem.Allocator) LayoutOutputTable {
        return .{ .allocator = allocator, .items = .{} };
    }

    pub fn deinit(self: *LayoutOutputTable) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Grow items 到 index。NodeLayoutOutput 无自指 slice（TextLayout 定长、
    /// PathGeometry 是指针），ArrayList 扩容 move 不需要 re-fixup。
    pub fn ensureSlot(self: *LayoutOutputTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        while (self.items.items.len <= idx) {
            try self.items.append(self.allocator, .{});
        }
    }

    pub fn get(self: *const LayoutOutputTable, id: ElementId) ?NodeLayoutOutput {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return self.items.items[id.index];
    }

    /// 取可变指针（layout_engine per-frame 原地改 artifacts 用，避免整 struct 回写）。
    pub fn getPtr(self: *LayoutOutputTable, id: ElementId) ?*NodeLayoutOutput {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return &self.items.items[id.index];
    }

    pub fn set(self: *LayoutOutputTable, id: ElementId, v: NodeLayoutOutput) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index] = v;
    }

    /// Cx.destroyElement 调。Stage 1: 非 owning 镜像，**只重置不 free**
    /// （path geometry 由 in-place 字段的 owner 释放）。Stage 3 接管 free。
    pub fn clear(self: *LayoutOutputTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index] = .{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LayoutOutputTable: init/deinit empty" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
}

test "LayoutOutputTable: ensureSlot grows up to index" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 3, .generation = 1 };
    try t.ensureSlot(id);
    try testing.expectEqual(@as(usize, 4), t.items.items.len);
    // 默认空 NodeLayoutOutput
    const got = t.get(id).?;
    try testing.expect(got.vector.fill.path == null);
    try testing.expect(got.artifacts.children_bbox == null);
}

test "LayoutOutputTable: set / get roundtrip (artifacts + stroke POD)" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    var v: NodeLayoutOutput = .{};
    v.artifacts.children_bbox = .{ .x = 1, .y = 2, .w = 30, .h = 40 };
    v.vector.stroke.width = 3.5;
    t.set(id, v);

    const got = t.get(id).?;
    try testing.expectEqual(@as(f32, 30), got.artifacts.children_bbox.?.w);
    try testing.expectEqual(@as(f32, 3.5), got.vector.stroke.width);
}

test "LayoutOutputTable: getPtr mutates in place" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 1, .generation = 1 };
    try t.ensureSlot(id);

    const p = t.getPtr(id).?;
    p.artifacts.children_bbox = .{ .x = 0, .y = 0, .w = 99, .h = 0 };
    try testing.expectEqual(@as(f32, 99), t.get(id).?.artifacts.children_bbox.?.w);
}

test "LayoutOutputTable: clear resets slot (non-owning, no free)" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);
    var v: NodeLayoutOutput = .{};
    v.artifacts.children_bbox = .{ .x = 0, .y = 0, .w = 5, .h = 5 };
    t.set(id, v);

    t.clear(id);
    try testing.expect(t.get(id).?.artifacts.children_bbox == null);
}
