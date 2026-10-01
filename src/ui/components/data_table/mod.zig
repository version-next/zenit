/// DataTable，高级数据表格（B4）：列宽拖拽调整 / 筛选 / 分页
///
/// 与基础 table.zig 的分工：Table = 无数据所有权的渲染骨架（虚拟滚动、排序表头）；
/// DataTable = 持字符串数据的电池全含版。retained 设计：分页窗口内的行/cell 节点
/// 只建一次（page_size 行），翻页/筛选 = setText 换内容 + 行高 0/N 切换。
///
/// 数据契约：`rows` 里的字符串切片必须在组件存活期内有效（组件不拷贝 cell 文本）。
///
/// 列宽调整：表头每列右缘 6px 手柄，拖拽 = slider 同款 on_event + pointer capture。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const Event = @import("../../events.zig").Event;
const EventResult = @import("../../events.zig").EventResult;
const table_mod = @import("../table/mod.zig");
const input_mod = @import("../input/mod.zig");
const button_mod = @import("../button/mod.zig");
const selection_mod = @import("../selection.zig");

pub const ColumnDef = table_mod.ColumnDef;
pub const SelectionMode = selection_mod.SelectionMode;

// ============================================================================
// 样式层已析出到 styles.zig, mount 只消费，本文件不做视觉决策
// ============================================================================

const styles = @import("styles.zig");
const RowColors = styles.RowColors;
const dataTableRootStyle = styles.dataTableRootStyle;
const dataTableBorderWrapStyle = styles.dataTableBorderWrapStyle;
const dataTableHeaderStyle = styles.dataTableHeaderStyle;
const dataTableHeaderCellStyle = styles.dataTableHeaderCellStyle;
const dataTableHeaderTextProps = styles.dataTableHeaderTextProps;
const resizeHandleStyle = styles.resizeHandleStyle;
const dataTableRowColors = styles.dataTableRowColors;
const dataTableRowStyle = styles.dataTableRowStyle;
const dataTableCellStyle = styles.dataTableCellStyle;
const dataTableCellTextProps = styles.dataTableCellTextProps;
const dataTablePagerStyle = styles.dataTablePagerStyle;
const dataTablePageLabelText = styles.dataTablePageLabelText;

pub const DataTableProps = struct {
    columns: []const ColumnDef = &.{},
    /// 行数据（row-major；rows[r][c] 与 columns 一一对应）。生命周期须覆盖组件。
    rows: []const []const []const u8 = &.{},
    page_size: usize = 10,
    row_height: f32 = 36,
    header_height: f32 = 40,
    striped: bool = true,
    filterable: bool = true,
    resizable: bool = true,
    table_width: ?f32 = null,
    min_col_width: f32 = 60,
    /// 行选择模式。默认 .none = 与加入多选之前完全一致（非破坏性新增）。
    /// .multi 下 Cmd/Ctrl 点选切换、Shift 点选连续区间。
    selection_mode: SelectionMode = .none,
    /// 选择变化回调；caller 在回调里读 state.selection（selected_count / isSelected / collect）
    on_selection_change: ?core.HandlerRef = null,
};

