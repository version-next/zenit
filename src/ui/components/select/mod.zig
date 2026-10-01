//! Select, interactive high-level Select component.
//!
//! Visual contract: Pencil `puQEf` (Select Group 2).
//! Behaviour is real: Popover positioning/dismissal, single and multiple
//! selection, clear, searchable filtering, removable tags, hover and keyboard
//! navigation all share one retained component state.

const std = @import("std");
const core = @import("../../core.zig");
const svg_assets = @import("../../svg_assets.zig");
const icons = @import("zenit_system_icons");
const popover_mod = @import("../popover/mod.zig");
const input_mod = @import("../input/mod.zig");
const button_mod = @import("../button/mod.zig");
const control_shell = @import("../control_shell/mod.zig");
const recipe_mod = @import("../../recipe.zig");

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

/// 与 Button / Input / DatePicker 同一套控件尺寸（默认 md）。trigger 外框高度 =
/// padding_y × 2 + font_size × line_height，全部来自 `tokens.control.get(size)`。
pub const SelectSize = core.theme.ControlSize;
pub const SelectMode = enum { single, multiple };

pub const SelectOption = struct {
    value: []const u8,
    label: []const u8,
    disabled: bool = false,
    icon: ?svg_assets.Asset = null,
};

pub const SelectProps = struct {
    options: []const SelectOption = &.{},
    placeholder: []const u8 = "Select an option...",
    width: f32 = 352,
    size: SelectSize = .md,
    mode: SelectMode = .single,
    searchable: bool = false,
    /// Keep the selected label in a searchable single-select trigger. Set to
    /// false for search-first presentations where the trigger should retain
    /// its search placeholder while the selected row remains checked.
    show_selected_value_in_search: bool = true,
    clearable: bool = false,
    leading_icon: ?svg_assets.Asset = null,
    initial_selected: []const usize = &.{},
    disabled: bool = false,
    max_dropdown_height: f32 = 280,
    on_change: ?core.HandlerRef = null,
};

const Metrics = struct {
    /// 选项行 / 勾选图标尺寸上限来源（trigger 几何不在这里，走 control metrics）
    icon_size: f32,
    tag_radius: f32,
    tag_gap: f32,
    tag_padding: core.Padding,
    tag_font: f32,
    close_size: f32,
    panel_radius: f32,
    panel_padding: f32,
    row_radius: f32,
    row_padding: core.Padding,
    row_font: f32,
    checkbox_size: f32,
    checkbox_radius: f32,
    check_size: f32,
};

fn metrics(size: SelectSize) Metrics {
    return switch (size) {
        .sm => metrics(.md),
        .lg => .{
            .icon_size = 20,
            .tag_radius = 4,
            .tag_gap = 4,
            .tag_padding = .{ .top = 2, .right = 6, .bottom = 2, .left = 10 },
            .tag_font = 12,
            .close_size = 12,
            .panel_radius = 8,
            .panel_padding = 4,
            .row_radius = 6,
            .row_padding = .{ .top = 8, .right = 12, .bottom = 8, .left = 12 },
            .row_font = 14,
            .checkbox_size = 18,
            .checkbox_radius = 4,
            .check_size = 14,
        },
        .md => .{
            .icon_size = 16,
            .tag_radius = 3,
            .tag_gap = 3,
            .tag_padding = .{ .top = 2, .right = 4, .bottom = 2, .left = 8 },
            .tag_font = 11,
            .close_size = 10,
            .panel_radius = 8,
            .panel_padding = 4,
            .row_radius = 6,
            .row_padding = core.Padding.all(8),
            .row_font = 12,
            .checkbox_size = 18,
            .checkbox_radius = 4,
            .check_size = 14,
        },
        .xs => .{
            .icon_size = 12,
            .tag_radius = 2,
            .tag_gap = 2,
            .tag_padding = .{ .top = 1, .right = 3, .bottom = 1, .left = 6 },
            .tag_font = 10,
            .close_size = 8,
            .panel_radius = 6,
            .panel_padding = 3,
            .row_radius = 4,
            .row_padding = core.Padding.all(6),
            .row_font = 11,
            .checkbox_size = 14,
            .checkbox_radius = 3,
            .check_size = 10,
        },
    };
}

const Palette = struct {
    bg: Color,
    panel: Color,
    hover: Color,
    inset: Color,
    text_primary: Color,
    text_secondary: Color,
    text_tertiary: Color,
    primary: Color,
    border: Color,
    border_strong: Color,
};

