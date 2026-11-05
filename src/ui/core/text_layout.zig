/// Text line-breaking calculation module. Computes break points during
/// layout based on available width, supports word and char modes. Break
/// results cached in TextLayout, recalculated only when content/available_width
/// changes.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const TextWrap = types.TextWrap;
const TextSpan = types.TextSpan;
const grapheme = @import("text_core").grapheme;

const native_text = if (builtin.os.tag == .macos and !builtin.is_test) struct {
    extern fn coretext_measure_text_width_utf8(text: [*]const u8, len: c_int, font_size: f32) f32;
    extern fn coretext_measure_text_width_weighted(text: [*]const u8, len: c_int, font_size: f32, font_weight: c_int) f32;
} else struct {};

fn usePlatformTextMeasure() bool {
    return comptime (builtin.os.tag == .macos and !builtin.is_test);
}

/// External injected measure function (uses preloaded fonts, consistent
/// with rendering). Parameters: text_ptr, text_len, font_size, font_weight,
/// use_italic. Thread safety: set once in runApp init via setMeasureFn,
/// then read-only. Safe while single-threaded; multithreaded layout would
/// need atomic or thread-local.
pub const MeasureFn = *const fn ([*]const u8, usize, f32, u16, bool) f32;
var external_measure_fn: ?MeasureFn = null;
var external_monospace_measure_fn: ?MeasureFn = null;

/// Measure callback with context, needed for multiple Apps / multiple windows.
/// The old MeasureFn lacks context; the caller (zenit_app.runtime) only has one process-level
/// global g_font_selector_for_measure, so with two coexisting Apps the later one overwrites
/// the earlier and the first window measures text with the wrong font. One of the last two
/// non-World global dependencies in multiwindow (other is a11y active context).
/// Context version takes priority over no-context version; neither set falls back to
/// platform/fallback paths.
pub const MeasureCtxFn = *const fn (ctx: *anyopaque, [*]const u8, usize, f32, u16, bool) f32;
var external_measure_ctx_fn: ?MeasureCtxFn = null;
var external_measure_ctx: ?*anyopaque = null;

/// Current measure context identity, enters MeasureKey. 0 when no ctx.
fn currentMeasureCtxId() u64 {
    const ctx = external_measure_ctx orelse return 0;
    return @intFromPtr(ctx);
}

pub fn setMeasureCtxFn(f: ?MeasureCtxFn, ctx: ?*anyopaque) void {
    if (external_measure_ctx_fn == f and external_measure_ctx == ctx) return;
    external_measure_ctx_fn = f;
    external_measure_ctx = ctx;
    // Doesn't clear the table: ctx identity is already part of MeasureKey (see
    // measure_ctx_id), so different ctx entries never collide. (Clearing on every ctx change
    // made MultiWindowApp, which runs each window's layout() sequentially, wipe the entire
    // 16384-entry table each time: hit rate always 0.)
    // Stale assumption: ctx pointer same but contents replaced in-place (e.g., same FontSelector
    // switched family/state) reuses old widths. Framework setFontSelector always passes a new
    // object pointer, so it won't hit; a host mutating in-place must call
    // invalidateMeasureCache() manually.
}

pub fn setMeasureFn(f: ?MeasureFn) void {
    // Idempotent: Cx.layout() always calls this fn to sync measure_fn. Fn
    // unchanged must never invalidate, else measure cache cleared entire table
    // each layout, becoming decorative (true root cause of N uncached CoreText
    // calls per frame in list scenarios).
    if (external_measure_fn == f) return;
    external_measure_fn = f;
    invalidateMeasureCache();
}

/// Set monospace-specific measure function (for monospace text scenarios).
pub fn setMonospaceMeasureFn(f: ?MeasureFn) void {
    if (external_monospace_measure_fn == f) return;
    external_monospace_measure_fn = f;
    invalidateMeasureCache();
}