pub const DataTableState = struct {
    rows: []const []const []const u8,
    columns: []const ColumnDef,
    /// 每列当前宽度（拖拽可变）
    col_widths: []f32,
    /// 通过筛选的原始行下标（容量 = rows.len，前 filtered_count 个有效）
    filtered: []usize,
    filtered_count: usize = 0,
    page: usize = 0,
    page_size: usize,
    row_height: f32,
    min_col_width: f32,
    filter_buf: [128]u8 = [_]u8{0} ** 128,
    filter_len: usize = 0,
    /// 分页窗口节点：row_nodes[vr] / cell_text_nodes[vr * ncols + c]
    row_nodes: []*Node,
    cell_text_nodes: []*Node,
    header_cells: []*Node,
    page_label: *Node,
    page_label_buf: [32]u8 = [_]u8{0} ** 32,
    body: *Node,
    cx: *Cx,
    // 列宽拖拽进行中状态
    resize_col: ?usize = null,
    resize_start_x: f32 = 0,
    resize_start_w: f32 = 0,

    /// 行选择集。索引 = **过滤后的行序号**（与 filtered[] 同一坐标系），
    /// 这样筛选态下的 Shift 区间选的是"看得见的连续行"，符合直觉。
    selection: selection_mod.SelectionModel = .{},
    on_selection_change: ?core.HandlerRef = null,
    /// 行点击事件上下文（长度 = page_size，随分页窗口复用）
    row_click_ctxs: []RowClickCtx = &.{},
    /// 选中行底色 / 各行常态底色（striped 下奇偶不同）
    selection_bg: core.Color = core.Color.TRANSPARENT,
    row_bg_even: core.Color = core.Color.TRANSPARENT,
    row_bg_odd: core.Color = core.Color.TRANSPARENT,

    /// 原始行下标 -> 是否选中（对外查询用；参数是 rows[] 的下标，不是过滤序号）
    pub fn isRowSelected(self: *const DataTableState, raw_row: usize) bool {
        var i: usize = 0;
        while (i < self.filtered_count) : (i += 1) {
            if (self.filtered[i] == raw_row) return self.selection.isSelected(i);
        }
        return false;
    }

    /// 把选中行的**原始下标**写进 out，返回个数
    pub fn selectedRows(self: *const DataTableState, out: []usize) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.filtered_count and n < out.len) : (i += 1) {
            if (self.selection.isSelected(i)) {
                out[n] = self.filtered[i];
                n += 1;
            }
        }
        return n;
    }

    /// 把选择态刷到当前分页窗口的行节点底色上
    pub fn applySelectionStyles(self: *DataTableState) void {
        const base = self.page * self.page_size;
        for (self.row_nodes, 0..) |row_node, vr| {
            const fi = base + vr;
            const has_data = fi < self.filtered_count;
            const normal = if (vr % 2 == 1) self.row_bg_odd else self.row_bg_even;
            const want = if (has_data and self.selection.isSelected(fi))
                self.selection_bg
            else
                normal;
            row_node.setBackgroundRaw(want);
            if (row_node.behavior.interaction.a11y) |*a| {
                a.selected = has_data and self.selection.isSelected(fi);
            }
            row_node.markRenderDirty();
        }
    }

    pub fn pageCount(self: *const DataTableState) usize {
        if (self.filtered_count == 0) return 1;
        return (self.filtered_count + self.page_size - 1) / self.page_size;
    }

    /// 重算筛选 + 刷新分页窗口内容（翻页/筛选/初始化共用）
    pub fn refresh(self: *DataTableState) void {
        const filter = self.filter_buf[0..self.filter_len];
        self.filtered_count = 0;
        for (self.rows, 0..) |row, ri| {
            const hit = blk: {
                if (filter.len == 0) break :blk true;
                for (row) |cell| {
                    if (containsIgnoreCase(cell, filter)) break :blk true;
                }
                break :blk false;
            };
            if (hit) {
                self.filtered[self.filtered_count] = ri;
                self.filtered_count += 1;
            }
        }
        if (self.page >= self.pageCount()) self.page = self.pageCount() - 1;

        const ncols = self.columns.len;
        const base = self.page * self.page_size;
        for (self.row_nodes, 0..) |row_node, vr| {
            const has_data = base + vr < self.filtered_count;
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
                const data_row = self.rows[self.filtered[base + vr]];
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
        if (self.page + 1 < self.pageCount()) {
            self.page += 1;
            self.refresh();
        }
    }

    pub fn prevPage(self: *DataTableState) void {
        if (self.page > 0) {
            self.page -= 1;
            self.refresh();
        }
    }

    /// 应用列宽（表头 + 该列所有 body cell）
    fn applyColWidth(self: *DataTableState, col: usize, w: f32) void {
        const clamped = @max(w, self.min_col_width);
        self.col_widths[col] = clamped;
        self.header_cells[col].style.width = .{ .px = clamped };
        const ncols = self.columns.len;
        for (0..self.row_nodes.len) |vr| {
            // cell text 的父节点是 cell box（定宽）
            if (self.cell_text_nodes[vr * ncols + col].parent) |cell| {
                cell.style.width = .{ .px = clamped };
            }
        }
        self.body.markLayoutDirty();
    }
};

