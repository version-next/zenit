/// ScrollArea Component
///
/// Scrollable container component with Apple-level scroll physics.
///
/// Features:
/// - overflow_hidden clipping + translate_y/x scroll offset
/// - event-driven scroll (system momentum auto-supported)
/// - scrollbar indicator: auto fade in/out, brighter/wider on hover
/// - Apple UIScrollView-level rubber banding:
///   - Damping phase: rational function f(x)=x*d*c/(d+c*x) (c=0.55, Apple standard)
///   - Rebound phase: WebKit exponential decay x(t)=(x0+v0*t*0.31)*exp(-12.5*t)
///   - Momentum overscroll directly triggers rubber band + exponential decay to zero
/// - Content size auto-adaptation
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const ComputedRect = core.ComputedRect;
const theme = core.theme;
const Padding = core.Padding;
const HitProxySpec = core.HitProxySpec;
const physics = @import("../../physics.zig");
const Scope = @import("../../reactive.zig").Scope;

// Submodules
pub const debug = @import("debug.zig");
const state_mod = @import("state.zig");
const scroll_event = @import("event.zig");
const scroll_scrollbar = @import("scrollbar.zig");
pub const scroll_physics = @import("physics.zig");

// Re-exports, keep external API unchanged
pub const ScrollDirection = state_mod.ScrollDirection;
pub const ScrollbarVisual = state_mod.ScrollbarVisual;
pub const ScrollbarAxisMetrics = state_mod.ScrollbarAxisMetrics;
pub const ScrollState = state_mod.ScrollState;
pub const ScrollTuning = state_mod.ScrollTuningT;

pub const scrollEventHandler = scroll_event.scrollEventHandler;
pub const isOutwardAtBoundary = scroll_event.isOutwardAtBoundary;

pub const scrollbarBeforeRender = scroll_scrollbar.scrollbarBeforeRender;
pub const scrollbarEventHandler = scroll_scrollbar.scrollbarEventHandler;
pub const scrollbarHEventHandler = scroll_scrollbar.scrollbarHEventHandler;
pub const computeVerticalScrollbarMetrics = scroll_scrollbar.computeVerticalScrollbarMetrics;
pub const computeHorizontalScrollbarMetrics = scroll_scrollbar.computeHorizontalScrollbarMetrics;

pub const applyVerticalScroll = scroll_physics.applyVerticalScroll;
pub const applyHorizontalScroll = scroll_physics.applyHorizontalScroll;

/// ScrollArea properties
pub const ScrollAreaProps = struct {
    /// Stable container identity for data-only restart persistence. Borrowed for scope lifetime.
    persist_key: ?[]const u8 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    direction: ScrollDirection = .vertical,
    content_height: ?f32 = null,
    content_width: ?f32 = null,
    /// Scroll speed multiplier (scroll dx/dy are logical px, normalized at the event bridge, default 1.0)
    scroll_speed: f32 = 1,
    padding: Padding = Padding.ZERO,
    background: Color = Color.TRANSPARENT,
    /// Custom state ID (for cross-instance reuse or distinguishing scroll state)
    state_id: ?u64 = null,
    /// Enable rubber band (jelly rebound) effect for vertical direction
    rubber_band_y: bool = true,
    /// Enable rubber band (jelly rebound) effect for horizontal direction
    rubber_band_x: bool = true,
};

/// ScrollArea mount return value
pub const ScrollAreaResult = struct {
    container: *Node,
    content: *Node,
    state: *ScrollState,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: ScrollAreaResult) core.ViewParts {
        return .{ .root = self.container, .slot = self.content };
    }
};

/// Create ScrollArea: `W.ScrollArea(.{ .width = 320, .height = 240 }).mount(scope, cx)`.
/// Scope manages ScrollState + ScrollEventCtx lifecycle.
/// AXScrollToVisible implementation for ScrollArea (registered with
/// core.a11y_scroll_into_view_hook).
fn a11yScrollIntoView(scroll: *Node, target: *Node) bool {
    if (scroll.behavior.events.on_event != scrollEventHandler) return false;
    const ev_ctx: *ScrollEventCtx = @ptrCast(@alignCast(scroll.behavior.events.event_context orelse return false));
    const content = ev_ctx.content orelse return false;
    const before_y = ev_ctx.state.scroll_y;
    const before_x = ev_ctx.state.scroll_x;
    scrollIntoView(ev_ctx.state, content, target, .nearest);
    scrollIntoViewX(ev_ctx.state, content, target, .nearest);
    return ev_ctx.state.scroll_y != before_y or ev_ctx.state.scroll_x != before_x;
}

pub fn ScrollArea(props: anytype) ScrollAreaBuilder {
    return .{ .props = @import("../../reactive.zig").props.coerce(ScrollAreaProps, props) };
}

pub const ScrollAreaBuilder = struct {
    props: ScrollAreaProps,

    pub fn mount(self: ScrollAreaBuilder, scope: *Scope, cx: *Cx) !ScrollAreaResult {
        return mountImpl(self.props, scope, cx);
    }
};

fn mountImpl(props: ScrollAreaProps, scope: *Scope, cx: *Cx) !ScrollAreaResult {
    core.a11y_scroll_into_view_hook = &a11yScrollIntoView;
    {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const p = props;

        // Outer container: fixed size + overflow_hidden
        // ScrollArea container defaults to grow (fill parent); explicit size uses px
        var container_style = BoxStyle{
            .direction = .column,
            .overflow_hidden = true,
            .background = p.background,
            .padding = p.padding,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        };
        if (p.width) |w| container_style.width = .{ .px = w };
        if (p.height) |h| container_style.height = .{ .px = h };

        // Structure: container / content column / two scrollbars (absolute positioned, hit proxy
        // for hitTest)
        const Parts = struct { content: *Node = undefined, bar_v: *Node = undefined, bar_h: *Node = undefined, track_v: *Node = undefined, track_h: *Node = undefined };
        var parts: Parts = .{};
        const bar_radius = ScrollbarVisual.idle_thickness / 2;
        const container = try view.render(my_scope, cx, view.box(.{ .style = container_style, .tag = .scroll }, .{
            // Inner content container. will_change_transform -> compositor_plan auto-promotes
            // scroll content.
            // Matrix #3: scroll = modify promoted layer transform, no repaint of paint chunks.
            view.capture(&parts.content, view.box(.{ .style = BoxStyle{
                .direction = .column,
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
                .will_change_transform = true,
            } }, {})),
            view.capture(&parts.track_v, view.box(.{ .hit_test = false, .style = .{ .position = .absolute, .width = 0, .height = 0 } }, {})),
            view.capture(&parts.track_h, view.box(.{ .hit_test = false, .style = .{ .position = .absolute, .width = 0, .height = 0 } }, {})),
            view.capture(&parts.bar_v, view.box(.{ .style = BoxStyle{
                .width = .{ .px = ScrollbarVisual.idle_thickness },
                .height = .{ .px = ScrollbarVisual.min_length },
                .position = .absolute,
                .background = Color.TRANSPARENT,
                .border = .{ .radius = bar_radius },
                .hit_shape = .{ .rounded_rect = bar_radius },
                .clip_shape = .{ .rounded_rect = bar_radius },
            } }, {})),
            view.capture(&parts.bar_h, view.box(.{ .style = BoxStyle{
                .width = .{ .px = ScrollbarVisual.min_length },
                .height = .{ .px = ScrollbarVisual.idle_thickness },
                .position = .absolute,
                .background = Color.TRANSPARENT,
                .border = .{ .radius = bar_radius },
                .hit_shape = .{ .rounded_rect = bar_radius },
                .clip_shape = .{ .rounded_rect = bar_radius },
            } }, {})),
        }));
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "ScrollArea";
        // Below the container the scrollbar hook only moves `content` (translate), flips its
        // linear-text state (part of the cache stamps) and repaints thumbs / tracks with a
        // render-dirty mark on change (scrollbar.syncBar*), so the scrolled content stays
        // cacheable across frames (before_render_hook_descendants_cache_safe, audited in Debug).
        container.frame_state.state_bits.flags.before_render_hook_descendants_cache_safe = true;
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;

        const content = parts.content;
        // The scroll offset is content's translate: hit-test the content in its own space so
        // scrolling moves a hit layer instead of rebuilding the hit index (hit_runtime.HitLayer).
        content.behavior.interaction.hit_layer = true;
        const scrollbar_v = parts.bar_v;
        const scrollbar_h = parts.bar_h;
        for ([_]*Node{ scrollbar_v, scrollbar_h }) |bar| {
            bar.frame_state.state_bits.flags.inspectable = false;
            bar.setHitProxyProvider(scrollbarHitProxyProvider, null);
        }

        // Scope allocates ScrollState (retain mode: nodes not rebuilt, state lives with scope)
        const state = blk: {
            const state = try my_scope.allocator.create(ScrollState);
            errdefer my_scope.allocator.destroy(state);
            state.* = ScrollState{};
            try my_scope.registerResource(@ptrCast(state), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const s: *ScrollState = @ptrCast(@alignCast(ptr));
                    alloc.destroy(s);
                }
            }.destroy);
            break :blk state;
        };
        container.addDebugState(@ptrCast(state));

        if (p.content_height) |ch| state.content_height = ch;
        if (p.content_width) |cw| state.content_width = cw;
        state.rubber_band_y_enabled = p.rubber_band_y;
        state.rubber_band_x_enabled = p.rubber_band_x;
        if (p.height) |h| {
            if (state.viewport_height == 0) state.viewport_height = @max(0, h - container.style.contentInsets().vertical());
        }
        if (p.width) |w| {
            if (state.viewport_width == 0) state.viewport_width = @max(0, w - container.style.contentInsets().horizontal());
        }

        // Node on_cleanup relay cell: must outlive my_scope (see ScrollCtxCell),
        // so attached to Cx for cleanup fallback, not my_scope.
        // After registration, ownership goes to Cx (deinit unified cleanup), so errdefer only
        // covers
        // the 'allocated but not yet registered' window, use block to limit scope.
        const cell = blk: {
            const c = try allocator.create(ScrollCtxCell);
            errdefer allocator.destroy(c);
            c.* = .{};
            try cx.registerScrollCtxCell(.{
                .ptr = @ptrCast(c),
                .can_destroy = struct {
                    fn ready(ptr: *anyopaque) bool {
                        const cc: *ScrollCtxCell = @ptrCast(@alignCast(ptr));
                        return cc.ctx == null and cc.references == 0;
                    }
                }.ready,
                .destroyFn = struct {
                    fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const cc: *ScrollCtxCell = @ptrCast(@alignCast(ptr));
                        alloc.destroy(cc);
                    }
                }.destroy,
            });
            break :blk c;
        };

        // Scope allocates ScrollEventCtx
        const event_ctx = blk: {
            const event_ctx = try my_scope.allocator.create(ScrollEventCtx);
            errdefer my_scope.allocator.destroy(event_ctx);
            event_ctx.* = ScrollEventCtx{
                .persist_key = p.persist_key,
                .state = state,
                .cell = cell,
                .content = content,
                .container = container,
                .scrollbar = scrollbar_v,
                .scrollbar_h = scrollbar_h,
                .track_v = parts.track_v,
                .track_h = parts.track_h,
                .cx = cx,
                .scroll_speed = p.scroll_speed,
                .direction = p.direction,
                .scrollbar_thumb = cx.tokens.tokens.color.scrollbar_thumb,
            };
            try my_scope.registerResource(@ptrCast(event_ctx), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const s: *ScrollEventCtx = @ptrCast(@alignCast(ptr));
                    // ctx vanishes here: sever relay cell backref. Node still alive but unbound:
                    // callbacks see cell.ctx == null, safe no-op.
                    if (s.cell) |c| c.ctx = null;
                    alloc.destroy(s);
                }
            }.destroy);

            break :blk event_ctx;
        };
        cell.ctx = event_ctx;
        // Node may outlive scope.dispose() for one reuse cycle (e.g., VirtualList slot rebind).
        // Unbind event_ctx-based hooks/handlers before freeing ScrollEventCtx to avoid dangling
        // pointers.
        try my_scope.onCleanup(ScrollEventCtx, event_ctx, detachScrollAreaBindings);
        container.behavior.events.on_event = scrollEventHandler;
        container.behavior.events.event_context = event_ctx;
        container.behavior.events.scroll_direction_hint = switch (p.direction) {
            .vertical => .vertical,
            .horizontal => .horizontal,
            .both => .both,
        };
        container.meta.per_frame.hooks.before_render.main = scrollbarBeforeRender;

        // Scrollbar attaches its own handler for hitTest hit + drag interaction handling
        scrollbar_v.behavior.events.on_event = scrollbarEventHandler;
        scrollbar_v.behavior.events.event_context = event_ctx;

        // Horizontal scrollbar attaches handler
        scrollbar_h.behavior.events.on_event = scrollbarHEventHandler;
        scrollbar_h.behavior.events.event_context = event_ctx;

        // Reverse: node freed before scope (e.g., ancestor freeNode releases container children,
        // but
        // ScrollArea scope is subtree of outer scope, cleanup runs on outer dispose)
        // -> on node freeNode, immediately null the event_ctx field,
        //   then detachScrollAreaBindings skips on null to avoid use-after-free.
        // Context is **cell not event_ctx**: node may outlive ctx and unbinding can't reach it
        // (see ScrollCtxCell). Writing cell is always safe, null ctx is safe no-op.
        cell.references += 6;
        container.meta.ownership.hooks.on_cleanup = .{ .callback = clearContainerOnNodeFree, .context = @ptrCast(cell) };
        scrollbar_v.meta.ownership.hooks.on_cleanup = .{ .callback = clearScrollbarOnNodeFree, .context = @ptrCast(cell) };
        scrollbar_h.meta.ownership.hooks.on_cleanup = .{ .callback = clearScrollbarHOnNodeFree, .context = @ptrCast(cell) };
        parts.track_v.meta.ownership.hooks.on_cleanup = .{ .callback = clearTrackVOnNodeFree, .context = @ptrCast(cell) };
        parts.track_h.meta.ownership.hooks.on_cleanup = .{ .callback = clearTrackHOnNodeFree, .context = @ptrCast(cell) };
        content.meta.ownership.hooks.on_cleanup = .{ .callback = clearContentOnNodeFree, .context = @ptrCast(cell) };

        // Apply initial scroll position
        content.style.translate_y = state.contentTranslateY();
        content.style.translate_x = state.contentTranslateX();

        // Register ScrollArea container to PropertyTree.scrolls + InteractionTable.
        // Write real scroll_id to InteractionTable for layerize's PromotionHint to recognize.
        // ScrollArea state also holds scroll_id for updateScrollOffset during scroll.
        if (container.element_id_raw != 0xFFFFFFFF) {
            const cx_core = @import("../../core.zig");
            const property_tree_mod = @import("../../core/property_tree.zig");
            const eid = cx_core.world.ElementId.fromRaw(container.element_id_raw);

            const w_size: f32 = if (p.width) |w| w else 0;
            const h_size: f32 = if (p.height) |h| h else 0;
            const scroll_id = cx.property_tree.appendScroll(.{
                .parent = property_tree_mod.INVALID_ID,
                .transform_id = property_tree_mod.INVALID_ID,
                .node_id = container.id,
                .content_size = .{ .width = w_size, .height = h_size },
                .viewport_size = .{ .width = w_size, .height = h_size },
            }) catch property_tree_mod.INVALID_ID;

            // Registration failure = scroll_id allocated but layerize's PromotionHint never sees
            // it,
            // manifests as silent scroll failure (no error). Propagate here, don't swallow.
            try cx.world.interaction.put(eid, .{
                .scroll_id = scroll_id,
            });

            state.world_scroll_id = scroll_id;
            state.world_ref = @ptrCast(&cx.world);
        }

        return .{ .container = container, .content = content, .state = state };
    }
}

