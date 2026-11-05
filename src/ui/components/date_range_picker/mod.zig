/// DateRangePicker component: date range picker based on Popover + dual month panels.
///
/// Signal-first: `value: Model(?DateRange)`. The first click yields a 'start-only' draft
/// (component-internal visual state, not in the data source); the second click completes the
/// range and proposes it, so on_change and the parent only see complete ranges. Opening resets
/// the draft and visible month to the data source value.
const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.date_range_picker);
const core = @import("../../core.zig");
const control_shell = @import("../control_shell/mod.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Shadow = core.Shadow;
const Padding = core.Padding;
const theme = core.theme;
const Event = core.Event;
const EventResult = core.EventResult;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Model = reactive.Model;
const Source = reactive.Source;
const Handler = core.Handler;
const hooks = @import("../../hooks.zig");
const popover_mod = @import("../popover/mod.zig");
const Popover = popover_mod.Popover;
const Button = @import("../button/mod.zig").Button;
const calendar_mod = @import("../calendar/mod.zig");
const SimpleDate = calendar_mod.SimpleDate;
const svg_assets = @import("../../svg_assets.zig");
const styles = @import("styles.zig");
/// Trigger look is shared with DatePicker (one definition).
const trigger_styles = @import("../date_picker/styles.zig");
const view = @import("../../view.zig");

/// closed interval [start, end], start <= end
pub const DateRange = struct {
    start: SimpleDate,
    end: SimpleDate,
};

pub const DateRangePickerProps = struct {
    placeholder_start: []const u8 = "Start date",
    placeholder_end: []const u8 = "End date",
    /// selected range: `?DateRange` uncontrolled initial; `*Signal(?DateRange)` controlled
    /// (interaction writes directly); `ui.split` intercepts
    value: Model(?DateRange) = .{ .local = null },
    /// Opt into an Apply/Cancel footer; default retains immediate commit.
    confirm_selection: bool = false,
    width: f32 = 320,
    /// control size (same ControlSize as Button / Input / Select, default md)
    size: control_shell.ControlSize = .md,
    /// disabled (can pass signal): click trigger does not toggle when disabled
    disabled: Source(bool) = .{ .value = false },
    /// popover toggle
    open: Model(bool) = .{ .local = false },
    on_open_change: ?Handler(bool) = null,
    /// Validation state; error border takes precedence over open/focus.
    invalid: Source(bool) = .{ .value = false },
    /// call after user selects complete range and settled (settled value)
    on_change: ?Handler(DateRange) = null,
    calendar_icon_asset: ?svg_assets.Asset = null,
    prev_icon_asset: ?svg_assets.Asset = null,
    next_icon_asset: ?svg_assets.Asset = null,
    test_id: ?[]const u8 = null,
};

pub const DateRangePickerState = struct {
    value: reactive.Bound(?DateRange),
    /// data source value applied to view (effect checks if data source changed)
    applied: ?DateRange = null,
    confirm_selection: bool = false,
    apply_disabled: ?*reactive.Signal(bool) = null,
    footer_summary: ?*Node = null,
    footer_buf: [80]u8 = undefined,
    /// current displayed range: data source value, or draft in progress (start-only)
    start_date: ?SimpleDate,
    end_date: ?SimpleDate,
    preview_end_date: ?SimpleDate,
    panel_node: *Node,
    start_display: *Node,
    dash_display: *Node,
    end_display: *Node,
    trigger_node: *Node,
    leading_icon_node: *Node,
    chevron_node: *Node,
    left_title: *Node,
    left_grid: *Node,
    right_title: *Node,
    right_grid: *Node,
    view_year: u16,
    view_month: u8,
    today_date: ?SimpleDate,
    /// data source for popover toggle (shared with Popover)
    open: Source(bool),
    /// request close / toggle: goes through Popover's toggle proposal pipeline
    close: Handler(void),
    toggle: Handler(void),
    disabled: Source(bool),
    invalid: Source(bool) = .{ .value = false },
    shown_open: bool = false,
    shown_disabled: bool = false,
    /// Trigger look the frame and icon tints follow (styleBy / tintBy); syncTriggerVisual writes it.
    trigger_look: *Signal(trigger_styles.TriggerLook),
    on_change: ?Handler(DateRange),
    placeholder_start: []const u8,
    placeholder_end: []const u8,
    cx: *Cx,
    scope: *Scope,
    day_cell_refs: std.ArrayListUnmanaged(DayCellRefs),
    /// a11y: trigger value_text ("Mar 10, 2026 – Mar 12, 2026") and left/right month grid
    /// label persistent storage; a11y projection reads these slices every frame, stack buf becomes
    /// dangling.
    a11y_value_buf: [64]u8 = undefined,
    left_grid_a11y_buf: [24]u8 = undefined,
    right_grid_a11y_buf: [24]u8 = undefined,
    /// date cell event context: left/right both 42 slots, live with state, reused every rebuild.
    /// previously each rebuild adoptResource'd new ctx into long-lived scope, month-flip monotone
    /// grew.
    day_ctxs: [2][42]DayCellCtx = undefined,

    /// apply data source value to display (discard draft); visible month unchanged
    fn applyValue(self: *DateRangePickerState, v: ?DateRange) void {
        self.applied = v;
        self.start_date = if (v) |r| r.start else null;
        self.end_date = if (v) |r| r.end else null;
        self.preview_end_date = null;
        updateDisplayLabelOrLog(self);
        self.rebuildOrLog();
    }

    fn rangeEql(a: ?DateRange, b: ?DateRange) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return x.start.eql(y.start) and x.end.eql(y.end);
    }

    fn viewEffect(self: *DateRangePickerState) void {
        const v = self.value.readAs(true);
        const open = self.open.read(true);
        _ = self.invalid.read(true);
        const disabled = self.disabled.read(true);
        if (disabled != self.shown_disabled) {
            self.applyDisabled(disabled);
            updateDisplayLabelOrLog(self);
        }
        // every open (click / external write open): reset draft and visible month to data source
        // value
        if (open and !self.shown_open) {
            self.shown_open = open;
            self.openReset(v);
        } else {
            // close (click outside / Esc / external write open) discards draft: incomplete start
            // cannot stay on trigger;
            // display must revert to data source value.
            const closing = !open and self.shown_open;
            self.shown_open = open;
            if (closing or !rangeEql(v, self.applied)) self.applyValue(v);
        }
        syncTriggerVisual(self, open);
    }

    /// dynamic disable: per recipe disable state changes frame, click entry gated by disabled
    fn applyDisabled(self: *DateRangePickerState, disabled: bool) void {
        self.shown_disabled = disabled;
        // Frame and cursor: the trigger shell (disabled parameter) and its look (syncTriggerVisual).
        if (self.trigger_node.behavior.interaction.a11y) |*a| a.disabled = disabled;
        self.trigger_node.markRenderDirty();
    }

    fn onTriggerClick(ptr: *anyopaque) void {
        const self: *DateRangePickerState = @ptrCast(@alignCast(ptr));
        if (self.disabled.peek()) return;
        self.toggle.invoke();
    }

    fn rebuildOrLog(self: *DateRangePickerState) void {
        self.syncFooter();
        rebuildPanels(self) catch |err| log.err("panel rebuild failed: {}", .{err});
    }

    /// open: reset draft and visible month to data source value (month of start, or today if none)
    fn openReset(self: *DateRangePickerState, v: ?DateRange) void {
        const anchor = if (v) |r| r.start else self.today_date;
        if (anchor) |d| {
            self.view_year = d.year;
            self.view_month = d.month;
        }
        self.applyValue(v);
    }

    pub fn selectDate(self: *DateRangePickerState, date: SimpleDate) void {
        self.preview_end_date = null;
        if (self.start_date == null or self.end_date != null) {
            // first click: only record draft start, no proposal
            self.start_date = date;
            self.end_date = null;
            updateDisplayLabelOrLog(self);
            syncTriggerVisual(self, self.open.peek());
            self.rebuildOrLog();
            return;
        }

        const start = self.start_date.?;
        const cmp = compareDate(date, start);
        if (cmp == 0) return;
        const range: DateRange = if (cmp < 0) .{ .start = date, .end = start } else .{ .start = start, .end = date };
        if (self.confirm_selection) {
            self.start_date = range.start;
            self.end_date = range.end;
            updateDisplayLabelOrLog(self);
            self.rebuildOrLog();
            return;
        }
        self.commitRange(range);
    }

    fn syncFooter(self: *DateRangePickerState) void {
        if (self.apply_disabled) |disabled| disabled.set(self.start_date == null or self.end_date == null);
        if (self.footer_summary) |label| {
            const content = if (self.start_date) |start| if (self.end_date) |end|
                std.fmt.bufPrint(&self.footer_buf, "{d}-{d:0>2}-{d:0>2} – {d}-{d:0>2}-{d:0>2}", .{ start.year, start.month, start.day, end.year, end.month, end.day }) catch ""
            else
                "Select end date" else "Select start date";
            if (label.getText()) |old| {
                var text = old;
                text.content = content;
                label.setText(text);
            }
        }
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *DateRangePickerState = @ptrCast(@alignCast(ptr));
        self.applyValue(self.value.peek());
        self.close.invoke();
    }

    fn apply(ptr: *anyopaque) void {
        const self: *DateRangePickerState = @ptrCast(@alignCast(ptr));
        if (self.disabled.peek()) return;
        const start = self.start_date orelse return;
        const end = self.end_date orelse return;
        self.commitRange(.{ .start = start, .end = end });
    }

    fn commitRange(self: *DateRangePickerState, range: DateRange) void {
        const on_change = self.on_change;
        const landed = self.value.commit(range);
        // parent rejects (or same as original) so view effect does not run: discard draft with
        // current data source value
        if (landed == null) self.applyValue(self.value.peek());
        self.close.invoke();
        if (landed) |l| {
            if (l) |r| {
                if (on_change) |h| h.call(r);
            }
        }
    }

    fn currentRightMonth(self: *const DateRangePickerState) MonthCursor {
        return nextMonthCursor(self.view_year, self.view_month);
    }

    pub fn prevMonth(self: *DateRangePickerState) void {
        const prev = previousMonthCursor(self.view_year, self.view_month);
        self.preview_end_date = null;
        self.view_year = prev.year;
        self.view_month = prev.month;
        self.rebuildOrLog();
    }

    pub fn nextMonth(self: *DateRangePickerState) void {
        const next = nextMonthCursor(self.view_year, self.view_month);
        self.preview_end_date = null;
        self.view_year = next.year;
        self.view_month = next.month;
        self.rebuildOrLog();
    }
};

