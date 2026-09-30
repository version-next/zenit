/// Table Component
///
/// 表格组件，支持虚拟滚动、排序、选择
///
/// 特性:
/// - 固定表头（Header sticky）
/// - 列宽配置
/// - 排序指示器
/// - 行 hover 高亮
/// - 条纹行 (可选)
/// - 虚拟滚动: row_count > virtual_threshold 时自动启用，基于 VirtualList 实现
/// - 小数据量直接渲染（零开销）
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const hooks = @import("../../hooks.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const virtual_list = @import("../virtual_list/mod.zig");
const VirtualListState = virtual_list.VirtualListState;

/// 虚拟滚动启用阈值: row_count 超过此值时自动启用 VirtualList
const virtual_threshold: usize = 50;

// ============================================================================
// 样式层已析出到 styles.zig — mount/render 只消费，本文件不做视觉决策
// ============================================================================

const styles = @import("styles.zig");
const colJustify = styles.colJustify;
const tableBorderWrapStyle = styles.tableBorderWrapStyle;
const tableInnerStyle = styles.tableInnerStyle;
const tableHeaderRowStyle = styles.tableHeaderRowStyle;
const tableHeaderCellStyle = styles.tableHeaderCellStyle;
const tableHeaderTextProps = styles.tableHeaderTextProps;
const sortIndicatorBoxStyle = styles.sortIndicatorBoxStyle;
const sortIndicatorText = styles.sortIndicatorText;
const tableRowBg = styles.tableRowBg;
const tableRowStyle = styles.tableRowStyle;
const tableCellStyle = styles.tableCellStyle;
const tableSeparatorStyle = styles.tableSeparatorStyle;

/// 列对齐
pub const ColumnAlign = enum {
    left,
    center,
    right,
};

/// 列定义
pub const ColumnDef = struct {
    id: []const u8,
    header: []const u8,
    width: f32 = 120,
    sortable: bool = false,
    col_align: ColumnAlign = .left,
};

/// 排序方向
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

/// Cell 渲染回调
pub const CellRenderFn = *const fn (cell: *Node, row: usize, col: usize, cx: *Cx) void;

/// Table 属性
pub const TableProps = struct {
    columns: []const ColumnDef = &.{},
    row_count: usize = 0,
    row_height: f32 = 36,
    header_height: f32 = 40,
    striped: bool = false,
    hoverable: bool = true,
    table_width: ?f32 = null,
    table_height: f32 = 400,
    render_cell: ?CellRenderFn = null,
    on_sort: ?core.HandlerRef = null,
    on_row_click: ?core.HandlerRef = null,
};

/// Table 状态
pub const TableState = struct {
    sort_column: ?usize = null,
    sort_direction: SortDirection = .none,
    /// 各列表头的排序指示器节点（用于点击后刷新箭头）。
    /// 定长上界：超出的列不显示箭头（数据/排序本身仍正常），
    /// 不做动态分配是为了让 TableState 保持可按值快照。
    /// 此前 SortDirection.indicator() **从未被调用** —— 点表头数据会重排，
    /// 但箭头永远是占位空格，用户看不出当前按哪列排序。
    sort_indicators: [MAX_SORT_INDICATORS]?*Node = [_]?*Node{null} ** MAX_SORT_INDICATORS,
    header_cells: [MAX_SORT_INDICATORS]?*Node = [_]?*Node{null} ** MAX_SORT_INDICATORS,
    columns: []const ColumnDef,
    on_sort: ?core.HandlerRef,

    /// 程序化设置排序列与方向。
    ///
    /// 此前直接写 `state.sort_column` / `sort_direction` 不会刷新表头箭头
    /// （刷新函数是私有的）—— 属于"暴露了 state 却没有生效的写入口"。
    ///
    /// 不触发 on_sort（程序化设值非用户交互；需要通知请自行调用）。
    /// 注意：本函数只更新**排序状态与箭头**，实际数据重排由调用方在
    /// on_sort / 自己的数据层完成（Table 不持有数据）。
    pub fn setSort(self: *TableState, column: ?usize, direction: SortDirection) void {
        self.sort_column = column;
        self.sort_direction = if (column == null) .none else direction;
        refreshSortIndicators(self);
    }

    /// 清除排序（回到无排序态）。
    pub fn clearSort(self: *TableState) void {
        self.setSort(null, .none);
    }
};

/// Table mount 结果
pub const TableResult = struct {
    wrapper: *Node,
    state: *TableState,
    /// 虚拟滚动模式下的 VirtualListState（可用于动态更新 row_count）
    vl_state: ?*VirtualListState = null,
};

/// 创建 Table
pub fn Table(props: TableProps) TableBuilder {
    return TableBuilder{ .props = props };
}

pub const TableBuilder = struct {
    props: TableProps,

    pub fn columns(self: TableBuilder, cols: []const ColumnDef) TableBuilder {
        var new = self;
        new.props.columns = cols;
        return new;
    }

    pub fn rowHeight(self: TableBuilder, h: f32) TableBuilder {
        var new = self;
        new.props.row_height = h;
        return new;
    }

    pub fn striped(self: TableBuilder, s: bool) TableBuilder {
        var new = self;
        new.props.striped = s;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: TableBuilder, scope: *Scope, cx: *Cx) !TableResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // 计算总宽度
        var total_width: f32 = 0;
        for (p.columns) |col| {
            total_width += col.width;
        }
        const table_width = p.table_width orelse total_width;

        // State
        const state = try allocator.create(TableState);
        state.* = .{
            .columns = p.columns,
            .on_sort = p.on_sort,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s: *TableState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.cleanup);

        // 外层边框容器（padding 为 border 留出空间，避免子节点覆盖边框）
        const border_wrap = try box(cx, tableBorderWrapStyle(table_width, p.table_height, t), .{});
        // sweep：border_wrap 守卫一直武装到 return（bind 之后 freeNode 连带 dispose my_scope）；
        // wrapper / header / body 建好即 adopt，子 mount 各自自守。
        errdefer cx.freeNode(border_wrap);
        border_wrap.meta.ownership.meta.component_name = "Table";
        border_wrap.behavior.interaction.a11y = .{ .role = .table };
        try core.bindScopeToNode(my_scope, border_wrap);

        // 内层容器（overflow_hidden 裁剪内容，不含 border）
        const wrapper = try core.adoptChild(cx, allocator, border_wrap, try box(cx, tableInnerStyle(t), .{}));

        // ---- Header ----
        _ = try core.adoptChild(cx, allocator, wrapper, try mountHeader(p, state, my_scope, cx, t));

        // ---- Body ----
        // 根据行数选择渲染策略: 小数据量直接渲染，大数据量启用虚拟滚动
        if (p.row_count > virtual_threshold) {
            // 虚拟滚动模式
            const vl_result = try mountVirtualBody(p, my_scope, cx, t, table_width);
            _ = try core.adoptChild(cx, allocator, wrapper, vl_result.container);
            return .{ .wrapper = border_wrap, .state = state, .vl_state = vl_result.vl_state };
        } else {
            // 直接渲染模式（小数据量，零开销）
            _ = try core.adoptChild(cx, allocator, wrapper, try mountDirectBody(p, my_scope, cx, t));
            return .{ .wrapper = border_wrap, .state = state };
        }
    }
};

