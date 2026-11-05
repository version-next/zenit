/// Grid business component state + public update API
///
/// 2D cell pool + visible range culling:
/// - cells are positioned absolutely in the content node, `margin.left/top` = `col_offset[ci] /
///   row_y`
/// - pool size is constant = (viewport_rows + 2*overscan) * (viewport_cols + 2*overscan)
/// - col_offsets[] prefix sum -> O(log N) binary search for col_at_x
/// - the on_before_render hook calls updateVisibleCells each frame, diffing pool bindings
///
/// Lifecycle: state is registered by Grid.mount via scope.registerResource and cleaned up on
/// scope.dispose (pool arrays released, etc).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Node = core.Node;
const Cx = core.Cx;
const Scope = @import("../../reactive.zig").Scope;
const scroll_area = @import("../scroll_area/mod.zig");
const ScrollState = scroll_area.ScrollState;
const ScrollDirection = scroll_area.ScrollDirection;

/// User-provided cell render callback.
/// - cell_node: pre-allocated cell container (size + position set); caller sets text / children
/// - row, col: cell coordinate in the table (0-indexed)
/// - cx: UI context
/// - user_ctx: caller-provided context pointer (typically application state)
pub const CellRenderFn = *const fn (
    cell_node: *Node,
    row: usize,
    col: usize,
    cx: *Cx,
    user_ctx: ?*anyopaque,
) void;

/// Cell render callback that also receives the grid's own scope (used by `Grid.cells`). That
/// scope owns the cell pools and is bound to the grid root, so content mounted under it is
/// released with its cell on rebind *and* with the grid when the grid root is freed.
pub const ScopedCellRenderFn = *const fn (
    cell_node: *Node,
    row: usize,
    col: usize,
    scope: *Scope,
    cx: *Cx,
    user_ctx: ?*anyopaque,
) void;

/// How the grid populates a cell (exactly one callback form per grid).
pub const CellRender = union(enum) {
    plain: CellRenderFn,
    scoped: ScopedCellRenderFn,
};