fn palette(t: *const core.theme.ThemeTokens) Palette {
    if (t.scheme == .light) return .{
        .bg = Color.hex(0xFAFAFA),
        .panel = Color.hex(0xFFFFFF),
        .hover = Color.hex(0xF5F5F5),
        .inset = Color.hex(0xEFEFEF),
        .text_primary = Color.hex(0x1A1A1A),
        .text_secondary = Color.hex(0x787878),
        .text_tertiary = Color.hex(0x9B9B9B),
        .primary = Color.hex(0x4A6741),
        .border = Color.hex(0xE5E5E5),
        .border_strong = Color.hex(0xD4D4D4),
    };
    return .{
        .bg = t.color.bg_secondary,
        .panel = t.color.bg_primary,
        .hover = t.color.bg_hover,
        .inset = t.color.bg_tertiary,
        .text_primary = t.color.fg_primary,
        .text_secondary = t.color.fg_secondary,
        .text_tertiary = t.color.fg_tertiary,
        .primary = t.color.accent,
        .border = t.color.border,
        .border_strong = t.color.border_strong,
    };
}

pub const SelectState = struct {
    allocator: Allocator,
    cx: *Cx,
    props: SelectProps,
    metrics: Metrics,
    colors: Palette,
    is_open: *Signal(bool),
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
    option_nodes: []*Node,
    check_nodes: []*Node,
    tag_nodes: []*Node,
    selected_mask: u64 = 0,
    highlighted_index: ?usize = null,
    suppress_search_change: bool = false,
    is_trigger_hovered: bool = false,

    pub fn isSelected(self: *const SelectState, index: usize) bool {
        if (index >= 64) return false;
        return (self.selected_mask & (@as(u64, 1) << @intCast(index))) != 0;
    }

    pub fn selectedValue(self: *const SelectState) ?[]const u8 {
        if (self.props.mode != .single) return null;
        for (self.props.options, 0..) |option, i| {
            if (self.isSelected(i)) return option.value;
        }
        return null;
    }

    pub fn selectedCount(self: *const SelectState) usize {
        return @popCount(self.selected_mask);
    }
};

pub const SelectMount = struct {
    wrapper: *Node,
    trigger: *Node,
    panel: *Node,
    state: *SelectState,
    is_open: *Signal(bool),
};

const ItemContext = struct { state: *SelectState, index: usize };
const ContextHolder = struct {
    items: []ItemContext,
    tags: []ItemContext,
};

fn textNode(cx: *Cx, content: []const u8, size: f32, color: Color, weight: u16) !*Node {
    const node = try core.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{});
    node.setText(.{ .content = content, .font_size = size, .font_weight = weight, .line_height = 1.2, .color = color });
    return node;
}

/// trigger 内文本：字号 / 行高取 control metrics（行盒 = font_size × line_height）。
fn triggerTextNode(cx: *Cx, content: []const u8, cm: core.theme.ControlMetrics, color: Color) !*Node {
    const node = try core.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{});
    node.setText(.{ .content = content, .font_size = cm.font_size, .font_weight = 400, .line_height = cm.line_height, .color = color });
    return node;
}

fn iconNode(cx: *Cx, asset: svg_assets.Asset, size: f32, color: Color) !*Node {
    return core.iconTint(cx, asset, color, .{ .width = .{ .px = size }, .height = .{ .px = size } });
}

fn row(cx: *Cx, gap: f32) !*Node {
    return core.box(cx, .{ .direction = .row, .align_items = .center, .gap = gap }, .{});
}

fn selectedIndex(state: *const SelectState) ?usize {
    for (state.props.options, 0..) |_, i| if (state.isSelected(i)) return i;
    return null;
}

fn syncClearAffordance(state: *SelectState) void {
    const clear = state.clear_button orelse return;
    const show_clear = !state.props.disabled and selectedIndex(state) != null and state.is_trigger_hovered;

    clear.setOpacity(if (show_clear) 1 else 0);
    clear.setHitTestVisible(show_clear);
    clear.setFocusable(show_clear);
    state.chevron_slot.setOpacity(if (show_clear) 0 else 1);
}

fn syncA11y(state: *SelectState) void {
    if (state.trigger.behavior.interaction.a11y) |*a| {
        a.expanded = state.is_open.peek();
        if (state.props.mode == .single) {
            a.value_text = if (selectedIndex(state)) |i| state.props.options[i].label else null;
        }
    }
    for (state.option_nodes, 0..) |node, i| {
        if (node.behavior.interaction.a11y) |*a| a.selected = state.isSelected(i);
    }
    state.trigger.markRenderDirty();
}