pub const DateRangePickerResult = struct {
    wrapper: *Node,
    /// selected range signal (null when `ui.split`)
    value: ?*Signal(?DateRange),
    /// toggle signal (null when `ui.split`)
    open: ?*Signal(bool),
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: DateRangePickerResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

/// create DateRangePicker: `W.DateRangePicker(.{ .value = stay })`
pub fn DateRangePicker(props: anytype) DateRangePickerBuilder {
    return .{ .props = reactive.props.coerce(DateRangePickerProps, props) };
}

pub const DateRangePickerBuilder = struct {
    props: DateRangePickerProps,

    pub fn mount(self: DateRangePickerBuilder, scope: *Scope, cx: *Cx) !DateRangePickerResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const disabled0 = p.disabled.peek();
        // static disable drawn by shell as disabled state, no click attached; dynamic disable per
        // recipe changes frame
        const static_disabled = p.disabled.isStatic() and disabled0;

        const pop_result = try Popover(.{
            .position = .bottom_start,
            // click handled by component itself (gated by disabled), toggle uses same proposal
            // pipeline
            .trigger = .manual,
            .open = p.open,
            .on_open_change = p.on_open_change,
            .offset = .{ .static = 4 },
            .flip = false,
            .close_on_outside_click = true,
            .close_on_escape = true,
            // prewarm disabled by default: CA-pure surface first open frame fully rendered
            // (per-frame screenshot validated), no need hidden copy prewarm.
        }).mount(scope, cx);

        // sweep: Popover's wrapper held by this component, guarded until return; subtree adopt as
        // built.
        // freeNode disposes Popover's scope (all hooks / resources registered there) before freeing
        // node.
        errdefer cx.freeNode(pop_result.wrapper);
        // all resources, hooks and effects owned by Popover's scope: dual month panel in portal,
        // freed together on unmount
        const my_scope = pop_result.scope;
        const value = try reactive.resolveModel(?DateRange, my_scope, p.value);
        const initial_value = value.readAs(false);
        pop_result.wrapper.meta.ownership.meta.component_name = "DateRangePicker";
        // wrapper is layout-only: semantics on trigger (combobox). old value role=.textbox
        // added phantom 'textbox' containing combobox in AX tree.
        pop_result.wrapper.behavior.interaction.a11y = .{ .disabled = disabled0 };
        if (p.test_id) |tid| pop_result.wrapper.meta.ownership.meta.test_id = tid;

        pop_result.content.setBackgroundRaw(Color.TRANSPARENT);
        pop_result.content.style.border = .{};
        pop_result.content.style.padding = Padding.ZERO;
        const pop_content_ext = try pop_result.content.style.ensureExtFallible(allocator);
        pop_content_ext.clearShadows();
        pop_content_ext.hit_shape = .auto;
        pop_content_ext.clip_shape = .auto;

        const has_any_value = initial_value != null;
        const cm = control_shell.metrics(t, p.size);
        // same ControlShell as Input / Select / DatePicker (.field): icon_slot = calendar icon,
        // content_slot = start-end text (grow, can shrink clip), append_slot = chevron.
        const trigger_look = try my_scope.createSignal(trigger_styles.TriggerLook, .{ .size = p.size, .width = p.width, .has_value = has_any_value, .invalid = p.invalid.peek(), .disabled = disabled0 });
        const icon_size: core.Sizing = .{ .px = cm.icon_size };
        const range_text = styles.rangeTextStyle(t, cm);
        // start-end text content and color managed by updateDisplayLabel
        const TriggerParts = struct { calendar: *Node = undefined, start: *Node = undefined, dash: *Node = undefined, end: *Node = undefined, chevron: *Node = undefined };
        var tparts: TriggerParts = .{};
        var shell: core.ViewParts = undefined;
        // The trigger is a ControlShell (structure, slots, cursor, disabled); the shared picker
        // look stacks on it as an overlay following trigger_look.
        try view.mount(my_scope, cx, pop_result.trigger, view.attrs(.{ .style = view.styleBy(trigger_look, trigger_styles.triggerFrame) }, view.with(control_shell.ControlShell(.{
            .variant = .field,
            .size = p.size,
            .disabled = p.disabled,
            .leading_icon = true,
            .tag = .button,
            .cursor = .pointer,
            .content_style = core.BoxStyle{
                .width = .{ .grow = .{ .min = 0 } },
                .flex_shrink = 1,
                .overflow_hidden = true,
                .gap = cm.gap,
                .min_width = 0,
            },
        }), .{}).capture(&shell).slots(.{
            .icon = view.capture(&tparts.calendar, view.icon(.{
                .style = .{ .width = icon_size, .height = icon_size },
                .tint = view.tintBy(trigger_look, trigger_styles.triggerLeadingTint),
            }, p.calendar_icon_asset orelse svg_assets.common.calendar)),
            .content = .{
                view.capture(&tparts.start, view.text(.{ .style = range_text }, p.placeholder_start)),
                view.capture(&tparts.dash, view.text(.{ .style = range_text }, "–")),
                view.capture(&tparts.end, view.text(.{ .style = range_text }, p.placeholder_end)),
            },
            .append = view.capture(&tparts.chevron, view.icon(.{
                .style = .{ .width = icon_size, .height = icon_size },
                .tint = view.tintBy(trigger_look, trigger_styles.triggerChevronTint),
            }, svg_assets.common.chevron_down)),
        })));
        const trigger = shell.root.?;
        // a11y: combobox + dialog popup; expanded/value_text updated by
        // syncTriggerVisual / updateDisplayLabel following interaction.
        trigger.behavior.interaction.a11y = .{
            .role = .combobox,
            .has_popup = .dialog,
            .label = "Date range",
            .disabled = disabled0,
            .expanded = false,
        };
        const calendar_icon = tparts.calendar;
        const start_display = tparts.start;
        const dash_display = tparts.dash;
        const end_display = tparts.end;
        const chevron = tparts.chevron;
        // test_id built at runtime from p.test_id, node holds copy (view's .test_id only borrows)
        try assignTestId(allocator, trigger, p.test_id, ".trigger");
        try assignTestId(allocator, start_display, p.test_id, ".start");
        try assignTestId(allocator, dash_display, p.test_id, ".dash");
        try assignTestId(allocator, end_display, p.test_id, ".end");

        // dual month panel mounted to popover content: left month / divider / right month.
        // panelStyle includes shadow (BoxStyle.shadow -> ensureExt.setShadow, equivalent to old
        // manual ext write)
        const prev_icon = p.prev_icon_asset orelse svg_assets.common.chevron_left;
        const next_icon = p.next_icon_asset orelse svg_assets.common.chevron_right;
        var left_month: MonthSectionRefs = .{};
        var right_month: MonthSectionRefs = .{};
        var panel: *Node = undefined;
        try view.mount(my_scope, cx, pop_result.content, view.capture(&panel, view.box(.{ .style = .{ styles.panelStyle(t), core.BoxStyle{
            .hit_shape = .{ .rounded_rect = styles.panel_radius },
            .clip_shape = .{ .rounded_rect = styles.panel_radius },
        } } }, .{
            view.row(.{ .style = styles.monthsStyle }, .{
                view.capture(&left_month.container, view.component(monthSection, MonthSectionProps{ .refs = &left_month, .show_prev = true, .show_next = false, .prev_icon = prev_icon, .next_icon = next_icon })),
                view.capture(&right_month.container, view.component(monthSection, MonthSectionProps{ .refs = &right_month, .show_prev = false, .show_next = true, .prev_icon = prev_icon, .next_icon = next_icon })),
            }),
        })));
        panel.meta.ownership.meta.component_name = "DateRangePickerPanel";
        try assignTestId(allocator, panel, p.test_id, ".panel");

        const today = calendar_mod.currentLocalDate();
        const anchor = if (initial_value) |r| r.start else today;
        const state = try my_scope.allocator.create(DateRangePickerState);
        state.* = .{
            .value = value,
            .applied = initial_value,
            .confirm_selection = p.confirm_selection,
            .start_date = if (initial_value) |r| r.start else null,
            .end_date = if (initial_value) |r| r.end else null,
            .preview_end_date = null,
            .panel_node = panel,
            .start_display = start_display,
            .dash_display = dash_display,
            .end_display = end_display,
            .trigger_node = trigger,
            .leading_icon_node = calendar_icon,
            .chevron_node = chevron,
            .left_title = left_month.title,
            .left_grid = left_month.grid,
            .right_title = right_month.title,
            .right_grid = right_month.grid,
            .view_year = if (anchor) |d| d.year else 2025,
            .view_month = if (anchor) |d| d.month else 1,
            .today_date = today,
            .open = pop_result.open_read,
            .close = pop_result.close,
            .toggle = pop_result.toggle,
            .disabled = p.disabled,
            .invalid = p.invalid,
            .shown_disabled = disabled0,
            .trigger_look = trigger_look,
            .on_change = p.on_change,
            .placeholder_start = p.placeholder_start,
            .placeholder_end = p.placeholder_end,
            .cx = cx,
            .scope = my_scope,
            .day_cell_refs = .empty,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s = @as(*DateRangePickerState, @ptrCast(@alignCast(ptr)));
                s.day_cell_refs.deinit(alloc);
                alloc.destroy(s);
            }
        }.cleanup);
        if (p.confirm_selection) {
            state.apply_disabled = try my_scope.createSignal(bool, initial_value == null);
            try view.mount(my_scope, cx, panel, view.row(.{ .style = styles.footerStyle }, .{
                view.attrs(.{ .style = styles.footerSummaryStyle }, view.capture(&state.footer_summary, view.text(.{ .style = styles.footerTextStyle }, @as([]const u8, "")))),
                Button(.{ .label = "Cancel", .variant = .secondary, .base_style = styles.footerButtonStyle(t), .on_click = Cx.simpleHandler(DateRangePickerState.cancel, state) }),
                Button(.{ .label = "Apply", .disabled = state.apply_disabled.?, .base_style = styles.footerButtonStyle(t), .on_click = Cx.simpleHandler(DateRangePickerState.apply, state) }),
            }));
            state.syncFooter();
        }
        // static disable completely lazy (no click attached); dynamic disable still attached, entry
        // gated by disabled
        if (!static_disabled) pop_result.trigger.behavior.events.on_click = core.Cx.simpleHandler(DateRangePickerState.onTriggerClick, state);
        pop_result.wrapper.addDebugState(@ptrCast(state));
        hooks.setHoverHandler(panel, false, core.Cx.simpleHandler(panelLeaveHandler, @ptrCast(state)));

        const prev_ctx = try my_scope.allocator.create(NavClickCtx);
        prev_ctx.* = .{ .state = state, .dir = .prev };
        try my_scope.adoptResource(@ptrCast(prev_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*NavClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        if (left_month.nav_btn) |prev_btn| {
            prev_btn.behavior.events.on_click = core.Cx.simpleHandler(navClickHandler, @ptrCast(prev_ctx));
            try assignTestId(allocator, prev_btn, p.test_id, ".prev");
        }

        const next_ctx = try my_scope.allocator.create(NavClickCtx);
        next_ctx.* = .{ .state = state, .dir = .next };
        try my_scope.adoptResource(@ptrCast(next_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*NavClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        if (right_month.nav_btn) |next_btn| {
            next_btn.behavior.events.on_click = core.Cx.simpleHandler(navClickHandler, @ptrCast(next_ctx));
            try assignTestId(allocator, next_btn, p.test_id, ".next");
        }

        try updateDisplayLabel(state);
        syncTriggerVisual(state, false);
        try rebuildPanels(state);
        // view = f(value, open): data source change overrides draft; toggle drives trigger visual
        try my_scope.createEffect(state, DateRangePickerState.viewEffect);

        return .{ .wrapper = pop_result.wrapper, .value = value.asSignal(), .open = pop_result.open };
    }
};

const Signal = core.Signal;

const NavDir = enum { prev, next };

const NavClickCtx = struct {
    state: *DateRangePickerState,
    dir: NavDir,
};

const DayCellCtx = struct {
    state: *DateRangePickerState,
    date: SimpleDate,
    node: *Node,
    /// a11y: cell complete date label ("March 15, 2026") persistent storage; ctx lifecycle same as
    /// node
    /// (scope resource).
    a11y_label_buf: [40]u8 = undefined,
    a11y_label_len: usize = 0,
    /// date number text (prebuilt element description borrows it)
    day_buf: [4]u8 = undefined,
};

const DayCellRefs = struct {
    date: SimpleDate,
    in_current_month: bool,
    cell_node: *Node,
    text_node: *Node,
    last_visual: ?styles.DayCellVisual = null,
};

const MonthSectionRefs = struct {
    container: *Node = undefined,
    title: *Node = undefined,
    grid: *Node = undefined,
    nav_btn: ?*Node = null,
};

const CalendarCell = struct {
    date: SimpleDate,
    in_current_month: bool,
};

const MonthCursor = struct {
    year: u16,
    month: u8,
};

fn navClickHandler(ctx_ptr: *anyopaque) void {
    const ctx: *NavClickCtx = @ptrCast(@alignCast(ctx_ptr));
    switch (ctx.dir) {
        .prev => ctx.state.prevMonth(),
        .next => ctx.state.nextMonth(),
    }
}

fn dayClickHandler(event: Event, ctx_ptr: ?*anyopaque) EventResult {
    switch (event) {
        .click => {},
        else => return .ignored,
    }
    const ctx: *DayCellCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.state.selectDate(ctx.date);
    return .handled;
}

const DayCellRole = enum {
    start,
    end,
    middle,
    outside,
};

var preview_trace_enabled_cache: ?bool = null;

fn previewTraceEnabled() bool {
    if (preview_trace_enabled_cache) |enabled| return enabled;
    const raw = @import("zenit_environment").getNative("ZENIT_DRP_PREVIEW_TRACE");
    if (raw == null) {
        preview_trace_enabled_cache = false;
        return false;
    }
    const value = std.mem.span(raw.?);
    if (value.len == 0 or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) {
        preview_trace_enabled_cache = false;
        return false;
    }
    preview_trace_enabled_cache = true;
    return true;
}

fn dayCellVisualEql(a: styles.DayCellVisual, b: styles.DayCellVisual) bool {
    return Color.eql(a.bg_color, b.bg_color) and
        Color.eql(a.text_color, b.text_color) and
        a.border_width == b.border_width and
        Color.eql(a.border_color, b.border_color) and
        std.meta.eql(a.corner_radius.resolve4(), b.corner_radius.resolve4()) and
        a.font_weight == b.font_weight and
        a.hover_enabled == b.hover_enabled;
}

fn dayCellRole(state: *const DateRangePickerState, date: SimpleDate) DayCellRole {
    const resolved_end = effectiveRangeEnd(state.start_date, state.end_date, state.preview_end_date);
    const is_start = if (state.start_date) |d| d.eql(date) else false;
    const is_end = if (resolved_end) |d| d.eql(date) else false;
    const in_range = isDateInRange(date, state.start_date, resolved_end);
    if (is_start) return .start;
    if (is_end) return .end;
    if (in_range) return .middle;
    return .outside;
}

fn traceDayCellApply(state: *const DateRangePickerState, refs: *DayCellRefs, visual: styles.DayCellVisual) void {
    if (!previewTraceEnabled()) return;

    const role = dayCellRole(state, refs.date);
    const changed = if (refs.last_visual) |prev| !dayCellVisualEql(prev, visual) else true;
    log.info(
        "[preview] {d}-{d:0>2}-{d:0>2} role={s} changed={} preview={any} start={any} end={any}",
        .{
            refs.date.year,
            refs.date.month,
            refs.date.day,
            @tagName(role),
            changed,
            state.preview_end_date,
            state.start_date,
            state.end_date,
        },
    );
}

pub fn effectiveRangeEnd(start: ?SimpleDate, end: ?SimpleDate, preview_end: ?SimpleDate) ?SimpleDate {
    if (end) |resolved_end| return resolved_end;
    if (start) |resolved_start| {
        if (preview_end) |hovered| {
            if (compareDate(hovered, resolved_start) > 0) return hovered;
        }
    }
    return null;
}

fn optionalDateEql(a: ?SimpleDate, b: ?SimpleDate) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

fn applyDayCellVisual(state: *DateRangePickerState, cell_node: *Node, text_node: *Node, visual: styles.DayCellVisual) void {
    cell_node.setStyle(null, .background, visual.bg_color);
    cell_node.setBorderWidth(visual.border_width);
    cell_node.setBorderColor(visual.border_color);
    cell_node.style.ensureExtPanic(state.cx.allocator).corner_radius = visual.corner_radius;
    cell_node.markRenderDirty();

    if (text_node.getText()) |old| {
        var txt = old;
        txt.color = visual.text_color;
        txt.font_weight = visual.font_weight;
        text_node.setText(txt);
    }
    text_node.markRenderDirty();
}

fn refreshVisibleDayCellStyles(state: *DateRangePickerState) void {
    for (state.day_cell_refs.items) |*refs| {
        const visual = styles.computeDayCellVisual(state, refs.date, refs.in_current_month);
        if (refs.last_visual) |prev| {
            if (dayCellVisualEql(prev, visual)) continue;
        }
        traceDayCellApply(state, refs, visual);
        applyDayCellVisual(state, refs.cell_node, refs.text_node, visual);
        refs.last_visual = visual;
    }
}

fn setPreviewEndDate(state: *DateRangePickerState, date: ?SimpleDate) void {
    if (optionalDateEql(state.preview_end_date, date)) return;
    if (previewTraceEnabled()) {
        log.info("[preview-transition] {any} -> {any}", .{ state.preview_end_date, date });
    }
    state.preview_end_date = date;
    refreshVisibleDayCellStyles(state);
}

fn dayHoverHandler(ctx_ptr: *anyopaque) void {
    const ctx: *DayCellCtx = @ptrCast(@alignCast(ctx_ptr));

    if (ctx.state.start_date) |start| {
        if (ctx.state.end_date == null and compareDate(ctx.date, start) > 0) {
            setPreviewEndDate(ctx.state, ctx.date);
            return;
        }
    }

    if (ctx.state.preview_end_date != null) {
        setPreviewEndDate(ctx.state, null);
    }

    const visual = styles.computeDayCellVisual(ctx.state, ctx.date, true);
    if (!visual.hover_enabled) return;
    ctx.node.setStyle(null, .background, ctx.state.cx.tokens.tokens.color.bg_hover);
}

fn dayLeaveHandler(ctx_ptr: *anyopaque) void {
    const ctx: *DayCellCtx = @ptrCast(@alignCast(ctx_ptr));

    const visual = styles.computeDayCellVisual(ctx.state, ctx.date, true);
    if (!visual.hover_enabled) return;
    ctx.node.setStyle(null, .background, visual.bg_color);
}

fn panelLeaveHandler(ctx_ptr: *anyopaque) void {
    const state: *DateRangePickerState = @ptrCast(@alignCast(ctx_ptr));
    const rect = state.panel_node.rectFromWorldOrFallback();
    // A pointer that left the window (or went under another window) keeps its last position.
    if (state.cx.pointerLive() and state.cx.mouse_x >= rect.x and state.cx.mouse_x <= rect.x + rect.w and
        state.cx.mouse_y >= rect.y and state.cx.mouse_y <= rect.y + rect.h)
    {
        return;
    }
    if (state.preview_end_date != null) setPreviewEndDate(state, null);
}

fn passiveHoverHandler(_: *anyopaque) void {}

const MonthSectionProps = struct {
    refs: *MonthSectionRefs,
    show_prev: bool,
    show_next: bool,
    prev_icon: svg_assets.Asset,
    next_icon: svg_assets.Asset,
};

/// one month section: header (left-arrow / title / right-arrow, the side without a button uses a
/// same-width spacer) + weekday titles + date grid
fn monthSection(props: MonthSectionProps, scope: *Scope, cx: *Cx) !*Node {
    const t = cx.tokens;
    const refs = props.refs;
    const weekdays = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };
    var grid_wrap: *Node = undefined;
    const container = try view.render(scope, cx, view.box(.{ .style = styles.monthSectionStyle(t) }, .{
        view.box(.{ .style = styles.monthHeaderStyle(t) }, .{
            view.branch(props.show_prev, view.capture(&refs.nav_btn, iconButton(t, props.prev_icon)), navSpacer()),
            // header content written by rebuildPanels
            view.capture(&refs.title, view.text(.{ .style = styles.monthTitleTextStyle(t) }, "")),
            view.branch(props.show_next, view.capture(&refs.nav_btn, iconButton(t, props.next_icon)), navSpacer()),
        }),
        view.box(.{ .style = core.BoxStyle{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
            .justify = .center,
        } }, view.box(.{ .style = core.BoxStyle{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
        } }, view.listWith(t, &weekdays, weekdayCell))),
        view.capture(&grid_wrap, view.box(.{ .style = core.BoxStyle{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
            .justify = .center,
            .cursor = .pointer,
        } }, view.capture(&refs.grid, view.box(.{ .style = styles.monthGridStyle(t) }, {})))),
    }));
    hooks.setHoverHandler(grid_wrap, true, core.Cx.simpleHandler(passiveHoverHandler, @ptrCast(grid_wrap)));
    hooks.setHoverHandler(refs.grid, true, core.Cx.simpleHandler(passiveHoverHandler, @ptrCast(refs.grid)));
    return container;
}

const IconButtonProps = struct { style: @TypeOf(styles.navButton) };
const IconProps = struct { style: core.BoxStyle, tint: Color };

fn iconButton(t: *const theme.ThemeTokens, icon_asset: svg_assets.Asset) view.Box(IconButtonProps, view.Icon(IconProps), null) {
    const icon_size: core.Sizing = .{ .px = styles.nav_icon_size };
    return view.box(IconButtonProps{ .style = styles.navButton }, view.icon(IconProps{
        .style = .{ .width = icon_size, .height = icon_size },
        .tint = t.tokens.color.fg_secondary,
    }, icon_asset));
}

const NavSpacerProps = struct { style: core.BoxStyle };

fn navSpacer() view.Box(NavSpacerProps, void, null) {
    return view.box(NavSpacerProps{ .style = .{ .width = .{ .px = 32 }, .height = .{ .px = 32 } } }, {});
}

const WeekdayTextProps = struct { style: core.TextStyle };
const WeekdayCellProps = struct { style: core.BoxStyle };
const WeekdayCell = view.Attrs(WeekdayCellProps, view.Text(WeekdayTextProps, []const u8));

fn weekdayCell(t: *const theme.ThemeTokens, wd: []const u8) WeekdayCell {
    return view.attrs(WeekdayCellProps{ .style = styles.weekdayCellStyle(t) }, view.text(WeekdayTextProps{ .style = styles.weekdayTextStyle(t) }, wd));
}

const DayCellProps = struct { style: core.BoxStyle, a11y: core.A11yProps, on_hover: ?core.HandlerRef, on_leave: ?core.HandlerRef };
const DayTextProps = struct { style: core.TextStyle };
const DayPlaceholderProps = struct { style: core.BoxStyle };
/// grid cell: current month date cell (cell + number), or neighbor month placeholder of same size
const DayGridCell = view.Branch(
    view.NodeCapture(**Node, view.Box(DayCellProps, view.NodeCapture(**Node, view.Text(DayTextProps, []const u8)), null)),
    view.Box(DayPlaceholderProps, void, null),
);

fn rebuildPanels(state: *DateRangePickerState) !void {
    state.day_cell_refs.clearRetainingCapacity();

    var left_buf: [24]u8 = undefined;
    const left_label = formatMonthYear(state.view_year, state.view_month, &left_buf);
    if (state.left_title.getText()) |__old_t| {
        var __t = __old_t;
        try __t.setContent(state.cx.allocator, left_label);
        state.left_title.setText(__t);
    }
    state.left_title.markRenderDirty();

    const right = state.currentRightMonth();
    var right_buf: [24]u8 = undefined;
    const right_label = formatMonthYear(right.year, right.month, &right_buf);
    if (state.right_title.getText()) |__old_t| {
        var __t = __old_t;
        try __t.setContent(state.cx.allocator, right_label);
        state.right_title.setText(__t);
    }
    state.right_title.markRenderDirty();

    // a11y: left and right month panels each a grid, label follows view month
    const left_a11y = formatMonthYear(state.view_year, state.view_month, &state.left_grid_a11y_buf);
    state.left_grid.behavior.interaction.a11y = .{ .role = .grid, .label = left_a11y };
    const right_a11y = formatMonthYear(right.year, right.month, &state.right_grid_a11y_buf);
    state.right_grid.behavior.interaction.a11y = .{ .role = .grid, .label = right_a11y };

    try rebuildMonthGrid(state, state.left_grid, state.view_year, state.view_month);
    try rebuildMonthGrid(state, state.right_grid, right.year, right.month);
}

fn rebuildMonthGrid(state: *DateRangePickerState, grid: *Node, year: u16, month: u8) !void {
    // each week row scope bound to row node (view.append): free row frees its scope, month-flip
    // does not accumulate in scope tree
    while (grid.children.items.len > 0) {
        const child = grid.children.items[grid.children.items.len - 1];
        state.cx.detachChild(grid, child);
        state.cx.freeNode(child);
    }
    try buildMonthGrid(state, grid, year, month);
}

fn buildMonthGrid(state: *DateRangePickerState, grid: *Node, year: u16, month: u8) !void {
    const allocator = state.cx.allocator;
    const t = state.cx.tokens;
    const side: usize = if (grid == state.right_grid) 1 else 0;
    var cells: [42]CalendarCell = undefined;
    const count = buildCalendarCells(year, month, &cells);

    var row: usize = 0;
    while (row * 7 < count) : (row += 1) {
        // exactly 7 cells per row (buildCalendarCells pads to full weeks)
        var row_cells: [7]DayGridCell = undefined;
        var text_nodes: [7]*Node = undefined;
        var visuals: [7]styles.DayCellVisual = undefined;
        for (&row_cells, 0..) |*el, col| {
            const idx = row * 7 + col;
            const cell = cells[idx];
            const date = cell.date;
            if (!cell.in_current_month) {
                el.* = .{ .b = view.box(DayPlaceholderProps{ .style = styles.dayPlaceholderStyle(t) }, {}) };
                continue;
            }

            const visual = styles.computeDayCellVisual(state, date, true);
            visuals[col] = visual;
            var cell_style = styles.dayCellBoxStyle(visual);
            cell_style.cursor = .pointer;
            // corner radius varies per corner endpoint (CornerRadius)
            cell_style.corner_radii = visual.corner_radius;

            // this grid's old cell nodes freed at rebuildMonthGrid start, slots safe to reuse; node
            // written by mount
            const day_ctx = &state.day_ctxs[side][idx];
            day_ctx.* = .{ .state = state, .date = date, .node = undefined };
            // date number: store in slot (element description borrows it on mount, text node copies
            // on mount)
            const day_text: []const u8 = std.fmt.bufPrint(&day_ctx.day_buf, "{d}", .{date.day}) catch "?";
            const day_len = day_text.len;

            // a11y: gridcell + complete label with year-month-day + endpoint selected state + today
            // marker
            const cell_label = std.fmt.bufPrint(&day_ctx.a11y_label_buf, "{s} {d}, {d}", .{
                monthName(date.month), date.day, date.year,
            }) catch "";
            day_ctx.a11y_label_len = cell_label.len;
            const is_endpoint = (state.start_date != null and date.eql(state.start_date.?)) or
                (state.end_date != null and date.eql(state.end_date.?));
            const is_today = state.today_date != null and date.eql(state.today_date.?);
            el.* = .{ .a = view.capture(&day_ctx.node, view.box(DayCellProps{
                .style = cell_style,
                .a11y = .{
                    .role = .gridcell,
                    .label = day_ctx.a11y_label_buf[0..day_ctx.a11y_label_len],
                    .selected = is_endpoint,
                    .description = if (is_today) "Today" else null,
                    .row_index = @intCast(row + 1),
                    .column_index = @intCast(col),
                },
                .on_hover = core.Cx.simpleHandler(dayHoverHandler, @ptrCast(day_ctx)),
                .on_leave = core.Cx.simpleHandler(dayLeaveHandler, @ptrCast(day_ctx)),
            }, view.capture(&text_nodes[col], view.text(DayTextProps{ .style = .{
                .color = visual.text_color,
                .font_size = styles.day_font_size,
                .font_weight = visual.font_weight,
            } }, @as([]const u8, day_ctx.day_buf[0..day_len]))))) };
        }
        // a11y: each week row is a grid row (weekday titles occupy row_index 0).
        // sweep: row mount failure rolls back whole row; row scope bound to row node, freed on
        // rebuild.
        _ = try view.append(state.scope, state.cx, grid, view.box(.{
            .style = styles.weekRowStyle(t),
            .a11y = core.A11yProps{ .role = .row, .row_index = @intCast(row + 1) },
        }, row_cells));

        // click (raw event callback) and visible cell registration
        for (0..7) |col| {
            const idx = row * 7 + col;
            if (!cells[idx].in_current_month) continue;
            const day_ctx = &state.day_ctxs[side][idx];
            const day_cell = day_ctx.node;
            day_cell.behavior.events.on_event = dayClickHandler;
            day_cell.behavior.events.event_context = @ptrCast(day_ctx);
            try state.day_cell_refs.append(allocator, .{
                .date = day_ctx.date,
                .in_current_month = true,
                .cell_node = day_cell,
                .text_node = text_nodes[col],
                .last_visual = visuals[col],
            });
        }
    }
}

/// Trigger labels, dash and a11y value from the current dates. Both labels are copied before
/// either node changes: `error.OutOfMemory` leaves the trigger as it was (mount propagates it;
/// later updates log it and the next date change writes the labels again).
fn updateDisplayLabel(state: *DateRangePickerState) error{OutOfMemory}!void {
    const t = state.cx.tokens;
    const alloc = state.cx.allocator;
    var start_buf: [24]u8 = undefined;
    var end_buf: [24]u8 = undefined;
    // allocating writes: the inline buffer only holds 16 bytes, a caller's placeholder would be cut
    const start_label = try alloc.dupe(u8, if (state.start_date) |date| formatDisplayDate(date, &start_buf) else state.placeholder_start);
    errdefer alloc.free(start_label);
    const end_label = try alloc.dupe(u8, if (state.end_date) |date| formatDisplayDate(date, &end_buf) else state.placeholder_end);
    writeDisplayLabel(state.start_display, start_label, styles.triggerForeground(state.start_date != null, state.disabled.peek(), t));
    writeDisplayLabel(state.end_display, end_label, styles.triggerForeground(state.end_date != null, state.disabled.peek(), t));

    if (state.dash_display.getText()) |old| {
        var txt = old;
        txt.setInlineContent("–") catch unreachable; // 3-byte literal
        txt.color = styles.dashColor(state.start_date != null or state.end_date != null, state.disabled.peek(), t);
        state.dash_display.setText(txt);
    }
    state.dash_display.markRenderDirty();

    // a11y: range readable description written to trigger value ("Mar 10, 2026 – Mar 12, 2026");
    // no selection entirely reverts to null (form_field retractable mode).
    if (state.trigger_node.behavior.interaction.a11y) |*a| {
        if (state.start_date == null and state.end_date == null) {
            a.value_text = null;
        } else {
            var sbuf: [24]u8 = undefined;
            var ebuf: [24]u8 = undefined;
            const s_txt = if (state.start_date) |d| formatDisplayDate(d, &sbuf) else state.placeholder_start;
            const e_txt = if (state.end_date) |d| formatDisplayDate(d, &ebuf) else state.placeholder_end;
            const v = std.fmt.bufPrint(&state.a11y_value_buf, "{s} – {s}", .{ s_txt, e_txt }) catch "";
            a.value_text = if (v.len > 0) state.a11y_value_buf[0..v.len] else null;
        }
        state.trigger_node.markRenderDirty();
    }
}

/// Owned label content and its color in one write (cannot fail).
fn writeDisplayLabel(node: *Node, owned: []u8, color: Color) void {
    var txt = node.getText() orelse core.TextProps{};
    const changed = !std.mem.eql(u8, txt.content, owned);
    txt.content = owned;
    txt.owned = true;
    txt.inline_len = 0;
    txt.color = color;
    node.setText(txt);
    if (changed) node.markSizingDirty();
    node.markRenderDirty();
}

fn updateDisplayLabelOrLog(state: *DateRangePickerState) void {
    updateDisplayLabel(state) catch |err| log.warn("trigger label update failed: {}; the trigger keeps its previous dates", .{err});
}

fn syncTriggerVisual(state: *DateRangePickerState, open: bool) void {
    // a11y: expanded follows toggle (form_field 'state follows interaction' mode)
    if (state.trigger_node.behavior.interaction.a11y) |*a| a.expanded = open;
    state.trigger_node.markRenderDirty();

    var look = state.trigger_look.peek();
    look.open = open;
    look.has_value = state.start_date != null or state.end_date != null;
    look.invalid = state.invalid.peek();
    look.disabled = state.disabled.peek();
    state.trigger_look.set(look);
    if (state.trigger_node.behavior.interaction.a11y) |*a| a.invalid = look.invalid;
    state.chevron_node.setRotate(state.cx.allocator, if (open) std.math.pi else 0);
}

fn assignTestId(allocator: Allocator, node: *Node, base: ?[]const u8, suffix: []const u8) !void {
    if (base) |tid| {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}{s}", .{ tid, suffix }) catch return;
        node.meta.ownership.meta.test_id = try allocator.dupe(u8, s);
        node.frame_state.state_bits.flags.test_id_owned = true;
    }
}

