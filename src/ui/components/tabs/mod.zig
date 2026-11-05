/// Tabs component with multiple variants and keyboard navigation.
///
/// Features:
/// - Signal-first: items as Source, active as Model (string uncontrolled / signal controlled /
///   split)
/// - View = f(items, active): an effect rebuilds tabs and selected state;
///   highlight box geometry follows layout in before_render
/// - Event-driven: click events via on_event switch tabs
/// - Focusable, keyboard left/right navigation
/// - Variants: underline, pill, icon (x size: sm, md)
/// - Icon variant supports Lucide SVG icons
/// - Closeable tabs
/// - on_change / on_close callbacks
const control_shell = @import("../control_shell/mod.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const ui_view = @import("../../view.zig");
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
const reactive = @import("../../reactive.zig");
const bind_mod = @import("../../bind.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const ConditionalStyle = core.ConditionalStyle;
const StyleOverride = core.StyleOverride;
const recipe_mod = @import("../../recipe.zig");
const svg_assets = @import("../../svg_assets.zig");

// Type definitions

/// Tabs variant
pub const TabsVariant = enum {
    underline,
    pill,
    tab,
};

/// Tabs size, uniformly uses ControlSize 4-step
pub const TabsSize = control_shell.ControlSize;

/// Tab item
pub const TabItem = struct {
    id: []const u8,
    label: []const u8,
    icon_asset: ?svg_assets.Asset = null,
    disabled: bool = false,
    closable: bool = false,
    badge: ?u32 = null,
};

// Style layer (TabsSlotRecipe + variant×size spec table)
// exported from styles.zig; re-export keeps public API stable.
const styles = @import("styles.zig");
pub const TabsSlotRecipe = styles.TabsSlotRecipe;

// Tabs runtime (Signal-first, docs/SIGNAL_API_DESIGN.md)

/// Click context per Tab (belongs to current tab subtree scope)
pub const TabClickContext = struct {
    rt: *TabsRuntime,
    tab_index: usize,
};

/// Tabs runtime state (owned by scope)
///
/// View = f(items, active): effect rebuilds tabs on items change, parses active id to index,
/// refreshes text/icon/a11y; highlight box geometry depends on layout, still tracked each frame in
/// before_render.
pub const TabsRuntime = struct {
    active: reactive.Bound(?[]const u8),
    items: Source([]const TabItem),
    /// Shallow copy of static items (re-read at click; caller array may be stack-allocated)
    owned_items: []TabItem = &.{},
    on_change: ?Handler([]const u8),
    on_close: ?Handler([]const u8),
    variant: TabsVariant,
    size: TabsSize,
    closable: bool,
    block: bool = false,
    tokens: *const theme.ThemeTokens,
    /// The view effect reads it: a theme switch re-resolves the slots and rebuilds the tabs.
    theme: *reactive.Signal(*const theme.ThemeTokens),
    allocator: Allocator,
    cx: *Cx,
    scope: *Scope,
    tab_row: *Node,
    highlight_box: *Node,
    /// Underline variant's bottom rule (null for the other variants)
    separator: ?*Node = null,
    slots: TabsSlotRecipe.Slots,
    /// Scope of current tab subtree (hover hook, click context), whole rebuild when items change
    tabs_scope: ?*Scope = null,
    item_count: usize = 0,
    built_key: ?u64 = null,
    /// Current active index (highlight box in before_render reads it)
    active_index: usize = 0,
    /// Index text style applied to
    shown_index: usize = std.math.maxInt(usize),
    /// Skip highlight box transition on first frame, position directly
    first_render: bool = true,

    /// Rebuild key: content + string address. Nodes borrow label slice itself; derived source
    /// recomputation may return same content, different address (old freed later), must rebuild
    /// then.
    fn itemsKey(items: []const TabItem) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&items.len));
        for (items) |it| {
            h.update(std.mem.asBytes(&it.id.len));
            h.update(it.id);
            h.update(std.mem.asBytes(&it.label.len));
            h.update(it.label);
            h.update(std.mem.asBytes(&@intFromPtr(it.id.ptr)));
            h.update(std.mem.asBytes(&@intFromPtr(it.label.ptr)));
            h.update(std.mem.asBytes(&it.badge));
            h.update(&[_]u8{ @intFromBool(it.disabled), @intFromBool(it.closable), @intFromBool(it.icon_asset != null) });
        }
        return h.final();
    }

    fn indexOf(items: []const TabItem, id: ?[]const u8) usize {
        const want = id orelse return 0;
        for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.id, want)) return i;
        }
        return 0;
    }

    /// View = f(items, active). mount snapshot passes false, effect passes true.
    fn view(self: *TabsRuntime, comptime tracked: bool) !void {
        const t = if (tracked) self.theme.get() else self.theme.peek();
        if (t != self.tokens) self.applyTheme(t);
        const items = self.items.read(tracked);
        const index = indexOf(items, self.active.readAs(tracked));
        const key = itemsKey(items);
        if (self.built_key == null or self.built_key.? != key) {
            // Clear first: if rebuild fails partway, next view must retry
            self.built_key = null;
            try self.cx.owner.untrack(rebuild, .{ self, items, index });
            self.built_key = key;
            self.shown_index = index;
        }
        self.active_index = index;
        if (index != self.shown_index) {
            self.applyActiveStyles(items, index);
            self.shown_index = index;
        }
        self.tab_row.markRenderDirty();
    }

    /// Theme switch: re-resolve the slots, restyle the row, slider and rule, and drop the built
    /// key so the tabs rebuild with the new colors (as a fresh mount would build them).
    fn applyTheme(self: *TabsRuntime, t: *const theme.ThemeTokens) void {
        self.tokens = t;
        self.slots = TabsSlotRecipe.resolve(.{ .variant = self.variant, .size = self.size }, t);
        self.tab_row.setStyleInline(self.allocator, tabRowStyle(self.slots, self.block));
        self.highlight_box.setStyleInline(self.allocator, highlightStyle(self.slots, self.variant == .underline));
        if (self.separator) |rule| rule.setBackground(t.tokens.color.separator);
        self.built_key = null;
        self.shown_index = std.math.maxInt(usize);
    }

    fn viewEffect(self: *TabsRuntime) void {
        self.view(true) catch |err| std.log.err("[Tabs] update failed: {}", .{err});
    }

    fn applyActiveStyles(self: *TabsRuntime, items: []const TabItem, index: usize) void {
        const t = self.tokens;
        const tab_style = self.slots.tab.resolve(.{});
        const active_style = self.slots.tab.resolve(.{ .is_selected = true });
        const children = self.tab_row.children.items;
        const count = @min(self.item_count, children.len -| 1);
        for (children[1 .. 1 + count], 0..) |tab_node, i| {
            const is_active = i == index;
            // aria-selected tracks current active tab: VoiceOver uses it to determine 'which tab am
            // I on'
            if (tab_node.behavior.interaction.a11y) |*a| a.selected = is_active;
            if (i < items.len and items[i].disabled) continue;
            const resolved = if (is_active) active_style else tab_style;
            const text_color = resolved.text_color orelse t.tokens.color.fg_secondary;
            const icon_tint = if (is_active and self.variant != .underline) t.tokens.color.accent else t.tokens.color.fg_secondary;
            updateTabDescendants(tab_node, text_color, icon_tint, is_active);
        }
    }

    fn rebuild(args: struct { *TabsRuntime, []const TabItem, usize }) !void {
        const self = args[0];
        const items = args[1];
        const index = args[2];
        self.teardownTabs();
        const tabs_scope = try self.scope.childScope();
        self.tabs_scope = tabs_scope;
        // Failure partway: half-built tabs unload with their hooks
        errdefer self.teardownTabs();
        try ui_view.mount(tabs_scope, self.cx, self.tab_row, ui_view.items(TabRowCtx{ .rt = self, .active = index }, items, tabElement));
        self.item_count = items.len;
        // New tab geometry unknown: highlight box positioned directly on first frame
        self.first_render = true;
    }

    const TabRowCtx = struct { rt: *TabsRuntime, active: usize };

    fn tabElement(c: TabRowCtx, item: TabItem, i: usize) ui_view.ComponentOf(buildTab) {
        const self = c.rt;
        return ui_view.component(buildTab, TabBuildArgs{
            .rt = self,
            .tab_index = i,
            .variant = self.variant,
            .size = self.size,
            .item = item,
            .is_active = i == c.active,
            .is_disabled = item.disabled,
            .show_close = item.closable or self.closable,
            .block = self.block,
            .slots = self.slots,
        });
    }

    /// Unload current tab (standard order: invalidate hooks -> dispose scope -> unlink free)
    fn teardownTabs(self: *TabsRuntime) void {
        const children = self.tab_row.children.items;
        const count = @min(self.item_count, children.len -| 1);
        for (children[1 .. 1 + count]) |tab_node| hooks.invalidateSubtreeHookState(tab_node);
        if (self.tabs_scope) |sc| sc.dispose();
        self.tabs_scope = null;
        var i = count;
        while (i > 0) : (i -= 1) {
            const tab_node = self.tab_row.children.items[i];
            core.clearNodeScopes(tab_node);
            self.cx.detachChild(self.tab_row, tab_node);
            self.cx.freeNode(tab_node);
        }
        self.item_count = 0;
    }

    fn select(self: *TabsRuntime, index: usize) void {
        const items = self.items.peek();
        if (index >= items.len or items[index].disabled) return;
        // Click on what's already shown as selected (including active null / not in items, falls
        // back to first): visual unchanged, no proposal, no on_change
        if (index == self.active_index) return;
        if (self.active.commit(items[index].id)) |landed| {
            if (landed) |id| {
                if (self.on_change) |h| h.call(id);
            }
        }
    }

    /// Arrow keys: skip disabled items, cycle
    fn move(self: *TabsRuntime, forward: bool) void {
        const items = self.items.peek();
        if (items.len == 0) return;
        // active_index from last successful view: within same batch items may shrink or rebuild
        // fails, may exceed current items, reverse branch has no modulo guard
        var i = @min(self.active_index, items.len - 1);
        for (0..items.len) |_| {
            i = if (forward) (i + 1) % items.len else (if (i == 0) items.len - 1 else i - 1);
            if (!items[i].disabled) return self.select(i);
        }
    }

    fn close(self: *TabsRuntime, index: usize) void {
        const items = self.items.peek();
        if (index >= items.len) return;
        if (self.on_close) |h| h.call(items[index].id);
    }
};

