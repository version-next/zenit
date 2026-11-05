//! Select, interactive high-level Select component.
//!
//! Visual contract: Pencil `puQEf` (Select Group 2).
//! Behaviour is real: Popover positioning/dismissal, single and multiple
//! selection, clear, searchable filtering, removable tags, hover and keyboard
//! navigation. Selection and open state are Models (value / values / open):
//! interactions only propose, the view follows the data source.

const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const svg_assets = @import("../../svg_assets.zig");
const icons = @import("zenit_system_icons");
const popover_mod = @import("../popover/mod.zig");
const input_mod = @import("../input/mod.zig");
const button_mod = @import("../button/mod.zig");
const control_shell = @import("../control_shell/mod.zig");
const recipe_mod = @import("../../recipe.zig");
const reactive = @import("../../reactive.zig");
const bind_mod = @import("../../bind.zig");
const hooks = @import("../../hooks.zig");
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;

const Allocator = std.mem.Allocator;
const Cx = core.Cx;
const Node = core.Node;
const Scope = core.Scope;
const Signal = core.Signal;
const Color = core.Color;
const Event = core.Event;
const EventResult = core.EventResult;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;

/// Same control size as Button/Input/DatePicker (default md). trigger outer frame height =
/// padding_y * 2 + font_size * line_height, all from `control_shell.metrics(tokens, size)`.
pub const SelectSize = control_shell.ControlSize;
pub const SelectMode = enum { single, multiple };

pub const SelectOption = struct {
    value: []const u8,
    label: []const u8,
    disabled: bool = false,
    icon: ?svg_assets.Asset = null,
    /// Option row test_id (e2e/locate); multi-select item tag is `<test_id>.tag`,
    /// tag close button is `<test_id>.tag-close`. Borrowed, must live with label.
    test_id: ?[]const u8 = null,
};

pub const SelectProps = struct {
    /// Options (can pass signal/derived: rebuild option rows on content/address change). Strings in
    /// option owned by
    /// caller, must stay valid while current; static arrays shallow-copied. Max 64 items
    options: Source([]const SelectOption) = .{ .value = &.{} },
    /// Placeholder text in trigger when unselected (can pass signal/derived: i18n, loading, updates
    /// with deps).
    /// For searchable single it's also search box placeholder
    placeholder: Source([]const u8) = .{ .value = "Select an option..." },
    width: f32 = 352,
    size: SelectSize = .md,
    mode: SelectMode = .single,
    searchable: bool = false,
    /// Keep the selected label in a searchable single-select trigger. Set to
    /// false for search-first presentations where the trigger should retain
    /// its search placeholder while the selected row remains checked.
    show_selected_value_in_search: bool = true,
    clearable: bool = false,
    /// Limit visible multi-select chips and show the remaining count. null keeps all chips.
    max_visible_tags: ?usize = null,
    /// Multi-select panel footer with selected count and a Clear action.
    selection_footer: bool = false,
    leading_icon: ?svg_assets.Asset = null,
    /// Single-select value (option `value`; null = unselected). Active when `.mode = .single`
    value: Model(?[]const u8) = .{ .local = null },
    /// Called after user selects/clears/types in search box (clears selection) and settles (settled
    /// value)
    on_change: ?Handler(?[]const u8) = null,
    /// Multi-select value set. Active when `.mode = .multiple`; `*Signal` must be created by
    /// `scope.createList([]const u8, ...)`
    values: Model([]const []const u8) = .{ .local = &.{} },
    /// Called after user checks/unchecks/deletes tag and settles (settled value)
    on_values_change: ?Handler([]const []const u8) = null,
    /// Dropdown panel toggle
    open: Model(bool) = .{ .local = false },
    on_open_change: ?Handler(bool) = null,
    disabled: Source(bool) = .{ .value = false },
    max_dropdown_height: f32 = 280,
    /// Dropdown panel width: `.trigger` matches the trigger (default); `.content` lets the panel
    /// size itself to its rows, independent of the trigger width.
    panel_width: PanelWidth = .trigger,
};

pub const PanelWidth = enum { trigger, content };

/// Create Select: `W.Select(.{ .options = &opts, .value = lang, .on_change = cx.on(S, s, S.picked)
/// })`
pub fn Select(props: anytype) SelectBuilder {
    return .{ .props = reactive.props.coerce(SelectProps, props) };
}

pub const SelectBuilder = struct {
    props: SelectProps,

    pub fn mount(self: SelectBuilder, scope: *Scope, cx: *Cx) !SelectResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        return mountSelect(self.props, scope, cx);
    }
};

const styles = @import("styles.zig");
const Metrics = styles.Metrics;
const Palette = styles.Palette;
const metrics = styles.metrics;
const palette = styles.palette;

