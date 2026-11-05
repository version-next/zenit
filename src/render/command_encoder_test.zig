//! command_encoder_test.zig: RenderCommandEncoder unit tests.
//!
//! Kept separate from command_encoder.zig to avoid file bloat. Zig test blocks in separate files
//! are still collected by `zig build test-render` (see build.zig render_tests module).
//!
//! Tests encoder *internal* behavior, so uses non-pub symbols via qualified paths. A compile
//! failure is intentional: test and implementation stay in sync, better than silently losing
//! coverage.

const std = @import("std");
const ce = @import("command_encoder.zig");
const RenderCommandEncoder = ce.RenderCommandEncoder;
const PersistentGpuCache = ce.PersistentGpuCache;
const lsort = @import("command_encoder/local_sort.zig");
const paint_fp = @import("command_encoder/paint_fingerprint.zig");
const retained_plan = @import("command_encoder/retained_plan.zig");
const ClipShapeKind = ce.ClipShapeKind;
const OffscreenLayer = ce.OffscreenLayer;
const backdrop_blur = @import("backdrop_blur.zig");
const GlassUniforms = backdrop_blur.GlassUniforms;
const text_module = @import("text");
const Font = text_module.Font;
const icon_ir = @import("icon_ir");
const FontSelector = ce.FontSelector;
const font_selector_mod = @import("command_encoder/font_selector.zig");

test "path stroke width stays in logical pixels on Retina" {
    try std.testing.expectApproxEqAbs(@as(f32, 3), ce.pathStrokeWidthForTessellation(3, 1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), ce.pathStrokeWidthForTessellation(3, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), ce.pathStrokeWidthForTessellation(3, 3), 0.001);
}

test "preferKoreanFallback only for hangul-dominant text" {
    try std.testing.expect(RenderCommandEncoder.preferKoreanFallback("안녕하세요 Hello"));
    try std.testing.expect(!RenderCommandEncoder.preferKoreanFallback("中文 · 日本語 · 한국어 · English"));
    try std.testing.expect(!RenderCommandEncoder.preferKoreanFallback("中英混排 Mixed 日本語 테스트 한글"));
}

test "preferCjkFallback only for Han or Kana text" {
    try std.testing.expect(RenderCommandEncoder.preferCjkFallback("中文 mixed English"));
    try std.testing.expect(RenderCommandEncoder.preferCjkFallback("日本語テキスト"));
    try std.testing.expect(RenderCommandEncoder.preferCjkFallback("。！？ punctuation"));
    try std.testing.expect(!RenderCommandEncoder.preferCjkFallback("① ② ③ tokens stride"));
    try std.testing.expect(!RenderCommandEncoder.preferCjkFallback("ASCII only 123"));
    try std.testing.expect(!RenderCommandEncoder.preferCjkFallback("한국어 only"));
}

test "intersectClipRects composes nested bounds" {
    const outer = [4]f32{ 10, 20, 100, 80 };
    const inner = [4]f32{ 50, 40, 100, 50 };
    const clipped = RenderCommandEncoder.intersectClipRects(outer, inner);
    try std.testing.expectApproxEqAbs(@as(f32, 50), clipped[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), clipped[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), clipped[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), clipped[3], 0.001);
}

test "computeBackdropCaptureRegion trims capture to current clip and preserves destination offset" {
    const region = RenderCommandEncoder.computeBackdropCaptureRegion(
        100,
        200,
        80,
        60,
        2,
        .{ 120, 210, 40, 30 },
        0,
        0,
    ).?;

    // Texture alloc size bucketed to 64px (perf: frames in same bucket share pool texture during
    // geometry animation). Logical capture 160x120 -> alloc 192x128; copy/dst semantics unchanged.
    try std.testing.expectEqual(@as(u32, 192), region.tex_w);
    try std.testing.expectEqual(@as(u32, 128), region.tex_h);
    try std.testing.expectEqual(@as(u32, 240), region.src_x);
    try std.testing.expectEqual(@as(u32, 420), region.src_y);
    try std.testing.expectEqual(@as(u32, 80), region.copy_w);
    try std.testing.expectEqual(@as(u32, 60), region.copy_h);
    try std.testing.expectEqual(@as(u32, 40), region.dst_x);
    try std.testing.expectEqual(@as(u32, 20), region.dst_y);
    try std.testing.expect(!region.coversFullTexture());
}

test "computeBackdropCaptureRegion clips negative origin into transparent padded texture" {
    const region = RenderCommandEncoder.computeBackdropCaptureRegion(
        -10,
        -6,
        30,
        20,
        2,
        null,
        0,
        0,
    ).?;

    // 60x40 -> 64px bucket -> 64x64.
    try std.testing.expectEqual(@as(u32, 64), region.tex_w);
    try std.testing.expectEqual(@as(u32, 64), region.tex_h);
    try std.testing.expectEqual(@as(u32, 0), region.src_x);
    try std.testing.expectEqual(@as(u32, 0), region.src_y);
    try std.testing.expectEqual(@as(u32, 40), region.copy_w);
    try std.testing.expectEqual(@as(u32, 28), region.copy_h);
    try std.testing.expectEqual(@as(u32, 20), region.dst_x);
    try std.testing.expectEqual(@as(u32, 12), region.dst_y);
}

test "computeBackdropCaptureRegion rejects non-finite and unrepresentable geometry" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    try std.testing.expect(RenderCommandEncoder.computeBackdropCaptureRegion(nan, 0, 10, 10, 1, null, 0, 0) == null);
    try std.testing.expect(RenderCommandEncoder.computeBackdropCaptureRegion(0, 0, inf, 10, 1, null, 0, 0) == null);
    try std.testing.expect(RenderCommandEncoder.computeBackdropCaptureRegion(0, 0, 10, 10, inf, null, 0, 0) == null);
    try std.testing.expect(RenderCommandEncoder.computeBackdropCaptureRegion(20_000_000, 0, 10, 10, 1, null, 0, 0) == null);
}

test "backdrop content UV preserves fractional padding and clipped physical registration" {
    const region = RenderCommandEncoder.computeBackdropCaptureRegion(129.6, 177.6, 380.8, 124.8, 2, null, 1280, 960).?;
    const uv = region.contentUv(.{ 160, 208, 320, 64 }, 2);
    // 30.4 logical pixels of requested padding becomes 61 physical pixels
    // after the actual source blit origin is floored to (259, 355).
    try std.testing.expectApproxEqAbs(@as(f32, 61), uv[0] * @as(f32, @floatFromInt(region.tex_w)), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 61), uv[1] * @as(f32, @floatFromInt(region.tex_h)), 0.0001);
    const clipped = RenderCommandEncoder.computeBackdropCaptureRegion(-42.65, -9.9, 380.8, 124.8, 2, null, 1280, 960).?;
    const clipped_uv = clipped.contentUv(.{ -12.25, 20.5, 320, 64 }, 2);
    // A visible pixel at world x=0 must address precisely the first copied
    // source pixel even when the node and requested padding are fractional.
    const logical_fraction: f32 = 12.25 / 320.0;
    const captured_x = (clipped_uv[0] + logical_fraction * clipped_uv[2]) * @as(f32, @floatFromInt(clipped.tex_w));
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(clipped.dst_x)), captured_x, 0.0001);
}

test "activeRoundedClip skips pure rect ancestors" {
    var encoder: RenderCommandEncoder = undefined;
    encoder.clip_depth = 3;
    encoder.logical_clip_stack[0] = .{ .x = 0, .y = 0, .w = 200, .h = 120, .radii = .{ 0, 0, 0, 0 }, .shape_kind = .rect };
    encoder.logical_clip_stack[1] = .{ .x = 8, .y = 8, .w = 160, .h = 90, .radii = .{ 12, 12, 12, 12 }, .shape_kind = .rounded_rect };
    encoder.logical_clip_stack[2] = .{ .x = 12, .y = 12, .w = 120, .h = 60, .radii = .{ 0, 0, 0, 0 }, .shape_kind = .rect };

    try std.testing.expect(encoder.activeRoundedClip() != null);
    const clip = encoder.activeRoundedClip().?;
    try std.testing.expectEqual(ClipShapeKind.rounded_rect, clip.shape_kind);
    try std.testing.expectApproxEqAbs(@as(f32, 12), clip.radii[0], 0.001);
}

test "restoreSavedClipState preserves parent clip stack after offscreen mutation" {
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    encoder.clip_depth = 2;
    encoder.logical_clip_stack[0] = .{ .x = 10, .y = 20, .w = 300, .h = 200, .radii = .{ 0, 0, 0, 0 }, .shape_kind = .rect };
    encoder.logical_clip_stack[1] = .{ .x = 30, .y = 40, .w = 120, .h = 80, .radii = .{ 12, 12, 12, 12 }, .shape_kind = .rounded_rect };
    encoder.effective_rect_clip_stack[0] = .{ 10, 20, 300, 200 };
    encoder.effective_rect_clip_stack[1] = .{ 30, 40, 120, 80 };

    var layer = OffscreenLayer{
        .texture = undefined,
        .render_pass = undefined,
        .restore_target = undefined,
        .saved_clip_depth = 0,
        .saved_viewport_width = 0,
        .saved_viewport_height = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .opacity = 1,
        .texture_id = 0,
    };
    layer.saved_clip_depth = encoder.clip_depth;
    layer.saved_logical_clip_stack = encoder.logical_clip_stack;
    layer.saved_effective_rect_clip_stack = encoder.effective_rect_clip_stack;

    // Simulate offscreen-local clip mutations reusing stack slot 0.
    encoder.clip_depth = 1;
    encoder.logical_clip_stack[0] = .{ .x = 0, .y = 0, .w = 40, .h = 20, .radii = .{ 0, 0, 0, 0 }, .shape_kind = .rect };
    encoder.effective_rect_clip_stack[0] = .{ 0, 0, 40, 20 };

    encoder.restoreSavedClipState(layer);

    try std.testing.expectEqual(@as(usize, 2), encoder.clip_depth);
    try std.testing.expectApproxEqAbs(@as(f32, 10), encoder.logical_clip_stack[0].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), encoder.logical_clip_stack[1].x, 0.001);
    try std.testing.expectEqual(ClipShapeKind.rounded_rect, encoder.logical_clip_stack[1].shape_kind);
    try std.testing.expectApproxEqAbs(@as(f32, 120), encoder.effective_rect_clip_stack[1][2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), encoder.effective_rect_clip_stack[1][3], 0.001);
}

test "clip 栈溢出：被忽略的 push 对应的 pop 不能弹掉父级 clip" {
    // Regression: pushClip at depth >= 64 silently skipped, but popClip unconditionally pops; each
    // pop in the overflow segment ejects a real parent clip layer, misaligning content clipping
    // downstream.
    var sdf: @import("sdf_renderer.zig").SdfRenderer = undefined;
    var txt: @import("text_renderer.zig").TextRenderer = undefined;
    txt.viewport_logical_width = 800;
    var pgc = PersistentGpuCache{};
    var encoder = RenderCommandEncoder{
        .sdf_renderer = &sdf,
        .text_renderer = &txt,
        .offscreen_pool = undefined,
        .persistent = &pgc,
    };
    const empty_poly = ce.ClipPolygon.empty();
    var i: usize = 0;
    while (i < 66) : (i += 1) {
        try encoder.pushClip(@floatFromInt(i), 0, 500, 500, .{ 0, 0, 0, 0 }, .rect, empty_poly);
    }
    try std.testing.expectEqual(@as(usize, 64), encoder.clip_depth);
    try std.testing.expectEqual(@as(u32, 2), encoder.clip_overflow_depth);
    // Pop twice: only cancels two ignored pushes, real stack unchanged.
    try encoder.popClip();
    try encoder.popClip();
    try std.testing.expectEqual(@as(usize, 64), encoder.clip_depth);
    try std.testing.expectEqual(@as(u32, 0), encoder.clip_overflow_depth);
    // Third pop ejects real layer 64.
    try encoder.popClip();
    try std.testing.expectEqual(@as(usize, 63), encoder.clip_depth);
    try std.testing.expectApproxEqAbs(@as(f32, 62), encoder.logical_clip_stack[encoder.clip_depth - 1].x, 0.001);
}

test "pushClip: per-corner rounded clip reaches every pipeline mask, clamped like the fill" {
    var sdf: @import("sdf_renderer.zig").SdfRenderer = undefined;
    var txt: @import("text_renderer.zig").TextRenderer = undefined;
    txt.viewport_logical_width = 800;
    var pgc = PersistentGpuCache{};
    var encoder = RenderCommandEncoder{
        .sdf_renderer = &sdf,
        .text_renderer = &txt,
        .offscreen_pool = undefined,
        .persistent = &pgc,
    };
    // TL 20, TR square, BR 10, BL oversized: each corner caps at half the shorter side (15).
    try encoder.pushClip(10, 20, 40, 30, .{ 20, 0, 10, 9999 }, .rounded_rect, ce.ClipPolygon.empty());
    const expected = [4]f32{ 15, 0, 10, 15 };
    try std.testing.expectEqual(expected, encoder.activeRoundedClip().?.radii);
    try std.testing.expectEqual(@as(u32, 1), sdf.clip_shape_kind);
    try std.testing.expectEqual(expected, sdf.clip_radii);
    try std.testing.expectEqual([4]f32{ 10, 20, 40, 30 }, sdf.clip_rect);
    try std.testing.expectEqual(@as(u32, 1), txt.clip_shape_kind);
    try std.testing.expectEqual(expected, txt.clip_radii);

    // A clip differing in one corner is a different mask (forces a flush boundary).
    const prev = encoder.activeRoundedClip();
    try encoder.pushClip(10, 20, 40, 30, .{ 20, 1, 10, 9999 }, .rounded_rect, ce.ClipPolygon.empty());
    try std.testing.expectEqual([4]f32{ 15, 1, 10, 15 }, sdf.clip_radii);
    try std.testing.expect(prev != null and prev.?.radii[1] != encoder.activeRoundedClip().?.radii[1]);

    try encoder.popClip();
    try encoder.popClip();
    try std.testing.expect(encoder.activeRoundedClip() == null);
    try std.testing.expectEqual(@as(u32, 0), sdf.clip_shape_kind);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, sdf.clip_radii);
}

