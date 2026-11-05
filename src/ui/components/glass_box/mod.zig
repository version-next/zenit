/// GlassBox component.
///
/// UI panel built on the existing Liquid Glass rendering. Instead of a hard-coded preset, it uses
/// the real laid-out size in the before_render phase to converge blur / tint / refraction / warp
/// into ranges better suited to hosting text content.
const std = @import("std");
const concentric_mod = @import("../../concentric.zig");
const a11y_preferences = @import("../../a11y/preferences.zig");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const types = @import("../../core/types.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const CornerRadius = core.CornerRadius;
const Shadow = core.Shadow;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const bind_mod = @import("../../bind.zig");
const ScrollState = @import("../scroll_area/state.zig").ScrollState;
const Event = @import("../../events.zig").Event;
const EventResult = @import("../../events.zig").EventResult;
const TransactionClock = @import("../../core/presentation_clock.zig").TransactionClock;
pub const profile = @import("profile.zig");
pub const GlassIdiom = profile.GlassIdiom;
pub const GlassProfile = profile.GlassProfile;
pub const MaterialFamily = profile.MaterialFamily;

pub const GlassBoxReadability = enum {
    balanced,
    preferred,
    maximum,
};

/// `NSGlassEffectView.Style` (macOS 26):
/// .regular = adaptive, keeps content readable (default; for text/controls);
/// .clear = highly transparent, almost no tint/fog, for overlaying rich content such as media
///          (Apple requires the content beneath clear to bring its own dimming; text relies on its
///          own shadow for legibility).
pub const GlassEffectStyle = enum {
    regular,
    clear,
    /// SwiftUI `Glass.identity` / `glassEffect(isEnabled: false)`: draws no material,
    /// keeps only layout and content (morphing to/from it gives appear/disappear transitions).
    identity,
};

/// Maps to SwiftUI `glassEffect(in: Shape)`: capsule (SwiftUI default) / circle use half of the
/// shorter side of the actual size each frame; rounded uses a fixed corner radius.
pub const GlassBoxShape = union(enum) {
    capsule,
    circle,
    rounded: f32,
    /// SwiftUI `ConcentricRectangle(corners: .concentric(minimum:))`: each corner is concentric
    /// with the nearest
    /// container-shape ancestor (ui.concentric.containerShape), with value minimum (see
    /// ui/concentric.zig).
    concentric: f32,
};

/// `NSScrollEdgeEffectStyle` (macOS 26.1) / SwiftUI `scrollEdgeEffectStyle`: soft fades out
/// progressively; hard keeps uniform intensity across the whole glass area (WWDC25 219,
/// 09:41-09:51); automatic lets the system choose and resolves to soft (native soft / hard /
/// automatic captures are pixel-identical on macOS 26.4, see docs/GLASS_NATIVE_FIDELITY.md).
pub const ScrollEdgeStyle = enum { automatic, soft, hard };

pub const GlassBoxEmphasis = enum {
    subtle,
    regular,
    prominent,
};

// Header text style extracted to styles.zig.
const styles = @import("styles.zig");
const glassTitleStyle = styles.glassTitleStyle;
const glassSubtitleStyle = styles.glassSubtitleStyle;

/// Maps to `glassEffectTransition`: materialize = appear/disappear modulates coating/rim/lens/blur
/// (measured: disappear ~0.27 s, appear ~0.42 s, smoothstep shaped, not an alpha fade);
/// matched_geometry morphs across layouts for the same id; identity has no transition.
pub const GlassTransition = enum { materialize, matched_geometry, identity };

/// glassEffectUnion id -> shape table key (0 reserved for "not participate").
pub fn unionKey(id: []const u8) u32 {
    const h: u32 = @truncate(std.hash.Wyhash.hash(0x6c69717569, id));
    return if (h == 0) 1 else h;
}

pub const GlassPressFeedback = enum { none, glass_button };

/// A fully transparent `tintColor` is no tint at all (native alpha 0 output == untinted).
pub fn effectiveTintColor(tint: ?Color) ?Color {
    const t = tint orelse return null;
    return if (t.a == 0) null else t;
}

pub const GlassBoxProps = struct {
    /// Title/subtitle (empty string = none; can pass signal: hidden when empty).
    title: Source([]const u8) = .{ .value = "" },
    subtitle: Source([]const u8) = .{ .value = "" },
    width: ?f32 = null,
    height: ?f32 = null,
    padding: ?Padding = null,
    body_gap: f32 = 12,
    /// `NSGlassEffectView.cornerRadius`; null = the idiom profile's default (macOS 8).
    corner_radius: ?f32 = null,
    /// Shape (SwiftUI `in:`). When null, uses fixed `corner_radius`.
    shape: ?GlassBoxShape = null,
    /// SwiftUI `glassEffect(isEnabled:)`: false equivalent to `.identity`.
    enabled: bool = true,
    /// Transition mode for runtime glassSetEnabled.
    transition: GlassTransition = .materialize,
    readability: GlassBoxReadability = .preferred,
    emphasis: GlassBoxEmphasis = .regular,
    /// `NSGlassEffectView.style`. Named `glass_style` because `style` is the framework-wide
    /// visual-style attribute (Yix routes `style=` on a component to its root node).
    glass_style: GlassEffectStyle = .regular,
    /// Platform rendering (macOS / iOS measured profile); null = `Cx.glass_idiom`.
    idiom: ?GlassIdiom = null,
    /// `NSGlassEffectView.tintColor`: the glass tints toward this color. Its alpha is the tint
    /// amount: the result is the untinted glass mixed toward the fully tinted glass by alpha
    /// (native: exactly linear in sRGB, e.g. regular over white red 249 -> 254, 249 -> 50 at
    /// alpha 0 -> 1, 251 / 149 at 0.5). Alpha 0 equals no tint.
    tint_color: ?Color = null,
    /// Interactive (`.interactive()`): hit testing, hover/press state, and content fading on press.
    /// Measured on native
    /// macOS 26.4 (native_interactive.swift, real cursor + real click): custom interactive glass
    /// shows
    /// no visible material change on hover or press; the glass itself does not respond.
    interactive: bool = false,
    /// Glass feedback on press. `.glass_button` = system `.glass` button style: on the press frame
    /// the body shifts
    /// by a constant in sRGB (light family -19.8, dark family +17.7, independent of background);
    /// restored on release frame; no hover change.
    press_feedback: GlassPressFeedback = .none,
    /// glassEffectUnion(id:): members of the same GlassGroup with equal union_id merge into one
    /// shape
    /// at rest (a same-kind shape over the overall bounding box, measured on native
    /// native_union.swift). null = not part of any union.
    union_id: ?[]const u8 = null,
    /// Popover arrow (glass shape of SwiftUI `.popover`): the node rect includes the arrow area;
    /// the content
    /// area automatically yields `length` on the arrow side. null = no arrow.
    arrow: ?GlassArrow = null,
    /// Material. `.knob_lens` = glass of the native slider / switch knob while held
    /// (native_slider_toggle.swift):
    /// a non-blurring shrunken lens, 178-gray 16% coating, dark accent edge at top-left, bright
    /// edge below.
    material: GlassMaterial = .standard,
    /// Which native lens `.tab_lens` renders (same `_UILiquidLensView`, measured field per use).
    lens_variant: LensVariant = .tab,
    /// Knob lenses' key highlight colour matrix (native vibrantColorMatrix, rows {r, g, b, offset}
    /// applied to the glass beneath it); it follows the control's tint.
    lens_key_matrix: [12]f32 = @as([12]f32, @splat(0)),
    /// `.blur_only` blur radius (logical px, pipeline blur radius).
    blur_radius: f32 = 0,
    /// Shadow. Native `.popover` glass has no shadow (native_menu_morph.swift pixel-diff 0),
    /// popover passes false.
    drop_shadow: bool = true,
    /// scroll-edge effect: once bound to a ScrollArea, a progressive blur/darken band appears where
    /// content scrolls past the glass edge (driven live by scroll position, with interpolation
    /// smoothing).
    scroll_edge: ?ScrollEdgeBinding = null,
};

pub const ScrollEdge = enum(u8) { top = 1, bottom = 2, left = 3, right = 4 };

pub const GlassArrowEdge = enum(u8) { bottom = 1, top = 2, left = 3, right = 4 };

/// The iOS `_UILiquidLensView` as used by each control: the same filter stack with different
/// inputs (tab: displacement 9, inner refraction -17.5 over 7 pt, aberration 3.68; slider thumb:
/// displacement 0, -18.5 over 6.66 pt, aberration 1.95; switch knob: displacement 9, -19.2 over
/// 6.9 pt, aberration 2.02), so a separately measured field each (glass.metal lens_sample_point).
pub const LensVariant = enum(u8) {
    tab = 0,
    slider_thumb = 1,
    switch_knob = 2,
    /// macOS NSSwitch / NSSlider knob: the iOS switch lens with every input proportional to the
    /// lens height (held NSSwitch 50 x 31: displacement 7.75, inner refraction -15.5 over 5.58 pt,
    /// aberration 1.632, no portal displacement)
    mac_knob = 3,

    /// The knob lens's filter inputs at lens height `height` (pt): {displacementMap amount, its SDF
    /// height, glassBackground |innerRefractionAmount|, innerRefractionHeight}; every native
    /// reading is proportional to the lens (held UISwitch 38.3: 9 / 36 / 19.17 / 6.9; UISlider
    /// 37: 0 / 36 / 18.5 / 6.66; NSSwitch 31: 7.75 / 31 / 15.5 / 5.58): SDF height = the lens
    /// height capped at 36, amount = a quarter of it (none on the iOS slider), inner refraction
    /// 0.5 and 0.18 x the height. The tab lens keeps its measured table (zeros).
    pub fn knobInputs(self: LensVariant, height: f32) [4]f32 {
        const sdf_h = @min(height, 36);
        return switch (self) {
            .tab => .{ 0, 0, 0, 0 },
            .slider_thumb => .{ 0, sdf_h, 0.5 * height, 0.18 * height },
            .switch_knob, .mac_knob => .{ sdf_h / 4, sdf_h, 0.5 * height, 0.18 * height },
        };
    }

    /// glassForeground aberrationAmount relative to the tab lens's 3.684 (edgeStart scales alike);
    /// `height` = the lens's height (pt), for the size-proportional macOS knob
    pub fn aberrationScale(self: LensVariant, height: f32) f32 {
        return switch (self) {
            .tab => 1,
            .slider_thumb => 1.947 / 3.684,
            .switch_knob => 2.018 / 3.684,
            // the layer tree says 1.632 at height 31, but the held NSSwitch shows no fringe
            // (neutral 117 at the track's edge under the lens, where the same model gives
            // (123,117,105)): none
            .mac_knob => 0 * height,
        };
    }
};

pub const GlassMaterial = enum {
    standard,
    knob_lens,
    /// iOS tab bar selection lens (`_UILiquidLensView`'s clear glass while lifted): the clear
    /// glass rim and lens without blur or the clear coating; the interior reads the platter
    /// almost unchanged (native 216 -> 212: 8 % veil toward 168).
    tab_lens,
    /// Only blur content behind: no coating, no highlight, no lens, no shadow
    /// (backgroundExtensionEffect blur layer).
    blur_only,
};

var knob_lens_env_read = false;
/// Calibration: ZENIT_KNOB_LENS="veil,bezel,height,base,rim" overrides knob_lens parameters
/// (bezel/height/base as h multiples).
fn knobLensEnvOverride() void {
    if (knob_lens_env_read) return;
    knob_lens_env_read = true;
    // getEnvVarOwned not posix.getenv: Windows environment block is WTF-16, posix.getenv
    // unavailable there.
    var env_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&env_buf);
    const raw = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_KNOB_LENS") catch return;
    var it = std.mem.splitScalar(u8, raw, ',');
    const fields = [_]*f32{ &knob_lens.veil_alpha, &knob_lens.bezel, &knob_lens.height, &knob_lens.base, &knob_lens.rim };
    for (fields) |f| {
        const tok = it.next() orelse return;
        f.* = std.fmt.parseFloat(f32, tok) catch return;
    }
}

/// Tunables of `.knob_lens`: calibrated from the held-frame profile of native_slider_toggle.swift.
/// Lens geometry scales with half-short-side h:
/// bezel = h*min(1, h/15.5) (small knobs have a narrower bezel), height 1.5h, base 0; the switch
/// h=15.5 and slider h=10
/// fit four sets of edge-displacement constraints within 0.3pt (a bezel proportional to h model
/// errs by an order of magnitude more).
/// Coating = 178 gray 16% (sRGB: gray 128->136, track 115->125, 104->116).
pub const knob_lens = struct {
    pub var veil_alpha: f32 = 0.16;
    pub var bezel: f32 = 1.0;
    pub var height: f32 = 1.5;
    pub var base: f32 = 0.0;
    /// Dark edge alpha
    pub var rim: f32 = 0.95;
};

var tab_lens_env_read = false;
/// Calibration: ZENIT_TAB_LENS="offset,rim,rim_inset,glow_top,glow_bottom,blur,rim_width,dip,dip_inset" overrides tab_lens parameters.
fn tabLensEnvOverride() void {
    if (tab_lens_env_read) return;
    tab_lens_env_read = true;
    var env_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&env_buf);
    // ZENIT_TAB_LENS_SHADOW="alpha,blur,offset,spread" overrides the lens shadow
    if (@import("zenit_environment").getOwned(fba.allocator(), "ZENIT_TAB_LENS_SHADOW") catch null) |sh| {
        var sit = std.mem.splitScalar(u8, sh, ',');
        for ([_]*f32{ &tab_lens.shadow_alpha, &tab_lens.shadow_blur, &tab_lens.shadow_offset, &tab_lens.shadow_spread }) |f| {
            f.* = std.fmt.parseFloat(f32, sit.next() orelse break) catch break;
        }
    }
    // a buffer of its own: a long ZENIT_TAB_LENS_SHADOW must not starve this one
    var env_buf2: [256]u8 = undefined;
    var fba2 = std.heap.FixedBufferAllocator.init(&env_buf2);
    const raw = @import("zenit_environment").getOwned(fba2.allocator(), "ZENIT_TAB_LENS") catch return;
    var it = std.mem.splitScalar(u8, raw, ',');
    const fields = [_]*f32{ &tab_lens.offset, &tab_lens.rim, &tab_lens.rim_inset, &tab_lens.glow_top, &tab_lens.glow_bottom, &tab_lens.blur, &tab_lens.rim_width, &tab_lens.dip, &tab_lens.dip_inset };
    for (fields) |f| {
        const tok = it.next() orelse return;
        f.* = std.fmt.parseFloat(f32, tok) catch return;
    }
}

/// Tunables of `.tab_lens` (iOS 26.5 Simulator held tab lens, ios/compare_tab_lens.py): the
/// coating is a constant offset (platter 216 -> 212, dark backdrop 121 -> 115 in the band: a
/// transfer curve, not a veil); the outward shift equals inset - lag up to a 3.7 pt plateau (so
/// the dark band only appears where the lifted lens overhangs the platter by 3 pt or more) and
/// fades out into the body (GlassParams.tab_lens).
pub const tab_lens = struct {
    /// (The displacement field is the measured native table glass.metal's tab_lens_field
    /// reads (src/render/tab_lens_field_table.zig); GlassParams.tab_lens[0] > 0 only marks the
    /// material.)
    /// Coating offset in sRGB levels (negative darkens)
    pub var offset: f32 = -5.0;
    /// Rim: a 1 px wide line of this sRGB value centred `rim_inset` px inside the contour
    /// (native: 220 over the dark backdrop at the top, 226 over the platter at the sides)
    pub var rim: f32 = 232.0;
    pub var rim_inset: f32 = 0.25;
    /// Inner glow amplitudes (sRGB levels at 2 pt inside the top / bottom contour). Off: the
    /// bright strip under the rim is the fold sampling the platter edge, not a glow.
    pub var glow_top: f32 = 0.0;
    pub var glow_bottom: f32 = 0.0;
    /// Backdrop blur sigma of the lens (pt); 0 = sharp
    pub var blur: f32 = 0.0;
    /// Rim line half width (px) and the faint dark line inside it (sRGB levels, px inset)
    pub var rim_width: f32 = 1.6;
    pub var dip: f32 = 0.0;
    pub var dip_inset: f32 = 2.2;
    /// The lens's drop shadow (alpha 0-1, blur and downward offset in pt). Native: glassBackground
    /// draws it from the lens SDF moved 7 pt down, alpha shadow_opacity 0.09998 x
    /// shadow_face_opacity 1.1114 times 1/2 erfc(d / 8) (its polynomial, decompiled); the SDF
    /// renderer's smoothstep(blur, -blur, d) has erfc's slope at the contour at blur 10.6.
    pub var shadow_alpha: f32 = 0.1111;
    pub var shadow_blur: f32 = 10.6;
    pub var shadow_offset: f32 = 7;
    pub var shadow_spread: f32 = 0;
};

/// Native `.popover` arrow (native_menu_morph.swift, fitted per row width against the body bottom
/// edge 94.75,
/// RMS 0.155 logical px): 90 degree apex, protrudes 10.8, tip corner radius 5.25, joined to the
/// body by a circular smooth union with k=2.
pub const GlassArrow = struct {
    edge: GlassArrowEdge = .bottom,
    /// Offset of the arrow tip along the edge relative to the edge center (logical px): +x on
    /// top/bottom edges, +y (downward) on left/right edges.
    /// The shader clamps it so the body-side corners do not extend beyond the node.
    offset: f32 = 0,
    length: f32 = 10.8,
    tip_radius: f32 = 5.25,
};

pub const ScrollEdgeBinding = struct {
    /// Scroll state of the ScrollArea covered by the glass
    scroll: *ScrollState,
    edge: ScrollEdge = .top,
    style: ScrollEdgeStyle = .automatic,
    /// Gradient band width (logical pixels)
    fade_width: f32 = 32,
    /// Scroll distance needed for full intensity (logical pixels)
    ramp_distance: f32 = 28,
    max_strength: f32 = 0.9,
};

pub fn GlassBox(props: anytype) GlassBoxBuilder {
    return .{ .props = @import("../../reactive.zig").props.coerce(GlassBoxProps, props) };
}

pub const GlassBoxBuilder = struct {
    props: GlassBoxProps,

    pub fn mount(self: GlassBoxBuilder, scope: *Scope, cx: *Cx) !*Node {
        const mounted = try self.mountBody(scope, cx);
        return mounted.box;
    }

    /// `ui.view` integration (see GlassBoxMount.viewParts).
    pub fn viewMount(self: GlassBoxBuilder, scope: *Scope, cx: *Cx) !GlassBoxMount {
        return self.mountWithState(scope, cx);
    }

    /// Use this entry point for cases that need a state handle, such as morph / brightness
    /// adaptation.
    pub fn mountWithState(self: GlassBoxBuilder, scope: *Scope, cx: *Cx) !GlassBoxMount {
        const mounted = try self.mountBody(scope, cx);
        const raw = mounted.box.meta.per_frame.hooks.slots.anim_state.?;
        return .{
            .box = mounted.box,
            .body = mounted.body,
            .state = @ptrCast(@alignCast(raw)),
        };
    }

    pub fn mountBody(self: GlassBoxBuilder, scope: *Scope, cx: *Cx) !struct { box: *Node, body: *Node } {
        const my_scope = try scope.childScope();
        // Any failure before binding to root is cleaned up here by freeing my_scope (including the
        // child scope built by view.render);
        // after binding, errdefer cx.freeNode(root) disposes it along with the node.
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const tokens = cx.tokens;
        const p = self.props;
        var base_padding = p.padding orelse Padding.all(16);
        if (p.arrow) |ar| switch (ar.edge) {
            .bottom => base_padding.bottom += ar.length,
            .top => base_padding.top += ar.length,
            .left => base_padding.left += ar.length,
            .right => base_padding.right += ar.length,
        };
        const glass_profile = (p.idiom orelse cx.glass_idiom).profile();
        const corner_radius = @max(p.corner_radius orelse glass_profile.default_corner_radius, 0);
        const tint_color = effectiveTintColor(p.tint_color);

        // Header (always built when dynamic, hidden when empty; not built for a static empty
        // string)
        const want_title = !p.title.isStatic() or p.title.peek().len > 0;
        const want_subtitle = !p.subtitle.isStatic() or p.subtitle.peek().len > 0;
        // An explicitly sized glass panel is a viewport; long content must not
        // impose its intrinsic minimum on the content/body wrappers.
        const grow_if_sized: core.Sizing = if (p.height != null) .{ .grow = .{ .min = 0 } } else .{ .fit = .{} };
        var title_style = glassTitleStyle(tokens);
        if (p.glass_style == .clear) title_style.color = Color.WHITE;
        var subtitle_style = glassSubtitleStyle(tokens);
        if (p.glass_style == .clear) subtitle_style.color = Color.WHITE.withAlpha(204);
        const wants_pointer = p.interactive or p.press_feedback != .none;

        const Parts = struct { surface: *Node = undefined, content: *Node = undefined, header: ?*Node = null, title: ?*Node = null, subtitle: ?*Node = null, body: *Node = undefined };
        var parts: Parts = .{};
        const root = try view.render(my_scope, cx, view.col(.{
            .style = core.BoxStyle{
                .width = if (p.width) |value| .{ .px = value } else .{ .fit = .{} },
                .height = if (p.height) |value| .{ .px = value } else .{ .fit = .{} },
                .position = .relative,
                // interactive / press feedback: hover / press go through root's event handler (see
                // on_event below)
                .cursor = if (wants_pointer) .pointer else null,
                .hit_roles = if (wants_pointer) .{ .pointer = true } else null,
            },
        }, .{
            // Layering: the root wrapper holds only the shadow; glass lives on an in-flow surface
            // child.
            // 1) a shadow on the glass node itself inflates the promoted surface bounds ->
            //    composites into
            //    rectangular chunks (framework bug); 2) an absolute surface misaligns backdrop
            //    sampling.
            view.capture(&parts.surface, view.col(.{
                .style = core.BoxStyle{
                    .width = .{ .grow = .{} },
                    // The painted surface follows the wrapper, even when padded
                    // content needs more room. Its content clip handles overflow.
                    .height = .{ .grow = .{ .min = 0 } },
                    .border = .{ .overlay = true, .width = 1, .color = Color.rgba(255, 255, 255, 112), .radius = corner_radius },
                    .background = Color.rgba(255, 255, 255, 16),
                    .corner_radius = corner_radius,
                },
            }, .{
                view.capture(&parts.content, view.col(.{
                    .style = core.BoxStyle{
                        .width = .{ .grow = .{} },
                        .height = grow_if_sized,
                        .gap = p.body_gap,
                        .padding = base_padding,
                        .position = .relative,
                        // `NSGlassEffectView` always clips its contentView to the glass shape
                        // (measured: an overflowing subview is cut along the rounded corner whether
                        // `clipsToBounds` is on or off). The clip sits on the content, not on the
                        // glass surface, so the glass rim itself is never cut; it follows the
                        // per-frame shape (applyAdaptiveGlass).
                        .overflow_hidden = true,
                        .corner_radius = corner_radius,
                    },
                }, .{
                    if (want_title or want_subtitle) view.capture(&parts.header, view.col(.{ .style = .{
                        .width = .{ .grow = .{} },
                        .gap = 4,
                    } }, .{
                        if (want_title) view.capture(&parts.title, view.text(.{ .style = title_style }, "")) else null,
                        if (want_subtitle) view.capture(&parts.subtitle, view.text(.{ .style = subtitle_style }, "")) else null,
                    })) else null,
                    view.capture(&parts.body, view.col(.{ .style = core.BoxStyle{
                        .width = .{ .grow = .{} },
                        .height = grow_if_sized,
                        .gap = p.body_gap,
                    } }, {})),
                })),
            })),
        }));
        root.meta.ownership.meta.component_name = "GlassBox";
        // sweep: the root guard stays armed until return (after bind, freeNode disposes my_scope
        // along with it)
        errdefer cx.freeNode(root);
        try core.bindScopeToNode(my_scope, root);
        scope_bound = true;

        if (parts.title) |title_node| try bind_mod.bindOptionalTextRow(cx, my_scope, p.title, title_node, parts.header, null);
        if (parts.subtitle) |subtitle_node| try bind_mod.bindOptionalTextRow(cx, my_scope, p.subtitle, subtitle_node, parts.header, null);
        const surface = parts.surface;
        const content_wrapper = parts.content;
        const header_title: ?*Node = parts.title;
        const header_subtitle: ?*Node = parts.subtitle;
        const body = parts.body;
        // Hits reach the content anywhere inside its rectangular bounds (AppKit `hitTest:` is
        // frame-based); only drawing is clipped to the glass shape.
        (try content_wrapper.style.ensureExtFallible(allocator)).hit_clip_shape = .rect;

        const adapts = adaptsFamily(&glass_profile.family, p.glass_style, tint_color != null);
        const adaptive = try allocator.create(AdaptiveGlassBoxState);
        adaptive.* = .{
            .allocator = allocator,
            .cx = cx,
            .surface = surface,
            .content = content_wrapper,
            .theme_tokens = tokens,
            .radius = corner_radius,
            .profile = glass_profile,
            .readability = p.readability,
            .emphasis = p.emphasis,
            .variant = p.glass_style,
            .shape = p.shape,
            .enabled = p.enabled,
            .transition = p.transition,
            .materialize_level = if (p.enabled) 1.0 else 0.0,
            .tint_override = tint_color,
            // A new effect starts from the family matching the appearance
            // (native_family_fresh.swift: light appearance uses the 215 light family, dark uses the
            // 45 dark family);
            // small elements then adapt to their own background.
            // clear / tinted have no families (the dark end comes from the theme's dark_factor);
            // only untinted regular starts by appearance.
            .family_dark = tokens.scheme == .dark and adapts,
            .family_adaptive = adapts,
            .family_mix = if (tokens.scheme == .dark and adapts) 1 else 0,
            .family_ink_mix = if (tokens.scheme == .dark and adapts) 1 else 0,
        };
        try my_scope.adoptResource(@ptrCast(adaptive), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(ptr));
                exitGroupMode(state);
                alloc.destroy(state);
            }
        }.cleanup);

        adaptive.interactive = p.interactive or p.press_feedback != .none;
        adaptive.press_feedback = p.press_feedback;
        adaptive.union_key = if (p.union_id) |id| unionKey(id) else 0;
        adaptive.scroll_edge = p.scroll_edge;
        adaptive.arrow = if (p.arrow) |ar| .{ @floatFromInt(@backingInt(ar.edge)), ar.offset, ar.length, ar.tip_radius } else .{ 0, 0, 0, 0 };
        adaptive.drop_shadow = p.drop_shadow;
        adaptive.material = p.material;
        adaptive.lens_variant = p.lens_variant;
        adaptive.lens_key_matrix = p.lens_key_matrix;
        adaptive.blur_radius = p.blur_radius;
        if (p.glass_style != .clear) {
            adaptive.title_node = header_title;
            adaptive.subtitle_node = header_subtitle;
        }
        adaptive.root = root;
        root.meta.per_frame.hooks.slots.anim_state = @ptrCast(adaptive);
        // The hook writes the surface / group surface / content through dirty-marking entries
        // (markGlassSurfaceDirty, setContentClipExt, setOpacity, setShadow), so the glass content
        // subtree stays cacheable across frames (audited in Debug). Declared before registering:
        // registration marks an undeclared hook's ancestors untrusted for good.
        root.frame_state.state_bits.flags.before_render_hook_descendants_cache_safe = true;
        root.addBeforeRender(glassBoxBeforeRender);

        if (wants_pointer) {
            root.behavior.events.event_context = @ptrCast(adaptive);
            root.behavior.events.on_event = interactiveGlassEventHandler;
        }

        // A fresh effect is visible from its first frame in the appearance family (native); the
        // before_render hook switches it to its backdrop's family on the native schedule once the
        // first luminance reading lands (see AdaptiveGlassBoxState.family_probe).
        // Apply the fallback once first so tests do not read empty params after mount.
        const initial = resolvedGlassBoxStyle(glass_profile, tokens, p.readability, p.emphasis, if (p.enabled) p.glass_style else .identity, tint_color, 220, p.height orelse 140, corner_radius, null, if (adapts) (if (adaptive.family_dark) MaterialFamily.dark else .light) else .appearance);
        try applyAdaptiveGlass(root, adaptive, initial);

        return .{ .box = root, .body = body };
    }
};

