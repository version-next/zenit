const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const id_hash = @import("id_hash.zig");

const types = @import("types.zig");
const node_mod = @import("node.zig");
const text_layout = @import("text_layout.zig");
// GlyphRun pipeline support
const shaping_cache_mod = @import("shaping_cache.zig");
const text_module = @import("text");
const text_shaper_adapter = @import("text_shaper_adapter.zig");
const glyph_run_mod = @import("glyph_run.zig");

const Node = node_mod.Node;
const Size = types.Size;
const Sizing = types.Sizing;
const AlignItems = types.AlignItems;

/// Bound recursive measure/layout walks before application-provided tree depth
/// can exhaust the native stack. Nodes beyond the limit remain dirty and can
/// be diagnosed through `layout_depth_limit_hits` instead of crashing.
pub const max_layout_recursion_depth: usize = 128;
pub var layout_depth_limit_hits: u64 = 0;
/// Independent budget: min-content probes must not consume the active layout
/// walk's depth or silently truncate an otherwise shallow layout.
pub var min_content_depth_limit_hits: u64 = 0;
var g_min_content_recursion_depth: usize = 0;

/// Number of frame_allocator allocation failures during layout.
///
/// The wide-child slow paths (FlexItem scratch for flex, placements for grid) degrade on
/// allocation failure instead of crashing, like `layout_depth_limit_hits`. Degrading yields
/// **degraded layout** (clamped bases without flex redistribution; grid not laid out), so this counter
/// makes OOM distinguishable from a layout bug.
pub var layout_alloc_failure_hits: u64 = 0;
var g_layout_recursion_depth: usize = 0;
// Deterministic work counters for incremental/baseline regressions only.
var test_layout_calls: usize = 0;
var test_flex_item_probes: usize = 0;

/// display: none—node and subtree don't participate in layout (no space, gap excluded, no parent
/// expansion).
pub inline fn isDisplayNone(n: *const Node) bool {
    return n.style.display == .none;
}

/// Children that do not take part in flex / grid flow layout: absolute (positioned separately) or
/// display:none.
/// Every layout-engine traversal that skips non-flow children uses this single predicate.
pub inline fn isOutOfFlow(n: *const Node) bool {
    return n.style.position == .absolute or isDisplayNone(n);
}

/// Layout finalization for a display:none subtree: own size is zeroed (position is kept;
/// computeChildrenBBox / hit-test pruning exclude it since w/h = 0) and the layout dirty bits of
/// the whole subtree are cleared. Otherwise the hidden subtree stays dirty every frame and idle
/// frame-gating always sees pending layout work. onMount still fires: the node is still in the
/// tree (unlike unmount), just not displayed.
fn collapseDisplayNone(node: *Node) void {
    const r = node.rectFromWorldOrFallback();
    if (r.w != 0 or r.h != 0) node.setLayoutRect(types.ComputedRect.init(r.x, r.y, 0, 0));
    settleHiddenSubtree(node, 0);
}

/// Recursion (depth limit, not width; wide subtrees won't miss dirty-bit clearing).
fn settleHiddenSubtree(n: *Node, depth: usize) void {
    n.frame_state.state_bits.dirty.core.layout = false;
    n.frame_state.state_bits.dirty.core.subtree_layout = false;
    n.frame_state.frame_local.runtime.layout_mount_pending = !n.frame_state.state_bits.flags.is_mounted;
    if (!suppress_layout_mounts) node_mod.fireMountIfNeeded(n);
    if (depth >= max_layout_recursion_depth) return;
    for (n.children.items) |c| {
        settleHiddenSubtree(c, depth + 1);
        n.frame_state.frame_local.runtime.layout_mount_pending = n.frame_state.frame_local.runtime.layout_mount_pending or c.frame_state.frame_local.runtime.layout_mount_pending;
    }
}

fn enterLayoutRecursion() bool {
    if (g_layout_recursion_depth >= max_layout_recursion_depth) {
        layout_depth_limit_hits +|= 1;
        return false;
    }
    g_layout_recursion_depth += 1;
    return true;
}

fn leaveLayoutRecursion() void {
    std.debug.assert(g_layout_recursion_depth > 0);
    g_layout_recursion_depth -= 1;
}

fn releaseShapedFallbackFontRefs(glyphs: []const text_module.ShapedGlyph) void {
    for (glyphs) |glyph| {
        if (glyph.fallback_font_ref) |font_ref| {
            text_module.releaseFallbackFontRef(font_ref);
        }
    }
}

// IntrinsicCache: reuses the intrinsic measurement for the same node and the same
// (axis, content_version) across calcIntrinsicSize calls.
// Keyed by a (node.id, axis) -> value hashmap, invalidated by node.caches.versions.content.
//
// Uses a static variable under the single-threaded model (guaranteed by owner.assertThread);
// move next to LayoutTable when Node is split.
const IntrinsicCacheEntry = struct {
    value: f32,
    /// content_version at write time; hit requires current version match
    content_version: u32,
};

const IntrinsicKind = enum(u1) { max_content, min_content };

var g_intrinsic_cache: std.AutoHashMapUnmanaged(u64, IntrinsicCacheEntry) = .{};
var g_intrinsic_cache_refcount: u32 = 0;
var g_intrinsic_cache_allocator: Allocator = undefined;
/// Node ids are never reused, so every destroyed node leaves tombstones behind.
var g_intrinsic_cache_removals: id_hash.TombstoneBudget = .{};

/// A destroyed node can never hit this memo again; remove both axes and kinds.
pub fn forgetIntrinsicCache(world_id: u16, node_id: u32) void {
    if (g_intrinsic_cache_refcount == 0) return;
    inline for (.{ IntrinsicKind.max_content, IntrinsicKind.min_content }) |kind| {
        inline for (.{ false, true }) |is_main_row| {
            if (g_intrinsic_cache.remove(intrinsicCacheKey(world_id, node_id, is_main_row, kind)) and
                g_intrinsic_cache_removals.noteRemoval(g_intrinsic_cache.count(), g_intrinsic_cache.capacity()))
                g_intrinsic_cache.rehash(std.hash_map.AutoContext(u64){});
        }
    }
}

pub fn intrinsicCacheMemoryStats() struct { entries: usize, capacity: usize, slot_bytes: usize } {
    return .{ .entries = g_intrinsic_cache.count(), .capacity = g_intrinsic_cache.capacity(), .slot_bytes = g_intrinsic_cache.capacity() * (@sizeOf(u64) + @sizeOf(IntrinsicCacheEntry) + 1) };
}

fn intrinsicCacheKey(world_id: u16, node_id: u32, is_main_row: bool, kind: IntrinsicKind) u64 {
    // The key must include world_id: this table is process-wide, while node.id is a per-Cx counter
    // and ids of two windows fully overlap. Without world_id, a node in window B would hit the
    // intrinsic size of the same-id node in window A (content_version is also a small per-node
    // counter and easily equal), mixing up layouts.
    return (@as(u64, world_id) << 34) | (@as(u64, node_id) << 2) |
        (@as(u64, @backingInt(kind)) << 1) | (if (is_main_row) @as(u64, 1) else 0);
}

fn intrinsicCacheLookup(node: *const Node, is_main_row: bool, kind: IntrinsicKind) ?f32 {
    if (g_intrinsic_cache_refcount == 0) return null;
    const key = intrinsicCacheKey(node.world_id, node.id, is_main_row, kind);
    if (g_intrinsic_cache.get(key)) |entry| {
        if (entry.content_version == node.meta.per_frame.caches.versions.content) {
            return entry.value;
        }
    }
    return null;
}

fn intrinsicCacheStore(node: *const Node, is_main_row: bool, kind: IntrinsicKind, value: f32) void {
    if (g_intrinsic_cache_refcount == 0) return;
    const key = intrinsicCacheKey(node.world_id, node.id, is_main_row, kind);
    // Safe degradation: this is a pure memoization cache. A failed write only means re-measuring
    // next time with an identical result (intrinsicCacheStore has no side effects).
    g_intrinsic_cache.put(g_intrinsic_cache_allocator, key, .{
        .value = value,
        .content_version = node.meta.per_frame.caches.versions.content,
    }) catch {};
}

/// Enable intrinsic cache (refcounted, safe for nested multi-Cx). The first Cx.init allocates and
/// sets up; later Cx.init only does refcount++.
///
/// Known edge: the allocator is bound to the **first** Cx. If two Cx use different allocators and
/// the first-init Cx deinits first (refcount 1 -> no release), later puts still use the first
/// allocator; if it is destroyed => UAF. Not triggered when all Cx share one GPA; multiple App
/// each holding its own allocator need per-Cx table migration.
pub fn enableIntrinsicCache(allocator: Allocator) void {
    if (g_intrinsic_cache_refcount == 0) {
        g_intrinsic_cache_allocator = allocator;
        g_intrinsic_cache = .{};
        g_intrinsic_cache_removals.reset();
    }
    g_intrinsic_cache_refcount += 1;
}

/// Disable cache (refcount--; last Cx.deinit releases).
pub fn disableIntrinsicCache() void {
    if (g_intrinsic_cache_refcount == 0) return;
    g_intrinsic_cache_refcount -= 1;
    if (g_intrinsic_cache_refcount == 0) {
        g_intrinsic_cache.deinit(g_intrinsic_cache_allocator);
        g_intrinsic_cache = .{};
    }
}

/// Layout context, pass frame allocator to all layout functions.
/// frame_allocator auto-clears at frame end, replaces fixed-size arrays on stack.
pub const LayoutContext = struct {
    frame_allocator: Allocator,
    /// Let layout pass measureIntrinsicTextWidth use GlyphRun pipeline, replaces
    /// direct measureTextWidthWithSpans. null -> downgrade to old path (compat with
    /// existing layoutNode test fixtures).
    shaping_cache: ?*shaping_cache_mod.ShapingCache = null,
    font_system: ?*text_module.FontSystem = null,
    /// Parent flex allocation pinned this node on one axis: its own
    /// layoutChildren fit backfill end must not re-fit this axis per child actual size,
    /// else shrink gets propped back to content height, ScrollArea never scrolls.
    /// Only matches == this node, grandchild sees mismatch.
    frozen_node: ?*const Node = null,
    frozen_axis_is_width: bool = false,
    frozen_both_axes: bool = false,
    /// Wrap probes and scratch-OOM degradation defer onMount until final layout.
    defer_mount: bool = false,
    initial_containing_block: ?Size = null,
};

/// Fast count Unicode chars (not bytes) in UTF-8 string.
/// For text intrinsic estimate.
fn countUtf8Chars(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        // UTF-8 continuation bytes start 0b10xxxxxx, count heads only
        if (bytes[i] & 0xC0 != 0x80) count += 1;
        i += 1;
    }
    return count;
}

/// Merge sizing's built-in min/max with node ext.min_X / ext.max_X into the effective (min,max)
/// for this axis.
///
/// Why: `style.height = .fit{.max=N}` and `ext.max_height` are two clamp paths; row layout/grid
/// use `style.max_height()` (=ext), fit intrinsic uses `fit.max`. Middleware (e.g. popover
/// autosize) updating only one leaves the other stale (small popup bursting oversized).
///
///   effective_min = max(sizing_mm.min, ext.min)
///   effective_max = min(sizing_mm.max, ext.max)
///
/// Auto minimum markers normalize to zero here; the flex main resolver applies
/// the content-based automatic minimum separately.
pub fn effectiveMinMax(sizing: Sizing, node: *const Node, comptime is_width: bool) struct { min: f32, max: f32 } {
    const floor = if (is_width) node.style.contentInsets().horizontal() else node.style.contentInsets().vertical();
    const ext_min: f32 = if (is_width) node.style.min_width() else node.style.min_height();
    const ext_max: f32 = if (is_width) node.style.max_width() else node.style.max_height();
    const result: struct { min: f32, max: f32 } = switch (sizing) {
        .grow => |mm| .{ .min = @max(mm.min, ext_min), .max = @min(mm.max, ext_max) },
        .fit => |mm| .{ .min = @max(mm.min, ext_min), .max = @min(mm.max, ext_max) },
        // px / percent -> ext clamp (layout later reclamped by ext, no repeat here)
        else => .{ .min = ext_min, .max = ext_max },
    };
    // CSS Sizing: min wins over a conflicting max, including intrinsic probes.
    return .{ .min = @max(floor, result.min), .max = @max(floor, @max(result.min, result.max)) };
}

/// resolveSize for known child sizing + container available space -> child
/// actual size. **Not** effective_min_max, caller holding child node uses
/// helper above directly.
fn resolveSize(sizing: Sizing, available: f32, intrinsic: f32) f32 {
    return switch (sizing) {
        .px => |v| v,
        .grow => |mm| @max(@max(0, mm.min), @min(available, mm.max)),
        .fit => |mm| @max(@max(0, mm.min), @min(intrinsic, mm.max)),
        .percent => |p| available * p / 100.0,
    };
}

fn measureIntrinsicTextWidth(t: types.TextProps) f32 {
    // layout pass entry (layoutNode) sets thread-local
    // g_active_shaping_cache / g_active_font_system; this measureIntrinsicTextWidth
    // calc-chain has no ctx param, uses globals instead. layoutNode exit clears back.
    return measureIntrinsicTextWidthCtx(g_active_shaping_cache, g_active_font_system, t);
}

var g_active_shaping_cache: ?*shaping_cache_mod.ShapingCache = null;
var g_active_font_system: ?*text_module.FontSystem = null;

/// GlyphRun pipeline font-resolver hook.
///
/// == Why not just FontSystem.findFont(family='system') ==
/// findFont queries installed system fonts **by name**. An App using `loadFont(path)` (Inter /
/// Lora / JetBrains Mono shipped with the repo) has fonts that exist nowhere in the system
/// library; the by-name query misses and silently falls back to another family, so shaping and
/// renderer use two fonts and the same text gets two widths.
/// `setDefaultFamily('Inter')` does not fix this: it only replaces 'system' with 'Inter' in the
/// system query, which still misses when Inter is not installed.
///
/// So the App hands back **its own FontSelector-picked `*Font`**, running the same picker logic,
/// guaranteeing 'measured and drawn use the same Font object'. The returned Font is owned by the
/// App; the pipeline borrows and never releases it (opposite of findFont, see the owned branch in
/// shapeViaPipeline). `content` must be passed: render-side CJK/Korean fallback is picked by
/// content, so a parser ignoring the bytes can never match render (see
/// FontSelector.resolveFonts).
pub const ShapeFontResolveFn = *const fn (
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    /// Font family id (render.FontRegistry). 0 = default family.
    /// Part of 'measured and drawn use the same font': render-side resolveFonts picks the face by
    /// family; if measure omits it, it falls to the default family and custom-font text
    /// cursor/selection are systematically offset.
    font_family: u16,
) ?*text_module.Font;

/// Application-owned authoritative width measurement. A renderer may segment
/// text, select fallback-stack fonts, or force a monospace cell advance after
/// shaping; resolving the same `*Font` is therefore necessary but not always
/// sufficient to reproduce the width that is actually drawn. Hosts should
/// wire this to the renderer's non-emitting draw path.
pub const DrawnTextMeasureFn = *const fn (
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32;

var g_shape_font_resolver: ?ShapeFontResolveFn = null;
var g_shape_font_resolver_ctx: ?*anyopaque = null;
var g_drawn_text_measure: ?DrawnTextMeasureFn = null;
var g_drawn_text_measure_ctx: ?*anyopaque = null;
var drawn_text_measure_debug_logged = false;
var g_context_font_owner: ?*anyopaque = null;
pub const TextLineMetrics = struct { ascent: f32, descent: f32 };
pub const TextLineMetricsFn = *const fn (*anyopaque, *const types.TextProps) ?TextLineMetrics;
var g_context_line_metrics: ?TextLineMetricsFn = null;
var g_context_line_metrics_ctx: ?*anyopaque = null;

/// Load once app startup; pass null unload (revert to findFont old path).
pub fn setShapeFontResolver(f: ?ShapeFontResolveFn, ctx: ?*anyopaque) void {
    g_context_font_owner = null;
    g_context_line_metrics = null;
    g_context_line_metrics_ctx = null;
    g_shape_font_resolver = f;
    g_shape_font_resolver_ctx = ctx;
}

/// Borrow the host's default UI face; ownership stays with the host.
pub fn resolveDefaultTextFont(text: []const u8, size: f32, weight: u16, italic: bool) ?*text_module.Font {
    return resolveTextFont(text, size, weight, italic, false, 0);
}

pub fn resolveTextFont(text: []const u8, size: f32, weight: u16, italic: bool, mono: bool, family: u16) ?*text_module.Font {
    const resolve = g_shape_font_resolver orelse return null;
    return resolve(g_shape_font_resolver_ctx orelse return null, text, size, weight, italic, mono, family);
}

pub fn setContextFontHooks(owner: *anyopaque, resolve: ?ShapeFontResolveFn, measure: ?DrawnTextMeasureFn, ctx: ?*anyopaque) void {
    setShapeFontResolver(resolve, ctx);
    setDrawnTextMeasure(measure, ctx);
    g_context_font_owner = owner;
}

/// The active window may supply metrics for its selected font ranges. Layout
/// alignment and painting must use the same baseline as that shaped line.
pub fn setContextLineMetrics(owner: *anyopaque, metrics: ?TextLineMetricsFn, ctx: ?*anyopaque) void {
    if (g_context_font_owner != owner) return;
    g_context_line_metrics = metrics;
    g_context_line_metrics_ctx = ctx;
}

pub fn clearContextFontHooks(owner: *anyopaque) void {
    if (g_context_font_owner != owner) return;
    setShapeFontResolver(null, null);
    setDrawnTextMeasure(null, null);
}

/// Install the application's authoritative "width as drawn" callback.
/// Passing null removes it and restores the internal shaping fallback.
pub fn setDrawnTextMeasure(f: ?DrawnTextMeasureFn, ctx: ?*anyopaque) void {
    g_context_font_owner = null;
    g_context_line_metrics = null;
    g_context_line_metrics_ctx = null;
    g_drawn_text_measure = f;
    g_drawn_text_measure_ctx = ctx;
}

/// Inject the hook into text_layout.measureProportional. GlyphRun pipeline unavailable -> NaN,
/// caller falls back to platform measure.
///
/// Outside **layout** (draw/overlay/hit-test), temporarily mounts the same GlyphRun measure
/// hook, then restores.
///
/// # Why it's required
///
/// Hooks only live during `layoutNode` (see setShapeMeasureFn below). Same text: **layout** uses
/// shaping width, but overlay `measureProportional` finds no hook and falls to **platform
/// measure**. The paths mismatch, so selection highlight/caret drift toward the line end.
///
/// Caller (RAII style):
/// ```zig
/// var guard = beginExternalShapeMeasure(cx);
/// defer guard.end();
/// ```
pub const ExternalShapeMeasureGuard = struct {
    prev_cache: ?*shaping_cache_mod.ShapingCache,
    prev_fs: ?*text_module.FontSystem,
    prev_installed: bool,

    pub fn end(self: ExternalShapeMeasureGuard) void {
        g_active_shaping_cache = self.prev_cache;
        g_active_font_system = self.prev_fs;
        if (!self.prev_installed) text_layout.setShapeMeasureFn(null);
    }
};

pub fn beginExternalShapeMeasure(
    cache: ?*shaping_cache_mod.ShapingCache,
    fs: ?*text_module.FontSystem,
) ExternalShapeMeasureGuard {
    const guard = ExternalShapeMeasureGuard{
        .prev_cache = g_active_shaping_cache,
        .prev_fs = g_active_font_system,
        .prev_installed = text_layout.hasShapeMeasure(),
    };
    g_active_shaping_cache = cache;
    g_active_font_system = fs;
    text_layout.setShapeMeasureFn(&shapeMeasureBridge);
    return guard;
}

fn shapeMeasureBridge(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    return shapeViaPipeline(g_active_shaping_cache, g_active_font_system, text, font_size, font_weight, use_italic, use_monospace, 0, false, 0) orelse std.math.nan(f32);
}

/// cx-aware variant, spans empty -> GlyphRun pipeline (cache hit direct return
/// total_advance), else downgrade to measureTextWidthWithSpans old span path.
/// Full switch needs GlyphRun sub-range shape, phase D+ work.
fn measureIntrinsicTextWidthCtx(
    cache: ?*shaping_cache_mod.ShapingCache,
    fs: ?*text_module.FontSystem,
    t: types.TextProps,
) f32 {
    const layout_spans = if (t.spans_affect_layout) t.spans else &.{};
    if (t.layoutWrap() != .none) {
        const layout = text_layout.computeTextLayout(
            t.content,
            std.math.inf(f32),
            t.layoutWrap(),
            t.max_lines,
            t.font_size,
            t.line_height,
            t.font_weight,
            t.use_italic_font,
            t.use_monospace_font,
            layout_spans,
        );
        return layout.max_line_width;
    }
    // Single-line measure no spans -> GlyphRun pipeline fast path
    if (layout_spans.len == 0) {
        if (shapeViaPipeline(cache, fs, t.content, t.font_size, t.font_weight, t.use_italic_font, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width)) |w| {
            return w;
        }
    }
    return text_layout.measureTextWidthWithSpans(
        t.content,
        0,
        @intCast(t.content.len),
        t.font_size,
        t.font_weight,
        t.use_italic_font,
        t.use_monospace_font,
        layout_spans,
    );
}

/// Internal helper: measure text width via the GlyphRun pipeline from layout_engine. Mirrors
/// cx.shapeText / measureSegmentWidthCtx and uses the same ShapingKey schema.
/// Fail (FontLookupFailed/OOM) -> null, caller falls back to the old path.
/// Shapes and measures through the same font resolver used by the renderer. Render-time
/// rich-text chunk positioning also uses this entry point so it cannot silently fall back to a
/// different family than layout/drawing.
pub fn shapeViaPipeline(
    cache_opt: ?*shaping_cache_mod.ShapingCache,
    fs_opt: ?*text_module.FontSystem,
    text: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32 {
    if (text.len == 0) return 0;
    // This is the only answer that can be guaranteed identical to drawing:
    // it executes the TextRenderer's own segment/font/advance loop without
    // emitting glyphs. The local shaper below remains a compatibility fallback
    // for bare Cx/tests and hosts that have not installed the new callback.
    if (g_drawn_text_measure) |measure| {
        if (g_drawn_text_measure_ctx) |ctx| {
            if (measure(ctx, text, font_size, font_weight, use_italic, use_monospace, font_family, use_symbols, monospace_char_width)) |width| {
                if (!drawn_text_measure_debug_logged and @import("zenit_environment").flag("ZENIT_TEXT_MEASURE_IDENTITY_CHECK")) {
                    drawn_text_measure_debug_logged = true;
                    std.log.info("[text-measure-source] drawn-active", .{});
                }
                return width;
            }
        }
    }
    // Only the compatibility shaper needs these objects. The authoritative
    // width-as-drawn callback above must remain usable by lightweight/bare
    // contexts, otherwise installing it can still be silently bypassed.
    const cache = cache_opt orelse return null;
    const fs = fs_opt orelse return null;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(text);
    var weight_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &weight_buf, font_weight, .little);
    hasher.update(&weight_buf);
    const flag_byte: [1]u8 = .{(if (use_italic) @as(u8, 1) else 0) | (if (use_monospace) @as(u8, 2) else 0)};
    hasher.update(&flag_byte);
    const key = shaping_cache_mod.ShapingKey{
        .text_hash = hasher.final(),
        .text_len = @intCast(text.len),
        // family must enter key: family change needs re-shape, else hit previous
        // family cache.
        .font_id = (@as(u32, font_family) << 1) | (if (use_monospace) @as(u32, 1) else 0),
        .max_width = 0,
        .font_size = font_size,
    };
    if (cache.lookup(key)) |run| return run.total_advance;

    // Priority ask App's resolver: it returns renderer-running **same** *Font,
    // let shape pipeline (caret/selection/hit) measure same as draw. Fallback
    // by-name query system fonts (no App bare Cx / unit test goes this).
    // Ownership differs: resolver borrow (App holds), findFont new -> must deinit.
    var owned_font: ?*text_module.Font = null;
    defer if (owned_font) |f| f.deinit();
    const font = blk: {
        if (g_shape_font_resolver) |resolve| {
            if (g_shape_font_resolver_ctx) |ctx| {
                if (resolve(ctx, text, font_size, font_weight, use_italic, use_monospace, font_family)) |f| break :blk f;
            }
        }
        const desc = text_module.FontDescriptor{
            .family = "system",
            .size = font_size,
            .weight = mapFontWeight(font_weight),
            .style = if (use_italic) .italic else .normal,
        };
        const f = fs.findFont(desc) catch return null;
        owned_font = f;
        break :blk f;
    };
    var shaper = text_module.TextShaper.init(cache.allocator) catch return null;
    defer shaper.deinit();
    const shaped = shaper.shapeWithOptions(text, font, use_italic) catch return null;
    defer cache.allocator.free(shaped);
    defer releaseShapedFallbackFontRefs(shaped);
    const metrics = glyph_run_mod.FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = font_size };
    const run = text_shaper_adapter.fromShapedGlyphs(cache.allocator, shaped, metrics, .ltr) catch return null;
    defer cache.allocator.free(run.glyphs);
    defer cache.allocator.free(run.clusters);
    // Shaper per font's own pixelSize shapes advance. Resolver may return
    // neighboring-size font preloaded (FontSelector only derives past epsilon),
    // must scale to requested size, exactly same formula as
    // FontSelector.measureTextWidth `font_size / font.pixelSize()`,
    // both paths align.
    const font_px = font.pixelSize();
    const text_scale: f32 = if (font_px > 0) font_size / font_px else 1.0;
    const total = run.total_advance * text_scale;
    cache.insert(key, run.glyphs, run.clusters, run.metrics, run.direction, total) catch return total;
    return total;
}

