/// ScrollArea Component
///
/// 可滚动容器组件，Apple 级滚动物理体验
///
/// 特性:
/// - overflow_hidden 裁剪 + translate_y/x 滚动偏移
/// - scroll 事件响应式滚动（系统惯性滚动自动支持）
/// - 滚动条指示器：自动淡入淡出 + hover 变亮变宽
/// - Apple UIScrollView 级 Rubber Banding:
///   - 阻尼阶段: 有理函数 f(x) = x*d*c/(d+c*x)（c=0.55，Apple 标准）
///   - 回弹阶段: WebKit 指数衰减 x(t)=(x0+v0*t*0.31)*exp(-12.5*t)
///   - 惯性越界直接走 rubber band + 指数衰减自然回零
/// - 支持内容尺寸自适应
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const ComputedRect = core.ComputedRect;
const theme = core.theme;
const Padding = core.Padding;
const HitProxySpec = core.HitProxySpec;
const physics = @import("../../physics.zig");
const Scope = @import("../../reactive.zig").Scope;

// 子模块
pub const debug = @import("debug.zig");
const state_mod = @import("state.zig");
const scroll_event = @import("event.zig");
const scroll_scrollbar = @import("scrollbar.zig");
pub const scroll_physics = @import("physics.zig");

// Re-exports，保持外部 API 不变
pub const ScrollDirection = state_mod.ScrollDirection;
pub const ScrollbarVisual = state_mod.ScrollbarVisual;
pub const ScrollbarAxisMetrics = state_mod.ScrollbarAxisMetrics;
pub const ScrollState = state_mod.ScrollState;
pub const ScrollTuning = state_mod.ScrollTuningT;

pub const scrollEventHandler = scroll_event.scrollEventHandler;
pub const isOutwardAtBoundary = scroll_event.isOutwardAtBoundary;

pub const scrollbarBeforeRender = scroll_scrollbar.scrollbarBeforeRender;
pub const scrollbarEventHandler = scroll_scrollbar.scrollbarEventHandler;
pub const scrollbarHEventHandler = scroll_scrollbar.scrollbarHEventHandler;
pub const computeVerticalScrollbarMetrics = scroll_scrollbar.computeVerticalScrollbarMetrics;
pub const computeHorizontalScrollbarMetrics = scroll_scrollbar.computeHorizontalScrollbarMetrics;

pub const applyVerticalScroll = scroll_physics.applyVerticalScroll;
pub const applyHorizontalScroll = scroll_physics.applyHorizontalScroll;

/// ScrollArea 属性
pub const ScrollAreaProps = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    direction: ScrollDirection = .vertical,
    content_height: ?f32 = null,
    content_width: ?f32 = null,
    /// 滚动速度乘数（macOS scrollingDelta 已是像素值，默认 1.0）
    scroll_speed: f32 = 1,
    padding: Padding = Padding.ZERO,
    background: Color = Color.TRANSPARENT,
    /// 自定义状态 ID（用于跨实例复用或区分滚动状态）
    state_id: ?u64 = null,
    /// 垂直方向是否启用 rubber band（果冻回弹）效果
    rubber_band_y: bool = true,
    /// 水平方向是否启用 rubber band（果冻回弹）效果
    rubber_band_x: bool = true,
};

/// mountScrollArea 返回值
pub const ScrollAreaResult = struct {
    container: *Node,
    content: *Node,
    state: *ScrollState,
};