test "pushClipCommand: nested shape clips keep the exact intersection in the single mask slot" {
    var sdf: @import("sdf_renderer.zig").SdfRenderer = undefined;
    var txt: @import("text_renderer.zig").TextRenderer = undefined;
    txt.viewport_logical_width = 800;
    var pgc = PersistentGpuCache{};
    var encoder = RenderCommandEncoder{
        .sdf_renderer = &sdf,
        .text_renderer = &txt,
        .offscreen_pool = undefined,
        .persistent = &pgc,
    };
    const none = ce.ClipPolygon.empty();
    // Parent 100x40 r20; child same box rounding only TR 10 (the review's case): one shape, the
    // parent's radius kept at every corner.
    try std.testing.expectEqual(ce.PushClipMode.clip, try encoder.pushClipCommand(0, 0, 100, 40, .{ 20, 20, 20, 20 }, .rounded_rect, none));
    try std.testing.expectEqual(ce.PushClipMode.clip, try encoder.pushClipCommand(0, 0, 100, 40, .{ 0, 10, 0, 0 }, .rounded_rect, none));
    try std.testing.expectEqual([4]f32{ 20, 20, 20, 20 }, sdf.clip_radii);
    try std.testing.expectEqual(@as(u32, 1), sdf.clip_shape_kind);
    // A pill-radius child over the same box merges after normalisation (9999 -> 20).
    try std.testing.expectEqual(ce.PushClipMode.clip, try encoder.pushClipCommand(0, 0, 100, 40, .{ 0, 0, 9999, 0 }, .rounded_rect, none));
    try std.testing.expectEqual([4]f32{ 20, 20, 20, 20 }, sdf.clip_radii);
    try encoder.popClip();
    try encoder.popClip();
    // A child well inside the parent's arcs replaces it in the mask.
    _ = try encoder.pushClipCommand(20, 8, 60, 24, .{ 4, 4, 4, 4 }, .rounded_rect, none);
    try std.testing.expectEqual([4]f32{ 20, 8, 60, 24 }, sdf.clip_rect);
    try std.testing.expectEqual([4]f32{ 4, 4, 4, 4 }, sdf.clip_radii);
    try encoder.popClip();
    // A child containing the parent only narrows the rect clip; the parent's shape stays.
    _ = try encoder.pushClipCommand(-10, -10, 120, 60, .{ 2, 2, 2, 2 }, .rounded_rect, none);
    try std.testing.expectEqual([4]f32{ 0, 0, 100, 40 }, sdf.clip_rect);
    try std.testing.expectEqual([4]f32{ 20, 20, 20, 20 }, sdf.clip_radii);
    try std.testing.expectEqual(ce.ClipShapeKind.rect, encoder.logical_clip_stack[encoder.clip_depth - 1].shape_kind);
    try encoder.popClip();
    try std.testing.expectEqual(ce.PushClipMode.clip, try encoder.pushClipCommand(0, 0, 70, 40, .{ 0, 12, 0, 0 }, .rounded_rect, none));
    if (comptime @import("shape_clip_pair.zig").supported) {
        // Two crossing shapes pair: the new one is the primary, the parent its partner.
        try std.testing.expectEqual(@as(u32, 0), encoder.isolated_clip_fallbacks);
        try std.testing.expectEqual([4]f32{ 0, 12, 0, 0 }, sdf.clip_radii);
        try std.testing.expectEqual(@as(u32, 1), sdf.clip2.kind);
        try std.testing.expectEqual([4]f32{ 0, 0, 100, 40 }, sdf.clip2.rect);
        try std.testing.expectEqual([4]f32{ 20, 20, 20, 20 }, sdf.clip2.radii);
        // A third shape crossing both inside the rect clip needs an isolation layer; without a
        // render target none can open, so the innermost shape applies alone and the fallback is
        // counted.
        try std.testing.expectEqual(ce.PushClipMode.clip, try encoder.pushClipCommand(5, -5, 60, 50, .{ 10, 10, 10, 10 }, .rounded_rect, none));
        try std.testing.expectEqual(@as(u32, 1), encoder.isolated_clip_fallbacks);
        try std.testing.expectEqual([4]f32{ 10, 10, 10, 10 }, sdf.clip_radii);
        try std.testing.expectEqual(@as(u32, 0), sdf.clip2.kind);
        try encoder.popClip();
        // Popping restores the pair.
        try std.testing.expectEqual(@as(u32, 1), sdf.clip2.kind);
        try std.testing.expectEqual([4]f32{ 0, 12, 0, 0 }, sdf.clip_radii);
    } else {
        // Crossing shapes need an isolation layer; without a render target none can open, so the
        // innermost shape applies (the pre-isolation behaviour) and the fallback is counted.
        try std.testing.expectEqual(@as(u32, 1), encoder.isolated_clip_fallbacks);
        try std.testing.expectEqual([4]f32{ 0, 12, 0, 0 }, sdf.clip_radii);
    }
    try encoder.popClip();
    try encoder.popClip();
    try std.testing.expect(encoder.activeRoundedClip() == null);
    try std.testing.expectEqual(@as(u32, 0), sdf.clip_shape_kind);
}

test "localizeDrawTransformForCurrentTarget subtracts cumulative offscreen offset" {
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    encoder.offscreen_depth = 2;
    encoder.offscreen_stack[0].x = 120;
    encoder.offscreen_stack[0].y = 48;
    encoder.offscreen_stack[1].x = 36;
    encoder.offscreen_stack[1].y = 18;

    const localized = encoder.localizeDrawTransformForCurrentTarget(.{ 1, 0, 0, 1, 240, 160 });
    try std.testing.expectApproxEqAbs(@as(f32, 84), localized[4], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 94), localized[5], 0.001);
}

test "offscreenLocalRectToWorld maps glass in a scaled / translated surface back to screen space" {
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    // Matches storybook testing: layer geom from (-10,-10) (shadow margin), composite matrix scale
    // 0.8, texture origin at world (382,321). Glass in layer at (0,0,300,90).
    encoder.offscreen_depth = 1;
    encoder.offscreen_stack[0].x = -10;
    encoder.offscreen_stack[0].y = -10;
    encoder.offscreen_stack[0].w = 320;
    encoder.offscreen_stack[0].h = 110;
    encoder.offscreen_stack[0].use_draw_transform = true;
    encoder.offscreen_stack[0].draw_transform = .{ 0.8, 0, 0, 0.8, 382, 321 };
    const r = backdrop_blur.offscreenLocalRectToWorld(&encoder, 0, 0, 300, 90);
    try std.testing.expectApproxEqAbs(@as(f32, 390), r[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 329), r[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 240), r[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 72), r[3], 0.01);

    // Nesting: outer translate-only offscreen (non-matrix, draw rect 2x magnified), inner matrix
    // translate.
    encoder.offscreen_depth = 2;
    encoder.offscreen_stack[0] = encoder.offscreen_stack[1];
    encoder.offscreen_stack[0].x = 100;
    encoder.offscreen_stack[0].y = 50;
    encoder.offscreen_stack[0].w = 200;
    encoder.offscreen_stack[0].h = 100;
    encoder.offscreen_stack[0].use_draw_transform = false;
    encoder.offscreen_stack[0].draw_x = 100;
    encoder.offscreen_stack[0].draw_y = 50;
    encoder.offscreen_stack[0].draw_w = 400;
    encoder.offscreen_stack[0].draw_h = 200;
    encoder.offscreen_stack[1].x = 0;
    encoder.offscreen_stack[1].y = 0;
    encoder.offscreen_stack[1].use_draw_transform = true;
    // Inner matrix output: outer frame not localized coordinates: in outer (110,60) = outer texture
    // local (10,10).
    encoder.offscreen_stack[1].draw_transform = .{ 1, 0, 0, 1, 110, 60 };
    const n = backdrop_blur.offscreenLocalRectToWorld(&encoder, 0, 0, 20, 10);
    try std.testing.expect(n[2] > 39.9 and n[2] < 40.1); // Outer 2x magnified: width 20 -> 40.
    try std.testing.expect(n[3] > 19.9 and n[3] < 20.1);
}

test "layerMagnification: only magnifying composites raise the raster scale (capped at 4)" {
    const ol = @import("opacity_layer.zig");
    // Matrix scale 2: rasterize at 2x (magnified composite no longer stretches 1x bitmap).
    try std.testing.expectApproxEqAbs(@as(f32, 2), ol.layerMagnification(true, .{ 2, 0, 0, 2, 10, 10 }, 100, 50, 0, 0), 1e-5);
    // Downscale does not reduce resolution.
    try std.testing.expectApproxEqAbs(@as(f32, 1), ol.layerMagnification(true, .{ 0.5, 0, 0, 0.5, 0, 0 }, 100, 50, 0, 0), 1e-5);
    // Rotation + scale: take column vector length.
    const c: f32 = 1.5 * @cos(@as(f32, 0.3));
    const sn: f32 = 1.5 * @sin(@as(f32, 0.3));
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), ol.layerMagnification(true, .{ c, sn, -sn, c, 0, 0 }, 100, 50, 0, 0), 1e-4);
    // Non-matrix layer by draw size / source size; cap 4.
    try std.testing.expectApproxEqAbs(@as(f32, 3), ol.layerMagnification(false, .{ 1, 0, 0, 1, 0, 0 }, 100, 50, 300, 50), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), ol.layerMagnification(true, .{ 9, 0, 0, 9, 0, 0 }, 100, 50, 0, 0), 1e-5);
}

test "text without shaped ink bounds fences local sorting" {
    const Kind = enum { none, rect, text, image, shadow, gradient, path, control };
    const command = .{ .kind = Kind.text, .arc_outer_radius = @as(f32, 0), .icon_rep_ptr = @as(?*const u8, null) };
    try std.testing.expectEqual(lsort.PipelineKind.fence, lsort.localSortPipelineKind(command));
}

const InkGlyph = struct { position: [2]f32, size: [2]f32, skew_x: f32 = 0 };

test "text ink: a command clear of every pending glyph quad may draw before the text" {
    var ink: ce.InkSet = .{};
    var nearest = [_]InkGlyph{ .{ .position = .{ 10, 10 }, .size = .{ 8, 12 } }, .{ .position = .{ 20, 10 }, .size = .{ 8, 12 } } };
    const linear = [_]InkGlyph{};
    // Glyph run covers x 9..29, y 9..23 (one logical pixel of snapping pad).
    try std.testing.expect(ink.allows(1, .{ nearest[0..], linear[0..] }, .{ 0, 30, 100, 40 }));
    try std.testing.expect(!ink.allows(1, .{ nearest[0..], linear[0..] }, .{ 28, 0, 40, 9.5 }));
    // Touching edges do not overlap.
    try std.testing.expect(ink.allows(1, .{ nearest[0..], linear[0..] }, .{ 29, 0, 40, 40 }));
    // A synthetic-italic skew widens the top edge.
    const skewed = [_]InkGlyph{.{ .position = .{ 50, 10 }, .size = .{ 8, 12 }, .skew_x = 4 }};
    try std.testing.expect(!ink.allows(1, .{ nearest[0..], skewed[0..] }, .{ 61.5, 0, 70, 40 }));
}

test "text ink covers glyphs appended after a check and forgets flushed ones" {
    var ink: ce.InkSet = .{};
    var glyphs = [_]InkGlyph{ .{ .position = .{ 10, 10 }, .size = .{ 8, 8 } }, .{ .position = .{ 200, 10 }, .size = .{ 8, 8 } } };
    const none = [_]InkGlyph{};
    const probe = [4]f32{ 199, 0, 220, 30 };
    try std.testing.expect(ink.allows(7, .{ glyphs[0..1], none[0..] }, probe));
    // The second glyph is appended later (any emission path): it must be seen.
    try std.testing.expect(!ink.allows(7, .{ glyphs[0..2], none[0..] }, probe));
    // Flushed (generation advanced): nothing pending covers the probe any more.
    try std.testing.expect(ink.allows(8, .{ glyphs[0..0], none[0..] }, probe));
    // Flushed and refilled past the old count within one generation change: rescanned from 0.
    try std.testing.expect(!ink.allows(9, .{ glyphs[1..2], glyphs[0..1] }, probe));
}

test "text ink: a flush refilled to the same count is a new set of glyphs" {
    var ink: ce.InkSet = .{};
    const old = [_]InkGlyph{ .{ .position = .{ 10, 10 }, .size = .{ 8, 8 } }, .{ .position = .{ 30, 10 }, .size = .{ 8, 8 } } };
    const new = [_]InkGlyph{ .{ .position = .{ 300, 10 }, .size = .{ 8, 8 } }, .{ .position = .{ 330, 10 }, .size = .{ 8, 8 } } };
    const none = [_]InkGlyph{};
    try std.testing.expect(!ink.allows(3, .{ old[0..], none[0..] }, .{ 0, 0, 20, 20 }));
    // Same lengths after the renderer flushed and re-emitted: old quads gone, new ones seen.
    try std.testing.expect(ink.allows(4, .{ new[0..], none[0..] }, .{ 0, 0, 20, 20 }));
    try std.testing.expect(!ink.allows(4, .{ new[0..], none[0..] }, .{ 299, 0, 320, 20 }));
}

test "text ink folds overflowing runs into one box that still covers them" {
    var ink: ce.InkSet = .{};
    var glyphs: [40]InkGlyph = undefined;
    for (&glyphs, 0..) |*g, i| g.* = .{ .position = .{ @floatFromInt(i * 100), 0 }, .size = .{ 10, 10 } };
    const none = [_]InkGlyph{};
    for (1..glyphs.len + 1) |n| _ = ink.allows(1, .{ glyphs[0..n], none[0..] }, .{ -100, -100, -90, -90 });
    for (glyphs) |g| try std.testing.expect(!ink.allows(1, .{ glyphs[0..], none[0..] }, .{ g.position[0] + 2, 2, g.position[0] + 4, 4 }));
}

