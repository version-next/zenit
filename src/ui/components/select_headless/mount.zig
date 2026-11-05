//! Select Headless mount layer.
//! Rendering on top of the pure-logic navigation in state_machine.zig (arrow keys / PageUp/
//! PageDown / Home/End / Esc / Enter / typeahead): Popover for trigger/content overlay;
//! optional VirtualList pooling; recipe.zig styles; render_trigger / render_item custom slots.
//!
//! Data flow: `value: Model(?ValueT)`, `open: Model(bool)`, `options: Source(...)`,
//! `disabled: Source(bool)`. Click / Enter / Esc only propose; the view refreshes from the data
//! source. Trigger a11y: role=combobox + has_popup=listbox + aria-activedescendant follows
//! highlight.
//!
//! Usage (comptime ValueT):
//! ```
//! const SH = ui.select_headless;
//! const fruit = try scope.createSignal(?i32, null);
//! const result = try SH.SelectHeadless(i32, .{
//!     .options = &.{
//!         .{ .value = 1, .label = "Apple" },
//!         .{ .value = 2, .label = "Banana" },
//!     },
//!     .placeholder = "Pick a fruit...",
//!     .value = fruit,
//!     // .virtualize = true,   // for 1k+ options
//!     // .render_trigger = myTriggerFn,
//!     // .render_item = myItemFn,
//! }).mount(scope, cx);
//! ```

const std = @import("std");
const icons = @import("zenit_system_icons");
const sm = @import("state_machine.zig");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const control_shell = @import("../control_shell/mod.zig");
const popover_mod = @import("../popover/mod.zig");
const virtual_list_mod = @import("../virtual_list/mod.zig");
const recipe_mod = @import("../../recipe.zig");
const theme = @import("../../theme.zig");
const reactive = @import("../../reactive.zig");
const bind_mod = @import("../../bind.zig");

pub const Option = sm.Option;
pub const SelectState = sm.SelectState;
pub const Action = sm.Action;

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
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const ConditionalStyle = recipe_mod.ConditionalStyle;
const ThemeTokens = theme.ThemeTokens;

// SelectSlotRecipe: three slots (trigger / content / item), defined via recipe.slotRecipe.
// Callers can use SelectSlotRecipe.resolve(.{}, tokens) to get the ConditionalStyle set to
// apply to a slot Node.
// Style values are the original hardcoded ones (bg_primary / border / fg_primary / bg_hover /
// bg_active).

pub const SelectVariant = enum { default };
/// same ControlSize as Button / Input / Select / DatePicker (xs / sm / md / lg).
/// note: old private enum `.sm` actually was xs geometry (20 height); unified `.sm` = theme sm
/// (24),
/// use `.xs` for 20.
pub const SelectSize = control_shell.ControlSize;

pub const SelectSlotRecipe = recipe_mod.slotRecipe(struct {
    pub const Slots = struct {
        trigger: ConditionalStyle = .{},
        content: ConditionalStyle = .{},
        item: ConditionalStyle = .{},
    };

    pub const Variants = struct {
        variant: SelectVariant = .default,
        size: SelectSize = .md,
    };

    pub fn base(t: *const ThemeTokens) Slots {
        return .{
            .trigger = .{
                .base = .{
                    .background = t.tokens.color.bg_primary,
                    .text_color = t.tokens.color.fg_primary,
                },
                .focus = .{ .background = t.tokens.color.bg_primary },
                .disabled = .{ .background = t.tokens.color.disabled_bg, .border_color = t.tokens.color.border, .text_color = t.tokens.color.fg_disabled },
            },
            .content = .{
                .base = .{ .background = t.tokens.color.bg_primary },
            },
            .item = .{
                .base = .{ .text_color = t.tokens.color.fg_primary },
                .selected = .{ .background = t.tokens.color.list_selection_bg, .text_color = t.tokens.color.selection_fg },
                .hover = .{ .background = t.tokens.color.bg_hover },
                .active = .{ .background = t.tokens.color.bg_hover },
                .disabled = .{ .text_color = t.tokens.color.fg_disabled },
            },
        };
    }

    pub const variants = .{
        .variant = struct {
            fn resolve(_: SelectVariant, _: *const ThemeTokens) Slots {
                return .{};
            }
        }.resolve,
        .size = struct {
            fn resolve(_: SelectSize, _: *const ThemeTokens) Slots {
                return .{};
            }
        }.resolve,
    };
});

// trigger geometry (height / padding / radius / font size / icon) all from ControlShell recipe
// (control_shell.metrics(tokens, size)), not table here. dropdown row height is list measure, not
// control frame:
pub fn itemHeight(size: SelectSize) f32 {
    _ = size;
    return 28; // RYMhT: menu row, independent of trigger size.
}

pub fn selectPanelRadius(t: *const ThemeTokens) f32 {
    return t.tokens.radius.panel;
}

pub const select_panel_shadow: core.Shadow = theme.light.tokens.shadow.md;

fn eqlValue(comptime ValueT: type, a: ValueT, b: ValueT) bool {
    return if (ValueT == []const u8) std.mem.eql(u8, a, b) else std.meta.eql(a, b);
}

/// render slot context: slot fn receives fields here, can custom *Node per interaction state.
pub fn TriggerSlotCtx(comptime ValueT: type) type {
    return struct {
        /// label at mount (selected item's label, else placeholder)
        label_text: []const u8,
        has_selection: bool,
        size: SelectSize,
        variant: SelectVariant,
        disabled: bool,
        tokens: *const ThemeTokens,
        width: f32,
        /// current value (can build effect / bind on `scope` to follow with custom trigger)
        value: Source(?ValueT),
        /// custom trigger binding mounted here (component scope)
        scope: *Scope,
    };
}

pub fn ItemSlotCtx(comptime ValueT: type) type {
    return struct {
        option: Option(ValueT),
        index: u32,
        /// current highlight (keyboard / hover position)
        is_highlighted: bool,
        /// currently selected
        is_selected: bool,
        size: SelectSize,
        variant: SelectVariant,
        tokens: *const ThemeTokens,
    };
}

