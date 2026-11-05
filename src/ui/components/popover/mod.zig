/// Popover Component
///
/// Universal floating panel; core infrastructure for Select/Menu/DatePicker.
/// Builds on OverlayStack framework.
///
/// Features:
/// - Signal(bool) controls show/hide
/// - click/hover/manual trigger modes
/// - OverlayStack manages z-index, Escape, outside-click
/// - Anchor auto-positions + flip + cross-axis shift
/// - Default scale_fade enter/exit animations (overridable)
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const Padding = core.Padding;
const Signal = core.Signal;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const animation = @import("../../animation/mod.zig");
const overlay_stack_mod = @import("../../overlay_stack.zig");
const render_engine = @import("../../core/render_engine/mod.zig");
const floating = @import("../../compute_position.zig");
const scroll_area_mod = @import("../scroll_area/mod.zig");

// Styling layer in styles.zig
const styles = @import("styles.zig");
const HIDDEN_OPACITY: f32 = 0.001;

/// Popover position
pub const PopoverPosition = floating.Placement;

// Virtual Anchor: floating-ui style virtual anchor point
//
// Purpose: popover/menu not necessarily anchored to real Node; common cases:
//   - text editor cursor position (dynamic pixel coords)
//   - context menu (click position)
//   - formatting toolbar above selection
//   - any dynamically computed (x, y, w, h) position
//
// Usage:
// ```zig
// const my_anchor = popover.VirtualAnchor{
//     .ctx = @ptrCast(my_state),
//     .getRect = struct {
//         fn f(ctx: *anyopaque) popover.AnchorRect {
//             const s: *MyState = @ptrCast(@alignCast(ctx));
//             return .{ .x = s.cursor_x, .y = s.cursor_y, .w = 0, .h = s.line_h };
//         }
//     }.f,
// };
//
// const result = try Popover(.{
//     .anchor = .{ .virtual = my_anchor },
//     .visible = &my_signal,
//     .trigger = .manual,
// }).mount(scope, cx);
// ```
//
// The popover before-render hook re-reads the anchor every frame, so it follows a moving anchor.

/// Anchor rect, absolute (viewport) coordinates
pub const AnchorRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Virtual anchor: caller provides ctx + callback to fetch rect.
pub const VirtualAnchor = struct {
    ctx: *anyopaque,
    /// Return rect in absolute viewport coordinate system.
    getRect: *const fn (ctx: *anyopaque) AnchorRect,
};

/// Popover anchor: either real Node (using its globalRect()) or VirtualAnchor.
pub const Anchor = union(enum) {
    node: *Node,
    virtual: VirtualAnchor,
};

/// Popover trigger mode
pub const PopoverTrigger = enum {
    click,
    hover,
    manual,
};

/// Popover size policy:
///   - hard_clip (default): max_width/max_height are hard limits, overflow clipped.
///   - fit_content: content lays out at natural size; max_* still soft limit. No scroll.
///   - fit_or_scroll: content <= max_* expands naturally; exceeding max_* wraps in
///     ScrollArea for vertical scroll (horizontal still hard constrained, no 2D scroll).
///     For hover popup/completion docs where long text overflows.
///
/// With compute_position.autosize middleware: runtime popover queries viewport space,
/// takes min(committed_max_height, user max_height) as soft limit.
pub const SizePolicy = enum {
    hard_clip,
    fit_content,
    fit_or_scroll,
};

/// Equivalent to floating-ui OffsetOptions; exposed to caller as .{ .static = N }
/// or .{ .derive = .{ .ctx = ..., .compute = fn } }.
pub const PopoverOffset = floating.OffsetValue;
pub const OffsetDeriveState = floating.OffsetDeriveState;

/// Popover properties
pub const PopoverProps = struct {
    /// Position
    position: PopoverPosition = .bottom_start,
    /// Trigger mode
    trigger: PopoverTrigger = .click,
    /// Main-axis distance from trigger element; supports static/derivable (computed
    /// dynamically per placement). Default static 4px. Caller writes:
    ///   .offset = .{ .static = 8 }  or
    ///   .offset = .{ .derive = .{ .ctx = ..., .compute = computeFn } }
    offset: PopoverOffset = .{ .static = 4 },
    /// Open/close state. *Signal(bool) is controlled (interactions write directly);
    /// bool has component self-manage (fetch signal via PopoverResult.open);
    /// ui.split(read, cx.on(...)) lets parent intercept (click trigger/hover/click outside/
    /// Esc just propose; parent can reject, keeping state unchanged).
    open: Model(bool) = .{ .local = false },
    /// Callback after user-initiated open/close lands.
    on_open_change: ?Handler(bool) = null,
    /// Close on outside click
    close_on_outside_click: bool = true,
    /// Consume outside-click to prevent triggering the clicked element. Requires
    /// close_on_outside_click.
    consume_outside_click: bool = false,
    /// Escape closes
    close_on_escape: bool = true,
    /// Content width
    width: ?f32 = null,
    /// Content max width (common for auto-fit; overflow handled by interior content
    /// wrapping).
    max_width: ?f32 = null,
    /// When open, float width tracks trigger width.
    match_trigger_width: bool = false,
    /// Allow fixed/matched width to shrink within viewport.
    constrain_width_to_viewport: bool = false,
    /// Content max height
    max_height: ?f32 = null,
    /// Viewport constraint safety margin
    viewport_padding: f32 = 8,
    /// Auto-flip: when preferred placement overflows, pick best position (see
    /// floating-ui flip).
    flip: bool = true,
    /// Enable main-axis shift back into viewport (default false, only cross-axis).
    /// When enabled, even if popover has no room, it shifts back in (may overlap
    /// anchor), friendlier than flying off-screen. Typical: completion docs in small
    /// window can't fit fallback placements.
    shift_main_axis: bool = false,
    /// Optional fallback placement list; non-empty: try [position, ...fallback_placements]
    /// in order, pick first non-overflowing. Empty: use classic 2-way flip (position <->
    /// opposite). Example (docs aside panel): .fallback_placements = &.{.bottom_start,
    /// .top_start} with .position = .right_start -> right -> bottom -> top, **never left**.
    fallback_placements: []const PopoverPosition = &.{},
    /// Optional: pointer to caller-owned mutable slice, **read by popover each frame** to
    /// decide fallback list. If non-null, overrides fallback_placements field. For
    /// "dynamically switch own fallback based on other popover's active_position" (e.g.
    /// docs panel stick to same side as main popup).
    fallback_placements_ptr: ?*[]const PopoverPosition = null,
    /// Enter delay (ms): after open, stay invisible for this long before playing
    /// enter_transition; if closed during the delay, it disappears immediately. For tooltip
    /// display delay.
    open_delay_ms: f32 = 0,
    /// Enter animation
    enter_transition: overlay_stack_mod.Transition = .scale_fade,
    /// Play `enter_transition` when `open` is already true as the popover mounts. Default false:
    /// a popover mounted open (a page shown with its picker open) is the open result, not an
    /// opening, so it appears at once. Set true when the caller mounts it in response to the
    /// opening itself.
    animate_initial_open: bool = false,
    /// Semantic z-index tier; null = overlay (Tooltip passes .tooltip). See StackTier.
    tier: ?overlay_stack_mod.StackTier = null,
    /// Exit animation
    exit_transition: overlay_stack_mod.Transition = .scale_fade,
    /// Keep hidden measurable layout after close, for first-frame warmup.
    prewarm_hidden_layout: bool = false,
    /// After close and exit animation completes, detach content from wrapper subtree.
    /// Content node itself persists; reattached on reopen; hidden content stays out of
    /// root box tree.
    detach_hidden_content: bool = true,
    /// a11y role (null = don't set role, let parent component override).
    a11y_role: ?core.A11yRole = null,
    /// Custom anchor: null means anchor = interior trigger_node (default). When anchor
    /// provided, positioning reads anchor; trigger_node still exists but doesn't participate
    /// in position (still is trigger for dismiss outside-click, preventing click-trigger
    /// dismiss). With trigger=.manual + visible signal, virtual anchor is most common.
    anchor: ?Anchor = null,

    /// Size policy (see SizePolicy docs). Default .hard_clip for backward compat;
    /// .fit_or_scroll still debugging (fit in parent ScrollArea grow degradation causing
    /// content collapse).
    size_policy: SizePolicy = .hard_clip,

    /// When visible, keep chrome.style.overflow_hidden=true (chrome edge clips child raster).
    /// Default false. Relies on the surface owner self-clip path (compositor_plan apply_clip op)
    /// and the fixed nested surface offset. For callers whose child has a background and needs
    /// true chrome corner-radius clipping (e.g. completion popup hint_bar).
    clip_subtree_to_chrome: bool = false,

    /// Avoidance rect provider: popoverBeforeRender calls it each frame; the returned rects feed
    /// the floating-ui flip/shift/autosize middleware as excluded_rects, so this popover's
    /// placement avoids them (treated as 'walls'). Typical: signature popup avoids the current
    /// completion and docs chrome. null = no avoidance. Caller provides buf (stack array fine);
    /// provider writes into it and returns the slice.
    avoid_rects_provider: ?*const fn (cx: *Cx, buf: []floating.Rect) []const floating.Rect = null,
};