// ========== Header 渲染 ==========

fn mountHeader(
    p: TableProps,
    state: *TableState,
    my_scope: *Scope,
    cx: *Cx,
    t: *const core.ThemeTokens,
) !*Node {
    const allocator = cx.allocator;

    const header = try box(cx, tableHeaderRowStyle(p.header_height, t), .{});
    // sweep：header 守到 return，cell / 文字 / 指示器建好即 adopt
    errdefer cx.freeNode(header);
    header.behavior.interaction.a11y = .{ .role = .row, .row_index = 0 };

    for (p.columns, 0..) |col, ci| {
        const header_cell = try core.adoptChild(cx, allocator, header, try box(cx, tableHeaderCellStyle(col), .{}));
        header_cell.behavior.interaction.a11y = .{
            .role = .columnheader,
            .label = col.header,
            .row_index = 0,
            .column_index = @intCast(ci),
            .sort_direction = .none,
        };
        if (ci < state.header_cells.len) state.header_cells[ci] = header_cell;

        const header_text = try core.adoptChild(cx, allocator, header_cell, try core.text(cx, col.header, .{}));
        if (header_text.getText()) |old| {
            // 只覆盖样式字段，content/owned 等内容所有权位保持原样
            var txt = old;
            const style_txt = tableHeaderTextProps(t);
            txt.color = style_txt.color;
            txt.font_size = style_txt.font_size;
            txt.font_weight = style_txt.font_weight;
            header_text.setText(txt);
        }

        // 排序指示器
        if (col.sortable) {
            header_cell.style.cursor = .pointer;
            const sort_ctx = try allocator.create(SortClickContext);
            sort_ctx.* = .{ .state = state, .col_index = ci };
            try my_scope.adoptResource(@ptrCast(sort_ctx), struct {
                fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                    const c: *SortClickContext = @ptrCast(@alignCast(ptr));
                    alloc.destroy(c);
                }
            }.cleanup);
            header_cell.behavior.events.on_event = sortEventHandler;
            header_cell.behavior.events.event_context = @ptrCast(sort_ctx);

            const sort_ind = try core.adoptChild(cx, allocator, header_cell, try box(cx, sortIndicatorBoxStyle(), .{}));
            const dir_now: SortDirection = if (state.sort_column == ci) state.sort_direction else .none;
            var ind_txt = sortIndicatorText(t);
            ind_txt.content = dir_now.indicator();
            sort_ind.setText(ind_txt);
            if (ci < state.sort_indicators.len) state.sort_indicators[ci] = sort_ind;
        }
    }

    return header;
}

