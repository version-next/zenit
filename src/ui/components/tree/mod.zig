/// Tree component: file explorer / directory structure style tree control.
///
/// Features:
/// - expandable/collapsible, indented hierarchy display
/// - keyboard navigation (ArrowRight expand, ArrowLeft collapse, ArrowUp/Down move)
/// - selectable
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const hooks = @import("../../hooks.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
const svg_assets = @import("../../svg_assets.zig");
const selection_mod = @import("../selection.zig");
pub const SelectionMode = selection_mod.SelectionMode;

/// Tree node data (includes nested children and string, owned by caller, must remain valid while
/// current)
pub const TreeNodeData = struct {
    id: []const u8,
    label: []const u8,
    children: []const TreeNodeData = &.{},
    disabled: bool = false,
};

/// Tree properties
pub const TreeProps = struct {
    /// Tree accessible name (UIA / AX container Name)
    label_text: []const u8 = "Tree",
    /// nodes (can pass signal / derived: rebuild rows when content or address changes)
    nodes: Source([]const TreeNodeData) = .{ .value = &.{} },
    indent: f32 = 20,
    /// selected node ids set (single-select at most one). `*Signal` must be created via
    /// `scope.createList` (component-written new set copied by signal)
    selected: Model([]const []const u8) = .{ .local = &.{} },
    /// expanded node ids set, same constraint
    expanded: Model([]const []const u8) = .{ .local = &.{} },
    /// user clicks / arrow-selects a node (that node id): fires after interaction when node in
    /// selected state --
    /// also fires clicking already-selected row (activation semantics); not fired when `selected`
    /// rejected by `ui.split` or deselected in multi-select.
    on_select: ?Handler([]const u8) = null,
    expand_icon_asset: ?svg_assets.Asset = null,
    /// .single: click replaces; .multi: Cmd/Ctrl toggles, Shift continuous range (visible order)
    selection_mode: selection_mod.SelectionMode = .single,
};

/// Create Tree: `W.Tree(.{ .nodes = &files, .selected = picked, .expanded = open_dirs })`
pub fn Tree(props: anytype) TreeBuilder {
    return .{ .props = reactive.props.coerce(TreeProps, props) };
}

// -- style layer in styles.zig --
const styles = @import("styles.zig");
const treeContainerStyle = styles.treeContainerStyle;
const treeRowStyle = styles.treeRowStyle;
const treeSelectionBg = styles.treeSelectionBg;
const treeIndicatorBoxStyle = styles.treeIndicatorBoxStyle;
const treeExpandIconStyle = styles.treeExpandIconStyle;
const treeIndicatorTextStyle = styles.treeIndicatorTextStyle;
const treeLabelBoxStyle = styles.treeLabelBoxStyle;
const treeLabelTextStyle = styles.treeLabelTextStyle;

/// Tree runtime (scope owns). Rows rebuilt via `ui.rebuildOn` with nodes; view = f(selected,
/// expanded) mapped by effect to bitmap by flat index; interaction only proposes new id sets.
pub const TreeState = struct {
    selected: reactive.Bound([]const []const u8),
    expanded_ids: reactive.Bound([]const []const u8),
    on_select: ?Handler([]const u8),
    selection_mode: selection_mod.SelectionMode,
    indent: f32,
    expand_icon_asset: ?svg_assets.Asset,
    tokens: *const theme.ThemeTokens,
    cx: *Cx,
    container: *Node,
    /// selected row background color
    selection_bg: Color,

    flat_nodes: [MAX_NODES]FlatNode = undefined,
    flat_node_rows: [MAX_NODES]?*Node = @as([MAX_NODES]?*Node, @splat(null)),
    /// row with children has expand indicator (icon rotation / text > v), refreshes with expand
    /// state
    flat_node_indicators: [MAX_NODES]?*Node = @as([MAX_NODES]?*Node, @splat(null)),
    flat_count: usize = 0,
    /// bitmap derived from data source (refreshed by view effect)
    expanded: [MAX_NODES]bool = @as([MAX_NODES]bool, @splat(false)),
    selected_bits: [MAX_NODES]bool = @as([MAX_NODES]bool, @splat(false)),
    /// keyboard navigation / Shift range current row and anchor (internal state)
    selected_flat_index: ?usize = null,
    hovered_index: ?usize = null,
    selection_anchor: ?usize = null,

    const MAX_NODES = 128;
    const MAX_TREE_DEPTH = 64;

    const FlatNode = struct {
        data: *const TreeNodeData,
        depth: u16,
        has_children: bool,
    };

    fn contains(ids: []const []const u8, id: []const u8) bool {
        for (ids) |x| {
            if (std.mem.eql(u8, x, id)) return true;
        }
        return false;
    }

    pub fn isSelected(self: *const TreeState, flat_index: usize) bool {
        return flat_index < self.flat_count and self.selected_bits[flat_index];
    }

    /// current (primary) selected node id
    pub fn selectedId(self: *const TreeState) ?[]const u8 {
        const i = self.selected_flat_index orelse return null;
        if (i >= self.flat_count or !self.selected_bits[i]) return null;
        return self.flat_nodes[i].data.id;
    }

    // ---- view ----

    fn viewEffect(self: *TreeState) void {
        self.applyModels(self.selected.readAs(true), self.expanded_ids.readAs(true));
    }

    fn applyModels(self: *TreeState, sel_ids: []const []const u8, exp_ids: []const []const u8) void {
        for (self.flat_nodes[0..self.flat_count], 0..) |flat, i| {
            self.selected_bits[i] = contains(sel_ids, flat.data.id);
            self.expanded[i] = flat.has_children and contains(exp_ids, flat.data.id);
        }
        // when current row no longer selected (external rewrite), keyboard continues from first
        // selected row
        if (self.selected_flat_index) |cur| {
            if (cur >= self.flat_count or !self.selected_bits[cur]) self.selected_flat_index = null;
        }
        if (self.selected_flat_index == null) {
            for (0..self.flat_count) |i| {
                if (self.selected_bits[i]) {
                    self.selected_flat_index = i;
                    break;
                }
            }
        }
        self.applySelectionStyles();
        self.updateVisibility();
    }

    /// sync selection state to row background + aria-selected; active_descendant points to current
    /// row
    fn applySelectionStyles(self: *TreeState) void {
        for (0..self.flat_count) |i| {
            const row = self.flat_node_rows[i] orelse continue;
            const sel = self.selected_bits[i];
            row.setBackgroundRaw(styles.rowVisual(sel, self.hovered_index == i, self.flat_nodes[i].data.disabled, self.tokens).background.?);
            if (row.children.items.len > 0) {
                const label = row.children.items[row.children.items.len - 1];
                if (label.getText()) |old| {
                    var text = old;
                    text.color = styles.treeRowTextColor(sel, self.flat_nodes[i].data.disabled, self.tokens);
                    label.setText(text);
                }
            }
            // highlight is visual-only; aria-selected is AT's sole selection basis
            if (row.behavior.interaction.a11y) |*a| a.selected = sel;
            row.markRenderDirty();
        }
        if (self.container.behavior.interaction.a11y) |*a| {
            a.active_descendant_element_id = if (self.selected_flat_index) |cur|
                if (self.flat_node_rows[cur]) |row| row.element_id_raw else 0xFFFFFFFF
            else
                0xFFFFFFFF;
        }
        self.container.markRenderDirty();
    }

    fn updateVisibility(self: *TreeState) void {
        for (0..self.flat_count) |i| {
            const row = self.flat_node_rows[i] orelse continue;
            const visible = self.isVisible(i);
            row.style.height = if (visible) .{ .px = 28 } else .{ .px = 0 };
            row.style.overflow_hidden = !visible;
            if (row.behavior.interaction.a11y) |*a| {
                a.hidden = !visible;
                // aria-expanded must follow, else AT users see collapsed after expanding directory
                if (self.flat_nodes[i].has_children) a.expanded = self.expanded[i];
            }
            if (self.flat_node_indicators[i]) |indicator| {
                if (indicator.getText()) |old| {
                    const content: []const u8 = if (self.expanded[i]) "v" else ">";
                    if (!std.mem.eql(u8, old.content, content)) {
                        var text = old;
                        text.content = content;
                        indicator.setText(text);
                    }
                } else indicator.setRotate(self.cx.allocator, if (self.expanded[i]) std.math.pi / 2.0 else 0);
            }
            row.markLayoutDirty();
            row.markRenderDirty();
        }
    }

    /// visible only if all ancestors expanded
    fn isVisible(self: *const TreeState, flat_index: usize) bool {
        var depth = self.flat_nodes[flat_index].depth;
        var check = flat_index;
        while (depth > 0 and check > 0) {
            check -= 1;
            if (self.flat_nodes[check].depth < depth) {
                if (!self.expanded[check]) return false;
                depth = self.flat_nodes[check].depth;
            }
        }
        return true;
    }

    // ---- interaction: propose new id sets only ----

    /// whether id selected in data source
    fn isSelectedId(self: *TreeState, id: []const u8) bool {
        for (self.selected.peek()) |x| {
            if (std.mem.eql(u8, x, id)) return true;
        }
        return false;
    }

    /// return whether data source equals proposed set (lands as-is, or already is this set).
    /// selection is set semantics: parent just reordered is still as-is
    fn proposeSelection(self: *TreeState, bits: *const [MAX_NODES]bool) bool {
        var ids: [MAX_NODES][]const u8 = undefined;
        var n: usize = 0;
        for (0..self.flat_count) |i| {
            if (bits[i]) {
                ids[n] = self.flat_nodes[i].data.id;
                n += 1;
            }
        }
        _ = self.selected.commit(ids[0..n]);
        // distinct ids: equal length and every proposed id in data source <-> same set
        if (self.selected.peek().len != n) return false;
        for (ids[0..n]) |id| {
            if (!self.isSelectedId(id)) return false;
        }
        return true;
    }

    /// select (no modifiers)
    pub fn selectNode(self: *TreeState, flat_index: usize) void {
        self.selectNodeWithIntent(flat_index, .{});
    }

    /// select with modifier intent. single mode ignores modifiers; multi: toggle=Cmd/Ctrl,
    /// range=Shift.
    pub fn selectNodeWithIntent(self: *TreeState, flat_index: usize, intent: selection_mod.ClickIntent) void {
        if (flat_index >= self.flat_count) return;
        // when proposal not as-is (blocked by split or rewritten), anchor / current row revert to
        // pre-click
        const prev_anchor = self.selection_anchor;
        const prev_current = self.selected_flat_index;
        var bits = self.selected_bits;
        if (self.selection_mode == .multi and intent.range) {
            const a = self.selection_anchor orelse flat_index;
            const lo = @min(a, flat_index);
            const hi = @max(a, flat_index);
            @memset(&bits, false);
            for (lo..hi + 1) |i| bits[i] = true;
            if (self.selection_anchor == null) self.selection_anchor = flat_index;
        } else if (self.selection_mode == .multi and intent.toggle) {
            bits[flat_index] = !bits[flat_index];
            self.selection_anchor = flat_index;
        } else {
            @memset(&bits, false);
            bits[flat_index] = true;
            self.selection_anchor = flat_index;
        }
        self.selected_flat_index = flat_index;
        const on_select = self.on_select;
        const id = self.flat_nodes[flat_index].data.id;
        if (!self.proposeSelection(&bits)) {
            self.selection_anchor = prev_anchor;
            self.selected_flat_index = prev_current;
        }
        // when data source unchanged (e.g., clicked already-selected row) view effect won't run:
        // current row change must still paint
        self.applySelectionStyles();
        // by data source: report after interaction only if node truly in selected state (reject /
        // deselect don't report)
        if (on_select) |h| {
            if (self.isSelectedId(id)) h.call(id);
        }
    }

    /// expand / collapse: propose new expanded set
    pub fn toggleExpand(self: *TreeState, flat_index: usize) void {
        if (flat_index >= self.flat_count or !self.flat_nodes[flat_index].has_children) return;
        var ids: [MAX_NODES][]const u8 = undefined;
        var n: usize = 0;
        for (0..self.flat_count) |i| {
            const on = if (i == flat_index) !self.expanded[i] else self.expanded[i];
            if (on) {
                ids[n] = self.flat_nodes[i].data.id;
                n += 1;
            }
        }
        _ = self.expanded_ids.commit(ids[0..n]);
    }

    // ---- row building (ui.rebuildOn) ----

    fn nodesKey(nodes: []const TreeNodeData) u64 {
        var h = std.hash.Wyhash.init(0);
        hashNodes(&h, nodes, 0);
        return h.final();
    }

    fn hashNodes(h: *std.hash.Wyhash, nodes: []const TreeNodeData, depth: u16) void {
        if (depth >= MAX_TREE_DEPTH) return;
        h.update(std.mem.asBytes(&@intFromPtr(nodes.ptr)));
        h.update(std.mem.asBytes(&nodes.len));
        for (nodes) |n| {
            h.update(n.id);
            h.update(std.mem.asBytes(&@intFromPtr(n.label.ptr)));
            h.update(n.label);
            h.update(&[_]u8{@intFromBool(n.disabled)});
            hashNodes(h, n.children, depth + 1);
        }
    }

    fn flatten(self: *TreeState, nodes: []const TreeNodeData, depth: u16) void {
        if (depth >= MAX_TREE_DEPTH) return; // prevent stack overflow from extremely deep tree
        for (nodes) |*data| {
            if (self.flat_count >= MAX_NODES) return;
            self.flat_nodes[self.flat_count] = .{ .data = data, .depth = depth, .has_children = data.children.len > 0 };
            self.flat_count += 1;
            self.flatten(data.children, depth + 1);
        }
    }

    fn buildRows(self: *TreeState, rows_scope: *Scope, container: *Node, nodes: []const TreeNodeData) !void {
        const cx = self.cx;
        self.flat_count = 0;
        self.hovered_index = null;
        self.flat_node_rows = @as([MAX_NODES]?*Node, @splat(null));
        self.flat_node_indicators = @as([MAX_NODES]?*Node, @splat(null));
        self.selected_flat_index = null;
        self.selection_anchor = null;
        self.flatten(nodes, 0);

        // mount failure: built rows wholly reclaimed, row handles can't be kept
        errdefer {
            self.flat_node_rows = @as([MAX_NODES]?*Node, @splat(null));
            self.flat_count = 0;
        }
        try view.mount(rows_scope, cx, container, view.items(self, self.flat_nodes[0..self.flat_count], rowElement));
        // new rows refresh selection / expand / visibility from current data source
        self.applyModels(self.selected.peek(), self.expanded_ids.peek());
    }

    fn rowElement(self: *TreeState, flat: FlatNode, i: usize) view.ComponentOf(buildRow) {
        return view.component(buildRow, RowArgs{ .state = self, .flat = flat, .index = i });
    }

    const RowArgs = struct { state: *TreeState, flat: FlatNode, index: usize };

    /// one row: indent placeholder + expand indicator + label; row node recorded in flat_node_rows,
    /// click context belongs to row's scope
    fn buildRow(args: RowArgs, scope: *Scope, cx: *Cx) !*Node {
        const self = args.state;
        const flat = args.flat;
        const i = args.index;
        const t = self.tokens;
        const indent_px = @as(f32, @floatFromInt(flat.depth)) * self.indent;
        const indicator_text: []const u8 = if (flat.has_children) ">" else " ";
        var indicator: *Node = undefined;
        const row = try view.render(scope, cx, view.row(.{
            .style = .{ treeRowStyle(t), core.BoxStyle{ .cursor = .pointer } },
            // each row role=treeitem. expanded only meaningful for rows with children, leave null
            // for leaf
            .a11y = core.A11yProps{
                .role = .treeitem,
                .label = flat.data.label,
                .disabled = flat.data.disabled,
                .expanded = if (flat.has_children) false else null,
                .level = flat.depth + 1,
                .row_index = @intCast(i),
            },
        }, .{
            if (indent_px > 0) view.box(.{ .style = core.BoxStyle{
                .width = .{ .px = indent_px },
                .height = .{ .px = 1 },
            } }, {}) else null,
            // expand indicator
            // rows with children record indicator node (icon rotation / text > v refreshes with
            // expand state, see applyModels)
            view.box(.{ .style = treeIndicatorBoxStyle(t) }, view.branch(
                flat.has_children and self.expand_icon_asset != null,
                view.capture(&indicator, view.icon(.{ .style = treeExpandIconStyle(t), .tint = t.tokens.color.fg_secondary }, self.expand_icon_asset orelse undefined)),
                view.capture(&indicator, view.text(.{ .style = treeIndicatorTextStyle(t) }, indicator_text)),
            )),
            // label: grow text with padding
            view.attrs(.{ .style = treeLabelBoxStyle(t) }, view.text(.{ .style = treeLabelTextStyle(flat.data.disabled, t) }, flat.data.label)),
        }));
        errdefer cx.freeNode(row);
        if (flat.has_children) {
            if (self.expand_icon_asset != null) _ = try indicator.style.ensureExtFallible(cx.allocator);
            self.flat_node_indicators[i] = indicator;
        }

        if (!flat.data.disabled) {
            const click_ctx = try scope.allocator.create(TreeClickContext);
            click_ctx.* = .{ .state = self, .flat_index = i };
            try scope.adoptResource(@ptrCast(click_ctx), struct {
                fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                    alloc.destroy(@as(*TreeClickContext, @ptrCast(@alignCast(ptr))));
                }
            }.cleanup);
            hooks.setHoverHandler(row, true, Cx.simpleHandler(treeHover, click_ctx));
            hooks.setHoverHandler(row, false, Cx.simpleHandler(treeLeave, click_ctx));
            row.behavior.events.on_event = treeItemEventHandler;
            row.behavior.events.event_context = @ptrCast(click_ctx);
            if (row.behavior.interaction.a11y) |*a| {
                a.item_selection = .{ .context = @ptrCast(click_ctx), .set = setAccessibleItemSelection };
                if (flat.has_children) a.expansion = .{ .context = @ptrCast(click_ctx), .set = setAccessibleExpanded };
            }
        }
        self.flat_node_rows[i] = row;
        return row;
    }
};

