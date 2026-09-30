/// Input Component — facade
///
/// 文本输入组件，支持键盘输入、光标导航、焦点管理
///
/// 特性:
/// - 键盘输入: text_input 事件, 箭头键导航
/// - 编辑操作: backspace, delete, Cmd+A 全选
/// - 焦点管理: 自动注册可聚焦, focus/blur 事件
/// - 状态管理: 通过 Scope 管理 TextInputState 生命周期
/// - 标签和辅助文本
/// - 错误状态
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const recipe_mod = @import("../../recipe.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Signal = core.Signal;
const createEffect = core.createEffect;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const hooks = @import("../../hooks.zig");
const Scope = @import("../../reactive.zig").Scope;
const editable_block = @import("../editable_block/mod.zig");
const control_shell = @import("../control_shell/mod.zig");
const svg_assets = @import("../../svg_assets.zig");

// ========== Sub-module imports ==========
const state_mod = @import("state.zig");
const render_mod = @import("render.zig");
const events_mod = @import("events.zig");
const styles = @import("styles.zig");
const textarea_mod = @import("textarea.zig");
const editable_text_mod = @import("editable_text.zig");

// ========== Public re-exports ==========
pub const TextInputState = state_mod.TextInputState;
pub const UndoSnapshot = editable_block.UndoSnapshot;
pub const InputType = editable_block.InputType;
pub const InputSize = control_shell.ControlSize;
pub const TextareaState = textarea_mod.TextareaState;
pub const inputEventHandler = events_mod.inputEventHandler;
pub const EditableText = editable_text_mod.EditableText;
pub const EditableTextResult = editable_text_mod.EditableTextResult;
pub const EditableTextProps = editable_text_mod.EditableTextProps;
pub const textareaEventHandler = textarea_mod.textareaEventHandler;

// Re-export text_utils for external consumers
pub const text_utils = @import("text_utils.zig");

/// 输入框属性
pub const InputProps = struct {
    /// 初始值。**只在 mount 时读取一次** —— 之后改无效。
    /// 首帧之后要写入内容，用 `mountResult()` 拿 `result.state` 再调
    /// `setText()`（2026-07-31 新增）。
    initial_value: ?[]const u8 = null,
    growable: bool = false,
    /// 占位符
    placeholder: ?[]const u8 = null,
    /// 占位符文本颜色覆盖
    placeholder_color: ?Color = null,
    /// 输入类型
    input_type: InputType = .text,
    /// 尺寸 (统一 ControlSize，默认 md；外框高度 = padding_y × 2 + font_size × line_height，
    /// 默认主题 xs=20 / sm=24 / md=32 / lg=40)
    size: InputSize = .md,
    /// 标签
    label_text: ?[]const u8 = null,
    /// 辅助文本
    helper: ?[]const u8 = null,
    /// 错误信息
    error_msg: ?[]const u8 = null,
    /// 必填
    required: bool = false,
    /// 只读
    readonly: bool = false,
    /// 禁用
    disabled: bool = false,
    /// 宽度
    width: ?f32 = null,
    /// 左侧图标
    leading_icon_asset: ?svg_assets.Asset = null,
    /// 右侧附加文本（如计数）
    append_text: ?[]const u8 = null,
    /// 右侧附加图标（如 clear / eye）
    append_icon_asset: ?svg_assets.Asset = null,
    /// 嵌入复合控件时仅保留文本编辑能力，由父控件绘制统一 shell。
    /// Select/ComboBox 等组件使用它避免出现双层 border / focus ring。
    embedded: bool = false,
    /// 状态 ID (用于 StateStore, 如果为 null 则使用自动生成的 ID)
    state_id: ?u64 = null,
    /// 值变化回调
    /// 2026-07-31 并轨：统一 ?core.HandlerRef（用 cx.strHandlerFrom 构造以拿到文本）。
    on_change: ?core.HandlerRef = null,
};

/// 创建输入框
pub fn Input(props: InputProps) InputBuilder {
    return InputBuilder{ .props = props };
}

/// Input mount 结果（用于 Group 组合场景）
pub const InputResult = struct {
    /// wrapper 根节点（含 label/helper，传给 addGroupItem）
    node: *Node,
    /// 真正带 border/radius 的输入框节点
    input_container: *Node,
    /// 文本状态（ComboBox 等组合组件需要程序化读写输入值）。
    /// 生命周期随 Input 的内部 scope；caller 不得越过 wrapper 存活期使用。
    state: *TextInputState,

    /// 调用方拿到 InputResult 之后、**挂载失败**时用它归还。
    ///
    /// 为什么需要这个 API：`node` 被 bindScopeToNode 绑在 Input 自己的
    /// childScope 上，而那个 childScope 是**调用方 scope 的子 scope**。
    /// 于是调用方在错误路径上无论用哪种方式自己释放都会 UAF —— 消费方
    /// 下游编辑器实测过两种，都是 signal 6 + 0xaaaa 毒值：
    ///   - `cx.freeNode(node)`                        → invalidateReferencesToEx
    ///   - `cx.freeDetachedNodeAfterScopeDispose(node)` → unregisterSubtree
    /// 因为调用方 scope teardown 时会沿 scope 树再走一遍。
    ///
    /// ⚠️ 光靠 scope 级联**不够**：Scope.disposeNow 只释放 effects/signals/
    /// resources，**从不释放绑定的节点**（ScopeBinding.destroy 也只解绑不释放，
    /// 见 core.zig bindScopeToNode 的注释）。所以"什么都不做"会真的泄漏 ——
    /// 消费方 OOM 注入实测该失败点泄漏 22 条。
    ///
    /// 正确做法：先让 Input 的 childScope 退场（把它从调用方 scope 的子链上摘掉
    /// 并跑完它自己的 cleanup），再释放节点子树。这样调用方 scope teardown 时
    /// 不会再遇到这棵已释放的子树，也就不会 UAF。
    ///
    /// 用法：
    ///     const im = try Input(...).mountResult(scope, cx);
    ///     errdefer im.abandon(cx);
    ///     try panel.appendChild(allocator, im.node);
    pub fn abandon(self: InputResult, cx: *Cx) void {
        // 顺序要紧：先 dispose 自己的 scope（它会从父 scope 的 children 里
        // swapRemove 自己），父 scope 之后就不会再碰这棵树；再释放节点。
        if (self.node.meta.ownership.scope.scope) |own_scope| {
            core.clearNodeScopes(self.node);
            if (!own_scope.disposed) own_scope.dispose();
        }
        cx.freeNode(self.node);
    }
};

fn updateGroupedFieldShellOutline(state: *TextInputState, active: bool) void {
    const host = state.focus_ring_host orelse return;
    if (active) {
        host.style.ensureExtPanic(state.allocator).z_index = 1;
        host.setStyle(state.allocator, .outline, .{
            .color = state.tokens.color.accent,
            .width = 1,
            .offset = 0,
        });
    } else {
        host.style.ensureExtPanic(state.allocator).z_index = 0;
        host.setStyle(state.allocator, .outline, null);
    }
    host.markRenderDirty();
}

fn syncGroupedCornerRadiusFromWrapper(wrapper: *Node, state: *TextInputState) void {
    const wrapper_corner = wrapper.style.corner_radius() orelse return;
    state.grouped_attached = true;
    const grouped_radii = wrapper_corner.resolve4();
    const grouped_corner: core.CornerRadius = .{ .each = grouped_radii };
    const grouped_is_uniform = grouped_radii[0] == grouped_radii[1] and
        grouped_radii[1] == grouped_radii[2] and
        grouped_radii[2] == grouped_radii[3];
    const wrapper_side_colors = wrapper.style.border_side_colors();

    // Group 场景下，wrapper 不应裁剪 input 的边框高亮
    wrapper.style.ensureExtPanic(state.allocator).clip_shape = .none;

    if (state.focus_ring_host) |field_shell| {
        field_shell.style.border.radius = 0;
        field_shell.style.ensureExtPanic(state.allocator).corner_radius = grouped_corner;
    }

    if (state.input_container_node) |input_container| {
        input_container.style.border.radius = 0;
        // 当前 render clip 对 overflow_hidden 仅支持统一半径（取四角最大值）。
        // Group 的 first/last 场景是非对称圆角（如 8,0,0,8），若仍 overflow_hidden
        // 会把右侧按 8 裁剪，导致边框看起来被 cut、右侧角不为 0。
        // 文本裁剪继续由 editable_surface 负责。
        input_container.style.overflow_hidden = grouped_is_uniform;
        const ic_ext = input_container.style.ensureExtPanic(state.allocator);
        ic_ext.corner_radius = grouped_corner;
        ic_ext.hit_shape = .auto;
        ic_ext.clip_shape = .auto;
        ic_ext.border_side_colors = wrapper_side_colors;
        // Group 的接缝现在由前一个 child 的 trailing border 持有。
        // input_container 不再抬高 z-index，否则会把后续 child 的 leading seam 盖掉。
        ic_ext.z_index = 0;
    }
}

fn inputWrapperBeforeRender(node: *Node) void {
    const ctx = node.behavior.events.event_context orelse return;
    const state: *TextInputState = @ptrCast(@alignCast(ctx));
    syncGroupedCornerRadiusFromWrapper(node, state);
}

/// 输入框构建器
pub const InputBuilder = struct {
    props: InputProps,

    pub fn placeholder(self: InputBuilder, text: []const u8) InputBuilder {
        var new = self;
        new.props.placeholder = text;
        return new;
    }

    pub fn label(self: InputBuilder, text: []const u8) InputBuilder {
        var new = self;
        new.props.label_text = text;
        return new;
    }

    pub fn helper(self: InputBuilder, text: []const u8) InputBuilder {
        var new = self;
        new.props.helper = text;
        return new;
    }

    pub fn errorMsg(self: InputBuilder, text: []const u8) InputBuilder {
        var new = self;
        new.props.error_msg = text;
        return new;
    }

    pub fn required(self: InputBuilder, r: bool) InputBuilder {
        var new = self;
        new.props.required = r;
        return new;
    }

    pub fn disabled(self: InputBuilder, d: bool) InputBuilder {
        var new = self;
        new.props.disabled = d;
        return new;
    }

    pub fn width(self: InputBuilder, w: f32) InputBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    /// 保留模式: mount（Scope 管理 TextInputState 生命周期）
    pub fn mount(self: InputBuilder, scope: *Scope, cx: *Cx) !*Node {
        return (try self.mountResult(scope, cx)).node;
    }

    /// mount 并返回包含 input_container 引用的结构体（用于 Group 组合场景）
    pub fn mountResult(self: InputBuilder, scope: *Scope, cx: *Cx) !InputResult {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        const has_error = p.error_msg != null;

        // Scope 分配 TextInputState（保留模式下节点不重建，状态随 scope 生存）
        const state = try my_scope.allocator.create(TextInputState);
        var state_registered = false;
        errdefer if (!state_registered) my_scope.allocator.destroy(state);
        state.* = blk: {
            var initial = TextInputState{};
            if (p.initial_value) |v| {
                // ⚠ 必须按 UTF-8 边界截断：@min 会把多字节序列拦腰截断，
                // 半个字符留在 buffer 里（与 setText/insertText 同一合同）。
                const copy_len = text_utils.utf8TruncateLen(v, initial.buffer.len);
                @memcpy(initial.buffer[0..copy_len], v[0..copy_len]);
                initial.buffer_len = copy_len;
                initial.cursor_pos = copy_len;
            }
            break :blk initial;
        };
        try my_scope.registerResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *TextInputState = @ptrCast(@alignCast(ptr));
                // 节点的 on_blur / event_context 都指向本 state。调用方若先 dispose scope
                // 再摘节点（聚焦中），摘树时 clearFocus 会回调已释放的 state（Notifier
                // 回复发送实测 SIGSEGV）。此刻 hover signal 等已先释放，也不能正常 blur：
                // 静默撤焦点。focused 节点由 FocusManager 合同保证存活。
                if (s.cx_ref) |c| {
                    if (c.focus_manager.getFocused()) |f| {
                        if (f.behavior.events.event_context == @as(?*anyopaque, @ptrCast(s))) c.focus_manager.abandonFocus(f);
                    }
                }
                s.deinit();
                alloc.destroy(s);
            }
        }.destroy);
        state_registered = true;

        state.growable = p.growable;
        state.allocator = allocator;
        if (p.growable) {
            if (p.initial_value) |value| {
                _ = try state.setTextChecked(value);
                state.clearUndoHistory();
            }
        }
        state.input_type = p.input_type;
        state.on_change = p.on_change;
        state.allocator = allocator;
        state.embedded_chrome = p.embedded;
        // 注入 cx 弱引用，让 utf8MeasuredAdvance 走 cx.shapeText 路径
        // 替代旧 measureTextWidthByFontKind。state.cx_ref 一直存活到 scope dispose。
        state.cx_ref = cx;

        // 从 ControlSize 读取统一尺寸（经主题 token）
        const sz = p.size;
        const metrics = t.control.get(sz);
        const input_font_size = metrics.font_size;
        // 行高与 Button/Select 同源（control metrics），不再自行 ceil —— 否则 md 高 1px
        const input_line_height = metrics.lineHeightPx();
        const input_text_line_height = metrics.line_height;
        const input_icon_size = metrics.icon_size;
        const inline_padding_in_content = p.leading_icon_asset == null and p.append_text == null and p.append_icon_asset == null;
        const content_padding_h: f32 = if (inline_padding_in_content) metrics.padding_h else 0;

        const wrapper = try box(cx, .{
            .width = if (p.width) |w| .{ .px = w } else .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = .column,
            .gap = 4,
        }, .{});
        errdefer cx.freeNode(wrapper);
        wrapper.meta.ownership.meta.component_name = "Input";
        wrapper.frame_state.state_bits.flags.disable_render_cache = true;
        try core.bindScopeToNode(my_scope, wrapper);
        scope_bound = true;
        wrapper.addDebugState(@ptrCast(state));
        wrapper.behavior.events.event_context = state;
        wrapper.meta.per_frame.hooks.before_render.main = inputWrapperBeforeRender;

        // 标签
        if (p.label_text) |lbl| {
            const label_row = try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
                .direction = .row,
                .align_items = .center,
                .gap = 4,
            }, .{});

            try appendInputChild(cx, wrapper, label_row);
            const label_node = try box(cx, .{ .width = .{ .fit = .{} } }, .{});
            try appendInputChild(cx, label_row, label_node);
            var label_txt = styles.labelTextStyle(t);
            label_txt.content = lbl;
            label_node.setText(label_txt);

            if (p.required) {
                const required_node = try box(cx, .{ .width = .{ .fit = .{} } }, .{});
                try appendInputChild(cx, label_row, required_node);
                required_node.setText(styles.requiredMarkStyle(t));
            }
        }

        // 输入框 ring 外层
        const field_shell = try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .border = .{ .radius = metrics.radius },
            .direction = .column,
        }, .{});

        try appendInputChild(cx, wrapper, field_shell);
        var shell = try control_shell.controlShell(.{
            .size = sz,
            .variant = .field,
            .disabled = p.disabled,
            .leading_icon = p.leading_icon_asset != null,
            .style = .{
                .width = if (p.width) |w| .{ .px = w } else null,
                // 常规 Input: 将水平 padding 下沉到 editable_surface（与 overflow shadow 同层）
                .padding = if (inline_padding_in_content)
                    Padding{ .top = metrics.padding_y, .right = 0, .bottom = metrics.padding_y, .left = 0 }
                else
                    null,
            },
            .interactive = false,
            .focus_ring = false,
            .cursor = if (p.disabled) .default else .text,
        }, my_scope, cx);

        // shell.node 从 controlShell 返回到挂进 field_shell 之间是游离子树：
        // 此前只有 icon_slot / append_slot 有 errdefer，**根节点本身没有** ——
        // 中途任何一步失败都会泄漏它（含 controlShell 给它分配的 StyleExt）。
        // 消费方下游编辑器的 OOM 注入实测：泄漏栈就是
        // controlShell 的 ensureExtFallible → Input.mountResult。
        var shell_node_owned = true;
        errdefer if (shell_node_owned) cx.freeNode(shell.node);
        var icon_owned = true;
        errdefer if (icon_owned) cx.freeNode(shell.icon_slot);
        var append_owned = true;
        errdefer if (append_owned) cx.freeNode(shell.append_slot);
        const input_container = shell.node;
        // shell_node_owned already owns failure cleanup; the adopting helper
        // would free the same detached subtree twice when append allocates.
        try field_shell.appendChild(cx.allocator, input_container);
        shell_node_owned = false; // 已归 field_shell 子树
        input_container.tag = .input;
        input_container.setFocusable(true);
        input_container.behavior.interaction.a11y = .{
            .role = .textbox,
            // Explicit empty suppresses core's subtree-text label fallback.
            // The current value (and password mask) must never become the
            // control's changing accessible name.
            .label = p.label_text orelse "",
            .placeholder = p.placeholder,
            .disabled = p.disabled,
            .required = p.required,
            .readonly = p.readonly,
            .invalid = has_error,
            .secure = p.input_type == .password,
        };
        input_container.style.overflow_hidden = false;
        const input_radius = input_container.style.border.radius;
        const input_hit_ext = try input_container.style.ensureExtFallible(allocator);
        input_hit_ext.hit_shape = .{ .rounded_rect = input_radius };
        input_hit_ext.clip_shape = .none;
        state.focus_ring_host = field_shell;
        state.input_container_node = input_container;
        if (!p.disabled and !p.readonly) {
            input_container.behavior.interaction.text_input_client = render_mod.textInputClient(state);
        }
        state.has_error = has_error;
        wrapper.setInteractionDelegate(input_container);
        field_shell.setInteractionDelegate(input_container);

        // border 动画统一到 Transition 系统
        input_container.applyTransition(allocator, &comptime recipe_mod.transition("border-color 150ms"));

        // mount 初始边框：error/有值时显式着色；空值+无错保持 shell field 变体默认
        if (has_error or state.hasVisualValue()) {
            input_container.setBorderColor(styles.restingBorderColor(t, has_error, state.hasVisualValue()));
        }

        if (p.leading_icon_asset) |asset| {
            const leading_icon = try core.iconTint(cx, asset, styles.iconTintColor(t, has_error), .{
                .width = .{ .px = input_icon_size },
                .height = .{ .px = input_icon_size },
            });
            // 建好到挂进 icon_slot 之间是游离子树，append 失败即泄漏。
            var leading_icon_owned = true;
            errdefer if (leading_icon_owned) cx.freeNode(leading_icon);
            // 已有门控 errdefer —— 不能再走会自释放 child 的 appendInputChild，
            // 否则 append 失败时释放两次（生存哨兵实测 signal 6）。
            try shell.icon_slot.appendChild(cx.allocator, leading_icon);
            leading_icon_owned = false;
            // 有 leading icon 时将 icon_slot 挂到 content_slot 之前
            try input_container.replaceChildOrder(allocator, &.{ shell.icon_slot, shell.content_slot });
            icon_owned = false;
        } else {
            // 无 leading icon: icon_slot 不会挂载，主动释放
            cx.freeNode(shell.icon_slot);
            icon_owned = false;
        }

        // Center the single text line in the available height, just like the caret.
        // The surface still fills content_slot so horizontal clipping is unchanged.
        const editable_surface = try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .justify = .center,
            .overflow_hidden = true,
        }, .{});
        // 建好到挂进 content_slot 之间是游离子树。
        var editable_surface_owned = true;
        errdefer if (editable_surface_owned) cx.freeNode(editable_surface);
        // 同上：有门控就用裸 appendChild，一个 child 只能有一个回收责任方。
        try shell.content_slot.appendChild(cx.allocator, editable_surface);
        editable_surface_owned = false; // 紧跟 append：晚一行就会在后续失败时二次释放
        const editable_ext = try editable_surface.style.ensureExtFallible(allocator);
        editable_ext.min_width = 0;
        editable_ext.overflow_fade = .{
            .size = 12,
            .color = styles.overflowFadeColor(t),
            .edges = .{ .top = false, .bottom = false, .left = true, .right = true },
        };
        editable_surface.behavior.events.event_context = state;
        // content_slot 也需要 grow 高度，让 editable_surface 能撑满
        shell.content_slot.style.height = .{ .grow = .{} };

        state_mod.applyEditableBlockConfig(
            state,
            .{ .multiline = false, .accept_newline = false, .soft_wrap = false },
            .{ .char_width = 7.8, .font_size = input_font_size, .padding_h = content_padding_h, .padding_v = 0, .line_height = input_line_height },
            null,
            cx,
            t,
        );
        state.updateScrollX();

        // 显示文本（在 editable_surface 内，受 overflow_hidden 裁剪）
        const has_content = state.hasVisualValue();
        const display_text = state.buildDisplayText(p.placeholder);
        const text_color = styles.displayTextColor(t, has_error, has_content, p.placeholder_color);

        var text_node = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
        }, .{});
        // 建好到挂进 editable_surface 之间是游离子树。
        var text_node_owned = true;
        errdefer if (text_node_owned) cx.freeNode(text_node);
        // 同上。
        try editable_surface.appendChild(cx.allocator, text_node);
        text_node_owned = false; // 紧跟 append
        const text_node_ext = try text_node.style.ensureExtFallible(allocator);
        // 覆盖父容器默认 align_items=stretch，保留文本 intrinsic 宽度用于 overflow fade 判断
        text_node_ext.align_self = .start;
        // Growable storage may move before the next render, including when
        // refreshing the display subsequently fails. Retain an owned snapshot.
        const retain_display = p.growable and display_text.len > 0;
        const initial_display = if (retain_display) try allocator.dupe(u8, display_text) else display_text;
        text_node.setText(.{
            .content = if (initial_display.len > 0) initial_display else "",
            .owned = retain_display,
            .color = text_color,
            .font_size = input_font_size,
            .line_height = input_text_line_height,
            .spans = state.text_spans_buf[0..0],
            .spans_owned = false,
            // selection / IME 高亮纯视觉，不影响文本布局尺寸。
            .spans_affect_layout = false,
        });
        text_node.style.padding.left = state.padding_h - state.scroll_x;
        state.text_display_node = text_node;
        state.placeholder_text = p.placeholder;
        state.placeholder_color = p.placeholder_color;

        editable_surface.meta.per_frame.hooks.before_render.main = render_mod.inputBeforeRender;

        // Single-line Input: selection / IME preedit underline / IME marked highlight 全部走
        // text_display_node.text.spans —— glyph 永远在 span 背景之上，根除"selection 遮文字"
        // 和"位置对不齐"两类 bug。只保留 cursor_node（光标条不属于文本属性）。

        const cursor_node = try box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{});
        try appendInputChild(cx, shell.content_slot, cursor_node);
        state.cursor_node = cursor_node;

        if (p.append_text != null or p.append_icon_asset != null) {
            const append_wrap = try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
                .direction = .row,
                .align_items = .center,
                .gap = metrics.gap,
            }, .{});

            try appendInputChild(cx, shell.append_slot, append_wrap);
            if (p.append_text) |append_text_val| {
                const append_text_node = try box(cx, .{ .width = .{ .fit = .{} } }, .{});
                try appendInputChild(cx, append_wrap, append_text_node);
                var append_txt = styles.appendTextStyle(t, input_font_size);
                append_txt.content = append_text_val;
                append_text_node.setText(append_txt);
            }

            if (p.append_icon_asset) |asset| {
                const append_icon = try core.iconTint(cx, asset, styles.iconTintColor(t, has_error), .{
                    .width = .{ .px = input_icon_size },
                    .height = .{ .px = input_icon_size },
                });
                try appendInputChild(cx, append_wrap, append_icon);
            }
        }

        // append_slot 有内容时挂到 content_slot 之后
        if (shell.append_slot.children.items.len > 0) {
            try input_container.appendChild(allocator, shell.append_slot);
            append_owned = false;
        } else {
            // 无 append/suffix: append_slot 不会挂载，主动释放
            cx.freeNode(shell.append_slot);
            append_owned = false;
        }

        // 注册事件处理器
        if (!p.disabled and !p.readonly) {
            input_container.behavior.events.on_event = events_mod.inputEventHandler;
            input_container.behavior.events.event_context = state;

            const state_opaque: *anyopaque = state;
            input_container.behavior.events.on_focus = .{
                .callback = struct {
                    fn handler(c: *anyopaque) void {
                        const s: *TextInputState = @ptrCast(@alignCast(c));
                        s.focused = true;
                        // 注意: 不设 dirty=true，聚焦不改变文本内容。
                        // multiline 模式下 dirty 会触发 rebuildTextareaTextNodes →
                        // markRuntimeIndexDirty → 节点从 registry detach → 焦点丢失。
                        // 更新边框样式: 聚焦 → focus 态色（保持 1px，避免交界处抖动）
                        if (!s.has_error and !s.embedded_chrome) {
                            if (s.input_container_node) |container| {
                                container.setBorderColor(styles.borderColor(s.tokens, s.restingBorderColor(), false, true, false));
                                // 聚焦只变色，不再放大 border width。
                                container.style.border.width = 1;
                                container.markRenderDirty();
                            }
                        }
                        if (s.grouped_attached) updateGroupedFieldShellOutline(s, true);
                        if (s.focus_ring_host) |host| {
                            if (host.behavior.events.on_focus) |h| h.invoke();
                        }
                    }
                }.handler,
                .context = state_opaque,
            };
            input_container.behavior.events.on_blur = .{
                .callback = struct {
                    fn handler(c: *anyopaque) void {
                        const s: *TextInputState = @ptrCast(@alignCast(c));
                        s.focused = false;
                        s.cancelImeComposition();
                        s.selection_anchor = null;
                        s.syncDocFromCursor();
                        s.is_dragging = false;
                        s.suspend_drag_until_mouse_up = false;
                        s.consecutive_mouse_downs = 0;
                        s.last_mouse_down_instant = null;
                        // 注意: 不设 dirty=true（同 on_focus 的原因）
                        // 重置边框样式: 失焦时按 hover 态解析边框颜色
                        if (!s.has_error and !s.embedded_chrome) {
                            const still_hovered = if (s.hover_signal) |hs| hs.get() else false;
                            if (s.input_container_node) |container| {
                                container.setBorderColor(styles.borderColor(s.tokens, s.restingBorderColor(), still_hovered, false, false));
                                container.style.border.width = 1;
                                container.markRenderDirty();
                            }
                            if (s.grouped_attached) updateGroupedFieldShellOutline(s, still_hovered);
                        }
                        if (s.focus_ring_host) |host| {
                            if (host.behavior.events.on_blur) |h| h.invoke();
                        }
                    }
                }.handler,
                .context = state_opaque,
            };

            // Scope 版 hover Signal
            const is_hovered = try hooks.useHover(my_scope, input_container);
            state.hover_signal = is_hovered;

            // Effect: hover 时高亮输入框边框（仅非焦点、非错误时生效）
            try my_scope.createEffect(.{
                .input_container = input_container,
                .is_hovered = is_hovered,
                .has_error = has_error,
                .state = state,
                .tokens = t,
                .embedded = p.embedded,
            }, struct {
                fn update(c: anytype) void {
                    const hovered = c.is_hovered.get();
                    if (!c.embedded and styles.hoverBorderApplies(c.state.focused, c.has_error)) {
                        c.input_container.setBorderColor(styles.borderColor(c.tokens, c.state.restingBorderColor(), hovered, false, false));
                        if (c.state.grouped_attached) updateGroupedFieldShellOutline(c.state, hovered);
                    }
                }
            }.update);

            // Focus ring（Scope 版）
            if (!p.embedded) try hooks.useFocusRing(my_scope, cx, field_shell, .{ .offset = 0 });
        }

        // 辅助文本/错误信息
        const helper_text = p.error_msg orelse p.helper;
        if (helper_text) |ht| {
            const helper_node = try box(cx, .{ .height = .{ .fit = .{} } }, .{});
            try appendInputChild(cx, wrapper, helper_node);
            var helper_txt = styles.helperTextStyle(t, has_error);
            helper_txt.content = ht;
            helper_node.setText(helper_txt);
        }

        return .{ .node = wrapper, .input_container = input_container, .state = state };
    }
};