/// tab_row: row container for all tabs + highlight_box, geometry/background all from root slot
fn tabRowStyle(slots: TabsSlotRecipe.Slots, block: bool) core.BoxStyle {
    const root_resolved = slots.root.resolve(.{});
    var style: core.BoxStyle = .{
        .border_overlay = true,
        .no_cross_stretch = true,
        .position = .relative,
        .gap = root_resolved.gap,
        .padding = root_resolved.padding,
        .align_items = .center,
        .background = root_resolved.background,
        .border = root_resolved.border,
        .border_color = root_resolved.border_color,
        .border_bottom_width = root_resolved.border_bottom_width,
        .corner_radius = if (root_resolved.corner_radius) |cr| (if (cr > 0) cr else null) else null,
    };
    if (block) {
        // In a column the fill width is a cross-axis stretch: allow it.
        style.width = core.Sizing.fill();
        style.no_cross_stretch = false;
    }
    return style;
}

/// highlight_box: absolute positioned, follows active tab (first child of tab_row)
fn highlightStyle(slots: TabsSlotRecipe.Slots, is_underline: bool) core.BoxStyle {
    var hl_style = slots.highlight.resolve(.{});
    hl_style.position = .absolute;
    // Anchored at the row's padding box: translate_x / margin_top carry the active
    // tab's parent-relative rect, which already includes the row padding (the static
    // position, the content box, would add the padding a second time).
    hl_style.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } };
    // The underline bar overlaps the tabs' bottom edge: paint it over their hover and
    // pressed backgrounds. Pill and tab sliders stay under the labels.
    if (is_underline) hl_style.z_index = 1;
    return hl_style;
}

