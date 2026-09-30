/// VirtualList Component
///
/// 虚拟滚动列表组件 — 只渲染可见区域的 item 节点（+ overscan 缓冲），
/// 用 N 个实际节点高效呈现 3 万+ 条数据。
///
/// 设计思路（综合 react-window / Flutter ListView.builder / floating-ui）：
/// 1. 固定行高模式: O(1) 定位，极致性能
/// 2. 节点池复用: 滚出视口的节点回收入池，新进入的 item 从池取节点并更新
/// 3. 与 ScrollArea 集成: 复用 Apple 级滚动物理（橡皮筋/弹簧/惯性）
/// 4. 保留模式 mount() API: Scope 管理所有状态生命周期
///
/// 用法:
/// ```zig
/// const vl = try VirtualList(.{
///     .item_count = 30000,
///     .item_height = 32,
///     .width = 300,
///     .height = 400,
/// }).mount(scope, cx, struct {
///     fn render(node: *Node, index: usize, cx_ptr: *Cx) void {
///         // 设置 item 节点内容
///         node.text = .{ .content = "..." };
///     }
/// }.render);
/// try parent.appendChild(cx.allocator, vl.container);
///
/// // 动态更新 item 数量:
/// virtual_list.updateItemCount(vl.state, 50000);
///
/// // 滚动到指定位置:
/// virtual_list.scrollToIndex(vl.state, 500);
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const scroll_area = @import("../scroll_area/mod.zig");
const ScrollState = scroll_area.ScrollState;
const ScrollDirection = scroll_area.ScrollDirection;
const Scope = @import("../../reactive.zig").Scope;
pub const measurements = @import("measurements.zig");
pub const Measurements = measurements.Measurements;
pub const ItemKey = measurements.ItemKey;

/// VirtualList 属性
pub const VirtualListProps = struct {
    /// 总 item 数量
    item_count: usize = 0,
    /// 每个 item 的固定高度（px）
    item_height: f32 = 32,
    /// 容器宽度
    width: ?f32 = null,
    /// 容器高度
    height: ?f32 = null,
    /// 视口外额外渲染的行数（上下各 overscan 行）
    overscan: usize = 5,
    /// 内边距
    padding: Padding = Padding.ZERO,
    /// 容器背景色
    background: Color = Color.TRANSPARENT,
    /// 滚动速度乘数
    scroll_speed: f32 = 1,
    /// 滚动方向（默认纵向）
    scroll_direction: ScrollDirection = .vertical,
    /// 内容宽度（用于横向滚动，null=由布局自动决定）
    content_width: ?f32 = null,
    /// 可选：按 item 返回高度（px）。给了它就进入**不等高模式**。
    ///
    /// null（默认）→ 所有 item 用 `item_height`，与以前完全一致。
    /// 非 null → 总高、可见范围、spacer、ensureVisible 全部改走前缀和。
    /// 回调必须是纯函数且对同一 index 稳定：它每帧会被调用若干次，返回值
    /// 若在同一帧内变化，滚动几何会自相矛盾。
    item_height_fn: ?*const fn (index: usize, user_context: ?*anyopaque) f32 = null,
    /// 传给 `item_height_fn` 的上下文（通常与 render 的 user_context 同一个）。
    item_height_context: ?*anyopaque = null,

    /// **动态测量模式**：行高由内容自己决定，组件量出来再记账。
    ///
    /// 三种高度模式的取舍：
    /// - 默认（都不设）→ 等高，`item_height`，O(1) 定位，最快。
    /// - `item_height_fn` → 不等高但**高度可预先算出**（如 diff 行：代码行 20、
    ///   hunk 头 28）。不需要测量，几何一次到位。
    /// - `measure_items = true` → 不等高且**高度事先不知道**（如自动换行的
    ///   评论、聊天气泡）。行先按 `estimate_item_height` 占位，布局后读回真实
    ///   高度并回填，同时补偿滚动位置。
    ///
    /// 同时设了 `item_height_fn` 时以 `item_height_fn` 为准（它更便宜且精确）。
    measure_items: bool = false,
    /// 未测量行的占位高度。估得越准，滚动条抖动越小。
    estimate_item_height: f32 = 32,
    /// 可选：index → 稳定 key。给了它，实测高度就跟着**数据**走而不是跟着
    /// 位置走 —— 在头部插入一条时，后面所有行的实测值依然有效。
    /// null = 用 index 本身（头部增删会让后续行重新测量）。
    item_key_fn: ?*const fn (index: usize, user_context: ?*anyopaque) measurements.ItemKey = null,
    /// 传给 `item_key_fn` 的上下文（null 时复用 render 的 user_context）。
    item_key_context: ?*anyopaque = null,
};

