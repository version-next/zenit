//! 单张提醒卡片的节点构建与内容层替换。
//!
//! 结构（设计稿 16.2 / 16.3）：
//!
//!   positioner      absolute · translate/scale 唯一载体 · 两段投影 · z 序
//!   ├─ surface      液态玻璃（backdrop blur 46）· 圆角 18 · 0.5px 亮边 · 裁切
//!   │  ├─ sheen     上亮下暗的线性光泽
//!   │  ├─ highlight 左上角径向高光
//!   │  ├─ content   内容层（原地转换时整体替换，外壳与 born 不变）
//!   │  └─ lifebar   底部 1.5px 生命条
//!   └─ close        左上角 20×20 关闭钮（压住图标一角）
//!
//! 淡入淡出不用节点 opacity：opacity layer 会把玻璃推进离屏合成，模糊丢失
//! （实测：包裹层 opacity .5 时下层文字清晰透出）。改为每帧把同一个 alpha
//! 系数乘进模糊半径 / 底色 / 描边 / 投影 / 光泽层 / 内容层。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const svg_assets = @import("../../svg_assets.zig");
const icons = @import("zenit_system_icons");
const render_engine = @import("../../core/render_engine/mod.zig");
const DrawContext = render_engine.DrawContext;
const button_mod = @import("../button/mod.zig");
const hooks = @import("../../hooks.zig");
const input_mod = @import("../input/mod.zig");
const TextInputState = @import("../input/state.zig").TextInputState;

const model = @import("model.zig");
const styles = @import("styles.zig");
const hint_mod = @import("hint.zig");
const M = styles.Metrics;

// ============================================================================
// 公共类型（由 mod.zig 重新导出）
// ============================================================================

/// 图标位（行首 32×32）的呈现方式。
pub const Lead = enum {
    /// 语义色圆角方块 + 白色字形（默认）。
    chip,
    /// 语义色方块 + 旋转指示器（progress 默认）。
    spinner,
    /// 倒计时环 + 中心剩余秒数（undo 默认）。
    ring,
    /// 圆形头像 + 首字（传了 avatar 时默认）。
    avatar,
    /// 无实心底的小圆点（quiet 默认）。
    dot,
};

pub const Action = struct {
    label: []const u8,
    /// 主按钮：更重的中性底 + 600 字重，仍不上色。
    primary: bool = false,
    /// 回调里用于区分按钮的标记。
    tag: []const u8 = "",
    /// 按钮内嵌键帽（仅文案提示的胶囊按钮显示，如「⌘Z」）。
    shortcut: []const u8 = "",
};

pub const Progress = struct {
    /// 0..1
    value: f32 = 0,
    /// 左侧状态文案，如「上传中 · 预计 4 秒」。
    label: []const u8 = "",
    /// 右侧 n / N 计数（等宽）。
    count: []const u8 = "",
};

/// 回复框发出后的引用行（原地转换的一部分）。
pub const Quote = struct {
    text: []const u8,
};

/// 规范化后的内容描述；字符串由 Card 的 arena 持有。
pub const ContentSpec = struct {
    kind: model.Kind = .default,
    tone: model.Tone = .info,
    lead: Lead = .chip,
    glyph: ?svg_assets.Asset = null,
    avatar: []const u8 = "",
    title: []const u8 = "",
    body: []const u8 = "",
    actions: []const Action = &.{},
    reply: bool = false,
    quote: ?[]const u8 = null,
    progress: ?Progress = null,
    /// 是否显示底部生命条。
    life_bar: bool = true,
    /// 文案提示（kind = .hint）的行首标记与键帽行。
    hint_mark: hint_mod.Mark = .none,
    keycap: ?hint_mod.Keycap = null,
};

pub const Strings = struct {
    now: []const u8 = "now",
    /// `{d}` 替换为数字。
    minutes_ago: []const u8 = "{d}m ago",
    hours_ago: []const u8 = "{d}h ago",
    days_ago: []const u8 = "{d}d ago",
    undo: []const u8 = "Undo",
    reply_placeholder: []const u8 = "Reply…",
    send: []const u8 = "Send",
    close: []const u8 = "Dismiss notification",
    /// 折叠态角标：`{d}` = 其余条数。
    more: []const u8 = "{d} more · hover to expand",
    paused: []const u8 = "Paused while hovering",
    /// 角标旁「全部清除」圆钮悬停展开的文字。
    clear_all: []const u8 = "Clear all",
};

pub fn defaultGlyph(tone: model.Tone) svg_assets.Asset {
    return switch (tone) {
        .success => icons.check,
        .@"error" => icons.close,
        .warning => icons.warning,
        .info => icons.info,
        .violet => icons.plus,
        .quiet => icons.info,
    };
}

pub fn defaultLead(kind: model.Kind, tone: model.Tone, has_avatar: bool) Lead {
    return switch (kind) {
        .progress => .spinner,
        .undo => .ring,
        .hint => .chip,
        .default => if (has_avatar) .avatar else if (tone == .quiet) .dot else .chip,
    };
}

/// 按 `{d}` 模板格式化到 buf。
pub fn formatCount(buf: []u8, template: []const u8, n: u64) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (std.mem.indexOf(u8, template, "{d}")) |at| {
        w.writeAll(template[0..at]) catch return template;
        w.print("{d}", .{n}) catch return template;
        w.writeAll(template[at + 3 ..]) catch return template;
    } else {
        w.writeAll(template) catch return template;
    }
    return w.buffered();
}

