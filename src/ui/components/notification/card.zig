//! Node building and content layer replacement for a single notification card.
//!
//! Structure (designs 16.2 / 16.3):
//!
//!   positioner      absolute, translate/scale/opacity carrier, z-order
//!   |-- glass_root   GlassBox (regular glass, corner 18), like AppKit NSGlassEffectView /
//!   |  |            SwiftUI .glassEffect(.regular): coating, edge highlight, shadow, brightness
//!   |  |            family and unfocused flatten all come from GlassBox; don't paint material
//!   |  |            layers. Collapse clip height here.
//!   |  |-- surface   GlassBox body: content layer + lifebar (glass surface with corner clip)
//!   |     |-- content  content layer (replaced entirely on in-place morph, shell unchanged)
//!   |     |-- lifebar  bottom 1.5px lifebar
//!   |-- close        top-left 20x20 close button (occludes icon corner)
//!
//! Fade and scale use the positioner's real opacity / scale: glass samples the background by world
//! coords in the offscreen composite layer, so glass + blurred backdrop composite as a whole.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const svg_assets = @import("../../svg_assets.zig");
const icons = @import("zenit_system_icons");
const render_engine = @import("../../core/render_engine/mod.zig");
const DrawContext = render_engine.DrawContext;
const button_mod = @import("../button/mod.zig");
const hooks = @import("../../hooks.zig");
const input_mod = @import("../input/mod.zig");
const TextInputState = @import("../input/state.zig").TextInputState;

const model = @import("model.zig");
const glass_box = @import("../glass_box/mod.zig");
const styles = @import("styles.zig");
const hint_mod = @import("hint.zig");
const M = styles.Metrics;

// Public types (re-exported by mod.zig)

/// Icon slot (32x32 at line start) presentation.
pub const Lead = enum {
    /// Semantic color rounded square + white glyph (default).
    chip,
    /// Semantic color square + rotating indicator (progress default).
    spinner,
    /// Countdown ring + center remaining seconds (undo default).
    ring,
    /// Circular avatar + first letter (avatar default).
    avatar,
    /// Small dot without solid backing (quiet default).
    dot,
};

pub const Action = struct {
    label: []const u8,
    /// Primary button: heavier neutral backing + 600 weight, still uncolored.
    primary: bool = false,
    /// Marker to distinguish buttons in callbacks.
    tag: []const u8 = "",
    /// Button-embedded keycap (capsule hint button only, e.g. "Cmd+Z").
    shortcut: []const u8 = "",
};

pub const Progress = struct {
    /// 0..1
    value: f32 = 0,
    /// Left-side status text, e.g. "uploading ... est 4s".
    label: []const u8 = "",
    /// Right-side n / N count (monospace).
    count: []const u8 = "",
};

/// Reply box quote line after send (in-place conversion part).
pub const Quote = struct {
    text: []const u8,
};

/// Normalized content description; string owned by Card arena.
pub const ContentSpec = struct {
    kind: model.Kind = .default,
    tone: model.Tone = .info,
    lead: Lead = .chip,
    glyph: ?svg_assets.Asset = null,
    avatar: []const u8 = "",
    title: []const u8 = "",
    body: []const u8 = "",
    actions: []const Action = &.{},
    reply: bool = false,
    quote: ?[]const u8 = null,
    progress: ?Progress = null,
    /// Whether to show bottom lifebar.
    life_bar: bool = true,
    /// Caption hint (kind = .hint) line-start marker and keycap row.
    hint_mark: hint_mod.Mark = .none,
    keycap: ?hint_mod.Keycap = null,
};

pub const Strings = struct {
    now: []const u8 = "now",
    /// `{d}` replaced with number.
    minutes_ago: []const u8 = "{d}m ago",
    hours_ago: []const u8 = "{d}h ago",
    days_ago: []const u8 = "{d}d ago",
    undo: []const u8 = "Undo",
    reply_placeholder: []const u8 = "Reply…",
    send: []const u8 = "Send",
    close: []const u8 = "Dismiss notification",
    /// Collapsed-state badge: `{d}` = remaining count.
    more: []const u8 = "{d} more · hover to expand",
    paused: []const u8 = "Paused while hovering",
    /// Badge-next "clear all" button hover-expand text.
    clear_all: []const u8 = "Clear all",
};

pub fn defaultGlyph(tone: model.Tone) svg_assets.Asset {
    return switch (tone) {
        .success => icons.check,
        .@"error" => icons.close,
        .warning => icons.warning,
        .info => icons.info,
        .violet => icons.plus,
        .quiet => icons.info,
    };
}