/// item 渲染回调: 用户通过此函数填充 item 节点的内容
/// - node: 预分配的 item 容器节点（已设置好尺寸），用户设置 text/background/children 等
/// - index: 当前 item 在数据源中的索引 [0, item_count)
/// - cx: UI 上下文
pub const RenderItemFn = *const fn (node: *Node, index: usize, cx: *Cx) void;
pub const RenderItemWithContextFn = *const fn (node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void;

/// VirtualList 内部状态（通过 Scope 管理生命周期）
pub const VirtualListState = struct {
    props: VirtualListProps,
    render_fn: RenderItemFn,
    render_with_context_fn: ?RenderItemWithContextFn = null,
    render_user_context: ?*anyopaque = null,
    cx: *Cx,

    /// ScrollArea 的滚动状态指针
    scroll_state: *ScrollState,

    /// 内容容器（ScrollArea 的 content 节点）
    content_node: *Node,
    /// 撑高用的 spacer 节点（top spacer，推动可见 item 到正确位置）
    top_spacer: *Node,
    /// 底部 spacer（撑满剩余高度，使滚动条正确）
    bottom_spacer: *Node,

    /// 节点池: 固定数量的 item 节点
    pool_nodes: []*Node,
    pool_size: usize,
    /// 每个池节点当前绑定的 data index（null = 空闲/隐藏）
    pool_bindings: []?usize,

    /// 上一帧可见范围
    prev_start: usize = 0,
    prev_end: usize = 0,
    /// 是否已初始化首次渲染
    initialized: bool = false,
    /// 上一趟完整 rebind 有没有做完。growPool 失败、可见行拿不到 slot、
    /// reorderPoolNodes 失败三种情况都是"这一帧先降级、下一帧重试"，但 updateVisibleItems
    /// 的提前返回只看 prev_start/prev_end —— 范围不变就永远不会重试，缺的行和错的
    /// 顺序会一直停到用户滚动为止。置位后下一帧强制走完整趟。
    rebind_incomplete: bool = false,
    /// 渲染回调是 void，失败只能 `catch return`——半截行没人重画（GLM 指出）。
    /// 回调在失败点调 `markPoolNodeRenderIncomplete(node)`：该 slot 当场解绑（子树清掉），
    /// 本趟标 incomplete，下一帧 updateVisibleItems 为同一 data index 重新取 slot 再调回调。
    /// 与 rebind_incomplete 分开记，因为 updateVisibleItems 末尾会用本趟结果覆盖 rebind_incomplete。
    render_retry_pending: bool = false,
    /// 回调持续失败时的重试退避（GLM 交叉审查）：不封顶次数、只拉大间隔。
    /// 否则一行持续 OOM 会让整个 VL 每帧丢掉等范围早退、每帧全趟 + markLayoutDirty，
    /// 帧循环永远停不下来。streak 连续失败趟数，wait 还要跳过几趟才重试（1,3,7,15,31,60）。
    render_retry_streak: u8 = 0,
    render_retry_wait: u16 = 0,

    /// 动态测量模式的几何账本（measure_items = false 时恒为 null）。
    measured: ?*Measurements = null,
    /// 上一帧的 scroll_y —— 用来判定滚动方向，喂给复测锚定判据。
    prev_scroll_y: f32 = 0,
    scroll_direction: measurements.ScrollDirection = .idle,

    allocator: Allocator,

    /// 是否处于动态测量模式。
    /// 是否持有几何账本（前缀和 + 二分）。
    /// `measure_items` 与 `item_height_fn` 两种不等高模式都持有。
    pub inline fn hasLedger(self: *const VirtualListState) bool {
        return self.measured != null;
    }

    /// 是否处于**回填测量**模式：行高事先不知道，靠布局量出来再记账。
    ///
    /// 与 `hasLedger` 的区别很重要：`item_height_fn` 也有账本，但它的高度是
    /// 调用方给定的权威值，既不测量也不回填。把两者混为一谈会让
    /// `item_height_fn` 的行被实测值覆盖，几何随即与调用方的契约打架。
    pub inline fn isMeasured(self: *const VirtualListState) bool {
        return self.measured != null and self.props.measure_items and
            self.props.item_height_fn == null;
    }

    /// 第 `index` 项的高度。等高模式下恒为 `item_height`。
    pub fn itemHeight(self: *const VirtualListState, index: usize) f32 {
        if (self.measured) |m| {
            // sizeOf 只读 sizes/estimate，不碰前缀和，因此可以在 const 语境用。
            return m.sizeOf(index);
        }
        const f = self.props.item_height_fn orelse return self.props.item_height;
        const h = f(index, self.props.item_height_context);
        // 高度必须为正且有限：0 或 NaN 会让"第几项"的除法退化成无穷循环。
        return if (std.math.isFinite(h) and h > 0) h else self.props.item_height;
    }

    /// [0, index) 这些项的高度之和 —— 即第 index 项的顶端 y。
    pub fn offsetOf(self: *const VirtualListState, index: usize) f32 {
        if (self.measured) |m| {
            // 前缀和是缓存，读它需要可变引用；这里的 const 是"逻辑只读"。
            return @constCast(m).offsetOf(index);
        }
        // 无账本 = 等高模式。
        return @as(f32, @floatFromInt(index)) * self.props.item_height;
    }

    pub fn totalContentHeight(self: *const VirtualListState) f32 {
        if (self.measured) |m| {
            return @constCast(m).totalHeight();
        }
        return @as(f32, @floatFromInt(self.props.item_count)) * self.props.item_height;
    }

    fn normalizedViewportHeight(self: *const VirtualListState) f32 {
        var vh = self.scroll_state.viewport_height;
        if (!std.math.isFinite(vh) or vh < 0) vh = 0;
        return vh;
    }

    /// 逻辑滚动位置（不含 rubber-band bonus），用于虚拟化索引计算。
    /// 这样可避免 overscroll 动画把可见范围推到错误索引导致“列表空白”。
    fn normalizedLogicalScrollY(self: *const VirtualListState) f32 {
        const count = self.props.item_count;
        const ih = self.props.item_height;
        if (count == 0 or ih <= 0) return 0;

        const vh = self.normalizedViewportHeight();
        const total_h = self.totalContentHeight();
        const max_scroll = @max(@as(f32, 0), total_h - vh);

        var scroll_y = self.scroll_state.scroll_y;
        if (!std.math.isFinite(scroll_y) or scroll_y < 0) scroll_y = 0;
        if (scroll_y > max_scroll) scroll_y = max_scroll;
        return scroll_y;
    }

    /// 根据 scroll_y 计算可见 item 范围 [start, end)
    pub fn visibleRange(self: *const VirtualListState) struct { start: usize, end: usize } {
        const scroll_y = self.normalizedLogicalScrollY();
        const vh = self.normalizedViewportHeight();
        const ih = self.props.item_height;
        const count = self.props.item_count;
        const overscan = self.props.overscan;

        if (count == 0 or ih <= 0) return .{ .start = 0, .end = 0 };
        if (vh <= 0) {
            return .{ .start = 0, .end = @min(count, overscan + 1) };
        }

        // 动态测量：前缀和已缓存，用二分定位首项、前向扫描收尾（O(log n + 可见行数)）。
        if (self.measured) |m| {
            const r = @constCast(m).range(scroll_y, vh);
            return .{
                .start = r.start -| overscan,
                .end = @min(count, r.end + overscan),
            };
        }

        // 到这里只剩等高模式：两种不等高模式都持有账本，已在上面返回。

        // 视口起始 item（向下取整）
        const raw_start_unclamped: usize = if (scroll_y <= 0) 0 else @intFromFloat(@floor(scroll_y / ih));
        const raw_start: usize = @min(raw_start_unclamped, count - 1);
        const start = if (raw_start > overscan) raw_start - overscan else 0;

        // 视口结束 item（向上取整 + overscan）
        const raw_end_f = (scroll_y + vh) / ih;
        const raw_end: usize = if (raw_end_f <= 0) 0 else @min(count, @as(usize, @intFromFloat(@ceil(raw_end_f))));
        var end = @min(count, raw_end + overscan);
        if (end <= start) end = @min(count, start + 1);

        return .{ .start = start, .end = end };
    }

    /// 核心: 每帧更新可见 item
    pub fn updateVisibleItems(self: *VirtualListState) void {
        // 动态测量模式：先把**上一次布局**量到的真实行高回填进账本，再算几何。
        // 顺序很关键 —— 必须在 totalContentHeight() 之前，否则这一帧用的还是
        // 旧高度，spacer 与内容对不上，滚动会漂。
        self.collectMeasurements();

        // VirtualList 自主管理内容高度，避免被外层 ScrollArea 误覆盖后出现索引/位移失配。
        const total_h = self.totalContentHeight();
        self.scroll_state.external_content_height = true;
        if (self.scroll_state.content_height != total_h) {
            self.scroll_state.content_height = total_h;
        }
        const height_needs_update = switch (self.content_node.style.height) {
            .px => |v| v != total_h,
            else => true,
        };
        if (height_needs_update) {
            self.content_node.style.height = .{ .px = total_h };
            self.content_node.markLayoutDirty();
        }

        // 先校正逻辑 scroll_y，避免内容高度变化后索引越界。
        const normalized_scroll_y = self.normalizedLogicalScrollY();
        if (normalized_scroll_y != self.scroll_state.scroll_y) {
            self.scroll_state.scroll_y = normalized_scroll_y;
            self.scroll_state.bonus_y = 0;
            self.scroll_state.bonus_velocity = 0;
        }

        // 保留 rubber-band 动效，但限制 VirtualList 的越界位移幅度，避免整屏空白。
        const vh = self.normalizedViewportHeight();
        if (vh > 0 and std.math.isFinite(self.scroll_state.bonus_y)) {
            const max_bonus = vh * 0.45;
            if (self.scroll_state.bonus_y > max_bonus) {
                self.scroll_state.bonus_y = max_bonus;
                self.scroll_state.bonus_velocity = 0;
            } else if (self.scroll_state.bonus_y < -max_bonus) {
                self.scroll_state.bonus_y = -max_bonus;
                self.scroll_state.bonus_velocity = 0;
            }
        }

        // 强制同步内容位移（带非有限值兜底），确保虚拟列表索引与可视位置一致。
        var effective_y = self.scroll_state.effectiveScrollY();
        if (!std.math.isFinite(effective_y)) {
            self.scroll_state.bonus_y = 0;
            self.scroll_state.bonus_velocity = 0;
            effective_y = self.scroll_state.scroll_y;
        }
        // 与 scroll 事件层一致地量化到物理像素网格，否则每帧覆盖成
        // 亚像素 translate 会在 Retina 上造成文字抖动/发糊。
        const desired_translate_y = -self.scroll_state.snapToPixel(effective_y);
        if (self.content_node.style.translate_y != desired_translate_y) {
            self.content_node.style.translate_y = desired_translate_y;
            self.content_node.markCompositePropDirty();
        }

        const range = self.visibleRange();
        const start = range.start;
        const end = range.end;
        const ih = self.props.item_height;

        // 更新 spacer 高度。不等高/测量模式走前缀和，否则 spacer 撑起的空间和
        // 内容实际占的空间对不上，滚动位置会漂移。
        const variable_geometry = self.hasLedger();
        const top_h = if (variable_geometry)
            self.offsetOf(start)
        else
            @as(f32, @floatFromInt(start)) * ih;
        const bottom_h = if (variable_geometry)
            @max(@as(f32, 0), self.totalContentHeight() - self.offsetOf(end))
        else
            @as(f32, @floatFromInt(self.props.item_count -| end)) * ih;
        const spacers_changed = !styleHeightEq(self.top_spacer, top_h) or
            !styleHeightEq(self.bottom_spacer, bottom_h);
        self.top_spacer.style.height = .{ .px = top_h };
        self.bottom_spacer.style.height = .{ .px = bottom_h };

        // 回调重试退避：本趟只是在等（范围没变）就不做完整趟；范围变了照常全趟（顺带重试）
        const retry_waiting = self.rebind_incomplete and self.render_retry_wait > 0 and
            start == self.prev_start and end == self.prev_end and self.initialized;
        if (retry_waiting) self.render_retry_wait -= 1;
        if (start == self.prev_start and end == self.prev_end and self.initialized and (!self.rebind_incomplete or retry_waiting)) {
            // 可见范围没变 —— 等高/预知高度模式下这就完事了。
            // 但**测量模式**下还有一件事必须做：刚量到真高的行要把 .fit 钉成 px，
            // 且 spacer 变了就得重新布局。漏了这一步，行会一直停在 .fit 态，
            // 账本与实际渲染各算各的，滚动就开始漂。
            if (self.pinMeasuredHeights() or spacers_changed) self.content_node.markLayoutDirty();
            return;
        }

        // 走到这里就是完整趟：refreshRange 路径留下的"待重试"记号已经兑现（它靠 rebind_incomplete
        // 把这一趟逼出来），先清掉；本趟回调再报失败会重新置位，趟末合并进 rebind_incomplete。
        self.render_retry_pending = false;

        // 动态扩展 pool: viewport 可能通过 grow 布局变得比 mount 时估算的更大
        const needed = end - start;
        var incomplete = false;
        if (needed > self.pool_size) {
            // 可安全降级：growPool 是事务性的（内部 errdefer 回滚全部半成品分配，
            // 失败后 pool_size / pool_nodes / pool_bindings 保持扩容前的自洽状态）。
            // 扩不了池只意味着这一帧可见行渲染得少些——下面 `findFreeSlot() orelse
            // continue` 处理取不到 slot 的情况。**下一帧重试**靠 rebind_incomplete：
            // 池还能长（没到 max_pool_size）却没长够，就标记本趟不完整。
            self.growPool(needed) catch {};
            if (needed > self.pool_size and self.pool_size < max_pool_size) incomplete = true;
        }

        // 回收不再可见的节点
        for (self.pool_bindings, 0..) |binding, i| {
            if (binding) |idx| {
                if (idx < start or idx >= end) self.recycleSlot(i);
            }
        }

        // 渲染新进入可见范围的 item
        var item_idx = start;
        while (item_idx < end) : (item_idx += 1) {
            // 检查是否已有节点绑定此 index
            if (self.isBound(item_idx)) continue;

            // 从池中取空闲节点；拿不到就是池短了，下一帧重试（见 rebind_incomplete）。
            const slot = self.findFreeSlot() orelse {
                if (self.pool_size < max_pool_size) incomplete = true;
                continue;
            };
            self.pool_bindings[slot] = item_idx;
            const node = self.pool_nodes[slot];
            // 不等高时每个 slot 用自己那一项的高度；等高时就是 ih。
            // 测量模式下未测过的行走 .fit，让内容把它撑开。
            self.applySlotHeight(node, item_idx);
            node.style.overflow_hidden = false;
            self.clearSlotNode(node);
            // 绑定到真实数据行 → 进 a11y 树。label 留空走子树文本 fallback，
            // 因为行内容完全由用户的 render_fn 决定，组件侧拿不到文本。
            node.behavior.interaction.a11y = .{ .role = .listitem };
            // 调用用户渲染函数填充内容
            if (self.render_with_context_fn) |render_with_context| {
                render_with_context(node, item_idx, self.cx, self.render_user_context);
            } else {
                self.render_fn(node, item_idx, self.cx);
            }
        }

        // 已绑定的行同样要钉高：rebind_incomplete 让完整趟连着跑好几帧时，
        // 钉高不能跟着被推迟（交叉审查指出的"持续 incomplete 时钉合无限延后"）。
        _ = self.pinMeasuredHeights();

        // 按 data index 重排 pool 节点在 content 中的位置。失败（OOM）时顺序是旧的：
        // 新扩出来的 slot 排在 bottom_spacer 之后、可见行彼此错位，必须下一帧重做。
        if (!self.reorderPoolNodes()) incomplete = true;

        self.prev_start = start;
        self.prev_end = end;
        self.initialized = true;
        // 本趟回调里有 slot 报了"没画完"→ 之后强制再走完整趟（该 index 已解绑，会重新取 slot 重画），
        // 间隔按连续失败趟数退避：1,3,7,15,31,60 帧
        self.rebind_incomplete = incomplete or self.render_retry_pending;
        if (self.render_retry_pending) {
            self.render_retry_streak = @min(self.render_retry_streak + 1, 6);
            const wait: u16 = (@as(u16, 1) << @intCast(self.render_retry_streak)) - 1;
            self.render_retry_wait = @min(wait, 60);
        } else {
            self.render_retry_streak = 0;
            self.render_retry_wait = 0;
        }
        self.render_retry_pending = false;

        self.content_node.markLayoutDirty();
    }

    /// 解绑一个 slot：隐藏、清子树、退出 a11y 树。回收滚出视口的行与回调报失败的行共用。
    fn recycleSlot(self: *VirtualListState, slot: usize) void {
        const node = self.pool_nodes[slot];
        node.style.height = .{ .px = 0 };
        node.style.overflow_hidden = true;
        // slot-level 容器仍会复用，但 item-level 子树和 identity
        // 必须在 unbind 时清掉，否则隐藏 slot 会继续暴露旧 children/test_id。
        self.clearSlotNode(node);
        node.meta.ownership.meta.test_id = null;
        // slot 解绑后必须退出 a11y 树（a11y=null + 不可 focus 时
        // 投影层直接丢弃）。否则被回收的隐藏行会继续以 listitem
        // 身份留在树里，AT 读到的是一堆已经滚出视口的旧内容。
        node.behavior.interaction.a11y = null;
        self.pool_bindings[slot] = null;
    }

    /// 渲染回调失败留痕：只接受当前已绑定的 pool node；解绑后本趟标 incomplete。
    fn markSlotRenderIncomplete(self: *VirtualListState, node: *Node) bool {
        for (self.pool_nodes, 0..) |pn, slot| {
            if (pn != node) continue;
            if (self.pool_bindings[slot] == null) return false;
            self.recycleSlot(slot);
            self.render_retry_pending = true;
            self.rebind_incomplete = true;
            self.content_node.markLayoutDirty();
            return true;
        }
        return false;
    }

    /// 测量模式：把已量到真高的已绑定行从 .fit 钉成 px。返回是否有行被钉。
    fn pinMeasuredHeights(self: *VirtualListState) bool {
        if (!self.isMeasured()) return false;
        var pinned_any = false;
        for (self.pool_bindings, 0..) |binding, slot| {
            const idx = binding orelse continue;
            const node = self.pool_nodes[slot];
            const want = self.measured.?.sizeOf(idx);
            if (self.measured.?.hasMeasurement(idx) and !styleHeightEq(node, want)) {
                node.style.height = .{ .px = want };
                pinned_any = true;
            }
        }
        return pinned_any;
    }

    /// 动态测量：把上一次布局量到的真实行高读回账本。
    ///
    /// 时序说明（这是整个特性能成立的前提）：框架每帧是
    /// `layout → tick(before_render hooks) → 若 hook 标脏则再 layout`。
    /// 本函数在 hook 里跑，所以读到的 rect 来自本帧**第一次** layout —— 也就是
    /// slot 以 `.fit` 撑开后的真实内容高度。回填后我们标脏，同帧第二次 layout
    /// 就会用修正后的几何出图，因此不会有"先错一帧再跳一下"的闪烁。
    fn collectMeasurements(self: *VirtualListState) void {
        // `item_height_fn` 模式也持有账本（为了前缀和缓存与二分），但它的高度
        // 是**调用方给定的权威值**，不能被布局实测覆盖。
        if (!self.isMeasured()) return;
        const m = self.measured orelse return;

        // 滚动方向：复测判据要用（向上滚时抑制补偿，避免连锁位移）。
        const cur_y = self.scroll_state.scroll_y;
        if (cur_y > self.prev_scroll_y + 0.01) {
            self.scroll_direction = .forward;
        } else if (cur_y < self.prev_scroll_y - 0.01) {
            self.scroll_direction = .backward;
        }
        self.prev_scroll_y = cur_y;

        var total_adjust: f32 = 0;
        for (self.pool_bindings, 0..) |binding, slot| {
            const idx = binding orelse continue;
            const node = self.pool_nodes[slot];
            const h = node.rectFromWorldOrFallback().h;
            // h <= 0 = 这一行还没被 layout 过（本帧刚绑定）。别把它当成"量到 0"
            // 写进账本，否则该行会被永久钉成 0 高且再也不会重测。
            if (!(h > 0)) continue;

            const out = m.applyMeasurement(idx, h, cur_y, self.scroll_direction);
            total_adjust += out.scroll_adjustment;
        }

        if (total_adjust != 0) {
            // 补偿必须与本帧的几何重建**原子**发生：scroll_y 和前缀和在同一帧
            // 内一起更新，用户看到的永远是自洽的一帧。
            const max_scroll = @max(@as(f32, 0), m.totalHeight() - self.normalizedViewportHeight());
            const adjusted = std.math.clamp(cur_y + total_adjust, 0, max_scroll);
            self.scroll_state.scroll_y = adjusted;
            self.prev_scroll_y = adjusted;
            // 补偿是"修正"不是"滚动"：不该留下动量/回弹，否则会被惯性放大。
            self.scroll_state.bonus_y = 0;
            self.scroll_state.bonus_velocity = 0;
        }
        m.consumeAdjustment();
    }

    /// slot 高度：测量模式下让内容自己撑（.fit），量到之后钉成实测值。
    ///
    /// 为什么量到后要钉死而不是一直 .fit：钉成 px 后该行的高度对布局是确定的，
    /// 与前缀和账本严格一致；一直 .fit 的话账本与实际渲染会各算各的，
    /// spacer 撑起的空间和内容实占空间对不上，滚动就漂了。
    fn applySlotHeight(self: *VirtualListState, node: *Node, index: usize) void {
        // 判据必须是 isMeasured 而不是 `measured != null`：`item_height_fn`
        // 模式同样持有账本（为了前缀和与二分），但它从不写 sizes，
        // 于是 hasMeasurement() 恒为 false —— 走 `measured != null` 的话
        // **每一行**都会被打成 .fit，行高改由内容决定，而账本按回调值预留
        // 空间，两者对不上（实测：回调说 40px，实际渲染 10px）。
        if (self.isMeasured()) {
            const m = self.measured.?;
            if (m.hasMeasurement(index)) {
                node.style.height = .{ .px = m.sizeOf(index) };
            } else {
                // 还没量过：让内容自己决定高度，本帧 layout 后就能读到真值。
                node.style.height = .{ .fit = .{} };
            }
            return;
        }
        // 等高 + item_height_fn：高度是已知的权威值，直接钉死。
        node.style.height = .{ .px = self.itemHeight(index) };
    }

    /// 回收 slot 时必须销毁旧子树，避免用户渲染函数仅重置 children.len 导致泄漏。
    fn clearSlotNode(self: *VirtualListState, node: *Node) void {
        while (node.children.items.len > 0) {
            const child = node.children.items[node.children.items.len - 1];
            self.cx.detachChild(node, child);
            self.cx.freeNode(child);
        }
        node.markRuntimeIndexDirty();
    }

    /// 动态扩展 pool 到 new_size（当实际 viewport 大于 mount 时的估算值时触发）
    fn growPool(self: *VirtualListState, new_size: usize) !void {
        const target = @min(max_pool_size, new_size + 2); // 留 2 个余量
        if (target <= self.pool_size) return;
        const old_size = self.pool_size;

        const new_nodes = try self.allocator.alloc(*Node, target);
        errdefer self.allocator.free(new_nodes);
        const new_bindings = try self.allocator.alloc(?usize, target);
        errdefer self.allocator.free(new_bindings);

        // 复制旧 pool
        @memcpy(new_nodes[0..old_size], self.pool_nodes);
        @memcpy(new_bindings[0..old_size], self.pool_bindings);
        @memset(new_bindings[old_size..target], null);

        var created_count: usize = 0;
        errdefer {
            for (0..created_count) |offset| {
                const node = new_nodes[old_size + offset];
                if (node.parent == self.content_node) {
                    self.content_node.removeChildIncremental(node);
                }
                self.cx.invalidateReferencesTo(node);
                node.destroy(self.allocator);
            }
        }

        // 新增的 slot 初始化为空闲隐藏节点
        for (old_size..target) |i| {
            const item_node = try box(self.cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .px = 0 },
                .flex_shrink = 0,
                .overflow_hidden = true,
            }, .{});
            new_nodes[i] = item_node;
            created_count += 1;
            try self.content_node.appendChild(self.allocator, item_node);
        }

        // 释放旧数组
        self.allocator.free(self.pool_nodes);
        self.allocator.free(self.pool_bindings);

        self.pool_nodes = new_nodes;
        self.pool_bindings = new_bindings;
        self.pool_size = target;
    }

    fn isBound(self: *const VirtualListState, data_idx: usize) bool {
        for (self.pool_bindings) |binding| {
            if (binding) |idx| {
                if (idx == data_idx) return true;
            }
        }
        return false;
    }

    fn findFreeSlot(self: *const VirtualListState) ?usize {
        for (self.pool_bindings, 0..) |binding, i| {
            if (binding == null) return i;
        }
        return null;
    }

    /// 按 data index 重排 pool 节点在 content.children 中的顺序
    /// 所有 pool 节点始终在 children 中（隐藏的也是），确保 destroy 时无泄漏
    /// 返回 false 表示顺序没能落下去（分配失败），调用方要安排重试。
    fn reorderPoolNodes(self: *VirtualListState) bool {
        const content = self.content_node;

        // 收集有效绑定的 (data_index, pool_slot) 对
        var active_count: usize = 0;
        var active_pairs: [max_pool_size]IndexSlotPair = undefined;
        for (self.pool_bindings, 0..) |binding, i| {
            if (binding) |idx| {
                if (active_count < max_pool_size) {
                    active_pairs[active_count] = .{ .data_idx = idx, .pool_slot = i };
                    active_count += 1;
                }
            }
        }

        // 按 data_index 排序（insertion sort，数量很少）
        const pairs = active_pairs[0..active_count];
        if (pairs.len > 1) {
            for (1..pairs.len) |i| {
                const key = pairs[i];
                var j: usize = i;
                while (j > 0 and pairs[j - 1].data_idx > key.data_idx) {
                    pairs[j] = pairs[j - 1];
                    j -= 1;
                }
                pairs[j] = key;
            }
        }

        // 重建 children: [top_spacer, active_items_sorted, inactive_items, bottom_spacer]
        // 所有 pool 节点始终在 children 中，确保 content.destroy() 时能递归销毁
        var ordered_nodes = std.ArrayList(*Node){};
        defer ordered_nodes.deinit(self.allocator);
        ordered_nodes.ensureTotalCapacity(self.allocator, self.pool_size + 2) catch return false;
        ordered_nodes.appendAssumeCapacity(self.top_spacer);

        // 先加活跃节点（按 data index 排序）
        var active_set: [max_pool_size]bool = [_]bool{false} ** max_pool_size;
        for (pairs) |pair| {
            ordered_nodes.appendAssumeCapacity(self.pool_nodes[pair.pool_slot]);
            if (pair.pool_slot < max_pool_size) active_set[pair.pool_slot] = true;
        }
        // 再加不活跃节点（高度 0，不影响布局）
        for (0..self.pool_size) |i| {
            if (!active_set[i]) {
                ordered_nodes.appendAssumeCapacity(self.pool_nodes[i]);
            }
        }
        ordered_nodes.appendAssumeCapacity(self.bottom_spacer);
        content.replaceChildOrder(self.allocator, ordered_nodes.items) catch return false;
        return true;
    }
};

