/// ScrollArea scroll event handling - scrollEventHandler + nested scroll chain delegation +
/// momentum ownership + helper functions
const std = @import("std");
const core = @import("../../core.zig");
const Node = core.Node;
const Event = core.Event;
const EventResult = core.EventResult;

const state_mod = @import("state.zig");
const ScrollState = state_mod.ScrollState;
const ScrollDirection = state_mod.ScrollDirection;
const ScrollEventCtx = state_mod.ScrollEventCtx;

const scroll_physics = @import("physics.zig");
const applyVerticalScroll = scroll_physics.applyVerticalScroll;
const InputKind = scroll_physics.InputKind;
const applyHorizontalScroll = scroll_physics.applyHorizontalScroll;

const debug = @import("debug.zig");
const logScroll = debug.logScroll;
const scrollDebugEnabled = debug.scrollDebugEnabled;

pub fn scrollEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *const ScrollEventCtx = @ptrCast(@alignCast(context.?));
    const state = ctx.state;
    const content = ctx.content orelse return .ignored;
    const container = ctx.container orelse return .ignored;

    switch (event) {
        .scroll => |scroll| {
            // A wheel against a pinned end (or into content that cannot scroll) leaves every
            // pixel as it was: tell the dispatcher, so the event requests no frame.
            const before = VisibleScrollState.of(state, content);
            defer if (VisibleScrollState.of(state, content).eql(before)) core.scroll_effect.declareInert();
            logScroll(
                "event in id={d} dir={s} dy={d:.2} dx={d:.2} phase={s} momentum={s} scroll_y={d:.2} bonus_y={d:.2} scroll_x={d:.2} bonus_x={d:.2}",
                .{
                    container.id,
                    @tagName(ctx.direction),
                    scroll.dy,
                    scroll.dx,
                    @tagName(scroll.phase),
                    @tagName(scroll.momentum),
                    state.scroll_y,
                    state.bonus_y,
                    state.scroll_x,
                    state.bonus_x,
                },
            );
            if (content.parent) |parent| {
                const pr = parent.rectFromWorldOrFallback();
                state.viewport_height = @max(0, pr.h - parent.style.contentInsets().vertical());
                state.viewport_width = @max(0, pr.w - parent.style.contentInsets().horizontal());
            }
            const cr = content.rectFromWorldOrFallback();
            if (!state.external_content_height and cr.h > 0) state.content_height = cr.h;
            if (!state.external_content_width and cr.w > 0) state.content_width = cr.w;

            // viewport not initialized (no layout yet), defer handling
            if (state.viewport_height <= 0 and state.viewport_width <= 0) {
                return .ignored;
            }

            const kind: InputKind = if (scroll.isMomentum())
                .momentum
            else if (scroll.phase == .none)
                .wheel
            else
                .gesture;

            // begin signal only handled by this layer (owner), don't bubble: if outer layer
            // rubber-banding, bubble would "catch" it and steal inner gesture. outer's old momentum
            // ended by scheduler-injected momentum ended; when gesture delegates to outer, outer
            // beginTouch on first actual scroll. end signal bubbles: gesture may delegate mid-way
            // to outer, must reach true holder.
            switch (scroll.phase) {
                .may_begin, .began => {
                    state.momentum_active = false;
                    state.momentum_spent_y = false;
                    state.momentum_spent_x = false;
                    state.latched = false;
                    // finger down catches ongoing rubber-band in this layer
                    if (state.bonus_y != 0 or state.bonus_x != 0 or state.bounce_active_y or state.bounce_active_x) {
                        state.beginTouch();
                    }
                    if (scroll.dx == 0 and scroll.dy == 0) return .stop;
                },
                .ended, .cancelled => {
                    if (state.touching) {
                        state.touching = false;
                        // release while overscrolled: outward momentum on this axis handed to
                        // spring
                        if (state.bonus_y != 0) state.momentum_spent_y = true;
                        if (state.bonus_x != 0) state.momentum_spent_x = true;
                        logScroll("touch end id={d} phase={s} bonus_y={d:.2} bonus_x={d:.2}", .{ container.id, @tagName(scroll.phase), state.bonus_y, state.bonus_x });
                    }
                    // no momentum after cancel, gesture ownership ends
                    if (scroll.phase == .cancelled) state.latched = false;
                    return .ignored;
                },
                .none, .changed => {},
            }
            if (kind == .momentum) {
                // momentum means finger already released
                state.touching = false;
                if (scroll.momentum == .ended) {
                    state.momentum_active = false;
                    state.latched = false;
                    return .ignored;
                }
            }

            // nested scroll chain: delegate to outer ScrollArea at boundary (closer to native
            // iOS/macOS feel). .both mode: axes delegate independently, one axis delegating doesn't
            // affect other axis normal scroll
            var skip_y = false;
            var skip_x = false;
            const wants_v = scroll.dy != 0;
            const wants_h = scroll.dx != 0;
            const can_v = canScrollVerticalAxis(state);
            const can_h = canScrollHorizontalAxis(state);
            const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
            const v_delta_abs = @abs(-scroll.dy * ctx.scroll_speed);
            const h_delta_abs = @abs(-scroll.dx * ctx.scroll_speed);
            const is_momentum = kind == .momentum;

            if (ctx.direction == .both) {
                if (wants_v and !can_v) {
                    skip_y = true;
                    logScroll("axis_skip y: reason=no-scroll-space dy={d:.2} max_y={d:.2} bonus_y={d:.2}", .{
                        scroll.dy,
                        state.maxScrollY(),
                        state.bonus_y,
                    });
                }
                if (wants_h and !can_h) {
                    skip_x = true;
                    logScroll("axis_skip x: reason=no-scroll-space dx={d:.2} max_x={d:.2} bonus_x={d:.2}", .{
                        scroll.dx,
                        state.maxScrollX(),
                        state.bonus_x,
                    });
                }
                if (can_v) {
                    skip_y = skip_y or shouldDelegateVerticalToAncestor(state, ctx, scroll.dy, is_momentum);
                }
                if (can_h) {
                    skip_x = skip_x or shouldDelegateHorizontalToAncestor(state, ctx, scroll.dx, is_momentum);
                }
                // one axis delegates to outer, other scrolls here: use dominant axis to decide
                // whole event ownership (same cross-dominant passthrough rule), else this layer
                // eats one axis and other disappears. don't switch when already holding gesture (or
                // its momentum), secondary axis stays with this layer.
                const y_leaves = wants_v and skip_y;
                const x_leaves = wants_h and skip_x;
                const holds_stream = state.touching or (is_momentum and state.latched);
                if (!holds_stream and y_leaves != x_leaves) {
                    const leaving_dominant = if (y_leaves) v_delta_abs > h_delta_abs else h_delta_abs > v_delta_abs;
                    if (leaving_dominant) {
                        logScroll("axis_passthrough both dominant-leaves: id={d} dy={d:.2} dx={d:.2}", .{ container.id, scroll.dy, scroll.dx });
                        if (kind == .gesture) state.latched = false;
                        return .ignored;
                    }
                }
            } else {
                const single_axis_passthrough = switch (ctx.direction) {
                    .vertical => h_delta_abs > epsilon and h_delta_abs > v_delta_abs and !state.touching and !hasActiveBonusForDirection(state, .vertical),
                    .horizontal => v_delta_abs > epsilon and v_delta_abs > h_delta_abs and !state.touching and !hasActiveBonusForDirection(state, .horizontal),
                    .both => false,
                };
                if (single_axis_passthrough) {
                    logScroll("axis_passthrough cross-dominant: id={d} dir={s} dy={d:.2} dx={d:.2}", .{
                        container.id,
                        @tagName(ctx.direction),
                        scroll.dy,
                        scroll.dx,
                    });
                    return .ignored;
                }

                const delegate_to_ancestor = switch (ctx.direction) {
                    .vertical => shouldDelegateVerticalToAncestor(state, ctx, scroll.dy, is_momentum),
                    .horizontal => shouldDelegateHorizontalToAncestor(state, ctx, scroll.dx, is_momentum),
                    .both => unreachable,
                };
                if (delegate_to_ancestor) {
                    logScroll("axis_delegate: id={d} dir={s} dy={d:.2} dx={d:.2}", .{
                        container.id,
                        @tagName(ctx.direction),
                        scroll.dy,
                        scroll.dx,
                    });
                    // gesture ownership bubbles up -> this layer relinquishes latch
                    if (kind == .gesture) {
                        state.latched = false;
                        state.touching = false;
                    }
                    syncContentTranslate(state, content);
                    return .ignored;
                }
            }

            // momentum: overscroll portion goes to spring; axes that already hit boundary this
            // segment don't push outward.
            if (kind == .momentum) {
                state.momentum_active = true;
                const block_y = momentumBlockedY(state, scroll.dy, ctx.scroll_speed);
                const block_x = momentumBlockedX(state, scroll.dx, ctx.scroll_speed);
                switch (ctx.direction) {
                    .vertical => if (block_y) {
                        logScroll("momentum blocked y: dy={d:.2} bonus_y={d:.2} spent={}", .{ scroll.dy, state.bonus_y, state.momentum_spent_y });
                        return .stop;
                    },
                    .horizontal => if (block_x) {
                        logScroll("momentum blocked x: dx={d:.2} bonus_x={d:.2} spent={}", .{ scroll.dx, state.bonus_x, state.momentum_spent_x });
                        return .stop;
                    },
                    .both => {
                        if (block_y) skip_y = true;
                        if (block_x) skip_x = true;
                        if ((block_y or !wants_v or !can_v) and (block_x or !wants_h or !can_h) and (block_y or block_x)) {
                            logScroll("momentum blocked both: dy={d:.2} dx={d:.2} block_y={} block_x={}", .{ scroll.dy, scroll.dx, block_y, block_x });
                            return .stop;
                        }
                    },
                }
            }

            if (kind == .gesture) state.beginTouch();

            var handled_axis = false;
            // per-axis tracking, scrollbar fade must know which axis actually scrolled, else pure Y
            // scroll also flashes X scrollbar (VSCode/Zed behavior: show only active axes).
            var applied_y = false;
            var applied_x = false;
            switch (ctx.direction) {
                .vertical => {
                    applyVerticalScroll(state, scroll.dy, ctx.scroll_speed, kind);
                    handled_axis = true;
                    applied_y = true;
                },
                .horizontal => {
                    applyHorizontalScroll(state, scroll.dx, ctx.scroll_speed, kind);
                    handled_axis = true;
                    applied_x = true;
                },
                .both => {
                    if (!skip_y and can_v and wants_v) {
                        applyVerticalScroll(state, scroll.dy, ctx.scroll_speed, kind);
                        handled_axis = true;
                        applied_y = true;
                    }
                    if (!skip_x and can_h and wants_h) {
                        applyHorizontalScroll(state, scroll.dx, ctx.scroll_speed, kind);
                        handled_axis = true;
                        applied_x = true;
                    }
                },
            }
            if (ctx.direction == .both and !handled_axis and (wants_v or wants_h)) {
                logScroll("axis_delegate: id={d} dir=both dy={d:.2} dx={d:.2} skip_y={} skip_x={} can_v={} can_h={}", .{
                    container.id,
                    scroll.dy,
                    scroll.dx,
                    skip_y,
                    skip_x,
                    can_v,
                    can_h,
                });
                if (kind == .gesture) {
                    state.latched = false;
                    state.touching = false;
                }
                syncContentTranslate(state, content);
                return .ignored;
            }
            if (handled_axis) {
                state.input_serial +%= 1;
                state.onScrollActivityAxes(applied_y, applied_x);
                switch (kind) {
                    // this layer actually handled this gesture -> holds latch, momentum follows
                    // this layer
                    .gesture => state.latched = true,
                    .momentum => {
                        if (applied_y and state.bonus_y != 0) state.momentum_spent_y = true;
                        if (applied_x and state.bonus_x != 0) state.momentum_spent_x = true;
                    },
                    .wheel => {},
                }
            }
            logScroll(
                "event out id={d} scroll_y={d:.2} bonus_y={d:.2} scroll_x={d:.2} bonus_x={d:.2}",
                .{ container.id, state.scroll_y, state.bonus_y, state.scroll_x, state.bonus_x },
            );
            syncContentTranslate(state, content);
            return .stop;
        },
        .mouse_move => |move| {
            // vertical bar hover: visual fine, but keep wider interaction hotzone.
            const sb = ctx.scrollbar orelse return .ignored;
            const was_hovered = state.scrollbar_hovered;
            state.scrollbar_hovered = state.needsScrollbar() and sb.globalRect().w > 0 and
                move.x >= sb.globalRect().x - state_mod.ScrollbarVisual.hover_slop and move.x <= sb.globalRect().x + sb.globalRect().w + state_mod.ScrollbarVisual.hover_slop;
            if (state.scrollbar_hovered and !was_hovered) state.onScrollActivity();
            // horizontal bar hover: also use hotzone expansion, avoid fine bar hard-hit.
            const sb_h = ctx.scrollbar_h orelse return .ignored;
            const was_hovered_h = state.scrollbar_hovered_h;
            state.scrollbar_hovered_h = state.needsHScrollbar() and sb_h.globalRect().h > 0 and
                move.y >= sb_h.globalRect().y - state_mod.ScrollbarVisual.hover_slop and move.y <= sb_h.globalRect().y + sb_h.globalRect().h + state_mod.ScrollbarVisual.hover_slop;
            if (state.scrollbar_hovered_h and !was_hovered_h) state.onScrollActivity();
            return .ignored;
        },
        .mouse_leave => {
            // A pointer that exits through the hover slop sends no further move to the container;
            // without this the hover track stays revealed and the bars never fade. Dragging is
            // owned by the thumb's pointer capture and is unaffected.
            state.scrollbar_hovered = false;
            state.scrollbar_hovered_h = false;
            return .ignored;
        },
        .mouse_down => {
            // container doesn't handle mouse_down, scrollbar's hitTest does
            return .ignored;
        },
        else => return .ignored,
    }
}

