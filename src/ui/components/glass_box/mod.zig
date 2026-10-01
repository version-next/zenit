/// GlassBox Component
///
/// 基于现有 Liquid Glass 渲染能力的 UI 面板组件。
/// 与直接写死 preset 不同，GlassBox 会在 before_render 阶段根据真实布局尺寸，
/// 自动把 blur / tint / refraction / warp 收敛到更适合承载文本内容的区间。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const CornerRadius = core.CornerRadius;
const Shadow = core.Shadow;
const theme = core.theme;
const Scope = @import("../../reactive.zig").Scope;
const ScrollState = @import("../scroll_area/state.zig").ScrollState;
const Event = @import("../../events.zig").Event;
const EventResult = @import("../../events.zig").EventResult;

pub const GlassBoxReadability = enum {
    balanced,
    preferred,
    maximum,
};

/// 对应 Apple Liquid Glass 的两种官方材质变体：
/// .regular = 自适应、保证内容可读（默认，适合承载文本/控件）；
/// .clear = 高度透明、几乎不加 tint/雾化，适合覆盖在媒体等丰富内容上
///          （Apple 要求 clear 下层自带 dimming，文本靠自身阴影保证可读）。
pub const GlassBoxVariant = enum {
    regular,
    clear,
};

pub const GlassBoxEmphasis = enum {
    subtle,
    regular,
    prominent,
};

// header 文本样式已析出到 styles.zig
const styles = @import("styles.zig");
const glassTitleStyle = styles.glassTitleStyle;
const glassSubtitleStyle = styles.glassSubtitleStyle;

pub const GlassBoxProps = struct {
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    padding: ?Padding = null,
    body_gap: f32 = 12,
    radius: f32 = 18,
    readability: GlassBoxReadability = .preferred,
    emphasis: GlassBoxEmphasis = .regular,
    variant: GlassBoxVariant = .regular,
    tint: ?Color = null,
    /// Apple Liquid Glass interactive：hover 提亮高光、press 玻璃增厚 + 微放大。
    interactive: bool = false,
    /// scroll-edge effect：绑定 ScrollArea 后，内容滚过玻璃边缘时出现渐进
    /// 模糊/压暗带（随滚动位置实时驱动 + 插值平滑）。
    scroll_edge: ?ScrollEdgeBinding = null,
};

pub const ScrollEdge = enum(u8) { top = 1, bottom = 2, left = 3, right = 4 };

pub const ScrollEdgeBinding = struct {
    /// 被玻璃覆盖的 ScrollArea 的滚动状态
    scroll: *ScrollState,
    edge: ScrollEdge = .top,
    /// 渐变带宽度（逻辑像素）
    fade_width: f32 = 32,
    /// 满强度所需滚动距离（逻辑像素）
    ramp_distance: f32 = 28,
    max_strength: f32 = 0.9,
};

pub fn GlassBox(props: GlassBoxProps) GlassBoxBuilder {
    return .{ .props = props };
}

