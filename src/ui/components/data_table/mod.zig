/// DataTable, advanced data table: column resize drag / filter / pagination.
///
/// Versus basic table.zig: Table = data-agnostic render skeleton (virtual scroll, sort header);
/// DataTable = string-data batteries-included. Retained design: rows/cells in the page window
/// are built once (page_size rows); page/filter = setText swap content + row height 0/N toggle.
///
/// Data contract: strings in `rows` (can pass signal/derived value) must stay valid while current
/// (component doesn't copy cell text). View = f(rows, filter_text, selection, page), refreshed by
/// effect;
/// click/page/filter only propose new selection/page.
///
/// Column resize: 6px handle at table header column edge; drag = slider-style on_event + pointer
/// capture.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const hooks = @import("../../hooks.zig");
// Alias avoids DataTableState.view method name
const view_dsl = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Padding = core.Padding;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const Event = @import("../../events.zig").Event;
const EventResult = @import("../../events.zig").EventResult;
const table_mod = @import("../table/mod.zig");
const input_mod = @import("../input/mod.zig");
const button_mod = @import("../button/mod.zig");
const selection_mod = @import("../selection.zig");

pub const ColumnDef = table_mod.ColumnDef;
pub const SelectionMode = selection_mod.SelectionMode;

// Styling layer extracted to styles.zig; mount only consumes; this file makes no visual decisions

const styles = @import("styles.zig");
const RowColors = styles.RowColors;
const dataTableRootStyle = styles.dataTableRootStyle;
const dataTableBorderWrapStyle = styles.dataTableBorderWrapStyle;
const dataTableHeaderStyle = styles.dataTableHeaderStyle;
const dataTableHeaderCellStyle = styles.dataTableHeaderCellStyle;
const dataTableHeaderTextStyle = styles.dataTableHeaderTextStyle;
const resizeHandleStyle = styles.resizeHandleStyle;
const dataTableRowColors = styles.dataTableRowColors;
const dataTableRowStyle = styles.dataTableRowStyle;
const dataTableCellStyle = styles.dataTableCellStyle;
const dataTableCellTextStyle = styles.dataTableCellTextStyle;
const dataTablePagerStyle = styles.dataTablePagerStyle;
const dataTablePageLabelText = styles.dataTablePageLabelText;

pub const Rows = []const []const []const u8;

pub const DataTableProps = struct {
    columns: []const ColumnDef = &.{},
    /// Row data (row-major; rows[r][c] corresponds one-to-one with columns). Can pass
    /// signal/derived value
    rows: Source(Rows) = .{ .value = &.{} },
    page_size: usize = 10,
    row_height: f32 = 28,
    header_height: f32 = 28,
    striped: bool = true,
    filterable: bool = true,
    resizable: bool = true,
    table_width: ?f32 = null,
    min_col_width: f32 = 60,
    /// Row selection mode. Under .multi: Cmd/Ctrl click toggles, Shift click selects contiguous
    /// range
    selection_mode: SelectionMode = .none,
    /// Selected rows (`rows` original indices). `*Signal` must be created with
    /// `scope.createList(usize, ...)`
    selection: Model([]const usize) = .{ .local = &.{} },
    /// Called after user click/filter changes selection and settles (settled value)
    on_selection_change: ?Handler([]const usize) = null,
    /// Current page (0-indexed). Out-of-bounds displays last page, doesn't write back
    page: Model(usize) = .{ .local = 0 },
    /// Called after user page/filter changes page and settles (settled value)
    on_page_change: ?Handler(usize) = null,
};

/// Create DataTable: `W.DataTable(.{ .columns = &cols, .rows = rows, .selection_mode = .multi })`
pub fn DataTable(props: anytype) DataTableBuilder {
    return .{ .props = reactive.props.coerce(DataTableProps, props) };
}

pub const DataTableBuilder = struct {
    props: DataTableProps,

    pub fn mount(self: DataTableBuilder, scope: *Scope, cx: *Cx) !DataTableResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        return mountDataTable(self.props, scope, cx);
    }
};

