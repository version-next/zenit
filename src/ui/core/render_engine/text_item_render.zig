/// Text Blob and DisplayList text item generation
///
/// Converts node text attributes (TextProps + TextLayout) to text_run / fill_rect items in
/// DisplayList.
/// Includes multiline layout, span segmentation, ellipsis truncation, and smart suffix
/// preservation.
const std = @import("std");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const text_layout = @import("../text_layout.zig");
const layout_engine = @import("../layout_engine.zig");
const text_blob_mod = @import("../text_blob.zig");
const display_list_mod = @import("../display_list.zig");
const render_context_mod = @import("render_context.zig");
const node_state = @import("node_state.zig");
const text_utils = @import("text_utils.zig");
const style_render = @import("node_style_render.zig");
const text_trace = @import("trace").text_flicker;
const grapheme = @import("text_core").grapheme;
const INVALID_ID = @import("../property_tree.zig").INVALID_ID;

const RenderContext = render_context_mod.RenderContext;
const NodeExecutionState = node_state.NodeExecutionState;
const Node = node_mod.Node;
const Color = types.Color;

/// DisplayList text_run.content is a slice of the whole text blob. The Metal
/// text renderer indexes ColorSpan from the start of that slice, while layout
/// spans use offsets in the original blob. Clip and rebase at this boundary.
fn spanForTextRun(span: types.TextSpan, run_start: u32, run_end: u32) ?types.TextSpan {
    const start = @max(span.start, run_start);
    const end = @min(span.end, run_end);
    if (start >= end) return null;
    var local = span;
    local.start = start - run_start;
    local.end = end - run_start;
    return local;
}

test "text run spans use offsets relative to their content slice" {
    const first = types.TextSpan{ .start = 0, .end = 34 };
    const second = types.TextSpan{ .start = 35, .end = 74 };
    try std.testing.expect(spanForTextRun(first, 35, 74) == null);
    const local = spanForTextRun(second, 35, 74).?;
    try std.testing.expectEqual(@as(u32, 0), local.start);
    try std.testing.expectEqual(@as(u32, 39), local.end);
    const clipped = spanForTextRun(.{ .start = 59, .end = 90 }, 35, 74).?;
    try std.testing.expectEqual(@as(u32, 24), clipped.start);
    try std.testing.expectEqual(@as(u32, 39), clipped.end);
}
var bracket_debug_enabled_cache: ?bool = null;
var bracket_debug_last_frame: u64 = std.math.maxInt(u64);
var bracket_debug_last_node: u32 = 0;
var bracket_debug_last_start: u32 = 0;
var bracket_debug_last_end: u32 = 0;
var measure_identity_enabled_cache: ?bool = null;
var measure_identity_ok_logged = false;

