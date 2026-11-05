/// Table Component.
///
/// Table component with virtual scrolling, sorting, selection.
///
/// Features:
/// - Fixed header (sticky)
/// - Column width config
/// - Sort indicator
/// - Row hover highlight
/// - Striped rows (optional)
/// - Virtual scroll: auto-enable when row_count > virtual_threshold, via VirtualList
/// - Small data: direct render (zero overhead).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
// Alias avoids name collision with TableState.view method.
const view_dsl = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const hooks = @import("../../hooks.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const virtual_list = @import("../virtual_list/mod.zig");
const VirtualListState = virtual_list.VirtualListState;

/// Virtual scroll enable threshold: auto-enable VirtualList above row_count.
const virtual_threshold: usize = 50;

// Style layer extracted to styles.zig; mount/render only consume it; this file makes no visual
// decisions.

const styles = @import("styles.zig");
const colJustify = styles.colJustify;
const tableBorderWrapStyle = styles.tableBorderWrapStyle;
const tableInnerStyle = styles.tableInnerStyle;
const tableHeaderRowStyle = styles.tableHeaderRowStyle;
const tableHeaderCellStyle = styles.tableHeaderCellStyle;
const tableHeaderTextStyle = styles.tableHeaderTextStyle;
const sortIndicatorBoxStyle = styles.sortIndicatorBoxStyle;
const sortIndicatorText = styles.sortIndicatorText;
const tableRowBg = styles.tableRowBg;
const tableRowStyle = styles.tableRowStyle;
const tableCellStyle = styles.tableCellStyle;
const tableSeparatorStyle = styles.tableSeparatorStyle;

/// Column alignment.
pub const ColumnAlign = enum {
    left,
    center,
    right,
};

/// Column definition.
pub const ColumnDef = struct {
    id: []const u8,
    header: []const u8,
    width: f32 = 120,
    sortable: bool = false,
    col_align: ColumnAlign = .left,
};

/// Sort direction.
pub const SortDirection = enum {
    none,
    asc,
    desc,

    pub fn indicator(self: SortDirection) []const u8 {
        return switch (self) {
            .none => " ",
            .asc => "^",
            .desc => "v",
        };
    }

    pub fn toggle(self: SortDirection) SortDirection {
        return switch (self) {
            .none => .asc,
            .asc => .desc,
            .desc => .none,
        };
    }
};

/// Cell render callback (low-level contract; app code uses
/// `.cells(ctx, cell)`): populate cell with content. `user_ctx` = `render_cell_ctx`.
/// `scope` owns `cell`: it is retired together with the cell (table rebuild in direct mode,
/// slot recycle in virtual mode), so anything the callback hangs on the cell (effects,
/// subscriptions, resources) must be opened under it -- never under a longer-lived scope.
pub const CellRenderFn = *const fn (cell: *Node, row: usize, col: usize, scope: *Scope, cx: *Cx, user_ctx: ?*anyopaque) void;

/// Table properties. Sort state: column index + direction (direction != .none).
pub const TableSort = struct {
    column: usize,
    direction: SortDirection,
};

pub const TableProps = struct {
    columns: []const ColumnDef = &.{},
    /// Row count (signal/derived OK). Virtual scroll above 50 rows.
    row_count: Source(usize) = .{ .value = 0 },
    /// Data version: when content changes without row_count change, set new value
    /// (or derive from data signal) to redraw cells.
    data_version: Source(u64) = .{ .value = 0 },
    row_height: f32 = 28,
    header_height: f32 = 28,
    striped: bool = false,
    hoverable: bool = true,
    table_width: ?f32 = null,
    table_height: f32 = 400,
    /// Cell render callback: populate cell (untracked; refresh via data_version).
    /// App code uses `.cells(ctx, cell)` for view-form cells, don't fill these directly.
    render_cell: ?CellRenderFn = null,
    render_cell_ctx: ?*anyopaque = null,
    /// Sort state (null = no sorting): `*Signal(?TableSort)` controlled (interaction writes
    /// directly); `ui.split` intercepts.
    sort: Model(?TableSort) = .{ .local = null },
    /// Called when header clicked, sort state committed.
    on_sort_change: ?Handler(?TableSort) = null,
    /// Row clicked (row index).
    on_row_click: ?Handler(usize) = null,
};

/// Create table: W.Table(.{ .columns = &cols, .row_count = n, .sort = sort
/// }).cells(ctx, cell).
pub fn Table(props: anytype) TableBuilder {
    return .{ .props = reactive.props.coerce(TableProps, props) };
}

/// Table runtime (scope-owned). View = f(row_count, data_version, sort): sort
/// arrows follow sort; body refreshes on row_count/version/sort change (direct
/// mode rebuilds, virtual mode updates item_count; crossing 50-row threshold
/// swaps body entirely).
pub const TableState = struct {
    sort: reactive.Bound(?TableSort),
    row_count: Source(usize),
    data_version: Source(u64),
    on_sort_change: ?Handler(?TableSort),
    on_row_click: ?Handler(usize),
    props: TableProps,
    table_width: f32,
    cx: *Cx,
    scope: *Scope,
    tokens: *const core.ThemeTokens,
    inner: *Node,
    /// Each column header's sort indicator nodes (fixed upper bound: excess columns
    /// skip arrows, sort itself still works).
    sort_indicators: [MAX_SORT_INDICATORS]?*Node = @as([MAX_SORT_INDICATORS]?*Node, @splat(null)),
    header_cells: [MAX_SORT_INDICATORS]?*Node = @as([MAX_SORT_INDICATORS]?*Node, @splat(null)),
    columns: []const ColumnDef,
    /// Currently displayed sort.
    shown_sort: ?TableSort = null,
    /// Current body (direct mode: row container or VirtualList container) + its
    /// dedicated scope.
    body: ?*Node = null,
    body_scope: ?*Scope = null,
    vl_state: ?*VirtualListState = null,
    /// Last (row_count, version, sort) applied to body; null = not yet built.
    body_key: ?u64 = null,

    fn bodyKey(count: usize, version: u64, sort: ?TableSort) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&count));
        h.update(std.mem.asBytes(&version));
        const s = sort orelse TableSort{ .column = std.math.maxInt(usize), .direction = .none };
        h.update(std.mem.asBytes(&s.column));
        h.update(&[_]u8{@backingInt(s.direction)});
        return h.final();
    }

    fn view(self: *TableState, comptime tracked: bool) !void {
        const sort = self.sort.readAs(tracked);
        const count = self.row_count.read(tracked);
        const version = self.data_version.read(tracked);
        self.shown_sort = sort;
        refreshSortIndicators(self);
        const k = bodyKey(count, version, sort);
        if (self.body_key != null and self.body_key.? == k) return;
        try self.cx.owner.untrack(refreshBody, .{ self, count });
        self.body_key = k;
    }

    fn viewEffect(self: *TableState) void {
        self.view(true) catch |err| std.log.err("[Table] update failed: {}", .{err});
    }

    fn refreshBody(args: struct { *TableState, usize }) !void {
        const self = args[0];
        const count = args[1];
        const want_virtual = count > virtual_threshold;
        if (want_virtual and self.vl_state != null) {
            // Virtual mode: update row_count and redraw visible rows, preserve scroll.
            virtual_list.updateItemCount(self.vl_state.?, count);
            return;
        }
        self.dropBody();
        const body_scope = try self.scope.childScope();
        self.body_scope = body_scope;
        errdefer self.dropBody();
        // Mount then record: adoptChild / view.mount failure releases nodes just
        // mounted; record early and errdefer releases twice.
        if (want_virtual) {
            const vl = try mountVirtualBody(self, body_scope, count);
            // Pre-built component root via adoptChild: if opening child scope fails after
            // view.mount receives *Node, node neither mounted nor freed (ownership
            // unclear), OOM sweep reports leak.
            _ = try core.adoptChild(self.cx, self.cx.allocator, self.inner, vl.container);
            self.body = vl.container;
            self.vl_state = vl.vl_state;
        } else {
            var body: *Node = undefined;
            try view_dsl.mount(body_scope, self.cx, self.inner, view_dsl.capture(&body, view_dsl.col(.{ .style = core.BoxStyle{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .overflow_hidden = true,
            } }, {})));
            self.body = body;
            // Row / cell / divider mid-failure: errdefer dropBody above releases mounted
            // rows too.
            try fillDirectBody(self, body_scope, body, count);
        }
    }

    /// Unmount current body (standard order: invalidate hook -> dispose scope ->
    /// unlink/free).
    fn dropBody(self: *TableState) void {
        if (self.body) |b| hooks.invalidateSubtreeHookState(b);
        if (self.body_scope) |sc| sc.dispose();
        self.body_scope = null;
        self.vl_state = null;
        if (self.body) |b| {
            core.clearNodeScopes(b);
            if (b.parent) |parent| self.cx.detachChild(parent, b);
            self.cx.freeNode(b);
        }
        self.body = null;
        self.body_key = null;
    }

    /// Click header: same column asc -> desc -> none, new column starts asc;
    /// proposal only.
    fn toggleSort(self: *TableState, column: usize) void {
        const cur = self.shown_sort;
        const next: ?TableSort = blk: {
            if (cur) |c| {
                if (c.column == column) {
                    const dir = c.direction.toggle();
                    break :blk if (dir == .none) null else TableSort{ .column = column, .direction = dir };
                }
            }
            break :blk TableSort{ .column = column, .direction = .asc };
        };
        const on_change = self.on_sort_change;
        const landed = self.sort.commit(next) orelse return;
        if (on_change) |h| h.call(landed);
    }

    fn rowClick(self: *TableState, index: usize) void {
        if (self.on_row_click) |h| h.call(index);
    }
};

