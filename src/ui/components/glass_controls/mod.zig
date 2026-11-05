//! GlassSlider / GlassToggle: replicas of the macOS 26 native slider and toggle Liquid Glass.
//!
//! Native real-time measurement (scripts/glass_native_model/native_slider_toggle.swift:
//! real cursor + HID down/drag/release, per-frame screenshot):
//! - Idle: white solid capsule knob (light drop shadow); track 10% black (gray 128 reads 115),
//!   filled / enabled color (0,119,249).
//! - Pressed: white linearly fades to a clear glass lens, knob spring-scales (slider 20x16 ->
//!   25x20,
//!   toggle 32x20 -> 50x31), center fixed, glass state has no drop shadow; stays glass while held.
//! - Released: spring shrinks back, white linearly refills; toggle also spring-slides the knob to
//!   the new position (range 18), track color cross-fades.
//! - Dragging the toggle knob past center changes track color mid-hold while pressed.
//! Fit params are in slider_knob / toggle_knob (timing relative to the event, collection jitter
//! corrected).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Handler = core.Handler;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Model = reactive.Model;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
const glass_box = @import("../glass_box/mod.zig");

/// Track: 10% black (gray 128 reads 115, white reads 230). Blended in sRGB space
/// (docs/SRGB_BLENDING_PLAN.md), alpha is native reading directly converted; linear-light
/// era equiv 53 now darker after space switch.
pub const track_color = Color.rgba(0, 0, 0, 26);
/// Fill / enabled color (gray 128 measured (0,119,249)).
pub const accent_color = Color.rgba(0, 119, 249, 255);
/// Pressed: slider fill darkens this frame to 0.9x (0,107,225); toggle closed track
/// darkens from 10% to 19% black (114 -> 104) as knob scales, enabled track also
/// darkens to 0.9x.
pub const accent_pressed = Color.rgba(0, 107, 225, 255);
/// 19% black (gray 128 -> 104). Old 92 is linear-light equivalent; after blend-space
/// switch read 82. Toggle lens track darkens: internal 0.84*82+28.5=97 vs native 0.84*104+28.5=116.
pub const track_pressed = Color.rgba(0, 0, 0, 48);
/// Increased contrast (native_slider_toggle.swift -increaseContrast): track 83 (35% black),
/// fill / enabled (0,58,202), track with 1pt black outline outside fill.
pub const track_color_ic = Color.rgba(0, 0, 0, 90);
pub const accent_ic = Color.rgba(0, 58, 202, 255);
const a11y_preferences = @import("../../a11y/preferences.zig");

fn contrastOutline(node: *Node, on: bool, radius: f32) void {
    const want: f32 = if (on) 1 else 0;
    if (node.style.border.width == want) return;
    node.style.border = .{ .overlay = true, .width = want, .color = Color.rgba(0, 0, 0, 255), .radius = radius };
    node.markRenderDirty();
}

/// Idle knob drop shadow: faint, large, 3pt down. Fit from native_appkit_controls.swift idle frames
/// with Zenit's smoothstep(blur, -blur, sdf) decay (NSSwitch / SwiftUI Toggle / NSSlider /
/// SwiftUI Slider; one model fits, residual ~0.05): toggle alpha 0.065 * blur 22 * y 3
/// (RMS 0.28-0.38), slider 0.060 * 19 * 3 (0.34-0.50). Deeper/smaller values (38 / 4 / 1) miss
/// native's faint halo outside the track entirely.
pub const toggle_knob_shadow = core.Shadow{ .color = Color.rgba(0, 0, 0, 17), .blur = 22, .offset_x = 0, .offset_y = 3 };
pub const slider_knob_shadow = core.Shadow{ .color = Color.rgba(0, 0, 0, 15), .blur = 19, .offset_x = 0, .offset_y = 3 };

/// Knob two-state geometry and transition (native_slider_toggle.swift fit).
pub const KnobSpec = struct {
    rest: [2]f32,
    glass: [2]f32,
    /// Pressed: size spring (delay ms / response s / damping) and white linear fade
    /// (delay ms / duration ms).
    press_scale: [3]f32,
    press_white: [2]f32,
    /// Released: size spring and white linear refill.
    release_scale: [3]f32,
    release_white: [2]f32,
    /// Idle white knob drop shadow.
    shadow: core.Shadow,
    /// iOS: the held knob is the `_UILiquidLensView` magnifier (glass_box `.tab_lens` of this
    /// variant) rather than macOS's shrinking knob lens.
    lens: ?glass_box.LensVariant = null,
    /// iOS: the white face fades out / back in on springs {delay ms, response s, damping} (press,
    /// release) instead of the linear press_white / release_white ramps.
    white_spring: ?[2][3]f32 = null,
    /// macOS: the press eases in and out instead (smoothstep {delay ms, duration ms} of the
    /// size and of the white face's fade); release keeps the springs (white_spring[1])
    press_smooth: ?[2][2]f32 = null,
    /// The lens's key highlight colour matrix (glass_box lens_key_matrix): set by the tint
    lens_key_matrix: [12]f32 = @as([12]f32, @splat(0)),
    /// iOS: a press shows the lifted lens at least this long (ms from the press): a 50 ms tap's
    /// knob stays glass while it slides and lets go 0.24 s after the press (native switch taps:
    /// the white face starts back 0.19 s after a release that came 0.05 s after the press)
    min_lift_ms: f32 = 0,
};

/// Key highlight colour matrices (native vibrantColorMatrix of the held knob's first highlight
/// layer, rows {r, g, b, offset}): they follow the tint - systemBlue on the iOS slider and on macOS
/// (whose green row differs slightly), systemGreen on the iOS switch.
pub const key_matrix_blue_ios = [12]f32{ 2.0173, -1.2875, -0.1298, -0.6, -0.2496, 0.7256, -0.0848, -0.0435, -0.1914, -0.6436, 1.1350, 0.2 };
pub const key_matrix_green_ios = [12]f32{ 1.6756, -1.0695, -0.1078, -0.329, -0.2149, 0.6249, -0.0730, 0.1013, -0.2838, -0.9542, 1.6827, -0.186 };
pub const key_matrix_blue_mac = [12]f32{ 2.0173, -1.2875, -0.1298, -0.6, -0.2588, 0.7526, -0.0879, -0.0822, -0.1914, -0.6436, 1.1350, 0.2 };

/// Slider knob: pressed size spring(0.150, 0.99) delays 48ms; white delays 15ms,
/// fades 90ms; released spring(0.134, 0.99), white delays 15ms, refills 160ms. White
/// per native_appkit_controls.swift (NSSlider + SwiftUI Slider, light tap 4x, HID zero),
/// joint refit RMS 0.050: native min white is 0.49-0.58, so the fade must bottom out near 0.40
/// rather than 0.24.
pub const slider_knob = KnobSpec{
    .rest = .{ 20, 16 },
    .glass = .{ 25, 20 },
    .press_scale = .{ 48, 0.150, 0.99 },
    .press_white = .{ 15, 90 },
    .release_scale = .{ 0, 0.134, 0.99 },
    .release_white = .{ 15, 160 },
    .shadow = slider_knob_shadow,
    .lens = .mac_knob,
    .lens_key_matrix = key_matrix_blue_mac,
};

