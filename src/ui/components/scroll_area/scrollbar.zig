/// ScrollArea scrollbar.
///
/// scrollbarBeforeRender + scrollbar event handlers + metrics calculation + dragging.
const std = @import("std");
const core = @import("../../core.zig");
const Node = core.Node;
const Event = core.Event;
const EventResult = core.EventResult;

const styles = @import("styles.zig");
const state_mod = @import("state.zig");
const ScrollState = state_mod.ScrollState;
const ScrollbarVisual = state_mod.ScrollbarVisual;
const ScrollbarAxisMetrics = state_mod.ScrollbarAxisMetrics;
const ScrollEventCtx = state_mod.ScrollEventCtx;

const scroll_event = @import("event.zig");
const scrollEventHandler = scroll_event.scrollEventHandler;

const debug = @import("debug.zig");
const logScroll = debug.logScroll;
const render_engine = @import("../../core/render_engine/mod.zig");

fn syncScrollbarFrame(node: *Node, x: f32, y: f32, w: f32, h: f32) bool {
    const cur = node.rectFromWorldOrFallback();
    const rect_changed =
        cur.x != x or cur.y != y or cur.w != w or cur.h != h;
    const margin_changed = @abs(node.style.margin.left - x) > 0.01 or
        @abs(node.style.margin.top - y) > 0.01 or
        node.style.marginLeftIsAuto() or
        node.style.marginTopIsAuto();

    if (margin_changed) {
        node.style.margin.left = x;
        node.style.margin.top = y;
        if (node.style.marginLeftIsAuto()) node.style.setMarginLeftAutoFallback(false);
        if (node.style.marginTopIsAuto()) node.style.setMarginTopAutoFallback(false);
    }

    node.setLayoutRect(.{ .x = x, .y = y, .w = w, .h = h });
    return rect_changed;
}

/// Thumb / track paint written by the per-frame hook: raw write (no transition), marked
/// render-dirty only when it changed, so an unchanged bar stays clean and cacheable while a fading
/// or resizing one is re-recorded (the container's descendants_cache_safe contract).
fn syncBarBackground(node: *Node, color: core.Color) void {
    if (std.meta.eql(node.getBackground(), color)) return;
    node.setBackgroundRaw(color);
    node.markRenderDirty();
}

fn syncBarBorder(node: *Node, border: core.Border) void {
    if (std.meta.eql(node.style.border, border)) return;
    node.style.border = border;
    node.markRenderDirty();
}