// ============================================================================
// 内容层
// ============================================================================

/// 按钮点击 -> Notifier。每个按钮一个固定上下文（card 地址 + 下标）。
pub const ButtonContext = struct {
    card: *Card,
    index: u8,
};

pub const ButtonSink = *const fn (card: *Card, index: u8) void;
/// 回复框「发送」/ Enter 走同一个按钮通道，用保留下标区分。
pub const send_index: u8 = 0xFE;
pub const CloseSink = *const fn (card: *Card) void;

pub const Content = struct {
    /// 内容层自己的 scope（按钮 / 回复框），整体替换时整体 dispose。
    scope: *Scope,
    root: *Node,
    /// 以下四项文案提示没有（胶囊只有一行）。
    lead_box: ?*Node = null,
    lead: ?*Node = null,
    title_row: ?*Node = null,
    title: *Node,
    timestamp: ?*Node = null,
    /// 旋转指示器（custom draw，常转需逐帧重画）。
    spinner: ?*Node = null,
    body: ?*Node = null,
    quote: ?*Node = null,
    progress_block: ?*Node = null,
    progress_fill: ?*Node = null,
    ring_secs: ?*Node = null,
    footer: ?*Node = null,
    reply_row: ?*Node = null,
    buttons: [2]?*Node = .{ null, null },
    button_contexts: [2]ButtonContext = undefined,
    send_button: ?*Node = null,
    send_context: ButtonContext = undefined,
    reply_input: ?*Node = null,
    reply_state: ?*TextInputState = null,
    /// 已绘制的环秒数（避免每帧换文本）。
    ring_secs_shown: i32 = -1,
};

// ============================================================================
// Card
// ============================================================================

pub const Card = struct {
    allocator: Allocator,
    cx: *Cx,
    id: u64,
    seq: u64,
    /// Changes only when a new content version is successfully published.
    revision: u64 = 0,

    positioner: *Node,
    surface: *Node,
    sheen: *Node,
    highlight: *Node,
    lifebar: *Node,
    close: *Node,
    close_glyph_dark: *Node,
    close_glyph_light: *Node,
    content: Content,

    /// 字符串所有权（按内容版本整体替换）。
    arena: std.heap.ArenaAllocator,
    /// 卡片级 scope（拖拽绑定），跨内容替换存活，随卡片销毁。
    scope: *Scope,
    spec: ContentSpec,
    sticky: bool,

    // ── 生命周期（帧时钟 ms）──
    measured: bool = false,
    natural_height: f32 = 0,
    /// 自然宽度：卡片恒为满宽；文案提示胶囊随内容（量到后写入）。
    natural_width: f32 = 0,
    born_ms: f64 = 0,
    born_wall_ms: i64 = 0,
    life: model.Life = .{},
    leaving: bool = false,
    /// 开始退场的帧时钟时刻；null = 已请求、待下一个真实帧盖戳（见 mod.zig frame）。
    left_at_ms: ?f64 = null,
    /// 从未显示过就被收掉：下一帧直接回收，不走退场动画。
    instant_exit: bool = false,
    /// 「全部清除」退场：保留占位不补位，原地淡出。
    hold_space: bool = false,
    fling_x: f32 = 0,
    /// 本卡是否由用户关闭（✕ / 拖拽），回调区分自动到期。
    closed_by_user: bool = false,

    // ── 原地转换 ──
    icon_pop_at_ms: ?f64 = null,
    crossfade_at_ms: ?f64 = null,
    /// 内容层刚换新、尚未量到高度：保持透明，量到后再开始弹入 / 淡入。
    content_pending: bool = false,

    // ── 拖拽 ──
    drag_dx: f32 = 0,
    /// 鼠标拖拽开始时的基准位移（从横扫接管时不跳位）。
    drag_base: f32 = 0,
    dragging: bool = false,
    /// 拖拽绑定（退场时主动取消进行中的手势）。
    drag_binding: ?*@import("../../interaction/drag.zig").Binding = null,
    /// destroyCard 进行中：回调一律只复位状态、不再访问 Notifier / 节点。
    destroying: bool = false,
    /// 触控板双指横扫驱动的拖拽（以手势 ended/cancelled 收尾）。
    scroll_dragging: bool = false,
    /// 最近一次发出的回复（失败时恢复进输入框）。
    last_reply: ?[]u8 = null,
    spring_from: f32 = 0,
    spring_at_ms: ?f64 = null,
    spring_pending: bool = false,
    /// 原地转换后的新寿命（ms）：等新内容层量到高度的那一帧再开始计时。
    life_pending_ms: ?f64 = null,

    // ── 渲染跟随 ──
    follow_y: model.Follow = .{},
    follow_x: model.Follow = .{},
    close_alpha: f32 = 0,
    close_dark: bool = false,
    /// 最近一帧的窗口坐标矩形（悬停命中测试用）。
    rect_x: f32 = 0,
    rect_y: f32 = 0,
    rect_w: f32 = 0,
    rect_h: f32 = 0,
    rect_visible: bool = false,
    last_ts: model.RelativeTime = .now,
    ts_initialized: bool = false,
    /// 卡片满宽（盒子缩放的基准）。
    full_width: f32 = 392,
    /// 当前层序 rank（z 序 = 上限 − rank）。
    rank: u8 = 0,

    // ── 回调 ──
    button_sink: ButtonSink,
    close_sink: CloseSink,
    strings: *const Strings,
    /// 最近一次 apply 的 alpha（custom draw 用）。
    draw_alpha: f32 = 0,
    /// custom draw 的帧时钟快照。
    draw_now_ms: f64 = 0,

    /// 退场已进行的时长；尚未盖戳时视为刚开始。
    pub fn exitElapsed(self: *const Card, now: f64) f64 {
        return now - (self.left_at_ms orelse now);
    }

    pub fn isQuiet(self: *const Card) bool {
        return self.spec.tone == .quiet and self.spec.lead == .dot;
    }

    pub fn swapArena(self: *Card) std.heap.ArenaAllocator {
        const old = self.arena;
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        return old;
    }
};