/// Handle returned by Popover mount
pub const PopoverResult = struct {
    wrapper: *Node,
    trigger: *Node,
    /// Caller appendChild content here.
    /// WARNING: content lives in a portal: on unmount, Popover disposes its own scope first, then
    /// releases the content subtree (scopes bound in the subtree only unbind, not disposed).
    /// Effects/bindings on added nodes must attach to `scope` (Popover's scope, see below)
    /// or its children; effects on the caller's scope write to freed nodes after Popover unmount.
    /// - hard_clip/fit_content: == chrome
    /// - fit_or_scroll: == ScrollArea content (chrome is separate, popover manages overflow)
    content: *Node,
    /// Caller configures popover panel background/border/shadow/panel padding here.
    /// Most modes == content; fit_or_scroll mode = popover shell node.
    chrome: *Node,
    /// Resolved open signal (non-null for local/bound; null for split, parent controls).
    open: ?*Signal(bool),
    /// Request close from content (menu selected, date picked): same proposal pipeline
    /// as Esc/outside-click, parent can refuse via ui.split; lands then calls on_open_change.
    /// Belongs to Popover's scope.
    close: Handler(void),
    /// Request open/toggle (trigger=.manual components use on click), same proposal pipeline.
    show: Handler(void),
    toggle: Handler(void),
    /// Open/close state data source (split: `open` is null, read from it).
    open_read: Source(bool),
    /// Current scope: Popover's own scope (bound to wrapper). Effects/bindings on content
    /// nodes and resources serving only content go here; lifecycle matches Popover.
    scope: *Scope,
    /// Pointer to internal ctx.active_position: caller **reads each frame** to get actual
    /// popover placement. For 'decide own fallback_placements based on another popover's
    /// active_position' scenario.
    active_position_ptr: *const PopoverPosition,
    /// Backward-compat field, always false now. Wrapper only carries trigger, always by
    /// caller to normal doc tree; floating content independently to window portal.
    portaled: bool,
    /// ui.view integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: PopoverResult) core.ViewParts {
        return .{ .root = self.wrapper, .slot = self.content, .slot_scope = self.scope, .trigger = self.trigger };
    }
};

/// Create Popover: `W.Popover(.{ .open = menu_open, .position = .bottom_start })`
pub fn Popover(props: anytype) PopoverBuilder {
    return .{ .props = reactive.props.coerce(PopoverProps, props) };
}

/// Popover runtime toggle (scope-owned): interactions only propose via write-back pipeline.
const PopoverOpen = struct {
    open: reactive.Bound(bool),
    on_open_change: ?Handler(bool),

    fn toggle(context: *anyopaque) void {
        const self: *PopoverOpen = @ptrCast(@alignCast(context));
        self.open.propose(!self.open.peek(), self.on_open_change);
    }

    fn show(context: *anyopaque) void {
        const self: *PopoverOpen = @ptrCast(@alignCast(context));
        self.open.propose(true, self.on_open_change);
    }

    fn hide(context: *anyopaque) void {
        const self: *PopoverOpen = @ptrCast(@alignCast(context));
        self.open.propose(false, self.on_open_change);
    }
};