/// Before each frame render: bonus decay + update scrollbar.
pub fn scrollbarBeforeRender(container: *Node) void {
    if (container.behavior.events.on_event != scrollEventHandler) return;
    const ctx: *ScrollEventCtx = @ptrCast(@alignCast(container.behavior.events.event_context orelse return));
    const state = ctx.state;
    const content = ctx.content orelse return;
    const scrollbar = ctx.scrollbar orelse return;

    // Global hook reads rect.
    const cont_r = container.rectFromWorldOrFallback();
    const content_r = content.rectFromWorldOrFallback();
    // Update viewport/content size (only when rect valid, avoid first-frame rect=0 overwriting
    // mount init).
    if (cont_r.h > 0) {
        state.viewport_height = @max(0, cont_r.h - container.style.contentInsets().vertical());
    }
    if (cont_r.w > 0) {
        state.viewport_width = @max(0, cont_r.w - container.style.contentInsets().horizontal());
    }
    if (!state.external_content_height) {
        if (content_r.h > 0) state.content_height = content_r.h;
    }
    if (!state.external_content_width) {
        if (content_r.w > 0) state.content_width = content_r.w;
    }

    // After window resize, maxScroll may shrink or zero -> re-clamp prevent stuck.
    const max_y = state.maxScrollY();
    if (state.scroll_y > max_y) {
        state.scroll_y = max_y;
        content.style.translate_y = state.contentTranslateY();
        content.markHitLayerMotionPropDirty();
    }
    const max_x = state.maxScrollX();
    if (state.scroll_x > max_x) {
        state.scroll_x = max_x;
        content.style.translate_x = state.contentTranslateX();
        content.markHitLayerMotionPropDirty();
    }

    const now_ms = render_engine.current_frame_time_ms;

    // Collect redraw requests, unified single markRenderDirty call at end, avoid multiple upward
    // bubble marks.
    var needs_redraw = false;

    // Spring-back animation (absolute timestamp + duration easing drive).
    if (state.bonus_y != 0 or state.bounce_active_y) {
        const old_ty = content.style.translate_y;
        state.tickBonus(now_ms);
        content.style.translate_y = state.contentTranslateY();
        if (content.style.translate_y != old_ty) content.markHitLayerMotion();
        needs_redraw = true;
    }

    if (state.bonus_x != 0 or state.bounce_active_x) {
        const old_tx = content.style.translate_x;
        state.tickBonusX(now_ms);
        content.style.translate_x = state.contentTranslateX();
        if (content.style.translate_x != old_tx) content.markHitLayerMotion();
        needs_redraw = true;
    }

    // During spring-back animation enable text stable rendering (prevent subpixel variants flashing
    // in jello animation).
    const stabilize_text = state.bonus_y != 0 or state.bounce_active_y or
        state.bonus_x != 0 or state.bounce_active_x;
    if (content.frame_state.state_bits.flags.text_stabilize_subtree != stabilize_text) {
        content.frame_state.state_bits.flags.text_stabilize_subtree = stabilize_text;
        needs_redraw = true;
    }

    // Keep scrollbar visible during drag.
    if (state.scrollbar_dragging) {
        state.scrollbar_fade.onActivity();
        needs_redraw = true;
    }
    if (state.scrollbar_dragging_h) {
        state.scrollbar_fade_h.onActivity();
        needs_redraw = true;
    }

    // Scrollbar fade out.
    const old_v_visible = state.needsScrollbar() and state.scrollbar_fade.opacity > 0;
    const old_h_visible = state.needsHScrollbar() and state.scrollbar_fade_h.opacity > 0;
    const scrollbar_fade_changed = state.tickScrollbar();
    const v_visible = state.needsScrollbar() and state.scrollbar_fade.isVisible();
    const h_visible = state.needsHScrollbar() and state.scrollbar_fade_h.isVisible();
    if (scrollbar_fade_changed or v_visible != old_v_visible or h_visible != old_h_visible) {
        needs_redraw = true;
    }

    if (needs_redraw) {
        container.markRenderDirty();
    }
    const scrollbar_h = ctx.scrollbar_h orelse return;

    // Track is a non-interactive sibling behind the thumb. Keep fade and theme
    // resolution on the same frame as the thumb, including during drag.
    const track_size = ScrollbarVisual.track_thickness;
    if (ctx.track_v) |track| {
        const visible = v_visible and (state.scrollbar_hovered or state.scrollbar_dragging);
        const w: f32 = if (visible) track_size else 0;
        if (syncScrollbarFrame(track, cont_r.w - track_size, 0, w, if (visible) cont_r.h else 0)) track.markRenderDirty();
        syncBarBackground(track, styles.track(ctx.cx.tokens));
    }
    if (ctx.track_h) |track| {
        const visible = h_visible and (state.scrollbar_hovered_h or state.scrollbar_dragging_h);
        const h: f32 = if (visible) track_size else 0;
        if (syncScrollbarFrame(track, 0, cont_r.h - track_size, if (visible) cont_r.w else 0, h)) track.markRenderDirty();
        syncBarBackground(track, styles.track(ctx.cx.tokens));
    }

    // ---- Vertical scrollbar update ----
    if (!v_visible) {
        const cur = scrollbar.rectFromWorldOrFallback();
        const rect_changed = cur.w != 0 or cur.h != 0;
        scrollbar.style.width = .{ .px = 0 };
        scrollbar.style.height = .{ .px = 0 };
        scrollbar.setLayoutRect(.{ .x = cur.x, .y = cur.y, .w = 0, .h = 0 });
        if (rect_changed) scrollbar.markInteractionDirty();
    } else {
        const opacity = state.scrollbar_fade.opacity;
        const active = state.scrollbar_dragging or state.scrollbar_hovered;
        const bar_width: f32 = if (active) ScrollbarVisual.active_thickness else ScrollbarVisual.idle_thickness;
        const metrics = computeVerticalScrollbarMetrics(state);
        const bar_h = metrics.length;
        const bar_y = metrics.pos;

        scrollbar.style.width = .{ .px = bar_width };
        scrollbar.style.height = .{ .px = bar_h };
        // Scrollbar sticky to container edge, minimize content obstruction. Write both rect
        // (immediate this frame) and margin (maintain on layout rerun).
        const bar_x_local = cont_r.w - bar_width - ScrollbarVisual.edge_inset;
        const bar_y_local = container.style.contentInsets().top + bar_y;
        const rect_changed = syncScrollbarFrame(scrollbar, bar_x_local, bar_y_local, bar_width, bar_h);
        if (rect_changed) scrollbar.markInteractionDirty();
        syncBarBorder(scrollbar, .{ .radius = bar_width / 2 });

        const fade = std.math.clamp(opacity / @max(state.scrollbar_fade.active_opacity, 0.001), 0.0, 1.0);
        syncBarBackground(scrollbar, styles.thumb(ctx.cx.tokens, active, fade));
    }

    // ---- Horizontal scrollbar update ----
    if (!h_visible) {
        const cur = scrollbar_h.rectFromWorldOrFallback();
        const rect_changed = cur.w != 0 or cur.h != 0;
        scrollbar_h.style.width = .{ .px = 0 };
        scrollbar_h.style.height = .{ .px = 0 };
        scrollbar_h.setLayoutRect(.{ .x = cur.x, .y = cur.y, .w = 0, .h = 0 });
        if (rect_changed) scrollbar_h.markInteractionDirty();
    } else {
        const opacity_h = state.scrollbar_fade_h.opacity;
        const active_h = state.scrollbar_dragging_h or state.scrollbar_hovered_h;
        const bar_height: f32 = if (active_h) ScrollbarVisual.active_thickness else ScrollbarVisual.idle_thickness;
        const v_clearance: f32 = if (v_visible) ScrollbarVisual.cross_axis_clearance else 0;
        const metrics_h = computeHorizontalScrollbarMetrics(state, v_clearance);
        const bar_w = metrics_h.length;
        const bar_x = metrics_h.pos;

        scrollbar_h.style.width = .{ .px = bar_w };
        scrollbar_h.style.height = .{ .px = bar_height };
        // Horizontal sticky to bottom edge, reduce obstruction.
        const bar_x_local = container.style.contentInsets().left + bar_x;
        const bar_y_local = cont_r.h - bar_height - ScrollbarVisual.edge_inset;
        const rect_changed = syncScrollbarFrame(scrollbar_h, bar_x_local, bar_y_local, bar_w, bar_height);
        if (rect_changed) scrollbar_h.markInteractionDirty();
        syncBarBorder(scrollbar_h, .{ .radius = bar_height / 2 });

        const fade_h = std.math.clamp(opacity_h / @max(state.scrollbar_fade_h.active_opacity, 0.001), 0.0, 1.0);
        syncBarBackground(scrollbar_h, styles.thumb(ctx.cx.tokens, active_h, fade_h));
    }
}