pub const GlassBoxMount = struct {
    box: *Node,
    body: *Node,
    state: *AdaptiveGlassBoxState,

    /// `ui.view` integration: the content of `v.with(W.GlassBox(...), .{ content })` goes into the
    /// body;
    /// to get the morph / brightness-adaptation handle, use `v.capture(&st.glass, ...)` to obtain
    /// the whole GlassBoxMount.
    pub fn viewParts(self: GlassBoxMount) core.ViewParts {
        return .{ .root = self.box, .slot = self.body };
    }
};

/// Start the glass morph transition: geometry (absolute inset positioning) is interpolated and the
/// glass
/// parameter fields at both ends transition field by field. root must be absolutely positioned
/// (caller layout contract).
pub fn glassMorphTo(state: *AdaptiveGlassBoxState, spec: MorphSpec) void {
    if (@import("zenit_environment").flag("ZENIT_DEBUG_GLASS")) std.debug.print("[morph] glassMorphTo called root={}\n", .{state.root != null});
    const root = state.root orelse return;
    const lr = root.rectFromWorldOrFallback();
    const r: struct { x: f32, y: f32, w: f32, h: f32 } = if (spec.from) |f| .{ .x = f[0], .y = f[1], .w = f[2], .h = f[3] } else .{ .x = lr.x, .y = lr.y, .w = lr.w, .h = lr.h };
    const from_w = if (spec.from != null or r.w > 0.5) r.w else 220;
    const from_h = if (spec.from != null or r.h > 0.5) r.h else 140;
    const to_readability = spec.readability orelse state.readability;
    const to_emphasis = spec.emphasis orelse state.emphasis;
    const to_variant = spec.glass_style orelse state.variant;
    const base_ms: f64 = spec.duration_ms orelse @as(f64, @floatFromInt(@max(spec.frames, 2))) * 1000.0 / 60.0;
    state.morph = .{
        .start_time_ms = state.cx.eventTimeMs(),
        // The spring curve only reaches 98.6% at duration: run 15% longer, then snap into place
        .duration_ms = if (spec.easing == .spring_smooth) base_ms * springSettleFactor(morphTravel(.{ r.x, r.y, from_w, from_h }, .{ spec.x, spec.y, spec.w, spec.h })) else base_ms,
        .spring_base_ms = base_ms,
        .easing = spec.easing,
        .liquid = spec.liquid,
        .from = .{ r.x, r.y, from_w, from_h },
        .to = .{ spec.x, spec.y, spec.w, spec.h },
        .to_readability = to_readability,
        .to_emphasis = to_emphasis,
        .to_variant = to_variant,
    };
    root.markRenderDirty();
    markGlassSurfaceDirty(state);
}

fn lerpColor(a: Color, b: Color, t: f32) Color {
    return .{
        .r = @intFromFloat(lerp(@floatFromInt(a.r), @floatFromInt(b.r), t)),
        .g = @intFromFloat(lerp(@floatFromInt(a.g), @floatFromInt(b.g), t)),
        .b = @intFromFloat(lerp(@floatFromInt(a.b), @floatFromInt(b.b), t)),
        .a = @intFromFloat(lerp(@floatFromInt(a.a), @floatFromInt(b.a), t)),
    };
}

/// Glass parameter-field transition: ResolvedGlassBoxStyle at both ends is interpolated field by
/// field (f32 linear +
/// Color channel interpolation; enum shapes switch at t=0.5).
fn lerpGlassBoxStyle(a: ResolvedGlassBoxStyle, b: ResolvedGlassBoxStyle, t: f32) ResolvedGlassBoxStyle {
    var out = if (t < 0.5) a else b;
    out.background = lerpColor(a.background, b.background, t);
    out.border_color = lerpColor(a.border_color, b.border_color, t);
    out.shadow = .{
        .color = lerpColor(a.shadow.color, b.shadow.color, t),
        .blur = lerp(a.shadow.blur, b.shadow.blur, t),
        .offset_x = lerp(a.shadow.offset_x, b.shadow.offset_x, t),
        .offset_y = lerp(a.shadow.offset_y, b.shadow.offset_y, t),
    };
    var g = out.glass;
    inline for (@import("zenit_reflection").fields(core.GlassParams)) |f| {
        if (f.type == f32) {
            @field(g, f.name) = lerp(@field(a.glass, f.name), @field(b.glass, f.name), t);
        }
    }
    g.glass_tint = lerpColor(a.glass.glass_tint orelse Color.rgba(255, 255, 255, 0), b.glass.glass_tint orelse Color.rgba(255, 255, 255, 0), t);
    if (a.glass.base_veil != null and b.glass.base_veil != null) g.base_veil = lerpColor(a.glass.base_veil.?, b.glass.base_veil.?, t);
    // A transfer curve on either side: interpolate knots, the other side as its affine line
    // (e.g. a morph across the compact size).
    if (a.glass.veil_curve != null or b.glass.veil_curve != null) {
        const ca = a.glass.veil_curve orelse affineVeilCurve(a.glass);
        const cb = b.glass.veil_curve orelse affineVeilCurve(b.glass);
        var c: [17]f32 = undefined;
        for (&c, ca, cb) |*o, x, y| o.* = lerp(x, y, t);
        g.veil_curve = c;
    }
    out.glass = g;
    return out;
}

pub const ResolvedGlassBoxStyle = struct {
    background: Color,
    border_color: Color,
    shadow: Shadow,
    glass: core.GlassParams,
};

pub const AdaptiveGlassBoxState = struct {
    allocator: Allocator,
    cx: *Cx,
    surface: *Node,
    content: *Node,
    theme_tokens: *const theme.ThemeTokens,
    /// Measured platform profile (idiom) this glass renders with.
    profile: *const GlassProfile = &profile.macos,
    radius: f32,
    readability: GlassBoxReadability,
    emphasis: GlassBoxEmphasis,
    variant: GlassEffectStyle = .regular,
    shape: ?GlassBoxShape = null,
    enabled: bool = true,
    tint_override: ?Color,
    last_width: f32 = -1,
    last_height: f32 = -1,
    last_style: ?ResolvedGlassBoxStyle = null,
    // interactive state (hover/press)
    interactive: bool = false,
    press_feedback: GlassPressFeedback = .none,
    /// glassEffectUnion key (0 = not part of a union)
    union_key: u32 = 0,
    /// Popover arrow (encoding of types.GlassParams.arrow) and whether it casts a shadow
    arrow: [4]f32 = .{ 0, 0, 0, 0 },
    drop_shadow: bool = true,
    material: GlassMaterial = .standard,
    lens_variant: LensVariant = .tab,
    lens_key_matrix: [12]f32 = @as([12]f32, @splat(0)),
    blur_radius: f32 = 0,
    /// Shadow strength scale (glassSetShadowScale; the knob fades in the glass-state shadow by how
    /// much white covers it)
    shadow_scale: f32 = 1,
    /// corner radius TL/TR/BR/BL for `.concentric` shape (null = uniform radius)
    corner_radii: ?[4]f32 = null,
    /// boost interpolation suspended surface render cache (converged frame restores and
    /// re-records).
    boost_cache_suppressed: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    /// externally-maintained pressed appearance (glassSetHeld: keep button pressed during menu
    /// open)
    held: bool = false,
    /// Externally driven body shift (sRGB 0-1, see GlassParams.press_offset); null = none. The
    /// iOS pressed tab bar platter brightens by +11 (205 -> 216 over gray 128, light family).
    press_offset_override: ?f32 = null,
    /// current animation interpolation (0 = idle, 0.5 = hover target, 1.0 = press target)
    glass_boost: f32 = 0,
    boost_event_pending: bool = false,
    // scroll-edge: scroll-position-driven edge intensity (with interpolation)
    scroll_edge: ?ScrollEdgeBinding = null,
    edge_strength: f32 = 0,
    // morph: geometry + glass parameter field transition
    morph: ?MorphState = null,
    /// GlassGroup.transact matched geometry insert/remove (mutually exclusive with morph)
    matched: ?MatchedState = null,
    /// when used as matched source: pulse start point (-1 = none), and equidistant outward
    /// expansion amount written to shape table this frame
    pulse_start_ms: f64 = -1,
    pulse_clock: TransactionClock = .{},
    pulse_time_scale: f64 = 1,
    /// earlier pulse not yet complete, interrupted by new transact: take max with current pulse,
    /// don't restart (see startPulse)
    pulse_prev: [2]?PulsePrev = .{ null, null },
    group_dilate: f32 = 0,
    /// materialize transition (glassSetEnabled): level 1 = fully formed, 0 = completely dispersed
    transition: GlassTransition = .materialize,
    materialize: ?MaterializeState = null,
    materialize_level: f32 = 1.0,
    /// The content fades with materialize_level: set for container members that a transaction
    /// inserts or removes (the view enters / leaves the hierarchy). Plain glassEffect(isEnabled:)
    /// keeps its content when the glass switches off, so this is off by default. Once set it stays:
    /// a member that transactions insert / remove is not also an isEnabled-style toggle.
    content_follows_presence: bool = false,
    /// Glass parameters this frame, before materialize modulation (container-shared source)
    group_shared_glass: ?types.GlassParams = null,
    root: ?*Node = null,
    // Backdrop luminance auto-adapt: smoothed luminance reading (null = disabled, fall back to
    // theme approximation)
    live_luminance: ?f32 = null,
    /// Own background sRGB uniform luminance (0..1), drives native light/dark family flip
    live_luminance_srgb: ?f32 = null,
    /// Native adaptive family: small elements flip based on background (see adaptiveFamilyStep),
    /// new effect starts light; large elements and clear/tinted fixed by appearance
    family_dark: bool = false,
    /// Short side the light/dark family decision uses (small glass adapts to its backdrop, large
    /// glass keeps the appearance family). Null = the live rect. A control whose glass grows while
    /// pressed (the iOS tab bar platter: 62 -> 65 pt, across the 64 pt limit) pins its rest size,
    /// so the press never flips the family.
    family_extent: ?f32 = null,
    /// Whether the glass took part in the adaptive family last frame (regular, untinted).
    family_adaptive: bool = true,
    /// Family transition factor (0 = light, 1 = dark): family_dark is the determined target,
    /// spring-tracked here (familyMixStep). Style parsing and content ink interpolate between
    /// families.
    family_mix: f32 = 0,
    family_mix_vel: f32 = 0,
    /// Transition settle frame: last step snaps factor to endpoint, still needs re-parsing this
    /// frame
    family_mix_settle: bool = false,
    /// Initial wait after family target changes (seconds, see family_to_dark_delay_s)
    family_hold_s: f32 = 0,
    /// Fresh effect (native_family_fresh.swift): a new adaptive glass is drawn from its first
    /// frame in the appearance family and switches to its backdrop's family ~150 ms (to dark) /
    /// ~207 ms (to light) after it first appears, with the usual crossfade springs (light
    /// appearance over gray 31 reads 215 -> 26). While `family_probe` is set the hook waits for
    /// the first luminance reading and that onset; the glass stays visible meanwhile.
    family_probe: bool = true,
    family_probe_start_ms: f64 = -1,
    family_probe_frames: u8 = 0,
    /// First time truly encoded by render backend (-1 = never drawn): timeout starts here
    family_probe_encoded_ms: f64 = -1,
    /// Content ink family transition factor (spring-tracked, see family_ink_to_dark_response_s)
    family_ink_mix: f32 = 0,
    family_ink_vel: f32 = 0,
    family_ink_hold_s: f32 = 0,
    family_ink_settle: bool = false,
    /// Content vibrancy (L4): when family switches, title/subtitle flip with glass brightness
    title_node: ?*Node = null,
    subtitle_node: ?*Node = null,
    /// GlassGroup member mode (M2): geometry/material into container surface shape table, self
    /// doesn't draw glass
    group: ?*GlassGroupLink = null,
    group_index: u8 = 0,
    last_rel_x: f32 = 0,
    last_rel_y: f32 = 0,
};

/// When container liquid fusion activates (product decision): `.transitions` = spacing enabled only
/// during member morph/move/materialize transitions, decays to 0 when static - adjacent shapes
/// don't mutually attract in stable layout; `.always` = native GlassEffectContainer static behavior
/// (Lab/control); `.never` = union only by overlap.
pub const GlassMergeMode = enum { transitions, always, never };
/// Duration to hold fusion after transition ends (ms), then decay starts
pub const merge_hold_ms: f64 = 150;

/// Link between GlassGroup and members (held by GlassGroupState, stable address)
pub const GlassGroupLink = struct {
    allocator: Allocator,
    container: *Node,
    /// Container glass surface: holds ext.glass (member 0 material + shape table pointer)
    surface: *Node,
    table: *types.GlassGroupShapes,
    /// Member interpolation bitmap -> container surface disable_render_cache
    anim_mask: u8 = 0,
    /// Container state still alive. freeNodeNow disposes node own scope first then children, member
    /// cleanup happens after GlassGroupState destroyed: link independently allocated, freed by last
    /// party
    alive: bool = true,
    attached: u8 = 0,
    /// Members registered by slot (enterGroupMode/exitGroupMode), GlassGroup.transact uses it to
    /// find matched geometry source element
    members: [8]?*AdaptiveGlassBoxState = @splat(null),
    /// Liquid fusion switch state (see GlassMergeMode/tickGroupMerge)
    merge_mode: GlassMergeMode = .transitions,
    base_spacing: f32 = 0,
    merge_strength: f32 = 0,
    /// This frame transition fusion max radius k/spacing contribution, motion_tick_ms marks frame
    motion_accum: f32 = 0,
    /// This frame morph-driven adhesion strength (max over transitioning members
    /// clamp(sqrt(1-s)/0.3))
    morph_strength: f32 = 0,
    motion_tick_ms: f64 = -1,
    last_motion_ms: f64 = -1.0e9,
    merge_tick_ms: f64 = -1,

    /// Container releases when idle; freed immediately without members
    pub fn releaseFromGroup(self: *GlassGroupLink) void {
        self.alive = false;
        if (self.attached == 0) self.allocator.destroy(self);
    }
};

fn markGlassSurfaceDirty(state: *AdaptiveGlassBoxState) void {
    state.surface.markRenderDirty();
    if (state.group) |g| g.surface.markRenderDirty();
}

fn setGlassCacheSuppressed(state: *AdaptiveGlassBoxState, on: bool) void {
    state.surface.frame_state.state_bits.flags.disable_render_cache = on;
    if (state.group) |g| {
        const bit: u8 = @as(u8, 1) << @intCast(@min(state.group_index, 7));
        if (on) g.anim_mask |= bit else g.anim_mask &= ~bit;
        g.surface.frame_state.state_bits.flags.disable_render_cache = g.anim_mask != 0;
    }
}

fn groupPositionChanged(state: *AdaptiveGlassBoxState, node: *Node) bool {
    const g = state.group orelse return false;
    const r = node.globalRect();
    const c = g.container.globalRect();
    return @abs((r.x - c.x) - state.last_rel_x) > 0.25 or @abs((r.y - c.y) - state.last_rel_y) > 0.25;
}

/// Transitioning member contributes remaining progress sqrt(1-s) to owner group (max this frame).
/// Morph-driven adhesion strength: remaining r = sqrt(1-s) at full strength when r >= 0.3 (s <=
/// 0.91), then continuous decay with spring tail to 0. Adhesion thus syncs with morph settle, no
/// separate hold+decay after animation ends (would freeze endpoint sharp tip then suddenly shrink).
pub const morph_merge_fade_r: f32 = 0.3;

/// Transitioning member contributes transition fusion radius morph_transition_k*sqrt(1-s) (spacing
/// units) to owner group (max this frame), syncs adhesion strength. s is "geometry progress to
/// fused state": split = morph progress, join = 1 - morph progress.
fn groupNoteTransition(state: *AdaptiveGlassBoxState, s: f32) void {
    const g = state.group orelse return;
    const r: f32 = @sqrt(std.math.clamp(1.0 - s, 0.0, 1.0));
    g.morph_strength = @max(g.morph_strength, std.math.clamp(r / morph_merge_fade_r, 0.0, 1.0));
    groupNoteK(g, morph_transition_k * r);
}

/// This frame transition fusion radius (spacing units, max of member contributions)
fn groupNoteK(g: *GlassGroupLink, k_per_spacing: f32) void {
    if (k_per_spacing > g.motion_accum) {
        g.motion_accum = k_per_spacing;
        g.table.motion = k_per_spacing;
    }
    writeGroupBlend(g);
}

fn writeGroupBlend(g: *GlassGroupLink) void {
    const eff: f32 = switch (g.merge_mode) {
        .always => 1.0,
        .never => 0.0,
        .transitions => @max(g.merge_strength, g.morph_strength),
    };
    if (g.table.blend != eff or g.table.spacing != g.base_spacing * eff) {
        g.table.spacing = g.base_spacing * eff;
        g.table.blend = eff; // static union: no edge bulge at overlap seam
    }
    g.table.version +%= 1;
    g.surface.markRenderDirty();
}

/// Each frame (in any member hook) advance container fusion strength. Morph driven by progress
/// directly (groupNoteTransition); other motion (drag position change, materialize) uses time
/// envelope: moving -> 1 (80ms), static merge_hold_ms then -> 0 (300ms decay). Strength directly
/// scales shape table spacing and blend.
fn tickGroupMerge(state: *AdaptiveGlassBoxState, node: *Node, dt: f32) void {
    const g = state.group orelse return;
    const now = state.cx.frame_time_ms;
    // Non-morph motion (drag position, materialize) uses time envelope; morph driven by progress
    // (groupNoteTransition). First table write doesn't count as motion (position baseline undefined
    // when last_style empty).
    const moving = state.materialize != null or (state.morph == null and state.last_style != null and groupPositionChanged(state, node));
    if (moving) g.last_motion_ms = now;
    if (g.motion_tick_ms != now) {
        // New frame: previous frame accumulation consumed by render, reset then re-accumulated by
        // this frame morphing members
        g.motion_tick_ms = now;
        if (g.motion_accum != 0 or g.table.motion != 0 or g.morph_strength != 0 or g.table.continuous) {
            g.motion_accum = 0;
            g.table.motion = 0;
            g.morph_strength = 0;
            g.table.continuous = false;
            writeGroupBlend(g);
        }
    }
    if (g.merge_tick_ms == now) return; // already advanced this frame by another member
    g.merge_tick_ms = now;
    const target: f32 = if (g.merge_mode == .transitions and now - g.last_motion_ms < merge_hold_ms) 1.0 else 0.0;
    if (@abs(target - g.merge_strength) < 0.001) {
        // Keep requesting frames during hold period (target still 1): idle frame gating has no one
        // requesting next frame, decay never advances, static state stays adhesive (sharp
        // endpoint).
        if (g.merge_mode == .transitions and g.merge_strength > 0) state.cx.needs_redraw = true;
        return;
    }
    const step_dt = @max(dt, 1.0 / 60.0);
    g.merge_strength = if (target > g.merge_strength)
        @min(g.merge_strength + step_dt / 0.08, 1.0)
    else
        @max(g.merge_strength - step_dt / 0.3, 0.0);
    writeGroupBlend(g);
    state.cx.needs_redraw = true;
}

/// GlassGroup member: switch to container surface shape table. Called after mount, before first
/// frame.
pub fn enterGroupMode(state: *AdaptiveGlassBoxState, link: *GlassGroupLink, index: u8) void {
    state.group = link;
    state.group_index = index;
    link.attached += 1;
    if (index < link.members.len) link.members[index] = state;
    state.last_style = null;
    const ext = state.surface.style.ensureExtFallible(state.allocator) catch return;
    ext.glass = null;
    state.surface.setBackgroundRaw(Color.rgba(0, 0, 0, 0));
    state.surface.style.border = .{ .overlay = true, .width = 0, .color = Color.rgba(0, 0, 0, 0), .radius = state.radius };
    markGlassSurfaceDirty(state);
}

/// Member unregister (called at state cleanup): clear own shape slot and interpolation position,
/// just release link if container already dismantled
pub fn exitGroupMode(state: *AdaptiveGlassBoxState) void {
    const g = state.group orelse return;
    state.group = null;
    g.attached -|= 1;
    if (!g.alive) {
        if (g.attached == 0) g.allocator.destroy(g);
        return;
    }
    const idx: usize = state.group_index;
    if (idx < g.table.shapes.len) g.table.shapes[idx] = .{};
    if (idx < g.members.len and g.members[idx] == state) g.members[idx] = null;
    // If other member uses this member as matched source, source disappears then settle immediately
    for (g.members) |mo| if (mo) |o| {
        if (o.matched) |mm| if (mm.source_index == state.group_index) finishMatched(o);
    };
    var count: u8 = 0;
    for (g.table.shapes, 0..) |sh, k| {
        if (sh.node_id != std.math.maxInt(u32)) count = @intCast(k + 1);
    }
    g.table.count = count;
    g.table.version +%= 1;
    const bit: u8 = @as(u8, 1) << @intCast(@min(state.group_index, 7));
    g.anim_mask &= ~bit;
    g.surface.frame_state.state_bits.flags.disable_render_cache = g.anim_mask != 0;
    g.surface.markRenderDirty();
}

/// Content follows glass brightness flip: use light text on dark family. clear always white text
/// (caller doesn't pass).
fn applyContentVibrancy(state: *AdaptiveGlassBoxState) void {
    if (state.title_node) |n| if (n.getText()) |t0| {
        var t = t0;
        t.color = familyInk(state, glassTitleStyle(state.theme_tokens).color, Color.WHITE);
        n.setText(t);
    };
    if (state.subtitle_node) |n| if (n.getText()) |t0| {
        var t = t0;
        t.color = familyInk(state, glassSubtitleStyle(state.theme_tokens).color, Color.WHITE.withAlpha(204));
        n.setText(t);
    };
}

/// First-frame probe timeout: need enough frames and enough time (readback waits prior frame
/// command buffer, measured 3-5 frames). Milliseconds only: sparse frames (idle gating) clock jumps
/// timeout before reading consumed; frame count only: forced continuous frames (screenshot) faster
/// than GPU, frame count exhausted first. Timeout shows by appearance family.
pub const family_probe_max_frames: u8 = 8;
pub const family_probe_max_ms: f64 = 250;

/// One step of family transition (critical damping spring analytical solution, exact per dt,
/// frame-rate independent). Returns true = still transitioning.
pub fn familyMixStep(fam: *const profile.FamilyParams, mix: *f32, vel: *f32, dark: bool, dt: f32) bool {
    return springStep(mix, vel, dark, if (dark) fam.to_dark_response_s else fam.to_light_response_s, dt);
}

/// Content ink family transition one step (see family_ink_to_dark_response_s)
pub fn familyInkMixStep(fam: *const profile.FamilyParams, mix: *f32, vel: *f32, dark: bool, dt: f32) bool {
    return springStep(mix, vel, dark, if (dark) fam.ink_to_dark_response_s else fam.ink_to_light_response_s, dt);
}