fn appendInputChild(cx: *Cx, parent: *Node, child: *Node) !void {
    parent.appendChild(cx.allocator, child) catch |err| {
        cx.freeNode(child);
        return err;
    };
}

/// 多行文本输入（独立实现，使用 TextareaDocument + DocCursor + WrapMap）
pub const TextareaProps = textarea_mod.TextareaProps;
pub const TextareaBuilder = textarea_mod.TextareaBuilder;

pub fn Textarea(props: TextareaProps) TextareaBuilder {
    return textarea_mod.Textarea(props);
}

// ========== 测试 ==========

test "Input: basic creation" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const input_node = try Input(.{})
        .label("Email")
        .placeholder("Enter your email")
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, input_node);

    // 应该有 2 个子节点: label + input container
    try std.testing.expectEqual(@as(usize, 2), input_node.children.items.len);
}

test "Input accessibility publishes value and writable selection but password fails closed" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 160 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const plain = try Input(.{ .initial_value = "hello", .width = 200 }).mountResult(scope, ctx);
    try root.appendChild(allocator, plain.node);
    plain.state.selection_anchor = 1;
    plain.state.cursor_pos = 4;
    const editable_surface = plain.state.text_display_node.?.parent.?;
    editable_surface.meta.per_frame.hooks.before_render.main.?(editable_surface);
    const plain_a11y = plain.input_container.behavior.interaction.a11y.?;
    try std.testing.expectEqualStrings("hello", plain_a11y.value_text.?);
    try std.testing.expectEqual(@as(u32, 1), plain_a11y.editable_text.?.selection_start);
    try std.testing.expectEqual(@as(u32, 4), plain_a11y.editable_text.?.selection_end);
    try std.testing.expect(plain_a11y.editable_text.?.set_selection(
        plain_a11y.editable_text.?.context,
        0,
        2,
    ));
    try std.testing.expectEqual(@as(usize, 0), plain.state.selection_anchor.?);
    try std.testing.expectEqual(@as(usize, 2), plain.state.cursor_pos);

    const password = try Input(.{ .initial_value = "secret", .input_type = .password, .width = 200 }).mountResult(scope, ctx);
    try root.appendChild(allocator, password.node);
    const password_surface = password.state.text_display_node.?.parent.?;
    password_surface.meta.per_frame.hooks.before_render.main.?(password_surface);
    const password_a11y = password.input_container.behavior.interaction.a11y.?;
    try std.testing.expect(password_a11y.value_text == null);
    try std.testing.expect(password_a11y.editable_text == null);
}

