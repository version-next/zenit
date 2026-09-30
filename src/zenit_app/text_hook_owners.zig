//! 进程级文本钩子（shape font resolver / drawn-width measure / 无 context
//! measure 兜底）的归属栈。
//!
//! 这几个钩子是进程全局的，但 App 可以有多个（主窗口 + DevTools 等辅助
//! 窗口）。此前每个 App.init 直接覆盖、每个 deinit 无条件清空 —— 关掉任一
//! 辅助窗口就把**主窗口**的测量钩子一并拆掉，之后主窗口布局退回平台
//! measure，光标/选区与字形错位。
//!
//! 规则：钩子永远指向栈顶（最近一次 init / setFontSelector 的 App 的
//! selector）；某个 App 析构时只摘掉它自己的条目，钩子回落到新的栈顶
//! （仍存活的 App），栈空才清为 null。与关闭顺序无关。
//!
//! 容量不是上限：owner 超过内联容量时扩到堆上，绝不丢条目（丢掉的若是
//! 主窗口，其余窗口关光后钩子会被清空，主窗口测量随之失效）。
//!
//! 纯数据结构、无 ObjC/Metal 依赖，独立 test target 覆盖（见 build.zig
//! test-text-hook-owners）。

const std = @import("std");

pub fn OwnerStack(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            owner: *const anyopaque,
            ctx: *anyopaque,
        };

        /// 常规情况（≤ capacity 个 App）只用内联存储，零分配。
        inline_entries: [capacity]Entry = undefined,
        /// 超出 capacity 时的堆存储。**不能**丢条目：容量来自单个
        /// MultiWindowApp 的上限，而独立 App.init 不受它约束，进程里 owner
        /// 数可以超过 capacity。旧实现栈满丢最老条目（往往正是主窗口），
        /// 其余窗口关光后栈空、钩子被清成 null，主窗口却还活着。
        heap_entries: ?[]Entry = null,
        len: usize = 0,
        /// 仅溢出时使用；进程级全局栈默认 page_allocator，测试可换成
        /// testing.allocator 检查泄漏。
        allocator: std.mem.Allocator = std.heap.page_allocator,

        fn storage(self: *Self) []Entry {
            return self.heap_entries orelse &self.inline_entries;
        }

        fn constStorage(self: *const Self) []const Entry {
            return self.heap_entries orelse &self.inline_entries;
        }

        /// 登记 / 更新 owner 的 ctx 并把它置于栈顶。返回新的栈顶 ctx。
        /// 只有「新 owner 且存储已满」才会分配；已登记 owner 的更新
        /// （setFontSelector）永不失败。分配失败时栈保持原样。
        pub fn push(self: *Self, owner: *const anyopaque, ctx: *anyopaque) error{OutOfMemory}!*anyopaque {
            const was_registered = self.removeEntry(owner);
            if (!was_registered and self.len == self.storage().len) try self.grow();
            self.storage()[self.len] = .{ .owner = owner, .ctx = ctx };
            self.len += 1;
            return ctx;
        }

        /// 摘掉 owner 的条目，返回摘除后的栈顶 ctx（栈空为 null）。
        pub fn remove(self: *Self, owner: *const anyopaque) ?*anyopaque {
            _ = self.removeEntry(owner);
            if (self.len == 0) self.releaseHeap();
            return self.top();
        }

        pub fn top(self: *const Self) ?*anyopaque {
            return if (self.len == 0) null else self.constStorage()[self.len - 1].ctx;
        }

        fn grow(self: *Self) error{OutOfMemory}!void {
            const old = self.storage();
            const bigger = try self.allocator.alloc(Entry, old.len * 2);
            @memcpy(bigger[0..self.len], old[0..self.len]);
            if (self.heap_entries) |h| self.allocator.free(h);
            self.heap_entries = bigger;
        }

        fn releaseHeap(self: *Self) void {
            if (self.heap_entries) |h| self.allocator.free(h);
            self.heap_entries = null;
        }

        fn removeEntry(self: *Self, owner: *const anyopaque) bool {
            const entries = self.storage();
            var found = false;
            var i: usize = 0;
            while (i < self.len) {
                if (entries[i].owner == owner) {
                    std.mem.copyForwards(Entry, entries[i .. self.len - 1], entries[i + 1 .. self.len]);
                    self.len -= 1;
                    found = true;
                } else i += 1;
            }
            return found;
        }
    };
}

const testing = std.testing;