// ============================================================================
// 构建
// ============================================================================

pub const BuildParams = struct {
    cx: *Cx,
    scope: *Scope,
    palette: *const styles.Palette,
    strings: *const Strings,
    width: f32,
};

fn appendOwned(cx: *Cx, parent: *Node, child: *Node) !void {
    errdefer cx.freeNode(child);
    try parent.appendChild(cx.allocator, child);
}

fn ext(cx: *Cx, node: *Node) !*@import("../../core/types.zig").StyleExt {
    return node.style.ensureExtFallible(cx.allocator);
}

/// 外壳：positioner + surface + 光泽 + 生命条 + 关闭钮。内容层另建。
pub fn buildShell(card: *Card, p: BuildParams) !void {
    const cx = p.cx;
    const pal = p.palette;

    const positioner = try box(cx, .{
        .position = .absolute,
        .width = .fixed(p.width),
        .height = .{ .fit = .{} },
        .direction = .column,
    }, .{});
    errdefer cx.freeNode(positioner);
    const pext = try ext(cx, positioner);
    pext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    pext.hit_behavior = .self_and_children;
    // 不挂 will_change_*：静止（alpha 1、scale 1）时直接绘制；只在淡入淡出 / 缩放
    // 期间才进离屏层（含玻璃的层不复用缓存纹理，常驻离屏会每帧重画）。
    pext.corner_radius = core.CornerRadius.uniform(M.radius);
    // opacity 0 的预测量帧仍需参与 layout。
    pext.keep_rendering_when_transparent = true;
    positioner.meta.ownership.meta.component_name = "Notification";

    const surface = try box(cx, .{
        .width = .fill(),
        .height = .{ .fit = .{} },
        .direction = .column,
        .border = .{ .width = 1, .color = pal.glass_edge, .radius = M.radius },
        .background = pal.glass(model.Spec.glass_front),
    }, .{});
    try appendOwned(cx, positioner, surface);
    try applyGlassMaterial(cx, surface, pal, M.radius);
    surface.style.overflow_hidden = true;
    surface.style.flex_shrink = 0;
    surface.meta.ownership.meta.component_name = "Notification.surface";
    const layers = try buildGlassLayers(cx, surface, pal);

    // 生命条在流里：卡片高度 = 内容 + 1.5（设计稿 16.2）；无生命条的类型高度为 0。
    const lifebar = try box(cx, .{
        .width = .fixed(p.width),
        .height = .fixed(0),
        .background = pal.lifeBar(.success),
    }, .{});
    try appendOwned(cx, surface, lifebar);
    const lext = try ext(cx, lifebar);
    lext.hit_behavior = .pass_through;
    // 剩余比例用 scale_x 表达（左端为原点），逐帧只改合成属性。
    lext.transform_origin = .{ .x = .{ .px = 0 }, .y = .{ .percent = 0.5 } };
    lext.corner_radius = .{ .each = .{ 0, 1, 1, 0 } };
    lifebar.style.flex_shrink = 0;

    try buildClose(card, p, positioner, surface, layers, lifebar);
    applyShellForm(card, p);
}

/// 外壳随形态切换（卡片 ↔ 文案提示胶囊）：宽度、投影、生命条宽度。
/// 建壳时与原地转换时各调用一次。
pub fn applyShellForm(card: *Card, p: BuildParams) void {
    const pal = p.palette;
    const is_hint = card.spec.kind == .hint;
    const positioner = card.positioner;
    const w: core.Sizing = if (is_hint) .{ .fit = .{} } else .fixed(p.width);
    positioner.style.width = w;
    card.surface.style.width = if (is_hint) .{ .fit = .{} } else .fill();
    card.lifebar.style.width = .fixed(if (is_hint) 0 else p.width);
    if (positioner.style.ext) |pext| {
        if (is_hint) {
            // 胶囊投影约为卡片的一半：y1/b2 · y6/b16 · y16/b36。
            pext.setShadowList(&.{
                .{ .color = pal.shadow(0.10), .blur = 2, .offset_y = 1 },
                .{ .color = pal.shadow(0.12), .blur = 16, .offset_y = 6 },
                .{ .color = pal.shadow(0.08), .blur = 36, .offset_y = 16 },
            });
        } else {
            // 三段投影（16.3 第 8 层）：近 = 接触、中 = 离地高度、远 = 让边界不生硬。
            // 两段负 spread 先把阴影矩形收小再模糊，去掉会明显变重、变低。
            pext.setShadowList(&.{
                .{ .color = pal.shadow(0.08), .blur = 2, .offset_y = 1 },
                .{ .color = pal.shadow(0.17), .blur = 24, .offset_y = 8, .spread = -6 },
                .{ .color = pal.shadow(0.22), .blur = 64, .offset_y = 28, .spread = -24 },
            });
        }
    }
    positioner.markSizingDirty();
    card.surface.markSizingDirty();
    card.lifebar.markSizingDirty();
    positioner.markRenderDirty();
}

