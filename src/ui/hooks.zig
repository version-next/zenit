/// UI Hooks - reusable interaction state hooks. Eliminate repeated Signal
/// + simpleHandler + Effect boilerplate in components. Each hook
/// encapsulates common interaction pattern. Usage: `const is_hovered = try
/// hooks.useHover(scope, node);`
const std = @import("std");
const core = @import("core.zig");
const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const Signal = core.Signal;
const Scope = core.Scope;
const createEffect = core.createEffect;
const animation = @import("animation/mod.zig");
const AnimatedColor = animation.AnimatedColor;
const events = @import("events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const focus_mod = @import("focus.zig");
const FocusManager = focus_mod.FocusManager;
const HandlerRef = core.HandlerRef;

/// One subscription per scope; all subscriptions share the node's hover event.
/// A linked list permits either scope to detach first without retaining its signal.
const HoverListener = struct {
    node: ?*Node,
    next: ?*HoverListener,
    signal: *Signal(bool),
    scope: *Scope,
    owner: *core.SignalOwner,
    on_hover: ?HandlerRef,
    on_leave: ?HandlerRef,
    queued: if (@import("zenit_environment").dev_preview) bool else void = if (@import("zenit_environment").dev_preview) false else {},

    fn head(node: *Node) ?*HoverListener {
        const ptr = node.meta.per_frame.hooks.slots.hover_listeners orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn publish(node: *Node, listener: ?*HoverListener, enter: ?HandlerRef, leave: ?HandlerRef) void {
        node.meta.per_frame.hooks.slots.hover_listeners = listener;
        node.behavior.events.on_hover = if (listener) |l| Cx.simpleHandler(onEnter, l) else enter;
        node.behavior.events.on_leave = if (listener) |l| Cx.simpleHandler(onLeave, l) else leave;
    }

    fn pendingHead(node: *Node) ?*HoverListener {
        if (comptime !@import("zenit_environment").dev_preview) return null;
        const ptr = node.meta.per_frame.hooks.slots.preview_hover_pending orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn unqueue(self: *HoverListener) void {
        if (comptime !@import("zenit_environment").dev_preview) return;
        const node = self.node orelse return;
        const first = pendingHead(node) orelse return;
        if (first == self) {
            node.meta.per_frame.hooks.slots.preview_hover_pending = if (self.next) |next| @ptrCast(next) else null;
        } else {
            var cursor = first;
            while (cursor.next) |next| : (cursor = next) {
                if (next == self) {
                    cursor.next = self.next;
                    break;
                }
            }
        }
        self.queued = false;
        self.next = null;
    }

    fn detach(self: *HoverListener) void {
        const node = self.node orelse return;
        node.removeDebugSignal(@ptrCast(self.signal));
        if (comptime @import("zenit_environment").dev_preview) if (self.queued) {
            self.unqueue();
            self.node = null;
            return;
        };
        const first = head(node) orelse return;
        if (first == self) {
            // Even release builds must not overwrite a later direct writer on cleanup.
            const enter_owned = ownsHandler(node.behavior.events.on_hover, self, true);
            const leave_owned = ownsHandler(node.behavior.events.on_leave, self, false);
            const enter = node.behavior.events.on_hover;
            const leave = node.behavior.events.on_leave;
            publish(node, self.next, self.on_hover, self.on_leave);
            if (!enter_owned) node.behavior.events.on_hover = enter;
            if (!leave_owned) node.behavior.events.on_leave = leave;
        } else {
            var current = first;
            while (current.next) |next| {
                if (next == self) {
                    current.next = self.next;
                    break;
                }
                current = next;
            }
        }
        self.node = null;
    }

    fn dispatch(self: *HoverListener, hovered: bool) void {
        const node = self.node orelse return;
        if (node.freeing or node.pending_free_cx != null) return;
        assertHoverHandlers(node);
        const owner = self.owner;
        // Signal effects and user callbacks may remove this node. Keep every
        // subscription alive through dispatch, and publish all hover states together.
        owner.beginReactiveCallback();
        defer owner.endReactiveCallback();
        owner.beginBatch();
        defer owner.endBatch();
        const callback = if (hovered) self.on_hover else self.on_leave;
        var cursor: ?*HoverListener = self;
        var active = false;
        while (cursor) |listener| {
            if (!listener.scope.willBeDisposedAfterReactiveCallback()) {
                active = true;
                listener.signal.set(hovered);
            }
            cursor = listener.next;
        }
        if (active) {
            if (callback) |handler| handler.invoke();
        }
    }
    fn onEnter(raw: *anyopaque) void {
        const self: *HoverListener = @ptrCast(@alignCast(raw));
        self.dispatch(true);
    }
    fn onLeave(raw: *anyopaque) void {
        const self: *HoverListener = @ptrCast(@alignCast(raw));
        self.dispatch(false);
    }
};

fn ownsHandler(handler: ?HandlerRef, listener: *HoverListener, comptime enter: bool) bool {
    const h = handler orelse return false;
    return h.context == @as(*anyopaque, @ptrCast(listener)) and
        h.callback == (if (enter) HoverListener.onEnter else HoverListener.onLeave) and h.payload_callback == null;
}

/// Direct writes to hover event slots after subscribing are a programming error.
/// Called before native dispatch too: replacing the dispatcher cannot hide the violation.
pub fn hoverHandlersIntact(node: *Node) bool {
    const first = HoverListener.head(node) orelse return true;
    return ownsHandler(node.behavior.events.on_hover, first, true) and
        ownsHandler(node.behavior.events.on_leave, first, false);
}

pub fn assertHoverHandlers(node: *Node) void {
    std.debug.assert(hoverHandlersIntact(node));
}

/// Set the public callback without replacing internal hover subscriptions.
pub fn setHoverHandler(node: *Node, comptime enter: bool, handler: ?HandlerRef) void {
    assertHoverHandlers(node);
    var cursor = HoverListener.head(node);
    if (cursor == null) {
        if (enter) node.behavior.events.on_hover = handler else node.behavior.events.on_leave = handler;
        return;
    }
    while (cursor) |listener| {
        if (enter) listener.on_hover = handler else listener.on_leave = handler;
        cursor = listener.next;
    }
}

/// Append hover Signal to node (Scope manages lifetime), preserve user
/// callback and existing hooks.
pub fn useHover(scope: *Scope, node: *Node) !*Signal(bool) {
    assertHoverHandlers(node);
    const previous = HoverListener.head(node);
    if (previous) |p| {
        if (p.owner != scope.owner) return error.HoverOwnerMismatch;
    }
    const is_hovered = try scope.createSignal(bool, if (previous) |p| p.signal.peek() else false);
    const listener = try scope.createState(HoverListener, .{
        .node = node,
        .next = previous,
        .signal = is_hovered,
        .scope = scope,
        .owner = scope.owner,
        .on_hover = if (previous) |p| p.on_hover else node.behavior.events.on_hover,
        .on_leave = if (previous) |p| p.on_leave else node.behavior.events.on_leave,
    });
    try scope.onCleanup(HoverListener, listener, HoverListener.detach);
    if (comptime @import("zenit_environment").dev_preview) if (@import("preview_mount.zig").current != null) {
        // Track only invalidation on the private candidate node. This list has
        // no event dispatcher and is not an active hover subscription.
        listener.queued = true;
        listener.next = HoverListener.pendingHead(node);
        node.meta.per_frame.hooks.slots.preview_hover_pending = @ptrCast(listener);
        _ = try @import("preview_mount.zig").deferAction(scope, .subscription, listener, struct {
            fn attach(l: *HoverListener, _: *Scope) anyerror!void {
                const n = l.node orelse return;
                l.unqueue();
                // Earlier queued subscriptions have now published. Chain in mount
                // order rather than retaining the candidate-time list head.
                assertHoverHandlers(n);
                l.next = HoverListener.head(n);
                if (l.next) |p| if (p.owner != l.owner) return error.HoverOwnerMismatch;
                l.on_hover = if (l.next) |p| p.on_hover else n.behavior.events.on_hover;
                l.on_leave = if (l.next) |p| p.on_leave else n.behavior.events.on_leave;
                HoverListener.publish(n, l, null, null);
            }
        }.attach);
        node.addDebugSignal(@ptrCast(is_hovered), "hover", .bool);
        return is_hovered;
    };
    HoverListener.publish(node, listener, null, null);
    node.addDebugSignal(@ptrCast(is_hovered), "hover", .bool);
    return is_hovered;
}

/// Node's pressed state: true while pressed on the node (or a descendant) and not released;
/// false when released or the press target is destroyed.
/// "Pressed and pointer in node" = native button highlight, combine with useHover (view's
/// `_active` does). Observers are registered on Cx and unregistered at scope destroy.
/// Contract: `scope` must not outlive `node` (use the node's render transaction scope), else
/// release leaves the entry in the list until scope destroy.
pub fn usePressed(scope: *Scope, cx: *Cx, node: *Node) !*Signal(bool) {
    const inside = if (cx.pressed_node) |p| p.isDescendantOf(node) else false;
    const pressed = try scope.createSignal(bool, inside);
    const Watch = struct {
        cx: *Cx,
        signal: *Signal(bool),
        fn detach(self: *@This()) void {
            const list = &self.cx.press_watchers;
            for (list.items, 0..) |w, i| if (w.signal == self.signal) {
                _ = list.swapRemove(i);
                return;
            };
        }
    };
    const watch = try scope.createState(Watch, .{ .cx = cx, .signal = pressed });
    if (comptime @import("zenit_environment").dev_preview) if (@import("preview_mount.zig").current != null) {
        try scope.onCleanup(Watch, watch, Watch.detach);
        _ = try @import("preview_mount.zig").deferAction(scope, .subscription, .{ .watch = watch, .node = node }, struct {
            fn attach(c: anytype, _: *Scope) anyerror!void {
                try c.watch.cx.press_watchers.append(c.watch.cx.allocator, .{ .node = c.node, .signal = c.watch.signal });
            }
        }.attach);
        return pressed;
    };
    try cx.press_watchers.ensureUnusedCapacity(cx.allocator, 1);
    // Register unregister before publish: OOM leaves no orphan observer
    try scope.onCleanup(Watch, watch, Watch.detach);
    cx.press_watchers.appendAssumeCapacity(.{ .node = node, .signal = pressed });
    return pressed;
}

/// Hover highlight style target field
pub const HighlightStyleField = enum {
    border_color,
    background,
    opacity,
    translate_y,
    scale,
};

/// Hover highlight animation state (cross-frame persistent)
pub const HoverHighlightState = struct {
    color_anim: AnimatedColor,
    /// Scalar animation (for opacity/translate_y/scale)
    scalar_anim: ?animation.AnimatedValue = null,
    target_node: ?*Node = null,
    style_field: HighlightStyleField,
    /// allocator (needed for ensureExt etc.; scale etc. fields must set)
    allocator: ?std.mem.Allocator = null,
    /// Frozen: when true before_render hook stops writing style, yield node
    /// to external control. Used RadioGroup selected: selected border pin
    /// accent, can't be overwritten by hover interpolation.
    frozen: bool = false,
};

/// Set frozen state on node with useHoverHighlight registered. Return
/// false = node has no hover highlight state.
pub fn setHoverHighlightFrozen(node: *Node, frozen: bool) bool {
    if (node.meta.per_frame.hooks.slots.hover_highlight_state) |ptr| {
        const state: *HoverHighlightState = @ptrCast(@alignCast(ptr));
        state.frozen = frozen;
        return true;
    }
    return false;
}

/// Hover highlight target_node before_render hook
fn hoverHighlightBeforeRender(node: *Node) void {
    if (node.meta.per_frame.hooks.slots.hover_highlight_state) |ctx_ptr| {
        const state: *HoverHighlightState = @ptrCast(@alignCast(ctx_ptr));

        // When frozen yield style control (external responsible for frame's
        // style); don't write or request redraw.
        if (state.frozen) return;

        const render_engine = @import("core/render_engine/mod.zig");
        const dt = render_engine.current_frame_dt_ms / 1000.0;
        const now_ms = render_engine.current_frame_time_ms;

        switch (state.style_field) {
            .border_color, .background => {
                const result = state.color_anim.tickWithTime(now_ms);
                switch (state.style_field) {
                    .border_color => {
                        // setBorderColor internally handles markRenderDirty
                        node.setBorderColor(result.color);
                        if (result.animating) node.markRenderDirty();
                    },
                    .background => {
                        // Only setStyle if color actually changed (avoid unconditional
                        // markRenderDirty each frame)
                        if (!Color.eql(node.getBackground(), result.color)) {
                            node.setBackgroundRaw(result.color);
                            node.markRenderDirty();
                        } else if (result.animating) {
                            node.markRenderDirty();
                        }
                    },
                    else => unreachable,
                }
            },
            .opacity, .translate_y, .scale => {
                if (state.scalar_anim) |*anim| {
                    anim.update(now_ms, dt);
                    const v = anim.get();
                    // composite properties use authoritative dirty marking, not
                    // markRenderDirty slow path, consistent with transition tick/node_animator
                    // (setOpacity internal); markCompositeDirty sets redraw.requested, no extra
                    // mark during animation.
                    switch (state.style_field) {
                        .opacity => node.setOpacity(v),
                        .translate_y => {
                            node.style.translate_y = v;
                            node.markCompositePropDirty();
                        },
                        .scale => {
                            if (state.allocator) |alloc| {
                                node.style.ensureExtPanic(alloc).scale_x = v;
                                node.style.ensureExtPanic(alloc).scale_y = v;
                                node.markCompositePropDirty();
                            }
                        },
                        else => unreachable,
                    }
                }
            },
        }
    }
}

/// Hover highlight animation config
pub const HoverHighlightConfig = struct {
    /// Transition duration (seconds)
    duration: f32 = 0.12,
    /// Easing function
    easing: animation.Easing = .ease_out_quad,
};

/// Set onMount callback (fires once after first layout)
pub fn onMount(node: *Node, handler: core.HandlerRef) void {
    node.meta.ownership.hooks.on_mount = handler;
}

/// Set onCleanup callback (fires when node removed from tree)
pub fn onCleanup(node: *Node, handler: core.HandlerRef) void {
    node.meta.ownership.hooks.on_cleanup = handler;
}

/// Before clearNodeScopes/dispose, decouple hook state from node, avoid
/// accessing Node pointer outside lifecycle during resource destruction.
pub fn invalidateSubtreeHookState(node: *Node) void {
    if (comptime @import("zenit_environment").dev_preview) {
        var pending = HoverListener.pendingHead(node);
        while (pending) |listener| {
            node.removeDebugSignal(@ptrCast(listener.signal));
            listener.node = null;
            listener.queued = false;
            pending = listener.next;
        }
        node.meta.per_frame.hooks.slots.preview_hover_pending = null;
    }
    if (HoverListener.head(node)) |first| {
        var cursor: ?*HoverListener = first;
        while (cursor) |listener| {
            node.removeDebugSignal(@ptrCast(listener.signal));
            listener.node = null;
            cursor = listener.next;
        }
        // The original callbacks may also borrow the disposed component scope.
        HoverListener.publish(node, null, null, null);
    }
    if (node.meta.per_frame.hooks.slots.hover_highlight_state) |ptr| {
        const state: *HoverHighlightState = @ptrCast(@alignCast(ptr));
        state.target_node = null;
        node.meta.per_frame.hooks.slots.hover_highlight_state = null;
    }
    if (node.meta.per_frame.hooks.slots.focus_ring_anim) |ptr| {
        if (node.meta.per_frame.hooks.slots.focus_ring_owned) {
            const state: *FocusRingAnimState = @ptrCast(@alignCast(ptr));
            state.node = null;
        }
        node.meta.per_frame.hooks.slots.focus_ring_anim = null;
    }
    node.meta.per_frame.hooks.slots.focus_ring_owned = false;
    // useFocusRing wires on_focus/on_blur to a scope-owned FocusRingCtx (and signal). All unmount
    // paths are "invalidate hook, dispose scope, unlink". If focus is in the subtree, clearFocus
    // -> on_blur. If the original handler is not restored here, blur would write the freed
    // ctx/signal (so it MUST be restored to the original handler here).
    // useFocusState handlers are the same; both can be stacked (view focus first, focus ring
    // later), so loop until the handler is not theirs.
    while (node.behavior.events.on_focus) |h| {
        if (h.callback == &focusRingOnFocus) {
            const rc: *FocusRingCtx = @ptrCast(@alignCast(h.context));
            rc.fm.unsubscribeVisibility(rc.subscription_id);
            rc.node = null;
            node.behavior.events.on_focus = rc.prev_on_focus;
        } else if (h.callback == &focusStateOnFocus) {
            const fs: *FocusStateCtx = @ptrCast(@alignCast(h.context));
            fs.fm.unsubscribeVisibility(fs.subscription_id);
            fs.node = null;
            node.behavior.events.on_focus = fs.prev_on_focus;
        } else break;
    }
    while (node.behavior.events.on_blur) |h| {
        if (h.callback == &focusRingOnBlur) {
            const rc: *FocusRingCtx = @ptrCast(@alignCast(h.context));
            node.behavior.events.on_blur = rc.prev_on_blur;
        } else if (h.callback == &focusStateOnBlur) {
            const fs: *FocusStateCtx = @ptrCast(@alignCast(h.context));
            node.behavior.events.on_blur = fs.prev_on_blur;
        } else break;
    }
    // Custom anim_state (Spinner/Skeleton shimmer infinite animations).
    //
    // Must clear anim_state and remove its before_render hook, not just
    // animated_bg/hover_highlight/focus_ring. Otherwise it doesn't crash (each hook's first line
    // is `slots.anim_state orelse return`), but the **unmounted subtree still ticks each frame**:
    // `freeNode` at tick_depth>0 is delayed, the queued hook runs, Spinner markRenderDirty() ->
    // wantsFrame true -> **idle never stops**.
    //
    // Unhook the key, don't just clear state: the hook would still be called. Infinite animations,
    // unlike finite transitions, don't self-converge and must be explicitly disconnected.
    node.meta.per_frame.hooks.slots.anim_state = null;
    node.meta.per_frame.hooks.slots.view_loop = null;
    node.meta.per_frame.hooks.before_render.main = null;
    node.meta.per_frame.hooks.before_render.count = 0;
    node.meta.per_frame.hooks.before_render.self_only_mask = 0;
    node.meta.per_frame.hooks.on_theme = null;
    node.meta.per_frame.hooks.theme_decl = null;
    node.meta.per_frame.hooks.view_theme = null;

    for (node.children.items) |child| {
        invalidateSubtreeHookState(child);
    }
}

// ==================== useFocusRing ====================

/// Focus Ring configuration
pub const FocusRingConfig = struct {
    /// focus ring color (null = use theme border_focus token)
    color: ?Color = null,
    /// focus ring line width
    width: f32 = 2,
    /// spacing between component and ring (like CSS outline-offset)
    offset: f32 = 2,
    /// fade in/out transition duration (seconds)
    duration: f32 = 0.1,
    /// easing function
    easing: animation.Easing = .ease_out_quad,
};

/// Focus ring handler context (persisted via StateStore)
const FocusRingCtx = struct {
    signal: *Signal(bool),
    fm: *FocusManager,
    subscription_id: u64 = 0,
    active: bool = false,
    node: ?*Node = null,
    /// Focus ring animation state
    anim_state: ?*FocusRingAnimState = null,
    /// previous callback for chained on_focus/on_blur
    prev_on_focus: ?HandlerRef = null,
    prev_on_blur: ?HandlerRef = null,
};

/// Focus ring animation state (persists across frames)
pub const FocusRingAnimState = struct {
    /// outline opacity animation (0.0 = hidden, 1.0 = fully visible)
    opacity_anim: animation.AnimatedValue,
    /// node reference
    node: ?*Node = null,
    /// outline configuration; `focus_color` is the color in force: `fixed_color` when the caller
    /// gave one, else the current theme's focus ring (re-read every frame, so it follows setTheme)
    focus_color: Color,
    fixed_color: ?Color = null,
    cx: *Cx,
    focus_width: f32,
    focus_offset: f32,
    /// set allocator needed for outline
    allocator: std.mem.Allocator,
};

/// Update a mounted outline without adding another subscription or animation hook.
pub fn updateFocusRingConfig(cx: *Cx, node: *Node, config: FocusRingConfig) void {
    const ptr = node.meta.per_frame.hooks.slots.focus_ring_anim orelse return;
    const state: *FocusRingAnimState = @ptrCast(@alignCast(ptr));
    state.fixed_color = config.color;
    state.focus_color = config.color orelse cx.tokens.tokens.color.focus_ring;
    state.focus_width = config.width;
    state.focus_offset = config.offset;
    switch (state.opacity_anim.animator) {
        .transition => |*transition| {
            transition.config.duration_ms = config.duration * 1000;
            transition.config.easing = config.easing;
        },
        else => {},
    }
    // Force the next pre-render update even when opacity is already settled.
    node.setStyle(state.allocator, .outline, null);
    node.markRenderDirty();
}

/// Focus ring pre-render hook: tick opacity animation and update outline alpha
fn focusRingBeforeRender(node: *Node) void {
    // get state from node's focus_ring_anim pointer
    if (node.meta.per_frame.hooks.slots.focus_ring_anim) |anim_ptr| {
        const anim_state: *FocusRingAnimState = @ptrCast(@alignCast(anim_ptr));
        anim_state.focus_color = anim_state.fixed_color orelse anim_state.cx.tokens.tokens.color.focus_ring;

        const render_engine = @import("core/render_engine/mod.zig");
        anim_state.opacity_anim.update(render_engine.current_frame_time_ms, render_engine.current_frame_dt_ms / 1000.0);
        const opacity = anim_state.opacity_anim.get();
        const target_opacity = anim_state.opacity_anim.getTarget();
        const effective_opacity = if (opacity <= 0.001 and target_opacity > 0.001)
            target_opacity
        else
            opacity;

        if (effective_opacity > 0.001) {
            // outline visible: set alpha channel
            var color = anim_state.focus_color;
            color.a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * effective_opacity);
            const new_outline: ?@import("core/types.zig").Outline = .{
                .color = color,
                .width = anim_state.focus_width,
                .offset = anim_state.focus_offset,
            };
            // only setStyle if outline actually changed or animation in progress
            if (anim_state.opacity_anim.isAnimating() or node.style.outline() == null) {
                node.setStyle(anim_state.allocator, .outline, new_outline);
                node.markRenderDirty();
            }
        } else {
            // fully transparent: clear only if outline is non-null (avoid unconditional setStyle
            // every frame)
            if (node.style.outline() != null) {
                node.setStyle(anim_state.allocator, .outline, null);
                node.markRenderDirty();
            }
        }
    }
}

// Remove a scope's wrappers even when another hook is stacked above them.
fn detachFocusHandlers(node: *Node, context: *anyopaque) void {
    inline for (.{ "on_focus", "on_blur" }) |field| {
        var slot = &@field(node.behavior.events, field);
        while (slot.*) |handler| {
            const previous: *?HandlerRef = if (handler.callback == &focusRingOnFocus)
                &@as(*FocusRingCtx, @ptrCast(@alignCast(handler.context))).prev_on_focus
            else if (handler.callback == &focusRingOnBlur)
                &@as(*FocusRingCtx, @ptrCast(@alignCast(handler.context))).prev_on_blur
            else if (handler.callback == &focusStateOnFocus)
                &@as(*FocusStateCtx, @ptrCast(@alignCast(handler.context))).prev_on_focus
            else if (handler.callback == &focusStateOnBlur)
                &@as(*FocusStateCtx, @ptrCast(@alignCast(handler.context))).prev_on_blur
            else
                break;
            if (handler.context == context) {
                slot.* = previous.*;
                break;
            }
            slot = previous;
        }
    }
}

/// add focus ring visual feedback around node (Scope manages lifecycle)
fn focusRingOnFocus(context: *anyopaque) void {
    const rc: *FocusRingCtx = @ptrCast(@alignCast(context));
    const fm = rc.fm;
    const id = rc.subscription_id;
    const epoch = fm.transition_epoch;
    rc.active = true;
    if (rc.prev_on_focus) |prev| prev.invoke();
    if (!fm.hasVisibilitySubscription(id) or fm.transition_epoch != epoch) return;
    focusRingVisibilityChanged(context);
}

fn focusRingVisibilityChanged(context: *anyopaque) void {
    const rc: *FocusRingCtx = @ptrCast(@alignCast(context));
    const focus_visible = rc.active and rc.fm.focus_visible;
    if (rc.signal.peek() == focus_visible) return;
    if (rc.anim_state) |state| {
        const now_ms = @import("core/render_engine/mod.zig").current_frame_time_ms;
        if (focus_visible) {
            state.opacity_anim.setTo(1.0, now_ms);
            if (state.node) |n| {
                // void callback cannot propagate; z_index is visual only, allocation failure
                // degrades gracefully but must never panic the process
                if (n.style.ensureExtFallible(state.allocator)) |ext| {
                    ext.z_index = 1;
                } else |_| {}
                n.setStyle(state.allocator, .outline, .{
                    .color = state.focus_color,
                    .width = state.focus_width,
                    .offset = state.focus_offset,
                });
                n.markRenderDirty();
            }
        } else {
            state.opacity_anim.setTo(0.0, now_ms);
            if (state.node) |n| {
                // void callback, failure degrades without panic (same as above)
                if (n.style.ensureExtFallible(state.allocator)) |ext| {
                    ext.z_index = 0;
                } else |_| {}
                n.markRenderDirty();
            }
        }
    }
    rc.signal.set(focus_visible);
}

fn focusRingOnBlur(context: *anyopaque) void {
    const rc: *FocusRingCtx = @ptrCast(@alignCast(context));
    const fm = rc.fm;
    const id = rc.subscription_id;
    const epoch = fm.transition_epoch;
    rc.active = false;
    if (rc.prev_on_blur) |prev| prev.invoke();
    if (!fm.hasVisibilitySubscription(id) or fm.transition_epoch != epoch) return;
    focusRingVisibilityChanged(context);
}

/// node's focus state (used by view's `_focus` / `_focus_visible` style conditions): `focused` is
/// true when focused;
/// `visible` is the FocusManager resolved policy, including current input modality.
/// on_focus / on_blur chain in front of original handler; unmounted by invalidateSubtreeHookState
/// using function address.
pub const FocusState = struct { focused: *Signal(bool), visible: *Signal(bool) };

const FocusStateCtx = struct {
    focused: *Signal(bool),
    visible: *Signal(bool),
    fm: *FocusManager,
    subscription_id: u64 = 0,
    active: bool = false,
    node: ?*Node = null,
    prev_on_focus: ?HandlerRef = null,
    prev_on_blur: ?HandlerRef = null,
};

fn focusStateOnFocus(context: *anyopaque) void {
    const fs: *FocusStateCtx = @ptrCast(@alignCast(context));
    const fm = fs.fm;
    const id = fs.subscription_id;
    const epoch = fm.transition_epoch;
    fs.active = true;
    if (fs.prev_on_focus) |prev| prev.invoke();
    if (!fm.hasVisibilitySubscription(id) or fm.transition_epoch != epoch) return;
    focusStateVisibilityChanged(context);
}

fn focusStateOnBlur(context: *anyopaque) void {
    const fs: *FocusStateCtx = @ptrCast(@alignCast(context));
    const fm = fs.fm;
    const id = fs.subscription_id;
    const epoch = fm.transition_epoch;
    fs.active = false;
    if (fs.prev_on_blur) |prev| prev.invoke();
    if (!fm.hasVisibilitySubscription(id) or fm.transition_epoch != epoch) return;
    focusStateVisibilityChanged(context);
}

fn focusStateVisibilityChanged(context: *anyopaque) void {
    const fs: *FocusStateCtx = @ptrCast(@alignCast(context));
    const fm = fs.fm;
    const id = fs.subscription_id;
    const epoch = fm.transition_epoch;
    fs.focused.set(fs.active);
    if (!fm.hasVisibilitySubscription(id) or fm.transition_epoch != epoch) return;
    fs.visible.set(fs.active and fm.focus_visible);
}

pub fn useFocusState(scope: *Scope, cx: *Cx, node: *Node) !FocusState {
    const focused_now = cx.isFocused(node);
    const focused = try scope.createSignal(bool, focused_now);
    const visible = try scope.createSignal(bool, focused_now and cx.focus_manager.focus_visible);
    node.addDebugSignal(@ptrCast(focused), "focused", .bool);
    const ctx = try scope.createState(FocusStateCtx, .{
        .focused = focused,
        .visible = visible,
        .fm = &cx.focus_manager,
        .node = node,
        .prev_on_focus = node.behavior.events.on_focus,
        .prev_on_blur = node.behavior.events.on_blur,
    });
    ctx.active = focused_now;
    if (comptime @import("zenit_environment").dev_preview) if (@import("preview_mount.zig").current != null) {
        try scope.onCleanup(FocusStateCtx, ctx, struct {
            fn detach(c: *FocusStateCtx) void {
                const n = c.node orelse return;
                c.fm.unsubscribeVisibility(c.subscription_id);
                detachFocusHandlers(n, c);
                c.node = null;
            }
        }.detach);
        node.behavior.events.on_focus = Cx.simpleHandler(focusStateOnFocus, @ptrCast(ctx));
        node.behavior.events.on_blur = Cx.simpleHandler(focusStateOnBlur, @ptrCast(ctx));
        _ = try @import("preview_mount.zig").deferAction(scope, .subscription, ctx, struct {
            fn attach(c: *FocusStateCtx, _: *Scope) anyerror!void {
                if (c.node == null) return;
                c.subscription_id = try c.fm.subscribeVisibility(c, focusStateVisibilityChanged);
            }
        }.attach);
        return .{ .focused = focused, .visible = visible };
    };
    ctx.subscription_id = try cx.focus_manager.subscribeVisibility(ctx, focusStateVisibilityChanged);
    errdefer cx.focus_manager.unsubscribeVisibility(ctx.subscription_id);
    try scope.onCleanup(FocusStateCtx, ctx, struct {
        fn detach(c: *FocusStateCtx) void {
            // Node invalidation already unsubscribes; its Cx may now be gone.
            const n = c.node orelse return;
            c.fm.unsubscribeVisibility(c.subscription_id);
            detachFocusHandlers(n, c);
            c.node = null;
        }
    }.detach);
    node.behavior.events.on_focus = Cx.simpleHandler(focusStateOnFocus, @ptrCast(ctx));
    node.behavior.events.on_blur = Cx.simpleHandler(focusStateOnBlur, @ptrCast(ctx));
    return .{ .focused = focused, .visible = visible };
}

pub fn useFocusRing(scope: *Scope, cx: *Cx, node: *Node, config: FocusRingConfig) !void {
    // The initial effect and later callbacks write outline/z-index without
    // returning errors. Prepare their shared storage before publishing hooks.
    _ = try node.style.ensureExtFallible(cx.allocator);
    const t = cx.tokens;
    const focus_color = config.color orelse t.tokens.color.focus_ring;

    const is_focused = try scope.createSignal(bool, false);
    node.addDebugSignal(@ptrCast(is_focused), "focused", .bool);

    // allocate animation state on scope
    const anim_state = try scope.allocator.create(FocusRingAnimState);
    anim_state.* = .{
        .opacity_anim = animation.AnimatedValue.create(0.0)
            .useTransition()
            .duration_ms(config.duration * 1000.0)
            .easing(config.easing)
            .build(),
        .node = node,
        .focus_color = focus_color,
        .fixed_color = config.color,
        .cx = cx,
        .focus_width = config.width,
        .focus_offset = config.offset,
        .allocator = scope.allocator,
    };
    {
        errdefer scope.allocator.destroy(anim_state);
        try scope.registerResource(@ptrCast(anim_state), struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const s: *FocusRingAnimState = @ptrCast(@alignCast(ptr));
                if (s.node) |n| {
                    if (n.meta.per_frame.hooks.slots.focus_ring_anim == ptr) {
                        n.meta.per_frame.hooks.slots.focus_ring_anim = null;
                        n.meta.per_frame.hooks.slots.focus_ring_owned = false;
                    }
                    n.removeBeforeRender(focusRingBeforeRender);
                }
                s.node = null;
                allocator.destroy(s);
            }
        }.destroy);
    }

    node.meta.per_frame.hooks.slots.focus_ring_anim = anim_state;
    node.meta.per_frame.hooks.slots.focus_ring_owned = true;

    // register as extended callback (does not override main on_before_render)
    // Only this node's outline, written through setStyle + markRenderDirty.
    if (comptime @import("zenit_environment").dev_preview) {
        if (!try @import("preview_mount.zig").deferAction(scope, .subscription, anim_state, struct {
            fn attach(state: *FocusRingAnimState, _: *Scope) anyerror!void {
                const n = state.node orelse return;
                n.addBeforeRenderScoped(focusRingBeforeRender, .self);
            }
        }.attach)) node.addBeforeRenderScoped(focusRingBeforeRender, .self);
    } else node.addBeforeRenderScoped(focusRingBeforeRender, .self);

    // handler context
    const ring_ctx = try scope.allocator.create(FocusRingCtx);
    ring_ctx.* = .{
        .signal = is_focused,
        .fm = &cx.focus_manager,
        .node = node,
        .anim_state = anim_state,
        .prev_on_focus = node.behavior.events.on_focus,
        .prev_on_blur = node.behavior.events.on_blur,
    };
    {
        errdefer scope.allocator.destroy(ring_ctx);
        try scope.registerResource(@ptrCast(ring_ctx), struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const s: *FocusRingCtx = @ptrCast(@alignCast(ptr));
                allocator.destroy(s);
            }
        }.destroy);
    }

    const detach = struct {
        fn detach(c: *FocusRingCtx) void {
            // Node invalidation already unsubscribes; its Cx may now be gone.
            const n = c.node orelse return;
            c.fm.unsubscribeVisibility(c.subscription_id);
            detachFocusHandlers(n, c);
            c.node = null;
        }
    }.detach;
    if (comptime @import("zenit_environment").dev_preview) {
        if (@import("preview_mount.zig").current != null) {
            try scope.onCleanup(FocusRingCtx, ring_ctx, detach);
            node.behavior.events.on_focus = Cx.simpleHandler(focusRingOnFocus, @ptrCast(ring_ctx));
            node.behavior.events.on_blur = Cx.simpleHandler(focusRingOnBlur, @ptrCast(ring_ctx));
            _ = try @import("preview_mount.zig").deferAction(scope, .subscription, ring_ctx, struct {
                fn attach(c: *FocusRingCtx, _: *Scope) anyerror!void {
                    if (c.node == null) return;
                    c.subscription_id = try c.fm.subscribeVisibility(c, focusRingVisibilityChanged);
                }
            }.attach);
        } else {
            ring_ctx.subscription_id = try cx.focus_manager.subscribeVisibility(ring_ctx, focusRingVisibilityChanged);
            errdefer cx.focus_manager.unsubscribeVisibility(ring_ctx.subscription_id);
            try scope.onCleanup(FocusRingCtx, ring_ctx, detach);
        }
    } else {
        ring_ctx.subscription_id = try cx.focus_manager.subscribeVisibility(ring_ctx, focusRingVisibilityChanged);
        errdefer cx.focus_manager.unsubscribeVisibility(ring_ctx.subscription_id);
        try scope.onCleanup(FocusRingCtx, ring_ctx, detach);
    }

    // Focus / Blur handlers (chain to previous callback). Named function:
    // invalidateSubtreeHookState
    // identifies and removes them by function address (ring_ctx and signal are both owned by scope,
    // must not be called after scope is released).
    node.behavior.events.on_focus = Cx.simpleHandler(focusRingOnFocus, @ptrCast(ring_ctx));
    node.behavior.events.on_blur = Cx.simpleHandler(focusRingOnBlur, @ptrCast(ring_ctx));

    // Effect: when focus-visible, set animation target opacity + z_index elevation;
    // z_index elevation ensures focus ring (outline) is not obscured by sibling nodes (e.g., Group
    // compositions)
    try scope.createEffect(.{
        .is_focused = is_focused,
        .anim_state = anim_state,
        .node = node,
        .allocator = scope.allocator,
    }, struct {
        fn update(c: anytype) void {
            const now_ms = @import("core/render_engine/mod.zig").current_frame_time_ms;
            if (c.is_focused.get()) {
                c.anim_state.opacity_anim.setTo(1.0, now_ms);
                // void callback cannot propagate; z_index is visual only, allocation failure
                // degrades gracefully but must never panic the process
                if (c.node.style.ensureExtFallible(c.allocator)) |ext| {
                    ext.z_index = 1;
                } else |_| {}
                c.node.setStyle(c.allocator, .outline, .{
                    .color = c.anim_state.focus_color,
                    .width = c.anim_state.focus_width,
                    .offset = c.anim_state.focus_offset,
                });
            } else {
                c.anim_state.opacity_anim.setTo(0.0, now_ms);
                // void callback, failure degrades without panic (same as above)
                if (c.node.style.ensureExtFallible(c.allocator)) |ext| {
                    ext.z_index = 0;
                } else |_| {}
            }
            c.node.markRenderDirty();
        }
    }.update);
}

