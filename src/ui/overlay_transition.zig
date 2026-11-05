//! Clock and easing tables for overlay enter/exit transitions, extracted from `overlay_stack.zig`.
//!
//! Contains only:
//!   - `Transition` enum (enter/exit_transition fields in LayerConfig)
//!   - `TransitionController` progress state (enter_ctrl / exit_ctrl instance fields on
//!     OverlayLayer)
//!   - `apply()` writes opacity/translate/scale to nodes (only touch point from node tree side)
//! Internally consistent, no dependency on layer stack fields.
//!
//! **The interface cuts between "interlayer relations" and "single-layer animation clock"**:
//! tier/nesting inheritance/mutual exclusion groups/outside-click/focus restoration stay in
//! overlay_stack.zig (need the full-stack view); this module only answers "what should this
//! layer's progress be now, what style to draw".
//!
//! **What NOT to move**:
//!   - `holdEnterUntilGeometryStable`: reads/writes OverlayLayer's enter_last_content_rect /
//!     enter_paused, part of the layer state machine; extracting would gut layer fields.
//!   - `setManualTransitionFlags`: writes manual animation flags to Node.frame_state, part of
//!     the node dirty-bit protocol, not the transition clock.
//!
//! Dependencies: easing tables (Easing) and node types are imported from their small modules
//! directly. **Don't import core.zig**: core.zig reverse-imports this module's consumers
//! (overlay_stack.zig), so a hard import creates a cycle. The clock only consumes the
//! read-only global `render_engine.current_frame_dt_ms` (first-frame dt), so pure Zig unit
//! tests can run full timing without a node tree / render engine.
//!
//! Pitfalls (do not change):
//!   1. First frame (pending_first_tick) uses `current_frame_dt_ms`, not `now - start_time_ms`:
//!      initWithTime's now is typically the push frame's timestamp while the animation starts
//!      rendering next frame, so a direct diff includes the inter-frame interval and loses the
//!      entrance's first frame.
//!   2. enter_delay and post-first-frame transitions use wall-clock. Only the first visible step
//!      keeps the maxStepMs limit; discarding >24ms per frame stretches short transitions to
//!      seconds.
//!   3. exit duration ~= enter x 0.7: closing is intentionally faster.
//!   4. mid-entrance exit must `seedFromProgress` from current progress, else progress jumps to
//!      1.0 and flashes a frame.

const std = @import("std");
const a11y_preferences = @import("a11y/preferences.zig");
const Allocator = std.mem.Allocator;
const node_mod = @import("core/node.zig");
const Node = node_mod.Node;
const easing_mod = @import("animation/easing.zig");
const Easing = easing_mod.Easing;
// Imports only current_frame_dt_ms (read-only global; see pending_first_tick
// branch). Can't refactor to parameter: ctrl.update(now_ms) calls scattered
// across overlay_stack / components.
const render_engine = @import("core/render_engine/mod.zig");

/// Transition animation presets (types of LayerConfig.enter_transition /
/// exit_transition).
pub const Transition = enum {
    none,
    fade,
    /// Short-duration fade for instant-feel popups (autocomplete, inline hints).
    fade_fast,
    scale_fade,
    /// Anchored dropdown (notification center): 160ms ease-out enter / 120ms exit,
    /// opacity + scale 0.98 (origin at anchor side). 6px slide-to-anchor via
    /// Popover positioner (exclusive translate); see dropdownSlideOffset.
    dropdown,
    /// Liquid Glass popover (macOS .popover; measured in native_menu_morph.swift):
    /// spring-scale from origin (arrow tip to anchor), opacity = min(scale, 1).
    /// Enter: spring(0.336, 0.783), peak 1.019. Exit: 1 - spring(0.378, 0.797),
    /// zero at 0.249s. Fitted RMS 0.003 / 0.004.
    glass_popover,
    /// Native menu (SwiftUI Menu glass; measured in native_menu_morph.swift):
    /// open full at frame, no scale/fade-in. Close: exp(-t/48.3ms) fade-out,
    /// invisible after 0.19s. Fitted RMS 0.011.
    menu_fade,
    slide_bottom,
    slide_right,
    slide_left,
    slide_top,
};

pub const glass_popover_enter_ms: f32 = 460;
pub const glass_popover_exit_ms: f32 = 249;
/// Hidden scale floor: avoids zero matrix (singular; hit test / composite
/// inversion divides by zero). Opacity = 0 at this scale.
pub const glass_popover_hidden_scale: f32 = 0.02;
/// .menu_fade exit: exp(-t/tau), ends below 0.02 (approx 0.19s).
pub const menu_fade_tau_ms: f32 = 48.3;
pub const menu_fade_exit_ms: f32 = 190;

/// SwiftUI spring(response, dampingFraction) 0->1 step response.
fn springStep(t_s: f32, response: f32, damping: f32) f32 {
    if (t_s <= 0) return 0;
    const w = 2.0 * std.math.pi / response;
    const wd = w * @sqrt(1.0 - damping * damping);
    return 1.0 - @exp(-damping * w * t_s) * (@cos(wd * t_s) + damping * w / wd * @sin(wd * t_s));
}

