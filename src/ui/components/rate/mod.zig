/// Rate Component
///
/// 星星评分组件
///
/// 特性:
/// - 星星 ★/☆ 显示
/// - hover 预览
/// - click 确认
/// - 可选半星
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const PathCommand = core.PathCommand;
const svg_assets = @import("../../svg_assets.zig");
const Scope = @import("../../reactive.zig").Scope;
const styles = @import("styles.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;

/// Rate 属性
pub const RateProps = struct {
    count: u8 = 5,
    value: f32 = 0,
    disabled: bool = false,
    size: f32 = 24,
    on_change: ?core.HandlerRef = null,
    /// 星标图标。默认实心星（common.star_filled，亮/灭只靠 tint 区分）；
    /// 可换成自定义 SVG（心形、描边星等）。曾经默认为 null 时退化成 "*" 文本。
    star_icon_asset: svg_assets.Asset = svg_assets.common.star_filled,
};

/// Rate 状态
pub const RateState = struct {
    value: f32,
    hover_value: f32 = 0,
    is_hovering: bool = false,
    count: u8,
    on_change: ?core.HandlerRef,
    stars: [10]*Node = undefined, // max 10 stars
    /// 容器节点：role=slider 的 a11y 数值挂在它身上
    container_node: ?*Node = null,
    cx: *Cx,

    /// 同步 a11y 数值。**只报 self.value，不报 hover_value**, hover 预览
    /// 是纯视觉的临时态，把它播报出去会让 AT 用户以为分数已经改了。
    fn syncA11y(self: *RateState) void {
        const node = self.container_node orelse return;
        if (node.behavior.interaction.a11y) |*a| {
            a.value_now = self.value;
            if (a.value_range) |*range| range.now = self.value;
        }
    }

    pub fn getValue(self: *const RateState) f32 {
        return self.value;
    }

    /// 程序化设置评分值。
    ///
    /// 此前 RateState 虽然公开、`value` 字段可写，但 `updateDisplay` 是私有的
    /// 直接写 `state.value` **不会重绘**，看起来能驱动实则无效
    /// （审查里归为"tier-b 陷阱"：暴露了 state 却没有生效的写入口）。
    ///
    /// 会 clamp 到 [0, count]，并同步星星显示。不触发 on_change
    /// （程序化设值不是用户交互；需要通知请自行调用）。
    pub fn setValue(self: *RateState, v: f32) void {
        const max: f32 = @floatFromInt(self.count);
        self.value = std.math.clamp(v, 0, max);
        self.updateDisplay();
    }

    /// 键盘步进：clamp 到 [0, count]，值变化时触发 on_change（用户交互）。
    /// 当前 Rate 无半星实现（点击也只产生整数值），步长固定 1。
    pub fn stepBy(self: *RateState, delta: f32) void {
        const max: f32 = @floatFromInt(self.count);
        const new_val = std.math.clamp(self.value + delta, 0, max);
        if (new_val == self.value) return;
        self.value = new_val;
        self.is_hovering = false;
        self.updateDisplay();
        if (self.on_change) |handler| handler.invoke();
    }

    fn updateDisplay(self: *RateState) void {
        // 所有改 value 的路径（setValue / 点击星星）都汇到这里，挂在此处
        // 不会漏。syncA11y 内部只读 self.value，hover 造成的重绘不会污染数值。
        self.syncA11y();
        const display_val = if (self.is_hovering) self.hover_value else self.value;
        const t = self.cx.tokens;
        for (0..self.count) |i| {
            const star = self.stars[i];
            const fi: f32 = @floatFromInt(i);
            const active = fi < display_val;
            if (star.children.items.len > 0) {
                _ = star.children.items[0].setTint(styles.starColor(active, t));
            }
            star.markRenderDirty();
        }
    }
};

/// 方向键调分（与 NumberStepper onStepKey 同型）：Right/Up 加、Left/Down 减。
fn onRateKey(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const state: *RateState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (key) {
        .right, .up => state.stepBy(1),
        .left, .down => state.stepBy(-1),
        else => return .ignored,
    }
    return .handled;
}

fn setA11yRateValue(context: *anyopaque, value: f32) bool {
    const state: *RateState = @ptrCast(@alignCast(context));
    state.setValue(value);
    if (state.on_change) |handler| handler.invoke();
    return true;
}

/// Rate mount 结果
pub const RateResult = struct {
    wrapper: *Node,
    state: *RateState,
};

/// 创建 Rate
pub fn Rate(props: RateProps) RateBuilder {
    return RateBuilder{ .props = props };
}

pub const RateBuilder = struct {
    props: RateProps,

    pub fn count(self: RateBuilder, c: u8) RateBuilder {
        var new = self;
        new.props.count = c;
        return new;
    }

    pub fn value(self: RateBuilder, v: f32) RateBuilder {
        var new = self;
        new.props.value = v;
        return new;
    }

    pub fn onChange(self: RateBuilder, handler_ref: core.HandlerRef) RateBuilder {
        var new = self;
        new.props.on_change = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: RateBuilder, scope: *Scope, cx: *Cx) !RateResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const star_count = @min(p.count, 10);

        const container = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
            .gap = 4,
        }, .{});
        // sweep：container 守到 return；星星建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Rate";
        try core.bindScopeToNode(my_scope, container);
        // 评分本质是"在 0..count 里取一个值"，ARIA 对应 role=slider。
        // 逐颗星星单独暴露反而让 AT 用户要听 5 遍才知道当前几分。
        container.behavior.interaction.a11y = .{
            .role = .slider,
            .label = "Rating",
            .disabled = p.disabled,
            .readonly = p.disabled,
            .value_now = p.value,
            .value_min = 0,
            .value_max = @floatFromInt(star_count),
        };

        // State
        const state = try allocator.create(RateState);
        state.* = .{
            .value = p.value,
            .count = star_count,
            .on_change = p.on_change,
            .container_node = container,
            .cx = cx,
        };
        if (container.behavior.interaction.a11y) |*a11y| {
            a11y.value_range = .{
                .now = state.value,
                .min = 0,
                .max = @floatFromInt(state.count),
                .context = state,
                .set_value = setA11yRateValue,
            };
            a11y.orientation = .horizontal;
        }
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*RateState, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);

        // 键盘交互：role=slider 的标配是方向键调值（与 NumberStepper 接线一致）。
        container.setFocusable(!p.disabled);
        if (!p.disabled) {
            container.behavior.events.on_key_down = onRateKey;
            container.behavior.events.key_context = @ptrCast(state);
        }

        for (0..star_count) |i| {
            const fi: f32 = @floatFromInt(i);
            const is_filled = fi < p.value;
            const star_color: Color = styles.starColor(is_filled, t);

            const star = try core.adoptChild(cx, allocator, container, try box(cx, styles.starBoxStyle(p.size), .{}));
            _ = try core.adoptChild(cx, allocator, star, try core.iconTint(cx, p.star_icon_asset, star_color, .{
                .width = .{ .px = p.size * styles.star_icon_scale },
                .height = .{ .px = p.size * styles.star_icon_scale },
            }));

            try configureStarHitShape(star, allocator, p.size);

            if (!p.disabled) {
                star.style.cursor = .pointer;

                const star_ctx = try allocator.create(StarClickCtx);
                star_ctx.* = .{ .state = state, .index = @intCast(i) };
                try my_scope.adoptResource(@ptrCast(star_ctx), struct {
                    fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                        alloc.destroy(@as(*StarClickCtx, @ptrCast(@alignCast(ptr))));
                    }
                }.cleanup);
                star.behavior.events.on_event = starEventHandler;
                star.behavior.events.event_context = @ptrCast(star_ctx);
            }

            state.stars[i] = star;
        }

        return .{ .wrapper = container, .state = state };
    }
};