test "TextInputState accessibility selection snaps to grapheme boundaries" {
    var state = TextInputState{};
    const value = "A👩‍💻B";
    @memcpy(state.buffer[0..value.len], value);
    state.buffer_len = value.len;
    // Start is inside the ZWJ emoji and must snap to its leading boundary;
    // end is the valid boundary immediately before B.
    try std.testing.expect(state.setAccessibilitySelection(2, @intCast(value.len - 1)));
    try std.testing.expectEqual(@as(usize, 1), state.selection_anchor.?);
    try std.testing.expectEqual(value.len - 1, state.cursor_pos);
}

test "Input: with error" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const input_node = try Input(.{})
        .label("Password")
        .errorMsg("Password is required")
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, input_node);

    // 应该有 3 个子节点: label + input + error
    try std.testing.expectEqual(@as(usize, 3), input_node.children.items.len);
}

test "Textarea: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const textarea_node = try Textarea(.{})
        .label("Description")
        .rows(4)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, textarea_node);

    try std.testing.expect(textarea_node.children.items.len >= 2);
}

test "TextInputState: insertText" {
    var state = TextInputState{};
    state.insertText("hello");
    try std.testing.expectEqualStrings("hello", state.getText());
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: deleteBackward" {
    var state = TextInputState{};
    state.insertText("hello");
    state.deleteBackward();
    try std.testing.expectEqualStrings("hell", state.getText());
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
}