pub const GlassBoxBuilder = struct {
    props: GlassBoxProps,

    pub fn title(self: GlassBoxBuilder, value: []const u8) GlassBoxBuilder {
        var next = self;
        next.props.title = value;
        return next;
    }

    pub fn subtitle(self: GlassBoxBuilder, value: []const u8) GlassBoxBuilder {
        var next = self;
        next.props.subtitle = value;
        return next;
    }

    pub fn width(self: GlassBoxBuilder, value: f32) GlassBoxBuilder {
        var next = self;
        next.props.width = value;
        return next;
    }

    pub fn height(self: GlassBoxBuilder, value: f32) GlassBoxBuilder {
        var next = self;
        next.props.height = value;
        return next;
    }

    pub fn padding(self: GlassBoxBuilder, value: Padding) GlassBoxBuilder {
        var next = self;
        next.props.padding = value;
        return next;
    }

    pub fn radius(self: GlassBoxBuilder, value: f32) GlassBoxBuilder {
        var next = self;
        next.props.radius = value;
        return next;
    }

    pub fn readability(self: GlassBoxBuilder, value: GlassBoxReadability) GlassBoxBuilder {
        var next = self;
        next.props.readability = value;
        return next;
    }

    pub fn emphasis(self: GlassBoxBuilder, value: GlassBoxEmphasis) GlassBoxBuilder {
        var next = self;
        next.props.emphasis = value;
        return next;
    }

    pub fn variant(self: GlassBoxBuilder, value: GlassBoxVariant) GlassBoxBuilder {
        var next = self;
        next.props.variant = value;
        return next;
    }

    pub fn tint(self: GlassBoxBuilder, value: Color) GlassBoxBuilder {
        var next = self;
        next.props.tint = value;
        return next;
    }

    pub fn interactive(self: GlassBoxBuilder, value: bool) GlassBoxBuilder {
        var next = self;
        next.props.interactive = value;
        return next;
    }

    pub fn scrollEdge(self: GlassBoxBuilder, value: ScrollEdgeBinding) GlassBoxBuilder {
        var next = self;
        next.props.scroll_edge = value;
        return next;
    }

    pub fn mount(self: GlassBoxBuilder, scope: *Scope, cx: *Cx) !*Node {
        const mounted = try self.mountBody(scope, cx);
        return mounted.box;
    }

    /// morph / 亮度自适应等需要拿状态句柄的场景用这个入口。
    pub fn mountWithState(self: GlassBoxBuilder, scope: *Scope, cx: *Cx) !GlassBoxMount {
        const mounted = try self.mountBody(scope, cx);
        const raw = mounted.box.meta.per_frame.hooks.slots.anim_state.?;
        return .{
            .box = mounted.box,
            .body = mounted.body,
            .state = @ptrCast(@alignCast(raw)),
        };
    }

    pub fn mountBody(self: GlassBoxBuilder, scope: *Scope, cx: *Cx) !struct { box: *Node, body: *Node } {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const tokens = cx.tokens;
        const p = self.props;
        const base_padding = p.padding orelse Padding.all(16);
        const corner_radius = @max(p.radius, 0);

        const root = try box(cx, .{
            .width = if (p.width) |value| .{ .px = value } else .{ .fit = .{} },
            .height = if (p.height) |value| .{ .px = value } else .{ .fit = .{} },
            .direction = .column,
            .position = .relative,
        }, .{});
        root.meta.ownership.meta.component_name = "GlassBox";
        // sweep：root 守卫一直武装到 return（bind 之后 freeNode 连带 dispose my_scope）；子节点建好即 adopt
        errdefer cx.freeNode(root);
        try core.bindScopeToNode(my_scope, root);

        // 分层：root wrapper 只持 shadow，glass 落在 in-flow 的 surface 子节点。
        // ① glass 节点自带 shadow 会把 promoted surface bounds 撑大 -> 合成出
        //    矩形切块（框架 bug）；② absolute surface 会让 backdrop 采样错位。
        const surface = try core.adoptChild(cx, allocator, root, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
        }, .{}));
        surface.style.border = .{ .width = 1, .color = Color.rgba(255, 255, 255, 112), .radius = corner_radius };
        surface.setBackgroundRaw(Color.rgba(255, 255, 255, 16));
        (try surface.style.ensureExtFallible(allocator)).corner_radius = CornerRadius.uniform(corner_radius);

        const content_wrapper = try core.adoptChild(cx, allocator, surface, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = if (p.height != null) .{ .grow = .{} } else .{ .fit = .{} },
            .direction = .column,
            .gap = p.body_gap,
            .padding = base_padding,
            .position = .relative,
        }, .{}));

        if (p.title != null or p.subtitle != null) {
            const header = try core.adoptChild(cx, allocator, content_wrapper, try box(cx, .{
                .width = .{ .grow = .{} },
                .direction = .column,
                .gap = 4,
            }, .{}));

            if (p.title) |title_text| {
                const title_node = try core.adoptChild(cx, allocator, header, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                var title_props = glassTitleStyle(tokens);
                title_props.content = title_text;
                title_node.setText(title_props);
            }

            if (p.subtitle) |subtitle_text| {
                const subtitle_node = try core.adoptChild(cx, allocator, header, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                var subtitle_props = glassSubtitleStyle(tokens);
                subtitle_props.content = subtitle_text;
                subtitle_node.setText(subtitle_props);
            }
        }

        const body = try core.adoptChild(cx, allocator, content_wrapper, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = if (p.height != null) .{ .grow = .{} } else .{ .fit = .{} },
            .direction = .column,
            .gap = p.body_gap,
        }, .{}));

        const adaptive = try allocator.create(AdaptiveGlassBoxState);
        adaptive.* = .{
            .allocator = allocator,
            .cx = cx,
            .surface = surface,
            .theme_tokens = tokens,
            .radius = corner_radius,
            .readability = p.readability,
            .emphasis = p.emphasis,
            .variant = p.variant,
            .tint_override = p.tint,
        };
        try my_scope.adoptResource(@ptrCast(adaptive), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(ptr));
                alloc.destroy(state);
            }
        }.cleanup);

        adaptive.interactive = p.interactive;
        adaptive.scroll_edge = p.scroll_edge;
        adaptive.root = root;
        root.meta.per_frame.hooks.slots.anim_state = @ptrCast(adaptive);
        root.addBeforeRender(glassBoxBeforeRender);

        if (p.interactive) {
            root.style.cursor = .pointer;
            (try root.style.ensureExtFallible(allocator)).hit_roles = .{ .pointer = true };
            root.behavior.events.event_context = @ptrCast(adaptive);
            root.behavior.events.on_event = interactiveGlassEventHandler;
        }

        // 先应用一次 fallback，避免挂载后在测试中读取到空参数。
        applyAdaptiveGlass(root, adaptive, resolvedGlassBoxStyle(tokens, p.readability, p.emphasis, p.variant, p.tint, 220, p.height orelse 140, null));

        return .{ .box = root, .body = body };
    }
};

pub const GlassBoxMount = struct {
    box: *Node,
    body: *Node,
    state: *AdaptiveGlassBoxState,
};

/// 启动玻璃形变过渡（morph）：几何（绝对 inset 定位）插值 + 两端玻璃参数场
/// 逐字段过渡。root 需为 absolute 定位（caller 布局约定）。
pub fn glassMorphTo(state: *AdaptiveGlassBoxState, spec: MorphSpec) void {
    if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) std.debug.print("[morph] glassMorphTo called root={}\n", .{state.root != null});
    const root = state.root orelse return;
    const r = root.rectFromWorldOrFallback();
    const from_w = if (r.w > 0.5) r.w else 220;
    const from_h = if (r.h > 0.5) r.h else 140;
    const to_readability = spec.readability orelse state.readability;
    const to_emphasis = spec.emphasis orelse state.emphasis;
    const to_variant = spec.variant orelse state.variant;
    state.morph = .{
        .step = 1.0 / @as(f32, @floatFromInt(@max(spec.frames, 2))),
        .from = .{ r.x, r.y, from_w, from_h },
        .to = .{ spec.x, spec.y, spec.w, spec.h },
        .from_style = resolvedGlassBoxStyle(state.theme_tokens, state.readability, state.emphasis, state.variant, state.tint_override, from_w, from_h, state.live_luminance),
        .to_style = resolvedGlassBoxStyle(state.theme_tokens, to_readability, to_emphasis, to_variant, state.tint_override, spec.w, spec.h, state.live_luminance),
        .to_readability = to_readability,
        .to_emphasis = to_emphasis,
        .to_variant = to_variant,
    };
    root.markRenderDirty();
    state.surface.markRenderDirty();
}

