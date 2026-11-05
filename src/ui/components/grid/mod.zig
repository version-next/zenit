/// Grid, business component: 2D virtualized table based on ScrollArea + cell pool.
/// Design reference: Google Sheets canvas / ag-grid / LinkedIn Rooster
/// - Double Viewport: outer ScrollArea(.both) + inner content translate_x/y
/// - Cell Culling: compute visible range from scroll position + viewport, keep only pool nodes
/// - Frozen Panes: independent absolute layer, not affected by translate
///
/// Retained-mode mount() API:
/// ```
/// const g = try Grid(.{
///     .row_count = 1000,
///     .col_count = 100,
///     .col_widths = &col_ws,
///     .cell_render_fn = myCellRender,
/// }).mount(scope, cx);
/// try parent.appendChild(alloc, g.root);
///
/// ```
///
/// Virtualization: pool_size = (viewport_rows + 2 * overscan) x (viewport_cols + 2 * overscan).
/// On scroll, cells reposition via absolute margin; no node rebuild, no allocation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
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
pub const ScopedCellRenderFn = state_mod.ScopedCellRenderFn;
pub const CellBinding = state_mod.CellBinding;
pub const VisibleRange = state_mod.VisibleRange;
pub const ExternalRowWindow = state_mod.ExternalRowWindow;
pub const HostViewport = state_mod.HostViewport;
pub const PinOwner = state_mod.PinOwner;

pub const GridResult = struct {
    root: *Node,
    state: *GridState,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: GridResult) core.ViewParts {
        return .{ .root = self.root };
    }
};

/// Pool size limit (prevent memory explosion).
const MAX_POOL_SIZE: usize = 2000;

fn appendPoolNodes(cx: *Cx, content: *Node, nodes: []*Node, comp_name: []const u8) !void {
    for (0..nodes.len) |i| {
        const cell_node = try box(cx, .{
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
            .position = .absolute,
            .overflow_hidden = true,
        }, .{});
        // append fails: this cell_node orphaned (mounted ones owned by
        // content, tree teardown cleans). Editor table render sweep measured:
        // largest of 101 total leaks here.
        errdefer cx.freeNode(cell_node);
        cell_node.meta.ownership.meta.component_name = comp_name;
        try content.appendChild(cx.allocator, cell_node);
        // Attach before writing to pool array (prepare-then-publish):
        // failure leaves dangling pointer in nodes[i], later detachGridBindings
        // traversal steps on it.
        nodes[i] = cell_node;
    }
}

/// Create virtualized Grid: `W.Grid(.{ .row_count = n, .col_count = m,
/// ... }).mount(scope, cx)`, returns root + state handle.
pub fn Grid(props: anytype) GridBuilder {
    return .{ .props = @import("../../reactive.zig").props.coerce(GridProps, props) };
}

pub const GridBuilder = struct {
    props: GridProps,

    /// `ui.view` integration: the cell function returns a view element, used as a direct ui.view
    /// child: `W.Grid(.{ .row_count = r, .col_count = c, .col_widths = &ws }).cells(ctx, cell)`.
    /// Cell function: `fn (Ctx, row: usize, col: usize) E` / `fn (usize, usize) E` (ctx {}),
    /// or component `fn (Ctx, usize, usize, *Scope, *Cx) !*Node`. Each cell's content gets a child
    /// scope of the grid's own scope, bound to the content root: a pool cell swap rebind/refresh
    /// (clear-then-render) destroys the scope and its contained effects, and freeing the grid
    /// root retires all of them with the grid.
    pub fn cells(self: GridBuilder, ctx: anytype, comptime cell_fn: anytype) GridCells(@TypeOf(ctx), cell_fn) {
        return .{ .builder = self, .ctx = ctx };
    }

    pub fn mount(self: GridBuilder, scope: *Scope, cx: *Cx) !GridResult {
        const f = self.props.cell_render_fn orelse return error.MissingCellRenderFn;
        return mountImpl(self.props, .{ .plain = f }, scope, cx);
    }
};

