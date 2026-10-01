//! Notification 纯逻辑层：停靠几何、堆叠几何、入场/退场曲线、计时。
//!
//! 不碰 Node，渲染层每帧把这里算出的数值写进 transform / alpha。
//! 所有时间相关量都由墙钟时间戳（born / left_at / deadline）推导，
//! 不在对象上逐帧累加：掉帧时相位不漂（设计稿 16.5 / 16.8）。
const std = @import("std");
const easing_mod = @import("../../animation/easing.zig");

// ============================================================================
// 类型
// ============================================================================

/// 一条提醒的形态（数据模型里的 kind）。
pub const Kind = enum {
    /// 图标 + 标题 + 正文（+ 可选按钮 / 回复框 / 头像）。
    default,
    /// 旋转指示器 + 确定进度条 + n / N 计数，不显示生命条。
    progress,
    /// 倒计时环（中心剩余秒数）+「撤销」按钮。
    undo,
    /// 文案提示（16.13）：36 高玻璃胶囊，只有一句话（+ 可选标记 / 键帽 / 按钮），
    /// 与卡片同一个堆叠，没有标题、时间戳、关闭钮和生命条。
    hint,
};

/// 语义色调。oklch 同明度同色度、只换色相（设计稿 16.9）。
pub const Tone = enum {
    success,
    @"error",
    warning,
    info,
    violet,
    quiet,
};

/// 八个停靠位置（设计稿 16.1）。默认 bottom_center。
pub const Position = enum(u3) {
    top_left,
    top_center,
    top_right,
    right_center,
    bottom_right,
    bottom_center,
    bottom_left,
    left_center,

    /// 堆叠增长方向的符号：顶部锚点 +1（向下长）、底部 −1（向上长）、
    /// 两侧中点 +1（向下长，整体保持垂直居中）。
    pub fn sign(self: Position) f32 {
        return switch (self) {
            .bottom_left, .bottom_center, .bottom_right => -1,
            else => 1,
        };
    }

    pub const HAlign = enum { left, center, right };

    pub fn hAlign(self: Position) HAlign {
        return switch (self) {
            .top_left, .bottom_left, .left_center => .left,
            .top_center, .bottom_center => .center,
            .top_right, .bottom_right, .right_center => .right,
        };
    }

    pub const VAnchor = enum { top, bottom, middle };

    pub fn vAnchor(self: Position) VAnchor {
        return switch (self) {
            .top_left, .top_center, .top_right => .top,
            .bottom_left, .bottom_center, .bottom_right => .bottom,
            .left_center, .right_center => .middle,
        };
    }

    /// 入场初始位移（窗口坐标，px）。上下锚点走 Y 轴，左右中点走 X 轴。
    pub fn entryOffset(self: Position, distance: f32) struct { x: f32, y: f32 } {
        return switch (self) {
            .top_left, .top_center, .top_right => .{ .x = 0, .y = -distance },
            .bottom_left, .bottom_center, .bottom_right => .{ .x = 0, .y = distance },
            .right_center => .{ .x = distance, .y = 0 },
            .left_center => .{ .x = -distance, .y = 0 },
        };
    }

    /// 允许的甩出方向：左侧只能向左、右侧只能向右、居中两侧皆可。
    /// 返回 −1 / +1 / 0（0 = 两侧皆可）。
    pub fn flingDirection(self: Position) f32 {
        return switch (self.hAlign()) {
            .left => -1,
            .right => 1,
            .center => 0,
        };
    }

    /// 角标（StackPill）贴在堆叠的哪一侧：true = 视觉上方。
    /// 顶部锚点贴下方；底部锚点与两侧中点贴上方（设计稿 16.1 表）。
    pub fn pillAbove(self: Position) bool {
        return switch (self.vAnchor()) {
            .top => false,
            .bottom, .middle => true,
        };
    }
};

// ============================================================================
// 规范常量（设计稿 16.2 / 16.4 / 16.5 / 16.7）
// ============================================================================

