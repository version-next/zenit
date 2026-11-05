/// ComboBox / Autocomplete, typeahead-in-input.
///
/// Composes Input (text) + Popover (bottom_start anchored panel, manual trigger). Option rows
/// rebuild with `options` (ui.rebuildOn, owned by Popover scope); filter = display toggle.
///
/// Data: `value: Model(?[]const u8)` (committed option value), `open: Model(bool)` (shared with
/// Popover). Input text is the query:
/// - Typing filters (case-insensitive label substring) and opens the panel; a manual edit
///   invalidates the committed selection (propose null)
/// - Click / Enter commits an option: propose value, write label to input, close panel
/// - External value write: input shows the label; external clear empties the input
///   (user-typed text is unaffected if the selection is invalid)
/// - No match: show a "No results found" empty state row
const std = @import("std");
const icons = @import("zenit_system_icons");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const popover_mod = @import("../popover/mod.zig");
const input_mod = @import("../input/mod.zig");
const TextInputState = input_mod.TextInputState;
const sm = @import("../select_headless/state_machine.zig");
const events = @import("../../events.zig");
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
const EventResult = events.EventResult;

/// Keyboard nav reuses select_headless pure function state machine
/// (wrap/page/home-end). ValueT = u32 = **visible (filtered) option index
/// in options**, because nav must walk only matching rows; arrow keys
/// skip hidden rows.
const NavValue = u32;
const NavState = sm.SelectState(NavValue);
const NavOption = sm.Option(NavValue);
/// Max visible options (excess hidden from keyboard nav)
const max_visible_options = 256;

/// Option (label display + value commit)
pub const ComboOption = struct {
    value: []const u8,
    label: []const u8,
    disabled: bool = false,
};

pub const ComboBoxProps = struct {
    /// Option (can pass signal/derived: rebuild row on content/address
    /// change). Strings owned by caller, must stay valid while current;
    /// static arrays shallow-copied.
    options: Source([]const ComboOption) = .{ .value = &.{} },
    placeholder: Source([]const u8) = .{ .value = "Type to search…" },
    label_text: Source([]const u8) = .{ .value = "" },
    width: f32 = 240,
    max_dropdown_height: f32 = 280,
    disabled: Source(bool) = .{ .value = false },
    /// Committed option value (null = unselected)
    value: Model(?[]const u8) = .{ .local = null },
    /// Called when user commits/edits invalidate selection and settle
    on_change: ?Handler(?[]const u8) = null,
    open: Model(bool) = .{ .local = false },
    on_open_change: ?Handler(bool) = null,
};

/// Create ComboBox: `W.ComboBox(.{ .options = &fruits, .value =
/// fruit }).mount(scope, cx)`
pub fn ComboBox(props: anytype) ComboBoxBuilder {
    return .{ .props = reactive.props.coerce(ComboBoxProps, props) };
}

pub const ComboBoxBuilder = struct {
    props: ComboBoxProps,

    pub fn mount(self: ComboBoxBuilder, scope: *Scope, cx: *Cx) !ComboBoxResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        return mountImpl(self.props, scope, cx);
    }
};

// -- Style layer in styles.zig --
const styles = @import("styles.zig");
const combo_item_height = styles.combo_item_height;
const comboPanelStyle = styles.comboPanelStyle;
const comboItemStyle = styles.comboItemStyle;
const comboEmptyStyle = styles.comboEmptyStyle;
const comboItemTextStyle = styles.comboItemTextStyle;
const comboEmptyTextStyle = styles.comboEmptyTextStyle;
const comboHighlightBg = styles.comboHighlightBg;

