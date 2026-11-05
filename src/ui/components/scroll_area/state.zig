/// ScrollArea scroll state
///
/// ScrollState struct + ScrollTuning params + all state methods
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const physics = @import("../../physics.zig");
const debug = @import("debug.zig");
const logScroll = debug.logScroll;

/// Scroll direction
pub const ScrollDirection = enum(u8) {
    vertical,
    horizontal,
    both,
};

pub const ScrollbarVisual = struct {
    // Design Scrollbar: rest 4, hover 6, track 10, inset 2, minimum thumb 24.
    pub const idle_thickness: f32 = 4;
    pub const track_thickness: f32 = 10;
    pub const min_length: f32 = 24;
    pub const active_thickness: f32 = 6;
    // Thumb inset from the outer edge (design zenit.scrollbar.inset).
    pub const edge_inset: f32 = 2;
    pub const hover_slop: f32 = 6;
    pub const cross_axis_clearance: f32 = 12;
    pub const idle_alpha: f32 = @as(f32, 0xA0) / 255.0;
    pub const hover_alpha: f32 = @as(f32, 0xA0) / 255.0;
    pub const dragging_alpha: f32 = @as(f32, 0xA0) / 255.0;
};

pub const ScrollbarAxisMetrics = struct {
    pos: f32,
    length: f32,
};

