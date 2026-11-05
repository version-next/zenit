//! command_encoder/font_selector.zig: font weight tier select + lazy derived font cache.
//!
//! FontSelector has zero coupling to RenderCommandEncoder. External access via the
//! `render.FontSelector` re-export.
//!
//! Duty: select the closest pre-loaded font tier by font_size + font_weight (regular / bold,
//! up to 12 tiers each), lazy-derive missing sizes + cache. Also a small LRU (8 slots) for
//! monospace ASCII advance, avoiding repeated per-char measurement.

const std = @import("std");
const text_module = @import("text");
const Font = text_module.Font;
const script_detect = @import("script_detect.zig");

/// Complete font decision for a text segment.
///
/// Rendering is (primary font + content-dependent CJK/Hangul fallback), but measurement used
/// to recognize only the primary. Bundling both into one struct makes "measurement can't
/// access fallback" impossible at the type level.
/// The renderer's answer to "how wide is this text going to be" (see FontSelector.drawn_width_fn).
/// null = can't answer this time (shaping failed); caller falls back to CoreText.
pub const DrawnWidthFn = *const fn (ctx: *anyopaque, text: []const u8, font: *Font, props: TextFontProps) ?f32;

/// Get face by family_id + font_size/weight/italic. null = family can't be resolved; use default.
/// Returned `*Font` is owned by registry; selector borrows without freeing.
pub const FamilyResolveFn = *const fn (ctx: *anyopaque, family: u16, size: f32, weight: u16, italic: bool) ?*Font;

/// Reserved TextProps.font_family id: the platform UI font (see FontSelector.system_ui_loader).
pub const system_ui_family: u16 = 0xFFFF;

pub const ResolvedFonts = struct {
    /// Primary font (after symbols override / italic / mono / regular decision)
    primary: *Font,
    /// Content-dependent fallback: rendering switches to it for Han/kana/Hangul in text.
    /// null = this text doesn't need fallback.
    fallback: ?*Font = null,
    /// `fallback` is script-based fallback (CJK / Hangul) selected **by content**.
    /// false means it's upright fallback for missing glyphs in italic face, not the whole segment's
    /// font.
    fallback_is_script: bool = false,
    /// Animated raster (`force_linear`) only: the preloaded instance the primary font's glyphs
    /// rasterize from, scaled to the requested size, when it is not `primary` itself. Never used
    /// for shaping: `primary` lays the run out under every raster policy (see resolveFonts).
    raster: ?*Font = null,

    /// The font to use for shaping / measuring the whole run; it must be exactly the one the render
    /// side's encodeText hands to the shaper.
    ///
    /// Script fallback (CJK/Korean): the whole run is measured with the fallback font, matching
    /// rendering (e.g. "asdfasdf<CJK>dfasdfsdfdsf" is otherwise off by 2.38px).
    /// The upright fallback for italic must **not** be used as the whole-run font: it only fills
    /// glyphs missing from the italic face, and measuring with it narrows every italic run to
    /// upright width, so italic text gets clipped by `.fit` containers.
    pub fn shapingFont(self: ResolvedFonts) *Font {
        if (self.fallback_is_script) {
            if (self.fallback) |f| return f;
        }
        return self.primary;
    }
};

/// **Complete** input for deciding what font a text uses.
///
/// `content` is mandatory, not an optimization: render-side CJK/Hangul fallback is **by
/// content** (selectCjkFallbackFont scans for Han/kana/Hangul). A measurement function taking
/// only (size, weight, italic, mono) can never match a renderer that also reads bytes; this
/// is the structural root cause of "measure and render widths differ".
pub const TextFontProps = struct {
    /// Per-window override; avoids mutating a selector shared by two windows.
    stack_mode_override: ?bool = null,

    font_size: f32,
    font_weight: u16 = 400,
    /// Font family id (render.FontRegistry). 0 = use this selector's default family slot.
    /// When non-zero, encoder first asks registry for face; if absent, falls back to slot logic.
    font_family: u16 = 0,
    use_italic: bool = false,
    use_monospace: bool = false,
    /// Fixed ASCII cell advance used by terminal/code-grid drawing. Zero means
    /// normal glyph advances. It is part of measurement identity even though
    /// it does not affect font selection.
    monospace_char_width: f32 = 0,
    /// Renderer can switch whole segment to symbols_font (Menlo, for arrows/tabs etc).
    use_symbols: bool = false,
    /// Animated raster: glyphs rasterize from a *Stable preloaded instance (`ResolvedFonts.raster`),
    /// so a size walking through an animated scale does not derive a font per frame. It never
    /// changes the shaping fonts: layout is identical under every raster policy.
    force_linear: bool = false,
};

const MonoAsciiAdvanceSlot = struct {
    font_ptr: ?*const Font = null,
    font_size: f32 = 0,
    font_weight: u16 = 0,
    use_italic: bool = false,
    advance: f32 = 0,
    last_used: u32 = 0,
};
var mono_ascii_advance_lru_tick: u32 = 0;