fn mapFontWeight(weight: u16) text_module.FontWeight {
    return if (weight <= 100) .thin else if (weight <= 300) .light else if (weight <= 400) .regular else if (weight <= 500) .medium else if (weight <= 600) .semibold else if (weight <= 700) .bold else if (weight <= 800) .heavy else .black;
}

test "shapeViaPipeline prefers the authoritative drawn-width callback" {
    const Bridge = struct {
        var calls: usize = 0;

        fn measure(
            _: *anyopaque,
            content: []const u8,
            font_size: f32,
            font_weight: u16,
            use_italic: bool,
            use_monospace: bool,
            font_family: u16,
            use_symbols: bool,
            monospace_char_width: f32,
        ) ?f32 {
            calls += 1;
            std.debug.assert(std.mem.eql(u8, content, "mono span"));
            std.debug.assert(font_size == 13);
            std.debug.assert(font_weight == 600);
            std.debug.assert(use_italic);
            std.debug.assert(use_monospace);
            std.debug.assert(font_family == 7);
            std.debug.assert(use_symbols);
            std.debug.assert(monospace_char_width == 8.25);
            return 123.5;
        }
    };

    var marker: u8 = 0;
    setDrawnTextMeasure(&Bridge.measure, @ptrCast(&marker));
    defer setDrawnTextMeasure(null, null);
    Bridge.calls = 0;

    // The authoritative renderer callback must not be gated on the optional
    // local-shaper objects; otherwise a partially configured Cx bypasses the
    // correct answer and silently returns to platform measurement.
    const width = shapeViaPipeline(null, null, "mono span", 13, 600, true, true, 7, true, 8.25);
    try std.testing.expectEqual(@as(?f32, 123.5), width);
    try std.testing.expectEqual(@as(usize, 1), Bridge.calls);
}

/// Calculate node intrinsic size (fit mode). Text nodes return text estimate,
/// container nodes recursively sum children.
fn calcIntrinsicSize(node: *Node, comptime is_main_row: bool) f32 {
    // Subtree layout dirty -> offspring size may changed, but node
    // content_version doesn't track offspring change; cache entry can't see;
    // must bypass cache to recalc (fix stale intrinsic layout bug).
    const subtree_dirty = node.frame_state.state_bits.dirty.core.layout or
        node.frame_state.state_bits.dirty.core.subtree_layout;
    // Cache lookup (by node.id + content_version)
    if (!subtree_dirty) {
        if (intrinsicCacheLookup(node, is_main_row, .max_content)) |cached| return cached;
    }

    if (!enterLayoutRecursion()) return 0;
    defer leaveLayoutRecursion();

    const result = calcIntrinsicSizeUncached(node, is_main_row);
    intrinsicCacheStore(node, is_main_row, .max_content, result);
    return result;
}

fn calcIntrinsicSizeUncached(node: *Node, comptime is_main_row: bool) f32 {
    // Text node: estimate text size + node self padding. Measured with the resolved (inherited)
    // properties paint uses, never the raw TextProps.
    if (node.resolveTextProps()) |t| {
        const pad = if (is_main_row) node.style.contentInsets().horizontal() else node.style.contentInsets().vertical();
        // Multi-line text: use computed text_layout
        if (t.layoutWrap() != .none) {
            if (node.layoutTextLayout()) |tl| {
                if (is_main_row) {
                    return tl.max_line_width + pad;
                } else {
                    return tl.total_height + pad;
                }
            }
        }
        // Single-line text: prefer precise measure, fallback estimate
        const text_size = if (is_main_row) blk: {
            const measured = measureIntrinsicTextWidth(t);
            if (measured > 0) break :blk measured;
            // fallback: rough estimate
            const char_count = countUtf8Chars(t.content);
            break :blk @as(f32, @floatFromInt(char_count)) * t.font_size * 0.6;
        } else t.font_size * t.line_height;
        return text_size + pad;
    }

    // Container node: sum children main-axis
    if (node.children.items.len == 0) return if (is_main_row) node.style.contentInsets().horizontal() else node.style.contentInsets().vertical();

    const pad = if (is_main_row) node.style.contentInsets().horizontal() else node.style.contentInsets().vertical();
    // Absolute children don't participate in intrinsic (avoid overlay impact layout)
    var flow_count: usize = 0;
    for (node.children.items) |child| {
        if (!isOutOfFlow(child)) flow_count += 1;
    }
    if (flow_count == 0) return pad;

    const gap_total = if (flow_count > 1)
        @as(f32, @floatFromInt(flow_count - 1)) * node.style.gap
    else
        0;

    const child_is_row = node.style.direction.isRow();

    // Main and cross axis depend on container's own direction
    if (child_is_row == is_main_row) {
        // Same direction: sum children main
        var total: f32 = 0;
        for (node.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            total += calcChildIntrinsicSize(child, is_main_row) + childMarginForAxis(child, is_main_row);
        }
        return total + gap_total + pad;
    } else {
        // Cross direction: take max of children
        var max_size: f32 = 0;
        for (node.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            max_size = @max(max_size, calcChildIntrinsicSize(child, is_main_row) + childMarginForAxis(child, is_main_row));
        }
        return max_size + pad;
    }
}

/// Calculate single child intrinsic main-axis. Note: .grow child in .fit parent
/// has no space to allocate, should fallback to intrinsic (matches CSS
/// flex-grow in fit-content).
fn calcChildIntrinsicSize(child: *Node, comptime is_main_row: bool) f32 {
    if (isOutOfFlow(child)) return 0;
    // Match the flex resolver: zero is a definite basis, not the auto sentinel.
    // A basis only contributes on the parent's main axis. Engines disagree on
    // the intrinsic contribution of a flex-basis (2026-10-18: Chromium clamps
    // to min(basis, width), Firefox/WebKit ignore the basis); zenit follows
    // Chromium so intrinsic sizing and the fit backfill stay consistent. See
    // fixtures fit-parent-basis-* (informational, not must_match).
    if (child.parent) |parent| {
        if (parent.style.grid() == null and parent.style.direction.isRow() == is_main_row and child.style.flex_basis() >= 0)
            return child.style.flex_basis();
    }
    const sizing = if (is_main_row) child.style.width else child.style.height;
    return switch (sizing) {
        .px => |v| v,
        // grow/fit min/max with ext.min_X/ext.max_X merged via effectiveMinMax
        // (unified clamp). Else .fit{.max=N} and ext.max=M out-of-sync ->
        // one works one doesn't (small popup bust-oversized bug).
        .grow, .fit => blk: {
            const mm = effectiveMinMax(sizing, child, is_main_row);
            const opposite = if (is_main_row) child.style.height else child.style.width;
            const value = if (child.style.aspect_ratio() > 0 and opposite == .px)
                aspectTransfer(opposite.px, child.style.aspect_ratio(), is_main_row)
            else
                calcIntrinsicSize(child, is_main_row);
            if (child.parent) |parent| {
                if (parent.style.grid() == null and parent.style.flex_wrap() == .no_wrap and
                    parent.style.direction.isRow() == is_main_row)
                    break :blk @max(mm.min, @min(value, mm.max));
            }
            break :blk std.math.clamp(value, mm.min, mm.max);
        },
        .percent => 0,
    };
}

fn childMarginForAxis(child: *const Node, comptime is_main_row: bool) f32 {
    return if (is_main_row) child.style.marginHorizontal() else child.style.marginVertical();
}

const ResolvedAxisMargins = struct {
    start: f32,
    end: f32,
};

// Resolve physical margins before the final reverse-axis mirroring. Auto
// margins must stay on their CSS physical side in row/column-reverse too.
fn flexMainMargins(child: *const Node, row: bool, reverse: bool, auto_unit: f32) ResolvedAxisMargins {
    const margin = child.style.marginSpec();
    const physical = if (row) ResolvedAxisMargins{
        .start = if (child.style.marginLeftIsAuto()) auto_unit else margin.left,
        .end = if (child.style.marginRightIsAuto()) auto_unit else margin.right,
    } else ResolvedAxisMargins{
        .start = if (child.style.marginTopIsAuto()) auto_unit else margin.top,
        .end = if (child.style.marginBottomIsAuto()) auto_unit else margin.bottom,
    };
    return if (reverse) .{ .start = physical.end, .end = physical.start } else physical;
}

/// CSS §9.7 state; only flow children occupy scratch slots.
const FlexItem = struct {
    base: f32,
    target: f32,
    min: f32,
    max: f32,
    grow: f32,
    shrink: f32,
    scaled_shrink: f32,
    violation: f32 = 0,
    frozen: bool = false,

    fn clamp(self: FlexItem, value: f32) f32 {
        // CSS min wins over max when the constraints conflict.
        return @max(self.min, @min(value, self.max));
    }
};

// Single-line scratch: 32 * @sizeOf(FlexItem) = 1152 B. On 64-bit targets,
// wrap also stores 32 pointers (256 B) and 32 FlexLine values (768 B, including
// usize alignment/padding): 2176 B per frame, 272 KiB across the 128-frame guard.
// Other layout locals/callees consume stack too; this is the scratch bound,
// not a claim that the complete call chain occupies exactly this amount.
const flex_stack_capacity: usize = 32;

/// Min-content is distinct from the cached, possibly already wrapped max-content
/// measurement. Share the text line-break and span measurement primitives.
fn flexMinContent(node: *Node, comptime width: bool) f32 {
    const subtree_dirty = node.frame_state.state_bits.dirty.core.layout or
        node.frame_state.state_bits.dirty.core.subtree_layout;
    if (!subtree_dirty) {
        if (intrinsicCacheLookup(node, width, .min_content)) |cached| return cached;
    }
    if (g_min_content_recursion_depth >= max_layout_recursion_depth) {
        min_content_depth_limit_hits +|= 1;
        return 0;
    }
    g_min_content_recursion_depth += 1;
    defer g_min_content_recursion_depth -= 1;
    const hits_before = min_content_depth_limit_hits;
    const result = flexMinContentUncached(node, width);
    // Never memoize a truncated descendant as a complete measurement.
    if (hits_before == min_content_depth_limit_hits)
        intrinsicCacheStore(node, width, .min_content, result);
    return result;
}

fn flexMinContentUncached(node: *Node, comptime width: bool) f32 {
    const pad = if (width) node.style.contentInsets().horizontal() else node.style.contentInsets().vertical();
    if (node.resolveTextProps()) |text| {
        // This is a text leaf: use the shared primitive without borrowing the
        // unrelated active layout walk's remaining recursion budget.
        if (!width) return calcIntrinsicSizeUncached(node, false);
        if (text.layoutWrap() == .none or text.layoutWrap() == .newline_only) return measureIntrinsicTextWidth(text) + pad;
        var start: usize = 0;
        var pos: usize = 0;
        var longest: f32 = 0;
        const layout_spans = if (text.spans_affect_layout) text.spans else &.{};
        var graphemes = @import("text_core").grapheme.BoundaryCursor.init(text.content);
        while (pos < text.content.len) {
            const len = if (text.layoutWrap() == .char or text.layoutWrap() == .break_all)
                graphemes.next(pos) - pos
            else
                @min(text_layout.utf8CharLen(text.content[pos]), text.content.len - pos);
            const cp = text_layout.decodeUtf8(text.content[pos..][0..len]);
            const end = pos + len;
            const next = if (end < text.content.len) text_layout.decodeUtf8(text.content[end..]) else 0;
            if (end == text.content.len or cp == '\n' or (text.layoutWrap() == .char or text.layoutWrap() == .break_all) or (text.layoutWrap() != .keep_all and text_layout.isBreakableCluster(cp, next))) {
                // Wrapping discards trailing break whitespace (white-space:pre-wrap).
                var trimmed = end;
                while (trimmed > start and std.ascii.isWhitespace(text.content[trimmed - 1])) : (trimmed -= 1) {}
                longest = @max(longest, text_layout.measureTextWidthWithSpans(text.content, @intCast(start), @intCast(trimmed), text.font_size, text.font_weight, text.use_italic_font, text.use_monospace_font, layout_spans));
                start = end;
            }
            pos = end;
        }
        return longest + pad;
    }
    var result: f32 = 0;
    var count: usize = 0;
    const sum = node.style.direction.isRow() == width;
    for (node.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const sizing = if (width) child.style.width else child.style.height;
        const mm = effectiveMinMax(sizing, child, width);
        var content = switch (sizing) {
            .px => |v| v,
            .percent => @as(f32, 0), // cyclic intrinsic percentage
            .grow, .fit => flexMinContent(child, width),
        };
        const opposite = if (width) child.style.height else child.style.width;
        if (child.style.aspect_ratio() > 0 and opposite == .px)
            content = @max(content, aspectTransfer(opposite.px, child.style.aspect_ratio(), width));
        var minimum = mm.min;
        const basis = child.style.flex_basis();
        if (sum and node.style.grid() == null and node.style.flex_wrap() == .no_wrap and basis >= 0) {
            // §9.9.1: a non-growable item's intrinsic contribution cannot
            // grow past its definite basis. Keep its actual min-size floor;
            // otherwise fit > basis:0/min:0 incorrectly acquires width:100.
            const child_padding = if (width) child.style.contentInsets().horizontal() else child.style.contentInsets().vertical();
            const outer_basis = @max(child_padding, basis);
            if (sizing != .grow or child.style.flex <= 0) content = @min(content, outer_basis);
            if (child.style.flex_shrink <= 0) content = @max(content, outer_basis);
            const ext = child.style.getExt();
            const explicit_min = if (width) ext.min_width else ext.min_height;
            const own_min = switch (sizing) {
                .grow, .fit => |v| v.min,
                else => @as(f32, -1),
            };
            if (explicit_min < 0 and own_min < 0 and !child.style.overflow_hidden and child.style.overflow == .visible) {
                minimum = @min(flexMinContent(child, width), switch (sizing) {
                    .px => |v| v,
                    else => std.math.inf(f32),
                });
                minimum = @min(minimum, mm.max);
            }
        }
        const contribution = @max(minimum, @min(content, mm.max)) + childMarginForAxis(child, width);
        if (sum) result += contribution else result = @max(result, contribution);
        count += 1;
    }
    if (sum and count > 1) result += @as(f32, @floatFromInt(count - 1)) * node.style.gap;
    return result + pad;
}

fn aspectTransfer(value: f32, ratio: f32, to_width: bool) f32 {
    return if (to_width) value * ratio else value / ratio;
}

// A measured number alone is not a definite percentage basis. In particular,
// fit ancestors must not turn a cyclic percentage into a ratio suggestion.
var test_axis_definiteness_probes: usize = 0;

fn axisDefinite(node: *const Node, width: bool, depth: usize) bool {
    if (comptime @import("builtin").is_test) test_axis_definiteness_probes += 1;
    if (depth >= max_layout_recursion_depth) return false;
    const sizing = if (width) node.style.width else node.style.height;
    return switch (sizing) {
        .px => true,
        .fit => false,
        .percent, .grow => if (node.parent) |parent| axisDefinite(parent, width, depth + 1) else true,
    };
}

fn containingAxisDefinite(child: *const Node, width: bool) bool {
    return if (child.parent) |parent| axisDefinite(parent, width, 0) else true;
}

fn gridAxisDefinite(child: *const Node, width: bool) bool {
    const parent = child.parent orelse return true;
    if (axisDefinite(parent, width, 0)) return true;
    const gc = parent.style.grid() orelse return false;
    const count = if (width) gc.column_count else gc.row_count;
    if (count == 0) return false;
    const tracks = if (width) &gc.columns else &gc.rows;
    for (tracks[0..@min(count, GridConfig.MAX_TRACKS)]) |track| switch (track) {
        .px => {},
        else => return false,
    };
    return true;
}

fn definiteSize(sizing: Sizing, available: f32, basis_definite: bool) ?f32 {
    return switch (sizing) {
        .px => |v| v,
        .percent => |v| if (basis_definite) available * v / 100 else null,
        else => null,
    };
}

// A definite cross-size (including a definite nowrap stretch) supplies a
// transferred size suggestion. Ratios use border-box dimensions in this engine.
fn aspectMainSuggestion(child: *Node, comptime row: bool, available: Size) ?f32 {
    const ar = child.style.aspect_ratio();
    if (!(ar > 0) or !std.math.isFinite(ar)) return null;
    const sizing = if (row) child.style.height else child.style.width;
    const avail = if (row) available.height else available.width;
    const cross_definite = containingAxisDefinite(child, !row);
    var cross = definiteSize(sizing, avail, cross_definite);
    if (cross == null) if (child.parent) |parent| {
        const parent_cross = if (row) parent.style.height else parent.style.width;
        if ((sizing == .fit or sizing == .grow) and cross_definite and parent.style.flex_wrap() == .no_wrap and parent_cross != .fit and stretches(child, row, parent.style.align_items))
            cross = avail - childMarginForAxis(child, !row);
    };
    const mm = effectiveMinMax(sizing, child, !row);
    return if (cross) |v| aspectTransfer(std.math.clamp(v, mm.min, mm.max), ar, row) else null;
}

fn aspectCrossSize(child: *Node, row: bool, main: f32, natural: f32) f32 {
    const ar = child.style.aspect_ratio();
    const sizing = if (row) child.style.height else child.style.width;
    if (!(ar > 0) or !std.math.isFinite(ar)) return natural;
    // Most nodes have no ratio. Do not walk their ancestor chain merely to
    // evaluate a call argument; percentage definiteness matters only here.
    const basis_definite = if (child.parent != null and child.parent.?.style.grid() != null)
        gridAxisDefinite(child, !row)
    else
        containingAxisDefinite(child, !row);
    if (definiteSize(sizing, natural, basis_definite) != null) return natural;
    const mm = if (row) effectiveMinMax(sizing, child, false) else effectiveMinMax(sizing, child, true);
    return std.math.clamp(aspectTransfer(main, ar, !row), mm.min, mm.max);
}

fn flexContentSize(child: *Node, comptime row: bool, available: Size) f32 {
    if (child.resolveTextProps()) |text| {
        if (row) return measureIntrinsicTextWidth(text) + child.style.contentInsets().horizontal();
        const cross_align = if (child.parent) |parent| resolveCrossAlign(child, parent.style.align_items) else types.AlignItems.stretch;
        const mm = effectiveMinMax(child.style.width, child, true);
        const width = std.math.clamp(resolveCrossAxisSize(child, false, available, cross_align), mm.min, mm.max);
        return measureNode(child, .{ .definite_width = width }).height;
    }
    return calcIntrinsicSize(child, row);
}

fn makeFlexItem(child: *Node, comptime row: bool, available: Size) FlexItem {
    if (comptime @import("builtin").is_test) test_flex_item_probes += 1;
    const sizing = if (row) child.style.width else child.style.height;
    const avail = if (row) available.width else available.height;
    const padding = if (row) child.style.contentInsets().horizontal() else child.style.contentInsets().vertical();
    const basis = child.style.flex_basis();
    // auto consults the main size; content ignores it. 0 is a definite basis.
    const suggestion = aspectMainSuggestion(child, row, available);
    const base = if (basis >= 0) basis else if (basis == types.FlexBasis.content)
        flexContentSize(child, row, available)
    else switch (sizing) {
        .px => |v| v,
        .percent => |v| avail * v / 100,
        .grow, .fit => suggestion orelse flexContentSize(child, row, available),
    };
    const mm = effectiveMinMax(sizing, child, row);
    const ext = child.style.getExt();
    const ext_min = if (row) ext.min_width else ext.min_height;
    const own_min = switch (sizing) {
        .grow, .fit => |v| v.min,
        else => @as(f32, -1),
    };
    var minimum = mm.min;
    if (ext_min < 0 and own_min < 0 and !child.style.overflow_hidden and child.style.overflow == .visible) {
        minimum = if (!row and child.resolveTextProps() != null) flexContentSize(child, row, available) else flexMinContent(child, row);
        // Flexbox §4.5: non-replaced content minimum is the larger of
        // content and transferred suggestions, capped by the specified size.
        if (suggestion) |v| minimum = @max(minimum, v);
        // Specified size suggestion caps the content-based minimum.
        minimum = @min(minimum, switch (sizing) {
            .px => |v| v,
            .percent => |v| avail * v / 100,
            else => std.math.inf(f32),
        });
        minimum = @min(minimum, mm.max);
    }
    var item = FlexItem{
        .base = @max(padding, base),
        .target = 0,
        .min = @max(padding, minimum),
        .max = @max(padding, mm.max),
        .grow = if (sizing == .grow) @max(0, child.style.flex) else 0,
        .shrink = @max(0, child.style.flex_shrink),
        .scaled_shrink = @max(0, base - padding) * @max(0, child.style.flex_shrink),
    };
    item.target = item.clamp(item.base);
    return item;
}

/// CSS Flexbox §9.7. Each pass freezes at least one item, so bounded by n+1
/// passes; the usual unconstrained case takes a single linear pass.
fn resolveFlexibleLengths(items: []FlexItem, available: f32) void {
    var hypothetical: f32 = 0;
    for (items) |item| hypothetical += item.target;
    const growing = hypothetical < available;
    var initial_free = available;
    for (items) |*item| {
        const factor = if (growing) item.grow else item.shrink;
        item.frozen = factor == 0 or (if (growing) item.base > item.target else item.base < item.target);
        // §9.7 step 4 explicitly uses frozen target sizes, and unfrozen flex
        // bases, for initial free space. This is intentional and matches CSS.
        if (item.frozen) initial_free -= item.target else initial_free -= item.base;
    }
    for (0..items.len + 1) |_| {
        var free = available;
        var factors: f32 = 0;
        var scaled: f32 = 0;
        var active: usize = 0;
        for (items) |item| {
            free -= if (item.frozen) item.target else item.base;
            if (!item.frozen) {
                active += 1;
                factors += if (growing) item.grow else item.shrink;
                scaled += item.scaled_shrink;
            }
        }
        if (active == 0) return;
        if (factors < 1 and @abs(initial_free * factors) < @abs(free)) free = initial_free * factors;
        var total_violation: f32 = 0;
        for (items) |*item| {
            if (item.frozen) continue;
            const proposed = if (growing)
                item.base + (if (factors > 0) free * item.grow / factors else 0)
            else
                item.base - (if (scaled > 0) @abs(free) * item.scaled_shrink / scaled else 0);
            item.target = item.clamp(proposed);
            item.violation = item.target - proposed;
            total_violation += item.violation;
        }
        for (items) |*item| {
            // Intentional numerical deviation from §9.7's exact-zero test:
            // sub-0.0001px cancellation is treated as zero so f32 roundoff
            // cannot keep an otherwise settled set active. Targets are still
            // individually clamped; this does not relax oracle tolerances.
            if (@abs(total_violation) < 0.0001 or
                (total_violation > 0 and item.violation > 0) or
                (total_violation < 0 and item.violation < 0)) item.frozen = true;
        }
    }
}

