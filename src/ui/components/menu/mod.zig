/// Menu component: command set expanding from a trigger element (dropdown / context menu),
/// Popover-based.
///
/// Features:
/// - Menu items + separators, optional icon/shortcut hint/danger style/disabled state
/// - Two (compatible) receive modes: per-item `on_click` callback, or whole `on_select` with item
///   id
/// - items from signal / derived: a new array rebuilds items
/// - Keyboard navigation (ArrowUp/Down/Enter/Escape)
/// - Optional max height (overflow scrolls in panel)
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Signal = reactive.Signal;
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
const popover_mod = @import("../popover/mod.zig");
const svg_assets = @import("../../svg_assets.zig");
const bind_mod = @import("../../bind.zig");

// Styling layer (recipe + named style functions) in styles.yss; re-exported here to keep public API
// stable
const styles = @import("_styles.yss.zig");
const views = @import("_menu.yix.zig");
/// Menu item appearance recipe (root / label / icon slots; danger / lit / disabled switches)
pub const MenuItemRecipe = styles.MenuRow;

/// Menu item type
pub const MenuItemKind = enum {
    item,
    separator,
};

/// Menu item
pub const MenuItem = struct {
    /// Nested menu. Static trees are copied at mount; leaf selection closes ancestors.
    children: []const MenuItem = &.{},
    /// Item identifier (received by `on_select`)
    id: []const u8 = "",
    /// Display text
    label: []const u8 = "",
    /// Type: normal item or separator
    kind: MenuItemKind = .item,
    disabled: bool = false,
    /// Shortcut hint text
    shortcut: ?[]const u8 = null,
    /// Dangerous operation style (red)
    danger: bool = false,
    /// Left icon (optional)
    icon_asset: ?svg_assets.Asset = null,
    /// Command callback for this item; menu requests close via toggle pipeline, then calls
    /// on_select, then it
    on_click: ?Handler(void) = null,
};

/// Menu properties
pub const MenuProps = struct {
    trigger: popover_mod.PopoverTrigger = .click,
    /// Used by nested menus to return focus to their parent on Left/Escape.
    on_back: ?Handler(void) = null,
    /// Menu items. Static array copied at mount with strings (caller can pass function-local
    /// array);
    /// signal / derived borrow current value: new array rebuilds, old array and strings must stay
    /// valid until replaced. Handler context still follows Scope lifecycle. Items beyond MAX_ITEMS
    /// not rendered.
    items: Source([]const MenuItem) = .{ .value = &.{} },
    /// Toggle: `bool` uncontrolled; `*Signal(bool)` controlled (interaction writes directly);
    /// `ui.split` intercepts
    open: Model(bool) = .{ .local = false },
    on_open_change: ?Handler(bool) = null,
    /// Select an item (item id, valid only in this call, copy to keep). After select menu requests
    /// close via toggle pipeline
    on_select: ?Handler([]const u8) = null,
    /// Panel width
    width: f32 = 220,
    /// Popup position
    position: popover_mod.PopoverPosition = .bottom_start,
    /// Optional menu max height. When set, reuses Popover's native fit_or_scroll / ScrollArea.
    max_height: ?f32 = null,
};

/// Menu mount result
pub const MenuResult = struct {
    /// Outer wrapper node
    wrapper: *Node,
    /// trigger slot (caller inserts trigger element here)
    trigger: *Node,
    /// Toggle signal (`ui.split` -> null)
    open: ?*Signal(bool),
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: MenuResult) core.ViewParts {
        return .{ .root = self.wrapper, .trigger = self.trigger };
    }
};