pub const DataTableState = struct {
    rows_src: Source(Rows),
    selection_src: reactive.Bound([]const usize),
    page_src: reactive.Bound(usize),
    /// Filter text (component-owned text signal)
    filter: *Signal([]const u8),
    on_page_change: ?Handler(usize),
    alloc: Allocator,
    /// Currently displayed row data
    rows: Rows = &.{},
    columns: []const ColumnDef,
    /// Current width of each column (drag-resizable)
    col_widths: []f32,
    /// Original row indices passing filter
    filtered: std.ArrayListUnmanaged(usize) = .empty,
    /// Temp bitmap for derived selection set (by original row index)
    raw_bits: std.DynamicBitSetUnmanaged = .{},
    /// Currently displayed page (data source value clamped to last page)
    page: usize = 0,
    page_size: usize,
    row_height: f32,
    min_col_width: f32,
    /// Pagination window nodes: row_nodes[vr] / cell_text_nodes[vr * ncols + c]
    row_nodes: []*Node,
    cell_text_nodes: []*Node,
    header_cells: []*Node,
    page_label: *Node,
    page_label_buf: [32]u8 = @as([32]u8, @splat(0)),
    body: *Node,
    cx: *Cx,
    // Column resize drag in-progress state
    resize_col: ?usize = null,
    resize_start_x: f32 = 0,
    resize_start_w: f32 = 0,

    /// Bitmap derived from selection. Index = **filtered row index** (same coordinate system as
    /// filtered),
    /// so Shift range select under filter picks "visible consecutive rows"; anchor is internal
    /// interaction state.
    selection: selection_mod.SelectionModel = .{},
    on_selection_change: ?Handler([]const usize) = null,
    /// Row click event context (length = page_size, reused with pagination window)
    row_click_ctxs: []RowClickCtx = &.{},
    /// Selected row background / normal row background (alternating under striped)
    selection_bg: core.Color = core.Color.TRANSPARENT,
    hovered_row: ?usize = null,
    row_bg_even: core.Color = core.Color.TRANSPARENT,
    row_bg_odd: core.Color = core.Color.TRANSPARENT,

    pub fn filteredCount(self: *const DataTableState) usize {
        return self.filtered.items.len;
    }

    // ---- View ----

    fn view(self: *DataTableState, comptime tracked: bool) !void {
        const rows = self.rows_src.read(tracked);
        const filter = (Source([]const u8){ .signal = self.filter }).read(tracked);
        const sel = self.selection_src.readAs(tracked);
        const page = self.page_src.readAs(tracked);

        if (rows.ptr != self.rows.ptr or rows.len != self.rows.len) {
            // Data changed: anchor on filter index no longer points to original row
            self.selection.anchor = null;
            self.selection.lead = null;
        }
        self.rows = rows;
        try self.filtered.ensureTotalCapacity(self.alloc, rows.len);
        self.filtered.clearRetainingCapacity();
        for (rows, 0..) |row, ri| {
            const hit = blk: {
                if (filter.len == 0) break :blk true;
                for (row) |cell| {
                    if (containsIgnoreCase(cell, filter)) break :blk true;
                }
                break :blk false;
            };
            if (hit) self.filtered.appendAssumeCapacity(ri);
        }
        try self.deriveSelection(sel);
        // Out-of-bounds page only clamped for display, doesn't write to data source
        self.page = @min(page, self.pageCount() - 1);
        self.paint();
    }

    fn viewEffect(self: *DataTableState) void {
        self.view(true) catch |err| std.log.err("[DataTable] update failed: {}", .{err});
    }

    /// selection (original index) -> bitmap on filter index; anchor/lead retained if in range
    fn deriveSelection(self: *DataTableState, sel: []const usize) !void {
        const n = self.filtered.items.len;
        try self.raw_bits.resize(self.alloc, self.rows.len, false);
        self.raw_bits.unsetAll();
        for (sel) |raw| {
            // Out-of-bounds index (after data shrinks) just doesn't display, doesn't write back
            if (raw < self.rows.len) self.raw_bits.set(raw);
        }
        const anchor = self.selection.anchor;
        const lead = self.selection.lead;
        try self.selection.resize(self.alloc, n);
        for (self.filtered.items, 0..) |raw, fi| {
            if (self.raw_bits.isSet(raw)) self.selection.setSelected(fi, true);
        }
        if (anchor) |a| self.selection.anchor = if (a < n) a else null;
        if (lead) |l| self.selection.lead = if (l < n) l else null;
    }

    /// After interaction, re-derive from current data source value (effect doesn't run if proposal
    /// blocked/unchanged)
    fn resync(self: *DataTableState) void {
        self.deriveSelection(self.selection_src.peek()) catch |err| {
            std.log.err("[DataTable] selection resync failed: {}", .{err});
            return;
        };
        self.applySelectionStyles();
    }

    // ---- Interaction: propose only ----

    /// Click filtered row fi: compute result on derived bitmap, propose whole, then re-derive from
    /// settled value.
    /// If proposal doesn't settle as-is (split blocks/rewrites), anchor/lead reverts to pre-click.
    fn clickFiltered(self: *DataTableState, fi: usize, intent: selection_mod.ClickIntent) void {
        const anchor = self.selection.anchor;
        const lead = self.selection.lead;
        self.selection.applyClick(fi, intent);
        if (!self.proposeSelectionFromBits()) {
            self.selection.anchor = anchor;
            self.selection.lead = lead;
        }
    }

    /// Return whether data source equals proposal (settles as-is or was already this value)
    fn proposeSelectionFromBits(self: *DataTableState) bool {
        const out = self.alloc.alloc(usize, self.selection.selected_count) catch |err| {
            std.log.err("[DataTable] selection proposal failed: {}", .{err});
            self.resync();
            return false;
        };
        defer self.alloc.free(out);
        var n: usize = 0;
        for (self.filtered.items, 0..) |raw, fi| {
            if (n < out.len and self.selection.isSelected(fi)) {
                out[n] = raw;
                n += 1;
            }
        }
        const on_change = self.on_selection_change;
        const landed = self.selection_src.commit(out[0..n]);
        const accepted = std.mem.eql(usize, self.selection_src.peek(), out[0..n]);
        self.resync();
        if (landed) |v| if (on_change) |h| h.call(v);
        return accepted;
    }

    fn proposePage(self: *DataTableState, page: usize) void {
        const on_change = self.on_page_change;
        const landed = self.page_src.commit(page) orelse return;
        if (on_change) |h| h.call(landed);
    }

    /// Original row index -> whether displays as selected (param is rows[] index, not filter index)
    pub fn isRowSelected(self: *const DataTableState, raw_row: usize) bool {
        for (self.filtered.items, 0..) |raw, fi| {
            if (raw == raw_row) return self.selection.isSelected(fi);
        }
        return false;
    }

    /// Sync selection state to row node background in current pagination window
    pub fn applySelectionStyles(self: *DataTableState) void {
        const base = self.page * self.page_size;
        for (self.row_nodes, 0..) |row_node, vr| {
            const fi = base + vr;
            const has_data = fi < self.filtered.items.len;
            const normal = if (vr % 2 == 1) self.row_bg_odd else self.row_bg_even;
            const visual = styles.rowVisual(normal, has_data and self.selection.isSelected(fi), self.hovered_row == vr, self.cx.tokens);
            row_node.setBackgroundRaw(visual.background.?);
            for (0..self.columns.len) |ci| {
                const label = self.cell_text_nodes[vr * self.columns.len + ci];
                if (label.getText()) |old| {
                    var text = old;
                    text.color = styles.dataTableRowTextColor(has_data and self.selection.isSelected(fi), self.cx.tokens);
                    label.setText(text);
                }
            }
            if (row_node.behavior.interaction.a11y) |*a| {
                a.selected = has_data and self.selection.isSelected(fi);
            }
            row_node.markRenderDirty();
        }
    }

    pub fn pageCount(self: *const DataTableState) usize {
        const count = self.filtered.items.len;
        if (count == 0) return 1;
        return (count + self.page_size - 1) / self.page_size;
    }

    /// Paint current view state to pagination window nodes
    fn paint(self: *DataTableState) void {
        const ncols = self.columns.len;
        const base = self.page * self.page_size;
        const count = self.filtered.items.len;
        for (self.row_nodes, 0..) |row_node, vr| {
            const has_data = base + vr < count;
            row_node.style.height = .{ .px = if (has_data) self.row_height else 0 };
            row_node.setHitTestVisible(has_data);
            // Keep the row as semantic parent but hide its complete subtree
            // when this recycled slot has no data. Dropping only the row role
            // would reparent its still-semantic cells to the grid.
            row_node.behavior.interaction.a11y = .{
                .role = .row,
                .hidden = !has_data,
                .row_index = @intCast(base + vr),
                .selected = has_data and self.selection.isSelected(base + vr),
            };
            if (has_data) {
                const data_row = self.rows[self.filtered.items[base + vr]];
                for (0..ncols) |c| {
                    const cell_text = self.cell_text_nodes[vr * ncols + c];
                    if (cell_text.parent) |cell| {
                        cell.behavior.interaction.a11y = .{
                            .role = .gridcell,
                            .row_index = @intCast(base + vr),
                            .column_index = @intCast(c),
                        };
                    }
                    if (cell_text.getText()) |old| {
                        var t = old;
                        t.content = if (c < data_row.len) data_row[c] else "";
                        cell_text.setText(t);
                    }
                    cell_text.markRenderDirty();
                }
            }
        }

        const label = std.fmt.bufPrint(&self.page_label_buf, "Page {d} / {d}", .{
            self.page + 1, self.pageCount(),
        }) catch "Page ?";
        if (self.page_label.getText()) |old| {
            var t = old;
            t.content = label;
            self.page_label.setText(t);
        }
        self.page_label.markRenderDirty();
        self.applySelectionStyles();
        self.body.markLayoutDirty();
    }

    pub fn nextPage(self: *DataTableState) void {
        if (self.page + 1 < self.pageCount()) self.proposePage(self.page + 1);
    }

    pub fn prevPage(self: *DataTableState) void {
        if (self.page > 0) self.proposePage(self.page - 1);
    }

    /// Apply column width (header + all body cells of column)
    fn applyColWidth(self: *DataTableState, col: usize, w: f32) void {
        const clamped = @max(w, self.min_col_width);
        self.col_widths[col] = clamped;
        self.header_cells[col].style.width = .{ .px = clamped };
        const ncols = self.columns.len;
        for (0..self.row_nodes.len) |vr| {
            // cell text parent is cell box (fixed width)
            if (self.cell_text_nodes[vr * ncols + col].parent) |cell| {
                cell.style.width = .{ .px = clamped };
            }
        }
        self.body.markLayoutDirty();
    }
};