/// 挂载 ScrollArea：v0.5 推荐入口（取代 `ScrollArea(props).mount(...)` Builder 链）。
///
/// Scope 管理 ScrollState + ScrollEventCtx 生命周期。
pub fn mountScrollArea(props: ScrollAreaProps, scope: *Scope, cx: *Cx) !ScrollAreaResult {
    {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const p = props;

        // 外层容器: 固定尺寸 + overflow_hidden
        // ScrollArea 容器默认 grow（撑满父容器），传了尺寸则用 px
        var container_style = BoxStyle{
            .direction = .column,
            .overflow_hidden = true,
            .background = p.background,
            .padding = p.padding,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        };
        if (p.width) |w| container_style.width = .{ .px = w };
        if (p.height) |h| container_style.height = .{ .px = h };

        const container = try box(cx, container_style, .{});
        errdefer cx.freeNode(container);
        container.tag = .scroll;
        container.meta.ownership.meta.component_name = "ScrollArea";
        container.frame_state.state_bits.flags.disable_render_cache = true;
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;

        // 内层内容容器
        const content = blk: {
            const content = try box(cx, .{
                .direction = .column,
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
            }, .{});
            errdefer cx.freeNode(content);
            // 标 will_change_transform -> compositor_plan 自动 promote scroll content。
            // 矩阵 #3：scroll = 改 promoted layer transform，不重录 paint chunks。
            (try content.style.ensureExtFallible(allocator)).will_change_transform = true;
            try container.appendChild(allocator, content);

            break :blk content;
        };

        // 垂直滚动条节点: absolute 定位，挂 event handler 使 hitTest 可命中
        const scrollbar_v = blk: {
            const scrollbar_v = try box(cx, .{
                .width = .{ .px = ScrollbarVisual.idle_thickness },
                .height = .{ .px = 30 },
                .position = .absolute,
                .background = Color.TRANSPARENT,
                .border = .{ .radius = ScrollbarVisual.idle_thickness / 2 },
            }, .{});
            errdefer cx.freeNode(scrollbar_v);
            scrollbar_v.frame_state.state_bits.flags.inspectable = false;
            const scrollbar_ext = try scrollbar_v.style.ensureExtFallible(allocator);
            scrollbar_ext.hit_shape = .{ .rounded_rect = ScrollbarVisual.idle_thickness / 2 };
            scrollbar_ext.clip_shape = .{ .rounded_rect = ScrollbarVisual.idle_thickness / 2 };
            scrollbar_v.setHitProxyProvider(scrollbarHitProxyProvider, null);
            try container.appendChild(allocator, scrollbar_v);

            break :blk scrollbar_v;
        };

        // 水平滚动条节点: absolute 定位
        const scrollbar_h = blk: {
            const scrollbar_h = try box(cx, .{
                .width = .{ .px = 30 },
                .height = .{ .px = ScrollbarVisual.idle_thickness },
                .position = .absolute,
                .background = Color.TRANSPARENT,
                .border = .{ .radius = ScrollbarVisual.idle_thickness / 2 },
            }, .{});
            errdefer cx.freeNode(scrollbar_h);
            scrollbar_h.frame_state.state_bits.flags.inspectable = false;
            const scrollbar_h_ext = try scrollbar_h.style.ensureExtFallible(allocator);
            scrollbar_h_ext.hit_shape = .{ .rounded_rect = ScrollbarVisual.idle_thickness / 2 };
            scrollbar_h_ext.clip_shape = .{ .rounded_rect = ScrollbarVisual.idle_thickness / 2 };
            scrollbar_h.setHitProxyProvider(scrollbarHitProxyProvider, null);
            try container.appendChild(allocator, scrollbar_h);

            break :blk scrollbar_h;
        };

        // Scope 分配 ScrollState（保留模式下节点不重建，状态随 scope 生存）
        const state = blk: {
            const state = try my_scope.allocator.create(ScrollState);
            errdefer my_scope.allocator.destroy(state);
            state.* = ScrollState{};
            try my_scope.registerResource(@ptrCast(state), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const s: *ScrollState = @ptrCast(@alignCast(ptr));
                    alloc.destroy(s);
                }
            }.destroy);
            break :blk state;
        };
        container.addDebugState(@ptrCast(state));

        if (p.content_height) |ch| state.content_height = ch;
        if (p.content_width) |cw| state.content_width = cw;
        state.rubber_band_y_enabled = p.rubber_band_y;
        state.rubber_band_x_enabled = p.rubber_band_x;
        if (p.height) |h| {
            if (state.viewport_height == 0) state.viewport_height = h - p.padding.vertical();
        }
        if (p.width) |w| {
            if (state.viewport_width == 0) state.viewport_width = w - p.padding.horizontal();
        }

        // 节点 on_cleanup 的中转格：必须能比 my_scope 活得久（见 ScrollCtxCell），
        // 所以挂到 Cx 上兜底回收，而不是 my_scope。
        // 登记成功后所有权即归 Cx（deinit 统一释放），因此 errdefer 只能覆盖
        // "分配了但还没登记上"这一小段，用 block 把它限制在这几行内。
        const cell = blk: {
            const c = try allocator.create(ScrollCtxCell);
            errdefer allocator.destroy(c);
            c.* = .{};
            try cx.registerScrollCtxCell(.{
                .ptr = @ptrCast(c),
                .destroyFn = struct {
                    fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const cc: *ScrollCtxCell = @ptrCast(@alignCast(ptr));
                        alloc.destroy(cc);
                    }
                }.destroy,
            });
            break :blk c;
        };

        // Scope 分配 ScrollEventCtx
        const event_ctx = blk: {
            const event_ctx = try my_scope.allocator.create(ScrollEventCtx);
            errdefer my_scope.allocator.destroy(event_ctx);
            event_ctx.* = ScrollEventCtx{
                .state = state,
                .cell = cell,
                .content = content,
                .container = container,
                .scrollbar = scrollbar_v,
                .scrollbar_h = scrollbar_h,
                .cx = cx,
                .scroll_speed = p.scroll_speed,
                .direction = p.direction,
                .scrollbar_thumb = cx.tokens.color.scrollbar_thumb,
            };
            try my_scope.registerResource(@ptrCast(event_ctx), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const s: *ScrollEventCtx = @ptrCast(@alignCast(ptr));
                    // ctx 就此消失：切断中转格回指。之后仍存活（且解绑够不着）的
                    // 节点回调只会看到 cell.ctx == null，安全空转。
                    if (s.cell) |c| c.ctx = null;
                    alloc.destroy(s);
                }
            }.destroy);

            break :blk event_ctx;
        };
        cell.ctx = event_ctx;
        // 节点可能在 scope.dispose() 后继续存活一个复用周期（如 VirtualList slot 复绑）。
        // 先解绑基于 event_ctx 的 hook / handler，再释放 ScrollEventCtx，避免悬垂指针。
        try my_scope.onCleanup(ScrollEventCtx, event_ctx, detachScrollAreaBindings);
        container.behavior.events.on_event = scrollEventHandler;
        container.behavior.events.event_context = event_ctx;
        container.behavior.events.scroll_direction_hint = switch (p.direction) {
            .vertical => .vertical,
            .horizontal => .horizontal,
            .both => .both,
        };
        container.meta.per_frame.hooks.before_render.main = scrollbarBeforeRender;

        // scrollbar 自己挂 handler，使 hitTest 可命中 + 处理拖拽交互
        scrollbar_v.behavior.events.on_event = scrollbarEventHandler;
        scrollbar_v.behavior.events.event_context = event_ctx;

        // 水平 scrollbar 挂 handler
        scrollbar_h.behavior.events.on_event = scrollbarHEventHandler;
        scrollbar_h.behavior.events.event_context = event_ctx;

        // 反向：节点先于 scope 释放（如祖先 freeNode 把容器子节点逐个释放、但
        // ScrollArea scope 是更外层 scope 的子树，要等更外层 dispose 才执行 cleanup）
        // -> 节点 freeNode 时立即把 event_ctx 上对应字段置 null，
        //   后续 detachScrollAreaBindings 看到 null 直接跳过，避免 use-after-free。
        // context 是 **cell 而非 event_ctx**：节点可能比 ctx 活得久、且解绑够不着
        // （见 ScrollCtxCell）。写 cell 恒定安全，ctx 没了就是空转。
        container.meta.ownership.hooks.on_cleanup = .{ .callback = clearContainerOnNodeFree, .context = @ptrCast(cell) };
        scrollbar_v.meta.ownership.hooks.on_cleanup = .{ .callback = clearScrollbarOnNodeFree, .context = @ptrCast(cell) };
        scrollbar_h.meta.ownership.hooks.on_cleanup = .{ .callback = clearScrollbarHOnNodeFree, .context = @ptrCast(cell) };
        content.meta.ownership.hooks.on_cleanup = .{ .callback = clearContentOnNodeFree, .context = @ptrCast(cell) };

        // 应用初始滚动位置
        content.style.translate_y = state.contentTranslateY();
        content.style.translate_x = state.contentTranslateX();

        // 注册 ScrollArea container 到 PropertyTree.scrolls + InteractionTable。
        // 真 scroll_id 写到 InteractionTable 让 layerize 的 PromotionHint 识别。
        // ScrollArea state 也持 scroll_id 让滚动期间 updateScrollOffset 用。
        if (container.element_id_raw != 0xFFFFFFFF) {
            const cx_core = @import("../../core.zig");
            const property_tree_mod = @import("../../core/property_tree.zig");
            const eid = cx_core.world.ElementId.fromRaw(container.element_id_raw);

            const w_size: f32 = if (p.width) |w| w else 0;
            const h_size: f32 = if (p.height) |h| h else 0;
            const scroll_id = cx.property_tree.appendScroll(.{
                .parent = property_tree_mod.INVALID_ID,
                .transform_id = property_tree_mod.INVALID_ID,
                .node_id = container.id,
                .content_size = .{ .width = w_size, .height = h_size },
                .viewport_size = .{ .width = w_size, .height = h_size },
            }) catch property_tree_mod.INVALID_ID;

            // 注册失败 = scroll_id 已分配但 layerize 的 PromotionHint 永远看不到它，
            // 表现为滚动静默失效（无任何报错）。这里能传播，就别吞。
            try cx.world.interaction.put(eid, .{
                .scroll_id = scroll_id,
            });

            state.world_scroll_id = scroll_id;
            state.world_ref = @ptrCast(&cx.world);
        }

        return .{ .container = container, .content = content, .state = state };
    }
}

// ============================================================================
// 程序化滚动，公共 API
//
// 在这之前，应用要把某个元素滚进视野只能直接写 `state.scroll_y`。那样会
// 跳过三件必须做的事：clamp、动量/回弹状态重置、translate 的像素对齐,
// 结果就是残留惯性把内容又滚走、以及文字半像素抖动（harness 的
// scroll-into-view 坑就是这么踩出来的）。这里给出唯一正确的入口。
// ============================================================================

