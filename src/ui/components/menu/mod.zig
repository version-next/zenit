/// Menu Component
///
/// 上下文菜单 / 下拉菜单，基于 Popover 实现
///
/// 特性:
/// - 菜单项 + 分隔符
/// - 键盘导航 (ArrowUp/Down/Enter/Escape)
/// - 快捷键提示
/// - danger 样式
/// - disabled 项
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

// 样式层（recipe + 具名样式函数）在 styles.zig；这里重导出保持公共 API 不变
const menu_navigation = @import("../menu_navigation.zig");
const styles = @import("styles.zig");
pub const MenuItemRecipe = styles.MenuItemRecipe;
const menuListStyle = styles.menuListStyle;
const menuSeparatorStyle = styles.menuSeparatorStyle;
const menuShortcutStyle = styles.menuShortcutStyle;

/// 菜单项类型
pub const MenuItemKind = enum {
    item,
    separator,
};

/// 菜单项
pub const MenuItem = struct {
    id: []const u8 = "",
    label_text: []const u8 = "",
    kind: MenuItemKind = .item,
    disabled: bool = false,
    shortcut: ?[]const u8 = null,
    danger: bool = false,
};

/// Menu 属性
pub const MenuProps = struct {
    items: []const MenuItem = &.{},
    on_select: ?core.HandlerRef = null,
    width: f32 = 220,
    position: popover_mod.PopoverPosition = .bottom_start,
};

/// Menu mount 返回结果
pub const MenuResult = struct {
    wrapper: *Node,
    trigger: *Node,
    state: *MenuState,
};

/// Menu 内部状态
pub const MenuState = struct {
    highlighted_index: usize = 0,
    is_open: *Signal(bool),
    items: []const MenuItem,
    item_nodes: [MAX_ITEMS]?*Node = [_]?*Node{null} ** MAX_ITEMS,
    item_count: usize = 0,
    on_select: ?core.HandlerRef,
    /// 虚拟高亮背景色，mount 时从 MenuItemRecipe 的 hover 态 resolve 得到
    highlight_bg: Color,
    /// Container which owns keyboard focus while item highlight is virtual.
    menu_node: ?*Node = null,

    const MAX_ITEMS = 32;

    pub fn selectHighlighted(self: *MenuState) void {
        if (self.highlighted_index >= self.items.len) return;
        const item = self.items[self.highlighted_index];
        if (item.kind == .separator or item.disabled) return;
        self.is_open.set(false);
        if (self.on_select) |handler| handler.invoke();
    }

    pub fn highlightIndex(self: *MenuState, index: usize) void {
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

        // 新高亮
        if (index < self.item_count) {
            if (self.item_nodes[index]) |node| {
                node.setBackgroundRaw(self.highlight_bg);
                node.markRenderDirty();
                if (self.menu_node) |menu_node| {
                    if (menu_node.behavior.interaction.a11y) |*a| {
                        a.active_descendant_element_id = node.element_id_raw;
                    }
                    menu_node.markRenderDirty();
                }
            }
        }
    }

    fn nextEnabledIndex(self: *MenuState, from: usize, forward: bool) ?usize {
        return menu_navigation.nextEnabledIndex(self.items, from, forward);
    }
};

/// 创建 Menu
pub fn Menu(props: MenuProps) MenuBuilder {
    return MenuBuilder{ .props = props };
}

