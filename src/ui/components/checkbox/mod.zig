/// Checkbox, Radio, Switch Components
///
/// 复选框、单选框、开关组件
///
/// Signal 驱动: hover 状态通过 Signal 管理，
/// Effect 自动更新样式。Toggle 状态保留 StateStore
/// （涉及 DOM 结构变化）。
///
/// 特性:
/// - 状态管理: toggle 通过 StateStore, hover 通过 Signal
/// - 事件驱动: 通过 on_event 处理 click 事件
/// - 焦点支持: 可聚焦, 支持 Tab 导航
/// - 标签支持
/// - 禁用状态
/// - on_change 回调
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Signal = core.Signal;
const createEffect = core.createEffect;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const hooks = @import("../../hooks.zig");
const svg_assets = @import("../../svg_assets.zig");
const icons = @import("zenit_system_icons");
const Scope = @import("../../reactive.zig").Scope;

const recipe_mod = @import("../../recipe.zig");

// 样式层析出至 styles.zig；下列别名保持调用点与公共 API 不变。
const styles = @import("styles.zig");
pub const CheckboxRecipe = styles.CheckboxRecipe;
pub const SwitchRecipe = styles.SwitchRecipe;
pub const CheckboxColors = styles.CheckboxColors;
const SwitchColors = styles.SwitchColors;
const controlRowStyle = styles.controlRowStyle;
const checkboxBoxStyle = styles.checkboxBoxStyle;
const checkIconStyle = styles.checkIconStyle;
const indetOverlayStyle = styles.indetOverlayStyle;
const controlLabelStyle = styles.controlLabelStyle;
const radioCircleStyle = styles.radioCircleStyle;
const radioDotStyle = styles.radioDotStyle;
const radioGroupContainerStyle = styles.radioGroupContainerStyle;
const switchTrackStyle = styles.switchTrackStyle;
const switchThumbStyle = styles.switchThumbStyle;
const switchLabelStyle = styles.switchLabelStyle;

/// Checkbox 内部状态
pub const CheckboxState = struct {
    checked: bool = false,
    indeterminate: bool = false,
    disabled: bool = false,

    /// Theme tokens 引用 (供 on_before_render 使用)
    tokens: *const theme.ThemeTokens = &theme.dark,

    /// 外部回调 (存储 props 传入的回调)
    /// 2026-07-31 并轨：统一 ?core.HandlerRef（含 context），用
    /// invokeWithBool 触发。旧的 fn-ptr + callback_context 双字段已合并。
    on_change: ?core.HandlerRef = null,

    /// checkbox_box 节点引用（用于 setBackground/setBorderColor 触发 Transition）
    checkbox_box: ?*Node = null,

    pub fn toggle(self: *CheckboxState) void {
        if (self.disabled) return;
        self.checked = !self.checked;
        self.indeterminate = false;

        // toggle 后立即更新 checkbox_box 的颜色（通过 Transition 系统自动过渡）
        if (self.checkbox_box) |checkbox_node| {
            const t = self.tokens;
            // indeterminate 视为 checked 来计算颜色
            const effectively_checked = self.checked or self.indeterminate;
            checkbox_node.setBackground(CheckboxColors.background(t, effectively_checked, self.disabled));
            checkbox_node.setBorderColor(CheckboxColors.borderColor(t, effectively_checked, self.disabled));
        }

        if (self.on_change) |h| h.invokeWithBool(self.checked);
    }
};

/// Checkbox on_before_render 钩子：更新 checkmark / indeterminate 可见性
/// 背景色和边框色的过渡动画由框架 Transition 系统自动处理（toggle 时通过 setBackground/setBorderColor 触发）
fn checkboxBeforeRender(node: *Node) void {
    const state: *CheckboxState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));

    if (node.behavior.interaction.a11y) |*a11y| {
        a11y.checked = state.checked;
        a11y.indeterminate = state.indeterminate and !state.checked;
    }

    if (node.children.items.len == 0) return;
    const checkbox_box = node.children.items[0];

    if (checkbox_box.children.items.len < 2) return;
    const checkmark = checkbox_box.children.items[0];
    const indet_overlay = checkbox_box.children.items[1];

    // 更新可见性
    checkmark.setOpacityRaw(if (state.checked) 1.0 else 0.0);
    indet_overlay.setOpacityRaw(if (state.indeterminate and !state.checked) 1.0 else 0.0);
}