fn lerpColor(a: Color, b: Color, t: f32) Color {
    return .{
        .r = @intFromFloat(lerp(@floatFromInt(a.r), @floatFromInt(b.r), t)),
        .g = @intFromFloat(lerp(@floatFromInt(a.g), @floatFromInt(b.g), t)),
        .b = @intFromFloat(lerp(@floatFromInt(a.b), @floatFromInt(b.b), t)),
        .a = @intFromFloat(lerp(@floatFromInt(a.a), @floatFromInt(b.a), t)),
    };
}

/// 玻璃参数场过渡：两端 ResolvedGlassBoxStyle 逐字段插值（f32 线性 +
/// Color 通道插值；enum 面型在 t=0.5 切换）。
fn lerpGlassBoxStyle(a: ResolvedGlassBoxStyle, b: ResolvedGlassBoxStyle, t: f32) ResolvedGlassBoxStyle {
    var out = if (t < 0.5) a else b;
    out.background = lerpColor(a.background, b.background, t);
    out.border_color = lerpColor(a.border_color, b.border_color, t);
    out.shadow = .{
        .color = lerpColor(a.shadow.color, b.shadow.color, t),
        .blur = lerp(a.shadow.blur, b.shadow.blur, t),
        .offset_x = lerp(a.shadow.offset_x, b.shadow.offset_x, t),
        .offset_y = lerp(a.shadow.offset_y, b.shadow.offset_y, t),
    };
    var g = out.glass;
    inline for (@typeInfo(core.GlassParams).@"struct".fields) |f| {
        if (f.type == f32) {
            @field(g, f.name) = lerp(@field(a.glass, f.name), @field(b.glass, f.name), t);
        }
    }
    g.glass_tint = lerpColor(a.glass.glass_tint orelse Color.rgba(255, 255, 255, 0), b.glass.glass_tint orelse Color.rgba(255, 255, 255, 0), t);
    out.glass = g;
    return out;
}

const ResolvedGlassBoxStyle = struct {
    background: Color,
    border_color: Color,
    shadow: Shadow,
    glass: core.GlassParams,
};

pub const AdaptiveGlassBoxState = struct {
    allocator: Allocator,
    cx: *Cx,
    surface: *Node,
    theme_tokens: *const theme.ThemeTokens,
    radius: f32,
    readability: GlassBoxReadability,
    emphasis: GlassBoxEmphasis,
    variant: GlassBoxVariant = .regular,
    tint_override: ?Color,
    last_width: f32 = -1,
    last_height: f32 = -1,
    last_style: ?ResolvedGlassBoxStyle = null,
    // interactive 状态（hover/press -> 玻璃响应）
    interactive: bool = false,
    /// boost 插值期间挂起了 surface 的渲染缓存（收敛帧恢复并补录）。
    boost_cache_suppressed: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    /// 当前动画插值（0 = 静息，0.5 = hover 目标，1.0 = press 目标）
    glass_boost: f32 = 0,
    // scroll-edge：随滚动位置驱动的边缘强度（带插值）
    scroll_edge: ?ScrollEdgeBinding = null,
    edge_strength: f32 = 0,
    /// blur_gradient.stops 指向这里（style 是 retained 的，slice 不能指向栈临时）
    edge_stops: [2]core.BlurGradient.Stop = .{ .{}, .{} },
    // morph：几何 + 玻璃参数场过渡
    morph: ?MorphState = null,
    root: ?*Node = null,
    // backdrop 亮度自适应：实测 luminance 的平滑值（null = 未启用，退回 theme 近似）
    live_luminance: ?f32 = null,
};

pub const MorphSpec = struct {
    /// 目标几何（root 节点的绝对 inset 定位；调用方需保证 root 为 absolute）
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// 目标玻璃 profile（null = 沿用当前）
    readability: ?GlassBoxReadability = null,
    emphasis: ?GlassBoxEmphasis = null,
    variant: ?GlassBoxVariant = null,
    /// 过渡帧数（60Hz 下 ~duration_ms/16）
    frames: u32 = 18,
};

const MorphState = struct {
    t: f32 = 0,
    step: f32,
    from: [4]f32, // x,y,w,h
    to: [4]f32,
    from_style: ResolvedGlassBoxStyle,
    to_style: ResolvedGlassBoxStyle,
    to_readability: GlassBoxReadability,
    to_emphasis: GlassBoxEmphasis,
    to_variant: GlassBoxVariant,
};

/// interactive：事件只翻状态位 + 标脏；参数收敛在 before_render 里做（带插值动画）
fn interactiveGlassEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .mouse_enter => {
            if (std.posix.getenv("ZENIT_DEBUG_GLASSHOVER") != null) std.debug.print("[ghandler] enter\n", .{});
            state.hovered = true;
        },
        .mouse_leave => {
            if (std.posix.getenv("ZENIT_DEBUG_GLASSHOVER") != null) std.debug.print("[ghandler] leave\n", .{});
            state.hovered = false;
            state.pressed = false;
        },
        .mouse_down => {
            if (std.posix.getenv("ZENIT_DEBUG_GLASSHOVER") != null) std.debug.print("[ghandler] down\n", .{});
            state.pressed = true;
        },
        .mouse_up => {
            if (std.posix.getenv("ZENIT_DEBUG_GLASSHOVER") != null) std.debug.print("[ghandler] up\n", .{});
            state.pressed = false;
        },
        else => return .ignored,
    }
    state.surface.markRenderDirty();
    return .ignored; // 不吞事件：内容里的按钮等仍正常响应
}