pub const PopoverBuilder = struct {
    props: PopoverProps,

    /// Preserve mode: mount
    pub fn mount(self: PopoverBuilder, scope: *Scope, cx: *Cx) !PopoverResult {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const resource_allocator = my_scope.allocator;
        const t = cx.tokens;
        const p = self.props;

        const open_bound = try reactive.resolveModel(bool, my_scope, p.open);
        const open_ctl = try my_scope.allocator.create(PopoverOpen);
        open_ctl.* = .{ .open = open_bound, .on_open_change = p.on_open_change };
        try my_scope.adoptResource(@ptrCast(open_ctl), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*PopoverOpen, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);
        const is_open: Source(bool) = open_bound.read;
        reactive.checkBorrow(my_scope, is_open);

        // Wrapper holds trigger slot only, stays in caller's normal doc flow (popover_content
        // goes portal, see below).
        var trigger_node: *Node = undefined;
        const wrapper = try view.render(my_scope, cx, view.col(.{
            .style = BoxStyle{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
                .no_cross_stretch = true,
                // `.start` required: column's default cross-axis stretch/center pushes trigger to
                // container center, misaligning trigger visual position with its box rect origin
                // (popover positions by this).
                .align_items = .start,
            },
            .a11y = if (p.a11y_role) |role| core.A11yProps{ .role = role } else null,
            // Trigger mode binding (all just proposals): hover on wrapper, click on trigger
            // (button semantics).
            .on_hover = if (p.trigger == .hover) core.Cx.simpleHandler(PopoverOpen.show, open_ctl) else null,
            .on_leave = if (p.trigger == .hover) core.Cx.simpleHandler(PopoverOpen.hide, open_ctl) else null,
        }, view.capture(&trigger_node, view.box(.{
            .style = BoxStyle{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            },
            .tag = if (p.trigger == .click) core.ElementTag.button else core.ElementTag.box,
            .on_click = if (p.trigger == .click) core.Cx.simpleHandler(PopoverOpen.toggle, open_ctl) else null,
        }, {}))));
        errdefer cx.freeNode(wrapper);
        wrapper.meta.ownership.meta.component_name = "Popover";
        try core.bindScopeToNode(my_scope, wrapper);
        scope_bound = true;

        // Popover content (absolute, initially hidden): standalone root, mounts to portal
        // below. fit modes must have max (if caller gave max_width/max_height); otherwise
        // long content expands beyond caller expectation, popover flies off viewport.
        const content_width: core.Sizing = if (p.width) |w| .{ .px = w } else if (p.max_width) |mw| .{ .fit = .{ .max = mw } } else .{ .fit = .{} };
        const content_height: core.Sizing = if (p.max_height) |mh| .{ .fit = .{ .max = mh } } else .{ .fit = .{} };
        const popover_content = try view.render(my_scope, cx, view.col(.{
            .style = BoxStyle{
                .position = .absolute,
                .width = content_width,
                .height = content_height,
                .background = styles.popoverContentBackground(t),
                .padding = Padding.all(0),
                .border = styles.popoverContentBorder(t),
                .transform_origin = transformOriginForPlacement(p.position),
                .shadows = core.ShadowList.of(&.{styles.popoverKeyShadow(t)}),
                .keep_rendering_when_transparent = true,
                .max_width = p.max_width,
                .hit_shape = .{ .rounded_rect = styles.popoverRadius(t) },
                .clip_shape = .{ .rounded_rect = styles.popoverRadius(t) },
                // Intercept pointer events on blank area, prevent pass-through to below.
                .hit_roles = .{ .pointer = true, .scroll = false, .inspect = true },
            },
        }, {}));
        var content_registered = false;
        errdefer if (!content_registered) {
            if (popover_content.parent) |parent| cx.detachChild(parent, popover_content);
            cx.freeNode(popover_content);
        };
        popover_content.meta.ownership.meta.component_name = "PopoverContent";
        const layer_handle = try cx.overlay_stack.push(.{
            .kind = .non_modal,
            .dismiss = .{
                .outside_click = if (p.close_on_outside_click and p.trigger != .hover)
                    (if (p.consume_outside_click) .close_and_consume else .close)
                else
                    .none,
                .escape = p.close_on_escape,
            },
            .enter_transition = p.enter_transition,
            .exit_transition = p.exit_transition,
            .enter_delay_ms = p.open_delay_ms,
            .on_dismiss_request = core.Cx.simpleHandler(PopoverOpen.hide, open_ctl),
            .trigger_node = trigger_node,
            .tier = p.tier,
        });
        var layer_registered = false;
        errdefer if (!layer_registered) cx.overlay_stack.removePermanently(layer_handle);
        // z_index allocated by overlay layer (layer registers with trigger_node first, after
        // node creation).
        (try popover_content.style.ensureExtFallible(allocator)).z_index = layer_handle.z_index;

        cx.overlay_stack.bindFloatingContent(allocator, layer_handle, popover_content);

        const cleanup_ctx = try resource_allocator.create(PopoverCleanupCtx);
        cleanup_ctx.* = .{ .handle = layer_handle, .cx = cx };
        my_scope.adoptResource(@ptrCast(cleanup_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const ctx: *PopoverCleanupCtx = @ptrCast(@alignCast(ptr));
                ctx.cx.overlay_stack.removePermanently(ctx.handle);
                alloc.destroy(ctx);
            }
        }.cleanup) catch |err| {
            resource_allocator.destroy(cleanup_ctx);
            return err;
        };
        layer_registered = true;

        popover_content.style.width = .{ .px = 0 };
        popover_content.style.height = .{ .px = 0 };
        popover_content.style.overflow_hidden = true;
        popover_content.setOpacityRaw(if (p.prewarm_hidden_layout) HIDDEN_OPACITY else 0);
        cx.overlay_stack.commitExit(layer_handle);
        popover_content.style.width = .{ .px = 0 };
        popover_content.style.height = .{ .px = 0 };
        popover_content.style.overflow_hidden = true;

        // Portalization: floating content, regardless of trigger mode, always mounts directly to
        // cx.popover_portal_root (App.mount creates it before building the user tree). The wrapper
        // keeps
        // the trigger in the caller's normal doc flow. This is the only way content can cross
        // parents
        // and overshoot the caller tree: z_index only has same-sibling semantics (render_engine
        // sortSubtreeChildrenByZ), so inline content cannot overshoot the wrapper ancestor's later
        // siblings. A portal also frees content from ancestor overflow_hidden clip and from modal
        // dialog composited surface texture bounds (surface bounds exclude z>0 children).
        // Positioning is unaffected: popoverBeforeRender translate = target world coord - parent
        // .globalRect(). Trigger stays in the caller tree, so click/hover semantics are unchanged.
        const content_portal = try cx.ensurePopoverPortalRoot();
        try content_portal.appendChild(allocator, popover_content);

        const mount_ctx = try resource_allocator.create(DetachedContentCtx);
        mount_ctx.* = .{
            .parent = content_portal,
            .content = popover_content,
            .cx = cx,
            .layer_handle = layer_handle,
            .detach_hidden_content = p.detach_hidden_content,
            .portaled = true,
            .animate_initial_open = p.animate_initial_open,
        };
        my_scope.adoptResource(@ptrCast(mount_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const ctx: *DetachedContentCtx = @ptrCast(@alignCast(ptr));
                // Under portal, content on portal root (outside caller subtree), scope dispose
                // doesn't
                // free via caller tree, must detach first then release detached; otherwise portal
                // root
                // leaves dangling scope-dead child (UAF).
                if (ctx.portaled) {
                    if (ctx.content.parent) |parent| ctx.cx.detachChild(parent, ctx.content);
                }
                if (ctx.content.parent == null) {
                    ctx.cx.freeDetachedNodeAfterScopeDispose(ctx.content);
                }
                alloc.destroy(ctx);
            }
        }.cleanup) catch |err| {
            resource_allocator.destroy(mount_ctx);
            return err;
        };
        content_registered = true;

        // Determine the caller's content mount point by size_policy. .fit_or_scroll: nest a
        // ScrollArea
        // in popover_content; the caller mounts into the scroll content. The ScrollArea container
        // uses
        // fit{.max=p.max_height} to cap total height; overflow is handled by ScrollArea.
        // popover_content has fit{.max=mh}, and a grow+max container gets no space in a fit parent,
        // so
        // it also gets fit+max (expands naturally, cap clamps).
        var scroll_container_node: ?*Node = null;
        const caller_content_node: *Node = if (p.size_policy == .fit_or_scroll) blk: {
            // Config error -> error, not panic: mount returns !PopoverResult, error channel exists,
            // no reason library code kills host for caller skipping a field. (Framework's
            // @panic("OOM:") strategy only for 'half-updated irrecoverable' index/reactive paths,
            // not here.)
            const max_w: f32 = p.max_width orelse return error.FitOrScrollRequiresMaxWidth;
            const max_h: f32 = p.max_height orelse return error.FitOrScrollRequiresMaxHeight;
            if (p.prewarm_hidden_layout) {
                popover_content.style.width = .{ .fit = .{ .max = max_w } };
                popover_content.style.height = .{ .fit = .{ .max = max_h } };
            }
            var scroll_result: scroll_area_mod.ScrollAreaResult = undefined;
            // Bug 1 + Bug 3 fixed: Bug 3 in framework (appendDisplayClipBridgeBegin). Bug 1
            // (scrollbarBeforeRender triggers holdEnterUntilGeometryStable) no longer reproduces,
            // e2e verified hook enabled then popup displays normally.
            try view.mount(my_scope, cx, popover_content, view.capture(&scroll_result, scroll_area_mod.ScrollArea(.{
                .direction = .vertical,
                .background = Color.TRANSPARENT,
                .width = max_w,
                .height = max_h,
            })));
            scroll_container_node = scroll_result.container;
            break :blk scroll_result.content;
        } else popover_content;

        const target_width = p.width;

        // Effect: control show/hide (toggle width/height only).
        const fit_or_scroll_flag = p.size_policy == .fit_or_scroll;
        // fit_or_scroll: force popover width/height to max_width/max_height (required).
        // target_width use max_width override caller's p.width (let effect use px path).
        const effective_target_width: ?f32 = if (fit_or_scroll_flag) p.max_width else target_width;
        const effective_fit_h: ?f32 = if (fit_or_scroll_flag) p.max_height else null;
        try my_scope.createEffect(.{
            .popover = popover_content,
            .is_open = is_open,
            .target_width = effective_target_width,
            .cx = cx,
            .layer_handle = layer_handle,
            .fit_or_scroll = fit_or_scroll_flag,
            .fit_h = effective_fit_h,
            .mount_ctx = mount_ctx,
            // fit_content path: fit must have max (prevent long content bursting), see above
            // content_width comment.
            .max_w = p.max_width,
            .max_h = p.max_height,
            .clip_subtree = p.clip_subtree_to_chrome,
        }, struct {
            fn update(c: anytype) void {
                const initial = !c.mount_ctx.presence_settled;
                c.mount_ctx.presence_settled = true;
                if (c.is_open.get()) {
                    ensurePopoverContentAttached(c.mount_ctx);
                    const animate = !initial or c.mount_ctx.animate_initial_open;
                    c.mount_ctx.instant_enter = !animate;
                    c.cx.overlay_stack.reactivateWith(c.layer_handle, .{ .animate = animate });
                    // Re-open mid-exit animation: reactivate only handles suspended layers; exiting
                    // layers
                    // must pull back to entering, else animation finishes commitExit writes
                    // just-set true
                    // visible back to false (same Modal/Sheet handling).
                    if (c.cx.overlay_stack.findLayer(c.layer_handle)) |layer| {
                        if (layer.state == .exiting) c.cx.overlay_stack.cancelExit(c.layer_handle, .entering);
                    }
                    var sizing_changed = false;
                    // size_policy=.fit_or_scroll: popover_content fixed px (max_width/max_height),
                    // internal ScrollArea handles scrolling. On each open, actively reset to px
                    // (set 0 on hide).
                    if (c.fit_or_scroll) {
                        // Hide state px=0; on open reset to fit{max=N}.
                        if (c.target_width) |w| {
                            const need_reset = switch (c.popover.style.width) {
                                .px => |v| v <= 1,
                                else => false,
                            };
                            if (need_reset) {
                                c.popover.style.width = .{ .fit = .{ .max = w } };
                                sizing_changed = true;
                            }
                        }
                        if (c.fit_h) |h| {
                            const need_reset = switch (c.popover.style.height) {
                                .px => |v| v <= 1,
                                else => false,
                            };
                            if (need_reset) {
                                c.popover.style.height = .{ .fit = .{ .max = h } };
                                sizing_changed = true;
                            }
                        }
                    } else {
                        if (c.target_width) |w| {
                            if (sizingPxValue(c.popover.style.width)) |current| {
                                if (!approxEq(current, w)) {
                                    c.popover.style.width = .{ .px = w };
                                    sizing_changed = true;
                                }
                            } else {
                                c.popover.style.width = .{ .px = w };
                                sizing_changed = true;
                            }
                        } else {
                            // fit-content path: when caller gave max_width, must bring max;
                            // otherwise long content
                            // explodes popover boundary (long paragraphs etc.).
                            const target_mw: f32 = c.max_w orelse std.math.inf(f32);
                            const need_set: bool = switch (c.popover.style.width) {
                                .fit => |f| !approxEq(f.max, target_mw),
                                else => true,
                            };
                            if (need_set) {
                                c.popover.style.width = .{ .fit = .{ .max = target_mw } };
                                sizing_changed = true;
                            }
                        }
                        const target_mh: f32 = c.max_h orelse std.math.inf(f32);
                        const need_set_h: bool = switch (c.popover.style.height) {
                            .fit => |f| !approxEq(f.max, target_mh),
                            else => true,
                        };
                        if (need_set_h) {
                            c.popover.style.height = .{ .fit = .{ .max = target_mh } };
                            sizing_changed = true;
                        }
                    }
                    // When visible, set overflow_hidden per caller intent (default false; with
                    // clip_subtree=true keep true).
                    const want_overflow_hidden = c.clip_subtree;
                    if (c.popover.style.overflow_hidden != want_overflow_hidden) {
                        c.popover.style.overflow_hidden = want_overflow_hidden;
                        sizing_changed = true;
                    }
                    c.popover.markSizingDirty();
                    c.popover.markInteractionDirty();
                    c.popover.markRenderDirty();
                    c.popover.markCompositeDirty();
                } else {
                    c.cx.overlay_stack.beginExit(c.layer_handle);
                }
                c.cx.needs_redraw = true;
            }
        }.update);

        // on_before_render: position after layout (rect computed correctly by then).
        const position_ctx = try resource_allocator.create(PopoverPositionCtx);
        const effective_anchor: EffectiveAnchor = if (p.anchor) |a| switch (a) {
            .node => |n| .{ .external_node = n },
            .virtual => |v| .{ .virtual = v },
        } else .self_trigger;

        position_ctx.* = .{
            .popover = popover_content,
            .scope = my_scope,
            .trigger_node = trigger_node,
            .effective_anchor = effective_anchor,
            .is_open = is_open,
            .layer_handle = layer_handle,
            .pos = p.position,
            .offset = p.offset,
            .cx = cx,
            .flip = p.flip,
            .shift_main_axis = p.shift_main_axis,
            .fallback_placements = p.fallback_placements,
            .fallback_placements_ptr = p.fallback_placements_ptr,
            .preferred_width = p.width,
            .preferred_max_width = p.max_width,
            .preferred_max_height = p.max_height,
            .match_trigger_width = p.match_trigger_width,
            .constrain_width_to_viewport = p.constrain_width_to_viewport,
            .viewport_padding = p.viewport_padding,
            .active_position = p.position,
            .entry_ready = false,
            .prewarmed_ready = false,
            .is_visible = false,
            .prewarm_hidden_layout = p.prewarm_hidden_layout,
            .mount_ctx = mount_ctx,
            .enter_transition = p.enter_transition,
            .exit_transition = p.exit_transition,
            .avoid_rects_provider = p.avoid_rects_provider,
            .scroll_container = scroll_container_node,
            .clip_subtree_to_chrome = p.clip_subtree_to_chrome,
        };

        my_scope.registerResource(@ptrCast(position_ctx), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const ctx: *PopoverPositionCtx = @ptrCast(@alignCast(ptr));
                alloc.destroy(ctx);
            }
        }.cleanup) catch |err| {
            resource_allocator.destroy(position_ctx);
            return err;
        };
        popover_content.meta.per_frame.hooks.before_render.main = popoverBeforeRender;
        popover_content.meta.per_frame.hooks.slots.anim_state = @ptrCast(position_ctx);

        if (!is_open.peek()) {
            detachPopoverContentIfSuspended(mount_ctx);
        }

        return .{
            .wrapper = wrapper,
            .trigger = trigger_node,
            .content = caller_content_node,
            .chrome = popover_content,
            .open = open_bound.asSignal(),
            .close = core.Cx.simpleHandler(PopoverOpen.hide, open_ctl),
            .show = core.Cx.simpleHandler(PopoverOpen.show, open_ctl),
            .toggle = core.Cx.simpleHandler(PopoverOpen.toggle, open_ctl),
            .open_read = open_bound.read,
            .scope = my_scope,
            .active_position_ptr = &position_ctx.active_position,
            .portaled = false,
        };
    }
};