/// Table mount result.
pub const TableResult = struct {
    wrapper: *Node,
    /// Sort signal (null in ui.split).
    sort: ?*Signal(?TableSort),
    /// ui.view integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: TableResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

pub const TableBuilder = struct {
    props: TableProps,

    /// ui.view integration: a cell function returns a view element, passed directly as a
    /// child to ui.view: W.Table(.{ .columns = &cols, .row_count = n }).cells(ctx, cell).
    /// Cell function: fn (Ctx, row: usize, col: usize) E / fn (usize, usize) E (ctx = {}),
    /// or component form fn (Ctx, usize, usize, *Scope, *Cx) !*Node. Each cell's content gets a
    /// child scope of the cell's own scope (itself under the row), bound to the content root: a
    /// table rebuild (row_count / data_version change) or virtual row reclaim frees the scope +
    /// cell effects together with the row.
    pub fn cells(self: TableBuilder, ctx: anytype, comptime cell_fn: anytype) TableCells(@TypeOf(ctx), cell_fn) {
        return .{ .builder = self, .ctx = ctx };
    }

    /// Retain mode: mount.
    pub fn mount(self: TableBuilder, scope: *Scope, cx: *Cx) !TableResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const t = cx.tokens;
        const p = self.props;
        reactive.checkBorrow(my_scope, p.row_count);
        reactive.checkBorrow(my_scope, p.data_version);

        // Compute total width.
        var total_width: f32 = 0;
        for (p.columns) |col| total_width += col.width;
        const table_width = p.table_width orelse total_width;

        // Outer border container (padding reserves border space, prevents child
        // overlap). Inner container (overflow_hidden clips, excludes border).
        var wrapper: *Node = undefined;
        const border_wrap = try view_dsl.render(my_scope, cx, view_dsl.box(.{
            .style = tableBorderWrapStyle(table_width, p.table_height, t),
            .a11y = .{ .role = .table },
        }, view_dsl.capture(&wrapper, view_dsl.box(.{ .style = tableInnerStyle(t) }, {}))));
        // Sweep: border_wrap armed through return (post-bind freeNode disposes
        // my_scope).
        errdefer cx.freeNode(border_wrap);
        border_wrap.meta.ownership.meta.component_name = "Table";
        try core.bindScopeToNode(my_scope, border_wrap);
        scope_bound = true;

        const sort = try reactive.resolveModel(?TableSort, my_scope, p.sort);
        const state = try my_scope.allocator.create(TableState);
        state.* = .{
            .sort = sort,
            .row_count = p.row_count,
            .data_version = p.data_version,
            .on_sort_change = p.on_sort_change,
            .on_row_click = p.on_row_click,
            .props = p,
            .table_width = table_width,
            .cx = cx,
            .scope = my_scope,
            .tokens = t,
            .inner = wrapper,
            .columns = p.columns,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*TableState, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        border_wrap.addDebugState(@ptrCast(state));

        // ---- Header ----
        try mountHeader(p, state, my_scope, cx, t, wrapper);

        // ---- Body: first view sync builds, then effect refreshes ----
        try state.view(false);
        // sort is Model: header click changes it, needs effect.
        try my_scope.createEffect(state, TableState.viewEffect);
        return .{ .wrapper = border_wrap, .sort = sort.asSignal() };
    }
};

// ========== Header render ==========.

fn mountHeader(
    p: TableProps,
    state: *TableState,
    my_scope: *Scope,
    cx: *Cx,
    t: *const core.ThemeTokens,
    parent: *Node,
) !void {
    // Mount to parent: mid-failure root guard releases all.
    try view_dsl.mount(my_scope, cx, parent, view_dsl.box(.{
        .style = tableHeaderRowStyle(p.header_height, t),
        .a11y = core.A11yProps{ .role = .row, .row_index = 0 },
    }, view_dsl.items(state, p.columns, headerCellElement)));
}

const HeaderCellArgs = struct { state: *TableState, col: ColumnDef, index: usize };

fn headerCellElement(state: *TableState, col: ColumnDef, ci: usize) view_dsl.ComponentOf(buildHeaderCell) {
    return view_dsl.component(buildHeaderCell, HeaderCellArgs{ .state = state, .col = col, .index = ci });
}

/// Header cell: title + sort indicator for sortable columns (text rewritten
/// by refreshSortIndicators).
fn buildHeaderCell(args: HeaderCellArgs, scope: *Scope, cx: *Cx) !*Node {
    const state = args.state;
    const col = args.col;
    const ci = args.index;
    const t = cx.tokens;
    var sort_ind: ?*Node = null;
    const header_cell = try view_dsl.render(scope, cx, view_dsl.box(.{
        .style = .{ tableHeaderCellStyle(col), if (col.sortable) core.BoxStyle{ .cursor = .pointer } else core.BoxStyle{} },
        .a11y = core.A11yProps{
            .role = .columnheader,
            .label = col.header,
            .row_index = 0,
            .column_index = @intCast(ci),
            .sort_direction = .none,
        },
    }, .{
        view_dsl.text(.{ .style = tableHeaderTextStyle(t) }, col.header),
        if (col.sortable) view_dsl.capture(&sort_ind, view_dsl.attrs(
            .{ .style = sortIndicatorBoxStyle() },
            view_dsl.text(.{ .style = sortIndicatorText(t) }, SortDirection.none.indicator()),
        )) else null,
    }));
    errdefer cx.freeNode(header_cell);
    if (ci < state.header_cells.len) state.header_cells[ci] = header_cell;

    if (sort_ind) |ind| {
        const sort_ctx = try scope.allocator.create(SortClickContext);
        sort_ctx.* = .{ .state = state, .col_index = ci };
        try scope.adoptResource(@ptrCast(sort_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const c: *SortClickContext = @ptrCast(@alignCast(ptr));
                alloc.destroy(c);
            }
        }.cleanup);
        header_cell.behavior.events.on_event = sortEventHandler;
        header_cell.behavior.events.event_context = @ptrCast(sort_ctx);
        if (ci < state.sort_indicators.len) state.sort_indicators[ci] = ind;
    }
    return header_cell;
}

