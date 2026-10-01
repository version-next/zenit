/// DatePicker Component
///
/// 日期选择器，基于 Popover + Calendar
///
/// 特性:
/// - Input 风格触发器
/// - 弹出 Calendar 选择
/// - 选中日期回显
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
const Scope = @import("../../reactive.zig").Scope;
const events = @import("../../events.zig");
const popover_mod = @import("../popover/mod.zig");
const Popover = popover_mod.Popover;
const calendar_mod = @import("../calendar/mod.zig");
const CalendarComp = calendar_mod.Calendar;
const SimpleDate = calendar_mod.SimpleDate;
const svg_assets = @import("../../svg_assets.zig");
const styles = @import("styles.zig");

/// DatePicker 属性
pub const DatePickerProps = struct {
    placeholder: []const u8 = "Select date...",
    selected_date: ?SimpleDate = null,
    initial_year: u16 = 2025,
    initial_month: u8 = 1,
    width: f32 = 220,
    /// 控件尺寸（与 Button / Input / Select 同一 ControlSize，默认 md）
    size: theme.ControlSize = .md,
    disabled: bool = false,
    on_change: ?core.HandlerRef = null,
    calendar_icon_asset: ?svg_assets.Asset = null,
    prev_icon_asset: ?svg_assets.Asset = null,
    next_icon_asset: ?svg_assets.Asset = null,
    test_id: ?[]const u8 = null,
};

/// DatePicker 状态
pub const DatePickerState = struct {
    selected_date: ?SimpleDate,
    display_node: *Node,
    trigger_node: *Node,
    leading_icon_node: *Node,
    chevron_node: *Node,
    panel_node: *Node,
    calendar_state: *calendar_mod.CalendarState,
    is_open: *Signal(bool),
    on_change: ?core.HandlerRef,
    placeholder: []const u8,
    cx: *Cx,
    /// a11y: trigger value_text（"Mar 22, 2026"）的持久存储，a11y 投影每帧
    /// 读这个 slice，栈上 buf 会悬垂。
    a11y_value_buf: [24]u8 = undefined,

    /// 程序化设置选中日期（null = 清空，显示 placeholder）。
    ///
    /// 此前 DatePickerState 公开但 `updateDisplayLabel` 是私有自由函数,
    /// 直接写 `state.selected_date` **不会刷新显示文本**，属于
    /// "暴露了 state 却没有生效的写入口"。
    ///
    /// 同步日历面板的选中态；不触发 on_change（程序化设值非用户交互）。
    pub fn setSelectedDate(self: *DatePickerState, date: ?SimpleDate) void {
        self.selected_date = date;
        self.calendar_state.selected_date = date;
        updateDisplayLabel(self);
    }

    /// 清空选择（`setSelectedDate(null)` 的语义糖）。
    pub fn clearSelection(self: *DatePickerState) void {
        self.setSelectedDate(null);
    }
};

/// DatePicker mount 结果
pub const DatePickerResult = struct {
    wrapper: *Node,
    state: *DatePickerState,
};

/// 创建 DatePicker
pub fn DatePicker(props: DatePickerProps) DatePickerBuilder {
    return DatePickerBuilder{ .props = props };
}