pub const DataTableMount = struct {
    wrapper: *Node,
    state: *DataTableState,
    /// 筛选输入框 wrapper（filterable=false 时为 null）
    filter_input: ?*Node = null,
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

fn onFilterChanged(state: *DataTableState, text: []const u8) void {
    const len = @min(text.len, state.filter_buf.len);
    @memcpy(state.filter_buf[0..len], text[0..len]);
    state.filter_len = len;
    state.page = 0;
    // 筛选变了，过滤序号整体重排，旧的选中位现在指向别的行，必须清掉
    state.selection.clear();
    state.selection.anchor = null;
    state.selection.lead = null;
    state.refresh();
}

/// 行点击 -> 选择模型。走 on_event 而不是 on_click，因为需要读修饰键
/// （Cmd/Ctrl 切换、Shift 区间），HandlerRef 的无参 on_click 拿不到。
fn rowClickHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *RowClickCtx = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .click => |c| {
            const state = ctx.state;
            if (state.selection.mode == .none) return .ignored;
            const fi = state.page * state.page_size + ctx.visible_row;
            if (fi >= state.filtered_count) return .ignored;
            state.selection.applyClick(fi, .{
                // macOS 用 Cmd，其它平台用 Ctrl，两个都认
                .toggle = c.modifiers.super or c.modifiers.ctrl,
                .range = c.modifiers.shift,
            });
            state.applySelectionStyles();
            if (state.on_selection_change) |h| h.invoke();
            return .stop;
        },
        else => return .ignored,
    }
}

