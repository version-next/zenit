//! Text context, font/shaping/measure subsystem derived from `Cx`. Aggregated five fields
//! previously flat on `Cx`: `font_system` (host-injected font backend, null->fallback shaping),
//! `shaping_cache` (results + VisualLine cache), `measure_fn` (legacy no-context hook, per-process,
//! multi-window collision), `measure_ctx_fn` / `measure_ctx` (context-aware hook, multi-window
//! correct). Why: these five fields and methods form closed loop, hung on `Cx` means any
//! text-measure code needs full `Cx` first. Review D noted '`layoutChildren` depends
//! `Cx.visualLine` / `Cx.measureTextWidth`, can't unit-test without full `Cx`'—direct coupling
//! result. Post-extraction `TextContext` standalone-constructible (`init(allocator)` only, font
//! backend and measure hooks optional), measure fallback chain finally has real unit tests.
//!
//! **Measure priority** (`measureTextWidth`): 1. GlyphRun pipeline (with `font_system`), same
//! font/shaping as render, cursor/selection, only path without typographic drift. 2.
//! `measure_ctx_fn` + `measure_ctx`, multi-window-safe host hook. 3. `measure_fn`, legacy
//! per-process hook. 4. `text_layout.measureTextWidthByFontKind`, final estimate fallback.

const std = @import("std");
const text_module = @import("text");
const text_core_module = @import("text_core");
const i18n = @import("i18n");

const shaping_cache_mod = @import("shaping_cache.zig");
const text_layout = @import("text_layout.zig");
const text_shaper_adapter = @import("text_shaper_adapter.zig");
const text_shaping = @import("text_shaping.zig");
const layout_engine = @import("layout_engine.zig");

const FontSystem = text_module.FontSystem;
const FontDescriptor = text_module.FontDescriptor;
const TextShaper = text_module.TextShaper;
const ShapedGlyph = text_module.ShapedGlyph;
const FontMetrics = @import("glyph_run.zig").FontMetrics;
const GlyphRun = @import("glyph_run.zig").GlyphRun;

pub const ShapeTextOpts = text_shaping.ShapeTextOpts;

/// Release reference to fallback font in shape result (consistent with same-name helper in
/// core.zig).
fn releaseShapedFallbackFontRefs(glyphs: []const ShapedGlyph) void {
    for (glyphs) |glyph| {
        if (glyph.fallback_font_ref) |font_ref| {
            text_module.releaseFallbackFontRef(font_ref);
        }
    }
}

