//! 共享选择模型 —— 供 DataTable / Table / VirtualList / Tree 复用。
//!
//! 此前全框架没有多选：DataTable / Table / VirtualList 连 selection 字段都
//! 没有，Tree 是单选。列表类组件的多选交互（Cmd/Ctrl 点选切换、Shift 点选
//! 连续区间、锚点语义）在各组件里各写一遍必然走样，所以抽成这一份纯逻辑
//! 模型：不碰节点、不碰 allocator 之外的任何框架状态，可独立单测。
//!
//! 索引语义由 caller 定义（DataTable 用「过滤后的行序号」，Tree 用
//! flat_index），模型本身只认 usize。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 选择模式。新组件 props 里以 `.none` 为默认值 —— 既有调用方行为不变
/// （props 结构体新增带默认值字段不算破坏性变更，见 docs/API_STABILITY.md）。
pub const SelectionMode = enum(u8) {
    /// 不可选（默认，与加入多选之前的行为一致）
    none,
    /// 单选：选中新行会取消旧行
    single,
    /// 多选：Cmd/Ctrl 切换、Shift 选区间
    multi,
};

/// 一次点击带的修饰键意图
pub const ClickIntent = struct {
    /// Cmd(macOS) / Ctrl —— 切换单行，保留其余选中
    toggle: bool = false,
    /// Shift —— 从锚点到本行的连续区间
    range: bool = false,
};