/// Toggle knob (NSSwitch, macOS 26.4; native_controls_probe `anim-switch`: the knob's layer model
/// values every ~5 ms, time zero at the posted event - AppKit hosts the knob in SwiftUI, which
/// writes the frames itself, no CAAnimation). Joint fit over two taps and two holds, each with its
/// own event latency (they scatter by +-20 ms; scripts/glass_native_model/compare_toggle_dynamics.py):
/// press - the size eases in and out, smoothstep from 44 ms over 186 ms, the white face smoothstep
/// from 32 ms over 153 ms; release - the press curves run on until the release takes effect, then
/// the size springs back (0.528, 0.629) 31 ms after it from rest (rms 0.3-0.5 pt) and the white
/// face (0.48, 0.59) 20 ms after it. A 70 ms tap only reaches ~35 x 22 and white ~0.7.
pub const toggle_knob = KnobSpec{
    .rest = .{ 32, 20 },
    .glass = .{ 50, 31 },
    .press_scale = .{ 44, 0.186, 1 },
    .press_white = .{ 32, 153 },
    .release_scale = .{ 31, 0.528, 0.629 },
    .release_white = .{ 20, 155 },
    .shadow = toggle_knob_shadow,
    .lens = .mac_knob,
    .white_spring = .{ .{ 32, 0.153, 1 }, .{ 20, 0.48, 0.59 } },
    .press_smooth = .{ .{ 44, 186 }, .{ 32, 153 } },
    .lens_key_matrix = key_matrix_blue_mac,
};

/// Toggle knob slide: spring(0.465, 0.709) 30 ms after the release (four recordings: 0.43-0.50 /
/// 0.68-0.74; the knob ends 0.7 pt past its rest and SwiftUI then snaps it there at ~0.55 s, which
/// is not reproduced). Track colour: smoothstep 25 ms after the release over 259 ms (rms 0.013).
pub const toggle_travel_delay_ms: f32 = 30;
pub const toggle_travel_spring: [2]f32 = .{ 0.465, 0.709 };
pub const toggle_track_fade: [2]f32 = .{ 25, 259 };

/// iOS 26.5 Simulator UISlider thumb / UISwitch knob (ios GlassProbe `switches` scene, per-frame
/// presentation frames and filter inputs): a 37 x 24 white capsule that, held, becomes the
/// `_UILiquidLensView` magnifier. Press: size spring(0.19, 0.59) to 57.3 x 37.2 (switch 58 x 38.3,
/// peaking 59.3 at 0.15 s); the white face (and with it every lens input) on spring(0.22, 0.56),
/// gone by 0.085 s. Release: size spring(0.46, 0.69), dipping to 36.0 at 0.33 s; the white face
/// back on spring(0.49, 0.69), full at 0.26 s.
pub const slider_knob_ios = KnobSpec{
    .rest = .{ 37, 24 },
    .glass = .{ 57.3, 37.2 },
    .press_scale = .{ 16, 0.19, 0.59 },
    .press_white = .{ 0, 1 },
    .release_scale = .{ 0, 0.46, 0.69 },
    .release_white = .{ 0, 1 },
    .shadow = slider_knob_shadow,
    .lens = .slider_thumb,
    .white_spring = .{ .{ 16, 0.22, 0.56 }, .{ 0, 0.49, 0.69 } },
    .lens_key_matrix = key_matrix_blue_ios,
    .min_lift_ms = 240,
};
pub const toggle_knob_ios = KnobSpec{
    .rest = .{ 37, 24 },
    .glass = .{ 58, 38.3 },
    .press_scale = .{ 16, 0.19, 0.59 },
    .press_white = .{ 0, 1 },
    .release_scale = .{ 0, 0.46, 0.69 },
    .release_white = .{ 0, 1 },
    .shadow = toggle_knob_shadow,
    .lens = .switch_knob,
    .white_spring = .{ .{ 16, 0.22, 0.56 }, .{ 0, 0.49, 0.69 } },
    .lens_key_matrix = key_matrix_green_ios,
    .min_lift_ms = 240,
};

/// Per-platform geometry and colours of the two controls.
pub const ControlLook = struct {
    slider_height: f32,
    slider_track_h: f32,
    slider_knob: KnobSpec,
    slider_accent: Color,
    /// Fill while the knob is held
    slider_accent_pressed: Color,
    toggle_size: [2]f32,
    toggle_inset: f32,
    toggle_knob: KnobSpec,
    toggle_on: Color,
    toggle_on_pressed: Color,
    toggle_off: Color,
    toggle_off_pressed: Color,
    track: Color,
    /// Knob slide after release: delay (ms), spring response (s), damping
    toggle_travel: [3]f32,
    /// iOS: the on colour sweeps in as native's sliding strip (see TrackStrip) on springs
    /// {response, damping} toward on / toward off; null = the macOS linear cross-fade
    toggle_strip: ?[2][2]f32 = null,
};

/// iOS UISwitch track colour: a strip image 10 track-widths long slides under the track window -
/// the on colour, opaque for one width, its alpha falling linearly over the next eight, clear for
/// the last (read from the native image: 630 x 31 over a 63 pt track) - from x = -9 w (off) to 0
/// (on). Mid-transition the on colour has swept in from the left as a long gradient, not faded
/// in as a whole. `p` = strip progress (0 off, 1 on); returns the track window's alpha stops.
pub const TrackStrip = struct {
    pub fn alphaAt(u_over_w: f32) f32 {
        if (u_over_w <= 1) return 1;
        if (u_over_w >= 9) return 0;
        return (9 - u_over_w) / 8;
    }

    /// Stops across the track (positions 0..1): its ends and the strip's kinks inside it.
    pub fn stops(p: f32, out: *[4][2]f32) usize {
        const off = 9 * (1 - std.math.clamp(p, 0, 1)); // u / w at the track's left end
        var n: usize = 0;
        out[n] = .{ 0, alphaAt(off) };
        n += 1;
        for ([_]f32{ 1 - off, 9 - off }) |k| {
            if (k > 0.001 and k < 0.999) {
                out[n] = .{ k, alphaAt(off + k) };
                n += 1;
            }
        }
        out[n] = .{ 1, alphaAt(off + 1) };
        n += 1;
        if (n == 4 and out[1][0] > out[2][0]) {
            const t = out[1];
            out[1] = out[2];
            out[2] = t;
        }
        return n;
    }
};

pub const look_macos = ControlLook{
    .slider_height = 20,
    .slider_track_h = 6,
    .slider_knob = slider_knob,
    .slider_accent = accent_color,
    .slider_accent_pressed = accent_pressed,
    .toggle_size = .{ 54, 24 },
    .toggle_inset = 2,
    .toggle_knob = toggle_knob,
    .toggle_on = accent_color,
    .toggle_on_pressed = accent_pressed,
    .toggle_off = track_color,
    .toggle_off_pressed = track_pressed,
    .track = track_color,
    .toggle_travel = .{ toggle_travel_delay_ms, toggle_travel_spring[0], toggle_travel_spring[1] },
};

/// iOS: slider 6 pt track (10 % black, gray 128 reads 115) with a (0,136,255) fill under a 34 pt
/// tall control; switch 63 x 28, on (52,199,89), off reads (108,108,110) over gray 128, knob
/// inset 2. Holding changes neither colour.
pub const look_ios = ControlLook{
    .slider_height = 34,
    .slider_track_h = 6,
    .slider_knob = slider_knob_ios,
    .slider_accent = Color.rgba(0, 136, 255, 255),
    .slider_accent_pressed = Color.rgba(0, 136, 255, 255),
    .toggle_size = .{ 63, 28 },
    .toggle_inset = 2,
    .toggle_knob = toggle_knob_ios,
    .toggle_on = Color.rgba(52, 199, 89, 255),
    .toggle_on_pressed = Color.rgba(52, 199, 89, 255),
    .toggle_off = Color.rgba(0, 0, 13, 40),
    .toggle_off_pressed = Color.rgba(0, 0, 13, 40),
    .track = track_color,
    // native tap (ios GlassProbe switch_taps, per-frame frames of the lens and the strip): every
    // curve a critically damped spring from the release - the knob 15 ms after it, response 0.31
    // (both ways); the strip at once, response 0.68 toward on, 0.40 toward off
    .toggle_travel = .{ 15, 0.31, 0.999 },
    .toggle_strip = .{ .{ 0.68, 0.999 }, .{ 0.40, 0.999 } },
};

