/// DatePicker component: date picker based on Popover + Calendar.
///
/// Features:
/// - Input-style trigger
/// - Popup Calendar selection
/// - Selected date echo
/// - Signal-first: `value: Model(?SimpleDate)`; the embedded Calendar uses a split Model onto the
///   same data source
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const control_shell = @import("../control_shell/mod.zig");
const button_mod = @import("../button/mod.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Shadow = core.Shadow;
const Padding = core.Padding;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Model = reactive.Model;
const Source = reactive.Source;
const Handler = core.Handler;
const events = @import("../../events.zig");
const popover_mod = @import("../popover/mod.zig");
const Popover = popover_mod.Popover;
const calendar_mod = @import("../calendar/mod.zig");
const CalendarComp = calendar_mod.Calendar;
const Input = @import("../input/mod.zig").Input;
const SimpleDate = calendar_mod.SimpleDate;
const svg_assets = @import("../../svg_assets.zig");
const styles = @import("styles.zig");
const view = @import("../../view.zig");

pub const Time = struct { hour: u8 = 0, minute: u8 = 0, second: u8 = 0 };
pub const DateTime = struct { date: SimpleDate, time: Time = .{} };

/// DatePicker properties
pub const DatePickerProps = struct {
    placeholder: []const u8 = "Select date...",
    /// DateTime mode holds date/time as drafts until Apply. Date-only default stays immediate.
    show_time: bool = false,
    /// Atomic DateTime source. Set this for split/controlled date-time validation.
    /// A non-null local value, or a bound/split/controlled model, owns both parts.
    /// value/time_value are then ignored. Separate split/controlled parts are rejected.
    datetime_value: Model(?DateTime) = .{ .local = null },
    time_value: Model(Time) = .{ .local = .{} },
    /// Selected date: `?SimpleDate` uncontrolled init; `*Signal(?SimpleDate)` controlled
    /// (interaction writes directly); `ui.split` intercepts
    value: Model(?SimpleDate) = .{ .local = null },
    width: f32 = 220,
    /// Control size (same ControlSize as Button / Input / Select, default md)
    size: control_shell.ControlSize = .md,
    /// Disabled (can pass signal): when disabled, clicking trigger does not toggle
    disabled: Source(bool) = .{ .value = false },
    /// Panel toggle
    open: Model(bool) = .{ .local = false },
    on_open_change: ?Handler(bool) = null,
    /// Validation state; error border takes precedence over open/focus.
    invalid: Source(bool) = .{ .value = false },
    /// User selected date and landed, call (settled value)
    on_change: ?Handler(SimpleDate) = null,
    calendar_icon_asset: ?svg_assets.Asset = null,
    prev_icon_asset: ?svg_assets.Asset = null,
    next_icon_asset: ?svg_assets.Asset = null,
    test_id: ?[]const u8 = null,
};

fn usesDateTimeModel(p: DatePickerProps) bool {
    return switch (p.datetime_value) {
        .local => |v| v != null,
        else => true,
    };
}

/// DatePicker runtime (owned by Popover scope). view = f(value, open)
pub const DatePickerState = struct {
    value: reactive.Bound(?SimpleDate),
    datetime: ?reactive.Bound(?DateTime) = null,
    /// Currently displayed selected date (derived from data source)
    selected_date: ?SimpleDate = null,
    time: ?reactive.Bound(Time) = null,
    draft_date: ?*Signal(?SimpleDate) = null,
    fields: [3]?*Signal([]const u8) = .{ null, null, null },
    field_errors: [3]?*Signal([]const u8) = .{ null, null, null },
    apply_disabled: ?*Signal(bool) = null,
    draft_time: ?Time = null,
    display_node: *Node,
    trigger_node: *Node,
    leading_icon_node: *Node,
    chevron_node: *Node,
    panel_node: *Node,
    calendar_state: *calendar_mod.CalendarState = undefined,
    /// Panel toggle data source (shared with Popover)
    open: Source(bool),
    /// Request close / toggle: goes through Popover toggle pipeline
    close: Handler(void),
    toggle: Handler(void),
    disabled: Source(bool),
    invalid: Source(bool) = .{ .value = false },
    shown_open: bool = false,
    shown_disabled: bool = false,
    /// Trigger look the frame and icon tints follow (styleBy / tintBy); syncTriggerVisual writes it.
    trigger_look: *Signal(styles.TriggerLook),
    /// Embedded calendar visible month; reset to null on each open (follow selected date)
    calendar_month: *Signal(?calendar_mod.YearMonth),
    on_change: ?Handler(SimpleDate),
    placeholder: []const u8,
    cx: *Cx,
    /// a11y: trigger value_text ("Mar 22, 2026") persistent storage, a11y projection reads
    /// this slice every frame, stack buf becomes invalid.
    a11y_value_buf: [24]u8 = undefined,

    fn view(self: *DatePickerState, comptime tracked: bool) void {
        self.selected_date = self.currentDate(tracked);
        const open = self.open.read(tracked);
        _ = self.invalid.read(tracked);
        if (self.time) |time| _ = time.readAs(tracked);
        // On each open, calendar returns to month of selected date (regardless of opener: click /
        // external open write)
        if (open and !self.shown_open) {
            self.calendar_month.set(null);
            self.resetTimeDraft();
        }
        if (!open and self.shown_open) self.resetTimeDraft();
        self.shown_open = open;
        const disabled = self.disabled.read(tracked);
        if (disabled != self.shown_disabled) self.applyDisabled(disabled);
        updateDisplayLabel(self);
        syncTriggerVisual(self, open);
    }

    /// Dynamic disabled: disable styling by recipe, click entry gated by disabled
    fn applyDisabled(self: *DatePickerState, disabled: bool) void {
        self.shown_disabled = disabled;
        // Frame and cursor: the trigger shell (disabled parameter) and its look (syncTriggerVisual).
        if (self.trigger_node.behavior.interaction.a11y) |*a| a.disabled = disabled;
        self.trigger_node.markRenderDirty();
    }

    fn onTriggerClick(ptr: *anyopaque) void {
        const self: *DatePickerState = @ptrCast(@alignCast(ptr));
        if (self.disabled.peek()) return;
        self.toggle.invoke();
    }

    fn viewEffect(self: *DatePickerState) void {
        self.view(true);
    }

    /// Calendar select (via split write back) / Today: propose, close panel, call on_change (final
    /// step)
    fn pick(self: *DatePickerState, date: ?SimpleDate) void {
        const d = date orelse return;
        if (self.draft_date) |draft| {
            draft.set(d);
            return;
        }
        self.commitDate(d);
    }

    fn commitDate(self: *DatePickerState, d: SimpleDate) void {
        const on_change = self.on_change;
        const landed = self.value.commit(d);
        self.close.invoke();
        if (landed) |l| {
            if (l) |v| {
                if (on_change) |h| h.call(v);
            }
        }
    }
    fn currentDate(self: *DatePickerState, comptime tracked: bool) ?SimpleDate {
        if (self.datetime) |dt| return if (dt.readAs(tracked)) |v| v.date else null;
        return self.value.readAs(tracked);
    }

    fn currentTime(self: *DatePickerState, comptime tracked: bool) Time {
        if (self.datetime) |dt| return if (dt.readAs(tracked)) |v| v.time else .{};
        return self.time.?.readAs(tracked);
    }

    fn resetTimeDraft(self: *DatePickerState) void {
        if (self.time == null) return;
        self.draft_date.?.set(self.currentDate(false));
        const t = self.currentTime(false);
        for ([_]u8{ t.hour, t.minute, t.second }, 0..) |n, i| {
            var buf: [4]u8 = undefined;
            self.fields[i].?.set(std.fmt.bufPrint(&buf, "{d:0>2}", .{n}) catch "");
        }
    }

    fn timeEffect(self: *DatePickerState) void {
        const limits = [_]u8{ 23, 59, 59 };
        const errors = [_][]const u8{ "Hour must be 0–23", "Minute must be 0–59", "Second must be 0–59" };
        var parts: [3]u8 = undefined;
        var valid = true;
        for (0..3) |i| {
            const n = std.fmt.parseInt(u8, self.fields[i].?.get(), 10) catch 255;
            const ok = n <= limits[i];
            self.field_errors[i].?.set(if (ok) "" else errors[i]);
            valid = valid and ok;
            parts[i] = n;
        }
        self.draft_time = if (valid) .{ .hour = parts[0], .minute = parts[1], .second = parts[2] } else null;
        self.apply_disabled.?.set(!valid or self.draft_date.?.get() == null);
    }

    fn cancelTime(ptr: *anyopaque) void {
        const self: *DatePickerState = @ptrCast(@alignCast(ptr));
        self.resetTimeDraft();
        self.close.invoke();
    }

    fn applyTime(ptr: *anyopaque) void {
        const self: *DatePickerState = @ptrCast(@alignCast(ptr));
        if (self.disabled.peek()) return;
        const time = self.draft_time orelse return;
        const date = self.draft_date.?.peek() orelse return;
        const close = self.close;
        const on_change = self.on_change;
        if (self.datetime) |dt| {
            const proposal: ?DateTime = .{ .date = date, .time = time };
            const unchanged = std.meta.eql(dt.peek(), proposal);
            const landed = dt.commit(proposal);
            // Rejected proposals leave both parts and the open draft untouched.
            if (landed) |changed| {
                close.invoke();
                if (changed) |v| if (on_change) |h| h.call(v.date);
            } else if (unchanged) {
                close.invoke();
            }
        } else {
            // Legacy local/bound parts cannot reject or run write callbacks. Batch makes
            // all observers see the full value, including on_change and close handlers.
            const owner = self.cx.owner;
            owner.beginBatch();
            _ = self.time.?.commit(time);
            const landed = self.value.commit(date);
            owner.endBatch();
            close.invoke();
            if (landed) |changed| if (changed) |v| if (on_change) |h| h.call(v);
        }
    }
};

/// DatePicker mount result
pub const DatePickerResult = struct {
    wrapper: *Node,
    /// Selected date signal (`ui.split` -> null)
    value: ?*Signal(?SimpleDate),
    /// Toggle signal (`ui.split` -> null)
    open: ?*Signal(bool),
    time: ?*Signal(Time) = null,
    datetime: ?*Signal(?DateTime) = null,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: DatePickerResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

/// Date/time picker shares the trigger and calendar with DatePicker, with explicit Apply/Cancel.
pub fn DateTimePicker(props: anytype) DatePickerBuilder {
    var p = reactive.props.coerce(DatePickerProps, props);
    p.show_time = true;
    if (!@hasField(@TypeOf(props), "width")) p.width = 276;
    return .{ .props = p };
}

/// Create DatePicker: `W.DatePicker(.{ .value = due })`
pub fn DatePicker(props: anytype) DatePickerBuilder {
    return .{ .props = reactive.props.coerce(DatePickerProps, props) };
}

pub const DatePickerBuilder = struct {
    props: DatePickerProps,

    /// Preserve mode: mount
    pub fn mount(self: DatePickerBuilder, scope: *Scope, cx: *Cx) !DatePickerResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        if (p.show_time and !usesDateTimeModel(p)) {
            // Independent interceptors cannot promise all-or-nothing acceptance.
            switch (p.value) {
                .split, .controlled => return error.NonAtomicDateTimeModels,
                else => {},
            }
            switch (p.time_value) {
                .split, .controlled => return error.NonAtomicDateTimeModels,
                else => {},
            }
        }

        const disabled0 = p.disabled.peek();
        // Static disabled handled by shell; dynamic disabled styled by view via recipe
        const static_disabled = p.disabled.isStatic() and disabled0;

        // Popover
        const pop_result = try Popover(.{
            .position = .bottom_start,
            // Click handled by component itself (gated by disabled), toggle via same pipeline
            .trigger = .manual,
            .open = p.open,
            .on_open_change = p.on_open_change,
            .offset = .{ .static = 4 },
            .flip = false,
            .close_on_outside_click = true,
            .close_on_escape = true,
            // prewarm defaults off: CA-pure surface fully renders on first open frame
            // (frame-by-frame
            // screenshot verification), no hidden copy prewarming needed.
        }).mount(scope, cx);

        // sweep: Popover's wrapper held by this component, guarded to return; subtree built below
        // adopted immediately. freeNode disposes Popover scope first (all hooks/resources
        // registered above) then node.
        errdefer cx.freeNode(pop_result.wrapper);
        // All DatePicker resources, hooks and effects owned by Popover scope: calendar in portal,
        // freed together on unmount
        const my_scope = pop_result.scope;
        const datetime = if (p.show_time and usesDateTimeModel(p)) try reactive.resolveModel(?DateTime, my_scope, p.datetime_value) else null;
        const value = try reactive.resolveModel(?SimpleDate, my_scope, if (datetime != null) .{ .local = null } else p.value);
        const initial_value = if (datetime) |dt| (if (dt.peek()) |v| v.date else null) else value.readAs(false);
        pop_result.wrapper.meta.ownership.meta.component_name = "DatePicker";
        // wrapper is layout container only: semantics on trigger (combobox). Old role=.textbox
        // creates phantom "textbox" wrapper in AX tree containing combobox.
        pop_result.wrapper.behavior.interaction.a11y = .{ .disabled = disabled0 };
        if (p.test_id) |tid| {
            pop_result.wrapper.meta.ownership.meta.test_id = tid;
        }

        // Cancel Popover default chrome, DatePicker provides panel shell itself.
        pop_result.content.setBackgroundRaw(Color.TRANSPARENT);
        pop_result.content.style.border = .{};
        pop_result.content.style.padding = Padding.ZERO;
        const pop_content_ext = try pop_result.content.style.ensureExtFallible(allocator);
        pop_content_ext.clearShadows();
        pop_content_ext.hit_shape = .auto;
        pop_content_ext.clip_shape = .auto;

        // ---- Trigger: same ControlShell (.field) as Input / Select ----
        // icon_slot = calendar icon, content_slot = date text (grow, shrink-clip), append_slot =
        // chevron.
        // Geometry (padding / radius / line height / gap) all from ControlShell recipe, shell
        // height =
        // padding_y * 2 + line_height.
        const has_value = initial_value != null;
        const cm = control_shell.metrics(t, p.size);
        const trigger_look = try my_scope.createSignal(styles.TriggerLook, .{ .size = p.size, .width = p.width, .has_value = has_value, .invalid = p.invalid.peek(), .disabled = disabled0 });
        const icon_size: core.Sizing = .{ .px = cm.icon_size };
        var label_buf: [24]u8 = undefined;
        const display_text = if (initial_value) |date| formatDisplayDate(date, &label_buf) else p.placeholder;
        const TriggerParts = struct { leading_icon: *Node = undefined, display: *Node = undefined, chevron: *Node = undefined };
        var tparts: TriggerParts = .{};
        var shell: core.ViewParts = undefined;
        // The trigger is a ControlShell (structure, slots, cursor, disabled); the picker's look
        // stacks on it as an overlay following trigger_look.
        try view.mount(my_scope, cx, pop_result.trigger, view.attrs(.{ .style = view.styleBy(trigger_look, styles.triggerFrame) }, view.with(control_shell.ControlShell(.{
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
                .min_width = 0,
            },
        }), .{}).capture(&shell).slots(.{
            .icon = view.capture(&tparts.leading_icon, view.icon(.{
                .style = .{ .width = icon_size, .height = icon_size },
                .tint = view.tintBy(trigger_look, styles.triggerLeadingTint),
            }, p.calendar_icon_asset orelse svg_assets.common.calendar)),
            // Display text (view.text copies node-owned copy, label_buf only needs to live until
            // mount)
            .content = view.capture(&tparts.display, view.text(.{ .style = core.TextStyle{
                .color = styles.displayTextColor(has_value, t),
                .font_size = cm.font_size,
                .line_height = cm.line_height,
            } }, display_text)),
            .append = view.capture(&tparts.chevron, view.icon(.{
                .style = .{ .width = icon_size, .height = icon_size },
                .tint = view.tintBy(trigger_look, styles.triggerChevronTint),
            }, svg_assets.common.chevron_down)),
        })));
        const trigger = shell.root.?;
        // aria role combobox + haspopup=dialog (Calendar popover). expanded/value_text follow
        // open/selected date updates via syncTriggerA11y.
        trigger.behavior.interaction.a11y = .{
            .role = .combobox,
            .has_popup = .dialog,
            .label = p.placeholder,
            .disabled = disabled0,
            .expanded = false,
        };
        const leading_icon = tparts.leading_icon;
        const display_node = tparts.display;
        const chevron_icon = tparts.chevron;
        // test_id from p.test_id built at runtime, node holds copy (view's .test_id only borrows)
        if (p.test_id) |tid| {
            var buf: [128]u8 = undefined;
            const trigger_tid = std.fmt.bufPrint(&buf, "{s}.trigger", .{tid}) catch null;
            if (trigger_tid) |s| {
                trigger.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                trigger.frame_state.state_bits.flags.test_id_owned = (trigger.meta.ownership.meta.test_id != null);
            }
            const label_tid = std.fmt.bufPrint(&buf, "{s}.label", .{tid}) catch null;
            if (label_tid) |s| {
                display_node.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                display_node.frame_state.state_bits.flags.test_id_owned = (display_node.meta.ownership.meta.test_id != null);
            }
        }

        // ---- Runtime (calendar and Today both callback it) ----
        // Do failables before allocating state: no try between alloc and registration
        const calendar_month = try my_scope.createSignal(?calendar_mod.YearMonth, null);
        const state = try my_scope.allocator.create(DatePickerState);
        state.* = .{
            .value = value,
            .datetime = datetime,
            .selected_date = initial_value,
            .display_node = display_node,
            .trigger_node = trigger,
            .leading_icon_node = leading_icon,
            .chevron_node = chevron_icon,
            .panel_node = undefined,
            .open = pop_result.open_read,
            .close = pop_result.close,
            .toggle = pop_result.toggle,
            .disabled = p.disabled,
            .invalid = p.invalid,
            .shown_disabled = disabled0,
            .trigger_look = trigger_look,
            .calendar_month = calendar_month,
            .on_change = p.on_change,
            .placeholder = p.placeholder,
            .cx = cx,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*DatePickerState, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        if (p.show_time) {
            state.time = try reactive.resolveModel(Time, my_scope, if (datetime != null) .{ .local = .{} } else p.time_value);
            state.draft_date = try my_scope.createSignal(?SimpleDate, initial_value);
            state.apply_disabled = try my_scope.createSignal(bool, initial_value == null);
            const initial_time = state.currentTime(false);
            for ([_]u8{ initial_time.hour, initial_time.minute, initial_time.second }, 0..) |n, i| {
                var buf: [4]u8 = undefined;
                state.fields[i] = try my_scope.createText(std.fmt.bufPrint(&buf, "{d:0>2}", .{n}) catch "", .{});
                state.field_errors[i] = try my_scope.createSignal([]const u8, "");
            }
        }
        // Static disabled completely lazy (no click handler); dynamic disabled still hooks,
        // entry gated by disabled
        if (!static_disabled) pop_result.trigger.behavior.events.on_click = core.Cx.simpleHandler(DatePickerState.onTriggerClick, state);
        pop_result.wrapper.addDebugState(@ptrCast(state));

        // panel hung into popover content: calendar + Today. panelStyle has shadow
        // (BoxStyle.shadow -> ensureExt.setShadow, equivalent old manual ext write)
        const PanelParts = struct { panel: *Node = undefined, calendar: calendar_mod.CalendarResult = undefined, today: *Node = undefined };
        var parts: PanelParts = .{};
        try view.mount(my_scope, cx, pop_result.content, view.capture(&parts.panel, view.box(.{
            .style = .{
                styles.panelStyle(t),
                core.BoxStyle{
                    .hit_shape = .{ .rounded_rect = styles.panel_radius },
                    .clip_shape = .{ .rounded_rect = styles.panel_radius },
                    // Let panel blank area intercept pointer events, prevent pierce to underlying
                    // content
                    .hit_roles = .{ .pointer = true, .scroll = false, .inspect = true },
                },
            },
        }, .{
            // Calendar and DatePicker share same data source: read DatePicker value, write back
            // via pick proposal and close panel. Calendar inner no chrome, DatePicker panel shell
            // wraps it.
            view.attrs(.{ .style = core.BoxStyle{
                .width = .{ .grow = .{} },
                .background = Color.TRANSPARENT,
                .border = .{},
                .padding = Padding.ZERO,
            } }, view.capture(&parts.calendar, CalendarComp(.{
                .value = Model(?SimpleDate){ .split = .{
                    .read = if (state.draft_date) |draft| .{ .signal = draft } else value.read,
                    .write = reactive.Callback(?SimpleDate).from(DatePickerState, state, DatePickerState.pick),
                } },
                .month = state.calendar_month,
                .cell_size = 36,
                .prev_icon_asset = p.prev_icon_asset orelse svg_assets.common.chevron_left,
                .next_icon_asset = p.next_icon_asset orelse svg_assets.common.chevron_right,
            }))),
            // Today: Button component (size follows control metrics, hover via button animation);
            // override to shallow fill, no border, full width.
            if (!p.show_time) view.capture(&parts.today, button_mod.Button(.{
                .label = "Today",
                .variant = .ghost,
                .size = p.size,
                .base_style = styles.todayBtnOverride(t),
                .hover_style = .{ .background = t.tokens.color.bg_active },
                .on_click = core.Cx.simpleHandler(todayClickHandler, @ptrCast(state)),
            })) else null,
        })));
        const panel = parts.panel;
        panel.meta.ownership.meta.component_name = "DatePickerPanel";
        if (p.test_id) |tid| {
            var buf: [128]u8 = undefined;
            const panel_tid = std.fmt.bufPrint(&buf, "{s}.panel", .{tid}) catch null;
            if (panel_tid) |s| {
                panel.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                panel.frame_state.state_bits.flags.test_id_owned = (panel.meta.ownership.meta.test_id != null);
            }
        }
        state.panel_node = panel;
        state.calendar_state = @ptrCast(@alignCast(parts.calendar.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
        if (!p.show_time) {
            const today_btn = parts.today;
            if (p.test_id) |tid| {
                var buf: [128]u8 = undefined;
                const today_tid = std.fmt.bufPrint(&buf, "{s}.today", .{tid}) catch null;
                if (today_tid) |s| {
                    today_btn.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                    today_btn.frame_state.state_bits.flags.test_id_owned = (today_btn.meta.ownership.meta.test_id != null);
                }
            }
        }
        if (p.show_time) {
            var time_inputs: [3]@import("../input/mod.zig").InputResult = undefined;
            try view.mount(my_scope, cx, panel, view.col(.{ .style = styles.timeEditorStyle }, .{
                view.text(.{ .style = styles.timeHeadingStyle }, "TIME"),
                view.row(.{ .style = styles.timeFieldsStyle }, .{
                    view.capture(&time_inputs[0], Input(.{ .value = state.fields[0].?, .width = 76, .size = .sm, .placeholder = "HH", .error_msg = state.field_errors[0].? })),
                    view.capture(&time_inputs[1], Input(.{ .value = state.fields[1].?, .width = 76, .size = .sm, .placeholder = "MM", .error_msg = state.field_errors[1].? })),
                    view.capture(&time_inputs[2], Input(.{ .value = state.fields[2].?, .width = 76, .size = .sm, .placeholder = "SS", .error_msg = state.field_errors[2].? })),
                }),
            }));
            for (time_inputs) |input| {
                try input.input_container.setStyleInlineFallible(cx.allocator, styles.timeFieldStyle(t));
            }
            try view.mount(my_scope, cx, panel, view.row(.{ .style = styles.timeFooterStyle }, .{
                button_mod.Button(.{ .label = "Cancel", .variant = .secondary, .base_style = styles.timeButtonStyle(cx.tokens), .on_click = Cx.simpleHandler(DatePickerState.cancelTime, state) }),
                button_mod.Button(.{ .label = "Apply", .disabled = state.apply_disabled.?, .base_style = styles.timeButtonStyle(cx.tokens), .on_click = Cx.simpleHandler(DatePickerState.applyTime, state) }),
            }));
            try my_scope.createEffect(state, DatePickerState.timeEffect);
        }
        // view = f(value, open): display text, border / icon tint, a11y
        state.view(false);
        try my_scope.createEffect(state, DatePickerState.viewEffect);

        return .{ .wrapper = pop_result.wrapper, .value = if (datetime == null) value.asSignal() else null, .open = pop_result.open, .time = if (datetime == null and state.time != null) state.time.?.asSignal() else null, .datetime = if (datetime) |dt| dt.asSignal() else null };
    }
};

// ========== Internal helpers ==========

const Signal = core.Signal;

fn todayClickHandler(ctx_ptr: *anyopaque) void {
    const st: *DatePickerState = @ptrCast(@alignCast(ctx_ptr));
    const today = calendar_mod.currentLocalDate() orelse return;
    st.calendar_month.set(null); // calendar follows selected date, jumps to today's month
    st.pick(today);
}

fn updateDisplayLabel(state: *DatePickerState) void {
    var buf: [64]u8 = undefined;
    var date_buf: [24]u8 = undefined;
    const label = if (state.selected_date) |date| if (state.time != null) blk: {
        const t = state.currentTime(false);
        break :blk std.fmt.bufPrint(&buf, "{s} {d:0>2}:{d:0>2}:{d:0>2}", .{ formatDisplayDate(date, &date_buf), t.hour, t.minute, t.second }) catch "";
    } else formatDisplayDate(date, &buf) else state.placeholder;
    // Allocating write: inline buffer only 16 bytes, caller's placeholder truncated.
    state.display_node.setTextContent(state.cx.allocator, label) catch {};
    if (state.display_node.getText()) |old| {
        var txt = old;
        txt.color = styles.triggerForeground(state.selected_date != null, state.disabled.peek(), state.cx.tokens);
        state.display_node.setText(txt);
    }
    state.display_node.markRenderDirty();
}

/// a11y state follows interaction (form_field mode): expanded follows open, value_text
/// follows selected date. When the selection is retracted, value_text must also be retracted;
/// otherwise AT announces the old value that has already been cleared.
fn syncTriggerA11y(state: *DatePickerState, open: bool) void {
    if (state.trigger_node.behavior.interaction.a11y) |*a| {
        a.expanded = open;
        a.value_text = if (state.selected_date) |date|
            formatDisplayDate(date, &state.a11y_value_buf)
        else
            null;
    }
    state.trigger_node.markRenderDirty();
}

fn syncTriggerVisual(state: *DatePickerState, open: bool) void {
    syncTriggerA11y(state, open);
    const has_value = state.selected_date != null;

    var look = state.trigger_look.peek();
    look.open = open;
    look.has_value = has_value;
    look.invalid = state.invalid.peek();
    look.disabled = state.disabled.peek();
    state.trigger_look.set(look);
    if (state.trigger_node.behavior.interaction.a11y) |*a| a.invalid = look.invalid;
    state.chevron_node.setRotate(state.cx.allocator, if (open) std.math.pi else 0);
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

fn formatDisplayDate(date: SimpleDate, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ monthAbbrev(date.month), date.day, date.year }) catch "Invalid date";
}

// ========== Tests ==========

fn stateOf(r: DatePickerResult) *DatePickerState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

test "DatePicker: basic structure" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(stateOf(result).selected_date == null);
    if (stateOf(result).display_node.getText()) |txt| {
        try std.testing.expectEqualStrings("Select date...", txt.content);
    } else {
        try std.testing.expect(false);
    }
}

test "DatePicker: with initial date" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
        .value = SimpleDate{ .year = 2025, .month = 6, .day = 15 },
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(stateOf(result).selected_date != null);
    try std.testing.expectEqual(@as(u8, 15), stateOf(result).selected_date.?.day);
    if (stateOf(result).display_node.getText()) |txt| {
        try std.testing.expectEqualStrings("Jun 15, 2025", txt.content);
    } else {
        try std.testing.expect(false);
    }
}

