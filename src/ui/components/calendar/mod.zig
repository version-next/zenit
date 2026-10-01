/// Calendar Component
///
/// 日历组件，月视图展示
///
/// 特性:
/// - 月视图 7×6 网格
/// - 年月导航 ◀ ▶
/// - 日期选择
/// - 今日高亮
const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const theme = core.theme;
const svg_assets = @import("../../svg_assets.zig");
const Scope = @import("../../reactive.zig").Scope;
const hooks = @import("../../hooks.zig");
const events = @import("../../events.zig");
const styles = @import("styles.zig");
const Event = events.Event;
const EventResult = events.EventResult;

/// 简单日期
pub const SimpleDate = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31

    pub fn eql(a: SimpleDate, b: SimpleDate) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

/// Calendar 属性
pub const CalendarProps = struct {
    initial_year: u16 = 2025,
    initial_month: u8 = 1,
    selected_date: ?SimpleDate = null,
    on_select: ?core.HandlerRef = null,
    cell_size: f32 = 36,
    prev_icon_asset: ?svg_assets.Asset = null,
    next_icon_asset: ?svg_assets.Asset = null,
};

/// Calendar 状态
pub const CalendarState = struct {
    view_year: u16,
    view_month: u8,
    selected_date: ?SimpleDate,
    today_date: ?SimpleDate,
    on_select: ?core.HandlerRef,
    container: *Node,
    grid: *Node,
    month_label: *Node,
    cx: *Cx,
    scope: *Scope,
    cell_size: f32,
    /// 键盘导航游标，在 grid 上的当前 "focused day"。
    /// null = 还没用键盘导航过 (鼠标用户)。第一次按方向键时 lazy 初始化:
    /// 优先 selected_date -> today_date -> view_year/month 1 号。
    keyboard_cursor: ?SimpleDate = null,
    /// a11y: grid 容器 value_text（"March 2026"）的持久存储，a11y 投影每帧
    /// 读这个 slice，栈上 buf 会悬垂。
    month_a11y_buf: [24]u8 = undefined,
    month_a11y_len: usize = 0,
    /// 日期格事件上下文：固定 42 槽随 state 存活、每次 rebuild 复用。
    /// 此前每次 rebuild 都 adoptResource 新的 ctx 进长寿 scope，翻月即单调增长。
    day_ctxs: [42]DayCellCtx = undefined,

    pub fn prevMonth(self: *CalendarState) void {
        if (self.view_month == 1) {
            self.view_month = 12;
            self.view_year -= 1;
        } else {
            self.view_month -= 1;
        }
        rebuildGrid(self) catch @panic("OOM: Calendar 重建日期网格失败（view_month 已改，不重建会让状态与画面永久不一致）");
    }

    pub fn nextMonth(self: *CalendarState) void {
        if (self.view_month == 12) {
            self.view_month = 1;
            self.view_year += 1;
        } else {
            self.view_month += 1;
        }
        rebuildGrid(self) catch @panic("OOM: Calendar 重建日期网格失败（view_month 已改，不重建会让状态与画面永久不一致）");
    }

    pub fn selectDate(self: *CalendarState, date: SimpleDate) void {
        self.selected_date = date;
        self.view_year = date.year;
        self.view_month = date.month;
        if (self.on_select) |handler| handler.invoke();
        rebuildGrid(self) catch @panic("OOM: Calendar.selectDate 重建日期网格失败（选中态已改，不重建会让状态与画面永久不一致）");
    }

    /// 键盘事件入口，返回 true 表示事件被消耗。
    /// 处理 <-/-> 跨日、↑/↓ 跨周、PageUp/PageDown 跨月、Home/End 行首尾、Enter 选中。
    pub fn handleKey(self: *CalendarState, key: core.KeyCode) bool {
        const cursor = self.keyboard_cursor orelse blk: {
            // lazy init：选中 -> today -> 当前视图月 1 号
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

    /// 移动 cursor 偏移 n 天 (正/负)，跨月时自动更新 view_year/view_month + rebuildGrid
    fn moveCursor(self: *CalendarState, from: SimpleDate, delta_days: i32) void {
        const target = addDays(from, delta_days);
        self.keyboard_cursor = target;
        if (target.year != self.view_year or target.month != self.view_month) {
            self.view_year = target.year;
            self.view_month = target.month;
        }
        rebuildGrid(self) catch @panic("OOM: Calendar.moveCursor 重建日期网格失败（键盘游标已移动，不重建会让状态与画面永久不一致）");
    }

    /// 跨月: 同日号尝试，若新月没这天则取月末
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
        self.keyboard_cursor = .{ .year = new_year, .month = new_month, .day = new_day };
        self.view_year = new_year;
        self.view_month = new_month;
        rebuildGrid(self) catch @panic("OOM: Calendar 重建日期网格失败（view_month 已改，不重建会让状态与画面永久不一致）");
    }
};

/// 给 SimpleDate 加 N 天 (正/负)，跨月跨年自动 carry
fn addDays(from: SimpleDate, delta: i32) SimpleDate {
    var y: i32 = @intCast(from.year);
    var m: i32 = @intCast(from.month);
    var d: i32 = @as(i32, @intCast(from.day)) + delta;
    // 向后 carry
    while (d > daysInMonth(@intCast(@max(1, y)), @intCast(@max(1, m)))) {
        d -= daysInMonth(@intCast(@max(1, y)), @intCast(@max(1, m)));
        m += 1;
        if (m > 12) {
            m = 1;
            y += 1;
        }
    }
    // 向前 carry
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

/// Calendar mount 结果
pub const CalendarResult = struct {
    wrapper: *Node,
    state: *CalendarState,
};

/// 创建 Calendar
pub fn Calendar(props: CalendarProps) CalendarBuilder {
    return CalendarBuilder{ .props = props };
}

pub const CalendarBuilder = struct {
    props: CalendarProps,

    pub fn selectedDate(self: CalendarBuilder, d: SimpleDate) CalendarBuilder {
        var new = self;
        new.props.selected_date = d;
        return new;
    }

    pub fn onSelect(self: CalendarBuilder, handler_ref: core.HandlerRef) CalendarBuilder {
        var new = self;
        new.props.on_select = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: CalendarBuilder, scope: *Scope, cx: *Cx) !CalendarResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const min_inner_width: f32 = 260;
        const panel_width = @max(min_inner_width + 40, p.cell_size * 7 + 40);

        // 外层容器
        const container = try box(cx, styles.containerStyle(panel_width, t), .{});
        container.meta.ownership.meta.component_name = "Calendar";
        // sweep：container 守卫一直武装到 return；子树建好即 adopt（顺序即挂接顺序）
        errdefer cx.freeNode(container);
        try core.bindScopeToNode(my_scope, container);

        // ---- Header: ◀ Month Year ▶ ----
        const header = try core.adoptChild(cx, allocator, container, try box(cx, styles.headerStyle(t), .{}));

        // 上月按钮
        const prev_btn = try core.adoptChild(cx, allocator, header, try box(cx, styles.navButtonStyle(t), .{}));
        prev_btn.style.cursor = .pointer;
        if (p.prev_icon_asset) |asset| {
            _ = try core.adoptChild(cx, allocator, prev_btn, try core.iconTint(cx, asset, t.color.fg_secondary, .{
                .width = .{ .px = styles.nav_icon_size },
                .height = .{ .px = styles.nav_icon_size },
            }));
        } else {
            const txt_node = try core.adoptChild(cx, allocator, prev_btn, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            var prev_glyph = styles.navGlyphTextStyle(t);
            prev_glyph.content = "<";
            txt_node.setText(prev_glyph);
        }

        // 月份标签
        var month_buf: [24]u8 = undefined;
        const month_str = formatMonthYear(p.initial_year, p.initial_month, &month_buf);
        const month_label = try core.adoptChild(cx, allocator, header, try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
        }, .{}));
        // setText({content=month_str,...}) 不行：month_str 指 local buf 出 scope 后悬垂。
        // setContent 拷贝（放得下走 inline，本地化长月份名则 dupe）。
        month_label.setText(styles.monthLabelTextStyle(t));
        if (month_label.getText()) |old| {
            var txt = old;
            try txt.setContent(cx.allocator, month_str);
            month_label.setText(txt);
        }

        // 下月按钮
        const next_btn = try core.adoptChild(cx, allocator, header, try box(cx, styles.navButtonStyle(t), .{}));
        next_btn.style.cursor = .pointer;
        if (p.next_icon_asset) |asset| {
            _ = try core.adoptChild(cx, allocator, next_btn, try core.iconTint(cx, asset, t.color.fg_secondary, .{
                .width = .{ .px = styles.nav_icon_size },
                .height = .{ .px = styles.nav_icon_size },
            }));
        } else {
            const txt_node = try core.adoptChild(cx, allocator, next_btn, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            var next_glyph = styles.navGlyphTextStyle(t);
            next_glyph.content = ">";
            txt_node.setText(next_glyph);
        }

        // ---- 星期标题行 ----
        const weekday_row = try core.adoptChild(cx, allocator, container, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
            .justify = .space_between,
        }, .{}));

        const weekdays = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };
        for (weekdays) |wd| {
            const wd_cell = try core.adoptChild(cx, allocator, weekday_row, try box(cx, styles.weekdayCellStyle(t), .{}));
            var wd_txt = styles.weekdayTextStyle(t);
            wd_txt.content = wd;
            wd_cell.setText(wd_txt);
        }

        // ---- 日期网格 ----
        const grid = try core.adoptChild(cx, allocator, container, try box(cx, styles.gridStyle(t), .{}));

        // State
        const state = try allocator.create(CalendarState);
        state.* = .{
            .view_year = p.initial_year,
            .view_month = p.initial_month,
            .selected_date = p.selected_date,
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

        // 按钮事件
        const prev_ctx = try allocator.create(NavClickCtx);
        prev_ctx.* = .{ .state = state, .dir = .prev };
        try my_scope.adoptResource(@ptrCast(prev_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*NavClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        prev_btn.behavior.events.on_event = navEventHandler;
        prev_btn.behavior.events.event_context = @ptrCast(prev_ctx);
        const nav_anim = styles.navButtonAnimColors(t);
        _ = try hooks.useAnimatedBackground(my_scope, cx, prev_btn, .{
            .normal = nav_anim.normal,
            .hover = nav_anim.hover,
        });

        const next_ctx = try allocator.create(NavClickCtx);
        next_ctx.* = .{ .state = state, .dir = .next };
        try my_scope.adoptResource(@ptrCast(next_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*NavClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        next_btn.behavior.events.on_event = navEventHandler;
        next_btn.behavior.events.event_context = @ptrCast(next_ctx);
        _ = try hooks.useAnimatedBackground(my_scope, cx, next_btn, .{
            .normal = nav_anim.normal,
            .hover = nav_anim.hover,
        });

        // 容器 focusable + 键盘 handler + ARIA grid role
        // 必须先于 buildGrid：buildGrid 会往 container a11y 写 value_text /
        // active_descendant（月份与键盘游标跟随）。
        container.behavior.interaction.focusable = true;
        container.behavior.interaction.tab_index = 0;
        container.behavior.interaction.a11y = .{ .role = .grid, .label = "Calendar" };
        container.behavior.events.on_key_down = calendarKeyHandler;
        container.behavior.events.key_context = @ptrCast(state);

        // 初始构建网格
        try buildGrid(state);

        return .{ .wrapper = container, .state = state };
    }
};

/// Calendar 键盘 handler，转给 state.handleKey
fn calendarKeyHandler(key: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) core.EventResult {
    const state: *CalendarState = @ptrCast(@alignCast(context orelse return .ignored));
    return if (state.handleKey(key)) .stop else .ignored;
}

// ========== 内部辅助 ==========

const NavDir = enum { prev, next };

const NavClickCtx = struct {
    state: *CalendarState,
    dir: NavDir,
};

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
    /// a11y: cell 完整日期 label（"March 15, 2026"）的持久存储；ctx 与节点
    /// 同生命周期（scope 资源），a11y 投影随时可读。
    a11y_label_buf: [40]u8 = undefined,
    a11y_label_len: usize = 0,
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

/// 计算某月的天数
fn daysInMonth(year: u16, month: u8) u8 {
    if (month < 1 or month > 12) return 31; // 防御性默认值
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2) {
        const y: u32 = year;
        const is_leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
        return if (is_leap) 29 else 28;
    }
    return days[month - 1];
}

/// 计算某天是星期几 (0=Sunday), Zeller 公式简化
fn dayOfWeek(year: u16, month: u8, day: u8) u8 {
    var y: i32 = @intCast(year);
    var m: i32 = @intCast(month);
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const d: i32 = @intCast(day);
    const w = @mod(d + @divFloor(13 * (m + 1), 5) + y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400), 7);
    // Zeller: 0=Sat, 1=Sun, ..., 6=Fri -> 转换为 0=Sun
    const dow: i32 = @mod(w + 6, 7);
    return @intCast(dow);
}

fn rebuildGrid(state: *CalendarState) !void {
    while (state.grid.children.items.len > 0) {
        const child = state.grid.children.items[state.grid.children.items.len - 1];
        state.cx.detachChild(state.grid, child);
        state.cx.freeNode(child);
    }

    // 更新月份标签
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
    const allocator = cx.allocator;
    const t = cx.tokens;
    const cell_size = state.cell_size;

    var cells: [42]CalendarCell = undefined;
    const cell_count = buildCalendarCells(state.view_year, state.view_month, &cells);

    // a11y: 键盘游标所在 cell（grid 容器的 active_descendant）
    var cursor_cell: ?*Node = null;

    var row_idx: usize = 0;
    while (row_idx * 7 < cell_count) : (row_idx += 1) {
        // sweep：行 / 格 / 文字建好即 adopt（rebuildGrid 期间 OOM 不能留游离节点）
        const week_row = try core.adoptChild(cx, allocator, state.grid, try box(cx, styles.weekRowStyle(cell_size), .{}));
        // a11y: 每个星期行是 grid 的一个 row（weekday 标题行占 row_index 0）
        week_row.behavior.interaction.a11y = .{
            .role = .row,
            .row_index = @intCast(row_idx + 1),
        };

        var col: usize = 0;
        while (col < 7) : (col += 1) {
            const idx = row_idx * 7 + col;
            if (idx >= cell_count) break;

            const cell = cells[idx];
            const current_date = cell.date;
            const is_selected = if (state.selected_date) |sel| sel.eql(current_date) else false;
            const is_today = if (state.today_date) |today| today.eql(current_date) else false;
            const is_keyboard_focus = if (state.keyboard_cursor) |kc| kc.eql(current_date) else false;
            const is_current_month = cell.in_current_month;

            // 日期数字
            var num_buf: [4]u8 = undefined;
            const day_str = std.fmt.bufPrint(&num_buf, "{d}", .{current_date.day}) catch "?";

            const flags = styles.DayCellFlags{
                .selected = is_selected,
                .today = is_today,
                .keyboard_focus = is_keyboard_focus,
                .current_month = is_current_month,
            };
            const cell_style = styles.dayCellStyle(flags, cell_size, t);

            const day_cell = try core.adoptChild(cx, allocator, week_row, try box(cx, cell_style, .{}));
            day_cell.style.cursor = .pointer;

            // 文本作为子节点（.fit 大小），这样 justify/align_items 才能居中
            const day_text = try core.adoptChild(cx, allocator, day_cell, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            // day_str 指 local buf；必须 setInlineContent 拷贝。
            day_text.setText(styles.dayTextStyle(flags, t));
            if (day_text.getText()) |old| {
                var txt = old;
                try txt.setContent(state.cx.allocator, day_str);
                day_text.setText(txt);
            }

            // 点击事件
            // 旧格节点已在 rebuildGrid 开头全部释放，槽位可安全复用
            const day_ctx = &state.day_ctxs[idx];
            day_ctx.* = .{
                .state = state,
                .date = current_date,
                .node = day_cell,
                .normal_bg = cell_style.background.?,
                .hover_bg = styles.dayHoverBg(is_current_month, t),
                .hover_enabled = !is_selected,
            };

            // a11y: gridcell + 含年月日的完整 label（AT 逐格朗读不能只念"15"）
            // + 选中态 + 今天标记（description，与 selected 正交）。
            const cell_label = std.fmt.bufPrint(&day_ctx.a11y_label_buf, "{s} {d}, {d}", .{
                monthName(current_date.month), current_date.day, current_date.year,
            }) catch "";
            day_ctx.a11y_label_len = cell_label.len;
            day_cell.behavior.interaction.a11y = .{
                .role = .gridcell,
                .label = day_ctx.a11y_label_buf[0..day_ctx.a11y_label_len],
                .selected = is_selected,
                .description = if (is_today) "Today" else null,
                .row_index = @intCast(row_idx + 1),
                .column_index = @intCast(col),
            };
            if (is_keyboard_focus) cursor_cell = day_cell;

            day_cell.behavior.events.on_event = dayCellEventHandler;
            day_cell.behavior.events.event_context = @ptrCast(day_ctx);
            day_cell.behavior.events.on_hover = core.Cx.simpleHandler(dayCellHoverHandler, @ptrCast(day_ctx));
            day_cell.behavior.events.on_leave = core.Cx.simpleHandler(dayCellLeaveHandler, @ptrCast(day_ctx));
        }
    }

    // a11y: grid 容器 value_text 跟随视图月份（月份切换后 AT 能读到新值），
    // active_descendant 跟随键盘游标（方向键移动 -> dirty 通知 -> AT 焦点跟走）。
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

fn nextMonth(year: u16, month: u8) MonthCursor {
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
    const next = nextMonth(year, month);
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
    if (c.localtime_r(&now, &local_tm) == null) return null;

    return .{
        .year = @intCast(local_tm.tm_year + 1900),
        .month = @intCast(local_tm.tm_mon + 1),
        .day = @intCast(local_tm.tm_mday),
    };
}

// ========== 测试 ==========

test "Calendar: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .initial_year = 2025,
        .initial_month = 1,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // container 有 3 个子节点: header + weekday_row + grid
    try std.testing.expectEqual(@as(usize, 3), result.wrapper.children.items.len);
}

test "Calendar: days in month" {
    try std.testing.expectEqual(@as(u8, 31), daysInMonth(2025, 1));
    try std.testing.expectEqual(@as(u8, 28), daysInMonth(2025, 2));
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2)); // 闰年
    try std.testing.expectEqual(@as(u8, 30), daysInMonth(2025, 4));
}

