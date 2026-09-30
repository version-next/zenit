/// Divider Component
///
/// 分隔线组件，用于分隔内容区域
///
/// 特性:
/// - 方向: horizontal / vertical
/// - 样式: solid, dashed, dotted
/// - 间距: none, sm, md, lg
/// - 标签支持
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const CornerRadius = core.CornerRadius;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;

/// 分隔线方向
pub const DividerOrientation = enum {
    horizontal,
    vertical,
};

/// 分隔线样式
pub const DividerVariant = enum {
    solid,
    dashed,
    dotted,
};

/// 分隔线间距
pub const DividerSpacing = enum {
    none,
    sm,
    md,
    lg,

    pub fn value(self: DividerSpacing) f32 {
        return switch (self) {
            .none => 0,
            .sm => 8,
            .md => 16,
            .lg => 24,
        };
    }
};

/// 标签位置
pub const LabelPosition = enum {
    left,
    center,
    right,
};

/// Divider 属性
pub const DividerProps = struct {
    /// 方向
    orientation: DividerOrientation = .horizontal,
    /// 样式变体
    variant: DividerVariant = .solid,
    /// 间距
    spacing: DividerSpacing = .md,
    /// 标签文本
    label_text: ?[]const u8 = null,
    /// 标签位置
    label_position: LabelPosition = .center,
    /// 颜色
    color: ?Color = null,
    /// 粗细
    thickness: f32 = 1,
    /// dash 的实线段长度
    dash_length: f32 = 8,
    /// dash 的间距
    dash_gap: f32 = 8,
};

// 样式层析出至 styles.zig；下列别名保持调用点与公共 API 不变。
const styles = @import("styles.zig");
const lineStyle = styles.lineStyle;
const patternedContainerStyle = styles.patternedContainerStyle;
const dashStyle = styles.dashStyle;
const labelContainerStyle = styles.labelContainerStyle;
const labelLineStyle = styles.labelLineStyle;
const labelTextStyle = styles.labelTextStyle;
const fitBoxStyle = styles.fitBoxStyle;

/// 创建分隔线
pub fn Divider(props: DividerProps) DividerBuilder {
    return DividerBuilder{ .props = props };
}