/// Select runtime (belongs to component scope). View = f(value/values, open, disabled): selection
/// bitmap derived by
/// data source from current options; option rows rebuilt with options (`ui.rebuildOn`, belongs to
/// Popover scope).
/// Click/clear/delete tag/toggle all propose only.
pub const SelectState = struct {
    allocator: Allocator,
    cx: *Cx,
    mode: SelectMode,
    searchable: bool,
    clearable: bool,
    /// At mount don't write selected label to search box (`show_selected_value_in_search = false`);
    /// clear after first view, then selected writes back normally
    hold_initial_search_label: bool,
    /// Text shown in label when unselected; sync reads current value (label holds own copy)
    placeholder: Source([]const u8),
    metrics: Metrics,
    /// Theme the parts below were painted with: a theme switch rebuilds the option rows and
    /// recolors the trigger and panel (`applyTheme`), so they match a fresh mount.
    colors: Palette,
    tokens: *const core.theme.ThemeTokens,
    shell_size: control_shell.ControlSize,
    max_visible_tags: ?usize = null,
    overflow_label: ?*Node = null,
    footer_label: ?*Node = null,

    value: ?reactive.Bound(?[]const u8),
    values: ?reactive.Bound([]const []const u8),
    open: reactive.Bound(bool),
    disabled: Source(bool),
    on_change: ?Handler(?[]const u8),
    on_values_change: ?Handler([]const []const u8),
    on_open_change: ?Handler(bool),

    /// Focusable keyboard-receiving outer (Popover trigger) and border-drawing control shell
    focus_target: *Node,
    trigger: *Node,
    content_slot: *Node,
    append_slot: *Node,
    append_comp: *Node,
    leading_icon_node: ?*Node,
    chevron_slot: *Node,
    trigger_label: ?*Node,
    panel: *Node,
    chevron_up: *Node,
    chevron_down: *Node,
    clear_button: ?*Node,
    input_state: ?*input_mod.TextInputState,
    /// Search box text value (component-owned text signal, bound to embedded Input)
    query_text: ?*Signal([]const u8) = null,
    input_node: ?*Node,
    /// Multi-select tag row, translated inside `tags_viewport` when the chips overflow
    tags_row: ?*Node,
    /// Clips the tag row; wheel/trackpad scrolls it horizontally behind edge fades
    tags_viewport: ?*Node = null,
    tags_scroll_x: f32 = 0,

    // ---- Rebuilt with options (arrays belong to rebuild child scope, cleared at rebuild start)
    // ----
    options: []const SelectOption = &.{},
    option_nodes: []*Node = &.{},
    check_nodes: []*Node = &.{},
    tag_nodes: []*Node = &.{},

    // ---- Derived / internal interaction state ----
    selected_mask: u64 = 0,
    /// Multi-select option indices in the order the user picked them (the `values` order); tags
    /// render in this order.
    selection_order: [64]u8 = undefined,
    selection_len: usize = 0,
    shown_open: bool = false,
    /// Closing discarded the search draft: the rows show all options again on the next open.
    /// The closing panel keeps the rows it had while it fades out.
    filter_reset_pending: bool = false,
    shown_disabled: bool = false,
    /// Last selected label written to search box (only overwrite when changes, don't interrupt user
    /// input)
    shown_search_label: ?[]const u8 = null,
    highlighted_index: ?usize = null,
    is_trigger_hovered: bool = false,
    query_buf: [128]u8 = undefined,
    query_len: usize = 0,

    pub fn isSelected(self: *const SelectState, index: usize) bool {
        if (index >= 64) return false;
        return (self.selected_mask & (@as(u64, 1) << @intCast(index))) != 0;
    }

    pub fn selectedCount(self: *const SelectState) usize {
        return @popCount(self.selected_mask);
    }

    fn indexOf(self: *const SelectState, value: []const u8) ?usize {
        for (self.options, 0..) |o, i| {
            if (std.mem.eql(u8, o.value, value)) return i;
        }
        return null;
    }

    // ---- View ----

    fn viewEffect(self: *SelectState) void {
        self.applyView(true);
    }

    fn applyView(self: *SelectState, comptime tracked: bool) void {
        const disabled = self.disabled.read(tracked);
        const open = self.open.readAs(tracked);
        var mask: u64 = 0;
        if (self.mode == .single) {
            const v = self.value.?.readAs(tracked);
            // Value not in options just doesn't display as selected, doesn't write back
            if (v) |s| if (self.indexOf(s)) |i| {
                mask = @as(u64, 1) << @intCast(i);
            };
        } else {
            self.selection_len = 0;
            for (self.values.?.readAs(tracked)) |s| {
                const i = self.indexOf(s) orelse continue;
                if (i >= 64) continue;
                const bit = @as(u64, 1) << @intCast(i);
                if (mask & bit != 0) continue;
                mask |= bit;
                self.selection_order[self.selection_len] = @intCast(i);
                self.selection_len += 1;
            }
        }
        // Label displays placeholder when unselected: subscribe to it, redraw when changes
        // (syncSelection reads current and copies to label)
        if (self.trigger_label != null) _ = self.placeholder.read(tracked);
        self.selected_mask = mask;
        const closing = self.shown_open and !open;
        const opening = !self.shown_open and open;
        self.shown_open = open;
        if (disabled != self.shown_disabled) self.applyDisabled(disabled);
        if (closing) self.discardSearchDraft() else self.syncSearchLabel();
        if (opening and self.filter_reset_pending) applyFilter(self);
        self.paint();
    }

    /// Searchable single: only write label to search box when selection changes (external write
    /// doesn't trigger on_change);
    /// when external clears selection, clear component-written label (don't touch user-typed text)
    fn syncSearchLabel(self: *SelectState) void {
        if (self.mode != .single) return;
        const query_text = self.query_text orelse return;
        const index = selectedIndex(self) orelse {
            // Search box still displays component-written label (clears when user types
            // shown_search_label)
            if (self.shown_search_label != null) clearSearch(self);
            return;
        };
        const label = self.options[index].label;
        if (self.shown_search_label) |shown| {
            if (shown.ptr == label.ptr and shown.len == label.len) return;
        }
        if (self.hold_initial_search_label) {
            self.shown_search_label = label;
            return;
        }
        query_text.set(label);
        self.shown_search_label = label;
        self.setQuery("");
        applyFilter(self);
    }

    /// Close panel = leave edit mode: text in search box is filter draft, discard and back to data
    /// source -- single with selection
    /// displays its label, else clear. Else if parent rejects clear selection, search box shows
    /// text mismatched to value
    fn discardSearchDraft(self: *SelectState) void {
        const query_text = self.query_text orelse return;
        if (self.mode == .single) {
            if (selectedIndex(self)) |index| {
                const label = self.options[index].label;
                if (!std.mem.eql(u8, query_text.peek(), label)) query_text.set(label);
                self.shown_search_label = label;
                self.setQuery("");
                self.filter_reset_pending = true;
                return;
            }
        }
        clearSearchText(self);
        self.filter_reset_pending = true;
    }

    fn applyDisabled(self: *SelectState, disabled: bool) void {
        self.shown_disabled = disabled;
        self.focus_target.setFocusable(!disabled);
        if (self.focus_target.behavior.interaction.a11y) |*a| a.disabled = disabled;
        if (self.input_node) |n| {
            // Embedded search box disabled can't be hit/focused (Input's own dynamic disable
            // pending its migration)
            n.setHitTestVisible(!disabled);
        }
        if (disabled) self.is_trigger_hovered = false;
        self.trigger.markRenderDirty();
    }

    fn setQuery(self: *SelectState, q: []const u8) void {
        const n = @min(q.len, self.query_buf.len);
        @memcpy(self.query_buf[0..n], q[0..n]);
        self.query_len = n;
    }

    /// Paint current derived state to nodes
    fn paint(self: *SelectState) void {
        syncSelection(self);
    }

    // ---- Interaction: propose only ----

    fn proposeOpen(self: *SelectState, v: bool) void {
        const on_change = self.on_open_change;
        const landed = self.open.commit(v) orelse return;
        if (on_change) |h| h.call(landed);
    }

    /// Return whether proposal settled
    fn proposeValue(self: *SelectState, v: ?[]const u8) bool {
        const b = self.value orelse return false;
        const on_change = self.on_change;
        const landed = b.commit(v) orelse return false;
        if (on_change) |h| h.call(landed);
        return true;
    }

    /// Multi-select: propose value set corresponding to mask in option order
    /// Return whether proposal settled (data source actually changed)
    /// Values for a proposed mask in pick order: kept selections stay where they were and newly
    /// picked options append at the end.
    fn valuesForMask(self: *const SelectState, mask: u64, buf: *[64][]const u8) usize {
        var n: usize = 0;
        var placed: u64 = 0;
        for (self.selection_order[0..self.selection_len]) |i| {
            const bit = @as(u64, 1) << @intCast(i);
            if (mask & bit == 0) continue;
            buf[n] = self.options[i].value;
            n += 1;
            placed |= bit;
        }
        for (self.options, 0..) |o, i| {
            if (i >= 64) break;
            const bit = @as(u64, 1) << @intCast(i);
            if (mask & bit == 0 or placed & bit != 0) continue;
            buf[n] = o.value;
            n += 1;
        }
        return n;
    }

    fn proposeMask(self: *SelectState, mask: u64) bool {
        const b = self.values orelse return false;
        var buf: [64][]const u8 = undefined;
        const n = self.valuesForMask(mask, &buf);
        const on_change = self.on_values_change;
        const landed = b.commit(buf[0..n]) orelse return false;
        if (on_change) |h| h.call(landed);
        return true;
    }

    // ---- Option rebuild (ui.rebuildOn) ----

    /// Rebuild source: the options and the theme they are painted with.
    const OptionsView = struct {
        options: []const SelectOption,
        tokens: *const core.theme.ThemeTokens,
    };

    const OptionsViewSources = struct {
        options: Source([]const SelectOption),
        theme: *Signal(*const core.theme.ThemeTokens),

        fn compute(src: @This()) OptionsView {
            return .{ .options = src.options.read(true), .tokens = src.theme.get() };
        }
    };

    fn optionsViewKey(v: OptionsView) u64 {
        var h = std.hash.Wyhash.init(optionsKey(v.options));
        h.update(std.mem.asBytes(&@intFromPtr(v.tokens)));
        return h.final();
    }

    fn buildOptionsView(self: *SelectState, child: *Scope, container: *Node, v: OptionsView) !void {
        if (v.tokens != self.tokens) self.applyTheme(v.tokens);
        try self.buildOptions(child, container, v.options);
    }

    /// Theme switch, before the option rows rebuild: recolor what the mount painted outside them.
    fn applyTheme(self: *SelectState, t: *const core.theme.ThemeTokens) void {
        self.tokens = t;
        self.colors = palette(t);
        const colors = self.colors;
        if (self.leading_icon_node) |n| _ = n.setTint(colors.text_tertiary);
        _ = self.chevron_down.setTint(colors.text_tertiary);
        _ = self.chevron_up.setTint(colors.primary);
        if (self.input_state) |st| st.placeholder_color = colors.text_tertiary;
        if (self.tags_viewport) |vp| {
            if (vp.style.ext) |ext| if (ext.overflow_fade) |*fade| {
                fade.color = colors.bg;
            };
            vp.markRenderDirty();
        }
        self.panel.setBackgroundRaw(colors.panel);
        self.panel.style.border.color = t.tokens.color.border;
        if (self.panel.style.ext) |ext| ext.setShadow(t.tokens.shadow.md);
        self.panel.markRenderDirty();
        // The rows are already gone (rebuildOn clears before building): buildOptions repaints
        // the selection, label and filter once they are back.
    }

    fn optionsKey(opts: []const SelectOption) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&opts.ptr));
        h.update(std.mem.asBytes(&opts.len));
        for (opts) |o| {
            h.update(std.mem.asBytes(&o.value.ptr));
            h.update(std.mem.asBytes(&o.value.len));
            h.update(o.value);
            h.update(std.mem.asBytes(&o.label.ptr));
            h.update(std.mem.asBytes(&o.label.len));
            h.update(o.label);
            h.update(&[_]u8{@intFromBool(o.disabled)});
            h.update(std.mem.asBytes(&o.icon));
        }
        return h.final();
    }

    /// Detach previous tag nodes (their event contexts released with old child scope). Doesn't fail
    fn clearTags(self: *SelectState) void {
        const tags = self.tags_row orelse return;
        self.overflow_label = null;
        while (tags.children.items.len > 0) {
            const n = tags.children.items[tags.children.items.len - 1];
            hooks.invalidateSubtreeHookState(n);
            core.clearNodeScopes(n);
            self.cx.detachChild(tags, n);
            self.cx.freeNode(n);
        }
        tags.markLayoutDirty();
    }

    const Parts = struct {
        options: []*Node = &.{},
        checks: []*Node = &.{},
        tags: []*Node = &.{},
        items: []ItemContext = &.{},
        tag_ctxs: []ItemContext = &.{},

        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const p: *Parts = @ptrCast(@alignCast(ptr));
            alloc.free(p.options);
            alloc.free(p.checks);
            alloc.free(p.tags);
            alloc.free(p.items);
            alloc.free(p.tag_ctxs);
            alloc.destroy(p);
        }
    };

    fn buildOptions(self: *SelectState, child: *Scope, container: *Node, opts: []const SelectOption) !void {
        // Stop runtime referencing previous nodes/arrays first: any failure after stops at "no
        // options"
        self.clearTags();
        self.options = &.{};
        self.option_nodes = &.{};
        self.check_nodes = &.{};
        self.tag_nodes = &.{};
        self.highlighted_index = null;
        if (opts.len > 64) return error.TooManySelectOptions;
        // Failed partial-built tags must not remain: their event contexts released with this-round
        // child scope
        errdefer self.clearTags();

        const a = child.allocator;
        const parts = try a.create(Parts);
        parts.* = .{};
        // If adopt fails, destroy releases on spot (arrays are empty)
        try child.adoptResource(@ptrCast(parts), Parts.destroy);
        parts.options = try a.alloc(*Node, opts.len);
        parts.checks = try a.alloc(*Node, opts.len);
        parts.items = try a.alloc(ItemContext, opts.len);
        if (self.mode == .multiple) {
            parts.tags = try a.alloc(*Node, opts.len);
            parts.tag_ctxs = try a.alloc(ItemContext, opts.len);
        }

        const cx = self.cx;
        const m = self.metrics;
        const colors = self.colors;
        for (opts, 0..) |option, i| {
            const option_style: core.BoxStyle = .{
                .width = .{ .grow = .{} },
                .direction = .row,
                .align_items = .center,
                .justify = .space_between,
                .gap = self.tokens.tokens.space.space200,
                .height = .{ .px = self.tokens.tokens.size.row },
                .padding = m.row_padding,
                .corner_radius = m.row_radius,
                .cursor = if (option.disabled) .default else .pointer,
            };
            const checkbox_style: core.BoxStyle = .{
                .width = .{ .px = m.checkbox_size },
                .height = .{ .px = m.checkbox_size },
                .direction = .row,
                .align_items = .center,
                .justify = .center,
                .background = colors.bg,
                .border = .{ .overlay = true, .width = self.tokens.tokens.border_width.thin, .color = colors.border_strong, .radius = m.checkbox_radius },
            };
            var check_node: *Node = undefined;
            // Row = [content (icon + text), selection mark]: single is check icon, multi is
            // checkbox.
            // Row scope bound to row node (view.append), released together when rebuild clears rows
            const option_node = try view.append(child, cx, container, view.box(.{
                .style = option_style,
                .a11y = .{ .role = .option, .label = option.label, .disabled = option.disabled, .selected = false },
                .test_id = option.test_id,
            }, .{
                if (self.mode == .multiple) view.capture(&check_node, view.box(.{ .style = checkbox_style }, iconEl(icons.check, m.check_size, colors.panel))) else null,
                view.row(.{ .style = styles.optionContentStyle }, .{
                    if (option.icon) |asset| iconEl(asset, @min(m.icon_size, 16), colors.text_secondary) else null,
                    // min_width 0 lets a long label shrink and ellipsize (CSS flex min-width: auto).
                    view.attrs(.{ .style = core.BoxStyle{ .min_width = 0 } }, textEl(option.label, m.row_font, if (option.disabled) colors.text_tertiary else colors.text_primary, 400)),
                }),
                if (self.mode == .single) view.capture(&check_node, iconEl(icons.check, @min(m.icon_size, 16), colors.primary)) else null,
            }));
            parts.options[i] = option_node;
            parts.checks[i] = check_node;
            parts.items[i] = .{ .state = self, .index = i };
            option_node.behavior.events.event_context = @ptrCast(&parts.items[i]);
            option_node.behavior.events.on_event = itemEvent;
            if (option_node.behavior.interaction.a11y) |*ax| ax.item_selection = .{ .context = @ptrCast(&parts.items[i]), .set = setAccessibleItemSelection };

            if (self.mode == .multiple) {
                parts.tag_ctxs[i] = .{ .state = self, .index = i };
                const tag = try buildTag(self, child, option, &parts.tag_ctxs[i]);
                parts.tags[i] = tag;
                if (option.test_id) |tid| {
                    try assignDerivedTestId(cx, tag, tid, ".tag");
                    try assignDerivedTestId(cx, tag.children.items[1], tid, ".tag-close");
                }
            }
        }

        if (self.mode == .multiple and self.max_visible_tags != null) {
            _ = try view.append(child, cx, self.tags_row.?, view.capture(&self.overflow_label, view.text(.{ .style = styles.overflowText }, "")));
        }
        self.options = opts;
        self.option_nodes = parts.options;
        self.check_nodes = parts.checks;
        self.tag_nodes = parts.tags;
        applyFilter(self);
        self.applyView(false);
    }
};