fn springStep(mix: *f32, vel: *f32, dark: bool, response: f32, dt: f32) bool {
    const target: f32 = if (dark) 1 else 0;
    const x0 = mix.* - target;
    if (@abs(x0) < 1e-3 and @abs(vel.*) < 1e-2) {
        mix.* = target;
        vel.* = 0;
        return false;
    }
    const w = 2.0 * std.math.pi / response;
    const e = @exp(-w * dt);
    const c = vel.* + w * x0;
    mix.* = target + (x0 + c * dt) * e;
    vel.* = (vel.* - w * c * dt) * e;
    mix.* = std.math.clamp(mix.*, 0, 1);
    return true;
}

fn familyExtent(state: *const AdaptiveGlassBoxState, rr: anytype) f32 {
    return state.family_extent orelse @min(rr.w, rr.h);
}

/// Pin the short side the light/dark family decision uses (see `family_extent`); null = live rect.
pub fn glassSetFamilyExtent(state: *AdaptiveGlassBoxState, extent: ?f32) void {
    state.family_extent = extent;
}

/// Jump to family immediately (no transition): new scene/test use
pub fn glassSetFamilyImmediate(state: *AdaptiveGlassBoxState, dark: bool) void {
    state.family_dark = dark;
    state.family_mix = if (dark) 1 else 0;
    state.family_mix_vel = 0;
    state.family_hold_s = 0;
    state.family_ink_mix = state.family_mix;
    state.family_ink_vel = 0;
    state.family_ink_hold_s = 0;
    applyContentVibrancy(state);
    state.last_style = null;
}

/// Style between families interpolated by transition factor: static state is single-parse of
/// corresponding family
fn familyStyle(state: *const AdaptiveGlassBoxState, readability: GlassBoxReadability, emphasis: GlassBoxEmphasis, variant: GlassEffectStyle, tint: ?Color, w: f32, h: f32) ResolvedGlassBoxStyle {
    // Adaptive glass renders the tracked family explicitly (in dark appearance a compact element
    // over a bright backdrop is light). Clear / tinted glass has no light family: its tracked
    // family only decays from dark toward the appearance (e.g. after morphing out of a dark
    // regular family), so its endpoints are the appearance and dark.
    const adaptive = adaptsFamily(&state.profile.family, variant, state.tint_override != null);
    const light_end: MaterialFamily = if (adaptive) .light else .appearance;
    const m = state.family_mix;
    if (m <= 0) return resolvedGlassBoxStyle(state.profile, state.theme_tokens, readability, emphasis, variant, tint, w, h, state.radius, state.live_luminance, light_end);
    if (m >= 1) return resolvedGlassBoxStyle(state.profile, state.theme_tokens, readability, emphasis, variant, tint, w, h, state.radius, state.live_luminance, .dark);
    const light = resolvedGlassBoxStyle(state.profile, state.theme_tokens, readability, emphasis, variant, tint, w, h, state.radius, state.live_luminance, light_end);
    const dark = resolvedGlassBoxStyle(state.profile, state.theme_tokens, readability, emphasis, variant, tint, w, h, state.radius, state.live_luminance, .dark);
    return lerpGlassBoxStyle(light, dark, m);
}

/// Glass content ink interpolation between families (text/icons self-color with spring during
/// family transition)
pub fn familyInk(state: *const AdaptiveGlassBoxState, light: Color, dark: Color) Color {
    return lerpColor(light, dark, state.family_ink_mix);
}

/// One-step family decision (pure function for unit testing): returns new family_dark.
/// appearance_dark = current appearance is dark. Large regular doesn't adapt, fixed to appearance
/// family (dark appearance 320x200 panel on white reads 84 = dark family).
/// Whether glass takes part in the adaptive light/dark family: regular, and untinted unless the
/// profile's tinted glass flips too (iOS).
pub fn adaptsFamily(fam: *const profile.FamilyParams, style: GlassEffectStyle, tinted: bool) bool {
    return style == .regular and (!tinted or fam.tinted_adapts);
}

pub fn adaptiveFamilyStep(fam: *const profile.FamilyParams, family_dark: bool, min_dim: f32, variant: GlassEffectStyle, tinted: bool, lum_srgb: ?f32, appearance_dark: bool) bool {
    if (!adaptsFamily(fam, variant, tinted)) return false;
    if (min_dim > fam.flip_max_dim) return appearance_dark;
    const l = lum_srgb orelse return family_dark;
    if (appearance_dark) {
        if (family_dark and l > fam.dark_appearance_enter_light_luma) return false;
        if (!family_dark and l < fam.dark_appearance_exit_light_luma) return true;
        return family_dark;
    }
    if (!family_dark and l < fam.enter_dark_luma) return true;
    if (family_dark and l > fam.exit_dark_luma) return false;
    return family_dark;
}

pub const MorphSpec = struct {
    /// Target geometry (root absolute inset position; caller ensures root absolute)
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// Target glass profile (null = keep current)
    readability: ?GlassBoxReadability = null,
    emphasis: ?GlassBoxEmphasis = null,
    glass_style: ?GlassEffectStyle = null,
    /// Duration in 60Hz frames; actual progress by elapsed time, 18 = 300ms
    frames: u32 = 18,
    /// Direct millisecond duration (takes priority over frames)
    duration_ms: ?f64 = null,
    /// Easing: smoothstep (default) or SwiftUI `.smooth(duration:)` (zero-bounce spring, omega =
    /// 2*pi/duration, x(t) = 1 - (1 + omega*t)*e^(-omega*t), settle when residual < 0.05px, see
    /// springSettleFactor).
    easing: MorphEasing = .smoothstep,
    /// Liquid direction in container: `.split` from fused to separate (remaining progress
    /// sqrt(1-s), adhesion strongest at start), `.join` separate to fused (sqrt(s), same neck
    /// geometry under same state as split, mirror image), `.none` no transition fusion radius
    /// (GlassGroup.transact members moving with layout).
    liquid: MorphLiquid = .split,
    /// Explicit start (null = use root current layout rect). Pass when member real geometry
    /// available: members absorbed back to the endpoint cap can legitimately shrink to near-zero
    /// size, but the layout rect's 'not yet laid out' fallback (220x140) would mistake that valid
    /// zero size for the default.
    from: ?[4]f32 = null,
};

pub const MorphEasing = enum { smoothstep, spring_smooth };
pub const MorphLiquid = enum { split, join, none };

const MaterializeState = struct {
    start_time_ms: f64,
    transaction_clock: TransactionClock = .{},
    duration_ms: f64,
    from: f32,
    to: f32,
};

/// `glassEffect(isEnabled:)` runtime switch. transition == .materialize modulates material by
/// measured curve (disappear to bottom then switch to identity), else immediate switch.
pub fn glassSetEnabled(state: *AdaptiveGlassBoxState, enabled: bool) void {
    const target: f32 = if (enabled) 1.0 else 0.0;
    if (state.transition != .materialize) {
        state.enabled = enabled;
        state.materialize = null;
        state.materialize_level = target;
    } else {
        const cur = state.materialize_level;
        if (state.materialize) |m| {
            if (m.to == target) return; // same-direction repeat: don't reset clock
        } else if (state.enabled == enabled and @abs(cur - target) < 0.001) return;
        if (enabled) state.enabled = true; // disappear keeps enabled, switch to identity after bottom
        // mid-transition reverse: recalc duration from remaining travel, avoid half-progress
        // full-duration slowdown
        const base = if (enabled) state.profile.materialize.appear_ms else state.profile.materialize.disappear_ms;
        state.materialize = .{
            .start_time_ms = state.cx.eventTimeMs(),
            .duration_ms = base * @max(@as(f64, @floatCast(@abs(target - cur))), 0.05),
            .from = cur,
            .to = target,
        };
    }
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
    state.cx.needs_redraw = true;
}

/// Luma of transfer-curve knot k (backdrop gray 16k).
fn curveKnotLuma(k: usize) f32 {
    return @as(f32, @floatFromInt(k)) * 16.0 / 255.0;
}

/// The affine veil blend of `g` as a transfer curve (sRGB 0-1 at the knot lumas), including the
/// backdrop gain before the veil. The surface veil is `base_veil` when present (partial tint).
fn affineVeilCurve(g: core.GlassParams) [17]f32 {
    const v = g.base_veil orelse g.glass_tint orelse Color.rgba(255, 255, 255, 0);
    const a: f32 = @as(f32, @floatFromInt(v.a)) / 255.0;
    const veil: f32 = @as(f32, @floatFromInt(v.r)) / 255.0;
    var out: [17]f32 = undefined;
    for (&out, 0..) |*o, i| o.* = veil * a + g.backdrop_brightness * curveKnotLuma(i) * (1.0 - a);
    return out;
}

/// materialize amount m applied to parsed style: layer/stroke/shadow alpha, rim, lens, blur
/// component and chroma aperture converge to "no material"; m = 1 is identity.
fn applyMaterializeLevel(r: *ResolvedGlassBoxStyle, m: f32) void {
    r.background.a = alphaU8(@as(f32, @floatFromInt(r.background.a)) * m);
    r.border_color.a = alphaU8(@as(f32, @floatFromInt(r.border_color.a)) * m);
    r.shadow.color.a = alphaU8(@as(f32, @floatFromInt(r.shadow.color.a)) * m);
    if (r.glass.glass_tint) |*t| t.a = alphaU8(@as(f32, @floatFromInt(t.a)) * m);
    if (r.glass.base_veil) |*t| t.a = alphaU8(@as(f32, @floatFromInt(t.a)) * m);
    // a transfer curve fades toward the identity (no coating) like the veil alpha
    if (r.glass.veil_curve) |*c| for (c, 0..) |*v, i| {
        v.* = lerp(curveKnotLuma(i), v.*, m);
    };
    r.glass.specular_opacity *= m;
    r.glass.refraction_level *= m;
    r.glass.blur_level *= m;
    r.glass.native_fine_weight = lerp(1.0, r.glass.native_fine_weight, m);
    r.glass.native_coarse_weight *= m;
    r.glass.native_chroma_fine = lerp(1.0, r.glass.native_chroma_fine, m);
    r.glass.native_chroma_coarse *= m;
    r.glass.backdrop_saturation = lerp(1.0, r.glass.backdrop_saturation, m);
    r.glass.backdrop_brightness = lerp(1.0, r.glass.backdrop_brightness, m);
    // Tab lens: its rim, glows, dark line and displacement fade with it (otherwise they stay at
    // full strength until the lens switches off and vanish in one frame). knob_rim_dark[3] (1
    // when shown) is the level the shader scales the whole displacement field by; the fold
    // geometry (tab_lens) stays as measured - shrinking it pins the band to the contour row.
    if (r.glass.tab_lens[0] > 0) {
        r.glass.knob_rim_light[2] *= m;
        r.glass.knob_rim_light[3] *= m;
        r.glass.knob_rim_dark[0] *= m;
        r.glass.knob_rim_dark[3] *= m;
    }
}

const MorphState = struct {
    t: f32 = 0,
    start_time_ms: f64,
    transaction_clock: TransactionClock = .{},
    duration_ms: f64,
    from: [4]f32, // x,y,w,h
    to: [4]f32,
    to_readability: GlassBoxReadability,
    to_emphasis: GlassBoxEmphasis,
    to_variant: GlassEffectStyle,
    easing: MorphEasing = .smoothstep,
    liquid: MorphLiquid = .split,
    /// .spring_smooth spring duration (duration_ms is settle time, derived from residual, see
    /// springSettleFactor)
    spring_base_ms: f64 = 0,
};

/// Spring settle factor: residual (1+x)*e^(-x)*displacement <= 0.05px time / duration (x =
/// 2*pi*t/duration). Fixed 1.15x settle spring only reaches 99.44%, 300px displacement ends with
/// 1.7px final-frame jump.
pub fn springSettleFactor(travel: f32) f64 {
    const tr: f64 = @max(travel, 0.05);
    var x: f64 = 2 * std.math.pi;
    while ((1 + x) * @exp(-x) * tr > 0.05 and x < 40) x += 0.05;
    return x / (2 * std.math.pi);
}

fn morphTravel(a: [4]f32, b: [4]f32) f32 {
    var m: f32 = 0;
    for (a, b) |p, q| m = @max(m, @abs(q - p));
    return m;
}

/// Morph (glassMorphTo .split/.join) transition fusion radius: k = morph_transition_k*S*sqrt(1-s)
/// (union id switch native bar separation frame-fitted).
pub const morph_transition_k: f32 = 2.0;

// -- matched geometry insert/remove (Apple: GlassEffectContainer adds/removes elements with
// glassEffectID + withAnimation). Native frame-fit (native_expand_collapse.swift: pencil/eraser
// example + toolbar + card; scripts/glass_native_model/fit_expand_collapse.py + measure_pulse.py):
//  - default withAnimation = .smooth(0.5) (first edge residual 0.2px);
//  - insert: from source toward its endpoint cap center, position spring (delay 0.16s, 0.25s);
//    size from 0, length along departure direction (0.05s, 0.30s), thickness (0.10s, 0.40s):
//    stretch long first, then thicken, thin tail;
//    remove: position (0.05s, 0.4s) back to cap center, length (0.05s, 0.5s), thickness
//    (0.05s, 0.3s) shrinking to 0: thin first, then shorten;
//  - transition fusion radius k = 0.75*S (insert) / 0.5*S (remove);
//  - source expands equidistantly outward by delta = (sigma(t) - 1)*short_edge/2, sigma is the
//    measured pulse (same both directions, peak 1.22 @0.2s, valley 0.963 @0.45s, back at 0.85s).
//    Durations scale by duration/0.5.

pub const matched_insert_k: f32 = 0.75;
pub const matched_remove_k: f32 = 0.5;
/// Common startup delay for all springs when removing (normalized seconds)
pub const matched_remove_delay_s: f64 = 0.05;
/// Settle point under normalized duration (baseline 0.5s): all springs residual < 0.05% (insert
/// slowest thickness 0.10 + 0.40s, remove slowest length 0.05 + 0.50s), no more visible jump at
/// settle.
pub const matched_insert_end_s: f64 = 0.80;
pub const matched_remove_end_s: f64 = 0.90;
/// Source element pulse sigma(t), t = 0, 0.025, ..., 0.85s (baseline 0.5s animation)
pub const matched_pulse = [_]f32{
    1.0000, 1.0012, 1.0159, 1.0434, 1.0937, 1.1460, 1.1905, 1.2144, 1.2227, 1.2110, 1.1793,
    1.1376, 1.0907, 1.0481, 1.0158, 0.9909, 0.9742, 0.9663, 0.9627, 0.9633, 0.9704, 0.9765,
    0.9846, 0.9904, 0.9965, 0.9998, 1.0019, 1.0038, 1.0052, 1.0074, 1.0081, 1.0077, 1.0069,
    1.0030, 1.0000,
};
pub const matched_pulse_step_s: f64 = 0.025;

pub fn matchedPulse(t_s: f64) f32 {
    if (t_s <= 0) return 1;
    const f = t_s / matched_pulse_step_s;
    const i: usize = @intFromFloat(@floor(f));
    if (i + 1 >= matched_pulse.len) return 1;
    const u: f32 = @floatCast(f - @as(f64, @floatFromInt(i)));
    return lerp(matched_pulse[i], matched_pulse[i + 1], u);
}
pub const matched_pulse_end_s: f64 = matched_pulse_step_s * @as(f64, @floatFromInt(matched_pulse.len - 1));

pub const MatchedKind = enum { insert, remove };
pub const MatchedState = struct {
    kind: MatchedKind,
    source_index: u8,
    start_time_ms: f64,
    transaction_clock: TransactionClock = .{},
    /// Normalization coefficient: baseline 0.5s / actual duration
    time_scale: f64 = 1,
    /// insert = final rect, remove = start rect (container local, root inset coordinates)
    rect: [4]f32,
    /// Interrupt prior matched fusion coefficient: transition from it to this type k, no jump (see
    /// matchedK)
    k_from: ?f32 = null,
    /// Start offset of normalized progress (seconds). Transaction clock from first show frame, skip
    /// initial delay only by adding here
    tn_offset: f64 = 0,
};

fn matchedKindK(kind: MatchedKind) f32 {
    return if (kind == .insert) matched_insert_k else matched_remove_k;
}

/// This frame fusion coefficient. Insert mid-reverse if k jumps from 0.75 to 0.5, union bulge at
/// overlap collapses (screen 51->44px re-bulges); native reverse bulge continuous. Transition along
/// remove thickness spring (0.05, 0.3).
fn matchedK(mm: MatchedState, tn: f64) f32 {
    const k = matchedKindK(mm.kind);
    const from = mm.k_from orelse return k;
    return lerp(from, k, springSmooth(tn - matched_remove_delay_s, 0.3));
}

/// Source element endpoint cap center: clamp target center to source rect skeleton after own radius
/// inset (capsule = long-axis segment, circle = center, rounded card = rect inset r - native card
/// child bar along own row pulls horizontal from card edge).
pub fn matchedAnchor(src: [4]f32, radius: f32, cx: f32, cy: f32) [2]f32 {
    const m = std.math.clamp(radius, 0, @min(src[2], src[3]) / 2);
    return .{
        std.math.clamp(cx, src[0] + m, src[0] + src[2] - m),
        std.math.clamp(cy, src[1] + m, src[1] + src[3] - m),
    };
}

/// Matched member geometry at normalized time tn (baseline 0.5s): {x, y, w, h}
pub fn matchedRect(kind: MatchedKind, rect: [4]f32, src: [4]f32, src_radius: f32, tn: f64) [4]f32 {
    const cx = rect[0] + rect[2] / 2;
    const cy = rect[1] + rect[3] / 2;
    const a = matchedAnchor(src, src_radius, cx, cy);
    var q: f32 = undefined;
    var g_len: f32 = undefined;
    var g_thk: f32 = undefined;
    switch (kind) {
        .insert => {
            // Position (0.02, 0.50) slow, length (0.02, 0.25) fast: anchor past source final cap,
            // frame-fit Zenit actual fusion distance (screen gap ~4.5pt when neck breaks) against
            // native default withAnimation expand (native_glass_scenarios.swift tb24/tb24b,
            // perimeter + break time joint). Members fusing native individual tracks unobserved,
            // only perimeter/break time measurable; old (0.06, 0.35)/(0.06, 0.30) fit assumed 20pt
            // fusion distance, break too early c/b @0.21/0.40s (native 0.30/0.35-0.40), new
            // 0.33/0.45s, 0.25s mid-reverse no premature break then reabsorb. Position can't
            // precede length: else new element flies from source while still short, isolated dot.
            q = springSmooth(tn - 0.02, 0.50);
            g_len = springSmooth(tn - 0.02, 0.25);
            g_thk = springSmooth(tn - 0.10, 0.40);
        },
        .remove => {
            q = 1 - springSmooth(tn - matched_remove_delay_s, 0.4);
            g_len = 1 - springSmooth(tn - matched_remove_delay_s, 0.5);
            g_thk = 1 - springSmooth(tn - matched_remove_delay_s, 0.3);
        },
    }
    // Length direction = anchor -> target center main axis (horizontal when expanding horizontally)
    const horizontal = @abs(cx - a[0]) >= @abs(cy - a[1]);
    const px = lerp(a[0], cx, q);
    const py = lerp(a[1], cy, q);
    const w = rect[2] * (if (horizontal) g_len else g_thk);
    const h = rect[3] * (if (horizontal) g_thk else g_len);
    return .{ px - w / 2, py - h / 2, w, h };
}

/// Member current rect (container local; last shape-table write layout result, no pulse expansion).
pub fn memberRect(s: *const AdaptiveGlassBoxState) [4]f32 {
    return .{ s.last_rel_x, s.last_rel_y, @max(s.last_width, 0), @max(s.last_height, 0) };
}

/// Member current specified geometry: root latest write inset + width/height (px), rect painted
/// next frame. memberRect is hook read from prior frame layout, one frame late - transaction just
/// placed member at source cap, hasn't run a frame yet, still old pre-hide geometry; using it as
/// reabsorb/reverse start one-frame jumps. Non-px geometry (members never placed via glassPlace) falls back
/// to memberRect.
pub fn memberGeometry(s: *const AdaptiveGlassBoxState) [4]f32 {
    const root = s.root orelse return memberRect(s);
    const ext = root.style.ext orelse return memberRect(s);
    const l = switch (ext.inset.left) {
        .px => |v| v,
        else => return memberRect(s),
    };
    const t = switch (ext.inset.top) {
        .px => |v| v,
        else => return memberRect(s),
    };
    const w = switch (root.style.width) {
        .px => |v| v,
        else => return memberRect(s),
    };
    const h = switch (root.style.height) {
        .px => |v| v,
        else => return memberRect(s),
    };
    return .{ l, t, @max(w, 0), @max(h, 0) };
}

/// Member final rect: while morphing use morph target, else use current. Insert animation anchors
/// to source **final** cap: anchoring current shrinking cap, new element centered there, protrudes
/// shrinking source, union perimeter rebounds 919->930->900px (screen frame-by-frame); native
/// expand perimeter single V (native_expand_collapse.swift toolbar).
pub fn memberFinalRect(s: *const AdaptiveGlassBoxState) [4]f32 {
    if (s.morph) |m| return m.to;
    return memberRect(s);
}

/// Place member geometry directly (root absolute inset + width/height), no animation.
pub fn glassPlace(state: *AdaptiveGlassBoxState, r: [4]f32) void {
    const root = state.root orelse return;
    setMemberGeometry(state, root, r);
    state.last_rel_x = r[0];
    state.last_rel_y = r[1];
    state.last_width = r[2];
    state.last_height = r[3];
    state.last_style = null;
    root.markRenderDirty();
    markGlassSurfaceDirty(state);
}

/// Show/hide immediately (no materialize), for initial state.
pub fn glassSetEnabledImmediate(state: *AdaptiveGlassBoxState, enabled: bool) void {
    state.enabled = enabled;
    state.materialize = null;
    state.materialize_level = if (enabled) 1 else 0;
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
    state.cx.needs_redraw = true;
}

/// Initial presence of a container member that a later transaction inserts or removes: an absent
/// member shows neither glass nor content (the view is not in the hierarchy yet).
pub fn glassSetPresentImmediate(state: *AdaptiveGlassBoxState, present: bool) void {
    state.content_follows_presence = true;
    glassSetEnabledImmediate(state, present);
}

/// Drive the materialization level directly (0 = absent, 1 = full glass), for glass whose presence
/// follows a gesture rather than a timed transition (the iOS tab selection lens).
pub fn glassSetMaterializeLevel(state: *AdaptiveGlassBoxState, level: f32) void {
    const l = std.math.clamp(level, 0, 1);
    const enabled = l > 0.001;
    if (state.materialize == null and state.enabled == enabled and @abs(state.materialize_level - l) < 1e-4) return;
    state.enabled = enabled;
    state.materialize = null;
    state.materialize_level = l;
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
}

/// Externally hold pressed appearance (`.glass_button` press feedback): native Menu trigger button
/// stays pressed while menu open (native_menu_morph.swift menu), release waits for menu close.
/// Drive the body shift directly (sRGB 0-1; null = none), e.g. a pressed bar platter.
pub fn glassSetPressOffset(state: *AdaptiveGlassBoxState, offset: ?f32) void {
    const same = (state.press_offset_override == null and offset == null) or
        (state.press_offset_override != null and offset != null and @abs(state.press_offset_override.? - offset.?) < 1e-4);
    if (same) return;
    state.press_offset_override = offset;
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
}

pub fn glassSetHeld(state: *AdaptiveGlassBoxState, held: bool) void {
    if (state.held == held) return;
    state.held = held;
    markGlassSurfaceDirty(state);
}

/// Member in geometry/visibility transition (morph/matched/materialize). Source pulse just visual
/// echo, not counted: pulse longer than morph, counting would eat next interaction. Shadow strength
/// ratio (0..1): knob static white capsule self-shadowed, glass state shadow fades in as white
/// fades.
pub fn glassSetShadowScale(state: *AdaptiveGlassBoxState, scale: f32) void {
    if (@abs(state.shadow_scale - scale) < 1e-4) return;
    state.shadow_scale = scale;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
}

pub fn glassIsAnimating(state: *const AdaptiveGlassBoxState) bool {
    return state.morph != null or state.matched != null or state.materialize != null;
}

fn setMemberGeometry(state: *AdaptiveGlassBoxState, node: *Node, r: [4]f32) void {
    node.style.width = .{ .px = r[2] };
    node.style.height = .{ .px = r[3] };
    const ext = node.style.ensureExtFallible(state.allocator) catch return;
    ext.inset = .{ .left = .{ .px = r[0] }, .top = .{ .px = r[1] } };
    node.markSizingDirty();
    node.markLayoutDirty();
    state.radius = shapeRadius(state.shape, state.radius, r[2], r[3]);
}

/// Start matched insert (internal to transact): member immediately enabled (no materialize),
/// geometry each frame by hook tracking source real rect.
pub fn startMatchedInsert(state: *AdaptiveGlassBoxState, source: *AdaptiveGlassBoxState, final: [4]f32, duration_ms: f64) void {
    state.morph = null;
    state.materialize = null;
    state.enabled = true;
    state.materialize_level = 1;
    state.matched = .{ .kind = .insert, .source_index = source.group_index, .start_time_ms = state.cx.eventTimeMs(), .time_scale = 500.0 / @max(duration_ms, 1), .rect = final };
    if (state.root) |root| setMemberGeometry(state, root, matchedRect(.insert, final, memberFinalRect(source), source.radius, 0));
    startPulse(source, duration_ms);
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
    state.cx.needs_redraw = true;
}

