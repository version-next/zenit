/// Tooltip Component
///
/// 悬浮提示组件，基于 Popover hover 路径实现，和 DatePicker/Popover
/// 共享同一套 overlay enter/prewarm 生命周期，避免两套动画逻辑分叉。
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const popover_mod = @import("../popover/mod.zig");

// ── 样式层在 styles.zig ──
const styles = @import("styles.zig");

/// Tooltip 位置（复用 Popover 的 12 种 placement）
pub const TooltipPosition = popover_mod.PopoverPosition;

/// Tooltip 属性
pub const TooltipProps = struct {
    text: []const u8,
    position: TooltipPosition = .top,
    offset: f32 = 6,
    /// hover 后到 tooltip 开始显示的延迟（ms）；期间移开指针则不显示。
    open_delay_ms: f32 = 200,
    background: ?Color = null,
    text_color: ?Color = null,
    font_size: f32 = 12,
};

/// 创建 Tooltip
pub fn Tooltip(props: TooltipProps) TooltipBuilder {
    return TooltipBuilder{ .props = props };
}

/// TooltipBuilder.mount 的返回结果
pub const TooltipResult = struct { wrapper: *Node, trigger: *Node, content: *Node };

pub const TooltipBuilder = struct {
    props: TooltipProps,

    pub fn text(self: TooltipBuilder, t: []const u8) TooltipBuilder {
        var new = self;
        new.props.text = t;
        return new;
    }

    pub fn position(self: TooltipBuilder, p: TooltipPosition) TooltipBuilder {
        var new = self;
        new.props.position = p;
        return new;
    }

    pub fn offset(self: TooltipBuilder, o: f32) TooltipBuilder {
        var new = self;
        new.props.offset = o;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: TooltipBuilder, scope: *Scope, cx: *Cx) !TooltipResult {
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const result = try popover_mod.Popover(.{
            .position = p.position,
            .trigger = .hover,
            .offset = .{ .static = p.offset },
            .open_delay_ms = p.open_delay_ms,
            .close_on_outside_click = false,
            .close_on_escape = false,
            .prewarm_hidden_layout = false,
            .tier = .tooltip,
        }).mount(scope, cx);
        // Popover.mount 返回后，wrapper 子树（含 trigger/content/overlay 层）只被
        // my_scope 绑定，bindScopeToNode 的 destroy 只解绑不释放，所以调用方
        // scope.dispose() 不会回收它。下面还有 box / appendChild 会失败，中途失败
        // 必须由这里释放。与 Popover.mount 内部同型（freeNode 会顺带 dispose 绑定的
        // 子 scope）。md mount OOM 注入 index 2226 实测：整棵 popover 子树泄漏。
        errdefer cx.freeNode(result.wrapper);

        result.wrapper.meta.ownership.meta.component_name = "Tooltip";
        result.wrapper.behavior.interaction.a11y = .{};
        result.content.meta.ownership.meta.component_name = "TooltipContent";
        result.content.behavior.interaction.a11y = .{ .role = .tooltip, .label = p.text };
        result.content.setHitTestVisible(false);
        result.content.setBackgroundRaw(styles.tooltipContentBackground(p.background, t));
        result.content.style.padding = styles.tooltip_content_padding;
        result.content.style.border = .{ .radius = styles.tooltip_radius };

        const content_ext = try result.content.style.ensureExtFallible(allocator);
        content_ext.clearShadows();
        content_ext.hit_shape = .{ .rounded_rect = styles.tooltip_radius };
        content_ext.clip_shape = .{ .rounded_rect = styles.tooltip_radius };

        const label = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
        }, .{});
        var label_txt = styles.tooltipLabelStyle(p.text_color, p.font_size, t);
        label_txt.content = p.text;
        label.setText(label_txt);
        // label 建好到挂进 content 之间是游离节点，setText 已 dupe 文本，
        // append 失败时连同它一起漏。
        errdefer cx.freeNode(label);
        try result.content.appendChild(allocator, label);

        return .{ .wrapper = result.wrapper, .trigger = result.trigger, .content = result.content };
    }
};

// ========= 测试 =========

test "Tooltip: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tooltip(.{
        .text = "Hello tooltip",
        .position = .top,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    const btn = try box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 32 },
        .background = theme.dark.color.accent,
    }, .{
        try core.text(ctx, "Hover me", .{}),
    });
    try result.trigger.appendChild(std.testing.allocator, btn);

    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);

    const tooltip = result.content;
    try std.testing.expect(tooltip.parent == null);
    try std.testing.expectEqual(core.Sizing{ .px = 0 }, tooltip.style.width);
    try std.testing.expectEqual(@as(usize, 1), tooltip.children.items.len);
    try std.testing.expect(tooltip.behavior.interaction.a11y != null);
    try std.testing.expectEqual(core.A11yRole.tooltip, tooltip.behavior.interaction.a11y.?.role);
}

test "Tooltip: hover shows" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tooltip(.{
        .text = "Visible",
        .position = .bottom,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    const tooltip = result.content;

    try std.testing.expectEqual(core.Sizing{ .px = 0 }, tooltip.style.width);
    try std.testing.expect(result.wrapper.behavior.events.on_hover != null);
    try std.testing.expect(result.wrapper.behavior.events.on_leave != null);

    result.wrapper.behavior.events.on_hover.?.invoke();
    try std.testing.expect(tooltip.parent != null);
    try std.testing.expectEqual(core.Sizing{ .fit = .{} }, tooltip.style.width);

    result.wrapper.behavior.events.on_leave.?.invoke();
    try std.testing.expectEqual(core.Sizing{ .fit = .{} }, tooltip.style.width);
}

test "Tooltip: first 10 open frames progress from enter state instead of flashing" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 300);

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tooltip(.{
        .text = "Smooth tooltip",
        .position = .bottom,
        // 本测试只看 enter 动画曲线，10 帧窗口盖不住默认 200ms display delay
        .open_delay_ms = 0,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const btn = try box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 32 },
    }, .{});
    try result.trigger.appendChild(std.testing.allocator, btn);

    ctx.layout();
    _ = ctx.render();

    const tooltip = result.content;
    result.wrapper.behavior.events.on_hover.?.invoke();

    var opacities: [10]f32 = undefined;
    var scales: [10]f32 = undefined;
    var now_ms: f64 = 0;
    for (0..10) |i| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        ctx.layout();
        _ = ctx.render();
        opacities[i] = tooltip.getOpacity();
        scales[i] = tooltip.style.scale_x();
    }

    var first_visible_idx: ?usize = null;
    for (opacities, 0..) |opacity, i| {
        if (opacity > 0.0011) {
            first_visible_idx = i;
            break;
        }
    }

    try std.testing.expect(tooltip.rectFromWorldOrFallback().w > 0);
    try std.testing.expect(tooltip.rectFromWorldOrFallback().h > 0);
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

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

test "Tooltip: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tooltip", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Tooltip(.{ .text = "Hello tooltip", .position = .top }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