pub fn lookFor(idiom: glass_box.GlassIdiom) *const ControlLook {
    return switch (idiom) {
        .macos => &look_macos,
        .ios => &look_ios,
    };
}

/// Calibration: ZENIT_TAB_LENS_HIDE=1 leaves the knobs' lenses out (rendering the native lens layer
/// tree over the backdrop instead: scripts/glass_native_model/ca_render.swift).
fn debugLensHidden() bool {
    var buf: [16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const raw = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_TAB_LENS_HIDE") catch return false;
    return std.mem.eql(u8, raw, "1");
}

/// SwiftUI spring(response, dampingFraction) 0->1 step response (damping < 1).
fn springStep(t_s: f32, response: f32, damping: f32) f32 {
    if (t_s <= 0) return 0;
    const z = std.math.clamp(damping, 0.05, 0.999);
    const w = 2.0 * std.math.pi / response;
    const wd = w * @sqrt(1.0 - z * z);
    return 1.0 - @exp(-z * w * t_s) * (@cos(wd * t_s) + z * w / wd * @sin(wd * t_s));
}

/// Scalar starting from `from`, spring toward `to` after `delay` (position continuous:
/// interrupting takes current as new start). During the delay the previous curve keeps going
/// (native: a knob released mid-press goes on growing until the release takes effect), and the
/// new one starts from where it is then. `smooth`: a timed smoothstep over `response` seconds
/// instead of a spring (native macOS press: AppKit's switch knob eases in and out).
const SpringTrack = struct {
    from: f32 = 0,
    to: f32 = 0,
    start_ms: f64 = 0,
    delay_ms: f32 = 0,
    response: f32 = 0.2,
    damping: f32 = 0.9,
    smooth: bool = false,
    /// The curve it replaced, shown until the delay is over
    prev: Curve = .{},

    const Curve = struct {
        from: f32 = 0,
        to: f32 = 0,
        start_ms: f64 = 0,
        delay_ms: f32 = 0,
        response: f32 = 0.2,
        damping: f32 = 0.9,
        smooth: bool = false,

        fn value(c: Curve, now_ms: f64) f32 {
            const t: f32 = @as(f32, @floatCast(now_ms - c.start_ms)) - c.delay_ms;
            if (c.smooth) {
                const u = std.math.clamp(t / 1000.0 / @max(c.response, 1e-3), 0, 1);
                return c.from + (c.to - c.from) * u * u * (3 - 2 * u);
            }
            return c.to + (c.from - c.to) * (1.0 - springStep(t / 1000.0, c.response, c.damping));
        }
    };

    fn curve(self: SpringTrack) Curve {
        return .{ .from = self.from, .to = self.to, .start_ms = self.start_ms, .delay_ms = self.delay_ms, .response = self.response, .damping = self.damping, .smooth = self.smooth };
    }

    fn value(self: SpringTrack, now_ms: f64) f32 {
        if (now_ms - self.start_ms < self.delay_ms) return self.prev.value(now_ms);
        return self.curve().value(now_ms);
    }

    fn done(self: SpringTrack, now_ms: f64) bool {
        const t: f32 = @as(f32, @floatCast(now_ms - self.start_ms)) - self.delay_ms;
        if (self.smooth) return t / 1000.0 >= self.response;
        return t > 0 and @abs(self.value(now_ms) - self.to) < 0.002 and t / 1000.0 > self.response;
    }

    fn retarget(self: *SpringTrack, now_ms: f64, to: f32, delay_ms: f32, response: f32, damping: f32) void {
        self.retargetCurve(now_ms, to, delay_ms, response, damping, false);
    }

    fn retargetSmooth(self: *SpringTrack, now_ms: f64, to: f32, delay_ms: f32, dur_ms: f32) void {
        self.retargetCurve(now_ms, to, delay_ms, dur_ms / 1000.0, 1, true);
    }

    fn retargetCurve(self: *SpringTrack, now_ms: f64, to: f32, delay_ms: f32, response: f32, damping: f32, smooth: bool) void {
        // the running curve carries on through the delay; the new one starts where it is then
        const prev = if (now_ms - self.start_ms < self.delay_ms) self.prev else self.curve();
        const from = prev.value(now_ms + delay_ms);
        self.* = .{ .from = from, .to = to, .start_ms = now_ms, .delay_ms = delay_ms, .response = response, .damping = damping, .smooth = smooth, .prev = prev };
    }
};

/// Linear transition (white fill, track color).
const LinearTrack = struct {
    from: f32 = 1,
    to: f32 = 1,
    start_ms: f64 = 0,
    delay_ms: f32 = 0,
    dur_ms: f32 = 1,
    /// smoothstep instead of a straight ramp
    smooth: bool = false,

    fn value(self: LinearTrack, now_ms: f64) f32 {
        const t: f32 = @as(f32, @floatCast(now_ms - self.start_ms)) - self.delay_ms;
        const u = std.math.clamp(t / @max(self.dur_ms, 1), 0, 1);
        return self.from + (self.to - self.from) * (if (self.smooth) u * u * (3 - 2 * u) else u);
    }

    fn done(self: LinearTrack, now_ms: f64) bool {
        return @as(f32, @floatCast(now_ms - self.start_ms)) >= self.delay_ms + self.dur_ms;
    }

    fn retarget(self: *LinearTrack, now_ms: f64, to: f32, delay_ms: f32, dur_ms: f32) void {
        const cur = self.value(now_ms);
        // Duration scales proportionally to remaining distance, interrupt preserves speed.
        const frac = if (self.to != self.from or cur != to) @abs(to - cur) else 0;
        self.* = .{ .from = cur, .to = to, .start_ms = now_ms, .delay_ms = delay_ms, .dur_ms = @max(dur_ms * @min(frac, 1), 1), .smooth = self.smooth };
    }
};

/// Knob: clear glass (absolute positioning, dimensions per-frame) + white capsule overlay (opacity
/// per-frame, static shadow).
pub const GlassKnob = struct {
    spec: KnobSpec,
    glass: glass_box.GlassBoxMount,
    white: *Node,
    /// 0 = idle size, 1 = glass size
    size: SpringTrack = .{},
    /// White fill opacity (1 = idle, 0 = glass)
    whiteness: LinearTrack = .{},
    /// The same on a spring (spec.white_spring, iOS)
    white_spring: SpringTrack = .{ .from = 1, .to = 1 },
    pressed: bool = false,
    /// Press time and, for a release that came before min_lift_ms, when it takes effect
    press_ms: f64 = 0,
    release_due: ?f64 = null,
    /// Last placed geometry {x, y, w, h} and brightness: no node rewrite or mark dirty when
    /// unchanged (zero cost at idle, frame gating enabled).
    last: [5]f32 = .{ std.math.nan(f32), 0, 0, 0, 0 },

    fn mount(scope: *Scope, cx: *Cx, parent: *Node, spec: KnobSpec) !GlassKnob {
        const a = cx.allocator;
        const g = try glass_box.GlassBox(.{
            .width = spec.rest[0],
            .height = spec.rest[1],
            .shape = .capsule,
            .glass_style = .clear,
            .material = if (spec.lens != null) glass_box.GlassMaterial.tab_lens else glass_box.GlassMaterial.knob_lens,
            .lens_variant = spec.lens orelse .tab,
            .lens_key_matrix = spec.lens_key_matrix,
            .drop_shadow = spec.lens != null,
            .padding = core.Padding.all(0),
            .body_gap = 0,
        }).mountWithState(scope, cx);
        _ = try core.adoptChild(cx, a, parent, g.box);
        // The iOS lens only exists while held (its level follows the white face). The control's
        // track under it is part of its backdrop: the lens formula maps it like native's portal.
        if (spec.lens != null) glass_box.glassSetMaterializeLevel(g.state, 0);
        g.box.style.position = .absolute;
        const white = try core.adoptChild(cx, a, parent, try box(cx, .{
            .width = .{ .px = spec.rest[0] },
            .height = .{ .px = spec.rest[1] },
            .position = .absolute,
            .background = Color.WHITE,
        }, .{}));
        const ext = try white.style.ensureExtFallible(a);
        ext.corner_radius = core.CornerRadius.uniform(spec.rest[1] / 2);
        ext.setShadow(spec.shadow);
        white.style.border = .{ .overlay = true, .width = 0, .color = Color.rgba(0, 0, 0, 0), .radius = spec.rest[1] / 2 };
        return .{ .spec = spec, .glass = g, .white = white };
    }

    fn setPressed(self: *GlassKnob, now_ms: f64, pressed: bool) void {
        if (self.pressed == pressed) return;
        self.pressed = pressed;
        const s = self.spec;
        if (pressed) {
            self.press_ms = now_ms;
            self.release_due = null;
        } else if (s.min_lift_ms > 0 and now_ms - self.press_ms < s.min_lift_ms) {
            // hold the lifted lens until the minimum lift is over (applyRelease in place())
            self.release_due = self.press_ms + s.min_lift_ms;
            return;
        }
        self.applyPress(now_ms, pressed);
    }

    fn applyPress(self: *GlassKnob, now_ms: f64, pressed: bool) void {
        const s = self.spec;
        if (pressed) {
            if (s.press_smooth) |ps| {
                self.size.retargetSmooth(now_ms, 1, ps[0][0], ps[0][1]);
                // whiteAt reads white_spring only when the spec has one: the linear track otherwise
                if (s.white_spring != null) self.white_spring.retargetSmooth(now_ms, 0, ps[1][0], ps[1][1]) else self.whiteness.retarget(now_ms, 0, ps[1][0], ps[1][1]);
                return;
            }
            self.size.retarget(now_ms, 1, s.press_scale[0], s.press_scale[1], s.press_scale[2]);
            self.whiteness.retarget(now_ms, 0, s.press_white[0], s.press_white[1]);
            if (s.white_spring) |ws| self.white_spring.retarget(now_ms, 0, ws[0][0], ws[0][1], ws[0][2]);
        } else {
            self.size.retarget(now_ms, 0, s.release_scale[0], s.release_scale[1], s.release_scale[2]);
            self.whiteness.retarget(now_ms, 1, s.release_white[0], s.release_white[1]);
            if (s.white_spring) |ws| self.white_spring.retarget(now_ms, 1, ws[1][0], ws[1][1], ws[1][2]);
        }
    }

    /// White face opacity now (1 = idle white knob, 0 = all glass)
    fn whiteAt(self: *const GlassKnob, now_ms: f64) f32 {
        const v = if (self.spec.white_spring != null) self.white_spring.value(now_ms) else self.whiteness.value(now_ms);
        return std.math.clamp(v, 0, 1);
    }

    fn animating(self: *const GlassKnob, now_ms: f64) bool {
        if (self.release_due != null) return true;
        const white_done = if (self.spec.white_spring != null) self.white_spring.done(now_ms) else self.whiteness.done(now_ms);
        return !self.size.done(now_ms) or !white_done;
    }

    /// Place current frame's knob centered at (cx, cy) in parent-local coordinates.
    fn place(self: *GlassKnob, now_ms: f64, center: [2]f32) void {
        if (self.release_due) |due| if (now_ms >= due) {
            self.release_due = null;
            if (!self.pressed) self.applyPress(due, false);
        };
        const k = self.size.value(now_ms);
        const w = self.spec.rest[0] + (self.spec.glass[0] - self.spec.rest[0]) * k;
        const h = self.spec.rest[1] + (self.spec.glass[1] - self.spec.rest[1]) * k;
        const white_a = self.whiteAt(now_ms);
        const next = [5]f32{ center[0] - w / 2, center[1] - h / 2, w, h, white_a };
        var same = true;
        for (next, self.last) |a, b| {
            if (!(@abs(a - b) < 1e-3)) same = false;
        }
        if (same) return;
        self.last = next;
        glass_box.glassPlace(self.glass.state, .{ next[0], next[1], w, h });
        // ZENIT_TAB_LENS_HIDE=1 (calibration): the knob's lens left out, its backdrop alone
        const hidden = debugLensHidden();
        glass_box.glassSetShadowScale(self.glass.state, if (hidden) 0 else 1 - white_a);
        // iOS: every lens input rides the same spring as the white face (native per-frame filter
        // inputs: displacement, inner refraction and aberration all track 1 - white)
        if (self.spec.lens != null) glass_box.glassSetMaterializeLevel(self.glass.state, if (hidden) 0 else 1 - white_a);
        const node = self.white;
        node.style.width = .{ .px = w };
        node.style.height = .{ .px = h };
        node.style.border.radius = h / 2;
        if (node.style.ensureExtFallible(node_allocator(self))) |ext| {
            ext.inset = .{ .left = .{ .px = center[0] - w / 2 }, .top = .{ .px = center[1] - h / 2 } };
            ext.corner_radius = core.CornerRadius.uniform(h / 2);
        } else |_| {}
        node.setOpacity(white_a);
        node.markSizingDirty();
        node.markLayoutDirty();
        node.markRenderDirty();
    }

    fn node_allocator(self: *GlassKnob) Allocator {
        return self.glass.state.allocator;
    }
};

// ───────────────────────────── GlassSlider ─────────────────────────────

pub const GlassSliderProps = struct {
    min: f32 = 0,
    max: f32 = 1,
    /// Snaps to step when > 0
    step: f32 = 0,
    value: Model(f32) = .{ .local = 0.5 },
    width: f32 = 240,
    on_change: ?Handler(f32) = null,
    test_id: ?[]const u8 = null,
    /// Platform look (macOS / iOS); null = `Cx.glass_idiom`.
    idiom: ?glass_box.GlassIdiom = null,
};

pub const GlassSliderRuntime = struct {
    cx: *Cx,
    value: reactive.Bound(f32),
    min: f32,
    max: f32,
    step: f32,
    width: f32,
    on_change: ?Handler(f32),
    look: *const ControlLook,
    container: *Node,
    track: *Node,
    fill: *Node,
    knob: GlassKnob,
    dragging: bool = false,
    /// When pressed on knob, cursor offset relative to knob center (drag maintains relative
    /// position).
    grab_dx: f32 = 0,

    fn ratio(self: *const GlassSliderRuntime) f32 {
        if (self.max <= self.min) return 0;
        const v = self.value.readAs(false);
        if (std.math.isNan(v)) return 0;
        return std.math.clamp((v - self.min) / (self.max - self.min), 0, 1);
    }

    /// Knob center (container-local x): reserves idle half-width at each end.
    fn knobX(self: *const GlassSliderRuntime, r: f32) f32 {
        const half = self.knob.spec.rest[0] / 2;
        return half + r * (self.width - 2 * half);
    }

    fn ratioAtLocalX(self: *const GlassSliderRuntime, x: f32) f32 {
        const half = self.knob.spec.rest[0] / 2;
        return std.math.clamp((x - half) / @max(self.width - 2 * half, 1), 0, 1);
    }

    fn propose(self: *GlassSliderRuntime, r: f32) void {
        var v = self.min + r * (self.max - self.min);
        if (self.step > 0) v = self.min + @round((v - self.min) / self.step) * self.step;
        v = std.math.clamp(v, self.min, self.max);
        // Landing syncs effects, which may destroy this control: extract handler first; after
        // commit, do not read self.
        const on_change = self.on_change;
        const landed = self.value.commit(v) orelse return;
        if (on_change) |h| h.call(landed);
    }

    fn layoutNow(self: *GlassSliderRuntime) void {
        const now = self.cx.frame_time_ms;
        const kx = self.knobX(self.ratio());
        if (self.fill.style.width != .px or @abs(self.fill.style.width.px - kx) > 1e-3) {
            self.fill.style.width = .{ .px = kx };
            self.fill.markSizingDirty();
        }
        const ic = a11y_preferences.increaseContrast();
        const lk = self.look;
        self.fill.setBackground(if (ic) accent_ic else if (self.knob.pressed) lk.slider_accent_pressed else lk.slider_accent);
        self.track.setBackground(if (ic) track_color_ic else lk.track);
        contrastOutline(self.track, ic, lk.slider_track_h / 2);
        contrastOutline(self.fill, ic, lk.slider_track_h / 2);
        self.knob.place(now, .{ kx, lk.slider_height / 2 });
        if (self.knob.animating(now)) self.cx.needs_redraw = true;
    }

    fn localX(self: *GlassSliderRuntime, screen_x: f32) f32 {
        return screen_x - self.container.globalRect().x;
    }
};

pub fn GlassSlider(props: anytype) GlassSliderBuilder {
    return .{ .props = reactive.props.coerce(GlassSliderProps, props) };
}

pub const GlassSliderResult = struct {
    wrapper: *Node,
    value: ?*Signal(f32),
    runtime: *GlassSliderRuntime,
};

pub const GlassSliderBuilder = struct {
    props: GlassSliderProps,

    pub fn mount(self: GlassSliderBuilder, scope: *Scope, cx: *Cx) !GlassSliderResult {
        const p = self.props;
        const my_scope = try scope.childScope();
        var bound = false;
        errdefer if (!bound) my_scope.dispose();
        const a = cx.allocator;
        const value = try reactive.resolveModel(f32, my_scope, p.value);
        const lk = lookFor(p.idiom orelse cx.glass_idiom);
        const track_h = lk.slider_track_h;

        const container = try box(cx, .{
            .width = .{ .px = p.width },
            .height = .{ .px = lk.slider_height },
            .position = .relative,
        }, .{});
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "GlassSlider";
        if (p.test_id) |tid| container.meta.ownership.meta.test_id = tid;
        container.behavior.interaction.a11y = .{ .role = .slider, .value_min = p.min, .value_max = p.max, .orientation = .horizontal };
        try core.bindScopeToNode(my_scope, container);
        bound = true;

        const ty = (lk.slider_height - track_h) / 2;
        const track = try core.adoptChild(cx, a, container, try box(cx, .{
            .width = .{ .px = p.width },
            .height = .{ .px = track_h },
            .position = .absolute,
            .background = lk.track,
        }, .{}));
        (try track.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = ty } };
        track.style.border = .{ .overlay = true, .width = 0, .color = Color.rgba(0, 0, 0, 0), .radius = track_h / 2 };
        (try track.style.ensureExtFallible(a)).corner_radius = core.CornerRadius.uniform(track_h / 2);
        const fill = try core.adoptChild(cx, a, container, try box(cx, .{
            .width = .{ .px = 0 },
            .height = .{ .px = track_h },
            .position = .absolute,
            .background = lk.slider_accent,
        }, .{}));
        (try fill.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = ty } };
        fill.style.border = .{ .overlay = true, .width = 0, .color = Color.rgba(0, 0, 0, 0), .radius = track_h / 2 };
        (try fill.style.ensureExtFallible(a)).corner_radius = core.CornerRadius.uniform(track_h / 2);

        const knob = try GlassKnob.mount(my_scope, cx, container, lk.slider_knob);
        if (p.test_id) |tid| {
            // anchor for the instruments (the knob's frame); the node owns it
            knob.white.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "{s}.knob", .{tid});
            knob.white.frame_state.state_bits.flags.test_id_owned = true;
        }

        const rt = try my_scope.allocator.create(GlassSliderRuntime);
        rt.* = .{
            .cx = cx,
            .value = value,
            .min = @min(p.min, p.max),
            .max = @max(p.min, p.max),
            .step = p.step,
            .width = p.width,
            .on_change = p.on_change,
            .look = lk,
            .container = container,
            .track = track,
            .fill = fill,
            .knob = knob,
        };
        rt.knob.size = .{ .start_ms = cx.frame_time_ms };
        rt.knob.whiteness = .{ .start_ms = cx.frame_time_ms };
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*GlassSliderRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        if (container.behavior.interaction.a11y) |*a11y| a11y.value_range = .{ .now = 0, .min = rt.min, .max = rt.max, .context = rt, .set_value = sliderA11ySet };

        container.style.cursor = .pointer;
        (try container.style.ensureExtFallible(a)).hit_roles = .{ .pointer = true };
        container.behavior.events.event_context = @ptrCast(rt);
        container.behavior.events.on_event = sliderEvent;
        container.on_capture_lost = sliderCaptureLost;
        container.setFocusable(true);
        container.behavior.events.on_key_down = sliderKey;
        container.behavior.events.key_context = @ptrCast(rt);
        container.meta.per_frame.hooks.before_render.main = sliderBeforeRender;
        rt.layoutNow();
        try my_scope.createEffect(rt, struct {
            fn run(r: *GlassSliderRuntime) void {
                _ = r.value.readAs(true);
                if (r.container.behavior.interaction.a11y) |*a11y| {
                    a11y.value_now = r.value.readAs(false);
                    if (a11y.value_range) |*range| range.now = r.value.readAs(false);
                }
                r.container.markRenderDirty();
                r.cx.needs_redraw = true;
            }
        }.run);
        return .{ .wrapper = container, .value = value.asSignal(), .runtime = rt };
    }
};

