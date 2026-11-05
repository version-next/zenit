//! iOS Liquid Glass bars and buttons: navigation bar, tab bar, bottom toolbar and glass buttons.
//!
//! Geometry and colors are read from the native iOS 26.5 Simulator (iPhone 17 Pro) view
//! hierarchy and captures (scripts/glass_native_model/baselines/ios-26-5-simulator-iphone-17-pro/
//! system, `ios/system_layout.py`). The glass itself is GlassBox with the iOS idiom profile: every
//! bar platter is compact regular glass (gray 128 reads 205 light / 89 dark natively, which the iOS
//! compact coating reproduces). Grouping follows UIKit: image items share one capsule, text items
//! and prominent items get their own (WWDC25 284).
//!
//! The tab bar selection follows native touch dynamics (tab_motion.zig: lens travel, lift, wobble,
//! drag and platter growth, fitted to XCUITest traces). Not measured yet (so not emulated): press
//! feedback of bar buttons, tab bar minimize, search expansion, large-title collapse on scroll.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Model = reactive.Model;
const Handler = core.Handler;
const Event = @import("../../events.zig").Event;
const EventResult = @import("../../events.zig").EventResult;
const svg_assets = @import("../../svg_assets.zig");
const types = @import("../../core/types.zig");
const glass_box = @import("../glass_box/mod.zig");
const glass_group = @import("../glass_group/mod.zig");
const GlassIdiom = glass_box.GlassIdiom;
pub const tab_motion = @import("tab_motion.zig");
const TabMotion = tab_motion.TabMotion;

// ============================================================================
// Measured metrics (logical points)
// ============================================================================

/// Capsule row of a bar: platter height, item hit size, inset from the capsule edge, spacing
/// between items in one capsule and between capsules, side margin, text item padding.
pub const BarMetrics = struct {
    height: f32,
    item_width: f32,
    item_height: f32,
    inset: f32,
    item_gap: f32,
    group_gap: f32,
    margin: f32,
    text_padding: f32,
    icon_size: f32,
};

/// UINavigationBar (system_navbar_*): platters 44 tall at the top of a 54 pt row, 16 pt margins,
/// image items 38 x 36 inset 4 and 16 apart, capsules 12 apart; Done capsule 73.7 for a 41.7 pt
/// label (16 pt padding).
pub const nav_metrics = BarMetrics{ .height = 44, .item_width = 38, .item_height = 36, .inset = 4, .item_gap = 16, .group_gap = 12, .margin = 16, .text_padding = 16, .icon_size = 24 };
/// Bottom UIToolbar (system_toolbar_*): platters 48 tall, 28 pt from the sides and the bottom,
/// items ~41 x 38 inset 5 and 14 apart; a prominent image item is a 48 pt circle.
pub const toolbar_metrics = BarMetrics{ .height = 48, .item_width = 41, .item_height = 38, .inset = 5, .item_gap = 14, .group_gap = 12, .margin = 28, .text_padding = 16, .icon_size = 24 };
/// Navigation bar row height (platters sit at its top).
pub const nav_row_height: f32 = 54;
/// Large title block below the row: 34 pt bold at 16 pt, block 71.3 tall.
pub const large_title_height: f32 = 71.3;
/// Tab bar (system_tabbar_*): 62 pt platter, 21 pt margins and bottom gap, a separate 62 pt search
/// circle 8 pt away; tab buttons 54 tall inset 4; 3 tabs in a 290 pt platter are 100.7 wide on a
/// 90.7 step (neighbours overlap); icon above a 10 pt label.
pub const tab_height: f32 = 62;
pub const tab_margin: f32 = 21;
pub const tab_search_gap: f32 = 8;
pub const tab_inset: f32 = 4;
pub const tab_button_height: f32 = 54;
/// The platter and the search circle share one glass container: 8 pt apart at rest they stay
/// separate; the pressed platter grows to within 0.6 pt of the circle and they fuse (native neck).
pub const tab_merge_spacing: f32 = 6;
/// Pressed platter body shift (native 205 -> 216 over gray 128 while the finger is down,
/// interaction/tabbar_hold_t8/t9.png), light family; follows the platter growth.
pub const tab_press_lift: f32 = 11.0 / 255.0;
/// Extra platter shadow strength while pressed (fraction of the rest shadow)
pub const tab_press_shadow: f32 = 1.3;
/// Room above and below the tab bar glass container for the pressed platter's 5 % growth
/// (the container surface clips its members).
const tab_glass_bleed: f32 = 8;
/// Button width over the even share of the platter interior (100.7 / 94, measured for 3 tabs).
pub const tab_button_overlap: f32 = 100.7 / 94.0;
/// UIButton.Configuration.glass (system_controls_*): 34.33 tall capsule, 12 pt side padding,
/// 17 pt title. An image-only button is a 48 pt circle around its 24 pt image, 12 pt all round
/// (system_controls_*, system_buttonsizes_*: buttonSize .mini / .small 44, .medium 48, .large 64);
/// it clears the HIG's 44 x 44 pt hit region and matches the bottom toolbar's 48 pt platters.
pub const button_height: f32 = 34.33;
pub const button_padding: f32 = 12;
pub const button_image_diameter: f32 = 48;
pub const button_image_size: f32 = 24;

/// Ink over bar glass, per material family (captures: icons 21 over 205 light, 247 over 89 dark;
/// titles pure black / white; inline subtitle 72 light / 194 dark).
pub const Ink = struct {
    primary: Color,
    icon: Color,
    secondary: Color,
    /// Tab selection plate before the first backdrop reading (light: 205 -> 181, dark: 89 -> 120
    /// over gray 128); with a reading the plate follows the platter body (`selectionPlate`).
    selection_plate: Color,
    /// Selected tab icon / label.
    selected: Color,
};
pub const light_ink = Ink{
    .primary = Color.rgba(0, 0, 0, 255),
    .icon = Color.rgba(0, 0, 0, 230),
    .secondary = Color.rgba(0, 0, 0, 153),
    .selection_plate = Color.rgba(0, 0, 0, 30),
    .selected = Color.rgba(0, 122, 255, 255),
};
pub const dark_ink = Ink{
    .primary = Color.rgba(255, 255, 255, 255),
    .icon = Color.rgba(255, 255, 255, 242),
    .secondary = Color.rgba(255, 255, 255, 166),
    .selection_plate = Color.rgba(255, 255, 255, 48),
    .selected = Color.rgba(60, 190, 255, 255),
};
/// Native tab bar platter body (sRGB) over a gray backdrop, light / dark family (iOS 26.5
/// simulator, light and dark schemes, backdrop gray 0..255; system_tabbar plate captures).
const body_light = [_][2]f32{ .{ 64, 174 }, .{ 96, 188 }, .{ 128, 205 }, .{ 160, 223 }, .{ 192, 236 }, .{ 210, 242 }, .{ 225, 247 }, .{ 235, 249 }, .{ 248, 252 }, .{ 255, 253 } };
const body_dark = [_][2]f32{ .{ 0, 19 }, .{ 32, 28 }, .{ 64, 42 }, .{ 128, 89 }, .{ 192, 103 } };

fn lerpColor(a: Color, b: Color, t: f32) Color {
    const f = struct {
        fn ch(x: u8, y: u8, k: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(x))) * std.math.clamp(k, 0, 1)));
        }
    };
    return .{ .r = f.ch(a.r, b.r, t), .g = f.ch(a.g, b.g, t), .b = f.ch(a.b, b.b, t), .a = f.ch(a.a, b.a, t) };
}

fn piecewise(table: []const [2]f32, x: f32) f32 {
    if (x <= table[0][0]) return table[0][1];
    for (table[1..], 1..) |p, i| if (x <= p[0]) {
        const q = table[i - 1];
        return q[1] + (p[1] - q[1]) * (x - q[0]) / (p[0] - q[0]);
    };
    return table[table.len - 1][1];
}

/// Selection plate over the tab bar platter. The native plate is an affine map of the platter
/// body it covers (sRGB, same captures): light family `1.114 * body - 47.8` (205 -> 181, 253 ->
/// 234: the brighter the body, the lighter the darkening), dark family `0.952 * body + 34.9`
/// (89 -> 120). It is drawn as a black (light) / white (dark) layer whose alpha lands on that value
/// over the body, so backdrop detail still shows through. The body comes from the platter's own
/// backdrop reading; before the first reading the gray-128 inks apply.
pub fn selectionPlate(backdrop_srgb: ?f32, family_mix: f32) Color {
    const lum = backdrop_srgb orelse return lerpColor(light_ink.selection_plate, dark_ink.selection_plate, family_mix);
    const x = std.math.clamp(lum, 0, 1) * 255;
    const lb = piecewise(&body_light, x);
    const light_alpha = std.math.clamp(1 - (1.114 * lb - 47.8) / lb, 0, 1);
    const db = piecewise(&body_dark, x);
    const dark_alpha = std.math.clamp((0.952 * db + 34.9 - db) / (255 - db), 0, 1);
    const light = Color.rgba(0, 0, 0, @intFromFloat(@round(light_alpha * 255)));
    const dark = Color.rgba(255, 255, 255, @intFromFloat(@round(dark_alpha * 255)));
    return lerpColor(light, dark, family_mix);
}