pub fn defaultLead(kind: model.Kind, tone: model.Tone, has_avatar: bool) Lead {
    return switch (kind) {
        .progress => .spinner,
        .undo => .ring,
        .hint => .chip,
        .default => if (has_avatar) .avatar else if (tone == .quiet) .dot else .chip,
    };
}

/// Format to buf per `{d}` template.
pub fn formatCount(buf: []u8, template: []const u8, n: u64) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (std.mem.indexOf(u8, template, "{d}")) |at| {
        w.writeAll(template[0..at]) catch return template;
        w.print("{d}", .{n}) catch return template;
        w.writeAll(template[at + 3 ..]) catch return template;
    } else {
        w.writeAll(template) catch return template;
    }
    return w.buffered();
}

// Content layer

/// Button click -> Notifier. Fixed context per button (card address + index).
pub const ButtonContext = struct {
    card: *Card,
    index: u8,
};

pub const ButtonSink = *const fn (card: *Card, index: u8) void;
/// Reply box "send" / Enter same button path, reserved index distinguishes.
pub const send_index: u8 = 0xFE;
pub const CloseSink = *const fn (card: *Card) void;

pub const Content = struct {
    /// Content layer's own scope (button / reply box), disposed wholesale on replacement.
    scope: *Scope,
    root: *Node,
    /// The following four caption hints absent (capsule single line only).
    lead_box: ?*Node = null,
    lead: ?*Node = null,
    title_row: ?*Node = null,
    title: *Node,
    timestamp: ?*Node = null,
    /// Rotating indicator (custom draw, constant rotation needs per-frame redraw).
    spinner: ?*Node = null,
    body: ?*Node = null,
    quote: ?*Node = null,
    progress_block: ?*Node = null,
    progress_fill: ?*Node = null,
    ring_secs: ?*Node = null,
    footer: ?*Node = null,
    reply_row: ?*Node = null,
    buttons: [2]?*Node = .{ null, null },
    button_contexts: [2]ButtonContext = undefined,
    send_button: ?*Node = null,
    send_context: ButtonContext = undefined,
    reply_input: ?*Node = null,
    reply_state: ?*TextInputState = null,
    /// Reply box text value (owned signal of embedded Input); programmatic write-back through it
    reply_value: ?*core.Signal([]const u8) = null,
    /// Drawn ring seconds (avoid text change every frame).
    ring_secs_shown: i32 = -1,
};

// ============================================================================
// Card
// ============================================================================

pub const Card = struct {
    allocator: Allocator,
    cx: *Cx,
    id: u64,
    seq: u64,
    /// Changes only when a new content version is successfully published.
    revision: u64 = 0,

    positioner: *Node,
    /// GlassBox root: dimension carrier (hint text with content / card full width) and collapse
    /// clip height
    glass_root: *Node,
    /// GlassBox body: container for content layer and lifebar
    surface: *Node,
    lifebar: *Node,
    close: *Node,
    close_glyph_dark: *Node,
    close_glyph_light: *Node,
    content: Content,

    /// String ownership (replace entirely by content version).
    arena: std.heap.ArenaAllocator,
    /// Card-level scope (drag binding), survives content replacement, destroyed with card.
    scope: *Scope,
    spec: ContentSpec,
    sticky: bool,

    // -- Lifecycle (frame_time_ms) --
    measured: bool = false,
    natural_height: f32 = 0,
    /// Natural width: card always full width; hint capsule with content (measured then written).
    natural_width: f32 = 0,
    born_ms: f64 = 0,
    born_wall_ms: i64 = 0,
    life: model.Life = .{},
    leaving: bool = false,
    /// Frame clock when exit starts; null = requested, awaiting next real frame timestamp (see
    /// mod.zig frame).
    left_at_ms: ?f64 = null,
    /// Never shown then closed: direct reclaim next frame, no exit animation.
    instant_exit: bool = false,
    /// Clear all exit: preserve placeholder no reflow, fade out in place.
    hold_space: bool = false,
    fling_x: f32 = 0,
    /// Whether this card closed by user (x / drag), callback distinguishes auto expiry.
    closed_by_user: bool = false,

    // -- In-place morph --
    icon_pop_at_ms: ?f64 = null,
    crossfade_at_ms: ?f64 = null,
    /// Content layer just swapped, height not yet measured: stay transparent, start bounce/fade-in
    /// after measured.
    content_pending: bool = false,

    // -- Drag --
    drag_dx: f32 = 0,
    /// Baseline offset when mouse drag starts (no jump when sweep takes over).
    drag_base: f32 = 0,
    dragging: bool = false,
    /// Drag binding (proactively cancel in-progress gesture on exit).
    drag_binding: ?*@import("../../interaction/drag.zig").Binding = null,
    /// destroyCard in progress: callbacks only reset state, no more access to Notifier / nodes.
    destroying: bool = false,
    /// Trackpad two-finger sweep drives drag (ends with gesture ended/cancelled).
    scroll_dragging: bool = false,
    /// Most recent outgoing reply (restore to input on failure).
    last_reply: ?[]u8 = null,
    spring_from: f32 = 0,
    spring_at_ms: ?f64 = null,
    spring_pending: bool = false,
    /// New lifetime after in-place morph (ms): start counting after new content layer measured
    /// height.
    life_pending_ms: ?f64 = null,

    // -- Render tracking --
    follow_y: model.Follow = .{},
    follow_x: model.Follow = .{},
    close_alpha: f32 = 0,
    close_dark: bool = false,
    /// Window-space rect of last frame (hover hit test).
    rect_x: f32 = 0,
    rect_y: f32 = 0,
    rect_w: f32 = 0,
    rect_h: f32 = 0,
    rect_visible: bool = false,
    last_ts: model.RelativeTime = .now,
    ts_initialized: bool = false,
    /// Card full width (box scale baseline).
    full_width: f32 = 392,
    /// Current layer rank (z = limit - rank).
    rank: u8 = 0,

    // ── callback ──
    button_sink: ButtonSink,
    close_sink: CloseSink,
    strings: *const Strings,
    /// Last applied alpha (custom draw use).
    draw_alpha: f32 = 0,
    /// Custom draw frame_time_ms snapshot.
    draw_now_ms: f64 = 0,

    /// Exit duration elapsed; no timestamp = just started.
    pub fn exitElapsed(self: *const Card, now: f64) f64 {
        return now - (self.left_at_ms orelse now);
    }

    pub fn isQuiet(self: *const Card) bool {
        return self.spec.tone == .quiet and self.spec.lead == .dot;
    }

    pub fn swapArena(self: *Card) std.heap.ArenaAllocator {
        const old = self.arena;
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        return old;
    }
};