pub const MenuBuilder = struct {
    props: MenuProps,

    pub fn items(self: MenuBuilder, its: []const MenuItem) MenuBuilder {
        var new = self;
        new.props.items = its;
        return new;
    }

    pub fn width(self: MenuBuilder, w: f32) MenuBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn onSelect(self: MenuBuilder, handler_ref: core.HandlerRef) MenuBuilder {
        var new = self;
        new.props.on_select = handler_ref;
        return new;
    }

    pub fn position(self: MenuBuilder, pos: popover_mod.PopoverPosition) MenuBuilder {
        var new = self;
        new.props.position = pos;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: MenuBuilder, scope: *Scope, cx: *Cx) !MenuResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Popover
        var pop_result = try popover_mod.Popover(.{
            .position = p.position,
            .trigger = .click,
            .width = p.width,
        }).mount(my_scope, cx);
        // sweep：wrapper 守到 return；失败先 dispose my_scope 再 freeNode；子树建好即 adopt
        errdefer cx.freeNode(pop_result.wrapper);
        errdefer my_scope.dispose();

        pop_result.wrapper.meta.ownership.meta.component_name = "Menu";

        // ---- State ----
        const state = try allocator.create(MenuState);
        state.* = .{
            .is_open = pop_result.is_open,
            // 只渲染前 MAX_ITEMS 项；键盘导航 / 选择也必须限在同一范围，
            // 否则能高亮并激活看不见的项。
            .items = p.items[0..@min(p.items.len, MenuState.MAX_ITEMS)],
            .on_select = p.on_select,
            .highlight_bg = MenuItemRecipe.resolve(.{}, t)
                .resolve(.{ .is_hovered = true }).background orelse Color.TRANSPARENT,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s: *MenuState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.cleanup);

        // ---- Menu Items ----
        const item_list = try core.adoptChild(cx, allocator, pop_result.content, try box(cx, menuListStyle(t), .{}));
        // The focusable popover content owns the menu role and active
        // descendant. Keeping those on the same node makes VoiceOver's
        // focusedUIElement query resolve the highlighted item; the visual
        // item_list remains an unprojected layout wrapper.
        pop_result.content.behavior.interaction.a11y = .{ .role = .menu };
        state.menu_node = pop_result.content;
        pop_result.content.setFocusable(true);

        const max_items = @min(p.items.len, MenuState.MAX_ITEMS);
        for (p.items[0..max_items], 0..) |item, i| {
            if (item.kind == .separator) {
                // 分隔线
                const sep = try core.adoptChild(cx, allocator, item_list, try box(cx, menuSeparatorStyle(t), .{}));
                sep.behavior.interaction.a11y = .{ .role = .separator };
                state.item_nodes[i] = sep;
                state.item_count = i + 1;
                continue;
            }

            // recipe resolve：几何 + 背景 + 文字样式一次拿全
            // danger 是变体维度；disabled 走条件位（短路语义保证压过 danger）
            var item_style = MenuItemRecipe.resolve(
                .{ .danger = item.danger },
                t,
            ).resolve(.{ .is_disabled = item.disabled });
            const fg = item_style.text_color orelse t.color.fg_primary;
            const label_fs = item_style.font_size orelse 13;
            // 文本样式经 setText 走 TextProps，不留在 box ext 上
            item_style.text_color = null;
            item_style.font_size = null;

            const item_node = try core.adoptChild(cx, allocator, item_list, try box(cx, item_style, .{}));

            // disabled 必须如实报：AT 用户否则会反复尝试激活一个永远没反应的项。
            item_node.behavior.interaction.a11y = .{
                .role = .menuitem,
                .label = item.label_text,
                .disabled = item.disabled,
                // 快捷键走 description，AT 在项名之后补读"⌘X"而不污染项名。
                .description = item.shortcut,
            };

            // Label
            const label_node = try core.adoptChild(cx, allocator, item_node, try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            label_node.setText(.{
                .content = item.label_text,
                .color = fg,
                .font_size = label_fs,
            });

            // Shortcut
            if (item.shortcut) |sc| {
                const sc_node = try core.adoptChild(cx, allocator, item_node, try core.text(cx, sc, .{}));
                if (sc_node.getText()) |old| {
                    const sc_style = menuShortcutStyle(t);
                    var txt = old;
                    txt.color = sc_style.color;
                    txt.font_size = sc_style.font_size;
                    sc_node.setText(txt);
                }
            }

            if (!item.disabled) {
                item_node.style.cursor = .pointer;
                const click_ctx = try allocator.create(MenuItemClickContext);
                click_ctx.* = .{ .state = state, .index = i };
                try my_scope.adoptResource(@ptrCast(click_ctx), struct {
                    fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                        const c: *MenuItemClickContext = @ptrCast(@alignCast(ptr));
                        alloc.destroy(c);
                    }
                }.cleanup);
                item_node.behavior.events.on_event = menuItemEventHandler;
                item_node.behavior.events.event_context = @ptrCast(click_ctx);
            }

            state.item_nodes[i] = item_node;
            state.item_count = i + 1;
        }

        // 键盘导航
        pop_result.content.behavior.events.on_key_down = menuKeyHandler;
        pop_result.content.behavior.events.key_context = @ptrCast(state);

        return .{
            .wrapper = pop_result.wrapper,
            .trigger = pop_result.trigger,
            .state = state,
        };
    }
};