/// Select mount result
pub const SelectResult = struct {
    wrapper: *Node,
    trigger: *Node,
    panel: *Node,
    /// Single-select value signal (null for multi or `ui.split`)
    value: ?*Signal(?[]const u8),
    /// Multi-select value set signal (null for single or `ui.split`)
    values: ?*Signal([]const []const u8),
    /// Toggle signal (null when `ui.split`)
    open: ?*Signal(bool),

    // ---- Fixed parts (`.parts` can set test_id/apply styles; live with component) ----
    /// Area in trigger holding selected content/search box
    content_slot: *Node,
    /// Container on trigger right (clear button + arrow)
    append_slot: *Node,
    append_comp: *Node,
    leading_icon: ?*Node,
    chevron_slot: *Node,
    chevron_up: *Node,
    chevron_down: *Node,
    /// Clear button when `clearable`
    clear_button: ?*Node,
    /// Search input box when `searchable` (bordered input container)
    search_input: ?*Node,

    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: SelectResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

/// Get runtime (test/Storybook for test id; fields are derived state, don't write)
pub fn stateOf(r: SelectResult) *SelectState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

const ItemContext = struct { state: *SelectState, index: usize };

// Helper returning elements: props uses named type, return type shared with function body (two
// identical-looking anonymous struct types differ)
const TextElProps = struct { style: core.TextStyle };
const IconElProps = struct { style: core.BoxStyle, tint: Color };
const TextEl = view.Text(TextElProps, []const u8);
const IconEl = view.Icon(IconElProps);

fn textEl(content: []const u8, size: f32, color: Color, weight: u16) TextEl {
    return view.text(TextElProps{ .style = .{ .font_size = size, .font_weight = weight, .line_height = 1.4, .color = color, .text_overflow = .ellipsis } }, content);
}

/// Text in trigger: font size/line height from control metrics (line box = font_size *
/// line_height).
fn triggerTextEl(content: []const u8, cm: control_shell.ControlMetrics, color: Color) TextEl {
    return view.text(TextElProps{ .style = .{ .font_size = cm.font_size, .font_weight = 400, .line_height = cm.line_height, .color = color, .text_overflow = .ellipsis } }, content);
}

fn iconEl(asset: svg_assets.Asset, size: f32, color: Color) IconEl {
    return view.icon(IconElProps{ .style = .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 }, .tint = color }, asset);
}

fn rowStyle(gap: f32) core.BoxStyle {
    return .{ .direction = .row, .align_items = .center, .gap = gap };
}

/// Keep the tag row in pick order: selected tags first as picked, then the hidden ones, then the
/// "+N" label. Moves happen only when the order actually changed.
fn orderTags(state: *SelectState) void {
    const row = state.tags_row orelse return;
    var want: [65]*Node = undefined;
    var n: usize = 0;
    var placed: u64 = 0;
    for (state.selection_order[0..state.selection_len]) |i| {
        if (i >= state.tag_nodes.len) continue;
        want[n] = state.tag_nodes[i];
        n += 1;
        placed |= @as(u64, 1) << @intCast(i);
    }
    for (state.tag_nodes, 0..) |tag_node, i| {
        if (placed & (@as(u64, 1) << @intCast(i)) != 0) continue;
        want[n] = tag_node;
        n += 1;
    }
    if (state.overflow_label) |label| {
        want[n] = label;
        n += 1;
    }
    if (n == row.children.items.len and std.mem.eql(*Node, want[0..n], row.children.items)) return;
    for (want[0..n]) |node| row.appendChild(state.allocator, node) catch |err| {
        std.log.warn("[select] reordering tags failed: {s}; tags keep their previous order", .{@errorName(err)});
        return;
    };
}

const tags_fade_size: f32 = 16;

/// Chips keep their natural width; the viewport takes what the trigger leaves and clips them.
fn tagsViewportStyle(fade_color: Color) core.BoxStyle {
    return .{
        .direction = .row,
        .align_items = .center,
        .width = .{ .grow = .{ .min = 0 } },
        .min_width = 0,
        .overflow_hidden = true,
        // Edges switch on from the scroll position (syncTagsScroll); both start off.
        .overflow_fade = .{ .size = tags_fade_size, .color = fade_color, .edges = .{ .top = false, .bottom = false, .left = false, .right = false } },
    };
}

fn tagsRowStyle(gap: f32) core.BoxStyle {
    var style = rowStyle(gap);
    style.flex_shrink = 0;
    return style;
}

fn tagsScrollMax(state: *const SelectState) f32 {
    const viewport = state.tags_viewport orelse return 0;
    const row = state.tags_row orelse return 0;
    return @max(0, row.rectFromWorldOrFallback().w - viewport.rectFromWorldOrFallback().w);
}

/// Clamp the scroll to the current chips (removing one shrinks the range), place the row and
/// fade only the edges that hide chips.
fn syncTagsScroll(state: *SelectState) void {
    const viewport = state.tags_viewport orelse return;
    const row = state.tags_row orelse return;
    const max = tagsScrollMax(state);
    state.tags_scroll_x = std.math.clamp(state.tags_scroll_x, 0, max);
    if (row.style.translate_x != -state.tags_scroll_x) {
        row.setTranslateX(-state.tags_scroll_x);
        row.markRenderDirty();
    }
    const ext = viewport.style.ensureExtPanic(state.cx.allocator);
    const fade = if (ext.overflow_fade) |*f| f else return;
    // A solid field covers the hidden chips with its own paint; a translucent one keeps the hard
    // clip, as painting its tint again would leave a darker seam (same rule as Input).
    const background = state.trigger.getBackground();
    const can_fade = background.a == 255;
    const left = can_fade and state.tags_scroll_x > 0.5;
    const right = can_fade and state.tags_scroll_x < max - 0.5;
    if (fade.edges.left == left and fade.edges.right == right and fade.color != null and Color.eql(fade.color.?, background)) return;
    fade.edges.left = left;
    fade.edges.right = right;
    fade.color = background;
    viewport.markRenderDirty();
}

fn tagsViewportBeforeRender(node: *Node) void {
    const state: *SelectState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    syncTagsScroll(state);
}

/// Horizontal trackpad swipes (and shift+wheel) scroll the chips sideways. Vertical scrolls and
/// scrolls without overflow pass on, so the page keeps scrolling over the trigger.
fn tagsViewportScroll(scroll: @import("../../events.zig").ScrollEvent, context: ?*anyopaque) EventResult {
    const state: *SelectState = @ptrCast(@alignCast(context orelse return .ignored));
    if (@abs(scroll.dy) > @abs(scroll.dx)) return .ignored;
    const max = tagsScrollMax(state);
    if (max <= 0) return .ignored;
    const next = std.math.clamp(state.tags_scroll_x - scroll.dx, 0, max);
    if (next == state.tags_scroll_x) return .ignored;
    state.tags_scroll_x = next;
    syncTagsScroll(state);
    return .handled;
}

fn selectedIndex(state: *const SelectState) ?usize {
    for (state.options, 0..) |_, i| if (state.isSelected(i)) return i;
    return null;
}

fn syncClearAffordance(state: *SelectState) void {
    const clear = state.clear_button orelse return;
    const show_clear = !state.shown_disabled and selectedIndex(state) != null and state.is_trigger_hovered;

    clear.setOpacity(if (show_clear) 1 else 0);
    clear.setHitTestVisible(show_clear);
    clear.setFocusable(show_clear);
    state.chevron_slot.setOpacity(if (show_clear) 0 else 1);
}

fn syncA11y(state: *SelectState) void {
    if (state.focus_target.behavior.interaction.a11y) |*a| {
        a.expanded = state.shown_open;
        if (state.mode == .single) {
            a.value_text = if (selectedIndex(state)) |i| state.options[i].label else null;
        }
    }
    for (state.option_nodes, 0..) |node, i| {
        if (node.behavior.interaction.a11y) |*a| a.selected = state.isSelected(i);
    }
    state.focus_target.markRenderDirty();
}

fn syncSelection(state: *SelectState) void {
    const colors = state.colors;

    if (state.mode == .single) {
        const index = selectedIndex(state);
        if (state.trigger_label) |label| {
            const content = if (index) |i| state.options[i].label else state.placeholder.peek();
            // WARNING: failure must not continue: code below will setText label's current (old)
            // text with new color back, equivalent to freezing "state selected B, display still A"
            // fork and add new color styling, looks completely normal.
            if (label.setTextContent(state.allocator, content)) {
                if (label.getText()) |old| {
                    var updated = old;
                    updated.color = if (index == null) colors.text_tertiary else colors.text_primary;
                    label.setText(updated);
                }
                label.markRenderDirty();
            } else |err| {
                std.log.warn("[select] 标签文本同步失败: {s}；标签显示的仍是上一个选项", .{@errorName(err)});
            }
        }
        syncClearAffordance(state);
    } else {
        const selected_count = state.selection_len;
        const visible_limit = state.max_visible_tags orelse state.tag_nodes.len;
        for (state.tag_nodes) |tag_node| tag_node.setDisplay(.none);
        for (state.selection_order[0..state.selection_len], 0..) |i, rank| {
            if (i < state.tag_nodes.len and rank < visible_limit) state.tag_nodes[i].setDisplay(.flex);
        }
        orderTags(state);
        if (state.overflow_label) |label| {
            const hidden = selected_count - @min(selected_count, state.max_visible_tags.?);
            var buf: [32]u8 = undefined;
            label.setTextContent(state.allocator, std.fmt.bufPrint(&buf, "+{d}", .{hidden}) catch "") catch {};
            label.setDisplay(if (hidden > 0) .flex else .none);
        }
        if (state.footer_label) |label| {
            var buf: [64]u8 = undefined;
            label.setTextContent(state.allocator, std.fmt.bufPrint(&buf, "{d} of {d} selected", .{ selected_count, state.options.len }) catch "") catch {};
        }
    }

    for (state.option_nodes, state.check_nodes, 0..) |option_node, check_node, i| {
        const selected = state.isSelected(i);
        const highlighted = state.highlighted_index != null and state.highlighted_index.? == i;
        const row_style = @import("../combo_box/styles.zig").optionStyle(state.tokens, selected and state.mode == .single).resolve(.{
            .is_selected = selected and state.mode == .single,
            .is_hovered = highlighted,
            .is_disabled = state.options[i].disabled,
        });
        option_node.setBackgroundRaw(row_style.background.?);
        const content = option_node.children.items[if (state.mode == .multiple) 1 else 0];
        const label = content.children.items[content.children.items.len - 1];
        if (label.getText()) |old| {
            var text = old;
            text.color = row_style.text_color.?;
            label.setText(text);
        }
        if (state.mode == .single) _ = check_node.setTint(state.tokens.tokens.color.selection_fg);
        if (state.mode == .single) {
            check_node.setOpacityRaw(if (selected) 1 else 0);
        } else {
            const check_visual = styles.checkboxStyle(state.tokens).resolve(.{ .is_selected = selected, .is_disabled = state.options[i].disabled });
            check_node.setBackgroundRaw(check_visual.background.?);
            check_node.setBorderColor(check_visual.border_color.?);
            if (check_node.children.items.len > 0) check_node.children.items[0].setOpacityRaw(if (selected) 1 else 0);
        }
        option_node.markRenderDirty();
        check_node.markRenderDirty();
    }
    syncOpen(state);
}