fn sliderA11ySet(context: *anyopaque, v: f32) bool {
    const rt: *GlassSliderRuntime = @ptrCast(@alignCast(context));
    if (rt.max <= rt.min) return false;
    rt.propose((v - rt.min) / (rt.max - rt.min));
    return true;
}

fn sliderBeforeRender(node: *Node) void {
    const rt: *GlassSliderRuntime = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    rt.layoutNow();
}

fn sliderCaptureLost(node: *Node) void {
    const rt: *GlassSliderRuntime = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    rt.dragging = false;
    rt.knob.setPressed(rt.cx.frame_time_ms, false);
    rt.cx.needs_redraw = true;
}

fn sliderEvent(event: Event, context: ?*anyopaque) EventResult {
    const rt: *GlassSliderRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .mouse_down => |e| {
            const lx = rt.localX(e.x);
            const kx = rt.knobX(rt.ratio());
            const on_knob = @abs(lx - kx) <= rt.knob.spec.rest[0] / 2;
            // Pressed on knob: drag maintaining relative position; pressed on track: knob jumps to
            // cursor.
            rt.grab_dx = if (on_knob) lx - kx else 0;
            // Capture change calls previous owner, which may destroy this control or transfer
            // capture: verify via handle afterwards.
            const cx = rt.cx;
            const identity = cx.node_registry.handleFor(rt.container);
            cx.setPointerCapture(rt.container);
            const live = cx.node_registry.resolve(identity, null) orelse return .stop;
            if (live.behavior.events.event_context != context or live.behavior.events.on_event != sliderEvent) return .stop;
            if (!ownsCapture(cx, rt.container)) return .stop;
            rt.dragging = true;
            rt.knob.setPressed(cx.frame_time_ms, true);
            cx.needs_redraw = true;
            // propose may destroy this control via on_change: must be the last step.
            if (!on_knob) rt.propose(rt.ratioAtLocalX(lx));
            return .stop;
        },
        .mouse_move => |e| {
            if (rt.dragging and !ownsCapture(rt.cx, rt.container)) rt.dragging = false;
            if (!rt.dragging) return .ignored;
            rt.propose(rt.ratioAtLocalX(rt.localX(e.x) - rt.grab_dx));
            return .stop;
        },
        .mouse_up => {
            if (!rt.dragging) return .ignored;
            rt.dragging = false;
            if (ownsCapture(rt.cx, rt.container)) rt.cx.releasePointerCapture();
            rt.knob.setPressed(rt.cx.frame_time_ms, false);
            rt.cx.needs_redraw = true;
            return .stop;
        },
        else => return .ignored,
    }
}