// Construction

pub const BuildParams = struct {
    cx: *Cx,
    scope: *Scope,
    palette: styles.Palette,
    strings: *const Strings,
    width: f32,
};

const fixed = core.Sizing.fixed;
const fill = core.Sizing.fill();
const fit: core.Sizing = .{ .fit = .{} };

// -- Text elements --
// Text node's own box style (flex_shrink / width / max_width / margin / opacity) stacked via
// view.attrs.

pub const TextProps = struct { style: core.TextStyle };
pub const TextBoxProps = struct { style: core.BoxStyle };
pub const PlainText = view.Text(TextProps, []const u8);
pub const StyledText = view.Attrs(TextBoxProps, PlainText);

pub fn plainText(content: []const u8, style: core.TextStyle) PlainText {
    return view.text(TextProps{ .style = style }, content);
}

pub fn styledText(content: []const u8, style: core.TextStyle, box_style: core.BoxStyle) StyledText {
    return view.attrs(TextBoxProps{ .style = box_style }, plainText(content, style));
}

/// Node-level patch (setup escape hatch): component name (DevTools display name, DSL no
/// equivalent).
pub const NodeTweak = struct { name: []const u8 };

pub fn tweakNode(t: NodeTweak, node: *Node) void {
    node.meta.ownership.meta.component_name = t.name;
}