/// AT ExpandCollapse: explicit target state, goes through same proposal pipeline as click.
fn setAccessibleExpanded(raw: *anyopaque, expanded: bool) bool {
    const state: *SelectState = @ptrCast(@alignCast(raw));
    if (state.shown_disabled) return false;
    if (state.shown_open == expanded) return true;
    const on_change = state.on_open_change;
    const landed = state.open.commit(expanded) orelse return false;
    if (on_change) |h| h.call(landed);
    return landed == expanded;
}

fn clearAllSelected(state: *SelectState) void {
    if (state.shown_disabled) return;
    const changed = state.on_values_change;
    const landed = state.values.?.commit(&.{}) orelse return;
    if (changed) |h| h.call(landed);
}

fn syncOpen(state: *SelectState) void {
    const open = state.shown_open;
    // Frame colors are the trigger shell's :hover / :expanded / :disabled.
    if (state.trigger_label) |label| if (label.getText()) |old| {
        var text = old;
        if (state.shown_disabled) text.color = state.tokens.tokens.color.fg_disabled;
        label.setText(text);
    };
    // One downward chevron rotates into the open state. Keeping a single icon
    // avoids the cross-fade flicker caused by swapping up/down SVG nodes.
    state.chevron_down.setRotate(state.allocator, if (open) std.math.pi else 0);
    state.chevron_down.setOpacityRaw(1);
    state.chevron_up.setOpacityRaw(0);
    syncA11y(state);
}

fn applyFilter(state: *SelectState) void {
    state.filter_reset_pending = false;
    const query = state.query_buf[0..state.query_len];
    for (state.options, state.option_nodes) |option, node| {
        var matches = query.len == 0;
        if (!matches and query.len <= option.label.len) {
            var offset: usize = 0;
            while (offset + query.len <= option.label.len) : (offset += 1) {
                if (std.ascii.eqlIgnoreCase(option.label[offset .. offset + query.len], query)) {
                    matches = true;
                    break;
                }
            }
        }
        node.setDisplay(if (matches) .flex else .none);
    }
    state.highlighted_index = null;
    state.panel.markLayoutDirty();
}

/// Clear search box and filter (external write doesn't trigger on_change)
fn clearSearch(state: *SelectState) void {
    if (state.query_text == null) return;
    clearSearchText(state);
    applyFilter(state);
}

/// Clear the search box and query, leaving the rows as filtered (a closing panel).
fn clearSearchText(state: *SelectState) void {
    const query_text = state.query_text orelse return;
    query_text.set("");
    state.shown_search_label = null;
    state.setQuery("");
}

/// Select/check item at index: propose only
fn commit(state: *SelectState, index: usize) void {
    if (state.shown_disabled) return;
    if (index >= state.options.len or state.options[index].disabled) return;
    if (state.mode == .single) {
        _ = state.proposeValue(state.options[index].value);
        state.proposeOpen(false);
    } else {
        // Clear search term only after check settles: parent rejection keeps user's search
        if (state.proposeMask(state.selected_mask ^ (@as(u64, 1) << @intCast(index))) and state.searchable) clearSearch(state);
    }
    // View effect doesn't run if proposal doesn't change data source: highlight/filter changes must
    // paint anyway
    state.paint();
}

fn onSearchChanged(state: *SelectState, value: []const u8) void {
    if (state.shown_disabled) return;
    state.setQuery(value);
    applyFilter(state);
    // Single's search box also shows value: user changes text, selection void. Parent rejection
    // preserves
    // "label shown" record: next view refresh won't overwrite user input with old label
    // (clear before propose: view effect may rerun on settle, must already know label no longer
    // shows,
    // else will clear user-typed text as component-written label)
    if (state.mode == .single and state.value.?.peek() != null) {
        const prev_label = state.shown_search_label;
        state.shown_search_label = null;
        if (!state.proposeValue(null)) state.shown_search_label = prev_label;
    }
    if (!state.shown_open) state.proposeOpen(true);
    state.paint();
}

fn triggerEvent(event: Event, context: ?*anyopaque) EventResult {
    const state: *SelectState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.shown_disabled) return .ignored;
    switch (event) {
        .click => {
            state.proposeOpen(!state.shown_open);
            return .stop;
        },
        .mouse_enter => {
            state.is_trigger_hovered = true;
            syncOpen(state);
            syncClearAffordance(state);
            return .handled;
        },
        .mouse_leave => {
            state.is_trigger_hovered = false;
            syncOpen(state);
            syncClearAffordance(state);
            return .handled;
        },
        else => return .ignored,
    }
}

fn clearEvent(event: Event, context: ?*anyopaque) EventResult {
    const state: *SelectState = @ptrCast(@alignCast(context orelse return .ignored));
    if (event != .click or state.shown_disabled) return .ignored;
    if (state.searchable) clearSearch(state);
    _ = state.proposeValue(null);
    state.proposeOpen(false);
    state.paint();
    return .stop;
}

/// AT SelectionItem: Select/AddToSelection/RemoveFromSelection.
/// Same write pipeline as click (controlled: parent can reject/rewrite). Return value based on
/// settled ==
/// proposal; result set before on_change, don't touch state after (callback may unmount).
fn setAccessibleItemSelection(raw: *anyopaque, operation: core.A11yProps.ItemSelectionOperation) bool {
    const ctx: *ItemContext = @ptrCast(@alignCast(raw));
    const state = ctx.state;
    if (state.shown_disabled or ctx.index >= state.options.len or ctx.index >= 64 or state.options[ctx.index].disabled) return false;
    const bit = @as(u64, 1) << @intCast(ctx.index);
    const previous = state.selected_mask;
    if (operation == .add and state.mode == .single and previous != 0 and previous != bit) return false;
    const next: u64 = switch (operation) {
        .replace => bit,
        .add => if (state.mode == .single) bit else previous | bit,
        .remove => previous & ~bit,
    };
    if (next == previous) return true;
    if (state.mode == .single) {
        const b = state.value orelse return false;
        const want: ?[]const u8 = if (next != 0) state.options[ctx.index].value else null;
        const on_change = state.on_change;
        const landed = b.commit(want) orelse return false;
        const ok = optStrEql(landed, want);
        if (ok and want == null and state.searchable) clearSearch(state);
        state.paint();
        if (on_change) |h| h.call(landed);
        return ok;
    }
    const b = state.values orelse return false;
    var buf: [64][]const u8 = undefined;
    const n = state.valuesForMask(next, &buf);
    const on_change = state.on_values_change;
    const landed = b.commit(buf[0..n]) orelse return false;
    var ok = landed.len == n;
    if (ok) {
        for (landed, buf[0..n]) |x, y| {
            if (!std.mem.eql(u8, x, y)) ok = false;
        }
    }
    state.paint();
    if (on_change) |h| h.call(landed);
    return ok;
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn itemEvent(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *ItemContext = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .click => {
            commit(ctx.state, ctx.index);
            return .stop;
        },
        .mouse_enter => {
            ctx.state.highlighted_index = ctx.index;
            ctx.state.paint();
            return .handled;
        },
        .mouse_leave => {
            if (ctx.state.highlighted_index == ctx.index) ctx.state.highlighted_index = null;
            ctx.state.paint();
            return .handled;
        },
        else => return .ignored,
    }
}

fn tagCloseEvent(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *ItemContext = @ptrCast(@alignCast(context orelse return .ignored));
    if (event != .click or ctx.state.shown_disabled) return .ignored;
    if (ctx.index < 64) _ = ctx.state.proposeMask(ctx.state.selected_mask & ~(@as(u64, 1) << @intCast(ctx.index)));
    return .stop;
}

fn nextVisible(state: *SelectState, start: usize, forward: bool) ?usize {
    const n = state.options.len;
    if (n == 0) return null;
    var index = start;
    var seen: usize = 0;
    while (seen < n) : (seen += 1) {
        index = if (forward)
            (index + 1) % n
        else if (index == 0)
            n - 1
        else
            index - 1;
        if (optionNavigable(state, index)) return index;
    }
    return null;
}

/// Visible after filter and not disabled
fn optionNavigable(state: *const SelectState, i: usize) bool {
    return state.option_nodes[i].style.display != .none and !state.options[i].disabled;
}

fn triggerKeyDown(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const state: *SelectState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.shown_disabled) return .ignored;
    const n = state.options.len;
    switch (key) {
        .escape => {
            state.highlighted_index = null;
            state.proposeOpen(false);
        },
        .down, .up => {
            if (!state.shown_open) state.proposeOpen(true);
            const forward = key == .down;
            // Empty options: len - 1 underflows panic; nextVisible returns null for empty list
            const start = state.highlighted_index orelse if (forward) n -| 1 else 0;
            state.highlighted_index = nextVisible(state, start, forward);
        },
        .home => {
            state.highlighted_index = null;
            for (0..n) |i| if (optionNavigable(state, i)) {
                state.highlighted_index = i;
                break;
            };
        },
        .end => {
            state.highlighted_index = null;
            var i = n;
            while (i > 0) {
                i -= 1;
                if (optionNavigable(state, i)) {
                    state.highlighted_index = i;
                    break;
                }
            }
        },
        .@"return", .space => {
            if (state.highlighted_index) |i| commit(state, i) else state.proposeOpen(!state.shown_open);
        },
        else => return .ignored,
    }
    state.paint();
    return .stop;
}

/// Derived test_id (node owned, released with node).
fn assignDerivedTestId(cx: *Cx, node: *Node, base: []const u8, suffix: []const u8) !void {
    node.meta.ownership.meta.test_id = try std.fmt.allocPrint(cx.allocator, "{s}{s}", .{ base, suffix });
    node.frame_state.state_bits.flags.test_id_owned = true;
}