/// .glass_popover visual: enter spring(0.336, 0.783), exit 1 -
/// spring(0.378, 0.797).
pub fn glassPopoverScale(direction: enum { entering, exiting }, t_ms: f32) f32 {
    const t = t_ms / 1000.0;
    return switch (direction) {
        .entering => springStep(t, 0.336, 0.783),
        .exiting => @max(0.0, 1.0 - springStep(t, 0.378, 0.797)),
    };
}

/// Enter spring peak time and value (overshoot): monotonic on [0, peak_t].
pub const glass_popover_peak_ms: f32 = 270;

fn glassPopoverTimeForValue(direction: anytype, value: f32) f32 {
    // Enter monotonic on [0, peak_t]; exit monotonic on [0, 249ms].
    var lo: f32 = 0;
    var hi: f32 = if (direction == .entering) glass_popover_peak_ms else glass_popover_exit_ms;
    var k: usize = 0;
    while (k < 40) : (k += 1) {
        const mid = (lo + hi) / 2;
        const v = switch (direction) {
            .entering => glassPopoverScale(.entering, mid),
            .exiting => glassPopoverScale(.exiting, mid),
        };
        const before = if (direction == .entering) v < value else v > value;
        if (before) lo = mid else hi = mid;
    }
    return (lo + hi) / 2;
}

