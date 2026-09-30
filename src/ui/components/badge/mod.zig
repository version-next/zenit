/// Badge Component
///
/// 徽章组件，用于显示状态、计数等
///
/// 特性:
/// - 多种变体: info, success, warning, error
/// - 尺寸: sm, md
/// - 点状模式
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const ConditionalStyle = core.ConditionalStyle;
const Scope = @import("../../reactive.zig").Scope;
const recipe_mod = @import("../../recipe.zig");

/// 徽章状态
pub const BadgeStatus = enum {
    info,
    success,
    warning,
    @"error",
};

/// 徽章尺寸
pub const BadgeSize = enum {
    sm,
    md,

    pub fn height(self: BadgeSize) f32 {
        return switch (self) {
            .sm => 16,
            .md => 20,
        };
    }

    pub fn fontSize(self: BadgeSize) f32 {
        return switch (self) {
            .sm => 10,
            .md => 11,
        };
    }

    pub fn padding(self: BadgeSize) Padding {
        return switch (self) {
            .sm => Padding.symmetric(2, 6),
            .md => Padding.symmetric(2, 8),
        };
    }
};

// 样式层析出至 styles.zig；下列别名保持调用点与公共 API 不变。
const styles = @import("styles.zig");
pub const BadgeRecipe = styles.BadgeRecipe;
const badgeDotStyle = styles.badgeDotStyle;
const statusBadgeContainerStyle = styles.statusBadgeContainerStyle;
const statusBadgeLabelStyle = styles.statusBadgeLabelStyle;

/// Badge 属性
pub const BadgeProps = struct {
    /// 显示文本
    text: ?[]const u8 = null,
    /// 数字计数
    count: ?u32 = null,
    /// 最大显示数
    max_count: u32 = 99,
    /// 状态
    status: BadgeStatus = .info,
    /// 尺寸
    size: BadgeSize = .md,
    /// 点状模式（只显示点，不显示内容）
    dot: bool = false,
};

/// 创建 Badge
pub fn Badge(props: BadgeProps) BadgeBuilder {
    return BadgeBuilder{ .props = props };
}

pub const BadgeBuilder = struct {
    props: BadgeProps,

    pub fn text(self: BadgeBuilder, t: []const u8) BadgeBuilder {
        var new = self;
        new.props.text = t;
        return new;
    }

    pub fn count(self: BadgeBuilder, c: u32) BadgeBuilder {
        var new = self;
        new.props.count = c;
        return new;
    }

    pub fn status(self: BadgeBuilder, s: BadgeStatus) BadgeBuilder {
        var new = self;
        new.props.status = s;
        return new;
    }

    pub fn size(self: BadgeBuilder, s: BadgeSize) BadgeBuilder {
        var new = self;
        new.props.size = s;
        return new;
    }

    pub fn dot(self: BadgeBuilder, d: bool) BadgeBuilder {
        var new = self;
        new.props.dot = d;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: BadgeBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const t = cx.tokens;
        const p = self.props;

        // Recipe resolve：status × size 两维度统一合并
        const cs = BadgeRecipe.resolve(.{ .status = p.status, .size = p.size }, t);
        const resolved = cs.resolve(.{});

        if (p.dot) {
            // 点状模式：固定 8×8 圆点，颜色来自 recipe
            const dot_node = try box(cx, badgeDotStyle(resolved.background orelse Color.TRANSPARENT), .{});
            // sweep：bindScopeToNode 失败时节点不能漏
            errdefer cx.freeNode(dot_node);
            dot_node.meta.ownership.meta.component_name = "Badge";
            try core.bindScopeToNode(my_scope, dot_node);
            return dot_node;
        }

        // 计算显示内容
        var display_text: []const u8 = "";
        var count_formatted: ?[]const u8 = null;
        // 必须与 count_formatted 同作用域：下面 setInlineContent(fmt) 在块外才读它，
        // 声明在 else-if 块内时读到的是已出作用域的栈内存。
        var tmp_buf: [16]u8 = undefined;

        if (p.text) |txt| {
            display_text = txt;
        } else if (p.count) |c| {
            count_formatted = if (c > p.max_count)
                std.fmt.bufPrint(&tmp_buf, "{d}+", .{p.max_count}) catch "99+"
            else
                std.fmt.bufPrint(&tmp_buf, "{d}", .{c}) catch "0";
            display_text = "0";
        }

        // 创建徽章 — 颜色/几何全部来自 recipe resolve 结果
        const badge_height: f32 = if (resolved.height) |h| h.px else p.size.height();
        const node = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .px = badge_height },
            .background = resolved.background orelse Color.TRANSPARENT,
            .padding = resolved.padding,
            .border = .{ .radius = badge_height / 2 },
            .justify = .center,
            .align_items = .center,
        }, .{});
        // sweep：bindScopeToNode 失败时节点不能漏
        errdefer cx.freeNode(node);
        if (display_text.len > 0) {
            node.setText(.{ .content = display_text });
        }
        node.meta.ownership.meta.component_name = "Badge";
        try core.bindScopeToNode(my_scope, node);

        // 文本样式：颜色/字号/字重全部来自 recipe resolve 结果
        if (node.getText()) |old| {
            var txt = old;
            txt.color = resolved.text_color orelse t.color.fg_inverse;
            txt.font_size = resolved.font_size orelse p.size.fontSize();
            txt.font_weight = resolved.font_weight orelse 600;
            if (count_formatted) |fmt| {
                try txt.setContent(cx.allocator, fmt);
            }
            node.setText(txt);
        }

        return node;
    }
};

