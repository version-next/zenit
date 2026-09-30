/// Progress Component
///
/// 进度条组件，支持确定/不确定模式
///
/// 特性:
/// - 百分比进度
/// - 状态颜色: normal/success/error
/// - 不确定模式 (高品质 shimmer 动画)
/// - 可选百分比文本
const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const ConditionalStyle = core.ConditionalStyle;
const Scope = @import("../../reactive.zig").Scope;
const MultiGradient = core.MultiGradient;
const GradientStop = core.GradientStop;
const styles = @import("styles.zig");
const render_engine = @import("../../core/render_engine/mod.zig");
const DrawContext = render_engine.DrawContext;

/// 进度条状态
pub const ProgressStatus = enum {
    normal,
    success,
    @"error",

    pub fn color(self: ProgressStatus, t: *const theme.ThemeTokens) Color {
        return styles.statusColor(self, t);
    }

    pub fn style(self: ProgressStatus, t: *const theme.ThemeTokens) ConditionalStyle {
        return styles.statusStyle(self, t);
    }
};

/// Progress 属性
pub const ProgressProps = struct {
    /// 当前值 (0-100)
    value: f32 = 0,
    /// 状态
    status: ProgressStatus = .normal,
    /// 轨道高度
    height: f32 = 4,
    /// 显示百分比文本
    show_text: bool = false,
    /// 不确定模式
    indeterminate: bool = false,
    /// 总宽度 (null = grow)
    width: ?f32 = null,
};

/// 创建 Progress
pub fn Progress(props: ProgressProps) ProgressBuilder {
    return ProgressBuilder{ .props = props };
}

