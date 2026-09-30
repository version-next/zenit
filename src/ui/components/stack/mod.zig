/// Stack Components
///
/// 堆叠布局组件: VStack (垂直), HStack (水平)
///
/// 特性:
/// - 方向: vertical / horizontal
/// - 间距: gap
/// - 对齐: align, justify
/// - 反向: reverse
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Direction = core.Direction;
const Alignment = core.Alignment;
const Justify = core.Justify;
const Sizing = core.Sizing;
const Scope = @import("../../reactive.zig").Scope;

/// VStack 属性
pub const VStackProps = struct {
    /// 间距
    gap: f32 = 0,
    /// 主轴对齐
    justify: Justify = .start,
    /// 交叉轴对齐
    align_items: Alignment = .stretch,
    /// 宽度
    width: ?f32 = null,
    /// 高度
    height: ?f32 = null,
    /// 内边距
    padding: ?Padding = null,
    /// 背景色
    background: ?Color = null,
    /// 反向
    reverse: bool = false,
};

/// 创建垂直堆叠
pub fn VStack(props: VStackProps) VStackBuilder {
    return VStackBuilder{ .props = props };
}

pub const VStackBuilder = struct {
    props: VStackProps,

    pub fn gap(self: VStackBuilder, g: f32) VStackBuilder {
        var new = self;
        new.props.gap = g;
        return new;
    }

    pub fn justify(self: VStackBuilder, j: Justify) VStackBuilder {
        var new = self;
        new.props.justify = j;
        return new;
    }

    pub fn alignItems(self: VStackBuilder, a: Alignment) VStackBuilder {
        var new = self;
        new.props.align_items = a;
        return new;
    }

    pub fn padding(self: VStackBuilder, p: Padding) VStackBuilder {
        var new = self;
        new.props.padding = p;
        return new;
    }

    pub fn background(self: VStackBuilder, c: Color) VStackBuilder {
        var new = self;
        new.props.background = c;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: VStackBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const p = self.props;

        const bg = p.background orelse Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const pad = p.padding orelse Padding.ZERO;
        const dir: Direction = if (p.reverse) .column_reverse else .column;
        const width: Sizing = if (p.width) |w| .{ .px = w } else .{ .fit = .{} };
        const height: Sizing = if (p.height) |h| .{ .px = h } else .{ .fit = .{} };

        const node = try box(cx, .{
            .width = width,
            .height = height,
            .direction = dir,
            .gap = p.gap,
            .justify = p.justify,
            .align_items = p.align_items,
            .padding = pad,
            .background = bg,
        }, .{});
        // sweep：node 建好到 bindScopeToNode 之间失败会漏 node
        errdefer cx.freeNode(node);
        try core.bindScopeToNode(my_scope, node);
        return node;
    }
};

/// HStack 属性
pub const HStackProps = struct {
    /// 间距
    gap: f32 = 0,
    /// 主轴对齐
    justify: Justify = .start,
    /// 交叉轴对齐
    align_items: Alignment = .center,
    /// 宽度
    width: ?f32 = null,
    /// 高度
    height: ?f32 = null,
    /// 内边距
    padding: ?Padding = null,
    /// 背景色
    background: ?Color = null,
    /// 反向
    reverse: bool = false,
    /// 换行
    wrap: bool = false,
};

/// 创建水平堆叠
pub fn HStack(props: HStackProps) HStackBuilder {
    return HStackBuilder{ .props = props };
}