pub const DataTableResult = struct {
    wrapper: *Node,
    /// Selected rows signal (null when `ui.split`)
    selection: ?*Signal([]const usize),
    /// Page signal (null when `ui.split`)
    page: ?*Signal(usize),
    /// Filter input wrapper (null when filterable=false)
    filter_input: ?*Node = null,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: DataTableResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Filter changed: filter indices reshuffled, old selection/anchor/page no longer match visible
/// rows;
/// propose clear selection, go to first page
fn onFilterChanged(state: *DataTableState, text: []const u8) void {
    state.filter.set(text);
    state.selection.anchor = null;
    state.selection.lead = null;
    if (state.selection_src.peek().len > 0) {
        const on_change = state.on_selection_change;
        if (state.selection_src.commit(&.{})) |v| if (on_change) |h| h.call(v);
    }
    state.proposePage(0);
}

/// Row click -> selection model. Use on_event not on_click, need to read modifiers
/// (Cmd/Ctrl toggle, Shift range), parameterless on_click from HandlerRef can't get them.
fn rowClickHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *RowClickCtx = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .click => |c| {
            const state = ctx.state;
            if (state.selection.mode == .none) return .ignored;
            const fi = state.page * state.page_size + ctx.visible_row;
            if (fi >= state.filtered.items.len) return .ignored;
            state.clickFiltered(fi, .{
                // macOS uses Cmd, other platforms Ctrl, both recognized
                .toggle = c.modifiers.super or c.modifiers.ctrl,
                .range = c.modifiers.shift,
            });
            return .stop;
        },
        else => return .ignored,
    }
}

fn rowHover(ptr: *anyopaque) void {
    const c: *RowClickCtx = @ptrCast(@alignCast(ptr));
    c.state.hovered_row = c.visible_row;
    c.state.applySelectionStyles();
}
fn rowLeave(ptr: *anyopaque) void {
    const c: *RowClickCtx = @ptrCast(@alignCast(ptr));
    if (c.state.hovered_row == c.visible_row) c.state.hovered_row = null;
    c.state.applySelectionStyles();
}

const RowClickCtx = struct {
    state: *DataTableState,
    /// Row index within pagination window (0..page_size)
    visible_row: usize,
};

fn onPrevClick(ctx: *anyopaque) void {
    const state: *DataTableState = @ptrCast(@alignCast(ctx));
    state.prevPage();
}

fn onNextClick(ctx: *anyopaque) void {
    const state: *DataTableState = @ptrCast(@alignCast(ctx));
    state.nextPage();
}

/// Column resize handle event context
const ResizeCtx = struct {
    state: *DataTableState,
    col: usize,
    handle: *Node,
};

