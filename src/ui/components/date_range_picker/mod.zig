/// DateRangePicker Component
///
/// 区间日期选择器，基于 Popover + 双月面板
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
const Scope = @import("../../reactive.zig").Scope;
const hooks = @import("../../hooks.zig");
const popover_mod = @import("../popover/mod.zig");
const Popover = popover_mod.Popover;
const calendar_mod = @import("../calendar/mod.zig");
const SimpleDate = calendar_mod.SimpleDate;
const svg_assets = @import("../../svg_assets.zig");
const styles = @import("styles.zig");

pub const DateRangePickerProps = struct {
    placeholder_start: []const u8 = "Start date",
    placeholder_end: []const u8 = "End date",
    start_date: ?SimpleDate = null,
    end_date: ?SimpleDate = null,
    initial_year: u16 = 2025,
    initial_month: u8 = 1,
    width: f32 = 320,
    /// 控件尺寸（与 Button / Input / Select 同一 ControlSize，默认 md）
    size: theme.ControlSize = .md,
    disabled: bool = false,
    on_change: ?core.HandlerRef = null,
    calendar_icon_asset: ?svg_assets.Asset = null,
    prev_icon_asset: ?svg_assets.Asset = null,
    next_icon_asset: ?svg_assets.Asset = null,
    test_id: ?[]const u8 = null,
};

pub const DateRangePickerState = struct {
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
    is_open: *Signal(bool),
    on_change: ?core.HandlerRef,
    placeholder_start: []const u8,
    placeholder_end: []const u8,
    cx: *Cx,
    scope: *Scope,
    day_cell_refs: std.ArrayListUnmanaged(DayCellRefs),
    /// a11y: trigger value_text（"Mar 10, 2026 – Mar 12, 2026"）与左右月 grid
    /// label 的持久存储 —— a11y 投影每帧读这些 slice，栈上 buf 会悬垂。
    a11y_value_buf: [64]u8 = undefined,
    left_grid_a11y_buf: [24]u8 = undefined,
    right_grid_a11y_buf: [24]u8 = undefined,
    /// 日期格事件上下文：左右两月各 42 槽，随 state 存活、每次 rebuild 复用。
    /// 此前每次 rebuild 都 adoptResource 新 ctx 进长寿 scope，翻月即单调增长。
    day_ctxs: [2][42]DayCellCtx = undefined,

    pub fn selectDate(self: *DateRangePickerState, date: SimpleDate) void {
        self.preview_end_date = null;
        if (self.start_date == null or self.end_date != null) {
            self.start_date = date;
            self.end_date = null;
            self.view_year = date.year;
            self.view_month = date.month;
            updateDisplayLabel(self);
            syncTriggerVisual(self, self.is_open.peek());
            rebuildPanels(self) catch @panic("OOM: DateRangePicker 重建面板失败（日期/视图状态已改，不重建会让状态与画面永久不一致）");
            return;
        }

        const start = self.start_date.?;
        const cmp = compareDate(date, start);
        if (cmp < 0) {
            self.start_date = date;
            self.end_date = start;
            self.view_year = date.year;
            self.view_month = date.month;
        } else if (cmp == 0) {
            return;
        } else {
            self.end_date = date;
        }

        updateDisplayLabel(self);
        syncTriggerVisual(self, self.is_open.peek());
        rebuildPanels(self) catch @panic("OOM: DateRangePicker 重建面板失败（日期/视图状态已改，不重建会让状态与画面永久不一致）");
        self.is_open.set(false);
        if (self.on_change) |handler| handler.invoke();
    }

    fn currentRightMonth(self: *const DateRangePickerState) MonthCursor {
        return nextMonthCursor(self.view_year, self.view_month);
    }

    pub fn prevMonth(self: *DateRangePickerState) void {
        const prev = previousMonthCursor(self.view_year, self.view_month);
        self.preview_end_date = null;
        self.view_year = prev.year;
        self.view_month = prev.month;
        rebuildPanels(self) catch @panic("OOM: DateRangePicker 重建面板失败（日期/视图状态已改，不重建会让状态与画面永久不一致）");
    }

    pub fn nextMonth(self: *DateRangePickerState) void {
        const next = nextMonthCursor(self.view_year, self.view_month);
        self.preview_end_date = null;
        self.view_year = next.year;
        self.view_month = next.month;
        rebuildPanels(self) catch @panic("OOM: DateRangePicker 重建面板失败（日期/视图状态已改，不重建会让状态与画面永久不一致）");
    }
};

pub const DateRangePickerResult = struct {
    wrapper: *Node,
    state: *DateRangePickerState,
};

pub fn DateRangePicker(props: DateRangePickerProps) DateRangePickerBuilder {
    return .{ .props = props };
}