test "TextInputState: cursor navigation" {
    var state = TextInputState{};
    state.insertText("hello");
    state.moveCursor(-2, false);
    try std.testing.expectEqual(@as(usize, 3), state.cursor_pos);
    state.moveCursor(1, false);
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    state.moveToStart();
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
    state.moveToEnd();
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "Input: Group first should propagate per-corner and avoid uniform clip cut" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const group_mod = @import("../group/mod.zig");
    const grp = try group_mod.Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, grp.container);

    const mounted = try Input(.{
        .initial_value = "example.com/page",
        .width = 240,
        .leading_icon_asset = svg_assets.common.link,
    }).mountResult(scope, ctx);
    try group_mod.addGroupItem(grp.container, alloc, mounted.node, .first, 8);

    if (mounted.node.meta.per_frame.hooks.before_render.main) |hook| {
        hook(mounted.node);
    }

    const r = mounted.input_container.style.effectiveRadii();
    try std.testing.expectApproxEqAbs(@as(f32, 8), r[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), r[3], 0.001);
    try std.testing.expect(!mounted.input_container.style.overflow_hidden);
}

test "Input: grouped wrapper propagates trailing seam border side colors to field" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const group_mod = @import("../group/mod.zig");
    const grp = try group_mod.Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, grp.container);

    const mounted = try Input(.{
        .initial_value = "example.com/page",
        .width = 240,
        .leading_icon_asset = svg_assets.common.link,
    }).mountResult(scope, ctx);
    try group_mod.addGroupItem(grp.container, alloc, mounted.node, .first, 8);

    if (mounted.node.meta.per_frame.hooks.before_render.main) |hook| {
        hook(mounted.node);
    }

    try std.testing.expect(mounted.input_container.style.border_side_colors() != null);
    try std.testing.expect(Color.eql(
        mounted.input_container.style.border_side_colors().?.right.?,
        Color.TRANSPARENT,
    ));
    try std.testing.expectEqual(@as(i32, 0), mounted.input_container.style.z_index());
}

test "Input: grouped focus shows outline on field shell" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const group_mod = @import("../group/mod.zig");
    const grp = try group_mod.Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, grp.container);

    const mounted = try Input(.{
        .initial_value = "example.com/page",
        .width = 240,
        .leading_icon_asset = svg_assets.common.link,
    }).mountResult(scope, ctx);
    try group_mod.addGroupItem(grp.container, alloc, mounted.node, .first, 8);

    if (mounted.node.meta.per_frame.hooks.before_render.main) |hook| hook(mounted.node);

    const state: *TextInputState = @ptrCast(@alignCast(mounted.input_container.behavior.events.event_context.?));
    try std.testing.expect(state.grouped_attached);
    try std.testing.expect(state.focus_ring_host != null);
    try std.testing.expectEqual(@as(i32, 0), mounted.input_container.style.z_index());
    try std.testing.expect(state.focus_ring_host.?.style.outline() == null);

    if (mounted.input_container.behavior.events.on_focus) |handler| handler.invoke();
    try std.testing.expectEqual(@as(i32, 0), mounted.input_container.style.z_index());
    try std.testing.expectEqual(@as(i32, 1), state.focus_ring_host.?.style.z_index());
    try std.testing.expect(state.focus_ring_host.?.style.outline() != null);

    if (mounted.input_container.behavior.events.on_blur) |handler| handler.invoke();
    try std.testing.expectEqual(@as(i32, 0), state.focus_ring_host.?.style.z_index());
    try std.testing.expect(state.focus_ring_host.?.style.outline() == null);
}