// ========== 直接渲染模式 (小数据量) ==========

fn mountDirectBody(
    p: TableProps,
    my_scope: *Scope,
    cx: *Cx,
    t: *const core.ThemeTokens,
) !*Node {
    const allocator = cx.allocator;

    const body = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
    }, .{});
    // sweep：body 守到 return，行 / 格 / 分隔线建好即 adopt
    errdefer cx.freeNode(body);
    body.style.overflow_hidden = true;

    for (0..p.row_count) |row_i| {
        const is_even = (row_i % 2 == 0);
        const row_bg = tableRowBg(p.striped, is_even, t);

        const row_node = try core.adoptChild(cx, allocator, body, try box(cx, tableRowStyle(row_bg, p.row_height), .{}));
        row_node.behavior.interaction.a11y = .{
            .role = .row,
            .row_index = @intCast(row_i),
        };

        // on_row_click：此前**声明了但全组件无人读取** —— 应用传进来的回调
        // 被静默吞掉，点行毫无反应。这里真正接到行节点上。
        if (p.on_row_click) |h| {
            row_node.style.cursor = .pointer;
            row_node.behavior.events.on_click = h;
        }

        for (p.columns, 0..) |col, ci| {
            const cell = try core.adoptChild(cx, allocator, row_node, try box(cx, tableCellStyle(col), .{}));
            cell.behavior.interaction.a11y = .{
                .role = .gridcell,
                .row_index = @intCast(row_i),
                .column_index = @intCast(ci),
            };

            // 用户渲染回调
            if (p.render_cell) |render_fn| {
                render_fn(cell, row_i, ci, cx);
            }
        }

        // hover 效果
        if (p.hoverable) {
            _ = try hooks.useAnimatedBackground(my_scope, cx, row_node, .{
                .normal = row_bg,
                .hover = t.color.list_hover_bg,
            });
        }

        // 行底部分隔线（最后一行不加）
        if (row_i + 1 < p.row_count) {
            _ = try core.adoptChild(cx, allocator, body, try box(cx, tableSeparatorStyle(t.color.separator), .{}));
        }
    }

    return body;
}