pub const DateRangePickerBuilder = struct {
    props: DateRangePickerProps,

    pub fn mount(self: DateRangePickerBuilder, scope: *Scope, cx: *Cx) !DateRangePickerResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const pop_result = try Popover(.{
            .position = .bottom_start,
            .trigger = if (p.disabled) .manual else .click,
            .offset = .{ .static = 8 },
            .flip = false,
            .close_on_outside_click = true,
            .close_on_escape = true,
            // prewarm 已默认关闭：CA-pure surface 首开帧即完整渲染（逐帧截图验证），无需隐藏副本预热。
        }).mount(my_scope, cx);

        // sweep：Popover 的 wrapper 由本组件持有，守到 return；子树建好即 adopt
        errdefer cx.freeNode(pop_result.wrapper);
        // 失败时 hooks（useAnimatedBackground 等）登记在 my_scope 上、destroy 会解引用节点：
        // 必须先 dispose my_scope（连带 Popover 子 scope 解绑）再 freeNode —— errdefer 逆序，后声明的先跑。
        errdefer my_scope.dispose();
        pop_result.wrapper.meta.ownership.meta.component_name = "DateRangePicker";
        pop_result.wrapper.behavior.interaction.a11y = .{ .role = .textbox, .disabled = p.disabled };
        if (p.test_id) |tid| pop_result.wrapper.meta.ownership.meta.test_id = tid;

        pop_result.content.setBackgroundRaw(Color.TRANSPARENT);
        pop_result.content.style.border = .{};
        pop_result.content.style.padding = Padding.ZERO;
        const pop_content_ext = try pop_result.content.style.ensureExtFallible(allocator);
        pop_content_ext.clearShadows();
        pop_content_ext.hit_shape = .auto;
        pop_content_ext.clip_shape = .auto;

        const has_any_value = p.start_date != null or p.end_date != null;
        const cm = t.control.get(p.size);
        // 与 Input / Select / DatePicker 同一个 ControlShell（.field）：icon_slot = 日历图标、
        // content_slot = 起止文本（grow，可收缩裁剪）、append_slot = chevron。
        const shell = try control_shell.controlShell(.{
            .size = p.size,
            .variant = .field,
            .disabled = p.disabled,
            .leading_icon = true,
            .style = .{
                .width = .{ .px = p.width },
                .background = t.color.bg_primary,
                .border = .{ .width = 1, .color = styles.triggerBorderColor(false, has_any_value, t), .radius = cm.radius },
            },
            .interactive = false,
            .focus_ring = false,
            .cursor = if (p.disabled) .not_allowed else .pointer,
        }, my_scope, cx);
        var icon_slot_detached = true;
        errdefer if (icon_slot_detached) cx.freeNode(shell.icon_slot);
        var append_slot_detached = true;
        errdefer if (append_slot_detached) cx.freeNode(shell.append_slot);
        const trigger = try core.adoptChild(cx, allocator, pop_result.trigger, shell.node);
        trigger.tag = .button;
        // a11y: combobox + dialog popup；expanded/value_text 由
        // syncTriggerVisual / updateDisplayLabel 跟随交互更新。
        trigger.behavior.interaction.a11y = .{
            .role = .combobox,
            .has_popup = .dialog,
            .label = "Date range",
            .disabled = p.disabled,
            .expanded = false,
        };
        try assignTestId(allocator, trigger, p.test_id, ".trigger");

        const content = shell.content_slot;
        content.style.width = .{ .grow = .{ .min = 0 } };
        content.style.flex_shrink = 1;
        content.style.overflow_hidden = true;
        content.style.gap = cm.gap;
        (try content.style.ensureExtFallible(allocator)).min_width = 0;

        const calendar_icon = try core.adoptChild(cx, allocator, shell.icon_slot, try core.iconTint(cx, p.calendar_icon_asset orelse svg_assets.common.calendar, styles.leadingIconTint(has_any_value, t), .{
            .width = .{ .px = cm.icon_size },
            .height = .{ .px = cm.icon_size },
        }));
        try trigger.replaceChildOrder(allocator, &.{ shell.icon_slot, content });
        icon_slot_detached = false;

        const start_display = try core.adoptChild(cx, allocator, content, try core.text(cx, p.placeholder_start, .{}));
        if (start_display.getText()) |old| {
            var txt = old;
            const rs = styles.rangeTextStyle(t, cm);
            txt.color = rs.color;
            txt.font_size = rs.font_size;
            txt.line_height = rs.line_height;
            start_display.setText(txt);
        }
        try assignTestId(allocator, start_display, p.test_id, ".start");

        const dash_display = try core.adoptChild(cx, allocator, content, try core.text(cx, "–", .{}));
        if (dash_display.getText()) |old| {
            var txt = old;
            const rs = styles.rangeTextStyle(t, cm);
            txt.color = rs.color;
            txt.font_size = rs.font_size;
            txt.line_height = rs.line_height;
            dash_display.setText(txt);
        }
        try assignTestId(allocator, dash_display, p.test_id, ".dash");

        const end_display = try core.adoptChild(cx, allocator, content, try core.text(cx, p.placeholder_end, .{}));
        if (end_display.getText()) |old| {
            var txt = old;
            const rs = styles.rangeTextStyle(t, cm);
            txt.color = rs.color;
            txt.font_size = rs.font_size;
            txt.line_height = rs.line_height;
            end_display.setText(txt);
        }
        try assignTestId(allocator, end_display, p.test_id, ".end");

        const chevron = try core.adoptChild(cx, allocator, shell.append_slot, try core.iconTint(cx, svg_assets.common.chevron_down, styles.chevronTint(false, t), .{
            .width = .{ .px = cm.icon_size },
            .height = .{ .px = cm.icon_size },
        }));
        append_slot_detached = false;
        _ = try core.adoptChild(cx, allocator, trigger, shell.append_slot);

        // panelStyle 内含 shadow（BoxStyle.shadow → ensureExt.setShadow，等价旧的手动 ext 写入）
        // panel 先建并挂进 popover content，两个月份区 / 分隔条建好即 adopt（mountMonthSection 自守）
        const panel = try core.adoptChild(cx, allocator, pop_result.content, try box(cx, styles.panelStyle(t), .{}));
        panel.meta.ownership.meta.component_name = "DateRangePickerPanel";
        try assignTestId(allocator, panel, p.test_id, ".panel");
        const panel_ext = try panel.style.ensureExtFallible(allocator);
        panel_ext.hit_shape = .{ .rounded_rect = styles.panel_radius };
        panel_ext.clip_shape = .{ .rounded_rect = styles.panel_radius };
        const left_month = try mountMonthSection(cx, allocator, true, false, p.prev_icon_asset orelse svg_assets.common.chevron_left, p.next_icon_asset orelse svg_assets.common.chevron_right);
        _ = try core.adoptChild(cx, allocator, panel, left_month.container);
        _ = try core.adoptChild(cx, allocator, panel, try box(cx, styles.panelDividerStyle(t), .{}));
        const right_month = try mountMonthSection(cx, allocator, false, true, p.prev_icon_asset orelse svg_assets.common.chevron_left, p.next_icon_asset orelse svg_assets.common.chevron_right);
        _ = try core.adoptChild(cx, allocator, panel, right_month.container);

        const state = try allocator.create(DateRangePickerState);
        state.* = .{
            .start_date = p.start_date,
            .end_date = p.end_date,
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
            .view_year = p.initial_year,
            .view_month = p.initial_month,
            .today_date = calendar_mod.currentLocalDate(),
            .is_open = pop_result.is_open,
            .on_change = p.on_change,
            .placeholder_start = p.placeholder_start,
            .placeholder_end = p.placeholder_end,
            .cx = cx,
            .scope = my_scope,
            .day_cell_refs = .{},
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s = @as(*DateRangePickerState, @ptrCast(@alignCast(ptr)));
                s.day_cell_refs.deinit(alloc);
                alloc.destroy(s);
            }
        }.cleanup);
        panel.behavior.events.on_leave = core.Cx.simpleHandler(panelLeaveHandler, @ptrCast(state));

        const prev_ctx = try allocator.create(NavClickCtx);
        prev_ctx.* = .{ .state = state, .dir = .prev };
        try my_scope.adoptResource(@ptrCast(prev_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*NavClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        const nav_anim = styles.iconBtnAnimColors(t);
        if (left_month.nav_btn) |prev_btn| {
            prev_btn.behavior.events.on_click = core.Cx.simpleHandler(navClickHandler, @ptrCast(prev_ctx));
            _ = try hooks.useAnimatedBackground(my_scope, cx, prev_btn, .{ .normal = nav_anim.normal, .hover = nav_anim.hover });
            try assignTestId(allocator, prev_btn, p.test_id, ".prev");
        }

        const next_ctx = try allocator.create(NavClickCtx);
        next_ctx.* = .{ .state = state, .dir = .next };
        try my_scope.adoptResource(@ptrCast(next_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*NavClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        if (right_month.nav_btn) |next_btn| {
            next_btn.behavior.events.on_click = core.Cx.simpleHandler(navClickHandler, @ptrCast(next_ctx));
            _ = try hooks.useAnimatedBackground(my_scope, cx, next_btn, .{ .normal = nav_anim.normal, .hover = nav_anim.hover });
            try assignTestId(allocator, next_btn, p.test_id, ".next");
        }

        const open_ctx = try allocator.create(OpenEffectCtx);
        open_ctx.* = .{ .state = state };
        try my_scope.adoptResource(@ptrCast(open_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*OpenEffectCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        try my_scope.createEffect(.{ .is_open = pop_result.is_open, .ctx = open_ctx }, struct {
            fn update(c: anytype) void {
                const oc: *OpenEffectCtx = c.ctx;
                syncTriggerVisual(oc.state, c.is_open.get());
            }
        }.update);

        updateDisplayLabel(state);
        syncTriggerVisual(state, false);
        try rebuildPanels(state);

        return .{ .wrapper = pop_result.wrapper, .state = state };
    }
};

const Signal = core.Signal;

const NavDir = enum { prev, next };

const NavClickCtx = struct {
    state: *DateRangePickerState,
    dir: NavDir,
};

const OpenEffectCtx = struct {
    state: *DateRangePickerState,
};

const DayCellCtx = struct {
    state: *DateRangePickerState,
    date: SimpleDate,
    node: *Node,
    /// a11y: cell 完整日期 label（"March 15, 2026"）的持久存储；ctx 与节点
    /// 同生命周期（scope 资源）。
    a11y_label_buf: [40]u8 = undefined,
    a11y_label_len: usize = 0,
};

const DayCellRefs = struct {
    date: SimpleDate,
    in_current_month: bool,
    cell_node: *Node,
    text_node: *Node,
    last_visual: ?styles.DayCellVisual = null,
};

const MonthSectionRefs = struct {
    container: *Node,
    title: *Node,
    grid: *Node,
    nav_btn: ?*Node,
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
    const raw = std.c.getenv("ZENIT_DRP_PREVIEW_TRACE");
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
    ctx.node.setStyle(null, .background, ctx.state.cx.tokens.color.bg_hover);
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
    if (state.cx.mouse_x >= rect.x and state.cx.mouse_x <= rect.x + rect.w and
        state.cx.mouse_y >= rect.y and state.cx.mouse_y <= rect.y + rect.h)
    {
        return;
    }
    if (state.preview_end_date != null) setPreviewEndDate(state, null);
}

fn passiveHoverHandler(_: *anyopaque) void {}

fn mountMonthSection(cx: *Cx, allocator: Allocator, show_prev: bool, show_next: bool, prev_icon: svg_assets.Asset, next_icon: svg_assets.Asset) !MonthSectionRefs {
    const t = cx.tokens;

    const container = try box(cx, styles.monthSectionStyle(t), .{});
    // sweep：container 守到 return；子节点建好即 adopt
    errdefer cx.freeNode(container);

    const header = try core.adoptChild(cx, allocator, container, try box(cx, styles.monthHeaderStyle(t), .{}));

    var nav_btn: ?*Node = null;
    if (show_prev) {
        const btn = try core.adoptChild(cx, allocator, header, try iconButton(cx, prev_icon));
        nav_btn = btn;
    } else {
        _ = try core.adoptChild(cx, allocator, header, try spacerNode(cx));
    }

    const title = try core.adoptChild(cx, allocator, header, try core.text(cx, "", .{}));
    if (title.getText()) |old| {
        var txt = old;
        const ts = styles.monthTitleTextStyle(t);
        txt.color = ts.color;
        txt.font_size = ts.font_size;
        txt.font_weight = ts.font_weight;
        title.setText(txt);
    }

    if (show_next) {
        const btn = try core.adoptChild(cx, allocator, header, try iconButton(cx, next_icon));
        nav_btn = btn;
    } else {
        _ = try core.adoptChild(cx, allocator, header, try spacerNode(cx));
    }

    const weekday_wrap = try core.adoptChild(cx, allocator, container, try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .justify = .center,
    }, .{}));
    const weekday_row = try core.adoptChild(cx, allocator, weekday_wrap, try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
    }, .{}));
    const weekdays = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };
    for (weekdays) |wd| {
        const wd_cell = try core.adoptChild(cx, allocator, weekday_row, try box(cx, styles.weekdayCellStyle(t), .{}));
        var wd_txt = styles.weekdayTextStyle(t);
        wd_txt.content = wd;
        wd_cell.setText(wd_txt);
    }

    const grid_wrap = try core.adoptChild(cx, allocator, container, try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .justify = .center,
    }, .{}));
    grid_wrap.style.cursor = .pointer;
    grid_wrap.behavior.events.on_hover = core.Cx.simpleHandler(passiveHoverHandler, @ptrCast(grid_wrap));
    const grid = try core.adoptChild(cx, allocator, grid_wrap, try box(cx, styles.monthGridStyle(t), .{}));
    grid.behavior.events.on_hover = core.Cx.simpleHandler(passiveHoverHandler, @ptrCast(grid));

    return .{ .container = container, .title = title, .grid = grid, .nav_btn = nav_btn };
}

