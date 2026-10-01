/// Tabs Component
///
/// 标签页组件，支持多种变体和键盘导航
///
/// 特性:
/// - 状态管理: 通过 Scope 分配 TabsState，on_before_render 脏检测更新
/// - 事件驱动: 通过 on_event 处理 click 事件切换 Tab
/// - 焦点支持: 可聚焦, 键盘左右切换
/// - 变体: underline, pill, icon (× size: sm, md)
/// - icon 变体支持 Lucide SVG 图标
/// - 可关闭标签
/// - on_change / on_close 回调
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const hooks = @import("../../hooks.zig");
const Scope = @import("../../reactive.zig").Scope;
const ConditionalStyle = core.ConditionalStyle;
const StyleOverride = core.StyleOverride;
const recipe_mod = @import("../../recipe.zig");
const svg_assets = @import("../../svg_assets.zig");

// ============================================================================
// 类型定义
// ============================================================================

/// Tabs 变体
pub const TabsVariant = enum {
    underline,
    pill,
    tab,
};

/// Tabs 尺寸，统一使用 ControlSize 4 档
pub const TabsSize = theme.ControlSize;

/// Tab 项目
pub const TabItem = struct {
    id: []const u8,
    label_text: []const u8,
    icon_asset: ?svg_assets.Asset = null,
    disabled: bool = false,
    closable: bool = false,
    badge: ?u32 = null,
};

// 样式层（TabsSlotRecipe + variant×size spec 表 + EditorTabs 样式函数）
// 析出至 styles.zig；重导出保持公共 API 不变。
const styles = @import("styles.zig");
pub const TabsSlotRecipe = styles.TabsSlotRecipe;

// ============================================================================
// TabsState，内部状态
// ============================================================================

pub const TabsState = struct {
    active_index: usize = 0,
    tab_count: usize = 0,

    /// 2026-07-31 并轨：统一 ?core.HandlerRef，用 invokeWithStr 触发
    /// （payload = tab id）。
    on_change: ?core.HandlerRef = null,
    on_close: ?core.HandlerRef = null,

    tab_ids: [32]?[]const u8 = [_]?[]const u8{null} ** 32,

    pub fn setActive(self: *TabsState, index: usize) void {
        if (index >= self.tab_count) return;
        if (index == self.active_index) return;

        self.active_index = index;

        if (self.on_change) |h| {
            if (self.tab_ids[index]) |id| h.invokeWithStr(id);
        }
    }

    pub fn moveNext(self: *TabsState) void {
        if (self.tab_count == 0) return;
        const next = (self.active_index + 1) % self.tab_count;
        self.setActive(next);
    }

    pub fn movePrev(self: *TabsState) void {
        if (self.tab_count == 0) return;
        const prev = if (self.active_index == 0) self.tab_count - 1 else self.active_index - 1;
        self.setActive(prev);
    }

    pub fn getActiveId(self: *const TabsState) ?[]const u8 {
        if (self.active_index < self.tab_count) {
            return self.tab_ids[self.active_index];
        }
        return null;
    }
};

/// 每个 Tab 的点击上下文
pub const TabClickContext = struct {
    tabs_state: *TabsState,
    tab_index: usize,
    tab_row: *Node,
};

/// Tabs on_before_render 渲染上下文
const TabsRenderContext = struct {
    state: *TabsState,
    variant: TabsVariant,
    size: TabsSize,
    tokens: *const theme.ThemeTokens,
    allocator: Allocator,
    item_count: usize,
    has_icons: bool,
    highlight_box: *Node,
    last_rendered_index: usize = std.math.maxInt(usize), // 首帧 highlight 定位需要
    first_render: bool = true, // 首帧跳过 transition 动画，直接定位
};

// ============================================================================
// tabsBeforeRender, highlight box + 文字样式更新
// ============================================================================

/// 更新 tab 后代节点的文字颜色、图标 tint 和 font_weight
fn updateTabDescendants(parent: *Node, text_color: Color, icon_tint: Color, is_active: bool) void {
    const target_weight: u16 = if (is_active) 600 else 500;
    for (parent.children.items) |child| {
        _ = child.setTint(icon_tint);
        // label_wrapper: [ghost, real_text]
        if (child.children.items.len == 2) {
            const real_text = child.children.items[1];
            if (real_text.getText()) |old| {
                var txt = old;
                txt.color = text_color;
                txt.font_weight = target_weight;
                real_text.setText(txt);
            }
        }
    }
}

fn sizingPxValue(sizing: core.Sizing) ?f32 {
    return switch (sizing) {
        .px => |v| v,
        else => null,
    };
}

