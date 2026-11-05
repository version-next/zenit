//! glass_showcase: the Liquid Glass demos recorded for the website, in the site's palette (ink,
//! an accent blue and its ordered-dither pixel fields). Three iPhone-sized screens (402 x 874,
//! idiom .ios) side by side, each recorded and cropped on its own:
//!
//!   - media:    clear glass controls over full-bleed artwork (HIG: clear only over visually
//!               rich content, with a 35% dimming layer where it is bright), one tinted action
//!   - library:  the iOS navigation bar and tab bar (regular glass) floating over a scrolling list
//!   - settings: iOS switches and a slider; they take on glass only while held (the HIG's one
//!               exception to "no glass in the content layer")
//!
//! Test ids (`showcase.*`) are what the site's capture script drives. Scrolling is animated by
//! the app itself at the display's frame rate (a harness wheel event only lands every ~30 ms):
//! keys a / s pan the media screen down / back, d / f the library list, g splits / merges the
//! media screen's header actions.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const W = ui.widgets;
const B = W.glass_bars;
const GG = W.glass_group;
const SA = W.scroll_area;
const icons = ui.icons;

// Site palette (zenit site theme.css, light).
const INK = ui.Color.rgba(28, 22, 18, 255);
const INK2 = ui.Color.rgba(74, 74, 74, 255);
const MUTE = ui.Color.rgba(107, 107, 107, 255);
const BG2 = ui.Color.rgba(245, 245, 244, 255);
const LINE = ui.Color.rgba(232, 232, 230, 255);
const ACC = ui.Color.rgba(17, 68, 170, 255);
const ACC_MID = ui.Color.rgba(112, 143, 205, 255);
const ACC_SOFT = ui.Color.rgba(207, 218, 240, 255);
const WHITE = ui.Color.rgba(255, 255, 255, 255);

/// iPhone 17 Pro screen in points; its status bar is 62 pt (UINavigationBar at y 62).
const STATUS_H: f32 = 62;
const SCREEN_W: f32 = 402;
const SCREEN_H: f32 = 874;
const GAP: f32 = 48;
const WIN_W: f32 = 3 * SCREEN_W + 4 * GAP;
const WIN_H: f32 = SCREEN_H + 2 * GAP;

// ── Scripted scrolling (keys a s d f) ─────────────────────────────────────────────────
const ScrollAnim = struct {
    sa: ?SA.ScrollAreaResult = null,
    from: f32 = 0,
    to: f32 = 0,
    t0_ms: f64 = 0,
    dur: f32 = 1,
    active: bool = false,

    fn start(self: *ScrollAnim, to: f32, dur: f32) void {
        const sa = self.sa orelse return;
        self.from = sa.state.scroll_y;
        self.to = to;
        self.t0_ms = frame_cx.?.frame_time_ms;
        self.dur = dur;
        self.active = true;
        sa.container.markRenderDirty();
    }
};
var anims = [2]ScrollAnim{ .{}, .{} };
var frame_cx: ?*ui.Cx = null;

fn tickScroll(node: *ui.Node) void {
    // Keys with nothing focused go to the window root, which the app runtime wraps around this
    // tree, and key events only bubble up: listen there.
    var top = node;
    while (top.parent) |p| top = p;
    if (top.behavior.events.on_key_down == null) top.behavior.events.on_key_down = onKey;
    const now_ms = (frame_cx orelse return).frame_time_ms;
    for (&anims) |*an| {
        if (!an.active) continue;
        const sa = an.sa orelse continue;
        const t = std.math.clamp(@as(f32, @floatCast(now_ms - an.t0_ms)) / 1000 / an.dur, 0, 1);
        const e = 0.5 - 0.5 * @cos(std.math.pi * t);
        SA.setScrollY(sa.state, sa.content, an.from + (an.to - an.from) * e);
        if (t >= 1) an.active = false else node.markRenderDirty();
    }
}

fn onKey(key: ui.events.KeyCode, _: ui.events.Modifiers, _: ?*anyopaque) ui.events.EventResult {
    switch (key) {
        .a => anims[0].start(700, 3.0),
        .s => anims[0].start(0, 2.4),
        .d => anims[1].start(520, 2.2),
        .f => anims[1].start(0, 1.9),
        .g => header.toggle(),
        else => return .ignored,
    }
    return .handled;
}