/// hover highlight animation (Scope manages lifecycle)
pub fn useHoverHighlight(
    scope: *Scope,
    node: *Node,
    target_node: *Node,
    comptime StyleField: HighlightStyleField,
    normal: Color,
    hover: Color,
    config: HoverHighlightConfig,
) !*Signal(bool) {
    const is_hovered = try useHover(scope, node);

    // allocate animation state on scope
    const hl_state = try scope.allocator.create(HoverHighlightState);
    hl_state.* = .{
        .color_anim = AnimatedColor.initWithConfig(normal, .{
            .duration_ms = config.duration * 1000.0,
            .easing = config.easing,
        }),
        .target_node = target_node,
        .style_field = StyleField,
    };
    try scope.adoptResource(@ptrCast(hl_state), struct {
        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const s: *HoverHighlightState = @ptrCast(@alignCast(ptr));
            if (s.target_node) |n| {
                if (n.meta.per_frame.hooks.slots.hover_highlight_state == ptr) n.meta.per_frame.hooks.slots.hover_highlight_state = null;
                n.removeBeforeRender(hoverHighlightBeforeRender);
            }
            allocator.destroy(s);
        }
    }.destroy);

    target_node.meta.per_frame.hooks.slots.hover_highlight_state = hl_state;

    // register as extended callback
    if (comptime @import("zenit_environment").dev_preview) {
        if (!try @import("preview_mount.zig").deferAction(scope, .subscription, hl_state, struct {
            fn attach(state: *HoverHighlightState, _: *Scope) anyerror!void {
                const n = state.target_node orelse return;
                n.addBeforeRender(hoverHighlightBeforeRender);
            }
        }.attach)) target_node.addBeforeRender(hoverHighlightBeforeRender);
    } else target_node.addBeforeRender(hoverHighlightBeforeRender);

    // Effect: set animation target color when hover changes
    try scope.createEffect(.{
        .hl_state = hl_state,
        .is_hovered = is_hovered,
        .normal = normal,
        .hover = hover,
        .target = target_node,
    }, struct {
        fn update(c: anytype) void {
            c.hl_state.color_anim.setTarget(if (c.is_hovered.get()) c.hover else c.normal, @import("core/render_engine/mod.zig").current_frame_time_ms);
            c.target.markRenderDirty();
        }
    }.update);

    return is_hovered;
}