test "DatePicker: selecting date updates label and closes popover" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    result.open.?.set(true);
    stateOf(result).calendar_state.selectDate(.{ .year = 2026, .month = 3, .day = 22 });

    try std.testing.expect(!result.open.?.peek());
    try std.testing.expectEqual(@as(u16, 2026), stateOf(result).selected_date.?.year);
    if (stateOf(result).display_node.getText()) |txt| {
        try std.testing.expectEqualStrings("Mar 22, 2026", txt.content);
    } else {
        try std.testing.expect(false);
    }
}

test "DatePicker: open render emits full calendar day texts after prewarm settles" {
    // History: test was "first open render already emits...", expected set(is_open=true) then
    // calendar texts visible next frame. Measured: popover prewarm path takes multiple frames for
    // panel content to enter render command stream (prewarm + animation init each frame). Changed
    // to run frames until settle. Reflects real behavior, user-perceived "open" is through
    // transition.
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{
        .width = .{ .px = 640 },
        .height = .{ .px = 480 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);
    stateOf(result).calendar_month.set(calendar_mod.YearMonth{ .year = 2026, .month = 3 });

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.open.?.set(true);

    // Run multiple frames for popover prewarm + entrance settle. Currently 2 frames measured
    // sufficient.
    var i: usize = 0;
    var day_text_count: usize = 0;
    var commands: []const @import("../../core.zig").paint_table.DisplayItem = &.{};
    while (i < 8) : (i += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
        commands = ctx.lowerForEncoderPaintTable();
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
        if (day_text_count >= 28) break;
    }

    try std.testing.expect(day_text_count >= 28);
}

test "DatePicker: open render emits day texts in panel after prewarm settles" {
    // History: likewise needs multiple frames to settle into panel render state (see prior test).
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{
        .width = .{ .px = 640 },
        .height = .{ .px = 480 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);
    stateOf(result).calendar_month.set(calendar_mod.YearMonth{ .year = 2026, .month = 3 });

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.open.?.set(true);

    var commands: []const @import("../../core.zig").paint_table.DisplayItem = &.{};
    var day_idx: ?usize = null;
    var today_idx: ?usize = null;
    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
        commands = ctx.lowerForEncoderPaintTable();
        day_idx = null;
        today_idx = null;
        for (commands, 0..) |cmd, i| {
            if (cmd.isText()) {
                const txt = cmd;
                if (std.mem.eql(u8, txt.text_content, "Today")) today_idx = i;
                if (day_idx == null and txt.text_content.len >= 1 and txt.text_content.len <= 2) {
                    const parsed = std.fmt.parseInt(u8, txt.text_content, 10) catch continue;
                    if (parsed >= 1 and parsed <= 31) day_idx = i;
                }
            }
        }
        if (day_idx != null and today_idx != null) break;
    }

    // P6.3 onward DatePicker panel uses composited_group surface. Assert true invariant
    // "day text + Today drawn", not old opacity-layer wrapper (promoted-surface path drops
    // children, see docs/BUGS.md).
    try std.testing.expect(day_idx != null);
    try std.testing.expect(today_idx != null);
}

test "DatePicker: disabled stays inert and keeps overlay collapsed" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
        .disabled = true,
    }).mount(scope, ctx);
    stateOf(result).calendar_month.set(calendar_mod.YearMonth{ .year = 2026, .month = 3 });
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();

    try std.testing.expect(!result.open.?.peek());
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    try std.testing.expect(result.wrapper.children.items[0].behavior.events.on_click == null);
    const detached_panel_host = stateOf(result).panel_node.parent.?;
    try std.testing.expect(detached_panel_host.parent == null);
    try std.testing.expectEqual(@as(f32, 0), detached_panel_host.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 0), detached_panel_host.rectFromWorldOrFallback().h);
}