/// Cross size: px/grow/fit/percent, plus align-stretch override.
/// Cross not participate in flex_shrink.
// Cross auto sizing is intrinsic unless stretch applies. Auto margins suppress
// stretch; clamp after the stretch calculation, with min winning over max.
fn resolveCrossAxisSize(child: *Node, is_row: bool, available: Size, cross_align: AlignItems) f32 {
    const sizing = if (is_row) child.style.height else child.style.width;
    const avail = if (is_row) available.height else available.width;
    const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();
    const auto_margin = crossAutoMargins(child, is_row);
    var size: f32 = switch (sizing) {
        .px => |v| v,
        .grow, .fit => if (is_row) calcIntrinsicSize(child, false) else calcIntrinsicSize(child, true),
        .percent => |v| avail * v / 100,
    };
    if ((sizing == .grow or sizing == .fit) and cross_align == .stretch and !auto_margin) size = avail - margin_cross;
    const mm = if (is_row) effectiveMinMax(sizing, child, false) else effectiveMinMax(sizing, child, true);
    return @max(mm.min, @min(size, mm.max));
}

fn crossAutoMargins(child: *const Node, row: bool) bool {
    return if (row) child.style.marginTopIsAuto() or child.style.marginBottomIsAuto() else child.style.marginLeftIsAuto() or child.style.marginRightIsAuto();
}
fn stretches(child: *Node, row: bool, align_items: AlignItems) bool {
    const sizing = if (row) child.style.height else child.style.width;
    return (sizing == .grow or sizing == .fit) and resolveCrossAlign(child, align_items) == .stretch and !crossAutoMargins(child, row);
}

// Shared by layout and paint: baseline of the first line, relative to its line
// box top. A custom baseline_ratio remains an explicit Zenit text extension.
pub fn firstTextBaseline(t: *const types.TextProps) f32 {
    const height = t.font_size * t.line_height;
    if (t.baseline_ratio > 0) return height * t.baseline_ratio;
    if (g_context_line_metrics) |metrics_fn| {
        if (g_context_line_metrics_ctx) |ctx| {
            if (metrics_fn(ctx, t)) |metrics| {
                if (std.math.isFinite(metrics.ascent) and std.math.isFinite(metrics.descent) and metrics.ascent >= 0 and metrics.descent >= 0) {
                    const ascent = @round(metrics.ascent);
                    const descent = @round(metrics.descent);
                    return @floor((height - ascent - descent) / 2) + ascent;
                }
            }
        }
    }
    if (comptime @hasDecl(text_module.Font, "getAscent") and @hasDecl(text_module.Font, "getDescent")) {
        if (resolveTextFont(t.content, t.font_size, t.font_weight, t.use_italic_font, t.use_monospace_font, t.font_family)) |font| {
            // CSS host font metrics are pixel-rounded before half-leading is
            // assigned (Lora 16px: 16/4 -> baseline 17; 32px: 32/9 -> 33).
            // Keep paint and alignment on that same line-box baseline.
            const ascent = @round(font.getAscent());
            const descent = @round(font.getDescent());
            return @floor((height - ascent - descent) / 2) + ascent;
        }
    }
    return height * 0.75;
}

fn baselineAlign(align_items: AlignItems) bool {
    return align_items == .baseline or align_items == .first_baseline;
}

// Flexbox §8.5: a flex container exports a participating first-line baseline,
// otherwise the first item's baseline. Empty/orthogonal boxes synthesize from
// their border box. Traversal is bounded separately from layout recursion.
fn firstBaseline(node: *Node, row: bool, depth: usize) f32 {
    const r = node.rectFromWorldOrFallback();
    if (!row or depth >= max_layout_recursion_depth) return if (row) r.h else r.w;
    if (node.resolveTextProps()) |t| return if (t.content.len == 0) r.h else node.style.contentInsets().top + firstTextBaseline(&t);
    var first: ?*Node = null;
    // The line collector cached the raw child-slice boundary before flexing.
    // Reusing it avoids intrinsic probes during each ancestor baseline export.
    const end = if (node.style.direction.isRow() and node.style.flex_wrap() != .no_wrap and node.style.grid() == null)
        @min(node.frame_state.first_flex_line_end, node.children.items.len)
    else
        node.children.items.len;
    for (node.children.items[0..end]) |child| {
        if (isOutOfFlow(child)) continue;
        if (first == null) first = child;
        if (node.style.direction.isRow() and baselineAlign(resolveCrossAlign(child, node.style.align_items)) and !crossAutoMargins(child, true)) {
            return child.rectFromWorldOrFallback().y + firstBaseline(child, true, depth + 1);
        }
    }
    if (first) |child| return child.rectFromWorldOrFallback().y + firstBaseline(child, true, depth + 1);
    return r.h;
}

const Distribution = struct { offset: f32 = 0, gap: f32 = 0 };
// Negative distributed free space uses flex-start for between/around/evenly,
// preserving fixed gutters even on reversed axes. This follows the direction
// of CSSWG #11937 / the January 2026 safe-fallback edit; those do not directly
// settle around/evenly in non-scroll containers. Chromium/Firefox differ from
// WebKit/Zenit there; the affected fixtures document report-only disagreement.
fn distribute(justify: types.JustifyContent, free: f32, count: usize, gap: f32) Distribution {
    const n: f32 = @floatFromInt(count);
    return switch (justify) {
        .start => .{ .gap = gap },
        .end => .{ .offset = free, .gap = gap },
        .center => .{ .offset = free / 2, .gap = gap },
        .space_between => .{ .gap = gap + (if (count > 1 and free > 0) free / (n - 1) else 0) },
        .space_around => if (free < 0 or count == 0) .{ .gap = gap } else .{ .offset = free / n / 2, .gap = gap + free / n },
        .space_evenly => if (free < 0) .{ .gap = gap } else .{ .offset = free / (n + 1), .gap = gap + free / (n + 1) },
    };
}

fn resolveAxisMargins(
    available_outer: f32,
    child_size: f32,
    start_value: f32,
    end_value: f32,
    start_auto: bool,
    end_auto: bool,
) ResolvedAxisMargins {
    const fixed = (if (start_auto) 0 else start_value) + (if (end_auto) 0 else end_value);
    const free = @max(@as(f32, 0), available_outer - child_size - fixed);
    if (start_auto and end_auto) {
        const half = free / 2.0;
        return .{ .start = half, .end = half };
    }
    if (start_auto) return .{ .start = free, .end = end_value };
    if (end_auto) return .{ .start = start_value, .end = free };
    return .{ .start = start_value, .end = end_value };
}

/// Measure phase: computes the node's precise intrinsic size under given constraints.
///
/// Difference from calcIntrinsicSize:
/// - measureNode wraps text once width is known (resolves "width determines height")
/// - result is more precise, used to eliminate backfill in fit containers
///
/// constraints.definite_width != null -> text can wrap, returns exact height
/// constraints.definite_width == null -> returns minimum intrinsic size
pub fn measureNode(node: *Node, constraints: types.LayoutConstraints) Size {
    if (!enterLayoutRecursion()) {
        return Size.init(
            std.math.clamp(node.style.contentInsets().horizontal(), constraints.min_width, constraints.max_width),
            std.math.clamp(node.style.contentInsets().vertical(), constraints.min_height, constraints.max_height),
        );
    }
    defer leaveLayoutRecursion();

    // text node (resolved properties: what paint draws)
    if (node.resolveTextProps()) |t| {
        const pad_w = node.style.contentInsets().horizontal();
        const pad_h = node.style.contentInsets().vertical();

        // width
        const text_w = blk: {
            if (constraints.definite_width) |dw| {
                break :blk dw;
            }
            // intrinsic width: precise measurement
            const measured = measureIntrinsicTextWidth(t);
            if (measured > 0) break :blk measured + pad_w;
            const char_count = countUtf8Chars(t.content);
            break :blk @as(f32, @floatFromInt(char_count)) * t.font_size * 0.6 + pad_w;
        };

        // height: performs text wrapping with definite width
        const text_h = blk: {
            if (t.layoutWrap() != .none) {
                const avail_w = if (constraints.definite_width) |dw|
                    dw - pad_w
                else if (constraints.max_width < std.math.inf(f32))
                    constraints.max_width - pad_w
                else
                    0;

                if (avail_w > 0) {
                    // execute wrapping calculation
                    const tl = text_layout.computeTextLayout(
                        t.content,
                        avail_w,
                        t.layoutWrap(),
                        t.max_lines,
                        t.font_size,
                        t.line_height,
                        t.font_weight,
                        t.use_italic_font,
                        t.use_monospace_font,
                        t.spans,
                    );
                    // cache to node, avoiding redundant computation in subsequent layout phase
                    node.storeTextLayout(&tl) catch {
                        layout_alloc_failure_hits += 1;
                        // Never publish a partial cache or render stale wraps.
                        node.clearTextLayout();
                        node.frame_state.state_bits.dirty.core.layout = true;
                    };
                    break :blk tl.total_height + pad_h;
                }
            }
            // single-line or no width constraint
            break :blk t.font_size * t.line_height + pad_h;
        };

        return Size.init(
            std.math.clamp(text_w, constraints.min_width, constraints.max_width),
            std.math.clamp(text_h, constraints.min_height, constraints.max_height),
        );
    }

    // container node: recursively measure children
    if (node.children.items.len == 0) {
        return Size.init(
            std.math.clamp(node.style.contentInsets().horizontal(), constraints.min_width, constraints.max_width),
            std.math.clamp(node.style.contentInsets().vertical(), constraints.min_height, constraints.max_height),
        );
    }

    const is_row = node.style.direction.isRow();
    const pad_w = node.style.contentInsets().horizontal();
    const pad_h = node.style.contentInsets().vertical();

    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    var flow_count: usize = 0;

    for (node.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        flow_count += 1;
        const margin_main = if (is_row) child.style.marginHorizontal() else child.style.marginVertical();
        const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();

        // child's intrinsic size
        const child_main_sizing = if (is_row) child.style.width else child.style.height;
        const child_cross_sizing = if (is_row) child.style.height else child.style.width;

        const child_main: f32 = switch (child_main_sizing) {
            .px => |v| v + margin_main,
            .grow, .fit => blk: {
                // for fit children: if definite main-axis constraint exists, pass to child
                const child_constraints = if (is_row)
                    types.LayoutConstraints{ .max_width = @max(@as(f32, 0), constraints.max_width - pad_w - margin_main) }
                else
                    types.LayoutConstraints{ .max_height = @max(@as(f32, 0), constraints.max_height - pad_h - margin_main) };
                const child_size = measureNode(child, child_constraints);
                break :blk (if (is_row) child_size.width else child_size.height) + margin_main;
            },
            .percent => 0, // percent in intrinsic = auto (CSS spec)
        };

        const child_cross: f32 = switch (child_cross_sizing) {
            .px => |v| v + margin_cross,
            .grow, .fit => blk: {
                const child_constraints = if (is_row)
                    types.LayoutConstraints{ .max_height = @max(@as(f32, 0), constraints.max_height - pad_h - margin_cross) }
                else
                    types.LayoutConstraints{ .max_width = @max(@as(f32, 0), constraints.max_width - pad_w - margin_cross) };
                const child_size = measureNode(child, child_constraints);
                break :blk (if (is_row) child_size.height else child_size.width) + margin_cross;
            },
            .percent => 0,
        };

        main_total += child_main;
        cross_max = @max(cross_max, child_cross);
    }

    if (flow_count > 1) {
        main_total += @as(f32, @floatFromInt(flow_count - 1)) * node.style.gap;
    }

    const w = if (is_row) main_total + pad_w else cross_max + pad_w;
    const h = if (is_row) cross_max + pad_h else main_total + pad_h;

    return Size.init(
        std.math.clamp(w, constraints.min_width, constraints.max_width),
        std.math.clamp(h, constraints.min_height, constraints.max_height),
    );
}

// Geometry is a transaction: no application callback may invalidate tree borrows
// while flex/grid/backfill still use them. Publish only after the outer walk.
var suppress_layout_mounts = false;

pub fn layoutNode(node: *Node, available: Size, ctx: LayoutContext) void {
    var frame_ctx = ctx;
    if (g_layout_recursion_depth == 0 and frame_ctx.initial_containing_block == null) frame_ctx.initial_containing_block = available;
    if (g_layout_recursion_depth != 0) {
        layoutNodeImpl(node, available, frame_ctx);
        return;
    }
    const previous = suppress_layout_mounts;
    suppress_layout_mounts = true;
    layoutNodeImpl(node, available, frame_ctx);
    suppress_layout_mounts = previous;
    if (!previous and !ctx.defer_mount and node.frame_state.frame_local.runtime.layout_mount_pending) {
        // A callback may destroy the outer root itself. A stack watch guards
        // the retry write without reading released memory or allocating scratch.
        var watch = @import("node_lifecycle.zig").ReleaseWatch{ .node = node };
        watch.begin();
        defer watch.end();
        if (publishLayoutMounts(node, 0) and watch.alive) node.markLayoutDirty();
    }
}

// A structure change invalidates every borrowed ancestor/sibling slice. Unwind
// without reading any of them again; the mutation dirties the surviving tree
// and remaining first mounts are published by its next layout. No scratch/OOM.
var test_mount_publication_visits: usize = 0;

fn publishLayoutMounts(node: *Node, depth: usize) bool {
    if (!node.frame_state.frame_local.runtime.layout_mount_pending or depth >= max_layout_recursion_depth) return false;
    if (comptime @import("builtin").is_test) test_mount_publication_visits += 1;
    const tree = @import("node_tree.zig");
    for (node.children.items) |child| {
        if (publishLayoutMounts(child, depth + 1)) return true;
    }
    if (node.frame_state.state_bits.dirty.core.layout) return false;
    const revision = tree.structureRevision();
    const lifetime = @import("node_lifecycle.zig").releaseRevision();
    // Clear before invoking user code: the callback may release this node.
    node.frame_state.frame_local.runtime.layout_mount_pending = false;
    node_mod.fireMountIfNeeded(node);
    return tree.structureRevision() != revision or @import("node_lifecycle.zig").releaseRevision() != lifetime;
}

fn layoutNodeImpl(node: *Node, available: Size, initial_ctx: LayoutContext) void {
    var ctx = initial_ctx;
    if (!enterLayoutRecursion()) return;
    defer leaveLayoutRecursion();
    if (comptime @import("builtin").is_test) test_layout_calls += 1;
    const alloc_failures_before = layout_alloc_failure_hits;

    // GlyphRun pipeline globals: measureIntrinsicTextWidth's call chain has no ctx parameter, so
    // the layout pass sets/restores globals at entry so it can use the cache.
    // Outer values are saved across nested layoutNode (recursive child) so unwinding restores them.
    //
    // Also installs shapeMeasureBridge as the text_layout.measureProportional callback, so *all*
    // legacy measurement paths (computeTextLayout / findLineBreak / measureSpanAware / textarea
    // direct / input/text_utils direct) use the pipeline without caller changes.
    const prev_cache = g_active_shaping_cache;
    const prev_fs = g_active_font_system;
    g_active_shaping_cache = ctx.shaping_cache;
    g_active_font_system = ctx.font_system;
    text_layout.setShapeMeasureFn(&shapeMeasureBridge);
    defer {
        g_active_shaping_cache = prev_cache;
        g_active_font_system = prev_fs;
        // unwind at nested exit or top-level exit; unset if prev_cache=null, otherwise keep set
        if (prev_cache == null and prev_fs == null) {
            text_layout.setShapeMeasureFn(null);
        }
    }

    // layout_isolation debug assert: isolation node cannot be fit (else internal changes affect
    // outer sizing)
    if (node.style.layout_isolation) {
        std.debug.assert(node.style.width != .fit and node.style.height != .fit);
    }

    // compute self-size only for root node; children's sizes are layoutChildren's responsibility
    if (node.parent == null) {
        const intrinsic_w = calcIntrinsicSize(node, true);
        const intrinsic_h = calcIntrinsicSize(node, false);

        const wm = effectiveMinMax(node.style.width, node, true);
        const hm = effectiveMinMax(node.style.height, node, false);
        node.setLayoutW(std.math.clamp(resolveSize(node.style.width, available.width, intrinsic_w), wm.min, wm.max));
        node.setLayoutH(std.math.clamp(resolveSize(node.style.height, available.height, intrinsic_h), hm.min, hm.max));
        const ratio = node.style.aspect_ratio();
        if (ratio > 0 and std.math.isFinite(ratio)) {
            if (definiteSize(node.style.width, available.width, true)) |_| {
                if (node.style.height == .fit or node.style.height == .grow)
                    node.setLayoutH(std.math.clamp(node.rectFromWorldOrFallback().w / ratio, hm.min, hm.max));
            } else if (definiteSize(node.style.height, available.height, true)) |_| {
                node.setLayoutW(std.math.clamp(node.rectFromWorldOrFallback().h * ratio, wm.min, wm.max));
            }
            ctx.frozen_node = node;
            ctx.frozen_both_axes = true;
        }
    }

    // A static box cannot cache its descendants against only its own size:
    // positioned grandchildren may depend on a farther containing block.
    if (node.style.position == .static and node.children.items.len > 0)
        node.frame_state.state_bits.dirty.core.layout = true;

    const w = node.rectFromWorldOrFallback().w;
    const h = node.rectFromWorldOrFallback().h;

    // A wrap probe may already have cleaned every descendant without mounting
    // it. The first published layout must still traverse that subtree, so deep
    // hooks observe final ancestor positions instead of being skipped forever.
    if (!ctx.defer_mount and !node.frame_state.state_bits.flags.is_mounted) {
        node.frame_state.state_bits.dirty.core.layout = true;
    }

    if (node.children.items.len > 0) {
        if (node.frame_state.state_bits.dirty.core.layout) {
            // current node dirty -> full layout children (flex depends on sibling relations)
            const content_w = @max(0, w - node.style.contentInsets().horizontal());
            const content_h = @max(0, h - node.style.contentInsets().vertical());
            if (node.style.grid() != null) {
                layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
            } else {
                layoutChildren(node, Size.init(content_w, content_h), ctx);
            }
        } else if (node.frame_state.state_bits.dirty.core.subtree_layout) {
            const own_main_fit = if (node.style.direction.isRow())
                node.style.width == .fit
            else
                node.style.height == .fit;
            const own_cross_fit = if (node.style.direction.isRow())
                node.style.height == .fit
            else
                node.style.width == .fit;

            // fit containers cannot recurse only dirty subtree: their self-size depends on actual
            // layout results of descendants.
            // Typical scenario: wrapped text deepens, direct child only has subtree_dirty;
            // skip full layout here -> parent keeps old rect, overflow_hidden clips content.
            if (own_main_fit or own_cross_fit or crossDependentDirty(node)) {
                const content_w = @max(0, w - node.style.contentInsets().horizontal());
                const content_h = @max(0, h - node.style.contentInsets().vertical());
                if (node.style.grid() != null) {
                    layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
                } else {
                    layoutChildren(node, Size.init(content_w, content_h), ctx);
                }
            } else
            // Grid container: needs full relayout when direct child layout_dirty.
            // Grid track sizing (including implicit auto rows) depends on child sizes,
            // and child positions are determined by auto-placement (sibling-related),
            // so any dirty child requires full recalculation.
            if (node.style.grid() != null) {
                var need_full = false;
                for (node.children.items) |child| {
                    if (child.frame_state.state_bits.dirty.core.layout) {
                        need_full = true;
                        break;
                    }
                }
                if (need_full) {
                    const content_w = @max(0, w - node.style.contentInsets().horizontal());
                    const content_h = @max(0, h - node.style.contentInsets().vertical());
                    layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
                } else {
                    for (node.children.items) |child| {
                        if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                            layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
                        }
                    }
                }
            } else {
                const is_row = node.style.direction.isRow();
                // subtree has dirty nodes -> check for flex sibling dependency.
                // If grow children exist, one child's size change affects flex allocation of other
                // siblings,
                // fallback to full relayout required.
                var has_flex_children = false;
                for (node.children.items) |child| {
                    if (isOutOfFlow(child)) continue;
                    const main_sizing = if (is_row) child.style.width else child.style.height;
                    if (main_sizing == .grow) {
                        has_flex_children = true;
                        break;
                    }
                }

                if (has_flex_children) {
                    // optimization: full layout only when "direct child layout may affect sibling
                    // allocation".
                    // Typical scroll scenario is only deep subtree_dirty (direct child size
                    // unchanged), no fallback.
                    var must_full_layout = false;
                    for (node.children.items) |child| {
                        if (isOutOfFlow(child)) continue;
                        const main_sizing = if (is_row) child.style.width else child.style.height;
                        if (child.frame_state.state_bits.dirty.core.layout) {
                            must_full_layout = true;
                            break;
                        }
                        if (child.frame_state.state_bits.dirty.core.subtree_layout and main_sizing == .fit) {
                            must_full_layout = true;
                            break;
                        }
                    }

                    if (must_full_layout) {
                        const content_w = @max(0, w - node.style.contentInsets().horizontal());
                        const content_h = @max(0, h - node.style.contentInsets().vertical());
                        layoutChildren(node, Size.init(content_w, content_h), ctx);
                    } else {
                        for (node.children.items) |child| {
                            if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                                // Absolute layout-dirty children must call layoutAbsoluteChild to
                                // re-resolve size/position:
                                // the must_full_layout path above intentionally skips absolute
                                // children (they do not affect flow
                                // siblings), but the fallback recursion layoutNode(child, old_rect)
                                // leaves **absolute children
                                // appended after the first layout with rect = 0**, so text labels
                                // on canvas objects never render.
                                if (isDisplayNone(child)) {
                                    collapseDisplayNone(child);
                                } else if (child.style.position == .absolute and absoluteChildNeedsResolve(child)) {
                                    layoutAbsoluteChild(node, child, ctx);
                                } else {
                                    relayoutFlexChild(node, child, ctx);
                                }
                            }
                        }
                    }
                } else {
                    // without flex dependency: if direct child layout_dirty (size/position style
                    // changed),
                    // still need full layout to update that child's rect in parent.
                    // Just recursing layoutNode(child) won't recalculate flow child x/y/w/h.
                    var must_full_layout = false;
                    for (node.children.items) |child| {
                        if (isOutOfFlow(child)) continue;
                        const main_sizing = if (is_row) child.style.width else child.style.height;
                        if (child.frame_state.state_bits.dirty.core.layout) {
                            must_full_layout = true;
                            break;
                        }
                        if (child.frame_state.state_bits.dirty.core.subtree_layout and main_sizing == .fit) {
                            must_full_layout = true;
                            break;
                        }
                    }

                    if (must_full_layout) {
                        const content_w = @max(0, w - node.style.contentInsets().horizontal());
                        const content_h = @max(0, h - node.style.contentInsets().vertical());
                        layoutChildren(node, Size.init(content_w, content_h), ctx);
                    } else {
                        for (node.children.items) |child| {
                            if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                                // Absolute layout-dirty children must call layoutAbsoluteChild to
                                // re-resolve size/position:
                                // the must_full_layout path above intentionally skips absolute
                                // children (they do not affect flow
                                // siblings), but the fallback recursion layoutNode(child, old_rect)
                                // leaves **absolute children
                                // appended after the first layout with rect = 0**, so text labels
                                // on canvas objects never render.
                                if (isDisplayNone(child)) {
                                    collapseDisplayNone(child);
                                } else if (child.style.position == .absolute and absoluteChildNeedsResolve(child)) {
                                    layoutAbsoluteChild(node, child, ctx);
                                } else {
                                    relayoutFlexChild(node, child, ctx);
                                }
                            }
                        }
                    }
                }
            }
        }
        // both false -> skip entire subtree (core optimization for incremental layout)
    }

    // After layout: an overflow_hidden node that is layout_dirty this pass (size/position may have
    // changed) must invalidate its render cache and be marked render dirty. Otherwise:
    // 1. the old cache's push_clip rect and child coordinates are stale -> wrong cache reused
    // 2. children mounted in the first frame, not fully laid out -> incomplete content is rendered
    //    and
    //    cached -> later subtree_render_dirty is cleared -> incomplete cache reused, content lost
    // markRenderDirty bubbles subtree_render_dirty up, so ancestor overflow_hidden containers
    // (e.g. scroll_area) caches are invalidated too.
    if (node.frame_state.state_bits.dirty.core.layout and node.style.overflow_hidden) {
        node.invalidateRenderCache();
        node.markRenderDirty();
    }

    // compute child bounding box (for hitTest culling)
    // only recalculate on layout_dirty or subtree_dirty, avoid redundant per-frame computation
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.core.subtree_layout) {
        computeChildrenBBox(node);
    }

    // Allocation-free degradation is usable on the first frame, but must be
    // retried next frame. Preserve the retry through every affected ancestor.
    node.frame_state.state_bits.dirty.core.layout = alloc_failures_before != layout_alloc_failure_hits or
        (ctx.defer_mount and !node.frame_state.state_bits.flags.is_mounted);
    node.frame_state.state_bits.dirty.core.subtree_layout = false;
    if (ctx.defer_mount) for (node.children.items) |child| {
        const bits = child.frame_state.state_bits;
        if (bits.dirty.core.layout or bits.dirty.core.subtree_layout)
            node.frame_state.state_bits.dirty.core.subtree_layout = true;
    };

    node.frame_state.frame_local.runtime.layout_mount_pending = !node.frame_state.state_bits.flags.is_mounted;
    for (node.children.items) |child| {
        node.frame_state.frame_local.runtime.layout_mount_pending = node.frame_state.frame_local.runtime.layout_mount_pending or child.frame_state.frame_local.runtime.layout_mount_pending;
    }

    // trigger onMount lifecycle hook (current node only).
    // children fire in their own layoutNode call tail, avoiding full-tree scan per frame.
    if (!suppress_layout_mounts and !ctx.defer_mount and alloc_failures_before == layout_alloc_failure_hits)
        node_mod.fireMountIfNeeded(node);
}