pub const DividerBuilder = struct {
    props: DividerProps,

    pub fn orientation(self: DividerBuilder, o: DividerOrientation) DividerBuilder {
        var new = self;
        new.props.orientation = o;
        return new;
    }

    pub fn variant(self: DividerBuilder, v: DividerVariant) DividerBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    pub fn spacing(self: DividerBuilder, s: DividerSpacing) DividerBuilder {
        var new = self;
        new.props.spacing = s;
        return new;
    }

    pub fn label(self: DividerBuilder, text: []const u8) DividerBuilder {
        var new = self;
        new.props.label_text = text;
        return new;
    }

    pub fn labelPosition(self: DividerBuilder, pos: LabelPosition) DividerBuilder {
        var new = self;
        new.props.label_position = pos;
        return new;
    }

    pub fn color(self: DividerBuilder, c: Color) DividerBuilder {
        var new = self;
        new.props.color = c;
        return new;
    }

    pub fn thickness(self: DividerBuilder, t: f32) DividerBuilder {
        var new = self;
        new.props.thickness = t;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: DividerBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        // 绑定成功之前 my_scope 与 node 都无人持有：
        // mountSimple / mountWithLabel / bindScopeToNode 任一失败都会漏
        // （下游编辑器 git_diff sweep index 123 实测）。
        // bindScopeToNode 成功后 node 归 my_scope，my_scope 归父 scope，
        // 此时不再需要这条 errdefer —— 用 committed flag 精确划界。
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const t = cx.tokens;
        const p = self.props;
        const space = p.spacing.value();
        const line_color = p.color orelse t.color.border_strong;

        // 带标签的水平分隔线
        if (p.label_text != null and p.orientation == .horizontal) {
            const node = try self.mountWithLabel(cx, line_color, space);
            errdefer cx.freeNode(node);
            node.meta.ownership.meta.component_name = "Divider";
            try core.bindScopeToNode(my_scope, node);
            scope_bound = true;
            return node;
        }

        // 简单分隔线
        const node = try self.mountSimple(cx, line_color, space);
        errdefer cx.freeNode(node);
        node.meta.ownership.meta.component_name = "Divider";
        try core.bindScopeToNode(my_scope, node);
        scope_bound = true;
        return node;
    }

    fn mountSimple(self: DividerBuilder, cx: *Cx, line_color: Color, space: f32) !*Node {
        const p = self.props;

        if (p.variant != .solid) {
            return self.mountPatterned(cx, line_color, space);
        }

        return box(cx, lineStyle(p.orientation, p.thickness, line_color, space), .{});
    }

    fn mountPatterned(self: DividerBuilder, cx: *Cx, line_color: Color, space: f32) !*Node {
        const allocator = cx.allocator;
        const p = self.props;
        const dash_length = if (p.variant == .dotted) p.thickness else p.dash_length;
        const dash_gap = p.dash_gap;
        const dash_count: usize = 128;

        const container = try box(cx, patternedContainerStyle(p.orientation, p.thickness, dash_gap, space), .{});
        // container 是返回给调用方的子树根，返回成功前无人持有：
        // 下面 128 个 dash 的构造任一失败即漏整棵（下游编辑器 git_diff sweep 实测）。
        errdefer cx.freeNode(container);

        var i: usize = 0;
        while (i < dash_count) : (i += 1) {
            // 建好即挂：dash 不留游离窗口。
            const dash = try adoptDividerChild(cx, allocator, container, try box(cx, dashStyle(p.orientation, p.thickness, dash_length, line_color), .{}));
            if (p.variant == .dotted) {
                // 本函数可失败，没理由在这里 panic（OOM 下会 abort 整个进程）。
                (try dash.style.ensureExtFallible(allocator)).corner_radius = CornerRadius.uniform(p.thickness / 2);
            }
            dash.style.flex_shrink = 0; // 防止 flex shrink 把 dash 压缩到 0
        }

        return container;
    }

    fn mountWithLabel(self: DividerBuilder, cx: *Cx, line_color: Color, space: f32) !*Node {
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        const lbl = p.label_text.?;

        // 外层容器 (flex row)
        const container = try box(cx, labelContainerStyle(space), .{});

        const makeLabel = struct {
            fn make(cx_: *Cx, content: []const u8, tokens: *const core.theme.ThemeTokens) !*Node {
                const label_node = try box(cx_, fitBoxStyle(), .{});
                var txt = labelTextStyle(tokens);
                txt.content = content;
                label_node.setText(txt);
                return label_node;
            }
        }.make;

        const makeLine = struct {
            fn make(cx_: *Cx, thick: f32, color_: Color) !*Node {
                const line = try box(cx_, labelLineStyle(thick, color_), .{});
                line.style.flex = 1;
                return line;
            }
        }.make;

        // 根据标签位置创建线段
        switch (p.label_position) {
            .left => {
                // 标签在左: label + 长线
                try container.appendChild(allocator, try makeLabel(cx, lbl, t));
                try container.appendChild(allocator, try makeLine(cx, p.thickness, line_color));
            },
            .center => {
                // 标签在中: 线 + 标签 + 线
                try container.appendChild(allocator, try makeLine(cx, p.thickness, line_color));
                try container.appendChild(allocator, try makeLabel(cx, lbl, t));
                try container.appendChild(allocator, try makeLine(cx, p.thickness, line_color));
            },
            .right => {
                // 标签在右: 长线 + label
                try container.appendChild(allocator, try makeLine(cx, p.thickness, line_color));
                try container.appendChild(allocator, try makeLabel(cx, lbl, t));
            },
        }

        return container;
    }
};

// ========== 测试 ==========

test "Divider: horizontal simple" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{})
        .orientation(.horizontal)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    ctx.layout();

    // 水平分隔线高度应该是 thickness
    try std.testing.expectEqual(@as(f32, 1), divider_node.style.height.px);
}

test "Divider: vertical" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{})
        .orientation(.vertical)
        .thickness(2)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // 垂直分隔线宽度应该是 thickness
    try std.testing.expectEqual(@as(f32, 2), divider_node.style.width.px);
}

test "Divider: with label center" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{})
        .label("OR")
        .labelPosition(.center)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // center label: 3 个子节点 (line + label + line)
    try std.testing.expectEqual(@as(usize, 3), divider_node.children.items.len);
}

test "Divider: with label left" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{})
        .label("Section")
        .labelPosition(.left)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // left label: 2 个子节点 (label + line)
    try std.testing.expectEqual(@as(usize, 2), divider_node.children.items.len);
}

test "Divider: custom color" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const custom_color = Color.hex(0xff0000);
    const divider_node = try Divider(.{})
        .color(custom_color)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // 背景色应该是自定义颜色 (红色 = 0xff0000)
    try std.testing.expectEqual(@as(u8, 255), divider_node.getBackground().r);
    try std.testing.expectEqual(@as(u8, 0), divider_node.getBackground().g);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

/// 一次性收养：append 失败时自己释放 child。让「建好即挂」写起来不啰嗦。
fn adoptDividerChild(cx: *Cx, allocator: std.mem.Allocator, parent: *Node, child: *Node) !*Node {
    errdefer cx.freeNode(child);
    try parent.appendChild(allocator, child);
    return child;
}

test "Divider: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("divider", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Divider(.{}).orientation(.horizontal).mount(scope, cx);
        }
    }.m);
}