const Noop = struct {
    fn f(_: *Noop) void {}
};
var noop = Noop{};

// ── Media header: the trailing actions split out of one glass circle ─────────────────────
// UINavigationBar metrics (B.nav_metrics): 44 pt platters at the top of the 54 pt row, 16 pt
// margins, capsules 12 apart. Apple's glassEffectID pattern: container spacing = stack spacing, so
// the inserted circles grow out of the retained one and merge back into it.
const HEAD_D: f32 = B.nav_metrics.height;
const HEAD_GAP: f32 = B.nav_metrics.group_gap;
const HEAD_W: f32 = 3 * HEAD_D + 2 * HEAD_GAP;
const Header = struct {
    group: ?GG.GlassGroupMount = null,
    members: [3]GG.GlassShapeEntry = undefined,
    split: bool = false,

    /// Member i's slot, container-local; the menu circle (member 0) stays at the trailing end.
    fn slot(i: usize) [4]f32 {
        const x = HEAD_W - HEAD_D - @as(f32, @floatFromInt(i)) * (HEAD_D + HEAD_GAP);
        return .{ x, 0, HEAD_D, HEAD_D };
    }

    fn toggle(self: *Header) void {
        const g = self.group orelse return;
        self.split = !self.split;
        if (self.split) {
            GG.transact(g, .{ .moves = &.{.{ .entry = self.members[0], .rect = slot(0) }}, .inserts = &.{ .{ .entry = self.members[1], .rect = slot(1) }, .{ .entry = self.members[2], .rect = slot(2) } } });
        } else {
            GG.transact(g, .{ .moves = &.{.{ .entry = self.members[0], .rect = slot(0) }}, .removes = &.{ self.members[1], self.members[2] } });
        }
        g.container.markRenderDirty();
    }
};
var header = Header{};

// ── Helpers ──────────────────────────────────────────────────────────────────────────────
fn rounded(cx: *ui.Cx, n: *ui.Node, r: f32) !void {
    (try n.style.ensureExtFallible(cx.allocator)).corner_radius = ui.CornerRadius.uniform(r);
}

fn place(cx: *ui.Cx, n: *ui.Node, left: f32, top: f32) !void {
    n.style.position = .absolute;
    (try n.style.ensureExtFallible(cx.allocator)).inset = .{ .left = .{ .px = left }, .top = .{ .px = top } };
}

fn tagged(n: *ui.Node, id: []const u8) *ui.Node {
    n.meta.ownership.meta.test_id = id;
    return n;
}

fn label(cx: *ui.Cx, s: []const u8, size: f32, weight: u16, color: ui.Color) !*ui.Node {
    return ui.text(cx, s, .{ .font_size = size, .font_weight = weight, .color = color, .line_height = 1.15, .selectable = false });
}

fn mono(cx: *ui.Cx, s: []const u8, size: f32, color: ui.Color) !*ui.Node {
    return ui.text(cx, s, .{ .font_size = size, .color = color, .use_monospace_font = true, .selectable = false });
}

fn fade(stops: []const ui.GradientStop) ui.MultiGradient {
    return ui.MultiGradient.fromSlice(stops, .vertical);
}

/// 4x4 Bayer thresholds.
const BAYER = [16]f32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

