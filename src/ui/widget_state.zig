/// Widget State - 组件状态管理
///
/// 允许组件维持跨帧状态。每个组件通过唯一 ID
/// 存储和检索状态。
///
/// 使用方式:
/// 1. 在组件 build() 中通过 StateStore.getOrCreate() 获取状态
/// 2. 状态在帧之间保持不变
/// 3. 通过事件处理器修改状态
/// 4. 状态变化标记脏位, 触发重新渲染
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 编译期检测类型是否有 pub fn deinit(*T) void
fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "deinit"),
        else => false,
    };
}

/// 通过函数指针地址获取类型唯一 ID (比 @typeName 字符串比较更快)
fn typeIdPtr(comptime T: type) *const anyopaque {
    return @ptrCast(&struct {
        fn f(_: *T) void {}
    }.f);
}

/// 类型擦除的状态条目
const StateEntry = struct {
    ptr: *anyopaque,
    destroy_fn: *const fn (*anyopaque, Allocator) void,
    type_id: *const anyopaque,
    type_name: []const u8,
    debug_fn: *const fn (*anyopaque, []u8) []const u8,
};

/// 状态存储 - 管理所有组件状态
pub const StateStore = struct {
    allocator: Allocator,
    states: std.AutoHashMap(u64, StateEntry),

    pub fn init(allocator: Allocator) StateStore {
        return .{
            .allocator = allocator,
            .states = std.AutoHashMap(u64, StateEntry).init(allocator),
        };
    }

    pub fn deinit(self: *StateStore) void {
        var it = self.states.valueIterator();
        while (it.next()) |entry| {
            entry.destroy_fn(entry.ptr, self.allocator);
        }
        self.states.deinit();
    }

    /// 获取或创建类型化状态
    pub fn getOrCreate(self: *StateStore, comptime T: type, id: u64, initial: T) !*T {
        const tid = typeIdPtr(T);
        if (self.states.get(id)) |entry| {
            if (entry.type_id == tid) {
                return @ptrCast(@alignCast(entry.ptr));
            }
            std.log.warn(
                "[StateStore] state id collision: id=0x{x} existing={s} requested={s}; replacing existing state",
                .{ id, entry.type_name, @typeName(T) },
            );
            entry.destroy_fn(entry.ptr, self.allocator);
            _ = self.states.remove(id);
        }

        // 创建新状态
        const state = try self.allocator.create(T);
        // put 失败时刚建的 state 无人持有（devtools mountPanel sweep 第 1 个注入点就漏）。
        // 契约：initial 必须是**不持有资源**的裸结构（全仓 7 个调用点都是 `T{}` / `.{}` 零值，
        // 已逐一核过），这里只 destroy 不 deinit：对未 init 的结构调 deinit 是 UB，而持有资源的
        // initial 在这条稀有路径上会漏掉内部资源。谁要传带资源的 initial，先改这里。
        errdefer self.allocator.destroy(state);
        state.* = initial;

        try self.states.put(id, .{
            .ptr = state,
            .destroy_fn = struct {
                fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                    const typed: *T = @ptrCast(@alignCast(ptr));
                    // 如果类型有 deinit 方法，先调用清理内部资源
                    if (comptime hasDeinit(T)) {
                        typed.deinit();
                    }
                    alloc.destroy(typed);
                }
            }.destroy,
            .type_id = tid,
            .type_name = @typeName(T),
            .debug_fn = struct {
                fn dump(ptr: *anyopaque, out: []u8) []const u8 {
                    const typed: *T = @ptrCast(@alignCast(ptr));
                    return debugFormatSafe(T, out, typed.*);
                }
            }.dump,
        });

        return state;
    }

    /// 获取已存在的状态 (如果不存在返回 null)
    pub fn get(self: *StateStore, comptime T: type, id: u64) ?*T {
        if (self.states.get(id)) |entry| {
            if (entry.type_id != typeIdPtr(T)) {
                std.log.warn(
                    "[StateStore] get type mismatch: id=0x{x} existing={s} requested={s}",
                    .{ id, entry.type_name, @typeName(T) },
                );
                return null;
            }
            return @ptrCast(@alignCast(entry.ptr));
        }
        return null;
    }

    /// 删除状态
    pub fn remove(self: *StateStore, id: u64) void {
        if (self.states.fetchRemove(id)) |kv| {
            kv.value.destroy_fn(kv.value.ptr, self.allocator);
        }
    }

    /// 状态数量
    pub fn count(self: *StateStore) usize {
        return self.states.count();
    }

    /// 按状态指针白名单生成调试状态列表（只格式化命中的状态，避免全量开销）
    pub fn debugEntriesByPtrs(self: *StateStore, allocator: Allocator, ptrs: []const *anyopaque) []DebugStateEntry {
        if (ptrs.len == 0) return &[_]DebugStateEntry{};

        var ptr_set = std.AutoHashMap(usize, void).init(allocator);
        defer ptr_set.deinit();
        // 刻意吞错：本函数只服务 devtools 状态面板（唯一调用方
        // devtools.zig:1981）。OOM 时少几行调试输出是安全降级，
        // 不影响任何产品正确性路径。
        for (ptrs) |ptr| {
            _ = ptr_set.put(@intFromPtr(ptr), {}) catch {};
        }

        var list = std.ArrayList(DebugStateEntry).empty;
        defer list.deinit(allocator);
        var it = self.states.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (!ptr_set.contains(@intFromPtr(value.ptr))) continue;
            var debug_entry: DebugStateEntry = .{
                .id = id,
                .ptr = value.ptr,
                .type_name = value.type_name,
            };
            const text = value.debug_fn(value.ptr, debug_entry.value[0..]);
            debug_entry.value_len = @intCast(text.len);
            _ = list.append(allocator, debug_entry) catch {};
        }
        return list.toOwnedSlice(allocator) catch &[_]DebugStateEntry{};
    }
};