/// Prominent items: tinted with the system blue (iOS 26 systemBlue 0,136,255; the slider fill and
/// prominent bodies read 0,124,235 over gray 128 light), white ink.
/// Tint that renders as the native prominent fill (0, 124, 235) over gray 128 through the
/// compact coating (compare_region.py against system_navbar / system_toolbar).
pub const prominent_tint = Color.rgba(0, 130, 246, 255);
/// Ink on a prominent item is 56 % white added to the fill (native Done label / compose icon
/// read (143, 255, 255) over (0, 124, 235): plus-lighter, not an opaque white).
pub const prominent_ink = Color.rgba(143, 255, 255, 255);

// ============================================================================
// Public types
// ============================================================================

pub const BarIcon = struct {
    icon: svg_assets.Asset,
    /// Accessibility name
    label: []const u8 = "",
    on_click: ?Handler(void) = null,
    test_id: ?[]const u8 = null,
};

pub const BarText = struct {
    title: []const u8,
    on_click: ?Handler(void) = null,
    test_id: ?[]const u8 = null,
};

/// UIBarButtonItem.Style.prominent: its own capsule, tinted, white ink. Title or image.
pub const BarProminent = struct {
    title: ?[]const u8 = null,
    icon: ?svg_assets.Asset = null,
    /// Accessibility name for an image item
    label: []const u8 = "",
    tint: Color = prominent_tint,
    on_click: ?Handler(void) = null,
    test_id: ?[]const u8 = null,
};

pub const BarGroup = union(enum) {
    /// Image items sharing one glass capsule
    icons: []const BarIcon,
    /// A text item in its own capsule
    text: BarText,
    /// A prominent item in its own tinted capsule (circle when it is an image)
    prominent: BarProminent,
    /// Pushes the following groups to the trailing side
    flexible_space,
};

// ============================================================================
// Runtime: items, ink refresh, click handling
// ============================================================================

const Item = struct {
    bar: *BarRuntime,
    glass: *glass_box.AdaptiveGlassBoxState,
    node: *Node,
    icon: ?*Node = null,
    label: ?*Node = null,
    role: enum { plain, prominent, tab } = .plain,
    tab_index: usize = 0,
    on_click: ?Handler(void) = null,
    pressed: bool = false,

    fn ink(self: *const Item, comptime f: fn (*const Item, *const Ink) Color) Color {
        return glass_box.familyInk(self.glass, f(self, &light_ink), f(self, &dark_ink));
    }
    // Tab items are hit targets only; their drawn copies are inked by the runtime (refresh).
    fn iconInk(self: *const Item, k: *const Ink) Color {
        return switch (self.role) {
            .prominent => prominent_ink,
            .plain, .tab => k.icon,
        };
    }
    fn labelInk(self: *const Item, k: *const Ink) Color {
        return switch (self.role) {
            .prominent => prominent_ink,
            .plain, .tab => k.primary,
        };
    }
};

/// A drawn copy of a tab button (icon + label). Native draws two sets of `_UITabButton`s: the
/// plain one with the lens cut out of it, and an accent one masked to the lens and magnified.
const TabCopy = struct { node: *Node, icon: *Node, label: *Node };

const Tabs = struct {
    cx: *Cx,
    selected: reactive.Bound(usize),
    on_change: ?Handler(usize),
    /// Tab button centres along the platter
    centers: []f32,
    /// Plain copies: [0..n) in the part left of the lens, [n..2n) right of it
    plain: []TabCopy,
    accents: []TabCopy,
    /// Platter glass, its rest size; the layer stack above it (all platter-local)
    platter: *glass_box.AdaptiveGlassBoxState,
    platter_size: [2]f32,
    holder: *Node,
    plate: *Node,
    lens: *glass_box.AdaptiveGlassBoxState,
    clip: *Node,
    plain_left: *Node,
    plain_right: *Node,
    btn_w: f32,
    motion: TabMotion,
    last_ms: f64,
    /// Selection the lens was last sent to
    shown: usize,
    /// Pointer x at the press (platter-local)
    down_x: f32 = 0,
    /// Every field initialized (mount registers Tabs on the runtime before building the layers)
    ready: bool = false,
    /// Last applied {lens x, y, w, h, plate, accent scale, platter scale}
    last: [7]f32 = @splat(std.math.nan(f32)),

    /// Must be the caller's last step: on_change may destroy the bar
    fn select(self: *Tabs, index: usize) void {
        const on_change = self.on_change;
        const landed = self.selected.commit(index) orelse return;
        if (on_change) |h| h.call(landed);
    }

    fn localX(self: *const Tabs, x: f32) f32 {
        return x - self.holder.globalRect().x;
    }

    fn nearest(self: *const Tabs, x: f32) usize {
        var best: usize = 0;
        for (self.centers, 0..) |c, i| {
            if (@abs(c - x) < @abs(self.centers[best] - x)) best = i;
        }
        return best;
    }

    fn selectedIndex(self: *const Tabs) usize {
        return @min(self.selected.readAs(false), self.centers.len -| 1);
    }

    fn press(self: *Tabs, index: usize, x: f32) void {
        self.down_x = self.localX(x);
        self.motion.press(self.centers[index]);
        self.wake();
    }

    fn dragTo(self: *Tabs, x: f32) void {
        const lx = self.localX(x);
        // Dragging starts past the touch slop; then the lens follows the finger along the tabs.
        if (!self.motion.dragging and @abs(lx - self.down_x) < drag_slop) return;
        self.motion.drag(std.math.clamp(lx, self.centers[0], self.centers[self.centers.len - 1]));
        self.wake();
    }

    /// Finger up. Returns the tab to select (null = keep the selection).
    fn release(self: *Tabs, index: usize, inside: bool) ?usize {
        // A drag lands on the tab nearest the finger
        const to: ?usize = if (self.motion.dragging) self.nearest(self.motion.target) else if (inside) index else null;
        const landing = to orelse self.selectedIndex();
        self.motion.release(self.centers[landing]);
        self.shown = landing;
        self.wake();
        return to;
    }

    fn cancel(self: *Tabs) void {
        if (!self.motion.down) return;
        self.motion.release(self.centers[self.selectedIndex()]);
        self.shown = self.selectedIndex();
        self.wake();
    }

    fn wake(self: *Tabs) void {
        self.cx.needs_redraw = true;
        self.holder.markRenderDirty();
    }

    /// Per frame: advance the lens and place the layers.
    fn animate(self: *Tabs) void {
        if (!self.ready or self.centers.len == 0) return;
        const now = self.cx.frame_time_ms;
        const dt: f32 = @floatCast(std.math.clamp((now - self.last_ms) / 1000.0, 0, 0.1));
        self.last_ms = now;
        const sel = self.selectedIndex();
        if (sel != self.shown and !self.motion.down) {
            self.shown = sel;
            self.motion.goTo(self.centers[sel]);
        }
        if (!self.motion.settled()) {
            const before = self.motion.pose();
            self.motion.step(dt);
            if (self.motion.settled()) self.motion.settle();
            // A held lens whose springs have all come to rest under a still finger needs no
            // further frames (the next pointer move wakes them); anything else keeps animating.
            if (!self.motion.down or !tab_motion.TabMotion.poseStill(before, self.motion.pose())) self.cx.needs_redraw = true;
        }
        self.place();
    }

    fn place(self: *Tabs) void {
        const m = &self.motion;
        const l = m.lens();
        const y = tab_inset + tab_button_height / 2;
        const next = [7]f32{ l[0] - l[1] / 2, y - l[2] / 2, l[1], l[2], m.plateAlpha(), m.accentScale(), m.platterScale() };
        var same = true;
        for (next, self.last) |a, b| {
            if (!(@abs(a - b) < 1e-3)) same = false;
        }
        if (same) return;
        self.last = next;
        const rect = [4]f32{ next[0], next[1], next[2], next[3] };
        const ps = next[6];
        const pw = self.platter_size[0] * ps;
        const ph = self.platter_size[1] * ps;
        glass_box.glassPlace(self.platter, .{ tab_glass_bleed + (self.platter_size[0] - pw) / 2, tab_glass_bleed + (self.platter_size[1] - ph) / 2, pw, ph });
        const press_t = std.math.clamp((ps - 1) / self.motion.spec.platter_gain, 0, 1);
        glass_box.glassSetPressOffset(self.platter, if (press_t > 0.001) tab_press_lift * press_t else null);
        // The lifted platter casts a deeper shadow (native below the platter: 113 at rest, 104
        // held, over a 120 backdrop).
        glass_box.glassSetShadowScale(self.platter, 1 + tab_press_shadow * press_t);
        glass_box.glassPlace(self.lens, rect);
        const hidden = debugLensHidden();
        glass_box.glassSetMaterializeLevel(self.lens, if (hidden) 0 else 1 - next[4]);
        const a = self.cx.allocator;
        placeRect(self.plate, a, rect);
        self.plate.setOpacity(if (hidden) 0 else next[4]);
        placeRect(self.clip, a, rect);
        if (hidden) self.clip.setOpacity(0);
        // The portal is warped by the clear lens only: at rest the selection is the opaque plate
        // and the accent content sits flat (native rest: crisp, unsheared label).
        const clear = 1 - next[4];
        if (self.clip.style.ext) |ext| {
            const base = debugContentWarp() orelse tab_portal_warp;
            ext.content_warp = if (clear > 0.01) .{ .cap = base.cap * clear, .edge = base.edge * clear, .fade_start = base.fade_start, .fade_width = base.fade_width } else null;
            self.clip.markRenderDirty();
        }
        // The plain tabs are cut where the lens is: vertical cuts at the capsule's edge across the
        // icon band (12 pt off the centre line); the lens rim refraction covers the rest.
        const r = rect[3] / 2;
        const dy = @min(r, 12);
        const cut = r - @sqrt(r * r - dy * dy);
        const margin: f32 = 24;
        const left_w = @max(rect[0] + cut + margin, 0);
        const right_x = rect[0] + rect[2] - cut;
        placeBox(self.plain_left, a, .{ -margin, 0, left_w, tab_height });
        placeBox(self.plain_right, a, .{ right_x, 0, @max(self.platter_size[0] + margin - right_x, 0), tab_height });
        const n = self.centers.len;
        const acc_scale = debugAccentScale() orelse next[5];
        for (self.centers, 0..) |c0, i| {
            // Content spreads with the grown platter (native: tab buttons keep their centres in
            // the platter's frame).
            const c = self.platter_size[0] / 2 + (c0 - self.platter_size[0] / 2) * ps;
            const left = c - self.btn_w / 2;
            // the plain copies grow with the platter too (Simulator, held: icons and labels x1.045)
            placeCopy(self.plain[i].node, a, left + margin, tab_inset, ps);
            placeCopy(self.plain[n + i].node, a, left - right_x, tab_inset, ps);
            // The accent set is a portal of the bar content: each copy stays on its own tab
            // (spread with the platter) and is magnified about its own centre, whatever the lens
            // does (native: Home accent cx 70.9 constant while the lens wobbles); the lens only
            // masks it, and its rim warps it (content_warp on the clip).
            placeCopy(self.accents[i].node, a, left - rect[0], tab_inset - rect[1], acc_scale);
        }
        self.holder.markRenderDirty();
    }

    fn destroy(self: *Tabs, alloc: Allocator) void {
        alloc.free(self.centers);
        alloc.free(self.plain);
        alloc.free(self.accents);
        alloc.destroy(self);
    }
};