/// An ordered-dither pixel field (the site's motif): cell (i, j) is `on` where the density
/// `f(u, v)` beats the Bayer threshold, the half tone `mid` just below it, else empty.
fn ditherField(cx: *ui.Cx, w: f32, h: f32, cell: f32, gap: f32, on: ui.Color, mid: ?ui.Color, f: *const fn (f32, f32) f32) !*ui.Node {
    const a = cx.allocator;
    const field = try ui.box(cx, .{ .width = .{ .px = w }, .height = .{ .px = h }, .position = .relative }, .{});
    const cols: usize = @intFromFloat(@floor(w / cell));
    const rows: usize = @intFromFloat(@floor(h / cell));
    for (0..rows) |j| {
        for (0..cols) |i| {
            const u = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(cols));
            const v = (@as(f32, @floatFromInt(j)) + 0.5) / @as(f32, @floatFromInt(rows));
            const d = f(u, v);
            const t = (BAYER[(j % 4) * 4 + (i % 4)] + 0.5) / 16;
            const color: ?ui.Color = if (d > t) on else if (mid != null and d > t * 0.55) mid else null;
            const c = color orelse continue;
            const px = try ui.box(cx, .{ .width = .{ .px = cell - gap }, .height = .{ .px = cell - gap }, .background = c }, .{});
            try place(cx, px, @as(f32, @floatFromInt(i)) * cell, @as(f32, @floatFromInt(j)) * cell);
            try field.appendChild(a, px);
        }
    }
    return field;
}

fn fadeDown(_: f32, v: f32) f32 {
    return std.math.pow(f32, 1 - v, 1.6);
}
fn fadeUp(_: f32, v: f32) f32 {
    return std.math.pow(f32, v, 1.4);
}
fn wave(u: f32, v: f32) f32 {
    return 0.5 + 0.45 * @sin(u * std.math.pi * 2.2 + v * 5.0) * (1 - v * 0.4);
}
fn cover1(u: f32, v: f32) f32 {
    return 1 - (u + v) / 2;
}
fn cover2(u: f32, v: f32) f32 {
    return 0.5 + 0.5 * @sin((u - v) * 7.0);
}
fn cover3(u: f32, v: f32) f32 {
    const dx = u - 0.5;
    const dy = v - 0.5;
    return 1 - @sqrt(dx * dx + dy * dy) * 1.8;
}
fn cover4(u: f32, v: f32) f32 {
    return std.math.pow(f32, v, 0.8) * (0.6 + 0.4 * @cos(u * 6.0));
}

/// An iPhone screen: clips its content, with the status bar and home indicator on top.
fn screen(cx: *ui.Cx, id: []const u8, bg: ui.Color) !*ui.Node {
    const s = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .height = .{ .px = SCREEN_H }, .position = .relative, .overflow_hidden = true, .background = bg }, .{});
    return tagged(s, id);
}

fn statusBar(cx: *ui.Cx, color: ui.Color) !*ui.Node {
    const a = cx.allocator;
    const bar = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .height = .{ .px = STATUS_H }, .direction = .row, .align_items = .center, .padding = .{ .left = 52, .right = 34, .top = 4 } }, .{});
    try bar.appendChild(a, try label(cx, "9:41", 17, 600, color));
    try bar.appendChild(a, try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1 } }, .{}));
    const glyphs = try ui.box(cx, .{ .direction = .row, .gap = 6, .align_items = .center }, .{});
    for ([_]ui.SvgAsset{ icons.signal, icons.wifi, icons.battery_full }) |ic| {
        try glyphs.appendChild(a, try ui.iconTint(cx, ic, color, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } }));
    }
    try bar.appendChild(a, glyphs);
    try place(cx, bar, 0, 0);
    return bar;
}

fn homeIndicator(cx: *ui.Cx, color: ui.Color) !*ui.Node {
    const home = try ui.box(cx, .{ .width = .{ .px = 140 }, .height = .{ .px = 5 }, .background = color }, .{});
    try rounded(cx, home, 3);
    try place(cx, home, (SCREEN_W - 140) / 2, SCREEN_H - 13);
    return home;
}

// ── Media: clear glass controls over full-bleed artwork ─────────────────────────────────
/// HIG: over bright content, a dark dimming layer of 35% opacity behind clear glass. It holds the
/// full 35% across the band `hold` deep at the screen edge (where the glass sits) and fades out
/// past it.
fn dimming(cx: *ui.Cx, h: f32, hold: f32, top: bool) !*ui.Node {
    const dark = ui.Color.rgba(0, 0, 0, 89);
    const none = ui.Color.rgba(0, 0, 0, 0);
    const k = hold / h;
    const stops: []const ui.GradientStop = if (top)
        &.{ .{ .color = dark, .position = 0 }, .{ .color = dark, .position = k }, .{ .color = none, .position = 1 } }
    else
        &.{ .{ .color = none, .position = 0 }, .{ .color = dark, .position = 1 - k }, .{ .color = dark, .position = 1 } };
    return ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .height = .{ .px = h }, .multi_gradient = fade(stops) }, .{});
}