pub const ComboBoxState = struct {
    cx: *Cx,
    tokens: *const theme.ThemeTokens,
    value: reactive.Bound(?[]const u8),
    open: reactive.Bound(bool),
    disabled: Source(bool),
    /// Dynamic label: trigger's a11y name points to self-owned copy
    /// (static label borrows literal)
    label: Source([]const u8),
    label_copy: []u8 = &.{},
    on_change: ?Handler(?[]const u8),
    on_open_change: ?Handler(bool),
    /// combobox role node (pop.trigger); expanded/active_descendant/
    /// value_text write here (AT focus stays on input).
    trigger: *Node,
    input_state: *TextInputState,
    /// Input text value (Input's owned signal): programmatic write uses
    /// it, doesn't trigger on_change
    input_value: *Signal([]const u8),
    panel: *Node,
    items_box: *Node,
    empty_node: *Node,
    item_h: f32,
    /// Rebuild with options (array owned by rebuild subscope,
    /// cleared at start)
    options: []const ComboOption = &.{},
    item_nodes: []*Node = &.{},
    /// Selected index derived from value
    selected_index: ?usize = null,
    shown_open: bool = false,
    /// Closing discarded the query: the rows show all options again on the next open. The
    /// closing panel keeps the rows it had while it fades out.
    filter_reset_pending: bool = false,
    /// Last label written into input by component (check when clearing)
    shown_label: ?[]const u8 = null,

    // -- Keyboard navigation (reuse select_headless state machine) --
    /// State machine state; highlight_index = "visible option ordinal",
    /// not options index
    nav: NavState = .{},
    /// Visible options table: nav_options[k].value = true index in options
    nav_options_buf: [max_visible_options]NavOption = undefined,
    nav_options_len: usize = 0,
    /// highlight row bg / normal bg
    highlight_bg: core.Color = core.Color.TRANSPARENT,

    pub fn selectedOption(self: *const ComboBoxState) ?ComboOption {
        const i = self.selected_index orelse return null;
        return self.options[i];
    }

    /// Current options index of highlight (null if none)
    pub fn highlightedIndex(self: *const ComboBoxState) ?usize {
        const k = self.nav.highlight_index orelse return null;
        if (k >= self.nav_options_len) return null;
        return @intCast(self.nav_options_buf[k].value);
    }

    fn navOptions(self: *const ComboBoxState) []const NavOption {
        return self.nav_options_buf[0..self.nav_options_len];
    }

    fn indexOf(self: *const ComboBoxState, value: []const u8) ?usize {
        for (self.options, 0..) |o, i| {
            if (std.mem.eql(u8, o.value, value)) return i;
        }
        return null;
    }

    // ---- View ----

    fn viewEffect(self: *ComboBoxState) void {
        self.applyView(true);
    }

    fn applyView(self: *ComboBoxState, comptime tracked: bool) void {
        const v = self.value.readAs(tracked);
        const open = self.open.readAs(tracked);
        const disabled = self.disabled.read(tracked);
        if (self.trigger.behavior.interaction.a11y) |*a| a.disabled = disabled;
        // A closing popup may remain painted during its fade. Its options
        // leave the accessibility tree as soon as the control collapses.
        if (self.panel.behavior.interaction.a11y) |*a| a.hidden = !open;
        if (!self.label.isStatic()) {
            const text = self.label.read(tracked);
            if (!std.mem.eql(u8, self.label_copy, text)) {
                if (self.cx.allocator.dupe(u8, text)) |copy| {
                    self.cx.allocator.free(self.label_copy);
                    self.label_copy = copy;
                    if (self.trigger.behavior.interaction.a11y) |*a| a.label = copy;
                } else |err| std.log.err("[ComboBox] label copy failed: {}", .{err});
            }
        }
        const closing = self.shown_open and !open;
        const opening = !self.shown_open and open;
        self.shown_open = open;
        // Values not in options don't display as selected, don't write back
        self.selected_index = if (v) |s| self.indexOf(s) else null;
        if (closing) self.discardQuery() else self.syncInputText();
        if (opening and self.filter_reset_pending) _ = applyFilter(self, "");
        if (!open) self.nav.highlight_index = null;
        // The closing panel keeps its highlighted row while it fades out; the next open repaints.
        if (closing) {
            syncComboA11y(self);
        } else {
            applyHighlightStyles(self);
        }
    }

    /// Selected item changed: write its label to input;
    /// clear component-written when externally cleared (don't touch user typing)
    fn syncInputText(self: *ComboBoxState) void {
        if (self.selectedOption()) |opt| {
            if (self.shown_label) |shown| {
                if (shown.ptr == opt.label.ptr and shown.len == opt.label.len) return;
            }
            self.input_value.set(opt.label);
            self.shown_label = opt.label;
            _ = applyFilter(self, "");
        } else if (self.shown_label != null) {
            // Input still displays component-written label (clears when user
            // types); clear together when externally cleared
            self.input_value.set("");
            self.shown_label = null;
        }
    }

    /// Close panel = leave edit mode: input typing is filter draft, discard
    /// and return to data -- have selection show label, no selection clear.
    /// Else parent refuses clear, input forever shows text != value.
    fn discardQuery(self: *ComboBoxState) void {
        const text: []const u8 = if (self.selectedOption()) |opt| opt.label else "";
        if (!std.mem.eql(u8, self.input_value.peek(), text)) self.input_value.set(text);
        self.shown_label = if (self.selectedOption()) |opt| opt.label else null;
        self.filter_reset_pending = true;
    }

    // ---- Interaction: propose only ----

    fn proposeOpen(self: *ComboBoxState, v: bool) void {
        const on_change = self.on_open_change;
        const landed = self.open.commit(v) orelse return;
        if (on_change) |h| h.call(landed);
    }

    /// Return whether proposal settled
    fn proposeValue(self: *ComboBoxState, v: ?[]const u8) bool {
        const on_change = self.on_change;
        const landed = self.value.commit(v) orelse return false;
        if (on_change) |h| h.call(landed);
        return true;
    }

    // ---- Option rows (ui.rebuildOn) ----

    fn optionsKey(opts: []const ComboOption) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&opts.ptr));
        h.update(std.mem.asBytes(&opts.len));
        for (opts) |o| {
            h.update(std.mem.asBytes(&o.value.ptr));
            h.update(std.mem.asBytes(&o.label.ptr));
            h.update(o.value);
            h.update(o.label);
            h.update(&[_]u8{@intFromBool(o.disabled)});
        }
        return h.final();
    }

    const Parts = struct {
        nodes: []*Node = &.{},
        clicks: []ItemClickCtx = &.{},

        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const p: *Parts = @ptrCast(@alignCast(ptr));
            alloc.free(p.nodes);
            alloc.free(p.clicks);
            alloc.destroy(p);
        }
    };

    fn buildItems(self: *ComboBoxState, child: *Scope, container: *Node, opts: []const ComboOption) !void {
        // Let runtime stop referencing previous round's nodes/array
        self.options = &.{};
        self.item_nodes = &.{};
        self.nav_options_len = 0;
        self.nav.highlight_index = null;
        const cx = self.cx;
        const a = child.allocator;
        const parts = try a.create(Parts);
        parts.* = .{};
        try child.adoptResource(@ptrCast(parts), Parts.destroy);
        parts.nodes = try a.alloc(*Node, opts.len);
        parts.clicks = try a.alloc(ItemClickCtx, opts.len);
        try view.mount(child, cx, container, view.items(RowCtx{ .state = self, .parts = parts }, opts, rowElement));
        self.options = opts;
        self.item_nodes = parts.nodes;
        _ = applyFilter(self, self.input_state.getText());
        self.applyView(false);
    }

    const RowCtx = struct { state: *ComboBoxState, parts: *Parts };
    const RowArgs = struct { ctx: RowCtx, opt: ComboOption, index: usize };

    fn rowElement(ctx: RowCtx, opt: ComboOption, i: usize) view.ComponentOf(buildRow) {
        return view.component(buildRow, RowArgs{ .ctx = ctx, .opt = opt, .index = i });
    }

    /// Row = label + selected state check (second child;
    /// syncComboA11y indexes)
    fn buildRow(args: RowArgs, scope: *Scope, cx: *Cx) !*Node {
        const self = args.ctx.state;
        const parts = args.ctx.parts;
        const opt = args.opt;
        const i = args.index;
        const t = self.tokens;
        const check_px: core.Sizing = .{ .px = 16 };
        var item_style = comboItemStyle(t);
        if (!opt.disabled) item_style.cursor = .pointer;
        const item = try view.render(scope, cx, view.box(.{
            .style = item_style,
            .hit_test = !opt.disabled,
            .a11y = core.A11yProps{ .role = .option, .label = opt.label, .disabled = opt.disabled, .selected = false },
        }, .{
            // Label eats row's remaining width (push check to end)
            view.attrs(.{ .style = core.BoxStyle{ .width = .{ .grow = .{} } } }, view.text(.{ .style = comboItemTextStyle(opt.disabled, t) }, opt.label)),
            view.icon(.{ .style = .{ .width = check_px, .height = check_px, .opacity = 0 }, .tint = t.tokens.color.selection_fg }, icons.check),
        }));
        parts.nodes[i] = item;
        parts.clicks[i] = .{ .state = self, .index = i };
        item.behavior.events.event_context = @ptrCast(&parts.clicks[i]);
        item.behavior.events.on_event = onItemEvent;
        if (!opt.disabled) {
            if (item.behavior.interaction.a11y) |*a| a.item_selection = .{ .context = @ptrCast(&parts.clicks[i]), .set = setAccessibleItemSelection };
        }
        return item;
    }
};

