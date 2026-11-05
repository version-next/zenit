/// Calendar component: month-view calendar.
///
/// Features:
/// - 7x6 month-view grid
/// - year/month nav
/// - date selection
/// - today highlight
/// - Signal-first: `value: Model(?SimpleDate)`, `month: Model(?YearMonth)` (null = follow selection
///   / today)
const std = @import("std");
const c = @import("calendar_time");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const theme = core.theme;
const svg_assets = @import("../../svg_assets.zig");
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Model = reactive.Model;
const Handler = core.Handler;
const events = @import("../../events.zig");
const view = @import("../../view.zig");
const button_mod = @import("../button/mod.zig");

const styles = @import("styles.zig");
const Event = events.Event;
const EventResult = events.EventResult;

/// simple date
pub const SimpleDate = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31

    pub fn eql(a: SimpleDate, b: SimpleDate) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

/// year-month (Calendar's visible month)
pub const YearMonth = struct {
    year: u16,
    month: u8, // 1-12
};

/// Calendar properties
pub const CalendarProps = struct {
    /// selected date: `?SimpleDate` uncontrolled initial; `*Signal(?SimpleDate)` controlled
    /// (interaction writes directly); `ui.split` intercepts
    value: Model(?SimpleDate) = .{ .local = null },
    /// visible month. null = follow selected date (or today if none); month-flip writes explicit
    /// month
    month: Model(?YearMonth) = .{ .local = null },
    /// call after user selects date and settled (settled value)
    on_select: ?Handler(SimpleDate) = null,
    cell_size: f32 = 36,
    prev_icon_asset: svg_assets.Asset = svg_assets.common.chevron_left,
    next_icon_asset: svg_assets.Asset = svg_assets.common.chevron_right,
};

/// Calendar runtime (scope-owned). view = f(value, month); keyboard cursor is internal visual state
pub const CalendarState = struct {
    value: reactive.Bound(?SimpleDate),
    month: reactive.Bound(?YearMonth),
    on_select: ?Handler(SimpleDate),
    /// currently displayed year-month / selected (derived from data sources; view_month = 0 means
    /// not built or needs rebuild)
    view_year: u16 = 0,
    view_month: u8 = 0,
    selected_date: ?SimpleDate = null,
    today_date: ?SimpleDate,
    container: *Node,
    grid: *Node,
    month_label: *Node,
    cx: *Cx,
    scope: *Scope,
    cell_size: f32,
    /// keyboard nav cursor, current 'focused day' on grid.
    /// null = never used keyboard nav (mouse user). lazy init on first arrow key:
    /// priority selected_date -> today_date -> view_year/month day 1.
    keyboard_cursor: ?SimpleDate = null,
    /// a11y: grid container value_text ("March 2026") persistent storage; a11y projection reads
    /// this slice
    /// every frame, stack buf becomes dangling.
    month_a11y_buf: [24]u8 = undefined,
    month_a11y_len: usize = 0,
    /// date cell event context: fixed 42 slots live with state, reused every rebuild.
    /// note: rebuild rewrites slot contents, read slots before proposals that might trigger
    /// rebuild.
    day_ctxs: [42]DayCellCtx = undefined,

    /// visible month: explicit month > selected date's month > today's month > 2025-01
    fn displayMonth(self: *const CalendarState, sel: ?SimpleDate, m: ?YearMonth) YearMonth {
        if (m) |ym| {
            if (ym.month >= 1 and ym.month <= 12 and ym.year >= 1) return ym;
        }
        if (sel) |d| return .{ .year = d.year, .month = d.month };
        if (self.today_date) |d| return .{ .year = d.year, .month = d.month };
        return .{ .year = 2025, .month = 1 };
    }

    fn view(self: *CalendarState, comptime tracked: bool) !void {
        const sel = self.value.readAs(tracked);
        const ym = self.displayMonth(sel, self.month.readAs(tracked));
        const same_sel = if (sel) |a| (if (self.selected_date) |b| a.eql(b) else false) else self.selected_date == null;
        if (same_sel and ym.year == self.view_year and ym.month == self.view_month) return;
        self.selected_date = sel;
        self.view_year = ym.year;
        self.view_month = ym.month;
        // invariant: keyboard cursor only exists in visible month. visible month determined by data
        // sources
        // (parent might rewrite month-flip to different month or write month directly from
        // outside), cursor clamped by day to
        // settled month
        if (self.keyboard_cursor) |kc| {
            if (kc.year != ym.year or kc.month != ym.month) {
                self.keyboard_cursor = .{ .year = ym.year, .month = ym.month, .day = @min(kc.day, daysInMonth(ym.year, ym.month)) };
            }
        }
        try self.rebuild();
    }

    fn viewEffect(self: *CalendarState) void {
        self.view(true) catch |err| std.log.err("[Calendar] update failed: {}", .{err});
    }

    /// rebuild grid; on failure mark view unbuilt, next data source change forces rebuild
    fn rebuild(self: *CalendarState) !void {
        errdefer self.view_month = 0;
        try rebuildGrid(self);
    }

    fn rebuildOrLog(self: *CalendarState) void {
        self.rebuild() catch |err| std.log.err("[Calendar] grid rebuild failed: {}", .{err});
    }

    pub fn prevMonth(self: *CalendarState) void {
        const m = previousMonth(self.view_year, self.view_month);
        _ = self.month.commit(.{ .year = m.year, .month = m.month });
    }

    pub fn nextMonth(self: *CalendarState) void {
        const m = calendarNextMonth(self.view_year, self.view_month);
        _ = self.month.commit(.{ .year = m.year, .month = m.month });
    }

    /// user selects date: view first jumps to month (clicked adjacent-month date), then propose
    /// selection;
    /// on_select may destroy component, must be last
    pub fn selectDate(self: *CalendarState, date: SimpleDate) void {
        const on_select = self.on_select;
        if (date.year != self.view_year or date.month != self.view_month) {
            _ = self.month.commit(.{ .year = date.year, .month = date.month });
        }
        const landed = self.value.commit(date) orelse return;
        if (landed) |d| {
            if (on_select) |h| h.call(d);
        }
    }

    /// keyboard event entry, return true = event consumed.
    /// handles <- -> cross-day, up/down cross-week, PageUp/PageDown cross-month, Home/End row
    /// edges, Enter select.
    pub fn handleKey(self: *CalendarState, key: core.KeyCode) bool {
        const cursor = self.keyboard_cursor orelse blk: {
            // lazy init: selected -> today -> current view month day 1
            const init = self.selected_date orelse self.today_date orelse SimpleDate{
                .year = self.view_year,
                .month = self.view_month,
                .day = 1,
            };
            self.keyboard_cursor = init;
            break :blk init;
        };
        switch (key) {
            .left => self.moveCursor(cursor, -1),
            .right => self.moveCursor(cursor, 1),
            .up => self.moveCursor(cursor, -7),
            .down => self.moveCursor(cursor, 7),
            .page_up => self.moveCursorMonth(cursor, -1),
            .page_down => self.moveCursorMonth(cursor, 1),
            .home => self.moveCursor(cursor, -@as(i32, @intCast(dayOfWeek(cursor.year, cursor.month, cursor.day)))),
            .end => self.moveCursor(cursor, 6 - @as(i32, @intCast(dayOfWeek(cursor.year, cursor.month, cursor.day)))),
            .@"return" => {
                self.selectDate(cursor);
                return true;
            },
            else => return false,
        }
        return true;
    }

    /// move cursor offset n days (positive/negative); propose new month on cross-month
    fn moveCursor(self: *CalendarState, from: SimpleDate, delta_days: i32) void {
        self.moveCursorTo(addDays(from, delta_days));
    }

    /// cursor is internal visual state: cross-month and month settled rebuilds by view effect
    /// (cursor already written;
    /// settled month rewritten by parent clamped by day to settled month); same month or parent
    /// rejected month-flip,
    /// rebuild here to draw cursor
    fn moveCursorTo(self: *CalendarState, target: SimpleDate) void {
        const prev = self.keyboard_cursor;
        self.keyboard_cursor = target;
        if (target.year != self.view_year or target.month != self.view_month) {
            if (self.month.commit(.{ .year = target.year, .month = target.month }) != null) return;
            // month-flip rejected: cursor outside current visible month has no meaning, revert
            self.keyboard_cursor = prev;
        }
        self.rebuildOrLog();
    }

    /// cross-month: try same day number, if new month has no this day take month end
    fn moveCursorMonth(self: *CalendarState, from: SimpleDate, delta_months: i32) void {
        var y: i32 = @as(i32, @intCast(from.year));
        var m: i32 = @as(i32, @intCast(from.month)) + delta_months;
        while (m < 1) {
            m += 12;
            y -= 1;
        }
        while (m > 12) {
            m -= 12;
            y += 1;
        }
        const new_year: u16 = @intCast(@max(1, y));
        const new_month: u8 = @intCast(m);
        const max_day = daysInMonth(new_year, new_month);
        const new_day = @min(from.day, max_day);
        self.moveCursorTo(.{ .year = new_year, .month = new_month, .day = new_day });
    }
};