/// TreeBuilder.mount return result
pub const TreeResult = struct {
    wrapper: *Node,
    /// selected / expanded set signals (null under `ui.split`)
    selected: ?*Signal([]const []const u8),
    expanded: ?*Signal([]const []const u8),
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: TreeResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

pub const TreeBuilder = struct {
    props: TreeProps,

    /// retain mode: mount
    pub fn mount(self: TreeBuilder, scope: *Scope, cx: *Cx) !TreeResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const t = cx.tokens;
        const p = self.props;

        const container = try view.render(my_scope, cx, view.box(.{
            .style = treeContainerStyle(t),
            .focusable = true,
            // container is role=tree: AT leverages this to treat lines below as hierarchy not
            // scattered rows
            .a11y = core.A11yProps{
                .role = .tree,
                .label = p.label_text,
                .multiselectable = p.selection_mode == .multi,
            },
        }, {}));
        // sweep: container guard armed until return
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Tree";
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;

        const selected = try reactive.resolveListModel([]const u8, my_scope, p.selected);
        const expanded = try reactive.resolveListModel([]const u8, my_scope, p.expanded);
        const state = try my_scope.allocator.create(TreeState);
        state.* = .{
            .selected = selected,
            .expanded_ids = expanded,
            .on_select = p.on_select,
            .selection_mode = p.selection_mode,
            .indent = p.indent,
            .expand_icon_asset = p.expand_icon_asset,
            .tokens = t,
            .cx = cx,
            .container = container,
            .selection_bg = treeSelectionBg(t),
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*TreeState, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        container.addDebugState(@ptrCast(state));

        try bind_mod.rebuildOn(cx, my_scope, p.nodes, container, state, TreeState.nodesKey, TreeState.buildRows);

        // keyboard navigation
        container.behavior.events.on_key_down = treeKeyHandler;
        container.behavior.events.key_context = @ptrCast(state);

        // selected / expanded are Model: interaction changes them, must have effect
        try my_scope.createEffect(state, TreeState.viewEffect);
        return .{ .wrapper = container, .selected = selected.asSignal(), .expanded = expanded.asSignal() };
    }
};

// ========== internal helpers ==========

const TreeClickContext = struct {
    state: *TreeState,
    flat_index: usize,
};

/// AT's ExpandCollapse: explicit target state, run through toggleExpand proposal pipeline.
fn setAccessibleExpanded(raw: *anyopaque, expanded: bool) bool {
    const ctx: *TreeClickContext = @ptrCast(@alignCast(raw));
    const state = ctx.state;
    const index = ctx.flat_index;
    if (index >= state.flat_count or !state.flat_nodes[index].has_children or state.flat_nodes[index].data.disabled) return false;
    if (state.expanded[index] != expanded) state.toggleExpand(index);
    return state.expanded[index] == expanded;
}

/// AT's SelectionItem: replace keeps only this row; add / remove flip only this row, single-select
/// rejects add when already have other selected. all run proposeSelection write-back pipeline,
/// result locked before on_select (callback may dismount component).
fn setAccessibleItemSelection(raw: *anyopaque, operation: core.A11yProps.ItemSelectionOperation) bool {
    const ctx: *TreeClickContext = @ptrCast(@alignCast(raw));
    const state = ctx.state;
    const index = ctx.flat_index;
    if (index >= state.flat_count or state.flat_nodes[index].data.disabled) return false;
    const want = operation != .remove;
    var bits = state.selected_bits;
    if (operation == .replace) {
        @memset(&bits, false);
        bits[index] = true;
    } else {
        if (state.isSelected(index) == want) return true;
        if (want and state.selection_mode == .single) {
            for (state.selected_bits[0..state.flat_count]) |bit| if (bit) return false;
        }
        bits[index] = want;
    }
    const on_select = state.on_select;
    const id = state.flat_nodes[index].data.id;
    if (!state.proposeSelection(&bits)) return false;
    if (want) {
        state.selected_flat_index = index;
    } else if (state.selected_flat_index == index) {
        state.selected_flat_index = null;
        for (0..state.flat_count) |candidate| {
            if (state.selected_bits[candidate]) {
                state.selected_flat_index = candidate;
                break;
            }
        }
    }
    state.selection_anchor = state.selected_flat_index;
    state.applySelectionStyles();
    if (on_select) |h| h.call(id);
    return true;
}

fn treeHover(ptr: *anyopaque) void {
    const c: *TreeClickContext = @ptrCast(@alignCast(ptr));
    c.state.hovered_index = c.flat_index;
    c.state.applySelectionStyles();
}
fn treeLeave(ptr: *anyopaque) void {
    const c: *TreeClickContext = @ptrCast(@alignCast(ptr));
    if (c.state.hovered_index == c.flat_index) c.state.hovered_index = null;
    c.state.applySelectionStyles();
}

fn treeItemEventHandler(event: Event, context: ?*anyopaque) EventResult {
    switch (event) {
        .click => |c| {
            const tc: *TreeClickContext = @ptrCast(@alignCast(context orelse return .ignored));
            const state = tc.state;
            const index = tc.flat_index;
            // read out values first: proposal may sync rebuild rows (release this context)
            if (state.flat_nodes[index].has_children) state.toggleExpand(index);
            state.selectNodeWithIntent(index, .{
                // macOS use Cmd, other platforms Ctrl, both recognized
                .toggle = c.modifiers.super or c.modifiers.ctrl,
                .range = c.modifiers.shift,
            });
            return .stop;
        },
        else => {},
    }
    return .ignored;
}

fn treeKeyHandler(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const state: *TreeState = @ptrCast(@alignCast(context orelse return .ignored));
    const sel = state.selected_flat_index orelse 0;

    switch (key) {
        .down => {
            // move to next visible enabled node; start from row 0 if not yet selected
            var next = if (state.selected_flat_index) |s| s + 1 else 0;
            while (next < state.flat_count) : (next += 1) {
                if (state.isVisible(next) and !state.flat_nodes[next].data.disabled) {
                    state.selectNode(next);
                    break;
                }
            }
            return .stop;
        },
        .up => {
            if (sel > 0) {
                var prev = sel - 1;
                while (true) {
                    if (state.isVisible(prev) and !state.flat_nodes[prev].data.disabled) {
                        state.selectNode(prev);
                        break;
                    }
                    if (prev == 0) break;
                    prev -= 1;
                }
            }
            return .stop;
        },
        .right => {
            if (sel < state.flat_count and state.flat_nodes[sel].has_children and !state.expanded[sel]) state.toggleExpand(sel);
            return .stop;
        },
        .left => {
            if (sel < state.flat_count and state.flat_nodes[sel].has_children and state.expanded[sel]) state.toggleExpand(sel);
            return .stop;
        },
        else => return .ignored,
    }
}

// ========== tests ==========

fn stateOf(r: TreeResult) *TreeState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

fn selectedCount(st: *const TreeState) usize {
    var n: usize = 0;
    for (0..st.flat_count) |i| n += @intFromBool(st.selected_bits[i]);
    return n;
}

const test_tree = [_]TreeNodeData{
    .{
        .id = "src",
        .label = "src",
        .children = &[_]TreeNodeData{
            .{ .id = "main.zig", .label = "main.zig" },
            .{
                .id = "ui",
                .label = "ui",
                .children = &[_]TreeNodeData{
                    .{ .id = "core.zig", .label = "core.zig" },
                },
            },
        },
    },
    .{ .id = "README", .label = "README.md" },
};

test "Tree: basic structure" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 5 flat nodes: src, main.zig, ui, core.zig, README
    try std.testing.expectEqual(@as(usize, 5), stateOf(result).flat_count);
}