fn resizeEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *ResizeCtx = @ptrCast(@alignCast(context orelse return .ignored));
    const state = ctx.state;
    switch (event) {
        .mouse_down => |e| {
            state.resize_col = ctx.col;
            state.resize_start_x = e.x;
            state.resize_start_w = state.col_widths[ctx.col];
            state.cx.setPointerCapture(ctx.handle);
            return .stop;
        },
        .mouse_move => |e| {
            if (state.resize_col == ctx.col) {
                state.applyColWidth(ctx.col, state.resize_start_w + (e.x - state.resize_start_x));
                return .stop;
            }
        },
        .mouse_up => {
            if (state.resize_col == ctx.col) {
                state.resize_col = null;
                state.cx.releasePointerCapture();
                return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

fn mountDataTable(props_in: DataTableProps, scope: *Scope, cx: *Cx) !DataTableResult {
    // page_size = 0 causes pageCount division by zero; minimum one row per page.
    var props = props_in;
    props.page_size = @max(props.page_size, 1);
    const my_scope = try scope.childScope();
    var scope_bound = false;
    errdefer if (!scope_bound) my_scope.dispose();
    const t = cx.tokens;
    const ncols = props.columns.len;
    reactive.checkBorrow(my_scope, props.rows);

    var total_width: f32 = 0;
    for (props.columns) |col| total_width += col.width;
    const table_width = props.table_width orelse total_width;

    const selection_src = try reactive.resolveListModel(usize, my_scope, props.selection);
    const page_src = try reactive.resolveModel(usize, my_scope, props.page);
    const filter = try my_scope.createText("", .{});

    // -- State (centralized allocation/freeing of all slices) --
    const state = try my_scope.allocator.create(DataTableState);
    // Allocations below must be freed on any failure before registration; after success owned by
    // state.cleanup.
    var state_adopted = false;
    errdefer if (!state_adopted) my_scope.allocator.destroy(state);
    const col_widths = try my_scope.allocator.alloc(f32, ncols);
    errdefer if (!state_adopted) my_scope.allocator.free(col_widths);
    for (props.columns, 0..) |col, i| col_widths[i] = col.width;
    const row_nodes = try my_scope.allocator.alloc(*Node, props.page_size);
    errdefer if (!state_adopted) my_scope.allocator.free(row_nodes);
    const cell_text_nodes = try my_scope.allocator.alloc(*Node, props.page_size * ncols);
    errdefer if (!state_adopted) my_scope.allocator.free(cell_text_nodes);
    const header_cells = try my_scope.allocator.alloc(*Node, ncols);
    errdefer if (!state_adopted) my_scope.allocator.free(header_cells);
    // Selection bitmap grows with data in view
    var sel_model = try selection_mod.SelectionModel.init(my_scope.allocator, props.selection_mode, 0);
    errdefer if (!state_adopted) sel_model.deinit(my_scope.allocator);
    // Row click context: one per pagination row (fixed count = page_size, doesn't grow with data)
    const row_click_ctxs = try my_scope.allocator.alloc(RowClickCtx, props.page_size);
    errdefer if (!state_adopted) my_scope.allocator.free(row_click_ctxs);
    // cleanup reads these fields to free, but full `state.* = .{...}` only written at mount end:
    // any failure mid-way, scope dispose runs cleanup sees undefined pointers.
    // Write cleanup-needed fields first, then register.
    state.* = undefined;
    state.col_widths = col_widths;
    state.filtered = .empty;
    state.raw_bits = .{};
    state.row_nodes = row_nodes;
    state.cell_text_nodes = cell_text_nodes;
    state.header_cells = header_cells;
    state.selection = sel_model;
    state.row_click_ctxs = row_click_ctxs;
    // From now ownership is one or other: adopt success goes to scope, adopt failure cleans up on
    // spot,
    // either way above errdefer can't run again, so flip flag **before** call.
    state_adopted = true;
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const s: *DataTableState = @ptrCast(@alignCast(ptr));
            alloc.free(s.col_widths);
            s.filtered.deinit(alloc);
            s.raw_bits.deinit(alloc);
            alloc.free(s.row_nodes);
            alloc.free(s.cell_text_nodes);
            alloc.free(s.header_cells);
            alloc.free(s.row_click_ctxs);
            s.selection.deinit(alloc);
            alloc.destroy(s);
        }
    }.cleanup);

    const ResizeCtxHolder = struct { ctxs: []ResizeCtx };
    const resize_holder = try my_scope.allocator.create(ResizeCtxHolder);
    {
        errdefer my_scope.allocator.destroy(resize_holder);
        resize_holder.* = .{ .ctxs = try my_scope.allocator.alloc(ResizeCtx, if (props.resizable) ncols else 0) };
    }
    const resize_ctxs = resize_holder.ctxs;
    try my_scope.adoptResource(@ptrCast(resize_holder), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const h: *ResizeCtxHolder = @ptrCast(@alignCast(ptr));
            alloc.free(h.ctxs);
            alloc.destroy(h);
        }
    }.cleanup);

    const row_colors = dataTableRowColors(props.striped, t);
    // Header cell and pagination window row (fixed page_size row nodes, reused on page) handles
    // written directly to state arrays
    const build: BuildCtx = .{
        .t = t,
        .columns = props.columns,
        .ncols = ncols,
        .row_height = props.row_height,
        .selectable = props.selection_mode != .none,
        .row_colors = row_colors,
        .header_cells = header_cells,
        .row_nodes = row_nodes,
        .cell_text_nodes = cell_text_nodes,
        .resize_ctxs = resize_ctxs,
        .state = state,
    };
    const page_rows: []const void = @as([*]const void, undefined)[0..props.page_size];

    // -- Structure: column [filter?] [table] [pagination] --
    const Parts = struct {
        input: input_mod.InputResult = undefined,
        body: *Node = undefined,
        page_label: *Node = undefined,
    };
    var parts: Parts = .{};
    const root = try view_dsl.render(my_scope, cx, view_dsl.box(.{
        .style = dataTableRootStyle(table_width),
        // role=grid: AT uses this to enable table nav (by column/row), announces "row R column C".
        // Without it, whole table is unstructured text stream on AT side.
        .a11y = core.A11yProps{
            .role = .grid,
            .multiselectable = props.selection_mode == .multi,
        },
    }, .{
        if (props.filterable) view_dsl.capture(&parts.input, input_mod.Input(.{
            .placeholder = "Filter rows…",
            .width = @min(table_width, 260),
            .on_change = cx.on(DataTableState, state, onFilterChanged),
        })) else null,
        view_dsl.box(.{ .style = dataTableBorderWrapStyle(table_width, t) }, .{
            // -- Header (includes resize handle) --
            view_dsl.box(.{
                .style = dataTableHeaderStyle(props.header_height, t),
                .a11y = core.A11yProps{ .role = .row, .row_index = 0 },
            }, view_dsl.items(&build, props.columns, headerCellElement)),
            // -- Body: page_size fixed row nodes --
            view_dsl.capture(&parts.body, view_dsl.col(.{ .style = grow_fit }, view_dsl.items(&build, page_rows, rowElement))),
        }),
        // ── Pagination ──
        view_dsl.box(.{ .style = dataTablePagerStyle() }, .{
            button_mod.Button(.{
                .label = "Prev",
                .variant = .secondary,
                .size = .sm,
                .on_click = core.Cx.simpleHandler(onPrevClick, state),
            }),
            button_mod.Button(.{
                .label = "Next",
                .variant = .secondary,
                .size = .sm,
                .on_click = core.Cx.simpleHandler(onNextClick, state),
            }),
            // Text rewritten at paint time (borrowed content)
            view_dsl.capture(&parts.page_label, view_dsl.text(.{ .style = dataTablePageLabelText(t) }, "Page 1 / 1")),
        }),
    }));
    // sweep: root guards to return (disposes bound my_scope); subtree attached once built
    errdefer cx.freeNode(root);
    root.meta.ownership.meta.component_name = "DataTable";
    try core.bindScopeToNode(my_scope, root);
    scope_bound = true;

    const filter_input_node: ?*Node = if (props.filterable) parts.input.node else null;
    const body = parts.body;
    const page_label = parts.page_label;

    // Row selection: use on_event to get modifiers (Cmd/Ctrl toggle, Shift range)
    for (row_nodes, 0..) |row_node, vr| {
        row_click_ctxs[vr] = .{ .state = state, .visible_row = vr };
        if (props.selection_mode != .none) {
            row_node.behavior.events.event_context = @ptrCast(&row_click_ctxs[vr]);
            row_node.behavior.events.on_event = rowClickHandler;
        }
        hooks.setHoverHandler(row_node, true, Cx.simpleHandler(rowHover, &row_click_ctxs[vr]));
        hooks.setHoverHandler(row_node, false, Cx.simpleHandler(rowLeave, &row_click_ctxs[vr]));
    }
    // Column resize handle (raw on_event)
    for (resize_ctxs, 0..) |*rc, ci| {
        rc.state = state;
        rc.col = ci;
        rc.handle.behavior.events.event_context = @ptrCast(rc);
        rc.handle.behavior.events.on_event = resizeEventHandler;
    }

    state.* = .{
        .rows_src = props.rows,
        .selection_src = selection_src,
        .page_src = page_src,
        .filter = filter,
        .on_page_change = props.on_page_change,
        .alloc = my_scope.allocator,
        .columns = props.columns,
        .col_widths = col_widths,
        .page_size = props.page_size,
        .row_height = props.row_height,
        .min_col_width = props.min_col_width,
        .row_nodes = row_nodes,
        .cell_text_nodes = cell_text_nodes,
        .header_cells = header_cells,
        .page_label = page_label,
        .body = body,
        .cx = cx,
        .selection = sel_model,
        .on_selection_change = props.on_selection_change,
        .row_click_ctxs = row_click_ctxs,
        .selection_bg = row_colors.selection,
        .row_bg_even = row_colors.even,
        .row_bg_odd = row_colors.odd,
    };
    root.addDebugState(@ptrCast(state));
    try state.view(false);
    // selection/page/filter text are mutable sources: must have effect
    try my_scope.createEffect(state, DataTableState.viewEffect);

    return .{
        .wrapper = root,
        .selection = selection_src.asSignal(),
        .page = page_src.asSignal(),
        .filter_input = filter_input_node,
    };
}