test "command paint bounds: SDF quads with shadow reach, offset, and no answer when transformed" {
    const Kind = enum { none, rect, text, image, shadow, gradient, path, control };
    const Item = struct {
        kind: Kind,
        geom: struct { x: f32, y: f32, w: f32, h: f32 },
        use_draw_transform: bool = false,
        rotate: f32 = 0,
        arc_outer_radius: f32 = 0,
        shadow_blur: f32 = 0,
        shadow_offset_x: f32 = 0,
        shadow_offset_y: f32 = 0,
        shadow_spread: f32 = 0,
        shadow2_color: struct { a: f32 = 0 } = .{},
        shadow2_blur: f32 = 0,
        shadow2_offset_x: f32 = 0,
        shadow2_offset_y: f32 = 0,
    };
    const rect: Item = .{ .kind = .rect, .geom = .{ .x = 10, .y = 20, .w = 30, .h = 40 } };
    try std.testing.expectEqual([4]f32{ 104, 9, 136, 51 }, RenderCommandEncoder.commandPaintBounds(rect, 95, -10).?);
    const shadow: Item = .{ .kind = .shadow, .geom = .{ .x = 10, .y = 20, .w = 30, .h = 40 }, .shadow_blur = 4, .shadow_offset_y = 2 };
    // Shadow quad: blur * 2 + |offset| on every side.
    try std.testing.expectEqual([4]f32{ -1, 9, 51, 71 }, RenderCommandEncoder.commandPaintBounds(shadow, 0, 0).?);
    var moved = rect;
    moved.use_draw_transform = true;
    try std.testing.expect(RenderCommandEncoder.commandPaintBounds(moved, 0, 0) == null);
    moved = rect;
    moved.rotate = 0.5;
    try std.testing.expect(RenderCommandEncoder.commandPaintBounds(moved, 0, 0) == null);
    const text: Item = .{ .kind = .text, .geom = .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
    try std.testing.expect(RenderCommandEncoder.commandPaintBounds(text, 0, 0) == null);
}

test "dynamic blur uniform slots advance within a frame" {
    var pgc = PersistentGpuCache{};
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = &pgc,
    };

    try std.testing.expectEqual(@as(?u32, 0), backdrop_blur.acquireKawaseUniformSlot(&encoder));
    try std.testing.expectEqual(@as(?u32, 1), backdrop_blur.acquireKawaseUniformSlot(&encoder));
    try std.testing.expectEqual(@as(u32, 0), backdrop_blur.acquireGlassUniformSlot(&encoder));
    try std.testing.expectEqual(@as(u32, 1), backdrop_blur.acquireGlassUniformSlot(&encoder));
}

test "kawase uniform slots exhaust to null instead of clamping onto the last slot" {
    // Regression: exhausted state once clamped to 511 to reuse; draw encoded but not submitted,
    // later write overwrote prior pass uniform (silent bad frame). Correct semantics: null ->
    // caller terminates blur chain.
    var pgc = PersistentGpuCache{};
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = &pgc,
    };

    var i: u32 = 0;
    while (i < backdrop_blur.max_kawase_uniform_updates) : (i += 1) {
        try std.testing.expectEqual(@as(?u32, i), backdrop_blur.acquireKawaseUniformSlot(&encoder));
    }
    try std.testing.expectEqual(@as(?u32, null), backdrop_blur.acquireKawaseUniformSlot(&encoder));
    try std.testing.expectEqual(@as(?u32, null), backdrop_blur.acquireKawaseUniformSlot(&encoder));

    // After frame boundary reset, allocation resumes.
    backdrop_blur.resetDynamicUniformOffsets(&encoder);
    try std.testing.expectEqual(@as(?u32, 0), backdrop_blur.acquireKawaseUniformSlot(&encoder));
}

test "blur chain params: continuous, monotonic, DPI-invariant" {
    // Equivalent physics footprint offset_scale*3*2^levels must equal r_phys (continuity +
    // monotonicity guarantee); same logic radius yields equivalent logic blur at 1x/2x/3x.
    const scales = [_]f32{ 1.0, 2.0, 3.0 };
    var r: f32 = 0.5;
    while (r <= 96.0) : (r += 0.5) {
        for (scales) |s| {
            const c = backdrop_blur.blurChainParams(r, s);
            try std.testing.expect(c.levels >= 1 and c.levels <= 6);
            const effective_logical = c.offset_scale * 3.0 * std.math.pow(f32, 2.0, @floatFromInt(c.levels)) / s;
            // After the 6-level cap the chain saturates (large radius on a 3x screen); before
            // saturation the effective radius must equal r exactly.
            const cap_logical = 3.0 * 64.0 / s;
            if (r <= cap_logical) {
                try std.testing.expectApproxEqRel(r, effective_logical, 1e-5);
            } else {
                try std.testing.expect(c.levels == 6);
            }
        }
    }
    // Out-of-range clamp: >96 and 96 take same params.
    const at_cap = backdrop_blur.blurChainParams(96.0, 2.0);
    const beyond = backdrop_blur.blurChainParams(500.0, 2.0);
    try std.testing.expectEqual(at_cap.levels, beyond.levels);
    try std.testing.expectApproxEqRel(at_cap.offset_scale, beyond.offset_scale, 1e-6);
}

test "glass uniform layout matches Metal constant buffer offsets" {
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(GlassUniforms, "glass_tint"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(GlassUniforms, "specular_params"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(GlassUniforms, "optic_params"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(GlassUniforms, "surface_params"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(GlassUniforms, "bottom_surface_params"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(GlassUniforms, "lens_params"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(GlassUniforms, "content_uv"));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(GlassUniforms, "edge_params"));
    try std.testing.expectEqual(@as(usize, 160), @offsetOf(GlassUniforms, "edge_stop_pos"));
    try std.testing.expectEqual(@as(usize, 176), @offsetOf(GlassUniforms, "edge_stop_str"));
    try std.testing.expectEqual(@as(usize, 192), @offsetOf(GlassUniforms, "valid_uv"));
    try std.testing.expectEqual(@as(usize, 208), @offsetOf(GlassUniforms, "native_params"));
    try std.testing.expectEqual(@as(usize, 224), @offsetOf(GlassUniforms, "native_blur"));
    try std.testing.expectEqual(@as(usize, 240), @offsetOf(GlassUniforms, "coarse_uv"));
    try std.testing.expectEqual(@as(usize, 336), @offsetOf(GlassUniforms, "native_tint_response"));
    try std.testing.expectEqual(@as(usize, 352), @offsetOf(GlassUniforms, "group_params"));
    try std.testing.expectEqual(@as(usize, 368), @offsetOf(GlassUniforms, "shape_rect"));
    try std.testing.expectEqual(@as(usize, 1008), @offsetOf(GlassUniforms, "shape_misc"));
    try std.testing.expectEqual(@as(usize, 1136), @offsetOf(GlassUniforms, "shape_shadow"));
    try std.testing.expectEqual(@as(usize, 1264), @offsetOf(GlassUniforms, "shape_level"));
    try std.testing.expectEqual(@as(usize, 1392), @offsetOf(GlassUniforms, "knob_rim_dark"));
    try std.testing.expectEqual(@as(usize, 1424), @offsetOf(GlassUniforms, "a11y_params"));
    try std.testing.expectEqual(@as(usize, 1440), @offsetOf(GlassUniforms, "corner_radii"));
    try std.testing.expectEqual(@as(usize, 1456), @offsetOf(GlassUniforms, "arrow_params"));
    try std.testing.expectEqual(@as(usize, 1472), @offsetOf(GlassUniforms, "base_veil"));
    try std.testing.expectEqual(@as(usize, 1488), @offsetOf(GlassUniforms, "veil_curve"));
    try std.testing.expectEqual(@as(usize, 1568), @offsetOf(GlassUniforms, "tab_lens_params"));
    try std.testing.expectEqual(@as(usize, 1664), @sizeOf(GlassUniforms));
}

test "dynamic blur uniform slots reset per frame" {
    var pgc = PersistentGpuCache{};
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = &pgc,
    };

    _ = backdrop_blur.acquireKawaseUniformSlot(&encoder);
    _ = backdrop_blur.acquireKawaseUniformSlot(&encoder);
    _ = backdrop_blur.acquireGlassUniformSlot(&encoder);
    backdrop_blur.resetDynamicUniformOffsets(&encoder);

    try std.testing.expectEqual(@as(?u32, 0), backdrop_blur.acquireKawaseUniformSlot(&encoder));
    try std.testing.expectEqual(@as(u32, 0), backdrop_blur.acquireGlassUniformSlot(&encoder));
}

test "FontSelector stable selection prefers oversampling candidate during animated text" {
    var font12 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 12,
        .size_px = 12,
        .weight = 400,
    };
    var font14 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 14,
        .size_px = 14,
        .weight = 400,
    };
    var font16 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 16,
        .size_px = 16,
        .weight = 400,
    };

    var selector = FontSelector{
        .small = &font12,
        .medium = &font14,
        .large = &font16,
    };

    try std.testing.expect(selector.selectWeightedStable(15, 400) == &font16);
    try std.testing.expect(selector.selectWeightedStable(13, 400) == &font14);
}

/// Glyph pen positions of `text` as the renderer lays them out (drawTextWithOptions: each glyph
/// advances by x_advance * requested_size / shaping font px), plus the run's total width.
fn shapedPenPositions(shaper: *text_module.TextShaper, selector: *FontSelector, text: []const u8, props: font_selector_mod.TextFontProps, out: []f32) !f32 {
    const font = selector.resolveFonts(text, props).primary;
    const glyphs = try shaper.shapeWithOptions(text, font, false);
    defer std.testing.allocator.free(glyphs);
    const layout_scale = props.font_size / font.pixelSize();
    var x: f32 = 0;
    for (glyphs, 0..) |glyph, i| {
        out[i] = x;
        x += glyph.x_advance * layout_scale;
    }
    return x;
}

test "text layout is identical under the static and animated raster policies" {
    // A run switching between static_crisp and animated_stable (an animation starting or
    // ending) must not move a single glyph. The animated policy used to shape with the nearest
    // preloaded instance scaled to the requested size; SF's size-dependent tracking then gave
    // different advances than the exact-size static font, and every glyph jumped at the switch.
    // Only the raster instance may differ.
    var fs = try text_module.FontSystem.init(std.testing.allocator, std.testing.io);
    defer fs.deinit();
    const Loader = struct {
        fn load(ctx: *anyopaque, font_size: f32, font_weight: u16) ?*Font {
            const system: *text_module.FontSystem = @ptrCast(@alignCast(ctx));
            return system.findFont(.{ .family = "system-ui", .size = font_size, .weight = if (font_weight >= 650) .bold else if (font_weight >= 550) .semibold else .regular }) catch null;
        }
    };
    // The runtime's default slots: the platform UI font at 14 / 18 / 24.
    const small = try fs.findFont(.{ .family = "system-ui", .size = 14 });
    defer small.deinit();
    const medium = try fs.findFont(.{ .family = "system-ui", .size = 18 });
    defer medium.deinit();
    const large = try fs.findFont(.{ .family = "system-ui", .size = 24 });
    defer large.deinit();
    var selector = FontSelector{ .small = small, .medium = medium, .large = large };
    selector.weight_loader = .{ .context = @ptrCast(&fs), .load = Loader.load };
    selector.initDerivedCache(std.testing.allocator);
    defer selector.deinitDerivedCache();
    var shaper = try text_module.TextShaper.init(std.testing.allocator);
    defer shaper.deinit();

    const sample = "Settings  Device name: Mac mini (ThunderLink) 1234567890";
    var static_x: [128]f32 = undefined;
    var animated_x: [128]f32 = undefined;
    var compared: usize = 0;
    // Plain sizes, then sizes under a non-integer transform scale (an animated scale lowers
    // the run at font_size * scale).
    const sizes = [_]f32{ 11, 12, 13, 14, 15, 16, 17, 13 * 0.97, 15 * 0.985, 14 * 1.5, 12.5, 16.25 };
    for (sizes) |size| {
        for ([_]u16{ 400, 600 }) |weight| {
            const static_w = try shapedPenPositions(&shaper, &selector, sample, .{ .font_size = size, .font_weight = weight }, &static_x);
            const animated_w = try shapedPenPositions(&shaper, &selector, sample, .{ .font_size = size, .font_weight = weight, .force_linear = true }, &animated_x);
            try std.testing.expectEqual(static_w, animated_w);
            for (static_x[0..sample.len], animated_x[0..sample.len]) |a, b| try std.testing.expectEqual(a, b);
            // The animated raster still draws from a preloaded instance (no per-frame derive
            // while an animated scale walks through sizes).
            if (weight == 400) {
                const resolved = selector.resolveFonts(sample, .{ .font_size = size, .font_weight = weight, .force_linear = true });
                const raster = resolved.raster orelse resolved.primary;
                try std.testing.expect(raster == small or raster == medium or raster == large);
            }
            compared += 1;
        }
    }
    try std.testing.expectEqual(sizes.len * 2, compared);
}

test "HiDPI: FontSelector.setScaleFactor 传播到基准字体与扩展槽位" {
    // When scale changes: updating only small/medium/large leaves extended slots (bold/mono/cjk)
    // forever at old scale, appearing as 'some sizes sharpened, others still blurry'.
    var font12 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 12,
        .size_px = 12,
        .weight = 400,
    };
    var font14 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 14,
        .size_px = 14,
        .weight = 400,
    };
    var font16 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 16,
        .size_px = 16,
        .weight = 400,
    };
    var bold20 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 20,
        .size_px = 20,
        .weight = 700,
    };
    var mono13 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 13,
        .size_px = 13,
        .weight = 400,
    };
    var symbols = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 15,
        .size_px = 15,
        .weight = 400,
    };

    var selector = FontSelector{
        .small = &font12,
        .medium = &font14,
        .large = &font16,
    };
    selector.bold_fonts[0] = &bold20;
    selector.bold_count = 1;
    selector.mono_fonts[0] = &mono13;
    selector.mono_count = 1;
    selector.symbols_font = &symbols;

    // Precondition: all initially default 1.0.
    try std.testing.expectEqual(@as(f32, 1.0), font12.scale_factor);
    try std.testing.expectEqual(@as(f32, 1.0), bold20.scale_factor);

    selector.setScaleFactor(2.0);

    try std.testing.expectEqual(@as(f32, 2.0), font12.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), font14.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), font16.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), bold20.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), mono13.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), symbols.scale_factor);

    // Going back to 1x must also propagate (dragging back to non-Retina screen).
    selector.setScaleFactor(1.0);
    try std.testing.expectEqual(@as(f32, 1.0), bold20.scale_factor);
    try std.testing.expectEqual(@as(f32, 1.0), mono13.scale_factor);
}