/// 对齐方式
pub const ScrollAlign = enum {
    /// 已经完整可见就不滚（最小移动量把元素带进视野）
    nearest,
    /// 元素顶部对齐视口顶部
    start,
    /// 元素底部对齐视口底部
    end,
    /// 元素在视口中居中
    center,
};

/// 程序化设置垂直滚动位置。**这是写 scroll_y 的唯一正确方式。**
///
/// 会做：clamp 到 [0, maxScrollY]、清零 rubber-band bonus 与弹簧速度、
/// 取消进行中的回弹动画、按 pixel_scale 对齐 translate_y。
pub fn setScrollY(state: *ScrollState, content: *Node, y: f32) void {
    const clamped = std.math.clamp(y, 0, state.maxScrollY());
    state.scroll_y = clamped;
    // 动量/回弹一并复位：否则残留惯性会在随后几帧把内容又推走
    state.bonus_y = 0;
    state.bonus_velocity = 0;
    state.bounce_active_y = false;
    state.momentum_spent_y = false;
    // 与 scrollbarBeforeRender 同款的像素对齐（消除文字抖动）
    content.style.translate_y = state.contentTranslateY();
    content.markCompositePropDirty();
}

/// 把 [top, top+height) 这段内容纵向滚进视野。
///
/// `top` 是**内容坐标系**下的偏移（即元素相对 content 顶部的距离，
/// 不含当前 scroll_y）。
pub fn scrollRectIntoView(
    state: *ScrollState,
    content: *Node,
    top: f32,
    height: f32,
    alignment: ScrollAlign,
) void {
    const vh = state.viewport_height;
    const bottom = top + height;
    const cur = state.scroll_y;

    const target: f32 = switch (alignment) {
        .start => top,
        .end => bottom - vh,
        .center => top + (height - vh) / 2,
        .nearest => blk: {
            if (top < cur) break :blk top; // 在视口上方 → 顶部对齐
            if (bottom > cur + vh) break :blk bottom - vh; // 在下方 → 底部对齐
            break :blk cur; // 已完整可见 → 不动
        },
    };
    setScrollY(state, content, target);
}

/// 把一个**已经完成布局**的节点滚进视野。
///
/// 用 node 与 content 的已算 rect 之差得到内容坐标，因此必须在布局跑过
/// 之后调用（rect 全 0 时是 no-op，不会把视口滚到奇怪的位置）。
pub fn scrollIntoView(
    state: *ScrollState,
    content: *Node,
    node: *Node,
    alignment: ScrollAlign,
) void {
    const nr = node.rectFromWorldOrFallback();
    if (nr.h <= 0) return; // 尚未布局：不要拿全 0 的 rect 把视口滚到奇怪的位置

    // 沿 parent 链把 layout-local 的 y 累加到 content 为止，得到的就是
    // 内容坐标系下的偏移（不含 content 自身的 translate/scroll，正是所需）。
    var top: f32 = 0;
    var cur: ?*Node = node;
    var found = false;
    while (cur) |n| {
        if (n == content) {
            found = true;
            break;
        }
        top += n.rectFromWorldOrFallback().y;
        cur = n.parent;
    }
    if (!found) return; // node 不在这个 ScrollArea 里

    scrollRectIntoView(state, content, top, nr.h, alignment);
}

pub const ScrollEventCtx = state_mod.ScrollEventCtx;
pub const ScrollCtxCell = state_mod.ScrollCtxCell;

fn clearContainerOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.container = null;
}

fn clearScrollbarOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.scrollbar = null;
}

fn clearScrollbarHOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.scrollbar_h = null;
}

fn clearContentOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.content = null;
}

fn detachScrollAreaBindings(event_ctx: *ScrollEventCtx) void {
    const raw_ctx: *anyopaque = @ptrCast(event_ctx);
    // on_cleanup 的 context 是 cell（见 mountScrollArea），这里按 cell 比对。
    const raw_cell: ?*anyopaque = if (event_ctx.cell) |c| @ptrCast(c) else null;

    // 注意：必须在 event_ctx 被 scope 释放**之前**把每个 node 上的 on_cleanup
    // 也清空。否则节点的 freeNode 会 invoke 一个指向已释放 ScrollEventCtx 的
    // 回调（clearContainerOnNodeFree / clearContentOnNodeFree 等），UAF。
    // 这条 cleanup 路径在 Textarea / VirtualList 内嵌 ScrollArea 时尤其重要：
    // 外层 cx.deinit 时节点存活到 freeNode，但 my_scope 已经 dispose。

    if (event_ctx.container) |container| {
        if (container.behavior.events.event_context == raw_ctx) {
            if (container.behavior.events.on_event == scrollEventHandler) {
                container.behavior.events.on_event = null;
            }
            if (container.meta.per_frame.hooks.before_render.main == scrollbarBeforeRender) {
                container.meta.per_frame.hooks.before_render.main = null;
            }
            container.behavior.events.event_context = null;
            container.behavior.events.scroll_direction_hint = null;
        }
        if (container.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearContainerOnNodeFree) {
                container.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.container = null;
    }

    if (event_ctx.scrollbar) |scrollbar| {
        if (scrollbar.behavior.events.event_context == raw_ctx) {
            if (scrollbar.behavior.events.on_event == scrollbarEventHandler) {
                scrollbar.behavior.events.on_event = null;
            }
            scrollbar.behavior.events.event_context = null;
        }
        if (scrollbar.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearScrollbarOnNodeFree) {
                scrollbar.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.scrollbar = null;
    }

    if (event_ctx.scrollbar_h) |scrollbar_h| {
        if (scrollbar_h.behavior.events.event_context == raw_ctx) {
            if (scrollbar_h.behavior.events.on_event == scrollbarHEventHandler) {
                scrollbar_h.behavior.events.on_event = null;
            }
            scrollbar_h.behavior.events.event_context = null;
        }
        if (scrollbar_h.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearScrollbarHOnNodeFree) {
                scrollbar_h.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.scrollbar_h = null;
    }

    if (event_ctx.content) |content| {
        if (content.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearContentOnNodeFree) {
                content.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.content = null;
    }
}

fn scrollbarHitProxyProvider(node: *const Node, _: ?*anyopaque, out: []HitProxySpec) usize {
    // NOTE: ScrollArea nested-chain tests 依赖 node.rect 直读（World rect 与 scrollbar rect 写入时序差）。
    // session 31 试切到 World hook 失败已 revert。
    if (out.len < 2 or node.rectFromWorldOrFallback().w <= 0 or node.rectFromWorldOrFallback().h <= 0) return 0;
    const slop = ScrollbarVisual.hover_slop;
    out[0] = .{
        .local_rect = ComputedRect.init(-slop, -slop, node.rectFromWorldOrFallback().w + slop * 2, node.rectFromWorldOrFallback().h + slop * 2),
        .shape = .{ .rounded_rect = node.style.border.radius },
        .behavior = .self_only,
    };
    out[1] = .{
        .local_rect = ComputedRect.init(0, 0, node.rectFromWorldOrFallback().w, node.rectFromWorldOrFallback().h),
        .shape = .{ .rounded_rect = node.style.border.radius },
        .behavior = .self_only,
    };
    return 2;
}

// ========== 测试 ==========

test "ScrollArea: basic vertical" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try mountScrollArea(.{
        .width = 300,
        .height = 200,
    }, scope, ctx);

    try root.appendChild(std.testing.allocator, result.container);

    for (0..10) |_| {
        const item = try box(ctx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 40 },
            .background = theme.dark.color.bg_tertiary,
        }, .{});
        try result.content.appendChild(std.testing.allocator, item);
    }

    // content + scrollbar (vertical) + scrollbar (horizontal)
    try std.testing.expectEqual(@as(usize, 3), result.container.children.items.len);
    try std.testing.expectEqual(@as(usize, 10), result.content.children.items.len);
    try std.testing.expect(result.container.style.overflow_hidden);
}

test "ScrollArea: scroll state" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try mountScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }, scope, ctx);

    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    try std.testing.expectEqual(@as(f32, 0), result.content.style.translate_y);

    const event = core.Event{ .scroll = .{ .x = 150, .y = 100, .dx = 0, .dy = -1 } };
    const handler_result = scrollEventHandler(event, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.stop, handler_result);
    try std.testing.expect(result.content.style.translate_y < 0);
}