pub const GridProps = struct {
    /// Total row count
    row_count: usize = 0,
    /// Total column count
    col_count: usize = 0,
    /// Column widths (px). Length must == col_count.
    col_widths: []const f32 = &[_]f32{},
    /// Uniform row height (px). If `row_heights` is null, all rows use this height (fast path).
    cell_height: f32 = 32,
    /// Per-row heights (px). Length must == row_count. When non-null, overrides `cell_height`.
    row_heights: ?[]const f32 = null,
    /// Container width (null = grow)
    width: ?f32 = null,
    /// Container height (null = fit)
    height: ?f32 = null,
    /// Inner ScrollArea scroll direction; default both axes, caller can narrow to single axis.
    scroll_direction: ScrollDirection = .both,
    /// Cell render callback (required)
    cell_render_fn: ?CellRenderFn = null,
    cell_render_ctx: ?*anyopaque = null,
    /// Extra rows/cols to render outside viewport, prefetch to prevent scroll jitter
    overscan_rows: usize = 4,
    overscan_cols: usize = 2,
    /// External row window height hint (px). Plan to drive row binding via setExternalRowWindow:
    /// caller should pass host viewport height: initial pool sized by "rows viewport covers"
    /// not "Grid self height / row count", else height=full-content Grid allocates pool for all.
    row_window_height_hint: ?f32 = null,
    /// Initial external row window at mount. Omit to use all-rows binding on first
    /// updateVisibleCells
    /// (old behavior), narrow later when window arrives, causes one full-binding spike.
    external_row_window: ?ExternalRowWindow = null,
    /// Frozen rows: header stays at top across y scroll (typical use = 1, lock header)
    frozen_rows: usize = 0,
    /// Frozen cols: leftmost N cols don't scroll with x
    frozen_cols: usize = 0,
    /// Debug / test component_name suffix. Default "Grid"
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

/// External row window (content-local coords, px).
/// For "Grid height = full content, no self-scroll, follows host document scroll" (markdown table):
/// Grid scroll_y==0, viewport_h==content_h, rows always fully bound. Each frame the host converts
/// (doc viewport INTERSECT Grid region) into this segment's local y window, so row binding covers
/// only truly visible rows. Hosts should use `setExternalRowWindowFromHost` (host coords; the
/// framework subtracts the internal padding offset) rather than converting to content-local coords.
pub const ExternalRowWindow = struct {
    top: f32,
    bottom: f32,
};

/// Host viewport (host scroll coordinate system). margin is window's extra margin:
/// only absorbs "host early-return this frame didn't push window" latency, must not
/// mask coordinate conversion errors.
pub const HostViewport = struct {
    scroll_y: f32,
    height: f32,
    margin: f32 = 0,
};

/// Row pin ownership. Pins with different lifecycles each occupy one slot, no override:
/// - .edit: edit-state pin, host explicitly pins/unpins (edit start/end).
/// - .hit_test: transient pin for command hit-test, auto-released when the host next pushes a
///   window.
/// A single nullable pin would mix both lifecycles (a hit-test pin from table A never released
/// while editing table B).
pub const PinOwner = enum(u1) {
    edit = 0,
    hit_test = 1,
};
pub const pin_owner_count = @import("zenit_reflection").fields(PinOwner).len;

/// Coordinate each pool cell node is bound to
pub const CellBinding = struct {
    row: usize,
    col: usize,
};

/// Grid component persistent state.
pub const GridState = struct {
    allocator: Allocator,
    cx: *Cx,

    /// Data snapshot (synced by caller via update API)
    row_count: usize,
    col_count: usize,
    /// Grid-owned column widths array (copy, doesn't alias caller pointer)
    col_widths: []f32,
    /// col_offsets[i] = SUM col_widths[0..i]. Length == col_count + 1.
    /// col_offsets[col_count] = totalContentWidth.
    col_offsets: []f32,
    /// Uniform row height (fallback when `row_heights` empty)
    cell_height: f32,
    /// Per-row heights (owned copy). Empty slice = use cell_height uniform.
    row_heights: []f32,
    /// row_offsets[i] = SUM row_heights[0..i] (if row_heights non-empty) or i*cell_height
    /// (uniform).
    /// Length == row_count + 1. row_offsets[row_count] = totalContentHeight.
    row_offsets: []f32,

    /// Overscan config
    overscan_rows: usize,
    overscan_cols: usize,

    /// Frozen rows/cols config
    frozen_rows: usize,
    frozen_cols: usize,

    /// DOM reference
    root: *Node,
    scroll_container: *Node,
    content: *Node,
    content_id: u32,
    scroll_state: *ScrollState,

    /// 4-layer pool, paint order (earlier append paints first, later covers):
    /// 1. scrollable body (bottom)
    /// 2. frozen col only (sticky left cols, no corner)
    /// 3. frozen row only (sticky top row, no corner; covers frozen col overlap)
    /// 4. corner (both frozen row + col, top)
    /// No z_index: render order is determined by content.children order
    /// (z_index > 0 would escape the ancestor clip)
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

    /// Record previous visible range, avoid repeat diff when unchanged
    prev_range: VisibleRange,
    initialized: bool = false,

    /// External row window (see ExternalRowWindow comment). null = row window uses self scroll.
    /// Caller (host) each frame pushes current frame's authoritative scroll value, don't
    /// reverse-compute from world rect, world rect lags translate by one frame, fast scroll exposes
    /// unbound rows.
    external_row_window: ?ExternalRowWindow = null,
    /// Rows forced to stay bound (split by PinOwner: edit pin / hit_test transient pin).
    /// Recycle loop skips pinned rows, bind loop adds back; row itself can be outside window.
    pinned_rows: [pin_owner_count]?usize = @splat(null),
    /// Previous frame's pinned_rows, used to trigger rebind diff when pins change.
    prev_pinned_rows: [pin_owner_count]?usize = @splat(null),
    /// Accumulated count of tryBindInPool failures when pool full (observability: first suspect
    /// for blank cells in viewport).
    pool_exhausted_count: u32 = 0,

    /// Previous frame content.translate_x/y, used to detect translate change,
    /// avoid idle frame's meaningless markRenderDirty + markLayoutDirty.
    last_content_tx: f32 = 0,
    last_content_ty: f32 = 0,

    /// Render callback
    cell_render: CellRender,
    cell_render_ctx: ?*anyopaque,
    /// The grid's own scope (bound to `root`): owner of the cell pools and of everything the
    /// scoped render callback mounts into them.
    scope: *Scope,

    /// Populate a (cleared) cell through the grid's render callback.
    pub fn renderCell(self: *GridState, node: *Node, row: usize, col: usize) void {
        switch (self.cell_render) {
            .plain => |f| f(node, row, col, self.cx, self.cell_render_ctx),
            .scoped => |f| f(node, row, col, self.scope, self.cx, self.cell_render_ctx),
        }
    }

    pub fn totalContentWidth(self: *const GridState) f32 {
        if (self.col_offsets.len == 0) return 0;
        return self.col_offsets[self.col_offsets.len - 1];
    }

    pub fn totalContentHeight(self: *const GridState) f32 {
        if (self.row_count == 0) return 0;
        return self.row_offsets[self.row_count];
    }

    /// Return row's top y (relative to content origin)
    pub fn rowTop(self: *const GridState, row: usize) f32 {
        return self.row_offsets[@min(row, self.row_count)];
    }

    /// Return row height
    pub fn rowHeight(self: *const GridState, row: usize) f32 {
        if (row >= self.row_count) return 0;
        return self.row_offsets[row + 1] - self.row_offsets[row];
    }

    /// Rebuild row_offsets: use prefix sum if row_heights exists, else use row*cell_height
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

    /// Binary search: row position in prefix sum
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

    /// Recalc and sync content node w/h + ScrollState content size, clamp scroll position
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

    /// Rebuild col_offsets (call after widths change)
    pub fn rebuildColOffsets(self: *GridState) void {
        var acc: f32 = 0;
        self.col_offsets[0] = 0;
        for (self.col_widths, 0..) |w, i| {
            acc += w;
            self.col_offsets[i + 1] = acc;
        }
    }

    // Visible range calculation

    /// Binary search: first col where col_offsets[i+1] > x (which col x falls in)
    /// Returns [0, col_count]. If x < 0 returns 0; if x >= total returns col_count.
    fn colAtX(self: *const GridState, x: f32) usize {
        if (self.col_count == 0 or x <= 0) return 0;
        // col_offsets[i+1] = cumulative width after column i
        // find minimum i where col_offsets[i+1] > x
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
            // Viewport not yet laid out; return conservative "all visible" (let initial mount work)
            const col_end = @min(self.col_count, self.overscan_cols * 2 + 4);
            const row_end = @min(self.row_count, self.overscan_rows * 2 + 6);
            return .{ .row_start = 0, .row_end = row_end, .col_start = 0, .col_end = col_end };
        }

        const sx = @max(self.scroll_state.scroll_x, 0);
        const sy = @max(self.scroll_state.scroll_y, 0);

        // Rows: external window priority (host scroll determines visible rows), else use self
        // scroll.
        var row_start: usize = undefined;
        var row_end: usize = undefined;
        if (self.external_row_window) |w| {
            const total_h = self.totalContentHeight();
            if (w.bottom <= 0 or w.top >= total_h or w.bottom <= w.top) {
                // Window and content don't intersect: empty bind (pinned rows added separately by
                // updateVisibleCells)
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
            // Binary search prefix sum (supports per-row height)
            row_start = self.rowAtY(sy);
            row_end = self.rowAtY(sy + viewport_h);
            row_end = @min(self.row_count, row_end + 1); // inclusive right boundary
            row_start = row_start -| self.overscan_rows;
            row_end = @min(self.row_count, row_end + self.overscan_rows);
            // Exclude frozen rows (they have separate path)
            row_start = @max(row_start, self.frozen_rows);
        }

        // Columns: binary search prefix sum
        var col_start = self.colAtX(sx);
        var col_end = self.colAtX(sx + viewport_w);
        col_end = @min(self.col_count, col_end + 1); // inclusive right boundary
        col_start = col_start -| self.overscan_cols;
        col_end = @min(self.col_count, col_end + self.overscan_cols);
        // Exclude frozen columns
        col_start = @max(col_start, self.frozen_cols);
        // When frozen region wider/taller than viewport, start pushed past end:
        // keep end >= start (empty range), else caller's `end - start` underflows panic.
        col_end = @max(col_end, col_start);
        row_end = @max(row_end, row_start);

        return .{
            .row_start = row_start,
            .row_end = row_end,
            .col_start = col_start,
            .col_end = col_end,
        };
    }

    /// Host each frame pushes external row window (content-local y range, px).
    /// Takes effect: next updateVisibleCells (Grid content before_render hook).
    /// Side effect: releases .hit_test transient pins (lifecycle = "until next window push").
    pub fn setExternalRowWindow(self: *GridState, top: f32, bottom: f32) void {
        self.external_row_window = .{ .top = top, .bottom = bottom };
        self.pinned_rows[@backingInt(PinOwner.hit_test)] = null;
    }

    /// Host coordinate entry: host only needs to give "own viewport" and "Grid root top y in host
    /// coords".
    /// content offset relative to grid root (scroll_container padding.top) framework
    /// auto-subtracts,
    /// private Grid layout knowledge, host shouldn't duplicate (errors masked by margin,
    /// never found).
    pub fn setExternalRowWindowFromHost(
        self: *GridState,
        vp: HostViewport,
        grid_root_top_in_host: f32,
    ) void {
        const content_top_in_host = grid_root_top_in_host + self.scroll_container.style.contentInsets().top;
        self.setExternalRowWindow(
            vp.scroll_y - content_top_in_host - vp.margin,
            vp.scroll_y + vp.height - content_top_in_host + vp.margin,
        );
    }

    pub fn clearExternalRowWindow(self: *GridState) void {
        self.external_row_window = null;
    }

    /// Force bind a row (edit / hit-test needs real node).
    pub fn pinRow(self: *GridState, owner: PinOwner, row: usize) void {
        self.pinned_rows[@backingInt(owner)] = @min(row, self.row_count -| 1);
    }

    pub fn unpinRow(self: *GridState, owner: PinOwner) void {
        self.pinned_rows[@backingInt(owner)] = null;
    }

    pub fn rowIsPinned(self: *const GridState, row: usize) bool {
        for (self.pinned_rows) |p| {
            if (p) |pr| if (pr == row) return true;
        }
        return false;
    }

    /// After geometry change (row/col count / height changed): pin + external window may point to
    /// nonexistent rows/ranges. Pinned out-of-bounds auto-released (host re-pins next frame);
    /// window wholly outside new content: shift to content end, avoid "blank table one frame"
    /// collapse.
    pub fn clampAfterGeometryChange(self: *GridState) void {
        // After row/col shrink frozen can't exceed totals (same constraint at mount returns error)
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