test "HiDPI: FontSelector.setScaleFactor 传播到 lazy derived font" {
    // Easiest to miss: Font.derive copies scale_factor only at creation time; derived fonts persist
    // in derived_cache for reuse. If setScaleFactor does not traverse this cache, non-standard
    // sizes rasterize forever at old scale. Requires actual CoreText font (derive calls CoreText).
    var fs = try text_module.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const base = try fs.findFont(.{ .family = "Helvetica", .size = 12 });
    defer base.deinit();
    const med = try fs.findFont(.{ .family = "Helvetica", .size = 14 });
    defer med.deinit();
    const big = try fs.findFont(.{ .family = "Helvetica", .size = 16 });
    defer big.deinit();

    var selector = FontSelector{ .small = base, .medium = med, .large = big };
    selector.initDerivedCache(std.testing.allocator);
    defer selector.deinitDerivedCache();

    // Trigger one lazy derive: pick a size not equal to any preloaded tier.
    const derived = selector.select(23.5);
    // Confirm derive was actually called (result not one of three base fonts).
    try std.testing.expect(derived != base and derived != med and derived != big);
    try std.testing.expect(selector.derived_cache.count() >= 1);
    try std.testing.expectEqual(@as(f32, 1.0), derived.scale_factor);

    selector.setScaleFactor(2.0);

    // Derived font must follow; this is the test's core aim.
    try std.testing.expectEqual(@as(f32, 2.0), derived.scale_factor);
    // Cannot clear cache (key independent of scale, update in-place).
    try std.testing.expect(selector.derived_cache.count() >= 1);
    // Reselecting same size must hit same object.
    try std.testing.expectEqual(derived, selector.select(23.5));
}

test "FontSelector derived cache init is idempotent" {
    var font12 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 12,
        .size_px = 12,
        .weight = 400,
    };
    var font14 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 14,
        .size_px = 14,
        .weight = 400,
    };
    var font16 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .io = std.testing.io,
        .size = 16,
        .size_px = 16,
        .weight = 400,
    };

    var selector = FontSelector{
        .small = &font12,
        .medium = &font14,
        .large = &font16,
    };

    selector.initDerivedCache(std.testing.allocator);
    try selector.derived_cache.ensureTotalCapacity(1);
    selector.initDerivedCache(std.testing.allocator);
    selector.deinitDerivedCache();

    try std.testing.expect(!selector.derived_cache_inited);
}

test "FontSelector weight_loader 未命中进负缓存：同 (字重, 字号) 不重复查 CoreText" {
    // Regression guard: font family missing a weight returns null from loader; no negative cache
    // before, CoreText lookup every select (every frame, every measure) with NSLog spam.
    const Counter = struct {
        calls: u32 = 0,
        fn load(ctx: *anyopaque, font_size: f32, font_weight: u16) ?*Font {
            _ = font_size;
            _ = font_weight;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return null;
        }
    };
    var font12 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .io = std.testing.io, .size = 12, .size_px = 12, .weight = 400 };
    var font14 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .io = std.testing.io, .size = 14, .size_px = 14, .weight = 400 };
    var font16 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .io = std.testing.io, .size = 16, .size_px = 16, .weight = 400 };
    var counter = Counter{};
    var selector = FontSelector{ .small = &font12, .medium = &font14, .large = &font16 };
    selector.weight_loader = .{ .context = @ptrCast(&counter), .load = Counter.load };
    selector.initDerivedCache(std.testing.allocator);
    defer selector.deinitDerivedCache();

    // 14px is preloaded tier: miss falls back to medium, no derive (no CoreText touch).
    try std.testing.expectEqual(&font14, selector.selectWeighted(14, 700));
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
    try std.testing.expectEqual(&font14, selector.selectWeighted(14, 700));
    try std.testing.expectEqual(&font14, selector.selectWeighted(14, 690)); // Quantized to same 700.
    try std.testing.expectEqual(@as(u32, 1), counter.calls);

    // Different keys still query separately.
    _ = selector.selectWeighted(14, 500);
    try std.testing.expectEqual(@as(u32, 2), counter.calls);

    // Loader change (font family swap) must invalidate negative cache.
    var counter2 = Counter{};
    selector.weight_loader = .{ .context = @ptrCast(&counter2), .load = Counter.load };
    _ = selector.selectWeighted(14, 700);
    try std.testing.expectEqual(@as(u32, 1), counter2.calls);

    // Invalidates with positive cache: deinit + reinit queries again.
    selector.deinitDerivedCache();
    selector.initDerivedCache(std.testing.allocator);
    _ = selector.selectWeighted(14, 700);
    try std.testing.expectEqual(@as(u32, 2), counter2.calls);

    // Bounded: 3 preloaded sizes x 8 non-standard weights = 24 keys, exceeds negative cache
    // capacity, no overflow; latest inserted key still remembered. (Only preloaded sizes: derive
    // would touch CoreText.)
    const sizes = [_]f32{ 12, 14, 16 };
    const weights = [_]u16{ 100, 200, 300, 500, 600, 700, 800, 900 };
    for (sizes) |s| for (weights) |wt| {
        _ = selector.selectWeighted(s, wt);
    };
    try std.testing.expect(24 > FontSelector.weight_miss_capacity);
    const before = counter2.calls;
    _ = selector.selectWeighted(16, 900);
    try std.testing.expectEqual(before, counter2.calls);
}

/// Paint command mock with every field the paint fingerprint reads.
const FullMock = struct {
    pub const MockColor = extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };
    pub const MockGlass = struct {
        backdrop_blur: f32 = 0,
        glass_tint: [4]f32 = .{ 0, 0, 0, 0 },
        glass_intensity: f32 = 0,
        specular_opacity: f32 = 0,
        specular_saturation: f32 = 0,
        refraction_level: f32 = 0,
        blur_level: f32 = 0,
        warp_gain: f32 = 0,
        center_thickness: f32 = 0,
        surface: u8 = 0,
        bezel_width: f32 = 0,
        bottom_surface: u8 = 0,
        bottom_bezel_width: f32 = 0,
        backdrop_saturation: f32 = 1.0,
        backdrop_brightness: f32 = 1.0,
        tint_mode: f32 = 0,
        base_veil: [4]f32 = .{ 0, 0, 0, -1 },
        veil_curve: [20]f32 = @splat(0),
        tab_lens: [24]f32 = @as([24]f32, @splat(0)),
        specular_angle: f32 = 0,
        magnification: f32 = 0,
        scale_ratio: f32 = 1,
        edge_field_strength: f32 = 0,
        center_zoom_radius: f32 = 0,
        center_zoom_falloff: f32 = 0,
        backdrop_distance: f32 = 0,
        lens_bezel_px: f32 = 0,
        lens_height_px: f32 = 0,
        lens_base_px: f32 = 0,
        lens_edge_blur: f32 = 1,
        native_fine_sigma: f32 = 0,
        native_main_grid_mix: f32 = 0,
        native_continuous_geometry: bool = false,
        press_offset: f32 = 0,
        arrow: [4]f32 = .{ 0, 0, 0, 0 },
        knob_rim_dark: [4]f32 = .{ 0, 0, 0, 0 },
        knob_rim_light: [4]f32 = .{ 0, 0, 0, 0 },
        a11y: [4]f32 = .{ 0, 0, 0, 0 },
        capture_clamp: bool = false,
        native_coarse_sigma: f32 = 0,
        native_fine_weight: f32 = 0,
        native_coarse_weight: f32 = 0,
        native_fine_slope: f32 = 0,
        native_fine_curve: f32 = 0,
        native_coarse_slope: f32 = 0,
        native_coarse_curve: f32 = 0,
        native_rim_offset: f32 = 0,
        native_rim_luma: f32 = 0,
        native_rim_chroma: f32 = 0,
        native_rim_ratio: f32 = 0,
        native_chroma_enabled: f32 = 0,
        native_chroma_fine: f32 = 0,
        native_chroma_coarse: f32 = 0,
        native_chroma_fine_slope: f32 = 0,
        native_chroma_fine_curve: f32 = 0,
        native_chroma_coarse_slope: f32 = 0,
        native_chroma_coarse_curve: f32 = 0,
        native_tint_mode: f32 = 0,
        native_tint_dark: f32 = 0,
        native_tint_chroma_base: f32 = 0,
        native_tint_chroma_slope: f32 = 0,
        blur_gradient_direction: u8 = 0,
        blur_gradient_strength: f32 = 0,
        blur_gradient_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
        blur_gradient_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
        blur_gradient_stop_count: u8 = 2,
    };
    pub const MockSpan = struct {
        start: u32 = 0,
        end: u32 = 0,
        color: ?MockColor = null,
        font_weight: ?u16 = null,
        use_italic_font: bool = false,
        use_monospace_font: bool = false,
        strikethrough: bool = false,
        bg_color: ?MockColor = null,
    };
    pub const MockPt = struct { x: f32 = 0, y: f32 = 0 };
    pub const MockPathCmd = union(enum) {
        move_to: MockPt,
        line_to: MockPt,
        quad_to: struct { ctrl: MockPt = .{}, end: MockPt = .{} },
        cubic_to: struct { ctrl1: MockPt = .{}, ctrl2: MockPt = .{}, end: MockPt = .{} },
        close: void,
    };
    pub const MockPathGeom = struct {
        fill_rule: enum(u8) { nonzero, evenodd } = .nonzero,
        commands: []const MockPathCmd = &.{},
    };
    pub const Kind = enum { none, rect, text, image, shadow, gradient, path, control };
    pub const CtrlKind = enum {
        none,
        push_clip,
        pop_clip,
        begin_opacity_layer,
        end_opacity_layer,
        begin_blur_layer,
        end_blur_layer,
        begin_rounded_clip,
        end_rounded_clip,
    };
    pub const Geom = struct { x: f32 = 0, y: f32 = 0, w: f32 = 100, h: f32 = 100 };
    pub const Radii = struct {
        tl: f32 = 0,
        tr: f32 = 0,
        br: f32 = 0,
        bl: f32 = 0,
        pub fn toArray(self: @This()) [4]f32 {
            return .{ self.tl, self.tr, self.br, self.bl };
        }
    };
    pub const MockItem = struct {
        kind: Kind = .control,
        control_kind: CtrlKind = .none,
        geom: Geom = .{},
        color: MockColor = .{},
        radii: Radii = .{},
        opacity: f32 = 1.0,
        rotate: f32 = 0,
        blend_mode: u8 = 0,
        warp: [4]f32 = .{ 0, 0, 0, 0 },
        use_draw_transform: bool = false,
        draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        stroke_width: f32 = 0,
        clip_shape_kind: u8 = 0,
        shape_kind: u8 = 0,
        shadow_blur: f32 = 0,
        shadow_offset_x: f32 = 0,
        shadow_offset_y: f32 = 0,
        shadow_spread: f32 = 0,
        shadow_secondary_color: MockColor = .{},
        shadow2_color: MockColor = .{},
        shadow2_blur: f32 = 0,
        shadow2_offset_x: f32 = 0,
        shadow2_offset_y: f32 = 0,
        gradient_to_color: MockColor = .{},
        gradient_direction: u8 = 0,
        gradient_extend_mode: u8 = 0,
        gradient_radial_center_x: f32 = 0,
        gradient_radial_center_y: f32 = 0,
        gradient_radial_radius_x: f32 = 0.5,
        gradient_radial_radius_y: f32 = 0.5,
        gradient_conic_start_angle: f32 = 0,
        mg_stop_colors: [16]MockColor = @as([16]MockColor, @splat(.{})),
        mg_stop_positions: [16]f32 = @as([16]f32, @splat(0)),
        mg_stop_count: u8 = 0,
        arc_start_angle: f32 = 0,
        arc_end_angle: f32 = 0,
        arc_outer_radius: f32 = 0,
        border_widths: [4]f32 = .{ 0, 0, 0, 0 },
        noise_mode: u8 = 0,
        noise_scale: f32 = 0,
        noise_intensity: f32 = 0,
        noise_seed: u8 = 0,
        path_line_join: u8 = 0,
        text_content: []const u8 = "",
        text_font_size: f32 = 0,
        text_font_weight: u16 = 0,
        text_font_family: u16 = 0,
        text_font_flags: u8 = 0,
        text_raster_policy: u8 = 0,
        text_fade_dx0: f32 = 0,
        text_fade_dx1: f32 = 0,
        text_monospace_char_width: f32 = 0,
        text_spans: ?[]const MockSpan = null,
        resource_handle: u64 = 0,
        image_opacity: f32 = 1,
        image_tint: MockColor = .{},
        image_corner_radius: f32 = 0,
        icon_tint: MockColor = .{},
        icon_rep_size: u8 = 0,
        icon_snap: bool = true,
        icon_corner_clip_radius: f32 = 0,
        clip_polygon_ptr: ?*const MockClipPolygon = null,
        glass_ptr: ?*const MockGlass = null,
        icon_rep_ptr: ?*const icon_ir.Rep = null,
        path_geometry_ptr: ?*const MockPathGeom = null,
        surface_stable_id: u32 = 42,
        surface_content_version: u32 = 1,
    };
};

test "retained_begin_seq stays aligned when no-op structural blocks are skipped" {
    // Regression guard (P0 from 2026-07-30 review): encodeCommands skips 'empty struct blocks'
    // (begin..end with no draw commands), skipping dispatchCommand. Before fix, skipped
    // begin_opacity_layer did not advance retained_begin_seq while fingerprint prescan already
    // numbered it; all downstream layers got wrong fingerprint shifted by 1, content changed but
    // hit, stale content froze.
    //
    // Uses duck-typed mock command list (encoder all anytype, render module does not import ui
    // paint_table). Two empty opacity blocks both collapsed-skipped; assert post-skip seq still
    // matches prescan numbering total.
    const MockItem = FullMock.MockItem;
    const begin = MockItem{ .control_kind = .begin_opacity_layer, .opacity = 0.5 };
    const end = MockItem{ .control_kind = .end_opacity_layer };
    // Two empty opacity blocks; tryFindNoOpStructuralBlock folds them entirely.
    const commands = [_]MockItem{ begin, end, begin, end };

    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    // render_pass == null: even if some begin reaches dispatch, tryBeginRetained/
    // beginOpacityLayer safely early-return, untouched GPU.
    try encoder.encodeCommands(commands[0..]);

    // Prescan assigned sequence numbers to both begins; skip path must advance seq to
    // same position.
    try std.testing.expectEqual(@as(usize, 2), encoder.retained_hash_count);
    try std.testing.expectEqual(@as(usize, 2), encoder.retained_begin_seq);
}