/// add N days (positive/negative) to SimpleDate, cross-month cross-year auto-carry
fn addDays(from: SimpleDate, delta: i32) SimpleDate {
    var y: i32 = @intCast(from.year);
    var m: i32 = @intCast(from.month);
    var d: i32 = @as(i32, @intCast(from.day)) + delta;
    // carry forward
    while (d > daysInMonth(@intCast(@max(1, y)), @intCast(@max(1, m)))) {
        d -= daysInMonth(@intCast(@max(1, y)), @intCast(@max(1, m)));
        m += 1;
        if (m > 12) {
            m = 1;
            y += 1;
        }
    }
    // carry backward
    while (d < 1) {
        m -= 1;
        if (m < 1) {
            m = 12;
            y -= 1;
        }
        d += @as(i32, @intCast(daysInMonth(@intCast(@max(1, y)), @intCast(@max(1, m)))));
    }
    return .{
        .year = @intCast(@max(1, y)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// Calendar mount result
pub const CalendarResult = struct {
    wrapper: *Node,
    /// selected date signal (null when `ui.split`)
    value: ?*Signal(?SimpleDate),
    /// visible month signal (null when `ui.split`)
    month: ?*Signal(?YearMonth),
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: CalendarResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

/// create Calendar: `W.Calendar(.{ .value = due_date })`
pub fn Calendar(props: anytype) CalendarBuilder {
    return .{ .props = reactive.props.coerce(CalendarProps, props) };
}

pub const CalendarBuilder = struct {
    props: CalendarProps,

    /// retained mode: mount
    pub fn mount(self: CalendarBuilder, scope: *Scope, cx: *Cx) !CalendarResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const t = cx.tokens;
        const p = self.props;

        // RxE0k: seven 36px cells plus 12px panel insets = 276px.
        const panel_width = p.cell_size * 7 + 24;

        // ---- structure: Header (left-arrow Month Year right-arrow) / weekday titles / date grid
        // ----
        const Parts = struct { prev: *Node = undefined, month_label: *Node = undefined, next: *Node = undefined, grid: *Node = undefined };
        var parts: Parts = .{};
        const weekdays = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };
        // nav click contexts precede the view (Button takes on_event via props); state is filled
        // in once built. scope-owned: an error before bind is swept by my_scope.dispose.
        const prev_ctx = try createNavCtx(my_scope, .prev);
        const next_ctx = try createNavCtx(my_scope, .next);
        const container = try view.render(my_scope, cx, view.box(.{
            .style = styles.containerStyle(panel_width, t),
            // container focusable + ARIA grid role (keyboard handler attached after state built).
            // must precede buildGrid: buildGrid writes value_text / active_descendant to container
            // a11y
            // (month and keyboard cursor follow).
            .focusable = true,
            .a11y = .{ .role = .grid, .label = "Calendar" },
        }, .{
            view.box(.{ .style = styles.headerStyle(t) }, .{
                // previous month button
                view.capture(&parts.prev, navButton(p.prev_icon_asset, "Previous month", prev_ctx)),
                // month label: content written by first view apply (rebuildGrid)
                view.capture(&parts.month_label, view.text(.{ .style = styles.monthLabelTextStyle(t) }, "")),
                // next month button
                view.capture(&parts.next, navButton(p.next_icon_asset, "Next month", next_ctx)),
            }),
            // weekday title row
            view.box(.{ .style = core.BoxStyle{
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
                .direction = .row,
                .justify = .space_between,
            } }, view.listWith(t, &weekdays, weekdayCell)),
            // date grid: content rebuilt by rebuildGrid per visible month
            view.capture(&parts.grid, view.box(.{ .style = styles.gridStyle(t) }, {})),
        }));
        container.meta.ownership.meta.component_name = "Calendar";
        // sweep: container guarded until return
        errdefer cx.freeNode(container);
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;
        const value = try reactive.resolveModel(?SimpleDate, my_scope, p.value);
        const month = try reactive.resolveModel(?YearMonth, my_scope, p.month);
        const month_label = parts.month_label;
        const grid = parts.grid;

        // State
        const state = try my_scope.allocator.create(CalendarState);
        state.* = .{
            .value = value,
            .month = month,
            .today_date = currentLocalDate(),
            .on_select = p.on_select,
            .container = container,
            .grid = grid,
            .month_label = month_label,
            .cx = cx,
            .scope = my_scope,
            .cell_size = p.cell_size,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s: *CalendarState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.cleanup);

        prev_ctx.state = state;
        next_ctx.state = state;

        // keyboard handler (focusable / a11y role already in declaration)
        container.behavior.interaction.tab_index = 0;
        container.behavior.events.on_key_down = calendarKeyHandler;
        container.behavior.events.key_context = @ptrCast(state);

        container.addDebugState(@ptrCast(state));

        // first view (view_month = 0 sentinel guarantees build); value / month are Model, must have
        // effect
        try state.view(false);
        try my_scope.createEffect(state, CalendarState.viewEffect);

        return .{ .wrapper = container, .value = value.asSignal(), .month = month.asSignal() };
    }
};

/// Calendar keyboard handler, forwards to state.handleKey
fn calendarKeyHandler(key: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) core.EventResult {
    const state: *CalendarState = @ptrCast(@alignCast(context orelse return .ignored));
    return if (state.handleKey(key)) .stop else .ignored;
}

// ========== helpers ==========

const NavDir = enum { prev, next };

const NavClickCtx = struct {
    state: *CalendarState = undefined,
    dir: NavDir,
};

fn createNavCtx(scope: *Scope, dir: NavDir) !*NavClickCtx {
    const nc = try scope.allocator.create(NavClickCtx);
    nc.* = .{ .dir = dir };
    try scope.adoptResource(@ptrCast(nc), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            alloc.destroy(@as(*NavClickCtx, @ptrCast(@alignCast(ptr))));
        }
    }.cleanup);
    return nc;
}

