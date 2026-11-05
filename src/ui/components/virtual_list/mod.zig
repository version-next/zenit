/// VirtualList Component
///
/// Virtual scroll list: only renders visible item nodes (+ overscan buffer), so 30k+ data
/// rows need only N actual nodes.
///
/// Design (react-window / Flutter ListView.builder / floating-ui):
/// 1. Fixed-height mode: O(1) locate, peak performance
/// 2. Node pool reuse: items scrolled out are recycled to the pool, new ones updated from it
/// 3. Integrated with ScrollArea: reuses Apple scroll physics (rubberband/spring/momentum)
/// 4. Retained mount() API: Scope manages all lifetimes
///
/// Usage:
/// ```zig
/// const vl = try VirtualList(.{
///     .item_count = 30000,
///     .item_height = 32,
///     .width = 300,
///     .height = 400,
/// }).mount(scope, cx, struct {
///     fn render(node: *Node, index: usize, cx_ptr: *Cx) void {
///         node.text = .{ .content = "..." };
///     }
/// }.render);
/// try parent.appendChild(cx.allocator, vl.container);
///
/// // dynamic item count:
/// virtual_list.updateItemCount(vl.state, 50000);
///
/// // scroll to position:
/// virtual_list.scrollToIndex(vl.state, 500);
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const scroll_area = @import("../scroll_area/mod.zig");
const a11y_collection = @import("../../a11y/collection.zig");
const ScrollState = scroll_area.ScrollState;
const ScrollDirection = scroll_area.ScrollDirection;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
pub const measurements = @import("measurements.zig");
pub const Measurements = measurements.Measurements;
pub const ItemKey = measurements.ItemKey;

/// VirtualList properties
pub const VirtualListProps = struct {
    /// total item count (can pass signal/derived: on change update row
    /// count redraw visible)
    item_count: Source(usize) = .{ .value = 0 },
    /// data version: row count same but content changed swap value (or
    /// derive from data signal), redraw visible rows
    data_version: Source(u64) = .{ .value = 0 },
    /// Fixed height of each item (px)
    item_height: f32 = 32,
    /// Container width
    width: ?f32 = null,
    /// Container height
    height: ?f32 = null,
    /// Additional rows rendered outside viewport (overscan top and bottom)
    overscan: usize = 5,
    /// Padding
    padding: Padding = Padding.ZERO,
    /// Container background color
    background: Color = Color.TRANSPARENT,
    /// Scroll speed multiplier
    scroll_speed: f32 = 1,
    /// Scroll direction (default vertical)
    scroll_direction: ScrollDirection = .vertical,
    /// Content width (for horizontal scrolling, null = determined by layout)
    content_width: ?f32 = null,
    /// Optional: returns height (px) per item. When set, enters **variable-height mode**.
    ///
    /// null (default) -> all items use `item_height`.
    /// non-null -> total height, visible range, spacer, ensureVisible all use prefix sums.
    /// Callback must be pure and stable per index: it is called multiple times per frame,
    /// and values varying within one frame make scroll geometry inconsistent.
    item_height_fn: ?*const fn (index: usize, user_context: ?*anyopaque) f32 = null,
    /// Context passed to `item_height_fn` (usually same as render's user_context).
    item_height_context: ?*anyopaque = null,

    /// **Dynamic measurement mode**: item heights are content-determined, measured and
    /// recorded by the component.
    ///
    /// Three height modes:
    /// - default (none set) -> uniform `item_height`, O(1) positioning, fastest.
    /// - `item_height_fn` -> variable height but **pre-calculable** (e.g., diff rows:
    ///   code lines 20, hunk header 28). No measurement needed, geometry resolved at once.
    /// - `measure_items = true` -> variable height and **unknown upfront** (e.g.,
    ///   auto-wrapped comments, chat bubbles). Items are initially sized via
    ///   `estimate_item_height`; after layout the actual height is read back and
    ///   recorded, and scroll position is compensated.
    ///
    /// If `item_height_fn` is also set, it takes precedence (cheaper and exact).
    measure_items: bool = false,
    /// Placeholder height for unmeasured items. More accurate = smoother scrollbar.
    estimate_item_height: f32 = 32,
    /// Optional: index -> stable key. When set, measured heights follow **data**
    /// rather than position, so inserting a row at the head keeps subsequent rows'
    /// measurements valid.
    /// null = use index itself (head insertions/deletions require re-measure).
    item_key_fn: ?*const fn (index: usize, user_context: ?*anyopaque) measurements.ItemKey = null,
    /// Context passed to `item_key_fn` (null = reuse render's user_context).
    item_key_context: ?*anyopaque = null,
    /// Optional: text for assistive tech on item index; write to buf and return the slice.
    ///
    /// The list exposes **all** data rows to VoiceOver (not just the dozen or so rendered).
    /// Rendered rows are read directly; unrendered (off-screen) rows are read here, defaulting
    /// to "Row N" if unset. Invoked when AT queries: must be read-only, cheap, non-allocating,
    /// and preserve UI state.
    item_label_fn: ?*const fn (index: usize, buf: []u8, user_context: ?*anyopaque) []const u8 = null,
    /// Context passed to `item_label_fn` (null = reuse render's user_context).
    item_label_context: ?*anyopaque = null,
};