/// Same shape as command_encoder.ClipPolygon (fingerprint content-hash needs these).
const MockClipPolygon = struct {
    point_count: u8 = 0,
    contour_count: u8 = 0,
    fill_rule: enum(u8) { nonzero, evenodd } = .evenodd,
    contour_end_points: [4]u8 = .{ 0, 0, 0, 0 },
    points: [16][2]f32 = @as([16][2]f32, @splat(.{ 0, 0 })),
};

/// Damage-rect/fingerprint shared duck-typed paint command mock (encoder is
/// anytype throughout, render module doesn't import ui paint_table).
const DamageMock = struct {
    pub const MockSpan = struct {
        start: u32 = 0,
        end: u32 = 0,
        color: ?u32 = null,
        font_weight: ?u16 = null,
        use_italic_font: bool = false,
        use_monospace_font: bool = false,
        strikethrough: bool = false,
        bg_color: ?u32 = null,
    };
    pub const MockPt = struct { x: f32 = 0, y: f32 = 0 };
    pub const MockPathCmd = union(enum) {
        move_to: MockPt,
        line_to: MockPt,
        quad_to: struct { ctrl: MockPt = .{}, end: MockPt = .{} },
        cubic_to: struct { ctrl1: MockPt = .{}, ctrl2: MockPt = .{}, end: MockPt = .{} },
        close: void,
    };
    pub const MockPathGeom = struct {
        fill_rule: u8 = 0,
        commands: []const MockPathCmd = &.{},
    };
    pub const Kind = enum { none, rect, text, image, shadow, gradient, path, control };
    pub const CtrlKind = enum {
        none,
        push_clip,
        pop_clip,
        begin_opacity_layer,
        end_opacity_layer,
        begin_blur_layer,
        end_blur_layer,
        begin_rounded_clip,
        end_rounded_clip,
    };
    pub const Geom = struct { x: f32 = 0, y: f32 = 0, w: f32 = 100, h: f32 = 100 };
    pub const Radii = struct {
        tl: f32 = 0,
        tr: f32 = 0,
        br: f32 = 0,
        bl: f32 = 0,
        pub fn toArray(self: @This()) [4]f32 {
            return .{ self.tl, self.tr, self.br, self.bl };
        }
    };
    pub const MockItem = struct {
        kind: Kind = .control,
        control_kind: CtrlKind = .none,
        geom: Geom = .{},
        color: u32 = 0,
        radii: Radii = .{},
        opacity: f32 = 1.0,
        rotate: f32 = 0,
        blend_mode: u8 = 0,
        warp: [4]f32 = .{ 0, 0, 0, 0 },
        use_draw_transform: bool = false,
        draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        stroke_width: f32 = 0,
        clip_shape_kind: u8 = 0,
        shape_kind: u8 = 0,
        shadow_blur: f32 = 0,
        shadow_offset_x: f32 = 0,
        shadow_offset_y: f32 = 0,
        shadow_spread: f32 = 0,
        shadow_secondary_color: u32 = 0,
        shadow2_color: u32 = 0,
        shadow2_blur: f32 = 0,
        shadow2_offset_x: f32 = 0,
        shadow2_offset_y: f32 = 0,
        gradient_to_color: u32 = 0,
        gradient_direction: u8 = 0,
        gradient_extend_mode: u8 = 0,
        gradient_radial_center_x: f32 = 0,
        gradient_radial_center_y: f32 = 0,
        gradient_radial_radius_x: f32 = 0.5,
        gradient_radial_radius_y: f32 = 0.5,
        gradient_conic_start_angle: f32 = 0,
        mg_stop_colors: [16]u32 = @as([16]u32, @splat(0)),
        mg_stop_positions: [16]f32 = @as([16]f32, @splat(0)),
        mg_stop_count: u8 = 0,
        arc_start_angle: f32 = 0,
        arc_end_angle: f32 = 0,
        arc_outer_radius: f32 = 0,
        border_widths: [4]f32 = .{ 0, 0, 0, 0 },
        noise_mode: u8 = 0,
        noise_scale: f32 = 0,
        noise_intensity: f32 = 0,
        noise_seed: u8 = 0,
        path_line_join: u8 = 0,
        text_content: []const u8 = "",
        text_font_size: f32 = 0,
        text_font_weight: u16 = 0,
        text_font_family: u16 = 0,
        text_font_flags: u8 = 0,
        text_raster_policy: u8 = 0,
        text_fade_dx0: f32 = 0,
        text_fade_dx1: f32 = 0,
        text_monospace_char_width: f32 = 0,
        text_spans: ?[]const MockSpan = null,
        resource_handle: u64 = 0,
        image_opacity: f32 = 1,
        image_tint: u32 = 0,
        image_corner_radius: f32 = 0,
        icon_tint: u32 = 0,
        icon_rep_size: u8 = 0,
        icon_snap: bool = true,
        icon_corner_clip_radius: f32 = 0,
        clip_polygon_ptr: ?*const MockClipPolygon = null,
        glass_ptr: ?*const u8 = null,
        icon_rep_ptr: ?*const u8 = null,
        path_geometry_ptr: ?*const MockPathGeom = null,
        surface_stable_id: u32 = 42,
        surface_content_version: u32 = 1,
    };
};

test "damage-rect: per-item 基线捕获；path/clip/嵌套子树折叠 safe；blur/polygon/旋转 unsafe" {
    const MockPathCmd = DamageMock.MockPathCmd;
    const MockPathGeom = DamageMock.MockPathGeom;
    const MockItem = DamageMock.MockItem;
    const begin = MockItem{ .control_kind = .begin_opacity_layer, .opacity = 0.5 };
    const end = MockItem{ .control_kind = .end_opacity_layer };
    const rect_a = MockItem{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 10, .y = 10, .w = 50, .h = 20 }, .color = 0xFF0000FF };
    const rect_b = MockItem{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 10, .y = 40, .w = 50, .h = 20 }, .color = 0x00FF00FF };
    const path_item = MockItem{ .kind = .path, .control_kind = .none };

    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };

    // Flat layer: two rect -> capture 2 items, safe.
    const flat = [_]MockItem{ begin, rect_a, rect_b, end };
    encoder.computeRetainedContentHashes(flat[0..]);
    try std.testing.expect(encoder.damage_ranges[0].captured);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expect(!encoder.damage_ranges[0].overflow);
    try std.testing.expectEqual(@as(u32, 2), encoder.damage_ranges[0].len);
    // bounds includes 2px pad.
    const b0 = encoder.damage_scratch[0].bounds;
    try std.testing.expectEqual(@as(f32, 8), b0[0]);
    try std.testing.expectEqual(@as(f32, 54), b0[2]);
    // same content rescan -> stable digest; color change -> digest changed.
    const d0 = encoder.damage_scratch[0].digest;
    encoder.computeRetainedContentHashes(flat[0..]);
    try std.testing.expectEqual(d0, encoder.damage_scratch[0].digest);
    var rect_a2 = rect_a;
    rect_a2.color = 0x123456FF;
    const flat2 = [_]MockItem{ begin, rect_a2, rect_b, end };
    encoder.computeRetainedContentHashes(flat2[0..]);
    try std.testing.expect(encoder.damage_scratch[0].digest != d0);
    try std.testing.expectEqual(encoder.damage_scratch[1].digest, encoder.damage_scratch[1].digest);

    // Translate-only nested opacity sublayer -> recursive item capture
    // (2026-07-30 non-flat extension): rect_a + begin + rect_b + end = 4 items,
    // outer stays safe.
    const nested = [_]MockItem{ begin, rect_a, begin, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested[0..]);
    try std.testing.expect(encoder.damage_ranges[0].captured);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 4), encoder.damage_ranges[0].len);
    // Sublayer content change -> only that item digest changes (fine-grain damage
    // premise).
    const inner_digest = encoder.damage_scratch[2].digest;
    const outer_digest = encoder.damage_scratch[1].digest;
    var rect_b2 = rect_b;
    rect_b2.color = 0x123456FF;
    const nested2 = [_]MockItem{ begin, rect_a, begin, rect_b2, end, end };
    encoder.computeRetainedContentHashes(nested2[0..]);
    try std.testing.expect(encoder.damage_scratch[2].digest != inner_digest);
    try std.testing.expect(encoder.damage_scratch[1].digest == outer_digest);
    // Layer with backdrop blur (glass): fingerprint always 0 = never cache texture.
    // Glass pixels depend on layer-behind, fingerprint invisible; cache burns in old
    // background. (Real app: glass in composite group stretched + doubled ghost image).
    const glass_begin = MockItem{ .control_kind = .begin_blur_layer };
    const glass_end = MockItem{ .control_kind = .end_blur_layer };
    const glassy = [_]MockItem{ begin, rect_a, begin, glass_begin, rect_b, glass_end, end, end };
    encoder.computeRetainedContentHashes(glassy[0..]);
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[0]);
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[1]);
    encoder.computeRetainedContentHashes(flat[0..]);
    try std.testing.expect(encoder.retained_hashes[0] != 0);

    // Plain nested (no dt): draw==geom -> content coords same parent frame, offset 0.
    var begin_off = begin;
    begin_off.geom = .{ .x = 30, .y = 40, .w = 100, .h = 100 };
    const nested_off = [_]MockItem{ begin, rect_a, begin_off, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested_off[0..]);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    // rect_b (10,40) - pad 2 = (8,38) (nested offset = 0).
    try std.testing.expectApproxEqAbs(@as(f32, 8), encoder.damage_scratch[2].bounds[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 38), encoder.damage_scratch[2].bounds[1], 0.001);

    // Translate-only draw_transform nested (promoted surface typical) -> also
    // recursive: content coords = nested-local + (tx - geom.x).
    var begin_tr = begin;
    begin_tr.use_draw_transform = true;
    begin_tr.draw_transform = .{ 1, 0, 0, 1, 200, 300 };
    begin_tr.geom = .{ .x = -20, .y = -20, .w = 140, .h = 140 };
    const nested_tr = [_]MockItem{ begin, rect_a, begin_tr, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested_tr[0..]);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 4), encoder.damage_ranges[0].len);
    // rect_b(10,40) + (200-(-20), 300-(-20)) - pad2 = (228, 358)
    try std.testing.expectApproxEqAbs(@as(f32, 228), encoder.damage_scratch[2].bounds[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 358), encoder.damage_scratch[2].bounds[1], 0.001);

    // Scaled axis-aligned transform nested -> fold entire subtree to one item:
    // rect_a + fold = 2; fold bounds only from transform rect (t4,t5,a*w,d*h).
    var begin_tx = begin;
    begin_tx.use_draw_transform = true;
    begin_tx.draw_transform = .{ 0.5, 0, 0, 0.5, 5, 5 };
    const nested_tx = [_]MockItem{ begin, rect_a, begin_tx, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested_tx[0..]);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 2), encoder.damage_ranges[0].len);
    try std.testing.expectApproxEqAbs(@as(f32, 5 - 4), encoder.damage_scratch[1].bounds[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 * 100 + 8), encoder.damage_scratch[1].bounds[2], 0.001);
    const fold_digest = encoder.damage_scratch[1].digest;
    const nested_tx2 = [_]MockItem{ begin, rect_a, begin_tx, rect_b2, end, end };
    encoder.computeRetainedContentHashes(nested_tx2[0..]);
    try std.testing.expect(encoder.damage_scratch[1].digest != fold_digest);

    // Rotated nested sublayer: composite range undefined -> unsafe.
    var begin_rot = begin;
    begin_rot.rotate = 0.5;
    const nested_rot = [_]MockItem{ begin, rect_a, begin_rot, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested_rot[0..]);
    try std.testing.expect(!encoder.damage_ranges[0].safe);

    // path command -> captured as item, bounds from points (+ pad).
    const path_cmds = [_]MockPathCmd{
        .{ .move_to = .{ .x = 5, .y = 5 } },
        .{ .line_to = .{ .x = 30, .y = 45 } },
        .{ .quad_to = .{ .ctrl = .{ .x = 60, .y = 10 }, .end = .{ .x = 50, .y = 20 } } },
        .{ .close = {} },
    };
    const path_geom = MockPathGeom{ .commands = path_cmds[0..] };
    var path_item2 = path_item;
    path_item2.path_geometry_ptr = &path_geom;
    path_item2.geom = .{ .x = 100, .y = 200, .w = 0, .h = 0 };
    const with_path = [_]MockItem{ begin, rect_a, path_item2, end };
    encoder.computeRetainedContentHashes(with_path[0..]);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 2), encoder.damage_ranges[0].len);
    const pb = encoder.damage_scratch[1].bounds;
    try std.testing.expectApproxEqAbs(@as(f32, 100 + 5 - 2), pb[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200 + 5 - 2), pb[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 55 + 4), pb[2], 0.001);

    // push/pop_clip (rect) -> captured as item; pop bounds = paired push rect.
    const clip_push = MockItem{ .control_kind = .push_clip, .geom = .{ .x = 20, .y = 20, .w = 40, .h = 30 } };
    const clip_pop = MockItem{ .control_kind = .pop_clip };
    const with_clip = [_]MockItem{ begin, clip_push, rect_a, clip_pop, end };
    encoder.computeRetainedContentHashes(with_clip[0..]);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 3), encoder.damage_ranges[0].len);
    try std.testing.expectEqual(encoder.damage_scratch[0].bounds, encoder.damage_scratch[2].bounds);

    // polygon clip/unpaired pop/blur subtree -> unsafe.
    var poly_clip = clip_push;
    poly_clip.clip_shape_kind = 3;
    const with_poly = [_]MockItem{ begin, poly_clip, rect_a, clip_pop, end };
    encoder.computeRetainedContentHashes(with_poly[0..]);
    try std.testing.expect(!encoder.damage_ranges[0].safe);
    const with_orphan_pop = [_]MockItem{ begin, clip_pop, rect_a, end };
    encoder.computeRetainedContentHashes(with_orphan_pop[0..]);
    try std.testing.expect(!encoder.damage_ranges[0].safe);
    const blur_begin = MockItem{ .control_kind = .begin_blur_layer };
    const blur_end = MockItem{ .control_kind = .end_blur_layer };
    const with_blur = [_]MockItem{ begin, blur_begin, blur_end, rect_a, end };
    encoder.computeRetainedContentHashes(with_blur[0..]);
    try std.testing.expect(!encoder.damage_ranges[0].safe);

    // More than the historical 8-level stack: every representable retained
    // layer must receive a real hash, and inner content must affect all outers.
    var deep: [19]MockItem = undefined;
    for (0..9) |i| deep[i] = begin;
    deep[9] = rect_a;
    for (0..9) |i| deep[10 + i] = end;
    encoder.computeRetainedContentHashes(deep[0..]);
    try std.testing.expectEqual(@as(usize, 9), encoder.retained_hash_count);
    for (encoder.retained_hashes[0..9]) |hash| try std.testing.expect(hash != 0);

    const old_outer_hash = encoder.retained_hashes[0];
    deep[9] = rect_a2;
    encoder.computeRetainedContentHashes(deep[0..]);
    try std.testing.expect(encoder.retained_hashes[0] != old_outer_hash);
}