pub const TextContext = struct {
    allocator: std.mem.Allocator,

    /// Font measurement function injected externally (unified for both measuring and rendering
    /// text).
    measure_fn: ?text_layout.MeasureFn = null,
    /// Context-aware measurement callback (required for multi-window; context-free version can only
    /// read
    /// process-global state, causing cross-talk when two apps coexist). Takes precedence over
    /// measure_fn when set.
    measure_ctx_fn: ?text_layout.MeasureCtxFn = null,
    measure_ctx: ?*anyopaque = null,
    /// CoreText shape call cache.
    shaping_cache: shaping_cache_mod.ShapingCache,
    /// Font backend injected by host; shapeText returns error.NoFontProvider when null.
    font_system: ?*FontSystem = null,
    /// Per-window font resolver, shared with the window painter.
    font_resolve_fn: ?*const fn (*anyopaque, ShapeTextOpts) ?*text_module.Font = null,
    font_resolve_ctx: ?*anyopaque = null,
    /// Optional per-window explicit font-selection provider (Windows).
    /// Returns a snapshot allocated with the supplied allocator; TextContext
    /// releases and destroys it after the native call. Range sizes are logical
    /// pixels; uncovered spans use the primary font at opts.font_size.
    font_ranges_fn: ?*const fn (*anyopaque, ShapeTextOpts, *text_module.Font, std.mem.Allocator) anyerror!?*text_module.FontRanges = null,
    font_ranges_ctx: ?*anyopaque = null,
    /// Native runtime owns these legacy hooks and rebinds them at each Cx frame.
    manage_legacy_font_hooks: bool = false,
    legacy_font_resolve_fn: ?layout_engine.ShapeFontResolveFn = null,
    font_props_measure_fn: ?layout_engine.DrawnTextMeasureFn = null,

    pub fn init(allocator: std.mem.Allocator, cache_capacity: u32) TextContext {
        return .{
            .allocator = allocator,
            .shaping_cache = shaping_cache_mod.ShapingCache.init(allocator, cache_capacity),
        };
    }

    pub fn deinit(self: *TextContext) void {
        self.clearManagedFontHooks();
        self.shaping_cache.deinit();
    }

    /// Advance cache generation at frame start.
    pub fn beginFrame(self: *TextContext) void {
        self.shaping_cache.beginFrame();
    }

    /// Sync current measurement hook into text_layout's process-level slot (required by legacy
    /// layout path).
    pub fn syncLegacyMeasureHooks(self: *TextContext) void {
        text_layout.setMeasureFn(self.measure_fn);
        text_layout.setMeasureCtxFn(self.measure_ctx_fn, self.measure_ctx);
        if (self.manage_legacy_font_hooks) {
            layout_engine.setContextFontHooks(self, self.legacy_font_resolve_fn, self.font_props_measure_fn, self.font_resolve_ctx);
            if (self.font_ranges_fn != null) layout_engine.setContextLineMetrics(self, selectedLineMetrics, self);
        }
    }

    fn selectedLineMetrics(ctx: *anyopaque, props: *const @import("types.zig").TextProps) ?layout_engine.TextLineMetrics {
        const self: *TextContext = @ptrCast(@alignCast(ctx));
        if (self.font_ranges_fn == null) return null;
        const line = self.visualLine(.{
            .text = props.content,
            .font_family = "system",
            .font_size = props.font_size,
            .font_weight = props.font_weight,
            .use_italic = props.use_italic_font,
            .font_family_id = props.font_family,
            .use_monospace = props.use_monospace_font,
            .use_symbols = props.use_symbols_font,
        }) catch return null;
        return .{ .ascent = line.ascent, .descent = line.descent };
    }

    /// Mount FontSystem to enable cx.shapeText to find Font and invoke TextShaper.
    /// Called by zenit_app after init (same sequence as setSystemSdk).
    pub fn setFontSystem(self: *TextContext, fs: *FontSystem) void {
        self.font_system = fs;
    }

    pub fn clearManagedFontHooks(self: *TextContext) void {
        if (self.manage_legacy_font_hooks) layout_engine.clearContextFontHooks(self);
    }

    pub fn resetShapingCache(self: *TextContext) void {
        const capacity = self.shaping_cache.capacity;
        self.shaping_cache.deinit();
        self.shaping_cache = shaping_cache_mod.ShapingCache.init(self.allocator, capacity);
    }

    pub fn setFontRangesProvider(self: *TextContext, ctx: ?*anyopaque, provider: @TypeOf(@as(TextContext, undefined).font_ranges_fn)) void {
        self.font_ranges_ctx = ctx;
        self.font_ranges_fn = provider;
        // Rebind after changing the provider's selection rules or fonts too.
        self.resetShapingCache();
    }

    fn resolveFontRanges(self: *TextContext, opts: ShapeTextOpts, font: *text_module.Font) !?*text_module.FontRanges {
        const provider = self.font_ranges_fn orelse return null;
        const ctx = self.font_ranges_ctx orelse return error.MissingFontRangesContext;
        if (!@hasDecl(TextShaper, "shapeWithRanges")) return error.UnsupportedFontRanges;
        return provider(ctx, opts, font, self.allocator);
    }

    fn rangeBaseFont(font: *text_module.Font, size: f32, ranges: ?*text_module.FontRanges) !?*text_module.Font {
        if (@hasDecl(text_module.Font, "lineCaretStopsWithRanges")) {
            // DirectWrite lays out selected ranges at their requested sizes.
            // Resize the primary too, instead of scaling the entire mixed run.
            if (ranges != null and font.pixelSize() != size) return try font.derive(size);
        }
        return null;
    }

    fn releaseFontRanges(self: *TextContext, ranges: ?*text_module.FontRanges) void {
        if (@hasDecl(text_module.FontRanges, "deinit")) {
            if (ranges) |snapshot| {
                snapshot.deinit();
                self.allocator.destroy(snapshot);
            }
        }
    }

    fn resolveDefaultFont(self: *TextContext, opts: ShapeTextOpts) ?*text_module.Font {
        if (self.font_resolve_fn) |resolve| {
            if (self.font_resolve_ctx) |ctx| return resolve(ctx, opts);
        }
        // A managed native context without a selector must not borrow another window's active hooks.
        if (self.manage_legacy_font_hooks) return null;
        return layout_engine.resolveTextFont(opts.text, opts.font_size, opts.font_weight, opts.use_italic, opts.use_monospace, opts.font_family_id);
    }

    pub fn clearFontSystem(self: *TextContext) void {
        self.font_system = null;
    }

    /// GlyphRun pipeline entry point (replaces text_layout's old measure API).
    ///
    /// Internally: 1) build ShapingKey; 2) ShapingCache lookup; 3) on miss, TextShaper.shape()
    /// yields
    /// []ShapedGlyph, converted via text_shaper_adapter.fromShapedGlyphs into a GlyphRun stored in
    /// the
    /// ShapingCache arena; 4) hit and miss both return a GlyphRun.
    ///
    /// ShapingCache.insert copies GlyphRun.glyphs/clusters into its internal arena, so callers need
    /// not worry about slice lifetime. The returned GlyphRun is valid until the threshold frames
    /// (default 2) after the next beginFrame.
    ///
    /// Errors:
    ///   - error.NoFontProvider: cx.font_system == null
    ///   - error.FontLookupFailed / TextShapingFailed / OutOfMemory: passthrough
    pub fn shapeText(self: *TextContext, opts: ShapeTextOpts) !GlyphRun {
        const fs = self.font_system orelse return error.NoFontProvider;
        if (opts.text.len == 0) {
            return GlyphRun{
                .glyphs = &.{},
                .clusters = &.{},
                .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = opts.font_size },
                .direction = .ltr,
                .total_advance = 0,
            };
        }

        // ShapingKey's current schema does not distinguish weight/italic (v0.5 design limitation).
        // Use
        // text_hash to embed weight + italic info to avoid different styles hitting same entry.
        // font_id
        // currently all 0 (FontSystem's internal *Font handle does not yet expose id).
        const key = text_shaping.shapingKey(opts);
        if (self.shaping_cache.lookup(key)) |run| return run;

        // miss: find Font -> shape -> adapt -> cache.insert
        const desc = FontDescriptor{
            .family = opts.font_family,
            .size = opts.font_size,
            .weight = text_shaping.mapFontWeight(opts.font_weight),
            .style = if (opts.use_italic) .italic else .normal,
        };
        const borrowed = if (opts.font_family_id != 0 or std.mem.eql(u8, opts.font_family, "system"))
            self.resolveDefaultFont(opts)
        else
            null;
        const font = borrowed orelse try fs.findFont(desc);
        defer if (borrowed == null) font.deinit();

        var shaper = try TextShaper.init(self.allocator);
        defer shaper.deinit();
        const ranges = try self.resolveFontRanges(opts, font);
        defer self.releaseFontRanges(ranges);
        const ranged_base = try rangeBaseFont(font, opts.font_size, ranges);
        defer if (ranged_base) |owned| owned.deinit();
        const native_font = ranged_base orelse font;
        const shaped = if (@hasDecl(TextShaper, "shapeWithRanges"))
            try shaper.shapeWithRanges(opts.text, native_font, opts.use_italic, ranges)
        else
            try shaper.shapeWithOptions(opts.text, font, opts.use_italic);
        defer self.allocator.free(shaped);
        defer releaseShapedFallbackFontRefs(shaped);

        // FontMetrics: Font does not yet expose ascent/descent; placeholder 0 for now (caller
        // mainly
        // cares about total_advance). Add Font.metrics() after Phase B/C switch.
        const metrics = FontMetrics{
            .ascent = 0,
            .descent = 0,
            .line_gap = 0,
            .font_size = opts.font_size,
        };
        var run = try text_shaper_adapter.fromShapedGlyphs(self.allocator, shaped, metrics, .ltr);
        const scale = if (ranges != null) 1 else if (font.pixelSize() > 0) opts.font_size / font.pixelSize() else 1;
        for (@constCast(run.glyphs)) |*glyph| {
            glyph.x_advance *= scale;
            glyph.y_advance *= scale;
            glyph.x_offset *= scale;
            glyph.y_offset *= scale;
        }
        run.total_advance *= scale;
        // glyphs/clusters allocated by adapter are copied and managed by cache's entry owner after
        // cache.insert;
        // original slice freed.
        defer self.allocator.free(run.glyphs);
        defer self.allocator.free(run.clusters);

        try self.shaping_cache.insert(key, run.glyphs, run.clusters, run.metrics, run.direction, run.total_advance);
        // cache.insert copies slices into entry ownership, then lookup again to get cache's copy. (Avoid
        // returning
        // caller-allocator slice already freed.)
        return self.shaping_cache.lookup(key) orelse unreachable;
    }

    /// Build a CoreText-authoritative single visual line. Grapheme boundaries
    /// come from text_core; glyph/bidi caret x positions come from the same
    /// platform line object used for shaping and measurement.
    pub fn shapeVisualLine(self: *TextContext, opts: ShapeTextOpts) !text_core_module.OwnedVisualLine {
        const fs = self.font_system orelse return error.NoFontProvider;
        const desc = FontDescriptor{
            .family = opts.font_family,
            .size = opts.font_size,
            .weight = text_shaping.mapFontWeight(opts.font_weight),
            .style = if (opts.use_italic) .italic else .normal,
        };
        const borrowed = if (opts.font_family_id != 0 or std.mem.eql(u8, opts.font_family, "system"))
            self.resolveDefaultFont(opts)
        else
            null;
        const font = borrowed orelse try fs.findFont(desc);
        defer if (borrowed == null) font.deinit();
        const ranges = try self.resolveFontRanges(opts, font);
        defer self.releaseFontRanges(ranges);
        const ranged_base = try rangeBaseFont(font, opts.font_size, ranges);
        defer if (ranged_base) |owned| owned.deinit();
        const native_font = ranged_base orelse font;
        const scale = if (ranges != null) 1 else if (font.pixelSize() > 0) opts.font_size / font.pixelSize() else 1;

        var boundary_count: usize = 1;
        var byte: usize = 0;
        var count_cursor = text_core_module.grapheme.BoundaryCursor.init(opts.text);
        while (byte < opts.text.len) : (boundary_count += 1) {
            byte = count_cursor.next(byte);
        }
        const boundaries = try self.allocator.alloc(u32, boundary_count);
        defer self.allocator.free(boundaries);
        boundaries[0] = 0;
        byte = 0;
        var boundary_index: usize = 1;
        var fill_cursor = text_core_module.grapheme.BoundaryCursor.init(opts.text);
        while (byte < opts.text.len) : (boundary_index += 1) {
            byte = fill_cursor.next(byte);
            boundaries[boundary_index] = @intCast(byte);
        }

        const native_stops = try self.allocator.alloc(text_module.LineCaretStop, boundary_count);
        defer self.allocator.free(native_stops);
        const metrics = if (@hasDecl(text_module.Font, "lineCaretStopsWithRanges"))
            try native_font.lineCaretStopsWithRanges(opts.text, boundaries, native_stops, ranges)
        else
            try font.lineCaretStops(opts.text, boundaries, native_stops);
        var stop_count: usize = boundary_count;
        for (native_stops) |stop| if (stop.has_secondary) {
            stop_count += 1;
        };
        const stops = try self.allocator.alloc(text_core_module.text_coordinates.CaretStop, stop_count);
        errdefer self.allocator.free(stops);
        var write: usize = 0;
        // CoreText owns glyph and caret geometry, while paragraph direction is
        // a Unicode text property.  The first CTRun is not authoritative here:
        // leading isolates/controls can make its run direction differ from P2/P3.
        const base_direction: text_core_module.text_coordinates.Direction = switch (i18n.detectParagraphDirection(opts.text)) {
            .ltr => .ltr,
            .rtl => .rtl,
        };
        for (native_stops) |stop| {
            stops[write] = .{
                .position = .{ .byte = .{ .value = stop.byte_offset }, .affinity = .downstream },
                .x = .{ .value = stop.primary_x * scale },
                .strong_direction = base_direction,
            };
            write += 1;
            if (stop.has_secondary) {
                stops[write] = .{
                    .position = .{ .byte = .{ .value = stop.byte_offset }, .affinity = .upstream },
                    .x = .{ .value = stop.secondary_x * scale },
                    .strong_direction = base_direction,
                };
                write += 1;
            }
        }
        std.mem.sort(text_core_module.text_coordinates.CaretStop, stops, {}, struct {
            fn lessThan(_: void, a: text_core_module.text_coordinates.CaretStop, b: text_core_module.text_coordinates.CaretStop) bool {
                if (a.x.value != b.x.value) return a.x.value < b.x.value;
                if (a.position.byte.value != b.position.byte.value) return a.position.byte.value < b.position.byte.value;
                return a.position.affinity == .upstream and b.position.affinity == .downstream;
            }
        }.lessThan);

        // Derive the strong direction from visual-neighbour logical order. At a
        // duplicate bidi caret, fall back to the paragraph base direction.
        for (stops, 0..) |*stop, i| {
            var direction = base_direction;
            var next = i + 1;
            while (next < stops.len and stops[next].position.byte.value == stop.position.byte.value) : (next += 1) {}
            if (next < stops.len) {
                direction = if (stops[next].position.byte.value < stop.position.byte.value) .rtl else .ltr;
            } else if (i > 0) {
                var previous = i;
                while (previous > 0) {
                    previous -= 1;
                    if (stops[previous].position.byte.value != stop.position.byte.value) {
                        direction = if (stop.position.byte.value < stops[previous].position.byte.value) .rtl else .ltr;
                        break;
                    }
                }
            }
            stop.strong_direction = direction;
        }

        const line = text_core_module.VisualLine{
            .source_start = .{ .value = 0 },
            .source_end = .{ .value = opts.text.len },
            .caret_stops = stops,
            .width = metrics.width * scale,
            .ascent = metrics.ascent * scale,
            .descent = metrics.descent * scale,
            .leading = metrics.leading * scale,
            .base_direction = base_direction,
        };
        try line.validate(opts.text);
        return .{ .allocator = self.allocator, .value = line };
    }

    /// Cached production entry point for consumers that only need a borrowed
    /// immutable line during the current context lifetime.
    pub fn visualLine(self: *TextContext, opts: ShapeTextOpts) !text_core_module.VisualLine {
        const key = text_shaping.shapingKey(opts);
        if (self.shaping_cache.lookupVisual(key)) |line| return line;
        var owned = try self.shapeVisualLine(opts);
        defer owned.deinit();
        try self.shaping_cache.insertVisual(key, owned.value);
        return self.shaping_cache.lookupVisual(key) orelse unreachable;
    }

    /// Measure text through this context's font selector. Unlike the legacy
    /// `measure_fn` field, this preserves the owning window's font context when
    /// several Cx instances coexist in one process.
    pub fn measureTextWidth(self: *TextContext, content: []const u8, font_size: f32, font_weight: u16, italic: bool) f32 {
        if (content.len == 0) return 0;
        // Callers may slice mid-multibyte sequence (half a CJK/emoji) when cutting a prefix by
        // byte. Invalid
        // UTF-8 fails CoreText NSString construction: the shape layer reports TextShapingFailed and
        // the
        // FontSelector bridge (coretext_measure_text_width_with_font) silently returns 0.0f,
        // collapsing the
        // bbox to 0.00. Trim to the longest valid prefix, matching what render displays; valid
        // input
        // passes through unchanged at zero cost.
        const safe = text_shaping.validUtf8Prefix(content);
        if (safe.len == 0) return 0;
        // Prefer the GlyphRun pipeline: one font and shaping for both rendering (visualLine in
        // text_item_render) and input cursor/selection (shapeText in input/text_utils). The old
        // FontSelector
        // bridge used fallback_families' preferred font (Helvetica Neue), whose Latin width is
        // ~1.5% wider
        // than 'system', causing WrapMap line-break drift and bbox width mismatch. Falls back to
        // the old
        // path when the pipeline is unavailable (no font_system / shape failure).
        if (self.font_system != null) {
            if (self.shapeText(.{
                .text = safe,
                .font_family = "system",
                .font_size = font_size,
                .font_weight = font_weight,
                .use_italic = italic,
            })) |run| {
                return run.total_advance;
            } else |_| {}
        }
        if (self.measure_ctx_fn) |measure| {
            if (self.measure_ctx) |ctx| {
                return measure(ctx, safe.ptr, safe.len, font_size, font_weight, italic);
            }
        }
        if (self.measure_fn) |measure| {
            return measure(safe.ptr, safe.len, font_size, font_weight, italic);
        }
        return text_layout.measureTextWidthByFontKind(safe, font_size, font_weight, italic, false);
    }

    // Intentionally NOT providing measureTextWidthCallback (pointer-erasing callback adapter).
    //
    // WrapMap-like APIs take `*anyopaque` + function pointer, which must be paired. All callers
    // pass
    // `cx` (see input/textarea.zig and input/editable_text.zig), so the adapter stays on `Cx`, cast
    // to `*Cx`.
    //
    // A same-named function casting to `*TextContext` would have an identical signature, so a
    // mispair
    // would not fail to compile. `text` is not at offset 0 in Cx; casting `*Cx` as `*TextContext`
    // dereferences the wrong field and silently yields garbage widths. Better not to provide it.
    /// Guard for external (non-layout-pass) shaping measurement, ensuring use of this context's
    /// cache
    /// and font backend.
    pub fn beginExternalTextMeasure(self: *TextContext) layout_engine.ExternalShapeMeasureGuard {
        return layout_engine.beginExternalShapeMeasure(&self.shaping_cache, self.font_system);
    }
};