test "DatePicker: first 10 open frames progress from enter state instead of flashing" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);
    stateOf(result).calendar_month.set(calendar_mod.YearMonth{ .year = 2026, .month = 3 });
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();

    result.open.?.set(true);
    const animated_container = stateOf(result).panel_node.parent.?;

    var opacities: [10]f32 = undefined;
    var scales: [10]f32 = undefined;
    var now_ms: f64 = 0;
    for (0..10) |i| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        ctx.layout();
        _ = ctx.render();
        opacities[i] = animated_container.getOpacity();
        scales[i] = animated_container.style.scale_x();
    }

    var first_visible_idx: ?usize = null;
    for (opacities, 0..) |opacity, i| {
        if (opacity > 0.0011) {
            first_visible_idx = i;
            break;
        }
    }

    if (first_visible_idx) |idx| {
        try std.testing.expect(opacities[idx] < 0.3);
        try std.testing.expect(scales[idx] < 1.0);

        var last_opacity = opacities[idx];
        var last_scale = scales[idx];
        for (opacities[(idx + 1)..], scales[(idx + 1)..]) |opacity, scale| {
            try std.testing.expect(opacity + 0.0001 >= last_opacity);
            try std.testing.expect(scale + 0.0001 >= last_scale);
            last_opacity = opacity;
            last_scale = scale;
        }
    }
}