/// 状态徽章（带图标的状态显示）
pub const StatusBadgeProps = struct {
    status: BadgeStatus = .info,
    label_text: ?[]const u8 = null,
};

pub fn StatusBadge(props: StatusBadgeProps) StatusBadgeBuilder {
    return StatusBadgeBuilder{ .props = props };
}

pub const StatusBadgeBuilder = struct {
    props: StatusBadgeProps,

    pub fn label(self: StatusBadgeBuilder, text: []const u8) StatusBadgeBuilder {
        var new = self;
        new.props.label_text = text;
        return new;
    }

    pub fn status(self: StatusBadgeBuilder, s: BadgeStatus) StatusBadgeBuilder {
        var new = self;
        new.props.status = s;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: StatusBadgeBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Recipe resolve 取状态点颜色
        const cs = BadgeRecipe.resolve(.{ .status = p.status }, t);
        const resolved = cs.resolve(.{});
        const dot_bg = resolved.background orelse Color.TRANSPARENT;

        const container = try box(cx, statusBadgeContainerStyle(), .{});
        // sweep：container 守到 return；子节点建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "StatusBadge";
        try core.bindScopeToNode(my_scope, container);

        // 状态点
        _ = try core.adoptChild(cx, allocator, container, try box(cx, badgeDotStyle(dot_bg), .{}));

        // 标签
        if (p.label_text) |lbl| {
            const label_node = try core.adoptChild(cx, allocator, container, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
            var label_txt = statusBadgeLabelStyle(t);
            label_txt.content = lbl;
            label_node.setText(label_txt);
        }

        return container;
    }
};

// ========== 测试 ==========

test "Badge: text" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const badge_node = try Badge(.{})
        .text("New")
        .status(.info)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, badge_node);

    try std.testing.expect(badge_node.getText() != null);
    try std.testing.expectEqualStrings("New", badge_node.getText().?.content);
}

test "Badge: count" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const badge_node = try Badge(.{})
        .count(42)
        .status(.success)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, badge_node);

    try std.testing.expect(badge_node.getText() != null);
}

test "Badge: count 文本内容正确（格式化缓冲不越出作用域）" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const a = try Badge(.{}).count(42).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, a);
    const b = try Badge(.{ .max_count = 99 }).count(500).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, b);
    try std.testing.expectEqualStrings("42", a.getText().?.content);
    try std.testing.expectEqualStrings("99+", b.getText().?.content);
}

test "Badge: count overflow" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const badge_node = try Badge(.{ .max_count = 99 })
        .count(150)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, badge_node);

    try std.testing.expect(badge_node.getText() != null);
}

test "Badge: dot mode" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const dot_badge = try Badge(.{})
        .dot(true)
        .status(.@"error")
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, dot_badge);

    // 点状模式没有文本
    try std.testing.expect(dot_badge.getText() == null);
    // 尺寸应该是 8x8
    ctx.layout();
    try std.testing.expectEqual(@as(f32, 8), dot_badge.style.width.px);
}

test "StatusBadge: with label" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const status_badge = try StatusBadge(.{})
        .label("Online")
        .status(.success)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, status_badge);

    // 应该有 2 个子节点: dot + label
    try std.testing.expectEqual(@as(usize, 2), status_badge.children.items.len);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "badge(text+status): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("badge(text+status)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Badge(.{}).text("New").status(.info).mount(scope, cx);
        }
    }.m);
}

test "status_badge: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("status_badge", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try StatusBadge(.{}).mount(scope, cx);
        }
    }.m);
}