/// DevTools 调试用结构
pub const DebugStateEntry = struct {
    id: u64,
    ptr: *anyopaque,
    type_name: []const u8,
    value: [256]u8 = [_]u8{0} ** 256,
    value_len: u16 = 0,

    pub fn valueSlice(self: *const DebugStateEntry) []const u8 {
        return self.value[0..self.value_len];
    }
};

fn debugFormatSafe(comptime T: type, out: []u8, value: T) []const u8 {
    if (out.len == 0) return out[0..0];
    var writer = std.Io.Writer.fixed(out);
    formatValue(T, value, &writer, 0) catch {
        const written = writer.buffered().len;
        if (out.len >= 3 and written >= 3) {
            out[written - 3] = '.';
            out[written - 2] = '.';
            out[written - 1] = '.';
            return out[0..written];
        }
        const fallback = "<?>";
        const n = @min(out.len, fallback.len);
        if (n > 0) @memcpy(out[0..n], fallback[0..n]);
        return out[0..n];
    };
    return writer.buffered();
}

fn formatValue(comptime T: type, value: T, writer: anytype, depth: u8) !void {
    if (depth > 4) {
        try writer.writeAll("…");
        return;
    }
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => {
            try writer.print("{}", .{value});
        },
        .@"enum" => |info| {
            // 空枚举（`enum(u64) { _ }` opaque id 惯用法）没有 tag 名，@tagName 会编译失败；
            // 非穷举枚举的值也可能落在具名 tag 之外。两种情况都退回打印整数值。
            if (info.fields.len == 0 or !info.is_exhaustive) {
                try writer.print("{d}", .{@intFromEnum(value)});
            } else {
                try writer.print("{s}", .{@tagName(value)});
            }
        },
        .optional => {
            if (value) |v| {
                try formatValue(@TypeOf(v), v, writer, depth + 1);
            } else {
                try writer.writeAll("null");
            }
        },
        .pointer => |p| {
            if (p.size == .slice) {
                const Child = p.child;
                if (Child == u8) {
                    try formatByteSlice(writer, value);
                } else {
                    const len = value.len;
                    try writer.writeAll("[");
                    const preview = @min(len, 4);
                    var i: usize = 0;
                    while (i < preview) : (i += 1) {
                        if (i > 0) try writer.writeAll(", ");
                        try formatValue(Child, value[i], writer, depth + 1);
                    }
                    if (len > preview) try writer.writeAll(", …");
                    try writer.writeAll("]");
                }
            } else {
                const ptr_addr: usize = @intFromPtr(value);
                _ = ptr_addr;
                try writer.writeAll("<ptr>");
            }
        },
        .array => {
            try writer.print("[{d}]", .{value.len});
        },
        .@"struct" => |info| {
            try writer.writeAll("{");
            inline for (info.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(field.name);
                try writer.writeAll("=");
                const field_value = @field(value, field.name);
                try formatValue(field.type, field_value, writer, depth + 1);
            }
            try writer.writeAll("}");
        },
        else => {
            try writer.writeAll("<opaque>");
        },
    }
}