fn iconButton(cx: *Cx, icon_asset: svg_assets.Asset) !*Node {
    const t = cx.tokens;
    const allocator = cx.allocator;
    const btn = try box(cx, styles.iconBtnStyle(t), .{});
    errdefer cx.freeNode(btn);
    btn.style.cursor = .pointer;
    const icon = try core.iconTint(cx, icon_asset, t.color.fg_secondary, .{ .width = .{ .px = styles.nav_icon_size }, .height = .{ .px = styles.nav_icon_size } });
    _ = try core.adoptChild(cx, allocator, btn, icon);
    return btn;
}

fn spacerNode(cx: *Cx) !*Node {
    return try box(cx, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 } }, .{});
}

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

    // a11y: 左右两个月面板各是一个 grid，label 跟随视图月份
    const left_a11y = formatMonthYear(state.view_year, state.view_month, &state.left_grid_a11y_buf);
    state.left_grid.behavior.interaction.a11y = .{ .role = .grid, .label = left_a11y };
    const right_a11y = formatMonthYear(right.year, right.month, &state.right_grid_a11y_buf);
    state.right_grid.behavior.interaction.a11y = .{ .role = .grid, .label = right_a11y };

    try rebuildMonthGrid(state, state.left_grid, state.view_year, state.view_month);
    try rebuildMonthGrid(state, state.right_grid, right.year, right.month);
}

