/// Button Component
///
/// 基于 ControlShell 统一基底的按钮组件
///
/// 特性:
/// - variant: primary, secondary, ghost, danger, link
/// - size: sm, md, lg (ControlSize)
/// - icon: 图标按钮
/// - loading: 加载状态
/// - disabled: 禁用状态
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Style = core.Style;
const Color = core.Color;
const Scope = core.Scope;
const StyleOverride = core.StyleOverride;
const GenericEventCallback = core.GenericEventCallback;
const hooks = @import("../../hooks.zig");
const spinner_mod = @import("../spinner/mod.zig");
const control_shell = @import("../control_shell/mod.zig");
const svg_assets = @import("../../svg_assets.zig");
const controlShell = control_shell.controlShell;

/// 按钮变体，别名到 ControlVariant（兼容）
pub const ButtonVariant = control_shell.ControlVariant;

/// 按钮尺寸，别名到 ControlSize（兼容）
pub const ButtonSize = control_shell.ControlSize;

/// 按钮属性
pub const ButtonProps = struct {
    /// 标签文本
    label: ?[]const u8 = null,
    /// 变体
    variant: ButtonVariant = .primary,
    /// 尺寸
    size: ButtonSize = .md,
    /// 图标模式（只显示图标）
    icon_only: bool = false,
    /// 加载中
    loading: bool = false,
    /// 禁用
    disabled: bool = false,
    /// 块级（宽度填充）
    /// 非 block Button 保持 intrinsic 宽度：父容器交叉轴为 stretch（默认）时按 start
    /// 排而不被拉伸；父显式 align_items=.center/.end 时照常居中/靠尾。
    block: bool = false,
    /// 点击 handler
    on_click: ?core.HandlerRef = null,
    /// 图标纹理 ID（放在 label 文本左侧）
    icon: ?u32 = null,
    /// SVG 图标资源（优先于 texture icon）
    icon_asset: ?svg_assets.Asset = null,
    /// 图标尺寸（null = 跟随 control metrics 的 icon_size；应 ≤ 行高）
    icon_size: ?f32 = null,
    /// 图标 tint 颜色（默认跟随 textColor）
    icon_tint: ?Color = null,
    /// 通用事件处理（支持 hover/key 等复合事件）
    on_event: ?GenericEventCallback = null,
    /// 事件上下文
    event_context: ?*anyopaque = null,

    // ── 样式覆盖 ──
    /// 默认态样式覆盖
    style: StyleOverride = .{},
    /// hover 态样式覆盖
    hover_style: ?StyleOverride = null,
    /// pressed 态样式覆盖
    pressed_style: ?StyleOverride = null,
};

/// 创建按钮
pub fn Button(props: ButtonProps) ButtonBuilder {
    return ButtonBuilder{
        .props = props,
    };
}

/// Runtime resting-background override for interactive buttons.
///
/// Directly calling `node.setStyle(..., .background, ...)` is temporary on an
/// animated ControlShell because its before-render hook owns the interaction
/// colors. Use this channel instead; hover/pressed colors remain recipe-driven.
/// Pass null to restore the variant's normal background.
pub fn setBackgroundOverride(node: *Node, color: ?Color) void {
    if (node.meta.per_frame.hooks.slots.animated_bg_state) |state_ptr| {
        const state: *hooks.AnimBgState = @ptrCast(@alignCast(state_ptr));
        state.setNormalOverride(color);
        return;
    }
    node.setBackgroundRaw(color orelse Color.TRANSPARENT);
    node.markRenderDirty();
}

/// Companion to `setBackgroundOverride` for hover/pressed. A button whose
/// resting color is overridden to a solid "active" fill must override hover
/// too, or hovering snaps back to the recipe's ghost hover and light-tinted
/// icons vanish. Pass null(s) to restore the recipe interaction colors.
/// No-op on buttons without an animated background state.
pub fn setInteractionOverride(node: *Node, hover: ?Color, pressed: ?Color) void {
    if (node.meta.per_frame.hooks.slots.animated_bg_state) |state_ptr| {
        const state: *hooks.AnimBgState = @ptrCast(@alignCast(state_ptr));
        state.setInteractionOverride(hover, pressed);
    }
}