test "Tree: initial visibility" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // depth=0 visible (src, README), depth>0 hidden
    const src_row = stateOf(result).flat_node_rows[0].?;
    try std.testing.expectEqual(@as(f32, 28), src_row.style.height.px);

    const main_row = stateOf(result).flat_node_rows[1].?;
    try std.testing.expectEqual(@as(f32, 0), main_row.style.height.px);
}

test "Tree: expand/collapse" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
        .expand_icon_asset = svg_assets.common.chevron_right,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // expand src (index 0)
    stateOf(result).toggleExpand(0);
    try std.testing.expect(stateOf(result).expanded[0]);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), stateOf(result).flat_node_indicators[0].?.style.rotate(), 0.0001);

    // main.zig (index 1) should be visible
    const main_row = stateOf(result).flat_node_rows[1].?;
    try std.testing.expectEqual(@as(f32, 28), main_row.style.height.px);

    // collapse src
    stateOf(result).toggleExpand(0);
    try std.testing.expect(!stateOf(result).expanded[0]);
    try std.testing.expectEqual(@as(f32, 0), stateOf(result).flat_node_indicators[0].?.style.rotate());
}

test "Tree: select node" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    stateOf(result).selectNode(0);
    try std.testing.expectEqual(@as(?usize, 0), stateOf(result).selected_flat_index);
}