/// Tag: [text, close button] (assignDerivedTestId depends on order), attached to tags_row,
/// initially hidden.
fn buildTag(state: *SelectState, scope: *Scope, option: SelectOption, ctx: *ItemContext) !*Node {
    const m = state.metrics;
    const colors = state.colors;
    const tag_style: core.BoxStyle = .{
        .direction = .row,
        .align_items = .center,
        .gap = m.tag_gap,
        .height = .{ .px = m.tag_height },
        .padding = m.tag_padding,
        .background = colors.inset,
        .corner_radius = m.tag_radius,
        .display = .none,
    };
    const close_style: core.BoxStyle = .{
        .width = .{ .px = m.close_size },
        .height = .{ .px = m.close_size },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .cursor = .pointer,
    };
    var close: *Node = undefined;
    const node = try view.append(scope, state.cx, state.tags_row.?, view.box(.{ .style = tag_style }, .{
        textEl(option.label, m.tag_font, colors.text_primary, 400),
        view.capture(&close, view.box(.{ .style = close_style }, iconEl(icons.close, m.close_size, colors.text_secondary))),
    }));
    close.behavior.events.event_context = @ptrCast(ctx);
    close.behavior.events.on_event = tagCloseEvent;
    return node;
}

fn mountSelect(props: SelectProps, scope: *Scope, cx: *Cx) !SelectResult {
    const my_scope = try scope.childScope();
    // On failure dispose my_scope first (hook/resource destroy in node lifetime) then free wrapper
    var wrapper_node: ?*Node = null;
    errdefer {
        my_scope.dispose();
        if (wrapper_node) |w| cx.freeNode(w);
    }
    const allocator = cx.allocator;
    const m = metrics(props.size);
    const colors = palette(cx.tokens);
    reactive.checkBorrow(my_scope, props.options);
    reactive.checkBorrow(my_scope, props.disabled);
    // Trigger geometry all from control metrics (same source as Button/Input/DatePicker);
    // outer frame height = padding_y * 2 + line height fitted.
    const shell_size: control_shell.ControlSize = props.size;
    const cm = @import("../input/styles.zig").fieldMetrics(cx.tokens, shell_size);
    const trigger_radius: f32 = cm.radius;
    const trigger_icon_size: f32 = cm.icon_size;
    const disabled0 = props.disabled.peek();

    const value: ?reactive.Bound(?[]const u8) = if (props.mode == .single) try reactive.resolveModel(?[]const u8, my_scope, props.value) else null;
    const values: ?reactive.Bound([]const []const u8) = if (props.mode == .multiple) try reactive.resolveListModel([]const u8, my_scope, props.values) else null;
    const open = try reactive.resolveModel(bool, my_scope, props.open);
    // Popover and Select share one toggle source: Esc/click outside proposed by Popover, click
    // trigger/select by Select
    const pop_open: Model(bool) = open.toModel();

    // Static options shallow-copied to scope: runtime reads them in click/view
    var options = props.options;
    if (props.options == .value) {
        const holder = try my_scope.allocator.create(OwnedOptions);
        holder.* = .{};
        try my_scope.adoptResource(@ptrCast(holder), OwnedOptions.destroy);
        holder.items = try my_scope.allocator.dupe(SelectOption, props.options.value);
        options = .{ .value = holder.items };
    }

    const pop = try popover_mod.Popover(.{
        .position = .bottom_start,
        .trigger = .manual,
        .offset = .{ .static = 4 },
        .flip = true,
        .width = if (props.panel_width == .trigger) props.width else null,
        .match_trigger_width = props.panel_width == .trigger,
        .constrain_width_to_viewport = true,
        .max_height = props.max_dropdown_height,
        // Anchor dropdown: 160ms fade + 0.98 scale + 6px slide-in to anchor (follows direction on
        // flip).
        .enter_transition = .dropdown,
        .exit_transition = .dropdown,
        .open = pop_open,
        .on_open_change = props.on_open_change,
    }).mount(my_scope, cx);
    wrapper_node = pop.wrapper;
    pop.wrapper.meta.ownership.meta.component_name = "Select";
    pop.trigger.style.width = .{ .px = props.width };
    pop.trigger.style.height = .{ .fit = .{} };

    const state = try my_scope.allocator.create(SelectState);
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            alloc.destroy(@as(*SelectState, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);

    state.* = .{
        .allocator = allocator,
        .cx = cx,
        .mode = props.mode,
        .searchable = props.searchable,
        .clearable = props.clearable,
        .hold_initial_search_label = !props.show_selected_value_in_search,
        .placeholder = props.placeholder,
        .metrics = m,
        .colors = colors,
        .tokens = cx.tokens,
        .shell_size = shell_size,
        .max_visible_tags = props.max_visible_tags,
        .value = value,
        .values = values,
        .open = open,
        .disabled = props.disabled,
        .on_change = props.on_change,
        .on_values_change = props.on_values_change,
        .on_open_change = props.on_open_change,
        .focus_target = pop.trigger,
        // trigger/slot/arrow nodes written after shell mounted below
        .trigger = undefined,
        .content_slot = undefined,
        .append_slot = undefined,
        .append_comp = undefined,
        .leading_icon_node = null,
        .chevron_slot = undefined,
        .trigger_label = null,
        .panel = pop.content,
        .chevron_up = undefined,
        .chevron_down = undefined,
        .clear_button = null,
        .input_state = null,
        .input_node = null,
        .tags_row = null,
    };
    pop.wrapper.addDebugState(@ptrCast(state));

    // Select uses the same three-slot shell as Button/Input. Business content
    // can now shrink only inside content_slot, while clear + chevron remain a
    // fixed append component and never overlap searchable text.
    // The append component is permanently one icon wide. Chevron and the real
    // icon-only clear Button occupy the same 20x20 plane; the clear Button is
    // an absolute overlay revealed only while a selected trigger is hovered.
    const leading_asset = props.leading_icon orelse if (props.searchable and props.mode == .single) icons.search else null;
    const icon_px: core.Sizing = .{ .px = trigger_icon_size };
    const absolute: core.BoxStyle = .{ .position = .absolute };
    const Append = struct { comp: *Node = undefined, chevrons: *Node = undefined, down: *Node = undefined, up: *Node = undefined, clear: ?*Node = null };
    var append: Append = .{};
    var input_result: ?input_mod.InputResult = null;
    var trigger_shell: core.ViewParts = undefined;
    // The trigger is a ControlShell(.field): hover / expanded / disabled frame colors and the
    // cursor are its declarative states; Select adds its geometry as an overlay. The focus ring
    // stays on the popover trigger (the focus target).
    try view.mount(my_scope, cx, pop.trigger, view.attrs(.{ .style = view.styleBy(styles.TriggerFrame{
        .size = shell_size,
        .width = props.width,
        .multiple = props.mode == .multiple,
        .tag_height = m.tag_height,
    }, styles.triggerFrame) }, view.with(control_shell.ControlShell(.{
        .variant = .field,
        .size = shell_size,
        .disabled = props.disabled,
        .expanded = open.read,
        .cursor = .pointer,
        .disabled_cursor = .default,
        .icon_style = core.BoxStyle{ .min_height = cm.lineHeightPx() },
        .append_style = core.BoxStyle{ .min_height = cm.lineHeightPx() },
        .content_style = core.BoxStyle{
            .min_height = cm.lineHeightPx(),
            .width = .{ .grow = .{ .min = 0 } },
            .flex_shrink = 1,
            .overflow_hidden = true,
            .min_width = 0,
        },
    }), .{}).capture(&trigger_shell).slots(.{
        .icon = if (leading_asset) |asset| view.capture(&state.leading_icon_node, iconEl(asset, trigger_icon_size, colors.text_tertiary)) else null,
        // Select's own content row fills the shell's content slot (its `.content_slot` part).
        .content = view.capture(&state.content_slot, view.row(.{ .style = core.BoxStyle{
            .width = .{ .grow = .{ .min = 0 } },
            .height = .{ .fit = .{} },
            .flex_shrink = 1,
            .min_width = 0,
            .align_items = .center,
            .gap = if (props.size == .xs) 3 else if (props.mode == .multiple) 4 else 8,
        } }, .{
            if (props.mode == .multiple) view.capture(&state.tags_viewport, view.row(.{ .style = tagsViewportStyle(colors.bg) }, .{
                view.capture(&state.tags_row, view.row(.{ .style = tagsRowStyle(if (props.size == .xs) 3 else 4) }, {})),
            })) else null,
            if (props.searchable) view.capture(&input_result, input_mod.Input(.{
                .placeholder = if (props.mode == .single) props.placeholder else Source([]const u8){ .value = "Search..." },
                .placeholder_color = colors.text_tertiary,
                .size = shell_size,
                .width = @max(@as(f32, 88), props.width * 0.38),
                .disabled = disabled0 and props.disabled.isStatic(),
                .embedded = true,
                .on_change = cx.on(SelectState, state, onSearchChanged),
            })) else null,
            // Text written by view effect at mount end (syncSelection copies for own: signal-source
            // text valid only this call);
            // tag fills remaining content width
            if (!props.searchable and props.mode == .single)
                view.capture(&state.trigger_label, view.attrs(.{ .style = core.BoxStyle{ .width = .{ .grow = .{} }, .min_width = 0 } }, triggerTextEl("", cm, colors.text_tertiary)))
            else
                null,
        })),
        .append = view.capture(&append.comp, view.row(.{ .style = core.BoxStyle{
            .width = icon_px,
            .height = icon_px,
            .align_items = .center,
            .justify = .end,
        } }, .{
            view.capture(&append.chevrons, view.row(.{ .style = core.BoxStyle{
                .width = icon_px,
                .height = icon_px,
                .align_items = .center,
                .justify = .center,
            } }, .{
                view.capture(&append.down, view.attrs(.{ .style = absolute }, iconEl(icons.chevron_down, trigger_icon_size, colors.text_tertiary))),
                view.capture(&append.up, view.attrs(.{ .style = absolute }, iconEl(icons.chevron_up, trigger_icon_size, colors.primary))),
            })),
            if (props.clearable and props.mode == .single and !props.searchable) view.capture(&append.clear, view.attrs(.{ .style = absolute }, button_mod.Button(.{
                .variant = .ghost,
                .size = .xs,
                .icon_only = true,
                .icon_asset = icons.close,
                .icon_size = trigger_icon_size,
                .icon_tint = colors.text_tertiary,
                .base_style = .{
                    .width = icon_px,
                    .height = icon_px,
                    .padding = core.Padding.all(0),
                    .background = colors.bg,
                    .corner_radius = @min(4, trigger_radius),
                    .overflow_hidden = true,
                },
                .hover_style = .{ .background = colors.hover },
                .pressed_style = .{ .background = colors.inset },
                .on_event = clearEvent,
                .event_context = state,
            }))) else null,
        })),
    })));
    const shell = trigger_shell.root.?;
    state.trigger = shell;
    // The shell's append slot box (it hosts the append comp).
    state.append_slot = append.comp.parent.?;
    if (input_result) |ir| {
        state.input_state = ir.state;
        state.query_text = ir.value;
        state.input_node = ir.node;
    }
    state.append_comp = append.comp;
    if (state.tags_viewport) |viewport| {
        viewport.behavior.events.event_context = @ptrCast(state);
        viewport.behavior.events.on_scroll = tagsViewportScroll;
        viewport.meta.per_frame.hooks.before_render.main = tagsViewportBeforeRender;
    }
    if (append.clear) |clear| {
        try clear.applyTransition(allocator, &comptime recipe_mod.transition("opacity 160ms ease-out"));
        clear.snapTransition(allocator, .opacity, 0);
        state.clear_button = clear;
    }
    const chevron_stack = append.chevrons;
    const chevron_down = append.down;
    const chevron_up = append.up;
    state.chevron_down = chevron_down;
    state.chevron_up = chevron_up;
    state.chevron_slot = chevron_stack;
    try chevron_stack.applyTransition(allocator, &comptime recipe_mod.transition("opacity 160ms ease-out"));
    chevron_stack.snapTransition(allocator, .opacity, 1);
    try chevron_down.applyTransition(allocator, &comptime recipe_mod.transition("rotate 180ms ease-in-out"));
    // rotate lives in the ext block: reserve it here, snapTransition would panic on OOM
    _ = try chevron_down.style.ensureExtFallible(allocator);
    // A select mounted open shows its open state at once, like its popover: the chevron starts
    // turned instead of rotating in from 0.
    chevron_down.snapTransition(allocator, .rotate, if (open.read.peek()) std.math.pi else 0);

    shell.behavior.events.event_context = @ptrCast(state);
    shell.behavior.events.on_event = triggerEvent;
    pop.trigger.behavior.events.key_context = @ptrCast(state);
    pop.trigger.behavior.events.on_key_down = triggerKeyDown;
    pop.trigger.setFocusable(true);
    pop.trigger.behavior.interaction.a11y = .{
        .role = .combobox,
        .has_popup = .listbox,
        .disabled = false,
        .expanded = false,
        .expansion = .{ .context = @ptrCast(state), .set = setAccessibleExpanded },
    };
    state.applyDisabled(disabled0);
    try hooks.useFocusRing(my_scope, cx, pop.trigger, .{ .width = cx.tokens.tokens.border_width.focus, .offset = cx.tokens.tokens.size.focus_offset });

    pop.content.style.direction = .column;
    pop.content.style.gap = 0;
    pop.content.style.padding = core.Padding.all(m.panel_padding);
    pop.content.setBackgroundRaw(colors.panel);
    pop.content.style.border = .{ .overlay = true, .width = 1, .color = cx.tokens.tokens.color.border, .radius = m.panel_radius };
    const panel_ext = try pop.content.style.ensureExtFallible(allocator);
    panel_ext.corner_radius = .{ .all = m.panel_radius };
    panel_ext.setShadow(cx.tokens.tokens.shadow.md);
    panel_ext.hit_shape = .{ .rounded_rect = m.panel_radius };
    panel_ext.clip_shape = .{ .rounded_rect = m.panel_radius };
    pop.content.behavior.interaction.a11y = .{ .role = .listbox, .multiselectable = props.mode == .multiple };

    var option_container = pop.content;
    if (props.mode == .multiple and props.selection_footer) {
        option_container = try core.adoptChild(cx, allocator, pop.content, try core.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} }, .direction = .column }, .{}));
        const footer = try view.append(pop.scope, cx, pop.content, view.row(.{ .style = styles.footerStyle }, .{
            view.capture(&state.footer_label, view.text(.{ .style = styles.footerText }, "")),
            button_mod.Button(.{ .label = "Clear", .variant = .link, .size = .xs, .on_click = cx.on(SelectState, state, clearAllSelected) }),
        }));
        _ = footer;
    }
    // Option rows write content (portal): rebuild and view effect belong to Popover scope
    // Rebuilt with the options and with the theme (rows and tags paint theme colors).
    const options_view = try pop.scope.createMemo(SelectState.OptionsView, SelectState.OptionsViewSources{ .options = options, .theme = try cx.themeSignal() }, SelectState.OptionsViewSources.compute);
    try bind_mod.rebuildOn(cx, pop.scope, options_view, option_container, state, SelectState.optionsViewKey, SelectState.buildOptionsView);
    try pop.scope.createEffect(state, SelectState.viewEffect);
    state.hold_initial_search_label = false;
    return .{
        .wrapper = pop.wrapper,
        .trigger = shell,
        .panel = pop.content,
        .value = if (value) |v| v.asSignal() else null,
        .values = if (values) |v| v.asSignal() else null,
        .open = open.asSignal(),
        .content_slot = state.content_slot,
        .append_slot = state.append_slot,
        .append_comp = state.append_comp,
        .leading_icon = state.leading_icon_node,
        .chevron_slot = state.chevron_slot,
        .chevron_up = state.chevron_up,
        .chevron_down = state.chevron_down,
        .clear_button = state.clear_button,
        .search_input = if (state.input_state) |is| is.input_container_node else null,
    };
}

