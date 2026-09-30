/// Popover Component
///
/// 通用浮动面板，Select/Menu/DatePicker 的核心基础设施
/// 基于 OverlayStack 框架
///
/// 特性:
/// - Signal(bool) 控制显示/隐藏
/// - click / hover / manual 三种触发模式
/// - OverlayStack 自动管理 z-index、Escape、outside-click
/// - Anchor 自动定位 + flip + cross-axis shift
/// - 默认 scale_fade 入场/退场动画（可覆盖）
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Signal = core.Signal;
const Scope = @import("../../reactive.zig").Scope;
const animation = @import("../../animation/mod.zig");
const overlay_stack_mod = @import("../../overlay_stack.zig");
const render_engine = @import("../../core/render_engine/mod.zig");
const floating = @import("../../compute_position.zig");
const scroll_area_mod = @import("../scroll_area/mod.zig");

// ── 样式层在 styles.zig ──
const styles = @import("styles.zig");
const HIDDEN_OPACITY: f32 = 0.001;

/// Popover 位置
pub const PopoverPosition = floating.Placement;

// ============================================================================
// Virtual Anchor —— floating-ui 风格的虚拟锚点
//
// 用途：popover/menu 不一定锚到真实 Node，常见场景：
//   - 文本编辑器光标位置（动态像素坐标）
//   - 鼠标右键菜单（点击位置）
//   - 选区上的格式工具栏
//   - 任何动态算出来的 (x, y, w, h) 位置
//
// 用法：
// ```zig
// const my_anchor = popover.VirtualAnchor{
//     .ctx = @ptrCast(my_state),
//     .getRect = struct {
//         fn f(ctx: *anyopaque) popover.AnchorRect {
//             const s: *MyState = @ptrCast(@alignCast(ctx));
//             return .{ .x = s.cursor_x, .y = s.cursor_y, .w = 0, .h = s.line_h };
//         }
//     }.f,
// };
//
// const result = try Popover(.{
//     .anchor = .{ .virtual = my_anchor },
//     .visible = &my_signal,
//     .trigger = .manual,
// }).mount(scope, cx);
// ```
//
// 每帧 popover before-render 都会重新读 anchor → 锚点移动时 popover 自动跟随。
// ============================================================================

/// Anchor rect —— absolute (viewport) coordinates
pub const AnchorRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// 虚拟锚点：caller 提供 ctx + 取 rect 的 callback
pub const VirtualAnchor = struct {
    ctx: *anyopaque,
    /// 返回 absolute viewport 坐标系下的 rect
    getRect: *const fn (ctx: *anyopaque) AnchorRect,
};

/// Popover 锚点：要么真实 Node（用其 globalRect()），要么 VirtualAnchor
pub const Anchor = union(enum) {
    node: *Node,
    virtual: VirtualAnchor,
};

/// Popover 触发方式
pub const PopoverTrigger = enum {
    click,
    hover,
    manual,
};

/// Popover 尺寸策略 ——
///   - hard_clip（默认，向后兼容）：`max_width` / `max_height` 是内容硬上限，超出裁剪。
///   - fit_content：内容按自身尺寸布局；`max_*` 仍作为软上限。无滚动。
///   - fit_or_scroll：内容 ≤ `max_*` 时自然撑开；超出 `max_*` 时把内容包进 ScrollArea
///     做纵向滚动（横向仍硬约束，不做 2D 滚动）。适合 hover popup / completion documentation
///     这种长文本会超界的场景。
///
/// 搭配 `compute_position.autosize` middleware：运行时 popover 查询 viewport 可用空间，
/// 把 committed_max_height 和用户设的 `max_height` 取 min，作为软上限。
pub const SizePolicy = enum {
    hard_clip,
    fit_content,
    fit_or_scroll,
};

/// 与 floating-ui `OffsetOptions` 等价，对外暴露给 caller 用 `.{ .static = N }`
/// 或 `.{ .derive = .{ .ctx = ..., .compute = fn } }`。
pub const PopoverOffset = floating.OffsetValue;
pub const OffsetDeriveState = floating.OffsetDeriveState;

/// Popover 属性
pub const PopoverProps = struct {
    /// 位置
    position: PopoverPosition = .bottom_start,
    /// 触发方式
    trigger: PopoverTrigger = .click,
    /// 与触发元素的 main-axis 间距 —— 支持静态 / derivable（按 placement 动态算）。
    /// 默认静态 4 px。Caller 写：
    ///   `.offset = .{ .static = 8 }`  或
    ///   `.offset = .{ .derive = .{ .ctx = ..., .compute = computeFn } }`
    offset: PopoverOffset = .{ .static = 4 },
    /// 外部控制显隐 Signal
    visible: ?*Signal(bool) = null,
    /// 点击外部关闭
    close_on_outside_click: bool = true,
    /// 点击外部关闭时吞掉这一下（不同时触发点中的东西）。需 close_on_outside_click。
    consume_outside_click: bool = false,
    /// Escape 关闭
    close_on_escape: bool = true,
    /// 内容宽度
    width: ?f32 = null,
    /// 内容最大宽度（auto-fit 时常用，超出后由内部内容自行 wrap）
    max_width: ?f32 = null,
    /// 打开时令浮层宽度跟随 trigger 宽度
    match_trigger_width: bool = false,
    /// 允许固定/匹配宽度在视口内收缩
    constrain_width_to_viewport: bool = false,
    /// 内容最大高度
    max_height: ?f32 = null,
    /// 视口约束时的安全边距
    viewport_padding: f32 = 8,
    /// 自动翻转：当首选 placement 溢出时自动选择最佳位置（参考 floating-ui flip）
    flip: bool = true,
    /// 主轴方向也启用 shift 推回 viewport（默认 false 仅 cross-axis 推回）。
    /// 启用时即使 popover 没空间放下，也会被推回 viewport 内（可能 overlap anchor），
    /// 比飞屏外更友好。典型场景：completion docs 在小窗口下放不进 fallback placements 时。
    shift_main_axis: bool = false,
    /// 可选的 fallback placement 列表；非空时按顺序尝试 [position, ...fallback_placements]，
    /// 挑第一个不溢出的。空时走经典 2-way flip（position ↔ opposite）。
    /// 示例（docs aside panel）：`.fallback_placements = &.{.bottom_start, .top_start}`
    /// 配合 `.position = .right_start` → 右侧 → 下方 → 上方，**永不 flip 到左**。
    fallback_placements: []const PopoverPosition = &.{},
    /// 可选：指向 caller 拥有的 mutable slice 的指针，**每帧被 popover 读**来决定 fallback 列表。
    /// 若非 null，覆盖 `fallback_placements` 字段。用于"根据其他 popover 的 active_position
    /// 动态切换自己的 fallback"场景（e.g. docs panel 要贴 main popup 所在的那一侧）。
    fallback_placements_ptr: ?*[]const PopoverPosition = null,
    /// 入场延迟（ms）：打开后先不可见持有这么久再播 enter_transition；
    /// 期间关闭则直接消失。tooltip display delay 用。
    open_delay_ms: f32 = 0,
    /// 入场动画
    enter_transition: overlay_stack_mod.Transition = .scale_fade,
    /// 语义 z-index tier；null = overlay（Tooltip 传 .tooltip）。见 StackTier。
    tier: ?overlay_stack_mod.StackTier = null,
    /// 退场动画
    exit_transition: overlay_stack_mod.Transition = .scale_fade,
    /// 关闭时是否保留可测量隐藏布局，用于首帧预热
    prewarm_hidden_layout: bool = false,
    /// 关闭且退出动画完成后，把浮层内容从 wrapper 子树摘下。
    /// 内容节点本身会保留，重新打开时再挂回；这样未显示内容不出现在 root box tree。
    detach_hidden_content: bool = true,
    /// 无障碍角色（null = 不设 role，由上层组件覆盖）
    a11y_role: ?core.A11yRole = null,
    /// 自定义锚点：null 时锚点 = 内部 trigger_node（默认行为）
    /// 提供 anchor 时定位读 anchor，trigger_node 仍存在但不参与位置计算
    /// （依然是 dismiss outside-click 判定的"trigger"——避免点击 trigger 触发 dismiss）。
    /// trigger=.manual + visible signal 控制下，virtual anchor 是最常用的组合。
    anchor: ?Anchor = null,

    /// 尺寸策略（见 SizePolicy 文档）。默认 .hard_clip 保持向后兼容；
    /// .fit_or_scroll 仍在调试（fit 父里 ScrollArea grow 退化导致内容塌缩）。
    size_policy: SizePolicy = .hard_clip,

    /// visible 时是否保留 chrome.style.overflow_hidden=true（让 chrome 边界裁切子节点 raster）。
    /// 默认 false（旧行为：visible 时无条件关 overflow_hidden）。
    /// 配合 surface owner self-clip 路径（compositor_plan apply_clip op）+ 修复后的嵌套 surface offset 使用。
    /// 适用：caller 子节点带 background 且需要被 chrome 圆角真正裁切（如 completion popup hint_bar）。
    clip_subtree_to_chrome: bool = false,

    /// 避让矩形提供者：popoverBeforeRender 每帧调用，返回的 rect 列表作为 excluded_rects
    /// 喂给 floating-ui 的 flip/shift/autosize middleware，让该 popover 的 placement 选择
    /// 避开这些 rect（视为"墙"）。典型用法：signature popup 需要避让 completion chrome
    /// 和 docs chrome 的当前位置。null 表示不避让任何 rect（单 popover 独立计算）。
    /// buf 由 caller 提供（栈上数组即可），provider 写入后返回 slice。
    avoid_rects_provider: ?*const fn (cx: *Cx, buf: []floating.Rect) []const floating.Rect = null,
};