// ========== 虚拟滚动模式 (大数据量) ==========

/// 虚拟滚动行渲染上下文 — 传递给 VirtualList 的 render 回调
const VirtualRowContext = struct {
    columns: []const ColumnDef,
    render_cell: ?CellRenderFn,
    row_height: f32,
    striped: bool,
    hoverable: bool,
    /// Design token 颜色缓存（避免在 render 回调中访问 cx.tokens）
    bg_secondary: Color,
    list_hover_bg: Color,
    separator_color: Color,
    /// 与直接渲染路径同语义（>50 行走虚拟路径时此前未接线）
    on_row_click: ?core.HandlerRef = null,

    /// ── hover 上下文槽位表（见 RowHoverCtx 注释）──
    /// 按 VirtualList 的 pool 节点指针索引，容量 = VirtualList.max_pool_size。
    /// 整表随 VirtualRowContext 一起分配/释放，行数无关。
    hover_slots: [virtual_list.max_pool_size]RowHoverCtx = [_]RowHoverCtx{.{}} ** virtual_list.max_pool_size,
    /// 槽位 → 拥有它的 pool 节点（null = 未占用）
    hover_slot_owner: [virtual_list.max_pool_size]?*Node = [_]?*Node{null} ** virtual_list.max_pool_size,
    hover_slot_count: usize = 0,

    /// 取（或首次分配）该 pool 节点专属的 hover 槽位。
    ///
    /// 之前这里是 `allocator.create(RowHoverCtx)` 且从不释放：每行滚入视口
    /// 漏一个，滚 10k 行漏 ~10k 个。而 pool 只有至多 max_pool_size 个槽位在
    /// 同时存活，所以按 pool 节点复用槽位既堵住泄漏，也天然避免了旧实现里
    /// 「pool 复用后旧 ctx 仍被别的节点事件引用」的悬垂风险。
    fn hoverSlotFor(self: *VirtualRowContext, pool_node: *Node) ?*RowHoverCtx {
        for (self.hover_slot_owner[0..self.hover_slot_count], 0..) |owner, i| {
            if (owner == pool_node) return &self.hover_slots[i];
        }
        if (self.hover_slot_count >= self.hover_slots.len) return null;
        const i = self.hover_slot_count;
        self.hover_slot_owner[i] = pool_node;
        self.hover_slot_count += 1;
        return &self.hover_slots[i];
    }
};

/// 行 hover 上下文（每个 pool slot 复用一个，在 render 回调中覆写）
const RowHoverCtx = struct {
    row_node: ?*Node = null,
    normal_bg: Color = Color.TRANSPARENT,
    hover_bg: Color = Color.TRANSPARENT,
};

fn mountVirtualBody(
    p: TableProps,
    my_scope: *Scope,
    cx: *Cx,
    t: *const core.ThemeTokens,
    table_width: f32,
) !struct { container: *Node, vl_state: *VirtualListState } {
    const allocator = cx.allocator;

    // VirtualList 的 item_height 包含行高 + 1px 分隔线
    const item_height = p.row_height + 1;
    // body 高度 = 总 table 高度 - header 高度 - border (2px)
    const body_height = p.table_height - p.header_height - 2;

    // 分配虚拟行渲染上下文
    const vr_ctx = try allocator.create(VirtualRowContext);
    vr_ctx.* = .{
        .columns = p.columns,
        .render_cell = p.render_cell,
        .row_height = p.row_height,
        .striped = p.striped,
        .hoverable = p.hoverable,
        .bg_secondary = t.color.bg_secondary,
        .list_hover_bg = t.color.list_hover_bg,
        .separator_color = t.color.separator,
        .on_row_click = p.on_row_click,
    };
    try my_scope.adoptResource(@ptrCast(vr_ctx), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const c: *VirtualRowContext = @ptrCast(@alignCast(ptr));
            alloc.destroy(c);
        }
    }.cleanup);

    const vl_result = try virtual_list.VirtualList(.{
        .item_count = p.row_count,
        .item_height = item_height,
        .width = table_width,
        .height = body_height,
        .overscan = 5,
    }).mountWithContext(
        my_scope,
        cx,
        @ptrCast(vr_ctx),
        null,
        virtualRowRender,
    );

    return .{ .container = vl_result.container, .vl_state = vl_result.state };
}