pub const Spec = struct {
    pub const card_width: f32 = 392;
    pub const edge_inset: f32 = 22;
    pub const stack_gap: f32 = 9;
    pub const peek: f32 = 9;
    pub const collapsed_scale_step: f32 = 0.038;
    pub const collapsed_scale_max_steps: f32 = 3;
    pub const collapsed_visible_layers: f32 = 3;
    pub const hover_slop: f32 = 18;
    pub const max_on_screen: usize = 6;
    pub const default_max_visible: u8 = 4;

    // 动效取「干净利落」：短、强减速、小位移，不做分层错峰和图标回弹。
    pub const enter_ms: f64 = 300;
    pub const enter_distance: f32 = 10;
    pub const enter_scale_from: f32 = 0.98;
    /// 透明度在入场前 55% 的时间里走完，避免半透明残影拖尾。
    pub const enter_fade_portion: f32 = 0.55;
    /// 内容分层错峰：间隔压到 20ms 级、每层 220ms、位移 4px，最后一层（60 + 220 = 280ms）
    /// 与卡片本体 300ms 的入场同时收尾，错峰感还在，整体时长不拉长。
    pub const stagger_ms: f64 = 220;
    pub const stagger_offset: f32 = 4;
    pub const title_delay_ms: f64 = 20;
    pub const body_delay_ms: f64 = 40;
    pub const progress_delay_ms: f64 = 50;
    pub const footer_delay_ms: f64 = 60;
    /// 入场后这段时间内不加重排过渡（逐帧驱动与过渡不能叠加）。
    pub const young_ms: f64 = 380;

    pub const exit_ms: f64 = 200;
    pub const exit_scale_loss: f32 = 0.03;
    pub const exit_drift: f32 = 4;
    pub const exit_fling_gain: f32 = 1.1;

    pub const reflow_ms: f64 = 300;
    pub const expand_ms: f64 = 320;
    pub const icon_pop_ms: f64 = 240;
    pub const crossfade_ms: f64 = 160;
    /// 「全部清除」圆钮展开 / 收回。
    pub const clear_reveal_ms: f64 = 200;
    pub const close_fade_ms: f64 = 140;

    pub const swipe_threshold: f32 = 84;
    pub const swipe_fling: f32 = 70;
    pub const swipe_fade_span: f32 = 190;
    pub const swipe_min_alpha: f32 = 0.25;

    /// 玻璃密度 A：与编辑器浮条（media_glass）同一档白玻璃；折叠在后面的层更实。
    pub const glass_front: f32 = 0.55;
    pub const glass_depth_gain: f32 = 0.13;
    pub const glass_quiet: f32 = 0.50;
};

/// 各类型默认停留时长（ms）。null = 常驻（sticky）。设计稿 16.2。
pub const Durations = struct {
    pub const success: u32 = 3600;
    pub const warning: u32 = 5600;
    pub const progress_done: u32 = 3400;
    pub const undo: u32 = 7000;
    pub const quiet: u32 = 2800;
    pub const info: u32 = 4200;
    pub const accept_settle: u32 = 2600;
    pub const reply_settle: u32 = 2200;
    pub const undo_settle: u32 = 2400;
    pub const retry_progress: u32 = 5200;
};

/// 文案提示（16.13）默认停留时长；进行中常驻。
pub const HintDurations = struct {
    /// 纯文案 / 成功。
    pub const plain: u32 = 2000;
    /// 失败 / 快捷键。
    pub const emphasis: u32 = 3000;
    /// 可撤销（带按钮）。
    pub const action: u32 = 4000;
};

// ============================================================================
// 缓动
// ============================================================================

pub fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// easeOutCubic = 1 − (1−p)³，统一缓动（16.5）。
pub fn easeOutCubic(p: f32) f32 {
    const q = 1 - clamp01(p);
    return 1 - q * q * q;
}