/// Menu internal state (owned by Popover scope, lifetime with menu)
pub const MenuState = struct {
    was_open: bool = false,
    previous_focus: ?core.NodeHandle = null,
    cx: *Cx,
    /// Current highlight index (keyboard navigation and select use it)
    highlighted_index: usize = 0,
    /// Visual highlight on screen (row view lights up by it); no highlight until keyboard move or
    /// pointer enter after create/rebuild
    highlighted: *Signal(usize),
    keyboard_focus: *Signal(bool),
    /// Currently rendered menu items (click / keyboard activate by it, matches screen)
    items: []const MenuItem = &.{},
    /// Deep copy of static items (null if from signal source, borrows current value)
    owned_items: ?[]MenuItem = null,
    /// Menu item UI nodes (for highlight style switching)
    item_nodes: [MAX_ITEMS]?*Node = @as([MAX_ITEMS]?*Node, @splat(null)),
    /// Actual rendered item count
    item_count: usize = 0,
    on_select: ?Handler([]const u8),
    /// Request close: goes through Popover toggle pipeline
    close: Handler(void),
    /// Container holding keyboard focus (aria-activedescendant attached to it)
    menu_node: ?*Node = null,
    on_back: ?Handler(void) = null,
    submenu_open: [MAX_ITEMS]?*Signal(bool) = @splat(null),

    pub const MAX_ITEMS = 64;
    /// highlight's "no highlight" value
    const no_highlight = std.math.maxInt(usize);

    fn deinit(self: *MenuState, allocator: Allocator) void {
        if (self.owned_items) |owned| freeItems(allocator, owned);
        self.owned_items = null;
        self.items = &.{};
    }

    /// Select current highlighted item: request close first, then notify on_select, then execute
    /// item's callback.
    /// All callbacks may destroy menu or swap items: extract needed values first, don't touch self
    /// after.
    /// id is borrowed (static items owned by state, signal items by caller), close request may
    /// invalidate it,
    /// so copy; all runs in one batch, effect-driven unmount/rebuild deferred after callbacks.
    pub fn selectHighlighted(self: *MenuState) void {
        if (self.highlighted_index >= self.items.len) return;
        const item = self.items[self.highlighted_index];
        if (item.kind == .separator or item.disabled) return;
        if (item.children.len > 0) {
            if (self.submenu_open[self.highlighted_index]) |open| open.set(true);
            return;
        }
        const on_select = self.on_select;
        const close = self.close;
        const cx = self.cx;

        var id_buf: [256]u8 = undefined;
        var heap_id: ?[]u8 = null;
        defer if (heap_id) |h| cx.allocator.free(h);
        const id: []const u8 = if (item.id.len <= id_buf.len) blk: {
            @memcpy(id_buf[0..item.id.len], item.id);
            break :blk id_buf[0..item.id.len];
        } else blk: {
            heap_id = cx.allocator.dupe(u8, item.id) catch {
                std.log.err("[Menu] out of memory copying item id; selection dropped", .{});
                return;
            };
            break :blk heap_id.?;
        };

        cx.owner.beginBatch();
        defer cx.owner.endBatch();
        close.invoke();
        if (on_select) |h| h.call(id);
        if (item.on_click) |h| h.invoke();
    }

    /// Switch highlight to index
    pub fn highlightIndex(self: *MenuState, index: usize) void {
        if (index >= self.item_count) return;
        if (self.items[index].kind == .separator) return;
        for (self.submenu_open, 0..) |open, i| if (open) |s| if (i != index) s.set(false);

        self.highlighted_index = index;
        // Row view lights up by highlighted (data-driven, no direct node background change)
        self.highlighted.set(index);

        if (self.item_nodes[index]) |node| {
            // Keyboard highlight is "virtual focus", real focus always on menu container, only
            // aria-activedescendant tells AT current item.
            if (self.menu_node) |menu_node| {
                if (menu_node.behavior.interaction.a11y) |*a| {
                    a.active_descendant_element_id = node.element_id_raw;
                }
                menu_node.markRenderDirty();
            }
        }
    }

    fn enterIndex(self: *MenuState, index: usize) void {
        self.keyboard_focus.set(false);
        self.highlightIndex(index);
        if (index < self.item_count and !self.items[index].disabled) if (self.submenu_open[index]) |open| open.set(true);
    }

    /// Rebuild key: content + string address + callback (strings borrowed, address change stales
    /// a11y label on old nodes)
    fn itemsKey(items: []const MenuItem) u64 {
        return itemsKeyDepth(items, 0);
    }
    fn itemsKeyDepth(items: []const MenuItem, depth: usize) u64 {
        if (depth > 8) return 0;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&items.len));
        for (items) |it| {
            hashStr(&h, it.id);
            hashStr(&h, it.label);
            if (it.shortcut) |sc| hashStr(&h, sc) else h.update("\x00");
            h.update(&.{ @backingInt(it.kind), @intFromBool(it.disabled), @intFromBool(it.danger) });
            const icon: usize = if (it.icon_asset) |a| @intFromPtr(a.svg_data.ptr) else 0;
            const child_key = if (it.children.len > 0) itemsKeyDepth(it.children, depth + 1) else 0;
            h.update(std.mem.asBytes(&child_key));
            h.update(std.mem.asBytes(&icon));
            if (it.on_click) |c| {
                h.update(std.mem.asBytes(&@intFromPtr(c.callback)));
                h.update(std.mem.asBytes(&@intFromPtr(c.context)));
            } else h.update("\x00");
        }
        return h.final();
    }

    fn hashStr(h: *std.hash.Wyhash, s: []const u8) void {
        h.update(std.mem.asBytes(&s.len));
        h.update(std.mem.asBytes(&@intFromPtr(s.ptr)));
        h.update(s);
    }

    /// Build menu items. Click context registered on `items_scope`, freed on rebuild;
    /// node table built locally, published only if all succeed (fail case rebuildOn clears subtree,
    /// state stays valid)
    fn buildItems(self: *MenuState, items_scope: *Scope, item_list: *Node, all_items: []const MenuItem) !void {
        const cx = self.cx;

        // Old nodes already freed by rebuildOn: clear references to them first
        self.items = &.{};
        self.item_nodes = @as([MAX_ITEMS]?*Node, @splat(null));
        self.item_count = 0;
        self.submenu_open = @splat(null);
        self.highlighted_index = 0;
        self.highlighted.set(no_highlight);
        if (self.menu_node) |menu_node| {
            if (menu_node.behavior.interaction.a11y) |*a| a.active_descendant_element_id = 0xFFFFFFFF;
        }

        // Only render first MAX_ITEMS; keyboard nav / select limited same range, else can activate
        // invisible items
        const items = all_items[0..@min(all_items.len, MAX_ITEMS)];
        var nodes = @as([MAX_ITEMS]?*Node, @splat(null));
        var submenus: [MAX_ITEMS]?*Signal(bool) = @splat(null);

        try view.mount(items_scope, cx, item_list, view.items(RowCtx{ .state = self, .nodes = &nodes, .submenus = &submenus }, items, rowElement));

        self.item_nodes = nodes;
        self.submenu_open = submenus;
        self.item_count = items.len;
        self.items = items;
    }

    const RowCtx = struct { state: *MenuState, nodes: *[MAX_ITEMS]?*Node, submenus: *[MAX_ITEMS]?*Signal(bool) };
    const RowArgs = struct { ctx: RowCtx, item: MenuItem, index: usize };

    fn rowElement(ctx: RowCtx, item: MenuItem, i: usize) view.ComponentOf(buildRow) {
        return view.component(buildRow, RowArgs{ .ctx = ctx, .item = item, .index = i });
    }

    /// One item (separator or menu item, view in menu.yix); node recorded in caller's local node
    /// table
    fn buildRow(args: RowArgs, scope: *Scope, cx: *Cx) !*Node {
        const item = args.item;
        const state = args.ctx.state;
        const node = if (item.kind == .separator)
            try view.render(scope, cx, views.MenuSeparator(.{}))
        else
            try view.render(scope, cx, views.MenuEntry(.{
                .label = item.label,
                .index = args.index,
                .highlighted = state.highlighted,
                .keyboard_focus = state.keyboard_focus,
                .danger = item.danger,
                .disabled = item.disabled,
                .shortcut = item.shortcut,
                .icon_asset = item.icon_asset,
                .on_pick = Handler(usize).from(MenuState, state, MenuState.pickIndex),
                .on_enter = Handler(usize).from(MenuState, state, MenuState.enterIndex),
            }));
        var orphan = true;
        errdefer if (orphan) cx.destroyDetached(node);
        args.ctx.nodes[args.index] = node;
        if (item.children.len > 0 and !item.disabled) {
            const open = try scope.createSignal(bool, false);
            args.ctx.submenus[args.index] = open;
            const Parent = struct {
                state: *MenuState,
                open: *Signal(bool),
                fn selected(p: *@This(), id: []const u8) void {
                    const close = p.state.close;
                    const notify = p.state.on_select;
                    close.invoke();
                    if (notify) |h| h.call(id);
                }
                fn changed(p: *@This(), value: bool) void {
                    if (!value) {
                        if (p.state.menu_node) |root| p.state.cx.setFocus(root);
                    }
                }
                fn back(p: *@This()) void {
                    p.open.set(false);
                    if (p.state.menu_node) |root| p.state.cx.setFocus(root);
                }
            };
            const parent = try scope.createState(Parent, .{ .state = state, .open = open });
            const arrow = try view.render(scope, cx, view.icon(.{ .style = .{ .width = 12, .height = 12 } }, @import("zenit_system_icons").chevron_right));
            _ = try core.adoptChild(cx, cx.allocator, node, arrow);
            if (node.behavior.interaction.a11y) |*a| a.has_popup = .menu;
            const nested = try Menu(.{ .trigger = .manual, .items = item.children, .open = open, .on_open_change = Handler(bool).from(Parent, parent, Parent.changed), .position = .right_start, .on_select = Handler([]const u8).from(Parent, parent, Parent.selected), .on_back = cx.on(Parent, parent, Parent.back) }).mount(scope, cx);
            errdefer cx.destroyDetached(nested.wrapper);
            // Nested rows fill the panel, unlike a fit-content toolbar trigger.
            try nested.wrapper.setStyleInlineFallible(cx.allocator, .{ .width = core.Sizing.fill() });
            try nested.trigger.setStyleInlineFallible(cx.allocator, .{ .width = core.Sizing.fill() });
            orphan = false; // adoptChild owns the row even when append fails
            _ = try core.adoptChild(cx, cx.allocator, nested.trigger, node);
            return nested.wrapper;
        }
        orphan = false;
        return node;
    }

    /// Click item: highlight it and select
    fn pickIndex(self: *MenuState, index: usize) void {
        self.highlighted_index = index;
        self.selectHighlighted();
    }
};