fn tabsBeforeRender(node: *Node) void {
    const render_ctx: *TabsRenderContext = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    const state = render_ctx.state;
    const t = render_ctx.tokens;
    const v = render_ctx.variant;
    const s = render_ctx.size;

    const hbox = render_ctx.highlight_box;
    const children = node.children.items;

    // ---- 1. 每帧更新 highlight box 位置/大小（依赖上一帧 layout rect） ----
    // 用 translate_x 做水平位移（支持 transition 动画），margin.top 做垂直定位
    if (children.len > 1 and state.active_index + 1 < children.len) {
        const active_tab = children[state.active_index + 1];
        const tab_rect = active_tab.rectFromWorldOrFallback();

        if (tab_rect.w > 0) {
            var layout_changed = false;
            if (render_ctx.first_render) {
                // 首帧：立即定位、同步 slot、不触发动画（snapTransition 统一处理，
                // 组件不再直接改写引擎 transition slot 内部状态）。
                render_ctx.first_render = false;
                hbox.snapTransition(render_ctx.allocator, .width, tab_rect.w);
                hbox.snapTransition(render_ctx.allocator, .translate_x, tab_rect.x);
            } else {
                hbox.setWidth(tab_rect.w);
                // translate_x 做水平动画位移
                hbox.setTranslateX(tab_rect.x);
            }
            switch (v) {
                .underline => {
                    const old_h = sizingPxValue(hbox.style.height);
                    // 全局 hook 读 rect。
                    const r = node.rectFromWorldOrFallback();
                    const row_h = r.h;
                    const new_margin = row_h - 2;
                    hbox.style.height = .{ .px = 2 };
                    hbox.setMarginTop(new_margin);
                    layout_changed = layout_changed or old_h == null or old_h.? != 2;
                },
                .pill, .tab => {
                    const old_h = sizingPxValue(hbox.style.height);
                    hbox.style.height = .{ .px = tab_rect.h };
                    hbox.setMarginTop(tab_rect.y);
                    layout_changed = layout_changed or old_h == null or old_h.? != tab_rect.h;
                },
            }
            if (layout_changed) hbox.markLayoutDirty();
        }
    }

    // ---- 2. 文字颜色 + font_weight 仅在 active_index 变化时更新 ----
    if (state.active_index != render_ctx.last_rendered_index) {
        render_ctx.last_rendered_index = state.active_index;

        const slots = TabsSlotRecipe.resolve(.{ .variant = v, .size = s }, t);
        const tab_style = slots.tab.resolve(.{});
        const active_style = slots.tab.resolve(.{ .is_selected = true });

        const tab_start: usize = 1;
        const tab_end = @min(children.len, render_ctx.item_count + 1);

        for (children[tab_start..tab_end], 0..) |tab_node, i| {
            const is_active = (i == state.active_index);
            const is_disabled = (tab_node.behavior.events.on_event == null);
            const resolved = if (is_active) active_style else tab_style;

            // aria-selected 必须跟着 active_index 走：VoiceOver 在 tablist 里
            // 靠 selected 位判断"当前是第几个标签页"，只在 mount 写一次的话
            // 切页后播报的永远是初始那一个。注意这里放在 is_disabled 判断
            // 之外，禁用的 tab 同样需要正确的 selected 位。
            if (tab_node.behavior.interaction.a11y) |*a| a.selected = is_active;

            if (!is_disabled) {
                const text_color = resolved.text_color orelse t.color.fg_secondary;
                const icon_tint = if (is_active and v == .tab) t.color.accent else t.color.fg_secondary;
                updateTabDescendants(tab_node, text_color, icon_tint, is_active);
            }
        }
    }
}