/// 重排曲线 cubic-bezier(.22,.92,.24,1)。
pub fn reflowEase(p: f32) f32 {
    return easing_mod.Easing.cubicBezier(0.22, 0.92, 0.24, 1).apply(clamp01(p));
}

/// 进度（0..1），elapsed < 0（尚未开始 / 延迟中）返回 0。
pub fn progressOf(elapsed_ms: f64, duration_ms: f64) f32 {
    if (duration_ms <= 0) return 1;
    return clamp01(@floatCast(elapsed_ms / duration_ms));
}

// ============================================================================
// 入场 / 退场 / 分层错峰
// ============================================================================

pub const Motion = struct {
    /// 沿入场轴的位移乘数（0 = 就位；1 = 满 22px 初始位移）。
    offset: f32 = 0,
    scale: f32 = 1,
    alpha: f32 = 1,
};

/// 强减速（≈ easeOutExpo）：起步快、收尾干净，没有拖尾。
pub fn enterEase(p: f32) f32 {
    return easing_mod.Easing.cubicBezier(0.16, 1, 0.3, 1).apply(clamp01(p));
}

/// 卡片本体入场：translate 10->0 · scale .98->1，300ms 强减速；alpha 在前 55% 走完。
pub fn enterMotion(elapsed_ms: f64) Motion {
    const raw = progressOf(elapsed_ms, Spec.enter_ms);
    const p = enterEase(raw);
    return .{
        .offset = 1 - p,
        .scale = lerp(Spec.enter_scale_from, 1, p),
        .alpha = easeOutCubic(clamp01(raw / Spec.enter_fade_portion)),
    };
}

/// 分层元素（标题行 / 正文 / 进度区 / 按钮区）：延迟后跑 440ms，位移 8px + alpha。
pub fn staggerMotion(elapsed_ms: f64, delay_ms: f64) struct { offset: f32, alpha: f32 } {
    const p = easeOutCubic(progressOf(elapsed_ms - delay_ms, Spec.stagger_ms));
    return .{ .offset = (1 - p) * Spec.stagger_offset, .alpha = p };
}

/// 图标出现：scale .9->1，不过冲、不旋转（原地转换换图标时复用）。
pub fn iconPop(elapsed_ms: f64, duration_ms: f64) struct { scale: f32, rotate_deg: f32 } {
    const p = enterEase(progressOf(elapsed_ms, duration_ms));
    return .{ .scale = lerp(0.9, 1, p), .rotate_deg = 0 };
}

pub const ExitMotion = struct {
    alpha: f32,
    scale: f32,
    /// 沿堆叠增长方向的漂移（px，未乘符号）。
    drift: f32,
    /// 高度贡献系数：后续卡片据此连续补位。
    weight: f32,
    /// 甩出位移倍数（仅拖拽触发时非零位移才有意义）。
    fling_gain: f32,
    done: bool,
};

/// 退场 200ms：alpha (1−p)^1.6、scale ×(1−0.03p)、漂移 4px、
/// 高度贡献按 easeOutCubic 收到 0（下面的卡片先快后慢地补位）、甩出 flingX×(1+1.1p)。
pub fn exitMotion(elapsed_ms: f64) ExitMotion {
    const p = progressOf(elapsed_ms, Spec.exit_ms);
    return .{
        .alpha = std.math.pow(f32, 1 - p, 1.6),
        .scale = 1 - Spec.exit_scale_loss * p,
        .drift = Spec.exit_drift * p,
        .weight = 1 - easeOutCubic(p),
        .fling_gain = 1 + Spec.exit_fling_gain * p,
        .done = p >= 1,
    };
}

/// 拖拽中的透明度：max(0.25, 1 − |dx| / 190)。
pub fn swipeAlpha(dx: f32) f32 {
    return @max(Spec.swipe_min_alpha, 1 - @abs(dx) / Spec.swipe_fade_span);
}

/// 把拖拽位移按位置约束到允许方向；反方向做 0.2 的橡皮筋阻尼。
pub fn constrainSwipe(position: Position, dx: f32) f32 {
    const dir = position.flingDirection();
    if (dir == 0) return dx;
    if (dx * dir >= 0) return dx;
    return dx * 0.2;
}