/// Item render callback: user populates item node content via this function.
/// - node: pre-allocated item container (sized), user sets text/background/children
/// - index: item index in data source [0, item_count)
/// - cx: UI context
pub const RenderItemFn = *const fn (node: *Node, index: usize, cx: *Cx) void;
pub const RenderItemWithContextFn = *const fn (node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void;
/// Item render callback that also receives the list's own scope (`mountScoped`). That scope owns
/// the pool slots and is retired with the list container, so content mounted under it (e.g. via
/// `ui.view.renderInto`) is released with its slot on recycle *and* with the list when the list
/// itself is freed -- never left behind in a longer-lived caller scope.
pub const RenderItemScopedFn = *const fn (node: *Node, index: usize, scope: *Scope, cx: *Cx, user_context: ?*anyopaque) void;

/// How the list populates a slot (exactly one callback form per list).
const RenderCallback = union(enum) {
    plain: RenderItemFn,
    with_context: RenderItemWithContextFn,
    scoped: RenderItemScopedFn,
};

/// VirtualList internal state (lifecycle managed via Scope)
pub const VirtualListState = struct {
    /// item_count / data_version as dynamic source effect: update row count and
    /// redraw visible rows when changed
    fn sourceEffect(self: *VirtualListState) void {
        const count = self.props.item_count.read(true);
        const version = self.props.data_version.read(true);
        if (count == self.item_count and version == self.shown_version) return;
        self.shown_version = version;
        updateItemCount(self, count);
    }

    props: VirtualListProps,
    /// Current row count (props.item_count is data source, this is applied value)
    item_count: usize,
    /// Applied data version
    shown_version: u64 = 0,
    render: RenderCallback,
    render_user_context: ?*anyopaque = null,
    /// The list's own scope (bound to the container): owner of the pool slots and of everything
    /// the scoped render callback mounts into them.
    scope: *Scope,
    cx: *Cx,

    /// ScrollArea's scroll state pointer
    scroll_state: *ScrollState,

    /// ScrollArea's outer container (viewport)
    container_node: *Node,
    /// Content container (ScrollArea's content node). Also a11y semantic collection
    /// table node.
    content_node: *Node,
    /// a11y semantic collection data era: advanced when dataset changes
    /// (updateItemCount). Rows created by AT in prior era destroyed/rebuilt on new
    /// era. Scrolling, rebinding, height changes do not count.
    a11y_generation: u64 = 1,
    /// Spacer node for height (top spacer, positions visible items correctly)
    top_spacer: *Node,
    /// Bottom spacer (fills remaining height, scrollbar accuracy)
    bottom_spacer: *Node,

    /// Node pool: fixed-size item nodes
    pool_nodes: []*Node,
    pool_size: usize,
    /// Data index bound to each pool node (null = idle/hidden)
    pool_bindings: []?usize,

    /// Previous frame's visible range
    prev_start: usize = 0,
    prev_end: usize = 0,
    /// Whether first render initialized
    initialized: bool = false,
    /// Whether the prior complete rebind finished. growPool failure, slot exhaustion and
    /// reorderPoolNodes failure all mean "degrade this frame, retry next", but the
    /// updateVisibleItems early return only checks prev_start/prev_end, so an unchanged range
    /// never retries; missing rows and wrong order persist until the user scrolls.
    /// Set this flag to force a complete pass next frame.
    rebind_incomplete: bool = false,
    /// The render callback returns void, so failure is only `catch return` and leaves an
    /// incomplete row undrawn. The callback calls `markPoolNodeRenderIncomplete(node)` at the
    /// failure point: the slot unbinds immediately (subtree cleared) and is marked incomplete;
    /// next frame updateVisibleItems re-slots and re-calls for the same data index.
    /// Separate from rebind_incomplete because the end of updateVisibleItems overwrites it.
    render_retry_pending: bool = false,
    /// Persistent callback failure backoff: no ceiling, intervals
    /// grow. Otherwise continuous OOM on one row makes VL drop range each frame,
    /// full pass + markLayoutDirty every frame, frame loop never stops. streak =
    /// consecutive failure passes, wait = frames to skip before retry (1,3,7,15,31,60).
    render_retry_streak: u8 = 0,
    render_retry_wait: u16 = 0,

    /// Dynamic measurement ledger (null when measure_items = false).
    measured: ?*Measurements = null,
    /// Prior frame scroll_y, used for scroll direction detection, fed to re-measure
    /// anchor criteria.
    prev_scroll_y: f32 = 0,
    scroll_direction: measurements.ScrollDirection = .idle,

    allocator: Allocator,

    /// In dynamic measurement mode.
    /// Have geometry ledger (prefix sums + binary search).
    /// Both `measure_items` and `item_height_fn` variable modes hold ledger.
    pub inline fn hasLedger(self: *const VirtualListState) bool {
        return self.measured != null;
    }

    /// In **re-measurement mode**: heights are unknown upfront; layout measures then records.
    ///
    /// Distinct from `hasLedger`: `item_height_fn` also has a ledger, but its heights are
    /// caller-provided authority, never measured/re-measured. Conflating them would let
    /// measurement overwrite `item_height_fn` rows and break the caller's geometry contract.
    pub inline fn isMeasured(self: *const VirtualListState) bool {
        return self.measured != null and self.props.measure_items and
            self.props.item_height_fn == null;
    }

    /// Height of item at index. Uniform mode always `item_height`.
    pub fn itemHeight(self: *const VirtualListState, index: usize) f32 {
        if (self.measured) |m| {
            // sizeOf read-only on sizes/estimate, no prefix-sum mutation, so usable in
            // const context.
            return m.sizeOf(index);
        }
        const f = self.props.item_height_fn orelse return self.props.item_height;
        const h = f(index, self.props.item_height_context);
        // Height must be positive and finite: 0 or NaN make "which item" division
        // infinite-loop.
        return if (std.math.isFinite(h) and h > 0) h else self.props.item_height;
    }

    /// Sum of heights [0, index), i.e., top y of item at index.
    pub fn offsetOf(self: *const VirtualListState, index: usize) f32 {
        if (self.measured) |m| {
            // Prefix sum is cached, reading requires mutable ref; const here is
            // "logically read-only".
            return @constCast(m).offsetOf(index);
        }
        // No ledger = uniform height mode.
        return @as(f32, @floatFromInt(index)) * self.props.item_height;
    }

    pub fn totalContentHeight(self: *const VirtualListState) f32 {
        if (self.measured) |m| {
            return @constCast(m).totalHeight();
        }
        return @as(f32, @floatFromInt(self.item_count)) * self.props.item_height;
    }

    fn normalizedViewportHeight(self: *const VirtualListState) f32 {
        var vh = self.scroll_state.viewport_height;
        if (!std.math.isFinite(vh) or vh < 0) vh = 0;
        return vh;
    }

    /// Logical scroll position (no rubber-band bonus), used for virtualization
    /// index math. Avoids overscroll animation pushing visible range to wrong
    /// indices, causing "list blank".
    fn normalizedLogicalScrollY(self: *const VirtualListState) f32 {
        const count = self.item_count;
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

    /// Compute visible item range [start, end) from scroll_y
    pub fn visibleRange(self: *const VirtualListState) struct { start: usize, end: usize } {
        const scroll_y = self.normalizedLogicalScrollY();
        const vh = self.normalizedViewportHeight();
        const ih = self.props.item_height;
        const count = self.item_count;
        const overscan = self.props.overscan;

        if (count == 0 or ih <= 0) return .{ .start = 0, .end = 0 };
        if (vh <= 0) {
            return .{ .start = 0, .end = @min(count, overscan + 1) };
        }

        // Dynamic measurement: prefix sum cached, binary-search first item, forward
        // scan to end (O(log n + visible row count)).
        if (self.measured) |m| {
            const r = @constCast(m).range(scroll_y, vh);
            return .{
                .start = r.start -| overscan,
                .end = @min(count, r.end + overscan),
            };
        }

        // Only uniform mode remains: both variable modes hold ledger, returned above.

        // Viewport start item (floor)
        const raw_start_unclamped: usize = if (scroll_y <= 0) 0 else @intFromFloat(@floor(scroll_y / ih));
        const raw_start: usize = @min(raw_start_unclamped, count - 1);
        const start = if (raw_start > overscan) raw_start - overscan else 0;

        // Viewport end item (ceil + overscan)
        const raw_end_f = (scroll_y + vh) / ih;
        const raw_end: usize = if (raw_end_f <= 0) 0 else @min(count, @as(usize, @intFromFloat(@ceil(raw_end_f))));
        var end = @min(count, raw_end + overscan);
        if (end <= start) end = @min(count, start + 1);

        return .{ .start = start, .end = end };
    }

    /// Core: update visible items each frame
    pub fn updateVisibleItems(self: *VirtualListState) void {
        // Dynamic measurement: backfill true item heights from **prior layout** into
        // ledger, then compute geometry. Order is critical—must precede totalContentHeight()
        // or this frame still uses stale heights, spacer and content mismatch, scroll
        // drifts.
        self.collectMeasurements();

        // VirtualList self-manages content height to prevent ScrollArea overwrite
        // causing index/offset mismatch.
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

        // Clamp logical scroll_y first, prevent out-of-bounds index after content
        // height changes.
        const normalized_scroll_y = self.normalizedLogicalScrollY();
        if (normalized_scroll_y != self.scroll_state.scroll_y) {
            self.scroll_state.scroll_y = normalized_scroll_y;
            self.scroll_state.bonus_y = 0;
            self.scroll_state.bonus_velocity = 0;
        }

        // Preserve rubber-band animation but cap VirtualList overshoot, prevent
        // full-screen blank.
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

        // Force-sync content offset (with finite-check fallback), ensure virtualization
        // index matches visual position.
        var effective_y = self.scroll_state.effectiveScrollY();
        if (!std.math.isFinite(effective_y)) {
            self.scroll_state.bonus_y = 0;
            self.scroll_state.bonus_velocity = 0;
            effective_y = self.scroll_state.scroll_y;
        }
        // Quantize to physical pixel grid like scroll event layer, else per-frame
        // sub-pixel translate causes text jitter/blur on Retina.
        const desired_translate_y = -self.scroll_state.snapToPixel(effective_y);
        if (self.content_node.style.translate_y != desired_translate_y) {
            self.content_node.style.translate_y = desired_translate_y;
            self.content_node.markHitLayerMotionPropDirty();
        }

        const range = self.visibleRange();
        const start = range.start;
        const end = range.end;
        const ih = self.props.item_height;

        // Update spacer heights. Variable/measurement mode uses prefix sum, else spacer
        // height and actual content height mismatch, scroll position drifts.
        const variable_geometry = self.hasLedger();
        const top_h = if (variable_geometry)
            self.offsetOf(start)
        else
            @as(f32, @floatFromInt(start)) * ih;
        const bottom_h = if (variable_geometry)
            @max(@as(f32, 0), self.totalContentHeight() - self.offsetOf(end))
        else
            @as(f32, @floatFromInt(self.item_count -| end)) * ih;
        const spacers_changed = !styleHeightEq(self.top_spacer, top_h) or
            !styleHeightEq(self.bottom_spacer, bottom_h);
        self.top_spacer.style.height = .{ .px = top_h };
        self.bottom_spacer.style.height = .{ .px = bottom_h };

        // Callback retry backoff: skip full pass if in wait window (range unchanged),
        // full pass on range change (includes retry).
        const retry_waiting = self.rebind_incomplete and self.render_retry_wait > 0 and
            start == self.prev_start and end == self.prev_end and self.initialized;
        if (retry_waiting) self.render_retry_wait -= 1;
        if (start == self.prev_start and end == self.prev_end and self.initialized and (!self.rebind_incomplete or retry_waiting)) {
            // Visible range unchanged, uniform/pre-known mode done here. But
            // **measurement mode** has one more task: newly-measured rows must lock .fit to
            // px, and if spacer changed, re-layout. Skip this, rows stay .fit, ledger and
            // actual render diverge, scroll drifts.
            if (self.pinMeasuredHeights() or spacers_changed) self.content_node.markLayoutDirty();
            return;
        }

        // Full pass reached: "pending retry" mark from refreshRange (via rebind_incomplete)
        // now honored, clear it. Callback failure this pass re-sets it, merged into
        // rebind_incomplete at pass end.
        self.render_retry_pending = false;

        // Dynamic pool expansion: viewport may be larger after grow layout than at
        // mount estimate
        const needed = end - start;
        var incomplete = false;
        if (needed > self.pool_size) {
            // Safe to degrade: growPool is transactional (inner errdefer rolls back half-built
            // allocations; pool_size / pool_nodes / pool_bindings stay self-consistent). Failing to
            // expand just means fewer visible rows this frame; `findFreeSlot() orelse continue`
            // below
            // handles a missing slot. **Retry next frame** via rebind_incomplete: if the pool can
            // grow
            // (under max_pool_size) but did not grow enough, mark the pass incomplete.
            self.growPool(needed) catch {};
            if (needed > self.pool_size and self.pool_size < max_pool_size) incomplete = true;
        }

        // Reclaim no-longer-visible nodes
        for (self.pool_bindings, 0..) |binding, i| {
            if (binding) |idx| {
                if (idx < start or idx >= end) self.recycleSlot(i);
            }
        }

        // Render items newly in visible range
        var item_idx = start;
        while (item_idx < end) : (item_idx += 1) {
            // Check node already bound to this index
            if (self.isBound(item_idx)) continue;

            // Take free slot from pool; missing means pool short, retry next frame (see
            // rebind_incomplete).
            const slot = self.findFreeSlot() orelse {
                if (self.pool_size < max_pool_size) incomplete = true;
                continue;
            };
            self.pool_bindings[slot] = item_idx;
            const node = self.pool_nodes[slot];
            // Variable height: each slot gets that item's height; uniform gets ih.
            // Measurement mode unmeasured rows get .fit, content expands them.
            self.applySlotHeight(node, item_idx);
            node.style.overflow_hidden = false;
            self.clearSlotNode(node);
            // Tell a11y layer this pool node carries item item_idx: node not in tree,
            // content under that item's cell. Row identity is data, not pool node, rebind
            // doesn't affect VoiceOver cursor (docs/A11Y_ARCHITECTURE.md 12).
            node.behavior.interaction.a11y = .{
                .collection_item = @intCast(@min(item_idx, std.math.maxInt(u32))),
            };
            // Call user render function to populate content
            self.renderSlot(node, item_idx);
            // The row callback may write the slot with any entry (raw or not): invalidate it
            // so no cross-frame cache replays its previous binding.
            node.markRenderDirty();
        }

        // Bound rows must also lock height: rebind_incomplete spans several frames of
        // full passes, lock can't defer (cross-review noted "stalled incomplete delays
        // locking indefinitely").
        _ = self.pinMeasuredHeights();

        // Reorder pool nodes in content by data index. Failure (OOM) leaves order old:
        // new slots after bottom_spacer, visible rows misaligned, must re-do next frame.
        if (!self.reorderPoolNodes()) incomplete = true;

        self.prev_start = start;
        self.prev_end = end;
        self.initialized = true;
        // Callback incomplete this pass -> force full pass next frame (index now unbound,
        // re-slot and re-call). Interval backoff per failure streak: 1,3,7,15,31,60 frames
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

    // -- a11y semantic collection (a11y/collection.zig Provider) --

    fn a11yProvider(self: *VirtualListState) a11y_collection.Provider {
        return .{ .ctx = self, .vtable = &a11y_vtable };
    }

    const a11y_vtable = a11y_collection.Provider.VTable{
        .count = a11yCount,
        .data_generation = a11yGeneration,
        .viewport = a11yViewport,
        .content_size = a11yContentSize,
        .item_rect = a11yItemRect,
        .index_at = a11yIndexAt,
        .scroll_offset = a11yScrollOffset,
        .apply_scroll = a11yApplyScroll,
        .label = a11yLabel,
    };

    fn fromCtx(ctx: *anyopaque) *VirtualListState {
        return @ptrCast(@alignCast(ctx));
    }

    fn a11yCount(ctx: *anyopaque) u32 {
        return @intCast(@min(fromCtx(ctx).item_count, std.math.maxInt(u32)));
    }

    fn a11yGeneration(ctx: *anyopaque) u64 {
        return fromCtx(ctx).a11y_generation;
    }

    /// Viewport = container minus padding. Content starts at (0,0) in viewport,
    /// shifted up by scroll_y.
    fn a11yViewport(ctx: *anyopaque) a11y_collection.Rect {
        const self = fromCtx(ctx);
        const r = self.container_node.globalRect();
        const pad = self.container_node.style.contentInsets();
        return .{
            .x = r.x + pad.left,
            .y = r.y + pad.top,
            .w = @max(0, r.w - pad.horizontal()),
            .h = self.normalizedViewportHeight(),
        };
    }

    fn a11yContentSize(ctx: *anyopaque) a11y_collection.Size {
        const self = fromCtx(ctx);
        return .{ .w = a11yViewport(ctx).w, .h = self.totalContentHeight() };
    }

    fn a11yItemRect(ctx: *anyopaque, index: u32) a11y_collection.Rect {
        const self = fromCtx(ctx);
        return .{
            .x = 0,
            .y = self.offsetOf(index),
            .w = a11yViewport(ctx).w,
            .h = self.itemHeight(index),
        };
    }

    fn a11yIndexAt(ctx: *anyopaque, y: f32) ?u32 {
        const self = fromCtx(ctx);
        const count = self.item_count;
        if (count == 0 or !std.math.isFinite(y) or y < 0) return null;
        if (y >= self.totalContentHeight()) return null;
        // Binary search prefix sum: first item whose bottom exceeds y. Uniform mode
        // offsetOf is multiply, same applies.
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.offsetOf(mid + 1) <= y) lo = mid + 1 else hi = mid;
        }
        return @intCast(@min(lo, count - 1));
    }

    fn a11yScrollOffset(ctx: *anyopaque) f32 {
        return fromCtx(ctx).scroll_state.scroll_y;
    }

    /// Pump-safe call: snap to offset (native scrollRowToVisible has no animation).
    fn a11yApplyScroll(ctx: *anyopaque, offset: f32) void {
        const self = fromCtx(ctx);
        scroll_area.setScrollY(self.scroll_state, self.content_node, offset);
        self.content_node.markLayoutDirty();
    }

    fn a11yLabel(ctx: *anyopaque, index: u32, buf: []u8) []const u8 {
        const self = fromCtx(ctx);
        const f = self.props.item_label_fn orelse return "";
        const user = self.props.item_label_context orelse self.render_user_context;
        return f(index, buf, user);
    }

    /// Unbind a slot: hide, clear subtree, exit a11y tree. Shared path for scroll-
    /// out and render-failure reclaim.
    fn recycleSlot(self: *VirtualListState, slot: usize) void {
        const node = self.pool_nodes[slot];
        node.style.height = .{ .px = 0 };
        node.style.overflow_hidden = true;
        // Slot-level container reused, but item-level subtree and identity must clear
        // on unbind, else hidden slot continues exposing stale children/test_id.
        self.clearSlotNode(node);
        node.meta.ownership.meta.test_id = null;
        // Slot must exit a11y tree post-unbind (a11y=null + unfocusable when projection
        // layer drops). Else reclaimed hidden rows linger in tree as listitems, AT sees
        // bunch of stale offscreen content.
        node.behavior.interaction.a11y = null;
        self.pool_bindings[slot] = null;
    }

    /// Mark render failure: accept only current bound pool node; post-unbind this
    /// pass marks incomplete.
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

    /// Measurement mode: lock already-measured bound rows from .fit to px. Return
    /// whether any locked.
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

    /// Dynamic measurement: backfill true heights from the prior layout into the ledger.
    ///
    /// Timing (premise of the feature): frame flow is `layout -> tick (before_render hooks) ->
    /// re-layout if a hook marked dirty`. This runs in the hook, so rect comes from the **first**
    /// layout of the frame, i.e. true content height after .fit expansion. Backfill then marks
    /// dirty and the second layout in the same frame uses corrected geometry, with no
    /// "wrong for one frame then jump" flicker.
    fn collectMeasurements(self: *VirtualListState) void {
        // `item_height_fn` mode also holds ledger (for prefix cache + binary search),
        // but its heights are **caller-provided authority**, can't be overwritten by
        // layout measurement.
        if (!self.isMeasured()) return;
        const m = self.measured orelse return;

        // Scroll direction: re-measure anchor needs it (suppress compensation when
        // scrolling up, avoid cascading shift).
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
            // h <= 0 = row not yet laid out (bound this frame). Don't treat as "measured
            // to 0" in ledger, or row locks to 0 height permanently and never re-measures.
            if (!(h > 0)) continue;

            const out = m.applyMeasurement(idx, h, cur_y, self.scroll_direction);
            total_adjust += out.scroll_adjustment;
        }

        if (total_adjust != 0) {
            // Compensation must happen **atomically** with this frame's geometry rebuild:
            // scroll_y and prefix sum update together in frame, user sees one consistent
            // frame.
            const max_scroll = @max(@as(f32, 0), m.totalHeight() - self.normalizedViewportHeight());
            const adjusted = std.math.clamp(cur_y + total_adjust, 0, max_scroll);
            self.scroll_state.scroll_y = adjusted;
            self.prev_scroll_y = adjusted;
            // Compensation is "correction" not "scroll": don't leave momentum/bounce, else
            // inertia amplifies it.
            self.scroll_state.bonus_y = 0;
            self.scroll_state.bonus_velocity = 0;
        }
        m.consumeAdjustment();
    }

    /// Slot height: measurement mode lets content expand (.fit), then locks to the measured value.
    ///
    /// Lock to px after measuring rather than keep .fit: the locked height is determinate for
    /// layout and strictly matches the ledger; a perpetual .fit makes the ledger and the actual
    /// render compute separately, so spacer and content height mismatch and scroll drifts.
    fn applySlotHeight(self: *VirtualListState, node: *Node, index: usize) void {
        // Criterion must be isMeasured, not `measured != null`: `item_height_fn` mode also holds a
        // ledger (for prefix sum + binary search) but never writes sizes, so hasMeasurement() is
        // always false. Using `measured != null` would make **every row** .fit, height set by
        // content while the ledger reserves space per callback (e.g. 40px reserved, 10px rendered).
        if (self.isMeasured()) {
            const m = self.measured.?;
            if (m.hasMeasurement(index)) {
                node.style.height = .{ .px = m.sizeOf(index) };
            } else {
                // Never measured: let content set height, read true value post-layout.
                node.style.height = .{ .fit = .{} };
            }
            return;
        }
        // Uniform + item_height_fn: height is known authority, lock directly.
        node.style.height = .{ .px = self.itemHeight(index) };
    }

    /// Reclaim slot must destroy old subtree, prevent user render only resetting
    /// children.len from leaking.
    /// Populate a (cleared) pool slot through the list's render callback.
    fn renderSlot(self: *VirtualListState, node: *Node, index: usize) void {
        switch (self.render) {
            .plain => |f| f(node, index, self.cx),
            .with_context => |f| f(node, index, self.cx, self.render_user_context),
            .scoped => |f| f(node, index, self.scope, self.cx, self.render_user_context),
        }
    }

    fn clearSlotNode(self: *VirtualListState, node: *Node) void {
        while (node.children.items.len > 0) {
            const child = node.children.items[node.children.items.len - 1];
            self.cx.detachChild(node, child);
            self.cx.freeNode(child);
        }
        node.markRuntimeIndexDirty();
    }

    /// Expand pool to new_size (triggered when actual viewport exceeds mount estimate)
    fn growPool(self: *VirtualListState, new_size: usize) !void {
        const target = @min(max_pool_size, new_size + 2); // margin of 2
        if (target <= self.pool_size) return;
        const old_size = self.pool_size;

        const new_nodes = try self.allocator.alloc(*Node, target);
        errdefer self.allocator.free(new_nodes);
        const new_bindings = try self.allocator.alloc(?usize, target);
        errdefer self.allocator.free(new_bindings);

        // Copy old pool
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

        // Initialize new slots as idle/hidden nodes
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

        // Free old array
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

    /// Reorder pool nodes in content.children by data index. All pool nodes (hidden ones
    /// included) always stay in children so destroy does not leak. Fails (OOM) -> order
    /// stale: new slots after bottom_spacer, visible rows misaligned, must re-do
    /// next frame. False = order unsettled (allocation failed), caller arranges
    /// retry.
    fn reorderPoolNodes(self: *VirtualListState) bool {
        const content = self.content_node;

        // Collect valid bound (data_index, pool_slot) pairs
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

        // Sort by data_index (insertion sort, small count)
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

        // Rebuild children: [top_spacer, active_items_sorted, inactive_items, bottom_spacer].
        // All pool nodes always in children so content.destroy() recursively destroys them.
        var ordered_nodes = @as(std.ArrayList(*Node), .empty);
        defer ordered_nodes.deinit(self.allocator);
        ordered_nodes.ensureTotalCapacity(self.allocator, self.pool_size + 2) catch return false;
        ordered_nodes.appendAssumeCapacity(self.top_spacer);

        // Add active nodes first (sorted by data index)
        var active_set: [max_pool_size]bool = @as([max_pool_size]bool, @splat(false));
        for (pairs) |pair| {
            ordered_nodes.appendAssumeCapacity(self.pool_nodes[pair.pool_slot]);
            if (pair.pool_slot < max_pool_size) active_set[pair.pool_slot] = true;
        }
        // Then add inactive nodes (height 0, no layout impact)
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

/// Whether node's current style height is already `want` pixels.
/// .fit / .grow treated as "not equal", they haven't locked to a value yet.
fn styleHeightEq(node: *const Node, want: f32) bool {
    return switch (node.style.height) {
        .px => |v| v == want,
        else => false,
    };
}

pub const max_pool_size = 256;

/// Result of `VirtualListBuilder.rows`: integrated via `viewMount` into ui.view.
pub fn VirtualListRows(comptime Ctx: type, comptime row_fn: anytype) type {
    const what = "VirtualList.rows";
    _ = view.callbackIsComponent(@TypeOf(row_fn), if (Ctx == void) 1 else 2, what);
    return struct {
        builder: VirtualListBuilder,
        ctx: Ctx,

        const Self = @This();
        const State = view.CallbackState(Ctx);

        pub fn viewMount(self: Self, scope: *Scope, cx: *Cx) !core.ViewParts {
            const st = try State.create(scope, self.ctx);
            const r = try self.builder.mountScoped(scope, cx, @ptrCast(st), render);
            return .{ .root = r.container };
        }

        /// Row scopes open under the list's own scope (`list_scope`), not the caller's: freeing
        /// the list container retires every bound row with it.
        fn render(node: *Node, index: usize, list_scope: *Scope, cx: *Cx, user: ?*anyopaque) void {
            const st: *State = @ptrCast(@alignCast(user.?));
            view.renderInto(list_scope, cx, node, row_fn, st.ctx, .{index}, what) catch {
                _ = markPoolNodeRenderIncomplete(node);
            };
        }
    };
}

/// Create VirtualList: `W.VirtualList(.{ .item_count = rows_len, .item_height = 28 }).mount(scope,
/// cx, render)`
pub fn VirtualList(props: anytype) VirtualListBuilder {
    return .{ .props = reactive.props.coerce(VirtualListProps, props) };
}

pub const VirtualListBuilder = struct {
    props: VirtualListProps,

    /// ui.view integration: the row function returns a view element, usable directly as a ui.view
    /// child: `W.VirtualList(.{ .item_count = n, .item_height = 32 }).rows(ctx, row)`.
    /// Row function: `fn (Ctx, usize) E` / `fn (usize) E` (ctx = `{}`), or component form
    /// `fn (Ctx, usize, *Scope, *Cx) !*Node`. Each row gets its own subscope bound to the row
    /// root: when the row scrolls out (freeNode), the subscope's effects are destroyed with it.
    pub fn rows(self: VirtualListBuilder, ctx: anytype, comptime row_fn: anytype) VirtualListRows(@TypeOf(ctx), row_fn) {
        return .{ .builder = self, .ctx = ctx };
    }

    const MountResult = struct { container: *Node, state: *VirtualListState };

    /// Retained-mode mount: create VirtualList and return container node + state handle
    ///
    /// render_fn: user-provided item render callback, invoked each time item enters visible range
    pub fn mount(
        self: VirtualListBuilder,
        scope: *Scope,
        cx: *Cx,
        render_fn: RenderItemFn,
    ) !MountResult {
        return self.mountWithContext(scope, cx, null, render_fn, null);
    }

    /// Mount with context: for render function needing external state access
    pub fn mountWithContext(
        self: VirtualListBuilder,
        scope: *Scope,
        cx: *Cx,
        user_context: ?*anyopaque,
        render_fn: ?RenderItemFn,
        render_with_context_fn: ?RenderItemWithContextFn,
    ) !MountResult {
        const render: RenderCallback = if (render_with_context_fn) |f| .{ .with_context = f } else .{ .plain = render_fn orelse noopRenderItem };
        return self.mountImpl(scope, cx, user_context, render);
    }

    /// Mount with a scoped render callback: the callback receives the list's own scope, which
    /// owns the slots. Use it whenever slot content carries scope-owned state (effects, signal
    /// subscriptions, resources), so that state is retired with the list as well as with the slot.
    pub fn mountScoped(
        self: VirtualListBuilder,
        scope: *Scope,
        cx: *Cx,
        user_context: ?*anyopaque,
        render_fn: RenderItemScopedFn,
    ) !MountResult {
        return self.mountImpl(scope, cx, user_context, .{ .scoped = render_fn });
    }

    fn mountImpl(
        self: VirtualListBuilder,
        scope: *Scope,
        cx: *Cx,
        user_context: ?*anyopaque,
        render: RenderCallback,
    ) !MountResult {
        const my_scope = try scope.childScope();
        errdefer my_scope.dispose();
        var resources_owned = false;
        const allocator = cx.allocator;
        const p = self.props;
        reactive.checkBorrow(scope, p.item_count);
        reactive.checkBorrow(scope, p.data_version);
        const count0 = p.item_count.peek();

        // Ledger is built for both variable-height modes:
        //   measure_items -> estimate + backfill after layout
        //   item_height_fn -> height known, used directly as estimate_fn, never backfilled
        // The latter is not for "measurement" but to get Measurements' **prefix cache + binary
        // search**; a per-frame O(n) linear scan would time out on 5000+ row diffs scrolled deep.
        const use_measured = p.measure_items or p.item_height_fn != null;
        const measured: ?*Measurements = if (use_measured) blk: {
            const m = try my_scope.allocator.create(Measurements);
            m.* = Measurements.init(allocator, .{
                .count = count0,
                .estimate = p.estimate_item_height,
                .estimate_fn = p.item_height_fn,
                .estimate_ctx = p.item_height_context,
                .key_fn = p.item_key_fn,
                // key_ctx defaults to render's user_context if unset, saves caller passing same
                // context twice.
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

        // Compute total content height. Measurement mode initially placeholders with
        // estimates, converges as true values measured.
        const total_h = if (measured) |m|
            m.totalHeight()
        else
            @as(f32, @floatFromInt(count0)) * p.item_height;

        // Use ScrollArea as outer container (reuse scroll physics)
        const sa = try scroll_area.ScrollArea(.{
            .width = p.width,
            .height = p.height,
            .direction = p.scroll_direction,
            .content_height = total_h,
            .content_width = p.content_width,
            .scroll_speed = p.scroll_speed,
            .padding = p.padding,
            .background = p.background,
        }).mount(my_scope, cx);

        errdefer cx.freeNode(sa.container);

        sa.container.meta.ownership.meta.component_name = "VirtualList";
        // a11y: container inferred as AXScrollArea from scroll container; content node
        // after state setup declared as table (semantic collection, see content a11y below).

        // Extract ScrollState from ScrollArea's event_context
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

        // Create top/bottom spacer (pool nodes appended after them, see pre-create below)
        var top_spacer: *Node = undefined;
        var bottom_spacer: *Node = undefined;
        try view.mount(my_scope, cx, sa.content, .{
            view.capture(&top_spacer, view.box(.{ .style = core.BoxStyle{
                .width = .{ .grow = .{} },
                .height = .{ .px = 0 },
                .flex_shrink = 0,
            } }, {})),
            view.capture(&bottom_spacer, view.box(.{ .style = core.BoxStyle{
                .width = .{ .grow = .{} },
                .height = .{ .px = total_h },
                .flex_shrink = 0,
            } }, {})),
        });
        top_spacer.frame_state.state_bits.flags.inspectable = false;
        bottom_spacer.frame_state.state_bits.flags.inspectable = false;

        // Compute pool size: how many rows fit in viewport + 2*overscan + buffer.
        // Measurement mode uses estimate, true heights often smaller so pool might grow, but
        // growPool expands to actual need on first frame, this just a reasonable start.
        const viewport_h = p.height orelse 400;
        // item_height = 0 / negative / NaN -> division gives inf, @intFromFloat panics directly:
        // both branches clamp to >= 1.
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

        // Allocate node pool
        const pool_nodes = try allocator.alloc(*Node, pool_size);
        errdefer if (!resources_owned) allocator.free(pool_nodes);
        const pool_bindings = try allocator.alloc(?usize, pool_size);
        errdefer if (!resources_owned) allocator.free(pool_bindings);
        @memset(pool_bindings, null);

        // Pre-create item nodes in pool (initially hidden, added to content for correct
        // parent + no leak on destroy)
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

        // Allocate VirtualListState (lifecycle managed via Scope)
        const state = try my_scope.allocator.create(VirtualListState);
        errdefer if (!resources_owned) my_scope.allocator.destroy(state);
        state.* = .{
            .props = p,
            .item_count = count0,
            .shown_version = p.data_version.peek(),
            .render = render,
            .render_user_context = user_context,
            .scope = my_scope,
            .cx = cx,
            .scroll_state = scroll_state_ptr,
            .container_node = sa.container,
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
                // Measurement ledger holds its own HashMap and prefix array, must deinit before
                // destroy or leak (they use cx.allocator, not scope-tracked).
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

        // Row count / data_version when dynamic source: effect-driven (first run same as
        // snapshot, no-op). Must build before scope binding below: no failing steps after binding.
        if (!p.item_count.isStatic() or !p.data_version.isStatic()) {
            try my_scope.createEffect(state, VirtualListState.sourceEffect);
        }

        // Retire the whole list scope when its container is freed, including
        // the nested ScrollArea scope. No fallible work follows this binding.
        try core.bindScopeToNode(my_scope, sa.container);

        // Store VirtualListState pointer in content.hooks.slots.anim_state (content node
        // doesn't use animation, field safe). Must attach **before** initial render, callback
        // may call markPoolNodeRenderIncomplete(node) within first pass to backtrack parent for
        // state.
        sa.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
        // Update visible items each frame in content's on_before_render (hook only runs in
        // frame tick, attach early is no-op; markPoolNodeRenderIncomplete uses it for identity
        // check).
        sa.content.meta.per_frame.hooks.before_render.main = vlBeforeRender;
        // The hook only moves `content` (translate), resizes spacers/slots (layout-dirty) and
        // rebinds pool slots, and every rebound slot is marked render-dirty after the row callback
        // ran (updateVisibleItems / refreshRange), so whatever the callback wrote is never replayed stale. Rows
        // that stay bound are untouched and reusable across frames while scrolling.
        sa.content.frame_state.state_bits.flags.before_render_hook_descendants_cache_safe = true;

        // Semantic collection: content node as table exposes all data rows to assistive tech
        // (AXTable > AXRow > AXCell), decoupled from pool rendering. Collection bound to content,
        // unregistered by framework on node release; state released same scope, outlives content.
        sa.content.behavior.interaction.a11y = .{
            .role = .grid,
            .collection = state.a11yProvider(),
        };

        // Initial render of visible items
        state.updateVisibleItems();

        return .{ .container = sa.container, .state = state };
    }
};

fn noopRenderItem(_: *Node, _: usize, _: *Cx) void {}

/// content node's on_before_render callback
fn vlBeforeRender(content_node: *Node) void {
    if (content_node.meta.per_frame.hooks.slots.anim_state) |ptr| {
        const state: *VirtualListState = @ptrCast(@alignCast(ptr));
        state.updateVisibleItems();
    }
}

/// Update item_count (call when data source changes)
pub fn updateItemCount(state: *VirtualListState, new_count: usize) void {
    state.item_count = new_count;
    // Contract is "call when data source changes": AT side row identity advances era.
    state.a11y_generation +%= 1;
    // Sync ledger row count. Note setCount **doesn't clear measurements**, they key-
    // domain, changing row count keeps old key heights valid (especially important with
    // item_key_fn: head insert won't re-measure tail).
    if (state.measured) |m| {
        m.setCount(new_count);
        // setCount exits early if count is unchanged, leaving pending_min and the prefix cache
        // stale.
        // But the contract is "call when data changes", and same-count data changes are common
        // (switch to same-row file, toggle side-by-side/inline), where item_height_fn return values
        // likely change too. Skipping the unconditional mark-dirty makes itemHeight() read the live
        // callback while offsetOf() reads the stale cache, so geometry self-contradicts
        // (e.g. itemHeight=100 but offsetOf(1)=40: rows overlap, scrollbar 2.5x short).
        m.markAllDirty();
    }
    syncContentHeight(state);
    // Reset: force recalc next frame
    state.prev_start = 0;
    state.prev_end = 0;
    state.initialized = false;
    // Reclaim all nodes, critical: **also clear children**, else caller-external item
    // state (e.g., item.label string in completion popup) changed/freed, old children's
    // text.content dangles -> crash on next layout/hit test.
    for (state.pool_bindings, 0..) |_, i| {
        state.pool_bindings[i] = null;
        state.clearSlotNode(state.pool_nodes[i]);
        state.pool_nodes[i].style.height = .{ .px = 0 };
        state.pool_nodes[i].style.overflow_hidden = true;
    }
    state.content_node.markLayoutDirty();
}

/// Scroll to index (item top aligns viewport top)
pub fn scrollToIndex(state: *VirtualListState, index: usize) void {
    const target_y = state.offsetOf(index);
    // Unified via scroll_area's programmatic scroll entry: clamp + momentum/bounce
    // reset + pixel snap (previously hand-written here, missed snapToPixel + bounce cancel).
    scroll_area.setScrollY(state.scroll_state, state.content_node, target_y);
}

/// Scroll item at index into view per alignment mode (scroll_area.ScrollAlign semantics).
pub fn scrollIndexIntoView(
    state: *VirtualListState,
    index: usize,
    alignment: scroll_area.ScrollAlign,
) void {
    const top = state.offsetOf(index);
    const ih = state.itemHeight(index);
    scroll_area.scrollRectIntoView(state.scroll_state, state.content_node, top, ih, alignment);
}

/// Call after `item_height_fn` return values change so geometry catches up.
///
/// Why explicit: the ledger **caches** prefix sums, the callback doesn't. When the caller
/// changes return values (expand/collapse blocks, toggle side-by-side/inline, resize font),
/// the ledger cannot know. Without the call itemHeight() reads the live callback while
/// offsetOf() / totalContentHeight() read the stale cache, so geometry self-contradicts
/// (holes or overlaps between rows).
///
/// Only invalidates derived prefix sums, not measurements, so it is safe in `measure_items`
/// mode too (usually unneeded there, backfill marks dirty itself).
pub fn invalidateHeights(state: *VirtualListState) void {
    const m = state.measured orelse return;
    m.markAllDirty();
    // Bound slots previously locked to **old** height, must update together, else ledger
    // changed but rows still draw old height. Uniform mode unaffected (doesn't lock px).
    for (state.pool_bindings, 0..) |binding, slot| {
        const idx = binding orelse continue;
        state.applySlotHeight(state.pool_nodes[slot], idx);
        state.pool_nodes[slot].markLayoutDirty();
    }
    // **No need** to reset prev_start/prev_end/initialized here. visibleRange() recalculates each
    // frame from the ledger and the updateVisibleItems early exit compares the new range with prev,
    // so a truly changed range never hits the early exit (100px->40px, 100 rows: without reset
    // [0,2) still expands to [0,5) and binds 5). A reset would be dead code that misleads about
    // what state must be maintained.
    syncContentHeight(state);
}

/// Three things must sync after total height changes: ScrollState content_height, the content
/// node style height, and clamping of out-of-bounds scroll_y.
///
/// Extracted because **omitting it is irreversible**: scrollToIndex / ensureVisible call the
/// scroll_area clamp, which uses maxScrollY() derived from content_height. If height grew but
/// content_height is stale, the target is clamped to the old max; next frame
/// updateVisibleItems fixes content_height but the **request is already lost**, so the list
/// stays on the wrong row (wanted row 90, landed row 38).
///
/// updateItemCount and invalidateHeights both change total height and share this logic.
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

/// Invalidate the measured height of the row at index; it is re-measured next frame.
///
/// When content gets taller/shorter (text changed, detail expanded) this must be called, or the
/// row reuses the old measurement forever, ledger and content diverge, and all following rows
/// are offset. `refreshRange` already calls it; call manually only when modifying content
/// directly, bypassing refreshRange.
pub fn invalidateMeasurement(state: *VirtualListState, index: usize) void {
    // Criteria must be isMeasured not `measured != null`: `item_height_fn` mode also
    // holds ledger, but its row heights are caller-authority. Resetting those to .fit lets
    // content decide height, and no path in that mode re-locks them, row stays perpetually at
    // content height, vs ledger allocation (measured: ledger 40px, actual render 10px).
    if (!state.isMeasured()) return;
    const m = state.measured orelse return;
    m.invalidate(index);
    // Row back to estimate mode, slot height also back to .fit to be re-expanded by
    // content.
    for (state.pool_bindings, 0..) |binding, slot| {
        if (binding == index) {
            state.pool_nodes[slot].style.height = .{ .fit = .{} };
            state.pool_nodes[slot].markLayoutDirty();
        }
    }
    state.content_node.markLayoutDirty();
}

/// Discard all measurements, whole table back to estimate (when data source fully
/// replaces).
pub fn invalidateAllMeasurements(state: *VirtualListState) void {
    // Same as invalidateMeasurement: only backfill-measurement mode should reset to .fit.
    // item_height_fn mode wanting geometry to track callback's new value uses
    // invalidateHeights().
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

/// Call when the render callback fails: `fn render(node, index, cx, ctx) void` cannot reach
/// state, so backtrack via the pool node's parent (content node). Returns false = not this
/// VL's current bound pool node. Effect: the slot unbinds immediately (half subtree cleared,
/// leaves a11y tree); next frame re-slots and re-calls for the same index. Continuous failure
/// means continuous retry (once per frame, no ceiling; a ceiling would freeze a half row).
pub fn markPoolNodeRenderIncomplete(node: *Node) bool {
    const content = node.parent orelse return false;
    // Identity check before type cast: only nodes with vlBeforeRender attached have
    // anim_state as *VirtualListState
    const hook = content.meta.per_frame.hooks.before_render.main orelse return false;
    if (hook != vlBeforeRender) return false;
    const ptr = content.meta.per_frame.hooks.slots.anim_state orelse return false;
    const state: *VirtualListState = @ptrCast(@alignCast(ptr));
    if (state.content_node != content) return false;
    return state.markSlotRenderIncomplete(node);
}

/// Whether `node` is a VirtualList's content node: its children (spacers and pool slots) are the
/// per-frame projection of the visible rows, re-derived by every pass. A row that failed to
/// render (OOM in the callback, pool growth or reordering) is unbound and retried by a later
/// pass rather than failing the mount (see `markPoolNodeRenderIncomplete`); test support
/// comparing mounts (oom_sweep) treats this subtree accordingly.
pub fn isVirtualContent(node: *const Node) bool {
    const hook = node.meta.per_frame.hooks.before_render.main orelse return false;
    return hook == vlBeforeRender;
}

/// Refresh bound items in range (row count unchanged, content may change)
pub fn refreshRange(state: *VirtualListState, start: usize, end: usize) void {
    for (state.pool_bindings, 0..) |binding, slot| {
        if (binding) |idx| {
            if (idx >= start and idx < end) {
                // Content to re-render -> old measurements no longer trusted, back to .fit
                // re-measure.
                // Backfill-measurement mode only: `item_height_fn` mode rows have caller-provided
                // heights,
                // resetting to .fit lets content decide height, and that mode's collectMeasurements
                // returns
                // directly, no one re-locks them.
                if (state.isMeasured()) {
                    state.measured.?.invalidate(idx);
                    state.pool_nodes[slot].style.height = .{ .fit = .{} };
                }
                state.clearSlotNode(state.pool_nodes[slot]);
                state.renderSlot(state.pool_nodes[slot], idx);
                // Content changed -> rect often unchanged: skip mark-dirty -> damage-tracking
                // renderer
                // won't redraw, IME input shows no text but cursor advances (cursor/selection
                // self-dirty
                // each frame).
                state.pool_nodes[slot].markLayoutDirty();
                state.pool_nodes[slot].markRenderDirty();
            }
        }
    }
}

/// Ensure index visible (no scroll if already in range)
pub fn ensureVisible(state: *VirtualListState, index: usize) void {
    scrollIndexIntoView(state, index, .nearest);
}

// ========== Testing ==========

const testing = std.testing;

test {
    // Zig won't collect submodule tests from `@import` alone, must reference explicitly.
    // Miss this, measurements.zig geometry tests won't run in `zig build test`, output looks
    // green (repo hit this pit).
    testing.refAllDecls(@This());
    _ = measurements;
}

test "VirtualList: item_height = 0 / 负数时 mount 不 panic" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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
    // Variable-height mode: item i has height (10 + i*10), i.e., 10/20/30/40/50...
    // Assertion here is "geometry self-consistent": total height, prefix sums, visible range
    // must come from same heights, else spacer height != content actual height, scroll drifts.
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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
        .item_height = 32, // shouldn't be used in variable-height mode
        .width = 300,
        .height = 100,
        .overscan = 0,
        .item_height_fn = heights,
    }).mount(scope, ctx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    try root.appendChild(allocator, result.container);

    const st = result.state;
    // 10+20+30+40+50 = 150, not 5*32=160.
    try testing.expectEqual(@as(f32, 150), st.totalContentHeight());
    try testing.expectEqual(@as(f32, 0), st.offsetOf(0));
    try testing.expectEqual(@as(f32, 10), st.offsetOf(1));
    try testing.expectEqual(@as(f32, 60), st.offsetOf(3)); // 10+20+30
    try testing.expectEqual(@as(f32, 30), st.itemHeight(2));

    // Viewport 100px, scroll 0: should cover items up to cumulative height >= 100.
    st.scroll_state.viewport_height = 100;
    st.scroll_state.scroll_y = 0;
    const r0 = st.visibleRange();
    try testing.expectEqual(@as(usize, 0), r0.start);
    try testing.expect(r0.end >= 4); // 10+20+30+40=100

    // Scroll to item 2 top (30): start item must be exactly 2. Uniform calc (32) would give
    // 0, this is what variable path fixes. Note viewport 100 / total 150 -> max_scroll=50,
    // taking 30 not clamped.
    st.scroll_state.scroll_y = 30;
    const r1 = st.visibleRange();
    try testing.expectEqual(@as(usize, 2), r1.start);

    // Out-of-bounds scroll_y clamped to max_scroll(=50), lands in item 2's [30,60).
    st.scroll_state.scroll_y = 9999;
    try testing.expectEqual(@as(usize, 2), st.visibleRange().start);
}

/// Measurement mode integration fixture: each row renders **fixed-height** child,
/// height by index (simulates "content decides height"). Component doesn't know upfront,
/// must measure via layout.
const MeasuredFixture = struct {
    /// Row i's true content height: 10 / 60 / 10 / 60 ...
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
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 100,
        .measure_items = true,
        .estimate_item_height = 20, // deliberately mis-estimate: true is 10/60 alternating
        .width = 300,
        .height = 200,
        .overscan = 1,
    }).mount(scope, ctx, MeasuredFixture.render);
    try root.appendChild(allocator, result.container);
    const st = result.state;

    // No frame run yet: all estimate -> 100 * 20 = 2000.
    try testing.expect(st.isMeasured());
    try testing.expectEqual(@as(f32, 2000), st.totalContentHeight());

    // Run frames: layout expands .fit -> hook reads true height -> mark dirty -> re-layout.
    st.scroll_state.viewport_height = 200;
    var frame: usize = 0;
    while (frame < 5) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    // Visible rows must already measure to true value (not estimate 20).
    try testing.expect(st.measured.?.hasMeasurement(0));
    try testing.expectApproxEqAbs(@as(f32, 10), st.itemHeight(0), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 60), st.itemHeight(1), 0.5);

    // Total = measured rows' true + unmeasured rows' estimate, must be < "all 20 estimate"
    // 2000? Not necessarily, true avg 35 > estimate 20, total should **grow**. Key is it's not
    // pure-estimate, and measured part exact.
    try testing.expect(st.totalContentHeight() != 2000);
    try testing.expectApproxEqAbs(@as(f32, 0), st.offsetOf(0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), st.offsetOf(1), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 70), st.offsetOf(2), 0.5);
}

test "VirtualList measured: measured rows pin their slot height to px" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // After measuring, slot must lock .fit to px, perpetual .fit means ledger and actual
    // diverge, spacer height != content height.
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
    // Spacer is virtualization foundation: top_spacer must equal sum of [0,start),
    // bottom_spacer equal sum of [end,count). Off by 1 pixel, scroll drifts by 1.
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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
    // Scroll to mid then run frames.
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
    // This is where dynamic height easiest to fail + most impacts feel: when rows above
    // change from estimate to true height, scroll_y not compensated -> user's viewed content
    // bounces around.
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Jump directly to mid (above is all estimate height).
    st.scroll_state.scroll_y = 1000;
    ctx.layout();
    st.updateVisibleItems();

    // Note which row is at viewport top, record its offset from top.
    const anchor_index = st.visibleRange().start + 1;
    const before_delta = st.offsetOf(anchor_index) - st.scroll_state.scroll_y;

    // Keep running frames, let visible rows measure one by one (height 20 -> 10/60).
    var frame: usize = 0;
    while (frame < 6) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }

    // Anchor works if that row's position relative to viewport top **unchanged**.
    //
    // Tolerance must tighten to 1px, measured (compensation off as control) drift was 10px,
    // loose tolerance (e.g., 40px) passes "compensation didn't work at all", test becomes useless.
    const after_delta = st.offsetOf(anchor_index) - st.scroll_state.scroll_y;
    try testing.expectApproxEqAbs(before_delta, after_delta, 1.0);

    // Compensation direction also matters: rows above grow overall (estimate 20 ->
    // true avg 35), scroll_y must **increase too**, else "position didn't move" might just be
    // nothing happened.
    try testing.expect(st.scroll_state.scroll_y > 1000);
}

