/// Spinner Component
///
/// 旋转加载动画（Material Design circular progress 风格）
///
/// 完全复现 MUI CircularProgress 的 keyframe 动画：
///
/// 每个 1.4s 周期内（84帧 @ 60fps）：
///   sweep(p)  = easeInOut(p) 映射 [0->MAX_SWEEP->0]（弧长先增后减）
///   offset(p) = easeInOut(p) 映射 [0->-OFFSET_MID->-OFFSET_MAX]（尾部追头部）
///   rotation  = 匀速，每周期转 270°（1.5π），跨周期累积
///
/// 坐标系：起始角从 -π/2（12点钟方向）开始
const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = @import("../../reactive.zig").Scope;
const render_engine = @import("../../core/render_engine/mod.zig");
const DrawContext = render_engine.DrawContext;

/// Spinner 属性
pub const SpinnerProps = struct {
    /// 外径（逻辑像素）
    size: f32 = 20,
    /// 线宽
    stroke_width: f32 = 3,
    /// 弧线颜色（null = 使用主题 accent 色）
    color: ?Color = null,
};

/// Spinner 内部动画状态
pub const SpinnerState = struct {
    /// 当前周期内的相位时间（秒）
    phase_seconds: f32 = 0,
    /// 连续累计的旋转角（弧度）
    rotation_angle: f32 = 0,
    /// 弧线颜色
    color: Color,
    /// 外径
    outer_radius: f32,
    /// 线宽
    stroke_width: f32,
};

/// 动画周期：1.4 秒
const CYCLE_SECONDS: f32 = 1.4;

/// MUI CircularProgress keyframe 参数
/// circumference ≈ 2π * r（r=20.2px in MUI），对应 2π 弧度
/// dasharray: 1->100->1 px，归一化到 [0, 2π]
const MAX_SWEEP: f32 = (100.0 / 126.92) * 2.0 * math.pi; // ≈ 4.95 rad
const MIN_SWEEP: f32 = (1.0 / 126.92) * 2.0 * math.pi; // ≈ 0.05 rad（防止完全消失）
/// dashoffset: 0 -> -15 -> -126 px，归一化到弧度（负号因为 offset 是向后移动）
const OFFSET_MID: f32 = (15.0 / 126.92) * 2.0 * math.pi; // 0.74 rad
const OFFSET_MAX: f32 = (126.0 / 126.92) * 2.0 * math.pi; // ≈ 6.24 rad ≈ 2π
/// MUI 每周期整体旋转：270° = 1.5π
const ROT_PER_CYCLE: f32 = 1.5 * math.pi;
const ROT_PER_SECOND: f32 = ROT_PER_CYCLE / CYCLE_SECONDS;