/// SelectHeadless properties
pub fn MountProps(comptime ValueT: type) type {
    return struct {
        /// options (can pass signal / derived: rebuild rows on content or address change, update
        /// vlist row count).
        /// static array shallow-copied; borrowed fields like label must stay valid while options
        /// are current value
        options: Source([]const Option(ValueT)) = .{ .value = &.{} },
        placeholder: []const u8 = "Select...",
        width: f32 = 240,
        max_dropdown_height: f32 = 280,
        /// current value (null = unselected)
        value: Model(?ValueT) = .{ .local = null },
        /// call after user selects and settled (settled value)
        on_change: ?Handler(ValueT) = null,
        open: Model(bool) = .{ .local = false },
        on_open_change: ?Handler(bool) = null,
        disabled: Source(bool) = .{ .value = false },
        /// variant + size used for SelectSlotRecipe resolution
        variant: SelectVariant = .default,
        size: SelectSize = .md,
        /// custom trigger node (mount still manages click toggle). to follow selected value, bind
        /// ctx.value on ctx.scope
        render_trigger: ?*const fn (ctx: TriggerSlotCtx(ValueT), cx: *Cx) anyerror!*Node = null,
        /// custom per-option row (mount still attaches click / hover on returned node). selected /
        /// highlight change
        /// does not rewrite custom row, caller visualizes
        render_item: ?*const fn (ctx: ItemSlotCtx(ValueT), cx: *Cx) anyerror!*Node = null,
        /// enable VirtualList pooling (required for 1k+ options). when enabled row nodes are
        /// pooled,
        /// not one-to-one with options
        virtualize: bool = false,
    };
}

/// create SelectHeadless: `SH.SelectHeadless(i32, .{ .options = &opts, .value = picked })`
pub fn SelectHeadless(comptime ValueT: type, props: anytype) Builder(ValueT) {
    return .{ .props = reactive.props.coerce(MountProps(ValueT), props) };
}

pub fn Builder(comptime ValueT: type) type {
    return struct {
        props: MountProps(ValueT),

        pub fn mount(self: @This(), scope: *Scope, cx: *Cx) !SelectHeadlessResult(ValueT) {
            cx.owner.enterMount();
            defer cx.owner.exitMount();
            return mountImpl(ValueT, self.props, scope, cx);
        }
    };
}

/// mount result
pub fn SelectHeadlessResult(comptime ValueT: type) type {
    return struct {
        /// outer Popover wrapper (caller appends to own mount point)
        wrapper: *Node,
        /// trigger node (click toggle; keyboard / a11y here too)
        trigger: *Node,
        /// default trigger's label node; when custom trigger this is caller's returned node
        trigger_label: *Node,
        /// content panel (portal)
        content: *Node,
        /// current value signal (null when `ui.split`)
        value: ?*Signal(?ValueT),
        /// toggle signal (null when `ui.split`)
        open: ?*Signal(bool),
    };
}