test "Calendar: month label formatting" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("March 2026", formatMonthYear(2026, 3, &buf));
}

test "Calendar: day of week" {
    // 2025-01-01 是星期三 (3)
    try std.testing.expectEqual(@as(u8, 3), dayOfWeek(2025, 1, 1));
    // 2024-01-01 是星期一 (1)
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
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .initial_year = 2025,
        .initial_month = 1,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.nextMonth();
    try std.testing.expectEqual(@as(u8, 2), result.state.view_month);

    result.state.prevMonth();
    try std.testing.expectEqual(@as(u8, 1), result.state.view_month);

    // 跨年
    result.state.prevMonth();
    try std.testing.expectEqual(@as(u8, 12), result.state.view_month);
    try std.testing.expectEqual(@as(u16, 2024), result.state.view_year);
}

test "Calendar: 翻月不在 scope 里累积日期格资源" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try Calendar(.{ .initial_year = 2025, .initial_month = 1 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const before = result.state.scope.resources.items.len;
    var i: usize = 0;
    while (i < 6) : (i += 1) result.state.nextMonth();
    try std.testing.expectEqual(before, result.state.scope.resources.items.len);
}

test "Calendar: day hover updates background" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const day_cell = result.state.grid.children.items[0].children.items[0];
    try std.testing.expect(Color.eql(day_cell.getBackground(), ctx.tokens.color.bg_primary) or Color.eql(day_cell.getBackground(), ctx.tokens.color.bg_secondary));

    day_cell.behavior.events.on_hover.?.invoke();
    try std.testing.expect(Color.eql(day_cell.getBackground(), ctx.tokens.color.bg_hover));

    day_cell.behavior.events.on_leave.?.invoke();
    try std.testing.expect(Color.eql(day_cell.getBackground(), ctx.tokens.color.bg_primary) or Color.eql(day_cell.getBackground(), ctx.tokens.color.bg_secondary));
}