test "关闭后开的辅助窗口：钩子回落到仍存活的主窗口 selector" {
    var stack: OwnerStack(4) = .{};
    var main_app: u8 = 0;
    var devtools_app: u8 = 0;
    var main_sel: u32 = 1;
    var devtools_sel: u32 = 2;
    try testing.expectEqual(@as(*anyopaque, &main_sel), try stack.push(&main_app, &main_sel));
    try testing.expectEqual(@as(*anyopaque, &devtools_sel), try stack.push(&devtools_app, &devtools_sel));
    // 关 DevTools：钩子必须仍指向主窗口，而不是被清空。
    try testing.expectEqual(@as(?*anyopaque, &main_sel), stack.remove(&devtools_app));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&main_app));
}

test "先关主窗口：栈顶的辅助窗口保持不变" {
    var stack: OwnerStack(4) = .{};
    var a: u8 = 0;
    var b: u8 = 0;
    var sel_a: u32 = 1;
    var sel_b: u32 = 2;
    _ = try stack.push(&a, &sel_a);
    _ = try stack.push(&b, &sel_b);
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.remove(&a));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&b));
}

test "setFontSelector 更新同一 owner：不重复登记，析构后不残留旧 selector" {
    var stack: OwnerStack(4) = .{};
    var a: u8 = 0;
    var b: u8 = 0;
    var builtin_a: u32 = 1;
    var host_a: u32 = 3;
    var sel_b: u32 = 2;
    _ = try stack.push(&a, &builtin_a);
    _ = try stack.push(&b, &sel_b);
    _ = try stack.push(&a, &host_a);
    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expectEqual(@as(?*anyopaque, &host_a), stack.top());
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.remove(&a));
    // 未登记的 owner：no-op
    var stranger: u8 = 0;
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.remove(&stranger));
}

test "栈满扩容而不是丢条目；全部移除后释放堆存储" {
    var stack: OwnerStack(2) = .{ .allocator = testing.allocator };
    var o: [5]u8 = .{ 0, 0, 0, 0, 0 };
    var s: [5]u32 = .{ 0, 1, 2, 3, 4 };
    for (0..5) |i| _ = try stack.push(&o[i], &s[i]);
    try testing.expectEqual(@as(usize, 5), stack.len);
    // 已登记 owner 更新不扩容。
    _ = try stack.push(&o[0], &s[0]);
    try testing.expectEqual(@as(?*anyopaque, &s[0]), stack.top());
    try testing.expectEqual(@as(?*anyopaque, &s[4]), stack.remove(&o[0]));
    try testing.expectEqual(@as(?*anyopaque, &s[4]), stack.remove(&o[2]));
    try testing.expectEqual(@as(?*anyopaque, &s[3]), stack.remove(&o[4]));
    try testing.expectEqual(@as(?*anyopaque, &s[1]), stack.remove(&o[3]));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&o[1]));
    try testing.expect(stack.heap_entries == null);
}

test "扩容分配失败：返回错误且栈保持原样" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var stack: OwnerStack(1) = .{ .allocator = failing.allocator() };
    var a: u8 = 0;
    var b: u8 = 0;
    var sel_a: u32 = 1;
    var sel_b: u32 = 2;
    _ = try stack.push(&a, &sel_a);
    try testing.expectError(error.OutOfMemory, stack.push(&b, &sel_b));
    try testing.expectEqual(@as(usize, 1), stack.len);
    try testing.expectEqual(@as(?*anyopaque, &sel_a), stack.top());
    // 已登记 owner 的更新在满栈时也不分配、不失败。
    _ = try stack.push(&a, &sel_b);
    try testing.expectEqual(@as(?*anyopaque, &sel_b), stack.top());
}

test "超过容量：主窗口不被挤掉，其余窗口全关后钩子仍指向主窗口" {
    // 真实场景：OwnerStack 是进程级的，容量取自 MultiWindowApp.max_windows，
    // 但这个上限只管单个 MultiWindowApp；独立 App.init 不受限。于是
    // 「独立主窗口 + 开满的 MultiWindowApp」就是 capacity+1 个 owner。
    // 旧实现栈满丢最老条目（= 主窗口），之后把其余窗口关光，栈空 → 钩子被
    // 清成 null，而主窗口还活着，测量退回平台 measure（光标/选区错位）。
    var stack: OwnerStack(2) = .{ .allocator = testing.allocator };
    var main_app: u8 = 0;
    var main_sel: u32 = 100;
    var o: [2]u8 = .{ 0, 0 };
    var s: [2]u32 = .{ 1, 2 };
    _ = try stack.push(&main_app, &main_sel);
    for (0..2) |i| _ = try stack.push(&o[i], &s[i]);
    try testing.expectEqual(@as(?*anyopaque, &s[1]), stack.top());
    try testing.expectEqual(@as(?*anyopaque, &s[0]), stack.remove(&o[1]));
    try testing.expectEqual(@as(?*anyopaque, &main_sel), stack.remove(&o[0]));
    try testing.expectEqual(@as(?*anyopaque, null), stack.remove(&main_app));
}