fn ownsCapture(cx: *Cx, node: *Node) bool {
    return cx.node_registry.resolve(cx.dispatcher.pointer_capture_handle, null) == node;
}

fn sliderKey(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const rt: *GlassSliderRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    const step_r: f32 = if (rt.step > 0 and rt.max > rt.min) rt.step / (rt.max - rt.min) else 0.01;
    switch (key) {
        .right => rt.propose(rt.ratio() + step_r),
        .left => rt.propose(rt.ratio() - step_r),
        .home => rt.propose(0),
        .end => rt.propose(1),
        else => return .ignored,
    }
    return .stop;
}

// ───────────────────────────── GlassToggle ─────────────────────────────

pub const GlassToggleProps = struct {
    on: Model(bool) = .{ .local = false },
    on_change: ?Handler(bool) = null,
    test_id: ?[]const u8 = null,
    /// Platform look (macOS / iOS); null = `Cx.glass_idiom`.
    idiom: ?glass_box.GlassIdiom = null,
};

pub const GlassToggleRuntime = struct {
    cx: *Cx,
    on: reactive.Bound(bool),
    on_change: ?Handler(bool),
    look: *const ControlLook,
    container: *Node,
    track: *Node,
    knob: GlassKnob,
    /// Knob center x: 0 = off, 1 = on (follows hand during drag).
    travel: SpringTrack = .{},
    /// Track color: 0 = off color, 1 = on color (macOS: smoothstep, toggle_track_fade)
    tint: LinearTrack = .{ .from = 0, .to = 0 },
    /// iOS: strip progress (TrackStrip) and the on-colour layer over the track it paints
    strip: SpringTrack = .{},
    strip_layer: ?*Node = null,
    strip_last: f32 = std.math.nan(f32),
    pressed: bool = false,
    dragged: bool = false,
    press_x: f32 = 0,
    press_travel: f32 = 0,
    shown_on: bool = false,

    fn knobCenter(self: *const GlassToggleRuntime, t: f32) [2]f32 {
        const lk = self.look;
        const half = self.knob.spec.rest[0] / 2;
        const x0 = lk.toggle_inset + half;
        const x1 = lk.toggle_size[0] - lk.toggle_inset - half;
        return .{ x0 + (x1 - x0) * t, lk.toggle_size[1] / 2 };
    }

    fn travelSpan(self: *const GlassToggleRuntime) f32 {
        return self.look.toggle_size[0] - 2 * self.look.toggle_inset - self.knob.spec.rest[0];
    }

    /// Display state change (click, drag past midpoint, external write): track color cross-fade.
    fn showState(self: *GlassToggleRuntime, now: f64, on: bool) void {
        if (self.shown_on == on) return;
        self.shown_on = on;
        if (self.look.toggle_strip) |sp| {
            const k = sp[if (on) 0 else 1];
            self.strip.retarget(now, if (on) 1 else 0, 0, k[0], k[1]);
        } else self.tint.retarget(now, if (on) 1 else 0, toggle_track_fade[0], toggle_track_fade[1]);
    }

    fn settle(self: *GlassToggleRuntime, now: f64, on: bool) void {
        const tr = self.look.toggle_travel;
        self.travel.retarget(now, if (on) 1 else 0, tr[0], tr[1], tr[2]);
        self.showState(now, on);
    }

    fn colourDone(self: *const GlassToggleRuntime, now: f64) bool {
        return if (self.look.toggle_strip != null) self.strip.done(now) else self.tint.done(now);
    }

    /// Paint the strip window over the track (only when its progress changed: idle stays idle).
    fn paintStrip(self: *GlassToggleRuntime, now: f64, on_c: Color) void {
        const layer = self.strip_layer orelse return;
        const p = std.math.clamp(self.strip.value(now), 0, 1);
        if (@abs(p - self.strip_last) < 1e-4) return;
        self.strip_last = p;
        var st: [4][2]f32 = undefined;
        const n = TrackStrip.stops(p, &st);
        var gs: [4]core.GradientStop = undefined;
        for (st[0..n], 0..) |s2, i| gs[i] = .{ .color = on_c.withAlpha(@intFromFloat(@round(std.math.clamp(s2[1], 0, 1) * @as(f32, @floatFromInt(on_c.a))))), .position = s2[0] };
        if (layer.style.ensureExtFallible(self.cx.allocator)) |ext| {
            ext.multi_gradient = core.MultiGradient.fromSlice(gs[0..n], .horizontal);
        } else |_| {}
        layer.markRenderDirty();
    }

    /// Must be caller's last step: commit's effect / on_change may destroy this control. When
    /// parent rejects, display animates toward target first; next frame layoutNow finds mismatch
    /// and bounces back (one visible bounce).
    fn commit(self: *GlassToggleRuntime, on: bool) void {
        const on_change = self.on_change;
        const landed = self.on.commit(on) orelse return;
        if (on_change) |h| h.call(landed);
    }

    fn layoutNow(self: *GlassToggleRuntime) void {
        const now = self.cx.frame_time_ms;
        // External write (non-interactive): animate to new state.
        const want = self.on.readAs(false);
        if (!self.pressed and want != self.shown_on) self.settle(now, want);
        const t = std.math.clamp(self.tint.value(now), 0, 1);
        const press = std.math.clamp(self.knob.size.value(now), 0, 1);
        const ic = a11y_preferences.increaseContrast();
        const lk = self.look;
        const off = if (ic) track_color_ic else lerpColor(lk.toggle_off, lk.toggle_off_pressed, press);
        const on_c = if (ic) accent_ic else lerpColor(lk.toggle_on, lk.toggle_on_pressed, press);
        contrastOutline(self.track, ic, lk.toggle_size[1] / 2);
        if (self.strip_layer != null) {
            self.track.setBackground(off);
            self.paintStrip(now, on_c);
        } else self.track.setBackground(lerpColor(off, on_c, t)); // Built-in dedup and mark dirty
        self.knob.place(now, self.knobCenter(self.travel.value(now)));
        if (self.knob.animating(now) or !self.travel.done(now) or !self.colourDone(now)) self.cx.needs_redraw = true;
    }
};