pub fn compareDate(a: SimpleDate, b: SimpleDate) i8 {
    if (a.year < b.year) return -1;
    if (a.year > b.year) return 1;
    if (a.month < b.month) return -1;
    if (a.month > b.month) return 1;
    if (a.day < b.day) return -1;
    if (a.day > b.day) return 1;
    return 0;
}

pub fn isDateInRange(date: SimpleDate, start: ?SimpleDate, end: ?SimpleDate) bool {
    if (start == null or end == null) return false;
    return compareDate(date, start.?) >= 0 and compareDate(date, end.?) <= 0;
}

fn monthAbbrev(month: u8) []const u8 {
    return switch (month) {
        1 => "Jan",
        2 => "Feb",
        3 => "Mar",
        4 => "Apr",
        5 => "May",
        6 => "Jun",
        7 => "Jul",
        8 => "Aug",
        9 => "Sep",
        10 => "Oct",
        11 => "Nov",
        12 => "Dec",
        else => "???",
    };
}

fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "Unknown",
    };
}

fn formatDisplayDate(date: SimpleDate, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ monthAbbrev(date.month), date.day, date.year }) catch "Invalid date";
}

fn formatMonthYear(year: u16, month: u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d}", .{ monthName(month), year }) catch "Unknown";
}

fn previousMonthCursor(year: u16, month: u8) MonthCursor {
    if (month <= 1) return .{ .year = year - 1, .month = 12 };
    return .{ .year = year, .month = month - 1 };
}