const RowClickCtx = struct {
    state: *DataTableState,
    /// 分页窗口内的行序号（0..page_size）
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

/// 列宽拖拽手柄的事件上下文
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

pub fn mountDataTable(props_in: DataTableProps, scope: *Scope, cx: *Cx) !DataTableMount {
    // page_size = 0 会让 pageCount 除零；至少一行一页。
    var props = props_in;
    props.page_size = @max(props.page_size, 1);
    const my_scope = try scope.childScope();
    const allocator = cx.allocator;
    const t = cx.tokens;
    const ncols = props.columns.len;

    var total_width: f32 = 0;
    for (props.columns) |col| total_width += col.width;
    const table_width = props.table_width orelse total_width;

    // ── State（含全部 slice 的集中分配/释放）──
    const state = try my_scope.allocator.create(DataTableState);
    // 下面这一串分配在登记之前，任一失败都要把前面的收回来；登记成功后归 state.cleanup。
    var state_adopted = false;
    errdefer if (!state_adopted) my_scope.allocator.destroy(state);
    const col_widths = try my_scope.allocator.alloc(f32, ncols);
    errdefer if (!state_adopted) my_scope.allocator.free(col_widths);
    for (props.columns, 0..) |col, i| col_widths[i] = col.width;
    const filtered = try my_scope.allocator.alloc(usize, props.rows.len);
    errdefer if (!state_adopted) my_scope.allocator.free(filtered);
    const row_nodes = try my_scope.allocator.alloc(*Node, props.page_size);
    errdefer if (!state_adopted) my_scope.allocator.free(row_nodes);
    const cell_text_nodes = try my_scope.allocator.alloc(*Node, props.page_size * ncols);
    errdefer if (!state_adopted) my_scope.allocator.free(cell_text_nodes);
    const header_cells = try my_scope.allocator.alloc(*Node, ncols);
    errdefer if (!state_adopted) my_scope.allocator.free(header_cells);
    // 选择位图容量按 rows.len（过滤序号最大值就是它）
    var sel_model = try selection_mod.SelectionModel.init(
        my_scope.allocator,
        props.selection_mode,
        props.rows.len,
    );
    errdefer if (!state_adopted) sel_model.deinit(my_scope.allocator);
    // 行点击上下文：每个分页窗口行一个（数量固定 = page_size，不随数据增长）
    const row_click_ctxs = try my_scope.allocator.alloc(RowClickCtx, props.page_size);
    errdefer if (!state_adopted) my_scope.allocator.free(row_click_ctxs);
    // cleanup 会读这些字段去 free，而完整的 `state.* = .{…}` 要到 mount 末尾才写：
    // 中间任何一步失败、scope dispose 跑 cleanup 时读到的就是 undefined 指针。
    // 先把 cleanup 需要的字段写好，再登记。
    state.* = undefined;
    state.col_widths = col_widths;
    state.filtered = filtered;
    state.row_nodes = row_nodes;
    state.cell_text_nodes = cell_text_nodes;
    state.header_cells = header_cells;
    state.selection = sel_model;
    state.row_click_ctxs = row_click_ctxs;
    // 从这一刻起所有权二选一：adopt 成功归 scope，adopt 失败由它当场用 cleanup 释放,
    // 两种结局上面那串 errdefer 都不能再跑，所以标志在调用**之前**翻。
    state_adopted = true;
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const s: *DataTableState = @ptrCast(@alignCast(ptr));
            alloc.free(s.col_widths);
            alloc.free(s.filtered);
            alloc.free(s.row_nodes);
            alloc.free(s.cell_text_nodes);
            alloc.free(s.header_cells);
            alloc.free(s.row_click_ctxs);
            s.selection.deinit(alloc);
            alloc.destroy(s);
        }
    }.cleanup);

    // ── 结构：column [filter?] [table] [pagination] ──
    const root = try box(cx, dataTableRootStyle(table_width), .{});
    // sweep：root 守到 return（连带 dispose 绑上的 my_scope）；子树建好即 adopt
    errdefer cx.freeNode(root);
    root.meta.ownership.meta.component_name = "DataTable";
    try core.bindScopeToNode(my_scope, root);
    // role=grid：AT 据此启用表格导航（按列/按行走），并播报"第 R 行第 C 列"。
    // 没有它，整张表在 AT 侧就是一长串无结构的文本。
    root.behavior.interaction.a11y = .{
        .role = .grid,
        .multiselectable = props.selection_mode == .multi,
    };

    var filter_input_node: ?*Node = null;
    if (props.filterable) {
        const input_result = try input_mod.Input(.{
            .placeholder = "Filter rows…",
            .width = @min(table_width, 260),
            .on_change = core.Cx.strHandlerFrom(DataTableState, state, onFilterChanged),
        }).mountResult(my_scope, cx);
        _ = try core.adoptChild(cx, allocator, root, input_result.node);
        filter_input_node = input_result.node;
    }

    const border_wrap = try core.adoptChild(cx, allocator, root, try box(cx, dataTableBorderWrapStyle(table_width, t), .{}));

    // ── Header（含 resize 手柄）──
    const header = try core.adoptChild(cx, allocator, border_wrap, try box(cx, dataTableHeaderStyle(props.header_height, t), .{}));
    header.behavior.interaction.a11y = .{ .role = .row, .row_index = 0 };

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

    for (props.columns, 0..) |col, ci| {
        const header_cell = try core.adoptChild(cx, allocator, header, try box(cx, dataTableHeaderCellStyle(col.width), .{}));
        // 表头单元格必须是 columnheader 而不是普通 cell, AT 靠它在朗读
        // 每个数据格时带上列名（"Name：Alice"而不是干巴巴一个"Alice"）。
        header_cell.behavior.interaction.a11y = .{
            .role = .columnheader,
            .label = col.header,
            .row_index = 0,
            .column_index = @intCast(ci),
        };
        const htext = try core.adoptChild(cx, allocator, header_cell, try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } }, .{}));
        var htext_props = dataTableHeaderTextProps(t);
        htext_props.content = col.header;
        htext.setText(htext_props);

        if (props.resizable) {
            const handle = try core.adoptChild(cx, allocator, header_cell, try box(cx, resizeHandleStyle(), .{}));
            resize_ctxs[ci] = .{ .state = state, .col = ci, .handle = handle };
            handle.behavior.events.event_context = @ptrCast(&resize_ctxs[ci]);
            handle.behavior.events.on_event = resizeEventHandler;
            (try handle.style.ensureExtFallible(allocator)).hit_roles = .{ .pointer = true };
        }

        header_cells[ci] = header_cell;
    }

    // ── Body：page_size 行固定节点 ──
    const body = try core.adoptChild(cx, allocator, border_wrap, try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    }, .{}));

    const row_colors = dataTableRowColors(props.striped, t);
    for (0..props.page_size) |vr| {
        const row_node = try core.adoptChild(cx, allocator, body, try box(cx, dataTableRowStyle(
            if (vr % 2 == 1) row_colors.odd else row_colors.even,
            props.row_height,
        ), .{}));
        // 分页是节点复用的：超出数据量的行被压成 0 高。它们在 a11y 上必须
        // 被隐藏（syncPage 里同步 hidden），否则 AT 会朗读出一串空行。
        row_node.behavior.interaction.a11y = .{
            .role = .row,
            .row_index = @intCast(vr),
        };
        for (props.columns, 0..) |col, c| {
            const cell = try core.adoptChild(cx, allocator, row_node, try box(cx, dataTableCellStyle(col.width), .{}));
            cell.behavior.interaction.a11y = .{
                .role = .gridcell,
                .row_index = @intCast(vr),
                .column_index = @intCast(c),
            };
            const cell_text = try core.adoptChild(cx, allocator, cell, try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } }, .{}));
            cell_text.setText(dataTableCellTextProps(t));
            cell_text_nodes[vr * ncols + c] = cell_text;
        }
        // 行选择：走 on_event 以拿到修饰键（Cmd/Ctrl 切换、Shift 区间）
        if (props.selection_mode != .none) {
            row_node.style.cursor = .pointer;
            row_click_ctxs[vr] = .{ .state = state, .visible_row = vr };
            row_node.behavior.events.event_context = @ptrCast(&row_click_ctxs[vr]);
            row_node.behavior.events.on_event = rowClickHandler;
        }
        row_nodes[vr] = row_node;
    }

    // ── Pagination ──
    const pager = try core.adoptChild(cx, allocator, root, try box(cx, dataTablePagerStyle(), .{}));

    _ = try core.adoptChild(cx, allocator, pager, try button_mod.Button(.{
        .label = "Prev",
        .variant = .secondary,
        .size = .sm,
        .on_click = .{ .callback = onPrevClick, .context = @ptrCast(state) },
    }).mount(my_scope, cx));
    _ = try core.adoptChild(cx, allocator, pager, try button_mod.Button(.{
        .label = "Next",
        .variant = .secondary,
        .size = .sm,
        .on_click = .{ .callback = onNextClick, .context = @ptrCast(state) },
    }).mount(my_scope, cx));

    const page_label = try core.adoptChild(cx, allocator, pager, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
    page_label.setText(dataTablePageLabelText(t));

    state.* = .{
        .rows = props.rows,
        .columns = props.columns,
        .col_widths = col_widths,
        .filtered = filtered,
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
    state.refresh();

    return .{ .wrapper = root, .state = state, .filter_input = filter_input_node };
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

fn mountForTest(cx: *Cx, scope: *Scope, page_size: usize) !DataTableMount {
    return mountDataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = page_size,
        .filterable = false,
    }, scope, cx);
}

