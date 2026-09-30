/// DropdownMenu Component
///
/// 命令触发式下拉菜单，区别于 Select（值选择）
///
/// 特性:
/// - 基于 Popover 定位
/// - 每个菜单项独立 on_click 回调（命令模式）
/// - 菜单项支持文本 + 可选图标 + 快捷键提示
/// - 分隔线
/// - disabled 项
/// - 键盘导航 (ArrowUp/Down/Enter/Escape)
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const Signal = core.Signal;
const Scope = @import("../../reactive.zig").Scope;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
const popover_mod = @import("../popover/mod.zig");
const svg_assets = @import("../../svg_assets.zig");

// 样式层（recipe + 具名样式函数）在 styles.zig；这里重导出保持公共 API 不变
const menu_navigation = @import("../menu_navigation.zig");
const styles = @import("styles.zig");
pub const DropdownMenuItemRecipe = styles.DropdownMenuItemRecipe;
const dropdownListStyle = styles.dropdownListStyle;
const dropdownSepWrapperStyle = styles.dropdownSepWrapperStyle;
const dropdownSepLineStyle = styles.dropdownSepLineStyle;
const dropdownItemLeftGroupStyle = styles.dropdownItemLeftGroupStyle;
const dropdownItemIconStyle = styles.dropdownItemIconStyle;
const dropdownShortcutStyle = styles.dropdownShortcutStyle;

/// 菜单项类型
pub const DropdownItemKind = enum {
    item,
    separator,
};

/// 菜单项定义
pub const DropdownItem = struct {
    /// 项目标识
    id: []const u8 = "",
    /// 显示文本
    label_text: []const u8 = "",
    /// 类型：普通项或分隔线
    kind: DropdownItemKind = .item,
    /// 是否禁用
    disabled: bool = false,
    /// 快捷键提示文字
    shortcut: ?[]const u8 = null,
    /// 危险操作样式（红色）
    danger: bool = false,
    /// 左侧图标（可选）
    icon_asset: ?svg_assets.Asset = null,
    /// 点击回调（命令触发）
    on_click: ?core.HandlerRef = null,
};

/// DropdownMenu 属性
pub const DropdownMenuProps = struct {
    /// 菜单项列表. mount copies the item records and their string fields, so
    /// callers may pass a function-local array. Handler contexts still follow
    /// the normal Scope lifetime contract.
    items: []const DropdownItem = &.{},
    /// 面板宽度
    width: f32 = 220,
    /// 弹出位置
    position: popover_mod.PopoverPosition = .bottom_start,
    /// 可选的菜单最大高度。设置后复用 Popover 的原生 fit_or_scroll/ScrollArea。
    max_height: ?f32 = null,
};

/// mount 返回结果
pub const DropdownMenuResult = struct {
    /// 外层包裹节点
    wrapper: *Node,
    /// trigger 插槽（调用方在此插入触发元素）
    trigger: *Node,
    /// 内部状态（可用于外部控制）
    state: *DropdownMenuState,
};