/// compute children's painted bounding box union (relative to this node, includes translate
/// offset). A child counts with everything it paints outside its own rect: every shadow layer,
/// its outline, and (unless it clips them) its own descendants' painted box. Used by hitTest
/// culling and as the offscreen surface extent of opacity/composited layers: a descendant's
/// shadow outside this box is cut by the texture edge into a hard rectangle.
fn computeChildrenBBox(node: *Node) void {
    const lo = node.layoutOutputPtr() orelse return;
    var bbox: ?types.ComputedRect = null;
    for (node.children.items) |child| {
        if (child.getOpacity() == 0) continue;
        // z>0 children also count: z_index affects sibling order only, doesn't escape clipping,
        // drawn in parent's opacity surface like z=0, must expand surface bbox (geometry uses it
        // for surface bounds), else z>0 children overflow parent frame get clipped by texture edge.
        const r = child.rectFromWorldOrFallback();
        if (r.w <= 0 or r.h <= 0) continue;
        const cx = r.x + child.style.translate_x + child.frame_state.frame_local.runtime.sticky.x;
        const cy = r.y + child.style.translate_y + child.frame_state.frame_local.runtime.sticky.y;
        const rect = types.ComputedRect.init(cx, cy, r.w, r.h);
        // A minimum margin for ink that styles do not describe (glyph overhang, AA).
        var ink = types.ComputedRect.init(cx - children_ink_margin, cy - children_ink_margin, r.w + children_ink_margin * 2, r.h + children_ink_margin * 2);
        ink = unionComputed(ink, paintedRect(&child.style, rect));
        if (!child.style.overflow_hidden) {
            if (child.layoutOutputPtr()) |child_lo| if (child_lo.artifacts.children_bbox) |nested| {
                ink = unionComputed(ink, types.ComputedRect.init(cx + nested.x, cy + nested.y, nested.w, nested.h));
            };
        }
        bbox = if (bbox) |b| unionComputed(b, ink) else ink;
    }
    lo.artifacts.children_bbox = bbox;
}

const children_ink_margin: f32 = 8;

/// `rect` plus what `style` paints beyond it: each shadow layer (blur on both sides, positive
/// spread, offset) and the outline. Same extent rule as the opacity-layer bounds.
fn paintedRect(style: anytype, rect: types.ComputedRect) types.ComputedRect {
    var out = rect;
    for (style.shadowSlice()) |shadow| {
        const grow = shadow.blur * 2 + @max(@as(f32, 0), shadow.spread);
        out = unionComputed(out, types.ComputedRect.init(rect.x + shadow.offset_x - grow, rect.y + shadow.offset_y - grow, rect.w + grow * 2, rect.h + grow * 2));
    }
    if (style.outline()) |o| {
        const m = @max(@as(f32, 0), o.offset + o.width);
        out = unionComputed(out, types.ComputedRect.init(rect.x - m, rect.y - m, rect.w + m * 2, rect.h + m * 2));
    }
    return out;
}

fn unionComputed(a: types.ComputedRect, b: types.ComputedRect) types.ComputedRect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    return types.ComputedRect.init(x0, y0, @max(a.x + a.w, b.x + b.w) - x0, @max(a.y + a.h, b.y + b.h) - y0);
}

/// batch reverse: mirror-flip direct children's position on main axis,
/// in relative coords only direct children's rect changes, no O(N) recursive descendant offset
fn batchReverseChildren(
    children: []*Node,
    comptime is_row: bool,
    main_start: f32,
    main_end: f32,
) void {
    for (children) |child| {
        if (isOutOfFlow(child)) continue;
        const child_size = if (is_row) child.rectFromWorldOrFallback().w else child.rectFromWorldOrFallback().h;
        const new_pos = main_start + (main_end - ((if (is_row) child.rectFromWorldOrFallback().x else child.rectFromWorldOrFallback().y) - main_start + child_size));

        // position change must mark dirty: descendants' world coords accumulate from ancestor
        // chain,
        // parent moved but not marked dirty -> entire subtree carries stale coords to next frame
        // (hit test, clipping, compositing all misaligned). layout loop has same check, missed
        // here.
        const old_pos = if (is_row) child.rectFromWorldOrFallback().x else child.rectFromWorldOrFallback().y;
        if (old_pos != new_pos) {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        if (is_row) {
            child.setLayoutX(new_pos);
        } else {
            child.setLayoutY(new_pos);
        }
    }
}

fn lineBaseline(children: []*Node, row: bool, align_items: AlignItems, reverse: bool) f32 {
    var result: f32 = -std.math.inf(f32);
    for (children) |child| {
        if (isOutOfFlow(child) or crossAutoMargins(child, row) or !baselineAlign(resolveCrossAlign(child, align_items))) continue;
        const r = child.rectFromWorldOrFallback();
        const size = if (row) r.h else r.w;
        const baseline = firstBaseline(child, row, 0);
        const m = flexCrossMargins(child, row, reverse, 0);
        result = @max(result, m.start + if (reverse) size - baseline else baseline);
    }
    return if (result == -std.math.inf(f32)) 0 else result;
}

fn flexCrossMargins(child: *Node, row: bool, reverse: bool, available: f32) ResolvedAxisMargins {
    const m = child.style.marginSpec();
    const size = if (row) child.rectFromWorldOrFallback().h else child.rectFromWorldOrFallback().w;
    const start_auto = if (row) child.style.marginTopIsAuto() else child.style.marginLeftIsAuto();
    const end_auto = if (row) child.style.marginBottomIsAuto() else child.style.marginRightIsAuto();
    const start = if (row) m.top else m.left;
    const end = if (row) m.bottom else m.right;
    // §9.6: overflow ignores auto on the physical start side; end takes the
    // deficit. Do this in physical coordinates even for wrap-reverse.
    const resolved = resolveAxisMargins(available, size, start, end, start_auto, end_auto);
    if (!reverse) return resolved;
    if (start_auto or end_auto) {
        const physical_start = resolved.start;
        return .{ .start = available - size - physical_start, .end = physical_start };
    }
    return .{ .start = end, .end = start };
}

const FlexLine = struct { start: usize, end: usize, cross: f32 = 0 };

fn layoutChildrenWrap(parent: *Node, available: Size, ctx: LayoutContext) void {
    if (parent.style.direction.isRow()) layoutChildrenWrapImpl(parent, available, true, ctx) else layoutChildrenWrapImpl(parent, available, false, ctx);
}

fn layoutChildrenWrapImpl(parent: *Node, available: Size, comptime row: bool, ctx: LayoutContext) void {
    const style = parent.style;
    const children = parent.children.items;
    const main = if (row) available.width else available.height;
    const cross = if (row) available.height else available.width;
    const reverse = style.flex_wrap() == .wrap_reverse;
    var count: usize = 0;
    for (children) |child| {
        if (isDisplayNone(child)) collapseDisplayNone(child) else if (child.style.position == .absolute) layoutAbsoluteChild(parent, child, ctx) else {
            count += 1;
        }
    }
    parent.frame_state.first_flex_line_end = children.len;
    if (count == 0) return;
    var stack_items: [flex_stack_capacity]FlexItem = undefined;
    var stack_nodes: [flex_stack_capacity]*Node = undefined;
    var stack_lines: [flex_stack_capacity]FlexLine = undefined;
    const items = if (count <= stack_items.len) stack_items[0..count] else ctx.frame_allocator.alloc(FlexItem, count) catch {
        layout_alloc_failure_hits +|= 1;
        std.log.warn("[wrap] flex scratch allocation failed; using clamped bases without wrapping or redistribution", .{});
        layoutChildrenSingle(parent, available, ctx, false);
        return;
    };
    defer if (count > stack_items.len) ctx.frame_allocator.free(items);
    const lines = if (count <= stack_lines.len) stack_lines[0..count] else ctx.frame_allocator.alloc(FlexLine, count) catch {
        layout_alloc_failure_hits +|= 1;
        std.log.warn("[wrap] line scratch allocation failed; using clamped bases without wrapping or redistribution", .{});
        layoutChildrenSingle(parent, available, ctx, false);
        return;
    };
    defer if (count > stack_lines.len) ctx.frame_allocator.free(lines);
    const flow = if (count <= stack_nodes.len) stack_nodes[0..count] else ctx.frame_allocator.alloc(*Node, count) catch {
        layout_alloc_failure_hits +|= 1;
        std.log.warn("[wrap] node scratch allocation failed; using clamped bases without wrapping or redistribution", .{});
        layoutChildrenSingle(parent, available, ctx, false);
        return;
    };
    defer if (count > stack_nodes.len) ctx.frame_allocator.free(flow);
    // §9.3: collect by outer hypothetical size, before flexing each line.
    var n: usize = 0;
    var used: f32 = 0;
    var start: usize = 0;
    var index: usize = 0;
    for (children, 0..) |child, raw_index| {
        if (isOutOfFlow(child)) continue;
        flow[index] = child;
        items[index] = makeFlexItem(child, row, available);
        const outer = items[index].target + childMarginForAxis(child, row);
        if (index > start and used + style.gap + outer > main) {
            if (n == 0) parent.frame_state.first_flex_line_end = raw_index;
            lines[n] = .{ .start = start, .end = index };
            n += 1;
            start = index;
            used = 0;
        }
        if (index > start) used += style.gap;
        used += outer;
        // Store a flow-only index -> child mapping without another allocation:
        // lines refer to flow slots; traversal below skips out-of-flow nodes.
        index += 1;
    }
    lines[n] = .{ .start = start, .end = count };
    n += 1;
    var total_cross: f32 = if (n > 1) @as(f32, @floatFromInt(n - 1)) * style.gap else 0;
    for (lines[0..n]) |*line| {
        var fixed: f32 = @as(f32, @floatFromInt(line.end - line.start - 1)) * style.gap;
        for (flow[line.start..line.end]) |child| fixed += childMarginForAxis(child, row);
        resolveFlexibleLengths(items[line.start..line.end], main - fixed);
        // Lay out at resolved main size with natural, clamped cross size.
        // This makes wrapped text and nested containers contribute their actual
        // hypothetical cross size instead of a pre-flex intrinsic estimate.
        index = 0;
        // Leading and margins can put a baseline outside its outer line box.
        // Keep the signed distances; clamping either side to zero inflates the
        // line (e.g. Lora line-height:.5 becomes 19px instead of 17px).
        var before: f32 = -std.math.inf(f32);
        var after: f32 = -std.math.inf(f32);
        for (flow[line.start..line.end], line.start..) |child, item_index| {
            index = item_index;
            const target = items[index].target;
            var natural = aspectCrossSize(child, row, target, resolveCrossAxisSize(child, row, available, .start));
            if (row) {
                if (computeWrapTextLayoutForWidth(child, target)) |h| {
                    if (child.style.height == .grow or child.style.height == .fit) {
                        const mm = effectiveMinMax(child.style.height, child, false);
                        natural = @max(mm.min, @min(h, mm.max));
                    }
                }
            }
            setFlexSize(child, row, target, natural);
            var child_ctx = ctx;
            child_ctx.defer_mount = true;
            child_ctx.frozen_node = child;
            child_ctx.frozen_axis_is_width = row;
            child_ctx.frozen_both_axes = child.style.aspect_ratio() > 0;
            if (needsFlexLayout(child, child_ctx))
                layoutNode(child, Size.init(if (row) target else natural, if (row) natural else target), child_ctx);
            const size = if (row) child.rectFromWorldOrFallback().h else child.rectFromWorldOrFallback().w;
            const m = flexCrossMargins(child, row, reverse, size + childMarginForAxis(child, !row));
            if (row and baselineAlign(resolveCrossAlign(child, style.align_items)) and !crossAutoMargins(child, row)) {
                const b = firstBaseline(child, row, 0);
                before = @max(before, m.start + if (reverse) size - b else b);
                after = @max(after, m.end + if (reverse) b else size - b);
            } else line.cross = @max(line.cross, size + childMarginForAxis(child, !row));
        }
        line.cross = @max(line.cross, before + after);
        total_cross += line.cross;
    }
    const cross_sizing = if (row) style.height else style.width;
    const frozen_cross = ctx.frozen_node == parent and (ctx.frozen_both_axes or ctx.frozen_axis_is_width != row);
    var final_cross = cross;
    if (cross_sizing == .fit and !frozen_cross) {
        const pad = if (row) style.contentInsets().vertical() else style.contentInsets().horizontal();
        const mm = effectiveMinMax(cross_sizing, parent, !row);
        const size = @max(mm.min, @min(total_cross + pad, mm.max));
        if (row) parent.setLayoutH(size) else parent.setLayoutW(size);
        final_cross = size - pad;
    }
    const free = final_cross - total_cross;
    var line_distribution = Distribution{ .gap = style.gap };
    switch (style.align_content) {
        .normal, .stretch => if (free > 0) {
            for (lines[0..n]) |*line| line.cross += free / @as(f32, @floatFromInt(n));
        },
        .start => {},
        .end => line_distribution.offset = free,
        .center => line_distribution.offset = free / 2,
        .space_between => line_distribution = distribute(.space_between, free, n, style.gap),
        // Same flex-start overflow fallback as justify, mirrored by wrap-reverse.
        .space_around => line_distribution = distribute(.space_around, free, n, style.gap),
        .space_evenly => line_distribution = distribute(.space_evenly, free, n, style.gap),
    }
    const pad_main = if (row) style.contentInsets().left else style.contentInsets().top;
    const pad_cross = if (row) style.contentInsets().top else style.contentInsets().left;
    var cross_cursor = line_distribution.offset;
    for (lines[0..n]) |line| {
        used = @as(f32, @floatFromInt(line.end - line.start - 1)) * style.gap;
        var autos: usize = 0;
        index = 0;
        var baseline: f32 = -std.math.inf(f32);
        for (flow[line.start..line.end], line.start..) |child, item_index| {
            index = item_index;
            used += items[index].target + childMarginForAxis(child, row);
            autos += if (row) @as(usize, @intFromBool(child.style.marginLeftIsAuto())) + @intFromBool(child.style.marginRightIsAuto()) else @as(usize, @intFromBool(child.style.marginTopIsAuto())) + @intFromBool(child.style.marginBottomIsAuto());
            if (stretches(child, row, style.align_items)) {
                const line_available = if (row) Size.init(available.width, line.cross) else Size.init(line.cross, available.height);
                const size = resolveCrossAxisSize(child, row, line_available, .stretch);
                setFlexSize(child, row, items[index].target, size);
                var child_ctx = ctx;
                child_ctx.defer_mount = true;
                child_ctx.frozen_node = child;
                child_ctx.frozen_both_axes = true;
                child_ctx.frozen_axis_is_width = row;
                if (needsFlexLayout(child, child_ctx))
                    layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), child_ctx);
            }
            if (row and baselineAlign(resolveCrossAlign(child, style.align_items)) and !crossAutoMargins(child, row)) {
                const size = child.rectFromWorldOrFallback().h;
                const m = flexCrossMargins(child, row, reverse, line.cross);
                const b = firstBaseline(child, row, 0);
                baseline = @max(baseline, m.start + if (reverse) size - b else b);
            }
        }
        const remaining = main - used;
        const auto_unit = if (autos > 0 and remaining > 0) remaining / @as(f32, @floatFromInt(autos)) else 0;
        const distribution = distribute(if (auto_unit > 0) .start else style.justify, remaining, line.end - line.start, style.gap);
        var cursor = distribution.offset;
        index = 0;
        for (flow[line.start..line.end], line.start..) |child, item_index| {
            index = item_index;
            const r = child.rectFromWorldOrFallback();
            const size = if (row) r.h else r.w;
            const margins = flexMainMargins(child, row, style.direction.isReverse(), auto_unit);
            const m = flexCrossMargins(child, row, reverse, line.cross);
            const align_items = resolveCrossAlign(child, style.align_items);
            const extra = line.cross - size - childMarginForAxis(child, !row);
            const offset: f32 = if (crossAutoMargins(child, row)) 0 else switch (align_items) {
                .end => extra,
                .center => extra / 2,
                .baseline, .first_baseline => if (row) baseline - m.start - (if (reverse) size - firstBaseline(child, row, 0) else firstBaseline(child, row, 0)) else 0,
                else => 0,
            };
            const main_pos = if (style.direction.isReverse()) main - cursor - margins.start - items[index].target else cursor + margins.start;
            const logical_cross = cross_cursor + m.start + offset;
            const cross_pos = if (reverse) final_cross - logical_cross - size else logical_cross;
            const x = if (row) pad_main + main_pos else pad_cross + cross_pos;
            const y = if (row) pad_cross + cross_pos else pad_main + main_pos;
            if (r.x != x or r.y != y) child.frame_state.state_bits.dirty.core.layout = true;
            child.setLayoutX(x);
            child.setLayoutY(y);
            applyRelativeInset(child, available);
            // Publish mount only with final line placement. Descendants probed
            // above also receive a final layout before any callback can reenter.
            var final_ctx = ctx;
            final_ctx.frozen_node = child;
            final_ctx.frozen_axis_is_width = row;
            final_ctx.frozen_both_axes = stretches(child, row, style.align_items);
            if (needsFlexLayout(child, final_ctx))
                layoutNode(child, Size.init(r.w, r.h), final_ctx);
            cursor += items[index].target + margins.start + margins.end + distribution.gap;
        }
        cross_cursor += line.cross + line_distribution.gap;
    }
}

fn applyRelativeInset(child: *Node, available: Size) void {
    if (child.style.position != .relative) return;
    const inset = child.style.inset();
    const dx = inset.left.resolve(available.width) orelse -(inset.right.resolve(available.width) orelse 0);
    const dy = inset.top.resolve(available.height) orelse -(inset.bottom.resolve(available.height) orelse 0);
    const r = child.rectFromWorldOrFallback();
    child.setLayoutX(r.x + dx);
    child.setLayoutY(r.y + dy);
}

fn needsFlexLayout(child: *Node, ctx: LayoutContext) bool {
    const bits = child.frame_state.state_bits;
    return bits.dirty.core.layout or bits.dirty.core.subtree_layout or
        (!ctx.defer_mount and !bits.flags.is_mounted);
}

// A changed natural cross size affects line sizes, sibling alignment and
// exported baselines even when the child's main size is fixed.
fn crossDependentDirty(parent: *Node) bool {
    const wrap = parent.style.flex_wrap() != .no_wrap;
    const row = parent.style.direction.isRow();
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const bits = child.frame_state.state_bits.dirty.core;
        if (!bits.layout and !bits.subtree_layout) continue;
        if (wrap) {
            // Deep changes can alter hypothetical main sizes or automatic
            // minima and hence line membership. Fixed non-shrinking px items
            // with auto basis are independent of descendant intrinsic sizes.
            const main = if (row) child.style.width else child.style.height;
            if (main != .px or child.style.flex_basis() != types.FlexBasis.auto or child.style.flex_shrink > 0) return true;
        }
        if (baselineAlign(resolveCrossAlign(child, parent.style.align_items))) return true;
        const cross = if (row) child.style.height else child.style.width;
        if ((cross == .fit or cross == .grow) and (wrap or !stretches(child, row, parent.style.align_items))) return true;
    }
    return false;
}

// Incremental subtree layout must preserve the same allocated dimensions as
// full flex layout. Otherwise a stretched fit child shrinks on the next dirty
// descendant update, although the parent's constraints did not change.
fn relayoutFlexChild(parent: *Node, child: *Node, ctx: LayoutContext) void {
    var child_ctx = ctx;
    child_ctx.frozen_node = child;
    child_ctx.frozen_axis_is_width = parent.style.direction.isRow();
    child_ctx.frozen_both_axes = stretches(child, parent.style.direction.isRow(), parent.style.align_items);
    const r = child.rectFromWorldOrFallback();
    layoutNode(child, Size.init(r.w, r.h), child_ctx);
}

fn setFlexSize(child: *Node, row: bool, main: f32, cross: f32) void {
    const w = if (row) main else cross;
    const h = if (row) cross else main;
    const old = child.rectFromWorldOrFallback();
    if (old.w != w or old.h != h) child.frame_state.state_bits.dirty.core.layout = true;
    child.setLayoutW(w);
    child.setLayoutH(h);
}

// fitResizeAfterLayout function deleted.
// Equivalent logic inlined in layoutChildren (search "fit_resize_block:").
// True backfill elimination requires layoutNode signature change to LayoutInput + Constraint
// downward passing,
// that's v0.4-P1 later layoutNode complete rewrite work (continuing in v0.5).