test "DataTable: page_size = 0 不除零" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const dt = try mountForTest(cx, scope, 0);
    try root.appendChild(testing.allocator, dt.wrapper);
    try testing.expect(dt.state.pageCount() >= 1);
    dt.state.refresh();
}

test "DataTable: 分页窗口 + 翻页" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountForTest(cx, scope, 2);
    try root.appendChild(testing.allocator, dt.wrapper);

    try testing.expectEqual(@as(usize, 5), dt.state.filtered_count);
    try testing.expectEqual(@as(usize, 3), dt.state.pageCount());
    // 第一页：Alice/Bob 可见
    try testing.expectEqualStrings("Alice", dt.state.cell_text_nodes[0].getText().?.content);
    try testing.expectEqualStrings("Bob", dt.state.cell_text_nodes[2].getText().?.content);

    dt.state.nextPage();
    try testing.expectEqual(@as(usize, 1), dt.state.page);
    try testing.expectEqualStrings("Carol", dt.state.cell_text_nodes[0].getText().?.content);

    // 尾页只有 1 行：第二行折叠为 0 高
    dt.state.nextPage();
    try testing.expectEqualStrings("Eve", dt.state.cell_text_nodes[0].getText().?.content);
    try testing.expectEqual(@as(f32, 0), dt.state.row_nodes[1].style.height.px);
    // 越界翻页 no-op
    dt.state.nextPage();
    try testing.expectEqual(@as(usize, 2), dt.state.page);
}