test "Tree: 无选中时 Down 选第 0 行；方向键跳过 disabled 节点" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const nodes = [_]TreeNodeData{
        .{ .id = "a", .label = "A" },
        .{ .id = "b", .label = "B", .disabled = true },
        .{ .id = "c", .label = "C" },
    };
    const result = try Tree(.{ .nodes = &nodes }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expect(stateOf(result).selected_flat_index == null);
    _ = treeKeyHandler(.down, .{}, @ptrCast(stateOf(result)));
    try std.testing.expectEqual(@as(?usize, 0), stateOf(result).selected_flat_index);
    _ = treeKeyHandler(.down, .{}, @ptrCast(stateOf(result)));
    try std.testing.expectEqual(@as(?usize, 2), stateOf(result).selected_flat_index);
    _ = treeKeyHandler(.up, .{}, @ptrCast(stateOf(result)));
    try std.testing.expectEqual(@as(?usize, 0), stateOf(result).selected_flat_index);
}

// ── on_select payload + multi-select ────────────────────────────────

/// record node id received by callback, this was missing before
const SelectSpy = struct {
    last: [64]u8 = @as([64]u8, @splat(0)),
    last_len: usize = 0,
    calls: usize = 0,

    fn onSelect(self: *SelectSpy, id: []const u8) void {
        const n = @min(id.len, self.last.len);
        @memcpy(self.last[0..n], id[0..n]);
        self.last_len = n;
        self.calls += 1;
    }

    fn lastId(self: *const SelectSpy) []const u8 {
        return self.last[0..self.last_len];
    }
};