const OwnedOptions = struct {
    items: []SelectOption = &.{},

    fn destroy(ptr: *anyopaque, alloc: Allocator) void {
        const h: *OwnedOptions = @ptrCast(@alignCast(ptr));
        alloc.free(h.items);
        alloc.destroy(h);
    }
};

// Tests

const testing = std.testing;

const T = struct {
    cx: *Cx,
    scope: *Scope,
    root: *Node,

    fn init() !T {
        const cx = try Cx.init(testing.allocator, std.testing.io);
        errdefer cx.deinit();
        const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
        cx.root = root;
        const scope = try Scope.init(testing.allocator, null, cx.owner);
        return .{ .cx = cx, .scope = scope, .root = root };
    }

    fn deinit(self: T) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn mount(self: T, props: anytype) !SelectResult {
        const r = try Select(props).mount(self.scope, self.cx);
        try self.root.appendChild(testing.allocator, r.wrapper);
        return r;
    }
};

const two_opts = [_]SelectOption{
    .{ .value = "one", .label = "Option 1" },
    .{ .value = "two", .label = "Option 2" },
};
const three_opts = [_]SelectOption{
    .{ .value = "one", .label = "Option 1" },
    .{ .value = "two", .label = "Option 2" },
    .{ .value = "three", .label = "Option 3" },
};

fn labelText(st: *SelectState) []const u8 {
    return st.trigger_label.?.getText().?.content;
}

const Spy = struct {
    calls: usize = 0,
    last: ?[]const u8 = null,
    opens: usize = 0,
    fn changed(self: *Spy, v: ?[]const u8) void {
        self.calls += 1;
        self.last = v;
    }
    fn opened(self: *Spy, _: bool) void {
        self.opens += 1;
    }
};

test "Select: single selection commits and clear resets" {
    const t = try T.init();
    defer t.deinit();
    var spy = Spy{};
    const result = try t.mount(.{ .options = &two_opts, .clearable = true, .on_change = t.cx.on(Spy, &spy, Spy.changed) });
    const st = stateOf(result);
    try testing.expectEqual(@as(f32, 0), st.clear_button.?.getOpacity());
    try testing.expectEqual(@as(f32, 1), st.chevron_down.getOpacity());
    commit(st, 1);
    try testing.expectEqualStrings("two", result.value.?.peek().?);
    try testing.expectEqualStrings("Option 2", labelText(st));
    try testing.expectEqualStrings("two", spy.last.?);
    try testing.expectEqual(@as(f32, 0), st.clear_button.?.getOpacity());
    try testing.expectEqual(@as(f32, 1), st.chevron_slot.getOpacity());
    _ = triggerEvent(.{ .mouse_enter = {} }, @ptrCast(st));
    try testing.expect(st.is_trigger_hovered);
    try testing.expect(st.clear_button.?.frame_state.state_bits.flags.hit_test_visible);
    const clear_opacity_transition = st.clear_button.?.frame_state.frame_local.runtime.transitions.?.find(.opacity).?;
    const chevron_opacity_transition = st.chevron_slot.frame_state.frame_local.runtime.transitions.?.find(.opacity).?;
    try testing.expect(clear_opacity_transition.active);
    try testing.expectEqual(@as(f32, 1), clear_opacity_transition.to_value);
    try testing.expect(chevron_opacity_transition.active);
    try testing.expectEqual(@as(f32, 0), chevron_opacity_transition.to_value);
    // Declarative transitions retain their current values until render ticks;
    // E2E verifies the intermediate and settled opacity values.
    try testing.expectEqual(@as(f32, 0), st.clear_button.?.getOpacity());
    try testing.expectEqual(@as(f32, 1), st.chevron_slot.getOpacity());
    result.open.?.set(true);
    const rotate_transition = st.chevron_down.frame_state.frame_local.runtime.transitions.?.find(.rotate).?;
    try testing.expect(rotate_transition.active);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), rotate_transition.to_value, 0.0001);
    _ = clearEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(st));
    try testing.expect(result.value.?.peek() == null);
    try testing.expect(spy.last == null);
    try testing.expectEqual(@as(usize, 2), spy.calls);
    try testing.expect(!result.open.?.peek());
    try testing.expectEqualStrings("Select an option...", labelText(st));
    try testing.expect(!st.clear_button.?.frame_state.state_bits.flags.hit_test_visible);
}

test "Select: 空 options 时方向键不 panic" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &[_]SelectOption{} });
    const st = stateOf(result);
    _ = triggerKeyDown(.down, .{}, @ptrCast(st));
    _ = triggerKeyDown(.up, .{}, @ptrCast(st));
    try testing.expect(st.highlighted_index == null);
}

test "Select: 反复 mount/free 不泄漏 World element slot（未用 icon_slot 走 freeNode）" {
    const t = try T.init();
    defer t.deinit();
    const Cycle = struct {
        fn run(c: *Cx, s: *Scope, r: *Node) !void {
            const sub = try s.childScope();
            const res = try Select(.{ .options = &two_opts }).mount(sub, c);
            try r.appendChild(c.allocator, res.wrapper);
            c.detachChild(r, res.wrapper);
            c.freeNode(res.wrapper);
            sub.dispose();
        }
    };
    try Cycle.run(t.cx, t.scope, t.root);
    const baseline = t.cx.world.elements.count();
    for (0..10) |_| try Cycle.run(t.cx, t.scope, t.root);
    try testing.expectEqual(baseline, t.cx.world.elements.count());
}