test "a11y: DatePicker expanded/value 跟随开合与选择且可撤回" {
    const testing = std.testing;
    var ctx = try Cx.init(testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);
    stateOf(result).calendar_month.set(calendar_mod.YearMonth{ .year = 2026, .month = 3 });
    try root.appendChild(testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    // Assert a11y tree (what really reaches AT), not props struct.
    const eid = core.ElementId.fromRaw(stateOf(result).trigger_node.element_id_raw);
    {
        const n = ctx.accessibility_tree.getNode(eid).?;
        try testing.expectEqual(core.a11y_tree.Role.combobox, n.role);
        try testing.expect(n.state.haspopup);
        try testing.expect(n.state.expanded_present);
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(@as(u64, 0), n.text_hash); // unselected -> no value
    }

    // open -> expanded=true
    result.open.?.set(true);
    ctx.layout();
    _ = ctx.render();
    try testing.expect(ctx.accessibility_tree.getNode(eid).?.state.expanded);

    // select date -> panel close (expanded revert) + readable date announced
    stateOf(result).calendar_state.selectDate(.{ .year = 2026, .month = 3, .day = 22 });
    ctx.layout();
    _ = ctx.render();
    {
        const n = ctx.accessibility_tree.getNode(eid).?;
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(std.hash.Wyhash.hash(0, "Mar 22, 2026"), n.text_hash);
    }

    // clear selection -> value must revert (not keep announcing old date)
    result.value.?.set(null);
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(@as(u64, 0), ctx.accessibility_tree.getNode(eid).?.text_hash);
}

test "DatePicker: trigger 主体槽吃满剩余宽度，chevron 贴右（与 Select content_slot 同合同）" {
    // Regression: old version content slot fit width only held icon + text, leaving gap
    // with chevron (220w trigger ~88px empty); long text pushed chevron out. Second set: narrow
    // trigger cannot hold content -> content slot shrink-clip, chevron still right-attached.
    const testing = std.testing;
    // Second group: narrow trigger undersized -> content slot shrinks-clip, chevron stays
    // right-edge of trigger.
    inline for (.{ .{ "Pick a date", 220 }, .{ "A very long placeholder that cannot possibly fit inside", 120 } }) |case| {
        const placeholder = case[0];
        const w: f32 = case[1];
        var ctx = try Cx.init(testing.allocator, std.testing.io);
        defer ctx.deinit();
        ctx.setViewport(640, 480);
        const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(testing.allocator, null, ctx.owner);
        defer scope.dispose();

        const result = try DatePicker(.{ .placeholder = placeholder, .width = w }).mount(scope, ctx);
        try root.appendChild(testing.allocator, result.wrapper);
        ctx.layout();

        // All take global rect (chevron in append_slot, local rect differs frames); padding/gap
        // from trigger actual style (ControlShell recipe product).
        const tn = stateOf(result).trigger_node;
        const trigger = tn.globalRect();
        const icon_slot = tn.children.items[0].globalRect();
        const slot = stateOf(result).display_node.parent.?.globalRect();
        const chevron = stateOf(result).chevron_node.globalRect();
        const pad = tn.style.padding;
        const gap = tn.style.gap;

        try testing.expectApproxEqAbs(w, trigger.w, 0.5);
        // chevron tight to right padding edge
        try testing.expectApproxEqAbs(trigger.x + trigger.w - pad.right, chevron.x + chevron.w, 0.5);
        // content slot spans gap-after-icon through gap-before-chevron, no gap between
        try testing.expectApproxEqAbs(icon_slot.x + icon_slot.w + gap, slot.x, 0.5);
        try testing.expectApproxEqAbs(chevron.x - gap, slot.x + slot.w, 0.5);
    }
}

// Test collection from styles.zig, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

test "DatePicker: bound value — external set updates the label; picking writes back, closes, reports the landed date" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const due = try scope.createSignal(?SimpleDate, null);
    var changes: u32 = 0;
    const result = try DatePicker(.{ .value = due, .on_change = ctx.on(u32, &changes, struct {
        fn f(c: *u32, _: SimpleDate) void {
            c.* += 1;
        }
    }.f) }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const st = stateOf(result);

    due.set(SimpleDate{ .year = 2025, .month = 6, .day = 15 });
    try std.testing.expectEqualStrings("Jun 15, 2025", st.display_node.getText().?.content);
    try std.testing.expectEqual(@as(u8, 6), st.calendar_state.view_month); // calendar follows
    try std.testing.expectEqual(@as(u32, 0), changes);

    result.open.?.set(true);
    st.calendar_state.selectDate(.{ .year = 2025, .month = 6, .day = 20 });
    try std.testing.expectEqual(@as(u8, 20), due.peek().?.day);
    try std.testing.expect(!result.open.?.peek());
    try std.testing.expectEqual(@as(u32, 1), changes);
    try std.testing.expectEqualStrings("Jun 20, 2025", st.display_node.getText().?.content);
}

test "DatePicker: reopening shows the selected month even after navigating away" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(500, 500);
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{ .value = SimpleDate{ .year = 2025, .month = 6, .day = 15 } }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    const st = stateOf(result);
    st.calendar_state.nextMonth();
    st.calendar_state.nextMonth();
    try std.testing.expectEqual(@as(u8, 8), st.calendar_state.view_month);
    // user click trigger: view resets calendar month to follow selected date
    _ = ctx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, st.trigger_node);
    try std.testing.expect(result.open.?.peek());
    try std.testing.expectEqual(@as(u8, 6), st.calendar_state.view_month);

    // external open write likewise back to selected month
    result.open.?.set(false);
    st.calendar_state.nextMonth();
    result.open.?.set(true);
    try std.testing.expectEqual(@as(u8, 6), st.calendar_state.view_month);
}