/// Header row over the artwork: a clear close button leading; trailing, one clear menu circle that
/// splits into three (key g) inside one GlassGroup.
fn mediaHeader(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const M = B.nav_metrics;
    const row = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .height = .{ .px = B.nav_row_height }, .position = .relative }, .{});
    try place(cx, row, 0, STATUS_H);

    const close = try W.GlassShape(.{ .width = HEAD_D, .height = HEAD_D, .shape = .circle, .glass_style = .clear, .padding = ui.Padding.all(0) }).mountIn(try headGroup(scope, cx, row, M.margin, HEAD_D), scope, cx);
    try headIcon(cx, close, icons.chevron_down);
    _ = tagged(close.node, "showcase.media.close");

    const g = try headGroup(scope, cx, row, SCREEN_W - M.margin - HEAD_W, HEAD_W);
    header.group = g;
    const glyphs = [_]ui.SvgAsset{ icons.ellipsis, icons.airplay, icons.captions };
    const ids = [_][]const u8{ "showcase.media.more", "showcase.media.airplay", "showcase.media.captions" };
    for (glyphs, 0..) |ic, i| {
        const r = Header.slot(if (i == 0) 0 else i);
        const e = try W.GlassShape(.{ .width = HEAD_D, .height = HEAD_D, .shape = .circle, .glass_style = .clear, .padding = ui.Padding.all(0) }).mountIn(g, scope, cx);
        e.node.style.position = .absolute;
        (try e.node.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = r[0] }, .top = .{ .px = r[1] } };
        try headIcon(cx, e, ic);
        _ = tagged(e.node, ids[i]);
        if (i > 0) GG.setMemberPresent(e, false);
        header.members[i] = e;
    }
    return row;
}

fn headGroup(scope: *ui.Scope, cx: *ui.Cx, row: *ui.Node, left: f32, w: f32) !GG.GlassGroupMount {
    const g = try W.GlassGroup(.{ .spacing = HEAD_GAP, .merge = .transitions, .width = w, .height = HEAD_D }).mountWithState(scope, cx);
    try place(cx, g.container, left, 0);
    try row.appendChild(cx.allocator, g.container);
    return g;
}

fn headIcon(cx: *ui.Cx, e: GG.GlassShapeEntry, ic: ui.SvgAsset) !void {
    e.body.style.align_items = .center;
    e.body.style.justify = .center;
    e.body.style.width = .{ .grow = .{} };
    e.body.style.height = .{ .grow = .{} };
    try e.body.appendChild(cx.allocator, try ui.iconTint(cx, ic, WHITE, .{ .width = .{ .px = B.nav_metrics.icon_size }, .height = .{ .px = B.nav_metrics.icon_size } }));
}