/// Popover mount 返回的句柄
pub const PopoverResult = struct {
    wrapper: *Node,
    trigger: *Node,
    /// caller 把内容 appendChild 到这里。
    /// - hard_clip / fit_content: == chrome
    /// - fit_or_scroll: == ScrollArea content（chrome 是另一节点，由 popover 自己管 overflow）
    content: *Node,
    /// caller 用来配 popover panel 的 background / border / shadow / panel padding。
    /// 大多数模式下 == content；fit_or_scroll 模式下 = popover 外壳节点。
    chrome: *Node,
    is_open: *Signal(bool),
    /// 指向内部 ctx.active_position 的指针：可供 caller **每帧读取** popover 实际落位。
    /// 用于"根据另一 popover 的 active_position 决定自己的 fallback_placements"场景。
    active_position_ptr: *const PopoverPosition,
    /// 向后兼容字段，现在恒为 false。wrapper 只承载 trigger，永远由
    /// caller 挂到正常文档树；floating content 则独立挂到 window portal。
    portaled: bool,
};

/// 创建 Popover
pub fn Popover(props: PopoverProps) PopoverBuilder {
    return PopoverBuilder{ .props = props };
}

pub const PopoverBuilder = struct {
    props: PopoverProps,

    pub fn position(self: PopoverBuilder, p: PopoverPosition) PopoverBuilder {
        var new = self;
        new.props.position = p;
        return new;
    }

    pub fn trigger(self: PopoverBuilder, t: PopoverTrigger) PopoverBuilder {
        var new = self;
        new.props.trigger = t;
        return new;
    }

    pub fn offset(self: PopoverBuilder, o: f32) PopoverBuilder {
        var new = self;
        new.props.offset = o;
        return new;
    }

    pub fn visible(self: PopoverBuilder, sig: *Signal(bool)) PopoverBuilder {
        var new = self;
        new.props.visible = sig;
        return new;
    }

    pub fn width(self: PopoverBuilder, w: f32) PopoverBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn anchor(self: PopoverBuilder, a: Anchor) PopoverBuilder {
        var new = self;
        new.props.anchor = a;
        return new;
    }

    pub fn maxHeight(self: PopoverBuilder, h: f32) PopoverBuilder {
        var new = self;
        new.props.max_height = h;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: PopoverBuilder, scope: *Scope, cx: *Cx) !PopoverResult {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const resource_allocator = my_scope.allocator;
        const t = cx.tokens;
        const p = self.props;

        // 使用外部 Signal 或创建内部 Signal
        const is_open = p.visible orelse try my_scope.createSignal(bool, false);

        // wrapper: 包含 trigger + popover_content
        const wrapper = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .column,
            // .start 必需：column 默认交叉轴拉伸/居中会把 trigger 推到容器中部，
            // 使 trigger 视觉位置与其 box rect 原点（popover 据此定位）错位。
            .align_items = .start,
        }, .{});
        errdefer cx.freeNode(wrapper);
        wrapper.meta.ownership.meta.component_name = "Popover";
        if (p.a11y_role) |role| {
            wrapper.behavior.interaction.a11y = .{ .role = role };
        }
        try core.bindScopeToNode(my_scope, wrapper);
        scope_bound = true;

        // trigger slot
        const trigger_node = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
        }, .{});
        try appendNewChild(cx, wrapper, trigger_node);

        // popover content (absolute, 初始隐藏)
        // fit 模式必须带 max（如果 caller 给了 max_width / max_height），
        // 否则长内容会让 fit 撑过 caller 期待的上限，整个 popover 跑出 viewport。
        const content_width: core.Sizing = if (p.width) |w| .{ .px = w } else if (p.max_width) |mw| .{ .fit = .{ .max = mw } } else .{ .fit = .{} };
        const content_height: core.Sizing = if (p.max_height) |mh| .{ .fit = .{ .max = mh } } else .{ .fit = .{} };
        const popover_content = try box(cx, .{
            .position = .absolute,
            .width = content_width,
            .height = content_height,
            .background = styles.popoverContentBackground(t),
            .padding = Padding.all(0),
            .direction = .column,
        }, .{});
        var content_registered = false;
        errdefer if (!content_registered) {
            if (popover_content.parent) |parent| cx.detachChild(parent, popover_content);
            cx.freeNode(popover_content);
        };
        popover_content.meta.ownership.meta.component_name = "PopoverContent";
        const layer_handle = try cx.overlay_stack.push(.{
            .kind = .non_modal,
            .dismiss = .{
                .outside_click = if (p.close_on_outside_click and p.trigger != .hover)
                    (if (p.consume_outside_click) .close_and_consume else .close)
                else
                    .none,
                .escape = p.close_on_escape,
            },
            .enter_transition = p.enter_transition,
            .exit_transition = p.exit_transition,
            .enter_delay_ms = p.open_delay_ms,
            .on_dismiss = is_open,
            .trigger_node = trigger_node,
            .tier = p.tier,
        });
        var layer_registered = false;
        errdefer if (!layer_registered) cx.overlay_stack.removePermanently(layer_handle);
        const popover_ext = try popover_content.style.ensureExtFallible(allocator);
        popover_ext.z_index = layer_handle.z_index;
        popover_content.style.border = styles.popoverContentBorder(t);
        popover_ext.transform_origin = transformOriginForPlacement(p.position);
        popover_ext.setShadows(styles.popoverKeyShadow(t), styles.popover_ambient_shadow);
        popover_ext.keep_rendering_when_transparent = true;
        if (p.max_width) |mw| {
            popover_ext.max_width = mw;
        }
        popover_ext.hit_shape = .{ .rounded_rect = styles.popoverRadius(t) };
        popover_ext.clip_shape = .{ .rounded_rect = styles.popoverRadius(t) };
        // 拦截空白区域的指针事件，防止穿透到底层
        popover_ext.hit_roles = .{ .pointer = true, .scroll = false, .inspect = true };

        cx.overlay_stack.bindFloatingContent(allocator, layer_handle, popover_content);

        const cleanup_ctx = try resource_allocator.create(PopoverCleanupCtx);
        cleanup_ctx.* = .{ .handle = layer_handle, .cx = cx };
        my_scope.adoptResource(@ptrCast(cleanup_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const ctx: *PopoverCleanupCtx = @ptrCast(@alignCast(ptr));
                ctx.cx.overlay_stack.removePermanently(ctx.handle);
                alloc.destroy(ctx);
            }
        }.cleanup) catch |err| {
            resource_allocator.destroy(cleanup_ctx);
            return err;
        };
        layer_registered = true;

        popover_content.style.width = .{ .px = 0 };
        popover_content.style.height = .{ .px = 0 };
        popover_content.style.overflow_hidden = true;
        popover_content.setOpacityRaw(if (p.prewarm_hidden_layout) HIDDEN_OPACITY else 0);
        cx.overlay_stack.commitExit(layer_handle);
        popover_content.style.width = .{ .px = 0 };
        popover_content.style.height = .{ .px = 0 };
        popover_content.style.overflow_hidden = true;

        // Portal 化：floating content 与 trigger 模式无关，始终直接挂到
        // cx.popover_portal_root（App.mount 会在构建用户树前创建）。wrapper
        // 只保留 trigger 并留在 caller 的正常文档流。这是本渲染器里
        // 唯一能跨父级压过 caller 树中 cousin 的机制
        // —— z_index 只有同级兄弟语义（render_engine sortSubtreeChildrenByZ），
        // inline content 的 z 压不过 wrapper 祖先的后置兄弟。portal 同时让 content
        // 免于祖先 overflow_hidden 裁剪与 modal dialog composited surface 的纹理
        // 边界裁切（surface bounds 不含 z>0 子树）。定位不受影响：
        // popoverBeforeRender 的 translate = 目标世界坐标 − parent.globalRect()，
        // parent 无关。trigger 仍在 caller 树，click/hover 语义不变。
        const content_portal = try cx.ensurePopoverPortalRoot();
        try content_portal.appendChild(allocator, popover_content);

        const mount_ctx = try resource_allocator.create(DetachedContentCtx);
        mount_ctx.* = .{
            .parent = content_portal,
            .content = popover_content,
            .cx = cx,
            .layer_handle = layer_handle,
            .detach_hidden_content = p.detach_hidden_content,
            .portaled = true,
        };
        my_scope.adoptResource(@ptrCast(mount_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const ctx: *DetachedContentCtx = @ptrCast(@alignCast(ptr));
                // portal 下 content 挂在 portal root（caller 子树之外），scope dispose
                // 不会经由 caller 树释放它 —— 必须先摘下来再走 detached 释放，否则
                // portal root 残留一个 scope 已死的子节点（悬垂 UAF）。
                if (ctx.portaled) {
                    if (ctx.content.parent) |parent| ctx.cx.detachChild(parent, ctx.content);
                }
                if (ctx.content.parent == null) {
                    ctx.cx.freeDetachedNodeAfterScopeDispose(ctx.content);
                }
                alloc.destroy(ctx);
            }
        }.cleanup) catch |err| {
            resource_allocator.destroy(mount_ctx);
            return err;
        };
        content_registered = true;

        // 根据 size_policy 决定 caller 的 content 挂点。
        // .fit_or_scroll：在 popover_content 内嵌 ScrollArea，caller 把内容挂到
        //   scroll content；ScrollArea container 自己用 fit{.max=p.max_height} 限制总高，
        //   超出由 ScrollArea 滚动条处理。popover_content 已设 fit{.max=mh}，但 ScrollArea
        //   container 用 grow + max 时在 fit 父里没空间，所以同时给它 fit + max（让它在 popup
        //   内自然撑高，过 max clamp）。caller 内容是 ScrollArea content，挂多少滚多少。
        var scroll_container_node: ?*Node = null;
        const caller_content_node: *Node = if (p.size_policy == .fit_or_scroll) blk: {
            // 配置错误走 error 而不是 panic：mount 本来就返回 !PopoverResult，
            // 错误通道已经存在，没有理由让库代码因为 caller 少填一个字段就杀掉
            // 宿主进程。（框架的 @panic("OOM:") 策略只适用于「半更新不可恢复」
            // 的索引/响应式路径，不是这里。）
            const max_w: f32 = p.max_width orelse return error.FitOrScrollRequiresMaxWidth;
            const max_h: f32 = p.max_height orelse return error.FitOrScrollRequiresMaxHeight;
            if (p.prewarm_hidden_layout) {
                popover_content.style.width = .{ .fit = .{ .max = max_w } };
                popover_content.style.height = .{ .fit = .{ .max = max_h } };
            }
            const scroll_result = try scroll_area_mod.mountScrollArea(.{
                .direction = .vertical,
                .background = Color.TRANSPARENT,
                .width = max_w,
                .height = max_h,
            }, my_scope, cx);
            // Bug 1 + Bug 3 都已修：
            //   Bug 3 在 framework 层（appendDisplayClipBridgeBegin）。
            //   Bug 1（scrollbarBeforeRender 触发 holdEnterUntilGeometryStable）
            //   已不复现 — 经 e2e 验证 hook 启用后 popup 正常显示。
            try appendNewChild(cx, popover_content, scroll_result.container);
            scroll_container_node = scroll_result.container;
            break :blk scroll_result.content;
        } else popover_content;

        const target_width = p.width;

        // 触发方式绑定
        switch (p.trigger) {
            .click => {
                trigger_node.behavior.events.on_click = core.Cx.simpleHandler(
                    struct {
                        fn handler(context: *anyopaque) void {
                            const sig: *Signal(bool) = @ptrCast(@alignCast(context));
                            sig.set(!sig.peek());
                        }
                    }.handler,
                    @ptrCast(is_open),
                );
                trigger_node.tag = .button;
            },
            .hover => {
                wrapper.behavior.events.on_hover = core.Cx.simpleHandler(
                    struct {
                        fn handler(context: *anyopaque) void {
                            const sig: *Signal(bool) = @ptrCast(@alignCast(context));
                            sig.set(true);
                        }
                    }.handler,
                    @ptrCast(is_open),
                );
                wrapper.behavior.events.on_leave = core.Cx.simpleHandler(
                    struct {
                        fn handler(context: *anyopaque) void {
                            const sig: *Signal(bool) = @ptrCast(@alignCast(context));
                            sig.set(false);
                        }
                    }.handler,
                    @ptrCast(is_open),
                );
            },
            .manual => {},
        }

        // Effect: 控制显示/隐藏（仅切换 width/height）
        const fit_or_scroll_flag = p.size_policy == .fit_or_scroll;
        // fit_or_scroll 时强制把 popup 的 width/height 钉到 max_width/max_height（必填）。
        // target_width 用 max_width 覆盖 caller 的 p.width（让 effect 走 px 路径）。
        const effective_target_width: ?f32 = if (fit_or_scroll_flag) p.max_width else target_width;
        const effective_fit_h: ?f32 = if (fit_or_scroll_flag) p.max_height else null;
        try my_scope.createEffect(.{
            .popover = popover_content,
            .is_open = is_open,
            .target_width = effective_target_width,
            .cx = cx,
            .layer_handle = layer_handle,
            .fit_or_scroll = fit_or_scroll_flag,
            .fit_h = effective_fit_h,
            .mount_ctx = mount_ctx,
            // fit_content 路径下 fit 必须带 max（防长内容撑爆 popover）—— 见上方 content_width 注释
            .max_w = p.max_width,
            .max_h = p.max_height,
            .clip_subtree = p.clip_subtree_to_chrome,
        }, struct {
            fn update(c: anytype) void {
                if (c.is_open.get()) {
                    ensurePopoverContentAttached(c.mount_ctx);
                    c.cx.overlay_stack.reactivate(c.layer_handle);
                    // 退场动画中途重开：reactivate 只处理已挂起的层，exiting 层必须
                    // 拉回 entering，否则动画播完 commitExit 会把刚置 true 的
                    // visible 写回 false（与 Modal/Sheet 同一处理）。
                    if (c.cx.overlay_stack.findLayer(c.layer_handle)) |layer| {
                        if (layer.state == .exiting) c.cx.overlay_stack.cancelExit(c.layer_handle, .entering);
                    }
                    var sizing_changed = false;
                    // size_policy=.fit_or_scroll 时 popover_content 用固定 px（max_width/max_height），
                    // 内部 ScrollArea 处理可滚动。每次 open 主动 reset 回 px（hide 时被设为 0）。
                    if (c.fit_or_scroll) {
                        // hide 状态 px=0；open 时 reset 回 fit{max=N}。
                        if (c.target_width) |w| {
                            const need_reset = switch (c.popover.style.width) {
                                .px => |v| v <= 1,
                                else => false,
                            };
                            if (need_reset) {
                                c.popover.style.width = .{ .fit = .{ .max = w } };
                                sizing_changed = true;
                            }
                        }
                        if (c.fit_h) |h| {
                            const need_reset = switch (c.popover.style.height) {
                                .px => |v| v <= 1,
                                else => false,
                            };
                            if (need_reset) {
                                c.popover.style.height = .{ .fit = .{ .max = h } };
                                sizing_changed = true;
                            }
                        }
                    } else {
                        if (c.target_width) |w| {
                            if (sizingPxValue(c.popover.style.width)) |current| {
                                if (!approxEq(current, w)) {
                                    c.popover.style.width = .{ .px = w };
                                    sizing_changed = true;
                                }
                            } else {
                                c.popover.style.width = .{ .px = w };
                                sizing_changed = true;
                            }
                        } else {
                            // fit-content 路径：caller 给了 max_width 时必须把 max 带上，
                            // 否则长内容会撑爆 popover 边界（长段落文本等场景）。
                            const target_mw: f32 = c.max_w orelse std.math.inf(f32);
                            const need_set: bool = switch (c.popover.style.width) {
                                .fit => |f| !approxEq(f.max, target_mw),
                                else => true,
                            };
                            if (need_set) {
                                c.popover.style.width = .{ .fit = .{ .max = target_mw } };
                                sizing_changed = true;
                            }
                        }
                        const target_mh: f32 = c.max_h orelse std.math.inf(f32);
                        const need_set_h: bool = switch (c.popover.style.height) {
                            .fit => |f| !approxEq(f.max, target_mh),
                            else => true,
                        };
                        if (need_set_h) {
                            c.popover.style.height = .{ .fit = .{ .max = target_mh } };
                            sizing_changed = true;
                        }
                    }
                    // visible 时按 caller 意愿设 overflow_hidden（默认 false，配合 clip_subtree=true 时保 true）
                    const want_overflow_hidden = c.clip_subtree;
                    if (c.popover.style.overflow_hidden != want_overflow_hidden) {
                        c.popover.style.overflow_hidden = want_overflow_hidden;
                        sizing_changed = true;
                    }
                    c.popover.markSizingDirty();
                    c.popover.markInteractionDirty();
                    c.popover.markRenderDirty();
                    c.popover.markCompositeDirty();
                } else {
                    c.cx.overlay_stack.beginExit(c.layer_handle);
                }
                c.cx.needs_redraw = true;
            }
        }.update);

        // on_before_render: layout 完成后定位（此时 rect 已正确计算）
        const position_ctx = try resource_allocator.create(PopoverPositionCtx);
        const effective_anchor: EffectiveAnchor = if (p.anchor) |a| switch (a) {
            .node => |n| .{ .external_node = n },
            .virtual => |v| .{ .virtual = v },
        } else .self_trigger;

        position_ctx.* = .{
            .popover = popover_content,
            .scope = my_scope,
            .trigger_node = trigger_node,
            .effective_anchor = effective_anchor,
            .is_open = is_open,
            .layer_handle = layer_handle,
            .pos = p.position,
            .offset = p.offset,
            .cx = cx,
            .flip = p.flip,
            .shift_main_axis = p.shift_main_axis,
            .fallback_placements = p.fallback_placements,
            .fallback_placements_ptr = p.fallback_placements_ptr,
            .preferred_width = p.width,
            .preferred_max_width = p.max_width,
            .preferred_max_height = p.max_height,
            .match_trigger_width = p.match_trigger_width,
            .constrain_width_to_viewport = p.constrain_width_to_viewport,
            .viewport_padding = p.viewport_padding,
            .active_position = p.position,
            .entry_ready = false,
            .prewarmed_ready = false,
            .is_visible = false,
            .prewarm_hidden_layout = p.prewarm_hidden_layout,
            .mount_ctx = mount_ctx,
            .enter_transition = p.enter_transition,
            .exit_transition = p.exit_transition,
            .avoid_rects_provider = p.avoid_rects_provider,
            .scroll_container = scroll_container_node,
            .clip_subtree_to_chrome = p.clip_subtree_to_chrome,
        };

        my_scope.registerResource(@ptrCast(position_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const ctx: *PopoverPositionCtx = @ptrCast(@alignCast(ptr));
                alloc.destroy(ctx);
            }
        }.cleanup) catch |err| {
            resource_allocator.destroy(position_ctx);
            return err;
        };
        popover_content.meta.per_frame.hooks.before_render.main = popoverBeforeRender;
        popover_content.meta.per_frame.hooks.slots.anim_state = @ptrCast(position_ctx);

        if (!is_open.peek()) {
            detachPopoverContentIfSuspended(mount_ctx);
        }

        return .{
            .wrapper = wrapper,
            .trigger = trigger_node,
            .content = caller_content_node,
            .chrome = popover_content,
            .is_open = is_open,
            .active_position_ptr = &position_ctx.active_position,
            .portaled = false,
        };
    }
};