/// Shell: positioner + glass (GlassBox) + lifebar + close button. Content layer separate.
/// Declaration tree under card-level scope (freed with card), shell itself no effect.
pub fn buildShell(card: *Card, p: BuildParams) !void {
    const cx = p.cx;
    const pal = p.palette;

    const Parts = struct { glass: glass_box.GlassBoxMount, lifebar: *Node, close: *Node, glyph_dark: *Node, glyph_light: *Node };
    var s: Parts = undefined;

    const glyph_style: core.BoxStyle = .{
        .width = fixed(M.close_glyph),
        .height = fixed(M.close_glyph),
        .position = .absolute,
        .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } },
    };
    var glyph_dark_style = glyph_style;
    glyph_dark_style.opacity = 0;

    const positioner = try view.render(card.scope, cx, view.col(.{
        .style = .{
            .position = .absolute,
            .width = fixed(p.width),
            .height = fit,
            .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } },
            .hit_behavior = .self_and_children,
            // No will_change_*: idle (alpha 1, scale 1) paint directly; only offscreen layer during
            // fade/scale
            // (glass layer doesn't reuse cached texture, permanent offscreen repaints every frame).
            .corner_radius = M.radius,
            // opacity 0 measure frame still participates in layout.
            .keep_rendering_when_transparent = true,
        },
    }, .{
        // Material via GlassBox (regular): AppKit canonical is NSGlassEffectView background +
        // content on top,
        // don't paint coating / gloss / inner shadow / shadow. Content layer mounts in body (see
        // buildContent).
        view.capture(&s.glass, view.with(glass_box.GlassBox(.{
            .corner_radius = M.radius,
            .padding = Padding.all(0),
            .body_gap = 0,
        }), .{
            // Lifebar in flow: card height = content + 1.5 (design 16.2); types without lifebar
            // height 0.
            // Remaining ratio via scale_x (origin left), per-frame only change composite attrs.
            view.capture(&s.lifebar, view.box(.{
                .style = .{
                    .width = fixed(p.width),
                    .height = fixed(0),
                    .background = pal.lifeBar(.success),
                    .hit_behavior = .pass_through,
                    .transform_origin = .{ .x = .{ .px = 0 }, .y = .{ .percent = 0.5 } },
                    .flex_shrink = 0,
                    // Right corners rounded
                    .corner_radii = .{ .each = .{ 0, 1, 1, 0 } },
                },
            }, {})),
        })),
        // Close button: native-style dark circle white x, occludes top-left icon corner; invisible
        // by default.
        view.capture(&s.close, view.box(.{
            .style = .{
                .position = .absolute,
                .width = fixed(M.close_size),
                .height = fixed(M.close_size),
                .align_items = .center,
                .justify = .center,
                .background = pal.close_light,
                .border = .{ .overlay = true, .width = 0.5, .color = pal.close_light_edge, .radius = M.close_size / 2 },
                .inset = .{ .left = .{ .px = M.close_inset }, .top = .{ .px = M.close_inset } },
                .corner_radius = M.close_size / 2,
                .z_index = 10,
                .shadow = core.Shadow{ .color = pal.shadow(0.2), .blur = 3, .offset_y = 1 },
                .cursor = .pointer,
                .opacity = 0,
            },
            .hit_test = false,
            .a11y = .{ .role = .button, .label = p.strings.close },
        }, .{
            view.capture(&s.glyph_dark, view.icon(.{ .style = glyph_dark_style, .tint = pal.on_semantic }, icons.close)),
            view.capture(&s.glyph_light, view.icon(.{ .style = glyph_style, .tint = pal.close_light_glyph }, icons.close)),
        })),
    }));
    errdefer cx.freeNode(positioner);
    positioner.meta.ownership.meta.component_name = "Notification";
    const glass_root = s.glass.box;
    glass_root.style.width = .fill();
    glass_root.style.flex_shrink = 0;
    glass_root.meta.ownership.meta.component_name = "Notification.glass";
    // Collapse clips root to front height: glass surface clips excess content by corner radius
    s.glass.state.surface.style.overflow_hidden = true;
    const surface = s.glass.body;
    surface.meta.ownership.meta.component_name = "Notification.surface";
    s.close.meta.ownership.meta.component_name = "Notification.close";
    // Raw events (bottom-level on_event + context): DSL only has on_click
    s.close.behavior.events.on_event = closeEvent;
    s.close.behavior.events.event_context = @ptrCast(card);

    card.positioner = positioner;
    card.glass_root = glass_root;
    card.surface = surface;
    card.lifebar = s.lifebar;
    card.close = s.close;
    card.close_glyph_dark = s.glyph_dark;
    card.close_glyph_light = s.glyph_light;
    applyShellForm(card, p);
}

/// Shell morphs with kind switch (card <-> hint capsule): width, lifebar width. Shadow from glass.
/// Called once at build, once at in-place morph.
pub fn applyShellForm(card: *Card, p: BuildParams) void {
    const is_hint = card.spec.kind == .hint;
    const positioner = card.positioner;
    const w: core.Sizing = if (is_hint) .{ .fit = .{} } else .fixed(p.width);
    positioner.style.width = w;
    card.glass_root.style.width = if (is_hint) .{ .fit = .{} } else .fill();
    card.lifebar.style.width = .fixed(if (is_hint) 0 else p.width);
    positioner.markSizingDirty();
    card.glass_root.markSizingDirty();
    card.lifebar.markSizingDirty();
    positioner.markRenderDirty();
}

fn closeEvent(event: core.Event, context: ?*anyopaque) core.EventResult {
    if (event != .click) return .ignored;
    const card: *Card = @ptrCast(@alignCast(context orelse return .ignored));
    card.close_sink(card);
    return .stop;
}

fn buttonEvent(event: core.Event, context: ?*anyopaque) core.EventResult {
    if (event != .click) return .ignored;
    const bctx: *ButtonContext = @ptrCast(@alignCast(context orelse return .ignored));
    bctx.card.button_sink(bctx.card, bctx.index);
    return .stop;
}