fn nextMonthCursor(year: u16, month: u8) MonthCursor {
    if (month >= 12) return .{ .year = year + 1, .month = 1 };
    return .{ .year = year, .month = month + 1 };
}

fn buildCalendarCells(year: u16, month: u8, out: *[42]CalendarCell) usize {
    const total_days = daysInMonth(year, month);
    const first_dow = dayOfWeek(year, month, 1);
    const used_slots: usize = @as(usize, first_dow) + @as(usize, total_days);
    const trailing_slots: usize = if (@mod(used_slots, 7) == 0) 0 else 7 - @mod(used_slots, 7);
    const total_slots = used_slots + trailing_slots;

    const prev = previousMonthCursor(year, month);
    const next = nextMonthCursor(year, month);
    const prev_days = daysInMonth(prev.year, prev.month);

    var idx: usize = 0;
    while (idx < total_slots) : (idx += 1) {
        if (idx < first_dow) {
            const offset = @as(u8, @intCast(first_dow - idx));
            out[idx] = .{ .date = .{ .year = prev.year, .month = prev.month, .day = prev_days - offset + 1 }, .in_current_month = false };
            continue;
        }
        if (idx < used_slots) {
            const day = @as(u8, @intCast(idx - first_dow + 1));
            out[idx] = .{ .date = .{ .year = year, .month = month, .day = day }, .in_current_month = true };
            continue;
        }
        const next_day = @as(u8, @intCast(idx - used_slots + 1));
        out[idx] = .{ .date = .{ .year = next.year, .month = next.month, .day = next_day }, .in_current_month = false };
    }
    return total_slots;
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

pub fn dayOfWeek(year: u16, month: u8, day: u8) u8 {
    var y: i32 = @intCast(year);
    var m: i32 = @intCast(month);
    const d: i32 = @intCast(day);
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const k = @mod(y, 100);
    const j = @divFloor(y, 100);
    const h = @mod(d + @divFloor(13 * (m + 1), 5) + k + @divFloor(k, 4) + @divFloor(j, 4) + 5 * j, 7);
    return switch (h) {
        0 => 6,
        1 => 0,
        2 => 1,
        3 => 2,
        4 => 3,
        5 => 4,
        6 => 5,
        else => 0,
    };
}

fn stateOf(r: DateRangePickerResult) *DateRangePickerState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

test "DateRangePicker: basic structure" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expect(stateOf(result).start_date == null);
    try std.testing.expect(stateOf(result).end_date == null);
    if (stateOf(result).start_display.getText()) |txt| {
        try std.testing.expectEqualStrings("Start date", txt.content);
    } else try std.testing.expect(false);
}