/// get runtime (test / bench use; fields are derived state, do not write)
pub fn stateOf(comptime ValueT: type, r: SelectHeadlessResult(ValueT)) *Runtime(ValueT) {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

/// SelectHeadless runtime (component scope-owned). view = f(value, open, disabled), refreshed by
/// effect;
/// option rows rebuilt per options (non-virt: `ui.rebuildOn`; virt: update row count).
/// click / Enter / Esc only propose; highlight and typeahead are internal interaction state
/// (`nav`).
pub fn Runtime(comptime ValueT: type) type {
    return struct {
        const Self = @This();

        cx: *Cx,
        tokens: *const ThemeTokens,
        size: SelectSize,
        variant: SelectVariant,
        placeholder: []const u8,
        item_h: f32,
        font_size: f32,
        line_height: f32,
        item_text_color: Color,
        trigger_text_color: Color,

        value: reactive.Bound(?ValueT),
        open: reactive.Bound(bool),
        options_src: Source([]const Option(ValueT)),
        disabled: Source(bool),
        on_change: ?Handler(ValueT),
        on_open_change: ?Handler(bool),
        render_item: ?*const fn (ctx: ItemSlotCtx(ValueT), cx: *Cx) anyerror!*Node,

        trigger: *Node,
        /// default trigger's label and chevron (null when custom trigger)
        label: ?*Node,
        chevron: ?*Node,
        frame: ?*Node,
        /// Default trigger's expanded state (the frame shell's :expanded), mirrored from nav.open.
        frame_expanded: ?*Signal(bool) = null,
        content: *Node,

        /// state machine nav state: open / value mirrored from data source via view, highlight /
        /// typeahead owned by it
        nav: SelectState(ValueT) = .{},
        options: []const Option(ValueT) = &.{},
        /// non-virt: one-to-one with options (in rebuild child scope, cleared when rebuild starts)
        item_nodes: []*Node = &.{},
        vl_state: ?*virtual_list_mod.VirtualListState = null,
        /// virt: pooled node click context (per-pool-node reuse, component scope-owned)
        virt_click_ctxs: std.ArrayListUnmanaged(*VirtClick) = .empty,
        shown_disabled: bool = false,

        const VirtClick = struct { rt: *Self, slot_node: *Node };
        const ItemClick = struct { rt: *Self, index: u32 };

        fn selectedIndex(self: *const Self) ?usize {
            const v = self.nav.value orelse return null;
            for (self.options, 0..) |o, i| {
                if (eqlValue(ValueT, o.value, v)) return i;
            }
            return null;
        }

        fn isSelected(self: *const Self, opt: Option(ValueT)) bool {
            const v = self.nav.value orelse return false;
            return eqlValue(ValueT, opt.value, v);
        }

        // ---- view ----

        fn viewEffect(self: *Self) void {
            self.applyView(true);
        }

        fn applyView(self: *Self, comptime tracked: bool) void {
            const v = self.value.readAs(tracked);
            const open = self.open.readAs(tracked);
            const disabled = self.disabled.read(tracked);
            self.nav.value = v;
            if (self.nav.open and !open) self.nav.highlight_index = null;
            self.nav.open = open;
            if (disabled != self.shown_disabled) self.applyDisabled(disabled);
            self.paintTrigger();
            self.paintItems();
        }

        fn applyDisabled(self: *Self, disabled: bool) void {
            self.shown_disabled = disabled;
            self.trigger.setFocusable(!disabled);
            self.trigger.style.cursor = if (disabled) .not_allowed else .pointer;
            if (self.trigger.behavior.interaction.a11y) |*a| a.disabled = disabled;
            // The default trigger's frame follows its shell's :disabled.
            self.trigger.markRenderDirty();
        }

        /// default trigger: label = selected item or placeholder (old implementation never updated
        /// label after select)
        fn paintTrigger(self: *Self) void {
            const label = self.label orelse return;
            const index = self.selectedIndex();
            const content = if (index) |i| self.options[i].label else self.placeholder;
            if (label.getText()) |old| {
                var txt = old;
                txt.content = content;
                txt.owned = false;
                txt.inline_len = 0;
                txt.color = if (self.shown_disabled) self.tokens.tokens.color.fg_disabled else if (index == null) self.tokens.tokens.color.fg_secondary else self.trigger_text_color;
                label.setText(txt);
            }
            if (self.frame_expanded) |expanded| expanded.set(self.nav.open);
            label.markLayoutDirty();
            if (self.chevron) |ch| {
                _ = ch.setTint(if (index == null) self.tokens.tokens.color.fg_tertiary else self.tokens.tokens.color.fg_secondary);
                ch.markRenderDirty();
            }
            if (self.trigger.behavior.interaction.a11y) |*a| {
                a.expanded = self.nav.open;
                a.value_text = if (index) |i| self.options[i].label else null;
            }
        }

        /// highlight / selected visual + aria-activedescendant
        fn paintItems(self: *Self) void {
            defer updateActiveDescendant(self.trigger, self.item_nodes, self.vl_state, self.nav.highlight_index);
            if (self.vl_state) |vl| {
                if (self.nav.highlight_index) |hi| virtual_list_mod.ensureVisible(vl, hi);
                virtual_list_mod.refreshRange(vl, vl.prev_start, vl.prev_end);
                return;
            }
            // custom row visualized by caller
            if (self.render_item != null) return;
            for (self.item_nodes, self.options, 0..) |n, opt, i| {
                const is_highlight = self.nav.highlight_index == @as(u32, @intCast(i));
                const is_selected = self.isSelected(opt);
                const visual = @import("../combo_box/styles.zig").optionStyle(self.tokens, is_selected).resolve(.{ .is_selected = is_selected, .is_hovered = is_highlight, .is_disabled = opt.disabled });
                n.setBackgroundRaw(visual.background.?);
                if (self.render_item == null and n.children.items.len > 0) {
                    const label = n.children.items[0];
                    if (label.getText()) |old| {
                        var text = old;
                        text.color = visual.text_color.?;
                        label.setText(text);
                    }
                }
                // default option second child is selected-state check icon
                if (n.children.items.len > 1) n.children.items[1].setOpacityRaw(if (is_selected) 1 else 0);
                n.markRenderDirty();
            }
        }

        // ---- interaction: propose-only ----

        fn proposeOpen(self: *Self, v: bool) void {
            const on_change = self.on_open_change;
            const landed = self.open.commit(v) orelse return;
            if (on_change) |h| h.call(landed);
        }

        /// commit item at index and close
        fn choose(self: *Self, index: u32) void {
            if (self.shown_disabled) return;
            self.nav.highlight_index = index;
            const picked = sm.commitSelection(ValueT, &self.nav, self.options);
            if (picked) |v| {
                const on_change = self.on_change;
                if (self.value.commit(v)) |landed| {
                    if (landed) |x| if (on_change) |h| h.call(x);
                }
            }
            // commitSelection changed mirror value in nav state; use data source (current value
            // after proposal)
            self.nav.value = self.value.peek();
            self.proposeOpen(false);
            self.paintTrigger();
            self.paintItems();
        }

        fn toggleFromTrigger(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.shown_disabled) return;
            self.proposeOpen(!self.nav.open);
        }

        fn onKey(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
            const self: *Self = @ptrCast(@alignCast(context orelse return .ignored));
            if (self.shown_disabled) return .ignored;
            const action: Action = switch (key) {
                .down => .arrow_down,
                .up => .arrow_up,
                .home => .home_key,
                .end => .end_key,
                .page_up => .page_up,
                .page_down => .page_down,
                .escape => .escape,
                .@"return" => .enter,
                else => return .ignored,
            };
            const was_open = self.nav.open;
            const prev_highlight = self.nav.highlight_index;
            sm.step(ValueT, &self.nav, self.options, action, 0);
            // state machine only for nav state; toggle uses data source, here only propose
            self.nav.open = was_open;
            switch (action) {
                .enter => if (self.nav.highlight_index) |hi| self.choose(hi) else self.proposeOpen(false),
                .escape => {
                    self.proposeOpen(false);
                    // close rejected: panel still open, highlight cleared by state machine must
                    // restore
                    if (self.open.peek()) self.nav.highlight_index = prev_highlight;
                },
                else => if (!was_open) {
                    self.proposeOpen(true);
                    // open rejected: panel still closed, highlight cannot stay on invisible list
                    // (nor write to aria)
                    if (!self.open.peek()) self.nav.highlight_index = prev_highlight;
                },
            }
            self.paintItems();
            return .stop;
        }

        fn itemEvent(event: Event, context: ?*anyopaque) EventResult {
            const ctx: *ItemClick = @ptrCast(@alignCast(context orelse return .ignored));
            switch (event) {
                .click => {
                    ctx.rt.choose(ctx.index);
                    return .stop;
                },
                .mouse_enter => {
                    ctx.rt.nav.highlight_index = ctx.index;
                    ctx.rt.paintItems();
                    return .handled;
                },
                else => return .ignored,
            }
        }

        fn virtItemEvent(event: Event, context: ?*anyopaque) EventResult {
            const cctx: *VirtClick = @ptrCast(@alignCast(context orelse return .ignored));
            const self = cctx.rt;
            const vl = self.vl_state orelse return .ignored;
            // reverse slot -> data index via pool_bindings
            const si = for (vl.pool_nodes, 0..) |pn, i| {
                if (pn == cctx.slot_node) break i;
            } else return .ignored;
            const data_idx = vl.pool_bindings[si] orelse return .ignored;
            switch (event) {
                .click => {
                    self.choose(@intCast(data_idx));
                    return .stop;
                },
                .mouse_enter => {
                    self.nav.highlight_index = @intCast(data_idx);
                    self.paintItems();
                    return .handled;
                },
                else => return .ignored,
            }
        }

        // ---- options (non-virt: ui.rebuildOn) ----

        fn optionsKey(opts: []const Option(ValueT)) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&opts.ptr));
            h.update(std.mem.asBytes(&opts.len));
            for (opts) |*o| {
                h.update(std.mem.asBytes(o));
                h.update(o.label);
                if (ValueT == []const u8) h.update(o.value);
            }
            return h.final();
        }

        const Parts = struct {
            nodes: []*Node = &.{},
            clicks: []ItemClick = &.{},

            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const p: *Parts = @ptrCast(@alignCast(ptr));
                alloc.free(p.nodes);
                alloc.free(p.clicks);
                alloc.destroy(p);
            }
        };

        fn buildItems(self: *Self, child: *Scope, container: *Node, opts: []const Option(ValueT)) !void {
            // stop runtime from referencing old nodes / array
            self.options = &.{};
            self.item_nodes = &.{};
            self.nav.highlight_index = null;
            const cx = self.cx;
            const a = child.allocator;
            const parts = try a.create(Parts);
            parts.* = .{};
            try child.adoptResource(@ptrCast(parts), Parts.destroy);
            parts.nodes = try a.alloc(*Node, opts.len);
            parts.clicks = try a.alloc(ItemClick, opts.len);
            const t = self.tokens;
            const check_px: core.Sizing = .{ .px = 16 };
            for (opts, 0..) |opt, i| {
                var item: *Node = undefined;
                if (self.render_item) |render_item_fn| {
                    item = try render_item_fn(.{
                        .option = opt,
                        .index = @intCast(i),
                        .is_highlighted = false,
                        .is_selected = false,
                        .size = self.size,
                        .variant = self.variant,
                        .tokens = t,
                    }, cx);
                    // caller-built *Node adopted via adoptChild (fail -> freeNode): view.mount
                    // takes *Node,
                    // rollback is clearNodeScopes + destroyDetached, release semantics differ from
                    // adoptChild's
                    _ = try core.adoptChild(cx, cx.allocator, container, item);
                } else {
                    // row = label (fills row width, push check to end) + selected-state check
                    // (initially transparent).
                    // row scope bound to row node (view.append), free row frees its scope
                    item = try view.append(child, cx, container, view.box(.{ .style = core.BoxStyle{
                        .direction = .row,
                        .width = .{ .grow = .{} },
                        .height = .{ .px = self.item_h },
                        .padding = core.Padding.symmetric(0, 8),
                        .justify = .space_between,
                        .align_items = .center,
                        .overflow_hidden = true,
                        .corner_radius = t.tokens.radius.md,
                    } }, .{
                        view.attrs(.{ .style = core.BoxStyle{ .width = .{ .grow = .{} } } }, view.text(.{ .style = core.TextStyle{
                            .color = if (opt.disabled) t.tokens.color.fg_disabled else self.item_text_color,
                            .font_size = self.font_size,
                            .line_height = 1.2,
                        } }, opt.label)),
                        view.icon(.{ .style = .{ .width = check_px, .height = check_px, .opacity = 0 }, .tint = t.tokens.color.selection_fg }, icons.check),
                    }));
                }
                parts.nodes[i] = item;
                parts.clicks[i] = .{ .rt = self, .index = @intCast(i) };
                item.behavior.events.event_context = @ptrCast(&parts.clicks[i]);
                item.behavior.events.on_event = itemEvent;
            }
            self.options = opts;
            self.item_nodes = parts.nodes;
            self.applyView(false);
        }

        // ---- options (virt: update row count only) ----

        fn virtOptionsEffect(self: *Self) void {
            const opts = self.options_src.read(true);
            self.options = opts;
            self.nav.highlight_index = null;
            if (self.vl_state) |vl| virtual_list_mod.updateItemCount(vl, opts.len);
            // selected item label from options
            self.paintTrigger();
        }

        /// VirtualList row render callback: fill row content on pool node and attach click
        fn virtRender(node: *Node, index: usize, cx: *Cx, user_ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_ctx orelse return));
            if (index >= self.options.len) return;
            const opt = self.options[index];
            const t = self.tokens;
            const is_highlighted = if (self.nav.highlight_index) |hi| hi == index else false;
            const is_selected = self.isSelected(opt);

            node.style.direction = .row;
            node.style.padding = core.Padding.symmetric(0, 8);
            node.style.justify = .space_between;
            node.style.align_items = .center;
            node.style.overflow_hidden = true;
            // write background before any fallible step: pool node reused, early return on fail
            // cannot leave previous row background
            node.setBackgroundRaw(@import("../combo_box/styles.zig").optionStyle(t, is_selected).resolve(.{ .is_selected = is_selected, .is_hovered = is_highlighted, .is_disabled = opt.disabled }).background.?);
            (node.style.ensureExtFallible(cx.allocator) catch return bail(node)).corner_radius = .{ .all = t.tokens.radius.md };

            if (self.render_item) |render_item_fn| {
                const child = render_item_fn(.{
                    .option = opt,
                    .index = @intCast(index),
                    .is_highlighted = is_highlighted,
                    .is_selected = is_selected,
                    .size = self.size,
                    .variant = self.variant,
                    .tokens = t,
                }, cx) catch return bail(node);
                _ = core.adoptChild(cx, cx.allocator, node, child) catch return bail(node);
            } else {
                const label = core.adoptChild(cx, cx.allocator, node, core.box(cx, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                }, .{}) catch return bail(node)) catch return bail(node);
                label.setText(.{
                    .content = opt.label,
                    .color = @import("../combo_box/styles.zig").optionStyle(t, is_selected).resolve(.{ .is_selected = is_selected, .is_hovered = is_highlighted, .is_disabled = opt.disabled }).text_color.?,
                    .font_size = self.font_size,
                    .line_height = 1.2,
                });
                const check_icon = core.adoptChild(cx, cx.allocator, node, core.iconTint(cx, icons.check, t.tokens.color.selection_fg, .{
                    .width = .{ .px = 16 },
                    .height = .{ .px = 16 },
                }) catch return bail(node)) catch return bail(node);
                check_icon.setOpacityRaw(if (is_selected) 1 else 0);
            }

            // pool node click context: allocated first time this pool node seen, then reused
            if (node.behavior.events.event_context == null) {
                const a = self.cx.allocator;
                const click_ctx = a.create(VirtClick) catch return bail(node);
                click_ctx.* = .{ .rt = self, .slot_node = node };
                self.virt_click_ctxs.append(a, click_ctx) catch {
                    a.destroy(click_ctx);
                    return bail(node);
                };
                node.behavior.events.event_context = @ptrCast(click_ctx);
                node.behavior.events.on_event = virtItemEvent;
            }
        }

        /// callback is void, fail only return, but leave trace with VL so it retakes slot and
        /// retries next frame
        fn bail(node: *Node) void {
            _ = virtual_list_mod.markPoolNodeRenderIncomplete(node);
        }

        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            for (self.virt_click_ctxs.items) |c| self.cx.allocator.destroy(c);
            self.virt_click_ctxs.deinit(self.cx.allocator);
            alloc.destroy(self);
        }
    };
}