/// VirtualList 行渲染回调 — 每次 item 进入可见区域时调用
fn virtualRowRender(node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void {
    const vr_ctx: *VirtualRowContext = @ptrCast(@alignCast(user_context orelse return));
    const allocator = cx.allocator;

    // 清空旧内容（pool 节点可能被复用）
    node.removeAllChildren();
    node.style.direction = .column;
    node.style.flex_shrink = 0;

    // 行容器（水平排列 cells）— 底色规则与直接渲染路径共用 tableRowBg 的语义，
    // 但 render 回调不访问 cx.tokens，用 VirtualRowContext 缓存的颜色
    const is_even = (index % 2 == 0);
    const row_bg = if (vr_ctx.striped and !is_even) vr_ctx.bg_secondary else Color.TRANSPARENT;

    const row_node = box(cx, tableRowStyle(row_bg, vr_ctx.row_height), .{}) catch return;
    row_node.behavior.interaction.a11y = .{
        .role = .row,
        .row_index = @intCast(index),
    };

    if (vr_ctx.on_row_click) |h| {
        row_node.style.cursor = .pointer;
        row_node.behavior.events.on_click = h;
    }

    // 设置 hover 效果（通过 on_hover/on_leave 实现，不依赖 Scope/useAnimatedBackground）
    if (vr_ctx.hoverable) {
        row_node.style.cursor = .pointer;
        // 复用本 pool 节点专属的 hover 槽位（不再每行 heap 分配）
        if (vr_ctx.hoverSlotFor(node)) |hc| {
            hc.* = .{
                .row_node = row_node,
                .normal_bg = row_bg,
                .hover_bg = vr_ctx.list_hover_bg,
            };
            row_node.behavior.events.on_hover = .{
                .callback = rowHoverEnter,
                .context = @ptrCast(hc),
            };
            row_node.behavior.events.on_leave = .{
                .callback = rowHoverLeave,
                .context = @ptrCast(hc),
            };
        }
    }

    for (vr_ctx.columns, 0..) |col, ci| {
        const cell = box(cx, tableCellStyle(col), .{}) catch continue;
        cell.behavior.interaction.a11y = .{
            .role = .gridcell,
            .row_index = @intCast(index),
            .column_index = @intCast(ci),
        };

        // 用户渲染回调
        if (vr_ctx.render_cell) |render_fn| {
            render_fn(cell, index, ci, cx);
        }

        row_node.appendChild(allocator, cell) catch continue;
    }

    node.appendChild(allocator, row_node) catch return;

    // 行底部分隔线
    const separator = box(cx, tableSeparatorStyle(vr_ctx.separator_color), .{}) catch return;
    node.appendChild(allocator, separator) catch return;
}

/// 行 hover 进入回调
fn rowHoverEnter(context: *anyopaque) void {
    const hc: *RowHoverCtx = @ptrCast(@alignCast(context));
    const row = hc.row_node orelse return;
    row.setStyle(null, .background, hc.hover_bg);
    row.markRenderDirty();
}

/// 行 hover 离开回调
fn rowHoverLeave(context: *anyopaque) void {
    const hc: *RowHoverCtx = @ptrCast(@alignCast(context));
    const row = hc.row_node orelse return;
    row.setStyle(null, .background, hc.normal_bg);
    row.markRenderDirty();
}

// ========== 内部辅助 ==========

/// sort_indicators 的定长上界（见 TableState.sort_indicators）。
const MAX_SORT_INDICATORS = 32;

const SortClickContext = struct {
    state: *TableState,
    col_index: usize,
};

/// 按当前 sort_column / sort_direction 重绘各列表头箭头。
fn refreshSortIndicators(state: *TableState) void {
    for (state.sort_indicators, 0..) |maybe_node, ci| {
        const node = maybe_node orelse continue;
        const dir: SortDirection = if (state.sort_column == ci) state.sort_direction else .none;
        if (node.getText()) |old| {
            var txt = old;
            txt.content = dir.indicator();
            // indicator() 返回的是静态字面量，不是堆内容 —— 必须清 owned，
            // 否则 Node.destroy 会 free 非堆指针。
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
            if (context) |ctx| {
                const sc: *SortClickContext = @ptrCast(@alignCast(ctx));
                if (sc.state.sort_column == sc.col_index) {
                    sc.state.sort_direction = sc.state.sort_direction.toggle();
                } else {
                    sc.state.sort_column = sc.col_index;
                    sc.state.sort_direction = .asc;
                }
                refreshSortIndicators(sc.state);
                if (sc.state.on_sort) |handler| handler.invoke();
                return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

// ========== 测试 ==========

const test_columns = [_]ColumnDef{
    .{ .id = "name", .header = "Name", .width = 150, .sortable = true },
    .{ .id = "age", .header = "Age", .width = 80, .col_align = .right },
    .{ .id = "email", .header = "Email", .width = 200 },
};

test "Table: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
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

    // 小数据量: 直接渲染模式，无 VirtualList
    try std.testing.expect(result.vl_state == null);

    // border_wrap 有 1 个子节点: inner wrapper
    try std.testing.expectEqual(@as(usize, 1), result.wrapper.children.items.len);
    const inner = result.wrapper.children.items[0];

    // inner wrapper 有 2 个子节点: header + body
    try std.testing.expectEqual(@as(usize, 2), inner.children.items.len);

    // header 有 3 个 cells
    const header = inner.children.items[0];
    try std.testing.expectEqual(@as(usize, 3), header.children.items.len);

    // body 有 5 行 + 4 分隔线 = 9 个子节点
    const body = inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 9), body.children.items.len);
}

test "Table: striped rows" {
    var ctx = try Cx.init(std.testing.allocator);
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

    // 4 行 + 3 分隔线 = 7 个子节点
    const inner = result.wrapper.children.items[0];
    const body = inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 7), body.children.items.len);
}

