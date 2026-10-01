//! Anchor，在文档编辑中保持稳定的位置标记。
//!
//! 参考 Zed `text::Anchor`。我们的实现基于 PieceTree 的 `(source, buffer_offset)` 对：
//!   - `original_buffer` 和 `add_buffer` 都是 **append-only**（insert 只追加、delete 不实际释放）
//!   - 所以 `(source, buffer_offset)` 是该字节的**永久坐标**
//!   - 即使 piece 因 insert/delete 被 split / replace，`buffer_offset` 指向的字节不变
//!   - resolve 时扫当前 piece 列表，找到包含该 `(source, offset)` 的 piece，算出 doc offset
//!
//! ## Bias 语义
//!
//! 当 anchor 位置正好位于某次 insert 的起点或 delete 边界时，Bias 决定 anchor 偏向哪边：
//!   - `.left`：anchor "粘"在左侧字符后 -> insert 在 anchor 位置时，anchor 不移动
//!   - `.right`：anchor "粘"在右侧字符前 -> insert 在 anchor 位置时，anchor 跟着往右移
//!
//! 典型用法：
//!   - `Selection.start` 用 `.right`（选区起点跟着后面的字符走）
//!   - `Selection.end` 用 `.left`（选区终点粘在前面的字符）
//!
//! 删除场景：如果 anchor 落在被删除的范围内，resolve 会根据 bias 回退到
//!   range.start（.left）或 range.end（.right）。
//!
//! ## 历史备注
//!
//! Phase 0 的占位 `Anchor` 基于 `(timestamp, offset, Unclipped)` 模拟 OT 语义。
//! 该设计对齐 Zed `text::Anchor`，但 resolve 需要 PieceTree 记录每次编辑的 diff log。
//! 为了在 Phase 1.5 就能交付可用 Anchor（给 Find Panel / Multi-cursor 用），
//! 改为基于 PieceTree 本身结构（append-only buffer）的简化实现。
//!
//! 两个实现都对齐 Zed 概念；差别在于 resolve 的查找策略。
//! 未来若需要 OT 语义可扩展为 `(source, buffer_offset, bias, version)`。

const std = @import("std");

/// Bias，决定 anchor 在编辑边界上的"粘性"方向。
pub const Bias = enum(u8) {
    /// 粘左（anchor 在字符之间时偏向左边的字符）
    left,
    /// 粘右（anchor 在字符之间时偏向右边的字符）
    right,
};

/// PieceTree 的 source 枚举镜像。
/// 值必须与 `piece_tree.Source` 一致（piece_tree 会用 `@intFromEnum` 转换）。
pub const Source = enum(u8) {
    original = 0,
    add = 1,
};

/// Anchor kind：normal = 普通锚点；start/end = 文档两端特殊锚点。
pub const Kind = enum(u8) {
    /// 普通 anchor：基于 (source, buffer_offset) 解析
    normal,
    /// 文档起始：resolve 永远返回 0
    start_of_document,
    /// 文档末尾：resolve 永远返回 totalLength()
    end_of_document,
};

/// Anchor，稳定位置标记。
///
/// 两个特殊常量：
///   - `START`：永远指向文档 offset 0
///   - `END`：永远指向文档末尾（totalLength）
pub const Anchor = struct {
    /// 源 buffer（original / add）。kind != .normal 时忽略此字段。
    source: Source,
    /// 该 buffer 中的字节偏移。kind != .normal 时忽略此字段。
    buffer_offset: usize,
    /// 粘性方向。
    bias: Bias,
    /// Anchor kind。
    kind: Kind,

    pub const START: Anchor = .{
        .source = .original,
        .buffer_offset = 0,
        .bias = .left,
        .kind = .start_of_document,
    };

    pub const END: Anchor = .{
        .source = .original,
        .buffer_offset = 0,
        .bias = .right,
        .kind = .end_of_document,
    };

    pub fn eql(a: Anchor, b: Anchor) bool {
        if (a.kind != b.kind) return false;
        if (a.kind != .normal) return true;
        return a.source == b.source and
            a.buffer_offset == b.buffer_offset and
            a.bias == b.bias;
    }

    /// 判断 anchor 是否指向某 source 的某 offset（忽略 bias 和 kind）
    pub fn pointsTo(self: Anchor, source: Source, offset: usize) bool {
        if (self.kind != .normal) return false;
        return self.source == source and self.buffer_offset == offset;
    }
};

/// 一段范围（起点 + 终点，都是 anchor）。
pub const AnchorRange = struct {
    start: Anchor,
    end: Anchor,

    pub fn eql(a: AnchorRange, b: AnchorRange) bool {
        return Anchor.eql(a.start, b.start) and Anchor.eql(a.end, b.end);
    }
};

// ============================================================================
// Tests（纯类型测试，不依赖 PieceTree；resolve 测试在 piece_tree.zig）
// ============================================================================

const testing = std.testing;

test "Anchor.START and END are singletons" {
    try testing.expect(Anchor.eql(Anchor.START, Anchor.START));
    try testing.expect(Anchor.eql(Anchor.END, Anchor.END));
    try testing.expect(!Anchor.eql(Anchor.START, Anchor.END));
}

test "Anchor.eql ignores buffer_offset for special kinds" {
    var mutated_start = Anchor.START;
    mutated_start.buffer_offset = 999;
    try testing.expect(Anchor.eql(mutated_start, Anchor.START));
}

test "Anchor.eql compares normal anchors by source+offset+bias" {
    const a: Anchor = .{ .source = .add, .buffer_offset = 10, .bias = .left, .kind = .normal };
    const b: Anchor = .{ .source = .add, .buffer_offset = 10, .bias = .left, .kind = .normal };
    const c: Anchor = .{ .source = .add, .buffer_offset = 10, .bias = .right, .kind = .normal };
    const d: Anchor = .{ .source = .original, .buffer_offset = 10, .bias = .left, .kind = .normal };

    try testing.expect(Anchor.eql(a, b));
    try testing.expect(!Anchor.eql(a, c));
    try testing.expect(!Anchor.eql(a, d));
}

test "AnchorRange equality" {
    const r1: AnchorRange = .{ .start = Anchor.START, .end = Anchor.END };
    const r2: AnchorRange = .{ .start = Anchor.START, .end = Anchor.END };
    try testing.expect(AnchorRange.eql(r1, r2));
}

test "Anchor.pointsTo detects source + offset match" {
    const a: Anchor = .{ .source = .add, .buffer_offset = 42, .bias = .left, .kind = .normal };
    try testing.expect(a.pointsTo(.add, 42));
    try testing.expect(!a.pointsTo(.add, 43));
    try testing.expect(!a.pointsTo(.original, 42));
}

test "Anchor.pointsTo returns false for special kinds" {
    try testing.expect(!Anchor.START.pointsTo(.original, 0));
    try testing.expect(!Anchor.END.pointsTo(.original, 0));
}