/// Month nav: ghost icon-only Button (focus ring / pressed / a11y from Button), chevron icon.
fn navButton(asset: svg_assets.Asset, a11y_label: []const u8, nc: *NavClickCtx) button_mod.ButtonBuilder {
    return button_mod.Button(.{
        .variant = .ghost,
        .size = .sm,
        .icon_only = true,
        .icon_asset = asset,
        .icon_size = styles.nav_icon_size,
        .a11y_label = a11y_label,
        .on_event = navEventHandler,
        .event_context = @as(?*anyopaque, @ptrCast(nc)),
    });
}

fn navEventHandler(event: Event, context: ?*anyopaque) EventResult {
    switch (event) {
        .click => {
            if (context) |ctx| {
                const nc: *NavClickCtx = @ptrCast(@alignCast(ctx));
                switch (nc.dir) {
                    .prev => nc.state.prevMonth(),
                    .next => nc.state.nextMonth(),
                }
                return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

const DayCellCtx = struct {
    state: *CalendarState,
    date: SimpleDate,
    node: *Node,
    normal_bg: Color,
    hover_bg: Color,
    hover_enabled: bool,
    /// a11y: cell complete date label ("March 15, 2026") persistent storage; ctx lifecycle same as
    /// node
    /// (scope resource), a11y projection can read anytime.
    a11y_label_buf: [40]u8 = undefined,
    a11y_label_len: usize = 0,
    /// date number text (prebuilt element description borrows it)
    day_buf: [4]u8 = undefined,
};

fn dayCellEventHandler(event: Event, context: ?*anyopaque) EventResult {
    switch (event) {
        .click => {
            if (context) |ctx| {
                const dc: *DayCellCtx = @ptrCast(@alignCast(ctx));
                dc.state.selectDate(dc.date);
                return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

fn dayCellHoverHandler(ctx_ptr: *anyopaque) void {
    const dc: *DayCellCtx = @ptrCast(@alignCast(ctx_ptr));
    if (!dc.hover_enabled) return;
    dc.node.setStyle(null, .background, dc.hover_bg);
}

fn dayCellLeaveHandler(ctx_ptr: *anyopaque) void {
    const dc: *DayCellCtx = @ptrCast(@alignCast(ctx_ptr));
    if (!dc.hover_enabled) return;
    dc.node.setStyle(null, .background, dc.normal_bg);
}

/// compute days in a month
fn daysInMonth(year: u16, month: u8) u8 {
    if (month < 1 or month > 12) return 31; // defensive default
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2) {
        const y: u32 = year;
        const is_leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
        return if (is_leap) 29 else 28;
    }
    return days[month - 1];
}

/// compute day-of-week (0=Sunday), simplified Zeller formula
fn dayOfWeek(year: u16, month: u8, day: u8) u8 {
    var y: i32 = @intCast(year);
    var m: i32 = @intCast(month);
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const d: i32 = @intCast(day);
    const w = @mod(d + @divFloor(13 * (m + 1), 5) + y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400), 7);
    // Zeller: 0=Sat, 1=Sun, ..., 6=Fri -> convert to 0=Sun
    const dow: i32 = @mod(w + 6, 7);
    return @intCast(dow);
}

const WeekdayTextProps = struct { style: core.TextStyle };
const WeekdayCellProps = struct { style: core.BoxStyle };
const WeekdayCell = view.Box(WeekdayCellProps, view.Text(WeekdayTextProps, []const u8), null);

fn weekdayCell(t: *const theme.ThemeTokens, wd: []const u8) WeekdayCell {
    return view.box(WeekdayCellProps{ .style = styles.weekdayCellStyle(t) }, view.text(WeekdayTextProps{ .style = styles.weekdayTextStyle(t) }, wd));
}

const DayCellProps = struct { style: core.BoxStyle, a11y: core.A11yProps, on_hover: core.HandlerRef, on_leave: core.HandlerRef };
const DayTextProps = struct { style: core.TextStyle };
const DayCell = view.NodeCapture(**Node, view.Box(DayCellProps, view.Text(DayTextProps, []const u8), null));

fn rebuildGrid(state: *CalendarState) !void {
    while (state.grid.children.items.len > 0) {
        const child = state.grid.children.items[state.grid.children.items.len - 1];
        state.cx.detachChild(state.grid, child);
        state.cx.freeNode(child);
    }

    // update month label
    if (state.month_label.getText()) |old| {
        var txt = old;
        var buf: [24]u8 = undefined;
        const label = formatMonthYear(state.view_year, state.view_month, &buf);
        try txt.setContent(state.cx.allocator, label);
        state.month_label.setText(txt);
    }
    state.month_label.markRenderDirty();

    try buildGrid(state);
}

fn buildGrid(state: *CalendarState) !void {
    const cx = state.cx;
    const t = cx.tokens;
    const cell_size = state.cell_size;

    var cells: [42]CalendarCell = undefined;
    const cell_count = buildCalendarCells(state.view_year, state.view_month, &cells);

    // a11y: keyboard cursor cell (grid container's active_descendant)
    var cursor_cell: ?*Node = null;

    var row_idx: usize = 0;
    while (row_idx * 7 < cell_count) : (row_idx += 1) {
        // exactly 7 cells per row (buildCalendarCells pads to full weeks)
        var row_cells: [7]DayCell = undefined;
        for (&row_cells, 0..) |*el, col| {
            const idx = row_idx * 7 + col;
            const cell = cells[idx];
            const current_date = cell.date;
            const is_selected = if (state.selected_date) |sel| sel.eql(current_date) else false;
            const is_today = if (state.today_date) |today| today.eql(current_date) else false;
            const is_keyboard_focus = if (state.keyboard_cursor) |kc| kc.eql(current_date) else false;
            const is_current_month = cell.in_current_month;

            const flags = styles.DayCellFlags{
                .selected = is_selected,
                .today = is_today,
                .keyboard_focus = is_keyboard_focus,
                .current_month = is_current_month,
            };
            var cell_style = styles.dayCellStyle(flags, cell_size, t);
            cell_style.cursor = .pointer;

            // old cell nodes freed at rebuildGrid start, slots safe to reuse; node written by mount
            const day_ctx = &state.day_ctxs[idx];
            day_ctx.* = .{
                .state = state,
                .date = current_date,
                .node = undefined,
                .normal_bg = cell_style.background.?,
                .hover_bg = styles.dayHoverBg(is_current_month, t),
                .hover_enabled = !is_selected,
            };
            // date number: store in slot (element description borrows it on mount, text node copies
            // on mount)
            const day_text: []const u8 = std.fmt.bufPrint(&day_ctx.day_buf, "{d}", .{current_date.day}) catch "?";
            const day_len = day_text.len;

            // a11y: gridcell + complete label with year-month-day (AT reads per-cell, not bare
            // '15')
            // + selected state + today marker (description, orthogonal to selected).
            const cell_label = std.fmt.bufPrint(&day_ctx.a11y_label_buf, "{s} {d}, {d}", .{
                monthName(current_date.month), current_date.day, current_date.year,
            }) catch "";
            day_ctx.a11y_label_len = cell_label.len;
            // text as child node (.fit size), so justify/align_items can center
            el.* = view.capture(&day_ctx.node, view.box(DayCellProps{
                .style = cell_style,
                .a11y = .{
                    .role = .gridcell,
                    .label = day_ctx.a11y_label_buf[0..day_ctx.a11y_label_len],
                    .selected = is_selected,
                    .description = if (is_today) "Today" else null,
                    .row_index = @intCast(row_idx + 1),
                    .column_index = @intCast(col),
                },
                .on_hover = core.Cx.simpleHandler(dayCellHoverHandler, @ptrCast(day_ctx)),
                .on_leave = core.Cx.simpleHandler(dayCellLeaveHandler, @ptrCast(day_ctx)),
            }, view.text(DayTextProps{ .style = styles.dayTextStyle(flags, t) }, @as([]const u8, day_ctx.day_buf[0..day_len]))));
        }
        // a11y: each week row is a grid row (weekday titles occupy row_index 0).
        // sweep: row mount failure rolls back whole row (OOM during rebuildGrid cannot leave orphan
        // nodes);
        // row scope bound to row node, next rebuild frees nodes with scope.
        _ = try view.append(state.scope, cx, state.grid, view.box(.{
            .style = styles.weekRowStyle(cell_size),
            .a11y = core.A11yProps{ .role = .row, .row_index = @intCast(row_idx + 1) },
        }, row_cells));

        // click event (raw on_event)
        for (state.day_ctxs[row_idx * 7 ..][0..7]) |*day_ctx| {
            const day_cell = day_ctx.node;
            if (state.keyboard_cursor) |kc| {
                if (kc.eql(day_ctx.date)) cursor_cell = day_cell;
            }
            day_cell.behavior.events.on_event = dayCellEventHandler;
            day_cell.behavior.events.event_context = @ptrCast(day_ctx);
        }
    }

    // a11y: grid container value_text follows view month (AT reads new value after month flip);
    // active_descendant follows keyboard cursor (arrow moves -> dirty notify -> AT focus follows).
    const month_lbl = formatMonthYear(state.view_year, state.view_month, &state.month_a11y_buf);
    state.month_a11y_len = month_lbl.len;
    if (state.container.behavior.interaction.a11y) |*a| {
        a.value_text = state.month_a11y_buf[0..state.month_a11y_len];
        a.active_descendant_element_id = if (cursor_cell) |n| n.element_id_raw else 0xFFFFFFFF;
    }
    state.container.markRenderDirty();
}

const CalendarCell = struct {
    date: SimpleDate,
    in_current_month: bool,
};

const MonthCursor = struct {
    year: u16,
    month: u8,
};

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

fn formatMonthYear(year: u16, month: u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d}", .{ monthName(month), year }) catch "Unknown";
}

fn previousMonth(year: u16, month: u8) MonthCursor {
    if (month <= 1) return .{ .year = year - 1, .month = 12 };
    return .{ .year = year, .month = month - 1 };
}

fn calendarNextMonth(year: u16, month: u8) MonthCursor {
    if (month >= 12) return .{ .year = year + 1, .month = 1 };
    return .{ .year = year, .month = month + 1 };
}

fn buildCalendarCells(year: u16, month: u8, out: *[42]CalendarCell) usize {
    const total_days = daysInMonth(year, month);
    const first_dow = dayOfWeek(year, month, 1);
    const used_slots: usize = @as(usize, first_dow) + @as(usize, total_days);
    const trailing_slots: usize = if (@mod(used_slots, 7) == 0) 0 else 7 - @mod(used_slots, 7);
    const total_slots = used_slots + trailing_slots;

    const prev = previousMonth(year, month);
    const next = calendarNextMonth(year, month);
    const prev_days = daysInMonth(prev.year, prev.month);

    var idx: usize = 0;
    while (idx < total_slots) : (idx += 1) {
        if (idx < first_dow) {
            const offset = @as(u8, @intCast(first_dow - idx));
            out[idx] = .{
                .date = .{ .year = prev.year, .month = prev.month, .day = prev_days - offset + 1 },
                .in_current_month = false,
            };
            continue;
        }

        if (idx < used_slots) {
            const day = @as(u8, @intCast(idx - first_dow + 1));
            out[idx] = .{
                .date = .{ .year = year, .month = month, .day = day },
                .in_current_month = true,
            };
            continue;
        }

        const next_day = @as(u8, @intCast(idx - used_slots + 1));
        out[idx] = .{
            .date = .{ .year = next.year, .month = next.month, .day = next_day },
            .in_current_month = false,
        };
    }

    return total_slots;
}

pub fn currentLocalDate() ?SimpleDate {
    var now: c.time_t = undefined;
    _ = c.time(&now);
    var local_tm: c.struct_tm = undefined;
    if (comptime @import("builtin").os.tag == .windows) {
        const now64: c.__time64_t = @intCast(now);
        if (c._localtime64_s(&local_tm, &now64) != 0) return null;
    } else {
        if (c.localtime_r(&now, &local_tm) == null) return null;
    }

    return .{
        .year = @intCast(local_tm.tm_year + 1900),
        .month = @intCast(local_tm.tm_mon + 1),
        .day = @intCast(local_tm.tm_mday),
    };
}

// ========== tests ==========

fn stateOf(r: CalendarResult) *CalendarState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

test "Calendar: basic structure" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .month = YearMonth{ .year = 2025, .month = 1 },
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // container has 3 children: header + weekday_row + grid
    try std.testing.expectEqual(@as(usize, 3), result.wrapper.children.items.len);
}

test "Calendar: days in month" {
    try std.testing.expectEqual(@as(u8, 31), daysInMonth(2025, 1));
    try std.testing.expectEqual(@as(u8, 28), daysInMonth(2025, 2));
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2)); // leap year
    try std.testing.expectEqual(@as(u8, 30), daysInMonth(2025, 4));
}

test "Calendar: month label formatting" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("March 2026", formatMonthYear(2026, 3, &buf));
}

test "Calendar: day of week" {
    // 2025-01-01 is Wednesday (3)
    try std.testing.expectEqual(@as(u8, 3), dayOfWeek(2025, 1, 1));
    // 2024-01-01 is Monday (1)
    try std.testing.expectEqual(@as(u8, 1), dayOfWeek(2024, 1, 1));
}

test "Calendar: leading and trailing month cells" {
    var cells: [42]CalendarCell = undefined;
    const count = buildCalendarCells(2026, 3, &cells);

    try std.testing.expectEqual(@as(usize, 35), count);
    try std.testing.expect(cells[0].in_current_month);
    try std.testing.expectEqual(@as(u8, 1), cells[0].date.day);
    try std.testing.expect(!cells[31].in_current_month);
    try std.testing.expectEqual(@as(u8, 1), cells[31].date.day);
    try std.testing.expectEqual(@as(u8, 4), cells[34].date.day);
}

test "Calendar: navigation" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .month = YearMonth{ .year = 2025, .month = 1 },
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    stateOf(result).nextMonth();
    try std.testing.expectEqual(@as(u8, 2), stateOf(result).view_month);

    stateOf(result).prevMonth();
    try std.testing.expectEqual(@as(u8, 1), stateOf(result).view_month);

    // cross-year
    stateOf(result).prevMonth();
    try std.testing.expectEqual(@as(u8, 12), stateOf(result).view_month);
    try std.testing.expectEqual(@as(u16, 2024), stateOf(result).view_year);
}