// ========== 内部辅助 ==========

fn appendNewChild(cx: *Cx, parent: *Node, child: *Node) !void {
    parent.appendChild(cx.allocator, child) catch |err| {
        cx.freeNode(child);
        return err;
    };
}

const PopoverCleanupCtx = struct {
    handle: overlay_stack_mod.LayerHandle,
    cx: *Cx,
};

const DetachedContentCtx = struct {
    parent: *Node,
    content: *Node,
    cx: *Cx,
    layer_handle: overlay_stack_mod.LayerHandle,
    detach_hidden_content: bool,
    /// content 挂在 popover_portal_root（非 caller 子树）——dispose 时需主动摘除。
    portaled: bool = false,
};

fn ensurePopoverContentAttached(ctx: *DetachedContentCtx) void {
    if (!ctx.detach_hidden_content) return;
    if (ctx.content.parent != null) return;
    ctx.parent.appendChild(ctx.cx.allocator, ctx.content) catch return;
    ctx.content.markRuntimeIndexFullRebuild();
    ctx.content.markSizingDirty();
    ctx.content.markRenderDirty();
    ctx.cx.needs_redraw = true;
}

fn detachPopoverContentIfSuspended(ctx: *DetachedContentCtx) void {
    if (!ctx.detach_hidden_content) return;
    if (ctx.content.parent == null) return;
    if (ctx.cx.overlay_stack.findLayer(ctx.layer_handle)) |layer| {
        if (!layer.suspended) return;
    }
    ctx.cx.detachChildRetained(ctx.parent, ctx.content);
    ctx.cx.needs_redraw = true;
}