fn mountTreeForTest(
    ctx: *Cx,
    scope: *Scope,
    mode: SelectionMode,
    handler: ?Handler([]const u8),
) !TreeResult {
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const result = try Tree(.{
        .nodes = &test_tree,
        .selection_mode = mode,
        .on_select = handler,
    }).mount(scope, ctx);
    try root.appendChild(ctx.allocator, result.wrapper);
    return result;
}

test "Tree: on_select 回调带上被选中节点的 id（此前完全拿不到是谁）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var spy = SelectSpy{};
    const result = try mountTreeForTest(
        ctx,
        scope,
        .single,
        ctx.on(SelectSpy, &spy, SelectSpy.onSelect),
    );

    // flat order: src(0) main.zig(1) ui(2) core.zig(3) README(4)
    stateOf(result).selectNode(4);
    try std.testing.expectEqual(@as(usize, 1), spy.calls);
    try std.testing.expectEqualStrings("README", spy.lastId());
    try std.testing.expectEqualStrings("README", stateOf(result).selectedId().?);

    stateOf(result).selectNode(3);
    try std.testing.expectEqual(@as(usize, 2), spy.calls);
    try std.testing.expectEqualStrings("core.zig", spy.lastId());
}

test "Tree: single 模式选中新行取消旧行（默认，行为不变）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountTreeForTest(ctx, scope, .single, null);
    const st = stateOf(result);

    st.selectNode(0);
    // single mode Cmd also won't accumulate
    st.selectNodeWithIntent(4, .{ .toggle = true });
    try std.testing.expectEqual(@as(usize, 1), selectedCount(st));
    try std.testing.expect(st.isSelected(4));
    try std.testing.expect(!st.isSelected(0));
    // background also follows
    try std.testing.expect(st.flat_node_rows[4].?.getBackground().eql(ctx.tokens.tokens.color.selection_bg));
    try std.testing.expect(st.flat_node_rows[0].?.getBackground().eql(Color.TRANSPARENT));
}