/// Everything of a ScrollArea a frame shows or animates from: offsets, overscroll and its spring,
/// the finger on the pad (it holds the spring), the content transform, and the scrollers'
/// opacity where they can show. A scroller's fade hold (idle frames) is excluded: it counts
/// rendered frames, so restarting it changes no pixel and needs no frame of its own.
pub const VisibleScrollState = struct {
    scroll_x: f32,
    scroll_y: f32,
    bonus_x: f32,
    bonus_y: f32,
    bounce_active_x: bool,
    bounce_active_y: bool,
    touching: bool,
    translate_x: f32,
    translate_y: f32,
    opacity_v: f32,
    opacity_h: f32,

    pub fn of(state: *const ScrollState, content: *const Node) VisibleScrollState {
        return .{
            .scroll_x = state.scroll_x,
            .scroll_y = state.scroll_y,
            .bonus_x = state.bonus_x,
            .bonus_y = state.bonus_y,
            .bounce_active_x = state.bounce_active_x,
            .bounce_active_y = state.bounce_active_y,
            .touching = state.touching,
            .translate_x = content.style.translate_x,
            .translate_y = content.style.translate_y,
            .opacity_v = if (state.needsScrollbar()) state.scrollbar_fade.opacity else 0,
            .opacity_h = if (state.needsHScrollbar()) state.scrollbar_fade_h.opacity else 0,
        };
    }

    pub fn eql(a: VisibleScrollState, b: VisibleScrollState) bool {
        return std.meta.eql(a, b);
    }
};