/// 按钮构建器
pub const ButtonBuilder = struct {
    props: ButtonProps,

    /// 设置标签
    pub fn label(self: ButtonBuilder, text_val: []const u8) ButtonBuilder {
        var new = self;
        new.props.label = text_val;
        return new;
    }

    /// 设置变体
    pub fn variant(self: ButtonBuilder, v: ButtonVariant) ButtonBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    /// 设置尺寸
    pub fn size(self: ButtonBuilder, s: ButtonSize) ButtonBuilder {
        var new = self;
        new.props.size = s;
        return new;
    }

    /// 设置禁用
    pub fn disabled(self: ButtonBuilder, d: bool) ButtonBuilder {
        var new = self;
        new.props.disabled = d;
        return new;
    }

    /// 设置加载中
    pub fn loading(self: ButtonBuilder, l: bool) ButtonBuilder {
        var new = self;
        new.props.loading = l;
        return new;
    }

    /// 设置点击 handler
    pub fn onClick(self: ButtonBuilder, handler_ref: core.HandlerRef) ButtonBuilder {
        var new = self;
        new.props.on_click = handler_ref;
        return new;
    }

    /// 保留模式: mount（只调一次，创建跨帧持久的 Node + Signal + Effect）
    pub fn mount(self: ButtonBuilder, scope: *Scope, cx: *Cx) !*Node {
        const p = self.props;
        const t = cx.tokens;

        // ── Recipe: 从 ControlShellRecipe 统一解析条件样式 ──
        const cs = control_shell.ControlShellRecipe.resolve(.{
            .variant = p.variant,
            .size = p.size,
        }, t);
        const resolved = cs.resolve(.{ .is_disabled = p.disabled });
        const metrics = t.control.get(p.size);
        const icon_size: f32 = p.icon_size orelse metrics.icon_size;
        const text_color = p.style.text_color orelse resolved.text_color orelse Color.hex(0xFFFFFF);
        const font_wt = p.style.font_weight orelse resolved.font_weight orelse 500;

        // 通过 ControlShell 构建统一基底
        var shell = try controlShell(.{
            .size = p.size,
            .variant = p.variant,
            .disabled = p.disabled,
            .icon_only = p.icon_only,
            .leading_icon = !p.icon_only and (p.icon != null or p.icon_asset != null or p.loading) and p.label != null,
            .style = p.style,
            .hover_style = p.hover_style,
            .pressed_style = p.pressed_style,
            .interactive = !p.disabled,
            .focus_ring = !p.disabled,
            .cursor = if (p.disabled) .not_allowed else .pointer,
        }, scope, cx);

        const node = shell.node;
        var icon_slot_live = true;
        var append_slot_live = true;
        errdefer {
            if (icon_slot_live and shell.icon_slot.parent == null) cx.freeNode(shell.icon_slot);
            if (append_slot_live) cx.freeNode(shell.append_slot);
            cx.freeNode(node);
        }
        try node.children.ensureUnusedCapacity(cx.allocator, 1);
        node.meta.ownership.meta.component_name = "Button";
        node.setFocusable(true);
        node.behavior.interaction.a11y = .{ .role = .button, .label = p.label, .disabled = p.disabled };
        // Button: 所有 slot 用 fit，root justify=center 让整体居中
        node.style.justify = .center;
        shell.content_slot.style.width = .{ .fit = .{} };

        // fit 宽 Button 放进 align_items=.stretch 的 column（框架默认）时，会被拉伸到
        // 整列宽，其 justify=center 的内容随之被推到列中央、跑出按钮自身可视框（label
        // 看似消失，Modal/Sheet/Form 的触发按钮全中招）。no_cross_stretch 只拒绝继承的
        // stretch（-> 按 .start 排、保持 intrinsic 宽），父显式 align_items=.center/.end
        // 仍照常生效（旧实现写死 align_self=.start，父容器永远无法居中按钮）。
        // block 走 grow 主动填充，需要 stretch 配合，故排除。
        if (!p.block) {
            (try node.style.ensureExtFallible(cx.allocator)).no_cross_stretch = true;
        }

        // block: 宽度填充父容器（root grow），内容仍靠 justify=center 居中。
        // icon_only 强制正方形，与 block 互斥，不覆盖。
        if (p.block and !p.icon_only) {
            node.style.width = .{ .grow = .{} };
        }

        // ── icon -> icon_slot ──────────────────────────────────────
        // loading 时由 spinner 取代 leading icon（二者都进 icon_slot，
        // 同时渲染会重叠，尤其 icon_only 下叠成 X+转圈）。
        if (!p.loading) {
            if (p.icon_asset) |asset| {
                const tint = p.icon_tint orelse text_color;
                var icon_style = Style{};
                icon_style.width = .{ .px = icon_size };
                icon_style.height = .{ .px = icon_size };
                const icon = try core.iconTint(cx, asset, tint, icon_style);
                errdefer if (icon.parent == null) cx.freeNode(icon);
                try shell.icon_slot.appendChild(cx.allocator, icon);
            } else if (p.icon) |tid| {
                const tint = p.icon_tint orelse text_color;
                var icon_style = Style{};
                icon_style.width = .{ .px = icon_size };
                icon_style.height = .{ .px = icon_size };
                const icon = try core.imageTint(cx, tid, tint, icon_style);
                errdefer if (icon.parent == null) cx.freeNode(icon);
                try shell.icon_slot.appendChild(cx.allocator, icon);
            }
        }

        // ── spinner -> icon_slot（仅 loading 时创建，在文字左侧）─
        if (p.loading) {
            const spinner_size: f32 = metrics.icon_size;
            const spinner_wrap = try box(cx, .{
                .width = .{ .px = spinner_size },
                .height = .{ .px = spinner_size },
                .align_items = .center,
                .justify = .center,
            }, .{});
            errdefer if (spinner_wrap.parent == null) cx.freeNode(spinner_wrap);
            spinner_wrap.meta.ownership.meta.component_name = "Button.spinner";
            try shell.icon_slot.appendChild(cx.allocator, spinner_wrap);

            const spinner_node = try spinner_mod.Spinner(.{})
                .size(spinner_size)
                .strokeWidth(switch (p.size) {
                    .xs => 1.5,
                    .sm => 1.5,
                    .md => 2.0,
                    .lg => 2.5,
                })
                .color(text_color)
                .mount(shell.scope, cx);
            errdefer if (spinner_node.parent == null) cx.freeNode(spinner_node);
            try spinner_wrap.appendChild(cx.allocator, spinner_node);
        }

        // ── label -> content_slot ─────────────────────────────────
        shell.content_slot.meta.ownership.meta.component_name = "Button.content";

        if (p.label) |lbl| {
            const text_node = try box(cx, .{ .width = .{ .fit = .{} } }, .{});
            errdefer if (text_node.parent == null) cx.freeNode(text_node);
            text_node.setText(.{
                .content = lbl,
                .color = text_color,
                .font_size = p.style.font_size orelse metrics.font_size,
                // 行高来自 control metrics：外框高度 = padding_y × 2 + 行高（不写死 height）
                .line_height = metrics.line_height,
                .font_weight = font_wt,
            });
            try shell.content_slot.appendChild(cx.allocator, text_node);
        }

        // icon_slot / content_slot 组装与未挂载 slot 释放
        if (shell.icon_slot.children.items.len > 0) {
            if (shell.content_slot.children.items.len == 0) {
                // icon-only: 移除并销毁空 content_slot，避免遗留未挂载节点
                cx.detachChildRetained(node, shell.content_slot);
                cx.freeNode(shell.content_slot);
                try node.appendChild(cx.allocator, shell.icon_slot);
            } else {
                try node.replaceChildOrder(cx.allocator, &.{ shell.icon_slot, shell.content_slot });
            }
        } else {
            // 无 icon: icon_slot 永远不会挂载，需主动释放
            cx.freeNode(shell.icon_slot);
            icon_slot_live = false;
        }

        // Button 不使用 append_slot，避免泄漏
        cx.freeNode(shell.append_slot);
        append_slot_live = false;

        // ── click / event handlers ───────────────────────────────
        if (!p.disabled) {
            if (!p.loading) {
                node.behavior.events.on_click = p.on_click;
            }
            if (p.on_event) |handler| {
                node.behavior.events.on_event = handler;
                node.behavior.events.event_context = p.event_context;
            }
        }

        return node;
    }
};

