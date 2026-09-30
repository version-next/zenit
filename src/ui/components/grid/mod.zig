/// Grid — 业务组件：基于 ScrollArea + cell pool 的 2D 虚拟化表格
///
/// 设计参考：Google Sheets canvas / ag-grid / LinkedIn Rooster
/// - Double Viewport：外层 ScrollArea(.both) + 内层 content translate_x/y
/// - Cell Culling：根据 scroll 位置 + viewport 计算 visible range，只保留 pool 节点
/// - Frozen Panes (Phase 3)：独立 absolute 层，不随 translate
///
/// 保留模式 mount() API：
/// ```
/// const g = try mountGrid(.{
///     .row_count = 1000,
///     .col_count = 100,
///     .col_widths = &col_ws,
///     .cell_render_fn = myCellRender,
/// }, scope, cx);
/// try parent.appendChild(alloc, g.root);
///
/// ```
///
/// **Phase 2 虚拟化**：pool_size = (viewport_rows + 2·overscan) × (viewport_cols + 2·overscan)。
/// 滚动时 pool 内 cell 通过 absolute margin 重新定位到新坐标，不重建节点，不申请内存。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const Cx = core.Cx;
const box = core.box;
const Scope = @import("../../reactive.zig").Scope;
const scroll_area = @import("../scroll_area/mod.zig");

const state_mod = @import("state.zig");
pub const GridProps = state_mod.GridProps;
pub const GridState = state_mod.GridState;
pub const CellRenderFn = state_mod.CellRenderFn;
pub const CellBinding = state_mod.CellBinding;
pub const VisibleRange = state_mod.VisibleRange;
pub const ExternalRowWindow = state_mod.ExternalRowWindow;
pub const HostViewport = state_mod.HostViewport;
pub const PinOwner = state_mod.PinOwner;

pub const GridResult = struct {
    root: *Node,
    state: *GridState,
};

/// Pool 大小上限（防炸内存）。
const MAX_POOL_SIZE: usize = 2000;

fn appendPoolNodes(cx: *Cx, content: *Node, nodes: []*Node, comp_name: []const u8) !void {
    for (0..nodes.len) |i| {
        const cell_node = try box(cx, .{
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
            .position = .absolute,
            .overflow_hidden = true,
        }, .{});
        // append 失败时这一个 cell_node 无人持有（已挂上的那些归 content，
        // 由树的 teardown 负责）。下游编辑器表格渲染期 sweep 实测：
        // 这里是全部 101 处泄漏里最大的一个来源。
        errdefer cx.freeNode(cell_node);
        cell_node.meta.ownership.meta.component_name = comp_name;
        try content.appendChild(cx.allocator, cell_node);
        // 挂稳之后再写进 pool 数组（prepare-then-publish）：
        // 失败时 nodes[i] 留着一个已释放的指针，稍后 detachGridBindings
        // 之类的遍历会踩到。
        nodes[i] = cell_node;
    }
}