// ========== Direct render mode (small data) ==========.

/// Fill mounted body col row-by-row (rows / cells / dividers).
fn fillDirectBody(state: *TableState, body_scope: *Scope, body: *Node, row_count: usize) !void {
    // Row count is runtime value: expand zero-width slice of row_count length.
    const rows: []const void = @as([*]const void, undefined)[0..row_count];
    try view_dsl.mount(body_scope, state.cx, body, view_dsl.items(DirectRowCtx{ .state = state, .count = row_count }, rows, directRowElement));
}

const DirectRowCtx = struct { state: *TableState, count: usize };
const RowArgs = struct { state: *TableState, index: usize };
const SeparatorProps = struct { style: core.BoxStyle };
const RowElem = view_dsl.ComponentOf(buildRow);
const SeparatorElem = view_dsl.Box(SeparatorProps, void, null);
const DirectRowElem = struct { RowElem, ?SeparatorElem };

/// Row element, shared by both body modes: direct rendering lists it next to a divider; the
/// virtual body mounts it into the pooled slot (`virtualRowRender`).
fn rowElement(state: *TableState, row_i: usize) RowElem {
    return view_dsl.component(buildRow, RowArgs{ .state = state, .index = row_i });
}

/// Divider below a row, shared by both body modes.
fn separatorElement(state: *TableState, _: usize) SeparatorElem {
    return view_dsl.box(SeparatorProps{ .style = tableSeparatorStyle(state.tokens.tokens.color.separator) }, {});
}

/// One row + divider (omit after last).
fn directRowElement(c: DirectRowCtx, _: void, row_i: usize) DirectRowElem {
    return .{
        rowElement(c.state, row_i),
        if (row_i + 1 < c.count) separatorElement(c.state, row_i) else null,
    };
}