// tabsBeforeRender, highlight box follows

/// Update text color, icon tint, and font_weight of tab descendant nodes
fn updateTabDescendants(parent: *Node, text_color: Color, icon_tint: Color, is_active: bool) void {
    const target_weight: u16 = if (is_active) 500 else 400;
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

/// Highlight box follows active tab's layout rect each frame (geometry depends on previous frame's
/// layout, can only do here)
fn tabsBeforeRender(node: *Node) void {
    const rt: *TabsRuntime = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    const hbox = rt.highlight_box;
    const children = node.children.items;
    if (rt.item_count == 0 or rt.active_index >= rt.item_count or rt.active_index + 1 >= children.len) return;

    const active_tab = children[rt.active_index + 1];
    const tab_rect = active_tab.rectFromWorldOrFallback();
    if (tab_rect.w <= 0) return;

    var layout_changed = false;
    if (rt.first_render) {
        // First frame: position immediately without triggering animation
        rt.first_render = false;
        hbox.snapTransition(rt.allocator, .width, tab_rect.w);
        hbox.snapTransition(rt.allocator, .translate_x, tab_rect.x);
    } else {
        hbox.setWidth(tab_rect.w);
        hbox.setTranslateX(tab_rect.x);
    }
    switch (rt.variant) {
        .underline => {
            const old_h = sizingPxValue(hbox.style.height);
            const r = node.rectFromWorldOrFallback();
            hbox.style.height = .{ .px = 2 };
            hbox.setMarginTop(r.h - 2);
            layout_changed = old_h == null or old_h.? != 2;
        },
        .pill, .tab => {
            const old_h = sizingPxValue(hbox.style.height);
            hbox.style.height = .{ .px = tab_rect.h };
            hbox.setMarginTop(tab_rect.y);
            layout_changed = old_h == null or old_h.? != tab_rect.h;
        },
    }
    if (layout_changed) hbox.markLayoutDirty();
}

// Tabs always retain one active page. Accessible selection must follow the same
// commit path as pointer activation, with single-selection rules.
fn setAccessibleTabSelection(raw: *anyopaque, operation: core.A11yProps.ItemSelectionOperation) bool {
    const ctx: *TabClickContext = @ptrCast(@alignCast(raw));
    const rt = ctx.rt;
    const items = rt.items.peek();
    if (ctx.tab_index >= items.len or items[ctx.tab_index].disabled) return false;
    const selected = rt.active_index == ctx.tab_index;
    if (operation == .remove) return !selected;
    if (selected) return true;
    if (operation == .add) return false;
    // Same proposal pipeline as click; result finalized before on_change (callback may unmount this
    // component)
    const id = items[ctx.tab_index].id;
    const on_change = rt.on_change;
    const landed = rt.active.commit(id) orelse return false;
    const ok = if (landed) |l| std.mem.eql(u8, l, id) else false;
    if (landed) |l| {
        if (on_change) |h| h.call(l);
    }
    return ok;
}

/// Tab click / arrow keys: only propose; view effect refreshes after data source lands
fn tabClickHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *TabClickContext = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .click => {
            ctx.rt.select(ctx.tab_index);
            return .handled;
        },
        .key_down => |e| {
            if (e.key == .left or e.key == .right) {
                ctx.rt.move(e.key == .right);
                return .handled;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

/// Arrow keys attached to focusable container (focus on container, keyboard events don't bubble to
/// tab_node)
fn tabsKeyDown(key: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
    const rt: *TabsRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    switch (key) {
        .left => rt.move(false),
        .right => rt.move(true),
        else => return .ignored,
    }
    return .handled;
}

/// Close button: trigger on_close(tab id) and stop propagation (else clicking x bubbles to tab_node
/// and activates it)
fn tabCloseHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *TabClickContext = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .click => {
            ctx.rt.close(ctx.tab_index);
            return .stop;
        },
        else => return .ignored,
    }
}

// Tabs properties + Builder + mount

pub const TabsProps = struct {
    /// Labels; changes in signal/derived values trigger rebuild. Strings owned by caller; must
    /// remain valid while they are the current data source value (treated as immutable data).
    items: Source([]const TabItem) = .{ .value = &.{} },
    /// Currently active tab id. String / null for uncontrolled (null = first tab);
    /// `*Signal(?[]const u8)` for controlled (interaction writes directly); `ui.split` parent
    /// intercepts.
    active: Model(?[]const u8) = .{ .local = null },
    variant: TabsVariant = .underline,
    size: TabsSize = .md,
    closable: bool = false,
    /// Fill the parent's width, the tabs sharing it equally (a segmented control).
    block: bool = false,
    /// Called after user switches and lands (the landed id)
    on_change: ?Handler([]const u8) = null,
    /// Click close button (tab id); closing itself is handled by caller updating items
    on_close: ?Handler([]const u8) = null,
};

/// Create Tabs: `W.Tabs(.{ .items = &items, .active = current_tab })`
pub fn Tabs(props: anytype) TabsBuilder {
    return .{ .props = reactive.props.coerce(TabsProps, props) };
}

const TabBuildArgs = struct {
    variant: TabsVariant,
    size: TabsSize,
    item: TabItem,
    is_active: bool,
    is_disabled: bool,
    show_close: bool,
    block: bool = false,
    rt: *TabsRuntime,
    tab_index: usize,
    slots: TabsSlotRecipe.Slots,
};

pub const TabsBuilder = struct {
    props: TabsProps,

    pub fn mount(self: TabsBuilder, scope: *Scope, cx: *Cx) !*Node {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        // my_scope has no owner before binding succeeds; container takes ownership after
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const slots = TabsSlotRecipe.resolve(.{ .variant = p.variant, .size = p.size }, t);
        const is_underline = p.variant == .underline;
        const theme_sig = try cx.themeSignal();
        const tab_row_style = tabRowStyle(slots, p.block);
        const hl_style = highlightStyle(slots, is_underline);

        var tab_row: *Node = undefined;
        var highlight_box: *Node = undefined;
        var separator: ?*Node = null;
        // Selected state's only observable exit: its translate_x points to current active tab (e2e
        // assertion)
        const highlight = ui_view.capture(&highlight_box, ui_view.box(.{ .style = hl_style, .test_id = "tabs.highlight" }, {}));
        // Container is tablist node with button semantics: wraps tab_row + separator in column when
        // underline, otherwise is tab_row
        const tablist_a11y: core.A11yProps = .{ .role = .tablist, .required = true };
        const container = try ui_view.render(my_scope, cx, ui_view.branch(is_underline, ui_view.col(.{
            .style = core.BoxStyle{ .width = if (p.block) core.Sizing.fill() else core.Sizing{ .fit = .{} } },
            .tag = .button,
            .focusable = true,
            .a11y = tablist_a11y,
        }, .{
            ui_view.capture(&tab_row, ui_view.row(.{ .style = tab_row_style }, .{highlight})),
            ui_view.capture(&separator, ui_view.box(.{ .style = .{
                .width = .{ .grow = .{} },
                .height = .{ .px = 1 },
                .background = t.tokens.color.separator,
            } }, {})),
        }), ui_view.capture(&tab_row, ui_view.row(.{
            .style = tab_row_style,
            .tag = .button,
            .focusable = true,
            .a11y = tablist_a11y,
        }, .{highlight}))));
        // Guard stays armed until return: container remains unowned even after binding
        errdefer cx.freeNode(container);
        highlight_box.meta.ownership.meta.component_name = "TabHighlight";
        // Decoration only: never takes a pointer from the tab under it.
        highlight_box.setHitTestVisible(false);
        try highlight_box.applyTransition(allocator, &comptime recipe_mod.transition("translate-x 150ms ease-out, width 150ms ease-out"));

        container.meta.ownership.meta.component_name = "Tabs";
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;

        const active = try reactive.resolveModel(?[]const u8, my_scope, p.active);
        // Shallow copy static items into scope (reversed after rt destroy, see RadioGroup)
        var items = p.items;
        var owned_items: []TabItem = &.{};
        if (p.items == .value) {
            owned_items = try my_scope.allocator.dupe(TabItem, p.items.value);
            items = .{ .value = owned_items };
        }
        var items_adopted = false;
        errdefer if (!items_adopted) my_scope.allocator.free(owned_items);
        const rt = try my_scope.allocator.create(TabsRuntime);
        rt.* = .{
            .active = active,
            .items = items,
            .owned_items = owned_items,
            .on_change = p.on_change,
            .on_close = p.on_close,
            .variant = p.variant,
            .size = p.size,
            .closable = p.closable,
            .block = p.block,
            .tokens = t,
            .theme = theme_sig,
            .allocator = allocator,
            .cx = cx,
            .scope = my_scope,
            .tab_row = tab_row,
            .highlight_box = highlight_box,
            .separator = separator,
            .slots = slots,
        };
        items_adopted = true;
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const r: *TabsRuntime = @ptrCast(@alignCast(ptr));
                alloc.free(r.owned_items);
                alloc.destroy(r);
            }
        }.destroy);
        container.addDebugState(@ptrCast(rt));
        container.behavior.events.on_key_down = tabsKeyDown;
        container.behavior.events.key_context = rt;
        try hooks.useFocusRing(my_scope, cx, container, .{});
        tab_row.behavior.events.event_context = rt;
        tab_row.meta.per_frame.hooks.before_render.main = tabsBeforeRender;

        try rt.view(false);
        reactive.checkBorrow(my_scope, p.items);
        // active is Model: local signal too, click changes it, needs effect
        try my_scope.createEffect(rt, TabsRuntime.viewEffect);
        return container;
    }
};

