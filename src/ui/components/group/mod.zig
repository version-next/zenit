/// Group Component — 组合容器 HOC
///
/// 将多个子组件组合成一个视觉整体：
/// - gap = -1 让子项边框重叠（避免双边框）
/// - 首项：右侧圆角清零（TR=0, BR=0），保留左侧圆角
/// - 末项：左侧圆角清零（TL=0, BL=0），保留右侧圆角
/// - 中间项：四角全部清零
/// - 不加外框 border，不干扰子项其他样式
///
/// 参考: React Group (CMC UI Kit) attached 模式
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Sizing = core.Sizing;
const Scope = core.Scope;
const Padding = core.Padding;
const BorderSideColors = @import("../../core/types.zig").BorderSideColors;

/// Group 方向
pub const GroupOrientation = enum {
    horizontal,
    vertical,
};

/// 子项在 Group 中的位置
pub const GroupItemPosition = enum {
    first,
    between,
    last,
    only,
};

/// Group 属性
pub const GroupProps = struct {
    /// 方向
    orientation: GroupOrientation = .horizontal,
    /// 宽度
    width: Sizing = .{ .fit = .{} },
    /// 对齐方式
    align_items: core.AlignItems = .stretch,
};

/// Group mount 返回值
pub const GroupResult = struct {
    container: *Node,
};

pub fn Group(props: GroupProps) GroupBuilder {
    return GroupBuilder{ .props = props };
}

pub const GroupBuilder = struct {
    props: GroupProps,

    pub fn mount(self: GroupBuilder, _: *Scope, cx: *Cx) !GroupResult {
        const p = self.props;
        const dir: core.Direction = if (p.orientation == .horizontal) .row else .column;

        const container = try box(cx, .{
            .width = p.width,
            .height = .{ .fit = .{} },
            .direction = dir,
            .align_items = p.align_items,
            .gap = 0,
        }, .{});
        container.meta.ownership.meta.component_name = "Group";

        return .{ .container = container };
    }
};

/// 将子节点添加到 Group 中，根据位置设置 per-corner radius
///
/// Horizontal 布局 (radii 顺序: TL, TR, BR, BL):
/// - first: 保留 TL/BL，清零 TR/BR
/// - last:  保留 TR/BR，清零 TL/BL
/// - between: 全部清零
/// - only: 保留全部
pub fn addGroupItem(
    container: *Node,
    allocator: Allocator,
    child: *Node,
    pos: GroupItemPosition,
    radius: f32,
) !void {
    const ext = try child.style.ensureExtFallible(allocator);
    const horizontal = container.style.direction == .row;
    const overlap = @max(@as(f32, 1), child.style.border.width);
    var side_colors = ext.border_side_colors orelse BorderSideColors{};

    ext.corner_radius = switch (pos) {
        .only => .{ .all = radius },
        .first => if (horizontal)
            .{ .each = .{ radius, 0, 0, radius } }
        else
            .{ .each = .{ radius, radius, 0, 0 } },
        .last => if (horizontal)
            .{ .each = .{ 0, radius, radius, 0 } }
        else
            .{ .each = .{ 0, 0, radius, radius } },
        .between => .{ .all = 0 },
    };

    // border.radius 清零（per-corner 由 ext.corner_radius 控制）
    child.style.border.radius = 0;
    child.setMargin(Padding.ZERO);
    switch (pos) {
        .first => {
            if (horizontal) {
                side_colors.right = Color.TRANSPARENT;
            } else {
                side_colors.bottom = Color.TRANSPARENT;
            }
        },
        .only => {},
        .between, .last => {
            if (horizontal) {
                child.setMarginLeft(-overlap);
                if (pos == .between) side_colors.right = Color.TRANSPARENT;
            } else {
                child.setMarginTop(-overlap);
                if (pos == .between) side_colors.bottom = Color.TRANSPARENT;
            }
        },
    }

    ext.border_side_colors = side_colors;
    ext.hit_shape = .auto;
    ext.clip_shape = .auto;

    try container.appendChild(allocator, child);
}

// ========== 测试 ==========

test "Group: structure" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    try std.testing.expectEqual(@as(f32, 0), result.container.style.gap);
    try std.testing.expectEqual(@as(f32, 0), result.container.style.border.width);
}

test "Group: addGroupItem per-corner radius" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c3 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .between, 8);
    try addGroupItem(result.container, alloc, c3, .last, 8);

    // first: TL=8, TR=0, BR=0, BL=8
    const r1 = c1.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 8), r1[0]);
    try std.testing.expectEqual(@as(f32, 0), r1[1]);
    try std.testing.expectEqual(@as(f32, 0), r1[2]);
    try std.testing.expectEqual(@as(f32, 8), r1[3]);

    // between: all 0
    const r2 = c2.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 0), r2[0]);

    // last: TL=0, TR=8, BR=8, BL=0
    const r3 = c3.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 0), r3[0]);
    try std.testing.expectEqual(@as(f32, 8), r3[1]);
    try std.testing.expectEqual(@as(f32, 8), r3[2]);
    try std.testing.expectEqual(@as(f32, 0), r3[3]);

    // border width/color 不被修改
    try std.testing.expectEqual(@as(f32, 1), c1.style.border.width);
    try std.testing.expectEqual(Color.hex(0xE5E5E5), c2.style.border.color);
    try std.testing.expectEqual(@as(f32, -1), c2.style.margin.left);
    try std.testing.expectEqual(@as(f32, -1), c3.style.margin.left);
}

test "Group: overlap follows child border width" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 240 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .radius = 8, .width = 2, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .radius = 8, .width = 2, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .last, 8);

    try std.testing.expectEqual(@as(f32, -2), c2.style.margin.left);
}

test "Group: attached seam keeps leading border on later items" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 240 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .last, 8);

    try std.testing.expect(c1.style.border_side_colors() != null);
    try std.testing.expect(c2.style.border_side_colors() != null);
    try std.testing.expect(Color.eql(c1.style.border_side_colors().?.right.?, Color.TRANSPARENT));
    try std.testing.expect(c2.style.border_side_colors().?.left == null);
    try std.testing.expect(c2.style.border_side_colors().?.top == null);
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "group: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("group", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Group(.{}).mount(scope, cx)).container;
        }
    }.m);
}