/// One row: cells per column (content via render_cell) + row click/hover, all owned by `scope`.
/// The single row declaration for both body modes: the direct body mounts it under the body
/// scope, the virtual body under a per-slot subscope that is retired with the row node when the
/// slot is recycled, so hover / transition / click state never outlives the row it belongs to.
fn buildRow(args: RowArgs, scope: *Scope, cx: *Cx) !*Node {
    const state = args.state;
    const row_i = args.index;
    const t = state.tokens;
    const p = state.props;
    const is_even = (row_i % 2 == 0);
    const row_bg = tableRowBg(p.striped, is_even, t);

    var row_click: ?core.Handler(void) = null;
    if (state.on_row_click != null) {
        const ctx = try scope.allocator.create(RowClickCtx);
        ctx.* = .{ .state = state, .index = row_i };
        try scope.adoptResource(@ptrCast(ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*RowClickCtx, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        row_click = core.Cx.simpleHandler(RowClickCtx.fire, ctx);
    }

    const row_node = try view_dsl.render(scope, cx, view_dsl.box(.{
        .style = .{ tableRowStyle(row_bg, p.row_height), if (row_click != null) core.BoxStyle{ .cursor = .pointer } else core.BoxStyle{}, styles.rowFade, view_dsl.when(p.hoverable, view_dsl.hover(styles.rowHover)) },
        .a11y = core.A11yProps{ .role = .row, .row_index = @intCast(row_i) },
        .on_click = row_click,
    }, view_dsl.items(CellCtx{ .state = state, .row = row_i }, p.columns, cellElement)));
    errdefer {
        hooks.invalidateSubtreeHookState(row_node);
        cx.freeNode(row_node);
    }

    return row_node;
}

const CellCtx = struct { state: *TableState, row: usize };
const CellArgs = struct { state: *TableState, col: ColumnDef, row: usize, index: usize };

fn cellElement(c: CellCtx, col: ColumnDef, ci: usize) view_dsl.ComponentOf(buildCell) {
    return view_dsl.component(buildCell, CellArgs{ .state = c.state, .col = col, .row = c.row, .index = ci });
}

fn buildCell(args: CellArgs, scope: *Scope, cx: *Cx) !*Node {
    const p = args.state.props;
    const cell = try view_dsl.render(scope, cx, view_dsl.box(.{
        .style = tableCellStyle(args.col),
        .a11y = core.A11yProps{
            .role = .gridcell,
            .row_index = @intCast(args.row),
            .column_index = @intCast(args.index),
        },
    }, {}));
    // Cell content callback (may graft subtree into cell). It receives this cell's own scope:
    // content ownership follows the row that owns the cell in both body modes (body scope
    // subtree in direct mode, the recycled slot's row scope in virtual mode).
    if (p.render_cell) |render_fn| render_fn(cell, args.row, args.index, scope, cx, p.render_cell_ctx);
    return cell;
}

/// TableBuilder.cells result: via viewMount enter ui.view (v.ref gets TableResult).
pub fn TableCells(comptime Ctx: type, comptime cell_fn: anytype) type {
    const what = "Table.cells";
    _ = view_dsl.callbackIsComponent(@TypeOf(cell_fn), if (Ctx == void) 2 else 3, what);
    return struct {
        builder: TableBuilder,
        ctx: Ctx,

        const Self = @This();
        /// User ctx, owned by the table's mount scope (outlives every body / row / cell).
        const State = view_dsl.CallbackState(Ctx);

        pub fn viewMount(self: Self, scope: *Scope, cx: *Cx) !TableResult {
            const st = try State.create(scope, self.ctx);
            var b = self.builder;
            b.props.render_cell = render;
            b.props.render_cell_ctx = @ptrCast(st);
            return b.mount(scope, cx);
        }

        /// Content scope opens under `cell_scope` (the cell's owner), never under the mount
        /// or body scope: a recycled virtual row frees its scope subtree, and with it the
        /// content's effects, before the row's nodes are released.
        fn render(cell: *Node, row: usize, col: usize, cell_scope: *Scope, cx: *Cx, user: ?*anyopaque) void {
            const st: *State = @ptrCast(@alignCast(user.?));
            view_dsl.renderInto(cell_scope, cx, cell, cell_fn, st.ctx, .{ row, col }, what) catch |err| {
                std.log.warn("Table.cells: cell ({d},{d}) render failed: {s}", .{ row, col, @errorName(err) });
            };
        }
    };
}

/// Row-click context, owned by the row's scope (body scope in direct mode, the slot subscope in
/// virtual mode).
const RowClickCtx = struct {
    state: *TableState,
    index: usize,

    fn fire(ptr: *anyopaque) void {
        const self: *RowClickCtx = @ptrCast(@alignCast(ptr));
        self.state.rowClick(self.index);
    }
};

// ========== Virtual scroll mode (large data) ==========.

fn mountVirtualBody(state: *TableState, body_scope: *Scope, row_count: usize) !struct { container: *Node, vl_state: *VirtualListState } {
    const cx = state.cx;
    const p = state.props;

    // VirtualList item_height = row height + 1px divider.
    const item_height = p.row_height + 1;
    // Body height = total table height - header - border (2px).
    const body_height = p.table_height - p.header_height - 2;

    // TableState is owned by the table scope and outlives the body: a plain context pointer.
    const vl_result = try virtual_list.VirtualList(.{
        .item_count = row_count,
        .item_height = item_height,
        .width = state.table_width,
        .height = body_height,
        .overscan = 5,
    }).mountScoped(body_scope, cx, @ptrCast(state), virtualRowRender);

    return .{ .container = vl_result.container, .vl_state = vl_result.state };
}

/// VirtualList slot render callback (item enters visible range / data refresh).
///
/// Mounts the same row + divider elements as the direct body, each through `view.renderInto`:
/// a subscope of the list's own scope bound to the mounted root. The row's cells, and the
/// content scopes `.cells` opens under each cell's scope, all nest inside that row subscope.
/// VirtualList clears the slot (frees its children) before every rebind, which retires the row
/// subscope -- hover listeners, style layers, transitions, click contexts and cell content
/// effects together -- so a rebound slot always starts from a fresh, unhovered row and nothing
/// accumulates while scrolling.
fn virtualRowRender(node: *Node, index: usize, list_scope: *Scope, cx: *Cx, user_context: ?*anyopaque) void {
    const state: *TableState = @ptrCast(@alignCast(user_context.?));
    node.style.direction = .column;
    node.style.flex_shrink = 0;
    const what = "Table virtual row";
    view_dsl.renderInto(list_scope, cx, node, rowElement, state, .{index}, what) catch {
        _ = virtual_list.markPoolNodeRenderIncomplete(node);
        return;
    };
    view_dsl.renderInto(list_scope, cx, node, separatorElement, state, .{index}, what) catch {
        // Unbinds the slot (frees the row mounted above) and retries next frame.
        _ = virtual_list.markPoolNodeRenderIncomplete(node);
    };
}

// ========== Internal helpers ==========.

/// sort_indicators fixed upper bound (see TableState.sort_indicators).
const MAX_SORT_INDICATORS = 32;

const SortClickContext = struct {
    state: *TableState,
    col_index: usize,
};

/// Redraw all column header arrows and aria-sort per current sort.
fn refreshSortIndicators(state: *TableState) void {
    for (state.sort_indicators, 0..) |maybe_node, ci| {
        const node = maybe_node orelse continue;
        const dir: SortDirection = if (state.shown_sort) |s| (if (s.column == ci) s.direction else .none) else .none;
        if (node.getText()) |old| {
            var txt = old;
            txt.content = dir.indicator();
            // indicator() returns static literal, not heap content; must clear owned,
            // else Node.destroy frees non-heap pointer.
            txt.owned = false;
            txt.inline_len = 0;
            node.setText(txt);
        }
        node.markRenderDirty();
        if (ci < state.header_cells.len) {
            if (state.header_cells[ci]) |header_cell| {
                if (header_cell.behavior.interaction.a11y) |*a| {
                    a.sort_direction = switch (dir) {
                        .none => .none,
                        .asc => .ascending,
                        .desc => .descending,
                    };
                }
                header_cell.markRenderDirty();
            }
        }
    }
}

fn sortEventHandler(event: Event, context: ?*anyopaque) EventResult {
    switch (event) {
        .click => {
            const sc: *SortClickContext = @ptrCast(@alignCast(context orelse return .ignored));
            sc.state.toggleSort(sc.col_index);
            return .stop;
        },
        else => {},
    }
    return .ignored;
}

// ========== Tests ==========.

fn stateOf(r: TableResult) *TableState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

const test_columns = [_]ColumnDef{
    .{ .id = "name", .header = "Name", .width = 150, .sortable = true },
    .{ .id = "age", .header = "Age", .width = 80, .col_align = .right },
    .{ .id = "email", .header = "Email", .width = 200 },
};

test "Table: basic structure" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 5,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // Small data: direct render mode, no VirtualList.
    try std.testing.expect(stateOf(result).vl_state == null);

    // border_wrap has 1 child: inner wrapper.
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    const inner = result.wrapper.children.items[0];

    // inner wrapper has 2 children: header + body.
    try std.testing.expectEqual(@as(usize, 2), inner.children.items.len);

    // header has 3 cells.
    const header = inner.children.items[0];
    try std.testing.expectEqual(@as(usize, 3), header.children.items.len);

    // body has 5 rows + 4 dividers = 9 children.
    const body = inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 9), body.children.items.len);
}