test "Select: multiple selection toggles independently; tags follow the values" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &three_opts, .mode = .multiple });
    const st = stateOf(result);
    try testing.expect(result.value == null);
    commit(st, 0);
    commit(st, 2);
    try testing.expect(st.isSelected(0) and st.isSelected(2));
    try testing.expectEqual(@as(usize, 2), result.values.?.peek().len);
    try testing.expectEqualStrings("three", result.values.?.peek()[1]);
    try testing.expectEqual(core.Display.flex, st.tag_nodes[2].style.display);
    try testing.expectEqual(core.Display.none, st.tag_nodes[1].style.display);
    commit(st, 0);
    try testing.expect(!st.isSelected(0));
    // Delete tag also just proposes
    _ = tagCloseEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(st.tag_nodes[2].children.items[1].behavior.events.event_context));
    try testing.expectEqual(@as(usize, 0), result.values.?.peek().len);
}

test "Select(multiple): values and tags follow pick order, not option order" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &three_opts, .mode = .multiple });
    const st = stateOf(result);
    commit(st, 2);
    commit(st, 0);
    commit(st, 1);
    const picked = result.values.?.peek();
    try testing.expectEqual(@as(usize, 3), picked.len);
    try testing.expectEqualStrings("three", picked[0]);
    try testing.expectEqualStrings("one", picked[1]);
    try testing.expectEqualStrings("two", picked[2]);
    const row = st.tags_row.?.children.items;
    try testing.expect(row[0] == st.tag_nodes[2] and row[1] == st.tag_nodes[0] and row[2] == st.tag_nodes[1]);
    // Unpicking the middle one keeps the others in place; picking it again appends it.
    commit(st, 0);
    commit(st, 0);
    const again = result.values.?.peek();
    try testing.expectEqualStrings("three", again[0]);
    try testing.expectEqualStrings("two", again[1]);
    try testing.expectEqualStrings("one", again[2]);
    try testing.expect(st.tags_row.?.children.items[2] == st.tag_nodes[0]);
}

test "Select: bound value —— 外部写入刷新标签与勾选；不在选项里的值不显示也不回写" {
    const t = try T.init();
    defer t.deinit();
    const v = try t.scope.createSignal(?[]const u8, "two");
    const result = try t.mount(.{ .options = &two_opts, .value = v });
    const st = stateOf(result);
    try testing.expectEqualStrings("Option 2", labelText(st));
    v.set("one");
    try testing.expectEqualStrings("Option 1", labelText(st));
    try testing.expectEqual(@as(f32, 1), st.check_nodes[0].getOpacity());
    v.set("nope");
    try testing.expectEqualStrings("Select an option...", labelText(st));
    try testing.expectEqualStrings("nope", v.peek().?);
}

test "Select: mounted open shows the chevron turned; opening later rotates it in" {
    const t = try T.init();
    defer t.deinit();
    const open_result = try t.mount(.{ .options = &two_opts, .open = true });
    const open_st = stateOf(open_result);
    try testing.expect(open_st.shown_open);
    const turned = open_st.chevron_down.frame_state.frame_local.runtime.transitions.?.find(.rotate).?;
    try testing.expect(!turned.active);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), turned.from_value, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), open_st.chevron_down.style.rotate(), 1e-4);

    const closed_result = try t.mount(.{ .options = &two_opts });
    const closed_st = stateOf(closed_result);
    _ = triggerEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(closed_st));
    try testing.expect(closed_st.shown_open);
    const rotating = closed_st.chevron_down.frame_state.frame_local.runtime.transitions.?.find(.rotate).?;
    try testing.expect(rotating.active);
    try testing.expectApproxEqAbs(@as(f32, 0), rotating.from_value, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), rotating.to_value, 1e-4);
}

test "Select: a closing searchable panel keeps its filtered rows until the next open" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &two_opts, .searchable = true });
    const st = stateOf(result);
    st.proposeOpen(true);
    onSearchChanged(st, "2");
    try testing.expectEqual(core.Display.none, st.option_nodes[0].style.display);
    try testing.expectEqual(core.Display.flex, st.option_nodes[1].style.display);
    st.proposeOpen(false);
    try testing.expect(!st.shown_open);
    // The draft is discarded, the fading panel still shows "Option 2" only.
    try testing.expectEqual(@as(usize, 0), st.query_len);
    try testing.expectEqual(core.Display.none, st.option_nodes[0].style.display);
    st.proposeOpen(true);
    try testing.expectEqual(core.Display.flex, st.option_nodes[0].style.display);
    try testing.expectEqual(core.Display.flex, st.option_nodes[1].style.display);
}

test "Select: ui.split 拒绝时显示不动、on_change 不调；open 也走提议" {
    const t = try T.init();
    defer t.deinit();
    const Parent = struct {
        v: *Signal(?[]const u8),
        o: *Signal(bool),
        allow: bool = false,
        fn writeV(self: *@This(), x: ?[]const u8) void {
            if (self.allow) self.v.set(x);
        }
        fn writeO(self: *@This(), x: bool) void {
            if (self.allow) self.o.set(x);
        }
    };
    var parent = Parent{ .v = try t.scope.createSignal(?[]const u8, null), .o = try t.scope.createSignal(bool, false) };
    var spy = Spy{};
    const result = try t.mount(.{
        .options = &two_opts,
        .value = reactive.split(parent.v, t.cx.on(Parent, &parent, Parent.writeV)),
        .open = reactive.split(parent.o, t.cx.on(Parent, &parent, Parent.writeO)),
        .on_change = t.cx.on(Spy, &spy, Spy.changed),
        .on_open_change = t.cx.on(Spy, &spy, Spy.opened),
    });
    const st = stateOf(result);
    try testing.expect(result.value == null and result.open == null);
    _ = triggerEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(st));
    try testing.expect(!st.shown_open);
    commit(st, 1);
    try testing.expectEqualStrings("Select an option...", labelText(st));
    try testing.expectEqual(@as(usize, 0), spy.calls);
    parent.allow = true;
    _ = triggerEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(st));
    try testing.expect(st.shown_open);
    try testing.expectEqual(@as(usize, 1), spy.opens);
    commit(st, 1);
    try testing.expectEqualStrings("Option 2", labelText(st));
    try testing.expect(!st.shown_open);
    try testing.expectEqual(@as(usize, 1), spy.calls);
}

test "Select: options 来自 signal —— 换选项重建行，选择按新选项重新派生" {
    const t = try T.init();
    defer t.deinit();
    const opts = try t.scope.createSignal([]const SelectOption, &two_opts);
    const v = try t.scope.createSignal(?[]const u8, "two");
    const result = try t.mount(.{ .options = opts, .value = v });
    const st = stateOf(result);
    try testing.expectEqual(@as(usize, 2), result.panel.children.items.len);
    opts.set(&three_opts);
    try testing.expectEqual(@as(usize, 3), result.panel.children.items.len);
    try testing.expectEqual(@as(usize, 3), st.option_nodes.len);
    try testing.expect(st.isSelected(1));
    commit(st, 2);
    try testing.expectEqualStrings("three", v.peek().?);
    opts.set(two_opts[0..1]); // Selected item removed: doesn't display as selected, value doesn't write back
    try testing.expect(!st.isSelected(0));
    try testing.expectEqualStrings("Select an option...", labelText(st));
    try testing.expectEqualStrings("three", v.peek().?);
}

test "Select(multiple): options 换了之后标签行只剩新一轮的标签，勾选按值保留" {
    const t = try T.init();
    defer t.deinit();
    const opts = try t.scope.createSignal([]const SelectOption, &two_opts);
    const vals = try t.scope.createList([]const u8, &.{"two"});
    const result = try t.mount(.{ .options = opts, .mode = .multiple, .values = vals });
    const st = stateOf(result);
    try testing.expectEqual(@as(usize, 2), st.tags_row.?.children.items.len);
    opts.set(&three_opts);
    try testing.expectEqual(@as(usize, 3), st.tags_row.?.children.items.len);
    try testing.expect(st.isSelected(1));
    try testing.expectEqual(core.Display.flex, st.tag_nodes[1].style.display);
}

test "Select(searchable): 选中后第一次输入立即过滤（旧实现会吞掉这次输入）并清掉选择" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &three_opts, .searchable = true });
    const st = stateOf(result);
    commit(st, 0);
    try testing.expectEqualStrings("Option 1", st.input_state.?.getText());
    onSearchChanged(st, "3");
    try testing.expect(result.value.?.peek() == null);
    try testing.expectEqual(core.Display.none, st.option_nodes[0].style.display);
    try testing.expectEqual(core.Display.flex, st.option_nodes[2].style.display);
    try testing.expect(st.shown_open);
    // Keyboard nav skips filtered-out items
    _ = triggerKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 2), st.highlighted_index);
    _ = triggerKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 2), st.highlighted_index);
}

test "Select(searchable): show_selected_value_in_search=false 只管挂载时，之后选中照常写回标签" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &three_opts, .searchable = true, .value = "one", .show_selected_value_in_search = false });
    const st = stateOf(result);
    try testing.expectEqualStrings("", st.input_state.?.getText());
    try testing.expect(st.isSelected(0));
    onSearchChanged(st, "3");
    commit(st, 2);
    try testing.expectEqualStrings("Option 3", st.input_state.?.getText());
}

test "Select(searchable): 父组件拒绝清空选择时，编辑中不覆盖用户输入，关闭面板后回到选中项的标签" {
    const t = try T.init();
    defer t.deinit();
    const Parent = struct {
        v: *Signal(?[]const u8),
        fn write(self: *@This(), x: ?[]const u8) void {
            if (x != null) self.v.set(x); // Only accept select, not clear
        }
    };
    var parent = Parent{ .v = try t.scope.createSignal(?[]const u8, "one") };
    const result = try t.mount(.{ .options = &three_opts, .searchable = true, .value = reactive.split(parent.v, t.cx.on(Parent, &parent, Parent.write)) });
    const st = stateOf(result);
    try testing.expectEqualStrings("Option 1", st.input_state.?.getText());
    // Real typing path: after select-all, input, Input writes full text to own data source, then
    // calls onSearchChanged
    // (propose null blocked, meanwhile propose open -> settle -> view refresh)
    _ = input_mod.inputEventHandler(.{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } }, @ptrCast(st.input_state.?));
    _ = input_mod.inputEventHandler(.{ .text_input = .{ .text = "Opt" } }, @ptrCast(st.input_state.?));
    try testing.expect(st.shown_open);
    try testing.expectEqualStrings("Opt", st.input_state.?.getText());
    try testing.expectEqualStrings("one", parent.v.peek().?);
    // Close = leave edit mode: search draft discarded, display back to data source (still select
    // one)
    st.proposeOpen(false);
    try testing.expect(!st.shown_open);
    try testing.expectEqualStrings("Option 1", st.input_state.?.getText());
}