/// Checkbox 事件处理器
fn checkboxEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *CheckboxState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.disabled) return .ignored;

    switch (event) {
        .click => {
            state.toggle();
            return .handled;
        },
        .key_down => |e| {
            // Space 键也可以切换
            if (e.key == .space) {
                state.toggle();
                return .handled;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

/// Checkbox 属性
pub const CheckboxProps = struct {
    /// 选中状态
    /// 初始勾选态。**只在 mount 时读取一次**，之后改无效（组件持有
    /// 自己的 CheckboxState）。需要外部驱动请用 mountResult 拿 state 后
    /// 调 setChecked，或用 ui.Show 重建。
    initial_checked: bool = false,
    /// 不确定状态
    indeterminate: bool = false,
    /// 标签
    label_text: ?[]const u8 = null,
    /// 禁用
    disabled: bool = false,
    /// 变化回调。2026-07-31 并轨为 `?core.HandlerRef`。
    /// 需要拿到新值用 `cx.boolHandlerFrom(State, ptr, method)` 构造；
    /// 只关心"变了"用 `cx.handlerFrom(...)`。
    on_change: ?core.HandlerRef = null,
    /// 状态 ID (用于 StateStore)
    state_id: ?u64 = null,
    /// Check icon SVG 资产
    check_icon_asset: ?svg_assets.Asset = null,
};

/// 创建 Checkbox
pub fn Checkbox(props: CheckboxProps) CheckboxBuilder {
    return CheckboxBuilder{ .props = props };
}

pub const CheckboxBuilder = struct {
    props: CheckboxProps,

    pub fn checked(self: CheckboxBuilder, c: bool) CheckboxBuilder {
        var new = self;
        new.props.initial_checked = c;
        return new;
    }

    pub fn label(self: CheckboxBuilder, text: []const u8) CheckboxBuilder {
        var new = self;
        new.props.label_text = text;
        return new;
    }

    pub fn disabled(self: CheckboxBuilder, d: bool) CheckboxBuilder {
        var new = self;
        new.props.disabled = d;
        return new;
    }

    pub fn onChange(self: CheckboxBuilder, handler_ref: core.HandlerRef) CheckboxBuilder {
        var new = self;
        new.props.on_change = handler_ref;
        return new;
    }

    pub fn checkIconAsset(self: CheckboxBuilder, asset: svg_assets.Asset) CheckboxBuilder {
        var new = self;
        new.props.check_icon_asset = asset;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: CheckboxBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Scope 分配内部状态（替代 StateStore）
        const state = try my_scope.allocator.create(CheckboxState);
        state.* = .{
            .checked = p.initial_checked,
            .indeterminate = p.indeterminate,
            .disabled = p.disabled,
            .tokens = t,
            .on_change = p.on_change,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *CheckboxState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);

        // 外层容器
        const container = try box(cx, controlRowStyle(), .{});
        // sweep：container 从建好到 return 之间还有多步可失败构造，守卫一直武装到 return
        errdefer cx.freeNode(container);
        container.tag = .button;
        container.setFocusable(true);
        container.meta.ownership.meta.component_name = "Checkbox";
        try core.bindScopeToNode(my_scope, container);
        container.behavior.interaction.a11y = .{
            .role = .checkbox,
            .label = p.label_text,
            .checked = state.checked,
            .indeterminate = state.indeterminate and !state.checked,
            .disabled = p.disabled,
        };
        container.style.cursor = if (p.disabled) .not_allowed else .pointer;
        container.addDebugState(@ptrCast(state));

        // 复选框方框（indeterminate 视为 checked 来决定颜色）
        const effectively_checked = p.initial_checked or p.indeterminate;
        // 建好即挂（container 的 errdefer 兜底整棵），子节点各自 adopt
        const checkbox_box = try core.adoptChild(cx, allocator, container, try box(cx, checkboxBoxStyle(t, effectively_checked, p.disabled), .{}));

        // 配置 Transition: 背景色和边框色自动过渡（替代手动 AnimatedColor）
        checkbox_box.applyTransition(allocator, &comptime recipe_mod.transition("background 150ms ease-out, border-color 150ms ease-out"));
        state.checkbox_box = checkbox_box;

        // Check 层：flex child，居中。
        // 默认用图标库的 `check` 字形（纯对勾，无外框，方框由 checkbox_box 自身绘制），
        // 调用方可通过 check_icon_asset 覆盖。
        const checkmark = try core.adoptChild(cx, allocator, checkbox_box, try core.iconTint(cx, p.check_icon_asset orelse icons.check, t.color.button_primary_fg, checkIconStyle()));
        checkmark.setOpacityRaw(if (state.checked) 1.0 else 0.0);

        // Indeterminate 层：absolute 覆盖 checkbox_box 同尺寸，内部 justify+align 居中
        const indet_overlay = try core.adoptChild(cx, allocator, checkbox_box, try box(cx, indetOverlayStyle(), .{}));
        // indeterminate 用图标库的 `minus` 字形（圆头横杠，无外框）
        _ = try core.adoptChild(cx, allocator, indet_overlay, try core.iconTint(cx, icons.minus, t.color.button_primary_fg, checkIconStyle()));
        indet_overlay.setOpacityRaw(if (state.indeterminate and !state.checked) 1.0 else 0.0);

        // 标签
        if (p.label_text) |lbl| {
            const label_node = try core.adoptChild(cx, allocator, container, try box(cx, .{}, .{}));
            var label_txt = controlLabelStyle(t, p.disabled);
            label_txt.content = lbl;
            label_node.setText(label_txt);
        }

        // 事件处理器
        container.behavior.events.event_context = state;

        // on_before_render 必须在 useFocusRing 之前设置，
        // 因为 useFocusRing 会链式保存旧的 on_before_render
        container.meta.per_frame.hooks.before_render.main = checkboxBeforeRender;

        if (!p.disabled) {
            container.behavior.events.on_event = checkboxEventHandler;

            // Scoped hover（始终提供 hover 效果）
            _ = try hooks.useHover(my_scope, container);
            try hooks.useFocusRing(my_scope, cx, container, .{});
        }

        return container;
    }
};

// ==================== Radio ====================

/// Radio 属性
pub const RadioProps = struct {
    checked: bool = false,
    label_text: ?[]const u8 = null,
    value: []const u8 = "",
    name: []const u8 = "",
    disabled: bool = false,
    on_change: ?core.HandlerRef = null,
    /// 跳过内部交互注册（RadioGroup 统一管理时设 true）
    _skip_interaction: bool = false,
};

/// 创建 Radio
pub fn Radio(props: RadioProps) RadioBuilder {
    return RadioBuilder{ .props = props };
}

pub const RadioBuilder = struct {
    props: RadioProps,

    pub fn checked(self: RadioBuilder, c: bool) RadioBuilder {
        var new = self;
        new.props.initial_checked = c;
        return new;
    }

    pub fn label(self: RadioBuilder, text: []const u8) RadioBuilder {
        var new = self;
        new.props.label_text = text;
        return new;
    }

    pub fn value(self: RadioBuilder, v: []const u8) RadioBuilder {
        var new = self;
        new.props.value = v;
        return new;
    }

    pub fn disabled(self: RadioBuilder, d: bool) RadioBuilder {
        var new = self;
        new.props.disabled = d;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: RadioBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // 外层容器
        const container = try box(cx, controlRowStyle(), .{});
        // sweep：container 守卫一直武装到 return；子节点建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Radio";
        try core.bindScopeToNode(my_scope, container);
        container.setOpacityRaw(if (p.disabled) 0.5 else 1.0);

        const circle = try core.adoptChild(cx, allocator, container, try box(cx, radioCircleStyle(t, p.checked), .{}));

        // 配置 Transition: 背景色和边框色自动过渡（选中态切换由 RadioGroup 的 before_render 触发）
        circle.applyTransition(allocator, &comptime recipe_mod.transition("background 150ms ease-out, border-color 150ms ease-out"));

        // 内部圆点（白色，始终存在，未选中时隐藏）
        const dot = try core.adoptChild(cx, allocator, circle, try box(cx, radioDotStyle(t), .{}));
        // 圆点的显隐做透明度过渡（与 circle 同步时长），避免硬切
        dot.applyTransition(allocator, &comptime recipe_mod.transition("opacity 150ms ease-out"));
        dot.setOpacityRaw(if (p.checked) 1.0 else 0.0);

        // 标签
        if (p.label_text) |lbl| {
            const label_node = try core.adoptChild(cx, allocator, container, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
            var label_txt = controlLabelStyle(t, false);
            label_txt.content = lbl;
            label_node.setText(label_txt);
        }

        // 交互（hover + focus ring），RadioGroup 统一管理时跳过
        if (p.disabled) {
            container.style.cursor = .not_allowed;
        } else if (!p._skip_interaction) {
            container.style.cursor = .pointer;
            _ = try hooks.useHoverHighlight(my_scope, container, circle, .border_color, t.color.checkbox_border, t.color.accent, .{});
            try hooks.useFocusRing(my_scope, cx, container, .{});
        }

        return container;
    }
};

// ==================== RadioGroup ====================

pub const RadioGroupProps = struct {
    options: []const RadioOption,
    value: ?[]const u8 = null,
    name: []const u8 = "",
    horizontal: bool = false,
    disabled: bool = false,
    on_change: ?core.HandlerRef = null,
    state_id: ?u64 = null,
};

pub const RadioOption = struct {
    value: []const u8,
    label_text: []const u8,
    disabled: bool = false,
};

/// RadioGroup 内部状态
pub const RadioGroupState = struct {
    /// 当前选中值的索引
    selected_index: ?usize = null,
    /// 选项数量
    option_count: usize = 0,
    /// 选项值列表 (指向外部 options 的指针, 最多 16 个)
    option_values: [16]?[]const u8 = [_]?[]const u8{null} ** 16,

    /// 外部回调
    /// 2026-07-31 并轨：统一 ?core.HandlerRef，用 invokeWithStr 触发。
    on_change: ?core.HandlerRef = null,

    pub fn select(self: *RadioGroupState, index: usize) void {
        if (index >= self.option_count) return;
        if (self.selected_index != null and self.selected_index.? == index) return;

        self.selected_index = index;

        if (self.on_change) |h| {
            if (self.option_values[index]) |val| h.invokeWithStr(val);
        }
    }
};

/// RadioGroup 点击上下文
const RadioClickContext = struct {
    group_state: *RadioGroupState,
    option_index: usize,
};

/// RadioGroup on_before_render 渲染上下文
const RadioGroupRenderContext = struct {
    state: *RadioGroupState,
    tokens: *const theme.ThemeTokens,
    option_count: usize,
    last_selected: ?usize = null,
};

/// RadioGroup on_before_render 钩子：根据 selected_index 更新 radio 样式
fn radioGroupBeforeRender(node: *Node) void {
    const render_ctx: *RadioGroupRenderContext = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    const state = render_ctx.state;
    const t = render_ctx.tokens;

    // 脏检测：选中态没变就不用重设样式（避免重启 transition）。
    if (state.selected_index == render_ctx.last_selected) return;
    render_ctx.last_selected = state.selected_index;

    // 遍历 radio 子节点
    const count = @min(node.children.items.len, render_ctx.option_count);
    for (node.children.items[0..count], 0..) |radio, i| {
        const is_checked = if (state.selected_index) |si| si == i else false;
        if (radio.behavior.interaction.a11y) |*a11y| a11y.checked = is_checked;
        if (radio.children.items.len == 0) continue;

        const circle = radio.children.items[0];

        // 选中项：冻结其 hover 高亮钩子，把 border 控制权收回来钉死成 accent。
        // 否则 hover 钩子每帧把 border 插值回 normal(=checkbox_border 浅灰)，盖掉选中底色
        // 鼠标移开后选中圈就镶一层浅灰。未选中项解冻，border 交还 hover 钩子管理。
        _ = hooks.setHoverHighlightFrozen(circle, is_checked);

        // 用非 Raw setter，走 mount 时配的 Transition slot 平滑插值（Raw 会瞬切->僵硬）。
        circle.setBackground(if (is_checked) t.color.accent else t.color.checkbox_bg);
        circle.setBorderColor(if (is_checked) t.color.accent else t.color.checkbox_border);

        if (circle.children.items.len > 0) {
            const dot = circle.children.items[0];
            dot.setOpacity(if (is_checked) 1.0 else 0.0);
        }
    }
    node.markRenderDirty();
}

/// RadioGroup 点击事件处理器
fn radioGroupClickHandler(event: Event, context: ?*anyopaque) EventResult {
    const click_ctx: *RadioClickContext = @ptrCast(@alignCast(context orelse return .ignored));

    switch (event) {
        .click => {
            click_ctx.group_state.select(click_ctx.option_index);
            return .handled;
        },
        else => return .ignored,
    }
}

/// 创建 RadioGroup
pub fn RadioGroup(props: RadioGroupProps) RadioGroupBuilder {
    return RadioGroupBuilder{ .props = props };
}

pub const RadioGroupBuilder = struct {
    props: RadioGroupProps,

    /// 保留模式: mount（Scope 管理 RadioGroupState 生命周期）
    pub fn mount(self: RadioGroupBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Scope 分配 RadioGroupState
        const state = try my_scope.allocator.create(RadioGroupState);
        state.* = blk: {
            var initial = RadioGroupState{};
            initial.option_count = @min(p.options.len, 16);
            for (p.options, 0..) |opt, i| {
                if (i >= 16) break;
                initial.option_values[i] = opt.value;
            }
            if (p.value) |v| {
                for (p.options, 0..) |opt, i| {
                    if (std.mem.eql(u8, opt.value, v)) {
                        initial.selected_index = i;
                        break;
                    }
                }
            }
            break :blk initial;
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *RadioGroupState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);

        state.on_change = p.on_change;

        const container = try box(cx, radioGroupContainerStyle(p.horizontal), .{});
        // sweep：container 守卫一直武装到 return；每个 radio 建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "RadioGroup";
        try core.bindScopeToNode(my_scope, container);
        container.addDebugState(@ptrCast(state));

        // Scope 分配渲染上下文
        const render_ctx = try my_scope.allocator.create(RadioGroupRenderContext);
        render_ctx.* = .{
            .state = state,
            .tokens = t,
            .option_count = p.options.len,
            .last_selected = state.selected_index,
        };
        try my_scope.adoptResource(@ptrCast(render_ctx), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *RadioGroupRenderContext = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);
        container.behavior.events.event_context = render_ctx;
        container.meta.per_frame.hooks.before_render.main = radioGroupBeforeRender;

        for (p.options, 0..) |opt, i| {
            const is_checked = if (state.selected_index) |si| si == i else false;
            const is_disabled = p.disabled or opt.disabled;

            const radio = try core.adoptChild(cx, allocator, container, try Radio(.{
                .checked = is_checked,
                .label_text = opt.label_text,
                .value = opt.value,
                .name = p.name,
                .disabled = is_disabled,
                ._skip_interaction = true,
            }).mount(my_scope, cx));

            if (!is_disabled) {
                radio.style.cursor = .pointer;
                // Scope 分配点击上下文
                const click_ctx = try my_scope.allocator.create(RadioClickContext);
                click_ctx.* = .{ .group_state = state, .option_index = i };
                try my_scope.adoptResource(@ptrCast(click_ctx), struct {
                    fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const s: *RadioClickContext = @ptrCast(@alignCast(ptr));
                        alloc.destroy(s);
                    }
                }.destroy);

                radio.behavior.events.on_event = radioGroupClickHandler;
                radio.behavior.events.event_context = click_ctx;
                radio.tag = .button;
                radio.setFocusable(true);
                radio.behavior.interaction.a11y = .{ .role = .radio, .checked = is_checked };

                // Scope 版 hover 高亮（所有非 disabled 项都注册，选中态由 beforeRender 覆盖）
                const circle_node = radio.children.items[0];
                _ = try hooks.useHoverHighlight(my_scope, radio, circle_node, .border_color, t.color.checkbox_border, t.color.accent, .{});
                try hooks.useFocusRing(my_scope, cx, radio, .{});
            }
        }

        return container;
    }
};

// ==================== Switch ====================

/// Switch 内部状态
pub const SwitchState = struct {
    /// Toggle 状态 (委托给 hooks.ToggleState)
    toggle_state: hooks.ToggleState = .{},
    hovered: bool = false,

    /// thumb Off/On 的 x 位置
    x_off: f32 = 2,
    x_on: f32 = 20,
    /// 上一帧的 checked 状态（用于检测变化并发起动画）
    last_checked: bool = false,

    /// Theme tokens 引用
    tokens: *const theme.ThemeTokens = &theme.dark,

    /// 节点引用
    track: ?*core.Node = null,
    thumb: ?*core.Node = null,

    /// 动画分配器（必须与节点的 allocator 一致）
    alloc: std.mem.Allocator = std.heap.page_allocator,

    pub fn toggle(self: *SwitchState) void {
        self.toggle_state.toggle();
    }
};

const node_animator = @import("../../animation/node_animator.zig");

/// Switch 渲染前钩子：检测 checked 变化 -> 发起 translate_x 动画 + 颜色联动
fn updateSwitchThumbPosition(node: *core.Node) void {
    const state: *SwitchState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    const thumb = state.thumb orelse return;
    const track = state.track orelse return;

    // 检测 checked 状态变化，发起 translate_x 动画
    const checked = state.toggle_state.checked;
    if (node.behavior.interaction.a11y) |*a11y| a11y.checked = checked;
    const target = if (checked) state.x_on else state.x_off;
    if (state.last_checked != checked) {
        state.last_checked = checked;
        node_animator.animateNode(thumb, state.alloc, .{
            .prop = .translate_x,
            .to = target,
            .duration = 0.2,
            .easing = .ease_out_cubic,
        });
    }

    // 用 thumb 的当前 translate_x 计算归一化进度（animateNode 自动驱动 translate_x）
    const travel = state.x_on - state.x_off;
    const t = if (travel > 0.1) std.math.clamp((thumb.style.translate_x - state.x_off) / travel, 0, 1) else 0;

    // 颜色联动（插值端点集中在 SwitchColors）
    const track_color = SwitchColors.track(state.tokens, t);
    const thumb_c = SwitchColors.thumb(state.tokens, t);
    const label_c = SwitchColors.label(state.tokens, t);
    node.setOpacityRaw(if (state.toggle_state.disabled) 0.5 else 1.0);

    track.setBackgroundRaw(track_color);
    thumb.setBackgroundRaw(thumb_c);
    if (node.children.items.len > 1) {
        const label_node = node.children.items[1];
        if (label_node.getText()) |old| {
            var txt = old;
            txt.color = label_c;
            label_node.setText(txt);
        }
    }

    // 动画进行中持续刷新（颜色联动需要跟踪 translate_x 变化）
    if (thumb.frame_state.frame_local.runtime.commands) |anims| {
        if (anims.count > 0) {
            node.markRenderDirty();
        }
    }
    thumb.markInteractionDirty();
}

/// Switch 事件处理器: 转发给内嵌的 ToggleState
fn switchEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *SwitchState = @ptrCast(@alignCast(context orelse return .ignored));
    return hooks.toggleEventHandlerFn(event, &state.toggle_state);
}

/// Switch 属性
pub const SwitchProps = struct {
    /// 初始开关态。**只在 mount 时读取一次**（语义同
    /// CheckboxProps.initial_checked）。
    initial_checked: bool = false,
    label_text: ?[]const u8 = null,
    disabled: bool = false,
    on_change: ?core.HandlerRef = null,
    state_id: ?u64 = null,
};

/// 创建 Switch
pub fn Switch(props: SwitchProps) SwitchBuilder {
    return SwitchBuilder{ .props = props };
}

pub const SwitchBuilder = struct {
    props: SwitchProps,

    pub fn checked(self: SwitchBuilder, c: bool) SwitchBuilder {
        var new = self;
        new.props.initial_checked = c;
        return new;
    }

    pub fn label(self: SwitchBuilder, text: []const u8) SwitchBuilder {
        var new = self;
        new.props.label_text = text;
        return new;
    }

    pub fn disabled(self: SwitchBuilder, d: bool) SwitchBuilder {
        var new = self;
        new.props.disabled = d;
        return new;
    }

    pub fn onChange(self: SwitchBuilder, handler_ref: core.HandlerRef) SwitchBuilder {
        var new = self;
        new.props.on_change = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: SwitchBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Scope 分配内部状态
        const state = try my_scope.allocator.create(SwitchState);
        state.* = .{
            .toggle_state = .{
                .checked = p.initial_checked,
                .disabled = p.disabled,
                .on_change = p.on_change,
            },
            .alloc = allocator,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *SwitchState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);

        state.tokens = t;

        // 外层容器
        const container = try box(cx, controlRowStyle(), .{});
        // sweep：container 守卫一直武装到 return；track / thumb / label 建好即 adopt
        errdefer cx.freeNode(container);
        container.tag = .button;
        container.setFocusable(true);
        container.meta.ownership.meta.component_name = "Switch";
        try core.bindScopeToNode(my_scope, container);
        container.behavior.interaction.a11y = .{ .role = .switch_role, .label = p.label_text, .checked = state.toggle_state.checked, .disabled = p.disabled };
        container.addDebugState(@ptrCast(state));

        // 轨道 + thumb：样式来自具名样式函数；init_translate 与 SwitchState.x_off/x_on 对应
        const is_on = state.toggle_state.checked;
        const track = try core.adoptChild(cx, allocator, container, try box(cx, switchTrackStyle(t, is_on), .{}));

        const init_translate: f32 = if (is_on) state.x_on else state.x_off;
        const thumb = try core.adoptChild(cx, allocator, track, try box(cx, switchThumbStyle(t, is_on, init_translate), .{}));

        state.track = track;
        state.thumb = thumb;
        state.last_checked = p.initial_checked;

        if (p.disabled) {
            container.style.cursor = .not_allowed;
            track.setBackgroundRaw(SwitchColors.disabledTrack(t, is_on));
            thumb.setBackgroundRaw(SwitchColors.disabledThumb(t, is_on));
        } else {
            container.style.cursor = .pointer;
        }

        // 标签
        if (p.label_text) |lbl| {
            const label_node = try core.adoptChild(cx, allocator, container, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
            var label_txt = switchLabelStyle(t, is_on, p.disabled);
            label_txt.content = lbl;
            label_node.setText(label_txt);
        }

        // 事件处理器
        container.behavior.events.event_context = state;
        if (!p.disabled) {
            container.behavior.events.on_event = switchEventHandler;
        }

        // on_before_render 必须在 useFocusRing 之前设置，
        // 因为 useFocusRing 会链式保存旧的 on_before_render
        container.meta.per_frame.hooks.before_render.main = updateSwitchThumbPosition;

        if (!p.disabled) {
            const is_hovered = try hooks.useHover(my_scope, container);
            try my_scope.createEffect(.{
                .state = state,
                .is_hovered = is_hovered,
                .node = container,
            }, struct {
                fn update(c: anytype) void {
                    c.state.hovered = c.is_hovered.get();
                    c.node.markRenderDirty();
                }
            }.update);

            try hooks.useFocusRing(my_scope, cx, container, .{});
        }

        return container;
    }
};

// ========== 测试 ==========

test "Checkbox: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const cb = try Checkbox(.{})
        .label("Remember me")
        .checked(false)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, cb);

    // 应该有 2 个子节点: checkbox box + label
    try std.testing.expectEqual(@as(usize, 2), cb.children.items.len);
}

test "Checkbox: checked state" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const cb = try Checkbox(.{})
        .label("Checked")
        .checked(true)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, cb);

    // 选中状态下，checkbox box 有 2 个子节点: checkmark + indet_overlay
    const checkbox_box = cb.children.items[0];
    try std.testing.expectEqual(@as(usize, 2), checkbox_box.children.items.len);
}