// ========== helper functions ==========

pub fn isAtVerticalBoundary(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollY();
    if (max <= epsilon) return true;
    return state.scroll_y <= epsilon or state.scroll_y >= max - epsilon;
}

pub fn canScrollVerticalAxis(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    return state.maxScrollY() > epsilon or state.bonus_y != 0;
}

pub fn canScrollHorizontalAxis(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    return state.maxScrollX() > epsilon or state.bonus_x != 0;
}

fn isOutwardAtBoundaryY(state: *const ScrollState, delta: f32) bool {
    if (delta == 0) return false;
    if (state.bonus_y < 0) return delta < 0;
    if (state.bonus_y > 0) return delta > 0;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollY();
    if (max <= epsilon) return true;
    const at_top = state.scroll_y <= epsilon;
    const at_bottom = state.scroll_y >= max - epsilon;
    return (at_top and delta < 0) or (at_bottom and delta > 0);
}

fn isOutwardAtBoundaryX(state: *const ScrollState, delta: f32) bool {
    if (delta == 0) return false;
    if (state.bonus_x < 0) return delta < 0;
    if (state.bonus_x > 0) return delta > 0;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollX();
    if (max <= epsilon) return true;
    const at_left = state.scroll_x <= epsilon;
    const at_right = state.scroll_x >= max - epsilon;
    return (at_left and delta < 0) or (at_right and delta > 0);
}