/// Event handler on scrollbar node, hitTest direct hit scrollbar thumb, coordinates naturally
/// correct.
pub fn scrollbarEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *const ScrollEventCtx = @ptrCast(@alignCast(context.?));
    const state = ctx.state;
    const content = ctx.content orelse return .ignored;
    const sb = ctx.scrollbar orelse return .ignored;

    switch (event) {
        .mouse_down => |down| {
            // Begin drag immediately, don't distinguish thumb/track.
            state.scrollbar_dragging = true;
            state.scrollbar_last_mouse_y = down.y;
            state.scrollbar_hovered = true;
            state.bonus_y = 0;
            state.bonus_velocity = 0;
            state.onScrollActivity();
            ctx.cx.setPointerCapture(sb);
            return .stop;
        },
        .mouse_up => {
            if (state.scrollbar_dragging) {
                state.scrollbar_dragging = false;
                state.onScrollActivity(); // Trigger redraw, update scrollbar.rect.
                return .stop;
            }
            return .ignored;
        },
        .mouse_move => |move| {
            if (state.scrollbar_dragging) {
                const dy = move.y - state.scrollbar_last_mouse_y;
                state.scrollbar_last_mouse_y = move.y;
                applyScrollbarDrag(state, content, dy);
                return .stop;
            }
            state.scrollbar_hovered = true;
            state.onScrollActivity();
            return .ignored;
        },
        else => return .ignored,
    }
}

/// Event handler on horizontal scrollbar node.
pub fn scrollbarHEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *const ScrollEventCtx = @ptrCast(@alignCast(context.?));
    const state = ctx.state;
    const content = ctx.content orelse return .ignored;
    const scrollbar_h = ctx.scrollbar_h orelse return .ignored;

    switch (event) {
        .mouse_down => |down| {
            state.scrollbar_dragging_h = true;
            state.scrollbar_last_mouse_x = down.x;
            state.scrollbar_hovered_h = true;
            state.bonus_x = 0;
            state.bonus_velocity_x = 0;
            state.onScrollActivity();
            ctx.cx.setPointerCapture(scrollbar_h);
            return .stop;
        },
        .mouse_up => {
            if (state.scrollbar_dragging_h) {
                state.scrollbar_dragging_h = false;
                state.onScrollActivity();
                return .stop;
            }
            return .ignored;
        },
        .mouse_move => |move| {
            if (state.scrollbar_dragging_h) {
                const dx = move.x - state.scrollbar_last_mouse_x;
                state.scrollbar_last_mouse_x = move.x;
                applyHScrollbarDrag(state, content, dx);
                return .stop;
            }
            state.scrollbar_hovered_h = true;
            state.onScrollActivity();
            return .ignored;
        },
        else => return .ignored,
    }
}