test "Table: striped rows" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 4,
        .striped = true,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 4 rows + 3 dividers = 7 children.
    const inner = result.wrapper.children.items[0];
    const body = inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 7), body.children.items.len);
}

test "Table: sort toggle" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 2,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // Simulate header click (sort).
    const inner = result.wrapper.children.items[0];
    const header = inner.children.items[0];
    const name_header = header.children.items[0];
    if (name_header.behavior.events.on_event) |handler| {
        _ = handler(.{ .click = .{ .x = 0, .y = 0 } }, name_header.behavior.events.event_context);
    }

    try std.testing.expectEqual(@as(usize, 0), result.sort.?.peek().?.column);
    try std.testing.expectEqual(SortDirection.asc, result.sort.?.peek().?.direction);
}

test "Table: empty" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 0,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    const inner = result.wrapper.children.items[0];
    const body = inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 0), body.children.items.len);
}

test "Table: virtual scrolling enabled for large datasets" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // Above threshold -> enable VirtualList.
    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 1000,
        .table_height = 400,
        .hoverable = false,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // Virtual scroll mode: vl_state non-null.
    try std.testing.expect(stateOf(result).vl_state != null);

    // VirtualList item_count correct.
    try std.testing.expectEqual(@as(usize, 1000), stateOf(result).vl_state.?.item_count);

    // Pool size > 0 and much smaller than row_count.
    try std.testing.expect(stateOf(result).vl_state.?.pool_size > 0);
    try std.testing.expect(stateOf(result).vl_state.?.pool_size < 100);
}

test "Table: virtual scrolling visible range" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 10000,
        .row_height = 36,
        .table_height = 400,
        .hoverable = false,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    const vl = stateOf(result).vl_state.?;

    // Simulate scroll to row 500.
    const item_height = 36 + 1; // row_height + separator
    vl.scroll_state.scroll_y = 500 * @as(f32, @floatFromInt(item_height));
    vl.scroll_state.viewport_height = 400 - 40 - 2; // table_height - header - border
    vl.scroll_state.content_height = 10000 * @as(f32, @floatFromInt(item_height));

    const range = vl.visibleRange();
    // Visible range should include ~500.
    try std.testing.expect(range.start <= 500);
    try std.testing.expect(range.end > 500);
    try std.testing.expect(range.end - range.start < 30); // much less than 10000.
}

test "Table: threshold boundary - 50 rows uses direct rendering" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // Exactly 50 rows: no virtual scroll.
    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 50,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 50 rows <= threshold -> direct render.
    try std.testing.expect(stateOf(result).vl_state == null);

    // body has 50 rows + 49 dividers = 99 children.
    const inner = result.wrapper.children.items[0];
    const body = inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 99), body.children.items.len);
}

test "Table: threshold boundary - 51 rows enables virtual scrolling" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 51 rows: enable virtual scroll.
    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 51,
        .hoverable = false,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 51 rows > threshold -> virtual scroll.
    try std.testing.expect(stateOf(result).vl_state != null);
    try std.testing.expectEqual(@as(usize, 51), stateOf(result).vl_state.?.item_count);
}