test "Calendar: render emits day numbers for visible month" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(360, 420);

    const root = try box(ctx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 420 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
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
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
        .selected_date = .{ .year = 2026, .month = 3, .day = 15 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    // 第一次按 right -> 应初始化 cursor 到 selected (15) 然后 +1 = 16
    try std.testing.expect(r.state.handleKey(.right));
    try std.testing.expect(r.state.keyboard_cursor != null);
    try std.testing.expectEqual(@as(u8, 16), r.state.keyboard_cursor.?.day);

    // down (+7) = 23
    try std.testing.expect(r.state.handleKey(.down));
    try std.testing.expectEqual(@as(u8, 23), r.state.keyboard_cursor.?.day);

    // left = 22
    try std.testing.expect(r.state.handleKey(.left));
    try std.testing.expectEqual(@as(u8, 22), r.state.keyboard_cursor.?.day);

    // up (−7) = 15
    try std.testing.expect(r.state.handleKey(.up));
    try std.testing.expectEqual(@as(u8, 15), r.state.keyboard_cursor.?.day);
}

test "handleKey 跨月: right at month end rolls forward + 更新 view_month" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
        .selected_date = .{ .year = 2026, .month = 3, .day = 31 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(r.state.handleKey(.right)); // 31 → 4-1
    try std.testing.expectEqual(@as(u8, 4), r.state.view_month);
    try std.testing.expectEqual(@as(u8, 1), r.state.keyboard_cursor.?.day);
}

test "handleKey PageDown 跨月，同日号尝试" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 1,
        .selected_date = .{ .year = 2026, .month = 1, .day = 31 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(r.state.handleKey(.page_down)); // 1-31 → 2 (max 28) → 2-28
    try std.testing.expectEqual(@as(u8, 2), r.state.view_month);
    try std.testing.expectEqual(@as(u8, 28), r.state.keyboard_cursor.?.day);
}

test "handleKey Home/End 跳到本周首/尾" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 2026-03-15 = Sunday (dow=0)
    // 2026-03-18 = Wednesday (dow=3)
    const r = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
        .selected_date = .{ .year = 2026, .month = 3, .day = 18 },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(r.state.handleKey(.home));
    // Home: 跳到本周日 (dow=0) -> 3-15
    try std.testing.expectEqual(@as(u8, 15), r.state.keyboard_cursor.?.day);

    try std.testing.expect(r.state.handleKey(.end));
    // End: 跳到本周六 (dow=6) -> 3-21
    try std.testing.expectEqual(@as(u8, 21), r.state.keyboard_cursor.?.day);
}

