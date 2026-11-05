//! text_ink.zig: tight ink bounds of a text paint command.
//!
//! A text command's geom is only its draw origin (x, baseline), so the generic damage bound
//! (PaintFingerprint.damageItemBounds) is a deliberately loose envelope: bytes x em wide,
//! 1.9 em + 20 px tall. Where that envelope decides whether the CPU can present a frame (caret
//! flips, CPU damage patches), it rejects for pixels the text never draws: a status bar line's
//! envelope reaches up over the editor's last line, one keystroke damages two lines' full width.
//!
//! This computes the pixels the encoder's text command actually draws: the glyph quads
//! (glyphQuad: as the text vertex shader places them, incl. synthetic italic skew and snapping)
//! of every instance TextRenderer would emit for it, by running the same font resolution
//! (chooseFonts, shared with RenderCommandEncoder.encodeText) and the renderer's own emit loop in
//! probe mode (TextRenderer.probeInk: no instance stored, atlas read without inserting).
//! A text command paints nothing else: decorations, inline backgrounds and selection are their
//! own paint items.
//!
//! Contract: never smaller than the drawn ink (a miss leaves stale pixels / draws a caret under a
//! glyph). Whenever the exact answer is unavailable (a glyph not resident in the atlas, shaping
//! failure, Windows), callers keep the conservative envelope.
//!
//! Cost: Cache keys the result by the command's text and font parameters and the sub-device-pixel
//! phase of its origin, so an unchanged (or merely moved by whole device pixels) item is one hash
//! of its bytes per frame; only new text runs the probe, whose shaping hits the segment cache.

const std = @import("std");
const text_renderer_mod = @import("text_renderer.zig");
const TextRenderer = text_renderer_mod.TextRenderer;
const FontSelector = @import("command_encoder/font_selector.zig").FontSelector;
const script_detect = @import("command_encoder/script_detect.zig");
const wire_types = @import("command_encoder/wire_types.zig");
const Font = @import("text").Font;

pub const glyphQuad = text_renderer_mod.glyphQuad;

/// Fonts a text command draws with. The single decision point for the encoder's text draw and
/// the ink probe: diverging here would make the bound describe a different draw.
pub const FontChoice = struct {
    font: *Font,
    fallback: ?*Font,
    fixed_advance: f32,
    /// FontSelector.ResolvedFonts.primary / .raster: the animated raster draws
    /// the primary's glyphs from `raster` (never a script fallback's).
    primary: *Font,
    raster: ?*Font,
};

pub fn chooseFonts(
    fonts: *FontSelector,
    tr: *const TextRenderer,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    font_family: u16,
    use_symbols: bool,
    use_monospace: bool,
    monospace_char_width: f32,
    use_italic: bool,
    force_linear: bool,
) FontChoice {
    // Font decisions **all** go to FontSelector.resolveFonts, the same function as the measure
    // side (measure == draw).
    const resolved = fonts.resolveFonts(content, .{
        .stack_mode_override = if (tr.fallback_stack != null) true else null,
        .font_size = font_size,
        .font_weight = font_weight,
        .font_family = font_family,
        .use_italic = use_italic,
        .use_monospace = use_monospace,
        .use_symbols = use_symbols,
        .force_linear = force_linear,
    });
    return .{
        .font = if (tr.font_ranges_provider != null) resolved.shapingFont() else resolved.primary,
        .fallback = resolved.fallback,
        .fixed_advance = script_detect.fixedMonospaceAdvance(content, use_monospace, monospace_char_width),
        .primary = resolved.primary,
        .raster = resolved.raster,
    };
}

/// Spans the encoder passes the renderer (RenderCommandEncoder.encodeTextWithSpans keeps at
/// most this many).
pub const max_spans = 128;

/// Exact ink of text command `it` drawn at window scale `scale`, window logical space
/// (x0, y0, x1, y1); null when unknown (see TextRenderer.probeInk). Mirrors the encoder's
/// `.text` dispatch on the main target.
pub fn probeItem(tr: *TextRenderer, fonts: *FontSelector, it: anytype, scale: f32) ?[4]f32 {
    const x = it.geom.x;
    const y = it.geom.y;
    if (it.text_content.len == 0 or it.text_font_size <= 0) return .{ x, y, x, y };
    const raster = wire_types.textRasterControls(it.text_raster_policy);
    const choice = chooseFonts(
        fonts,
        tr,
        it.text_content,
        it.text_font_size,
        it.text_font_weight,
        it.text_font_family,
        (it.text_font_flags & 4) != 0,
        (it.text_font_flags & 2) != 0,
        it.text_monospace_char_width,
        (it.text_font_flags & 1) != 0,
        raster.force_linear,
    );
    var span_buf: [max_spans]TextRenderer.ColorSpan = undefined;
    const spans: ?[]const TextRenderer.ColorSpan = if (it.text_spans) |s| blk: {
        const n = @min(s.len, span_buf.len);
        for (s[0..n], span_buf[0..n]) |src, *dst| dst.* = .{ .start = src.start, .end = src.end, .color = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };
        break :blk span_buf[0..n];
    } else null;
    // As the encoder: the animated raster draws the primary's glyphs from the
    // stable instance, whose bearings the ink must follow.
    tr.raster_font = if (choice.font == choice.primary) choice.raster else null;
    defer tr.raster_font = null;
    return tr.probeInk(
        it.text_content,
        x,
        y,
        choice.font,
        it.text_font_size,
        (it.text_font_flags & 1) != 0,
        choice.fallback,
        raster.force_linear,
        raster.shader_snap,
        choice.fixed_advance,
        spans,
        scale,
        (it.text_font_flags & 8) == 0,
    );
}