/// 松手判定：越过 84px 阈值（且方向允许）即关闭并甩出。
pub fn swipeCommits(position: Position, dx: f32) bool {
    if (@abs(dx) < Spec.swipe_threshold) return false;
    const dir = position.flingDirection();
    return dir == 0 or dx * dir > 0;
}

// ============================================================================
// 堆叠几何（16.4）
// ============================================================================

/// 堆叠求解的单条输入：按层序（0 = 最新、最靠近锚点）排列。
pub const StackInput = struct {
    /// 卡片自然高度（未裁切）。
    height: f32,
    /// 卡片自然宽度（卡片恒为满宽；文案提示胶囊随内容）。0 = 不参与宽度收拢。
    width: f32 = 0,
    /// 高度贡献权重：常态 1；退场中 1−p，连续收到 0。
    weight: f32 = 1,
    /// 退场中的卡片不作为「最前那张」的裁切参照。
    leaving: bool = false,
    quiet: bool = false,
};

/// 单条输出：均相对锚点边，渲染层再换算到窗口坐标。
pub const StackOutput = struct {
    /// 卡片近锚点边离锚点的距离（沿增长方向，≥0）。
    offset: f32,
    /// 可见高度（折叠态被裁到最前那张的高度）。
    clip_height: f32,
    /// 可见宽度：折叠态后层收拢到最前那张的宽度（胶囊宽度不一时不从侧面露出），
    /// 展开时按展开进度恢复自身宽度。
    clip_width: f32 = 0,
    scale: f32,
    /// 玻璃密度 A（背景 alpha）。
    glass_alpha: f32,
    /// 内容层 alpha：折叠态非最前层为 0，否则 9px 露边会切出半截文字。
    content_alpha: f32,
    /// 整卡可见度：折叠态第 4 层起 0；展开态超过 max_visible 为 0。
    visibility: f32,
    /// 连续层深（Σ 前面各卡片权重）。
    depth: f32,
};

pub const StackParams = struct {
    /// 展开进度 0 = 折叠，1 = 展开。
    expand: f32 = 0,
    max_visible: u8 = Spec.default_max_visible,
};

/// 按「锚点 + 符号」单一几何求解整组堆叠。
/// 折叠 offset = 9 × depth；展开 offset = Σ(前面卡片高度 + 9) × 权重；两态按 expand 插值。
pub fn solveStack(inputs: []const StackInput, params: StackParams, out: []StackOutput) void {
    std.debug.assert(out.len >= inputs.len);
    const e = clamp01(params.expand);

    // 折叠态的裁切参照：最前一张非退场卡片的高度与宽度。
    var front_height: f32 = 0;
    var front_width: f32 = 0;
    for (inputs) |in| {
        if (!in.leaving) {
            front_height = in.height;
            front_width = in.width;
            break;
        }
    } else if (inputs.len > 0) {
        front_height = inputs[0].height;
        front_width = inputs[0].width;
    }

    var depth: f32 = 0;
    var expanded_offset: f32 = 0;
    const max_visible: f32 = @floatFromInt(@max(params.max_visible, 1));
    for (inputs, 0..) |in, i| {
        const collapsed_offset = Spec.peek * depth;
        const offset = lerp(collapsed_offset, expanded_offset, e);

        const depth1 = @min(depth, 1);
        const collapsed_scale = 1 - @min(depth, Spec.collapsed_scale_max_steps) * Spec.collapsed_scale_step;
        const base_alpha: f32 = if (in.quiet) Spec.glass_quiet else Spec.glass_front;
        const collapsed_glass = @min(1, base_alpha + depth1 * Spec.glass_depth_gain);
        const collapsed_clip = lerp(in.height, front_height, depth1);
        const collapsed_width = if (in.width > 0 and front_width > 0) lerp(in.width, front_width, depth1) else in.width;
        const collapsed_content = 1 - depth1;
        const collapsed_vis = clamp01(Spec.collapsed_visible_layers - depth);
        const expanded_vis = clamp01(max_visible - depth);

        out[i] = .{
            .offset = offset,
            .clip_height = lerp(collapsed_clip, in.height, e),
            .clip_width = lerp(collapsed_width, in.width, e),
            .scale = lerp(collapsed_scale, 1, e),
            .glass_alpha = lerp(collapsed_glass, base_alpha, e),
            .content_alpha = lerp(collapsed_content, 1, e),
            .visibility = lerp(collapsed_vis, expanded_vis, e),
            .depth = depth,
        };

        const w = clamp01(in.weight);
        depth += w;
        expanded_offset += (in.height + Spec.stack_gap) * w;
    }
}