// ========== Internal helpers ==========

const PopoverCleanupCtx = struct {
    handle: overlay_stack_mod.LayerHandle,
    cx: *Cx,
};

const DetachedContentCtx = struct {
    parent: *Node,
    content: *Node,
    cx: *Cx,
    layer_handle: overlay_stack_mod.LayerHandle,
    detach_hidden_content: bool,
    /// Content on popover_portal_root (not caller subtree), on dispose must manually detach.
    portaled: bool = false,
    /// The open effect has run once (mount); later opens are openings.
    presence_settled: bool = false,
    /// The current open shows at once (no enter transition), see `animate_initial_open`.
    instant_enter: bool = false,
    animate_initial_open: bool = false,
};

fn ensurePopoverContentAttached(ctx: *DetachedContentCtx) void {
    if (!ctx.detach_hidden_content) return;
    if (ctx.content.parent != null) return;
    ctx.parent.appendChild(ctx.cx.allocator, ctx.content) catch return;
    ctx.content.markRuntimeIndexFullRebuild();
    ctx.content.markSizingDirty();
    ctx.content.markRenderDirty();
    ctx.cx.needs_redraw = true;
}

fn detachPopoverContentIfSuspended(ctx: *DetachedContentCtx) void {
    if (!ctx.detach_hidden_content) return;
    if (ctx.content.parent == null) return;
    if (ctx.cx.overlay_stack.findLayer(ctx.layer_handle)) |layer| {
        if (!layer.suspended) return;
    }
    ctx.cx.detachChildRetained(ctx.parent, ctx.content);
    ctx.cx.needs_redraw = true;
}

/// Actual anchor when positioning: node / external node / virtual, pick one.
const EffectiveAnchor = union(enum) {
    /// Default: use trigger_node (Popover's own mount).
    self_trigger,
    /// Caller-provided real Node.
    external_node: *Node,
    /// Virtual anchor.
    virtual: VirtualAnchor,
};

/// on_before_render positioning context.
pub const PopoverPositionCtx = struct {
    popover: *Node,
    scope: *Scope,
    trigger_node: *Node,
    /// Actual anchor for positioning.
    effective_anchor: EffectiveAnchor,
    is_open: Source(bool),
    layer_handle: overlay_stack_mod.LayerHandle,
    pos: PopoverPosition,
    offset: PopoverOffset,
    cx: *Cx,
    flip: bool,
    shift_main_axis: bool = false,
    fallback_placements: []const PopoverPosition = &.{},
    fallback_placements_ptr: ?*[]const PopoverPosition = null,
    preferred_width: ?f32,
    preferred_max_width: ?f32,
    preferred_max_height: ?f32,
    match_trigger_width: bool,
    constrain_width_to_viewport: bool,
    viewport_padding: f32,
    active_position: PopoverPosition,
    entry_ready: bool,
    prewarmed_ready: bool,
    is_visible: bool,
    prewarm_hidden_layout: bool,
    mount_ctx: ?*DetachedContentCtx = null,
    /// The trigger was found freed (traced once under the popover debug switch).
    orphan_reported: bool = false,
    enter_transition: overlay_stack_mod.Transition,
    exit_transition: overlay_stack_mod.Transition,
    /// Each frame fetch 'must-avoid rect list' via it (see PopoverProps.avoid_rects_provider
    /// comment).
    avoid_rects_provider: ?*const fn (cx: *Cx, buf: []floating.Rect) []const floating.Rect = null,
    /// size_policy=.fit_or_scroll nested ScrollArea container (px height = max_height).
    /// When autosize shrinks popover_content, must sync-shrink this; otherwise container
    /// expands by original px beyond chrome.
    scroll_container: ?*Node = null,
    /// Caller's clip_subtree_to_chrome intent; temporarily raised to true when autosize cap
    /// applies.
    clip_subtree_to_chrome: bool = false,
    /// Static translate computed by positioner (no .dropdown transition slide offset).
    /// Exit freeze branch has no fresh positioning, relies on this + current offset to
    /// rewrite translate.
    rest_translate_x: f32 = 0,
    rest_translate_y: f32 = 0,

    /// Current active anchor rect (absolute viewport coordinate).
    pub fn anchorRect(self: *const PopoverPositionCtx) AnchorRect {
        return switch (self.effective_anchor) {
            .self_trigger => blk: {
                const g = self.trigger_node.globalRect();
                // Global hook read rect (fallback to node.rect when epoch==0).
                const r = self.trigger_node.rectFromWorldOrFallback();
                const offset = if (self.cx.windowHeaderOwns(self.trigger_node)) self.cx.window_header_offset else [2]f32{ 0, 0 };
                break :blk .{ .x = g.x + offset[0], .y = g.y + offset[1], .w = r.w, .h = r.h };
            },
            .external_node => |n| blk: {
                const g = n.globalRect();
                const r = n.rectFromWorldOrFallback();
                const offset = if (self.cx.windowHeaderOwns(n)) self.cx.window_header_offset else [2]f32{ 0, 0 };
                break :blk .{ .x = g.x + offset[0], .y = g.y + offset[1], .w = r.w, .h = r.h };
            },
            .virtual => |va| va.getRect(va.ctx),
        };
    }
};

fn isZeroPx(sizing: core.Sizing) bool {
    return switch (sizing) {
        .px => |v| v == 0,
        else => false,
    };
}

fn approxEq(a: f32, b: f32) bool {
    if (std.math.isInf(a) and std.math.isInf(b)) return true;
    return @abs(a - b) <= 0.5;
}

fn sizingPxValue(sizing: core.Sizing) ?f32 {
    return switch (sizing) {
        .px => |v| v,
        else => null,
    };
}

/// .dropdown transition snap-slide into anchor: unseen -6px away opposite direction,
/// track opacity (= transition ease-out progress) to 0. Direction follows actual placement
/// (flip to top -> slide down).
pub const DROPDOWN_SLIDE_PX: f32 = 6;

pub fn dropdownSlideOffset(side: floating.Side, opacity: f32) [2]f32 {
    const d = (1 - std.math.clamp(opacity, 0, 1)) * DROPDOWN_SLIDE_PX;
    return switch (side) {
        .bottom => .{ 0, -d },
        .top => .{ 0, d },
        .right => .{ -d, 0 },
        .left => .{ d, 0 },
    };
}