/// 挂载 Grid：创建虚拟化 Grid 组件，返回 root 节点 + state handle。
/// v0.5 推荐入口（取代 `Grid(props).mount(scope, cx)` Builder 链）。
pub fn mountGrid(props: GridProps, scope: *Scope, cx: *Cx) !GridResult {
    const my_scope = try scope.childScope();
    const alloc = cx.allocator;
    const p = props;
    {
        if (p.cell_render_fn == null) return error.MissingCellRenderFn;
        if (p.col_widths.len != p.col_count) return error.ColWidthsLengthMismatch;

        // 外层 root
        var root_style = core.BoxStyle{
            .direction = .column,
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
        };
        if (p.width) |w| root_style.width = .{ .px = w };
        if (p.height) |h| root_style.height = .{ .px = h };
        const root = try box(cx, root_style, .{});
        // root 是返回给调用方的整棵 Grid 子树的根，返回成功前无人持有。
        // 它下面还有 ScrollArea、四组 pool 节点（各上千个 cell）、
        // registerResource、onCleanup —— 任何一处失败都会漏掉整棵。
        // 下游编辑器表格渲染期 sweep 实测：99 处泄漏里的绝大多数都源于这里，
        // appendPoolNodes 那 1207 条只是可见的表象（那些 cell 已挂在 root 下）。
        errdefer cx.freeNode(root);
        root.meta.ownership.meta.component_name = "Grid";
        // scope 生命周期必须绑到 root 节点（与 ScrollArea 同款）。
        //
        // 没有这行的实测后果（2026-08-22 用户线上 crash，反汇编定位到
        // detachGridBindings）：caller 用 freeNode/clearChildren 清掉 Grid 子树
        // 时，my_scope 不会被 dispose，留在父 scope 的 children 里；它的
        // onCleanup(detachGridBindings) 持有 state.content 节点指针——节点已
        // 随子树释放。之后父 scope dispose（如虚拟列表 recycleSlot）才跑到这
        // 条 cleanup → 解引用已释放节点 → EXC_BAD_ACCESS。
        // 绑定后 freeNode(root) 会先 dispose my_scope（此刻节点仍有效，
        // detach 正常执行），父 scope 再 dispose 时按 disposed 标记跳过。
        try core.bindScopeToNode(my_scope, root);

        // 预算 content 总尺寸
        var content_w: f32 = 0;
        for (p.col_widths) |w| content_w += w;
        var content_h: f32 = 0;
        if (p.row_heights) |heights| {
            if (heights.len == p.row_count) {
                for (heights) |h| content_h += h;
            } else {
                content_h = @as(f32, @floatFromInt(p.row_count)) * p.cell_height;
            }
        } else {
            content_h = @as(f32, @floatFromInt(p.row_count)) * p.cell_height;
        }

        // Grid 默认保留双轴滚动；业务调用方可把 scroll_direction 收窄成单轴。
        // sa.container 到下面 root.appendChild 之间是游离子树（ScrollArea 自带
        // 子 scope，绑定只解绑不释放，调用方 scope.dispose() 回收不到它）。
        var sa_attached = false;
        const sa = try scroll_area.mountScrollArea(.{
            .width = p.width,
            .height = p.height,
            .direction = p.scroll_direction,
            .content_width = content_w,
            .content_height = content_h,
        }, my_scope, cx);
        sa.container.meta.ownership.meta.component_name = "Grid.ScrollArea";
        errdefer if (!sa_attached) cx.freeNode(sa.container);
        try root.appendChild(alloc, sa.container);
        sa_attached = true;

        sa.content.meta.ownership.meta.component_name = "Grid.Content";
        sa.content.style.width = .{ .px = content_w };
        sa.content.style.height = .{ .px = content_h };
        sa.content.style.flex_shrink = 0;
        // content 里 cell 用 absolute 定位，content 本身 direction 不再重要
        sa.content.style.direction = .column;

        const scroll_event_ctx: *scroll_area.ScrollEventCtx = @ptrCast(@alignCast(sa.container.behavior.events.event_context.?));
        const scroll_state_ptr = scroll_event_ctx.state;
        scroll_state_ptr.external_content_width = true;
        scroll_state_ptr.external_content_height = true;

        // frozen 验证
        if (p.frozen_rows > p.row_count) return error.FrozenRowsExceedsRowCount;
        if (p.frozen_cols > p.col_count) return error.FrozenColsExceedsColCount;

        // 估算 pool 大小
        const viewport_w_est = p.width orelse 400;
        const viewport_h_est = p.height orelse 300;
        const avg_col_w: f32 = if (p.col_count > 0) content_w / @as(f32, @floatFromInt(p.col_count)) else 100;
        const visible_cols_est: usize = @max(1, @as(usize, @intFromFloat(@ceil(viewport_w_est / @max(avg_col_w, 1)))));
        const visible_rows_est: usize = if (p.row_window_height_hint) |hint| blk: {
            // 外部行窗口宿主：pool 按窗口高 / 平均行高估算，而不是 Grid 自身高度
            //（那是全内容高，会把 pool 撑成全部行）。窗口变化超估时运行期再扩容。
            const avg_row_h: f32 = if (p.row_count > 0)
                content_h / @as(f32, @floatFromInt(p.row_count))
            else
                p.cell_height;
            break :blk @max(1, @as(usize, @intFromFloat(@ceil(hint / @max(avg_row_h, 1)))));
        } else @max(1, @as(usize, @intFromFloat(@ceil(viewport_h_est / @max(p.cell_height, 1)))));
        // 池不可能有用地大于实际行列数：多出来的 cell 永远没有数据可绑定，
        // 却仍以零尺寸节点常驻树上，被 tick / paint-sync / interaction-sync
        // 三条全树遍历各扫一遍。
        //
        // 实测（下游编辑器，25 个 2×2 markdown 表格的文档）：每个 Grid 按视口估算
        // 建了 50 个 cell，全文档 **900 个** Grid.Cell 池节点，把 synced_nodes
        // 从 ~1200 抬到 4451，phase_sync 1.1ms → 6.5ms。按行列数收紧后，
        // 2×2 的表只建 4 个。
        const pool_rows = @min(p.row_count, visible_rows_est + 2 * p.overscan_rows);
        const pool_cols = @min(p.col_count, visible_cols_est + 2 * p.overscan_cols);
        // 4 类 pool 独立分配（按 paint order 依次 append）
        const scrollable_pool_size = @min(MAX_POOL_SIZE, pool_rows * pool_cols);
        const frozen_col_pool_size = @min(MAX_POOL_SIZE, p.frozen_cols * pool_rows);
        const frozen_row_pool_size = @min(MAX_POOL_SIZE, p.frozen_rows * pool_cols);
        const corner_pool_size = @min(MAX_POOL_SIZE, p.frozen_rows * p.frozen_cols);

        // registered：注册成功后，下面这批 errdefer 全部让位给 scope 的 destroy
        //（同一批 slice 只能有一个回收责任方）。声明必须在第一次使用之前。
        var registered = false;
        const state = try my_scope.allocator.create(GridState);
        errdefer if (!registered) my_scope.allocator.destroy(state);

        const owned_widths = try my_scope.allocator.alloc(f32, p.col_count);
        errdefer if (!registered) my_scope.allocator.free(owned_widths);
        @memcpy(owned_widths, p.col_widths);

        const col_offsets = try my_scope.allocator.alloc(f32, p.col_count + 1);
        errdefer if (!registered) my_scope.allocator.free(col_offsets);

        const row_offsets = try my_scope.allocator.alloc(f32, p.row_count + 1);
        errdefer if (!registered) my_scope.allocator.free(row_offsets);

        // row_heights: caller 传了就 copy，否则 empty slice 走 uniform 路径
        const owned_row_heights: []f32 = if (p.row_heights) |src| blk: {
            if (src.len != p.row_count) return error.RowHeightsLengthMismatch;
            const buf = try my_scope.allocator.alloc(f32, p.row_count);
            @memcpy(buf, src);
            break :blk buf;
        } else &[_]f32{};
        errdefer if (!registered and owned_row_heights.len > 0) my_scope.allocator.free(owned_row_heights);

        // scrollable pool
        const pool_nodes = try my_scope.allocator.alloc(*Node, scrollable_pool_size);
        errdefer if (!registered) my_scope.allocator.free(pool_nodes);
        const pool_bindings = try my_scope.allocator.alloc(?CellBinding, scrollable_pool_size);
        errdefer if (!registered) my_scope.allocator.free(pool_bindings);
        @memset(pool_bindings, null);

        // frozen col pool
        const fc_nodes = try my_scope.allocator.alloc(*Node, frozen_col_pool_size);
        errdefer if (!registered) my_scope.allocator.free(fc_nodes);
        const fc_bindings = try my_scope.allocator.alloc(?CellBinding, frozen_col_pool_size);
        errdefer if (!registered) my_scope.allocator.free(fc_bindings);
        @memset(fc_bindings, null);

        // frozen row pool
        const fr_nodes = try my_scope.allocator.alloc(*Node, frozen_row_pool_size);
        errdefer if (!registered) my_scope.allocator.free(fr_nodes);
        const fr_bindings = try my_scope.allocator.alloc(?CellBinding, frozen_row_pool_size);
        errdefer if (!registered) my_scope.allocator.free(fr_bindings);
        @memset(fr_bindings, null);

        // corner pool
        const cn_nodes = try my_scope.allocator.alloc(*Node, corner_pool_size);
        errdefer if (!registered) my_scope.allocator.free(cn_nodes);
        const cn_bindings = try my_scope.allocator.alloc(?CellBinding, corner_pool_size);
        errdefer if (!registered) my_scope.allocator.free(cn_bindings);
        @memset(cn_bindings, null);

        state.* = .{
            .allocator = my_scope.allocator,
            .cx = cx,
            .row_count = p.row_count,
            .col_count = p.col_count,
            .col_widths = owned_widths,
            .col_offsets = col_offsets,
            .cell_height = p.cell_height,
            .row_heights = owned_row_heights,
            .row_offsets = row_offsets,
            .overscan_rows = p.overscan_rows,
            .overscan_cols = p.overscan_cols,
            .frozen_rows = p.frozen_rows,
            .frozen_cols = p.frozen_cols,
            .root = root,
            .scroll_container = sa.container,
            .content = sa.content,
            .content_id = sa.content.id,
            .scroll_state = scroll_state_ptr,
            .pool_nodes = pool_nodes,
            .pool_bindings = pool_bindings,
            .pool_size = scrollable_pool_size,
            .frozen_col_pool_nodes = fc_nodes,
            .frozen_col_pool_bindings = fc_bindings,
            .frozen_col_pool_size = frozen_col_pool_size,
            .frozen_row_pool_nodes = fr_nodes,
            .frozen_row_pool_bindings = fr_bindings,
            .frozen_row_pool_size = frozen_row_pool_size,
            .corner_pool_nodes = cn_nodes,
            .corner_pool_bindings = cn_bindings,
            .corner_pool_size = corner_pool_size,
            .prev_range = .{},
            .initialized = false,
            .last_content_tx = 0,
            .last_content_ty = 0,
            .cell_render_fn = p.cell_render_fn.?,
            .cell_render_ctx = p.cell_render_ctx,
            .external_row_window = p.external_row_window,
        };
        state.rebuildColOffsets();
        state.rebuildRowOffsets();

        // ⚠️ 注册成功之后，上面那一长串 `errdefer free(...)` 必须**全部解除**：
        // 它们与这里登记的 destroy 是同一批 slice 的两个回收责任方。
        // 注册之后还有 5 处可失败调用（appendPoolNodes ×4 + onCleanup），
        // 任何一处失败都会让 errdefer 先释放一遍、稍后 scope dispose 再释放一遍
        // —— 实测 Segmentation fault in Grid destroy 的 a.free(col_offsets)
        //（下游编辑器的表格**渲染期** OOM sweep 首次照到，
        //  mount 期 sweep 走不到这条路）。
        // 用 registered 标志把两段责任切开。
        try my_scope.registerResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, a: Allocator) void {
                const s: *GridState = @ptrCast(@alignCast(ptr));
                a.free(s.col_widths);
                a.free(s.col_offsets);
                if (s.row_heights.len > 0) a.free(s.row_heights);
                a.free(s.row_offsets);
                a.free(s.pool_nodes);
                a.free(s.pool_bindings);
                a.free(s.frozen_col_pool_nodes);
                a.free(s.frozen_col_pool_bindings);
                a.free(s.frozen_row_pool_nodes);
                a.free(s.frozen_row_pool_bindings);
                a.free(s.corner_pool_nodes);
                a.free(s.corner_pool_bindings);
                a.destroy(s);
            }
        }.destroy);
        registered = true;

        // 依 paint order append：scrollable → frozen_col → frozen_row → corner
        // 后 append 的在 children 数组里靠后，先 paint 后者覆盖前者
        try appendPoolNodes(cx, sa.content, pool_nodes, "Grid.Cell");
        try appendPoolNodes(cx, sa.content, fc_nodes, "Grid.Cell.FrozenCol");
        try appendPoolNodes(cx, sa.content, fr_nodes, "Grid.Cell.FrozenRow");
        try appendPoolNodes(cx, sa.content, cn_nodes, "Grid.Cell.Corner");

        // 挂 on_before_render → 每帧算 visible range，diff pool
        sa.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
        sa.content.meta.per_frame.hooks.before_render.main = contentBeforeRender;
        try my_scope.onCleanup(GridState, state, detachGridBindings);

        // 初次立刻刷一遍（以免首帧空白）
        updateVisibleCells(state);

        return .{ .root = root, .state = state };
    }
}