// ============================================================================
// Programmatic scroll: public API
//
// Apps scrolling an element into view must not write `state.scroll_y` directly: that
// skips three essentials (clamp, momentum/bounce reset, translate pixel alignment),
// leaving residual momentum scrolling content away and text half-pixel jitter.
// This is the single correct entry point.
// ============================================================================

/// Alignment mode
pub const ScrollAlign = enum {
    /// If fully visible, don't scroll (minimum motion to bring into view)
    nearest,
    /// Align element top to viewport top
    start,
    /// Align element bottom to viewport bottom
    end,
    /// Center element in viewport
    center,
};

/// Programmatically set vertical scroll position. **Only correct way to write scroll_y.**
///
/// Does: clamp to [0, maxScrollY], zero rubber-band bonus and spring velocity,
/// cancel in-flight rebound animation, snap translate_y to pixel_scale grid.
pub fn setScrollY(state: *ScrollState, content: *Node, y: f32) void {
    const clamped = std.math.clamp(y, 0, state.maxScrollY());
    state.scroll_y = clamped;
    // Reset momentum/rebound together; else residual inertia pushes content away next frames
    state.bonus_y = 0;
    state.bonus_velocity = 0;
    state.bounce_active_y = false;
    state.momentum_spent_y = false;
    // Pixel-snap like scrollbarBeforeRender to eliminate text jitter
    content.style.translate_y = state.contentTranslateY();
    content.markHitLayerMotionPropDirty();
}

/// Scroll [top, top+height) content range vertically into view.
///
/// `top` is offset in **content coordinates** (element's distance from content top,
/// not including current scroll_y).
pub fn scrollRectIntoView(
    state: *ScrollState,
    content: *Node,
    top: f32,
    height: f32,
    alignment: ScrollAlign,
) void {
    const vh = state.viewport_height;
    const bottom = top + height;
    const cur = state.scroll_y;

    const target: f32 = switch (alignment) {
        .start => top,
        .end => bottom - vh,
        .center => top + (height - vh) / 2,
        .nearest => blk: {
            if (top < cur) break :blk top; // Above viewport -> align top
            if (bottom > cur + vh) break :blk bottom - vh; // Below viewport -> align bottom
            break :blk cur; // Fully visible -> no-op
        },
    };
    setScrollY(state, content, target);
}

/// Scroll a **fully laid-out** node into view.
///
/// Uses node-vs-content rect delta for content coords; must call after layout
/// (zero rect is no-op, won't scroll viewport to weird position).
pub fn scrollIntoView(
    state: *ScrollState,
    content: *Node,
    node: *Node,
    alignment: ScrollAlign,
) void {
    const nr = node.rectFromWorldOrFallback();
    if (nr.h <= 0) return; // Not yet laid out: don't scroll viewport to weird position with zero rect

    // Accumulate layout-local y along parent chain up to content: that's the
    // content-coordinate offset (not including content's translate/scroll, as needed).
    var top: f32 = 0;
    var cur: ?*Node = node;
    var found = false;
    while (cur) |n| {
        if (n == content) {
            found = true;
            break;
        }
        top += n.rectFromWorldOrFallback().y;
        cur = n.parent;
    }
    if (!found) return; // node not in this ScrollArea

    scrollRectIntoView(state, content, top, nr.h, alignment);
}

/// Horizontal counterpart of `setScrollY`.
pub fn setScrollX(state: *ScrollState, content: *Node, x: f32) void {
    const clamped = std.math.clamp(x, 0, state.maxScrollX());
    state.scroll_x = clamped;
    state.bonus_x = 0;
    state.bonus_velocity_x = 0;
    state.bounce_active_x = false;
    state.momentum_spent_x = false;
    content.style.translate_x = state.contentTranslateX();
    content.markHitLayerMotionPropDirty();
}

/// Scroll [left, left+width) content range horizontally into view. `left`
/// is in content coordinates (not including the current scroll_x).
pub fn scrollRectIntoViewX(
    state: *ScrollState,
    content: *Node,
    left: f32,
    width: f32,
    alignment: ScrollAlign,
) void {
    const vw = state.viewport_width;
    const right = left + width;
    const cur = state.scroll_x;
    const target: f32 = switch (alignment) {
        .start => left,
        .end => right - vw,
        .center => left + (width - vw) / 2,
        .nearest => blk: {
            // Wider than the viewport: show its start.
            if (left < cur or width > vw) break :blk left;
            if (right > cur + vw) break :blk right - vw;
            break :blk cur;
        },
    };
    if (target == cur) return;
    setScrollX(state, content, target);
}

/// Horizontal counterpart of `scrollIntoView` (same laid-out-node contract).
pub fn scrollIntoViewX(
    state: *ScrollState,
    content: *Node,
    node: *Node,
    alignment: ScrollAlign,
) void {
    const nr = node.rectFromWorldOrFallback();
    if (nr.w <= 0) return;
    var left: f32 = 0;
    var cur: ?*Node = node;
    var found = false;
    while (cur) |n| {
        if (n == content) {
            found = true;
            break;
        }
        left += n.rectFromWorldOrFallback().x;
        cur = n.parent;
    }
    if (!found) return;
    scrollRectIntoViewX(state, content, left, nr.w, alignment);
}

pub const ScrollEventCtx = state_mod.ScrollEventCtx;
pub const ScrollCtxCell = state_mod.ScrollCtxCell;

fn clearContainerOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.container = null;
    cell.release();
}

fn clearScrollbarOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.scrollbar = null;
    cell.release();
}

fn clearScrollbarHOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.scrollbar_h = null;
    cell.release();
}

fn clearTrackVOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.track_v = null;
    cell.release();
}

fn clearTrackHOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.track_h = null;
    cell.release();
}

fn clearContentOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.content = null;
    cell.release();
}

fn detachScrollAreaBindings(event_ctx: *ScrollEventCtx) void {
    const raw_ctx: *anyopaque = @ptrCast(event_ctx);
    // on_cleanup context is cell (see mountScrollArea), compare by cell here.
    const raw_cell: ?*anyopaque = if (event_ctx.cell) |c| @ptrCast(c) else null;

    // IMPORTANT: must clear on_cleanup on each node **before** event_ctx is freed by scope.
    // Else node's freeNode invokes callback to freed ScrollEventCtx (clearContainerOnNodeFree/
    // clearContentOnNodeFree, etc), UAF. Critical path for Textarea/VirtualList with embedded
    // ScrollArea: on outer cx.deinit the nodes survive until freeNode, but my_scope has already
    // been disposed.

    if (event_ctx.container) |container| {
        if (container.behavior.events.event_context == raw_ctx) {
            if (container.behavior.events.on_event == scrollEventHandler) {
                container.behavior.events.on_event = null;
            }
            if (container.meta.per_frame.hooks.before_render.main == scrollbarBeforeRender) {
                container.meta.per_frame.hooks.before_render.main = null;
            }
            container.behavior.events.event_context = null;
            container.behavior.events.scroll_direction_hint = null;
        }
        if (container.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearContainerOnNodeFree) {
                container.meta.ownership.hooks.on_cleanup = null;
                event_ctx.cell.?.release();
            }
        }
        event_ctx.container = null;
    }

    if (event_ctx.scrollbar) |scrollbar| {
        if (scrollbar.behavior.events.event_context == raw_ctx) {
            if (scrollbar.behavior.events.on_event == scrollbarEventHandler) {
                scrollbar.behavior.events.on_event = null;
            }
            scrollbar.behavior.events.event_context = null;
        }
        if (scrollbar.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearScrollbarOnNodeFree) {
                scrollbar.meta.ownership.hooks.on_cleanup = null;
                event_ctx.cell.?.release();
            }
        }
        event_ctx.scrollbar = null;
    }

    if (event_ctx.scrollbar_h) |scrollbar_h| {
        if (scrollbar_h.behavior.events.event_context == raw_ctx) {
            if (scrollbar_h.behavior.events.on_event == scrollbarHEventHandler) {
                scrollbar_h.behavior.events.on_event = null;
            }
            scrollbar_h.behavior.events.event_context = null;
        }
        if (scrollbar_h.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearScrollbarHOnNodeFree) {
                scrollbar_h.meta.ownership.hooks.on_cleanup = null;
                event_ctx.cell.?.release();
            }
        }
        event_ctx.scrollbar_h = null;
    }

    for ([_]?*Node{ event_ctx.track_v, event_ctx.track_h }, [_]*const fn (*anyopaque) void{ clearTrackVOnNodeFree, clearTrackHOnNodeFree }) |maybe, callback| {
        if (maybe) |track| if (track.meta.ownership.hooks.on_cleanup) |hook| {
            if (raw_cell != null and hook.context == raw_cell.? and hook.callback == callback) {
                track.meta.ownership.hooks.on_cleanup = null;
                event_ctx.cell.?.release();
            }
        };
    }
    event_ctx.track_v = null;
    event_ctx.track_h = null;

    if (event_ctx.content) |content| {
        if (content.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearContentOnNodeFree) {
                content.meta.ownership.hooks.on_cleanup = null;
                event_ctx.cell.?.release();
            }
        }
        event_ctx.content = null;
    }
}

