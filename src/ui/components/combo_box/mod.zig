/// ComboBox / Autocomplete, typeahead-in-input（B3）
///
/// 组合已有基建：Input（文本输入 + on_change）+ Popover（bottom_start 锚定面板，
/// manual 触发）。retained 模式下 option 行只建一次，过滤 = 行高 0/item_h 切换
/// （与 Accordion 收起同款），不重建节点。
///
/// 行为：
///   - 输入即过滤（label 大小写不敏感子串匹配）并打开面板
///   - 点选 option -> 输入框填入 label、面板关闭、触发 on_change（caller 读
///     state.selectedOption() 取值）
///   - 无匹配时显示 "No results found" 空态行
const std = @import("std");
const icons = @import("zenit_system_icons");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const Signal = core.Signal;
const box = core.box;
const theme = core.theme;
const Scope = @import("../../reactive.zig").Scope;
const popover_mod = @import("../popover/mod.zig");
const input_mod = @import("../input/mod.zig");
const TextInputState = input_mod.TextInputState;
const sm = @import("../select_headless/state_machine.zig");
const events = @import("../../events.zig");
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
const EventResult = events.EventResult;

/// 键盘导航复用 select_headless 的纯函数状态机（含 wrap / page / home-end）。
/// ValueT 取 u32 = **可见（过滤后）选项在 options 里的下标**，因为 ComboBox
/// 的导航必须只走当前匹配的行，隐藏行不能被箭头选中。
const NavValue = u32;
const NavState = sm.SelectState(NavValue);
const NavOption = sm.Option(NavValue);
/// 可见选项上限（= options 上限；超出部分不参与键盘导航）
const max_visible_options = 256;

/// 选项（label 展示 + value 提交）
pub const ComboOption = struct {
    value: []const u8,
    label: []const u8,
    disabled: bool = false,
};

pub const ComboBoxProps = struct {
    options: []const ComboOption = &.{},
    placeholder: []const u8 = "Type to search…",
    label_text: ?[]const u8 = null,
    width: f32 = 240,
    max_dropdown_height: f32 = 280,
    disabled: bool = false,
    /// 选中提交回调；caller 在回调里读 state.selectedOption()
    on_change: ?core.HandlerRef = null,
};

// ── 样式层在 styles.zig ──
const styles = @import("styles.zig");
const combo_item_height = styles.combo_item_height;
const comboPanelStyle = styles.comboPanelStyle;
const comboItemStyle = styles.comboItemStyle;
const comboEmptyStyle = styles.comboEmptyStyle;
const comboItemTextStyle = styles.comboItemTextStyle;
const comboEmptyTextStyle = styles.comboEmptyTextStyle;
const comboHighlightBg = styles.comboHighlightBg;

pub const ComboBoxState = struct {
    options: []const ComboOption,
    item_nodes: []*Node,
    empty_node: *Node,
    /// combobox 角色所在节点（pop.trigger），expanded / active_descendant /
    /// value_text 三个 a11y 状态全部写回这里（AT 的虚拟焦点停在输入框上）。
    trigger: *Node,
    input_state: *TextInputState,
    is_open: *Signal(bool),
    panel: *Node,
    item_h: f32,
    selected_index: ?usize = null,
    on_change: ?core.HandlerRef = null,
    /// 点选后程序化写回输入框会触发 Input on_change；置位跳过一次过滤/重开面板
    suppress_change: bool = false,

    // ── 键盘导航（复用 select_headless 状态机）──
    /// 状态机 state；highlight_index 是"可见选项序号"，不是 options 下标
    nav: NavState = .{ .open = false, .value = null, .highlight_index = null },
    /// 可见选项表：nav_options[k].value = 该可见项在 options 里的真实下标
    nav_options_buf: [max_visible_options]NavOption = undefined,
    nav_options_len: usize = 0,
    /// highlight 行底色 / 常态底色
    highlight_bg: core.Color = core.Color.TRANSPARENT,

    pub fn selectedOption(self: *const ComboBoxState) ?ComboOption {
        const i = self.selected_index orelse return null;
        return self.options[i];
    }

    /// 当前 highlight 的 options 下标（无 highlight 返回 null）
    pub fn highlightedIndex(self: *const ComboBoxState) ?usize {
        const k = self.nav.highlight_index orelse return null;
        if (k >= self.nav_options_len) return null;
        return @intCast(self.nav_options_buf[k].value);
    }

    fn navOptions(self: *const ComboBoxState) []const NavOption {
        return self.nav_options_buf[0..self.nav_options_len];
    }
};