/// 提醒玻璃材质（卡片与文案提示共用）：底色 / 亮边 / 模糊 / 内阴影。
pub fn applyGlassMaterial(cx: *Cx, surface: *Node, pal: *const styles.Palette, radius: f32) !void {
    const sext = try ext(cx, surface);
    sext.corner_radius = core.CornerRadius.uniform(radius);
    // 材质与编辑器浮条（下游编辑器 media_glass）一致：白玻璃 + 凸面折射高光。
    sext.glass = .{
        .backdrop_blur = 24,
        .backdrop_saturation = 1.4,
        .backdrop_brightness = 1.03,
        .glass_intensity = 0.30,
        .surface = .convex_squircle,
        .bottom_surface = .flat,
        .specular_opacity = 0.16,
        .refraction_level = 0.10,
        .warp_gain = 0.10,
        .edge_field_strength = 0.10,
    };
    // 暗色模式保留 0.5px 暗边（offset −1，压住亮边外溢）；亮色的边由 1px 白描边负责。
    if (pal.glass_outline.a > 0) sext.outline = .{ .color = pal.glass_outline, .width = 0.5, .offset = -1 };
    // 第 7 层：三段内阴影，顶部 1px 白 95% / 底部 1px 暗 9% / 内发光 22px 白 35%。
    sext.setInsetShadowList(&.{
        .{ .color = pal.inset_top, .blur = 0, .offset_y = 1 },
        .{ .color = pal.inset_bottom, .blur = 0, .offset_y = -1 },
        .{ .color = pal.inset_glow, .blur = 22 },
    });
}

pub const GlassLayers = struct { sheen: *Node, highlight: *Node };

/// 玻璃上的两层高光：线性光泽 + 左上角径向光斑（卡片与文案提示共用）。
pub fn buildGlassLayers(cx: *Cx, surface: *Node, pal: *const styles.Palette) !GlassLayers {
    const sheen = try box(cx, .{ .position = .absolute, .width = .fill(), .height = .fill() }, .{});
    try appendOwned(cx, surface, sheen);
    const shext = try ext(cx, sheen);
    shext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } };
    shext.hit_behavior = .pass_through;
    shext.multi_gradient = core.MultiGradient.fromSlice(&.{
        .{ .color = pal.sheen_top, .position = 0 },
        .{ .color = pal.sheen_bottom, .position = 1 },
    }, .vertical);

    // 径向高光：中心在 (12%, −10%)，尺寸 120% × 100%（16.3 第 3 层）。
    // 第 3 层：左上角径向光斑 radial-gradient(120% 100% at 12% −10%, 白 55% -> 0 @58%)。
    const highlight = try box(cx, .{ .position = .absolute, .width = .fill(), .height = .fill() }, .{});
    try appendOwned(cx, surface, highlight);
    const hext = try ext(cx, highlight);
    hext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } };
    hext.hit_behavior = .pass_through;
    var radial = core.MultiGradient.fromSlice(&.{
        .{ .color = pal.highlight, .position = 0 },
        .{ .color = pal.highlight.withAlpha(0), .position = 0.58 },
        .{ .color = pal.highlight.withAlpha(0), .position = 1 },
    }, .radial);
    radial.radial_center = .{ 0.12, -0.10 };
    radial.radial_radius = .{ 1.2, 1.0 };
    hext.multi_gradient = radial;
    return .{ .sheen = sheen, .highlight = highlight };
}

fn buildClose(card: *Card, p: BuildParams, positioner: *Node, surface: *Node, layers: GlassLayers, lifebar: *Node) !void {
    const cx = p.cx;
    const pal = p.palette;
    // 关闭钮：原生同款深色圆形白叉，压在左上角盖住图标一角；平时不可见。
    const close = try box(cx, .{
        .position = .absolute,
        .width = .fixed(M.close_size),
        .height = .fixed(M.close_size),
        .align_items = .center,
        .justify = .center,
        .background = pal.close_light,
        .border = .{ .width = 0.5, .color = pal.close_light_edge, .radius = M.close_size / 2 },
    }, .{});
    try appendOwned(cx, positioner, close);
    const cext = try ext(cx, close);
    cext.inset = .{ .left = .{ .px = M.close_inset }, .top = .{ .px = M.close_inset } };
    cext.corner_radius = core.CornerRadius.uniform(M.close_size / 2);
    cext.z_index = 10;
    cext.setShadow(.{ .color = pal.shadow(0.2), .blur = 3, .offset_y = 1 });
    close.style.cursor = .pointer;
    close.setOpacityRaw(0);
    close.setHitTestVisible(false);
    close.meta.ownership.meta.component_name = "Notification.close";
    close.behavior.interaction.a11y = .{ .role = .button, .label = p.strings.close };
    close.behavior.events.on_event = closeEvent;
    close.behavior.events.event_context = @ptrCast(card);

    const glyph_dark = try core.iconTint(cx, icons.close, pal.on_semantic, .{ .width = .fixed(M.close_glyph), .height = .fixed(M.close_glyph), .position = .absolute });
    try appendOwned(cx, close, glyph_dark);
    (try ext(cx, glyph_dark)).inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } };
    glyph_dark.setOpacityRaw(0);
    const glyph_light = try core.iconTint(cx, icons.close, pal.close_light_glyph, .{ .width = .fixed(M.close_glyph), .height = .fixed(M.close_glyph), .position = .absolute });
    try appendOwned(cx, close, glyph_light);
    (try ext(cx, glyph_light)).inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } };

    card.positioner = positioner;
    card.surface = surface;
    card.sheen = layers.sheen;
    card.highlight = layers.highlight;
    card.lifebar = lifebar;
    card.close = close;
    card.close_glyph_dark = glyph_dark;
    card.close_glyph_light = glyph_light;
}