fn buildTab(args: TabBuildArgs, scope: *Scope, cx: *Cx) !*Node {
    const t = cx.tokens;
    const v = args.variant;
    const s = args.size;
    const item = args.item;
    const is_active = args.is_active;
    const is_disabled = args.is_disabled;
    const show_close = args.show_close;
    const slots = args.slots;
    // Click context belongs to this tab's scope (freed together with tab rebuild)
    const click_ctx = try scope.allocator.create(TabClickContext);
    click_ctx.* = .{ .rt = args.rt, .tab_index = args.tab_index };
    try scope.adoptResource(@ptrCast(click_ctx), struct {
        fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            alloc.destroy(@as(*TabClickContext, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);

    const resolved = slots.tab.resolve(.{ .is_selected = is_active });

    const text_color = if (is_disabled)
        t.tokens.color.fg_disabled
    else
        resolved.text_color orelse t.tokens.color.fg_secondary;

    const font_sz = resolved.font_size orelse control_shell.metrics(t, s).font_size;

    // Badge text on stack, copied into node when view.text mounts
    var badge_buf: [8]u8 = undefined;
    var badge_style: core.BoxStyle = .{};
    var badge_content: []const u8 = "";
    var badge_txt: core.TextStyle = .{};
    if (item.badge) |badge_count| {
        badge_style = slots.badge.resolve(.{});
        badge_content = std.fmt.bufPrint(&badge_buf, "{d}", .{badge_count}) catch "0";
        badge_txt = .{
            .color = badge_style.text_color orelse t.tokens.color.button_primary_fg,
            .font_size = badge_style.font_size orelse 10,
        };
        badge_style.text_color = null;
        badge_style.font_size = null;
    }

    var close_style = slots.close.resolve(.{});
    const close_txt: core.TextStyle = .{
        .color = close_style.text_color orelse t.tokens.color.fg_secondary,
        .font_size = close_style.font_size orelse 12,
    };
    close_style.text_color = null;
    close_style.font_size = null;
    if (!is_disabled) close_style.cursor = .pointer;

    const icon_sz = styles.tabIconSize(s);
    const icon_asset: ?svg_assets.Asset = item.icon_asset;

    // All variants unified: row { icon?, label, badge?, close? }
    // Background from highlight_box, tab transparent; geometry from tab slot's derived
    var close_btn: ?*Node = null;
    const tab_node = try ui_view.render(scope, cx, ui_view.row(.{
        .style = .{
            .width = if (args.block) core.Sizing.fill() else core.Sizing{ .fit = .{} },
            .justify = if (args.block) core.Justify.center else .start,
            .height = resolved.height,
            .no_cross_stretch = true,
            .padding = resolved.padding,
            .align_items = .center,
            .gap = resolved.gap,
            .corner_radius = resolved.corner_radius,
            .corner_radii = resolved.corner_radii,
            .cursor = if (!is_disabled) core.CursorShape.pointer else null,
        },
        // role=tab + label + selected all required (container is role=tablist)
        .a11y = core.A11yProps{
            .role = .tab,
            .label = item.label,
            .selected = is_active,
            .disabled = is_disabled,
            .item_selection = if (is_disabled) null else .{ .context = @ptrCast(click_ctx), .set = setAccessibleTabSelection },
        },
    }, .{
        // Optional icon (any variant)
        if (icon_asset) |asset| ui_view.icon(.{
            .style = .{ .width = .{ .px = icon_sz }, .height = .{ .px = icon_sz } },
            .tint = if (is_active and v != .underline) t.tokens.color.accent else t.tokens.color.fg_secondary,
        }, asset) else null,
        // Label: ghost bold text (h=0, prevents jitter) + real text (font_weight switches
        // instantly)
        ui_view.col(.{}, .{
            // Ghost text: bold weight reserves width, h=0 + overflow_hidden hides rendering
            ui_view.attrs(.{ .style = core.BoxStyle{ .height = .{ .px = 0 }, .overflow_hidden = true } }, ui_view.text(.{ .style = core.TextStyle{
                .color = Color.TRANSPARENT,
                .font_size = font_sz,
                .font_weight = 600,
            } }, item.label)),
            // Real text: font_weight switches instantly on change (no transition animation, avoid
            // jitter/shadow)
            ui_view.text(.{ .style = core.TextStyle{
                .color = text_color,
                .font_size = font_sz,
                .font_weight = if (is_active) @as(u16, 500) else @as(u16, 400),
            } }, item.label),
        }),
        // badge
        if (item.badge != null) ui_view.attrs(.{ .style = badge_style }, ui_view.text(.{ .style = badge_txt }, badge_content)) else null,
        // Close button
        if (show_close) ui_view.capture(&close_btn, ui_view.attrs(.{
            .style = close_style,
            .a11y = core.A11yProps{ .role = .button, .label = "Close" },
        }, ui_view.text(.{ .style = close_txt }, "×"))) else null,
    }));
    // tab_node is returned to caller, unowned before return succeeds
    errdefer cx.freeNode(tab_node);

    if (!is_disabled) {
        tab_node.behavior.events.on_event = tabClickHandler;
        tab_node.behavior.events.event_context = click_ctx;
        const hover = try hooks.useHover(scope, tab_node);
        const pressed = try hooks.usePressed(scope, cx, tab_node);
        const Visual = struct {
            hover: *reactive.Signal(bool),
            pressed: *reactive.Signal(bool),
            node: *Node,
            rt: *TabsRuntime,
            index: usize,
            fn update(c: @This()) void {
                const hovered = c.hover.get();
                const down = c.pressed.get();
                const active = TabsRuntime.indexOf(c.rt.items.read(true), c.rt.active.readAs(true)) == c.index;
                // The selected tab already shows its slider / bar: no hover or pressed fill over it.
                const visual = c.rt.slots.tab.resolve(.{ .is_selected = active, .is_hovered = hovered and !active, .is_pressed = down and hovered and !active });
                c.node.setBackgroundRaw(visual.background orelse Color.TRANSPARENT);
            }
        };
        try scope.createEffect(Visual{ .hover = hover, .pressed = pressed, .node = tab_node, .rt = args.rt, .index = args.tab_index }, Visual.update);
        if (close_btn) |btn| {
            btn.behavior.events.on_event = tabCloseHandler;
            btn.behavior.events.event_context = click_ctx;
        }
    }

    return tab_node;
}

// ============================================================================
// TabPanel
// ============================================================================

pub const TabPanelProps = struct {
    /// Panel identifier (a11y identifier, corresponds to Tabs item id)
    id: []const u8,
    /// Is current panel: commonly written as `ui.eq(current_tab, "files")`
    active: Source(bool) = .{ .value = true },
};

/// Create TabPanel: `W.TabPanel(.{ .id = "files", .active = ui.eq(tab, "files") }).mount(scope,
/// cx)`,
/// returned node is panel content container; non-current panel skips layout and hides from AT
pub fn TabPanel(props: anytype) TabPanelBuilder {
    return .{ .props = reactive.props.coerce(TabPanelProps, props) };
}

pub const TabPanelBuilder = struct {
    props: TabPanelProps,

    /// `ui.view.with(W.TabPanel(...), .{ children... })`: the panel itself holds the children.
    pub fn viewMount(self: TabPanelBuilder, scope: *Scope, cx: *Cx) !ui_view.ViewParts {
        const node = try self.mount(scope, cx);
        return .{ .root = node, .slot = node };
    }

    pub fn mount(self: TabPanelBuilder, scope: *Scope, cx: *Cx) !*Node {
        const p = self.props;
        const node = try ui_view.render(scope, cx, ui_view.col(.{
            .style = .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } },
            .a11y = .{ .role = .tabpanel, .identifier = p.id },
        }, {}));
        errdefer cx.freeNode(node);
        node.meta.ownership.meta.component_name = "TabPanel";
        try bind_mod.bind(scope, p.active, node, struct {
            fn apply(n: *Node, active: bool) void {
                n.style.display = if (active) .flex else .none;
                if (n.behavior.interaction.a11y) |*a| a.hidden = !active;
                n.markLayoutDirty();
            }
        }.apply);
        return node;
    }
};

// Tests

test "TabPanel: ui.view.with puts the children inside the panel, which follows active" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const active = try scope.createSignal(bool, false);
    const panel = try ui_view.render(scope, ctx, ui_view.with(TabPanel(.{ .id = "files", .active = active }), .{
        ui_view.text(.{}, "first"),
        ui_view.text(.{}, "second"),
    }));
    try root.appendChild(std.testing.allocator, panel);
    try std.testing.expectEqual(@as(usize, 2), panel.children.items.len);
    try std.testing.expectEqualStrings("first", panel.children.items[0].getText().?.content);
    try std.testing.expectEqual(core.Display.none, panel.style.display);
    active.set(true);
    try std.testing.expectEqual(core.Display.flex, panel.style.display);
}

