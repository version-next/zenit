//! ControlledProp — Phase 7 Radix 风格 controlled / uncontrolled 二元 props
//!
//! 当前 zenit 组件混合用 "props 直接传值"（uncontrolled）和 "外部控制"
//! （controlled），没有统一模式。Radix UI 已经验证 controlled/uncontrolled
//! 二元 props 是组件 API 的最佳实践。
//!
//! 用法：
//!   pub const SelectProps = struct {
//!       /// open: 是否打开。controlled 模式给 value+on_change；uncontrolled 给 default_value
//!       open: ControlledProp(bool) = .{ .uncontrolled = .{ .default = false } },
//!       value: ControlledProp([]const u8) = .{ .uncontrolled = .{ .default = "" } },
//!       ...
//!   };
//!
//! 组件内部：
//!   const state = props.open.read(internal_state);
//!   props.open.write(&internal_state, new_value);
//!
//! 历史债避免：
//! - **不**让组件的 props field 是单一类型 —— 用户既要"传值不管"也要"完全控制"
//! - **不**让 controlled 写入立即生效（必须经 on_change 反馈，确保单一数据源）
//! - **不**用 ?T optional 表达 controlled —— 区分不出 "uncontrolled with null default"

const std = @import("std");
const testing = std.testing;

/// Controlled / uncontrolled 二元 props
///
/// ⚠ **回调形态例外**（2026-07-31 并轨时确认，不是遗漏）：
/// 组件层的 `on_change` 已统一为 `?core.HandlerRef`，但这里保留裸函数
/// 指针，因为 `ControlledProp(T)` 是 comptime 泛型、T 可以是任意类型
/// （`?ValueT` / `?u32` / `bool` …）。HandlerRef 的 payload 通道只支持
/// bool 与 []const u8 两种具体类型 —— 那是刻意的：HandlerRef 存在 Node
/// 里，做成泛型会让 EventHandlers 变成 comptime 类型参数，污染整棵树。
///
/// 所以这里的取舍是：**泛型容器用泛型回调，具体组件用 HandlerRef**。
/// 两者不冲突，也不该强行并轨。
pub fn ControlledProp(comptime T: type) type {
    return union(enum) {
        controlled: Controlled,
        uncontrolled: Uncontrolled,

        pub const Controlled = struct {
            /// 当前值（来自外部状态，单一数据源）
            value: T,
            /// 写入回调（组件请求 caller 改值）
            on_change: ?*const fn (new_value: T, ctx: *anyopaque) void = null,
            /// 回调上下文
            ctx: ?*anyopaque = null,
        };

        pub const Uncontrolled = struct {
            /// 初始值（组件内部首次 mount 时种入 internal state）
            default: T,
            /// 状态变化通知（不影响数据源）
            on_change: ?*const fn (new_value: T, ctx: *anyopaque) void = null,
            ctx: ?*anyopaque = null,
        };

        const Self = @This();

        /// 读当前值。
        /// - controlled：返回 props.value（外部状态）
        /// - uncontrolled：返回 internal（组件内部状态；由 mount 时种 default）
        pub fn read(self: Self, internal: T) T {
            return switch (self) {
                .controlled => |c| c.value,
                .uncontrolled => internal,
            };
        }

        /// 写入。组件状态变化时调。
        /// - controlled：调 on_change 让外部更新；internal 不修改
        /// - uncontrolled：写 internal；可选 on_change 通知
        pub fn write(self: Self, internal: *T, new_value: T) void {
            switch (self) {
                .controlled => |c| {
                    if (c.on_change) |cb| cb(new_value, c.ctx orelse undefined);
                },
                .uncontrolled => |u| {
                    internal.* = new_value;
                    if (u.on_change) |cb| cb(new_value, u.ctx orelse undefined);
                },
            }
        }

        /// 获取 mount 时的初始值。
        pub fn initialValue(self: Self) T {
            return switch (self) {
                .controlled => |c| c.value,
                .uncontrolled => |u| u.default,
            };
        }

        pub fn isControlled(self: Self) bool {
            return self == .controlled;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ControlledProp: uncontrolled read default" {
    const Prop = ControlledProp(i32);
    const p: Prop = .{ .uncontrolled = .{ .default = 42 } };
    try testing.expectEqual(@as(i32, 42), p.initialValue());
    try testing.expect(!p.isControlled());

    var internal: i32 = 42;
    try testing.expectEqual(@as(i32, 42), p.read(internal));

    p.write(&internal, 100);
    try testing.expectEqual(@as(i32, 100), internal);
    try testing.expectEqual(@as(i32, 100), p.read(internal));
}

test "ControlledProp: controlled read external value" {
    const Prop = ControlledProp(i32);
    const p: Prop = .{ .controlled = .{ .value = 99 } };
    try testing.expectEqual(@as(i32, 99), p.initialValue());
    try testing.expect(p.isControlled());

    const internal: i32 = 0; // 在 controlled 模式下 internal 被忽略
    try testing.expectEqual(@as(i32, 99), p.read(internal));
}

test "ControlledProp: controlled write goes to on_change, not internal" {
    const Captured = struct {
        last: i32 = 0,
        fn cb(new_value: i32, ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.last = new_value;
        }
    };
    var captured = Captured{};

    const Prop = ControlledProp(i32);
    const p: Prop = .{
        .controlled = .{
            .value = 5,
            .on_change = &Captured.cb,
            .ctx = &captured,
        },
    };

    var internal: i32 = 5;
    p.write(&internal, 100);

    // on_change 收到了请求，但 internal 不变（外部数据源单一）
    try testing.expectEqual(@as(i32, 100), captured.last);
    try testing.expectEqual(@as(i32, 5), internal);
}

test "ControlledProp: uncontrolled with on_change notifies" {
    const Captured = struct {
        last: bool = false,
        called: u32 = 0,
        fn cb(new_value: bool, ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.last = new_value;
            c.called += 1;
        }
    };
    var captured = Captured{};

    const Prop = ControlledProp(bool);
    const p: Prop = .{
        .uncontrolled = .{
            .default = false,
            .on_change = &Captured.cb,
            .ctx = &captured,
        },
    };

    var internal: bool = false;
    p.write(&internal, true);
    try testing.expect(internal);
    try testing.expect(captured.last);
    try testing.expectEqual(@as(u32, 1), captured.called);
}

test "ControlledProp: works with []const u8" {
    const Prop = ControlledProp([]const u8);
    var internal: []const u8 = "init";
    const p: Prop = .{ .uncontrolled = .{ .default = "init" } };
    try testing.expectEqualStrings("init", p.read(internal));

    p.write(&internal, "new");
    try testing.expectEqualStrings("new", internal);
}