fn ownTestId(a: Allocator, node: *Node, comptime fmt: []const u8, args: anytype) !void {
    node.meta.ownership.meta.test_id = try std.fmt.allocPrint(a, fmt, args);
    node.frame_state.state_bits.flags.test_id_owned = true;
}

/// A tab button: icon above a 10 pt label (children: icon, label row).
fn tabButton(cx: *Cx, t: TabItem, w: f32, ink: Color, idiom: GlassIdiom) !*Node {
    const a = cx.allocator;
    const node = try box(cx, .{
        .width = .{ .px = w },
        .height = .{ .px = tab_button_height },
        .position = .absolute,
    }, .{});
    errdefer cx.freeNode(node);
    const ic = try core.adoptChild(cx, a, node, try core.iconTint(cx, t.icon, ink, .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .position = .absolute,
    }));
    // Native (interaction/tabbar_zicons_t8.png and fresh Simulator shots, the same Lucide icons):
    // icon ink 13 pt below the button top (the 24 pt box at 8), label ink top at 41.3 (the system UI
    // font's 10 pt label box at 35.5; 35.8 measured worse overall).
    (try ic.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = (w - 24) / 2 }, .top = .{ .px = 8 } };
    const label_box = try core.adoptChild(cx, a, node, try box(cx, .{
        .width = .{ .px = w },
        .height = .{ .px = 12 },
        .position = .absolute,
        .direction = .row,
        .justify = .center,
    }, .{}));
    (try label_box.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 35.5 } };
    // native tab label: 10 pt medium (ink measured on the replay: 600 drew 30 % more ink)
    const label = try textNode(cx, label_box, t.label, 10, 500, idiom);
    label.setTextColor(ink);
    return node;
}

/// Portal warp of the accent copies (types.ContentWarp; px toward the lens centre at the
/// contour, fading inward). Native keeps the smear in a narrow rim (a tab crossing the cap curls
/// around it while the label inside stays flat, tap recordings): fading out over 8 pt from the
/// contour; a deeper fade (4 + 14 pt) bent the label into a wave as the lens moved.
pub const tab_portal_warp = types.ContentWarp{ .cap = 6, .edge = 2, .fade_start = 0, .fade_width = 8 };

/// Calibration: ZENIT_TAB_WARP="cap,edge,fade_start,fade_width" overrides tab_portal_warp.
fn debugContentWarp() ?types.ContentWarp {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const raw = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_TAB_WARP") catch return null;
    var it = std.mem.splitScalar(u8, raw, ',');
    var w = tab_portal_warp;
    const fields = [_]*f32{ &w.cap, &w.edge, &w.fade_start, &w.fade_width };
    for (fields) |f| f.* = std.fmt.parseFloat(f32, it.next() orelse return w) catch return w;
    return w;
}

/// Calibration: ZENIT_TAB_LENS_HIDE=1 leaves the selection out (lens, plate and accent copies):
/// the bar as the lens's backdrop sees it, for rendering the native lens layer tree over it
/// (scripts/glass_native_model/ca_render.swift).
fn debugLensHidden() bool {
    var buf: [16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const raw = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_TAB_LENS_HIDE") catch return false;
    return std.mem.eql(u8, raw, "1");
}

/// Calibration: ZENIT_TAB_ACCENT_SCALE overrides the accent magnification.
fn debugAccentScale() ?f32 {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const raw = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_TAB_ACCENT_SCALE") catch return null;
    return std.fmt.parseFloat(f32, raw) catch null;
}

/// Touch slop before a press becomes a drag of the lens (pt).
const drag_slop: f32 = 4;

/// Absolute rectangle {x, y, w, h}.
fn placeBox(node: *Node, alloc: Allocator, r: [4]f32) void {
    node.style.width = .{ .px = r[2] };
    node.style.height = .{ .px = r[3] };
    if (node.style.ensureExtFallible(alloc)) |ext| {
        ext.inset = .{ .left = .{ .px = r[0] }, .top = .{ .px = r[1] } };
    } else |_| {}
    node.markSizingDirty();
    node.markLayoutDirty();
    node.markRenderDirty();
}

/// A tab copy at {x, y} in its clip, scaled about its centre.
fn placeCopy(node: *Node, alloc: Allocator, x: f32, y: f32, scale: f32) void {
    const ext = node.style.ensureExtFallible(alloc) catch return;
    ext.inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
    node.snapTransition(alloc, .scale_x, scale);
    node.snapTransition(alloc, .scale_y, scale);
    node.markLayoutDirty();
}

/// Absolute rectangle {x, y, w, h} with a capsule corner.
fn placeRect(node: *Node, alloc: Allocator, r: [4]f32) void {
    node.style.width = .{ .px = r[2] };
    node.style.height = .{ .px = r[3] };
    node.style.border.radius = r[3] / 2;
    if (node.style.ensureExtFallible(alloc)) |ext| {
        ext.inset = .{ .left = .{ .px = r[0] }, .top = .{ .px = r[1] } };
        ext.corner_radius = core.CornerRadius.uniform(r[3] / 2);
    } else |_| {}
    node.markSizingDirty();
    node.markLayoutDirty();
    node.markRenderDirty();
}

/// Text node whose ink follows a glass (titles over the navigation bar follow the first platter).
const InkText = struct { node: *Node, glass: *glass_box.AdaptiveGlassBoxState, secondary: bool };

pub const BarRuntime = struct {
    cx: *Cx,
    root: *Node,
    items: std.ArrayListUnmanaged(*Item) = .empty,
    texts: std.ArrayListUnmanaged(InkText) = .empty,
    tabs: ?*Tabs = null,

    fn refresh(self: *BarRuntime) void {
        for (self.items.items) |it| {
            if (it.icon) |n| if (n.setTint(it.ink(Item.iconInk))) n.markRenderDirty();
            if (it.label) |n| n.setTextColor(it.ink(Item.labelInk));
        }
        if (self.tabs) |t| if (t.ready) {
            const g = t.platter;
            t.plate.setBackground(selectionPlate(g.live_luminance_srgb, g.family_ink_mix));
            const sel = glass_box.familyInk(g, light_ink.selected, dark_ink.selected);
            for (t.accents) |acc| {
                if (acc.icon.setTint(sel)) acc.icon.markRenderDirty();
                acc.label.setTextColor(sel);
            }
            const plain = glass_box.familyInk(g, light_ink.icon, dark_ink.icon);
            for (t.plain) |c| {
                if (c.icon.setTint(plain)) c.icon.markRenderDirty();
                c.label.setTextColor(plain);
            }
        };
        for (self.texts.items) |t| {
            const c = glass_box.familyInk(t.glass, if (t.secondary) light_ink.secondary else light_ink.primary, if (t.secondary) dark_ink.secondary else dark_ink.primary);
            t.node.setTextColor(c);
        }
    }

    fn destroy(self: *BarRuntime, alloc: Allocator) void {
        for (self.items.items) |it| alloc.destroy(it);
        self.items.deinit(alloc);
        self.texts.deinit(alloc);
        if (self.tabs) |t| t.destroy(alloc);
        alloc.destroy(self);
    }
};

fn newRuntime(scope: *Scope, cx: *Cx, root: *Node) !*BarRuntime {
    const rt = try scope.allocator.create(BarRuntime);
    rt.* = .{ .cx = cx, .root = root };
    try scope.adoptResource(@ptrCast(rt), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const r: *BarRuntime = @ptrCast(@alignCast(ptr));
            r.destroy(alloc);
        }
    }.cleanup);
    root.meta.per_frame.hooks.before_render.main = barBeforeRender;
    root.behavior.events.event_context = @ptrCast(rt);
    return rt;
}