/// Inject GlyphRun pipeline measure callback. layoutNode entry sets it when activating the
/// measure context; measureProportional prioritizes calling it for GlyphRun cache ->
/// ShapingCache hit / TextShaper.shape miss-path. Returning NaN means pipeline
/// unavailable (cache unhooked, font lookup failed, etc.), auto-fallback to
/// platform measure. This makes all legacy paths (layout/findLineBreak/
/// computeTextLayout etc.) use the GlyphRun pipeline without changing callers.
/// Thread safety same as setMeasureFn: layoutNode entry sets, exit restores.
pub const ShapeMeasureFn = *const fn (text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32;
var g_shape_measure_fn: ?ShapeMeasureFn = null;

pub fn setShapeMeasureFn(f: ?ShapeMeasureFn) void {
    g_shape_measure_fn = f;
}

/// Diagnostic: is GlyphRun measure hook currently installed. The hook is only active during
/// layoutNode (see thread-safety above), empty during draw/overlay phases. Thus the same text
/// measures by shaping width during layout but by platform fallback during overlay, and the
/// mismatch misaligns selection highlight and cursor with glyphs. Anyone measuring text
/// outside layout should first assert which world they are in with this.
pub fn hasShapeMeasure() bool {
    return g_shape_measure_fn != null;
}

/// Clear measure cache. Must call when measure fn changes (different fns,
/// same key should give different widths).
pub fn invalidateMeasureCache() void {
    // A generation bump invalidates every entry without writing the table
    // (zero-filled storage stays untouched, outside the process footprint).
    g_measure_cache_generation +%= 1;
    g_measure_cache_live = 0;
    if (g_measure_cache_generation == 0) {
        @memset(g_measure_cache, .{ .key = undefined, .width = 0, .last_used = 0, .generation = 0 });
        g_measure_cache_generation = 1;
    }
}

// Measure cache: text_hash + font params -> width. Target: shape cache > 95% hit. Hit skips
// CoreText shape call (~10-100us). Single-threaded, 2-way set-assoc, LRU eviction. Same
// text is reused at high frequency within a frame (100 list rows with the same "Item N"
// text each call measure_x N times). Capacity basis: a dense 40KB Chinese document cold-open
// produces ~16.5k unique (segment, font) keys; 4096 capacity evicted twice in a single
// open, so revert/reopen redid all shaping.
// 16384 x ~48B = ~786KB, keeps whole document segments resident. The table
// starts small and doubles at half load, so a window of labels does not keep
// the full table resident (hashed writes would dirty most of its pages).
const MEASURE_CACHE_CAP: usize = 16384;
const MEASURE_CACHE_INITIAL: usize = 1024;
const MeasureKey = packed struct {
    text_hash: u64,
    font_size_bits: u32, // f32 reinterpret used as integral key part.
    font_weight: u16,
    use_italic: u8, // bool 0/1
    text_len_low: u8, // text length low 8 bits (prevent short collision).
    /// Mono and proportional have different widths for same (text,size,weight),
    /// must separate keys, else whoever measures first their value wrongly reused
    /// by other.
    use_monospace: u8 = 0,
    /// Measure context identity (pointer value of external_measure_ctx, 0 when
    /// no ctx). In multiwindow each App's measure_ctx is the address of its own
    /// &app.font_selector, so they are naturally distinct. With it in the key, results from
    /// different windows coexist in one table; otherwise cross-contamination could only be
    /// prevented by clearing the whole table on ctx change, which MultiWindowApp (each window's
    /// layout() run sequentially per frame) would do every frame: hit rate zero.
    measure_ctx_id: u64 = 0,
};
const MeasureEntry = struct {
    key: MeasureKey,
    width: f32,
    last_used: u64,
    /// Valid when equal to g_measure_cache_generation (never 0).
    generation: u32 = 0,
};
var g_measure_cache: []MeasureEntry = &.{};
var g_measure_cache_live: usize = 0;
var g_measure_cache_generation: u32 = 1;

fn measureCacheResize(len: usize) bool {
    const fresh = std.heap.page_allocator.alloc(MeasureEntry, len) catch return false;
    @memset(fresh, .{ .key = undefined, .width = 0, .last_used = 0, .generation = 0 });
    const old = g_measure_cache;
    g_measure_cache = fresh;
    g_measure_cache_live = 0;
    for (old) |e| if (e.generation == g_measure_cache_generation) measureCacheInsert(e);
    if (old.len > 0) std.heap.page_allocator.free(old);
    return true;
}

fn measureCacheInsert(entry: MeasureEntry) void {
    const base: usize = @intCast((entry.key.text_hash % g_measure_cache.len) & ~@as(u64, 1));
    const e0 = &g_measure_cache[base];
    const e1 = &g_measure_cache[base + 1];
    const gen = g_measure_cache_generation;
    const target = if (e0.generation != gen) e0 else if (e1.generation != gen) e1 else if (e0.last_used <= e1.last_used) e0 else e1;
    if (target.generation != gen) g_measure_cache_live += 1;
    target.* = entry;
    target.generation = gen;
}
var g_measure_cache_clock: u64 = 0;
var g_measure_cache_hits: u64 = 0;
var g_measure_cache_misses: u64 = 0;

pub const MeasureCacheStats = struct {
    hits: u64,
    misses: u64,
    pub fn hitRate(self: MeasureCacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

pub fn measureCacheStats() MeasureCacheStats {
    return .{ .hits = g_measure_cache_hits, .misses = g_measure_cache_misses };
}

pub fn resetMeasureCacheStats() void {
    g_measure_cache_hits = 0;
    g_measure_cache_misses = 0;
}

inline fn measureKeyEq(a: MeasureKey, b: MeasureKey) bool {
    return a.text_hash == b.text_hash and
        a.font_size_bits == b.font_size_bits and
        a.font_weight == b.font_weight and
        a.use_italic == b.use_italic and
        a.text_len_low == b.text_len_low and
        a.use_monospace == b.use_monospace and
        // Note: this function compares field-by-field not bitwise whole, adding
        // MeasureKey fields must also sync here, else that field (different values
        // hit each other).
        a.measure_ctx_id == b.measure_ctx_id;
}

// 2-way set-associative: direct-mapped hot key conflicts kick each other
// (repeated CoreText remeasure), two slots/group + group LRU eviction
// significantly lowers thrash, same capacity.
fn measureCacheLookup(key: MeasureKey) ?f32 {
    if (g_measure_cache.len == 0) {
        g_measure_cache_misses += 1;
        return null;
    }
    const base: usize = @intCast((key.text_hash % g_measure_cache.len) & ~@as(u64, 1));
    inline for (0..2) |way| {
        const e = &g_measure_cache[base + way];
        if (e.generation == g_measure_cache_generation and measureKeyEq(e.key, key)) {
            g_measure_cache_clock += 1;
            e.last_used = g_measure_cache_clock;
            g_measure_cache_hits += 1;
            return e.width;
        }
    }
    g_measure_cache_misses += 1;
    return null;
}

fn measureCacheStore(key: MeasureKey, width: f32) void {
    if (g_measure_cache.len == 0 and !measureCacheResize(MEASURE_CACHE_INITIAL)) return;
    if (g_measure_cache_live * 2 >= g_measure_cache.len and g_measure_cache.len < MEASURE_CACHE_CAP)
        _ = measureCacheResize(g_measure_cache.len * 2);
    g_measure_cache_clock += 1;
    measureCacheInsert(.{ .key = key, .width = width, .last_used = g_measure_cache_clock });
}

/// Internal proportional measure + cache. Sole aggregation point for
/// measureTextWidthByFontKind / measureMonospaceTextWidth fallback. The GlyphRun
/// pipeline main path is in cx.shapeText / measureSegmentWidthCtx /
/// measureIntrinsicTextWidthCtx; this fn is the fallback's last stop.
fn measureProportional(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    if (text.len == 0) return 0;
    // GlyphRun pipeline fast path (hit returns cache total_advance; miss
    // callback shapes + inserts then returns). NaN treated unavailable (pipeline
    // unhooked or shape failed), fallback to platform measure.
    if (g_shape_measure_fn) |shape_fn| {
        const w = shape_fn(text, font_size, font_weight, use_italic, false);
        if (!std.math.isNan(w)) return w;
    }
    // measure cache lookup
    const text_hash = std.hash.Wyhash.hash(0, text);
    const key = MeasureKey{
        .text_hash = text_hash,
        .font_size_bits = @bitCast(font_size),
        .font_weight = font_weight,
        .use_italic = if (use_italic) 1 else 0,
        .text_len_low = @truncate(text.len),
        .measure_ctx_id = currentMeasureCtxId(),
    };
    if (measureCacheLookup(key)) |w| return w;

    const computed: f32 = blk: {
        // Context-aware callback priority, locates that specific App's font
        // selector, while no-context version only reads process-level global
        // (multiwindow cross-talks).
        if (external_measure_ctx_fn) |f| {
            if (external_measure_ctx) |ctx| {
                break :blk f(ctx, text.ptr, text.len, font_size, font_weight, use_italic);
            }
        }
        if (external_measure_fn) |f| {
            break :blk f(text.ptr, text.len, font_size, font_weight, use_italic);
        }
        if (comptime usePlatformTextMeasure()) {
            if (font_weight > 400) {
                break :blk native_text.coretext_measure_text_width_weighted(text.ptr, @intCast(text.len), font_size, @intCast(font_weight));
            }
            break :blk native_text.coretext_measure_text_width_utf8(text.ptr, @intCast(text.len), font_size);
        }
        if (builtin.os.tag == .freestanding) @panic("freestanding text measurement requires an injected hook");
        // Fallback: rough estimate by codepoint (ASCII 0.6em, non-ASCII full-width
        // 1.0em). Can't use byte count; CJK 3 bytes/char, byte count overestimates
        // ~3x (selection/cursor misaligned).
        var est: f32 = 0;
        const view = std.unicode.Utf8View.init(text) catch
            break :blk @as(f32, @floatFromInt(text.len)) * font_size * 0.6;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            est += if (cp < 0x80) font_size * 0.6 else font_size;
        }
        break :blk est;
    };
    measureCacheStore(key, computed);
    return computed;
}

/// Monospace text width measurement (priority walk monospace-specific
/// function).
pub fn measureMonospaceTextWidth(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    if (text.len == 0) return 0;
    // Same as proportional path priority walk GlyphRun pipeline.
    if (g_shape_measure_fn) |shape_fn| {
        const w = shape_fn(text, font_size, font_weight, use_italic, true);
        if (!std.math.isNan(w)) return w;
    }
    if (external_monospace_measure_fn) |f| {
        // Walk cache (use_monospace=1 separate key): external mono measure same
        // FFI/shaping overhead, before uncached.
        const key = MeasureKey{
            .text_hash = std.hash.Wyhash.hash(0, text),
            .font_size_bits = @bitCast(font_size),
            .font_weight = font_weight,
            .use_italic = if (use_italic) 1 else 0,
            .text_len_low = @truncate(text.len),
            .use_monospace = 1,
            .measure_ctx_id = currentMeasureCtxId(),
        };
        if (measureCacheLookup(key)) |w| return w;
        const computed = f(text.ptr, text.len, font_size, font_weight, use_italic);
        measureCacheStore(key, computed);
        return computed;
    }
    return measureProportional(text, font_size, font_weight, use_italic);
}

/// Measure text width by font kind (monospace fast path). Unified entry for
/// render_engine + input components, avoids duplicate wrappers. GlyphRun
/// pipeline main path is in cx.shapeText / measureSegmentWidthCtx /
/// measureIntrinsicTextWidthCtx. This fn is the fallback's last stop
/// (no cx / shape failed degradation path).
pub inline fn measureTextWidthByFontKind(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    return if (use_monospace)
        measureMonospaceTextWidth(text, font_size, font_weight, use_italic)
    else
        measureProportional(text, font_size, font_weight, use_italic);
}

pub const InlineBoxMetrics = struct {
    leading_advance: f32 = 0,
    trailing_advance: f32 = 0,
    inset_top: f32 = 0,
    inset_bottom: f32 = 0,
    corner_radius: f32 = 0,

    pub fn totalHorizontalAdvance(self: InlineBoxMetrics) f32 {
        return self.leading_advance + self.trailing_advance;
    }
};

pub fn spanHasInlineBox(span: TextSpan) bool {
    return span.inline_box_padding_left > 0 or
        span.inline_box_padding_right > 0 or
        span.inline_box_inset_top > 0 or
        span.inline_box_inset_bottom > 0 or
        span.inline_box_corner_radius > 0;
}

pub fn inlineBoxMetricsForFragment(span: TextSpan, frag_start: u32, frag_end: u32) InlineBoxMetrics {
    if (!spanHasInlineBox(span) or frag_start >= frag_end) return .{};
    return .{
        .leading_advance = if (frag_start == span.start) span.inline_box_padding_left else 0,
        .trailing_advance = if (frag_end == span.end) span.inline_box_padding_right else 0,
        .inset_top = span.inline_box_inset_top,
        .inset_bottom = span.inline_box_inset_bottom,
        .corner_radius = span.inline_box_corner_radius,
    };
}

/// Measure text width by TextSpan segments. Logic consistent with
/// renderLineWithSpans: iterate [start..end] range, span-covered segments use
/// span.font_weight/italic, uncovered use base_fw/base_italic.
pub fn measureTextWidthWithSpans(
    content: []const u8,
    start: u32,
    end: u32,
    font_size: f32,
    base_fw: u16,
    base_italic: bool,
    base_use_monospace: bool,
    spans: []const TextSpan,
) f32 {
    if (start >= end) return 0;
    if (spans.len == 0) return measureTextWidthByFontKind(content[start..end], font_size, base_fw, base_italic, base_use_monospace);

    var total: f32 = 0;
    var pos: u32 = start;

    for (spans) |span| {
        if (span.end <= start) continue;
        if (span.start >= end) break;

        const seg_start = @max(span.start, start);
        const seg_end = @min(span.end, end);
        if (seg_start >= seg_end) continue;

        // Gap before span uses base_fw/base_italic.
        if (pos < seg_start) {
            total += measureTextWidthByFontKind(content[pos..seg_start], font_size, base_fw, base_italic, base_use_monospace);
        }

        // Span segment uses span's own fw/italic/monospace.
        const seg_fw = span.font_weight orelse base_fw;
        const seg_italic = span.use_italic_font or base_italic;
        const seg_monospace = span.use_monospace_font or base_use_monospace;
        const box_metrics = inlineBoxMetricsForFragment(span, seg_start, seg_end);
        total += measureTextWidthByFontKind(content[seg_start..seg_end], font_size, seg_fw, seg_italic, seg_monospace);
        total += box_metrics.totalHorizontalAdvance();
        pos = seg_end;
    }

    // Tail text without span coverage.
    if (pos < end) {
        total += measureTextWidthByFontKind(content[pos..end], font_size, base_fw, base_italic, base_use_monospace);
    }

    return total;
}

/// Visual line start offset (px, >= 0) at content width `avail_w` per
/// `text_align`. Rendering (text_item_render) and host's cursor/hit/selection
/// conversion must share this one formula, else centered text's cursor misaligns
/// with glyphs. Line wider than available (overflow) doesn't offset.
pub fn alignLineOffset(text_align: types.TextAlign, avail_w: f32, line_w: f32) f32 {
    if (text_align == .start) return 0;
    if (!std.math.isFinite(avail_w) or !std.math.isFinite(line_w)) return 0;
    const slack = avail_w - line_w;
    if (slack <= 0) return 0;
    return switch (text_align) {
        .start => 0,
        .center => slack / 2,
        .end => slack,
    };
}

test "alignLineOffset: start/center/end, overflow and non-finite input" {
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.start, 100, 40));
    try std.testing.expectEqual(@as(f32, 30), alignLineOffset(.center, 100, 40));
    try std.testing.expectEqual(@as(f32, 60), alignLineOffset(.end, 100, 40));
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.center, 40, 100));
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.center, std.math.nan(f32), 10));
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.end, std.math.inf(f32), 10));
}

