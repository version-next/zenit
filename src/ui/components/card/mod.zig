/// Card Component
///
/// 卡片容器组件，支持标题、内容、底部区域
///
/// 特性:
/// - 变体: default, outlined, elevated
/// - 标题/副标题
/// - 可交互/可悬停
/// - 选中状态
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const hooks = @import("../../hooks.zig");
const Scope = @import("../../reactive.zig").Scope;

const ConditionalStyle = core.ConditionalStyle;
const Border = core.Border;
const recipe_mod = @import("../../recipe.zig");
const styles = @import("styles.zig");

/// 卡片变体
pub const CardVariant = enum {
    default,
    outlined,
    elevated,
};

pub const CardRecipe = styles.CardRecipe;

/// 卡片属性
pub const CardProps = struct {
    /// 标题
    title: ?[]const u8 = null,
    /// 副标题
    subtitle: ?[]const u8 = null,
    /// 变体
    variant: CardVariant = .default,
    /// 可交互
    interactive: bool = false,
    /// 可悬停
    hoverable: bool = false,
    /// 选中状态
    selected: bool = false,
    /// 内边距
    padded: bool = true,
    /// 宽度
    width: ?f32 = null,
    /// 高度
    height: ?f32 = null,
    /// 点击回调
    on_click: ?core.HandlerRef = null,
};

/// 创建卡片
pub fn Card(props: CardProps) CardBuilder {
    return CardBuilder{ .props = props };
}

pub const CardBuilder = struct {
    props: CardProps,

    pub fn title(self: CardBuilder, t: []const u8) CardBuilder {
        var new = self;
        new.props.title = t;
        return new;
    }

    pub fn subtitle(self: CardBuilder, s: []const u8) CardBuilder {
        var new = self;
        new.props.subtitle = s;
        return new;
    }

    pub fn variant(self: CardBuilder, v: CardVariant) CardBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    pub fn interactive(self: CardBuilder, i: bool) CardBuilder {
        var new = self;
        new.props.interactive = i;
        return new;
    }

    pub fn selected(self: CardBuilder, s: bool) CardBuilder {
        var new = self;
        new.props.selected = s;
        return new;
    }

    pub fn width(self: CardBuilder, w: f32) CardBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn height(self: CardBuilder, h: f32) CardBuilder {
        var new = self;
        new.props.height = h;
        return new;
    }

    pub fn onClick(self: CardBuilder, handler_ref: core.HandlerRef) CardBuilder {
        var new = self;
        new.props.on_click = handler_ref;
        new.props.interactive = true;
        return new;
    }

    /// 保留模式: mount（只调一次）
    pub fn mount(self: CardBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Recipe resolve：variant（background / border / corner_radius / shadow / hover）
        // + selected 条件位（2px accent 边框）
        const cs = CardRecipe.resolve(.{ .variant = p.variant }, t);
        const resolved = cs.resolve(.{ .is_selected = p.selected });

        // border fold：细粒度 border_color/border_width（selected 条件产出）折进 Border
        var card_border: core.Border = resolved.border orelse .{};
        if (resolved.corner_radius) |cr| card_border.radius = cr;
        if (resolved.border_color) |bc| card_border.color = bc;
        if (resolved.border_width) |bw| card_border.width = bw;

        const card = try box(cx, .{
            .width = if (p.width) |w| .{ .px = w } else .{ .fit = .{} },
            .height = if (p.height) |h| .{ .px = h } else .{ .fit = .{} },
            .background = resolved.background orelse Color.TRANSPARENT,
            .border = card_border,
            .direction = .column,
        }, .{});
        // sweep：card 从建好到 return 之间还有 ensureExt / bind / hooks / header 等可失败步骤，
        // 守卫一直武装到 return（bindScopeToNode 之后 freeNode 会连带 dispose my_scope）。
        errdefer cx.freeNode(card);
        // elevated 的 shadow 在 StyleExt 中，通过 applyTo 处理
        if (resolved.shadow) |sh| (try card.style.ensureExtFallible(allocator)).setShadow(sh);
        if (p.on_click) |h| {
            card.behavior.events.on_click = .{
                .callback = h.callback,
                .context = h.context,
            };
        }
        card.meta.ownership.meta.component_name = "Card";
        // 整卡可点（.interactive(true) / .onClick(...)）时必须进 tab 序并对 AT
        // 报角色，否则纯键盘用户 Tab 不到、VoiceOver 直接跳过整个卡片
        // —— WCAG 2.1.1（键盘）与 4.1.2（名称/角色/值）双 A 级失败。
        // label 用 title 兜底；没有 title 时 a11y 投影会借子树文本（见
        // core.zig 的 label fallback），所以这里不强行造名字。
        if (p.interactive) {
            card.setFocusable(true);
            card.behavior.interaction.a11y = .{
                .role = .button,
                .label = p.title,
                .selected = p.selected,
            };
        }
        try core.bindScopeToNode(my_scope, card);

        // Hover 高亮（Scope 版本）— hover 目标色来自 recipe 的 hover 态
        if (p.hoverable or p.interactive) {
            if (!p.selected) {
                const hovered = cs.resolve(.{ .is_hovered = true });
                if (p.variant == .outlined) {
                    const normal_border = card.style.border.color;
                    _ = try hooks.useHoverHighlight(my_scope, card, card, .border_color, normal_border, hovered.border_color orelse t.color.accent, .{});
                } else {
                    const normal_bg = card.getBackground();
                    _ = try hooks.useHoverHighlight(my_scope, card, card, .background, normal_bg, hovered.background orelse t.color.bg_hover, .{});
                }
            } else {
                _ = try hooks.useHover(my_scope, card);
            }
        }

        // Header
        if (p.title != null or p.subtitle != null) {
            // 建好即挂：header 先进 card，子节点各自 adopt（append 失败自己收尸）
            const header = try core.adoptChild(cx, allocator, card, try box(cx, styles.cardHeaderStyle(t), .{}));

            if (p.title) |title_text| {
                const title_node = try core.adoptChild(cx, allocator, header, try box(cx, styles.cardTitleContainerStyle(t), .{}));
                var title_txt = styles.cardTitleText(t);
                title_txt.content = title_text;
                title_node.setText(title_txt);
            }

            if (p.subtitle) |s| {
                const subtitle_node = try core.adoptChild(cx, allocator, header, try box(cx, styles.cardSubtitleContainerStyle(t), .{}));
                var subtitle_txt = styles.cardSubtitleText(t);
                subtitle_txt.content = s;
                subtitle_node.setText(subtitle_txt);
            }
        }

        // Body container
        _ = try core.adoptChild(cx, allocator, card, try box(cx, styles.cardBodyStyle(p.padded), .{}));

        return card;
    }

    /// 保留模式: mount 返回 body 节点
    pub fn mountBody(self: CardBuilder, scope: *Scope, cx: *Cx) !struct { card: *Node, body: *Node } {
        const card = try self.mount(scope, cx);
        const body = card.children.items[card.children.items.len - 1];
        return .{ .card = card, .body = body };
    }
};