test "Input: grouped hover shows outline on field shell" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const group_mod = @import("../group/mod.zig");
    const grp = try group_mod.Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, grp.container);

    const mounted = try Input(.{
        .initial_value = "example.com/page",
        .width = 240,
        .leading_icon_asset = svg_assets.common.link,
    }).mountResult(scope, ctx);
    try group_mod.addGroupItem(grp.container, alloc, mounted.node, .first, 8);

    if (mounted.node.meta.per_frame.hooks.before_render.main) |hook| hook(mounted.node);

    const state: *TextInputState = @ptrCast(@alignCast(mounted.input_container.behavior.events.event_context.?));
    try std.testing.expect(state.hover_signal != null);
    try std.testing.expect(state.focus_ring_host != null);
    try std.testing.expect(state.focus_ring_host.?.style.outline() == null);

    state.hover_signal.?.set(true);
    try std.testing.expectEqual(@as(i32, 1), state.focus_ring_host.?.style.z_index());
    try std.testing.expect(state.focus_ring_host.?.style.outline() != null);

    state.hover_signal.?.set(false);
    try std.testing.expectEqual(@as(i32, 0), state.focus_ring_host.?.style.z_index());
    try std.testing.expect(state.focus_ring_host.?.style.outline() == null);
}

test "TextInputState: insert in middle" {
    var state = TextInputState{};
    state.insertText("helo");
    state.moveCursor(-1, false); // cursor at 'o'
    state.insertText("l");
    try std.testing.expectEqualStrings("hello", state.getText());
}

test "TextInputState: selectAll + delete" {
    var state = TextInputState{};
    state.insertText("hello");
    state.selectAll();
    state.deleteBackward();
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}

test "TextInputState: handleKeyDown" {
    var state = TextInputState{};
    state.insertText("test");
    // Left arrow
    try std.testing.expect(state.handleKeyDown(.left, .{}));
    try std.testing.expectEqual(@as(usize, 3), state.cursor_pos);
    // Shift+Left should extend selection
    try std.testing.expect(state.handleKeyDown(.left, .{ .shift = true }));
    try std.testing.expectEqual(@as(?usize, 3), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 2), state.cursor_pos);
    // Cmd+A
    try std.testing.expect(state.handleKeyDown(.a, .{ .super = true }));
    try std.testing.expectEqual(@as(?usize, 0), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    // Backspace deletes selection
    try std.testing.expect(state.handleKeyDown(.delete, .{}));
    try std.testing.expectEqualStrings("", state.getText());
}

test "Input: event handler responds to text_input" {
    const result = events_mod.inputEventHandler(
        Event{ .text_input = .{ .text = "a" } },
        null,
    );
    // null context should return ignored
    try std.testing.expectEqual(EventResult.ignored, result);
}

test "Input: render emits field border and value text" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(360, 120);

    const root = try box(ctx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 120 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const input_node = try Input(.{
        .initial_value = "hello@example.com",
        .width = 280,
        .leading_icon_asset = svg_assets.common.search,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, input_node);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_border = false;
    var saw_text = false;
    for (commands) |cmd| if (cmd.isStrokeRect()) {
        const b = cmd;
        if (b.geom.w >= 200 and b.geom.h >= 24 and b.stroke_width >= 1) {
            saw_border = true;
        }
    } else if (cmd.isText()) {
        const tcmd = cmd;
        if (std.mem.eql(u8, tcmd.text_content, "hello@example.com")) saw_text = true;
    };

    try std.testing.expect(saw_border);
    try std.testing.expect(saw_text);
}

test "Input: double click selects word on mouse_down" {
    var state = TextInputState{};
    state.insertText("hello world");
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .mouse_down = .{ .x = 0, .y = 0 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .mouse_up = .{ .x = 0, .y = 0 } }, ctx_ptr);
    // 第二次按下立刻触发选词（不等 click/mouse_up）
    _ = events_mod.inputEventHandler(Event{ .mouse_down = .{ .x = 0, .y = 0 } }, ctx_ptr);
    try std.testing.expect(state.selection_anchor != null);
    try std.testing.expectEqual(@as(usize, 0), state.selection_anchor.?);
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: ime preedit state update" {
    var state = TextInputState{};
    state.char_width = 8;
    state.font_size = 13;
    state.handleImePreeditEvent("ni", 1);
    try std.testing.expect(state.hasImePreedit());
    try std.testing.expect(state.imeIsComposing());
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
    try std.testing.expectEqual(@as(usize, 2), state.ime_preedit_len);
    try std.testing.expectEqual(@as(usize, 1), state.ime_cursor_utf8_offset);
    try std.testing.expect(state.imePreeditAdvance() > 0);
    try std.testing.expectEqual(@as(f32, 0), state.imePreeditStartAdvance());
    state.handleImePreeditEvent("", 0);
    try std.testing.expect(!state.hasImePreedit());
    try std.testing.expect(!state.imeIsComposing());
}

test "Input: ime_commit inserts text once" {
    var state = TextInputState{};
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "abc" } }, ctx_ptr);
    try std.testing.expectEqualStrings("abc", state.getText());
}

test "Input: ime_commit should replace selected text instead of appending" {
    var state = TextInputState{};
    state.insertText("hello");
    state.selectAll();
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "你", .cursor_utf8_offset = 3 } }, ctx_ptr);
    try std.testing.expectEqualStrings("你", state.buildDisplayText(null));
    try std.testing.expectEqualStrings("hello", state.getText());
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "你" } }, ctx_ptr);
    try std.testing.expectEqualStrings("你", state.getText());
}

test "Input: implicit IME selection replacement updates cancels and commits in both directions" {
    for ([_]bool{ false, true }) |backward| {
        var state = TextInputState{};
        defer state.deinit();
        state.insertText("a中文Englishz");
        state.cursor_pos = if (backward) 1 else state.getText().len - 1;
        state.selection_anchor = if (backward) state.getText().len - 1 else 1;
        const cursor = state.cursor_pos;
        const anchor = state.selection_anchor;
        const ctx_ptr: ?*anyopaque = @ptrCast(&state);
        for ([_][]const u8{ "d", "df", "夺" }) |candidate| {
            _ = events_mod.inputEventHandler(.{ .ime_preedit = .{ .text = candidate, .cursor_utf8_offset = @intCast(candidate.len) } }, ctx_ptr);
            var expected: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "a{s}z", .{candidate}), state.buildDisplayText(null));
            try std.testing.expectEqualStrings("a中文Englishz", state.getText());
            try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
        }
        _ = events_mod.inputEventHandler(.{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } }, ctx_ptr);
        try std.testing.expectEqual(cursor, state.cursor_pos);
        try std.testing.expectEqual(anchor, state.selection_anchor);
        try std.testing.expectEqualStrings("a中文Englishz", state.buildDisplayText(null));
        state.handleImePreeditEvent("夺", 3);
        state.handleImeCommitEvent("夺");
        try std.testing.expectEqualStrings("a夺z", state.getText());
        state.undo();
        try std.testing.expectEqualStrings("a中文Englishz", state.getText());
    }
}

test "Input: ime_commit with replacementRange revises committed text" {
    // 日文再変換：IME 用 replacementRange 修订已提交文本。
    var state = TextInputState{};
    state.insertText("こんにちは"); // 15 bytes
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{
        .text = "今日は",
        .replace_start_utf8 = 0,
        .replace_end_utf8 = 15,
    } }, ctx_ptr);
    try std.testing.expectEqualStrings("今日は", state.getText());
    try std.testing.expectEqual(@as(usize, 9), state.cursor_pos);
}

test "Input: ime_commit replacementRange sentinel keeps insert-at-cursor behavior" {
    var state = TextInputState{};
    state.insertText("ab");
    state.cursor_pos = 1;
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "x" } }, ctx_ptr);
    try std.testing.expectEqualStrings("axb", state.getText());
}

test "Input: ime replacementRange rejects stale out-of-bounds range" {
    // 桥接层区间可能基于过期文本：越界必须整体拒绝，退化为现行为。
    var state = TextInputState{};
    state.insertText("ab");
    try std.testing.expect(!state.applyImeReplacementRange(0, 99));
    try std.testing.expect(!state.applyImeReplacementRange(3, 2));
    try std.testing.expect(!state.applyImeReplacementRange(
        events.ime_no_replacement,
        events.ime_no_replacement,
    ));
    // 现行为不受影响
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{
        .text = "c",
        .replace_start_utf8 = 0,
        .replace_end_utf8 = 99,
    } }, @ptrCast(&state));
    try std.testing.expectEqualStrings("abc", state.getText());
}