fn rebuildMonthGrid(state: *DateRangePickerState, grid: *Node, year: u16, month: u8) !void {
    while (grid.children.items.len > 0) {
        const child = grid.children.items[grid.children.items.len - 1];
        state.cx.detachChild(grid, child);
        state.cx.freeNode(child);
    }
    try buildMonthGrid(state, grid, year, month);
}

fn buildMonthGrid(state: *DateRangePickerState, grid: *Node, year: u16, month: u8) !void {
    const allocator = state.cx.allocator;
    var cells: [42]CalendarCell = undefined;
    const count = buildCalendarCells(year, month, &cells);

    var row: usize = 0;
    while (row * 7 < count) : (row += 1) {
        // sweep：行 / 格 / 文字建好即 adopt
        const week_row = try core.adoptChild(state.cx, allocator, grid, try box(state.cx, styles.weekRowStyle(state.cx.tokens), .{}));
        // a11y: 每个星期行是 grid 的一个 row（weekday 标题行占 row_index 0）
        week_row.behavior.interaction.a11y = .{
            .role = .row,
            .row_index = @intCast(row + 1),
        };

        var col: usize = 0;
        while (col < 7) : (col += 1) {
            const idx = row * 7 + col;
            if (idx >= count) break;

            const cell = cells[idx];
            const date = cell.date;
            const is_current_month = cell.in_current_month;

            if (!is_current_month) {
                _ = try core.adoptChild(state.cx, allocator, week_row, try box(state.cx, styles.dayPlaceholderStyle(state.cx.tokens), .{}));
                continue;
            }

            const visual = styles.computeDayCellVisual(state, date, is_current_month);

            const day_cell = try core.adoptChild(state.cx, allocator, week_row, try box(state.cx, styles.dayCellBoxStyle(visual), .{}));
            day_cell.style.cursor = .pointer;
            (try day_cell.style.ensureExtFallible(allocator)).corner_radius = visual.corner_radius;

            // 该 grid 的旧格节点已在 rebuildMonthGrid 开头全部释放，槽位可安全复用
            const day_ctx = &state.day_ctxs[if (grid == state.right_grid) 1 else 0][idx];
            day_ctx.* = .{ .state = state, .date = date, .node = day_cell };

            // a11y: gridcell + 含年月日的完整 label + 端点选中态 + 今天标记
            const cell_label = std.fmt.bufPrint(&day_ctx.a11y_label_buf, "{s} {d}, {d}", .{
                monthName(date.month), date.day, date.year,
            }) catch "";
            day_ctx.a11y_label_len = cell_label.len;
            const is_endpoint = (state.start_date != null and date.eql(state.start_date.?)) or
                (state.end_date != null and date.eql(state.end_date.?));
            const is_today = state.today_date != null and date.eql(state.today_date.?);
            day_cell.behavior.interaction.a11y = .{
                .role = .gridcell,
                .label = day_ctx.a11y_label_buf[0..day_ctx.a11y_label_len],
                .selected = is_endpoint,
                .description = if (is_today) "Today" else null,
                .row_index = @intCast(row + 1),
                .column_index = @intCast(col),
            };

            day_cell.behavior.events.on_event = dayClickHandler;
            day_cell.behavior.events.event_context = @ptrCast(day_ctx);
            day_cell.behavior.events.on_hover = core.Cx.simpleHandler(dayHoverHandler, @ptrCast(day_ctx));
            day_cell.behavior.events.on_leave = core.Cx.simpleHandler(dayLeaveHandler, @ptrCast(day_ctx));

            var num_buf: [4]u8 = undefined;
            const day_str = std.fmt.bufPrint(&num_buf, "{d}", .{date.day}) catch "?";
            const text_node = try core.adoptChild(state.cx, allocator, day_cell, try core.text(state.cx, day_str, .{}));
            if (text_node.getText()) |old| {
                var txt = old;
                try txt.setContent(state.cx.allocator, day_str);
                txt.color = visual.text_color;
                txt.font_size = styles.day_font_size;
                txt.font_weight = visual.font_weight;
                text_node.setText(txt);
            }
            try state.day_cell_refs.append(allocator, .{
                .date = date,
                .in_current_month = is_current_month,
                .cell_node = day_cell,
                .text_node = text_node,
                .last_visual = visual,
            });
        }
    }
}