fn barBeforeRender(node: *Node) void {
    const rt: *BarRuntime = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    if (rt.tabs) |t| t.animate();
    rt.refresh();
}

fn ownsCapture(cx: *Cx, node: *Node) bool {
    return cx.node_registry.resolve(cx.dispatcher.pointer_capture_handle, null) == node;
}

fn itemEvent(event: Event, context: ?*anyopaque) EventResult {
    const it: *Item = @ptrCast(@alignCast(context orelse return .ignored));
    const cx = it.bar.cx;
    switch (event) {
        .mouse_down => |e| {
            if (e.button != .left) return .ignored;
            cx.setPointerCapture(it.node);
            if (!ownsCapture(cx, it.node)) return .stop;
            it.pressed = true;
            if (it.role == .tab) if (it.bar.tabs) |t| t.press(it.tab_index, e.x);
            return .stop;
        },
        .mouse_move => |e| {
            if (!it.pressed or it.role != .tab) return .ignored;
            if (it.bar.tabs) |t| t.dragTo(e.x);
            return .stop;
        },
        .mouse_up => |e| {
            // Another button released while the left is held is not this item's release.
            if (e.button != .left or !it.pressed) return .ignored;
            it.pressed = false;
            if (ownsCapture(cx, it.node)) cx.releasePointerCapture();
            const g = it.node.globalRect();
            const inside = e.x >= g.x and e.x < g.x + g.w and e.y >= g.y and e.y < g.y + g.h;
            if (it.role == .tab) {
                const t = it.bar.tabs orelse return .stop;
                // Last step: the callback may destroy the bar
                if (t.release(it.tab_index, inside)) |to| t.select(to);
                return .stop;
            }
            if (!inside) return .stop;
            cx.needs_redraw = true;
            // Last step: the callback may destroy the bar
            if (it.on_click) |h| h.invoke();
            return .stop;
        },
        else => return .ignored,
    }
}

fn itemCaptureLost(node: *Node) void {
    const it: *Item = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    // A release clears `pressed` before giving the capture up: only a lost press cancels.
    if (!it.pressed) return;
    it.pressed = false;
    if (it.role == .tab) if (it.bar.tabs) |t| t.cancel();
}

/// Register an interactive item; once appended it belongs to the runtime's cleanup.
fn addItem(scope: *Scope, rt: *BarRuntime, item: Item) !*Item {
    // Items take the node's event slots: the glass they sit on must not be interactive.
    std.debug.assert(item.node.behavior.events.on_event == null);
    const it = try scope.allocator.create(Item);
    it.* = item;
    it.bar = rt;
    rt.items.append(scope.allocator, it) catch |err| {
        scope.allocator.destroy(it);
        return err;
    };
    it.node.behavior.events.event_context = @ptrCast(it);
    it.node.behavior.events.on_event = itemEvent;
    it.node.on_capture_lost = itemCaptureLost;
    (try it.node.style.ensureExtFallible(rt.cx.allocator)).hit_roles = .{ .pointer = true };
    return it;
}

// ============================================================================
// Shared pieces
// ============================================================================

/// A glass platter. `width` null = fit the content with `pad` on both sides (text items).
fn capsule(scope: *Scope, cx: *Cx, parent: *Node, width: ?f32, height: f32, pad: f32, idiom: GlassIdiom, tint: ?Color) !glass_box.GlassBoxMount {
    const g = try glass_box.GlassBox(.{
        .width = width,
        .height = height,
        .shape = if (width != null and width.? == height) @as(glass_box.GlassBoxShape, .circle) else .capsule,
        .idiom = idiom,
        .tint_color = tint,
        .padding = .{ .left = pad, .right = pad },
        .body_gap = 0,
    }).mountWithState(scope, cx);
    _ = try core.adoptChild(cx, cx.allocator, parent, g.box);
    g.body.style.direction = .row;
    g.body.style.align_items = .center;
    g.body.style.justify = .center;
    g.body.style.height = .{ .grow = .{} };
    return g;
}

fn iconNode(cx: *Cx, parent: *Node, asset: svg_assets.Asset, size: f32) !*Node {
    return core.adoptChild(cx, cx.allocator, parent, try core.iconTint(cx, asset, light_ink.icon, .{
        .width = .{ .px = size },
        .height = .{ .px = size },
    }));
}

/// UINavigationItem's subtitle: 12 pt regular, and UIKit sets it in Helvetica, not the system
/// font (the Simulator's view dump: [12, 'Helvetica']); the default family is the closer one.
fn subtitleNode(cx: *Cx, parent: *Node, content: []const u8, idiom: GlassIdiom) !*Node {
    return textNodeFamily(cx, parent, content, 12, 400, idiom, 0);
}

fn textNode(cx: *Cx, parent: *Node, content: []const u8, size: f32, weight: u16, idiom: GlassIdiom) !*Node {
    return textNodeFamily(cx, parent, content, size, weight, idiom, types.font_family_system_ui);
}

fn textNodeFamily(cx: *Cx, parent: *Node, content: []const u8, size: f32, weight: u16, idiom: GlassIdiom, family: u16) !*Node {
    return core.adoptChild(cx, cx.allocator, parent, try core.text(cx, content, .{
        .color = light_ink.primary,
        .font_size = size,
        .font_weight = weight,
        // textNode: the system UI font, as UIKit / AppKit bars draw (the default family is
        // Helvetica Neue: "Library" 7 % narrower than native at 10 pt)
        .font_family = family,
        .line_height = 1.2,
        .selectable = false,
        // UIKit draws glyphs unsmoothed (macOS smoothing put 23-46 % more ink on the labels)
        .font_smoothing = idiom != .ios,
    }));
}

fn mountGroup(scope: *Scope, cx: *Cx, rt: *BarRuntime, row: *Node, g: BarGroup, m: BarMetrics, idiom: GlassIdiom) !void {
    const a = cx.allocator;
    switch (g) {
        .flexible_space => _ = try core.adoptChild(cx, a, row, try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 1 } }, .{})),
        .icons => |icons| {
            const n: f32 = @floatFromInt(icons.len);
            // A lone image item is a circle as tall as the bar (native "+": 44 x 44, item 36 x 36).
            const w = if (icons.len == 1) m.height else 2 * m.inset + n * m.item_width + @max(n - 1, 0) * m.item_gap;
            const cap = try capsule(scope, cx, row, w, m.height, 0, idiom, null);
            cap.body.style.gap = m.item_gap;
            for (icons) |b| {
                const node = try core.adoptChild(cx, a, cap.body, try box(cx, .{ .width = .{ .px = m.item_width }, .height = .{ .px = m.item_height }, .justify = .center, .align_items = .center }, .{}));
                const ic = try iconNode(cx, node, b.icon, m.icon_size);
                node.behavior.interaction.a11y = .{ .role = .button, .label = b.label };
                if (b.test_id) |tid| node.meta.ownership.meta.test_id = tid;
                _ = try addItem(scope, rt, .{ .bar = rt, .glass = cap.state, .node = node, .icon = ic, .on_click = b.on_click });
            }
        },
        .text => |t| {
            const cap = try capsule(scope, cx, row, null, m.height, m.text_padding, idiom, null);
            const label = try textNode(cx, cap.body, t.title, 17, 400, idiom);
            cap.box.behavior.interaction.a11y = .{ .role = .button, .label = t.title };
            if (t.test_id) |tid| cap.box.meta.ownership.meta.test_id = tid;
            _ = try addItem(scope, rt, .{ .bar = rt, .glass = cap.state, .node = cap.box, .label = label, .on_click = t.on_click });
        },
        .prominent => |p| {
            const cap = if (p.title != null)
                try capsule(scope, cx, row, null, m.height, m.text_padding, idiom, p.tint)
            else
                try capsule(scope, cx, row, m.height, m.height, 0, idiom, p.tint);
            var item: Item = .{ .bar = rt, .glass = cap.state, .node = cap.box, .role = .prominent, .on_click = p.on_click };
            if (p.title) |t| {
                item.label = try textNode(cx, cap.body, t, 17, 600, idiom);
            } else if (p.icon) |ic| {
                item.icon = try iconNode(cx, cap.body, ic, m.icon_size);
            }
            cap.box.behavior.interaction.a11y = .{ .role = .button, .label = p.title orelse p.label };
            if (p.test_id) |tid| cap.box.meta.ownership.meta.test_id = tid;
            _ = try addItem(scope, rt, item);
        },
    }
}

fn mountGroups(scope: *Scope, cx: *Cx, rt: *BarRuntime, row: *Node, groups: []const BarGroup, m: BarMetrics, idiom: GlassIdiom) !void {
    for (groups) |g| try mountGroup(scope, cx, rt, row, g, m, idiom);
}

pub const BarResult = struct { root: *Node, runtime: *BarRuntime };

// ============================================================================
// Navigation bar
// ============================================================================

