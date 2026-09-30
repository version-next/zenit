//! Phase 0 — Unclipped(T)
//!
//! 对齐 Zed `crates/text/src/text.rs` 的 `Unclipped<T>` wrapper。
//! 用于表示"可以暂时越界的坐标"，供 Anchor 等结构使用。
//!
//! 动机：Anchor 的 offset 可能临时指向一个"不存在"的位置（例如：一次编辑
//! 移除了尾部文本，但某个 Anchor 仍然携带旧的 offset）。Unclipped 是一个显式
//! 标记，告诉读者"这个值可能越界，需要 resolve 后再使用"。
//!
//! 纯类型标签，无运行时开销。

const std = @import("std");

/// `Unclipped(T)` = "携带可能越界的 T"。
pub fn Unclipped(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,

        pub fn wrap(v: T) Self {
            return .{ .value = v };
        }

        pub fn unwrap(self: Self) T {
            return self.value;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Unclipped wraps and unwraps any type" {
    const U = Unclipped(u64);
    const u = U.wrap(42);
    try std.testing.expectEqual(@as(u64, 42), u.unwrap());
}

test "Unclipped is distinct from inner type at comptime" {
    const UInt = Unclipped(u32);
    const UStr = Unclipped([]const u8);
    // 纯类型检查：两种实例化类型不同
    try std.testing.expect(@TypeOf(UInt.wrap(1)) != @TypeOf(UStr.wrap("x")));
}