/// Write positioning result: record static position, add current .dropdown offset
/// (by node's current opacity), and hand the landing direction to the transition controller,
/// which applies the opacity advance for the rest of the same frame incrementally.
fn setPopoverRestTranslate(ctx: *PopoverPositionCtx, x: f32, y: f32) bool {
    ctx.rest_translate_x = x;
    ctx.rest_translate_y = y;
    return applyDropdownSlide(ctx);
}

fn applyDropdownSlide(ctx: *PopoverPositionCtx) bool {
    var x = ctx.rest_translate_x;
    var y = ctx.rest_translate_y;
    const uses_dropdown = ctx.enter_transition == .dropdown or ctx.exit_transition == .dropdown;
    if (uses_dropdown) {
        const unit = dropdownSlideOffset(floating.getSide(ctx.active_position), 0);
        if (ctx.cx.overlay_stack.findLayer(ctx.layer_handle)) |layer| {
            layer.enter_ctrl.slide = unit;
            layer.exit_ctrl.slide = unit;
        }
        const off = dropdownSlideOffset(floating.getSide(ctx.active_position), ctx.popover.getOpacity());
        x += off[0];
        y += off[1];
        // The slide is transient: a composited panel anchors its pixel grid to the rest position.
        if (ctx.popover.style.ext) |ext| ext.motion_offset = off else if (off[0] != 0 or off[1] != 0) {
            ctx.popover.style.ensureExtPanic(ctx.cx.allocator).motion_offset = off;
        }
    }
    return setPopoverTranslate(ctx.popover, x, y);
}

fn setPopoverTranslate(node: *Node, x: f32, y: f32) bool {
    const changed = @abs(node.style.translate_x - x) > 0.01 or @abs(node.style.translate_y - y) > 0.01;
    if (!changed) return false;
    node.style.translate_x = x;
    node.style.translate_y = y;
    // Unified authority invalidation combo (interaction+composite+cache): composite
    // assures surface position updates, cache invalidation assures pre-built display payload
    // not replayed by old position.
    node.markCompositePropDirty();
    return true;
}

fn hiddenWidth(ctx: *const PopoverPositionCtx) core.Sizing {
    return if (ctx.preferred_width) |w| .{ .px = w } else .{ .fit = .{} };
}

pub fn transformOriginForPlacement(pos: PopoverPosition) core.TransformOrigin {
    return switch (pos) {
        .top_start => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 1.0 } },
        .top => .{ .x = .{ .percent = 0.5 }, .y = .{ .percent = 1.0 } },
        .top_end => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 1.0 } },
        .bottom_start => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 0.0 } },
        .bottom => .{ .x = .{ .percent = 0.5 }, .y = .{ .percent = 0.0 } },
        .bottom_end => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 0.0 } },
        .left_start => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 0.0 } },
        .left => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 0.5 } },
        .left_end => .{ .x = .{ .percent = 1.0 }, .y = .{ .percent = 1.0 } },
        .right_start => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 0.0 } },
        .right => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 0.5 } },
        .right_end => .{ .x = .{ .percent = 0.0 }, .y = .{ .percent = 1.0 } },
    };
}

fn syncTransformOriginForPlacement(node: *Node, pos: PopoverPosition, allocator: Allocator) void {
    const next = transformOriginForPlacement(pos);
    const ext = node.style.ensureExtPanic(allocator);
    if (std.meta.eql(ext.transform_origin, next)) return;
    ext.transform_origin = next;
    node.markInteractionDirty();
    node.markCompositeDirty();
}

fn popoverDebugEnabled() bool {
    return @import("zenit_environment").flag("ZENIT_POPOVER_DEBUG");
}

fn popoverContentReady(node: *Node) bool {
    // Global hook read rect.
    const r = node.rectFromWorldOrFallback();
    if (r.w <= 0 or r.h <= 0) return false;
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.core.subtree_layout) return false;
    // Placement only consumes measured geometry. Requiring subtree_render to
    // be clean creates a deadlock for a freshly opened/prewarmed overlay: the
    // hidden subtree cannot finish its first paint until it is positioned and
    // admitted by the overlay stack, while positioning used to wait for that
    // paint. Render dirtiness is safe here because opacity remains hidden until
    // the enter controller commits the positioned frame.
    return true;
}

/// Post-autosize height floor: viewport tight -> never collapse panel to 0 (prefer
/// anchor overlap over unreadable).
pub const AUTOSIZE_MIN_HEIGHT: f32 = 48;

/// Write autosize middleware's available height into popover_content (and fit_or_scroll's
/// ScrollArea container) ext.max_height. Equivalent to floating-ui `size` `maxHeight:
/// availableHeight`. Without autosize data, fall back to the caller cap.
///
/// When the cap really bites content (current height `ph` >= cap), also toggle chrome's
/// overflow_hidden: with the default overflow_hidden=false, content spills past the shell if only
/// chrome is capped and children are not clipped. No cap bite -> restore caller intent.
fn applyAutosizeMaxHeight(ctx: *PopoverPositionCtx, auto_opt: ?floating.AutosizeData, ph: f32) void {
    var target_max_h: f32 = ctx.preferred_max_height orelse std.math.inf(f32);
    if (auto_opt) |auto| {
        if (auto.apply_height) {
            target_max_h = @min(target_max_h, @max(auto.committed_max_height, AUTOSIZE_MIN_HEIGHT));
        }
    }
    const ext = ctx.popover.style.ensureExtPanic(ctx.cx.allocator);
    // ph from prior frame at old max_height layout. When scroll/window changes loosen
    // available height frame-by-frame, old-cap-bitten ph < new target, if just compare new
    // target will turn off clip this frame but content still taller than old cap; next layout
    // reaches new cap, this frame entire content overflows panel (continuous scroll = multiple
    // frame leak). So ph pinned to old cap also counts as cap bite.
    const prev_max_h = ext.max_height;
    if (!approxEq(ext.max_height, target_max_h)) {
        ext.max_height = target_max_h;
        ctx.popover.markSizingDirty();
    }
    const cap_binding = (!std.math.isInf(target_max_h) and ph >= target_max_h - 0.5) or
        (!std.math.isInf(prev_max_h) and ph >= prev_max_h - 0.5);
    const want_clip = ctx.clip_subtree_to_chrome or cap_binding;
    var clip_changed = false;
    if (ctx.popover.style.overflow_hidden != want_clip) {
        ctx.popover.style.overflow_hidden = want_clip;
        clip_changed = true;
    }
    // Clip shape follows chrome's radius (.auto -> rounded_rect from border.radius), so a caller
    // changing the panel radius auto-matches.
    // The surface owner's overflow clip applies to children only (node-local SDF push_clip,
    // padding-box inner) with no rounded_clip layer, so no rect-clip workaround is needed here
    // (a rect clip would cut the shadow into a gray block past the radius and pin edge strokes).
    // A caller that explicitly wants clip_subtree_to_chrome keeps its own shape unchanged.
    if (!ctx.clip_subtree_to_chrome) {
        if (std.meta.activeTag(ext.clip_shape) != .auto) {
            ext.clip_shape = .auto;
            clip_changed = true;
        }
    }
    if (clip_changed) {
        ctx.popover.markSizingDirty();
        ctx.popover.markInteractionDirty();
        ctx.popover.markRenderDirty();
        ctx.popover.markCompositeDirty();
    }
    if (ctx.scroll_container) |sc| {
        const sc_ext = sc.style.ensureExtPanic(ctx.cx.allocator);
        if (!approxEq(sc_ext.max_height, target_max_h)) {
            sc_ext.max_height = target_max_h;
            sc.markSizingDirty();
        }
    }
}