/// `GridBuilder.cells` result: integrated via `viewMount` into ui.view
/// (use `v.ref` to get GridResult).
pub fn GridCells(comptime Ctx: type, comptime cell_fn: anytype) type {
    const what = "Grid.cells";
    _ = view.callbackIsComponent(@TypeOf(cell_fn), if (Ctx == void) 2 else 3, what);
    return struct {
        builder: GridBuilder,
        ctx: Ctx,

        const Self = @This();
        const State = view.CallbackState(Ctx);

        pub fn viewMount(self: Self, scope: *Scope, cx: *Cx) !GridResult {
            const st = try State.create(scope, self.ctx);
            var p = self.builder.props;
            p.cell_render_fn = null;
            p.cell_render_ctx = @ptrCast(st);
            return mountImpl(p, .{ .scoped = render }, scope, cx);
        }

        /// Content scopes open under the grid's own scope (`grid_scope`), not the caller's:
        /// freeing the grid root retires every bound cell's content with it.
        fn render(node: *Node, row: usize, col: usize, grid_scope: *Scope, cx: *Cx, user: ?*anyopaque) void {
            const st: *State = @ptrCast(@alignCast(user.?));
            view.renderInto(grid_scope, cx, node, cell_fn, st.ctx, .{ row, col }, what) catch |err| {
                std.log.warn("Grid.cells: cell ({d},{d}) render failed: {s}", .{ row, col, @errorName(err) });
            };
        }
    };
}

