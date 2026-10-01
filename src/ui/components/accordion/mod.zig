/// Accordion / Collapsible Component
///
/// 可折叠面板组件，支持展开/折叠动画
///
/// 特性:
/// - AccordionItem: header 标题 + content 展开内容
/// - 点击 header 展开/折叠
/// - max_height 插值 + overflow_hidden 实现平滑折叠动画
/// - exclusive 模式: 一次只展开一个
/// - on_change 回调
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const Border = core.Border;
const ConditionalStyle = core.ConditionalStyle;
const hooks = @import("../../hooks.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const svg_assets = @import("../../svg_assets.zig");
const Scope = @import("../../reactive.zig").Scope;
const node_animator = @import("../../animation/node_animator.zig");
const recipe_mod = @import("../../recipe.zig");
const styles = @import("styles.zig");

// ============================================================================
// AccordionItemRecipe, recipe(variant) 统一 AccordionItem 样式
//
// variant 维度:
//   - default: 填充背景 + 圆角，无边框
//   - outline: 透明背景 + 1px 边框 + 圆角
//   - ghost:   完全透明，无边框无圆角
// ============================================================================

/// AccordionItem 变体
pub const AccordionVariant = enum {
    default,
    outline,
    ghost,
};

pub const AccordionItemRecipe = styles.AccordionItemRecipe;

// ==================== AccordionItem ====================

const Signal = core.Signal;

/// AccordionItem 内部状态
pub const AccordionItemState = struct {
    expanded: bool = false,
    /// 上一帧的 expanded（用于 before_render 检测变化）
    last_expanded: bool = false,
    /// 动画状态：idle -> measuring(展开需要测量) -> animating
    anim_phase: enum { idle, measure_expand, animating } = .idle,
    /// content 节点引用
    content_node: ?*Node = null,
    /// body 节点引用（用于直接读取 intrinsic 高度，避免展开时多等一帧测量）
    body_node: ?*Node = null,
    /// 容器节点引用（用于 markRenderDirty + border-color 动画）
    container_node: ?*Node = null,
    /// chevron 图标节点（通过 rotate 动画旋转：0° 折叠 -> 90° 展开）
    chevron_node: ?*Node = null,
    /// 标题文本节点（展开时 weight 600，折叠时 500）
    title_node: ?*Node = null,
    /// header 按钮节点（a11y expanded 挂在它身上）
    header_node: ?*Node = null,
    /// item 容器的 hover 信号（展开时 hover -> border 显现）
    item_hovered: ?*Signal(bool) = null,
    /// hover 时的 border 颜色
    hover_border_color: Color = Color.TRANSPARENT,
    /// 外部回调
    /// 2026-07-31 并轨：统一 ?core.HandlerRef，用 invokeWithBool 触发。
    on_change: ?core.HandlerRef = null,
    /// 所属 Accordion 的 exclusive 控制器（可选）
    group: ?*AccordionState = null,
    /// 在 group 中的索引
    group_index: usize = 0,
    /// 动画分配器（必须与节点的 allocator 一致，beforeRender 回调中使用）
    alloc: Allocator = std.heap.page_allocator,

    /// 切换展开/折叠
    pub fn toggle(self: *AccordionItemState) void {
        if (self.group) |group| {
            group.toggleItem(self.group_index);
        } else {
            self.setExpanded(!self.expanded);
        }
    }

    /// 设置展开状态
    pub fn setExpanded(self: *AccordionItemState, expanded: bool) void {
        if (self.expanded == expanded) return;
        self.expanded = expanded;

        // aria-expanded 是 accordion 唯一真正重要的状态位：没有它，AT 用户
        // 按下 header 后完全无从得知内容是展开了还是折叠了。此前 mount 只设
        // role=button，expanded 从头到尾没人写过。
        if (self.header_node) |header| {
            if (header.behavior.interaction.a11y) |*a| a.expanded = expanded;
        }

        // 展开时标题加粗 600，折叠时恢复 500
        if (self.title_node) |title| {
            if (title.getText()) |old| {
                var t = old;
                t.font_weight = if (expanded) 600 else 500;
                title.setText(t);
            }
        }

        if (self.on_change) |h| h.invokeWithBool(expanded);

        if (self.container_node) |node| {
            node.markRenderDirty();
        }
    }
};

/// AccordionItem 渲染前钩子：检测 expanded 变化 -> 发起 height 动画
fn accordionItemBeforeRender(node: *Node) void {
    const state: *AccordionItemState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    const content = state.content_node orelse return;
    const alloc = state.alloc;

    // 0. hover -> item 容器 border 显现（直接切换，无过渡）
    if (state.item_hovered) |hovered_sig| {
        node.style.border.color = if (hovered_sig.get()) state.hover_border_color else Color.TRANSPARENT;
    }

    // 1. 检测 expanded 状态变化
    if (state.expanded != state.last_expanded) {
        state.last_expanded = state.expanded;

        // chevron rotate 动画：折叠 0° -> 展开 π/2
        if (state.chevron_node) |chevron| {
            const target_rotate: f32 = if (state.expanded) std.math.pi / 2.0 else 0.0;
            const from_rotate: f32 = if (state.expanded) 0.0 else std.math.pi / 2.0;
            node_animator.animateNode(chevron, alloc, .{
                .prop = .rotate,
                .from = from_rotate,
                .to = target_rotate,
                .duration = 0.2,
                .easing = .ease_in_out_cubic,
            });
        }

        if (state.expanded) {
            const target_h = blk: {
                if (state.body_node) |body| {
                    const bh = body.rectFromWorldOrFallback().h;
                    if (bh > 0) break :blk bh;
                }
                break :blk 0;
            };

            if (target_h > 0) {
                content.style.height = .{ .px = 0 };
                content.style.overflow_hidden = true;
                content.markLayoutDirty();

                node_animator.animateNode(content, alloc, .{
                    .prop = .height,
                    .from = 0,
                    .to = target_h,
                    .duration = 0.32,
                    .easing = .ease_in_out_cubic,
                    .on_complete = expandComplete,
                    .on_complete_ctx = @ptrCast(state),
                });
                state.anim_phase = .animating;
            } else {
                // fallback：先设 height=.fit + overflow_hidden 让布局引擎计算真实高度
                // 下一帧（measure_expand）再读取并发起动画
                content.style.height = .{ .fit = .{} };
                content.style.overflow_hidden = true;
                content.markLayoutDirty();
                state.anim_phase = .measure_expand;
                node.markRenderDirty();
            }
        } else {
            // 折叠：直接从当前高度动画到 0
            const current_h = content.rectFromWorldOrFallback().h;
            content.style.height = .{ .px = current_h };
            content.style.overflow_hidden = true;
            content.markLayoutDirty();

            node_animator.animateNode(content, alloc, .{
                .prop = .height,
                .from = current_h,
                .to = 0,
                .duration = 0.2,
                .easing = .ease_out_cubic,
                .on_complete = collapseComplete,
                .on_complete_ctx = @ptrCast(state),
            });
            state.anim_phase = .animating;
        }
        return;
    }

    // 2. 展开测量帧：读取布局后的真实高度，发起 0 -> realHeight 动画
    if (state.anim_phase == .measure_expand) {
        const real_h = content.rectFromWorldOrFallback().h;
        if (real_h > 0) {
            // 拿到真实高度，从 0 开始动画
            content.style.height = .{ .px = 0 };
            content.markLayoutDirty();

            node_animator.animateNode(content, alloc, .{
                .prop = .height,
                .from = 0,
                .to = real_h,
                .duration = 0.32,
                .easing = .ease_in_out_cubic,
                .on_complete = expandComplete,
                .on_complete_ctx = @ptrCast(state),
            });
            state.anim_phase = .animating;
        } else {
            // 还没布局完，等下一帧
            node.markRenderDirty();
        }
        return;
    }

    // 3. 动画进行中持续刷新
    if (state.anim_phase == .animating) {
        if (content.frame_state.frame_local.runtime.commands) |anims| {
            if (anims.count > 0) {
                node.markRenderDirty();
            } else {
                state.anim_phase = .idle;
            }
        } else {
            state.anim_phase = .idle;
        }
    }
}

/// 展开动画完成：切回 height=.fit 让内容自由伸缩
fn expandComplete(ctx: *anyopaque) void {
    const state: *AccordionItemState = @ptrCast(@alignCast(ctx));
    if (state.content_node) |content| {
        content.style.height = .{ .fit = .{} };
        content.style.overflow_hidden = false;
        content.markSizingDirty();
    }
    state.anim_phase = .idle;
}

/// 折叠动画完成：保持 height=0 + overflow_hidden
fn collapseComplete(ctx: *anyopaque) void {
    const state: *AccordionItemState = @ptrCast(@alignCast(ctx));
    if (state.content_node) |content| {
        content.style.height = .{ .px = 0 };
        content.style.overflow_hidden = true;
        content.markSizingDirty();
    }
    state.anim_phase = .idle;
}

/// AccordionItem 点击事件处理器
fn accordionItemClickHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *AccordionItemState = @ptrCast(@alignCast(context orelse return .ignored));

    switch (event) {
        .click => {
            state.toggle();
            return .handled;
        },
        .key_down => |e| {
            if (e.key == .space or e.key == .@"return") {
                state.toggle();
                return .handled;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

/// AccordionItem 属性
pub const AccordionItemProps = struct {
    /// 标题文本
    title: []const u8 = "",
    /// 初始展开状态
    expanded: bool = false,
    /// 视觉变体
    variant: AccordionVariant = .default,
    /// 展开/折叠回调
    on_change: ?core.HandlerRef = null,
    /// 回调上下文
    context: ?*anyopaque = null,
    /// Chevron 图标（可选，默认用文本 ">"）
    chevron_asset: ?svg_assets.Asset = null,
};

/// 创建 AccordionItem
pub fn AccordionItem(props: AccordionItemProps) AccordionItemBuilder {
    return AccordionItemBuilder{ .props = props };
}

/// AccordionItemBuilder.mount 的返回结果
pub const AccordionItemResult = struct { item: *Node, body: *Node };

pub const AccordionItemBuilder = struct {
    props: AccordionItemProps,

    pub fn title(self: AccordionItemBuilder, t: []const u8) AccordionItemBuilder {
        var new = self;
        new.props.title = t;
        return new;
    }

    pub fn expanded(self: AccordionItemBuilder, e: bool) AccordionItemBuilder {
        var new = self;
        new.props.expanded = e;
        return new;
    }

    pub fn variant(self: AccordionItemBuilder, v: AccordionVariant) AccordionItemBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    pub fn onChange(self: AccordionItemBuilder, handler_ref: core.HandlerRef) AccordionItemBuilder {
        var new = self;
        new.props.on_change = handler_ref;
        return new;
    }

    /// 保留模式: mount，返回 { item 根节点, content body 节点 }
    pub fn mount(self: AccordionItemBuilder, scope: *Scope, cx: *Cx) !AccordionItemResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // === Recipe resolve ===
        const item_cs = AccordionItemRecipe.resolve(.{ .variant = p.variant }, t);
        const item_resolved = item_cs.resolve(.{});

        const item_bg = item_resolved.background orelse Color.TRANSPARENT;
        const border_color = styles.accordionHoverBorderColor(item_bg, t);

        // 分配内部状态
        const state = try my_scope.allocator.create(AccordionItemState);
        state.* = .{
            .expanded = p.expanded,
            .last_expanded = p.expanded,
            .on_change = p.on_change,
            .hover_border_color = border_color,
            .alloc = allocator,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const s: *AccordionItemState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);

        // 外层容器（纵向排列: header + content），样式由 Recipe variant 决定
        const item = try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .column,
            .background = item_bg,
        }, .{});
        // sweep：item 守卫一直武装到 return；可失败函数里不用 ensureExtPanic（sweep 实测直接 abort）
        errdefer cx.freeNode(item);
        // 圆角 + 边框从 recipe 提取（border 初始透明，hover 时通过 transition 显现）
        const item_radius = item_resolved.corner_radius orelse 0;
        if (item_radius > 0) {
            (try item.style.ensureExtFallible(allocator)).corner_radius = .{ .all = item_radius };
        }
        item.style.border.color = Color.TRANSPARENT;
        item.style.border.width = 1;
        if (item_resolved.border) |b| {
            item.style.border.radius = b.radius;
        } else if (item_radius > 0) {
            item.style.border.radius = item_radius;
        }
        const item_hovered = try hooks.useHover(my_scope, item);
        state.item_hovered = item_hovered;

        item.meta.ownership.meta.component_name = "AccordionItem";
        try core.bindScopeToNode(my_scope, item);
        state.container_node = item;

        // === Header（可点击） ===
        const header = try core.adoptChild(cx, allocator, item, try box(cx, styles.accordionHeaderStyle(t), .{}));
        header.tag = .button;
        header.setFocusable(true);
        header.behavior.interaction.a11y = .{
            .role = .button,
            .label = p.title,
            .expanded = p.expanded,
        };
        state.header_node = header;

        // Chevron 指示器（直接以图标自身中心为轴旋转）
        const chevron = try core.adoptChild(cx, allocator, header, try core.iconTint(cx, p.chevron_asset orelse svg_assets.common.chevron_right, t.color.fg_secondary, .{
            .width = .{ .px = styles.accordion_chevron_size },
            .height = .{ .px = styles.accordion_chevron_size },
        }));
        const chevron_ext = try chevron.style.ensureExtFallible(allocator);
        chevron_ext.transform_origin = core.TransformOrigin.centered();
        chevron_ext.will_change_transform = true;
        if (p.expanded) {
            chevron_ext.rotate = std.math.pi / 2.0;
        }
        chevron.setHitTestVisible(false);
        state.chevron_node = chevron;

        // 标题文本
        const title_node = try core.adoptChild(cx, allocator, header, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
        }, .{}));
        var title_txt = styles.accordionTitleText(p.expanded, t);
        title_txt.content = p.title;
        title_node.setText(title_txt);
        title_node.setHitTestVisible(false);
        title_node.behavior.events.event_context = state;
        title_node.behavior.events.on_event = accordionItemClickHandler;
        state.title_node = title_node;

        // Header 交互（header 不响应 hover 背景变化，border 由 item 容器统一管理）
        header.behavior.events.event_context = state;
        header.behavior.events.on_event = accordionItemClickHandler;
        try hooks.useFocusRing(my_scope, cx, header, .{});

        // === Content 容器（overflow_hidden + height 动画） ===
        const content = try core.adoptChild(cx, allocator, item, try box(cx, .{
            .width = .{ .grow = .{} },
            .direction = .column,
        }, .{}));
        content.style.height = if (p.expanded) .{ .fit = .{} } else .{ .px = 0 };
        content.style.overflow_hidden = !p.expanded;
        state.content_node = content;
        // 展开态的唯一可观测出口：折叠时 height 被设成 0，展开时是 fit。
        // body 子节点的 rect.h 是内容高度、不随折叠变化（裁剪发生在渲染阶段，
        // 不改 layout rect），所以 e2e 必须看这一层。
        content.meta.ownership.meta.test_id = "accordion.content";

        // 内容 body，左缩进合同见 accordionBodyStyle
        const body = try core.adoptChild(cx, allocator, content, try box(cx, styles.accordionBodyStyle(t), .{}));
        state.body_node = body;

        // 设置 on_before_render 动画（必须在 useFocusRing 之后，因为它会链式保存）
        item.behavior.events.event_context = state;
        item.meta.per_frame.hooks.before_render.main = accordionItemBeforeRender;

        return .{ .item = item, .body = body };
    }
};