// ==================== ToggleState ====================

/// Toggle state
pub const ToggleState = struct {
    checked: bool = false,
    disabled: bool = false,
    /// 2026-07-31 merged: unified `?core.HandlerRef` (context already included).
    /// invoke with invokeWithBool; if registration uses a no-arg handler, degrades to
    /// no-arg invocation rather than dropping event.
    on_change: ?core.HandlerRef = null,

    pub fn toggle(self: *ToggleState) void {
        if (self.disabled) return;
        self.checked = !self.checked;
        if (self.on_change) |h| h.invokeWithBool(self.checked);
    }
};

/// Toggle event handling logic (type-safe version, callable by wrapper)
pub fn toggleEventHandlerFn(event: Event, state: *ToggleState) EventResult {
    if (state.disabled) return .ignored;

    switch (event) {
        .click => {
            state.toggle();
            return .handled;
        },
        .key_down => |e| {
            if (e.key == .space) {
                state.toggle();
                return .handled;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

/// Test-only traversal; absent from production builds.
pub const testing = if (@import("builtin").is_test) struct {
    pub fn hoverListenerCount(node: *Node) usize {
        var count: usize = 0;
        var cursor = HoverListener.head(node);
        while (cursor) |listener| : (cursor = listener.next) count += 1;
        return count;
    }
} else struct {};