test "Table: sort toggle" {
    var ctx = try Cx.init(std.testing.allocator);
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

    // 模拟点击排序
    const inner = result.wrapper.children.items[0];
    const header = inner.children.items[0];
    const name_header = header.children.items[0];
    if (name_header.behavior.events.on_event) |handler| {
        _ = handler(.{ .click = .{ .x = 0, .y = 0 } }, name_header.behavior.events.event_context);
    }

    try std.testing.expectEqual(@as(?usize, 0), result.state.sort_column);
    try std.testing.expectEqual(SortDirection.asc, result.state.sort_direction);
}

test "Table: empty" {
    var ctx = try Cx.init(std.testing.allocator);
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
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 超过虚拟化阈值 → 启用 VirtualList
    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 1000,
        .table_height = 400,
        .hoverable = false,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 虚拟滚动模式: vl_state 非 null
    try std.testing.expect(result.vl_state != null);

    // VirtualList 的 item_count 正确
    try std.testing.expectEqual(@as(usize, 1000), result.vl_state.?.props.item_count);

    // 池大小 > 0 且远小于 row_count
    try std.testing.expect(result.vl_state.?.pool_size > 0);
    try std.testing.expect(result.vl_state.?.pool_size < 100);
}

test "Table: virtual scrolling visible range" {
    var ctx = try Cx.init(std.testing.allocator);
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

    const vl = result.vl_state.?;

    // 模拟滚动到第 500 行
    const item_height = 36 + 1; // row_height + separator
    vl.scroll_state.scroll_y = 500 * @as(f32, @floatFromInt(item_height));
    vl.scroll_state.viewport_height = 400 - 40 - 2; // table_height - header - border
    vl.scroll_state.content_height = 10000 * @as(f32, @floatFromInt(item_height));

    const range = vl.visibleRange();
    // 可见范围应包含 ~500 附近的行
    try std.testing.expect(range.start <= 500);
    try std.testing.expect(range.end > 500);
    try std.testing.expect(range.end - range.start < 30); // 远小于 10000
}