test "Checkbox: accessibility state tracks mixed and runtime toggle" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const cb = try Checkbox(.{ .indeterminate = true }).label("Mixed").mount(scope, ctx);
    try root.appendChild(std.testing.allocator, cb);
    try std.testing.expect(cb.behavior.interaction.a11y.?.indeterminate);
    try std.testing.expect(!cb.behavior.interaction.a11y.?.checked.?);

    const state: *CheckboxState = @ptrCast(@alignCast(cb.behavior.events.event_context.?));
    state.toggle();
    checkboxBeforeRender(cb);
    try std.testing.expect(!cb.behavior.interaction.a11y.?.indeterminate);
    try std.testing.expect(cb.behavior.interaction.a11y.?.checked.?);
}

test "Checkbox: state toggle via CheckboxState" {
    var state = CheckboxState{ .checked = false };

    try std.testing.expect(!state.checked);

    state.toggle();
    try std.testing.expect(state.checked);

    state.toggle();
    try std.testing.expect(!state.checked);
}

test "Checkbox: toggle fires on_change callback" {
    const CallbackCtx = struct {
        last_value: bool = false,
        call_count: u32 = 0,
    };

    var cb_ctx = CallbackCtx{};

    var state = CheckboxState{
        .checked = false,
        // 并轨后：boolHandlerFrom 把 context 与回调捆在一起，
        // 且**必须真的收到 new_val**，这正是并轨最容易丢的东西。
        .on_change = core.Cx.boolHandlerFrom(CallbackCtx, &cb_ctx, struct {
            fn handler(c: *CallbackCtx, new_val: bool) void {
                c.last_value = new_val;
                c.call_count += 1;
            }
        }.handler),
    };

    state.toggle();
    try std.testing.expect(state.checked);
    try std.testing.expect(cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 1), cb_ctx.call_count);

    state.toggle();
    try std.testing.expect(!state.checked);
    try std.testing.expect(!cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 2), cb_ctx.call_count);
}