const IndexSlotPair = struct {
    data_idx: usize,
    pool_slot: usize,
};

/// 节点当前的 style 高度是否已经是 `want` 像素。
/// `.fit` / `.grow` 一律视为"不等于"，因为它们还没被钉成确定值。
fn styleHeightEq(node: *const Node, want: f32) bool {
    return switch (node.style.height) {
        .px => |v| v == want,
        else => false,
    };
}

pub const max_pool_size = 256;

/// 创建 VirtualList
pub fn VirtualList(props: VirtualListProps) VirtualListBuilder {
    return VirtualListBuilder{ .props = props };
}

pub const VirtualListBuilder = struct {
    props: VirtualListProps,

    pub fn width(self: VirtualListBuilder, w: f32) VirtualListBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn height(self: VirtualListBuilder, h: f32) VirtualListBuilder {
        var new = self;
        new.props.height = h;
        return new;
    }

    pub fn overscan(self: VirtualListBuilder, n: usize) VirtualListBuilder {
        var new = self;
        new.props.overscan = n;
        return new;
    }

    pub fn padding(self: VirtualListBuilder, p: Padding) VirtualListBuilder {
        var new = self;
        new.props.padding = p;
        return new;
    }

    pub fn background(self: VirtualListBuilder, c: Color) VirtualListBuilder {
        var new = self;
        new.props.background = c;
        return new;
    }

    const MountResult = struct { container: *Node, state: *VirtualListState };

    /// 保留模式 mount: 创建 VirtualList 并返回容器节点 + 状态句柄
    ///
    /// render_fn: 用户提供的 item 渲染回调，每次 item 进入可见区域时调用
    pub fn mount(
        self: VirtualListBuilder,
        scope: *Scope,
        cx: *Cx,
        render_fn: RenderItemFn,
    ) !MountResult {
        return self.mountWithContext(scope, cx, null, render_fn, null);
    }

    /// 带上下文的 mount：用于 render 函数需要访问外部状态
    pub fn mountWithContext(
        self: VirtualListBuilder,
        scope: *Scope,
        cx: *Cx,
        user_context: ?*anyopaque,
        render_fn: ?RenderItemFn,
        render_with_context_fn: ?RenderItemWithContextFn,
    ) !MountResult {
        const my_scope = try scope.childScope();
        errdefer my_scope.dispose();
        var resources_owned = false;
        const allocator = cx.allocator;
        const p = self.props;

        // 账本对两种不等高模式都建：
        //   measure_items → 估算占位 + 布局后回填实测
        //   item_height_fn → 高度已知，直接当 estimate_fn 用、永不回填
        // 后者这样做不是为了"测量"，而是白得 Measurements 的**前缀和缓存与
        // 二分**。此前 item_height_fn 走的是每帧 O(n) 线性扫，5000+ 行的
        // diff 滚到深处会卡到 RPC 超时。
        const use_measured = p.measure_items or p.item_height_fn != null;
        const measured: ?*Measurements = if (use_measured) blk: {
            const m = try my_scope.allocator.create(Measurements);
            m.* = Measurements.init(allocator, .{
                .count = p.item_count,
                .estimate = p.estimate_item_height,
                .estimate_fn = p.item_height_fn,
                .estimate_ctx = p.item_height_context,
                .key_fn = p.item_key_fn,
                // key_ctx 未单独给时复用 render 的 user_context，省掉调用方
                // 为同一个上下文传两遍。
                .key_ctx = p.item_key_context orelse user_context,
            });
            break :blk m;
        } else null;
        errdefer if (!resources_owned) {
            if (measured) |m| {
                m.deinit();
                my_scope.allocator.destroy(m);
            }
        };

        // 计算总内容高度。测量模式下先按估算值占位，量到真值后逐步收敛。
        const total_h = if (measured) |m|
            m.totalHeight()
        else
            @as(f32, @floatFromInt(p.item_count)) * p.item_height;

        // 使用 ScrollArea 作为外层容器（复用滚动物理）
        const sa = try scroll_area.mountScrollArea(.{
            .width = p.width,
            .height = p.height,
            .direction = p.scroll_direction,
            .content_height = total_h,
            .content_width = p.content_width,
            .scroll_speed = p.scroll_speed,
            .padding = p.padding,
            .background = p.background,
        }, my_scope, cx);

        errdefer cx.freeNode(sa.container);

        sa.container.meta.ownership.meta.component_name = "VirtualList";
        sa.container.frame_state.state_bits.flags.disable_render_cache = true;
        // role=list：虚拟滚动只在树里放可见的那几行，AT 至少要知道这是一份
        // 列表而不是一段自由文本。
        sa.container.behavior.interaction.a11y = .{ .role = .list };

        // 从 ScrollArea 的 event_context 提取 ScrollState
        const scroll_event_ctx: *scroll_area.ScrollEventCtx = @ptrCast(@alignCast(
            sa.container.behavior.events.event_context.?,
        ));
        const scroll_state_ptr = scroll_event_ctx.state;
        scroll_state_ptr.external_content_height = true;
        sa.content.style.height = .{ .px = total_h };
        sa.content.style.flex_shrink = 0;
        if (p.content_width) |cw| {
            scroll_state_ptr.external_content_width = true;
            sa.content.style.width = .{ .px = cw };
        }

        // 创建 top/bottom spacer
        const top_spacer = try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 0 },
            .flex_shrink = 0,
        }, .{});
        top_spacer.frame_state.state_bits.flags.inspectable = false;
        sa.content.appendChild(allocator, top_spacer) catch |err| {
            cx.freeNode(top_spacer);
            return err;
        };

        const bottom_spacer = try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = total_h },
            .flex_shrink = 0,
        }, .{});
        bottom_spacer.frame_state.state_bits.flags.inspectable = false;
        sa.content.appendChild(allocator, bottom_spacer) catch |err| {
            cx.freeNode(bottom_spacer);
            return err;
        };

        // 计算池大小: viewport 能放多少行 + 2*overscan + 余量。
        // 测量模式按估算行高算 —— 真实行高普遍更小时池会不够，但 growPool
        // 会在首帧按实际需要扩容，这里只求一个合理起点。
        const viewport_h = p.height orelse 400;
        // item_height = 0 / 负 / NaN 时除出 inf，@intFromFloat 直接 panic：两条分支同样钳到 >= 1。
        const row_h_guess = if (use_measured)
            @max(@as(f32, 1), p.estimate_item_height)
        else
            @max(@as(f32, 1), p.item_height);
        const rows_f = @ceil(viewport_h / row_h_guess);
        const rows_in_viewport: usize = if (std.math.isFinite(rows_f) and rows_f > 0)
            @intFromFloat(@min(rows_f, @as(f32, @floatFromInt(max_pool_size))))
        else
            1;
        const pool_size = @min(max_pool_size, rows_in_viewport + 2 * p.overscan + 2);

        // 分配节点池
        const pool_nodes = try allocator.alloc(*Node, pool_size);
        errdefer if (!resources_owned) allocator.free(pool_nodes);
        const pool_bindings = try allocator.alloc(?usize, pool_size);
        errdefer if (!resources_owned) allocator.free(pool_bindings);
        @memset(pool_bindings, null);

        // 预创建 pool 中的 item 节点（初始隐藏，加入 content 确保 parent 正确 + 销毁时无泄漏）
        for (0..pool_size) |i| {
            const item_node = try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .px = 0 },
                .flex_shrink = 0,
                .overflow_hidden = true,
            }, .{});
            pool_nodes[i] = item_node;
            sa.content.appendChild(allocator, item_node) catch |err| {
                cx.freeNode(item_node);
                return err;
            };
        }

        // 分配 VirtualListState（通过 Scope 管理生命周期）
        const state = try my_scope.allocator.create(VirtualListState);
        errdefer if (!resources_owned) my_scope.allocator.destroy(state);
        state.* = .{
            .props = p,
            .render_fn = render_fn orelse noopRenderItem,
            .render_with_context_fn = render_with_context_fn,
            .render_user_context = user_context,
            .cx = cx,
            .scroll_state = scroll_state_ptr,
            .content_node = sa.content,
            .top_spacer = top_spacer,
            .bottom_spacer = bottom_spacer,
            .pool_nodes = pool_nodes,
            .pool_size = pool_size,
            .pool_bindings = pool_bindings,
            .measured = measured,
            .allocator = allocator,
        };
        try my_scope.registerResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const s: *VirtualListState = @ptrCast(@alignCast(ptr));
                // 测量账本持有自己的 HashMap 与前缀和数组，必须先 deinit
                // 再 destroy，否则泄漏（它们用的是 cx.allocator，不随 scope 走）。
                if (s.measured) |m| {
                    m.deinit();
                    alloc.destroy(m);
                }
                s.allocator.free(s.pool_nodes);
                s.allocator.free(s.pool_bindings);
                alloc.destroy(s);
            }
        }.destroy);

        resources_owned = true;

        // Retire the whole list scope when its container is freed, including
        // the nested ScrollArea scope. No fallible work follows this binding.
        try core.bindScopeToNode(my_scope, sa.container);

        // 使用 content.hooks.slots.anim_state 存储 VirtualListState 指针
        // （content 节点不使用动画功能，该字段安全可用）。
        // 必须在初始渲染**之前**挂上——回调在首趟里就可能要经
        // markPoolNodeRenderIncomplete(node) 沿 parent 反查 state。
        sa.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
        // 在 content 节点的 on_before_render 中每帧更新可见 item（hook 只在帧 tick 里跑，
        // 提前挂上无副作用；markPoolNodeRenderIncomplete 用它做"确实是 VL content"的身份校验）
        sa.content.meta.per_frame.hooks.before_render.main = vlBeforeRender;

        // 初始渲染可见 item
        state.updateVisibleItems();

        return .{ .container = sa.container, .state = state };
    }
};