// =========================================================================
// Core virtualization: update visible cells
// =========================================================================

fn contentBeforeRender(content_node: *Node) void {
    if (content_node.meta.per_frame.hooks.slots.anim_state) |raw| {
        const state: *GridState = @ptrCast(@alignCast(raw));
        updateVisibleCells(state);
    }
}

fn detachGridBindings(state: *GridState) void {
    // anim_state slot 可能已被框架其他清理路径置空（hook scope 之类），但 hook
    // 函数指针未必同时清。两个字段独立比对独立清。
    const content = state.content;
    const raw_state: *anyopaque = @ptrCast(state);
    if (content.meta.per_frame.hooks.before_render.main == contentBeforeRender) {
        content.meta.per_frame.hooks.before_render.main = null;
    }
    if (content.meta.per_frame.hooks.slots.anim_state == raw_state) {
        content.meta.per_frame.hooks.slots.anim_state = null;
    }
}

/// 每帧（或 update API 后）调用：
/// 1. 算 visible range（主滚动区，不含 frozen）
/// 2. 与 prev_range diff
/// 3. 回收滚出视口 / 非 frozen 的 pool cell
/// 4. 为新进入的 cell 从 pool 取节点 bind
/// 5. 冻结 cells 永远 active，且每帧更新其 translate 以"粘住"在视口边缘
fn updateVisibleCells(state: *GridState) void {
    const range = state.computeVisibleRange();
    const pinned_changed = !std.meta.eql(state.pinned_rows, state.prev_pinned_rows);
    const range_changed = !state.initialized or !range.eql(state.prev_range) or pinned_changed;

    // 有变化才需要 markLayoutDirty。
    // Phase 7 的 translate 更新会自己 markInteractionDirty + markRenderDirty，不用重复。
    var anything_changed = range_changed;

    // --- Scrollable body pool (最底层) ---
    if (range_changed) {
        // 需求量超过池容量时先扩容——静默跳过绑定 = 视口内 cell 整帧空白且
        // 永不自愈（同 md VL 的 pool 钳制教训）。
        var pinned_rows_extra: usize = 0;
        for (state.pinned_rows) |p| {
            if (p) |pr| {
                if (pr < range.row_start or pr >= range.row_end) pinned_rows_extra += 1;
            }
        }
        const need_rows = (range.row_end - range.row_start) + pinned_rows_extra;
        const need_cols = range.col_end - range.col_start;
        const needed = need_rows * need_cols;
        if (needed > state.pool_size) {
            growScrollablePool(state, needed) catch |err| {
                std.log.warn("[Grid] pool grow to {d} failed: {s} — cells may stay unbound", .{ needed, @errorName(err) });
            };
        }

        for (state.pool_bindings, 0..) |binding, i| {
            if (binding) |b| {
                const evict = if (state.rowIsPinned(b.row))
                    // pinned 行的列窗口仍然生效（横滚裁剪）
                    (b.col < range.col_start or b.col >= range.col_end)
                else
                    (b.row < range.row_start or b.row >= range.row_end or
                        b.col < range.col_start or b.col >= range.col_end);
                if (evict) {
                    hideCell(state.pool_nodes[i], state.cx);
                    state.pool_bindings[i] = null;
                }
            }
        }
        var ri = range.row_start;
        while (ri < range.row_end) : (ri += 1) {
            var ci = range.col_start;
            while (ci < range.col_end) : (ci += 1) {
                tryBindInPool(state, .scrollable, ri, ci);
            }
        }
        // pinned 行在窗口外时单独补绑（窗口内时上面的循环已覆盖）
        for (state.pinned_rows) |p| {
            const pr = p orelse continue;
            if (pr >= state.frozen_rows and (pr < range.row_start or pr >= range.row_end)) {
                var ci = range.col_start;
                while (ci < range.col_end) : (ci += 1) {
                    tryBindInPool(state, .scrollable, pr, ci);
                }
            }
        }
    }

    // --- Frozen col pool (scrollable rows × frozen cols) ---
    if (range_changed) {
        for (state.frozen_col_pool_bindings, 0..) |binding, i| {
            if (binding) |b| {
                if (!state.rowIsPinned(b.row) and
                    (b.row < range.row_start or b.row >= range.row_end))
                {
                    hideCell(state.frozen_col_pool_nodes[i], state.cx);
                    state.frozen_col_pool_bindings[i] = null;
                }
            }
        }
        if (state.frozen_cols > 0) {
            var ri = range.row_start;
            while (ri < range.row_end) : (ri += 1) {
                var fci: usize = 0;
                while (fci < state.frozen_cols) : (fci += 1) {
                    tryBindInPool(state, .frozen_col, ri, fci);
                }
            }
            for (state.pinned_rows) |p| {
                const pr = p orelse continue;
                if (pr >= state.frozen_rows and (pr < range.row_start or pr >= range.row_end)) {
                    var fci: usize = 0;
                    while (fci < state.frozen_cols) : (fci += 1) {
                        tryBindInPool(state, .frozen_col, pr, fci);
                    }
                }
            }
        }
    }

    // --- Frozen row pool (frozen rows × scrollable cols) ---
    if (range_changed) {
        for (state.frozen_row_pool_bindings, 0..) |binding, i| {
            if (binding) |b| {
                if (b.col < range.col_start or b.col >= range.col_end) {
                    hideCell(state.frozen_row_pool_nodes[i], state.cx);
                    state.frozen_row_pool_bindings[i] = null;
                }
            }
        }
        if (state.frozen_rows > 0) {
            var fri: usize = 0;
            while (fri < state.frozen_rows) : (fri += 1) {
                var ci = range.col_start;
                while (ci < range.col_end) : (ci += 1) {
                    tryBindInPool(state, .frozen_row, fri, ci);
                }
            }
        }
    }

    // --- Corner pool (frozen rows × frozen cols，永远绑定) ---
    // 初次 mount 时需要一次性绑定，之后不变
    if (!state.initialized and state.frozen_rows > 0 and state.frozen_cols > 0) {
        var fri: usize = 0;
        while (fri < state.frozen_rows) : (fri += 1) {
            var fci: usize = 0;
            while (fci < state.frozen_cols) : (fci += 1) {
                tryBindInPool(state, .corner, fri, fci);
            }
        }
    }

    // Phase: 每帧 **只当 content translate 变化时** 更新 frozen cells 的 translate。
    // idle 状态 translate 不变 → 无 op → 零 markDirty 开销。
    const content_tx = state.content.style.translate_x;
    const content_ty = state.content.style.translate_y;
    const translate_changed =
        content_tx != state.last_content_tx or content_ty != state.last_content_ty;
    if (translate_changed) {
        updateTranslateForPool(state.frozen_col_pool_bindings, state.frozen_col_pool_nodes, content_tx, content_ty, true, false);
        updateTranslateForPool(state.frozen_row_pool_bindings, state.frozen_row_pool_nodes, content_tx, content_ty, false, true);
        updateTranslateForPool(state.corner_pool_bindings, state.corner_pool_nodes, content_tx, content_ty, true, true);
        state.last_content_tx = content_tx;
        state.last_content_ty = content_ty;
        anything_changed = true;
    }

    state.prev_range = range;
    state.prev_pinned_rows = state.pinned_rows;
    state.initialized = true;
    if (anything_changed) state.content.markLayoutDirty();
}

