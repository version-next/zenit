/// Rate: star rating component.
///
/// Features:
/// - star display (filled/empty)
/// - hover preview
/// - click confirm
/// - Signal-first: `value: Model(f32)`, `disabled: Source(bool)`; hover preview is pure visual temp
///   state
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const PathCommand = core.PathCommand;
const svg_assets = @import("../../svg_assets.zig");
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const styles = @import("styles.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;

/// Rate properties
pub const RateProps = struct {
    count: u8 = 5,
    /// Current score: `f32` uncontrolled initial; `*Signal(f32)` controlled (interaction writes
    /// directly); `ui.split` intercepts.
    /// User input truncates and clamps to [0, count]; external out-of-range values clamped to
    /// display, no write-back.
    value: Model(f32) = .{ .local = 0 },
    disabled: Source(bool) = .{ .value = false },
    size: f32 = 24,
    /// Called after user changes score and lands (landed value)
    on_change: ?Handler(f32) = null,
    /// Star icon. Default filled / outlined stars (accent / border_strong);
    /// can swap custom SVG (heart, outline star etc).
    star_icon_asset: svg_assets.Asset = svg_assets.common.star_filled,
};

/// Rate runtime (scope-owned). View = f(value, disabled) applied by effect;
/// Hover preview updates star appearance without touching the data source.
pub const RateRuntime = struct {
    value: reactive.Bound(f32),
    disabled: Source(bool),
    on_change: ?Handler(f32),
    count: u8,
    default_star: bool = true,
    icon_px: f32 = 18,
    /// Currently displayed score (data source value clamped to [0, count])
    shown: f32 = 0,
    is_disabled: bool = false,
    hover_value: ?f32 = null,
    stars: [10]*Node = undefined, // max 10 stars
    /// Container node: role=slider a11y value hooked on it
    container_node: *Node,
    cx: *Cx,

    fn displayOf(self: *const RateRuntime, v: f32) f32 {
        if (std.math.isNan(v)) return 0;
        return std.math.clamp(v, 0, @as(f32, @floatFromInt(self.count)));
    }

    fn view(self: *RateRuntime, comptime tracked: bool) void {
        const v = self.displayOf(self.value.readAs(tracked));
        const dis = self.disabled.read(tracked);
        if (dis != self.is_disabled) {
            self.is_disabled = dis;
            self.applyDisabled();
        }
        if (v != self.shown) {
            self.shown = v;
            self.syncA11y();
            self.paintStars();
        }
    }

    fn viewEffect(self: *RateRuntime) void {
        self.view(true);
    }

    fn applyDisabled(self: *RateRuntime) void {
        const dis = self.is_disabled;
        self.container_node.setFocusable(!dis);
        if (self.container_node.behavior.interaction.a11y) |*a| {
            a.disabled = dis;
            a.readonly = dis;
        }
        for (self.stars[0..self.count]) |star| star.style.cursor = if (dis) .default else .pointer;
        if (dis) self.hover_value = null;
        self.paintStars();
    }

    /// Sync a11y value. Only report landed score, not hover preview: speaking temp state
    /// would confuse AT users into thinking score already changed.
    fn syncA11y(self: *RateRuntime) void {
        if (self.container_node.behavior.interaction.a11y) |*a| {
            a.value_now = self.shown;
            if (a.value_range) |*range| range.now = self.shown;
        }
    }

    fn paintStars(self: *RateRuntime) void {
        const display_val = self.hover_value orelse self.shown;
        const t = self.cx.tokens;
        for (self.stars[0..self.count], 0..) |star, i| {
            const active = @as(f32, @floatFromInt(i)) < display_val;
            if (star.children.items.len > 0) {
                const icon = star.children.items[0];
                // setIcon / setTint write the icon raw: mark the icon itself, the node whose
                // content changed (its cross-frame copies are keyed on its own dirty bits).
                if (self.default_star) {
                    const asset = if (active) svg_assets.common.star_filled else svg_assets.common.star;
                    icon.setIcon(.{ .icon_id = asset.icon_id.?, .rep = asset.pickRep(self.icon_px).?, .tint = styles.starColor(active, t) });
                    icon.markRenderDirty();
                } else {
                    if (icon.setTint(styles.starColor(active, t))) icon.markRenderDirty();
                }
            }
            star.markRenderDirty();
        }
    }

    fn setHover(self: *RateRuntime, v: ?f32) void {
        if (self.is_disabled) return;
        self.hover_value = v;
        self.paintStars();
    }

    /// User input: truncate, clamp, propose; after landing call on_change (last step, may destroy
    /// this component)
    fn propose(self: *RateRuntime, raw: f32) void {
        if (std.math.isNan(raw)) return;
        const v = std.math.clamp(@round(raw), 0, @as(f32, @floatFromInt(self.count)));
        const landed = self.value.commit(v) orelse return;
        if (self.on_change) |h| h.call(landed);
    }
};

/// Arrow key adjust: Right/Up increment, Left/Down decrement (no half-stars currently, step 1)
fn onRateKey(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const rt: *RateRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    if (rt.is_disabled) return .ignored;
    switch (key) {
        .right, .up => rt.propose(rt.shown + 1),
        .left, .down => rt.propose(rt.shown - 1),
        else => return .ignored,
    }
    return .handled;
}

/// Return true means this control handled request (caller focuses it)
fn setA11yRateValue(context: *anyopaque, value: f32) bool {
    const rt: *RateRuntime = @ptrCast(@alignCast(context));
    if (rt.is_disabled) return false;
    rt.propose(value);
    return true;
}

/// Rate mount result
pub const RateResult = struct {
    wrapper: *Node,
    /// Score signal (`ui.split` when null)
    value: ?*Signal(f32),
    /// `ui.view` entry (see src/ui/view_parts.zig).
    pub fn viewParts(self: RateResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

/// Create Rate: `W.Rate(.{ .count = 5, .value = score })`
pub fn Rate(props: anytype) RateBuilder {
    return .{ .props = reactive.props.coerce(RateProps, props) };
}

pub const RateBuilder = struct {
    props: RateProps,

    /// Retain mode: mount
    pub fn mount(self: RateBuilder, scope: *Scope, cx: *Cx) !RateResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        reactive.checkBorrow(my_scope, p.disabled);
        const value = try reactive.resolveModel(f32, my_scope, p.value);
        const initially_disabled = p.disabled.read(false);

        const star_count = @min(p.count, 10);

        // Star count is runtime value (<=10): unused slots in fixed array left null, not emitted
        var stars: [10]*Node = undefined;
        const icon_px: core.Sizing = .{ .px = p.size * styles.star_icon_scale };
        var star_elems: [10]?StarView = @splat(null);
        for (0..star_count) |i| star_elems[i] = starView(&stars[i], p.size, p.star_icon_asset, icon_px, t);

        const container = try view.render(my_scope, cx, view.row(.{
            .style = .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .no_cross_stretch = true, .gap = 0 },
            // Rating is 'pick one value from 0..count', ARIA maps to role=slider.
            // Exposing each star separately would make AT users hear 5 times before knowing current
            // score.
            .a11y = .{
                .role = .slider,
                .label = "Rating",
                .value_min = 0,
                .value_max = @as(f32, @floatFromInt(star_count)),
                .orientation = .horizontal,
            },
        }, star_elems));
        // sweep: container guards to return
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Rate";
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;

        const rt = try my_scope.allocator.create(RateRuntime);
        rt.* = .{
            .value = value,
            .disabled = p.disabled,
            .on_change = p.on_change,
            .count = star_count,
            .default_star = p.star_icon_asset.svg_data.ptr == svg_assets.common.star_filled.svg_data.ptr,
            .icon_px = p.size * styles.star_icon_scale,
            // Not equal to any display value: first view must apply
            .shown = std.math.nan(f32),
            // Negate first: ensure disabled state applied on first view
            .is_disabled = !initially_disabled,
            .container_node = container,
            .cx = cx,
        };
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*RateRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        if (container.behavior.interaction.a11y) |*a11y| {
            a11y.value_range = .{
                .small_change = 1,
                .now = 0,
                .min = 0,
                .max = @floatFromInt(star_count),
                .context = rt,
                .set_value = setA11yRateValue,
            };
        }

        // Keyboard interaction always hooked, disabled determined at runtime (disabled can be
        // dynamic)
        container.behavior.events.on_key_down = onRateKey;
        container.behavior.events.key_context = @ptrCast(rt);

        // Star hit shape (star path) and raw events (click / hover preview) are node-level
        // capability, wired after mount
        for (stars[0..star_count], 0..) |star, i| {
            try configureStarHitShape(star, allocator, p.size);

            const star_ctx = try my_scope.allocator.create(StarClickCtx);
            star_ctx.* = .{ .rt = rt, .index = @intCast(i) };
            try my_scope.adoptResource(@ptrCast(star_ctx), struct {
                fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                    alloc.destroy(@as(*StarClickCtx, @ptrCast(@alignCast(ptr))));
                }
            }.cleanup);
            star.behavior.events.on_event = starEventHandler;
            star.behavior.events.event_context = @ptrCast(star_ctx);

            rt.stars[i] = star;
        }

        rt.view(false);
        // value is Model: local also signal, interaction changes it, must have effect
        try my_scope.createEffect(rt, RateRuntime.viewEffect);
        return .{ .wrapper = container, .value = value.asSignal() };
    }
};