/// CardGrid - 卡片网格布局 props
pub const CardGridProps = struct {
    columns: u8 = 2,
    gap: f32 = 16,
    width: ?f32 = null,
};

/// 挂载 CardGrid：row + flex-wrap container。v0.5 推荐入口（取代
/// `CardGrid(props).build(cx)` Builder 链）。
pub fn mountCardGrid(props: CardGridProps, cx: *Cx) !*Node {
    var node = try box(cx, .{
        .width = if (props.width) |w| .{ .px = w } else .{ .grow = .{} },
        .direction = .row,
        .gap = props.gap,
    }, .{});
    node.meta.ownership.meta.component_name = "CardGrid";
    (try node.style.ensureExtFallible(cx.allocator)).flex_wrap = .wrap;
    return node;
}

// ========== 测试 ==========

test "Card: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try Card(.{})
        .title("Card Title")
        .subtitle("Description text")
        .width(300)
        .mountBody(scope, ctx);

    try root.appendChild(std.testing.allocator, result.card);

    // 应该有 header + body
    try std.testing.expectEqual(@as(usize, 2), result.card.children.items.len);
}

test "Card: outlined variant" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const card = try Card(.{})
        .variant(.outlined)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, card);

    // outlined 应该有边框
    try std.testing.expect(card.style.border.width > 0);
}

test "Card: selected state" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const card = try Card(.{})
        .selected(true)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, card);

    // selected 应该有高亮边框
    try std.testing.expectEqual(@as(f32, 2), card.style.border.width);
}

test "Card: interactive with click" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    var clicked = false;

    const card = try Card(.{ .width = 200, .height = 100 })
        .onClick(.{ .callback = struct {
            fn handler(c: *anyopaque) void {
                const ptr: *bool = @ptrCast(@alignCast(c));
                ptr.* = true;
            }
        }.handler, .context = &clicked })
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, card);

    // 模拟点击
    ctx.layout();
    ctx.handleClick(card.rectFromWorldOrFallback().x + 10, card.rectFromWorldOrFallback().y + 10);

    try std.testing.expect(clicked);

    // 可点的卡片必须键盘可达 + 对 AT 有角色（WCAG 2.1.1 / 4.1.2）
    try std.testing.expect(card.behavior.interaction.focusable);
    const a11y = card.behavior.interaction.a11y orelse
        return error.TestExpectedA11yProps;
    try std.testing.expectEqual(core.A11yRole.button, a11y.role);
}

test "Card: 非交互卡片不进 tab 序" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const card = try Card(.{ .width = 200, .height = 100 })
        .title("Static")
        .mount(scope, ctx);
    try root.appendChild(std.testing.allocator, card);

    // 纯展示卡片进 tab 序会给键盘用户制造空停靠点
    try std.testing.expect(!card.behavior.interaction.focusable);
}

test "CardGrid: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const grid = try mountCardGrid(.{ .columns = 2, .gap = 16 }, ctx);
    try root.appendChild(std.testing.allocator, grid);

    // 验证 wrap 设置
    try std.testing.expectEqual(core.FlexWrap.wrap, grid.style.flex_wrap());
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "card: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("card", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Card(.{ .title = "Title", .subtitle = "Sub", .interactive = true, .hoverable = true }).mount(scope, cx);
        }
    }.m);
}
