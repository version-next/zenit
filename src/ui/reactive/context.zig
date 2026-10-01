/// Context，通用跨层级依赖注入
///
/// 基于 Scope 树向上查找，零额外分配（栈内 8 slot）。
///
/// 用法:
/// ```zig
/// // 提供者
/// const ThemeCtx = Context(*ThemeTokens);
/// try ThemeCtx.provide(scope, &my_tokens);
///
/// // 消费者（任意子 scope 中）
/// const tokens = ThemeCtx.consume(scope) orelse &default_tokens;
/// ```
const std = @import("std");
const Scope = @import("scope.zig").Scope;

/// 生成类型唯一 ID。
///
/// 不能使用空泛型函数的地址：ReleaseFast 的 identical-code folding 会把
/// 不同 `T` 的空函数合并到同一地址，导致 context 槽碰撞及错误类型指针转换。
/// 每个泛型实例的可变静态 token 必须有独立、可观察的存储地址。
fn typeId(comptime T: type) usize {
    const S = struct {
        var token: struct { type_marker: ?*T = null } = .{};
    };
    return @intFromPtr(&S.token);
}

/// 泛型 Context，通过类型参数自动选择不同的 slot
pub fn Context(comptime T: type) type {
    return struct {
        /// 在当前 scope 注册一个 context 值
        pub fn provide(scope: *Scope, value: *T) !void {
            try scope.setContext(typeId(T), @ptrCast(value));
        }

        /// 沿 parent 链向上查找最近的 context 值
        pub fn consume(scope: *Scope) ?*T {
            if (scope.getContext(typeId(T))) |ptr| {
                return @ptrCast(@alignCast(ptr));
            }
            return null;
        }
    };
}

/// Scope 上下文条目（内联在 scope.zig 的 ContextSlot 中）
pub const ContextSlot = struct {
    type_id: usize = 0,
    ptr: ?*anyopaque = null,
};

pub const max_context_slots = 16;

const testing = std.testing;
const owner_mod = @import("owner.zig");

test "Context: child scope shadows parent scope" {
    const Theme = struct { value: i32 };
    const ThemeCtx = Context(Theme);

    const owner = try owner_mod.SignalOwner.init(testing.allocator);
    defer owner.deinit();

    const root = try Scope.init(testing.allocator, null, owner);
    defer root.dispose();
    const child = try root.childScope();

    var parent_theme = Theme{ .value = 1 };
    try ThemeCtx.provide(root, &parent_theme);
    try testing.expectEqual(@as(i32, 1), ThemeCtx.consume(child).?.value);

    var child_theme = Theme{ .value = 2 };
    try ThemeCtx.provide(child, &child_theme);
    try testing.expectEqual(@as(i32, 2), ThemeCtx.consume(child).?.value);
    try testing.expectEqual(@as(i32, 1), ThemeCtx.consume(root).?.value);
}

test "Context: distinct types retain distinct IDs in optimized builds" {
    const A = struct { value: u8 };
    const B = struct { value: u8 };
    try testing.expect(typeId(A) != typeId(B));
}