fn updateDisplayLabel(state: *DateRangePickerState) void {
    const t = state.cx.tokens;

    {
        var buf: [24]u8 = undefined;
        const label = if (state.start_date) |date| formatDisplayDate(date, &buf) else state.placeholder_start;
        // 分配式写入：inline 缓冲只有 16 字节，调用方给的 placeholder 会被截断。
        state.start_display.setTextContent(state.cx.allocator, label) catch {};
        if (state.start_display.getText()) |old| {
            var txt = old;
            txt.color = styles.valueTextColor(state.start_date != null, t);
            state.start_display.setText(txt);
        }
    }
    state.start_display.markRenderDirty();

    {
        var buf: [24]u8 = undefined;
        const label = if (state.end_date) |date| formatDisplayDate(date, &buf) else state.placeholder_end;
        // 分配式写入：inline 缓冲只有 16 字节，调用方给的 placeholder 会被截断。
        state.end_display.setTextContent(state.cx.allocator, label) catch {};
        if (state.end_display.getText()) |old| {
            var txt = old;
            txt.color = styles.valueTextColor(state.end_date != null, t);
            state.end_display.setText(txt);
        }
    }
    state.end_display.markRenderDirty();

    if (state.dash_display.getText()) |old| {
        var txt = old;
        txt.setInlineContent("–") catch unreachable; // 3 字节字面量
        txt.color = styles.dashColor(state.start_date != null or state.end_date != null, t);
        state.dash_display.setText(txt);
    }
    state.dash_display.markRenderDirty();

    // a11y: 范围的可读描述写回 trigger value（"Mar 10, 2026 – Mar 12, 2026"）；
    // 完全无选择时撤回为 null（form_field 的可撤回模式）。
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

fn syncTriggerVisual(state: *DateRangePickerState, open: bool) void {
    // a11y: expanded 跟随开合（form_field 的"状态跟随交互"模式）
    if (state.trigger_node.behavior.interaction.a11y) |*a| a.expanded = open;
    state.trigger_node.markRenderDirty();

    const t = state.cx.tokens;
    const has_value = state.start_date != null or state.end_date != null;
    state.trigger_node.setBorderColor(styles.triggerBorderColor(open, has_value, t));

    _ = state.leading_icon_node.setTint(styles.leadingIconTint(has_value, t));
    _ = state.chevron_node.setTint(styles.chevronTint(open, t));
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

fn dayOfWeek(year: u16, month: u8, day: u8) u8 {
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

test "DateRangePicker: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expect(result.state.start_date == null);
    try std.testing.expect(result.state.end_date == null);
    if (result.state.start_display.getText()) |txt| {
        try std.testing.expectEqualStrings("Start date", txt.content);
    } else try std.testing.expect(false);
}

test "a11y: DateRangePicker expanded/value 跟随范围选择且可撤回" {
    const testing = std.testing;
    var ctx = try Cx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(900, 700);
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);
    try root.appendChild(testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    // 断言 a11y 树（真正送给 AT 的），不是 props 结构体。
    const eid = core.ElementId.fromRaw(result.state.trigger_node.element_id_raw);
    {
        const n = ctx.accessibility_tree.get(eid).?;
        try testing.expectEqual(core.a11y_tree.Role.combobox, n.role);
        try testing.expect(n.state.haspopup);
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(@as(u64, 0), n.text_hash); // 无范围 → 无 value
    }

    // 打开 → expanded=true
    result.state.is_open.set(true);
    ctx.layout();
    _ = ctx.render();
    try testing.expect(ctx.accessibility_tree.get(eid).?.state.expanded);

    // 选起点（面板保持打开，value 是半程描述）
    result.state.selectDate(.{ .year = 2026, .month = 3, .day = 10 });
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(
        std.hash.Wyhash.hash(0, "Mar 10, 2026 – End date"),
        ctx.accessibility_tree.get(eid).?.text_hash,
    );

    // 选终点 → 面板关闭（expanded 撤回）+ 完整范围播报
    result.state.selectDate(.{ .year = 2026, .month = 3, .day = 12 });
    ctx.layout();
    _ = ctx.render();
    {
        const n = ctx.accessibility_tree.get(eid).?;
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(std.hash.Wyhash.hash(0, "Mar 10, 2026 – Mar 12, 2026"), n.text_hash);
    }

    // 端点 cell 的 gridcell 语义（重开范围起点会重置为新起点，可撤回）
    var found_selected: usize = 0;
    for (result.state.day_cell_refs.items) |ref| {
        const a = ref.cell_node.behavior.interaction.a11y orelse continue;
        if (a.selected) {
            found_selected += 1;
            try testing.expectEqual(core.A11yRole.gridcell, a.role);
        }
    }
    try testing.expectEqual(@as(usize, 2), found_selected); // 起点 + 终点

    // 再选一天 = 开启新范围 → 旧范围撤回，value 变半程
    result.state.selectDate(.{ .year = 2026, .month = 3, .day = 20 });
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(
        std.hash.Wyhash.hash(0, "Mar 20, 2026 – End date"),
        ctx.accessibility_tree.get(eid).?.text_hash,
    );
}

test "DateRangePicker: with initial range" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .start_date = .{ .year = 2026, .month = 3, .day = 15 },
        .end_date = .{ .year = 2026, .month = 3, .day = 28 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    if (result.state.start_display.getText()) |txt| {
        try std.testing.expectEqualStrings("Mar 15, 2026", txt.content);
    } else try std.testing.expect(false);
    if (result.state.end_display.getText()) |txt| {
        try std.testing.expectEqualStrings("Mar 28, 2026", txt.content);
    } else try std.testing.expect(false);
}

test "DateRangePicker: selecting range keeps open until completed" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.is_open.set(true);
    result.state.selectDate(.{ .year = 2026, .month = 3, .day = 28 });
    try std.testing.expect(result.state.is_open.peek());
    try std.testing.expect(result.state.start_date != null);
    try std.testing.expect(result.state.end_date == null);

    result.state.selectDate(.{ .year = 2026, .month = 3, .day = 28 });
    try std.testing.expect(result.state.is_open.peek());
    try std.testing.expectEqual(@as(u8, 28), result.state.start_date.?.day);
    try std.testing.expect(result.state.end_date == null);

    result.state.selectDate(.{ .year = 2026, .month = 3, .day = 15 });
    try std.testing.expect(!result.state.is_open.peek());
    try std.testing.expectEqual(@as(u8, 15), result.state.start_date.?.day);
    try std.testing.expectEqual(@as(u8, 28), result.state.end_date.?.day);
}

test "DateRangePicker: 翻月不在 scope 里累积日期格资源" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const before = result.state.scope.resources.items.len;
    var i: usize = 0;
    while (i < 6) : (i += 1) result.state.nextMonth();
    result.state.prevMonth();
    try std.testing.expectEqual(before, result.state.scope.resources.items.len);
}