test "Tabs: basic creation (underline default)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "tab1", .label = "Tab 1" },
        .{ .id = "tab2", .label = "Tab 2" },
        .{ .id = "tab3", .label = "Tab 3" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .active = "tab1",
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tabs_node);

    // underline: outer = column { tab_row, separator }
    try std.testing.expectEqual(@as(usize, 2), tabs_node.children.items.len);
    // tab_row children = [highlight_box, tab1, tab2, tab3]
    const tab_row = tabs_node.children.items[0];
    try std.testing.expectEqual(@as(usize, 4), tab_row.children.items.len);
    // First child is highlight_box
    try std.testing.expectEqualStrings("TabHighlight", tab_row.children.items[0].meta.ownership.meta.component_name.?);
}

test "Tabs: pill variant" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label = "Option A" },
        .{ .id = "b", .label = "Option B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tabs_node);
    // pill: tab_row children = [highlight_box, tab1, tab2]
    try std.testing.expectEqual(@as(usize, 3), tabs_node.children.items.len);
    // Pill container should have background color (bg_secondary)
    try std.testing.expect(!Color.eql(tabs_node.getBackground(), Color.TRANSPARENT));
    // highlight_box should have white background
    const hbox = tabs_node.children.items[0];
    try std.testing.expect(Color.eql(hbox.getBackground(), ctx.tokens.tokens.color.bg_primary));
}