/// 内部状态
pub const DropdownMenuState = struct {
    /// 当前高亮索引
    highlighted_index: usize = 0,
    /// 控制面板显隐
    is_open: *Signal(bool),
    /// 菜单项定义引用
    items: []const DropdownItem,
    /// Owned backing for `items` and its string fields.
    owned_items: ?[]DropdownItem = null,
    /// 菜单项 UI 节点（用于高亮样式切换）
    item_nodes: [MAX_ITEMS]?*Node = [_]?*Node{null} ** MAX_ITEMS,
    /// 实际渲染的项数
    item_count: usize = 0,
    /// 虚拟高亮背景色 — mount 时从 DropdownMenuItemRecipe 的 hover 态 resolve 得到
    highlight_bg: Color,
    /// 菜单容器节点（aria-activedescendant 挂在它身上）
    menu_node: ?*Node = null,

    const MAX_ITEMS = 64;

    fn deinit(self: *DropdownMenuState, allocator: Allocator) void {
        const owned = self.owned_items orelse return;
        for (owned) |item| {
            allocator.free(item.id);
            allocator.free(item.label_text);
            if (item.shortcut) |shortcut| allocator.free(shortcut);
        }
        allocator.free(owned);
        self.owned_items = null;
        self.items = &.{};
    }

    /// 执行当前高亮项的命令
    pub fn selectHighlighted(self: *DropdownMenuState) void {
        if (self.highlighted_index >= self.items.len) return;
        const item = self.items[self.highlighted_index];
        if (item.kind == .separator or item.disabled) return;
        // 先关闭菜单
        self.is_open.set(false);
        // 触发该项的 on_click 回调
        if (item.on_click) |handler| handler.invoke();
    }

    /// 切换高亮到指定索引
    pub fn highlightIndex(self: *DropdownMenuState, index: usize) void {
        if (index >= self.items.len) return;
        if (self.items[index].kind == .separator) return;

        // 取消旧高亮
        if (self.highlighted_index < self.item_count) {
            if (self.item_nodes[self.highlighted_index]) |node| {
                node.setBackgroundRaw(Color.TRANSPARENT);
                node.markRenderDirty();
            }
        }

        self.highlighted_index = index;

        // 设置新高亮
        if (index < self.item_count) {
            if (self.item_nodes[index]) |node| {
                node.setBackgroundRaw(self.highlight_bg);
                node.markRenderDirty();

                // 键盘高亮是"虚拟焦点"——真实焦点始终停在菜单容器上，只有
                // aria-activedescendant 能告诉 AT 当前停在哪一项。缺了它，
                // 用方向键在菜单里走一圈，屏幕阅读器全程一言不发。
                if (self.menu_node) |menu| {
                    if (menu.behavior.interaction.a11y) |*a| {
                        a.active_descendant_element_id = node.element_id_raw;
                    }
                }
            }
        }
    }

    /// 查找下一个可用项（跳过分隔线和禁用项）
    fn nextEnabledIndex(self: *DropdownMenuState, from: usize, forward: bool) ?usize {
        return menu_navigation.nextEnabledIndex(self.items, from, forward);
    }
};

// ========== Builder ==========

/// 创建 DropdownMenu
pub fn DropdownMenu(props: DropdownMenuProps) DropdownMenuBuilder {
    return DropdownMenuBuilder{ .props = props };
}