/// 位图选择集。容量在 init 时固定（= 数据行数），无逐行分配。
pub const SelectionModel = struct {
    mode: SelectionMode = .none,
    /// 每行一个 bit
    bits: []u64 = &.{},
    len: usize = 0,
    /// Shift 选区间的锚点（最近一次非 range 点击的行）
    anchor: ?usize = null,
    /// 最近一次点击的行（键盘导航的起点）
    lead: ?usize = null,
    selected_count: usize = 0,

    pub fn init(allocator: Allocator, mode: SelectionMode, len: usize) !SelectionModel {
        const words = (len + 63) / 64;
        const bits = try allocator.alloc(u64, words);
        @memset(bits, 0);
        return .{ .mode = mode, .bits = bits, .len = len };
    }

    pub fn deinit(self: *SelectionModel, allocator: Allocator) void {
        allocator.free(self.bits);
        self.bits = &.{};
        self.len = 0;
    }

    /// 行数变化（筛选/翻页/数据替换）时重建容量并清空选择。
    pub fn resize(self: *SelectionModel, allocator: Allocator, new_len: usize) !void {
        const words = (new_len + 63) / 64;
        if (words != self.bits.len) {
            const bits = try allocator.realloc(self.bits, words);
            self.bits = bits;
        }
        @memset(self.bits, 0);
        self.len = new_len;
        self.selected_count = 0;
        self.anchor = null;
        self.lead = null;
    }

    pub fn isSelected(self: *const SelectionModel, index: usize) bool {
        if (index >= self.len) return false;
        return (self.bits[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
    }

    fn setBit(self: *SelectionModel, index: usize, on: bool) void {
        if (index >= self.len) return;
        const w = index / 64;
        const mask = @as(u64, 1) << @intCast(index % 64);
        const was = (self.bits[w] & mask) != 0;
        if (on == was) return;
        if (on) {
            self.bits[w] |= mask;
            self.selected_count += 1;
        } else {
            self.bits[w] &= ~mask;
            self.selected_count -= 1;
        }
    }

    pub fn clear(self: *SelectionModel) void {
        @memset(self.bits, 0);
        self.selected_count = 0;
    }

    /// 程序化选中单行（等价于无修饰键点击）
    pub fn select(self: *SelectionModel, index: usize) void {
        self.applyClick(index, .{});
    }

    /// 核心交互：把一次（带修饰键的）点击应用到选择集。
    ///
    /// 语义对齐 Finder / NSTableView：
    ///   - single 模式：任何修饰键都忽略，永远只选中被点的那行
    ///   - multi + toggle：切换该行，其余不动；锚点移到该行
    ///   - multi + range：清空后选中 [anchor, index] 闭区间；锚点**不动**
    ///     （所以连续 Shift 点击是以同一锚点重新划区间，而不是逐次累加）
    ///   - multi 无修饰：清空后只选该行；锚点移到该行
    pub fn applyClick(self: *SelectionModel, index: usize, intent: ClickIntent) void {
        if (self.mode == .none or index >= self.len) return;
        self.lead = index;

        if (self.mode == .single) {
            self.clear();
            self.setBit(index, true);
            self.anchor = index;
            return;
        }

        if (intent.range) {
            const a = self.anchor orelse index;
            const lo = @min(a, index);
            const hi = @max(a, index);
            self.clear();
            var i = lo;
            while (i <= hi) : (i += 1) self.setBit(i, true);
            // 锚点保持不变：Shift 连点是重划区间，不是累加
            if (self.anchor == null) self.anchor = index;
            return;
        }

        if (intent.toggle) {
            self.setBit(index, !self.isSelected(index));
            self.anchor = index;
            return;
        }

        self.clear();
        self.setBit(index, true);
        self.anchor = index;
    }

    /// 全选（仅 multi 有效）
    pub fn selectAll(self: *SelectionModel) void {
        if (self.mode != .multi) return;
        var i: usize = 0;
        while (i < self.len) : (i += 1) self.setBit(i, true);
    }

    /// 把选中的行下标写进 out，返回写入个数（out 不够则截断）。
    pub fn collect(self: *const SelectionModel, out: []usize) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.len and n < out.len) : (i += 1) {
            if (self.isSelected(i)) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// 首个选中行（无选中返回 null）
    pub fn first(self: *const SelectionModel) ?usize {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.isSelected(i)) return i;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "SelectionModel: none 模式忽略一切点击" {
    var m = try SelectionModel.init(testing.allocator, .none, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(3, .{});
    m.applyClick(4, .{ .toggle = true });
    try testing.expectEqual(@as(usize, 0), m.selected_count);
}

test "SelectionModel: single 模式选中新行取消旧行（修饰键无效）" {
    var m = try SelectionModel.init(testing.allocator, .single, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(3, .{});
    try testing.expect(m.isSelected(3));
    try testing.expectEqual(@as(usize, 1), m.selected_count);

    // 即使带 toggle，single 也只保留一行
    m.applyClick(7, .{ .toggle = true });
    try testing.expect(!m.isSelected(3));
    try testing.expect(m.isSelected(7));
    try testing.expectEqual(@as(usize, 1), m.selected_count);
}

test "SelectionModel: multi + Cmd 切换，其余保留" {
    var m = try SelectionModel.init(testing.allocator, .multi, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(1, .{});
    m.applyClick(3, .{ .toggle = true });
    m.applyClick(5, .{ .toggle = true });
    try testing.expectEqual(@as(usize, 3), m.selected_count);
    try testing.expect(m.isSelected(1) and m.isSelected(3) and m.isSelected(5));

    // 再点一次 3 → 取消，其余不动
    m.applyClick(3, .{ .toggle = true });
    try testing.expect(!m.isSelected(3));
    try testing.expect(m.isSelected(1) and m.isSelected(5));
    try testing.expectEqual(@as(usize, 2), m.selected_count);
}

test "SelectionModel: multi + Shift 选连续区间（含反向）" {
    var m = try SelectionModel.init(testing.allocator, .multi, 20);
    defer m.deinit(testing.allocator);
    m.applyClick(5, .{}); // 锚点 = 5
    m.applyClick(9, .{ .range = true });
    try testing.expectEqual(@as(usize, 5), m.selected_count); // 5..9
    for (5..10) |i| try testing.expect(m.isSelected(i));

    // 反向 Shift：锚点仍是 5，区间重划为 2..5
    m.applyClick(2, .{ .range = true });
    try testing.expectEqual(@as(usize, 4), m.selected_count);
    for (2..6) |i| try testing.expect(m.isSelected(i));
    try testing.expect(!m.isSelected(9)); // 上一次的区间被清掉，不是累加
}

test "SelectionModel: 无修饰点击清空其余" {
    var m = try SelectionModel.init(testing.allocator, .multi, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(1, .{});
    m.applyClick(2, .{ .toggle = true });
    m.applyClick(8, .{}); // 无修饰 → 只剩 8
    try testing.expectEqual(@as(usize, 1), m.selected_count);
    try testing.expect(m.isSelected(8));
}

test "SelectionModel: selectAll / collect / first" {
    var m = try SelectionModel.init(testing.allocator, .multi, 5);
    defer m.deinit(testing.allocator);
    m.selectAll();
    try testing.expectEqual(@as(usize, 5), m.selected_count);
    try testing.expectEqual(@as(?usize, 0), m.first());

    m.clear();
    m.applyClick(1, .{});
    m.applyClick(4, .{ .toggle = true });
    var buf: [8]usize = undefined;
    const n = m.collect(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(usize, &.{ 1, 4 }, buf[0..n]);
    try testing.expectEqual(@as(?usize, 1), m.first());

    // single 模式下 selectAll 无效
    var s = try SelectionModel.init(testing.allocator, .single, 5);
    defer s.deinit(testing.allocator);
    s.selectAll();
    try testing.expectEqual(@as(usize, 0), s.selected_count);
}

test "SelectionModel: 跨 64 行边界的区间选择" {
    var m = try SelectionModel.init(testing.allocator, .multi, 200);
    defer m.deinit(testing.allocator);
    m.applyClick(60, .{});
    m.applyClick(130, .{ .range = true });
    try testing.expectEqual(@as(usize, 71), m.selected_count);
    try testing.expect(m.isSelected(60) and m.isSelected(64) and m.isSelected(130));
    try testing.expect(!m.isSelected(59) and !m.isSelected(131));
}

test "SelectionModel: resize 重建容量并清空" {
    var m = try SelectionModel.init(testing.allocator, .multi, 10);
    defer m.deinit(testing.allocator);
    m.applyClick(3, .{});
    try testing.expectEqual(@as(usize, 1), m.selected_count);

    try m.resize(testing.allocator, 300);
    try testing.expectEqual(@as(usize, 0), m.selected_count);
    try testing.expectEqual(@as(usize, 300), m.len);
    try testing.expect(m.anchor == null);
    m.applyClick(250, .{});
    try testing.expect(m.isSelected(250));

    try m.resize(testing.allocator, 5);
    try testing.expectEqual(@as(usize, 5), m.len);
    try testing.expectEqual(@as(usize, 0), m.selected_count);
}

test "SelectionModel: 越界索引安全" {
    var m = try SelectionModel.init(testing.allocator, .multi, 4);
    defer m.deinit(testing.allocator);
    m.applyClick(99, .{});
    try testing.expectEqual(@as(usize, 0), m.selected_count);
    try testing.expect(!m.isSelected(99));
}