// ========== 测试 ==========

test "Button: basic creation" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{})
        .label("Click Me")
        .variant(.primary)
        .size(.md)
        .mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    // 文本在 content_slot 子节点里（无 icon 时 btn -> [content_slot]）
    try std.testing.expect(btn.children.items.len >= 1);
    const content_slot = btn.children.items[0];
    try std.testing.expect(content_slot.children.items.len > 0);
    const text_child = content_slot.children.items[0];
    try std.testing.expect(text_child.getText() != null);
    try std.testing.expectEqualStrings("Click Me", text_child.getText().?.content);
}

test "Button: variants" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    inline for (.{ ButtonVariant.primary, ButtonVariant.secondary, ButtonVariant.ghost, ButtonVariant.danger }) |v| {
        const btn = try Button(.{})
            .label("Test")
            .variant(v)
            .mount(scope_val, ctx);
        try root.appendChild(std.testing.allocator, btn);
    }

    try std.testing.expectEqual(@as(usize, 4), root.children.items.len);
}

test "Button: click handler" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    var clicked = false;

    const btn = try Button(.{})
        .label("Click")
        .onClick(core.Cx.simpleHandler(struct {
            fn handler(c: *anyopaque) void {
                const ptr: *bool = @ptrCast(@alignCast(c));
                ptr.* = true;
            }
        }.handler, &clicked))
        .mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    ctx.layout();
    ctx.handleClick(btn.rectFromWorldOrFallback().x + 10, btn.rectFromWorldOrFallback().y + 10);

    try std.testing.expect(clicked);
}