/// Font selector: picks closest font for font_size + font_weight.
/// Two groups: regular (weight < 600) and bold (weight >= 600).
/// Each: up to 12 preloaded buckets + lazy derived font cache (exact match any size).
pub const FontSelector = struct {
    const exact_size_epsilon: f32 = 0.01;
    pub const weight_miss_capacity = 16;

    small: *Font, // Backward compatibility: minimum bucket (regular)
    medium: *Font, // Backward compatibility: medium bucket (regular)
    large: *Font, // Backward compatibility: largest bucket (regular)
    /// Extended font slots (optional; for finer size/weight matching)
    extra_fonts: [24]?*Font = @splat(null),
    extra_count: u8 = 0,
    /// Bold font slots (weight >= 650)
    bold_fonts: [16]?*Font = @splat(null),
    bold_count: u8 = 0,
    /// Symbols font (for rendering list markers and special Unicode symbols)
    symbols_font: ?*Font = null,
    /// Monospace Regular font slot
    mono_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_count: u8 = 0,
    /// Monospace Bold font slot
    mono_bold_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_bold_count: u8 = 0,
    /// Monospace Italic font slot
    mono_italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_italic_count: u8 = 0,
    /// Monospace Bold Italic font slot
    mono_bold_italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_bold_italic_count: u8 = 0,
    /// Italic font slot
    italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    italic_count: u8 = 0,
    /// Bold Italic font slot
    bold_italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    bold_italic_count: u8 = 0,
    /// CJK fallback font group
    cjk_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    cjk_count: u8 = 0,
    /// CJK Bold fallback font group
    cjk_bold_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    cjk_bold_count: u8 = 0,
    /// Hangul fallback font group
    korean_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    korean_count: u8 = 0,
    /// Hangul Bold fallback font group
    korean_bold_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    korean_bold_count: u8 = 0,

    /// Lazy derived font cache, on-demand for exact size.
    /// Key: hash(src_font_ptr, group_idx, size_hundredths)
    derived_cache: std.AutoHashMap(u64, *Font) = undefined,
    derived_cache_inited: bool = false,
    /// Load fonts by weight (app injected: same family + target weight). Without injection,
    /// regular group can only derive sizes, not real weights; 600/700 silently fall back to
    /// regular (storybook measured: all bold titles are regular). Results go in derived_cache,
    /// lifetime managed with it.
    weight_loader: ?WeightLoader = null,
    /// Negative cache for weight_loader: records "this (weight, size) key doesn't exist in family".
    /// Without it, missing weights query CoreText on every measure (every frame, every call), plus
    /// a native NSLog each time. Ring buffer (when full, wraps oldest; evicted keys are queried
    /// once more); same lifetime as derived_cache (cleared on init/deinit), bound to loader
    /// identity: changing the loader (family) invalidates the whole table.
    weight_misses: [weight_miss_capacity]u64 = undefined,
    weight_miss_len: u8 = 0,
    weight_miss_next: u8 = 0,
    weight_miss_loader: ?WeightLoader = null,
    /// Allocator for derived_cache and Font allocation
    allocator: ?std.mem.Allocator = null,

    /// Monospace ASCII advance cache: (font, size, weight, italic) -> character width.
    /// CoreText measurement is a hot path for monospace (typical code hits 600+ FFI calls per
    /// frame). Code usually uses one monospace font + few size/weight combos, so an 8-slot LRU
    /// gets ~100% hits. On hit, ASCII-only strings use len * advance, bypassing CoreText.
    ascii_advance_cache: [8]MonoAsciiAdvanceSlot = @as([8]MonoAsciiAdvanceSlot, @splat(.{})),

    /// Authority on "how wide is this text going to be", wired in by
    /// RenderCommandEncoder.setFonts, pointing to that renderer's
    /// TextRenderer.measureTextWidthAsDrawn.
    /// Unwired (bare FontSelector / unit tests) falls back to CoreText full-string typographic
    /// width—that's fallback only (see measureTextWidthWithProps comment).
    drawn_width_fn: ?DrawnWidthFn = null,
    drawn_width_ctx: ?*anyopaque = null,

    /// Font family resolver hook (render.FontRegistry). When `props.font_family != 0`, text asks
    /// it for the face first; on miss, falls back to the slot logic below.
    ///
    /// Warning: must live on **FontSelector**, not in encodeText. resolveFonts is the **shared**
    /// entry point for measure and render; patching at call sites makes measure and render pick
    /// different fonts.
    family_resolve_fn: ?FamilyResolveFn = null,
    family_resolve_ctx: ?*anyopaque = null,

    /// The platform's UI font (`font_family = system_ui_family`: SF Pro on macOS, with its
    /// size-dependent optical size and tracking), loaded per (size, weight) by the app. Unwired
    /// (bare selector, other platforms) the default family serves it. Results go in
    /// derived_cache.
    system_ui_loader: ?WeightLoader = null,
    system_ui_unavailable: bool = false,

    /// Explicit font fallback stack mode. App wires FontFallbackStack to TextRenderer
    /// (setFallbackStack) and sets this true. Content-dependent script fallback (CJK/Hangul) then
    /// comes from the renderer **per-codepoint** (TextRenderer.selectSegmentFont, used by both
    /// draw and measureTextWidthAsDrawn), not from this selector **per-segment**. So
    /// resolveFonts.fallback is always null (script case) and shapingFont() is always primary:
    /// measure and render both follow "primary + explicit per-segment stack selection".
    /// Upright italic fallback stays independent.
    /// Warning: the two switches must pair: stack_mode without wiring = CJK cascades with the
    /// fallback deleted; stack wired without stack_mode = measure still whole-segment, so measure
    /// and render mismatch.
    stack_mode: bool = false,

    /// Look up/compute single-char ASCII advance (monospace font + ASCII string only).
    /// Returns 0 = that font/size/weight can't be cached (rare path).
    inline fn lookupOrInsertAsciiAdvance(
        self: *FontSelector,
        font: *Font,
        font_size: f32,
        font_weight: u16,
        use_italic: bool,
    ) f32 {
        mono_ascii_advance_lru_tick +%= 1;
        const tick = mono_ascii_advance_lru_tick;
        var lru_idx: usize = 0;
        var lru_tick: u32 = std.math.maxInt(u32);
        for (&self.ascii_advance_cache, 0..) |*slot, i| {
            if (slot.font_ptr == font and
                slot.font_size == font_size and
                slot.font_weight == font_weight and
                slot.use_italic == use_italic)
            {
                slot.last_used = tick;
                return slot.advance;
            }
            if (slot.last_used <= lru_tick) {
                lru_tick = slot.last_used;
                lru_idx = i;
            }
        }
        // Cache miss: measure "M" width once, self-check font is strictly monospace.
        const text_scale = font_size / font.pixelSize();
        const m_width = font.measureWidth("M") * text_scale;
        if (m_width <= 0) return 0;
        // Self-check: measure "MMiM " (5 chars). True monospace must equal 5 * m_width.
        // If font is misconfigured (e.g., fallback to proportional), i / space advance deviates.
        // We return 0 to let caller use full CoreText. Choice covers cap / lowercase / space—
        // the three most easily-undersized glyphs; true monospace shouldn't let them deviate.
        const probe_width = font.measureWidth("MMiM ") * text_scale;
        const expected = m_width * 5.0;
        const epsilon: f32 = 0.5; // 0.5px tolerance to avoid subpixel rounding false alarm
        if (@abs(probe_width - expected) > epsilon) {
            // Font isn't strictly monospace; don't cache; let caller use CoreText each time
            return 0;
        }
        self.ascii_advance_cache[lru_idx] = .{
            .font_ptr = font,
            .font_size = font_size,
            .font_weight = font_weight,
            .use_italic = use_italic,
            .advance = m_width,
            .last_used = tick,
        };
        return m_width;
    }

    inline fn isAllAscii(text: []const u8) bool {
        for (text) |b| {
            if (b >= 0x80) return false;
        }
        return true;
    }

    /// Initialize lazy cache (call after setFonts)
    pub fn initDerivedCache(self: *FontSelector, allocator: std.mem.Allocator) void {
        if (self.derived_cache_inited) return;
        self.allocator = allocator;
        self.derived_cache = std.AutoHashMap(u64, *Font).init(allocator);
        self.derived_cache_inited = true;
        self.clearWeightMisses();
        self.system_ui_unavailable = false;
    }

    /// HiDPI: propagate the new backing scale to all already-derived fonts in the cache.
    ///
    /// `Font.derive` copies `scale_factor` only at **creation time**, and derived fonts are
    /// cached and reused. After moving a window to a screen with a different DPI, updating the
    /// three base fonts in `app.fonts` is not enough: any non-standard size goes through derived
    /// fonts stuck on the old scale (some sizes stay blurry/wrong).
    ///
    /// Update in place, don't clear: the derived cache key is (src_ptr, size), independent of
    /// scale. Real bucketing by scale happens downstream in glyph atlas GlyphKey.scale_q, where
    /// new entries appear naturally. Clearing wastes CoreText font objects that all get rebuilt
    /// next frame.
    pub fn setScaleFactor(self: *FontSelector, scale: f32) void {
        self.small.setScaleFactor(scale);
        self.medium.setScaleFactor(scale);
        self.large.setScaleFactor(scale);
        if (self.symbols_font) |f| f.setScaleFactor(scale);

        const groups = [_][]const ?*Font{
            &self.extra_fonts,
            &self.bold_fonts,
            &self.mono_fonts,
            &self.mono_bold_fonts,
            &self.mono_italic_fonts,
            &self.mono_bold_italic_fonts,
            &self.italic_fonts,
            &self.bold_italic_fonts,
            &self.cjk_fonts,
            &self.cjk_bold_fonts,
            &self.korean_fonts,
            &self.korean_bold_fonts,
        };
        for (groups) |group| {
            for (group) |maybe_font| {
                if (maybe_font) |f| f.setScaleFactor(scale);
            }
        }

        if (!self.derived_cache_inited) return;
        var it = self.derived_cache.valueIterator();
        while (it.next()) |font_ptr| {
            font_ptr.*.setScaleFactor(scale);
        }
    }

    pub const WeightLoader = struct {
        context: *anyopaque,
        load: *const fn (context: *anyopaque, font_size: f32, font_weight: u16) ?*Font,
    };

    /// The platform UI font at (size, weight), cached in derived_cache; null = no loader wired
    /// or it found nothing (the caller falls back to the default family).
    fn systemUiFont(self: *FontSelector, font_size: f32, font_weight: u16) ?*Font {
        if (!self.derived_cache_inited) return null;
        const loader = self.system_ui_loader orelse return null;
        const target_size = @max(font_size, 1.0);
        const w = quantizeWeight(font_weight);
        const size_hundredths: u32 = @intFromFloat(@round(target_size * 100));
        // seed high bits mark the UI font, disjoint from the weight and derive key spaces
        const seed: u64 = (@as(u64, 0xF1) << 56) | @as(u64, w);
        const key = std.hash.Wyhash.hash(seed, std.mem.asBytes(&size_hundredths));
        if (self.derived_cache.get(key)) |cached| return cached;
        // (no per-key miss table: that one is bound to weight_loader's identity; the UI font is
        // either there or not at all)
        if (self.system_ui_unavailable) return null;
        const font = loader.load(loader.context, target_size, w) orelse {
            self.system_ui_unavailable = true;
            return null;
        };
        font.setScaleFactor(self.small.scale_factor);
        self.derived_cache.put(key, font) catch {
            font.deinit();
            return null;
        };
        return font;
    }

    /// CSS weight rounds to 100-multiple (590 -> 600, 650 -> 700).
    pub fn quantizeWeight(w: u16) u16 {
        const clamped = std.math.clamp(w, 100, 900);
        return @intCast(((@as(u32, clamped) + 50) / 100) * 100);
    }

    /// Get font of specified size + weight (via weight_loader, cached by (weight, size)).
    fn loadWeightedCached(self: *FontSelector, font_size: f32, weight: u16) ?*Font {
        if (!self.derived_cache_inited) return null;
        const loader = self.weight_loader orelse return null;
        const target_size = @max(font_size, 1.0);
        const size_hundredths: u32 = @intFromFloat(@round(target_size * 100));
        // seed high bits mark weight, disjoint from (src_ptr, group) derive key space.
        const seed: u64 = (@as(u64, 0xF0) << 56) | @as(u64, weight);
        const key = std.hash.Wyhash.hash(seed, std.mem.asBytes(&size_hundredths));
        if (self.derived_cache.get(key)) |cached| return cached;
        if (self.isWeightMiss(loader, key)) return null;
        const font = loader.load(loader.context, target_size, weight) orelse {
            self.recordWeightMiss(loader, key);
            return null;
        };
        font.setScaleFactor(self.small.scale_factor);
        self.derived_cache.put(key, font) catch {
            font.deinit();
            return null;
        };
        return font;
    }

    fn sameLoader(a: WeightLoader, b: WeightLoader) bool {
        return a.context == b.context and a.load == b.load;
    }

    fn clearWeightMisses(self: *FontSelector) void {
        self.weight_miss_len = 0;
        self.weight_miss_next = 0;
        self.weight_miss_loader = null;
    }

    fn isWeightMiss(self: *FontSelector, loader: WeightLoader, key: u64) bool {
        const owner = self.weight_miss_loader orelse return false;
        if (!sameLoader(owner, loader)) {
            // Loader changed (family changed): old "doesn't exist" no longer holds.
            self.clearWeightMisses();
            return false;
        }
        return std.mem.indexOfScalar(u64, self.weight_misses[0..self.weight_miss_len], key) != null;
    }

    fn recordWeightMiss(self: *FontSelector, loader: WeightLoader, key: u64) void {
        if (self.weight_miss_loader) |owner| {
            if (!sameLoader(owner, loader)) self.clearWeightMisses();
        }
        self.weight_miss_loader = loader;
        self.weight_misses[self.weight_miss_next] = key;
        self.weight_miss_next = @intCast((@as(usize, self.weight_miss_next) + 1) % weight_miss_capacity);
        if (self.weight_miss_len < weight_miss_capacity) self.weight_miss_len += 1;
    }

    /// Free all dynamically-created fonts in derived cache
    pub fn deinitDerivedCache(self: *FontSelector) void {
        if (!self.derived_cache_inited) return;
        var it = self.derived_cache.valueIterator();
        while (it.next()) |font_ptr| {
            font_ptr.*.deinit();
        }
        self.derived_cache.deinit();
        self.derived_cache_inited = false;
        self.clearWeightMisses();
    }

    pub fn select(self: *FontSelector, font_size: f32) *Font {
        return self.selectWeighted(font_size, 400);
    }

    /// Pick best font by font_size and font_weight.
    /// If no exact match (exceeds epsilon) and lazy cache initialized, derive exact size.
    pub fn selectWeighted(self: *FontSelector, font_size: f32, font_weight: u16) *Font {
        if (font_weight >= 650 and self.bold_count > 0) {
            return self.selectOrDerive(&self.bold_fonts, self.bold_count, font_size, 1, font_weight);
        }
        return self.selectOrDeriveRegular(font_size, font_weight);
    }

    /// Measures text width using the preloaded font (consistent with rendering).
    /// The **only** font decision point; both rendering and measurement must go through it.
    ///
    /// == Why it must be unified (root of a whole class of recurring bugs) ==
    /// Rendering (command_encoder.drawText) and measurement (measureTextWidth) must not have
    /// separate font-selection branches: otherwise the same text is measured with one font and
    /// drawn with another (cursor stops short inside a glyph, selection highlight falls short of
    /// line end). **The divergence is in font selection, not the measurement algorithm.** Known
    /// divergences, all closed by this function:
    ///   1. use_symbols: rendering can switch the whole run to symbols_font (Menlo)
    ///   2. CJK/Korean fallback: rendering picks the fallback font **by content**; e.g.
    ///      "asdfasdf<CJK>dfasdfsdfdsf" measured (Inter)=155.894 vs rendered (PingFang)=153.514,
    ///      a 2.38px gap, the visible "one glyph short"
    ///   3. force_linear: scaling uses the *Stable variants; a mismatch picks different instances
    ///
    /// Add new font decision rules **only here**; an if at a call site reintroduces the silent
    /// misalignment.
    ///
    /// == The raster policy never reaches shaping ==
    /// A run switches between static_crisp and animated_stable whenever an animation starts or
    /// ends. Shaping with the animated policy's preloaded instance (scaled to the requested size)
    /// gave other advances than the exact-size static font, SF's size-dependent tracking being
    /// the large part (11px laid out ~10px narrower over 56 chars), so every glyph jumped at the
    /// switch. Fonts are therefore always resolved as for the static raster; `force_linear` only
    /// adds the instance the primary glyphs rasterize from (`raster`).
    pub fn resolveFonts(self: *FontSelector, content: []const u8, props: TextFontProps) ResolvedFonts {
        var layout_props = props;
        layout_props.force_linear = false;
        var resolved = self.resolveFontsForRaster(content, layout_props);
        if (props.force_linear) {
            const stable = self.resolveFontsForRaster("", props).primary;
            if (stable != resolved.primary) resolved.raster = stable;
        }
        return resolved;
    }

    /// Font decisions for one raster policy (see resolveFonts: only `.primary` of the
    /// `force_linear` variant is used, and only to rasterize).
    fn resolveFontsForRaster(self: *FontSelector, content: []const u8, props: TextFontProps) ResolvedFonts {
        const fs = props.font_size;
        const fw = props.font_weight;

        // The platform UI font (reserved family id): its own loader, ahead of the registry.
        if (props.font_family == system_ui_family and !props.use_symbols and !props.use_monospace) {
            if (self.systemUiFont(fs, fw)) |f| {
                const fb = self.resolveContentFallback(content, props, f, f);
                return .{ .primary = f, .fallback = fb.font, .fallback_is_script = fb.is_script };
            }
        }
        // Family override: explicit family uses its face.
        // symbols and mono have higher priority (list markers need symbols; mono is semantic).
        // These two are **semantic** requirement, not user font preference.
        if (props.font_family != 0 and props.font_family != system_ui_family and !props.use_symbols and !props.use_monospace) {
            if (self.family_resolve_fn) |resolve| {
                if (self.family_resolve_ctx) |ctx| {
                    if (resolve(ctx, props.font_family, fs, fw, props.use_italic)) |f| {
                        // Script fallback still goes original logic: user's family may not cover
                        // CJK.
                        const fb = self.resolveContentFallback(content, props, f, f);
                        return .{
                            .primary = f,
                            .fallback = fb.font,
                            .fallback_is_script = fb.is_script,
                        };
                    }
                }
            }
        }

        const regular_font = if (props.use_monospace)
            (if (props.force_linear)
                self.selectMonospaceWeightedStable(fs, fw, props.use_italic)
            else
                self.selectMonospaceWeighted(fs, fw, props.use_italic))
        else if (props.force_linear)
            self.selectWeightedStable(fs, fw)
        else
            self.selectWeighted(fs, fw);

        const primary = if (props.use_symbols and self.symbols_font != null)
            self.symbols_font.?
        else if (props.use_monospace)
            regular_font
        else if (props.use_italic and fw >= 650 and self.bold_italic_count > 0)
            (if (props.force_linear)
                self.selectStableFromGroup(&self.bold_italic_fonts, self.bold_italic_count, fs, fw)
            else
                self.selectOrDerive(&self.bold_italic_fonts, self.bold_italic_count, fs, 3, fw))
        else if (props.use_italic and self.italic_count > 0)
            (if (props.force_linear)
                self.selectStableFromGroup(&self.italic_fonts, self.italic_count, fs, fw)
            else
                self.selectOrDerive(&self.italic_fonts, self.italic_count, fs, 2, fw))
        else
            regular_font;

        const content_fallback = self.resolveContentFallback(content, props, primary, regular_font);
        return .{
            .primary = primary,
            .fallback = content_fallback.font,
            .fallback_is_script = content_fallback.is_script,
        };
    }

    /// resolveContentFallback return: fallback font itself + whether it's script fallback.
    /// Both must go out together, else caller can't distinguish "whole-segment font" from "fill
    /// gaps".
    const ContentFallback = struct {
        font: ?*Font = null,
        is_script: bool = false,
    };

    /// Content-dependent fallback (Han/kana -> CJK family; Hangul -> Hangul family).
    /// Same logic as command_encoder.selectCjkFallbackFont; unified here.
    fn resolveContentFallback(
        self: *FontSelector,
        content: []const u8,
        props: TextFontProps,
        primary: *Font,
        regular_font: *Font,
    ) ContentFallback {
        const fs = props.font_size;
        const fw = props.font_weight;
        // stack_mode: script fallback delegates to explicit stack (see field comment).
        // Only preserve upright fallback independent of scripts.
        if (props.stack_mode_override orelse self.stack_mode) {
            if (props.use_italic and primary != regular_font) return .{ .font = regular_font };
            return .{};
        }
        // Script fallback shapes (measurement, Windows ranges), so it is the layout choice under
        // every raster policy (see resolveFonts).
        if (script_detect.preferKoreanFallback(content)) {
            if (fw >= 650 and self.korean_bold_count > 0) {
                return .{ .is_script = true, .font = self.selectFromGroup(&self.korean_bold_fonts, self.korean_bold_count, fs) };
            }
            if (self.korean_count > 0) {
                return .{ .is_script = true, .font = self.selectFromGroup(&self.korean_fonts, self.korean_count, fs) };
            }
        }
        if (script_detect.preferCjkFallback(content)) {
            if (fw >= 650 and self.cjk_bold_count > 0) {
                return .{ .is_script = true, .font = self.selectFromGroup(&self.cjk_bold_fonts, self.cjk_bold_count, fs) };
            }
            if (self.cjk_count > 0) {
                return .{ .is_script = true, .font = self.selectFromGroup(&self.cjk_fonts, self.cjk_count, fs) };
            }
        }
        // Upright fallback for missing italic glyphs, per-glyph fill-gap, **not** whole segment.
        if (props.use_italic and primary != regular_font) return .{ .font = regular_font };
        return .{};
    }

    /// Keep old signature for callers that truly can't get content (GlyphRun shape pipeline
    /// needs font before text). Forwards to resolveFonts with an empty content slice, i.e. **no**
    /// content-dependent fallback. Prefer resolveFonts for new code.
    pub fn selectForMeasure(self: *FontSelector, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) *Font {
        return self.resolveFonts("", .{
            .font_size = font_size,
            .font_weight = font_weight,
            .use_italic = use_italic,
            .use_monospace = use_monospace,
        }).primary;
    }

    /// Measure text with the same font choice as render (including content CJK/Hangul).
    ///
    /// With fallback, the whole run is measured with the fallback font, matching text_renderer's
    /// non-null cjk_fallback behavior (see drawTextWithOptions fallback param).
    pub fn measureTextWidth(self: *FontSelector, text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
        if (text.len == 0) return 0;
        return self.measureTextWidthWithProps(text, .{
            .font_size = font_size,
            .font_weight = font_weight,
            .use_italic = use_italic,
        });
    }

    pub fn setDrawnWidthSource(self: *FontSelector, f: ?DrawnWidthFn, ctx: ?*anyopaque) void {
        self.drawn_width_fn = f;
        self.drawn_width_ctx = ctx;
    }

    /// == Why ask the renderer first, not CoreText ==
    /// `.fit` width = measure once, draw once; a mismatch shrinks to A, draws B, and clips the
    /// tail.
    /// "Drawn width" is not a pure function of (text, size): render splits per segmentText
    /// (Han per-codepoint, ASCII as words; no kerning across segments), then per-glyph
    /// x_advance * scale. CoreText CTLineGetTypographicBounds measures one full pass, which is
    /// typographically more "correct" but not **exactly what the GPU draws**. They are close for
    /// pure ASCII; mismatches on long/italic/CJK text are rare and hard to trace.
    ///
    /// So don't calculate; ask the renderer to emit the same segment loop without drawing.
    pub fn measureTextWidthWithProps(self: *FontSelector, text: []const u8, props: TextFontProps) f32 {
        if (text.len == 0) return 0;
        const font = self.resolveFonts(text, props).shapingFont();
        if (self.drawn_width_fn) |drawn| {
            if (self.drawn_width_ctx) |ctx| {
                if (drawn(ctx, text, font, props)) |w| return w;
            }
        }
        const fixed_advance = script_detect.fixedMonospaceAdvance(text, props.use_monospace, props.monospace_char_width);
        if (fixed_advance > 0) return @as(f32, @floatFromInt(text.len)) * fixed_advance;
        const text_scale = props.font_size / font.pixelSize();
        return font.measureWidth(text) * text_scale;
    }

    /// Monospace text measure (fast path for monospace fonts)
    ///
    /// Fast path: pure ASCII string -> len * cached_advance (O(1) plus O(N) ASCII scan,
    /// completely skip CoreText FFI). Non-ASCII uses full CoreText.
    pub fn measureMonospaceTextWidth(self: *FontSelector, text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
        if (text.len == 0) return 0;
        const font = self.selectMonospaceWeighted(font_size, font_weight, use_italic);
        if (isAllAscii(text)) {
            const advance = self.lookupOrInsertAsciiAdvance(font, font_size, font_weight, use_italic);
            if (advance > 0) {
                return @as(f32, @floatFromInt(text.len)) * advance;
            }
        }
        const text_scale = font_size / font.pixelSize();
        return font.measureWidth(text) * text_scale;
    }

    /// Pick monospace font (fallback to regular if no monospace group registered)
    pub fn selectMonospaceWeighted(self: *FontSelector, font_size: f32, font_weight: u16, use_italic: bool) *Font {
        if (use_italic and font_weight >= 650 and self.mono_bold_italic_count > 0) {
            return self.selectOrDerive(&self.mono_bold_italic_fonts, self.mono_bold_italic_count, font_size, 3, font_weight);
        }
        if (use_italic and self.mono_italic_count > 0) {
            return self.selectOrDerive(&self.mono_italic_fonts, self.mono_italic_count, font_size, 2, font_weight);
        }
        if (font_weight >= 650 and self.mono_bold_count > 0) {
            return self.selectOrDerive(&self.mono_bold_fonts, self.mono_bold_count, font_size, 1, font_weight);
        }
        if (self.mono_count > 0) {
            return self.selectOrDerive(&self.mono_fonts, self.mono_count, font_size, 0, font_weight);
        }
        return self.selectWeighted(font_size, font_weight);
    }

    /// From font group, pick best match by font_size (include lazy derive)
    pub fn selectFromGroup(self: *FontSelector, group: []const ?*Font, count: u8, font_size: f32) *Font {
        return self.selectOrDerive(group, count, font_size, 0, null);
    }

    // ===== Internal methods =====

    inline fn weightDelta(font_weight: u16, desired_weight: ?u16) u16 {
        const dw = desired_weight orelse return 0;
        return if (font_weight >= dw) font_weight - dw else dw - font_weight;
    }

    inline fn betterCandidate(weight_diff: u16, size_diff: f32, best_weight_diff: u16, best_size_diff: f32) bool {
        return weight_diff < best_weight_diff or (weight_diff == best_weight_diff and size_diff < best_size_diff);
    }

    inline fn betterStableCandidate(
        candidate_weight_diff: u16,
        candidate_font_px: f32,
        best_weight_diff: u16,
        best_font_px: f32,
        target: f32,
    ) bool {
        if (candidate_weight_diff != best_weight_diff) return candidate_weight_diff < best_weight_diff;

        const candidate_oversample = candidate_font_px >= target;
        const best_oversample = best_font_px >= target;
        if (candidate_oversample != best_oversample) return candidate_oversample;

        const candidate_size_diff = @abs(candidate_font_px - target);
        const best_size_diff = @abs(best_font_px - target);
        if (!std.math.approxEqAbs(f32, candidate_size_diff, best_size_diff, 0.0001)) {
            return candidate_size_diff < best_size_diff;
        }
        return candidate_font_px > best_font_px;
    }

    /// Regular group + .small/.medium/.large three base slots all participate in closest match
    fn selectOrDeriveRegular(self: *FontSelector, font_size: f32, desired_weight: u16) *Font {
        // Not in preload group: load true glyphs by weight (not substitute with regular).
        const want_weight = quantizeWeight(desired_weight);
        if (weightDelta(self.medium.weight, want_weight) >= 100) {
            if (self.loadWeightedCached(font_size, want_weight)) |f| return f;
        }
        const target = font_size;
        var best = self.small;
        var best_size_diff = @abs(self.small.pixelSize() - target);
        var best_weight_diff = weightDelta(self.small.weight, desired_weight);

        const diff_m = @abs(self.medium.pixelSize() - target);
        const weight_diff_m = weightDelta(self.medium.weight, desired_weight);
        if (betterCandidate(weight_diff_m, diff_m, best_weight_diff, best_size_diff)) {
            best = self.medium;
            best_size_diff = diff_m;
            best_weight_diff = weight_diff_m;
        }

        const diff_l = @abs(self.large.pixelSize() - target);
        const weight_diff_l = weightDelta(self.large.weight, desired_weight);
        if (betterCandidate(weight_diff_l, diff_l, best_weight_diff, best_size_diff)) {
            best = self.large;
            best_size_diff = diff_l;
            best_weight_diff = weight_diff_l;
        }

        for (self.extra_fonts[0..self.extra_count]) |maybe_font| {
            if (maybe_font) |font| {
                const size_diff = @abs(font.pixelSize() - target);
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (betterCandidate(weight_diff, size_diff, best_weight_diff, best_size_diff)) {
                    best = font;
                    best_size_diff = size_diff;
                    best_weight_diff = weight_diff;
                }
            }
        }

        // Close to exact match, reuse directly; avoid unnecessary derive.
        if (best_size_diff <= exact_size_epsilon) return best;
        return self.deriveFontCached(best, font_size, 0) orelse best;
    }

    fn selectStableRegular(self: *FontSelector, font_size: f32, desired_weight: u16) *Font {
        const want_weight = quantizeWeight(desired_weight);
        if (weightDelta(self.medium.weight, want_weight) >= 100) {
            // Stable path (zoom animation): don't derive arbitrary sizes, load with closest preload
            // by weight.
            const presets = [_]f32{ self.small.pixelSize(), self.medium.pixelSize(), self.large.pixelSize() };
            var nearest = presets[0];
            for (presets[1..]) |p| {
                if (@abs(p - font_size) < @abs(nearest - font_size)) nearest = p;
            }
            if (self.loadWeightedCached(nearest, want_weight)) |f| return f;
        }
        const target = font_size;
        var best = self.small;
        var best_font_px = self.small.pixelSize();
        var best_weight_diff = weightDelta(self.small.weight, desired_weight);

        const medium_px = self.medium.pixelSize();
        const medium_weight_diff = weightDelta(self.medium.weight, desired_weight);
        if (betterStableCandidate(medium_weight_diff, medium_px, best_weight_diff, best_font_px, target)) {
            best = self.medium;
            best_font_px = medium_px;
            best_weight_diff = medium_weight_diff;
        }

        const large_px = self.large.pixelSize();
        const large_weight_diff = weightDelta(self.large.weight, desired_weight);
        if (betterStableCandidate(large_weight_diff, large_px, best_weight_diff, best_font_px, target)) {
            best = self.large;
            best_font_px = large_px;
            best_weight_diff = large_weight_diff;
        }

        for (self.extra_fonts[0..self.extra_count]) |maybe_font| {
            if (maybe_font) |font| {
                const font_px = font.pixelSize();
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (betterStableCandidate(weight_diff, font_px, best_weight_diff, best_font_px, target)) {
                    best = font;
                    best_font_px = font_px;
                    best_weight_diff = weight_diff;
                }
            }
        }
        return best;
    }

    /// Find closest match in any group; if size misses exact, lazy derive.
    fn selectOrDerive(
        self: *FontSelector,
        group: []const ?*Font,
        count: u8,
        font_size: f32,
        group_idx: u4,
        desired_weight: ?u16,
    ) *Font {
        var best: ?*Font = null;
        var best_size_diff: f32 = std.math.inf(f32);
        var best_weight_diff: u16 = std.math.maxInt(u16);
        for (group[0..count]) |maybe_font| {
            if (maybe_font) |font| {
                const size_diff = @abs(font.pixelSize() - font_size);
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (best == null or betterCandidate(weight_diff, size_diff, best_weight_diff, best_size_diff)) {
                    best = font;
                    best_size_diff = size_diff;
                    best_weight_diff = weight_diff;
                }
            }
        }
        const b = best orelse return self.selectWeighted(font_size, desired_weight orelse 400);
        if (best_size_diff <= exact_size_epsilon) return b;
        return self.deriveFontCached(b, font_size, group_idx) orelse b;
    }

    pub fn selectStableFromGroup(
        self: *FontSelector,
        group: []const ?*Font,
        count: u8,
        font_size: f32,
        desired_weight: ?u16,
    ) *Font {
        var best: ?*Font = null;
        var best_font_px: f32 = 0;
        var best_weight_diff: u16 = std.math.maxInt(u16);
        for (group[0..count]) |maybe_font| {
            if (maybe_font) |font| {
                const font_px = font.pixelSize();
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (best == null or betterStableCandidate(weight_diff, font_px, best_weight_diff, best_font_px, font_size)) {
                    best = font;
                    best_font_px = font_px;
                    best_weight_diff = weight_diff;
                }
            }
        }
        return best orelse self.selectWeightedStable(font_size, desired_weight orelse 400);
    }

    pub fn selectWeightedStable(self: *FontSelector, font_size: f32, font_weight: u16) *Font {
        if (font_weight >= 650 and self.bold_count > 0) {
            return self.selectStableFromGroup(&self.bold_fonts, self.bold_count, font_size, font_weight);
        }
        return self.selectStableRegular(font_size, font_weight);
    }

    pub fn selectMonospaceWeightedStable(self: *FontSelector, font_size: f32, font_weight: u16, use_italic: bool) *Font {
        if (use_italic and font_weight >= 650 and self.mono_bold_italic_count > 0) {
            return self.selectStableFromGroup(&self.mono_bold_italic_fonts, self.mono_bold_italic_count, font_size, font_weight);
        }
        if (use_italic and self.mono_italic_count > 0) {
            return self.selectStableFromGroup(&self.mono_italic_fonts, self.mono_italic_count, font_size, font_weight);
        }
        if (font_weight >= 650 and self.mono_bold_count > 0) {
            return self.selectStableFromGroup(&self.mono_bold_fonts, self.mono_bold_count, font_size, font_weight);
        }
        if (self.mono_count > 0) {
            return self.selectStableFromGroup(&self.mono_fonts, self.mono_count, font_size, font_weight);
        }
        return self.selectWeightedStable(font_size, font_weight);
    }

    /// Get or derive font from cache
    fn deriveFontCached(self: *FontSelector, src: *Font, font_size: f32, group_idx: u4) ?*Font {
        if (!self.derived_cache_inited) return null;
        const target_size = @max(font_size, 1.0);
        const size_hundredths: u32 = @intFromFloat(@round(target_size * 100));
        const seed = (@as(u64, @intFromPtr(src)) << 4) | @as(u64, @intCast(group_idx));
        const key = std.hash.Wyhash.hash(seed, std.mem.asBytes(&size_hundredths));
        if (self.derived_cache.get(key)) |cached| return cached;

        const derived = src.derive(target_size) catch return null;
        self.derived_cache.put(key, derived) catch {
            derived.deinit();
            return null;
        };
        return derived;
    }
};