test "VirtualList measured: refreshRange invalidates stale measurements" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Content changed -> old measurement must invalidate, row height reused forever.
    refreshRange(st, 0, 5);
    try testing.expect(!st.measured.?.hasMeasurement(1));

    // Next frame run should re-measure back.
    frame = 0;
    while (frame < 4) : (frame += 1) {
        ctx.layout();
        st.updateVisibleItems();
    }
    try testing.expect(st.measured.?.hasMeasurement(1));
}

test "VirtualList measured: updateItemCount keeps measurements and is leak-free" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Row count change shouldn't clear measurements (they key-domain).
    updateItemCount(st, 60);
    try testing.expectEqual(@as(usize, 60), st.measured.?.opts.count);
    try testing.expectApproxEqAbs(h1, st.itemHeight(1), 0.01);

    // Shrink equally safe (prefix table rebuilds, can't read stale tail).
    updateItemCount(st, 5);
    try testing.expectEqual(@as(usize, 5), st.measured.?.opts.count);
    _ = st.totalContentHeight();
}

test "VirtualList: item_height_fn uses the ledger (prefix sums + binary search)" {
    // item_height_fn also holds ledger, for O(log n) locate not O(n) linear scan per
    // frame. Diffs 5000+ rows scrolled deep, linear scan hits RPC timeout.
    //
    // Asserts "ledger exists and geometry from it", not timing directly: time asserts
    // flaky in CI, ledger existence binary, reliably turns red.
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try VirtualList(.{
        .item_count = 1000,
        .item_height = 32, // shouldn't be used
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
    // Has ledger, but not backfill-measurement mode.
    try testing.expect(st.hasLedger());
    try testing.expect(!st.isMeasured());

    // Geometry from item_height_fn: 500 pairs (20+28) = 24000.
    try testing.expectApproxEqAbs(@as(f32, 24000), st.totalContentHeight(), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 48), st.offsetOf(2), 0.01);
    try testing.expectEqual(@as(f32, 20), st.itemHeight(0));
    try testing.expectEqual(@as(f32, 28), st.itemHeight(1));

    // Positioning deep must be accurate (this is where linear scan drags, binary search
    // guarantees).
    st.scroll_state.viewport_height = 200;
    st.scroll_state.scroll_y = 12000; // exactly item 500 top
    try testing.expectEqual(@as(usize, 500), st.visibleRange().start);
}

/// `checked > 0` unified assertion: zero loop iterations = all assertions skipped =
/// false positive. Solo `expect(checked > 0)` loses context on CI flakes, can't tell
/// true bug catch vs quiet degradation (growPool `catch {}`, `box` `orelse continue`,
/// both degrade silent). With binding count + pool size, one glance distinguishes.
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

/// Regression fixture: row height via a **switchable** callback, row content fixed at 10px.
/// The mismatch is deliberate so "which decides height" is observable.
///
/// `tall` is shared mutable state across tests (item_height_fn has no context, so only a
/// container-level var works). Every test using it must `begin()`, which resets on entry and
/// `defer`s teardown. **Don't use tail assignment for teardown**: an assert failure early-
/// returns, skips it, and leaks tall=true into the next test (declaration order is fragile).
const AuthoritativeHeight = struct {
    var tall: bool = false;
    /// Usage: `defer AuthoritativeHeight.begin();`, see explanation above.
    fn begin() void {
        tall = false;
    }
    fn heightFn(_: usize, _: ?*anyopaque) f32 {
        return if (tall) 100 else 40;
    }
    /// Content only 10px: if row height set by content, collapses to 10.
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
    // Regression: after item_height_fn also holds ledger, if applySlotHeight guard
    // written as `measured != null`, hasMeasurement() always false causes **every row**
    // .fit, height by content (10px), ledger allocates per callback (40px), each row 30px
    // short. Default path, no extra call needed to hit bug.
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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
        // Authority height must lock to px (not .fit).
        switch (node.style.height) {
            .px => |v| try testing.expectApproxEqAbs(@as(f32, 40), v, 0.01),
            else => return error.AuthoritativeRowLeftAsFit,
        }
        // And truly render as 40, not collapse to content 10.
        try testing.expectApproxEqAbs(@as(f32, 40), node.rectFromWorldOrFallback().h, 0.5);
        checked += 1;
    }
    try expectSlotsChecked(checked, st);
}