/// Italic glyphs often have typographic advance overhang on right. Provides
/// unified heuristic padding for visual extension of background/selection
/// rectangles, doesn't participate in hit-test or cursor positioning, avoids
/// logical width drift.
pub fn estimateItalicOverhangPadding(font_size: f32, use_italic: bool) f32 {
    if (!use_italic) return 0;
    return std.math.clamp(font_size * 0.12, 1.0, 4.0);
}

// Phase 5: cap 64 -> 1024. Full ArrayList conversion in Phase 6 text
// pipeline rewrite (integrate with text_core PieceTree together); current
// 1024 far exceeds any UI text scenario.
pub const MAX_LINES = 1024;
pub const INTERACTION_PREFIX_MAX_CHARS: usize = 1024;
const INTERACTION_PREFIX_CACHE_SIZE: usize = 512;
// Sidecar hash table (open addressing). >= 2x cache size for low collision rate.
const INTERACTION_PREFIX_INDEX_SIZE: usize = 2048;
const INTERACTION_PREFIX_INDEX_MASK: usize = INTERACTION_PREFIX_INDEX_SIZE - 1;
const INTERACTION_PREFIX_INDEX_PROBE_LIMIT: usize = 8;
/// Sentinel: sidecar slot empty / evicted.
const INVALID_CACHE_IDX: u16 = std.math.maxInt(u16);

pub const LineInfo = struct {
    byte_start: u32,
    byte_end: u32,
    width: f32,
};

pub const TextLayout = struct {
    lines: [MAX_LINES]LineInfo = undefined,
    line_count: u16 = 0,
    total_height: f32 = 0,
    max_line_width: f32 = 0,
    // Cache key, triple-check ptr+len+hash.
    cached_content_ptr: [*]const u8 = undefined,
    cached_content_len: usize = 0,
    cached_content_hash: u64 = 0,
    cached_available_width: f32 = 0,
    cached_font_weight: u16 = 400,
    cached_font_size: f32 = 0,
    cached_use_italic: bool = false,
    cached_use_monospace: bool = false,
    cached_wrap: TextWrap = .none,
    cached_max_lines: u16 = 0,
    cached_spans_hash: u64 = 0,
};

// Hot header, accessed every lookup. ~64 bytes (one cache line). Header/payload split:
// ~32KB of headers fit L1 (boundaries+prefix_widths payload is ~4.2MB), and a sidecar hash
// index makes lookup O(1) instead of a linear scan with a cache miss per entry.
const InteractionPrefixCacheHeader = struct {
    valid: bool = false,
    use_italic: bool = false,
    use_monospace: bool = false,
    _pad0: u8 = 0,
    boundary_count: u16 = 0,
    font_weight: u16 = 0,
    node_id: u32 = 0,
    content_version: u32 = 0,
    range_start: u32 = 0,
    range_end: u32 = 0,
    font_size: f32 = 0,
    last_used_gen: u32 = 0,
    spans_hash: u64 = 0,
    key_hash: u64 = 0, // Full key pre-computed hash, sidecar lookup uses.
};

const InteractionPrefixCachePayload = struct {
    boundaries: [INTERACTION_PREFIX_MAX_CHARS + 1]u32 = @as([(INTERACTION_PREFIX_MAX_CHARS + 1)]u32, @splat(0)),
    prefix_widths: [INTERACTION_PREFIX_MAX_CHARS + 1]f32 = @as([(INTERACTION_PREFIX_MAX_CHARS + 1)]f32, @splat(0)),
};

/// Build failure (range too long) key memo: after one failure same key
/// doesn't retry full table. 32-entry ring covers "same screen several long
/// lines repeated interaction"; key includes content_version, auto-invalidates
/// after edit.
var g_prefix_build_failed_ring: [32]u64 = @as([32]u64, @splat(0));
var g_prefix_build_failed_cursor: usize = 0;

var interaction_prefix_cache_headers: [INTERACTION_PREFIX_CACHE_SIZE]InteractionPrefixCacheHeader =
    @as([INTERACTION_PREFIX_CACHE_SIZE]InteractionPrefixCacheHeader, @splat(.{}));
var interaction_prefix_cache_payloads: [INTERACTION_PREFIX_CACHE_SIZE]InteractionPrefixCachePayload =
    @as([INTERACTION_PREFIX_CACHE_SIZE]InteractionPrefixCachePayload, @splat(.{}));
/// Sidecar: bucket -> entry index in headers/payloads. INVALID_CACHE_IDX
/// means empty slot.
var interaction_prefix_cache_index: [INTERACTION_PREFIX_INDEX_SIZE]u16 =
    @as([INTERACTION_PREFIX_INDEX_SIZE]u16, @splat(INVALID_CACHE_IDX));
var interaction_prefix_cache_gen: u32 = 1;

inline fn computeInteractionPrefixKeyHash(
    node_id: u32,
    content_version: u32,
    range_start: u32,
    range_end: u32,
    spans_hash: u64,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&node_id));
    hasher.update(std.mem.asBytes(&content_version));
    hasher.update(std.mem.asBytes(&range_start));
    hasher.update(std.mem.asBytes(&range_end));
    hasher.update(std.mem.asBytes(&spans_hash));
    hasher.update(std.mem.asBytes(&font_size));
    hasher.update(std.mem.asBytes(&font_weight));
    const flags: u8 = (if (use_italic) @as(u8, 1) else 0) | (if (use_monospace) @as(u8, 2) else 0);
    hasher.update(std.mem.asBytes(&flags));
    return hasher.final();
}

inline fn cacheIndexBucket(key_hash: u64) usize {
    return @as(usize, @intCast(key_hash & INTERACTION_PREFIX_INDEX_MASK));
}

/// Lookup key_hash in sidecar -> entry idx.
fn sidecarLookup(key_hash: u64) ?u16 {
    var probe: usize = 0;
    while (probe < INTERACTION_PREFIX_INDEX_PROBE_LIMIT) : (probe += 1) {
        const bucket = (cacheIndexBucket(key_hash) + probe) & INTERACTION_PREFIX_INDEX_MASK;
        const idx = interaction_prefix_cache_index[bucket];
        if (idx == INVALID_CACHE_IDX) return null;
        const h = &interaction_prefix_cache_headers[idx];
        if (h.valid and h.key_hash == key_hash) return idx;
    }
    return null;
}

fn sidecarInsert(key_hash: u64, entry_idx: u16) void {
    var probe: usize = 0;
    while (probe < INTERACTION_PREFIX_INDEX_PROBE_LIMIT) : (probe += 1) {
        const bucket = (cacheIndexBucket(key_hash) + probe) & INTERACTION_PREFIX_INDEX_MASK;
        const slot = interaction_prefix_cache_index[bucket];
        if (slot == INVALID_CACHE_IDX or slot == entry_idx) {
            interaction_prefix_cache_index[bucket] = entry_idx;
            return;
        }
        const existing = &interaction_prefix_cache_headers[slot];
        if (!existing.valid) {
            interaction_prefix_cache_index[bucket] = entry_idx;
            return;
        }
    }
    // Probe overflow: cover first bucket (rare, PROBE_LIMIT=8 has ample
    // space).
    interaction_prefix_cache_index[cacheIndexBucket(key_hash)] = entry_idx;
}