fn closeEvent(event: core.Event, context: ?*anyopaque) core.EventResult {
    if (event != .click) return .ignored;
    const card: *Card = @ptrCast(@alignCast(context orelse return .ignored));
    card.close_sink(card);
    return .stop;
}

fn buttonEvent(event: core.Event, context: ?*anyopaque) core.EventResult {
    if (event != .click) return .ignored;
    const bctx: *ButtonContext = @ptrCast(@alignCast(context orelse return .ignored));
    bctx.card.button_sink(bctx.card, bctx.index);
    return .stop;
}

fn textNode(cx: *Cx, content: []const u8, color: Color, size: f32, weight: u16, wrap: core.TextWrap, line_height: f32) !*Node {
    return core.text(cx, content, .{
        .color = color,
        .font_size = size,
        .font_weight = weight,
        .wrap = wrap,
        .line_height = line_height,
    });
}

fn setMonospace(node: *Node) void {
    var t = node.getText() orelse return;
    t.use_monospace_font = true;
    node.setText(t);
}

/// 构建内容层并挂到 surface（位于光泽层之后、生命条之前）。
pub fn buildContent(card: *Card, p: BuildParams) !Content {
    if (card.spec.kind == .hint) {
        var content = try hint_mod.buildContent(card, p);
        errdefer destroyContent(p.cx, card.surface, &content);
        setLifebarHeight(card, 0);
        try card.surface.appendChild(p.cx.allocator, content.root);
        reorderSurface(card, content.root) catch {};
        return content;
    }
    const cx = p.cx;
    const pal = p.palette;
    const spec = card.spec;

    // 根 scope（不挂在 Notifier scope 下），只由本卡片释放：父 scope dispose 时
    // 会先递归销毁子 scope 再跑资源回调，挂成子 scope 的话 Notifier 的清理回调
    // 读 content.scope 时它已被释放。按钮各自的 scope 是它的子 scope、绑在按钮
    // 节点上，节点先释放时会自行摘除，不影响这里。
    const scope = try Scope.init(p.scope.allocator, null, p.scope.owner);
    errdefer scope.dispose();

    const root = try box(cx, .{ .width = .fixed(p.width), .height = .{ .fit = .{} }, .direction = .column }, .{});
    errdefer cx.freeNode(root);
    root.style.flex_shrink = 0;
    root.meta.ownership.meta.component_name = "Notification.content";

    const row = try box(cx, .{
        .width = .fill(),
        .direction = .row,
        .align_items = .start,
        .gap = M.row_gap,
        .padding = M.row_padding,
    }, .{});
    try appendOwned(cx, root, row);

    // ── 行首图标位 ──
    const lead_box = try box(cx, .{
        .width = .fixed(if (spec.lead == .ring) M.ring_size else M.lead_size),
        .height = .fixed(if (spec.lead == .ring) M.ring_size else M.lead_size),
        .align_items = .center,
        .justify = .center,
    }, .{});
    try appendOwned(cx, row, lead_box);
    lead_box.style.flex_shrink = 0;
    const lead = try buildLead(card, p, lead_box);

    // ── 文字列 ──
    const col = try box(cx, .{ .width = .fill(), .direction = .column, .gap = M.content_gap }, .{});
    try appendOwned(cx, row, col);

    const title_row = try box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = M.title_gap }, .{});
    try appendOwned(cx, col, title_row);
    const title = try textNode(cx, spec.title, pal.ink, M.title_size, M.title_weight, .word, M.title_line_height);
    try appendOwned(cx, title_row, title);
    const ts = try textNode(cx, p.strings.now, pal.ink_3, M.timestamp_size, 400, .none, M.timestamp_line_height);
    try appendOwned(cx, title_row, ts);
    ts.style.flex_shrink = 0;
    setMonospace(ts);

    var content = Content{
        .scope = scope,
        .root = root,
        .lead_box = lead_box,
        .lead = lead,
        .title_row = title_row,
        .title = title,
        .timestamp = ts,
    };
    if (spec.lead == .ring) {
        content.ring_secs = lead_box.children.items[1].children.items[0];
    }
    if (spec.lead == .spinner) content.spinner = lead.children.items[0];

    if (spec.body.len > 0) {
        const body = try core.text(cx, spec.body, .{
            .color = pal.ink_2,
            .font_size = M.body_size,
            .line_height = M.body_line_height,
            .wrap = .word,
            .max_lines = M.body_max_lines,
        });
        try appendOwned(cx, col, body);
        content.body = body;
    }

    if (spec.quote) |q| {
        const quote = try box(cx, .{
            .width = .fill(),
            .direction = .row,
            .gap = 6,
            .padding = .{ .top = 4, .right = 0, .bottom = 0, .left = 8 },
            .border = .{ .width = 0, .color = pal.separator, .radius = 0 },
        }, .{});
        try appendOwned(cx, col, quote);
        const bar = try box(cx, .{ .width = .fixed(2), .height = .fill(), .background = pal.track }, .{});
        try appendOwned(cx, quote, bar);
        const qt = try core.text(cx, q, .{ .color = pal.ink_2, .font_size = M.body_size, .line_height = M.body_line_height, .wrap = .word, .max_lines = 2 });
        try appendOwned(cx, quote, qt);
        content.quote = quote;
    }

    if (spec.progress) |prog| {
        const block = try box(cx, .{ .width = .fill(), .direction = .column, .gap = 5, .padding = M.progress_padding }, .{});
        try appendOwned(cx, col, block);
        const track = try box(cx, .{
            .width = .fill(),
            .height = .fixed(M.progress_track),
            .background = pal.track,
            .border = .{ .width = 0, .color = pal.track, .radius = M.progress_track / 2 },
        }, .{});
        try appendOwned(cx, block, track);
        (try ext(cx, track)).corner_radius = core.CornerRadius.uniform(M.progress_track / 2);
        track.style.overflow_hidden = true;
        const fill = try box(cx, .{
            .width = .pct(model.clamp01(prog.value) * 100),
            .height = .fill(),
            .background = pal.info,
            .border = .{ .width = 0, .color = pal.info, .radius = M.progress_track / 2 },
        }, .{});
        try appendOwned(cx, track, fill);
        (try ext(cx, fill)).corner_radius = core.CornerRadius.uniform(M.progress_track / 2);
        const meta = try box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 8 }, .{});
        try appendOwned(cx, block, meta);
        const state = try textNode(cx, prog.label, pal.ink_3, M.meta_size, 400, .none, M.meta_line_height);
        try appendOwned(cx, meta, state);
        state.style.width = .fill();
        const count = try textNode(cx, prog.count, pal.ink_2, M.meta_size, 600, .none, M.meta_line_height);
        try appendOwned(cx, meta, count);
        count.style.flex_shrink = 0;
        setMonospace(count);
        content.progress_block = block;
        content.progress_fill = fill;
    }

    // ── 分隔线下方的独立按钮区 / 回复框 ──
    if (spec.actions.len > 0 or spec.reply) {
        const footer = try box(cx, .{ .width = .fill(), .direction = .column }, .{});
        try appendOwned(cx, root, footer);
        const sep = try box(cx, .{ .width = .fill(), .height = .fixed(M.separator), .background = pal.separator }, .{});
        try appendOwned(cx, footer, sep);
        const actions = try box(cx, .{
            .width = .fill(),
            .direction = .row,
            .align_items = .center,
            .gap = M.footer_gap,
            .padding = M.footer_padding,
        }, .{});
        try appendOwned(cx, footer, actions);
        content.footer = footer;

        if (spec.reply) {
            content.reply_row = actions;
            try buildReply(card, p, scope, actions, &content);
        } else {
            for (spec.actions[0..@min(spec.actions.len, 2)], 0..) |action, i| {
                content.button_contexts[i] = .{ .card = card, .index = @intCast(i) };
                const bg = if (action.primary) pal.button_primary else pal.button_secondary;
                const bg_hover = if (action.primary) pal.button_primary_hover else pal.button_secondary_hover;
                const btn = try button_mod.Button(.{
                    .label = action.label,
                    .variant = .secondary,
                    .size = .sm,
                    .block = true,
                    .on_event = buttonEvent,
                    // 注意：content 按值返回，上下文必须指向 card 内的稳定地址,
                    // 由调用方在 content 落位后调用 rebindButtons 修正。
                    .event_context = null,
                    .style = .{
                        .width = .fill(),
                        .height = .fixed(M.button_height),
                        .background = bg,
                        .border = .{ .width = 0, .color = bg, .radius = M.button_radius },
                        .text_color = if (action.primary) pal.ink else pal.ink_2,
                        .font_size = M.button_font,
                        .font_weight = if (action.primary) 600 else 500,
                    },
                    .hover_style = .{ .background = bg_hover, .border = .{ .width = 0, .color = bg_hover, .radius = M.button_radius } },
                    .pressed_style = .{ .background = bg_hover, .border = .{ .width = 0, .color = bg_hover, .radius = M.button_radius } },
                }).mount(scope, cx);
                btn.meta.ownership.meta.component_name = "Notification.action";
                try appendOwned(cx, actions, btn);
                content.buttons[i] = btn;
            }
        }
    }

    setLifebarHeight(card, if (spec.life_bar) M.life_bar else 0);

    // 插到 lifebar 之前：光泽层在下，内容在中，生命条在上。
    try card.surface.appendChild(cx.allocator, root);
    reorderSurface(card, root) catch {};
    return content;
}