fn bracketRenderDebugEnabled() bool {
    if (bracket_debug_enabled_cache) |v| return v;
    const raw = @import("zenit_environment").getNative("ZENIT_TEXT_BRACKET_DEBUG");
    if (raw == null) {
        bracket_debug_enabled_cache = false;
        return false;
    }
    const value = std.mem.span(raw.?);
    const enabled = !(value.len == 0 or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"));
    bracket_debug_enabled_cache = enabled;
    return enabled;
}

fn measureIdentityEnabled() bool {
    if (measure_identity_enabled_cache) |v| return v;
    const raw = @import("zenit_environment").getNative("ZENIT_TEXT_MEASURE_IDENTITY_CHECK");
    if (raw == null) {
        measure_identity_enabled_cache = false;
        return false;
    }
    const value = std.mem.span(raw.?);
    const enabled = !(value.len == 0 or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"));
    measure_identity_enabled_cache = enabled;
    return enabled;
}

fn verifyMeasuredAdvance(content: []const u8, start: u32, end: u32, planned: f32, drawn: f32) void {
    if (!measureIdentityEnabled()) return;
    const diff = @abs(planned - drawn);
    if (diff > 0.5) {
        std.log.err(
            "[text-measure-identity] mismatch planned={d:.3} drawn={d:.3} diff={d:.3} text=\"{s}\"",
            .{ planned, drawn, diff, content[start..end] },
        );
    } else if (!measure_identity_ok_logged) {
        measure_identity_ok_logged = true;
        std.log.info("[text-measure-identity] active; render advances are checked against width-as-drawn", .{});
    }
}

fn shouldLogBracketChunk(frame: u64, node_id: u32, start: u32, end: u32) bool {
    if (bracket_debug_last_frame == frame and
        bracket_debug_last_node == node_id and
        bracket_debug_last_start == start and
        bracket_debug_last_end == end)
    {
        return false;
    }
    bracket_debug_last_frame = frame;
    bracket_debug_last_node = node_id;
    bracket_debug_last_start = start;
    bracket_debug_last_end = end;
    return true;
}

pub fn appendTextBlobForNode(
    cx: *RenderContext,
    node: *Node,
    t: *const types.TextProps,
    tl: ?*const text_layout.TextLayout,
    wrap_width: f32,
    raster_policy: text_blob_mod.TextRasterPolicy,
) !u32 {
    const text_hashes = node.getOrComputeTextHashes(t);
    const layout_spans_hash = if (t.spans_affect_layout) text_hashes.spans_hash else 0;
    var blob = text_blob_mod.TextLayoutBlob{
        .style_key = .{
            .font_size = t.font_size,
            .font_weight = t.font_weight,
            .font_family = t.font_family,
            .line_height = t.line_height,
            .use_italic = t.use_italic_font,
            .use_monospace = t.use_monospace_font,
            .use_symbols = t.use_symbols_font,
            .wrap = t.wrap,
            .max_lines = t.max_lines,
        },
        .content_hash = text_hashes.content_hash,
        .content = t.content,
        .spans_hash = layout_spans_hash,
        .line_count = 1,
        .total_height = t.font_size * t.line_height,
        .max_line_width = 0,
        .wrap_width = wrap_width,
    };

    var single_line: [1]text_blob_mod.LineInfo = undefined;
    var blob_lines: []const text_blob_mod.LineInfo = &single_line;
    if (tl) |layout| {
        blob_lines = layout.lines[0..layout.line_count];
        blob.line_count = layout.line_count;
        blob.total_height = layout.total_height;
        blob.max_line_width = layout.max_line_width;
        blob.wrap_width = if (wrap_width > 0) wrap_width else layout.cached_available_width;
    } else {
        const width = text_layout.measureTextWidthByFontKind(t.content, t.font_size, t.font_weight, t.use_italic_font, t.use_monospace_font);
        single_line[0] = .{
            .byte_start = 0,
            .byte_end = @intCast(t.content.len),
            .width = width,
        };
        blob.max_line_width = width;
    }

    const result = try cx.text_blob_store.appendOrReuseTracked(blob, blob_lines);
    if (!result.reused and t.content.len > 0 and (raster_policy != .static_crisp or blob.line_count > 4)) {
        text_trace.log(
            cx.scene_runtime.frame_epoch,
            "blob-anomaly node={d} blob={d} hash=0x{x} len={d} spans=0x{x} lines={d} wrap={d:.1} policy={s}",
            .{
                node.id,
                result.blob_id,
                blob.content_hash,
                t.content.len,
                blob.spans_hash,
                blob.line_count,
                blob.wrap_width,
                @tagName(raster_policy),
            },
        );
    }
    return result.blob_id;
}

/// Fallback text for blob-backed text_run.
///
/// Normal path reads bytes indirectly via blob_id (saves a copy); but blob_id is frame-local,
/// and items surviving across frames (replay/cache) may land on blobs created by other controls.
/// resolveTextRunContent detects the mismatch via content_hash and falls back here.
/// Empty fallback means the text cannot be rendered even after detection (terminal renders blank).
///
/// Slice points to the node's own text buffer, no extra allocation; empty only on overflow.
fn blobFallbackSlice(content: []const u8, start: u32, end: u32) []const u8 {
    if (start >= end or end > content.len) return "";
    return content[start..end];
}

pub fn appendDisplayRect(
    cx: *RenderContext,
    header: display_list_mod.ItemHeader,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: Color,
    radius: [4]f32,
) !void {
    if (w <= 0 or h <= 0 or color.a == 0) return;
    try cx.display_list.append(.{
        .fill_rect = .{
            .header = header,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .color = color,
            .radius = radius,
        },
    });
}

/// Emits underline draw command in text pipeline based on UnderlineStyle.
/// Command shares same ItemHeader/paint_order with caller's glyph blob; at flush, z-order matches
/// selection highlight.
///
/// thickness <= 0 means use default value from style.
/// Wavy line avoids GPU path stroke (prevents cross-pipeline interleaving loss), approximates sine
/// via multiple narrow fill_rects.
/// A single underline typically has 10-30 rects, total is bounded. Upgrade to path geometry for
/// higher fidelity; API unchanged.
pub fn appendUnderline(
    cx: *RenderContext,
    header: display_list_mod.ItemHeader,
    x: f32,
    y: f32,
    width: f32,
    font_size: f32,
    style: types.UnderlineStyle,
    thickness: f32,
    color: Color,
) !void {
    if (width <= 0 or color.a == 0) return;
    switch (style) {
        .solid => {
            const th = if (thickness > 0) thickness else 1.0;
            try appendDisplayRect(cx, header, x, y, width, th, color, .{ 0, 0, 0, 0 });
        },
        .dashed => {
            const th = if (thickness > 0) thickness else 1.0;
            var dx: f32 = 0;
            while (dx < width) : (dx += 10) {
                try appendDisplayRect(cx, header, x + dx, y, @min(6, width - dx), th, color, .{ 0, 0, 0, 0 });
            }
        },
        .dotted => {
            // Round dots of diameter `th`, one diameter apart (VS Code's hint
            // underline: r = 1 dots every 4px). Only whole dots are drawn.
            const th = if (thickness > 0) thickness else 1.5;
            const r = th * 0.5;
            var dx: f32 = 0;
            while (dx + th <= width + 0.01) : (dx += th * 2) {
                try appendDisplayRect(cx, header, x + dx, y, th, th, color, .{ r, r, r, r });
            }
        },
        .wavy => {
            const params = WavyParams.forFontSize(font_size);
            const th = if (thickness > 0) thickness else params.thickness;
            try appendWavyUnderline(cx, header, x, y, width, th, params, color);
        },
    }
}

/// Wavy line waveform (derived from font size), VS Code's squiggle geometry: its 6×3 px SVG tile
/// (`editorError.foreground` polygons, repeat-x along the bottom of the line box) is one period of
/// 6px, 3px tall overall with a ~1px stroke, measured 12px → 6px period / 6 device px tall at 2x.
/// At 13px that is period 6, centerline peak-to-peak 2, line width 1 (total height 3); it scales
/// with the font size and never drops below a visible 4px period / 1.5px peak-to-peak.
pub const WavyParams = struct {
    period: f32,
    /// Centerline amplitude (half peak-to-peak)
    amplitude: f32,
    /// Default line width
    thickness: f32,

    pub fn forFontSize(font_size: f32) WavyParams {
        return .{
            .period = @max(@as(f32, 4.0), font_size * (6.0 / 13.0)),
            .amplitude = @max(@as(f32, 0.75), font_size / 13.0),
            .thickness = @max(@as(f32, 1.0), font_size * 0.07),
        };
    }

    /// Total height of wavy line (peak-to-peak + line width)
    pub fn totalHeight(self: WavyParams, thickness: f32) f32 {
        return self.amplitude * 2 + thickness;
    }
};

/// Step size along centerline: no more than 0.35x line width; adjacent disks overlap significantly,
/// combining into a continuous, even-width curve (not a staircase).
pub fn wavyDotStep(thickness: f32) f32 {
    return @max(@as(f32, 0.2), thickness * 0.35);
}

/// Pure function: point on centerline at horizontal offset t (x, y is underline top-left; waveform
/// spans [y, y + totalHeight]).
pub fn wavyCenterAt(x: f32, y: f32, t: f32, thickness: f32, params: WavyParams) [2]f32 {
    const phase = (t / params.period) * std.math.pi * 2.0;
    const center_y = y + thickness * 0.5 + params.amplitude;
    return .{ x + t, center_y - std.math.sin(phase) * params.amplitude };
}

/// Wavy line = densely packed SDF disks along sine centerline (fill_rect fully rounded,
/// antialiasing from SDF).
/// Old impl used ~50 segments of 0.64px-wide axis-aligned thin rects with fractional coords,
/// stacked as stairs:
/// each segment self-antialiased, edges soft; fixed 256-segment stack buffer truncated long
/// underlines.
/// Here: no buffering, no truncation, shares same header/paint_order with glyph blob; z-order
/// matches selection highlight.
fn appendWavyUnderline(
    cx: *RenderContext,
    header: display_list_mod.ItemHeader,
    x: f32,
    y: f32,
    width: f32,
    thickness: f32,
    params: WavyParams,
    color: Color,
) !void {
    const r = thickness * 0.5;
    const step = wavyDotStep(thickness);
    var t: f32 = 0;
    while (true) : (t += step) {
        const at = @min(t, width);
        const p = wavyCenterAt(x, y, at, thickness, params);
        try appendDisplayRect(cx, header, p[0] - r, p[1] - r, thickness, thickness, color, .{ r, r, r, r });
        if (at >= width) break;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "WavyParams: 13px diagnostic squiggle has VS Code's 6x3 tile geometry" {
    const p = WavyParams.forFontSize(13);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), p.period, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), p.totalHeight(p.thickness), 1e-4);
    try std.testing.expectEqual(@as(f32, 1.0), p.thickness); // No thinner than visible
    const tiny = WavyParams.forFontSize(6);
    try std.testing.expect(tiny.period >= 4.0 and tiny.amplitude >= 0.75);
    const big = WavyParams.forFontSize(32);
    try std.testing.expect(big.period > p.period and big.amplitude > p.amplitude);
}

test "wavy centerline stays in its band and dots overlap into a continuous stroke" {
    const p = WavyParams.forFontSize(14);
    const th = p.thickness;
    var t: f32 = 0;
    var min_y: f32 = std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    while (t <= 40) : (t += 0.05) {
        const c = wavyCenterAt(10, 100, t, th, p);
        min_y = @min(min_y, c[1] - th * 0.5);
        max_y = @max(max_y, c[1] + th * 0.5);
    }
    // Actual stroke (centerline ± half line width) stays within [y, y + totalHeight], with real
    // undulation
    try std.testing.expect(min_y >= 100 - 1e-3);
    try std.testing.expect(max_y <= 100 + p.totalHeight(th) + 1e-3);
    try std.testing.expect(max_y - min_y > th * 1.5);
    // Distance between adjacent disk centers <= 0.5 x line width: disks must overlap into
    // continuous stroke
    const step = wavyDotStep(th);
    const a = wavyCenterAt(0, 0, 1.0, th, p);
    const b = wavyCenterAt(0, 0, 1.0 + step, th, p);
    const dist = @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
    try std.testing.expect(dist <= th * 0.5);
}

pub fn appendDisplayLineWithSpans(
    cx: *RenderContext,
    header: display_list_mod.ItemHeader,
    content_version: u32,
    t: *const types.TextProps,
    blob_id: u32,
    line_byte_start: u32,
    line_byte_end: u32,
    text_x: f32,
    line_y: f32,
    baseline_y: f32,
    line_h: f32,
    base_text_color: Color,
    raster_policy: text_blob_mod.TextRasterPolicy,
) !void {
    // Span positioning uses text_layout's prefix-width cache below. Rendering
    // normally happens after layoutNode has removed its temporary shaping
    // callback, so without this guard a cache miss is measured by the legacy
    // platform callback while the emitted text run is drawn with FontSelector.
    // The two fonts can differ (most visibly for mono/inline-code), making each
    // following chunk start too early and eventually overlap. Keep the entire
    // line build in the same resolver/cache/font system as layout and drawing.
    var shape_measure_guard = layout_engine.beginExternalShapeMeasure(cx.shaping_cache, cx.font_system);
    defer shape_measure_guard.end();

    // blob_id is frame-local; cross-frame items may land on other controls' blobs.
    // Carries content_hash for resolveTextRunContent to verify the id still points to the same
    // text.
    const blob_content_hash: u64 = if (cx.text_blob_store.get(blob_id)) |bl|
        bl.content_hash
    else
        0;
    const spans = t.spans;
    const content = t.content;
    const font_size = t.font_size;
    const base_fw = t.font_weight;

    // Font-neutral spans (selection, IME, syntax color/highlight) must not split
    // a bidi line into logical-order chunks. Build geometry from the shared
    // visual caret model, paint every disjoint visual rectangle, then emit one
    // whole-line text run so CoreText keeps its original run order/ligatures.
    var visual_only_spans = !t.use_monospace_font;
    for (spans) |span| {
        if (span.font_weight != null or span.use_italic_font or span.use_monospace_font or text_layout.spanHasInlineBox(span)) {
            visual_only_spans = false;
            break;
        }
    }
    if (visual_only_spans) {
        const line_text = content[line_byte_start..line_byte_end];
        if (cx.visualLine(line_text, font_size, base_fw, t.use_italic_font, t.font_family, t.use_monospace_font, t.use_symbols_font)) |visual_line| {
            const rect_storage = try cx.frame_allocator.alloc(@import("text_core").text_coordinates.SelectionRect, @max(visual_line.caret_stops.len, 1));
            const local_spans = try cx.frame_allocator.alloc(types.TextSpan, spans.len);
            var local_span_count: usize = 0;
            for (spans) |span| {
                const seg_start = @max(span.start, line_byte_start);
                const seg_end = @min(span.end, line_byte_end);
                if (seg_start >= seg_end) continue;
                local_spans[local_span_count] = spanForTextRun(span, line_byte_start, line_byte_end).?;
                local_span_count += 1;
                const rects = visual_line.selectionRects(
                    .{ .value = seg_start - line_byte_start },
                    .{ .value = seg_end - line_byte_start },
                    rect_storage,
                ) catch continue;
                for (rects) |rect| {
                    if (span.bg_color) |bg| {
                        try appendDisplayRect(cx, header, text_x + rect.x, line_y + 1, rect.width, line_h - 2, bg, .{ 3, 3, 3, 3 });
                    }
                    const decoration_color = span.color orelse base_text_color;
                    if (span.strikethrough) {
                        try appendDisplayRect(cx, header, text_x + rect.x, line_y + line_h * 0.5, rect.width, 1, decoration_color, .{ 0, 0, 0, 0 });
                    }
                    if (span.underline) {
                        try appendUnderline(
                            cx,
                            header,
                            text_x + rect.x,
                            line_y + line_h - 2 + span.underline_offset,
                            rect.width,
                            font_size,
                            span.underline_style,
                            span.underline_thickness,
                            span.underline_color orelse decoration_color,
                        );
                    }
                }
            }
            try cx.display_list.append(.{
                .text_run = .{
                    .header = header,
                    .x = text_x,
                    .y = baseline_y,
                    .content = blobFallbackSlice(content, line_byte_start, line_byte_end),
                    .blob_byte_start = line_byte_start,
                    .blob_byte_end = line_byte_end,
                    .color = base_text_color,
                    .font_size = font_size,
                    .font_weight = base_fw,
                    .font_family = t.font_family,
                    .use_symbols_font = t.use_symbols_font,
                    .font_smoothing = t.font_smoothing,
                    .use_monospace_font = false,
                    .monospace_char_width = 0,
                    .use_italic_font = t.use_italic_font,
                    .spans = local_spans[0..local_span_count],
                    .blob_id = blob_id,
                    .blob_content_hash = blob_content_hash,
                    .raster_policy = raster_policy,
                },
            });
            return;
        }
    }

    const ChunkKind = enum { gap, span };
    const SpanChunk = struct {
        kind: ChunkKind,
        start: u32,
        end: u32,
        x: f32,
        width: f32,
        text_x: f32,
        text_width: f32,
        font_weight: u16,
        use_italic: bool,
        use_monospace: bool,
        span_index: usize = 0,
    };

    const max_chunks = spans.len * 2 + 1;
    const chunks = try cx.frame_allocator.alloc(SpanChunk, max_chunks);
    var chunk_count: usize = 0;
    var cur_x: f32 = text_x;
    var pos: u32 = line_byte_start;

    const measure_line_range_width = struct {
        fn run(
            ctx: *RenderContext,
            node_id: u32,
            content_version_inner: u32,
            content_inner: []const u8,
            line_start: u32,
            line_end: u32,
            seg_start: u32,
            seg_end: u32,
            font_size_inner: f32,
            font_weight_inner: u16,
            use_italic_inner: bool,
            use_monospace_inner: bool,
            font_family_inner: u16,
            use_symbols_inner: bool,
            spans_inner: []const types.TextSpan,
            extra_advance: f32,
            fixed_monospace_char_width: f32,
        ) f32 {
            if (seg_start >= seg_end) return 0;
            // Monospace + pure ASCII fast path, hits 99% in fixed-width scenarios.
            // Takes measureSegmentWidthCtx -> GlyphRun pipeline (cache hit) /
            // measureMonospaceTextWidth (legacy fallback).
            // Previously every span used prefix cache (~5 spans/line x 2 lookups); during ph_pre
            // spike, cache-miss build was dominant cost.
            if (use_monospace_inner) {
                var is_ascii = true;
                for (content_inner[seg_start..seg_end]) |b| {
                    if (b >= 0x80) {
                        is_ascii = false;
                        break;
                    }
                }
                if (is_ascii) {
                    if (fixed_monospace_char_width > 0) {
                        return @as(f32, @floatFromInt(seg_end - seg_start)) * fixed_monospace_char_width + extra_advance;
                    }
                    return text_utils.measureSegmentWidthCtx(
                        ctx,
                        content_inner[seg_start..seg_end],
                        font_size_inner,
                        font_weight_inner,
                        use_italic_inner,
                        use_monospace_inner,
                        font_family_inner,
                        use_symbols_inner,
                        fixed_monospace_char_width,
                    ) + extra_advance;
                }
            }
            const fallback = text_utils.measureSegmentWidthCtx(
                ctx,
                content_inner[seg_start..seg_end],
                font_size_inner,
                font_weight_inner,
                use_italic_inner,
                use_monospace_inner,
                font_family_inner,
                use_symbols_inner,
                fixed_monospace_char_width,
            ) + extra_advance;
            const start_w = text_layout.measurePrefixWidthRangeCached(
                node_id,
                content_version_inner,
                content_inner,
                line_start,
                line_end,
                seg_start,
                font_size_inner,
                font_weight_inner,
                use_italic_inner,
                use_monospace_inner,
                spans_inner,
            ) orelse return fallback;
            const end_w = text_layout.measurePrefixWidthRangeCached(
                node_id,
                content_version_inner,
                content_inner,
                line_start,
                line_end,
                seg_end,
                font_size_inner,
                font_weight_inner,
                use_italic_inner,
                use_monospace_inner,
                spans_inner,
            ) orelse return fallback;
            const planned = end_w - start_w;
            verifyMeasuredAdvance(content_inner, seg_start, seg_end, planned, fallback);
            return planned;
        }
    }.run;

    for (spans, 0..) |span, span_index| {
        if (span.end <= line_byte_start) continue;
        if (span.start >= line_byte_end) break;

        const seg_start = @max(span.start, line_byte_start);
        const seg_end = @min(span.end, line_byte_end);
        if (seg_start >= seg_end) continue;

        if (pos < seg_start) {
            const gap_w = measure_line_range_width(
                cx,
                header.node_id,
                content_version,
                content,
                line_byte_start,
                line_byte_end,
                pos,
                seg_start,
                font_size,
                base_fw,
                t.use_italic_font,
                t.use_monospace_font,
                t.font_family,
                t.use_symbols_font,
                spans,
                0,
                t.monospace_char_width,
            );
            chunks[chunk_count] = .{
                .kind = .gap,
                .start = pos,
                .end = seg_start,
                .x = cur_x,
                .width = gap_w,
                .text_x = cur_x,
                .text_width = gap_w,
                .font_weight = base_fw,
                .use_italic = t.use_italic_font,
                .use_monospace = t.use_monospace_font,
            };
            chunk_count += 1;
            cur_x += gap_w;
        }

        const seg_fw = span.font_weight orelse base_fw;
        const seg_italic = span.use_italic_font or t.use_italic_font;
        const seg_mono = span.use_monospace_font or t.use_monospace_font;
        const box_metrics = text_layout.inlineBoxMetricsForFragment(span, seg_start, seg_end);
        const seg_w = measure_line_range_width(
            cx,
            header.node_id,
            content_version,
            content,
            line_byte_start,
            line_byte_end,
            seg_start,
            seg_end,
            font_size,
            seg_fw,
            seg_italic,
            seg_mono,
            t.font_family,
            t.use_symbols_font,
            spans,
            box_metrics.totalHorizontalAdvance(),
            t.monospace_char_width,
        );
        const seg_text_w = @max(0, seg_w - box_metrics.totalHorizontalAdvance());
        chunks[chunk_count] = .{
            .kind = .span,
            .start = seg_start,
            .end = seg_end,
            .x = cur_x,
            .width = seg_w,
            .text_x = cur_x + box_metrics.leading_advance,
            .text_width = seg_text_w,
            .font_weight = seg_fw,
            .use_italic = seg_italic,
            .use_monospace = seg_mono,
            .span_index = span_index,
        };
        if (bracketRenderDebugEnabled() and span.bg_color != null and
            shouldLogBracketChunk(cx.scene_runtime.frame_epoch, header.node_id, seg_start, seg_end))
        {
            std.debug.print(
                "[PT-BRACKET] frame={d} chunk node={d} line=[{d},{d}) span=[{d},{d}) chunk_x={d:.1} width={d:.1} text=\"{s}\" full=\"{s}\"\n",
                .{
                    cx.scene_runtime.frame_epoch,
                    header.node_id,
                    line_byte_start,
                    line_byte_end,
                    seg_start,
                    seg_end,
                    cur_x,
                    seg_w,
                    content[seg_start..seg_end],
                    content[line_byte_start..line_byte_end],
                },
            );
        }
        chunk_count += 1;
        cur_x += seg_w;
        pos = seg_end;
    }

    if (pos < line_byte_end) {
        const tail_w = measure_line_range_width(
            cx,
            header.node_id,
            content_version,
            content,
            line_byte_start,
            line_byte_end,
            pos,
            line_byte_end,
            font_size,
            base_fw,
            t.use_italic_font,
            t.use_monospace_font,
            t.font_family,
            t.use_symbols_font,
            spans,
            0,
            t.monospace_char_width,
        );
        chunks[chunk_count] = .{
            .kind = .gap,
            .start = pos,
            .end = line_byte_end,
            .x = cur_x,
            .width = tail_w,
            .text_x = cur_x,
            .text_width = tail_w,
            .font_weight = base_fw,
            .use_italic = t.use_italic_font,
            .use_monospace = t.use_monospace_font,
        };
        chunk_count += 1;
    }

    for (chunks[0..chunk_count]) |chunk| {
        if (chunk.kind != .span) continue;
        const span = spans[chunk.span_index];
        if (span.bg_color) |bg| {
            const overhang_pad = text_layout.estimateItalicOverhangPadding(font_size, chunk.use_italic);
            const box_metrics = text_layout.inlineBoxMetricsForFragment(span, chunk.start, chunk.end);
            const uses_inline_box = text_layout.spanHasInlineBox(span);
            const bg_x = if (uses_inline_box) chunk.x else chunk.x - 2;
            const bg_w = if (uses_inline_box) chunk.width + overhang_pad else chunk.width + 4 + overhang_pad;
            const bg_y = line_y + (if (uses_inline_box) box_metrics.inset_top else 1);
            const bg_h = line_h - (if (uses_inline_box) (box_metrics.inset_top + box_metrics.inset_bottom) else 2);
            const radius = if (uses_inline_box) blk: {
                const left_r = if (box_metrics.leading_advance > 0) box_metrics.corner_radius else 0;
                const right_r = if (box_metrics.trailing_advance > 0) box_metrics.corner_radius else 0;
                break :blk [4]f32{ left_r, right_r, right_r, left_r };
            } else .{ 3, 3, 3, 3 };
            try appendDisplayRect(
                cx,
                header,
                bg_x,
                bg_y,
                bg_w,
                bg_h,
                bg,
                radius,
            );
        }
    }

    // Step 1: merge adjacent chunks with same font attributes into 'runs',
    // so ligature fonts (e.g. JetBrains Mono) calt/liga compose correctly across token boundaries.
    // Within a run only color differs -> drawTextWithSpans (shape once + per-glyph coloring).
    // Run boundary is (font_weight, use_italic, use_monospace);
    // font dimension changes split the run (e.g. keyword bold vs regular).
    var run_start: usize = 0;
    while (run_start < chunk_count) {
        const head = chunks[run_start];
        // Inline box (e.g. inline code left/right padding) offsets chunk text start (text_x) from
        // layout start (x).
        // Such chunks must be standalone runs:
        // once merged with neighbors into continuous shaping, padding offset is lost,
        // text renders flush with background left edge, right side has double padding (asymmetric).
        const head_has_box = head.kind == .span and
            text_layout.spanHasInlineBox(spans[head.span_index]);
        var run_end = run_start + 1;
        if (!head_has_box) {
            while (run_end < chunk_count) : (run_end += 1) {
                const c = chunks[run_end];
                if (c.font_weight != head.font_weight or
                    c.use_italic != head.use_italic or
                    c.use_monospace != head.use_monospace) break;
                if (c.kind == .span and text_layout.spanHasInlineBox(spans[c.span_index])) break;
            }
        }
        const run_chunks = chunks[run_start..run_end];

        // Run's byte range + start x (chunks accumulated by cur_x order);
        // inline box run uses text_x (= x + left padding), so text lands in background center.
        const run_byte_start = run_chunks[0].start;
        const run_byte_end = run_chunks[run_chunks.len - 1].end;
        const run_x = if (head_has_box) head.text_x else run_chunks[0].x;

        // Collect ColorSpans within run: one per chunk
        // (gap uses base_text_color; span uses span.color or base_text_color)
        const run_spans = try cx.frame_allocator.alloc(types.TextSpan, run_chunks.len);
        var span_count: usize = 0;
        for (run_chunks) |c| {
            const c_color = if (c.kind == .span) (spans[c.span_index].color orelse base_text_color) else base_text_color;
            run_spans[span_count] = .{
                .start = c.start - run_byte_start,
                .end = c.end - run_byte_start,
                .color = c_color,
            };
            span_count += 1;
        }

        try cx.display_list.append(.{
            .text_run = .{
                .header = header,
                .x = run_x,
                .y = baseline_y,
                .content = blobFallbackSlice(content, run_byte_start, run_byte_end),
                .blob_byte_start = run_byte_start,
                .blob_byte_end = run_byte_end,
                .color = base_text_color,
                .font_size = font_size,
                .font_weight = head.font_weight,
                .font_family = t.font_family,
                .use_symbols_font = t.use_symbols_font,
                .font_smoothing = t.font_smoothing,
                .use_monospace_font = head.use_monospace,
                .monospace_char_width = if (head.use_monospace) t.monospace_char_width else 0,
                .use_italic_font = head.use_italic,
                .spans = run_spans[0..span_count],
                .blob_id = blob_id,
                .blob_content_hash = blob_content_hash,
                .raster_policy = raster_policy,
            },
        });

        run_start = run_end;
    }

    // Step 2: strikethrough per chunk; underline per run. Chunks split where
    // the text color changes (syntax tokens), but one decoration span across
    // them is one line: a wavy underline drawn per chunk restarts its phase
    // at every token boundary and, when a chunk is a whole number of
    // half-periods wide, paints the boundary dot twice. Adjacent chunks with
    // the same underline (style, color, offset, thickness) are drawn as one.
    var ul_run: ?UnderlineRun = null;
    for (chunks[0..chunk_count]) |chunk| {
        if (chunk.kind != .span) {
            if (ul_run) |run| try run.emit(cx, header, font_size);
            ul_run = null;
            continue;
        }
        const span = spans[chunk.span_index];
        const seg_color = span.color orelse base_text_color;
        if (bracketRenderDebugEnabled() and span.bg_color != null and
            shouldLogBracketChunk(cx.scene_runtime.frame_epoch, header.node_id, chunk.start, chunk.end))
        {
            std.debug.print(
                "[PT-BRACKET] frame={d} text_run node={d} blob=[{d},{d}) x={d:.1} text=\"{s}\"\n",
                .{
                    cx.scene_runtime.frame_epoch,
                    header.node_id,
                    chunk.start,
                    chunk.end,
                    chunk.text_x,
                    content[chunk.start..chunk.end],
                },
            );
        }
        if (span.strikethrough) {
            try appendDisplayRect(cx, header, chunk.text_x, line_y + line_h * 0.5, chunk.text_width, 1, seg_color, .{ 0, 0, 0, 0 });
        }
        if (!span.underline) {
            if (ul_run) |run| try run.emit(cx, header, font_size);
            ul_run = null;
            continue;
        }
        const next: UnderlineRun = .{
            .x = chunk.text_x,
            .width = chunk.text_width,
            .y = line_y + line_h - 2 + span.underline_offset,
            .style = span.underline_style,
            .thickness = span.underline_thickness,
            .color = span.underline_color orelse seg_color,
        };
        if (ul_run) |*run| {
            if (run.continuedBy(next)) {
                run.width = next.x + next.width - run.x;
                continue;
            }
            try run.emit(cx, header, font_size);
        }
        ul_run = next;
    }
    if (ul_run) |run| try run.emit(cx, header, font_size);
}

/// One underline drawn across adjacent chunks (see Step 2 above).
const UnderlineRun = struct {
    x: f32,
    width: f32,
    y: f32,
    style: types.UnderlineStyle,
    thickness: f32,
    color: Color,

    fn continuedBy(self: UnderlineRun, next: UnderlineRun) bool {
        return @abs(self.x + self.width - next.x) < 0.01 and self.y == next.y and self.style == next.style and
            self.thickness == next.thickness and std.meta.eql(self.color, next.color);
    }

    fn emit(self: UnderlineRun, cx: *RenderContext, header: display_list_mod.ItemHeader, font_size: f32) !void {
        try appendUnderline(cx, header, self.x, self.y, self.width, font_size, self.style, self.thickness, self.color);
    }
};

/// Overflow below this (px) is float noise between layout and shaping widths, not truncation.
const ellipsis_overflow_epsilon: f32 = 0.01;

pub fn appendDisplayEllipsisText(
    cx: *RenderContext,
    header: display_list_mod.ItemHeader,
    content_version: u32,
    t: *const types.TextProps,
    blob_id: u32,
    text_x: f32,
    baseline_y: f32,
    avail_w: f32,
    raster_policy: text_blob_mod.TextRasterPolicy,
) !void {
    // blob_id is frame-local; cross-frame items may land on other controls' blobs.
    // Carries content_hash for resolveTextRunContent to verify identity.
    const blob_content_hash: u64 = if (cx.text_blob_store.get(blob_id)) |bl|
        bl.content_hash
    else
        0;
    const content = t.content;
    const font_size = t.font_size;
    const font_weight = t.font_weight;
    const use_italic = t.use_italic_font;
    const ellipsis = "\xe2\x80\xa6";
    const ellipsis_w = text_utils.measureSegmentWidthCtx(cx, ellipsis, font_size, font_weight, use_italic, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width);

    var suffix: []const u8 = "";
    var suffix_start: u32 = @intCast(content.len);
    var suffix_w: f32 = 0;
    if (t.text_overflow == .ellipsis_smart) {
        var dot_pos: ?usize = null;
        var i: usize = content.len;
        while (i > 0) {
            i -= 1;
            if (content[i] == '.') {
                if (i > 0) dot_pos = i;
                break;
            }
        }
        if (dot_pos) |dp| {
            suffix = content[dp..];
            suffix_start = @intCast(dp);
            suffix_w = text_utils.measureSegmentWidthCtx(cx, suffix, font_size, font_weight, use_italic, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width);
        }
    }

    var prefix_budget = avail_w - ellipsis_w - suffix_w;
    if (prefix_budget < 0) {
        suffix = "";
        suffix_start = @intCast(content.len);
        suffix_w = 0;
        prefix_budget = avail_w - ellipsis_w;
    }
    const prefix_range_end = suffix_start;

    var prefix_end: usize = 0;
    var prefix_w: f32 = 0;
    if (text_layout.floorPrefixBoundaryByWidthCached(
        header.node_id,
        content_version,
        content,
        0,
        prefix_range_end,
        prefix_budget,
        font_size,
        font_weight,
        use_italic,
        t.use_monospace_font,
        &.{},
    )) |cached_prefix| {
        prefix_end = cached_prefix.byte_end;
        prefix_w = cached_prefix.width;
    } else {
        const frame_allocator = cx.frame_allocator;
        const boundaries = try frame_allocator.alloc(u32, @as(usize, prefix_range_end) + 1);
        var boundary_count: usize = 1;
        boundaries[0] = 0;
        var cursor: usize = 0;
        var clusters = grapheme.BoundaryCursor.init(content[0..prefix_range_end]);
        while (cursor < prefix_range_end) {
            const next = clusters.next(cursor);
            if (next <= cursor) break;
            boundaries[boundary_count] = @intCast(next);
            boundary_count += 1;
            cursor = next;
        }

        var lo: usize = 0;
        var hi: usize = boundary_count - 1;
        while (lo < hi) {
            const mid = lo + ((hi - lo + 1) / 2);
            const candidate_end: usize = boundaries[mid];
            const w = text_utils.measureSegmentWidthCtx(cx, content[0..candidate_end], font_size, font_weight, use_italic, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width);
            if (w <= prefix_budget) {
                lo = mid;
            } else if (mid == 0) {
                break;
            } else {
                hi = mid - 1;
            }
        }
        prefix_end = boundaries[lo];
        prefix_w = text_utils.measureSegmentWidthCtx(cx, content[0..prefix_end], font_size, font_weight, use_italic, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width);
    }
    // If even the first grapheme does not fit, show only the ellipsis. Forcing
    // one scalar here breaks skin-tone / ZWJ emoji and combining sequences.

    const prefix = content[0..prefix_end];
    var cur_x = text_x;
    if (prefix.len > 0) {
        try cx.display_list.append(.{
            .text_run = .{
                .header = header,
                .x = cur_x,
                .y = baseline_y,
                .content = blobFallbackSlice(content, 0, @intCast(prefix_end)),
                .blob_byte_start = 0,
                .blob_byte_end = @intCast(prefix_end),
                .color = t.color,
                .font_size = font_size,
                .font_weight = font_weight,
                .font_family = t.font_family,
                .use_symbols_font = t.use_symbols_font,
                .font_smoothing = t.font_smoothing,
                .use_monospace_font = t.use_monospace_font,
                .monospace_char_width = t.monospace_char_width,
                .use_italic_font = use_italic,
                .blob_id = blob_id,
                .blob_content_hash = blob_content_hash,
                .raster_policy = raster_policy,
            },
        });
        cur_x += prefix_w;
    }

    try cx.display_list.append(.{
        .text_run = .{
            .header = header,
            .x = cur_x,
            .y = baseline_y,
            .content = ellipsis,
            .color = t.color,
            .font_size = font_size,
            .font_weight = font_weight,
            .use_symbols_font = false,
            .font_smoothing = t.font_smoothing,
            .use_monospace_font = t.use_monospace_font,
            .monospace_char_width = t.monospace_char_width,
            .use_italic_font = use_italic,
            .blob_id = INVALID_ID,
            .raster_policy = raster_policy,
        },
    });
    cur_x += ellipsis_w;

    if (suffix.len > 0) {
        try cx.display_list.append(.{
            .text_run = .{
                .header = header,
                .x = cur_x,
                .y = baseline_y,
                .content = blobFallbackSlice(content, @intCast(t.content.len - suffix.len), @intCast(t.content.len)),
                .blob_byte_start = @intCast(t.content.len - suffix.len),
                .blob_byte_end = @intCast(t.content.len),
                .color = t.color,
                .font_size = font_size,
                .font_weight = font_weight,
                .font_family = t.font_family,
                .use_symbols_font = t.use_symbols_font,
                .font_smoothing = t.font_smoothing,
                .use_monospace_font = t.use_monospace_font,
                .monospace_char_width = t.monospace_char_width,
                .use_italic_font = use_italic,
                .blob_id = blob_id,
                .blob_content_hash = blob_content_hash,
                .raster_policy = raster_policy,
            },
        });
    }
}

pub fn appendDisplayTextItem(
    cx: *RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
    t: *const types.TextProps,
    tl: ?*const text_layout.TextLayout,
) !void {
    try appendDisplayTextItemBorrowed(cx, node, &exec_state, t, tl);
}

pub fn appendDisplayTextItemBorrowed(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    t: *const types.TextProps,
    tl: ?*const text_layout.TextLayout,
) !void {
    const header = style_render.makeDisplayItemHeaderBorrowed(exec_state);
    const raster_policy: text_blob_mod.TextRasterPolicy = if (exec_state.subtree_force_linear_text)
        .animated_stable
    else if (exec_state.is_promoted_layer)
        .surface_cached
    else
        .static_crisp;
    const wrap_width = @max(0, exec_state.render_w - exec_state.pad_left - exec_state.pad_right);
    const blob_id = try appendTextBlobForNode(cx, node, t, tl, wrap_width, raster_policy);
    // Passed with blob_id so resolveTextRunContent can verify the id still points to the same text.
    const blob_content_hash: u64 = if (cx.text_blob_store.get(blob_id)) |bl|
        bl.content_hash
    else
        0;
    const line_h = t.font_size * t.line_height;
    const first_baseline = @import("../layout_engine.zig").firstTextBaseline(t);

    // Per-visual-line alignment (TextProps.text_align): only shifts draw start; uses same formula
    // as host cursor conversion.
    const align_avail_w = @max(0, exec_state.render_w - exec_state.pad_left - exec_state.pad_right);
    if (tl) |layout| {
        var line_y = exec_state.pad_top;
        for (layout.lines[0..layout.line_count]) |line| {
            if (line.byte_start < line.byte_end and line.byte_end <= t.content.len) {
                const line_x = exec_state.pad_left + text_layout.alignLineOffset(t.text_align, align_avail_w, line.width);
                if (t.spans.len > 0) {
                    try appendDisplayLineWithSpans(
                        cx,
                        header,
                        exec_state.retained_runtime.content_version,
                        t,
                        blob_id,
                        line.byte_start,
                        line.byte_end,
                        line_x,
                        line_y,
                        line_y + first_baseline,
                        line_h,
                        t.color,
                        raster_policy,
                    );
                    line_y += line_h;
                    continue;
                }
                try cx.display_list.append(.{
                    .text_run = .{
                        .header = header,
                        .x = line_x,
                        .y = line_y + first_baseline,
                        .content = blobFallbackSlice(t.content, line.byte_start, line.byte_end),
                        .blob_byte_start = line.byte_start,
                        .blob_byte_end = line.byte_end,
                        .color = t.color,
                        .font_size = t.font_size,
                        .font_weight = t.font_weight,
                        .font_family = t.font_family,
                        .use_symbols_font = t.use_symbols_font,
                        .font_smoothing = t.font_smoothing,
                        .use_monospace_font = t.use_monospace_font,
                        .monospace_char_width = t.monospace_char_width,
                        .use_italic_font = t.use_italic_font,
                        .spans = if (t.spans.len > 0) t.spans else null,
                        .blob_id = blob_id,
                        .blob_content_hash = blob_content_hash,
                        .raster_policy = raster_policy,
                    },
                });
                if (t.strikethrough) {
                    try appendDisplayRect(cx, header, line_x, line_y + line_h * 0.5, line.width, 1, t.color, .{ 0, 0, 0, 0 });
                }
            }
            line_y += line_h;
        }
        return;
    }

    const text_h = line_h;
    // A CSS text block starts its first line at the content top. Vertical
    // centering belongs to the containing flex box, not a hidden text offset.
    const text_y = exec_state.pad_top;
    const avail_w = exec_state.render_w - exec_state.pad_left - exec_state.pad_right;
    const need_ellipsis = t.text_overflow != .clip and t.content.len > 0 and t.spans.len == 0;
    if (need_ellipsis) {
        const full_w = if (cx.text_blob_store.get(blob_id)) |blob| blob.max_line_width else text_utils.measureSegmentWidthCtx(cx, t.content, t.font_size, t.font_weight, t.use_italic_font, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width);
        // Layout sizes a fit text node to its measured width through f32 sums, so render_w can
        // land an ulp under full_w; only a real overflow may ellipsize.
        if (full_w - avail_w > ellipsis_overflow_epsilon) {
            try appendDisplayEllipsisText(
                cx,
                header,
                exec_state.retained_runtime.content_version,
                t,
                blob_id,
                exec_state.pad_left,
                text_y + first_baseline,
                avail_w,
                raster_policy,
            );
            return;
        }
    }
    // Single line (no wrapping) also offsets per text_align; returns alignLineOffset = 0 on
    // overflow (ellipsis handled above).
    const single_x = if (t.text_align == .start or t.content.len == 0) exec_state.pad_left else blk: {
        const full_w = if (cx.text_blob_store.get(blob_id)) |blob| blob.max_line_width else text_utils.measureSegmentWidthCtx(cx, t.content, t.font_size, t.font_weight, t.use_italic_font, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width);
        break :blk exec_state.pad_left + text_layout.alignLineOffset(t.text_align, avail_w, full_w);
    };
    if (t.spans.len > 0) {
        try appendDisplayLineWithSpans(
            cx,
            header,
            exec_state.retained_runtime.content_version,
            t,
            blob_id,
            0,
            @intCast(t.content.len),
            single_x,
            text_y,
            text_y + first_baseline,
            text_h,
            t.color,
            raster_policy,
        );
        return;
    }

    try cx.display_list.append(.{
        .text_run = .{
            .header = header,
            .x = single_x,
            .y = text_y + first_baseline,
            .content = blobFallbackSlice(t.content, 0, @intCast(t.content.len)),
            .blob_byte_start = 0,
            .blob_byte_end = @intCast(t.content.len),
            .color = t.color,
            .font_size = t.font_size,
            .font_weight = t.font_weight,
            .font_family = t.font_family,
            .use_symbols_font = t.use_symbols_font,
            .font_smoothing = t.font_smoothing,
            .use_monospace_font = t.use_monospace_font,
            .monospace_char_width = t.monospace_char_width,
            .use_italic_font = t.use_italic_font,
            .blob_id = blob_id,
            .blob_content_hash = blob_content_hash,
            .raster_policy = raster_policy,
            // Right fade mask: window anchor at **available width** end (relative to run start).
            .fade_dx0 = if (t.fade_right > 0) @max(0, avail_w - t.fade_right) else 0,
            .fade_dx1 = if (t.fade_right > 0) avail_w else 0,
        },
    });
    if (t.strikethrough) {
        const strike_w = exec_state.render_w - exec_state.pad_left - exec_state.pad_right;
        try appendDisplayRect(cx, header, exec_state.pad_left, text_y + text_h * 0.5, strike_w, 1, t.color, .{ 0, 0, 0, 0 });
    }
}

test "UnderlineRun: adjacent chunks with the same decoration join into one line" {
    const c0 = std.mem.zeroes(Color);
    var c1 = c0;
    c1.r = 1;
    const a: UnderlineRun = .{ .x = 10, .width = 7.8, .y = 20, .style = .wavy, .thickness = 1, .color = c0 };
    var b = a;
    b.x = 17.8;
    try std.testing.expect(a.continuedBy(b));
    var gap = b;
    gap.x = 19;
    try std.testing.expect(!a.continuedBy(gap));
    var other_color = b;
    other_color.color = c1;
    try std.testing.expect(!a.continuedBy(other_color));
    var other_style = b;
    other_style.style = .solid;
    try std.testing.expect(!a.continuedBy(other_style));
}