fn noopRenderItem(_: *Node, _: usize, _: *Cx) void {}

/// content 节点的 on_before_render 回调
fn vlBeforeRender(content_node: *Node) void {
    if (content_node.meta.per_frame.hooks.slots.anim_state) |ptr| {
        const state: *VirtualListState = @ptrCast(@alignCast(ptr));
        state.updateVisibleItems();
    }
}

/// 更新 item_count（数据源变化时调用）
pub fn updateItemCount(state: *VirtualListState, new_count: usize) void {
    state.props.item_count = new_count;
    // 测量账本同步行数。注意 setCount **不清实测值** —— 它们是 key 域的，
    // 行数变了旧 key 的高度依然有效（给了 item_key_fn 时尤其重要：
    // 头部插入一条不会让后面所有行重新测量）。
    if (state.measured) |m| {
        m.setCount(new_count);
        // `setCount` 见到行数没变会早退，于是 pending_min 不动、前缀和保持陈旧。
        // 但本函数的契约是"数据源变化时调用" —— 数据换了而**行数恰好相同**
        // 是很常见的（diff 换一个同行数的文件、切 inline/side-by-side），此时
        // `item_height_fn` 的返回值多半也变了。不无条件标脏的话，
        // `itemHeight()` 读实时回调、`offsetOf()` 读旧缓存，几何自相矛盾
        // （实测：itemHeight=100 而 offsetOf(1) 仍是 40，行重叠 + 滚动条短 2.5 倍）。
        m.markAllDirty();
    }
    syncContentHeight(state);
    // 重置: 强制下帧重新计算
    state.prev_start = 0;
    state.prev_end = 0;
    state.initialized = false;
    // 回收所有节点 —— 关键：**也要清 children**，否则 caller 依赖 item 外部状态
    // （例如 completion popup 里的 item.label 字符串）被改/被释放后，pool node 上旧
    // children 的 text.content 会 dangling → 下次 layout/hit test 时 crash。
    for (state.pool_bindings, 0..) |_, i| {
        state.pool_bindings[i] = null;
        state.clearSlotNode(state.pool_nodes[i]);
        state.pool_nodes[i].style.height = .{ .px = 0 };
        state.pool_nodes[i].style.overflow_hidden = true;
    }
    state.content_node.markLayoutDirty();
}

/// 滚动到指定 index（item 顶部对齐视口顶部）
pub fn scrollToIndex(state: *VirtualListState, index: usize) void {
    const target_y = state.offsetOf(index);
    // 统一走 scroll_area 的程序化滚动入口：clamp + 动量/回弹复位 + 像素对齐
    // （此前这里手写、且漏了 snapToPixel 与 bounce 取消）
    scroll_area.setScrollY(state.scroll_state, state.content_node, target_y);
}

/// 把第 index 项按指定对齐方式滚进视野（scroll_area.ScrollAlign 语义一致）。
pub fn scrollIndexIntoView(
    state: *VirtualListState,
    index: usize,
    alignment: scroll_area.ScrollAlign,
) void {
    const top = state.offsetOf(index);
    const ih = state.itemHeight(index);
    scroll_area.scrollRectIntoView(state.scroll_state, state.content_node, top, ih, alignment);
}

/// `item_height_fn` 的返回值变了之后调用，让几何跟上。
///
/// 为什么需要显式调用：账本会**缓存**前缀和，而回调不会 —— 调用方什么时候
/// 改了返回值（展开折叠块、切 side-by-side/inline、改字号），账本无从得知。
/// 不调用的话 `itemHeight()` 读实时回调、`offsetOf()` / `totalContentHeight()`
/// 读陈旧缓存，同一份几何自相矛盾，表现为行与行之间出现空洞或重叠。
///
/// 只作废派生的前缀和，不碰实测值，因此在 `measure_items` 模式下调用也是
/// 安全的（那里通常不需要 —— 实测回填自己会标脏）。
pub fn invalidateHeights(state: *VirtualListState) void {
    const m = state.measured orelse return;
    m.markAllDirty();
    // 已绑定的 slot 此前被钉成**旧**高度，必须一起更新，否则账本已经改了、
    // 行还按老高度画。等高模式不受影响（它压根不钉 px）。
    for (state.pool_bindings, 0..) |binding, slot| {
        const idx = binding orelse continue;
        state.applySlotHeight(state.pool_nodes[slot], idx);
        state.pool_nodes[slot].markLayoutDirty();
    }
    // 这里**不需要**重置 prev_start/prev_end/initialized。
    // 直觉上"行高变了、一屏能放的行数也变了，得强制下帧重算"，但
    // `visibleRange()` 每帧都是从账本现算的，`updateVisibleItems` 的提前返回
    // 拿新算出的范围和 prev 比 —— 范围真变了就不会命中提前返回。
    // 实测（100px→40px、100 行）：不重置也照样从 [0,2) 扩到 [0,5) 并绑满 5 行。
    // 留着是三行永远不生效的死代码，反而误导人以为这里有状态要维护。
    syncContentHeight(state);
}

/// 总高变化后必须同步的三件事：滚动状态的 content_height、content 节点的
/// style 高度、以及把越界的 scroll_y 钳回来。
///
/// 抽出来是因为**漏掉它的后果不可逆**：`scrollToIndex` / `ensureVisible` 走
/// `scroll_area` 的 clamp，钳的是 `maxScrollY()`，而它派生自 `content_height`。
/// 总高涨了但 content_height 还是旧的 → 目标位置被钳到旧的 max，下一帧
/// `updateVisibleItems` 虽然会修好 content_height，但**请求的位置已经丢了**，
/// 列表就停在错误的行上不动了（实测：想去第 90 行，落在第 38 行）。
///
/// `updateItemCount` 与 `invalidateHeights` 都改总高，共用这一份逻辑，
/// 免得将来只有一边被改。
fn syncContentHeight(state: *VirtualListState) void {
    const total_h = state.totalContentHeight();
    state.scroll_state.content_height = total_h;
    state.content_node.style.height = .{ .px = total_h };
    const max_scroll = state.scroll_state.maxScrollY();
    if (state.scroll_state.scroll_y > max_scroll) {
        state.scroll_state.scroll_y = max_scroll;
    }
    state.content_node.markLayoutDirty();
}

/// 作废第 index 行的实测高度，使其在下一帧重新测量。
///
/// 内容变高/变矮（文本改了、展开了详情）时必须调用，否则该行会一直沿用
/// 旧的实测值 —— 账本与实际内容对不上，后面所有行的位置都会偏。
/// `refreshRange` 已经内置调用它，只有绕开 refreshRange 直接改内容时才需手调。
pub fn invalidateMeasurement(state: *VirtualListState, index: usize) void {
    // 判据必须是 isMeasured 而不是 `measured != null`：`item_height_fn` 模式
    // 也持有账本，但它的行高是调用方给定的权威值。把那种行打回 .fit 等于让
    // 内容自己决定高度，而该模式下没有任何路径会再把它钉回去 —— 行会永久
    // 停在内容高度上，与账本预留的空间对不上（实测：账本 40px，实际渲染 10px）。
    if (!state.isMeasured()) return;
    const m = state.measured orelse return;
    m.invalidate(index);
    // 该行退回估算态，slot 高度也要退回 .fit 才能重新被内容撑开。
    for (state.pool_bindings, 0..) |binding, slot| {
        if (binding == index) {
            state.pool_nodes[slot].style.height = .{ .fit = .{} };
            state.pool_nodes[slot].markLayoutDirty();
        }
    }
    state.content_node.markLayoutDirty();
}