test "Button: ghost icon-only stays bare (no forced chrome)" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{
        .icon_only = true,
        .icon_asset = svg_assets.common.star,
        .variant = .ghost,
    }).mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    try std.testing.expect(Color.eql(btn.getBackground(), Color.TRANSPARENT));
    try std.testing.expect(btn.style.border.width == 0);
}

test "Button: runtime resting background override uses animation state" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();
    const btn = try Button(.{ .label = "Active", .variant = .ghost }).mount(scope_val, ctx);
    ctx.root = btn;
    const state_ptr = btn.meta.per_frame.hooks.slots.animated_bg_state orelse return error.TestUnexpectedResult;
    const state: *hooks.AnimBgState = @ptrCast(@alignCast(state_ptr));
    const recipe_normal = state.recipe_normal_bg;
    const active = Color.hex(0x2468AC);

    setBackgroundOverride(btn, active);
    try std.testing.expect(Color.eql(state.normal_bg, active));
    try std.testing.expect(Color.eql(state.normal_override.?, active));

    setBackgroundOverride(btn, null);
    try std.testing.expect(state.normal_override == null);
    try std.testing.expect(Color.eql(state.normal_bg, recipe_normal));
}

test "Button: resting override set before first render lands without a fade-in" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();
    const btn = try Button(.{ .label = "Active", .variant = .ghost }).mount(scope_val, ctx);
    ctx.root = btn;
    const hooks_list = &btn.meta.per_frame.hooks.before_render;
    const runHooks = struct {
        fn run(node: *Node, list: anytype) void {
            if (list.main) |m| m(node);
            for (list.hooks[0..list.count]) |maybe| if (maybe) |hook| hook(node);
        }
    }.run;

    const active = Color.hex(0x2468AC);
    setBackgroundOverride(btn, active);
    runHooks(btn, hooks_list);
    try std.testing.expect(Color.eql(btn.getBackground(), active));

    // 之后的变化仍然走过渡：同一帧时间下颜色还停在起点
    setBackgroundOverride(btn, Color.hex(0xFF0000));
    runHooks(btn, hooks_list);
    try std.testing.expect(Color.eql(btn.getBackground(), active));
}

test "Button: label stays inside pill when placed in a stretch column" {
    // Regression: a fit-width Button directly under an align_items=.stretch
    // column (framework default) used to be stretched to the column width,
    // and its justify=center content got centered against that stretched
    // width, landing far outside the pill's own visual box (label looked
    // missing in Modal/Sheet/Form trigger buttons). no_cross_stretch fixes it.
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    ctx.setViewport(800, 200);

    // wide column with default align_items (.stretch)
    const col = try box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .direction = .column,
    }, .{});
    ctx.root = col;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Open Modal", .variant = .primary }).mount(scope_val, ctx);
    try col.appendChild(allocator, btn);

    ctx.layout();

    const br = btn.rectFromWorldOrFallback();
    // Button keeps intrinsic (fit) width, NOT stretched to the 800px column.
    try std.testing.expect(br.w < 400);

    // The content slot's rect is relative to the button: it must sit inside
    // the button's own box. (The previous version compared the label rect,
    // relative to the content slot, against the button rect, which was
    // vacuous: it passed even when the slot had drifted to x≈366.)
    const content_slot = btn.children.items[btn.children.items.len - 1];
    const sr = content_slot.rectFromWorldOrFallback();
    try std.testing.expect(sr.x >= -0.5);
    try std.testing.expect(sr.x + sr.w <= br.w + 0.5);
}