test "DatePicker: disabled 来自 signal —— 禁用时点击不开合；open 可受控 / ui.split 拦截" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(500, 500);
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const d = try scope.createSignal(bool, true);
    const result = try DatePicker(.{ .disabled = d }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    const st = stateOf(result);
    const click = core.Event{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } };
    _ = ctx.dispatcher.dispatch(click, st.trigger_node);
    try std.testing.expect(!result.open.?.peek());
    try std.testing.expect(st.trigger_node.behavior.interaction.a11y.?.disabled);
    d.set(false);
    _ = ctx.dispatcher.dispatch(click, st.trigger_node);
    try std.testing.expect(result.open.?.peek());
    try std.testing.expect(!st.trigger_node.behavior.interaction.a11y.?.disabled);

    const Parent = struct {
        o: *Signal(bool),
        fn write(_: *@This(), _: bool) void {}
    };
    var parent = Parent{ .o = try scope.createSignal(bool, false) };
    const r2 = try DatePicker(.{ .open = reactive.split(parent.o, ctx.on(Parent, &parent, Parent.write)) }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r2.wrapper);
    ctx.layout();
    try std.testing.expect(r2.open == null);
    _ = ctx.dispatcher.dispatch(click, stateOf(r2).trigger_node);
    try std.testing.expect(!stateOf(r2).shown_open);
    parent.o.set(true);
    try std.testing.expect(stateOf(r2).shown_open);
}