// -- Tests
//
// The measureTextWidth fallback chain is testable here because TextContext can be constructed
// independently, without building a complete Cx (node tree, focus, dispatcher...).

const TestHooks = struct {
    var ctx_calls: u32 = 0;
    var plain_calls: u32 = 0;
    var marker: u8 = 0;

    fn reset() void {
        ctx_calls = 0;
        plain_calls = 0;
    }

    fn withCtx(_: *anyopaque, _: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
        ctx_calls += 1;
        return @as(f32, @floatFromInt(len)) * 7;
    }

    fn plain(_: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
        plain_calls += 1;
        return @as(f32, @floatFromInt(len)) * 3;
    }
};

test "TextContext selected baseline uses cached line and clears with provider or owner" {
    const Bridge = struct {
        fn ranges(_: *anyopaque, _: ShapeTextOpts, _: *text_module.Font, _: std.mem.Allocator) anyerror!?*text_module.FontRanges {
            return error.OutOfMemory;
        }
    };
    var tc = TextContext.init(std.testing.allocator, 4);
    defer tc.deinit();
    tc.manage_legacy_font_hooks = true;
    tc.setFontRangesProvider(&tc, Bridge.ranges);
    const props = @import("types.zig").TextProps{ .content = "A", .font_size = 20, .line_height = 1 };
    const opts = ShapeTextOpts{ .text = "A", .font_family = "system", .font_size = 20 };
    const stops = [_]text_core_module.text_coordinates.CaretStop{
        .{ .position = .{ .byte = .{ .value = 0 }, .affinity = .downstream }, .x = .{ .value = 0 }, .strong_direction = .ltr },
        .{ .position = .{ .byte = .{ .value = 1 }, .affinity = .downstream }, .x = .{ .value = 10 }, .strong_direction = .ltr },
    };
    try tc.shaping_cache.insertVisual(text_shaping.shapingKey(opts), .{
        .source_start = .{ .value = 0 },
        .source_end = .{ .value = 1 },
        .caret_stops = &stops,
        .width = 10,
        .ascent = 18,
        .descent = 4,
    });
    tc.syncLegacyMeasureHooks();
    try std.testing.expectEqual(@as(f32, 17), layout_engine.firstTextBaseline(&props));
    // Provider clear invalidates its metrics immediately, before the next frame.
    tc.setFontRangesProvider(null, null);
    try std.testing.expectEqual(@as(f32, 15), layout_engine.firstTextBaseline(&props));
    tc.setFontRangesProvider(&tc, Bridge.ranges);
    tc.syncLegacyMeasureHooks();
    // A partial context has no font backend: unavailable shaping falls back.
    try std.testing.expectEqual(@as(f32, 15), layout_engine.firstTextBaseline(&props));
    tc.clearManagedFontHooks();
    try std.testing.expectEqual(@as(f32, 15), layout_engine.firstTextBaseline(&props));
}