/// When entry evicted, clear all buckets in sidecar pointing to it.
fn sidecarRemoveByIndex(entry_idx: u16) void {
    for (&interaction_prefix_cache_index) |*slot| {
        if (slot.* == entry_idx) slot.* = INVALID_CACHE_IDX;
    }
}

fn nextInteractionCacheGen() u32 {
    interaction_prefix_cache_gen +%= 1;
    if (interaction_prefix_cache_gen == 0) {
        interaction_prefix_cache_gen = 1;
    }
    return interaction_prefix_cache_gen;
}

fn findInteractionPrefixCacheIndexByHash(key_hash: u64) ?usize {
    if (sidecarLookup(key_hash)) |idx| {
        const h = &interaction_prefix_cache_headers[idx];
        h.last_used_gen = nextInteractionCacheGen();
        return @as(usize, idx);
    }
    return null;
}

fn allocInteractionPrefixCacheIndex() usize {
    var lru_idx: usize = 0;
    var lru_gen: u32 = std.math.maxInt(u32);

    // O(N) LRU scan still exists on alloc path, but alloc only called on cache
    // miss, far lower than lookup frequency. N=512 scan ~512 cycles, acceptable.
    for (&interaction_prefix_cache_headers, 0..) |*h, idx| {
        if (!h.valid) {
            h.* = .{};
            h.last_used_gen = nextInteractionCacheGen();
            return idx;
        }
        if (h.last_used_gen <= lru_gen) {
            lru_gen = h.last_used_gen;
            lru_idx = idx;
        }
    }

    // Evict: first clear bucket in sidecar pointing to entry.
    sidecarRemoveByIndex(@intCast(lru_idx));
    interaction_prefix_cache_headers[lru_idx] = .{};
    interaction_prefix_cache_headers[lru_idx].last_used_gen = nextInteractionCacheGen();
    return lru_idx;
}

pub fn buildPrefixWidthsForRange(
    content: []const u8,
    range_start: u32,
    range_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
    boundaries: []u32,
    prefix_widths: []f32,
) ?usize {
    if (range_end <= range_start or range_end > content.len) return null;
    if (boundaries.len == 0 or boundaries.len != prefix_widths.len) return null;

    const text = content[range_start..range_end];
    boundaries[0] = 0;
    prefix_widths[0] = 0;

    // Chunked incremental measurement. Re-measuring the entire prefix from range_start for each
    // grapheme would be O(N^2) shaped bytes, and each prefix is a different string so the
    // measure cache never hits (500-char line = 500 full-price CoreText calls on avg 250-byte
    // strings). Instead drop a checkpoint every PREFIX_CHUNK_GRAPHEMES and measure only
    // [checkpoint, next) (span semantics unchanged: measureTextWidthWithSpans collects spans by
    // content global offset); prefix width = checkpoint cumulative + chunk width.
    // Cost: kerning lost at checkpoint boundary (CJK=0, Latin pair subpixel, at most once per 64
    // graphemes); binary search monotonicity unaffected.
    var off: usize = 0;
    var count: usize = 1;
    var chunk_base_off: u32 = 0;
    var chunk_base_w: f32 = 0;
    var since_checkpoint: usize = 0;
    var grapheme_cursor = grapheme.BoundaryCursor.init(text);
    while (off < text.len and count < boundaries.len) {
        const next_off = grapheme_cursor.next(off);
        const chunk_w = measureTextWidthWithSpans(
            content,
            range_start + chunk_base_off,
            range_start + @as(u32, @intCast(next_off)),
            font_size,
            font_weight,
            use_italic,
            use_monospace,
            spans,
        );
        const prefix_w = chunk_base_w + chunk_w;
        boundaries[count] = @intCast(next_off);
        prefix_widths[count] = prefix_w;
        off = next_off;
        count += 1;
        since_checkpoint += 1;
        if (since_checkpoint >= PREFIX_CHUNK_GRAPHEMES) {
            chunk_base_off = @intCast(off);
            chunk_base_w = prefix_w;
            since_checkpoint = 0;
        }
    }

    if (off < text.len) return null;
    return count;
}

/// Checkpoint interval for buildPrefixWidthsForRange. Smaller closer to full
/// prefix measurement kerning semantics, larger single-measurement string
/// longer; 64 graphemes ≈ 256 bytes CJK / 64 bytes ASCII, chunk-internal
/// substring short enough measure cache miss also cheap.
const PREFIX_CHUNK_GRAPHEMES: usize = 64;

pub fn hitTestPrefixBoundaries(
    boundaries: []const u32,
    prefix_widths: []const f32,
    boundary_count: usize,
    target_x: f32,
) usize {
    if (boundary_count <= 1 or target_x <= 0) return 0;

    const total_w = prefix_widths[boundary_count - 1];
    if (target_x >= total_w) return boundaries[boundary_count - 1];

    var lo: usize = 1;
    var hi: usize = boundary_count - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (prefix_widths[mid] <= target_x) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    const prev_idx = lo - 1;
    const prev_w = prefix_widths[prev_idx];
    const cur_w = prefix_widths[lo];
    const char_w = cur_w - prev_w;
    if (target_x < prev_w + char_w / 2.0) {
        return boundaries[prev_idx];
    }
    return boundaries[lo];
}

pub fn measurePrefixWidthFromBoundaries(
    boundaries: []const u32,
    prefix_widths: []const f32,
    boundary_count: usize,
    local_end: u32,
) ?f32 {
    if (local_end == 0 or boundary_count == 0) return 0;

    var lo: usize = 0;
    var hi: usize = boundary_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (boundaries[mid] < local_end) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo < boundary_count and boundaries[lo] == local_end) {
        return prefix_widths[lo];
    }
    return null;
}

pub const PrefixBoundaryFloorResult = struct {
    byte_end: u32,
    width: f32,
};

pub fn floorPrefixBoundaryByWidth(
    boundaries: []const u32,
    prefix_widths: []const f32,
    boundary_count: usize,
    target_x: f32,
) PrefixBoundaryFloorResult {
    if (boundary_count == 0 or target_x <= 0) {
        return .{ .byte_end = 0, .width = 0 };
    }

    const last_idx = boundary_count - 1;
    if (target_x >= prefix_widths[last_idx]) {
        return .{
            .byte_end = boundaries[last_idx],
            .width = prefix_widths[last_idx],
        };
    }

    var lo: usize = 0;
    var hi: usize = last_idx;
    while (lo < hi) {
        const mid = lo + ((hi - lo + 1) / 2);
        if (prefix_widths[mid] <= target_x) {
            lo = mid;
        } else if (mid == 0) {
            break;
        } else {
            hi = mid - 1;
        }
    }

    return .{
        .byte_end = boundaries[lo],
        .width = prefix_widths[lo],
    };
}