/// Create Menu: `W.Menu(.{ .items = &items, .on_select = cx.on(S, s, S.run) })`
pub fn Menu(props: anytype) MenuBuilder {
    return .{ .props = reactive.props.coerce(MenuProps, props) };
}

pub const MenuBuilder = struct {
    props: MenuProps,

    /// Retained mode: mount
    pub fn mount(self: MenuBuilder, scope: *Scope, cx: *Cx) !MenuResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const p = self.props;

        var pop_result = try popover_mod.Popover(.{
            .position = p.position,
            .trigger = p.trigger,
            .width = p.width,
            .max_width = if (p.max_height != null) p.width else null,
            .max_height = p.max_height,
            .size_policy = @as(popover_mod.SizePolicy, if (p.max_height != null) .fit_or_scroll else .hard_clip),
            .constrain_width_to_viewport = true,
            .open = p.open,
            .on_open_change = p.on_open_change,
        }).mount(scope, cx);
        // All menu resources and effects owned by Popover scope (on wrapper): menu content in
        // portal,
        // freed with it on unmount; effects on other scopes wake from external signals, write freed
        // nodes
        // sweep: wrapper holds until return (with Popover scope dispose); adopt subtree after build
        errdefer cx.freeNode(pop_result.wrapper);
        const menu_scope = pop_result.scope;

        pop_result.wrapper.meta.ownership.meta.component_name = "Menu";

        // ---- State ----
        // Do failables first: no fail points between create and adoptResource
        const highlighted = try menu_scope.createSignal(usize, MenuState.no_highlight);
        const keyboard_focus = try menu_scope.createSignal(bool, false);
        const state = try menu_scope.allocator.create(MenuState);
        state.* = .{
            .cx = cx,
            .on_select = p.on_select,
            .on_back = p.on_back,
            .close = pop_result.close,
            .highlighted = highlighted,
            .keyboard_focus = keyboard_focus,
        };
        // adoptResource fails, self-destroy (with owned_items)
        try menu_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const st: *MenuState = @ptrCast(@alignCast(ptr));
                st.deinit(alloc);
                alloc.destroy(st);
            }
        }.cleanup);
        pop_result.wrapper.addDebugState(@ptrCast(state));

        var items = p.items;
        if (p.items == .value) {
            state.owned_items = try cloneItems(menu_scope.allocator, p.items.value[0..@min(p.items.value.len, MenuState.MAX_ITEMS)]);
            items = .{ .value = state.owned_items.? };
        }

        // ---- Menu Items ----
        var item_list: *Node = undefined;
        try view.mount(menu_scope, cx, pop_result.content, view.capture(&item_list, view.box(.{ .style = styles.list }, {})));
        // The focusable popover content owns the menu role and active
        // descendant. Keeping those on the same node makes VoiceOver's
        // focusedUIElement query resolve the highlighted item; the visual
        // item_list remains an unprojected layout wrapper.
        pop_result.content.behavior.interaction.a11y = .{ .role = .menu };
        state.menu_node = pop_result.content;
        pop_result.content.setFocusable(true);

        try bind_mod.rebuildOn(cx, menu_scope, items, item_list, state, MenuState.itemsKey, MenuState.buildItems);

        // Keyboard navigation
        pop_result.content.behavior.events.on_key_down = menuKeyHandler;
        pop_result.content.behavior.events.key_context = @ptrCast(state);

        // On open, give focus to menu content (keyboard nav attached to it)
        try menu_scope.createEffect(.{
            .open = pop_result.open_read,
            .content = pop_result.content,
            .state = state,
            .cx = cx,
        }, struct {
            fn update(c: anytype) void {
                const open = c.open.get();
                if (open and !c.state.was_open) {
                    c.state.keyboard_focus.set(false);
                    c.state.previous_focus = if (c.cx.focused_node) |node| c.cx.node_registry.handleFor(node) else null;
                    c.cx.setFocus(c.content);
                } else if (!open and c.state.was_open) {
                    for (c.state.submenu_open) |submenu| if (submenu) |child| child.set(false);
                    if (c.state.on_back == null or c.cx.focus_manager.getFocused() == c.content) {
                        if (c.state.previous_focus) |handle| if (c.cx.node_registry.resolve(handle, null)) |node| c.cx.setFocus(node);
                    }
                    c.state.previous_focus = null;
                }
                c.state.was_open = open;
            }
        }.update);

        return .{
            .wrapper = pop_result.wrapper,
            .trigger = pop_result.trigger,
            .open = pop_result.open,
        };
    }
};