fn scrollbarHitProxyProvider(node: *const Node, _: ?*anyopaque, out: []HitProxySpec) usize {
    // NOTE: ScrollArea nested-chain tests rely on node.rect direct read (World vs scrollbar rect
    // write order).
    // Session 31 attempted World hook switch, reverted.
    if (out.len < 2) return 0;
    if (node.rectFromWorldOrFallback().w <= 0 or node.rectFromWorldOrFallback().h <= 0) {
        // Hidden bar: two empty specs emit no proxy but keep the planned proxy count (the bar's
        // paint-order range) constant, so showing/hiding the bar is a partial hit rebuild of the
        // bar instead of a full one (hit_runtime.rebuildSubtree).
        out[0] = .{ .local_rect = ComputedRect.init(0, 0, 0, 0), .behavior = .self_only };
        out[1] = out[0];
        return 2;
    }
    const slop = ScrollbarVisual.hover_slop;
    out[0] = .{
        .local_rect = ComputedRect.init(-slop, -slop, node.rectFromWorldOrFallback().w + slop * 2, node.rectFromWorldOrFallback().h + slop * 2),
        .shape = .{ .rounded_rect = node.style.border.radius },
        .behavior = .self_only,
    };
    out[1] = .{
        .local_rect = ComputedRect.init(0, 0, node.rectFromWorldOrFallback().w, node.rectFromWorldOrFallback().h),
        .shape = .{ .rounded_rect = node.style.border.radius },
        .behavior = .self_only,
    };
    return 2;
}

// ========== Tests ==========

test "ScrollArea: basic vertical" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.container);

    for (0..10) |_| {
        const item = try box(ctx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 40 },
            .background = theme.dark.tokens.color.bg_tertiary,
        }, .{});
        try result.content.appendChild(std.testing.allocator, item);
    }

    // COMPONENTS.json Scrollbar: content + two thumbs + two hover tracks.
    try std.testing.expectEqual(@as(usize, 5), result.container.children.items.len);
    try std.testing.expectEqual(@as(usize, 10), result.content.children.items.len);
    try std.testing.expect(result.container.style.overflow_hidden);
}

test "ScrollArea: scroll state" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    try std.testing.expectEqual(@as(f32, 0), result.content.style.translate_y);

    const event = core.Event{ .scroll = .{ .x = 150, .y = 100, .dx = 0, .dy = -1 } };
    const handler_result = scrollEventHandler(event, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.stop, handler_result);
    try std.testing.expect(result.content.style.translate_y < 0);
}

/// Single 300x200 vertical ScrollArea (content 600), return mounted result.
fn mountTestScrollArea(ctx: *Cx, scope: *Scope) !ScrollAreaResult {
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();
    return result;
}

fn testState(result: ScrollAreaResult) *ScrollState {
    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    return event_ctx.state;
}

fn sendScroll(result: ScrollAreaResult, ev: @import("../../events.zig").ScrollEvent) core.EventResult {
    return scrollEventHandler(.{ .scroll = ev }, result.container.behavior.events.event_context);
}

fn settleSpring(state: *ScrollState) void {
    var ms: f64 = 1000.0;
    state.tickBonus(ms);
    while ((state.bounce_active_y or state.bounce_active_x) and ms < 4000.0) {
        ms += 16.667;
        state.tickBonus(ms);
        state.tickBonusX(ms);
    }
}

test "ScrollArea: lifting while overscrolled hands outward momentum to the spring" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    // Finger drags content past bottom
    state.scroll_y = state.maxScrollY();
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -30, .phase = .changed });
    try std.testing.expect(state.touching);
    try std.testing.expect(state.bonus_y > 0);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!state.touching);

    // After release, outward inertia no longer pushes; overscroll goes to spring
    const bonus_at_lift = state.bonus_y;
    try std.testing.expectEqual(core.EventResult.stop, sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -80, .momentum = .began }));
    try std.testing.expectEqual(bonus_at_lift, state.bonus_y);
    try std.testing.expectEqual(state.maxScrollY(), state.scroll_y);

    // After rebound completes, outward inertia tail won't overscroll again
    settleSpring(state);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -80, .momentum = .changed });
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);

    // Inward inertia scrolls normally
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .momentum = .changed });
    try std.testing.expect(state.scroll_y < state.maxScrollY());
}

test "ScrollArea: momentum that reaches the edge bounces once per stream" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.scroll_y = 5;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 40, .momentum = .began });
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expect(state.bonus_y < 0);
    try std.testing.expect(state.momentum_spent_y);

    settleSpring(state);
    for (0..5) |_| {
        _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 30, .momentum = .changed });
        try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    }

    // Next gesture can pull overscroll again
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    try std.testing.expect(!state.momentum_spent_y);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .phase = .changed });
    try std.testing.expect(state.bonus_y < 0);
}

test "ScrollArea: momentum means the finger is up, so the spring can run" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .phase = .changed });
    try std.testing.expect(state.touching);
    // ended event lost, momentum arrives directly
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 5, .momentum = .began });
    try std.testing.expect(!state.touching);
    try std.testing.expect(state.momentum_active);
}

test "ScrollArea: inputActive follows begin/end signals without timers" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);
    state.scroll_y = 200;

    try std.testing.expect(!state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .momentum = .began });
    try std.testing.expect(state.inputActive());
    // Won't auto-revert to idle; depends on signal only
    for (0..100) |_| scrollbarBeforeRender(result.container);
    try std.testing.expect(state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .momentum = .ended });
    try std.testing.expect(!state.inputActive());

    // New gesture interrupts inertia
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .momentum = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .may_begin });
    try std.testing.expect(!state.momentum_active);
}

test "ScrollArea: input_serial counts applied input only" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);
    state.scroll_y = 200;

    const s0 = state.input_serial;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10 });
    try std.testing.expectEqual(s0 + 1, state.input_serial);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expectEqual(s0 + 2, state.input_serial);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expectEqual(s0 + 2, state.input_serial);
}

test "ScrollArea: mouse wheel stops at the edge without rubber band" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.scroll_y = 3;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 40 });
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.touching);
    try std.testing.expect(!state.inputActive());
}

test "ScrollArea: finger down catches a running bounce" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.bonus_y = -20;
    state.tickBonus(1000.0);
    state.tickBonus(1032.0);
    try std.testing.expect(state.bounce_active_y);
    const held = state.bonus_y;

    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .may_begin });
    try std.testing.expect(state.touching);
    try std.testing.expect(!state.bounce_active_y);
    try std.testing.expectEqual(held, state.bonus_y);
    // Spring doesn't run while pressed
    state.tickBonus(1100.0);
    try std.testing.expectEqual(held, state.bonus_y);
    // Spring takes over on release
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .cancelled });
    settleSpring(state);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollArea: nested chain delegates outward boundary scroll to ancestor" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try ScrollArea(.{
        .width = 320,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try ScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();

    const outer_ctx: *ScrollEventCtx = @ptrCast(@alignCast(outer.container.behavior.events.event_context.?));
    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    outer_ctx.state.scroll_y = 0;
    outer_ctx.state.bonus_y = 0;
    inner_ctx.state.scroll_y = 0;
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = 8, .phase = .changed });

    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
    try std.testing.expect(outer_ctx.state.bonus_y < 0);
}

test "ScrollArea: nested chain delegates on boundary crossing frame" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try ScrollArea(.{
        .width = 320,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try ScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();
    _ = ctx.render(); // Ensure hitTest scene updates

    const outer_ctx: *ScrollEventCtx = @ptrCast(@alignCast(outer.container.behavior.events.event_context.?));
    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    outer_ctx.state.scroll_y = 0;
    outer_ctx.state.bonus_y = 0;
    inner_ctx.state.scroll_y = 2; // Not yet at boundary, but will overscroll this frame
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = 8, .phase = .changed });

    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
    try std.testing.expect(outer_ctx.state.bonus_y < 0);
}

test "ScrollArea: nested chain snaps inner to boundary before delegating" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try ScrollArea(.{
        .width = 320,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try ScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();
    _ = ctx.render(); // Ensure hitTest scene updates

    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    inner_ctx.state.scroll_y = inner_ctx.state.maxScrollY() - 2;
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = -8, .phase = .changed });

    try std.testing.expectApproxEqAbs(inner_ctx.state.maxScrollY(), inner_ctx.state.scroll_y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
}

test "ScrollArea: an outer layer holding the gesture keeps it over an inner one" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    inner_state.scroll_y = 60;
    const g = inner.container.globalRect();

    // outer idle: inner scrolls normally under pointer
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });

    // outer holds gesture (finger on pad, content moves under pointer): no handoff to inner
    // mid-gesture
    outer_state.touching = true;
    const outer_before = outer_state.scroll_y;
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
    try std.testing.expect(outer_state.scroll_y > outer_before);
}

test "ScrollArea: an outer bounce does not steal a gesture that starts on the inner layer" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    // outer is rebounding
    outer_state.bonus_y = -12;
    outer_state.tickBonus(1000.0);
    try std.testing.expect(outer_state.bounce_active_y);
    inner_state.scroll_y = 60;

    const g = inner.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    try std.testing.expect(!outer_state.touching);
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
}

test "ScrollArea: ended reaches every layer of a delegated nested gesture" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    // Gesture delegated to outer; inner retains prior overscroll amount
    outer_state.touching = true;
    inner_state.bonus_y = 5;

    const g = inner.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!outer_state.touching);
    try std.testing.expect(!inner_state.touching);
}

test "ScrollArea: a gesture whose ended was lost is cancelled when the next one begins" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 700 }, .height = .{ .px = 300 }, .direction = .row }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const a = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, a.container);
    const b = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, b.container);
    ctx.layout();
    _ = ctx.render();

    const a_state = testState(a);
    const b_state = testState(b);
    a_state.scroll_y = 100;
    b_state.scroll_y = 100;
    const ga = a.container.globalRect();
    const gb = b.container.globalRect();

    ctx.handleScroll(.{ .x = ga.x + 20, .y = ga.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = ga.x + 20, .y = ga.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(a_state.touching);

    ctx.handleScroll(.{ .x = gb.x + 20, .y = gb.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = gb.x + 20, .y = gb.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(!a_state.touching);
    try std.testing.expect(b_state.touching);
}

test "ScrollArea: window blur cancels an in-progress gesture" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    _ = ctx.render();
    const state = testState(result);
    state.scroll_y = 200;

    const g = result.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(state.touching);

    ctx.cancelPointerInteractions(.window_blur);
    try std.testing.expect(!state.touching);
    try std.testing.expect(!state.inputActive());
}

test "ScrollArea: window blur ends in-progress momentum" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    _ = ctx.render();
    const state = testState(result);
    state.scroll_y = 200;

    const g = result.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .ended });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .momentum = .began });
    try std.testing.expect(state.momentum_active);

    ctx.cancelPointerInteractions(.window_blur);
    try std.testing.expect(!state.momentum_active);
}

test "ScrollArea: bounce animation blocks outward momentum" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .scroll_y = 0,
        .bonus_y = -20,
    };

    // Start rebound
    state.tickBonus(1016.0);
    state.tickBonus(1032.0);
    try std.testing.expect(state.bounce_active_y);

    // During animation, outward momentum should be rejected
    const scroll_event_mod = @import("event.zig");
    const bounce_active = scroll_event_mod.hasBounceActive(&state, .vertical);
    try std.testing.expect(bounce_active);

    // Run to completion
    var ms: f64 = 1000.0;
    while (state.bounce_active_y and ms < 3000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.bounce_active_y);
}

fn mountBothInsideVertical(ctx: *Cx, scope: *Scope) !struct { outer: ScrollAreaResult, inner: ScrollAreaResult } {
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    // Horizontal-only both area: content wider than viewport, same height
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .direction = .both }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const strip = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 120 } }, .{});
    try inner.content.appendChild(std.testing.allocator, strip);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();
    // Horizontal content width managed by host (Grid / VirtualList usage)
    const inner_state = testState(inner);
    inner_state.external_content_width = true;
    inner_state.content_width = 900;
    return .{ .outer = outer, .inner = inner };
}

test "ScrollArea: both mode hands a diagonal event to the layer of its dominant axis" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    try std.testing.expectEqual(@as(f32, 0), inner_state.maxScrollY());
    const g = areas.inner.container.globalRect();

    // Vertical dominant: hand entire event to outer, preserve y component
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -2, .dy = -8 });
    try std.testing.expectEqual(@as(f32, 8), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_state.scroll_x);

    // Horizontal dominant: handle x here, discard small y per axis lock
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -2 });
    try std.testing.expectEqual(@as(f32, 8), inner_state.scroll_x);
    try std.testing.expectEqual(@as(f32, 8), outer_state.scroll_y);
}