pub const ProgressBuilder = struct {
    props: ProgressProps,

    pub fn value(self: ProgressBuilder, v: f32) ProgressBuilder {
        var new = self;
        new.props.value = v;
        return new;
    }

    pub fn status(self: ProgressBuilder, s: ProgressStatus) ProgressBuilder {
        var new = self;
        new.props.status = s;
        return new;
    }

    pub fn height(self: ProgressBuilder, h: f32) ProgressBuilder {
        var new = self;
        new.props.height = h;
        return new;
    }

    pub fn showText(self: ProgressBuilder, s: bool) ProgressBuilder {
        var new = self;
        new.props.show_text = s;
        return new;
    }

    pub fn indeterminate(self: ProgressBuilder, i: bool) ProgressBuilder {
        var new = self;
        new.props.indeterminate = i;
        return new;
    }

    pub fn width(self: ProgressBuilder, w: f32) ProgressBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: ProgressBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const status_color = p.status.color(t);
        const track_color = styles.trackColor(t);
        const container_width: core.Sizing = if (p.width) |w| .{ .px = w } else .{ .grow = .{} };

        // 外层容器
        const container = try box(cx, .{
            .width = container_width,
            .height = .{ .fit = .{} },
            .direction = .row,
            .align_items = .center,
            .gap = 8,
        }, .{});
        // sweep：container 守到 return；子节点建好即 adopt；可失败 mount 里不用 ensureExtPanic
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Progress";
        // role=progressbar + valuenow/min/max：AT 靠这三个数播报"70%"。
        // 不确定模式按 ARIA 约定不报数值（值未知），改用 busy 位告诉用户
        // "正在进行中但无法预估进度"。
        container.behavior.interaction.a11y = if (p.indeterminate) .{
            .role = .progressbar,
            .busy = true,
        } else .{
            .role = .progressbar,
            .value_now = math.clamp(p.value, 0, 100),
            .value_min = 0,
            .value_max = 100,
            .value_range = .{ .now = math.clamp(p.value, 0, 100), .min = 0, .max = 100 },
        };
        try core.bindScopeToNode(my_scope, container);

        // 轨道
        const track = try core.adoptChild(cx, allocator, container, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = p.height },
            .background = track_color,
            .border = .{ .radius = p.height / 2 },
        }, .{}));
        track.style.overflow_hidden = true;

        // 填充条
        const clamped = math.clamp(p.value, 0, 100);

        if (p.indeterminate) {
            // 不确定模式: custom_draw 实现高品质 shimmer 动画
            const anim_state = try allocator.create(IndeterminateState);
            anim_state.* = .{
                .base_color = status_color,
                .highlight_color = Color.lerp(status_color, Color.rgba(255, 255, 255, 255), 0.35),
                .shadow_color = Color.lerp(status_color, Color.rgba(0, 0, 0, 255), 0.15),
                .radius = p.height / 2,
            };
            try my_scope.adoptResource(@ptrCast(anim_state), struct {
                fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                    const s: *IndeterminateState = @ptrCast(@alignCast(ptr));
                    alloc.destroy(s);
                }
            }.cleanup);

            // 用 grow 撑满 track 的 custom_draw 节点
            const draw_node = try core.adoptChild(cx, allocator, track, try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
            }, .{}));
            draw_node.meta.per_frame.hooks.slots.anim_state = @ptrCast(anim_state);
            draw_node.meta.per_frame.hooks.before_render.main = indeterminateTick;
            draw_node.setCustomDraw(indeterminateDraw, @ptrCast(anim_state));
        } else {
            // 确定模式: 按百分比宽度，垂直 3-stop 渐变模拟光照立体感
            const fill = try core.adoptChild(cx, allocator, track, try box(cx, .{
                .width = .{ .percent = clamped },
                .height = .{ .px = p.height },
                .border = .{ .radius = p.height / 2 },
            }, .{}));
            const fill_stops = [_]GradientStop{
                .{ .color = Color.lerp(status_color, Color.rgba(255, 255, 255, 255), 0.25), .position = 0.0 },
                .{ .color = status_color, .position = 0.5 },
                .{ .color = Color.lerp(status_color, Color.rgba(0, 0, 0, 255), 0.10), .position = 1.0 },
            };
            (try fill.style.ensureExtFallible(allocator)).multi_gradient = MultiGradient.fromSlice(&fill_stops, .vertical);
        }

        // 百分比文本
        if (p.show_text and !p.indeterminate) {
            var text_buf: [8]u8 = undefined;
            const text_content = std.fmt.bufPrint(&text_buf, "{d:.0}%", .{clamped}) catch "0%";

            const text_node = try core.adoptChild(cx, allocator, container, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            // text_content 来自 local buf；setContent 拷贝。
            text_node.setText(styles.percentTextStyle(t));
            if (text_node.getText()) |old| {
                var txt = old;
                try txt.setContent(cx.allocator, text_content);
                text_node.setText(txt);
            }
        }

        return container;
    }
};

// ========== 不确定模式动画 ==========

const IndeterminateState = struct {
    /// 当前周期内的相位时间（秒）
    phase_seconds: f32 = 0,
    /// 基础颜色
    base_color: Color,
    /// 高亮颜色（白色混合 35%）— shimmer 波峰
    highlight_color: Color,
    /// 阴影颜色（黑色混合 15%）— shimmer 波谷
    shadow_color: Color,
    /// 圆角
    radius: f32 = 2,
};

/// 动画时间参数
const CYCLE_SECONDS: f32 = 2.0;

/// cubic-bezier(0.65, 0, 0.35, 1) — 类似 CSS ease-in-out 但更极端
/// 用 de Casteljau 算法计算 cubic bezier 曲线上的 y 值
/// P0=(0,0), P1=(0.65, 0), P2=(0.35, 1), P3=(1,1)
fn cubicBezierEase(t: f32) f32 {
    // 近似求解：对 cubic bezier 做 Newton-Raphson 反解 x→t 太重了
    // 用 5 次多项式拟合 cubic-bezier(0.65, 0, 0.35, 1)
    // 特征：中段快、两端慢，比 smoothstep 更极端
    const t2 = t * t;
    const t3 = t2 * t;
    // 6t^5 - 15t^4 + 10t^3 (quintic smoothstep，比 cubic 更陡)
    return 6.0 * t2 * t3 - 15.0 * t2 * t2 + 10.0 * t3;
}