test "VirtualList item_height_fn: refreshRange does not collapse rows to content height" {
    // Regression: if refreshRange guard written `measured != null`, authority-height
    // rows reset to .fit; that mode's collectMeasurements returns directly, no one re-
    // locks, row stays perpetually at content height, never self-heals no matter frames.
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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
    // Run frames more, give self-heal time.
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
    // Same: without this, loop zero iterations -> all asserts skipped -> false positive.
    try expectSlotsChecked(checked, st);
}

test "VirtualList item_height_fn: invalidateHeights rebuilds the cached prefix sums" {
    // Regression: ledger caches prefix sums, callback doesn't. When caller changes
    // return values (expand/collapse blocks, toggle side-by-side), ledger can't know.
    // Without invalidation entry: itemHeight() live callback, offsetOf()/totalContentHeight()
    // stale cache, geometry self-contradicts.
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Caller changed row height (40 -> 100).
    AuthoritativeHeight.tall = true;
    invalidateHeights(st);

    // All three must update **together**, else self-contradicting geometry.
    try testing.expectEqual(@as(f32, 100), st.itemHeight(0));
    try testing.expectApproxEqAbs(@as(f32, 100), st.offsetOf(1), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10000), st.totalContentHeight(), 0.01);

    // Bound rows must also re-lock to new height, not stay at old 40.
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
    // Without this, if pool has no bound rows, entire loop skipped, assertions all
    // unexecuted, test fake-green (can fool by stuffing null into pool_bindings).
    try expectSlotsChecked(checked, st);
}