fn buildMedia(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const s = try screen(cx, "showcase.media", ACC);

    // The artwork: taller than the screen, panned by the scripted scroll.
    const sa = try W.ScrollArea(.{ .width = SCREEN_W, .height = SCREEN_H, .direction = .vertical }).mount(scope, cx);
    _ = tagged(sa.container, "showcase.media.scroll");
    anims[0].sa = sa;
    const art = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .direction = .column }, .{});
    const top = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .height = .{ .px = 520 }, .background = ACC, .direction = .column, .gap = 6, .padding = .{ .top = 150, .left = 24 } }, .{});
    try top.appendChild(a, try mono(cx, "ZENIT / LIQUID GLASS", 13, ACC_SOFT));
    try top.appendChild(a, try label(cx, "Liquid", 128, 700, WHITE));
    try art.appendChild(a, top);
    try art.appendChild(a, try ditherField(cx, SCREEN_W, 160, 14, 2, ACC, ACC_MID, fadeDown));
    const mid = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .height = .{ .px = 330 }, .background = WHITE, .direction = .column, .padding = .{ .top = 10, .left = 24 } }, .{});
    try mid.appendChild(a, try label(cx, "Glass", 128, 700, INK));
    try art.appendChild(a, mid);
    try art.appendChild(a, try ditherField(cx, SCREEN_W, 220, 14, 2, ACC, ACC_MID, fadeUp));
    const end = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .height = .{ .px = 700 }, .background = ACC, .direction = .column, .padding = .{ .top = 60, .left = 24 } }, .{});
    try end.appendChild(a, try label(cx, "zenit.", 128, 700, WHITE));
    try art.appendChild(a, end);
    try sa.content.appendChild(a, art);
    try s.appendChild(a, sa.container);

    // The large clear glass over the giant word: the type refracts through its lens edge as the
    // artwork pans underneath.
    const clear = try W.GlassBox(.{ .width = 330, .height = 96, .shape = .capsule, .glass_style = .clear, .padding = ui.Padding.all(0) }).mount(scope, cx);
    try place(cx, tagged(clear, "showcase.clear"), (SCREEN_W - 330) / 2, 214);
    try s.appendChild(a, clear);
    const cap = try ui.box(cx, .{ .direction = .row, .gap = 10, .align_items = .center, .padding = ui.Padding.symmetric(7, 15), .background = ui.Color.rgba(28, 22, 18, 150) }, .{});
    try rounded(cx, cap, 999);
    try cap.appendChild(a, try label(cx, "Clear", 16, 700, WHITE));
    try cap.appendChild(a, try mono(cx, "glass_style = .clear", 13, WHITE));
    try place(cx, cap, (SCREEN_W - 330) / 2 + 12, 214 + 96 + 14);
    try s.appendChild(a, cap);

    const dim_top = try dimming(cx, 190, STATUS_H + B.nav_row_height, true);
    try place(cx, dim_top, 0, 0);
    try s.appendChild(a, dim_top);
    const dim_bottom = try dimming(cx, 220, B.toolbar_metrics.margin + B.toolbar_metrics.height + 12, false);
    try place(cx, dim_bottom, 0, SCREEN_H - 220);
    try s.appendChild(a, dim_bottom);

    // Bottom controls, on the bottom toolbar's measured metrics (B.toolbar_metrics: 48 pt platters
    // 28 pt from the sides and the bottom, 12 apart): clear glass image buttons (48 pt circles, the
    // HIG's 44 pt hit region and the same height as the tinted primary action on the trailing side).
    const TB = B.toolbar_metrics;
    const row = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .direction = .row, .gap = TB.group_gap, .align_items = .center, .padding = .{ .left = TB.margin, .right = TB.margin } }, .{});
    const buttons = [_]struct { icon: ui.SvgAsset, name: []const u8, id: []const u8 }{
        .{ .icon = icons.heart, .name = "Like", .id = "showcase.media.like" },
        .{ .icon = icons.share, .name = "Share", .id = "showcase.media.share" },
        .{ .icon = icons.info, .name = "Info", .id = "showcase.media.info" },
    };
    for (buttons) |bt| try row.appendChild(a, (try W.GlassButton(.{ .icon = bt.icon, .label = bt.name, .style = .clear_glass, .test_id = bt.id }).mount(scope, cx)).root);
    try row.appendChild(a, try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1 } }, .{}));
    const save = try ui.box(cx, .{ .width = .{ .px = 112 }, .height = .{ .px = TB.height }, .position = .relative }, .{});
    const save_glass = try W.GlassBox(.{ .width = 112, .height = TB.height, .shape = .capsule, .tint_color = ACC, .interactive = true, .padding = ui.Padding.all(0) }).mount(scope, cx);
    try place(cx, tagged(save_glass, "showcase.media.save"), 0, 0);
    try save.appendChild(a, save_glass);
    const save_label = try ui.box(cx, .{ .width = .{ .px = 112 }, .height = .{ .px = TB.height }, .align_items = .center, .justify = .center }, .{});
    try save_label.appendChild(a, try label(cx, "Save", 17, 600, WHITE));
    try place(cx, save_label, 0, 0);
    try save.appendChild(a, save_label);
    try row.appendChild(a, save);
    try place(cx, row, 0, SCREEN_H - TB.margin - TB.height);
    try s.appendChild(a, row);

    try s.appendChild(a, try mediaHeader(scope, cx));

    try s.appendChild(a, try statusBar(cx, WHITE));
    try s.appendChild(a, try homeIndicator(cx, WHITE));
    return s;
}