/// 丢弃全部实测高度，整表退回估算态（数据源整体替换时用）。
pub fn invalidateAllMeasurements(state: *VirtualListState) void {
    // 同 invalidateMeasurement：只有回填测量模式才该被打回 .fit。
    // `item_height_fn` 模式想让几何跟上回调的新返回值，用 invalidateHeights()。
    if (!state.isMeasured()) return;
    const m = state.measured orelse return;
    m.resetMeasurements();
    for (state.pool_bindings, 0..) |binding, slot| {
        if (binding != null) {
            state.pool_nodes[slot].style.height = .{ .fit = .{} };
        }
    }
    state.content_node.markLayoutDirty();
}

/// 渲染回调里某一步失败时调用：`fn render(node, index, cx, ctx) void` 拿不到 state，
/// 这里沿 pool node 的 parent（content 节点）反查。返回 false = 这不是本 VL 当前绑定的 pool node。
/// 效果：该 slot 当场解绑（半截子树清掉、退出 a11y 树），下一帧为同一 index 重新取 slot 再调回调。
/// 持续失败就持续重试（每帧一次，不封顶——封顶等于把半截行冻住）。
pub fn markPoolNodeRenderIncomplete(node: *Node) bool {
    const content = node.parent orelse return false;
    // 身份校验先于类型断言：只有挂着 vlBeforeRender 的节点，anim_state 才是 *VirtualListState
    const hook = content.meta.per_frame.hooks.before_render.main orelse return false;
    if (hook != vlBeforeRender) return false;
    const ptr = content.meta.per_frame.hooks.slots.anim_state orelse return false;
    const state: *VirtualListState = @ptrCast(@alignCast(ptr));
    if (state.content_node != content) return false;
    return state.markSlotRenderIncomplete(node);
}

/// 刷新指定范围内的已绑定 item（行数不变，但内容可能变化时调用）
pub fn refreshRange(state: *VirtualListState, start: usize, end: usize) void {
    for (state.pool_bindings, 0..) |binding, slot| {
        if (binding) |idx| {
            if (idx >= start and idx < end) {
                // 内容要重画 → 旧的实测高度不再可信，退回 .fit 重测。
                // 仅限**回填测量**模式：`item_height_fn` 模式的行高是调用方
                // 给定的权威值，打回 .fit 会让行改由内容决定高度，且该模式下
                // collectMeasurements 直接 return，没人再把它钉回去。
                if (state.isMeasured()) {
                    state.measured.?.invalidate(idx);
                    state.pool_nodes[slot].style.height = .{ .fit = .{} };
                }
                state.clearSlotNode(state.pool_nodes[slot]);
                if (state.render_with_context_fn) |render_with_context| {
                    render_with_context(state.pool_nodes[slot], idx, state.cx, state.render_user_context);
                } else {
                    state.render_fn(state.pool_nodes[slot], idx, state.cx);
                }
                // 内容变了但 rect 往往没变：不标脏的话 damage-tracking 渲染器
                // 不会重绘该行 —— 表现为打字/IME 上屏后字不出现、光标却照常
                // 前进（光标/选区节点每帧自己标脏）。
                state.pool_nodes[slot].markLayoutDirty();
                state.pool_nodes[slot].markRenderDirty();
            }
        }
    }
}

/// 确保指定 index 可见（如果已在可见范围内则不滚动）
pub fn ensureVisible(state: *VirtualListState, index: usize) void {
    scrollIndexIntoView(state, index, .nearest);
}

// ========== 测试 ==========

const testing = std.testing;

test {
    // Zig 不会因为 `@import` 就收集子模块的 test —— 必须显式引用。
    // 漏了这行，measurements.zig 的几何单测在 `zig build test` 里一个都不跑，
    // 而输出看起来照样全绿（本仓库踩过这个坑）。
    testing.refAllDecls(@This());
    _ = measurements;
}

test "VirtualList: item_height = 0 / 负数时 mount 不 panic" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    inline for (.{ @as(f32, 0), @as(f32, -5) }) |ih| {
        const result = try VirtualList(.{
            .item_count = 10,
            .item_height = ih,
            .width = 300,
            .height = 100,
        }).mount(scope, ctx, struct {
            fn render(_: *Node, _: usize, _: *Cx) void {}
        }.render);
        try root.appendChild(allocator, result.container);
        const r = result.state.visibleRange();
        try testing.expectEqual(r.start, r.end);
    }
}

test "VirtualList: variable item heights drive offsets and visible range" {
    // 不等高模式：第 i 项高 (10 + i*10)，即 10/20/30/40/50…
    // 这里断言的是"几何自洽"——总高、前缀和、可见范围三者必须来自同一套
    // 高度，否则 spacer 撑起的空间与内容实占空间对不上，滚动会漂移。
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const heights = struct {
        fn f(index: usize, _: ?*anyopaque) f32 {
            return 10.0 + @as(f32, @floatFromInt(index)) * 10.0;
        }
    }.f;

    const result = try VirtualList(.{
        .item_count = 5,
        .item_height = 32, // 不等高模式下不该被用到
        .width = 300,
        .height = 100,
        .overscan = 0,
        .item_height_fn = heights,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    const st = result.state;
    // 10+20+30+40+50 = 150，而不是 5*32=160。
    try testing.expectEqual(@as(f32, 150), st.totalContentHeight());
    try testing.expectEqual(@as(f32, 0), st.offsetOf(0));
    try testing.expectEqual(@as(f32, 10), st.offsetOf(1));
    try testing.expectEqual(@as(f32, 60), st.offsetOf(3)); // 10+20+30
    try testing.expectEqual(@as(f32, 30), st.itemHeight(2));

    // 视口 100px、scroll 0：应覆盖到累计高度 >= 100 的那一项。
    st.scroll_state.viewport_height = 100;
    st.scroll_state.scroll_y = 0;
    const r0 = st.visibleRange();
    try testing.expectEqual(@as(usize, 0), r0.start);
    try testing.expect(r0.end >= 4); // 10+20+30+40=100

    // 滚到第 2 项顶端（30）：起始项必须正好是 2。
    // 按等高（32）误算会得到 0，这正是不等高路径要修的。
    // 注意视口 100 / 总高 150 → max_scroll=50，取 30 不会被钳制。
    st.scroll_state.scroll_y = 30;
    const r1 = st.visibleRange();
    try testing.expectEqual(@as(usize, 2), r1.start);

    // 越界的 scroll_y 会被钳到 max_scroll(=50)，落在项 2 的 [30,60) 内。
    st.scroll_state.scroll_y = 9999;
    try testing.expectEqual(@as(usize, 2), st.visibleRange().start);
}

/// 测量模式集成测试的公共装置：每行渲染一个**固定高度**的子节点，
/// 高度由 index 决定（模拟"内容自己决定高度"）。组件事先并不知道这些值 ——
/// 它必须靠 layout 量出来。
const MeasuredFixture = struct {
    /// 第 i 行的真实内容高度：10 / 60 / 10 / 60 …
    fn realHeight(index: usize) f32 {
        return if (index % 2 == 0) 10 else 60;
    }
    fn render(node: *Node, index: usize, c: *Cx) void {
        const child = box(c, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = realHeight(index) },
        }, .{}) catch return;
        node.appendChild(c.allocator, child) catch {};
    }
};

test "VirtualList measured: heights start as estimates then converge to measured values" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 100,
        .measure_items = true,
        .estimate_item_height = 20, // 故意估错：真实是 10/60 交替
        .width = 300,
        .height = 200,
        .overscan = 1,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);
    const st = result.state;

    // 一帧都还没跑：全部按估算 → 100 * 20 = 2000。
    try testing.expect(st.isMeasured());
    try testing.expectEqual(@as(f32, 2000), st.totalContentHeight());

    // 跑几帧：layout 撑开 .fit → hook 读回真高 → 标脏 → 再 layout。
    st.scroll_state.viewport_height = 200;
    var frame: usize = 0;
    while (frame < 5) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    // 可见的那几行必须已经量到真值（不再是估算的 20）。
    try testing.expect(st.measured.?.hasMeasurement(0));
    try testing.expectApproxEqAbs(@as(f32, 10), st.itemHeight(0), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 60), st.itemHeight(1), 0.5);

    // 总高 = 已测行的真高 + 未测行的估算，必须严格小于"全按 20 估"的 2000？
    // 不一定 —— 真高均值 35 > 估算 20，所以总高应当**变大**。
    // 关键是它不再等于纯估算值，且已测部分精确。
    try testing.expect(st.totalContentHeight() != 2000);
    try testing.expectApproxEqAbs(@as(f32, 0), st.offsetOf(0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), st.offsetOf(1), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 70), st.offsetOf(2), 0.5);
}

test "VirtualList measured: measured rows pin their slot height to px" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 50,
        .measure_items = true,
        .estimate_item_height = 20,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;

    var frame: usize = 0;
    while (frame < 5) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    // 量到之后 slot 必须从 .fit 钉成 px —— 一直 .fit 的话账本与实际渲染
    // 各算各的，spacer 撑起的空间会和内容实占空间对不上。
    var checked: usize = 0;
    for (st.pool_bindings, 0..) |binding, slot| {
        const idx = binding orelse continue;
        if (!st.measured.?.hasMeasurement(idx)) continue;
        switch (st.pool_nodes[slot].style.height) {
            .px => |v| {
                try testing.expectApproxEqAbs(MeasuredFixture.realHeight(idx), v, 0.5);
                checked += 1;
            },
            else => return error.SlotHeightNotPinned,
        }
    }
    try expectSlotsChecked(checked, st);
}

test "VirtualList measured: spacers match the prefix sums exactly" {
    // spacer 是虚拟滚动的地基：top_spacer 必须恰好等于 [0,start) 的高度和，
    // bottom_spacer 恰好等于 [end,count) 的高度和。差一点，滚动就漂一点。
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 80,
        .measure_items = true,
        .estimate_item_height = 20,
        .width = 300,
        .height = 200,
        .overscan = 2,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;

    var frame: usize = 0;
    while (frame < 4) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }
    // 滚到中段再跑几帧。
    st.scroll_state.scroll_y = 300;
    frame = 0;
    while (frame < 4) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    const range = st.visibleRange();
    const expect_top = st.offsetOf(range.start);
    const expect_bottom = st.totalContentHeight() - st.offsetOf(range.end);

    switch (st.top_spacer.style.height) {
        .px => |v| try testing.expectApproxEqAbs(expect_top, v, 0.01),
        else => return error.TopSpacerNotPx,
    }
    switch (st.bottom_spacer.style.height) {
        .px => |v| try testing.expectApproxEqAbs(expect_bottom, v, 0.01),
        else => return error.BottomSpacerNotPx,
    }
}

test "VirtualList measured: scroll anchoring keeps the visible row stable" {
    // 这是动态高度最容易出错、也最影响体感的地方：上方的行从估算高变成实测高时，
    // 如果不补偿 scroll_y，用户正在看的内容就会被顶得上下乱跳。
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 200,
        .measure_items = true,
        .estimate_item_height = 20,
        .width = 300,
        .height = 200,
        .overscan = 1,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;

    // 直接跳到中段（此时上方全是估算高度）。
    st.scroll_state.scroll_y = 1000;
    ctx.layout();
    st.updateVisibleItems();

    // 记下视口顶端当前是哪一行、以及它相对视口顶端的偏移。
    const anchor_index = st.visibleRange().start + 1;
    const before_delta = st.offsetOf(anchor_index) - st.scroll_state.scroll_y;

    // 继续跑帧，让可见行逐个被测量（高度从 20 变成 10/60）。
    var frame: usize = 0;
    while (frame < 6) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    // 锚定生效的判据：那一行相对视口顶端的位置**纹丝不动**。
    //
    // 容差必须收紧到 1px —— 实测（关掉补偿做对照）漂移是 10px，
    // 松容差（比如 40px）会让"补偿完全没生效"也照样通过，测试就成了摆设。
    const after_delta = st.offsetOf(anchor_index) - st.scroll_state.scroll_y;
    try testing.expectApproxEqAbs(before_delta, after_delta, 1.0);

    // 补偿的方向也要对：上方的行整体变高（估算 20 → 实测均值 35），
    // scroll_y 必须**跟着变大**，否则"位置没动"可能只是因为什么都没发生。
    try testing.expect(st.scroll_state.scroll_y > 1000);
}