// OOM sweep at each allocation point, see src/ui/components/oom_sweep.zig
test "date_picker: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("date_picker", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try DatePicker(.{}).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}

test "date_picker: 受控值的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("date_picker(bound)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const due = try scope.createSignal(?SimpleDate, SimpleDate{ .year = 2026, .month = 9, .day = 1 });
            const r = try DatePicker(.{ .value = due }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}

test "DateTimePicker: invalid time blocks Apply and cancel resets date/time draft" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 800 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const r = try DateTimePicker(.{ .value = @as(?SimpleDate, .{ .year = 2026, .month = 10, .day = 16 }), .time_value = Time{ .hour = 14, .minute = 30 } }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);
    const state = stateOf(r);
    r.open.?.set(true);
    state.fields[1].?.set("60");
    try std.testing.expect(state.apply_disabled.?.peek());
    DatePickerState.applyTime(state);
    try std.testing.expect(r.open.?.peek());
    try std.testing.expectEqual(@as(u8, 30), r.time.?.peek().minute);
    state.pick(.{ .year = 2026, .month = 10, .day = 18 });
    try std.testing.expectEqual(@as(u8, 16), r.value.?.peek().?.day);
    DatePickerState.cancelTime(state);
    try std.testing.expectEqualStrings("30", state.fields[1].?.peek());
    try std.testing.expectEqual(@as(u8, 16), state.draft_date.?.peek().?.day);
    r.open.?.set(true);
    state.pick(.{ .year = 2026, .month = 10, .day = 18 });
    state.fields[1].?.set("45");
    DatePickerState.applyTime(state);
    try std.testing.expect(!r.open.?.peek());
    try std.testing.expectEqual(@as(u8, 18), r.value.?.peek().?.day);
    try std.testing.expectEqual(@as(u8, 45), r.time.?.peek().minute);
}