/// write element_id of item at current highlight_index to
/// trigger.a11y.active_descendant_element_id.
/// - non-virt path: directly read item_nodes[highlight_idx].element_id_raw
/// - virt path: scan pool_bindings for matching slot; if highlight outside visible range set
///   active_descendant NULL
/// - highlight_index == null (closed / Esc reset) -> set NULL
fn updateActiveDescendant(
    trigger: *Node,
    item_nodes: []*Node,
    vl_state: ?*virtual_list_mod.VirtualListState,
    highlight_index: ?u32,
) void {
    const new_raw: u32 = blk: {
        const hi = highlight_index orelse break :blk 0xFFFFFFFF;
        if (vl_state) |vl| {
            for (vl.pool_bindings, 0..) |b, slot| {
                if (b) |bound| {
                    if (bound == hi) break :blk vl.pool_nodes[slot].element_id_raw;
                }
            }
            break :blk 0xFFFFFFFF;
        }
        if (hi >= item_nodes.len) break :blk 0xFFFFFFFF;
        break :blk item_nodes[hi].element_id_raw;
    };
    if (trigger.behavior.interaction.a11y) |*a11y| {
        if (a11y.active_descendant_element_id == new_raw) return;
        a11y.active_descendant_element_id = new_raw;
    } else {
        trigger.behavior.interaction.a11y = .{ .active_descendant_element_id = new_raw };
    }
    trigger.markRenderDirty();
}