test "Table: on_row_click 真的被接线（此前声明了无人读取）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(600, 400);
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Sink = struct {
        clicks: u32 = 0,
        last: usize = 0,
        fn onClick(self: *@This(), index: usize) void {
            self.clicks += 1;
            self.last = index;
        }
    };
    var sink = Sink{};

    const cols = [_]ColumnDef{.{ .id = "name", .header = "Name", .width = 100 }};
    const result = try Table(.{
        .columns = &cols,
        .row_count = 3,
        .on_row_click = ctx.on(Sink, &sink, Sink.onClick),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    // Find a row node with on_click and dispatch click.
    var found: ?*Node = null;
    // Take last clickable row: first row index is exactly 0, can't detect
    // "callback lost row index".
    const Walk = struct {
        fn go(n: *Node, out: *?*Node) void {
            if (n.behavior.events.on_click != null) out.* = n;
            for (n.children.items) |c| go(c, out);
        }
    };
    Walk.go(result.wrapper, &found);
    const row = found orelse return error.NoClickableRow;

    _ = ctx.dispatcher.dispatch(core.Event{ .click = .{ .x = 10, .y = 10 } }, row);
    try std.testing.expectEqual(@as(u32, 1), sink.clicks);
    try std.testing.expect(sink.last > 0);
    try std.testing.expectEqual(@as(usize, row.behavior.interaction.a11y.?.row_index), sink.last);
}

test "Table(virtual): on_row_click 在 >50 行虚拟路径同样接线" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(600, 400);
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Sink = struct {
        clicks: u32 = 0,
        last: usize = 0,
        fn onClick(self: *@This(), index: usize) void {
            self.clicks += 1;
            self.last = index;
        }
    };
    var sink = Sink{};
    const cols = [_]ColumnDef{.{ .id = "name", .header = "Name", .width = 100 }};
    const result = try Table(.{
        .columns = &cols,
        .row_count = 200,
        .on_row_click = ctx.on(Sink, &sink, Sink.onClick),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(stateOf(result).vl_state != null);
    ctx.layout();
    _ = ctx.render();

    var found: ?*Node = null;
    // Take last clickable row: first row index is exactly 0, can't detect
    // "callback lost row index".
    const Walk = struct {
        fn go(n: *Node, out: *?*Node) void {
            if (n.behavior.interaction.a11y) |a| {
                if (a.role == .row and n.behavior.events.on_click != null) out.* = n;
            }
            for (n.children.items) |c| go(c, out);
        }
    };
    Walk.go(result.wrapper, &found);
    const row = found orelse return error.NoClickableRow;
    _ = ctx.dispatcher.dispatch(core.Event{ .click = .{ .x = 10, .y = 10 } }, row);
    try std.testing.expectEqual(@as(u32, 1), sink.clicks);
    try std.testing.expect(sink.last > 0);
    try std.testing.expectEqual(@as(usize, row.behavior.interaction.a11y.?.row_index), sink.last);
}

test "Table: 排序箭头随点击更新；外部写入 sort 同样刷新箭头与 aria-sort" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(600, 400);
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const cols = [_]ColumnDef{
        .{ .id = "name", .header = "Name", .width = 100, .sortable = true },
        .{ .id = "age", .header = "Age", .width = 60, .sortable = true },
    };
    const sort = try scope.createSignal(?TableSort, null);
    var landed: ?TableSort = null;
    var changes: u32 = 0;
    const Rec = struct {
        landed: *?TableSort,
        changes: *u32,
        fn f(self: *@This(), v: ?TableSort) void {
            self.landed.* = v;
            self.changes.* += 1;
        }
    };
    var rec = Rec{ .landed = &landed, .changes = &changes };
    const result = try Table(.{ .columns = &cols, .row_count = 2, .sort = sort, .on_sort_change = ctx.on(Rec, &rec, Rec.f) }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const st = stateOf(result);
    const indicator = struct {
        fn of(s: *TableState, col: usize) []const u8 {
            return s.sort_indicators[col].?.getText().?.content;
        }
    }.of;
    try std.testing.expectEqualStrings(" ", indicator(st, 0));

    // Click col 0: asc; again: desc; again: none.
    const header0 = st.header_cells[0].?;
    _ = sortEventHandler(.{ .click = .{ .x = 0, .y = 0 } }, header0.behavior.events.event_context);
    try std.testing.expectEqualStrings("^", indicator(st, 0));
    try std.testing.expectEqualStrings(" ", indicator(st, 1));
    _ = sortEventHandler(.{ .click = .{ .x = 0, .y = 0 } }, header0.behavior.events.event_context);
    try std.testing.expectEqualStrings("v", indicator(st, 0));
    try std.testing.expectEqual(SortDirection.desc, landed.?.direction);
    _ = sortEventHandler(.{ .click = .{ .x = 0, .y = 0 } }, header0.behavior.events.event_context);
    try std.testing.expect(sort.peek() == null);
    try std.testing.expectEqual(@as(u32, 3), changes);

    // External write: don't trigger on_sort_change.
    sort.set(TableSort{ .column = 1, .direction = .desc });
    try std.testing.expectEqualStrings("v", indicator(st, 1));
    try std.testing.expectEqual(@as(?core.A11ySortDirection, .descending), st.header_cells[1].?.behavior.interaction.a11y.?.sort_direction);
    try std.testing.expectEqual(@as(u32, 3), changes);
}

test "Table: row_count / data_version from signals refresh the body; crossing 50 rows switches to virtual" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Probe = struct {
        var renders: u32 = 0;
        fn cell(_: *Node, _: usize, _: usize, _: *Scope, _: *Cx, _: ?*anyopaque) void {
            renders += 1;
        }
    };
    Probe.renders = 0;
    const count = try scope.createSignal(usize, 3);
    const version = try scope.createSignal(u64, 0);
    const result = try Table(.{ .columns = &test_columns, .row_count = count, .data_version = version, .render_cell = Probe.cell }).mount(scope, ctx);
    defer ctx.freeNode(result.wrapper);
    const st = stateOf(result);
    try std.testing.expectEqual(@as(u32, 9), Probe.renders); // 3 rows x 3 cols.
    version.set(1); // content changed: redraw.
    try std.testing.expectEqual(@as(u32, 18), Probe.renders);
    count.set(5);
    const body = st.inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 9), body.children.items.len); // 5 rows + 4 dividers.
    try std.testing.expect(st.vl_state == null);
    count.set(200);
    try std.testing.expect(st.vl_state != null);
    try std.testing.expectEqual(@as(usize, 200), st.vl_state.?.item_count);
    count.set(300); // both virtual: update row_count only.
    const vl = st.vl_state.?;
    try std.testing.expectEqual(@as(usize, 300), vl.item_count);
    count.set(2); // back to direct mode.
    try std.testing.expect(st.vl_state == null);
    try std.testing.expectEqual(@as(usize, 3), st.inner.children.items[1].children.items.len);
}

