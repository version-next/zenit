//! 菜单键盘导航的共享纯逻辑 —— 供 Menu / DropdownMenu 复用。
//!
//! 背景：`nextEnabledIndex`（跳过 separator 和 disabled 项的循环查找）此前
//! 在三个地方各写了一份：`menu/mod.zig`、`dropdown_menu/mod.zig`，以及一个
//! 全仓零引用的死文件 `menu_core.zig`。两个活实现当时逐字节相同，但没有任何
//! 机制保证它们继续保持一致——改一份忘另一份，Menu 和 DropdownMenu 的键盘
//! 行为就会分叉，而两边各自的测试都会继续绿。
//!
//! 这里只抽真正共享的那一个函数。Menu 与 DropdownMenu 的 item 类型不同
//! （`MenuItem` / `DropdownItem`），但都有 `kind` 与 `disabled` 两个字段，
//! 所以按 duck typing 泛型化，不强行统一两边的 item 类型。

const std = @import("std");

/// 从 `from` 出发按方向找下一个「可聚焦」项的下标，跳过 separator 与
/// disabled 项，到边界回绕。全部项都不可选时返回 null。
///
/// `items` 的元素需要有 `kind`（枚举，值 `.item` 表示真正的菜单项）和
/// `disabled`（bool）两个字段。
pub fn nextEnabledIndex(items: anytype, from: usize, forward: bool) ?usize {
    const len = items.len;
    if (len == 0) return null;
    var idx = from;
    var count: usize = 0;
    while (count < len) : (count += 1) {
        if (forward) {
            idx = if (idx + 1 >= len) 0 else idx + 1;
        } else {
            idx = if (idx == 0) len - 1 else idx - 1;
        }
        if (items[idx].kind == .item and !items[idx].disabled) return idx;
    }
    return null;
}

const TestKind = enum { item, separator };
const TestItem = struct {
    kind: TestKind = .item,
    disabled: bool = false,
};

test "nextEnabledIndex 跳过 separator 与 disabled" {
    const items = [_]TestItem{
        .{},
        .{ .kind = .separator },
        .{ .disabled = true },
        .{},
    };
    try std.testing.expectEqual(@as(?usize, 3), nextEnabledIndex(&items, 0, true));
    try std.testing.expectEqual(@as(?usize, 0), nextEnabledIndex(&items, 3, true));
    try std.testing.expectEqual(@as(?usize, 0), nextEnabledIndex(&items, 3, false));
}

test "nextEnabledIndex 全不可选时返回 null" {
    const items = [_]TestItem{
        .{ .kind = .separator },
        .{ .disabled = true },
    };
    try std.testing.expectEqual(@as(?usize, null), nextEnabledIndex(&items, 0, true));
    try std.testing.expectEqual(@as(?usize, null), nextEnabledIndex(&items, 0, false));
}

test "nextEnabledIndex 空列表返回 null" {
    const items = [_]TestItem{};
    try std.testing.expectEqual(@as(?usize, null), nextEnabledIndex(&items, 0, true));
}

test "nextEnabledIndex 单个可选项时回绕到自己" {
    const items = [_]TestItem{ .{ .kind = .separator }, .{}, .{ .disabled = true } };
    try std.testing.expectEqual(@as(?usize, 1), nextEnabledIndex(&items, 1, true));
    try std.testing.expectEqual(@as(?usize, 1), nextEnabledIndex(&items, 1, false));
}