/// Build and mount content layer to surface (after gloss layer, before lifebar).
pub fn buildContent(card: *Card, p: BuildParams) !Content {
    if (card.spec.kind == .hint) {
        var content = try hint_mod.buildContent(card, p);
        errdefer destroyContent(p.cx, card.surface, &content);
        setLifebarHeight(card, 0);
        try card.surface.appendChild(p.cx.allocator, content.root);
        reorderSurface(card, content.root) catch {};
        return content;
    }
    const cx = p.cx;
    const pal = p.palette;
    const spec = card.spec;

    // Root scope (not under Notifier scope), released only by this card: when parent scope
    // disposes,
    // recursively destroys child scopes first then runs resource callbacks. If mounted as child
    // scope, Notifier's
    // cleanup callback reads content.scope when it's already freed. Button each has its own scope,
    // bound to button
    // node, node unmounts first so no effect here.
    const scope = try Scope.init(p.scope.allocator, null, p.scope.owner);
    errdefer scope.dispose();

    var content = Content{ .scope = scope, .root = undefined, .title = undefined };
    var actions_row: ?*Node = null;
    const lead_px: f32 = if (spec.lead == .ring) M.ring_size else M.lead_size;
    const tone = pal.tone(spec.tone);
    const prog = spec.progress orelse Progress{};
    const chip_like = spec.lead == .chip or spec.lead == .spinner;

    const root = try view.render(scope, cx, view.col(.{ .style = .{ .width = fixed(p.width), .height = fit, .flex_shrink = 0 } }, .{
        view.row(.{ .style = .{ .width = fill, .align_items = .start, .gap = M.row_gap, .padding = M.row_padding } }, .{
            // -- Row-start icon position --
            view.capture(&content.lead_box, view.box(.{ .style = .{
                .width = fixed(lead_px),
                .height = fixed(lead_px),
                .align_items = .center,
                .justify = .center,
                .flex_shrink = 0,
            } }, .{
                // Transparent lead box with semantic-color glyph / spinner
                if (chip_like) view.capture(&content.lead, view.box(.{ .style = .{
                    .width = fixed(M.lead_size),
                    .height = fixed(M.lead_size),
                    .align_items = .center,
                    .justify = .center,
                    .background = Color.TRANSPARENT,
                    .border = .{ .overlay = true, .width = 0, .color = tone, .radius = M.chip_radius },
                    .corner_radius = M.chip_radius,
                } }, view.branch(
                    spec.lead == .chip,
                    view.icon(.{
                        .style = .{ .width = fixed(M.glyph_size), .height = fixed(M.glyph_size) },
                        .tint = tone,
                    }, spec.glyph orelse defaultGlyph(spec.tone)),
                    view.capture(&content.spinner, view.setup(view.box(.{ .style = .{
                        .width = fixed(M.spinner_size),
                        .height = fixed(M.spinner_size),
                    } }, {}), card, setSpinnerDraw)),
                ))) else null,
                // Ring itself is custom draw node (doesn't paint children), seconds as sibling
                // absolutely positioned at center.
                if (spec.lead == .ring) view.capture(&content.lead, view.setup(view.box(.{ .style = .{
                    .width = fixed(M.ring_size),
                    .height = fixed(M.ring_size),
                } }, {}), card, setRingDraw)) else null,
                if (spec.lead == .ring) view.box(.{ .style = .{
                    .position = .absolute,
                    .width = fixed(M.ring_size),
                    .height = fixed(M.ring_size),
                    .align_items = .center,
                    .justify = .center,
                    .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } },
                } }, view.capture(&content.ring_secs, plainText("", .{
                    .color = pal.ink,
                    .font_size = M.ring_secs_size,
                    .font_weight = 600,
                    .use_monospace_font = true,
                }))) else null,
                if (spec.lead == .avatar) view.capture(&content.lead, view.box(.{ .style = .{
                    .width = fixed(M.lead_size),
                    .height = fixed(M.lead_size),
                    .align_items = .center,
                    .justify = .center,
                    .background = pal.avatar_bg,
                    .border = .{ .overlay = true, .width = 0, .color = pal.avatar_bg, .radius = M.lead_size / 2 },
                    .corner_radius = M.lead_size / 2,
                } }, plainText(spec.avatar, .{ .color = pal.avatar_fg, .font_size = M.avatar_initial_size, .font_weight = 600 }))) else null,
                if (spec.lead == .dot) view.capture(&content.lead, view.box(.{ .style = .{
                    .width = fixed(M.quiet_dot),
                    .height = fixed(M.quiet_dot),
                    .background = tone,
                    .border = .{ .overlay = true, .width = 0, .color = tone, .radius = M.quiet_dot / 2 },
                    .corner_radius = M.quiet_dot / 2,
                } }, {})) else null,
            })),
            // -- Text row --
            view.col(.{ .style = .{ .width = fill, .gap = M.content_gap } }, .{
                view.capture(&content.title_row, view.row(.{ .style = .{ .width = fill, .align_items = .center, .gap = M.title_gap } }, .{
                    view.capture(&content.title, plainText(spec.title, .{
                        .color = pal.ink,
                        .font_size = M.title_size,
                        .font_weight = M.title_weight,
                        .wrap = .word_break,
                        .line_height = M.title_line_height,
                    })),
                    view.capture(&content.timestamp, styledText(p.strings.now, .{
                        .color = pal.ink_3,
                        .font_size = M.timestamp_size,
                        .line_height = M.timestamp_line_height,
                        .use_monospace_font = true,
                    }, .{ .flex_shrink = 0 })),
                })),
                if (spec.body.len > 0) view.capture(&content.body, plainText(spec.body, .{
                    .color = pal.ink_2,
                    .font_size = M.body_size,
                    .line_height = M.body_line_height,
                    .wrap = .word_break,
                    .max_lines = M.body_max_lines,
                })) else null,
                if (spec.quote) |q| view.capture(&content.quote, view.row(.{ .style = .{
                    .width = fill,
                    .gap = 6,
                    .padding = .{ .top = 4, .right = 0, .bottom = 0, .left = 8 },
                    .border = .{ .overlay = true, .width = 0, .color = pal.separator, .radius = 0 },
                } }, .{
                    view.box(.{ .style = .{ .width = fixed(2), .height = fill, .background = pal.track } }, {}),
                    plainText(q, .{ .color = pal.ink_2, .font_size = M.body_size, .line_height = M.body_line_height, .wrap = .word_break, .max_lines = 2 }),
                })) else null,
                if (spec.progress != null) view.capture(&content.progress_block, view.col(.{ .style = .{
                    .width = fill,
                    .gap = 5,
                    .padding = M.progress_padding,
                } }, .{
                    view.box(.{ .style = .{
                        .width = fill,
                        .height = fixed(M.progress_track),
                        .background = pal.track,
                        .border = .{ .overlay = true, .width = 0, .color = pal.track, .radius = M.progress_track / 2 },
                        .corner_radius = M.progress_track / 2,
                        .overflow_hidden = true,
                    } }, view.capture(&content.progress_fill, view.box(.{ .style = .{
                        .width = core.Sizing.pct(model.clamp01(prog.value) * 100),
                        .height = fill,
                        .background = pal.info,
                        .border = .{ .overlay = true, .width = 0, .color = pal.info, .radius = M.progress_track / 2 },
                        .corner_radius = M.progress_track / 2,
                    } }, {}))),
                    view.row(.{ .style = .{ .width = fill, .align_items = .center, .gap = 8 } }, .{
                        styledText(prog.label, .{ .color = pal.ink_3, .font_size = M.meta_size, .line_height = M.meta_line_height }, .{ .width = fill }),
                        styledText(prog.count, .{
                            .color = pal.ink_2,
                            .font_size = M.meta_size,
                            .font_weight = 600,
                            .line_height = M.meta_line_height,
                            .use_monospace_font = true,
                        }, .{ .flex_shrink = 0 }),
                    }),
                })) else null,
            }),
        }),
        // -- Separate button area below divider / reply input --
        if (spec.actions.len > 0 or spec.reply) view.capture(&content.footer, view.col(.{ .style = .{ .width = fill } }, .{
            view.box(.{ .style = .{ .width = fill, .height = fixed(M.separator), .background = pal.separator } }, {}),
            view.capture(&actions_row, view.row(.{ .style = .{
                .width = fill,
                .align_items = .center,
                .gap = M.footer_gap,
                .padding = M.footer_padding,
            } }, if (!spec.reply) view.items(ActionCtx{ .content = &content, .pal = pal }, spec.actions[0..@min(spec.actions.len, 2)], actionElement) else null)),
        })) else null,
    }));
    errdefer cx.freeNode(root);
    root.meta.ownership.meta.component_name = "Notification.content";
    content.root = root;

    if (actions_row) |actions| {
        if (spec.reply) {
            content.reply_row = actions;
            try buildReply(card, p, scope, actions, &content);
        }
    }

    setLifebarHeight(card, if (spec.life_bar) M.life_bar else 0);

    // Insert before lifebar: gloss layer below, content middle, lifebar top.
    try card.surface.appendChild(cx.allocator, root);
    reorderSurface(card, root) catch {};
    return content;
}