fn OwnedOptions(comptime ValueT: type) type {
    return struct {
        items: []Option(ValueT) = &.{},

        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const h: *@This() = @ptrCast(@alignCast(ptr));
            alloc.free(h.items);
            alloc.destroy(h);
        }
    };
}

fn mountImpl(comptime ValueT: type, props: MountProps(ValueT), scope: *Scope, cx: *Cx) !SelectHeadlessResult(ValueT) {
    const RT = Runtime(ValueT);
    const my_scope = try scope.childScope();
    // on failure dispose my_scope (hooks / resources destroyed during node lifetime) then free
    // wrapper
    var wrapper_node: ?*Node = null;
    errdefer {
        my_scope.dispose();
        if (wrapper_node) |w| cx.freeNode(w);
    }
    const allocator = cx.allocator;
    const t = cx.tokens;
    reactive.checkBorrow(my_scope, props.options);
    reactive.checkBorrow(my_scope, props.disabled);

    // resolve recipe, get ConditionalStyle for three slots
    const slots = SelectSlotRecipe.resolve(.{ .variant = props.variant, .size = props.size }, t);
    const cm = @import("../input/styles.zig").fieldMetrics(t, props.size);
    const disabled0 = props.disabled.peek();

    const value = try reactive.resolveModel(?ValueT, my_scope, props.value);
    const open = try reactive.resolveModel(bool, my_scope, props.open);
    // Popover and component share same toggle data source: Esc / click outside proposed by Popover,
    // click trigger / select by component
    const pop_open: Model(bool) = open.toModel();

    // static options shallow-copied into scope: runtime reads them in click / view
    var options = props.options;
    if (props.options == .value) {
        const Owned = OwnedOptions(ValueT);
        const holder = try my_scope.allocator.create(Owned);
        holder.* = .{};
        try my_scope.adoptResource(@ptrCast(holder), Owned.destroy);
        holder.items = try my_scope.allocator.dupe(Option(ValueT), props.options.value);
        options = .{ .value = holder.items };
    }

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
    pop.wrapper.meta.ownership.meta.component_name = "SelectHeadless";

    const rt = try my_scope.allocator.create(RT);
    rt.* = .{
        .cx = cx,
        .tokens = t,
        .size = props.size,
        .variant = props.variant,
        .placeholder = props.placeholder,
        .item_h = itemHeight(props.size),
        .font_size = t.tokens.font_size.md,
        .line_height = cm.line_height,
        .item_text_color = slots.item.resolve(.{}).text_color orelse t.tokens.color.fg_primary,
        .trigger_text_color = slots.trigger.resolve(.{}).text_color orelse t.tokens.color.fg_primary,
        .value = value,
        .open = open,
        .options_src = options,
        .disabled = props.disabled,
        .on_change = props.on_change,
        .on_open_change = props.on_open_change,
        .render_item = props.render_item,
        .trigger = pop.trigger,
        .label = null,
        .chevron = null,
        .frame = null,
        .content = pop.content,
    };
    try my_scope.adoptResource(@ptrCast(rt), RT.destroy);
    pop.wrapper.addDebugState(@ptrCast(rt));

    // ── Trigger ───────────────────────────────────────────────────
    var trigger_label: *Node = undefined;
    if (props.render_trigger) |render_trigger_fn| {
        const initial_label = blk: {
            const v = value.peek() orelse break :blk props.placeholder;
            for (options.peek()) |opt| {
                if (eqlValue(ValueT, opt.value, v)) break :blk opt.label;
            }
            break :blk props.placeholder;
        };
        // custom trigger as child of pop.trigger (click toggle on pop.trigger)
        trigger_label = try render_trigger_fn(.{
            .label_text = initial_label,
            .has_selection = value.peek() != null,
            .size = props.size,
            .variant = props.variant,
            .disabled = disabled0,
            .tokens = t,
            .width = props.width,
            .value = value.read,
            .scope = my_scope,
        }, cx);
        // caller-built *Node adopted via adoptChild (reason same as buildItems' render_item)
        _ = try core.adoptChild(cx, allocator, pop.trigger, trigger_label);
    } else {
        // default trigger: same ControlShell(.field) as Input / Select / DatePicker.
        // content_slot = label (grow, can shrink), append_slot = chevron; no leading icon (no icon
        // slot).
        // geometry from recipe, frame height = padding_y * 2 + line height. color from this
        // component's recipe trigger slot.
        pop.trigger.style.width = .{ .px = props.width };
        pop.trigger.style.height = .{ .fit = .{} };
        const chevron_px: core.Sizing = .{ .px = cm.icon_size };
        // The frame is a ControlShell(.field): hover / expanded / disabled colors and cursor are its
        // declarative states; geometry and the RYMhT xs shadow stack on it as an overlay.
        const expanded = try my_scope.createSignal(bool, false);
        rt.frame_expanded = expanded;
        var shell: core.ViewParts = undefined;
        var label_node: *Node = undefined;
        try view.mount(my_scope, cx, pop.trigger, view.attrs(.{ .style = core.BoxStyle{
            .width = .{ .grow = .{} },
            .align_self = .stretch,
            .padding = core.Padding.symmetric(cm.padding_y, cm.padding_h),
            .corner_radius = cm.radius,
            .shadow = t.tokens.shadow.xs,
        } }, view.with(control_shell.ControlShell(.{
            .variant = .field,
            .size = props.size,
            .disabled = props.disabled,
            .expanded = expanded,
            .cursor = .pointer,
            .append_style = core.BoxStyle{ .min_height = cm.lineHeightPx() },
            .content_style = core.BoxStyle{
                .min_height = cm.lineHeightPx(),
                .width = .{ .grow = .{ .min = 0 } },
                .flex_shrink = 1,
                .overflow_hidden = true,
            },
        }), .{}).capture(&shell).slots(.{
            // text and color follow the selected item (paintTrigger)
            .content = view.capture(&label_node, view.text(.{ .style = core.TextStyle{
                .color = t.tokens.color.fg_disabled,
                .font_size = cm.font_size,
                .line_height = cm.line_height,
            } }, props.placeholder)),
            .append = view.capture(&rt.chevron, view.icon(.{
                .style = .{ .width = chevron_px, .height = chevron_px },
                .tint = t.tokens.color.fg_tertiary,
            }, icons.chevron_down)),
        })));
        rt.frame = shell.root.?;
        trigger_label = label_node;
        rt.label = trigger_label;
    }

    // trigger: click toggle, keyboard, a11y (combobox + has_popup=listbox + initially no
    // active_descendant)
    pop.trigger.behavior.events.on_click = core.Cx.simpleHandler(RT.toggleFromTrigger, rt);
    pop.trigger.behavior.events.key_context = @ptrCast(rt);
    pop.trigger.behavior.events.on_key_down = RT.onKey;
    pop.trigger.setFocusable(true);
    pop.trigger.behavior.interaction.a11y = .{
        .role = .combobox,
        .has_popup = .listbox,
        .disabled = false,
        .active_descendant_element_id = 0xFFFFFFFF,
    };
    rt.applyDisabled(disabled0);
    try @import("../../hooks.zig").useFocusRing(my_scope, cx, pop.trigger, .{ .width = t.tokens.border_width.focus, .offset = t.tokens.size.focus_offset, .color = t.tokens.color.focus_ring });

    // ── Content panel ───────────────────────────────────────────
    const content_resolved = slots.content.resolve(.{});
    pop.content.style.direction = .column;
    pop.content.style.gap = 0;
    pop.content.style.padding = core.Padding.all(4);
    pop.content.setBackgroundRaw(content_resolved.background orelse t.tokens.color.bg_primary);
    const panel_radius = selectPanelRadius(t);
    pop.content.style.border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = panel_radius };
    const content_ext = try pop.content.style.ensureExtFallible(allocator);
    content_ext.corner_radius = .{ .all = panel_radius };
    content_ext.setShadow(t.tokens.shadow.md);
    content_ext.hit_shape = .{ .rounded_rect = panel_radius };
    content_ext.clip_shape = .{ .rounded_rect = panel_radius };
    // keyboard works on panel too
    pop.content.behavior.events.key_context = @ptrCast(rt);
    pop.content.behavior.events.on_key_down = RT.onKey;

    // content (portal) rebuild and view effect both in Popover's scope
    if (props.virtualize) {
        rt.options = options.peek();
        const vl_result = try virtual_list_mod.VirtualList(.{
            .item_count = rt.options.len,
            .item_height = rt.item_h,
            .width = props.width,
            .height = props.max_dropdown_height,
            .overscan = 5,
        }).mountWithContext(pop.scope, cx, @ptrCast(rt), null, RT.virtRender);
        // VirtualList's mountWithContext (pool row callback) not builder, container adopts via
        // adoptChild:
        // fail does freeNode (disposes VL scope bound to container), view.mount rollback only
        // clearNodeScopes + destroyDetached,
        // leaks VL scope (failed-alloc scan tested)
        _ = try core.adoptChild(cx, allocator, pop.content, vl_result.container);
        rt.vl_state = vl_result.state;
        if (!options.isStatic()) try pop.scope.createEffect(rt, RT.virtOptionsEffect);
        rt.applyView(false);
    } else {
        try bind_mod.rebuildOn(cx, pop.scope, options, pop.content, rt, RT.optionsKey, RT.buildItems);
    }
    try pop.scope.createEffect(rt, RT.viewEffect);

    return .{
        .wrapper = pop.wrapper,
        .trigger = pop.trigger,
        .trigger_label = trigger_label,
        .content = pop.content,
        .value = value.asSignal(),
        .open = open.asSignal(),
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestEnv = struct {
    cx: *Cx,
    scope: *Scope,
    root: *Node,

    fn init() !TestEnv {
        const cx = try Cx.init(testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(600, 400);
        const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
        cx.root = root;
        const scope = try Scope.init(testing.allocator, null, cx.owner);
        return .{ .cx = cx, .scope = scope, .root = root };
    }

    fn deinit(self: TestEnv) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn mount(self: TestEnv, props: anytype) !SelectHeadlessResult(i32) {
        const r = try SelectHeadless(i32, props).mount(self.scope, self.cx);
        try self.root.appendChild(testing.allocator, r.wrapper);
        return r;
    }
};

const abc = [_]Option(i32){
    .{ .value = 1, .label = "Apple" },
    .{ .value = 2, .label = "Banana" },
    .{ .value = 3, .label = "Cherry" },
};

fn labelOf(r: SelectHeadlessResult(i32)) []const u8 {
    return r.trigger_label.getText().?.content;
}

fn click(n: *Node) void {
    _ = n.behavior.events.on_event.?(.{ .click = .{ .x = 0, .y = 0 } }, n.behavior.events.event_context);
}

test "MountProps default" {
    const p = MountProps(i32){};
    try testing.expectEqualStrings("Select...", p.placeholder);
    try testing.expect(p.options.peek().len == 0);
}

test "SelectHeadless: Pvnqs trigger panel and option geometry" {
    const env = try TestEnv.init();
    defer env.deinit();
    const options = [_]Option(i32){
        .{ .value = 1, .label = "Option 1" },
        .{ .value = 2, .label = "Option 2" },
    };
    const mounted = try env.mount(.{ .options = &options, .value = @as(?i32, 2), .size = .md });
    const rt = stateOf(i32, mounted);

    // frame = pop.trigger's ControlShell node below; height fit by padding_y*2 + line height.
    env.cx.layout();
    // RYMhT: field 32px, popup row 28px / radius 4 / inset 4.
    const cm = @import("../input/styles.zig").fieldMetrics(env.cx.tokens, .md);
    try testing.expectEqual(@as(usize, 1), mounted.trigger.children.items.len);
    const frame = mounted.trigger.children.items[0];
    try testing.expectApproxEqAbs(@as(f32, 32), frame.rectFromWorldOrFallback().h, 0.01);
    try testing.expectEqual(cm.padding_y, frame.style.padding.top);
    try testing.expectEqual(cm.padding_h, frame.style.padding.left);
    try testing.expectEqual(cm.radius, frame.style.effectiveRadius());
    try testing.expectEqual(@as(usize, 2), frame.children.items.len); // content_slot + append_slot

    try testing.expectEqual(@as(f32, 0), mounted.content.style.gap);
    try testing.expectEqual(@as(f32, 4), mounted.content.style.padding.top);
    try testing.expectEqual(@as(f32, 10), mounted.content.style.border.radius);
    try testing.expectEqual(@as(usize, 1), mounted.content.style.shadowSlice().len);
    try testing.expectEqual(env.cx.tokens.tokens.shadow.md.blur, mounted.content.style.shadowSlice()[0].blur);

    for (rt.item_nodes) |item| {
        try testing.expectEqual(@as(f32, 28), item.style.height.px);
        try testing.expectEqual(@as(f32, 0), item.style.padding.top);
        try testing.expectEqual(@as(f32, 8), item.style.padding.left);
        try testing.expectEqual(@as(f32, 4), item.style.corner_radius().?.resolve());
        try testing.expectEqual(@as(usize, 2), item.children.items.len);
    }
    try testing.expectEqual(@as(f32, 0), rt.item_nodes[0].children.items[1].getOpacity());
    try testing.expectEqual(@as(f32, 1), rt.item_nodes[1].children.items[1].getOpacity());
    try testing.expect(rt.item_nodes[1].getBackground().eql(env.cx.tokens.tokens.color.list_selection_bg));
    try testing.expectEqualStrings("Option 2", labelOf(mounted));
}

test "SelectHeadless: 点选提议值并关闭；默认 trigger 的标签跟着变（旧实现从不更新）" {
    const env = try TestEnv.init();
    defer env.deinit();
    const Spy = struct {
        n: usize = 0,
        last: i32 = 0,
        fn f(self: *@This(), v: i32) void {
            self.n += 1;
            self.last = v;
        }
    };
    var spy = Spy{};
    const r = try env.mount(.{ .options = &abc, .placeholder = "Pick", .on_change = env.cx.on(Spy, &spy, Spy.f) });
    const rt = stateOf(i32, r);
    try testing.expectEqualStrings("Pick", labelOf(r));
    RT_toggle(rt);
    try testing.expect(r.open.?.peek());
    click(rt.item_nodes[2]);
    try testing.expectEqual(@as(?i32, 3), r.value.?.peek());
    try testing.expectEqualStrings("Cherry", labelOf(r));
    try testing.expect(!r.open.?.peek());
    try testing.expectEqual(@as(usize, 1), spy.n);
    try testing.expectEqual(@as(i32, 3), spy.last);
    // external write
    r.value.?.set(1);
    try testing.expectEqualStrings("Apple", labelOf(r));
    try testing.expectEqual(@as(f32, 1), rt.item_nodes[0].children.items[1].getOpacity());
    try testing.expectEqual(@as(usize, 1), spy.n);
}

fn RT_toggle(rt: *Runtime(i32)) void {
    Runtime(i32).toggleFromTrigger(@ptrCast(rt));
}

test "SelectHeadless: 键盘 —— 方向键打开并移动高亮，Enter 提交，Esc 关闭；ui.split 拒绝时不动" {
    const env = try TestEnv.init();
    defer env.deinit();
    const Parent = struct {
        v: *Signal(?i32),
        allow: bool = false,
        fn write(self: *@This(), x: ?i32) void {
            if (self.allow) self.v.set(x);
        }
    };
    var parent = Parent{ .v = try env.scope.createSignal(?i32, null) };
    const r = try env.mount(.{ .options = &abc, .value = reactive.split(parent.v, env.cx.on(Parent, &parent, Parent.write)) });
    const rt = stateOf(i32, r);
    try testing.expect(r.value == null);
    _ = Runtime(i32).onKey(.down, .{}, @ptrCast(rt));
    try testing.expect(r.open.?.peek());
    _ = Runtime(i32).onKey(.down, .{}, @ptrCast(rt));
    try testing.expectEqual(@as(?u32, 1), rt.nav.highlight_index);
    try testing.expectEqual(rt.item_nodes[1].element_id_raw, r.trigger.behavior.interaction.a11y.?.active_descendant_element_id);
    _ = Runtime(i32).onKey(.@"return", .{}, @ptrCast(rt)); // rejected
    try testing.expect(parent.v.peek() == null);
    try testing.expect(!r.open.?.peek());
    try testing.expectEqualStrings("Select...", labelOf(r));
    parent.allow = true;
    _ = Runtime(i32).onKey(.down, .{}, @ptrCast(rt));
    _ = Runtime(i32).onKey(.@"return", .{}, @ptrCast(rt));
    try testing.expectEqual(@as(?i32, 1), parent.v.peek());
    try testing.expectEqualStrings("Apple", labelOf(r));
    _ = Runtime(i32).onKey(.down, .{}, @ptrCast(rt));
    _ = Runtime(i32).onKey(.escape, .{}, @ptrCast(rt));
    try testing.expect(!r.open.?.peek());
    try testing.expect(rt.nav.highlight_index == null);
}

test "SelectHeadless: 关闭时按方向键而打开被拒，高亮与 aria-activedescendant 不变" {
    const env = try TestEnv.init();
    defer env.deinit();
    const Parent = struct {
        o: *Signal(bool),
        fn write(_: *@This(), _: bool) void {}
    };
    var parent = Parent{ .o = try env.scope.createSignal(bool, false) };
    const r = try env.mount(.{ .options = &abc, .open = reactive.split(parent.o, env.cx.on(Parent, &parent, Parent.write)) });
    const rt = stateOf(i32, r);
    _ = Runtime(i32).onKey(.down, .{}, @ptrCast(rt));
    try testing.expect(rt.nav.highlight_index == null);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), r.trigger.behavior.interaction.a11y.?.active_descendant_element_id);
}