fn cloneItems(allocator: Allocator, source: []const MenuItem) ![]MenuItem {
    return cloneItemsDepth(allocator, source, 0);
}
fn cloneItemsDepth(allocator: Allocator, source: []const MenuItem, depth: usize) ![]MenuItem {
    if (depth > 8) return error.MenuNestingTooDeep;
    const cloned = try allocator.alloc(MenuItem, source.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |item| {
        allocator.free(item.id);
        allocator.free(item.label);
        if (item.shortcut) |shortcut| allocator.free(shortcut);
        if (item.children.len > 0) freeItems(allocator, @constCast(item.children));
    };

    for (source, 0..) |item, index| {
        const id = try allocator.dupe(u8, item.id);
        errdefer allocator.free(id);
        const label = try allocator.dupe(u8, item.label);
        errdefer allocator.free(label);
        const shortcut = if (item.shortcut) |value| try allocator.dupe(u8, value) else null;
        errdefer if (shortcut) |text| allocator.free(text);
        const children: []const MenuItem = if (item.children.len > 0) try cloneItemsDepth(allocator, item.children, depth + 1) else &.{};
        cloned[index] = item;
        cloned[index].id = id;
        cloned[index].label = label;
        cloned[index].shortcut = shortcut;
        cloned[index].children = children;
        initialized += 1;
    }
    return cloned;
}

fn freeItems(allocator: Allocator, items: []MenuItem) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.label);
        if (item.shortcut) |shortcut| allocator.free(shortcut);
        if (item.children.len > 0) freeItems(allocator, @constCast(item.children));
    }
    allocator.free(items);
}

// ========== Internal helpers ==========