/// Transition animation controller.
pub const TransitionController = struct {
    transition: Transition,
    /// 0.0 = hidden, 1.0 = fully visible
    progress: f32,
    /// First tick anchors current frame time; avoids missing first frame.
    pending_first_tick: bool = false,
    direction: Direction,
    /// Absolute timestamp (ms) when animation starts.
    start_time_ms: f64 = 0,
    elapsed_ms: f32 = 0,
    last_tick_time_ms: f64 = 0,
    /// Remaining enter delay (ms): while >0, update() consumes and pins progress
    /// at 0. Delay uses wall-clock (raw frame delta), not clamped by maxStepMs;
    /// frame drops don't stretch delay to seconds.
    delay_remaining_ms: f32 = 0,
    /// (dropdown-only) Displacement from rest position (px). Host (Popover
    /// positioner) sets each frame. apply() advances delta by opacity progress,
    /// same frame, no lag.
    slide: [2]f32 = .{ 0, 0 },
    /// .glass_popover exit starting amplitude: mid-enter interruption scales exit
    /// curve by visual value at interruption for position continuity.
    amplitude: f32 = 1,

    const Direction = enum { entering, exiting };

    /// Get transition duration (ms). Exit shorter than enter: user's deliberate
    /// action; UI shouldn't delay (Radix/Material standard: exit ~= enter * 0.7).
    fn durationMs(transition: Transition, direction: Direction) f32 {
        return switch (transition) {
            .none => 0,
            .fade => switch (direction) {
                .entering => 150,
                .exiting => 110,
            },
            .fade_fast => switch (direction) {
                .entering => 120,
                .exiting => 90,
            },
            .scale_fade => switch (direction) {
                .entering => 200,
                .exiting => 140,
            },
            .dropdown => switch (direction) {
                .entering => 160,
                .exiting => 120,
            },
            .glass_popover => switch (direction) {
                .entering => glass_popover_enter_ms,
                .exiting => glass_popover_exit_ms,
            },
            // Enter duration used only to complete controller frame; visual value always
            // 1 (see visualValue).
            .menu_fade => switch (direction) {
                .entering => 1,
                .exiting => menu_fade_exit_ms,
            },
            .slide_bottom, .slide_right, .slide_left, .slide_top => switch (direction) {
                .entering => 300,
                .exiting => 220,
            },
        };
    }

    /// Get easing function (applied to progress). Progress advances linearly:
    /// enter 0->1, exit 1->0. After ease-out: enter reads as decelerate (quick
    /// start slow end), exit as accelerate (slow start quick end) — Material's
    /// standard enter/exit pairing; no separate exit curve.
    fn transitionEasing(transition: Transition) Easing {
        return switch (transition) {
            .none => .linear,
            .fade, .fade_fast => .ease_out_quad,
            .scale_fade, .dropdown => .ease_out_cubic,
            // Visual value from glassPopoverScale directly; no easing applied.
            .glass_popover, .menu_fade => .linear,
            // iOS sheet feel: high initial velocity, long-tail deceleration; smoother
            // than cubic.
            .slide_bottom, .slide_right, .slide_left, .slide_top => .ease_out_quint,
        };
    }

    fn maxStepMs(transition: Transition) f32 {
        return switch (transition) {
            .none => 0,
            .fade, .fade_fast => 24,
            .scale_fade, .dropdown, .glass_popover, .menu_fade => 24,
            .slide_bottom, .slide_right, .slide_left, .slide_top => 24,
        };
    }

    pub fn hiddenScaleForTransition(transition: Transition) f32 {
        // Reduced motion: no scale, fade only.
        if (a11y_preferences.reduceMotion()) return 1.0;
        return switch (transition) {
            // Mainstream popover scale: 0.95-0.97 subtle pop (Radix/macOS NSPopover
            // level). Old 0.86 reads as "flying in"; large scale amplifies text
            // resampling artifacts during animation.
            .scale_fade => 0.95,
            .dropdown => 0.98,
            .glass_popover => glass_popover_hidden_scale,
            else => 1.0,
        };
    }

    pub fn init(transition: Transition, direction: Direction) TransitionController {
        return .{
            .transition = transition,
            .progress = switch (direction) {
                .entering => 0.0,
                .exiting => 1.0,
            },
            .direction = direction,
            // start_time_ms defaults to 0; set at runtime via initWithTime or
            // manually before use.
        };
    }

    /// Created at runtime; records current frame absolute timestamp.
    pub fn initWithTime(transition: Transition, direction: Direction, now_ms: f64) TransitionController {
        var ctrl = init(transition, direction);
        ctrl.start_time_ms = now_ms;
        ctrl.last_tick_time_ms = now_ms;
        ctrl.pending_first_tick = transition != .none;
        return ctrl;
    }

    /// Advance animation (timestamp-driven). Returns true = complete.
    /// pending_first_tick consumes current_frame_dt_ms (frame dt), not
    /// (now - start_time_ms); see module pitfall 1.
    pub fn update(self: *TransitionController, now_ms: f64) bool {
        if (render_engine.current_reduced_motion) {
            self.progress = if (self.direction == .entering) 1 else 0;
            self.pending_first_tick = false;
            self.last_tick_time_ms = now_ms;
            return true;
        }
        if (self.transition == .none) return true;

        const dur = durationMs(self.transition, self.direction);

        if (dur <= 0) return true;

        const first_tick = self.pending_first_tick;
        var raw_delta = if (first_tick)
            render_engine.current_frame_dt_ms
        else
            @as(f32, @floatCast(now_ms - self.last_tick_time_ms));
        self.pending_first_tick = false;
        self.last_tick_time_ms = now_ms;

        if (self.delay_remaining_ms > 0) {
            const consumed = @min(@max(raw_delta, 0.0), self.delay_remaining_ms);
            self.delay_remaining_ms -= consumed;
            raw_delta -= consumed;
            if (self.delay_remaining_ms > 0) return false;
        }

        // Preserve the first visible step, then honor elapsed wall time.
        // These are analytic easing curves, not unstable physics integration:
        // dropping every interval above 24 ms stretches a 150 ms fade into
        // seconds on WARP and after an ordinary dropped frame.
        const delta = if (first_tick)
            std.math.clamp(raw_delta, 0.0, maxStepMs(self.transition))
        else
            @max(raw_delta, 0.0);
        self.elapsed_ms = std.math.clamp(self.elapsed_ms + delta, 0.0, dur);
        const raw_progress = std.math.clamp(self.elapsed_ms / dur, 0.0, 1.0);

        switch (self.direction) {
            .entering => {
                self.progress = raw_progress;
                return self.progress >= 1.0;
            },
            .exiting => {
                self.progress = 1.0 - raw_progress;
                return self.progress <= 0.0;
            },
        }
    }

    /// Apply styling to node based on current progress.
    pub fn apply(self: *const TransitionController, node: *Node, allocator: Allocator) void {
        if (self.transition == .none) return;

        const ease = transitionEasing(self.transition);
        const opacity_t = ease.apply(self.progress);
        // Reduced motion (system preference): translation/scale pinned to end;
        // opacity fades. Layer transition degrades to dissolve (Apple HIG
        // alternative).
        const reduce_motion = a11y_preferences.reduceMotion();
        const motion_t: f32 = if (reduce_motion) 1.0 else opacity_t;

        switch (self.transition) {
            .none => {},
            .fade, .fade_fast => {
                node.setOpacityRaw(opacity_t);
            },
            .dropdown => {
                // Host owns translate (Popover writes rest + current offset each frame);
                // here applies delta = new - old (old inferred from node opacity), same
                // frame.
                const old_t = std.math.clamp(node.getOpacity(), 0, 1);
                node.setOpacityRaw(opacity_t);
                const start_scale = hiddenScaleForTransition(self.transition);
                const s = start_scale + (1.0 - start_scale) * motion_t;
                const ext = node.style.ensureExtPanic(allocator);
                ext.scale_x = s;
                ext.scale_y = s;
                if (!reduce_motion) {
                    node.style.translate_x += self.slide[0] * ((1 - opacity_t) - (1 - old_t));
                    node.style.translate_y += self.slide[1] * ((1 - opacity_t) - (1 - old_t));
                }
                // The slide still in the translate: transient, out of the surface rest origin.
                ext.motion_offset = if (reduce_motion) .{ 0, 0 } else .{ self.slide[0] * (1 - opacity_t), self.slide[1] * (1 - opacity_t) };
            },
            .menu_fade => node.setOpacityRaw(self.visualValue()),
            .glass_popover => {
                const v = self.visualValue();
                node.setOpacityRaw(std.math.clamp(v, 0, 1));
                const s = if (reduce_motion) 1.0 else @max(v, glass_popover_hidden_scale);
                const ext = node.style.ensureExtPanic(allocator);
                ext.scale_x = s;
                ext.scale_y = s;
            },
            .scale_fade => {
                // Scale 0.95: front-load no longer creates "first-frame tiny-faint" artifact.
                // Opacity and scale share same ease-out curve, reads as single pop (old
                // linear scale made back half sluggish).
                node.setOpacityRaw(opacity_t);
                const start_scale = hiddenScaleForTransition(self.transition);
                const s = start_scale + (1.0 - start_scale) * motion_t;
                const ext = node.style.ensureExtPanic(allocator);
                ext.scale_x = s;
                ext.scale_y = s;
            },
            .slide_bottom => {
                node.setOpacityRaw(if (reduce_motion) opacity_t else slideOpacity(self.progress));
                // Global hook reads rect.
                const r = node.rectFromWorldOrFallback();
                const offset = (1.0 - motion_t) * r.h;
                node.style.translate_y = offset;
                // The whole slide is transient (the rest translate is 0).
                node.style.ensureExtPanic(allocator).motion_offset = .{ 0, offset };
            },
            .slide_right => {
                node.setOpacityRaw(if (reduce_motion) opacity_t else slideOpacity(self.progress));
                const r = node.rectFromWorldOrFallback();
                const offset = (1.0 - motion_t) * r.w;
                node.style.translate_x = offset;
                // The whole slide is transient (the rest translate is 0).
                node.style.ensureExtPanic(allocator).motion_offset = .{ offset, 0 };
            },
            .slide_left => {
                node.setOpacityRaw(if (reduce_motion) opacity_t else slideOpacity(self.progress));
                const r = node.rectFromWorldOrFallback();
                const offset = -(1.0 - motion_t) * r.w;
                node.style.translate_x = offset;
                // The whole slide is transient (the rest translate is 0).
                node.style.ensureExtPanic(allocator).motion_offset = .{ offset, 0 };
            },
            .slide_top => {
                node.setOpacityRaw(if (reduce_motion) opacity_t else slideOpacity(self.progress));
                const r = node.rectFromWorldOrFallback();
                const offset = -(1.0 - motion_t) * r.h;
                node.style.translate_y = offset;
                // The whole slide is transient (the rest translate is 0).
                node.style.ensureExtPanic(allocator).motion_offset = .{ 0, offset };
            },
        }
        // Overlay enter/exit transitions here only touch compositor-managed
        // properties (opacity / translate / scale). Marking render-dirty on every
        // frame would force the subtree content to rebuild and defeat promoted
        // surface reuse, which is exactly what causes text to shimmer during the
        // scale_fade animation. Keep this to interaction + composite dirtiness.
        node.markCompositeAnimFrameDirty();
    }

    /// Slide content opacity: fade-in complete at 45% into motion / fade-out
    /// starts at 55%. Mainstream sheet feel: "panel slides + backdrop fades";
    /// content fading throughout seems mushy; no fade seems jarring. Early fast
    /// ramp is compromise.
    fn slideOpacity(progress: f32) f32 {
        const t = std.math.clamp(progress / 0.45, 0.0, 1.0);
        return 1 - (1 - t) * (1 - t);
    }

    /// Resume animation from given progress (not endpoint). For mid-enter
    /// reversal to exit: exit starts from current enter progress, avoids
    /// "progress jumps 1.0 flash".
    pub fn seedFromProgress(self: *TransitionController, p0: f32) void {
        const dur = durationMs(self.transition, self.direction);
        if (dur <= 0) return;
        if (self.transition == .menu_fade) {
            const target = std.math.clamp(p0, 0.0, 1.0);
            switch (self.direction) {
                .entering => {
                    self.progress = 1.0;
                    self.elapsed_ms = dur;
                },
                .exiting => {
                    const t_ms = if (target <= 0.0) dur else @min(-menu_fade_tau_ms * @log(target), dur);
                    self.elapsed_ms = t_ms;
                    self.progress = 1.0 - t_ms / dur;
                },
            }
            return;
        }
        if (self.transition == .glass_popover) {
            // p0 = opposite controller visual value (can be >1 in overshoot).
            // Reverse-solve same visual value on this spring; no frame skip. Spring
            // monotonic on [0, peak] => binary search.
            const peak = glassPopoverScale(.entering, glass_popover_peak_ms);
            const target = std.math.clamp(p0, 0.0, peak);
            self.amplitude = 1;
            if (self.direction == .exiting and target >= 1.0) {
                // Exit starts from >=1: t=0, curve scaled proportionally by start.
                self.amplitude = target;
                self.elapsed_ms = 0;
                self.progress = 1.0;
                return;
            }
            const t_ms = glassPopoverTimeForValue(self.direction, target);
            self.elapsed_ms = t_ms;
            self.progress = switch (self.direction) {
                .entering => t_ms / dur,
                .exiting => 1.0 - t_ms / dur,
            };
            return;
        }
        const p = std.math.clamp(p0, 0.0, 1.0);
        self.progress = p;
        self.elapsed_ms = switch (self.direction) {
            .entering => p * dur,
            .exiting => (1.0 - p) * dur,
        };
    }

    /// This controller at its fully shown end: an enter's last frame, an exit's first. `apply`ing
    /// it writes exactly the open state of every property this transition animates (opacity,
    /// scale, slide translate, motion offset, the dropdown offset relative to the node's current
    /// opacity), so it undoes whatever the transition left on a node without a second definition
    /// of "shown". Host-fed state (the dropdown `slide`) is kept.
    pub fn shown(self: TransitionController) TransitionController {
        var ctrl = self;
        ctrl.progress = 1.0;
        ctrl.elapsed_ms = switch (ctrl.direction) {
            .entering => durationMs(ctrl.transition, .entering),
            .exiting => 0,
        };
        ctrl.amplitude = 1;
        ctrl.delay_remaining_ms = 0;
        ctrl.pending_first_tick = false;
        return ctrl;
    }

    pub fn isComplete(self: *const TransitionController) bool {
        if (self.transition == .none) return true;
        return switch (self.direction) {
            .entering => self.progress >= 1.0,
            .exiting => self.progress <= 0.0,
        };
    }

    pub fn currentOpacity(self: *const TransitionController) f32 {
        if (!transitionAffectsOpacity(self.transition)) return 1.0;
        if (self.transition == .glass_popover or self.transition == .menu_fade) return std.math.clamp(self.visualValue(), 0, 1);
        return transitionEasing(self.transition).apply(self.progress);
    }

    /// On reversal, seed value for opposite controller: spring transitions use
    /// visual value; others use linear progress (unchanged).
    pub fn visualProgress(self: *const TransitionController) f32 {
        if (self.transition == .menu_fade) return std.math.clamp(self.visualValue(), 0, 1);
        if (self.transition == .glass_popover) return @max(self.visualValue(), 0); // preserve overshoot (>1).
        return self.progress;
    }

    /// .glass_popover spring value (scale; >1 = overshoot); .menu_fade opacity.
    fn visualValue(self: *const TransitionController) f32 {
        const dur = durationMs(self.transition, self.direction);
        if (self.transition == .menu_fade) return switch (self.direction) {
            .entering => 1.0,
            .exiting => if (self.progress <= 0.0) 0.0 else @exp(-((1.0 - self.progress) * dur) / menu_fade_tau_ms),
        };
        return switch (self.direction) {
            .entering => if (self.progress >= 1.0) 1.0 else glassPopoverScale(.entering, self.progress * dur),
            .exiting => if (self.progress <= 0.0) 0.0 else self.amplitude * glassPopoverScale(.exiting, (1.0 - self.progress) * dur),
        };
    }
};