/// 整组堆叠沿增长方向的外沿（最远那张卡片的远边），角标与悬停外接矩形用。
pub fn stackExtent(outputs: []const StackOutput) f32 {
    var extent: f32 = 0;
    for (outputs) |o| {
        if (o.visibility <= 0.01) continue;
        extent = @max(extent, o.offset + o.clip_height);
    }
    return extent;
}

// ============================================================================
// 计时（生命周期）
// ============================================================================

/// 剩余寿命：deadline 模型。暂停时冻结 remaining，恢复时按当前时刻重设 deadline。
pub const Life = struct {
    /// 初始时长（ms）；0 = 常驻。
    duration_ms: f64 = 0,
    /// 运行中时的截止时刻（帧时钟 ms）。
    deadline_ms: f64 = 0,
    /// 暂停时冻结的剩余时长。
    frozen_remaining_ms: ?f64 = null,

    pub fn sticky() Life {
        return .{};
    }

    pub fn start(duration_ms: f64, now_ms: f64) Life {
        return .{ .duration_ms = duration_ms, .deadline_ms = now_ms + duration_ms };
    }

    pub fn isSticky(self: Life) bool {
        return self.duration_ms <= 0;
    }

    pub fn remaining(self: Life, now_ms: f64) f64 {
        if (self.isSticky()) return std.math.inf(f64);
        if (self.frozen_remaining_ms) |r| return r;
        return @max(0, self.deadline_ms - now_ms);
    }

    /// 剩余比例（生命条 / 倒计时环），常驻恒 1。
    pub fn fraction(self: Life, now_ms: f64) f32 {
        if (self.isSticky()) return 1;
        return clamp01(@floatCast(self.remaining(now_ms) / self.duration_ms));
    }

    pub fn pause(self: *Life, now_ms: f64) void {
        if (self.isSticky() or self.frozen_remaining_ms != null) return;
        self.frozen_remaining_ms = self.remaining(now_ms);
    }

    pub fn @"resume"(self: *Life, now_ms: f64) void {
        const r = self.frozen_remaining_ms orelse return;
        self.frozen_remaining_ms = null;
        self.deadline_ms = now_ms + r;
    }

    pub fn expired(self: Life, now_ms: f64) bool {
        if (self.isSticky()) return false;
        return self.remaining(now_ms) <= 0;
    }
};

// ============================================================================
// 重排过渡：目标跳变时 540ms 补间，逐帧驱动期间直接跟随目标
// ============================================================================