pub const ComboBoxResult = struct {
    wrapper: *Node,
    /// Input wrapper (with label)
    input: *Node,
    panel: *Node,
    /// Selected value signal (null when ui.split)
    value: ?*Signal(?[]const u8),
    /// Open signal (null when ui.split)
    open: ?*Signal(bool),
    state: *ComboBoxState,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: ComboBoxResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

const ItemClickCtx = struct {
    state: *ComboBoxState,
    index: usize,
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Filter show/hide rows, rebuild nav table; return match count
fn applyFilter(state: *ComboBoxState, filter: []const u8) usize {
    state.filter_reset_pending = false;
    var matched: usize = 0;
    state.nav_options_len = 0;
    for (state.options, state.item_nodes, 0..) |opt, item, i| {
        const show = containsIgnoreCase(opt.label, filter);
        // display:none: no layout, no gap, no paint, no hit
        // (framework-native hide).
        item.setDisplay(if (show) .flex else .none);
        if (show) {
            matched += 1;
            // Only visible rows enter nav table; arrow keys won't stop on filtered
            if (state.nav_options_len < state.nav_options_buf.len) {
                state.nav_options_buf[state.nav_options_len] = .{
                    .value = @intCast(i),
                    .label = opt.label,
                    .disabled = opt.disabled,
                };
                state.nav_options_len += 1;
            }
        }
    }
    state.empty_node.setDisplay(if (matched == 0) .flex else .none);
    // After filter change old highlight index invalid (item might be filtered)
    state.nav.highlight_index = null;
    applyHighlightStyles(state);
    state.panel.markLayoutDirty();
    return matched;
}

/// Paint highlight bg to row node (only highlight has bg, rest transparent)
fn applyHighlightStyles(state: *ComboBoxState) void {
    const hi = state.highlightedIndex();
    for (state.item_nodes, 0..) |item, i| {
        const row_style = styles.optionStyle(state.tokens, state.selected_index == i).resolve(.{
            .is_selected = state.selected_index == i,
            .is_hovered = hi != null and hi.? == i,
            .is_disabled = state.options[i].disabled,
        });
        const want = row_style.background.?;
        if (item.children.items[0].getText()) |old| {
            var text = old;
            text.color = row_style.text_color.?;
            item.children.items[0].setText(text);
        }
        item.setBackgroundRaw(want);
        // The second child is the selected option's check icon.
        if (item.children.items.len > 1) {
            item.children.items[1].setOpacity(if (state.selected_index == i) 1 else 0);
        }
        item.markRenderDirty();
    }
    syncComboA11y(state);
}

/// a11y state follows interaction: expanded with open,
/// active_descendant with highlight, value_text/option.selected with value.
fn syncComboA11y(state: *ComboBoxState) void {
    if (state.trigger.behavior.interaction.a11y) |*a| {
        a.expanded = state.shown_open;
        a.active_descendant_element_id = if (state.highlightedIndex()) |idx|
            state.item_nodes[idx].element_id_raw
        else
            0xFFFFFFFF;
        a.value_text = if (state.selectedOption()) |opt| opt.label else null;
    }
    for (state.item_nodes, 0..) |item, i| {
        const selected = state.selected_index != null and state.selected_index.? == i;
        if (item.behavior.interaction.a11y) |*a| {
            a.selected = selected;
        }
    }
    state.trigger.markRenderDirty();
}

/// Commit index (Enter/click): propose value + close;
/// input written back label by view
fn commitIndex(state: *ComboBoxState, index: usize) void {
    if (state.disabled.peek()) return;
    if (index >= state.options.len) return;
    const opt = state.options[index];
    if (opt.disabled) return;
    _ = state.proposeValue(opt.value);
    state.proposeOpen(false);
    // Data source unchanged (re-selected same): view doesn't run;
    // write label to modified input
    if (state.selected_index == index and !std.mem.eql(u8, state.input_state.getText(), opt.label)) {
        state.input_value.set(opt.label);
        state.shown_label = opt.label;
        _ = applyFilter(state, "");
    }
    applyHighlightStyles(state);
}

/// ComboBox keyboard handling: navigation delegated to select_headless
/// state machine; this maps KeyCode->Action and visible-index->options-index.
fn comboKeyDown(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const state: *ComboBoxState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.disabled.peek()) return .ignored;

    const action: ?sm.Action = switch (key) {
        .down => .arrow_down,
        .up => .arrow_up,
        .home => .home_key,
        .end => .end_key,
        .page_up => .page_up,
        .page_down => .page_down,
        .escape => .escape,
        .@"return" => .enter,
        else => null,
    };
    const a = action orelse return .ignored;

    // Close + arrow = open panel and land on first item
    // (native ComboBox behavior)
    const was_open = state.shown_open;
    if (!was_open and (a == .arrow_down or a == .arrow_up)) {
        state.proposeOpen(true);
        // Open refused: don't move highlight on invisible list
        if (!state.open.peek()) return .stop;
    }

    const prev_open = state.nav.open;
    sm.step(NavValue, &state.nav, state.navOptions(), a, 0);
    // State machine only for nav state; open/close by data source
    state.nav.open = prev_open;

    switch (a) {
        .enter => {
            if (state.highlightedIndex()) |idx| {
                commitIndex(state, idx);
            } else {
                // No highlight + Enter: don't consume, let form submit etc. handle
                return .ignored;
            }
        },
        .escape => {
            // Panel not open + Escape: don't consume (outer Modal etc. need it)
            if (!was_open) return .ignored;
            state.proposeOpen(false);
        },
        else => {},
    }
    applyHighlightStyles(state);
    return .stop;
}

fn onInputChanged(state: *ComboBoxState, text: []const u8) void {
    // Manual edit invalidates selection (value by click only). Parent
    // refuses clear: keep "label shown" record so later view refresh (panel
    // open) won't overwrite user input. Clear shown_label first, then propose: when the proposal
    // settles the view effect may re-run synchronously, and by then it must already know the
    // label is no longer displayed.
    const prev_label = state.shown_label;
    state.shown_label = null;
    if (state.value.peek() != null and !state.proposeValue(null)) state.shown_label = prev_label;
    _ = applyFilter(state, text);
    if (!state.shown_open) state.proposeOpen(true);
}

/// AT ExpandCollapse: explicit target state, same propose pipeline as
/// keyboard/click. Result fixed before on_open_change (callback might
/// unmount).
fn setAccessibleExpanded(raw: *anyopaque, expanded: bool) bool {
    const state: *ComboBoxState = @ptrCast(@alignCast(raw));
    if (state.disabled.peek()) return false;
    if (state.shown_open == expanded) return true;
    const on_change = state.on_open_change;
    const landed = state.open.commit(expanded) orelse return false;
    if (on_change) |h| h.call(landed);
    return landed == expanded;
}

/// AT SelectionItem (single): select/remove both only propose value,
/// input text written/cleared by view per selection; don't change open
/// (ExpandCollapse's job). Return by settled==proposed; fixed before
/// on_change (callback might unmount).
fn setAccessibleItemSelection(raw: *anyopaque, operation: core.A11yProps.ItemSelectionOperation) bool {
    const ctx: *ItemClickCtx = @ptrCast(@alignCast(raw));
    const state = ctx.state;
    if (state.disabled.peek() or ctx.index >= state.options.len or state.options[ctx.index].disabled) return false;
    const selected = state.selected_index == ctx.index;
    const want: ?[]const u8 = switch (operation) {
        .replace, .add => blk: {
            if (selected) return true;
            if (operation == .add and state.selected_index != null) return false;
            break :blk state.options[ctx.index].value;
        },
        .remove => blk: {
            if (!selected) return true;
            break :blk null;
        },
    };
    const on_change = state.on_change;
    const landed = state.value.commit(want) orelse return false;
    const ok = if (landed == null or want == null) landed == null and want == null else std.mem.eql(u8, landed.?, want.?);
    applyHighlightStyles(state);
    if (on_change) |h| h.call(landed);
    return ok;
}

fn onItemEvent(event: events.Event, context: ?*anyopaque) EventResult {
    const ctx: *ItemClickCtx = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .click => {
            commitIndex(ctx.state, ctx.index);
            return .stop;
        },
        .mouse_enter => {
            for (ctx.state.nav_options_buf[0..ctx.state.nav_options_len], 0..) |nav_opt, visible_index| {
                if (nav_opt.value == ctx.index and !nav_opt.disabled) {
                    ctx.state.nav.highlight_index = @intCast(visible_index);
                    applyHighlightStyles(ctx.state);
                    return .handled;
                }
            }
        },
        .mouse_leave => {
            if (ctx.state.highlightedIndex() == ctx.index) {
                ctx.state.nav.highlight_index = null;
                applyHighlightStyles(ctx.state);
            }
            return .handled;
        },
        else => {},
    }
    return .ignored;
}