pub const ComboBoxMount = struct {
    wrapper: *Node,
    /// Input wrapper（含 label）
    input: *Node,
    panel: *Node,
    is_open: *Signal(bool),
    state: *ComboBoxState,
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

fn applyFilter(state: *ComboBoxState, filter: []const u8) usize {
    var matched: usize = 0;
    state.nav_options_len = 0;
    for (state.options, state.item_nodes, 0..) |opt, item, i| {
        const show = containsIgnoreCase(opt.label, filter);
        // display:none：不占位、不计 gap、不绘制、不命中（框架原生隐藏）。
        item.setDisplay(if (show) .flex else .none);
        if (show) {
            matched += 1;
            // 只有可见行进入导航表，箭头键不会停在被过滤掉的行上
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
    // 过滤变化后旧 highlight 序号失效（指向的可能已被过滤掉）
    state.nav.highlight_index = null;
    applyHighlightStyles(state);
    state.panel.markLayoutDirty();
    return matched;
}

/// 把 highlight 底色刷到行节点上（仅 highlight 行有底色，其余透明）
fn applyHighlightStyles(state: *ComboBoxState) void {
    const hi = state.highlightedIndex();
    for (state.item_nodes, 0..) |item, i| {
        const want = if (hi != null and hi.? == i) state.highlight_bg else core.Color.TRANSPARENT;
        item.setBackgroundRaw(want);
        item.markRenderDirty();
    }
    syncComboA11y(state);
}

/// a11y 状态跟随交互（form_field 模式）：expanded 跟 is_open、
/// active_descendant 跟 highlight、value_text / option.selected 跟提交的选择。
/// 每处交互出口都要走到这里，否则 AT 播报的是过期状态。
fn syncComboA11y(state: *ComboBoxState) void {
    if (state.trigger.behavior.interaction.a11y) |*a| {
        a.expanded = state.is_open.peek();
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
        // 默认 option 的第二个 child 是 Pvnqs 选中态 check icon。
        if (item.children.items.len > 1) {
            item.children.items[1].setOpacity(if (selected) 1 else 0);
        }
    }
    state.trigger.markRenderDirty();
}

/// 把 highlight 行写回输入框并提交（Enter / 点选共用）
fn commitIndex(state: *ComboBoxState, index: usize) void {
    const opt = state.options[index];
    if (opt.disabled) return;
    state.selected_index = index;
    // 输入框写回 label（selectAll + insertText = 整体替换）；写回会触发
    // Input on_change -> suppress 一次，避免按 label 重过滤 + 重开面板。
    state.suppress_change = true;
    state.input_state.selectAll();
    state.input_state.insertText(opt.label);
    state.is_open.set(false);
    syncComboA11y(state);
    if (state.on_change) |h| h.invoke();
}

/// ComboBox 键盘处理，导航逻辑整体委托给 select_headless 状态机，
/// 本函数只做 KeyCode -> Action 映射与「可见序号 -> options 下标」的翻译。
fn comboKeyDown(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const state: *ComboBoxState = @ptrCast(@alignCast(context orelse return .ignored));

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

    // 关闭态按方向键 = 打开面板并落到首项（原生 ComboBox 行为）
    if (!state.is_open.get() and (a == .arrow_down or a == .arrow_up)) {
        state.is_open.set(true);
        state.nav.open = true;
    }

    const opts = state.navOptions();
    sm.step(NavValue, &state.nav, opts, a, 0);

    switch (a) {
        .enter => {
            if (state.highlightedIndex()) |idx| {
                commitIndex(state, idx);
            } else {
                // 无 highlight 时 Enter 不吞事件，交给表单提交等外层逻辑
                return .ignored;
            }
        },
        .escape => state.is_open.set(false),
        else => {},
    }
    applyHighlightStyles(state);
    return .stop;
}

fn onInputChanged(state: *ComboBoxState, text: []const u8) void {
    if (state.suppress_change) {
        state.suppress_change = false;
        return;
    }
    // 手动编辑使既有选择失效（提交值以点选为准）
    state.selected_index = null;
    _ = applyFilter(state, text);
    if (!state.is_open.get()) state.is_open.set(true);
}

fn onItemClick(ctx_ptr: *anyopaque) void {
    const ctx: *ItemClickCtx = @ptrCast(@alignCast(ctx_ptr));
    commitIndex(ctx.state, ctx.index);
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

/// mount ComboBox。默认样式与 select_headless 对齐（bg_primary 面板 + hover 行）。
pub fn mountComboBox(props: ComboBoxProps, scope: *Scope, cx: *Cx) !ComboBoxMount {
    const my_scope = try scope.childScope();
    const allocator = cx.allocator;
    const t = cx.tokens;

    // ── Popover（manual 触发；面板 bottom_start 锚定 + 跟随 trigger 宽度）──
    // wrapper/trigger 留在正常文档流，floating content 由 Popover 统一挂到
    // window portal，不再需要临时篡改 cx 的 portal 指针。
    var pop = try popover_mod.Popover(.{
        .position = .bottom_start,
        .trigger = .manual,
        .offset = .{ .static = 4 },
        .flip = false,
        .width = props.width,
        .match_trigger_width = true,
        .constrain_width_to_viewport = true,
        .max_height = props.max_dropdown_height,
    }).mount(my_scope, cx);
    // sweep：wrapper 守到 return；失败先 dispose my_scope（hook / resource 在节点存活期 destroy）再 freeNode
    errdefer cx.freeNode(pop.wrapper);
    errdefer my_scope.dispose();
    pop.wrapper.meta.ownership.meta.component_name = "ComboBox";

    // ── State ──
    const state = try my_scope.allocator.create(ComboBoxState);
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            alloc.destroy(@as(*ComboBoxState, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);

    // ── Input（塞进 pop.trigger 作为锚点）──
    const input_result = try input_mod.Input(.{
        .placeholder = props.placeholder,
        .label_text = props.label_text,
        .width = props.width,
        .disabled = props.disabled,
        .on_change = core.Cx.strHandlerFrom(ComboBoxState, state, onInputChanged),
    }).mountResult(my_scope, cx);
    pop.trigger.style.width = .{ .px = props.width };
    pop.trigger.style.height = .{ .fit = .{} };
    _ = try core.adoptChild(cx, allocator, pop.trigger, input_result.node);

    // a11y: combobox + listbox popup；expanded 初始收起（后续由
    // syncComboA11y / is_open effect 跟随交互更新）
    pop.trigger.behavior.interaction.a11y = .{
        .role = .combobox,
        .has_popup = .listbox,
        .label = props.label_text,
        .disabled = props.disabled,
        .expanded = false,
        .active_descendant_element_id = 0xFFFFFFFF,
    };

    // ── 面板 + option 行 ──
    // a11y: 面板是 listbox，行是 option（combobox -> listbox -> option 三级角色链）
    pop.content.behavior.interaction.a11y = .{ .role = .listbox };
    const panel_style = comboPanelStyle(t);
    panel_style.applyTo(&pop.content.style, allocator);
    if (panel_style.background) |bg| pop.content.setBackgroundRaw(bg);
    // Popover 的默认 chrome 是 4px 圆角；ComboBox 以 Pvnqs 的 8px panel
    // 为准，同步命中与裁剪形状，避免只有边框变圆而内容仍按旧半径裁切。
    const panel_radius = styles.comboPanelRadius(t);
    const panel_ext = try pop.content.style.ensureExtFallible(allocator);
    panel_ext.hit_shape = .{ .rounded_rect = panel_radius };
    panel_ext.clip_shape = .{ .rounded_rect = panel_radius };

    const NodesHolder = struct { nodes: []*Node, click_ctxs: []ItemClickCtx };
    const holder = try my_scope.allocator.create(NodesHolder);
    {
        // 两次 alloc 不能写在同一个初始化器里：第二次失败时第一次已分配却无人释放。
        errdefer my_scope.allocator.destroy(holder);
        const nodes = try my_scope.allocator.alloc(*Node, props.options.len);
        errdefer my_scope.allocator.free(nodes);
        const click_ctxs = try my_scope.allocator.alloc(ItemClickCtx, props.options.len);
        holder.* = .{ .nodes = nodes, .click_ctxs = click_ctxs };
    }
    try my_scope.adoptResource(@ptrCast(holder), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const h: *NodesHolder = @ptrCast(@alignCast(ptr));
            alloc.free(h.nodes);
            alloc.free(h.click_ctxs);
            alloc.destroy(h);
        }
    }.destroy);

    for (props.options, 0..) |opt, i| {
        // 建好即挂：item 进 content，label / check 进 item
        const item = try core.adoptChild(cx, allocator, pop.content, try box(cx, comboItemStyle(t), .{}));
        if (!opt.disabled) item.style.cursor = .pointer;
        item.setHitTestVisible(!opt.disabled);
        item.behavior.interaction.a11y = .{
            .role = .option,
            .label = opt.label,
            .disabled = opt.disabled,
            .selected = false,
        };
        const label = try core.adoptChild(cx, allocator, item, try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } }, .{}));
        var label_txt = comboItemTextStyle(opt.disabled, t);
        label_txt.content = opt.label;
        label.setText(label_txt);
        const check_icon = try core.adoptChild(cx, allocator, item, try core.iconTint(cx, icons.check, t.color.accent, .{
            .width = .{ .px = 16 },
            .height = .{ .px = 16 },
        }));
        check_icon.setOpacityRaw(0);
        holder.nodes[i] = item;

        holder.click_ctxs[i] = .{ .state = state, .index = i };
        item.behavior.events.event_context = @ptrCast(&holder.click_ctxs[i]);
        item.behavior.events.on_event = onItemEvent;
    }

    // 空态行（默认收起）
    const empty_node = try core.adoptChild(cx, allocator, pop.content, try box(cx, comboEmptyStyle(t), .{}));
    const empty_label = try core.adoptChild(cx, allocator, empty_node, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
    empty_label.setText(comboEmptyTextStyle(t));
    empty_node.setHitTestVisible(false);

    state.* = .{
        .options = props.options,
        .item_nodes = holder.nodes,
        .empty_node = empty_node,
        .trigger = pop.trigger,
        .input_state = input_result.state,
        .is_open = pop.is_open,
        .panel = pop.content,
        .item_h = combo_item_height,
        .on_change = props.on_change,
        .highlight_bg = comboHighlightBg(t),
    };
    // 初始导航表 = 全部选项可见
    _ = applyFilter(state, "");

    // 键盘导航挂在 Input 节点上：焦点始终在输入框里（面板不抢焦点），
    // 所以 arrow/Enter/Escape 必须从 Input 起手。
    input_result.node.behavior.events.key_context = @ptrCast(state);
    input_result.node.behavior.events.on_key_down = comboKeyDown;

    // expanded 也可能由外部路径翻转（点外部关闭 popover 等），effect 兜底跟随
    // is_open（form_field 的 error_sig effect 同款模式）。
    try my_scope.createEffect(.{
        .is_open = pop.is_open,
        .state_ptr = state,
    }, struct {
        fn update(c: anytype) void {
            _ = c.is_open.get();
            syncComboA11y(c.state_ptr);
        }
    }.update);

    return .{
        .wrapper = pop.wrapper,
        .input = input_result.node,
        .panel = pop.content,
        .is_open = pop.is_open,
        .state = state,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("Apple", "app"));
    try std.testing.expect(containsIgnoreCase("Banana", "NAN"));
    try std.testing.expect(!containsIgnoreCase("Cherry", "apple"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "mountComboBox: 过滤切换行高 + 点选写回输入框" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const opts = [_]ComboOption{
        .{ .value = "a", .label = "Apple" },
        .{ .value = "b", .label = "Banana" },
        .{ .value = "c", .label = "Cherry" },
    };
    const cb = try mountComboBox(.{ .options = &opts, .width = 240 }, scope, cx);
    try root.appendChild(testing.allocator, cb.wrapper);

    // Pvnqs panel / option chrome
    try testing.expectEqual(@as(f32, 2), cb.panel.style.gap);
    try testing.expectEqual(@as(f32, 4), cb.panel.style.padding.top);
    try testing.expectEqual(@as(f32, 4), cb.panel.style.padding.left);
    try testing.expectEqual(@as(f32, 8), cb.panel.style.border.radius);
    try testing.expectEqual(@as(usize, 1), cb.panel.style.shadowSlice().len);
    try testing.expectEqual(@as(f32, 12), cb.panel.style.shadowSlice()[0].blur);
    try testing.expectEqual(@as(f32, 4), cb.panel.style.shadowSlice()[0].offset_y);

    // 初始：全部行可见
    for (cb.state.item_nodes) |item| {
        try testing.expectEqual(@as(f32, combo_item_height), item.style.height.px);
        try testing.expectEqual(@as(f32, 8), item.style.padding.top);
        try testing.expectEqual(@as(f32, 12), item.style.padding.left);
        try testing.expectEqual(@as(f32, 6), item.style.corner_radius().?.resolve());
        try testing.expectEqual(@as(f32, 1), item.getOpacity());
        try testing.expect(item.style.overflow_hidden);
        try testing.expectEqual(core.Position.relative, item.style.position);
    }

    // 过滤 "an" -> 只 Banana 命中
    const matched = applyFilter(cb.state, "an");
    try testing.expectEqual(@as(usize, 1), matched);
    try testing.expectEqual(core.Display.none, cb.state.item_nodes[0].style.display);
    try testing.expectEqual(core.Display.flex, cb.state.item_nodes[1].style.display);
    try testing.expectEqual(core.Display.none, cb.state.item_nodes[2].style.display);
    try testing.expectEqual(core.Display.none, cb.state.empty_node.style.display);
    // 行高不再被改写（隐藏靠 display，不靠 0 高）

    // 无匹配 -> 空态行展开
    _ = applyFilter(cb.state, "zzz");
    try testing.expectEqual(core.Display.flex, cb.state.empty_node.style.display);
    for (cb.state.item_nodes) |item| try testing.expectEqual(core.Display.none, item.style.display);

    // 点选 Banana -> 输入框写回 label、选中提交、面板关闭
    cb.is_open.set(true);
    var click_ctx = ItemClickCtx{ .state = cb.state, .index = 1 };
    onItemClick(@ptrCast(&click_ctx));
    try testing.expectEqual(@as(?usize, 1), cb.state.selected_index);
    try testing.expectEqualStrings("Banana", cb.state.selectedOption().?.label);
    try testing.expect(!cb.is_open.get());
    try testing.expectEqualStrings("Banana", cb.state.input_state.buffer[0..cb.state.input_state.buffer_len]);
    try testing.expectEqual(@as(f32, 1), cb.state.item_nodes[1].children.items[1].getOpacity());
}

/// 键盘导航测试用的公共 mount
fn mountKbdFixture(cx: *Cx, scope: *Scope, opts: []const ComboOption) !ComboBoxMount {
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const cb = try mountComboBox(.{ .options = opts, .width = 240 }, scope, cx);
    try root.appendChild(cx.allocator, cb.wrapper);
    return cb;
}

test "ComboBox 键盘：arrow-then-Enter 选中（此前完全没有键盘导航）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const opts = [_]ComboOption{
        .{ .value = "a", .label = "Apple" },
        .{ .value = "b", .label = "Banana" },
        .{ .value = "c", .label = "Cherry" },
    };
    const cb = try mountKbdFixture(cx, scope, &opts);
    const st = cb.state;

    // key handler 真的接上了（回归护栏：此前 on_key_down 是 null）
    try testing.expect(cb.input.behavior.events.on_key_down != null);

    // 关闭态按 ↓ -> 打开面板并落到首项
    try testing.expect(!cb.is_open.get());
    try testing.expectEqual(EventResult.stop, comboKeyDown(.down, .{}, @ptrCast(st)));
    try testing.expect(cb.is_open.get());
    try testing.expectEqual(@as(?usize, 0), st.highlightedIndex());

    // 再按两次 ↓ -> Cherry
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 2), st.highlightedIndex());

    // Enter 提交 -> 写回输入框、关闭面板
    _ = comboKeyDown(.@"return", .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 2), st.selected_index);
    try testing.expectEqualStrings("Cherry", st.selectedOption().?.label);
    try testing.expect(!cb.is_open.get());
    try testing.expectEqualStrings("Cherry", st.input_state.buffer[0..st.input_state.buffer_len]);
}