test "DataTable: 筛选跨列匹配 + 重置回第一页" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountForTest(cx, scope, 3);
    try root.appendChild(testing.allocator, dt.wrapper);

    dt.state.page = 1;
    onFilterChanged(dt.state, "user");
    try testing.expectEqual(@as(usize, 3), dt.state.filtered_count); // Bob/Carol/Eve
    try testing.expectEqual(@as(usize, 0), dt.state.page);
    try testing.expectEqualStrings("Bob", dt.state.cell_text_nodes[0].getText().?.content);

    onFilterChanged(dt.state, "zzz");
    try testing.expectEqual(@as(usize, 0), dt.state.filtered_count);
    try testing.expectEqual(@as(f32, 0), dt.state.row_nodes[0].style.height.px);
    try testing.expectEqualStrings("Page 1 / 1", dt.state.page_label.getText().?.content);
}

test "DataTable: 列宽调整应用到表头与所有 cell 并钳最小宽" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountDataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = 3,
        .filterable = false,
        .min_col_width = 60,
    }, scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    dt.state.applyColWidth(0, 200);
    try testing.expectEqual(@as(f32, 200), dt.state.col_widths[0]);
    try testing.expectEqual(@as(f32, 200), dt.state.header_cells[0].style.width.px);
    try testing.expectEqual(@as(f32, 200), dt.state.cell_text_nodes[0].parent.?.style.width.px);
    // 钳最小宽
    dt.state.applyColWidth(0, 10);
    try testing.expectEqual(@as(f32, 60), dt.state.col_widths[0]);
}

// ── 行选择 ──────────────────────────────────────────────────

const SelChangeCounter = struct {
    n: usize = 0,
    fn bump(ctx: *anyopaque) void {
        const self: *SelChangeCounter = @ptrCast(@alignCast(ctx));
        self.n += 1;
    }
};

fn clickRow(dt: DataTableMount, visible_row: usize, mods: core.Modifiers) void {
    _ = rowClickHandler(
        .{ .click = .{ .x = 0, .y = 0, .modifiers = mods } },
        @ptrCast(&dt.state.row_click_ctxs[visible_row]),
    );
}

test "DataTable: 默认 selection_mode=.none —— 点击不选中（既有行为不变）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountForTest(cx, scope, 5);
    try root.appendChild(testing.allocator, dt.wrapper);

    try testing.expectEqual(SelectionMode.none, dt.state.selection.mode);
    // .none 时行节点根本没接事件处理器
    try testing.expect(dt.state.row_nodes[0].behavior.events.on_event == null);
    try testing.expectEqual(@as(usize, 0), dt.state.selection.selected_count);
}