pub const Follow = struct {
    value: f32 = 0,
    from: f32 = 0,
    target: f32 = 0,
    start_ms: f64 = 0,
    active: bool = false,
    initialized: bool = false,

    /// continuous = true 时（有卡片在退场 / 本卡入场未满 620ms / 正在展开折叠），
    /// 直接跟随逐帧目标，过渡与逐帧驱动不能叠加。否则目标跳变启动 540ms 补间。
    pub fn step(self: *Follow, target: f32, now_ms: f64, continuous: bool) f32 {
        if (!self.initialized or continuous) {
            self.* = .{ .value = target, .from = target, .target = target, .initialized = true };
            return target;
        }
        if (@abs(target - self.target) > 0.25) {
            self.from = self.value;
            self.target = target;
            self.start_ms = now_ms;
            self.active = true;
        }
        if (self.active) {
            const p = progressOf(now_ms - self.start_ms, Spec.reflow_ms);
            self.value = lerp(self.from, self.target, reflowEase(p));
            if (p >= 1) {
                self.value = self.target;
                self.active = false;
            }
        } else {
            self.value = self.target;
        }
        return self.value;
    }

    /// 锚点整体平移（窗口尺寸变化）：当前值、补间起点与目标一起移动，
    /// 进行中的重排补间继续走而不重新起跳。窗口变化是刚性位移，不是重排,
    /// 若当成目标跳变去补间，普通 resize 会拖尾，live resize 里（拖动停住后
    /// AppKit 不再出帧）更会卡在半路直到松手（堆叠掉出窗口底部）。
    pub fn shift(self: *Follow, delta: f32) void {
        if (!self.initialized) return;
        self.value += delta;
        self.from += delta;
        self.target += delta;
    }
};

// ============================================================================
// 时间戳文案
// ============================================================================

pub const RelativeTime = union(enum) {
    now,
    minutes: u32,
    hours: u32,
    days: u32,
};

pub fn relativeTime(elapsed_ms: i64) RelativeTime {
    const s = @divTrunc(@max(elapsed_ms, 0), 1000);
    if (s < 60) return .now;
    const m = @divTrunc(s, 60);
    if (m < 60) return .{ .minutes = @intCast(m) };
    const h = @divTrunc(m, 60);
    if (h < 24) return .{ .hours = @intCast(h) };
    return .{ .days = @intCast(@divTrunc(h, 24)) };
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "Position: sign / entry / fling / pill follow the 16.1 table" {
    try testing.expectEqual(@as(f32, -1), Position.bottom_center.sign());
    try testing.expectEqual(@as(f32, 1), Position.top_left.sign());
    try testing.expectEqual(@as(f32, 1), Position.left_center.sign());
    try testing.expectEqual(@as(f32, 22), Position.bottom_right.entryOffset(22).y);
    try testing.expectEqual(@as(f32, -22), Position.top_center.entryOffset(22).y);
    try testing.expectEqual(@as(f32, 22), Position.right_center.entryOffset(22).x);
    try testing.expectEqual(@as(f32, -22), Position.left_center.entryOffset(22).x);
    try testing.expectEqual(@as(f32, -1), Position.bottom_left.flingDirection());
    try testing.expectEqual(@as(f32, 0), Position.top_center.flingDirection());
    try testing.expect(!Position.top_right.pillAbove());
    try testing.expect(Position.bottom_center.pillAbove());
    try testing.expect(Position.right_center.pillAbove());
}

test "solveStack: collapsed geometry — 9px peek, width steps, clipped to front, content hidden" {
    const inputs = [_]StackInput{ .{ .height = 70 }, .{ .height = 124 }, .{ .height = 90 }, .{ .height = 80 } };
    var out: [4]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 0 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 9), out[1].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 18), out[2].offset, 1e-4);
    // 后层裁到最前那张的高度，露边等宽等高。
    try testing.expectApproxEqAbs(@as(f32, 70), out[1].clip_height, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 70), out[2].clip_height, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - 0.038), out[1].scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - 3 * 0.038), out[3].scale, 1e-4);
    try testing.expectApproxEqAbs(Spec.glass_front, out[0].glass_alpha, 1e-4);
    try testing.expectApproxEqAbs(Spec.glass_front + Spec.glass_depth_gain, out[1].glass_alpha, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), out[0].content_alpha, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1].content_alpha, 1e-4);
    // 第 4 层起不可见，交给角标。
    try testing.expectApproxEqAbs(@as(f32, 1), out[2].visibility, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[3].visibility, 1e-4);
}