test "ComboBox 键盘：箭头只走过滤后可见的行" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const opts = [_]ComboOption{
        .{ .value = "a", .label = "Apple" },
        .{ .value = "b", .label = "Banana" },
        .{ .value = "c", .label = "Cherry" },
        .{ .value = "g", .label = "Grape" },
    };
    const cb = try mountKbdFixture(cx, scope, &opts);
    const st = cb.state;

    // 过滤 "ap" -> Apple(0) 与 Grape(3) 命中；Banana/Cherry 隐藏
    try testing.expectEqual(@as(usize, 2), applyFilter(st, "ap"));
    try testing.expectEqual(@as(usize, 2), st.nav_options_len);

    cb.is_open.set(true);
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 0), st.highlightedIndex()); // Apple
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 3), st.highlightedIndex()); // 跳过隐藏行 → Grape
    // wrap 回首个可见项，而不是走到 Banana
    _ = comboKeyDown(.down, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 0), st.highlightedIndex());

    // ↑ 从首项 wrap 到末个可见项
    _ = comboKeyDown(.up, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 3), st.highlightedIndex());
}

test "ComboBox 键盘：Home/End/Escape 与无 highlight 时的 Enter" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const opts = [_]ComboOption{
        .{ .value = "a", .label = "Apple" },
        .{ .value = "b", .label = "Banana" },
        .{ .value = "c", .label = "Cherry" },
    };
    const cb = try mountKbdFixture(cx, scope, &opts);
    const st = cb.state;
    cb.is_open.set(true);

    _ = comboKeyDown(.end, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 2), st.highlightedIndex());
    _ = comboKeyDown(.home, .{}, @ptrCast(st));
    try testing.expectEqual(@as(?usize, 0), st.highlightedIndex());

    // Escape 关闭并清 highlight
    _ = comboKeyDown(.escape, .{}, @ptrCast(st));
    try testing.expect(!cb.is_open.get());
    try testing.expect(st.highlightedIndex() == null);

    // 无 highlight 时 Enter 不吞事件（留给外层表单提交）
    try testing.expectEqual(EventResult.ignored, comboKeyDown(.@"return", .{}, @ptrCast(st)));
    try testing.expect(st.selected_index == null);
}