test "TextContext: 空文本宽度为 0，不碰任何钩子" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    try std.testing.expectEqual(@as(f32, 0), tc.measureTextWidth("", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 0), TestHooks.plain_calls);
}

test "TextContext: 无字体后端时落到 measure_fn" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    try std.testing.expectEqual(@as(f32, 12), tc.measureTextWidth("abcd", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 1), TestHooks.plain_calls);
}

test "TextContext: 带 context 的钩子优先于 legacy 钩子（多窗口正确性）" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;
    tc.measure_ctx_fn = TestHooks.withCtx;
    tc.measure_ctx = @ptrCast(&TestHooks.marker);

    // 7/char = ctx version; 3/char = legacy version
    try std.testing.expectEqual(@as(f32, 28), tc.measureTextWidth("abcd", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 1), TestHooks.ctx_calls);
    try std.testing.expectEqual(@as(u32, 0), TestHooks.plain_calls);
}

test "TextContext: 设了 measure_ctx_fn 但没给 ctx 时不当作可用" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;
    tc.measure_ctx_fn = TestHooks.withCtx;
    tc.measure_ctx = null; // partially configured state

    try std.testing.expectEqual(@as(f32, 12), tc.measureTextWidth("abcd", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 0), TestHooks.ctx_calls);
    try std.testing.expectEqual(@as(u32, 1), TestHooks.plain_calls);
}