/// Whether transition affects opacity (determines LayerConfig needs
/// composited_group surface, manual_opacity_animation_active flag, etc.).
pub fn transitionAffectsOpacity(transition: Transition) bool {
    return switch (transition) {
        .none => false,
        .fade, .fade_fast, .scale_fade, .dropdown, .glass_popover, .menu_fade, .slide_bottom, .slide_right, .slide_left, .slide_top => true,
    };
}

/// Whether transition affects transform (translate / scale).
pub fn transitionAffectsTransform(transition: Transition) bool {
    return switch (transition) {
        .scale_fade, .dropdown, .glass_popover, .slide_bottom, .slide_right, .slide_left, .slide_top => true,
        .none, .fade, .fade_fast, .menu_fade => false,
    };
}

/// LayerConfig needs composited_group surface (any-direction transition
/// affects opacity/transform). Was private helper; kept: only table-driven
/// form of "why bindContentNode safely opens composited_group". Tier/z-order
/// changes hit this first.
pub fn layerNeedsCompositedGroup(enter: Transition, exit: Transition) bool {
    return transitionAffectsOpacity(enter) or
        transitionAffectsTransform(enter) or
        transitionAffectsOpacity(exit) or
        transitionAffectsTransform(exit);
}

// -- Tests --
//
// WARNING: collected only via `test { _ = @import("overlay_transition.zig"); }` at the end of
// overlay_stack.zig (refAllDecls does not recurse into test blocks; see build.zig:556-570).