const CrossAlignProbe = struct {
    col_w: f32,
    btn_x: f32,
    btn_w: f32,
    slot_x: f32,
    slot_w: f32,

    fn expectLabelInside(self: @This()) !void {
        try std.testing.expect(self.slot_w > 0);
        try std.testing.expect(self.slot_x >= -0.5);
        try std.testing.expect(self.slot_x + self.slot_w <= self.btn_w + 0.5);
        // justify=center：内容在按钮内水平居中
        try std.testing.expectApproxEqAbs((self.btn_w - self.slot_w) / 2.0, self.slot_x, 0.5);
    }
};

/// 800px 宽 column（指定 align_items）里挂一个 Button，布局后返回按钮相对 column 的 x/宽。
fn probeButtonInColumn(align_items: core.AlignItems, block: bool) !CrossAlignProbe {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    ctx.setViewport(800, 200);

    const col = try box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .direction = .column,
        .align_items = align_items,
    }, .{});
    ctx.root = col;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Click me", .block = block }).mount(scope_val, ctx);
    try col.appendChild(allocator, btn);

    ctx.layout();

    const cr = col.rectFromWorldOrFallback();
    const br = btn.rectFromWorldOrFallback();
    // content slot 的 rect 相对按钮本身：label 必须落在按钮自己的可视框内。
    const sr = btn.children.items[btn.children.items.len - 1].rectFromWorldOrFallback();
    return .{ .col_w = cr.w, .btn_x = br.x - cr.x, .btn_w = br.w, .slot_x = sr.x, .slot_w = sr.w };
}

test "Button: default stretch column keeps intrinsic width, start-aligned" {
    const r = try probeButtonInColumn(.stretch, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.btn_x, 0.5);
}

test "Button: parent align_items=.center centers a non-block button" {
    const r = try probeButtonInColumn(.center, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs((r.col_w - r.btn_w) / 2.0, r.btn_x, 0.5);
}

test "Button: parent align_items=.end end-aligns a non-block button" {
    const r = try probeButtonInColumn(.end, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(r.col_w - r.btn_w, r.btn_x, 0.5);
}

test "Button: parent align_items=.start start-aligns a non-block button" {
    const r = try probeButtonInColumn(.start, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.btn_x, 0.5);
}

test "Button: block button still fills the column width" {
    const stretch = try probeButtonInColumn(.stretch, true);
    try stretch.expectLabelInside();
    try std.testing.expectApproxEqAbs(stretch.col_w, stretch.btn_w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), stretch.btn_x, 0.5);
}

test "Button: mount (retained mode)" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    var clicked = false;
    const btn = try Button(.{})
        .label("Retained Button")
        .variant(.primary)
        .size(.md)
        .onClick(core.Cx.simpleHandler(struct {
            fn handler(c: *anyopaque) void {
                const ptr: *bool = @ptrCast(@alignCast(c));
                ptr.* = true;
            }
        }.handler, &clicked))
        .mount(scope_val, ctx);

    try root.appendChild(allocator, btn);

    // 验证节点属性（无 icon 时 btn -> [content_slot]）
    try std.testing.expect(btn.children.items.len >= 1);
    const content_slot = btn.children.items[0];
    try std.testing.expect(content_slot.children.items.len > 0);
    const text_child = content_slot.children.items[0];
    try std.testing.expect(text_child.getText() != null);
    try std.testing.expectEqualStrings("Retained Button", text_child.getText().?.content);
    try std.testing.expect(btn.meta.ownership.scope.scope != null);
    try std.testing.expect(btn.behavior.interaction.focusable);

    // 验证 hover 动画绑定
    try std.testing.expect(btn.behavior.events.on_hover != null);
    try std.testing.expect(btn.meta.per_frame.hooks.before_render.main != null or btn.meta.per_frame.hooks.before_render.count > 0);

    // 模拟 hover
    btn.behavior.events.on_hover.?.invoke();

    // 模拟点击
    ctx.layout();
    ctx.handleClick(btn.rectFromWorldOrFallback().x + 10, btn.rectFromWorldOrFallback().y + 10);
    try std.testing.expect(clicked);

    // Scope dispose 后清理所有 Signal/Effect
    scope_val.dispose();
}

test "Button: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("button", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Button(.{}).label("Click Me").variant(.primary).size(.md).mount(scope, cx);
        }
    }.m);
}