pub const GlassNavigationBarProps = struct {
    title: []const u8 = "",
    /// UINavigationItem.subtitle (inline: 15 pt title over a 12 pt subtitle; without one the
    /// title is 17 pt and centered)
    subtitle: []const u8 = "",
    /// prefersLargeTitles: a 34 pt bold title block below the row
    large_title: bool = false,
    /// Back button (a 44 pt glass circle with a chevron); null = none
    back: ?Handler(void) = null,
    back_icon: svg_assets.Asset = @import("zenit_system_icons").chevron_left,
    back_test_id: ?[]const u8 = null,
    /// Trailing groups, laid out leading to trailing
    trailing: []const BarGroup = &.{},
    width: ?f32 = null,
    idiom: GlassIdiom = .ios,
    test_id: ?[]const u8 = null,
};

pub fn GlassNavigationBar(props: anytype) GlassNavigationBarBuilder {
    return .{ .props = reactive.props.coerce(GlassNavigationBarProps, props) };
}

pub const GlassNavigationBarBuilder = struct {
    props: GlassNavigationBarProps,

    pub fn mount(self: GlassNavigationBarBuilder, scope: *Scope, cx: *Cx) !BarResult {
        const p = self.props;
        const m = nav_metrics;
        const my_scope = try scope.childScope();
        var bound = false;
        errdefer if (!bound) my_scope.dispose();
        const a = cx.allocator;
        const root = try box(cx, .{
            .width = if (p.width) |w| .{ .px = w } else .{ .grow = .{} },
            .direction = .column,
        }, .{});
        errdefer cx.freeNode(root);
        root.meta.ownership.meta.component_name = "GlassNavigationBar";
        if (p.test_id) |tid| root.meta.ownership.meta.test_id = tid;
        root.behavior.interaction.a11y = .{ .role = .group, .label = "Navigation bar" };
        try core.bindScopeToNode(my_scope, root);
        bound = true;
        const rt = try newRuntime(my_scope, cx, root);

        const row = try core.adoptChild(cx, a, root, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = nav_row_height },
            .direction = .row,
            .align_items = .start,
            .padding = .{ .left = m.margin, .right = m.margin },
            .gap = m.group_gap,
            .position = .relative,
        }, .{}));
        // Ink of free-standing titles follows the first platter's family (the bar's backdrop).
        var ink_glass: ?*glass_box.AdaptiveGlassBoxState = null;
        if (p.back) |h| {
            const cap = try capsule(my_scope, cx, row, m.height, m.height, 0, p.idiom, null);
            const ic = try iconNode(cx, cap.body, p.back_icon, m.icon_size);
            cap.box.behavior.interaction.a11y = .{ .role = .button, .label = "Back" };
            if (p.back_test_id) |tid| cap.box.meta.ownership.meta.test_id = tid;
            _ = try addItem(my_scope, rt, .{ .bar = rt, .glass = cap.state, .node = cap.box, .icon = ic, .on_click = h });
            ink_glass = cap.state;
        }
        // Title: leading (after the back button) when there is one, otherwise centered on the bar.
        const show_inline = !p.large_title and p.title.len > 0;
        const title_col = try core.adoptChild(cx, a, row, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = m.height },
            .direction = .column,
            .justify = .center,
            .align_items = if (p.back != null) .start else .center,
        }, .{}));
        var title_nodes: [2]?*Node = .{ null, null };
        if (show_inline) {
            const has_sub = p.subtitle.len > 0;
            title_nodes[0] = try textNode(cx, title_col, p.title, if (has_sub) 15 else 17, 600, p.idiom);
            if (has_sub) title_nodes[1] = try subtitleNode(cx, title_col, p.subtitle, p.idiom);
        }
        try mountGroups(my_scope, cx, rt, row, p.trailing, m, p.idiom);
        if (ink_glass == null and rt.items.items.len > 0) ink_glass = rt.items.items[0].glass;
        if (p.large_title) {
            const block = try core.adoptChild(cx, a, root, try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .px = large_title_height },
                .direction = .column,
                .padding = .{ .left = m.margin, .top = 6.7 },
            }, .{}));
            title_nodes[0] = try textNode(cx, block, p.title, 34, 700, p.idiom);
            if (p.subtitle.len > 0) title_nodes[1] = try subtitleNode(cx, block, p.subtitle, p.idiom);
        }
        if (ink_glass) |g| for (title_nodes, 0..) |tn, i| if (tn) |n| try rt.texts.append(my_scope.allocator, .{ .node = n, .glass = g, .secondary = i == 1 });
        rt.refresh();
        return .{ .root = root, .runtime = rt };
    }
};

// ============================================================================
// Bottom toolbar
// ============================================================================

pub const GlassBottomToolbarProps = struct {
    groups: []const BarGroup = &.{},
    width: ?f32 = null,
    idiom: GlassIdiom = .ios,
    test_id: ?[]const u8 = null,
};

pub fn GlassBottomToolbar(props: anytype) GlassBottomToolbarBuilder {
    return .{ .props = reactive.props.coerce(GlassBottomToolbarProps, props) };
}

pub const GlassBottomToolbarBuilder = struct {
    props: GlassBottomToolbarProps,

    pub fn mount(self: GlassBottomToolbarBuilder, scope: *Scope, cx: *Cx) !BarResult {
        const p = self.props;
        const m = toolbar_metrics;
        const my_scope = try scope.childScope();
        var bound = false;
        errdefer if (!bound) my_scope.dispose();
        const root = try box(cx, .{
            .width = if (p.width) |w| .{ .px = w } else .{ .grow = .{} },
            .height = .{ .px = m.height },
            .direction = .row,
            .align_items = .center,
            .padding = .{ .left = m.margin, .right = m.margin },
            .gap = m.group_gap,
        }, .{});
        errdefer cx.freeNode(root);
        root.meta.ownership.meta.component_name = "GlassBottomToolbar";
        if (p.test_id) |tid| root.meta.ownership.meta.test_id = tid;
        root.behavior.interaction.a11y = .{ .role = .group, .label = "Toolbar" };
        try core.bindScopeToNode(my_scope, root);
        bound = true;
        const rt = try newRuntime(my_scope, cx, root);
        try mountGroups(my_scope, cx, rt, root, p.groups, m, p.idiom);
        rt.refresh();
        return .{ .root = root, .runtime = rt };
    }
};

// ============================================================================
// Tab bar
// ============================================================================

pub const TabItem = struct {
    icon: svg_assets.Asset,
    label: []const u8,
    test_id: ?[]const u8 = null,
};

pub const GlassTabBarProps = struct {
    tabs: []const TabItem = &.{},
    selected: Model(usize) = .{ .local = 0 },
    on_change: ?Handler(usize) = null,
    /// Search tab (UISearchTab): a separate 62 pt glass circle at the trailing end; null = none
    search: ?BarIcon = null,
    /// Bar width (the platter spans width - 2 * 21, minus the search circle and its gap)
    width: f32 = 402,
    idiom: GlassIdiom = .ios,
    test_id: ?[]const u8 = null,
    /// Fixture: mount with the finger held on a tab (steady lifted state, optionally dragged by
    /// `offset` pt), for captures compared against the native traces. null = normal.
    held: ?HeldFixture = null,
};

pub const HeldFixture = struct { tab: usize, offset: f32 = 0 };

pub fn GlassTabBar(props: anytype) GlassTabBarBuilder {
    return .{ .props = reactive.props.coerce(GlassTabBarProps, props) };
}