const grow_fit = core.BoxStyle{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } };

/// Mount-time header/row build context (handles written to pre-allocated state arrays)
const BuildCtx = struct {
    t: *const core.ThemeTokens,
    columns: []const ColumnDef,
    ncols: usize,
    row_height: f32,
    selectable: bool,
    row_colors: styles.RowColors,
    header_cells: []*Node,
    row_nodes: []*Node,
    cell_text_nodes: []*Node,
    resize_ctxs: []ResizeCtx,
    state: *DataTableState,
};

const GrowProps = struct { style: core.BoxStyle };
const CellTextProps = struct { style: core.TextStyle };
const CellText = view_dsl.Attrs(GrowProps, view_dsl.Text(CellTextProps, []const u8));
const HandleProps = struct { style: struct { core.BoxStyle, core.BoxStyle } };
const HeaderCellProps = struct { style: core.BoxStyle, a11y: core.A11yProps };
const HeaderCell = view_dsl.NodeCapture(**Node, view_dsl.Box(HeaderCellProps, struct { CellText, ?view_dsl.NodeCapture(**Node, view_dsl.Box(HandleProps, void, null)) }, null));

/// Header cell. Header must be columnheader not plain cell; AT uses it to announce column when
/// reading
/// each data cell with column name ("Name: Alice" not just "Alice").
fn headerCellElement(b: *const BuildCtx, col: ColumnDef, ci: usize) HeaderCell {
    return view_dsl.capture(&b.header_cells[ci], view_dsl.box(HeaderCellProps{
        .style = dataTableHeaderCellStyle(col.width),
        .a11y = .{
            .role = .columnheader,
            .label = col.header,
            .row_index = 0,
            .column_index = @intCast(ci),
        },
    }, .{
        // Title text grows to width (pushes resize handle to column edge)
        view_dsl.attrs(GrowProps{ .style = grow_fit }, view_dsl.text(CellTextProps{ .style = dataTableHeaderTextStyle(b.t) }, col.header)),
        if (b.resize_ctxs.len > 0) view_dsl.capture(&b.resize_ctxs[ci].handle, view_dsl.box(HandleProps{
            .style = .{ resizeHandleStyle(), core.BoxStyle{ .hit_roles = .{ .pointer = true } } },
        }, {})) else null,
    }));
}