test "Checkbox: disabled state prevents toggle" {
    var state = CheckboxState{ .checked = false, .disabled = true };

    state.toggle();
    try std.testing.expect(!state.checked); // 不应该改变
}

test "Checkbox: event handler responds to click" {
    var state = CheckboxState{ .checked = false };

    const result = checkboxEventHandler(.{ .click = .{
        .x = 10,
        .y = 10,
        .button = .left,
        .click_count = 1,
    } }, @ptrCast(&state));

    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(state.checked);
}

test "Checkbox: event handler responds to space key" {
    var state = CheckboxState{ .checked = false };

    const result = checkboxEventHandler(.{ .key_down = .{
        .key = .space,
        .raw_keycode = 49,
        .modifiers = .{},
    } }, @ptrCast(&state));

    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(state.checked);
}

test "Radio: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const radio = try Radio(.{})
        .label("Option 1")
        .value("opt1")
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, radio);
    try std.testing.expectEqual(@as(usize, 2), radio.children.items.len);
}

test "Radio: checked render emits inner dot" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(120, 40);

    const root = try box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const radio = try Radio(.{
        .checked = true,
        .label_text = "On",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, radio);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_dot = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.color.button_primary_fg) and r.geom.w >= 7 and r.geom.h >= 7 and r.geom.w <= 10 and r.geom.h <= 10) {
            saw_dot = true;
        }
    };

    try std.testing.expect(saw_dot);
}