/// scroll-edge 的 blur 渐变 stops：边缘处满糊（1），fade_width 处回落到
/// 玻璃自身的基底糊度 `base_blur_level`, **不能**回落到 0。
///
/// stop strength 是绝对 blur_level（0 = 纯 sharp）。早先写成 1 -> 0，玻璃
/// 条在 fade 带以外的整段被渐变判成 sharp：内容一滚动，玻璃下的文字就
/// 锐利透出（2026-09-29 用户报告 GlassMotion scroll-edge「滚动后 blur 失效」）。
/// scroll-edge 是在玻璃基底之上**追加**边缘糊化，不是削掉玻璃本身的磨砂。
pub fn scrollEdgeStops(fade_width: f32, extent: f32, base_blur_level: f32) [2]core.BlurGradient.Stop {
    const fade_end = clampf(fade_width / @max(extent, 1), 0, 1);
    return .{
        .{ .pos = 0, .strength = 1 },
        .{ .pos = fade_end, .strength = clampf(base_blur_level, 0, 1) },
    };
}

fn glassBoxBeforeRender(node: *Node) void {
    const raw = node.meta.per_frame.hooks.slots.anim_state orelse return;
    const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(raw));

    // backdrop 亮度自适应：实测 luminance（1 帧滞后）经插值平滑后驱动
    // 参数场（避免逐帧回读噪声造成的明暗抖动）。无实测值时退回 theme 近似。
    var param_interp_active = false;
    // 逐 glass 亮度：按 surface node id 精确匹配自己那块背景的实测值（槽 key =
    // 拥有者 node id，滚动/布局变化下恒定），无匹配退回全局均值。这让每块玻璃
    // 适配**自己**的背景：面板背景随面板一起滚，亮度天然滚动不变；早先全局
    // 单值随视口内容构成摆动 -> 全体换装/变透明。
    const measured_lum: ?f32 = blk: {
        for (state.cx.backdrop_luminance_regions[0..state.cx.backdrop_luminance_region_count]) |reg| {
            if (reg.node_id == state.surface.id) break :blk reg.lum;
        }
        break :blk state.cx.backdrop_luminance;
    };
    if (measured_lum) |target_lum| {
        const cur = state.live_luminance orelse target_lum;
        const diff = target_lum - cur;
        if (@abs(diff) > 0.004) {
            state.live_luminance = cur + diff * 0.15;
            param_interp_active = true;
            state.surface.markRenderDirty();
            node.markRenderDirty();
        } else {
            state.live_luminance = target_lum;
        }
    }
    if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
        std.debug.print("[glassbr] node={d} surf={d} measured={d:.4} live={d:.4} interp={} cache_dis={} boost={d:.2}\n", .{
            node.id,
            state.surface.id,
            measured_lum orelse -1,
            state.live_luminance orelse -1,
            param_interp_active,
            state.surface.frame_state.state_bits.flags.disable_render_cache,
            state.glass_boost,
        });
    }

    // morph：几何插值 + 玻璃参数场过渡（进行中时接管 apply，跳过常规自适应）
    if (state.morph) |*m| {
        if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
            const rr = node.rectFromWorldOrFallback();
            std.debug.print("[morph] tick t={d:.2} rect=({d:.0},{d:.0},{d:.0}x{d:.0})\n", .{ m.t, rr.x, rr.y, rr.w, rr.h });
        }
        m.t = @min(m.t + m.step, 1.0);
        const t = m.t * m.t * (3.0 - 2.0 * m.t); // smoothstep ease
        const x = lerp(m.from[0], m.to[0], t);
        const y = lerp(m.from[1], m.to[1], t);
        const w = lerp(m.from[2], m.to[2], t);
        const h = lerp(m.from[3], m.to[3], t);
        node.style.width = .{ .px = w };
        node.style.height = .{ .px = h };
        // 每帧路径不拿 abort 兜底，分配失败就跳过这一帧，下一帧再来
        const ext = node.style.ensureExtFallible(state.allocator) catch return;
        ext.inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
        // width/height 的 World 同步走 sizing-dirty（markLayoutDirty 不重读 style，
        // 见 node_animator 同款处理）
        node.markSizingDirty();
        node.markLayoutDirty();
        const style = lerpGlassBoxStyle(m.from_style, m.to_style, t);
        applyAdaptiveGlass(node, state, style);
        if (m.t >= 1.0) {
            // 过渡完成：接管的 profile 落位，恢复常规自适应
            state.readability = m.to_readability;
            state.emphasis = m.to_emphasis;
            state.variant = m.to_variant;
            state.morph = null;
        } else {
            state.surface.markRenderDirty();
            node.markRenderDirty();
        }
        return;
    }

    // interactive 玻璃响应插值：press=1.0 > hover=0.45 > 静息=0
    if (state.interactive) {
        const target: f32 = if (state.pressed) 1.0 else if (state.hovered) 0.45 else 0.0;
        const diff = target - state.glass_boost;
        if (@abs(diff) > 0.005) {
            state.glass_boost += diff * 0.22; // ~ease-out，60Hz 下 ~12 帧收敛
            param_interp_active = true;
            state.surface.markRenderDirty(); // 驱动下一帧继续插值
            node.markRenderDirty();
        } else {
            state.glass_boost = target;
        }
    }
    // 参数插值（boost / 亮度自适应）进行中退出全部渲染缓存：glass 参数按值
    // 烘焙进缓存的 blur token，逐帧变化的参数配任何跨帧缓存都是 stale 回放
    //（真机 hover 冻结 + 滚动亮度跳变补课的共同根因）。收敛帧恢复资格并
    // 补一帧 fresh 重录（把 settled 参数录进缓存）。
    if (param_interp_active) {
        state.surface.frame_state.state_bits.flags.disable_render_cache = true;
        state.boost_cache_suppressed = true;
    } else if (state.boost_cache_suppressed) {
        state.boost_cache_suppressed = false;
        state.surface.frame_state.state_bits.flags.disable_render_cache = false;
        state.surface.markRenderDirty();
        node.markRenderDirty();
    }

    // 全局 hook 读 rect。
    const r = node.rectFromWorldOrFallback();
    const width = if (r.w > 0.5) r.w else 220;
    const height = if (r.h > 0.5) r.h else 140;
    var resolved = resolvedGlassBoxStyle(
        state.theme_tokens,
        state.readability,
        state.emphasis,
        state.variant,
        state.tint_override,
        width,
        height,
        state.live_luminance,
    );

    // scroll-edge effect：滚动位置 -> 目标强度，插值平滑后写进玻璃参数
    if (state.scroll_edge) |binding| {
        const scroll_amount = switch (binding.edge) {
            .top => binding.scroll.effectiveScrollY(),
            .bottom => binding.scroll.maxScrollY() - binding.scroll.effectiveScrollY(),
            .left => binding.scroll.effectiveScrollX(),
            .right => binding.scroll.maxScrollX() - binding.scroll.effectiveScrollX(),
        };
        const target = clampf(scroll_amount / @max(binding.ramp_distance, 1), 0, 1) * binding.max_strength;
        const diff = target - state.edge_strength;
        if (@abs(diff) > 0.005) {
            state.edge_strength += diff * 0.25;
            state.surface.markRenderDirty();
            node.markRenderDirty();
        } else {
            state.edge_strength = target;
        }
        // 映射到 blur_gradient：edge=起点边 -> CSS 方向（top ≡ to_bottom），
        // fade_width（逻辑 px）换算成占节点尺寸的 stop 百分比
        const extent: f32 = switch (binding.edge) {
            .top, .bottom => height,
            .left, .right => width,
        };
        state.edge_stops = scrollEdgeStops(binding.fade_width, extent, resolved.glass.blur_level);
        resolved.glass.blur_gradient = .{
            .direction = switch (binding.edge) {
                .top => .to_bottom,
                .bottom => .to_top,
                .left => .to_right,
                .right => .to_left,
            },
            .strength = state.edge_strength,
            .stops = &state.edge_stops,
        };
    }

    // interactive boost：高光提亮 + 玻璃增厚 + 折射感增强（press 最强）
    if (state.interactive and state.glass_boost > 0.001) {
        const b = state.glass_boost;
        resolved.glass.specular_opacity = @min(resolved.glass.specular_opacity + 0.18 * b, 0.6);
        resolved.glass.glass_intensity *= 1.0 + 0.30 * b;
        resolved.glass.center_thickness += 1.6 * b;
        resolved.glass.warp_gain *= 1.0 + 0.15 * b;
        // 可见性主通道：玻璃 tint 增浓 + 背景/边框提亮。纯参数 boost（specular/
        // intensity/thickness/warp）在中小面板上的像素差 ≤4/通道，肉眼不可见,
        // 原实现的可见反馈其实来自那个害人的 1.2% scale；bg/border 提亮又大半
        // 被玻璃合成盖住（实测 hover->press 仅 maxΔ35）。glass_tint 直接参与
        // 玻璃合成，是真正的可见旋钮。提亮量随 boost 插值，press 最亮。
        // hover 段（b≤0.45）：提亮。press 段（b>0.45）：Apple 惯例压暗,
        // 提亮通道在已亮的 hover 态上边际递减（实测 hover->press 仅 maxΔ37），
        // 压暗不会被洗掉，press 一眼可辨。
        resolved.background = lerpColor(resolved.background, Color.rgba(255, 255, 255, 140), 0.8 * @min(b, 0.45));
        resolved.border_color = lerpColor(resolved.border_color, Color.rgba(255, 255, 255, 245), 0.8 * @min(b, 0.45));
        const press_f = std.math.clamp((b - 0.45) / 0.55, 0.0, 1.0);
        if (press_f > 0.001) {
            const tint0 = resolved.glass.glass_tint orelse Color.rgba(255, 255, 255, 0);
            resolved.glass.glass_tint = Color.rgba(
                @intFromFloat(@as(f32, @floatFromInt(tint0.r)) * (1.0 - 0.45 * press_f)),
                @intFromFloat(@as(f32, @floatFromInt(tint0.g)) * (1.0 - 0.45 * press_f)),
                @intFromFloat(@as(f32, @floatFromInt(tint0.b)) * (1.0 - 0.45 * press_f)),
                @intFromFloat(@min(255.0, @as(f32, @floatFromInt(tint0.a)) + 90.0 * press_f)),
            );
            resolved.background = lerpColor(resolved.background, Color.rgba(24, 28, 38, 110), 0.5 * press_f);
        }
    }

    if (@abs(width - state.last_width) <= 0.5 and
        @abs(height - state.last_height) <= 0.5 and
        state.last_style != null and
        std.meta.eql(state.last_style.?, resolved))
    {
        return;
    }

    applyAdaptiveGlass(node, state, resolved);
}