const OwnedOptions = struct {
    items: []ComboOption = &.{},

    fn destroy(ptr: *anyopaque, alloc: Allocator) void {
        const h: *OwnedOptions = @ptrCast(@alignCast(ptr));
        alloc.free(h.items);
        alloc.destroy(h);
    }
};

/// mount ComboBox. Default style matches select_headless
/// (bg_primary panel + hover row).
fn mountImpl(props: ComboBoxProps, scope: *Scope, cx: *Cx) !ComboBoxResult {
    const my_scope = try scope.childScope();
    // Failure: dispose my_scope first (hook/resource destroyed at
    // node lifetime) then free wrapper
    var wrapper_node: ?*Node = null;
    errdefer {
        my_scope.dispose();
        if (wrapper_node) |w| cx.freeNode(w);
    }
    const allocator = cx.allocator;
    const t = cx.tokens;
    reactive.checkBorrow(my_scope, props.options);
    reactive.checkBorrow(my_scope, props.label_text);
    reactive.checkBorrow(my_scope, props.disabled);

    const value = try reactive.resolveModel(?[]const u8, my_scope, props.value);
    const open = try reactive.resolveModel(bool, my_scope, props.open);
    // Popover and component share same open source: click outside by
    // Popover, input/select by component
    const pop_open: Model(bool) = open.toModel();

    // Static options shallow-copied into scope: runtime keeps reading
    // in click/view
    var options = props.options;
    if (props.options == .value) {
        const holder = try my_scope.allocator.create(OwnedOptions);
        holder.* = .{};
        try my_scope.adoptResource(@ptrCast(holder), OwnedOptions.destroy);
        holder.items = try my_scope.allocator.dupe(ComboOption, props.options.value);
        options = .{ .value = holder.items };
    }

    // -- Popover (manual trigger; panel bottom_start anchored +
    // follows trigger width) --
    const pop = try popover_mod.Popover(.{
        .position = .bottom_start,
        .trigger = .manual,
        .offset = .{ .static = 4 },
        .flip = false,
        .width = props.width,
        .match_trigger_width = true,
        .constrain_width_to_viewport = true,
        .max_height = props.max_dropdown_height,
        .open = pop_open,
        .on_open_change = props.on_open_change,
    }).mount(my_scope, cx);
    wrapper_node = pop.wrapper;
    pop.wrapper.meta.ownership.meta.component_name = "ComboBox";

    // ── State ──
    const state = try my_scope.allocator.create(ComboBoxState);
    state.label_copy = &.{};
    state.cx = cx;
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const st: *ComboBoxState = @ptrCast(@alignCast(ptr));
            st.cx.allocator.free(st.label_copy);
            alloc.destroy(st);
        }
    }.destroy);

    // Initial selected item's label is input's initial value
    // (don't write signal during mount)
    const initial_label: ?[]const u8 = blk: {
        const v0 = value.peek() orelse break :blk null;
        for (options.peek()) |o| {
            if (std.mem.eql(u8, o.value, v0)) break :blk o.label;
        }
        break :blk null;
    };

    // -- Input (stuffed into pop.trigger as anchor) --
    pop.trigger.style.width = .{ .px = props.width };
    pop.trigger.style.height = .{ .fit = .{} };
    var input_result: input_mod.InputResult = undefined;
    try view.mount(my_scope, cx, pop.trigger, view.capture(&input_result, input_mod.Input(.{
        .value = initial_label orelse "",
        .placeholder = props.placeholder,
        .leading_icon_asset = icons.search,
        .append_icon_asset = icons.chevron_down,
        .expanded = open.read,
        .raised = true,
        .label_text = props.label_text,
        .width = props.width,
        .disabled = props.disabled,
        .on_change = cx.on(ComboBoxState, state, onInputChanged),
    })));

    // a11y: combobox + listbox popup; expanded initially collapsed
    // (later view-follows)
    pop.trigger.behavior.interaction.a11y = .{
        .role = .combobox,
        .has_popup = .listbox,
        // Static label borrows literal; dynamic label written by view
        // into self-owned copy
        .label = if (props.label_text.isStatic() and props.label_text.peek().len > 0) props.label_text.peek() else null,
        .disabled = props.disabled.peek(),
        .expanded = false,
        .expansion = .{ .context = @ptrCast(state), .set = setAccessibleExpanded },
        .active_descendant_element_id = 0xFFFFFFFF,
    };

    // -- Panel -- a11y: panel is listbox, rows are option
    // (combobox->listbox->option three-level role chain)
    pop.content.behavior.interaction.a11y = .{ .role = .listbox };
    const panel_style = comboPanelStyle(t);
    // the ext block first: applyTo cannot report a failed allocation and would drop ext fields
    if (panel_style.needsExt()) _ = try pop.content.style.ensureExtFallible(allocator);
    panel_style.applyTo(&pop.content.style, allocator);
    if (panel_style.background) |bg| pop.content.setBackgroundRaw(bg);
    // Popover's default chrome 4px radius; ComboBox uses Pvnqs's 8px
    // panel, sync hit/clip shape to avoid only border rounding while
    // content clips with old radius.
    const panel_radius = styles.comboPanelRadius(t);
    const panel_ext = try pop.content.style.ensureExtFallible(allocator);
    panel_ext.hit_shape = .{ .rounded_rect = panel_radius };
    panel_ext.clip_shape = .{ .rounded_rect = panel_radius };

    // Option row container (rebuild with options) + empty state row
    // (default collapsed)
    const Panel = struct { items_box: *Node = undefined, empty: *Node = undefined };
    var panel: Panel = .{};
    try view.mount(my_scope, cx, pop.content, .{
        view.capture(&panel.items_box, view.box(.{ .style = .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .column,
            .gap = pop.content.style.gap,
        } }, {})),
        view.capture(&panel.empty, view.box(
            .{ .style = comboEmptyStyle(t), .hit_test = false },
            view.text(.{ .style = comboEmptyTextStyle(t) }, "No results found"),
        )),
    });
    const items_box = panel.items_box;
    const empty_node = panel.empty;

    state.* = .{
        .cx = cx,
        .tokens = t,
        .value = value,
        .open = open,
        .disabled = props.disabled,
        .label = props.label_text,
        .on_change = props.on_change,
        .on_open_change = props.on_open_change,
        .trigger = pop.trigger,
        .input_state = input_result.state,
        .input_value = input_result.value.?,
        .panel = pop.content,
        .items_box = items_box,
        .empty_node = empty_node,
        .item_h = combo_item_height,
        .highlight_bg = comboHighlightBg(t),
        .shown_label = initial_label,
    };
    pop.wrapper.addDebugState(@ptrCast(state));
    // Dynamic label: trigger's a11y name points to self-owned copy
    // (later view-follows)
    if (!props.label_text.isStatic()) {
        state.label_copy = try cx.allocator.dupe(u8, props.label_text.peek());
        pop.trigger.behavior.interaction.a11y.?.label = state.label_copy;
    }

    // Keyboard nav on Input node: focus always on input (panel doesn't
    // steal), so arrow/Enter/Escape start from Input.
    input_result.node.behavior.events.key_context = @ptrCast(state);
    input_result.node.behavior.events.on_key_down = comboKeyDown;

    // Write content (portal) rebuild and view effect both owned by
    // Popover's scope
    try bind_mod.rebuildOn(cx, pop.scope, options, items_box, state, ComboBoxState.optionsKey, ComboBoxState.buildItems);
    try pop.scope.createEffect(state, ComboBoxState.viewEffect);

    return .{
        .wrapper = pop.wrapper,
        .input = input_result.node,
        .panel = pop.content,
        .value = value.asSignal(),
        .open = open.asSignal(),
        .state = state,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "containsIgnoreCase" {
    try testing.expect(containsIgnoreCase("Apple", "app"));
    try testing.expect(containsIgnoreCase("Banana", "NAN"));
    try testing.expect(!containsIgnoreCase("Cherry", "apple"));
    try testing.expect(containsIgnoreCase("anything", ""));
}

const fruit = [_]ComboOption{
    .{ .value = "a", .label = "Apple" },
    .{ .value = "b", .label = "Banana" },
    .{ .value = "c", .label = "Cherry" },
};

const CEnv = struct {
    cx: *Cx,
    scope: *Scope,
    root: *Node,

    fn init() !CEnv {
        const cx = try Cx.init(testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(600, 400);
        const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
        cx.root = root;
        return .{ .cx = cx, .scope = try Scope.init(testing.allocator, null, cx.owner), .root = root };
    }

    fn deinit(self: CEnv) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn mount(self: CEnv, props: anytype) !ComboBoxResult {
        const cb = try ComboBox(props).mount(self.scope, self.cx);
        try self.root.appendChild(testing.allocator, cb.wrapper);
        return cb;
    }
};

/// Simulate user typing in input (go through Input's edit exit).
/// Real path: select-all then input. Input writes full text to data source,
/// then calls onInputChanged.
fn typeText(cb: ComboBoxResult, text: []const u8) void {
    const st = cb.state.input_state;
    _ = input_mod.inputEventHandler(.{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } }, @ptrCast(st));
    _ = input_mod.inputEventHandler(.{ .text_input = .{ .text = text } }, @ptrCast(st));
}

test "ComboBox: 过滤 + 点选写回输入框并提议 value / 关闭" {
    const env = try CEnv.init();
    defer env.deinit();
    const cb = try env.mount(.{ .options = &fruit, .width = 240 });
    const st = cb.state;

    // RYMhT / ComboBox open: inset 4, row 28, horizontal padding 8, no row gap.
    try testing.expectEqual(@as(f32, 0), cb.panel.style.gap);
    try testing.expectEqual(@as(f32, 4), cb.panel.style.padding.top);
    try testing.expectEqual(@as(f32, 10), cb.panel.style.border.radius);
    try testing.expectEqual(@as(usize, 1), cb.panel.style.shadowSlice().len);
    for (st.item_nodes) |item| {
        try testing.expectEqual(@as(f32, combo_item_height), item.style.height.px);
        try testing.expectEqual(@as(f32, 0), item.style.padding.top);
        try testing.expectEqual(@as(f32, 8), item.style.padding.left);
        try testing.expect(item.style.overflow_hidden);
    }

    // Type "an" -> only Banana matches, panel opens
    typeText(cb, "an");
    try testing.expectEqual(core.Display.none, st.item_nodes[0].style.display);
    try testing.expectEqual(core.Display.flex, st.item_nodes[1].style.display);
    try testing.expectEqual(core.Display.none, st.empty_node.style.display);
    try testing.expect(cb.open.?.peek());

    // No match -> empty state row expands
    typeText(cb, "zzz");
    try testing.expectEqual(core.Display.flex, st.empty_node.style.display);

    // Click Banana -> value commits, label written to input, panel closes
    var click_ctx = ItemClickCtx{ .state = st, .index = 1 };
    _ = onItemEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(&click_ctx));
    try testing.expectEqualStrings("b", cb.value.?.peek().?);
    try testing.expectEqualStrings("Banana", st.input_state.getText());
    try testing.expect(!cb.open.?.peek());
    try testing.expectEqual(@as(f32, 1), st.item_nodes[1].children.items[1].getOpacity());

    // First real edit after click-write filters normally (old implementation
    // suppressed flag swallowed), invalidates selection
    typeText(cb, "Ch");
    try testing.expect(cb.value.?.peek() == null);
    try testing.expectEqual(core.Display.flex, st.item_nodes[2].style.display);
    try testing.expectEqual(core.Display.none, st.item_nodes[1].style.display);
}