/// Tab 点击事件处理器
fn tabClickHandler(event: Event, context: ?*anyopaque) EventResult {
    const click_ctx: *TabClickContext = @ptrCast(@alignCast(context orelse return .ignored));

    // before_render hook 本就在事件之后、本帧渲染前由引擎统一执行；这里只需
    // 请求重绘（历史上手动调 hook 是 hook 时序不稳时代的补丁）。
    const syncVisuals = struct {
        fn run(tab_row: *Node) void {
            tab_row.markRenderDirty();
        }
    }.run;

    switch (event) {
        .click => {
            click_ctx.tabs_state.setActive(click_ctx.tab_index);
            syncVisuals(click_ctx.tab_row);
            return .handled;
        },
        .key_down => |e| {
            if (e.key == .left) {
                click_ctx.tabs_state.movePrev();
                syncVisuals(click_ctx.tab_row);
                return .handled;
            } else if (e.key == .right) {
                click_ctx.tabs_state.moveNext();
                syncVisuals(click_ctx.tab_row);
                return .handled;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

/// 方向键切换：挂在可聚焦的 container 上（焦点在 container，tab_node 不可聚焦，
/// 键盘事件从焦点节点向上冒泡，永远到不了 tab_node 的 on_event）。
fn tabsKeyDown(key: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
    const ctx: *TabClickContext = @ptrCast(@alignCast(context orelse return .ignored));
    switch (key) {
        .left => ctx.tabs_state.movePrev(),
        .right => ctx.tabs_state.moveNext(),
        else => return .ignored,
    }
    ctx.tab_row.markRenderDirty();
    return .handled;
}

/// 关闭按钮：触发 on_close(tab id)，并 stop 冒泡，否则点 × 会冒泡到 tab_node 把它激活。
fn tabCloseHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *TabClickContext = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .click => {
            if (ctx.tabs_state.on_close) |h| {
                if (ctx.tab_index < ctx.tabs_state.tab_ids.len) {
                    if (ctx.tabs_state.tab_ids[ctx.tab_index]) |id| h.invokeWithStr(id);
                }
            }
            return .stop;
        },
        else => return .ignored,
    }
}

// ============================================================================
// Tabs 属性 + Builder + mount
// ============================================================================

pub const TabsProps = struct {
    items: []const TabItem,
    active_id: ?[]const u8 = null,
    default_active_id: ?[]const u8 = null,
    variant: TabsVariant = .underline,
    size: TabsSize = .md,
    closable: bool = false,
    /// 2026-07-31 并轨：统一 ?core.HandlerRef，用 invokeWithStr 触发
    /// （payload = tab id）。
    on_change: ?core.HandlerRef = null,
    on_close: ?core.HandlerRef = null,
    context: ?*anyopaque = null,
    state_id: ?u64 = null,
};

pub fn Tabs(props: TabsProps) TabsBuilder {
    return TabsBuilder{ .props = props };
}

pub const TabsBuilder = struct {
    props: TabsProps,

    pub fn variant(self: TabsBuilder, v: TabsVariant) TabsBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    pub fn size(self: TabsBuilder, s: TabsSize) TabsBuilder {
        var new = self;
        new.props.size = s;
        return new;
    }

    pub fn closable(self: TabsBuilder, c: bool) TabsBuilder {
        var new = self;
        new.props.closable = c;
        return new;
    }

    pub fn onChange(self: TabsBuilder, handler_ref: core.HandlerRef) TabsBuilder {
        var new = self;
        new.props.on_change = handler_ref;
        return new;
    }

    pub fn onClose(self: TabsBuilder, handler_ref: core.HandlerRef) TabsBuilder {
        var new = self;
        new.props.on_close = handler_ref;
        return new;
    }

    pub fn mount(self: TabsBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        // 绑定成功之前 my_scope 无人持有；绑定之后由 container 的守卫接手
        // （freeNode 会顺带 dispose 绑定的 scope）。
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Scope 分配 TabsState
        const state = try my_scope.allocator.create(TabsState);
        // 到下面 registerResource 之前 state 无人持有,
        // my_scope.allocator 不是 arena，dispose 只释放已登记的资源。
        // 中间的 blk 初始化与 signal 创建都可失败（sidebar sweep index 27 实测）。
        var state_registered = false;
        errdefer if (!state_registered) my_scope.allocator.destroy(state);
        state.* = blk: {
            var initial = TabsState{};
            initial.tab_count = @min(p.items.len, 32);
            for (p.items, 0..) |item, i| {
                if (i >= 32) break;
                initial.tab_ids[i] = item.id;
            }
            const default_id = p.default_active_id orelse
                (if (p.items.len > 0) p.items[0].id else null);
            if (default_id) |did| {
                for (p.items, 0..) |item, i| {
                    if (i >= 32) break;
                    if (std.mem.eql(u8, item.id, did)) {
                        initial.active_index = i;
                        break;
                    }
                }
            }
            break :blk initial;
        };
        try my_scope.registerResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *TabsState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);
        state_registered = true;

        state.on_change = p.on_change;
        state.on_close = p.on_close;

        if (p.active_id) |aid| {
            for (p.items, 0..) |item, i| {
                if (std.mem.eql(u8, item.id, aid)) {
                    state.active_index = i;
                    break;
                }
            }
        }

        // SlotRecipe resolve
        const slots = TabsSlotRecipe.resolve(.{ .variant = p.variant, .size = p.size }, t);
        const root_resolved = slots.root.resolve(.{});

        // 检测是否有 icon
        var has_icons = false;
        for (p.items) |item| {
            if (item.icon_asset != null) {
                has_icons = true;
                break;
            }
        }

        const is_underline = p.variant == .underline;

        // tab_row: 所有 tab + highlight_box 的行容器，几何/背景全部来自 root slot
        const tab_row = try box(cx, .{
            .position = .relative,
            .direction = .row,
            .gap = root_resolved.gap,
            .padding = root_resolved.padding,
            .align_items = .center,
        }, .{});

        // tab_row 直到下面才被 container 收走（underline 分支还要再包一层），
        // 中间 ensureExtFallible / highlight_box / applyTransition 都可失败。
        var tab_row_owned = true;
        errdefer if (tab_row_owned) cx.freeNode(tab_row);
        if (root_resolved.background) |bg| tab_row.setBackgroundRaw(bg);
        if (root_resolved.corner_radius) |cr| {
            if (cr > 0) {
                (try tab_row.style.ensureExtFallible(allocator)).corner_radius = .{ .all = cr };
            }
        }

        // ---- highlight_box: absolute 定位，跟随 active tab ----
        // 外观（背景/阴影/圆角/underline 的 2px 高度）全部来自 highlight slot；
        // 宽度与位移是运行时几何，由 tabsBeforeRender 每帧驱动。
        var hl_style = slots.highlight.resolve(.{});
        hl_style.position = .absolute;
        // 建好即挂：applyTransition 会分配，挂在前面窗口就不存在。
        // highlight_box 作为 tab_row 的第一个子节点（index 0）
        const highlight_box = try adoptTabChild(cx, allocator, tab_row, try box(cx, hl_style, .{}));
        // 选中态的唯一可观测出口：它的 translate_x 指向当前 active tab。
        // e2e 要断言「点击真的切换了视觉选中态」，只靠 on_change 回调不够,
        // setActive 的去重守卫会让 active_index 坏掉时回调照常触发。
        highlight_box.meta.ownership.meta.test_id = "tabs.highlight";
        highlight_box.meta.ownership.meta.component_name = "TabHighlight";
        // translate_x transition: 弹簧般的滑动动画
        highlight_box.applyTransition(allocator, &comptime recipe_mod.transition("translate-x 150ms ease-out, width 150ms ease-out"));

        // outer_container: underline 时包裹 column { tab_row, separator }
        const container = if (is_underline) blk: {
            const outer = try box(cx, .{
                .direction = .column,
            }, .{});
            {
                // outer 在接管 tab_row 之前/之后失败都得自己收拾（sweep 实测：
                // separator 建好或挂载失败时 outer 连同 separator 一起漏）。接管之后
                // tab_row 的守卫让位给 outer，否则同一棵子树会被释放两次。
                errdefer cx.freeNode(outer);
                try outer.appendChild(allocator, tab_row);
                tab_row_owned = false;
                _ = try core.adoptChild(cx, allocator, outer, try box(cx, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 1 },
                    .background = t.color.separator,
                }, .{}));
            }
            break :blk outer;
        } else tab_row;
        // 守卫交接紧跟在 container 定下来的那一行：tab_row 的守卫让位，container 的
        // 守卫立刻武装，中间零窗口（交叉审查指出：此前隔着四行非可失败语句，
        // 正确性只靠"这几行没有 try"维持，编译器不保护）。
        // ⚠️ 这条守卫要一直武装到 return：ScopeBinding 只解绑不释放节点，
        // 绑定之后 container 依然无人回收，而下面还有大量可失败构造
        // （与 Tag.mount 同型，git_diff sidebar sweep index 27 实测）。
        tab_row_owned = false; // container 已接管 tab_row（自身或作为其子节点）
        errdefer cx.freeNode(container);

        container.tag = .button;
        container.setFocusable(true);
        container.meta.ownership.meta.component_name = "Tabs";
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;
        container.behavior.interaction.a11y = .{ .role = .tablist };
        container.addDebugState(@ptrCast(state));
        const key_ctx = try my_scope.allocator.create(TabClickContext);
        key_ctx.* = .{ .tabs_state = state, .tab_index = 0, .tab_row = tab_row };
        try my_scope.adoptResource(@ptrCast(key_ctx), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*TabClickContext, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);
        container.behavior.events.on_key_down = tabsKeyDown;
        container.behavior.events.key_context = key_ctx;

        try hooks.useFocusRing(my_scope, cx, container, .{});

        // on_before_render 渲染上下文
        const render_ctx = try my_scope.allocator.create(TabsRenderContext);
        render_ctx.* = .{
            .state = state,
            .variant = p.variant,
            .size = p.size,
            .tokens = t,
            .allocator = allocator,
            .item_count = p.items.len,
            .has_icons = has_icons,
            .highlight_box = highlight_box,
            .last_rendered_index = state.active_index, // 首帧不触发文字更新（mount 已设好）
        };
        try my_scope.adoptResource(@ptrCast(render_ctx), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *TabsRenderContext = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);
        tab_row.behavior.events.event_context = render_ctx;
        tab_row.meta.per_frame.hooks.before_render.main = tabsBeforeRender;

        // 构建每个 tab（不带背景色，背景由 highlight_box 提供）
        for (p.items, 0..) |item, i| {
            const is_active = (i == state.active_index);
            const is_disabled = item.disabled;
            const show_close = item.closable or p.closable;

            const click_ctx = try my_scope.allocator.create(TabClickContext);
            click_ctx.* = .{
                .tabs_state = state,
                .tab_index = i,
                .tab_row = tab_row,
            };
            try my_scope.adoptResource(@ptrCast(click_ctx), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const s: *TabClickContext = @ptrCast(@alignCast(ptr));
                    alloc.destroy(s);
                }
            }.destroy);

            const tab_node = try buildTab(my_scope, cx, p, item, is_active, is_disabled, show_close, click_ctx, slots);
            try tab_row.appendChild(allocator, tab_node);
        }

        return container;
    }
};