pub const GlassTabBarBuilder = struct {
    props: GlassTabBarProps,

    pub fn mount(self: GlassTabBarBuilder, scope: *Scope, cx: *Cx) !BarResult {
        const p = self.props;
        const my_scope = try scope.childScope();
        var bound = false;
        errdefer if (!bound) my_scope.dispose();
        const a = cx.allocator;
        const root = try box(cx, .{
            .width = .{ .px = p.width },
            .height = .{ .px = tab_height },
            .position = .relative,
        }, .{});
        errdefer cx.freeNode(root);
        root.meta.ownership.meta.component_name = "GlassTabBar";
        if (p.test_id) |tid| root.meta.ownership.meta.test_id = tid;
        root.behavior.interaction.a11y = .{ .role = .tablist, .label = "Tab bar" };
        try core.bindScopeToNode(my_scope, root);
        bound = true;
        const rt = try newRuntime(my_scope, cx, root);
        // Resolve before allocating so a failure leaves nothing outside rt's cleanup.
        const selected = try reactive.resolveModel(usize, my_scope, p.selected);
        const n = p.tabs.len;
        const platter_w = p.width - 2 * tab_margin - (if (p.search != null) tab_height + tab_search_gap else 0);
        const inner = platter_w - 2 * tab_inset;
        const nf: f32 = @floatFromInt(@max(n, 1));
        const btn_w = @min(inner, inner / nf * tab_button_overlap);
        const step = if (n > 1) (inner - btn_w) / (nf - 1) else 0;

        // Glass: the platter and the search circle in one container (they fuse when the pressed
        // platter grows into the gap).
        const group = try glass_group.GlassGroup(.{
            .spacing = tab_merge_spacing,
            .merge = .always,
            .width = p.width - 2 * tab_margin + 2 * tab_glass_bleed,
            .height = tab_height + 2 * tab_glass_bleed,
            .gap = 0,
        }).mountWithState(my_scope, cx);
        _ = try core.adoptChild(cx, a, root, group.container);
        group.container.style.position = .absolute;
        (try group.container.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = tab_margin - tab_glass_bleed }, .top = .{ .px = -tab_glass_bleed } };
        const cap = try glass_group.GlassShape(.{
            .width = platter_w,
            .height = tab_height,
            .shape = .capsule,
            .idiom = p.idiom,
            .padding = Padding.all(0),
            .body_gap = 0,
        }).mountIn(group, my_scope, cx);
        cap.node.style.position = .absolute;
        (try cap.node.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = tab_glass_bleed }, .top = .{ .px = tab_glass_bleed } };
        const search_shape: ?glass_group.GlassShapeEntry = if (p.search != null) try glass_group.GlassShape(.{
            .width = tab_height,
            .height = tab_height,
            .shape = .circle,
            .idiom = p.idiom,
            .padding = Padding.all(0),
            .body_gap = 0,
        }).mountIn(group, my_scope, cx) else null;
        if (search_shape) |sc| {
            sc.node.style.position = .absolute;
            (try sc.node.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = tab_glass_bleed + platter_w + tab_search_gap }, .top = .{ .px = tab_glass_bleed } };
            sc.body.style.direction = .row;
            sc.body.style.align_items = .center;
            sc.body.style.justify = .center;
            sc.body.style.height = .{ .grow = .{} };
        }

        // Layers over the platter, in its rest frame: the selection plate, the plain tabs with
        // the lens cut out, the clear lens, the accent tabs masked to the lens, the hit targets.
        const holder = try core.adoptChild(cx, a, root, try box(cx, .{
            .width = .{ .px = platter_w },
            .height = .{ .px = tab_height },
            .position = .absolute,
        }, .{}));
        (try holder.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = tab_margin }, .top = .{ .px = 0 } };
        const plate = try core.adoptChild(cx, a, holder, try box(cx, .{
            .width = .{ .px = btn_w },
            .height = .{ .px = tab_button_height },
            .position = .absolute,
            .background = light_ink.selection_plate,
            .corner_radius = tab_button_height / 2,
        }, .{}));
        const tabs = try my_scope.allocator.create(Tabs);
        tabs.* = .{
            .cx = cx,
            .selected = selected,
            .on_change = p.on_change,
            .centers = &.{},
            .plain = &.{},
            .accents = &.{},
            .platter = cap.state,
            .platter_size = .{ platter_w, tab_height },
            .holder = holder,
            .plate = plate,
            .lens = undefined,
            .clip = undefined,
            .plain_left = undefined,
            .plain_right = undefined,
            .btn_w = btn_w,
            .motion = undefined,
            .last_ms = cx.frame_time_ms,
            .shown = 0,
        };
        rt.tabs = tabs;
        // The pressed platter grows 5 % (62 -> 65 pt, past the 64 pt limit where glass stops
        // adapting to its backdrop): the family decision keeps the rest height, so a press never
        // flips the bar to the appearance family (a dark-theme app on a white page went gray).
        glass_box.glassSetFamilyExtent(cap.state, @min(platter_w, tab_height));
        tabs.centers = try my_scope.allocator.alloc(f32, n);
        for (tabs.centers, 0..) |*c, i| c.* = tab_inset + step * @as(f32, @floatFromInt(i)) + btn_w / 2;
        // Plain tabs, in two clips that leave the lens out
        const clip_style = core.BoxStyle{ .width = .{ .px = platter_w }, .height = .{ .px = tab_height }, .position = .absolute, .overflow_hidden = true };
        tabs.plain_left = try core.adoptChild(cx, a, holder, try box(cx, clip_style, .{}));
        tabs.plain_right = try core.adoptChild(cx, a, holder, try box(cx, clip_style, .{}));
        tabs.plain = try my_scope.allocator.alloc(TabCopy, 2 * n);
        for (0..2 * n) |k| {
            const parent = if (k < n) tabs.plain_left else tabs.plain_right;
            const node = try core.adoptChild(cx, a, parent, try tabButton(cx, p.tabs[k % n], btn_w, light_ink.icon, p.idiom));
            tabs.plain[k] = .{ .node = node, .icon = node.children.items[0], .label = node.children.items[1].children.items[0] };
        }
        // The clear lens over the plain tabs and the platter. The accent copies go above it (native
        // _UILiquidLensView: the portal sits over the glass layers with its own displacement):
        // the lens's rim samples 20-40 pt deep (glass.metal tab_lens_field) and must find the platter
        // there, not the accent glyphs.
        const lens = try glass_box.GlassBox(.{
            .width = btn_w,
            .height = tab_button_height,
            .shape = .capsule,
            .glass_style = .clear,
            .material = .tab_lens,
            .idiom = p.idiom,
            .padding = Padding.all(0),
            .body_gap = 0,
        }).mountWithState(my_scope, cx);
        lens.box.style.position = .absolute;
        _ = try core.adoptChild(cx, a, holder, lens.box);
        glass_box.glassSetMaterializeLevel(lens.state, 0);
        tabs.lens = lens.state;
        // Accent tabs, masked to the lens
        tabs.clip = try core.adoptChild(cx, a, holder, try box(cx, .{
            .width = .{ .px = btn_w },
            .height = .{ .px = tab_button_height },
            .position = .absolute,
            .overflow_hidden = true,
            .corner_radius = tab_button_height / 2,
        }, .{}));
        // The accent copies are a portal of the bar content: their surface is warped at the lens
        // contour (native straddle: the Library bars merge toward the cap).
        (try tabs.clip.style.ensureExtFallible(a)).content_warp = debugContentWarp() orelse tab_portal_warp;
        tabs.accents = try my_scope.allocator.alloc(TabCopy, n);
        for (p.tabs, tabs.accents) |t, *acc| {
            const node = try core.adoptChild(cx, a, tabs.clip, try tabButton(cx, t, btn_w, light_ink.selected, p.idiom));
            acc.* = .{ .node = node, .icon = node.children.items[0], .label = node.children.items[1].children.items[0] };
        }
        if (p.test_id) |tid| {
            // Layer anchors for the dynamics instruments (ios/compare_tab_dynamics.py); the
            // nodes own their copies (freed with the node)
            try ownTestId(a, lens.box, "{s}.lens", .{tid});
            try ownTestId(a, plate, "{s}.plate", .{tid});
            try ownTestId(a, tabs.clip, "{s}.portal", .{tid});
            try ownTestId(a, cap.node, "{s}.platter", .{tid});
            for (tabs.accents, 0..) |acc, i| try ownTestId(a, acc.node, "{s}.accent.{d}", .{ tid, i });
        }
        // Hit targets on top (the drawn copies move; the targets keep the rest layout)
        for (p.tabs, 0..) |t, i| {
            const node = try core.adoptChild(cx, a, holder, try box(cx, .{
                .width = .{ .px = btn_w },
                .height = .{ .px = tab_button_height },
                .position = .absolute,
            }, .{}));
            (try node.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = tabs.centers[i] - btn_w / 2 }, .top = .{ .px = tab_inset } };
            node.behavior.interaction.a11y = .{ .role = .tab, .label = t.label };
            if (t.test_id) |tid| node.meta.ownership.meta.test_id = tid;
            _ = try addItem(my_scope, rt, .{ .bar = rt, .glass = cap.state, .node = node, .role = .tab, .tab_index = i });
        }
        const sel0 = tabs.selectedIndex();
        tabs.shown = sel0;
        tabs.motion = TabMotion.init(.{ btn_w, tab_button_height }, platter_w / 2, if (n > 0) tabs.centers[sel0] else platter_w / 2);
        tabs.ready = true;
        if (p.held) |h| if (n > 0) {
            const i = @min(h.tab, n - 1);
            tabs.motion.press(tabs.centers[i]);
            if (h.offset != 0) tabs.motion.drag(std.math.clamp(tabs.centers[i] + h.offset, tabs.centers[0], tabs.centers[n - 1]));
            for (0..40) |_| tabs.motion.step(0.1);
        };
        tabs.place();
        if (p.search) |s| {
            const sc = search_shape.?;
            const ic = try iconNode(cx, sc.body, s.icon, 24);
            sc.node.behavior.interaction.a11y = .{ .role = .button, .label = if (s.label.len > 0) s.label else "Search" };
            if (s.test_id) |tid| sc.node.meta.ownership.meta.test_id = tid;
            _ = try addItem(my_scope, rt, .{ .bar = rt, .glass = sc.state, .node = sc.node, .icon = ic, .on_click = s.on_click });
        }
        try my_scope.createEffect(rt, struct {
            fn run(r: *BarRuntime) void {
                if (r.tabs) |t| _ = t.selected.readAs(true);
                r.cx.needs_redraw = true;
                r.root.markRenderDirty();
            }
        }.run);
        rt.refresh();
        return .{ .root = root, .runtime = rt };
    }
};

// ============================================================================
// Glass button
// ============================================================================

/// UIButton.Configuration: .glass(), .prominentGlass(), .clearGlass(), .prominentClearGlass().
pub const GlassButtonStyle = enum { glass, prominent_glass, clear_glass, prominent_clear_glass };

pub const GlassButtonProps = struct {
    title: []const u8 = "",
    /// Image-only when title is empty: a 48 pt circle (24 pt image)
    icon: ?svg_assets.Asset = null,
    /// Accessibility name for an image-only button
    label: []const u8 = "",
    style: GlassButtonStyle = .glass,
    tint: Color = prominent_tint,
    on_click: ?Handler(void) = null,
    idiom: GlassIdiom = .ios,
    test_id: ?[]const u8 = null,
};