test "VirtualList item_height_fn: invalidate* APIs do not collapse authoritative rows" {
    // Regression: if the invalidateMeasurement / invalidateAllMeasurements guards are written
    // `measured != null`, authority-height rows reset to .fit and never self-heal.
    //
    // These two guards had **zero test coverage**: changing both to `if (false) return;` left the
    // suite all green.
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Call both APIs, missing guard on either makes rows collapse to content height.
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
    // Regression D2: if invalidateHeights doesn't sync scroll_state.content_height, a
    // scrollToIndex / ensureVisible right after is clamped to the **stale** maxScrollY.
    // The clamp is irreversible: next frame fixes content_height but the request is lost and
    // the list is stuck on the wrong row (wanted row 90, landed row 38).
    //
    // Scenario from invalidateHeights docs: expand/collapse a block, then ensureVisible to the
    // expanded row.
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Row height 40 -> 100, total 4000 -> 10000.
    AuthoritativeHeight.tall = true;
    invalidateHeights(st);

    // Scroll bound must sync **immediately**, can't wait next frame.
    try testing.expectApproxEqAbs(@as(f32, 10000), st.scroll_state.content_height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 9800), st.scroll_state.maxScrollY(), 0.01);

    // So scrollToIndex reaches target, not clamped to stale max(3800).
    scrollToIndex(st, 90);
    try testing.expectApproxEqAbs(@as(f32, 9000), st.scroll_state.scroll_y, 1.0);
}