test "Calendar: 翻月按钮是 chevron 图标 Button——有按钮语义与名称，点击翻月" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try Calendar(.{ .month = YearMonth{ .year = 2025, .month = 1 } }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();

    const header = result.wrapper.children.items[0];
    const prev_btn = header.children.items[0];
    const next_btn = header.children.items[2];
    const prev_a11y = prev_btn.behavior.interaction.a11y.?;
    try std.testing.expectEqual(core.A11yRole.button, prev_a11y.role);
    try std.testing.expectEqualStrings("Previous month", prev_a11y.label.?);
    try std.testing.expectEqualStrings("Next month", next_btn.behavior.interaction.a11y.?.label.?);
    // icon only: no text child, square, fits the 32px header
    const r = prev_btn.globalRect();
    try std.testing.expectApproxEqAbs(r.w, r.h, 0.5);
    try std.testing.expect(r.h <= 32);

    const click = core.Event{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } };
    _ = ctx.dispatcher.dispatch(click, next_btn);
    try std.testing.expectEqual(@as(u8, 2), stateOf(result).view_month);
    _ = ctx.dispatcher.dispatch(click, prev_btn);
    _ = ctx.dispatcher.dispatch(click, prev_btn);
    try std.testing.expectEqual(@as(u8, 12), stateOf(result).view_month);
    try std.testing.expectEqual(@as(u16, 2024), stateOf(result).view_year);
}