/// prominentClearGlass reads 144 over gray 128 in both appearances (clear alone: 152): clear glass
/// with a faint neutral darkening, approximated as a 5 % black tint.
pub const prominent_clear_dim = Color.rgba(0, 0, 0, 13);

pub fn GlassButton(props: anytype) GlassButtonBuilder {
    return .{ .props = reactive.props.coerce(GlassButtonProps, props) };
}

pub const GlassButtonBuilder = struct {
    props: GlassButtonProps,

    pub fn mount(self: GlassButtonBuilder, scope: *Scope, cx: *Cx) !BarResult {
        const p = self.props;
        const my_scope = try scope.childScope();
        var bound = false;
        errdefer if (!bound) my_scope.dispose();
        const root = try box(cx, .{}, .{});
        errdefer cx.freeNode(root);
        root.meta.ownership.meta.component_name = "GlassButton";
        if (p.test_id) |tid| root.meta.ownership.meta.test_id = tid;
        try core.bindScopeToNode(my_scope, root);
        bound = true;
        const rt = try newRuntime(my_scope, cx, root);
        const icon_only = p.title.len == 0;
        const clear = p.style == .clear_glass or p.style == .prominent_clear_glass;
        const tint: ?Color = switch (p.style) {
            .prominent_glass => p.tint,
            .prominent_clear_glass => prominent_clear_dim,
            else => null,
        };
        const g = try glass_box.GlassBox(.{
            .width = if (icon_only) button_image_diameter else null,
            .height = if (icon_only) button_image_diameter else button_height,
            .shape = if (icon_only) @as(glass_box.GlassBoxShape, .circle) else .capsule,
            .idiom = p.idiom,
            .glass_style = if (clear) glass_box.GlassEffectStyle.clear else .regular,
            .tint_color = tint,
            .padding = if (icon_only) Padding.all(0) else Padding{ .left = button_padding, .right = button_padding },
            .body_gap = 0,
        }).mountWithState(my_scope, cx);
        _ = try core.adoptChild(cx, cx.allocator, root, g.box);
        g.body.style.direction = .row;
        g.body.style.align_items = .center;
        g.body.style.justify = .center;
        g.body.style.height = .{ .grow = .{} };
        g.box.behavior.interaction.a11y = .{ .role = .button, .label = if (icon_only) p.label else p.title };
        var item: Item = .{ .bar = rt, .glass = g.state, .node = g.box, .role = if (p.style == .prominent_glass) .prominent else .plain, .on_click = p.on_click };
        if (icon_only) {
            if (p.icon) |ic| item.icon = try iconNode(cx, g.body, ic, button_image_size);
        } else {
            item.label = try textNode(cx, g.body, p.title, 17, 400, p.idiom);
        }
        _ = try addItem(my_scope, rt, item);
        rt.refresh();
        return .{ .root = root, .runtime = rt };
    }
};

// ============================================================================
// Tests
// ============================================================================

const theme = core.theme;

test {
    _ = tab_motion;
}

fn testCx() !*Cx {
    const ctx = try Cx.init(std.testing.allocator, std.testing.io);
    ctx.tokens = &theme.light;
    return ctx;
}

test "selectionPlate: lands on the native plate over the native body (light and dark family)" {
    const over = struct {
        fn light(body: f32, c: Color) f32 {
            return body * (1 - @as(f32, @floatFromInt(c.a)) / 255);
        }
        fn dark(body: f32, c: Color) f32 {
            const a = @as(f32, @floatFromInt(c.a)) / 255;
            return body + (255 - body) * a;
        }
    };
    // light family: gray 128 -> body 205 plate 181; white -> 253 / 235; gray 64 -> 174 / 146
    try std.testing.expectApproxEqAbs(@as(f32, 181), over.light(205, selectionPlate(128.0 / 255.0, 0)), 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 235), over.light(253, selectionPlate(1.0, 0)), 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 146), over.light(174, selectionPlate(64.0 / 255.0, 0)), 1.5);
    // dark family: gray 128 -> body 89 plate 120; black -> 19 / 53
    try std.testing.expectApproxEqAbs(@as(f32, 120), over.dark(89, selectionPlate(128.0 / 255.0, 1)), 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 53), over.dark(19, selectionPlate(0, 1)), 1.5);
    // no reading yet: the gray-128 calibration
    try std.testing.expect(Color.eql(light_ink.selection_plate, selectionPlate(null, 0)));
}

test "GlassNavigationBar: measured UIKit grouping and metrics" {
    var ctx = try testCx();
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const icons = @import("zenit_system_icons");
    const Noop = struct {
        fn f(_: *@This()) void {}
    };
    var noop = Noop{};
    const items = [_]BarIcon{ .{ .icon = icons.more_horizontal }, .{ .icon = icons.upload } };
    const r = try GlassNavigationBar(.{
        .title = "Message",
        .subtitle = "2 unread",
        .back = ctx.on(Noop, &noop, Noop.f),
        .trailing = &[_]BarGroup{ .{ .icons = &items }, .{ .prominent = .{ .title = "Done" } } },
        .width = 402,
    }).mount(scope, ctx);
    const root = try box(ctx, .{ .width = .{ .px = 402 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    try root.appendChild(std.testing.allocator, r.root);
    ctx.layout();
    // back (44 circle) + two image items + Done
    try std.testing.expectEqual(@as(usize, 4), r.runtime.items.items.len);
    const back = r.runtime.items.items[0].node.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 16), back.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 44), back.w, 0.01);
    // the two image items share one capsule: 4 + 38 + 16 + 38 + 4 = 100 (native 100.7)
    try std.testing.expect(r.runtime.items.items[1].glass == r.runtime.items.items[2].glass);
    const cap = r.runtime.items.items[1].glass.root.?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 100), cap.w, 0.01);
    // Done is its own tinted capsule, flush with the 16 pt trailing margin
    const done = r.runtime.items.items[3];
    try std.testing.expect(done.glass != r.runtime.items.items[1].glass);
    try std.testing.expect(done.glass.tint_override != null);
    const d = done.node.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 402 - 16), d.x + d.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 12), d.x - (cap.x + cap.w), 0.5);
    // every platter renders with the iOS profile
    try std.testing.expect(done.glass.profile == &glass_box.profile.ios);
}

test "GlassTabBar: platter, search circle and selection" {
    var ctx = try testCx();
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const icons = @import("zenit_system_icons");
    const tabs = [_]TabItem{ .{ .icon = icons.home, .label = "Home" }, .{ .icon = icons.copy, .label = "Library" }, .{ .icon = icons.audio, .label = "Radio" } };
    const sel = try scope.createSignal(usize, 0);
    const r = try GlassTabBar(.{ .tabs = &tabs, .selected = sel, .search = .{ .icon = icons.search } }).mount(scope, ctx);
    const root = try box(ctx, .{ .width = .{ .px = 402 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    try root.appendChild(std.testing.allocator, r.root);
    ctx.layout();
    // native: 290 pt platter at 21, 62 pt search circle 8 pt after it; 3 tabs 100.7 wide
    const platter = r.runtime.items.items[0].glass.root.?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 21), platter.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 290), platter.w, 0.01);
    const tab0 = r.runtime.items.items[0].node.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 100.7), tab0.w, 0.05);
    const search = r.runtime.items.items[3].node.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 319), search.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 62), search.w, 0.01);
    // at rest the plate and the accent mask cover the selected tab; the clear lens is absent
    const t = r.runtime.tabs.?;
    try std.testing.expect(t.lens.materialize_level == 0 and !t.lens.enabled);
    try std.testing.expectApproxEqAbs(tab0.x, t.plate.globalRect().x, 0.01);
    try std.testing.expectApproxEqAbs(tab0.x, t.clip.globalRect().x, 0.01);
    // a tap sends the lens on touch-down; the selection commits on release
    _ = itemEvent(.{ .mouse_down = .{ .x = 180, .y = 30, .button = .left } }, r.runtime.items.items[1]);
    try std.testing.expect(t.motion.down);
    try std.testing.expectEqual(@as(usize, 0), sel.get());
    _ = itemEvent(.{ .mouse_up = .{ .x = 180, .y = 30, .button = .left } }, r.runtime.items.items[1]);
    try std.testing.expectEqual(@as(usize, 1), sel.get());
    try std.testing.expect(!t.motion.settled());
    for (0..240) |_| {
        ctx.frame_time_ms += 1000.0 / 60.0;
        t.animate();
    }
    ctx.layout();
    const tab1 = r.runtime.items.items[1].node.globalRect();
    try std.testing.expect(t.motion.settled());
    try std.testing.expectApproxEqAbs(tab1.x, t.plate.globalRect().x, 0.05);
    try std.testing.expectApproxEqAbs(tab1.x, t.clip.globalRect().x, 0.05);
    // a long press dragged to Radio commits Radio on release (the capture release must not
    // cancel the drag)
    _ = itemEvent(.{ .mouse_down = .{ .x = 70, .y = 50, .button = .left } }, r.runtime.items.items[0]);
    _ = itemEvent(.{ .mouse_move = .{ .x = 150, .y = 50 } }, r.runtime.items.items[0]);
    _ = itemEvent(.{ .mouse_move = .{ .x = 270, .y = 50 } }, r.runtime.items.items[0]);
    try std.testing.expect(t.motion.dragging);
    _ = itemEvent(.{ .mouse_up = .{ .x = 270, .y = 50, .button = .left } }, r.runtime.items.items[0]);
    try std.testing.expectEqual(@as(usize, 2), sel.get());
    try std.testing.expectApproxEqAbs(t.centers[2], t.motion.target, 0.01);
    // a lost capture mid-press returns the lens to the selection
    _ = itemEvent(.{ .mouse_down = .{ .x = 70, .y = 50, .button = .left } }, r.runtime.items.items[0]);
    ctx.releasePointerCapture();
    itemCaptureLost(r.runtime.items.items[0].node);
    try std.testing.expect(!t.motion.down);
    try std.testing.expectApproxEqAbs(t.centers[2], t.motion.target, 0.01);
    try std.testing.expectEqual(@as(usize, 2), sel.get());
    // a programmatic change moves the lens too
    sel.set(0);
    t.animate();
    try std.testing.expect(!t.motion.settled());
    try std.testing.expectApproxEqAbs(t.centers[0], t.motion.target, 0.01);
}