test "SelectHeadless: 值与开关都被父组件拒绝时，镜像值与标签保持数据源的值" {
    const env = try TestEnv.init();
    defer env.deinit();
    const Parent = struct {
        v: *Signal(?i32),
        o: *Signal(bool),
        fn writeV(_: *@This(), _: ?i32) void {}
        fn writeO(_: *@This(), _: bool) void {}
    };
    var parent = Parent{ .v = try env.scope.createSignal(?i32, null), .o = try env.scope.createSignal(bool, true) };
    const r = try env.mount(.{
        .options = &abc,
        .value = reactive.split(parent.v, env.cx.on(Parent, &parent, Parent.writeV)),
        .open = reactive.split(parent.o, env.cx.on(Parent, &parent, Parent.writeO)),
    });
    const rt = stateOf(i32, r);
    rt.choose(1);
    try testing.expect(rt.nav.value == null);
    try testing.expectEqualStrings("Select...", labelOf(r));
    try testing.expectEqual(@as(f32, 0), rt.item_nodes[1].children.items[1].getOpacity());
}

test "SelectHeadless: 点选后本次重画就用新值（不等 effect）" {
    const env = try TestEnv.init();
    defer env.deinit();
    const r = try env.mount(.{ .options = &abc });
    const rt = stateOf(i32, r);
    // click select in batch: effect deferred until batch end, check here is state painted by choose
    // itself
    env.cx.owner.beginBatch();
    rt.choose(1);
    try testing.expectEqual(@as(?i32, 2), rt.nav.value);
    try testing.expectEqual(@as(f32, 1), rt.item_nodes[1].children.items[1].getOpacity());
    try testing.expectEqualStrings("Banana", labelOf(r));
    env.cx.owner.endBatch();
}