test "DateRangePicker: hover preview marks pending range when only start selected" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 700 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.start_date = .{ .year = 2026, .month = 3, .day = 15 };
    result.state.end_date = null;
    result.state.view_year = 2026;
    result.state.view_month = 3;
    try rebuildPanels(result.state);
    setPreviewEndDate(result.state, .{ .year = 2026, .month = 3, .day = 20 });

    var start_ref: ?DayCellRefs = null;
    var middle_ref: ?DayCellRefs = null;
    var end_ref: ?DayCellRefs = null;
    var after_ref: ?DayCellRefs = null;
    for (result.state.day_cell_refs.items) |refs| {
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 15 })) start_ref = refs;
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 16 })) middle_ref = refs;
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 20 })) end_ref = refs;
        if (refs.date.eql(.{ .year = 2026, .month = 3, .day = 21 })) after_ref = refs;
    }

    try std.testing.expect(start_ref != null);
    try std.testing.expect(middle_ref != null);
    try std.testing.expect(end_ref != null);
    try std.testing.expect(after_ref != null);

    try std.testing.expect(Color.eql(start_ref.?.cell_node.getBackground(), ctx.tokens.color.accent));
    try std.testing.expect(Color.eql(middle_ref.?.cell_node.getBackground(), ctx.tokens.color.accent_subtle));
    try std.testing.expect(Color.eql(end_ref.?.cell_node.getBackground(), ctx.tokens.color.accent));
    try std.testing.expect(Color.eql(after_ref.?.cell_node.getBackground(), Color.TRANSPARENT));

    setPreviewEndDate(result.state, null);
    try std.testing.expect(Color.eql(middle_ref.?.cell_node.getBackground(), Color.TRANSPARENT));
    try std.testing.expect(Color.eql(end_ref.?.cell_node.getBackground(), Color.TRANSPARENT));
}