const RowProps = struct { style: struct { core.BoxStyle, core.BoxStyle }, a11y: core.A11yProps };
const CellProps = struct { style: core.BoxStyle, a11y: core.A11yProps };
const CellCtx = struct { b: *const BuildCtx, vr: usize };
const Cell = view_dsl.Box(CellProps, view_dsl.NodeCapture(**Node, CellText), null);
const Row = view_dsl.NodeCapture(**Node, view_dsl.Box(RowProps, view_dsl.ItemsOf(CellCtx, []const ColumnDef, cellElement), null));

/// Row in pagination window (node reuse: rows beyond data count collapsed to 0 height; a11y must
/// hide them (synced hidden in syncPage), else AT speaks a string of empty rows)
fn rowElement(b: *const BuildCtx, _: void, vr: usize) Row {
    return view_dsl.capture(&b.row_nodes[vr], view_dsl.box(RowProps{
        .style = .{
            dataTableRowStyle(if (vr % 2 == 1) b.row_colors.odd else b.row_colors.even, b.row_height),
            if (b.selectable) core.BoxStyle{ .cursor = .pointer } else core.BoxStyle{},
        },
        .a11y = .{ .role = .row, .row_index = @intCast(vr) },
    }, view_dsl.items(CellCtx{ .b = b, .vr = vr }, b.columns, cellElement)));
}

/// Cell text rewritten at paint time (borrowed row data)
fn cellElement(c: CellCtx, col: ColumnDef, ci: usize) Cell {
    return view_dsl.box(CellProps{
        .style = dataTableCellStyle(col.width),
        .a11y = .{
            .role = .gridcell,
            .row_index = @intCast(c.vr),
            .column_index = @intCast(ci),
        },
    }, view_dsl.capture(&c.b.cell_text_nodes[c.vr * c.b.ncols + ci], view_dsl.attrs(GrowProps{ .style = grow_fit }, view_dsl.text(CellTextProps{ .style = dataTableCellTextStyle(c.b.t) }, @as([]const u8, "")))));
}

// ============================================================================
// Tests
// ============================================================================

const test_rows = [_][]const []const u8{
    &.{ "Alice", "Admin" },
    &.{ "Bob", "User" },
    &.{ "Carol", "User" },
    &.{ "Dave", "Editor" },
    &.{ "Eve", "User" },
};
const test_cols = [_]ColumnDef{
    .{ .id = "name", .header = "Name", .width = 120 },
    .{ .id = "role", .header = "Role", .width = 100 },
};

fn mountForTest(cx: *Cx, scope: *Scope, page_size: usize) !DataTableResult {
    return DataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = page_size,
        .filterable = false,
    }).mount(scope, cx);
}

fn stateOf(r: DataTableResult) *DataTableState {
    return @ptrCast(@alignCast(r.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
}

test "DataTable: page_size = 0 不除零" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const dt = try mountForTest(cx, scope, 0);
    try root.appendChild(testing.allocator, dt.wrapper);
    try testing.expect(stateOf(dt).pageCount() >= 1);
    try stateOf(dt).view(false);
}

test "DataTable: 分页窗口 + 翻页" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountForTest(cx, scope, 2);
    try root.appendChild(testing.allocator, dt.wrapper);

    try testing.expectEqual(@as(usize, 5), stateOf(dt).filteredCount());
    try testing.expectEqual(@as(usize, 3), stateOf(dt).pageCount());
    // First page: Alice/Bob visible
    try testing.expectEqualStrings("Alice", stateOf(dt).cell_text_nodes[0].getText().?.content);
    try testing.expectEqualStrings("Bob", stateOf(dt).cell_text_nodes[2].getText().?.content);

    stateOf(dt).nextPage();
    try testing.expectEqual(@as(usize, 1), stateOf(dt).page);
    try testing.expectEqualStrings("Carol", stateOf(dt).cell_text_nodes[0].getText().?.content);

    // Last page has 1 row: second row collapsed to 0 height
    stateOf(dt).nextPage();
    try testing.expectEqualStrings("Eve", stateOf(dt).cell_text_nodes[0].getText().?.content);
    try testing.expectEqual(@as(f32, 0), stateOf(dt).row_nodes[1].style.height.px);
    // Out-of-bounds page change no-op
    stateOf(dt).nextPage();
    try testing.expectEqual(@as(usize, 2), stateOf(dt).page);
}

test "DataTable: 筛选跨列匹配 + 重置回第一页" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    // page_size=2: after filter still 2 pages, page reset can't pass by clamping
    const dt = try mountForTest(cx, scope, 2);
    try root.appendChild(testing.allocator, dt.wrapper);

    dt.page.?.set(1);
    try testing.expectEqual(@as(usize, 1), stateOf(dt).page);
    onFilterChanged(stateOf(dt), "user");
    try testing.expectEqual(@as(usize, 3), stateOf(dt).filteredCount()); // Bob/Carol/Eve
    try testing.expectEqual(@as(usize, 0), stateOf(dt).page);
    try testing.expectEqual(@as(usize, 2), stateOf(dt).pageCount());
    try testing.expectEqual(@as(usize, 0), dt.page.?.peek());
    try testing.expectEqualStrings("Bob", stateOf(dt).cell_text_nodes[0].getText().?.content);

    onFilterChanged(stateOf(dt), "zzz");
    try testing.expectEqual(@as(usize, 0), stateOf(dt).filteredCount());
    try testing.expectEqual(@as(f32, 0), stateOf(dt).row_nodes[0].style.height.px);
    try testing.expectEqualStrings("Page 1 / 1", stateOf(dt).page_label.getText().?.content);
}