pub fn popoverBeforeRender(node: *Node) void {
    const ctx: *PopoverPositionCtx = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    // The trigger lives in the caller's subtree and can be freed before the Popover's scope is
    // disposed: a scope disposal requested inside a reactive callback is deferred, while the
    // subtree's nodes may already be gone, and a frame can run in between (zeditor rebuilding a
    // blockquote citation row under its tooltips). Never dereference the freed trigger (the
    // stack's generation-checked handle tells): close the layer until the scope disposal lands.
    if (ctx.cx.overlay_stack.findLayer(ctx.layer_handle)) |layer| {
        // A layer pushed without a trigger has nothing to lose.
        if (layer.trigger_node != null and ctx.cx.overlay_stack.resolveTrigger(layer) == null) {
            if (popoverDebugEnabled() and !ctx.orphan_reported) {
                ctx.orphan_reported = true;
                std.debug.print("[popover] trigger freed before the scope disposal (content test_id={s})\n", .{ctx.popover.meta.ownership.meta.test_id orelse "(nil)"});
            }
            if (!layer.suspended and layer.state != .exiting) ctx.cx.overlay_stack.beginExit(ctx.layer_handle);
            return;
        }
    }
    const overlay_visual_in_progress = ctx.popover.frame_state.state_bits.flags.manual_opacity_animation_active or
        ctx.popover.frame_state.state_bits.flags.manual_transform_animation_active or
        ((ctx.popover.getOpacity() > (HIDDEN_OPACITY + 0.0001) and ctx.popover.getOpacity() < 0.999) or
            @abs(ctx.popover.style.scale_x() - 1.0) > 0.0001 or
            @abs(ctx.popover.style.scale_y() - 1.0) > 0.0001);
    if (!ctx.is_open.peek()) {
        if (ctx.mount_ctx) |mount_ctx| {
            if (ctx.cx.overlay_stack.findLayer(ctx.layer_handle)) |layer| {
                if (layer.suspended) {
                    // An exit with `.none` commits synchronously, so this can
                    // be the first closed-frame callback. Reset placement
                    // readiness before detaching; otherwise reopen skips the
                    // entry-ready branch and retains commitExit's opacity=0.
                    ctx.active_position = ctx.pos;
                    ctx.entry_ready = false;
                    ctx.is_visible = false;
                    if (!ctx.prewarm_hidden_layout) ctx.prewarmed_ready = false;
                    detachPopoverContentIfSuspended(mount_ctx);
                    return;
                }
            }
        }
        if (popoverDebugEnabled()) {
            const exit_rect_pre = ctx.popover.globalRect();
            std.debug.print("[popover-exit] tid={s} stage=enter_branch rect=({d:.0},{d:.0},{d:.0}x{d:.0}) trans=({d:.1},{d:.1}) op={d:.3} scale=({d:.3},{d:.3}) anim_op={} anim_tf={} prewarm={}\n", .{
                ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                exit_rect_pre.x,
                exit_rect_pre.y,
                exit_rect_pre.w,
                exit_rect_pre.h,
                ctx.popover.style.translate_x,
                ctx.popover.style.translate_y,
                ctx.popover.getOpacity(),
                ctx.popover.style.scale_x(),
                ctx.popover.style.scale_y(),
                ctx.popover.frame_state.state_bits.flags.manual_opacity_animation_active,
                ctx.popover.frame_state.state_bits.flags.manual_transform_animation_active,
                ctx.prewarm_hidden_layout,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, false, ctx.cx.allocator);
        ctx.entry_ready = false;
        ctx.is_visible = false;
        // During an exit transition OR while a visible remnant remains, don't reset
        // translate/scale;
        // else the popover flies to (0,0) then finishes fading in place, leaving a top-left ghost.
        // Criteria: (a) overlay_stack hung manual flag; (b) opacity > HIDDEN_OPACITY (still
        // visible); (c) scale not in hidden silent state. Any true -> cede this frame to
        // TransitionController and let it finish the fade.
        const exit_hidden_scale = overlay_stack_mod.TransitionController.hiddenScaleForTransition(ctx.exit_transition);
        const popup_still_visible = ctx.popover.getOpacity() > (HIDDEN_OPACITY + 0.0001) or
            @abs(ctx.popover.style.scale_x() - exit_hidden_scale) > 0.001 or
            @abs(ctx.popover.style.scale_y() - exit_hidden_scale) > 0.001;
        // The exit leaves from where the popover is placed: a flipped (top) popover keeps its side,
        // so the dropdown slide and the scale origin point at its anchor. Placement resets once
        // the exit has finished.
        if (!(overlay_visual_in_progress or popup_still_visible)) {
            ctx.active_position = ctx.pos;
            syncTransformOriginForPlacement(ctx.popover, ctx.active_position, ctx.cx.allocator);
        }
        if (overlay_visual_in_progress or popup_still_visible) {
            // During exit, positioner doesn't run: pass landing direction to exit controller, it
            // same-frame push slide-out.
            if (ctx.exit_transition == .dropdown) _ = applyDropdownSlide(ctx);
            if (popoverDebugEnabled()) {
                std.debug.print("[popover-exit] tid={s} stage=transition_freeze visual_in_prog={} still_visible={} op={d:.3}\n", .{
                    ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                    overlay_visual_in_progress,
                    popup_still_visible,
                    ctx.popover.getOpacity(),
                });
            }
            ctx.popover.markInteractionDirty();
            ctx.cx.needs_redraw = true;
            return;
        }
        if (!ctx.prewarm_hidden_layout) {
            ctx.prewarmed_ready = false;
            var interaction_changed = false;
            const collapsed = isZeroPx(ctx.popover.style.width) and isZeroPx(ctx.popover.style.height) and ctx.popover.style.overflow_hidden;
            if (!collapsed or ctx.popover.getOpacity() != 0 or ctx.popover.style.translate_x != 0 or ctx.popover.style.translate_y != 0) {
                if (popoverDebugEnabled()) {
                    std.debug.print("[popover-exit] tid={s} stage=reset_no_prewarm trans_was=({d:.1},{d:.1}) op_was={d:.3}\n", .{
                        ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                        ctx.popover.style.translate_x,
                        ctx.popover.style.translate_y,
                        ctx.popover.getOpacity(),
                    });
                }
                ctx.popover.style.width = .{ .px = 0 };
                ctx.popover.style.height = .{ .px = 0 };
                ctx.popover.style.overflow_hidden = true;
                ctx.popover.setOpacityRaw(0);
                interaction_changed = setPopoverTranslate(ctx.popover, 0, 0);
                ctx.popover.markSizingDirty();
                ctx.popover.markSubtreeDirty();
                ctx.popover.markRenderDirty();
            }
            // Global hook read rect.
            const pr = ctx.popover.rectFromWorldOrFallback();
            if (pr.w != 0 or pr.h != 0) {
                ctx.popover.markSizingDirty();
                ctx.popover.markSubtreeDirty();
                ctx.cx.needs_redraw = true;
            }
            if (interaction_changed) ctx.cx.needs_redraw = true;
            return;
        }
        var sizing_changed = false;
        var visual_changed = false;
        var interaction_changed = false;
        const hidden_scale = overlay_stack_mod.TransitionController.hiddenScaleForTransition(ctx.enter_transition);
        const target_width = hiddenWidth(ctx);
        const width_needs_restore = switch (target_width) {
            .fit => isZeroPx(ctx.popover.style.width),
            .px => |w| if (sizingPxValue(ctx.popover.style.width)) |current| !approxEq(current, w) else true,
            else => true,
        };
        const height_needs_restore = isZeroPx(ctx.popover.style.height);
        if (width_needs_restore or height_needs_restore or ctx.popover.style.overflow_hidden) {
            ctx.popover.style.width = target_width;
            ctx.popover.style.height = .{ .fit = .{} };
            ctx.popover.style.overflow_hidden = false;
            sizing_changed = true;
        }
        if (ctx.popover.getOpacity() != HIDDEN_OPACITY or ctx.popover.style.scale_x() != hidden_scale or ctx.popover.style.scale_y() != hidden_scale or sizing_changed) {
            if (popoverDebugEnabled()) {
                std.debug.print("[popover-exit] tid={s} stage=reset_prewarm trans_was=({d:.1},{d:.1}) op_was={d:.3} sizing_changed={}\n", .{
                    ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                    ctx.popover.style.translate_x,
                    ctx.popover.style.translate_y,
                    ctx.popover.getOpacity(),
                    sizing_changed,
                });
            }
            ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
            interaction_changed = setPopoverTranslate(ctx.popover, 0, 0);
            const ext = ctx.popover.style.ensureExtPanic(ctx.cx.allocator);
            ext.scale_x = hidden_scale;
            ext.scale_y = hidden_scale;
            visual_changed = true;
            if (sizing_changed) {
                ctx.popover.markSizingDirty();
                ctx.popover.markSubtreeDirty();
            }
            ctx.popover.markRenderDirty();
        }
        // Global hook read rect.
        const pr2 = ctx.popover.rectFromWorldOrFallback();
        if (!sizing_changed and (pr2.w == 0 or pr2.h == 0)) {
            ctx.popover.markSizingDirty();
            ctx.popover.markSubtreeDirty();
            ctx.cx.needs_redraw = true;
        }
        if (interaction_changed) ctx.cx.needs_redraw = true;
        ctx.prewarmed_ready = !sizing_changed and !visual_changed and popoverContentReady(ctx.popover);
        return;
    }

    const anchor_rect = ctx.anchorRect();
    // Anchor invalidation signal: caller explicitly marks 'invalid' with
    // ANCHOR_OFFSCREEN_SENTINEL (convention x/y < -1e5). Note: cursor-like anchor legally
    // returns w=0 h=0 (virtual zero-width point), can't deem w/h=0 as invalid.
    const anchor_valid = anchor_rect.x > -1.0e5 and anchor_rect.y > -1.0e5;
    if (!anchor_valid) {
        if (popoverDebugEnabled()) {
            const popover_rect_inv = ctx.popover.globalRect();
            std.debug.print("[popover-inv] tid={s} pop_rect=({d:.0},{d:.0},{d:.0}x{d:.0}) trans=({d:.0},{d:.0}) op={d:.3} entry_ready={}\n", .{
                ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                popover_rect_inv.x,
                popover_rect_inv.y,
                popover_rect_inv.w,
                popover_rect_inv.h,
                ctx.popover.style.translate_x,
                ctx.popover.style.translate_y,
                ctx.popover.getOpacity(),
                ctx.entry_ready,
            });
        }
        if (ctx.entry_ready) {
            // Had valid positioning -> freeze prior frame translate (natural fade, don't fly back
            // to origin).
            ctx.popover.markInteractionDirty();
        } else {
            // Never positioned + anchor invalid -> force fully transparent (opacity 0, not HIDDEN_OPACITY).
            // HIDDEN_OPACITY=0.001 prewarm strategy: positioned popup maintains measurement but
            // visual hidden. But this path popup translate default (0,0), layout still computes
            // normal
            // rect, opacity=0.001 GPU blend visible -> top-left ghost. Use 0 to never render.
            ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
            if (ctx.popover.getOpacity() != 0) {
                ctx.popover.setOpacityRaw(0);
                ctx.popover.markInteractionDirty();
                ctx.popover.markRenderDirty();
                ctx.cx.needs_redraw = true;
            }
        }
        return;
    }
    const tw = anchor_rect.w;
    const th = anchor_rect.h;
    const pop_local_rect = ctx.popover.rectFromWorldOrFallback();
    const pw = pop_local_rect.w;
    const ph = pop_local_rect.h;
    if (pw == 0 or ph == 0) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] pause zero-rect match_trigger_width={} preferred_width={any} rect=({d:.1},{d:.1}) prewarmed={} entry_ready={}\n", .{
                ctx.match_trigger_width,
                ctx.preferred_width,
                pw,
                ph,
                ctx.prewarmed_ready,
                ctx.entry_ready,
            });
        }
        // Entered popover temporarily hit zero-rect (caller cleared children -> reflow) don't
        // force HIDDEN_OPACITY; else popover never recovered. Framework 'show again' path only
        // runs entry_ready=false (line 1054-1072). When entered, keep opacity, next layout
        // complete seamlessly show new content.
        if (ctx.entry_ready) {
            ctx.cx.needs_redraw = true;
            return;
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
        // Never positioned + zero-rect -> force fully transparent (0, not HIDDEN_OPACITY=0.001).
        // 0.001 GPU blend still visible -> eye sees top-left (0,0) popup gray bar ghost (same
        // Phase 3 fix).
        if (ctx.popover.getOpacity() != 0) {
            ctx.popover.setOpacityRaw(0);
            ctx.popover.markInteractionDirty();
            ctx.popover.markRenderDirty();
            ctx.cx.needs_redraw = true;
        }
        return;
    }
    const content_ready = popoverContentReady(ctx.popover);
    const can_use_prewarmed_content = ctx.prewarm_hidden_layout and ctx.prewarmed_ready and content_ready;
    if (!ctx.entry_ready and !can_use_prewarmed_content and (ctx.popover.frame_state.state_bits.dirty.core.layout or ctx.popover.frame_state.state_bits.dirty.core.subtree_layout)) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] pause unstable-layout match_trigger_width={} preferred_width={any} rect=({d:.1},{d:.1}) dirty(l={},s={},r={}) prewarmed={}\n", .{
                ctx.match_trigger_width,
                ctx.preferred_width,
                pw,
                ph,
                ctx.popover.frame_state.state_bits.dirty.core.layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_render,
                ctx.prewarmed_ready,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
        ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
        ctx.cx.needs_redraw = true;
        return;
    }
    if (!ctx.entry_ready and !can_use_prewarmed_content and !overlay_visual_in_progress and !content_ready) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] pause not-ready match_trigger_width={} preferred_width={any} rect=({d:.1},{d:.1}) dirty(l={},s={},r={}) prewarmed={}\n", .{
                ctx.match_trigger_width,
                ctx.preferred_width,
                pw,
                ph,
                ctx.popover.frame_state.state_bits.dirty.core.layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_layout,
                ctx.popover.frame_state.state_bits.dirty.core.subtree_render,
                ctx.prewarmed_ready,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
        ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
        ctx.cx.needs_redraw = true;
        return;
    }

    const trigger_abs_x = anchor_rect.x;
    const trigger_abs_y = anchor_rect.y;

    // Fold cx.safe_area_* insets into viewport for floating-ui middleware. Viewport
    // receives 'safe displayable rect', flip/shift/autosize all compute overflow by this,
    // auto-avoid title bar/tab bar/status bar.
    const safe_top = ctx.cx.safe_area_top;
    const safe_left = ctx.cx.safe_area_left;
    const vp_x: f32 = safe_left;
    const vp_y: f32 = safe_top;
    const vp_w = @max(@as(f32, 0), ctx.cx.viewport.width - safe_left - ctx.cx.safe_area_right);
    const vp_h = @max(@as(f32, 0), ctx.cx.viewport.height - safe_top - ctx.cx.safe_area_bottom);

    var middleware_buf: [5]floating.Middleware = undefined;
    var middleware_count: usize = 0;
    middleware_buf[middleware_count] = .{ .offset = .{ .main_axis = ctx.offset } };
    middleware_count += 1;
    if (ctx.flip) {
        const effective_fallbacks: []const PopoverPosition = if (ctx.fallback_placements_ptr) |ptr|
            ptr.*
        else
            ctx.fallback_placements;
        middleware_buf[middleware_count] = .{ .flip = .{ .fallback_placements = effective_fallbacks, .padding = ctx.viewport_padding } };
        middleware_count += 1;
    }
    middleware_buf[middleware_count] = .{ .shift = .{ .main_axis = ctx.shift_main_axis, .cross_axis = true, .padding = ctx.viewport_padding } };
    middleware_count += 1;
    if (ctx.match_trigger_width or ctx.constrain_width_to_viewport or ctx.preferred_max_width != null) {
        middleware_buf[middleware_count] = .{ .size = .{ .padding = ctx.viewport_padding } };
        middleware_count += 1;
    }
    // autosize (= floating-ui `size` availableHeight -> max-height) **always** participates:
    // after flip/shift settle the final placement, take that placement's remaining viewport height
    // as the popover_content max_height cap (a caller-set max_height takes the min). It must not be
    // gated on caller max_height: an unset popover that fits on neither side keeps full height,
    // and best-fit only shuffles translate without remeasuring, squashing the reference element.
    // Consumption: only change ext.max_height + markSizingDirty, applied naturally next layout;
    // **don't trigger needs_remeasure** (forced remeasure leaves the popup eternally paused).
    middleware_buf[middleware_count] = .{ .autosize = .{ .padding = ctx.viewport_padding, .apply_width = false } };
    middleware_count += 1;

    const anchor_rect_pos = floating.Rect.init(trigger_abs_x, trigger_abs_y, tw, th);
    const popover_rect_pos = floating.Rect.init(0, 0, pw, ph);
    const viewport_rect_pos = floating.Rect.init(vp_x, vp_y, vp_w, vp_h);

    // Collect avoid_rects (e.g. signature avoid completion/docs chrome rect): caller
    // provides provider fn, call once per frame. No provider -> empty slice.
    var avoid_buf: [8]floating.Rect = undefined;
    const excluded_slice: []const floating.Rect = if (ctx.avoid_rects_provider) |provider|
        provider(ctx.cx, &avoid_buf)
    else
        &.{};

    const positioned = floating.computePosition(
        anchor_rect_pos,
        popover_rect_pos,
        viewport_rect_pos,
        .{
            .placement = ctx.pos,
            .middleware = middleware_buf[0..middleware_count],
            .excluded_rects = excluded_slice,
        },
    );
    // autosize drives max_height soft tighten (no remeasure, see middleware comment).
    // layout_engine fit/grow intrinsic clamp already fuses sizing.max and ext.max_height via
    // effectiveMinMax (take min); px children also clamp by ext.max_height -> just update
    // ext.max_height here, layout next frame naturally clamps by fused max.
    applyAutosizeMaxHeight(ctx, positioned.middleware_data.autosize, ph);

    if (ctx.match_trigger_width or ctx.constrain_width_to_viewport or ctx.preferred_max_width != null) {
        var needs_remeasure = false;
        var target_width: ?f32 = null;
        if (ctx.match_trigger_width) {
            target_width = tw;
        } else if (ctx.preferred_width) |w| {
            target_width = w;
        }

        if (ctx.constrain_width_to_viewport) {
            if (positioned.middleware_data.size) |size_data| {
                if (target_width) |w| {
                    target_width = @min(w, size_data.available_width);
                }
            }
        }

        if (target_width) |w| {
            if (sizingPxValue(ctx.popover.style.width)) |current| {
                if (!approxEq(current, w)) {
                    ctx.popover.style.width = .{ .px = w };
                    needs_remeasure = true;
                }
            } else {
                ctx.popover.style.width = .{ .px = w };
                needs_remeasure = true;
            }
        }

        const ext = ctx.popover.style.ensureExtPanic(ctx.cx.allocator);
        var target_max_width = ctx.preferred_max_width orelse std.math.inf(f32);
        if (ctx.constrain_width_to_viewport) {
            if (positioned.middleware_data.size) |size_data| {
                target_max_width = @min(target_max_width, size_data.available_width);
            }
        }

        if (std.math.isInf(target_max_width)) {
            if (!std.math.isInf(ext.max_width)) {
                ext.max_width = std.math.inf(f32);
                needs_remeasure = true;
            }
        } else if (!approxEq(ext.max_width, target_max_width)) {
            const popover_w = ctx.popover.rectFromWorldOrFallback().w;
            const current_within_new_cap = popover_w > 0 and popover_w <= target_max_width + 0.5;
            ext.max_width = target_max_width;
            needs_remeasure = !current_within_new_cap;
        }

        if (needs_remeasure) {
            if (popoverDebugEnabled()) {
                std.debug.print("[popover] pause remeasure match_trigger_width={} preferred_width={any} target_width={any} max_width={d:.1}\n", .{
                    ctx.match_trigger_width,
                    ctx.preferred_width,
                    target_width,
                    ctx.popover.style.max_width(),
                });
            }
            ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, true, ctx.cx.allocator);
            ctx.popover.setOpacityRaw(HIDDEN_OPACITY);
            ctx.prewarmed_ready = false;
            ctx.popover.markSizingDirty();
            ctx.popover.markSubtreeDirty();
            ctx.cx.needs_redraw = true;
            return;
        }
    }

    // Phase 4: best-fit. popup must 'stick anchor top/bottom', must not exceed cx safe area.
    const pad = ctx.viewport_padding;
    const final_side = floating.getSide(positioned.placement);
    // Resolve final main-axis offset using final placement (derivable different per side).
    const final_offset_main: f32 = ctx.offset.resolve(.{
        .placement = positioned.placement,
        .reference = floating.Rect.init(trigger_abs_x, trigger_abs_y, tw, th),
        .floating = floating.Rect.init(0, 0, pw, ph),
    });
    var available_h: f32 = vp_h;
    var ph_eff: f32 = ph;
    if (final_side == .top or final_side == .bottom) {
        available_h = if (final_side == .top)
            @max(0, trigger_abs_y - vp_y - pad - final_offset_main)
        else
            @max(0, (vp_y + vp_h) - (trigger_abs_y + th) - pad - final_offset_main);
        // Note: best-fit must not change popup_content.style.height; changing height triggers
        // markSizingDirty -> overlay_stack.holdEnterUntilGeometryStable freezes the enter
        // transition
        // at progress=0 -> opacity stays HIDDEN_OPACITY -> popup never shows. Real best-fit
        // only adjusts ph_eff so translate.y is computed right; **don't** touch layout.
        // popup_content's own fit{max} already clamps height (content past max stops expanding).
        if (ph > available_h and available_h > 48 and ctx.entry_ready) {
            ph_eff = available_h;
        }
    }

    // Recompute translate.y with ph_eff (top/bottom side only).
    var positioned_y = positioned.y;
    if (final_side == .top) {
        positioned_y = trigger_abs_y - ph_eff - final_offset_main;
    } else if (final_side == .bottom) {
        positioned_y = trigger_abs_y + th + final_offset_main;
    }

    var clamped_x = positioned.x;
    if (clamped_x < vp_x + pad) clamped_x = vp_x + pad;
    if (clamped_x + pw > vp_x + vp_w - pad) clamped_x = @max(vp_x + pad, vp_x + vp_w - pad - pw);

    // translate is popover_content's offset relative to the wrapper (its parent). It must use the
    // wrapper's global coordinate, not `trigger_abs_x` (= anchor.x): those coincide for click/hover
    // triggers (trigger_node fills the wrapper) but are unrelated for VirtualAnchor (cursor
    // anchor).
    const wrapper_node = ctx.popover.parent orelse {
        ctx.active_position = positioned.placement;
        _ = setPopoverRestTranslate(ctx, clamped_x - trigger_abs_x, positioned_y - trigger_abs_y);
        return;
    };
    const wrapper_rect = wrapper_node.globalRect();
    ctx.active_position = positioned.placement;
    _ = setPopoverRestTranslate(ctx, clamped_x - wrapper_rect.x, positioned_y - wrapper_rect.y);
    if (popoverDebugEnabled()) {
        const popover_rect = ctx.popover.globalRect();
        std.debug.print("[popover-pos] tid={s} wrap=({d:.0},{d:.0},{d:.0}x{d:.0}) pop_rect=({d:.0},{d:.0},{d:.0}x{d:.0}) trans=({d:.0},{d:.0}) anchor=({d:.0},{d:.0},{d:.0}x{d:.0}) op={d:.3} entry_ready={} side={s}\n", .{
            ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
            wrapper_rect.x,
            wrapper_rect.y,
            wrapper_rect.w,
            wrapper_rect.h,
            popover_rect.x,
            popover_rect.y,
            popover_rect.w,
            popover_rect.h,
            ctx.popover.style.translate_x,
            ctx.popover.style.translate_y,
            anchor_rect.x,
            anchor_rect.y,
            anchor_rect.w,
            anchor_rect.h,
            ctx.popover.getOpacity(),
            ctx.entry_ready,
            @tagName(final_side),
        });
    }
    ctx.active_position = positioned.placement;
    syncTransformOriginForPlacement(ctx.popover, ctx.active_position, ctx.cx.allocator);

    if (!ctx.entry_ready) {
        if (popoverDebugEnabled()) {
            std.debug.print("[popover] enter ready node={d} test_id={s} match_trigger_width={} preferred_width={any} prewarmed={} translate=({d:.1},{d:.1}) size=({d:.1},{d:.1})\n", .{
                ctx.popover.id,
                ctx.popover.meta.ownership.meta.test_id orelse "(nil)",
                ctx.match_trigger_width,
                ctx.preferred_width,
                can_use_prewarmed_content,
                ctx.popover.style.translate_x,
                ctx.popover.style.translate_y,
                pw,
                ph,
            });
        }
        ctx.cx.overlay_stack.setEnterPaused(ctx.layer_handle, false, ctx.cx.allocator);
        // `.none` layers (and an instant initial open) enter the overlay stack
        // directly in `.visible`, so there is no TransitionController tick to
        // restore the opacity (and hidden prewarm scale) that
        // commitExit set to zero. Once geometry is ready, make the content
        // atomically visible here. Animated transitions keep ownership of
        // opacity in the overlay controller.
        if ((ctx.enter_transition == .none or (if (ctx.mount_ctx) |m| m.instant_enter else false)) and
            (ctx.popover.getOpacity() != 1 or ctx.popover.style.scale_x() != 1 or ctx.popover.style.scale_y() != 1))
        {
            ctx.popover.setOpacityRaw(1);
            if (ctx.popover.style.scale_x() != 1 or ctx.popover.style.scale_y() != 1) {
                const ext = ctx.popover.style.ensureExtPanic(ctx.cx.allocator);
                ext.scale_x = 1;
                ext.scale_y = 1;
            }
            // Positioning added the hidden dropdown offset (it tracks opacity): land at rest now,
            // or the first opaque frame sits 6 px off and jumps on the next.
            _ = applyDropdownSlide(ctx);
            ctx.popover.markCompositeAnimFrameDirty();
            ctx.popover.markRenderDirty();
            ctx.cx.needs_redraw = true;
        }
        ctx.entry_ready = true;
        ctx.prewarmed_ready = false;
        ctx.is_visible = true;
    }
}