test "ScrollArea: both mode keeps a held gesture when the dominant axis changes" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    const g = areas.inner.container.globalRect();

    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -1, .phase = .changed });
    try std.testing.expect(inner_state.touching);
    // Mid-gesture switch to vertical dominant: no handoff to outer
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -1, .dy = -8, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 0), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 9), inner_state.scroll_x);
}

test "ScrollArea: both mode keeps the momentum of a gesture it held" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    const g = areas.inner.container.globalRect();

    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -1, .phase = .changed });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });
    // Inertia tail becomes vertical dominant: still inner's inertia, no leak to outer
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -1, .dy = -6, .momentum = .changed });
    try std.testing.expectEqual(@as(f32, 0), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 9), inner_state.scroll_x);
}

test "ScrollArea: both mode does not inject bonus on non-scrollable axis" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .direction = .both,
        .content_height = 200,
        .content_width = 500,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    try std.testing.expectEqual(@as(f32, 0), state.maxScrollY());
    try std.testing.expect(state.maxScrollX() > 0);

    const y_only = core.Event{
        .scroll = .{
            .x = 150,
            .y = 100,
            .dx = 0,
            .dy = 24,
            .phase = .changed,
        },
    };
    const routed = scrollEventHandler(y_only, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.ignored, routed);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollArea: both-mode momentum x bounce does not block vertical scrolling" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .direction = .both,
        .content_height = 1200,
        .content_width = 1200,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    state.scroll_x = 0;
    state.scroll_y = 329;
    state.bonus_x = -0.04;
    state.bonus_y = 0;

    const momentum_vertical = core.Event{
        .scroll = .{
            .x = 150,
            .y = 100,
            .dx = 0,
            .dy = -38,
            .momentum = .changed,
        },
    };

    const handled = scrollEventHandler(momentum_vertical, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.stop, handled);
    try std.testing.expectEqual(@as(f32, 367), state.scroll_y);
    try std.testing.expectApproxEqAbs(@as(f32, -0.04), state.bonus_x, 0.001);
}

test "ScrollArea: isOutwardAtBoundary both returns false when no active delta" {
    const state = ScrollState{
        .content_height = 600,
        .viewport_height = 200,
        .content_width = 800,
        .viewport_width = 300,
        .scroll_y = 20,
        .scroll_x = 40,
    };
    try std.testing.expect(!isOutwardAtBoundary(&state, .both, 0, 0, 1.0));
}

test "ScrollState: effectiveScrollY with bonus" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    // Normal range: effective = scroll_y (bonus=0)
    state.scroll_y = 100;
    try std.testing.expectEqual(@as(f32, 100), state.effectiveScrollY());

    // With bonus: effective = scroll_y + bonus
    state.scroll_y = 0;
    state.bonus_y = -90;
    try std.testing.expectEqual(@as(f32, -90), state.effectiveScrollY());

    state.scroll_y = 300;
    state.bonus_y = 60;
    try std.testing.expectEqual(@as(f32, 360), state.effectiveScrollY());
}

test "ScrollState: duration-based bounce decay" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.bonus_y = 100;
    state.tickBonus(1000.0);
    // First frame: bonus should start decreasing
    try std.testing.expect(state.bonus_y <= 100);
    try std.testing.expect(state.bonus_y > 0);
    try std.testing.expect(state.bounce_active_y);

    // Run to completion
    var ms: f64 = 1000.0;
    while (state.bounce_active_y and ms < 3000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.bounce_active_y);
}

test "ScrollState: bonus bounce blocked while touching" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.bonus_y = 100;
    state.touching = true;
    state.tickBonus(1000.0);
    // Spring doesn't start
    try std.testing.expect(!state.bounce_active_y);
    try std.testing.expectEqual(@as(f32, 100), state.bonus_y);
}

test "ScrollState: larger displacement settles later (critically damped spring)" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var small = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 20,
    };
    var large = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 120,
    };

    small.tickBonus(1000.0);
    large.tickBonus(1000.0);

    var small_done_ms: f64 = 0;
    var large_done_ms: f64 = 0;
    var ms: f64 = 1000.0;
    while ((small.bounce_active_y or large.bounce_active_y) and ms < 3000.0) {
        ms += 16.667;
        small.tickBonus(ms);
        large.tickBonus(ms);
        if (!small.bounce_active_y and small_done_ms == 0) small_done_ms = ms;
        if (!large.bounce_active_y and large_done_ms == 0) large_done_ms = ms;
    }
    // Both converge to zero; larger displacement converges later
    try std.testing.expectEqual(@as(f32, 0), small.bonus_y);
    try std.testing.expectEqual(@as(f32, 0), large.bonus_y);
    try std.testing.expect(large_done_ms >= small_done_ms);
}

test "ScrollState: spring bounce carries inbound velocity (overshoot then return)" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 30,
        .bonus_velocity = 800, // Incoming inertia still pushes outward
    };
    state.tickBonus(1000.0);
    try std.testing.expect(state.bounce_active_y);

    // Should deepen briefly (velocity continuous -> smooth)
    state.tickBonus(1030.0);
    try std.testing.expect(state.bonus_y > 30);

    var ms: f64 = 1030.0;
    while (state.bounce_active_y and ms < 4000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollState: rubberBand round-trip (via physics.RubberBand)" {
    // clamp -> unclamp should restore original value (test via ScrollState.rubber_band)
    const rb = physics.RubberBand{};
    const dim: f32 = 200;
    const inputs = [_]f32{ 5, 20, 50, 100, -10, -80 };
    for (inputs) |input| {
        const clamped = rb.clamp(input, dim);
        const recovered = rb.unclamp(clamped, dim);
        try std.testing.expectApproxEqAbs(input, recovered, 0.1);
    }
}

test "ScrollState: rubberBand asymptotic (via physics.RubberBand)" {
    const rb = physics.RubberBand{};
    const dim: f32 = 200;
    // Small input: output < input (with damping) and close to input
    const small = rb.clamp(10, dim);
    try std.testing.expect(small > 0);
    try std.testing.expect(small <= 10.0);
    // Large input approaches dim asymptotically
    const large = rb.clamp(10000, dim);
    try std.testing.expect(large > 0);
    try std.testing.expect(large <= dim);
    // Monotonically increasing
    try std.testing.expect(large > small);
    // Symmetric for negative input
    const neg = rb.clamp(-50, dim);
    try std.testing.expect(neg < 0);
}

test "applyVerticalScroll: boundary bonus with damping" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    // Normal scroll
    applyVerticalScroll(&state, -5, 1, .gesture);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(state.scroll_y > 0);

    // Overshoot top -> bonus becomes negative (with damping decay)
    state.scroll_y = 0;
    state.bonus_y = 0;
    applyVerticalScroll(&state, 10, 1, .gesture); // delta = -10
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expect(state.bonus_y < 0);
    // Damping: |bonus| should be < 10 (after decay)
    try std.testing.expect(@abs(state.bonus_y) <= 10);

    // Overshoot bottom -> bonus becomes positive (with damping decay)
    state.scroll_y = 300;
    state.bonus_y = 0;
    applyVerticalScroll(&state, -10, 1, .gesture); // delta = +10
    try std.testing.expectEqual(@as(f32, 300), state.scroll_y);
    try std.testing.expect(state.bonus_y > 0);
    try std.testing.expect(state.bonus_y <= 10);

    // Repeated overshoot: damping accumulates, each increment smaller
    state.scroll_y = 0;
    state.bonus_y = 0;
    applyVerticalScroll(&state, 5, 1, .gesture);
    const first_bonus = @abs(state.bonus_y);
    const prev_bonus = state.bonus_y;
    applyVerticalScroll(&state, 5, 1, .gesture);
    const second_increment = @abs(state.bonus_y - prev_bonus);
    try std.testing.expect(second_increment < first_bonus);
}

test "ScrollState: scrollbar metrics" {
    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
    };

    try std.testing.expect(state.needsScrollbar());
    try std.testing.expectEqual(@as(f32, 40), state.scrollbarHeight());

    state.scroll_y = 0;
    try std.testing.expectEqual(@as(f32, 2), state.scrollbarY());

    state.scroll_y = 800;
    try std.testing.expectEqual(@as(f32, 158), state.scrollbarY());

    state.content_height = 100;
    try std.testing.expect(!state.needsScrollbar());
}

test "ScrollState: overscroll shrinks vertical thumb and pins to edge" {
    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
        .scroll_y = 400,
    };

    const base = computeVerticalScrollbarMetrics(&state);
    try std.testing.expectApproxEqAbs(@as(f32, 40), base.length, 0.01);

    state.scroll_y = 0;
    state.bonus_y = -28;
    const top = computeVerticalScrollbarMetrics(&state);
    try std.testing.expect(top.length < base.length);
    try std.testing.expectApproxEqAbs(@as(f32, 2), top.pos, 0.01);

    state.scroll_y = state.maxScrollY();
    state.bonus_y = 28;
    const bottom = computeVerticalScrollbarMetrics(&state);
    try std.testing.expect(bottom.length < base.length);
    try std.testing.expectApproxEqAbs(@as(f32, 198), bottom.pos + bottom.length, 0.05);
}

test "ScrollArea: scrollbar thumb rect updates in before-render hook" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 1000,
        .padding = Padding.all(10),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    state.scrollbar_fade.opacity = 1.0;

    state.scroll_y = state.maxScrollY() / 2;
    scrollbarBeforeRender(result.container);

    const thumb_node = event_ctx.scrollbar.?;
    try std.testing.expectApproxEqAbs(@as(f32, ScrollbarVisual.idle_thickness), thumb_node.rectFromWorldOrFallback().w, 0.01);
    const expected_x = result.container.rectFromWorldOrFallback().x + result.container.rectFromWorldOrFallback().w - thumb_node.rectFromWorldOrFallback().w - ScrollbarVisual.edge_inset;
    try std.testing.expectApproxEqAbs(expected_x, thumb_node.rectFromWorldOrFallback().x, 0.01);
    const first_y = thumb_node.rectFromWorldOrFallback().y;
    try std.testing.expect(first_y > result.container.rectFromWorldOrFallback().y + result.container.style.contentInsets().top);

    state.scroll_y = state.maxScrollY();
    scrollbarBeforeRender(result.container);
    try std.testing.expect(thumb_node.rectFromWorldOrFallback().y > first_y);

    // COMPONENTS.json Scrollbar variants and zenit.scrollbar.*: 4 -> 6, track 10, inset 2.
    try std.testing.expectEqual(ctx.tokens.tokens.color.scrollbar_thumb, thumb_node.getBackground());
    state.scrollbar_hovered = true;
    scrollbarBeforeRender(result.container);
    try std.testing.expectEqual(@as(f32, 6), thumb_node.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 10), event_ctx.track_v.?.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(ctx.tokens.tokens.color.scrollbar_thumb_hover, thumb_node.getBackground());
    try std.testing.expectEqual(ctx.tokens.tokens.color.scrollbar_track, event_ctx.track_v.?.getBackground());
    ctx.setTheme(&core.theme.dark);
    scrollbarBeforeRender(result.container);
    try std.testing.expectEqual(core.theme.dark.tokens.color.scrollbar_thumb_hover, thumb_node.getBackground());
}

test "ScrollArea: scope dispose detaches before-render hook and event handlers" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const scrollbar_v = event_ctx.scrollbar.?;
    const scrollbar_h = event_ctx.scrollbar_h.?;

    scope.dispose();
    scope_disposed = true;

    try std.testing.expect(result.container.behavior.events.on_event == null);
    try std.testing.expect(result.container.behavior.events.event_context == null);
    try std.testing.expect(result.container.meta.per_frame.hooks.before_render.main == null);
    try std.testing.expect(scrollbar_v.behavior.events.on_event == null);
    try std.testing.expect(scrollbar_v.behavior.events.event_context == null);
    try std.testing.expect(scrollbar_h.behavior.events.on_event == null);
    try std.testing.expect(scrollbar_h.behavior.events.event_context == null);

    scrollbarBeforeRender(result.container);
}

test "ScrollState: scrollbar fade" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.onScrollActivity();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    for (0..90) |_| _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    _ = state.tickScrollbar();
    try std.testing.expect(state.scrollbar_fade.opacity < 0.7);

    for (0..40) |_| _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 0), state.scrollbar_fade.opacity);

    state.onScrollActivity();
    state.scrollbar_hovered = true;
    _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 1.0), state.scrollbar_fade.opacity);
}