fn buildTab(
    scope: *Scope,
    cx: *Cx,
    props: TabsProps,
    item: TabItem,
    is_active: bool,
    is_disabled: bool,
    show_close: bool,
    click_ctx: *TabClickContext,
    slots: TabsSlotRecipe.Slots,
) !*Node {
    const allocator = cx.allocator;
    const t = cx.tokens;
    const v = props.variant;
    const s = props.size;

    const resolved = slots.tab.resolve(.{ .is_selected = is_active });

    const text_color = if (is_disabled)
        t.color.fg_secondary
    else
        resolved.text_color orelse t.color.fg_secondary;

    const font_sz = resolved.font_size orelse t.control.get(s).font_size;

    // 所有变体统一: row { icon?, label, badge?, close? }
    // 背景色由 highlight_box 提供，tab 自身透明；几何来自 tab slot 的 derived
    const tab_node = try box(cx, .{
        .padding = resolved.padding,
        .direction = .row,
        .align_items = .center,
        .gap = resolved.gap,
    }, .{});
    // tab_node 是返回给调用方的子树根，返回成功前无人持有。
    errdefer cx.freeNode(tab_node);
    if (!is_disabled) tab_node.style.cursor = .pointer;

    // 容器已是 role=tablist，但此前每个 tab 自身没有任何 a11y 声明，AT 看到的
    // 是一个空 tablist，既不知道有几个标签页，也读不出哪个是当前页。
    // role=tab + label + selected 三者缺一不可。
    tab_node.behavior.interaction.a11y = .{
        .role = .tab,
        .label = item.label_text,
        .selected = is_active,
        .disabled = is_disabled,
    };

    if (!is_disabled) {
        tab_node.behavior.events.on_event = tabClickHandler;
        tab_node.behavior.events.event_context = click_ctx;
        _ = try hooks.useHover(scope, tab_node);
    }

    // tab variant: 图标
    if (v == .tab) {
        if (item.icon_asset) |asset| {
            const icon_sz = styles.tabIconSize(s);
            const tint = if (is_active) t.color.accent else t.color.fg_secondary;
            const icon_node = try core.iconTint(cx, asset, tint, .{
                .width = .{ .px = icon_sz },
                .height = .{ .px = icon_sz },
            });
            try tab_node.appendChild(allocator, icon_node);
        }
    }

    // label: ghost bold text (h=0, 撑宽防抖动) + real text (font_weight 瞬间切换)
    // 建好即挂：下面 ghost/label 的构造与 setText 都可失败。
    const label_wrapper = try adoptTabChild(cx, allocator, tab_node, try box(cx, .{
        .direction = .column,
    }, .{}));

    // ghost text: bold 字重撑宽度，h=0 + overflow_hidden 裁掉渲染
    const ghost_node = try adoptTabChild(cx, allocator, label_wrapper, try box(cx, .{
        .height = .{ .px = 0 },
        .overflow_hidden = true,
    }, .{}));
    ghost_node.setText(.{
        .content = item.label_text,
        .color = Color.TRANSPARENT,
        .font_size = font_sz,
        .font_weight = 600,
    });

    // real text: font_weight 在切换时瞬间切换（不做 transition 动画，避免抖动/叠影）
    const label_node = try adoptTabChild(cx, allocator, label_wrapper, try box(cx, .{}, .{}));
    label_node.setText(.{
        .content = item.label_text,
        .color = text_color,
        .font_size = font_sz,
        .font_weight = if (is_active) @as(u16, 600) else @as(u16, 500),
    });

    // badge
    if (item.badge) |badge_count| {
        var badge_buf: [8]u8 = undefined;
        const badge_text = std.fmt.bufPrint(&badge_buf, "{d}", .{badge_count}) catch "0";

        var badge_style = slots.badge.resolve(.{});
        const badge_fg = badge_style.text_color orelse t.color.button_primary_fg;
        const badge_fs = badge_style.font_size orelse 10;
        // 文本样式经 setText 走 TextProps，不留在 box ext 上
        badge_style.text_color = null;
        badge_style.font_size = null;
        var badge_node = try box(cx, badge_style, .{});
        // 关键：badge_text 指向栈上 badge_buf，函数返回后即失效。必须 setContent
        // 拷贝（同 Badge 组件做法），否则跨帧渲染时 content 指针悬空 -> 只画出 accent 圆点、数字不绘。
        var badge_txt = core.TextProps{
            .content = "",
            .color = badge_fg,
            .font_size = badge_fs,
        };
        try badge_txt.setContent(cx.allocator, badge_text);
        badge_node.setText(badge_txt);
        try tab_node.appendChild(allocator, badge_node);
    }

    // close 按钮
    if (show_close) {
        var close_style = slots.close.resolve(.{});
        const close_fg = close_style.text_color orelse t.color.fg_secondary;
        const close_fs = close_style.font_size orelse 12;
        close_style.text_color = null;
        close_style.font_size = null;
        const close_btn = try box(cx, close_style, .{});
        close_btn.setText(.{
            .content = "×",
            .color = close_fg,
            .font_size = close_fs,
        });
        close_btn.behavior.interaction.a11y = .{ .role = .button, .label = "Close" };
        if (!is_disabled) {
            close_btn.style.cursor = .pointer;
            close_btn.behavior.events.on_event = tabCloseHandler;
            close_btn.behavior.events.event_context = click_ctx;
        }
        try tab_node.appendChild(allocator, close_btn);
    }

    return tab_node;
}