// ========== Internal helpers ==========

/// Single star: square grid centered + star icon (initially unlit, RateRuntime.paintStars changes
/// tint at runtime)
fn starView(dest: **Node, size: f32, asset: svg_assets.Asset, icon_px: core.Sizing, t: *const core.ThemeTokens) StarView {
    return view.capture(dest, view.box(StarBoxProps{ .style = styles.starBoxStyle(size) }, view.icon(StarIconProps{
        .style = .{ .width = icon_px, .height = icon_px },
        .tint = styles.starColor(false, t),
    }, asset)));
}

const StarBoxProps = struct { style: core.BoxStyle };
const StarIconProps = struct { style: core.BoxStyle, tint: Color };
const StarView = view.NodeCapture(**Node, view.Box(StarBoxProps, view.Icon(StarIconProps), null));

const StarClickCtx = struct {
    rt: *RateRuntime,
    index: u8,
};

fn starEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const sc: *StarClickCtx = @ptrCast(@alignCast(context orelse return .ignored));
    if (sc.rt.is_disabled) return .ignored;
    switch (event) {
        .click => {
            // End preview first and redraw: if proposal unchanged (clicked current score), view
            // effect won't run again
            sc.rt.setHover(null);
            sc.rt.propose(@floatFromInt(sc.index + 1));
            return .stop;
        },
        .mouse_enter => {
            sc.rt.setHover(@floatFromInt(sc.index + 1));
            return .stop;
        },
        .mouse_leave => {
            sc.rt.setHover(null);
            return .stop;
        },
        else => {},
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

// ========== Tests ==========

fn runtimeOf(r: RateResult) *RateRuntime {
    return @ptrCast(@alignCast(r.wrapper.behavior.events.key_context.?));
}

fn starLit(r: RateResult, i: usize, t: *const core.ThemeTokens) bool {
    const ic = r.wrapper.children.items[i].children.items[0].getIcon().?;
    return Color.eql(ic.tint, styles.starColor(true, t));
}

test "Rate: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 3 }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(@as(usize, 5), result.wrapper.children.items.len);
    try std.testing.expectEqual(@as(f32, 3), result.value.?.peek());
}