test "ScrollState: scrollbar fade tick stays idle while opacity is unchanged" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.onScrollActivity();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    var i: usize = 0;
    while (i < state.scrollbar_fade.fade_delay) : (i += 1) {
        const changed = state.tickScrollbar();
        try std.testing.expect(!changed);
        try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);
    }

    const changed = state.tickScrollbar();
    try std.testing.expect(changed);
    try std.testing.expect(state.scrollbar_fade.opacity < 0.7);
}

// -- Programmatic scroll API ----------------

test "setScrollY: clamp + 动量复位 + 像素对齐（裸写 scroll_y 三样全没有）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const content = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    cx.root = content;

    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
        .pixel_scale = 2.0,
    };
    // Fabricate 'residual inertia + in-flight rebound' scenario
    state.bonus_y = 37;
    state.bonus_velocity = 900;
    state.bounce_active_y = true;
    state.momentum_spent_y = true;

    setScrollY(&state, content, 300.4);

    try testing.expectEqual(@as(f32, 300.4), state.scroll_y);
    // Reset momentum/rebound; else next frames' inertia pushes content away
    try testing.expectEqual(@as(f32, 0), state.bonus_y);
    try testing.expectEqual(@as(f32, 0), state.bonus_velocity);
    try testing.expect(!state.bounce_active_y);
    try testing.expect(!state.momentum_spent_y);
    // Snap translate to physical pixel grid (pixel_scale=2 -> 0.5px grid)
    const ty = content.style.translate_y;
    try testing.expectEqual(@as(f32, -300.5), ty);

    // Clamp both top and bottom
    setScrollY(&state, content, -100);
    try testing.expectEqual(@as(f32, 0), state.scroll_y);
    setScrollY(&state, content, 99999);
    try testing.expectEqual(@as(f32, 800), state.scroll_y); // maxScrollY = 1000-200
}

test "scrollRectIntoView: 四种对齐" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const content = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    cx.root = content;

    var state = ScrollState{ .content_height = 1000, .viewport_height = 200 };

    // start: align top
    scrollRectIntoView(&state, content, 500, 40, .start);
    try testing.expectEqual(@as(f32, 500), state.scroll_y);
    // end: align bottom to viewport bottom
    scrollRectIntoView(&state, content, 500, 40, .end);
    try testing.expectEqual(@as(f32, 340), state.scroll_y); // 540 - 200
    // center: center in viewport
    scrollRectIntoView(&state, content, 500, 40, .center);
    try testing.expectEqual(@as(f32, 420), state.scroll_y); // 500 + (40-200)/2

    // nearest: fully visible -> no-op
    state.scroll_y = 480;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 480), state.scroll_y);
    // nearest: below viewport -> align bottom (min motion)
    state.scroll_y = 200;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 340), state.scroll_y);
    // nearest: above viewport -> align top
    state.scroll_y = 700;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 500), state.scroll_y);
}

test "scrollIntoView: 按节点 rect 把子节点滚进视野" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const sa = try ScrollArea(.{ .width = 200, .height = 200 }).mount(scope, cx);
    try root.appendChild(testing.allocator, sa.container);

    sa.state.content_height = 1000;
    sa.state.viewport_height = 200;
    sa.state.external_content_height = true;

    // Create child at content y=600, height 40 (with intermediate container, verify ancestor chain)
    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    const target = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 } }, .{});
    try sa.content.appendChild(testing.allocator, mid);
    try mid.appendChild(testing.allocator, target);
    mid.setLayoutRect(.{ .x = 0, .y = 100, .w = 200, .h = 1000 });
    target.setLayoutRect(.{ .x = 0, .y = 500, .w = 200, .h = 40 });

    // Content coordinate top = 100 + 500 = 600
    scrollIntoView(sa.state, sa.content, target, .start);
    try testing.expectEqual(@as(f32, 600), sa.state.scroll_y);

    scrollIntoView(sa.state, sa.content, target, .end);
    try testing.expectEqual(@as(f32, 440), sa.state.scroll_y); // 640 - 200

    // Node outside ScrollArea -> no-op, won't scroll viewport away
    const outsider = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try root.appendChild(testing.allocator, outsider); // Attached outside ScrollArea
    outsider.setLayoutRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    const before = sa.state.scroll_y;
    scrollIntoView(sa.state, sa.content, outsider, .start);
    try testing.expectEqual(before, sa.state.scroll_y);

    // Unlaid-out (h=0) is also no-op
    const unlaid = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try sa.content.appendChild(testing.allocator, unlaid);
    scrollIntoView(sa.state, sa.content, unlaid, .start);
    try testing.expectEqual(before, sa.state.scroll_y);
}

test "scrollIntoViewX: brings a laid-out child into the horizontal viewport" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const sa = try ScrollArea(.{ .width = 200, .height = 40, .direction = .horizontal }).mount(scope, cx);
    try root.appendChild(testing.allocator, sa.container);
    sa.state.content_width = 1000;
    sa.state.viewport_width = 200;
    sa.state.external_content_width = true;

    const mid = try box(cx, .{ .width = .{ .px = 1000 }, .height = .{ .px = 40 } }, .{});
    const target = try box(cx, .{ .width = .{ .px = 60 }, .height = .{ .px = 40 } }, .{});
    try sa.content.appendChild(testing.allocator, mid);
    try mid.appendChild(testing.allocator, target);
    mid.setLayoutRect(.{ .x = 100, .y = 0, .w = 1000, .h = 40 });
    target.setLayoutRect(.{ .x = 500, .y = 0, .w = 60, .h = 40 });

    // Content coordinate left = 100 + 500 = 600; nearest aligns its right edge.
    scrollIntoViewX(sa.state, sa.content, target, .nearest);
    try testing.expectEqual(@as(f32, 460), sa.state.scroll_x);
    try testing.expectEqual(@as(f32, -460), sa.content.style.translate_x);
    // Already visible: unchanged.
    scrollIntoViewX(sa.state, sa.content, target, .nearest);
    try testing.expectEqual(@as(f32, 460), sa.state.scroll_x);
    // Left of the viewport: aligns its left edge.
    sa.state.scroll_x = 700;
    scrollIntoViewX(sa.state, sa.content, target, .nearest);
    try testing.expectEqual(@as(f32, 600), sa.state.scroll_x);
    // Clamped to the scrollable range.
    scrollIntoViewX(sa.state, sa.content, target, .start);
    try testing.expectEqual(@as(f32, 600), sa.state.scroll_x);
    setScrollX(sa.state, sa.content, 5000);
    try testing.expectEqual(@as(f32, 800), sa.state.scroll_x);
}

test "LP3 template scroll relay retirement preserves escaped callbacks and window ownership" {
    const t = std.testing;
    // Keep another live window while the first is repeatedly retired/recreated.
    const other = try Cx.init(t.allocator, t.io);
    defer other.deinit();
    const other_scope = try Scope.init(t.allocator, null, other.owner);
    defer other_scope.dispose();
    const other_area = try ScrollArea(.{ .height = 80 }).mount(other_scope, other);
    defer other.freeNode(other_area.container);
    const other_cell = other.scroll_ctx_cells.items[0].ptr;
    for (0..2) |_| {
        const cx = try Cx.init(t.allocator, t.io);
        defer cx.deinit();
        for (0..12) |round| {
            const scope = try Scope.init(t.allocator, null, cx.owner);
            const area = try ScrollArea(.{ .height = 80 }).mount(scope, cx);
            try t.expectEqual(@as(usize, 1), cx.scroll_ctx_cells.items.len);
            const cell: *ScrollCtxCell = @ptrCast(@alignCast(cx.scroll_ctx_cells.items[0].ptr));
            try t.expectEqual(@as(usize, 6), cell.references);
            if (round % 2 == 0) {
                scope.dispose();
                cx.freeNode(area.container);
            } else {
                cx.freeNode(area.container);
                scope.dispose();
            }
            try t.expect(cell.ctx == null);
            try t.expectEqual(@as(usize, 0), cell.references);
            try t.expectEqual(other_cell, other.scroll_ctx_cells.items[0].ptr);
        }
        // A callback hidden from event_ctx's current node slots still owns the
        // relay. It must remain safe across scope teardown and a later mount.
        const scope = try Scope.init(t.allocator, null, cx.owner);
        const area = try ScrollArea(.{ .height = 80 }).mount(scope, cx);
        const cell: *ScrollCtxCell = @ptrCast(@alignCast(cx.scroll_ctx_cells.items[0].ptr));
        const escaped = try box(cx, .{}, .{});
        escaped.meta.ownership.hooks.on_cleanup = .{ .callback = clearContentOnNodeFree, .context = @ptrCast(cell) };
        cell.references += 1;
        scope.dispose();
        cx.freeNode(area.container);
        try t.expectEqual(@as(usize, 1), cell.references);
        const next_scope = try Scope.init(t.allocator, null, cx.owner);
        defer next_scope.dispose();
        const next = try ScrollArea(.{ .height = 80 }).mount(next_scope, cx);
        defer cx.freeNode(next.container);
        try t.expectEqual(@as(usize, 2), cx.scroll_ctx_cells.items.len);
        cx.freeNode(escaped); // cell.ctx==null, release without touching dead ctx
        try t.expectEqual(@as(usize, 0), cell.references);
        const final_scope = try Scope.init(t.allocator, null, cx.owner);
        defer final_scope.dispose();
        const last = try ScrollArea(.{ .height = 80 }).mount(final_scope, cx);
        defer cx.freeNode(last.container);
        try t.expectEqual(@as(usize, 2), cx.scroll_ctx_cells.items.len);
        for (cx.scroll_ctx_cells.items) |entry| try t.expect(entry.ptr != @as(*anyopaque, @ptrCast(cell)) or @as(*ScrollCtxCell, @ptrCast(@alignCast(entry.ptr))).ctx != null);
    }
}

test "ScrollArea: mountScrollArea 在任意分配点失败时不泄漏" {
    // OOM injection of PlainTextEditor.mount: 98 leak stacks top out at mountScrollArea, but
    // in isolation it leaks 0. Stack tops show *where* memory was allocated, not *who* must free.
    // The real bug was in the caller (LineVirtualList): missing errdefer on my_scope and
    // sa.container.
    //
    // Regression guard: don't regress mountScrollArea's cleanup contract.
    const t = std.testing;

    // First measure how many allocation points a successful call consumes.
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator(), std.testing.io);
        defer ctx.deinit();
        const scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer scope.dispose();
        const before = counting.alloc_index;
        _ = try ScrollArea(.{ .width = 300, .height = 200 }).mount(scope, ctx);
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;

    for (0..total_allocs) |failure_index| {
        // Each injection point uses independent GPA; use deinit() == .leak to detect leaks.
        // Arena would reclaim leaks as a whole, hiding these defects.
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const ctx = Cx.init(failing.allocator(), std.testing.io) catch {
                _ = gpa.deinit();
                continue;
            };
            const scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };

            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = ScrollArea(.{ .width = 300, .height = 200 }).mount(scope, ctx);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);

            if (result) |r| {
                // Success: caller owns this detached subtree.
                ctx.freeNode(r.container);
            } else |_| {
                induced += 1;
            }
            scope.dispose();
            ctx.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }

    // No-op guard uses ratio not absolute floor (calibration as oom_sweep.zig): induced > 0
    // threshold is three orders below measured value, can't block allocation-point collapse.
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ "scroll_area", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[scroll_area] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}

test "ScrollArea: mountScrollArea 在 childScope 下失败时不泄漏" {
    // Prior test used root scope and didn't attach container to any parent tree, result clean.
    // Consumer (downstream editor line_virtual_list) calls differently: passes scope.childScope()
    // derived scope, and container later attaches to main_lane. This test replicates that pattern
    // to determine if 'dependency-side leak' needs consumer context.
    const t = std.testing;

    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator(), std.testing.io);
        defer ctx.deinit();
        const root_scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer root_scope.dispose();
        const child = try root_scope.childScope();
        const before = counting.alloc_index;
        _ = try ScrollArea(.{ .width = 300, .height = 200 }).mount(child, ctx);
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;

    for (0..total_allocs) |failure_index| {
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const ctx = Cx.init(failing.allocator(), std.testing.io) catch {
                _ = gpa.deinit();
                continue;
            };
            const root_scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const parent = box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{}) catch {
                root_scope.dispose();
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const child = root_scope.childScope() catch {
                ctx.freeNode(parent);
                root_scope.dispose();
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };

            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = ScrollArea(.{ .width = 300, .height = 200 }).mount(child, ctx);
            const appended = if (result) |r| blk2: {
                parent.appendChild(failing.allocator(), r.container) catch break :blk2 false;
                break :blk2 true;
            } else |_| false;
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);

            if (result) |r| {
                if (!appended) ctx.freeNode(r.container);
            } else |_| {
                induced += 1;
                // KEY: on failure path, **only dispose scope, don't freeNode separately**.
                // This matches consumer LineVirtualList pattern: when mountScrollArea fails
                // internally,
                // caller doesn't get sa, relies on scope cleanup alone. If we freeNode here too,
                // we mask the defect (first version did this, showed 0 leaks).
            }
            // Order matches consumer pt_editor.mount errdefer: dispose scope first, then freeNode.
            root_scope.dispose();
            ctx.freeNode(parent);
            ctx.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }

    // No-op guard uses ratio not absolute floor (calibration as oom_sweep.zig): induced > 0
    // threshold is three orders below measured value, can't block allocation-point collapse.
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ "scroll_area", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[scroll_area/childScope] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}