pub const DropdownMenuBuilder = struct {
    props: DropdownMenuProps,

    pub fn items(self: DropdownMenuBuilder, its: []const DropdownItem) DropdownMenuBuilder {
        var new = self;
        new.props.items = its;
        return new;
    }

    pub fn width(self: DropdownMenuBuilder, w: f32) DropdownMenuBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn position(self: DropdownMenuBuilder, pos: popover_mod.PopoverPosition) DropdownMenuBuilder {
        var new = self;
        new.props.position = pos;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: DropdownMenuBuilder, scope: *Scope, cx: *Cx) !DropdownMenuResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const scope_allocator = my_scope.allocator;
        const t = cx.tokens;
        const p = self.props;

        // 创建 Popover 容器
        var pop_result = try popover_mod.Popover(.{
            .position = p.position,
            .trigger = .click,
            .width = p.width,
            .max_width = if (p.max_height != null) p.width else null,
            .max_height = p.max_height,
            .size_policy = if (p.max_height != null) .fit_or_scroll else .hard_clip,
            .constrain_width_to_viewport = true,
        }).mount(my_scope, cx);

        // Popover.mount 返回后 wrapper 子树只被 my_scope 绑定（bindScopeToNode 的
        // destroy 只解绑不释放），调用方 scope.dispose() 不会回收它；
        // 而下面 cloneItems / create(State) / 各 item 节点构造全都可失败。
        // 与 Tooltip.mount 同型（修的那处）。
        // git_diff canvas OOM 注入 index 227 实测：整棵 popover 子树泄漏。
        errdefer cx.freeNode(pop_result.wrapper);

        pop_result.wrapper.meta.ownership.meta.component_name = "DropdownMenu";

        // ---- 状态 ----
        // The fixed node table intentionally caps the public menu at MAX_ITEMS.
        // Keep the state slice capped too, otherwise keyboard navigation could
        // select and invoke an item that was never rendered.
        const source_items = p.items[0..@min(p.items.len, DropdownMenuState.MAX_ITEMS)];
        var owned_items: ?[]DropdownItem = try cloneItems(scope_allocator, source_items);
        errdefer if (owned_items) |owned_slice| freeItems(scope_allocator, owned_slice);
        const state = try scope_allocator.create(DropdownMenuState);
        var state_registered = false;
        errdefer if (!state_registered) scope_allocator.destroy(state);
        state.* = .{
            .is_open = pop_result.is_open,
            .items = owned_items.?,
            .owned_items = owned_items.?,
            .highlight_bg = DropdownMenuItemRecipe.resolve(.{}, t)
                .resolve(.{ .is_hovered = true }).background orelse Color.TRANSPARENT,
        };
        try my_scope.registerResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s: *DropdownMenuState = @ptrCast(@alignCast(ptr));
                s.deinit(alloc);
                alloc.destroy(s);
            }
        }.cleanup);
        state_registered = true;
        // Ownership has transferred to the registered state cleanup. On a
        // later mount error the child scope remains parent-owned and will
        // dispose the state exactly once.
        owned_items = null;

        // ---- 菜单项列表容器 ----
        const item_list = try box(cx, dropdownListStyle(t), .{});
        // 建好即挂：挂稳之后再发布 state.menu_node（prepare-then-publish），
        // 否则 append 失败时 state 里留下悬垂指针。
        var item_list_attached = false;
        errdefer if (!item_list_attached) cx.freeNode(item_list);
        item_list.behavior.interaction.a11y = .{ .role = .menu };
        pop_result.content.setFocusable(true);
        try pop_result.content.appendChild(allocator, item_list);
        item_list_attached = true;
        state.menu_node = item_list;

        // ---- 渲染每个菜单项 ----
        const max_items = @min(state.items.len, DropdownMenuState.MAX_ITEMS);
        for (state.items[0..max_items], 0..) |item, i| {
            if (item.kind == .separator) {
                // 分隔线
                const sep_wrapper = try box(cx, dropdownSepWrapperStyle(t), .{});
                var sep_wrapper_attached = false;
                errdefer if (!sep_wrapper_attached) cx.freeNode(sep_wrapper);
                const sep_line = try box(cx, dropdownSepLineStyle(t), .{});
                var sep_line_attached = false;
                errdefer if (!sep_line_attached) cx.freeNode(sep_line);
                try sep_wrapper.appendChild(allocator, sep_line);
                sep_line_attached = true;
                sep_wrapper.behavior.interaction.a11y = .{ .role = .separator };
                try item_list.appendChild(allocator, sep_wrapper);
                sep_wrapper_attached = true;
                // 挂稳之后再发布指针。
                state.item_nodes[i] = sep_wrapper;
                state.item_count = i + 1;
                continue;
            }

            // recipe resolve：几何 + 背景 + 文字样式一次拿全（disabled > danger > normal，
            // disabled 走条件位短路保证优先）
            var item_style = DropdownMenuItemRecipe.resolve(
                .{ .danger = item.danger },
                t,
            ).resolve(.{ .is_disabled = item.disabled });
            const fg = item_style.text_color orelse t.color.fg_primary;
            const label_fs = item_style.font_size orelse 13;
            // 文本样式经 setText 走 TextProps，不留在 box ext 上
            item_style.text_color = null;
            item_style.font_size = null;

            // 建好即挂：下面 left_group / icon / label / shortcut 全都可失败，
            // item_node 原本要等它们全建完才上树，中途失败即漏整项。
            const item_node = try adoptChild(cx, allocator, item_list, try box(cx, item_style, .{}));

            item_node.behavior.interaction.a11y = .{
                .role = .menuitem,
                .label = item.label_text,
                .disabled = item.disabled,
                // 快捷键放 description：AT 会在项名之后补读"⌘N"，
                // 不会污染项名本身。
                .description = item.shortcut,
            };

            // 左侧容器：图标 + 文本
            const left_group = try adoptChild(cx, allocator, item_node, try box(cx, dropdownItemLeftGroupStyle(t), .{}));

            // 可选图标
            if (item.icon_asset) |asset| {
                _ = try adoptChild(cx, allocator, left_group, try core.iconTint(cx, asset, fg, dropdownItemIconStyle(t)));
            }

            // 文本标签
            var label_node = try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{});
            // 不加 errdefer —— adoptChild 已在 append 失败时释放它。
            // 一个 child 只能有一个回收责任方（加了就是 double free，
            // 实测 0xaaaa 毒值 segfault）。
            label_node.setText(.{ .content = item.label_text, .color = fg, .font_size = label_fs });
            _ = try adoptChild(cx, allocator, left_group, label_node);

            // 右侧快捷键提示
            if (item.shortcut) |sc| {
                var sc_node = try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{});
                var sc_txt = dropdownShortcutStyle(t);
                sc_txt.content = sc;
                sc_node.setText(sc_txt);
                try item_node.appendChild(allocator, sc_node);
            }

            // 交互：非禁用项绑定点击和 hover
            if (!item.disabled) {
                item_node.style.cursor = .pointer;
                const click_ctx = try scope_allocator.create(ItemClickContext);
                var click_ctx_registered = false;
                errdefer if (!click_ctx_registered) scope_allocator.destroy(click_ctx);
                click_ctx.* = .{ .state = state, .index = i };
                try my_scope.registerResource(@ptrCast(click_ctx), struct {
                    fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                        const c: *ItemClickContext = @ptrCast(@alignCast(ptr));
                        alloc.destroy(c);
                    }
                }.cleanup);
                click_ctx_registered = true;
                item_node.behavior.events.on_event = itemEventHandler;
                item_node.behavior.events.event_context = @ptrCast(click_ctx);
            }

            // 已在建好时挂进 item_list，这里只发布指针。
            state.item_nodes[i] = item_node;
            state.item_count = i + 1;
        }

        // ---- 键盘导航（绑定到 popover content） ----
        pop_result.content.behavior.events.on_key_down = menuKeyHandler;
        pop_result.content.behavior.events.key_context = @ptrCast(state);

        try my_scope.createEffect(.{
            .is_open = pop_result.is_open,
            .content = pop_result.content,
            .cx = cx,
        }, struct {
            fn update(c: anytype) void {
                if (c.is_open.get()) {
                    c.cx.setFocus(c.content);
                }
            }
        }.update);

        return .{
            .wrapper = pop_result.wrapper,
            .trigger = pop_result.trigger,
            .state = state,
        };
    }
};