// ========== 内部辅助 ==========

const StarClickCtx = struct {
    state: *RateState,
    index: u8,
};

fn starEventHandler(event: Event, context: ?*anyopaque) EventResult {
    if (context) |ctx| {
        const sc: *StarClickCtx = @ptrCast(@alignCast(ctx));
        switch (event) {
            .click => {
                const new_val: f32 = @floatFromInt(sc.index + 1);
                sc.state.value = new_val;
                sc.state.is_hovering = false;
                sc.state.updateDisplay();
                if (sc.state.on_change) |handler| handler.invoke();
                return .stop;
            },
            .mouse_enter => {
                sc.state.is_hovering = true;
                sc.state.hover_value = @floatFromInt(sc.index + 1);
                sc.state.updateDisplay();
                return .stop;
            },
            .mouse_leave => {
                sc.state.is_hovering = false;
                sc.state.updateDisplay();
                return .stop;
            },
            else => {},
        }
    }
    return .ignored;
}

fn configureStarHitShape(star: *Node, allocator: Allocator, size: f32) !void {
    const cx = size / 2.0;
    const cy = size / 2.0;
    const outer = size * 0.42;
    const inner = outer * 0.48;

    var commands: [11]PathCommand = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const is_outer = (i % 2) == 0;
        const radius = if (is_outer) outer else inner;
        const angle = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * (std.math.pi / 5.0);
        const point = core.Point{
            .x = cx + std.math.cos(angle) * radius,
            .y = cy + std.math.sin(angle) * radius,
        };
        commands[i] = if (i == 0)
            .{ .move_to = point }
        else
            .{ .line_to = point };
    }
    commands[10] = .{ .close = {} };

    try star.setPathHitGeometry(allocator, commands[0..], .nonzero);
    const ext = try star.style.ensureExtFallible(allocator);
    ext.hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
}