test "a11y: DateRangePicker expanded/value 跟随范围选择且可撤回" {
    const testing = std.testing;
    var ctx = try Cx.init(testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 700);
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    stateOf(result).view_year = 2026;
    stateOf(result).view_month = 3;
    try rebuildPanels(stateOf(result));
    try root.appendChild(testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    // assert a11y tree (actually sent to AT), not props struct.
    const eid = core.ElementId.fromRaw(stateOf(result).trigger_node.element_id_raw);
    {
        const n = ctx.accessibility_tree.getNode(eid).?;
        try testing.expectEqual(core.a11y_tree.Role.combobox, n.role);
        try testing.expect(n.state.haspopup);
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(@as(u64, 0), n.text_hash); // no range -> no value
    }

    // open -> expanded=true (open resets visible month to today, test flips back to 2026-03)
    result.open.?.set(true);
    stateOf(result).view_year = 2026;
    stateOf(result).view_month = 3;
    try rebuildPanels(stateOf(result));
    ctx.layout();
    _ = ctx.render();
    try testing.expect(ctx.accessibility_tree.getNode(eid).?.state.expanded);

    // select start (panel stays open, value is partial description)
    stateOf(result).selectDate(.{ .year = 2026, .month = 3, .day = 10 });
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(
        std.hash.Wyhash.hash(0, "Mar 10, 2026 – End date"),
        ctx.accessibility_tree.getNode(eid).?.text_hash,
    );

    // select end -> panel closes (expanded retracts) + full range announced
    stateOf(result).selectDate(.{ .year = 2026, .month = 3, .day = 12 });
    ctx.layout();
    _ = ctx.render();
    {
        const n = ctx.accessibility_tree.getNode(eid).?;
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(std.hash.Wyhash.hash(0, "Mar 10, 2026 – Mar 12, 2026"), n.text_hash);
    }

    // endpoint cell gridcell semantics (reopening range resets to new start, retractable)
    var found_selected: usize = 0;
    for (stateOf(result).day_cell_refs.items) |ref| {
        const a = ref.cell_node.behavior.interaction.a11y orelse continue;
        if (a.selected) {
            found_selected += 1;
            try testing.expectEqual(core.A11yRole.gridcell, a.role);
        }
    }
    try testing.expectEqual(@as(usize, 2), found_selected); // start + end

    // select another day = start new range -> old range retracts, value becomes partial
    stateOf(result).selectDate(.{ .year = 2026, .month = 3, .day = 20 });
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(
        std.hash.Wyhash.hash(0, "Mar 20, 2026 – End date"),
        ctx.accessibility_tree.getNode(eid).?.text_hash,
    );
}

test "DateRangePicker: the range preview ends when the pointer leaves the window, even over the panel" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 700);
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const state = stateOf(result);
    state.start_date = .{ .year = 2026, .month = 3, .day = 10 };
    state.preview_end_date = .{ .year = 2026, .month = 3, .day = 14 };
    // A live pointer still over the panel when it gets on_leave (moved onto a child): keep it.
    const rect = state.panel_node.rectFromWorldOrFallback();
    ctx.handleMouseMove(rect.x, rect.y);
    panelLeaveHandler(@ptrCast(state));
    try std.testing.expect(state.preview_end_date != null);
    // Platform pointer_left (left the window or covered) at the same last position: preview ends.
    ctx.hover_sync.pointer_over_content = false;
    panelLeaveHandler(@ptrCast(state));
    try std.testing.expect(state.preview_end_date == null);
}