test "ComboBox 键盘：highlight 底色刷到行节点上" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const opts = [_]ComboOption{
        .{ .value = "a", .label = "Apple" },
        .{ .value = "b", .label = "Banana" },
    };
    const cb = try mountKbdFixture(cx, scope, &opts);
    const st = cb.state;
    cb.is_open.set(true);

    _ = comboKeyDown(.down, .{}, @ptrCast(st)); // highlight = Apple
    const hl = st.highlight_bg;
    try testing.expect(st.item_nodes[0].getBackground().eql(hl));
    try testing.expect(st.item_nodes[1].getBackground().eql(core.Color.TRANSPARENT));

    _ = comboKeyDown(.down, .{}, @ptrCast(st)); // highlight = Banana
    try testing.expect(st.item_nodes[0].getBackground().eql(core.Color.TRANSPARENT));
    try testing.expect(st.item_nodes[1].getBackground().eql(hl));
}

test "a11y: ComboBox expanded/active_descendant/value 跟随交互且可撤回" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    cx.setViewport(600, 400);
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const opts = [_]ComboOption{
        .{ .value = "a", .label = "Apple" },
        .{ .value = "b", .label = "Banana" },
    };
    const cb = try mountComboBox(.{ .options = &opts, .width = 240 }, scope, cx);
    try root.appendChild(testing.allocator, cb.wrapper);
    cx.layout();
    _ = cx.render();

    // 断言 a11y 树（真正送给 AT 的），不是 props 结构体。
    const eid = core.ElementId.fromRaw(cb.state.trigger.element_id_raw);
    {
        const n = cx.accessibility_tree.get(eid).?;
        try testing.expectEqual(core.a11y_tree.Role.combobox, n.role);
        try testing.expect(n.state.haspopup);
        try testing.expect(n.state.expanded_present);
        try testing.expect(!n.state.expanded); // 初始收起
        try testing.expect(n.active_descendant.isNull());
        try testing.expectEqual(@as(u64, 0), n.text_hash); // 无选中值
    }

    // ↓ 打开面板并落到首项 -> expanded=true + active_descendant 指向 Apple 行
    _ = comboKeyDown(.down, .{}, @ptrCast(cb.state));
    cx.layout();
    _ = cx.render();
    {
        const n = cx.accessibility_tree.get(eid).?;
        try testing.expect(n.state.expanded);
        try testing.expectEqual(cb.state.item_nodes[0].element_id_raw, n.active_descendant.raw());
    }

    // Enter 提交 Apple -> 收起、value_text 播报选中项、option.selected 置位
    _ = comboKeyDown(.@"return", .{}, @ptrCast(cb.state));
    cx.layout();
    _ = cx.render();
    {
        const n = cx.accessibility_tree.get(eid).?;
        try testing.expect(!n.state.expanded); // 状态可撤回：开→关
        try testing.expectEqual(std.hash.Wyhash.hash(0, "Apple"), n.text_hash);
    }
    try testing.expect(cb.state.item_nodes[0].behavior.interaction.a11y.?.selected);
    try testing.expect(!cb.state.item_nodes[1].behavior.interaction.a11y.?.selected);

    // 手动编辑使选择失效 -> value 撤回、selected 位撤回。
    // （测试直接调 onInputChanged，先消掉 commitIndex 写回 Input 用的
    // suppress 标记，真实流程里它被 insertText 触发的 on_change 消费。）
    cb.state.suppress_change = false;
    onInputChanged(cb.state, "ban");
    cx.layout();
    _ = cx.render();
    try testing.expectEqual(@as(u64, 0), cx.accessibility_tree.get(eid).?.text_hash);
    try testing.expect(!cb.state.item_nodes[0].behavior.interaction.a11y.?.selected);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
const sweep_opts = [_]ComboOption{ .{ .value = "a", .label = "Apple" }, .{ .value = "b", .label = "Banana" } };
test "combo_box: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("combo_box", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountComboBox(.{ .options = &sweep_opts, .width = 240 }, scope, cx)).wrapper;
        }
    }.m);
}