test "Tabs: pill render emits highlight background" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(320, 80);

    const root = try box(ctx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 80 },
        .background = ctx.tokens.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label = "One" },
        .{ .id = "b", .label = "Two" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .active = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_highlight = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.tokens.color.bg_primary) and r.geom.w >= 40 and r.geom.h >= 20) {
            saw_highlight = true;
        }
    };

    try std.testing.expect(saw_highlight);
}

test "Tabs: pill active tab text styling" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label = "Option A" },
        .{ .id = "b", .label = "Option B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .active = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // children = [highlight_box, tab_a, tab_b]
    // active tab: tab -> [label_wrapper] -> [ghost(h=0), label_node(text)]
    const active_tab = tabs_node.children.items[1]; // skip highlight
    const active_label_wrapper = active_tab.children.items[0];
    try std.testing.expect(active_label_wrapper.children.items.len >= 2);
    const active_label = active_label_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(active_label.getText() != null);
    try std.testing.expect(Color.eql(active_label.getText().?.color, ctx.tokens.tokens.color.fg_primary));

    // inactive tab
    const inactive_tab = tabs_node.children.items[2]; // skip highlight
    const inactive_label_wrapper = inactive_tab.children.items[0];
    try std.testing.expect(inactive_label_wrapper.children.items.len >= 2);
    const inactive_label = inactive_label_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(inactive_label.getText() != null);
    try std.testing.expect(Color.eql(inactive_label.getText().?.color, ctx.tokens.tokens.color.fg_secondary));
}

test "Tabs: icon variant" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label = "Files", .icon_asset = svg_assets.common.file_text },
        .{ .id = "b", .label = "Search", .icon_asset = svg_assets.common.search },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .tab,
        .active = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // children = [highlight_box, tab_a, tab_b]
    // cokFx document tabs: selected page is the primary surface.
    const hbox = tabs_node.children.items[0];
    try std.testing.expect(Color.eql(hbox.getBackground(), ctx.tokens.tokens.color.bg_primary));

    // Each tab should have icon + label = 2 children
    const first_tab = tabs_node.children.items[1];
    try std.testing.expectEqual(@as(usize, 2), first_tab.children.items.len);
}

test "Tabs: small size" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label = "A" },
        .{ .id = "b", .label = "B" },
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label = "Tab A" },
        .{ .id = "b", .label = "Tab B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .underline,
        .active = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // underline: outer = column { tab_row, separator }
    const tab_row = tabs_node.children.items[0];
    // tab_row children = [highlight_box, tab_a, tab_b]
    const hbox = tab_row.children.items[0];
    try std.testing.expectEqualStrings("TabHighlight", hbox.meta.ownership.meta.component_name.?);
    // Underline highlight = primary ink, 2px height
    try std.testing.expect(Color.eql(hbox.getBackground(), ctx.tokens.tokens.color.fg_primary));
    try std.testing.expectEqual(@as(f32, 2), hbox.style.height.px);
}

test "Tabs: with badge" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "inbox", .label = "Inbox", .badge = 5 },
        .{ .id = "sent", .label = "Sent" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tabs_node);

    // underline: outer = column { tab_row, separator }
    const tab_row = tabs_node.children.items[0];
    // tab_row children = [highlight_box, tab_inbox, tab_sent]
    const first_tab = tab_row.children.items[1]; // skip highlight
    // Tab should have label + badge = 2 children
    try std.testing.expectEqual(@as(usize, 2), first_tab.children.items.len);

    // Regression: badge text once pointed to stack buffer, dangling after function return -> render
    // lost digits, only accent dot.
    // After switch to setInlineContent copying to inline storage, content must still be "5".
    const badge_node = first_tab.children.items[1];
    try std.testing.expect(badge_node.getText() != null);
    try std.testing.expectEqualStrings("5", badge_node.getText().?.content);
}

test "Tabs: closable" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "file1", .label = "file.txt" },
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
    // Tab should have label + close = 2 children
    try std.testing.expectEqual(@as(usize, 2), tab.children.items.len);
}