fn setLifebarHeight(card: *Card, bar_h: f32) void {
    if (card.lifebar.style.height != .px or card.lifebar.style.height.px != bar_h) {
        card.lifebar.style.height = .fixed(bar_h);
        card.lifebar.markSizingDirty();
    }
}

fn buildReply(card: *Card, p: BuildParams, scope: *Scope, row: *Node, content: *Content) !void {
    const cx = p.cx;
    const pal = p.palette;
    const field = try box(cx, .{
        .width = .fill(),
        .height = .fixed(M.reply_height),
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = M.reply_padding,
        .background = pal.reply_field,
        .border = .{ .width = 0.5, .color = pal.reply_border, .radius = M.button_radius },
    }, .{});
    try appendOwned(cx, row, field);
    (try ext(cx, field)).corner_radius = core.CornerRadius.uniform(M.button_radius);

    // 嵌入模式：只保留文本编辑，外壳由这里绘制（与 ComboBox 同款）。
    const result = try input_mod.Input(.{
        .placeholder = p.strings.reply_placeholder,
        .placeholder_color = pal.ink_3,
        .size = .sm,
        .embedded = true,
    }).mountResult(scope, cx);
    field.appendChild(cx.allocator, result.node) catch |err| {
        result.abandon(cx);
        return err;
    };
    result.node.style.width = .fill();
    result.node.style.flex_shrink = 1;
    result.input_container.setBackground(Color.TRANSPARENT);
    result.input_container.setBorderColor(Color.TRANSPARENT);
    result.input_container.style.border.width = 0;
    result.input_container.style.padding = Padding.ZERO;
    result.input_container.style.height = .fixed(M.reply_height - 2);
    // 水平内边距由回复框外壳（左 11）负责；Input 内部那层（sm 档 8）归零，
    // 光标命中测试读同一个 padding_h，外观与命中一起对齐。
    result.state.padding_h = 0;
    result.input_container.markSizingDirty();
    result.node.behavior.events.key_context = @ptrCast(card);
    result.node.behavior.events.on_key_down = replyKeyDown;
    content.reply_input = result.input_container;
    content.reply_state = result.state;
    result.node.meta.ownership.meta.component_name = "Notification.reply";

    const kbd = try core.text(cx, "↵", .{ .color = pal.ink_3, .font_size = M.timestamp_size });
    try appendOwned(cx, field, kbd);
    kbd.style.flex_shrink = 0;

    const send = try button_mod.Button(.{
        .label = p.strings.send,
        .variant = .secondary,
        .size = .xs,
        .on_event = buttonEvent,
        .style = .{
            .height = .fixed(M.send_height),
            .padding = Padding.symmetric(0, 10),
            .background = pal.button_primary,
            .border = .{ .width = 0, .color = pal.button_primary, .radius = M.send_radius },
            .text_color = pal.ink,
            .font_size = M.send_font,
            .font_weight = 600,
        },
        .hover_style = .{ .background = pal.button_primary_hover, .border = .{ .width = 0, .color = pal.button_primary_hover, .radius = M.send_radius } },
        .pressed_style = .{ .background = pal.button_primary_hover, .border = .{ .width = 0, .color = pal.button_primary_hover, .radius = M.send_radius } },
    }).mount(scope, cx);
    send.meta.ownership.meta.component_name = "Notification.send";
    try appendOwned(cx, field, send);
    send.style.flex_shrink = 0;
    content.send_button = send;
}