test "table: 动态行数（跨虚拟阈值）的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("table(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const count = try scope.createSignal(usize, 60);
            const sort = try scope.createSignal(?TableSort, TableSort{ .column = 0, .direction = .asc });
            const r = try Table(.{ .columns = &test_columns, .row_count = count, .sort = sort, .striped = true }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}

/// Virtual-mode fixture: a mounted 10k-row table with a laid-out viewport.
const VirtualFixture = struct {
    cx: *Cx,
    scope: *Scope,
    result: TableResult,

    fn init(props: anytype) !VirtualFixture {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(600, 500);
        const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
        cx.root = root;
        const scope = try Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        const result = try Table(props).mount(scope, cx);
        try root.appendChild(std.testing.allocator, result.wrapper);
        try std.testing.expect(stateOf(result).vl_state != null);
        return .{ .cx = cx, .scope = scope, .result = result };
    }

    fn deinit(f: VirtualFixture) void {
        f.scope.dispose();
        f.cx.deinit();
    }

    fn vl(f: VirtualFixture) *VirtualListState {
        return stateOf(f.result).vl_state.?;
    }

    /// Bound slot + its row node for data index `index` (null = not bound).
    fn slotOf(f: VirtualFixture, index: usize) ?struct { slot: usize, row: *Node } {
        const list = f.vl();
        for (list.pool_bindings, 0..) |binding, slot| {
            if (binding != index) continue;
            const pool = list.pool_nodes[slot];
            return .{ .slot = slot, .row = pool.children.items[0] };
        }
        return null;
    }

    /// Scroll so `first` is the top row (no layout needed: drives the VirtualList pass directly).
    fn scrollTo(f: VirtualFixture, first: usize, item_height: f32) void {
        const list = f.vl();
        list.scroll_state.viewport_height = 400 - 28 - 2;
        list.scroll_state.content_height = @as(f32, @floatFromInt(list.item_count)) * item_height;
        list.scroll_state.scroll_y = @as(f32, @floatFromInt(first)) * item_height;
        list.updateVisibleItems();
    }
};

fn testHover(n: *Node, on: bool) void {
    const h = if (on) n.behavior.events.on_hover.? else n.behavior.events.on_leave.?;
    h.callback(h.context);
}

/// Background the row is heading to: transition target while one runs, else the current value.
fn backgroundTarget(n: *Node) Color {
    if (n.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.find(.background)) |slot| if (slot.active) return slot.to_color;
    }
    return n.getBackground();
}

fn backgroundTransitionActive(n: *Node) bool {
    const slots = n.frame_state.frame_local.runtime.transitions orelse return false;
    const slot = slots.find(.background) orelse return false;
    return slot.active;
}

test "Table(virtual): 虚拟行悬停走与直渲行同一份声明——过渡到 bg_active，离开回到斑马纹底色" {
    const f = try VirtualFixture.init(.{ .columns = &test_columns, .row_count = 10000, .striped = true });
    defer f.deinit();
    const tok = f.cx.tokens.tokens.color;

    // Odd row: striped base is bg_secondary; mounted without a transition.
    const odd = (f.slotOf(1) orelse return error.RowNotBound).row;
    try std.testing.expectEqual(core.A11yRole.row, odd.behavior.interaction.a11y.?.role);
    try std.testing.expectEqual(@as(u32, 1), odd.behavior.interaction.a11y.?.row_index);
    try std.testing.expect(Color.eql(tok.bg_secondary, odd.getBackground()));
    try std.testing.expect(!backgroundTransitionActive(odd));
    // No on_row_click: hover alone must not advertise a click target.
    try std.testing.expect(odd.style.cursor != .pointer);

    testHover(odd, true);
    try std.testing.expect(backgroundTransitionActive(odd));
    try std.testing.expect(Color.eql(tok.bg_active, backgroundTarget(odd)));
    testHover(odd, false);
    try std.testing.expect(Color.eql(tok.bg_secondary, backgroundTarget(odd)));

    // Even row: base transparent.
    const even = (f.slotOf(2) orelse return error.RowNotBound).row;
    testHover(even, true);
    try std.testing.expect(Color.eql(tok.bg_active, backgroundTarget(even)));
    testHover(even, false);
    try std.testing.expect(Color.eql(Color.TRANSPARENT, backgroundTarget(even)));
}

test "Table(virtual): 回收复用槽位后悬停 / 过渡不串到新内容，行作用域不累积" {
    const f = try VirtualFixture.init(.{ .columns = &test_columns, .row_count = 10000, .striped = true });
    defer f.deinit();
    const tok = f.cx.tokens.tokens.color;
    const item_height: f32 = 28 + 1;
    f.scrollTo(0, item_height);

    // Hover row 3 and leave it mid-transition, then scroll it out of range.
    const hovered = f.slotOf(3) orelse return error.RowNotBound;
    testHover(hovered.row, true);
    try std.testing.expect(backgroundTransitionActive(hovered.row));
    // Row subscopes hang off the list's own scope (itself under the body scope).
    const row_parent = f.vl().scope;
    const scopes_before = row_parent.children.items.len;
    // Live non-row children of the list scope (ScrollArea etc.): constant while scrolling.
    const fixed_scopes = liveChildScopes(row_parent) - 2 * boundSlots(f.vl());

    // Scroll 2000 rows: each slot is rebound many times.
    var first: usize = 0;
    while (first < 2000) : (first += 1) f.scrollTo(first, item_height);

    // The hovered slot now carries another row: fresh node, its own base, no hover, no transition.
    const list = f.vl();
    const rebound = list.pool_bindings[hovered.slot] orelse return error.SlotNotRebound;
    try std.testing.expect(rebound != 3);
    for (list.pool_bindings, 0..) |binding, slot| {
        const idx = binding orelse continue;
        const row = list.pool_nodes[slot].children.items[0];
        try std.testing.expectEqual(@as(u32, @intCast(idx)), row.behavior.interaction.a11y.?.row_index);
        const base = if (idx % 2 == 1) tok.bg_secondary else Color.TRANSPARENT;
        try std.testing.expect(Color.eql(base, row.getBackground()));
        try std.testing.expect(!backgroundTransitionActive(row));
        // Exactly one hover listener chain per row (none left over from the previous binding).
        try std.testing.expect(row.behavior.events.on_hover != null);
    }

    // Row subscopes retire with their nodes: two per bound slot (row + divider), independent
    // of how many rows scrolled through.
    const bound = boundSlots(list);
    try std.testing.expect(bound > 0);
    try std.testing.expect(row_parent.children.items.len <= scopes_before + 2 * list.pool_size);
    try std.testing.expect(row_parent.children.items.len < 2 * virtual_list.max_pool_size);
    try std.testing.expectEqual(fixed_scopes + 2 * bound, liveChildScopes(row_parent));
}