test "Calendar: 翻月不在 scope 里累积日期格资源" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try Calendar(.{ .month = YearMonth{ .year = 2025, .month = 1 } }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const before = stateOf(result).scope.resources.items.len;
    var i: usize = 0;
    while (i < 6) : (i += 1) stateOf(result).nextMonth();
    try std.testing.expectEqual(before, stateOf(result).scope.resources.items.len);
}

test "Calendar: day hover updates background" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const day_cell = stateOf(result).grid.children.items[0].children.items[0];
    try std.testing.expect(Color.eql(day_cell.getBackground(), ctx.tokens.tokens.color.bg_primary) or Color.eql(day_cell.getBackground(), ctx.tokens.tokens.color.bg_secondary));

    day_cell.behavior.events.on_hover.?.invoke();
    try std.testing.expect(Color.eql(day_cell.getBackground(), ctx.tokens.tokens.color.bg_hover));

    day_cell.behavior.events.on_leave.?.invoke();
    try std.testing.expect(Color.eql(day_cell.getBackground(), ctx.tokens.tokens.color.bg_primary) or Color.eql(day_cell.getBackground(), ctx.tokens.tokens.color.bg_secondary));
}

test "Calendar: render emits day numbers for visible month" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(360, 420);

    const root = try box(ctx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 420 },
        .background = ctx.tokens.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_month = false;
    var saw_day = false;
    for (commands) |cmd| if (cmd.isText()) {
        const tcmd = cmd;
        if (std.mem.eql(u8, tcmd.text_content, "March 2026")) saw_month = true;
        if (std.mem.eql(u8, tcmd.text_content, "15")) saw_day = true;
    };

    try std.testing.expect(saw_month);
    try std.testing.expect(saw_day);
}