/// 单个 300x200 的纵向 ScrollArea（内容 600），返回挂好的 result。
fn mountTestScrollArea(ctx: *Cx, scope: *Scope) !ScrollAreaResult {
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const result = try mountScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();
    return result;
}

fn testState(result: ScrollAreaResult) *ScrollState {
    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    return event_ctx.state;
}

fn sendScroll(result: ScrollAreaResult, ev: @import("../../events.zig").ScrollEvent) core.EventResult {
    return scrollEventHandler(.{ .scroll = ev }, result.container.behavior.events.event_context);
}

fn settleSpring(state: *ScrollState) void {
    var ms: f64 = 1000.0;
    state.tickBonus(ms);
    while ((state.bounce_active_y or state.bounce_active_x) and ms < 4000.0) {
        ms += 16.667;
        state.tickBonus(ms);
        state.tickBonusX(ms);
    }
}

test "ScrollArea: lifting while overscrolled hands outward momentum to the spring" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    // 手指把内容拉过底部
    state.scroll_y = state.maxScrollY();
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -30, .phase = .changed });
    try std.testing.expect(state.touching);
    try std.testing.expect(state.bonus_y > 0);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!state.touching);

    // 松手后朝外的惯性不再推内容，越界量归弹簧
    const bonus_at_lift = state.bonus_y;
    try std.testing.expectEqual(core.EventResult.stop, sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -80, .momentum = .began }));
    try std.testing.expectEqual(bonus_at_lift, state.bonus_y);
    try std.testing.expectEqual(state.maxScrollY(), state.scroll_y);

    // 回弹结束后，同一段惯性的朝外尾巴也不会再次越界
    settleSpring(state);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -80, .momentum = .changed });
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);

    // 朝内的惯性照常滚动
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .momentum = .changed });
    try std.testing.expect(state.scroll_y < state.maxScrollY());
}

test "ScrollArea: momentum that reaches the edge bounces once per stream" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.scroll_y = 5;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 40, .momentum = .began });
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expect(state.bonus_y < 0);
    try std.testing.expect(state.momentum_spent_y);

    settleSpring(state);
    for (0..5) |_| {
        _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 30, .momentum = .changed });
        try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    }

    // 下一个手势可以再次拉出越界
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    try std.testing.expect(!state.momentum_spent_y);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .phase = .changed });
    try std.testing.expect(state.bonus_y < 0);
}

test "ScrollArea: momentum means the finger is up, so the spring can run" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .phase = .changed });
    try std.testing.expect(state.touching);
    // ended 丢失，直接来了惯性
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 5, .momentum = .began });
    try std.testing.expect(!state.touching);
    try std.testing.expect(state.momentum_active);
}

test "ScrollArea: inputActive follows begin/end signals without timers" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);
    state.scroll_y = 200;

    try std.testing.expect(!state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .momentum = .began });
    try std.testing.expect(state.inputActive());
    // 任意多帧过去都不会自己变回 idle，只看信号
    for (0..100) |_| scrollbarBeforeRender(result.container);
    try std.testing.expect(state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .momentum = .ended });
    try std.testing.expect(!state.inputActive());

    // 新手势打断惯性
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .momentum = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .may_begin });
    try std.testing.expect(!state.momentum_active);
}

test "ScrollArea: input_serial counts applied input only" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);
    state.scroll_y = 200;

    const s0 = state.input_serial;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10 });
    try std.testing.expectEqual(s0 + 1, state.input_serial);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expectEqual(s0 + 2, state.input_serial);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expectEqual(s0 + 2, state.input_serial);
}

test "ScrollArea: mouse wheel stops at the edge without rubber band" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.scroll_y = 3;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 40 });
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.touching);
    try std.testing.expect(!state.inputActive());
}

test "ScrollArea: finger down catches a running bounce" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.bonus_y = -20;
    state.tickBonus(1000.0);
    state.tickBonus(1032.0);
    try std.testing.expect(state.bounce_active_y);
    const held = state.bonus_y;

    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .may_begin });
    try std.testing.expect(state.touching);
    try std.testing.expect(!state.bounce_active_y);
    try std.testing.expectEqual(held, state.bonus_y);
    // 按住期间弹簧不跑
    state.tickBonus(1100.0);
    try std.testing.expectEqual(held, state.bonus_y);
    // 抬起后弹簧接手
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .cancelled });
    settleSpring(state);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollArea: nested chain delegates outward boundary scroll to ancestor" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try mountScrollArea(.{
        .width = 320,
        .height = 220,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try mountScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }, scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();

    const outer_ctx: *ScrollEventCtx = @ptrCast(@alignCast(outer.container.behavior.events.event_context.?));
    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    outer_ctx.state.scroll_y = 0;
    outer_ctx.state.bonus_y = 0;
    inner_ctx.state.scroll_y = 0;
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = 8, .phase = .changed });

    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
    try std.testing.expect(outer_ctx.state.bonus_y < 0);
}

test "ScrollArea: nested chain delegates on boundary crossing frame" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try mountScrollArea(.{
        .width = 320,
        .height = 220,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try mountScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }, scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();
    _ = ctx.render(); // 确保 hitTest scene 更新

    const outer_ctx: *ScrollEventCtx = @ptrCast(@alignCast(outer.container.behavior.events.event_context.?));
    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    outer_ctx.state.scroll_y = 0;
    outer_ctx.state.bonus_y = 0;
    inner_ctx.state.scroll_y = 2; // 尚未到边界，但本帧会越界
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = 8, .phase = .changed });

    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
    try std.testing.expect(outer_ctx.state.bonus_y < 0);
}

test "ScrollArea: nested chain snaps inner to boundary before delegating" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try mountScrollArea(.{
        .width = 320,
        .height = 220,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try mountScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }, scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();
    _ = ctx.render(); // 确保 hitTest scene 更新

    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    inner_ctx.state.scroll_y = inner_ctx.state.maxScrollY() - 2;
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = -8, .phase = .changed });

    try std.testing.expectApproxEqAbs(inner_ctx.state.maxScrollY(), inner_ctx.state.scroll_y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
}