fn lerpColor(a: Color, b: Color, t: f32) Color {
    const f = struct {
        fn l(x: u8, y: u8, u: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(x))) * u));
        }
    };
    return Color.rgba(f.l(a.r, b.r, t), f.l(a.g, b.g, t), f.l(a.b, b.b, t), f.l(a.a, b.a, t));
}

pub fn GlassToggle(props: anytype) GlassToggleBuilder {
    return .{ .props = reactive.props.coerce(GlassToggleProps, props) };
}

pub const GlassToggleResult = struct {
    wrapper: *Node,
    on: ?*Signal(bool),
    runtime: *GlassToggleRuntime,
};

pub const GlassToggleBuilder = struct {
    props: GlassToggleProps,

    pub fn mount(self: GlassToggleBuilder, scope: *Scope, cx: *Cx) !GlassToggleResult {
        const p = self.props;
        const my_scope = try scope.childScope();
        var bound = false;
        errdefer if (!bound) my_scope.dispose();
        const a = cx.allocator;
        const on = try reactive.resolveModel(bool, my_scope, p.on);
        const on0 = on.readAs(false);
        const lk = lookFor(p.idiom orelse cx.glass_idiom);

        const container = try box(cx, .{
            .width = .{ .px = lk.toggle_size[0] },
            .height = .{ .px = lk.toggle_size[1] },
            .position = .relative,
        }, .{});
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "GlassToggle";
        if (p.test_id) |tid| container.meta.ownership.meta.test_id = tid;
        container.behavior.interaction.a11y = .{ .role = .switch_role, .checked = on0 };
        try core.bindScopeToNode(my_scope, container);
        bound = true;

        const track = try core.adoptChild(cx, a, container, try box(cx, .{
            .width = .{ .px = lk.toggle_size[0] },
            .height = .{ .px = lk.toggle_size[1] },
            .position = .absolute,
            .background = if (on0 and lk.toggle_strip == null) lk.toggle_on else lk.toggle_off,
        }, .{}));
        (try track.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
        track.style.border = .{ .overlay = true, .width = 0, .color = Color.rgba(0, 0, 0, 0), .radius = lk.toggle_size[1] / 2 };
        (try track.style.ensureExtFallible(a)).corner_radius = core.CornerRadius.uniform(lk.toggle_size[1] / 2);

        // iOS: the on colour's strip window over the track (TrackStrip)
        const strip_layer: ?*Node = if (lk.toggle_strip != null) blk: {
            const n = try core.adoptChild(cx, a, container, try box(cx, .{
                .width = .{ .px = lk.toggle_size[0] },
                .height = .{ .px = lk.toggle_size[1] },
                .position = .absolute,
            }, .{}));
            const e = try n.style.ensureExtFallible(a);
            e.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
            e.corner_radius = core.CornerRadius.uniform(lk.toggle_size[1] / 2);
            e.hit_behavior = .pass_through;
            n.style.border = .{ .overlay = true, .width = 0, .color = Color.rgba(0, 0, 0, 0), .radius = lk.toggle_size[1] / 2 };
            break :blk n;
        } else null;
        const knob = try GlassKnob.mount(my_scope, cx, container, lk.toggle_knob);
        if (p.test_id) |tid| {
            // anchors for the dynamics instruments (knob frames per frame); the nodes own them
            knob.white.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, "{s}.knob", .{tid});
            knob.white.frame_state.state_bits.flags.test_id_owned = true;
        }
        const rt = try my_scope.allocator.create(GlassToggleRuntime);
        const t0: f32 = if (on0) 1 else 0;
        rt.* = .{
            .cx = cx,
            .on = on,
            .on_change = p.on_change,
            .look = lk,
            .container = container,
            .track = track,
            .knob = knob,
            .travel = .{ .from = t0, .to = t0, .start_ms = cx.frame_time_ms },
            .tint = .{ .from = t0, .to = t0, .start_ms = cx.frame_time_ms, .smooth = true },
            .strip = .{ .from = t0, .to = t0, .start_ms = cx.frame_time_ms },
            .strip_layer = strip_layer,
            .shown_on = on0,
        };
        rt.knob.size = .{ .start_ms = cx.frame_time_ms };
        rt.knob.whiteness = .{ .start_ms = cx.frame_time_ms };
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*GlassToggleRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);

        container.style.cursor = .pointer;
        (try container.style.ensureExtFallible(a)).hit_roles = .{ .pointer = true };
        container.behavior.events.event_context = @ptrCast(rt);
        container.behavior.events.on_event = toggleEvent;
        container.on_capture_lost = toggleCaptureLost;
        container.setFocusable(true);
        container.behavior.events.on_key_down = toggleKey;
        container.behavior.events.key_context = @ptrCast(rt);
        container.meta.per_frame.hooks.before_render.main = toggleBeforeRender;
        rt.layoutNow();
        try my_scope.createEffect(rt, struct {
            fn run(r: *GlassToggleRuntime) void {
                const v = r.on.readAs(true);
                if (r.container.behavior.interaction.a11y) |*a11y| a11y.checked = v;
                r.container.markRenderDirty();
                r.cx.needs_redraw = true;
            }
        }.run);
        return .{ .wrapper = container, .on = on.asSignal(), .runtime = rt };
    }
};