/// 立即重跑一次可见 cell diff（等价于 content before_render hook 的那次调用）。
/// 用于宿主刚改完 external_row_window / pinned_row 又马上要读 cell 节点的场景
/// （命中测试按需绑定、进入编辑态）。
pub fn refreshVisibleCellsNow(state: *GridState) void {
    updateVisibleCells(state);
}

/// 扩容 scrollable pool 到至少 needed 个 slot（上限 MAX_POOL_SIZE）。
/// 新节点 append 到 content 尾部；bindings 初始为 null，由后续绑定循环填。
/// 仅支持无 frozen pool 的 Grid：children 顺序即 paint order，尾部追加会把
/// 新 scrollable cell 画到 frozen cell 之上。有 frozen 时保持旧行为（不扩容）。
fn growScrollablePool(state: *GridState, needed: usize) !void {
    if (state.frozen_col_pool_size > 0 or state.frozen_row_pool_size > 0 or
        state.corner_pool_size > 0)
    {
        // 有 frozen pool 时无法安全扩容（paint order 会错），但这意味着安全网
        // 失效——超估的 frozen grid 会静默空白，必须留下诊断痕迹。
        std.log.warn("[Grid] pool grow refused (frozen pools present): need={d} have={d}", .{ needed, state.pool_size });
        return;
    }
    const target = @min(MAX_POOL_SIZE, needed + 8);
    if (target <= state.pool_size) return;

    const alloc = state.allocator;
    const new_nodes = try alloc.alloc(*Node, target);
    errdefer alloc.free(new_nodes);
    const new_bindings = try alloc.alloc(?CellBinding, target);
    errdefer alloc.free(new_bindings);
    @memset(new_bindings, null);

    @memcpy(new_nodes[0..state.pool_size], state.pool_nodes[0..state.pool_size]);
    @memcpy(new_bindings[0..state.pool_size], state.pool_bindings[0..state.pool_size]);

    // 新增节点：与 mount 时的 appendPoolNodes 同构
    for (state.pool_size..target) |i| {
        const cell = try box(state.cx, .{
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
            .position = .absolute,
            .overflow_hidden = true,
        }, .{});
        cell.meta.ownership.meta.component_name = "Grid.Cell";
        try state.content.appendChild(state.cx.allocator, cell);
        new_nodes[i] = cell;
    }

    alloc.free(state.pool_nodes);
    alloc.free(state.pool_bindings);
    state.pool_nodes = new_nodes;
    state.pool_bindings = new_bindings;
    state.pool_size = target;
    state.content.markLayoutDirty();
}

