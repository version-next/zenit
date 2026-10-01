/// Grid 业务组件状态 + Public update API
///
/// Phase 2：2D cell pool + visible range culling
/// - cells 用 absolute 定位在 content 节点里，`margin.left/top` = `col_offset[ci] / row_y`
/// - pool 大小恒定 = (viewport_rows + 2·overscan) × (viewport_cols + 2·overscan)
/// - col_offsets[] prefix sum -> O(log N) 二分定位 col_at_x
/// - on_before_render hook 每帧调 updateVisibleCells -> diff pool bindings
///
/// 生命周期：state 由 Grid.mount 通过 scope.registerResource 注册，
/// scope.dispose 时自动 cleanup（释放 pool 数组等）。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Node = core.Node;
const Cx = core.Cx;
const scroll_area = @import("../scroll_area/mod.zig");
const ScrollState = scroll_area.ScrollState;
const ScrollDirection = scroll_area.ScrollDirection;

/// 用户提供的 cell 渲染回调。
/// - cell_node: 组件预分配的 cell 容器（已设好尺寸 + 位置），caller 负责设 text / children
/// - row, col: cell 在表中的坐标（0-indexed）
/// - cx: UI 上下文
/// - user_ctx: caller 传入的上下文指针（通常是应用 state）
pub const CellRenderFn = *const fn (
    cell_node: *Node,
    row: usize,
    col: usize,
    cx: *Cx,
    user_ctx: ?*anyopaque,
) void;

pub const GridProps = struct {
    /// 总行数
    row_count: usize = 0,
    /// 总列数
    col_count: usize = 0,
    /// 每列宽度（px）。长度必须 == col_count。
    col_widths: []const f32 = &[_]f32{},
    /// Uniform 行高。若 `row_heights` 为 null 则所有 row 用此高度（快路径）。
    cell_height: f32 = 32,
    /// 每行高度（px）。长度必须 == row_count。非 null 时覆盖 `cell_height`。
    row_heights: ?[]const f32 = null,
    /// 容器宽度（null = grow）
    width: ?f32 = null,
    /// 容器高度（null = fit）
    height: ?f32 = null,
    /// 内层 ScrollArea 的滚动方向；默认保持双轴，调用方可收窄成单轴。
    scroll_direction: ScrollDirection = .both,
    /// cell 渲染回调（必填）
    cell_render_fn: ?CellRenderFn = null,
    cell_render_ctx: ?*anyopaque = null,
    /// 视口外额外渲染的行数 / 列数，提前加载让滚动不抖动
    overscan_rows: usize = 4,
    overscan_cols: usize = 2,
    /// 外部行窗口的高度提示（px）。计划用 setExternalRowWindow 驱动行绑定的宿主
    /// 应传宿主视口高度：初始 pool 按"窗口能盖住的行数"而非"Grid 自身高度/行数"
    /// 估算，否则 height=全内容高的 Grid 会为全部行分配 pool。
    row_window_height_hint: ?f32 = null,
    /// mount 时的初始外部行窗口。不传则首次 updateVisibleCells 按全行绑定
    ///（旧行为），窗口稍后推送时再收缩，会产生一次全量绑定尖峰。
    external_row_window: ?ExternalRowWindow = null,
    /// Frozen 行数：表头不随 y 滚动（典型用途 = 1，锁住 header）
    frozen_rows: usize = 0,
    /// Frozen 列数：最左 N 列不随 x 滚动
    frozen_cols: usize = 0,
    /// Debug / test 用的 component_name 后缀。默认 "Grid"
    debug_name: []const u8 = "Grid",
};

pub const VisibleRange = struct {
    row_start: usize = 0,
    row_end: usize = 0,
    col_start: usize = 0,
    col_end: usize = 0,

    pub fn eql(a: VisibleRange, b: VisibleRange) bool {
        return a.row_start == b.row_start and a.row_end == b.row_end and
            a.col_start == b.col_start and a.col_end == b.col_end;
    }
};