// ── Library: the iOS navigation bar and tab bar over a list ──────────────────────────────
const Album = struct { title: []const u8, sub: []const u8, f: *const fn (f32, f32) f32, tone: u8 };
const ALBUMS = [_]Album{
    .{ .title = "Frame Pacing", .sub = "CVDisplayLink · 12 tracks", .f = cover1, .tone = 0 },
    .{ .title = "Signals", .sub = "Fine-grained · 9 tracks", .f = cover2, .tone = 1 },
    .{ .title = "Refraction", .sub = "Lens field · 11 tracks", .f = cover3, .tone = 0 },
    .{ .title = "Retained", .sub = "Surface cache · 8 tracks", .f = cover4, .tone = 2 },
    .{ .title = "Bidi", .sub = "UAX #9 · 10 tracks", .f = cover2, .tone = 0 },
    .{ .title = "Damage", .sub = "Dirty rects · 7 tracks", .f = cover1, .tone = 1 },
    .{ .title = "Glyph Atlas", .sub = "Core Text · 14 tracks", .f = cover3, .tone = 2 },
    .{ .title = "Harness", .sub = "Real windows · 6 tracks", .f = cover4, .tone = 0 },
    .{ .title = "Metal", .sub = "Triple buffered · 12 tracks", .f = cover1, .tone = 2 },
    .{ .title = "Direct3D 12", .sub = "Windows · 9 tracks", .f = cover2, .tone = 1 },
    .{ .title = "Grapheme", .sub = "UAX #29 · 8 tracks", .f = cover3, .tone = 0 },
    .{ .title = "Union", .sub = "Glass morph · 10 tracks", .f = cover4, .tone = 1 },
};

fn coverArt(cx: *ui.Cx, size: f32, al: Album) !*ui.Node {
    const bg = switch (al.tone) {
        0 => ACC_SOFT,
        1 => ACC,
        else => INK,
    };
    const fg = switch (al.tone) {
        0 => ACC,
        1 => ACC_SOFT,
        else => ACC_MID,
    };
    const box = try ui.box(cx, .{ .width = .{ .px = size }, .height = .{ .px = size }, .background = bg, .overflow_hidden = true, .position = .relative }, .{});
    try rounded(cx, box, 12);
    try box.appendChild(cx.allocator, try ditherField(cx, size, size, size / 8, 1.5, fg, null, al.f));
    return box;
}