// ============================================================================
// TabPanel
// ============================================================================

pub const TabPanelProps = struct {
    id: []const u8,
    active: bool = true,
};

pub fn TabPanel(props: TabPanelProps) TabPanelBuilder {
    return TabPanelBuilder{ .props = props };
}

pub const TabPanelBuilder = struct {
    props: TabPanelProps,

    pub fn active(self: TabPanelBuilder, a: bool) TabPanelBuilder {
        var new = self;
        new.props.active = a;
        return new;
    }

    pub fn build(self: TabPanelBuilder, ctx: *Cx) !*Node {
        const p = self.props;

        if (!p.active) {
            const node = try box(ctx, .{
                .width = .{ .px = 0 },
                .height = .{ .px = 0 },
            }, .{});
            node.meta.ownership.meta.component_name = "TabPanel";
            node.behavior.interaction.a11y = .{
                .role = .tabpanel,
                .identifier = p.id,
                .hidden = true,
            };
            return node;
        }

        const node = try box(ctx, .{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
        }, .{});
        node.meta.ownership.meta.component_name = "TabPanel";
        node.behavior.interaction.a11y = .{
            .role = .tabpanel,
            .identifier = p.id,
        };
        return node;
    }
};

// ============================================================================
// EditorTabs, VSCode 风格文件标签
// ============================================================================

pub const EditorTabItem = struct {
    id: []const u8,
    label_text: []const u8,
    modified: bool = false,
    closable: bool = true,
};

pub const EditorTabsProps = struct {
    items: []const EditorTabItem,
    active_id: ?[]const u8 = null,
    default_active_id: ?[]const u8 = null,
    /// 2026-07-31 并轨：统一 ?core.HandlerRef，用 invokeWithStr 触发
    /// （payload = tab id）。
    on_change: ?core.HandlerRef = null,
    on_close: ?core.HandlerRef = null,
    context: ?*anyopaque = null,
};

pub fn EditorTabs(props: EditorTabsProps) EditorTabsBuilder {
    return EditorTabsBuilder{
        .props = props,
        .internal_active_id = props.default_active_id orelse if (props.items.len > 0) props.items[0].id else "",
    };
}

pub const EditorTabsBuilder = struct {
    props: EditorTabsProps,
    internal_active_id: []const u8,

    fn currentActiveId(self: *const EditorTabsBuilder) []const u8 {
        return self.props.active_id orelse self.internal_active_id;
    }

    pub fn build(self: EditorTabsBuilder, ctx: *Cx) !*Node {
        const allocator = ctx.allocator;
        const t = ctx.tokens;
        const p = self.props;

        const container = try box(ctx, styles.editorTabsContainerStyle(t), .{});
        container.meta.ownership.meta.component_name = "EditorTabs";

        for (p.items) |item| {
            const is_active = std.mem.eql(u8, item.id, self.currentActiveId());

            const tab = try self.buildEditorTab(ctx, item, is_active);
            try container.appendChild(allocator, tab);
        }

        return container;
    }

    fn buildEditorTab(
        self: EditorTabsBuilder,
        ctx: *Cx,
        item: EditorTabItem,
        is_active: bool,
    ) !*Node {
        const allocator = ctx.allocator;
        const t = ctx.tokens;
        _ = self;

        const tab = try box(ctx, styles.editorTabStyle(is_active, t), .{});

        const label_node = try box(ctx, .{}, .{});
        var label_txt = styles.editorTabLabelStyle(is_active, t);
        label_txt.content = item.label_text;
        label_node.setText(label_txt);
        try tab.appendChild(allocator, label_node);

        if (item.modified) {
            const dot = try box(ctx, styles.editorModifiedDotStyle(t), .{});
            try tab.appendChild(allocator, dot);
        }

        if (item.closable) {
            const close_btn = try box(ctx, styles.editorCloseStyle(t), .{});
            close_btn.setText(styles.editorCloseLabelStyle(t));
            try tab.appendChild(allocator, close_btn);
        }

        return tab;
    }
};

