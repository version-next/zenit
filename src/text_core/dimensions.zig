//! Phase 0 — Dim trait / 统一的 SumTree seek 维度入口
//!
//! 对齐 Zed `crates/sum_tree/src/sum_tree.rs:95-110` 的
//! `trait Dimension<'a, S: Summary>`。
//!
//! SumTree 的 Cursor 需要按不同维度 seek：
//!   - ByteDim / ByteOffset  — 按字节偏移
//!   - LineDim / Row         — 按行号
//!   - PointDim              — 按 (row, column)
//!   - CharDim               — 按字符数
//!   - OffsetUtf16           — 按 UTF-16 code unit
//!
//! 每个维度都实现一个"从 Summary 提取值 + 累加两个值"的契约。Phase 0 只定义
//! 契约 + 空壳，具体维度在 Phase 2 `src/core/rope/summary.zig` 里逐一实现。
//!
//! Zig 没有 Rust 的 trait；这里用 **结构化鸭子类型**：每个 Dim 类型必须满足
//!
//!   ```zig
//!   pub const Self = @This();
//!   pub const ZERO: Self;                      // 该维度的零值
//!   pub fn fromSummary(s: Summary) Self;       // 从 Summary 投影出本维度的值
//!   pub fn addAssign(self: *Self, other: Self) void;  // 累加（monoid add）
//!   pub fn cmp(a: Self, b: Self) std.math.Order;      // 全序（用于 seek）
//!   ```
//!
//! Phase 2 的 `SumTree.Cursor(Dim, OtherDim)` 会 `@hasDecl(Dim, ...)` 强制检查。
//!
//! 本文件目前只提供：
//!   - `isValidDim(comptime Dim, comptime Summary)` 编译期检查辅助
//!   - 一个 `Unit` 空维度作为占位（Cursor 第二维度可选时使用）

const std = @import("std");

/// 空维度。用作 `Cursor(Dim, Unit)` 里的 "不跟踪第二维度" 占位。
/// 所有方法都是 no-op。
pub const Unit = struct {
    pub const ZERO: Unit = .{};

    pub fn fromSummary(s: anytype) Unit {
        _ = s;
        return .{};
    }

    pub fn addAssign(self: *Unit, other: Unit) void {
        _ = self;
        _ = other;
    }

    pub fn cmp(a: Unit, b: Unit) std.math.Order {
        _ = a;
        _ = b;
        return .eq;
    }
};

/// 编译期契约检查：Dim 必须满足 Dimension<Summary> 的四条方法。
///
/// 用法：
/// ```zig
/// comptime isValidDim(ByteOffset, TextSummary);  // 若缺方法则编译报错
/// ```
pub fn isValidDim(comptime Dim: type, comptime Summary: type) void {
    if (!@hasDecl(Dim, "ZERO")) @compileError(@typeName(Dim) ++ " missing ZERO constant");
    if (!@hasDecl(Dim, "fromSummary")) @compileError(@typeName(Dim) ++ " missing fromSummary(Summary) " ++ @typeName(Dim));
    if (!@hasDecl(Dim, "addAssign")) @compileError(@typeName(Dim) ++ " missing addAssign(*Self, Self) void");
    if (!@hasDecl(Dim, "cmp")) @compileError(@typeName(Dim) ++ " missing cmp(Self, Self) Order");
    _ = Summary; // 占位；Phase 2 会加上签名细节校验
}

// ============================================================================
// Tests
// ============================================================================

test "Unit is a valid Dim for any Summary" {
    comptime isValidDim(Unit, struct {});
    var u: Unit = Unit.ZERO;
    u.addAssign(.{});
    try std.testing.expectEqual(std.math.Order.eq, Unit.cmp(.{}, .{}));
}

// 一个最小化 Dim 示例：u64 byte offset 维度，绑定到任意带 `len: u64` 字段的 Summary。
const DummySummary = struct {
    len: u64 = 0,
    pub const ZERO: DummySummary = .{};
    pub fn add(self: DummySummary, other: DummySummary) DummySummary {
        return .{ .len = self.len + other.len };
    }
};

const DummyByteDim = struct {
    value: u64 = 0,
    pub const ZERO: DummyByteDim = .{};
    pub fn fromSummary(s: DummySummary) DummyByteDim {
        return .{ .value = s.len };
    }
    pub fn addAssign(self: *DummyByteDim, other: DummyByteDim) void {
        self.value += other.value;
    }
    pub fn cmp(a: DummyByteDim, b: DummyByteDim) std.math.Order {
        return std.math.order(a.value, b.value);
    }
};

test "custom Dim passes isValidDim" {
    comptime isValidDim(DummyByteDim, DummySummary);
    var dim: DummyByteDim = DummyByteDim.ZERO;
    dim.addAssign(DummyByteDim.fromSummary(.{ .len = 10 }));
    dim.addAssign(DummyByteDim.fromSummary(.{ .len = 5 }));
    try std.testing.expectEqual(@as(u64, 15), dim.value);
}