/// Absolute child layout (supports the CSS inset positioning model)
///
/// Positioning priority: inset > static-position-origin (margin only corrects, never positions)
/// - left + right both set -> width=grow stretches to fill the inset gap (CSS width:auto);
///   px/percent/fit still resolve themselves (fit = intrinsic size, empty box is 0), the rest
///   goes to margin
/// - top + bottom both set -> same, height=grow stretches
/// - only one set -> offset from that side, size from width/height
/// - all auto -> containing block origin as static position origin, stack margin
///
/// In incremental layout, an absolute child must re-resolve its size (instead of just recursing
/// into the subtree with its old rect) when: its own layout is dirty; or its width/height is fit
/// and the subtree has layout changes. A fit size depends on descendants; if children are laid out
/// using the old rect as available space, shrinkable descendants get squeezed back to the old size
/// and the container only shrinks, never grows (Popover dropdown: height does not recover after
/// more rows are added).
fn absoluteChildNeedsResolve(child: *const Node) bool {
    const bits = child.frame_state.state_bits.dirty.core;
    if (bits.layout) return true;
    if (!bits.subtree_layout) return false;
    return child.style.width == .fit or child.style.height == .fit;
}

/// compute/cache wrapped text line breaks after width is set (shared by flex and absolute layout
/// paths,
/// absolute-positioned text nodes previously skipped wrapping, wrap always rendered single-line).
/// returns wrapped total height (with vertical padding), for fit height use; null if inapplicable.
fn computeWrapTextLayoutForWidth(child: *Node, child_width: f32) ?f32 {
    const t = child.resolveTextProps() orelse {
        child.clearTextLayout();
        return null;
    };
    if (t.layoutWrap() == .none) {
        child.clearTextLayout();
        return null;
    }
    const text_avail_w = child_width - child.style.contentInsets().horizontal();
    if (text_avail_w <= 0) return null;
    const layout_spans = if (t.spans_affect_layout) t.spans else &.{};
    // cache hit check (layoutOutputPtr gives stable address, isCacheValid takes *const)
    if (child.layoutOutputPtr()) |c_lo| {
        const need_recompute = if (c_lo.artifacts.text_layout) |tl|
            !text_layout.isCacheValid(tl, t.content, text_avail_w, t.font_weight, t.font_size, t.use_italic_font, t.use_monospace_font, t.layoutWrap(), t.max_lines, layout_spans)
        else
            true;
        if (need_recompute) {
            const computed = text_layout.computeTextLayout(
                t.content,
                text_avail_w,
                t.layoutWrap(),
                t.max_lines,
                t.font_size,
                t.line_height,
                t.font_weight,
                t.use_italic_font,
                t.use_monospace_font,
                layout_spans,
            );
            child.storeTextLayout(&computed) catch {
                layout_alloc_failure_hits += 1;
                child.clearTextLayout();
                child.frame_state.state_bits.dirty.core.layout = true;
                return computed.total_height + child.style.contentInsets().vertical();
            };
        }
    }
    if (child.layoutTextLayout()) |tl| {
        return tl.total_height + child.style.contentInsets().vertical();
    }
    return null;
}

fn establishesAbsoluteContainingBlock(node: *const Node) bool {
    return node.style.position != .static or node.style.layout_isolation or
        node.style.translate_x != 0 or node.style.translate_y != 0 or
        node.style.scale_x() != 1 or node.style.scale_y() != 1 or node.style.rotate() != 0 or
        node.style.will_change_transform();
}

fn layoutAbsoluteChild(parent: *Node, child: *Node, ctx: LayoutContext) void {
    const inset = child.style.inset();
    const margin = child.style.marginSpec();
    const wm = effectiveMinMax(child.style.width, child, true);
    const hm = effectiveMinMax(child.style.height, child, false);

    // Nearest positioned ancestor establishes its padding-box containing block.
    // Keep the child rect local to its actual (possibly static) parent.
    var cb = parent;
    var offset_x: f32 = 0;
    var offset_y: f32 = 0;
    while (!establishesAbsoluteContainingBlock(cb)) {
        const ancestor = cb.parent orelse break;
        const rect = cb.rectFromWorldOrFallback();
        offset_x += rect.x;
        offset_y += rect.y;
        cb = ancestor;
    }
    const initial = !establishesAbsoluteContainingBlock(cb) and cb.parent == null;
    const border = if (initial or cb.style.border.overlay) [4]f32{ 0, 0, 0, 0 } else cb.style.border.resolvedWidths();
    const parent_rect = cb.rectFromWorldOrFallback();
    const initial_size = ctx.initial_containing_block orelse Size.init(parent_rect.w, parent_rect.h);
    const cb_w = if (initial) initial_size.width else @max(@as(f32, 0), parent_rect.w - border[1] - border[3]);
    const cb_h = if (initial) initial_size.height else @max(@as(f32, 0), parent_rect.h - border[0] - border[2]);
    const cb_x = border[3] - offset_x - (if (initial) parent_rect.x else @as(f32, 0));
    const cb_y = border[0] - offset_y - (if (initial) parent_rect.y else @as(f32, 0));
    // Static position: a flex/block parent places the box at its content edge; a grid
    // container treats it as the sole item of an area spanning its padding edges
    // (CSS Grid 1 §9.1), so no padding is added there.
    const static_pad = !initial and parent.style.grid() == null;

    // --- horizontal axis ---
    const left_val = inset.left.resolve(cb_w);
    const right_val = inset.right.resolve(cb_w);

    var child_width: f32 = undefined;
    var new_x: f32 = undefined;

    if (left_val != null and right_val != null) {
        const available_outer = @max(0, cb_w - left_val.? - right_val.?);
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => @max(0, available_outer - child.style.marginHorizontal()),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        child_width = std.math.clamp(child_width, wm.min, wm.max);
        if (child.style.width == .grow) {
            new_x = left_val.? + (if (child.style.marginLeftIsAuto()) 0 else margin.left);
        } else {
            const resolved = resolveAxisMargins(
                available_outer,
                child_width,
                margin.left,
                margin.right,
                child.style.marginLeftIsAuto(),
                child.style.marginRightIsAuto(),
            );
            new_x = left_val.? + resolved.start;
        }
    } else if (left_val) |lv| {
        // only left -> offset from left side
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => @max(0, cb_w - lv - margin.horizontal()),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = lv + (if (child.style.marginLeftIsAuto()) 0 else margin.left);
    } else if (right_val) |rv| {
        // only right -> offset from right side
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => @max(0, cb_w - rv - margin.horizontal()),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = cb_w - rv - (if (child.style.marginRightIsAuto()) 0 else margin.right) - child_width;
    } else {
        // Static position starts at the containing block content edge; explicit
        // insets above continue to resolve against its padding box.
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => @max(0, @max(0, cb_w - margin.horizontal())),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = (if (static_pad) cb.style.padding.left else @as(f32, 0)) + (if (child.style.marginLeftIsAuto()) @as(f32, 0) else margin.left);
    }

    // --- vertical axis ---
    const top_val = inset.top.resolve(cb_h);
    const bottom_val = inset.bottom.resolve(cb_h);

    var child_height: f32 = undefined;
    var new_y: f32 = undefined;

    if (top_val != null and bottom_val != null) {
        const available_outer = @max(0, cb_h - top_val.? - bottom_val.?);
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => @max(0, available_outer - child.style.marginVertical()),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        child_height = std.math.clamp(child_height, hm.min, hm.max);
        if (child.style.height == .grow) {
            new_y = top_val.? + (if (child.style.marginTopIsAuto()) 0 else margin.top);
        } else {
            const resolved = resolveAxisMargins(
                available_outer,
                child_height,
                margin.top,
                margin.bottom,
                child.style.marginTopIsAuto(),
                child.style.marginBottomIsAuto(),
            );
            new_y = top_val.? + resolved.start;
        }
    } else if (top_val) |tv| {
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => @max(0, cb_h - tv - margin.vertical()),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = tv + (if (child.style.marginTopIsAuto()) 0 else margin.top);
    } else if (bottom_val) |bv| {
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => @max(0, cb_h - bv - margin.vertical()),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = cb_h - bv - (if (child.style.marginBottomIsAuto()) 0 else margin.bottom) - child_height;
    } else {
        // Static position starts at the containing block content edge; explicit
        // insets above continue to resolve against its padding box.
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => @max(0, @max(0, cb_h - margin.vertical())),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = (if (static_pad) cb.style.padding.top else @as(f32, 0)) + (if (child.style.marginTopIsAuto()) @as(f32, 0) else margin.top);
    }

    // independent min/max constraint clamp
    child_width = std.math.clamp(child_width, wm.min, wm.max);
    child_height = std.math.clamp(child_height, hm.min, hm.max);

    const ratio = child.style.aspect_ratio();
    if (ratio > 0) {
        if (child.style.height != .px and child.style.height != .percent and !(top_val != null and bottom_val != null and child.style.height == .grow)) {
            child_height = std.math.clamp(child_width / ratio, hm.min, hm.max);
        } else if (child.style.width != .px and child.style.width != .percent and !(left_val != null and right_val != null and child.style.width == .grow)) {
            child_width = std.math.clamp(child_height * ratio, wm.min, wm.max);
        }
    }

    // text wrapping: absolute text nodes also wrap after definite width (canvas overlay label
    // scenario)
    if (computeWrapTextLayoutForWidth(child, child_width)) |wrapped_h| {
        if (child.style.height == .fit) {
            child_height = std.math.clamp(wrapped_h, hm.min, hm.max);
        }
    }

    if (child.rectFromWorldOrFallback().w != child_width or child.rectFromWorldOrFallback().h != child_height or
        child.rectFromWorldOrFallback().x != new_x or child.rectFromWorldOrFallback().y != new_y)
    {
        child.frame_state.state_bits.dirty.core.layout = true;
    }
    new_x += cb_x;
    new_y += cb_y;
    child.setLayoutX(new_x);
    child.setLayoutY(new_y);
    child.setLayoutW(child_width);
    child.setLayoutH(child_height);
    var child_ctx = ctx;
    if (ratio > 0) {
        child_ctx.frozen_node = child;
        child_ctx.frozen_both_axes = true;
    }
    layoutNode(child, Size.init(child_width, child_height), child_ctx);

    // absolute + fit height correction: text_layout not generated during calcIntrinsicSize,
    // causing wrapped text fit height underestimated as single-line.
    // after layoutNode completes text shaping executes, re-read child's actual content height and
    // update child.rect.h.
    if (ratio <= 0 and child.style.height == .fit and top_val == null and bottom_val == null and child.children.items.len > 0) {
        var actual_content: f32 = 0;
        const child_is_row = child.style.direction.isRow();
        for (child.children.items) |gc| {
            if (isOutOfFlow(gc)) continue;
            if (child_is_row) {
                actual_content = @max(actual_content, gc.rectFromWorldOrFallback().h + gc.style.marginVertical());
            } else {
                actual_content += gc.rectFromWorldOrFallback().h + gc.style.marginVertical();
            }
        }
        if (!child_is_row) {
            const abs_flow_n = blk: {
                var n: usize = 0;
                for (child.children.items) |gc| {
                    if (gc.style.position != .absolute) n += 1;
                }
                break :blk n;
            };
            if (abs_flow_n > 1) actual_content += @as(f32, @floatFromInt(abs_flow_n - 1)) * child.style.gap;
        }
        actual_content += child.style.contentInsets().vertical();
        const mm = effectiveMinMax(child.style.height, child, false);
        const fit_h = std.math.clamp(actual_content, @max(0, mm.min), mm.max);
        if (fit_h != child.rectFromWorldOrFallback().h) {
            child.setLayoutH(fit_h);
        }
    }

    // anchor right / anchor bottom only: above calculated x / y before layout using pre-layout size
    // (fit is pre-wrap single-line estimate); subtree layout's wrap backfill may change final size,
    // re-anchor by final size, else bottom-right positioned panel overflows containing block
    // (storybook GlassAdapt regular panel: bottom 20 but edge out 22 pt).
    if (left_val == null) if (right_val) |rv| {
        const x = cb_x + cb_w - rv - (if (child.style.marginRightIsAuto()) 0 else margin.right) - child.rectFromWorldOrFallback().w;
        if (x != new_x) child.setLayoutX(x);
    };
    if (top_val == null) if (bottom_val) |bv| {
        const y = cb_y + cb_h - bv - (if (child.style.marginBottomIsAuto()) 0 else margin.bottom) - child.rectFromWorldOrFallback().h;
        if (y != new_y) child.setLayoutY(y);
    };
}

fn layoutChildren(parent: *Node, available: Size, ctx: LayoutContext) void {
    const style = parent.style;
    // wrap mode: row-by-row (line-broken) layout
    if (style.flex_wrap() != .no_wrap) {
        layoutChildrenWrap(parent, available, ctx);
        return;
    }

    layoutChildrenSingle(parent, available, ctx, true);
}

// OOM in either flex path uses clamped bases with no redistribution. Wrap also
// degrades to one line, so no allocation or partly published line state is needed.
fn layoutChildrenSingle(parent: *Node, available: Size, initial_ctx: LayoutContext, comptime scratch: bool) void {
    var ctx = initial_ctx;
    parent.frame_state.first_flex_line_end = parent.children.items.len;
    const style = parent.style;
    const is_row = style.direction.isRow();
    var flow_count: usize = 0;
    var flex_total: f32 = 0;
    var main_auto_margin_count: usize = 0;
    var margin_space: f32 = 0;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        flow_count += 1;
        const sizing = if (is_row) child.style.width else child.style.height;
        if (sizing == .grow) flex_total += @max(0, child.style.flex);
        margin_space += if (is_row) child.style.marginHorizontal() else child.style.marginVertical();
        if (is_row) {
            if (child.style.marginLeftIsAuto()) main_auto_margin_count += 1;
            if (child.style.marginRightIsAuto()) main_auto_margin_count += 1;
        } else {
            if (child.style.marginTopIsAuto()) main_auto_margin_count += 1;
            if (child.style.marginBottomIsAuto()) main_auto_margin_count += 1;
        }
    }
    const main_is_fit = if (is_row) style.width == .fit else style.height == .fit;
    const cross_is_fit = if (is_row) style.height == .fit else style.width == .fit;
    const frozen_cross = ctx.frozen_node == parent and (ctx.frozen_both_axes or ctx.frozen_axis_is_width != is_row);
    const natural_cross = cross_is_fit and !frozen_cross;

    const gap_count: f32 = if (flow_count > 1) @floatFromInt(flow_count - 1) else 0;
    const fixed_space = margin_space + gap_count * style.gap;
    const main_available = if (is_row) available.width else available.height;
    var flex_stack: [flex_stack_capacity]FlexItem = undefined;
    const items: []FlexItem = if (!scratch) &.{} else if (flow_count <= flex_stack.len) flex_stack[0..flow_count] else ctx.frame_allocator.alloc(FlexItem, flow_count) catch blk: {
        layout_alloc_failure_hits +|= 1;
        std.log.warn("[flex] scratch alloc failed (flow_count={d}), using clamped bases without redistribution", .{flow_count});
        // No partially initialized scratch escapes. OOM keeps clamped bases (no flex).
        break :blk &.{};
    };
    defer if (flow_count > flex_stack.len and items.len > 0) ctx.frame_allocator.free(items);
    // Degraded geometry is usable, but flow mounts wait for a successful
    // retry. In particular, a self-destroying mount must not run during this
    // provisional single-line pass, which still reads items during backfill.
    if (flow_count > 0 and items.len == 0) ctx.defer_mount = true;
    var used_space = fixed_space;
    var item_index: usize = 0;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const item = if (is_row) makeFlexItem(child, true, available) else makeFlexItem(child, false, available);
        if (item_index < items.len) {
            items[item_index] = item;
        } else {
            // OOM has no scratch storage. Publish the already-computed target
            // to its eventual layout slot and reuse it during placement; do
            // not run text/min-content measurement a second time.
            const old_main = if (is_row) child.rectFromWorldOrFallback().w else child.rectFromWorldOrFallback().h;
            if (old_main != item.target) child.frame_state.state_bits.dirty.core.layout = true;
            if (is_row) child.setLayoutW(item.target) else child.setLayoutH(item.target);
        }
        item_index += 1;
        used_space += item.target;
    }
    if (items.len > 0) {
        resolveFlexibleLengths(items, main_available - fixed_space);
        used_space = fixed_space;
        for (items) |item| used_space += item.target;
    }
    // A non-flexed fit main axis will backfill to its content. Predict that size
    // for positioning, so an unchanged relayout does not move children twice.
    const frozen_main = ctx.frozen_node == parent and (ctx.frozen_both_axes or ctx.frozen_axis_is_width == is_row);
    const justify_available = if (main_is_fit and flex_total == 0 and !frozen_main) blk: {
        const pad = if (is_row) style.contentInsets().horizontal() else style.contentInsets().vertical();
        const mm = if (is_row) effectiveMinMax(style.width, parent, true) else effectiveMinMax(style.height, parent, false);
        break :blk std.math.clamp(used_space + pad, mm.min, mm.max) - pad;
    } else main_available;
    const remaining = justify_available - used_space;
    const auto_margin_unit = if (main_auto_margin_count > 0 and remaining > 0)
        remaining / @as(f32, @floatFromInt(main_auto_margin_count))
    else
        0;
    const distribution = distribute(if (main_auto_margin_count > 0 and remaining > 0) .start else style.justify, remaining, flow_count, style.gap);
    const pad_start: f32 = if (is_row) style.contentInsets().left else style.contentInsets().top;
    const justify_offset = distribution.offset;
    const justify_gap = distribution.gap;

    var cursor: f32 = pad_start + justify_offset;
    var flex_idx: usize = 0;

    for (parent.children.items) |child| {
        if (isDisplayNone(child)) {
            collapseDisplayNone(child);
            continue;
        }
        // absolute children handled separately
        if (child.style.position == .absolute) {
            layoutAbsoluteChild(parent, child, ctx);
            continue;
        }

        const margin = child.style.marginSpec();
        const resolved_main_margins = flexMainMargins(child, is_row, style.direction.isReverse(), auto_margin_unit);
        var child_width: f32 = undefined;
        var child_height: f32 = undefined;

        // determine cross-axis alignment (align_self priority over align_items; no_cross_stretch
        // only downgrades inherited stretch)
        const cross_align = resolveCrossAlign(child, style.align_items);

        const target = if (flex_idx < items.len) items[flex_idx].target else if (is_row) child.rectFromWorldOrFallback().w else child.rectFromWorldOrFallback().h;
        const main_frozen = if (flex_idx < items.len) items[flex_idx].target != items[flex_idx].base or child.style.flex_basis() >= 0 else true;
        flex_idx += 1;
        if (is_row) {
            child_width = target;
            child_height = resolveCrossAxisSize(child, true, available, if (natural_cross) .start else cross_align);
            const mm = effectiveMinMax(child.style.height, child, false);
            child_height = @max(mm.min, @min(child_height, mm.max));
        } else {
            child_height = target;
            child_width = resolveCrossAxisSize(child, false, available, if (natural_cross) .start else cross_align);
            const mm = effectiveMinMax(child.style.width, child, true);
            child_width = @max(mm.min, @min(child_width, mm.max));
        }

        if (natural_cross or !stretches(child, is_row, style.align_items)) {
            if (is_row) child_height = aspectCrossSize(child, true, child_width, child_height) else child_width = aspectCrossSize(child, false, child_height, child_width);
        }

        // text wrapping: compute line breaks after width fixed
        if (computeWrapTextLayoutForWidth(child, child_width)) |wrapped_h| {
            // fit height: use post-wrap total height
            if (is_row and (child.style.height == .fit or child.style.height == .grow) and (natural_cross or !stretches(child, true, style.align_items))) {
                const mm = effectiveMinMax(child.style.height, child, false);
                child_height = @max(mm.min, @min(wrapped_h, mm.max));
            }
        }

        // position (record old value first, for later marking dirty if changed)
        const old_child_x = child.rectFromWorldOrFallback().x;
        const old_child_y = child.rectFromWorldOrFallback().y;
        if (is_row) {
            const resolved_cross = resolveAxisMargins(
                available.height,
                child_height,
                margin.top,
                margin.bottom,
                child.style.marginTopIsAuto(),
                child.style.marginBottomIsAuto(),
            );
            child.setLayoutX(cursor + resolved_main_margins.start);
            child.setLayoutY(style.contentInsets().top + resolved_cross.start + switch (cross_align) {
                .center => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else (available.height - child.style.marginVertical() - child_height) / 2.0,
                .end => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else available.height - child.style.marginVertical() - child_height,
                else => 0,
            });
            cursor += child_width + resolved_main_margins.start + resolved_main_margins.end + justify_gap;
        } else {
            const resolved_cross = resolveAxisMargins(
                available.width,
                child_width,
                margin.left,
                margin.right,
                child.style.marginLeftIsAuto(),
                child.style.marginRightIsAuto(),
            );
            child.setLayoutX(style.contentInsets().left + resolved_cross.start + switch (cross_align) {
                .center => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else (available.width - child.style.marginHorizontal() - child_width) / 2.0,
                .end => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else available.width - child.style.marginHorizontal() - child_width,
                else => 0,
            });
            child.setLayoutY(cursor + resolved_main_margins.start);
            cursor += child_height + resolved_main_margins.start + resolved_main_margins.end + justify_gap;
        }

        // mark dirty on size or position change, ensure children recurse relayout
        if (child.rectFromWorldOrFallback().w != child_width or child.rectFromWorldOrFallback().h != child_height or
            child.rectFromWorldOrFallback().x != old_child_x or child.rectFromWorldOrFallback().y != old_child_y)
        {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        child.setLayoutW(child_width);
        child.setLayoutH(child_height);

        // A flexed/definite-basis main size must survive recursive fit backfill.
        var child_ctx = ctx;
        // A changed flex target (or definite basis, including zero) is authoritative.
        // Unflexed auto/content fit retains its intrinsic wrap backfill.
        const cross_stretched = (!natural_cross and stretches(child, is_row, style.align_items)) or child.style.aspect_ratio() > 0;
        child_ctx.frozen_node = if (main_frozen or cross_stretched) child else null;
        child_ctx.frozen_both_axes = main_frozen and cross_stretched;
        child_ctx.frozen_axis_is_width = if (main_frozen) is_row else !is_row;
        layoutNode(child, Size.init(child_width, child_height), child_ctx);

        // text wrap backfill correction: layoutNode internally may backfill child size due to
        // wrapped text in subtree,
        // cursor needs compensate by actual size delta, else later sibling positions wrong.
        if (is_row) {
            const actual_w = child.rectFromWorldOrFallback().w;
            if (actual_w != child_width) {
                cursor += actual_w - child_width;
            }
        } else {
            const actual_h = child.rectFromWorldOrFallback().h;
            if (actual_h != child_height) {
                cursor += actual_h - child_height;
            }
        }
    }

    // Text wrap backfill: the parent's fit size must be updated from the child's actual size
    // (text wrap is computed inside child layoutNode; text_layout is still null during
    // calcIntrinsicSize).
    //
    // True "backfill elimination" needs layoutNode to take LayoutInput + Constraint passed down,
    // which is a full layoutNode rewrite; this inline version preserves the old
    // fitResizeAfterLayout behavior exactly.
    fit_resize_block: {
        const pstyle_fit = parent.style;
        // when grow-axis ancestor on same axis is fit, grow has no allocable remaining, final size
        // is content size:
        // backfill by child actual size too—but only grow, never shrink (see w_grow_only below).
        // else fit > grow > ... > wrapped-text chain: wrap deepens inner layer, grow stops at
        // pre-wrap single-line height,
        // fit ancestor sums it—whole chain undersized (GlassBox root fit -> surface grow -> content
        // fit case,
        // wrapped body overflows glass lower edge). ancestor has fixed size don't touch: grow
        // should allocate by assigned space
        // (scroll areas depend on this).
        const gp_w_fit = if (parent.parent) |gp| gp.style.width == .fit else false;
        const gp_h_fit = if (parent.parent) |gp| gp.style.height == .fit else false;
        const w_fit = pstyle_fit.width == .fit or (pstyle_fit.width == .grow and gp_w_fit);
        const h_fit = pstyle_fit.height == .fit or (pstyle_fit.height == .grow and gp_h_fit);
        const main_fit = if (is_row) w_fit else h_fit;
        const cross_fit = if (is_row) h_fit else w_fit;
        // grow axis grow-only: cross-axis stretched grow node (panel in fit row / divider) backfill
        // by self content shrinks first,
        // this function's final alignment pass places children by shrunken size (center offset
        // becomes 0);
        // fit ancestor re-stretches it but won't re-layout children -> content aligned edge
        // (storybook GlassBox Materials
        // one row left-shifted 24 pt, tested).
        const w_grow_only = pstyle_fit.width == .grow;
        const h_grow_only = pstyle_fit.height == .grow;
        const cur_w = parent.rectFromWorldOrFallback().w;
        const cur_h = parent.rectFromWorldOrFallback().h;
        if (!main_fit and !cross_fit) break :fit_resize_block;
        // Parent flex allocation locked this axis (see LayoutContext.frozen_node).
        const frozen_here = ctx.frozen_node == parent;
        const skip_w = frozen_here and (ctx.frozen_axis_is_width or ctx.frozen_both_axes);
        const skip_h = frozen_here and (!ctx.frozen_axis_is_width or ctx.frozen_both_axes);

        var actual_main: f32 = 0;
        var actual_cross: f32 = 0;
        var flow_n: usize = 0;
        for (parent.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            const child_main = if (is_row) child.rectFromWorldOrFallback().w + child.style.marginHorizontal() else child.rectFromWorldOrFallback().h + child.style.marginVertical();
            const child_cross = if (is_row) child.rectFromWorldOrFallback().h + child.style.marginVertical() else child.rectFromWorldOrFallback().w + child.style.marginHorizontal();
            actual_main += child_main;
            actual_cross = @max(actual_cross, child_cross);
            flow_n += 1;
        }
        if (is_row) {
            const before = lineBaseline(parent.children.items, true, style.align_items, false);
            var after: f32 = -std.math.inf(f32);
            for (parent.children.items) |child| {
                if (isOutOfFlow(child) or crossAutoMargins(child, true) or !baselineAlign(resolveCrossAlign(child, style.align_items))) continue;
                after = @max(after, child.style.margin.bottom + child.rectFromWorldOrFallback().h - firstBaseline(child, true, 0));
            }
            actual_cross = @max(actual_cross, before + after);
        }
        if (flow_n > 1) actual_main += @as(f32, @floatFromInt(flow_n - 1)) * pstyle_fit.gap;

        if (main_fit) {
            const new_main = actual_main + (if (is_row) pstyle_fit.contentInsets().horizontal() else pstyle_fit.contentInsets().vertical());
            if (is_row) {
                const mm = effectiveMinMax(pstyle_fit.width, parent, true);
                const v = std.math.clamp(new_main, mm.min, mm.max);
                if (!skip_w) parent.setLayoutW(if (w_grow_only) @max(cur_w, v) else v);
            } else {
                const mm = effectiveMinMax(pstyle_fit.height, parent, false);
                const v = std.math.clamp(new_main, mm.min, mm.max);
                if (!skip_h) parent.setLayoutH(if (h_grow_only) @max(cur_h, v) else v);
            }
        }
        if (cross_fit) {
            const new_cross = actual_cross + (if (is_row) pstyle_fit.contentInsets().vertical() else pstyle_fit.contentInsets().horizontal());
            if (is_row) {
                const mm = effectiveMinMax(pstyle_fit.height, parent, false);
                const v = std.math.clamp(new_cross, mm.min, mm.max);
                if (!skip_h) parent.setLayoutH(if (h_grow_only) @max(cur_h, v) else v);
            } else {
                const mm = effectiveMinMax(pstyle_fit.width, parent, true);
                const v = std.math.clamp(new_cross, mm.min, mm.max);
                if (!skip_w) parent.setLayoutW(if (w_grow_only) @max(cur_w, v) else v);
            }

            // backfill correction: after parent cross size growth, grow children cross axis need
            // re-stretch to new space
            const new_cross_avail = if (is_row)
                parent.rectFromWorldOrFallback().h - pstyle_fit.contentInsets().vertical()
            else
                parent.rectFromWorldOrFallback().w - pstyle_fit.contentInsets().horizontal();
            for (parent.children.items) |child| {
                if (isOutOfFlow(child)) continue;
                const cross_sizing = if (is_row) child.style.height else child.style.width;
                if ((cross_sizing == .grow or cross_sizing == .fit) and stretches(child, is_row, style.align_items)) {
                    const resolved = resolveCrossAxisSize(child, is_row, if (is_row) Size.init(available.width, new_cross_avail) else Size.init(new_cross_avail, available.height), .stretch);
                    const old = child.rectFromWorldOrFallback();
                    if ((if (is_row) old.h else old.w) != resolved) {
                        if (is_row) child.setLayoutH(resolved) else child.setLayoutW(resolved);
                        child.frame_state.state_bits.dirty.core.layout = true;
                        var stretched_ctx = ctx;
                        stretched_ctx.frozen_node = child;
                        stretched_ctx.frozen_both_axes = true;
                        stretched_ctx.frozen_axis_is_width = is_row;
                        layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), stretched_ctx);
                    }
                }
            }
        }
    }

    // main axis final positioning: when fit backfill changed parent main size (typical: fit-width
    // row ancestor-stretched
    // by column then justify offset calculated by stretch width, backfill shrinks to intrinsic
    // width),
    // justify/auto-margin offset from old main_available now invalid, content drifts out frame.
    // rerun main-axis positioning by final size + child actual size. child coords are
    // parent-relative,
    // translate doesn't affect subtree layout, no recursive relayout needed (O(children)).
    // Non-fit containers already used post-flex remaining space above. Only a
    // fit backfill can change the size used for their final positioning here.
    if (main_is_fit and flex_total == 0) {
        const final_main_available = if (is_row)
            parent.rectFromWorldOrFallback().w - style.contentInsets().horizontal()
        else
            parent.rectFromWorldOrFallback().h - style.contentInsets().vertical();
        if (final_main_available != main_available) {
            repositionMainAxis(parent, is_row, final_main_available, main_auto_margin_count);
        }
    }

    // Wrapping can change a child's cross size during recursion, and fit
    // backfill can then change its parent's size. Align using those final
    // dimensions; the preliminary alignment above used intrinsic estimates.
    const final_cross_available = if (is_row)
        parent.rectFromWorldOrFallback().h - style.contentInsets().vertical()
    else
        parent.rectFromWorldOrFallback().w - style.contentInsets().horizontal();
    const baseline = lineBaseline(parent.children.items, is_row, style.align_items, false);
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const cross_align = resolveCrossAlign(child, style.align_items);
        const child_cross = if (is_row) child.rectFromWorldOrFallback().h else child.rectFromWorldOrFallback().w;
        const margin = child.style.marginSpec();
        const start_auto = if (is_row) child.style.marginTopIsAuto() else child.style.marginLeftIsAuto();
        const end_auto = if (is_row) child.style.marginBottomIsAuto() else child.style.marginRightIsAuto();
        const start_margin = if (is_row) margin.top else margin.left;
        const end_margin = if (is_row) margin.bottom else margin.right;
        const resolved = resolveAxisMargins(final_cross_available, child_cross, start_margin, end_margin, start_auto, end_auto);
        const extra = final_cross_available - start_margin - end_margin - child_cross;
        const offset = if (start_auto or end_auto) 0 else switch (cross_align) {
            .center => extra / 2.0,
            .end => extra,
            .baseline, .first_baseline => if (is_row) baseline - start_margin - firstBaseline(child, true, 0) else 0,
            else => 0,
        };
        // same as batchReverseChildren: position change must mark dirty. this pass re-aligns by
        // final size,
        // usually matches pre-layout align (most cases won't trigger), but wrap / fit backfill
        // changing
        // cross size really moves children.
        const new_cross = if (is_row)
            style.contentInsets().top + resolved.start + offset
        else
            style.contentInsets().left + resolved.start + offset;
        const old_cross = if (is_row) child.rectFromWorldOrFallback().y else child.rectFromWorldOrFallback().x;
        if (old_cross != new_cross) {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        if (is_row) {
            child.setLayoutY(new_cross);
        } else {
            child.setLayoutX(new_cross);
        }
    }

    // reverse: mirror-flip child position on main axis (relative coords)
    if (style.direction.isReverse()) {
        const main_start = if (is_row) style.contentInsets().left else style.contentInsets().top;
        const main_end = if (is_row) parent.rectFromWorldOrFallback().w - style.contentInsets().right else parent.rectFromWorldOrFallback().h - style.contentInsets().bottom;

        if (is_row) {
            batchReverseChildren(parent.children.items, true, main_start, main_end);
        } else {
            batchReverseChildren(parent.children.items, false, main_start, main_end);
        }
    }
    for (parent.children.items) |child| {
        if (!isOutOfFlow(child)) applyRelativeInset(child, available);
    }
}