test "review regression 10: separate rejecting date/time models cannot mount an atomic picker" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Reject = struct {
        fn date(_: *@This(), _: ?SimpleDate) void {}
        fn time(_: *@This(), _: Time) void {}
    };
    cx.root = try box(cx, .{}, .{});
    var reject: Reject = .{};
    const date = try scope.createSignal(?SimpleDate, .{ .year = 2026, .month = 10, .day = 16 });
    const time = try scope.createSignal(Time, .{ .hour = 14 });
    const a = DateTimePicker(.{ .value = reactive.split(date, cx.on(Reject, &reject, Reject.date)), .time_value = time }).mount(scope, cx);
    defer if (a) |r| cx.freeNode(r.wrapper) else |_| {};
    try std.testing.expectError(error.NonAtomicDateTimeModels, a);
    const b = DateTimePicker(.{ .value = date, .time_value = reactive.split(time, cx.on(Reject, &reject, Reject.time)) }).mount(scope, cx);
    defer if (b) |r| cx.freeNode(r.wrapper) else |_| {};
    try std.testing.expectError(error.NonAtomicDateTimeModels, b);
}

test "review regression 10: atomic split rejects either invalid part without partial writes" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try box(cx, .{}, .{});
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Parent = struct {
        value: *Signal(?DateTime),
        reject_date: bool,
        reject_time: bool,
        writes: usize = 0,
        fn write(self: *@This(), proposal: ?DateTime) void {
            self.writes += 1;
            const v = proposal orelse return;
            if (self.reject_date and v.date.day == 18) return;
            if (self.reject_time and v.time.minute == 45) return;
            self.value.set(v);
        }
    };
    for ([_]bool{ true, false }) |reject_date| {
        const initial: DateTime = .{ .date = .{ .year = 2026, .month = 10, .day = 16 }, .time = .{ .hour = 14, .minute = 30 } };
        var parent: Parent = .{ .value = try scope.createSignal(?DateTime, initial), .reject_date = reject_date, .reject_time = !reject_date };
        const r = try DateTimePicker(.{ .datetime_value = reactive.split(parent.value, cx.on(Parent, &parent, Parent.write)) }).mount(scope, cx);
        defer cx.freeNode(r.wrapper);
        const state = stateOf(r);
        r.open.?.set(true);
        state.pick(.{ .year = 2026, .month = 10, .day = 18 });
        state.fields[1].?.set("45");
        DatePickerState.applyTime(state);
        try std.testing.expectEqualDeep(@as(?DateTime, initial), parent.value.peek());
        try std.testing.expectEqual(@as(usize, 1), parent.writes);
        try std.testing.expect(r.open.?.peek());
        parent.reject_date = false;
        parent.reject_time = false;
        DatePickerState.applyTime(state);
        try std.testing.expectEqual(@as(u8, 18), parent.value.peek().?.date.day);
        try std.testing.expectEqual(@as(u8, 45), parent.value.peek().?.time.minute);
        try std.testing.expectEqual(@as(usize, 2), parent.writes);
        try std.testing.expect(!r.open.?.peek());
    }
}