/// 定位时实际锚点 —— node / 外部 node / virtual 三选一
const EffectiveAnchor = union(enum) {
    /// 默认：用 trigger_node（popover 自己 mount 出的）
    self_trigger,
    /// 调用方提供的真实 Node
    external_node: *Node,
    /// 虚拟锚点
    virtual: VirtualAnchor,
};

/// on_before_render 定位上下文
pub const PopoverPositionCtx = struct {
    popover: *Node,
    scope: *Scope,
    trigger_node: *Node,
    /// 实际定位用的锚点
    effective_anchor: EffectiveAnchor,
    is_open: *Signal(bool),
    layer_handle: overlay_stack_mod.LayerHandle,
    pos: PopoverPosition,
    offset: PopoverOffset,
    cx: *Cx,
    flip: bool,
    shift_main_axis: bool = false,
    fallback_placements: []const PopoverPosition = &.{},
    fallback_placements_ptr: ?*[]const PopoverPosition = null,
    preferred_width: ?f32,
    preferred_max_width: ?f32,
    preferred_max_height: ?f32,
    match_trigger_width: bool,
    constrain_width_to_viewport: bool,
    viewport_padding: f32,
    active_position: PopoverPosition,
    entry_ready: bool,
    prewarmed_ready: bool,
    is_visible: bool,
    prewarm_hidden_layout: bool,
    mount_ctx: ?*DetachedContentCtx = null,
    enter_transition: overlay_stack_mod.Transition,
    exit_transition: overlay_stack_mod.Transition,
    /// 每帧通过它拿"必须避让的 rect 列表"（见 PopoverProps.avoid_rects_provider 注释）
    avoid_rects_provider: ?*const fn (cx: *Cx, buf: []floating.Rect) []const floating.Rect = null,
    /// size_policy=.fit_or_scroll 时内嵌的 ScrollArea 容器（px 高 = max_height）。
    /// autosize 收紧 popover_content 时必须同步收紧它，否则容器按原 px 撑出 chrome。
    scroll_container: ?*Node = null,
    /// caller 的 clip_subtree_to_chrome 意愿；autosize cap 生效时会被临时抬成 true。
    clip_subtree_to_chrome: bool = false,
    /// 定位器算出的静止 translate（不含 `.dropdown` 过渡的滑入偏移）。
    /// 退场冻结分支没有新定位结果，靠它 + 当前偏移重写 translate。
    rest_translate_x: f32 = 0,
    rest_translate_y: f32 = 0,

    /// 当前生效的锚点矩形（absolute viewport 坐标）
    pub fn anchorRect(self: *const PopoverPositionCtx) AnchorRect {
        return switch (self.effective_anchor) {
            .self_trigger => blk: {
                const g = self.trigger_node.globalRect();
                // 全局 hook 读 rect（epoch==0 时 fallback 到 node.rect）。
                const r = self.trigger_node.rectFromWorldOrFallback();
                break :blk .{ .x = g.x, .y = g.y, .w = r.w, .h = r.h };
            },
            .external_node => |n| blk: {
                const g = n.globalRect();
                const r = n.rectFromWorldOrFallback();
                break :blk .{ .x = g.x, .y = g.y, .w = r.w, .h = r.h };
            },
            .virtual => |va| va.getRect(va.ctx),
        };
    }
};

fn isZeroPx(sizing: core.Sizing) bool {
    return switch (sizing) {
        .px => |v| v == 0,
        else => false,
    };
}

fn approxEq(a: f32, b: f32) bool {
    if (std.math.isInf(a) and std.math.isInf(b)) return true;
    return @abs(a - b) <= 0.5;
}

fn sizingPxValue(sizing: core.Sizing) ?f32 {
    return switch (sizing) {
        .px => |v| v,
        else => null,
    };
}

/// `.dropdown` 过渡的贴锚点滑入：未显示时离锚点反方向 6px，随 opacity
/// （= 过渡的 ease-out 进度）回到 0。方向跟随实际落位（flip 到上方时向下滑）。
pub const DROPDOWN_SLIDE_PX: f32 = 6;