/// rubber-band animation active (outward momentum rejected within duration)
pub fn hasBounceActive(state: *const ScrollState, direction: ScrollDirection) bool {
    return switch (direction) {
        .vertical => state.bounce_active_y,
        .horizontal => state.bounce_active_x,
        .both => state.bounce_active_y or state.bounce_active_x,
    };
}

fn hasActiveBonusForDirection(state: *const ScrollState, direction: ScrollDirection) bool {
    return switch (direction) {
        .vertical => state.bonus_y != 0,
        .horizontal => state.bonus_x != 0,
        .both => state.bonus_y != 0 or state.bonus_x != 0,
    };
}

pub fn isOutwardAtBoundary(state: *const ScrollState, direction: ScrollDirection, dx: f32, dy: f32, speed: f32) bool {
    const v_delta = -dy * speed;
    const h_delta = -dx * speed;
    return switch (direction) {
        .vertical => isOutwardAtBoundaryY(state, v_delta),
        .horizontal => isOutwardAtBoundaryX(state, h_delta),
        // .both: axes with delta=0 treated neutral (don't participate), only check outward for
        // non-zero delta axes
        .both => blk: {
            const has_v = canScrollVerticalAxis(state);
            const has_h = canScrollHorizontalAxis(state);
            const v_active = has_v and v_delta != 0;
            const h_active = has_h and h_delta != 0;
            if (v_active and h_active) {
                break :blk isOutwardAtBoundaryY(state, v_delta) and isOutwardAtBoundaryX(state, h_delta);
            }
            if (v_active) break :blk isOutwardAtBoundaryY(state, v_delta);
            if (h_active) break :blk isOutwardAtBoundaryX(state, h_delta);
            break :blk false; // neither axis has active delta
        },
    };
}