/// Start matched remove: reabsorb from current rect to source element, hide after settle
/// (identity).
pub fn startMatchedRemove(state: *AdaptiveGlassBoxState, source: *AdaptiveGlassBoxState, duration_ms: f64) void {
    const start = memberGeometry(state);
    // Insert mid-reverse: record this moment fusion coefficient
    const k_from: ?f32 = if (state.matched) |prev| blk: {
        var clock = prev.transaction_clock;
        const tn = clock.elapsed(prev.start_time_ms, state.cx.frame_time_ms, null) / 1000.0 * prev.time_scale + prev.tn_offset;
        break :blk matchedK(prev, tn);
    } else null;
    state.morph = null;
    state.materialize = null;
    state.matched = .{ .kind = .remove, .source_index = source.group_index, .start_time_ms = state.cx.eventTimeMs(), .time_scale = 500.0 / @max(duration_ms, 1), .rect = start, .k_from = k_from };
    // Mid-reverse doesn't consume remove spring startup delay (0.05s fitted from static close):
    // member freezes ~5 frames (screen right edge 4 frames static). Native resize mid-reverse only
    // display delay, speed clears then reverses immediately.
    if (k_from != null) state.matched.?.tn_offset = matched_remove_delay_s;
    startPulse(source, duration_ms);
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
    state.cx.needs_redraw = true;
}

/// Interrupted pulse: keep its transaction clock advancing - same display sample as current pulse,
/// same idle-skip-frame semantics (same frame forced redraw doesn't advance pose), two don't offset
/// each other.
pub const PulsePrev = struct {
    start_ms: f64,
    clock: TransactionClock,
    time_scale: f64,
};

/// Source element pulse (bow). Mid-reverse etc interrupt, native doesn't reset pulse to 0: old
/// pulse completes, new starts from 0, take max - 0.158s reverse height stays at peak 55 until
/// ~0.30s drops, 0.257s reverse first drops to 49 then new pulse rises to 53
/// (native_glass_scenarios.swift toolbar_rev15/25). Restart one-frame height 52->44 re-bow (screen
/// measured reverse stutter). Re-insert while reabsorbing (quick reverse): spring from current rect
/// to target, member visible. Don't call startMatchedInsert - resets to source cap (one-frame
/// jump).
pub fn reverseMatchedRemove(state: *AdaptiveGlassBoxState, source: ?*AdaptiveGlassBoxState, final: [4]f32, duration_ms: f64) void {
    state.matched = null;
    setGlassCacheSuppressed(state, false);
    state.materialize = null;
    state.enabled = true;
    state.materialize_level = 1;
    // start = screen geometry now: absorbed near cap edge width/height ~0, must grow from here
    glassMorphTo(state, .{ .x = final[0], .y = final[1], .w = final[2], .h = final[3], .duration_ms = duration_ms, .easing = .spring_smooth, .liquid = .none, .from = memberGeometry(state) });
    if (source) |src| startPulse(src, duration_ms);
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
    state.cx.needs_redraw = true;
}

fn startPulse(source: *AdaptiveGlassBoxState, duration_ms: f64) void {
    const now = source.cx.eventTimeMs();
    // Once per insert/remove per transaction: eventTimeMs real-time wall clock, second call start
    // slightly before now, but pulse hasn't walked any frame (progress 0) - only already-walked
    // pulse counts as interrupted, else just-saved old pulse overwritten as progress 0 (mid-reverse
    // pulse one-frame zero, instrumented 4.19->0).
    if (source.pulse_start_ms >= 0) {
        var probe = source.pulse_clock;
        const el = probe.elapsed(source.pulse_start_ms, source.cx.frame_time_ms, null) / 1000.0 * source.pulse_time_scale;
        if (el > 1e-3 and el < matched_pulse_end_s) {
            // Quick re-tap multiple pulses concurrent: two slots, replace oldest when full (closest
            // to end, least impact)
            const prev = PulsePrev{ .start_ms = source.pulse_start_ms, .clock = source.pulse_clock, .time_scale = source.pulse_time_scale };
            var slot: usize = 0;
            for (source.pulse_prev, 0..) |p, i| {
                if (p == null) {
                    slot = i;
                    break;
                }
                if (p.?.start_ms < source.pulse_prev[slot].?.start_ms) slot = i;
            }
            source.pulse_prev[slot] = prev;
        }
    }
    source.pulse_start_ms = now;
    source.pulse_clock = .{};
    source.pulse_time_scale = 500.0 / @max(duration_ms, 1);
    source.last_style = null;
    source.cx.needs_redraw = true;
}

fn finishMatched(state: *AdaptiveGlassBoxState) void {
    const mm = state.matched orelse return;
    state.matched = null;
    setGlassCacheSuppressed(state, false);
    switch (mm.kind) {
        .insert => if (state.root) |root| setMemberGeometry(state, root, mm.rect),
        .remove => {
            // Reabsorb complete: hide (identity, zero-size entry), geometry left at source cap
            state.enabled = false;
            state.materialize_level = 0;
        },
    }
    state.last_style = null;
    if (state.root) |root| root.markRenderDirty();
    markGlassSurfaceDirty(state);
    state.cx.needs_redraw = true;
}

/// Hook each frame advance: matched geometry + source pulse. Return true = frame needs forced
/// shape-table rewrite.
fn tickMatched(state: *AdaptiveGlassBoxState, node: *Node) bool {
    var dirty = false;
    if (state.pulse_start_ms >= 0) {
        const el = state.pulse_clock.elapsed(state.pulse_start_ms, state.cx.frame_time_ms, state.cx.frame_presentation_sample) / 1000.0 * state.pulse_time_scale;
        var level = matchedPulse(@max(el, 0));
        var running = el < matched_pulse_end_s;
        for (&state.pulse_prev) |*slot| {
            if (slot.*) |*prev| {
                // advance by pointer: elapsed updates internal clock state, must write back to slot
                const prev_el = prev.clock.elapsed(prev.start_ms, state.cx.frame_time_ms, state.cx.frame_presentation_sample) / 1000.0 * prev.time_scale;
                if (prev_el < matched_pulse_end_s) {
                    level = @max(level, matchedPulse(@max(prev_el, 0)));
                    running = true;
                } else slot.* = null; // curve tail reaches 1.0, expired discard no jump
            }
        }
        if (!running) {
            state.pulse_start_ms = -1;
            state.pulse_prev = .{ null, null };
            state.group_dilate = 0;
        } else {
            const w = if (state.last_width > 0) state.last_width else 0;
            const h = if (state.last_height > 0) state.last_height else 0;
            state.group_dilate = (level - 1) * @min(w, h) / 2;
            state.cx.needs_redraw = true;
        }
        dirty = true;
    }
    if (state.matched) |*mm| {
        const g = state.group orelse {
            finishMatched(state);
            return true;
        };
        const src = if (mm.source_index < g.members.len) g.members[mm.source_index] else null;
        const s = src orelse {
            finishMatched(state);
            return true;
        };
        const elapsed_ms = mm.transaction_clock.elapsed(mm.start_time_ms, state.cx.frame_time_ms, state.cx.frame_presentation_sample);
        const tn = elapsed_ms / 1000.0 * mm.time_scale + mm.tn_offset;
        if (tn >= (if (mm.kind == .insert) matched_insert_end_s else matched_remove_end_s)) {
            finishMatched(state);
            return true;
        }
        setGlassCacheSuppressed(state, true);
        // insert anchor at source final cap; remove reabsorbed to source current cap (follows
        // source)
        const src_rect = if (mm.kind == .insert) memberFinalRect(s) else memberRect(s);
        setMemberGeometry(state, node, matchedRect(mm.kind, mm.rect, src_rect, s.radius, tn));
        groupNoteK(g, matchedK(mm.*, tn));
        g.morph_strength = 1;
        writeGroupBlend(g);
        state.cx.needs_redraw = true;
        dirty = true;
    }
    return dirty;
}

/// SwiftUI Spring(duration:, bounce: 0) position curve (critically damped, omega = 2*pi/duration)
pub fn springSmooth(t_seconds: f64, duration_seconds: f64) f32 {
    const w = 2.0 * std.math.pi / @max(duration_seconds, 1e-3);
    const x = w * @max(t_seconds, 0.0);
    return @floatCast(1.0 - (1.0 + x) * @exp(-x));
}

/// interactive: events only flip state bit + mark dirty; parameter convergence in before_render
/// (animating)
fn interactiveGlassEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .mouse_enter => {
            state.hovered = true;
        },
        .mouse_leave => {
            state.hovered = false;
            state.pressed = false;
        },
        .mouse_down => {
            state.pressed = true;
        },
        .mouse_up => {
            state.pressed = false;
        },
        else => return .ignored,
    }
    state.boost_event_pending = true;
    markGlassSurfaceDirty(state);
    return .ignored; // don't consume events: buttons in content still respond normally
}

/// scroll-edge blur gradient stops: edge fully blurred (1), fade_width fades back to glass own
/// base_blur_level, **cannot** fade to 0.
///
/// stop strength is absolute blur_level (0 = pure sharp). Previously 1 -> 0, glass strip outside
/// fade band judged full sharp: on scroll glass below sharp text shows through (2026-09-29 user
/// report GlassMotion scroll-edge "blur lost after scroll"). scroll-edge adds edge blur **on top
/// of** glass base, doesn't remove glass own frosting.
pub fn scrollEdgeStops(fade_width: f32, extent: f32, base_blur_level: f32) [2]core.BlurGradient.Stop {
    const fade_end = clampf(fade_width / @max(extent, 1), 0, 1);
    return .{
        .{ .pos = 0, .strength = 1 },
        .{ .pos = fade_end, .strength = clampf(base_blur_level, 0, 1) },
    };
}

/// shape -> current size corner radius (capsule/circle half short edge)
pub fn shapeRadius(shape: ?GlassBoxShape, fallback: f32, w: f32, h: f32) f32 {
    const sh = shape orelse return fallback;
    return switch (sh) {
        .capsule, .circle => @max(@min(w, h) * 0.5, 0),
        .rounded => |r| @max(r, 0),
        // concentric radii per frame by container (concentricRadii); here just upper bound for
        // uniform path
        .concentric => fallback,
    };
}

fn glassBoxBeforeRender(node: *Node) void {
    const raw = node.meta.per_frame.hooks.slots.anim_state orelse return;
    const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(raw));
    var effective_variant: GlassEffectStyle = if (state.enabled) state.variant else .identity;
    // true frame interval: all advances here exact for any step (solve spring, exponential
    // response, clamped ramp)
    const dt = @max(state.cx.frame_dt_seconds, 0);
    state.theme_tokens = state.cx.tokens;
    tickGroupMerge(state, node, dt);
    if (tickMatched(state, node)) state.last_style = null;
    if (state.group) |g| {
        if (state.morph != null or state.matched != null or state.materialize != null or state.pulse_start_ms >= 0) {
            if (!g.table.continuous) {
                g.table.continuous = true;
                g.table.version +%= 1;
                g.surface.markRenderDirty();
            }
        }
    }

    // backdrop luminance adapt: measured luminance (1 frame lag) smoothed by interpolation drives
    // parameter field (avoid frame-by-frame readback noise-caused flicker). Fall back to theme
    // approximation with no reading.
    var param_interp_active = false;
    // per-glass luminance: match own background measured value precisely by surface node id (slot
    // key = owner node id, stable across scroll/layout), no match fall back to global average. Each
    // glass adapts **own** background: panel background scrolls with panel, luminance naturally
    // unchanging; prior global single value swung with viewport content - all switch
    // appearance/fade.
    const measured_lum: ?f32 = blk: {
        for (state.cx.backdrop_luminance_regions[0..state.cx.backdrop_luminance_region_count]) |reg| {
            if (reg.node_id == state.surface.id) break :blk reg.lum;
        }
        break :blk state.cx.backdrop_luminance;
    };
    state.live_luminance_srgb = blk: {
        for (state.cx.backdrop_luminance_regions[0..state.cx.backdrop_luminance_region_count]) |reg| {
            if (reg.node_id == state.surface.id) break :blk reg.lum_srgb;
        }
        break :blk state.live_luminance_srgb;
    };
    probe: {
        if (!state.family_probe) break :probe;
        const rr = node.rectFromWorldOrFallback();
        const eligible = state.enabled and adaptsFamily(&state.profile.family, state.variant, state.tint_override != null) and
            familyExtent(state, rr) <= state.profile.family.flip_max_dim and state.cx.backdrop_luminance_readback;
        const now = state.cx.frame_time_ms;
        if (state.family_probe_start_ms < 0) {
            if (!eligible) {
                state.family_probe = false;
                break :probe;
            }
            state.family_probe_start_ms = now;
        }
        // timeout only from glass first truly drawn (encoded backplate, has background sample):
        // clipped/unlaidout/hidden glass unseen anyway, wait until really appears, first reading
        // lands correct family (else timeout shows by appearance, transition after appearing)
        if (state.family_probe_encoded_ms < 0) {
            const owner = if (state.group) |g| g.surface.id else state.surface.id;
            for (state.cx.glass_encoded_owners[0..state.cx.glass_encoded_count]) |id| if (id == owner) {
                state.family_probe_encoded_ms = now;
                break;
            };
        }
        // Frames are needed only while a drawn glass waits for its reading. A glass that is not
        // drawn (hidden, clipped, an empty notification viewport's pill) must not keep the window
        // rendering: the frame that first draws it asks for the next one (the renderer wakes on
        // newly encoded glass), which picks the probe up from here.
        if (state.family_probe_encoded_ms >= 0) state.cx.needs_redraw = true;
        if (state.family_probe_encoded_ms >= 0) state.family_probe_frames +|= 1;
        const timed_out = state.family_probe_frames > family_probe_max_frames and now - state.family_probe_encoded_ms > family_probe_max_ms;
        if (eligible and state.live_luminance_srgb == null and !timed_out) break :probe;
        // Reading arrived (or no longer applies / timed out): from here the regular adaptive path
        // runs. A family switch starts on the native fresh-effect schedule, counted from the
        // first frame the glass was drawn.
        const stats = &state.cx.glass_probe_stats;
        if (eligible) {
            if (state.live_luminance_srgb != null) stats.resolved +|= 1 else stats.timed_out +|= 1;
            stats.max_frames = @max(stats.max_frames, state.family_probe_frames);
        }
        if (state.live_luminance_srgb != null and eligible) {
            const fam = &state.profile.family;
            const next_dark = adaptiveFamilyStep(fam, state.family_dark, familyExtent(state, rr), state.variant, false, state.live_luminance_srgb, state.theme_tokens.scheme == .dark);
            if (next_dark != state.family_dark) {
                const shown_s: f32 = if (state.family_probe_encoded_ms >= 0) @floatCast((now - state.family_probe_encoded_ms) / 1000.0) else 0;
                const fresh = (if (next_dark) fam.fresh_to_dark_delay_s else fam.fresh_to_light_delay_s) - shown_s;
                const glass_delay = if (next_dark) fam.to_dark_delay_s else fam.to_light_delay_s;
                const ink_delay = if (next_dark) fam.ink_to_dark_delay_s else fam.ink_to_light_delay_s;
                state.family_dark = next_dark;
                state.family_hold_s = @max(fresh, glass_delay);
                state.family_ink_hold_s = @max(fresh + ink_delay - glass_delay, ink_delay);
            }
        }
        state.family_probe = false;
    }
    if (!state.family_probe) {
        const rr = node.rectFromWorldOrFallback();
        // Becoming adaptive again (tint cleared, morphed back to regular) is a fresh effect: it
        // starts in the appearance family (native_family_fresh.swift) instead of the light end
        // its decayed non-adaptive family would otherwise snap to.
        const adaptive_now = adaptsFamily(&state.profile.family, state.variant, state.tint_override != null);
        if (adaptive_now and !state.family_adaptive) glassSetFamilyImmediate(state, state.theme_tokens.scheme == .dark);
        state.family_adaptive = adaptive_now;
        const next_dark = adaptiveFamilyStep(&state.profile.family, state.family_dark, familyExtent(state, rr), state.variant, state.tint_override != null, state.live_luminance_srgb, state.theme_tokens.scheme == .dark);
        if (next_dark != state.family_dark) {
            state.family_hold_s = if (next_dark) state.profile.family.to_dark_delay_s else state.profile.family.to_light_delay_s;
            state.family_ink_hold_s = if (next_dark) state.profile.family.ink_to_dark_delay_s else state.profile.family.ink_to_light_delay_s;
        }
        state.family_dark = next_dark;
        const target: f32 = if (state.family_dark) 1 else 0;
        // family transition: wait startup delay first (maintain same, keep framing), then
        // spring-chase target, re-parse each frame. When startup delay ends within frame, remainder
        // advances spring (no wasted frame on long frame).
        const family_dt = holdRemainder(&state.family_hold_s, dt);
        if (state.family_hold_s > 0) {
            state.cx.needs_redraw = true;
        } else if (familyMixStep(&state.profile.family, &state.family_mix, &state.family_mix_vel, state.family_dark, family_dt) or state.family_mix_settle) {
            state.family_mix_settle = state.family_mix != target;
            state.last_style = null;
            param_interp_active = true;
            markGlassSurfaceDirty(state);
            node.markRenderDirty();
        }
        // content ink: own delay and spring
        const ink_dt = holdRemainder(&state.family_ink_hold_s, dt);
        if (state.family_ink_hold_s > 0) {
            state.cx.needs_redraw = true;
        } else if (familyInkMixStep(&state.profile.family, &state.family_ink_mix, &state.family_ink_vel, state.family_dark, ink_dt) or state.family_ink_settle) {
            state.family_ink_settle = state.family_ink_mix != target;
            applyContentVibrancy(state);
            state.cx.needs_redraw = true;
            node.markRenderDirty();
        }
    }
    if (measured_lum) |target_lum| {
        const cur = state.live_luminance orelse target_lum;
        const diff = target_lum - cur;
        if (@abs(diff) > 0.004) {
            state.live_luminance = cur + diff * materialResponse(0.15, dt);
            param_interp_active = true;
            markGlassSurfaceDirty(state);
            node.markRenderDirty();
        } else {
            state.live_luminance = target_lum;
        }
    }
    if (@import("zenit_environment").flag("ZENIT_DEBUG_GLASS")) {
        std.debug.print("[glassbr] node={d} surf={d} measured={d:.4} live={d:.4} interp={} cache_dis={} boost={d:.2}\n", .{
            node.id,
            state.surface.id,
            measured_lum orelse -1,
            state.live_luminance orelse -1,
            param_interp_active,
            state.surface.frame_state.state_bits.flags.disable_render_cache,
            state.glass_boost,
        });
    }

    // morph: geometry interpolation + glass parameter field transition (during progress takes over
    // apply, skip normal adapt)
    if (state.morph) |*m| {
        if (@import("zenit_environment").flag("ZENIT_DEBUG_GLASS")) {
            const rr = node.rectFromWorldOrFallback();
            std.debug.print("[morph] tick t={d:.2} rect=({d:.0},{d:.0},{d:.0}x{d:.0})\n", .{ m.t, rr.x, rr.y, rr.w, rr.h });
        }
        // Display hosts sample the transaction at display targets. Poll and
        // headless hosts retain event-clock elapsed time; physics dt is separate.
        const elapsed_ms = m.transaction_clock.elapsed(m.start_time_ms, state.cx.frame_time_ms, state.cx.frame_presentation_sample);
        m.t = @floatCast(@min(elapsed_ms / m.duration_ms, 1.0));
        const t: f32 = switch (m.easing) {
            .smoothstep => m.t * m.t * (3.0 - 2.0 * m.t),
            .spring_smooth => if (m.t >= 1.0) 1.0 else springSmooth(elapsed_ms / 1000.0, m.spring_base_ms / 1000.0),
        };
        switch (m.liquid) {
            .split => groupNoteTransition(state, t),
            .join => groupNoteTransition(state, 1.0 - t),
            .none => {},
        }
        const x = lerp(m.from[0], m.to[0], t);
        const y = lerp(m.from[1], m.to[1], t);
        const w = lerp(m.from[2], m.to[2], t);
        const h = lerp(m.from[3], m.to[3], t);
        node.style.width = .{ .px = w };
        node.style.height = .{ .px = h };
        // no abort per-frame, allocation failure skip this frame retry next
        const ext = node.style.ensureExtFallible(state.allocator) catch return;
        ext.inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
        // width/height World sync follows sizing-dirty (markLayoutDirty doesn't re-read style, see
        // node_animator same handling)
        node.markSizingDirty();
        node.markLayoutDirty();
        // Resolve optical geometry and the measured backdrop for this frame.
        // Interpolating two cached endpoint styles leaves the curved coating
        // and its scattering aperture out of sync with the animated shape.
        state.radius = shapeRadius(state.shape, state.radius, w, h);
        var from_style = familyStyle(state, state.readability, state.emphasis, effective_variant, effectiveTint(state), w, h);
        var to_style = familyStyle(state, m.to_readability, m.to_emphasis, if (state.enabled) m.to_variant else .identity, effectiveTint(state), w, h);
        applyInactiveTint(state, &from_style);
        applyInactiveTint(state, &to_style);
        applyShapeExtras(state, &from_style, w, h);
        applyShapeExtras(state, &to_style, w, h);
        var style = lerpGlassBoxStyle(from_style, to_style, t);
        // Mid-morph native frames show fractional edge coverage: the shape is
        // rasterized continuously while animating, and snaps only at rest.
        style.glass.native_continuous_geometry = m.t < 1.0;
        state.group_shared_glass = style.glass;
        // OOM: this frame is skipped and the morph does not advance; the next frame retries
        applyAdaptiveGlass(node, state, style) catch return;
        if (m.t >= 1.0) {
            // transition complete: taken-over profile settled, resume normal adapt
            state.readability = m.to_readability;
            state.emphasis = m.to_emphasis;
            state.variant = m.to_variant;
            state.morph = null;
        } else {
            markGlassSurfaceDirty(state);
            node.markRenderDirty();
            state.cx.needs_redraw = true;
        }
        return;
    }

    // interactive glass response interpolation: press=1.0 > hover=0.45 > idle=0
    if (state.interactive) {
        const response_dt: f32 = if (state.boost_event_pending) 0 else dt;
        state.boost_event_pending = false;
        const target: f32 = if (state.pressed) 1.0 else if (state.hovered) 0.45 else 0.0;
        const diff = target - state.glass_boost;
        if (@abs(diff) > 0.005) {
            state.glass_boost += diff * materialResponse(0.22, response_dt);
            param_interp_active = true;
            markGlassSurfaceDirty(state); // drive next frame continue interpolating
            node.markRenderDirty();
        } else {
            state.glass_boost = target;
        }
    }
    // materialize transition: advance by display clock, level drives below-style modulation
    if (state.materialize) |*m| {
        const elapsed_ms = m.transaction_clock.elapsed(m.start_time_ms, state.cx.frame_time_ms, state.cx.frame_presentation_sample);
        const t: f32 = @floatCast(std.math.clamp(elapsed_ms / m.duration_ms, 0.0, 1.0));
        const e = t * t * (3.0 - 2.0 * t);
        state.materialize_level = m.from + (m.to - m.from) * e;
        param_interp_active = true;
        markGlassSurfaceDirty(state);
        node.markRenderDirty();
        state.cx.needs_redraw = true;
        if (t >= 1.0) {
            state.materialize_level = m.to;
            if (m.to <= 0.0) state.enabled = false;
            state.materialize = null;
            state.last_style = null;
            // dissipate to bottom this frame parse directly as identity (no extra material level=0
            // frame)
            effective_variant = if (state.enabled) state.variant else .identity;
        }
    }
    // parameter interpolation (boost/luminance adapt) during exit all render cache: glass params
    // baked into cache blur token, per-frame changing params + cross-frame cache is stale playback
    // (real hover frozen + scroll brightness jump fix root cause). Converge frame restores
    // eligibility and fresh re-record (bake settled params into cache).
    if (param_interp_active) {
        setGlassCacheSuppressed(state, true);
        state.boost_cache_suppressed = true;
    } else if (state.boost_cache_suppressed) {
        state.boost_cache_suppressed = false;
        setGlassCacheSuppressed(state, false);
        markGlassSurfaceDirty(state);
        node.markRenderDirty();
    }

    // global hook read rect
    const r = node.rectFromWorldOrFallback();
    const width = if (r.w > 0.5) r.w else 220;
    const height = if (r.h > 0.5) r.h else 140;
    state.radius = shapeRadius(state.shape, state.radius, width, height);
    if (state.shape) |sh| switch (sh) {
        .concentric => |minimum| {
            const radii = concentric_mod.concentricRadii(node, minimum);
            state.corner_radii = radii;
            state.radius = @max(@max(radii[0], radii[1]), @max(radii[2], radii[3]));
        },
        else => state.corner_radii = null,
    };
    var resolved = familyStyle(state, state.readability, state.emphasis, effective_variant, effectiveTint(state), width, height);
    applyInactiveTint(state, &resolved);
    applyShapeExtras(state, &resolved, width, height);

    // scroll-edge effect: scroll position -> target strength, smoothed interpolation into glass
    // parameters
    if (state.scroll_edge) |binding| {
        const scroll_amount = switch (binding.edge) {
            .top => binding.scroll.effectiveScrollY(),
            .bottom => binding.scroll.maxScrollY() - binding.scroll.effectiveScrollY(),
            .left => binding.scroll.effectiveScrollX(),
            .right => binding.scroll.maxScrollX() - binding.scroll.effectiveScrollX(),
        };
        const target = clampf(scroll_amount / @max(binding.ramp_distance, 1), 0, 1) * binding.max_strength;
        const diff = target - state.edge_strength;
        if (@abs(diff) > 0.005) {
            state.edge_strength += diff * materialResponse(0.25, dt);
            markGlassSurfaceDirty(state);
            node.markRenderDirty();
        } else {
            state.edge_strength = target;
        }
        // map to blur_gradient: edge=start edge -> CSS direction (top ≡ to_bottom), fade_width
        // (logical px) convert to stop percentage of node size
        const extent: f32 = switch (binding.edge) {
            .top, .bottom => height,
            .left, .right => width,
        };
        const edge_stops: [2]core.BlurGradient.Stop = if (binding.style == .hard)
            .{ .{ .pos = 0, .strength = 1 }, .{ .pos = 1, .strength = 1 } }
        else
            // A `.blur_only` layer has no glass frosting of its own to fall back to: its edge fades
            // all the way to sharp (UIScrollEdgeEffect over plain content, no bar platter).
            scrollEdgeStops(binding.fade_width, extent, if (state.material == .blur_only) 0 else resolved.glass.blur_level);
        resolved.glass.blur_gradient = (core.BlurGradient{
            .direction = switch (binding.edge) {
                .top => .to_bottom,
                .bottom => .to_top,
                .left => .to_right,
                .right => .to_left,
            },
            .strength = state.edge_strength,
        }).withStops(&edge_stops);
    }

    // press feedback: only system .glass button style (frame switch); custom interactive glass
    // native no material change
    if (state.press_feedback == .glass_button and (state.pressed or state.held)) {
        resolved.glass.press_offset = if (state.family_dark) state.profile.press.glass_button_dark else state.profile.press.glass_button_light;
    }
    if (state.press_offset_override) |o| resolved.glass.press_offset = o;

    // container shared params (blur bank/chroma aperture) from unmodulated materialize style:
    // member 0 fade can't drag group blur; member own fade done per-shape level in shader.
    state.group_shared_glass = resolved.glass;
    const level = state.materialize_level;
    if (level < 0.999) applyMaterializeLevel(&resolved, std.math.clamp(level, 0.0, 1.0));

    // Match a pressed native plain glass control's foreground response. Only content subtree fades;
    // glass stays in backdrop render pass. Opacity composites in linear light in Metal; 0.9 gives
    // recorded native foreground contrast, not much paler sRGB 0.7 blend.
    const content_opacity: f32 = if (state.interactive) 1.0 - 0.1 * std.math.clamp((state.glass_boost - 0.45) / 0.55, 0, 1) else 1.0;
    const presence: f32 = if (state.content_follows_presence) std.math.clamp(level, 0.0, 1.0) else 1.0;
    state.content.setOpacity(content_opacity * presence);

    if (@abs(width - state.last_width) <= 0.5 and
        @abs(height - state.last_height) <= 0.5 and
        state.last_style != null and
        std.meta.eql(state.last_style.?, resolved) and
        !groupPositionChanged(state, node))
    {
        return;
    }

    // OOM: nothing changed and last_style still differs, so the next frame applies it again
    applyAdaptiveGlass(node, state, resolved) catch return;
}