fn syncSelection(state: *SelectState) void {
    const m = state.metrics;
    const colors = state.colors;

    if (state.props.mode == .single) {
        const index = selectedIndex(state);
        if (state.trigger_label) |label| {
            const content = if (index) |i| state.props.options[i].label else state.props.placeholder;
            // ⚠ 失败时**不能**继续往下走：下面那段会把 label 当前（即旧的）
            // 文本连同新颜色一起 setText 回去，等于把"状态已选 B、显示仍是 A"
            // 这个分叉固化下来，并且配上新配色，看起来完全正常。
            // 选中值本身已在别处提交，所以这不只是显示问题，任何回读标签
            // 文本的路径都会拿到旧值。
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
        for (state.tag_nodes, 0..) |tag_node, i| tag_node.setDisplay(if (state.isSelected(i)) .flex else .none);
    }

    for (state.option_nodes, state.check_nodes, 0..) |option_node, check_node, i| {
        const selected = state.isSelected(i);
        const highlighted = state.highlighted_index != null and state.highlighted_index.? == i;
        option_node.setBackgroundRaw(if (highlighted) colors.hover else Color.TRANSPARENT);
        if (state.props.mode == .single) {
            check_node.setOpacityRaw(if (selected) 1 else 0);
        } else {
            check_node.setBackgroundRaw(if (selected) colors.primary else colors.bg);
            check_node.style.border.width = if (selected) 0 else 1.5;
            if (check_node.children.items.len > 0) check_node.children.items[0].setOpacityRaw(if (selected) 1 else 0);
        }
        option_node.markRenderDirty();
        check_node.markRenderDirty();
    }
    _ = m;
    // Clearable single-select keeps one fixed-size append slot. A selected
    // value only reveals the close affordance while the trigger is hovered;
    // otherwise it looks exactly like every other Select.
    syncOpen(state, state.is_open.peek());
}

fn syncOpen(state: *SelectState, open: bool) void {
    state.trigger.setBorderColor(if (open) state.colors.primary else state.colors.border);
    // One downward chevron rotates into the open state. Keeping a single icon
    // avoids the cross-fade flicker caused by swapping up/down SVG nodes.
    state.chevron_down.setRotate(state.allocator, if (open) std.math.pi else 0);
    state.chevron_down.setOpacityRaw(1);
    state.chevron_up.setOpacityRaw(0);
    syncA11y(state);
}

fn emitChange(state: *SelectState) void {
    if (state.props.on_change) |handler| handler.invoke();
}

fn applyFilter(state: *SelectState, query: []const u8) void {
    for (state.props.options, state.option_nodes) |option, node| {
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

fn clearSearch(state: *SelectState) void {
    const input_state = state.input_state orelse return;
    state.suppress_search_change = true;
    input_state.selectAll();
    input_state.insertText("");
    applyFilter(state, "");
}

fn commit(state: *SelectState, index: usize) void {
    if (index >= state.props.options.len or state.props.options[index].disabled) return;
    const bit = @as(u64, 1) << @intCast(index);
    if (state.props.mode == .single) {
        state.selected_mask = bit;
        if (state.props.searchable) {
            if (state.input_state) |input_state| {
                state.suppress_search_change = true;
                input_state.selectAll();
                input_state.insertText(state.props.options[index].label);
            }
        }
        state.is_open.set(false);
    } else {
        state.selected_mask ^= bit;
        if (state.props.searchable) clearSearch(state);
    }
    syncSelection(state);
    emitChange(state);
}

fn onSearchChanged(state: *SelectState, value: []const u8) void {
    if (state.suppress_search_change) {
        state.suppress_search_change = false;
        return;
    }
    if (state.props.mode == .single) state.selected_mask = 0;
    applyFilter(state, value);
    if (!state.is_open.peek()) state.is_open.set(true);
    syncSelection(state);
}

fn triggerEvent(event: Event, context: ?*anyopaque) EventResult {
    const state: *SelectState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.props.disabled) return .ignored;
    switch (event) {
        .click => {
            state.is_open.set(!state.is_open.peek());
            return .stop;
        },
        .mouse_enter => {
            state.is_trigger_hovered = true;
            syncClearAffordance(state);
            return .handled;
        },
        .mouse_leave => {
            state.is_trigger_hovered = false;
            syncClearAffordance(state);
            return .handled;
        },
        else => return .ignored,
    }
}

fn clearEvent(event: Event, context: ?*anyopaque) EventResult {
    const state: *SelectState = @ptrCast(@alignCast(context orelse return .ignored));
    if (event != .click) return .ignored;
    state.selected_mask = 0;
    if (state.props.searchable) clearSearch(state);
    state.is_open.set(false);
    syncSelection(state);
    emitChange(state);
    return .stop;
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
            syncSelection(ctx.state);
            return .handled;
        },
        .mouse_leave => {
            if (ctx.state.highlighted_index == ctx.index) ctx.state.highlighted_index = null;
            syncSelection(ctx.state);
            return .handled;
        },
        else => return .ignored,
    }
}

fn tagCloseEvent(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *ItemContext = @ptrCast(@alignCast(context orelse return .ignored));
    if (event != .click) return .ignored;
    if (ctx.index < 64) ctx.state.selected_mask &= ~(@as(u64, 1) << @intCast(ctx.index));
    syncSelection(ctx.state);
    emitChange(ctx.state);
    return .stop;
}

fn nextVisible(state: *SelectState, start: usize, forward: bool) ?usize {
    if (state.props.options.len == 0) return null;
    var index = start;
    var seen: usize = 0;
    while (seen < state.props.options.len) : (seen += 1) {
        index = if (forward)
            (index + 1) % state.props.options.len
        else if (index == 0)
            state.props.options.len - 1
        else
            index - 1;
        const node = state.option_nodes[index];
        if (node.getOpacity() > 0.5 and !state.props.options[index].disabled) return index;
    }
    return null;
}