fn applyAdaptiveGlass(node: *Node, state: *AdaptiveGlassBoxState, resolved: ResolvedGlassBoxStyle) void {
    const surface = state.surface;
    surface.setBackgroundRaw(resolved.background);
    surface.style.border = .{
        .width = 1,
        .color = resolved.border_color,
        .radius = state.radius,
    };

    // 每帧路径不拿 abort 兜底（sweep 实测 mount 期 OOM 直接 signal 6），失败就跳过这一帧
    const ext = surface.style.ensureExtFallible(state.allocator) catch return;
    ext.corner_radius = CornerRadius.uniform(state.radius);
    ext.glass = resolved.glass;
    // shadow 挂 root wrapper：glass 节点带 shadow 会触发矩形切块（见 mountBody 注释）
    const root_ext = node.style.ensureExtFallible(state.allocator) catch return;
    root_ext.corner_radius = CornerRadius.uniform(state.radius);
    root_ext.setShadow(resolved.shadow);
    // 刻意无微放大：任何非 1 的 scale 会让 root 走 opacity-layer offscreen
    // 合成，而 backdrop_blur 玻璃在 offscreen surface 内采不到背景 -> hover 时
    // 整个面板（blur+子内容）消失只剩壳（实测；同 nav lens "glass+scale" 禁忌
    // 注释）。交互响应全部走玻璃参数场（specular/intensity/thickness/warp），
    // 待框架支持 glass 进 scaled surface 后再恢复 1.2% 微放大。

    state.last_style = resolved;
    // 全局 hook 读 rect。
    const r = node.rectFromWorldOrFallback();
    state.last_width = r.w;
    state.last_height = r.h;
    surface.markRenderDirty();
}