fn cloneItems(allocator: Allocator, source: []const DropdownItem) ![]DropdownItem {
    const cloned = try allocator.alloc(DropdownItem, source.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| {
            allocator.free(item.id);
            allocator.free(item.label_text);
            if (item.shortcut) |shortcut| allocator.free(shortcut);
        }
    }

    for (source, 0..) |item, index| {
        const id = try allocator.dupe(u8, item.id);
        errdefer allocator.free(id);
        const label = try allocator.dupe(u8, item.label_text);
        errdefer allocator.free(label);
        const shortcut = if (item.shortcut) |value| try allocator.dupe(u8, value) else null;
        cloned[index] = item;
        cloned[index].id = id;
        cloned[index].label_text = label;
        cloned[index].shortcut = shortcut;
        initialized += 1;
    }
    return cloned;
}

fn freeItems(allocator: Allocator, items: []DropdownItem) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.label_text);
        if (item.shortcut) |shortcut| allocator.free(shortcut);
    }
    allocator.free(items);
}

// ========== 内部辅助 ==========

const ItemClickContext = struct {
    state: *DropdownMenuState,
    index: usize,
};

/// 菜单项事件处理：click 执行命令，mouse_enter 高亮
fn itemEventHandler(event: Event, context: ?*anyopaque) EventResult {
    switch (event) {
        .click => {
            if (context) |ctx| {
                const mc: *ItemClickContext = @ptrCast(@alignCast(ctx));
                mc.state.highlighted_index = mc.index;
                mc.state.selectHighlighted();
                return .stop;
            }
        },
        .mouse_enter => {
            if (context) |ctx| {
                const mc: *ItemClickContext = @ptrCast(@alignCast(ctx));
                mc.state.highlightIndex(mc.index);
                return .handled;
            }
        },
        else => {},
    }
    return .ignored;
}

/// 键盘导航处理
fn menuKeyHandler(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const state: *DropdownMenuState = @ptrCast(@alignCast(context.?));

    switch (key) {
        .down => {
            if (state.nextEnabledIndex(state.highlighted_index, true)) |idx| {
                state.highlightIndex(idx);
            }
            return .stop;
        },
        .up => {
            if (state.nextEnabledIndex(state.highlighted_index, false)) |idx| {
                state.highlightIndex(idx);
            }
            return .stop;
        },
        .@"return" => {
            state.selectHighlighted();
            return .stop;
        },
        .escape => {
            state.is_open.set(false);
            return .stop;
        },
        else => return .ignored,
    }
}

// ========== 测试 ==========