test "damage-rect: arc（spinner 环）脏区覆盖整个圆环，不是圆心一个点" {
    // Regression: arc reuses .path kind but no path_geometry_ptr; pathItemBounds
    // returned {cx,cy,0,0} -> Spinner in retained layer partial-repaint scissor = ~2px
    // at center, entire ring clipped, animation froze.
    const MockItem = DamageMock.MockItem;
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    const begin = MockItem{ .control_kind = .begin_opacity_layer, .opacity = 0.5, .geom = .{ .w = 400, .h = 400 } };
    const arc = MockItem{
        .kind = .path,
        .geom = .{ .x = 200, .y = 200, .w = 0, .h = 0 },
        .arc_outer_radius = 12,
        .stroke_width = 3,
        .color = 0xFFFFFFFF,
    };
    const end = MockItem{ .control_kind = .end_opacity_layer };
    encoder.computeRetainedContentHashes(&[_]MockItem{ begin, arc, end });
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 1), encoder.damage_ranges[0].len);
    const b = encoder.damage_scratch[encoder.damage_ranges[0].start].bounds;
    // Ring outer edge [188,212] must fall fully inside dirty region.
    try std.testing.expect(b[0] <= 200 - 12 - 3);
    try std.testing.expect(b[1] <= 200 - 12 - 3);
    try std.testing.expect(b[0] + b[2] >= 200 + 12 + 3);
    try std.testing.expect(b[1] + b[3] >= 200 + 12 + 3);
}

test "retained：含玻璃（begin_blur）的层及其外层指纹恒 0，永不复用缓存" {
    // Regression: glass pixels depend on layer-**behind**, layer fingerprint only sees
    // layer content. Retained layer hit freezes background in cache, backdrop scrolls/
    // animates but glass unchanged.
    const MockItem = DamageMock.MockItem;
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    const begin = MockItem{ .control_kind = .begin_opacity_layer, .opacity = 0.5 };
    const end = MockItem{ .control_kind = .end_opacity_layer };
    const blur_begin = MockItem{ .control_kind = .begin_blur_layer };
    const blur_end = MockItem{ .control_kind = .end_blur_layer };
    const rect = MockItem{ .kind = .rect, .geom = .{ .x = 10, .y = 10, .w = 50, .h = 20 }, .color = 0xFF0000FF };

    // Outer [ inner [ glass ] ], then non-glass sibling.
    const cmds = [_]MockItem{
        begin, rect, begin, blur_begin, rect, blur_end, end, end,
        begin, rect, end,
    };
    encoder.computeRetainedContentHashes(cmds[0..]);
    try std.testing.expectEqual(@as(usize, 3), encoder.retained_hash_count);
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[0]); // Outer layer (contains glass).
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[1]); // Directly contains glass.
    try std.testing.expect(encoder.retained_hashes[2] != 0); // Sibling unaffected.
}

test "computeBackdropCaptureRegion clamps src to source texture bottom/right edge" {
    // Tile crosses viewport bottom: capture rect bottom exceeds RT, clamp allows
    // partial capture not total fail (no clamp: blit InvalidTextureRegion -> glass
    // composite silently skipped entirely).
    const region = RenderCommandEncoder.computeBackdropCaptureRegion(
        100,
        450, // Sample start near bottom.
        80,
        120, // Height past RT bottom (RT height 500*2=1000 physical, sample bottom 450+120=570 logical -> 1140 physical).
        2,
        null,
        1000,
        1000,
    ).?;
    try std.testing.expect(region.src_y + region.copy_h <= 1000);
    try std.testing.expect(region.copy_h > 0);
}

test "measure 端与 render 端必须是同一个 FontSelector（度量≠渲染回归锚）" {
    // == What this test guards ==
    //
    // "Text width" in zenit_app.runtime has three outlets, all bound to built-in
    // app.font_selector at init(): renderer.fonts / cx.measure_ctx /
    // g_font_selector_for_measure. Changing fonts (Inter+Lora+Mono) but only calling
    // renderer.setFonts() swaps one outlet; draw uses Inter, measure uses the runtime default.
    // Advance differs between fonts, so cursor/selection endpoints are systematically off
    // character edges and the error grows per character. Visible esp. with emoji, but the
    // glitch is always Latin. Measured (fs=14, fw=450, "ssdf x"): Inter-Regular = 40.348,
    // HelveticaNeue (runtime default) = 37.590, a 2.758px gap. With an emoji at line end the gap
    // is most visible (the emoji advance, 19.000, is identical on both sides; the Latin part is
    // what is wrong), which was historically misreported as "emoji rasterizes too narrow".
    // WARNING: FontSelector is 3 of 4 outlets. The 4th, the GlyphRun shape pipeline
    // (cursor/selection/hit), **bypasses FontSelector** via layout_engine.setShapeFontResolver.
    // Regression anchor in ui/core.zig "cursor measure: shape hook wired/unwired must match
    // width"; the two tests together cover all 4.
    // == Why assert "different selectors measure different width", not a specific value ==
    // Concrete values drift with system font versions. What matters is the **mechanism**: different
    // selectors necessarily give different width, so "which selector measures" is not an
    // implementation detail. App.setFontSelector must swap all outlets at once.
    var fs = try text_module.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fs.deinit();

    // Two font families play "runtime default" vs "app custom". System-installed,
    // no repo Inter/Lora dependency.
    const helv = try fs.findFont(.{ .family = "Helvetica Neue", .size = 14 });
    defer helv.deinit();
    const menlo = try fs.findFont(.{ .family = "Menlo", .size = 14 });
    defer menlo.deinit();

    var runtime_selector = FontSelector{ .small = helv, .medium = helv, .large = helv };
    var app_selector = FontSelector{ .small = menlo, .medium = menlo, .large = menlo };

    // Precondition: two selectors must give **different** width for same text.
    // If not, downstream assertions lack discrimination (test silently always true).
    const sample = "ssdf x";
    const w_runtime = runtime_selector.measureTextWidth(sample, 14, 450, false);
    const w_app = app_selector.measureTextWidth(sample, 14, 450, false);
    try std.testing.expect(w_runtime > 0 and w_app > 0);
    try std.testing.expect(@abs(w_runtime - w_app) > 1.0);

    // Core invariant: **render selector** == **measure selector**, same object.
    // Render = encoder.fonts; measure = measure_ctx style indirection.
    const Bridge = struct {
        fn measure(ctx: *anyopaque, ptr: [*]const u8, len: usize, size: f32, weight: u16, italic: bool) f32 {
            const sel: *FontSelector = @ptrCast(@alignCast(ctx));
            return sel.measureTextWidth(ptr[0..len], size, weight, italic);
        }
    };

    // Simulate runtime.init(): all three point to built-in selector.
    var render_side: *FontSelector = &runtime_selector;
    var measure_ctx: *anyopaque = @ptrCast(&runtime_selector);
    try std.testing.expectApproxEqAbs(
        render_side.measureTextWidth(sample, 14, 450, false),
        Bridge.measure(measure_ctx, sample.ptr, sample.len, 14, 450, false),
        0.001,
    );

    // Simulate "only renderer.setFonts" bug: render swapped, measure not.
    render_side = &app_selector;
    const rendered_w = render_side.measureTextWidth(sample, 14, 450, false);
    const measured_w = Bridge.measure(measure_ctx, sample.ptr, sample.len, 14, 450, false);
    // Bug shape: forks. Assert forks to prove test catches it.
    try std.testing.expect(@abs(rendered_w - measured_w) > 1.0);

    // Simulate App.setFontSelector: both swap, fork closes.
    measure_ctx = @ptrCast(&app_selector);
    try std.testing.expectApproxEqAbs(
        render_side.measureTextWidth(sample, 14, 450, false),
        Bridge.measure(measure_ctx, sample.ptr, sample.len, 14, 450, false),
        0.001,
    );
}

test "emoji advance 与拉丁 advance 不随 base selector 变化而混淆" {
    // Paired guard: emoji via coretext_bridge AppleColorEmoji override, unaffected
    // base font, same advance any base selector. Pins "cursor drift" scope to exclude
    // emoji; future similar drift + this test green -> blame Latin/base font, not
    // rasterize (learned from long rasterize search before).
    var fs = try text_module.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const helv = try fs.findFont(.{ .family = "Helvetica Neue", .size = 14 });
    defer helv.deinit();
    const menlo = try fs.findFont(.{ .family = "Menlo", .size = 14 });
    defer menlo.deinit();

    var sel_a = FontSelector{ .small = helv, .medium = helv, .large = helv };
    var sel_b = FontSelector{ .small = menlo, .medium = menlo, .large = menlo };

    const emoji = "\u{1F60A}";
    const ea = sel_a.measureTextWidth(emoji, 14, 450, false);
    const eb = sel_b.measureTextWidth(emoji, 14, 450, false);
    try std.testing.expect(ea > 0);
    // Same emoji, two base selectors -> same advance.
    try std.testing.expectApproxEqAbs(ea, eb, 0.001);

    // Latin must **differ**, the +2.758px source.
    const la = sel_a.measureTextWidth("ssdf x", 14, 450, false);
    const lb = sel_b.measureTextWidth("ssdf x", 14, 450, false);
    try std.testing.expect(@abs(la - lb) > 1.0);
}

test "stack_mode: 脚本回退让位给显式字体栈，shapingFont 恒为 primary" {
    // == What this test guards == With explicit font stack, font choice divides:
    // FontSelector (this test), no longer per-content CJK fallback; TextRenderer.
    // selectSegmentFont explicitly per codepoint in stack before shape. Stack_mode
    // resolveFonts still returns script fallback -> measure whole segment as fallback
    // (shapingFont history), draw only CJK chunk, width mismatch reappears.
    var fs = try text_module.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const helv = try fs.findFont(.{ .family = "Helvetica Neue", .size = 14 });
    defer helv.deinit();
    const pingfang = try fs.findFont(.{ .family = "PingFang SC", .size = 14 });
    defer pingfang.deinit();

    var sel = FontSelector{ .small = helv, .medium = helv, .large = helv };
    sel.cjk_fonts[0] = pingfang;
    sel.cjk_count = 1;

    const cjk_text = "中文 mixed";

    // Off (default): keep existing behavior, content-driven script fallback + whole-
    // segment shape as fallback.
    const legacy = sel.resolveFonts(cjk_text, .{ .font_size = 14 });
    try std.testing.expect(legacy.fallback_is_script);
    try std.testing.expectEqual(pingfang, legacy.fallback.?);
    try std.testing.expectEqual(pingfang, legacy.shapingFont());

    // On: script fallback absent, shaping font always primary.
    sel.stack_mode = true;
    const stacked = sel.resolveFonts(cjk_text, .{ .font_size = 14 });
    try std.testing.expectEqual(@as(?*Font, null), stacked.fallback);
    try std.testing.expect(!stacked.fallback_is_script);
    try std.testing.expectEqual(stacked.primary, stacked.shapingFont());

    // Plain Latin unaffected by stack_mode.
    const latin_off = blk: {
        sel.stack_mode = false;
        break :blk sel.resolveFonts("hello", .{ .font_size = 14 }).primary;
    };
    sel.stack_mode = true;
    try std.testing.expectEqual(latin_off, sel.resolveFonts("hello", .{ .font_size = 14 }).primary);
}

test "damage-rect: 文本脏区必须覆盖整串，不能只有绘制原点那一小块" {
    // Regression: text command geom.w/h are **always 0**, so lowering fills only the origin
    // (render_engine/gpu_draw_shadow.zig .text_run hard-codes .w=0/.h=0). damageItemBounds uses
    // it for the dirty region; retained-layer partial repaint then dirties only ~20px around the
    // origin: the first 1-2 glyphs redraw, the rest keep prior-frame pixels (stale tail text).
    // Not font-fallback related.
    // Contract: **overestimate is safe** (just extra redraw pixels), underestimate leaves the
    // screen stale.
    const MockItem = struct {
        kind: enum { text, rect } = .text,
        geom: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 } = .{},
        rotate: f32 = 0,
        stroke_width: f32 = 0,
        shadow_blur: f32 = 0,
        shadow_offset_x: f32 = 0,
        shadow_offset_y: f32 = 0,
        shadow_spread: f32 = 0,
        shadow2_blur: f32 = 0,
        shadow2_offset_x: f32 = 0,
        shadow2_offset_y: f32 = 0,
        text_content: []const u8 = "",
        text_font_size: f32 = 0,
        text_monospace_char_width: f32 = 0,
    };

    // Recreate: 11px mono, 6 bytes content, origin x=341; last glyph ~x=368.
    const it = MockItem{
        .kind = .text,
        .geom = .{ .x = 341, .y = 84.3, .w = 0, .h = 0 },
        .text_content = "3 \xc3\x97 5",
        .text_font_size = 11,
    };

    const b = paint_fp.damageItemBounds(it);
    const left = b[0];
    const right = b[0] + b[2];

    // Last glyph right edge (conservative x=368+13) must land in dirty region.
    try std.testing.expect(left <= 341);
    try std.testing.expect(right >= 381);
}