test "ScrollArea: fit + max 被夹住的列容器里收缩成可滚动，px 兄弟不被推出容器" {
    // Pattern like popover chrome height-limited by autosize: head(px) + ScrollArea(fit) +
    // footer(px).
    // Pre-fix: layoutChildren didn't recompute fit child's intrinsic, overflow underestimated,
    // ScrollArea still laid out at content height 300, footer pushed to y=320 (container only 100
    // tall).
    const t = std.testing;
    var ctx = try Cx.init(t.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const panel = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{ .max = 100 } }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, panel);
    const head = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, head);
    const sa = try ScrollArea(.{}).mount(scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try panel.appendChild(t.allocator, sa.container);
    for (0..10) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }
    const foot = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, foot);

    ctx.layout();
    const p = panel.globalRect();
    try t.expectApproxEqAbs(@as(f32, 100), p.h, 0.5);
    // Container squeezed to 100 - 20 - 20, content stays 300 (not squashed, can scroll)
    try t.expectApproxEqAbs(@as(f32, 60), sa.container.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.content.globalRect().h, 0.5);
    // footer fully inside container
    const f = foot.globalRect();
    try t.expectApproxEqAbs(@as(f32, 20), f.h, 0.5);
    try t.expect(f.y + f.h <= p.y + p.h + 0.5);

    // Enough space: no shrink, content-driven as usual
    panel.style.height = .{ .fit = .{ .max = 1000 } };
    panel.markSizingDirty();
    ctx.layout();
    try t.expectApproxEqAbs(@as(f32, 340), panel.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.container.globalRect().h, 0.5);
}

test "ScrollArea: ext.max_height（popover autosize 的写法）夹住的列容器里同样收缩可滚" {
    const t = std.testing;
    var ctx = try Cx.init(t.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const panel = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{} }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, panel);
    (try panel.style.ensureExtFallible(t.allocator)).max_height = 100;
    const sa = try ScrollArea(.{}).mount(scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try panel.appendChild(t.allocator, sa.container);
    for (0..10) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }
    const foot = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, foot);

    ctx.layout();
    const p = panel.globalRect();
    try t.expectApproxEqAbs(@as(f32, 100), p.h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 80), sa.container.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.content.globalRect().h, 0.5);
    const f = foot.globalRect();
    try t.expect(f.y + f.h <= p.y + p.h + 0.5);
}

test "ScrollArea: px 0 + overflow_hidden 的隐藏容器里，flex 收缩为零后重新显示恢复尺寸" {
    // CSS flex shrinks the hidden dialog to zero. Reopening must recompute
    // the intrinsic basis, rather than keeping the previously frozen result.
    const t = std.testing;
    var ctx = try Cx.init(t.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const hidden = try box(ctx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, hidden);
    const dialog = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{ .max = 600 } }, .direction = .column, .overflow_hidden = true }, .{});
    try hidden.appendChild(t.allocator, dialog);
    const sa = try ScrollArea(.{}).mount(scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try dialog.appendChild(t.allocator, sa.container);
    for (0..4) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }

    ctx.layout();
    try t.expectApproxEqAbs(@as(f32, 0), dialog.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 0), sa.container.globalRect().h, 0.5);
    hidden.style.width = .{ .px = 300 };
    hidden.style.height = .{ .px = 200 };
    hidden.markSizingDirty();
    ctx.layout();
    try t.expectApproxEqAbs(@as(f32, 120), dialog.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 120), sa.container.globalRect().h, 0.5);
}

/// Validated read interface; never expose an event-context cast to callers.
pub const PersistView = struct { key: ?[]const u8, x: f32, y: f32, anchor_required: bool };
fn persistContext(node: *Node) ?*ScrollEventCtx {
    if (node.behavior.events.on_event != scrollEventHandler) return null;
    const ptr = node.behavior.events.event_context orelse return null;
    const ctx: *ScrollEventCtx = @ptrCast(@alignCast(ptr));
    if (ctx.cell) |cell| if (cell.ctx != ctx) return null;
    return ctx;
}
pub fn persistView(node: *Node) ?PersistView {
    const ctx = persistContext(node) orelse return null;
    return .{ .key = ctx.persist_key orelse node.meta.ownership.meta.test_id, .x = ctx.state.scroll_x, .y = ctx.state.scroll_y, .anchor_required = ctx.state.external_content_height or ctx.state.external_content_width };
}
pub fn restorePersistOffset(node: *Node, x: f32, y: f32) void {
    const ctx = persistContext(node) orelse return;
    const content = ctx.content orelse return;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
    // The cached extents are only refreshed by scroll events; after a layout that
    // grew or shrank the content they are stale, and clamping against them would
    // cut the restored offset short. Re-read them from the current layout rects,
    // exactly like the scroll event handler does.
    if (content.parent) |parent| {
        const pr = parent.rectFromWorldOrFallback();
        if (pr.h > 0) ctx.state.viewport_height = @max(0, pr.h - parent.style.contentInsets().vertical());
        if (pr.w > 0) ctx.state.viewport_width = @max(0, pr.w - parent.style.contentInsets().horizontal());
    }
    const cr = content.rectFromWorldOrFallback();
    if (!ctx.state.external_content_height and cr.h > 0) ctx.state.content_height = cr.h;
    if (!ctx.state.external_content_width and cr.w > 0) ctx.state.content_width = cr.w;
    setScrollY(ctx.state, content, y);
    const state = ctx.state;
    state.touching = false;
    state.momentum_active = false;
    state.scroll_x = std.math.clamp(x, 0, state.maxScrollX());
    state.bonus_x = 0;
    state.bonus_velocity_x = 0;
    state.bounce_active_x = false;
    state.momentum_spent_x = false;
    content.style.translate_x = state.contentTranslateX();
    content.markHitLayerMotionPropDirty();
    ctx.cx.needs_redraw = true;
}

test "persist scroll key, offset clamp, gesture reset and detached context" {
    const allocator = std.testing.allocator;
    const cx = try Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(allocator, null, cx.owner);
    cx.root_scope = scope;
    const result = try ScrollArea(.{ .width = 100, .height = 80, .persist_key = "stable-scroll" }).mount(scope, cx);
    cx.root = result.container;
    const state = result.state;
    state.content_width = 300;
    state.content_height = 500;
    state.viewport_width = 100;
    state.viewport_height = 80;
    state.bonus_x = 20;
    state.bonus_y = 30;
    restorePersistOffset(result.container, 900, 900);
    const persisted = persistView(result.container).?;
    try std.testing.expectEqualStrings("stable-scroll", persisted.key.?);
    try std.testing.expectEqual(@as(f32, 200), persisted.x);
    try std.testing.expectEqual(@as(f32, 420), persisted.y);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_x);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    const ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    ctx.cell.?.ctx = null;
    try std.testing.expect(persistView(result.container) == null);
    restorePersistOffset(result.container, 0, 0);
    try std.testing.expectEqual(@as(f32, 420), state.scroll_y);
    ctx.cell.?.ctx = ctx;
}

// Hover events are window coordinates; scrollbar frames are local to the viewport.
test "ScrollArea: scrollbar hover survives an offset viewport" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const root = try box(ctx, .{ .width = .fixed(600), .height = .fixed(400), .padding = Padding.all(40) }, .{});
    ctx.root = root;
    const sa = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 1000 }).mount(scope, ctx);
    try root.appendChild(ctx.allocator, sa.container);
    ctx.layout();
    sa.state.onScrollActivity();
    scrollbarBeforeRender(sa.container);
    const ec: *ScrollEventCtx = @ptrCast(@alignCast(sa.container.behavior.events.event_context.?));
    const r = ec.scrollbar.?.globalRect();
    _ = scrollEventHandler(.{ .mouse_move = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2, .dx = 0, .dy = 0 } }, ec);
    try std.testing.expect(sa.state.scrollbar_hovered);
    scrollbarBeforeRender(sa.container);
    // COMPONENTS.json: hover expands thumb 4 -> 6 and reveals the 10px track.
    try std.testing.expectEqual(@as(f32, 6), ec.scrollbar.?.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 10), ec.track_v.?.rectFromWorldOrFallback().w);
}

test "ScrollArea: leaving the container clears scrollbar hover" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const root = try box(ctx, .{ .width = .fixed(600), .height = .fixed(400) }, .{});
    ctx.root = root;
    const sa = try ScrollArea(.{ .width = 300, .height = 200, .content_width = 800, .content_height = 1000 }).mount(scope, ctx);
    try root.appendChild(ctx.allocator, sa.container);
    ctx.layout();
    sa.state.onScrollActivity();
    scrollbarBeforeRender(sa.container);
    const ec: *ScrollEventCtx = @ptrCast(@alignCast(sa.container.behavior.events.event_context.?));
    const r = ec.scrollbar.?.globalRect();
    _ = scrollEventHandler(.{ .mouse_move = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2, .dx = 0, .dy = 0 } }, ec);
    try std.testing.expect(sa.state.scrollbar_hovered);
    // The pointer exits straight through the hover slop: no further move reaches the container.
    _ = scrollEventHandler(.mouse_leave, ec);
    try std.testing.expect(!sa.state.scrollbar_hovered);
    try std.testing.expect(!sa.state.scrollbar_hovered_h);
    scrollbarBeforeRender(sa.container);
    try std.testing.expectEqual(@as(f32, 4), ec.scrollbar.?.rectFromWorldOrFallback().w);
}

// ---- Stationary-pointer hover (core/cx_hover.zig) through the real ScrollArea ----

const HoverRig = struct {
    fn rows(cx: *Cx, parent: *Node, out: []*Node, h: f32) !void {
        for (out) |*slot| {
            const row = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = h } }, .{});
            // Rows that observe pointer events participate in hit testing (hoverable rows).
            row.behavior.events.on_event = observe;
            try parent.appendChild(std.testing.allocator, row);
            slot.* = row;
        }
    }

    fn observe(_: core.Event, _: ?*anyopaque) core.EventResult {
        return .ignored;
    }

    fn settle(cx: *Cx) !void {
        var frames: usize = 0;
        while (cx.wantsFrame() and frames < 600) : (frames += 1) {
            cx.advanceFrameClock();
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expect(!cx.wantsFrame());
    }

    fn indexOf(rows_: []*Node, node: ?*Node) ?usize {
        const n = node orelse return null;
        for (rows_, 0..) |r, i| if (r == n) return i;
        return null;
    }
};

test "ScrollArea: wheel scroll under a stationary pointer moves hover to the row now under it" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const area = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, area.container);
    var rows: [15]*Node = undefined;
    try HoverRig.rows(cx, area.content, &rows, 40);
    try HoverRig.settle(cx);

    cx.handleMouseMove(150, 20);
    try std.testing.expectEqual(@as(?usize, 0), HoverRig.indexOf(&rows, cx.hovered_node));
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = -80 });
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(f32, 80), area.state.scroll_y);
    try std.testing.expectEqual(@as(?usize, 2), HoverRig.indexOf(&rows, cx.hovered_node));

    // Trackpad gesture with momentum: hover tracks every committed position and lands on the row
    // under the pointer once the content rests.
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 0, .phase = .began });
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = -50, .phase = .changed });
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 0, .phase = .ended });
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = -30, .momentum = .began });
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 0, .momentum = .ended });
    try HoverRig.settle(cx);
    const want: usize = @intFromFloat(@floor((20 + area.state.scroll_y) / 40));
    try std.testing.expect(area.state.scroll_y > 80);
    try std.testing.expectEqual(@as(?usize, want), HoverRig.indexOf(&rows, cx.hovered_node));
}