fn replyKeyDown(key: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) core.EventResult {
    if (key != .@"return") return .ignored;
    const card: *Card = @ptrCast(@alignCast(context orelse return .ignored));
    const state = card.content.reply_state orelse return .ignored;
    // 输入法组字中的回车属于候选确认，不是提交。
    if (state.imeIsComposing()) return .ignored;
    card.button_sink(card, send_index);
    return .stop;
}

/// 按钮上下文指向 card.content 内的数组元素；content 落位后调用。
pub fn rebindButtons(card: *Card) void {
    if (card.content.send_button) |send| {
        card.content.send_context = .{ .card = card, .index = send_index };
        send.behavior.events.event_context = @ptrCast(&card.content.send_context);
    }
    for (card.content.buttons, 0..) |maybe, i| {
        if (maybe) |btn| {
            card.content.button_contexts[i] = .{ .card = card, .index = @intCast(i) };
            btn.behavior.events.event_context = @ptrCast(&card.content.button_contexts[i]);
        }
    }
}

fn reorderSurface(card: *Card, content_root: *Node) !void {
    var order: [8]*Node = undefined;
    var n: usize = 0;
    for (card.surface.children.items) |child| {
        if (child == card.lifebar or child == content_root) continue;
        order[n] = child;
        n += 1;
    }
    order[n] = content_root;
    n += 1;
    order[n] = card.lifebar;
    n += 1;
    try card.surface.replaceChildOrder(card.cx.allocator, order[0..n]);
}