fn toggleBeforeRender(node: *Node) void {
    const rt: *GlassToggleRuntime = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    rt.layoutNow();
}

fn toggleCaptureLost(node: *Node) void {
    const rt: *GlassToggleRuntime = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    if (!rt.pressed) return;
    rt.pressed = false;
    const now = rt.cx.frame_time_ms;
    rt.knob.setPressed(now, false);
    rt.settle(now, rt.on.readAs(false));
    rt.cx.needs_redraw = true;
}

fn toggleEvent(event: Event, context: ?*anyopaque) EventResult {
    const rt: *GlassToggleRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    const now = rt.cx.frame_time_ms;
    switch (event) {
        .mouse_down => |e| {
            const cx = rt.cx;
            const identity = cx.node_registry.handleFor(rt.container);
            cx.setPointerCapture(rt.container);
            const live = cx.node_registry.resolve(identity, null) orelse return .stop;
            if (live.behavior.events.event_context != context or live.behavior.events.on_event != toggleEvent) return .stop;
            if (!ownsCapture(cx, rt.container)) return .stop;
            rt.pressed = true;
            rt.dragged = false;
            rt.press_x = e.x;
            rt.press_travel = rt.travel.value(now);
            rt.knob.setPressed(now, true);
            rt.cx.needs_redraw = true;
            return .stop;
        },
        .mouse_move => |e| {
            if (rt.pressed and !ownsCapture(rt.cx, rt.container)) toggleCaptureLost(rt.container);
            if (!rt.pressed) return .ignored;
            const dx = e.x - rt.press_x;
            if (!rt.dragged and @abs(dx) < 3) return .stop;
            rt.dragged = true;
            // Knob follows hand (no spring), flipping display state once past midpoint (native:
            // track already changes color when pressed).
            const t = std.math.clamp(rt.press_travel + dx / rt.travelSpan(), 0, 1);
            rt.travel = .{ .from = t, .to = t, .start_ms = now };
            rt.showState(now, t > 0.5);
            rt.cx.needs_redraw = true;
            return .stop;
        },
        .mouse_up => {
            if (!rt.pressed) return .ignored;
            rt.pressed = false;
            if (ownsCapture(rt.cx, rt.container)) rt.cx.releasePointerCapture();
            rt.knob.setPressed(now, false);
            const target = if (rt.dragged) rt.travel.value(now) > 0.5 else !rt.on.readAs(false);
            rt.settle(now, target);
            rt.cx.needs_redraw = true;
            rt.commit(target); // Last step: do not access rt afterwards
            return .stop;
        },
        else => return .ignored,
    }
}

fn toggleKey(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const rt: *GlassToggleRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    switch (key) {
        .space, .@"return" => {
            const target = !rt.on.readAs(false);
            rt.settle(rt.cx.frame_time_ms, target);
            rt.cx.needs_redraw = true;
            rt.commit(target); // Last step: do not access rt afterwards
            return .stop;
        },
        else => return .ignored,
    }
}

const runBeforeRenderHooks = struct {
    fn run(node: *Node) void {
        if (node.meta.per_frame.hooks.before_render.main) |f| f(node);
        for (node.children.items) |c| run(c);
    }
}.run;

test "GlassKnob springs: press grows to the glass size and fades the white, release reverses" {
    var size = SpringTrack{ .start_ms = 0 };
    var white = LinearTrack{ .start_ms = 0 };
    size.retarget(0, 1, slider_knob.press_scale[0], slider_knob.press_scale[1], slider_knob.press_scale[2]);
    white.retarget(0, 0, slider_knob.press_white[0], slider_knob.press_white[1]);
    try std.testing.expectEqual(@as(f32, 0), size.value(40)); // Size lags behind white start
    // White stays pure white for 15ms (native pauses one frame after press, light tap only fades to
    // light gray), then linearly fades over 90ms.
    try std.testing.expectEqual(@as(f32, 1), white.value(15));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), white.value(60), 0.01);
    try std.testing.expectEqual(@as(f32, 0), white.value(105));
    try std.testing.expect(size.value(300) > 0.99);
    // Released mid-way: continuously fall back from current value.
    const mid = size.value(120);
    size.retarget(120, 0, slider_knob.release_scale[0], slider_knob.release_scale[1], slider_knob.release_scale[2]);
    try std.testing.expectApproxEqAbs(mid, size.value(120), 1e-5);
    try std.testing.expect(size.value(600) < 0.01);
}