test "Radio: disabled checked keeps selected color and uses container opacity" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const radio = try Radio(.{
        .checked = true,
        .disabled = true,
        .label_text = "Disabled",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, radio);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), radio.getOpacity(), 0.001);
    try std.testing.expectEqual(ctx.tokens.color.accent, radio.children.items[0].getBackground());
    try std.testing.expectEqual(ctx.tokens.color.accent, radio.children.items[0].style.border.color);
}

test "RadioGroup: multiple options" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const options = [_]RadioOption{
        .{ .value = "a", .label_text = "Option A" },
        .{ .value = "b", .label_text = "Option B" },
        .{ .value = "c", .label_text = "Option C" },
    };

    const group = try RadioGroup(.{
        .options = &options,
        .value = "b",
        .name = "test-group",
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, group);
    try std.testing.expectEqual(@as(usize, 3), group.children.items.len);
}

test "Switch: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const sw = try Switch(.{})
        .label("Enable feature")
        .checked(true)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, sw);
    try std.testing.expectEqual(@as(usize, 2), sw.children.items.len);
}

test "Switch: checked render emits track and thumb" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(140, 40);

    const root = try box(ctx, .{
        .width = .{ .px = 140 },
        .height = .{ .px = 40 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sw = try Switch(.{
        .initial_checked = true,
        .label_text = "Enabled",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, sw);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_track = false;
    var saw_thumb = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.color.accent) and r.geom.w >= 38 and r.geom.h >= 20) saw_track = true;
        if (Color.eql(r.color.toColor(), Color.hex(0xFFFFFF)) and r.geom.w >= 16 and r.geom.h >= 16 and r.geom.w <= 20 and r.geom.h <= 20) saw_thumb = true;
    };

    try std.testing.expect(saw_track);
    try std.testing.expect(saw_thumb);
}