fn buildLibrary(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const s = try screen(cx, "showcase.library", WHITE);

    const sa = try W.ScrollArea(.{ .width = SCREEN_W, .height = SCREEN_H, .direction = .vertical }).mount(scope, cx);
    _ = tagged(sa.container, "showcase.library.scroll");
    anims[1].sa = sa;
    const list = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .direction = .column, .gap = 4, .padding = .{ .top = STATUS_H + B.nav_row_height, .bottom = 120, .left = 16, .right = 16 } }, .{});

    // The large title belongs to the scrolling content (as UIKit's does): it scrolls away under the
    // floating bar instead of sitting over the list. Measured block: 71.3 tall, 34 pt bold title
    // 6.7 down, 12 pt subtitle (B.GlassNavigationBar's large title, system UI font 0xFFFF).
    const title = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = B.large_title_height }, .direction = .column, .padding = .{ .top = 6.7 } }, .{});
    try title.appendChild(a, try ui.text(cx, "Library", .{ .font_size = 34, .font_weight = 700, .font_family = 0xFFFF, .color = ui.Color.rgba(0, 0, 0, 255), .line_height = 1.2, .selectable = false, .font_smoothing = false }));
    try title.appendChild(a, try ui.text(cx, "12 albums", .{ .font_size = 12, .color = ui.Color.rgba(72, 72, 72, 255), .line_height = 1.2, .selectable = false, .font_smoothing = false }));
    try list.appendChild(a, title);
    try list.appendChild(a, try ui.box(cx, .{ .height = .{ .px = 40 } }, .{}));

    // Featured banner: blue pixels and big type pass under the navigation bar.
    const feat = try ui.box(cx, .{ .width = .{ .px = SCREEN_W - 32 }, .height = .{ .px = 210 }, .background = ACC, .position = .relative, .overflow_hidden = true, .direction = .column, .padding = .{ .top = 26, .left = 22 } }, .{});
    try rounded(cx, feat, 24);
    const feat_px = try ditherField(cx, SCREEN_W - 32, 210, 14, 2, ACC_MID, null, wave);
    try place(cx, feat_px, 0, 0);
    try feat.appendChild(a, feat_px);
    try feat.appendChild(a, try mono(cx, "NOW PLAYING", 12, ACC_SOFT));
    try feat.appendChild(a, try label(cx, "Liquid Glass", 40, 700, WHITE));
    try list.appendChild(a, feat);
    try list.appendChild(a, try ui.box(cx, .{ .height = .{ .px = 14 } }, .{}));

    for (ALBUMS) |al| {
        const r = try ui.box(cx, .{ .direction = .row, .gap = 14, .align_items = .center, .padding = ui.Padding.symmetric(8, 4) }, .{});
        try r.appendChild(a, try coverArt(cx, 60, al));
        const txt = try ui.box(cx, .{ .direction = .column, .gap = 3 }, .{});
        try txt.appendChild(a, try label(cx, al.title, 17, 600, INK));
        try txt.appendChild(a, try label(cx, al.sub, 14, 400, MUTE));
        try r.appendChild(a, txt);
        try list.appendChild(a, r);
    }
    try sa.content.appendChild(a, list);
    try s.appendChild(a, sa.container);

    // No scroll edge layers: the bars float straight over the list (regular glass, as UIKit's).
    const nav_icons = [_]B.BarIcon{.{ .icon = icons.plus, .label = "Add" }};
    // The floating bar carries only its trailing action; the large title is in the list above.
    const nav = try W.GlassNavigationBar(.{
        .trailing = &[_]B.BarGroup{.{ .icons = &nav_icons }},
        .width = SCREEN_W,
        .test_id = "showcase.nav",
    }).mount(scope, cx);
    try place(cx, nav.root, 0, STATUS_H);
    try s.appendChild(a, nav.root);

    const tabs = [_]B.TabItem{
        .{ .icon = icons.house, .label = "Home", .test_id = "showcase.tab.home" },
        .{ .icon = icons.library, .label = "Library", .test_id = "showcase.tab.library" },
        .{ .icon = icons.radio, .label = "Radio", .test_id = "showcase.tab.radio" },
    };
    const tab = try W.GlassTabBar(.{
        .tabs = &tabs,
        .selected = 1,
        .search = .{ .icon = icons.search, .label = "Search", .test_id = "showcase.tab.search" },
        .width = SCREEN_W,
        .test_id = "showcase.tabbar",
    }).mount(scope, cx);
    try place(cx, tab.root, 0, SCREEN_H - 98);
    try s.appendChild(a, tab.root);

    try s.appendChild(a, try statusBar(cx, INK));
    try s.appendChild(a, try homeIndicator(cx, INK));
    return s;
}

// ── Settings: iOS switches, a slider and glass buttons ───────────────────────────────────
const Setting = struct { label: []const u8, on: bool, id: []const u8, icon: ui.SvgAsset };

fn settingRow(scope: *ui.Scope, cx: *ui.Cx, st: Setting, last: bool) !*ui.Node {
    const a = cx.allocator;
    const r = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 14, .height = .{ .px = 58 }, .padding = ui.Padding.symmetric(0, 16) }, .{});
    const ic = try ui.box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .background = ACC, .align_items = .center, .justify = .center }, .{});
    try rounded(cx, ic, 8);
    try ic.appendChild(a, try ui.iconTint(cx, st.icon, WHITE, .{ .width = .{ .px = 17 }, .height = .{ .px = 17 } }));
    try r.appendChild(a, ic);
    try r.appendChild(a, try label(cx, st.label, 17, 400, INK));
    try r.appendChild(a, try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1 } }, .{}));
    const t = try W.GlassToggle(.{ .on = st.on, .idiom = .ios, .test_id = st.id }).mount(scope, cx);
    try r.appendChild(a, t.wrapper);
    if (last) return r;
    const wrap = try ui.box(cx, .{ .width = .fill(), .direction = .column }, .{});
    try wrap.appendChild(a, r);
    try wrap.appendChild(a, try ui.box(cx, .{ .height = .{ .px = 1 }, .background = LINE, .margin = .{ .left = 60 } }, .{}));
    return wrap;
}