test "DateRangePicker: with initial range" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .value = DateRange{ .start = .{ .year = 2026, .month = 3, .day = 15 }, .end = .{ .year = 2026, .month = 3, .day = 28 } },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    if (stateOf(result).start_display.getText()) |txt| {
        try std.testing.expectEqualStrings("Mar 15, 2026", txt.content);
    } else try std.testing.expect(false);
    if (stateOf(result).end_display.getText()) |txt| {
        try std.testing.expectEqualStrings("Mar 28, 2026", txt.content);
    } else try std.testing.expect(false);
}

test "DateRangePicker: selecting range keeps open until completed" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    result.open.?.set(true);
    stateOf(result).selectDate(.{ .year = 2026, .month = 3, .day = 28 });
    try std.testing.expect(result.open.?.peek());
    try std.testing.expect(stateOf(result).start_date != null);
    try std.testing.expect(stateOf(result).end_date == null);

    stateOf(result).selectDate(.{ .year = 2026, .month = 3, .day = 28 });
    try std.testing.expect(result.open.?.peek());
    try std.testing.expectEqual(@as(u8, 28), stateOf(result).start_date.?.day);
    try std.testing.expect(stateOf(result).end_date == null);

    stateOf(result).selectDate(.{ .year = 2026, .month = 3, .day = 15 });
    try std.testing.expect(!result.open.?.peek());
    try std.testing.expectEqual(@as(u8, 15), stateOf(result).start_date.?.day);
    try std.testing.expectEqual(@as(u8, 28), stateOf(result).end_date.?.day);
}