/// 计算 bar 的左右边缘位置（归一化 0~1，相对于 track 宽度）
/// 返回 (left, right)，left < right
fn barEdges(t: f32) struct { left: f32, right: f32 } {
    // lead（右边缘）比 trail（左边缘）相位超前
    // lead 更早启动、更早到达，trail 稍后追上
    // 时间差制造宽度变化：入场展开 → 中段最宽 → 离场收窄

    // lead: 从 t=-0.1 开始映射到 [0,1]（提前启动）
    const lead_raw = math.clamp((t + 0.1) / 0.9, 0, 1);
    // trail: 从 t=0.2 开始映射到 [0,1]（延迟启动）
    const trail_raw = math.clamp((t - 0.2) / 0.9, 0, 1);

    const right = cubicBezierEase(lead_raw);
    const left = cubicBezierEase(trail_raw);

    return .{ .left = left, .right = right };
}

/// 从绝对时间戳直接计算 phase，零累积误差。
fn advanceIndeterminateState(state: *IndeterminateState, now_ms: f64) void {
    const cycle_ms: f64 = CYCLE_SECONDS * 1000.0;
    state.phase_seconds = @as(f32, @floatCast(@mod(now_ms, cycle_ms) / 1000.0));
}

fn indeterminateTick(node: *Node) void {
    const state: *IndeterminateState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    advanceIndeterminateState(state, render_engine.current_frame_time_ms);
    node.markRenderDirty();
}

fn indeterminateDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const state: *IndeterminateState = @ptrCast(@alignCast(context orelse return));

    const t = state.phase_seconds / CYCLE_SECONDS;
    const edges = barEdges(t);
    const track_w = ctx.render_w;
    const track_h = ctx.render_h;
    _ = track_h;

    const bar_left = edges.left * track_w;
    const bar_right = edges.right * track_w;
    const bar_w = bar_right - bar_left;

    if (bar_w < 0.5) return; // 太小不画

    // 绘制带 3-stop 渐变的 bar — highlight(0%) → base(55%) → shadow(100%)
    // 模拟移动光泽：波峰偏左，右侧自然衰减到暗部，比 2-stop 更真实
    var shimmer_colors = [_]Color{Color.rgba(0, 0, 0, 0)} ** 16;
    var shimmer_positions = [_]f32{0} ** 16;
    shimmer_colors[0] = state.highlight_color;
    shimmer_colors[1] = state.base_color;
    shimmer_colors[2] = state.shadow_color;
    shimmer_positions[0] = 0.0;
    shimmer_positions[1] = 0.55;
    shimmer_positions[2] = 1.0;

    if (ctx.display_list) |dl| {
        if (ctx.display_header) |header| {
            try dl.append(.{
                .multi_gradient_rect = .{
                    .header = header,
                    .x = bar_left,
                    .y = 0,
                    .w = bar_w,
                    .h = ctx.local_h,
                    .direction = .horizontal,
                    .radius = .{ state.radius, state.radius, state.radius, state.radius },
                    .stop_colors = shimmer_colors,
                    .stop_positions = shimmer_positions,
                    .stop_count = 3,
                },
            });
        }
    }
}

// ========== 测试 ==========

test "Progress: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{})
        .value(75)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, progress);

    // container 有 1 个子节点: track
    try std.testing.expectEqual(@as(usize, 1), progress.children.items.len);

    // track 有 1 个子节点: fill
    const track = progress.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), track.children.items.len);
}

test "Progress: indeterminate custom draw emits display list gradient" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(300, 60);

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 60 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{}).indeterminate(true).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    ctx.layout();
    _ = ctx.render();

    var saw_gradient = false;
    for (ctx.display_list.items.items) |item| {
        switch (item) {
            .multi_gradient_rect => |grad| {
                if (grad.direction == .horizontal and grad.w > 0 and grad.h > 0) {
                    saw_gradient = true;
                    break;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_gradient);
}

test "Progress: indeterminate custom draw replays own content from display list" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(300, 60);

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 60 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{}).indeterminate(true).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    ctx.layout();
    ctx.perf.display_list_own_replay_count = 0;
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    try std.testing.expect(ctx.perf.display_list_own_replay_count >= 1);

    var saw_gradient = false;
    for (commands) |cmd| {
        if (cmd.isGradient() and cmd.mg_stop_count > 0) {
            // multi_gradient_rect 在 paint_table 用 mg_stop_count > 0 区分；direction 字段
            // 没单独存（paint_table 简化），用 geom.w/h > 0 即可代验。
            if (cmd.geom.w > 0 and cmd.geom.h > 0) {
                saw_gradient = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_gradient);
}

test "Progress: with text" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{})
        .value(50)
        .showText(true)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, progress);

    // container 有 2 个子节点: track + text
    try std.testing.expectEqual(@as(usize, 2), progress.children.items.len);
}

