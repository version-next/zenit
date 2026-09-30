/// Store — comptime 展开 struct 字段为独立 Signal，实现细粒度追踪
///
/// 用法:
/// ```zig
/// const AppState = struct { count: i32, name: []const u8 };
/// const store = try StoreOf(AppState).create(scope, .{ .count = 0, .name = "hello" });
/// // 读取（自动追踪依赖）
/// const count = store.get(.count);
/// // 设置（只通知 count 订阅者，name 订阅者不受影响）
/// store.set(.count, 42);
/// ```
const std = @import("std");
const Scope = @import("scope.zig").Scope;
const Signal = @import("signal.zig").Signal;

/// 为 struct T 生成的 Store 类型
pub fn StoreOf(comptime T: type) type {
    const info = @typeInfo(T).@"struct";

    return struct {
        const Self = @This();

        /// 每个字段对应一个独立 Signal
        signals: [info.fields.len]*anyopaque,
        scope: *Scope,

        /// 在 scope 上创建 Store，初始值从 initial 读取
        pub fn create(scope: *Scope, initial: T) !Self {
            var signals: [info.fields.len]*anyopaque = undefined;
            inline for (info.fields, 0..) |f, i| {
                signals[i] = @ptrCast(try scope.createSignal(f.type, @field(initial, f.name)));
            }
            return .{ .signals = signals, .scope = scope };
        }

        /// 读取单个字段（自动追踪依赖）
        pub fn get(self: *const Self, comptime field: std.meta.FieldEnum(T)) FieldType(field) {
            return self.signalPtr(field).get();
        }

        /// 设置单个字段（只通知该字段订阅者）
        pub fn set(self: *Self, comptime field: std.meta.FieldEnum(T), value: FieldType(field)) void {
            self.signalPtr(field).set(value);
        }

        /// 无追踪读取全部字段（snapshot）
        pub fn snapshot(self: *const Self) T {
            var result: T = undefined;
            inline for (info.fields, 0..) |f, i| {
                const signal: *Signal(f.type) = @ptrCast(@alignCast(self.signals[i]));
                @field(result, f.name) = signal.peek();
            }
            return result;
        }

        /// 获取字段的类型
        fn FieldType(comptime field: std.meta.FieldEnum(T)) type {
            return std.meta.fieldInfo(T, field).type;
        }

        fn signalPtr(self: *const Self, comptime field: std.meta.FieldEnum(T)) *Signal(FieldType(field)) {
            return @ptrCast(@alignCast(self.signals[@intFromEnum(field)]));
        }
    };
}

// 测试位于 src/ui/ui.zig 通过完整 import 链跑（store + scope 需要 work/deferred_scheduler 模块）。
// 这里仅做 type-level 编译验证：StoreOf 实例化即所有 method 编译。
test "StoreOf: type instantiates" {
    const Counter = struct { n: i32, name: []const u8 };
    const T = StoreOf(Counter);
    _ = T.create;
    _ = T.get;
    _ = T.set;
    _ = T.snapshot;
}