test "damage-rect: 文本脏区纵向以基线为准，覆盖上伸部与下伸部" {
    // Regression: text geom.y is **baseline** (text_item_render fills baseline_y);
    // glyphs draw above baseline (glyph_y = cursor_y - bearing_y). Old bounds
    // vertical [y-10, y+2fs+10]; fs>=14 glyphs top (y-ascent) outside dirty,
    // partial-repaint changed text top half preserves stale pixels.
    const MockItem = DamageMock.MockItem;
    inline for (.{ 11.0, 14.0, 24.0, 48.0 }) |fs_c| {
        const fs: f32 = fs_c;
        const baseline: f32 = 300;
        const it = MockItem{
            .kind = .text,
            .geom = .{ .x = 10, .y = baseline, .w = 0, .h = 0 },
            .text_content = "Ágjy",
            .text_font_size = fs,
        };
        const b = paint_fp.damageItemBounds(it);
        // Ascenders (uppercase + accents/CJK ascent ~1.2em).
        try std.testing.expect(b[1] <= baseline - fs * 1.2);
        // Descenders (g/j/y ~0.3em).
        try std.testing.expect(b[1] + b[3] >= baseline + fs * 0.4);
    }
}

test "damage-rect: 旋转的 image/icon 脏区覆盖旋转后的四角" {
    // Regression: damageItemBounds ignored rotate, scissored by axis-aligned geom;
    // 45-degree rotated corners extend outside geom -> rotate animation leaves trails
    // in retained layer.
    const MockItem = DamageMock.MockItem;
    const it = MockItem{
        .kind = .image,
        .geom = .{ .x = 100, .y = 100, .w = 40, .h = 40 },
        .rotate = std.math.pi / 4.0,
        .resource_handle = 7,
    };
    const b = paint_fp.damageItemBounds(it);
    // Center (120,120), circumcircle radius = 20*sqrt(2) ~= 28.28.
    const r: f32 = 20 * std.math.sqrt2;
    try std.testing.expect(b[0] <= 120 - r);
    try std.testing.expect(b[1] <= 120 - r);
    try std.testing.expect(b[0] + b[2] >= 120 + r);
    try std.testing.expect(b[1] + b[3] >= 120 + r);
}

fn digestOf(it: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    paint_fp.hashPaintItemInto(&h, it);
    return h.final();
}

test "指纹：胶片颗粒按帧换种子，指纹随帧变化；其它噪声不受影响" {
    const MockItem = DamageMock.MockItem;
    var grain = MockItem{ .kind = .rect, .noise_mode = 2, .noise_intensity = 0.5 };
    var value = MockItem{ .kind = .rect, .noise_mode = 1, .noise_intensity = 0.5 };
    paint_fp.frame_salt = 1;
    const grain_a = digestOf(grain);
    const value_a = digestOf(value);
    paint_fp.frame_salt = 2;
    try std.testing.expect(digestOf(grain) != grain_a);
    try std.testing.expectEqual(value_a, digestOf(value));
    // Disabled grain is static.
    grain.noise_intensity = 0;
    const off = digestOf(grain);
    paint_fp.frame_salt = 3;
    try std.testing.expectEqual(off, digestOf(grain));
    _ = &value;
}

test "指纹：polygon clip 按内容 hash（同指针新点集必须 miss）" {
    // Regression: clip_polygon_ptr only pointer value. Points live in frame_arena,
    // reset per frame reuses address; polygon mutation (same pointer, new content)
    // hits, retained layer stuck at old clip shape.
    const MockItem = DamageMock.MockItem;
    var poly = MockClipPolygon{ .point_count = 3, .contour_count = 1 };
    poly.contour_end_points[0] = 3;
    poly.points[0] = .{ 0, 0 };
    poly.points[1] = .{ 10, 0 };
    poly.points[2] = .{ 5, 8 };
    const it = MockItem{ .control_kind = .push_clip, .clip_shape_kind = 3, .clip_polygon_ptr = &poly };
    const d0 = digestOf(it);
    try std.testing.expectEqual(d0, digestOf(it));
    poly.points[2] = .{ 5, 9 }; // same pointer, content changed.
    try std.testing.expect(digestOf(it) != d0);
    poly.points[2] = .{ 5, 8 };
    poly.fill_rule = .nonzero;
    try std.testing.expect(digestOf(it) != d0);
    poly.fill_rule = .evenodd;
    // out-of-range points don't affect pixels -> no fingerprint change.
    poly.points[10] = .{ 99, 99 };
    try std.testing.expectEqual(d0, digestOf(it));
    // same content, different address -> same fingerprint (no arena address jitter miss).
    const poly_copy = poly;
    var it2 = it;
    it2.clip_polygon_ptr = &poly_copy;
    try std.testing.expectEqual(d0, digestOf(it2));
}

test "指纹：shape_kind 与 text fade 区间进指纹" {
    const MockItem = DamageMock.MockItem;
    const rect = MockItem{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .color = 0xFF0000FF };
    var ellipse = rect;
    ellipse.shape_kind = 1;
    try std.testing.expect(digestOf(rect) != digestOf(ellipse));

    const txt = MockItem{ .kind = .text, .text_content = "hello", .text_font_size = 13, .text_fade_dx0 = 10, .text_fade_dx1 = 30 };
    var txt_a = txt;
    txt_a.text_fade_dx0 = 12;
    var txt_b = txt;
    txt_b.text_fade_dx1 = 40;
    try std.testing.expect(digestOf(txt) != digestOf(txt_a));
    try std.testing.expect(digestOf(txt) != digestOf(txt_b));
}

test "isArcCommand: 类型判据只看 arc_outer_radius，不掺可见性条件" {
    // Regression: "is it an arc" had two judges; dispatchCommand top uses
    // arc_outer_radius <= 0 for flush PathPending, .path branch used
    // (radius>0 && stroke>0 && alpha>0). A zero-width / fully-transparent arc was
    // neither judged an arc nor had path_geometry_ptr -> silently dropped by
    // `orelse return`. Spinner.strokeWidth(0) constructs this; display_list_lowering
    // stroke_width *= scale, scale -> 0 underflows to 0 the same way.

    const zero_stroke_arc = .{ .kind = .path, .arc_outer_radius = @as(f32, 10), .stroke_width = @as(f32, 0) };
    const transparent_arc = .{ .kind = .path, .arc_outer_radius = @as(f32, 10), .stroke_width = @as(f32, 3) };
    const normal_arc = .{ .kind = .path, .arc_outer_radius = @as(f32, 10), .stroke_width = @as(f32, 3) };
    const fill_path = .{ .kind = .path, .arc_outer_radius = @as(f32, 0), .stroke_width = @as(f32, 0) };
    const rect = .{ .kind = .rect, .arc_outer_radius = @as(f32, 0), .stroke_width = @as(f32, 0) };

    // Zero-width/transparent arc still **is** arc, not drawable !=  type change.
    try std.testing.expect(ce.isArcCommand(zero_stroke_arc));
    try std.testing.expect(ce.isArcCommand(transparent_arc));
    try std.testing.expect(ce.isArcCommand(normal_arc));
    // Not an arc.
    try std.testing.expect(!ce.isArcCommand(fill_path));
    try std.testing.expect(!ce.isArcCommand(rect));
}

test "image with an unknown texture is skipped instead of aborting the frame" {
    const img = @import("image_renderer.zig");
    // addImageUV lookup-fail fast-return before any GPU access; unrelated fields never
    // read.
    const ir = try std.testing.allocator.create(img.ImageRenderer);
    defer std.testing.allocator.destroy(ir);
    ir.texture_store.init(std.testing.allocator, undefined, false);
    ir.shared_texture_store = null;
    const stale_handle: u64 = 0x8000_1003;
    try ce.addImageOrSkip(ir, stale_handle, 0, 0, 10, 10, .{ 1, 1, 1, 1 }, 0, 1, 0);
    try ce.addImageOrSkip(ir, 7, 0, 0, 10, 10, .{ 1, 1, 1, 1 }, 0, 1, 0);
}

test "encoder.deinit 归还帧中途中止时 offscreen 栈上层借用的 external 纹理槽位" {
    // Regression: encodeDisplay/flush try fails after layer begin, frame encoder
    // deinit direct, pushed layer texture_id never unregister. external 256-slot pool,
    // handles don't cross frame, leak = permanent slot loss.
    const img = @import("image_renderer.zig");
    const ir = try std.testing.allocator.create(img.ImageRenderer);
    defer std.testing.allocator.destroy(ir);
    ir.texture_store.init(std.testing.allocator, undefined, false);
    defer ir.texture_store.deinit();
    ir.shared_texture_store = null;
    const gpu = @import("gpu");
    const binding = gpu.Backend.TextureBinding.testBinding(16, 1, 1);

    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    encoder.image_renderer = ir;
    var ids: [2]u32 = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = @intCast(try ir.registerTextureBinding(binding, 8, 8));
        encoder.offscreen_stack[i] = OffscreenLayer{
            .texture = undefined,
            .render_pass = undefined,
            .restore_target = undefined,
            .saved_clip_depth = 0,
            .saved_viewport_width = 0,
            .saved_viewport_height = 0,
            .x = 0,
            .y = 0,
            .w = 0,
            .h = 0,
            .opacity = 1,
            .texture_id = id.*,
        };
    }
    encoder.offscreen_depth = ids.len;
    try std.testing.expect(ir.getTextureSize(ids[0]) != null);

    encoder.deinit();

    for (ids) |id| try std.testing.expect(ir.getTextureSize(id) == null);
    try std.testing.expectEqual(@as(usize, 0), encoder.offscreen_depth);
}

test "retained plan: backend-independent layer ranges include nested damage and exclude backdrop caching" {
    const Item = DamageMock.MockItem;
    const begin = Item{ .control_kind = .begin_opacity_layer, .surface_stable_id = 11, .opacity = 0.5 };
    const nested = Item{ .control_kind = .begin_opacity_layer, .surface_stable_id = 12, .geom = .{ .x = 10, .y = 20, .w = 100, .h = 80 }, .opacity = 0.8 };
    const end = Item{ .control_kind = .end_opacity_layer };
    const body = Item{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 15, .y = 25, .w = 20, .h = 10 }, .color = 0xff00ffff };
    var commands = [_]Item{ begin, nested, body, end, end };
    var plan: retained_plan.Plan = .{};
    plan.compute(&commands, 2);
    try std.testing.expectEqual(@as(usize, 2), plan.retained_hash_count);
    try std.testing.expectEqual(@as(u32, 11), plan.layers[0].stable_id);
    try std.testing.expectEqual(@as(?usize, 4), plan.layers[0].end);
    try std.testing.expectEqual(@as(usize, 1), plan.layers[1].begin);
    try std.testing.expectEqual(@as(?usize, 3), plan.layers[1].end);
    try std.testing.expect(plan.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 3), plan.damage_ranges[0].len); // nested begin, body, end
    const before = plan.retained_hashes[0];
    const old_damage = plan.damage_scratch[plan.damage_ranges[0].start + 1];
    commands[2].color = 0x00ff00ff;
    plan.compute(&commands, 2);
    try std.testing.expect(plan.retained_hashes[0] != before);
    const new_damage = plan.damage_scratch[plan.damage_ranges[0].start + 1];
    try std.testing.expect(new_damage.digest != old_damage.digest);
    try std.testing.expectEqual(old_damage.bounds, new_damage.bounds);

    const blur = Item{ .control_kind = .begin_blur_layer };
    const blur_end = Item{ .control_kind = .end_blur_layer };
    const with_backdrop = [_]Item{ begin, blur, body, blur_end, end };
    plan.compute(&with_backdrop, 2);
    try std.testing.expectEqual(@as(u64, 0), plan.retained_hashes[0]);
    try std.testing.expect(!plan.damage_ranges[0].safe);
    // No layer metadata/baseline may survive a scene with no layers.
    plan.compute(&[_]Item{body}, 1);
    try std.testing.expectEqual(@as(usize, 0), plan.retained_hash_count);
    try std.testing.expectEqual(@as(?usize, null), plan.layers[0].end);
}

test "retained plan: a per-corner clip radius change invalidates the layer content hash" {
    const Item = DamageMock.MockItem;
    const begin = Item{ .control_kind = .begin_opacity_layer, .surface_stable_id = 21, .opacity = 0.5 };
    const end = Item{ .control_kind = .end_opacity_layer };
    const body = Item{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 0, .y = 0, .w = 80, .h = 40 }, .color = 0xff0000ff };
    const pop = Item{ .control_kind = .pop_clip };
    var clip = Item{ .control_kind = .push_clip, .clip_shape_kind = 1, .geom = .{ .x = 0, .y = 0, .w = 80, .h = 40 }, .radii = .{ .tl = 8, .tr = 0, .br = 0, .bl = 8 } };
    var plan: retained_plan.Plan = .{};
    plan.compute(&[_]Item{ begin, clip, body, pop, end }, 1);
    const square_right = plan.retained_hashes[0];
    try std.testing.expect(square_right != 0);
    // Only the bottom-left corner changes: cached pixels clipped with the old mask are stale.
    clip.radii.bl = 0;
    plan.compute(&[_]Item{ begin, clip, body, pop, end }, 1);
    try std.testing.expect(plan.retained_hashes[0] != square_right);
}

test "retained plan: excess nesting and incomplete scopes cannot misassociate native layer boundaries" {
    const Item = DamageMock.MockItem;
    var commands: [140]Item = undefined;
    for (commands[0..70], 0..) |*item, index| item.* = .{
        .control_kind = .begin_opacity_layer,
        .surface_stable_id = @intCast(index + 1),
        .opacity = 0.8,
    };
    for (commands[70..]) |*item| item.* = .{ .control_kind = .end_opacity_layer };
    var plan: retained_plan.Plan = .{};
    plan.compute(&commands, 1);
    try std.testing.expectEqual(@as(usize, 70), plan.retained_hash_count);
    try std.testing.expectEqual(@as(?usize, 139), plan.layers[0].end);
    try std.testing.expectEqual(@as(?usize, 76), plan.layers[63].end);
    try std.testing.expectEqual(@as(u32, 64), plan.layers[63].stable_id);
    plan.compute(commands[0..1], 1);
    try std.testing.expectEqual(@as(?usize, null), plan.layers[0].end);
    try std.testing.expectEqual(@as(u64, 0), plan.retained_hashes[0]);
    try std.testing.expectEqual(@as(?usize, null), plan.layers[63].end);
}