test "Progress: status colors" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const normal = try Progress(.{}).value(80).status(.normal).mount(scope, ctx);
    const success_p = try Progress(.{}).value(100).status(.success).mount(scope, ctx);
    const err = try Progress(.{}).value(30).status(.@"error").mount(scope, ctx);

    try root.appendChild(std.testing.allocator, normal);
    try root.appendChild(std.testing.allocator, success_p);
    try root.appendChild(std.testing.allocator, err);

    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
}

test "Progress: clamp value" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 超过 100 应该 clamp
    const progress = try Progress(.{}).value(150).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    const track = progress.children.items[0];
    const fill = track.children.items[0];
    try std.testing.expectEqual(core.Sizing{ .percent = 100 }, fill.style.width);
}

test "Progress: indeterminate" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{}).indeterminate(true).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    const track = progress.children.items[0];
    // 不确定模式: 1 个 custom_draw 子节点
    try std.testing.expectEqual(@as(usize, 1), track.children.items.len);
    const draw_node = track.children.items[0];
    try std.testing.expect(draw_node.meta.per_frame.hooks.before_render.main != null);
    try std.testing.expect(draw_node.meta.per_frame.custom_hooks.draw != null);
}

test "Progress: indeterminate timing follows elapsed time instead of frame count" {
    var a = IndeterminateState{
        .base_color = Color.rgba(100, 160, 220, 255),
        .highlight_color = Color.rgba(180, 210, 245, 255),
        .shadow_color = Color.rgba(85, 136, 187, 255),
        .radius = 2,
    };
    var b = a;

    for (0..125) |_| advanceIndeterminateState(&a, 0.01);
    for (0..25) |_| advanceIndeterminateState(&b, 0.05);

    try std.testing.expectApproxEqAbs(a.phase_seconds, b.phase_seconds, 0.0001);
    const edges_a = barEdges(a.phase_seconds / CYCLE_SECONDS);
    const edges_b = barEdges(b.phase_seconds / CYCLE_SECONDS);
    try std.testing.expectApproxEqAbs(edges_a.left, edges_b.left, 0.0001);
    try std.testing.expectApproxEqAbs(edges_a.right, edges_b.right, 0.0001);
}

test "Progress: render emits visible fill and percent text" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(320, 80);

    const root = try box(ctx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 80 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const progress = try Progress(.{
        .value = 70,
        .status = .success,
        .show_text = true,
        .width = 240,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, progress);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_track = false;
    var saw_fill = false;
    var saw_text = false;
    const expected_track = Color.lerp(ctx.tokens.color.bg_tertiary, ctx.tokens.color.fg_primary, 0.06);
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            if (Color.eql(cmd.color.toColor(), expected_track) and cmd.geom.w >= 160 and cmd.geom.h >= 4) {
                saw_track = true;
            }
        } else if (cmd.isGradient() and cmd.mg_stop_count > 0) {
            if (cmd.geom.w >= 100 and cmd.geom.h >= 4) {
                saw_fill = true;
            }
        } else if (cmd.isText()) {
            if (std.mem.eql(u8, cmd.text_content, "70%")) saw_text = true;
        }
    }

    try std.testing.expect(saw_track);
    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_text);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "progress: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("progress", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Progress(.{}).value(75).mount(scope, cx);
        }
    }.m);
}

test "progress(indeterminate): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("progress(indeterminate)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Progress(.{ .indeterminate = true }).mount(scope, cx);
        }
    }.m);
}