// ========== 测试 ==========

test "Rate: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 3 }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(@as(usize, 5), result.wrapper.children.items.len);
    try std.testing.expectEqual(@as(f32, 3), result.state.value);
}

test "Rate: 默认用实心星图标（不再是 \"*\" 文本），亮/灭按 tint 区分" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 2 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    for (result.wrapper.children.items, 0..) |star, i| {
        try std.testing.expect(star.getText() == null);
        try std.testing.expectEqual(@as(usize, 1), star.children.items.len);
        const ic = star.children.items[0].getIcon() orelse return error.TestExpectedIcon;
        try std.testing.expectEqual(styles.starColor(i < 2, ctx.tokens), ic.tint);
    }
    // setValue / hover 走 updateDisplay：必须真的改到图标 tint。
    result.state.setValue(4);
    const lit = result.wrapper.children.items[3].children.items[0].getIcon().?;
    try std.testing.expectEqual(styles.starColor(true, ctx.tokens), lit.tint);
}

test "Rate: click changes value" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 0 }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 模拟点击第 3 颗星
    const star3 = result.wrapper.children.items[2];
    if (star3.behavior.events.on_event) |handler| {
        _ = handler(.{ .click = .{ .x = 0, .y = 0 } }, star3.behavior.events.event_context);
    }

    try std.testing.expectEqual(@as(f32, 3), result.state.value);
}

test "Rate: disabled" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 4, .disabled = true }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // disabled 时没有事件处理
    const star = result.wrapper.children.items[0];
    try std.testing.expect(star.behavior.events.on_event == null);
}

test "Rate: 方向键调分 + clamp + on_change" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var change_count: u32 = 0;
    const on_change = core.HandlerRef{
        .callback = struct {
            fn cb(p: *anyopaque) void {
                const c: *u32 = @ptrCast(@alignCast(p));
                c.* += 1;
            }
        }.cb,
        .context = @ptrCast(&change_count),
    };

    const result = try Rate(.{ .count = 5, .value = 4, .on_change = on_change }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const node = result.wrapper;
    try std.testing.expect(node.behavior.events.on_key_down != null);
    const kh = node.behavior.events.on_key_down.?;
    const kctx = node.behavior.events.key_context;

    // Right/Up 加
    try std.testing.expectEqual(EventResult.handled, kh(.right, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 5), result.state.value);
    // clamp 到 max：值没变，不触发 on_change
    try std.testing.expectEqual(EventResult.handled, kh(.up, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 5), result.state.value);
    try std.testing.expectEqual(@as(u32, 1), change_count);

    // Left/Down 减
    try std.testing.expectEqual(EventResult.handled, kh(.left, .{}, kctx));
    try std.testing.expectEqual(EventResult.handled, kh(.down, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 3), result.state.value);
    try std.testing.expectEqual(@as(u32, 3), change_count);

    // clamp 到 0
    result.state.setValue(0);
    try std.testing.expectEqual(EventResult.handled, kh(.down, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 0), result.state.value);

    // 无关按键 ignored
    try std.testing.expectEqual(EventResult.ignored, kh(.a, .{}, kctx));
}

test "Rate: disabled 无键盘接线" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 2, .disabled = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(result.wrapper.behavior.events.on_key_down == null);
    try std.testing.expect(!result.wrapper.behavior.interaction.focusable);
}

test "Rate.setValue: 程序化设值会重绘星星（此前 updateDisplay 私有，写字段无效）" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 200);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 2 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    const st = result.state;
    try std.testing.expectEqual(@as(f32, 2), st.getValue());

    st.setValue(4);
    try std.testing.expectEqual(@as(f32, 4), st.getValue());

    // clamp 到 [0, count]
    st.setValue(99);
    try std.testing.expectEqual(@as(f32, 5), st.getValue());
    st.setValue(-3);
    try std.testing.expectEqual(@as(f32, 0), st.getValue());
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "rate: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("rate", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Rate(.{ .count = 5, .value = 3 }).mount(scope, cx)).wrapper;
        }
    }.m);
}