test "VirtualList item_height_fn: updateItemCount refreshes geometry even when count is unchanged" {
    // Regression D1: setCount exits early if count is unchanged, so pending_min and the prefix
    // cache go stale. But "data changed, row count same" is common (diff switches to a same-row
    // file, toggle inline/side-by-side) and item_height_fn return values likely change too.
    // Symptom: itemHeight() says 100, offsetOf() still says 40, rows overlap + scrollbar 2.5x
    // short.
    AuthoritativeHeight.begin();
    defer AuthoritativeHeight.begin();
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Data changed, row count **unchanged**, row heights changed.
    AuthoritativeHeight.tall = true;
    updateItemCount(st, 100);

    // All three must match, else self-contradicting geometry.
    try testing.expectEqual(@as(f32, 100), st.itemHeight(0));
    try testing.expectApproxEqAbs(@as(f32, 100), st.offsetOf(1), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10000), st.totalContentHeight(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10000), st.scroll_state.content_height, 0.01);
}

test "VirtualList measured: item_height_fn wins over measure_items" {
    // When both set, item_height_fn wins, cheaper and exact, no measure roundtrip.
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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
    var ctx = try Cx.init(allocator, std.testing.io);
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
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Verify is ScrollArea (overflow_hidden)
    try testing.expect(result.container.style.overflow_hidden);
    try testing.expectEqualStrings("VirtualList", result.container.meta.ownership.meta.component_name.?);

    // Pool size > 0
    try testing.expect(result.state.pool_size > 0);
    try testing.expect(result.state.pool_size <= max_pool_size);

    // Initial visible range starts from 0
    const range = result.state.visibleRange();
    try testing.expectEqual(@as(usize, 0), range.start);
    try testing.expect(range.end > 0);
    try testing.expect(range.end <= 1000);
}