test "TransitionController: fade enter" {
    // fade duration is 150 ms (see durationMs).
    var ctrl = TransitionController.initWithTime(.fade, .entering, 100.0);
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);

    // First update consumes `current_frame_dt_ms` (pending_first_tick path)
    // rather than (now - start), so 16ms / 150ms ≈ 0.107.
    render_engine.current_frame_dt_ms = 16.0;
    _ = ctrl.update(175.0);
    try std.testing.expect(ctrl.progress > 0.05 and ctrl.progress < 0.2);
    try std.testing.expect(!ctrl.isComplete());

    // Subsequent updates consume the full 75 ms interval: elapsed = 91 ms.
    _ = ctrl.update(250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 91.0 / 150.0), ctrl.progress, 0.0001);
    try std.testing.expect(!ctrl.isComplete());

    // Continue with normal frame-sized ticks to the same deadline.
    var t: f64 = 250.0;
    var safety: u32 = 0;
    while (!ctrl.isComplete() and safety < 64) : (safety += 1) {
        t += 16.0;
        _ = ctrl.update(t);
    }
    try std.testing.expect(ctrl.isComplete());
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.progress);
}

test "TransitionController: fade exit" {
    // Fade exit duration is 110 ms; only its first step is bounded.
    var ctrl = TransitionController.initWithTime(.fade, .exiting, 100.0);
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.progress);

    // First update: pending_first_tick path uses current_frame_dt_ms (16ms).
    // For .exiting: progress = 1.0 - 16/110 ≈ 0.855.
    render_engine.current_frame_dt_ms = 16.0;
    _ = ctrl.update(175.0);
    try std.testing.expect(ctrl.progress > 0.8 and ctrl.progress < 1.0);
    try std.testing.expect(!ctrl.isComplete());

    // Second update consumes 75 ms: elapsed = 91 ms, progress ≈ 0.173.
    _ = ctrl.update(250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - 91.0 / 110.0), ctrl.progress, 0.0001);
    try std.testing.expect(!ctrl.isComplete());

    // Drive to completion via normal frame-sized ticks.
    var t: f64 = 250.0;
    var safety: u32 = 0;
    while (!ctrl.isComplete() and safety < 64) : (safety += 1) {
        t += 16.0;
        _ = ctrl.update(t);
    }
    try std.testing.expect(ctrl.isComplete());
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
}