test "solveStack: expanded geometry — real heights, gap 9, glass back to 0.84" {
    const inputs = [_]StackInput{ .{ .height = 70 }, .{ .height = 124 }, .{ .height = 90 }, .{ .height = 80 }, .{ .height = 60 } };
    var out: [5]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 1, .max_visible = 4 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 79), out[1].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 79 + 133), out[2].offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 124), out[1].clip_height, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), out[3].scale, 1e-4);
    try testing.expectApproxEqAbs(Spec.glass_front, out[2].glass_alpha, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), out[3].visibility, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[4].visibility, 1e-4);
}

test "solveStack: a leaving middle card collapses its height contribution continuously" {
    var inputs = [_]StackInput{ .{ .height = 70 }, .{ .height = 100 }, .{ .height = 80 } };
    var out: [3]StackOutput = undefined;
    var prev: f32 = std.math.inf(f32);
    var p: f32 = 0;
    while (p <= 1.0001) : (p += 0.05) {
        inputs[1].weight = 1 - p;
        inputs[1].leaving = true;
        solveStack(&inputs, .{ .expand = 1 }, &out);
        // 下方那张单调、连续地补位：每步跳变不超过 (100+9)×0.05。
        try testing.expect(out[2].offset <= prev + 1e-3);
        if (prev != std.math.inf(f32)) try testing.expect(prev - out[2].offset <= 109 * 0.05 + 1e-3);
        prev = out[2].offset;
    }
    try testing.expectApproxEqAbs(@as(f32, 79), out[2].offset, 1e-3);
}

test "solveStack: leaving front card does not become the collapsed clip reference" {
    const inputs = [_]StackInput{ .{ .height = 140, .leaving = true, .weight = 0.5 }, .{ .height = 70 }, .{ .height = 90 } };
    var out: [3]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 0 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 70), out[2].clip_height, 1e-4);
}

test "solveStack: 后层宽度折叠时收拢到最前那张、展开时按进度恢复自身宽度" {
    const inputs = [_]StackInput{
        .{ .height = 36, .width = 95 },
        .{ .height = 36, .width = 220 },
        .{ .height = 90, .width = 392 },
    };
    var out: [3]StackOutput = undefined;
    solveStack(&inputs, .{ .expand = 0 }, &out);
    for (out) |o| try std.testing.expectApproxEqAbs(@as(f32, 95), o.clip_width, 1e-4);
    solveStack(&inputs, .{ .expand = 1 }, &out);
    for (out, inputs) |o, in| try std.testing.expectApproxEqAbs(in.width, o.clip_width, 1e-4);
    // 展开进行中：连续插值（过渡），不跳变。
    solveStack(&inputs, .{ .expand = 0.5 }, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 95), out[0].clip_width, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, (95.0 + 220.0) / 2.0), out[1].clip_width, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, (95.0 + 392.0) / 2.0), out[2].clip_width, 1e-4);
    // 未提供宽度的输入保持 0（不参与收拢）。
    const legacy = [_]StackInput{ .{ .height = 60 }, .{ .height = 80 } };
    var out2: [2]StackOutput = undefined;
    solveStack(&legacy, .{}, &out2);
    try std.testing.expectEqual(@as(f32, 0), out2[1].clip_width);
}

test "solveStack: quiet uses its own base density" {
    const inputs = [_]StackInput{.{ .height = 60, .quiet = true }};
    var out: [1]StackOutput = undefined;
    solveStack(&inputs, .{}, &out);
    try testing.expectApproxEqAbs(Spec.glass_quiet, out[0].glass_alpha, 1e-4);
}