const ActionCtx = struct { content: *Content, pal: styles.Palette };
const ActionButton = view.NodeCapture(*?*Node, view.Setup(button_mod.ButtonBuilder, NodeTweak, tweakNode));

/// Action buttons (up to 2). Event context points to stable address in card.content: content
/// returns by value,
/// caller calls rebindButtons after content lands to write it.
fn actionElement(c: ActionCtx, action: Action, i: usize) ActionButton {
    const pal = c.pal;
    const bg = if (action.primary) pal.button_primary else pal.button_secondary;
    const bg_hover = if (action.primary) pal.button_primary_hover else pal.button_secondary_hover;
    const bg_pressed = if (action.primary) pal.button_primary_pressed else pal.button_secondary_pressed;
    return view.capture(&c.content.buttons[i], view.setup(button_mod.Button(.{
        .label = action.label,
        .variant = .secondary,
        .size = .sm,
        .block = true,
        .on_event = buttonEvent,
        .event_context = null,
        .base_style = core.StyleOverride{
            .width = .fill(),
            .height = .fixed(M.button_height),
            .background = bg,
            .border = .{ .overlay = true, .width = if (action.primary) @as(f32, 0) else @as(f32, 1), .color = pal.separator, .radius = M.button_radius },
            .text_color = if (action.primary) pal.on_semantic else pal.ink,
            .font_size = M.button_font,
            .font_weight = if (action.primary) 600 else 500,
        },
        .hover_style = .{ .background = bg_hover, .border = .{ .overlay = true, .width = if (action.primary) @as(f32, 0) else @as(f32, 1), .color = pal.separator, .radius = M.button_radius } },
        .pressed_style = .{ .background = bg_pressed, .border = .{ .overlay = true, .width = if (action.primary) @as(f32, 0) else @as(f32, 1), .color = pal.separator, .radius = M.button_radius } },
    }), NodeTweak{ .name = "Notification.action" }, tweakNode));
}