test "TextContext: 非法 UTF-8 前缀先裁再测（不把半个字符喂给钩子）" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    // 'a' + half of 'zhong' -> should measure only 1 byte of 'a'
    try std.testing.expectEqual(@as(f32, 3), tc.measureTextWidth("a\xE4\xB8", 14, 400, false));
}

test "TextContext: 完全非法的输入量出 0 而不是喂给钩子" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    try std.testing.expectEqual(@as(f32, 0), tc.measureTextWidth("\xFF\xFE", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 0), TestHooks.plain_calls);
}

test "TextContext: 没有字体后端时 shapeText 明确报错" {
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    try std.testing.expectError(
        error.NoFontProvider,
        tc.shapeText(.{ .text = "hi", .font_family = "system", .font_size = 14 }),
    );
}

test "TextContext: host face and logical size govern mixed input caret and glyph widths" {
    var fs = try FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica Neue", .size = 26 });
    defer font.deinit();
    const Bridge = struct {
        fn resolve(raw: *anyopaque, _: []const u8, _: f32, _: u16, _: bool, _: bool, _: u16) ?*text_module.Font {
            return @ptrCast(@alignCast(raw));
        }
    };
    layout_engine.setShapeFontResolver(&Bridge.resolve, @ptrCast(font));
    defer layout_engine.setShapeFontResolver(null, null);
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.setFontSystem(&fs);
    const content = "asfdsfsdadfa工asdf工 中文 English";
    const opts = ShapeTextOpts{ .text = content, .font_family = "system", .font_size = 13 };
    const line = try tc.visualLine(opts);
    const run = try tc.shapeText(opts);
    const expected = font.measureWidth(content) * 13 / font.pixelSize();
    try std.testing.expectApproxEqAbs(expected, line.width, 0.01);
    try std.testing.expectApproxEqAbs(expected, run.total_advance, 0.01);
    const caret = try line.positionToCaret(.{ .byte = .{ .value = content.len }, .affinity = .downstream });
    try std.testing.expectApproxEqAbs(expected, caret.x.value, 0.01);
}

test "TextContext: 无字体后端时连空文本也报错（取后端在长度短路之前）" {
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    // Pin current evaluation order: font_system check before text.len == 0 short-circuit. Swapping
    // changes behavior for hostless backends; lock as contract here.
    try std.testing.expectError(
        error.NoFontProvider,
        tc.shapeText(.{ .text = "", .font_family = "system", .font_size = 14 }),
    );
}