test "Rate: 默认用实心星图标（不再是 \"*\" 文本），亮/灭按 tint 区分" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
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
    // External write must really change icon tint.
    result.value.?.set(4);
    const lit = result.wrapper.children.items[3].children.items[0].getIcon().?;
    try std.testing.expectEqual(styles.starColor(true, ctx.tokens), lit.tint);
}

test "Rate: click changes value" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 0 }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // Simulate clicking 3rd star
    const star3 = result.wrapper.children.items[2];
    if (star3.behavior.events.on_event) |handler| {
        _ = handler(.{ .click = .{ .x = 0, .y = 0 } }, star3.behavior.events.event_context);
    }

    try std.testing.expectEqual(@as(f32, 3), result.value.?.peek());
}

test "Rate: disabled" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 4, .disabled = true }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // When disabled, click doesn't change score
    const star = result.wrapper.children.items[0];
    try std.testing.expectEqual(EventResult.ignored, star.behavior.events.on_event.?(.{ .click = .{ .x = 0, .y = 0 } }, star.behavior.events.event_context));
    try std.testing.expectEqual(@as(f32, 4), result.value.?.peek());
}

test "Rate: 方向键调分 + clamp + on_change" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var change_count: u32 = 0;
    const on_change = ctx.on(u32, &change_count, struct {
        fn cb(c: *u32, _: f32) void {
            c.* += 1;
        }
    }.cb);

    const result = try Rate(.{ .count = 5, .value = 4, .on_change = on_change }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const node = result.wrapper;
    try std.testing.expect(node.behavior.events.on_key_down != null);
    const kh = node.behavior.events.on_key_down.?;
    const kctx = node.behavior.events.key_context;

    // Right/Up increment
    try std.testing.expectEqual(EventResult.handled, kh(.right, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 5), result.value.?.peek());
    // Clamp to max: value unchanged, no on_change trigger
    try std.testing.expectEqual(EventResult.handled, kh(.up, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 5), result.value.?.peek());
    try std.testing.expectEqual(@as(u32, 1), change_count);

    // Left/Down decrement
    try std.testing.expectEqual(EventResult.handled, kh(.left, .{}, kctx));
    try std.testing.expectEqual(EventResult.handled, kh(.down, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 3), result.value.?.peek());
    try std.testing.expectEqual(@as(u32, 3), change_count);

    // Clamp to 0
    result.value.?.set(0);
    try std.testing.expectEqual(EventResult.handled, kh(.down, .{}, kctx));
    try std.testing.expectEqual(@as(f32, 0), result.value.?.peek());

    // Unrelated key ignored
    try std.testing.expectEqual(EventResult.ignored, kh(.a, .{}, kctx));
}