test "ScrollArea: a wheel that moves nothing requests no frame" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const area = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, area.container);
    var rows: [15]*Node = undefined;
    try HoverRig.rows(cx, area.content, &rows, 40);
    try HoverRig.settle(cx);
    // A live stationary pointer over the rows: hover re-resolution must not keep frames going.
    cx.handleMouseMove(150, 20);
    try HoverRig.settle(cx);

    // Against the top end: the first wheel reveals the scroller (a visible change) ...
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 40 });
    try std.testing.expect(cx.wantsFrame());
    try HoverRig.settle(cx);
    // ... and a wheel with the scroller already shown and the content pinned changes nothing.
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 40 });
    try std.testing.expect(!cx.wantsFrame());
    try std.testing.expectEqual(@as(f32, 0), area.state.scroll_y);

    // A wheel that moves the content renders, and so does the next one pinned at the far end
    // only while it still moves.
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = -1000 });
    try std.testing.expect(cx.wantsFrame());
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(f32, 400), area.state.scroll_y);
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = -40 });
    try std.testing.expect(!cx.wantsFrame());
}

test "ScrollArea: overscroll at a pinned end still renders its rubber band and spring" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const area = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, area.container);
    var rows: [15]*Node = undefined;
    try HoverRig.rows(cx, area.content, &rows, 40);
    try HoverRig.settle(cx);
    cx.handleMouseMove(150, 20);
    try HoverRig.settle(cx);
    // Pinned at the top, a trackpad pull past the end rubber-bands: it renders ...
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 0, .phase = .began });
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 40, .phase = .changed });
    try std.testing.expect(cx.wantsFrame());
    try std.testing.expect(area.state.bonus_y != 0);
    // ... and the release hands the overscroll to the spring, which runs to rest.
    cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(cx.wantsFrame());
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(f32, 0), area.state.bonus_y);
    try std.testing.expectEqual(@as(f32, 0), area.state.scroll_y);
}

test "ScrollArea: a wheel over content that cannot scroll requests no frame" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const area = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 120 }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, area.container);
    var rows: [3]*Node = undefined;
    try HoverRig.rows(cx, area.content, &rows, 40);
    // A window-level capture handler that passes scroll events on (a key-binding layer) is not
    // a change either.
    const Keys = struct {
        var seen: u32 = 0;
        fn capture(e: core.Event, _: ?*anyopaque) core.EventResult {
            if (e == .scroll) seen += 1;
            return .ignored;
        }
    };
    root.behavior.events.on_event_capture = Keys.capture;
    try HoverRig.settle(cx);
    cx.handleMouseMove(150, 20);
    try HoverRig.settle(cx);
    for ([_]f32{ 40, -40, 12, -12 }) |dy| {
        cx.handleScroll(.{ .x = 150, .y = 20, .dx = 0, .dy = dy });
        try std.testing.expect(!cx.wantsFrame());
    }
    try std.testing.expectEqual(@as(u32, 4), Keys.seen);
}

test "ScrollArea: a scroll handler that takes the event without declaring it inert still renders" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const canvas = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    const App = struct {
        var seen: u32 = 0;
        fn onScroll(_: @import("../../events.zig").ScrollEvent, _: ?*anyopaque) core.EventResult {
            seen += 1;
            return .stop;
        }
    };
    canvas.behavior.events.on_scroll = App.onScroll;
    try root.appendChild(std.testing.allocator, canvas);
    try HoverRig.settle(cx);
    cx.handleScroll(.{ .x = 50, .y = 50, .dx = 0, .dy = 12 });
    try std.testing.expectEqual(@as(u32, 1), App.seen);
    try std.testing.expect(cx.wantsFrame());
}

test "ScrollArea: nested and programmatic scroll re-resolve hover under a stationary pointer" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const outer = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, outer.container);
    const header = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 } }, .{});
    try outer.content.appendChild(std.testing.allocator, header);
    const inner = try ScrollArea(.{ .width = 300, .height = 120, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    var rows: [20]*Node = undefined;
    try HoverRig.rows(cx, inner.content, &rows, 30);
    const filler = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 380 } }, .{});
    try outer.content.appendChild(std.testing.allocator, filler);
    try HoverRig.settle(cx);

    // Pointer 50px into the inner list: inner row 1.
    cx.handleMouseMove(150, 150);
    try std.testing.expectEqual(@as(?usize, 1), HoverRig.indexOf(&rows, cx.hovered_node));
    // Programmatic scroll of the outer area carries the inner list up by 60: inner row 3.
    setScrollY(outer.state, outer.content, 60);
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(?usize, 3), HoverRig.indexOf(&rows, cx.hovered_node));
    // Wheel over the inner list scrolls the inner area by 30: inner row 4.
    cx.handleScroll(.{ .x = 150, .y = 150, .dx = 0, .dy = -30 });
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(f32, 30), inner.state.scroll_y);
    try std.testing.expectEqual(@as(?usize, 4), HoverRig.indexOf(&rows, cx.hovered_node));
}

// ---- Hit layers (core/hit_runtime.zig HitLayer): scrolling moves hit geometry, no rebuild ----

const HitLayerRig = struct {
    cx: *Cx,
    scope: *Scope,
    area: ScrollAreaResult,
    rows: [15]*Node = undefined,

    fn init(rig: *HitLayerRig) !void {
        rig.cx = try Cx.init(std.testing.allocator, std.testing.io);
        rig.cx.setViewport(400, 300);
        try rig.cx.setTestFrameStep(16);
        rig.cx.caret_flip_host = true;
        rig.scope = try Scope.init(std.testing.allocator, null, rig.cx.owner);
        const root = try box(rig.cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        rig.cx.root = root;
        // Area at y=50: rows above y=50 and below y=250 are clipped by the viewport.
        const spacer = try box(rig.cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 50 } }, .{});
        try root.appendChild(std.testing.allocator, spacer);
        rig.area = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600, .rubber_band_y = false }).mount(rig.scope, rig.cx);
        try root.appendChild(std.testing.allocator, rig.area.container);
        try HoverRig.rows(rig.cx, rig.area.content, &rig.rows, 40);
        try HoverRig.settle(rig.cx);
    }

    fn deinit(rig: *HitLayerRig) void {
        rig.scope.dispose();
        rig.cx.deinit();
    }

    fn rowAt(rig: *HitLayerRig, x: f32, y: f32) ?usize {
        return HoverRig.indexOf(&rig.rows, rig.cx.hitTest(x, y));
    }

    fn rowEpochs(rig: *HitLayerRig) [15]u32 {
        var out: [15]u32 = undefined;
        for (rig.rows, 0..) |row, i| out[i] = row.frame_state.frame_local.spatial.hit.epoch;
        return out;
    }
};

test "ScrollArea hit layer: scrolling moves row hits without rebuilding their proxies" {
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    try std.testing.expect(rig.area.content.behavior.interaction.hit_layer);
    try std.testing.expectEqual(@as(?usize, 0), rig.rowAt(150, 60));
    const epochs = rig.rowEpochs();
    cx.input_perf = .{};

    // Event time (no frame in between): the next hit already resolves at the new offset.
    cx.handleScroll(.{ .x = 150, .y = 60, .dx = 0, .dy = -80 });
    try std.testing.expectEqual(@as(f32, 80), rig.area.state.scroll_y);
    try std.testing.expectEqual(@as(?usize, 2), rig.rowAt(150, 60));
    try std.testing.expectEqual(@as(?usize, 6), rig.rowAt(150, 249));
    // Clip of the (unscrolled) viewport still applies to scrolled rows.
    try std.testing.expectEqual(@as(?usize, null), rig.rowAt(150, 45));
    try std.testing.expectEqual(@as(?usize, null), rig.rowAt(150, 255));
    cx.handleScroll(.{ .x = 150, .y = 60, .dx = 0, .dy = -40 });
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(150, 60));
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(150, 60));
    try std.testing.expectEqual(@as(?usize, 7), rig.rowAt(150, 249));
    // No row proxy was re-emitted by either the event-time refresh or the frames.
    const after = rig.rowEpochs();
    try std.testing.expectEqual(@as(u32, 0), cx.input_perf.in_hit_full_rebuilds);
    try std.testing.expectEqualSlices(u32, &epochs, &after);
}

test "ScrollArea hit layer: layout change inside scrolled content rebuilds siblings at their new place" {
    // Partial rebuild inside a moved layer must place the reflowed siblings in layer space, and
    // the viewport clip entry (outside the layer) must keep clipping them.
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    cx.handleScroll(.{ .x = 150, .y = 60, .dx = 0, .dy = -80 });
    try HoverRig.settle(cx);
    // Row 3 grows by 40: rows 4.. move down by 40 in content space.
    rig.rows[3].style.height = .{ .px = 80 };
    rig.rows[3].markLayoutDirty();
    // Event-time query commits the layout first.
    // content y of point (150,60) = 60 - 50 + 80 = 90 -> row 2; y=210 -> content 240 -> row 4
    // (row 3 spans 120..200, row 4 200..240, row 5 240..280).
    try std.testing.expectEqual(@as(?usize, 2), rig.rowAt(150, 60));
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(150, 150));
    try std.testing.expectEqual(@as(?usize, 5), rig.rowAt(150, 220));
    try std.testing.expectEqual(@as(?usize, null), rig.rowAt(150, 260));
    // Scrolling after the partial rebuild keeps both the rebuilt and the untouched rows exact.
    cx.handleScroll(.{ .x = 150, .y = 60, .dx = 0, .dy = 40 });
    try std.testing.expectEqual(@as(f32, 40), rig.area.state.scroll_y);
    try std.testing.expectEqual(@as(?usize, 1), rig.rowAt(150, 60));
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(150, 190));
    try std.testing.expectEqual(@as(?usize, 4), rig.rowAt(150, 215));
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(?usize, 4), rig.rowAt(150, 215));
}

test "ScrollArea hit layer: partial rebuild below the layer node stays in layer space" {
    // The rebuild root is a row inside the scrolled content: its parent chain must be composed
    // relative to the layer node, not in world space.
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    const chip = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .{});
    chip.behavior.events.on_event = HoverRig.observe;
    try rig.rows[3].appendChild(std.testing.allocator, chip);
    try HoverRig.settle(cx);
    cx.handleScroll(.{ .x = 150, .y = 60, .dx = 0, .dy = -80 });
    try HoverRig.settle(cx);
    // Row 3 spans content 120..160 -> window y 90..130 at scroll 80; chip at its top-left.
    try std.testing.expectEqual(@as(?*Node, chip), cx.hitTest(20, 100));
    chip.style.width = .{ .px = 120 };
    chip.markLayoutDirty();
    try std.testing.expectEqual(@as(?*Node, chip), cx.hitTest(100, 100));
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(100, 125));
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(?*Node, chip), cx.hitTest(100, 100));
}

test "ScrollArea hit layer: nested areas clip and move independently" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const outer = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, outer.container);
    const header = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 } }, .{});
    try outer.content.appendChild(std.testing.allocator, header);
    const inner = try ScrollArea(.{ .width = 300, .height = 120, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    var rows: [20]*Node = undefined;
    try HoverRig.rows(cx, inner.content, &rows, 30);
    const filler = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 380 } }, .{});
    try outer.content.appendChild(std.testing.allocator, filler);
    try HoverRig.settle(cx);

    // Inner viewport spans y 100..220.
    try std.testing.expectEqual(@as(?usize, 1), HoverRig.indexOf(&rows, cx.hitTest(150, 150)));
    // Inner scroll by 30: inner row under y=150 is now row 2; outer does not move.
    cx.handleScroll(.{ .x = 150, .y = 150, .dx = 0, .dy = -30 });
    try std.testing.expectEqual(@as(f32, 30), inner.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), outer.state.scroll_y);
    try std.testing.expectEqual(@as(?usize, 2), HoverRig.indexOf(&rows, cx.hitTest(150, 150)));
    // Outer scroll by 60 (programmatic) carries the inner viewport to y 40..160.
    setScrollY(outer.state, outer.content, 60);
    try std.testing.expectEqual(@as(?usize, 4), HoverRig.indexOf(&rows, cx.hitTest(150, 150)));
    // Above the moved inner viewport: header (not an inner row); below it: filler.
    try std.testing.expectEqual(@as(?usize, null), HoverRig.indexOf(&rows, cx.hitTest(150, 35)));
    try std.testing.expectEqual(@as(?usize, null), HoverRig.indexOf(&rows, cx.hitTest(150, 165)));
    // y=41 is 1px into the moved inner viewport: inner content y 31 -> row 1.
    try std.testing.expectEqual(@as(?usize, 1), HoverRig.indexOf(&rows, cx.hitTest(150, 41)));
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(?usize, 4), HoverRig.indexOf(&rows, cx.hitTest(150, 150)));
}