test "DateRangePicker: open render emits month day texts after prewarm settles" {
    // History: 同样需要多帧 settle (popover prewarm 是多帧路径)。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(900, 640);

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 640 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.state.is_open.set(true);

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
    // History: 同样需要多帧 settle (popover prewarm 是多帧路径)。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(900, 640);

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 640 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.state.is_open.set(true);

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

    // P6.3 后 DateRangePicker panel 走 composited_group surface。断言真正不变量「两个月的 day texts 被绘制」，而非旧的 opacity-layer
    // 包裹（那条 promoted-surface 路径会丢 children，见 docs/BUGS.md）。
    try std.testing.expect(first_day_idx != null);
    try std.testing.expect(second_day_idx != null);
}

test "DateRangePicker: disabled stays inert and keeps overlay collapsed" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(900, 640);

    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 640 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DateRangePicker(.{
        .disabled = true,
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();

    // 保持关闭：disabled 用 trigger = .manual，点击不会翻 is_open。
    try std.testing.expect(!result.state.is_open.peek());

    // 结构断言（原测试写的是 children.len >= 2 + children[1] 是 overlay）：
    // **已不成立，且不是回归。** Popover 的 detach_hidden_content 默认 true，
    // 关闭态的 overlay content 会被整个从树上摘下（见
    // popover.zig detachPopoverContentIfSuspended），所以 wrapper 下只剩
    // trigger 一个子节点。原断言是 pre-detach 时代的结构假设。
    // 这里改为断言真正的不变量：只有 trigger 在树上，且它 inert。
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);

    const trigger = result.wrapper.children.items[0];
    try std.testing.expect(trigger.behavior.events.on_click == null);

    // trigger 本身仍正常布局（disabled 不等于塌成 0）——
    // 关闭态的"零尺寸"现在体现在 overlay 已脱离树，而非留在树上占 0×0。
    const trigger_rect = trigger.rectFromWorldOrFallback();
    try std.testing.expect(trigger_rect.w > 0);
    try std.testing.expect(trigger_rect.h > 0);

    // a11y 侧仍标记 disabled。
    try std.testing.expect(result.wrapper.behavior.interaction.a11y.?.disabled);
}