// ==================== Accordion (容器) ====================

/// Accordion 内部状态（管理 exclusive 模式）
pub const AccordionState = struct {
    items: [MAX_ITEMS]?*AccordionItemState = [_]?*AccordionItemState{null} ** MAX_ITEMS,
    count: usize = 0,
    exclusive: bool = false,

    const MAX_ITEMS = 16;

    /// 注册一个 item
    pub fn registerItem(self: *AccordionState, item_state: *AccordionItemState) void {
        if (self.count >= MAX_ITEMS) return;
        item_state.group = self;
        item_state.group_index = self.count;
        self.items[self.count] = item_state;
        self.count += 1;
    }

    /// exclusive 模式下切换某个 item
    pub fn toggleItem(self: *AccordionState, index: usize) void {
        if (index >= self.count) return;
        const target = self.items[index] orelse return;

        if (self.exclusive) {
            // 先折叠所有其他
            for (self.items[0..self.count]) |maybe_item| {
                if (maybe_item) |item| {
                    if (item != target and item.expanded) {
                        item.setExpanded(false);
                    }
                }
            }
        }
        // 切换目标
        target.setExpanded(!target.expanded);
    }
};

/// Accordion 属性
pub const AccordionProps = struct {
    /// exclusive 模式: 一次只展开一个
    exclusive: bool = false,
    /// 间距
    gap: f32 = 8,
};