fn formatByteSlice(writer: anytype, bytes: []const u8) !void {
    const max_preview: usize = 64;
    const preview = bytes[0..@min(bytes.len, max_preview)];

    if (std.unicode.utf8ValidateSlice(preview) and isReasonablyPrintableText(preview)) {
        try writer.writeAll("\"");
        try writeEscapedAsciiUtf8(writer, preview);
        if (bytes.len > max_preview) try writer.writeAll("…");
        try writer.writeAll("\"");
        return;
    }

    try writer.print("bytes[{d}](", .{bytes.len});
    const hex_preview = @min(bytes.len, @as(usize, 16));
    for (bytes[0..hex_preview], 0..) |b, i| {
        if (i > 0) try writer.writeAll(" ");
        try writer.print("{x:0>2}", .{b});
    }
    if (bytes.len > hex_preview) try writer.writeAll(" …");
    try writer.writeAll(")");
}

fn isReasonablyPrintableText(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == 0) return false;
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') return false;
        if (c == 0x7F) return false;
    }
    return true;
}

fn writeEscapedAsciiUtf8(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

/// 生成组件状态 ID (基于组件类型名 + 实例索引)
pub fn stateId(comptime component_name: []const u8, instance: u32) u64 {
    var hash: u64 = 0;
    for (component_name) |c| {
        hash = hash *% 31 +% c;
    }
    return hash *% 0x100000000 +% instance;
}

// ========== 测试 ==========

test "StateStore: init/deinit" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "StateStore: getOrCreate" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const CounterState = struct {
        value: i32,
        clicked: bool,
    };

    const state = try store.getOrCreate(CounterState, 1, .{ .value = 0, .clicked = false });
    try std.testing.expectEqual(@as(i32, 0), state.value);

    // 修改状态
    state.value = 42;
    state.clicked = true;

    // 再次获取, 应该得到同一个状态
    const state2 = try store.getOrCreate(CounterState, 1, .{ .value = 0, .clicked = false });
    try std.testing.expectEqual(@as(i32, 42), state2.value);
    try std.testing.expect(state2.clicked);

    // 指针相同
    try std.testing.expect(state == state2);
}

test "StateStore: multiple states" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const state_a = try store.getOrCreate(u32, 1, 100);
    const state_b = try store.getOrCreate(u32, 2, 200);

    try std.testing.expectEqual(@as(u32, 100), state_a.*);
    try std.testing.expectEqual(@as(u32, 200), state_b.*);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}

test "StateStore: get returns null for missing" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const result = store.get(u32, 999);
    try std.testing.expectEqual(@as(?*u32, null), result);
}

test "StateStore: remove" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.getOrCreate(u32, 1, 42);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    store.remove(1);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "stateId: different names produce different IDs" {
    const id1 = stateId("TextInput", 0);
    const id2 = stateId("Checkbox", 0);
    const id3 = stateId("TextInput", 1);

    try std.testing.expect(id1 != id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id2 != id3);
}

test "StateStore: struct state with ArrayList" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const InputState = struct {
        cursor_pos: usize,
        focused: bool,
    };

    const state = try store.getOrCreate(InputState, 1, .{
        .cursor_pos = 0,
        .focused = false,
    });

    state.cursor_pos = 5;
    state.focused = true;

    const state2 = try store.getOrCreate(InputState, 1, .{
        .cursor_pos = 0,
        .focused = false,
    });

    try std.testing.expectEqual(@as(usize, 5), state2.cursor_pos);
    try std.testing.expect(state2.focused);
}

test "StateStore: getOrCreate replaces mismatched type for same id" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const A = struct { v: i32 };
    const B = struct { flag: bool };

    const id: u64 = 0x00ABCDEF;
    const a = try store.getOrCreate(A, id, .{ .v = 9 });
    try std.testing.expectEqual(@as(i32, 9), a.v);

    const b = try store.getOrCreate(B, id, .{ .flag = true });
    try std.testing.expectEqual(true, b.flag);

    try std.testing.expect(store.get(A, id) == null);
    try std.testing.expect(store.get(B, id) != null);
}

test "debugFormatSafe: empty enum (opaque id) prints integer value" {
    const ObjectId = enum(u64) { _ };
    const S = struct { id: ObjectId = @enumFromInt(42) };
    var buf: [128]u8 = undefined;
    const out = debugFormatSafe(S, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, out, "42") != null);
}