test "DataTable: 列宽调整应用到表头与所有 cell 并钳最小宽" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try DataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = 3,
        .filterable = false,
        .min_col_width = 60,
    }).mount(scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    stateOf(dt).applyColWidth(0, 200);
    try testing.expectEqual(@as(f32, 200), stateOf(dt).col_widths[0]);
    try testing.expectEqual(@as(f32, 200), stateOf(dt).header_cells[0].style.width.px);
    try testing.expectEqual(@as(f32, 200), stateOf(dt).cell_text_nodes[0].parent.?.style.width.px);
    // Clamp min width
    stateOf(dt).applyColWidth(0, 10);
    try testing.expectEqual(@as(f32, 60), stateOf(dt).col_widths[0]);
}

// -- Row selection --

const SelChangeCounter = struct {
    n: usize = 0,
    last: [8]usize = undefined,
    last_len: usize = 0,
    fn bump(self: *SelChangeCounter, v: []const usize) void {
        self.n += 1;
        self.last_len = @min(v.len, self.last.len);
        @memcpy(self.last[0..self.last_len], v[0..self.last_len]);
    }
};

fn clickRow(dt: DataTableResult, visible_row: usize, mods: core.Modifiers) void {
    _ = rowClickHandler(
        .{ .click = .{ .x = 0, .y = 0, .modifiers = mods } },
        @ptrCast(&stateOf(dt).row_click_ctxs[visible_row]),
    );
}

test "DataTable: 默认 selection_mode=.none —— 点击不选中（既有行为不变）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountForTest(cx, scope, 5);
    try root.appendChild(testing.allocator, dt.wrapper);

    try testing.expectEqual(SelectionMode.none, stateOf(dt).selection.mode);
    // At .none row nodes don't attach event handlers at all
    try testing.expect(stateOf(dt).row_nodes[0].behavior.events.on_event == null);
    try testing.expectEqual(@as(usize, 0), stateOf(dt).selection.selected_count);
}

test "DataTable: multi 多选 —— Cmd 切换 / Shift 区间 / 底色 / 回调" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    var counter = SelChangeCounter{};
    const dt = try DataTable(.{
        .columns = &test_cols,
        .rows = &test_rows, // 5 rows
        .page_size = 5,
        .filterable = false,
        .selection_mode = .multi,
        .on_selection_change = cx.on(SelChangeCounter, &counter, SelChangeCounter.bump),
    }).mount(scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    // Events wired up (regression guard: DataTable previously had no selection field)
    try testing.expect(stateOf(dt).row_nodes[0].behavior.events.on_event != null);

    // Click row 1 unmodified
    clickRow(dt, 1, .{});
    try testing.expectEqual(@as(usize, 1), stateOf(dt).selection.selected_count);
    try testing.expect(stateOf(dt).isRowSelected(1));
    try testing.expectEqual(@as(usize, 1), counter.n);
    // Background painted
    try testing.expect(stateOf(dt).row_nodes[1].getBackground().eql(stateOf(dt).selection_bg));
    try testing.expect(!stateOf(dt).row_nodes[0].getBackground().eql(stateOf(dt).selection_bg));

    // Cmd-click row 3 -> both rows selected
    clickRow(dt, 3, .{ .super = true });
    try testing.expectEqual(@as(usize, 2), stateOf(dt).selection.selected_count);
    try testing.expect(stateOf(dt).isRowSelected(1) and stateOf(dt).isRowSelected(3));

    // Shift-click row 4 -> redraw range 3..4 with anchor(3)
    clickRow(dt, 4, .{ .shift = true });
    try testing.expectEqual(@as(usize, 2), stateOf(dt).selection.selected_count);
    try testing.expect(stateOf(dt).isRowSelected(3) and stateOf(dt).isRowSelected(4));
    try testing.expect(!stateOf(dt).isRowSelected(1));

    // selection signal has original row index, callback gets settled value
    try testing.expectEqualSlices(usize, &.{ 3, 4 }, dt.selection.?.peek());
    try testing.expectEqualSlices(usize, &.{ 3, 4 }, counter.last[0..counter.last_len]);

    // Click row 0 unmodified -> clears others
    clickRow(dt, 0, .{});
    try testing.expectEqual(@as(usize, 1), stateOf(dt).selection.selected_count);
    try testing.expect(stateOf(dt).isRowSelected(0));
    try testing.expectEqual(@as(usize, 4), counter.n); // 4 total clicks, one callback per click
}

test "DataTable: single 模式只保留一行（修饰键不生效）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try DataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = 5,
        .filterable = false,
        .selection_mode = .single,
    }).mount(scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    clickRow(dt, 1, .{});
    clickRow(dt, 3, .{ .super = true }); // Cmd ineffective in single mode
    try testing.expectEqual(@as(usize, 1), stateOf(dt).selection.selected_count);
    try testing.expect(stateOf(dt).isRowSelected(3));
    try testing.expect(!stateOf(dt).isRowSelected(1));
}

test "DataTable: 筛选变化清空选择（过滤序号重排，旧选中位会指错行）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try DataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = 5,
        .selection_mode = .multi,
    }).mount(scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    clickRow(dt, 0, .{});
    clickRow(dt, 2, .{ .super = true });
    try testing.expectEqual(@as(usize, 2), stateOf(dt).selection.selected_count);

    onFilterChanged(stateOf(dt), "Alice");
    try testing.expectEqual(@as(usize, 0), stateOf(dt).selection.selected_count);
    try testing.expect(stateOf(dt).selection.anchor == null);
}