test "ComboBox: 外部写入 value 写回 label；外部清空只在输入框仍显示原 label 时清文字" {
    const env = try CEnv.init();
    defer env.deinit();
    const v = try env.scope.createSignal(?[]const u8, "c");
    const cb = try env.mount(.{ .options = &fruit, .value = v });
    try testing.expectEqualStrings("Cherry", cb.state.input_state.getText());
    v.set("a");
    try testing.expectEqualStrings("Apple", cb.state.input_state.getText());
    v.set(null);
    try testing.expectEqualStrings("", cb.state.input_state.getText());
    // External clear while user typing doesn't overwrite input
    v.set("b");
    typeText(cb, "Bananas?");
    v.set(null);
    try testing.expectEqualStrings("Bananas?", cb.state.input_state.getText());
    // Close panel: no selected item, typed text (not any option) discarded
    try testing.expect(cb.open.?.peek());
    cb.open.?.set(false);
    try testing.expectEqualStrings("", cb.state.input_state.getText());
}

test "ComboBox: options 来自 signal —— 换选项重建行，选择按新选项派生" {
    const env = try CEnv.init();
    defer env.deinit();
    const opts = try env.scope.createSignal([]const ComboOption, fruit[0..2]);
    const v = try env.scope.createSignal(?[]const u8, "c");
    const cb = try env.mount(.{ .options = opts, .value = v });
    try testing.expectEqual(@as(usize, 2), cb.state.item_nodes.len);
    try testing.expect(cb.state.selected_index == null);
    opts.set(&fruit);
    try testing.expectEqual(@as(usize, 3), cb.state.items_box.children.items.len);
    try testing.expectEqual(@as(?usize, 2), cb.state.selected_index);
    try testing.expectEqualStrings("Cherry", cb.state.input_state.getText());
}