/// popover arrow and shadow toggle: geometry exterior is node, doesn't follow material
/// interpolation
fn applyShapeExtras(state: *const AdaptiveGlassBoxState, r: *ResolvedGlassBoxStyle, width: f32, height: f32) void {
    r.glass.arrow = state.arrow;
    if (!state.drop_shadow) r.shadow.color.a = 0;
    if (state.material == .knob_lens) {
        knobLensEnvOverride();
        const g = &r.glass;
        // lens: clear transmission (no blur, no roughness layer), refract only in narrow bezel.
        // Radius < 0.5 whole glass doesn't emit (effectiveBackdropBlurRadius); keep minimal radius,
        // blur_level=0 avoids mix
        g.backdrop_blur = 1;
        g.blur_level = 0;
        g.native_fine_sigma = 0;
        g.native_coarse_sigma = 0;
        g.native_fine_weight = 1;
        g.native_coarse_weight = 0;
        g.native_chroma_enabled = 0;
        g.backdrop_brightness = 1.0;
        g.backdrop_saturation = 1.0;
        g.tint_mode = .surface;
        g.native_tint_mode = 0;
        // sRGB layer out = 0.84*in + 28.5 (gray 128->136, 115->125, 104->116) = 178 gray 16%
        g.glass_tint = Color.rgba(178, 178, 178, @intFromFloat(@round(knob_lens.veil_alpha * 255)));
        // The lens scales with the corner radius the knob actually draws (fitted to its size, as
        // the glass shape normalises it), not the requested one: `.rounded = 9999` is a capsule.
        const h = @max(@min(state.radius, @min(width, height) / 2), 1);
        // The native knob lens is a minifying (shrinking) lens: edge pixels sample content further
        // outward (so the inner track appears smaller).
        g.refraction_level = -1;
        g.lens_bezel_px = knob_lens.bezel * h * @min(1.0, h / 15.5);
        g.lens_height_px = knob_lens.height * h;
        g.lens_base_px = knob_lens.base * h;
        g.lens_edge_blur = 0;
        // two-color rim replaces material edge: top-left dark accent line, bottom light line
        // (native_slider_toggle.swift radial profile)
        g.specular_opacity = 0;
        g.native_rim_luma = 0;
        g.knob_rim_dark = .{ 12.0 / 255.0, 72.0 / 255.0, 112.0 / 255.0, knob_lens.rim };
        g.knob_rim_light = .{ 0.15, -0.55, -0.83, 0.9 };
        // The knob is exempt from the generic accessibility material swap: under Reduce
        // Transparency it is still rendered as a lens (measured on native); under Increase
        // Contrast the two-color rim is replaced by a full-circle deep navy outline (0,10,80)
        // (native_slider_toggle.swift -increaseContrast)
        g.a11y_exempt = true;
        if (a11y_preferences.increaseContrast()) {
            g.knob_rim_dark = .{ 0, 10.0 / 255.0, 80.0 / 255.0, 1 };
            g.knob_rim_light = .{ 0, 0, 0, 1.6 }; // native rim ~1pt solid
        }
        // glass state: downward soft shadow (below -6..-7, almost none to sides)
        r.shadow = .{ .color = Color.rgba(0, 0, 0, 29), .blur = 3, .offset_x = 0, .offset_y = 2 };
    }
    if (state.material == .tab_lens) {
        const g = &r.glass;
        g.backdrop_blur = 1;
        g.blur_level = 0;
        g.native_fine_sigma = 0;
        g.native_coarse_sigma = 0;
        g.native_fine_weight = 1;
        g.native_coarse_weight = 0;
        g.native_chroma_enabled = 0;
        g.backdrop_brightness = 1.0;
        g.backdrop_saturation = 1.0;
        g.tint_mode = .surface;
        g.native_tint_mode = 0;
        g.tint_amount = 1.0;
        g.base_veil = null;
        g.veil_curve = null;
        tabLensEnvOverride();
        g.glass_tint = Color.rgba(255, 255, 255, 0);
        // The rim is the constant bright line in the shader (knob_rim_light.xy carry its value
        // and inset); no specular on top of it.
        g.specular_opacity = 0;
        g.knob_rim_light = .{ tab_lens.rim / 255.0, tab_lens.rim_inset, tab_lens.glow_top / 255.0, tab_lens.glow_bottom / 255.0 };
        g.knob_rim_dark = .{ tab_lens.dip / 255.0, tab_lens.dip_inset, tab_lens.rim_width, 1 };
        if (tab_lens.blur > 0.05) {
            g.backdrop_blur = @max(tab_lens.blur * 2, 1);
            g.blur_level = 1;
            g.native_fine_sigma = tab_lens.blur;
        }
        var curve: [17]f32 = undefined;
        // The knobs' face carries no constant offset (native interior averages 128.5 over 128,
        // shading -7 / +8 top to bottom in the shader).
        const offset: f32 = if (state.lens_variant == .tab) tab_lens.offset else 0;
        // macOS knob face: a flat coating out = 0.84 in + 28.5 (held NSSwitch: 128 -> 136, its
        // track 104 -> 116, top and bottom alike)
        const gain: f32 = if (state.lens_variant == .mac_knob) 0.84 else 1;
        const lift: f32 = if (state.lens_variant == .mac_knob) 28.5 else offset;
        for (&curve, 0..) |*k, i| k.* = std.math.clamp((@as(f32, @floatFromInt(i)) * 16.0 * gain + lift) / 255.0, 0, 1);
        g.veil_curve = curve;
        const km = state.lens_key_matrix;
        const lens_h = if (state.last_height > 0) state.last_height else 2 * state.radius;
        const kin = state.lens_variant.knobInputs(lens_h);
        g.tab_lens = @as([24]f32, @splat(0));
        g.tab_lens[0] = 1;
        g.tab_lens[1] = @floatFromInt(@backingInt(state.lens_variant));
        g.tab_lens[2] = state.lens_variant.aberrationScale(lens_h);
        @memcpy(g.tab_lens[8..12], &kin);
        @memcpy(g.tab_lens[12..24], &km);
        g.lens_edge_blur = 0;
        // The lens casts its own shadow below it (glassBackground's, see tab_lens.shadow_*). The
        // iOS knobs' is the same reach but tinted, not black: shadow_cm's offset at
        // shadow_opacity 0.1801 x shadow_face_opacity 1.08 (uniforms on CARenderer replays), the
        // control colour mixed 0.229 into gray 0.437 (switch green -> (0.384, 0.516, 0.417),
        // slider blue -> (0.337, 0.458, 0.563): both exact), barely darker than the gray around
        // it; the held NSSwitch's is the same with macOS's systemBlue (0, 122, 255).
        const sh: f32 = 1;
        const knob_shadow = struct {
            fn of(tint: [3]f32) Color {
                var c: [3]u8 = undefined;
                for (&c, tint) |*o, t| o.* = @intFromFloat(@round((0.437 + (t - 0.437) * 0.229) * 255));
                return Color.rgba(c[0], c[1], c[2], alphaU8(0.1945 * 255));
            }
        }.of;
        const scol = switch (state.lens_variant) {
            .switch_knob => knob_shadow(.{ 52.0 / 255.0, 199.0 / 255.0, 89.0 / 255.0 }),
            .slider_thumb => knob_shadow(.{ 0, 136.0 / 255.0, 1 }),
            .mac_knob => knob_shadow(.{ 0, 122.0 / 255.0, 1 }),
            .tab => Color.rgba(0, 0, 0, alphaU8(tab_lens.shadow_alpha * 255)),
        };
        if (state.drop_shadow) r.shadow = .{ .color = scol, .blur = tab_lens.shadow_blur * sh, .offset_x = 0, .offset_y = tab_lens.shadow_offset * sh, .spread = tab_lens.shadow_spread * sh };
    }
    if (state.material == .blur_only) {
        const g = &r.glass;
        g.backdrop_blur = @max(state.blur_radius, 1);
        g.blur_level = 1;
        g.native_fine_sigma = 0;
        g.native_coarse_sigma = 0;
        g.native_fine_weight = 0;
        g.native_coarse_weight = 0;
        g.native_chroma_enabled = 0;
        g.backdrop_brightness = 1;
        g.backdrop_saturation = 1;
        g.tint_mode = .surface;
        g.native_tint_mode = 0;
        g.glass_tint = Color.rgba(255, 255, 255, 0);
        g.specular_opacity = 0;
        g.native_rim_luma = 0;
        g.refraction_level = 0;
        g.lens_bezel_px = 0;
        g.lens_edge_blur = 1;
        g.capture_clamp = true;
        g.a11y_exempt = true;
        r.shadow.color.a = 0;
        r.background = Color.rgba(0, 0, 0, 0);
        r.border_color = Color.rgba(0, 0, 0, 0);
    }
    if (state.shadow_scale < 1) r.shadow.color.a = alphaU8(@as(f32, @floatFromInt(r.shadow.color.a)) * std.math.clamp(state.shadow_scale, 0, 1));
}

fn effectiveTint(state: *const AdaptiveGlassBoxState) ?Color {
    return if (state.cx.window_active) state.tint_override else null;
}

fn applyInactiveTint(state: *const AdaptiveGlassBoxState, r: *ResolvedGlassBoxStyle) void {
    if (state.cx.window_active or state.variant != .regular) return;
    // inactive window glass flattens: edge highlight and shadow disappear
    // (native_tint_backdrop.swift inactive: white edge 255/254 -> flat 242, below shadow 238->244
    // -> flat 255; gray 128 body still 230 but highlight/shadow gone; NSToolbar same - capsule on
    // 243 title bar is flat 241; dark same, see state.profile.inactive.dark_veil)
    r.glass.specular_opacity = 0;
    r.glass.native_rim_luma = 0;
    r.shadow.color.a = 0;
    // the measured inactive coatings below are affine
    r.glass.veil_curve = null;
    r.glass.backdrop_brightness = 1.0;
    if (state.family_dark) {
        // dark family only on untinted regular (adaptiveFamilyStep), chroma by veil alpha change
        // compensate
        const a0: f32 = if (r.glass.glass_tint) |t| @as(f32, @floatFromInt(t.a)) / 255.0 else 0;
        const a1: f32 = @as(f32, @floatFromInt(state.profile.inactive.dark_veil.a)) / 255.0;
        r.glass.backdrop_saturation *= (1.0 - a0) / @max(1.0 - a1, 0.05);
        r.glass.glass_tint = state.profile.inactive.dark_veil;
        return;
    }
    if (state.tint_override == null) {
        // chroma gain = saturation*(1 - veil alpha): native inactive chroma same as active,
        // compensate by alpha change
        const a0: f32 = if (r.glass.glass_tint) |t| @as(f32, @floatFromInt(t.a)) / 255.0 else 0;
        const a1: f32 = @as(f32, @floatFromInt(state.profile.inactive.plain_veil.a)) / 255.0;
        r.glass.backdrop_saturation *= (1.0 - a0) / @max(1.0 - a1, 0.05);
        r.glass.glass_tint = state.profile.inactive.plain_veil;
        return;
    }
    r.glass.glass_tint = state.profile.inactive.tint_veil;
    r.glass.backdrop_saturation = state.profile.inactive.tint_saturation;
}

/// base layer no tint {luminance, alpha}: untinted members self veil; Glass.tint members re-parse
/// no tint style same variant/family/size get veil (bridge + tint fade-out zone use it).
fn baseVeil(state: *AdaptiveGlassBoxState, resolved: ResolvedGlassBoxStyle, w: f32, h: f32) [2]f32 {
    // no tint currently applied (untinted or inactive window tint removed): parsed veil is base
    // layer
    const veil = if (effectiveTint(state) == null)
        resolved.glass.glass_tint orelse Color.rgba(247, 247, 247, 0)
    else blk: {
        const plain = familyStyle(state, state.readability, state.emphasis, state.variant, null, w, h);
        break :blk plain.glass.glass_tint orelse Color.rgba(247, 247, 247, 0);
    };
    return .{ @as(f32, @floatFromInt(veil.r)) / 255.0, @as(f32, @floatFromInt(veil.a)) / 255.0 };
}

/// Mirrors render backdrop_blur.singleRadiusShape: the popover silhouette (arrow) and the tab
/// lens carry one corner radius, so a non-uniform (concentric) request draws its largest corner.
fn singleRadiusShape(state: *const AdaptiveGlassBoxState) bool {
    return state.arrow[0] > 0.5 or state.material == .tab_lens;
}

/// The glass shape's corners as written on the surface, the content clip and the root (shadow and
/// hit shape): every one of them reads this, and the renderer fits it to each rect it evaluates.
fn glassCorners(state: *const AdaptiveGlassBoxState) CornerRadius {
    if (state.corner_radii) |r4| {
        if (!singleRadiusShape(state)) return .{ .each = r4 };
        return CornerRadius.uniform(@max(@max(r4[0], r4[1]), @max(r4[2], r4[3])));
    }
    return CornerRadius.uniform(state.radius);
}

/// The content clip follows the glass shape (capsule / circle / concentric radii change with
/// the laid-out size).
fn setContentClipExt(content: *Node, ext: *types.StyleExt, corners: CornerRadius) void {
    if (std.meta.eql(ext.corner_radius, corners)) return;
    ext.corner_radius = corners;
    content.markRenderDirty();
}

/// Apply a resolved glass style to the box (surface, content clip, root shadow; a group member
/// writes its container's shape table instead). All or nothing: every ext block it writes is
/// reserved before anything changes, so `error.OutOfMemory` leaves the box exactly as it was.
/// Mount propagates the error; the per-frame callers skip the frame, and since `last_style` was
/// not updated the next frame applies it again.
fn applyAdaptiveGlass(node: *Node, state: *AdaptiveGlassBoxState, resolved: ResolvedGlassBoxStyle) error{OutOfMemory}!void {
    const surface = state.surface;
    const ext = try surface.style.ensureExtFallible(state.allocator);
    const content_ext = try state.content.style.ensureExtFallible(state.allocator);
    const root_ext = try node.style.ensureExtFallible(state.allocator);
    if (state.group) |g| {
        const gext: ?*types.StyleExt = if (state.group_index == 0 and state.group_index < g.table.shapes.len) try g.surface.style.ensureExtFallible(state.allocator) else null;
        // member: geometry and material into container shape table; own surface doesn't draw
        // glass/background/stroke, shadow still on root (shadow only outer shape, painted after
        // container glass not darken interior).
        surface.setBackgroundRaw(Color.rgba(0, 0, 0, 0));
        surface.style.border = .{ .overlay = true, .width = 0, .color = Color.rgba(0, 0, 0, 0), .radius = state.radius };
        ext.corner_radius = CornerRadius.uniform(state.radius);
        ext.glass = null;
        setContentClipExt(state.content, content_ext, CornerRadius.uniform(state.radius));
        root_ext.corner_radius = CornerRadius.uniform(state.radius);
        // shadow by container glass pass union SDF (continuous under bridge); member own shadow
        // off.
        var member_shadow = resolved.shadow;
        member_shadow.color.a = 0;
        root_ext.setShadow(member_shadow);
        // shape table coordinates = container local: both world coordinates then subtract
        // (rectFromWorld parent-relative).
        const r = node.globalRect();
        const c = g.container.globalRect();
        const idx: usize = state.group_index;
        // identity (isEnabled false / dissipated): not composited - zero-size entry skips encoder,
        // else empty material + shared bank draws meaningless "glass".
        const identity = resolved.glass.backdrop_blur < 0.5 or r.w < 0.25 or r.h < 0.25;
        // matched source pulse: equidistant outward expand rounded rect =
        // half-width/half-height/radius all add delta
        const dl: f32 = if (identity) 0 else state.group_dilate;
        if (idx < g.table.shapes.len) {
            g.table.shapes[idx] = .{
                .node_id = surface.id,
                .x = r.x - c.x - dl,
                .y = r.y - c.y - dl,
                .w = if (identity) 0 else r.w + 2 * dl,
                .h = if (identity) 0 else r.h + 2 * dl,
                .radius = state.radius + dl,
                .shadow_alpha = @as(f32, @floatFromInt(resolved.shadow.color.a)) / 255.0,
                .shadow_blur = resolved.shadow.blur,
                .shadow_offset_x = resolved.shadow.offset_x,
                .shadow_offset_y = resolved.shadow.offset_y,
                .level = std.math.clamp(state.materialize_level, 0.0, 1.0),
                .base_veil = baseVeil(state, resolved, r.w, r.h),
                .press_offset = resolved.glass.press_offset,
                .union_key = state.union_key,
                .capsule = if (state.shape) |sh| (sh == .capsule or sh == .circle) else true,
                .material = resolved.glass.resolve(),
            };
            if (g.table.count < idx + 1) g.table.count = @intCast(idx + 1);
            g.table.version +%= 1;
            if (gext) |shared| {
                // shared items (blur bank, chroma aperture) from member 0 material
                var gp = state.group_shared_glass orelse resolved.glass;
                gp.group = g.table;
                shared.glass = gp;
            }
        }
        state.last_style = resolved;
        state.last_width = r.w;
        state.last_height = r.h;
        state.last_rel_x = r.x - c.x;
        state.last_rel_y = r.y - c.y;
        // root shadow / corner radius changed with the style: the root's own content too
        // (descendants_cache_safe contract).
        node.markRenderDirty();
        markGlassSurfaceDirty(state);
        return;
    }
    surface.setBackgroundRaw(resolved.background);
    surface.style.border = .{
        .overlay = true,
        .width = 1,
        .color = resolved.border_color,
        .radius = state.radius,
    };

    const corners = glassCorners(state);
    ext.corner_radius = corners;
    ext.glass = resolved.glass;
    setContentClipExt(state.content, content_ext, corners);
    // shadow on root wrapper: glass node with shadow triggers rect subdivide (see mountBody
    // comment)
    root_ext.corner_radius = corners;
    root_ext.setShadow(resolved.shadow);
    // intentional no micro-scale: any non-1 scale makes root go opacity-layer offscreen composite,
    // backdrop_blur glass in offscreen surface can't sample background -> hover entire panel
    // (blur+children) vanishes leaving shell (measured; same nav lens "glass+scale" taboo note).
    // Interaction response all via glass parameters (specular/intensity/thickness/warp), await
    // framework support glass in scaled surface then restore 1.2% micro-scale.

    state.last_style = resolved;
    // global hook read rect
    const r = node.rectFromWorldOrFallback();
    state.last_width = r.w;
    state.last_height = r.h;
    node.markRenderDirty();
    markGlassSurfaceDirty(state);
}

/// Signed Gaussian mixture measured with gray DC and four-phase frequencies.
/// Sigma is in logical pixels, weights sum to one including the main kernel.
/// The wide component explains broad contrast; compact controls have a small
/// negative wide weight (native local contrast enhancement).
pub const NativeBlur = struct {
    radius: f32,
    sharp_mix: f32,
    fine_sigma: f32 = 0,
    main_grid_mix: f32 = 0,
    coarse_sigma: f32 = 0,
    coarse_weight: f32 = 0,
    fine_slope: f32 = 0,
    fine_curve: f32 = 0,
    coarse_slope: f32 = 0,
    coarse_curve: f32 = 0,
};
pub fn nativeBlur(is_clear: bool, min_dim: f32) NativeBlur {
    return nativeBlurFamily(is_clear, min_dim, false);
}
pub fn nativeBlurFamily(is_clear: bool, min_dim: f32, dark: bool) NativeBlur {
    if (is_clear) return .{ .radius = 2.149, .sharp_mix = 0.11298 };
    const table = [_]struct { dim: f32, sigma: f32, fine_sigma: f32, fine: f32, coarse: f32, fine_slope: f32, fine_curve: f32, coarse_slope: f32, coarse_curve: f32 }{
        .{ .dim = 32, .sigma = 4.496000, .fine_sigma = 1.000000, .fine = 0.44187369, .coarse = -0.10634060, .fine_slope = -0.58007467, .fine_curve = 0.19408245, .coarse_slope = -0.04772887, .coarse_curve = 0.03427527 },
        .{ .dim = 48, .sigma = 4.524000, .fine_sigma = 1.000000, .fine = 0.43988596, .coarse = -0.10654877, .fine_slope = -0.55630535, .fine_curve = 0.17975651, .coarse_slope = -0.06276999, .coarse_curve = 0.04571329 },
        .{ .dim = 64, .sigma = 4.463463, .fine_sigma = 1.000000, .fine = 0.27497810, .coarse = -0.11051825, .fine_slope = -0.48621559, .fine_curve = 0.09839720, .coarse_slope = 0.01850038, .coarse_curve = -0.01521667 },
        .{ .dim = 96, .sigma = 4.414000, .fine_sigma = 1.000000, .fine = 0.00009766, .coarse = 0.02002460, .fine_slope = -0.54120691, .fine_curve = 0.09908004, .coarse_slope = 0.05941081, .coarse_curve = -0.04337703 },
        .{ .dim = 104, .sigma = 5.84, .fine_sigma = 3.8, .fine = 0.53549905, .coarse = 0.06743336, .fine_slope = -0.55106, .fine_curve = 0.04923, .coarse_slope = -0.1276, .coarse_curve = 0.03370 },
        .{ .dim = 128, .sigma = 8.922000, .fine_sigma = 4.500000, .fine = 0.53338668, .coarse = 0.15189589, .fine_slope = -0.57303269, .fine_curve = -0.10084536, .coarse_slope = -0.24985305, .coarse_curve = 0.14564667 },
        .{ .dim = 160, .sigma = 8.862000, .fine_sigma = 4.000000, .fine = 0.17082834, .coarse = 0.28185299, .fine_slope = -0.82032039, .fine_curve = 0.16609869, .coarse_slope = 0.00427626, .coarse_curve = 0.02280313 },
        .{ .dim = 200, .sigma = 8.956000, .fine_sigma = 4.000000, .fine = 0.18317229, .coarse = 0.27740166, .fine_slope = -0.70110064, .fine_curve = 0.07415678, .coarse_slope = -0.07928387, .coarse_curve = 0.08006954 },
        .{ .dim = 240, .sigma = 9.060000, .fine_sigma = 4.000000, .fine = 0.17446625, .coarse = 0.28093857, .fine_slope = -0.70110064, .fine_curve = 0.07415678, .coarse_slope = -0.07928387, .coarse_curve = 0.08006954 },
        .{ .dim = 320, .sigma = 11.000000, .fine_sigma = 4.000000, .fine = 0.19651271, .coarse = 0.20131523, .fine_slope = -0.43148690, .fine_curve = -0.13330020, .coarse_slope = -0.13562423, .coarse_curve = 0.06946584 },
    };
    var hi: usize = 0;
    while (hi + 1 < table.len and min_dim > table[hi].dim) : (hi += 1) {}
    const lo = hi -| 1;
    const t = if (hi == lo) 0 else norm01(min_dim - table[lo].dim, 0, table[hi].dim - table[lo].dim);
    var result = NativeBlur{
        .radius = lerp(table[lo].sigma, table[hi].sigma, t),
        // Grid4 at64 and grid8 at96/104/128 are separately measured. The
        // transition is continuous; beyond128 the old large bank is retained
        // pending independent large-size alias identification.
        .main_grid_mix = norm01(min_dim - 64, 0, 32) * (1.0 - norm01(min_dim - 128, 0, 32)),
        .sharp_mix = lerp(table[lo].fine, table[hi].fine, t),
        .fine_sigma = lerp(table[lo].fine_sigma, table[hi].fine_sigma, t),
        // Off-panel gray/color surrounds, with local/DC gains frozen from
        // independent MTF, identify this radius at 128.5 logical px. All
        // other surrounds and an 80px margin are held out (RMSE .65 RGB).
        .coarse_sigma = lerp(192, 128.5, norm01(min_dim - 64, 0, 96)),
        .coarse_weight = lerp(table[lo].coarse, table[hi].coarse, t),
    };
    // Source-space aperture profiles, measured independently of the lens.
    // Anchor each polynomial at rho=1 to the nine-frequency center fit.
    const size_t = norm01(min_dim - 64, 0, 96);
    if (dark) {
        const gain = lerp(0.21, 0.30, size_t);
        result.radius = lerp(4.502, 8.012, size_t);
        result.fine_sigma = lerp(1, 3.5, size_t);
        result.sharp_mix = lerp(0.0544294185, 0.0182902624, size_t) / gain;
        result.coarse_weight = lerp(-0.0057280019, 0.1873908347, size_t) / gain;
        result.fine_slope = lerp(-0.06774951, -0.10969245, size_t) / gain;
        result.fine_curve = lerp(-0.00017697, 0.01995505, size_t) / gain;
        result.coarse_slope = lerp(-0.00058243, 0.00977234, size_t) / gain;
        result.coarse_curve = lerp(-0.00138261, 0.00421494, size_t) / gain;
    } else {
        result.fine_slope = lerp(table[lo].fine_slope, table[hi].fine_slope, t);
        result.fine_curve = lerp(table[lo].fine_curve, table[hi].fine_curve, t);
        result.coarse_slope = lerp(table[lo].coarse_slope, table[hi].coarse_slope, t);
        result.coarse_curve = lerp(table[lo].coarse_curve, table[hi].coarse_curve, t);
    }
    return result;
}