test "ScrollArea: an outer layer holding the gesture keeps it over an inner one" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try mountScrollArea(.{ .width = 320, .height = 220 }, scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try mountScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }, scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    inner_state.scroll_y = 60;
    const g = inner.container.globalRect();

    // outer 空闲：指针下的 inner 正常滚动
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });

    // outer 正持有手势（手指在板上、内容在指针下移动）：中途不换手给 inner
    outer_state.touching = true;
    const outer_before = outer_state.scroll_y;
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
    try std.testing.expect(outer_state.scroll_y > outer_before);
}

test "ScrollArea: an outer bounce does not steal a gesture that starts on the inner layer" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try mountScrollArea(.{ .width = 320, .height = 220 }, scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try mountScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }, scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    // 外层正在回弹
    outer_state.bonus_y = -12;
    outer_state.tickBonus(1000.0);
    try std.testing.expect(outer_state.bounce_active_y);
    inner_state.scroll_y = 60;

    const g = inner.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    try std.testing.expect(!outer_state.touching);
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
}

test "ScrollArea: ended reaches every layer of a delegated nested gesture" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try mountScrollArea(.{ .width = 320, .height = 220 }, scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try mountScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }, scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    // 手势已委托给 outer；inner 自己还留着上次的越界量
    outer_state.touching = true;
    inner_state.bonus_y = 5;

    const g = inner.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!outer_state.touching);
    try std.testing.expect(!inner_state.touching);
}

test "ScrollArea: a gesture whose ended was lost is cancelled when the next one begins" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 700 }, .height = .{ .px = 300 }, .direction = .row }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const a = try mountScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }, scope, ctx);
    try root.appendChild(std.testing.allocator, a.container);
    const b = try mountScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }, scope, ctx);
    try root.appendChild(std.testing.allocator, b.container);
    ctx.layout();
    _ = ctx.render();

    const a_state = testState(a);
    const b_state = testState(b);
    a_state.scroll_y = 100;
    b_state.scroll_y = 100;
    const ga = a.container.globalRect();
    const gb = b.container.globalRect();

    ctx.handleScroll(.{ .x = ga.x + 20, .y = ga.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = ga.x + 20, .y = ga.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(a_state.touching);

    ctx.handleScroll(.{ .x = gb.x + 20, .y = gb.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = gb.x + 20, .y = gb.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(!a_state.touching);
    try std.testing.expect(b_state.touching);
}

test "ScrollArea: window blur cancels an in-progress gesture" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    _ = ctx.render();
    const state = testState(result);
    state.scroll_y = 200;

    const g = result.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(state.touching);

    ctx.cancelPointerInteractions(.window_blur);
    try std.testing.expect(!state.touching);
    try std.testing.expect(!state.inputActive());
}

test "ScrollArea: window blur ends in-progress momentum" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    _ = ctx.render();
    const state = testState(result);
    state.scroll_y = 200;

    const g = result.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .ended });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .momentum = .began });
    try std.testing.expect(state.momentum_active);

    ctx.cancelPointerInteractions(.window_blur);
    try std.testing.expect(!state.momentum_active);
}

test "ScrollArea: bounce animation blocks outward momentum" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .scroll_y = 0,
        .bonus_y = -20,
    };

    // 启动回弹
    state.tickBonus(1016.0);
    state.tickBonus(1032.0);
    try std.testing.expect(state.bounce_active_y);

    // 动画中途 outward momentum 应被拒绝
    const scroll_event_mod = @import("event.zig");
    const bounce_active = scroll_event_mod.hasBounceActive(&state, .vertical);
    try std.testing.expect(bounce_active);

    // 运行到完成
    var ms: f64 = 1000.0;
    while (state.bounce_active_y and ms < 3000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.bounce_active_y);
}

fn mountBothInsideVertical(ctx: *Cx, scope: *Scope) !struct { outer: ScrollAreaResult, inner: ScrollAreaResult } {
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const outer = try mountScrollArea(.{ .width = 320, .height = 220 }, scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    // 只能横向滚的 both 区域：内容比视口宽、与视口一样高
    const inner = try mountScrollArea(.{ .width = 280, .height = 120, .direction = .both }, scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const strip = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 120 } }, .{});
    try inner.content.appendChild(std.testing.allocator, strip);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();
    // 横向内容宽度由宿主管理（Grid / VirtualList 的用法）
    const inner_state = testState(inner);
    inner_state.external_content_width = true;
    inner_state.content_width = 900;
    return .{ .outer = outer, .inner = inner };
}

test "ScrollArea: both mode hands a diagonal event to the layer of its dominant axis" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    try std.testing.expectEqual(@as(f32, 0), inner_state.maxScrollY());
    const g = areas.inner.container.globalRect();

    // 纵向为主：整个事件交给外层，纵向分量不会丢
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -2, .dy = -8 });
    try std.testing.expectEqual(@as(f32, 8), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_state.scroll_x);

    // 横向为主：本层处理横向，纵向小分量随轴锁丢弃
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -2 });
    try std.testing.expectEqual(@as(f32, 8), inner_state.scroll_x);
    try std.testing.expectEqual(@as(f32, 8), outer_state.scroll_y);
}

test "ScrollArea: both mode keeps a held gesture when the dominant axis changes" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    const g = areas.inner.container.globalRect();

    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -1, .phase = .changed });
    try std.testing.expect(inner_state.touching);
    // 手势中途变成纵向为主：不换手给外层
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -1, .dy = -8, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 0), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 9), inner_state.scroll_x);
}

test "ScrollArea: both mode keeps the momentum of a gesture it held" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    const g = areas.inner.container.globalRect();

    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -1, .phase = .changed });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });
    // 惯性尾段变成纵向为主：仍属于 inner 的这段惯性，不漏给外层
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -1, .dy = -6, .momentum = .changed });
    try std.testing.expectEqual(@as(f32, 0), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 9), inner_state.scroll_x);
}

test "ScrollArea: both mode does not inject bonus on non-scrollable axis" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountScrollArea(.{
        .width = 300,
        .height = 200,
        .direction = .both,
        .content_height = 200,
        .content_width = 500,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    try std.testing.expectEqual(@as(f32, 0), state.maxScrollY());
    try std.testing.expect(state.maxScrollX() > 0);

    const y_only = core.Event{
        .scroll = .{
            .x = 150,
            .y = 100,
            .dx = 0,
            .dy = 24,
            .phase = .changed,
        },
    };
    const routed = scrollEventHandler(y_only, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.ignored, routed);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollArea: both-mode momentum x bounce does not block vertical scrolling" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountScrollArea(.{
        .width = 300,
        .height = 200,
        .direction = .both,
        .content_height = 1200,
        .content_width = 1200,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    state.scroll_x = 0;
    state.scroll_y = 329;
    state.bonus_x = -0.04;
    state.bonus_y = 0;

    const momentum_vertical = core.Event{
        .scroll = .{
            .x = 150,
            .y = 100,
            .dx = 0,
            .dy = -38,
            .momentum = .changed,
        },
    };

    const handled = scrollEventHandler(momentum_vertical, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.stop, handled);
    try std.testing.expectEqual(@as(f32, 367), state.scroll_y);
    try std.testing.expectApproxEqAbs(@as(f32, -0.04), state.bonus_x, 0.001);
}

test "ScrollArea: isOutwardAtBoundary both returns false when no active delta" {
    const state = ScrollState{
        .content_height = 600,
        .viewport_height = 200,
        .content_width = 800,
        .viewport_width = 300,
        .scroll_y = 20,
        .scroll_x = 40,
    };
    try std.testing.expect(!isOutwardAtBoundary(&state, .both, 0, 0, 1.0));
}

test "ScrollState: effectiveScrollY with bonus" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    // 正常范围: effective = scroll_y (bonus=0)
    state.scroll_y = 100;
    try std.testing.expectEqual(@as(f32, 100), state.effectiveScrollY());

    // 有 bonus: effective = scroll_y + bonus
    state.scroll_y = 0;
    state.bonus_y = -90;
    try std.testing.expectEqual(@as(f32, -90), state.effectiveScrollY());

    state.scroll_y = 300;
    state.bonus_y = 60;
    try std.testing.expectEqual(@as(f32, 360), state.effectiveScrollY());
}