test "TransitionController: none is instant" {
    var ctrl = TransitionController.initWithTime(.none, .entering, 100.0);
    const done = ctrl.update(101.0);
    try std.testing.expect(done);
    try std.testing.expect(ctrl.isComplete());
}

test "TransitionController: enter delay holds progress at 0 then animates" {
    var ctrl = TransitionController.initWithTime(.scale_fade, .entering, 0);
    ctrl.delay_remaining_ms = 200;

    // During delay phase (~200ms, 12 frames): progress pinned at 0, animation incomplete.
    var now_ms: f64 = 0;
    for (0..12) |_| {
        now_ms += 16.0;
        try std.testing.expect(!ctrl.update(now_ms));
        try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);
    }

    // After delay expires, animation starts; progress monotonic increase to complete.
    var last_progress: f32 = 0;
    var completed = false;
    for (0..20) |_| {
        now_ms += 16.0;
        completed = ctrl.update(now_ms);
        try std.testing.expect(ctrl.progress + 0.0001 >= last_progress);
        last_progress = ctrl.progress;
        if (completed) break;
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.progress);
}

test "TransitionController: seedFromProgress starts exit from mid-enter progress" {
    // Mid-enter exit reversal: exit should start from 0.5, not flash at 1.0.
    var exit_ctrl = TransitionController.initWithTime(.scale_fade, .exiting, 0);
    exit_ctrl.seedFromProgress(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), exit_ctrl.progress);

    // Exit during delay hold (progress=0): first update completes, layer vanishes.
    var exit_from_hidden = TransitionController.initWithTime(.scale_fade, .exiting, 0);
    exit_from_hidden.seedFromProgress(0.0);
    try std.testing.expectEqual(@as(f32, 0.0), exit_from_hidden.progress);
    try std.testing.expect(exit_from_hidden.update(16.0));
}

test "enter delay 按 wall-clock 消耗，掉帧的大步不被 maxStepMs 截短" {
    // Pitfall 2 nail: delay 84ms left, frame 100ms comes => consume 84ms entire
    // and overflow into animation. If delay clamped by maxStepMs(24), only 24ms
    // consumed this frame, progress stays 0, delay stretches during frame drops.
    var ctrl = TransitionController.initWithTime(.fade, .entering, 0);
    ctrl.delay_remaining_ms = 100;
    render_engine.current_frame_dt_ms = 16.0;
    _ = ctrl.update(16.0); // pending_first_tick uses dt: consumes 16, leaves 84.
    try std.testing.expect(ctrl.delay_remaining_ms > 0);
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.progress);

    _ = ctrl.update(116.0); // 100ms frame: delay wall-clock zeroed and overflowed.
    try std.testing.expectEqual(@as(f32, 0.0), ctrl.delay_remaining_ms);
    try std.testing.expect(ctrl.progress > 0.0); // Overflow 16ms already in animation.
}

test "exit duration 比 enter 短（exit ≈ enter × 0.7）" {
    render_engine.current_frame_dt_ms = 16.0;
    var enter = TransitionController.initWithTime(.fade, .entering, 0);
    var exit_ = TransitionController.initWithTime(.fade, .exiting, 0);
    // After full duration, compare elapsed_ms (clamped to dur): exit must be shorter than enter.
    var t: f64 = 0;
    while (!enter.isComplete()) : (t += 16.0) {
        _ = enter.update(t);
    }
    var t2: f64 = 0;
    while (!exit_.isComplete()) : (t2 += 16.0) {
        _ = exit_.update(t2);
    }
    try std.testing.expect(exit_.elapsed_ms < enter.elapsed_ms);
}

