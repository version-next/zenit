/// Timeline Component
///
/// 时间线组件，用于展示事件流程
///
/// 特性:
/// - 垂直布局
/// - 状态点 + 连接线
/// - 标题 + 描述 + 时间
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Scope = @import("../../reactive.zig").Scope;

// 样式层已析出到 styles.zig
const styles = @import("styles.zig");

/// 时间线项状态
pub const TimelineStatus = enum {
    completed,
    active,
    pending,

    pub fn dotColor(self: TimelineStatus, t: *const theme.ThemeTokens) Color {
        return switch (self) {
            .completed => t.color.success,
            .active => t.color.accent,
            .pending => t.color.border,
        };
    }

    pub fn lineColor(self: TimelineStatus, t: *const theme.ThemeTokens) Color {
        return switch (self) {
            .completed => t.color.success,
            .active, .pending => t.color.border,
        };
    }
};

/// 时间线项
pub const TimelineItem = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    time: ?[]const u8 = null,
    status: TimelineStatus = .pending,
};

/// Timeline 属性
pub const TimelineProps = struct {
    items: []const TimelineItem = &.{},
};

/// 创建 Timeline
pub fn Timeline(props: TimelineProps) TimelineBuilder {
    return TimelineBuilder{ .props = props };
}

pub const TimelineBuilder = struct {
    props: TimelineProps,

    pub fn items(self: TimelineBuilder, its: []const TimelineItem) TimelineBuilder {
        var new = self;
        new.props.items = its;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: TimelineBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const container = try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .column,
        }, .{});
        container.meta.ownership.meta.component_name = "Timeline";
        // sweep：container 守卫一直武装到 return；行及行内子节点建好即 adopt
        errdefer cx.freeNode(container);
        try core.bindScopeToNode(my_scope, container);
        container.behavior.interaction.a11y = .{ .role = .list, .label = "Timeline" };

        for (p.items, 0..) |item, i| {
            const is_last = (i == p.items.len - 1);

            const row = try core.adoptChild(cx, allocator, container, try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{ .min = 48 } },
                .direction = .row,
                .gap = 12,
            }, .{}));

            // 状态全靠圆点颜色表达，AT 用户完全接收不到。显式说出来：
            // checked=已完成、selected=进行中、disabled=尚未开始。
            row.behavior.interaction.a11y = .{
                .role = .listitem,
                .label = item.title,
                .description = item.description,
                .value_text = item.time,
                .checked = (item.status == .completed),
                .selected = (item.status == .active),
                .disabled = (item.status == .pending),
            };

            // ---- 指示器列 (dot + line) ----
            const indicator = try core.adoptChild(cx, allocator, row, try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .grow = .{} },
                .direction = .column,
                .align_items = .center,
            }, .{}));

            // 状态圆点
            _ = try core.adoptChild(cx, allocator, indicator, try box(cx, styles.dotStyle(item.status, t), .{}));

            // 连接线 (不是最后一项)
            if (!is_last) {
                _ = try core.adoptChild(cx, allocator, indicator, try box(cx, styles.connectorStyle(item.status, t), .{}));
            }

            // ---- 内容列 ----
            const bottom_pad: f32 = if (is_last) 0 else 16;
            const content = try core.adoptChild(cx, allocator, row, try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
                .direction = .column,
                .gap = 2,
            }, .{}));
            content.style.padding.bottom = bottom_pad;

            // 标题
            const title_node = try core.adoptChild(cx, allocator, content, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            var title_txt = styles.titleTextProps(item.status, t);
            title_txt.content = item.title;
            title_node.setText(title_txt);

            // 描述
            if (item.description) |desc| {
                const desc_node = try core.adoptChild(cx, allocator, content, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                var desc_txt = styles.descTextProps(t);
                desc_txt.content = desc;
                desc_node.setText(desc_txt);
            }

            // 时间
            if (item.time) |time_text| {
                const time_node = try core.adoptChild(cx, allocator, content, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                var time_txt = styles.timeTextProps(t);
                time_txt.content = time_text;
                time_node.setText(time_txt);
            }
        }

        return container;
    }
};

// ========== 测试 ==========

const test_items = [_]TimelineItem{
    .{ .title = "Created", .description = "Project initialized", .time = "2024-01-01", .status = .completed },
    .{ .title = "In Progress", .description = "Development ongoing", .status = .active },
    .{ .title = "Review", .status = .pending },
    .{ .title = "Deploy", .status = .pending },
};

test "Timeline: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tl = try Timeline(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tl);

    // 4 行
    try std.testing.expectEqual(@as(usize, 4), tl.children.items.len);
}

test "Timeline: last item no line" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tl = try Timeline(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tl);

    // 最后一行的指示器列只有 dot (1个子节点), 前面的有 dot + line (2个)
    const first_row = tl.children.items[0];
    const first_indicator = first_row.children.items[0];
    try std.testing.expectEqual(@as(usize, 2), first_indicator.children.items.len);

    const last_row = tl.children.items[3];
    const last_indicator = last_row.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), last_indicator.children.items.len);
}

test "Timeline: single item" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const single = [_]TimelineItem{
        .{ .title = "Only", .status = .active },
    };

    const tl = try Timeline(.{
        .items = &single,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tl);
    try std.testing.expectEqual(@as(usize, 1), tl.children.items.len);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "timeline: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("timeline", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]TimelineItem{ .{ .title = "start", .time = "09:00", .status = .completed }, .{ .title = "mid", .description = "desc" }, .{ .title = "end" } };
            return try Timeline(.{ .items = &items }).mount(scope, cx);
        }
    }.m);
}