/// From `from` in direction, find next selectable item index, skip separator and disabled, wrap at
/// boundary.
/// Returns null if no items selectable.
fn nextEnabledIndex(items: []const MenuItem, from: usize, forward: bool) ?usize {
    const len = items.len;
    if (len == 0) return null;
    var idx = from;
    var count: usize = 0;
    while (count < len) : (count += 1) {
        if (forward) {
            idx = if (idx + 1 >= len) 0 else idx + 1;
        } else {
            idx = if (idx == 0) len - 1 else idx - 1;
        }
        if (items[idx].kind == .item and !items[idx].disabled) return idx;
    }
    return null;
}

/// Keyboard navigation handler
fn menuKeyHandler(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const state: *MenuState = @ptrCast(@alignCast(context.?));

    switch (key) {
        .right => {
            if (state.highlighted_index < state.items.len and state.items[state.highlighted_index].children.len > 0) state.selectHighlighted();
            return .stop;
        },
        .left => {
            if (state.on_back) |h| h.invoke();
            return .stop;
        },
        .down => {
            state.keyboard_focus.set(true);
            if (nextEnabledIndex(state.items, state.highlighted_index, true)) |idx| {
                state.highlightIndex(idx);
            }
            return .stop;
        },
        .up => {
            state.keyboard_focus.set(true);
            if (nextEnabledIndex(state.items, state.highlighted_index, false)) |idx| {
                state.highlightIndex(idx);
            }
            return .stop;
        },
        .@"return" => {
            state.selectHighlighted();
            return .stop;
        },
        .escape => {
            if (state.on_back) |h| h.invoke() else state.close.invoke();
            return .stop;
        },
        else => return .ignored,
    }
}

// ========== Tests ==========

fn stateOf(r: MenuResult) *MenuState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

const test_items = [_]MenuItem{
    .{ .id = "cut", .label = "Cut", .shortcut = "\xe2\x8c\x98X", .icon_asset = svg_assets.common.star }, // ⌘X
    .{ .id = "copy", .label = "Copy", .shortcut = "\xe2\x8c\x98C" }, // ⌘C
    .{ .kind = .separator },
    .{ .id = "paste", .label = "Paste", .shortcut = "\xe2\x8c\x98V" }, // ⌘V
    .{ .id = "delete", .label = "Delete", .danger = true },
    .{ .id = "disabled_item", .label = "Unavailable", .disabled = true },
};

/// Test helper: on_select id valid only in callback, copy to keep for assertion
const Picked = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,
    fn set(self: *Picked, id: []const u8) void {
        @memcpy(self.buf[0..id.len], id);
        self.len = id.len;
    }
    fn get(self: *const Picked) []const u8 {
        return self.buf[0..self.len];
    }
};

const TestEnv = struct {
    ctx: *Cx,
    root: *Node,
    scope: *Scope,

    fn init() !TestEnv {
        const ctx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer ctx.deinit();
        const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 1200 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
        return .{ .ctx = ctx, .root = root, .scope = scope };
    }

    fn deinit(self: TestEnv) void {
        self.scope.dispose();
        self.ctx.deinit();
    }

    fn mount(self: TestEnv, props: anytype) !MenuResult {
        const r = try Menu(props).mount(self.scope, self.ctx);
        try self.root.appendChild(std.testing.allocator, r.wrapper);
        return r;
    }
};

test "MenuItemRecipe: disabled 压过 danger 与虚拟高亮；图标着色跟随文字" {
    const t = &theme.dark;
    const normal = MenuItemRecipe.resolve(.{ .danger = false, .lit = false, .disabled = false }, t);
    try std.testing.expectEqual(t.tokens.color.fg_primary, normal.label.base.text_color.?);
    try std.testing.expectEqual(t.tokens.color.fg_primary, normal.icon.base.icon_color.?);
    const danger = MenuItemRecipe.resolve(.{ .danger = true, .lit = false, .disabled = false }, t);
    try std.testing.expectEqual(t.tokens.color.danger, danger.label.base.text_color.?);
    try std.testing.expectEqual(t.tokens.color.danger, danger.icon.base.icon_color.?);
    const lit = MenuItemRecipe.resolve(.{ .danger = false, .lit = true, .disabled = false }, t);
    try std.testing.expectEqual(t.tokens.color.list_hover_bg, lit.root.base.background.?);
    const dis = MenuItemRecipe.resolve(.{ .danger = true, .lit = true, .disabled = true }, t);
    try std.testing.expectEqual(t.tokens.color.fg_disabled, dis.label.base.text_color.?);
    try std.testing.expect(dis.root.base.background == null or !std.meta.eql(dis.root.base.background.?, t.tokens.color.list_hover_bg));
}

test "Menu: basic structure" {
    const env = try TestEnv.init();
    defer env.deinit();
    const result = try env.mount(.{ .items = &test_items });
    try std.testing.expectEqual(@as(usize, 6), stateOf(result).item_count);
    // Icon item: icon + text two children in left group
    const left = stateOf(result).item_nodes[0].?.children.items[0];
    try std.testing.expectEqual(@as(usize, 2), left.children.items.len);
}