test "Tabs: before_render updates on active change" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "a", .label = "Option A" },
        .{ .id = "b", .label = "Option B" },
    };

    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .active = "a",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);

    // children = [highlight_box, tab_a, tab_b]
    // click second tab (index 2)
    const second_tab = tabs_node.children.items[2];
    const click_result = tabClickHandler(.{ .click = .{
        .x = 10,
        .y = 10,
        .button = .left,
        .click_count = 1,
    } }, second_tab.behavior.events.event_context);
    try std.testing.expectEqual(EventResult.handled, click_result);

    // Trigger before_render
    if (tabs_node.meta.per_frame.hooks.before_render.main) |before_render| {
        before_render(tabs_node);
    }
    for (tabs_node.meta.per_frame.hooks.before_render.hooks[0..tabs_node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
        if (cb_opt) |cb| cb(tabs_node);
    }

    // Verify text color switch: tab -> [label_wrapper] -> [ghost, label_node(text)]
    const tab_b_wrapper = tabs_node.children.items[2].children.items[0];
    const tab_b_label = tab_b_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(tab_b_label.getText() != null);
    try std.testing.expect(Color.eql(tab_b_label.getText().?.color, ctx.tokens.tokens.color.fg_primary));
    const tab_a_wrapper = tabs_node.children.items[1].children.items[0];
    const tab_a_label = tab_a_wrapper.children.items[1]; // skip ghost
    try std.testing.expect(Color.eql(tab_a_label.getText().?.color, ctx.tokens.tokens.color.fg_secondary));
}

test "TabPanel: follows its active source" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tab = try scope.createSignal(?[]const u8, "files");
    const files = try TabPanel(.{ .id = "files", .active = reactive.eq(tab, "files") }).mount(scope, ctx);
    defer ctx.freeNode(files);
    const search = try TabPanel(.{ .id = "search", .active = reactive.eq(tab, "search") }).mount(scope, ctx);
    defer ctx.freeNode(search);
    try std.testing.expect(files.style.display != .none);
    try std.testing.expect(search.style.display == .none);
    try std.testing.expect(search.behavior.interaction.a11y.?.hidden);
    tab.set("search");
    try std.testing.expect(files.style.display == .none);
    try std.testing.expect(!search.behavior.interaction.a11y.?.hidden);
}

fn tabText(tabs_node: *Node, tab_index: usize) *Node {
    return tabs_node.children.items[tab_index + 1].children.items[0].children.items[1];
}

test "Tabs: bound active — external set and clicks, disabled tab skipped by arrows" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const items = [_]TabItem{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B", .disabled = true }, .{ .id = "c", .label = "C" } };
    const current = try scope.createSignal(?[]const u8, "a");
    const Rec = struct {
        changes: u32 = 0,
        fn changed(self: *@This(), _: []const u8) void {
            self.changes += 1;
        }
    };
    var rec = Rec{};
    const tabs_node = try Tabs(.{ .items = &items, .variant = .pill, .active = current, .on_change = ctx.on(Rec, &rec, Rec.changed) }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);
    ctx.layout(); // Dispatcher resolves targets by handle, nodes register during layout
    try std.testing.expect(tabs_node.children.items[1].behavior.interaction.a11y.?.selected);

    current.set("c"); // External drive
    try std.testing.expect(tabs_node.children.items[3].behavior.interaction.a11y.?.selected);
    try std.testing.expect(!tabs_node.children.items[1].behavior.interaction.a11y.?.selected);
    try std.testing.expect(Color.eql(tabText(tabs_node, 2).getText().?.color, ctx.tokens.tokens.color.fg_primary));
    try std.testing.expectEqual(@as(u32, 0), rec.changes); // Programmatic write does not trigger on_change

    _ = ctx.dispatcher.dispatchKeyDown(tabs_node, .{ .key = .left, .modifiers = .{} }); // Skip disabled b
    try std.testing.expectEqualStrings("a", current.peek().?);
    _ = tabClickHandler(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, tabs_node.children.items[3].behavior.events.event_context);
    try std.testing.expectEqualStrings("c", current.peek().?);
    try std.testing.expectEqual(@as(u32, 2), rec.changes);
}

var swap_buf_a = "Files".*;
var swap_buf_b = "Files".*;
const swap_first = [_]TabItem{.{ .id = "f", .label = &swap_buf_a }};
const swap_second = [_]TabItem{.{ .id = "f", .label = &swap_buf_b }};

test "Tabs: a derived source returning an equal-content array at a new address rebinds labels" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // Signal compares by content, equal set doesn't land; derived values recompute but may return
    // content-identical, address-different arrays (independent buffers: literals de-dup to same
    // address).
    const gen = try scope.createSignal(u32, 0);
    const items = reactive.map(gen, struct {
        fn f(g: u32) []const TabItem {
            return if (g % 2 == 0) &swap_first else &swap_second;
        }
    }.f);
    const tabs_node = try Tabs(.{ .items = items, .variant = .pill }).mount(scope, ctx);
    defer ctx.freeNode(tabs_node);
    // Text node owns label copy (ui.view.text copies content), borrowing caller's slice remains
    // only in a11y label
    try std.testing.expectEqualStrings("Files", tabText(tabs_node, 0).getText().?.content);
    try std.testing.expectEqual(@as([*]const u8, &swap_buf_a), tabs_node.children.items[1].behavior.interaction.a11y.?.label.?.ptr);
    gen.set(1);
    try std.testing.expectEqualStrings("Files", tabText(tabs_node, 0).getText().?.content);
    try std.testing.expectEqual(@as([*]const u8, &swap_buf_b), tabs_node.children.items[1].behavior.interaction.a11y.?.label.?.ptr);
}

test "Tabs: clicking the tab shown as selected for a null active is a no-op" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const items = [_]TabItem{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" } };
    const current = try scope.createSignal(?[]const u8, null);
    var changes: u32 = 0;
    const tabs_node = try Tabs(.{ .items = &items, .variant = .pill, .active = current, .on_change = ctx.on(u32, &changes, struct {
        fn f(n: *u32, _: []const u8) void {
            n.* += 1;
        }
    }.f) }).mount(scope, ctx);
    defer ctx.freeNode(tabs_node);
    try std.testing.expect(tabs_node.children.items[1].behavior.interaction.a11y.?.selected); // Null falls back to first item
    _ = tabClickHandler(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, tabs_node.children.items[1].behavior.events.event_context);
    try std.testing.expect(current.peek() == null);
    try std.testing.expectEqual(@as(u32, 0), changes);
}