fn buildSettings(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const s = try screen(cx, "showcase.settings", WHITE);

    // Pixel field at the foot of the screen, the site's dither in accent blue.
    const foot = try ditherField(cx, SCREEN_W, 250, 14, 2, ACC, ACC_MID, fadeUp);
    try place(cx, foot, 0, SCREEN_H - 250);
    try s.appendChild(a, foot);

    const body = try ui.box(cx, .{ .width = .{ .px = SCREEN_W }, .direction = .column, .gap = 18, .padding = .{ .top = STATUS_H + 72, .left = 16, .right = 16 } }, .{});
    try body.appendChild(a, try mono(cx, "LIQUID GLASS", 13, MUTE));

    const group = try ui.box(cx, .{ .width = .fill(), .direction = .column, .background = BG2 }, .{});
    try rounded(cx, group, 22);
    const settings = [_]Setting{
        .{ .label = "Liquid Glass", .on = true, .id = "showcase.switch.glass", .icon = icons.sparkles },
        .{ .label = "Reduce Transparency", .on = false, .id = "showcase.switch.reduce", .icon = icons.eye },
        .{ .label = "Increase Contrast", .on = false, .id = "showcase.switch.contrast", .icon = icons.contrast },
        .{ .label = "Dark Appearance", .on = false, .id = "showcase.switch.dark", .icon = icons.moon },
    };
    for (settings, 0..) |st, i| try group.appendChild(a, try settingRow(scope, cx, st, i == settings.len - 1));
    try body.appendChild(a, group);

    const sl_group = try ui.box(cx, .{ .width = .fill(), .direction = .column, .background = BG2, .gap = 14, .padding = .{ .top = 16, .bottom = 20, .left = 16, .right = 16 } }, .{});
    try rounded(cx, sl_group, 22);
    const head = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 10 }, .{});
    try head.appendChild(a, try ui.iconTint(cx, icons.sun_medium, MUTE, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } }));
    try head.appendChild(a, try label(cx, "Glass thickness", 17, 400, INK));
    try sl_group.appendChild(a, head);
    const slider = try W.GlassSlider(.{ .width = SCREEN_W - 64, .value = 0.32, .idiom = .ios, .test_id = "showcase.slider" }).mount(scope, cx);
    try sl_group.appendChild(a, slider.wrapper);
    try body.appendChild(a, sl_group);
    try s.appendChild(a, body);

    // Navigation bar with a back button, as a settings sub-page has.
    const nav = try W.GlassNavigationBar(.{ .title = "Display", .back = cx.on(Noop, &noop, Noop.f), .width = SCREEN_W }).mount(scope, cx);
    try place(cx, nav.root, 0, STATUS_H);
    try s.appendChild(a, nav.root);

    try s.appendChild(a, try statusBar(cx, INK));
    try s.appendChild(a, try homeIndicator(cx, INK));
    return s;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    frame_cx = cx;
    // The screens use the site's light palette: run the light theme so glass picks its light
    // appearance family (the framework default is dark), as the storybook does.
    cx.setTheme(&ui.theme.modes.light);
    const a = cx.allocator;
    const root = try ui.box(cx, .{
        .width = .{ .px = WIN_W },
        .height = .{ .px = WIN_H },
        .direction = .row,
        .gap = GAP,
        .align_items = .center,
        .justify = .center,
        .background = BG2,
    }, .{});
    try root.appendChild(a, try buildMedia(scope, cx));
    try root.appendChild(a, try buildLibrary(scope, cx));
    try root.appendChild(a, try buildSettings(scope, cx));
    root.addBeforeRender(tickScroll);
    return root;
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = WIN_W, .height = WIN_H, .title = "Liquid Glass" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