/// 创建 Accordion
pub fn Accordion(props: AccordionProps) AccordionBuilder {
    return AccordionBuilder{ .props = props };
}

/// AccordionBuilder.mount 的返回结果
pub const AccordionResult = struct { container: *Node, state: *AccordionState };

pub const AccordionBuilder = struct {
    props: AccordionProps,

    pub fn exclusive(self: AccordionBuilder, e: bool) AccordionBuilder {
        var new = self;
        new.props.exclusive = e;
        return new;
    }

    pub fn gap(self: AccordionBuilder, g: f32) AccordionBuilder {
        var new = self;
        new.props.gap = g;
        return new;
    }

    /// 保留模式: mount，返回 { container 节点, AccordionState }
    pub fn mount(self: AccordionBuilder, scope: *Scope, cx: *Cx) !AccordionResult {
        const my_scope = try scope.childScope();
        const p = self.props;

        // 分配 group 状态
        const state = try my_scope.allocator.create(AccordionState);
        state.* = .{ .exclusive = p.exclusive };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const s: *AccordionState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);

        const container = try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .column,
            .gap = p.gap,
        }, .{});
        container.meta.ownership.meta.component_name = "Accordion";
        try core.bindScopeToNode(my_scope, container);

        return .{ .container = container, .state = state };
    }
};