fn setSpinnerDraw(card: *Card, node: *Node) void {
    node.setCustomDraw(spinnerDraw, @ptrCast(card));
}

fn setRingDraw(card: *Card, node: *Node) void {
    node.setCustomDraw(ringDraw, @ptrCast(card));
}

fn setLifebarHeight(card: *Card, bar_h: f32) void {
    if (card.lifebar.style.height != .px or card.lifebar.style.height.px != bar_h) {
        card.lifebar.style.height = .fixed(bar_h);
        card.lifebar.markSizingDirty();
    }
}

fn buildReply(card: *Card, p: BuildParams, scope: *Scope, row: *Node, content: *Content) !void {
    const cx = p.cx;
    const pal = p.palette;
    var field: *Node = undefined;
    try view.mount(scope, cx, row, view.capture(&field, view.row(.{ .style = .{
        .width = fill,
        .height = fixed(M.reply_height),
        .align_items = .center,
        .gap = 8,
        .padding = M.reply_padding,
        .background = pal.reply_field,
        .border = .{ .overlay = true, .width = 0.5, .color = pal.reply_border, .radius = M.button_radius },
        .corner_radius = M.button_radius,
    } }, {})));

    // Embedded mode: keep only text editing, shell drawn here (same as ComboBox).
    // Must hand-rewrite mountResult's internal handles (state / input_container / value) per item,
    // keep imperative mount.
    const result = try input_mod.Input(.{
        .placeholder = p.strings.reply_placeholder,
        .placeholder_color = pal.ink_3,
        .size = .sm,
        .embedded = true,
        // field_style lands in the caller overlay layer, above inline and declarative layers,
        // so it survives layer recomputes (unlike direct node.style writes).
        .field_style = .{
            .height = .{ .px = M.reply_height - 2 },
            .border_width = 0,
            .padding = Padding.ZERO,
            .background = Color.TRANSPARENT,
            .border_color = Color.TRANSPARENT,
        },
    }).mountResult(scope, cx);
    field.appendChild(cx.allocator, result.node) catch |err| {
        result.abandon(cx);
        return err;
    };
    // width grow / flex_shrink declared by embedded Input's wrapper itself.
    // Horizontal padding handled by reply shell (left 11); Input internal layer (sm 8) zeros out,
    // cursor hit test reads same padding_h, appearance and hit align.
    result.state.padding_h = 0;
    result.input_container.markSizingDirty();
    result.node.behavior.events.key_context = @ptrCast(card);
    result.node.behavior.events.on_key_down = replyKeyDown;
    content.reply_input = result.input_container;
    content.reply_state = result.state;
    content.reply_value = result.value;
    result.node.meta.ownership.meta.component_name = "Notification.reply";

    try view.mount(scope, cx, field, .{
        styledText("↵", .{ .color = pal.ink_3, .font_size = M.timestamp_size }, .{ .flex_shrink = 0 }),
        view.capture(&content.send_button, view.attrs(.{ .style = core.BoxStyle{ .flex_shrink = 0 } }, view.setup(button_mod.Button(.{
            .label = p.strings.send,
            .variant = .secondary,
            .size = .xs,
            .on_event = buttonEvent,
            // With type name: props collapse via anytype, nested literals' `.fixed(...)` need known
            // result type
            .base_style = core.StyleOverride{
                .height = .fixed(M.send_height),
                .padding = Padding.symmetric(0, 10),
                .background = pal.button_primary,
                .border = .{ .overlay = true, .width = 0, .color = pal.button_primary, .radius = M.send_radius },
                .text_color = pal.on_semantic,
                .font_size = M.send_font,
                .font_weight = 600,
            },
            .hover_style = .{ .background = pal.button_primary_hover, .border = .{ .overlay = true, .width = 0, .color = pal.button_primary_hover, .radius = M.send_radius } },
            .pressed_style = .{ .background = pal.button_primary_hover, .border = .{ .overlay = true, .width = 0, .color = pal.button_primary_hover, .radius = M.send_radius } },
        }), NodeTweak{ .name = "Notification.send" }, tweakNode))),
    });
}