const ScrollAxis = enum {
    vertical,
    horizontal,
};

fn supportsAxis(direction: ScrollDirection, axis: ScrollAxis) bool {
    return switch (direction) {
        .vertical => axis == .vertical,
        .horizontal => axis == .horizontal,
        .both => true,
    };
}

/// single ancestor chain traverse, check if ancestor ScrollArea supports axis and is active
const AncestorCheckResult = struct {
    exists: bool,
    is_active: bool,
    /// does any ancestor hold current gesture's latch (for momentum ownership)
    has_latch: bool,
};

fn checkAncestorScrollArea(container: *Node, axis: ScrollAxis) AncestorCheckResult {
    var result = AncestorCheckResult{ .exists = false, .is_active = false, .has_latch = false };
    var node = container.parent;
    while (node) |n| : (node = n.parent) {
        if (n.behavior.events.on_event) |handler| {
            if (handler == scrollEventHandler) {
                if (n.behavior.events.event_context) |raw_ctx| {
                    const ancestor_ctx: *const ScrollEventCtx = @ptrCast(@alignCast(raw_ctx));
                    if (!supportsAxis(ancestor_ctx.direction, axis)) continue;
                    result.exists = true;
                    const s = ancestor_ctx.state;
                    if (s.latched) result.has_latch = true;
                    // ancestor holding current trackpad gesture (finger on pad)
                    if (s.touching) {
                        result.is_active = true;
                        break; // found active ancestor, no need continue
                    }
                }
            }
        }
    }
    return result;
}