pub const HStackBuilder = struct {
    props: HStackProps,

    pub fn gap(self: HStackBuilder, g: f32) HStackBuilder {
        var new = self;
        new.props.gap = g;
        return new;
    }

    pub fn justify(self: HStackBuilder, j: Justify) HStackBuilder {
        var new = self;
        new.props.justify = j;
        return new;
    }

    pub fn alignItems(self: HStackBuilder, a: Alignment) HStackBuilder {
        var new = self;
        new.props.align_items = a;
        return new;
    }

    pub fn padding(self: HStackBuilder, p: Padding) HStackBuilder {
        var new = self;
        new.props.padding = p;
        return new;
    }

    pub fn background(self: HStackBuilder, c: Color) HStackBuilder {
        var new = self;
        new.props.background = c;
        return new;
    }

    pub fn wrap(self: HStackBuilder, w: bool) HStackBuilder {
        var new = self;
        new.props.wrap = w;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: HStackBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const p = self.props;

        const bg = p.background orelse Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const pad = p.padding orelse Padding.ZERO;
        const dir: Direction = if (p.reverse) .row_reverse else .row;
        const width: Sizing = if (p.width) |w| .{ .px = w } else .{ .fit = .{} };
        const height: Sizing = if (p.height) |h| .{ .px = h } else .{ .fit = .{} };

        var node = try box(cx, .{
            .width = width,
            .height = height,
            .direction = dir,
            .gap = p.gap,
            .justify = p.justify,
            .align_items = p.align_items,
            .padding = pad,
            .background = bg,
        }, .{});

        // Wrap 需要在 style 中设置
        if (p.wrap) {
            (try node.style.ensureExtFallible(cx.allocator)).flex_wrap = .wrap;
        }

        // sweep：node 建好到 bindScopeToNode 之间失败会漏 node
        errdefer cx.freeNode(node);
        try core.bindScopeToNode(my_scope, node);
        return node;
    }
};

/// Spacer - 弹性间隔
pub fn Spacer() SpacerBuilder {
    return SpacerBuilder{};
}

pub const SpacerBuilder = struct {
    min_size: f32 = 0,

    pub fn build(self: SpacerBuilder, ctx: *Cx) !*Node {
        // Spacer 是一个 flex: 1 的空节点
        const w: core.Sizing = if (self.min_size > 0) .{ .px = self.min_size } else .{ .grow = .{} };
        const h: core.Sizing = if (self.min_size > 0) .{ .px = self.min_size } else .{ .grow = .{} };
        var node = try box(ctx, .{
            .width = w,
            .height = h,
        }, .{});

        // 设置 flex: 1 以占据剩余空间
        node.style.flex = 1;

        return node;
    }
};

// ========== 测试 ==========

test "VStack: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try VStack(.{ .gap = 10 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    // 创建子元素
    const item1 = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    const item2 = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try stack.appendChild(std.testing.allocator, item1);
    try stack.appendChild(std.testing.allocator, item2);

    ctx.layout();

    try std.testing.expectEqual(@as(usize, 2), stack.children.items.len);
    try std.testing.expectEqual(Direction.column, stack.style.direction);
}

test "HStack: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try HStack(.{ .gap = 8, .align_items = .center }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    const item1 = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{});
    const item2 = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 40 } }, .{});
    try stack.appendChild(std.testing.allocator, item1);
    try stack.appendChild(std.testing.allocator, item2);

    ctx.layout();

    try std.testing.expectEqual(Direction.row, stack.style.direction);
    try std.testing.expectEqual(Alignment.center, stack.style.align_items);
}

test "VStack: reverse" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try VStack(.{ .reverse = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    try std.testing.expectEqual(Direction.column_reverse, stack.style.direction);
}

test "HStack: justify space-between" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try HStack(.{
        .justify = .space_between,
        .width = 300,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    try std.testing.expectEqual(Justify.space_between, stack.style.justify);
}

test "Spacer: fills space" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try HStack(.{ .width = 300 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    const left = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{});
    const spacer = try Spacer().build(ctx);
    const right = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{});

    try stack.appendChild(std.testing.allocator, left);
    try stack.appendChild(std.testing.allocator, spacer);
    try stack.appendChild(std.testing.allocator, right);

    try std.testing.expectEqual(@as(f32, 1), spacer.style.flex);
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "vstack: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("vstack", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try VStack(.{ .gap = 4, .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 } }).mount(scope, cx);
        }
    }.m);
}
