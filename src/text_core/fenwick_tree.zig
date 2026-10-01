/// FenwickTree, Binary Indexed Tree (BIT) 前缀和加速
///
/// 用于 WrapMap 的 display line 前缀和查询：
/// - update(idx, delta): O(logN) 增量更新
/// - prefixSum(idx): O(logN) 前缀和查询
/// - find(target): O(logN) walk-down 查找
/// - buildFrom(values): O(N) 初始化
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 计算 BIT 中的 lowbit: i & (-i)
/// 对 usize 安全地执行此操作
inline fn lowbit(x: usize) usize {
    // x & (~x + 1) 等价于 x & (-x)，且对无符号安全
    return x & (~x +% 1);
}

pub const FenwickTree = struct {
    /// 1-indexed BIT 数组
    tree: []i64,
    /// 原始值数组（用于 set 时计算 delta）
    values: []u32,
    n: usize,
    allocator: Allocator,

    /// 创建大小为 size 的全零树
    pub fn init(allocator: Allocator, size: usize) !FenwickTree {
        const tree = try allocator.alloc(i64, try std.math.add(usize, size, 1));
        errdefer allocator.free(tree);
        @memset(tree, 0);
        const values = try allocator.alloc(u32, size);
        @memset(values, 0);
        return .{
            .tree = tree,
            .values = values,
            .n = size,
            .allocator = allocator,
        };
    }

    /// 从 u32 切片 O(N) 构建
    pub fn buildFrom(allocator: Allocator, vals: []const u32) !FenwickTree {
        const n = vals.len;
        const tree = try allocator.alloc(i64, try std.math.add(usize, n, 1));
        errdefer allocator.free(tree);
        @memset(tree, 0);
        const values = try allocator.alloc(u32, n);
        @memcpy(values, vals);

        // O(N) 构建：每个位置向"父"传递贡献
        for (1..n + 1) |i| {
            tree[i] += @as(i64, @intCast(vals[i - 1]));
            const parent = i + lowbit(i);
            if (parent <= n) {
                tree[parent] += tree[i];
            }
        }

        return .{
            .tree = tree,
            .values = values,
            .n = n,
            .allocator = allocator,
        };
    }

    /// 0-indexed 增量更新 O(logN)
    pub fn update(self: *FenwickTree, idx: usize, delta: i32) void {
        if (idx >= self.n) return;
        const next = @as(i64, self.values[idx]) + @as(i64, delta);
        if (next < 0 or next > std.math.maxInt(u32)) return;
        self.values[idx] = @intCast(next);
        self.applyDelta(idx, delta);
    }

    fn applyDelta(self: *FenwickTree, idx: usize, delta: i64) void {
        // BIT 更新 (1-indexed)
        var pos = idx + 1;
        while (pos <= self.n) {
            self.tree[pos] += delta;
            pos += lowbit(pos);
        }
    }

    /// 0-indexed 设置值
    pub fn set(self: *FenwickTree, idx: usize, new_val: u32) void {
        if (idx >= self.n) return;
        const old = self.values[idx];
        const delta = @as(i64, new_val) - @as(i64, old);
        if (delta == 0) return;
        self.values[idx] = new_val;
        self.applyDelta(idx, delta);
    }

    /// 0-indexed 前缀和 [0..idx]，O(logN)
    pub fn prefixSum(self: *const FenwickTree, idx: usize) u32 {
        if (self.n == 0) return 0;
        var sum: i64 = 0;
        var pos = @min(idx, self.n - 1) + 1; // 转 1-indexed
        while (pos > 0) {
            sum += self.tree[pos];
            pos -= lowbit(pos);
        }
        return @intCast(std.math.clamp(sum, 0, std.math.maxInt(u32)));
    }

    /// 总和
    pub fn total(self: *const FenwickTree) u32 {
        if (self.n == 0) return 0;
        return self.prefixSum(self.n - 1);
    }

    /// Walk-down 查找: 找到最小的 idx 使得 prefixSum(idx) >= target
    /// 用于 WrapMap.displayLineInfo: 给定 display_line -> 找到对应的 buffer_line
    /// target 是 1-based (等价于 prefix_sums 数组中的 display_line + 1)
    pub fn find(self: *const FenwickTree, target: u32) usize {
        if (self.n == 0 or target == 0) return 0;

        // Walk-down: 从最高有效位开始逐位构建位置
        var pos: usize = 0;
        var remaining: i64 = @intCast(target);

        // 找到 >= n 的最小的 2 的幂
        var bit_mask: usize = 1;
        while (bit_mask <= self.n) bit_mask <<= 1;
        bit_mask >>= 1;

        while (bit_mask > 0) : (bit_mask >>= 1) {
            const next = pos + bit_mask;
            if (next <= self.n and self.tree[next] < remaining) {
                pos = next;
                remaining -= self.tree[next];
            }
        }

        // pos 是最后一个 prefix < target 的 1-indexed 位置
        // pos+1 是第一个 prefix >= target 的 1-indexed 位置
        // 转回 0-indexed: pos (因为 1-indexed pos+1 -> 0-indexed pos)
        return @min(pos, self.n -| 1);
    }

    /// 改变大小并用新值 O(N) 重建
    ///
    /// 先分配新数组、都成功后才释放旧数组：反过来（先 free 后 alloc）在
    /// alloc 失败时 self.tree/values 悬垂且 n 陈旧，后续任何读写都是 UAF，
    /// deinit 再 free 一次就是 double free。
    pub fn resize(self: *FenwickTree, new_size: usize, new_values: []const u32) !void {
        const tree = try self.allocator.alloc(i64, try std.math.add(usize, new_size, 1));
        errdefer self.allocator.free(tree);
        @memset(tree, 0);
        const values = try self.allocator.alloc(u32, new_size);

        self.allocator.free(self.tree);
        self.allocator.free(self.values);

        const copy_len = @min(new_size, new_values.len);
        if (copy_len > 0) @memcpy(values[0..copy_len], new_values[0..copy_len]);
        if (copy_len < new_size) @memset(values[copy_len..], 0);

        self.tree = tree;
        self.values = values;
        self.n = new_size;

        // O(N) 构建
        for (1..new_size + 1) |i| {
            self.tree[i] += @as(i64, @intCast(values[i - 1]));
            const parent = i + lowbit(i);
            if (parent <= new_size) {
                self.tree[parent] += self.tree[i];
            }
        }
    }

    pub fn deinit(self: *FenwickTree) void {
        self.allocator.free(self.tree);
        self.allocator.free(self.values);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "basic init" {
    const alloc = std.testing.allocator;
    var ft = try FenwickTree.init(alloc, 5);
    defer ft.deinit();
    try std.testing.expectEqual(@as(u32, 0), ft.prefixSum(0));
    try std.testing.expectEqual(@as(u32, 0), ft.total());
}

test "buildFrom and prefixSum" {
    const alloc = std.testing.allocator;
    const vals = [_]u32{ 1, 2, 3, 4, 5 };
    var ft = try FenwickTree.buildFrom(alloc, &vals);
    defer ft.deinit();

    try std.testing.expectEqual(@as(u32, 1), ft.prefixSum(0));
    try std.testing.expectEqual(@as(u32, 3), ft.prefixSum(1));
    try std.testing.expectEqual(@as(u32, 6), ft.prefixSum(2));
    try std.testing.expectEqual(@as(u32, 10), ft.prefixSum(3));
    try std.testing.expectEqual(@as(u32, 15), ft.prefixSum(4));
    try std.testing.expectEqual(@as(u32, 15), ft.total());
}

test "update" {
    const alloc = std.testing.allocator;
    const vals = [_]u32{ 1, 2, 3 };
    var ft = try FenwickTree.buildFrom(alloc, &vals);
    defer ft.deinit();

    ft.update(1, 5);
    try std.testing.expectEqual(@as(u32, 1), ft.prefixSum(0));
    try std.testing.expectEqual(@as(u32, 8), ft.prefixSum(1));
    try std.testing.expectEqual(@as(u32, 11), ft.prefixSum(2));
}

test "set" {
    const alloc = std.testing.allocator;
    const vals = [_]u32{ 1, 2, 3 };
    var ft = try FenwickTree.buildFrom(alloc, &vals);
    defer ft.deinit();

    ft.set(1, 10);
    try std.testing.expectEqual(@as(u32, 1), ft.prefixSum(0));
    try std.testing.expectEqual(@as(u32, 11), ft.prefixSum(1));
    try std.testing.expectEqual(@as(u32, 14), ft.prefixSum(2));
}

test "public operations safely handle invalid indices and full u32 values" {
    const alloc = std.testing.allocator;
    const vals = [_]u32{1};
    var ft = try FenwickTree.buildFrom(alloc, &vals);
    defer ft.deinit();

    ft.update(99, 1);
    ft.set(99, 2);
    try std.testing.expectEqual(@as(u32, 1), ft.prefixSum(99));

    ft.set(0, std.math.maxInt(u32));
    try std.testing.expectEqual(std.math.maxInt(u32), ft.total());
    ft.update(0, 1); // rejected instead of wrapping
    try std.testing.expectEqual(std.math.maxInt(u32), ft.total());
}

test "find walk-down" {
    const alloc = std.testing.allocator;
    // display_counts: [1, 1, 3, 1, 2] -> prefix: [1, 2, 5, 6, 8]
    const vals = [_]u32{ 1, 1, 3, 1, 2 };
    var ft = try FenwickTree.buildFrom(alloc, &vals);
    defer ft.deinit();

    // find(target) returns the buf_line (0-indexed) where display_line falls
    // display_line=0 -> target=1 -> buf_line=0 (prefix[0]=1 >= 1)
    try std.testing.expectEqual(@as(usize, 0), ft.find(1));
    // display_line=1 -> target=2 -> buf_line=1 (prefix[1]=2 >= 2)
    try std.testing.expectEqual(@as(usize, 1), ft.find(2));
    // display_line=2 -> target=3 -> buf_line=2 (prefix[2]=5 >= 3)
    try std.testing.expectEqual(@as(usize, 2), ft.find(3));
    // display_line=4 -> target=5 -> buf_line=2 (prefix[2]=5 >= 5)
    try std.testing.expectEqual(@as(usize, 2), ft.find(5));
    // display_line=5 -> target=6 -> buf_line=3 (prefix[3]=6 >= 6)
    try std.testing.expectEqual(@as(usize, 3), ft.find(6));
    // display_line=7 -> target=8 -> buf_line=4 (prefix[4]=8 >= 8)
    try std.testing.expectEqual(@as(usize, 4), ft.find(8));
}

test "resize" {
    const alloc = std.testing.allocator;
    const vals = [_]u32{ 1, 2, 3 };
    var ft = try FenwickTree.buildFrom(alloc, &vals);
    defer ft.deinit();

    try std.testing.expectEqual(@as(u32, 6), ft.total());

    const new_vals = [_]u32{ 1, 2, 3, 4, 5 };
    try ft.resize(5, &new_vals);

    try std.testing.expectEqual(@as(u32, 15), ft.total());
    try std.testing.expectEqual(@as(u32, 6), ft.prefixSum(2));
}

test "Fenwick constructors release first allocation when the second fails" {
    const t = std.testing;
    for ([_]bool{ false, true }) |from_values| {
        for (0..2) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
            const result = if (from_values) FenwickTree.buildFrom(failing.allocator(), &.{ 2, 3, 4 }) else FenwickTree.init(failing.allocator(), 3);
            try t.expectError(error.OutOfMemory, result);
        }
    }
    try t.expectError(error.Overflow, FenwickTree.init(t.allocator, std.math.maxInt(usize)));
    var tree = try FenwickTree.buildFrom(t.allocator, &.{ 2, 3 });
    defer tree.deinit();
    try t.expectError(error.Overflow, tree.resize(std.math.maxInt(usize), &.{}));
    try t.expectEqual(@as(u32, 5), tree.total());
}