fn shouldDelegateVerticalToAncestor(state: *ScrollState, ctx: *const ScrollEventCtx, dy: f32, is_momentum: bool) bool {
    if (dy == 0) return false;
    const container = ctx.container orelse return false;
    const ancestor = checkAncestorScrollArea(container, .vertical);
    if (!ancestor.exists) return false;

    const delta = -dy * ctx.scroll_speed;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    if (@abs(delta) <= epsilon) return false;
    // macOS gesture latching: momentum goes to latch holder; this layer's latch never bubbles, else
    // bubbles if active/latch ancestor (momentum follows gesture initiator).
    if (is_momentum) {
        if (state.latched) return false;
        return ancestor.is_active or ancestor.has_latch;
    }
    if (ancestor.is_active) return true;
    // no hand-off mid-gesture (NSScrollView 10.9+ latch semantics): once this layer starts
    // handling, stay rubber-band even at boundary, don't bubble.
    if (state.touching) return false;

    const max = state.maxScrollY();
    if (max <= epsilon) return true;

    const projected = state.scroll_y + delta;
    if (projected < -epsilon) {
        if (state.scroll_y > 0) state.scroll_y = 0;
        state.bonus_y = 0;
        state.bonus_velocity = 0;
        return true;
    }
    if (projected > max + epsilon) {
        if (state.scroll_y < max) state.scroll_y = max;
        state.bonus_y = 0;
        state.bonus_velocity = 0;
        return true;
    }
    return false;
}

fn shouldDelegateHorizontalToAncestor(state: *ScrollState, ctx: *const ScrollEventCtx, dx: f32, is_momentum: bool) bool {
    if (dx == 0) return false;
    const container = ctx.container orelse return false;
    const ancestor = checkAncestorScrollArea(container, .horizontal);
    if (!ancestor.exists) return false;

    const delta = -dx * ctx.scroll_speed;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    if (@abs(delta) <= epsilon) return false;
    if (is_momentum) {
        if (state.latched) return false;
        return ancestor.is_active or ancestor.has_latch;
    }
    if (ancestor.is_active) return true;
    // no hand-off mid-gesture (latch), rubber-band when at boundary
    if (state.touching) return false;

    const max = state.maxScrollX();
    if (max <= epsilon) return true;

    const projected = state.scroll_x + delta;
    if (projected < -epsilon) {
        if (state.scroll_x > 0) state.scroll_x = 0;
        state.bonus_x = 0;
        state.bonus_velocity_x = 0;
        return true;
    }
    if (projected > max + epsilon) {
        if (state.scroll_x < max) state.scroll_x = max;
        state.bonus_x = 0;
        state.bonus_velocity_x = 0;
        return true;
    }
    return false;
}

pub fn isAtHorizontalBoundary(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollX();
    if (max <= epsilon) return true;
    return state.scroll_x <= epsilon or state.scroll_x >= max - epsilon;
}

fn syncContentTranslate(state: *const ScrollState, content: *Node) void {
    const new_ty = state.contentTranslateY();
    const new_tx = state.contentTranslateX();
    if (new_ty != content.style.translate_y or new_tx != content.style.translate_x) {
        content.style.translate_y = new_ty;
        content.style.translate_x = new_tx;
        // scroll frame-by-frame offset (content unchanged): anim-frame combo
        // (interaction+composite).
        content.markHitLayerMotionAnimFrameDirty();
    }
}

/// does momentum on Y axis no longer affect content: overscroll owned by spring; or this segment's
/// momentum already hit boundary and still pushing out.
fn momentumBlockedY(state: *const ScrollState, dy: f32, speed: f32) bool {
    if (dy == 0) return false;
    if (state.bonus_y != 0) return true;
    return state.momentum_spent_y and isOutwardAtBoundaryY(state, -dy * speed);
}

fn momentumBlockedX(state: *const ScrollState, dx: f32, speed: f32) bool {
    if (dx == 0) return false;
    if (state.bonus_x != 0) return true;
    return state.momentum_spent_x and isOutwardAtBoundaryX(state, -dx * speed);
}