test "handleKey Enter 提交选中 + 触发 on_select" {
    const On = struct {
        var fired: u32 = 0;
        fn cb(_: *anyopaque) void {
            fired += 1;
        }
    };
    On.fired = 0;

    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var dummy: u32 = 0;
    const r = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
        .selected_date = .{ .year = 2026, .month = 3, .day = 10 },
        .on_select = .{ .callback = On.cb, .context = @ptrCast(&dummy) },
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    // 移到 14
    try std.testing.expect(r.state.handleKey(.right));
    try std.testing.expect(r.state.handleKey(.right));
    try std.testing.expect(r.state.handleKey(.right));
    try std.testing.expect(r.state.handleKey(.right));
    try std.testing.expectEqual(@as(u8, 14), r.state.keyboard_cursor.?.day);

    // Enter -> selectDate
    try std.testing.expect(r.state.handleKey(.@"return"));
    try std.testing.expectEqual(@as(u32, 1), On.fired);
    try std.testing.expectEqual(@as(u8, 14), r.state.selected_date.?.day);
}

test "container focusable + on_key_down wired (smoke)" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 400);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);

    try std.testing.expect(r.wrapper.behavior.interaction.focusable);
    try std.testing.expectEqual(@as(?i32, 0), r.wrapper.behavior.interaction.tab_index);
    try std.testing.expect(r.wrapper.behavior.events.on_key_down != null);
}