test "Menu: static items are copied with their strings — the caller's array may go away" {
    const env = try TestEnv.init();
    defer env.deinit();

    var picked = Picked{};
    var local_items = [_]MenuItem{
        .{ .id = "local", .label = "Local item", .shortcut = "Cmd-L" },
    };
    const result = try env.mount(.{ .items = &local_items, .on_select = env.ctx.on(Picked, &picked, Picked.set) });

    const items = stateOf(result).items;
    try std.testing.expect(items.ptr != local_items[0..].ptr);
    try std.testing.expect(items[0].id.ptr != local_items[0].id.ptr);
    try std.testing.expect(items[0].label.ptr != local_items[0].label.ptr);
    try std.testing.expect(items[0].shortcut.?.ptr != local_items[0].shortcut.?.ptr);
    local_items[0] = .{ .id = "changed", .label = "Changed" };
    stateOf(result).selectHighlighted();
    try std.testing.expectEqualStrings("local", picked.get());
    try std.testing.expectEqualStrings("Local item", items[0].label);
    try std.testing.expectEqualStrings("Cmd-L", items[0].shortcut.?);
}

test "Menu: state and keyboard navigation are capped to rendered items" {
    const env = try TestEnv.init();
    defer env.deinit();

    var many_items: [MenuState.MAX_ITEMS + 1]MenuItem = undefined;
    for (&many_items) |*item| item.* = .{ .id = "item", .label = "Item" };
    const result = try env.mount(.{ .items = &many_items });
    try std.testing.expectEqual(MenuState.MAX_ITEMS, stateOf(result).items.len);
    try std.testing.expectEqual(MenuState.MAX_ITEMS, stateOf(result).item_count);

    stateOf(result).highlighted_index = MenuState.MAX_ITEMS - 1;
    _ = menuKeyHandler(.down, .{}, @ptrCast(stateOf(result)));
    try std.testing.expectEqual(@as(usize, 0), stateOf(result).highlighted_index);
    _ = menuKeyHandler(.up, .{}, @ptrCast(stateOf(result)));
    try std.testing.expectEqual(MenuState.MAX_ITEMS - 1, stateOf(result).highlighted_index);
}

test "Menu: keyboard navigation skips separator and disabled" {
    const env = try TestEnv.init();
    defer env.deinit();
    const result = try env.mount(.{ .items = &test_items });
    const st = stateOf(result);

    _ = menuKeyHandler(.down, .{}, @ptrCast(st));
    try std.testing.expectEqual(@as(usize, 1), st.highlighted_index);
    // Foundations keyboard focus: 2px ring + 2px offset on the virtual row.
    const outline = st.item_nodes[1].?.style.outline().?;
    try std.testing.expectEqual(@as(f32, 2), outline.width);
    try std.testing.expectEqual(@as(f32, 2), outline.offset);
    try std.testing.expectEqual(env.ctx.tokens.tokens.color.focus_ring, outline.color);
    st.enterIndex(1);
    try std.testing.expect(st.item_nodes[1].?.style.outline() == null);
    // Skip separator (index 2)
    _ = menuKeyHandler(.down, .{}, @ptrCast(st));
    try std.testing.expectEqual(@as(usize, 3), st.highlighted_index);
    _ = menuKeyHandler(.down, .{}, @ptrCast(st));
    try std.testing.expectEqual(@as(usize, 4), st.highlighted_index);
    // Skip disabled (index 5), wrap to index 0
    _ = menuKeyHandler(.down, .{}, @ptrCast(st));
    try std.testing.expectEqual(@as(usize, 0), st.highlighted_index);
}

test "Menu: select closes the menu, then reports the id, then runs the item command" {
    const env = try TestEnv.init();
    defer env.deinit();

    const Probe = struct {
        open: ?*Signal(bool) = null,
        log: [4]u8 = undefined,
        len: usize = 0,
        fn select(self: *@This(), id: []const u8) void {
            // Close request comes first: toggle now settled to false
            if (self.open.?.peek()) self.log[self.len] = 'X' else self.log[self.len] = id[0];
            self.len += 1;
        }
        fn run(self: *@This()) void {
            self.log[self.len] = '!';
            self.len += 1;
        }
    };
    var probe = Probe{};
    const items = [_]MenuItem{.{ .id = "go", .label = "Go", .on_click = env.ctx.on(Probe, &probe, Probe.run) }};
    const result = try env.mount(.{ .items = &items, .on_select = env.ctx.on(Probe, &probe, Probe.select) });
    probe.open = result.open;
    result.open.?.set(true);
    stateOf(result).selectHighlighted();
    try std.testing.expect(!result.open.?.peek());
    try std.testing.expectEqualStrings("g!", probe.log[0..probe.len]);
}

test "Menu: escape closes menu" {
    const env = try TestEnv.init();
    defer env.deinit();
    const result = try env.mount(.{ .items = &test_items });
    result.open.?.set(true);
    _ = menuKeyHandler(.escape, .{}, @ptrCast(stateOf(result)));
    try std.testing.expect(!result.open.?.peek());
}

