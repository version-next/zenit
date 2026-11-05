/// FenwickTree, Binary Indexed Tree (BIT) prefix sum acceleration
///
/// Used for WrapMap display line prefix-sum query:
/// - update(idx, delta): O(logN) incremental update
/// - prefixSum(idx): O(logN) prefix-sum query
/// - find(target): O(logN) walk-down search
/// - buildFrom(values): O(N) initialize
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Calculate BIT lowbit: i & (-i)
/// Safe on usize
inline fn lowbit(x: usize) usize {
    // x & (~x + 1) equivalent to x & (-x), safe on unsigned
    return x & (~x +% 1);
}

pub const FenwickTree = struct {
    /// 1-indexed BIT array
    tree: []i64,
    /// Original values array (used to compute delta on set)
    values: []u32,
    n: usize,
    allocator: Allocator,

    /// Create zero-filled tree of size
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

    /// Build O(N) from u32 slice
    pub fn buildFrom(allocator: Allocator, vals: []const u32) !FenwickTree {
        const n = vals.len;
        const tree = try allocator.alloc(i64, try std.math.add(usize, n, 1));
        errdefer allocator.free(tree);
        @memset(tree, 0);
        const values = try allocator.alloc(u32, n);
        @memcpy(values, vals);

        // O(N) build: each position propagates contribution to 'parent'
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

    /// 0-indexed incremental update O(logN)
    pub fn update(self: *FenwickTree, idx: usize, delta: i32) void {
        if (idx >= self.n) return;
        const next = @as(i64, self.values[idx]) + @as(i64, delta);
        if (next < 0 or next > std.math.maxInt(u32)) return;
        self.values[idx] = @intCast(next);
        self.applyDelta(idx, delta);
    }

    fn applyDelta(self: *FenwickTree, idx: usize, delta: i64) void {
        // BIT update (1-indexed)
        var pos = idx + 1;
        while (pos <= self.n) {
            self.tree[pos] += delta;
            pos += lowbit(pos);
        }
    }

    /// 0-indexed set value
    pub fn set(self: *FenwickTree, idx: usize, new_val: u32) void {
        if (idx >= self.n) return;
        const old = self.values[idx];
        const delta = @as(i64, new_val) - @as(i64, old);
        if (delta == 0) return;
        self.values[idx] = new_val;
        self.applyDelta(idx, delta);
    }

    /// 0-indexed prefix-sum [0..idx], O(logN)
    pub fn prefixSum(self: *const FenwickTree, idx: usize) u32 {
        if (self.n == 0) return 0;
        var sum: i64 = 0;
        var pos = @min(idx, self.n - 1) + 1; // Convert to 1-indexed
        while (pos > 0) {
            sum += self.tree[pos];
            pos -= lowbit(pos);
        }
        // Keep the u32 saturation boundaries explicit before narrowing. The
        // optimized aggregate module must preserve the full 0xffffffff value.
        if (sum <= 0) return 0;
        if (sum >= std.math.maxInt(u32)) return std.math.maxInt(u32);
        return @intCast(sum);
    }

    /// Total sum
    pub fn total(self: *const FenwickTree) u32 {
        if (self.n == 0) return 0;
        return self.prefixSum(self.n - 1);
    }

    /// Walk-down find: smallest idx where prefixSum(idx) >= target
    /// Used for WrapMap.displayLineInfo: given display_line -> find corresponding buffer_line
    /// target is 1-based (equivalent to prefix_sums array display_line + 1)
    pub fn find(self: *const FenwickTree, target: u32) usize {
        if (self.n == 0 or target == 0) return 0;

        // Walk-down: build position bitwise from MSB
        var pos: usize = 0;
        var remaining: i64 = @intCast(target);

        // Find smallest power of 2 >= n
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

        // pos is last 1-indexed position where prefix < target;
        // pos+1 is first 1-indexed position where prefix >= target;
        // convert to 0-indexed: pos (because 1-indexed pos+1 -> 0-indexed pos)
        return @min(pos, self.n -| 1);
    }

    /// Resize and O(N) rebuild with new values
    ///
    /// Allocate new array first, only free old after both succeed: reverse order
    /// (free then alloc) on alloc failure leaves self.tree/values dangling and n stale,
    /// subsequent read/write is UAF; deinit then free again is double-free.
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

        // O(N) build
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

    const maximum: u32 = std.math.maxInt(u32);
    ft.set(0, maximum);
    try std.testing.expectEqual(maximum, ft.values[0]);
    try std.testing.expectEqual(@as(i64, maximum), ft.tree[1]);
    try std.testing.expectEqual(maximum, ft.total());
    ft.update(0, 1); // rejected instead of wrapping
    try std.testing.expectEqual(maximum, ft.values[0]);
    try std.testing.expectEqual(@as(i64, maximum), ft.tree[1]);
    try std.testing.expectEqual(maximum, ft.total());
    var saturated = try FenwickTree.buildFrom(alloc, &.{ maximum, maximum });
    defer saturated.deinit();
    try std.testing.expectEqual(maximum, saturated.total());
    try std.testing.expectEqual(maximum, saturated.prefixSum(std.math.maxInt(usize)));
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