// ============================================================================
// 测试
// ============================================================================

test "Tabs: basic creation (underline default)" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "tab1", .label_text = "Tab 1" },
        .{ .id = "tab2", .label_text = "Tab 2" },
        .{ .id = "tab3", .label_text = "Tab 3" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .default_active_id = "tab1",
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tabs_node);

    // underline: outer = column { tab_row, separator }
    try std.testing.expectEqual(@as(usize, 2), tabs_node.children.items.len);
    // tab_row children = [highlight_box, tab1, tab2, tab3]
    const tab_row = tabs_node.children.items[0];
    try std.testing.expectEqual(@as(usize, 4), tab_row.children.items.len);
    // 第一个子节点是 highlight_box
    try std.testing.expectEqualStrings("TabHighlight", tab_row.children.items[0].meta.ownership.meta.component_name.?);
}

test "Tabs: pill variant" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "Option A" },
        .{ .id = "b", .label_text = "Option B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tabs_node);
    // pill: tab_row children = [highlight_box, tab1, tab2]
    try std.testing.expectEqual(@as(usize, 3), tabs_node.children.items.len);
    // pill 容器应该有背景色 (bg_secondary)
    try std.testing.expect(!Color.eql(tabs_node.getBackground(), Color.TRANSPARENT));
    // highlight_box 应该有白色背景
    const hbox = tabs_node.children.items[0];
    try std.testing.expect(Color.eql(hbox.getBackground(), ctx.tokens.color.bg_primary));
}

test "Tabs: pill render emits highlight background" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(320, 80);

    const root = try box(ctx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 80 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "One" },
        .{ .id = "b", .label_text = "Two" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .default_active_id = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_highlight = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.color.bg_primary) and r.geom.w >= 40 and r.geom.h >= 20) {
            saw_highlight = true;
        }
    };

    try std.testing.expect(saw_highlight);
}

test "Tabs: pill active tab text styling" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "Option A" },
        .{ .id = "b", .label_text = "Option B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .default_active_id = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // children = [highlight_box, tab_a, tab_b]
    // active tab: tab -> [label_wrapper] -> [ghost(h=0), label_node(text)]
    const active_tab = tabs_node.children.items[1]; // skip highlight
    const active_label_wrapper = active_tab.children.items[0];
    try std.testing.expect(active_label_wrapper.children.items.len >= 2);
    const active_label = active_label_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(active_label.getText() != null);
    try std.testing.expect(Color.eql(active_label.getText().?.color, ctx.tokens.color.fg_primary));

    // inactive tab
    const inactive_tab = tabs_node.children.items[2]; // skip highlight
    const inactive_label_wrapper = inactive_tab.children.items[0];
    try std.testing.expect(inactive_label_wrapper.children.items.len >= 2);
    const inactive_label = inactive_label_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(inactive_label.getText() != null);
    try std.testing.expect(Color.eql(inactive_label.getText().?.color, ctx.tokens.color.fg_secondary));
}

test "Tabs: icon variant" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "Files", .icon_asset = svg_assets.common.file_text },
        .{ .id = "b", .label_text = "Search", .icon_asset = svg_assets.common.search },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .tab,
        .default_active_id = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // children = [highlight_box, tab_a, tab_b]
    // highlight_box 应该有 accent_subtle 背景
    const hbox = tabs_node.children.items[0];
    try std.testing.expect(Color.eql(hbox.getBackground(), ctx.tokens.color.accent_subtle));

    // 每个 tab 应该有 icon + label = 2 个子节点
    const first_tab = tabs_node.children.items[1];
    try std.testing.expectEqual(@as(usize, 2), first_tab.children.items.len);
}

test "Tabs: small size" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "A" },
        .{ .id = "b", .label_text = "B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .size = .sm,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // children = [highlight_box, tab_a, tab_b]
    // tab -> [label_wrapper] -> [label_node(text)]
    const first_tab = tabs_node.children.items[1]; // skip highlight
    const label_wrapper = first_tab.children.items[0];
    try std.testing.expect(label_wrapper.children.items.len >= 2);
    const label = label_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(label.getText() != null);
    try std.testing.expectEqual(@as(f32, 11), label.getText().?.font_size);
}

test "Tabs: underline highlight box" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "Tab A" },
        .{ .id = "b", .label_text = "Tab B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .underline,
        .default_active_id = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // underline: outer = column { tab_row, separator }
    const tab_row = tabs_node.children.items[0];
    // tab_row children = [highlight_box, tab_a, tab_b]
    const hbox = tab_row.children.items[0];
    try std.testing.expectEqualStrings("TabHighlight", hbox.meta.ownership.meta.component_name.?);
    // underline highlight = accent 背景, 2px 高
    try std.testing.expect(Color.eql(hbox.getBackground(), ctx.tokens.color.accent));
    try std.testing.expectEqual(@as(f32, 2), hbox.style.height.px);
}