test "DataTable: multi 多选 —— Cmd 切换 / Shift 区间 / 底色 / 回调" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    var counter = SelChangeCounter{};
    const dt = try mountDataTable(.{
        .columns = &test_cols,
        .rows = &test_rows, // 5 行
        .page_size = 5,
        .filterable = false,
        .selection_mode = .multi,
        .on_selection_change = .{ .callback = SelChangeCounter.bump, .context = @ptrCast(&counter) },
    }, scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    // 事件真的接上了（回归护栏：此前 DataTable 连 selection 字段都没有）
    try testing.expect(dt.state.row_nodes[0].behavior.events.on_event != null);

    // 无修饰点第 1 行
    clickRow(dt, 1, .{});
    try testing.expectEqual(@as(usize, 1), dt.state.selection.selected_count);
    try testing.expect(dt.state.isRowSelected(1));
    try testing.expectEqual(@as(usize, 1), counter.n);
    // 底色刷上了
    try testing.expect(dt.state.row_nodes[1].getBackground().eql(dt.state.selection_bg));
    try testing.expect(!dt.state.row_nodes[0].getBackground().eql(dt.state.selection_bg));

    // Cmd 点第 3 行 -> 两行都选中
    clickRow(dt, 3, .{ .super = true });
    try testing.expectEqual(@as(usize, 2), dt.state.selection.selected_count);
    try testing.expect(dt.state.isRowSelected(1) and dt.state.isRowSelected(3));

    // Shift 点第 4 行 -> 以锚点(3)重划区间 3..4
    clickRow(dt, 4, .{ .shift = true });
    try testing.expectEqual(@as(usize, 2), dt.state.selection.selected_count);
    try testing.expect(dt.state.isRowSelected(3) and dt.state.isRowSelected(4));
    try testing.expect(!dt.state.isRowSelected(1));

    // selectedRows 返回原始行下标
    var buf: [8]usize = undefined;
    const n = dt.state.selectedRows(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(usize, &.{ 3, 4 }, buf[0..n]);

    // 无修饰点回第 0 行 -> 清空其余
    clickRow(dt, 0, .{});
    try testing.expectEqual(@as(usize, 1), dt.state.selection.selected_count);
    try testing.expect(dt.state.isRowSelected(0));
    try testing.expectEqual(@as(usize, 4), counter.n); // 共 4 次点击，每次一回调
}

test "DataTable: single 模式只保留一行（修饰键不生效）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountDataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = 5,
        .filterable = false,
        .selection_mode = .single,
    }, scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    clickRow(dt, 1, .{});
    clickRow(dt, 3, .{ .super = true }); // Cmd 在 single 下无效
    try testing.expectEqual(@as(usize, 1), dt.state.selection.selected_count);
    try testing.expect(dt.state.isRowSelected(3));
    try testing.expect(!dt.state.isRowSelected(1));
}

test "DataTable: 筛选变化清空选择（过滤序号重排，旧选中位会指错行）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const dt = try mountDataTable(.{
        .columns = &test_cols,
        .rows = &test_rows,
        .page_size = 5,
        .selection_mode = .multi,
    }, scope, cx);
    try root.appendChild(testing.allocator, dt.wrapper);

    clickRow(dt, 0, .{});
    clickRow(dt, 2, .{ .super = true });
    try testing.expectEqual(@as(usize, 2), dt.state.selection.selected_count);

    onFilterChanged(dt.state, "Alice");
    try testing.expectEqual(@as(usize, 0), dt.state.selection.selected_count);
    try testing.expect(dt.state.selection.anchor == null);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "data_table: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("data_table", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountForTest(cx, scope, 2)).wrapper;
        }
    }.m);
}