test "Select(searchable): 外部清空选择时清掉搜索框里组件写入的标签，不碰用户打的字" {
    const t = try T.init();
    defer t.deinit();
    const v = try t.scope.createSignal(?[]const u8, "one");
    const result = try t.mount(.{ .options = &three_opts, .searchable = true, .value = v });
    const st = stateOf(result);
    try testing.expectEqualStrings("Option 1", st.input_state.?.getText());
    v.set(null);
    try testing.expectEqualStrings("", st.input_state.?.getText());
    // External clear while typing doesn't wipe input
    v.set("two");
    try testing.expectEqualStrings("Option 2", st.input_state.?.getText());
    _ = input_mod.inputEventHandler(.{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } }, @ptrCast(st.input_state.?));
    _ = input_mod.inputEventHandler(.{ .text_input = .{ .text = "Opt" } }, @ptrCast(st.input_state.?));
    v.set(null);
    try testing.expectEqualStrings("Opt", st.input_state.?.getText());
}

test "Select(multiple): 选项重建在任意分配点失败时，不留下半建的标签" {
    // Directly drive buildOptions (rebuildOn fail in effect only logs err, test runner judges
    // fail):
    // after failure, tag count in tags_row must match tag_nodes (both empty), no orphaned tags with
    // released context
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const cx = try Cx.init(failing.allocator(), std.testing.io);
    defer cx.deinit();
    cx.root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    const scope = try Scope.init(failing.allocator(), null, cx.owner);
    defer scope.dispose();
    const result = try Select(.{ .options = &two_opts, .mode = .multiple }).mount(scope, cx);
    const st = stateOf(result);
    var k: usize = 0;
    while (true) : (k += 1) {
        try testing.expect(k < 1000);
        const child = try scope.childScope();
        const scratch = try core.box(cx, .{}, .{});
        failing.fail_index = failing.alloc_index + k;
        const r = st.buildOptions(child, scratch, &three_opts);
        failing.fail_index = std.math.maxInt(usize);
        if (r) |_| {
            try testing.expectEqual(@as(usize, 3), st.tags_row.?.children.items.len);
            // Cleanup per rebuildOn unmount order: component unmounts first, then free this-round
            // child scope and rows
            cx.freeNode(result.wrapper);
            child.dispose();
            cx.freeNode(scratch);
            break;
        } else |_| {
            try testing.expectEqual(@as(usize, 0), st.tag_nodes.len);
            try testing.expectEqual(@as(usize, 0), st.tags_row.?.children.items.len);
            child.dispose();
            cx.freeNode(scratch);
        }
    }
    try testing.expect(k > 0);
}

test "Select: disabled 来自 signal —— 禁用时点击 / 按键 / 选中都无效，a11y 同步" {
    const t = try T.init();
    defer t.deinit();
    const d = try t.scope.createSignal(bool, true);
    const result = try t.mount(.{ .options = &two_opts, .disabled = d });
    const st = stateOf(result);
    try testing.expect(st.focus_target.behavior.interaction.a11y.?.disabled);
    try testing.expectEqual(EventResult.ignored, triggerEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(st)));
    commit(st, 0);
    try testing.expect(result.value.?.peek() == null);
    d.set(false);
    try testing.expect(!st.focus_target.behavior.interaction.a11y.?.disabled);
    commit(st, 0);
    try testing.expectEqualStrings("one", result.value.?.peek().?);
}

test "Select: values 绑定的 signal 不是 createList 创建的 -> 拒绝" {
    const t = try T.init();
    defer t.deinit();
    const borrowed = try t.scope.createSignal([]const []const u8, &.{});
    try testing.expectError(error.ListModelNotOwned, Select(.{ .options = &two_opts, .mode = .multiple, .values = borrowed }).mount(t.scope, t.cx));
}

test "Select(multiple): a11y item_selection —— add / replace / remove 走同一提议管线" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &three_opts, .mode = .multiple });
    const st = stateOf(result);
    commit(st, 2);
    try testing.expect(st.isSelected(2));
    const contract = st.option_nodes[1].behavior.interaction.a11y.?.item_selection.?;
    try testing.expect(contract.set(contract.context, .add));
    try testing.expect(st.isSelected(1) and st.isSelected(2));
    try testing.expect(contract.set(contract.context, .replace));
    try testing.expect(st.isSelected(1) and !st.isSelected(2));
    try testing.expect(contract.set(contract.context, .remove));
    try testing.expectEqual(@as(usize, 0), st.selectedCount());
}

test "Select: a11y item_selection / expansion —— 单选替换、禁止并列 add" {
    const t = try T.init();
    defer t.deinit();
    const result = try t.mount(.{ .options = &three_opts });
    const st = stateOf(result);
    const expansion = st.focus_target.behavior.interaction.a11y.?.expansion.?;
    try testing.expect(expansion.set(expansion.context, true));
    try testing.expect(st.shown_open);
    try testing.expect(expansion.set(expansion.context, false));
    try testing.expect(!st.shown_open);
    const first = st.option_nodes[0].behavior.interaction.a11y.?.item_selection.?;
    const second = st.option_nodes[1].behavior.interaction.a11y.?.item_selection.?;
    try testing.expect(first.set(first.context, .replace));
    try testing.expectEqualStrings("one", result.value.?.peek().?);
    try testing.expect(!second.set(second.context, .add));
    try testing.expect(second.set(second.context, .replace));
    try testing.expectEqualStrings("two", result.value.?.peek().?);
    try testing.expect(second.set(second.context, .remove));
    try testing.expect(result.value.?.peek() == null);
}

// OOM sweep by alloc point, see src/ui/components/oom_sweep.zig
test "Select: placeholder 来自 signal —— 未选中时标签跟着换（自持副本），选中时不受影响" {
    const t = try T.init();
    defer t.deinit();
    const ph = try t.scope.createText("Loading…", .{});
    const v = try t.scope.createSignal(?[]const u8, null);
    const result = try t.mount(.{ .options = &two_opts, .placeholder = ph, .value = v });
    const st = stateOf(result);
    try testing.expectEqualStrings("Loading…", labelText(st));
    // Tag holds own copy, doesn't borrow signal buffer (latter valid only this call)
    try testing.expect(labelText(st).ptr != ph.peek().ptr);

    ph.set("Pick a city");
    try testing.expectEqualStrings("Pick a city", labelText(st));

    v.set("two");
    ph.set("Pick a country");
    try testing.expectEqualStrings("Option 2", labelText(st));
    // After clearing selection, display is latest placeholder text
    v.set(null);
    try testing.expectEqualStrings("Pick a country", labelText(st));
}

test "Select(searchable): placeholder 来自 signal 时搜索框占位符跟着换" {
    const t = try T.init();
    defer t.deinit();
    const ph = try t.scope.createText("Search cities", .{});
    const result = try t.mount(.{ .options = &two_opts, .placeholder = ph, .searchable = true });
    const st = stateOf(result);
    try testing.expectEqualStrings("Search cities", st.input_state.?.placeholder_text.?);
    ph.set("Search countries");
    try testing.expectEqualStrings("Search countries", st.input_state.?.placeholder_text.?);
}

test "select(dynamic placeholder): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select(placeholder)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const ph = try scope.createText("Loading…", .{});
            return (try Select(.{ .options = &two_opts, .placeholder = ph }).mount(scope, cx)).wrapper;
        }
    }.m);
}

// Reference-checked OOM sweep (see oom_sweep.zig): a mount that reports success must look exactly
// like the uninjected mount; `check` also pins the states the reference was given.
test "select(value+disabled): mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMountVerified("select(value+disabled)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const value = try scope.createSignal(?[]const u8, "two");
            const disabled = try scope.createSignal(bool, true);
            return (try Select(.{ .options = &two_opts, .value = value, .disabled = disabled, .clearable = true }).mount(scope, cx)).wrapper;
        }
    }.m, struct {
        fn find(n: *Node, comptime pred: fn (*Node) bool) bool {
            if (pred(n)) return true;
            for (n.children.items) |c| if (find(c, pred)) return true;
            return false;
        }
        fn disabledFrame(n: *Node) bool {
            return n.style.border.width > 0 and Color.eql(core.theme.dark.tokens.color.disabled_bg, n.getBackground());
        }
        fn selectedLabel(n: *Node) bool {
            const t = n.getText() orelse return false;
            return std.mem.eql(u8, t.content, "Option 2");
        }
        fn check(root: *Node) anyerror!void {
            // the disabled frame and the selected option's label, both from sources at mount
            try std.testing.expect(find(root, disabledFrame));
            try std.testing.expect(find(root, selectedLabel));
        }
    }.check);
}

test "select(clearable): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select(clearable)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Select(.{ .options = &two_opts, .clearable = true }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "select(multiple, searchable, dynamic): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select(multiple)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const opts = try scope.createSignal([]const SelectOption, &three_opts);
            const vals = try scope.createList([]const u8, &.{"two"});
            const d = try scope.createSignal(bool, false);
            return (try Select(.{ .options = opts, .mode = .multiple, .values = vals, .searchable = true, .disabled = d }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "Select multi overflow and footer follow selection across option rebuild and Clear" {
    const t = try T.init();
    defer t.deinit();
    const options = try t.scope.createSignal([]const SelectOption, &three_opts);
    const disabled = try t.scope.createSignal(bool, false);
    const result = try t.mount(.{ .options = options, .mode = .multiple, .values = &[_][]const u8{ "one", "two", "three" }, .max_visible_tags = 1, .selection_footer = true, .disabled = disabled });
    const state = stateOf(result);
    try testing.expectEqualStrings("+2", state.overflow_label.?.getText().?.content);
    try testing.expectEqual(core.Display.none, state.tag_nodes[1].style.display);
    try testing.expectEqualStrings("3 of 3 selected", state.footer_label.?.getText().?.content);
    options.set(&two_opts);
    try testing.expectEqualStrings("+1", state.overflow_label.?.getText().?.content);
    try testing.expectEqualStrings("2 of 2 selected", state.footer_label.?.getText().?.content);
    disabled.set(true);
    clearAllSelected(state);
    try testing.expectEqual(@as(usize, 3), result.values.?.peek().len);
    disabled.set(false);
    clearAllSelected(state);
    try testing.expectEqual(@as(usize, 0), result.values.?.peek().len);
    try testing.expectEqual(core.Display.none, state.overflow_label.?.style.display);
    try testing.expectEqualStrings("0 of 2 selected", state.footer_label.?.getText().?.content);
}

test "review regression 9: multi-select checkbox shares the thin border token" {
    var t = try T.init();
    defer t.deinit();
    var custom = t.cx.tokens.*;
    custom.tokens.border_width.thin = 3;
    t.cx.setTheme(&custom);
    const result = try t.mount(.{ .options = &three_opts, .mode = .multiple });
    const st = stateOf(result);
    for (st.option_nodes) |row| {
        try testing.expectEqual(custom.tokens.border_width.thin, row.children.items[0].style.border.width);
    }
}