test "enter / exit / stagger curves hit their endpoints" {
    const e0 = enterMotion(0);
    try testing.expectApproxEqAbs(@as(f32, 1), e0.offset, 1e-4);
    try testing.expectApproxEqAbs(Spec.enter_scale_from, e0.scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), e0.alpha, 1e-4);
    const e1 = enterMotion(Spec.enter_ms);
    try testing.expectApproxEqAbs(@as(f32, 0), e1.offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), e1.alpha, 1e-4);

    const x0 = exitMotion(0);
    try testing.expectApproxEqAbs(@as(f32, 1), x0.alpha, 1e-4);
    try testing.expect(!x0.done);
    const xm = exitMotion(Spec.exit_ms / 2);
    try testing.expectApproxEqAbs(std.math.pow(f32, 0.5, 1.6), xm.alpha, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - easeOutCubic(0.5)), xm.weight, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - Spec.exit_scale_loss / 2), xm.scale, 1e-4);
    try testing.expect(exitMotion(Spec.exit_ms).done);

    // 分层错峰：延迟内保持初始位移，最后一层不晚于卡片入场结束。
    try testing.expectApproxEqAbs(Spec.stagger_offset, staggerMotion(Spec.title_delay_ms, Spec.title_delay_ms).offset, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), staggerMotion(0, Spec.body_delay_ms).alpha, 1e-4);
    try testing.expect(Spec.footer_delay_ms + Spec.stagger_ms <= Spec.enter_ms);
    // 透明度先于位移走完。
    try testing.expectApproxEqAbs(@as(f32, 1), enterMotion(Spec.enter_ms * Spec.enter_fade_portion).alpha, 1e-4);

    const pop = iconPop(0, Spec.icon_pop_ms);
    try testing.expectApproxEqAbs(@as(f32, 0.9), pop.scale, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), pop.rotate_deg, 1e-4);
    // 不过冲。
    var t: f64 = 0;
    while (t <= Spec.icon_pop_ms) : (t += 10) try testing.expect(iconPop(t, Spec.icon_pop_ms).scale <= 1.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), iconPop(Spec.icon_pop_ms, Spec.icon_pop_ms).scale, 1e-4);
}

test "swipe: threshold, direction constraint, alpha floor" {
    try testing.expect(!swipeCommits(.bottom_center, 40));
    try testing.expect(swipeCommits(.bottom_center, 84));
    try testing.expect(swipeCommits(.bottom_center, -90));
    try testing.expect(!swipeCommits(.bottom_right, -120));
    try testing.expect(swipeCommits(.bottom_right, 120));
    try testing.expectApproxEqAbs(@as(f32, -4), constrainSwipe(.top_right, -20), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), swipeAlpha(400), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1 - 40.0 / 190.0), swipeAlpha(-40), 1e-4);
}

test "Life: pause freezes remaining, resume continues from the frozen point" {
    var life = Life.start(3600, 1000);
    try testing.expectApproxEqAbs(@as(f64, 2600), life.remaining(2000), 1e-6);
    life.pause(2000);
    try testing.expectApproxEqAbs(@as(f64, 2600), life.remaining(9000), 1e-6);
    try testing.expect(!life.expired(9000));
    life.@"resume"(9000);
    try testing.expectApproxEqAbs(@as(f64, 2600), life.remaining(9000), 1e-6);
    try testing.expect(life.expired(11600));
    try testing.expect(!Life.sticky().expired(1e12));
    try testing.expectApproxEqAbs(@as(f32, 1), Life.sticky().fraction(5), 1e-6);
}

test "Follow: tweens on target jumps, follows directly while continuous" {
    var f = Follow{};
    try testing.expectApproxEqAbs(@as(f32, 0), f.step(0, 0, false), 1e-4);
    _ = f.step(100, 1000, false);
    const mid = f.step(100, 1270, false);
    try testing.expect(mid > 0 and mid < 100);
    try testing.expectApproxEqAbs(@as(f32, 100), f.step(100, 1540, false), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 42), f.step(42, 1541, true), 1e-4);
}

test "relativeTime buckets" {
    try testing.expectEqual(RelativeTime.now, relativeTime(59_000));
    try testing.expectEqual(RelativeTime{ .minutes = 1 }, relativeTime(60_000));
    try testing.expectEqual(RelativeTime{ .hours = 2 }, relativeTime(2 * 3_600_000 + 5));
    try testing.expectEqual(RelativeTime{ .days = 1 }, relativeTime(25 * 3_600_000));
}