test "Tabs: with badge" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "inbox", .label_text = "Inbox", .badge = 5 },
        .{ .id = "sent", .label_text = "Sent" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tabs_node);

    // underline: outer = column { tab_row, separator }
    const tab_row = tabs_node.children.items[0];
    // tab_row children = [highlight_box, tab_inbox, tab_sent]
    const first_tab = tab_row.children.items[1]; // skip highlight
    // tab 应该有 label + badge = 2 children
    try std.testing.expectEqual(@as(usize, 2), first_tab.children.items.len);

    // 回归：badge 文本曾指向栈上 buffer，函数返回后悬空 -> 渲染只剩 accent 圆点、
    // 数字不绘。改用 setInlineContent 拷进 inline 存储后，content 必须仍是 "5"。
    const badge_node = first_tab.children.items[1];
    try std.testing.expect(badge_node.getText() != null);
    try std.testing.expectEqualStrings("5", badge_node.getText().?.content);
}

test "Tabs: closable" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "file1", .label_text = "file.txt" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .closable = true,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tabs_node);

    // underline: outer = column { tab_row, separator }
    const tab_row = tabs_node.children.items[0];
    // tab_row children = [highlight_box, tab]
    const tab = tab_row.children.items[1]; // skip highlight
    // tab 应该有 label + close = 2 children
    try std.testing.expectEqual(@as(usize, 2), tab.children.items.len);
}

test "Tabs: before_render updates on active change" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "Option A" },
        .{ .id = "b", .label_text = "Option B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .default_active_id = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // children = [highlight_box, tab_a, tab_b]
    // click 第二个 tab (index 2)
    const second_tab = tabs_node.children.items[2];
    const click_result = tabClickHandler(.{ .click = .{
        .x = 10,
        .y = 10,
        .button = .left,
        .click_count = 1,
    } }, second_tab.behavior.events.event_context);
    try std.testing.expectEqual(EventResult.handled, click_result);

    // 触发 before_render
    if (tabs_node.meta.per_frame.hooks.before_render.main) |before_render| {
        before_render(tabs_node);
    }
    for (tabs_node.meta.per_frame.hooks.before_render.hooks[0..tabs_node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
        if (cb_opt) |cb| cb(tabs_node);
    }

    // 验证文本颜色切换: tab -> [label_wrapper] -> [ghost, label_node(text)]
    const tab_b_wrapper = tabs_node.children.items[2].children.items[0];
    const tab_b_label = tab_b_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(tab_b_label.getText() != null);
    try std.testing.expect(Color.eql(tab_b_label.getText().?.color, ctx.tokens.color.fg_primary));
    const tab_a_wrapper = tabs_node.children.items[1].children.items[0];
    const tab_a_label = tab_a_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(Color.eql(tab_a_label.getText().?.color, ctx.tokens.color.fg_secondary));
}

test "TabPanel: active" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const panel = try TabPanel(.{ .id = "panel1", .active = true }).build(ctx);
    try root.appendChild(std.testing.allocator, panel);

    try std.testing.expect(panel.style.width == .grow);
}

test "TabPanel: inactive" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const panel = try TabPanel(.{ .id = "panel2", .active = false }).build(ctx);
    try root.appendChild(std.testing.allocator, panel);

    try std.testing.expectEqual(@as(f32, 0), panel.style.width.px);
}

test "EditorTabs: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 35 } }, .{});
    ctx.root = root;

    const items = [_]EditorTabItem{
        .{ .id = "main.zig", .label_text = "main.zig" },
        .{ .id = "build.zig", .label_text = "build.zig", .modified = true },
    };

    const tabs_node = try EditorTabs(.{
        .items = &items,
        .default_active_id = "main.zig",
    }).build(ctx);

    try root.appendChild(std.testing.allocator, tabs_node);
    try std.testing.expectEqual(@as(usize, 2), tabs_node.children.items.len);
}

test "TabsState: basic toggle" {
    var state = TabsState{
        .active_index = 0,
        .tab_count = 3,
    };
    state.tab_ids[0] = "tab1";
    state.tab_ids[1] = "tab2";
    state.tab_ids[2] = "tab3";

    try std.testing.expectEqual(@as(usize, 0), state.active_index);
    try std.testing.expectEqualStrings("tab1", state.getActiveId().?);

    state.setActive(1);
    try std.testing.expectEqual(@as(usize, 1), state.active_index);
    try std.testing.expectEqualStrings("tab2", state.getActiveId().?);

    state.setActive(2);
    try std.testing.expectEqual(@as(usize, 2), state.active_index);
    try std.testing.expectEqualStrings("tab3", state.getActiveId().?);
}

test "TabsState: moveNext/movePrev circular" {
    var state = TabsState{
        .active_index = 0,
        .tab_count = 3,
    };
    state.tab_ids[0] = "a";
    state.tab_ids[1] = "b";
    state.tab_ids[2] = "c";

    state.moveNext();
    try std.testing.expectEqual(@as(usize, 1), state.active_index);

    state.moveNext();
    try std.testing.expectEqual(@as(usize, 2), state.active_index);

    state.moveNext();
    try std.testing.expectEqual(@as(usize, 0), state.active_index);

    state.movePrev();
    try std.testing.expectEqual(@as(usize, 2), state.active_index);
}

test "TabsState: setActive fires on_change callback" {
    const CallbackCtx = struct {
        last_id: ?[]const u8 = null,
        call_count: u32 = 0,
    };

    var cb_ctx = CallbackCtx{};

    var state = TabsState{
        .active_index = 0,
        .tab_count = 2,
        .on_change = core.Cx.strHandlerFrom(CallbackCtx, &cb_ctx, struct {
            fn handler(c: *CallbackCtx, id: []const u8) void {
                c.last_id = id;
                c.call_count += 1;
            }
        }.handler),
    };
    state.tab_ids[0] = "first";
    state.tab_ids[1] = "second";

    state.setActive(1);
    try std.testing.expectEqual(@as(u32, 1), cb_ctx.call_count);
    try std.testing.expectEqualStrings("second", cb_ctx.last_id.?);

    state.setActive(1);
    try std.testing.expectEqual(@as(u32, 1), cb_ctx.call_count);
}