// ========== 测试 ==========

test "AccordionItem: basic collapsed" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try AccordionItem(.{})
        .title("Section 1")
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.item);

    // item 有 2 个子节点: header + content
    try std.testing.expectEqual(@as(usize, 2), result.item.children.items.len);
    // 折叠: content height=0, overflow_hidden=true
    const content = result.item.children.items[1];
    try std.testing.expectEqual(core.Sizing{ .px = 0 }, content.style.height);
    try std.testing.expect(content.style.overflow_hidden);
}

test "AccordionItem: expanded" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try AccordionItem(.{})
        .title("Section 1")
        .expanded(true)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.item);

    // 展开: content height=.fit, overflow_hidden=false
    const content = result.item.children.items[1];
    try std.testing.expectEqual(core.Sizing{ .fit = .{} }, content.style.height);
    try std.testing.expect(!content.style.overflow_hidden);

    const header = result.item.children.items[0];
    const chevron = header.children.items[0];
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, chevron.style.rotate(), 0.0001);
}

test "AccordionItem: state toggle" {
    var state = AccordionItemState{ .expanded = false };

    state.setExpanded(true);
    try std.testing.expect(state.expanded);

    state.setExpanded(false);
    try std.testing.expect(!state.expanded);
}

test "AccordionItem: toggle callback" {
    const CallbackCtx = struct {
        last_value: bool = false,
        call_count: u32 = 0,
    };

    var cb_ctx = CallbackCtx{};

    var state = AccordionItemState{
        .expanded = false,
        .on_change = core.Cx.boolHandlerFrom(CallbackCtx, &cb_ctx, struct {
            fn handler(c: *CallbackCtx, new_val: bool) void {
                c.last_value = new_val;
                c.call_count += 1;
            }
        }.handler),
    };

    state.setExpanded(true);
    try std.testing.expect(cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 1), cb_ctx.call_count);
}