test "VirtualList measured: refreshRange invalidates stale measurements" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 20,
        .measure_items = true,
        .estimate_item_height = 20,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;

    var frame: usize = 0;
    while (frame < 4) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }
    try testing.expect(st.measured.?.hasMeasurement(1));

    // 内容变了 → 旧实测值必须作废，否则行高会一直沿用旧值。
    refreshRange(st, 0, 5);
    try testing.expect(!st.measured.?.hasMeasurement(1));

    // 再跑帧应重新量回来。
    frame = 0;
    while (frame < 4) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }
    try testing.expect(st.measured.?.hasMeasurement(1));
}

test "VirtualList measured: updateItemCount keeps measurements and is leak-free" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 30,
        .measure_items = true,
        .estimate_item_height = 20,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;

    var frame: usize = 0;
    while (frame < 4) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }
    const h1 = st.itemHeight(1);
    try testing.expect(st.measured.?.hasMeasurement(1));

    // 行数变化不该清掉已测高度（它们是 key 域的）。
    updateItemCount(st, 60);
    try testing.expectEqual(@as(usize, 60), st.measured.?.opts.count);
    try testing.expectApproxEqAbs(h1, st.itemHeight(1), 0.01);

    // 缩小同样安全（前缀和表会重建，不能读到旧尾巴）。
    updateItemCount(st, 5);
    try testing.expectEqual(@as(usize, 5), st.measured.?.opts.count);
    _ = st.totalContentHeight();
}

test "VirtualList: item_height_fn uses the ledger (prefix sums + binary search)" {
    // item_height_fn 也持有账本，为的是 O(log n) 定位而不是每帧 O(n) 线性扫。
    // 5000+ 行的 diff 滚到深处时，线性扫会卡到 RPC 超时 —— 实测过。
    //
    // 这里断言"账本存在且几何由它给出"，而不是直接测时间：时间断言在 CI 上
    // 不稳，而账本存在与否是二值的、能可靠转红。
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 1000,
        .item_height = 32, // 不该被用到
        .item_height_fn = struct {
            fn f(index: usize, _: ?*anyopaque) f32 {
                return if (index % 2 == 0) 20 else 28;
            }
        }.f,
        .width = 300,
        .height = 200,
        .overscan = 0,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    const st = result.state;
    // 有账本，但不是回填测量模式。
    try testing.expect(st.hasLedger());
    try testing.expect(!st.isMeasured());

    // 几何来自 item_height_fn：500 组 (20+28) = 24000。
    try testing.expectApproxEqAbs(@as(f32, 24000), st.totalContentHeight(), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 48), st.offsetOf(2), 0.01);
    try testing.expectEqual(@as(f32, 20), st.itemHeight(0));
    try testing.expectEqual(@as(f32, 28), st.itemHeight(1));

    // 深处定位必须准（这正是线性扫会拖慢、二分要保证的地方）。
    st.scroll_state.viewport_height = 200;
    st.scroll_state.scroll_y = 12000; // 恰好第 500 项顶端
    try testing.expectEqual(@as(usize, 500), st.visibleRange().start);
}

/// `checked > 0` 的统一断言：循环体一次都没执行 = 断言全被跳过 = 测试假绿。
///
/// 单写 `expect(checked > 0)` 的问题是失败时没有任何上下文 —— CI 上偶发一次
/// 只能看到"某个 expect false"，分不清是**真的抓到 bug**还是池在内存压力下
/// 没分配出节点（`growPool` 是 `catch {}`、`box` 是 `orelse continue`，
/// 两者都会安静降级）。带上绑定数与池大小就能一眼区分。
fn expectSlotsChecked(checked: usize, state: *const VirtualListState) !void {
    if (checked > 0) return;
    var bound: usize = 0;
    for (state.pool_bindings) |b| {
        if (b != null) bound += 1;
    }
    std.debug.print(
        "\n[VirtualList test] 断言循环零次执行：checked=0 bound={d} pool_size={d} " ++
            "range=[{d},{d}) —— bound=0 多半是池分配失败（环境问题），" ++
            "bound>0 才是筛选条件写错了\n",
        .{ bound, state.pool_size, state.prev_start, state.prev_end },
    );
    return error.NoSlotsChecked;
}

/// 回归测试的公共装置：行高由一个**可切换**的回调给出，而行内容固定 10px。
/// 两者故意不等，这样"行高到底听谁的"才可观测。
///
/// `tall` 是跨测试共享的可变状态（`item_height_fn` 的签名不带上下文，只能用
/// 容器级 var）。每个用它的测试都必须 `begin()` —— 它同时做入口复位和
/// `defer` 收尾复位。**不能用尾部赋值收尾**：断言失败会 early-return 跳过它，
/// 把 tall=true 泄漏给下一个测试（Zig 按声明序跑，靠顺序侥幸是不可维护的）。
const AuthoritativeHeight = struct {
    var tall: bool = false;
    /// 用法：`defer AuthoritativeHeight.begin();`  —— 见上方说明。
    fn begin() void {
        tall = false;
    }
    fn heightFn(_: usize, _: ?*anyopaque) f32 {
        return if (tall) 100 else 40;
    }
    /// 内容只有 10px：若行高改由内容决定，就会塌成 10。
    fn render(node: *Node, _: usize, c: *Cx) void {
        const child = box(c, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 10 },
        }, .{}) catch return;
        node.appendChild(c.allocator, child) catch {};
    }
};

fn mountAuthoritative(scope: *Scope, ctx: *Cx, count: usize) !VirtualListBuilder.MountResult {
    return VirtualList(.{
        .item_count = count,
        .item_height_fn = AuthoritativeHeight.heightFn,
        .width = 300,
        .height = 200,
        .overscan = 0,
    }).mount(scope, ctx, AuthoritativeHeight.render);
}

test "VirtualList item_height_fn: rows keep the caller's height, not the content's" {
    // 回归：`item_height_fn` 也持有账本之后，applySlotHeight 的判据若写成
    // `measured != null`，会因为 hasMeasurement() 恒 false 而把**每一行**
    // 打成 .fit —— 行高改由内容决定（10px），账本却按回调值（40px）预留空间，
    // 每行差 30px。这是该模式的默认路径，不需要任何额外调用就会中招。
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountAuthoritative(scope, ctx, 50);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;

    var frame: usize = 0;
    while (frame < 5) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    var checked: usize = 0;
    for (st.pool_bindings, 0..) |binding, slot| {
        const idx = binding orelse continue;
        _ = idx;
        const node = st.pool_nodes[slot];
        // 权威高度必须钉成 px（不是 .fit）。
        switch (node.style.height) {
            .px => |v| try testing.expectApproxEqAbs(@as(f32, 40), v, 0.01),
            else => return error.AuthoritativeRowLeftAsFit,
        }
        // 且真的按 40 渲染，而不是塌成内容的 10。
        try testing.expectApproxEqAbs(@as(f32, 40), node.rectFromWorldOrFallback().h, 0.5);
        checked += 1;
    }
    try expectSlotsChecked(checked, st);
}

test "VirtualList item_height_fn: refreshRange does not collapse rows to content height" {
    // 回归：refreshRange 的判据若写成 `measured != null`，会把权威高度的行
    // 打回 .fit；而该模式下 collectMeasurements 直接 return，没人再钉回去 ——
    // 行永久停在内容高度上，且跑多少帧都不自愈。
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountAuthoritative(scope, ctx, 50);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;

    var frame: usize = 0;
    while (frame < 3) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    refreshRange(st, 0, 3);
    // 再跑若干帧，给"自愈"留足机会。
    frame = 0;
    while (frame < 8) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    var checked: usize = 0;
    for (st.pool_bindings, 0..) |binding, slot| {
        const idx = binding orelse continue;
        if (idx >= 3) continue;
        const node = st.pool_nodes[slot];
        switch (node.style.height) {
            .px => |v| try testing.expectApproxEqAbs(@as(f32, 40), v, 0.01),
            else => return error.RefreshRangeCollapsedAuthoritativeRow,
        }
        try testing.expectApproxEqAbs(@as(f32, 40), node.rectFromWorldOrFallback().h, 0.5);
        checked += 1;
    }
    // 同上：没有这一行，循环零次执行时断言全跳过、测试假绿。
    try expectSlotsChecked(checked, st);
}

test "VirtualList item_height_fn: invalidateHeights rebuilds the cached prefix sums" {
    // 回归：账本会缓存前缀和，而回调不会 —— 调用方改了返回值（展开折叠块、
    // 切 side-by-side），账本无从得知。没有作废入口的话，itemHeight() 读实时
    // 回调、offsetOf()/totalContentHeight() 读陈旧缓存，几何自相矛盾。
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountAuthoritative(scope, ctx, 100);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;
    ctx.layout();
    st.updateVisibleItems();

    try testing.expectApproxEqAbs(@as(f32, 4000), st.totalContentHeight(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), st.offsetOf(1), 0.01);

    // 调用方改了行高（40 → 100）。
    AuthoritativeHeight.tall = true;
    invalidateHeights(st);

    // 三者必须**一起**更新，否则就是自相矛盾的几何。
    try testing.expectEqual(@as(f32, 100), st.itemHeight(0));
    try testing.expectApproxEqAbs(@as(f32, 100), st.offsetOf(1), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10000), st.totalContentHeight(), 0.01);

    // 已绑定的行也要按新高度重钉，而不是停在旧的 40。
    ctx.layout();
    st.updateVisibleItems();
    var checked: usize = 0;
    for (st.pool_bindings, 0..) |binding, slot| {
        if (binding == null) continue;
        switch (st.pool_nodes[slot].style.height) {
            .px => |v| try testing.expectApproxEqAbs(@as(f32, 100), v, 0.01),
            else => return error.SlotNotRepinnedAfterInvalidateHeights,
        }
        checked += 1;
    }
    // 没有这一行的话，池若一行都没绑定，上面整个循环被跳过、断言全不执行，
    // 测试照样"绿" —— 实测把 pool_bindings 全塞 null 就能骗过去。
    try expectSlotsChecked(checked, st);
}

test "VirtualList item_height_fn: invalidate* APIs do not collapse authoritative rows" {
    // 回归：`invalidateMeasurement` / `invalidateAllMeasurements` 的守卫若写成
    // `measured != null`，会把权威高度的行打回 .fit 且永不自愈。
    //
    // 这两个守卫此前**完全没有测试覆盖** —— 把它们同时改成 `if (false) return;`
    // 整个套件照样全绿（修了一半、只测了一半）。
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountAuthoritative(scope, ctx, 50);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;
    var frame: usize = 0;
    while (frame < 3) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    // 两个 API 都调一遍，任一个漏了守卫都会让行塌成内容高度。
    invalidateMeasurement(st, 0);
    invalidateAllMeasurements(st);
    frame = 0;
    while (frame < 5) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    var checked: usize = 0;
    for (st.pool_bindings, 0..) |binding, slot| {
        if (binding == null) continue;
        const node = st.pool_nodes[slot];
        switch (node.style.height) {
            .px => |v| try testing.expectApproxEqAbs(@as(f32, 40), v, 0.01),
            else => return error.InvalidateCollapsedAuthoritativeRow,
        }
        try testing.expectApproxEqAbs(@as(f32, 40), node.rectFromWorldOrFallback().h, 0.5);
        checked += 1;
    }
    try expectSlotsChecked(checked, st);
}