/// Scroll state (persisted via StateStore)
pub const ScrollState = struct {
    /// Clamped scroll offset, always in [0, max] range
    scroll_y: f32 = 0,
    scroll_x: f32 = 0,
    content_height: f32 = 0,
    content_width: f32 = 0,
    viewport_height: f32 = 0,
    viewport_width: f32 = 0,

    /// External content_height management (e.g., VirtualList), scrollbarBeforeRender no longer
    /// overrides with rect.h
    external_content_height: bool = false,
    /// External content_width management, scrollbarBeforeRender no longer overrides with rect.w
    external_content_width: bool = false,

    /// Vertical rubber band (jelly rebound) toggle
    rubber_band_y_enabled: bool = true,
    /// Horizontal rubber band (jelly rebound) toggle
    rubber_band_x_enabled: bool = true,

    /// Instance-level tuning override (non-null preferred over global scroll_tuning)
    tuning_override: ?ScrollTuning = null,

    /// Rubber band bonus: visual offset beyond boundary (positive=past bottom, negative=past top)
    bonus_y: f32 = 0,
    /// Bonus speed (spring physics, px/s)
    bonus_velocity: f32 = 0,
    /// Horizontal bonus
    bonus_x: f32 = 0,
    bonus_velocity_x: f32 = 0,
    /// Finger on trackpad and this layer owns the gesture (began/changed through ended/cancelled).
    /// No spring rebound during this window. Mouse wheel has no gesture, won't set.
    touching: bool = false,
    /// This layer receiving momentum (momentum began/changed through momentum ended or new gesture)
    momentum_active: bool = false,
    /// This momentum already overshot this axis (or already overshot when released):
    /// outward momentum thereafter handed to spring, no longer pushes content.
    /// Cleared when next gesture begins.
    momentum_spent_y: bool = false,
    momentum_spent_x: bool = false,
    /// Incremented each time actual user scroll input is applied (wheel/gesture/momentum/scrollbar
    /// drag).
    /// Host can compare values between frames to detect if this frame has scroll input.
    input_serial: u64 = 0,
    /// Associated PropertyTree.scrolls id (maxInt = not registered to World)
    world_scroll_id: u32 = std.math.maxInt(u32),
    /// World reference (write scroll offset); doesn't own
    world_ref: ?*anyopaque = null,
    /// macOS gesture latching: whether this layer is current gesture owner.
    /// First frame determines ownership, no mid-gesture hand-off (NSScrollView 10.9+ semantics),
    /// momentum follows latch.
    latched: bool = false,
    /// Rebound animation: critical damping spring (native NSScrollView feel), closed-form solution
    /// driven by absolute timestamp.
    bounce_start_time_y: f64 = 0,
    bounce_from_y: f32 = 0,
    /// Spring initial velocity (px/s, outward direction is positive bonus growth direction),
    /// carries incoming momentum
    bounce_v0_y: f32 = 0,
    bounce_active_y: bool = false,
    bounce_start_time_x: f64 = 0,
    bounce_from_x: f32 = 0,
    bounce_v0_x: f32 = 0,
    bounce_active_x: bool = false,

    // Vertical scrollbar animation (delegated to FadeIndicator)
    scrollbar_fade: physics.FadeIndicator = .{},
    scrollbar_hovered: bool = false,

    // Vertical scrollbar drag
    scrollbar_dragging: bool = false,
    scrollbar_last_mouse_y: f32 = 0, // previous frame mouse Y, used for delta calculation

    // Horizontal scrollbar animation
    scrollbar_fade_h: physics.FadeIndicator = .{},
    scrollbar_hovered_h: bool = false,

    // Horizontal scrollbar drag
    scrollbar_dragging_h: bool = false,
    scrollbar_last_mouse_x: f32 = 0, // previous frame mouse X, used for delta calculation

    /// Screen physical pixel ratio (Retina=2, standard=1).
    /// translate_y/x quantized to physical pixel grid, eliminates text scroll jitter.
    pixel_scale: f32 = 2.0,
    /// Optional horizontal translate rebasing for very large scroll_x values.
    /// Default 0 keeps the regular `translate_x = -effectiveScrollX()` behavior.
    horizontal_translate_rebase_quantum: f32 = 0,
    /// Application-managed vertical origin. Children may store positions
    /// relative to this base, while the content transform only carries the
    /// small residual `scroll_y - base` into layout/GPU f32 coordinates.
    vertical_translate_rebase_base: f32 = 0,

    // Rubber band physics (delegated to RubberBand)
    rubber_band: physics.RubberBand = .{},
    /// Horizontal axis same coefficient as vertical (native NSScrollView both axes identical, both
    /// 0.55)
    rubber_band_x: physics.RubberBand = .{},

    /// Default frame interval (seconds)
    pub const default_dt: f32 = 1.0 / 60.0;

    /// Tunable parameters (for demo adjustment)
    pub const ScrollTuning = ScrollTuningT;

    /// Global tuning (demo can modify)
    pub var scroll_tuning = ScrollTuningT{};

    pub fn maxScrollY(self: *const ScrollState) f32 {
        const max = self.content_height - self.viewport_height;
        return if (max > 0) max else 0;
    }

    pub fn maxScrollX(self: *const ScrollState) f32 {
        const max = self.content_width - self.viewport_width;
        return if (max > 0) max else 0;
    }

    /// Is user scrolling: finger on trackpad, momentum in progress, or dragging scrollbar.
    /// All driven by definite start/end signals, no timeout involved.
    pub fn inputActive(self: *const ScrollState) bool {
        return self.touching or self.momentum_active or self.scrollbar_dragging or self.scrollbar_dragging_h;
    }

    /// This layer begins holding a new trackpad gesture: catch in-progress rebound (keep current
    /// overshoot,
    /// content stops at finger position), end previous momentum.
    pub fn beginTouch(self: *ScrollState) void {
        if (self.touching) return;
        self.touching = true;
        self.momentum_active = false;
        self.momentum_spent_y = false;
        self.momentum_spent_x = false;
        self.bounce_active_y = false;
        self.bounce_active_x = false;
        self.bonus_velocity = 0;
        self.bonus_velocity_x = 0;
    }

    /// Return instance-level tuning (use override if exists, else global)
    pub fn tuning(self: *const ScrollState) ScrollTuningT {
        return self.tuning_override orelse scroll_tuning;
    }

    /// actual visual offset = scroll_y + bonus_y
    pub fn effectiveScrollY(self: *const ScrollState) f32 {
        return self.scroll_y + self.bonus_y;
    }

    /// actual horizontal visual offset = scroll_x + bonus_x
    pub fn effectiveScrollX(self: *const ScrollState) f32 {
        return self.scroll_x + self.bonus_x;
    }

    /// Snap logical pixel value to physical pixel grid (eliminates text scroll jitter).
    /// Example: pixel_scale=2, 12.3 -> 12.5 (= 25 physical pixels / 2).
    pub fn snapToPixel(self: *const ScrollState, v: f32) f32 {
        const s = self.pixel_scale;
        return @round(v * s) / s;
    }

    pub fn horizontalTranslateBase(self: *const ScrollState, scroll_x_value: f32) f32 {
        const quantum = self.horizontal_translate_rebase_quantum;
        if (quantum <= 0 or !std.math.isFinite(scroll_x_value) or @abs(scroll_x_value) < quantum * 2) return 0;
        return @floor(scroll_x_value / quantum) * quantum;
    }

    pub fn contentTranslateX(self: *const ScrollState) f32 {
        const scroll = self.effectiveScrollX();
        const base = self.horizontalTranslateBase(scroll);
        return -self.snapToPixel(scroll - base);
    }

    pub fn contentTranslateY(self: *const ScrollState) f32 {
        const scroll = self.effectiveScrollY();
        const base = if (std.math.isFinite(self.vertical_translate_rebase_base))
            self.vertical_translate_rebase_base
        else
            0;
        return -self.snapToPixel(scroll - base);
    }

    /// Incoming velocity cap (px/s), prevent extreme fling from pushing spring too deep
    const max_bounce_v0: f32 = 2500;
    /// Spring convergence criteria: both displacement and velocity sufficiently small to settle
    const bounce_settle_pos: f32 = 0.4;
    const bounce_settle_vel: f32 = 24.0;

    /// Critical damping spring closed-form: b(t) = (b0 + (v0 + lambda*b0)*t)*e^(-lambda*t).
    /// v0 carries incoming momentum: fling into boundary first overshoots briefly then smoothly
    /// rebounds (native feel),
    /// continuous velocity with rubber-band phase, no shift jolt.
    fn springAt(b0: f32, v0: f32, lambda: f32, t: f32) struct { pos: f32, vel: f32 } {
        const c1 = v0 + lambda * b0;
        const decay = @exp(-lambda * t);
        const pos = (b0 + c1 * t) * decay;
        const vel = (c1 - lambda * (b0 + c1 * t)) * decay;
        return .{ .pos = pos, .vel = vel };
    }

    /// Start vertical rebound animation (spring from current bonus_y / bonus_velocity back to 0)
    pub fn startBounceY(self: *ScrollState, now_ms: f64) void {
        if (self.bonus_y == 0) return;
        self.bounce_from_y = self.bonus_y;
        self.bounce_v0_y = std.math.clamp(self.bonus_velocity, -max_bounce_v0, max_bounce_v0);
        self.bounce_start_time_y = now_ms;
        self.bounce_active_y = true;
        logScroll("bounce START Y: from={d:.2} v0={d:.1}", .{ self.bonus_y, self.bounce_v0_y });
    }

    /// Start horizontal rebound animation
    pub fn startBounceX(self: *ScrollState, now_ms: f64) void {
        if (self.bonus_x == 0) return;
        self.bounce_from_x = self.bonus_x;
        self.bounce_v0_x = std.math.clamp(self.bonus_velocity_x, -max_bounce_v0, max_bounce_v0);
        self.bounce_start_time_x = now_ms;
        self.bounce_active_x = true;
        logScroll("bounce START X: from={d:.2} v0={d:.1}", .{ self.bonus_x, self.bounce_v0_x });
    }

    /// Per-frame rebound: critical damping spring, absolute timestamp-driven.
    /// During rebound active outward momentum rejected by event handler.
    pub fn tickBonus(self: *ScrollState, now_ms: f64) void {
        if (!self.bounce_active_y) {
            // Non-animation state: has bonus and finger off pad, start rebound
            if (self.bonus_y != 0 and !self.touching) {
                self.startBounceY(now_ms);
            } else {
                return;
            }
        }
        if (self.touching) {
            // Finger down -> interrupt rebound
            self.bounce_active_y = false;
            logScroll("tickBonus INTERRUPTED: bonus_y={d:.2} touching", .{self.bonus_y});
            return;
        }

        const t: f32 = @floatCast((now_ms - self.bounce_start_time_y) / 1000.0);
        const s = springAt(self.bounce_from_y, self.bounce_v0_y, self.tuning().bounce_spring_lambda, @max(t, 0));
        self.bonus_y = s.pos;
        self.bonus_velocity = s.vel;

        logScroll("BOUNCE_Y: t={d:.3}s bonus={d:.2} vel={d:.1}", .{ t, self.bonus_y, s.vel });

        if (@abs(s.pos) < bounce_settle_pos and @abs(s.vel) < bounce_settle_vel) {
            self.bonus_y = 0;
            self.bonus_velocity = 0;
            self.bounce_active_y = false;
            logScroll("bounce DONE Y", .{});
        }
    }

    /// Horizontal rebound
    pub fn tickBonusX(self: *ScrollState, now_ms: f64) void {
        if (!self.bounce_active_x) {
            if (self.bonus_x != 0 and !self.touching) {
                self.startBounceX(now_ms);
            } else {
                return;
            }
        }
        if (self.touching) {
            self.bounce_active_x = false;
            return;
        }

        const t: f32 = @floatCast((now_ms - self.bounce_start_time_x) / 1000.0);
        const s = springAt(self.bounce_from_x, self.bounce_v0_x, self.tuning().bounce_spring_lambda, @max(t, 0));
        self.bonus_x = s.pos;
        self.bonus_velocity_x = s.vel;

        logScroll("BOUNCE_X: t={d:.3}s bonus={d:.2} vel={d:.1}", .{ t, self.bonus_x, s.vel });

        if (@abs(s.pos) < bounce_settle_pos and @abs(s.vel) < bounce_settle_vel) {
            self.bonus_x = 0;
            self.bonus_velocity_x = 0;
            self.bounce_active_x = false;
            logScroll("bounce DONE X", .{});
        }
    }

    /// Content overflows viewport
    pub fn needsScrollbar(self: *const ScrollState) bool {
        return self.content_height > self.viewport_height and self.viewport_height > 0;
    }

    /// Scrollbar height (min 24px)
    pub fn scrollbarHeight(self: *const ScrollState) f32 {
        if (self.content_height <= 0) return ScrollbarVisual.min_length;
        const ratio = self.viewport_height / self.content_height;
        return @max(ScrollbarVisual.min_length, ratio * self.viewport_height);
    }

    /// Scrollbar Y position
    pub fn scrollbarY(self: *const ScrollState) f32 {
        const max_scroll = self.maxScrollY();
        if (max_scroll <= 0) return 2;
        const bar_h = self.scrollbarHeight();
        const track_h = self.viewport_height - bar_h - 4;
        return (self.scroll_y / max_scroll) * track_h + 2;
    }

    /// Horizontal content overflows viewport
    pub fn needsHScrollbar(self: *const ScrollState) bool {
        return self.content_width > self.viewport_width and self.viewport_width > 0;
    }

    /// Horizontal scrollbar width (min 24px)
    pub fn hScrollbarWidth(self: *const ScrollState) f32 {
        if (self.content_width <= 0) return ScrollbarVisual.min_length;
        const ratio = self.viewport_width / self.content_width;
        return @max(ScrollbarVisual.min_length, ratio * self.viewport_width);
    }

    pub fn onScrollActivity(self: *ScrollState) void {
        // Default both axes active (for scenarios without axis info: drag, hover)
        self.onScrollActivityAxes(true, true);
    }

    /// Per-axis scrollbar fade activation.
    /// VSCode/Zed standard: pure Y scroll shows only Y scrollbar; pure X likewise.
    pub fn onScrollActivityAxes(self: *ScrollState, axis_y: bool, axis_x: bool) void {
        if (axis_y) self.scrollbar_fade.onActivity();
        if (axis_x) self.scrollbar_fade_h.onActivity();
        // Sync tuning to instance (override preferred when present)
        self.rubber_band.coefficient = self.tuning().rubber_band_coeff;
    }

    pub fn tickScrollbar(self: *ScrollState) bool {
        const old_opacity = self.scrollbar_fade.opacity;
        const old_opacity_h = self.scrollbar_fade_h.opacity;
        self.scrollbar_fade.hovered = self.scrollbar_hovered;
        self.scrollbar_fade.tick();
        self.scrollbar_fade_h.hovered = self.scrollbar_hovered_h;
        self.scrollbar_fade_h.tick();
        return self.scrollbar_fade.opacity != old_opacity or
            self.scrollbar_fade_h.opacity != old_opacity_h;
    }
};