fn triggerKeyDown(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const state: *SelectState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.props.disabled) return .ignored;
    switch (key) {
        .escape => {
            state.is_open.set(false);
            state.highlighted_index = null;
        },
        .down, .up => {
            if (!state.is_open.peek()) state.is_open.set(true);
            const forward = key == .down;
            // 空 options 时 len - 1 下溢 panic；nextVisible 对空列表返回 null
            const start = state.highlighted_index orelse if (forward) state.props.options.len -| 1 else 0;
            state.highlighted_index = nextVisible(state, start, forward);
        },
        .home => {
            state.highlighted_index = null;
            var i: usize = 0;
            while (i < state.props.options.len) : (i += 1) {
                if (state.option_nodes[i].getOpacity() > 0.5 and !state.props.options[i].disabled) {
                    state.highlighted_index = i;
                    break;
                }
            }
        },
        .end => {
            state.highlighted_index = null;
            var i = state.props.options.len;
            while (i > 0) {
                i -= 1;
                if (state.option_nodes[i].getOpacity() > 0.5 and !state.props.options[i].disabled) {
                    state.highlighted_index = i;
                    break;
                }
            }
        },
        .@"return", .space => {
            if (state.highlighted_index) |i| commit(state, i) else state.is_open.set(!state.is_open.peek());
        },
        else => return .ignored,
    }
    syncSelection(state);
    return .stop;
}

fn buildTag(state: *SelectState, option: SelectOption, index: usize, ctx: *ItemContext) !*Node {
    const node = try core.box(state.cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = state.metrics.tag_gap,
        .padding = state.metrics.tag_padding,
        .background = state.colors.inset,
        .corner_radius = state.metrics.tag_radius,
    }, .{});
    try node.appendChild(state.allocator, try textNode(state.cx, option.label, state.metrics.tag_font, state.colors.text_primary, 400));
    const close = try core.box(state.cx, .{
        .width = .{ .px = state.metrics.close_size },
        .height = .{ .px = state.metrics.close_size },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .cursor = .pointer,
    }, .{});
    try close.appendChild(state.allocator, try iconNode(state.cx, icons.close, state.metrics.close_size, state.colors.text_secondary));
    ctx.* = .{ .state = state, .index = index };
    close.behavior.events.event_context = @ptrCast(ctx);
    close.behavior.events.on_event = tagCloseEvent;
    try node.appendChild(state.allocator, close);
    return node;
}

fn stripSearchInput(result: input_mod.InputResult) void {
    // The Select owns all chrome and horizontal spacing. The embedded Input
    // contributes only an editable, shrinkable content surface; keeping the
    // regular Input padding here would double the icon/text gap, while a
    // fixed width lets long multi-select tags run underneath the append slot.
    result.node.style.width = .{ .grow = .{ .min = 0 } };
    result.node.style.flex_shrink = 1;
    result.node.style.gap = 0;
    result.node.style.ensureExtPanic(result.state.allocator).min_width = 0;
    if (result.node.children.items.len > 0) {
        const field_shell = result.node.children.items[0];
        field_shell.style.width = .{ .grow = .{ .min = 0 } };
        field_shell.style.flex_shrink = 1;
        field_shell.style.ensureExtPanic(result.state.allocator).min_width = 0;
        field_shell.style.border.width = 0;
    }
    result.input_container.style.width = .{ .grow = .{ .min = 0 } };
    result.input_container.style.flex_shrink = 1;
    result.input_container.style.ensureExtPanic(result.state.allocator).min_width = 0;
    result.input_container.style.height = .{ .fit = .{} };
    result.input_container.style.padding = core.Padding.ZERO;
    result.input_container.style.border.width = 0;
    result.input_container.setBackgroundRaw(Color.TRANSPARENT);

    result.state.padding_h = 0;
    if (result.state.text_display_node) |text| text.style.padding.left = -result.state.scroll_x;
}