pub fn dropdownSlideOffset(side: floating.Side, opacity: f32) [2]f32 {
    const d = (1 - std.math.clamp(opacity, 0, 1)) * DROPDOWN_SLIDE_PX;
    return switch (side) {
        .bottom => .{ 0, -d },
        .top => .{ 0, d },
        .right => .{ -d, 0 },
        .left => .{ d, 0 },
    };
}

/// 写入定位结果：记下静止位置，叠加 `.dropdown` 当前偏移（按节点现有 opacity），
/// 并把落位方向交给过渡控制器——同帧后续的 opacity 推进由它按增量补上。
fn setPopoverRestTranslate(ctx: *PopoverPositionCtx, x: f32, y: f32) bool {
    ctx.rest_translate_x = x;
    ctx.rest_translate_y = y;
    return applyDropdownSlide(ctx);
}

fn applyDropdownSlide(ctx: *PopoverPositionCtx) bool {
    var x = ctx.rest_translate_x;
    var y = ctx.rest_translate_y;
    const uses_dropdown = ctx.enter_transition == .dropdown or ctx.exit_transition == .dropdown;
    if (uses_dropdown) {
        const unit = dropdownSlideOffset(floating.getSide(ctx.active_position), 0);
        if (ctx.cx.overlay_stack.findLayer(ctx.layer_handle)) |layer| {
            layer.enter_ctrl.slide = unit;
            layer.exit_ctrl.slide = unit;
        }
        const off = dropdownSlideOffset(floating.getSide(ctx.active_position), ctx.popover.getOpacity());
        x += off[0];
        y += off[1];
    }
    return setPopoverTranslate(ctx.popover, x, y);
}

fn setPopoverTranslate(node: *Node, x: f32, y: f32) bool {
    const changed = @abs(node.style.translate_x - x) > 0.01 or @abs(node.style.translate_y - y) > 0.01;
    if (!changed) return false;
    node.style.translate_x = x;
    node.style.translate_y = y;
    // 统一权威失效组合（interaction+composite+cache 失效）：composite 保证 surface
    // 位置更新，cache 失效保证已 prebuild 的 display payload 不按旧位置 replay。
    node.markCompositePropDirty();
    return true;
}

fn hiddenWidth(ctx: *const PopoverPositionCtx) core.Sizing {
    return if (ctx.preferred_width) |w| .{ .px = w } else .{ .fit = .{} };
}

pub fn transformOriginForPlacement(pos: PopoverPosition) core.TransformOrigin {
    return switch (pos) {
        .top_start => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 1.0 } },
        .top => .{ .x = .{ .percent = 0.5 }, .y = .{ .percent = 1.0 } },
        .top_end => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 1.0 } },
        .bottom_start => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 0.0 } },
        .bottom => .{ .x = .{ .percent = 0.5 }, .y = .{ .percent = 0.0 } },
        .bottom_end => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 0.0 } },
        .left_start => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 0.0 } },
        .left => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 0.5 } },
        .left_end => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 1.0 } },
        .right_start => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 0.0 } },
        .right => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 0.5 } },
        .right_end => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 1.0 } },
    };
}

fn syncTransformOriginForPlacement(node: *Node, pos: PopoverPosition, allocator: Allocator) void {
    const next = transformOriginForPlacement(pos);
    const ext = node.style.ensureExtPanic(allocator);
    if (std.meta.eql(ext.transform_origin, next)) return;
    ext.transform_origin = next;
    node.markInteractionDirty();
    node.markCompositeDirty();
}

fn popoverDebugEnabled() bool {
    return std.posix.getenv("ZENIT_POPOVER_DEBUG") != null;
}

fn popoverContentReady(node: *Node) bool {
    // 全局 hook 读 rect。
    const r = node.rectFromWorldOrFallback();
    if (r.w <= 0 or r.h <= 0) return false;
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.core.subtree_layout) return false;
    // Placement only consumes measured geometry. Requiring subtree_render to
    // be clean creates a deadlock for a freshly opened/prewarmed overlay: the
    // hidden subtree cannot finish its first paint until it is positioned and
    // admitted by the overlay stack, while positioning used to wait for that
    // paint. Render dirtiness is safe here because opacity remains hidden until
    // the enter controller commits the positioned frame.
    return true;
}

/// autosize 折叠到 viewport 后的高度下限：viewport 很挤时别把面板折到 0
/// （此时宁可 overlap anchor 也要可读）。
pub const AUTOSIZE_MIN_HEIGHT: f32 = 48;

/// 把 autosize middleware 算出的可用高度写成 popover_content（及 fit_or_scroll 的
/// ScrollArea 容器）的 ext.max_height。等价 floating-ui `size` 中
/// `maxHeight: availableHeight` 的 apply。没有 autosize 数据时回落到 caller cap。
///
/// cap 真正咬住内容（当前测得高度 `ph` ≥ cap）时同时打开 chrome 的 overflow_hidden：
/// visible 态默认 overflow_hidden=false，只收 chrome 不裁子节点的话内容照样溢出
/// 外壳（flip 到上方时就压回 trigger），等于没收。cap 没咬住时恢复 caller 意愿。
fn applyAutosizeMaxHeight(ctx: *PopoverPositionCtx, auto_opt: ?floating.AutosizeData, ph: f32) void {
    var target_max_h: f32 = ctx.preferred_max_height orelse std.math.inf(f32);
    if (auto_opt) |auto| {
        if (auto.apply_height) {
            target_max_h = @min(target_max_h, @max(auto.committed_max_height, AUTOSIZE_MIN_HEIGHT));
        }
    }
    const ext = ctx.popover.style.ensureExtPanic(ctx.cx.allocator);
    // ph 是上一帧按旧 max_height 排出来的高度。滚动/窗口变化让可用高度逐帧变大时，
    // 被旧 cap 咬住的 ph < 新 target，若只和新 target 比会在本帧关掉裁切——而内容
    // 实际比旧 cap 还高，下一帧 layout 才长到新 cap，这一帧整块内容溢出面板
    // （连续滚动 = 连续多帧漏出）。所以 ph 贴住旧 cap 时同样视为 cap 咬住。
    const prev_max_h = ext.max_height;
    if (!approxEq(ext.max_height, target_max_h)) {
        ext.max_height = target_max_h;
        ctx.popover.markSizingDirty();
    }
    const cap_binding = (!std.math.isInf(target_max_h) and ph >= target_max_h - 0.5) or
        (!std.math.isInf(prev_max_h) and ph >= prev_max_h - 0.5);
    const want_clip = ctx.clip_subtree_to_chrome or cap_binding;
    var clip_changed = false;
    if (ctx.popover.style.overflow_hidden != want_clip) {
        ctx.popover.style.overflow_hidden = want_clip;
        clip_changed = true;
    }
    // 裁切形状跟随 chrome 的圆角（.auto → border.radius 推出的 rounded_rect），
    // caller 改了面板圆角（下游编辑器工具条菜单 radius 10）也自动一致。
    // 历史：这里曾刻意用矩形 clip，绕开「composited owner 圆角 + overflow_hidden
    // settle 后嵌套 rounded_clip layer 落错帧（面板画到 2× 位置）」；代价是阴影
    // 被矩形裁出圆角外的灰块、贴边内容压住描边。框架已改为 surface owner 的
    // overflow clip 只包 children（node-local SDF push_clip，padding-box 内沿），
    // 不再开 rounded_clip layer，绕行随之撤销。caller 显式要
    // clip_subtree_to_chrome 的保持其原有形状不动。
    if (!ctx.clip_subtree_to_chrome) {
        if (std.meta.activeTag(ext.clip_shape) != .auto) {
            ext.clip_shape = .auto;
            clip_changed = true;
        }
    }
    if (clip_changed) {
        ctx.popover.markSizingDirty();
        ctx.popover.markInteractionDirty();
        ctx.popover.markRenderDirty();
        ctx.popover.markCompositeDirty();
    }
    if (ctx.scroll_container) |sc| {
        const sc_ext = sc.style.ensureExtPanic(ctx.cx.allocator);
        if (!approxEq(sc_ext.max_height, target_max_h)) {
            sc_ext.max_height = target_max_h;
            sc.markSizingDirty();
        }
    }
}