fn replyKeyDown(key: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) core.EventResult {
    if (key != .@"return") return .ignored;
    const card: *Card = @ptrCast(@alignCast(context orelse return .ignored));
    const state = card.content.reply_state orelse return .ignored;
    // Enter during IME composition is candidate confirmation, not submit.
    if (state.imeIsComposing()) return .ignored;
    card.button_sink(card, send_index);
    return .stop;
}

/// Button context points to array element in card.content; called after content lands.
pub fn rebindButtons(card: *Card) void {
    if (card.content.send_button) |send| {
        card.content.send_context = .{ .card = card, .index = send_index };
        send.behavior.events.event_context = @ptrCast(&card.content.send_context);
    }
    for (card.content.buttons, 0..) |maybe, i| {
        if (maybe) |btn| {
            card.content.button_contexts[i] = .{ .card = card, .index = @intCast(i) };
            btn.behavior.events.event_context = @ptrCast(&card.content.button_contexts[i]);
        }
    }
}

fn reorderSurface(card: *Card, content_root: *Node) !void {
    var order: [8]*Node = undefined;
    var n: usize = 0;
    for (card.surface.children.items) |child| {
        if (child == card.lifebar or child == content_root) continue;
        order[n] = child;
        n += 1;
    }
    order[n] = content_root;
    n += 1;
    order[n] = card.lifebar;
    n += 1;
    try card.surface.replaceChildOrder(card.cx.allocator, order[0..n]);
}

/// Destroy content layer: invalidate hook, dispose scope, then unlink and free (same order as For).
pub fn destroyContent(cx: *Cx, parent: *Node, content: *Content) void {
    // Button event context points to slot in card.content: on in-place morph card.content swaps to
    // new content,
    // freeing old button dispatches blur events (if focus on button), remove handler first so it
    // doesn't read new content's slot.
    for (content.buttons) |maybe| {
        if (maybe) |btn| {
            btn.behavior.events.on_event = null;
            btn.behavior.events.event_context = null;
        }
    }
    if (content.send_button) |btn| {
        btn.behavior.events.on_event = null;
        btn.behavior.events.event_context = null;
    }
    hooks.invalidateSubtreeHookState(content.root);
    if (!content.scope.disposed) content.scope.dispose();
    core.clearNodeScopes(content.root);
    if (content.root.parent != null) cx.detachChildRetained(parent, content.root);
    cx.freeNode(content.root);
}

// Custom draw: rotating indicator / countdown ring

fn spinnerDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const card: *Card = @ptrCast(@alignCast(context orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    // 260 deg arc, one rotation per 0.9s.
    const turn: f32 = @floatCast(@mod(card.draw_now_ms, 900.0) / 900.0);
    const start = -std.math.pi / 2.0 + turn * std.math.tau;
    const sweep: f32 = 260.0 / 360.0 * std.math.tau;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = M.spinner_size / 2,
        .stroke_width = M.spinner_stroke,
        .start_angle = start,
        .end_angle = start + sweep,
        .color = Color.WHITE,
    } });
}

fn ringDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const card: *Card = @ptrCast(@alignCast(context orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    const pal = styles.palette(card.cx.tokens);
    const top = -std.math.pi / 2.0;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = M.ring_size / 2,
        .stroke_width = M.ring_stroke,
        .start_angle = top,
        .end_angle = top + std.math.tau,
        .color = pal.track,
    } });
    const frac = card.life.fraction(card.draw_now_ms);
    if (frac <= 0.001) return;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = M.ring_size / 2,
        .stroke_width = M.ring_stroke,
        .start_angle = top,
        .end_angle = top + frac * std.math.tau,
        .color = pal.info,
    } });
}