test "ComboBox 键盘：arrow-then-Enter 选中；箭头只走可见行；Escape 关闭" {
    const env = try CEnv.init();
    defer env.deinit();
    const cb = try env.mount(.{ .options = &fruit });
    const st = cb.state;
    try testing.expect(cb.input.behavior.events.on_key_down != null);

    // Close + down arrow -> open panel and land on first item
    try testing.expectEqual(EventResult.stop, comboKeyDown(.down, .{}, @ptrCast(st)));
    try testing.expect(cb.open.?.peek());
    try testing.expectEqual(@as(?usize, 0), st.highlightedIndex());
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 1), st.highlightedIndex());
    try testing.expect(st.item_nodes[1].getBackground().eql(st.highlight_bg));
    _ = comboKeyDown(.@"return", .{}, @ptrCast(st));
    try testing.expectEqualStrings("b", cb.value.?.peek().?);
    try testing.expect(!cb.open.?.peek());

    // After filter, arrow only walks visible rows ("an" -> Banana)
    typeText(cb, "an");
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 1), st.highlightedIndex());
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 1), st.highlightedIndex());

    _ = comboKeyDown(.escape, .{}, @ptrCast(st));
    try testing.expect(!cb.open.?.peek());
    // No highlight + Enter doesn't consume
    try testing.expectEqual(EventResult.ignored, comboKeyDown(.@"return", .{}, @ptrCast(st)));
}