/// main axis final positioning after fit backfill (see layoutChildren call site). only call when
/// parent main axis fit,
/// no grow children, so space_* ineffective (is_space_mode requires main axis non-fit),
/// handle as start like first pass. use child actual sizes (includes wrap backfill).
fn repositionMainAxis(parent: *Node, is_row: bool, final_main_available: f32, main_auto_margin_count: usize) void {
    const style = parent.style;
    var used: f32 = 0;
    var flow_n: usize = 0;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const r = child.rectFromWorldOrFallback();
        const m = child.style.marginSpec();
        used += if (is_row) r.w else r.h;
        if (is_row) {
            if (!child.style.marginLeftIsAuto()) used += m.left;
            if (!child.style.marginRightIsAuto()) used += m.right;
        } else {
            if (!child.style.marginTopIsAuto()) used += m.top;
            if (!child.style.marginBottomIsAuto()) used += m.bottom;
        }
        flow_n += 1;
    }
    if (flow_n > 1) used += @as(f32, @floatFromInt(flow_n - 1)) * style.gap;

    const remaining = final_main_available - used;
    const auto_margin_unit = if (main_auto_margin_count > 0 and remaining > 0)
        remaining / @as(f32, @floatFromInt(main_auto_margin_count))
    else
        0;
    const distribution = distribute(if (main_auto_margin_count > 0 and remaining > 0) .start else style.justify, remaining, flow_n, style.gap);
    const justify_offset = distribution.offset;
    var cursor: f32 = (if (is_row) style.contentInsets().left else style.contentInsets().top) + justify_offset;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const r = child.rectFromWorldOrFallback();
        const main_margins = flexMainMargins(child, is_row, style.direction.isReverse(), auto_margin_unit);
        const start_m = main_margins.start;
        const end_m = main_margins.end;
        if (is_row) {
            child.setLayoutX(cursor + start_m);
            cursor += r.w + start_m + end_m + distribution.gap;
        } else {
            child.setLayoutY(cursor + start_m);
            cursor += r.h + start_m + end_m + distribution.gap;
        }
    }
}

// ========== Grid Layout ==========

const GridConfig = types.GridConfig;

const Placement = struct {
    col: usize = 0,
    row: usize = 0,
    col_span: usize = 0,
    row_span: usize = 0,
};

fn gridOverlaps(placements: []const Placement, p: Placement) bool {
    for (placements) |q| {
        if (q.col_span != 0 and p.col < q.col + q.col_span and q.col < p.col + p.col_span and
            p.row < q.row + q.row_span and q.row < p.row + p.row_span) return true;
    }
    return false;
}

const GridTrack = struct {
    base: f32 = 0,
    limit: f32 = std.math.inf(f32),
    growth: f32 = 0,
    flex: f32 = 0,
    frozen: bool = false,
    minimum: types.GridTrackSize.Minimum = .auto,
    maximum: types.GridTrackSize.Maximum = .auto,
    fn init(spec: types.GridTrackSize) GridTrack {
        const minimum: types.GridTrackSize.Minimum = switch (spec) {
            .px => |v| .{ .px = v },
            .fr, .auto => .auto,
            .minmax => |v| v.min,
        };
        const maximum: types.GridTrackSize.Maximum = switch (spec) {
            .px => |v| .{ .px = v },
            .fr => |v| .{ .fr = v },
            .auto => .auto,
            .minmax => |v| v.max,
        };
        const base = if (minimum == .px) @max(0, minimum.px) else 0;
        return .{ .base = base, .growth = base, .limit = if (maximum == .px) @max(base, maximum.px) else std.math.inf(f32), .flex = if (maximum == .fr) @max(0, maximum.fr) else 0, .minimum = minimum, .maximum = maximum };
    }
};

fn gridArea(tracks: []const GridTrack, start: usize, span: usize, gap: f32) f32 {
    var size = @as(f32, @floatFromInt(span - 1)) * gap;
    for (tracks[start..][0..span]) |t| size += t.base;
    return size;
}

const GridContribution = enum { minimum, max_content };

fn gridContribution(child: *Node, comptime width: bool, kind: GridContribution, cross: f32, automatic: bool) f32 {
    const sizing = if (width) child.style.width else child.style.height;
    const mm = effectiveMinMax(sizing, child, width);
    const ext = child.style.getExt();
    const own_min = switch (sizing) {
        .grow, .fit => |v| v.min,
        else => @as(f32, -1),
    };
    const raw_min = if (width) ext.min_width else ext.min_height;
    var content = if (kind == .max_content) calcIntrinsicSize(child, width) else flexMinContent(child, width);
    if (!width and child.resolveTextProps() != null)
        content = measureNode(child, .{ .definite_width = cross }).height;
    if (child.style.aspect_ratio() > 0) {
        const opposite = if (width) child.style.height else child.style.width;
        if (opposite == .px) content = @max(content, aspectTransfer(opposite.px, child.style.aspect_ratio(), width));
    }
    var value = switch (sizing) {
        .px => |v| v,
        .percent => @as(f32, 0), // indefinite intrinsic percentage
        .fit => content, // explicit max-content on the inline/main mapped axis
        .grow => if (kind != .minimum or (automatic and raw_min < 0 and own_min < 0 and !child.style.overflow_hidden and child.style.overflow == .visible)) content else mm.min,
    };
    value = std.math.clamp(value, mm.min, mm.max);
    return value + childMarginForAxis(child, width);
}

// Distribute an item's intrinsic contribution across eligible tracks. Process
// increasing spans so a spanning item sees all shorter items' established bases.
fn sizeGridTracks(parent: *Node, placements: []const Placement, tracks: []GridTrack, comptime width: bool, available: f32, cross_tracks: []const GridTrack) void {
    const gc = parent.style.grid().?;
    const gap = if (width) gc.column_gap else gc.row_gap;
    const cross_gap = if (width) gc.row_gap else gridTrackDistribution(parent, cross_tracks, true, @max(0, parent.rectFromWorldOrFallback().w - parent.style.contentInsets().horizontal())).gap;
    var max_span: usize = 1;
    for (placements) |p| max_span = @max(max_span, if (width) p.col_span else p.row_span);
    for (1..max_span + 1) |span| {
        for (parent.children.items, placements) |child, p| {
            if (p.col_span == 0 or (if (width) p.col_span else p.row_span) != span) continue;
            const start = if (width) p.col else p.row;
            const group = tracks[start..][0..span];
            var has_auto = false;
            var has_flex = false;
            for (group) |t| {
                has_auto = has_auto or t.minimum == .auto;
                has_flex = has_flex or t.flex > 0;
            }
            const automatic = has_auto and !(span > 1 and has_flex);
            const cross = if (width or cross_tracks.len == 0) @as(f32, 0) else gridArea(cross_tracks, p.col, p.col_span, cross_gap);
            // Automatic minima use minimum contributions. There is no separate
            // min-content track sizing keyword in this supported track subset.
            var weight: f32 = 0;
            var minimum_current = @as(f32, @floatFromInt(span - 1)) * gap;
            for (group) |t| {
                minimum_current += t.base;
                if (t.minimum == .auto) weight += if (has_flex and span > 1) t.flex else 1;
            }
            if (weight > 0) {
                const deficit = @max(0, gridContribution(child, width, .minimum, cross, automatic) - minimum_current);
                for (group) |*t| {
                    // CSS Grid §12.5 step 4 distributes spanning flex deficits
                    // to flexible tracks in proportion to their flex factors.
                    if (t.minimum == .auto) t.base += deficit * (if (has_flex and span > 1) t.flex else @as(f32, 1)) / weight;
                    t.limit = @max(t.base, t.limit);
                }
            }
            var current = @as(f32, @floatFromInt(span - 1)) * gap;
            var count: usize = 0;
            for (group) |t| {
                current += @max(t.base, t.growth);
                if (t.maximum == .auto) count += 1;
            }
            if (count > 0) {
                const desired = gridContribution(child, width, .max_content, cross, automatic);
                const delta = @max(0, desired - current) / @as(f32, @floatFromInt(count));
                for (group) |*t| if (t.maximum == .auto) {
                    t.growth = @max(t.base, t.growth) + delta;
                };
            }
        }
    }
    var free = available - @as(f32, @floatFromInt(tracks.len - 1)) * gap;
    for (tracks) |*t| {
        t.growth = @max(t.base, if (t.maximum == .px) t.limit else t.growth);
        free -= t.base;
    }
    // Maximize non-flex tracks, respecting finite growth limits.
    for (0..tracks.len + 1) |_| {
        var count: usize = 0;
        for (tracks) |t| if (t.flex == 0 and t.base < t.growth) {
            count += 1;
        };
        if (free <= 0 or count == 0) break;
        const share = free / @as(f32, @floatFromInt(count));
        for (tracks) |*t| if (t.flex == 0 and t.base < t.growth) {
            const delta = @min(share, t.growth - t.base);
            t.base += delta;
            free -= delta;
        };
    }
    // Find the fr size; tracks whose base exceeds their share freeze and return
    // to the non-flex set. Factors below one retain unused free space (§12.7).
    var fraction: f32 = 0;
    for (0..tracks.len + 1) |_| {
        var space = available - @as(f32, @floatFromInt(tracks.len - 1)) * gap;
        var factors: f32 = 0;
        for (tracks) |t| {
            if (t.flex > 0 and !t.frozen) factors += t.flex else space -= t.base;
        }
        fraction = @max(0, space) / @max(1, factors);
        var changed = false;
        for (tracks) |*t| {
            if (t.flex > 0 and !t.frozen and t.base > fraction * t.flex) {
                t.frozen = true;
                changed = true;
            }
        }
        if (!changed) break;
    }
    free = available - @as(f32, @floatFromInt(tracks.len - 1)) * gap;
    var autos: usize = 0;
    for (tracks) |*t| {
        if (t.flex > 0 and !t.frozen) t.base = @max(t.base, fraction * t.flex);
        free -= t.base;
        if (t.maximum == .auto) autos += 1;
    }
    // Default justify-content/align-content normal stretches auto tracks only.
    const stretch = !width and (parent.style.align_content == .normal or parent.style.align_content == .stretch);
    if (stretch and free > 0 and autos > 0) for (tracks) |*t| {
        if (t.maximum == .auto) t.base += free / @as(f32, @floatFromInt(autos));
    };
}

fn gridTrackDistribution(parent: *Node, tracks: []const GridTrack, width: bool, available: f32) Distribution {
    const gc = parent.style.grid().?;
    const gap = if (width) gc.column_gap else gc.row_gap;
    var used = @as(f32, @floatFromInt(tracks.len - 1)) * gap;
    for (tracks) |t| used += t.base;
    const justify: types.JustifyContent = if (width) parent.style.justify else switch (parent.style.align_content) {
        .normal, .stretch, .start => .start,
        .end => .end,
        .center => .center,
        .space_between => .space_between,
        .space_around => .space_around,
        .space_evenly => .space_evenly,
    };
    return distribute(justify, available - used, tracks.len, gap);
}

fn layoutChildrenGrid(parent: *Node, available: Size, ctx: LayoutContext) void {
    const gc = parent.style.grid() orelse return;
    const children = parent.children.items;
    if (children.len == 0 or gc.column_count == 0) return;
    const a = ctx.frame_allocator;
    const placements = a.alloc(Placement, children.len) catch {
        layout_alloc_failure_hits +|= 1;
        return;
    };
    defer a.free(placements);
    @memset(placements, .{});
    var cols: usize = @min(gc.column_count, GridConfig.MAX_TRACKS);
    var rows: usize = @min(gc.row_count, GridConfig.MAX_TRACKS);
    // Determine the implicit column range before auto placement (§8.5 step 3).
    for (children) |child| {
        if (isOutOfFlow(child)) continue;
        const gp = child.style.grid_placement() orelse types.GridPlacement{};
        cols = @max(cols, @as(usize, gp.col_start -| 1) + @max(1, @as(usize, gp.col_span)));
    }
    // Definite positions, then row-locked items, then sparse row-major cursor.
    for (0..3) |pass| {
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;
        for (children, 0..) |child, i| {
            if (isOutOfFlow(child)) continue;
            const gp = child.style.grid_placement() orelse types.GridPlacement{};
            const phase: usize = if (gp.row_start > 0 and gp.col_start > 0) 0 else if (gp.row_start > 0) 1 else 2;
            if (phase != pass) continue;
            var p = Placement{ .col = gp.col_start -| 1, .row = gp.row_start -| 1, .col_span = @max(1, @as(usize, gp.col_span)), .row_span = @max(1, @as(usize, gp.row_span)) };
            if (pass == 1) {
                // §8.5 sparse row-locked placement stays past prior items placed
                // by this step; only dense packing would backfill their holes.
                for (children[0..i], placements[0..i]) |earlier, q| {
                    const egp = earlier.style.grid_placement() orelse continue;
                    if (q.col_span > 0 and egp.row_start == gp.row_start and egp.col_start == 0)
                        p.col = @max(p.col, q.col + q.col_span);
                }
                while (gridOverlaps(placements, p)) p.col += 1;
                cols = @max(cols, p.col + p.col_span);
            } else if (pass == 2) {
                p.row = cursor_row;
                if (gp.col_start > 0) {
                    if (p.col < cursor_col) p.row += 1;
                    while (gridOverlaps(placements, p)) p.row += 1;
                } else {
                    p.col = cursor_col;
                    while (true) {
                        if (p.col + p.col_span > cols) {
                            p.col = 0;
                            p.row += 1;
                        }
                        if (!gridOverlaps(placements, p)) break;
                        p.col += 1;
                    }
                }
                cursor_row = p.row;
                cursor_col = p.col;
            }
            placements[i] = p;
            rows = @max(rows, p.row + p.row_span);
        }
    }
    if (rows == 0) rows = 1;
    const col_tracks = a.alloc(GridTrack, cols) catch {
        layout_alloc_failure_hits +|= 1;
        return;
    };
    defer a.free(col_tracks);
    const row_tracks = a.alloc(GridTrack, rows) catch {
        layout_alloc_failure_hits +|= 1;
        return;
    };
    defer a.free(row_tracks);
    for (col_tracks, 0..) |*t, i| t.* = GridTrack.init(if (i < @min(gc.column_count, GridConfig.MAX_TRACKS)) gc.columns[i] else .auto);
    for (row_tracks, 0..) |*t, i| t.* = GridTrack.init(if (i < @min(gc.row_count, GridConfig.MAX_TRACKS)) gc.rows[i] else .auto);
    sizeGridTracks(parent, placements, col_tracks, true, available.width, &.{});
    sizeGridTracks(parent, placements, row_tracks, false, available.height, col_tracks);
    const pad = parent.style.contentInsets();
    const columns = gridTrackDistribution(parent, col_tracks, true, available.width);
    const rows_distribution = gridTrackDistribution(parent, row_tracks, false, available.height);
    for (children, placements) |child, p| {
        if (isDisplayNone(child)) {
            collapseDisplayNone(child);
            continue;
        }
        if (child.style.position == .absolute) {
            layoutAbsoluteChild(parent, child, ctx);
            continue;
        }
        const cell_w = gridArea(col_tracks, p.col, p.col_span, columns.gap);
        const cell_h = gridArea(row_tracks, p.row, p.row_span, rows_distribution.gap);
        var x = pad.left + columns.offset;
        var y = pad.top + rows_distribution.offset;
        for (col_tracks[0..p.col]) |t| x += t.base + columns.gap;
        for (row_tracks[0..p.row]) |t| y += t.base + rows_distribution.gap;
        const w = resolveGridChildSize(child, true, cell_w, cell_h);
        var h = resolveGridChildSize(child, false, cell_h, cell_w);
        h = aspectCrossSize(child, true, w, h);
        if (computeWrapTextLayoutForWidth(child, w)) |wrapped| if (child.style.height == .fit) {
            const mm = effectiveMinMax(child.style.height, child, false);
            h = std.math.clamp(wrapped, mm.min, mm.max);
        };
        const hm = resolveAxisMargins(cell_w, w, child.style.margin.left, child.style.margin.right, child.style.marginLeftIsAuto(), child.style.marginRightIsAuto());
        const vm = resolveAxisMargins(cell_h, h, child.style.margin.top, child.style.margin.bottom, child.style.marginTopIsAuto(), child.style.marginBottomIsAuto());
        x += hm.start;
        y += vm.start + if (crossAutoMargins(child, true)) @as(f32, 0) else switch (resolveCrossAlign(child, parent.style.align_items)) {
            .center => (cell_h - h - vm.start - vm.end) / 2,
            .end => cell_h - h - vm.start - vm.end,
            else => 0,
        };
        const old = child.rectFromWorldOrFallback();
        if (old.x != x or old.y != y or old.w != w or old.h != h) child.frame_state.state_bits.dirty.core.layout = true;
        child.setLayoutRect(types.ComputedRect.init(x, y, w, h));
        applyRelativeInset(child, .{ .width = cell_w, .height = cell_h });
        var child_ctx = ctx;
        child_ctx.frozen_node = child;
        child_ctx.frozen_both_axes = true;
        layoutNode(child, .{ .width = w, .height = h }, child_ctx);
    }
}