/// Per-renderer cache of text ink, relative to the draw origin.
pub const Cache = struct {
    const capacity = 4096;
    /// Origin phase resolution (fractions of a device pixel).
    const phase_steps: f32 = 256;

    const Entry = union(enum) {
        /// Ink relative to the origin (x0, y0, x1, y1).
        ink: [4]f32,
        /// Unknown when the atlas was in this state; probed again once it changed.
        unknown: u64,
    };

    map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    resource_key: u64 = 0,
    probes: u64 = 0,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = .{};
    }

    /// Fonts (and fallback stacks) the cached probes resolved: entries are valid only for one
    /// font configuration (AppRenderer.frameResourceKey).
    pub fn sync(self: *Cache, resource_key: u64) void {
        if (resource_key == self.resource_key) return;
        self.map.clearRetainingCapacity();
        self.resource_key = resource_key;
    }

    /// Window-space (x, y, w, h) containing every pixel text command `it` draws on the main
    /// target at `scale`; null when unknown (keep the conservative bound).
    ///
    /// Reused across origins with the same sub-device-pixel phase: placement snaps to device
    /// pixels, so moving by whole device pixels moves every quad by the same amount up to one
    /// device pixel of rounding at a snap boundary, and the result is padded by one device pixel
    /// for it. The pad applies whether or not the entry was cached, so the bound of an
    /// unchanged item is the same every frame.
    pub fn bounds(self: *Cache, allocator: std.mem.Allocator, tr: *TextRenderer, fonts: *FontSelector, it: anytype, scale: f32) ?[4]f32 {
        if (it.kind != .text or it.use_draw_transform or !(scale > 0)) return null;
        // Anything the generic bound pads for besides glyphs: keep it.
        if (it.stroke_width != 0 or it.shadow_blur != 0 or it.shadow2_blur != 0) return null;
        const x = it.geom.x;
        const y = it.geom.y;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
        const key = self.keyOf(it, scale);
        const atlas_state = (@as(u64, tr.atlas.gc_generation) << 32) | @as(u64, @truncate(tr.atlas.cache.count()));
        const rel: [4]f32 = if (self.map.get(key)) |entry| switch (entry) {
            .ink => |r| r,
            .unknown => |state| if (state == atlas_state) return null else self.probe(allocator, tr, fonts, it, scale, key, atlas_state) orelse return null,
        } else self.probe(allocator, tr, fonts, it, scale, key, atlas_state) orelse return null;
        if (rel[2] <= rel[0] or rel[3] <= rel[1]) return .{ x, y, 0, 0 };
        const pad = 1 / scale;
        return .{ x + rel[0] - pad, y + rel[1] - pad, rel[2] - rel[0] + 2 * pad, rel[3] - rel[1] + 2 * pad };
    }

    fn probe(self: *Cache, allocator: std.mem.Allocator, tr: *TextRenderer, fonts: *FontSelector, it: anytype, scale: f32, key: u64, atlas_state: u64) ?[4]f32 {
        self.probes += 1;
        if (self.map.count() >= capacity) self.map.clearRetainingCapacity();
        const ink = probeItem(tr, fonts, it, scale) orelse {
            self.map.put(allocator, key, .{ .unknown = atlas_state }) catch {};
            return null;
        };
        const x = it.geom.x;
        const y = it.geom.y;
        const rel: [4]f32 = .{ ink[0] - x, ink[1] - y, ink[2] - x, ink[3] - y };
        self.map.put(allocator, key, .{ .ink = rel }) catch {};
        return rel;
    }

    fn phase(v: f32, scale: f32) u16 {
        const d = v * scale;
        return @intFromFloat(@round((d - @floor(d)) * phase_steps));
    }

    fn keyOf(self: *const Cache, it: anytype, scale: f32) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0x74696e6b);
        h.update(it.text_content);
        const Params = extern struct {
            len: u64,
            size: f32,
            mono: f32,
            scale: f32,
            weight: u16,
            family: u16,
            phase_x: u16,
            phase_y: u16,
            flags: u8,
            policy: u8,
            spans: u8,
            pad: u8 = 0,
        };
        const p: Params = .{
            .len = it.text_content.len,
            .size = it.text_font_size,
            .mono = it.text_monospace_char_width,
            .scale = scale,
            .weight = it.text_font_weight,
            .family = it.text_font_family,
            .phase_x = phase(it.geom.x, scale),
            .phase_y = phase(it.geom.y, scale),
            .flags = it.text_font_flags,
            .policy = it.text_raster_policy,
            .spans = @intFromBool(it.text_spans != null),
        };
        h.update(std.mem.asBytes(&p));
        if (it.text_spans) |spans| for (spans[0..@min(spans.len, max_spans)]) |s| {
            h.update(std.mem.asBytes(&[2]u32{ s.start, s.end }));
        };
        return h.final();
    }
};