test "ComboBox: ui.split 拒绝开合时箭头不移动高亮；拒绝提交时选择不变" {
    const env = try CEnv.init();
    defer env.deinit();
    const Parent = struct {
        o: *Signal(bool),
        v: *Signal(?[]const u8),
        fn writeO(_: *@This(), _: bool) void {}
        fn writeV(_: *@This(), _: ?[]const u8) void {}
    };
    var parent = Parent{ .o = try env.scope.createSignal(bool, false), .v = try env.scope.createSignal(?[]const u8, null) };
    const cb = try env.mount(.{
        .options = &fruit,
        .open = reactive.split(parent.o, env.cx.on(Parent, &parent, Parent.writeO)),
        .value = reactive.split(parent.v, env.cx.on(Parent, &parent, Parent.writeV)),
    });
    _ = comboKeyDown(.down, .{}, @ptrCast(cb.state));
    try testing.expect(cb.state.highlightedIndex() == null);
    var click_ctx = ItemClickCtx{ .state = cb.state, .index = 0 };
    _ = onItemEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(&click_ctx));
    try testing.expect(cb.state.selected_index == null);
    try testing.expectEqualStrings("", cb.state.input_state.getText());
}

test "ComboBox: 父组件拒绝清空选择时，编辑中不覆盖用户输入，关闭后回到选中项的标签；面板关着时 Escape 不吞" {
    const env = try CEnv.init();
    defer env.deinit();
    const Parent = struct {
        v: *Signal(?[]const u8),
        fn write(self: *@This(), x: ?[]const u8) void {
            if (x != null) self.v.set(x); // Only accept selection, not clear
        }
    };
    var parent = Parent{ .v = try env.scope.createSignal(?[]const u8, "b") };
    const cb = try env.mount(.{ .options = &fruit, .value = reactive.split(parent.v, env.cx.on(Parent, &parent, Parent.write)) });
    try testing.expectEqualStrings("Banana", cb.state.input_state.getText());
    typeText(cb, "Ch"); // Clear refused; panel open settled -> view re-runs
    try testing.expect(cb.open.?.peek());
    try testing.expectEqualStrings("Ch", cb.state.input_state.getText());
    try testing.expectEqualStrings("b", parent.v.peek().?);

    _ = comboKeyDown(.escape, .{}, @ptrCast(cb.state));
    try testing.expect(!cb.open.?.peek());
    // Close = leave edit mode: filter draft discarded, input returns to
    // data source (still selected b)
    try testing.expectEqualStrings("Banana", cb.state.input_state.getText());
    try testing.expectEqual(EventResult.ignored, comboKeyDown(.escape, .{}, @ptrCast(cb.state)));
}

test "ComboBox: a closing panel keeps its filtered rows; the next open shows every option" {
    const env = try CEnv.init();
    defer env.deinit();
    const cb = try env.mount(.{ .options = &fruit });
    const st = cb.state;
    typeText(cb, "Bana");
    try testing.expect(cb.open.?.peek());
    try testing.expectEqual(core.Display.none, st.item_nodes[0].style.display);
    try testing.expectEqual(core.Display.flex, st.item_nodes[1].style.display);

    // Closing discards the draft in the input, but the fading panel keeps showing "Banana".
    _ = comboKeyDown(.escape, .{}, @ptrCast(st));
    try testing.expect(!cb.open.?.peek());
    try testing.expectEqualStrings("", st.input_state.getText());
    try testing.expectEqual(core.Display.none, st.item_nodes[0].style.display);
    try testing.expectEqual(core.Display.flex, st.item_nodes[1].style.display);
    try testing.expectEqual(core.Display.none, st.item_nodes[2].style.display);

    // Reopening shows every option again.
    cb.open.?.set(true);
    for (st.item_nodes) |item| try testing.expectEqual(core.Display.flex, item.style.display);

    // Typing after a close filters by the new text (the pending reset does not override it).
    _ = comboKeyDown(.escape, .{}, @ptrCast(st));
    typeText(cb, "Ch");
    try testing.expect(cb.open.?.peek());
    try testing.expectEqual(core.Display.none, st.item_nodes[1].style.display);
    try testing.expectEqual(core.Display.flex, st.item_nodes[2].style.display);
}