test "SelectHeadless: options 来自 signal —— 换选项重建行，标签按新选项重算" {
    const env = try TestEnv.init();
    defer env.deinit();
    const opts = try env.scope.createSignal([]const Option(i32), abc[0..2]);
    const r = try env.mount(.{ .options = opts, .value = @as(?i32, 3) });
    const rt = stateOf(i32, r);
    try testing.expectEqual(@as(usize, 2), rt.item_nodes.len);
    try testing.expectEqualStrings("Select...", labelOf(r)); // 3 not in options: not display, not write back
    opts.set(&abc);
    try testing.expectEqual(@as(usize, 3), rt.item_nodes.len);
    try testing.expectEqual(@as(usize, 3), r.content.children.items.len);
    try testing.expectEqualStrings("Cherry", labelOf(r));
    try testing.expectEqual(@as(?i32, 3), r.value.?.peek());
}

test "SelectHeadless(virtualize): options signal 更新行数，点池节点提议对应数据行" {
    const env = try TestEnv.init();
    defer env.deinit();
    var many: [200]Option(i32) = undefined;
    for (&many, 0..) |*o, i| o.* = .{ .value = @intCast(i), .label = "x" };
    const opts = try env.scope.createSignal([]const Option(i32), many[0..100]);
    const r = try env.mount(.{ .options = opts, .virtualize = true, .max_dropdown_height = 200 });
    const rt = stateOf(i32, r);
    const vl = rt.vl_state.?;
    try testing.expectEqual(@as(usize, 100), vl.item_count);
    opts.set(&many);
    try testing.expectEqual(@as(usize, 200), vl.item_count);
    r.open.?.set(true);
    env.cx.layout();
    _ = env.cx.render();
    vl.updateVisibleItems();
    const slot = for (vl.pool_bindings, 0..) |b, i| {
        if (b != null and b.? == 2) break i;
    } else return error.RowNotBound;
    click(vl.pool_nodes[slot]);
    try testing.expectEqual(@as(?i32, 2), r.value.?.peek());
    try testing.expect(!r.open.?.peek());
}