test "Tree: multi 多选 —— Cmd 切换 / Shift 区间 / selectedIds" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountTreeForTest(ctx, scope, .multi, null);
    const st = stateOf(result);

    st.selectNode(0); // src
    st.selectNodeWithIntent(4, .{ .toggle = true }); // + README
    try std.testing.expectEqual(@as(usize, 2), selectedCount(st));
    try std.testing.expect(st.isSelected(0) and st.isSelected(4));

    const ids = result.selected.?.peek();
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("src", ids[0]);
    try std.testing.expectEqualStrings("README", ids[1]);

    // Cmd click 4 -> deselect
    st.selectNodeWithIntent(4, .{ .toggle = true });
    try std.testing.expectEqual(@as(usize, 1), selectedCount(st));
    try std.testing.expect(!st.isSelected(4));

    // Shift range: anchor is 4 (last toggle landing) -> redraw 1..4
    st.selectNode(1);
    st.selectNodeWithIntent(4, .{ .range = true });
    try std.testing.expectEqual(@as(usize, 4), selectedCount(st));
    for (1..5) |i| try std.testing.expect(st.isSelected(i));
    try std.testing.expect(!st.isSelected(0));

    // unmodified click clears rest
    st.selectNode(2);
    try std.testing.expectEqual(@as(usize, 1), selectedCount(st));
    try std.testing.expect(st.isSelected(2));
}