fn resolvedGlassBoxStyle(
    tokens: *const theme.ThemeTokens,
    readability: GlassBoxReadability,
    emphasis: GlassBoxEmphasis,
    variant: GlassBoxVariant,
    tint_override: ?Color,
    width: f32,
    height: f32,
    live_luminance: ?f32,
) ResolvedGlassBoxStyle {
    const w = @max(width, 72);
    const h = @max(height, 36);
    const min_dim = @min(w, h);
    const area = w * h;
    const compactness = norm01(88 - min_dim, 0, 52);
    const spaciousness = norm01(min_dim - 96, 0, 160);
    const panel_scale = norm01(area - 12000, 0, 90000);

    const readability_bias: f32 = switch (readability) {
        .balanced => 0.35,
        .preferred => 0.68,
        .maximum => 1.0,
    };
    const emphasis_bias: f32 = switch (emphasis) {
        .subtle => 0.0,
        .regular => 0.5,
        .prominent => 1.0,
    };

    // backdrop 亮度：有实测（luminance 降采样回读）用实测，否则 theme 近似。
    // darkness 是**连续**因子（0=亮 1=暗）。⚠ 不允许任何硬阈值离散翻转：
    // 实测 luminance 是**全窗口**单点值，滚动改变视口内容构成就会摆动,
    // 早先 `is_dark_theme = darkness > 0.55` 让滚动跨阈值时所有玻璃在
    // "白底/tint 深底"之间整体换装（下游应用验收实拍）。色相/背景/阴影全部
    // 改为随 dark_factor 连续混合，摆动只表现为轻微渐变。
    const lum = live_luminance orelse relativeLuminance(tokens.color.bg_primary);
    const darkness = norm01(0.5 - lum, 0.0, 0.35);
    // 平滑的深色权重：darkness 0.35->0.75 之间线性过渡（原阈值 0.55 居中）。
    const dark_factor = norm01(darkness - 0.35, 0.0, 0.4);
    const is_dark_theme = dark_factor > 0.5; // 仅存量非视觉分支（specular 角度）使用
    const base_background_alpha: f32 = lerp(12.0, 34.0, darkness);
    const base_border_alpha: f32 = lerp(104.0, 88.0, darkness);
    const base_shadow_alpha: f32 = lerp(22.0, 56.0, darkness);

    const tint_alpha = alphaU8(
        104 +
            readability_bias * 54 +
            panel_scale * 16 -
            compactness * 8 +
            emphasis_bias * 10,
    );
    const background_alpha = alphaU8(
        base_background_alpha +
            readability_bias * 16 +
            compactness * 6 +
            emphasis_bias * 4,
    );
    const border_alpha = alphaU8(
        base_border_alpha +
            readability_bias * 22 +
            emphasis_bias * 10,
    );
    const shadow_alpha = alphaU8(
        base_shadow_alpha +
            readability_bias * 10 +
            panel_scale * 10 +
            emphasis_bias * 6,
    );

    // Apple .clear：材质本体几乎不遮挡背景，tint/雾化大幅降低、折射保留，
    // 可读性交给下层 dimming（HIG：亮媒体上叠 35% 黑）与文本自身。
    const is_clear = variant == .clear;
    const clear_scale: f32 = if (is_clear) 0.30 else 1.0;

    const tint_a = alphaU8(@as(f32, @floatFromInt(tint_alpha)) * clear_scale);
    const tint = lerpColor(autoTint(false, tint_override, tint_a), autoTint(true, tint_override, tint_a), dark_factor);
    const bg_a = alphaU8(@as(f32, @floatFromInt(background_alpha)) * clear_scale);
    const background = lerpColor(
        Color.rgba(255, 255, 255, bg_a),
        Color.rgba(tint.r, tint.g, tint.b, bg_a),
        dark_factor,
    );
    const border_color = Color.rgba(255, 255, 255, if (is_clear) alphaU8(@as(f32, @floatFromInt(border_alpha)) * 0.7) else border_alpha);

    return .{
        .background = background,
        .border_color = border_color,
        .shadow = .{
            .color = lerpColor(Color.rgba(10, 18, 34, shadow_alpha), Color.rgba(0, 0, 0, shadow_alpha), dark_factor),
            .blur = lerp(14, 28, panel_scale) + emphasis_bias * 4,
            .offset_x = 0,
            .offset_y = lerp(4, 10, panel_scale) + emphasis_bias * 1.5,
        },
        .glass = .{
            // clear 变体：更少雾化、背景更直接透出（折射保留，雾化降低）
            .backdrop_blur = (lerp(14, 26, readability_bias) + panel_scale * 2 + compactness * 1.5) * (if (is_clear) @as(f32, 0.5) else 1.0),
            .glass_tint = tint,
            .glass_intensity = clampf(0.74 + emphasis_bias * 0.22 + spaciousness * 0.06 - readability_bias * 0.12, 0.62, 1.08),
            .specular_opacity = clampf(0.10 + emphasis_bias * 0.14 + spaciousness * 0.03 - readability_bias * 0.03, 0.08, 0.3),
            .specular_saturation = clampf(3.6 + emphasis_bias * 1.4 - readability_bias * 0.6, 3.0, 5.6),
            .refraction_level = clampf(0.58 + emphasis_bias * 0.14 + panel_scale * 0.08 - readability_bias * 0.28 - compactness * 0.08 + (if (is_clear) @as(f32, 0.12) else 0.0), 0.22, 0.98),
            .blur_level = if (is_clear)
                clampf(0.34 + readability_bias * 0.12, 0.25, 0.5)
            else
                clampf(0.72 + readability_bias * 0.24 + compactness * 0.06, 0.68, 1.0),
            .warp_gain = clampf(0.34 + emphasis_bias * 0.28 + panel_scale * 0.1 - readability_bias * 0.16 - compactness * 0.08, 0.18, 0.82),
            .center_thickness = clampf(1.0 + emphasis_bias * 0.6 + spaciousness * 0.9 + panel_scale * 0.7 - readability_bias * 0.45, 0.7, 3.2),
            .surface = .convex_squircle,
            .bezel_width = clampf(0.12 + emphasis_bias * 0.04 + compactness * 0.02, 0.1, 0.22),
            .bottom_surface = .flat,
            .bottom_bezel_width = clampf(0.08 + emphasis_bias * 0.03, 0.08, 0.16),
            .specular_angle = if (is_dark_theme) -std.math.pi / 2.7 else -std.math.pi / 3.1,
            .magnification = clampf(emphasis_bias * 0.06 - readability_bias * 0.06 - compactness * 0.03, -0.08, 0.08),
            .scale_ratio = clampf(0.9 + panel_scale * 0.08 - readability_bias * 0.05, 0.82, 1.02),
            .edge_field_strength = clampf(0.32 + emphasis_bias * 0.28 + panel_scale * 0.08 - readability_bias * 0.14, 0.18, 0.78),
            .center_zoom_radius = clampf(0.48 + panel_scale * 0.08 - readability_bias * 0.06, 0.38, 0.6),
            .center_zoom_falloff = clampf(2.4 + readability_bias * 1.0 - emphasis_bias * 0.15, 2.2, 3.6),
            .backdrop_distance = clampf(1.2 + emphasis_bias * 1.6 + panel_scale * 2.6 - readability_bias * 0.3, 0.8, 5.6),
        },
    };
}