fn buildLead(card: *Card, p: BuildParams, lead_box: *Node) !*Node {
    const cx = p.cx;
    const pal = p.palette;
    const spec = card.spec;
    const tone = pal.tone(spec.tone);
    switch (spec.lead) {
        .chip, .spinner => {
            const chip = try box(cx, .{
                .width = .fixed(M.lead_size),
                .height = .fixed(M.lead_size),
                .align_items = .center,
                .justify = .center,
                .background = tone,
                .border = .{ .width = 0, .color = tone, .radius = M.chip_radius },
            }, .{});
            try appendOwned(cx, lead_box, chip);
            (try ext(cx, chip)).corner_radius = core.CornerRadius.uniform(M.chip_radius);
            if (spec.lead == .chip) {
                const glyph = try core.iconTint(cx, spec.glyph orelse defaultGlyph(spec.tone), pal.on_semantic, .{
                    .width = .fixed(M.glyph_size),
                    .height = .fixed(M.glyph_size),
                });
                try appendOwned(cx, chip, glyph);
            } else {
                const arc = try box(cx, .{ .width = .fixed(M.spinner_size), .height = .fixed(M.spinner_size) }, .{});
                try appendOwned(cx, chip, arc);
                arc.setCustomDraw(spinnerDraw, @ptrCast(card));
            }
            return chip;
        },
        .ring => {
            // 环本体是 custom draw 节点（不绘制子节点），秒数作为兄弟节点绝对定位叠在中心。
            const ring = try box(cx, .{ .width = .fixed(M.ring_size), .height = .fixed(M.ring_size) }, .{});
            try appendOwned(cx, lead_box, ring);
            ring.setCustomDraw(ringDraw, @ptrCast(card));
            const secs_box = try box(cx, .{
                .position = .absolute,
                .width = .fixed(M.ring_size),
                .height = .fixed(M.ring_size),
                .align_items = .center,
                .justify = .center,
            }, .{});
            try appendOwned(cx, lead_box, secs_box);
            (try ext(cx, secs_box)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
            const secs = try core.text(cx, "", .{ .color = pal.ink, .font_size = M.ring_secs_size, .font_weight = 600 });
            try appendOwned(cx, secs_box, secs);
            setMonospace(secs);
            return ring;
        },
        .avatar => {
            const avatar = try box(cx, .{
                .width = .fixed(M.lead_size),
                .height = .fixed(M.lead_size),
                .align_items = .center,
                .justify = .center,
                .background = pal.avatar_bg,
                .border = .{ .width = 0, .color = pal.avatar_bg, .radius = M.lead_size / 2 },
            }, .{});
            try appendOwned(cx, lead_box, avatar);
            (try ext(cx, avatar)).corner_radius = core.CornerRadius.uniform(M.lead_size / 2);
            const initial = try core.text(cx, spec.avatar, .{ .color = pal.avatar_fg, .font_size = M.avatar_initial_size, .font_weight = 600 });
            try appendOwned(cx, avatar, initial);
            return avatar;
        },
        .dot => {
            const dot = try box(cx, .{
                .width = .fixed(M.quiet_dot),
                .height = .fixed(M.quiet_dot),
                .background = tone,
                .border = .{ .width = 0, .color = tone, .radius = M.quiet_dot / 2 },
            }, .{});
            try appendOwned(cx, lead_box, dot);
            (try ext(cx, dot)).corner_radius = core.CornerRadius.uniform(M.quiet_dot / 2);
            return dot;
        },
    }
}

/// 销毁内容层：先失效 hook、dispose scope，再摘链释放（与 For 同序）。
pub fn destroyContent(cx: *Cx, parent: *Node, content: *Content) void {
    // 按钮的事件上下文指向 card.content 内的槽位：原地转换时 card.content 已换成新内容，
    // 释放旧按钮会派发 blur 等事件（焦点在按钮上时），先摘掉处理器，免得读到新内容的槽位。
    for (content.buttons) |maybe| {
        if (maybe) |btn| {
            btn.behavior.events.on_event = null;
            btn.behavior.events.event_context = null;
        }
    }
    if (content.send_button) |btn| {
        btn.behavior.events.on_event = null;
        btn.behavior.events.event_context = null;
    }
    hooks.invalidateSubtreeHookState(content.root);
    if (!content.scope.disposed) content.scope.dispose();
    core.clearNodeScopes(content.root);
    if (content.root.parent != null) cx.detachChildRetained(parent, content.root);
    cx.freeNode(content.root);
}

// ============================================================================
// Custom draw：旋转指示器 / 倒计时环
// ============================================================================

fn spinnerDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const card: *Card = @ptrCast(@alignCast(context orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    // 260° 弧，0.9s 一圈。
    const turn: f32 = @floatCast(@mod(card.draw_now_ms, 900.0) / 900.0);
    const start = -std.math.pi / 2.0 + turn * std.math.tau;
    const sweep: f32 = 260.0 / 360.0 * std.math.tau;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = M.spinner_size / 2,
        .stroke_width = M.spinner_stroke,
        .start_angle = start,
        .end_angle = start + sweep,
        .color = Color.WHITE,
    } });
}

fn ringDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const card: *Card = @ptrCast(@alignCast(context orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    const pal = styles.palette(card.cx.tokens);
    const top = -std.math.pi / 2.0;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = M.ring_size / 2,
        .stroke_width = M.ring_stroke,
        .start_angle = top,
        .end_angle = top + std.math.tau,
        .color = pal.track,
    } });
    const frac = card.life.fraction(card.draw_now_ms);
    if (frac <= 0.001) return;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = M.ring_size / 2,
        .stroke_width = M.ring_stroke,
        .start_angle = top,
        .end_angle = top + frac * std.math.tau,
        .color = pal.info,
    } });
}