test "a11y: ComboBox expanded/active_descendant/value 跟随交互且可撤回" {
    const env = try CEnv.init();
    defer env.deinit();
    const cb = try env.mount(.{ .options = fruit[0..2], .width = 240 });
    env.cx.layout();
    _ = env.cx.render();

    // Assert a11y tree (actually sent to AT), not props struct.
    const eid = core.ElementId.fromRaw(cb.state.trigger.element_id_raw);
    {
        const n = env.cx.accessibility_tree.getNode(eid).?;
        try testing.expectEqual(core.a11y_tree.Role.combobox, n.role);
        try testing.expect(n.state.haspopup);
        try testing.expect(n.state.expanded_present);
        try testing.expect(!n.state.expanded);
        try testing.expect(n.active_descendant.isNull());
        try testing.expectEqual(@as(u64, 0), n.text_hash);
    }

    _ = comboKeyDown(.down, .{}, @ptrCast(cb.state));
    env.cx.layout();
    _ = env.cx.render();
    {
        const n = env.cx.accessibility_tree.getNode(eid).?;
        try testing.expect(n.state.expanded);
        try testing.expectEqual(cb.state.item_nodes[0].element_id_raw, n.active_descendant.raw());
    }

    _ = comboKeyDown(.@"return", .{}, @ptrCast(cb.state));
    env.cx.layout();
    _ = env.cx.render();
    {
        const n = env.cx.accessibility_tree.getNode(eid).?;
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(std.hash.Wyhash.hash(0, "Apple"), n.text_hash);
    }
    try testing.expect(cb.state.item_nodes[0].behavior.interaction.a11y.?.selected);
    try testing.expect(!cb.state.item_nodes[1].behavior.interaction.a11y.?.selected);

    // Manual edit invalidates selection -> value retracted, selected bit
    // retracted
    typeText(cb, "ban");
    env.cx.layout();
    _ = env.cx.render();
    try testing.expectEqual(@as(u64, 0), env.cx.accessibility_tree.getNode(eid).?.text_hash);
    try testing.expect(!cb.state.item_nodes[0].behavior.interaction.a11y.?.selected);
}

test "ComboBox: 动态标签同步到 combobox 的 a11y 名称（自持副本）" {
    const env = try CEnv.init();
    defer env.deinit();
    const label = try env.scope.createText("Fruit", .{});
    const cb = try env.mount(.{ .options = &fruit, .label_text = label });
    try testing.expectEqualStrings("Fruit", cb.state.trigger.behavior.interaction.a11y.?.label.?);
    label.set("Favourite fruit");
    try testing.expectEqualStrings("Favourite fruit", cb.state.trigger.behavior.interaction.a11y.?.label.?);
}

// styles.zig test collection; this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig
const sweep_opts = [_]ComboOption{ .{ .value = "a", .label = "Apple" }, .{ .value = "b", .label = "Banana" } };
test "combo_box: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("combo_box", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try ComboBox(.{ .options = &sweep_opts, .width = 240 }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "combo_box(dynamic): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("combo_box(dynamic)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const opts = try scope.createSignal([]const ComboOption, &sweep_opts);
            const v = try scope.createSignal(?[]const u8, "b");
            const label = try scope.createText("Fruit", .{});
            return (try ComboBox(.{ .options = opts, .value = v, .label_text = label }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "ComboBox: a11y item_selection / expansion —— 返回值如实反映受控拒绝" {
    const env = try CEnv.init();
    defer env.deinit();
    const Parent = struct {
        v: *Signal(?[]const u8),
        fn write(self: *@This(), x: ?[]const u8) void {
            if (x != null) self.v.set(x); // Only accept selection, not clear
        }
    };
    var parent = Parent{ .v = try env.scope.createSignal(?[]const u8, null) };
    const cb = try env.mount(.{ .options = &fruit, .value = reactive.split(parent.v, env.cx.on(Parent, &parent, Parent.write)) });
    const sel0 = cb.state.item_nodes[0].behavior.interaction.a11y.?.item_selection.?;
    const sel1 = cb.state.item_nodes[1].behavior.interaction.a11y.?.item_selection.?;
    try testing.expect(sel0.set(sel0.context, .replace));
    try testing.expectEqualStrings(fruit[0].value, parent.v.peek().?);
    try testing.expect(!sel1.set(sel1.context, .add)); // Single-select: add fails when selection exists
    try testing.expect(!sel0.set(sel0.context, .remove)); // Parent refuses clear
    try testing.expectEqualStrings(fruit[0].value, parent.v.peek().?);
    const expansion = cb.state.trigger.behavior.interaction.a11y.?.expansion.?;
    const eid = core.ElementId.fromRaw(cb.state.trigger.element_id_raw);
    try testing.expect(expansion.set(expansion.context, true));
    try testing.expect(cb.state.shown_open);
    env.cx.layout();
    _ = env.cx.render();
    try testing.expect(env.cx.accessibility_tree.getNode(eid).?.state.expanded);
    try testing.expect(expansion.set(expansion.context, false));
    try testing.expect(!cb.state.shown_open);
    env.cx.layout();
    _ = env.cx.render();
    try testing.expect(!env.cx.accessibility_tree.getNode(eid).?.state.expanded);
    const option_id = core.ElementId.fromRaw(cb.state.item_nodes[0].element_id_raw);
    if (env.cx.accessibility_tree.getNode(option_id)) |option| try testing.expect(option.state.hidden);
}

test "ComboBox: selected rows keep the selection pairing under hover in every mode" {
    const S = @import("styles.zig");
    const WCAG = struct {
        fn linear(v: u8) f64 {
            const c = @as(f64, @floatFromInt(v)) / 255;
            return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        }
        fn luminance(c: core.Color) f64 {
            return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
        }
        fn contrast(a: core.Color, b: core.Color) f64 {
            const x = luminance(a);
            const y = luminance(b);
            return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
        }
    };
    for ([_]*const core.ThemeTokens{ &core.theme.high_contrast, &core.theme.light, &core.theme.dark }) |t| {
        const option = S.optionStyle(t, true).resolve(.{ .is_selected = true, .is_hovered = true });
        const backgrounds = [_]core.Color{ option.background.?, @import("../tree/styles.zig").rowVisual(true, true, false, t).background.?, @import("../data_table/styles.zig").rowVisual(t.tokens.color.bg_primary, true, true, t).background.? };
        for (backgrounds) |bg| {
            // Selected + hover must stay on the design pairing (list_selection_hover_bg with
            // selection_fg); falling back to bg_hover made high contrast unreadable (1.42:1).
            try std.testing.expectEqual(t.tokens.color.list_selection_hover_bg, bg);
            // Light uses the design's blue.300 / blue.700 pair (4.27:1), tracked as a design
            // review item rather than tuned here; dark and high contrast must meet AA.
            if (t.scheme == .dark) try std.testing.expect(WCAG.contrast(t.tokens.color.selection_fg, bg) >= 4.5);
        }
    }
}