fn autoTint(is_dark_theme: bool, tint_override: ?Color, alpha: u8) Color {
    if (tint_override) |override| {
        return .{
            .r = override.r,
            .g = override.g,
            .b = override.b,
            .a = @max(override.a, alpha),
        };
    }

    return if (is_dark_theme)
        Color.rgba(44, 52, 66, alpha)
    else
        Color.rgba(244, 247, 252, alpha);
}

fn norm01(value: f32, min: f32, max: f32) f32 {
    if (max <= min) return 0;
    return clampf((value - min) / (max - min), 0, 1);
}

fn lerp(from: f32, to: f32, t: f32) f32 {
    return from + (to - from) * clampf(t, 0, 1);
}

fn clampf(value: f32, min: f32, max: f32) f32 {
    return std.math.clamp(value, min, max);
}

fn alphaU8(value: f32) u8 {
    return @intFromFloat(clampf(value, 0, 255));
}

fn channelToLinear(c: u8) f32 {
    const v = @as(f32, @floatFromInt(c)) / 255.0;
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn relativeLuminance(c: Color) f32 {
    const r = channelToLinear(c.r);
    const g = channelToLinear(c.g);
    const b = channelToLinear(c.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

fn runBeforeRenderHooks(node: *Node) void {
    if (node.meta.per_frame.hooks.before_render.main) |hook| hook(node);
    for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |hook_opt| {
        if (hook_opt) |hook| hook(node);
    }
}

test "GlassBox: mountBody installs adaptive liquid glass" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 520 },
        .height = .{ .px = 320 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const mounted = try GlassBox(.{
        .title = "Overview",
        .subtitle = "Readable liquid glass panel",
        .width = 320,
        .height = 180,
    }).mountBody(scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.box);

    ctx.layout();
    runBeforeRenderHooks(mounted.box);

    try std.testing.expectEqualStrings("GlassBox", mounted.box.meta.ownership.meta.component_name.?);
    try std.testing.expectEqual(@as(usize, 1), mounted.box.children.items.len);
    const surface_node = mounted.box.children.items[0];
    try std.testing.expect(surface_node.style.glass_params() != null);
    try std.testing.expect(surface_node.style.border.width > 0);
    try std.testing.expect(surface_node.getBackground().a > 0);
    try std.testing.expectEqual(@as(usize, 2), surface_node.children.items[0].children.items.len);
}

test "GlassBox: maximum readability trades distortion for blur and tint" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 400 },
        .direction = .row,
        .gap = 24,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const balanced = try GlassBox(.{
        .width = 280,
        .height = 160,
        .readability = .balanced,
    }).mount(scope, ctx);
    const maximum = try GlassBox(.{
        .width = 280,
        .height = 160,
        .readability = .maximum,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, balanced);
    try root.appendChild(std.testing.allocator, maximum);

    ctx.layout();
    runBeforeRenderHooks(balanced);
    runBeforeRenderHooks(maximum);

    const gp_balanced = balanced.children.items[0].style.glass_params().?;
    const gp_maximum = maximum.children.items[0].style.glass_params().?;

    try std.testing.expect(gp_maximum.refraction_level < gp_balanced.refraction_level);
    try std.testing.expect(gp_maximum.warp_gain < gp_balanced.warp_gain);
    try std.testing.expect(gp_maximum.blur_level > gp_balanced.blur_level);
    try std.testing.expect(gp_maximum.glass_tint.?.a > gp_balanced.glass_tint.?.a);
}

test "GlassBox: clear variant is markedly more transparent than regular" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 400 },
        .direction = .row,
        .gap = 24,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const regular = try GlassBox(.{ .width = 280, .height = 160 }).mount(scope, ctx);
    const clear = try GlassBox(.{ .width = 280, .height = 160, .variant = .clear }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, regular);
    try root.appendChild(std.testing.allocator, clear);

    ctx.layout();
    runBeforeRenderHooks(regular);
    runBeforeRenderHooks(clear);

    const gp_regular = regular.children.items[0].style.glass_params().?;
    const gp_clear = clear.children.items[0].style.glass_params().?;

    // clear：雾化显著低、tint 更弱、折射不弱于 regular
    try std.testing.expect(gp_clear.blur_level < gp_regular.blur_level - 0.2);
    try std.testing.expect(gp_clear.backdrop_blur < gp_regular.backdrop_blur);
    try std.testing.expect(gp_clear.glass_tint.?.a < gp_regular.glass_tint.?.a);
    try std.testing.expect(gp_clear.refraction_level >= gp_regular.refraction_level);
    try std.testing.expect(clear.children.items[0].getBackground().a < regular.children.items[0].getBackground().a);
}

