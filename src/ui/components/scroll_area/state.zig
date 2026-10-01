/// ScrollArea 滚动状态
///
/// ScrollState 结构体 + ScrollTuning 参数 + 所有 state 方法
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const physics = @import("../../physics.zig");
const debug = @import("debug.zig");
const logScroll = debug.logScroll;

/// 滚动方向
pub const ScrollDirection = enum(u8) {
    vertical,
    horizontal,
    both,
};

pub const ScrollbarVisual = struct {
    // macOS overlay scrollbar thumb: 6px 固定宽
    pub const idle_thickness: f32 = 6;
    pub const active_thickness: f32 = 6;
    // 外层容器贴边，thumb 等效左右/上下 3px 内缩
    pub const edge_inset: f32 = 3;
    pub const hover_slop: f32 = 6;
    pub const cross_axis_clearance: f32 = 12;
    pub const idle_alpha: f32 = @as(f32, 0xA0) / 255.0;
    pub const hover_alpha: f32 = @as(f32, 0xA0) / 255.0;
    pub const dragging_alpha: f32 = @as(f32, 0xA0) / 255.0;
};

pub const ScrollbarAxisMetrics = struct {
    pos: f32,
    length: f32,
};

/// 滚动状态（通过 StateStore 持久化）
pub const ScrollState = struct {
    /// clamped 滚动偏移，始终在 [0, max] 范围内
    scroll_y: f32 = 0,
    scroll_x: f32 = 0,
    content_height: f32 = 0,
    content_width: f32 = 0,
    viewport_height: f32 = 0,
    viewport_width: f32 = 0,

    /// 由外部（如 VirtualList）管理 content_height，scrollbarBeforeRender 不再用 rect.h 覆盖
    external_content_height: bool = false,
    /// 由外部管理 content_width，scrollbarBeforeRender 不再用 rect.w 覆盖
    external_content_width: bool = false,

    /// 垂直方向 rubber band（果冻回弹）开关
    rubber_band_y_enabled: bool = true,
    /// 水平方向 rubber band（果冻回弹）开关
    rubber_band_x_enabled: bool = true,

    /// 实例级调参覆盖（非 null 时优先于全局 scroll_tuning）
    tuning_override: ?ScrollTuning = null,

    /// 橡皮筋 bonus：边界外的视觉偏移（正=超过底部，负=超过顶部）
    bonus_y: f32 = 0,
    /// bonus 速度（弹簧物理，px/s）
    bonus_velocity: f32 = 0,
    /// 水平 bonus
    bonus_x: f32 = 0,
    bonus_velocity_x: f32 = 0,
    /// 手指在触控板上且本层持有这个手势（began/changed 起，到 ended/cancelled 止）。
    /// 期间不跑回弹弹簧。鼠标滚轮没有手势，不会置位。
    touching: bool = false,
    /// 本层正在接收一段惯性（momentum began/changed 起，到 momentum ended 或新手势止）
    momentum_active: bool = false,
    /// 本段惯性已在该轴越界（或松手时已越界）：之后朝外的惯性交给弹簧，不再推内容。
    /// 下一个手势开始时清除。
    momentum_spent_y: bool = false,
    momentum_spent_x: bool = false,
    /// 每次实际应用一次用户滚动输入（滚轮/手势/惯性/滚动条拖拽）加一。
    /// 宿主比较前后两帧的值即可知道这帧有没有滚动输入。
    input_serial: u64 = 0,
    /// 关联的 PropertyTree.scrolls id（maxInt = 未注册到 World）
    world_scroll_id: u32 = std.math.maxInt(u32),
    /// World 引用（写 scroll offset 用）；不持有所有权
    world_ref: ?*anyopaque = null,
    /// macOS 手势 latching：本层是否是当前手势的归属者。
    /// 手势首帧决定归属后中途不换手（NSScrollView 10.9+ 语义），momentum 跟随 latch。
    latched: bool = false,
    /// 回弹动画：临界阻尼弹簧（native NSScrollView 手感），闭式解由绝对时间戳驱动。
    bounce_start_time_y: f64 = 0,
    bounce_from_y: f32 = 0,
    /// 弹簧初速度（px/s，越界方向为正向 bonus 增长方向），携带入射惯性
    bounce_v0_y: f32 = 0,
    bounce_active_y: bool = false,
    bounce_start_time_x: f64 = 0,
    bounce_from_x: f32 = 0,
    bounce_v0_x: f32 = 0,
    bounce_active_x: bool = false,

    // 垂直滚动条动画 (委托给 FadeIndicator)
    scrollbar_fade: physics.FadeIndicator = .{},
    scrollbar_hovered: bool = false,

    // 垂直滚动条拖拽
    scrollbar_dragging: bool = false,
    scrollbar_last_mouse_y: f32 = 0, // 上一帧鼠标 Y，用于算增量

    // 水平滚动条动画
    scrollbar_fade_h: physics.FadeIndicator = .{},
    scrollbar_hovered_h: bool = false,

    // 水平滚动条拖拽
    scrollbar_dragging_h: bool = false,
    scrollbar_last_mouse_x: f32 = 0, // 上一帧鼠标 X，用于算增量

    /// 屏幕物理像素倍率（Retina=2, 普通=1）。
    /// translate_y/x 量化到物理像素网格，消除文字滚动抖动。
    pixel_scale: f32 = 2.0,
    /// Optional horizontal translate rebasing for very large scroll_x values.
    /// Default 0 keeps the regular `translate_x = -effectiveScrollX()` behavior.
    horizontal_translate_rebase_quantum: f32 = 0,
    /// Application-managed vertical origin. Children may store positions
    /// relative to this base, while the content transform only carries the
    /// small residual `scroll_y - base` into layout/GPU f32 coordinates.
    vertical_translate_rebase_base: f32 = 0,

    // 橡皮筋物理 (委托给 RubberBand)
    rubber_band: physics.RubberBand = .{},
    /// 水平方向与垂直同系数（native NSScrollView 两轴一致，均为 0.55）
    rubber_band_x: physics.RubberBand = .{},

    /// 默认帧间隔（秒）
    pub const default_dt: f32 = 1.0 / 60.0;

    /// 可调参数（用于演示调参）
    pub const ScrollTuning = ScrollTuningT;

    /// 全局调参（demo 可修改）
    pub var scroll_tuning = ScrollTuningT{};

    pub fn maxScrollY(self: *const ScrollState) f32 {
        const max = self.content_height - self.viewport_height;
        return if (max > 0) max else 0;
    }

    pub fn maxScrollX(self: *const ScrollState) f32 {
        const max = self.content_width - self.viewport_width;
        return if (max > 0) max else 0;
    }

    /// 用户是否正在滚动：手指在触控板上、惯性进行中或正在拖滚动条。
    /// 全部由确定的开始/结束信号维护，不含任何超时。
    pub fn inputActive(self: *const ScrollState) bool {
        return self.touching or self.momentum_active or self.scrollbar_dragging or self.scrollbar_dragging_h;
    }

    /// 本层开始持有一个新的触控板手势：接住进行中的回弹（保留当前越界量，
    /// 内容停在手指按住的位置），并结束上一段惯性。
    pub fn beginTouch(self: *ScrollState) void {
        if (self.touching) return;
        self.touching = true;
        self.momentum_active = false;
        self.momentum_spent_y = false;
        self.momentum_spent_x = false;
        self.bounce_active_y = false;
        self.bounce_active_x = false;
        self.bonus_velocity = 0;
        self.bonus_velocity_x = 0;
    }

    /// 返回实例级 tuning（有 override 用 override，否则用全局）
    pub fn tuning(self: *const ScrollState) ScrollTuningT {
        return self.tuning_override orelse scroll_tuning;
    }

    /// 实际视觉偏移 = scroll_y + bonus_y
    pub fn effectiveScrollY(self: *const ScrollState) f32 {
        return self.scroll_y + self.bonus_y;
    }

    /// 实际水平视觉偏移 = scroll_x + bonus_x
    pub fn effectiveScrollX(self: *const ScrollState) f32 {
        return self.scroll_x + self.bonus_x;
    }

    /// 将逻辑像素值量化到物理像素网格（消除文字滚动抖动）。
    /// 例: pixel_scale=2 时，12.3 -> 12.5（= 25 物理像素 / 2）。
    pub fn snapToPixel(self: *const ScrollState, v: f32) f32 {
        const s = self.pixel_scale;
        return @round(v * s) / s;
    }

    pub fn horizontalTranslateBase(self: *const ScrollState, scroll_x_value: f32) f32 {
        const quantum = self.horizontal_translate_rebase_quantum;
        if (quantum <= 0 or !std.math.isFinite(scroll_x_value) or @abs(scroll_x_value) < quantum * 2) return 0;
        return @floor(scroll_x_value / quantum) * quantum;
    }

    pub fn contentTranslateX(self: *const ScrollState) f32 {
        const scroll = self.effectiveScrollX();
        const base = self.horizontalTranslateBase(scroll);
        return -self.snapToPixel(scroll - base);
    }

    pub fn contentTranslateY(self: *const ScrollState) f32 {
        const scroll = self.effectiveScrollY();
        const base = if (std.math.isFinite(self.vertical_translate_rebase_base))
            self.vertical_translate_rebase_base
        else
            0;
        return -self.snapToPixel(scroll - base);
    }

    /// 入射初速度上限（px/s），防止极端 fling 把弹簧推得过深
    const max_bounce_v0: f32 = 2500;
    /// 弹簧收敛判定：位移与速度都足够小才算 settle
    const bounce_settle_pos: f32 = 0.4;
    const bounce_settle_vel: f32 = 24.0;

    /// 临界阻尼弹簧闭式解：b(t) = (b0 + (v0 + λ·b0)·t)·e^{-λt}。
    /// v0 携带入射惯性：fling 冲进边界会先短暂加深再平滑回弹（native 手感），
    /// 且与 rubber-band 阶段速度连续，没有换挡感。
    fn springAt(b0: f32, v0: f32, lambda: f32, t: f32) struct { pos: f32, vel: f32 } {
        const c1 = v0 + lambda * b0;
        const decay = @exp(-lambda * t);
        const pos = (b0 + c1 * t) * decay;
        const vel = (c1 - lambda * (b0 + c1 * t)) * decay;
        return .{ .pos = pos, .vel = vel };
    }

    /// 启动垂直回弹动画（从当前 bonus_y / bonus_velocity 出发弹回 0）
    pub fn startBounceY(self: *ScrollState, now_ms: f64) void {
        if (self.bonus_y == 0) return;
        self.bounce_from_y = self.bonus_y;
        self.bounce_v0_y = std.math.clamp(self.bonus_velocity, -max_bounce_v0, max_bounce_v0);
        self.bounce_start_time_y = now_ms;
        self.bounce_active_y = true;
        logScroll("bounce START Y: from={d:.2} v0={d:.1}", .{ self.bonus_y, self.bounce_v0_y });
    }

    /// 启动水平回弹动画
    pub fn startBounceX(self: *ScrollState, now_ms: f64) void {
        if (self.bonus_x == 0) return;
        self.bounce_from_x = self.bonus_x;
        self.bounce_v0_x = std.math.clamp(self.bonus_velocity_x, -max_bounce_v0, max_bounce_v0);
        self.bounce_start_time_x = now_ms;
        self.bounce_active_x = true;
        logScroll("bounce START X: from={d:.2} v0={d:.1}", .{ self.bonus_x, self.bounce_v0_x });
    }

    /// 每帧回弹：临界阻尼弹簧，绝对时间戳驱动。
    /// 回弹 active 期间 outward momentum 被 event handler 拒绝。
    pub fn tickBonus(self: *ScrollState, now_ms: f64) void {
        if (!self.bounce_active_y) {
            // 非动画状态：有 bonus 且手指不在板上，启动回弹
            if (self.bonus_y != 0 and !self.touching) {
                self.startBounceY(now_ms);
            } else {
                return;
            }
        }
        if (self.touching) {
            // 手指按住 -> 中断回弹
            self.bounce_active_y = false;
            logScroll("tickBonus INTERRUPTED: bonus_y={d:.2} touching", .{self.bonus_y});
            return;
        }

        const t: f32 = @floatCast((now_ms - self.bounce_start_time_y) / 1000.0);
        const s = springAt(self.bounce_from_y, self.bounce_v0_y, self.tuning().bounce_spring_lambda, @max(t, 0));
        self.bonus_y = s.pos;
        self.bonus_velocity = s.vel;

        logScroll("BOUNCE_Y: t={d:.3}s bonus={d:.2} vel={d:.1}", .{ t, self.bonus_y, s.vel });

        if (@abs(s.pos) < bounce_settle_pos and @abs(s.vel) < bounce_settle_vel) {
            self.bonus_y = 0;
            self.bonus_velocity = 0;
            self.bounce_active_y = false;
            logScroll("bounce DONE Y", .{});
        }
    }

    /// 水平回弹
    pub fn tickBonusX(self: *ScrollState, now_ms: f64) void {
        if (!self.bounce_active_x) {
            if (self.bonus_x != 0 and !self.touching) {
                self.startBounceX(now_ms);
            } else {
                return;
            }
        }
        if (self.touching) {
            self.bounce_active_x = false;
            return;
        }

        const t: f32 = @floatCast((now_ms - self.bounce_start_time_x) / 1000.0);
        const s = springAt(self.bounce_from_x, self.bounce_v0_x, self.tuning().bounce_spring_lambda, @max(t, 0));
        self.bonus_x = s.pos;
        self.bonus_velocity_x = s.vel;

        logScroll("BOUNCE_X: t={d:.3}s bonus={d:.2} vel={d:.1}", .{ t, self.bonus_x, s.vel });

        if (@abs(s.pos) < bounce_settle_pos and @abs(s.vel) < bounce_settle_vel) {
            self.bonus_x = 0;
            self.bonus_velocity_x = 0;
            self.bounce_active_x = false;
            logScroll("bounce DONE X", .{});
        }
    }

    /// 内容是否超出视口
    pub fn needsScrollbar(self: *const ScrollState) bool {
        return self.content_height > self.viewport_height and self.viewport_height > 0;
    }

    /// 滚动条高度（最小 30px）
    pub fn scrollbarHeight(self: *const ScrollState) f32 {
        if (self.content_height <= 0) return 30;
        const ratio = self.viewport_height / self.content_height;
        return @max(30, ratio * self.viewport_height);
    }

    /// 滚动条 Y 位置
    pub fn scrollbarY(self: *const ScrollState) f32 {
        const max_scroll = self.maxScrollY();
        if (max_scroll <= 0) return 2;
        const bar_h = self.scrollbarHeight();
        const track_h = self.viewport_height - bar_h - 4;
        return (self.scroll_y / max_scroll) * track_h + 2;
    }

    /// 水平内容是否超出视口
    pub fn needsHScrollbar(self: *const ScrollState) bool {
        return self.content_width > self.viewport_width and self.viewport_width > 0;
    }

    /// 水平滚动条宽度（最小 30px）
    pub fn hScrollbarWidth(self: *const ScrollState) f32 {
        if (self.content_width <= 0) return 30;
        const ratio = self.viewport_width / self.content_width;
        return @max(30, ratio * self.viewport_width);
    }

    pub fn onScrollActivity(self: *ScrollState) void {
        // 默认两个轴都激活（用于无 axis 信息的场景：drag、hover）
        self.onScrollActivityAxes(true, true);
    }

    /// 按轴激活 scrollbar fade。
    /// VSCode/Zed 标准：纯 Y 滚动只显示 Y scrollbar；纯 X 同理。
    pub fn onScrollActivityAxes(self: *ScrollState, axis_y: bool, axis_x: bool) void {
        if (axis_y) self.scrollbar_fade.onActivity();
        if (axis_x) self.scrollbar_fade_h.onActivity();
        // 同步调参到实例（有 override 时优先）
        self.rubber_band.coefficient = self.tuning().rubber_band_coeff;
    }

    pub fn tickScrollbar(self: *ScrollState) bool {
        const old_opacity = self.scrollbar_fade.opacity;
        const old_opacity_h = self.scrollbar_fade_h.opacity;
        self.scrollbar_fade.hovered = self.scrollbar_hovered;
        self.scrollbar_fade.tick();
        self.scrollbar_fade_h.hovered = self.scrollbar_hovered_h;
        self.scrollbar_fade_h.tick();
        return self.scrollbar_fade.opacity != old_opacity or
            self.scrollbar_fade_h.opacity != old_opacity_h;
    }
};

