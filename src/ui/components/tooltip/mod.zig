/// Tooltip Component.
/// Hover tooltip based on Popover hover path; shares overlay enter/prewarm lifecycle
/// with DatePicker/Popover to avoid forked animation logic.
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Signal = reactive.Signal;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const popover_mod = @import("../popover/mod.zig");

// -- Styling in styles.zig --
const styles = @import("styles.zig");

/// Tooltip position (reuse 12 Popover placements).
pub const TooltipPosition = popover_mod.PopoverPosition;

/// Tooltip properties.
pub const TooltipProps = struct {
    /// Hint text (accepts signal / derived value).
    text: Source([]const u8),
    position: TooltipPosition = .top,
    offset: f32 = 6,
    /// Delay after hover until tooltip shows (ms); if pointer leaves, doesn't show.
    open_delay_ms: f32 = 200,
    /// Toggle: default driven by hover; pass `*Signal(bool)` to programmatically show/hide.
    open: Model(bool) = .{ .local = false },
    on_open_change: ?Handler(bool) = null,
    background: ?Color = null,
    text_color: ?Color = null,
    font_size: f32 = 12,
};

/// Create Tooltip: `W.Tooltip(.{ .text = "Copy link" })`.
pub fn Tooltip(props: anytype) TooltipBuilder {
    return .{ .props = reactive.props.coerce(TooltipProps, props) };
}

/// TooltipBuilder.mount return value.
pub const TooltipResult = struct {
    wrapper: *Node,
    trigger: *Node,
    content: *Node,
    /// Toggle signal (null when split).
    open: ?*Signal(bool),
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: TooltipResult) core.ViewParts {
        return .{ .root = self.wrapper, .trigger = self.trigger };
    }
};

pub const TooltipBuilder = struct {
    props: TooltipProps,

    /// Retain mode: mount.
    pub fn mount(self: TooltipBuilder, scope: *Scope, cx: *Cx) !TooltipResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const result = try popover_mod.Popover(.{
            .position = p.position,
            .trigger = .hover,
            .offset = .{ .static = p.offset },
            .open_delay_ms = p.open_delay_ms,
            .open = p.open,
            .on_open_change = p.on_open_change,
            .close_on_outside_click = false,
            .close_on_escape = false,
            .prewarm_hidden_layout = false,
            .tier = .tooltip,
        }).mount(scope, cx);
        // After Popover.mount, wrapper subtree (trigger/content/overlay layers) bound only to
        // my_scope;
        // bindScopeToNode destroy unbinds but doesn't release, so caller's scope.dispose() won't
        // reclaim it.
        // Below: ensureExt / text mount / binding can fail; mid-fail must release here (freeNode
        // auto-disposes bound subscope).
        errdefer cx.freeNode(result.wrapper);

        result.wrapper.meta.ownership.meta.component_name = "Tooltip";
        result.wrapper.behavior.interaction.a11y = .{};
        result.content.meta.ownership.meta.component_name = "TooltipContent";
        result.content.behavior.interaction.a11y = .{ .role = .tooltip };
        result.content.setHitTestVisible(false);
        result.content.setBackgroundRaw(styles.tooltipContentBackground(p.background, t));
        result.content.style.padding = styles.tooltipPadding(t);
        result.content.style.border = .{ .radius = styles.tooltipRadius(t) };

        const content_ext = try result.content.style.ensureExtFallible(allocator);
        content_ext.clearShadows();
        content_ext.setShadow(t.tokens.shadow.sm);
        content_ext.hit_shape = .{ .rounded_rect = styles.tooltipRadius(t) };
        content_ext.clip_shape = .{ .rounded_rect = styles.tooltipRadius(t) };

        // Built and mounted: after that, released with wrapper if binding fails. Hangs under
        // Popover's scope (content in portal).
        var label: *Node = undefined;
        try view.mount(result.scope, cx, result.content, view.capture(&label, view.text(
            .{ .style = styles.tooltipLabelStyle(p.text_color, p.font_size, t) },
            p.text.peek(),
        )));
        // Tooltip a11y name points to label's text copy; re-point when dynamic text updates.
        if (result.content.behavior.interaction.a11y) |*a| a.label = label.getText().?.content;
        if (!p.text.isStatic()) {
            // Text binding must belong to Popover's scope: content in portal; on Popover unmount,
            // dispose
            // its scope first, then freeDetachedNodeAfterScopeDispose content (unbind children,
            // don't dispose).
            // If binding hangs elsewhere, unmount still writes freed label.
            try bind_mod.bindTextLabel(cx, result.scope, p.text, label, result.content);
        }

        return .{ .wrapper = result.wrapper, .trigger = result.trigger, .content = result.content, .open = result.open };
    }
};

// ========= Tests =========

test "Tooltip: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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
        .background = theme.dark.tokens.color.accent,
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 300);

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tooltip(.{
        .text = "Smooth tooltip",
        .position = .bottom,
        // Test only checks enter animation curve; 10-frame window can't hide default 200ms display
        // delay.
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

// Test collection from styles.zig; this line required (see docs/STYLING.md).
test "Tooltip: dynamic text updates the label and the tooltip a11y name; unmount stops the binding" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tip = try scope.createText("Copy", .{});
    const result = try Tooltip(.{ .text = tip }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const label = result.content.children.items[result.content.children.items.len - 1];
    try std.testing.expectEqualStrings("Copy", label.getText().?.content);
    tip.set("Copied!");
    try std.testing.expectEqualStrings("Copied!", label.getText().?.content);
    try std.testing.expectEqual(label.getText().?.content.ptr, result.content.behavior.interaction.a11y.?.label.?.ptr);

    // Change text after unmount tooltip: binding released with label's scope; can't write freed
    // node.
    ctx.detachChild(root, result.wrapper);
    ctx.freeNode(result.wrapper);
    tip.set("after unmount");
}

test "Tooltip: 动态文本的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tooltip(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const tip = try scope.createText("Copy", .{});
            return (try Tooltip(.{ .text = tip }).mount(scope, cx)).wrapper;
        }
    }.m);
}

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
