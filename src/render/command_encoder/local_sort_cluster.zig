//! command_encoder/local_sort_cluster.zig, local-sort 的**簇状态机**
//!
//! 从 command_encoder.zig 析出（2026-08-05），与 clip_geometry.zig 同批。
//! 前一批（local_sort.zig，2026-07-31）搬走的是纯函数：单条命令属于哪个
//! pipeline、它的 bounds 是什么。这一批搬的是**有状态的另一半**：
//! 在结构边界之间累积「可换序命令」的定长簇。
//!
//! 内聚性判据（本次析出的全部理由）：
//!   - 字段只有 `refs` + `len`，四个方法（clear / isEmpty / tryAppend /
//!     buildDispatchOrder）只碰这两个字段，互相之间零 encoder 依赖；
//!   - 它此前是 `RenderCommandEncoder` 的**嵌套** struct（还带着
//!     `local_sort_cluster_capacity` 这个容器大小常量），簇逻辑因而是
//!     「encoder 结构体里的一个独立小机器」，最典型的 god-module 寄生体；
//!   - encoder 侧只剩 3 个触点：`var cluster = ...Cluster{}`、
//!     `cluster.tryAppend(...)`、`self.flushLocalSortCluster(commands, &cluster)`
//!     （flush 留在 encoder：它要调 dispatchCommand，那是编码主循环的职责）。
//!
//! 析出前它**测不了**：嵌套类型没有独立入口，只能借 encodeCommands 的
//! 整条通路间接观测；现在容量耗尽、fence 拒绝、overlap 拒绝、
//! pipeline 稳定排序这些都能直接断言（见本文件尾部单测）。
//!
//! ⚠ 合同继承自 local_sort.zig：`buildDispatchOrder` 输出的顺序必须是
//! 「按 pipeline 分桶、桶内保持插入序」。local-sort 重排只在**bounds 不
//! 重叠**的前提下进行，桶内序不变 ⇒ 与原始顺序视觉等价。改成分桶内
//! 任意重排都守不住这个不变式。
//!
//! 这里不搬什么：判定「哪条命令可入簇」的几何（bounds/pipeline）在
//! local_sort.zig；把簇里的命令真正发射出去（flush -> dispatchCommand）
//! 在 encoder。本模块只管「攒」。

const std = @import("std");
const lsort = @import("local_sort.zig");

/// 簇容量。与 encoder 内联时的历史值一致（128 条 paint 命令）；
/// 超出即拒绝入簇并触发一次 flush，行为不变。
pub const capacity: usize = 128;

pub const RejectReason = enum {
    none,
    overlap,
    capacity,
    unsortable,
};

const SortableRef = struct {
    index: usize,
    pipeline: lsort.PipelineKind,
    bounds: [4]f32,
};

pub const LocalSortCluster = struct {
    refs: [capacity]SortableRef = undefined,
    len: usize = 0,

    pub fn clear(self: *LocalSortCluster) void {
        self.len = 0;
    }

    pub fn isEmpty(self: *const LocalSortCluster) bool {
        return self.len == 0;
    }

    /// 尝试把 `commands[index]` 并入簇。
    ///
    /// 返回 `.unsortable` 的两种情况（fence 命令 / 算不出 bounds）由调用方
    /// 直接 dispatch；`.overlap` / `.capacity` 由调用方 flush 后重试一次。
    pub fn tryAppend(self: *LocalSortCluster, commands: anytype, index: usize) RejectReason {
        const pipeline = lsort.localSortPipelineKind(commands[index]);
        if (pipeline == .fence) return .unsortable;
        const bounds = lsort.localSortBoundsForCommand(commands[index]) orelse return .unsortable;
        if (self.len >= self.refs.len) return .capacity;

        for (self.refs[0..self.len]) |ref| {
            if (ref.pipeline == pipeline) continue;
            if (lsort.rectsOverlap(ref.bounds, bounds)) return .overlap;
        }

        self.refs[self.len] = .{
            .index = index,
            .pipeline = pipeline,
            .bounds = bounds,
        };
        self.len += 1;
        return .none;
    }

    /// 按 pipeline 分桶输出 dispatch 顺序（sdf -> image -> icon -> text），
    /// 桶内保持插入序，见模块头的顺序合同。
    pub fn buildDispatchOrder(self: *const LocalSortCluster, out: *[capacity]usize) []const usize {
        var out_len: usize = 0;
        const order = [_]lsort.PipelineKind{ .sdf, .image, .icon, .text };
        for (order) |pipeline| {
            for (self.refs[0..self.len]) |ref| {
                if (ref.pipeline != pipeline) continue;
                out[out_len] = ref.index;
                out_len += 1;
            }
        }
        return out[0..out_len];
    }
};

// ── 测试 ───────────────────────────────────────────────────────────────
// 此前这套逻辑是 encoder 的嵌套 struct，只能借 encodeCommands 间接观测；
// 下面用 duck-typed mock 命令直接驱动（与 command_encoder_test.zig 的
// MockItem 同款手法，render 模块不 import ui 侧的 paint_table）。