test "TransitionController: slow frames preserve duration after bounded first step" {
    const previous_dt = render_engine.current_frame_dt_ms;
    defer render_engine.current_frame_dt_ms = previous_dt;
    render_engine.current_frame_dt_ms = 1000.0;
    for (std.meta.tags(Transition)) |transition| {
        if (transition == .none) continue;
        for ([_]TransitionController.Direction{ .entering, .exiting }) |direction| {
            var ctrl = TransitionController.initWithTime(transition, direction, 0);
            const duration = TransitionController.durationMs(transition, direction);
            if (duration <= TransitionController.maxStepMs(transition)) {
                // Duration not exceeding first-step cap (e.g., menu_fade enter: full appear
                // at frame): first step completes.
                try std.testing.expect(ctrl.update(1000.0));
                try std.testing.expectEqual(if (direction == .entering) @as(f32, 1) else @as(f32, 0), ctrl.progress);
                continue;
            }
            try std.testing.expect(!ctrl.update(1000.0));
            try std.testing.expectEqual(@as(f32, 24), ctrl.elapsed_ms);
            try std.testing.expect(ctrl.update(1000.0 + duration));
            try std.testing.expectEqual(if (direction == .entering) @as(f32, 1) else @as(f32, 0), ctrl.progress);
        }
    }
}

test "hiddenScaleForTransition 只有 scale_fade 收缩" {
    try std.testing.expectEqual(@as(f32, 0.95), TransitionController.hiddenScaleForTransition(.scale_fade));
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.fade));
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.slide_bottom));
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.none));
}

test "transitionAffectsOpacity / Transform / layerNeedsCompositedGroup 的表" {
    try std.testing.expect(!transitionAffectsOpacity(.none));
    try std.testing.expect(transitionAffectsOpacity(.fade));
    try std.testing.expect(transitionAffectsOpacity(.fade_fast));
    try std.testing.expect(transitionAffectsOpacity(.scale_fade));
    try std.testing.expect(transitionAffectsOpacity(.slide_top));
    try std.testing.expect(!transitionAffectsTransform(.fade));
    try std.testing.expect(transitionAffectsTransform(.scale_fade));
    try std.testing.expect(transitionAffectsTransform(.slide_left));
    try std.testing.expect(!transitionAffectsTransform(.none));

    // Any direction animates -> needs composited_group; both .none -> doesn't.
    try std.testing.expect(!layerNeedsCompositedGroup(.none, .none));
    try std.testing.expect(layerNeedsCompositedGroup(.fade, .none));
    try std.testing.expect(layerNeedsCompositedGroup(.none, .fade_fast));
    try std.testing.expect(layerNeedsCompositedGroup(.scale_fade, .scale_fade));
}

test "currentOpacity 在 .none 时恒 1.0" {
    var ctrl = TransitionController.initWithTime(.none, .entering, 0);
    ctrl.progress = 0.0;
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.currentOpacity());
}

test "enter 中途反向：exit seed 后继续单调走向 0" {
    render_engine.current_frame_dt_ms = 16.0;
    var exit_ctrl = TransitionController.initWithTime(.fade, .exiting, 0);
    exit_ctrl.seedFromProgress(0.7);
    var last: f32 = exit_ctrl.progress;
    var done = false;
    var t: f64 = 0;
    for (0..32) |_| {
        t += 16.0;
        done = exit_ctrl.update(t);
        try std.testing.expect(exit_ctrl.progress <= last + 0.0001);
        last = exit_ctrl.progress;
        if (done) break;
    }
    try std.testing.expect(done);
    try std.testing.expectEqual(@as(f32, 0.0), exit_ctrl.progress);
}

test "减少动态效果：浮层不缩放，只淡入淡出" {
    const saved = a11y_preferences.current();
    defer a11y_preferences.set(saved);
    a11y_preferences.set(.{ .reduce_motion = true });
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.scale_fade));
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.dropdown));
    a11y_preferences.set(.{});
    try std.testing.expectEqual(@as(f32, 0.95), TransitionController.hiddenScaleForTransition(.scale_fade));
}

test "reduced motion completes enter and exit without advancing the clock" {
    const saved = render_engine.current_reduced_motion;
    defer render_engine.current_reduced_motion = saved;
    render_engine.current_reduced_motion = true;
    var enter = TransitionController.initWithTime(.scale_fade, .entering, 100);
    var exit = TransitionController.initWithTime(.slide_bottom, .exiting, 100);
    try std.testing.expect(enter.update(100));
    try std.testing.expect(exit.update(100));
    try std.testing.expectEqual(@as(f32, 1), enter.progress);
    try std.testing.expectEqual(@as(f32, 0), exit.progress);
    render_engine.setFrameClock(.{ .io = std.testing.io, .time_ms = 100, .dt_ms = 16, .dt_seconds = 0.016 });
    var normal = TransitionController.initWithTime(.fade, .entering, 100);
    try std.testing.expect(!normal.update(100));
}