test "VirtualList item_height_fn: invalidateHeights resyncs scroll bounds" {
    // 回归 D2：`invalidateHeights` 若不同步 `scroll_state.content_height`，
    // 紧随其后的 scrollToIndex / ensureVisible 会按**旧的** maxScrollY 钳制。
    // 这个钳制是不可逆的：下一帧虽然修好 content_height，但请求的位置已经丢了，
    // 列表就停在错误的行上（实测：想去第 90 行，落在第 38 行）。
    //
    // 这正是 invalidateHeights 文档里写的那个场景 —— 展开折叠块后
    // ensureVisible 到展开的那一行。
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountAuthoritative(scope, ctx, 100);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;
    ctx.layout();
    st.updateVisibleItems();
    try testing.expectApproxEqAbs(@as(f32, 4000), st.scroll_state.content_height, 0.01);

    // 行高 40 → 100，总高 4000 → 10000。
    AuthoritativeHeight.tall = true;
    invalidateHeights(st);

    // 滚动边界必须**立刻**跟上，不能等到下一帧。
    try testing.expectApproxEqAbs(@as(f32, 10000), st.scroll_state.content_height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 9800), st.scroll_state.maxScrollY(), 0.01);

    // 于是 scrollToIndex 能真的到达目标，而不是被钳在旧的 max(3800)。
    scrollToIndex(st, 90);
    try testing.expectApproxEqAbs(@as(f32, 9000), st.scroll_state.scroll_y, 1.0);
}

test "VirtualList item_height_fn: updateItemCount refreshes geometry even when count is unchanged" {
    // 回归 D1：`setCount` 见到行数没变会早退，pending_min 不动 → 前缀和陈旧。
    // 但"数据源变了而行数恰好相同"很常见（diff 换同行数的文件、切 inline/
    // side-by-side），此时 item_height_fn 的返回值多半也变了。
    // 表现：itemHeight() 说 100、offsetOf() 还说 40，行重叠 + 滚动条短 2.5 倍。
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountAuthoritative(scope, ctx, 100);
    try root.appendChild(allocator, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 200;
    ctx.layout();
    st.updateVisibleItems();
    try testing.expectApproxEqAbs(@as(f32, 4000), st.totalContentHeight(), 0.01);

    // 数据换了、行数**没变**、行高变了。
    AuthoritativeHeight.tall = true;
    updateItemCount(st, 100);

    // 三者必须一致，否则就是自相矛盾的几何。
    try testing.expectEqual(@as(f32, 100), st.itemHeight(0));
    try testing.expectApproxEqAbs(@as(f32, 100), st.offsetOf(1), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10000), st.totalContentHeight(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10000), st.scroll_state.content_height, 0.01);
}

test "VirtualList measured: item_height_fn wins over measure_items" {
    // 两者都给时以 item_height_fn 为准 —— 它更便宜且精确，无需测量往返。
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 10,
        .measure_items = true,
        .estimate_item_height = 99,
        .item_height_fn = struct {
            fn f(_: usize, _: ?*anyopaque) f32 {
                return 15;
            }
        }.f,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);

    try testing.expect(!result.state.isMeasured());
    try testing.expectEqual(@as(f32, 150), result.state.totalContentHeight());
}

test "VirtualList: equal-height path is unchanged when no height fn is given" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 10,
        .item_height = 20,
        .width = 300,
        .height = 100,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    try testing.expectEqual(@as(f32, 200), result.state.totalContentHeight());
    try testing.expectEqual(@as(f32, 40), result.state.offsetOf(2));
    try testing.expectEqual(@as(f32, 20), result.state.itemHeight(7));
}

test "VirtualList: basic mount and visible range" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 1000,
        .item_height = 32,
        .width = 300,
        .height = 200,
        .overscan = 2,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);

    try root.appendChild(allocator, result.container);

    // 验证是 ScrollArea（overflow_hidden）
    try testing.expect(result.container.style.overflow_hidden);
    try testing.expectEqualStrings("VirtualList", result.container.meta.ownership.meta.component_name.?);

    // 池大小 > 0
    try testing.expect(result.state.pool_size > 0);
    try testing.expect(result.state.pool_size <= max_pool_size);

    // 初始可见范围从 0 开始
    const range = result.state.visibleRange();
    try testing.expectEqual(@as(usize, 0), range.start);
    try testing.expect(range.end > 0);
    try testing.expect(range.end <= 1000);
}

test "VirtualList: visible range changes with scroll" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 30000,
        .item_height = 32,
        .width = 300,
        .height = 200,
        .overscan = 3,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    // 模拟滚动到 index 100
    result.state.scroll_state.scroll_y = 100 * 32;
    result.state.scroll_state.viewport_height = 200;
    result.state.scroll_state.content_height = 30000 * 32;

    const range = result.state.visibleRange();
    // start = 100 - 3 = 97
    try testing.expectEqual(@as(usize, 97), range.start);
    // end = 100 + ceil(200/32) + 3 = 100 + 7 + 3 = 110
    try testing.expectEqual(@as(usize, 110), range.end);
}

test "VirtualList: empty list" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 0,
        .item_height = 32,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    const range = result.state.visibleRange();
    try testing.expectEqual(@as(usize, 0), range.start);
    try testing.expectEqual(@as(usize, 0), range.end);
}

test "VirtualList: updateItemCount" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 100,
        .item_height = 32,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    updateItemCount(result.state, 50000);
    try testing.expectEqual(@as(usize, 50000), result.state.props.item_count);
    try testing.expectEqual(@as(f32, 50000 * 32), result.state.scroll_state.content_height);
}

test "VirtualList: scrollToIndex" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 1000,
        .item_height = 32,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    // 设置 content_height 让 maxScrollY > 0
    result.state.scroll_state.content_height = 1000 * 32;
    result.state.scroll_state.viewport_height = 200;

    scrollToIndex(result.state, 500);
    try testing.expectEqual(@as(f32, 500 * 32), result.state.scroll_state.scroll_y);
}

test "VirtualList: node pool reuse" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 100,
        .item_height = 40,
        .width = 300,
        .height = 200,
        .overscan = 1,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    // 初始绑定数
    var bound_count: usize = 0;
    for (result.state.pool_bindings) |binding| {
        if (binding != null) bound_count += 1;
    }
    try testing.expect(bound_count > 0);
    const initial_bound = bound_count;

    // 模拟滚动
    result.state.scroll_state.scroll_y = 200;
    result.state.scroll_state.viewport_height = 200;
    result.state.scroll_state.content_height = 100 * 40;
    result.state.updateVisibleItems();

    // 验证绑定数（节点池复用，总数不应超过池大小）
    bound_count = 0;
    for (result.state.pool_bindings) |binding| {
        if (binding != null) bound_count += 1;
    }
    try testing.expect(bound_count > 0);
    try testing.expect(bound_count <= result.state.pool_size);
    // 前后绑定数应该接近（视口大小不变）
    try testing.expect(bound_count >= initial_bound -| 2);
}

test "VirtualList: ensureVisible" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 1000,
        .item_height = 32,
        .width = 300,
        .height = 200,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    result.state.scroll_state.content_height = 1000 * 32;
    result.state.scroll_state.viewport_height = 200;

    // item 50 不在视口内 → 应该滚动
    ensureVisible(result.state, 50);
    const scroll_y = result.state.scroll_state.scroll_y;
    const item_top = 50 * 32;
    const item_bottom = item_top + 32;
    // 确保 item 完全在视口内
    try testing.expect(scroll_y <= @as(f32, @floatFromInt(item_top)));
    try testing.expect(scroll_y + 200 >= @as(f32, @floatFromInt(item_bottom)));
}

test "VirtualList: spacer heights correct" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 100,
        .item_height = 40,
        .width = 300,
        .height = 200,
        .overscan = 0,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    // 初始: top_spacer = 0（从 index 0 开始）
    try testing.expectEqual(@as(f32, 0), result.state.top_spacer.style.height.px);

    // 滚动后更新
    result.state.scroll_state.scroll_y = 400; // index 10 开始
    result.state.scroll_state.viewport_height = 200;
    result.state.scroll_state.content_height = 100 * 40;
    result.state.updateVisibleItems();

    // top_spacer = 10 * 40 = 400
    const range = result.state.visibleRange();
    try testing.expectEqual(@as(f32, @floatFromInt(range.start * 40)), result.state.top_spacer.style.height.px);
    // bottom_spacer = (100 - end) * 40
    try testing.expectEqual(
        @as(f32, @floatFromInt((100 - range.end) * 40)),
        result.state.bottom_spacer.style.height.px,
    );
}

test "allocation campaign: VirtualList growPool failure does not partially commit" {
    const allocator = testing.allocator;
    var fail_index: usize = 0;
    var saw_induced_failure = false;
    var induced_failure_count: usize = 0;
    var saw_success_after_failures = false;

    while (fail_index < 64) : (fail_index += 1) {
        var ctx = try Cx.init(allocator);
        defer ctx.deinit();

        const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        ctx.root = root;

        const scope = try Scope.init(allocator, null, ctx.owner);
        defer scope.dispose();

        const result = try VirtualList(.{
            .item_count = 200,
            .item_height = 40,
            .width = 300,
            .height = 80,
            .overscan = 0,
        }).mount(scope, ctx, struct {
            fn render(_: *Node, _: usize, _: *Cx) void {}
        }.render);
        try root.appendChild(allocator, result.container);

        const old_pool_size = result.state.pool_size;
        const old_pool_nodes_ptr = result.state.pool_nodes.ptr;
        const old_pool_bindings_ptr = result.state.pool_bindings.ptr;
        const old_children_count = result.state.content_node.children.items.len;

        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });
        const fail_alloc = failing_allocator.allocator();
        ctx.allocator = fail_alloc;
        result.state.allocator = fail_alloc;

        // 迫使 visible window 大于 mount 时的初始 pool，触发 growPool。
        result.state.scroll_state.viewport_height = 520;
        result.state.scroll_state.content_height = result.state.totalContentHeight();
        result.state.updateVisibleItems();

        if (!failing_allocator.has_induced_failure) {
            if (saw_induced_failure and result.state.pool_size > old_pool_size) {
                saw_success_after_failures = true;
            }
            continue;
        }
        saw_induced_failure = true;
        induced_failure_count += 1;

        try testing.expect(result.state.pool_size >= old_pool_size);
        if (result.state.pool_size == old_pool_size) {
            try testing.expectEqual(old_pool_nodes_ptr, result.state.pool_nodes.ptr);
            try testing.expectEqual(old_pool_bindings_ptr, result.state.pool_bindings.ptr);
            try testing.expectEqual(old_children_count, result.state.content_node.children.items.len);
        }
    }

    try testing.expect(saw_induced_failure);
    try testing.expect(induced_failure_count >= 3);
    try testing.expect(saw_success_after_failures);
}