fn buildInteractionPrefixCacheEntryAt(
    idx: usize,
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?usize {
    if (range_end <= range_start or range_end > content.len) return null;

    const h = &interaction_prefix_cache_headers[idx];
    h.* = .{
        .valid = false,
        .node_id = node_id,
        .content_version = content_version,
        .range_start = range_start,
        .range_end = range_end,
        .spans_hash = hashSpans(spans),
        .font_size = font_size,
        .font_weight = font_weight,
        .use_italic = use_italic,
        .use_monospace = use_monospace,
        .boundary_count = 1,
        .last_used_gen = nextInteractionCacheGen(),
    };
    const p = &interaction_prefix_cache_payloads[idx];
    const count = buildPrefixWidthsForRange(
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
        p.boundaries[0..],
        p.prefix_widths[0..],
    ) orelse return null;

    h.boundary_count = @intCast(count);
    h.valid = true;
    return idx;
}

fn getInteractionPrefixCacheIndex(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?usize {
    if (range_end <= range_start or range_end > content.len) return null;

    const spans_hash = hashSpans(spans);
    const key_hash = computeInteractionPrefixKeyHash(
        node_id,
        content_version,
        range_start,
        range_end,
        spans_hash,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
    );
    if (findInteractionPrefixCacheIndexByHash(key_hash)) |idx| return idx;
    // Failure memo: range exceeding INTERACTION_PREFIX_MAX_CHARS build must
    // fail, but failure already burned full table measure. Same key failure only
    // burns once, hit memo calls caller fallback. Key includes content_version/
    // spans/font, auto-retries after content changes.
    for (g_prefix_build_failed_ring) |fk| {
        if (fk == key_hash) return null;
    }

    const idx = allocInteractionPrefixCacheIndex();
    const built = buildInteractionPrefixCacheEntryAt(
        idx,
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse {
        g_prefix_build_failed_ring[g_prefix_build_failed_cursor] = key_hash;
        g_prefix_build_failed_cursor = (g_prefix_build_failed_cursor + 1) % g_prefix_build_failed_ring.len;
        return null;
    };
    interaction_prefix_cache_headers[idx].key_hash = key_hash;
    sidecarInsert(key_hash, @intCast(idx));
    return built;
}

pub fn hitTestPrefixWidthRangeCached(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    target_x: f32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?usize {
    if (target_x <= 0 or range_end <= range_start) return 0;

    const idx = getInteractionPrefixCacheIndex(
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse return null;

    const h = &interaction_prefix_cache_headers[idx];
    const p = &interaction_prefix_cache_payloads[idx];
    const count = @as(usize, h.boundary_count);
    return hitTestPrefixBoundaries(p.boundaries[0..count], p.prefix_widths[0..count], count, target_x);
}

pub fn measurePrefixWidthRangeCached(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    byte_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?f32 {
    if (byte_end <= range_start) return 0;
    if (range_end <= range_start) return 0;

    const idx = getInteractionPrefixCacheIndex(
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse return null;

    const h = &interaction_prefix_cache_headers[idx];
    const p = &interaction_prefix_cache_payloads[idx];
    const local_end = byte_end - range_start;
    const count = @as(usize, h.boundary_count);
    return measurePrefixWidthFromBoundaries(p.boundaries[0..count], p.prefix_widths[0..count], count, local_end);
}

pub fn floorPrefixBoundaryByWidthCached(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    target_x: f32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?PrefixBoundaryFloorResult {
    if (range_end <= range_start or target_x <= 0) {
        return .{ .byte_end = range_start, .width = 0 };
    }

    const idx = getInteractionPrefixCacheIndex(
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse return null;

    const h = &interaction_prefix_cache_headers[idx];
    const p = &interaction_prefix_cache_payloads[idx];
    const count = @as(usize, h.boundary_count);
    const result = floorPrefixBoundaryByWidth(
        p.boundaries[0..count],
        p.prefix_widths[0..count],
        count,
        target_x,
    );
    return .{
        .byte_end = range_start + result.byte_end,
        .width = result.width,
    };
}

/// Determine if CJK character (CJK unified ideographs range, breakable at
/// any position). Implementation converges on i18n.linebreak.isCJK (WrapMap
/// precise breakpoints share same check).
pub fn isCJK(codepoint: u21) bool {
    const i18n = @import("i18n");
    return i18n.linebreak.isCJK(codepoint);
}

/// Cluster-aware breakability (UAX #14, per i18n.linebreak).
pub fn isBreakableCluster(prev_cp: u32, next_cp: u32) bool {
    const i18n = @import("i18n");
    const prev_class = i18n.linebreak.classify(prev_cp);
    const next_class = i18n.linebreak.classify(next_cp);
    return i18n.linebreak.canBreakBetween(prev_class, next_class);
}

/// Get UTF-8 character byte length.
pub fn utf8CharLen(first_byte: u8) u3 {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 1; // invalid, treat as single byte
}

/// Decode UTF-8 code point.
pub fn decodeUtf8(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0;
    const b0 = bytes[0];
    if (b0 < 0x80) return b0;
    if (b0 & 0xE0 == 0xC0 and bytes.len >= 2) {
        return (@as(u21, b0 & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F);
    }
    if (b0 & 0xF0 == 0xE0 and bytes.len >= 3) {
        return (@as(u21, b0 & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | @as(u21, bytes[2] & 0x3F);
    }
    if (b0 & 0xF8 == 0xF0 and bytes.len >= 4) {
        return (@as(u21, b0 & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | @as(u21, bytes[3] & 0x3F);
    }
    return 0xFFFD; // replacement character
}

/// Compute text line-break layout.
///
/// Parameters:
/// - content: UTF-8 text
/// - available_width: available width (pixels)
/// - wrap: wrap mode
/// - max_lines: max line count (0 = unlimited)
/// - font_size: font size
/// - line_height: line height multiplier
/// - use_italic: base italic toggle
/// - spans: TextSpan array; span-covered segments are measured with span.font_weight/italic
pub fn computeTextLayout(
    content: []const u8,
    available_width: f32,
    wrap: TextWrap,
    max_lines: u16,
    font_size: f32,
    line_height: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) TextLayout {
    var layout = TextLayout{};

    if (content.len == 0 or available_width <= 0) {
        layout.line_count = 1;
        layout.lines[0] = .{ .byte_start = 0, .byte_end = 0, .width = 0 };
        layout.total_height = font_size * line_height;
        return layout;
    }

    if (wrap == .none) {
        // No wrap: single line.
        layout.line_count = 1;
        layout.lines[0] = .{
            .byte_start = 0,
            .byte_end = @intCast(content.len),
            .width = measureSpanAware(content, 0, @intCast(content.len), font_size, font_weight, use_italic, use_monospace, spans),
        };
        layout.max_line_width = layout.lines[0].width;
        layout.total_height = font_size * line_height;
        return layout;
    }

    if (wrap == .newline_only) {
        // Break only on \n, no width wrapping (code fence scenarios).
        var line_start: u32 = 0;
        var lc: u16 = 0;
        var mw: f32 = 0;
        while (line_start <= content.len and lc < MAX_LINES) {
            // Find line end (\n or EOF).
            var line_end: u32 = line_start;
            while (line_end < content.len and content[line_end] != '\n') line_end += 1;

            const w = measureSpanAware(content, line_start, line_end, font_size, font_weight, use_italic, use_monospace, spans);
            layout.lines[lc] = .{ .byte_start = line_start, .byte_end = line_end, .width = w };
            mw = @max(mw, w);
            lc += 1;

            if (line_end >= content.len) break;
            line_start = line_end + 1; // Skip \n.
        }
        if (lc == 0) {
            lc = 1;
            layout.lines[0] = .{ .byte_start = 0, .byte_end = 0, .width = 0 };
        }
        layout.line_count = lc;
        layout.max_line_width = mw;
        layout.total_height = @as(f32, @floatFromInt(lc)) * font_size * line_height;

        layout.cached_content_ptr = content.ptr;
        layout.cached_content_len = content.len;
        layout.cached_content_hash = std.hash.Wyhash.hash(0, content);
        layout.cached_available_width = available_width;
        layout.cached_font_weight = font_weight;
        layout.cached_font_size = font_size;
        layout.cached_use_italic = use_italic;
        layout.cached_use_monospace = use_monospace;
        layout.cached_wrap = wrap;
        layout.cached_max_lines = max_lines;
        layout.cached_spans_hash = hashSpans(spans);
        return layout;
    }

    const effective_max: u16 = if (max_lines == 0) MAX_LINES else @min(max_lines, MAX_LINES);

    var line_start: u32 = 0;
    var line_count: u16 = 0;
    var max_width: f32 = 0;

    while (line_start < content.len and line_count < effective_max) {
        // Find current line break point.
        const result = findLineBreak(content, line_start, available_width, wrap, font_size, font_weight, use_italic, use_monospace, spans);
        const line_end = line_start + result.byte_len;
        const line_width = result.width;

        layout.lines[line_count] = .{
            .byte_start = line_start,
            .byte_end = @intCast(line_end),
            .width = line_width,
        };
        max_width = @max(max_width, line_width);
        line_count += 1;

        line_start = @intCast(line_end);

        // Skip space after break (word wrap mode).
        if (wrap == .word or wrap == .char or wrap == .word_break or wrap == .keep_all) {
            while (line_start < content.len and content[line_start] == ' ') {
                line_start += 1;
            }
        }

        // A hard newline terminates the line we just emitted; it is not a
        // second, empty line of its own.  Leaving it for the next iteration
        // made `one\ntwo` occupy rows 0 and 2, so a three-row editor clipped
        // the third paragraph at row 4.  Consume exactly one separator here.
        // A trailing separator still creates the expected final empty line.
        if (line_start < content.len and content[line_start] == '\n') {
            line_start += 1;
            if (line_start == content.len and line_count < effective_max) {
                layout.lines[line_count] = .{
                    .byte_start = line_start,
                    .byte_end = line_start,
                    .width = 0,
                };
                line_count += 1;
            }
        }
    }

    if (line_count == 0) {
        line_count = 1;
        layout.lines[0] = .{ .byte_start = 0, .byte_end = 0, .width = 0 };
    }

    layout.line_count = line_count;
    layout.max_line_width = max_width;
    layout.total_height = @as(f32, @floatFromInt(line_count)) * font_size * line_height;

    // Cache key (ptr+len fast path + hash prevent pointer reuse false-hit).
    layout.cached_content_ptr = content.ptr;
    layout.cached_content_len = content.len;
    layout.cached_content_hash = std.hash.Wyhash.hash(0, content);
    layout.cached_available_width = available_width;
    layout.cached_font_weight = font_weight;
    layout.cached_font_size = font_size;
    layout.cached_use_italic = use_italic;
    layout.cached_use_monospace = use_monospace;
    layout.cached_wrap = wrap;
    layout.cached_max_lines = max_lines;
    layout.cached_spans_hash = hashSpans(spans);

    return layout;
}

/// Internal helper: span-aware measure (segment when spans, direct measure
/// without).
fn measureSpanAware(content: []const u8, start: u32, end: u32, font_size: f32, base_fw: u16, use_italic: bool, use_monospace: bool, spans: []const TextSpan) f32 {
    if (spans.len == 0) return measureTextWidthByFontKind(content[start..end], font_size, base_fw, use_italic, use_monospace);
    return measureTextWidthWithSpans(content, start, end, font_size, base_fw, use_italic, use_monospace, spans);
}

fn hashSpans(spans: []const TextSpan) u64 {
    if (spans.len == 0) return 0;
    const bytes = std.mem.sliceAsBytes(spans);
    return std.hash.Wyhash.hash(0, bytes);
}

const LineBreakResult = struct {
    byte_len: u32,
    width: f32,
};

/// Find line break point within given width. content: full text, line_start:
/// this line's start offset in content.
fn findLineBreak(
    content: []const u8,
    line_start: u32,
    available_width: f32,
    wrap: TextWrap,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) LineBreakResult {
    const text = content[line_start..];

    // Fast path: find this line's natural end (\n or EOF) first.
    var natural_end: u32 = 0;
    while (natural_end < text.len and text[natural_end] != '\n') natural_end += 1;
    // Measure entire line once: if line width <= available_width, return
    // directly, avoid per-character advance (drops O(N) CoreText calls to O(1)).
    if (natural_end > 0) {
        const full_width = measureSpanAware(content, line_start, line_start + natural_end, font_size, font_weight, use_italic, use_monospace, spans);
        if (full_width <= available_width) {
            return .{ .byte_len = natural_end, .width = full_width };
        }
    }

    // Chunked incremental measurement (same approach as buildPrefixWidthsForRange):
    // re-measuring the entire prefix from line_start for each grapheme is O(N^2) shaped bytes,
    // and each prefix is a unique string (measure cache always misses). First-frame layout of
    // every wrap-text node hits here.
    // Drop a checkpoint every 64 graphemes, measure only [checkpoint, next); prefix
    // width = cumulative + chunk width. Kerning lost at checkpoint boundary: CJK=0,
    // Latin subpixel (same tradeoff as buildPrefixWidthsForRange).
    var pos: u32 = 0;
    var width_so_far: f32 = 0;
    var last_break_pos: u32 = 0;
    var last_break_width: f32 = 0;
    var has_break_point = false;
    var chunk_base: u32 = 0;
    var chunk_base_w: f32 = 0;
    var since_checkpoint: usize = 0;
    var grapheme_cursor = grapheme.BoundaryCursor.init(text);

    while (pos < text.len) {
        // Hit newline, end this line here.
        if (text[pos] == '\n') {
            return .{ .byte_len = pos, .width = width_so_far };
        }

        const next_pos: u32 = @intCast(grapheme_cursor.next(pos));
        if (next_pos > text.len) break;

        const previous_width = width_so_far;
        width_so_far = chunk_base_w + measureSpanAware(
            content,
            line_start + chunk_base,
            line_start + @as(u32, @intCast(next_pos)),
            font_size,
            font_weight,
            use_italic,
            use_monospace,
            spans,
        );
        since_checkpoint += 1;
        if (since_checkpoint >= PREFIX_CHUNK_GRAPHEMES) {
            chunk_base = @intCast(next_pos);
            chunk_base_w = width_so_far;
            since_checkpoint = 0;
        }

        if (width_so_far > available_width and pos > 0) {
            // Exceed available width.
            if ((wrap == .word or wrap == .char or wrap == .word_break or wrap == .keep_all) and has_break_point) {
                // Word mode: backtrack to last break point.
                return .{ .byte_len = last_break_pos, .width = last_break_width };
            }
            // Normal/keep-all preserve an unbreakable word even when it
            // overflows the line. Emergency wrapping is an explicit option.
            if (wrap != .word and wrap != .keep_all)
                return .{ .byte_len = pos, .width = previous_width };
        }

        // Record possible break point.
        if (wrap == .word or wrap == .char or wrap == .word_break or wrap == .keep_all) {
            const cp = decodeUtf8(text[pos..@min(pos + 4, @as(u32, @intCast(text.len)))]);
            if (isCJK(cp) and wrap != .keep_all) {
                // CJK character, breakable after.
                last_break_pos = @intCast(next_pos);
                last_break_width = width_so_far;
                has_break_point = true;
            } else if (next_pos < text.len) {
                // UAX #14: is current cp and next cp breakable between.
                const next_cp_bytes = text[@intCast(next_pos)..@min(@as(usize, @intCast(next_pos)) + 4, text.len)];
                const next_cp = decodeUtf8(next_cp_bytes);
                if (isBreakableCluster(cp, next_cp) and !(wrap == .keep_all and (isCJK(cp) or isCJK(next_cp)))) {
                    last_break_pos = @intCast(next_pos);
                    last_break_width = width_so_far;
                    has_break_point = true;
                }
            }
        }

        if (width_so_far > available_width and has_break_point and (wrap == .word or wrap == .keep_all))
            return .{ .byte_len = last_break_pos, .width = last_break_width };
        pos = @intCast(next_pos);
    }

    // Didn't exceed width, whole segment on one line.
    return .{ .byte_len = pos, .width = width_so_far };
}

/// Check cache validity. Use ptr+len fast path + hash verify prevent
/// pointer reuse false-hit. Width uses 0.5px epsilon compare, avoid float
/// precision invalid recomputation.
pub fn isCacheValid(layout: *const TextLayout, content: []const u8, available_width: f32, font_weight: u16, font_size: f32, use_italic: bool, use_monospace: bool, wrap: TextWrap, max_lines: u16, spans: []const TextSpan) bool {
    if (layout.line_count == 0) return false;
    if (layout.cached_content_len != content.len) return false;
    if (@abs(layout.cached_available_width - available_width) > 0.5) return false;
    if (layout.cached_font_weight != font_weight) return false;
    if (layout.cached_font_size != font_size) return false;
    if (layout.cached_use_italic != use_italic) return false;
    if (layout.cached_use_monospace != use_monospace) return false;
    if (layout.cached_wrap != wrap) return false;
    if (layout.cached_max_lines != max_lines) return false;
    if (layout.cached_spans_hash != hashSpans(spans)) return false;

    // Fast path: ptr same and hash match.
    if (layout.cached_content_ptr == content.ptr) return true;

    // Slow path: ptr different but content possibly same (memory reallocated).
    return layout.cached_content_hash == std.hash.Wyhash.hash(0, content);
}

test "interaction prefix cache matches direct prefix measurement" {
    const content = "hello world";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};

    const direct = measureTextWidthWithSpans(content, 0, 5, font_size, font_weight, use_italic, false, spans);
    const cached = measurePrefixWidthRangeCached(101, 1, content, 0, @intCast(content.len), 5, font_size, font_weight, use_italic, false, spans);

    try std.testing.expect(cached != null);
    try std.testing.expectApproxEqAbs(direct, cached.?, 0.001);
}

test "build prefix widths supports direct hit testing without cache" {
    const content = "hello world";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    var boundaries: [INTERACTION_PREFIX_MAX_CHARS + 1]u32 = undefined;
    var prefix_widths: [INTERACTION_PREFIX_MAX_CHARS + 1]f32 = undefined;

    const count = buildPrefixWidthsForRange(
        content,
        0,
        @intCast(content.len),
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
        boundaries[0..],
        prefix_widths[0..],
    );

    try std.testing.expect(count != null);
    try std.testing.expectApproxEqAbs(
        measureTextWidthWithSpans(content, 0, 5, font_size, font_weight, use_italic, false, spans),
        measurePrefixWidthFromBoundaries(boundaries[0..count.?], prefix_widths[0..count.?], count.?, 5).?,
        0.001,
    );
    try std.testing.expectEqual(@as(usize, 2), hitTestPrefixBoundaries(boundaries[0..count.?], prefix_widths[0..count.?], count.?, prefix_widths[2] - 0.01));
}

test "interaction prefix cache hit test matches expected boundary" {
    const content = "hello";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    const char_w = measureProportional("h", font_size, font_weight, use_italic);

    const left_half = hitTestPrefixWidthRangeCached(
        202,
        1,
        content,
        0,
        @intCast(content.len),
        char_w * 2.4,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );
    const right_half = hitTestPrefixWidthRangeCached(
        202,
        1,
        content,
        0,
        @intCast(content.len),
        char_w * 2.6,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );

    try std.testing.expectEqual(@as(?usize, 2), left_half);
    try std.testing.expectEqual(@as(?usize, 3), right_half);
}

test "interaction prefix cache invalidates on content change" {
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};

    const first = measurePrefixWidthRangeCached(303, 1, "abc", 0, 3, 3, font_size, font_weight, use_italic, false, spans);
    const second = measurePrefixWidthRangeCached(303, 2, "abcdef", 0, 6, 6, font_size, font_weight, use_italic, false, spans);

    try std.testing.expect(first != null);
    try std.testing.expect(second != null);
    try std.testing.expect(second.? > first.?);
}

test "interaction prefix cache can floor prefix boundary by width" {
    const content = "hello world";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    const target_boundary: u32 = 5;
    const target_w = measureTextWidthWithSpans(content, 0, target_boundary, font_size, font_weight, use_italic, false, spans);

    const exact = floorPrefixBoundaryByWidthCached(
        404,
        1,
        content,
        0,
        @intCast(content.len),
        target_w,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );
    const just_before = floorPrefixBoundaryByWidthCached(
        404,
        1,
        content,
        0,
        @intCast(content.len),
        target_w - 0.01,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );

    try std.testing.expect(exact != null);
    try std.testing.expectEqual(target_boundary, exact.?.byte_end);
    try std.testing.expectApproxEqAbs(target_w, exact.?.width, 0.001);
    try std.testing.expect(just_before != null);
    try std.testing.expect(just_before.?.byte_end < target_boundary);
    try std.testing.expect(just_before.?.width < target_w);
}

test "word wrap consumes each hard newline exactly once" {
    const layout = computeTextLayout(
        "one\ntwo\nthree",
        1000,
        .word,
        0,
        14,
        1.25,
        400,
        false,
        false,
        &.{},
    );

    try std.testing.expectEqual(@as(u16, 3), layout.line_count);
    try std.testing.expectEqual(@as(u32, 0), layout.lines[0].byte_start);
    try std.testing.expectEqual(@as(u32, 3), layout.lines[0].byte_end);
    try std.testing.expectEqual(@as(u32, 4), layout.lines[1].byte_start);
    try std.testing.expectEqual(@as(u32, 7), layout.lines[1].byte_end);
    try std.testing.expectEqual(@as(u32, 8), layout.lines[2].byte_start);
    try std.testing.expectEqual(@as(u32, 13), layout.lines[2].byte_end);
}

test "word wrap preserves intentional empty and trailing hard-newline rows" {
    const middle_empty = computeTextLayout("a\n\nb", 1000, .word, 0, 14, 1.25, 400, false, false, &.{});
    try std.testing.expectEqual(@as(u16, 3), middle_empty.line_count);
    try std.testing.expectEqual(middle_empty.lines[1].byte_start, middle_empty.lines[1].byte_end);

    const trailing_empty = computeTextLayout("a\n", 1000, .word, 0, 14, 1.25, 400, false, false, &.{});
    try std.testing.expectEqual(@as(u16, 2), trailing_empty.line_count);
    try std.testing.expectEqual(@as(u32, 2), trailing_empty.lines[1].byte_start);
    try std.testing.expectEqual(@as(u32, 2), trailing_empty.lines[1].byte_end);
}

test "findLineBreak preserves word wrap boundary with incremental width accumulation" {
    const content = "abc def";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    const break_width = measureTextWidthWithSpans(content, 0, 4, font_size, font_weight, use_italic, false, spans);

    const result = findLineBreak(
        content,
        0,
        break_width + 0.01,
        .word,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );

    try std.testing.expectEqual(@as(u32, 4), result.byte_len);
    try std.testing.expectApproxEqAbs(break_width, result.width, 0.001);
}

test "findLineBreak never splits an extended grapheme cluster" {
    const content = "A👩‍💻B";
    const after_a: u32 = 1;
    const after_emoji: u32 = @intCast(grapheme.nextBoundary(content, after_a));
    const width_a = measureTextWidthWithSpans(content, 0, after_a, 10, 400, false, false, &.{});
    const width_through_emoji = measureTextWidthWithSpans(content, 0, after_emoji, 10, 400, false, false, &.{});
    const result = findLineBreak(content, 0, (width_a + width_through_emoji) * 0.5, .char, 10, 400, false, false, &.{});
    try std.testing.expectEqual(after_a, result.byte_len);
    try std.testing.expect(grapheme.nextBoundary(content, grapheme.prevBoundary(content, result.byte_len)) == result.byte_len);
}

test "measureTextWidthWithSpans respects base monospace across gaps and spans" {
    const Helpers = struct {
        fn proportionalMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size * 0.5;
        }
        fn monospaceMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size;
        }
    };

    setMeasureFn(Helpers.proportionalMeasure);
    defer setMeasureFn(null);
    setMonospaceMeasureFn(Helpers.monospaceMeasure);
    defer setMonospaceMeasureFn(null);

    const content = "ab";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const spans: []const TextSpan = &.{
        .{
            .start = 1,
            .end = 2,
            .color = types.Color.rgba(255, 0, 0, 255),
        },
    };

    const measured = measureTextWidthWithSpans(content, 0, 2, font_size, font_weight, false, true, spans);
    try std.testing.expectApproxEqAbs(@as(f32, 20), measured, 0.001);
}

test "monospace measurement handles CJK fallback correctly" {
    // Simulate true monospace measure: ASCII 1 byte = font_size, CJK 3 bytes
    // = 2 * font_size. This is typical Menlo + PingFang fallback: CJK takes
    // two cells.
    const Helpers = struct {
        fn monospaceMeasure(text_ptr: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            const slice = text_ptr[0..text_len];
            var width: f32 = 0;
            var i: usize = 0;
            while (i < slice.len) {
                const b = slice[i];
                if (b < 0x80) {
                    width += font_size;
                    i += 1;
                } else {
                    // UTF-8 multibyte, simulate CJK takes two cells.
                    const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                    width += font_size * 2;
                    i += cp_len;
                }
            }
            return width;
        }
    };

    setMonospaceMeasureFn(Helpers.monospaceMeasure);
    defer setMonospaceMeasureFn(null);

    const font_size: f32 = 10;
    const font_weight: u16 = 400;

    // Pure ASCII, should = len * font_size.
    const ascii_only = measureMonospaceTextWidth("hello", font_size, font_weight, false);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ascii_only, 0.001);

    // Pure CJK 3 chars = 9 bytes, should = 3 * 2 * font_size = 60.
    const cjk_only = measureMonospaceTextWidth("你好啊", font_size, font_weight, false);
    try std.testing.expectApproxEqAbs(@as(f32, 60), cjk_only, 0.001);

    // Mixed: 5 ASCII + 2 CJK = 5 * 10 + 2 * 20 = 90.
    const mixed = measureMonospaceTextWidth("hello你好", font_size, font_weight, false);
    try std.testing.expectApproxEqAbs(@as(f32, 90), mixed, 0.001);

    // Critical: string with CJK must never walk ASCII fast path (fast path
    // calculates 8 bytes as 8 * font_size = 80, less than correct 90 by 10).
    try std.testing.expect(mixed != 80);
}

// Metrics #8, shape cache > 95%.
test "measure cache produces > 95% hit rate on repeated text" {
    const Helpers = struct {
        fn fakeMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size * 0.6;
        }
    };
    setMeasureFn(Helpers.fakeMeasure);
    defer setMeasureFn(null);

    invalidateMeasureCache();
    resetMeasureCacheStats();

    // Simulate list scenario: 100 rows same text each measure once (cache miss
    // 1st, hit 99 times after).
    const sample_text = "Hello World";
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        _ = measureProportional(sample_text, 14, 400, false);
    }

    const stats = measureCacheStats();
    try std.testing.expect(stats.hits >= 99);
    try std.testing.expect(stats.hitRate() > 0.95);
}

test "interaction prefix cache distinguishes monospace base font" {
    const Helpers = struct {
        fn proportionalMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size * 0.5;
        }
        fn monospaceMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size;
        }
    };

    setMeasureFn(Helpers.proportionalMeasure);
    defer setMeasureFn(null);
    setMonospaceMeasureFn(Helpers.monospaceMeasure);
    defer setMonospaceMeasureFn(null);

    const content = "abc";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const spans: []const TextSpan = &.{};

    const proportional = measurePrefixWidthRangeCached(505, 1, content, 0, @intCast(content.len), 3, font_size, font_weight, false, false, spans);
    const monospace = measurePrefixWidthRangeCached(505, 1, content, 0, @intCast(content.len), 3, font_size, font_weight, false, true, spans);

    try std.testing.expect(proportional != null);
    try std.testing.expect(monospace != null);
    try std.testing.expectApproxEqAbs(@as(f32, 15), proportional.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), monospace.?, 0.001);
}

test "measureTextWidthWithSpans includes inline box horizontal padding" {
    const content = "code";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{
        .{
            .start = 0,
            .end = 4,
            .use_monospace_font = true,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .inline_box_padding_left = 4,
            .inline_box_padding_right = 4,
            .inline_box_inset_top = 1,
            .inline_box_inset_bottom = 1,
            .inline_box_corner_radius = 3,
        },
    };

    const text_only = measureMonospaceTextWidth(content, font_size, font_weight, use_italic);
    const measured = measureTextWidthWithSpans(content, 0, 4, font_size, font_weight, use_italic, false, spans);

    try std.testing.expectApproxEqAbs(text_only + 8, measured, 0.001);
}

test "inline box prefix widths include leading and trailing padding exactly once" {
    const content = "code";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{
        .{
            .start = 0,
            .end = 4,
            .use_monospace_font = true,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .inline_box_padding_left = 4,
            .inline_box_padding_right = 4,
            .inline_box_inset_top = 1,
            .inline_box_inset_bottom = 1,
            .inline_box_corner_radius = 3,
        },
    };
    var boundaries: [INTERACTION_PREFIX_MAX_CHARS + 1]u32 = undefined;
    var prefix_widths: [INTERACTION_PREFIX_MAX_CHARS + 1]f32 = undefined;

    const count = buildPrefixWidthsForRange(
        content,
        0,
        @intCast(content.len),
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
        boundaries[0..],
        prefix_widths[0..],
    ) orelse return error.TestUnexpectedResult;

    const first_char = measureMonospaceTextWidth("c", font_size, font_weight, use_italic);
    const full_text = measureMonospaceTextWidth(content, font_size, font_weight, use_italic);

    try std.testing.expectApproxEqAbs(first_char + 4, prefix_widths[1], 0.001);
    try std.testing.expectApproxEqAbs(full_text + 8, prefix_widths[count - 1], 0.001);
    try std.testing.expectEqual(@as(usize, 0), hitTestPrefixBoundaries(boundaries[0..count], prefix_widths[0..count], count, 1.0));
}

// v0.5 §5 GlyphRun-B test uses mock callback.
const TestShapeContext = struct {
    var call_count: u32 = 0;
    var last_text: []const u8 = "";
    var return_value: f32 = 0;
};

fn testShapeMeasureMock(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    _ = font_size;
    _ = font_weight;
    _ = use_italic;
    _ = use_monospace;
    TestShapeContext.call_count += 1;
    TestShapeContext.last_text = text;
    return TestShapeContext.return_value;
}

test "shape measure callback intercepts measureProportional when set" {
    invalidateMeasureCache();
    TestShapeContext.call_count = 0;
    TestShapeContext.return_value = 42.0;
    setShapeMeasureFn(&testShapeMeasureMock);
    defer setShapeMeasureFn(null);

    const w = measureProportional("hello", 14.0, 400, false);
    try std.testing.expectApproxEqAbs(@as(f32, 42), w, 0.001);
    try std.testing.expectEqual(@as(u32, 1), TestShapeContext.call_count);
    try std.testing.expectEqualStrings("hello", TestShapeContext.last_text);
}

test "shape measure callback NaN return falls back to platform measure" {
    invalidateMeasureCache();
    TestShapeContext.call_count = 0;
    TestShapeContext.return_value = std.math.nan(f32);
    setShapeMeasureFn(&testShapeMeasureMock);
    defer setShapeMeasureFn(null);

    const w = measureProportional("test", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 1), TestShapeContext.call_count);
    // NaN fallback -> platform measure, result > 0 (fallback estimate 4 * 14 * 0.6 = 33.6).
    try std.testing.expect(w > 0);
    try std.testing.expect(!std.math.isNan(w));
}

test "monospace measure also routes through shape callback" {
    invalidateMeasureCache();
    TestShapeContext.call_count = 0;
    TestShapeContext.return_value = 99.0;
    setShapeMeasureFn(&testShapeMeasureMock);
    defer setShapeMeasureFn(null);

    const w = measureMonospaceTextWidth("x", 14.0, 400, false);
    try std.testing.expectApproxEqAbs(@as(f32, 99), w, 0.001);
    try std.testing.expectEqual(@as(u32, 1), TestShapeContext.call_count);
}

// -- Line break result must be scale-independent --
//
// Scale is pure geometry: a whole proportional shrink must not change which character
// wraps. Hosts with a 6px font-size floor break if the wrap width still shrinks per scale:
// the ratio changes and text rewraps on shrink, even overflows. This locks the **formula
// invariant**: as long as `available width / font_size` is constant, the break point is
// constant. Host syncObjectLabel uses the same eff to convert width and size, satisfying
// that precondition.

/// Replicate host's "effective geometry scale": font size hits floor, layout
/// geometry stops at same tier.
fn hostEffectiveScale(world_font: f32, scale: f32, min_font_px: f32) f32 {
    if (!(world_font > 0)) return scale;
    return @max(scale, min_font_px / world_font);
}

test "text wrap is invariant under view scale (downstream zoom regression)" {
    const min_font_px: f32 = 6.0;
    const world_font: f32 = 16.0;
    const line_height: f32 = 1.25;

    const Case = struct {
        name: []const u8,
        content: []const u8,
        world_w: f32,
        inset_world: f32,
    };
    // User-reported two real objects.
    const cases = [_]Case{
        .{ .name = "textbox", .content = "asdfsdfasdfasdf asdfsdf", .world_w = 240, .inset_world = 4 },
        .{ .name = "sticky", .content = "杠杆顶起 asdfsd塔顶", .world_w = 180, .inset_world = 10 },
    };
    const scales = [_]f32{ 1.0, 0.75, 0.5, 0.375, 0.25, 0.12, 0.10, 0.05, 0.02 };

    for (cases) |c| {
        // Baseline: scale = 1 (world coordinates true break points).
        const base = computeTextLayout(
            c.content,
            (c.world_w - c.inset_world * 2),
            .word,
            0,
            world_font,
            line_height,
            400,
            false,
            false,
            &.{},
        );
        try std.testing.expect(base.line_count >= 1);

        for (scales) |s| {
            const eff = hostEffectiveScale(world_font, s, min_font_px);
            const font_px = world_font * eff;
            const avail = (c.world_w - c.inset_world * 2) * eff;

            const got = computeTextLayout(
                c.content,
                avail,
                .word,
                0,
                font_px,
                line_height,
                400,
                false,
                false,
                &.{},
            );

            // 1) Line count independent of scale.
            if (got.line_count != base.line_count) {
                std.debug.print(
                    "[{s}] scale={d}: line_count {d} != base {d} (font_px={d:.2} avail={d:.2})\n",
                    .{ c.name, s, got.line_count, base.line_count, font_px, avail },
                );
                return error.LineCountChangedWithScale;
            }
            // 2) Break point (byte offset) independent of scale.
            var i: u16 = 0;
            while (i < base.line_count) : (i += 1) {
                if (got.lines[i].byte_start != base.lines[i].byte_start or
                    got.lines[i].byte_end != base.lines[i].byte_end)
                {
                    std.debug.print(
                        "[{s}] scale={d} line {d}: [{d}:{d}] != base [{d}:{d}]\n",
                        .{ c.name, s, i, got.lines[i].byte_start, got.lines[i].byte_end, base.lines[i].byte_start, base.lines[i].byte_end },
                    );
                    return error.WrapPositionChangedWithScale;
                }
            }
            // 3) Each tier must have "visible text expression": complete text (font
            // size large enough) or pixel strip (host draws per LineInfo.width). Both
            // require this tier measures non-empty line geometry, can't have any tier
            // with nothing.
            try std.testing.expect(got.line_count > 0);
            try std.testing.expect(got.max_line_width > 0);
        }
    }
}

// Multiwindow measure cache coexistence test fake callback: return
// different widths per ctx, verify two ctx entries coexist yet don't
// cross-contaminate.
const TestCtxMeasure = struct {
    var calls: u32 = 0;
    var ctx_a: u8 = 0;
    var ctx_b: u8 = 0;

    fn measure(ctx: *anyopaque, text: [*]const u8, len: usize, size: f32, weight: u16, italic: bool) f32 {
        _ = text;
        _ = size;
        _ = weight;
        _ = italic;
        calls += 1;
        // ctx_a records 10/char, ctx_b records 20/char.
        const is_a = ctx == @as(*anyopaque, @ptrCast(&ctx_a));
        return @as(f32, @floatFromInt(len)) * (if (is_a) @as(f32, 10) else @as(f32, 20));
    }
};

test "切换 measure ctx 不清空缓存，且两个 ctx 的条目互不串味" {
    invalidateMeasureCache();
    TestCtxMeasure.calls = 0;

    const a: *anyopaque = @ptrCast(&TestCtxMeasure.ctx_a);
    const b: *anyopaque = @ptrCast(&TestCtxMeasure.ctx_b);
    defer setMeasureCtxFn(null, null);

    // Window A measure once, miss, real call.
    setMeasureCtxFn(&TestCtxMeasure.measure, a);
    const wa1 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 1), TestCtxMeasure.calls);
    try std.testing.expectEqual(@as(f32, 40), wa1);

    // Switch to window B measure same string, must miss (can't reuse A's
    // width), real call.
    setMeasureCtxFn(&TestCtxMeasure.measure, b);
    const wb1 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 2), TestCtxMeasure.calls);
    try std.testing.expectEqual(@as(f32, 80), wb1);

    // Switch back A, A's entry must still exist (this is the fix: before
    // switching ctx would clear whole table).
    setMeasureCtxFn(&TestCtxMeasure.measure, a);
    const wa2 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 2), TestCtxMeasure.calls); // No new real call = hit.
    try std.testing.expectEqual(@as(f32, 40), wa2);

    // Switch back to B, should also hit.
    setMeasureCtxFn(&TestCtxMeasure.measure, b);
    const wb2 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 2), TestCtxMeasure.calls);
    try std.testing.expectEqual(@as(f32, 80), wb2);
}