test "native glass AA fringe keeps fractional backdrop texels registered" {
    // A Retina node begins between physical pixels, while its backdrop blit
    // begins at integral (192,352). The fringe must reveal the first exterior
    // coverage pixel without shifting any of the interior backdrop samples.
    const uv: [4]f32 = .{ 128.25 / 896.0, 64.75 / 256.0, 768.75 / 896.0, 193.75 / 256.0 };
    const quad = backdrop_blur.expandGlassCompositeFringe(320.25, 64.5, uv, .{ 896, 256 }, .{ 1, 0, 0, 1, 160.125, 208.375 });
    try std.testing.expectApproxEqAbs(@as(f32, 159.625), quad.transform[4], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 207.875), quad.transform[5], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 321.25), quad.width, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 65.5), quad.height, 1e-5);

    for ([_][2]f32{ .{ 319.5, 416.5 }, .{ 320.5, 417.5 }, .{ 481.5, 482.5 }, .{ 960.5, 545.5 } }) |pixel| {
        const sample_u = (pixel[0] - 192) / 896;
        const sample_v = (pixel[1] - 352) / 256;
        try std.testing.expect(sample_u >= quad.uv[0] and sample_u <= quad.uv[2]);
        try std.testing.expect(sample_v >= quad.uv[1] and sample_v <= quad.uv[3]);
        const screen_x = quad.transform[4] + (sample_u - quad.uv[0]) / (quad.uv[2] - quad.uv[0]) * quad.width;
        const screen_y = quad.transform[5] + (sample_v - quad.uv[1]) / (quad.uv[3] - quad.uv[1]) * quad.height;
        try std.testing.expectApproxEqAbs(pixel[0] / 2, screen_x, 0.0001);
        try std.testing.expectApproxEqAbs(pixel[1] / 2, screen_y, 0.0001);
    }
}

test "native glass AA fringe preserves affine sample positions and original center" {
    const transform: [6]f32 = .{ 1.25, 0.5, -0.25, 0.75, 160.125, 208.375 };
    const uv: [4]f32 = .{ 0.125, 0.25, 0.75, 0.75 };
    const quad = backdrop_blur.expandGlassCompositeFringe(320, 64, uv, .{ 1024, 256 }, transform);
    // Translating by (-.5,-.5) in local space must use both affine columns;
    // subtracting padding directly in screen space breaks rotation and shear.
    try std.testing.expectApproxEqAbs(@as(f32, 159.625), quad.transform[4], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 207.75), quad.transform[5], 1e-5);
    for ([_][2]f32{ .{ 0, 0 }, .{ 320, 64 }, .{ 160, 32 }, .{ 13.25, 20.75 } }) |point| {
        const sample_u = uv[0] + point[0] / 320 * (uv[2] - uv[0]);
        const sample_v = uv[1] + point[1] / 64 * (uv[3] - uv[1]);
        const expanded_x = (sample_u - quad.uv[0]) / (quad.uv[2] - quad.uv[0]) * quad.width;
        const expanded_y = (sample_v - quad.uv[1]) / (quad.uv[3] - quad.uv[1]) * quad.height;
        const expected_x = transform[0] * point[0] + transform[2] * point[1] + transform[4];
        const expected_y = transform[1] * point[0] + transform[3] * point[1] + transform[5];
        const actual_x = quad.transform[0] * expanded_x + quad.transform[2] * expanded_y + quad.transform[4];
        const actual_y = quad.transform[1] * expanded_x + quad.transform[3] * expanded_y + quad.transform[5];
        try std.testing.expectApproxEqAbs(expected_x, actual_x, 0.0001);
        try std.testing.expectApproxEqAbs(expected_y, actual_y, 0.0001);
    }
}

test "FontSelector system UI family: unavailable falls back to the default slot, asked once, weight misses kept" {
    const Counter = struct {
        calls: u32 = 0,
        fn load(ctx: *anyopaque, font_size: f32, font_weight: u16) ?*Font {
            _ = font_size;
            _ = font_weight;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return null;
        }
    };
    var font12 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .io = std.testing.io, .size = 12, .size_px = 12, .weight = 400 };
    var font14 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .io = std.testing.io, .size = 14, .size_px = 14, .weight = 400 };
    var font16 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .io = std.testing.io, .size = 16, .size_px = 16, .weight = 400 };
    var weights = Counter{};
    var ui = Counter{};
    var selector = FontSelector{ .small = &font12, .medium = &font14, .large = &font16 };
    selector.weight_loader = .{ .context = @ptrCast(&weights), .load = Counter.load };
    selector.system_ui_loader = .{ .context = @ptrCast(&ui), .load = Counter.load };
    selector.initDerivedCache(std.testing.allocator);
    defer selector.deinitDerivedCache();

    // a weight miss recorded first
    _ = selector.selectWeighted(14, 700);
    try std.testing.expectEqual(@as(u32, 1), weights.calls);

    const props = font_selector_mod.TextFontProps{ .font_size = 14, .font_family = font_selector_mod.system_ui_family };
    try std.testing.expectEqual(&font14, selector.resolveFonts("Library", props).primary);
    try std.testing.expectEqual(@as(u32, 1), ui.calls);
    // unavailable: not asked again, for any size or weight (the fallback slot asks the weight
    // loader for 700 at 14, already a recorded miss)
    _ = selector.resolveFonts("Library", .{ .font_size = 14, .font_weight = 700, .font_family = font_selector_mod.system_ui_family });
    _ = selector.resolveFonts("Library", .{ .font_size = 12, .font_family = font_selector_mod.system_ui_family });
    try std.testing.expectEqual(@as(u32, 1), ui.calls);
    // and the weight loader's miss table survived (no re-query)
    _ = selector.selectWeighted(14, 700);
    try std.testing.expectEqual(@as(u32, 1), weights.calls);
}

test "frame damage with effects: entries, glass backdrop growth, skips and unbalanced groups" {
    const FrameDamage = @import("frame_damage.zig").FrameDamage;
    const M = FullMock.MockItem;
    const a = std.testing.allocator;
    const near = M{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 10, .y = 10, .w = 50, .h = 20 }, .color = .{ .r = 1 } };
    const far = M{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 600, .y = 600, .w = 50, .h = 20 }, .color = .{ .r = 1 } };
    const glass_begin = M{ .control_kind = .begin_blur_layer, .geom = .{ .x = 100, .y = 100, .w = 40, .h = 40 } };
    const child = M{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 105, .y = 105, .w = 10, .h = 10 }, .color = .{ .r = 1 } };
    const glass_end = M{ .control_kind = .end_blur_layer };
    var plan: FrameDamage = .{};
    defer plan.deinit(a);

    const frame1 = [_]M{ near, far, glass_begin, child, glass_end };
    try std.testing.expectEqual(@as(?[4]u32, null), try plan.prepareEffects(a, a, frame1[0..], 1000, 1000, 1, 7));
    plan.commit();
    // Nothing changed: copy only.
    try std.testing.expectEqual(@as(?[4]u32, .{ 0, 0, 0, 0 }), try plan.prepareEffects(a, a, frame1[0..], 1000, 1000, 1, 7));
    plan.commit();

    // A change far from the glass damages only itself; the rest is skipped.
    var far2 = far;
    far2.color = .{ .r = 2 };
    const frame2 = [_]M{ near, far2, glass_begin, child, glass_end };
    const d2 = (try plan.prepareEffects(a, a, frame2[0..], 1000, 1000, 1, 7)).?;
    try std.testing.expect(d2[0] >= 590 and d2[1] >= 590 and d2[0] + d2[2] <= 662 and d2[1] + d2[3] <= 632);
    try std.testing.expectEqualSlices([2]u32, &.{ .{ 0, 0 }, .{ 2, 4 } }, plan.skip.items);
    plan.commit();

    // A change inside the glass's sampled margin pulls in its whole backdrop:
    // a glass composited again under the scissor captures only fresh pixels.
    var near2 = near;
    near2.color = .{ .r = 3 };
    const frame3 = [_]M{ near2, far2, glass_begin, child, glass_end };
    const d3 = (try plan.prepareEffects(a, a, frame3[0..], 1000, 1000, 1, 7)).?;
    const read = @import("command_encoder/paint_fingerprint.zig").glassReadBounds(glass_begin);
    try std.testing.expect(@as(f32, @floatFromInt(d3[0] + d3[2])) >= read[0] + read[2]);
    try std.testing.expect(@as(f32, @floatFromInt(d3[1] + d3[3])) >= read[1] + read[3]);
    try std.testing.expectEqualSlices([2]u32, &.{.{ 1, 1 }}, plan.skip.items);
    plan.commit();

    // Context change (size, scale, resources): full redraw.
    try std.testing.expectEqual(@as(?[4]u32, null), try plan.prepareEffects(a, a, frame3[0..], 1000, 1000, 1, 8));
    plan.commit();

    // A group popping a clip opened before it is described but never skipped
    // (skipping it would unbalance the encoder's clip stack).
    const clip = M{ .control_kind = .push_clip, .geom = .{ .x = 0, .y = 0, .w = 300, .h = 300 } };
    const pop = M{ .control_kind = .pop_clip };
    const frame4 = [_]M{ far2, clip, glass_begin, child, pop, glass_end };
    _ = try plan.prepareEffects(a, a, frame4[0..], 1000, 1000, 1, 8);
    plan.commit();
    var far3 = far2;
    far3.color = .{ .r = 4 };
    const frame5 = [_]M{ far3, clip, glass_begin, child, pop, glass_end };
    _ = (try plan.prepareEffects(a, a, frame5[0..], 1000, 1000, 1, 8)).?;
    try std.testing.expectEqual(@as(usize, 0), plan.skip.items.len);
    plan.commit();

    // An external image (its texture can change under an unchanged item) is
    // damaged every frame.
    const image = M{ .kind = .image, .control_kind = .none, .geom = .{ .x = 700, .y = 100, .w = 20, .h = 20 } };
    const frame6 = [_]M{ far3, image };
    _ = try plan.prepareEffects(a, a, frame6[0..], 1000, 1000, 1, 9);
    plan.commit();
    const d6 = (try plan.prepareEffects(a, a, frame6[0..], 1000, 1000, 1, 9)).?;
    try std.testing.expect(d6[0] <= 700 and d6[0] + d6[2] >= 720 and d6[2] < 60);
}

test "frame damage computes geometry only for items it has not seen" {
    const FrameDamage = @import("frame_damage.zig").FrameDamage;
    const M = FullMock.MockItem;
    const a = std.testing.allocator;
    var rows: [40]M = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 10, .y = @floatFromInt(i * 20), .w = 200, .h = 18 }, .color = .{ .r = 1 } };
    var plan: FrameDamage = .{ .verify_geometry = true };
    defer plan.deinit(a);
    _ = try plan.prepareEffects(a, a, rows[0..], 1000, 1000, 1, 7);
    plan.commit();
    try std.testing.expectEqual(@as(u32, 40), plan.geo_computed);
    _ = try plan.prepareEffects(a, a, rows[0..], 1000, 1000, 1, 7);
    plan.commit();
    try std.testing.expectEqual(@as(u32, 0), plan.geo_computed);

    // One changed row, one inserted, one removed: only the changed and the
    // inserted one are computed; the rest are found again.
    var next: [40]M = undefined;
    @memcpy(next[0..5], rows[0..5]);
    next[5] = rows[5];
    next[5].geom.w = 300;
    next[6] = .{ .kind = .rect, .control_kind = .none, .geom = .{ .x = 500, .y = 500, .w = 5, .h = 5 }, .color = .{ .r = 9 } };
    @memcpy(next[7..39], rows[6..38]);
    next[39] = rows[39];
    const d = (try plan.prepareEffects(a, a, next[0..], 1000, 1000, 1, 7)).?;
    plan.commit();
    try std.testing.expectEqual(@as(u32, 2), plan.geo_computed);
    try std.testing.expectEqual(@as(u64, 0), plan.geo_violations);
    // The damage still covers the removed row (38: y 760..778) and the changed one.
    try std.testing.expect(d[1] <= 100 and d[1] + d[3] >= 778);
    try std.testing.expect(d[0] + d[2] >= 310);
}

test "frame damage skip ranges keep the retained layer numbering" {
    const M = FullMock.MockItem;
    const begin = M{ .control_kind = .begin_opacity_layer, .opacity = 0.5 };
    const rect = M{ .kind = .rect, .control_kind = .none, .color = .{ .r = 1 } };
    const end = M{ .control_kind = .end_opacity_layer };
    const commands = [_]M{ begin, rect, end, begin, rect, end };
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    const skip = [_][2]u32{ .{ 0, 2 }, .{ 3, 5 } };
    encoder.frame_damage_skip = &skip;
    try encoder.encodeCommands(commands[0..]);
    try std.testing.expectEqual(@as(usize, 2), encoder.retained_begin_seq);
}

test "frame damage skip accepts empty and singleton fixed command arrays" {
    const M = FullMock.MockItem;
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    // An empty typed array must instantiate without subtracting from zero.
    const empty = [_]M{};
    const skip = [_][2]u32{.{ 0, std.math.maxInt(u32) }};
    encoder.frame_damage_skip = &skip;
    try encoder.encodeCommands(&empty);
    try std.testing.expectEqual(@as(usize, 0), encoder.retained_begin_seq);
    // The inclusive skip end is clipped to one, including when supplied as
    // maxInt; the exclusive end cannot have the inferred integer type u0.
    const singleton = [_]M{.{ .control_kind = .begin_opacity_layer, .opacity = 0.5 }};
    try encoder.encodeCommands(&singleton);
    try std.testing.expectEqual(@as(usize, 1), encoder.retained_begin_seq);
}

test "content fingerprint: a group's draw rect and warp and an icon's snapping change it" {
    const M = FullMock.MockItem;
    const content = struct {
        fn of(it: M) u64 {
            return paint_fp.fullItemDigest(&it);
        }
    };
    const group = M{ .control_kind = .begin_opacity_layer, .use_draw_transform = true, .draw_x = 10, .draw_y = 20, .draw_w = 300, .draw_h = 40, .opacity = 0.5 };
    const base = content.of(group);
    var moved = group;
    moved.draw_w = 300.00003;
    try std.testing.expect(content.of(moved) != base);
    moved = group;
    moved.warp = .{ 0.1, 0, 0, 0 };
    try std.testing.expect(content.of(moved) != base);
    const icon = M{ .kind = .image, .control_kind = .none };
    var unsnapped = icon;
    unsnapped.icon_snap = !icon.icon_snap;
    try std.testing.expect(content.of(unsnapped) != content.of(icon));
}