const NativeRim = struct { alpha: f32, offset: f32, luma: f32, chroma: f32, ratio: f32 };
fn mixNativeRim(a: NativeRim, b: NativeRim, t: f32) NativeRim {
    var out = a;
    inline for (@import("zenit_reflection").fields(NativeRim)) |field| @field(out, field.name) = lerp(@field(a, field.name), @field(b, field.name), t);
    return out;
}
/// Colored rim transfer measured on uniform gray and held-out solid colors.
/// The shader applies this to the body color, then interpolates the measured
/// first/second-pixel profile; it is not a white line or a physical BRDF.
fn nativeRim(is_clear: bool, tinted: bool, min_dim: f32, dark: f32) NativeRim {
    const t = norm01(min_dim - 64, 0, 136);
    const light: NativeRim = if (tinted)
        (if (is_clear) .{ .alpha = 0.58506, .offset = 229.1793, .luma = 0.10892, .chroma = 1.50906, .ratio = 0.5753 } else mixNativeRim(.{ .alpha = 0.58785, .offset = 226.3272, .luma = 0.14991, .chroma = 1.53565, .ratio = 0.5783 }, .{ .alpha = 0.79147, .offset = 228.9464, .luma = 0.12524, .chroma = 1.52181, .ratio = 0.5766 }, t))
    else if (is_clear) mixNativeRim(.{ .alpha = 0.60126, .offset = 221.9192, .luma = 0.15849, .chroma = 1.54074, .ratio = 0.5824 }, .{ .alpha = 0.77577, .offset = 233.7914, .luma = 0.10015, .chroma = 1.54074, .ratio = 0.5774 }, t) else mixNativeRim(.{ .alpha = 1.0, .offset = 139.7192, .luma = 0.46486, .chroma = 1.27602, .ratio = 0.5909 }, .{ .alpha = 0.93583, .offset = 194.0645, .luma = 0.25010, .chroma = 1.41712, .ratio = 0.6111 }, t);
    const dim: NativeRim = if (tinted and !is_clear)
        .{ .alpha = 0.8343, .offset = 27.90, .luma = 1.2314, .chroma = 2.3902, .ratio = 0.574 }
    else if (is_clear)
        .{ .alpha = 0.66723, .offset = 32.271, .luma = 1.36928, .chroma = 1.0, .ratio = 0.5814 }
    else
        mixNativeRim(.{ .alpha = 0.59601, .offset = 35.6706, .luma = 1.45029, .chroma = 2.97113, .ratio = 0.5769 }, .{ .alpha = 0.80322, .offset = 38.47, .luma = 1.38372, .chroma = 3.09, .ratio = 0.5745 }, t);
    return mixNativeRim(light, dim, dark);
}

/// Native lens scale: the measured bevel profile shrinks with the smaller
/// dimension of the shape (clear reaches full size at ~58 logical px, regular
/// at ~80) and is otherwise independent of corner radius.
pub fn nativeLensScale(is_clear: bool, min_dim: f32) f32 {
    return @min(1.0, min_dim / (if (is_clear) @as(f32, 57.5) else 78.0));
}

/// `tintColor` with alpha < 1: native output is exactly the untinted glass mixed toward the
/// fully tinted glass by alpha, in sRGB (native_tint_alpha.swift: regular / clear, light / dark,
/// white / gray 128 / black backdrops). The body mix happens in the shader (continuous tint_mode +
/// base_veil); the untinted share keeps its own chroma boost and veil, and the scalar rim / edge
/// parameters are interpolated by the same amount.
/// Material of the glass's idiom profile.
fn resolvedGlassBoxStyle(
    glass_profile: *const GlassProfile,
    tokens: *const theme.ThemeTokens,
    readability: GlassBoxReadability,
    emphasis: GlassBoxEmphasis,
    variant: GlassEffectStyle,
    tint_override: ?Color,
    width: f32,
    height: f32,
    radius: f32,
    live_luminance: ?f32,
    family: MaterialFamily,
) ResolvedGlassBoxStyle {
    return glass_profile.material(glass_profile, tokens, readability, emphasis, variant, tint_override, width, height, radius, live_luminance, family);
}

/// Fitted native material: the measured functional form shared by the macOS and iOS profiles,
/// with the profile's coating coefficients.
pub fn fittedMaterial(
    glass_profile: *const GlassProfile,
    tokens: *const theme.ThemeTokens,
    readability: GlassBoxReadability,
    emphasis: GlassBoxEmphasis,
    variant: GlassEffectStyle,
    tint_override: ?Color,
    width: f32,
    height: f32,
    radius: f32,
    live_luminance: ?f32,
    family: MaterialFamily,
) ResolvedGlassBoxStyle {
    const tint = tint_override orelse
        return resolvedGlassBoxStyleOpaque(&glass_profile.coating, tokens, readability, emphasis, variant, null, width, height, radius, live_luminance, family);
    if (tint.a == 255 or variant == .identity)
        return resolvedGlassBoxStyleOpaque(&glass_profile.coating, tokens, readability, emphasis, variant, tint, width, height, radius, live_luminance, family);
    const plain = resolvedGlassBoxStyleOpaque(&glass_profile.coating, tokens, readability, emphasis, variant, null, width, height, radius, live_luminance, family);
    if (tint.a == 0) return plain;
    const amount = @as(f32, @floatFromInt(tint.a)) / 255.0;
    var out = resolvedGlassBoxStyleOpaque(&glass_profile.coating, tokens, readability, emphasis, variant, tint.withAlpha(255), width, height, radius, live_luminance, family);
    const pg = plain.glass;
    var g = &out.glass;
    g.tint_amount = amount;
    g.base_veil = pg.glass_tint;
    g.veil_curve = pg.veil_curve;
    // Transmission transforms before the material are the untinted ones: the tinted branch
    // reads the transmission without them (shader e_nochroma / tint_source).
    g.backdrop_saturation = pg.backdrop_saturation;
    g.backdrop_brightness = pg.backdrop_brightness;
    g.native_chroma_enabled = pg.native_chroma_enabled;
    g.specular_opacity = lerp(pg.specular_opacity, g.specular_opacity, amount);
    g.native_rim_offset = lerp(pg.native_rim_offset, g.native_rim_offset, amount);
    g.native_rim_luma = lerp(pg.native_rim_luma, g.native_rim_luma, amount);
    g.native_rim_chroma = lerp(pg.native_rim_chroma, g.native_rim_chroma, amount);
    g.native_rim_ratio = lerp(pg.native_rim_ratio, g.native_rim_ratio, amount);
    out.shadow = plain.shadow;
    return out;
}

fn resolvedGlassBoxStyleOpaque(
    coating: *const profile.CoatingModel,
    tokens: *const theme.ThemeTokens,
    readability: GlassBoxReadability,
    emphasis: GlassBoxEmphasis,
    variant: GlassEffectStyle,
    tint_override: ?Color,
    width: f32,
    height: f32,
    radius: f32,
    live_luminance: ?f32,
    family: MaterialFamily,
) ResolvedGlassBoxStyle {
    _ = radius;
    const w = @max(width, 8);
    const h = @max(height, 8);
    const min_dim = @min(w, h);
    const is_clear = variant == .clear;
    if (variant == .identity) {
        // No material: zero blur radius skips the backdrop pass entirely.
        return .{
            .background = Color.rgba(255, 255, 255, 0),
            .border_color = Color.rgba(255, 255, 255, 0),
            .shadow = .{ .color = Color.rgba(0, 0, 0, 0), .blur = 37, .offset_x = 0, .offset_y = 8 },
            .glass = .{
                .backdrop_blur = 0,
                .glass_tint = Color.rgba(255, 255, 255, 0),
                .tint_mode = .surface,
                .glass_intensity = 0,
                .specular_opacity = 0,
                .refraction_level = 0,
                .blur_level = 0,
                .surface = .convex_plate,
                .bottom_surface = .flat,
                .lens_bezel_px = 0,
            },
        };
    }

    // The appearance selects the light/dark material family; the measured
    // backdrop only nudges the drop shadow. Native regular glass flips family
    // on extreme backdrops, which GlassBox deliberately does not emulate.
    // Measured backdrop luminance is kept for the adaptive family flip (M5);
    // the static material and shadow do not depend on it.
    _ = live_luminance;
    // Adaptive family (small regular elements over dark backdrops) overrides
    // the appearance-selected family; both use the measured dark material.
    const dark_factor: f32 = switch (family) {
        .dark => 1.0,
        .light => 0.0,
        .appearance => norm01(0.5 - relativeLuminance(tokens.tokens.color.bg_primary), 0.0, 0.35),
    };
    const is_dark_theme = dark_factor > 0.5;

    // Size responses measured on native: chroma gain and dark luma gain ramp
    // between 64 and 160 logical px; the rim brightens above ~180 px.
    const size_t = norm01(min_dim - 64, 0, 96);

    const readability_bias: f32 = switch (readability) {
        .balanced => -0.06,
        .preferred => 0.0,
        .maximum => 0.04,
    };
    const emphasis_bias: f32 = switch (emphasis) {
        .subtle => -0.08,
        .regular => 0.0,
        .prominent => 0.06,
    };

    // Veil (sRGB blend after the chroma boost). Native regular on gray 128:
    // light 213 + 0.137·in, dark 20 + 0.21·in (0.25 on large panels).
    // Chroma gain after the veil: light 0.39 → 0.73, dark 0.78 → 0.93.
    // Coefficients per idiom profile (profile.CoatingModel).
    const c = coating;
    const coat_t = norm01(min_dim - c.ramp[0], 0, c.ramp[1] - c.ramp[0]);
    const compact: ?profile.CompactCoating = if (c.compact) |k| (if (min_dim <= k.max_dim) k else null) else null;
    const light_alpha = clampf((if (compact) |k| k.light_alpha else lerp(c.light_alpha[0], c.light_alpha[1], coat_t)) + readability_bias, 0.5, 0.95);
    const light_veil_value = if (compact) |k| k.light_veil else lerp(c.light_veil[0], c.light_veil[1], coat_t);
    const light_brightness = if (compact) |k| k.light_brightness else c.light_brightness;
    // Dark: capsule 20 + 0.21·Y, large panel 14 + 0.30·Y on macOS (measured on gray,
    // blue and red backdrops).
    const dark_luma_gain = if (compact) |k| k.dark_gain else lerp(c.dark_gain[0], c.dark_gain[1], coat_t);
    const dark_offset = if (compact) |k| k.dark_offset else lerp(c.dark_offset[0], c.dark_offset[1], coat_t);
    const dark_alpha = clampf(1.0 - dark_luma_gain + readability_bias, 0.5, 0.95);
    const veil_alpha = lerp(light_alpha, dark_alpha, dark_factor);
    const light_chroma = if (compact) |k| k.light_chroma else lerp(c.light_chroma[0], c.light_chroma[1], coat_t);
    const dark_chroma = if (compact) |k| k.dark_chroma else lerp(c.dark_chroma[0], c.dark_chroma[1], coat_t);
    const chroma_gain = lerp(light_chroma, dark_chroma, dark_factor);
    const saturation = chroma_gain / @max(1.0 - veil_alpha, 0.05);
    const light_veil_u8 = alphaU8(light_veil_value);
    const light_veil = Color.rgba(light_veil_u8, light_veil_u8, light_veil_u8, alphaU8(veil_alpha * 255.0));
    // Measured non-affine coating (compact elements): a transfer curve per family, interpolated
    // like the affine coefficients; a family without a curve contributes its affine line.
    const veil_curve: ?[17]f32 = if (compact) |k| (if (k.light_curve != null or k.dark_curve != null) curve: {
        var out: [17]f32 = undefined;
        for (0..17) |i| {
            const x: f32 = @as(f32, @floatFromInt(i)) * 16.0;
            const lc = if (k.light_curve) |lcv| lcv[i] else light_veil_value * light_alpha + light_brightness * x * (1.0 - light_alpha);
            const dc = if (k.dark_curve) |dcv| dcv[i] else dark_offset + x * dark_luma_gain;
            out[i] = lerp(lc, dc, dark_factor) / 255.0;
        }
        break :curve out;
    } else null) else null;
    const dark_veil_value: u8 = alphaU8(dark_offset / @max(dark_alpha, 0.05));
    const dark_veil = Color.rgba(dark_veil_value, dark_veil_value, dark_veil_value, alphaU8(veil_alpha * 255.0));
    // Glass.tint: multiplicative transmission through the tint color after a
    // dense white lift (measured 0.93 light / 0.98 dark / 0.63 clear).
    const tinted = tint_override != null;
    const regular_tint = if (tint_override) |override|
        Color.rgba(override.r, override.g, override.b, alphaU8(lerp(0.93, 0.98, dark_factor) * 255.0))
    else
        lerpColor(light_veil, dark_veil, dark_factor);
    // Clear: 19 + 1.04·in in both appearances = gain 1.124 under a 7.5% white veil.
    const clear_tint = if (tint_override) |override|
        Color.rgba(override.r, override.g, override.b, alphaU8(0.63 * 255.0))
    else
        Color.rgba(255, 255, 255, alphaU8(19));

    const rim = nativeRim(is_clear, tinted, min_dim, dark_factor);

    // Drop shadow (regular only), measured on white and gray 128
    // (native_tint_backdrop.swift capsule 120×44): a fixed multiplicative
    // darkening, identical over text and solid colour and unchanged while
    // content scrolls; no colour bleed. The GlassBox shadow is a black
    // overlay composited in sRGB-encoded space (docs/SRGB_BLENDING_PLAN.md),
    // which is exactly that multiplicative model. Fitted to the below / above /
    // side profiles with Zenit's smoothstep(blur, -blur, sdf) falloff:
    // alpha 0.095, blur 37, offset 8 (RMS 0.5 levels). The dark family keeps the
    // previous light:dark ratio (0.245 : 0.10, fitted under linear blending).
    const light_shadow = if (compact) |k| k.light_shadow else lerp(c.light_shadow[0], c.light_shadow[1], coat_t);
    const dark_shadow = if (compact) |k| k.dark_shadow else lerp(c.dark_shadow[0], c.dark_shadow[1], coat_t);
    const shadow_alpha: f32 = if (is_clear) 0.0 else lerp(light_shadow, dark_shadow, dark_factor) * 255.0;

    const k_lens = nativeLensScale(is_clear, min_dim);
    const blur_dim = if (compact) |k| (if (is_clear) min_dim else k.blur_dim) else min_dim;
    const blur = nativeBlurFamily(is_clear, blur_dim, dark_factor > 0.5);
    // Gray and color modulation share kernel widths but have different
    // transfer coefficients. These local ratios and source curves come from
    // held-out equal-luma red/green and blue/green four-phase captures.
    const chroma_fine_ratio = if (is_dark_theme) lerp(1.0, 1.177, size_t) else lerp(0.8984, 0.4400, size_t);
    const chroma_main_ratio = if (is_dark_theme) lerp(0.949, 1.461, size_t) else lerp(0.9100, 0.4896, size_t);
    const chroma_fine = blur.sharp_mix * chroma_fine_ratio;
    const chroma_coarse = 1.0 - chroma_fine - (1.0 - blur.sharp_mix - blur.coarse_weight) * chroma_main_ratio;
    const chroma_profile: [4]f32 = if (is_dark_theme) .{
        lerp(blur.fine_slope, -0.47398679, size_t),  lerp(blur.fine_curve, 0.05129214, size_t),
        lerp(blur.coarse_slope, 0.13904008, size_t), lerp(blur.coarse_curve, -0.06298607, size_t),
    } else .{
        lerp(-0.57244797, -0.26844589, size_t), lerp(0.16761576, -0.03094569, size_t),
        lerp(-0.05940911, 0.13296813, size_t),  lerp(0.03113592, -0.12629294, size_t),
    };
    const background = Color.rgba(255, 255, 255, if (is_clear) 0 else 1);
    const border_color = Color.rgba(255, 255, 255, 1);

    return .{
        .background = background,
        .border_color = border_color,
        .shadow = .{
            .color = Color.rgba(0, 0, 0, alphaU8(shadow_alpha)),
            .blur = 37,
            .offset_x = 0,
            .offset_y = 8,
        },
        .glass = .{
            .backdrop_blur = blur.radius,
            .glass_tint = if (is_clear) clear_tint else regular_tint,
            .tint_mode = if (tinted) .absorption else .surface,
            .backdrop_brightness = if (is_clear) 1.124 else if (veil_curve != null and !tinted) 1.0 else lerp(light_brightness, 1.0, dark_factor),
            .veil_curve = if (is_clear or tinted) null else veil_curve,
            // A tinted material transmits the same color over gray and colored
            // backdrops (native): no chroma boost before the tint.
            .backdrop_saturation = if (is_clear or tinted) 1.0 else saturation,
            .glass_intensity = 1.0,
            .specular_opacity = clampf(rim.alpha + emphasis_bias, 0.0, 1.0),
            .native_rim_offset = rim.offset / 255.0,
            .native_rim_luma = rim.luma,
            .native_rim_chroma = rim.chroma,
            .native_rim_ratio = rim.ratio,
            .native_chroma_enabled = if (!is_clear and !tinted) 1 else 0,
            .native_chroma_fine = chroma_fine,
            .native_chroma_coarse = chroma_coarse,
            .native_chroma_fine_slope = chroma_profile[0],
            .native_chroma_fine_curve = chroma_profile[1],
            .native_chroma_coarse_slope = chroma_profile[2],
            .native_chroma_coarse_curve = chroma_profile[3],
            .native_tint_mode = if (tinted) (if (is_clear) 2 else 1) else 0,
            .native_tint_dark = dark_factor,
            // A single boost/clip/recenter pipeline is shared by all neutral
            // tint families; appearance changes only its continuous gain.
            // Coefficients use three controlled backgrounds, with seven held
            // out. Clear independently identifies the common source boost.
            .native_tint_chroma_base = if (is_clear) 0.923383797 else lerp(0.139988433, 0.851218159, dark_factor),
            .native_tint_chroma_slope = if (is_clear) 0 else lerp(0.280662395, -0.546423593, dark_factor),
            .specular_saturation = 1.0,
            .refraction_level = 1.0,
            .blur_level = 1.0 - blur.sharp_mix,
            .warp_gain = 1.0,
            .center_thickness = 0.0,
            .native_fine_sigma = blur.fine_sigma,
            .native_main_grid_mix = blur.main_grid_mix,
            .native_coarse_sigma = blur.coarse_sigma,
            .native_fine_weight = blur.sharp_mix,
            .native_coarse_weight = blur.coarse_weight,
            .native_fine_slope = blur.fine_slope,
            .native_fine_curve = blur.fine_curve,
            .native_coarse_slope = blur.coarse_slope,
            .native_coarse_curve = blur.coarse_curve,
            .surface = .convex_plate,
            .bezel_width = 0.5,
            .bottom_surface = .flat,
            .bottom_bezel_width = 0.08,
            .specular_angle = if (is_dark_theme) -std.math.pi / 2.7 else -std.math.pi / 3.1,
            .magnification = 0.0,
            .scale_ratio = 1.0,
            .edge_field_strength = 1.0,
            .center_zoom_radius = 0.58,
            .center_zoom_falloff = 2.2,
            .backdrop_distance = 0.0,
            .lens_bezel_px = 19.75 * k_lens,
            .lens_height_px = 27.0 * k_lens,
            .lens_base_px = 37.5 * k_lens,
            // Rim transmits more sharp detail than the center (native amplitude
            // ratio ≈ 1.9 for clear, similar for regular).
            // Light regular transmits noticeably more detail through the rim
            // of large panels (text edges); dark regular transmits less.
            .lens_edge_blur = if (is_clear) 0.72 else lerp(lerp(0.75, 0.70, size_t), 1.0, dark_factor),
        },
    };
}

fn autoTint(is_dark_theme: bool, tint_override: ?Color, alpha: u8) Color {
    if (tint_override) |override| {
        return .{
            .r = override.r,
            .g = override.g,
            .b = override.b,
            .a = @max(override.a, alpha),
        };
    }

    return if (is_dark_theme)
        Color.rgba(44, 52, 66, alpha)
    else
        Color.rgba(244, 247, 252, alpha);
}

fn norm01(value: f32, min: f32, max: f32) f32 {
    if (max <= min) return 0;
    return clampf((value - min) / (max - min), 0, 1);
}

/// Same elapsed-time response on 30 Hz, 60 Hz and ProMotion displays.
/// Consume `dt` from a start-delay countdown; returns the part of `dt` left
/// after the delay ended (0 while it is still running).
fn holdRemainder(hold_s: *f32, dt: f32) f32 {
    if (hold_s.* <= 0) return dt;
    if (dt < hold_s.*) {
        hold_s.* -= dt;
        return 0;
    }
    const rest = dt - hold_s.*;
    hold_s.* = 0;
    return rest;
}

test "holdRemainder carries the time left after a start delay into the same frame" {
    var hold: f32 = 0.04;
    try std.testing.expectEqual(@as(f32, 0), holdRemainder(&hold, 0.016));
    try std.testing.expectApproxEqAbs(@as(f32, 0.024), hold, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.476), holdRemainder(&hold, 0.5), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), hold);
    try std.testing.expectEqual(@as(f32, 0.5), holdRemainder(&hold, 0.5));
}

fn materialResponse(response_at_60hz: f32, dt: f32) f32 {
    return 1.0 - std.math.pow(f32, 1.0 - response_at_60hz, dt * 60.0);
}

fn lerp(from: f32, to: f32, t: f32) f32 {
    return from + (to - from) * clampf(t, 0, 1);
}

fn clampf(value: f32, min: f32, max: f32) f32 {
    return std.math.clamp(value, min, max);
}

fn alphaU8(value: f32) u8 {
    return @intFromFloat(clampf(value, 0, 255));
}