test "Menu: a split parent can refuse to close; on_select and the command still run" {
    const env = try TestEnv.init();
    defer env.deinit();

    const Parent = struct {
        open: *Signal(bool),
        pinned: bool = true,
        picked: Picked = .{},
        runs: u32 = 0,
        fn write(self: *@This(), v: bool) void {
            if (!v and self.pinned) return; // Reject close when pinned
            self.open.set(v);
        }
        fn select(self: *@This(), id: []const u8) void {
            self.picked.set(id);
        }
        fn run(self: *@This()) void {
            self.runs += 1;
        }
    };
    var parent = Parent{ .open = try env.scope.createSignal(bool, true) };
    const items = [_]MenuItem{
        .{ .id = "cut", .label = "Cut" },
        .{ .id = "copy", .label = "Copy", .on_click = env.ctx.on(Parent, &parent, Parent.run) },
    };
    const result = try env.mount(.{
        .items = &items,
        .open = reactive.split(parent.open, env.ctx.on(Parent, &parent, Parent.write)),
        .on_select = env.ctx.on(Parent, &parent, Parent.select),
    });
    try std.testing.expect(result.open == null);

    _ = menuKeyHandler(.down, .{}, @ptrCast(stateOf(result))); // -> copy
    _ = menuKeyHandler(.@"return", .{}, @ptrCast(stateOf(result)));
    try std.testing.expectEqualStrings("copy", parent.picked.get());
    try std.testing.expectEqual(@as(u32, 1), parent.runs);
    try std.testing.expect(parent.open.peek()); // Parent rejected close
    _ = menuKeyHandler(.escape, .{}, @ptrCast(stateOf(result)));
    try std.testing.expect(parent.open.peek());

    parent.pinned = false;
    _ = menuKeyHandler(.escape, .{}, @ptrCast(stateOf(result)));
    try std.testing.expect(!parent.open.peek());
}

test "Menu: a parent that unmounts the menu while closing still gets the right id" {
    const env = try TestEnv.init();
    defer env.deinit();

    const Parent = struct {
        env: TestEnv,
        open: *Signal(bool),
        wrapper: ?*Node = null,
        picked: [16]u8 = undefined,
        picked_len: usize = 0,
        runs: u32 = 0,
        fn write(self: *@This(), v: bool) void {
            self.open.set(v);
            // Close syncs unmount: menu's items copy (with id strings) freed
            if (!v) if (self.wrapper) |w| {
                self.env.ctx.detachChild(self.env.root, w);
                self.env.ctx.freeNode(w);
                self.wrapper = null;
            };
        }
        fn select(self: *@This(), id: []const u8) void {
            @memcpy(self.picked[0..id.len], id);
            self.picked_len = id.len;
        }
        fn run(self: *@This()) void {
            self.runs += 1;
        }
    };
    var parent = Parent{ .env = env, .open = try env.scope.createSignal(bool, true) };
    var items = [_]MenuItem{.{ .id = "copy", .label = "Copy", .on_click = env.ctx.on(Parent, &parent, Parent.run) }};
    const result = try env.mount(.{
        .items = &items,
        .open = reactive.split(parent.open, env.ctx.on(Parent, &parent, Parent.write)),
        .on_select = env.ctx.on(Parent, &parent, Parent.select),
    });
    parent.wrapper = result.wrapper;
    stateOf(result).selectHighlighted();
    try std.testing.expect(parent.wrapper == null);
    try std.testing.expectEqualStrings("copy", parent.picked[0..parent.picked_len]);
    try std.testing.expectEqual(@as(u32, 1), parent.runs);
}

test "Menu: items from a signal rebuild when a new array is set" {
    const env = try TestEnv.init();
    defer env.deinit();

    var picked = Picked{};
    const first = [_]MenuItem{
        .{ .id = "a", .label = "A" },
        .{ .kind = .separator },
        .{ .id = "b", .label = "B" },
        .{ .id = "c", .label = "C" },
    };
    const second = [_]MenuItem{.{ .id = "z", .label = "Z" }};
    const items = try env.scope.createSignal([]const MenuItem, &first);
    const result = try env.mount(.{ .items = items, .on_select = env.ctx.on(Picked, &picked, Picked.set) });
    const st = stateOf(result);
    try std.testing.expectEqual(@as(usize, 4), st.item_count);
    // Caller-scope signal lent to Popover scope: latter parented below former, borrow valid
    if (reactive.SignalOwner.debug_checks)
        try std.testing.expectEqual(@as(u32, 0), env.ctx.owner.debug.borrow_warnings);

    // Highlight past end, swap to shorter array: highlight back to start, no overflow, no stale
    // active_descendant on old nodes
    st.highlightIndex(3);
    items.set(&second);
    try std.testing.expectEqual(@as(usize, 1), st.item_count);
    try std.testing.expectEqual(@as(usize, 1), st.items.len);
    try std.testing.expectEqual(@as(usize, 0), st.highlighted_index);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), st.menu_node.?.behavior.interaction.a11y.?.active_descendant_element_id);
    try std.testing.expect(st.item_nodes[1] == null);
    st.selectHighlighted();
    try std.testing.expectEqualStrings("z", picked.get());
    // Menu panel now holds only the new item
    try std.testing.expectEqual(@as(usize, 1), st.item_nodes[0].?.parent.?.children.items.len);
}