test "review regression 10: legacy bound observers only see the complete date and time" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try box(cx, .{}, .{});
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Observer = struct {
        date: *Signal(?SimpleDate),
        time: *Signal(Time),
        partial: bool = false,
        fn run(self: *@This()) void {
            const t = self.time.get();
            const d = self.date.get();
            if (t.minute == 45 and d.?.day != 18) self.partial = true;
        }
    };
    var observer: Observer = .{
        .date = try scope.createSignal(?SimpleDate, .{ .year = 2026, .month = 10, .day = 16 }),
        .time = try scope.createSignal(Time, .{ .hour = 14, .minute = 30 }),
    };
    try scope.createEffect(&observer, Observer.run);
    const r = try DateTimePicker(.{ .value = observer.date, .time_value = observer.time }).mount(scope, cx);
    defer cx.freeNode(r.wrapper);
    r.open.?.set(true);
    const state = stateOf(r);
    state.pick(.{ .year = 2026, .month = 10, .day = 18 });
    state.fields[1].?.set("45");
    DatePickerState.applyTime(state);
    try std.testing.expect(!observer.partial);
    try std.testing.expectEqual(@as(u8, 18), observer.date.peek().?.day);
    try std.testing.expectEqual(@as(u8, 45), observer.time.peek().minute);
}