test "Table: threshold boundary - 50 rows uses direct rendering" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 恰好 50 行: 不启用虚拟滚动
    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 50,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 50 行 <= threshold → 直接渲染
    try std.testing.expect(result.vl_state == null);

    // body 有 50 行 + 49 分隔线 = 99 个子节点
    const inner = result.wrapper.children.items[0];
    const body = inner.children.items[1];
    try std.testing.expectEqual(@as(usize, 99), body.children.items.len);
}

test "Table: threshold boundary - 51 rows enables virtual scrolling" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // 51 行: 启用虚拟滚动
    const result = try Table(.{
        .columns = &test_columns,
        .row_count = 51,
        .hoverable = false,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 51 行 > threshold → 虚拟滚动
    try std.testing.expect(result.vl_state != null);
    try std.testing.expectEqual(@as(usize, 51), result.vl_state.?.props.item_count);
}

test "Table: on_row_click 真的被接线（此前声明了无人读取）" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(600, 400);
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Sink = struct {
        clicks: u32 = 0,
        fn onClick(self: *@This()) void {
            self.clicks += 1;
        }
    };
    var sink = Sink{};

    const cols = [_]ColumnDef{.{ .id = "name", .header = "Name", .width = 100 }};
    const result = try Table(.{
        .columns = &cols,
        .row_count = 3,
        .on_row_click = Cx.handlerFrom(Sink, &sink, Sink.onClick),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    // 找到某个装了 on_click 的行节点并派发点击
    var found: ?*Node = null;
    const Walk = struct {
        fn go(n: *Node, out: *?*Node) void {
            if (out.* != null) return;
            if (n.behavior.events.on_click != null) {
                out.* = n;
                return;
            }
            for (n.children.items) |c| go(c, out);
        }
    };
    Walk.go(result.wrapper, &found);
    const row = found orelse return error.NoClickableRow;

    _ = ctx.dispatcher.dispatch(core.Event{ .click = .{ .x = 10, .y = 10 } }, row);
    try std.testing.expectEqual(@as(u32, 1), sink.clicks);
}

test "Table(virtual): on_row_click 在 >50 行虚拟路径同样接线" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(600, 400);
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Sink = struct {
        clicks: u32 = 0,
        fn onClick(self: *@This()) void {
            self.clicks += 1;
        }
    };
    var sink = Sink{};
    const cols = [_]ColumnDef{.{ .id = "name", .header = "Name", .width = 100 }};
    const result = try Table(.{
        .columns = &cols,
        .row_count = 200,
        .on_row_click = Cx.handlerFrom(Sink, &sink, Sink.onClick),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expect(result.vl_state != null);
    ctx.layout();
    _ = ctx.render();

    var found: ?*Node = null;
    const Walk = struct {
        fn go(n: *Node, out: *?*Node) void {
            if (out.* != null) return;
            if (n.behavior.interaction.a11y) |a| {
                if (a.role == .row and n.behavior.events.on_click != null) {
                    out.* = n;
                    return;
                }
            }
            for (n.children.items) |c| go(c, out);
        }
    };
    Walk.go(result.wrapper, &found);
    const row = found orelse return error.NoClickableRow;
    _ = ctx.dispatcher.dispatch(core.Event{ .click = .{ .x = 10, .y = 10 } }, row);
    try std.testing.expectEqual(@as(u32, 1), sink.clicks);
}

test "Table: 排序箭头随点击更新（indicator() 此前从未被调用）" {
    var ctx = try Cx.init(std.testing.allocator);
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
    const result = try Table(.{ .columns = &cols, .row_count = 2 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    const st = result.state;
    // 初始：无排序，两列都是占位
    try std.testing.expectEqualStrings(" ", SortDirection.none.indicator());

    // 模拟点第 0 列表头
    st.sort_column = 0;
    st.sort_direction = .asc;
    refreshSortIndicators(st);

    const ind0 = st.sort_indicators[0] orelse return error.NoIndicator;
    const txt0 = ind0.getText() orelse return error.NoText;
    try std.testing.expectEqualStrings("^", txt0.content);

    // 第 1 列应保持无排序态
    const ind1 = st.sort_indicators[1] orelse return error.NoIndicator;
    const txt1 = ind1.getText() orelse return error.NoText;
    try std.testing.expectEqualStrings(" ", txt1.content);

    // 再点同列 → desc
    st.sort_direction = st.sort_direction.toggle();
    refreshSortIndicators(st);
    const txt0b = (st.sort_indicators[0].?).getText().?;
    try std.testing.expectEqualStrings("v", txt0b.content);
}

test "Table.setSort: 程序化排序会刷新箭头（直接写字段则不会）" {
    var ctx = try Cx.init(std.testing.allocator);
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
    const result = try Table(.{ .columns = &cols, .row_count = 2 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    const st = result.state;
    st.setSort(1, .desc);
    try std.testing.expectEqual(@as(?usize, 1), st.sort_column);
    try std.testing.expectEqualStrings("v", (st.sort_indicators[1].?).getText().?.content);
    try std.testing.expectEqualStrings(" ", (st.sort_indicators[0].?).getText().?.content);

    st.clearSort();
    try std.testing.expectEqual(@as(?usize, null), st.sort_column);
    try std.testing.expectEqualStrings(" ", (st.sort_indicators[1].?).getText().?.content);
}

test "Table(virtual, hoverable): 反复滚动不泄漏 hover 上下文" {
    // 红绿证据：旧实现每次行滚入视口都 `allocator.create(RowHoverCtx)` 且从不
    // 释放。本用例用 testing.allocator（带泄漏检测）滚过上千行 —— 旧实现会以
    // "memory address ... leaked" 失败；现在 hover ctx 是 VirtualRowContext 里
    // 按 pool 槽位复用的定长表，分配数与滚过的行数无关。
    var ctx = try Cx.init(std.testing.allocator);
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
        .hoverable = true, // ← 关键：走 hover ctx 分配路径
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const vl = result.vl_state.?;
    const item_height: f32 = 36 + 1;
    vl.scroll_state.viewport_height = 400 - 40 - 2;
    vl.scroll_state.content_height = 10000 * item_height;

    // 滚过 2000 行：旧实现在这里泄漏 ~2000 个 RowHoverCtx
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        vl.scroll_state.scroll_y = @as(f32, @floatFromInt(i)) * item_height;
        vl.updateVisibleItems();
    }

    // hover 槽位数受 pool 容量约束，与滚过的 2000 行无关
    try std.testing.expect(vl.render_user_context != null);
    const vr: *VirtualRowContext = @ptrCast(@alignCast(vl.render_user_context.?));
    try std.testing.expect(vr.hover_slot_count > 0);
    try std.testing.expect(vr.hover_slot_count <= virtual_list.max_pool_size);
    try std.testing.expect(vr.hover_slot_count < 64); // 远小于 2000

    // 每个槽位都指向一个当前有效的 row_node（无悬垂/未初始化）
    for (vr.hover_slot_owner[0..vr.hover_slot_count], 0..) |owner, s| {
        try std.testing.expect(owner != null);
        try std.testing.expect(vr.hover_slots[s].row_node != null);
    }
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "table: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("table", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const cols = [_]ColumnDef{ .{ .id = "name", .header = "Name", .sortable = true }, .{ .id = "size", .header = "Size", .col_align = .right } };
            const r = try Table(.{ .columns = &cols, .row_count = 3, .striped = true }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