test "AccordionItem: expand uses body intrinsic height when available" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();
    ctx.setViewport(480, 320);

    const root = try box(ctx, .{
        .width = .{ .px = 480 },
        .height = .{ .px = 320 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try AccordionItem(.{})
        .title("Section 1")
        .mount(scope, ctx);
    try root.appendChild(alloc, result.item);

    const body_text = try box(ctx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
    }, .{});
    body_text.setText(.{ .content = "Expandable content", .font_size = 13, .color = ctx.tokens.color.fg_secondary });
    try result.body.appendChild(alloc, body_text);

    ctx.layout();

    const state: *AccordionItemState = @ptrCast(@alignCast(result.item.behavior.events.event_context.?));
    try std.testing.expect(state.body_node != null);
    try std.testing.expect(state.body_node.?.rectFromWorldOrFallback().h > 0);

    state.setExpanded(true);
    if (result.item.meta.per_frame.hooks.before_render.main) |hook| {
        hook(result.item);
    }

    try std.testing.expectEqual(@TypeOf(state.anim_phase).animating, state.anim_phase);
    try std.testing.expect(state.content_node.?.frame_state.frame_local.runtime.commands != null);
}

test "Accordion: exclusive mode" {
    var group = AccordionState{ .exclusive = true };
    var item_a = AccordionItemState{};
    var item_b = AccordionItemState{};

    group.registerItem(&item_a);
    group.registerItem(&item_b);

    // 展开 A
    group.toggleItem(0);
    try std.testing.expect(item_a.expanded);
    try std.testing.expect(!item_b.expanded);

    // 展开 B -> A 应自动折叠
    group.toggleItem(1);
    try std.testing.expect(!item_a.expanded);
    try std.testing.expect(item_b.expanded);

    // 再次点击 B -> B 折叠
    group.toggleItem(1);
    try std.testing.expect(!item_b.expanded);
}

test "Accordion: non-exclusive mode" {
    var group = AccordionState{ .exclusive = false };
    var item_a = AccordionItemState{};
    var item_b = AccordionItemState{};

    group.registerItem(&item_a);
    group.registerItem(&item_b);

    group.toggleItem(0);
    group.toggleItem(1);

    // 两个都应展开
    try std.testing.expect(item_a.expanded);
    try std.testing.expect(item_b.expanded);
}

test "Accordion: hit-test follows layout after a sibling expands (regression)" {
    // 复现用户报的 bug：展开上方 item 把下方 item 往下推之后，对下方 item header
    // 的点击应命中下方 item（hit-test 用新布局），而不是旧布局里那个位置的节点。
    const render_engine = @import("../../core/render_engine/mod.zig");
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();
    ctx.setViewport(600, 400);

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 }, .direction = .column }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const acc = try Accordion(.{ .exclusive = false, .gap = 8 }).mount(scope, ctx);
    try root.appendChild(alloc, acc.container);

    // 对齐 storybook 场景：item 0 初始 expanded（mount 时经动画展开）。
    var items: [3]*Node = undefined;
    inline for (.{ "Section One", "Section Two", "Section Three" }, 0..) |title, i| {
        const it = try AccordionItem(.{ .title = title, .expanded = (i == 0) }).mount(scope, ctx);
        const body_text = try box(ctx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{});
        body_text.setText(.{ .content = "Panel body content.", .font_size = 13, .color = ctx.tokens.color.fg_secondary });
        try it.body.appendChild(alloc, body_text);
        try acc.container.appendChild(alloc, it.item);
        items[i] = it.item;
    }

    // settle 初始布局 + item0 的 mount 展开动画（多帧）。
    var t: f64 = 0;
    var warm: usize = 0;
    while (warm < 60) : (warm += 1) {
        t += 16;
        render_engine.current_frame_time_ms = t;
        ctx.frame_time_ms = t;
        ctx.layout();
        _ = ctx.render();
    }

    // 初始展开 settle 后，三个 header 各自当前位置都应命中对应 item（基线：还没点过）。
    inline for (.{ 0, 1, 2 }) |idx| {
        const hdr0 = items[idx].children.items[0];
        const hr0 = hdr0.globalRect();
        const h0 = ctx.hitTest(hr0.x + hr0.w * 0.5, hr0.y + hr0.h * 0.5);
        try std.testing.expect(nodeIsInSubtree(h0, items[idx]));
    }

    // 记录三个 item header 的初始顶部 y（header 是 item.children[0]）。
    const header2_y0 = items[2].children.items[0].globalRect().y;

    // 展开 Section Two（item 1）-> 触发高度动画，把 Section Three 往下推。
    const state1: *AccordionItemState = @ptrCast(@alignCast(items[1].behavior.events.event_context.?));
    state1.setExpanded(true);

    // 跑足够多帧让展开动画 + 收尾（expandComplete -> height=.fit）settle。
    var frame: usize = 0;
    while (frame < 60) : (frame += 1) {
        t += 16;
        render_engine.current_frame_time_ms = t;
        ctx.frame_time_ms = t;
        ctx.layout();
        _ = ctx.render();
    }

    // Section Three header 现在应该被推到更下方。
    const header2 = items[2].children.items[0];
    const r2 = header2.globalRect();
    try std.testing.expect(r2.y > header2_y0 + 10); // 确实下移了

    // 关键断言：在 Section Three header 的**新**位置做 hit-test，必须命中它
    // （或它的子节点 / 它自己）。旧布局 bug 下这里会命中别的 item 或空。
    const hit = ctx.hitTest(r2.x + r2.w * 0.5, r2.y + r2.h * 0.5);
    try std.testing.expect(hit != null);
    try std.testing.expect(nodeIsInSubtree(hit, items[2]));

    // 全覆盖：展开 Section Two 后，三个 header 各自当前位置的 hit-test 都必须命中
    // **对应**的 item（防止 off-by-one：点 item1 header 却命中 item2 之类）。
    inline for (.{ 0, 1, 2 }) |idx| {
        const hdr = items[idx].children.items[0];
        const hr = hdr.globalRect();
        const h = ctx.hitTest(hr.x + hr.w * 0.5, hr.y + hr.h * 0.5);
        try std.testing.expect(h != null);
        try std.testing.expect(nodeIsInSubtree(h, items[idx]));
    }
}

fn nodeIsInSubtree(node: ?*Node, ancestor: *Node) bool {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur == ancestor) return true;
    }
    return false;
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "accordion_item: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("accordion_item", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try AccordionItem(.{ .title = "Section", .expanded = true }).mount(scope, cx);
            return r.item;
        }
    }.m);
}