/// Tunable parameters (for demo adjustment)
pub const ScrollTuningT = struct {
    /// Overshoot drag damping coefficient (Apple UIScrollView standard = 0.55)
    /// runtime sync to state.rubber_band.coefficient
    rubber_band_coeff: f32 = 0.55,
    /// Tiny threshold for jitter elimination (px)
    jitter_snap_epsilon: f32 = 0.35,
    /// Pre-drag resistance zone before boundary (px).
    /// Native macOS: 1:1 frictionless until boundary (rubber band only acts past boundary), default
    /// off;
    /// retain parameter for special scenario opt-in.
    edge_resistance_zone_px: f32 = 0.0,
    /// Rebound spring critical damping coefficient lambda (1/s). settle ~= 6.6/lambda ~= 470ms,
    /// aligned with NSScrollView.
    bounce_spring_lambda: f32 = 14.0,
    /// Minimum throughput ratio at boundary (user-driven scroll)
    edge_resistance_min_factor: f32 = 0.16,
    /// Minimum throughput ratio at boundary (momentum, higher resistance)
    momentum_edge_resistance_min_factor: f32 = 0.12,
};

/// Intermediate cell between Node on_cleanup and ScrollEventCtx.
/// Why: on_cleanup must null the node pointer on ctx, but **a node may outlive ctx and be
/// unreachable
/// by detachChild**: (1) VirtualList recycles slots via `detachChild + cx.freeNode`: on_cleanup
/// runs
/// but the scope is **not** disposed, ctx's four fields are cleared, ctx lives on. (2) In retain
/// mode
/// one ctx may mount on **multiple** nodes (stale duplicates) that `detachScrollAreaBindings` can't
/// reach (it only sees ctx's four slots). (3) scope.dispose() then frees ctx, and the unreachable
/// node's
/// callback later writes freed memory at freeNode -> SIGSEGV.
/// So callbacks target this cell, **exclusively held by Cx** (Cx.scroll_ctx_cells): ctx release
/// only
/// nulls its `ctx` slot; stale nodes see ctx==null (safe no-op). Each installed
/// node callback owns one reference, released on invocation or explicit detach.
/// A later mount may reclaim a cell only when ctx==null and references==0;
/// Cx.deinit remains the fallback for escaped nodes. Neither callback frees it.
pub const ScrollCtxCell = struct {
    /// scope dispose of ScrollEventCtx nulls this.
    ctx: ?*ScrollEventCtx = null,
    references: usize = 0,

    pub fn release(self: *ScrollCtxCell) void {
        std.debug.assert(self.references != 0);
        self.references -= 1;
    }
};

pub const ScrollEventCtx = struct {
    persist_key: ?[]const u8 = null,
    state: *ScrollState = undefined,
    /// Node pointer cleared by Node.ownership.hooks.on_cleanup when associated ScrollArea node
    /// freeNode.
    /// So scope.dispose() cleanup callbacks after node **already** released still safely skip
    /// dangling pointer.
    content: ?*Node = null,
    container: ?*Node = null,
    scrollbar: ?*Node = null,
    scrollbar_h: ?*Node = null,
    track_v: ?*Node = null,
    track_h: ?*Node = null,
    /// Node on_cleanup actually writes to this intermediate cell (see ScrollCtxCell).
    cell: ?*ScrollCtxCell = null,
    cx: *Cx = undefined,
    scroll_speed: f32 = 1,
    direction: ScrollDirection = .vertical,
    scrollbar_thumb: Color = Color.hex(0xffffff),
};