test "VirtualList: visible range changes with scroll" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Simulate scroll to index 100
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
    var ctx = try Cx.init(allocator, std.testing.io);
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
    var ctx = try Cx.init(allocator, std.testing.io);
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
    try testing.expectEqual(@as(usize, 50000), result.state.item_count);
    try testing.expectEqual(@as(f32, 50000 * 32), result.state.scroll_state.content_height);
}

test "VirtualList: item_count / data_version 来自 signal —— 行数跟随，版本变化重画可见行" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const Probe = struct {
        var renders: usize = 0;
        fn render(_: *Node, _: usize, _: *Cx) void {
            renders += 1;
        }
    };
    Probe.renders = 0;
    const count = try scope.createSignal(usize, 100);
    const version = try scope.createSignal(u64, 0);
    const result = try VirtualList(.{ .item_count = count, .data_version = version, .item_height = 32, .width = 300, .height = 200 }).mount(scope, ctx, Probe.render);
    try root.appendChild(allocator, result.container);
    const first = Probe.renders;
    try testing.expect(first > 0);

    count.set(5000);
    try testing.expectEqual(@as(usize, 5000), result.state.item_count);
    try testing.expectEqual(@as(f32, 5000 * 32), result.state.scroll_state.content_height);

    // Row count unchanged, version changed: redraw visible rows
    result.state.updateVisibleItems();
    const before = Probe.renders;
    version.set(1);
    result.state.updateVisibleItems();
    try testing.expect(Probe.renders > before);
    // Nothing changed: no redraw
    const settled = Probe.renders;
    result.state.updateVisibleItems();
    try testing.expectEqual(settled, Probe.renders);

    // Caller manually updateItemCount, data source then written same count: already
    // applied, no redraw
    updateItemCount(result.state, 7000);
    result.state.updateVisibleItems();
    const synced = Probe.renders;
    count.set(7000);
    result.state.updateVisibleItems();
    try testing.expectEqual(synced, Probe.renders);
}

test "VirtualList: 只有 data_version 是动态源（行数静态）也会重画" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();
    const Probe = struct {
        var renders: usize = 0;
        fn render(_: *Node, _: usize, _: *Cx) void {
            renders += 1;
        }
    };
    Probe.renders = 0;
    const version = try scope.createSignal(u64, 0);
    const result = try VirtualList(.{ .item_count = 100, .data_version = version, .item_height = 32, .width = 300, .height = 200 }).mount(scope, ctx, Probe.render);
    try root.appendChild(allocator, result.container);
    result.state.updateVisibleItems();
    const before = Probe.renders;
    version.set(1);
    result.state.updateVisibleItems();
    try testing.expect(Probe.renders > before);
}

test "virtual_list(dynamic): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("virtual_list(dynamic)", struct {
        fn m(s: *Scope, c: *Cx) anyerror!?*Node {
            const count = try s.createSignal(usize, 50);
            const r = try VirtualList(.{ .item_count = count, .item_height = 20, .width = 200, .height = 100 }).mount(s, c, struct {
                fn render(_: *Node, _: usize, _: *Cx) void {}
            }.render);
            return r.container;
        }
    }.m);
}

test "VirtualList: scrollToIndex" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Set content_height so maxScrollY > 0
    result.state.scroll_state.content_height = 1000 * 32;
    result.state.scroll_state.viewport_height = 200;

    scrollToIndex(result.state, 500);
    try testing.expectEqual(@as(f32, 500 * 32), result.state.scroll_state.scroll_y);
}

test "VirtualList: node pool reuse" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Initial binding count
    var bound_count: usize = 0;
    for (result.state.pool_bindings) |binding| {
        if (binding != null) bound_count += 1;
    }
    try testing.expect(bound_count > 0);
    const initial_bound = bound_count;

    // Simulate scroll
    result.state.scroll_state.scroll_y = 200;
    result.state.scroll_state.viewport_height = 200;
    result.state.scroll_state.content_height = 100 * 40;
    result.state.updateVisibleItems();

    // Verify binding count (node pool reused, total not exceed pool size)
    bound_count = 0;
    for (result.state.pool_bindings) |binding| {
        if (binding != null) bound_count += 1;
    }
    try testing.expect(bound_count > 0);
    try testing.expect(bound_count <= result.state.pool_size);
    // Before/after binding count similar (viewport size unchanged)
    try testing.expect(bound_count >= initial_bound -| 2);
}

test "VirtualList: ensureVisible" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Item 50 not in viewport -> should scroll
    ensureVisible(result.state, 50);
    const scroll_y = result.state.scroll_state.scroll_y;
    const item_top = 50 * 32;
    const item_bottom = item_top + 32;
    // Ensure item fully in viewport
    try testing.expect(scroll_y <= @as(f32, @floatFromInt(item_top)));
    try testing.expect(scroll_y + 200 >= @as(f32, @floatFromInt(item_bottom)));
}

test "VirtualList: spacer heights correct" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Initial: top_spacer = 0 (start from index 0)
    try testing.expectEqual(@as(f32, 0), result.state.top_spacer.style.height.px);

    // Update after scroll
    result.state.scroll_state.scroll_y = 400; // index 10 start
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
        var ctx = try Cx.init(allocator, std.testing.io);
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

        // Force visible window larger than mount estimate, need slot > current pool,
        // first growPool allocation fails this frame.
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

// Downstream app layers ghost re-render: slot row "absolute + translate_x" action
// track icon, post-mount **runtime** setOpacity toggle show/hide (hover direct-write
// path), projection x must stay translate'd position, not revert to layout slot (row
// left). Real symptom: key drawn x~16 (row left pad), real position ~182.
test "VirtualList: runtime setOpacity keeps absolute+translate child at translated x" {
    const allocator = testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
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

    // Frame 1: initial mount. Icon opacity=0, should not appear in command stream.
    ctx.layout();
    _ = ctx.render();
    {
        const commands = ctx.lowerForEncoderPaintTable();
        for (commands) |cmd| {
            if (cmd.isFillRect() and Color.eql(cmd.color.toColor(), ICON_BG)) {
                try testing.expect(false); // opacity 0 shouldn't draw
            }
        }
    }

    // Simulate scroll (content translate_y non-zero, includes sub-row offset path).
    scroll_area.setScrollY(result.state.scroll_state, result.state.content_node, 36);
    ctx.layout();
    _ = ctx.render();
    _ = ctx.lowerForEncoderPaintTable();

    // Find icon node of bound slot (structure: slot > row > track > icon). Pick bound
    // data index mid-row (avoid clip edges), select by data index not world rect.
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

    // Hover direct-write: runtime setOpacity 0->1 (downstream app setTrackInk direct-
    // write path).
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

    // Toggle back 0 -> toggle to 1 again (re-hover path, ghost is where it resurrects).
    // At 0 frame: icon must not appear in stream (ghost = cached splice passes stale entry).
    icon_node.?.setOpacity(0.0);
    ctx.layout();
    _ = ctx.render();
    {
        const commands = ctx.lowerForEncoderPaintTable();
        for (commands) |cmd| {
            if (cmd.isFillRect() and Color.eql(cmd.color.toColor(), ICON_BG)) {
                try testing.expect(false); // opacity 0 after icon lingers = ghost
            }
        }
    }
    // Continuous second frame still 0 (cached splice hits non-record frame), ghost
    // resurrects on "non-record frame".
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

// downgrade must self-heal. growPool / slot take / reorderPoolNodes under OOM all mean
// "skip render this frame" but updateVisibleItems early-return only checks if visible range
// changed. If range unchanged, never retry; missing rows + wrong order stuck until user scroll.

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
    // children = [top_spacer, active rows sorted by index, idle slot, bottom_spacer]
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
            try testing.expect(!seen_free); // active rows must precede idle slot
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
    var ctx = try Cx.init(a, std.testing.io);
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

    // Viewport 4x larger: needed slot > pool, first growPool alloc fails this frame.
    st.scroll_state.viewport_height = 400;
    failing.fail_index = failing.alloc_index;
    st.updateVisibleItems();
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(small_pool, st.pool_size); // grow really failed
    try testing.expect(st.rebind_incomplete);

    // Range unchanged. Pre-fix: early return, pool never grows, half visible rows
    // missing until user scrolls.
    st.updateVisibleItems();
    try testing.expect(st.pool_size > small_pool);
    try expectRangeFullyBound(st);
    try expectPoolOrderSane(st);
    try testing.expect(!st.rebind_incomplete);
}