test "Switch: state toggle via SwitchState" {
    var state = SwitchState{};

    try std.testing.expect(!state.toggle_state.checked);

    state.toggle();
    try std.testing.expect(state.toggle_state.checked);

    state.toggle();
    try std.testing.expect(!state.toggle_state.checked);
}

test "Switch: toggle fires on_change callback" {
    const CallbackCtx = struct {
        last_value: bool = false,
        call_count: u32 = 0,
    };

    var cb_ctx = CallbackCtx{};

    var state = SwitchState{
        .toggle_state = .{
            .checked = false,
            .on_change = core.Cx.boolHandlerFrom(CallbackCtx, &cb_ctx, struct {
                fn handler(c: *CallbackCtx, new_val: bool) void {
                    c.last_value = new_val;
                    c.call_count += 1;
                }
            }.handler),
        },
    };

    state.toggle();
    try std.testing.expect(state.toggle_state.checked);
    try std.testing.expect(cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 1), cb_ctx.call_count);
}

test "Switch: disabled state prevents toggle" {
    var state = SwitchState{ .toggle_state = .{ .checked = false, .disabled = true } };

    state.toggle();
    try std.testing.expect(!state.toggle_state.checked);
}

test "Switch: event handler responds to click" {
    var state = SwitchState{};

    const result = switchEventHandler(.{ .click = .{
        .x = 10,
        .y = 10,
        .button = .left,
        .click_count = 1,
    } }, @ptrCast(&state));

    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(state.toggle_state.checked);
}

test "Switch: event handler responds to space key" {
    var state = SwitchState{ .toggle_state = .{ .checked = true } };

    const result = switchEventHandler(.{ .key_down = .{
        .key = .space,
        .raw_keycode = 49,
        .modifiers = .{},
    } }, @ptrCast(&state));

    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(!state.toggle_state.checked); // toggled off
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "checkbox(indeterminate): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("checkbox(indeterminate)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Checkbox(.{ .label_text = "check", .indeterminate = true }).mount(scope, cx);
        }
    }.m);
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "radio_group: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("radio_group", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const opts = [_]RadioOption{ .{ .value = "a", .label_text = "A" }, .{ .value = "b", .label_text = "B", .disabled = true } };
            return try RadioGroup(.{ .options = &opts, .value = "a" }).mount(scope, cx);
        }
    }.m);
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "switch: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("switch", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Switch(.{ .label_text = "toggle", .initial_checked = true }).mount(scope, cx);
        }
    }.m);
}