pub fn popoverBeforeRender(node: *Node) void {
    const ctx: *PopoverPositionCtx = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    const overlay_visual_in_progress = ctx.popover.frame_state.state_bits.flags.manual_opacity_animation_active or
        ctx.popover.frame_state.state_bits.flags.manual_transform_animation_active or
        ((ctx.popover.getOpacity() > (HIDDEN_OPACITY + 0.0001) and ctx.popover.getOpacity() < 0.999) or
            @abs(ctx.popover.style.scale_x() - 1.0) > 0.0001 or
            @abs(ctx.popover.style.scale_y() - 1.0) > 0.0001);
    const should_stabilize_text = (ctx.enter_transition == .scale_fade or ctx.enter_transition == .dropdown) and overlay_visual_in_progress;
    if (ctx.popover.frame_state.state_bits.flags.text_stabilize_subtree != should_stabilize_text) {
        ctx.popover.frame_state.state_bits.flags.text_stabilize_subtree = should_stabilize_text;
        ctx.popover.markRenderDirty();
        ctx.popover.markCompositeDirty();
    }

    if (!ctx.is_open.peek()) {
        if (ctx.mount_ctx) |mount_ctx| {
            if (ctx.cx.overlay_stack.findLayer(ctx.layer_handle)) |layer| {
                if (layer.suspended) {
                    // An exit with `.none` commits synchronously, so this can
                    // be the first closed-frame callback. Reset placement
                    // readiness before detaching; otherwise reopen skips the
                    // entry-ready branch and retains commitExit's opacity=0.
                    ctx.active_position = ctx.pos;
                    ctx.entry_ready = false;
                    ctx.is_visible = false;
                    if (!ctx.prewarm_hidden_layout) ctx.prewarmed_ready = false;
                    detachPopoverContentIfSuspended(mount_ctx);
                    return;
                }
            }
        }
        if (popoverDebugEnabled()) {
            const exit_rect_pre = ctx.popover.globalRect();
            std.debug.print("[popover-exit] tid={s} stage=enter_branch rect=({d:.0},{d:.0},{d:.0}x{d:.0}) trans=({d:.1},{d:.1}) op={d:.3} scale=({d:.3},{d:.3}) anim_op={} anim_tf={} prewarm={}\n", .{
                ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                exit_rect_pre.x,
                exit_rect_pre.y,
                exit_rect_pre.w,
                exit_rect_pre.h,
                ctx.popover.style.translate_x,
                ctx.popover.style.translate_y,
                ctx.popover.getOpacity(),
                ctx.popover.style.scale_x(),
                ctx.popover.style.scale_y(),
                ctx.popover.frame_state.state_bits.flags.manual_opacity_animation_active,
                ctx.popover.frame_state.state_bits.flags.manual_transform_animation_active,
                ctx.prewarm_hidden_layout,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, false, ctx.cx.allocator);
        ctx.active_position = ctx.pos;
        syncTransformOriginForPlacement(ctx.popover, ctx.active_position, ctx.cx.allocator);
        ctx.entry_ready = false;
        ctx.is_visible = false;
        // Exit transition 期间 OR 仍有可见残留时 → 不能 reset translate/scale，
        // 否则 popover 会瞬间飞到 (0,0) 然后才在原位完成 fade，肉眼看到左上角残影。
        // 判据：(a) overlay_stack 已挂 manual flag；(b) opacity > HIDDEN_OPACITY（仍可见）；
        //       (c) scale 不在 hidden 静默状态。
        // 任一成立 → 把这一帧让给 TransitionController，等它把 fade 走完。
        const exit_hidden_scale = overlay_stack_mod.TransitionController.hiddenScaleForTransition(ctx.exit_transition);
        const popup_still_visible = ctx.popover.getOpacity() > (HIDDEN_OPACITY + 0.0001) or
            @abs(ctx.popover.style.scale_x() - exit_hidden_scale) > 0.001 or
            @abs(ctx.popover.style.scale_y() - exit_hidden_scale) > 0.001;
        if (overlay_visual_in_progress or popup_still_visible) {
            // 退场期间定位器不再跑：把落位方向交给退场控制器，由它同帧推进滑出。
            if (ctx.exit_transition == .dropdown) _ = applyDropdownSlide(ctx);
            if (popoverDebugEnabled()) {
                std.debug.print("[popover-exit] tid={s} stage=transition_freeze visual_in_prog={} still_visible={} op={d:.3}\n", .{
                    ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                    overlay_visual_in_progress,
                    popup_still_visible,
                    ctx.popover.getOpacity(),
                });
            }
            ctx.popover.markInteractionDirty();
            ctx.cx.needs_redraw = true;
            return;
        }
        if (!ctx.prewarm_hidden_layout) {
            ctx.prewarmed_ready = false;
            var interaction_changed = false;
            const collapsed = isZeroPx(ctx.popover.style.width) and isZeroPx(ctx.popover.style.height) and ctx.popover.style.overflow_hidden;
            if (!collapsed or ctx.popover.getOpacity() != 0 or ctx.popover.style.translate_x != 0 or ctx.popover.style.translate_y != 0) {
                if (popoverDebugEnabled()) {
                    std.debug.print("[popover-exit] tid={s} stage=reset_no_prewarm trans_was=({d:.1},{d:.1}) op_was={d:.3}\n", .{
                        ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                        ctx.popover.style.translate_x,
                        ctx.popover.style.translate_y,
                        ctx.popover.getOpacity(),
                    });
                }
                ctx.popover.style.width = .{ .px = 0 };
                ctx.popover.style.height = .{ .px = 0 };
                ctx.popover.style.overflow_hidden = true;
                ctx.popover.setOpacityRaw(0);
                interaction_changed = setPopoverTranslate(ctx.popover, 0, 0);
                ctx.popover.markSizingDirty();
                ctx.popover.markSubtreeDirty();
                ctx.popover.markRenderDirty();
            }
            // 全局 hook 读 rect。
            const pr = ctx.popover.rectFromWorldOrFallback();
            if (pr.w != 0 or pr.h != 0) {
                ctx.popover.markSizingDirty();
                ctx.popover.markSubtreeDirty();
                ctx.cx.needs_redraw = true;
            }
            if (interaction_changed) ctx.cx.needs_redraw = true;
            return;
        }
        var sizing_changed = false;
        var visual_changed = false;
        var interaction_changed = false;
        const hidden_scale = overlay_stack_mod.TransitionController.hiddenScaleForTransition(ctx.enter_transition);
        const target_width = hiddenWidth(ctx);
        const width_needs_restore = switch (target_width) {
            .fit => isZeroPx(ctx.popover.style.width),
            .px => |w| if (sizingPxValue(ctx.popover.style.width)) |current| !approxEq(current, w) else true,
            else => true,
        };
        const height_needs_restore = isZeroPx(ctx.popover.style.height);
        if (width_needs_restore or height_needs_restore or ctx.popover.style.overflow_hidden) {
            ctx.popover.style.width = target_width;
            ctx.popover.style.height = .{ .fit = .{} };
            ctx.popover.style.overflow_hidden = false;
            sizing_changed = true;
        }
        if (ctx.popover.getOpacity() != HIDDEN_OPACITY or ctx.popover.style.scale_x() != hidden_scale or ctx.popover.style.scale_y() != hidden_scale or sizing_changed) {
            if (popoverDebugEnabled()) {
                std.debug.print("[popover-exit] tid={s} stage=reset_prewarm trans_was=({d:.1},{d:.1}) op_was={d:.3} sizing_changed={}\n", .{
                    ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                    ctx.popover.style.translate_x,
                    ctx.popover.style.translate_y,
                    ctx.popover.getOpacity(),
                    sizing_changed,
                });
            }
            ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
            interaction_changed = setPopoverTranslate(ctx.popover, 0, 0);
            const ext = ctx.popover.style.ensureExtPanic(ctx.cx.allocator);
            ext.scale_x = hidden_scale;
            ext.scale_y = hidden_scale;
            visual_changed = true;
            if (sizing_changed) {
                ctx.popover.markSizingDirty();
                ctx.popover.markSubtreeDirty();
            }
            ctx.popover.markRenderDirty();
        }
        // 全局 hook 读 rect。
        const pr2 = ctx.popover.rectFromWorldOrFallback();
        if (!sizing_changed and (pr2.w == 0 or pr2.h == 0)) {
            ctx.popover.markSizingDirty();
            ctx.popover.markSubtreeDirty();
            ctx.cx.needs_redraw = true;
        }
        if (interaction_changed) ctx.cx.needs_redraw = true;
        ctx.prewarmed_ready = !sizing_changed and !visual_changed and popoverContentReady(ctx.popover);
        return;
    }

    const anchor_rect = ctx.anchorRect();
    // Anchor 失效信号：caller 用 ANCHOR_OFFSCREEN_SENTINEL（约定 x/y < -1e5）显式标"失效"。
    // 注意：cursor 类 anchor 合法地返回 w=0 h=0（虚拟零宽点），不能因 w/h=0 就视作失效。
    const anchor_valid = anchor_rect.x > -1.0e5 and anchor_rect.y > -1.0e5;
    if (!anchor_valid) {
        if (popoverDebugEnabled()) {
            const popover_rect_inv = ctx.popover.globalRect();
            std.debug.print("[popover-inv] tid={s} pop_rect=({d:.0},{d:.0},{d:.0}x{d:.0}) trans=({d:.0},{d:.0}) op={d:.3} entry_ready={}\n", .{
                ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                popover_rect_inv.x,
                popover_rect_inv.y,
                popover_rect_inv.w,
                popover_rect_inv.h,
                ctx.popover.style.translate_x,
                ctx.popover.style.translate_y,
                ctx.popover.getOpacity(),
                ctx.entry_ready,
            });
        }
        if (ctx.entry_ready) {
            // 已有过有效定位 → freeze 上一帧 translate（保持位置自然 fade，不要飞回原点）。
            ctx.popover.markInteractionDirty();
        } else {
            // 从未定位过 + anchor 已失效 → 强制完全透明（不是 HIDDEN_OPACITY）。
            // HIDDEN_OPACITY=0.001 是 prewarm 策略：已定位过的 popup 维持测量但视觉隐藏。
            // 但此路径 popup 的 translate 默认 (0,0)，layout 仍会给它算出正常 rect，
            // opacity=0.001 经 GPU 混色后肉眼可见 → 左上角残影。用 0 彻底不画。
            ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
            if (ctx.popover.getOpacity() != 0) {
                ctx.popover.setOpacityRaw(0);
                ctx.popover.markInteractionDirty();
                ctx.popover.markRenderDirty();
                ctx.cx.needs_redraw = true;
            }
        }
        return;
    }
    const tw = anchor_rect.w;
    const th = anchor_rect.h;
    const pop_local_rect = ctx.popover.rectFromWorldOrFallback();
    const pw = pop_local_rect.w;
    const ph = pop_local_rect.h;
    if (pw == 0 or ph == 0) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] pause zero-rect match_trigger_width={} preferred_width={any} rect=({d:.1},{d:.1}) prewarmed={} entry_ready={}\n", .{
                ctx.match_trigger_width,
                ctx.preferred_width,
                pw,
                ph,
                ctx.prewarmed_ready,
                ctx.entry_ready,
            });
        }
        // 已 entered 的 popover 临时遇到 zero-rect（caller 清空 children 触发 reflow）
        // 不要 force HIDDEN_OPACITY，否则 popover 此后再也不会被恢复 ——
        // 框架的"恢复显示"路径只在 entry_ready=false 时才走（line 1054-1072）。
        // 已 entered 时维持当前 opacity，下一帧 layout 完成后无缝显示新内容。
        if (ctx.entry_ready) {
            ctx.cx.needs_redraw = true;
            return;
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
        // 从未定位过 + zero-rect → 强制完全透明（0 而非 HIDDEN_OPACITY=0.001）。
        // 0.001 经 GPU 混色仍可见 → 肉眼看到左上角 (0,0) 的 popup 灰条残影（同 Phase 3 修复）。
        if (ctx.popover.getOpacity() != 0) {
            ctx.popover.setOpacityRaw(0);
            ctx.popover.markInteractionDirty();
            ctx.popover.markRenderDirty();
            ctx.cx.needs_redraw = true;
        }
        return;
    }
    const content_ready = popoverContentReady(ctx.popover);
    const can_use_prewarmed_content = ctx.prewarm_hidden_layout and ctx.prewarmed_ready and content_ready;
    if (!ctx.entry_ready and !can_use_prewarmed_content and (ctx.popover.frame_state.state_bits.dirty.core.layout or ctx.popover.frame_state.state_bits.dirty.core.subtree_layout)) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] pause unstable-layout match_trigger_width={} preferred_width={any} rect=({d:.1},{d:.1}) dirty(l={},s={},r={}) prewarmed={}\n", .{
                ctx.match_trigger_width,
                ctx.preferred_width,
                pw,
                ph,
                ctx.popover.frame_state.state_bits.dirty.core.layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_render,
                ctx.prewarmed_ready,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
        ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
        ctx.cx.needs_redraw = true;
        return;
    }
    if (!ctx.entry_ready and !can_use_prewarmed_content and !overlay_visual_in_progress and !content_ready) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] pause not-ready match_trigger_width={} preferred_width={any} rect=({d:.1},{d:.1}) dirty(l={},s={},r={}) prewarmed={}\n", .{
                ctx.match_trigger_width,
                ctx.preferred_width,
                pw,
                ph,
                ctx.popover.frame_state.state_bits.dirty.core.layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_render,
                ctx.prewarmed_ready,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
        ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
        ctx.cx.needs_redraw = true;
        return;
    }

    const trigger_abs_x = anchor_rect.x;
    const trigger_abs_y = anchor_rect.y;

    // 把 cx.safe_area_* insets 折进 viewport 给 floating-ui middleware 用。
    // viewport 收到的是"安全可显示矩形"，flip / shift / autosize 都按这个矩形算 overflow，
    // 自动避开 title bar / tab bar / status bar。
    const safe_top = ctx.cx.safe_area_top;
    const safe_left = ctx.cx.safe_area_left;
    const vp_x: f32 = safe_left;
    const vp_y: f32 = safe_top;
    const vp_w = @max(@as(f32, 0), ctx.cx.viewport.width - safe_left - ctx.cx.safe_area_right);
    const vp_h = @max(@as(f32, 0), ctx.cx.viewport.height - safe_top - ctx.cx.safe_area_bottom);

    var middleware_buf: [5]floating.Middleware = undefined;
    var middleware_count: usize = 0;
    middleware_buf[middleware_count] = .{ .offset = .{ .main_axis = ctx.offset } };
    middleware_count += 1;
    if (ctx.flip) {
        const effective_fallbacks: []const PopoverPosition = if (ctx.fallback_placements_ptr) |ptr|
            ptr.*
        else
            ctx.fallback_placements;
        middleware_buf[middleware_count] = .{ .flip = .{ .fallback_placements = effective_fallbacks } };
        middleware_count += 1;
    }
    middleware_buf[middleware_count] = .{ .shift = .{ .main_axis = ctx.shift_main_axis, .cross_axis = true } };
    middleware_count += 1;
    if (ctx.match_trigger_width or ctx.constrain_width_to_viewport or ctx.preferred_max_width != null) {
        middleware_buf[middleware_count] = .{ .size = .{ .padding = ctx.viewport_padding } };
        middleware_count += 1;
    }
    // autosize（= floating-ui `size` 的 availableHeight → max-height）**始终**参与：
    // flip/shift 决定最终 placement 后，把该 placement 下 viewport 剩余高度作为
    // popover_content 的 max_height 上限（caller 设了 max_height 时取两者 min）。
    // 以前只在 caller 设了 max_height 时才激活，于是没设的 popover 在两侧都放不下时
    // 保持完整高度，best-fit 只挪 translate 不改 layout → 面板压住 reference element。
    // 消费方式：只改 ext.max_height + markSizingDirty，让下一帧 layout 自然应用，
    // **不触发 needs_remeasure**（强制 remeasure 会让 popup 永远 paused 不弹）。
    middleware_buf[middleware_count] = .{ .autosize = .{ .padding = ctx.viewport_padding, .apply_width = false } };
    middleware_count += 1;

    const anchor_rect_pos = floating.Rect.init(trigger_abs_x, trigger_abs_y, tw, th);
    const popover_rect_pos = floating.Rect.init(0, 0, pw, ph);
    const viewport_rect_pos = floating.Rect.init(vp_x, vp_y, vp_w, vp_h);

    // 收集 avoid_rects（如 signature 避让 completion/docs chrome rect）：
    // caller 提供 provider fn，每帧调一次。没 provider 就传空 slice。
    var avoid_buf: [8]floating.Rect = undefined;
    const excluded_slice: []const floating.Rect = if (ctx.avoid_rects_provider) |provider|
        provider(ctx.cx, &avoid_buf)
    else
        &.{};

    const positioned = floating.computePosition(
        anchor_rect_pos,
        popover_rect_pos,
        viewport_rect_pos,
        .{
            .placement = ctx.pos,
            .middleware = middleware_buf[0..middleware_count],
            .excluded_rects = excluded_slice,
        },
    );
    // autosize 驱动 max_height 软收紧（不 remeasure，见 middleware 注释）。
    // layout_engine 的 fit/grow intrinsic clamp 已经通过 effectiveMinMax 融合
    // sizing.max 与 ext.max_height（取 min），px 子节点也按 ext.max_height clamp
    // → 这里只更新 ext.max_height 即可，layout 下一帧自然按融合后的 max clamp。
    applyAutosizeMaxHeight(ctx, positioned.middleware_data.autosize, ph);

    if (ctx.match_trigger_width or ctx.constrain_width_to_viewport or ctx.preferred_max_width != null) {
        var needs_remeasure = false;
        var target_width: ?f32 = null;
        if (ctx.match_trigger_width) {
            target_width = tw;
        } else if (ctx.preferred_width) |w| {
            target_width = w;
        }

        if (ctx.constrain_width_to_viewport) {
            if (positioned.middleware_data.size) |size_data| {
                if (target_width) |w| {
                    target_width = @min(w, size_data.available_width);
                }
            }
        }

        if (target_width) |w| {
            if (sizingPxValue(ctx.popover.style.width)) |current| {
                if (!approxEq(current, w)) {
                    ctx.popover.style.width = .{ .px = w };
                    needs_remeasure = true;
                }
            } else {
                ctx.popover.style.width = .{ .px = w };
                needs_remeasure = true;
            }
        }

        const ext = ctx.popover.style.ensureExtPanic(ctx.cx.allocator);
        var target_max_width = ctx.preferred_max_width orelse std.math.inf(f32);
        if (ctx.constrain_width_to_viewport) {
            if (positioned.middleware_data.size) |size_data| {
                target_max_width = @min(target_max_width, size_data.available_width);
            }
        }

        if (std.math.isInf(target_max_width)) {
            if (!std.math.isInf(ext.max_width)) {
                ext.max_width = std.math.inf(f32);
                needs_remeasure = true;
            }
        } else if (!approxEq(ext.max_width, target_max_width)) {
            const popover_w = ctx.popover.rectFromWorldOrFallback().w;
            const current_within_new_cap = popover_w > 0 and popover_w <= target_max_width + 0.5;
            ext.max_width = target_max_width;
            needs_remeasure = !current_within_new_cap;
        }

        if (needs_remeasure) {
            if (popoverDebugEnabled()) {
                std.debug.print("[popover] pause remeasure match_trigger_width={} preferred_width={any} target_width={any} max_width={d:.1}\n", .{
                    ctx.match_trigger_width,
                    ctx.preferred_width,
                    target_width,
                    ctx.popover.style.max_width(),
                });
            }
            ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
            ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
            ctx.prewarmed_ready = false;
            ctx.popover.markSizingDirty();
            ctx.popover.markSubtreeDirty();
            ctx.cx.needs_redraw = true;
            return;
        }
    }

    // Phase 4: best-fit. popup 必须 "贴 anchor 上方或下方"，且不能超出 cx safe area。
    const pad = ctx.viewport_padding;
    const final_side = floating.getSide(positioned.placement);
    // Resolve final main-axis offset 用 final placement（derivable 时不同 side 不同值）。
    const final_offset_main: f32 = ctx.offset.resolve(.{
        .placement = positioned.placement,
        .reference = floating.Rect.init(trigger_abs_x, trigger_abs_y, tw, th),
        .floating = floating.Rect.init(0, 0, pw, ph),
    });
    var available_h: f32 = vp_h;
    var ph_eff: f32 = ph;
    if (final_side == .top or final_side == .bottom) {
        available_h = if (final_side == .top)
            @max(0, trigger_abs_y - vp_y - pad - final_offset_main)
        else
            @max(0, (vp_y + vp_h) - (trigger_abs_y + th) - pad - final_offset_main);
        // 注：best-fit 不再改 popup_content.style.height —— 改 height 会触发 markSizingDirty
        // → overlay_stack.holdEnterUntilGeometryStable 把 enter transition 冻结在 progress=0
        // → opacity 永远 HIDDEN_OPACITY → popup 不显示。
        // 真正的 best-fit 只调整 ph_eff 让 translate.y 计算正确，**不**触碰 layout。
        // popup_content 自己的 fit{max} 已经 clamp 高度（内容超 max 自然停止撑大）。
        if (ph > available_h and available_h > 48 and ctx.entry_ready) {
            ph_eff = available_h;
        }
    }

    // 用 ph_eff 重算 translate.y（仅 top/bottom side）
    var positioned_y = positioned.y;
    if (final_side == .top) {
        positioned_y = trigger_abs_y - ph_eff - final_offset_main;
    } else if (final_side == .bottom) {
        positioned_y = trigger_abs_y + th + final_offset_main;
    }

    var clamped_x = positioned.x;
    if (clamped_x < vp_x + pad) clamped_x = vp_x + pad;
    if (clamped_x + pw > vp_x + vp_w - pad) clamped_x = @max(vp_x + pad, vp_x + vp_w - pad - pw);

    // translate 是 popover_content 相对 wrapper（它的 parent）的偏移。
    // 旧代码误用 `trigger_abs_x`（= anchor.x），这在 click/hover trigger 场景下巧合 OK
    // （因为 trigger_node 占满 wrapper，wrapper_global ≈ trigger_abs）。
    // 但 VirtualAnchor（光标锚点）场景 anchor 和 wrapper 位置无关，translate 就错了。
    // 正确做法：用 wrapper 的 global 坐标。
    const wrapper_node = ctx.popover.parent orelse {
        ctx.active_position = positioned.placement;
        _ = setPopoverRestTranslate(ctx, clamped_x - trigger_abs_x, positioned_y - trigger_abs_y);
        return;
    };
    const wrapper_rect = wrapper_node.globalRect();
    ctx.active_position = positioned.placement;
    _ = setPopoverRestTranslate(ctx, clamped_x - wrapper_rect.x, positioned_y - wrapper_rect.y);
    if (popoverDebugEnabled()) {
        const popover_rect = ctx.popover.globalRect();
        std.debug.print("[popover-pos] tid={s} wrap=({d:.0},{d:.0},{d:.0}x{d:.0}) pop_rect=({d:.0},{d:.0},{d:.0}x{d:.0}) trans=({d:.0},{d:.0}) anchor=({d:.0},{d:.0},{d:.0}x{d:.0}) op={d:.3} entry_ready={} side={s}\n", .{
            ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
            wrapper_rect.x,
            wrapper_rect.y,
            wrapper_rect.w,
            wrapper_rect.h,
            popover_rect.x,
            popover_rect.y,
            popover_rect.w,
            popover_rect.h,
            ctx.popover.style.translate_x,
            ctx.popover.style.translate_y,
            anchor_rect.x,
            anchor_rect.y,
            anchor_rect.w,
            anchor_rect.h,
            ctx.popover.getOpacity(),
            ctx.entry_ready,
            @tagName(final_side),
        });
    }
    ctx.active_position = positioned.placement;
    syncTransformOriginForPlacement(ctx.popover, ctx.active_position, ctx.cx.allocator);

    if (!ctx.entry_ready) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] enter ready node={d} test_id={s} match_trigger_width={} preferred_width={any} prewarmed={} translate=({d:.1},{d:.1}) size=({d:.1},{d:.1})\n", .{
                ctx.popover.id,
                ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                ctx.match_trigger_width,
                ctx.preferred_width,
                can_use_prewarmed_content,
                ctx.popover.style.translate_x,
                ctx.popover.style.translate_y,
                pw,
                ph,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, false, ctx.cx.allocator);
        // `.none` layers enter the overlay stack directly in `.visible`, so
        // there is no TransitionController tick to restore the opacity that
        // commitExit set to zero. Once geometry is ready, make the content
        // atomically visible here. Animated transitions keep ownership of
        // opacity in the overlay controller.
        if (ctx.enter_transition == .none and ctx.popover.getOpacity() != 1) {
            ctx.popover.setOpacityRaw(1);
            ctx.popover.markCompositeAnimFrameDirty();
            ctx.popover.markRenderDirty();
            ctx.cx.needs_redraw = true;
        }
        ctx.entry_ready = true;
        ctx.prewarmed_ready = false;
        ctx.is_visible = true;
    }
}