/// ease-in-out cubic（CSS ease-in-out 近似，smoothstep）
inline fn easeInOut(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

/// sweep(p)：弧长随周期内进度的变化
/// p ∈ [0,1]，sweep ∈ [MIN_SWEEP, MAX_SWEEP, MIN_SWEEP]
/// 前半段增长，后半段缩短，都用 easeInOut
inline fn sweepAt(p: f32) f32 {
    // 前半：0->1（增长），后半：1->0（缩短），三角波 * ease
    const tri = if (p < 0.5) p * 2.0 else (1.0 - p) * 2.0;
    const e_tri = easeInOut(tri);
    return MIN_SWEEP + e_tri * (MAX_SWEEP - MIN_SWEEP);
}

/// tail_offset(p)：尾部相对于头部的偏移角（始终 >= 0，从尾到头）
/// p ∈ [0,1]，offset ∈ [OFFSET_MID -> OFFSET_MAX -> 2π(wrap)]
/// 这个值加到尾部角度上，使弧变短
inline fn tailOffsetAt(p: f32) f32 {
    // MUI：dashoffset 从 0 到 -15px（前半），再到 -126px（后半）
    // 即：tail 从 head 起点向后偏移（弧缩短），easeInOut 两段
    if (p < 0.5) {
        // 前半：offset 从 0 增到 OFFSET_MID
        return easeInOut(p * 2.0) * OFFSET_MID;
    } else {
        // 后半：offset 从 OFFSET_MID 增到 OFFSET_MAX
        return OFFSET_MID + easeInOut((p - 0.5) * 2.0) * (OFFSET_MAX - OFFSET_MID);
    }
}

/// 创建 Spinner
pub fn Spinner(props: SpinnerProps) SpinnerBuilder {
    return SpinnerBuilder{ .props = props };
}

pub const SpinnerBuilder = struct {
    props: SpinnerProps,

    pub fn size(self: SpinnerBuilder, s: f32) SpinnerBuilder {
        var new = self;
        new.props.size = s;
        return new;
    }

    pub fn strokeWidth(self: SpinnerBuilder, w: f32) SpinnerBuilder {
        var new = self;
        new.props.stroke_width = w;
        return new;
    }

    pub fn color(self: SpinnerBuilder, c: Color) SpinnerBuilder {
        var new = self;
        new.props.color = c;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: SpinnerBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        // 绑定成功之前 my_scope 无人持有（与 Tag.mount 同一套守卫）。
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const arc_color = p.color orelse t.color.accent;

        // 容器节点：固定大小，无背景
        const container = try box(cx, .{
            .width = .{ .px = p.size },
            .height = .{ .px = p.size },
        }, .{});
        container.meta.ownership.meta.component_name = "Spinner";
        container.behavior.interaction.a11y = .{ .role = .progressbar };
        // 游离节点的守卫，到 return 为止都不能解除：下面 ensureExt / create /
        // adoptResource 全可失败。freeNode 会顺带 dispose 绑定的 my_scope。
        errdefer cx.freeNode(container);
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;
        const spinner_ext = try container.style.ensureExtFallible(allocator);
        spinner_ext.hit_shape = .{
            .ring_arc = .{
                .outer_radius = p.size / 2.0,
                .inner_radius = @max(@as(f32, 0), p.size / 2.0 - p.stroke_width),
                .start_angle = 0,
                .end_angle = std.math.tau,
            },
        };

        // 动画状态，用 my_scope.allocator 建：adoptResource / dispose 都拿 scope 的
        // allocator 去 destroy，两边必须同源（交叉审查指出 cx.allocator 不保证等于它）。
        const state = try my_scope.allocator.create(SpinnerState);
        state.* = .{
            .color = arc_color,
            .outer_radius = p.size / 2.0,
            .stroke_width = p.stroke_width,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*SpinnerState, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);

        container.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
        container.meta.per_frame.hooks.before_render.main = spinnerBeforeRender;
        container.setCustomDraw(spinnerDraw, @ptrCast(state));

        return container;
    }
};

// ========== 动画 tick ==========

/// 从绝对时间戳直接计算 spinner 相位和旋转角，零累积误差。
fn advanceSpinnerState(state: *SpinnerState, now_ms: f64) void {
    const cycle_ms: f64 = CYCLE_SECONDS * 1000.0;
    const now_in_cycle = @mod(now_ms, cycle_ms);
    state.phase_seconds = @as(f32, @floatCast(now_in_cycle / 1000.0));
    // 旋转角：now_ms * 旋转速率，取模 2π
    const rot_per_ms: f64 = @as(f64, ROT_PER_SECOND) / 1000.0;
    state.rotation_angle = @as(f32, @floatCast(@mod(now_ms * rot_per_ms, std.math.tau)));
}

fn spinnerBeforeRender(node: *Node) void {
    const state: *SpinnerState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    advanceSpinnerState(state, render_engine.current_frame_time_ms);
    // 视口外跳过重绘，避免阻止 displayLink idle-stop
    if (node.frame_state.state_bits.flags.out_of_viewport) return;
    node.markRenderDirty();
}

// ========== 自定义绘制 ==========

fn spinnerDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const state: *SpinnerState = @ptrCast(@alignCast(context orelse return));

    // 当前周期内进度 p ∈ [0, 1)
    const p = state.phase_seconds / CYCLE_SECONDS;

    // 弧长（sweep）：前半增长，后半缩短，easeInOut，范围 [MIN_SWEEP, MAX_SWEEP]
    const sweep = sweepAt(p);

    // dashoffset：弧段的起点偏移（MUI 从 0 -> -15px -> -126px，用 easeInOut）
    // 转换为角度后，负号意味着弧的起始端向后走，弧整体被"推前"
    // dash_shift 是正值，代表弧起始端向前移动了多少弧度
    const dash_shift = tailOffsetAt(p);

    // 整体旋转：匀速，每周期 270°，跨周期累积
    const base_rot = -math.pi / 2.0 + state.rotation_angle;

    // start_angle = 弧的后端（tail），沿旋转方向前进 dash_shift
    // end_angle   = start + sweep（弧的前端）
    const start_angle = base_rot + dash_shift;
    const end_angle = start_angle + sweep;

    const center_x = ctx.render_x + ctx.render_w / 2.0;
    const center_y = ctx.render_y + ctx.render_h / 2.0;
    _ = center_x;
    _ = center_y;

    if (ctx.display_list) |dl| {
        if (ctx.display_header) |header| {
            try dl.append(.{
                .arc = .{
                    .header = header,
                    .cx = ctx.local_w / 2.0,
                    .cy = ctx.local_h / 2.0,
                    .outer_radius = state.outer_radius,
                    .stroke_width = state.stroke_width,
                    .start_angle = start_angle,
                    .end_angle = end_angle,
                    .color = state.color,
                },
            });
        }
    }
}