test "GlassKnob macOS toggle: a tap's knob keeps growing until the release takes effect" {
    var size = SpringTrack{ .start_ms = 0 };
    var white = SpringTrack{ .from = 1, .to = 1 };
    const ps = toggle_knob.press_smooth.?;
    size.retargetSmooth(0, 1, ps[0][0], ps[0][1]);
    white.retargetSmooth(0, 0, ps[1][0], ps[1][1]);
    // eased in: nothing before the delay, half way at the middle of the ramp
    try std.testing.expectEqual(@as(f32, 0), size.value(20));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), size.value(ps[0][0] + ps[0][1] / 2), 1e-4);
    // a 70 ms tap: the press curve runs on through the release delay (native: 34.3 x 21.4 at
    // ~100 ms), then the release spring starts from there, continuously
    const up: f64 = 70;
    const due = up + toggle_knob.release_scale[0];
    const at_due = size.value(due);
    size.retarget(up, 0, toggle_knob.release_scale[0], toggle_knob.release_scale[1], toggle_knob.release_scale[2]);
    try std.testing.expect(size.value(up + 20) > size.value(up));
    try std.testing.expectApproxEqAbs(at_due, size.value(due), 1e-5);
    try std.testing.expectApproxEqAbs(at_due, size.value(due + 0.01), 1e-3);
    try std.testing.expect(size.value(due + 600) < 0.01);
    const ws = toggle_knob.white_spring.?[1];
    const w_due = white.value(up + ws[0]);
    white.retarget(up, 1, ws[0], ws[1], ws[2]);
    try std.testing.expectApproxEqAbs(w_due, white.value(up + ws[0]), 1e-5);
    try std.testing.expect(white.value(up + 700) > 0.99);
}

test "GlassToggle: click toggles with travel + track fade, drag past the middle flips while held" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const r = try GlassToggle(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);
    ctx.layout();
    const rt = r.runtime;
    ctx.frame_time_ms = 1000;
    _ = toggleEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = .left } }, rt);
    try std.testing.expect(rt.knob.pressed);
    ctx.frame_time_ms = 1500;
    runBeforeRenderHooks(r.wrapper);
    // Held: off track darkens to 19% black.
    try std.testing.expectEqual(track_pressed.a, rt.track.getBackground().a);
    ctx.frame_time_ms = 1000;
    _ = toggleEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = .left } }, rt);
    try std.testing.expect(r.on.?.peek());
    try std.testing.expectEqual(@as(f32, 0), rt.travel.value(1000));
    ctx.frame_time_ms = 1600;
    try std.testing.expectApproxEqAbs(@as(f32, 1), rt.travel.value(1600), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rt.tint.value(1600), 1e-4);
    runBeforeRenderHooks(r.wrapper);
    // Drag: dragging from on leftward past midpoint, display flips to off while held.
    _ = toggleEvent(.{ .mouse_down = .{ .x = 40, .y = 10, .button = .left } }, rt);
    _ = toggleEvent(.{ .mouse_move = .{ .x = 25, .y = 10 } }, rt);
    try std.testing.expect(!rt.shown_on);
    try std.testing.expect(r.on.?.peek()); // Data unchanged before landing
    _ = toggleEvent(.{ .mouse_up = .{ .x = 25, .y = 10, .button = .left } }, rt);
    try std.testing.expect(!r.on.?.peek());
}

test "GlassSlider: pressing the knob turns it to glass, dragging keeps the grab offset" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const r = try GlassSlider(.{ .width = 240 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);
    ctx.layout();
    const rt = r.runtime;
    try std.testing.expectEqual(@as(f32, 120), rt.knobX(rt.ratio())); // 0.5 -> center
    ctx.frame_time_ms = 1000;
    _ = sliderEvent(.{ .mouse_down = .{ .x = 123, .y = 10, .button = .left } }, rt); // Pressed on knob offset right by 3
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.value.?.peek(), 1e-6); // No jump
    _ = sliderEvent(.{ .mouse_move = .{ .x = 183, .y = 10 } }, rt);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 + 60.0 / 220.0), r.value.?.peek(), 1e-4);
    ctx.frame_time_ms = 1400;
    runBeforeRenderHooks(r.wrapper);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rt.knob.whiteness.value(1400), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 25), rt.knob.glass.box.style.width.px, 0.05);
    _ = sliderEvent(.{ .mouse_up = .{ .x = 183, .y = 10, .button = .left } }, rt);
    ctx.frame_time_ms = 2000;
    runBeforeRenderHooks(r.wrapper);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rt.knob.whiteness.value(2000), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 20), rt.knob.glass.box.style.width.px, 0.05);
}

test "TrackStrip: the iOS track colour sweeps in from the left as the native strip slides" {
    const t = std.testing;
    var st: [4][2]f32 = undefined;
    // off / on: uniform
    var n = TrackStrip.stops(0, &st);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(f32, 0), st[0][1]);
    try t.expectEqual(@as(f32, 0), st[1][1]);
    n = TrackStrip.stops(1, &st);
    try t.expectEqual(@as(f32, 1), st[0][1]);
    try t.expectEqual(@as(f32, 1), st[1][1]);
    // halfway: a gradient, greener on the left (strip at -4.5 w: alpha 0.5625 .. 0.4375)
    n = TrackStrip.stops(0.5, &st);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectApproxEqAbs(@as(f32, 0.5625), st[0][1], 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0.4375), st[1][1], 1e-5);
    // near on: the opaque head's edge crosses the track (a stop at the kink)
    n = TrackStrip.stops(0.95, &st);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectApproxEqAbs(@as(f32, 0.55), st[1][0], 1e-4);
    try t.expectEqual(@as(f32, 1), st[1][1]);
    try t.expect(st[2][1] < 1);
}

test "GlassToggle iOS: tap slides the knob and sweeps the strip on the native springs" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const r = try GlassToggle(.{ .idiom = .ios }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);
    ctx.layout();
    const rt = r.runtime;
    try std.testing.expect(rt.strip_layer != null);
    ctx.frame_time_ms = 1000;
    _ = toggleEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = .left } }, rt);
    ctx.frame_time_ms = 1065;
    _ = toggleEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = .left } }, rt);
    // native strip progress 0.50 at 0.18 s after the release (response 0.68, critically damped)
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), rt.strip.value(1065 + 184), 0.03);
    // knob halfway ~0.11 s after the release (response 0.31, 15 ms delay)
    try std.testing.expect(rt.travel.value(1065 + 15 + 105) > 0.4 and rt.travel.value(1065 + 15 + 105) < 0.65);
    ctx.frame_time_ms = 1065 + 1500;
    runBeforeRenderHooks(r.wrapper);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rt.strip.value(ctx.frame_time_ms), 1e-3);
}

test "GlassKnob iOS: a quick tap keeps the knob lifted for the minimum lift, then lets go" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const r = try GlassToggle(.{ .idiom = .ios }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, r.wrapper);
    ctx.layout();
    const rt = r.runtime;
    ctx.frame_time_ms = 1000;
    _ = toggleEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = .left } }, rt);
    ctx.frame_time_ms = 1050;
    _ = toggleEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = .left } }, rt);
    // 150 ms after the press: still glass (native: the white face is gone until 0.24 s)
    ctx.frame_time_ms = 1150;
    runBeforeRenderHooks(r.wrapper);
    try std.testing.expect(rt.knob.whiteAt(1150) < 0.05);
    try std.testing.expect(rt.knob.release_due != null);
    // past the minimum lift the release runs (white back by ~0.45 s)
    ctx.frame_time_ms = 1250;
    runBeforeRenderHooks(r.wrapper);
    try std.testing.expect(rt.knob.release_due == null);
    ctx.frame_time_ms = 1700;
    runBeforeRenderHooks(r.wrapper);
    try std.testing.expect(rt.knob.whiteAt(1700) > 0.9);
}