fn mountImpl(props: GridProps, cell_render: state_mod.CellRender, scope: *Scope, cx: *Cx) !GridResult {
    const my_scope = try scope.childScope();
    const p = props;
    {
        if (p.col_widths.len != p.col_count) return error.ColWidthsLengthMismatch;

        // Outer root
        var root_style = core.BoxStyle{
            .direction = .column,
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
        };
        if (p.width) |w| root_style.width = .{ .px = w };
        if (p.height) |h| root_style.height = .{ .px = h };
        // Budget content total size
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

        // Grid defaults dual-axis scroll; business caller can narrow
        // scroll_direction to single-axis.
        var sa: scroll_area.ScrollAreaResult = undefined;
        const root = try view.render(my_scope, cx, view.box(.{ .style = root_style }, view.capture(&sa, scroll_area.ScrollArea(.{
            .width = p.width,
            .height = p.height,
            .direction = p.scroll_direction,
            .content_width = content_w,
            .content_height = content_h,
        }))));
        // root is returned Grid subtree root, no one owns until success. Below:
        // ScrollArea, four cell pools (thousands each), registerResource, onCleanup;
        // any failure orphans whole. Editor table render sweep measured: most of
        // 99 leaks from here, appendPoolNodes 1207 just visible (cells mounted below).
        errdefer cx.freeNode(root);
        root.meta.ownership.meta.component_name = "Grid";
        // Scope lifetime is bound to the root node (like ScrollArea).
        //
        // Without this: when a caller does freeNode/clearChildren on the Grid subtree, my_scope is
        // not
        // disposed and stays in the parent scope's children; its onCleanup(detachGridBindings)
        // holds
        // the state.content node pointer, which is freed with the subtree. A later parent dispose
        // (virtual list recycleSlot) runs the cleanup, dereferences the freed node and hits
        // EXC_BAD_ACCESS. With the binding, freeNode(root) disposes my_scope first (nodes still
        // valid, detach runs) and the parent dispose skips it via the disposed flag.
        try core.bindScopeToNode(my_scope, root);

        sa.container.meta.ownership.meta.component_name = "Grid.ScrollArea";

        sa.content.meta.ownership.meta.component_name = "Grid.Content";
        sa.content.style.width = .{ .px = content_w };
        sa.content.style.height = .{ .px = content_h };
        sa.content.style.flex_shrink = 0;
        // content cells use absolute positioning; content direction no longer
        // matters
        sa.content.style.direction = .column;

        const scroll_event_ctx: *scroll_area.ScrollEventCtx = @ptrCast(@alignCast(sa.container.behavior.events.event_context.?));
        const scroll_state_ptr = scroll_event_ctx.state;
        scroll_state_ptr.external_content_width = true;
        scroll_state_ptr.external_content_height = true;

        // frozen validation
        if (p.frozen_rows > p.row_count) return error.FrozenRowsExceedsRowCount;
        if (p.frozen_cols > p.col_count) return error.FrozenColsExceedsColCount;

        // Estimate pool size
        const viewport_w_est = p.width orelse 400;
        const viewport_h_est = p.height orelse 300;
        const avg_col_w: f32 = if (p.col_count > 0) content_w / @as(f32, @floatFromInt(p.col_count)) else 100;
        const visible_cols_est: usize = @max(1, @as(usize, @intFromFloat(@ceil(viewport_w_est / @max(avg_col_w, 1)))));
        const visible_rows_est: usize = if (p.row_window_height_hint) |hint| blk: {
            // External row window host: pool by window height / avg row height, not
            // Grid's own height (that's full content, bloats pool to all rows).
            // Window change over-estimates then runtime expand.
            const avg_row_h: f32 = if (p.row_count > 0)
                content_h / @as(f32, @floatFromInt(p.row_count))
            else
                p.cell_height;
            break :blk @max(1, @as(usize, @intFromFloat(@ceil(hint / @max(avg_row_h, 1)))));
        } else @max(1, @as(usize, @intFromFloat(@ceil(viewport_h_est / @max(p.cell_height, 1)))));
        // The pool can't usefully exceed actual rows/cols: excess cells never bind data, yet stay
        // as
        // zero-size nodes in the tree, swept by tick/paint-sync/interaction-sync. E.g. an editor
        // doc
        // with 25 2x2 markdown tables, each Grid sized 50 cells by viewport: 900 Grid.Cell pool
        // nodes,
        // synced_nodes ~1200 -> 4451, phase_sync 1.1ms -> 6.5ms. So tighten by row/col (2x2 only
        // 4).
        const pool_rows = @min(p.row_count, visible_rows_est + 2 * p.overscan_rows);
        const pool_cols = @min(p.col_count, visible_cols_est + 2 * p.overscan_cols);
        // Four pool types allocated separately (append per paint order)
        const scrollable_pool_size = @min(MAX_POOL_SIZE, pool_rows * pool_cols);
        const frozen_col_pool_size = @min(MAX_POOL_SIZE, p.frozen_cols * pool_rows);
        const frozen_row_pool_size = @min(MAX_POOL_SIZE, p.frozen_rows * pool_cols);
        const corner_pool_size = @min(MAX_POOL_SIZE, p.frozen_rows * p.frozen_cols);

        // registered: after success, following errdefer all defer to scope's
        // destroy (single batch slice = one cleanup). Declare before first use.
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

        // row_heights: caller provided copied, else empty slice uses uniform path
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
            .cell_render = cell_render,
            .cell_render_ctx = p.cell_render_ctx,
            .scope = my_scope,
            .external_row_window = p.external_row_window,
        };
        state.rebuildColOffsets();
        state.rebuildRowOffsets();

        // WARNING: after `registered`, the long errdefer above must **all unwind**: the same batch
        // slice would have two cleanup responsibilities. 5 more fail points follow (appendPoolNodes
        // x4
        // + onCleanup); on any failure, errdefer and scope dispose would both free, causing a
        // segfault in Grid destroy at a.free(col_offsets). The `registered` flag splits
        // responsibility.
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

        // Append per paint order: scrollable -> frozen_col -> frozen_row ->
        // corner. Later append -> children array later -> painted last covers first.
        try appendPoolNodes(cx, sa.content, pool_nodes, "Grid.Cell");
        try appendPoolNodes(cx, sa.content, fc_nodes, "Grid.Cell.FrozenCol");
        try appendPoolNodes(cx, sa.content, fr_nodes, "Grid.Cell.FrozenRow");
        try appendPoolNodes(cx, sa.content, cn_nodes, "Grid.Cell.Corner");

        // Wire on_before_render -> each frame calc visible range, diff pool
        sa.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
        sa.content.meta.per_frame.hooks.before_render.main = contentBeforeRender;
        try my_scope.onCleanup(GridState, state, detachGridBindings);

        // First frame immediate refresh (avoid blank first frame)
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
    // anim_state slot might be cleared by framework other paths (hook
    // scope), but hook function pointer not necessarily synced. Two fields
    // check/clear independently.
    const content = state.content;
    const raw_state: *anyopaque = @ptrCast(state);
    if (content.meta.per_frame.hooks.before_render.main == contentBeforeRender) {
        content.meta.per_frame.hooks.before_render.main = null;
    }
    if (content.meta.per_frame.hooks.slots.anim_state == raw_state) {
        content.meta.per_frame.hooks.slots.anim_state = null;
    }
}