// ========== 测试 ==========

test "Spinner: basic mount" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    try std.testing.expectEqual(@as(f32, 20), spinner.rectFromWorldOrFallback().w);
    try std.testing.expect(spinner.meta.per_frame.hooks.before_render.main != null);
    try std.testing.expect(spinner.meta.per_frame.custom_hooks.draw != null);
}

test "Spinner: custom size" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).size(40).strokeWidth(4).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    try std.testing.expectEqual(@as(f32, 40), spinner.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 40), spinner.rectFromWorldOrFallback().h);
}

test "Spinner: custom draw emits display list arc" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(120, 120);

    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    _ = ctx.render();

    var saw_arc = false;
    for (ctx.display_list.items.items) |item| {
        switch (item) {
            .arc => |arc| {
                saw_arc = true;
                try std.testing.expectEqual(spinner.id, arc.header.node_id);
                try std.testing.expect(arc.outer_radius > 0);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_arc);
}

test "Spinner: custom draw replays own content from display list" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(80, 80);

    const root = try box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    ctx.perf.display_list_own_replay_count = 0;
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    try std.testing.expect(ctx.perf.display_list_own_replay_count >= 1);

    var saw_arc = false;
    for (commands) |cmd| {
        if (cmd.kind == .path and cmd.arc_outer_radius > 0 and cmd.stroke_width > 0) {
            saw_arc = true;
            break;
        }
    }
    try std.testing.expect(saw_arc);
}

test "Spinner: animation speed follows elapsed time instead of frame count" {
    var a = SpinnerState{
        .color = Color.rgba(255, 255, 255, 255),
        .outer_radius = 10,
        .stroke_width = 3,
    };
    var b = a;

    for (0..93) |_| advanceSpinnerState(&a, 0.01);
    for (0..31) |_| advanceSpinnerState(&b, 0.03);

    try std.testing.expectApproxEqAbs(a.phase_seconds, b.phase_seconds, 0.0001);
    try std.testing.expectApproxEqAbs(a.rotation_angle, b.rotation_angle, 0.0001);
}

test "Spinner: mount 在任意分配点失败时不泄漏" {
    // 修复前 mount 有三个失败窗口，my_scope 无守卫、container 建好后
    // 无守卫（bindScopeToNode / ensureExt / create 任一失败即漏整棵游离节点）、
    // state 建好后 registerResource 失败即漏。写法照抄 scroll_area 的逐分配点 sweep。
    const t = std.testing;
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator());
        defer ctx.deinit();
        const scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer scope.dispose();
        const before = counting.alloc_index;
        _ = try Spinner(.{}).mount(scope, ctx);
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;
    for (0..total_allocs) |failure_index| {
        var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const ctx = Cx.init(failing.allocator()) catch {
                _ = gpa.deinit();
                continue;
            };
            const scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = Spinner(.{}).mount(scope, ctx);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |node| {
                ctx.freeNode(node);
            } else |_| {
                induced += 1;
            }
            scope.dispose();
            ctx.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }
    // 空转防护按比例而非绝对下限（口径同 oom_sweep.zig）：induced > 0 的门槛
    // 比实测值低三个数量级，挡不住「mount 提前 return 导致分配点坍塌」。
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ "spinner", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) std.debug.print("\n[spinner] LEAK at {d}/{d} failure points; first={?d}\n", .{ leaked, total_allocs, first_leak });
    try t.expectEqual(@as(usize, 0), leaked);
}
