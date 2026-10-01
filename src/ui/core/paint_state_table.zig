//! PaintStateTable, v0.9-§b paint state SoA, dense by ElementId
//!
//! 持有 Node.style 内的 paint-state 字段 (background, opacity, border 等)。
//! Stage 1: 基建 + Node accessor + Cx.init 注册 read/write callback。
//! 本表当前为镜像；style.background 等仍是 source of truth (类似 §a stage 1)。
//! Stage 2+: caller 全切 getter，Stage 3 删 Node.style 字段。
//!
//! TODO: 字段集仍在 design 中；初版只覆盖 background + opacity 验证机制。
//! 后续按 caller 频度逐个搬。

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const types = @import("types.zig");

pub const ElementId = element_id_mod.ElementId;
pub const Color = types.Color;

/// Per-element paint state mirror.
pub const PaintStateData = struct {
    background: Color = Color.TRANSPARENT,
    opacity: f32 = 1.0,
};

pub const PaintStateTable = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(PaintStateData),

    pub fn init(allocator: std.mem.Allocator) PaintStateTable {
        return .{ .allocator = allocator, .items = .{} };
    }

    pub fn deinit(self: *PaintStateTable) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureSlot(self: *PaintStateTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        while (self.items.items.len <= idx) {
            try self.items.append(self.allocator, .{});
        }
    }

    pub fn get(self: *const PaintStateTable, id: ElementId) ?PaintStateData {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return self.items.items[id.index];
    }

    pub fn setBackground(self: *PaintStateTable, id: ElementId, c: Color) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index].background = c;
    }

    pub fn setOpacity(self: *PaintStateTable, id: ElementId, o: f32) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index].opacity = o;
    }

    pub fn clear(self: *PaintStateTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index] = .{};
    }
};

test "PaintStateTable: init/deinit empty" {
    var t = PaintStateTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
}

test "PaintStateTable: ensureSlot + setBackground/getOpacity roundtrip" {
    var t = PaintStateTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 2, .generation = 1 };
    try t.ensureSlot(id);
    try testing.expectEqual(@as(usize, 3), t.items.items.len);
    try testing.expectEqual(Color.TRANSPARENT, t.get(id).?.background);

    t.setBackground(id, Color.rgba(255, 0, 0, 255));
    t.setOpacity(id, 0.5);
    const data = t.get(id).?;
    try testing.expectEqual(@as(u8, 255), data.background.r);
    try testing.expectEqual(@as(f32, 0.5), data.opacity);
}