test "Input: ime_preedit with replacementRange pulls committed text back into composition" {
    // 再変換只替换显示；已提交文档与 undo 在 commit 前保持完整。
    var state = TextInputState{};
    state.insertText("x漢字y"); // "漢字" = bytes [1,7)
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{
        .text = "かんじ",
        .cursor_utf8_offset = 9,
        .replace_start_utf8 = 1,
        .replace_end_utf8 = 7,
    } }, ctx_ptr);
    try std.testing.expectEqualStrings("x漢字y", state.getText());
    try std.testing.expectEqualStrings("xかんじy", state.buildDisplayText(null));
    try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
    try std.testing.expect(state.hasImePreedit());
    try std.testing.expect(state.imeIsComposing());
}

test "Input: ime_commit empty text with replacementRange deletes range" {
    var state = TextInputState{};
    state.insertText("abcd");
    state.handleImeCommitReplaceEvent("", 1, 3);
    try std.testing.expectEqualStrings("ad", state.getText());
    try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
}

test "Input: ime composing ignores selection-space text_input" {
    var state = TextInputState{};
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "に", .cursor_utf8_offset = 1 } }, ctx_ptr);
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = " " } }, ctx_ptr);
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expect(state.hasImePreedit());
    try std.testing.expect(state.imeIsComposing());
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
}

test "Input: ime composing marks highlight on key_down space" {
    var state = TextInputState{};
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "しゅる", .cursor_utf8_offset = 6 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .key_down = .{ .key = .space, .modifiers = .{} } }, ctx_ptr);
    try std.testing.expect(state.imeIsComposing());
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
    try std.testing.expectEqualStrings("", state.getText());
}

test "TextInputState: ime highlight keeps cursor at preedit end when offset is zero" {
    var state = TextInputState{};
    state.handleImePreeditEvent("しゅる", 0);
    state.markImeSelectionHighlight();
    try std.testing.expectEqual(@as(usize, 9), state.effectiveImeCursorOffset());
    try std.testing.expect(state.visualCursorAdvance() > 0);
}

test "Input: ime composing fallback text_input commits once" {
    var state = TextInputState{};
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "に", .cursor_utf8_offset = 1 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = " " } }, ctx_ptr);
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = "に" } }, ctx_ptr);
    try std.testing.expectEqualStrings("に", state.getText());
    try std.testing.expect(!state.hasImePreedit());
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
}

test "Input: ime fallback text_input should replace selected text instead of appending" {
    var state = TextInputState{};
    state.insertText("hello");
    state.selectAll();
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "に", .cursor_utf8_offset = 1 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = "に" } }, ctx_ptr);
    try std.testing.expectEqualStrings("に", state.getText());
}

test "TextInputState: ime preedit start advance follows cursor" {
    var state = TextInputState{};
    state.char_width = 8;
    state.font_size = 13;
    state.insertText("ab");
    state.handleImePreeditEvent("に", 1);
    try std.testing.expect(state.imePreeditStartAdvance() > 0);
}

test "TextInputState: wrap display segment can fuse ime preedit text" {
    var doc = state_mod.TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText("abcd");

    var wrap = state_mod.TextareaWrapMap.init(std.testing.allocator);
    defer wrap.deinit();

    var state = TextInputState{};
    state.multiline = true;
    state.textarea_doc = &doc;
    state.textarea_wrap = &wrap;
    state.cursor_pos = 2;

    const ni = "\xe4\xbd\xa0";
    state.handleImePreeditEvent(ni, @as(u32, @intCast(ni.len)));
    const insert_off = state.imeInsertOffsetForDisplaySegment(&doc, 0, 0, 4) orelse unreachable;
    const fused = state.composeDisplaySegmentWithIme("abcd", insert_off);
    try std.testing.expect(std.mem.eql(u8, fused, "ab" ++ ni ++ "cd"));
}

test "Input: ime_commit dedupes same text_input" {
    var state = TextInputState{};
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "한" } }, ctx_ptr);
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = "한" } }, ctx_ptr);
    try std.testing.expectEqualStrings("한", state.getText());
}

test "TextInputState: cancelImeComposition clears selection highlight" {
    var state = TextInputState{};
    state.handleImePreeditEvent("に", 1);
    state.markImeSelectionHighlight();
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
    state.cancelImeComposition();
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
}

test "Input: allow space immediately after ime_commit" {
    var state = TextInputState{};
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "我" } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = " " } }, ctx_ptr);
    try std.testing.expectEqualStrings("我 ", state.getText());
}

test "TextInputState: utf8 visual cursor uses codepoint count" {
    var state = TextInputState{};
    state.insertText("我a");
    // buffer bytes = 4, codepoints = 2
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    // display units: "我"=2, "a"=1
    try std.testing.expectEqual(@as(usize, 3), state.visualCursorPos());
    try std.testing.expectEqual(@as(usize, 2), state.displayedTextLen());
}

test "TextInputState: hitTestCursorPos maps visual column to utf8 byte offset" {
    var state = TextInputState{};
    state.insertText("我a");
    state.container_x = 0;
    state.padding_h = 8.0;
    state.scroll_x = 0;
    state.char_width = 8.0;
    // Visual unit 2 (after full-width '我') maps to utf8 byte offset 3
    const pos = state.hitTestCursorPos(24.0); // 8 (padding) + 8 * 2
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "TextInputState: deleteForward" {
    var state = TextInputState{};
    state.insertText("hello");
    state.moveToStart();
    state.deleteForward();
    try std.testing.expectEqualStrings("ello", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}

test "sanitizeInputText: filters escape sequences" {
    var state = TextInputState{};
    state.input_type = .text;
    state.multiline = false;
    var buf: [256]u8 = undefined;
    const filtered = state_mod.sanitizeInputText(&state, "\x1b[D", buf[0..]);
    try std.testing.expectEqual(@as(usize, 0), filtered.len);
}

test "sanitizeInputText: newline is gated by accept_newline" {
    var state = TextInputState{};
    state.input_type = .text;
    state.accept_newline = false;
    var buf: [256]u8 = undefined;
    const single_line = state_mod.sanitizeInputText(&state, "a\nb\r\nc", buf[0..]);
    try std.testing.expectEqualStrings("abc", single_line);
    state.accept_newline = true;
    const multi_line = state_mod.sanitizeInputText(&state, "a\nb\r\nc", buf[0..]);
    try std.testing.expectEqualStrings("a\nb\nc", multi_line);
}

test "TextInputState: soft wrap follows behavior config" {
    var state = TextInputState{};
    state.multiline = true;
    state.soft_wrap = false;
    state.input_inner_w = 120;
    try std.testing.expect(!state.shouldSoftWrap());
    state.soft_wrap = true;
    try std.testing.expect(state.shouldSoftWrap());
    state.input_inner_w = 0;
    try std.testing.expect(!state.shouldSoftWrap());
}

test "TextInputState: findWordBoundaryLeft" {
    var state = TextInputState{};
    state.insertText("hello world foo");
    try std.testing.expectEqual(@as(usize, 12), state.findWordBoundaryLeft(15));
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryLeft(11));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(5));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(0));
}

test "TextInputState: findWordBoundaryRight" {
    var state = TextInputState{};
    state.insertText("hello world foo");
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryRight(0));
    try std.testing.expectEqual(@as(usize, 12), state.findWordBoundaryRight(6));
    try std.testing.expectEqual(@as(usize, 15), state.findWordBoundaryRight(12));
}

test "TextInputState: CJK findWordBoundaryLeft" {
    var state = TextInputState{};
    state.insertText("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c");
    try std.testing.expectEqual(@as(usize, 9), state.findWordBoundaryLeft(12));
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryLeft(9));
    try std.testing.expectEqual(@as(usize, 3), state.findWordBoundaryLeft(6));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(3));
}

test "TextInputState: CJK findWordBoundaryRight" {
    var state = TextInputState{};
    state.insertText("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c");
    try std.testing.expectEqual(@as(usize, 3), state.findWordBoundaryRight(0));
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryRight(3));
    try std.testing.expectEqual(@as(usize, 9), state.findWordBoundaryRight(6));
    try std.testing.expectEqual(@as(usize, 12), state.findWordBoundaryRight(9));
}

test "TextInputState: CJK selectWordAt" {
    var state = TextInputState{};
    state.insertText("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c");
    state.selectWordAt(3);
    try std.testing.expectEqual(@as(usize, 3), state.selection_anchor.?);
    try std.testing.expectEqual(@as(usize, 6), state.cursor_pos);
}

test "TextInputState: mixed CJK/ASCII word boundary" {
    var state = TextInputState{};
    state.insertText("hello\xe4\xbd\xa0\xe5\xa5\xbd world");
    try std.testing.expectEqual(@as(usize, 5), state.findWordBoundaryLeft(8));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(5));
}