test "VirtualList: reorderPoolNodes 失败后下一帧重排（新 slot 不能留在 bottom_spacer 之后）" {
    // First measure on clean fixture how many allocs "viewport 4x" pass uses, then on
    // another fixture fail last alloc, last lands in reorderPoolNodes (ensureTotalCapacity /
    // replaceChildOrder), pool growth and binding succeeded before.
    const Fixture = struct {
        fn run(a: std.mem.Allocator, fail_at_from_end: ?usize, failing: *testing.FailingAllocator) !void {
            var ctx = try Cx.init(a, std.testing.io);
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
                // Pre-fix: early return, order forever wrong.
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
    var counting = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    try Fixture.run(counting.allocator(), null, &counting);
    try testing.expect(Fixture.pass_allocs > 0);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
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
                // Simulate callback mid-failure: half subtree built, then report incomplete
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
    var ctx = try Cx.init(a, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(a, null, ctx.owner);
    defer scope.dispose();
    const result = try VirtualList(.{ .item_count = 5, .item_height = 20, .width = 300, .height = 100, .overscan = 0 })
        .mount(scope, ctx, Probe.render);
    try root.appendChild(a, result.container);
    const st = result.state;
    // Mount's first pass rendered 5 rows: index 1 fails once (fail_left 2->1) reports
    // incomplete
    try testing.expect(st.rebind_incomplete);
    try testing.expect(!st.isBound(1));
    try testing.expectEqual(@as(usize, 5), Probe.calls);
    st.scroll_state.viewport_height = 100;
    // Backoff: consecutive fail 1 pass -> wait 1. This pass wait only (range unchanged),
    // callback not called
    try testing.expectEqual(@as(u16, 1), st.render_retry_wait);
    st.updateVisibleItems();
    try testing.expectEqual(@as(usize, 5), Probe.calls);
    try testing.expect(st.rebind_incomplete);
    // Second real retry (visible range unchanged): pre-fix early return, index 1
    // forever empty; now re-call callback, fail again (1->0)
    st.updateVisibleItems();
    try testing.expectEqual(@as(usize, 6), Probe.calls);
    try testing.expect(st.rebind_incomplete);
    try testing.expect(!st.isBound(1));
    // Consecutive fail 2 passes -> wait 3
    try testing.expectEqual(@as(u16, 3), st.render_retry_wait);
    // Failed slot reclaimed: subtree cleared, exited a11y tree
    for (st.pool_nodes, 0..) |pn, slot| {
        if (st.pool_bindings[slot] == null) {
            try testing.expectEqual(@as(usize, 0), pn.children.items.len);
            try testing.expect(pn.behavior.interaction.a11y == null);
        }
    }
    // Wait 3 passes (callback not called), pass 4 retry succeeds -> bind, no longer
    // incomplete, backoff zeroed
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
    // 4 other rows once each + index 1 three times
    try testing.expectEqual(@as(usize, 7), Probe.calls);
    // Not this VL's current bound pool node -> false (root not pool node)
    try testing.expect(!markPoolNodeRenderIncomplete(root));
}

test "review regression 3: generic default row geometry stays 32" {
    const p: VirtualListProps = .{};
    try std.testing.expectEqual(@as(f32, 32), p.item_height);
    try std.testing.expectEqual(@as(f32, 32), p.estimate_item_height);
}

test "LC3C VirtualList accessibility viewport includes layout border" {
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const result = try VirtualList(.{ .item_count = 20, .item_height = 20, .width = 300, .height = 200 }).mount(scope, cx, struct {
        fn render(_: *Node, _: usize, _: *Cx) void {}
    }.render);
    cx.root = result.container;
    result.container.style.padding = core.Padding.all(10);
    result.container.style.border = .{ .width = 5 };
    cx.layout();
    scroll_area.scrollbarBeforeRender(result.container);
    const viewport = VirtualListState.a11yViewport(result.state);
    try testing.expectEqual(@as(f32, 15), viewport.x);
    try testing.expectEqual(@as(f32, 15), viewport.y);
    try testing.expectEqual(@as(f32, 270), viewport.w);
    try testing.expectEqual(@as(f32, 170), viewport.h);
    result.container.style.border.overlay = true;
    result.container.markLayoutDirty();
    cx.layout();
    scroll_area.scrollbarBeforeRender(result.container);
    const overlay = VirtualListState.a11yViewport(result.state);
    try testing.expectEqual(@as(f32, 10), overlay.x);
    try testing.expectEqual(@as(f32, 10), overlay.y);
    try testing.expectEqual(@as(f32, 280), overlay.w);
    try testing.expectEqual(@as(f32, 180), overlay.h);
}

// ---- Hit index under scrolling (core/hit_runtime.zig HitBlock): each pool slot is a block ----

const VlHitRig = struct {
    cx: *Cx,
    scope: *Scope,
    state: *VirtualListState,
    container: *Node,

    /// Data index of the last clicked row (row click handlers carry their index).
    var clicked: ?usize = null;
    /// Bumped to make every row render differently (data change).
    var generation: usize = 0;

    const row_h: f32 = 28;
    const view_h: f32 = 280;

    fn rowHeight(index: usize, measured: bool) f32 {
        return if (measured) 20 + @as(f32, @floatFromInt(index % 4)) * 9 else row_h;
    }

    fn renderRow(node: *Node, index: usize, cx: *Cx, measured: bool) void {
        const row = box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = rowHeight(index, measured) } }, .{}) catch return;
        row.behavior.events.on_click = .{ .callback = onClick, .context = @ptrFromInt(index + 1 + generation * 100_000) };
        node.appendChild(cx.allocator, row) catch cx.freeNode(row);
    }

    fn onClick(ctx: *anyopaque) void {
        clicked = (@intFromPtr(ctx) - 1) % 100_000;
    }

    fn init(rig: *VlHitRig, count: usize, comptime measured: bool) !void {
        clicked = null;
        generation = 0;
        rig.cx = try Cx.init(testing.allocator, testing.io);
        errdefer rig.cx.deinit();
        rig.cx.setViewport(400, 300);
        try rig.cx.setTestFrameStep(16);
        rig.cx.caret_flip_host = true;
        rig.scope = try Scope.init(testing.allocator, null, rig.cx.owner);
        const root = try box(rig.cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        rig.cx.root = root;
        const render = if (measured) struct {
            fn f(node: *Node, index: usize, cx: *Cx) void {
                renderRow(node, index, cx, true);
            }
        }.f else struct {
            fn f(node: *Node, index: usize, cx: *Cx) void {
                renderRow(node, index, cx, false);
            }
        }.f;
        const result = if (measured)
            try VirtualList(.{ .item_count = count, .measure_items = true, .estimate_item_height = 30, .width = 300, .height = view_h, .overscan = 2 }).mount(rig.scope, rig.cx, render)
        else
            try VirtualList(.{ .item_count = count, .item_height = row_h, .width = 300, .height = view_h, .overscan = 2 }).mount(rig.scope, rig.cx, render);
        try root.appendChild(testing.allocator, result.container);
        rig.state = result.state;
        rig.container = result.container;
        try rig.settle();
    }

    fn deinit(rig: *VlHitRig) void {
        rig.scope.dispose();
        rig.cx.deinit();
    }

    fn settle(rig: *VlHitRig) !void {
        var frames: usize = 0;
        while (rig.cx.wantsFrame() and frames < 600) : (frames += 1) {
            rig.cx.advanceFrameClock();
            rig.cx.layout();
            _ = rig.cx.render();
        }
        try testing.expect(!rig.cx.wantsFrame());
    }

    /// Data index of the row painted at content-space y (what the user sees there).
    fn expectedIndex(rig: *VlHitRig, y: f32) ?usize {
        const content_y = y - rig.container.rectFromWorldOrFallback().y - rig.state.content_node.style.translate_y;
        if (content_y < 0 or content_y >= rig.state.totalContentHeight()) return null;
        var lo: usize = 0;
        var hi: usize = rig.state.item_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (rig.state.offsetOf(mid + 1) <= content_y) lo = mid + 1 else hi = mid;
        }
        // Only rows rendered at their full measured height are unambiguous.
        const top = rig.state.offsetOf(lo);
        if (content_y - top < 2 or top + rig.state.itemHeight(lo) - content_y < 2) return null;
        return lo;
    }

    /// Data index of the row the hit index resolves at (x, y), through the pool slot it hit.
    fn hitIndex(rig: *VlHitRig, x: f32, y: f32) ?usize {
        var node = rig.cx.hitTest(x, y);
        while (node) |n| : (node = n.parent) {
            for (rig.state.pool_nodes, 0..) |slot, i| {
                if (slot == n) return rig.state.pool_bindings[i];
            }
        }
        return null;
    }

    fn click(rig: *VlHitRig, x: f32, y: f32) ?usize {
        clicked = null;
        rig.cx.handleMouseDown(x, y, .{});
        rig.cx.handleMouseUp(x, y);
        return clicked;
    }

    /// Every probed point resolves (hit test and click) to the row painted there.
    fn expectHitsMatchPaint(rig: *VlHitRig) !void {
        var y: f32 = 3;
        while (y < view_h) : (y += 11) {
            const want = rig.expectedIndex(y) orelse continue;
            try testing.expectEqual(@as(?usize, want), rig.hitIndex(100, y));
        }
        const probe_y: f32 = 137;
        if (rig.expectedIndex(probe_y)) |want| try testing.expectEqual(@as(?usize, want), rig.click(100, probe_y));
    }

    fn scroll(rig: *VlHitRig, dy: f32) void {
        rig.cx.handleScroll(.{ .x = 100, .y = 137, .dx = 0, .dy = dy });
    }
};

test "VirtualList hit: rows rebound by scrolling are hit at once, only they are rebuilt" {
    var rig: VlHitRig = undefined;
    try rig.init(1000, false);
    defer rig.deinit();
    const cx = rig.cx;
    const deltas = [_]f32{ -28, -7, -50, -28, -90, 13, -28, -28, 40, -200, -3 };
    for (0..4) |round| {
        for (deltas) |dy| {
            var bindings_before: [max_pool_size]?usize = undefined;
            @memcpy(bindings_before[0..rig.state.pool_size], rig.state.pool_bindings);
            const blocks_before = cx.interaction_index.stat_build_blocks;
            cx.input_perf = .{};
            // Event time, no frame in between: the hit scene commits the rebind first.
            rig.scroll(dy);
            try rig.expectHitsMatchPaint();
            try testing.expectEqual(@as(u32, 0), cx.input_perf.in_hit_full_rebuilds);
            var rebound: u32 = 0;
            for (rig.state.pool_bindings, 0..) |b, i| {
                if (!std.meta.eql(b, bindings_before[i])) rebound += 1;
            }
            // Rebuilt hit blocks: the rebound slots, plus the two spacers that resized.
            try testing.expect(cx.interaction_index.stat_build_blocks - blocks_before <= rebound + 2);
            if (round % 2 == 1) try rig.settle();
        }
    }
    try rig.settle();
    try rig.expectHitsMatchPaint();
}

test "VirtualList hit: fast scroll and both ends hit the painted rows" {
    var rig: VlHitRig = undefined;
    try rig.init(1000, false);
    defer rig.deinit();
    rig.scroll(-5000);
    try rig.expectHitsMatchPaint();
    try rig.settle();
    try rig.expectHitsMatchPaint();
    // Past the end: the last row is at the bottom.
    rig.scroll(-1_000_000);
    try rig.settle();
    try rig.expectHitsMatchPaint();
    try testing.expectEqual(@as(?usize, 999), rig.hitIndex(100, VlHitRig.view_h - 5));
    try testing.expectEqual(@as(?usize, 999), rig.click(100, VlHitRig.view_h - 5));
    // Back to the top in one event.
    rig.scroll(1_000_000);
    try rig.expectHitsMatchPaint();
    try rig.settle();
    try testing.expectEqual(@as(?usize, 0), rig.hitIndex(100, 5));
    try testing.expectEqual(@as(?usize, 0), rig.click(100, 5));
}

test "VirtualList hit: measured variable-height rows hit where they are painted" {
    var rig: VlHitRig = undefined;
    try rig.init(400, true);
    defer rig.deinit();
    const deltas = [_]f32{ -30, -61, -200, 45, -17, -900, 300, -2 };
    for (deltas) |dy| {
        rig.cx.input_perf = .{};
        rig.scroll(dy);
        try rig.settle();
        try rig.expectHitsMatchPaint();
        try testing.expectEqual(@as(u32, 0), rig.cx.input_perf.in_hit_full_rebuilds);
    }
}

test "VirtualList hit: data change rebinds visible rows and the hit index follows" {
    var rig: VlHitRig = undefined;
    try rig.init(1000, false);
    defer rig.deinit();
    rig.scroll(-300);
    try rig.settle();
    const old_row = rig.cx.hitTest(100, 137).?;
    VlHitRig.generation = 1;
    updateItemCount(rig.state, 600);
    // Event-time query straight after the data change: new row nodes, same painted indices.
    try rig.expectHitsMatchPaint();
    try testing.expect(rig.cx.hitTest(100, 137).? != old_row);
    try rig.settle();
    try rig.expectHitsMatchPaint();
    // Shrink below the scroll position: the list clamps and the hits follow.
    updateItemCount(rig.state, 5);
    try rig.settle();
    try rig.expectHitsMatchPaint();
    try testing.expectEqual(@as(?usize, 4), rig.hitIndex(100, 4 * VlHitRig.row_h + 10));
    try testing.expectEqual(@as(?usize, null), rig.hitIndex(100, 5 * VlHitRig.row_h + 10));
}