test "glass_popover: 弹簧曲线命中原生 SwiftUI .popover 采样（native_menu_morph.swift）" {
    // Native enter samples (time relative to fit start, scale); fitted RMS 0.003.
    const enter = [_][2]f32{ .{ 0.0, 0.0 }, .{ 270, 1.019 } };
    try std.testing.expectApproxEqAbs(enter[0][1], glassPopoverScale(.entering, enter[0][0]), 1e-4);
    try std.testing.expectApproxEqAbs(enter[1][1], glassPopoverScale(.entering, enter[1][0]), 0.002);
    // Native: overshoot ~1.5%, returns to 1 within 0.45s (+-0.002).
    try std.testing.expect(glassPopoverScale(.entering, 270) > 1.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), glassPopoverScale(.entering, glass_popover_enter_ms), 0.002);
    // Exit zeroes at 0.249s, monotonic throughout.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), glassPopoverScale(.exiting, glass_popover_exit_ms), 0.002);
    var prev: f32 = 1.0;
    var t: f32 = 0;
    while (t <= glass_popover_exit_ms) : (t += 4) {
        const v = glassPopoverScale(.exiting, t);
        try std.testing.expect(v <= prev + 1e-6);
        prev = v;
    }
}

test "glass_popover: 不透明度 = min(缩放, 1)，隐藏态缩放钉在下限" {
    var ctrl = TransitionController.initWithTime(.glass_popover, .entering, 0);
    try std.testing.expectEqual(@as(f32, 0), ctrl.currentOpacity());
    ctrl.progress = 270.0 / glass_popover_enter_ms;
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.currentOpacity()); // Overshoot-phase opacity capped at 1.0.
    ctrl.progress = 1.0;
    try std.testing.expectEqual(@as(f32, 1.0), ctrl.visualValue());
    try std.testing.expect(TransitionController.hiddenScaleForTransition(.glass_popover) > 0);
}

test "glass_popover: 进场中途反向退场视觉值连续" {
    var enter = TransitionController.initWithTime(.glass_popover, .entering, 0);
    enter.progress = 120.0 / glass_popover_enter_ms; // Visual value ~0.6.
    const v0 = enter.visualProgress();
    try std.testing.expect(v0 > 0.3 and v0 < 0.9);
    var exit = TransitionController.initWithTime(.glass_popover, .exiting, 0);
    exit.seedFromProgress(v0);
    try std.testing.expectApproxEqAbs(v0, exit.visualProgress(), 0.002);
    // Reverse back to enter.
    var again = TransitionController.initWithTime(.glass_popover, .entering, 0);
    again.seedFromProgress(exit.visualProgress());
    try std.testing.expectApproxEqAbs(v0, again.visualProgress(), 0.002);
}

test "menu_fade: 打开当帧完整出现，关闭按 exp(−t/48.3ms) 淡出（native_menu_morph.swift menu）" {
    var enter = TransitionController.initWithTime(.menu_fade, .entering, 0);
    try std.testing.expectEqual(@as(f32, 1.0), enter.currentOpacity()); // Fully visible even before any tick.
    var exit = TransitionController.initWithTime(.menu_fade, .exiting, 0);
    exit.seedFromProgress(enter.visualProgress());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), exit.currentOpacity(), 1e-4);
    // Native samples (relative to exit start 27ms): t=78ms 0.402, t=113ms 0.098
    // -> model exp(-(t-27)/48.3).
    exit.progress = 1.0 - 51.0 / menu_fade_exit_ms;
    try std.testing.expectApproxEqAbs(@as(f32, 0.348), exit.currentOpacity(), 0.01);
    exit.progress = 1.0 - 113.0 / menu_fade_exit_ms;
    try std.testing.expectApproxEqAbs(@as(f32, 0.096), exit.currentOpacity(), 0.01);
    exit.progress = 0;
    try std.testing.expectEqual(@as(f32, 0), exit.currentOpacity());
    try std.testing.expectEqual(@as(f32, 1.0), TransitionController.hiddenScaleForTransition(.menu_fade));
}

test "glass_popover: 过冲段打断退场位置连续，退场中途拉回也连续" {
    var enter = TransitionController.initWithTime(.glass_popover, .entering, 0);
    enter.progress = glass_popover_peak_ms / glass_popover_enter_ms; // Peak ~1.019.
    const v0 = enter.visualProgress();
    try std.testing.expect(v0 > 1.01);
    var exit = TransitionController.initWithTime(.glass_popover, .exiting, 0);
    exit.seedFromProgress(v0);
    try std.testing.expectApproxEqAbs(v0, exit.visualValue(), 1e-5);
    try std.testing.expectEqual(@as(f32, 1.0), exit.currentOpacity());
    // Exit still zeros at 249ms.
    exit.progress = 0;
    try std.testing.expectEqual(@as(f32, 0), exit.visualValue());
    // Exit just starting (>1) pulled back: enter's ascending segment same value.
    var exit2 = TransitionController.initWithTime(.glass_popover, .exiting, 0);
    exit2.seedFromProgress(v0);
    exit2.progress = 1.0 - 10.0 / glass_popover_exit_ms;
    const v1 = exit2.visualProgress();
    var back = TransitionController.initWithTime(.glass_popover, .entering, 0);
    back.seedFromProgress(v1);
    try std.testing.expectApproxEqAbs(v1, back.visualValue(), 0.002);
}