test "TextInputState: selection collapse on left arrow" {
    var state = TextInputState{};
    state.insertText("hello");
    state.selection_anchor = 1;
    state.cursor_pos = 4;
    _ = state.handleKeyDown(.left, .{});
    try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: selection collapse on right arrow" {
    var state = TextInputState{};
    state.insertText("hello");
    state.selection_anchor = 1;
    state.cursor_pos = 4;
    _ = state.handleKeyDown(.right, .{});
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: Alt+Backspace deletes word" {
    var state = TextInputState{};
    state.insertText("hello world");
    _ = state.handleKeyDown(.delete, .{ .alt = true });
    try std.testing.expectEqualStrings("hello ", state.getText());
}

test "TextInputState: Cmd+Backspace deletes to line start" {
    var state = TextInputState{};
    state.insertText("hello world");
    state.cursor_pos = 7;
    _ = state.handleKeyDown(.delete, .{ .super = true });
    try std.testing.expectEqualStrings("orld", state.getText());
}

test "TextInputState: Alt+Right moves by word" {
    var state = TextInputState{};
    state.insertText("hello world foo");
    state.cursor_pos = 0;
    _ = state.handleKeyDown(.right, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 6), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: Alt+Left moves by word" {
    var state = TextInputState{};
    state.insertText("hello world foo");
    _ = state.handleKeyDown(.left, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 12), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: selectWordAt" {
    var state = TextInputState{};
    state.insertText("hello world");
    state.selectWordAt(3);
    try std.testing.expectEqual(@as(?usize, 0), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: undo single insert" {
    var state = TextInputState{};
    state.insertText("hello");
    try std.testing.expectEqualStrings("hello", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}

test "TextInputState: undo then redo" {
    var state = TextInputState{};
    state.insertText("hello");
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
    state.redo();
    try std.testing.expectEqualStrings("hello", state.getText());
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: undo delete" {
    var state = TextInputState{};
    state.insertText("hello");
    state.deleteBackward();
    try std.testing.expectEqualStrings("hell", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("hello", state.getText());
}

test "TextInputState: new operation clears redo" {
    var state = TextInputState{};
    state.insertText("hello");
    state.undo();
    try std.testing.expectEqual(@as(u8, 1), state.redo_count);
    state.insertText("world");
    try std.testing.expectEqual(@as(u8, 0), state.redo_count);
}

test "TextInputState: multiple undo — 连续输入合并成一个单元" {
    var state = TextInputState{};
    // 连打三个字符（无光标跳转、无停顿、无边界字符）→ 合并为一步
    state.insertText("a");
    state.insertText("b");
    state.insertText("c");
    try std.testing.expectEqualStrings("abc", state.getText());
    try std.testing.expectEqual(@as(u8, 1), state.undo_count);
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "undo 合并：光标跳转断开输入单元" {
    var state = TextInputState{};
    state.insertText("ab");
    // 光标跳到开头（模拟点击/Home），下一次输入必须开新单元
    state.cursor_pos = 0;
    state.insertText("X");
    try std.testing.expectEqualStrings("Xab", state.getText());
    try std.testing.expectEqual(@as(u8, 2), state.undo_count);
    state.undo();
    try std.testing.expectEqualStrings("ab", state.getText());
}

test "undo 合并：空格/换行是硬边界" {
    var state = TextInputState{};
    state.insertText("hello");
    state.insertText(" "); // 边界字符自成一步
    state.insertText("world");
    try std.testing.expectEqualStrings("hello world", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("hello ", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("hello", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "undo 合并：插入与退格是不同种类，互不合并" {
    var state = TextInputState{};
    state.insertText("abc");
    state.deleteBackward();
    state.deleteBackward();
    try std.testing.expectEqualStrings("a", state.getText());
    // 两次退格合并成一步，撤销后回到 "abc"
    state.undo();
    try std.testing.expectEqualStrings("abc", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "undo 合并：超时后断开（idle 阈值）" {
    var state = TextInputState{};
    state.insertText("ab");
    // 手工把合并锚点时间戳作废 = 模拟停顿超过 idle 阈值
    state.undo_coalesce_at = null;
    state.insertText("cd");
    try std.testing.expectEqual(@as(u8, 2), state.undo_count);
    state.undo();
    try std.testing.expectEqualStrings("ab", state.getText());
}

test "undo 合并：栈深提高后能容纳更长历史" {
    var state = TextInputState{};
    try std.testing.expectEqual(@as(usize, 64), TextInputState.UNDO_CAPACITY);
    // 每个 "w" + 分隔空格 = 2 个 undo 单元；30 个词 = 60 单元，仍在 64 栈深内。
    // 旧的 32 栈深会丢掉最早的一多半历史，撤不回空文本。
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        state.insertText("w");
        state.insertText(" ");
    }
    try std.testing.expectEqual(@as(u8, 60), state.undo_count);
    // 一路撤销回空文本
    var guard: usize = 0;
    while (state.buffer_len > 0 and guard < 200) : (guard += 1) state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "TextInputState: getSelectedText" {
    var state = TextInputState{};
    state.insertText("hello world");
    state.selection_anchor = 0;
    state.cursor_pos = 5;
    const sel = state.getSelectedText();
    try std.testing.expect(sel != null);
    try std.testing.expectEqualStrings("hello", sel.?);
    state.selection_anchor = null;
    try std.testing.expectEqual(@as(?[]const u8, null), state.getSelectedText());
}

test "TextInputState: Cmd+Z undo via handleKeyDown" {
    var state = TextInputState{};
    state.insertText("hello");
    try std.testing.expectEqualStrings("hello", state.getText());
    _ = state.handleKeyDown(.z, .{ .super = true });
    try std.testing.expectEqualStrings("", state.getText());
    _ = state.handleKeyDown(.z, .{ .super = true, .shift = true });
    try std.testing.expectEqualStrings("hello", state.getText());
}

test "Textarea: multiline text input inserts and sets dirty" {
    var state = TextInputState{};
    state.multiline = true;
    state.accept_newline = true;
    state.insertText("line1");
    try std.testing.expectEqualStrings("line1", state.getText());
    try std.testing.expect(state.dirty);
    state.dirty = false;
    state.insertText("\nline2");
    try std.testing.expectEqualStrings("line1\nline2", state.getText());
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(usize, 11), state.cursor_pos);
}

test "Textarea: enter key inserts newline via sanitize" {
    var state = TextInputState{};
    state.input_type = .text;
    state.accept_newline = true;
    var buf: [256]u8 = undefined;
    // accept_newline=true 时，\n 保留
    const result = state_mod.sanitizeInputText(&state, "hello\nworld", buf[0..]);
    try std.testing.expectEqualStrings("hello\nworld", result);
    // accept_newline=false 时，\n 被过滤
    state.accept_newline = false;
    const result2 = state_mod.sanitizeInputText(&state, "hello\nworld", buf[0..]);
    try std.testing.expectEqualStrings("helloworld", result2);
}

test "Textarea: multiline cursor navigation across lines" {
    var state = TextInputState{};
    state.multiline = true;
    state.accept_newline = true;
    state.insertText("abc\ndef\nghi");
    // 光标在末尾 (位置 11)
    try std.testing.expectEqual(@as(usize, 11), state.cursor_pos);
    // 移到行首
    state.moveToStart();
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
    // 移到行尾
    state.moveToEnd();
    try std.testing.expectEqual(@as(usize, 11), state.cursor_pos);
    // 从末尾向左移 3 步到 "ghi" 的 'g'
    state.moveCursor(-3, false);
    try std.testing.expectEqual(@as(usize, 8), state.cursor_pos);
}

test "Textarea: auxiliary nodes have zero rect by default" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const textarea_node = try Textarea(.{})
        .label("Test")
        .rows(4)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, textarea_node);

    // Textarea 的 wrapper 第二个子节点是 field_shell，其子节点 textarea 是内容容器
    // textarea 容器包含 VirtualList container + overlay
    // overlay 中的辅助节点（selection/cursor/preedit_underline）rect 应该为 0
    const field_shell = textarea_node.children.items[1]; // field_shell
    const textarea = field_shell.children.items[0]; // textarea box
    // textarea 应该有 2 个子节点: VirtualList container + overlay
    try std.testing.expect(textarea.children.items.len >= 2);
    // overlay 是最后一个子节点
    const overlay = textarea.children.items[textarea.children.items.len - 1];
    for (overlay.children.items) |child| {
        // 辅助节点初始 rect 宽高都是 0
        try std.testing.expectEqual(@as(f32, 0), child.rectFromWorldOrFallback().w);
        try std.testing.expectEqual(@as(f32, 0), child.rectFromWorldOrFallback().h);
    }
}

// ── 单行 Input 程序化写入 / 容量 / UTF-8 边界（2026-07-31 审查修复）──

test "Input.setText: 程序化替换内容（此前完全不可能）" {
    var state = TextInputState{};
    state.insertText("old");
    try std.testing.expectEqualStrings("old", state.getText());

    // 表单从网络加载：首帧之后填值。修复前无任何 API 可做到这件事。
    const n = state.setText("loaded from network");
    try std.testing.expectEqual(@as(usize, 19), n);
    try std.testing.expectEqualStrings("loaded from network", state.getText());
    // 光标落到末尾、选区清空
    try std.testing.expectEqual(@as(usize, 19), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);

    // 提交后清空表单
    state.clearText();
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);

    // setText 可撤销
    _ = state.handleKeyDown(.z, .{ .super = true });
    try std.testing.expectEqualStrings("loaded from network", state.getText());
}

test "Input: 容量上限支持超过旧 256 字节" {
    var state = TextInputState{};
    // 300 字节的路径 —— 旧的 256B buffer 装不下
    var long: [300]u8 = undefined;
    @memset(&long, 'x');
    const n = state.setText(&long);
    try std.testing.expectEqual(@as(usize, 300), n);
    try std.testing.expectEqual(@as(usize, 300), state.getText().len);
}

test "Input: 超限截断落在 UTF-8 边界上，不产生半个字符" {
    var state = TextInputState{};

    // 构造超过 MAX_INPUT_BYTES 的纯 CJK（每字符 3 字节）
    const cap = editable_block.MAX_INPUT_BYTES;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    while (buf.items.len < cap + 60) {
        try buf.appendSlice(std.testing.allocator, "中");
    }

    const n = state.setText(buf.items);
    try std.testing.expect(n <= cap);
    // 关键断言：写入内容必须是合法 UTF-8（修复前会切出半个字符）
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.getText()));
    // 3 字节字符，截断长度必是 3 的倍数
    try std.testing.expectEqual(@as(usize, 0), n % 3);

    // insertText 路径同样要守边界
    var s2 = TextInputState{};
    _ = s2.setText("");
    var i: usize = 0;
    while (i < cap + 60) : (i += 3) s2.insertText("中");
    try std.testing.expect(std.unicode.utf8ValidateSlice(s2.getText()));
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

test "mounted input reconversion cancels before commands blur and explicit replacement" {
    const t = std.testing;
    inline for (.{ false, true }) |independent| {
        var cx = try Cx.init(t.allocator);
        defer cx.deinit();
        const root = try box(cx, .{ .width = .{ .px = 520 }, .height = .{ .px = 200 } }, .{});
        cx.root = root;
        const scope = try Scope.init(t.allocator, null, cx.owner);
        defer scope.dispose();
        const ta = @import("textarea.zig");
        const mounted = if (independent) try ta.Textarea(.{ .value = "x漢字y" }).mountWithState(scope, cx) else try Input(.{ .initial_value = "x漢字y" }).mountResult(scope, cx);
        try root.appendChild(t.allocator, if (independent) mounted.wrapper else mounted.node);
        const input = if (independent) mounted.input else mounted.input_container;
        const state = if (independent) mounted.state else @as(*TextInputState, @ptrCast(@alignCast(input.behavior.events.event_context.?)));
        const handler = if (independent) ta.textareaEventHandler else events_mod.inputEventHandler;
        if (independent) {
            state.cursor.offset = 8;
            state.cursor.anchor = 7;
        } else {
            state.cursor_pos = 8;
            state.selection_anchor = 7;
        }
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        _ = handler(.{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } }, state);
        try t.expect(state.ime_replacement == null);
        try t.expectEqualStrings("x漢字y", state.getSelectedText().?);
        if (independent) {
            state.cursor.offset = 8;
            state.cursor.anchor = 7;
        } else {
            state.cursor_pos = 8;
            state.selection_anchor = 7;
        }
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        _ = handler(.{ .key_down = .{ .key = .escape } }, state);
        try t.expectEqual(@as(usize, 8), if (independent) state.cursor.offset else state.cursor_pos);
        try t.expectEqual(@as(?usize, 7), if (independent) state.cursor.anchor else state.selection_anchor);
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        input.behavior.events.on_blur.?.invoke();
        try t.expectEqualStrings("x漢字y", state.getText());
        try t.expectEqual(@as(?usize, null), if (independent) state.cursor.anchor else state.selection_anchor);
        try t.expect(!state.imeIsComposing());
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        if (independent) try t.expect(state.setAccessibilityValue("done")) else _ = try state.setTextChecked("done");
        try t.expect(!state.imeIsComposing());
        try t.expect(state.ime_replacement == null);
        try t.expectEqualStrings("done", state.getText());
        state.undo();
        try t.expectEqualStrings("x漢字y", state.getText());
    }
}

// devtools mountPanel sweep 在 Input 内部抓到泄漏，而的夹具是 `Input(.{})`——
// 没走 leading_icon / placeholder / helper 分支（夹具决定覆盖面）。补一条带齐分支的 sweep。
test "Input: 带 leading_icon / placeholder / helper 的 mountResult 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("input(icon+helper)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Input(.{
                .placeholder = "Filter (tag, #id)...",
                .size = .sm,
                .leading_icon_asset = svg_assets.common.search,
                .helper = "helper",
            }).mountResult(scope, cx);
            return r.node;
        }
    }.m);
}