fn updateTranslateForPool(
    bindings: []const ?CellBinding,
    nodes: []const *Node,
    content_tx: f32,
    content_ty: f32,
    cancel_x: bool,
    cancel_y: bool,
) void {
    for (bindings, 0..) |binding, i| {
        if (binding != null) {
            const node = nodes[i];
            const new_tx: f32 = if (cancel_x) -content_tx else 0;
            const new_ty: f32 = if (cancel_y) -content_ty else 0;
            if (node.style.translate_x != new_tx or node.style.translate_y != new_ty) {
                node.style.translate_x = new_tx;
                node.style.translate_y = new_ty;
                node.markCompositePropDirty();
            }
        }
    }
}

pub const PoolKind = enum { scrollable, frozen_col, frozen_row, corner };

fn tryBindInPool(state: *GridState, kind: PoolKind, row: usize, col: usize) void {
    const bindings = poolBindings(state, kind);
    const nodes = poolNodes(state, kind);
    // 已存在绑定则 skip
    for (bindings) |b| {
        if (b) |bb| if (bb.row == row and bb.col == col) return;
    }
    // 找空 slot
    var slot: ?usize = null;
    for (bindings, 0..) |b, i| {
        if (b == null) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse {
        // 池满静默跳过 = 该 cell 整帧空白。计数暴露给诊断（视口空 cell 的第一嫌疑）。
        state.pool_exhausted_count +%= 1;
        return;
    };
    // 防御：nodes 和 bindings 长度应相同（mount 时同 size alloc），保险起见防越界
    if (idx >= nodes.len) return;
    poolBindingsMut(state, kind)[idx] = .{ .row = row, .col = col };
    configureCell(state, nodes[idx], row, col);
}

fn poolBindings(state: *const GridState, kind: PoolKind) []const ?CellBinding {
    return switch (kind) {
        .scrollable => state.pool_bindings,
        .frozen_col => state.frozen_col_pool_bindings,
        .frozen_row => state.frozen_row_pool_bindings,
        .corner => state.corner_pool_bindings,
    };
}

fn poolBindingsMut(state: *GridState, kind: PoolKind) []?CellBinding {
    return switch (kind) {
        .scrollable => state.pool_bindings,
        .frozen_col => state.frozen_col_pool_bindings,
        .frozen_row => state.frozen_row_pool_bindings,
        .corner => state.corner_pool_bindings,
    };
}

fn poolNodes(state: *const GridState, kind: PoolKind) []const *Node {
    return switch (kind) {
        .scrollable => state.pool_nodes,
        .frozen_col => state.frozen_col_pool_nodes,
        .frozen_row => state.frozen_row_pool_nodes,
        .corner => state.corner_pool_nodes,
    };
}

/// 将 cell 节点配置为 (row, col) 的可视 cell。
/// 不设 z_index —— render order 由 node 在 content.children 里的位置决定（memory:
/// `feedback_listening_and_diff_paths.md` 说过 z_index > 0 会跳出祖先 clip）。
fn configureCell(state: *GridState, node: *Node, row: usize, col: usize) void {
    // 越界防御：几何变化（行列数缩小）与 pin/窗口失效之间存在一帧窗口期，
    // 不能依赖 cell_render_fn（应用回调）自己做边界检查。
    if (row >= state.row_count or col >= state.col_count) return;
    const x = state.col_offsets[col];
    const y = state.rowTop(row);
    const w = state.col_widths[col];
    const h = state.rowHeight(row);

    node.style.width = .{ .px = w };
    node.style.height = .{ .px = h };
    node.style.position = .absolute;
    node.style.margin = .{ .left = x, .top = y, .right = 0, .bottom = 0 };
    node.style.overflow_hidden = true;

    // 清旧内容
    clearNodeChildren(node, state.cx);
    node.setText(null);

    state.cell_render_fn(node, row, col, state.cx, state.cell_render_ctx);
    node.markLayoutDirty();
}

fn hideCell(node: *Node, cx: *Cx) void {
    node.style.width = .{ .px = 0 };
    node.style.height = .{ .px = 0 };
    node.style.translate_x = 0;
    node.style.translate_y = 0;
    node.style.overflow_hidden = true;
    clearNodeChildren(node, cx);
    node.setText(null);
}

fn applyGeometryToPool(state: *GridState, bindings: []const ?CellBinding, nodes: []const *Node) void {
    for (bindings, 0..) |b, i| {
        if (b) |bb| {
            if (i >= nodes.len or bb.row >= state.row_count or bb.col >= state.col_count) continue;
            const node = nodes[i];
            node.style.width = .{ .px = state.col_widths[bb.col] };
            node.style.height = .{ .px = state.rowHeight(bb.row) };
            node.style.margin = .{
                .left = state.col_offsets[bb.col],
                .top = state.rowTop(bb.row),
                .right = 0,
                .bottom = 0,
            };
            node.markLayoutDirty();
        }
    }
}

fn applyGeometryToActivePools(state: *GridState) void {
    applyGeometryToPool(state, state.pool_bindings, state.pool_nodes);
    applyGeometryToPool(state, state.frozen_col_pool_bindings, state.frozen_col_pool_nodes);
    applyGeometryToPool(state, state.frozen_row_pool_bindings, state.frozen_row_pool_nodes);
    applyGeometryToPool(state, state.corner_pool_bindings, state.corner_pool_nodes);
    state.content.markLayoutDirty();
}

// =========================================================================
// Post-mount geometry API
// 框架自己的布局数据（col_widths/row_heights/offsets/pool bindings）必须由
// 框架 mutator 维护——此前这些实现散落在应用层（下游编辑器 ui_compat）直接翻
// GridState 内部字段，computeVisibleRange / 外部行窗口 / pin 无法信任自己的
// 不变量。所有 mutator 末尾统一走 clampAfterGeometryChange 使 pin/窗口失效。
// =========================================================================

/// 行列数 / 列宽整体变化（结构性更新）。行高保留旧值，缺省补 cell_height。
pub fn updateGeometry(state: *GridState, rows: usize, cols: usize, widths: []const f32) !void {
    if (widths.len != cols) return error.ColWidthsLengthMismatch;
    const allocator = state.allocator;
    const new_widths = try allocator.alloc(f32, cols);
    errdefer allocator.free(new_widths);
    const new_col_offsets = try allocator.alloc(f32, cols + 1);
    errdefer allocator.free(new_col_offsets);
    const new_row_heights = try allocator.alloc(f32, rows);
    errdefer allocator.free(new_row_heights);
    const new_row_offsets = try allocator.alloc(f32, rows + 1);
    errdefer allocator.free(new_row_offsets);

    @memcpy(new_widths, widths);
    for (new_row_heights, 0..) |*height, row| {
        height.* = if (row < state.row_heights.len) state.row_heights[row] else state.cell_height;
    }
    allocator.free(state.col_widths);
    allocator.free(state.col_offsets);
    if (state.row_heights.len > 0) allocator.free(state.row_heights);
    allocator.free(state.row_offsets);
    state.col_widths = new_widths;
    state.col_offsets = new_col_offsets;
    state.row_heights = new_row_heights;
    state.row_offsets = new_row_offsets;
    state.row_count = rows;
    state.col_count = cols;
    state.rebuildColOffsets();
    state.rebuildRowOffsets();
    state.syncContentSize();
    state.clampAfterGeometryChange();
    applyGeometryToActivePools(state);
    state.initialized = false;
    state.cx.needs_redraw = true;
}

/// 仅列宽变化（行列数不变）。
pub fn updateColWidths(state: *GridState, widths: []const f32) void {
    if (widths.len != state.col_count) return;
    @memcpy(state.col_widths, widths);
    state.rebuildColOffsets();
    state.syncContentSize();
    applyGeometryToActivePools(state);
    state.initialized = false;
    state.cx.needs_redraw = true;
}

/// 仅行高变化（行数不变）。
pub fn updateRowHeights(state: *GridState, heights: []const f32) !void {
    if (heights.len != state.row_count) return error.RowHeightsLengthMismatch;
    if (state.row_heights.len != state.row_count) {
        if (state.row_heights.len > 0) state.allocator.free(state.row_heights);
        state.row_heights = try state.allocator.alloc(f32, state.row_count);
    }
    @memcpy(state.row_heights, heights);
    state.rebuildRowOffsets();
    state.syncContentSize();
    state.clampAfterGeometryChange();
    applyGeometryToActivePools(state);
    state.initialized = false;
    state.cx.needs_redraw = true;
}

/// 重渲染单个 pooled cell：replace-render（先清后渲染），绝不 append-render。
fn rerenderBoundCell(state: *GridState, node: *Node, cell: CellBinding) void {
    // tail loop：Cx.freeNode 可能在 before-render tick 中原地改 children.items
    while (node.children.items.len > 0) {
        const child = node.children.items[node.children.items.len - 1];
        state.cx.detachChild(node, child);
        state.cx.freeNode(child);
    }
    node.setText(null);
    if (cell.row >= state.row_count or cell.col >= state.col_count) return;
    state.cell_render_fn(node, cell.row, cell.col, state.cx, state.cell_render_ctx);
    node.markLayoutDirty();
}

/// 重渲染所有当前 bound 的 cell（数据变化后内容级刷新，不改绑定）。
pub fn refreshBoundCells(state: *GridState) void {
    const refresh = struct {
        fn pool(grid: *GridState, bindings: []const ?CellBinding, nodes: []const *Node) void {
            for (bindings, 0..) |binding, index| {
                if (binding) |cell| {
                    if (index < nodes.len) rerenderBoundCell(grid, nodes[index], cell);
                }
            }
        }
    }.pool;
    refresh(state, state.pool_bindings, state.pool_nodes);
    refresh(state, state.frozen_col_pool_bindings, state.frozen_col_pool_nodes);
    refresh(state, state.frozen_row_pool_bindings, state.frozen_row_pool_nodes);
    refresh(state, state.corner_pool_bindings, state.corner_pool_nodes);
    state.cx.needs_redraw = true;
}

/// 重渲染指定 (row, col) 的 cell（若当前 bound）。
pub fn updateCellContent(state: *GridState, row: usize, col: usize) void {
    const refresh = struct {
        fn pool(grid: *GridState, bindings: []const ?CellBinding, nodes: []const *Node, r: usize, c: usize) void {
            for (bindings, 0..) |binding, index| {
                if (binding) |cell| {
                    if (cell.row == r and cell.col == c and index < nodes.len) {
                        rerenderBoundCell(grid, nodes[index], cell);
                        return;
                    }
                }
            }
        }
    }.pool;
    refresh(state, state.pool_bindings, state.pool_nodes, row, col);
    refresh(state, state.frozen_col_pool_bindings, state.frozen_col_pool_nodes, row, col);
    refresh(state, state.frozen_row_pool_bindings, state.frozen_row_pool_nodes, row, col);
    refresh(state, state.corner_pool_bindings, state.corner_pool_nodes, row, col);
    state.cx.needs_redraw = true;
}

// =========================================================================
// 内部工具
// =========================================================================

fn clearNodeChildren(node: *Node, cx: *Cx) void {
    while (node.children.items.len > 0) {
        const child = node.children.items[node.children.items.len - 1];
        cx.detachChild(node, child);
        cx.freeNode(child);
    }
    node.markRuntimeIndexDirty();
    node.markLayoutDirty();
}

test "Grid: scope dispose detaches content before-render hook" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    const mounted = try mountGrid(.{
        .row_count = 4,
        .col_count = 3,
        .col_widths = &.{ 80, 90, 100 },
        .width = 240,
        .height = 120,
        .cell_render_fn = struct {
            fn render(_: *Node, _: usize, _: usize, _: *Cx, _: ?*anyopaque) void {}
        }.render,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.root);

    const content = mounted.state.content;

    scope.dispose();
    scope_disposed = true;

    try std.testing.expect(content.meta.per_frame.hooks.before_render.main == null);
    try std.testing.expect(content.meta.per_frame.hooks.slots.anim_state == null);
}

pub fn hitTestCell(state: *const GridState, local_x: f32, local_y: f32) ?CellBinding {
    if (local_x < 0 or local_y < 0 or state.row_count == 0 or state.col_count == 0 or
        local_y >= state.totalContentHeight() or local_x >= state.totalContentWidth()) return null;

    var row_low: usize = 0;
    var row_high = state.row_count;
    while (row_low < row_high) {
        const middle = row_low + (row_high - row_low) / 2;
        if (state.row_offsets[middle + 1] > local_y) row_high = middle else row_low = middle + 1;
    }

    var col_low: usize = 0;
    var col_high = state.col_count;
    while (col_low < col_high) {
        const middle = col_low + (col_high - col_low) / 2;
        if (state.col_offsets[middle + 1] > local_x) col_high = middle else col_low = middle + 1;
    }
    if (row_low >= state.row_count or col_low >= state.col_count) return null;
    return .{ .row = row_low, .col = col_low };
}

pub fn getCellNode(state: *const GridState, row: usize, col: usize) ?*Node {
    const binding_sets = [_][]const ?CellBinding{
        state.pool_bindings,
        state.frozen_col_pool_bindings,
        state.frozen_row_pool_bindings,
        state.corner_pool_bindings,
    };
    const node_sets = [_][]const *Node{
        state.pool_nodes,
        state.frozen_col_pool_nodes,
        state.frozen_row_pool_nodes,
        state.corner_pool_nodes,
    };
    for (binding_sets, node_sets) |bindings, nodes| {
        for (bindings, 0..) |binding, index| {
            const cell = binding orelse continue;
            if (cell.row == row and cell.col == col and index < nodes.len) return nodes[index];
        }
    }
    return null;
}

test "Grid: frozen 区宽/高于视口时可见区间不下溢" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const widths = [_]f32{120} ** 8;
    const mounted = try mountGrid(.{
        .row_count = 10,
        .col_count = 8,
        .col_widths = &widths,
        .cell_height = 40,
        .frozen_rows = 5,
        .frozen_cols = 5,
        .width = 100,
        .height = 100,
        .cell_render_fn = struct {
            fn render(_: *Node, _: usize, _: usize, _: *Cx, _: ?*anyopaque) void {}
        }.render,
    }, scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.root);

    const state = mounted.state;
    state.scroll_state.viewport_width = 100;
    state.scroll_state.viewport_height = 100;
    const range = state.computeVisibleRange();
    try std.testing.expect(range.col_end >= range.col_start);
    try std.testing.expect(range.row_end >= range.row_start);
    updateVisibleCells(state); // 旧实现在 `col_end - col_start` 处下溢 panic

    // 行列数缩到 frozen 以下：frozen 被夹住，区间仍合法
    try updateGeometry(state, 3, 2, &.{ 120, 120 });
    try std.testing.expect(state.frozen_rows <= 3 and state.frozen_cols <= 2);
    const r2 = state.computeVisibleRange();
    try std.testing.expect(r2.row_end <= state.row_count and r2.col_end <= state.col_count);
    updateVisibleCells(state);
}

test "Grid: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("grid", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try mountGrid(.{ .row_count = 4, .col_count = 3, .col_widths = &.{ 80, 90, 100 }, .width = 240, .height = 120, .cell_render_fn = struct {
                fn render(_: *Node, _: usize, _: usize, _: *Cx, _: ?*anyopaque) void {}
            }.render }, scope, cx);
            return r.root;
        }
    }.m);
}