/// parse grid child's size on an axis
/// child's cross-axis valid alignment: explicit align_self priority;
/// else inherit parent align_items, but `no_cross_stretch` downgrades inherited .stretch to .start
/// (keep intrinsic cross size), parent explicit .start/.center/.end/.baseline pass through as-is.
pub fn resolveCrossAlign(child: *const Node, parent_align_items: AlignItems) AlignItems {
    if (child.style.align_self()) |explicit| return explicit;
    if (parent_align_items == .stretch and child.style.no_cross_stretch()) return .start;
    return parent_align_items;
}

fn resolveGridChildSize(child: *Node, comptime is_width: bool, cell_main: f32, cell_cross: f32) f32 {
    const sizing = if (is_width) child.style.width else child.style.height;
    const margin_axis = if (is_width) child.style.marginHorizontal() else child.style.marginVertical();
    const mm = effectiveMinMax(sizing, child, is_width);
    var size = switch (sizing) {
        .px => |v| v,
        .grow => @max(0, cell_main - margin_axis),
        .fit => blk: {
            if (child.parent) |parent| {
                if (is_width != parent.style.direction.isRow() and stretches(child, !is_width, parent.style.align_items))
                    break :blk @max(0, cell_main - margin_axis);
            }
            break :blk calcIntrinsicSize(child, is_width);
        },
        .percent => |p| cell_main * p / 100.0,
    };
    if ((sizing == .fit or sizing == .grow) and child.style.aspect_ratio() > 0) {
        const opposite = if (is_width) child.style.height else child.style.width;
        if (definiteSize(opposite, cell_cross, gridAxisDefinite(child, !is_width))) |v| size = aspectTransfer(v, child.style.aspect_ratio(), is_width);
    }
    return std.math.clamp(size, mm.min, mm.max);
}

test "intrinsic cache: destroyed nodes do not accumulate tombstones" {
    enableIntrinsicCache(testing.allocator);
    defer disableIntrinsicCache();
    const world_id: u16 = 77;
    const put = struct {
        fn f(node_id: u32) !void {
            inline for (.{ IntrinsicKind.max_content, IntrinsicKind.min_content }) |kind| {
                inline for (.{ false, true }) |is_main_row| {
                    try g_intrinsic_cache.put(g_intrinsic_cache_allocator, intrinsicCacheKey(world_id, node_id, is_main_row, kind), .{ .value = 1, .content_version = 0 });
                }
            }
        }
    }.f;
    for (1..301) |id| try put(@intCast(id));
    var next: u32 = 1000;
    for (0..200) |_| {
        const first = next;
        for (0..80) |_| {
            try put(next);
            next += 1;
        }
        for (first..next) |id| {
            forgetIntrinsicCache(world_id, @intCast(id));
            try id_hash.expectFewTombstones(&g_intrinsic_cache);
        }
    }
    for (1..301) |id| forgetIntrinsicCache(world_id, @intCast(id));
}

test "measureIntrinsicTextWidth accounts for monospace spans and inline padding" {
    const spans: []const types.TextSpan = &.{
        .{
            .start = 0,
            .end = 13,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    const text_props = types.TextProps{
        .content = "message?: any",
        .font_size = 12,
        .font_weight = 600,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    };

    const measured = measureIntrinsicTextWidth(text_props);
    const expected = text_layout.measureTextWidthWithSpans(
        text_props.content,
        0,
        @intCast(text_props.content.len),
        text_props.font_size,
        text_props.font_weight,
        text_props.use_italic_font,
        text_props.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected, measured, 0.001);
}

test "measureIntrinsicTextWidth respects newline_only max line width" {
    const spans: []const types.TextSpan = &.{
        .{
            .start = 5,
            .end = 18,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    const text_props = types.TextProps{
        .content = "log(\n  message?: any,\n  ...optionalParams: any[]\n): void",
        .font_size = 12,
        .font_weight = 400,
        .line_height = 1.35,
        .wrap = .newline_only,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    };

    const measured = measureIntrinsicTextWidth(text_props);
    const expected_layout = text_layout.computeTextLayout(
        text_props.content,
        std.math.inf(f32),
        text_props.wrap,
        text_props.max_lines,
        text_props.font_size,
        text_props.line_height,
        text_props.font_weight,
        text_props.use_italic_font,
        text_props.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected_layout.max_line_width, measured, 0.001);
}

test "measureNode intrinsic width uses span-aware text width" {
    var node = Node{
        .id = 1,
        .tag = .box,
        .style = .{},
        .children = .empty,
    };
    defer node.children.deinit(testing.allocator);

    const spans: []const types.TextSpan = &.{
        .{
            .start = 0,
            .end = 13,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    node.setText(.{
        .content = "message?: any",
        .font_size = 12,
        .font_weight = 600,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    });

    const size = measureNode(&node, .{});
    const expected = text_layout.measureTextWidthWithSpans(
        node.getText().?.content,
        0,
        @intCast(node.getText().?.content.len),
        node.getText().?.font_size,
        node.getText().?.font_weight,
        node.getText().?.use_italic_font,
        node.getText().?.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected, size.width, 0.001);
}

test "measureNode bounds application-provided tree depth" {
    const count = max_layout_recursion_depth + 16;
    const nodes = try testing.allocator.alloc(Node, count);
    defer testing.allocator.free(nodes);
    var initialized: usize = 0;
    defer for (nodes[0..initialized]) |*node| node.children.deinit(testing.allocator);

    for (nodes, 0..) |*node, i| {
        node.* = .{
            .id = @intCast(i + 1),
            .tag = .box,
            // Column main-axis (.height) recurses; fixed cross-axis width
            // keeps this a linear depth test instead of exercising the
            // intentionally independent width/height measurement passes.
            .style = .{ .width = .{ .px = 1 } },
            .children = .empty,
        };
        initialized += 1;
    }
    for (nodes[0 .. count - 1], 0..) |*node, i| {
        try node.appendChild(testing.allocator, &nodes[i + 1]);
    }

    const hits_before = layout_depth_limit_hits;
    const measured = measureNode(&nodes[0], .{});
    try testing.expect(layout_depth_limit_hits > hits_before);
    try testing.expectEqual(@as(usize, 0), g_layout_recursion_depth);
    try testing.expect(std.math.isFinite(measured.width));
    try testing.expect(std.math.isFinite(measured.height));
}

test "selected line baseline follows active owner and explicit ratio" {
    const Bridge = struct {
        fn metrics(ctx: *anyopaque, _: *const types.TextProps) ?TextLineMetrics {
            return @as(*TextLineMetrics, @ptrCast(@alignCast(ctx))).*;
        }
    };
    var first: u8 = 0;
    var second: u8 = 0;
    var a = TextLineMetrics{ .ascent = 23.6, .descent = 6.4 };
    var b = TextLineMetrics{ .ascent = 12, .descent = 4 };
    const props = types.TextProps{ .content = "AV ffi Windows", .font_size = 24, .line_height = 1.5 };
    defer setShapeFontResolver(null, null);
    setContextFontHooks(&first, null, null, null);
    setContextLineMetrics(&first, Bridge.metrics, &a);
    try testing.expectEqual(@as(f32, 27), firstTextBaseline(&props));
    var explicit = props;
    explicit.baseline_ratio = 0.5;
    try testing.expectEqual(@as(f32, 18), firstTextBaseline(&explicit));

    setContextFontHooks(&second, null, null, null);
    setContextLineMetrics(&second, Bridge.metrics, &b);
    clearContextFontHooks(&first);
    setContextLineMetrics(&first, Bridge.metrics, &a); // Inactive owners cannot replace it.
    try testing.expectEqual(@as(f32, 22), firstTextBaseline(&props));
    clearContextFontHooks(&second);
    try testing.expectEqual(@as(f32, 27), firstTextBaseline(&props)); // No-font fallback.

    setContextFontHooks(&first, null, null, null); // Recreated/rebound window.
    setContextLineMetrics(&first, Bridge.metrics, &b);
    setDrawnTextMeasure(null, null); // Legacy takeover must release the borrowed context.
    try testing.expectEqual(@as(f32, 27), firstTextBaseline(&props));
}

test "selected line baseline rejects unavailable and invalid metrics" {
    const Bridge = struct {
        fn metrics(ctx: *anyopaque, _: *const types.TextProps) ?TextLineMetrics {
            return @as(*?TextLineMetrics, @ptrCast(@alignCast(ctx))).*;
        }
    };
    var owner: u8 = 0;
    var metrics: ?TextLineMetrics = null;
    const props = types.TextProps{ .content = "sample", .font_size = 20, .line_height = 1 };
    defer clearContextFontHooks(&owner);
    setContextFontHooks(&owner, null, null, null);
    setContextLineMetrics(&owner, Bridge.metrics, &metrics);
    try testing.expectEqual(@as(f32, 15), firstTextBaseline(&props));
    metrics = .{ .ascent = std.math.nan(f32), .descent = 4 };
    try testing.expectEqual(@as(f32, 15), firstTextBaseline(&props));
    metrics = .{ .ascent = 12, .descent = -1 };
    try testing.expectEqual(@as(f32, 15), firstTextBaseline(&props));
    metrics = .{ .ascent = 12, .descent = std.math.inf(f32) };
    try testing.expectEqual(@as(f32, 15), firstTextBaseline(&props));
}

test "managed font hooks clear only the active Cx owner" {
    const Bridge = struct {
        fn measure(_: *anyopaque, _: []const u8, _: f32, _: u16, _: bool, _: bool, _: u16, _: bool, _: f32) ?f32 {
            return 42;
        }
    };
    var first: u8 = 0;
    var second: u8 = 0;
    var shared_selector: u8 = 0;
    defer setDrawnTextMeasure(null, null);
    defer setShapeFontResolver(null, null);
    setContextFontHooks(&first, null, Bridge.measure, &shared_selector);
    setContextFontHooks(&second, null, Bridge.measure, &shared_selector);
    clearContextFontHooks(&first);
    try std.testing.expectEqual(@as(?f32, 42), shapeViaPipeline(null, null, "sample", 16, 400, false, false, 0, false, 0));
    clearContextFontHooks(&second);
    try std.testing.expectEqual(@as(?f32, null), shapeViaPipeline(null, null, "sample", 16, 400, false, false, 0, false, 0));
    setContextFontHooks(&first, null, Bridge.measure, &shared_selector);
    setDrawnTextMeasure(Bridge.measure, &shared_selector); // External owner takes over.
    clearContextFontHooks(&first);
    try std.testing.expectEqual(@as(?f32, 42), shapeViaPipeline(null, null, "sample", 16, 400, false, false, 0, false, 0));
}

test "intrinsic fit gaps exclude hidden anchors and display-none captions" {
    var parent = Node{ .id = 1, .tag = .box, .style = .{ .direction = .row, .gap = 8 }, .children = .empty };
    defer parent.children.deinit(std.testing.allocator);
    var first = Node{ .id = 2, .tag = .box, .style = .{ .width = .{ .px = 28 } }, .children = .empty };
    var hidden = Node{ .id = 3, .tag = .anchor, .style = .{ .display = .none }, .children = .empty };
    var last = Node{ .id = 4, .tag = .box, .style = .{ .width = .{ .px = 146 } }, .children = .empty };
    try parent.appendChild(std.testing.allocator, &first);
    try parent.appendChild(std.testing.allocator, &hidden);
    try parent.appendChild(std.testing.allocator, &last);
    try std.testing.expectEqual(@as(f32, 182), calcIntrinsicSizeUncached(&parent, true));
}

// Wide containers exercise both the frame scratch allocation and the OOM fallback.
// Keep this in test-ui-core (and therefore zig build test), independent of a window.
test "LC3 flex wide scratch OOM degrades safely and recovers" {
    try expectFlexScratchRecovery(flex_stack_capacity + 1);
    // Keep the original >512-child regression as well as the new stack boundary.
    try expectFlexScratchRecovery(513);
}

fn expectFlexScratchRecovery(comptime count: usize) !void {
    const a = std.testing.allocator;
    const children = try a.alloc(Node, count);
    defer a.free(children);
    var parent = Node{ .id = 9000, .tag = .box, .style = .{ .width = .{ .px = @as(f32, @floatFromInt(count * 2)) }, .height = .{ .px = 20 }, .direction = .row }, .children = .empty };
    defer parent.children.deinit(a);
    for (children, 0..) |*child, i| {
        child.* = .{ .id = @intCast(9001 + i), .tag = .box, .style = .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 } }, .children = .empty };
        try parent.appendChild(a, child);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    layoutNode(&parent, .{ .width = @as(f32, @floatFromInt(count * 2)), .height = 20 }, .{ .frame_allocator = arena.allocator() });
    for (children) |*child| try std.testing.expectApproxEqAbs(@as(f32, 2), child.rectFromWorldOrFallback().w, 0.001);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const old_hits = layout_alloc_failure_hits;
    parent.frame_state.state_bits.dirty.core.layout = true;
    layoutNode(&parent, .{ .width = @as(f32, @floatFromInt(count * 2)), .height = 20 }, .{ .frame_allocator = failing.allocator() });
    try std.testing.expectEqual(old_hits + 1, layout_alloc_failure_hits);
    for (children) |*child| {
        try std.testing.expectEqual(@as(f32, 0), child.rectFromWorldOrFallback().w);
        try std.testing.expect(std.math.isFinite(child.rectFromWorldOrFallback().x));
    }
    parent.frame_state.state_bits.dirty.core.layout = true;
    layoutNode(&parent, .{ .width = @as(f32, @floatFromInt(count * 2)), .height = 20 }, .{ .frame_allocator = arena.allocator() });
    try std.testing.expectApproxEqAbs(@as(f32, 2), children[count - 1].rectFromWorldOrFallback().w, 0.001);
    // display:none consumes no flow slot. At 33 -> 32 it also crosses
    // back to stack scratch, so an allocator that cannot allocate is safe.
    children[count - 1].style.display = .none;
    parent.frame_state.state_bits.dirty.core.layout = true;
    const hidden_allocator = if (count - 1 <= flex_stack_capacity) failing.allocator() else arena.allocator();
    layoutNode(&parent, .{ .width = @as(f32, @floatFromInt(count * 2)), .height = 20 }, .{ .frame_allocator = hidden_allocator });
    try std.testing.expectEqual(old_hits + 1, layout_alloc_failure_hits);
    try std.testing.expectEqual(@as(f32, 0), children[count - 1].rectFromWorldOrFallback().w);
    try std.testing.expectApproxEqAbs(@as(f32, @as(f32, @floatFromInt(count * 2)) / @as(f32, @floatFromInt(count - 1))), children[0].rectFromWorldOrFallback().w, 0.001);
    children[count - 1].style.display = .flex;
    // Scaled shrink also uses the wide path, and min violations must redistribute.
    parent.style.width = .{ .px = @floatFromInt(count) };
    for (children) |*child| child.style.width = .{ .px = 2 };
    var ext: types.StyleExt = .{ .min_width = 2 };
    children[0].style.ext = &ext;
    parent.frame_state.state_bits.dirty.core.layout = true;
    layoutNode(&parent, .{ .width = @floatFromInt(count), .height = 20 }, .{ .frame_allocator = arena.allocator() });
    try std.testing.expectEqual(@as(f32, 2), children[0].rectFromWorldOrFallback().w);
    try std.testing.expectApproxEqAbs(@as(f32, @as(f32, @floatFromInt(count - 2)) / @as(f32, @floatFromInt(count - 1))), children[count - 1].rectFromWorldOrFallback().w, 0.001);
    parent.frame_state.state_bits.dirty.core.layout = true;
    layoutNode(&parent, .{ .width = @floatFromInt(count), .height = 20 }, .{ .frame_allocator = failing.allocator() });
    try std.testing.expectEqual(old_hits + 2, layout_alloc_failure_hits);
    for (children) |*child| try std.testing.expectEqual(@as(f32, 2), child.rectFromWorldOrFallback().w);
    parent.frame_state.state_bits.dirty.core.layout = true;
    layoutNode(&parent, .{ .width = @floatFromInt(count), .height = 20 }, .{ .frame_allocator = arena.allocator() });
    try std.testing.expectApproxEqAbs(@as(f32, @as(f32, @floatFromInt(count - 2)) / @as(f32, @floatFromInt(count - 1))), children[count - 1].rectFromWorldOrFallback().w, 0.001);
}

test "LC3 automatic minimum respects paint-only text spans" {
    var node = Node{ .id = 9900, .tag = .text, .style = .{}, .children = .empty };
    const spans: []const types.TextSpan = &.{.{ .start = 0, .end = 4, .inline_box_padding_left = 20, .inline_box_padding_right = 20 }};
    var props = types.TextProps{ .content = "word", .wrap = .word, .spans = spans, .spans_affect_layout = false };
    node.setText(props);
    const plain = text_layout.measureTextWidthWithSpans(props.content, 0, 4, props.font_size, props.font_weight, props.use_italic_font, props.use_monospace_font, &.{});
    try std.testing.expectApproxEqAbs(plain, makeFlexItem(&node, true, Size.init(0, 20)).min, 0.001);
    props.spans_affect_layout = true;
    node.setText(props);
    try std.testing.expectApproxEqAbs(plain + 40, makeFlexItem(&node, true, Size.init(0, 20)).min, 0.001);
}

test "LC3 fit parent honors zero basis only on the main axis" {
    var parent = Node{ .id = 9910, .tag = .box, .style = .{ .direction = .row }, .children = .empty };
    defer parent.children.deinit(std.testing.allocator);
    var ext = types.StyleExt{ .flex_basis = 0, .min_width = 0 };
    var child = Node{ .id = 9911, .tag = .box, .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 24 }, .ext = &ext }, .children = .empty };
    try parent.appendChild(std.testing.allocator, &child);
    try std.testing.expectEqual(@as(f32, 0), calcIntrinsicSize(&parent, true));
    try std.testing.expectEqual(@as(f32, 24), calcIntrinsicSize(&parent, false));
    try std.testing.expectEqual(@as(f32, 0), makeFlexItem(&child, true, Size.init(200, 40)).target);
}

test "LC3 flex scratch OOM reuses measured targets" {
    const Bridge = struct {
        var calls: usize = 0;
        fn measure(_: *anyopaque, _: []const u8, _: f32, _: u16, _: bool, _: bool, _: u16, _: bool, _: f32) ?f32 {
            calls += 1;
            return 10;
        }
    };
    const a = std.testing.allocator;
    const count = flex_stack_capacity + 1;
    const children = try a.alloc(Node, count);
    defer a.free(children);
    var parent = Node{ .id = 9940, .tag = .box, .style = .{ .direction = .row, .width = .{ .px = @floatFromInt(count * 2) }, .height = .{ .px = 20 } }, .children = .empty };
    defer parent.children.deinit(a);
    for (children, 0..) |*child, i| {
        child.* = .{ .id = @intCast(9941 + i), .tag = .text, .style = .{ .width = .{ .px = 2 }, .height = .{ .px = 20 } }, .children = .empty };
        child.setText(.{ .content = "word", .wrap = .none });
        try parent.appendChild(a, child);
    }
    var marker: u8 = 0;
    setDrawnTextMeasure(Bridge.measure, &marker);
    defer setDrawnTextMeasure(null, null);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    Bridge.calls = 0;
    layoutNode(&parent, Size.init(@floatFromInt(count * 2), 20), .{ .frame_allocator = arena.allocator() });
    const normal_calls = Bridge.calls;
    try std.testing.expect(normal_calls >= count);
    parent.frame_state.state_bits.dirty.core.layout = true;
    for (children) |*child| child.frame_state.state_bits.dirty.core.layout = true;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    Bridge.calls = 0;
    const old_hits = layout_alloc_failure_hits;
    layoutNode(&parent, Size.init(@floatFromInt(count * 2), 20), .{ .frame_allocator = failing.allocator() });
    try std.testing.expectEqual(old_hits + 1, layout_alloc_failure_hits);
    try std.testing.expectEqual(normal_calls, Bridge.calls);
    for (children) |*child| try std.testing.expectEqual(@as(f32, 2), child.rectFromWorldOrFallback().w);
}

test "LC3 min-content cache separates kinds axes worlds and invalidation" {
    enableIntrinsicCache(std.testing.allocator);
    defer disableIntrinsicCache();
    var node = Node{ .id = 9920, .world_id = 100, .tag = .text, .style = .{}, .children = .empty };
    node.setText(.{ .content = "a longer word", .wrap = .word });
    const min_width = flexMinContent(&node, true);
    const max_width = calcIntrinsicSize(&node, true);
    try std.testing.expect(min_width < max_width);
    try std.testing.expectEqual(@as(?f32, min_width), intrinsicCacheLookup(&node, true, .min_content));
    try std.testing.expectEqual(@as(?f32, max_width), intrinsicCacheLookup(&node, true, .max_content));
    intrinsicCacheStore(&node, false, .min_content, 42);
    var other = node;
    other.world_id += 1;
    try std.testing.expectEqual(@as(?f32, null), intrinsicCacheLookup(&other, true, .min_content));
    try std.testing.expectEqual(@as(?f32, 42), intrinsicCacheLookup(&node, false, .min_content));

    node.frame_state.state_bits.dirty.core.layout = false;
    node.frame_state.state_bits.dirty.core.subtree_layout = false;
    // A hit must not descend or spend either recursion budget.
    const old_depth = g_min_content_recursion_depth;
    g_min_content_recursion_depth = max_layout_recursion_depth;
    const hits = min_content_depth_limit_hits;
    try std.testing.expectEqual(min_width, flexMinContent(&node, true));
    try std.testing.expectEqual(hits, min_content_depth_limit_hits);
    g_min_content_recursion_depth = old_depth;
    node.setText(.{ .content = "extraordinarilylong", .wrap = .word });
    try std.testing.expectEqual(@as(?f32, null), intrinsicCacheLookup(&node, true, .min_content));
    try std.testing.expect(flexMinContent(&node, true) > min_width);
    forgetIntrinsicCache(node.world_id, node.id);
    try std.testing.expectEqual(@as(?f32, null), intrinsicCacheLookup(&node, true, .max_content));
    try std.testing.expectEqual(@as(?f32, null), intrinsicCacheLookup(&node, true, .min_content));
    try std.testing.expectEqual(@as(?f32, null), intrinsicCacheLookup(&node, false, .min_content));
}

test "LC3 min-content depth is independent counted and never caches truncation" {
    const a = std.testing.allocator;
    const count = max_layout_recursion_depth + 1;
    const nodes = try a.alloc(Node, count);
    defer a.free(nodes);
    defer for (nodes) |*node| node.children.deinit(a);
    for (nodes, 0..) |*node, i| node.* = .{ .id = @intCast(10000 + i), .tag = .box, .style = .{ .direction = .column }, .children = .empty };
    for (nodes[0 .. count - 1], nodes[1..]) |*node, *child| {
        try node.appendChild(a, child);
    }
    nodes[count - 1].style.padding = .all(5);
    enableIntrinsicCache(a);
    defer disableIntrinsicCache();
    const hits = min_content_depth_limit_hits;
    _ = flexMinContent(&nodes[0], true);
    try std.testing.expectEqual(hits + 1, min_content_depth_limit_hits);
    try std.testing.expectEqual(@as(usize, 0), g_min_content_recursion_depth);
    try std.testing.expectEqual(@as(?f32, null), intrinsicCacheLookup(&nodes[0], true, .min_content));
    const old_depth = g_layout_recursion_depth;
    defer g_layout_recursion_depth = old_depth;
    g_layout_recursion_depth = max_layout_recursion_depth;
    const layout_hits = layout_depth_limit_hits;
    try std.testing.expectEqual(@as(f32, 10), flexMinContent(&nodes[count - 1], true));
    try std.testing.expectEqual(layout_hits, layout_depth_limit_hits);
    try std.testing.expectEqual(hits + 1, min_content_depth_limit_hits);
}

test "LC3B wrap scratch OOM publishes clamped bases and recovers" {
    const a = std.testing.allocator;
    const count = flex_stack_capacity + 1;
    var ext = types.StyleExt{ .flex_wrap = .wrap };
    var parent = Node{ .id = 12000, .tag = .box, .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 330 }, .direction = .row, .align_content = .start, .ext = &ext }, .children = .empty };
    defer parent.children.deinit(a);
    var children: [count]Node = undefined;
    for (&children, 0..) |*child, i| {
        child.* = .{ .id = @intCast(12001 + i), .tag = .box, .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 10 } }, .children = .empty };
        try parent.appendChild(a, child);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const size = Size.init(20, 330);
    layoutNode(&parent, size, .{ .frame_allocator = arena.allocator() });
    try testing.expectEqual(@as(f32, 320), children[count - 1].rectFromWorldOrFallback().y);
    for (0..3) |fail_index| {
        var failing = testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const hits = layout_alloc_failure_hits;
        parent.frame_state.state_bits.dirty.core.layout = true;
        layoutNode(&parent, size, .{ .frame_allocator = failing.allocator() });
        try testing.expectEqual(hits + 1, layout_alloc_failure_hits);
        for (&children, 0..) |*child, i| {
            try testing.expectEqual(@as(f32, 0), child.rectFromWorldOrFallback().y);
            try testing.expectEqual(@as(f32, @floatFromInt(i * 20)), child.rectFromWorldOrFallback().x);
            try testing.expectEqual(@as(f32, 20), child.rectFromWorldOrFallback().w);
            try testing.expectEqual(@as(f32, 10), child.rectFromWorldOrFallback().h);
        }
        try testing.expect(parent.frame_state.state_bits.dirty.core.layout);
        layoutNode(&parent, size, .{ .frame_allocator = arena.allocator() });
        try testing.expectEqual(@as(f32, 320), children[count - 1].rectFromWorldOrFallback().y);
        try testing.expect(!parent.frame_state.state_bits.dirty.core.layout);
    }
    ext.flex_wrap = .wrap_reverse;
    parent.frame_state.state_bits.dirty.core.layout = true;
    layoutNode(&parent, size, .{ .frame_allocator = arena.allocator() });
    try testing.expectEqual(@as(f32, 320), children[0].rectFromWorldOrFallback().y);
    try testing.expectEqual(@as(f32, 0), children[count - 1].rectFromWorldOrFallback().y);
    children[count - 1].style.display = .none;
    parent.frame_state.state_bits.dirty.core.layout = true;
    var failing = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const hits = layout_alloc_failure_hits;
    layoutNode(&parent, size, .{ .frame_allocator = failing.allocator() });
    try testing.expectEqual(hits, layout_alloc_failure_hits);
    try testing.expectEqual(@as(f32, 0), children[count - 1].rectFromWorldOrFallback().w);
}