// ============================================================================
// v0.7 §2.5, Calendar keyboard navigation tests
// ============================================================================

test "Calendar: bound value moves the selection and (with month = null) the visible month" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const due = try scope.createSignal(?SimpleDate, SimpleDate{ .year = 2026, .month = 3, .day = 10 });
    const r = try Calendar(.{ .value = due }).mount(scope, ctx);
    defer ctx.freeNode(r.wrapper);
    try std.testing.expectEqual(@as(u8, 3), stateOf(r).view_month);
    due.set(SimpleDate{ .year = 2026, .month = 7, .day = 4 });
    try std.testing.expectEqual(@as(u8, 7), stateOf(r).view_month);
    try std.testing.expectEqual(@as(u8, 4), stateOf(r).selected_date.?.day);

    // after month-flip writes explicit month, no longer follows selected date
    stateOf(r).nextMonth();
    try std.testing.expectEqual(@as(u8, 8), stateOf(r).view_month);
    due.set(SimpleDate{ .year = 2026, .month = 1, .day = 1 });
    try std.testing.expectEqual(@as(u8, 8), stateOf(r).view_month);
    r.month.?.set(null); // back to following
    try std.testing.expectEqual(@as(u8, 1), stateOf(r).view_month);
}

test "Calendar: a split month parent can refuse navigation; clicking an adjacent-month day jumps there" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Parent = struct {
        month: *Signal(?YearMonth),
        locked: bool = true,
        fn write(self: *@This(), m: ?YearMonth) void {
            if (!self.locked) self.month.set(m);
        }
    };
    var parent = Parent{ .month = try scope.createSignal(?YearMonth, YearMonth{ .year = 2026, .month = 3 }) };
    var picked: ?SimpleDate = null;
    const r = try Calendar(.{
        .month = reactive.split(parent.month, ctx.on(Parent, &parent, Parent.write)),
        .on_select = ctx.on(?SimpleDate, &picked, struct {
            fn f(out: *?SimpleDate, d: SimpleDate) void {
                out.* = d;
            }
        }.f),
    }).mount(scope, ctx);
    defer ctx.freeNode(r.wrapper);
    stateOf(r).nextMonth();
    try std.testing.expectEqual(@as(u8, 3), stateOf(r).view_month); // rejected

    parent.locked = false;
    // 2026-03 grid first cell is Feb date before Mar 1 (3/1 is Sunday -> no leading row); directly
    // select Apr 2
    stateOf(r).selectDate(.{ .year = 2026, .month = 4, .day = 2 });
    try std.testing.expectEqual(@as(u8, 4), stateOf(r).view_month);
    try std.testing.expectEqual(@as(u8, 2), picked.?.day);
}