test "Tree: 选择提议被 ui.split 拦截时锚点退回，之后的 Shift 区间从原锚点展开" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Parent = struct {
        sel: *Signal([]const []const u8),
        allow: bool = true,
        fn write(self: *@This(), v: []const []const u8) void {
            if (self.allow) self.sel.set(v);
        }
    };
    var parent = Parent{ .sel = try scope.createList([]const u8, &.{}) };
    const result = try Tree(.{
        .nodes = &test_tree,
        .selection_mode = .multi,
        .selected = reactive.split(parent.sel, ctx.on(Parent, &parent, Parent.write)),
    }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    const st = stateOf(result);

    st.selectNode(1); // anchor = 1
    parent.allow = false;
    st.selectNode(4); // blocked: anchor still 1, current row still 1
    try std.testing.expect(st.isSelected(1) and !st.isSelected(4));
    try std.testing.expectEqual(@as(?usize, 1), st.selected_flat_index);
    parent.allow = true;
    st.selectNodeWithIntent(3, .{ .range = true }); // 1..3
    for (1..4) |i| try std.testing.expect(st.isSelected(i));
    try std.testing.expect(!st.isSelected(4));
}

test "Tree: split 父组件只重排了选中集合的顺序也算原样落地，锚点不回退" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Parent = struct {
        sel: *Signal([]const []const u8),
        buf: [16][]const u8 = undefined,
        fn write(self: *@This(), v: []const []const u8) void {
            // normalize to reverse order
            for (v, 0..) |x, i| self.buf[v.len - 1 - i] = x;
            self.sel.set(self.buf[0..v.len]);
        }
    };
    var parent = Parent{ .sel = try scope.createList([]const u8, &.{}) };
    const result = try Tree(.{
        .nodes = &test_tree,
        .selection_mode = .multi,
        .selected = reactive.split(parent.sel, ctx.on(Parent, &parent, Parent.write)),
    }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    const st = stateOf(result);

    st.selectNode(0);
    st.selectNodeWithIntent(2, .{ .toggle = true });
    try std.testing.expectEqual(@as(usize, 2), parent.sel.peek().len);
    try std.testing.expectEqual(@as(?usize, 2), st.selection_anchor);
    try std.testing.expectEqual(@as(?usize, 2), st.selected_flat_index);
}