pub const DatePickerBuilder = struct {
    props: DatePickerProps,

    pub fn placeholder(self: DatePickerBuilder, ph: []const u8) DatePickerBuilder {
        var new = self;
        new.props.placeholder = ph;
        return new;
    }

    pub fn selectedDate(self: DatePickerBuilder, d: SimpleDate) DatePickerBuilder {
        var new = self;
        new.props.selected_date = d;
        return new;
    }

    pub fn onChange(self: DatePickerBuilder, handler_ref: core.HandlerRef) DatePickerBuilder {
        var new = self;
        new.props.on_change = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: DatePickerBuilder, scope: *Scope, cx: *Cx) !DatePickerResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Popover
        const pop_result = try Popover(.{
            .position = .bottom_start,
            .trigger = if (p.disabled) .manual else .click,
            .offset = .{ .static = 4 },
            .flip = false,
            .close_on_outside_click = true,
            .close_on_escape = true,
            // prewarm 已默认关闭：CA-pure surface 首开帧即完整渲染（逐帧截图验证），无需隐藏副本预热。
        }).mount(my_scope, cx);

        // sweep：Popover 返回的 wrapper 由本组件持有，守到 return；下面的子树建好即 adopt
        errdefer cx.freeNode(pop_result.wrapper);
        // 失败时 hooks（useAnimatedBackground 等）登记在 my_scope 上、destroy 会解引用节点：
        // 必须先 dispose my_scope（连带 Popover 子 scope 解绑）再 freeNode, errdefer 逆序，后声明的先跑。
        errdefer my_scope.dispose();
        pop_result.wrapper.meta.ownership.meta.component_name = "DatePicker";
        pop_result.wrapper.behavior.interaction.a11y = .{ .role = .textbox, .disabled = p.disabled };
        if (p.test_id) |tid| {
            pop_result.wrapper.meta.ownership.meta.test_id = tid;
        }

        // 取消 Popover 默认 chrome，DatePicker 自己提供 panel shell。
        pop_result.content.setBackgroundRaw(Color.TRANSPARENT);
        pop_result.content.style.border = .{};
        pop_result.content.style.padding = Padding.ZERO;
        const pop_content_ext = try pop_result.content.style.ensureExtFallible(allocator);
        pop_content_ext.clearShadows();
        pop_content_ext.hit_shape = .auto;
        pop_content_ext.clip_shape = .auto;

        // ---- Trigger：与 Input / Select 同一个 ControlShell（.field）----
        // icon_slot = 日历图标、content_slot = 日期文本（grow，可收缩裁剪）、
        // append_slot = chevron。几何（padding / 圆角 / 行盒高度 / gap）全部来自
        // ControlShell recipe，外框高度 = padding_y × 2 + 行高。
        const has_value = p.selected_date != null;
        const cm = t.control.get(p.size);
        const shell = try control_shell.controlShell(.{
            .size = p.size,
            .variant = .field,
            .disabled = p.disabled,
            .leading_icon = true,
            .style = .{
                .width = .{ .px = p.width },
                .background = t.color.bg_primary,
                .border = .{ .width = 1, .color = styles.triggerBorderColor(false, has_value, t), .radius = cm.radius },
            },
            // 边框色随 open / has_value 由 syncTriggerVisual 驱动；焦点与悬停不另画。
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
        // aria role combobox + haspopup=dialog (Calendar popover)
        // expanded/value_text 由 syncTriggerA11y 跟随开合与选中日期更新。
        trigger.behavior.interaction.a11y = .{
            .role = .combobox,
            .has_popup = .dialog,
            .label = p.placeholder,
            .disabled = p.disabled,
            .expanded = false,
        };
        if (p.test_id) |tid| {
            var buf: [128]u8 = undefined;
            const trigger_tid = std.fmt.bufPrint(&buf, "{s}.trigger", .{tid}) catch null;
            if (trigger_tid) |s| {
                trigger.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                trigger.frame_state.state_bits.flags.test_id_owned = (trigger.meta.ownership.meta.test_id != null);
            }
        }

        const content = shell.content_slot;
        content.style.width = .{ .grow = .{ .min = 0 } };
        content.style.flex_shrink = 1;
        content.style.overflow_hidden = true;
        (try content.style.ensureExtFallible(allocator)).min_width = 0;

        const calendar_icon_asset = p.calendar_icon_asset orelse svg_assets.common.calendar;
        const leading_icon = try core.adoptChild(cx, allocator, shell.icon_slot, try core.iconTint(cx, calendar_icon_asset, styles.leadingIconTint(has_value, t), .{
            .width = .{ .px = cm.icon_size },
            .height = .{ .px = cm.icon_size },
        }));
        try trigger.replaceChildOrder(allocator, &.{ shell.icon_slot, content });
        icon_slot_detached = false;

        // 显示文本
        var label_buf: [24]u8 = undefined;
        const display_text = if (p.selected_date) |date| formatDisplayDate(date, &label_buf) else p.placeholder;
        const display_node = try core.adoptChild(cx, allocator, content, try core.text(cx, display_text, .{}));
        if (display_node.getText()) |old| {
            var txt = old;
            if (has_value) try txt.setContent(cx.allocator, display_text);
            txt.color = styles.displayTextColor(has_value, t);
            txt.font_size = cm.font_size;
            txt.line_height = cm.line_height;
            display_node.setText(txt);
        }
        if (p.test_id) |tid| {
            var buf: [128]u8 = undefined;
            const label_tid = std.fmt.bufPrint(&buf, "{s}.label", .{tid}) catch null;
            if (label_tid) |s| {
                display_node.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                display_node.frame_state.state_bits.flags.test_id_owned = (display_node.meta.ownership.meta.test_id != null);
            }
        }
        const chevron_icon = try core.adoptChild(cx, allocator, shell.append_slot, try core.iconTint(cx, svg_assets.common.chevron_down, styles.chevronTint(false, t), .{
            .width = .{ .px = cm.icon_size },
            .height = .{ .px = cm.icon_size },
        }));
        append_slot_detached = false;
        _ = try core.adoptChild(cx, allocator, trigger, shell.append_slot);

        // ---- Calendar 内容 ----
        const select_ctx = try allocator.create(DateSelectCtx);
        select_ctx.* = .{ .state = undefined, .is_open = pop_result.is_open };
        try my_scope.adoptResource(@ptrCast(select_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*DateSelectCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);

        const select_handler = core.HandlerRef{
            .callback = dateSelectHandler,
            .context = @ptrCast(select_ctx),
        };

        // panelStyle 内含 shadow（BoxStyle.shadow -> ensureExt.setShadow，等价旧的手动 ext 写入）
        // panel 先建并挂进 popover content，日历 / Today 建好即 adopt
        const panel = try core.adoptChild(cx, allocator, pop_result.content, try box(cx, styles.panelStyle(t), .{}));
        panel.meta.ownership.meta.component_name = "DatePickerPanel";
        if (p.test_id) |tid| {
            var buf: [128]u8 = undefined;
            const panel_tid = std.fmt.bufPrint(&buf, "{s}.panel", .{tid}) catch null;
            if (panel_tid) |s| {
                panel.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                panel.frame_state.state_bits.flags.test_id_owned = (panel.meta.ownership.meta.test_id != null);
            }
        }
        const panel_ext = try panel.style.ensureExtFallible(allocator);
        panel_ext.hit_shape = .{ .rounded_rect = styles.panel_radius };
        panel_ext.clip_shape = .{ .rounded_rect = styles.panel_radius };
        // 让 panel 空白区域也拦截指针事件，防止穿透到底层内容
        panel_ext.hit_roles = .{ .pointer = true, .scroll = false, .inspect = true };

        const cal_result = try CalendarComp(.{
            .initial_year = p.initial_year,
            .initial_month = p.initial_month,
            .selected_date = p.selected_date,
            .on_select = select_handler,
            .cell_size = 32,
            .prev_icon_asset = p.prev_icon_asset orelse svg_assets.common.chevron_left,
            .next_icon_asset = p.next_icon_asset orelse svg_assets.common.chevron_right,
        }).mount(my_scope, cx);
        _ = try core.adoptChild(cx, allocator, panel, cal_result.wrapper);

        // Calendar 内层去 chrome，交给 DatePicker panel shell。
        cal_result.wrapper.style.width = .{ .grow = .{} };
        cal_result.wrapper.setBackgroundRaw(Color.TRANSPARENT);
        cal_result.wrapper.style.border = .{};
        cal_result.wrapper.style.padding = Padding.ZERO;

        // Today：Button 组件（尺寸跟随 control metrics，hover 走按钮自身动画）；
        // 覆盖为浅填充、无边框、占满宽度。
        const today_ctx = try allocator.create(TodayClickCtx);
        today_ctx.* = .{ .select_ctx = select_ctx };
        try my_scope.adoptResource(@ptrCast(today_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*TodayClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        const today_btn = try core.adoptChild(cx, allocator, panel, try button_mod.Button(.{
            .label = "Today",
            .variant = .secondary,
            .size = p.size,
            .style = styles.todayBtnOverride(t),
            .hover_style = .{ .background = t.color.bg_active },
            .on_click = core.Cx.simpleHandler(todayClickHandler, @ptrCast(today_ctx)),
        }).mount(my_scope, cx));
        if (p.test_id) |tid| {
            var buf: [128]u8 = undefined;
            const today_tid = std.fmt.bufPrint(&buf, "{s}.today", .{tid}) catch null;
            if (today_tid) |s| {
                today_btn.meta.ownership.meta.test_id = allocator.dupe(u8, s) catch null;
                today_btn.frame_state.state_bits.flags.test_id_owned = (today_btn.meta.ownership.meta.test_id != null);
            }
        }

        // State
        const state = try allocator.create(DatePickerState);
        state.* = .{
            .selected_date = p.selected_date,
            .display_node = display_node,
            .trigger_node = trigger,
            .leading_icon_node = leading_icon,
            .chevron_node = chevron_icon,
            .panel_node = panel,
            .calendar_state = cal_result.state,
            .is_open = pop_result.is_open,
            .on_change = p.on_change,
            .placeholder = p.placeholder,
            .cx = cx,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*DatePickerState, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);

        select_ctx.state = state;
        select_ctx.cal_state = cal_result.state;

        // 初始选中日期也要进 a11y value（AT 打开界面第一次读就要有值）
        syncTriggerA11y(state, false);

        const open_ctx = try allocator.create(OpenEffectCtx);
        open_ctx.* = .{ .state = state, .cx = cx };
        try my_scope.adoptResource(@ptrCast(open_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*OpenEffectCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        try my_scope.createEffect(.{
            .is_open = pop_result.is_open,
            .open_ctx = open_ctx,
        }, struct {
            fn update(c: anytype) void {
                const oc: *OpenEffectCtx = c.open_ctx;
                syncTriggerVisual(oc.state, c.is_open.get());
            }
        }.update);

        return .{ .wrapper = pop_result.wrapper, .state = state };
    }
};

// ========== 内部辅助 ==========

const Signal = core.Signal;

const DateSelectCtx = struct {
    state: *DatePickerState,
    is_open: *Signal(bool),
    cal_state: *calendar_mod.CalendarState = undefined,
};

const TodayClickCtx = struct {
    select_ctx: *DateSelectCtx,
};

const OpenEffectCtx = struct {
    state: *DatePickerState,
    cx: *Cx,
};

fn dateSelectHandler(ctx_ptr: ?*anyopaque) void {
    if (ctx_ptr) |ctx| {
        const dc: *DateSelectCtx = @ptrCast(@alignCast(ctx));
        if (dc.cal_state.selected_date) |date| {
            dc.state.selected_date = date;
            updateDisplayLabel(dc.state);

            // 关闭弹出
            dc.is_open.set(false);

            if (dc.state.on_change) |handler| handler.invoke();
        }
    }
}

fn todayClickHandler(ctx_ptr: *anyopaque) void {
    const tc: *TodayClickCtx = @ptrCast(@alignCast(ctx_ptr));
    const today = calendar_mod.currentLocalDate() orelse return;
    tc.select_ctx.cal_state.selectDate(today);
    tc.select_ctx.is_open.set(false);
}

fn updateDisplayLabel(state: *DatePickerState) void {
    var buf: [24]u8 = undefined;
    const label = if (state.selected_date) |date| formatDisplayDate(date, &buf) else state.placeholder;
    // 分配式写入：inline 缓冲只有 16 字节，调用方给的 placeholder 会被截断。
    state.display_node.setTextContent(state.cx.allocator, label) catch {};
    if (state.display_node.getText()) |old| {
        var txt = old;
        txt.color = styles.displayTextColor(state.selected_date != null, state.cx.tokens);
        state.display_node.setText(txt);
    }
    state.display_node.markRenderDirty();
    syncTriggerA11y(state, state.is_open.peek());
}

/// a11y 状态跟随交互（form_field 模式）：expanded 跟开合、value_text 跟选中
/// 日期；撤回选择时 value 也必须撤回，否则 AT 播报的是已清空的旧值。
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
    const t = state.cx.tokens;
    const has_value = state.selected_date != null;

    state.trigger_node.setBorderColor(styles.triggerBorderColor(open, has_value, t));

    _ = state.leading_icon_node.setTint(styles.leadingIconTint(has_value, t));

    _ = state.chevron_node.setTint(styles.chevronTint(open, t));
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

// ========== 测试 ==========

test "DatePicker: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(result.state.selected_date == null);
    if (result.state.display_node.getText()) |txt| {
        try std.testing.expectEqualStrings("Select date...", txt.content);
    } else {
        try std.testing.expect(false);
    }
}

test "DatePicker: with initial date" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
        .selected_date = .{ .year = 2025, .month = 6, .day = 15 },
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(result.state.selected_date != null);
    try std.testing.expectEqual(@as(u8, 15), result.state.selected_date.?.day);
    if (result.state.display_node.getText()) |txt| {
        try std.testing.expectEqualStrings("Jun 15, 2025", txt.content);
    } else {
        try std.testing.expect(false);
    }
}

test "DatePicker: selecting date updates label and closes popover" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{}).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    result.state.is_open.set(true);
    result.state.calendar_state.selectDate(.{ .year = 2026, .month = 3, .day = 22 });

    try std.testing.expect(!result.state.is_open.peek());
    try std.testing.expectEqual(@as(u16, 2026), result.state.selected_date.?.year);
    if (result.state.display_node.getText()) |txt| {
        try std.testing.expectEqualStrings("Mar 22, 2026", txt.content);
    } else {
        try std.testing.expect(false);
    }
}

test "DatePicker: open render emits full calendar day texts after prewarm settles" {
    // History: 此测试原名 "first open render already emits..."，期望 set(is_open=true)
    // 后单帧就能看到 calendar texts。实测 popover prewarm 路径需要多帧才让 panel
    // 内容进入 render command stream（可能 prewarm + animation initial 各占一帧）。
    // 改成跑多帧直到 settle。这反映真实行为，用户视觉上"open"也是经过 transition。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{
        .width = .{ .px = 640 },
        .height = .{ .px = 480 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.state.is_open.set(true);

    // 跑多帧让 popover prewarm + 入场动画 settle。当前实测 2 帧足够。
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
    // History: 同样需要多帧 settle 才能进入 panel render 状态（见上一 test 注释）。
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{
        .width = .{ .px = 640 },
        .height = .{ .px = 480 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    result.state.is_open.set(true);

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

    // P6.3 后 DatePicker panel 走 composited_group surface。断言真正不变量「day text + Today 被绘制」，而非旧的 opacity-layer
    // 包裹（那条 promoted-surface 路径会丢 children，见 docs/BUGS.md）。
    try std.testing.expect(day_idx != null);
    try std.testing.expect(today_idx != null);
}

test "DatePicker: disabled stays inert and keeps overlay collapsed" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
        .disabled = true,
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();

    try std.testing.expect(!result.state.is_open.peek());
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    try std.testing.expect(result.wrapper.children.items[0].behavior.events.on_click == null);
    const detached_panel_host = result.state.panel_node.parent.?;
    try std.testing.expect(detached_panel_host.parent == null);
    try std.testing.expectEqual(@as(f32, 0), detached_panel_host.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 0), detached_panel_host.rectFromWorldOrFallback().h);
}

test "DatePicker: first 10 open frames progress from enter state instead of flashing" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);

    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
        .initial_year = 2026,
        .initial_month = 3,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();

    result.state.is_open.set(true);
    const animated_container = result.state.panel_node.parent.?;

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
    var ctx = try Cx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(640, 480);
    const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try DatePicker(.{
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
        try testing.expect(n.state.expanded_present);
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(@as(u64, 0), n.text_hash); // 未选择 → 无 value
    }

    // 打开 -> expanded=true
    result.state.is_open.set(true);
    ctx.layout();
    _ = ctx.render();
    try testing.expect(ctx.accessibility_tree.get(eid).?.state.expanded);

    // 选中日期 -> 面板关闭（expanded 撤回）+ value 播报可读日期
    result.state.calendar_state.selectDate(.{ .year = 2026, .month = 3, .day = 22 });
    ctx.layout();
    _ = ctx.render();
    {
        const n = ctx.accessibility_tree.get(eid).?;
        try testing.expect(!n.state.expanded);
        try testing.expectEqual(std.hash.Wyhash.hash(0, "Mar 22, 2026"), n.text_hash);
    }

    // 清空选择 -> value 必须撤回（不能一直播报旧日期）
    result.state.clearSelection();
    ctx.layout();
    _ = ctx.render();
    try testing.expectEqual(@as(u64, 0), ctx.accessibility_tree.get(eid).?.text_hash);
}

test "DatePicker: trigger 主体槽吃满剩余宽度，chevron 贴右（与 Select content_slot 同合同）" {
    // 回归：旧版主体槽 fit 宽度只包住「图标 + 文本」，与 chevron 之间留一段
    // 不属于任何元素的空白（220 宽 trigger 空 ~88px）；长文本还会把 chevron 顶出 trigger。
    const testing = std.testing;
    // 第二组：窄 trigger 放不下内容 -> 主体槽收缩裁剪，chevron 仍在 trigger 内贴右。
    inline for (.{ .{ "Pick a date", 220 }, .{ "A very long placeholder that cannot possibly fit inside", 120 } }) |case| {
        const placeholder = case[0];
        const w: f32 = case[1];
        var ctx = try Cx.init(testing.allocator);
        defer ctx.deinit();
        ctx.setViewport(640, 480);
        const root = try box(ctx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(testing.allocator, null, ctx.owner);
        defer scope.dispose();

        const result = try DatePicker(.{ .placeholder = placeholder, .width = w }).mount(scope, ctx);
        try root.appendChild(testing.allocator, result.wrapper);
        ctx.layout();

        // 全部取全局 rect（chevron 在 append_slot 里，局部 rect 不同帧）；padding / gap
        // 取 trigger 实际样式（ControlShell recipe 产出）。
        const tn = result.state.trigger_node;
        const trigger = tn.globalRect();
        const icon_slot = tn.children.items[0].globalRect();
        const slot = result.state.display_node.parent.?.globalRect();
        const chevron = result.state.chevron_node.globalRect();
        const pad = tn.style.padding;
        const gap = tn.style.gap;

        try testing.expectApproxEqAbs(w, trigger.w, 0.5);
        // chevron 贴右侧 padding 边
        try testing.expectApproxEqAbs(trigger.x + trigger.w - pad.right, chevron.x + chevron.w, 0.5);
        // 主体槽从图标槽后的 gap 一直延伸到 chevron 前的 gap，中间无空白
        try testing.expectApproxEqAbs(icon_slot.x + icon_slot.w + gap, slot.x, 0.5);
        try testing.expectApproxEqAbs(chevron.x - gap, slot.x + slot.w, 0.5);
    }
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "date_picker: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("date_picker", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try DatePicker(.{ .initial_year = 2026, .initial_month = 9 }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