// ========== 内部辅助 ==========

const MenuItemClickContext = struct {
    state: *MenuState,
    index: usize,
};

fn menuItemEventHandler(event: Event, context: ?*anyopaque) EventResult {
    switch (event) {
        .click => {
            if (context) |ctx| {
                const mc: *MenuItemClickContext = @ptrCast(@alignCast(ctx));
                mc.state.highlighted_index = mc.index;
                mc.state.selectHighlighted();
                return .stop;
            }
        },
        .mouse_enter => {
            if (context) |ctx| {
                const mc: *MenuItemClickContext = @ptrCast(@alignCast(ctx));
                mc.state.highlightIndex(mc.index);
                return .handled;
            }
        },
        else => {},
    }
    return .ignored;
}

fn menuKeyHandler(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const state: *MenuState = @ptrCast(@alignCast(context.?));

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

const test_items = [_]MenuItem{
    .{ .id = "cut", .label_text = "Cut", .shortcut = "\xe2\x8c\x98X" }, // ⌘X
    .{ .id = "copy", .label_text = "Copy", .shortcut = "\xe2\x8c\x98C" }, // ⌘C
    .{ .kind = .separator },
    .{ .id = "paste", .label_text = "Paste", .shortcut = "\xe2\x8c\x98V" }, // ⌘V
    .{ .id = "delete", .label_text = "Delete", .danger = true },
};

test "MenuItemRecipe: disabled 条件压过 danger 变体（等价旧 compounds 梯子）" {
    const t = &theme.dark;
    const normal = MenuItemRecipe.resolve(.{}, t).resolve(.{});
    try std.testing.expectEqual(t.color.fg_primary, normal.text_color.?);
    const danger = MenuItemRecipe.resolve(.{ .danger = true }, t).resolve(.{});
    try std.testing.expectEqual(t.color.danger, danger.text_color.?);
    const dis_danger = MenuItemRecipe.resolve(.{ .danger = true }, t)
        .resolve(.{ .is_disabled = true });
    try std.testing.expectEqual(t.color.fg_disabled, dis_danger.text_color.?);
}

test "Menu: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Menu(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(@as(usize, 5), result.state.item_count);
}

test "Menu: keyboard navigation skips separator" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Menu(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 从 index 0 向下，跳过 separator (index 2)
    _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(usize, 1), result.state.highlighted_index);

    _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
    // 应跳过 separator (index 2)，到 index 3
    try std.testing.expectEqual(@as(usize, 3), result.state.highlighted_index);
}

test "Menu: 超过 MAX_ITEMS 时键盘不能导航到未渲染的项" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const many = [_]MenuItem{.{ .id = "x", .label_text = "X" }} ** 40;
    const result = try Menu(.{ .items = &many }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        _ = menuKeyHandler(.down, .{}, @ptrCast(result.state));
        try std.testing.expect(result.state.highlighted_index < MenuState.MAX_ITEMS);
    }
    _ = menuKeyHandler(.up, .{}, @ptrCast(result.state));
    try std.testing.expect(result.state.highlighted_index < MenuState.MAX_ITEMS);
}

test "Menu: select item closes menu" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Menu(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.is_open.set(true);
    result.state.selectHighlighted();
    try std.testing.expect(!result.state.is_open.peek());
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "menu: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("menu", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Menu(.{ .items = &test_items }).mount(scope, cx)).wrapper;
        }
    }.m);
}