test "Tabs: arrow key in the same batch as an items shrink stays in bounds" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const three = [_]TabItem{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" }, .{ .id = "c", .label = "C" } };
    const one = [_]TabItem{.{ .id = "a", .label = "A" }};
    const items = try scope.createSignal([]const TabItem, &three);
    const current = try scope.createSignal(?[]const u8, "c");
    const tabs_node = try Tabs(.{ .items = items, .variant = .pill, .active = current }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);
    ctx.layout();

    // After items shrink, effect runs after batch ends; active_index still 2
    ctx.owner.beginBatch();
    items.set(&one);
    _ = ctx.dispatcher.dispatchKeyDown(tabs_node, .{ .key = .left, .modifiers = .{} });
    ctx.owner.endBatch();
    try std.testing.expectEqualStrings("a", current.peek().?);
}

test "Tabs: items from a signal rebuild the tabs (closable tab list)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const three = [_]TabItem{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" }, .{ .id = "c", .label = "C" } };
    const two = [_]TabItem{ .{ .id = "a", .label = "A" }, .{ .id = "c", .label = "C" } };
    const items = try scope.createSignal([]const TabItem, &three);
    const current = try scope.createSignal(?[]const u8, "c");
    const tabs_node = try Tabs(.{ .items = items, .variant = .pill, .closable = true, .active = current }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);
    try std.testing.expectEqual(@as(usize, 4), tabs_node.children.items.len); // highlight + 3
    items.set(&two); // Close b
    try std.testing.expectEqual(@as(usize, 3), tabs_node.children.items.len);
    try std.testing.expect(tabs_node.children.items[2].behavior.interaction.a11y.?.selected); // c still active (new index 1)
    _ = tabClickHandler(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, tabs_node.children.items[1].behavior.events.event_context);
    try std.testing.expectEqualStrings("a", current.peek().?);
}

test "Tabs: 点关闭按钮触发 on_close 且不激活该 tab；方向键在可聚焦 container 上生效" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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
        .{ .id = "a", .label = "A" },
        .{ .id = "b", .label = "B" },
    };
    const tabs_node = try Tabs(.{
        .items = &items,
        .variant = .pill,
        .closable = true,
        .active = "a",
        .on_close = ctx.on(Rec, &rec, Rec.onClose),
        .on_change = ctx.on(Rec, &rec, Rec.onChange),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);
    ctx.layout();

    // pill: container == tab_row, children = [highlight_box, tab_a, tab_b]
    const tab_b = tabs_node.children.items[2];
    const close_b = tab_b.children.items[tab_b.children.items.len - 1];
    _ = ctx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, close_b);
    try std.testing.expectEqualStrings("b", rec.closed.?);
    try std.testing.expectEqual(@as(usize, 0), rec.changed); // Didn't bubble activate tab_b

    // Focus on container (only focusable node): arrow keys must switch
    try std.testing.expect(tabs_node.behavior.interaction.focusable);
    _ = ctx.dispatcher.dispatchKeyDown(tabs_node, .{ .key = .right, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 1), rec.changed);
    _ = ctx.dispatcher.dispatchKeyDown(tabs_node, .{ .key = .left, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 2), rec.changed);
}

// Test collection from styles.zig, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// devtools mountPanel sweep caught leak inside Tabs, fixture didn't hit underline + xs + on_change
// branch
test "Tabs: underline/xs/on_change 的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tabs(underline)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]TabItem{
                .{ .id = "elements", .label = "Elements" },
                .{ .id = "components", .label = "Components" },
                .{ .id = "console", .label = "Console" },
                .{ .id = "performance", .label = "Performance" },
            };
            const Dummy = struct {
                fn onChange(_: *@This(), _: []const u8) void {}
            };
            var dummy: Dummy = .{};
            return try Tabs(.{
                .items = &items,
                .active = "elements",
                .variant = .underline,
                .size = .xs,
                .on_change = cx.on(Dummy, &dummy, Dummy.onChange),
            }).mount(scope, cx);
        }
    }.m);
}

test "Tabs: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tabs", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]TabItem{ .{ .id = "tab1", .label = "Tab 1" }, .{ .id = "tab2", .label = "Tab 2" } };
            return try Tabs(.{ .items = &items, .active = "tab1" }).mount(scope, cx);
        }
    }.m);
}

test "Tabs: a11y item_selection —— 受控拒绝时返回 false，接受时返回 true" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const items = [_]TabItem{
        .{ .id = "tab1", .label = "Tab 1" },
        .{ .id = "tab2", .label = "Tab 2" },
        .{ .id = "tab3", .label = "Tab 3" },
    };
    const Parent = struct {
        v: *reactive.Signal(?[]const u8),
        allow: bool = false,
        fn write(self: *@This(), x: ?[]const u8) void {
            if (self.allow) self.v.set(x);
        }
    };
    var parent = Parent{ .v = try scope.createSignal(?[]const u8, "tab1") };
    const tabs_node = try Tabs(.{ .items = &items, .active = reactive.split(parent.v, ctx.on(Parent, &parent, Parent.write)) }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tabs_node);
    const tab_row = tabs_node.children.items[0];
    const sel = tab_row.children.items[2].behavior.interaction.a11y.?.item_selection.?;
    try std.testing.expect(!sel.set(sel.context, .replace));
    try std.testing.expectEqualStrings("tab1", parent.v.peek().?);
    try std.testing.expect(!sel.set(sel.context, .add));
    parent.allow = true;
    try std.testing.expect(sel.set(sel.context, .replace));
    try std.testing.expectEqualStrings("tab2", parent.v.peek().?);
    try std.testing.expect(!sel.set(sel.context, .remove)); // Tab always keeps one item selected
}