const MockItem = struct {
    // ⚠ 枚举成员必须与 local_sort.zig 的 switch 标签一致（那边按 anytype
    // 鸭子类型直接 switch it.kind）。但它是本模块私有的测试夹具：
    // command_encoder_test.zig 各自维护自己的 MockItem，谁也不 import 谁，
    // 避免「既有模块依赖新模块的测试类型」这种反向耦合。
    kind: enum { none, rect, text, image, shadow, gradient, path, control } = .rect,
    geom: struct { x: f32 = 0, y: f32 = 0, w: f32 = 10, h: f32 = 10 } = .{},
    rotate: f32 = 0,
    arc_outer_radius: f32 = 0,
    icon_rep_ptr: ?*const u8 = null,
    text_content: []const u8 = "x",
    text_font_size: f32 = 12,
    shadow_blur: f32 = 0,
    shadow_offset_x: f32 = 0,
    shadow_offset_y: f32 = 0,
    shadow_spread: f32 = 0,
    shadow2_color: struct { a: f32 = 0 } = .{},
    shadow2_blur: f32 = 0,
    shadow2_offset_x: f32 = 0,
    shadow2_offset_y: f32 = 0,
};

const rects = [_]MockItem{
    .{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 10, .h = 10 } },
    .{ .kind = .image, .geom = .{ .x = 100, .y = 0, .w = 10, .h = 10 } },
    .{ .kind = .text, .geom = .{ .x = 200, .y = 0, .w = 0, .h = 0 } },
};

test "tryAppend: 同 pipeline 相互重叠也照收（bounds 只跨 pipeline 检查）" {
    var cluster = LocalSortCluster{};
    const overlapping = [_]MockItem{
        .{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 50, .h = 50 } },
        .{ .kind = .rect, .geom = .{ .x = 1, .y = 1, .w = 50, .h = 50 } },
    };
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&overlapping, 0));
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&overlapping, 1));
    try std.testing.expectEqual(@as(usize, 2), cluster.len);
}

test "tryAppend: 跨 pipeline 且 bounds 重叠 ⇒ .overlap，不改动簇" {
    var cluster = LocalSortCluster{};
    // rects[0]：rect -> sdf，bounds 在 (0,0)。
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
    const overlapping_image = [_]MockItem{
        .{ .kind = .image, .geom = .{ .x = 5, .y = 5, .w = 10, .h = 10 } },
    };
    try std.testing.expectEqual(RejectReason.overlap, cluster.tryAppend(&overlapping_image, 0));
    // 拒绝必须是「无副作用」的：簇里仍只有第一条。
    try std.testing.expectEqual(@as(usize, 1), cluster.len);
}

test "tryAppend: 跨 pipeline bounds 不重叠 ⇒ 入簇" {
    var cluster = LocalSortCluster{};
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 1));
    try std.testing.expectEqual(@as(usize, 2), cluster.len);
}

test "tryAppend: control（fence）恒 .unsortable，即便簇为空" {
    var cluster = LocalSortCluster{};
    const ctl = [_]MockItem{.{ .kind = .control }};
    try std.testing.expectEqual(RejectReason.unsortable, cluster.tryAppend(&ctl, 0));
    try std.testing.expectEqual(@as(usize, 0), cluster.len);
}

test "buildDispatchOrder: 按 pipeline 分桶、桶内保插入序" {
    var cluster = LocalSortCluster{};
    // 插入序：image, sdf, text, sdf，交错。注意各 bounds 互不重叠
    //（跨 pipeline 重叠会被 tryAppend 拒绝，混不进同一个簇）。
    const seq = [_]MockItem{
        .{ .kind = .image, .geom = .{ .x = 0, .y = 0, .w = 5, .h = 5 } },
        .{ .kind = .rect, .geom = .{ .x = 0, .y = 10, .w = 5, .h = 5 } },
        .{ .kind = .text, .geom = .{ .x = 200, .y = 0, .w = 0, .h = 0 } },
        .{ .kind = .rect, .geom = .{ .x = 100, .y = 0, .w = 5, .h = 5 } },
    };
    for (0..seq.len) |i| {
        try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&seq, i));
    }
    var buf: [capacity]usize = undefined;
    const order = cluster.buildDispatchOrder(&buf);
    // sdf(1), sdf(3), image(0), text(2)
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 3, 0, 2 }, order);
}

test "clear 后可复用且 isEmpty 为真" {
    var cluster = LocalSortCluster{};
    try std.testing.expect(cluster.isEmpty());
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
    try std.testing.expect(!cluster.isEmpty());
    cluster.clear();
    try std.testing.expect(cluster.isEmpty());
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
}

test "容量耗尽返回 .capacity 而非静默丢命令" {
    // 回归锚：refs 是定长数组，若满了继续写会越界写 undefined 内存。
    var cluster = LocalSortCluster{};
    var cmds: [capacity + 1]MockItem = undefined;
    for (&cmds) |*c| c.* = .{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 1, .h = 1 } };
    for (0..capacity) |i| {
        try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&cmds, i));
    }
    try std.testing.expectEqual(RejectReason.capacity, cluster.tryAppend(&cmds, capacity));
    try std.testing.expectEqual(@as(usize, capacity), cluster.len);
}