test "TabsState: out of bounds setActive is no-op" {
    var state = TabsState{
        .active_index = 0,
        .tab_count = 2,
    };

    state.setActive(5);
    try std.testing.expectEqual(@as(usize, 0), state.active_index);
}

test "Tabs: event handler responds to click" {
    const dummy_row = try Node.create(std.testing.allocator, 9001, .box, .{});
    defer dummy_row.destroy(std.testing.allocator);

    var state = TabsState{
        .active_index = 0,
        .tab_count = 3,
    };
    state.tab_ids[0] = "a";
    state.tab_ids[1] = "b";
    state.tab_ids[2] = "c";

    var click_ctx = TabClickContext{
        .tabs_state = &state,
        .tab_index = 2,
        .tab_row = dummy_row,
    };

    const result = tabClickHandler(.{ .click = .{
        .x = 10,
        .y = 10,
        .button = .left,
        .click_count = 1,
    } }, @ptrCast(&click_ctx));

    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(usize, 2), state.active_index);
}

test "Tabs: event handler responds to arrow keys" {
    const dummy_row = try Node.create(std.testing.allocator, 9002, .box, .{});
    defer dummy_row.destroy(std.testing.allocator);

    var state = TabsState{
        .active_index = 0,
        .tab_count = 3,
    };
    state.tab_ids[0] = "a";
    state.tab_ids[1] = "b";
    state.tab_ids[2] = "c";

    var click_ctx = TabClickContext{
        .tabs_state = &state,
        .tab_index = 0,
        .tab_row = dummy_row,
    };

    const result1 = tabClickHandler(.{ .key_down = .{
        .key = .right,
        .raw_keycode = 124,
        .modifiers = .{},
    } }, @ptrCast(&click_ctx));

    try std.testing.expectEqual(EventResult.handled, result1);
    try std.testing.expectEqual(@as(usize, 1), state.active_index);

    const result2 = tabClickHandler(.{ .key_down = .{
        .key = .left,
        .raw_keycode = 123,
        .modifiers = .{},
    } }, @ptrCast(&click_ctx));

    try std.testing.expectEqual(EventResult.handled, result2);
    try std.testing.expectEqual(@as(usize, 0), state.active_index);
}

test "Tabs: 点关闭按钮触发 on_close 且不激活该 tab；方向键在可聚焦 container 上生效" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Rec = struct {
        closed: ?[]const u8 = null,
        changed: usize = 0,
        fn onClose(self: *@This(), id: []const u8) void {
            self.closed = id;
        }
        fn onChange(self: *@This(), _: []const u8) void {
            self.changed += 1;
        }
    };
    var rec: Rec = .{};
    const items = [_]TabItem{
        .{ .id = "a", .label_text = "A" },
        .{ .id = "b", .label_text = "B" },
    };
    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .closable = true,
        .default_active_id = "a",
        .on_close = Cx.strHandlerFrom(Rec, &rec, Rec.onClose),
        .on_change = Cx.strHandlerFrom(Rec, &rec, Rec.onChange),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);
    ctx.layout();

    // pill: container == tab_row, children = [highlight_box, tab_a, tab_b]
    const tab_b = tabs_node.children.items[2];
    const close_b = tab_b.children.items[tab_b.children.items.len - 1];
    _ = ctx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, close_b);
    try std.testing.expectEqualStrings("b", rec.closed.?);
    try std.testing.expectEqual(@as(usize, 0), rec.changed); // 未冒泡激活 tab_b

    // 焦点在 container（唯一可聚焦节点）：方向键必须能切换
    try std.testing.expect(tabs_node.behavior.interaction.focusable);
    _ = ctx.dispatcher.dispatchKeyDown(tabs_node, .{ .key = .right, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 1), rec.changed);
    _ = ctx.dispatcher.dispatchKeyDown(tabs_node, .{ .key = .left, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 2), rec.changed);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

/// 一次性收养：append 失败时自己释放 child。
fn adoptTabChild(cx: *Cx, allocator: std.mem.Allocator, parent: *Node, child: *Node) !*Node {
    errdefer cx.freeNode(child);
    try parent.appendChild(allocator, child);
    return child;
}

// devtools mountPanel sweep 在 Tabs 内部抓到泄漏，夹具没走 underline + xs + on_change 分支。
test "Tabs: underline/xs/on_change 的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tabs(underline)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]TabItem{
                .{ .id = "elements", .label_text = "Elements" },
                .{ .id = "components", .label_text = "Components" },
                .{ .id = "console", .label_text = "Console" },
                .{ .id = "performance", .label_text = "Performance" },
            };
            const Dummy = struct {
                fn onChange(_: *@This(), _: []const u8) void {}
            };
            var dummy: Dummy = .{};
            return try Tabs(.{
                .items = &items,
                .default_active_id = "elements",
                .variant = .underline,
                .size = .xs,
                .on_change = Cx.strHandlerFrom(Dummy, &dummy, Dummy.onChange),
            }).mount(scope, cx);
        }
    }.m);
}

test "Tabs: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tabs", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]TabItem{ .{ .id = "tab1", .label_text = "Tab 1" }, .{ .id = "tab2", .label_text = "Tab 2" } };
            return try Tabs(.{ .items = &items, .default_active_id = "tab1" }).mount(scope, cx);
        }
    }.m);
}