test "Tree: on_select 以数据源为准——split 拒绝时不报，点已选中的行仍报（激活）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Parent = struct {
        sel: *Signal([]const []const u8),
        allow: bool = true,
        selects: usize = 0,
        last: []const u8 = "",
        fn write(self: *@This(), v: []const []const u8) void {
            if (self.allow) self.sel.set(v);
        }
        fn onSelect(self: *@This(), id: []const u8) void {
            self.selects += 1;
            self.last = id;
        }
    };
    var parent = Parent{ .sel = try scope.createList([]const u8, &.{}) };
    const result = try Tree(.{
        .nodes = &test_tree,
        .selected = reactive.split(parent.sel, ctx.on(Parent, &parent, Parent.write)),
        .on_select = ctx.on(Parent, &parent, Parent.onSelect),
    }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    const st = stateOf(result);

    st.selectNode(1);
    try std.testing.expectEqual(@as(usize, 1), parent.selects);
    // click already-selected row again: selection set unchanged, still activation
    st.selectNode(1);
    try std.testing.expectEqual(@as(usize, 2), parent.selects);
    // Parent rejected: don't report select
    parent.allow = false;
    st.selectNode(2);
    try std.testing.expectEqual(@as(usize, 2), parent.selects);
    try std.testing.expect(st.isSelected(1) and !st.isSelected(2));
}

test "Tree: bound selected / expanded — external writes drive the view; clicks propose new id sets" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const picked = try scope.createList([]const u8, &.{});
    const open_dirs = try scope.createList([]const u8, &.{});
    const result = try Tree(.{ .nodes = &test_tree, .selected = picked, .expanded = open_dirs }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    const st = stateOf(result);

    open_dirs.set(&.{ "src", "ui" }); // external expand
    try std.testing.expect(st.isVisible(3)); // core.zig
    try std.testing.expect(st.flat_node_rows[0].?.behavior.interaction.a11y.?.expanded.?);
    picked.set(&.{"main.zig"});
    try std.testing.expect(st.isSelected(1));
    try std.testing.expectEqualStrings("main.zig", st.selectedId().?);

    // click README: selection set replaced; click src: collapse and select
    _ = treeItemEventHandler(.{ .click = .{ .x = 0, .y = 0 } }, st.flat_node_rows[4].?.behavior.events.event_context);
    try std.testing.expectEqualStrings("README", picked.peek()[0]);
    _ = treeItemEventHandler(.{ .click = .{ .x = 0, .y = 0 } }, st.flat_node_rows[0].?.behavior.events.event_context);
    try std.testing.expectEqual(@as(usize, 1), open_dirs.peek().len);
    try std.testing.expectEqualStrings("ui", open_dirs.peek()[0]);
    try std.testing.expect(!st.isVisible(1));
}

test "Tree: a borrowed (non-owned) list signal is rejected" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const borrowed = try scope.createSignal([]const []const u8, &.{});
    try std.testing.expectError(error.ListModelNotOwned, Tree(.{ .nodes = &test_tree, .selected = borrowed }).mount(scope, ctx));
}

test "Tree: a nodes signal rebuilds the rows and keeps the selection by id" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const two = [_]TreeNodeData{ .{ .id = "a", .label = "A" }, .{ .id = "README", .label = "README.md" } };
    const nodes = try scope.createSignal([]const TreeNodeData, &two);
    const picked = try scope.createList([]const u8, &.{"README"});
    const result = try Tree(.{ .nodes = nodes, .selected = picked }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    try std.testing.expect(stateOf(result).isSelected(1));
    nodes.set(&test_tree);
    try std.testing.expectEqual(@as(usize, 5), stateOf(result).flat_count);
    try std.testing.expect(stateOf(result).isSelected(4)); // README changed position still selected
}

test "tree: 受控集合 / 动态节点的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tree(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const nodes = try scope.createSignal([]const TreeNodeData, &test_tree);
            const picked = try scope.createList([]const u8, &.{"README"});
            const open_dirs = try scope.createList([]const u8, &.{"src"});
            const r = try Tree(.{ .nodes = nodes, .selected = picked, .expanded = open_dirs }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}

// styles.zig test collection, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// per-alloc OOM sweep, see src/ui/components/oom_sweep.zig
test "tree: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tree", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const nodes = [_]TreeNodeData{ .{ .id = "a", .label = "A", .children = &.{ .{ .id = "a1", .label = "A1" }, .{ .id = "a2", .label = "A2", .disabled = true } } }, .{ .id = "b", .label = "B" } };
            const r = try Tree(.{ .nodes = &nodes }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