pub fn mountSelect(props: SelectProps, scope: *Scope, cx: *Cx) !SelectMount {
    if (props.options.len > 64) return error.TooManySelectOptions;
    const my_scope = try scope.childScope();
    const allocator = cx.allocator;
    const m = metrics(props.size);
    const colors = palette(cx.tokens);
    // trigger 几何全部来自 control metrics（与 Button / Input / DatePicker 同源）；
    // 外框高度由 padding_y × 2 + 行高 fit 撑出。可搜索单选不再有写死的「紧凑」几何。
    const shell_size: core.theme.ControlSize = props.size;
    const cm = cx.tokens.control.get(shell_size);
    const trigger_padding = core.Padding{
        .top = cm.padding_y,
        .right = cm.padding_h,
        .bottom = cm.padding_y,
        .left = cm.padding_leading_icon,
    };
    const trigger_radius: f32 = cm.radius;
    const trigger_icon_size: f32 = cm.icon_size;
    const shell_gap: f32 = cm.gap;

    var pop = try popover_mod.Popover(.{
        .position = .bottom_start,
        .trigger = .manual,
        .offset = .{ .static = 4 },
        .flip = true,
        .width = props.width,
        .match_trigger_width = true,
        .constrain_width_to_viewport = true,
        .max_height = props.max_dropdown_height,
        // 锚定下拉面板：160ms 淡入 + 0.98 缩放 + 6px 贴锚点滑入（flip 时方向跟随）。
        .enter_transition = .dropdown,
        .exit_transition = .dropdown,
    }).mount(my_scope, cx);
    // sweep：wrapper 守到 return；失败先 dispose my_scope（hook / resource 在节点存活期 destroy）再 freeNode
    errdefer cx.freeNode(pop.wrapper);
    errdefer my_scope.dispose();
    pop.wrapper.meta.ownership.meta.component_name = "Select";
    pop.trigger.style.width = .{ .px = props.width };
    pop.trigger.style.height = .{ .fit = .{} };

    const state = try my_scope.allocator.create(SelectState);
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            alloc.destroy(@as(*SelectState, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);

    const holder = try my_scope.allocator.create(ContextHolder);
    {
        // 两次 alloc 不能写在同一个初始化器里：第二次失败时第一次已分配却无人释放。
        errdefer my_scope.allocator.destroy(holder);
        const items = try my_scope.allocator.alloc(ItemContext, props.options.len);
        errdefer my_scope.allocator.free(items);
        const tags = try my_scope.allocator.alloc(ItemContext, props.options.len);
        holder.* = .{ .items = items, .tags = tags };
    }
    try my_scope.adoptResource(@ptrCast(holder), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const h: *ContextHolder = @ptrCast(@alignCast(ptr));
            alloc.free(h.items);
            alloc.free(h.tags);
            alloc.destroy(h);
        }
    }.destroy);

    // 三个 slice 在登记之前各自守着；从 adoptResource 那一刻起所有权二选一
    // （成功归 scope / 失败由 destroy 当场连 slice 一起释放），errdefer 都不能再跑。
    var slices_adopted = false;
    const option_nodes = try my_scope.allocator.alloc(*Node, props.options.len);
    errdefer if (!slices_adopted) my_scope.allocator.free(option_nodes);
    const check_nodes = try my_scope.allocator.alloc(*Node, props.options.len);
    errdefer if (!slices_adopted) my_scope.allocator.free(check_nodes);
    const tag_nodes = try my_scope.allocator.alloc(*Node, props.options.len);
    errdefer if (!slices_adopted) my_scope.allocator.free(tag_nodes);
    const NodeSlices = struct { options: []*Node, checks: []*Node, tags: []*Node };
    const slices = try my_scope.allocator.create(NodeSlices);
    slices.* = .{ .options = option_nodes, .checks = check_nodes, .tags = tag_nodes };
    slices_adopted = true;
    try my_scope.adoptResource(@ptrCast(slices), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const s: *NodeSlices = @ptrCast(@alignCast(ptr));
            alloc.free(s.options);
            alloc.free(s.checks);
            alloc.free(s.tags);
            alloc.destroy(s);
        }
    }.destroy);

    // Select uses the same three-slot shell as Button/Input. Business content
    // can now shrink only inside content_slot, while clear + chevron remain a
    // fixed append component and never overlap searchable text.
    const trigger_shell = try control_shell.controlShell(.{
        .size = shell_size,
        .variant = .field,
        .disabled = props.disabled,
        .style = .{
            .width = .{ .px = props.width },
            .height = .{ .fit = .{} },
            .padding = trigger_padding,
            .background = colors.bg,
            .border = .{ .width = 1, .color = colors.border, .radius = trigger_radius },
            .corner_radius = trigger_radius,
            .gap = shell_gap,
            .cursor = if (props.disabled) .default else .pointer,
        },
        .interactive = false,
        .focus_ring = false,
        .cursor = if (props.disabled) .default else .pointer,
    }, my_scope, cx);
    // controlShell 的 icon_slot / append_slot 是游离节点：挂上或 destroy 之前都要守
    //（包括紧接着 adopt shell.node 失败的那一步）；标志在 adoptChild **之前**翻
    //（adopt 失败时它自己 freeNode，这里不能再 free 一次）
    var icon_slot_detached = true;
    errdefer if (icon_slot_detached) cx.freeNode(trigger_shell.icon_slot);
    var append_slot_detached = true;
    errdefer if (append_slot_detached) cx.freeNode(trigger_shell.append_slot);
    const shell = try core.adoptChild(cx, allocator, pop.trigger, trigger_shell.node);

    const content = trigger_shell.content_slot;
    content.style.width = .{ .grow = .{ .min = 0 } };
    content.style.flex_shrink = 1;
    content.style.gap = if (props.size == .xs) 3 else if (props.mode == .multiple) 4 else 8;
    content.style.overflow_hidden = true;
    (try content.style.ensureExtFallible(allocator)).min_width = 0;

    var leading_icon_node: ?*Node = null;
    const leading_asset = props.leading_icon orelse if (props.searchable and props.mode == .single) icons.search else null;
    if (leading_asset) |asset| {
        const leading = try core.adoptChild(cx, allocator, trigger_shell.icon_slot, try iconNode(cx, asset, trigger_icon_size, colors.text_tertiary));
        leading_icon_node = leading;
        try shell.replaceChildOrder(allocator, &.{ trigger_shell.icon_slot, content });
        icon_slot_detached = false;
    } else {
        cx.freeNode(trigger_shell.icon_slot); // Node.destroy 不回收 World element slot
        icon_slot_detached = false;
    }

    state.* = .{
        .allocator = allocator,
        .cx = cx,
        .props = props,
        .metrics = m,
        .colors = colors,
        .is_open = pop.is_open,
        .trigger = shell,
        .content_slot = content,
        .append_slot = trigger_shell.append_slot,
        .append_comp = undefined,
        .leading_icon_node = leading_icon_node,
        .chevron_slot = undefined,
        .trigger_label = null,
        .panel = pop.content,
        .chevron_up = undefined,
        .chevron_down = undefined,
        .clear_button = null,
        .input_state = null,
        .option_nodes = option_nodes,
        .check_nodes = check_nodes,
        .tag_nodes = tag_nodes,
    };

    for (props.initial_selected) |i| if (i < props.options.len) {
        if (props.mode == .single) state.selected_mask = @as(u64, 1) << @intCast(i) else state.selected_mask |= @as(u64, 1) << @intCast(i);
    };

    if (props.mode == .multiple) {
        const tags = try core.adoptChild(cx, allocator, content, try row(cx, if (props.size == .xs) 3 else 4));
        for (props.options, 0..) |option, i| {
            const tag_node = try core.adoptChild(cx, allocator, tags, try buildTag(state, option, i, &holder.tags[i]));
            tag_nodes[i] = tag_node;
        }
    } else for (tag_nodes) |*slot| slot.* = shell;

    if (props.searchable) {
        const initial_text = if (props.mode == .single and props.show_selected_value_in_search) blk: {
            if (selectedIndex(state)) |i| break :blk props.options[i].label;
            break :blk null;
        } else null;
        const input_result = try input_mod.Input(.{
            .initial_value = initial_text,
            .placeholder = if (props.mode == .single) props.placeholder else "Search...",
            .placeholder_color = colors.text_tertiary,
            .size = shell_size,
            .width = @max(@as(f32, 88), props.width * 0.38),
            .disabled = props.disabled,
            .embedded = true,
            .on_change = core.Cx.strHandlerFrom(SelectState, state, onSearchChanged),
        }).mountResult(my_scope, cx);
        stripSearchInput(input_result);
        _ = try core.adoptChild(cx, allocator, content, input_result.node);
        state.input_state = input_result.state;
    } else if (props.mode == .single) {
        const label = try core.adoptChild(cx, allocator, content, try triggerTextNode(cx, props.placeholder, cm, colors.text_tertiary));
        label.style.width = .{ .grow = .{} };
        state.trigger_label = label;
    }
    // The append component is permanently one icon wide. Chevron and the real
    // icon-only clear Button occupy the same 20x20 plane; the clear Button is
    // an absolute overlay revealed only while a selected trigger is hovered.
    const append_comp = try core.adoptChild(cx, allocator, trigger_shell.append_slot, try core.box(cx, .{
        .width = .{ .px = trigger_icon_size },
        .height = .{ .px = trigger_icon_size },
        .direction = .row,
        .align_items = .center,
        .justify = .end,
    }, .{}));
    state.append_comp = append_comp;
    const chevron_stack = try core.adoptChild(cx, allocator, append_comp, try core.box(cx, .{
        .width = .{ .px = trigger_icon_size },
        .height = .{ .px = trigger_icon_size },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
    }, .{}));
    if (props.clearable and props.mode == .single and !props.searchable) {
        const clear = try core.adoptChild(cx, allocator, append_comp, try button_mod.Button(.{
            .variant = .ghost,
            .size = .xs,
            .icon_only = true,
            .icon_asset = icons.close,
            .icon_size = trigger_icon_size,
            .icon_tint = colors.text_tertiary,
            .style = .{
                .width = .{ .px = trigger_icon_size },
                .height = .{ .px = trigger_icon_size },
                .padding = core.Padding.all(0),
                .background = colors.bg,
                .corner_radius = @min(4, trigger_radius),
                .overflow_hidden = true,
            },
            .hover_style = .{ .background = colors.hover },
            .pressed_style = .{ .background = colors.inset },
            .on_event = clearEvent,
            .event_context = @ptrCast(state),
        }).mount(my_scope, cx));
        clear.style.position = .absolute;
        clear.applyTransition(allocator, &comptime recipe_mod.transition("opacity 160ms ease-out"));
        clear.snapTransition(allocator, .opacity, 0);
        state.clear_button = clear;
    }
    const chevron_down = try core.adoptChild(cx, allocator, chevron_stack, try iconNode(cx, icons.chevron_down, trigger_icon_size, colors.text_tertiary));
    const chevron_up = try core.adoptChild(cx, allocator, chevron_stack, try iconNode(cx, icons.chevron_up, trigger_icon_size, colors.primary));
    chevron_down.style.position = .absolute;
    chevron_up.style.position = .absolute;
    state.chevron_down = chevron_down;
    state.chevron_up = chevron_up;
    state.chevron_slot = chevron_stack;
    chevron_stack.applyTransition(allocator, &comptime recipe_mod.transition("opacity 160ms ease-out"));
    chevron_stack.snapTransition(allocator, .opacity, 1);
    chevron_down.applyTransition(allocator, &comptime recipe_mod.transition("rotate 180ms ease-in-out"));
    chevron_down.snapTransition(allocator, .rotate, 0);
    append_slot_detached = false;
    _ = try core.adoptChild(cx, allocator, shell, trigger_shell.append_slot);

    shell.behavior.events.event_context = @ptrCast(state);
    shell.behavior.events.on_event = triggerEvent;
    pop.trigger.behavior.events.key_context = @ptrCast(state);
    pop.trigger.behavior.events.on_key_down = triggerKeyDown;
    pop.trigger.setFocusable(!props.disabled);
    pop.trigger.behavior.interaction.a11y = .{
        .role = .combobox,
        .has_popup = .listbox,
        .disabled = props.disabled,
        .expanded = false,
    };

    pop.content.style.direction = .column;
    pop.content.style.gap = 2;
    pop.content.style.padding = core.Padding.all(m.panel_padding);
    pop.content.setBackgroundRaw(colors.panel);
    pop.content.style.border = .{ .width = 1, .color = colors.border, .radius = m.panel_radius };
    const panel_ext = try pop.content.style.ensureExtFallible(allocator);
    panel_ext.corner_radius = .{ .all = m.panel_radius };
    panel_ext.setShadow(.{ .color = Color.rgba(0, 0, 0, 18), .blur = 12, .offset_y = 4 });
    panel_ext.hit_shape = .{ .rounded_rect = m.panel_radius };
    panel_ext.clip_shape = .{ .rounded_rect = m.panel_radius };
    pop.content.behavior.interaction.a11y = .{ .role = .listbox, .multiselectable = props.mode == .multiple };

    for (props.options, 0..) |option, i| {
        // 建好即挂：option 进 content，content/check 进 option
        const option_node = try core.adoptChild(cx, allocator, pop.content, try core.box(cx, .{
            .width = .{ .grow = .{} },
            .direction = .row,
            .align_items = .center,
            .justify = .space_between,
            .padding = if (props.mode == .multiple) core.Padding.all(m.row_padding.top) else m.row_padding,
            .corner_radius = m.row_radius,
            .cursor = if (option.disabled) .default else .pointer,
        }, .{}));
        const option_content = try core.adoptChild(cx, allocator, option_node, try row(cx, 8));
        if (option.icon) |asset| _ = try core.adoptChild(cx, allocator, option_content, try iconNode(cx, asset, @min(m.icon_size, 16), colors.text_secondary));
        _ = try core.adoptChild(cx, allocator, option_content, try textNode(cx, option.label, m.row_font, if (option.disabled) colors.text_tertiary else colors.text_primary, 400));

        var check_node: *Node = undefined;
        if (props.mode == .single) {
            check_node = try core.adoptChild(cx, allocator, option_node, try iconNode(cx, icons.check, @min(m.icon_size, 16), colors.primary));
        } else {
            check_node = try core.adoptChild(cx, allocator, option_node, try core.box(cx, .{
                .width = .{ .px = m.checkbox_size },
                .height = .{ .px = m.checkbox_size },
                .direction = .row,
                .align_items = .center,
                .justify = .center,
                .background = colors.bg,
                .border = .{ .width = 1.5, .color = colors.border_strong, .radius = m.checkbox_radius },
            }, .{}));
            _ = try core.adoptChild(cx, allocator, check_node, try iconNode(cx, icons.check, m.check_size, colors.panel));
        }
        option_nodes[i] = option_node;
        check_nodes[i] = check_node;
        holder.items[i] = .{ .state = state, .index = i };
        option_node.behavior.events.event_context = @ptrCast(&holder.items[i]);
        option_node.behavior.events.on_event = itemEvent;
        option_node.behavior.interaction.a11y = .{ .role = .option, .label = option.label, .disabled = option.disabled, .selected = false };
    }

    try my_scope.createEffect(.{ .open = pop.is_open, .state = state }, struct {
        fn update(ctx: anytype) void {
            syncOpen(ctx.state, ctx.open.get());
        }
    }.update);

    syncSelection(state);
    syncOpen(state, false);
    return .{ .wrapper = pop.wrapper, .trigger = shell, .panel = pop.content, .state = state, .is_open = pop.is_open };
}