test "DateRangePicker: trigger 主体槽吃满剩余宽度，chevron 贴右" {
    // 回归：旧版所有子项平铺在 trigger 上且无 justify，chevron 紧跟 "End date"，
    // 320 宽 trigger 右侧空 ~109px；长文本还会把 chevron 顶出 trigger。
    const testing = std.testing;
    // 第二组：窄 trigger 放不下内容 → 主体槽收缩裁剪，chevron 仍在 trigger 内贴右。
    // （placeholder 控制在 16 字节内：updateDisplayLabel 走 setInlineContent，超长会被截断）
    inline for (.{ .{ "Start date", "End date", 320 }, .{ "Sixteen byte str", "Sixteen byte end", 200 } }) |ph| {
        var ctx = try Cx.init(testing.allocator);
        defer ctx.deinit();
        ctx.setViewport(640, 480);
        const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(testing.allocator, null, ctx.owner);
        defer scope.dispose();

        const result = try DateRangePicker(.{ .placeholder_start = ph[0], .placeholder_end = ph[1], .width = ph[2] }).mount(scope, ctx);
        try root.appendChild(testing.allocator, result.wrapper);
        ctx.layout();

        // 全局 rect（图标 / chevron 各在自己的 slot 里）；padding / gap 取 ControlShell 实际样式。
        const tn = result.state.trigger_node;
        const trigger = tn.globalRect();
        const icon_slot = tn.children.items[0].globalRect();
        const slot = result.state.start_display.parent.?.globalRect();
        const chevron = result.state.chevron_node.globalRect();

        try testing.expectApproxEqAbs(@as(f32, ph[2]), trigger.w, 0.5);
        try testing.expect(result.state.start_display.parent.? != result.state.trigger_node);
        try testing.expectApproxEqAbs(trigger.x + trigger.w - tn.style.padding.right, chevron.x + chevron.w, 0.5);
        try testing.expectApproxEqAbs(icon_slot.x + icon_slot.w + tn.style.gap, slot.x, 0.5);
        try testing.expectApproxEqAbs(chevron.x - tn.style.gap, slot.x + slot.w, 0.5);
    }
}

test "DateRangePicker: placeholder 超过 16 字节时完整显示，销毁不 Invalid free" {
    // 回归：core.text 对 >16 字节内容 dupe 成 owned 堆文本；mount 末尾 updateDisplayLabel
    // 用 setInlineContent 改写同一 TextProps 却保留 owned=true，节点销毁时 free inline_buf。
    var ctx = try Cx.init(std.testing.allocator);
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
    // 完整显示（不被 16 字节 inline 缓冲截断），且销毁时不 Invalid free（defer 覆盖）。
    try std.testing.expectEqualStrings("A very long start placeholder", result.state.start_display.getText().?.content);
    try std.testing.expectEqualStrings("An equally long end placeholder", result.state.end_display.getText().?.content);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "date_range_picker: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("date_range_picker", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try DateRangePicker(.{ .initial_year = 2026, .initial_month = 9 }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