test "ScrollState: duration-based bounce decay" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.bonus_y = 100;
    state.tickBonus(1000.0);
    // 第一帧: bonus 应该开始减小
    try std.testing.expect(state.bonus_y <= 100);
    try std.testing.expect(state.bonus_y > 0);
    try std.testing.expect(state.bounce_active_y);

    // 运行到完成
    var ms: f64 = 1000.0;
    while (state.bounce_active_y and ms < 3000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.bounce_active_y);
}

test "ScrollState: bonus bounce blocked while touching" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.bonus_y = 100;
    state.touching = true;
    state.tickBonus(1000.0);
    // 弹簧不启动
    try std.testing.expect(!state.bounce_active_y);
    try std.testing.expectEqual(@as(f32, 100), state.bonus_y);
}

test "ScrollState: larger displacement settles later (critically damped spring)" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var small = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 20,
    };
    var large = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 120,
    };

    small.tickBonus(1000.0);
    large.tickBonus(1000.0);

    var small_done_ms: f64 = 0;
    var large_done_ms: f64 = 0;
    var ms: f64 = 1000.0;
    while ((small.bounce_active_y or large.bounce_active_y) and ms < 3000.0) {
        ms += 16.667;
        small.tickBonus(ms);
        large.tickBonus(ms);
        if (!small.bounce_active_y and small_done_ms == 0) small_done_ms = ms;
        if (!large.bounce_active_y and large_done_ms == 0) large_done_ms = ms;
    }
    // 两者最终都归零，且较大位移收敛更晚
    try std.testing.expectEqual(@as(f32, 0), small.bonus_y);
    try std.testing.expectEqual(@as(f32, 0), large.bonus_y);
    try std.testing.expect(large_done_ms >= small_done_ms);
}

test "ScrollState: spring bounce carries inbound velocity (overshoot then return)" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 30,
        .bonus_velocity = 800, // 入射惯性仍在向外冲
    };
    state.tickBonus(1000.0);
    try std.testing.expect(state.bounce_active_y);

    // 短时间内应先加深（速度连续 -> 无换挡感）
    state.tickBonus(1030.0);
    try std.testing.expect(state.bonus_y > 30);

    var ms: f64 = 1030.0;
    while (state.bounce_active_y and ms < 4000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollState: rubberBand round-trip (via physics.RubberBand)" {
    // clamp -> unclamp 应该恢复原始值 (测试通过 ScrollState.rubber_band 访问)
    const rb = physics.RubberBand{};
    const dim: f32 = 200;
    const inputs = [_]f32{ 5, 20, 50, 100, -10, -80 };
    for (inputs) |input| {
        const clamped = rb.clamp(input, dim);
        const recovered = rb.unclamp(clamped, dim);
        try std.testing.expectApproxEqAbs(input, recovered, 0.1);
    }
}

test "ScrollState: rubberBand asymptotic (via physics.RubberBand)" {
    const rb = physics.RubberBand{};
    const dim: f32 = 200;
    // 小输入: 输出 < 输入 (有衰减) 且接近输入
    const small = rb.clamp(10, dim);
    try std.testing.expect(small > 0);
    try std.testing.expect(small <= 10.0);
    // 大输入渐近于 dim
    const large = rb.clamp(10000, dim);
    try std.testing.expect(large > 0);
    try std.testing.expect(large <= dim);
    // 单调递增
    try std.testing.expect(large > small);
    // 负输入对称
    const neg = rb.clamp(-50, dim);
    try std.testing.expect(neg < 0);
}

test "applyVerticalScroll: boundary bonus with damping" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    // 正常滚动
    applyVerticalScroll(&state, -5, 1, .gesture);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(state.scroll_y > 0);

    // 越过顶部 -> bonus 变负 (有阻尼衰减)
    state.scroll_y = 0;
    state.bonus_y = 0;
    applyVerticalScroll(&state, 10, 1, .gesture); // delta = -10
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expect(state.bonus_y < 0);
    // 阻尼：bonus 的绝对值应该小于 10（衰减后）
    try std.testing.expect(@abs(state.bonus_y) <= 10);

    // 越过底部 -> bonus 变正 (有阻尼衰减)
    state.scroll_y = 300;
    state.bonus_y = 0;
    applyVerticalScroll(&state, -10, 1, .gesture); // delta = +10
    try std.testing.expectEqual(@as(f32, 300), state.scroll_y);
    try std.testing.expect(state.bonus_y > 0);
    try std.testing.expect(state.bonus_y <= 10);

    // 连续越界：阻力累积，每次增量越来越小
    state.scroll_y = 0;
    state.bonus_y = 0;
    applyVerticalScroll(&state, 5, 1, .gesture);
    const first_bonus = @abs(state.bonus_y);
    const prev_bonus = state.bonus_y;
    applyVerticalScroll(&state, 5, 1, .gesture);
    const second_increment = @abs(state.bonus_y - prev_bonus);
    try std.testing.expect(second_increment < first_bonus);
}

test "ScrollState: scrollbar metrics" {
    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
    };

    try std.testing.expect(state.needsScrollbar());
    try std.testing.expectEqual(@as(f32, 40), state.scrollbarHeight());

    state.scroll_y = 0;
    try std.testing.expectEqual(@as(f32, 2), state.scrollbarY());

    state.scroll_y = 800;
    try std.testing.expectEqual(@as(f32, 158), state.scrollbarY());

    state.content_height = 100;
    try std.testing.expect(!state.needsScrollbar());
}

test "ScrollState: overscroll shrinks vertical thumb and pins to edge" {
    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
        .scroll_y = 400,
    };

    const base = computeVerticalScrollbarMetrics(&state);
    try std.testing.expectApproxEqAbs(@as(f32, 40), base.length, 0.01);

    state.scroll_y = 0;
    state.bonus_y = -28;
    const top = computeVerticalScrollbarMetrics(&state);
    try std.testing.expect(top.length < base.length);
    try std.testing.expectApproxEqAbs(@as(f32, 2), top.pos, 0.01);

    state.scroll_y = state.maxScrollY();
    state.bonus_y = 28;
    const bottom = computeVerticalScrollbarMetrics(&state);
    try std.testing.expect(bottom.length < base.length);
    try std.testing.expectApproxEqAbs(@as(f32, 198), bottom.pos + bottom.length, 0.05);
}