test "GlassTabBar: pressing does not flip the platter to the appearance family (dark theme, white page)" {
    var ctx = try testCx();
    defer ctx.deinit();
    ctx.tokens = &theme.dark; // dark appearance (the framework default; the showcase app ran on it)
    try std.testing.expect(ctx.tokens.scheme == .dark);
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const icons = @import("zenit_system_icons");
    const tabs = [_]TabItem{ .{ .icon = icons.home, .label = "Home" }, .{ .icon = icons.copy, .label = "Library" }, .{ .icon = icons.audio, .label = "Radio" } };
    const r = try GlassTabBar(.{ .tabs = &tabs, .search = .{ .icon = icons.search } }).mount(scope, ctx);
    const root = try box(ctx, .{ .width = .{ .px = 402 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    try root.appendChild(std.testing.allocator, r.root);
    ctx.layout();
    const t = r.runtime.tabs.?;
    const g = t.platter;
    const glass_node = g.root.?;
    // a white page under the bar: the platter has read its backdrop and settled light
    ctx.backdrop_luminance_readback = true;
    ctx.backdrop_luminance_regions[0] = .{ .node_id = g.surface.id, .lum = 1, .lum_srgb = 1 };
    ctx.backdrop_luminance_region_count = 1;
    g.family_probe = false;
    glass_box.glassSetFamilyImmediate(g, false);
    const hooks = glass_node.meta.per_frame.hooks.before_render;
    try std.testing.expect(hooks.count > 0);
    const hook = hooks.hooks[0].?;
    // hold Library: the platter grows 5 % (62 -> 65 pt) for the whole press
    _ = itemEvent(.{ .mouse_down = .{ .x = 180, .y = 30, .button = .left } }, r.runtime.items.items[1]);
    for (0..60) |_| {
        ctx.frame_time_ms += 1000.0 / 60.0;
        ctx.frame_dt_seconds = 1.0 / 60.0;
        t.animate();
        ctx.layout();
        hook(glass_node);
        try std.testing.expect(!g.family_dark);
    }
    try std.testing.expect(glass_node.rectFromWorldOrFallback().h > 64); // the growth really crossed the limit
    _ = itemEvent(.{ .mouse_up = .{ .x = 180, .y = 30, .button = .left } }, r.runtime.items.items[1]);
}

test "GlassTabBar: held accent copy stays on its tab while the lens moves" {
    var ctx = try testCx();
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const icons = @import("zenit_system_icons");
    const tabs = [_]TabItem{ .{ .icon = icons.home, .label = "Home" }, .{ .icon = icons.copy, .label = "Library" }, .{ .icon = icons.audio, .label = "Radio" } };
    // (test_id: the derived layer anchors are owned by their nodes; the testing allocator
    // reports them if they leak)
    const r = try GlassTabBar(.{ .tabs = &tabs, .search = .{ .icon = icons.search }, .test_id = "tb" }).mount(scope, ctx);
    const root = try box(ctx, .{ .width = .{ .px = 402 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    try root.appendChild(std.testing.allocator, r.root);
    ctx.layout();
    const t = r.runtime.tabs.?;
    // press Home (the lens travels from... Home is selected: press Radio so the lens travels)
    _ = itemEvent(.{ .mouse_down = .{ .x = 300, .y = 30, .button = .left } }, r.runtime.items.items[2]);
    // from 0.25 s (the accent and the platter have reached their gains) the finger drags the
    // lens back toward Library; the copy stays on its tab (native: Home accent cx 70.6 -> 70.9
    // while the lens moves)
    var xs: [2]f32 = undefined;
    var ls: [2]f32 = undefined;
    for (0..60) |i| {
        ctx.frame_time_ms += 1000.0 / 60.0;
        if (i > 15 and i <= 40) _ = itemEvent(.{ .mouse_move = .{ .x = 300 - 60 * @as(f32, @floatFromInt(i - 15)) / 25.0, .y = 30 } }, r.runtime.items.items[2]);
        t.animate();
        ctx.layout();
        if (i == 15 or i == 59) {
            xs[if (i == 15) 0 else 1] = t.accents[2].node.globalRect().x;
            ls[if (i == 15) 0 else 1] = t.clip.globalRect().x;
        }
    }
    try std.testing.expect(@abs(ls[1] - ls[0]) > 2);
    try std.testing.expectApproxEqAbs(xs[0], xs[1], 0.4);
    _ = itemEvent(.{ .mouse_up = .{ .x = 300, .y = 30, .button = .left } }, r.runtime.items.items[2]);
}

test "GlassTabBar: a still finger on the lifted lens stops requesting frames, a move resumes them" {
    var ctx = try testCx();
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const icons = @import("zenit_system_icons");
    const tabs = [_]TabItem{ .{ .icon = icons.home, .label = "Home" }, .{ .icon = icons.copy, .label = "Library" }, .{ .icon = icons.audio, .label = "Radio" } };
    const r = try GlassTabBar(.{ .tabs = &tabs }).mount(scope, ctx);
    const root = try box(ctx, .{ .width = .{ .px = 402 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    try root.appendChild(std.testing.allocator, r.root);
    ctx.layout();
    const t = r.runtime.tabs.?;
    _ = itemEvent(.{ .mouse_down = .{ .x = 166, .y = 30, .button = .left } }, r.runtime.items.items[1]);
    var wants: bool = true;
    for (0..240) |_| {
        ctx.frame_time_ms += 1000.0 / 60.0;
        ctx.needs_redraw = false;
        t.animate();
        wants = ctx.needs_redraw;
    }
    try std.testing.expect(t.motion.down);
    try std.testing.expect(!wants);
    _ = itemEvent(.{ .mouse_move = .{ .x = 200, .y = 30 } }, r.runtime.items.items[1]);
    ctx.frame_time_ms += 1000.0 / 60.0;
    ctx.needs_redraw = false;
    t.animate();
    try std.testing.expect(ctx.needs_redraw);
    _ = itemEvent(.{ .mouse_up = .{ .x = 200, .y = 30, .button = .left } }, r.runtime.items.items[1]);
}

test "GlassBottomToolbar and GlassButton: measured sizes and styles" {
    var ctx = try testCx();
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const icons = @import("zenit_system_icons");
    const root = try box(ctx, .{ .width = .{ .px = 402 }, .height = .{ .px = 400 }, .direction = .column }, .{});
    ctx.root = root;
    const items = [_]BarIcon{ .{ .icon = icons.download }, .{ .icon = icons.trash } };
    const tb = try GlassBottomToolbar(.{ .groups = &[_]BarGroup{ .{ .icons = &items }, .flexible_space, .{ .prominent = .{ .icon = icons.edit } } }, .width = 402 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, tb.root);
    const glass = try GlassButton(.{ .title = "Glass" }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, glass.root);
    const clear = try GlassButton(.{ .title = "Clear", .style = .clear_glass }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, clear.root);
    const heart = try GlassButton(.{ .icon = icons.heart }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, heart.root);
    ctx.layout();
    // toolbar: 48 pt platters 28 pt from the sides; shared capsule 5 + 41 + 14 + 41 + 5 = 106
    // (native 106.3); the prominent image item is a 48 pt circle flush with the trailing margin
    const cap = tb.runtime.items.items[0].glass.root.?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 28), cap.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 106), cap.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 48), cap.h, 0.01);
    const prom = tb.runtime.items.items[2].node.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 402 - 28 - 48), prom.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 48), prom.w, 0.01);
    // buttons: 34.33 tall; clear style is clear glass; image-only is a 48 pt circle (native
    // system_controls_*: UIButton 48 x 48, image 24 x 24 at 12, 12)
    try std.testing.expectApproxEqAbs(button_height, glass.runtime.items.items[0].node.globalRect().h, 0.01);
    try std.testing.expectEqual(glass_box.GlassEffectStyle.clear, clear.runtime.items.items[0].glass.variant);
    const h = heart.runtime.items.items[0].node.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 48), h.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 48), h.h, 0.01);
    const hi = heart.runtime.items.items[0].icon.?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 12), hi.x - h.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24), hi.w, 0.01);
}