test "LC3B wrap first frame OOM retries every scratch failure without zero geometry" {
    const a = testing.allocator;
    const count = flex_stack_capacity + 1;
    for (0..3) |fail_index| {
        var ext = types.StyleExt{ .flex_wrap = .wrap };
        var parent = Node{ .id = 15000, .tag = .box, .children = .empty, .style = .{ .width = .{ .px = 40 }, .height = .{ .px = 340 }, .direction = .row, .align_content = .start, .ext = &ext } };
        @import("node_lifecycle.zig").releaseStandaloneState(&parent);
        defer @import("node_lifecycle.zig").releaseStandaloneState(&parent);
        defer parent.children.deinit(a);
        const Probe = struct {
            fn mount(raw: *anyopaque) void {
                const mounts: *usize = @ptrCast(@alignCast(raw));
                mounts.* += 1;
            }
        };
        var mounts: usize = 0;
        var children: [count]Node = undefined;
        for (&children, 0..) |*child, i| {
            child.* = .{ .id = @intCast(15001 + i), .tag = .box, .children = .empty, .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 10 } } };
            child.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &mounts };
            @import("node_lifecycle.zig").releaseStandaloneState(child);
            child.setLayoutRect(types.ComputedRect.init(0, 0, 0, 0));
            try parent.appendChild(a, child);
        }
        defer for (&children) |*child| @import("node_lifecycle.zig").releaseStandaloneState(child);
        var failing = testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const hits = layout_alloc_failure_hits;
        layoutNode(&parent, Size.init(40, 340), .{ .frame_allocator = failing.allocator() });
        try testing.expectEqual(hits + 1, layout_alloc_failure_hits);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        for (&children, 0..) |*child, i| {
            const r = child.rectFromWorldOrFallback();
            try testing.expectEqual(@as(f32, 20), r.w);
            try testing.expectEqual(@as(f32, 10), r.h);
            try testing.expectEqual(@as(f32, @floatFromInt(i * 20)), r.x);
            try testing.expectEqual(@as(f32, 0), r.y);
        }
        try testing.expectEqual(@as(usize, 0), mounts);
        try testing.expect(!parent.frame_state.state_bits.flags.is_mounted);
        try testing.expect(parent.frame_state.state_bits.dirty.core.layout);
        // No external dirtying: the failed allocation itself schedules recovery.
        layoutNode(&parent, Size.init(40, 340), .{ .frame_allocator = a });
        for (&children, 0..) |*child, i| {
            const r = child.rectFromWorldOrFallback();
            try testing.expectEqual(@as(f32, @floatFromInt((i % 2) * 20)), r.x);
            try testing.expectEqual(@as(f32, @floatFromInt((i / 2) * 10)), r.y);
        }
        try testing.expectEqual(count, mounts);
        try testing.expect(parent.frame_state.state_bits.flags.is_mounted);
        try testing.expect(!parent.frame_state.state_bits.dirty.core.layout);
    }
}

test "LC3B large wrap incremental layout skips independent siblings and redundant passes" {
    const a = testing.allocator;
    const count = 128;
    var ext = types.StyleExt{ .flex_wrap = .wrap };
    var parent = Node{ .id = 16000, .tag = .box, .children = .empty, .style = .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 }, .direction = .row, .align_items = .start, .align_content = .start, .ext = &ext } };
    @import("node_lifecycle.zig").releaseStandaloneState(&parent);
    defer @import("node_lifecycle.zig").releaseStandaloneState(&parent);
    defer parent.children.deinit(a);
    var cards: [count]Node = undefined;
    var leaves: [count]Node = undefined;
    for (&cards, &leaves, 0..) |*card, *leaf, i| {
        card.* = .{ .id = @intCast(16001 + i * 2), .tag = .box, .children = .empty, .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .flex_shrink = 0 } };
        leaf.* = .{ .id = @intCast(16002 + i * 2), .tag = .box, .children = .empty, .style = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } };
        try card.appendChild(a, leaf);
        @import("node_lifecycle.zig").releaseStandaloneState(card);
        @import("node_lifecycle.zig").releaseStandaloneState(leaf);
        try parent.appendChild(a, card);
    }
    defer for (&cards, &leaves) |*card, *leaf| {
        card.children.deinit(a);
        @import("node_lifecycle.zig").releaseStandaloneState(card);
        @import("node_lifecycle.zig").releaseStandaloneState(leaf);
    };
    const size = Size.init(200, 1000);
    layoutNode(&parent, size, .{ .frame_allocator = a });
    // Deep mutation cannot affect fixed non-shrinking card allocations.
    leaves[0].style.width = .{ .px = 7 };
    leaves[0].markLayoutDirty();
    test_layout_calls = 0;
    test_flex_item_probes = 0;
    layoutNode(&parent, size, .{ .frame_allocator = a });
    try testing.expect(test_layout_calls <= 3);
    try testing.expect(test_flex_item_probes < 4);
    try testing.expectEqual(@as(f32, 7), leaves[0].rectFromWorldOrFallback().w);
    try testing.expectEqual(@as(f32, 240), cards[count - 1].rectFromWorldOrFallback().y);
    // A full unchanged pass need not lay out clean, mounted cards at all.
    parent.markLayoutDirty();
    test_layout_calls = 0;
    layoutNode(&parent, size, .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 1), test_layout_calls);
    // Direct size change must still recollect/reposition lines.
    cards[0].style.width = .{ .px = 40 };
    cards[0].markLayoutDirty();
    layoutNode(&parent, size, .{ .frame_allocator = a });
    try testing.expectEqual(@as(f32, 40), cards[1].rectFromWorldOrFallback().x);
    try testing.expectEqual(@as(f32, 20), cards[9].rectFromWorldOrFallback().y);
    // Natural cross changes remain sibling-dependent, including stretch.
    cards[0].style.height = .{ .fit = .{} };
    cards[0].markLayoutDirty();
    layoutNode(&parent, size, .{ .frame_allocator = a });
    leaves[0].style.height = .{ .px = 40 };
    leaves[0].markLayoutDirty();
    layoutNode(&parent, size, .{ .frame_allocator = a });
    try testing.expectEqual(@as(f32, 40), cards[9].rectFromWorldOrFallback().y);
}

test "LC3B baseline export reuses collected first line without intrinsic reprobes" {
    const a = testing.allocator;
    var ext = types.StyleExt{ .flex_wrap = .wrap };
    var baseline_ext = types.StyleExt{ .align_self = .baseline };
    var parent = Node{ .id = 17000, .tag = .box, .children = .empty, .style = .{ .width = .{ .px = 40 }, .height = .{ .px = 100 }, .direction = .row, .align_items = .start, .align_content = .start, .ext = &ext } };
    @import("node_lifecycle.zig").releaseStandaloneState(&parent);
    defer @import("node_lifecycle.zig").releaseStandaloneState(&parent);
    defer parent.children.deinit(a);
    var children: [3]Node = undefined;
    for (&children, 0..) |*child, i| {
        child.* = .{ .id = @intCast(17001 + i), .tag = .box, .children = .empty, .style = .{ .width = .{ .px = 20 }, .height = .{ .px = @as(f32, @floatFromInt(10 + i * 10)) }, .ext = if (i > 0) &baseline_ext else null } };
        @import("node_lifecycle.zig").releaseStandaloneState(child);
        try parent.appendChild(a, child);
    }
    defer for (&children) |*child| @import("node_lifecycle.zig").releaseStandaloneState(child);
    layoutNode(&parent, Size.init(40, 100), .{ .frame_allocator = a });
    test_flex_item_probes = 0;
    for (0..100) |_| {
        children[0].frame_state.state_bits.dirty.core.subtree_layout = true;
        try testing.expectEqual(@as(f32, 20), firstBaseline(&parent, true, 0));
    }
    try testing.expectEqual(@as(usize, 0), test_flex_item_probes);
    parent.style.width = .{ .px = 20 };
    parent.markLayoutDirty();
    layoutNode(&parent, Size.init(20, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(f32, 10), firstBaseline(&parent, true, 0));
    children[0].style.display = .none;
    parent.markLayoutDirty();
    layoutNode(&parent, Size.init(20, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(f32, 20), firstBaseline(&parent, true, 0));
}

test "LC3C nowrap mount destruction and reentry never retain child borrows" {
    const a = std.testing.allocator;
    for ([_]u8{ 0, 1, 2 }) |mode| {
        const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .direction = .row, .justify = .center });
        defer root.destroy(a);
        for (0..3) |i| try root.appendChild(a, try Node.create(a, @intCast(i + 2), .box, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }));
        const Probe = struct {
            root: *Node,
            self: *Node,
            victim: *Node,
            mode: u8,
            mounts: usize = 0,
            cleanup: usize = 0,
            x: f32 = -1,
            fn mount(raw: *anyopaque) void {
                const p: *@This() = @ptrCast(@alignCast(raw));
                p.mounts += 1;
                p.x = p.self.rectFromWorldOrFallback().x;
                if (p.mode == 2) {
                    layoutNode(p.root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = std.testing.allocator });
                } else {
                    const victim = if (p.mode == 0) p.self else p.victim;
                    p.root.removeChild(victim);
                    victim.destroy(std.testing.allocator);
                }
            }
            fn cleaned(raw: *anyopaque) void {
                const p: *@This() = @ptrCast(@alignCast(raw));
                p.cleanup += 1;
            }
        };
        var probe = Probe{ .root = root, .self = root.children.items[0], .victim = root.children.items[1], .mode = mode };
        probe.self.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &probe };
        const victim = if (mode == 0) probe.self else probe.victim;
        victim.meta.ownership.hooks.on_cleanup = .{ .callback = Probe.cleaned, .context = &probe };
        layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
        try std.testing.expectEqual(@as(usize, 1), probe.mounts);
        try std.testing.expectEqual(@as(f32, 20), probe.x);
        if (mode != 2) {
            try std.testing.expectEqual(@as(usize, 1), probe.cleanup);
            try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        }
        layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
        try std.testing.expectEqual(@as(usize, 1), probe.mounts);
        // Context must remain live through normal root teardown.
        if (mode == 2) victim.meta.ownership.hooks.on_cleanup = null;
    }
}

test "LC3C mount publication permits direct ancestor destruction" {
    const a = std.testing.allocator;
    const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    const child = try Node.create(a, 2, .box, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
    try root.appendChild(a, child);
    const Probe = struct {
        root: *Node,
        calls: usize = 0,
        fn mount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.calls += 1;
            p.root.destroy(std.testing.allocator);
        }
    };
    var p = Probe{ .root = root };
    child.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &p };
    layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 1), p.calls);
}

test "LC3C grid scratch OOM is atomic and implicit rows exceed old limits" {
    const a = std.testing.allocator;
    for (0..3) |fail_index| {
        const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 513 } });
        defer root.destroy(a);
        const ext = try root.style.ensureExtFallible(a);
        const gc = try a.create(GridConfig);
        gc.* = .{ .column_count = 1 };
        gc.columns[0] = .{ .px = 100 };
        ext.grid = gc;
        for (0..513) |i| try root.appendChild(a, try Node.create(a, @intCast(i + 2), .box, .{ .width = .{ .grow = .{} }, .height = .{ .px = 1 } }));
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const before = layout_alloc_failure_hits;
        layoutNode(root, .{ .width = 100, .height = 513 }, .{ .frame_allocator = failing.allocator() });
        try testing.expectEqual(before + 1, layout_alloc_failure_hits);
        try testing.expect(root.frame_state.state_bits.dirty.core.layout);
        try testing.expect(!root.frame_state.state_bits.flags.is_mounted);
        for (root.children.items) |child| {
            try testing.expectEqual(@as(f32, 0), child.rectFromWorldOrFallback().h);
            try testing.expect(!child.frame_state.state_bits.flags.is_mounted);
        }
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        layoutNode(root, .{ .width = 100, .height = 513 }, .{ .frame_allocator = a });
        try testing.expect(!root.frame_state.state_bits.dirty.core.layout);
        for (root.children.items, 0..) |child, i| {
            const r = child.rectFromWorldOrFallback();
            try testing.expectEqual(@as(f32, @floatFromInt(i)), r.y);
            try testing.expectEqual(@as(f32, 1), r.h);
            try testing.expect(child.frame_state.state_bits.flags.is_mounted);
        }
    }
}

test "LC3C release during publication preserves remaining mount retries" {
    const a = std.testing.allocator;
    const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(a);
    layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    const detached = try Node.create(a, 9, .box, .{});
    for (0..2) |i| try root.appendChild(a, try Node.create(a, @intCast(i + 2), .box, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }));
    const Probe = struct {
        detached: *Node,
        first: usize = 0,
        second: usize = 0,
        fn firstMount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.first += 1;
            p.detached.destroy(std.testing.allocator);
        }
        fn secondMount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.second += 1;
        }
    };
    var p = Probe{ .detached = detached };
    root.children.items[0].meta.ownership.hooks.on_mount = .{ .callback = Probe.firstMount, .context = &p };
    root.children.items[1].meta.ownership.hooks.on_mount = .{ .callback = Probe.secondMount, .context = &p };
    layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 1), p.first);
    try testing.expectEqual(@as(usize, 0), p.second);
    try testing.expect(root.frame_state.state_bits.dirty.core.layout);
    layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 1), p.first);
    try testing.expectEqual(@as(usize, 1), p.second);
}

test "LC3C deferred outer probes do not mount display none descendants" {
    const a = std.testing.allocator;
    const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(a);
    const hidden = try Node.create(a, 2, .box, .{ .display = .none });
    try root.appendChild(a, hidden);
    const leaf = try Node.create(a, 3, .box, .{});
    try hidden.appendChild(a, leaf);
    layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a, .defer_mount = true });
    try testing.expect(!root.frame_state.state_bits.flags.is_mounted);
    try testing.expect(!hidden.frame_state.state_bits.flags.is_mounted);
    try testing.expect(!leaf.frame_state.state_bits.flags.is_mounted);
    layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try testing.expect(root.frame_state.state_bits.flags.is_mounted);
    try testing.expect(hidden.frame_state.state_bits.flags.is_mounted);
    try testing.expect(leaf.frame_state.state_bits.flags.is_mounted);
}

test "LC3C mount publication skips settled trees and retains deferred new mounts" {
    const a = testing.allocator;
    const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(a);
    for (0..32) |i| try root.appendChild(a, try Node.create(a, @intCast(i + 2), .box, .{}));
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a });
    test_mount_publication_visits = 0;
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 0), test_mount_publication_visits);
    const leaf = try Node.create(a, 40, .box, .{});
    const Probe = struct {
        mounts: usize = 0,
        fn mount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.mounts += 1;
        }
    };
    var p = Probe{};
    leaf.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &p };
    try root.children.items[31].appendChild(a, leaf);
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a, .defer_mount = true });
    try testing.expectEqual(@as(usize, 0), p.mounts);
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 1), p.mounts);
    try testing.expect(test_mount_publication_visits < 32);
    test_mount_publication_visits = 0;
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 0), test_mount_publication_visits);
    try testing.expectEqual(@as(usize, 1), p.mounts);
    // Cleanup can happen with unchanged geometry, including without a tree
    // mutation. Both the subtree and its clean ancestors must publish again.
    const branch = root.children.items[31];
    node_mod.fireCleanupCallbacks(branch);
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 2), p.mounts);
    root.removeChild(branch);
    try root.appendChild(a, branch);
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 3), p.mounts);
    test_mount_publication_visits = 0;
    layoutNode(root, Size.init(100, 100), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 0), test_mount_publication_visits);
    try testing.expectEqual(@as(usize, 3), p.mounts);
}

test "LC3C mount callback reparents a sibling into another subtree" {
    const a = testing.allocator;
    const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    defer root.destroy(a);
    const source = try Node.create(a, 2, .box, .{});
    const target = try Node.create(a, 3, .box, .{});
    try root.appendChild(a, source);
    try root.appendChild(a, target);
    const first = try Node.create(a, 4, .box, .{});
    const sibling = try Node.create(a, 5, .box, .{});
    try source.appendChild(a, first);
    try source.appendChild(a, sibling);
    const Probe = struct {
        target: *Node,
        sibling: *Node,
        first: usize = 0,
        moved: usize = 0,
        cleanup: usize = 0,
        fn mount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.first += 1;
            // appendChild is this checkout's retained move/reparent API.
            p.target.appendChild(testing.allocator, p.sibling) catch unreachable;
        }
        fn movedMount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.moved += 1;
        }
        fn cleaned(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.cleanup += 1;
        }
    };
    var p = Probe{ .target = target, .sibling = sibling };
    first.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &p };
    sibling.meta.ownership.hooks.on_mount = .{ .callback = Probe.movedMount, .context = &p };
    sibling.meta.ownership.hooks.on_cleanup = .{ .callback = Probe.cleaned, .context = &p };
    layoutNode(root, Size.init(200, 200), .{ .frame_allocator = a });
    try testing.expectEqual(target, sibling.parent.?);
    try testing.expectEqual(@as(usize, 1), source.children.items.len);
    try testing.expectEqual(@as(usize, 1), p.first);
    try testing.expectEqual(@as(usize, 0), p.moved);
    try testing.expectEqual(@as(usize, 0), p.cleanup);
    for (0..2) |_| layoutNode(root, Size.init(200, 200), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 1), p.first);
    try testing.expectEqual(@as(usize, 1), p.moved);
    try testing.expectEqual(@as(usize, 0), p.cleanup);
    // Keep the callback context alive during normal teardown.
    target.removeChild(sibling);
    try testing.expectEqual(@as(usize, 1), p.cleanup);
    sibling.destroy(a);
}

test "LC3C aspect percentage suggestions require a definite containing axis" {
    const a = testing.allocator;
    const root = try Node.create(a, 1, .box, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{} }, .direction = .row, .align_items = .start });
    defer root.destroy(a);
    const child = try Node.create(a, 2, .box, .{ .width = .{ .fit = .{} }, .height = .{ .percent = 50 } });
    try root.appendChild(a, child);
    const ext = try child.style.ensureExtFallible(a);
    test_axis_definiteness_probes = 0;
    layoutNode(root, Size.init(300, 200), .{ .frame_allocator = a });
    try testing.expectEqual(@as(usize, 0), test_axis_definiteness_probes);
    ext.aspect_ratio = 2;
    try testing.expectEqual(@as(?f32, null), aspectMainSuggestion(child, true, Size.init(300, 200)));
    try testing.expectEqual(@as(?f32, null), definiteSize(child.style.height, 200, false));
    root.style.height = .{ .px = 200 };
    try testing.expectEqual(@as(?f32, 200), aspectMainSuggestion(child, true, Size.init(300, 200)));
}