test "GlassBox: compact layouts automatically soften lensing" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 420 },
        .direction = .row,
        .gap = 24,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const compact = try GlassBox(.{
        .width = 140,
        .height = 52,
    }).mount(scope, ctx);
    const spacious = try GlassBox(.{
        .width = 360,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, compact);
    try root.appendChild(std.testing.allocator, spacious);

    ctx.layout();
    runBeforeRenderHooks(compact);
    runBeforeRenderHooks(spacious);

    const compact_gp = compact.children.items[0].style.glass_params().?;
    const spacious_gp = spacious.children.items[0].style.glass_params().?;

    try std.testing.expect(compact_gp.refraction_level < spacious_gp.refraction_level);
    try std.testing.expect(compact_gp.warp_gain < spacious_gp.warp_gain);
    try std.testing.expect(compact_gp.blur_level >= spacious_gp.blur_level);
}

test "GlassBox: interactive hover/press 提升玻璃参数且不引入 scale" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const g = try GlassBox(.{ .width = 240, .height = 120, .interactive = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, g);
    ctx.layout();
    runBeforeRenderHooks(g);

    const resting = g.children.items[0].style.glass_params().?;
    const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(g.meta.per_frame.hooks.slots.anim_state.?));

    // press -> boost 插值收敛后参数提升
    _ = interactiveGlassEventHandler(.{ .mouse_enter = {} }, @ptrCast(state));
    _ = interactiveGlassEventHandler(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, @ptrCast(state));
    var i: usize = 0;
    while (i < 60) : (i += 1) runBeforeRenderHooks(g);

    const pressed = g.children.items[0].style.glass_params().?;
    try std.testing.expect(pressed.specular_opacity > resting.specular_opacity);
    try std.testing.expect(pressed.glass_intensity > resting.glass_intensity);
    // 守护断言：interactive 绝不能写非 1 scale，会把 glass 推上 offscreen
    // 合成路径，hover 时整块内容消失（storybook 实测）。
    try std.testing.expectEqual(@as(f32, 1.0), g.style.scale_x());

    // 释放 + 移出 -> 回落
    _ = interactiveGlassEventHandler(.{ .mouse_up = .{ .x = 0, .y = 0, .button = .left } }, @ptrCast(state));
    _ = interactiveGlassEventHandler(.{ .mouse_leave = {} }, @ptrCast(state));
    i = 0;
    while (i < 120) : (i += 1) runBeforeRenderHooks(g);
    const settled = g.children.items[0].style.glass_params().?;
    try std.testing.expect(@abs(settled.glass_intensity - resting.glass_intensity) < 0.02);
    try std.testing.expectEqual(@as(f32, 1.0), g.style.scale_x());
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "GlassBox: scroll-edge 渐变 stops 不低于玻璃基底糊度" {
    // 回归：stops 曾是 1 -> 0，滚动后玻璃条 fade 带以外整段变 sharp。
    for ([_]f32{ 0.25, 0.68, 0.83, 1.0 }) |bl| {
        const stops = scrollEdgeStops(28, 44, bl);
        try std.testing.expectEqual(@as(f32, 0), stops[0].pos);
        try std.testing.expectApproxEqAbs(@as(f32, 28.0 / 44.0), stops[1].pos, 1e-5);
        try std.testing.expectEqual(@as(f32, 1), stops[0].strength);
        for (stops) |st| try std.testing.expect(st.strength >= bl - 1e-6);
    }
    // fade_width 超出节点：stop 位置钳在 [0,1]
    try std.testing.expectEqual(@as(f32, 1), scrollEdgeStops(80, 44, 0.8)[1].pos);
}

test "glass_box: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("glass_box", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try GlassBox(.{ .title = "Glass", .subtitle = "sub", .interactive = true }).mount(scope, cx);
        }
    }.m);
}