/// 可调参数（用于演示调参）
pub const ScrollTuningT = struct {
    /// 越界拖拽阻尼系数 (Apple UIScrollView 标准 = 0.55)
    /// 运行时同步到 state.rubber_band.coefficient
    rubber_band_coeff: f32 = 0.55,
    /// 抖动消除用的微小阈值（px）
    jitter_snap_epsilon: f32 = 0.35,
    /// 进入边界前的预阻力区域（px）。
    /// native macOS 到边界前是 1:1 无阻力（rubber band 只作用于越界后），默认关闭；
    /// 保留参数供特殊场景 opt-in。
    edge_resistance_zone_px: f32 = 0.0,
    /// 回弹弹簧临界阻尼系数 λ（1/s）。settle ≈ 6.6/λ ≈ 470ms，对齐 NSScrollView。
    bounce_spring_lambda: f32 = 14.0,
    /// 边界处最小通过比例（用户主动滚动）
    edge_resistance_min_factor: f32 = 0.16,
    /// 边界处最小通过比例（momentum，阻力更大）
    momentum_edge_resistance_min_factor: f32 = 0.12,
};

/// 节点 on_cleanup 与 ScrollEventCtx 之间的中转格。
///
/// 为什么必须有这一层：节点的 on_cleanup 回调要把 ctx 上的节点指针清成 null，
/// 但**节点可能比 ctx 活得久，且解绑够不着它**,
///   1. VirtualList 回收 slot 走 `detachChild + cx.freeNode`（`Node.destroy`
///      只剩扩容 errdefer 一处）：invoke on_cleanup 但**不** dispose scope，
///      于是 ctx 上四个字段被清空、ctx 本身却还活着；
///   2. 保留模式下节点复用，同一 ctx 可能被装到**多个**节点上（陈旧重复的
///      content 节点），而 `detachScrollAreaBindings` 只认 ctx 上那四格，
///      清不到重复的那个；
///   3. 于是 scope.dispose() 释放 ctx 后，那个够不着的节点稍后 freeNode 时
///      invoke 回调 -> 写已释放内存 -> SIGSEGV。
///      （下游应用实测：进板滚动 Layers 列表后返回首页，必崩。）
///
/// 所以回调一律改写本格，而**本格由 Cx 独占持有**（Cx.scroll_ctx_cells）：
/// ctx 释放时只把 `ctx` 置 null，格子本身留到 Cx.deinit 统一回收。节点与
/// scope 都不参与本格的生命周期，也就无从失衡；够不着的陈旧节点只会看到
/// ctx == null，安全空转。
///
/// 代价：格子按 ScrollArea 挂载次数累积，直到 Cx 关闭才回收（每个仅 8 字节）。
/// 实测下游应用跑 10 轮 board↔home 往返（含 Layers 列表滚动）总数 < 5 个,
/// 保留模式下节点复用，重挂并不会新建。换来的是"任何释放顺序都不会 UAF"。
pub const ScrollCtxCell = struct {
    /// scope 释放 ScrollEventCtx 后置 null。
    ctx: ?*ScrollEventCtx = null,
};

pub const ScrollEventCtx = struct {
    state: *ScrollState = undefined,
    /// 节点指针在 ScrollArea 关联节点被 freeNode 时由 Node.ownership.hooks.on_cleanup 钩子清成 null。
    /// 这样 scope.dispose() 在节点 *已经* 释放后才触发的清理回调也能安全地跳过悬垂指针。
    content: ?*Node = null,
    container: ?*Node = null,
    scrollbar: ?*Node = null,
    scrollbar_h: ?*Node = null,
    /// 节点 on_cleanup 实际写的中转格（见 ScrollCtxCell）。
    cell: ?*ScrollCtxCell = null,
    cx: *Cx = undefined,
    scroll_speed: f32 = 1,
    direction: ScrollDirection = .vertical,
    scrollbar_thumb: Color = Color.hex(0xffffff),
};