test "Calendar: 键盘游标始终在可视月份内——换月被拒退回原处，被改写则钳进落地的月份" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Parent = struct {
        month: *Signal(?YearMonth),
        mode: enum { refuse, to_june } = .refuse,
        fn write(self: *@This(), m: ?YearMonth) void {
            _ = m;
            // reject, or rewrite all proposals to June
            if (self.mode == .to_june) self.month.set(YearMonth{ .year = 2026, .month = 6 });
        }
    };
    var parent = Parent{ .month = try scope.createSignal(?YearMonth, YearMonth{ .year = 2026, .month = 3 }) };
    const r = try Calendar(.{
        .month = reactive.split(parent.month, ctx.on(Parent, &parent, Parent.write)),
        .value = SimpleDate{ .year = 2026, .month = 3, .day = 31 },
    }).mount(scope, ctx);
    defer ctx.freeNode(r.wrapper);
    const st = stateOf(r);

    _ = st.handleKey(.right); // 3/31 -> 4/1, month-flip rejected
    try std.testing.expectEqual(@as(u8, 3), st.view_month);
    try std.testing.expect(st.keyboard_cursor.?.eql(.{ .year = 2026, .month = 3, .day = 31 }));

    parent.mode = .to_june;
    _ = st.handleKey(.right); // propose April, settle June: cursor clamped to June
    try std.testing.expectEqual(@as(u8, 6), st.view_month);
    try std.testing.expect(st.keyboard_cursor.?.eql(.{ .year = 2026, .month = 6, .day = 1 }));

    // external write month directly (31-day clamp to 30-day also covered)
    st.keyboard_cursor = .{ .year = 2026, .month = 6, .day = 30 };
    parent.month.set(YearMonth{ .year = 2026, .month = 2 });
    try std.testing.expectEqual(@as(u8, 2), st.view_month);
    try std.testing.expect(st.keyboard_cursor.?.eql(.{ .year = 2026, .month = 2, .day = 28 }));
}

test "addDays handles month rollover forward + backward" {
    // 2026-01-31 + 1 = 2026-02-01
    var d = addDays(.{ .year = 2026, .month = 1, .day = 31 }, 1);
    try std.testing.expectEqual(@as(u16, 2026), d.year);
    try std.testing.expectEqual(@as(u8, 2), d.month);
    try std.testing.expectEqual(@as(u8, 1), d.day);
    // 2026-02-01 - 1 = 2026-01-31
    d = addDays(.{ .year = 2026, .month = 2, .day = 1 }, -1);
    try std.testing.expectEqual(@as(u8, 1), d.month);
    try std.testing.expectEqual(@as(u8, 31), d.day);
    // 2026-12-31 + 7 = 2027-01-07
    d = addDays(.{ .year = 2026, .month = 12, .day = 31 }, 7);
    try std.testing.expectEqual(@as(u16, 2027), d.year);
    try std.testing.expectEqual(@as(u8, 1), d.month);
    try std.testing.expectEqual(@as(u8, 7), d.day);
    // Leap year: 2024-02-28 + 1 = 2024-02-29
    d = addDays(.{ .year = 2024, .month = 2, .day = 28 }, 1);
    try std.testing.expectEqual(@as(u8, 2), d.month);
    try std.testing.expectEqual(@as(u8, 29), d.day);
}

test "handleKey arrow keys 移动 cursor (lazy init from today/selected)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
        .value = SimpleDate{ .year = 2026, .month = 3, .day = 15 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    // first arrow-right -> should init cursor to selected (15) then +1 = 16
    try std.testing.expect(stateOf(r).handleKey(.right));
    try std.testing.expect(stateOf(r).keyboard_cursor != null);
    try std.testing.expectEqual(@as(u8, 16), stateOf(r).keyboard_cursor.?.day);

    // down (+7) = 23
    try std.testing.expect(stateOf(r).handleKey(.down));
    try std.testing.expectEqual(@as(u8, 23), stateOf(r).keyboard_cursor.?.day);

    // left = 22
    try std.testing.expect(stateOf(r).handleKey(.left));
    try std.testing.expectEqual(@as(u8, 22), stateOf(r).keyboard_cursor.?.day);

    // up (−7) = 15
    try std.testing.expect(stateOf(r).handleKey(.up));
    try std.testing.expectEqual(@as(u8, 15), stateOf(r).keyboard_cursor.?.day);
}

test "handleKey 跨月: right at month end rolls forward + 更新 view_month" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
        .value = SimpleDate{ .year = 2026, .month = 3, .day = 31 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(stateOf(r).handleKey(.right)); // 31 → 4-1
    try std.testing.expectEqual(@as(u8, 4), stateOf(r).view_month);
    try std.testing.expectEqual(@as(u8, 1), stateOf(r).keyboard_cursor.?.day);
}

