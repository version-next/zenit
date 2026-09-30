//! Phase 0 — LocalClock / Global / EditTimestamp
//!
//! 对齐 Zed `crates/clock/src/clock.rs` 的 `Lamport` + `Global` 概念。
//! 非 CRDT 场景下我们只需要一个严格单调递增的 tick 作为版本键。
//!
//! 不变式：
//!   - `tick` 严格单调递增
//!   - 所有 snapshot 携带自己的 tick
//!   - 所有 "edits_since(version)" 查询以 tick 为基准
//!
//! Zed 参考：
//!   - `crates/text/src/text.rs:829-831` `Buffer::version()` 返回 `clock::Global`
//!   - `crates/language/src/syntax_map.rs:329-446` `SyntaxSnapshot::interpolate` 基于
//!     `text.anchored_edits_since(interpolated_version)` 查询

const std = @import("std");

/// 单调递增的本地逻辑时钟。
///
/// 每次编辑 `next()` 得到一个新的 tick，作为 `EditTimestamp`。
/// `observe(other)` 让本地 clock 追赶到某个外部 tick 之后（用于 snapshot 恢复、
/// merge 后台 parse 结果等场景）。
pub const LocalClock = struct {
    tick: u64 = 0,

    /// 产生下一个严格大于当前的 tick。
    pub fn next(self: *LocalClock) u64 {
        self.tick += 1;
        return self.tick;
    }

    /// 让本地 tick 至少追赶到 `other`（若更大）。
    pub fn observe(self: *LocalClock, other: u64) void {
        if (other > self.tick) self.tick = other;
    }

    /// 比较两个版本的顺序。
    pub fn cmp(a: LocalClock, b: LocalClock) std.math.Order {
        return std.math.order(a.tick, b.tick);
    }

    /// 返回当前 tick 的值快照（用于只读比较）。
    pub fn value(self: LocalClock) u64 {
        return self.tick;
    }
};

/// Zed 的 `clock::Global` 是 Lamport 向量时钟；我们单机场景下它就是 `LocalClock`。
/// 保留 `Global` 名字让 `Buffer`/`BufferSnapshot`/`SyntaxSnapshot` 等下游用统一签名。
pub const Global = LocalClock;

/// 单次编辑的时间戳。对齐 Zed `clock::Lamport`，但非 CRDT 场景下只是一个 u64。
pub const EditTimestamp = u64;

// ============================================================================
// Tests
// ============================================================================

test "LocalClock.next is strictly monotonic" {
    var clock: LocalClock = .{};
    const a = clock.next();
    const b = clock.next();
    const c = clock.next();
    try std.testing.expect(a < b);
    try std.testing.expect(b < c);
    try std.testing.expectEqual(@as(u64, 1), a);
    try std.testing.expectEqual(@as(u64, 2), b);
    try std.testing.expectEqual(@as(u64, 3), c);
}

test "LocalClock.observe pulls tick forward but never backward" {
    var clock: LocalClock = .{ .tick = 5 };
    clock.observe(3);
    try std.testing.expectEqual(@as(u64, 5), clock.tick);
    clock.observe(10);
    try std.testing.expectEqual(@as(u64, 10), clock.tick);
    clock.observe(10);
    try std.testing.expectEqual(@as(u64, 10), clock.tick);
}

test "LocalClock.cmp orders by tick" {
    const a: LocalClock = .{ .tick = 3 };
    const b: LocalClock = .{ .tick = 5 };
    try std.testing.expectEqual(std.math.Order.lt, LocalClock.cmp(a, b));
    try std.testing.expectEqual(std.math.Order.gt, LocalClock.cmp(b, a));
    try std.testing.expectEqual(std.math.Order.eq, LocalClock.cmp(a, a));
}

test "Global alias behaves like LocalClock" {
    var global: Global = .{};
    const t1 = global.next();
    const t2 = global.next();
    try std.testing.expect(t2 > t1);
}