test "Menu: rebuild key ignores array identity but sees borrowed string addresses and handlers" {
    var copy = test_items;
    try std.testing.expectEqual(MenuState.itemsKey(&test_items), MenuState.itemsKey(&copy));
    // Different string address of same content: old nodes' a11y label borrows old address, must
    // rebuild
    var label_buf = "Cut".*;
    copy[0].label = &label_buf;
    try std.testing.expect(MenuState.itemsKey(&test_items) != MenuState.itemsKey(&copy));
    // Context changed (same function, different object) requires rebuild, else click calls old
    // object
    const noop = struct {
        fn f(_: *anyopaque) void {}
    }.f;
    var n1: u32 = 0;
    var n2: u32 = 0;
    copy = test_items;
    copy[1].on_click = core.HandlerRef{ .callback = noop, .context = @ptrCast(&n1) };
    var other = copy;
    other[1].on_click = core.HandlerRef{ .callback = noop, .context = @ptrCast(&n2) };
    try std.testing.expect(MenuState.itemsKey(&other) != MenuState.itemsKey(&copy));
    try std.testing.expect(MenuState.itemsKey(&test_items) != MenuState.itemsKey(&copy));
}

test "Menu: with an external open signal, unmount leaves no live effect behind" {
    const env = try TestEnv.init();
    defer env.deinit();
    const open = try env.scope.createSignal(bool, false);
    const items = try env.scope.createSignal([]const MenuItem, &test_items);
    const before = env.ctx.owner.graph.countByKind().get(.effect);
    const result = try env.mount(.{ .items = items, .open = open });
    env.ctx.detachChild(env.root, result.wrapper);
    env.ctx.freeNode(result.wrapper);
    // Focus effect reads external open, rebuild effect reads external items: both must destroy with
    // Popover scope,
    // else write below touches freed menu content
    try std.testing.expectEqual(before, env.ctx.owner.graph.countByKind().get(.effect));
    open.set(true);
    items.set(test_items[0..1]);
}

test "Menu: 卸载 wrapper 即回收菜单资源（不必等调用方 scope 释放）" {
    const env = try TestEnv.init();
    defer env.deinit();
    const before = env.scope.resources.items.len;
    const result = try env.mount(.{ .items = &test_items });
    env.ctx.detachChild(env.root, result.wrapper);
    env.ctx.freeNode(result.wrapper);
    // Menu leaves no resources on caller scope
    try std.testing.expectEqual(before, env.scope.resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), env.scope.children.items.len);
}

test "nextEnabledIndex 跳过 separator 与 disabled，到边界回绕" {
    const items = [_]MenuItem{ .{}, .{ .kind = .separator }, .{ .disabled = true }, .{} };
    try std.testing.expectEqual(@as(?usize, 3), nextEnabledIndex(&items, 0, true));
    try std.testing.expectEqual(@as(?usize, 0), nextEnabledIndex(&items, 3, true));
    try std.testing.expectEqual(@as(?usize, 0), nextEnabledIndex(&items, 3, false));
    // With one selectable item, wrap to self
    const single = [_]MenuItem{ .{ .kind = .separator }, .{}, .{ .disabled = true } };
    try std.testing.expectEqual(@as(?usize, 1), nextEnabledIndex(&single, 1, true));
    try std.testing.expectEqual(@as(?usize, 1), nextEnabledIndex(&single, 1, false));
}

test "nextEnabledIndex 全不可选或空列表时返回 null" {
    const none = [_]MenuItem{ .{ .kind = .separator }, .{ .disabled = true } };
    try std.testing.expectEqual(@as(?usize, null), nextEnabledIndex(&none, 0, true));
    try std.testing.expectEqual(@as(?usize, null), nextEnabledIndex(&none, 0, false));
    try std.testing.expectEqual(@as(?usize, null), nextEnabledIndex(&.{}, 0, true));
}

// Test collection from styles.yss, this line required, see docs/STYLING.md
test {
    _ = @import("_styles.yss.zig");
}

// OOM sweep at each allocation point, see src/ui/components/oom_sweep.zig
test "Menu: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("menu", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Menu(.{ .items = &test_items }).mount(scope, cx)).wrapper;
        }
    }.m);
    try sw.sweepMount("menu_signal_items", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const items = try scope.createSignal([]const MenuItem, &test_items);
            return (try Menu(.{ .items = items, .max_height = 120 }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "Menu: nested navigation, ancestor close and focus restoration" {
    const env = try TestEnv.init();
    defer env.deinit();
    const open = try env.scope.createSignal(bool, false);
    const result = try env.mount(.{ .items = &[_]MenuItem{.{ .id = "file", .label = "File", .children = &.{.{ .id = "new", .label = "New" }} }}, .open = open });
    try env.ctx.node_registry.rebuild(env.root);
    result.trigger.setFocusable(true);
    env.ctx.setFocus(result.trigger);
    open.set(true);
    const parent = stateOf(result);
    const child_open = parent.submenu_open[0].?;
    parent.highlightIndex(0);
    try std.testing.expect(!child_open.peek());
    _ = menuKeyHandler(.right, .{}, parent);
    try std.testing.expect(child_open.peek());
    open.set(false);
    try std.testing.expect(!child_open.peek());
    try std.testing.expectEqual(result.trigger, env.ctx.focused_node.?);
}

test "Menu: nested mount failures release rows, portal scopes and copied children" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("nested_menu", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Menu(.{ .items = &[_]MenuItem{.{ .id = "file", .label = "File", .children = &.{.{ .id = "new", .label = "New", .children = &.{.{ .id = "leaf", .label = "Leaf" }} }} }} }).mount(scope, cx)).wrapper;
        }
    }.m);
}