fn channelToLinear(c: u8) f32 {
    const v = @as(f32, @floatFromInt(c)) / 255.0;
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn relativeLuminance(c: Color) f32 {
    const r = channelToLinear(c.r);
    const g = channelToLinear(c.g);
    const b = channelToLinear(c.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

pub fn runBeforeRenderHooks(node: *Node) void {
    if (node.meta.per_frame.hooks.before_render.main) |hook| hook(node);
    for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |hook_opt| {
        if (hook_opt) |hook| hook(node);
    }
}

test "GlassBox: mountBody installs adaptive liquid glass" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 520 },
        .height = .{ .px = 320 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const mounted = try GlassBox(.{
        .title = "Overview",
        .subtitle = "Readable liquid glass panel",
        .width = 320,
        .height = 180,
    }).mountBody(scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.box);

    ctx.layout();
    runBeforeRenderHooks(mounted.box);

    try std.testing.expectEqualStrings("GlassBox", mounted.box.meta.ownership.meta.component_name.?);
    try std.testing.expectEqual(@as(usize, 1), mounted.box.children.items.len);
    const surface_node = mounted.box.children.items[0];
    try std.testing.expect(surface_node.style.glass_params() != null);
    try std.testing.expect(surface_node.style.border.width > 0);
    try std.testing.expect(surface_node.getBackground().a > 0);
    try std.testing.expectEqual(@as(usize, 2), surface_node.children.items[0].children.items.len);
}

test "GlassBox: maximum readability trades distortion for blur and tint" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 400 },
        .direction = .row,
        .gap = 24,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const balanced = try GlassBox(.{
        .width = 280,
        .height = 160,
        .readability = .balanced,
    }).mount(scope, ctx);
    const maximum = try GlassBox(.{
        .width = 280,
        .height = 160,
        .readability = .maximum,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, balanced);
    try root.appendChild(std.testing.allocator, maximum);

    ctx.layout();
    runBeforeRenderHooks(balanced);
    runBeforeRenderHooks(maximum);

    const gp_balanced = balanced.children.items[0].style.glass_params().?;
    const gp_maximum = maximum.children.items[0].style.glass_params().?;

    // The native material keeps its lens and blur; readability only moves
    // the veil density around the measured native value.
    try std.testing.expect(gp_maximum.glass_tint.?.a > gp_balanced.glass_tint.?.a);
    try std.testing.expectEqual(gp_maximum.lens_bezel_px, gp_balanced.lens_bezel_px);
    try std.testing.expectEqual(gp_maximum.backdrop_blur, gp_balanced.backdrop_blur);
}

test "GlassBox: SwiftUI API surface — capsule shape, identity variant and isEnabled" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 400 }, .direction = .row, .gap = 24 }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const capsule = try GlassBox(.{ .width = 240, .height = 56, .shape = .capsule }).mount(scope, ctx);
    const identity = try GlassBox(.{ .width = 240, .height = 56, .glass_style = .identity }).mount(scope, ctx);
    const disabled = try GlassBox(.{ .width = 240, .height = 56, .enabled = false }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, capsule);
    try root.appendChild(std.testing.allocator, identity);
    try root.appendChild(std.testing.allocator, disabled);
    ctx.layout();
    runBeforeRenderHooks(capsule);
    runBeforeRenderHooks(identity);
    runBeforeRenderHooks(disabled);

    // Capsule: the corner radius follows the smaller dimension every frame.
    try std.testing.expectEqual(@as(f32, 28), capsule.children.items[0].style.border.radius);
    const gp = capsule.children.items[0].style.glass_params().?;
    try std.testing.expect(gp.backdrop_blur > 0);
    try std.testing.expect(gp.lens_bezel_px > 0);
    // identity / isEnabled(false): no material at all (zero blur skips the pass).
    for ([_]*Node{ identity, disabled }) |g| {
        const p = g.children.items[0].style.glass_params().?;
        try std.testing.expectEqual(@as(f32, 0), p.backdrop_blur);
        try std.testing.expectEqual(@as(u8, 0), p.glass_tint.?.a);
        try std.testing.expectEqual(@as(u8, 0), g.children.items[0].getBackground().a);
    }
    try std.testing.expectEqual(@as(f32, 24), shapeRadius(.{ .rounded = 24 }, 18, 100, 50));
    try std.testing.expectEqual(@as(f32, 25), shapeRadius(.circle, 18, 100, 50));
}

test "GlassBox: glassSetEnabled materializes out then in on the display clock" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .fixed(600), .height = .fixed(400) }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const mounted = try GlassBox(.{ .width = 200, .height = 56, .shape = .capsule }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.box);
    ctx.layout();
    ctx.frame_time_ms = 5000;
    runBeforeRenderHooks(mounted.box);
    const surface = mounted.box.children.items[0];
    const full_bg = surface.getBackground().a;
    const full_rim = surface.style.glass_params().?.specular_opacity;
    try std.testing.expect(full_bg > 0 and full_rim > 0);

    glassSetEnabled(mounted.state, false);
    try std.testing.expect(mounted.state.materialize != null);
    try std.testing.expect(mounted.state.enabled); // stays regular until fully dissolved
    ctx.frame_presentation_sample = .{ .tick = 36, .target_time_ms = null, .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mounted.state.materialize_level, 1e-6);
    // ≈ 8 display periods (133 ms) into the 270 ms dissolve: material about half way out
    ctx.frame_time_ms += 133;
    ctx.frame_dt_ms = 133;
    ctx.frame_presentation_sample = .{ .tick = 44, .target_time_ms = 90035 + 7 * (1000.0 / 60.0), .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    const mid = mounted.state.materialize_level;
    try std.testing.expect(mid > 0.25 and mid < 0.75);
    const mid_gp = surface.style.glass_params().?;
    try std.testing.expect(surface.getBackground().a < full_bg);
    try std.testing.expect(mid_gp.specular_opacity < full_rim and mid_gp.specular_opacity > 0);
    try std.testing.expect(mid_gp.blur_level < 1.0);
    try std.testing.expect(surface.frame_state.state_bits.flags.disable_render_cache);
    // past the end: identity, no backdrop pass
    ctx.frame_time_ms += 300;
    ctx.frame_presentation_sample = .{ .tick = 62, .target_time_ms = 90035 + 25 * (1000.0 / 60.0), .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    try std.testing.expect(mounted.state.materialize == null);
    try std.testing.expect(!mounted.state.enabled);
    // same frame switched to identity: don't emit backdrop pass
    try std.testing.expectEqual(@as(f32, 0), surface.style.glass_params().?.backdrop_blur);

    // appear: enabled immediately, level ramps 0 -> 1 over 420 ms
    glassSetEnabled(mounted.state, true);
    try std.testing.expect(mounted.state.enabled);
    ctx.frame_presentation_sample = .{ .tick = 70, .target_time_ms = null, .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mounted.state.materialize_level, 1e-6);
    try std.testing.expect(surface.style.glass_params().?.backdrop_blur > 0);
    ctx.frame_time_ms += 500;
    ctx.frame_presentation_sample = .{ .tick = 100, .target_time_ms = 90035 + 63 * (1000.0 / 60.0), .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    try std.testing.expect(mounted.state.materialize == null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mounted.state.materialize_level, 1e-6);
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectEqual(full_bg, surface.getBackground().a);

    // identity transition switches instantly
    mounted.state.transition = .identity;
    glassSetEnabled(mounted.state, false);
    try std.testing.expect(!mounted.state.enabled and mounted.state.materialize == null);
}

test "GlassBox: materialize reversed mid-way scales the remaining duration and ignores same-direction repeats" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .fixed(600), .height = .fixed(400) }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const mounted = try GlassBox(.{ .width = 200, .height = 56, .shape = .capsule }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.box);
    ctx.layout();
    ctx.frame_time_ms = 5000;
    runBeforeRenderHooks(mounted.box);
    glassSetEnabled(mounted.state, false);
    const start0 = mounted.state.materialize.?.start_time_ms;
    glassSetEnabled(mounted.state, false); // same-direction repeat: don't reset clock
    try std.testing.expectEqual(start0, mounted.state.materialize.?.start_time_ms);
    ctx.frame_presentation_sample = .{ .tick = 36, .target_time_ms = null, .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    ctx.frame_time_ms += 133;
    ctx.frame_presentation_sample = .{ .tick = 44, .target_time_ms = 90035 + 7 * (1000.0 / 60.0), .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    const mid = mounted.state.materialize_level;
    try std.testing.expect(mid > 0.25 and mid < 0.75);
    glassSetEnabled(mounted.state, true); // mid-transition reverse
    const m = mounted.state.materialize.?;
    try std.testing.expectEqual(@as(f32, 1.0), m.to);
    try std.testing.expectApproxEqAbs(mid, m.from, 1e-6);
    try std.testing.expectApproxEqAbs(profile.macos.materialize.appear_ms * (1.0 - mid), @as(f32, @floatCast(m.duration_ms)), 0.5);
    try std.testing.expect(mounted.state.enabled);
}

test "springSmooth matches SwiftUI .smooth: 82% at half duration, 98.6% at duration" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), springSmooth(0, 0.6), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.821), springSmooth(0.3, 0.6), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.986), springSmooth(0.6, 0.6), 0.005);
    try std.testing.expect(springSmooth(0.1, 0.6) < springSmooth(0.2, 0.6));
}

test "GlassBox: adaptive family flips small regular elements with hysteresis, never large ones" {
    // Pure decision function: thresholds and size gate from the native sweep.
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, false, 64, .regular, false, 60.0 / 255.0, false));
    try std.testing.expect(adaptiveFamilyStep(&profile.macos.family, false, 64, .regular, false, 32.0 / 255.0, false));
    try std.testing.expect(adaptiveFamilyStep(&profile.macos.family, true, 64, .regular, false, 112.0 / 255.0, false));
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, true, 64, .regular, false, 130.0 / 255.0, false));
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, false, 96, .regular, false, 0.0, false));
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, false, 44, .clear, false, 0.0, false));
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, false, 44, .regular, true, 0.0, false));
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, false, 44, .regular, false, null, false));
    // dark appearance: large regular fixed dark; small no reading keep current family (new =
    // appearance family); hysteresis on light end: dark at 224 doesn't flip, 240 goes light; light
    // at 176 doesn't return, 152 returns dark
    try std.testing.expect(adaptiveFamilyStep(&profile.macos.family, false, 96, .regular, false, 1.0, true));
    try std.testing.expect(adaptiveFamilyStep(&profile.macos.family, true, 44, .regular, false, null, true));
    try std.testing.expect(adaptiveFamilyStep(&profile.macos.family, true, 44, .regular, false, 128.0 / 255.0, true));
    try std.testing.expect(adaptiveFamilyStep(&profile.macos.family, true, 44, .regular, false, 224.0 / 255.0, true));
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, true, 44, .regular, false, 240.0 / 255.0, true));
    try std.testing.expect(!adaptiveFamilyStep(&profile.macos.family, false, 44, .regular, false, 176.0 / 255.0, true));
    try std.testing.expect(adaptiveFamilyStep(&profile.macos.family, false, 44, .regular, false, 152.0 / 255.0, true));

    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    // light appearance: test Cx default dark theme, new glass starts from appearance family (native
    // measured)
    ctx.tokens = &theme.light;
    ctx.setTheme(&theme.light); // the switch is relative to the light appearance family
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 }, .direction = .row, .gap = 24 }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const small = try GlassBox(.{ .width = 320, .height = 64, .shape = .capsule, .title = "Today" }).mountWithState(scope, ctx);
    const large = try GlassBox(.{ .width = 320, .height = 200 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, small.box);
    try root.appendChild(std.testing.allocator, large.box);
    ctx.layout();
    runBeforeRenderHooks(small.box);
    runBeforeRenderHooks(large.box);
    const light_small = small.box.children.items[0].style.glass_params().?.glass_tint.?;
    // A fresh effect starts in the light family even over a dark backdrop reading.
    try std.testing.expect(light_small.r > 200);
    ctx.backdrop_luminance_regions[0] = .{ .node_id = small.state.surface.id, .lum = 0.01, .lum_srgb = 20.0 / 255.0 };
    ctx.backdrop_luminance_regions[1] = .{ .node_id = large.state.surface.id, .lum = 0.01, .lum_srgb = 20.0 / 255.0 };
    ctx.backdrop_luminance_region_count = 2;
    ctx.frame_dt_seconds = 1.0 / 60.0;
    runBeforeRenderHooks(small.box);
    runBeforeRenderHooks(large.box);
    try std.testing.expect(small.state.family_dark);
    try std.testing.expect(!large.state.family_dark);
    // The switch is a transition (native 0.37 s spring), not a one-frame swap: after one frame the
    // material is still close to the light family and the title is mid-way at most.
    const first = small.box.children.items[0].style.glass_params().?.glass_tint.?;
    try std.testing.expect(first.r > 180);
    // startup delay 45ms: within two frames (33ms) still light, fourth frame (67ms) already
    // transitioning
    runBeforeRenderHooks(small.box);
    try std.testing.expectEqual(@as(f32, 0), small.state.family_mix);
    runBeforeRenderHooks(small.box);
    runBeforeRenderHooks(small.box);
    try std.testing.expect(small.state.family_mix > 0 and small.state.family_mix < 0.2);
    for (0..60) |_| {
        runBeforeRenderHooks(small.box);
        runBeforeRenderHooks(large.box);
    }
    try std.testing.expectEqual(@as(f32, 1), small.state.family_mix);
    // Content vibrancy: the title turns light on the dark family.
    try std.testing.expectEqual(Color.WHITE, small.state.title_node.?.getText().?.color);
    const dark_small = small.box.children.items[0].style.glass_params().?.glass_tint.?;
    try std.testing.expect(dark_small.r < 60);
    try std.testing.expect(large.box.children.items[0].style.glass_params().?.glass_tint.?.r > 200);
    // Hysteresis: a mid-gray backdrop keeps the dark family; a light one restores it.
    ctx.backdrop_luminance_regions[0].lum_srgb = 100.0 / 255.0;
    runBeforeRenderHooks(small.box);
    try std.testing.expect(small.state.family_dark);
    ctx.backdrop_luminance_regions[0].lum_srgb = 200.0 / 255.0;
    for (0..60) |_| runBeforeRenderHooks(small.box);
    try std.testing.expect(!small.state.family_dark);
    try std.testing.expectEqual(@as(f32, 0), small.state.family_mix);
    try std.testing.expect(!std.meta.eql(Color.WHITE, small.state.title_node.?.getText().?.color));
}

test "GlassBox: clear variant is markedly more transparent than regular" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 400 },
        .direction = .row,
        .gap = 24,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const regular = try GlassBox(.{ .width = 280, .height = 160 }).mount(scope, ctx);
    const clear = try GlassBox(.{ .width = 280, .height = 160, .glass_style = .clear }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, regular);
    try root.appendChild(std.testing.allocator, clear);

    ctx.layout();
    runBeforeRenderHooks(regular);
    runBeforeRenderHooks(clear);

    const gp_regular = regular.children.items[0].style.glass_params().?;
    const gp_clear = clear.children.items[0].style.glass_params().?;

    // clear: frosting much lower, tint weaker, refraction not weaker than regular. Compare
    // effective blur: clear can use mostly blurred sample smaller kernel, not mix sharp grid lines
    // back into body.
    try std.testing.expect(gp_clear.backdrop_blur * gp_clear.blur_level < gp_regular.backdrop_blur * gp_regular.blur_level * 0.7);
    try std.testing.expect(gp_clear.backdrop_blur < gp_regular.backdrop_blur);
    try std.testing.expect(gp_clear.glass_tint.?.a < gp_regular.glass_tint.?.a);
    try std.testing.expect(gp_clear.refraction_level >= gp_regular.refraction_level);
    try std.testing.expect(clear.children.items[0].getBackground().a < regular.children.items[0].getBackground().a);
}

test "GlassBox: compact layouts automatically soften lensing" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 900 },
        .height = .{ .px = 420 },
        .direction = .row,
        .gap = 24,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const compact = try GlassBox(.{
        .width = 140,
        .height = 52,
    }).mount(scope, ctx);
    const spacious = try GlassBox(.{
        .width = 360,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, compact);
    try root.appendChild(std.testing.allocator, spacious);

    ctx.layout();
    runBeforeRenderHooks(compact);
    runBeforeRenderHooks(spacious);

    const compact_gp = compact.children.items[0].style.glass_params().?;
    const spacious_gp = spacious.children.items[0].style.glass_params().?;

    // Native size responses: the lens profile shrinks with the smaller
    // dimension, the blur radius and chroma gain grow with it.
    try std.testing.expect(compact_gp.lens_bezel_px < spacious_gp.lens_bezel_px);
    try std.testing.expect(compact_gp.lens_base_px < spacious_gp.lens_base_px);
    try std.testing.expect(compact_gp.backdrop_blur < spacious_gp.backdrop_blur);
    // Chroma gain after the veil (not the pre-veil saturation, which falls
    // with size in the dark family) grows with size in both families.
    const compact_chroma = compact_gp.backdrop_saturation * (255.0 - @as(f32, @floatFromInt(compact_gp.glass_tint.?.a)));
    const spacious_chroma = spacious_gp.backdrop_saturation * (255.0 - @as(f32, @floatFromInt(spacious_gp.glass_tint.?.a)));
    try std.testing.expect(compact_chroma < spacious_chroma);
    try std.testing.expectEqual(@as(f32, 1.0), compact_gp.refraction_level);
}

test "GlassBox: interactive glass has no material response (native macOS); .glass_button press shifts the body" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    // light appearance: test Cx default dark theme, new glass starts from appearance family (native
    // measured)
    ctx.tokens = &theme.light;

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    // custom .interactive(): hover/press don't change glass params (native native_interactive.swift
    // measured zero pixel change)
    const g = try GlassBox(.{ .width = 240, .height = 120, .interactive = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, g);
    // .glass button style: press this frame sRGB shift
    const b = try GlassBox(.{ .width = 120, .height = 44, .press_feedback = .glass_button }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, b);
    ctx.layout();
    runBeforeRenderHooks(g);
    runBeforeRenderHooks(b);

    const resting = g.children.items[0].style.glass_params().?;
    const state: *AdaptiveGlassBoxState = @ptrCast(@alignCast(g.meta.per_frame.hooks.slots.anim_state.?));
    _ = interactiveGlassEventHandler(.{ .mouse_enter = {} }, @ptrCast(state));
    _ = interactiveGlassEventHandler(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, @ptrCast(state));
    var i: usize = 0;
    while (i < 60) : (i += 1) runBeforeRenderHooks(g);
    const pressed = g.children.items[0].style.glass_params().?;
    try std.testing.expectEqual(resting.specular_opacity, pressed.specular_opacity);
    try std.testing.expectEqual(resting.glass_intensity, pressed.glass_intensity);
    try std.testing.expectEqual(@as(f32, 0), pressed.press_offset);
    // guard assert: interactive never write non-1 scale (pushes glass offscreen composite path)
    try std.testing.expectEqual(@as(f32, 1.0), g.style.scale_x());

    const bs: *AdaptiveGlassBoxState = @ptrCast(@alignCast(b.meta.per_frame.hooks.slots.anim_state.?));
    _ = interactiveGlassEventHandler(.{ .mouse_enter = {} }, @ptrCast(bs));
    runBeforeRenderHooks(b);
    try std.testing.expectEqual(@as(f32, 0), b.children.items[0].style.glass_params().?.press_offset); // hover no change
    _ = interactiveGlassEventHandler(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, @ptrCast(bs));
    runBeforeRenderHooks(b); // frame switch, no interpolation
    try std.testing.expectApproxEqAbs(profile.macos.press.glass_button_light, b.children.items[0].style.glass_params().?.press_offset, 1e-6);
    _ = interactiveGlassEventHandler(.{ .mouse_up = .{ .x = 0, .y = 0, .button = .left } }, @ptrCast(bs));
    runBeforeRenderHooks(b);
    try std.testing.expectEqual(@as(f32, 0), b.children.items[0].style.glass_params().?.press_offset);
}

test "GlassBox: input after idle anchors morph to the event clock and press to presentation" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .fixed(600), .height = .fixed(400) }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const mounted = try GlassBox(.{ .width = 240, .height = 120, .interactive = true }).mountWithState(scope, ctx);
    mounted.box.style.position = .absolute;
    try root.appendChild(std.testing.allocator, mounted.box);
    ctx.layout();
    ctx.frame_dt_seconds = 0.1;
    _ = interactiveGlassEventHandler(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, @ptrCast(mounted.state));
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectEqual(@as(f32, 0), mounted.state.glass_boost);
    // A paused last-render clock differs from the event's live clock after
    // idle. Keep the old 100 ms dt to catch accidentally advancing from it.
    ctx.clock_epoch = try @import("zenit_time").Instant.now(ctx.io);
    try std.Io.sleep(ctx.io, .fromNanoseconds(2 * std.time.ns_per_ms), .awake);
    glassMorphTo(mounted.state, .{ .x = 40, .y = 30, .w = 96, .h = 96, .frames = 18 });
    const event_time = mounted.state.morph.?.start_time_ms;
    try std.testing.expect(event_time > ctx.frame_time_ms);
    ctx.frame_time_ms = event_time + 60;
    runBeforeRenderHooks(mounted.box);
    // 60 ms of a 300 ms morph is 10.4% of the geometric path. It must be
    // visible on this first frame rather than restarting at the idle pose.
    try std.testing.expectApproxEqAbs(@as(f32, 225.024), mounted.box.style.width.px, 0.001);
    ctx.frame_time_ms += 240;
    runBeforeRenderHooks(mounted.box);
    try std.testing.expect(mounted.state.morph == null);
    try std.testing.expectApproxEqAbs(@as(f32, 96), mounted.box.style.width.px, 0.001);
}

test "GlassBox: press 材质在 30/60/120 Hz 下以相同时间响应" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    var responses: [3]f32 = undefined;
    inline for (.{ 30, 60, 120 }, 0..) |hz, n| {
        const mounted = try GlassBox(.{ .width = 240, .height = 120, .interactive = true }).mountWithState(scope, ctx);
        try root.appendChild(std.testing.allocator, mounted.box);
        ctx.layout();
        ctx.frame_dt_seconds = 1.0 / @as(f32, hz);
        _ = interactiveGlassEventHandler(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, @ptrCast(mounted.state));
        runBeforeRenderHooks(mounted.box); // Anchor the event; preceding dt is not animation time.
        // 100 ms, before the response reaches its settle threshold.
        for (0..hz / 10) |_| runBeforeRenderHooks(mounted.box);
        responses[n] = mounted.state.glass_boost;
    }
    try std.testing.expect(responses[0] > 0.5 and responses[0] < 0.9);
    try std.testing.expectApproxEqAbs(responses[0], responses[1], 1e-5);
    try std.testing.expectApproxEqAbs(responses[1], responses[2], 1e-5);
}

test "GlassBox: morph uses elapsed frame time across a slow frame" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .fixed(600), .height = .fixed(400) }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const mounted = try GlassBox(.{ .width = 240, .height = 120 }).mountWithState(scope, ctx);
    mounted.box.style.position = .absolute;
    try root.appendChild(std.testing.allocator, mounted.box);
    ctx.layout();
    ctx.frame_time_ms = 5000;
    glassMorphTo(mounted.state, .{ .x = 40, .y = 30, .w = 96, .h = 96 });
    runBeforeRenderHooks(mounted.box);
    // Incremental dt is bounded for spring stability, while this 300 ms tween
    // must retain the whole 180 ms of elapsed animation time.
    ctx.frame_dt_seconds = 0.1;
    ctx.frame_time_ms += 180;
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), mounted.state.morph.?.t, 1e-5);
    const width = mounted.box.style.width.px;
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectEqual(width, mounted.box.style.width.px);
    ctx.frame_time_ms += 120;
    runBeforeRenderHooks(mounted.box);
    try std.testing.expect(mounted.state.morph == null);
    try std.testing.expectApproxEqAbs(@as(f32, 96), mounted.box.style.width.px, 0.001);
}

test "GlassBox: morph samples presentation ticks despite CPU jitter and skipped frames" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .fixed(600), .height = .fixed(400) }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const mounted = try GlassBox(.{ .width = 320, .height = 64 }).mountWithState(scope, ctx);
    mounted.box.style.position = .absolute;
    try root.appendChild(std.testing.allocator, mounted.box);
    ctx.layout();
    ctx.frame_time_ms = 5000;
    glassMorphTo(mounted.state, .{ .x = 200, .y = 160, .w = 240, .h = 160 });
    // An input-triggered draw starts the transaction before an idle display
    // link has delivered a fresh target. It displays the existing pose.
    ctx.frame_presentation_sample = .{ .tick = 36, .target_time_ms = null, .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectEqual(@as(f32, 320), mounted.box.style.width.px);
    ctx.frame_time_ms += 12;
    ctx.frame_dt_ms = 100;
    ctx.frame_presentation_sample = .{ .tick = 37, .target_time_ms = 90035, .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 18.0), mounted.state.morph.?.t, 1e-6);
    const width = mounted.box.style.width.px;
    // Screenshot/input may force another draw in this same display tick.
    ctx.frame_time_ms += 9;
    runBeforeRenderHooks(mounted.box);
    try std.testing.expectEqual(width, mounted.box.style.width.px);
    // Advancing targets preserves the entire slow interval, independent of
    // the bounded physics dt and without requiring every intermediate draw.
    ctx.frame_time_ms += 100;
    ctx.frame_presentation_sample = .{ .tick = 54, .target_time_ms = 90035 + 17 * (1000.0 / 60.0), .period_ms = 1000.0 / 60.0 };
    runBeforeRenderHooks(mounted.box);
    try std.testing.expect(mounted.state.morph == null);
    try std.testing.expectEqual(@as(f32, 240), mounted.box.style.width.px);
}

// styles.zig test collection, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// per-allocation OOM sweep, see src/ui/components/oom_sweep.zig
test "GlassBox: scroll-edge 渐变 stops 不低于玻璃基底糊度" {
    // regression: stops was 1 -> 0, after scroll glass strip outside fade band went sharp
    for ([_]f32{ 0.25, 0.68, 0.83, 1.0 }) |bl| {
        const stops = scrollEdgeStops(28, 44, bl);
        try std.testing.expectEqual(@as(f32, 0), stops[0].pos);
        try std.testing.expectApproxEqAbs(@as(f32, 28.0 / 44.0), stops[1].pos, 1e-5);
        try std.testing.expectEqual(@as(f32, 1), stops[0].strength);
        for (stops) |st| try std.testing.expect(st.strength >= bl - 1e-6);
    }
    // fade_width exceeds node: stop position clamp [0,1]
    try std.testing.expectEqual(@as(f32, 1), scrollEdgeStops(80, 44, 0.8)[1].pos);
}