test "Select: single selection commits and clear resets" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const options = [_]SelectOption{
        .{ .value = "one", .label = "Option 1" },
        .{ .value = "two", .label = "Option 2" },
    };
    const result = try mountSelect(.{ .options = &options, .clearable = true }, scope, cx);
    try root.appendChild(testing.allocator, result.wrapper);
    try testing.expectEqual(@as(f32, 0), result.state.clear_button.?.getOpacity());
    try testing.expectEqual(@as(f32, 1), result.state.chevron_down.getOpacity());
    commit(result.state, 1);
    try testing.expectEqualStrings("two", result.state.selectedValue().?);
    try testing.expectEqual(@as(f32, 0), result.state.clear_button.?.getOpacity());
    try testing.expectEqual(@as(f32, 1), result.state.chevron_slot.getOpacity());
    _ = triggerEvent(.{ .mouse_enter = {} }, @ptrCast(result.state));
    try testing.expect(result.state.is_trigger_hovered);
    try testing.expect(result.state.clear_button.?.frame_state.state_bits.flags.hit_test_visible);
    const clear_opacity_transition = result.state.clear_button.?.frame_state.frame_local.runtime.transitions.?.find(.opacity).?;
    const chevron_opacity_transition = result.state.chevron_slot.frame_state.frame_local.runtime.transitions.?.find(.opacity).?;
    try testing.expect(clear_opacity_transition.active);
    try testing.expectEqual(@as(f32, 1), clear_opacity_transition.to_value);
    try testing.expect(chevron_opacity_transition.active);
    try testing.expectEqual(@as(f32, 0), chevron_opacity_transition.to_value);
    // Declarative transitions retain their current values until render ticks;
    // E2E below verifies the intermediate and settled opacity values.
    try testing.expectEqual(@as(f32, 0), result.state.clear_button.?.getOpacity());
    try testing.expectEqual(@as(f32, 1), result.state.chevron_slot.getOpacity());
    try testing.expectEqual(@as(f32, 1), result.state.chevron_down.getOpacity());
    try testing.expectEqual(@as(f32, 0), result.state.chevron_up.getOpacity());
    syncOpen(result.state, true);
    const rotate_transition = result.state.chevron_down.frame_state.frame_local.runtime.transitions.?.find(.rotate).?;
    try testing.expect(rotate_transition.active);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), rotate_transition.to_value, 0.0001);
    _ = clearEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(result.state));
    try testing.expect(result.state.selectedValue() == null);
    try testing.expectEqual(@as(f32, 0), result.state.clear_button.?.getOpacity());
    try testing.expect(!result.state.clear_button.?.frame_state.state_bits.flags.hit_test_visible);
    try testing.expectEqual(@as(f32, 1), result.state.chevron_slot.getOpacity());
    try testing.expectEqual(@as(f32, 1), result.state.chevron_down.getOpacity());
}