test "a11y: Calendar grid/cell 语义 + 月份切换/键盘游标跟随且可撤回" {
    const testing = std.testing;
    var ctx = try Cx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 500);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const r = try Calendar(.{
        .initial_year = 2026,
        .initial_month = 3,
        .selected_date = .{ .year = 2026, .month = 3, .day = 15 },
    }).mount(scope, ctx);
    try root.appendChild(testing.allocator, r.wrapper);
    ctx.layout();
    _ = ctx.render();

    const grid_eid = core.ElementId.fromRaw(r.wrapper.element_id_raw);
    {
        const n = ctx.accessibility_tree.get(grid_eid).?;
        try testing.expectEqual(core.a11y_tree.Role.grid, n.role);
        // 容器 value = 当前视图月份
        try testing.expectEqual(std.hash.Wyhash.hash(0, "March 2026"), n.text_hash);
        // 尚无键盘游标
        try testing.expect(n.active_descendant.isNull());
    }

    // 找到选中 cell（2026-03-15），断言 a11y 树里的 cell 语义
    var selected_cell: ?*Node = null;
    for (r.state.grid.children.items) |week_row| {
        try testing.expectEqual(core.A11yRole.row, week_row.behavior.interaction.a11y.?.role);
        for (week_row.children.items) |cell_node| {
            if (cell_node.behavior.interaction.a11y.?.selected) selected_cell = cell_node;
        }
    }
    {
        const n = ctx.accessibility_tree.get(core.ElementId.fromRaw(selected_cell.?.element_id_raw)).?;
        try testing.expectEqual(core.a11y_tree.Role.cell, n.role);
        try testing.expect(n.state.selected);
        // label 是含年月日的完整描述，不是裸数字
        try testing.expectEqual(std.hash.Wyhash.hash(0, "March 15, 2026"), n.label_hash);
    }

    // 方向键移动 -> 重建后 active_descendant 指向游标 cell（AT 焦点跟着走）
    try testing.expect(r.state.handleKey(.right)); // 15 → 16
    ctx.layout();
    _ = ctx.render();
    {
        const n = ctx.accessibility_tree.get(grid_eid).?;
        try testing.expect(!n.active_descendant.isNull());
        const cursor_node = ctx.accessibility_tree.get(n.active_descendant).?;
        try testing.expectEqual(std.hash.Wyhash.hash(0, "March 16, 2026"), cursor_node.label_hash);
        // 旧选中 cell 已随 rebuild 换代，但选中态仍在（15 号仍 selected）
    }

    // 月份切换 -> 容器 value 更新；切回 -> 撤回到原值
    r.state.nextMonth();
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(std.hash.Wyhash.hash(0, "April 2026"), ctx.accessibility_tree.get(grid_eid).?.text_hash);
    r.state.prevMonth();
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(std.hash.Wyhash.hash(0, "March 2026"), ctx.accessibility_tree.get(grid_eid).?.text_hash);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "calendar: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("calendar", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Calendar(.{ .initial_year = 2026, .initial_month = 9 }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