/// 外部纵向行窗口（content 局部坐标，px）。
/// 用于"Grid 高度 = 全内容高、纵向不自滚、随宿主文档滚动"的场景（markdown 表格）：
/// 此时 Grid 自身 scroll_y==0、viewport_h==内容高，行维度永远全绑定。宿主每帧把
/// 文档视口 ∩ Grid 区间换算成这段局部 y 窗口推进来，行绑定就只覆盖真正可见的行。
/// 宿主侧优先用 `setExternalRowWindowFromHost`（宿主坐标入口，框架自己扣内部
/// padding 偏移），而不是手动换算 content 局部坐标。
pub const ExternalRowWindow = struct {
    top: f32,
    bottom: f32,
};

/// 宿主视口（宿主滚动坐标系）。margin 是窗口两侧的额外余量：只用来吸收
/// "宿主本帧 early-return 没推窗"这类一帧级滞后，不得用来掩盖坐标换算误差。
pub const HostViewport = struct {
    scroll_y: f32,
    height: f32,
    margin: f32 = 0,
};

/// 行 pin 的归属方。不同生命周期的 pin 各占一个槽位，互不覆盖：
/// - .edit：编辑态 pin，由宿主显式 pin/unpin（编辑开始/结束）。
/// - .hit_test：命中测试按需绑定的瞬态 pin，宿主下一次推窗时自动释放。
/// 单一 nullable pin 会把两种生命周期搅在一起（曾导致"编辑 A 表时 B 表的
/// hit-test pin 永不释放"的泄漏）。
pub const PinOwner = enum(u1) {
    edit = 0,
    hit_test = 1,
};
pub const pin_owner_count = @typeInfo(PinOwner).@"enum".fields.len;

/// Pool 中每个 cell 节点当前绑定的坐标
pub const CellBinding = struct {
    row: usize,
    col: usize,
};