test "ScrollArea: scrollbar thumb rect updates in before-render hook" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try mountScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 1000,
        .padding = Padding.all(10),
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    state.scrollbar_fade.opacity = 1.0;

    state.scroll_y = state.maxScrollY() / 2;
    scrollbarBeforeRender(result.container);

    const thumb_node = result.container.children.items[1];
    try std.testing.expectApproxEqAbs(@as(f32, ScrollbarVisual.idle_thickness), thumb_node.rectFromWorldOrFallback().w, 0.01);
    const expected_x = result.container.rectFromWorldOrFallback().x + result.container.rectFromWorldOrFallback().w - thumb_node.rectFromWorldOrFallback().w - ScrollbarVisual.edge_inset;
    try std.testing.expectApproxEqAbs(expected_x, thumb_node.rectFromWorldOrFallback().x, 0.01);
    const first_y = thumb_node.rectFromWorldOrFallback().y;
    try std.testing.expect(first_y > result.container.rectFromWorldOrFallback().y + result.container.style.padding.top);

    state.scroll_y = state.maxScrollY();
    scrollbarBeforeRender(result.container);
    try std.testing.expect(thumb_node.rectFromWorldOrFallback().y > first_y);
}

test "ScrollArea: scope dispose detaches before-render hook and event handlers" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    const result = try mountScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);

    const scrollbar_v = result.container.children.items[1];
    const scrollbar_h = result.container.children.items[2];

    scope.dispose();
    scope_disposed = true;

    try std.testing.expect(result.container.behavior.events.on_event == null);
    try std.testing.expect(result.container.behavior.events.event_context == null);
    try std.testing.expect(result.container.meta.per_frame.hooks.before_render.main == null);
    try std.testing.expect(scrollbar_v.behavior.events.on_event == null);
    try std.testing.expect(scrollbar_v.behavior.events.event_context == null);
    try std.testing.expect(scrollbar_h.behavior.events.on_event == null);
    try std.testing.expect(scrollbar_h.behavior.events.event_context == null);

    scrollbarBeforeRender(result.container);
}

test "ScrollState: scrollbar fade" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.onScrollActivity();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    for (0..90) |_| _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    _ = state.tickScrollbar();
    try std.testing.expect(state.scrollbar_fade.opacity < 0.7);

    for (0..40) |_| _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 0), state.scrollbar_fade.opacity);

    state.onScrollActivity();
    state.scrollbar_hovered = true;
    _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 1.0), state.scrollbar_fade.opacity);
}

test "ScrollState: scrollbar fade tick stays idle while opacity is unchanged" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.onScrollActivity();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    var i: usize = 0;
    while (i < state.scrollbar_fade.fade_delay) : (i += 1) {
        const changed = state.tickScrollbar();
        try std.testing.expect(!changed);
        try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);
    }

    const changed = state.tickScrollbar();
    try std.testing.expect(changed);
    try std.testing.expect(state.scrollbar_fade.opacity < 0.7);
}

// ── 程序化滚动 API ──────────────────────────────────────────

test "setScrollY: clamp + 动量复位 + 像素对齐（裸写 scroll_y 三样全没有）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const content = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    cx.root = content;

    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
        .pixel_scale = 2.0,
    };
    // 制造"残留惯性 + 进行中回弹"的现场
    state.bonus_y = 37;
    state.bonus_velocity = 900;
    state.bounce_active_y = true;
    state.momentum_spent_y = true;

    setScrollY(&state, content, 300.4);

    try testing.expectEqual(@as(f32, 300.4), state.scroll_y);
    // 动量/回弹全部复位，否则接下来几帧惯性会把内容又推走
    try testing.expectEqual(@as(f32, 0), state.bonus_y);
    try testing.expectEqual(@as(f32, 0), state.bonus_velocity);
    try testing.expect(!state.bounce_active_y);
    try testing.expect(!state.momentum_spent_y);
    // translate 对齐到物理像素网格（pixel_scale=2 -> 0.5px 栅格）
    const ty = content.style.translate_y;
    try testing.expectEqual(@as(f32, -300.5), ty);

    // 上下都 clamp
    setScrollY(&state, content, -100);
    try testing.expectEqual(@as(f32, 0), state.scroll_y);
    setScrollY(&state, content, 99999);
    try testing.expectEqual(@as(f32, 800), state.scroll_y); // maxScrollY = 1000-200
}

test "scrollRectIntoView: 四种对齐" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const content = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    cx.root = content;

    var state = ScrollState{ .content_height = 1000, .viewport_height = 200 };

    // start：顶部对齐
    scrollRectIntoView(&state, content, 500, 40, .start);
    try testing.expectEqual(@as(f32, 500), state.scroll_y);
    // end：底部对齐视口底部
    scrollRectIntoView(&state, content, 500, 40, .end);
    try testing.expectEqual(@as(f32, 340), state.scroll_y); // 540 - 200
    // center：居中
    scrollRectIntoView(&state, content, 500, 40, .center);
    try testing.expectEqual(@as(f32, 420), state.scroll_y); // 500 + (40-200)/2

    // nearest：已完整可见 -> 不动
    state.scroll_y = 480;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 480), state.scroll_y);
    // nearest：在视口下方 -> 底部对齐（最小移动）
    state.scroll_y = 200;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 340), state.scroll_y);
    // nearest：在视口上方 -> 顶部对齐
    state.scroll_y = 700;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 500), state.scroll_y);
}

test "scrollIntoView: 按节点 rect 把子节点滚进视野" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const sa = try mountScrollArea(.{ .width = 200, .height = 200 }, scope, cx);
    try root.appendChild(testing.allocator, sa.container);

    sa.state.content_height = 1000;
    sa.state.viewport_height = 200;
    sa.state.external_content_height = true;

    // 造一个位于内容 y=600、高 40 的子节点（含一层中间容器，验证祖先链累加）
    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    const target = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 } }, .{});
    try sa.content.appendChild(testing.allocator, mid);
    try mid.appendChild(testing.allocator, target);
    mid.setLayoutRect(.{ .x = 0, .y = 100, .w = 200, .h = 1000 });
    target.setLayoutRect(.{ .x = 0, .y = 500, .w = 200, .h = 40 });

    // 内容坐标 top = 100 + 500 = 600
    scrollIntoView(sa.state, sa.content, target, .start);
    try testing.expectEqual(@as(f32, 600), sa.state.scroll_y);

    scrollIntoView(sa.state, sa.content, target, .end);
    try testing.expectEqual(@as(f32, 440), sa.state.scroll_y); // 640 - 200

    // 不在本 ScrollArea 内的节点 -> no-op，不会把视口滚飞
    const outsider = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try root.appendChild(testing.allocator, outsider); // 挂在 ScrollArea 之外
    outsider.setLayoutRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    const before = sa.state.scroll_y;
    scrollIntoView(sa.state, sa.content, outsider, .start);
    try testing.expectEqual(before, sa.state.scroll_y);

    // 未布局（h=0）也是 no-op
    const unlaid = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try sa.content.appendChild(testing.allocator, unlaid);
    scrollIntoView(sa.state, sa.content, unlaid, .start);
    try testing.expectEqual(before, sa.state.scroll_y);
}