/// Each frame (or after update API): (1) calc visible range (main scroll,
/// no frozen) (2) diff with prev_range (3) reclaim pool cells scrolled out /
/// non-frozen (4) new cells entering: take nodes from pool bind (5) frozen
/// cells forever active, each frame update translate to "stick" at viewport.
fn updateVisibleCells(state: *GridState) void {
    const range = state.computeVisibleRange();
    const pinned_changed = !std.meta.eql(state.pinned_rows, state.prev_pinned_rows);
    const range_changed = !state.initialized or !range.eql(state.prev_range) or pinned_changed;

    // Only mark layout dirty on changes.
    // Phase 7 translate updates auto-mark interaction and render dirty; no need to repeat.
    var anything_changed = range_changed;

    // --- Scrollable body pool (lowest level) ---
    if (range_changed) {
        // Demand exceeds capacity: expand first, silent skip bind = viewport cell
        // blank frame, never self-heal (md VL pool cap lesson).
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
                    // pinned row's column window still applies (horizontal scroll clip)
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
        // pinned row outside window: separate bind (in-window loop above covers)
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

    // --- Corner pool (frozen rows x frozen cols, always bind) ---
    // one-time bind at mount, unchanged after
    if (!state.initialized and state.frozen_rows > 0 and state.frozen_cols > 0) {
        var fri: usize = 0;
        while (fri < state.frozen_rows) : (fri += 1) {
            var fci: usize = 0;
            while (fci < state.frozen_cols) : (fci += 1) {
                tryBindInPool(state, .corner, fri, fci);
            }
        }
    }

    // Phase: each frame **only when content translate changes** update
    // frozen cells translate. idle -> no change -> zero markDirty cost.
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

/// Re-run visible cell diff immediately (equiv to content
/// before_render hook). Used when host just changed
/// external_row_window/pinned_row then immediately needs cell nodes
/// (hit-test eager bind, enter edit).
pub fn refreshVisibleCellsNow(state: *GridState) void {
    updateVisibleCells(state);
}

/// Expand scrollable pool to at least needed slots (cap MAX_POOL_SIZE).
/// New nodes append to content tail; bindings initially null, filled by loop.
/// Only no-frozen-pool Grid: children order = paint order, tail append
/// puts new scrollable above frozen. With frozen: keep old (no expand).
fn growScrollablePool(state: *GridState, needed: usize) !void {
    if (state.frozen_col_pool_size > 0 or state.frozen_row_pool_size > 0 or
        state.corner_pool_size > 0)
    {
        // With frozen pool can't safely expand (paint order breaks), but safe
        // net fails, over-estimated frozen grid silently blank, must leave
        // diagnostic trace.
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

    // New nodes: homomorphic to mount's appendPoolNodes
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
    // Existing binding: skip
    for (bindings) |b| {
        if (b) |bb| if (bb.row == row and bb.col == col) return;
    }
    // Find empty slot
    var slot: ?usize = null;
    for (bindings, 0..) |b, i| {
        if (b == null) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse {
        // Pool full silent skip = cell blank frame. Expose count for diagnosis
        // (viewport blank cell's top suspect).
        state.pool_exhausted_count +%= 1;
        return;
    };
    // Defense: nodes and bindings same length (mount alloc same size),
    // defensive bounds check.
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

/// Configure cell node as visible (row, col). Don't set z_index; render
/// order by node position in content.children (memory:
/// feedback_listening_and_diff_paths.md z_index > 0 exits ancestor clip).
fn configureCell(state: *GridState, node: *Node, row: usize, col: usize) void {
    // Bounds defense: geometry change (rows/cols shrink) and pin/window
    // invalidation one-frame window, can't rely on cell_render_fn boundary.
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

    // Clear old content
    clearNodeChildren(node, state.cx);
    node.setText(null);

    state.renderCell(node, row, col);
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

// Post-mount geometry API.
// Framework layout data (col_widths/row_heights/offsets/pool bindings) must be maintained by
// framework mutators; app code must not touch GridState internals directly, or
// computeVisibleRange / external row window / pin can't trust the invariants.
// All mutators call clampAfterGeometryChange at the end to invalidate pin/window.

/// rows/cols / column widths structural change. Row heights keep old,
/// default cell_height.
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

/// Column widths only (rows/cols unchanged).
pub fn updateColWidths(state: *GridState, widths: []const f32) void {
    if (widths.len != state.col_count) return;
    @memcpy(state.col_widths, widths);
    state.rebuildColOffsets();
    state.syncContentSize();
    applyGeometryToActivePools(state);
    state.initialized = false;
    state.cx.needs_redraw = true;
}

/// Row heights only (row count unchanged).
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

/// Re-render single pooled cell: replace-render (clear-then-render),
/// never append-render.
fn rerenderBoundCell(state: *GridState, node: *Node, cell: CellBinding) void {
    // tail loop: Cx.freeNode might in-place modify children.items during
    // before-render tick
    while (node.children.items.len > 0) {
        const child = node.children.items[node.children.items.len - 1];
        state.cx.detachChild(node, child);
        state.cx.freeNode(child);
    }
    node.setText(null);
    if (cell.row >= state.row_count or cell.col >= state.col_count) return;
    state.renderCell(node, cell.row, cell.col);
    node.markLayoutDirty();
}

/// Re-render all currently bound cells (data change content refresh,
/// no rebind).
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

/// Re-render (row, col) cell (if currently bound).
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

// Internal utilities

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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    const mounted = try Grid(.{
        .row_count = 4,
        .col_count = 3,
        .col_widths = &.{ 80, 90, 100 },
        .width = 240,
        .height = 120,
        .cell_render_fn = struct {
            fn render(_: *Node, _: usize, _: usize, _: *Cx, _: ?*anyopaque) void {}
        }.render,
    }).mount(scope, ctx);
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
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const widths = @as([8]f32, @splat(120));
    const mounted = try Grid(.{
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
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.root);

    const state = mounted.state;
    state.scroll_state.viewport_width = 100;
    state.scroll_state.viewport_height = 100;
    const range = state.computeVisibleRange();
    try std.testing.expect(range.col_end >= range.col_start);
    try std.testing.expect(range.row_end >= range.row_start);
    updateVisibleCells(state); // Old implementation panic'd at `col_end - col_start` underflow

    // Rows/cols shrink below frozen: frozen pinched, range still valid
    try updateGeometry(state, 3, 2, &.{ 120, 120 });
    try std.testing.expect(state.frozen_rows <= 3 and state.frozen_cols <= 2);
    const r2 = state.computeVisibleRange();
    try std.testing.expect(r2.row_end <= state.row_count and r2.col_end <= state.col_count);
    updateVisibleCells(state);
}

test "Grid: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("grid", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Grid(.{ .row_count = 4, .col_count = 3, .col_widths = &.{ 80, 90, 100 }, .width = 240, .height = 120, .cell_render_fn = struct {
                fn render(_: *Node, _: usize, _: usize, _: *Cx, _: ?*anyopaque) void {}
            }.render }).mount(scope, cx);
            return r.root;
        }
    }.m);
}