test "Select: 空 options 时方向键不 panic" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const result = try mountSelect(.{ .options = &.{} }, scope, cx);
    try root.appendChild(testing.allocator, result.wrapper);
    _ = triggerKeyDown(.down, .{}, @ptrCast(result.state));
    _ = triggerKeyDown(.up, .{}, @ptrCast(result.state));
    try testing.expect(result.state.highlighted_index == null);
}

test "Select: 反复 mount/free 不泄漏 World element slot（未用 icon_slot 走 freeNode）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const options = [_]SelectOption{.{ .value = "one", .label = "Option 1" }};
    const Cycle = struct {
        fn run(c: *Cx, s: *Scope, r: *Node, opts: []const SelectOption) !void {
            const sub = try s.childScope();
            const res = try mountSelect(.{ .options = opts }, sub, c);
            try r.appendChild(c.allocator, res.wrapper);
            c.detachChild(r, res.wrapper);
            c.freeNode(res.wrapper);
            sub.dispose();
        }
    };
    try Cycle.run(cx, scope, root, &options);
    const baseline = cx.world.elements.count();
    var i: usize = 0;
    while (i < 10) : (i += 1) try Cycle.run(cx, scope, root, &options);
    try testing.expectEqual(baseline, cx.world.elements.count());
}

test "Select: multiple selection toggles independently" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const options = [_]SelectOption{
        .{ .value = "one", .label = "Option 1" },
        .{ .value = "two", .label = "Option 2" },
        .{ .value = "three", .label = "Option 3" },
    };
    const result = try mountSelect(.{ .options = &options, .mode = .multiple }, scope, cx);
    try root.appendChild(testing.allocator, result.wrapper);
    commit(result.state, 0);
    commit(result.state, 2);
    try testing.expect(result.state.isSelected(0));
    try testing.expect(result.state.isSelected(2));
    try testing.expectEqual(@as(usize, 2), result.state.selectedCount());
    commit(result.state, 0);
    try testing.expect(!result.state.isSelected(0));
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
const sweep_opts = [_]SelectOption{ .{ .value = "one", .label = "Option 1" }, .{ .value = "two", .label = "Option 2" } };
test "select(clearable): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select(clearable)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountSelect(.{ .options = &sweep_opts, .clearable = true }, scope, cx)).wrapper;
        }
    }.m);
}