fn overlayBox(cx: *Cx, parent: *Node, top: f32, h: f32) !*Node {
    const n = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = h }, .position = .absolute }, .{});
    (try n.style.ensureExtFallible(cx.allocator)).inset = .{ .top = .{ .px = top }, .left = .{ .px = 0 } };
    n.behavior.events.on_event = HoverRig.observe;
    try parent.appendChild(std.testing.allocator, n);
    return n;
}

test "ScrollArea hit layer: overlapping children follow paint order through reorders and z" {
    // Children of a hit layer are numbered in blocks of their own (hit_runtime.HitBlock); the
    // topmost hit must still be the last painted one when their order changes without any of
    // them being rebuilt.
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    const content = rig.area.content;
    // Two overlays over row 0 (content y 0..30, window y 50..80), painted after the rows.
    const a = try overlayBox(cx, content, 0, 30);
    const b = try overlayBox(cx, content, 0, 30);
    try HoverRig.settle(cx);
    try std.testing.expectEqual(b, cx.hitTest(20, 60).?);
    // Reorder only: a painted last.
    var order: [17]*Node = undefined;
    order[0] = b;
    for (rig.rows, 0..) |row, i| order[i + 1] = row;
    order[16] = a;
    try content.replaceChildOrder(std.testing.allocator, &order);
    try std.testing.expectEqual(a, cx.hitTest(20, 60).?);
    // Moving b in front of everything (b is first in tree order): positive z paints it last.
    (try b.style.ensureExtFallible(cx.allocator)).z_index = 3;
    b.markOrderDirty();
    b.markInteractionDirty();
    try std.testing.expectEqual(b, cx.hitTest(20, 60).?);
    // Rows keep their place under the overlays; outside them rows hit.
    try std.testing.expectEqual(@as(?usize, 0), rig.rowAt(150, 60));
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(20, 175));
    try HoverRig.settle(cx);
    try std.testing.expectEqual(b, cx.hitTest(20, 60).?);
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(20, 175));
}

test "ScrollArea hit layer: a layer subtree sorts between its node and the node's later siblings" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    try cx.setTestFrameStep(16);
    cx.caret_flip_host = true;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    root.behavior.events.on_event = HoverRig.observe;
    const outer = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, outer.container);
    // An outer row holding a nested area and, painted after it, an overlay over it.
    const row = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 150 } }, .{});
    row.behavior.events.on_event = HoverRig.observe;
    try outer.content.appendChild(std.testing.allocator, row);
    const inner = try ScrollArea(.{ .width = 300, .height = 120, .content_height = 600, .rubber_band_y = false }).mount(scope, cx);
    try row.appendChild(std.testing.allocator, inner.container);
    var rows: [20]*Node = undefined;
    try HoverRig.rows(cx, inner.content, &rows, 30);
    const cover = try overlayBox(cx, row, 60, 30);
    // Window-level overlay after the outer area, over its top.
    const top_cover = try overlayBox(cx, root, 0, 20);
    try HoverRig.settle(cx);

    try std.testing.expectEqual(top_cover, cx.hitTest(20, 10).?);
    try std.testing.expectEqual(@as(?usize, 0), HoverRig.indexOf(&rows, cx.hitTest(150, 10)));
    try std.testing.expectEqual(cover, cx.hitTest(20, 70).?);
    try std.testing.expectEqual(@as(?usize, 2), HoverRig.indexOf(&rows, cx.hitTest(150, 70)));
    // Inner rows beat the row and the outer content they are nested in.
    try std.testing.expectEqual(@as(?usize, 3), HoverRig.indexOf(&rows, cx.hitTest(150, 100)));
    // Below the inner viewport: the outer row itself.
    try std.testing.expectEqual(row, cx.hitTest(150, 130).?);
    // Rebind an inner row (structure change inside the nested layer): order is kept.
    cx.input_perf = .{};
    const fresh = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
    fresh.behavior.events.on_event = HoverRig.observe;
    try inner.content.insertChildBefore(std.testing.allocator, fresh, rows[2]);
    try std.testing.expectEqual(fresh, cx.hitTest(150, 70).?);
    try std.testing.expectEqual(cover, cx.hitTest(20, 70).?);
    try std.testing.expectEqual(@as(?usize, 2), HoverRig.indexOf(&rows, cx.hitTest(150, 100)));
    try std.testing.expectEqual(@as(u32, 0), cx.input_perf.in_hit_full_rebuilds);
}

test "ScrollArea hit layer: a removed or hidden row stops hitting without a full rebuild" {
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    cx.input_perf = .{};
    // Retained removal: the node stays alive, its proxies must go.
    const row2 = rig.rows[2];
    rig.area.content.removeChildRetained(row2);
    // Row 3 moved up into row 2's place (content y 80..120 -> window y 130..170).
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(150, 140));
    try std.testing.expect(cx.hitTest(150, 140).? != row2);
    // Hidden row: no hit, siblings unchanged.
    rig.rows[5].setHitTestVisible(false);
    try std.testing.expect(cx.hitTest(150, 225) != rig.rows[5]);
    try std.testing.expectEqual(@as(?usize, 4), rig.rowAt(150, 185));
    try std.testing.expectEqual(@as(u32, 0), cx.input_perf.in_hit_full_rebuilds);
    try rig.area.content.appendChild(std.testing.allocator, row2);
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(?usize, 3), rig.rowAt(150, 140));
    // A removed overlay leaves nothing behind: the row under it hits again.
    const cover = try overlayBox(cx, rig.area.content, 0, 30);
    try HoverRig.settle(cx);
    try std.testing.expectEqual(cover, cx.hitTest(20, 60).?);
    rig.area.content.removeChildRetained(cover);
    try std.testing.expectEqual(@as(?usize, 0), rig.rowAt(20, 60));
    try rig.area.content.appendChild(std.testing.allocator, cover);
    try std.testing.expectEqual(cover, cx.hitTest(20, 60).?);
}

test "ScrollArea hit layer: a change inside a row is committed when an ancestor of the layer is dirty too" {
    // The layer node's build keeps rows whose own geometry is unchanged, so the change inside the
    // row must be a partial root of its own even though the ancestor's root covers the layer node.
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    const inner = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 40 } }, .{});
    inner.behavior.events.on_event = HoverRig.observe;
    try rig.rows[1].appendChild(std.testing.allocator, inner);
    try HoverRig.settle(cx);
    try std.testing.expectEqual(rig.rows[1], cx.hitTest(150, 110).?);
    cx.input_perf = .{};
    inner.style.width = .{ .px = 200 };
    inner.markLayoutDirty();
    rig.area.container.markLayoutDirty();
    try std.testing.expectEqual(inner, cx.hitTest(150, 110).?);
    try std.testing.expectEqual(@as(u32, 0), cx.input_perf.in_hit_full_rebuilds);
}

test "ScrollArea: latched trackpad gesture and momentum dispatch without hit tests" {
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    cx.handleScroll(.{ .x = 150, .y = 60, .dx = 0, .dy = 0, .phase = .began });
    cx.handleScroll(.{ .x = 150, .y = 60, .dx = 0, .dy = -20, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 20), rig.area.state.scroll_y);
    // Latched: changed events go to the session owner without querying the scene, even with the
    // pointer outside the area.
    const queries = cx.perf.hit_test_count;
    cx.handleScroll(.{ .x = 390, .y = 290, .dx = 0, .dy = -20, .phase = .changed });
    cx.handleScroll(.{ .x = 390, .y = 290, .dx = 0, .dy = 0, .phase = .ended });
    cx.handleScroll(.{ .x = 390, .y = 290, .dx = 0, .dy = -10, .momentum = .began });
    cx.handleScroll(.{ .x = 390, .y = 290, .dx = 0, .dy = -10, .momentum = .changed });
    try std.testing.expectEqual(queries, cx.perf.hit_test_count);
    try std.testing.expectEqual(@as(f32, 60), rig.area.state.scroll_y);
    cx.handleScroll(.{ .x = 390, .y = 290, .dx = 0, .dy = 0, .momentum = .ended });
    // A new gesture hit-tests again: outside the area nothing scrolls.
    cx.handleScroll(.{ .x = 390, .y = 290, .dx = 0, .dy = 0, .phase = .began });
    try std.testing.expect(cx.perf.hit_test_count > queries);
    cx.handleScroll(.{ .x = 390, .y = 290, .dx = 0, .dy = -20, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 60), rig.area.state.scroll_y);
}

test "Cx hit refresh: one before-render tick per scene mutation between frames" {
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    // Pending render-only work after the last frame tick (e.g. an animation repaint).
    rig.rows[0].markRenderDirty();
    cx.input_perf = .{};
    _ = cx.hitTest(150, 60);
    try std.testing.expectEqual(@as(u32, 1), cx.input_perf.in_hit_refresh_forced);
    // No mutation since that tick: further queries reuse the committed scene.
    _ = cx.hitTest(150, 60);
    _ = cx.hitTest(150, 100);
    try std.testing.expectEqual(@as(u32, 1), cx.input_perf.in_hit_refresh_forced);
    // A mutation re-runs the tick before the next query.
    rig.rows[1].markRenderDirty();
    _ = cx.hitTest(150, 60);
    try std.testing.expectEqual(@as(u32, 2), cx.input_perf.in_hit_refresh_forced);
    // Hit-index work is committed even without a mutation-driven tick: a layout change made by
    // the tick's own hooks is laid out and indexed in the same refresh.
    try HoverRig.settle(cx);
}

const HookMoveProbe = struct {
    var target: ?*Node = null;
    var want_y: f32 = 0;
    fn hook(node: *Node) void {
        _ = node;
        const t = target orelse return;
        if (t.style.translate_y != want_y) {
            t.style.translate_y = want_y;
            t.markCompositePropDirty();
        }
    }
};

test "Cx hit refresh: a handler's mutation reaches before-render hooks before the next hit" {
    // A hook that turns handler state into geometry (VirtualList rows, scrollbar thumb, sticky
    // offsets) must have run before the next event's hit test, as before.
    var rig: HitLayerRig = undefined;
    try rig.init();
    defer rig.deinit();
    const cx = rig.cx;
    const root = cx.root.?;
    const probe = try box(cx, .{ .position = .absolute, .width = .{ .px = 60 }, .height = .{ .px = 40 } }, .{});
    probe.behavior.events.on_event = HoverRig.observe;
    try root.appendChild(std.testing.allocator, probe);
    root.meta.per_frame.hooks.before_render.main = HookMoveProbe.hook;
    HookMoveProbe.target = probe;
    HookMoveProbe.want_y = 0;
    defer HookMoveProbe.target = null;
    try HoverRig.settle(cx);
    try std.testing.expectEqual(@as(?*Node, probe), cx.hitTest(30, 20));
    // "Handler": state change plus a dirty mark, as event handlers do.
    HookMoveProbe.want_y = 100;
    root.markRenderDirty();
    try std.testing.expectEqual(@as(?*Node, probe), cx.hitTest(30, 120));
    try std.testing.expect(cx.hitTest(30, 20) != probe);
}

test "LC3C ScrollArea border viewport maxScroll and resize use content insets" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const area = try ScrollArea(.{ .width = 300, .height = 200, .padding = Padding.all(10), .content_height = 1000, .content_width = 800 }).mount(scope, cx);
    cx.root = area.container;
    area.state.external_content_height = true;
    area.state.external_content_width = true;
    area.container.style.border = .{ .width = 5 };
    cx.layout();
    scrollbarBeforeRender(area.container);
    try std.testing.expectEqual(@as(f32, 170), area.state.viewport_height);
    try std.testing.expectEqual(@as(f32, 270), area.state.viewport_width);
    try std.testing.expectEqual(@as(f32, 830), area.state.maxScrollY());
    try std.testing.expectEqual(@as(f32, 530), area.state.maxScrollX());
    restorePersistOffset(area.container, 9999, 9999);
    try std.testing.expectEqual(@as(f32, 830), area.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 530), area.state.scroll_x);
    area.container.style.border.overlay = true;
    area.container.markLayoutDirty();
    cx.layout();
    scrollbarBeforeRender(area.container);
    try std.testing.expectEqual(@as(f32, 820), area.state.maxScrollY());
    try std.testing.expectEqual(@as(f32, 520), area.state.maxScrollX());
    try std.testing.expectEqual(area.state.maxScrollY(), area.state.scroll_y);
    try std.testing.expectEqual(area.state.maxScrollX(), area.state.scroll_x);
}