test "Rate: disabled 不响应键盘、不可聚焦" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Rate(.{ .count = 5, .value = 2, .disabled = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(EventResult.ignored, onRateKey(.right, .{}, result.wrapper.behavior.events.key_context));
    try std.testing.expect(!result.wrapper.behavior.interaction.focusable);
}

test "Rate: bound value — external writes are displayed clamped and not written back" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const score = try scope.createSignal(f32, 2);
    const result = try Rate(.{ .count = 5, .value = score }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    try std.testing.expect(starLit(result, 1, ctx.tokens) and !starLit(result, 2, ctx.tokens));
    score.set(99);
    try std.testing.expectEqual(@as(f32, 5), runtimeOf(result).shown);
    try std.testing.expectEqual(@as(f32, 99), score.peek());
    try std.testing.expect(starLit(result, 4, ctx.tokens));
    try std.testing.expectEqual(@as(f32, 5), result.wrapper.behavior.interaction.a11y.?.value_now);
}

test "Rate: hover previews without touching the value; clicking the current score clears the preview" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const score = try scope.createSignal(f32, 2);
    var changes: u32 = 0;
    const result = try Rate(.{ .count = 5, .value = score, .on_change = ctx.on(u32, &changes, struct {
        fn cb(c: *u32, _: f32) void {
            c.* += 1;
        }
    }.cb) }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    const star = struct {
        fn send(r: RateResult, i: usize, e: Event) void {
            const n = r.wrapper.children.items[i];
            _ = n.behavior.events.on_event.?(e, n.behavior.events.event_context);
        }
    }.send;
    star(result, 3, .{ .mouse_enter = {} });
    try std.testing.expect(starLit(result, 3, ctx.tokens));
    try std.testing.expectEqual(@as(f32, 2), score.peek());
    try std.testing.expectEqual(@as(f32, 2), result.wrapper.behavior.interaction.a11y.?.value_now);
    score.set(1); // External change during preview: a11y speaks landed value, not preview
    try std.testing.expectEqual(@as(f32, 1), result.wrapper.behavior.interaction.a11y.?.value_now);
    score.set(2);
    star(result, 1, .{ .click = .{ .x = 0, .y = 0 } }); // Click on current score: doesn't land
    try std.testing.expectEqual(@as(u32, 0), changes);
    try std.testing.expect(!starLit(result, 3, ctx.tokens)); // Preview ended
    star(result, 4, .{ .click = .{ .x = 0, .y = 0 } });
    try std.testing.expectEqual(@as(f32, 5), score.peek());
    try std.testing.expectEqual(@as(u32, 1), changes);
}

test "Rate: dynamic disabled" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const off = try scope.createSignal(bool, false);
    const result = try Rate(.{ .count = 5, .value = 1, .disabled = off }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    try std.testing.expect(result.wrapper.behavior.interaction.focusable);
    off.set(true);
    try std.testing.expect(!result.wrapper.behavior.interaction.focusable);
    try std.testing.expect(result.wrapper.behavior.interaction.a11y.?.readonly);
    try std.testing.expect(!setA11yRateValue(runtimeOf(result), 4));
    off.set(false);
    try std.testing.expect(setA11yRateValue(runtimeOf(result), 4));
    try std.testing.expectEqual(@as(f32, 4), result.value.?.peek());
}

test "rate: 动态值 / disabled 的 mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("rate(dynamic)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const v = try scope.createSignal(f32, 3);
            const off = try scope.createSignal(bool, false);
            return (try Rate(.{ .count = 5, .value = v, .disabled = off }).mount(scope, cx)).wrapper;
        }
    }.m);
}

// styles.zig test collection, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// Per-alloc OOM sweep, see src/ui/components/oom_sweep.zig
test "rate: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("rate", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Rate(.{ .count = 5, .value = 3 }).mount(scope, cx)).wrapper;
        }
    }.m);
}