test "LC3C Grid external row window subtracts layout border" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const mounted = try Grid(.{
        .row_count = 10,
        .col_count = 1,
        .col_widths = &.{50},
        .width = 100,
        .height = 100,
        .cell_render_fn = struct {
            fn render(_: *Node, _: usize, _: usize, _: *Cx, _: ?*anyopaque) void {}
        }.render,
    }).mount(scope, cx);
    cx.root = mounted.root;
    const state = mounted.state;
    state.scroll_container.style.padding = core.Padding.all(10);
    state.scroll_container.style.border = .{ .width = 5 };
    state.pinned_rows[@backingInt(PinOwner.hit_test)] = 5;
    state.setExternalRowWindowFromHost(.{ .scroll_y = 200, .height = 80, .margin = 3 }, 100);
    try std.testing.expectEqual(@as(f32, 82), state.external_row_window.?.top);
    try std.testing.expectEqual(@as(f32, 168), state.external_row_window.?.bottom);
    try std.testing.expectEqual(@as(?usize, null), state.pinned_rows[@backingInt(PinOwner.hit_test)]);
    state.scroll_container.style.border.overlay = true;
    state.setExternalRowWindowFromHost(.{ .scroll_y = 200, .height = 80, .margin = 3 }, 100);
    try std.testing.expectEqual(@as(f32, 87), state.external_row_window.?.top);
    try std.testing.expectEqual(@as(f32, 173), state.external_row_window.?.bottom);
}