// ========== Flip 定位算法（参考 floating-ui/flip） ==========

pub fn computeOverflow(
    pos: PopoverPosition,
    trig_x: f32,
    trig_y: f32,
    tw: f32,
    th: f32,
    pw: f32,
    ph: f32,
    off: f32,
    vp_w: f32,
    vp_h: f32,
) [4]f32 {
    const overflow = floating.computeOverflow(
        pos,
        floating.Rect.init(trig_x, trig_y, tw, th),
        floating.Rect.init(0, 0, pw, ph),
        floating.Rect.init(0, 0, vp_w, vp_h),
        off,
        0,
    );
    return .{ overflow.top, overflow.right, overflow.bottom, overflow.left };
}

pub fn flipPlacement(
    preferred: PopoverPosition,
    trig_x: f32,
    trig_y: f32,
    tw: f32,
    th: f32,
    pw: f32,
    ph: f32,
    off: f32,
    vp_w: f32,
    vp_h: f32,
) PopoverPosition {
    return floating.flipPlacement(
        preferred,
        floating.Rect.init(trig_x, trig_y, tw, th),
        floating.Rect.init(0, 0, pw, ph),
        floating.Rect.init(0, 0, vp_w, vp_h),
        off,
        0,
    );
}

// 析出的单测（tests.zig，原 popover_test.zig）。必须显式 import：
// refAllDecls 不会自动发现无人引用的测试文件，漏了这行等于静默失去 18 个测试。
test {
    _ = @import("tests.zig");
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

test "Popover: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("popover", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Popover(.{}).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