test "ScrollArea: mountScrollArea 在任意分配点失败时不泄漏" {
    // 由来：消费方（下游编辑器）对 PlainTextEditor.mount 做逐分配点 OOM 注入，
    // 有 98 个泄漏点的 GPA 栈顶全部落在 mountScrollArea 内部（container.appendChild
    // 的 children 扩容、content / scrollbar_v 的 ensureExtFallible），据此一度判定
    // 是依赖侧缺陷。
    //
    // **这两个测试证伪了那个判断**：mountScrollArea 自身在逐分配点注入下 0 泄漏。
    // 栈顶说明的是内存**在哪儿分配**，不是**谁该释放**。真正的缺陷在调用方
    // （LineVirtualList 没给 my_scope 和 sa.container 配 errdefer），修掉后消费方
    // 泄漏点从 98 降到 28。
    //
    // 保留这两个测试作为回归护栏：mountScrollArea 的失败清理契约以后不能退化。
    const t = std.testing;

    // 先量一次成功调用用掉多少个分配点。
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator());
        defer ctx.deinit();
        const scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer scope.dispose();
        const before = counting.alloc_index;
        _ = try mountScrollArea(.{ .width = 300, .height = 200 }, scope, ctx);
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;

    for (0..total_allocs) |failure_index| {
        // 每个注入点一个独立 GPA：用它的 deinit() == .leak 做判定。
        // 用 arena 会把泄漏整体回收，正是那样才看不见这批缺陷。
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
            const result = mountScrollArea(.{ .width = 300, .height = 200 }, scope, ctx);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);

            if (result) |r| {
                // 成功：调用方负责这棵游离子树。
                ctx.freeNode(r.container);
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
            .{ "scroll_area", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[scroll_area] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}

test "ScrollArea: mountScrollArea 在 childScope 下失败时不泄漏" {
    // 上一个测试用的是根 scope 且不把 container 挂进任何父树，结果是干净的。
    // 消费方（下游编辑器 line_virtual_list）的调用形态不同：传进来的是
    // scope.childScope() 派生的 scope，并且 container 随后要挂进 main_lane。
    // 这个测试复制那个形态，用来判定"依赖侧泄漏"到底需不需要消费方上下文。
    const t = std.testing;

    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator());
        defer ctx.deinit();
        const root_scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer root_scope.dispose();
        const child = try root_scope.childScope();
        const before = counting.alloc_index;
        _ = try mountScrollArea(.{ .width = 300, .height = 200 }, child, ctx);
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
            const root_scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const parent = box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{}) catch {
                root_scope.dispose();
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const child = root_scope.childScope() catch {
                ctx.freeNode(parent);
                root_scope.dispose();
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };

            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = mountScrollArea(.{ .width = 300, .height = 200 }, child, ctx);
            const appended = if (result) |r| blk2: {
                parent.appendChild(failing.allocator(), r.container) catch break :blk2 false;
                break :blk2 true;
            } else |_| false;
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);

            if (result) |r| {
                if (!appended) ctx.freeNode(r.container);
            } else |_| {
                induced += 1;
                // ⚠️ 关键：失败路径上**只 dispose scope，不额外 freeNode**。
                // 这正是消费方 LineVirtualList 的形态，mountScrollArea 内部失败时，
                // 调用方拿不到 sa，只能靠 scope 清理。若这里也顺手 freeNode，
                // 就把缺陷掩盖了（本测试第一版就是这样，结果 0 泄漏）。
            }
            // 顺序与消费方 pt_editor.mount 的 errdefer 一致：先 dispose scope 再 freeNode。
            root_scope.dispose();
            ctx.freeNode(parent);
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
            .{ "scroll_area", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[scroll_area/childScope] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}

test "ScrollArea: fit + max 被夹住的列容器里收缩成可滚动，px 兄弟不被推出容器" {
    // 形态同 popover chrome 被 autosize 限高：head(px) + ScrollArea(fit) + footer(px)。
    // 修复前 layoutChildren 不补算 fit 子节点的 intrinsic，溢出量被低估，
    // ScrollArea 仍按内容高度 300 排，footer 被推到 y=320（容器只有 100 高）。
    const t = std.testing;
    var ctx = try Cx.init(t.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const panel = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{ .max = 100 } }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, panel);
    const head = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, head);
    const sa = try mountScrollArea(.{}, scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try panel.appendChild(t.allocator, sa.container);
    for (0..10) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }
    const foot = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, foot);

    ctx.layout();
    const p = panel.globalRect();
    try t.expectApproxEqAbs(@as(f32, 100), p.h, 0.5);
    // 容器被压到 100 - 20 - 20，内容保持 300（没有被连带压扁，所以能滚）
    try t.expectApproxEqAbs(@as(f32, 60), sa.container.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.content.globalRect().h, 0.5);
    // footer 完整落在容器内
    const f = foot.globalRect();
    try t.expectApproxEqAbs(@as(f32, 20), f.h, 0.5);
    try t.expect(f.y + f.h <= p.y + p.h + 0.5);

    // 空间充足：不收缩，照旧按内容撑开
    panel.style.height = .{ .fit = .{ .max = 1000 } };
    panel.markSizingDirty();
    ctx.layout();
    try t.expectApproxEqAbs(@as(f32, 340), panel.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.container.globalRect().h, 0.5);
}

test "ScrollArea: ext.max_height（popover autosize 的写法）夹住的列容器里同样收缩可滚" {
    const t = std.testing;
    var ctx = try Cx.init(t.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const panel = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{} }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, panel);
    (try panel.style.ensureExtFallible(t.allocator)).max_height = 100;
    const sa = try mountScrollArea(.{}, scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try panel.appendChild(t.allocator, sa.container);
    for (0..10) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }
    const foot = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, foot);

    ctx.layout();
    const p = panel.globalRect();
    try t.expectApproxEqAbs(@as(f32, 100), p.h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 80), sa.container.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.content.globalRect().h, 0.5);
    const f = foot.globalRect();
    try t.expect(f.y + f.h <= p.y + p.h + 0.5);
}

test "ScrollArea: px 0 + overflow_hidden 的隐藏容器里，fit 可收缩子节点保持内容尺寸（隐藏惯用法）" {
    // Modal 关着时 barrier = px 0 + overflow_hidden，showNode 同款。隐藏期子节点必须保持
    // 内容尺寸只被裁剪，收缩规则若对 px 父节点生效，会把它压成 0，Quick Open 重开后
    // 面板停在 0 高（native gate panel_infra / save_path_identity 实测）。
    const t = std.testing;
    var ctx = try Cx.init(t.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const hidden = try box(ctx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, hidden);
    const dialog = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{ .max = 600 } }, .direction = .column, .overflow_hidden = true }, .{});
    try hidden.appendChild(t.allocator, dialog);
    const sa = try mountScrollArea(.{}, scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try dialog.appendChild(t.allocator, sa.container);
    for (0..4) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }

    ctx.layout();
    try t.expectApproxEqAbs(@as(f32, 120), dialog.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 120), sa.container.globalRect().h, 0.5);
}