const test_items = [_]DropdownItem{
    .{ .id = "new_file", .label_text = "New File", .shortcut = "\xe2\x8c\x98N" },
    .{ .id = "open", .label_text = "Open...", .shortcut = "\xe2\x8c\x98O" },
    .{ .kind = .separator },
    .{ .id = "save", .label_text = "Save", .shortcut = "\xe2\x8c\x98S" },
    .{ .id = "delete", .label_text = "Delete", .danger = true },
    .{ .id = "disabled_item", .label_text = "Unavailable", .disabled = true },
};

test "DropdownMenuItemRecipe: disabled 条件压过 danger 变体（等价旧 compounds 梯子）" {
    const t = &theme.dark;
    const normal = DropdownMenuItemRecipe.resolve(.{}, t).resolve(.{});
    try std.testing.expectEqual(t.color.fg_primary, normal.text_color.?);
    const danger = DropdownMenuItemRecipe.resolve(.{ .danger = true }, t).resolve(.{});
    try std.testing.expectEqual(t.color.danger, danger.text_color.?);
    const dis_danger = DropdownMenuItemRecipe.resolve(.{ .danger = true }, t)
        .resolve(.{ .is_disabled = true });
    try std.testing.expectEqual(t.color.fg_disabled, dis_danger.text_color.?);
}

test "DropdownMenu: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DropdownMenu(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(@as(usize, 6), result.state.item_count);
}

test "DropdownMenu: mount owns item records and strings" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var local_items = [_]DropdownItem{
        .{ .id = "local", .label_text = "Local item", .shortcut = "Cmd-L" },
    };
    const result = try DropdownMenu(.{ .items = &local_items }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expect(result.state.items.ptr != local_items[0..].ptr);
    try std.testing.expect(result.state.items[0].id.ptr != local_items[0].id.ptr);
    try std.testing.expect(result.state.items[0].label_text.ptr != local_items[0].label_text.ptr);
    try std.testing.expect(result.state.items[0].shortcut.?.ptr != local_items[0].shortcut.?.ptr);
    local_items[0] = .{ .id = "changed", .label_text = "Changed" };
    try std.testing.expectEqualStrings("local", result.state.items[0].id);
    try std.testing.expectEqualStrings("Local item", result.state.items[0].label_text);
    try std.testing.expectEqualStrings("Cmd-L", result.state.items[0].shortcut.?);
}

test "DropdownMenu: state and keyboard navigation are capped to rendered items" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 1200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var many_items: [DropdownMenuState.MAX_ITEMS + 1]DropdownItem = undefined;
    for (&many_items) |*item| item.* = .{ .id = "item", .label_text = "Item" };
    const result = try DropdownMenu(.{ .items = &many_items }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(DropdownMenuState.MAX_ITEMS, result.state.items.len);
    try std.testing.expectEqual(DropdownMenuState.MAX_ITEMS, result.state.item_count);

    result.state.highlighted_index = DropdownMenuState.MAX_ITEMS - 1;
    _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(usize, 0), result.state.highlighted_index);
}

test "DropdownMenu: keyboard navigation skips separator and disabled" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DropdownMenu(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 从 index 0 向下
    _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(usize, 1), result.state.highlighted_index);

    // 继续向下，跳过 separator (index 2)
    _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(usize, 3), result.state.highlighted_index);

    // 继续向下到 danger 项
    _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(usize, 4), result.state.highlighted_index);

    // 继续向下，跳过 disabled (index 5)，回到 index 0
    _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(usize, 0), result.state.highlighted_index);
}

test "DropdownMenu: select item closes menu" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DropdownMenu(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.is_open.set(true);
    result.state.selectHighlighted();
    try std.testing.expect(!result.state.is_open.peek());
}

test "DropdownMenu: escape closes menu" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DropdownMenu(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.is_open.set(true);
    _ = menuKeyHandler(.escape, .{}, @ptrCast(result.state));
    try std.testing.expect(!result.state.is_open.peek());
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

/// 一次性收养：append 失败时自己释放 child（与下游编辑器的 utils.adopt 同型）。
/// 让「建好即挂」写起来不啰嗦 —— 窗口不存在就不需要门控 flag。
fn adoptChild(cx: *Cx, allocator: Allocator, parent: *Node, child: *Node) !*Node {
    errdefer cx.freeNode(child);
    try parent.appendChild(allocator, child);
    return child;
}

test "DropdownMenu: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("dropdown_menu", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try DropdownMenu(.{ .items = &test_items }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