// ========== Metrics calculation ==========

fn overscrollThumbShrinkFactor(raw_overscroll: f32, viewport: f32) f32 {
    if (raw_overscroll <= 0 or viewport <= 0) return 0;
    const zone = @max(viewport * 0.35, 1.0);
    const norm = raw_overscroll / zone;
    return norm / (1.0 + norm);
}

pub fn computeVerticalScrollbarMetrics(state: *const ScrollState) ScrollbarAxisMetrics {
    const base_h = state.scrollbarHeight();
    const max_scroll = state.maxScrollY();
    const track_top: f32 = 2;
    const track_h = @max(state.viewport_height - 4, 0);

    var base_y: f32 = track_top;
    if (max_scroll > 0 and track_h > base_h) {
        base_y = (state.scroll_y / max_scroll) * (track_h - base_h) + track_top;
    }
    if (state.bonus_y == 0 or track_h <= 0) {
        return .{ .pos = base_y, .length = base_h };
    }

    const raw_bonus = @abs(state.rubber_band.unclamp(state.bonus_y, state.viewport_height));
    const shrink = overscrollThumbShrinkFactor(raw_bonus, state.viewport_height);
    const min_h = @min(base_h, @max(18.0, base_h * 0.45));
    const visual_h = base_h - (base_h - min_h) * shrink;
    const clamped_h = std.math.clamp(visual_h, min_h, base_h);
    const pinned_y = if (state.bonus_y < 0)
        track_top
    else
        track_top + @max(track_h - clamped_h, 0);

    return .{ .pos = pinned_y, .length = clamped_h };
}

pub fn computeHorizontalScrollbarMetrics(state: *const ScrollState, v_clearance: f32) ScrollbarAxisMetrics {
    const base_w = state.hScrollbarWidth();
    const max_scroll = state.maxScrollX();
    const track_left: f32 = 2;
    const track_w_base = @max(state.viewport_width - base_w - 4 - v_clearance, 0);

    var base_x: f32 = track_left;
    if (max_scroll > 0 and track_w_base > 0) {
        base_x = (state.scroll_x / max_scroll) * track_w_base + track_left;
    }
    if (state.bonus_x == 0) {
        return .{ .pos = base_x, .length = base_w };
    }

    const raw_bonus = @abs(state.rubber_band_x.unclamp(state.bonus_x, state.viewport_width));
    const shrink = overscrollThumbShrinkFactor(raw_bonus, state.viewport_width);
    const min_w = @min(base_w, @max(18.0, base_w * 0.45));
    const visual_w = base_w - (base_w - min_w) * shrink;
    const clamped_w = std.math.clamp(visual_w, min_w, base_w);
    const track_w = @max(state.viewport_width - clamped_w - 4 - v_clearance, 0);
    const pinned_x = if (state.bonus_x < 0)
        track_left
    else
        track_left + track_w;

    return .{ .pos = pinned_x, .length = clamped_w };
}

// ========== Drag ==========

/// Mouse pixel delta -> scroll_y delta (track pixels : content pixels ratio conversion).
fn applyScrollbarDrag(state: *ScrollState, content: *Node, mouse_dy: f32) void {
    const bar_h = state.scrollbarHeight();
    const track_h = state.viewport_height - bar_h - 4;
    if (track_h <= 0) return;
    const max = state.maxScrollY();
    state.scroll_y = std.math.clamp(state.scroll_y + mouse_dy / track_h * max, 0, max);
    state.input_serial +%= 1;
    state.onScrollActivity();
    content.style.translate_y = state.contentTranslateY();
    content.markHitLayerMotionAnimFrameDirty();
}

/// Mouse pixel delta -> scroll_x delta (track pixels : content pixels ratio conversion).
fn applyHScrollbarDrag(state: *ScrollState, content: *Node, mouse_dx: f32) void {
    const bar_w = state.hScrollbarWidth();
    const track_w = state.viewport_width - bar_w - 4;
    if (track_w <= 0) return;
    const max = state.maxScrollX();
    state.scroll_x = std.math.clamp(state.scroll_x + mouse_dx / track_w * max, 0, max);
    state.input_serial +%= 1;
    state.onScrollActivity();
    content.style.translate_x = state.contentTranslateX();
    content.markHitLayerMotionAnimFrameDirty();
}
