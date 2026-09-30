/// Breadcrumb Component
///
/// 面包屑导航，显示当前页面在层级中的位置
///
/// 特性:
/// - 可点击的导航链接
/// - 自定义分隔符
/// - 最后一项不可点击 (当前页)
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;

/// 面包屑项
pub const BreadcrumbItem = struct {
    id: []const u8,
    label_text: []const u8,
};

/// Breadcrumb 属性
pub const BreadcrumbProps = struct {
    items: []const BreadcrumbItem = &.{},
    separator: []const u8 = "/",
    on_click: ?core.HandlerRef = null,
};

/// 创建 Breadcrumb
pub fn Breadcrumb(props: BreadcrumbProps) BreadcrumbBuilder {
    return BreadcrumbBuilder{ .props = props };
}

pub const BreadcrumbBuilder = struct {
    props: BreadcrumbProps,

    pub fn items(self: BreadcrumbBuilder, its: []const BreadcrumbItem) BreadcrumbBuilder {
        var new = self;
        new.props.items = its;
        return new;
    }

    pub fn separator(self: BreadcrumbBuilder, s: []const u8) BreadcrumbBuilder {
        var new = self;
        new.props.separator = s;
        return new;
    }

    pub fn onClick(self: BreadcrumbBuilder, handler_ref: core.HandlerRef) BreadcrumbBuilder {
        var new = self;
        new.props.on_click = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: BreadcrumbBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const container = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
            .align_items = .center,
            .gap = 4,
        }, .{});
        // sweep：container 守到 return；item / 分隔符建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Breadcrumb";
        try core.bindScopeToNode(my_scope, container);
        // 此前是 role=.none —— 投影层遇到 none + 不可 focus 会直接丢弃整个
        // 节点，等于 Breadcrumb 在 AT 侧根本不存在。role=navigation + label
        // 才能让 AT 把它列进"页面地标"，用户可以直接跳过来看自己在哪一层。
        container.behavior.interaction.a11y = .{
            .role = .navigation,
            .label = "Breadcrumb",
        };

        for (p.items, 0..) |item, i| {
            const is_last = (i == p.items.len - 1);

            // 链接 / 当前页
            var item_node = try core.adoptChild(cx, allocator, container, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
                .padding = Padding.symmetric(2, 2),
            }, .{}));
            item_node.setText(.{
                .content = item.label_text,
                .color = if (is_last) t.color.fg_primary else t.color.accent,
                .font_size = t.font_size.sm,
            });

            // 最后一项是当前页（不可点），用 selected 标出来；前面的都是
            // 可点链接。AT 用户否则分不清哪一级是"我现在在这儿"。
            item_node.behavior.interaction.a11y = .{
                // 当前页用 listitem 而不是 .none —— .none + 不可 focus 会被
                // 投影层整个丢掉，那"我现在在哪一层"就又没了。
                .role = if (is_last) .listitem else .link,
                .label = item.label_text,
                .selected = is_last,
            };

            if (!is_last) {
                item_node.style.cursor = .pointer;
                if (p.on_click) |handler| {
                    item_node.behavior.events.on_click = handler;
                }
            }

            // 分隔符 (不是最后一个)
            if (!is_last) {
                const sep_node = try core.adoptChild(cx, allocator, container, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                sep_node.setText(.{
                    .content = p.separator,
                    .color = t.color.fg_disabled,
                    .font_size = t.font_size.sm,
                });
            }
        }

        return container;
    }
};

// ========== 测试 ==========

const test_items = [_]BreadcrumbItem{
    .{ .id = "home", .label_text = "Home" },
    .{ .id = "docs", .label_text = "Documents" },
    .{ .id = "file", .label_text = "Report.pdf" },
};

test "Breadcrumb: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const bc = try Breadcrumb(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, bc);

    // 3 items + 2 separators = 5 子节点
    try std.testing.expectEqual(@as(usize, 5), bc.children.items.len);
}

test "Breadcrumb: last item not clickable" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const bc = try Breadcrumb(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, bc);

    // 最后一项 (index 4) 没有 pointer cursor
    const last = bc.children.items[4];
    try std.testing.expectEqual(core.CursorShape.inherit, last.style.cursor);
}

test "Breadcrumb: single item" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const single = [_]BreadcrumbItem{
        .{ .id = "home", .label_text = "Home" },
    };

    const bc = try Breadcrumb(.{
        .items = &single,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, bc);

    // 1 item, 0 separators
    try std.testing.expectEqual(@as(usize, 1), bc.children.items.len);
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "breadcrumb: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("breadcrumb", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Breadcrumb(.{ .items = &test_items }).mount(scope, cx);
        }
    }.m);
}