test "DateRangePicker: 翻月不在 scope 里累积日期格资源" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const before = stateOf(result).scope.resources.items.len;
    var i: usize = 0;
    while (i < 6) : (i += 1) stateOf(result).nextMonth();
    stateOf(result).prevMonth();
    try std.testing.expectEqual(before, stateOf(result).scope.resources.items.len);
}

test "DateRangePicker: hover preview marks pending range when only start selected" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    stateOf(result).start_date = .{ .year = 2026, .month = 3, .day = 15 };
    stateOf(result).end_date = null;
    stateOf(result).view_year = 2026;
    stateOf(result).view_month = 3;
    try rebuildPanels(stateOf(result));
    setPreviewEndDate(stateOf(result), .{ .year = 2026, .month = 3, .day = 20 });

    var start_ref: ?DayCellRefs = null;
    var middle_ref: ?DayCellRefs = null;
    var end_ref: ?DayCellRefs = null;
    var after_ref: ?DayCellRefs = null;
    for (stateOf(result).day_cell_refs.items) |refs| {
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 15 })) start_ref = refs;
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 16 })) middle_ref = refs;
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 20 })) end_ref = refs;
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 21 })) after_ref = refs;
    }

    try std.testing.expect(start_ref != null);
    try std.testing.expect(middle_ref != null);
    try std.testing.expect(end_ref != null);
    try std.testing.expect(after_ref != null);

    try std.testing.expect(Color.eql(start_ref.?.cell_node.getBackground(), ctx.tokens.tokens.color.accent));
    // Ph7UE / Q9ZBB: range interior uses selection_bg.
    try std.testing.expect(Color.eql(middle_ref.?.cell_node.getBackground(), ctx.tokens.tokens.color.selection_bg));
    // RxE0k: hover preview is a light selection with an accent outline.
    try std.testing.expect(Color.eql(end_ref.?.cell_node.getBackground(), ctx.tokens.tokens.color.selection_bg));
    try std.testing.expectEqual(@as(f32, 1), end_ref.?.cell_node.style.border.width);
    try std.testing.expect(Color.eql(end_ref.?.cell_node.style.border.color, ctx.tokens.tokens.color.accent));
    try std.testing.expect(Color.eql(after_ref.?.cell_node.getBackground(), Color.TRANSPARENT));

    setPreviewEndDate(stateOf(result), null);
    try std.testing.expect(Color.eql(middle_ref.?.cell_node.getBackground(), Color.TRANSPARENT));
    try std.testing.expect(Color.eql(end_ref.?.cell_node.getBackground(), Color.TRANSPARENT));
}

test "DateRangePicker: open render emits month day texts after prewarm settles" {
    // History: also needs multi-frame settle (popover prewarm is multi-frame path).
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 640);

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 640 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    stateOf(result).view_year = 2026;
    stateOf(result).view_month = 3;
    try rebuildPanels(stateOf(result));

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.open.?.set(true);

    var day_text_count: usize = 0;
    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
        const commands = ctx.lowerForEncoderPaintTable();
        day_text_count = 0;
        for (commands) |cmd| {
            if (cmd.isText()) {
                const txt = cmd;
                const content = txt.text_content;
                if (content.len >= 1 and content.len <= 2) {
                    const parsed = std.fmt.parseInt(u8, content, 10) catch continue;
                    if (parsed >= 1 and parsed <= 31) day_text_count += 1;
                }
            }
        }
        if (day_text_count >= 56) break;
    }

    try std.testing.expect(day_text_count >= 56);
}

test "DateRangePicker: open render emits day texts in panel after prewarm settles" {
    // History: also needs multi-frame settle (popover prewarm is multi-frame path).
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 640);

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 640 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    stateOf(result).view_year = 2026;
    stateOf(result).view_month = 3;
    try rebuildPanels(stateOf(result));

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.open.?.set(true);

    var commands: []const @import("../../core.zig").paint_table.DisplayItem = &.{};
    var first_day_idx: ?usize = null;
    var second_day_idx: ?usize = null;
    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
        commands = ctx.lowerForEncoderPaintTable();
        first_day_idx = null;
        second_day_idx = null;
        for (commands, 0..) |cmd, i| {
            if (cmd.isText()) {
                const txt = cmd;
                if (txt.text_content.len < 1 or txt.text_content.len > 2) continue;
                const parsed = std.fmt.parseInt(u8, txt.text_content, 10) catch continue;
                if (parsed < 1 or parsed > 31) continue;
                if (first_day_idx == null) {
                    first_day_idx = i;
                } else if (second_day_idx == null and i != first_day_idx.?) {
                    second_day_idx = i;
                }
            }
        }
        if (first_day_idx != null and second_day_idx != null) break;
    }

    // post-P6.3 DateRangePicker panel uses composited_group surface. assert real invariant 'both
    // month day texts rendered', not old opacity-layer
    // wrap (promoted-surface path drops children, see docs/BUGS.md).
    try std.testing.expect(first_day_idx != null);
    try std.testing.expect(second_day_idx != null);
}

test "DateRangePicker: disabled stays inert and keeps overlay collapsed" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 640);

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 640 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .disabled = true,
    }).mount(scope, ctx);
    stateOf(result).view_year = 2026;
    stateOf(result).view_month = 3;
    try rebuildPanels(stateOf(result));
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();

    // stays closed: static disable no click attached, toggle does not flip.
    try std.testing.expect(!result.open.?.peek());

    // Structure assertion: the old `children.len >= 2` + `children[1]` is overlay no longer holds
    // (not a regression). Popover's detach_hidden_content defaults to true, so closed overlay
    // content is detached from the tree entirely (see popover.zig detachPopoverContentIfSuspended)
    // and the wrapper has only the trigger child.
    // Assert the real invariant: only the trigger is in the tree, marked inert.
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);

    const trigger = result.wrapper.children.items[0];
    try std.testing.expect(trigger.behavior.events.on_click == null);

    // trigger still normal layout (disabled not collapsed to 0);
    // closed 'zero size' now shown as overlay left tree, not zero rect in tree.
    const trigger_rect = trigger.rectFromWorldOrFallback();
    try std.testing.expect(trigger_rect.w > 0);
    try std.testing.expect(trigger_rect.h > 0);

    // a11y side still marked disabled.
    try std.testing.expect(result.wrapper.behavior.interaction.a11y.?.disabled);
}

test "DateRangePicker: trigger 主体槽吃满剩余宽度，chevron 贴右" {
    // regression: old version all children flat on trigger with no justify, chevron tight after
    // 'End date',
    // 320-wide trigger right side ~109px empty; long text pushes chevron out of trigger.
    const testing = std.testing;
    // second set: narrow trigger cannot fit content -> main slot shrinks clip, chevron stays in
    // trigger right-stuck.
    // (placeholder kept under 16 bytes: updateDisplayLabel uses setInlineContent, overflow
    // truncated)
    inline for (.{ .{ "Start date", "End date", 320 }, .{ "Sixteen byte str", "Sixteen byte end", 200 } }) |ph| {
        var ctx = try Cx.init(testing.allocator, std.testing.io);
        defer ctx.deinit();
        ctx.setViewport(640, 480);
        const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(testing.allocator, null, ctx.owner);
        defer scope.dispose();

        const result = try DateRangePicker(.{ .placeholder_start = ph[0], .placeholder_end = ph[1], .width = ph[2] }).mount(scope, ctx);
        try root.appendChild(testing.allocator, result.wrapper);
        ctx.layout();

        // global rect (icon / chevron each in own slot); padding / gap from ControlShell actual
        // style.
        const tn = stateOf(result).trigger_node;
        const trigger = tn.globalRect();
        const icon_slot = tn.children.items[0].globalRect();
        const slot = stateOf(result).start_display.parent.?.globalRect();
        const chevron = stateOf(result).chevron_node.globalRect();

        try testing.expectApproxEqAbs(@as(f32, ph[2]), trigger.w, 0.5);
        try testing.expect(stateOf(result).start_display.parent.? != stateOf(result).trigger_node);
        try testing.expectApproxEqAbs(trigger.x + trigger.w - tn.style.padding.right, chevron.x + chevron.w, 0.5);
        try testing.expectApproxEqAbs(icon_slot.x + icon_slot.w + tn.style.gap, slot.x, 0.5);
        try testing.expectApproxEqAbs(chevron.x - tn.style.gap, slot.x + slot.w, 0.5);
    }
}

