//! Phase 0, Point / PointUtf16 / OffsetUtf16
//!
//! 对齐 Zed `crates/text/src/text.rs` 的文本坐标类型。
//!
//! `Point { row, column }` 是 **字节列** 坐标系（row 是 0-based 行号，column 是行内字节偏移）。
//! `PointUtf16` / `OffsetUtf16` 是 UTF-16 code unit 坐标系，供将来 LSP 对齐用。
//!
//! 当前 Phase 0 仅定义类型 + 基本比较/加减；Phase 2 的 Rope.offsetToPoint/pointToOffset
//! 才会真正产生这些 Point。
//!
//! 注意：`src/core/wrap_map.zig` 里已有一个 `DisplayPoint { row, column }`，
//! 那是 **display 层** 的坐标，和这里的 **buffer 层** Point 是不同坐标系。
//! Phase 5 会把 DisplayPoint 从 core 移到 display_map/，此处保持独立。

const std = @import("std");

/// Buffer 坐标系的 (row, column)。column 是字节列。
pub const Point = struct {
    row: u32 = 0,
    column: u32 = 0,

    pub const ZERO: Point = .{};
    pub const MAX: Point = .{ .row = std.math.maxInt(u32), .column = std.math.maxInt(u32) };

    pub fn init(row: u32, column: u32) Point {
        return .{ .row = row, .column = column };
    }

    /// 两个 Point 的顺序：先比 row，row 相同比 column。
    pub fn cmp(a: Point, b: Point) std.math.Order {
        if (a.row != b.row) return std.math.order(a.row, b.row);
        return std.math.order(a.column, b.column);
    }

    pub fn eql(a: Point, b: Point) bool {
        return a.row == b.row and a.column == b.column;
    }

    /// 累加一个 Point：若 other 横跨行则 row += other.row 且 column 变为 other.column；
    /// 否则 row 不变、column += other.column。对齐 Zed `Point::add`。
    pub fn add(self: Point, other: Point) Point {
        if (other.row == 0) {
            return .{ .row = self.row, .column = self.column + other.column };
        }
        return .{ .row = self.row + other.row, .column = other.column };
    }

    /// 两点相减：假设 a >= b。用于 Summary.add 的逆操作。
    /// 对齐 Zed `Point::sub`：若同一行则 (0, a.col - b.col)；否则 (a.row - b.row, a.col)。
    pub fn sub(a: Point, b: Point) Point {
        std.debug.assert(cmp(a, b) != .lt);
        if (a.row == b.row) {
            return .{ .row = 0, .column = a.column - b.column };
        }
        return .{ .row = a.row - b.row, .column = a.column };
    }

    pub fn isZero(self: Point) bool {
        return self.row == 0 and self.column == 0;
    }
};

/// UTF-16 code unit 坐标系的 (row, column)。为 LSP 协议对齐留位；Phase 0 不实现内部逻辑。
pub const PointUtf16 = struct {
    row: u32 = 0,
    column: u32 = 0,

    pub const ZERO: PointUtf16 = .{};

    pub fn init(row: u32, column: u32) PointUtf16 {
        return .{ .row = row, .column = column };
    }
};

/// 全局 UTF-16 offset（单一数字坐标），对齐 Zed `OffsetUtf16`。
pub const OffsetUtf16 = struct {
    value: u64 = 0,

    pub const ZERO: OffsetUtf16 = .{};

    pub fn cmp(a: OffsetUtf16, b: OffsetUtf16) std.math.Order {
        return std.math.order(a.value, b.value);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Point.cmp orders by row then column" {
    const a = Point.init(0, 5);
    const b = Point.init(0, 10);
    const c = Point.init(1, 0);
    try std.testing.expectEqual(std.math.Order.lt, Point.cmp(a, b));
    try std.testing.expectEqual(std.math.Order.lt, Point.cmp(b, c));
    try std.testing.expectEqual(std.math.Order.lt, Point.cmp(a, c));
    try std.testing.expectEqual(std.math.Order.eq, Point.cmp(a, a));
}

test "Point.add same line: column accumulates" {
    const base = Point.init(3, 10);
    const delta = Point.init(0, 5);
    const result = base.add(delta);
    try std.testing.expectEqual(@as(u32, 3), result.row);
    try std.testing.expectEqual(@as(u32, 15), result.column);
}

test "Point.add cross line: row advances and column resets to delta.column" {
    const base = Point.init(3, 10);
    const delta = Point.init(2, 7);
    const result = base.add(delta);
    try std.testing.expectEqual(@as(u32, 5), result.row);
    try std.testing.expectEqual(@as(u32, 7), result.column);
}

test "Point.sub reverses Point.add for same-line case" {
    const base = Point.init(3, 10);
    const delta = Point.init(0, 5);
    const combined = base.add(delta);
    const recovered = combined.sub(base);
    try std.testing.expect(recovered.eql(delta));
}

test "Point.sub cross line" {
    const a = Point.init(5, 8);
    const b = Point.init(3, 10);
    const diff = a.sub(b);
    try std.testing.expectEqual(@as(u32, 2), diff.row);
    try std.testing.expectEqual(@as(u32, 8), diff.column);
}

test "Point.isZero" {
    try std.testing.expect(Point.ZERO.isZero());
    try std.testing.expect(!Point.init(1, 0).isZero());
    try std.testing.expect(!Point.init(0, 1).isZero());
}

test "OffsetUtf16.cmp" {
    const a: OffsetUtf16 = .{ .value = 10 };
    const b: OffsetUtf16 = .{ .value = 20 };
    try std.testing.expectEqual(std.math.Order.lt, OffsetUtf16.cmp(a, b));
}