// ========== Flip positioning algorithm (see floating-ui/flip) ==========

pub fn computeOverflow(
    pos: PopoverPosition,
    trig_x: f32,
    trig_y: f32,
    tw: f32,
    th: f32,
    pw: f32,
    ph: f32,
    off: f32,
    vp_w: f32,
    vp_h: f32,
) [4]f32 {
    const overflow = floating.computeOverflow(
        pos,
        floating.Rect.init(trig_x, trig_y, tw, th),
        floating.Rect.init(0, 0, pw, ph),
        floating.Rect.init(0, 0, vp_w, vp_h),
        off,
        0,
    );
    return .{ overflow.top, overflow.right, overflow.bottom, overflow.left };
}

pub fn flipPlacement(
    preferred: PopoverPosition,
    trig_x: f32,
    trig_y: f32,
    tw: f32,
    th: f32,
    pw: f32,
    ph: f32,
    off: f32,
    vp_w: f32,
    vp_h: f32,
) PopoverPosition {
    return floating.flipPlacement(
        preferred,
        floating.Rect.init(trig_x, trig_y, tw, th),
        floating.Rect.init(0, 0, pw, ph),
        floating.Rect.init(0, 0, vp_w, vp_h),
        off,
        0,
    );
}

// Extracted unit tests (tests.zig, was popover_test.zig). Must explicitly import:
// refAllDecls won't auto-discover unreferenced test files, omit this = silent lose 18
// tests.
test {
    _ = @import("tests.zig");
}

// styles.zig test collection, this line required, see docs/STYLING.md.
test {
    _ = @import("styles.zig");
}

test "Popover: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("popover", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Popover(.{}).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