/// Grid 组件的可持久状态。
pub const GridState = struct {
    allocator: Allocator,
    cx: *Cx,

    /// 数据快照（caller 更新时通过 update API 同步）
    row_count: usize,
    col_count: usize,
    /// Grid 自持的列宽数组（copy，不 alias caller 指针）
    col_widths: []f32,
    /// col_offsets[i] = Σ col_widths[0..i]。长度 == col_count + 1。
    /// col_offsets[col_count] = totalContentWidth。
    col_offsets: []f32,
    /// Uniform 行高（fallback，`row_heights` 为空时用）
    cell_height: f32,
    /// 每行高度（owned copy）。空 slice = 用 cell_height uniform。
    row_heights: []f32,
    /// row_offsets[i] = Σ row_heights[0..i]（若 row_heights 非空）或 i*cell_height（uniform）。
    /// 长度 == row_count + 1。row_offsets[row_count] = totalContentHeight。
    row_offsets: []f32,

    /// Overscan 配置
    overscan_rows: usize,
    overscan_cols: usize,

    /// Frozen 行/列配置
    frozen_rows: usize,
    frozen_cols: usize,

    /// DOM 引用
    root: *Node,
    scroll_container: *Node,
    content: *Node,
    content_id: u32,
    scroll_state: *ScrollState,

    /// 4 层 pool，按 paint order 排列（先 append 的先 paint，后者覆盖前者）：
    /// 1. scrollable body (最底)
    /// 2. frozen col only (sticky 左列，不含角落)
    /// 3. frozen row only (sticky 顶行，不含角落；覆盖 frozen col 的重叠区域）
    /// 4. corner (角落：既在 frozen row 又在 frozen col，最顶)
    /// 不使用 z_index, render order 由 content.children 顺序决定
    /// (memory: feedback_listening_and_diff_paths.md 说过 z_index > 0 会跳出祖先 clip)
    pool_nodes: []*Node,
    pool_bindings: []?CellBinding,
    pool_size: usize,

    frozen_col_pool_nodes: []*Node,
    frozen_col_pool_bindings: []?CellBinding,
    frozen_col_pool_size: usize,

    frozen_row_pool_nodes: []*Node,
    frozen_row_pool_bindings: []?CellBinding,
    frozen_row_pool_size: usize,

    corner_pool_nodes: []*Node,
    corner_pool_bindings: []?CellBinding,
    corner_pool_size: usize,

    /// 记录上一帧 visible range，避免无变化时重复 diff
    prev_range: VisibleRange,
    initialized: bool = false,

    /// 外部纵向行窗口（见 ExternalRowWindow 注释）。null = 行窗口用自身 scroll。
    /// 调用方（宿主）每帧用当帧权威的滚动值推送，不要用 world rect 反推，
    /// world rect 落后 translate 一帧，快速滚动会露出未绑定行。
    external_row_window: ?ExternalRowWindow = null,
    /// 强制保持绑定的行（按 PinOwner 分槽：编辑 pin / 命中测试瞬态 pin）。
    /// 回收循环跳过 pinned 行，绑定循环补上它；行本身可以在窗口外。
    pinned_rows: [pin_owner_count]?usize = @splat(null),
    /// 上一帧的 pinned_rows，用于让 pin 变化触发一次 rebind diff。
    prev_pinned_rows: [pin_owner_count]?usize = @splat(null),
    /// tryBindInPool 因池满静默跳过的累计次数（可观测性：视口内 cell 空白的
    /// 第一嫌疑就是它）。
    pool_exhausted_count: u32 = 0,

    /// 上一帧 content.translate_x/y，用于判断 translate 是否变化，
    /// 避免 idle 时每帧无意义 markRenderDirty + markLayoutDirty。
    last_content_tx: f32 = 0,
    last_content_ty: f32 = 0,

    /// 渲染回调
    cell_render_fn: CellRenderFn,
    cell_render_ctx: ?*anyopaque,

    pub fn totalContentWidth(self: *const GridState) f32 {
        if (self.col_offsets.len == 0) return 0;
        return self.col_offsets[self.col_offsets.len - 1];
    }

    pub fn totalContentHeight(self: *const GridState) f32 {
        if (self.row_count == 0) return 0;
        return self.row_offsets[self.row_count];
    }

    /// 返回第 row 行的 top y（相对 content 原点）
    pub fn rowTop(self: *const GridState, row: usize) f32 {
        return self.row_offsets[@min(row, self.row_count)];
    }

    /// 返回第 row 行的高度
    pub fn rowHeight(self: *const GridState, row: usize) f32 {
        if (row >= self.row_count) return 0;
        return self.row_offsets[row + 1] - self.row_offsets[row];
    }

    /// 重建 row_offsets：有 row_heights 用 prefix sum，否则用 row*cell_height
    pub fn rebuildRowOffsets(self: *GridState) void {
        self.row_offsets[0] = 0;
        if (self.row_heights.len == self.row_count and self.row_count > 0) {
            var acc: f32 = 0;
            for (self.row_heights, 0..) |h, i| {
                acc += h;
                self.row_offsets[i + 1] = acc;
            }
        } else {
            for (0..self.row_count) |i| {
                self.row_offsets[i + 1] = @as(f32, @floatFromInt(i + 1)) * self.cell_height;
            }
        }
    }

    /// 二分查找：row 在 prefix sum 里的位置
    fn rowAtY(self: *const GridState, y: f32) usize {
        if (self.row_count == 0 or y <= 0) return 0;
        var lo: usize = 0;
        var hi: usize = self.row_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.row_offsets[mid + 1] > y) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }

    /// 重算并同步 content 节点宽高 + ScrollState 内容尺寸，clamp scroll 位置
    pub fn syncContentSize(self: *GridState) void {
        const cw = self.totalContentWidth();
        const ch = self.totalContentHeight();
        self.content.style.width = .{ .px = cw };
        self.content.style.height = .{ .px = ch };
        self.scroll_state.content_width = cw;
        self.scroll_state.content_height = ch;
        const max_x = self.scroll_state.maxScrollX();
        if (self.scroll_state.scroll_x > max_x) self.scroll_state.scroll_x = max_x;
        const max_y = self.scroll_state.maxScrollY();
        if (self.scroll_state.scroll_y > max_y) self.scroll_state.scroll_y = max_y;
        self.content.markLayoutDirty();
    }

    /// 重建 col_offsets（widths 变化后调用）
    pub fn rebuildColOffsets(self: *GridState) void {
        var acc: f32 = 0;
        self.col_offsets[0] = 0;
        for (self.col_widths, 0..) |w, i| {
            acc += w;
            self.col_offsets[i + 1] = acc;
        }
    }

    // ======================================================================
    // Visible range 计算
    // ======================================================================

    /// 二分查找：第一个 col_offsets[i+1] > x 的 i（即 x 落在第几列）
    /// 返回 [0, col_count]。若 x < 0 返回 0；若 x >= total 返回 col_count。
    fn colAtX(self: *const GridState, x: f32) usize {
        if (self.col_count == 0 or x <= 0) return 0;
        // col_offsets[i+1] = cumulative width after column i
        // 找最小 i 使得 col_offsets[i+1] > x
        var lo: usize = 0;
        var hi: usize = self.col_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.col_offsets[mid + 1] > x) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }

    pub fn computeVisibleRange(self: *const GridState) VisibleRange {
        if (self.row_count == 0 or self.col_count == 0) return .{};

        const viewport_w = self.scroll_state.viewport_width;
        const viewport_h = self.scroll_state.viewport_height;
        if (viewport_w <= 0 or viewport_h <= 0) {
            // Viewport 还没布局；返回"全部可见"的保守估计（让 initial mount 能工作）
            const col_end = @min(self.col_count, self.overscan_cols * 2 + 4);
            const row_end = @min(self.row_count, self.overscan_rows * 2 + 6);
            return .{ .row_start = 0, .row_end = row_end, .col_start = 0, .col_end = col_end };
        }

        const sx = @max(self.scroll_state.scroll_x, 0);
        const sy = @max(self.scroll_state.scroll_y, 0);

        // 行：外部窗口优先（宿主滚动决定可见行），否则用自身 scroll。
        var row_start: usize = undefined;
        var row_end: usize = undefined;
        if (self.external_row_window) |w| {
            const total_h = self.totalContentHeight();
            if (w.bottom <= 0 or w.top >= total_h or w.bottom <= w.top) {
                // 窗口与内容无交集：空绑定（pinned 行由 updateVisibleCells 单独补）
                row_start = self.frozen_rows;
                row_end = self.frozen_rows;
            } else {
                row_start = self.rowAtY(@max(w.top, 0));
                row_end = @min(self.row_count, self.rowAtY(@max(w.bottom, 0)) + 1);
                row_start = row_start -| self.overscan_rows;
                row_end = @min(self.row_count, row_end + self.overscan_rows);
                row_start = @max(row_start, self.frozen_rows);
            }
        } else {
            // 二分 prefix sum（支持 per-row height）
            row_start = self.rowAtY(sy);
            row_end = self.rowAtY(sy + viewport_h);
            row_end = @min(self.row_count, row_end + 1); // inclusive 右边界
            row_start = row_start -| self.overscan_rows;
            row_end = @min(self.row_count, row_end + self.overscan_rows);
            // 排除 frozen 行（它们走独立路径）
            row_start = @max(row_start, self.frozen_rows);
        }

        // 列：二分 prefix sum
        var col_start = self.colAtX(sx);
        var col_end = self.colAtX(sx + viewport_w);
        col_end = @min(self.col_count, col_end + 1); // inclusive 右边界
        col_start = col_start -| self.overscan_cols;
        col_end = @min(self.col_count, col_end + self.overscan_cols);
        // 排除 frozen 列
        col_start = @max(col_start, self.frozen_cols);
        // frozen 区宽/高于视口时 start 会被抬过 end：保持 end >= start（空区间），
        // 否则调用方 `end - start` 下溢 panic。
        col_end = @max(col_end, col_start);
        row_end = @max(row_end, row_start);

        return .{
            .row_start = row_start,
            .row_end = row_end,
            .col_start = col_start,
            .col_end = col_end,
        };
    }

    /// 宿主每帧推送外部行窗口（content 局部 y 区间，px）。
    /// 生效时机：下一次 updateVisibleCells（Grid content 的 before_render hook）。
    /// 副作用：释放 .hit_test 瞬态 pin（它的生命周期就是"到下一次推窗为止"）。
    pub fn setExternalRowWindow(self: *GridState, top: f32, bottom: f32) void {
        self.external_row_window = .{ .top = top, .bottom = bottom };
        self.pinned_rows[@intFromEnum(PinOwner.hit_test)] = null;
    }

    /// 宿主坐标入口：宿主只需给出"自己视口"与"Grid root 顶边在宿主坐标系里的 y"。
    /// content 相对 grid root 的内部偏移（scroll_container 的 padding.top）由框架
    /// 自己扣，这是 Grid 的私有布局知识，宿主不该复制（复制出错时会被 margin
    /// 静默吸收，永远发现不了）。
    pub fn setExternalRowWindowFromHost(
        self: *GridState,
        vp: HostViewport,
        grid_root_top_in_host: f32,
    ) void {
        const content_top_in_host = grid_root_top_in_host + self.scroll_container.style.padding.top;
        self.setExternalRowWindow(
            vp.scroll_y - content_top_in_host - vp.margin,
            vp.scroll_y + vp.height - content_top_in_host + vp.margin,
        );
    }

    pub fn clearExternalRowWindow(self: *GridState) void {
        self.external_row_window = null;
    }

    /// 强制绑定某一行（编辑/命中需要真实节点时）。
    pub fn pinRow(self: *GridState, owner: PinOwner, row: usize) void {
        self.pinned_rows[@intFromEnum(owner)] = @min(row, self.row_count -| 1);
    }

    pub fn unpinRow(self: *GridState, owner: PinOwner) void {
        self.pinned_rows[@intFromEnum(owner)] = null;
    }

    pub fn rowIsPinned(self: *const GridState, row: usize) bool {
        for (self.pinned_rows) |p| {
            if (p) |pr| if (pr == row) return true;
        }
        return false;
    }

    /// 几何变化（行列数/行高改变）后的失效处理：pin 与外部窗口都可能指向
    /// 已不存在的行/区间。pin 越界直接解除（宿主下一帧会重新 pin）；窗口
    /// 整体落在新内容之外时平移贴到内容末尾，避免"整表空白一帧"的塌缩。
    pub fn clampAfterGeometryChange(self: *GridState) void {
        // 行列数缩小后 frozen 不能超过总数（mount 时同一约束以 error 返回）
        self.frozen_rows = @min(self.frozen_rows, self.row_count);
        self.frozen_cols = @min(self.frozen_cols, self.col_count);
        for (&self.pinned_rows) |*p| {
            if (p.*) |pr| {
                if (pr >= self.row_count) p.* = null;
            }
        }
        if (self.external_row_window) |*w| {
            const total = self.totalContentHeight();
            if (w.top >= total) {
                const h = w.bottom - w.top;
                w.bottom = total;
                w.top = @max(0, total - h);
            }
        }
    }

    pub fn effectiveScrollX(self: *const GridState) f32 {
        const v = self.scroll_state.effectiveScrollX();
        return if (std.math.isFinite(v)) v else self.scroll_state.scroll_x;
    }

    pub fn effectiveScrollY(self: *const GridState) f32 {
        const v = self.scroll_state.effectiveScrollY();
        return if (std.math.isFinite(v)) v else self.scroll_state.scroll_y;
    }
};