test "DataTable: rows / selection / page 来自外部 signal —— 外部写入刷新视图，越界只钳显示不回写" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const rows = try scope.createSignal(Rows, test_rows[0..2]);
    const sel = try scope.createList(usize, &.{1});
    const page = try scope.createSignal(usize, 0);
    var counter = SelChangeCounter{};
    const dt = try DataTable(.{
        .columns = &test_cols,
        .rows = rows,
        .page_size = 2,
        .filterable = false,
        .selection_mode = .multi,
        .selection = sel,
        .page = page,
        .on_selection_change = cx.on(SelChangeCounter, &counter, SelChangeCounter.bump),
    }).mount(scope, cx);
    defer cx.freeNode(dt.wrapper);
    const st = stateOf(dt);
    try testing.expect(dt.selection.? == sel);
    try testing.expect(st.isRowSelected(1) and !st.isRowSelected(0));
    try testing.expectEqualStrings("Bob", st.cell_text_nodes[2].getText().?.content);

    rows.set(&test_rows); // 5 rows
    try testing.expectEqual(@as(usize, 5), st.filteredCount());
    page.set(2);
    try testing.expectEqualStrings("Eve", st.cell_text_nodes[0].getText().?.content);
    page.set(9); // Out-of-bounds: display last page, data source unchanged
    try testing.expectEqual(@as(usize, 2), st.page);
    try testing.expectEqual(@as(usize, 9), page.peek());

    sel.set(&.{ 4, 7 }); // 7 out-of-bounds: doesn't display, doesn't write back
    try testing.expect(st.isRowSelected(4));
    try testing.expect(st.row_nodes[0].getBackground().eql(st.selection_bg));
    try testing.expectEqualSlices(usize, &.{ 4, 7 }, sel.peek());
    try testing.expectEqual(@as(usize, 0), counter.n); // External write doesn't trigger callback

    rows.set(test_rows[0..3]); // Data shrinks: page clamped to last
    try testing.expectEqual(@as(usize, 1), st.page);
    try testing.expectEqualStrings("Carol", st.cell_text_nodes[0].getText().?.content);
    // Out-of-bounds indices (4, 7) can't be clamped into last row
    for (0..3) |r| try testing.expect(!st.isRowSelected(r));
}

test "DataTable: 翻页提议 page，ui.split 拦截时视图不动；选择被拦截时位图回到数据源" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Parent = struct {
        page: *Signal(usize),
        sel: *Signal([]const usize),
        allow: bool = false,
        page_events: usize = 0,
        fn writePage(self: *@This(), v: usize) void {
            if (self.allow) self.page.set(v);
        }
        fn writeSel(self: *@This(), v: []const usize) void {
            if (self.allow) self.sel.set(v);
        }
        fn onPage(self: *@This(), _: usize) void {
            self.page_events += 1;
        }
    };
    var parent = Parent{ .page = try scope.createSignal(usize, 0), .sel = try scope.createList(usize, &.{}) };
    const dt = try DataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = 2,
        .filterable = false,
        .selection_mode = .multi,
        .page = reactive.split(parent.page, cx.on(Parent, &parent, Parent.writePage)),
        .selection = reactive.split(parent.sel, cx.on(Parent, &parent, Parent.writeSel)),
        .on_page_change = cx.on(Parent, &parent, Parent.onPage),
    }).mount(scope, cx);
    defer cx.freeNode(dt.wrapper);
    const st = stateOf(dt);
    try testing.expect(dt.page == null and dt.selection == null);

    st.nextPage(); // Blocked
    try testing.expectEqual(@as(usize, 0), st.page);
    try testing.expectEqual(@as(usize, 0), parent.page_events);
    clickRow(dt, 1, .{}); // Blocked: can't display as selected
    try testing.expect(!st.isRowSelected(1));
    try testing.expect(!st.row_nodes[1].getBackground().eql(st.selection_bg));

    parent.allow = true;
    st.nextPage();
    try testing.expectEqual(@as(usize, 1), st.page);
    try testing.expectEqual(@as(usize, 1), parent.page_events);
    try testing.expectEqualStrings("Carol", st.cell_text_nodes[0].getText().?.content);
    clickRow(dt, 1, .{}); // Page 2 row 2 = original index 3, anchor = 3
    try testing.expectEqualSlices(usize, &.{3}, parent.sel.peek());
    try testing.expect(st.isRowSelected(3));

    // Blocked click can't move anchor: then Shift-click page 2 row 1 = range 2..3
    parent.allow = false;
    clickRow(dt, 0, .{});
    try testing.expect(!st.isRowSelected(2));
    parent.allow = true;
    clickRow(dt, 0, .{ .shift = true });
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, parent.sel.peek());
}

test "DataTable: 筛选态下点选提议的是原始行下标（不是过滤序号）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const dt = try DataTable(.{ .columns = &test_cols, .rows = &test_rows, .page_size = 5, .selection_mode = .multi }).mount(scope, cx);
    defer cx.freeNode(dt.wrapper);
    onFilterChanged(stateOf(dt), "user"); // Bob(1) / Carol(2) / Eve(4)
    clickRow(dt, 2, .{});
    try testing.expectEqualSlices(usize, &.{4}, dt.selection.?.peek());
    try testing.expect(stateOf(dt).isRowSelected(4));
    clickRow(dt, 0, .{ .shift = true }); // Range by visible rows: Bob..Eve
    try testing.expectEqualSlices(usize, &.{ 1, 2, 4 }, dt.selection.?.peek());
}

test "DataTable: selection 绑定的 signal 不是 createList 创建的 -> 拒绝" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const borrowed = try scope.createSignal([]const usize, &.{});
    try testing.expectError(error.ListModelNotOwned, DataTable(.{ .columns = &test_cols, .rows = &test_rows, .selection = borrowed }).mount(scope, cx));
}

// Test collection for styles.zig; this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// OOM sweep by alloc point, see src/ui/components/oom_sweep.zig
test "data_table: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("data_table", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountForTest(cx, scope, 2)).wrapper;
        }
    }.m);
}

test "data_table: 绑定 signal 的 mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("data_table(bound)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const rows = try scope.createSignal(Rows, &test_rows);
            const sel = try scope.createList(usize, &.{ 1, 3 });
            const r = try DataTable(.{ .columns = &test_cols, .rows = rows, .selection = sel, .selection_mode = .multi, .page_size = 2 }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