test "handleKey PageDown 跨月，同日号尝试" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 1 },
        .value = SimpleDate{ .year = 2026, .month = 1, .day = 31 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(stateOf(r).handleKey(.page_down)); // 1-31 → 2 (max 28) → 2-28
    try std.testing.expectEqual(@as(u8, 2), stateOf(r).view_month);
    try std.testing.expectEqual(@as(u8, 28), stateOf(r).keyboard_cursor.?.day);
}

test "handleKey Home/End 跳到本周首/尾" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 2026-03-15 = Sunday (dow=0)
    // 2026-03-18 = Wednesday (dow=3)
    const r = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
        .value = SimpleDate{ .year = 2026, .month = 3, .day = 18 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(stateOf(r).handleKey(.home));
    // Home: jump to week start (dow=0) -> 3-15
    try std.testing.expectEqual(@as(u8, 15), stateOf(r).keyboard_cursor.?.day);

    try std.testing.expect(stateOf(r).handleKey(.end));
    // End: jump to week end (dow=6) -> 3-21
    try std.testing.expectEqual(@as(u8, 21), stateOf(r).keyboard_cursor.?.day);
}

test "handleKey Enter 提交选中 + 触发 on_select" {
    const On = struct {
        var fired: u32 = 0;
        fn cb(_: *u32, _: SimpleDate) void {
            fired += 1;
        }
    };
    On.fired = 0;

    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var dummy: u32 = 0;
    const r = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
        .value = SimpleDate{ .year = 2026, .month = 3, .day = 10 },
        .on_select = ctx.on(u32, &dummy, On.cb),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    // move to 14
    try std.testing.expect(stateOf(r).handleKey(.right));
    try std.testing.expect(stateOf(r).handleKey(.right));
    try std.testing.expect(stateOf(r).handleKey(.right));
    try std.testing.expect(stateOf(r).handleKey(.right));
    try std.testing.expectEqual(@as(u8, 14), stateOf(r).keyboard_cursor.?.day);

    // Enter -> selectDate
    try std.testing.expect(stateOf(r).handleKey(.@"return"));
    try std.testing.expectEqual(@as(u32, 1), On.fired);
    try std.testing.expectEqual(@as(u8, 14), stateOf(r).selected_date.?.day);
}

test "container focusable + on_key_down wired (smoke)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(r.wrapper.behavior.interaction.focusable);
    try std.testing.expectEqual(@as(?i32, 0), r.wrapper.behavior.interaction.tab_index);
    try std.testing.expect(r.wrapper.behavior.events.on_key_down != null);
}

test "a11y: Calendar grid/cell 语义 + 月份切换/键盘游标跟随且可撤回" {
    const testing = std.testing;
    var ctx = try Cx.init(testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 500);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .month = YearMonth{ .year = 2026, .month = 3 },
        .value = SimpleDate{ .year = 2026, .month = 3, .day = 15 },
    }).mount(scope, ctx);
    try root.appendChild(testing.allocator, r.wrapper);
    ctx.layout();
    _ = ctx.render();

    const grid_eid = core.ElementId.fromRaw(r.wrapper.element_id_raw);
    {
        const n = ctx.accessibility_tree.getNode(grid_eid).?;
        try testing.expectEqual(core.a11y_tree.Role.grid, n.role);
        // container value = current view month
        try testing.expectEqual(std.hash.Wyhash.hash(0, "March 2026"), n.text_hash);
        // no keyboard cursor yet
        try testing.expect(n.active_descendant.isNull());
    }

    // find selected cell (2026-03-15), assert cell semantics in a11y tree
    var selected_cell: ?*Node = null;
    for (stateOf(r).grid.children.items) |week_row| {
        try testing.expectEqual(core.A11yRole.row, week_row.behavior.interaction.a11y.?.role);
        for (week_row.children.items) |cell_node| {
            if (cell_node.behavior.interaction.a11y.?.selected) selected_cell = cell_node;
        }
    }
    {
        const n = ctx.accessibility_tree.getNode(core.ElementId.fromRaw(selected_cell.?.element_id_raw)).?;
        try testing.expectEqual(core.a11y_tree.Role.cell, n.role);
        try testing.expect(n.state.selected);
        // label is complete description with year-month-day, not bare number
        try testing.expectEqual(std.hash.Wyhash.hash(0, "March 15, 2026"), n.label_hash);
    }

    // arrow move -> after rebuild active_descendant points to cursor cell (AT focus follows)
    try testing.expect(stateOf(r).handleKey(.right)); // 15 → 16
    ctx.layout();
    _ = ctx.render();
    {
        const n = ctx.accessibility_tree.getNode(grid_eid).?;
        try testing.expect(!n.active_descendant.isNull());
        const cursor_node = ctx.accessibility_tree.get(n.active_descendant).?;
        try testing.expectEqual(std.hash.Wyhash.hash(0, "March 16, 2026"), cursor_node.label_hash);
        // old selected cell replaced by rebuild, selected state still present (15th still selected)
    }

    // month flip -> container value updates; flip back -> reverts to original value
    stateOf(r).nextMonth();
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(std.hash.Wyhash.hash(0, "April 2026"), ctx.accessibility_tree.getNode(grid_eid).?.text_hash);
    stateOf(r).prevMonth();
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(std.hash.Wyhash.hash(0, "March 2026"), ctx.accessibility_tree.getNode(grid_eid).?.text_hash);
}

// test collection from styles.zig, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// per-allocation-point OOM sweep, see src/ui/components/oom_sweep.zig
test "calendar: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("calendar", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Calendar(.{ .month = YearMonth{ .year = 2026, .month = 9 } }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}

test "calendar: 受控值 / 月份的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("calendar(bound)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const due = try scope.createSignal(?SimpleDate, SimpleDate{ .year = 2026, .month = 9, .day = 3 });
            const month = try scope.createSignal(?YearMonth, null);
            const r = try Calendar(.{ .value = due, .month = month }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