test "SelectHeadless: disabled 来自 signal —— 禁用时点击 / 按键无效" {
    const env = try TestEnv.init();
    defer env.deinit();
    const d = try env.scope.createSignal(bool, true);
    const r = try env.mount(.{ .options = &abc, .disabled = d });
    const rt = stateOf(i32, r);
    RT_toggle(rt);
    try testing.expect(!r.open.?.peek());
    try testing.expectEqual(EventResult.ignored, Runtime(i32).onKey(.down, .{}, @ptrCast(rt)));
    try testing.expect(r.trigger.behavior.interaction.a11y.?.disabled);
    d.set(false);
    try testing.expect(!r.trigger.behavior.interaction.a11y.?.disabled);
    RT_toggle(rt);
    try testing.expect(r.open.?.peek());
}

test "SelectHeadless: render_trigger 拿到 value Source 与 scope，可让自定义 trigger 跟随选中值" {
    const env = try TestEnv.init();
    defer env.deinit();
    const Custom = struct {
        fn render(ctx: TriggerSlotCtx(i32), c: *Cx) anyerror!*Node {
            const n = try core.text(c, ctx.label_text, .{});
            try bind_mod.bindText(c, ctx.scope, reactive.map(ctx.value.signal, struct {
                fn f(v: ?i32) []const u8 {
                    return if (v) |x| (if (x == 2) "two" else "other") else "none";
                }
            }.f), n);
            return n;
        }
    };
    const v = try env.scope.createSignal(?i32, null);
    const r = try env.mount(.{ .options = &abc, .value = v, .render_trigger = Custom.render });
    try testing.expectEqualStrings("none", labelOf(r));
    v.set(2);
    try testing.expectEqualStrings("two", labelOf(r));
}

// per-allocation-point OOM sweep, see src/ui/components/oom_sweep.zig
const sweep_options = [_]Option(i32){ .{ .value = 1, .label = "Option 1" }, .{ .value = 2, .label = "Option 2" } };
test "select_headless: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select_headless", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try SelectHeadless(i32, .{ .options = &sweep_options, .value = @as(?i32, 2), .size = .md }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "select_headless(virtualize, dynamic): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select_headless(virtualize)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const opts = try scope.createSignal([]const Option(i32), &sweep_options);
            const d = try scope.createSignal(bool, false);
            return (try SelectHeadless(i32, .{ .options = opts, .value = @as(?i32, 2), .virtualize = true, .disabled = d }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "SelectHeadless(virtualize): VL 回调中途 OOM 后留痕重试，下一趟整行画全" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const a = failing.allocator();
    var cx = try Cx.init(a, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const mounted = try SelectHeadless(i32, .{ .options = &sweep_options, .virtualize = true }).mount(scope, cx);
    try root.appendChild(a, mounted.wrapper);
    const vl = stateOf(i32, mounted).vl_state.?;
    // repaint index 0, let first alloc in callback (label box) fail: callback traces via
    // markPoolNodeRenderIncomplete,
    // that slot unbound
    failing.fail_index = failing.alloc_index;
    virtual_list_mod.refreshRange(vl, 0, 1);
    failing.fail_index = std.math.maxInt(usize);
    try testing.expect(failing.has_induced_failure);
    try testing.expect(vl.rebind_incomplete);
    for (vl.pool_bindings) |b| try testing.expect(b != 0);
    // next pass: retake slot, callback succeeds -> label + check two children
    vl.updateVisibleItems();
    try testing.expect(!vl.rebind_incomplete);
    var found = false;
    for (vl.pool_bindings, 0..) |b, slot| {
        if (b == 0) {
            found = true;
            try testing.expectEqual(@as(usize, 2), vl.pool_nodes[slot].children.items.len);
        }
    }
    try testing.expect(found);
}