// 下游应用 layers 残影复现：slot 行内"绝对定位 + translate_x"的动作条图标，
// 挂载后**运行时** setOpacity 翻转显隐（hover 直写路径），投影 x 必须仍是
// translate 后的位置，不能退回布局槽位（行左）。
// 真实症状：键画到 x≈16（行左 padding），真实位置 ≈182。
test "VirtualList: runtime setOpacity keeps absolute+translate child at translated x" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 300);

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const ICON_BG = Color.rgba(250, 60, 60, 255);
    const TRACK_X: f32 = 170;

    const render_row = struct {
        fn render(item_node: *Node, idx: usize, cx_ptr: *Cx) void {
            _ = idx;
            const a = cx_ptr.allocator;
            const row = box(cx_ptr, .{
                .width = .{ .grow = .{} },
                .height = .{ .px = 24 },
                .direction = .row,
                .align_items = .center,
                .padding = .{ .left = 6, .right = 6 },
            }, .{}) catch return;
            const track = box(cx_ptr, .{
                .position = .absolute,
                .width = .{ .px = 48 },
                .height = .{ .px = 24 },
                .direction = .row,
                .align_items = .center,
                .gap = 4,
            }, .{}) catch return;
            track.setStyle(null, .translate_x, @as(f32, 170));
            track.setStyle(null, .translate_y, @as(f32, 0));
            const icon = box(cx_ptr, .{
                .width = .{ .px = 13 },
                .height = .{ .px = 13 },
                .background = Color.rgba(250, 60, 60, 255),
            }, .{}) catch return;
            icon.setOpacity(0.0);
            track.appendChild(a, icon) catch return;
            row.appendChild(a, track) catch return;
            item_node.appendChild(a, row) catch return;
        }
    }.render;

    const result = try VirtualList(.{
        .item_count = 40,
        .item_height = 24,
        .width = 228,
        .height = 240,
        .overscan = 1,
    }).mount(scope, ctx, render_row);
    try root.appendChild(allocator, result.container);

    // 帧 1：初始挂载。图标 opacity=0，不应出现在命令流里。
    ctx.layout();
    _ = ctx.render();
    {
        const commands = ctx.lowerForEncoderPaintTable();
        for (commands) |cmd| {
            if (cmd.isFillRect() and Color.eql(cmd.color.toColor(), ICON_BG)) {
                try testing.expect(false); // opacity 0 不该被画
            }
        }
    }

    // 模拟滚动（content translate_y 非零，含亚行偏移路径）。
    scroll_area.setScrollY(result.state.scroll_state, result.state.content_node, 36);
    ctx.layout();
    _ = ctx.render();
    _ = ctx.lowerForEncoderPaintTable();

    // 找一个已绑定 slot 的图标节点（结构：slot > row > track > icon）。
    // 选绑定 data index 居中的行（避开裁剪边界），按 data index 而非世界 rect 选。
    var icon_node: ?*Node = null;
    var expect_x: f32 = 0;
    var best_slot: ?usize = null;
    var best_idx: usize = 0;
    for (result.state.pool_bindings, 0..) |binding, slot| {
        const idx = binding orelse continue;
        if (result.state.pool_nodes[slot].children.items.len == 0) continue;
        if (best_slot == null or (idx > best_idx + 1 and idx < 8)) {
            best_slot = slot;
            best_idx = idx;
        }
    }
    if (best_slot) |slot| {
        const row = result.state.pool_nodes[slot].children.items[0];
        if (row.children.items.len > 0) {
            const track = row.children.items[0];
            if (track.children.items.len > 0) {
                icon_node = track.children.items[0];
                expect_x = track.rectFromWorldOrFallback().x + TRACK_X;
            }
        }
    }
    try testing.expect(icon_node != null);

    // hover 直写：运行时 setOpacity 0→1（下游应用 setTrackInk 的直写路径）。
    icon_node.?.setOpacity(1.0);
    ctx.layout();
    _ = ctx.render();
    {
        const commands = ctx.lowerForEncoderPaintTable();
        var found = false;
        for (commands) |cmd| {
            if (cmd.isFillRect() and Color.eql(cmd.color.toColor(), ICON_BG)) {
                found = true;
                try testing.expectApproxEqAbs(expect_x, cmd.geom.x, 1.0);
            }
        }
        try testing.expect(found);
    }

    // 再翻回 0 → 再翻到 1（re-hover 路径，残影正是这里复活）。
    // 翻 0 帧：图标不得再出现在命令流（残影 = 缓存 splice 把 stale 条目放行）。
    icon_node.?.setOpacity(0.0);
    ctx.layout();
    _ = ctx.render();
    {
        const commands = ctx.lowerForEncoderPaintTable();
        for (commands) |cmd| {
            if (cmd.isFillRect() and Color.eql(cmd.color.toColor(), ICON_BG)) {
                try testing.expect(false); // opacity 0 后图标残留 = 残影
            }
        }
    }
    // 连续第二帧仍保持 0（缓存 splice 命中帧）——残影正是在"非重录帧"复活。
    _ = ctx.render();
    {
        const commands = ctx.lowerForEncoderPaintTable();
        for (commands) |cmd| {
            if (cmd.isFillRect() and Color.eql(cmd.color.toColor(), ICON_BG)) {
                try testing.expect(false);
            }
        }
    }
    icon_node.?.setOpacity(1.0);
    ctx.layout();
    _ = ctx.render();
    {
        const commands = ctx.lowerForEncoderPaintTable();
        var found = false;
        for (commands) |cmd| {
            if (cmd.isFillRect() and Color.eql(cmd.color.toColor(), ICON_BG)) {
                found = true;
                try testing.expectApproxEqAbs(expect_x, cmd.geom.x, 1.0);
            }
        }
        try testing.expect(found);
    }
}

// ---------------------------------------------------------------------------
// 降级之后必须能自愈。growPool / 取 slot / reorderPoolNodes 在 OOM 下
// 都是"这一帧少画点"，但 updateVisibleItems 的提前返回只看可见范围有没有变 ——
// 范围不变就永远不重试，缺的行和错的顺序会停到用户滚动为止。
// ---------------------------------------------------------------------------

fn expectRangeFullyBound(st: *const VirtualListState) !void {
    const range = st.visibleRange();
    var idx = range.start;
    while (idx < range.end) : (idx += 1) {
        if (!st.isBound(idx)) {
            std.debug.print("\n[VirtualList test] 行 {d} 未绑定：range=[{d},{d}) pool_size={d}\n", .{ idx, range.start, range.end, st.pool_size });
            return error.RowNotBound;
        }
    }
}

fn expectPoolOrderSane(st: *const VirtualListState) !void {
    // children = [top_spacer, 活跃行按 index 升序, 空闲 slot, bottom_spacer]
    const kids = st.content_node.children.items;
    try testing.expect(kids.len >= 2);
    try testing.expect(kids[0] == st.top_spacer);
    try testing.expect(kids[kids.len - 1] == st.bottom_spacer);
    var last_idx: ?usize = null;
    var seen_free = false;
    for (kids[1 .. kids.len - 1]) |k| {
        var bound: ?usize = null;
        for (st.pool_bindings, 0..) |b, slot| {
            if (st.pool_nodes[slot] == k) bound = b;
        }
        if (bound) |idx| {
            try testing.expect(!seen_free); // 活跃行必须都排在空闲 slot 前面
            if (last_idx) |l| try testing.expect(idx > l);
            last_idx = idx;
        } else {
            seen_free = true;
        }
    }
}

test "VirtualList: growPool 失败后可见范围不变也会在下一帧重试扩池并绑满" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const a = failing.allocator();
    var ctx = try Cx.init(a);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(a, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{ .item_count = 200, .item_height = 20, .width = 300, .height = 100, .overscan = 0 })
        .mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(a, result.container);
    const st = result.state;
    st.scroll_state.viewport_height = 100;
    st.updateVisibleItems();
    try expectRangeFullyBound(st);
    const small_pool = st.pool_size;

    // 视口放大四倍：需要的 slot 超过当前池，这一帧 growPool 的第一次分配失败。
    st.scroll_state.viewport_height = 400;
    failing.fail_index = failing.alloc_index;
    st.updateVisibleItems();
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(small_pool, st.pool_size); // 扩容确实失败了
    try testing.expect(st.rebind_incomplete);

    // 范围没变。修复前：提前返回，池永远不再长，可见行缺一半直到用户滚动。
    st.updateVisibleItems();
    try testing.expect(st.pool_size > small_pool);
    try expectRangeFullyBound(st);
    try expectPoolOrderSane(st);
    try testing.expect(!st.rebind_incomplete);
}

test "VirtualList: reorderPoolNodes 失败后下一帧重排（新 slot 不能留在 bottom_spacer 之后）" {
    // 先在一份干净的装置上量出"视口放大那一趟"用了多少次分配，再在另一份装置上
    // 让最后一次分配失败 —— 最后一次分配落在 reorderPoolNodes 里
    // （ensureTotalCapacity / replaceChildOrder），前面的扩池与绑定都已成功。
    const Fixture = struct {
        fn run(a: std.mem.Allocator, fail_at_from_end: ?usize, failing: *testing.FailingAllocator) !void {
            var ctx = try Cx.init(a);
            defer ctx.deinit();
            const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 600 } }, .{});
            ctx.root = root;
            const scope = try Scope.init(a, null, ctx.owner);
            defer scope.dispose();
            const result = try VirtualList(.{ .item_count = 200, .item_height = 20, .width = 300, .height = 100, .overscan = 0 })
                .mount(scope, ctx, struct {
                fn render(_: *Node, _: usize, _: *Cx) void {}
            }.render);
            try root.appendChild(a, result.container);
            const st = result.state;
            st.scroll_state.viewport_height = 100;
            st.updateVisibleItems();
            st.scroll_state.viewport_height = 400;
            if (fail_at_from_end) |from_end| {
                failing.fail_index = failing.alloc_index + @This().pass_allocs - 1 - from_end;
                st.updateVisibleItems();
                failing.fail_index = std.math.maxInt(usize);
                try testing.expect(failing.has_induced_failure);
                try testing.expect(st.rebind_incomplete);
                // 修复前：提前返回，顺序永远是错的。
                st.updateVisibleItems();
                try expectRangeFullyBound(st);
                try expectPoolOrderSane(st);
                try testing.expect(!st.rebind_incomplete);
            } else {
                const before = failing.alloc_index;
                st.updateVisibleItems();
                @This().pass_allocs = failing.alloc_index - before;
                try expectPoolOrderSane(st);
            }
        }
        var pass_allocs: usize = 0;
    };
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    try Fixture.run(counting.allocator(), null, &counting);
    try testing.expect(Fixture.pass_allocs > 0);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    try Fixture.run(failing.allocator(), 0, &failing);
}

test "VirtualList: 回调报 markPoolNodeRenderIncomplete 后该行解绑并在下一趟重画" {
    const Probe = struct {
        var calls: usize = 0;
        var fail_left: usize = 2;
        fn render(node: *Node, index: usize, cx: *Cx) void {
            calls += 1;
            if (index == 1 and fail_left > 0) {
                fail_left -= 1;
                // 模拟回调中途失败：已经建了半截子树，然后报未完成
                const half = core.adoptChild(cx, cx.allocator, node, box(cx, .{}, .{}) catch return) catch return;
                _ = half;
                std.testing.expect(markPoolNodeRenderIncomplete(node)) catch unreachable;
                return;
            }
            node.meta.ownership.meta.test_id = "rendered";
        }
    };
    Probe.calls = 0;
    Probe.fail_left = 2;
    const a = testing.allocator;
    var ctx = try Cx.init(a);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(a, null, ctx.owner);
    defer scope.dispose();
    const result = try VirtualList(.{ .item_count = 5, .item_height = 20, .width = 300, .height = 100, .overscan = 0 })
        .mount(scope, ctx, Probe.render);
    try root.appendChild(a, result.container);
    const st = result.state;
    // mount 的首趟已经渲染了 5 行：index 1 失败一次（fail_left 2→1）并报未完成
    try testing.expect(st.rebind_incomplete);
    try testing.expect(!st.isBound(1));
    try testing.expectEqual(@as(usize, 5), Probe.calls);
    st.scroll_state.viewport_height = 100;
    // 退避：连续失败 1 趟 → 等 1 趟。这一趟只是等（范围没变），回调不被调
    try testing.expectEqual(@as(u16, 1), st.render_retry_wait);
    st.updateVisibleItems();
    try testing.expectEqual(@as(usize, 5), Probe.calls);
    try testing.expect(st.rebind_incomplete);
    // 第二次真正重试（可见范围没变）：修复前提前返回、index 1 永远空着；现在重调回调，再失败一次（1→0）
    st.updateVisibleItems();
    try testing.expectEqual(@as(usize, 6), Probe.calls);
    try testing.expect(st.rebind_incomplete);
    try testing.expect(!st.isBound(1));
    // 连续失败 2 趟 → 等 3 趟
    try testing.expectEqual(@as(u16, 3), st.render_retry_wait);
    // 失败的 slot 已回收：子树清空、退出 a11y 树
    for (st.pool_nodes, 0..) |pn, slot| {
        if (st.pool_bindings[slot] == null) {
            try testing.expectEqual(@as(usize, 0), pn.children.items.len);
            try testing.expect(pn.behavior.interaction.a11y == null);
        }
    }
    // 等 3 趟（回调不被调），第 4 趟重试成功 → 绑上、不再 incomplete、退避归零
    for (0..3) |_| st.updateVisibleItems();
    try testing.expectEqual(@as(usize, 6), Probe.calls);
    try testing.expect(!st.isBound(1));
    st.updateVisibleItems();
    try testing.expect(st.isBound(1));
    try testing.expect(!st.rebind_incomplete);
    try testing.expectEqual(@as(u16, 0), st.render_retry_wait);
    try testing.expectEqual(@as(u8, 0), st.render_retry_streak);
    var rendered: usize = 0;
    for (st.pool_bindings, 0..) |b, slot| {
        if (b != null and st.pool_nodes[slot].meta.ownership.meta.test_id != null) rendered += 1;
    }
    try testing.expectEqual(@as(usize, 5), rendered);
    // 其余 4 行各一次 + index 1 三次
    try testing.expectEqual(@as(usize, 7), Probe.calls);
    // 不是本 VL 当前绑定的 pool node → false（root 不是 pool node）
    try testing.expect(!markPoolNodeRenderIncomplete(root));
}