test "Input: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("input", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Input(.{}).mount(scope, cx);
        }
    }.m);
}

test "Input centers its text line for every control size and field height" {
    for ([_]InputSize{ .xs, .sm, .md, .lg }) |size| {
        var cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        cx.setViewport(500, 200);
        const scope = try Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        const input = try Input(.{ .size = size, .width = 240, .placeholder = "https://" }).mountResult(scope, cx);
        cx.root = input.node;
        for (0..2) |frame| {
            if (frame == 1) {
                input.input_container.style.height = .{ .px = 56 };
                input.input_container.markLayoutDirty();
                _ = try input.state.setTextChecked("example.com");
            }
            cx.layout();
            _ = cx.render();
            cx.layout();
            _ = cx.render();
            const line = input.state.text_display_node.?.globalRect();
            const field = input.input_container.globalRect();
            try std.testing.expect(line.h > 0);
            try std.testing.expectApproxEqAbs(field.y + field.h / 2, line.y + line.h / 2, 0.01);
            const surface = input.state.text_display_node.?.parent.?;
            const local_line = input.state.text_display_node.?.rectFromWorldOrFallback();
            try std.testing.expectApproxEqAbs((surface.rectFromWorldOrFallback().h - line.h) / 2, local_line.y, 0.01);
        }
    }
}

test "growable Input initial display owns text across storage growth" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const allocator = failing.allocator();
    var cx = try Cx.init(allocator);
    defer cx.deinit();
    const root = try box(cx, .{}, .{});
    cx.root = root;
    const scope = try Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const initial = "界" ** 1000;
    const mounted = try Input(.{ .initial_value = initial, .growable = true }).mountResult(scope, cx);
    try root.appendChild(allocator, mounted.node);
    try t.expectEqualStrings(initial, mounted.state.getText());
    const node = mounted.state.text_display_node.?;
    try t.expect(node.getText().?.owned);
    const rendered = node.getText().?.content;
    try t.expect(rendered.ptr != mounted.state.getText().ptr);
    _ = try mounted.state.setTextChecked("a" ** 9000);
    // Before a display refresh (which may itself fail), old pixels own bytes.
    try t.expectEqualStrings(initial, rendered);
    failing.fail_index = failing.alloc_index;
    try t.expect(!mounted.state.syncDisplayTextContent());
    try t.expect(failing.has_induced_failure);
    try t.expect(node.getText().?.owned);
    try t.expectEqualStrings(initial, node.getText().?.content);
    failing.fail_index = std.math.maxInt(usize);
    try t.expect(mounted.state.syncDisplayTextContent());
    try t.expect(node.getText().?.owned);
    try t.expectEqualStrings("a" ** 9000, node.getText().?.content);
}

test "Input: 聚焦时先 dispose scope 再摘节点，blur 不碰已释放的 state" {
    // Notifier 回复框发送后原地换内容：先 dispose 内容 scope（释放 TextInputState），
    // 再 detachChildRetained → invalidateReferencesTo → clearFocus → on_blur(state)。
    // 真 app 里 SIGSEGV 在 HandlerRef.invoke。
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const parent_scope = try Scope.init(alloc, null, ctx.owner);
    defer parent_scope.dispose();
    const content_scope = try parent_scope.childScope();

    const mounted = try Input(.{ .initial_value = "hi" }).mountResult(content_scope, ctx);
    try root.appendChild(alloc, mounted.node);
    ctx.focus_manager.setFocus(mounted.input_container);
    try std.testing.expect(ctx.focus_manager.getFocused() == mounted.input_container);

    content_scope.dispose();
    core.clearNodeScopes(mounted.node);
    ctx.detachChildRetained(root, mounted.node);
    ctx.freeNode(mounted.node);
    try std.testing.expect(ctx.focus_manager.getFocused() == null);
}