fn liveChildScopes(scope: *Scope) usize {
    var n: usize = 0;
    for (scope.children.items) |c| n += @intFromBool(!c.disposed);
    return n;
}

fn boundSlots(list: *VirtualListState) usize {
    var n: usize = 0;
    for (list.pool_bindings) |b| n += @intFromBool(b != null);
    return n;
}

test "Table(virtual): hoverable=false 时行无悬停；有 on_row_click 时才是 pointer" {
    const Sink = struct {
        fn onClick(_: *@This(), _: usize) void {}
    };
    var sink = Sink{};
    const f = try VirtualFixture.init(.{ .columns = &test_columns, .row_count = 10000, .striped = true, .hoverable = false, .on_row_click = Handler(usize).from(Sink, &sink, Sink.onClick) });
    defer f.deinit();
    const tok = f.cx.tokens.tokens.color;
    const row = (f.slotOf(1) orelse return error.RowNotBound).row;
    try std.testing.expect(row.behavior.events.on_hover == null);
    try std.testing.expect(row.behavior.events.on_click != null);
    try std.testing.expect(row.style.cursor == .pointer);
    try std.testing.expect(Color.eql(tok.bg_secondary, backgroundTarget(row)));
}

// styles.zig test collection, this line required; see docs/STYLING.md.
test {
    _ = @import("styles.zig");
}

test "table: 虚拟行（悬停 + 点击 + 斑马纹）的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("table(virtual rows)", struct {
        const Sink = struct {
            fn onClick(_: *@This(), _: usize) void {}
        };
        var sink: Sink = .{};
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Table(.{
                .columns = &test_columns,
                .row_count = 200,
                .striped = true,
                .hoverable = true,
                .on_row_click = Handler(usize).from(Sink, &sink, Sink.onClick),
            }).mount(scope, cx);
            // Rows were rendered during mount (initial VirtualList pass).
            if (stateOf(r).vl_state.?.pool_bindings[0] == null) return error.NoRowsRendered;
            return r.wrapper;
        }
    }.m);
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig.
test "table: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("table", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const cols = [_]ColumnDef{ .{ .id = "name", .header = "Name", .sortable = true }, .{ .id = "size", .header = "Size", .col_align = .right } };
            const r = try Table(.{ .columns = &cols, .row_count = 3, .striped = true }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}

const RecycleCellCtx = struct { label: *Signal([]const u8) };

fn recycleCellView(ctx: RecycleCellCtx, row: usize, col: usize) view_dsl.Text(@TypeOf(.{}), view_dsl.Fmt("{s}:{d}.{d}", struct { *Signal([]const u8), usize, usize })) {
    return view_dsl.text(.{}, view_dsl.fmt("{s}:{d}.{d}", .{ ctx.label, row, col }));
}

fn liveScopeCount(scope: *Scope) usize {
    var n: usize = @intFromBool(!scope.disposed);
    for (scope.children.items) |c| n += liveScopeCount(c);
    return n;
}

fn liveEffectCount(cx: *Cx) usize {
    return cx.owner.graph.countByKind().get(.effect);
}

fn subtreeHasTextT(root: *Node, want: []const u8) bool {
    if (root.getText()) |t| {
        if (std.mem.eql(u8, t.content, want)) return true;
    }
    for (root.children.items) |c| {
        if (subtreeHasTextT(c, want)) return true;
    }
    return false;
}

test "Table(virtual).cells: 回收槽位时单元格内容 scope / 绑定效果随行释放，不累积，Signal 更新不触碰已释放节点" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 500);
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    cx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const label = try scope.createSignal([]const u8, "a");

    const result = try Table(.{ .columns = &test_columns, .row_count = 10000 })
        .cells(RecycleCellCtx{ .label = label }, recycleCellView).viewMount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    const f = VirtualFixture{ .cx = cx, .scope = scope, .result = result };
    const item_height: f32 = 28 + 1;
    f.scrollTo(0, item_height);
    try std.testing.expect(subtreeHasTextT(result.wrapper, "a:0.0"));

    const body_scope = stateOf(result).body_scope.?;
    const scopes_before = liveScopeCount(body_scope);
    const effects_before = liveEffectCount(cx);

    // Scroll 300 rows: every slot is rebound many times.
    var first: usize = 0;
    while (first < 300) : (first += 1) f.scrollTo(first, item_height);
    f.scrollTo(0, item_height);

    // Cell content scopes and their bindText effects retire with the row that owns them.
    try std.testing.expectEqual(scopes_before, liveScopeCount(body_scope));
    try std.testing.expectEqual(effects_before, liveEffectCount(cx));

    // Updating the signal reaches only live cells (a retained effect would write a freed node).
    label.set("b");
    try std.testing.expect(subtreeHasTextT(result.wrapper, "b:0.0"));
    try std.testing.expect(!subtreeHasTextT(result.wrapper, "a:0.0"));
}