test "glass_box: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("glass_box", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try GlassBox(.{ .title = "Glass", .subtitle = "sub", .interactive = true }).mount(scope, cx);
        }
    }.m);
}

test "GlassBox: springSettleFactor ends the spring below 0.05 px of residual" {
    const f = springSettleFactor(300);
    const x = 2 * std.math.pi * f;
    try std.testing.expect((1 + x) * @exp(-x) * 300 <= 0.05);
    try std.testing.expect(f > 1.15); // old fixed 1.15x leaves 1.7px end-frame jump
}

test "GlassBox: inactive window replaces Glass.tint with the measured gray coating, tightens the plain veil and drops rim + shadow" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    // light appearance: test Cx default dark theme, new glass starts from appearance family (native
    // measured)
    ctx.tokens = &theme.light;
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const tinted = try GlassBox(.{ .width = 120, .height = 44, .tint_color = Color.rgba(255, 141, 40, 255) }).mount(scope, ctx);
    const plain = try GlassBox(.{ .width = 120, .height = 44 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tinted);
    try root.appendChild(std.testing.allocator, plain);
    ctx.layout();
    runBeforeRenderHooks(tinted);
    runBeforeRenderHooks(plain);
    const active_tint = tinted.children.items[0].style.glass_params().?.glass_tint;
    const active_plain = plain.children.items[0].style.glass_params().?.glass_tint;
    try std.testing.expectEqual(@as(u8, 255), active_tint.?.r); // orange tint
    try std.testing.expect(plain.style.ext.?.shadows[0].color.a > 0);
    try std.testing.expect(plain.children.items[0].style.glass_params().?.native_rim_luma > 0);

    ctx.window_active = false;
    runBeforeRenderHooks(tinted);
    runBeforeRenderHooks(plain);
    const inactive_tint = tinted.children.items[0].style.glass_params().?.glass_tint;
    try std.testing.expectEqual(@as(u8, 213), inactive_tint.?.r);
    try std.testing.expectEqual(inactive_tint.?.r, inactive_tint.?.b); // neutral gray, unrelated to tint
    try std.testing.expectEqual(@as(u8, 241), plain.children.items[0].style.glass_params().?.glass_tint.?.r);
    _ = active_plain;
    // inactive glass flattens: edge highlight and shadow disappear
    for ([_]*Node{ tinted, plain }) |n| {
        try std.testing.expectEqual(@as(u8, 0), n.style.ext.?.shadows[0].color.a);
        try std.testing.expectEqual(@as(f32, 0), n.children.items[0].style.glass_params().?.native_rim_luma);
        try std.testing.expectEqual(@as(f32, 0), n.children.items[0].style.glass_params().?.specular_opacity);
    }

    ctx.window_active = true;
    runBeforeRenderHooks(tinted);
    try std.testing.expectEqual(active_tint, tinted.children.items[0].style.glass_params().?.glass_tint);

    // dark family (native_dark_inactive.swift): inactive layer 41 + 0.125*in, also flattens
    const dark = try GlassBox(.{ .width = 120, .height = 44 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, dark.box);
    ctx.layout();
    glassSetFamilyImmediate(dark.state, true);
    runBeforeRenderHooks(dark.box);
    try std.testing.expect(dark.box.children.items[0].style.glass_params().?.glass_tint.?.r < 40); // active dark family layer
    ctx.window_active = false;
    dark.state.last_style = null;
    runBeforeRenderHooks(dark.box);
    const gp = dark.box.children.items[0].style.glass_params().?;
    try std.testing.expectEqual(profile.macos.inactive.dark_veil, gp.glass_tint.?);
    try std.testing.expectEqual(@as(f32, 0), gp.native_rim_luma);
    try std.testing.expectEqual(@as(u8, 0), dark.box.style.ext.?.shadows[0].color.a);
    ctx.window_active = true;
}

test "familyMixStep: measured native family transition (critically damped spring, frame-rate independent)" {
    // native_family_transition.swift: to dark response 0.37s, back to light 0.50s, x = 1 - (1 +
    // omega*t)*e^(-omega*t). Glass body and content ink each one curve (ink opposite direction:
    // brighten slower, darken faster)
    const fam = &profile.macos.family;
    inline for (.{ .{ true, fam.to_dark_response_s, familyMixStep }, .{ false, fam.to_light_response_s, familyMixStep }, .{ true, fam.ink_to_dark_response_s, familyInkMixStep }, .{ false, fam.ink_to_light_response_s, familyInkMixStep } }) |c| {
        const dark = c[0];
        const w = 2.0 * std.math.pi / c[1];
        for ([_]f32{ 1.0 / 60.0, 1.0 / 120.0 }) |dt| {
            var mix: f32 = if (dark) 0 else 1;
            var vel: f32 = 0;
            var t: f32 = 0;
            var prev = mix;
            var settled_at: ?f32 = null;
            while (t < 1.5) {
                const moving = c[2](fam, &mix, &vel, dark, dt);
                t += dt;
                const p = if (dark) mix else 1 - mix;
                const expect = 1 - (1 + w * t) * @exp(-w * t);
                if (moving) try std.testing.expectApproxEqAbs(expect, p, 2e-3);
                // monotonic, no bounce
                if (dark) try std.testing.expect(mix >= prev - 1e-6) else try std.testing.expect(mix <= prev + 1e-6);
                prev = mix;
                if (!moving and settled_at == null) settled_at = t;
            }
            try std.testing.expectEqual(@as(f32, if (dark) 1 else 0), mix);
            // measured: to dark ~0.4s, back to light ~0.6s complete
            try std.testing.expect(settled_at.? > c[1] and settled_at.? < c[1] * 2.2);
        }
    }
}

test "GlassBox: glassSetHeld keeps the glass_button pressed look without a pointer" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    // light appearance: test Cx default dark theme, new glass starts from appearance family (native
    // measured)
    ctx.tokens = &theme.light;
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const m = try GlassBox(.{ .width = 80, .height = 28, .shape = .capsule, .press_feedback = .glass_button }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, m.box);
    ctx.layout();
    runBeforeRenderHooks(m.box);
    try std.testing.expectEqual(@as(f32, 0), m.box.children.items[0].style.glass_params().?.press_offset);
    glassSetHeld(m.state, true);
    runBeforeRenderHooks(m.box);
    try std.testing.expectApproxEqAbs(profile.macos.press.glass_button_light, m.box.children.items[0].style.glass_params().?.press_offset, 1e-6);
    glassSetHeld(m.state, false);
    runBeforeRenderHooks(m.box);
    try std.testing.expectEqual(@as(f32, 0), m.box.children.items[0].style.glass_params().?.press_offset);
}

test "GlassBox knob_lens: exempt from the generic a11y swap; increase contrast turns the rim into a full dark ring" {
    const saved = a11y_preferences.current();
    defer a11y_preferences.set(saved);
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const m = try GlassBox(.{ .width = 50, .height = 31, .shape = .capsule, .glass_style = .clear, .material = .knob_lens }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, m.box);
    ctx.layout();
    a11y_preferences.set(.{ .reduce_transparency = true });
    runBeforeRenderHooks(m.box);
    const gp = m.box.children.items[0].style.glass_params().?;
    try std.testing.expect(gp.a11y_exempt);
    try std.testing.expectApproxEqAbs(@as(f32, -0.55), gp.knob_rim_light[1], 1e-6); // Reduce Transparency: two-color rim unchanged
    a11y_preferences.set(.{ .increase_contrast = true });
    runBeforeRenderHooks(m.box);
    const ic = m.box.children.items[0].style.glass_params().?;
    try std.testing.expectEqual(@as(f32, 0), ic.knob_rim_light[1]); // full circle
    try std.testing.expectEqual(@as(f32, 1), ic.knob_rim_dark[3]);
}

test "GlassBox: AppKit NSGlassEffectView defaults and contentView clipping" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.tokens = &theme.light;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    // NSGlassEffectView().cornerRadius == 8, .style == .regular, tintColor == nil
    const props: GlassBoxProps = .{};
    try std.testing.expect(props.corner_radius == null);
    try std.testing.expectEqual(@as(f32, 8), profile.macos.default_corner_radius);
    try std.testing.expectEqual(GlassEffectStyle.regular, props.glass_style);
    try std.testing.expect(props.tint_color == null);
    try std.testing.expectEqual(ScrollEdgeStyle.automatic, (ScrollEdgeBinding{ .scroll = undefined }).style);
    const g = try GlassBox(.{ .width = 120, .height = 44 }).mount(scope, ctx);
    defer ctx.freeNode(g);
    // The contentView (not the glass surface: its rim must not be cut) is clipped to the glass
    // shape; hit testing keeps the rectangular bounds (AppKit hitTest:).
    const surface = g.children.items[0];
    const content = surface.children.items[0];
    try std.testing.expect(!surface.style.overflow_hidden);
    try std.testing.expect(content.style.overflow_hidden);
    try std.testing.expect(content.style.clip_shape() == .auto);
    try std.testing.expect(content.style.getExt().hit_clip_shape.? == .rect);
}

test "GlassBox: tintColor alpha mixes the untinted glass toward the fully tinted glass" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const tokens = &theme.light;
    const red = Color.rgba(255, 51, 51, 255);
    const plain = resolvedGlassBoxStyle(&profile.macos, tokens, .preferred, .regular, .regular, null, 120, 60, 12, null, .light);
    const full = resolvedGlassBoxStyle(&profile.macos, tokens, .preferred, .regular, .regular, red, 120, 60, 12, null, .light);
    const half = resolvedGlassBoxStyle(&profile.macos, tokens, .preferred, .regular, .regular, red.withAlpha(128), 120, 60, 12, null, .light);
    const none = resolvedGlassBoxStyle(&profile.macos, tokens, .preferred, .regular, .regular, red.withAlpha(0), 120, 60, 12, null, .light);

    // Opaque tint is the plain absorption material (no surface share).
    try std.testing.expectEqual(@as(f32, 1.0), full.glass.tint_amount);
    try std.testing.expect(full.glass.base_veil == null);
    try std.testing.expectEqual(@as(f32, 0.0), full.glass.resolve().tint_mode);
    // Alpha 0 is exactly the untinted glass.
    try std.testing.expectEqual(plain.glass.glass_tint, none.glass.glass_tint);
    try std.testing.expectEqual(plain.glass.tint_mode, none.glass.tint_mode);

    // Partial: the tint branch keeps the opaque tint material, the surface share keeps the
    // untinted veil and transmission transforms; the shader mixes them by alpha.
    try std.testing.expectEqual(full.glass.glass_tint, half.glass.glass_tint);
    try std.testing.expectEqual(plain.glass.glass_tint, half.glass.base_veil);
    try std.testing.expectEqual(plain.glass.backdrop_saturation, half.glass.backdrop_saturation);
    try std.testing.expectEqual(plain.glass.native_chroma_enabled, half.glass.native_chroma_enabled);
    const r = half.glass.resolve();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - 128.0 / 255.0), r.tint_mode, 1e-6);
    try std.testing.expect(r.base_veil[3] >= 0);
    try std.testing.expectApproxEqAbs(lerp(plain.glass.native_rim_luma, full.glass.native_rim_luma, 128.0 / 255.0), half.glass.native_rim_luma, 1e-6);
    try std.testing.expectEqual(effectiveTintColor(red.withAlpha(0)), null);
}

test "GlassIdiom: iOS coating reproduces the iOS Simulator transfer (baselines/ios-26-5-simulator-iphone-17-pro/size)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    // out = veil * a + brightness * in * (1 - a) on uniform gray, regular, light / dark family.
    const Case = struct { d: f32, dark: bool, a: f32, b: f32 };
    const cases = [_]Case{
        .{ .d = 72, .dark = false, .a = 174.0, .b = 0.3055 },
        .{ .d = 160, .dark = false, .a = 181.0, .b = 0.2847 },
        .{ .d = 72, .dark = true, .a = 28.5, .b = 0.2410 },
        .{ .d = 160, .dark = true, .a = 18.8, .b = 0.3084 },
    };
    for (cases) |c| {
        const tokens = if (c.dark) &theme.dark else &theme.light;
        const r = resolvedGlassBoxStyle(&profile.ios, tokens, .preferred, .regular, .regular, null, 2 * c.d, c.d, c.d / 4, null, if (c.dark) .dark else .light);
        const g = r.glass;
        const a: f32 = @as(f32, @floatFromInt(g.glass_tint.?.a)) / 255.0;
        const veil: f32 = @floatFromInt(g.glass_tint.?.r);
        for ([_]f32{ 64, 128, 224 }) |in| {
            const out = veil * a + g.backdrop_brightness * in * (1 - a);
            try std.testing.expectApproxEqAbs(c.a + c.b * in, out, 2.5);
        }
    }
    // Compact (d <= 60): the measured knee curves, not an affine line.
    const Point = struct { in: f32, out: f32 };
    for ([_]bool{ false, true }) |dark| {
        const tokens = if (dark) &theme.dark else &theme.light;
        const g = resolvedGlassBoxStyle(&profile.ios, tokens, .preferred, .regular, .regular, null, 104, 52, 13, null, if (dark) .dark else .light).glass;
        const curve = g.veil_curve.?;
        try std.testing.expectEqual(@as(f32, 1.0), g.backdrop_brightness);
        const pts: [3]Point = if (dark) .{ .{ .in = 64, .out = 42 }, .{ .in = 128, .out = 89 }, .{ .in = 192, .out = 103 } } else .{ .{ .in = 64, .out = 174 }, .{ .in = 128, .out = 205 }, .{ .in = 224, .out = 247 } };
        for (pts) |pt| {
            const x = pt.in / 16.0;
            const k: usize = @intFromFloat(@floor(x));
            const out = lerp(curve[k], curve[@min(k + 1, 16)], x - @floor(x)) * 255.0;
            try std.testing.expectApproxEqAbs(pt.out, out, 1.0);
        }
    }
    // Non-compact iOS and every macOS glass keep the affine blend (no curve).
    try std.testing.expect(resolvedGlassBoxStyle(&profile.ios, &theme.light, .preferred, .regular, .regular, null, 240, 120, 30, null, .light).glass.veil_curve == null);
    try std.testing.expect(resolvedGlassBoxStyle(&profile.macos, &theme.light, .preferred, .regular, .regular, null, 104, 52, 13, null, .light).glass.veil_curve == null);
    // macOS keeps its own coating: light 213 + 0.137 in.
    const m = resolvedGlassBoxStyle(&profile.macos, &theme.light, .preferred, .regular, .regular, null, 240, 120, 30, null, .light).glass;
    const ma: f32 = @as(f32, @floatFromInt(m.glass_tint.?.a)) / 255.0;
    try std.testing.expectApproxEqAbs(@as(f32, 213.0 + 0.137 * 128.0), @as(f32, @floatFromInt(m.glass_tint.?.r)) * ma + 128.0 * (1 - ma), 1.5);
    // Shadow: macOS keeps its size-independent alphas (0.095 light / 0.039 dark); the iOS dark
    // family deepens with size and compact light glass casts a stronger shadow.
    const shadow = struct {
        fn alpha(p: *const GlassProfile, d: f32, dark: bool) u8 {
            const tk = if (dark) &theme.dark else &theme.light;
            return resolvedGlassBoxStyle(p, tk, .preferred, .regular, .regular, null, 2 * d, d, d / 4, null, if (dark) .dark else .light).shadow.color.a;
        }
    };
    try std.testing.expectEqual(@as(u8, 24), shadow.alpha(&profile.macos, 120, false)); // 0.095 * 255
    try std.testing.expectEqual(@as(u8, 9), shadow.alpha(&profile.macos, 120, true)); // 0.039 * 255
    try std.testing.expect(shadow.alpha(&profile.ios, 160, true) > 2 * shadow.alpha(&profile.ios, 72, true));
    try std.testing.expect(shadow.alpha(&profile.ios, 52, false) > shadow.alpha(&profile.ios, 120, false));
    // Chroma gain: iOS light glass is more saturated than macOS at the same size.
    const sat_ios = resolvedGlassBoxStyle(&profile.ios, &theme.light, .preferred, .regular, .regular, null, 200, 100, 25, null, .light).glass;
    const sat_mac = resolvedGlassBoxStyle(&profile.macos, &theme.light, .preferred, .regular, .regular, null, 200, 100, 25, null, .light).glass;
    const gain = struct {
        fn of(g: core.GlassParams) f32 {
            return g.backdrop_saturation * (1.0 - @as(f32, @floatFromInt(g.glass_tint.?.a)) / 255.0);
        }
    };
    try std.testing.expect(gain.of(sat_ios) > gain.of(sat_mac) * 1.1);
    // Tinted glass flips family on iOS only (native 120 x 60 red tint over black: light
    // appearance reads the dark-appearance value on iOS, not on macOS).
    try std.testing.expect(adaptsFamily(&profile.ios.family, .regular, true));
    try std.testing.expect(!adaptsFamily(&profile.macos.family, .regular, true));
    try std.testing.expect(!adaptsFamily(&profile.ios.family, .clear, false));
    // Family thresholds: iOS flips a 56-luma-and-below backdrop to dark; 64 stays light.
    try std.testing.expect(adaptiveFamilyStep(&profile.ios.family, false, 52, .regular, false, 48.0 / 255.0, false));
    try std.testing.expect(!adaptiveFamilyStep(&profile.ios.family, false, 52, .regular, false, 64.0 / 255.0, false));
    try std.testing.expect(adaptiveFamilyStep(&profile.ios.family, true, 52, .regular, false, 224.0 / 255.0, true) == false);
}

test "GlassBox: a fresh adaptive glass is visible from its first frame and switches on the native schedule" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.tokens = &theme.light;
    ctx.setTheme(&theme.light);
    ctx.backdrop_luminance_readback = true;
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const g = try GlassBox(.{ .width = 120, .height = 44, .shape = .capsule, .title = "Today" }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, g.box);
    ctx.layout();
    ctx.frame_dt_seconds = 1.0 / 60.0;
    // first frame: drawn (encoded), full material, content shown, appearance (light) family
    ctx.glass_encoded_owners[0] = g.state.surface.id;
    ctx.glass_encoded_count = 1;
    runBeforeRenderHooks(g.box);
    try std.testing.expectApproxEqAbs(@as(f32, 1), g.state.materialize_level, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), g.state.content.getOpacity(), 1e-6);
    // what the renderer gets: the full material, not a materialize-0 pass-through
    const first = g.box.children.items[0].style.glass_params().?;
    try std.testing.expect(first.glass_intensity > 0.9);
    try std.testing.expect(first.glass_tint.?.a > 100);
    try std.testing.expect(!g.state.family_dark);
    // the dark reading lands 3 frames later (readback latency)
    var t_ms: f64 = 0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        t_ms += 1000.0 / 60.0;
        ctx.frame_time_ms = t_ms;
        runBeforeRenderHooks(g.box);
    }
    ctx.backdrop_luminance_regions[0] = .{ .node_id = g.state.surface.id, .lum = 0.01, .lum_srgb = 20.0 / 255.0 };
    ctx.backdrop_luminance_region_count = 1;
    // native: the switch to dark starts ~150 ms after the glass first appeared
    var mix_at_140: f32 = -1;
    while (t_ms < 260) {
        t_ms += 1000.0 / 60.0;
        ctx.frame_time_ms = t_ms;
        runBeforeRenderHooks(g.box);
        if (t_ms <= 140) mix_at_140 = g.state.family_mix;
    }
    try std.testing.expect(g.state.family_dark);
    try std.testing.expectApproxEqAbs(@as(f32, 0), mix_at_140, 1e-4);
    try std.testing.expect(g.state.family_mix > 0.05);
}

test "GlassBox: in dark appearance a compact element flipped to the light family renders light material" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.tokens = &theme.dark;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const m = try GlassBox(.{ .width = 104, .height = 52 }).mountWithState(scope, ctx);
    defer ctx.freeNode(m.box);
    try std.testing.expect(m.state.family_dark); // a fresh effect starts in the appearance family
    glassSetFamilyImmediate(m.state, false); // bright backdrop: flipped to light (iOS 224, macOS 232)
    const light = familyStyle(m.state, .preferred, .regular, .regular, null, 104, 52);
    glassSetFamilyImmediate(m.state, true);
    const dark = familyStyle(m.state, .preferred, .regular, .regular, null, 104, 52);
    try std.testing.expect(light.glass.glass_tint.?.r > 200);
    try std.testing.expect(dark.glass.glass_tint.?.r < 60);
    // clear follows the appearance whatever the tracked family
    const clear = familyStyle(m.state, .preferred, .regular, .clear, null, 104, 52);
    glassSetFamilyImmediate(m.state, false);
    try std.testing.expectEqual(clear.glass.glass_tint, familyStyle(m.state, .preferred, .regular, .clear, null, 104, 52).glass.glass_tint);
}

test "GlassBox: re-entering the adaptive family starts from the appearance (no light flash in dark appearance)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.tokens = &theme.dark;
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const m = try GlassBox(.{ .width = 104, .height = 52, .tint_color = Color.rgba(0, 122, 255, 255) }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, m.box);
    ctx.layout();
    // Tinted: not adaptive; its tracked family has decayed to the light end.
    runBeforeRenderHooks(m.box);
    try std.testing.expect(!m.state.family_adaptive);
    glassSetFamilyImmediate(m.state, false);
    // Clearing the tint makes it adaptive again: dark appearance, so dark family on that frame.
    m.state.tint_override = null;
    runBeforeRenderHooks(m.box);
    try std.testing.expect(m.state.family_adaptive);
    try std.testing.expect(m.state.family_dark);
    try std.testing.expectEqual(@as(f32, 1), m.state.family_mix);
    const gp = m.box.children.items[0].style.glass_params().?;
    try std.testing.expect(gp.glass_tint.?.r < 60); // dark coating, not the light end
    // Clear glass keeps the pre-fix endpoints: a dark tracked family renders dark material
    // (it decays toward the appearance instead of jumping to it).
    ctx.tokens = &theme.light;
    m.state.theme_tokens = &theme.light;
    glassSetFamilyImmediate(m.state, true);
    const clear_dark = familyStyle(m.state, .preferred, .regular, .clear, null, 104, 52);
    glassSetFamilyImmediate(m.state, false);
    const clear_light = familyStyle(m.state, .preferred, .regular, .clear, null, 104, 52);
    try std.testing.expect(clear_dark.glass.native_tint_dark > 0.99);
    try std.testing.expect(clear_light.glass.native_tint_dark < 0.01);
}

test "GlassBox: single-radius glass shapes (arrow, tab lens) clip and hit with the corner the glass draws" {
    // Concentric glass whose corners differ: only the plain shape keeps them per corner. A popover
    // arrow or a tab lens silhouette carries one radius in the glass shader (and in the encoder,
    // backdrop_blur.shapeRadii), so the surface, the content clip and the root hit / shadow shape
    // take the same largest corner instead of disagreeing with the drawn glass.
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 400 }, .direction = .row }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Case = struct { arrow: ?GlassArrow, material: GlassMaterial, want: CornerRadius };
    const cases = [_]Case{
        .{ .arrow = null, .material = .standard, .want = .{ .each = .{ 12, 0, 0, 0 } } },
        .{ .arrow = .{}, .material = .standard, .want = CornerRadius.uniform(12) },
        .{ .arrow = null, .material = .tab_lens, .want = CornerRadius.uniform(12) },
    };
    var mounts: [cases.len]GlassBoxMount = undefined;
    for (cases, 0..) |c, i| {
        // Container shape radius 30, glass inset (6, 18): TL = 30 - 18 = 12, the far corners 0.
        const container = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 }, .padding = .{ .left = 6, .top = 18 } }, .{});
        try root.appendChild(std.testing.allocator, container);
        try concentric_mod.containerShape(container, ctx.allocator, 30);
        mounts[i] = try GlassBox(.{ .width = 120, .height = 60, .shape = .{ .concentric = 0 }, .arrow = c.arrow, .material = c.material }).mountWithState(scope, ctx);
        try container.appendChild(std.testing.allocator, mounts[i].box);
    }
    ctx.layout();
    for (cases, mounts) |c, m| {
        runBeforeRenderHooks(m.box);
        try std.testing.expectEqual([4]f32{ 12, 0, 0, 0 }, m.state.corner_radii.?);
        try std.testing.expectEqual(c.want, m.state.surface.style.ext.?.corner_radius.?);
        try std.testing.expectEqual(c.want, m.state.content.style.ext.?.corner_radius.?);
        try std.testing.expectEqual(c.want, m.box.style.ext.?.corner_radius.?);
    }
}

test "GlassBox bounded sidebar keeps scroll viewport below content height" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 }, .direction = .column }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const glass = try GlassBox(.{ .width = 200, .height = 1, .padding = Padding.ZERO, .body_gap = 0 }).mountWithState(scope, ctx);
    glass.box.style.height = .{ .grow = .{ .min = 0 } };
    try root.appendChild(ctx.allocator, glass.box);
    const scroll = try @import("../scroll_area/mod.zig").ScrollArea(.{ .direction = .vertical }).mount(scope, ctx);
    try glass.body.appendChild(ctx.allocator, scroll.container);
    const content = try box(ctx, .{ .width = .{ .px = 180 }, .height = .{ .px = 4000 } }, .{});
    try scroll.content.appendChild(ctx.allocator, content);
    ctx.layout();
    try std.testing.expect(glass.box.rectFromWorldOrFallback().h <= 1000);
    try std.testing.expect(scroll.container.rectFromWorldOrFallback().h <= 1000);
    try std.testing.expect(scroll.content.rectFromWorldOrFallback().h >= 4000);
}