test "DateRangePicker: placeholder 超过 16 字节时完整显示，销毁不 Invalid free" {
    // regression: core.text dupes >16-byte content to owned heap text; mount end updateDisplayLabel
    // rewrites same TextProps with setInlineContent but keeps owned=true, node destroy frees
    // inline_buf.
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .placeholder_start = "A very long start placeholder",
        .placeholder_end = "An equally long end placeholder",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    // fully displayed (not truncated by 16-byte inline buffer), destroy does not Invalid free
    // (defer override).
    try std.testing.expectEqualStrings("A very long start placeholder", stateOf(result).start_display.getText().?.content);
    try std.testing.expectEqualStrings("An equally long end placeholder", stateOf(result).end_display.getText().?.content);
}

// test collection from styles.zig, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

test "DateRangePicker: the first click is a draft — nothing is proposed until the range is complete" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const stay = try scope.createSignal(?DateRange, null);
    var changes: u32 = 0;
    const result = try DateRangePicker(.{ .value = stay, .on_change = ctx.on(u32, &changes, struct {
        fn f(c: *u32, _: DateRange) void {
            c.* += 1;
        }
    }.f) }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const st = stateOf(result);
    result.open.?.set(true);
    st.selectDate(.{ .year = 2026, .month = 3, .day = 20 });
    try std.testing.expect(stay.peek() == null); // draft does not reach data source
    try std.testing.expectEqual(@as(u32, 0), changes);
    try std.testing.expectEqual(@as(u8, 20), st.start_date.?.day);

    // external write overrides draft
    stay.set(DateRange{ .start = .{ .year = 2026, .month = 5, .day = 1 }, .end = .{ .year = 2026, .month = 5, .day = 3 } });
    try std.testing.expectEqual(@as(u8, 5), st.start_date.?.month);
    try std.testing.expectEqual(@as(u8, 3), st.end_date.?.day);
    try std.testing.expectEqual(@as(u32, 0), changes);

    // two clicks complete range: propose, close, on_change
    st.selectDate(.{ .year = 2026, .month = 3, .day = 20 });
    st.selectDate(.{ .year = 2026, .month = 3, .day = 10 });
    try std.testing.expectEqual(@as(u8, 10), stay.peek().?.start.day);
    try std.testing.expectEqual(@as(u8, 20), stay.peek().?.end.day);
    try std.testing.expect(!result.open.?.peek());
    try std.testing.expectEqual(@as(u32, 1), changes);
}

test "DateRangePicker: a split parent can refuse — the draft is dropped and the stored range shown" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Parent = struct {
        v: *Signal(?DateRange),
        fn write(_: *@This(), _: ?DateRange) void {} // all reject
    };
    var parent = Parent{ .v = try scope.createSignal(?DateRange, DateRange{ .start = .{ .year = 2026, .month = 1, .day = 5 }, .end = .{ .year = 2026, .month = 1, .day = 9 } }) };
    const result = try DateRangePicker(.{ .value = reactive.split(parent.v, ctx.on(Parent, &parent, Parent.write)) }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const st = stateOf(result);
    st.selectDate(.{ .year = 2026, .month = 3, .day = 1 });
    st.selectDate(.{ .year = 2026, .month = 3, .day = 4 });
    try std.testing.expectEqual(@as(u8, 1), st.start_date.?.month);
    try std.testing.expectEqual(@as(u8, 9), st.end_date.?.day);
    try std.testing.expectEqualStrings("Jan 5, 2026", st.start_display.getText().?.content);
}

test "DateRangePicker: reopening resets the draft and shows the start month" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 700);
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{ .value = DateRange{ .start = .{ .year = 2026, .month = 6, .day = 2 }, .end = .{ .year = 2026, .month = 6, .day = 9 } } }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    const st = stateOf(result);
    st.nextMonth();
    st.nextMonth();
    st.selectDate(.{ .year = 2026, .month = 8, .day = 1 }); // draft
    _ = ctx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, st.trigger_node);
    try std.testing.expect(result.open.?.peek());
    try std.testing.expectEqual(@as(u8, 6), st.view_month);
    try std.testing.expectEqual(@as(u8, 2), st.start_date.?.day);
    try std.testing.expectEqual(@as(u8, 9), st.end_date.?.day);
}

test "DateRangePicker: 只选了起点就关闭时，草稿丢弃，触发器回到数据源的值" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 700);
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const open = try scope.createSignal(bool, false);
    const result = try DateRangePicker(.{
        .value = DateRange{ .start = .{ .year = 2026, .month = 6, .day = 2 }, .end = .{ .year = 2026, .month = 6, .day = 9 } },
        .open = open,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    const st = stateOf(result);
    open.set(true);
    st.selectDate(.{ .year = 2026, .month = 6, .day = 20 }); // draft start, not proposed
    try std.testing.expectEqual(@as(u8, 20), st.start_date.?.day);
    open.set(false); // click outside / Esc close
    try std.testing.expectEqual(@as(u8, 2), st.start_date.?.day);
    try std.testing.expectEqual(@as(u8, 9), st.end_date.?.day);
    try std.testing.expectEqualStrings("Jun 2, 2026", st.start_display.getText().?.content);
}

test "date_range_picker: 受控值的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("date_range_picker(bound)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const v = try scope.createSignal(?DateRange, DateRange{ .start = .{ .year = 2026, .month = 9, .day = 1 }, .end = .{ .year = 2026, .month = 9, .day = 3 } });
            return (try DateRangePicker(.{ .value = v }).mount(scope, cx)).wrapper;
        }
    }.m);
}

// per-allocation-point OOM sweep, see src/ui/components/oom_sweep.zig
test "date_range_picker: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("date_range_picker", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try DateRangePicker(.{}).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}

test "DateRangePicker: disabled 来自 signal —— 禁用时点击不开合；外部打开同样重置草稿与可视月份" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(900, 700);
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const d = try scope.createSignal(bool, true);
    const result = try DateRangePicker(.{ .disabled = d, .value = DateRange{ .start = .{ .year = 2026, .month = 6, .day = 2 }, .end = .{ .year = 2026, .month = 6, .day = 9 } } }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    const st = stateOf(result);
    const click = core.Event{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } };
    _ = ctx.dispatcher.dispatch(click, st.trigger_node);
    try std.testing.expect(!result.open.?.peek());
    d.set(false);
    _ = ctx.dispatcher.dispatch(click, st.trigger_node);
    try std.testing.expect(result.open.?.peek());

    result.open.?.set(false);
    st.nextMonth();
    st.selectDate(.{ .year = 2026, .month = 7, .day = 1 }); // draft
    result.open.?.set(true);
    try std.testing.expectEqual(@as(u8, 6), st.view_month);
    try std.testing.expectEqual(@as(u8, 2), st.start_date.?.day);
}

test "DateRangePicker: confirmation holds draft, cancel discards, apply commits" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const r = try DateRangePicker(.{ .confirm_selection = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);
    const state = stateOf(r);
    r.open.?.set(true);
    state.selectDate(.{ .year = 2026, .month = 10, .day = 12 });
    try std.testing.expect(state.apply_disabled.?.peek());
    state.selectDate(.{ .year = 2026, .month = 10, .day = 18 });
    try std.testing.expect(!state.apply_disabled.?.peek());
    try std.testing.expect(r.open.?.peek());
    try std.testing.expect(r.value.?.peek() == null);
    DateRangePickerState.cancel(state);
    try std.testing.expect(!r.open.?.peek());
    try std.testing.expect(state.start_date == null);
    r.open.?.set(true);
    state.selectDate(.{ .year = 2026, .month = 10, .day = 18 });
    state.selectDate(.{ .year = 2026, .month = 10, .day = 12 });
    DateRangePickerState.apply(state);
    try std.testing.expect(!r.open.?.peek());
    try std.testing.expectEqual(@as(u8, 12), r.value.?.peek().?.start.day);
    try std.testing.expectEqual(@as(u8, 18), r.value.?.peek().?.end.day);
}

test "DateRangePicker: dynamic disabled recolors both dates and separator" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const disabled = try scope.createSignal(bool, false);
    const r = try DateRangePicker(.{ .disabled = disabled, .value = DateRange{ .start = .{ .year = 2026, .month = 10, .day = 12 }, .end = .{ .year = 2026, .month = 10, .day = 18 } } }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);
    const state = stateOf(r);
    disabled.set(true);
    for ([_]*Node{ state.start_display, state.end_display, state.dash_display }) |node| {
        try std.testing.expect(node.getText().?.color.eql(ctx.tokens.tokens.color.fg_disabled));
    }
    // The frame eases to its disabled background (transition target).
    const bg_slot = state.trigger_node.frame_state.frame_local.runtime.transitions.?.find(.background).?;
    try std.testing.expect((if (bg_slot.active) bg_slot.to_color else state.trigger_node.getBackground()).eql(ctx.tokens.tokens.color.disabled_bg));
    disabled.set(false);
    try std.testing.expect(state.start_display.getText().?.color.eql(ctx.tokens.tokens.color.fg_primary));
    try std.testing.expect(state.end_display.getText().?.color.eql(ctx.tokens.tokens.color.fg_primary));
}
